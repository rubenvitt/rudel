import RudelEngine
import SwiftData
import SwiftUI

/// Der „Heute"-Screen (PRD §5.6). Er beantwortet genau eine Frage: *Was ist
/// offen?* — deshalb steht die Aufgabenliste direkt unter dem Tierkopf, und
/// jede Zeile lässt sich mit einem Tap abhaken.
///
/// Die Ein-Tap-Zeile ist der Grund, warum dieser Screen eine `List` ist und
/// keine Karten-Spalte: `swipeActions` gibt es nur in einer Liste. Der Weg über
/// `appState.present(.quickLogMedication(...))` bleibt als zweiter Weg für den
/// Fall, dass Datum oder Notiz vom Regelfall abweichen (PRD §2).
struct DashboardView: View {
    var body: some View {
        PetScope(title: "Heute") { pet in
            DashboardContent(pet: pet)
        }
    }
}

// MARK: - Inhalt

private struct DashboardContent: View {
    let pet: Pet

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    // Ohne Prädikat und ohne Enum-Vergleich: gefiltert wird in Swift, weil
    // `#Predicate` weder über Beziehungen noch über gespeicherte Enums geht.
    // Die Datenmenge ist einstellig bis dreistellig — das kostet nichts.
    @Query(sort: \MedicationPlan.createdAt) private var allPlans: [MedicationPlan]
    @Query(sort: \CyclePeriod.day1Date, order: .reverse) private var allPeriods: [CyclePeriod]

    /// Zählt erfolgreiche Log-Vorgänge und dient nur als Auslöser für die
    /// haptische Rückmeldung. Sitzt auf der `List`, nicht auf der Zeile: die
    /// Zeile verschwindet beim Abhaken aus der Liste und käme nie zum Feuern.
    @State private var logTick = 0

    /// Stichtag für **alle** Berechnungen dieses Screens, auf Mitternacht in der
    /// Gerätezeitzone normalisiert. Bewusst nicht `Date()` an mehreren Stellen:
    /// sonst rechnete jede Zeile mit einem anderen Zeitpunkt, und der Snapshot
    /// wäre bei jedem Neuzeichnen ein anderer.
    private var today: Date { appState.dayMath.startOfDay(Date()) }

    private var plans: [MedicationPlan] {
        allPlans.filter { $0.pet?.id == pet.id }
    }

    private var periods: [CyclePeriod] {
        allPeriods.filter { $0.pet?.id == pet.id }
    }

