import Foundation
import RudelEngine
import Testing
import UserNotifications
@testable import Rudel

@MainActor
@Suite("Wiederholte Ersatz-Mitteilungen")
struct NotificationRequestTests {
    @Test("Eine offene Ersatz-Mitteilung überlebt Mitternacht unabhängig vom Alarmregister")
    func fallbackSurvivesMidnightWithoutAlarmRegistry() async throws {
        let fixture = MedicationReminderDataTests()
        let (context, settings, plan, reminder) = try fixture.fixture()
        let system = TestAlarmSystem()
        system.authorization = .denied
        let alarms = MedicationAlarmService(system: system, registry: TestAlarmRegistry())
        let service = NotificationService(dayMath: .utc, alarmService: alarms)
        let item = try #require(service.plannedNotifications(context: context, settings: settings, asOf: fixture.now)
            .first { $0.dueAt == reminder.dueAt })
        let request = NotificationService.request(for: item, reminder: reminder)
        let retained = NotificationService.reminders(from: [request])
        let tomorrow = Fixture.day(2026, 9, 6).addingTimeInterval(60)
        for enabled in [true, false] {
            settings.medicationAlarmsEnabled = enabled
            _ = await alarms.reconcile(reminders: [reminder], configuration: settings.medicationAlarmConfiguration, asOf: fixture.now)
            #expect(try alarms.registeredReminders().isEmpty)
            let (open, _) = try service.medicationSchedulingInput(context: context, settings: settings, retaining: retained, asOf: tomorrow)
            #expect(open.contains { $0.id == reminder.id })
            #expect(service.plannedNotifications(context: context, settings: settings, asOf: tomorrow, reminders: open)
                .contains { $0.dueAt == reminder.dueAt && $0.repeatInterval != nil })
        }
        #expect(plan.doseLogs.isEmpty)
        try fixture.data.confirm(reminder, context: context, settings: settings, asOf: tomorrow)
        let (open, _) = try service.medicationSchedulingInput(context: context, settings: settings, retaining: retained, asOf: tomorrow)
        #expect(!open.contains { $0.id == reminder.id })
    }

    @Test("Ein Abgleich verschiebt den bestehenden Wiederholungs-Countdown nicht")
    func unchangedRetryKeepsExistingRequest() {
        var item = NotificationPlanner.PlannedNotification(
            id: "retry:dose", fireDate: Fixture.day(2026, 9, 5), title: "Gabe offen", body: "Bitte bestätigen",
            petID: "pet", category: .dose, priority: 50, sourceID: "source",
            dueAt: Fixture.day(2026, 9, 4), repeatInterval: 600
        )
        let reminder = MedicationAlarmServiceTests().reminder()
        let existing = NotificationService.request(for: item, reminder: reminder)
        item.fireDate = item.fireDate.addingTimeInterval(300)
        #expect(NotificationService.canKeep(existing, for: NotificationService.request(for: item, reminder: reminder)))
        item.repeatInterval = 900
        #expect(!NotificationService.canKeep(existing, for: NotificationService.request(for: item, reminder: reminder)))
        item.repeatInterval = 600
        item.body = "Geändertes Präparat"
        #expect(!NotificationService.canKeep(existing, for: NotificationService.request(for: item, reminder: reminder)))
    }

    @Test("Zyklushinweise werden nicht als erledigte Medikamentengaben behandelt")
    func cycleNotificationsHaveNoMedicationMarker() {
        let item = NotificationPlanner.PlannedNotification(
            id: "cycle", fireDate: Fixture.logged, title: "Zyklus", body: "Vorhersage",
            petID: "pet", category: .cycleForecast, priority: 10, sourceID: "cycle", dueAt: Fixture.logged
        )
        let request = NotificationService.request(for: item)
        #expect(request.content.userInfo["medicationOccurrence"] == nil)
        #expect(NotificationService.reminders(from: [request]).isEmpty)
    }
}
