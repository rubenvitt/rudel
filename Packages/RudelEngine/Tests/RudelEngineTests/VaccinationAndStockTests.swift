import Foundation
import RudelEngine
import Testing

/// Feste Zeitpunkte in UTC — nie `Date()`.
private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year, month: month, day: day, hour: hour, minute: minute
    ).date!
}

@Suite("Impfungen — Katalog und Fälligkeit")
struct VaccinationTests {
    let builder = DueItemBuilder(dayMath: .utc)
    let today = moment(2026, 7, 26)

    @Test("Der Katalog bietet je Tierart nur passende Impfungen an, „andere“ immer")
    func optionsPerSpecies() {
        let dog = VaccineType.options(for: .dog)
        let cat = VaccineType.options(for: .cat)
        #expect(dog.contains(.leptospirosis))
        #expect(dog.contains(.distemperHepatitisParvo))
        #expect(dog.contains(.kennelCough))
        #expect(dog.contains(.lymeDisease))
        #expect(!dog.contains(.panleukopenia))
        #expect(cat.contains(.panleukopenia))
        #expect(cat.contains(.catFlu))
        #expect(cat.contains(.felineLeukemia))
        #expect(!cat.contains(.leptospirosis))
        #expect(dog.last == .other)
        #expect(cat.last == .other)
    }

    @Test("Standard-Gültigkeit nach StIKo Vet, bei Spannen der kürzere Wert")
    func catalogValidity() {
        #expect(VaccineType.distemperHepatitisParvo.defaultValidityDays(for: .dog) == 1095)
        #expect(VaccineType.leptospirosis.defaultValidityDays(for: .dog) == 365)
        #expect(VaccineType.kennelCough.defaultValidityDays(for: .dog) == 365)
        #expect(VaccineType.lymeDisease.defaultValidityDays(for: .dog) == 365)
        #expect(VaccineType.dogCombination.defaultValidityDays(for: .dog) == 365)
        #expect(VaccineType.panleukopenia.defaultValidityDays(for: .cat) == 1095)
        #expect(VaccineType.catFlu.defaultValidityDays(for: .cat) == 365)
        #expect(VaccineType.felineLeukemia.defaultValidityDays(for: .cat) == 365)
        #expect(VaccineType.catCombination.defaultValidityDays(for: .cat) == 365)
    }

    @Test("Impfung rechnet wie Tollwut: Gültigkeit, Restwirksamkeit, Vorsorge, Termin nötig")
    func vaccinationBehavesLikeRabies() throws {
        #expect(MedicationKind.vaccination.usesEffectivePeriod)
        #expect(MedicationKind.vaccination.defaultCareClass == .preventive)
        #expect(MedicationKind.vaccination.defaultRequiresVetVisit)
        #expect(MedicationKind.vaccination.isVaccination)
        #expect(MedicationKind.rabiesVaccination.isVaccination)
        #expect(!MedicationKind.tickProtection.isVaccination)

        func item(_ kind: MedicationKind) throws -> DueItem {
            let input = DueItemBuilder.MedicationInput(
                sourceID: "v", petID: "p", petName: "Rex", kind: kind, productName: "Nobivac",
                lastGivenOn: moment(2025, 10, 1), effectiveDays: 365,
                vaccine: kind == .vaccination ? .leptospirosis : nil
            )
            return try #require(builder.build(medications: [input], cycles: [], asOf: today).first)
        }
        let rabies = try item(.rabiesVaccination)
        let lepto = try item(.vaccination)
        #expect(lepto.category == .protectionExpiry)
        #expect(lepto.dueOn == rabies.dueOn)
        #expect(lepto.remainingFraction == rabies.remainingFraction)
        #expect(lepto.protectionEndsOn == rabies.protectionEndsOn)
        #expect(lepto.careClass == .preventive)
        #expect(lepto.title == "Leptospirose")
        #expect(lepto.detail == "Nobivac")
        #expect(rabies.title == "Tollwut-Impfung")
    }

    @Test("Bei „andere Impfung“ ist das Präparat der Titel")
    func otherVaccineUsesProductName() throws {
        let input = DueItemBuilder.MedicationInput(
            sourceID: "v", petID: "p", petName: "Rex", kind: .vaccination, productName: "Herpes canis",
            effectiveDays: 365, vaccine: .other
        )
        let item = try #require(builder.build(medications: [input], cycles: [], asOf: today).first)
        #expect(item.title == "Herpes canis")
        #expect(item.detail == "Noch nie gegeben")
    }
}

