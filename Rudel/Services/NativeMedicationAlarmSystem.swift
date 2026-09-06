import AlarmKit
import Foundation
import SwiftUI

@MainActor
struct NativeMedicationAlarmSystem: MedicationAlarmSystem {
    var authorization: MedicationAlarmAuthorization {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws -> MedicationAlarmAuthorization {
        _ = try await AlarmManager.shared.requestAuthorization()
        return authorization
    }

    func currentAlarms() throws -> [UUID: MedicationAlarmPhase] {
        try Dictionary(uniqueKeysWithValues: AlarmManager.shared.alarms.map { alarm in
            let phase: MedicationAlarmPhase
            switch alarm.state {
            case .scheduled: phase = .scheduled
            case .countdown: phase = .countdown
            case .paused: phase = .paused
            case .alerting: phase = .alerting
            @unknown default: phase = .scheduled
            }
            return (alarm.id, phase)
        })
    }

    func schedule(_ registration: MedicationAlarmRegistration) async throws {
        let reminder = registration.reminder
        let title = LocalizedStringResource("\(reminder.petName): \(reminder.title)")
        let snooze = AlarmButton(text: "\(registration.snoozeMinutes) Min. später", textColor: .white, systemImageName: "zzz")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title, secondaryButton: snooze, secondaryButtonBehavior: .countdown)
        } else {
            alert = AlarmPresentation.Alert(
                title: title,
                stopButton: AlarmButton(text: "Stopp", textColor: .white, systemImageName: "stop.circle"),
                secondaryButton: snooze, secondaryButtonBehavior: .countdown
            )
        }
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert, countdown: AlarmPresentation.Countdown(title: title)),
            metadata: MedicationAlarmMetadata(reminderID: reminder.id, petName: reminder.petName, medication: reminder.title,
                                              dose: reminder.detail ?? "", dueAt: reminder.dueAt),
            tintColor: Color.orange
        )
        let lead = registration.isRetry ? registration.snoozeMinutes : registration.leadMinutes
        let configuration = AlarmManager.AlarmConfiguration(
            countdownDuration: Alarm.CountdownDuration(
                preAlert: lead > 0 ? Double(lead * 60) : nil,
                postAlert: Double(registration.snoozeMinutes * 60)
            ),
            schedule: .fixed(registration.fireDate), attributes: attributes,
            stopIntent: StopMedicationAlarmIntent(alarmID: registration.id.uuidString)
        )
        _ = try await AlarmManager.shared.schedule(id: registration.id, configuration: configuration)
    }

    func cancel(id: UUID) throws { try AlarmManager.shared.cancel(id: id) }
}
