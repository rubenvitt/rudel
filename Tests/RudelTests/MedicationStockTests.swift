import Foundation
import RudelEngine
import SwiftData
import Testing
@testable import Rudel

@MainActor
@Suite("Vorrat — Gaben seit der Zählung und Engine-Input")
struct MedicationStockTests {
    let countedAt = Fixture.day(2026, 9, 1).addingTimeInterval(12 * 3600)

    private func makePlan(_ kind: MedicationKind = .ongoing, in context: ModelContext) -> MedicationPlan {
        let pet = Pet(name: "Rex", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = MedicationPlan(
            kind: kind, productName: "Apoquel", intervalDays: kind == .dewormer ? 90 : 0,
            doseTimesMinutes: kind == .ongoing ? [8 * 60, 20 * 60] : [],
            doseStartDate: Fixture.day(2026, 8, 1), createdAt: Fixture.logged
        )
        context.insert(plan)
        plan.pet = pet
        plan.stockCountedAt = countedAt
        plan.stockAmount = 20
        plan.stockUnit = "Tabletten"
        return plan
    }

    private func addEvent(_ plan: MedicationPlan, loggedAt: Date, outcome: MedicationEventOutcome = .given, in context: ModelContext) {
        let event = MedicationEvent(givenOn: Fixture.day(2026, 9, 1), outcome: outcome, loggedAt: loggedAt)
        context.insert(event)
        event.plan = plan
    }

    @discardableResult
    private func addDose(_ plan: MedicationPlan, takenAt: Date, skipped: Bool = false, in context: ModelContext) -> DoseLogEntry {
        let entry = DoseLogEntry(scheduledAt: takenAt, takenAt: takenAt, wasSkipped: skipped)
        context.insert(entry)
        entry.plan = plan
        return entry
    }

    @Test("Gezählt werden echte Gaben und abgehakte Einzelgaben nach der Zählung")
    func countsGivingsSinceCount() throws {
        let context = try makeContext()
        let plan = makePlan(in: context)
        addEvent(plan, loggedAt: countedAt.addingTimeInterval(-60), in: context)           // vor der Zählung
        addEvent(plan, loggedAt: countedAt.addingTimeInterval(60), in: context)            // zählt
        addEvent(plan, loggedAt: countedAt.addingTimeInterval(120), outcome: .skipped, in: context)
        addDose(plan, takenAt: countedAt.addingTimeInterval(-3600), in: context)           // vor der Zählung
        addDose(plan, takenAt: countedAt.addingTimeInterval(3600), in: context)            // zählt
        addDose(plan, takenAt: countedAt.addingTimeInterval(7200), skipped: true, in: context)
        try context.save()

        #expect(plan.givingsSinceStockCount == 2)
        #expect(plan.remainingStock == 18)
    }

    @Test("Ein gelöschter Fehleintrag korrigiert den Bestand von selbst")
    func deletedEntryRestoresStock() throws {
        let context = try makeContext()
        let plan = makePlan(in: context)
        plan.amountPerGiving = 0.5
        addDose(plan, takenAt: countedAt.addingTimeInterval(3600), in: context)
        let mistake = addDose(plan, takenAt: countedAt.addingTimeInterval(3660), in: context)
        try context.save()
        #expect(plan.remainingStock == 19)

        context.delete(mistake)
        try context.save()
        #expect(plan.remainingStock == 19.5)
    }

    @Test("Ohne Zählung keine Vorratsverwaltung und kein Vorrat im Engine-Input")
    func noStockWithoutCount() throws {
        let context = try makeContext()
        let plan = makePlan(in: context)
        plan.stockCountedAt = nil
        try context.save()
        #expect(plan.remainingStock == nil)
        #expect(plan.engineInput(asOf: Fixture.day(2026, 9, 2), dayMath: .utc).stock == nil)
    }

    @Test("engineInput reicht den Vorrat samt heute erfasster Einzelgaben durch")
    func engineInputCarriesStock() throws {
        let context = try makeContext()
        let plan = makePlan(in: context)
        plan.amountPerGiving = 2
        plan.restockLeadDays = 10
        plan.needsPrescription = true
        let today = Fixture.day(2026, 9, 3)
        addDose(plan, takenAt: today.addingTimeInterval(8 * 3600), in: context)
        addDose(plan, takenAt: Fixture.day(2026, 9, 2).addingTimeInterval(8 * 3600), in: context)
        try context.save()

        let stock = try #require(plan.engineInput(asOf: today.addingTimeInterval(10 * 3600), dayMath: .utc).stock)
        #expect(stock.amountAtCount == 20)
        #expect(stock.givingsSinceCount == 2)
        #expect(stock.amountPerGiving == 2)
        #expect(stock.unit == "Tabletten")
        #expect(stock.restockLeadDays == 10)
        #expect(stock.needsPrescription)
        #expect(stock.dosesHandledToday == 1)
        #expect(stock.remainingAmount == 16)
    }

    @Test("„Aufgefüllt“ setzt Bestand und Zählzeitpunkt, ältere Gaben zählen nicht mehr")
    func restockResetsCount() throws {
        let context = try makeContext()
        let plan = makePlan(in: context)
        addDose(plan, takenAt: countedAt.addingTimeInterval(3600), in: context)
        try context.save()
        let restockedAt = countedAt.addingTimeInterval(2 * 3600)
        MedicationActions.recordStockCount(plan, amount: 49, at: restockedAt)
        #expect(plan.stockCountedAt == restockedAt)
        #expect(plan.remainingStock == 49)
    }
}

@MainActor
@Suite("Formular — Impfung und Vorrat speichern")
struct MedicationFormMappingTests {

