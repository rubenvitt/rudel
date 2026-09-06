import Foundation
import RudelEngine
import SwiftData
import Testing
@testable import Rudel

@MainActor
@Suite("Bestätigung einer Medikamentengabe")
struct MedicationReminderDataTests {
    let now = Fixture.day(2026, 9, 5).addingTimeInterval(9 * 3600)
    let data = MedicationReminderData(dayMath: .utc)

    func fixture() throws -> (ModelContext, AppSettings, MedicationPlan, MedicationReminder) {
        let context = try makeContext()
        let settings = AppSettings.loadOrCreate(in: context)
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = MedicationPlan(kind: .ongoing, productName: "Testpräparat", doseTimesMinutes: [8 * 60, 20 * 60],
                                  doseStartDate: Fixture.day(2026, 9, 4), createdAt: Fixture.logged)
        context.insert(plan)
        plan.pet = pet
        try context.save()
        let reminder = try #require(data.reminders(context: context, settings: settings, asOf: now).first)
        return (context, settings, plan, reminder)
    }

    @Test("Zweimal Bestätigen erzeugt nur einen Eintrag für den richtigen Termin")
    func confirmationIsIdempotent() throws {
        let (context, settings, plan, reminder) = try fixture()
        #expect(try data.confirm(reminder, context: context, settings: settings, asOf: now))
        #expect(try !data.confirm(reminder, context: context, settings: settings, asOf: now))
        #expect(plan.doseLogs.count == 1)
        #expect(plan.doseLogs.first?.scheduledAt == Fixture.day(2026, 9, 5).addingTimeInterval(8 * 3600))
        #expect(plan.doseLogs.first?.takenAt == now)
        let remaining = try data.reminders(context: context, settings: settings, retaining: [reminder], asOf: now)
        #expect(!remaining.contains { $0.id == reminder.id })
        #expect(remaining.contains { $0.dueAt == Fixture.day(2026, 9, 5).addingTimeInterval(20 * 3600) })
    }

    @Test("Die unbestätigte Gabe bleibt auch am nächsten Tag offen")
    func openReminderSurvivesMidnight() throws {
        let (context, settings, _, reminder) = try fixture()
        let reminders = try data.reminders(context: context, settings: settings, retaining: [reminder], asOf: Fixture.day(2026, 9, 6))
        #expect(reminders.contains { $0.id == reminder.id })
    }

    @Test("Ein geänderter Plan entfernt alte Uhrzeiten statt sie weiter zu erinnern")
    func changedScheduleRemovesOldReminder() throws {
        let (context, settings, plan, reminder) = try fixture()
        plan.doseTimesMinutes = [10 * 60]
        try context.save()
        let reminders = try data.reminders(context: context, settings: settings, retaining: [reminder], asOf: Fixture.day(2026, 9, 6))
        #expect(!reminders.contains { $0.id == reminder.id })
        #expect(throws: MedicationReminderData.ConfirmationError.self) {
            try data.confirm(reminder, context: context, settings: settings, asOf: now)
        }
        #expect(plan.doseLogs.isEmpty)
    }

    @Test("Absetzen verhindert Bestätigung über eine alte Live Activity")
    func inactivePlanRejectsOldAction() throws {
        let (context, settings, plan, reminder) = try fixture()
        plan.isActive = false
        try context.save()
        #expect(throws: MedicationReminderData.ConfirmationError.self) {
            try data.confirm(reminder, context: context, settings: settings, asOf: now)
        }
        #expect(plan.doseLogs.isEmpty)
    }

    @Test("Offene Gaben zeigen nach einer Änderung den aktuellen Präparatnamen")
    func retainedReminderUsesCurrentMetadata() throws {
        let (context, settings, plan, reminder) = try fixture()
        plan.productName = "Neues Präparat"
        try context.save()
        let reminders = try data.reminders(context: context, settings: settings, retaining: [reminder], asOf: Fixture.day(2026, 9, 6))
        #expect(reminders.first { $0.id == reminder.id }?.title == "Neues Präparat")
    }

    @Test("Eine Intervallgabe wird einmal bestätigt und beendet den alten Termin")
    func intervalConfirmationAdvancesSchedule() throws {
        let (context, settings, plan, _) = try fixture()
        plan.kindValue = .dewormer
        plan.intervalDays = 90
        let event = MedicationEvent(givenOn: Fixture.day(2026, 1, 1), loggedAt: Fixture.logged)
        context.insert(event)
        event.plan = plan
        try context.save()
        let reminder = try #require(data.reminders(context: context, settings: settings, asOf: now).first)
        #expect(try data.confirm(reminder, context: context, settings: settings, asOf: now))
        #expect(try !data.confirm(reminder, context: context, settings: settings, asOf: now))
        #expect(plan.events.count == 2)
        #expect(try !data.reminders(context: context, settings: settings, retaining: [reminder], asOf: now).contains { $0.id == reminder.id })
    }
}
