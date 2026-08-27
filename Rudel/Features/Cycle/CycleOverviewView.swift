import RudelEngine
import SwiftData
import SwiftUI

/// Zyklus-Übersicht (PRD §5.3, §6.1–6.3).
///
/// Zwei Zustände, die sich gegenseitig ausschließen: Läuft gerade eine
/// Läufigkeit, steht die Phase im Vordergrund; läuft keine, die Prognose der
/// nächsten. Beides immer mit Konfidenz — eine Prognose ohne Konfidenzangabe ist
/// laut PRD §6 nicht zulässig.
struct CycleOverviewView: View {
    var body: some View {
        // Nur unkastrierte Hündinnen — Katzen modelliert die Engine nicht.
        PetScope(title: "Zyklus", cycleTrackingOnly: true) { pet in
            CycleOverviewContent(pet: pet)
        }
    }
}

// MARK: - Inhalt

private struct CycleOverviewContent: View {
    let pet: Pet

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    /// Läufigkeiten kommen über `@Query`, nicht über `pet.cyclePeriods`: die
    /// Query aktualisiert sich verlässlich, wenn ein Sheet einen Datensatz
    /// einfügt. Gefiltert wird in Swift — Beziehungen lassen sich in
    /// `#Predicate` nicht vergleichen, und die Datenmenge ist winzig.
    @Query(sort: \CyclePeriod.day1Date, order: .reverse) private var allPeriods: [CyclePeriod]

    @State private var periodPendingDeletion: CyclePeriod?
    @State private var quickLogFeedback = 0
    @State private var breedingExpanded = false

    // MARK: Ableitungen

    private var dayMath: DayMath { appState.dayMath }
    private var today: Date { dayMath.startOfDay(Date()) }
    private var estimator: CyclePhaseEstimator { CyclePhaseEstimator(dayMath: dayMath) }

    private var periods: [CyclePeriod] {
        allPeriods.filter { $0.pet?.id == pet.id }
    }

    private var latestPeriod: CyclePeriod? { periods.first }

    /// Obergrenze für „sichtbare Hitze läuft noch".
    ///
    /// `CyclePeriod.isVisiblyActive` liefert ohne `visibleHeatEndDate` für immer
    /// `true` — eine nie abgeschlossene Läufigkeit würde sonst nach Monaten noch
    /// als laufend gelten und die Prognose verdecken. Die Grenze ist dieselbe,
    /// die `FertileWindowEstimator` zieht: nach Proöstrus + Östrus in
    /// Maximaldauer ist die sichtbare Hitze sicher vorbei.
    private static let visibleHeatMaxDays = StudyConstants.proestrusMaxDays + StudyConstants.estrusMaxDays

    private var activePeriod: CyclePeriod? {
        guard let latestPeriod, latestPeriod.isVisiblyActive(asOf: today) else { return nil }
        let day = dayMath.days(from: latestPeriod.day1Date, to: today)
        return day < Self.visibleHeatMaxDays ? latestPeriod : nil
    }

    /// Läufigkeit ohne Enddatum, die aus dem plausiblen Fenster gelaufen ist.
    /// Sie ist nicht „aktiv", aber auch nicht abgeschlossen — das Enddatum fehlt
    /// und muss nachtragbar bleiben.
    private var staleOpenPeriod: CyclePeriod? {
        guard let latestPeriod, latestPeriod.visibleHeatEndDate == nil, activePeriod == nil else { return nil }
        return latestPeriod
    }

    private var phaseEstimate: PhaseEstimate? {
        guard let activePeriod else { return nil }
        return estimator.estimatePhase(
            day1: activePeriod.day1Date,
            signals: activePeriod.phaseSignals,
            asOf: today
        )
    }

