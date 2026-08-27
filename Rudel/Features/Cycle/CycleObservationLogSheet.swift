import RudelEngine
import SwiftData
import SwiftUI

/// Eine Tagesbeobachtung innerhalb der laufenden Läufigkeit (PRD §5.3).
///
/// **Jedes Feld ist optional und leer vorbelegt.** Nichts wird aus dem Vortag
/// übernommen: eine übernommene Farbe wäre eine Beobachtung, die niemand
/// gemacht hat. Der Vortag steht deshalb nur als Kontext daneben.
///
/// Geschrieben wird auf zwei Ebenen: die Beobachtung selbst (append-only) und
/// die Läufigkeit (Ende der sichtbaren Hitze, Scheinträchtigkeit). Wer nur das
/// Ende nachträgt, legt keine leere Beobachtung an.
struct CycleObservationLogSheet: View {
    let petID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @Query(sort: \Pet.createdAt) private var allPets: [Pet]
    @Query(sort: \CyclePeriod.day1Date, order: .reverse) private var allPeriods: [CyclePeriod]

    // Beobachtung
    @State private var date = Date()
    @State private var standingHeat: Bool?
    @State private var dischargePresent: Bool?
    @State private var dischargeColor: DischargeColor?
    @State private var dischargeAmount: DischargeAmount?
    @State private var vulvaTurgor: VulvaTurgor?
    @State private var frequentUrination: Bool?
    @State private var genitalLicking: Bool?
    @State private var vulvaSwellingVisible: Bool?
    @State private var flagging: Bool?
    @State private var attractsMales: Bool?
    @State private var progesteroneText = ""
    @State private var cornificationText = ""
    @State private var note = ""
    @State private var detailExpanded = false
    @State private var clinicalExpanded = false

    // Läufigkeits-Ebene
    @State private var heatEnded = false
    @State private var heatEndDate = Date()
    @State private var pseudopregnancy = false
    @State private var pseudopregnancyNote = ""

    @State private var seeded = false

    // MARK: Ableitungen

    private var dayMath: DayMath { appState.dayMath }

    private var pet: Pet? { allPets.first { $0.id == petID } }

    /// Die jüngste Läufigkeit des Tiers. Bewusst nicht die zum gewählten Datum
    /// passende: das Datum ist auf dieses Fenster begrenzt, und ein wandernder
    /// Bezug würde beim Zurückblättern still die Läufigkeit wechseln.
    private var period: CyclePeriod? {
        allPeriods.first { $0.pet?.id == petID }
    }

    /// Nur Vergangenheit, und nicht vor Tag 1 — eine Beobachtung vor dem Anker
    /// hätte keinen Tag im Zyklus.
    private var allowedDates: ClosedRange<Date> {
        let lower = dayMath.startOfDay(period?.day1Date ?? Date())
        return lower...max(lower, Date())
    }

    private var normalizedDate: Date { dayMath.startOfDay(date) }

    private var dayInCycle: Int? {
        guard let period else { return nil }
        return CyclePhaseEstimator(dayMath: dayMath)
            .dayInCycle(day1: period.day1Date, asOf: normalizedDate)
    }

    /// Letzte Beobachtung vor dem gewählten Tag — als Kontext, nicht als
    /// Vorbelegung.
    private var previousObservation: CycleObservation? {
        period?.sortedObservations.last { observation in
            observation.date < normalizedDate && dayMath.isSameDay(observation.date, normalizedDate) == false
        }
    }

    private var sameDayCount: Int {
        guard let period else { return 0 }
        return period.observations.filter { dayMath.isSameDay($0.date, normalizedDate) }.count
    }

    private var progesteroneValue: Double? {
        guard let value = decimal(progesteroneText), value >= 0 else { return nil }
        return value
    }

    private var cornificationValue: Double? {
        guard let value = decimal(cornificationText) else { return nil }
        return min(100, max(0, value))
    }

