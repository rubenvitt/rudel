import RudelEngine
import SwiftData
import SwiftUI

/// Alle Medikamentenpläne des gewählten Tiers, gruppiert nach Art (PRD §5.2).
///
/// Der Screen ist auf den häufigsten Handgriff zugeschnitten: eine Gabe
/// dokumentieren. Deshalb liegt „Gegeben" auf der Wisch-Geste nach rechts
/// (ein Zug, kein Formular), und Dauermedikamente zeigen die heutigen
/// Einzelgaben direkt in der Zeile zum Abhaken.
struct MedicationListView: View {
    var body: some View {
        PetScope(title: "Medikamente") { pet in
            MedicationPlanList(pet: pet)
        }
    }
}

// MARK: - Liste

private struct MedicationPlanList: View {
    let pet: Pet

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    /// Welche Pläne ihre Historie zeigen. Bewusst über die Plan-ID statt über
    /// einen `@State` pro Zeile — die Zeilen werden von `ForEach` recycelt.
    @State private var expandedPlanIDs: Set<UUID> = []
    @State private var showsInactive = false
    /// Zählt Eintragungen, damit `sensoryFeedback` einen Auslöser hat.
    @State private var logPulse = 0

    /// Nicht in `@State`: so ist die Fälligkeit bei jedem Neuzeichnen aktuell,
    /// ohne dass ein Timer die Ansicht wachhalten muss.
    private var now: Date { Date() }

    private var activePlans: [MedicationPlan] {
        MedicationDisplay.sortedActivePlans(of: pet, asOf: now, dayMath: appState.dayMath)
    }

    private var inactivePlans: [MedicationPlan] {
        pet.medicationPlans
            .filter { !$0.isActive }
            .sorted {
                MedicationDisplay.title(for: $0)
                    .localizedStandardCompare(MedicationDisplay.title(for: $1)) == .orderedAscending
            }
    }

    /// Gruppen in fester Reihenfolge, damit die Abschnitte nicht die Plätze
    /// tauschen, wenn sich eine Fälligkeit ändert. Tollwut und die übrigen
    /// Impfungen teilen sich den Abschnitt „Impfungen".
    private var groups: [PlanGroup] {
        let plans = activePlans
        return PlanSection.allCases.compactMap { section in
            let matching = plans.filter { PlanSection(kind: $0.kindValue) == section }
            return matching.isEmpty ? nil : PlanGroup(section: section, plans: matching)
        }
    }

    var body: some View {
        Group {
            if pet.medicationPlans.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.present(.editMedicationPlan(planID: nil, petID: pet.id))
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Plan anlegen")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !activePlans.isEmpty {
                Button {
                    appState.present(.quickLogMedication(petID: pet.id))
                } label: {
                    Label("Gabe erfassen", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RudelPrimaryButtonStyle())
                .controlSize(.large)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(RudelTheme.canvas)
            }
        }
        .sensoryFeedback(.success, trigger: logPulse)
    }

    private var emptyState: some View {
        RudelEmptyState(
            title: "Keine Medikamente",
            detail: "Von der Wurmkur bis zur täglichen Gabe: Lege den ersten Plan für \(pet.name.isEmpty ? "dein Tier" : pet.name) an. Rudel behält die Intervalle im Blick.",
            symbol: "pills",
            actionTitle: "Plan anlegen"
        ) {
            appState.present(.editMedicationPlan(planID: nil, petID: pet.id))
        }
    }

    private var list: some View {
        List {
            Section {
                RudelFeatureHeading(
                    eyebrow: pet.name.isEmpty ? "MEDIKAMENTENPLÄNE" : "FÜR \(pet.name.uppercased())",
                    title: "Gaben & Schutz",
                    detail: "\(activePlans.count) \(activePlans.count == 1 ? "aktiver Plan" : "aktive Pläne") · Intervalle und Verlauf",
                    symbol: "pills"
                )
                .rudelFeatureRow()
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.plans) { plan in
                        planRow(plan)
                        // Die Kapseln stehen in einer eigenen Zeile, nicht in
                        // der Planzeile: ein Button innerhalb eines Buttons
                        // bekommt in SwiftUI keine Taps ab.
                        if plan.kindValue == .ongoing {
                            doseRow(for: plan)
                        }
                        appointmentRow(for: plan)
                        stockRow(for: plan)
                        if expandedPlanIDs.contains(plan.id) {
                            detailRows(for: plan)
                        }
                    }
                } header: {
                    Label(group.section.title, systemImage: group.section.symbolName)
                        .labelStyle(.titleAndIcon)
                }
            }

