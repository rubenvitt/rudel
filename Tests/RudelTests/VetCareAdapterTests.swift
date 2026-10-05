import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Die neuen Felder der Umsetzung `MedicationPlan` → Engine-Input und
/// `VetAppointment` → `AppointmentInput`.
///
/// Wie beim bestehenden Adapter liegt das Risiko in Konventionen: `nil` heißt
/// „Standard der Art", eine Auslassung ist keine Gabe, eine Zurückstellung gilt
/// nur bis zum nächsten Journal-Eintrag.
@MainActor
@Suite("Vorsorge und Tierarzt → Engine-Input")
struct VetCareAdapterTests {

    private func makePlan(
        _ kind: MedicationKind, in context: ModelContext, pet: Pet? = nil
    ) -> MedicationPlan {
        let plan = MedicationPlan(kind: kind, productName: "Präparat", intervalDays: 90, createdAt: Fixture.logged)
        context.insert(plan)
        plan.pet = pet
        return plan
    }

    private func addEvent(
        _ plan: MedicationPlan, on day: Date, outcome: MedicationEventOutcome = .given,
        loggedAt: Date = Fixture.logged, in context: ModelContext
    ) {
        let event = MedicationEvent(givenOn: day, outcome: outcome, loggedAt: loggedAt)
        context.insert(event)
        event.plan = plan
    }

    // MARK: Erinnerungsklasse

    @Test("Ohne Override gilt der Standard der Art")
    func careClassDefaultsPerKind() throws {
        let context = try makeContext()
        let expected: [MedicationKind: MedicationCareClass] = [
            .ongoing: .timeCritical,
            .dewormer: .preventive,
            .tickProtection: .preventive,
            .rabiesVaccination: .preventive,
            .vaccination: .preventive,
        ]
        for (kind, careClass) in expected {
            let plan = makePlan(kind, in: context)
            try context.save()
            #expect(plan.careClassOverride == nil)
            #expect(plan.engineInput().careClass == careClass, "\(kind)")
        }
    }

    @Test("Ein Override schlägt den Standard der Art")
    func careClassOverrideWins() throws {
        let context = try makeContext()
        let plan = makePlan(.ongoing, in: context)
        plan.careClassOverride = .preventive
        try context.save()
        #expect(plan.engineInput().careClass == .preventive)
    }

    // MARK: Tierarzttermin nötig

    @Test("Tollwut braucht standardmäßig einen Termin, Wurmkur nicht")
    func requiresVetVisitDefaultsToRabies() throws {
        let context = try makeContext()
        let rabies = makePlan(.rabiesVaccination, in: context)
        let dewormer = makePlan(.dewormer, in: context)
        try context.save()
        #expect(rabies.engineInput().requiresVetVisit)
        #expect(!dewormer.engineInput().requiresVetVisit)

        rabies.requiresVetVisitOverride = false
        dewormer.requiresVetVisitOverride = true
        try context.save()
        #expect(!rabies.engineInput().requiresVetVisit)
        #expect(dewormer.engineInput().requiresVetVisit)
    }

    // MARK: Auslassen

    @Test("Eine Auslassung ist lastSkippedOn, aber nie lastGivenOn")
    func skipIsNotAGift() throws {
        let context = try makeContext()
        let plan = makePlan(.tickProtection, in: context)
        addEvent(plan, on: Fixture.day(2026, 1, 1), in: context)
        addEvent(plan, on: Fixture.day(2026, 4, 1), outcome: .skipped, in: context)
        try context.save()

        let input = plan.engineInput()
        #expect(input.lastGivenOn == Fixture.day(2026, 1, 1))
        #expect(input.lastSkippedOn == Fixture.day(2026, 4, 1))
        #expect(plan.lastEvent?.outcomeValue == .given)
    }

    @Test("Ohne Auslassung bleibt lastSkippedOn leer")
    func noSkipMeansNil() throws {
        let context = try makeContext()
        let plan = makePlan(.dewormer, in: context)
        addEvent(plan, on: Fixture.day(2026, 1, 1), in: context)
        try context.save()
        #expect(plan.engineInput().lastSkippedOn == nil)
    }

