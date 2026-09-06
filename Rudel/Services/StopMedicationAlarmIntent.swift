import AppIntents
import Foundation
import SwiftData

/// AlarmKit führt LiveActivityIntents im App-Prozess aus. Der Systemknopf
/// heißt „Stopp“, deshalb darf diese Aktion niemals eine Gabe protokollieren.
struct StopMedicationAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Medikamentenalarm stoppen" }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Alarm") var alarmID: String

    init() {}
    init(alarmID: String) { self.alarmID = alarmID }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        let service = MedicationAlarmService.shared
        do {
            let container = try RudelPersistence.containerResult.get()
            let context = container.mainContext
            let settings = AppSettings.loadOrCreate(in: context)
            try context.save()
            let now = Date()
            let notifications = NotificationService()
            let retained = await notifications.notificationReminders()
            let (valid, _) = try notifications.medicationSchedulingInput(context: context, settings: settings, retaining: retained, asOf: now)
            await service.rearmAfterStop(id: id, validReminders: valid,
                                         configuration: settings.medicationAlarmConfiguration, asOf: now)
            await notifications.reschedule(context: context, settings: settings)
        } catch { service.reportFailure(error) }
        return .result()
    }
}
