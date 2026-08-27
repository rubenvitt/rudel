import RudelEngine
import SwiftData
import SwiftUI

/// Tag 1 erfassen — der Anker aller Zyklus-Berechnungen (PRD §5.3).
///
/// Der Screen erklärt, was Tag 1 ist, statt es vorauszusetzen: von diesem einen
/// Datum hängen Phase, fruchtbares Fenster und die Prognose der nächsten
/// Läufigkeit ab. Ein um zwei Tage falsch gesetzter Anker verschiebt alles
/// Weitere mit.
///
/// Vorbelegt mit heute — der Normalfall ist „ist heute losgegangen", und der
/// soll ein Tap sein (PRD §2).
struct CyclePeriodStartSheet: View {
    let petID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @Query(sort: \Pet.createdAt) private var allPets: [Pet]
    @Query(sort: \CyclePeriod.day1Date, order: .reverse) private var allPeriods: [CyclePeriod]

    @State private var day1 = Date()
    @State private var note = ""

    // Erste Beobachtung, optional. Vorbelegung überall „nicht beobachtet":
    // Tag 1 ist über mehrere Zeichen definiert, und welches davon aufgefallen
    // ist, weiß nur der Mensch davor.
    @State private var vulvaSwellingVisible: Bool?
    @State private var frequentUrination: Bool?
    @State private var genitalLicking: Bool?
    @State private var dischargePresent: Bool?
    @State private var dischargeColor: DischargeColor?
    @State private var dischargeAmount: DischargeAmount?
    @State private var vulvaTurgor: VulvaTurgor?
    @State private var detailExpanded = false

    // MARK: Ableitungen

    private var dayMath: DayMath { appState.dayMath }

    private var pet: Pet? { allPets.first { $0.id == petID } }

    /// In Swift gefiltert, nicht per `#Predicate` — Beziehungen sind dort nicht
    /// vergleichbar.
    private var periods: [CyclePeriod] {
        allPeriods.filter { $0.pet?.id == petID }
    }

    private var anchor: Date { dayMath.startOfDay(day1) }

    /// Nächstliegender bereits erfasster Anker, mit dem **absoluten** Abstand.
    ///
    /// Absolut, weil das Datum auch nachgetragen werden darf: ein alter Zyklus,
    /// der zwischen zwei erfasste rutscht, ist derselbe Verdachtsfall wie ein
    /// zu kurzes Intervall nach vorn.
    private var nearestAnchor: (period: CyclePeriod, distance: Int)? {
        var best: (period: CyclePeriod, distance: Int)?
        for candidate in periods {
            let distance = abs(dayMath.days(from: candidate.day1Date, to: anchor))
            if let current = best, current.distance <= distance { continue }
            best = (period: candidate, distance: distance)
        }
        return best
    }

    /// Warnung, wenn der Abstand unter der Populations-Untergrenze liegt.
    /// Biologisch unplausibel und meist ein Tippfehler — blockiert wird nicht,
    /// denn die Ausnahme kennt nur der Mensch.
    private var implausibleWarning: String? {
        guard let nearest = nearestAnchor,
              nearest.distance < StudyConstants.day1ToDay1IntervalMinDays
        else { return nil }

        if nearest.distance == 0 {
            return "Für den \(Format.date(nearest.period.day1Date)) ist bereits eine Läufigkeit erfasst."
        }
        return "Nur \(Format.dayCount(nearest.distance)) Abstand zu Tag 1 am \(Format.date(nearest.period.day1Date)). "
            + "Unter \(StudyConstants.day1ToDay1IntervalMinDays) Tagen ist der Abstand biologisch unplausibel — "
            + "meist ein Tippfehler. Speichern ist trotzdem möglich."
    }

    private var firstSignals: PhaseSignals {
        PhaseSignals(
            date: anchor,
            dischargePresent: dischargePresent,
            dischargeColor: dischargeColor,
            dischargeAmount: dischargeAmount,
            vulvaTurgor: vulvaTurgor,
            frequentUrination: frequentUrination,
            genitalLicking: genitalLicking,
            vulvaSwellingVisible: vulvaSwellingVisible
        )
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
                } else {
                    form
                }
            }
            .navigationTitle("Läufigkeit begonnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(pet == nil)
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Was ist Tag 1?", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "Der erste Tag, an dem die Läufigkeit erkennbar war — Schwellung, Ausfluss, "
                            + "vermehrtes Belecken oder häufigeres Urinieren, je nachdem was zuerst auffiel."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Unsicher, ob es gestern schon angefangen hat? Dann den früheren Tag nehmen — "
                            + "ein zu spät gesetzter Anker verschiebt jede Phase nach hinten."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            Section {
                DatePicker("Tag 1", selection: $day1, in: ...Date(), displayedComponents: .date)

                HStack(spacing: 10) {
                    quickDateButton("Heute", daysBack: 0)
                    quickDateButton("Gestern", daysBack: 1)
                    quickDateButton("Vorgestern", daysBack: 2)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .font(.subheadline)

                if let warning = implausibleWarning {
                    CycleNoticeRow(text: warning)
                }
            } header: {
                Text("Datum")
            } footer: {
                if let last = periods.first {
                    Text("Letzte erfasste Läufigkeit: Tag 1 am \(Format.date(last.day1Date)).")
                } else {
                    Text("Erste erfasste Läufigkeit. Bis zum nächsten Tag 1 rechnet die App mit Populationswerten.")
                }
            }

            Section {
                CycleTriStatePicker(title: "Vulva sichtbar geschwollen", value: $vulvaSwellingVisible)
                CycleTriStatePicker(title: "Häufiges Urinieren", value: $frequentUrination)
                CycleTriStatePicker(title: "Vermehrtes Belecken", value: $genitalLicking)
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
            } header: {
                Text("Erste Beobachtung (optional)")
            } footer: {
                Text(
                    "Nichts ausfüllen ist in Ordnung: leer heißt „nicht beobachtet“ und wird gar nicht "
                        + "gespeichert — nicht „nein“. Beobachtungen lassen sich jederzeit nachtragen."
                )
            }

            Section("Notiz") {
                TextField("Notiz zur Läufigkeit", text: $note, axis: .vertical)
                    .lineLimit(1...4)
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

    private func quickDateButton(_ title: String, daysBack: Int) -> some View {
        Button(title) {
            day1 = dayMath.adding(days: -daysBack, to: Date())
        }
        .disabled(dayMath.isSameDay(day1, dayMath.adding(days: -daysBack, to: Date())))
    }

    // MARK: Schreiben

    private func save() {
        guard let pet else { return }

        let period = CyclePeriod(
            day1Date: anchor,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Beziehung über die To-One-Seite setzen, nicht über das Array.
        period.pet = pet
        context.insert(period)
        try? context.save()

        // Beobachtung nur anlegen, wenn sie etwas aussagt — ein leerer Eintrag
        // wäre für die Phasenschätzung nicht neutral, sondern Rauschen.
        if !firstSignals.isEmpty {
            let observation = CycleObservation(
                date: anchor,
                dischargePresent: dischargePresent,
                dischargeColor: dischargeColor,
                dischargeAmount: dischargeAmount,
                vulvaTurgor: vulvaTurgor,
                frequentUrination: frequentUrination,
                genitalLicking: genitalLicking,
                vulvaSwellingVisible: vulvaSwellingVisible
            )
            observation.period = period
            context.insert(observation)
            try? context.save()
        }

        dismiss()
    }
}
