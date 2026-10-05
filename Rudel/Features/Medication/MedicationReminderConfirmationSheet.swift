import RudelEngine
import SwiftData
import SwiftUI

struct MedicationReminderConfirmationSheet: View {
    let reminderID: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var reminder: MedicationReminder?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Form {
                if let reminder {
                    Section {
                        LabeledContent("Tier", value: reminder.petName)
                        LabeledContent("Medikament", value: reminder.title)
                        if let detail = reminder.detail, !detail.isEmpty { Text(detail) }
                        LabeledContent("Geplant", value: Format.dateTime(reminder.dueAt))
                    }
                    Section {
                        Button("Jetzt als gegeben bestätigen", systemImage: "checkmark.circle.fill") {
                            Task { await confirm(reminder) }
                        }
                        .disabled(isSaving)
                    } footer: {
                        Text("Bestätige erst, wenn du diese Gabe tatsächlich verabreicht hast.")
                    }
                    Section {
                        Button(reminder.category == .dose ? "Gabe auslassen" : "Diesmal auslassen",
                               systemImage: "forward.end") {
                            Task { await skip(reminder) }
                        }
                        .foregroundStyle(RudelTheme.muted)
                        .disabled(isSaving)
                    }
                } else if isLoading {
                    ProgressView("Gabe laden …")
                } else if errorMessage == nil {
                    Text("Diese Erinnerung ist bereits erledigt oder wurde durch einen geänderten Plan ersetzt.")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .rudelFormStyle()
            .navigationTitle("Gabe bestätigen")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .task {
                defer { isLoading = false }
                do {
                    let settings = AppSettings.loadOrCreate(in: context)
                    let notifications = NotificationService()
                    let retained = await notifications.notificationReminders()
                    let (open, _) = try notifications.medicationSchedulingInput(context: context, settings: settings, retaining: retained, asOf: Date())
                    reminder = open.first { $0.id == reminderID }
                }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func confirm(_ reminder: MedicationReminder) async {
        await record { data, settings in
            try data.confirm(reminder, context: context, settings: settings, asOf: Date())
        }
    }

    /// Auslassen beendet den Termin wie eine Bestätigung — der Alarm darf
    /// danach nicht erneut auslösen.
    private func skip(_ reminder: MedicationReminder) async {
        await record { data, settings in
            try data.skip(reminder, context: context, settings: settings, asOf: Date())
        }
    }

    private func record(_ write: (MedicationReminderData, AppSettings) throws -> Bool) async {
        isSaving = true
        defer { isSaving = false }
        let settings = AppSettings.loadOrCreate(in: context)
        do {
            _ = try write(MedicationReminderData(), settings)
            await NotificationService().reschedule(context: context, settings: settings)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
