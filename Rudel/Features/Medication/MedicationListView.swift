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

    /// Gruppen in fester Reihenfolge über `MedicationKind.allCases`, damit die
    /// Abschnitte nicht die Plätze tauschen, wenn sich eine Fälligkeit ändert.
    private var groups: [KindGroup] {
        let plans = activePlans
        return MedicationKind.allCases.compactMap { kind in
            let matching = plans.filter { $0.kindValue == kind }
            return matching.isEmpty ? nil : KindGroup(kind: kind, plans: matching)
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .sensoryFeedback(.success, trigger: logPulse)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Keine Medikamente", systemImage: "pills")
        } description: {
            Text("Lege einen Plan an — Wurmkur, Zeckenschutz, Tollwut-Impfung oder ein Dauermedikament.")
        } actions: {
            Button("Plan anlegen") {
                appState.present(.editMedicationPlan(planID: nil, petID: pet.id))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
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
                        if expandedPlanIDs.contains(plan.id) {
                            detailRows(for: plan)
                        }
                    }
                } header: {
                    Label(Format.label(group.kind), systemImage: Format.symbolName(group.kind))
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
        .listStyle(.insetGrouped)
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
                    Text(MedicationDisplay.title(for: plan))
                        .font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    if let urgency = status.urgency {
                        UrgencyBadge(urgency: urgency)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
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
        .swipeActions(edge: .trailing) {
            Button {
                appState.present(.editMedicationPlan(planID: plan.id, petID: pet.id))
            } label: {
                Label("Bearbeiten", systemImage: "pencil")
            }
            .tint(.blue)
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
        let isDone = doseLog(for: plan, at: occurrence) != nil
        return Button {
            toggleDose(plan: plan, occurrence: occurrence)
        } label: {
            Label(Format.time(occurrence), systemImage: isDone ? "checkmark.circle.fill" : "circle")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isDone ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12),
                    in: .capsule
                )
                .foregroundStyle(isDone ? Color.green : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Gabe \(Format.time(occurrence))")
        .accessibilityValue(isDone ? "abgehakt" : "offen")
        .accessibilityHint(isDone ? "Abhaken zurücknehmen" : "Als gegeben abhaken")
    }

    /// Die für heute geplanten Gaben. Das Ende der Spanne liegt eine Sekunde vor
    /// Mitternacht, damit eine auf 00:00 gelegte Gabe von morgen nicht mitkommt.
    private func todaysDoses(for plan: MedicationPlan) -> [Date] {
        guard let schedule = plan.doseSchedule else { return [] }
        let start = appState.dayMath.startOfDay(now)
        let end = appState.dayMath.adding(days: 1, to: start).addingTimeInterval(-1)
        return MedicationCalculator(dayMath: appState.dayMath)
            .doseOccurrences(schedule: schedule, in: start...end)
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

        let history = MedicationDisplay.history(for: plan)
        Text("Gaben")
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
                Text("Abgehakte Einzelgaben")
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
            Text("abgehakt \(Format.dateTime(entry.takenAt))")
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

    private func toggleDose(plan: MedicationPlan, occurrence: Date) {
        if let existing = doseLog(for: plan, at: occurrence) {
            // Kein Häkchen heißt „nicht gegeben" — also wird das Abhaken
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

/// Ein Abschnitt der Liste: eine Art und ihre Pläne.
private struct KindGroup: Identifiable {
    let kind: MedicationKind
    let plans: [MedicationPlan]
    var id: MedicationKind { kind }
}

// Kein `#Preview`: die Zeilen rufen `MedicationCalculator` auf, dessen Bodies
// noch `fatalError` werfen — eine Vorschau würde nur den Absturz zeigen.