    /// Alle Tageshinweise der laufenden Läufigkeit, von Tag 1 bis über das Ende
    /// des kritischen Zeitraums hinaus.
    ///
    /// **Eine Quelle für zwei Anzeigen.** Aus derselben Liste kommen der Hinweis
    /// für heute *und* die Grenzen der kritischen Tage. Zwei Aufrufe mit
    /// unterschiedlichen Fenstern könnten auseinanderlaufen, sobald eine
    /// Beobachtung den Beginn verschiebt — und dann stünde auf einem Screen
    /// „kritisch ab Tag 7" neben „heute ist Tag 8, erhöhte Aufmerksamkeit".
    private var criticalNotices: [CriticalDayNotice] {
        guard let activePeriod else { return [] }
        let horizon = dayMath.adding(
            days: Self.visibleHeatMaxDays + CriticalDaysAdvisor.subsidingBufferDays,
            to: activePeriod.day1Date
        )
        return CriticalDaysAdvisor(dayMath: dayMath).notices(
            day1: activePeriod.day1Date,
            signals: activePeriod.phaseSignals,
            visibleHeatEnd: activePeriod.visibleHeatEndDate,
            petName: pet.name,
            sourceID: activePeriod.engineID,
            from: activePeriod.day1Date,
            through: horizon
        )
    }

    /// Der Hinweis für heute. Genau der, den auch die Benachrichtigung trägt —
    /// App und Meldung dürfen zur selben Sache nicht Verschiedenes sagen.
    private var todaysRisk: CriticalDayNotice? {
        criticalNotices.first { dayMath.isSameDay($0.date, today) }
    }

    /// Zeitraum der Stufe `.critical` als Datumsspanne. `nil`, solange die Stufe
    /// im betrachteten Fenster gar nicht vorkommt.
    private var criticalRange: ClosedRange<Date>? {
        let days = criticalNotices.filter { $0.risk == .critical }.map(\.date)
        guard let first = days.first, let last = days.last, first <= last else { return nil }
        return first...last
    }

    private var fertileWindow: FertileWindowEstimate? {
        guard let activePeriod else { return nil }
        return FertileWindowEstimator(dayMath: dayMath).estimate(
            day1: activePeriod.day1Date,
            signals: activePeriod.phaseSignals,
            asOf: today
        )
    }

    private var prediction: CyclePrediction? {
        let anchors = periods.map(\.day1Date)
        guard !anchors.isEmpty else { return nil }
        return CycleIntervalPredictor(dayMath: dayMath).predictNextCycle(
            history: CycleHistory(day1Anchors: anchors, sizeClass: pet.effectiveSizeClass),
            asOf: today
        )
    }

    // MARK: Aufbau

