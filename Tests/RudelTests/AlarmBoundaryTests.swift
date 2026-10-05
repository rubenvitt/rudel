import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Die Grenze zwischen Vorsorge und Alarm.
///
/// `MedicationReminderPlanner` liefert Termine **aller** Pläne, weil der
/// `NotificationPlanner` Dosis-Mitteilungen nur daraus bildet. Ein Vorsorge-
/// Termin darf deshalb nie bei AlarmKit landen — und darf umgekehrt seine
/// Mitteilung nicht verlieren, weil ihn jemand für „vom Alarm übernommen" hält.
@MainActor
@Suite("Alarmgrenze: Vorsorge nur als Mitteilung")
struct AlarmBoundaryTests {
    let today = Fixture.day(2026, 9, 5)
    let configuration = MedicationAlarmConfiguration(enabled: true, leadMinutes: 30, snoozeMinutes: 10)

    private func reminder(_ id: String, usesAlarm: Bool) -> MedicationReminder {
        MedicationReminder(id: id, sourceID: id, petID: "pet", petName: "Zola", title: "Präparat",
                           category: .dose, dueAt: today.addingTimeInterval(8 * 3600), usesAlarm: usesAlarm)
    }

    /// Dauermedikament mit einer Gabe um 08:00, wahlweise auf Vorsorge gestellt.
    private func makeStore(preventive: Bool) throws -> (ModelContext, AppSettings, MedicationPlan) {
        let context = try makeContext()
        let settings = AppSettings.loadOrCreate(in: context)
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = MedicationPlan(kind: .ongoing, productName: "Gelenktablette", doseTimesMinutes: [8 * 60],
                                  doseStartDate: Fixture.day(2026, 9, 1), createdAt: Fixture.logged)
        context.insert(plan)
        plan.pet = pet
        if preventive { plan.careClassOverride = .preventive }
        try context.save()
        return (context, settings, plan)
    }

    // MARK: Alarmdienst

    @Test("Aus einer gemischten Liste wird nur der zeitkritische Termin zum Alarm")
    func reconcileSchedulesOnlyTimeCritical() async {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        let service = MedicationAlarmService(system: system, registry: registry)
        let critical = reminder("critical", usesAlarm: true)
        let preventive = reminder("preventive", usesAlarm: false)
        let handled = await service.reconcile(reminders: [critical, preventive], configuration: configuration, asOf: today)
        #expect(handled == [critical.id])
        #expect(system.scheduled.map(\.reminder.id) == [critical.id])
        #expect(registry.records.map(\.reminder.id) == [critical.id])
        #expect(service.issue == nil)
    }

    @Test("Ein früher als Alarm registrierter Vorsorge-Termin wird entfernt")
    func formerAlarmForPreventiveIsCancelled() async throws {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        let service = MedicationAlarmService(system: system, registry: registry)
        // Stand vor dem Update: jeder Termin war ein Alarm.
        _ = await service.reconcile(reminders: [reminder("tick", usesAlarm: true)], configuration: configuration, asOf: today)
        let old = try #require(registry.records.first)

        let handled = await service.reconcile(reminders: [reminder("tick", usesAlarm: false)], configuration: configuration, asOf: today)
        #expect(handled.isEmpty)
        #expect(system.cancelled.contains(old.id))
        #expect(registry.records.isEmpty)
    }

    @Test("Der Stopp-Knopf eines Altalarms macht Vorsorge nicht wieder zum Alarm")
    func stopDoesNotRearmPreventive() async throws {
        let system = TestAlarmSystem()
        let registry = TestAlarmRegistry()
        let service = MedicationAlarmService(system: system, registry: registry)
        _ = await service.reconcile(reminders: [reminder("tick", usesAlarm: true)], configuration: configuration, asOf: today)
        let old = try #require(registry.records.first)

        await service.rearmAfterStop(id: old.id, validReminders: [reminder("tick", usesAlarm: false)],
                                     configuration: configuration, asOf: today.addingTimeInterval(8 * 3600))
        #expect(system.scheduled.count == 1)
        #expect(registry.records.isEmpty)
        #expect(system.alarms.isEmpty)
    }