@Suite("Vorrat — Reichweite und Nachfüllen")
struct StockProjectionTests {
    let builder = DueItemBuilder(dayMath: .utc)
    let today = moment(2026, 7, 26)

    private func ongoing(
        times: [Int] = [8, 20],
        everyNDays: Int = 1,
        start: Date? = nil,
        end: Date? = nil,
        stock: StockInput?,
        deferredUntil: Date? = nil,
        isActive: Bool = true
    ) -> DueItemBuilder.MedicationInput {
        DueItemBuilder.MedicationInput(
            sourceID: "m1", petID: "p1", petName: "Rex", kind: .ongoing, productName: "Apoquel",
            schedule: DoseSchedule(
                timesOfDay: times.map { TimeOfDay(hour: $0) },
                everyNDays: everyNDays,
                startDate: start ?? moment(2026, 7, 1),
                endDate: end
            ),
            isActive: isActive,
            deferredUntil: deferredUntil,
            stock: stock
        )
    }

    @Test("Zwei Gaben täglich: 12 Tabletten reichen sechs Tage")
    func twicePerDay() throws {
        let input = ongoing(stock: StockInput(amountAtCount: 12, unit: "Tabletten"))
        let projection = try #require(builder.stockProjection(for: input, asOf: today))
        #expect(projection.coveredGivings == 12)
        #expect(projection.lastCoveredOn == moment(2026, 7, 31))
        #expect(projection.runsOutOn == moment(2026, 8, 1))
        #expect(projection.daysOfSupply == 6)
    }

    @Test("Heute schon erfasste Gaben zählen nicht doppelt")
    func handledTodayIsNotCountedTwice() throws {
        let input = ongoing(stock: StockInput(amountAtCount: 12, givingsSinceCount: 2, dosesHandledToday: 2))
        let projection = try #require(builder.stockProjection(for: input, asOf: today))
        // 12 − 2 = 10 Tabletten für 27.–31.07.
        #expect(projection.remainingAmount == 10)
        #expect(projection.lastCoveredOn == moment(2026, 7, 31))
        #expect(projection.runsOutOn == moment(2026, 8, 1))
    }

    @Test("Jeden zweiten Tag: drei Tabletten decken 26., 28. und 30.")
    func everySecondDay() throws {
        let input = ongoing(times: [8], everyNDays: 2, start: moment(2026, 7, 26), stock: StockInput(amountAtCount: 3))
        let projection = try #require(builder.stockProjection(for: input, asOf: today))
        #expect(projection.lastCoveredOn == moment(2026, 7, 30))
        #expect(projection.runsOutOn == moment(2026, 8, 1))
        #expect(projection.daysOfSupply == 6)
    }

    @Test("Endet das Schema vorher, läuft der Vorrat nicht aus")
    func scheduleEndsFirst() throws {
        let input = ongoing(times: [8], end: moment(2026, 7, 28), stock: StockInput(amountAtCount: 10))
        let projection = try #require(builder.stockProjection(for: input, asOf: today))
        #expect(projection.lastCoveredOn == moment(2026, 7, 28))
        #expect(projection.runsOutOn == nil)
        #expect(!projection.needsRestock)
        #expect(builder.build(medications: [input], cycles: [], asOf: today).allSatisfy { $0.category != .restock })
    }

    @Test("Halbe Tabletten: drei Tabletten sind sechs Gaben")
    func halfTablets() throws {
        let input = ongoing(times: [8], stock: StockInput(amountAtCount: 3, amountPerGiving: 0.5))
        let projection = try #require(builder.stockProjection(for: input, asOf: today))
        #expect(projection.coveredGivings == 6)
        #expect(projection.runsOutOn == moment(2026, 8, 1))
    }

    @Test("Wurmkur: eine Gabe je Intervall ab der nächsten Fälligkeit")
    func intervalKind() throws {
        func dewormer(stock: Double, lastGivenOn: Date) -> DueItemBuilder.MedicationInput {
            DueItemBuilder.MedicationInput(
                sourceID: "w", petID: "p1", petName: "Rex", kind: .dewormer, productName: "Milbemax",
                lastGivenOn: lastGivenOn, intervalDays: 90,
                stock: StockInput(amountAtCount: stock)
            )
        }
        // Fällig am 30.07.: eine Tablette deckt diese Gabe, die nächste am 28.10. nicht mehr.
        let one = try #require(builder.stockProjection(for: dewormer(stock: 1, lastGivenOn: moment(2026, 5, 1)), asOf: today))
        #expect(one.lastCoveredOn == moment(2026, 7, 30))
        #expect(one.runsOutOn == moment(2026, 10, 28))
        #expect(!one.needsRestock)

        // Leer: schon die Gabe am 30.07. fehlt — vier Tage, innerhalb des Vorlaufs.
        let empty = try #require(builder.stockProjection(for: dewormer(stock: 0, lastGivenOn: moment(2026, 5, 1)), asOf: today))
        #expect(empty.runsOutOn == moment(2026, 7, 30))
        #expect(empty.daysOfSupply == 4)
        #expect(empty.needsRestock)

        // Überfällig: die nächste Gabe ist heute, nicht in der Vergangenheit.
        let overdue = try #require(builder.stockProjection(for: dewormer(stock: 0, lastGivenOn: moment(2026, 1, 1)), asOf: today))
        #expect(overdue.runsOutOn == today)
        #expect(overdue.daysOfSupply == 0)
    }