    @Test("Tollwut speichert die eigene Art ohne Impfung, alles andere .vaccination")
    func rabiesMapping() throws {
        let context = try makeContext()
        let plan = MedicationPlan(kind: .dewormer, createdAt: Fixture.logged)
        context.insert(plan)

        let rabies = VaccineChoice.rabies
        MedicationPlanEditSheet.applyKind(rabies.kind, vaccine: rabies.vaccine, to: plan)
        #expect(plan.kindValue == .rabiesVaccination)
        #expect(plan.vaccineValue == nil)

        let lepto = VaccineChoice.vaccine(.leptospirosis)
        MedicationPlanEditSheet.applyKind(lepto.kind, vaccine: lepto.vaccine, to: plan)
        #expect(plan.kindValue == .vaccination)
        #expect(plan.vaccineValue == .leptospirosis)

        MedicationPlanEditSheet.applyKind(.dewormer, vaccine: .leptospirosis, to: plan)
        #expect(plan.vaccineValue == nil)
    }

    @Test("Ein Bestands-Tollwutplan öffnet als Tollwut")
    func existingRabiesOpensAsRabies() {
        #expect(VaccineChoice(kind: .rabiesVaccination, vaccine: nil) == .rabies)
        #expect(VaccineChoice(kind: .vaccination, vaccine: nil) == .vaccine(.other))
        #expect(VaccineChoice(kind: .tickProtection, vaccine: nil) == nil)
        #expect(VaccineChoice.rabies.defaultValidityDays(for: .dog) == 1095)
        #expect(VaccineChoice.vaccine(.leptospirosis).defaultValidityDays(for: .dog) == 365)
    }

    @Test("Engine-Input trägt die Impfung; Tollwut keine")
    func engineInputVaccine() throws {
        let context = try makeContext()
        let lepto = MedicationPlan(kind: .vaccination, effectiveDays: 365, createdAt: Fixture.logged)
        lepto.vaccineValue = .leptospirosis
        let legacy = MedicationPlan(kind: .vaccination, effectiveDays: 365, createdAt: Fixture.logged)
        let rabies = MedicationPlan(kind: .rabiesVaccination, effectiveDays: 1095, createdAt: Fixture.logged)
        for plan in [lepto, legacy, rabies] { context.insert(plan) }
        try context.save()
        #expect(lepto.engineInput().vaccine == .leptospirosis)
        #expect(legacy.engineInput().vaccine == .other)
        #expect(rabies.engineInput().vaccine == nil)
        #expect(lepto.engineInput().requiresVetVisit)
        #expect(MedicationDisplay.title(for: lepto) == "Leptospirose")
        #expect(MedicationDisplay.vaccineName(for: rabies) == "Tollwut")
    }

    private func draft(manages: Bool = true, amount: Double = 30) -> MedicationPlanEditSheet.StockDraft {
        .init(managesStock: manages, amount: amount, unit: " Tabletten ", amountPerGiving: 1,
              packageSize: 30, restockLeadDays: 7, needsPrescription: true)
    }