    var body: some View {
        Group {
            if periods.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .confirmationDialog(
            "Läufigkeit löschen?",
            isPresented: deletionDialogBinding,
            titleVisibility: .visible,
            presenting: periodPendingDeletion
        ) { period in
            Button("Löschen", role: .destructive) { delete(period) }
            Button("Abbrechen", role: .cancel) { periodPendingDeletion = nil }
        } message: { period in
            Text(
                "Tag 1 vom \(Format.date(period.day1Date)) und \(observationCountText(period)) werden entfernt. "
                    + "Das verändert jede Prognose, die auf diesem Anker beruht."
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Kein Zyklus erfasst", systemImage: "circle.hexagonpath")
        } description: {
            Text(
                "Erfasse Tag 1 der Läufigkeit — den ersten Tag, an dem sie erkennbar war: "
                    + "sichtbar geschwollene Vulva, blutiger Ausfluss, vermehrtes Belecken oder "
                    + "häufigeres Urinieren. Er ist der Anker, auf dem jede Prognose und jede "
                    + "Risikostufe beruht."
            )
        } actions: {
            Button {
                appState.present(.startCyclePeriod(petID: pet.id))
            } label: {
                Text("Läufigkeit begonnen")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
            if let period = activePeriod, let phase = phaseEstimate {
                // Zuerst das Risiko, dann die Phase: „muss sie heute an der Leine
                // bleiben?" ist die Frage, mit der die App morgens aufgemacht
                // wird. Die Phase ist die Begründung dahinter, nicht die Antwort.
                if let notice = todaysRisk {
                    riskSection(notice)
                }
                activeHeatSection(period: period, phase: phase)
                if let window = fertileWindow {
                    breedingSection(window)
                }
            } else {
                nextHeatSection
            }

            if let stale = staleOpenPeriod {
                openEndSection(stale)
            }

            intervalHistorySection

            historySection
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) { actionBar }
        .sensoryFeedback(.success, trigger: quickLogFeedback)
    }

    // MARK: Risiko

    /// Die Antwort auf „wie sehr muss ich heute aufpassen?".
    ///
    /// Text und Stufe kommen unverändert aus `CriticalDaysAdvisor` — derselben
    /// Quelle, aus der die Benachrichtigung entsteht. Eigene Formulierungen an
    /// dieser Stelle wären eine zweite Wahrheit über dieselbe Sache.
    private func riskSection(_ notice: CriticalDayNotice) -> some View {
        Section {
            RiskHeaderRow(notice: notice)
            if let range = criticalRange {
                LabeledValueRow(
                    label: "Kritische Tage",
                    value: Format.dateRange(range),
                    systemImage: "exclamationmark.octagon"
                )
            }
        } header: {
            Text("Wie sehr aufpassen?")
        } footer: {
            Text(riskFooter(notice))
        }
    }

    /// Warum die Stufe so steht, wie sie steht — und was sie verschiebt.
    private func riskFooter(_ notice: CriticalDayNotice) -> String {
        var text =
            "Der Übergang zum Östrus liegt im Mittel bei Tag 10, die Spanne reicht von Tag "
            + "\(StudyConstants.proestrusMinDays + 1) bis Tag "
            + "\(StudyConstants.proestrusMaxDays + 1). Die kritischen Tage beginnen deshalb schon an "
            + "Tag \(StudyConstants.proestrusTypicalDays) — einen Tag vor dem Mittel, aber bewusst "
            + "nicht am Anfang der Spanne: sonst wäre fast die ganze Läufigkeit kritisch und die "
            + "Stufe sagte nichts mehr.\n\n"
            + "Beobachtetes Flagging, Duldung, strohfarbener Ausfluss oder eine weicher werdende "
            + "Vulva ziehen den Beginn weiter nach vorn — nie nach hinten."
        if notice.risk != .subsiding, activePeriod?.visibleHeatEndDate == nil {
            text += " Ist die sichtbare Hitze vorbei, beendet ein erfasstes Enddatum die Hinweise früher."
        }
        return text
    }

    // MARK: Laufende Läufigkeit

    private func activeHeatSection(period: CyclePeriod, phase: PhaseEstimate) -> some View {
        Section {
            ActiveHeatHeaderRow(phase: phase)

            LabeledValueRow(
                label: "Phase endet voraussichtlich",
                value: Format.dateRange(phase.expectedPhaseEnd),
                systemImage: "calendar"
            )
            LabeledValueRow(
                label: "Tag 1",
                value: "\(Format.date(period.day1Date)) · \(Format.relativePast(days: dayMath.days(from: period.day1Date, to: today)))",
                systemImage: "flag"
            )
            if let end = period.visibleHeatEndDate {
                LabeledValueRow(
                    label: "Sichtbare Hitze beendet",
                    value: Format.date(end),
                    systemImage: "checkmark.circle"
                )
            }

            // Der kürzeste Weg zum wichtigsten Signal: ein Tap, kein Formular.
            if let recorded = recordedStandingHeatToday(in: period) {
                LabeledValueRow(
                    label: "Duldung heute",
                    value: recorded ? "Ja" : "Nein",
                    systemImage: "checkmark.seal"
                )
            } else {
                QuickStandingHeatRow { value in
                    logStandingHeat(value, in: period)
                }
            }
        } header: {
            Text("Läuft gerade")
        } footer: {
            Text("Die Phase ist geschätzt, kein Befund. Eigene Beobachtungen verschieben sie — sie schlagen den Kalender.")
        }
    }

    /// Das fruchtbare Fenster — **eingeklappt und als Deckplanung beschriftet**.
    ///
    /// Es beantwortet nicht die Frage, um die es in dieser App geht. Das Fenster
    /// liegt um den optimalen Deckzeitpunkt und ist je nach Datenlage nur ±1 bis
    /// ±5 Tage breit; der Zeitraum, in dem eine Deckung *aufgehen kann*, ist
    /// deutlich breiter und beginnt früher — Spermien bleiben im Genitaltrakt
    /// mehrere Tage befruchtungsfähig, und schon die Östrus-Grenze streut über
    /// 3 bis 21 Tage. Darum steht hier eine schmalere Spanne als in „Wie sehr
    /// aufpassen?" — die schmalere sieht genauer aus und wäre als Risikoangabe
    /// grob falsch. Wer die beiden nebeneinander gleich groß zeigt, lädt genau
    /// diese Verwechslung ein.
    private func breedingSection(_ estimate: FertileWindowEstimate) -> some View {
        Section {
            DisclosureGroup("Fruchtbares Fenster", isExpanded: $breedingExpanded) {
                LabeledValueRow(
                    label: "Fenster",
                    value: Format.dateRange(estimate.window),
                    systemImage: "calendar.badge.clock"
                )
                LabeledValueRow(
                    label: "Bester Zeitpunkt",
                    value: Format.date(estimate.optimalDate),
                    systemImage: "scope"
                )
                ConfidenceLabel(confidence: estimate.confidence, detail: CycleLabel.source(estimate.source))
                // Pflicht-Caveat: sichtbar daneben, nicht hinter einem Info-Button.
                CycleNoticeRow(text: estimate.caveat)
            }
        } header: {
            Text("Deckplanung")
        } footer: {
            Text(
                "Nur für eine geplante Verpaarung. Ohne Progesteronverlauf ist der Eisprung nicht "
                    + "bestimmbar.\n\n"
                    + "Nicht als Risikozeitraum lesen: Dieses Fenster liegt um den besten "
                    + "Deckzeitpunkt und ist enger als der Zeitraum, in dem eine Deckung aufgehen "
                    + "kann. Wie sehr aufzupassen ist, steht oben."
            )
        }
    }

    // MARK: Prognose

    private var nextHeatSection: some View {
        Section {
            if let prediction = prediction {
                NextHeatHeaderRow(
                    prediction: prediction,
                    daysUntil: dayMath.days(from: today, to: prediction.expectedDate)
                )
                LabeledValueRow(
                    label: "Punktschätzung",
                    value: Format.date(prediction.expectedDate),
                    systemImage: "scope"
                )
                LabeledValueRow(
                    label: "Gerechnetes Intervall",
                    value: Format.dayCount(Int(prediction.effectiveIntervalDays.rounded())),
                    systemImage: "arrow.left.and.right"
                )
                if let last = latestPeriod {
                    LabeledValueRow(
                        label: "Letzter Tag 1",
                        value: Format.date(last.day1Date),
                        systemImage: "flag"
                    )
                }
            }
        } header: {
            Text("Nächste Läufigkeit")
        } footer: {
            Text("Die Spanne ist die Prognose. Die Punktschätzung ist nur ihre Mitte und für sich genommen Scheingenauigkeit.")
        }
    }

    private func openEndSection(_ period: CyclePeriod) -> some View {
        Section {
            Button {
                appState.present(.logCycleObservation(petID: pet.id))
            } label: {
                Label("Ende der sichtbaren Hitze nachtragen", systemImage: "calendar.badge.exclamationmark")
            }
        } footer: {
            Text(
                "Die Läufigkeit vom \(Format.date(period.day1Date)) hat kein Enddatum. "
                    + "Die Prognose funktioniert trotzdem — sie hängt nur am Tag-1-Anker."
            )
        }
    }

    // MARK: Eigene Intervalle

    private var intervalHistorySection: some View {
        Section {
            let intervals = prediction?.observedIntervalDays ?? []
            if intervals.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Noch keine eigenen Intervalle")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "Die Prognose steht auf Populationswerten: \(CycleLabel.populationIntervalSummary). "
                            + "Ab der nächsten erfassten Läufigkeit rechnet die App mit dem eigenen Abstand."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else {
                let scale = max(intervals.max() ?? 0, StudyConstants.day1ToDay1IntervalDays)
                ForEach(intervals.indices, id: \.self) { index in
                    IntervalBarRow(
                        title: intervalTitle(index: index, intervalCount: intervals.count),
                        days: intervals[index],
                        maxDays: scale
                    )
                }
            }
        } header: {
            Text("Eigene Intervalle")
        } footer: {
            Text("Abstand von Tag 1 zu Tag 1. Vergleichswert der Population: \(CycleLabel.populationIntervalSummary).")
        }
    }

    /// Intervall-Beschriftung aus den Ankern. Die Engine wirft doppelt geloggte
    /// Tage heraus, deshalb wird nur mit Daten beschriftet, wenn die Anzahl
    /// aufgeht — sonst hingen falsche Daten an den Balken.
    private func intervalTitle(index: Int, intervalCount: Int) -> String {
        let anchors = periods.map(\.day1Date).sorted()
        guard anchors.count - 1 == intervalCount, index + 1 < anchors.count else {
            return "Intervall \(index + 1)"
        }
        return "\(Format.shortDate(anchors[index])) → \(Format.shortDate(anchors[index + 1]))"
    }

    // MARK: Historie

    private var historySection: some View {
        Section {
            ForEach(periods, id: \.id) { period in
                DisclosureGroup {
                    let observations = Array(period.sortedObservations.reversed())
                    if observations.isEmpty {
                        Text("Keine Beobachtungen erfasst.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(observations, id: \.id) { observation in
                            ObservationSummaryRow(
                                observation: observation,
                                dayInCycle: estimator.dayInCycle(day1: period.day1Date, asOf: observation.date)
                            )
                        }
                    }
                    if !period.note.isEmpty {
                        LabeledValueRow(label: "Notiz", value: period.note, systemImage: "text.alignleft")
                    }
                } label: {
                    PeriodSummaryRow(
                        period: period,
                        dayMath: dayMath,
                        isActive: period.id == activePeriod?.id
                    )
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        periodPendingDeletion = period
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Läufigkeiten")
        } footer: {
            Text("Beobachtungen werden nur ergänzt, nie überschrieben — die Historie bleibt nachvollziehbar.")
        }
    }

    // MARK: Aktion

    private var actionBar: some View {
        Button {
            if activePeriod == nil {
                appState.present(.startCyclePeriod(petID: pet.id))
            } else {
                appState.present(.logCycleObservation(petID: pet.id))
            }
        } label: {
            Label(
                activePeriod == nil ? "Läufigkeit begonnen" : "Beobachtung erfassen",
                systemImage: activePeriod == nil ? "calendar.badge.plus" : "square.and.pencil"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: Schreiben

    /// Bereits erfasste Duldung von heute. `nil` = für heute nicht beantwortet —
    /// nur dann lohnt die Schnellfrage.
    private func recordedStandingHeatToday(in period: CyclePeriod) -> Bool? {
        let match = period.sortedObservations.last { observation in
            dayMath.isSameDay(observation.date, today) && observation.standingHeat != nil
        }
        return match?.standingHeat
    }

    private func logStandingHeat(_ value: Bool, in period: CyclePeriod) {
        let observation = CycleObservation(date: today, standingHeat: value)
        observation.period = period
        context.insert(observation)
        try? context.save()
        quickLogFeedback += 1
    }

    private func delete(_ period: CyclePeriod) {
        context.delete(period)
        try? context.save()
        periodPendingDeletion = nil
    }

    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { periodPendingDeletion != nil },
            set: { if !$0 { periodPendingDeletion = nil } }
        )
    }

    private func observationCountText(_ period: CyclePeriod) -> String {
        let count = period.observations.count
        return count == 1 ? "1 Beobachtung" : "\(count) Beobachtungen"
    }
}

// MARK: - Zeilen

/// Kopfzeile der laufenden Läufigkeit: Tag, Phase, Erklärung, Konfidenz.
private struct ActiveHeatHeaderRow: View {
    let phase: PhaseEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Tag \(phase.dayInCycle)")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Label(Format.label(phase.phase), systemImage: CycleLabel.symbolName(phase.phase))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(CycleLabel.tint(phase.phase).opacity(0.15), in: .capsule)
                    .foregroundStyle(CycleLabel.tint(phase.phase))
            }
            Text(Format.explanation(phase.phase))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ConfidenceLabel(confidence: phase.confidence, detail: CycleLabel.source(phase.source))
        }
        .padding(.vertical, 4)
    }
}

/// Kopfzeile der Risikostufe. Steht als erstes auf dem Screen.
///
/// `notice.phase` wird bewusst **nicht** gerendert: sie stammt allein aus dem
/// Kalender und kann von der Phasenschätzung darunter abweichen (siehe
/// `CriticalDayNotice.phase`). Zwei verschiedene Phasenangaben auf einem Screen
/// wären schlimmer als eine fehlende.
private struct RiskHeaderRow: View {
    let notice: CriticalDayNotice

    var body: some View {
        let tint = CycleLabel.riskTint(notice.risk)
        return VStack(alignment: .leading, spacing: 8) {
            Label(CycleLabel.riskTitle(notice.risk), systemImage: CycleLabel.riskSymbolName(notice.risk))
                .font(.headline)
                .foregroundStyle(tint)
            Text(CycleLabel.riskHeadline(notice.risk))
                .font(.title3.weight(.semibold))
            Text(notice.body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .listRowBackground(tint.opacity(0.10))
        .accessibilityElement(children: .combine)
    }
}

/// Schnellfrage nach der Duldung. Zwei Taps von „App offen" bis „erfasst"
/// (PRD §2) — deshalb hier und nicht nur im Formular.
private struct QuickStandingHeatRow: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Duldet sie heute?")
                .font(.subheadline.weight(.semibold))
            Text(
                "Kein Rüde nötig: mit flacher Hand festen Druck auf die Lendenpartie geben. "
                    + "Duldet sie, bleibt sie stehen, stemmt sich fest und legt den Schwanz zur Seite. "
                    + "Das eindeutigste Östrus-Signal."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    onAnswer(true)
                } label: {
                    Text("Ja").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Duldung heute: ja")

                Button {
                    onAnswer(false)
                } label: {
                    Text("Nein").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Duldung heute: nein")
            }
            .buttonBorderShape(.capsule)
        }
        .padding(.vertical, 4)
    }
}

/// Kopfzeile der Prognose. Die Spanne steht groß, der Punktwert klein darunter —
/// nie umgekehrt.
private struct NextHeatHeaderRow: View {
    let prediction: CyclePrediction
    let daysUntil: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Format.dateRange(prediction.range))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(CycleLabel.predictionTiming(days: daysUntil)) · \(Format.bandWidth(prediction))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ConfidenceLabel(confidence: prediction.confidence, detail: CycleLabel.basis(prediction.basis))
        }
        .padding(.vertical, 4)
    }
}