    @Test("Schwelle: Reichweite gleich Vorlauf erinnert, einen Tag mehr nicht")
    func restockThreshold() {
        let atLead = ongoing(times: [8], stock: StockInput(amountAtCount: 7, restockLeadDays: 7))
        let aboveLead = ongoing(times: [8], stock: StockInput(amountAtCount: 8, restockLeadDays: 7))
        let items = builder.build(medications: [atLead], cycles: [], asOf: today).filter { $0.category == .restock }
        #expect(items.count == 1)
        #expect(items.first?.daysUntilDue == 7)
        #expect(builder.build(medications: [aboveLead], cycles: [], asOf: today).allSatisfy { $0.category != .restock })
    }

    @Test("Vorrats-Item: eigene ID, Titel, Text, Dringlichkeit")
    func restockItemShape() throws {
        let input = ongoing(stock: StockInput(
            amountAtCount: 4, unit: "Tabletten", needsPrescription: true
        ))
        let item = try #require(builder.build(medications: [input], cycles: [], asOf: today).first { $0.category == .restock })
        #expect(item.id == "restock:m1")
        #expect(item.sourceID == "m1")
        #expect(item.title == "Vorrat Apoquel")
        #expect(item.detail == "Noch 4 Tabletten · Rezept nötig")
        #expect(item.dueOn == moment(2026, 7, 28))
        #expect(item.urgency == .dueSoon)
        #expect(item.careClass == nil)
        #expect(item.stock?.needsPrescription == true)
    }

    @Test("Aufgebraucht: heute fällig, „Vorrat aufgebraucht“")
    func emptyStock() throws {
        let input = ongoing(stock: StockInput(amountAtCount: 2, givingsSinceCount: 3))
        let item = try #require(builder.build(medications: [input], cycles: [], asOf: today).first { $0.category == .restock })
        #expect(item.detail == "Vorrat aufgebraucht")
        #expect(item.urgency == .dueToday)
    }

    @Test("Zurückstellung verschiebt die Reichweite, inaktive Pläne schweigen")
    func deferralAndInactive() {
        let stock = StockInput(amountAtCount: 2)
        let deferred = ongoing(times: [8], stock: stock, deferredUntil: moment(2026, 8, 10))
        #expect(builder.stockProjection(for: deferred, asOf: today)?.runsOutOn == moment(2026, 8, 12))
        #expect(builder.build(medications: [deferred], cycles: [], asOf: today).allSatisfy { $0.category != .restock })

        let notDeferred = ongoing(times: [8], stock: stock)
        #expect(builder.build(medications: [notDeferred], cycles: [], asOf: today).contains { $0.category == .restock })

        let inactive = ongoing(times: [8], stock: stock, isActive: false)
        #expect(builder.build(medications: [inactive], cycles: [], asOf: today).isEmpty)
    }

    @Test("Absurde Mengen stürzen nicht ab")
    func absurdAmountsDoNotTrap() throws {
        let huge = ongoing(times: [8], stock: StockInput(amountAtCount: 1e30, amountPerGiving: 1e-30))
        let projection = try #require(builder.stockProjection(for: huge, asOf: today))
        #expect(projection.coveredGivings > 0)
        let infinite = ongoing(times: [8], stock: StockInput(amountAtCount: .infinity))
        #expect(builder.stockProjection(for: infinite, asOf: today) != nil)
    }

    @Test("Ohne Vorratsverwaltung kein Vorrats-Item")
    func noStockNoItem() {
        let input = ongoing(stock: nil)
        #expect(builder.stockProjection(for: input, asOf: today) == nil)
        #expect(builder.build(medications: [input], cycles: [], asOf: today).allSatisfy { $0.category != .restock })
    }

