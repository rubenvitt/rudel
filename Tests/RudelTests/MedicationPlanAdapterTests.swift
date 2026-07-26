import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Die Umsetzung `MedicationPlan` → `DueItemBuilder.MedicationInput`.
///
/// Hier laufen zwei Konventionen aufeinander: das Modell kodiert „nicht gesetzt"
/// als `0`, die Engine als `nil`. Ein durchgereichtes `0` wäre kein
/// Compiler-Fehler, sondern eine Wurmkur, die jeden Tag fällig ist.
@MainActor
@Suite("MedicationPlan → Engine-Input")
struct MedicationPlanAdapterTests {

    // MARK: Intervalle: 0 heißt „nicht gesetzt", nicht „null Tage"

    @Test("intervalDays und effectiveDays von 0 werden nil, nicht 0")
    func zeroIntervalsBecomeNil() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .dewormer,
            productName: "Milbemax",
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        #expect(plan.intervalDays == 0)
        #expect(plan.effectiveDays == 0)

        let input = plan.engineInput()
        #expect(input.intervalDays == nil)
        #expect(input.effectiveDays == nil)
    }

    @Test("Gesetzte Intervalle wandern unverändert durch")
    func positiveIntervalsPassThrough() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .tickProtection,
            productName: "Bravecto",
            intervalDays: 90,
            effectiveDays: 30,
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        let input = plan.engineInput()
        #expect(input.intervalDays == 90)
        #expect(input.effectiveDays == 30)
    }

    @Test("Negative Intervalle werden nil — die Grenze ist > 0, nicht != 0")
    func negativeIntervalsBecomeNil() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .dewormer,
            productName: "Kaputter Altbestand",
            intervalDays: -1,
            effectiveDays: -7,
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        let input = plan.engineInput()
        #expect(input.intervalDays == nil)
        #expect(input.effectiveDays == nil)
    }

    // MARK: Letzte Gabe

    @Test("lastGivenOn kommt aus der spätesten Gabe, nicht aus der zuerst eingefügten")
    func lastGivenOnUsesLatestEvent() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .dewormer,
            productName: "Milbemax",
            intervalDays: 90,
            createdAt: Fixture.logged
        )
        context.insert(plan)

        // Die späteste Gabe steht bewusst in der Mitte: so schlägt der Test
        // sowohl bei `events.first` als auch bei `events.last` fehl. Die
        // Reihenfolge von SwiftData-To-Many-Arrays ist ohnehin nicht garantiert
        // — genau deshalb muss der Adapter `max(by:)` benutzen.
        let givenOn = [
            Fixture.day(2026, 5, 20),
            Fixture.day(2026, 7, 1),
            Fixture.day(2026, 2, 1),
        ]
        for date in givenOn {
            let event = MedicationEvent(givenOn: date, loggedAt: Fixture.logged)
            context.insert(event)
            event.plan = plan
        }
        try context.save()

        #expect(plan.events.count == 3)
        #expect(plan.lastEvent?.givenOn == Fixture.day(2026, 7, 1))
        #expect(plan.lastGivenOn == Fixture.day(2026, 7, 1))
        #expect(plan.engineInput().lastGivenOn == Fixture.day(2026, 7, 1))
    }

    @Test("Ohne Gabe bleibt lastGivenOn nil")
    func lastGivenOnIsNilWithoutEvents() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .dewormer,
            productName: "Milbemax",
            intervalDays: 90,
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        #expect(plan.events.isEmpty)
        #expect(plan.lastGivenOn == nil)
        #expect(plan.engineInput().lastGivenOn == nil)
    }

    // MARK: Identität und Stammdaten

    @Test("Plan mit Tier übernimmt engineID, petID und Namen")
    func planWithPetMapsIdentity() throws {
        let context = try makeContext()
        let pet = Pet(name: "Nala", species: .dog, createdAt: Fixture.logged)
        context.insert(pet)
        let plan = MedicationPlan(
            kind: .rabiesVaccination,
            productName: "Nobivac",
            effectiveDays: 1095,
            isActive: false,
            createdAt: Fixture.logged
        )
        context.insert(plan)
        plan.pet = pet
        try context.save()

        let input = plan.engineInput()
        #expect(input.sourceID == plan.id.uuidString)
        #expect(input.petID == pet.id.uuidString)
        #expect(input.petName == "Nala")
        #expect(input.kind == .rabiesVaccination)
        #expect(input.productName == "Nobivac")
        #expect(input.effectiveDays == 1095)
        // Abgesetzt bleibt abgesetzt: der Builder filtert darüber.
        #expect(input.isActive == false)
    }

    @Test("Plan ohne Tier liefert leere petID und leeren Namen")
    func planWithoutPetMapsToEmptyStrings() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .dewormer,
            productName: "Milbemax",
            intervalDays: 90,
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        let input = plan.engineInput()
        #expect(input.petID.isEmpty)
        #expect(input.petName.isEmpty)
    }

    // MARK: Dosierschema

    @Test("doseSchedule bleibt nil, wenn der Plan kein Dauermedikament ist")
    func doseScheduleIsNilForNonOngoingKinds() throws {
        let context = try makeContext()
        for kind in MedicationKind.allCases where kind != .ongoing {
            let plan = MedicationPlan(
                kind: kind,
                productName: "Testpräparat",
                doseTimesMinutes: [480, 1200],
                createdAt: Fixture.logged
            )
            context.insert(plan)
            try context.save()

            #expect(plan.doseSchedule == nil, "\(kind.rawValue) darf kein Dosierschema erzeugen")
            #expect(plan.engineInput().schedule == nil)
        }
    }

    @Test("Dauermedikament ohne Gabezeiten erzeugt kein Schema")
    func doseScheduleIsNilWithoutTimes() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .ongoing,
            productName: "Vetmedin",
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        #expect(plan.doseTimesMinutes.isEmpty)
        #expect(plan.doseSchedule == nil)
        #expect(plan.engineInput().schedule == nil)
    }

    @Test("Gabezeiten werden korrekt in Stunde und Minute zerlegt")
    func doseTimesSplitIntoHourAndMinute() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .ongoing,
            productName: "Vetmedin",
            doseTimesMinutes: [1305, 0, 480, 1439],
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        let schedule = try #require(plan.doseSchedule)
        // `DoseSchedule.init` sortiert die Zeiten — erwartet wird die
        // aufsteigende Reihenfolge, nicht die Eingabereihenfolge.
        // 1305 = 21 * 60 + 45, der Fall, den eine Division durch 100 zerlegen würde.
        #expect(schedule.timesOfDay == [
            TimeOfDay(hour: 0, minute: 0),
            TimeOfDay(hour: 8, minute: 0),
            TimeOfDay(hour: 21, minute: 45),
            TimeOfDay(hour: 23, minute: 59),
        ])
        #expect(schedule.dosesPerDay == 4)
        #expect(plan.engineInput().schedule == schedule)
    }

    @Test("Unplausible Minutenwerte bleiben im gültigen Bereich")
    func outOfRangeDoseMinutesStayValid() throws {
        let context = try makeContext()
        // Solche Werte kann nur ein Fehler oder ein alter Persistenz-Stand
        // liefern; abstürzen oder eine ungültige Uhrzeit erzeugen darf der
        // Adapter deswegen trotzdem nicht (`TimeOfDay` klemmt).
        let plan = MedicationPlan(
            kind: .ongoing,
            productName: "Vetmedin",
            doseTimesMinutes: [-30, 1440, 5000],
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        let schedule = try #require(plan.doseSchedule)
        #expect(schedule.timesOfDay.count == 3)
        for time in schedule.timesOfDay {
            #expect((0...23).contains(time.hour))
            #expect((0...59).contains(time.minute))
        }
    }

    @Test("everyNDays ist niemals kleiner als 1")
    func everyNDaysNeverBelowOne() throws {
        let context = try makeContext()

        // Der Initializer klemmt bereits …
        let clampedByInit = MedicationPlan(
            kind: .ongoing,
            productName: "Vetmedin",
            doseTimesMinutes: [480],
            doseEveryNDays: 0,
            createdAt: Fixture.logged
        )
        context.insert(clampedByInit)
        #expect(clampedByInit.doseEveryNDays == 1)

        // … die Property selbst nicht. Ein Editor-Screen oder ein alter
        // Datenstand darf 0 oder negativ hineinschreiben, ohne dass daraus ein
        // Schema mit Intervall 0 entsteht (Endlosschleife beim Terminaufbau).
        let clampedBySchedule = MedicationPlan(
            kind: .ongoing,
            productName: "Vetmedin",
            doseTimesMinutes: [480],
            createdAt: Fixture.logged
        )
        context.insert(clampedBySchedule)
        try context.save()

        for raw in [0, -3] {
            clampedBySchedule.doseEveryNDays = raw
            let schedule = try #require(clampedBySchedule.doseSchedule)
            #expect(schedule.everyNDays == 1, "doseEveryNDays \(raw) muss auf 1 geklemmt werden")
        }

        clampedBySchedule.doseEveryNDays = 2
        let everySecondDay = try #require(clampedBySchedule.doseSchedule)
        #expect(everySecondDay.everyNDays == 2)
    }

    @Test("Startdatum fällt auf createdAt zurück, gesetztes doseStartDate gewinnt")
    func scheduleStartDateFallsBackToCreatedAt() throws {
        let context = try makeContext()
        let created = Fixture.day(2026, 3, 9)
        let plan = MedicationPlan(
            kind: .ongoing,
            productName: "Vetmedin",
            doseTimesMinutes: [480],
            createdAt: created
        )
        context.insert(plan)
        try context.save()

        let fallback = try #require(plan.doseSchedule)
        #expect(fallback.startDate == created)
        #expect(fallback.endDate == nil)

        let explicitStart = Fixture.day(2026, 4, 1)
        plan.doseStartDate = explicitStart
        let explicit = try #require(plan.doseSchedule)
        #expect(explicit.startDate == explicitStart)
    }

    @Test("Enddatum und Dosis-Beschriftung wandern durch")
    func scheduleCarriesEndDateAndLabel() throws {
        let context = try makeContext()
        let plan = MedicationPlan(
            kind: .ongoing,
            productName: "Vetmedin",
            doseTimesMinutes: [480, 1200],
            doseEveryNDays: 1,
            doseStartDate: Fixture.day(2026, 3, 1),
            doseEndDate: Fixture.day(2026, 9, 30),
            doseLabel: "1/2 Tablette",
            createdAt: Fixture.logged
        )
        context.insert(plan)
        try context.save()

        let schedule = try #require(plan.doseSchedule)
        #expect(schedule.startDate == Fixture.day(2026, 3, 1))
        #expect(schedule.endDate == Fixture.day(2026, 9, 30))
        #expect(schedule.doseLabel == "1/2 Tablette")
    }
}