    // MARK: Zurückstellen

    @Test("Eine Zurückstellung wird durch einen späteren Journal-Eintrag aufgehoben")
    func deferralIsLiftedByLaterEvent() throws {
        let context = try makeContext()
        let plan = makePlan(.tickProtection, in: context)
        let deferredAt = Fixture.day(2026, 10, 1)
        plan.deferredUntil = Fixture.day(2027, 3, 1)
        plan.deferredAt = deferredAt
        // Ein älterer Eintrag ändert nichts.
        addEvent(plan, on: Fixture.day(2026, 9, 1), loggedAt: Fixture.day(2026, 9, 1), in: context)
        try context.save()
        #expect(plan.engineInput().deferredUntil == Fixture.day(2027, 3, 1))

        addEvent(plan, on: Fixture.day(2026, 10, 2), outcome: .skipped, loggedAt: deferredAt.addingTimeInterval(60), in: context)
        try context.save()
        #expect(plan.engineInput().deferredUntil == nil)
    }

    @Test("Eine später abgehakte Einzelgabe hebt die Zurückstellung ebenfalls auf")
    func deferralIsLiftedByLaterDoseLog() throws {
        let context = try makeContext()
        let plan = MedicationPlan(kind: .ongoing, productName: "Gelenk", doseTimesMinutes: [8 * 60],
                                  doseStartDate: Fixture.day(2026, 9, 1), createdAt: Fixture.logged)
        context.insert(plan)
        let deferredAt = Fixture.day(2026, 10, 1)
        plan.deferredUntil = Fixture.day(2026, 11, 1)
        plan.deferredAt = deferredAt
        try context.save()
        #expect(plan.engineInput().deferredUntil == Fixture.day(2026, 11, 1))

        let log = DoseLogEntry(scheduledAt: Fixture.day(2026, 10, 2).addingTimeInterval(8 * 3600),
                               takenAt: deferredAt.addingTimeInterval(86_400))
        context.insert(log)
        log.plan = plan
        try context.save()
        #expect(plan.engineInput().deferredUntil == nil)
    }

    // MARK: Offener Termin

    @Test("Nur ein geplanter Termin zählt als offen — erledigt und abgesagt nicht")
    func onlyPlannedAppointmentIsOpen() throws {
        let context = try makeContext()
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = makePlan(.rabiesVaccination, in: context, pet: pet)
        let appointment = VetAppointment(date: Fixture.day(2026, 10, 20), reason: .vaccination, createdAt: Fixture.logged)
        context.insert(appointment)
        appointment.pet = pet
        appointment.medicationPlan = plan
        try context.save()
        #expect(plan.engineInput().hasOpenAppointment)

        appointment.statusValue = .done
        try context.save()
        #expect(!plan.engineInput().hasOpenAppointment)

        appointment.statusValue = .cancelled
        try context.save()
        #expect(!plan.engineInput().hasOpenAppointment)
    }

    @Test("Ein vergangener, noch nicht abgeschlossener Termin bleibt offen")
    func pastPlannedAppointmentStaysOpen() throws {
        let context = try makeContext()
        let plan = makePlan(.rabiesVaccination, in: context)
        let appointment = VetAppointment(date: Fixture.day(2020, 1, 1), createdAt: Fixture.logged)
        context.insert(appointment)
        appointment.medicationPlan = plan
        try context.save()
        #expect(plan.engineInput().hasOpenAppointment)
    }

    // MARK: VetAppointment → AppointmentInput