    var body: some View {
        // Einmal rechnen, mehrfach anzeigen — jeder Zugriff auf `snapshot`
        // würde die Engine erneut aufrufen.
        let data = DashboardSnapshot(
            pet: pet,
            plans: plans,
            periods: periods,
            dayMath: appState.dayMath,
            asOf: today
        )

        return List {
            headerSection
            tasksSection(data)
            dosesSection(data)
            cycleSection(data)
            laterSection(data)
            quickActionsSection
        }
        .listStyle(.insetGrouped)
        .sensoryFeedback(.success, trigger: logTick)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.present(.quickLogMedication(petID: pet.id))
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Gabe erfassen")
            }
        }
    }

    // MARK: Kopf

    @ViewBuilder
    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                PetAvatar(pet: pet, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(petName)
                        .font(.headline)
                    if let subtitle = petSubtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            weightRow
        } header: {
            Text(Format.date(today))
        }
    }

    /// Letztes Gewicht mit Trend gegen die vorherige Messung. Der Trend steht
    /// hier und nicht erst im Gesundheits-Tab, weil eine Gewichtsveränderung
    /// die häufigste stille Auffälligkeit ist.
    @ViewBuilder
    private var weightRow: some View {
        let history = pet.weightEntries.sorted { $0.date > $1.date }

        if let latest = history.first {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "scalemass")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text("Gewicht")
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.weight(latest.valueKg))
                        .foregroundStyle(.secondary)
                    if let trend = weightTrend(history) {
                        Label(trend.text, systemImage: trend.symbolName)
                            .font(.caption)
                            .foregroundStyle(trend.tint)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            LabeledValueRow(
                label: "Gewicht",
                value: "noch nicht erfasst",
                systemImage: "scalemass"
            )
        }
    }

    private struct WeightTrend {
        var text: String
        var symbolName: String
        var tint: Color
    }

    /// Differenz zur vorherigen Messung. `nil`, wenn es nur einen Eintrag gibt —
    /// ein Trend aus einem einzigen Wert wäre erfunden.
    private func weightTrend(_ history: [WeightEntry]) -> WeightTrend? {
        guard history.count >= 2 else { return nil }
        let latest = history[0]
        let previous = history[1]
        let delta = latest.valueKg - previous.valueKg
        let since = Format.relativePast(days: appState.dayMath.days(from: previous.date, to: today))

        // 50 g Toleranz: darunter ist es Waagen-Rauschen, kein Trend.
        if abs(delta) < 0.05 {
            return WeightTrend(text: "unverändert · \(since)", symbolName: "arrow.right", tint: .secondary)
        }
        let sign = delta > 0 ? "+" : "−"
        return WeightTrend(
            text: "\(sign)\(Format.weight(abs(delta))) · \(since)",
            symbolName: delta > 0 ? "arrow.up.right" : "arrow.down.right",
            tint: .secondary
        )
    }

    // MARK: Offene Aufgaben

    @ViewBuilder
    private func tasksSection(_ data: DashboardSnapshot) -> some View {
        Section {
            if data.tasks.isEmpty {
                ContentUnavailableView {
                    Label("Nichts offen", systemImage: "checkmark.seal")
                } description: {
                    Text("Für \(petName) ist gerade keine Gabe fällig.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(data.tasks) { item in
                    DueItemRow(
                        item: item,
                        title: title(for: item),
                        symbolName: symbolName(for: item),
                        protection: data.protection[item.sourceID],
                        forecastConfidence: item.isForecast ? data.prediction?.confidence : nil,
                        onLog: logAction(for: item),
                        logActionTitle: logActionTitle(for: item)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if canLog(item) {
                            Button {
                                logGiven(item)
                            } label: {
                                Label(logActionTitle(for: item), systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                        secondarySwipeAction(for: item)
                    }
                }
            }
        } header: {
            HStack {
                Text("Offene Aufgaben")
                Spacer()
                if !data.tasks.isEmpty {
                    Text("\(data.tasks.count)")
                        .accessibilityLabel("\(data.tasks.count) offen")
                }
            }
        }
    }

    /// Was später dran ist. Bewusst schmucklos — ohne Badge, ohne Balken, ohne
    /// Haken-Button: es soll nachschlagbar sein, aber nicht um Aufmerksamkeit
    /// konkurrieren. Wer früher gibt als geplant, kommt über die Wisch-Aktion ran.
    @ViewBuilder
    private func laterSection(_ data: DashboardSnapshot) -> some View {
        if !data.later.isEmpty {
            Section("Später geplant") {
                ForEach(data.later) { item in
                    LabeledValueRow(
                        label: title(for: item),
                        value: Format.relativeDue(days: item.daysUntilDue),
                        systemImage: symbolName(for: item)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canLog(item) {
                            Button {
                                logGiven(item)
                            } label: {
                                Label(logActionTitle(for: item), systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                    }
                }
            }
        }
    }

    /// Zweiter Weg für den Sonderfall: abweichendes Datum, Notiz, oder — bei
    /// einer erwarteten Läufigkeit — der Tag-1-Anker.
    @ViewBuilder
    private func secondarySwipeAction(for item: DueItem) -> some View {
        if item.category == .cycleForecast {
            Button {
                appState.present(.startCyclePeriod(petID: pet.id))
            } label: {
                Label("Tag 1 erfassen", systemImage: "drop")
            }
            .tint(.pink)
        } else {
            Button {
                appState.present(.quickLogMedication(petID: pet.id))
            } label: {
                Label("Anderes Datum", systemImage: "calendar")
            }
            .tint(.blue)
        }
    }

    // MARK: Heutige Einzelgaben

    @ViewBuilder
    private func dosesSection(_ data: DashboardSnapshot) -> some View {
        if !data.doses.isEmpty {
            Section {
                ForEach(data.doses) { slot in
                    DoseRow(slot: slot) { toggle(slot) }
                }
            } header: {
                Text("Heutige Einzelgaben")
            } footer: {
                Text("Nur abgehakte Gaben werden gespeichert. Ein Tap auf einen Haken nimmt ihn wieder zurück.")
            }
        }
    }

    // MARK: Zyklus

    @ViewBuilder
    private func cycleSection(_ data: DashboardSnapshot) -> some View {
        if pet.tracksCycle, let cycle = data.cycle {
            Section("Zyklus") {
                switch cycle {
                case .running(let estimate, let day1):
                    LabeledValueRow(
                        label: "Phase",
                        value: Format.label(estimate.phase),
                        systemImage: "circle.hexagonpath"
                    )
                    LabeledValueRow(
                        label: "Tag im Zyklus",
                        value: "\(estimate.dayInCycle)",
                        systemImage: "number"
                    )
                    LabeledValueRow(
                        label: "Tag 1",
                        value: Format.date(day1),
                        systemImage: "calendar"
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Phasenende erwartet \(Format.dateRange(estimate.expectedPhaseEnd))")
                            .font(.subheadline)
                        ConfidenceLabel(
                            confidence: estimate.confidence,
                            detail: sourceLabel(estimate.source)
                        )
                        Text(Format.explanation(estimate.phase))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .forecast(let prediction):
                    LabeledValueRow(
                        label: "Nächste Läufigkeit",
                        value: Format.dateRange(prediction.range),
                        systemImage: "calendar.badge.clock"
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Erwartet um \(Format.date(prediction.expectedDate))")
                            .font(.subheadline)
                        // Spanne und Konfidenz gehören zusammen: eine Prognose
                        // ohne Konfidenzangabe darf nicht angezeigt werden (PRD §6).
                        ConfidenceLabel(
                            confidence: prediction.confidence,
                            detail: "± \(Format.dayCount(Int(prediction.bandHalfWidthDays.rounded()))) · \(basisLabel(prediction.basis))"
                        )
                    }

                case .noAnchor:
                    Button {
                        appState.present(.startCyclePeriod(petID: pet.id))
                    } label: {
                        Label("Tag 1 der Läufigkeit erfassen", systemImage: "drop")
                    }
                    Text("Ohne einen erfassten Tag 1 gibt es keinen Bezugspunkt und damit keine Prognose.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Woher die Phasenschätzung kommt. Bewusst lokal statt als Extension auf
    /// `PhaseEstimateSource`: die Zyklus-Screens brauchen dieselbe Formulierung,
    /// und zwei gleichnamige Extensions im Modul kollidieren.
    private func sourceLabel(_ source: PhaseEstimateSource) -> String {
        switch source {
        case .clinicalSignals: return "aus klinischen Werten"
        case .observedSignals: return "aus Beobachtungen"
        case .populationDefault: return "aus Populationswerten"
        }
    }

    private func basisLabel(_ basis: PredictionBasis) -> String {
        switch basis {
        case .population:
            return "Populationswert"
        case .blended(let count):
            return count == 1 ? "1 eigenes Intervall" : "\(count) eigene Intervalle"
        }
    }

    // MARK: Schnellaktionen

    @ViewBuilder
    private var quickActionsSection: some View {
        Section("Schnell erfassen") {
            quickAction("Symptom", systemImage: "stethoscope") {
                appState.present(.logSymptom(petID: pet.id))
            }
            quickAction("Gewicht", systemImage: "scalemass") {
                appState.present(.logWeight(petID: pet.id))
            }
            if pet.tracksCycle {
                quickAction("Zyklus-Beobachtung", systemImage: "drop") {
                    appState.present(.logCycleObservation(petID: pet.id))
                }
            }
            quickAction("Gabe mit Datum", systemImage: "pills") {
                appState.present(.quickLogMedication(petID: pet.id))
            }
        }
    }

    private func quickAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Aktionen

    private func plan(for item: DueItem) -> MedicationPlan? {
        plans.first { $0.engineID == item.sourceID }
    }

    /// Abhakbar sind nur Gaben. Eine Zyklus-Prognose ist keine Aufgabe, die man
    /// erledigt — sie tritt ein.
    private func canLog(_ item: DueItem) -> Bool {
        switch item.category {
        case .medication, .protectionExpiry: return plan(for: item) != nil
        case .dose, .cycleForecast: return false
        }
    }

    /// Bei Kotproben-Plänen dokumentiert der Eintrag die abgegebene Probe, nicht
    /// eine Wurmkur — die Formulierung muss das spiegeln (PRD §5.2). Die Engine
    /// kann das nicht wissen: `DueItemBuilder.MedicationInput` führt das Feld
    /// nicht mit, also korrigiert die View den Titel.
    private func title(for item: DueItem) -> String {
        if item.category == .medication, let plan = plan(for: item), plan.usesFecalSampleInstead {
            return "Kotprobe"
        }
        return item.title
    }

    private func logActionTitle(for item: DueItem) -> String {
        if let plan = plan(for: item), plan.usesFecalSampleInstead {
            return "Abgegeben"
        }
        return "Gegeben"
    }

    /// `nil` ⇒ die Zeile bekommt keinen Haken-Button und keine Wisch-Aktion
    /// zum Eintragen.
    private func logAction(for item: DueItem) -> (() -> Void)? {
        guard canLog(item) else { return nil }
        return { logGiven(item) }
    }

    private func symbolName(for item: DueItem) -> String {
        if let plan = plan(for: item) {
            return Format.symbolName(plan.kindValue)
        }
        return item.category == .cycleForecast ? "drop" : "bell"
    }

    /// Ein Tap = eine dokumentierte Gabe mit heutigem Datum. Kein Sheet, keine
    /// Rückfrage — das ist die Zwei-Tap-Regel aus PRD §2, und ein Fehleintrag
    /// ist in der Medikamenten-Historie in einem Wisch gelöscht.
    private func logGiven(_ item: DueItem) {
        guard let plan = plan(for: item) else { return }
        // Zweimal am selben Tag ist bei Wurmkur, Zeckenschutz und Impfung immer
        // ein Doppeltipp, kein zweiter Vorgang. Der Zustand ist dann schon
        // richtig, also nur die Rückmeldung geben und nichts anlegen.
        if plan.events.contains(where: { appState.dayMath.isSameDay($0.givenOn, today) }) {
            logTick += 1
            return
        }
        let event = MedicationEvent(givenOn: today)
        context.insert(event)
        // Beziehung über die To-One-Seite setzen; `inverse:` sitzt auf `MedicationPlan.events`.
        event.plan = plan
        try? context.save()
        logTick += 1
    }

    /// Haken setzen oder zurücknehmen. Das Zurücknehmen **löscht** die Zeile:
    /// das Journal kennt nur „gegeben"-Einträge, eine fehlende Zeile heißt
    /// „nicht gegeben" (PRD §8).
    private func toggle(_ slot: DoseSlot) {
        if let existing = slot.existingLog {
            context.delete(existing)
            try? context.save()
            return
        }
        let entry = DoseLogEntry(scheduledAt: slot.scheduledAt)
        context.insert(entry)
        entry.plan = slot.plan
        try? context.save()
        logTick += 1
    }

    // MARK: Anzeige-Helfer

    private var petName: String {
        pet.name.isEmpty ? "Unbenannt" : pet.name
    }

    private var petSubtitle: String? {
        var pieces: [String] = []
        let breed = pet.breed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !breed.isEmpty { pieces.append(breed) }
        if let age = ageText { pieces.append(age) }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    private var ageText: String? {
        guard let parts = pet.ageComponents(asOf: today, calendar: appState.dayMath.calendar) else {
            return nil
        }
        var pieces: [String] = []
        if parts.years > 0 {
            pieces.append(parts.years == 1 ? "1 Jahr" : "\(parts.years) Jahre")
        }
        if parts.months > 0 {
            pieces.append(parts.months == 1 ? "1 Monat" : "\(parts.months) Monate")
        }
        return pieces.isEmpty ? "unter 1 Monat" : pieces.joined(separator: ", ")
    }
}

// MARK: - Berechnung

/// Alles Gerechnete dieses Screens an einer Stelle, aus **einem** Stichtag.
///
/// Absichtlich kein ViewModel: hier wird nichts gehalten und nichts beobachtet,
/// nur aus den geladenen Modellen und der Engine ein Anzeige-Zustand abgeleitet.
/// Ein `@Observable`-Objekt drumherum wäre Zustand, den niemand braucht.
private struct DashboardSnapshot {
    /// Offene Aufgaben, nach Dringlichkeit sortiert (Reihenfolge der Engine).
    ///
    /// **Ohne** `.dose`-Einträge: die Einzelgaben stehen in einem eigenen
    /// Abschnitt, weil zum Abhaken der genaue Termin gebraucht wird — den
    /// führt `DueItem` nicht mit.
    ///
    /// **Ohne** `.scheduled`: `DueItemBuilder` gibt zu jedem aktiven Plan ein
    /// Item zurück, auch zu einer Wurmkur, die erst in zwei Monaten dran ist.
    /// Unter „offen" gehört das nicht — es verwässert genau die Frage, die der
    /// Screen beantworten soll. Diese Items stehen in `later`.
    var tasks: [DueItem] = []

    /// Was ansteht, aber mehr als 14 Tage hin ist (`Urgency.scheduled`).
    /// Sichtbar, aber ohne Dringlichkeits-Aufmachung.
    var later: [DueItem] = []

    /// Restwirksamkeit je Plan-ID, für die `ProtectionBar`. Nur für Pläne mit
    /// Wirkdauer **und** dokumentierter letzter Gabe — ohne beides gibt es
    /// keinen Prozentwert, nur eine überfällige Aufgabe.
    var protection: [String: ProtectionStatus] = [:]

    /// Die heute fälligen Einzelgaben eines Dauermedikaments.
    var doses: [DoseSlot] = []

    var cycle: CycleStatus?

    /// Prognose der nächsten Läufigkeit, falls berechenbar. Wird zusätzlich zur
    /// Zyklus-Karte für die Konfidenzangabe an der Prognose-Zeile gebraucht.
    var prediction: CyclePrediction?

    init(
        pet: Pet,
        plans: [MedicationPlan],
        periods: [CyclePeriod],
        dayMath: DayMath,
        asOf: Date
    ) {
        let calculator = MedicationCalculator(dayMath: dayMath)

        // Zyklus zuerst: die Prognose fließt sowohl in die Zyklus-Karte als
        // auch als Aufgabe in die Dashboard-Liste.
        let sortedPeriods = periods.sorted { $0.day1Date > $1.day1Date }
        var cycleInputs: [DueItemBuilder.CycleInput] = []

        if pet.tracksCycle {
            if let latest = sortedPeriods.first {
                prediction = CycleIntervalPredictor(dayMath: dayMath).predictNextCycle(
                    history: CycleHistory(
                        day1Anchors: sortedPeriods.map(\.day1Date),
                        sizeClass: pet.effectiveSizeClass
                    ),
                    asOf: asOf
                )

                let estimate = CyclePhaseEstimator(dayMath: dayMath).estimatePhase(
                    day1: latest.day1Date,
                    signals: latest.phaseSignals,
                    asOf: asOf
                )

                // Anöstrus heißt: die letzte Läufigkeit ist durch. Dann ist die
                // interessante Aussage nicht die Phase, sondern wann die nächste
                // kommt. In jeder anderen Phase läuft der Zyklus gerade.
                if estimate.phase == .anestrus, let prediction {
                    cycle = .forecast(prediction)
                } else {
                    cycle = .running(estimate, day1: latest.day1Date)
                }

                if let prediction {
                    cycleInputs = [
                        DueItemBuilder.CycleInput(
                            sourceID: latest.engineID,
                            petID: pet.engineID,
                            petName: pet.name,
                            prediction: prediction
                        )
                    ]
                }
            } else {
                cycle = .noAnchor
            }
        }

        let items = DueItemBuilder(dayMath: dayMath).build(
            medications: plans.map { $0.engineInput() },
            cycles: cycleInputs,
            asOf: asOf
        )
        let withoutDoses = items.filter { $0.category != .dose }
        tasks = withoutDoses.filter { $0.urgency > .scheduled }
        // Prognosen dürfen hier nicht landen: „Später geplant" zeigt eine nackte
        // Zeile ohne Konfidenzangabe, und eine Prognose ohne Konfidenz ist laut
        // PRD §6 nicht zulässig. Ein Band, das 15–30 Tage entfernt beginnt, fällt
        // genau in diesen Fall — es steht dann in der Zyklus-Karte mit Spanne,
        // Konfidenz und Grundlage, wo es hingehört.
        later = withoutDoses.filter { $0.urgency == .scheduled && $0.category != .cycleForecast }

        for plan in plans where plan.isActive && plan.kindValue.usesEffectivePeriod {
            guard let lastGivenOn = plan.lastGivenOn, plan.effectiveDays > 0 else { continue }
            protection[plan.engineID] = calculator.protectionStatus(
                lastGivenOn: lastGivenOn,
                effectiveDays: plan.effectiveDays,
                asOf: asOf
            )
        }

        // Tagesfenster über `DayMath` statt 86400 Sekunden — sonst schneidet
        // eine Zeitumstellung eine Abendgabe ab.
        let endOfDay = dayMath.adding(days: 1, to: asOf).addingTimeInterval(-1)
        var slots: [DoseSlot] = []
        for plan in plans where plan.isActive && plan.kindValue == .ongoing {
            guard let schedule = plan.doseSchedule else { continue }
            for occurrence in calculator.doseOccurrences(schedule: schedule, in: asOf...endOfDay) {
                // Toleranz gegen Sekundenbruchteile aus der Persistenz — der
                // Termin ist minutengenau gemeint.
                let existing = plan.doseLogs.first {
                    abs($0.scheduledAt.timeIntervalSince(occurrence)) < 60
                }
                slots.append(DoseSlot(plan: plan, scheduledAt: occurrence, existingLog: existing))
            }
        }
        doses = slots.sorted { $0.scheduledAt < $1.scheduledAt }
    }
}

/// Zustand des Zyklus-Abschnitts. Drei Fälle, weil sie drei verschiedene Dinge
/// anzeigen — nicht denselben Inhalt in drei Varianten.
private enum CycleStatus {
    /// Eine Läufigkeit läuft: geschätzte Phase samt Tag im Zyklus.
    case running(PhaseEstimate, day1: Date)
    /// Zwischen zwei Läufigkeiten: Prognose als Spanne.
    case forecast(CyclePrediction)
    /// Noch kein Tag-1-Anker erfasst — ohne ihn ist keine Aussage möglich.
    case noAnchor
}

/// Eine heute fällige Einzelgabe samt bereits erfasster Quittung.
private struct DoseSlot: Identifiable {
    let plan: MedicationPlan
    let scheduledAt: Date
    let existingLog: DoseLogEntry?

    var id: String { "\(plan.engineID)-\(scheduledAt.timeIntervalSince1970)" }
    var isTaken: Bool { existingLog != nil }
}

// MARK: - Zeilen

/// Eine offene Aufgabe. Nimmt nur Value-Types und einen Callback, damit sie
/// ohne ModelContext in der Preview läuft.
private struct DueItemRow: View {
    let item: DueItem
    let title: String
    let symbolName: String
    let protection: ProtectionStatus?
    /// Nur bei Prognosen gesetzt: eine Spanne ohne Konfidenz ist laut PRD §6
    /// nicht zulässig.
    let forecastConfidence: Confidence?
    let onLog: (() -> Void)?
    let logActionTitle: String

    @ScaledMetric private var iconWidth: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbolName)
                    .foregroundStyle(item.urgency.tint)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.body.weight(.medium))
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Badge und Fälligkeit brechen bei großer Schrift um, statt
                    // den Titel zu kürzen.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            UrgencyBadge(urgency: item.urgency)
                            dueText
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            UrgencyBadge(urgency: item.urgency)
                            dueText
                        }
                    }
                    if let forecastConfidence {
                        ConfidenceLabel(confidence: forecastConfidence)
                    }
                }

                Spacer(minLength: 0)

                if let onLog {
                    Button(action: onLog) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(logActionTitle): \(title)")
                }
            }

            if let protection {
                ProtectionBar(status: protection)
            }
        }
        .padding(.vertical, 4)
    }

    private var dueText: Text {
        Text(dueDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// „Noch nie gegeben" liefert die Engine als `.overdue` mit
    /// `daysUntilDue == 0`. Daneben „Heute" zu schreiben wäre eine
    /// Beschönigung — in diesem Fall steht nur das Datum.
    private var dueDescription: String {
        if item.urgency == .overdue, item.daysUntilDue == 0 {
            return Format.date(item.dueOn)
        }
        return "\(Format.relativeDue(days: item.daysUntilDue)) · \(Format.date(item.dueOn))"
    }
}

/// Einzelgabe eines Dauermedikaments. Die ganze Zeile ist der Schalter — ein
/// kleines Kästchen zum Treffen wäre auf dem Weg zur Arbeit unbenutzbar.
private struct DoseRow: View {
    let slot: DoseSlot
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: slot.isTaken ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(slot.isTaken ? Color.green : Color.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(productName)
                        .foregroundStyle(.primary)
                        .strikethrough(slot.isTaken, color: .secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(productName), \(Format.time(slot.scheduledAt))")
        .accessibilityValue(slot.isTaken ? "gegeben" : "offen")
        .accessibilityHint(slot.isTaken ? "Doppeltippen, um den Haken zurückzunehmen" : "Doppeltippen, um die Gabe einzutragen")
    }

    private var productName: String {
        slot.plan.productName.isEmpty
            ? Format.label(slot.plan.kindValue)
            : slot.plan.productName
    }

    private var subtitle: String {
        var pieces = [Format.time(slot.scheduledAt)]
        let dose = slot.plan.doseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dose.isEmpty { pieces.append(dose) }
        if let takenAt = slot.existingLog?.takenAt {
            pieces.append("abgehakt \(Format.time(takenAt))")
        }
        return pieces.joined(separator: " · ")
    }
}

// MARK: - Preview

// Nur die Zeilen, mit erfundenen Werten: der Screen selbst ruft die Engine auf,
// deren Bodies noch nicht implementiert sind.
#Preview("Aufgaben-Zeilen") {
    List {
        Section("Offene Aufgaben") {
            DueItemRow(
                item: DueItem(
                    id: "1",
                    sourceID: "1",
                    petID: "p",
                    petName: "Luna",
                    category: .protectionExpiry,
                    title: "Zeckenschutz erneuern",
                    detail: "Bravecto · letzte Gabe 12. Jun.",
                    dueOn: Date(timeIntervalSinceReferenceDate: 807_000_000),
                    daysUntilDue: -3,
                    urgency: .overdue,
                    remainingFraction: 0
                ),
                title: "Zeckenschutz erneuern",
                symbolName: "shield.lefthalf.filled",
                protection: ProtectionStatus(
                    remainingFraction: 0,
                    remainingDays: -3,
                    expiresOn: Date(timeIntervalSinceReferenceDate: 807_000_000),
                    isExpired: true
                ),
                forecastConfidence: nil,
                onLog: {},
                logActionTitle: "Gegeben"
            )

            DueItemRow(
                item: DueItem(
                    id: "2",
                    sourceID: "2",
                    petID: "p",
                    petName: "Luna",
                    category: .cycleForecast,
                    title: "Läufigkeit erwartet",
                    detail: "Spanne 12. – 26. Aug.",
                    dueOn: Date(timeIntervalSinceReferenceDate: 808_000_000),
                    daysUntilDue: 11,
                    urgency: .upcoming,
                    isForecast: true
                ),
                title: "Läufigkeit erwartet",
                symbolName: "drop",
                protection: nil,
                forecastConfidence: .moderate,
                onLog: nil,
                logActionTitle: "Gegeben"
            )
        }
    }
    .listStyle(.insetGrouped)
}
