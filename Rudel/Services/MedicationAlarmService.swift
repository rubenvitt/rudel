import Foundation
import Observation
import RudelEngine

@MainActor
@Observable
final class MedicationAlarmService {
    static let shared = MedicationAlarmService(system: NativeMedicationAlarmSystem(), registry: FileMedicationAlarmRegistry())
    static let capacity = 32
    private let system: any MedicationAlarmSystem
    private let registry: any MedicationAlarmRegistry
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var queueToken = UUID()
    private(set) var issue: String?
    private(set) var scheduledCount = 0
    private(set) var authorization: MedicationAlarmAuthorization = .notDetermined

    init(system: any MedicationAlarmSystem, registry: any MedicationAlarmRegistry) {
        self.system = system
        self.registry = registry
    }

    func reconcile(reminders: [MedicationReminder], configuration: MedicationAlarmConfiguration, asOf: Date) async -> Set<String> {
        await enqueue { await self.apply(reminders: reminders, configuration: configuration, asOf: asOf) }
    }

    func registeredReminders() throws -> [MedicationReminder] { try registry.load().map(\.reminder) }

    func registration(id: UUID) throws -> MedicationAlarmRegistration? {
        try registry.load().first { $0.id == id }
    }

    func reportFailure(_ error: Error) {
        issue = "Medikamentenalarme konnten nicht aktualisiert werden: \(error.localizedDescription)"
    }

    func rearmAfterStop(id: UUID, validReminders: [MedicationReminder], configuration: MedicationAlarmConfiguration, asOf: Date) async {
        await enqueue {
            do {
                var records = try self.registry.load()
                guard let old = records.first(where: { $0.id == id }) else { return }
                // Vorsorge darf auch über den Stopp-Knopf eines Altalarms nicht
                // wieder zum Alarm werden.
                guard configuration.enabled,
                      let reminder = validReminders.first(where: { $0.id == old.reminder.id && $0.usesAlarm }) else {
                    if try self.system.currentAlarms()[id] != nil { try self.system.cancel(id: id) }
                    records.removeAll { $0.id == id }
                    try self.registry.save(records)
                    return
                }
                let retry = MedicationAlarmRegistration(
                    id: UUID(), reminder: reminder,
                    fireDate: asOf.addingTimeInterval(Double(configuration.snoozeMinutes * 60)),
                    leadMinutes: configuration.leadMinutes, snoozeMinutes: configuration.snoozeMinutes,
                    isRetry: true
                )
                // Neue ID: Der nachlaufende System-Stopp des alten Alarms darf
                // nicht versehentlich den frisch geplanten Alarm beenden.
                records.append(retry)
                try self.registry.save(records)
                try await self.system.schedule(retry)
                if try self.system.currentAlarms()[id] != nil { try self.system.cancel(id: id) }
                records.removeAll { $0.id == id }
                try self.registry.save(records)
                self.issue = nil
            } catch { self.reportFailure(error) }
        }
    }

