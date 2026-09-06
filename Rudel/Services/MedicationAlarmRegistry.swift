import Foundation
import RudelEngine

struct MedicationAlarmConfiguration: Sendable, Equatable {
    var enabled: Bool
    var leadMinutes: Int
    var snoozeMinutes: Int

    init(enabled: Bool, leadMinutes: Int, snoozeMinutes: Int) {
        self.enabled = enabled
        self.leadMinutes = min(120, max(0, leadMinutes))
        self.snoozeMinutes = min(60, max(5, snoozeMinutes))
    }
}

struct MedicationAlarmRegistration: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var reminder: MedicationReminder
    var fireDate: Date
    var leadMinutes: Int
    var snoozeMinutes: Int
    var isRetry: Bool = false
}

enum MedicationAlarmAuthorization: Sendable { case notDetermined, denied, authorized }
enum MedicationAlarmPhase: Sendable { case scheduled, countdown, paused, alerting }

@MainActor
protocol MedicationAlarmRegistry {
    func load() throws -> [MedicationAlarmRegistration]
    func save(_ records: [MedicationAlarmRegistration]) throws
}

/// Atomar und unabhängig vom View-Lebenszyklus gespeichert. Die Extension liest
/// diese Datei nicht; AlarmKit liefert ihre Metadaten direkt an die Live Activity.
@MainActor
struct FileMedicationAlarmRegistry: MedicationAlarmRegistry {
    let url: URL

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Rudel/medication-alarms.json")) {
        self.url = url
    }

    func load() throws -> [MedicationAlarmRegistration] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([MedicationAlarmRegistration].self, from: Data(contentsOf: url))
    }

    func save(_ records: [MedicationAlarmRegistration]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor
protocol MedicationAlarmSystem {
    var authorization: MedicationAlarmAuthorization { get }
    func requestAuthorization() async throws -> MedicationAlarmAuthorization
    func currentAlarms() throws -> [UUID: MedicationAlarmPhase]
    func schedule(_ registration: MedicationAlarmRegistration) async throws
    func cancel(id: UUID) throws
}
