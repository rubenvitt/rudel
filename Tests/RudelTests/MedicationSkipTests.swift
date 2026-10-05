import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Auslassen über `MedicationReminderData` — der Weg aus der
/// Bestätigungsansicht eines Alarms oder einer Mitteilung.
@MainActor
@Suite("Auslassen einer Medikamentengabe")
struct MedicationSkipTests {
    let now = Fixture.day(2026, 9, 5).addingTimeInterval(9 * 3600)
    let data = MedicationReminderData(dayMath: .utc)

    /// Wurmkur, letzte Gabe 01.01., 90 Tage ⇒ seit 01.04. überfällig.
    private func intervalFixture() throws -> (ModelContext, AppSettings, MedicationPlan, MedicationReminder) {
        let context = try makeContext()
        let settings = AppSettings.loadOrCreate(in: context)
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = MedicationPlan(kind: .dewormer, productName: "Milbemax", intervalDays: 90, createdAt: Fixture.logged)
        context.insert(plan)
        plan.pet = pet
        let event = MedicationEvent(givenOn: Fixture.day(2026, 1, 1), loggedAt: Fixture.logged)
        context.insert(event)
        event.plan = plan
        try context.save()
        let reminder = try #require(data.reminders(context: context, settings: settings, asOf: now).first)
        return (context, settings, plan, reminder)
    }

    // MARK: Einzelgabe

    @Test("Eine ausgelassene Gabe wird einmal als ausgelassen erfasst und ist danach erledigt")
    func doseSkipIsIdempotentAndCloses() throws {
        let (context, settings, plan, reminder) = try MedicationReminderDataTests().fixture()
        #expect(try data.skip(reminder, context: context, settings: settings, asOf: now))
        #expect(try !data.skip(reminder, context: context, settings: settings, asOf: now))

        #expect(plan.doseLogs.count == 1)
        let log = try #require(plan.doseLogs.first)
        #expect(log.wasSkipped)
        #expect(log.scheduledAt == reminder.dueAt)
        #expect(log.takenAt == now)

        let remaining = try data.reminders(context: context, settings: settings, retaining: [reminder], asOf: now)
        #expect(!remaining.contains { $0.id == reminder.id })
        // Die Abendgabe bleibt unberührt.
        #expect(remaining.contains { $0.dueAt == Fixture.day(2026, 9, 5).addingTimeInterval(20 * 3600) })
    }

    @Test("Nach dem Auslassen einer Einzelgabe legt Bestätigen keinen zweiten Eintrag an")
    func confirmAfterDoseSkipKeepsSingleEntry() throws {
        let (context, settings, plan, reminder) = try MedicationReminderDataTests().fixture()
        #expect(try data.skip(reminder, context: context, settings: settings, asOf: now))
        #expect(try !data.confirm(reminder, context: context, settings: settings, asOf: now))
        #expect(plan.doseLogs.count == 1)
    }

    @Test("Eine bestätigte Einzelgabe lässt sich nicht nachträglich auslassen")
    func skipAfterDoseConfirmIsNoop() throws {
        let (context, settings, plan, reminder) = try MedicationReminderDataTests().fixture()
        #expect(try data.confirm(reminder, context: context, settings: settings, asOf: now))
        #expect(try !data.skip(reminder, context: context, settings: settings, asOf: now))
        #expect(plan.doseLogs.count == 1)
        #expect(plan.doseLogs.first?.wasSkipped == false)
    }

    // MARK: Intervall-Fälligkeit

    @Test("Auslassen einer Wurmkur schreibt einen Auslassungs-Eintrag und schließt den Termin")
    func intervalSkipWritesSkippedEvent() throws {
        let (context, settings, plan, reminder) = try intervalFixture()
        #expect(try data.skip(reminder, context: context, settings: settings, asOf: now))
        #expect(try !data.skip(reminder, context: context, settings: settings, asOf: now))

        let skipped = plan.events.filter { $0.outcomeValue == .skipped }
        #expect(skipped.count == 1)
        #expect(skipped.first?.givenOn == Fixture.day(2026, 9, 5))
        #expect(skipped.first?.loggedAt == now)
        // Die Auslassung ist keine Gabe.
        #expect(plan.lastGivenOn == Fixture.day(2026, 1, 1))
        #expect(plan.lastSkippedOn == Fixture.day(2026, 9, 5))

        let remaining = try data.reminders(context: context, settings: settings, retaining: [reminder], asOf: now)
        #expect(!remaining.contains { $0.id == reminder.id })
    }

    @Test("Eine Auslassung heute blockiert die echte Bestätigung nicht")
    func skipDoesNotBlockConfirm() throws {
        let (context, settings, plan, reminder) = try intervalFixture()
        #expect(try data.skip(reminder, context: context, settings: settings, asOf: now))
        #expect(try data.confirm(reminder, context: context, settings: settings, asOf: now.addingTimeInterval(600)))
        #expect(try !data.confirm(reminder, context: context, settings: settings, asOf: now.addingTimeInterval(1200)))

        #expect(plan.events.count == 3)
        #expect(plan.events.filter { $0.outcomeValue == .given }.count == 2)
        #expect(plan.lastGivenOn == Fixture.day(2026, 9, 5))
    }

    @Test("Nach einer Bestätigung heute ist Auslassen wirkungslos")
    func skipAfterIntervalConfirmIsNoop() throws {
        let (context, settings, plan, reminder) = try intervalFixture()
        #expect(try data.confirm(reminder, context: context, settings: settings, asOf: now))
        #expect(try !data.skip(reminder, context: context, settings: settings, asOf: now))
        #expect(plan.events.filter { $0.outcomeValue == .skipped }.isEmpty)
    }

    @Test("Ein abgesetzter Plan lässt sich nicht über eine alte Erinnerung auslassen")
    func inactivePlanRejectsSkip() throws {
        let (context, settings, plan, reminder) = try intervalFixture()
        plan.isActive = false
        try context.save()
        #expect(throws: MedicationReminderData.ConfirmationError.self) {
            try data.skip(reminder, context: context, settings: settings, asOf: now)
        }
        #expect(plan.events.count == 1)
    }
}