    private func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let token = UUID()
        queueToken = token
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        let result = await task.value
        if queueToken == token { tail = nil }
        return result
    }

    private func apply(reminders: [MedicationReminder], configuration: MedicationAlarmConfiguration, asOf: Date) async -> Set<String> {
        // Zweite Sicherung neben `NotificationService`: Vorsorge erzeugt nie
        // einen Alarm. Vor allem anderen gefiltert, damit auch die
        // Kapazitätsmeldung unten nur Alarm-Termine zählt — und ein früher als
        // Alarm registrierter Vorsorge-Termin wie ein erledigter entfernt wird.
        let reminders = reminders.filter(\.usesAlarm)
        issue = nil
        var handled = Set<String>()
        do {
            var current = try system.currentAlarms()
            authorization = system.authorization
            guard configuration.enabled else {
                for id in current.keys { try system.cancel(id: id) }
                try registry.save([])
                scheduledCount = 0
                return []
            }

            var records = try registry.load()

            let desired = prioritized(reminders)
            let desiredIDs = Set(desired.map(\.id))
            // Erst ungültige Alarme entfernen. Fehler werden nicht als
            // erfolgreiche Deaktivierung oder vollständige Planung dargestellt.
            for record in records where !desiredIDs.contains(record.reminder.id) {
                if current[record.id] != nil {
                    try system.cancel(id: record.id)
                    current.removeValue(forKey: record.id)
                }
            }
            records.removeAll { !desiredIDs.contains($0.reminder.id) }
            try registry.save(records)

            if authorization == .notDetermined, !desired.isEmpty {
                authorization = try await system.requestAuthorization()
            }
            guard authorization == .authorized else {
                scheduledCount = 0
                if !desired.isEmpty {
                    issue = "Medikamentenalarme sind nicht erlaubt. Aktuell sind nur normale Mitteilungen möglich."
                }
                return []
            }

            var failures: [String] = []
            for reminder in desired {
                let matches = records.filter { $0.reminder.id == reminder.id }
                // Der neueste Wiederholungsalarm gewinnt auch nach einem
                // Prozessende zwischen Installation und Entfernen der alten ID.
                let old = matches.max { $0.fireDate < $1.fireDate }
                if let old, current[old.id] != nil,
                   old.reminder == reminder,
                   old.leadMinutes == configuration.leadMinutes,
                   old.snoozeMinutes == configuration.snoozeMinutes {
                    handled.insert(reminder.id)
                    for duplicate in matches where duplicate.id != old.id {
                        if current[duplicate.id] != nil { try system.cancel(id: duplicate.id) }
                        records.removeAll { $0.id == duplicate.id }
                    }
                    continue
                }

                let fireDate: Date
                if let old {
                    fireDate = old.fireDate > asOf ? old.fireDate : asOf.addingTimeInterval(Double(configuration.snoozeMinutes * 60))
                } else {
                    fireDate = max(reminder.dueAt, asOf.addingTimeInterval(5))
                }
                let new = MedicationAlarmRegistration(
                    id: UUID(), reminder: reminder, fireDate: fireDate,
                    leadMinutes: configuration.leadMinutes, snoozeMinutes: configuration.snoozeMinutes,
                    isRetry: old?.isRetry == true || reminder.dueAt < asOf
                )
                do {
                    // Vor dem Systemaufruf speichern: jeder ausgelöste Alarm
                    // muss auch nach einem Prozessneustart zuordenbar sein.
                    records.append(new)
                    try registry.save(records)
                    try await system.schedule(new)
                    current[new.id] = .scheduled
                    for replaced in matches {
                        if current[replaced.id] != nil {
                            try system.cancel(id: replaced.id)
                            current.removeValue(forKey: replaced.id)
                        }
                        records.removeAll { $0.id == replaced.id }
                    }
                    try registry.save(records)
                    handled.insert(reminder.id)
                } catch {
                    records.removeAll {
                        $0.reminder.id == reminder.id && $0.id != new.id && current[$0.id] == nil
                    }
                    failures.append("\(reminder.petName) · \(reminder.title): \(error.localizedDescription)")
                }
            }
            try registry.save(records)
            scheduledCount = handled.count
            if reminders.count > desired.count {
                failures.append("Für \(reminders.count - desired.count) weitere Termine sind vorerst nur Mitteilungen vorgesehen.")
            }
            if !failures.isEmpty { issue = failures.joined(separator: "\n") }
        } catch {
            scheduledCount = handled.count
            reportFailure(error)
        }
        return handled
    }

    /// Zunächst die nächste offene Gabe jedes Plans, danach weitere Termine.
    /// Ein enges Dosierschema darf die nächste Gabe eines anderen Tiers nicht
    /// aus dem Alarmbudget verdrängen.
    private func prioritized(_ reminders: [MedicationReminder]) -> [MedicationReminder] {
        let sorted = reminders.sorted { $0.dueAt == $1.dueAt ? $0.id < $1.id : $0.dueAt < $1.dueAt }
        var sources = Set<String>()
        var first: [MedicationReminder] = []
        var rest: [MedicationReminder] = []
        var ids = Set<String>()
        for reminder in sorted where ids.insert(reminder.id).inserted {
            if sources.insert(reminder.sourceID).inserted { first.append(reminder) }
            else { rest.append(reminder) }
        }
        return Array((first + rest).prefix(Self.capacity))
    }
}
