import Foundation
import RudelEngine
import Testing
@testable import Rudel

@MainActor
@Suite("Medikamentenalarme")
struct MedicationAlarmServiceTests {
    let now = Fixture.day(2026, 9, 5)
    let configuration = MedicationAlarmConfiguration(enabled: true, leadMinutes: 30, snoozeMinutes: 10)

    func reminder() -> MedicationReminder {
        MedicationReminder(id: "dose:test:8", sourceID: "test", petID: "pet", petName: "Zola",
                           title: "Präparat", detail: "1 Tablette", category: .dose,
                           dueAt: now.addingTimeInterval(8 * 3600))
    }

    @Test("Ein normaler Abgleich lässt einen laufenden Schlummer-Countdown unverändert")
    func reconcilePreservesSnooze() async throws {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        let service = MedicationAlarmService(system: system, registry: registry)
        _ = await service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        let registered = try #require(registry.records.first)
        system.alarms[registered.id] = .countdown
        _ = await service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now.addingTimeInterval(9 * 3600))
        #expect(system.scheduled.count == 1)
        #expect(system.cancelled.isEmpty)
        #expect(registry.records.first?.id == registered.id)
    }

    @Test("Stoppen plant dieselbe offene Gabe erneut, ohne sie zu bestätigen")
    func stopRearmsWithNewIdentifier() async throws {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        let service = MedicationAlarmService(system: system, registry: registry)
        _ = await service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        let first = try #require(registry.records.first)
        let stoppedAt = now.addingTimeInterval(8 * 3600)
        await service.rearmAfterStop(id: first.id, validReminders: [reminder()], configuration: configuration, asOf: stoppedAt)
        let retry = try #require(registry.records.first)
        #expect(retry.id != first.id)
        #expect(retry.reminder.id == reminder().id)
        #expect(retry.fireDate == now.addingTimeInterval(8 * 3600 + 600))
        #expect(system.scheduled.last?.id == retry.id)
    }

    @Test("Nach Bestätigung werden Alarm und Registrierung entfernt")
    func confirmedReminderIsRemoved() async throws {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        let service = MedicationAlarmService(system: system, registry: registry)
        _ = await service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        let first = try #require(registry.records.first)
        _ = await service.reconcile(reminders: [], configuration: configuration, asOf: now)
        #expect(system.cancelled.contains(first.id))
        #expect(registry.records.isEmpty)
        await service.rearmAfterStop(id: first.id, validReminders: [], configuration: configuration, asOf: now)
        #expect(system.scheduled.count == 1)
    }

    @Test("Abgelehnte Alarme werden nicht als gesetzt gemeldet")
    func rejectedAlarmIsVisibleAndNotHandled() async {
        let system = TestAlarmSystem()
        system.rejectSchedules = true
        let service = MedicationAlarmService(system: system, registry: TestAlarmRegistry())
        let handled = await service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        #expect(handled.isEmpty)
        #expect(service.issue != nil)
        #expect(service.scheduledCount == 0)
    }

    @Test("Ohne persistierte Zuordnung wird kein Alarm installiert")
    func registryFailurePreventsOrphanAlarm() async {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        registry.rejectWrites = true
        let service = MedicationAlarmService(system: system, registry: registry)
        let handled = await service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        #expect(handled.isEmpty)
        #expect(system.scheduled.isEmpty)
        #expect(service.issue != nil)
    }

    @Test("Berechtigungsentzug erhält die offenen Gaben und meldet die Einschränkung")
    func deniedAuthorizationPreservesPendingRecords() async throws {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        let service = MedicationAlarmService(system: system, registry: registry)
        _ = await service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        system.authorization = .denied
        let handled = await service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        #expect(handled.isEmpty)
        #expect(registry.records.count == 1)
        #expect(service.issue != nil)
    }

    @Test("Abschalten entfernt Systemalarme auch bei unlesbarer Registrierung")
    func disableWorksWithUnreadableRegistry() async {
        let system = TestAlarmSystem()
        let id = UUID()
        system.alarms[id] = .alerting
        let registry = TestAlarmRegistry()
        registry.rejectReads = true
        let service = MedicationAlarmService(system: system, registry: registry)
        _ = await service.reconcile(reminders: [], configuration: .init(enabled: false, leadMinutes: 30, snoozeMinutes: 10), asOf: now)
        #expect(system.cancelled.contains(id))
        #expect(system.alarms.isEmpty)
    }

    @Test("Zwei gleichzeitige Aktualisierungen erzeugen nur einen Systemalarm")
    func concurrentReconcilesAreSerialized() async {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        let service = MedicationAlarmService(system: system, registry: registry)
        async let first = service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        async let second = service.reconcile(reminders: [reminder()], configuration: configuration, asOf: now)
        _ = await (first, second)
        #expect(system.scheduled.count == 1)
        #expect(registry.records.count == 1)
    }
}

@MainActor
final class TestAlarmRegistry: MedicationAlarmRegistry {
    var records: [MedicationAlarmRegistration] = []
    var rejectWrites = false
    var rejectReads = false
    func load() throws -> [MedicationAlarmRegistration] {
        if rejectReads { throw CocoaError(.fileReadCorruptFile) }
        return records
    }
    func save(_ records: [MedicationAlarmRegistration]) throws {
        if rejectWrites { throw CocoaError(.fileWriteOutOfSpace) }
        self.records = records
    }
}

@MainActor
final class TestAlarmSystem: MedicationAlarmSystem {
    var authorization: MedicationAlarmAuthorization = .authorized
    var alarms: [UUID: MedicationAlarmPhase] = [:]
    var scheduled: [MedicationAlarmRegistration] = []
    var cancelled: [UUID] = []
    var rejectSchedules = false
    func requestAuthorization() async throws -> MedicationAlarmAuthorization { authorization }
    func currentAlarms() throws -> [UUID: MedicationAlarmPhase] { alarms }
    func schedule(_ registration: MedicationAlarmRegistration) async throws {
        await Task.yield()
        if rejectSchedules { throw CocoaError(.featureUnsupported) }
        scheduled.append(registration)
        alarms[registration.id] = .scheduled
    }
    func cancel(id: UUID) throws {
        cancelled.append(id)
        alarms.removeValue(forKey: id)
    }
}
