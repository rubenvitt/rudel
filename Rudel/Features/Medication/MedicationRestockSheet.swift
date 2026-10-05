import RudelEngine
import SwiftData
import SwiftUI

/// „Aufgefüllt": neuen Bestand erfassen.
///
/// Gespeichert wird eine neue Zählung (Bestand + Zeitpunkt), kein Zu- oder
/// Abgang — der Restbestand bleibt aus dem Journal abgeleitet
/// (`MedicationPlan.remainingStock`).
struct MedicationRestockSheet: View {
    let planID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var plan: MedicationPlan?
    @State private var didLoad = false
    /// Als Text, damit Komma und Tippen nicht vom Zahlenformat gestört werden.
    @State private var amountText = ""
    /// Restbestand beim Öffnen, Grundlage für „+ 1 Packung".
    @State private var remaining: Double = 0

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
            .navigationTitle("Aufgefüllt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(plan == nil || amount == nil)
                }
            }
            .task { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private var amount: Double? {
        MedicationPlanEditSheet.parseAmount(amountText).flatMap { $0 >= 0 ? $0 : nil }
    }

    private func form(_ plan: MedicationPlan) -> some View {
        Form {
            Section {
                if plan.packageSize > 0 {
                    Button {
                        amountText = Format.amount(max(0, remaining) + plan.packageSize)
                    } label: {
                        HStack {
                            Label("+ 1 Packung", systemImage: "plus.circle.fill")
                            Spacer(minLength: 8)
                            Text(Format.amount(plan.packageSize, unit: plan.stockUnit))
                                .foregroundStyle(RudelTheme.muted)
                        }
                    }
                    .accessibilityIdentifier("restock-add-package")
                }
                HStack {
                    Text("Bestand jetzt")
                    Spacer(minLength: 8)
                    TextField("Bestand", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        .accessibilityIdentifier("restock-amount")
                    if !plan.stockUnit.isEmpty {
                        Text(plan.stockUnit).foregroundStyle(RudelTheme.muted)
                    }
                }
            } header: {
                Text(MedicationDisplay.title(for: plan))
            } footer: {
                Text("Bisher: \(Format.amount(max(0, remaining), unit: plan.stockUnit))")
            }
        }
    }

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
        remaining = existing.remainingStock ?? 0
        // Vorbelegt mit dem bisherigen Rest: ohne Eingabe ändert Speichern nur
        // den Zählzeitpunkt, nicht die Menge.
        amountText = Format.amount(max(0, remaining))
    }

    private func save() {
        guard let plan, let amount else { return }
        MedicationActions.recordStockCount(plan, amount: amount, at: Date())
        try? context.save()
        MedicationActions.refreshNotifications(context: context)
        dismiss()
    }
}