    @Test("Ein geplanter Termin wird vollständig umgesetzt, Detail ist der Praxisname")
    func appointmentInputCarriesPracticeName() throws {
        let context = try makeContext()
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = makePlan(.rabiesVaccination, in: context, pet: pet)
        let practice = VetPractice(name: "Praxis am Park", createdAt: Fixture.logged)
        context.insert(practice)
        let at = Fixture.day(2026, 10, 20).addingTimeInterval(10.5 * 3600)
        let appointment = VetAppointment(date: at, reason: .vaccination, createdAt: Fixture.logged)
        context.insert(appointment)
        appointment.pet = pet
        appointment.practice = practice
        appointment.medicationPlan = plan
        try context.save()

        let input = try #require(appointment.engineInput())
        #expect(input.sourceID == appointment.engineID)
        #expect(input.petID == pet.engineID)
        #expect(input.petName == "Zola")
        #expect(input.title == "Impfung")
        #expect(input.detail == "Praxis am Park")
        #expect(input.at == at)
        #expect(input.linkedMedicationSourceID == plan.engineID)
    }

    @Test("Ohne Praxis oder mit leerem Praxisnamen gibt es kein Detail")
    func appointmentWithoutPracticeHasNoDetail() throws {
        let context = try makeContext()
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let appointment = VetAppointment(date: Fixture.day(2026, 10, 20), title: "  Kontrolle Pfote ", createdAt: Fixture.logged)
        context.insert(appointment)
        appointment.pet = pet
        try context.save()
        #expect(appointment.engineInput()?.detail == nil)
        #expect(appointment.engineInput()?.title == "Kontrolle Pfote")

        let unnamed = VetPractice(createdAt: Fixture.logged)
        context.insert(unnamed)
        appointment.practice = unnamed
        try context.save()
        #expect(appointment.engineInput()?.detail == nil)
    }

    @Test("Erledigte, abgesagte und tierlose Termine erscheinen nicht")
    func closedOrOrphanedAppointmentsAreSkipped() throws {
        let context = try makeContext()
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let done = VetAppointment(date: Fixture.day(2026, 10, 20), status: .done, createdAt: Fixture.logged)
        let cancelled = VetAppointment(date: Fixture.day(2026, 10, 21), status: .cancelled, createdAt: Fixture.logged)
        let orphan = VetAppointment(date: Fixture.day(2026, 10, 22), createdAt: Fixture.logged)
        for appointment in [done, cancelled, orphan] { context.insert(appointment) }
        done.pet = pet
        cancelled.pet = pet
        try context.save()
        #expect(done.engineInput() == nil)
        #expect(cancelled.engineInput() == nil)
        #expect(orphan.engineInput() == nil)
    }

    // MARK: Löschregeln

    @Test("Löschen einer Praxis lässt ihre Termine als Historie bestehen")
    func deletingPracticeKeepsAppointments() throws {
        let context = try makeContext()
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let practice = VetPractice(name: "Praxis am Park", createdAt: Fixture.logged)
        context.insert(practice)
        pet.primaryPractice = practice
        let appointment = VetAppointment(date: Fixture.day(2026, 10, 20), status: .done, createdAt: Fixture.logged)
        context.insert(appointment)
        appointment.pet = pet
        appointment.practice = practice
        try context.save()

        context.delete(practice)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<VetAppointment>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.practice == nil)
        #expect(pet.primaryPractice == nil)
        #expect(try context.fetch(FetchDescriptor<Pet>()).count == 1)
    }

    @Test("Löschen eines Tiers löscht seine Termine, nicht die Praxis")
    func deletingPetDeletesItsAppointments() throws {
        let context = try makeContext()
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        let other = Pet(name: "Kiano", createdAt: Fixture.logged)
        context.insert(pet)
        context.insert(other)
        let practice = VetPractice(name: "Praxis am Park", createdAt: Fixture.logged)
        context.insert(practice)
        let mine = VetAppointment(date: Fixture.day(2026, 10, 20), createdAt: Fixture.logged)
        let theirs = VetAppointment(date: Fixture.day(2026, 10, 21), createdAt: Fixture.logged)
        context.insert(mine)
        context.insert(theirs)
        mine.pet = pet
        mine.practice = practice
        theirs.pet = other
        try context.save()

        context.delete(pet)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<VetAppointment>())
        #expect(remaining.map(\.id) == [theirs.id])
        #expect(try context.fetch(FetchDescriptor<VetPractice>()).count == 1)
    }
}