/// Ein eigenes Intervall als Balken. Macht sichtbar, worauf die Prognose beruht:
/// drei ähnlich lange Balken erklären eine hohe Konfidenz besser als jedes Wort.
private struct IntervalBarRow: View {
    let title: String
    let days: Int
    let maxDays: Int

    private var fraction: Double {
        guard maxDays > 0 else { return 0 }
        return min(1, Double(days) / Double(maxDays))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text(Format.dayCount(days))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geometry.size.width * fraction))
                }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Format.dayCount(days))
    }
}

/// Aufklapp-Zeile einer Läufigkeit.
private struct PeriodSummaryRow: View {
    let period: CyclePeriod
    let dayMath: DayMath
    let isActive: Bool

    private var detail: String {
        var parts: [String] = []
        if let end = period.visibleHeatEndDate {
            let days = dayMath.days(from: period.day1Date, to: end) + 1
            parts.append("Sichtbare Hitze \(Format.dayCount(days)), bis \(Format.shortDate(end))")
        } else {
            parts.append("Ende der sichtbaren Hitze nicht erfasst")
        }
        let count = period.observations.count
        parts.append(count == 1 ? "1 Beobachtung" : "\(count) Beobachtungen")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Format.date(period.day1Date))
                    .font(.body.weight(.medium))
                if isActive {
                    Text("läuft")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if period.pseudopregnancyObserved {
                Label("Anzeichen von Scheinträchtigkeit", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Eine Tagesbeobachtung in der Historie.
private struct ObservationSummaryRow: View {
    let observation: CycleObservation
    let dayInCycle: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.shortDate(observation.date))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text("Tag \(dayInCycle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            let parts = CycleLabel.observationSummary(observation)
            Text(parts.isEmpty ? "Ohne Angaben" : parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !observation.note.isEmpty {
                Text(observation.note)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview("Intervall-Balken") {
    // Statische Werte: die Engine ist hier absichtlich nicht im Spiel.
    List {
        IntervalBarRow(title: "3. Mai → 28. Nov.", days: 209, maxDays: 240)
        IntervalBarRow(title: "28. Nov. → 12. Jul.", days: 226, maxDays: 240)
    }
}