    private var signals: PhaseSignals {
        PhaseSignals(
            date: normalizedDate,
            dischargePresent: dischargePresent,
            dischargeColor: dischargeColor,
            dischargeAmount: dischargeAmount,
            vulvaTurgor: vulvaTurgor,
            frequentUrination: frequentUrination,
            genitalLicking: genitalLicking,
            vulvaSwellingVisible: vulvaSwellingVisible,
            flagging: flagging,
            standingHeat: standingHeat,
            attractsMales: attractsMales,
            progesteroneNgPerMl: progesteroneValue,
            cornificationPercent: cornificationValue
        )
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trägt das Formular eine Beobachtung? Die Prüfung läuft über
    /// `PhaseSignals.isEmpty` — dieselbe Definition, mit der die Engine leere
    /// Einträge ignoriert.
    private var hasObservation: Bool {
        !signals.isEmpty || !trimmedNote.isEmpty
    }

    /// Änderungen an der Läufigkeit selbst, unabhängig von der Beobachtung.
    private var hasPeriodChange: Bool {
        guard let period else { return false }
        let endChanged: Bool
        if heatEnded {
            endChanged = period.visibleHeatEndDate.map { dayMath.isSameDay($0, heatEndDate) == false } ?? true
        } else {
            endChanged = period.visibleHeatEndDate != nil
        }
        let noteChanged = pseudopregnancy
            && pseudopregnancyNote.trimmingCharacters(in: .whitespacesAndNewlines) != period.pseudopregnancyNote
        return endChanged || pseudopregnancy != period.pseudopregnancyObserved || noteChanged
    }

    private var canSave: Bool {
        period != nil && (hasObservation || hasPeriodChange)
    }

    // MARK: Aufbau

    var body: some View {
        NavigationStack {
            Group {
                if pet == nil {
                    ContentUnavailableView(
                        "Tier nicht gefunden",
                        systemImage: "pawprint",
                        description: Text("Das Tier wurde inzwischen gelöscht.")
                    )
                } else if period == nil {
                    noPeriodState
                } else {
                    form
                }
            }
            .navigationTitle("Beobachtung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(!canSave)
                }
            }
            // An die Läufigkeit gekoppelt: läge sie beim ersten Aufbau noch nicht
            // vor, würde eine einmalige `.task` mit ungesetztem `heatEnded`
            // vorbelegen — und beim Speichern ein vorhandenes Enddatum löschen.
            .task(id: period?.id) { seed() }
        }
    }

