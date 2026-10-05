import RudelEngine
import SwiftData
import SwiftUI

/// Einen Vorsorge-Plan zurückstellen — die Zeckentablette im Winter.
///
/// Gespeichert wird nur das Datum; die Engine schiebt die Fälligkeit darauf und
/// meldet sich bis dahin nicht. Eine danach erfasste Gabe oder Auslassung hebt
/// die Zurückstellung von selbst auf (`MedicationPlan.activeDeferral`).
struct MedicationDeferSheet: View {
    let planID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var plan: MedicationPlan?
    @State private var didLoad = false
    @State private var date = Date()

    private var dayMath: DayMath { appState.dayMath }
    private var today: Date { dayMath.startOfDay(Date()) }
    private var tomorrow: Date { dayMath.adding(days: 1, to: today) }

    var body: some View {
        NavigationStack {
            Group {
                if didLoad, let plan {
                    form(plan)
                } else {
                    Color.clear
                }
            }
            .rudelFormStyle()
            .navigationTitle("Zurückstellen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(plan == nil)
                }
            }
            .task { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func form(_ plan: MedicationPlan) -> some View {
        Form {
            Section {
                ForEach(quickOptions) { option in
                    Button {
                        date = option.date
                    } label: {
                        HStack {
                            Text(option.title).foregroundStyle(RudelTheme.ink)
                            Spacer(minLength: 8)
                            Text(Format.date(option.date)).foregroundStyle(RudelTheme.muted)
                            Image(systemName: "checkmark")
                                .foregroundStyle(RudelTheme.accent)
                                .opacity(dayMath.isSameDay(option.date, date) ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("defer-option-\(option.id)")
                    .accessibilityAddTraits(dayMath.isSameDay(option.date, date) ? .isSelected : [])
                }
                DatePicker("Eigenes Datum", selection: $date, in: tomorrow..., displayedComponents: .date)
            } header: {
                Text(MedicationDisplay.title(for: plan))
            }

            if let current = plan.activeDeferral {
                Section {
                    Button("Zurückstellung aufheben", role: .destructive) { clear() }
                } footer: {
                    Text("Zurückgestellt bis \(Format.date(current)).")
                }
            }
        }
    }

    // MARK: Schnellwahl

    private struct QuickOption: Identifiable {
        let id: String
        let title: String
        let date: Date
    }

    private var quickOptions: [QuickOption] {
        let calendar = dayMath.calendar
        let inAMonth = calendar.date(byAdding: .month, value: 1, to: today) ?? dayMath.adding(days: 30, to: today)
        return [
            QuickOption(id: "week", title: "1 Woche", date: dayMath.adding(days: 7, to: today)),
            QuickOption(id: "month", title: "1 Monat", date: dayMath.startOfDay(inAMonth)),
            QuickOption(id: "march", title: "Bis 1. März", date: nextFirstOfMarch)
        ]
    }

    /// Der nächste 1. März, der noch in der Zukunft liegt — dann beginnt die
    /// Zeckensaison wieder. Am 1. März selbst ist es der des Folgejahres.
    private var nextFirstOfMarch: Date {
        let calendar = dayMath.calendar
        let year = calendar.component(.year, from: today)
        for candidateYear in [year, year + 1] {
            if let candidate = calendar.date(from: DateComponents(year: candidateYear, month: 3, day: 1)),
               dayMath.startOfDay(candidate) > today {
                return dayMath.startOfDay(candidate)
            }
        }
        return dayMath.adding(days: 365, to: today)
    }

    // MARK: Laden und Speichern

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let target = planID
        var descriptor = FetchDescriptor<MedicationPlan>(predicate: #Predicate<MedicationPlan> { $0.id == target })
        descriptor.fetchLimit = 1
        guard let existing = (try? context.fetch(descriptor))?.first else {
            dismiss()
            return
        }
        plan = existing
        // Eine laufende Zurückstellung vorbelegen, sonst eine Woche — die
        // kleinste Schnellwahl.
        if let current = existing.activeDeferral, dayMath.startOfDay(current) > today {
            date = dayMath.startOfDay(current)
        } else {
            date = dayMath.adding(days: 7, to: today)
        }
    }

    private func save() {
        guard let plan else { return }
        plan.deferredUntil = dayMath.startOfDay(max(date, tomorrow))
        plan.deferredAt = Date()
        try? context.save()
        MedicationActions.refreshNotifications(context: context)
        dismiss()
    }

    private func clear() {
        guard let plan else { return }
        plan.deferredUntil = nil
        plan.deferredAt = nil
        try? context.save()
        MedicationActions.refreshNotifications(context: context)
        dismiss()
    }
}