    @Test("Vorrat einschalten zählt neu, unverändertes Speichern nicht")
    func stockEdit() throws {
        let context = try makeContext()
        let plan = MedicationPlan(kind: .ongoing, createdAt: Fixture.logged)
        context.insert(plan)
        let first = Fixture.day(2026, 9, 1)
        let later = Fixture.day(2026, 9, 5)

        MedicationPlanEditSheet.applyStockEdit(draft(), recount: false, to: plan, at: first)
        #expect(plan.stockCountedAt == first)
        #expect(plan.stockAmount == 30)
        #expect(plan.stockUnit == "Tabletten")
        #expect(plan.packageSize == 30)

        // Unverändert gespeichert: die alte Zählung bleibt.
        MedicationPlanEditSheet.applyStockEdit(draft(amount: 25), recount: false, to: plan, at: later)
        #expect(plan.stockCountedAt == first)
        #expect(plan.stockAmount == 30)

        // Bestand geändert: neue Zählung.
        MedicationPlanEditSheet.applyStockEdit(draft(amount: 12), recount: true, to: plan, at: later)
        #expect(plan.stockCountedAt == later)
        #expect(plan.stockAmount == 12)

        // Ausschalten löscht nur die Zählung.
        MedicationPlanEditSheet.applyStockEdit(draft(manages: false), recount: false, to: plan, at: later)
        #expect(plan.stockCountedAt == nil)
        #expect(plan.packageSize == 30)
    }

    @Test("Mengen mit Komma, Punkt und Leerzeichen")
    func parseAmounts() {
        #expect(MedicationPlanEditSheet.parseAmount("12") == 12)
        #expect(MedicationPlanEditSheet.parseAmount("1,5") == 1.5)
        #expect(MedicationPlanEditSheet.parseAmount("1.5") == 1.5)
        #expect(MedicationPlanEditSheet.parseAmount("1.000,5") == 1000.5)
        #expect(MedicationPlanEditSheet.parseAmount(" 3 ") == 3)
        #expect(MedicationPlanEditSheet.parseAmount("") == nil)
        #expect(MedicationPlanEditSheet.parseAmount("abc") == nil)
        #expect(MedicationPlanEditSheet.parseAmount("inf") == nil)
        #expect(MedicationPlanEditSheet.parseAmount("nan") == nil)
        #expect(MedicationPlanEditSheet.parseAmount("99999999999999999999") == nil)
    }
}

@MainActor
@Suite("Bestätigung — Zurückstellung")
struct MedicationReminderDeferralTests {
    let now = Fixture.day(2026, 9, 5).addingTimeInterval(9 * 3600)
    let data = MedicationReminderData(dayMath: .utc)

    @Test("Ein vor der Zurückstellung geplanter Alarm erfasst danach keine Gabe mehr")
    func deferralClosesEarlierDoses() throws {
        let context = try makeContext()
        let settings = AppSettings.loadOrCreate(in: context)
        let pet = Pet(name: "Zola", createdAt: Fixture.logged)
        context.insert(pet)
        let plan = MedicationPlan(kind: .ongoing, productName: "Testpräparat", doseTimesMinutes: [8 * 60],
                                  doseStartDate: Fixture.day(2026, 9, 4), createdAt: Fixture.logged)
        context.insert(plan)
        plan.pet = pet
        try context.save()
        let reminder = try #require(data.reminders(context: context, settings: settings, asOf: now).first)
        #expect(data.isOpen(reminder, plan: plan, settings: settings))

        plan.deferredUntil = Fixture.day(2026, 9, 7)
        plan.deferredAt = now
        try context.save()

        #expect(!data.isOpen(reminder, plan: plan, settings: settings))
        #expect(throws: MedicationReminderData.ConfirmationError.self) {
            try data.confirm(reminder, context: context, settings: settings, asOf: now)
        }
        #expect(plan.doseLogs.isEmpty)

        // Am Tag der Zurückstellung geht es wieder los.
        var resumed = reminder
        resumed.dueAt = Fixture.day(2026, 9, 7).addingTimeInterval(8 * 3600)
        #expect(data.isOpen(resumed, plan: plan, settings: settings))
    }
}
