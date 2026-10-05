import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Zurückstellung und Auslassung in der App-Schicht: Statuszeile, Dosis-Kapseln,
/// Bearbeiten-Sheet und Zählung im Profil.
@MainActor
@Suite("Zurückstellung und Auslassung in der Anzeige")
struct MedicationDeferralDisplayTests {
    let dayMath = DayMath.utc

    // MARK: Fixtures

    /// Zeckenschutz, gegeben 01.11.2026, 30 Tage ⇒ Schutz bis 01.12.2026,
    /// am 02.11. zurückgestellt bis 01.03.2027.
    private func deferredTickPlan(in context: ModelContext) throws -> MedicationPlan {
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = MedicationPlan(kind: .tickProtection, productName: "Bravecto", effectiveDays: 30, createdAt: Fixture.logged)
        context.insert(plan)
        plan.pet = pet
        let event = MedicationEvent(givenOn: Fixture.day(2026, 11, 1), loggedAt: Fixture.day(2026, 11, 1))
        context.insert(event)
        event.plan = plan
        plan.deferredUntil = Fixture.day(2027, 3, 1)
        plan.deferredAt = Fixture.day(2026, 11, 2)
        try context.save()
        return plan
    }

    /// Dauermedikament 08:00 und 20:00 seit 01.09.2026.
    private func ongoingPlan(in context: ModelContext) throws -> MedicationPlan {
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = MedicationPlan(
            kind: .ongoing,
            productName: "Metacam",
            doseTimesMinutes: [8 * 60, 20 * 60],
            doseStartDate: Fixture.day(2026, 9, 1),
            createdAt: Fixture.logged
        )
        context.insert(plan)
        plan.pet = pet
        try context.save()
        return plan
    }

    // MARK: Schutzende nach verstrichener Zurückstellung

    @Test("Nach verstrichener Zurückstellung nennt die Statuszeile das echte Schutzende",
          arguments: [1, 10])
    func expiredDeferralShowsRealProtectionEnd(day: Int) throws {
        let context = try makeContext()
        let plan = try deferredTickPlan(in: context)
        #expect(plan.activeDeferral != nil)

        let status = MedicationDisplay.status(
            for: plan,
            asOf: Fixture.day(2027, 3, day).addingTimeInterval(9 * 3600),
            dayMath: dayMath
        )
        #expect(!status.dueText.contains("Schutz bis"))
        #expect(status.dueText.hasPrefix("Schutz endete am \(Format.date(Fixture.day(2026, 12, 1)))"))
        #expect(status.dueText.contains(Format.date(Fixture.day(2027, 3, 1))))
        #expect(status.protection?.remainingFraction == 0)
    }

    @Test("Ein laufender Schutz zeigt weiter „Schutz bis\"")
    func runningProtectionKeepsWording() throws {
        let context = try makeContext()
        let plan = try deferredTickPlan(in: context)
        plan.deferredUntil = nil
        plan.deferredAt = nil

        let status = MedicationDisplay.status(
            for: plan,
            asOf: Fixture.day(2026, 11, 20).addingTimeInterval(9 * 3600),
            dayMath: dayMath
        )
        #expect(status.dueText == "Schutz bis \(Format.date(Fixture.day(2026, 12, 1)))")
    }

    // MARK: Dosis-Kapseln

    @Test("Ein zurückgestelltes Dauermedikament hat bis zum Zurückstelltag keine Kapseln")
    func deferredOngoingHasNoDoseCapsules() throws {
        let context = try makeContext()
        let plan = try ongoingPlan(in: context)
        let asOf = Fixture.day(2026, 9, 5).addingTimeInterval(9 * 3600)
        #expect(MedicationDisplay.todaysDoseOccurrences(for: plan, asOf: asOf, dayMath: dayMath).count == 2)

        plan.deferredUntil = Fixture.day(2026, 9, 6)
        plan.deferredAt = Fixture.day(2026, 9, 4)
        #expect(MedicationDisplay.todaysDoseOccurrences(for: plan, asOf: asOf, dayMath: dayMath).isEmpty)

        // Am Tag der Zurückstellung geht es wieder los — wie in der Engine.
        plan.deferredUntil = Fixture.day(2026, 9, 5)
        #expect(MedicationDisplay.todaysDoseOccurrences(for: plan, asOf: asOf, dayMath: dayMath).count == 2)
        let engineDoses = DueItemBuilder(dayMath: dayMath)
            .build(medications: [plan.engineInput()], cycles: [], asOf: asOf)
        #expect(engineDoses.count == 2)
    }

    // MARK: Plan bearbeiten

    @Test("Speichern ohne „Aufheben\" lässt eine nicht angezeigte Zurückstellung stehen")
    func savingWithoutClearKeepsDeferral() throws {
        let context = try makeContext()
        let plan = try deferredTickPlan(in: context)

        MedicationPlanEditSheet.applyDeferralEdit(didClearDeferral: false, to: plan)
        #expect(plan.deferredUntil == Fixture.day(2027, 3, 1))
        #expect(plan.deferredAt == Fixture.day(2026, 11, 2))

        MedicationPlanEditSheet.applyDeferralEdit(didClearDeferral: true, to: plan)
        #expect(plan.deferredUntil == nil)
        #expect(plan.deferredAt == nil)
    }

    // MARK: Profil

    @Test("Auslassungen zählen nicht als Gaben")
    func skipsAreNotCountedAsDoses() throws {
        let context = try makeContext()
        let tick = try deferredTickPlan(in: context)
        let pet = try #require(tick.pet)
        let skippedEvent = MedicationEvent(givenOn: Fixture.day(2026, 12, 1), outcome: .skipped, loggedAt: Fixture.logged)
        context.insert(skippedEvent)
        skippedEvent.plan = tick

        let ongoing = MedicationPlan(
            kind: .ongoing, doseTimesMinutes: [8 * 60], doseStartDate: Fixture.day(2026, 9, 1), createdAt: Fixture.logged
        )
        context.insert(ongoing)
        ongoing.pet = pet
        let taken = DoseLogEntry(scheduledAt: Fixture.day(2026, 9, 2), takenAt: Fixture.day(2026, 9, 2))
        let skippedDose = DoseLogEntry(scheduledAt: Fixture.day(2026, 9, 3), takenAt: Fixture.day(2026, 9, 3), wasSkipped: true)
        context.insert(taken)
        context.insert(skippedDose)
        taken.plan = ongoing
        skippedDose.plan = ongoing
        try context.save()

        let counts = PetProfileView.medicationCounts(of: pet)
        #expect(counts.given == 2)
        #expect(counts.skipped == 2)
    }
}