    // MARK: Mitteilungen

    @Test("Ein auf Vorsorge gestelltes Dauermedikament plant Termine ohne Alarm")
    func preventivePlanYieldsNonAlarmReminders() throws {
        let (context, settings, _) = try makeStore(preventive: true)
        let service = NotificationService(dayMath: .utc, alarmService: MedicationAlarmService(system: TestAlarmSystem(), registry: TestAlarmRegistry()))
        let (reminders, _) = try service.medicationSchedulingInput(context: context, settings: settings, asOf: today)
        #expect(!reminders.isEmpty)
        #expect(reminders.allSatisfy { !$0.usesAlarm })
    }

    @Test("Vorsorge behält ihre Dosis-Mitteilung, auch wenn ihre ID fälschlich als Alarm gilt")
    func preventiveKeepsNotificationWithoutAlarmExtras() throws {
        let (context, settings, plan) = try makeStore(preventive: true)
        let service = NotificationService(dayMath: .utc)
        let reminders = try MedicationReminderData(dayMath: .utc).reminders(context: context, settings: settings, asOf: today)
        let first = try #require(reminders.first)
        #expect(!first.usesAlarm)

        let planned = service.plannedNotifications(context: context, settings: settings, asOf: today,
                                                   reminders: reminders, handledByAlarms: Set(reminders.map(\.id)))
        let forPlan = planned.filter { $0.sourceID == plan.engineID }
        #expect(forPlan.contains { $0.category == .dose && $0.fireDate == first.dueAt })
        #expect(!forPlan.contains { $0.id.hasPrefix("advance:") })
    }

    @Test("Eine verpasste Vorsorge-Gabe fragt nicht alle zehn Minuten nach")
    func overduePreventiveHasNoRetry() throws {
        let (context, settings, plan) = try makeStore(preventive: true)
        let service = NotificationService(dayMath: .utc)
        let later = today.addingTimeInterval(9 * 3600)
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: later)
        #expect(!planned.contains { $0.sourceID == plan.engineID && $0.id.hasPrefix("retry:") })
        #expect(!planned.contains { $0.repeatInterval != nil })
    }

    @Test("Ein zeitkritisches Dauermedikament behält Vorwarnung und Ersatz-Erinnerung")
    func timeCriticalKeepsAlarmExtras() throws {
        let (context, settings, plan) = try makeStore(preventive: false)
        let service = NotificationService(dayMath: .utc)
        let reminders = try MedicationReminderData(dayMath: .utc).reminders(context: context, settings: settings, asOf: today)
        #expect(reminders.allSatisfy { $0.usesAlarm })

        let handled = Set(reminders.map(\.id))
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: today,
                                                   reminders: reminders, handledByAlarms: handled)
        let first = try #require(reminders.first)
        #expect(planned.contains { $0.id == "advance:\(first.id)" })
        // Der Alarm übernimmt den Termin selbst.
        #expect(!planned.contains { $0.category == .dose && $0.fireDate == first.dueAt })

        let later = first.dueAt.addingTimeInterval(3600)
        let overdue = service.plannedNotifications(context: context, settings: settings, asOf: later)
        #expect(overdue.contains { $0.sourceID == plan.engineID && $0.id.hasPrefix("retry:") })
    }

    // MARK: Registry

    @Test("Eine Alarmdatei ohne usesAlarm lädt weiter und gilt als Alarm")
    func legacyRegistryFileLoads() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rudel-registry-\(UUID().uuidString)/medication-alarms.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let registry = FileMedicationAlarmRegistry(url: url)
        let record = MedicationAlarmRegistration(
            id: UUID(), reminder: reminder("legacy", usesAlarm: true),
            fireDate: today.addingTimeInterval(8 * 3600), leadMinutes: 30, snoozeMinutes: 10
        )
        try registry.save([record])

        // Das Feld entfernen, wie es in Dateien älterer Versionen fehlt.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var nested = try #require(json[0]["reminder"] as? [String: Any])
        let removed = nested.removeValue(forKey: "usesAlarm")
        #expect(removed != nil)
        json[0]["reminder"] = nested
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let loaded = try registry.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == record.id)
        #expect(loaded.first?.reminder.usesAlarm == true)
        #expect(loaded.first?.reminder.id == "legacy")
    }
}