            if !inactivePlans.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsInactive) {
                        ForEach(inactivePlans) { plan in
                            Button {
                                appState.present(.editMedicationPlan(planID: plan.id, petID: pet.id))
                            } label: {
                                inactiveRow(plan)
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Label(
                            "Abgesetzt (\(inactivePlans.count))",
                            systemImage: "archivebox"
                        )
                        .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Abgesetzte Medikamente erzeugen keine Fälligkeiten mehr, ihre Historie bleibt erhalten.")
                }
            }
        }
        .rudelListStyle()
    }

    // MARK: Planzeile

    @ViewBuilder
    private func planRow(_ plan: MedicationPlan) -> some View {
        let status = MedicationDisplay.status(for: plan, asOf: now, dayMath: appState.dayMath)
        let isExpanded = expandedPlanIDs.contains(plan.id)

        Button {
            toggleExpansion(plan)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(plan.kindValue.isVaccination ? MedicationDisplay.vaccineName(for: plan) : MedicationDisplay.title(for: plan))
                        .font(.body.weight(.medium))
                    reminderBadge(plan)
                    Spacer(minLength: 8)
                    if let urgency = status.urgency {
                        UrgencyBadge(urgency: urgency)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }

                // Impfpass: Präparat und letztes Impfdatum stehen mit in der Zeile.
                if let product = MedicationDisplay.vaccineProduct(for: plan) {
                    Text(product)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if plan.kindValue.isVaccination {
                    Text(plan.lastGivenOn.map { "Zuletzt geimpft \(Format.date($0))" } ?? "Keine Impfung dokumentiert")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(status.dueText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let protection = status.protection {
                    ProtectionBar(status: protection)
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Historie einklappen" : "Historie ausklappen")
        .swipeActions(edge: .leading) {
            Button {
                logGiven(plan)
            } label: {
                Label("Gegeben", systemImage: "checkmark.circle.fill")
            }
            .tint(.green)
        }
        // Kein Vollwisch: ein versehentliches Auslassen wäre ein stiller
        // Journal-Eintrag.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                appState.present(.editMedicationPlan(planID: plan.id, petID: pet.id))
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            .tint(.blue)
            if isPreventive(plan) {
                Button {
                    appState.present(.deferMedication(planID: plan.id))
                } label: {
                    Label("Zurückstellen", systemImage: "moon.zzz")
                }
                .tint(.indigo)
                Button {
                    skip(plan)
                } label: {
                    Label("Auslassen", systemImage: "forward")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            Button {
                logGiven(plan)
            } label: {
                Label(plan.usesFecalSampleInstead ? "Abgegeben" : "Gegeben", systemImage: "checkmark.circle")
            }
            if isPreventive(plan) {
                Button {
                    skip(plan)
                } label: {
                    Label("Auslassen", systemImage: "forward")
                }
                Button {
                    appState.present(.deferMedication(planID: plan.id))
                } label: {
                    Label("Zurückstellen", systemImage: "moon.zzz")
                }
            }
            if needsAppointment(plan) {
                Button {
                    appState.present(.editAppointment(appointmentID: nil, petID: pet.id, planID: plan.id))
                } label: {
                    Label("Termin anlegen", systemImage: "calendar.badge.plus")
                }
            }
            Button {
                appState.present(.editMedicationPlan(planID: plan.id, petID: pet.id))
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
        }
    }

    /// Dezenter Hinweis, wie erinnert wird: Wecker für zeitkritische Gaben,
    /// Glocke für Vorsorge. Nur ein Symbol — die Erklärung steht im Plan.
    private func reminderBadge(_ plan: MedicationPlan) -> some View {
        let timeCritical = plan.careClass == .timeCritical
        return Image(systemName: timeCritical ? "alarm" : "bell")
            .font(.caption)
            .foregroundStyle(RudelTheme.muted)
            .accessibilityLabel(timeCritical ? "Mit Alarm" : "Nur Mitteilung")
    }

    /// Auslassen und Zurückstellen gibt es nur für Vorsorge. Ein
    /// Dauermedikament wird Gabe für Gabe abgehakt oder ausgelassen.
    private func isPreventive(_ plan: MedicationPlan) -> Bool {
        plan.careClass == .preventive && plan.kindValue != .ongoing
    }

    /// Die Engine wertet „Termin nötig" bei Dauermedikamenten nicht aus.
    private func needsAppointment(_ plan: MedicationPlan) -> Bool {
        plan.kindValue != .ongoing && plan.requiresVetVisit && plan.openAppointment == nil
    }

    /// Eigene Zeile unter dem Plan: ein Button in der Planzeile bekäme keine
    /// Taps ab. Mit offenem Termin führt sie zum Termin, sonst bietet sie ihn
    /// an — aber erst, wenn die Gabe in Reichweite ist; eine drei Jahre gültige
    /// Impfung soll nicht dauerhaft „Termin anlegen" rufen. Früher geht es über
    /// das Kontextmenü.
    @ViewBuilder
    private func appointmentRow(for plan: MedicationPlan) -> some View {
        if plan.kindValue != .ongoing, let appointment = plan.openAppointment {
            Button {
                appState.present(.editAppointment(appointmentID: appointment.id, petID: pet.id, planID: plan.id))
            } label: {
                HStack {
                    Label(MedicationDisplay.appointmentText(appointment), systemImage: appointment.reasonValue.symbolName)
                        .font(.footnote)
                        .foregroundStyle(RudelTheme.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else if needsAppointment(plan),
                  let urgency = MedicationDisplay.status(for: plan, asOf: now, dayMath: appState.dayMath).urgency,
                  urgency >= .upcoming {
            Button {
                appState.present(.editAppointment(appointmentID: nil, petID: pet.id, planID: plan.id))
            } label: {
                Label("Termin anlegen", systemImage: "calendar.badge.plus")
                    .font(.footnote.weight(.medium))
            }
        }
    }

    /// Eigene Zeile wie der Termin: ein Button in der Planzeile bekäme keine
    /// Taps ab. Knapper Vorrat steht in Warnfarbe und mit Symbol.
    @ViewBuilder
    private func stockRow(for plan: MedicationPlan) -> some View {
        if let text = MedicationDisplay.stockText(for: plan, asOf: now, dayMath: appState.dayMath) {
            let isLow = MedicationDisplay.stockProjection(for: plan, asOf: now, dayMath: appState.dayMath)?.needsRestock == true
            HStack(spacing: 8) {
                Label(text, systemImage: isLow ? "exclamationmark.triangle.fill" : "shippingbox")
                    .font(.footnote)
                    .foregroundStyle(isLow ? RudelTheme.warning : RudelTheme.ink)
                Spacer(minLength: 8)
                Button("Aufgefüllt") {
                    appState.present(.restockMedication(planID: plan.id))
                }
                .buttonStyle(.borderless)
                .font(.footnote.weight(.medium))
                .accessibilityLabel("Aufgefüllt: \(MedicationDisplay.title(for: plan))")
                .accessibilityIdentifier("restock-\(MedicationDisplay.title(for: plan))")
            }
        }
    }

    private func inactiveRow(_ plan: MedicationPlan) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(MedicationDisplay.title(for: plan))
                Text(lastGivenText(plan))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Format.label(plan.kindValue))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func lastGivenText(_ plan: MedicationPlan) -> String {
        guard let lastGivenOn = plan.lastGivenOn else { return "Keine Gabe dokumentiert" }
        return "Zuletzt: \(Format.date(lastGivenOn))"
    }

    // MARK: Einzelgaben eines Dauermedikaments

    /// Die heutigen Gaben als antippbare Kapseln. Das ist der eigentliche
    /// Arbeitsweg bei Dauermedikamenten: ein Tap pro Gabe, kein Formular.
    @ViewBuilder
    private func doseRow(for plan: MedicationPlan) -> some View {
        let occurrences = todaysDoses(for: plan)
        if !occurrences.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Heute abhaken")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Bei großen Textgrößen brechen die Kapseln untereinander um,
                // statt am Rand abgeschnitten zu werden.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(occurrences, id: \.self) { occurrence in
                            doseCapsule(plan: plan, occurrence: occurrence)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(occurrences, id: \.self) { occurrence in
                            doseCapsule(plan: plan, occurrence: occurrence)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func doseCapsule(plan: MedicationPlan, occurrence: Date) -> some View {
        let log = doseLog(for: plan, at: occurrence)
        let isSkipped = log?.wasSkipped == true
        let isDone = log != nil && !isSkipped
        // Eine ausgelassene Gabe ist erledigt, aber nicht gegeben — sie darf
        // nicht wie ein grünes Häkchen aussehen.
        let symbol = isSkipped ? "forward.fill" : (isDone ? "checkmark.circle.fill" : "circle")
        let tint: Color = isSkipped ? RudelTheme.muted : (isDone ? Color.green : Color.primary)
        return Button {
            toggleDose(plan: plan, occurrence: occurrence)
        } label: {
            Label {
                Text(Format.time(occurrence)).strikethrough(isSkipped)
            } icon: {
                Image(systemName: symbol)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isDone ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12),
                in: .capsule
            )
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gabe \(Format.time(occurrence))")
        .accessibilityValue(isSkipped ? "ausgelassen" : (isDone ? "abgehakt" : "offen"))
        .accessibilityHint(isSkipped ? "Auslassung zurücknehmen" : (isDone ? "Abhaken zurücknehmen" : "Als gegeben abhaken"))
    }

    /// Die für heute geplanten Gaben — keine, solange der Plan zurückgestellt ist.
    private func todaysDoses(for plan: MedicationPlan) -> [Date] {
        MedicationDisplay.todaysDoseOccurrences(for: plan, asOf: now, dayMath: appState.dayMath)
    }

    /// Toleranz von einer Minute: der Termin kommt aus der Engine, der
    /// gespeicherte aus einem früheren Lauf — auf die Sekunde zu vergleichen
    /// wäre unnötig streng.
    private func doseLog(for plan: MedicationPlan, at occurrence: Date) -> DoseLogEntry? {
        plan.doseLogs.first { abs($0.scheduledAt.timeIntervalSince(occurrence)) < 60 }
    }

    // MARK: Aufgeklappter Bereich

    @ViewBuilder
    private func detailRows(for plan: MedicationPlan) -> some View {
        ForEach(MedicationDisplay.configuration(for: plan)) { row in
            LabeledValueRow(label: row.label, value: row.value)
                .font(.footnote)
        }

        if !plan.notes.isEmpty {
            Text(plan.notes)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if needsAppointment(plan) {
            Button {
                appState.present(.editAppointment(appointmentID: nil, petID: pet.id, planID: plan.id))
            } label: {
                Label("Termin anlegen", systemImage: "calendar.badge.plus")
                    .font(.footnote)
            }
        }

        let history = MedicationDisplay.history(for: plan)
        Text("Verlauf")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        if history.isEmpty {
            Text("Keine Gabe dokumentiert")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(history) { event in
                eventRow(event)
            }
        }

        if plan.kindValue == .ongoing {
            let doses = MedicationDisplay.doseHistory(for: plan)
            if !doses.isEmpty {
                Text("Einzelgaben")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(doses) { entry in
                    doseLogRow(entry)
                }
            }
        }

        Button {
            appState.present(.editMedicationPlan(planID: plan.id, petID: pet.id))
        } label: {
            Label("Plan bearbeiten", systemImage: "slider.horizontal.3")
                .font(.footnote)
        }
    }

    /// Eine dokumentierte Gabe. Nicht editierbar — das Journal ist append-only
    /// (PRD §8); ein Tippfehler wird gelöscht und neu erfasst.
    private func eventRow(_ event: MedicationEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Format.date(event.givenOn))
                    .font(.footnote)
                if event.outcomeValue == .skipped {
                    Label("Ausgelassen", systemImage: "forward")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(RudelTheme.muted)
                }
                Spacer(minLength: 8)
                Text(Format.relativePast(days: appState.dayMath.days(from: event.givenOn, to: now)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !event.productNameOverride.isEmpty {
                Text(event.productNameOverride)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !event.note.isEmpty {
                Text(event.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(event)
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    private func doseLogRow(_ entry: DoseLogEntry) -> some View {
        HStack {
            Text(Format.dateTime(entry.scheduledAt))
                .font(.footnote)
            Spacer(minLength: 8)
            Text("\(entry.wasSkipped ? "ausgelassen" : "abgehakt") \(Format.dateTime(entry.takenAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(entry)
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    // MARK: Aktionen

    private func toggleExpansion(_ plan: MedicationPlan) {
        withAnimation {
            if expandedPlanIDs.contains(plan.id) {
                expandedPlanIDs.remove(plan.id)
            } else {
                expandedPlanIDs.insert(plan.id)
            }
        }
    }

    /// „Gegeben" mit einem Zug: Tag = heute, kein Formular. Auf Mitternacht
    /// normalisiert, weil die Engine auf Tagesebene rechnet und eine Uhrzeit im
    /// Datum die Fälligkeit verschieben würde.
    private func logGiven(_ plan: MedicationPlan) {
        if plan.kindValue == .ongoing {
            appState.present(.quickLogMedication(petID: pet.id, planID: plan.id))
            return
        }
        let event = MedicationEvent(givenOn: appState.dayMath.startOfDay(Date()))
        context.insert(event)
        event.plan = plan
        try? context.save()
        logPulse += 1
    }

    private func skip(_ plan: MedicationPlan) {
        MedicationActions.skip(plan, context: context, dayMath: appState.dayMath)
        logPulse += 1
    }

    private func toggleDose(plan: MedicationPlan, occurrence: Date) {
        if let existing = doseLog(for: plan, at: occurrence) {
            // Kein Eintrag heißt „offen" — also wird das Abhaken oder Auslassen
            // zurückgenommen, indem der Eintrag verschwindet.
            context.delete(existing)
            try? context.save()
        } else {
            let entry = DoseLogEntry(scheduledAt: occurrence)
            context.insert(entry)
            entry.plan = plan
            try? context.save()
        }
        logPulse += 1
    }

    private func delete(_ event: MedicationEvent) {
        context.delete(event)
        try? context.save()
    }

    private func delete(_ entry: DoseLogEntry) {
        context.delete(entry)
        try? context.save()
    }
}

/// Abschnitte der Liste. Fast eine Art je Abschnitt — nur die Impfungen
/// fassen Tollwut und alle übrigen zum Impfpass zusammen.
private enum PlanSection: CaseIterable, Hashable {
    case dewormer
    case tickProtection
    case ongoing
    case vaccinations

    init(kind: MedicationKind) {
        switch kind {
        case .dewormer: self = .dewormer
        case .tickProtection: self = .tickProtection
        case .ongoing: self = .ongoing
        case .rabiesVaccination, .vaccination: self = .vaccinations
        }
    }

    var title: String {
        switch self {
        case .dewormer: return Format.label(MedicationKind.dewormer)
        case .tickProtection: return Format.label(MedicationKind.tickProtection)
        case .ongoing: return Format.label(MedicationKind.ongoing)
        case .vaccinations: return "Impfungen"
        }
    }

    var symbolName: String {
        switch self {
        case .dewormer: return Format.symbolName(MedicationKind.dewormer)
        case .tickProtection: return Format.symbolName(MedicationKind.tickProtection)
        case .ongoing: return Format.symbolName(MedicationKind.ongoing)
        case .vaccinations: return Format.symbolName(MedicationKind.vaccination)
        }
    }
}

/// Ein Abschnitt der Liste und seine Pläne.
private struct PlanGroup: Identifiable {
    let section: PlanSection
    let plans: [MedicationPlan]
    var id: PlanSection { section }
}

// Kein `#Preview`: die Zeilen rufen `MedicationCalculator` auf, dessen Bodies
// noch `fatalError` werfen — eine Vorschau würde nur den Absturz zeigen.