    @Test("Ein offener Termin verschluckt die Fälligkeit, nicht den Vorrat")
    func openAppointmentKeepsRestock() {
        let input = DueItemBuilder.MedicationInput(
            sourceID: "z", petID: "p1", petName: "Rex", kind: .tickProtection, productName: "Bravecto",
            lastGivenOn: moment(2026, 5, 1), effectiveDays: 84, hasOpenAppointment: true,
            stock: StockInput(amountAtCount: 0)
        )
        let items = builder.build(medications: [input], cycles: [], asOf: today)
        #expect(items.map(\.category) == [.restock])
    }

    @Test("Vorrat erzeugt nie einen Medikamententermin (kein Alarm)")
    func neverAReminder() {
        let input = ongoing(stock: StockInput(amountAtCount: 0))
        let reminders = MedicationReminderPlanner(dayMath: .utc).plan(
            medications: [input], loggedDoses: [:], reminderTime: TimeOfDay(hour: 9), horizonDays: 7, asOf: today
        )
        #expect(!reminders.isEmpty)
        #expect(reminders.allSatisfy { $0.category == .dose })
    }
}

@Suite("Vorrat — Mitteilungen")
struct RestockNotificationTests {
    let builder = DueItemBuilder(dayMath: .utc)
    let planner = NotificationPlanner(dayMath: .utc)

    private func notifications(needsPrescription: Bool, asOf: Date) -> [NotificationPlanner.PlannedNotification] {
        let input = DueItemBuilder.MedicationInput(
            sourceID: "m1", petID: "p1", petName: "Rex", kind: .ongoing, productName: "Apoquel",
            schedule: DoseSchedule(timesOfDay: [TimeOfDay(hour: 8)], startDate: moment(2026, 7, 1)),
            stock: StockInput(amountAtCount: 6, needsPrescription: needsPrescription)
        )
        let items = builder.build(medications: [input], cycles: [], asOf: asOf)
        return planner.plan(
            dueItems: items, doseOccurrences: [:], medicationReminders: [],
            settings: NotificationPlanner.Settings(reminderTime: TimeOfDay(hour: 9)), asOf: asOf
        ).filter { $0.category == .restock }
    }

    @Test("Mit Rezept: Titel, Reichweite ab Mitteilung, Rezept-Hinweis")
    func withPrescription() throws {
        // 26.07. 07:00 — sechs Tabletten decken 26.–31.07., die Mitteilung kommt heute um 09:00.
        let planned = notifications(needsPrescription: true, asOf: moment(2026, 7, 26, 7))
        let notification = try #require(planned.first)
        #expect(planned.count == 1)
        #expect(notification.title == "Rex — Vorrat Apoquel")
        #expect(notification.body == "Reicht noch etwa 6 Tage. Rezept beim Tierarzt anfordern.")
        #expect(notification.fireDate == moment(2026, 7, 26, 9))
    }

    @Test("Ohne Rezept, nach der Erinnerungszeit: morgen, ein Tag weniger")
    func withoutPrescriptionTomorrow() throws {
        let planned = notifications(needsPrescription: false, asOf: moment(2026, 7, 26, 10))
        let notification = try #require(planned.first)
        #expect(planned.count == 1)
        #expect(notification.body == "Reicht noch etwa 5 Tage.")
        #expect(notification.fireDate == moment(2026, 7, 27, 9))
    }

    @Test("Vorrat steht unter einer heute fälligen Behandlung")
    func priorityBelowDueTreatments() throws {
        let asOf = moment(2026, 7, 26, 7)
        let due = DueItemBuilder.MedicationInput(
            sourceID: "w", petID: "p1", petName: "Rex", kind: .dewormer, productName: "",
            lastGivenOn: moment(2026, 4, 27), intervalDays: 90
        )
        let stock = DueItemBuilder.MedicationInput(
            sourceID: "m1", petID: "p1", petName: "Rex", kind: .ongoing, productName: "Apoquel",
            schedule: DoseSchedule(timesOfDay: [TimeOfDay(hour: 8)], startDate: moment(2026, 7, 1)),
            stock: StockInput(amountAtCount: 1)
        )
        let planned = planner.plan(
            dueItems: builder.build(medications: [due, stock], cycles: [], asOf: asOf),
            doseOccurrences: [:], medicationReminders: [],
            settings: NotificationPlanner.Settings(reminderTime: TimeOfDay(hour: 9)), asOf: asOf
        )
        let restock = try #require(planned.first { $0.category == .restock })
        let treatment = try #require(planned.first { $0.category == .medication })
        #expect(restock.priority < treatment.priority)
    }
}