/// Tierarzttermine in der Mitteilungsplanung.
@MainActor
@Suite("Tierarzttermine → Mitteilungen")
struct AppointmentNotificationTests {
    let asOf = Fixture.day(2026, 10, 5).addingTimeInterval(12 * 3600)
    let service = NotificationService(dayMath: .utc)

    private func makeStore(
        status: AppointmentStatus = .planned, linkTo kind: MedicationKind? = nil
    ) throws -> (ModelContext, AppSettings, VetAppointment, MedicationPlan?) {
        let context = try makeContext()
        let settings = AppSettings.loadOrCreate(in: context)
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let practice = VetPractice(name: "Praxis am Park", createdAt: Fixture.logged)
        context.insert(practice)
        let appointment = VetAppointment(date: Fixture.day(2026, 10, 8).addingTimeInterval(10.5 * 3600),
                                         reason: .vaccination, status: status, createdAt: Fixture.logged)
        context.insert(appointment)
        appointment.pet = pet
        appointment.practice = practice
        var plan: MedicationPlan?
        if let kind {
            let linked = MedicationPlan(kind: kind, productName: "Tollwut", effectiveDays: 365, createdAt: Fixture.logged)
            context.insert(linked)
            linked.pet = pet
            let event = MedicationEvent(givenOn: Fixture.day(2025, 10, 1), loggedAt: Fixture.logged)
            context.insert(event)
            event.plan = linked
            appointment.medicationPlan = linked
            plan = linked
        }
        try context.save()
        return (context, settings, appointment, plan)
    }

    @Test("Ein geplanter Termin meldet sich am Vortag und zum eingestellten Vorlauf")
    func plannedAppointmentIsNotified() throws {
        let (context, settings, appointment, _) = try makeStore()
        settings.appointmentLeadMinutes = 60
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)
            .filter { $0.category == .vetAppointment }
        let start = appointment.date
        #expect(Set(planned.map(\.fireDate)) == [
            Fixture.day(2026, 10, 7).addingTimeInterval(9 * 3600),
            start.addingTimeInterval(-3600),
        ])
        #expect(planned.allSatisfy { $0.sourceID == appointment.engineID && $0.repeatInterval == nil })
        #expect(planned.contains { $0.body.contains("Praxis am Park") })
    }

    @Test("Erledigte Termine erzeugen keine Mitteilung")
    func closedAppointmentIsSilent() throws {
        let (context, settings, _, _) = try makeStore(status: .done)
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)
        #expect(!planned.contains { $0.category == .vetAppointment })
    }

    @Test("Ein offener Termin übernimmt die Erinnerungen der verknüpften Impfung")
    func openAppointmentReplacesMedicationNotifications() throws {
        let (context, settings, appointment, plan) = try makeStore(linkTo: .rabiesVaccination)
        let linked = try #require(plan)
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)
        #expect(planned.contains { $0.category == .vetAppointment })
        #expect(!planned.contains { $0.sourceID == linked.engineID })

        // Ohne offenen Termin meldet sich die Impfung wieder — als Aufforderung,
        // einen Termin zu vereinbaren.
        appointment.statusValue = .cancelled
        try context.save()
        let reopened = service.plannedNotifications(context: context, settings: settings, asOf: asOf)
        #expect(reopened.contains { $0.sourceID == linked.engineID && $0.title.contains("Tierarzttermin vereinbaren") })
    }
}