    private var noPeriodState: some View {
        ContentUnavailableView {
            Label("Keine Läufigkeit erfasst", systemImage: "circle.hexagonpath")
        } description: {
            Text("Eine Beobachtung braucht einen Tag-1-Anker, sonst hat sie keinen Tag im Zyklus.")
        } actions: {
            Button("Tag 1 erfassen") {
                appState.present(.startCyclePeriod(petID: petID))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var form: some View {
        Form {
            // MARK: Tag
            Section {
                DatePicker("Datum", selection: $date, in: allowedDates, displayedComponents: .date)
                if let day = dayInCycle {
                    LabeledValueRow(label: "Tag im Zyklus", value: "Tag \(day)", systemImage: "number")
                }
                if sameDayCount > 0 {
                    CycleNoticeRow(
                        text: "Für diesen Tag ist bereits eine Beobachtung erfasst. Die neue kommt hinzu, sie ersetzt nichts.",
                        systemImage: "info.circle.fill",
                        tint: .secondary
                    )
                }
            } header: {
                Text("Tag")
            } footer: {
                if let previous = previousObservation {
                    let parts = CycleLabel.observationSummary(previous)
                    Text(
                        "Zuletzt am \(Format.shortDate(previous.date))"
                            + (parts.isEmpty ? "." : ": \(parts.joined(separator: " · "))")
                    )
                }
            }

            // MARK: Duldungsreflex
            Section {
                CycleTriStatePicker(title: "Flagging", value: $flagging)
                CycleTriStatePicker(
                    title: "Duldung",
                    value: $standingHeat,
                    yesLabel: "Duldet",
                    noLabel: "Duldet nicht"
                )
            } header: {
                Text("Duldungsreflex")
            } footer: {
                // Die einzige Zeile, die hier stehen muss: dass es ohne Rüden
                // geht und wie. Warum die beiden Signale unterschiedlich wiegen,
                // gehört ins Design-Doc, nicht auf den Screen.
                Text("Ohne Rüden prüfbar: Flagging beim Streichen über die Kruppe, Duldung bei festem Druck auf die Lenden.")
            }

            // MARK: Alltagszeichen
            Section {
                CycleTriStatePicker(title: "Vulva sichtbar geschwollen", value: $vulvaSwellingVisible)
                CycleTriStatePicker(title: "Häufiges Urinieren", value: $frequentUrination)
                CycleTriStatePicker(title: "Vermehrtes Belecken", value: $genitalLicking)
                CycleTriStatePicker(title: "Rüden interessiert", value: $attractsMales)
            } header: {
                Text("Alltagszeichen")
            }

            // MARK: Genauer hinsehen
            Section {
                DisclosureGroup("Ausfluss und Vulva", isExpanded: $detailExpanded) {
                    CycleTriStatePicker(
                        title: "Ausfluss",
                        value: $dischargePresent,
                        yesLabel: "Vorhanden",
                        noLabel: "Keiner"
                    )
                    if dischargePresent != false {
                        CycleOptionalPicker(title: "Farbe", value: $dischargeColor) { Format.label($0) }
                        CycleOptionalPicker(title: "Menge", value: $dischargeAmount) { Format.label($0) }
                    }
                    CycleOptionalPicker(title: "Konsistenz der Vulva", value: $vulvaTurgor) { Format.label($0) }
                }
            }

            // MARK: Klinische Werte
            Section {
                DisclosureGroup("Klinische Werte", isExpanded: $clinicalExpanded) {
                    LabeledContent("Progesteron") {
                        HStack(spacing: 4) {
                            TextField("0,0", text: $progesteroneText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("ng/ml")
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Kornifizierung") {
                        HStack(spacing: 4) {
                            TextField("0", text: $cornificationText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("%")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Nur eintragen, was tierärztlich bestimmt wurde.")
            }

            // MARK: Notiz
            Section("Notiz") {
                TextField("Notiz", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            }

            // MARK: Läufigkeit
            if let period = period {
                Section {
                    Toggle("Sichtbare Hitze beendet", isOn: $heatEnded)
                    if heatEnded {
                        DatePicker(
                            "Letzter Tag",
                            selection: $heatEndDate,
                            in: allowedDates,
                            displayedComponents: .date
                        )
                    }
                } header: {
                    Text("Läufigkeit vom \(Format.shortDate(period.day1Date))")
                } footer: {
                    Text("Das Ende der sichtbaren Hitze ist nicht das Ende des Zyklus — der Diöstrus läuft danach noch 60–90 Tage.")
                }

                Section {
                    Toggle("Anzeichen von Scheinträchtigkeit", isOn: $pseudopregnancy)
                    if pseudopregnancy {
                        TextField("Was ist aufgefallen?", text: $pseudopregnancyNote, axis: .vertical)
                            .lineLimit(1...4)
                    }
                } footer: {
                    Text("Im Diöstrus-Nachlauf möglich: geschwollenes Gesäuge, Milchbildung, Nestbau, Verhaltensänderung.")
                }
            }
        }
        .onChange(of: dischargePresent) { _, newValue in
            // „Keiner" plus eine Farbe wäre ein Widerspruch, den die Engine
            // ernst nehmen müsste. Also mit dem Feld verschwinden auch die Werte.
            if newValue == false {
                dischargeColor = nil
                dischargeAmount = nil
            }
        }
    }

    // MARK: Zustand

    /// Einmalige Vorbelegung. Nur Datum und die Felder der Läufigkeit — die
    /// Beobachtungsfelder bleiben leer, damit nichts erfasst wird, was niemand
    /// gesehen hat.
    private func seed() {
        guard !seeded, let period else { return }
        seeded = true

        let today = max(period.day1Date, dayMath.startOfDay(Date()))
        date = today
        heatEnded = period.visibleHeatEndDate != nil
        heatEndDate = period.visibleHeatEndDate ?? today
        pseudopregnancy = period.pseudopregnancyObserved
        pseudopregnancyNote = period.pseudopregnancyNote
    }

    /// Komma-Eingabe zulassen: die deutsche Tastatur liefert „3,4", und
    /// `Double("3,4")` ist `nil`.
    private func decimal(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }

    // MARK: Schreiben

    private func save() {
        guard let period else { return }

        if hasObservation {
            let observation = CycleObservation(
                date: normalizedDate,
                dischargePresent: dischargePresent,
                dischargeColor: dischargeColor,
                dischargeAmount: dischargeAmount,
                vulvaTurgor: vulvaTurgor,
                frequentUrination: frequentUrination,
                genitalLicking: genitalLicking,
                vulvaSwellingVisible: vulvaSwellingVisible,
                flagging: flagging,
                standingHeat: standingHeat,
                attractsMales: attractsMales,
                progesteroneNgPerMl: progesteroneValue,
                cornificationPercent: cornificationValue,
                note: trimmedNote
            )
            // Beziehung über die To-One-Seite setzen, nicht über das Array.
            observation.period = period
            context.insert(observation)
        }

        period.visibleHeatEndDate = heatEnded ? dayMath.startOfDay(heatEndDate) : nil
        period.pseudopregnancyObserved = pseudopregnancy
        period.pseudopregnancyNote = pseudopregnancy
            ? pseudopregnancyNote.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        try? context.save()
        dismiss()
    }
}
