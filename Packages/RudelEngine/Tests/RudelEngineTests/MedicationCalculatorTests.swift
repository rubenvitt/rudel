import Foundation
import Testing

import RudelEngine

@Suite("MedicationCalculator")
struct MedicationCalculatorTests {
    private let calculator = MedicationCalculator(dayMath: .utc)

    /// Realistische Wirkdauern und Intervalle. `StudyConstants` enthält
    /// ausschließlich Zykluswerte und ist für Gaben deshalb keine Referenz — die
    /// Zahlen hier sind Produktangaben (Spot-on 30 d, Wurmkur 90 d, Tollwut 3 Jahre).
    private let tickProtectionDays = 30
    private let dewormerIntervalDays = 90
    private let rabiesValidityDays = 1095

    // MARK: - Fixtures

    /// Kalendertag in UTC. Fixtures werden aus festen Komponenten gebaut und nie
    /// aus `Date()` — sonst hängt das Ergebnis am Testzeitpunkt.
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year, month: month, day: day
        ).date!
    }

    /// Zeitpunkt in UTC — für Fenstergrenzen und erwartete Gabe-Termine.
    private func moment(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0
    ) -> Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year, month: month, day: day, hour: hour, minute: minute
        ).date!
    }

    /// Kalender mit echter Sommerzeit — nur damit lässt sich prüfen, dass die
    /// Engine in Kalendertagen und nicht in 86400-Sekunden-Schritten rechnet.
    private func berlinCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func berlinCalculator() -> MedicationCalculator {
        MedicationCalculator(dayMath: DayMath(calendar: berlinCalendar()))
    }

    private func berlinMoment(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        DateComponents(
            calendar: berlinCalendar(),
            timeZone: TimeZone(identifier: "Europe/Berlin"),
            year: year, month: month, day: day, hour: hour, minute: minute
        ).date!
    }

    /// Wanduhrzeit in Berlin. Kern der Sommerzeit-Prüfung: der absolute Abstand
    /// zweier Gaben ändert sich am Umstellungstag, die Wanduhrzeit darf es nicht.
    private func berlinWallClock(_ date: Date) -> (Int, Int) {
        let components = berlinCalendar().dateComponents([.hour, .minute], from: date)
        return (components.hour ?? -1, components.minute ?? -1)
    }

    private func berlinDate(_ date: Date) -> (Int, Int, Int) {
        let components = berlinCalendar().dateComponents([.year, .month, .day], from: date)
        return (components.year ?? -1, components.month ?? -1, components.day ?? -1)
    }

    // MARK: - protectionStatus

    @Test("Am Gabetag ist die Restwirksamkeit genau 1,0")
    func protectionIsFullOnDayOfDose() {
        let given = day(2026, 7, 1)
        let status = calculator.protectionStatus(
            lastGivenOn: given,
            effectiveDays: tickProtectionDays,
            asOf: given
        )

        #expect(status.remainingFraction == 1.0)
        #expect(status.remainingDays == tickProtectionDays)
        #expect(status.expiresOn == day(2026, 7, 31))
        #expect(status.isExpired == false)
    }

    @Test("Zur Hälfte der Wirkdauer ist die Fraktion 0,5")
    func protectionHalfwayThrough() {
        let status = calculator.protectionStatus(
            lastGivenOn: day(2026, 7, 1),
            effectiveDays: 30,
            asOf: day(2026, 7, 16)
        )

        #expect(status.remainingDays == 15)
        #expect(abs(status.remainingFraction - 0.5) < 1e-9)
        #expect(status.isExpired == false)
    }

    @Test("Am Ablauftag selbst ist der Schutz weg: Fraktion 0, 0 Resttage, abgelaufen")
    func protectionExpiresOnExpiryDay() {
        let status = calculator.protectionStatus(
            lastGivenOn: day(2026, 7, 1),
            effectiveDays: 30,
            asOf: day(2026, 7, 31)
        )

        #expect(status.remainingDays == 0)
        #expect(status.remainingFraction == 0)
        #expect(status.isExpired)
    }

    @Test("Überfällig: Fraktion bleibt bei 0, remainingDays wird negativ")
    func overdueProtectionClampsFractionButNotDays() {
        let status = calculator.protectionStatus(
            lastGivenOn: day(2026, 7, 1),
            effectiveDays: 30,
            asOf: day(2026, 8, 10)
        )

        #expect(status.remainingFraction == 0)
        #expect(status.remainingDays == -10)
        #expect(status.isExpired)
    }

    @Test("asOf vor der Gabe: Fraktion auf 1,0 geklemmt, läuft nicht über")
    func protectionFractionIsClampedAtOne() {
        let status = calculator.protectionStatus(
            lastGivenOn: day(2026, 7, 1),
            effectiveDays: 30,
            asOf: day(2026, 6, 28)
        )

        #expect(status.remainingFraction == 1.0)
        #expect(status.remainingDays == 33)
    }

    @Test("Wirkdauer 0: sofort abgelaufen, keine Division durch Null")
    func zeroEffectiveDaysExpiresImmediately() {
        let given = day(2026, 7, 1)
        let status = calculator.protectionStatus(lastGivenOn: given, effectiveDays: 0, asOf: given)

        #expect(status.remainingFraction == 0)
        #expect(status.remainingFraction.isNaN == false)
        #expect(status.remainingDays == 0)
        #expect(status.expiresOn == given)
        #expect(status.isExpired)
    }

    @Test("Negative Wirkdauer schiebt den Ablauf nicht vor die Gabe")
    func negativeEffectiveDaysDoesNotMoveExpiryBeforeDose() {
        let given = day(2026, 7, 1)
        let status = calculator.protectionStatus(lastGivenOn: given, effectiveDays: -5, asOf: given)

        #expect(status.expiresOn == given)
        #expect(status.remainingFraction == 0)
        #expect(status.isExpired)
    }

    @Test("Uhrzeiten innerhalb eines Tages ändern die Resttage nicht")
    func protectionIgnoresTimeOfDay() {
        // Gabe abends, Abfrage am Folgetag früh: zwei Stunden Abstand, aber ein
        // ganzer Kalendertag.
        let status = calculator.protectionStatus(
            lastGivenOn: moment(2026, 7, 1, 23, 0),
            effectiveDays: 30,
            asOf: moment(2026, 7, 2, 1, 0)
        )

        #expect(status.remainingDays == 29)
        #expect(status.expiresOn == day(2026, 7, 31))
    }

    @Test("Tollwut-Gültigkeit über drei Jahre inkl. Schaltjahr")
    func longProtectionSpansLeapYear() {
        let status = calculator.protectionStatus(
            lastGivenOn: day(2024, 2, 29),
            effectiveDays: rabiesValidityDays,
            asOf: day(2024, 2, 29)
        )

        // 2024 ist Schaltjahr: 1095 Kalendertage ab 29.02.2024 enden am 28.02.2027.
        #expect(status.expiresOn == day(2027, 2, 28))
        #expect(status.remainingDays == rabiesValidityDays)
        #expect(status.remainingFraction == 1.0)
    }

    // MARK: - dueness

    @Test("Fälligkeit ist letzte Gabe plus Intervall")
    func duenessIsLastGivenPlusInterval() {
        let given = day(2026, 7, 1)
        let dueness = calculator.dueness(
            lastGivenOn: given,
            intervalDays: dewormerIntervalDays,
            asOf: given
        )

        #expect(dueness.dueOn == day(2026, 9, 29))
        #expect(dueness.daysUntilDue == dewormerIntervalDays)
        #expect(dueness.isOverdue == false)
    }

    @Test("Heute fällig ist noch nicht überfällig")
    func dueTodayIsNotOverdue() {
        let dueness = calculator.dueness(
            lastGivenOn: day(2026, 7, 1),
            intervalDays: 90,
            asOf: day(2026, 9, 29)
        )

        #expect(dueness.daysUntilDue == 0)
        #expect(dueness.isOverdue == false)
        // Muss zur Einstufung der UI passen, sonst widersprechen sich Badge und Text.
        #expect(Urgency(daysUntilDue: dueness.daysUntilDue) == .dueToday)
    }

    @Test("Überfällig: negative Resttage und overdue-Einstufung")
    func overdueDuenessIsNegative() {
        let dueness = calculator.dueness(
            lastGivenOn: day(2026, 7, 1),
            intervalDays: 90,
            asOf: day(2026, 10, 4)
        )

        #expect(dueness.daysUntilDue == -5)
        #expect(dueness.isOverdue)
        #expect(Urgency(daysUntilDue: dueness.daysUntilDue) == .overdue)
    }

    @Test("Intervall 0 ⇒ fällig am Gabetag")
    func zeroIntervalIsDueOnDoseDay() {
        let given = day(2026, 7, 1)
        let dueness = calculator.dueness(lastGivenOn: given, intervalDays: 0, asOf: given)

        #expect(dueness.dueOn == given)
        #expect(dueness.daysUntilDue == 0)
        #expect(dueness.isOverdue == false)
    }

    @Test("Negatives Intervall ⇒ fällig am Gabetag, nicht davor")
    func negativeIntervalIsDueOnDoseDay() {
        let given = day(2026, 7, 1)
        let dueness = calculator.dueness(lastGivenOn: given, intervalDays: -30, asOf: given)

        #expect(dueness.dueOn == given)
        #expect(dueness.daysUntilDue == 0)
        #expect(dueness.isOverdue == false)
    }

    @Test("Fälligkeit rechnet in Kalendertagen, nicht in Uhrzeiten")
    func duenessIgnoresTimeOfDay() {
        let dueness = calculator.dueness(
            lastGivenOn: moment(2026, 7, 1, 22, 30),
            intervalDays: 90,
            asOf: moment(2026, 9, 29, 6, 0)
        )

        #expect(dueness.dueOn == day(2026, 9, 29))
        #expect(dueness.daysUntilDue == 0)
    }

    // MARK: - doseOccurrences

    @Test("Ohne Uhrzeiten gibt es keine Termine")
    func emptyTimesOfDayYieldsNoOccurrences() {
        let schedule = DoseSchedule(timesOfDay: [], startDate: day(2026, 7, 1))
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 31, 23, 59)
        )

        #expect(occurrences.isEmpty)
    }

    @Test("Zwei Gaben täglich ergeben zwei Termine pro Tag, aufsteigend")
    func twoDosesPerDay() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8), TimeOfDay(hour: 20)],
            startDate: day(2026, 7, 1)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 3, 23, 59)
        )

        #expect(occurrences == [
            moment(2026, 7, 1, 8), moment(2026, 7, 1, 20),
            moment(2026, 7, 2, 8), moment(2026, 7, 2, 20),
            moment(2026, 7, 3, 8), moment(2026, 7, 3, 20),
        ])
    }

    @Test("everyNDays zählt ab startDate — Tag 0 ist ein Gabetag")
    func everyNDaysCountsFromStartDate() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 3,
            startDate: day(2026, 7, 1)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 10, 23, 59)
        )

        #expect(occurrences == [
            moment(2026, 7, 1, 9),
            moment(2026, 7, 4, 9),
            moment(2026, 7, 7, 9),
            moment(2026, 7, 10, 9),
        ])
    }

    @Test("Raster bleibt erhalten, wenn das Fenster mitten im Schema beginnt")
    func gridStaysAlignedWhenWindowStartsLater() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 5,
            startDate: day(2026, 7, 1)
        )
        // Fenster beginnt am 08.07. — kein Gabetag (Raster: 1., 6., 11., 16.).
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 8)...moment(2026, 7, 20, 23, 59)
        )

        #expect(occurrences == [moment(2026, 7, 11, 9), moment(2026, 7, 16, 9)])
    }

    @Test("Ein Gabetag am Fensterbeginn bleibt drin")
    func doseDayAtWindowStartIsKept() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 5,
            startDate: day(2026, 7, 1)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 6)...moment(2026, 7, 6, 23, 59)
        )

        #expect(occurrences == [moment(2026, 7, 6, 9)])
    }

    @Test("endDate schneidet inklusiv ab: am Ablauftag wird noch gegeben")
    func endDateIsInclusive() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 20)],
            startDate: day(2026, 7, 1),
            // Mitternacht: die Uhrzeit von endDate darf den Ablauftag nicht kappen.
            endDate: day(2026, 7, 5)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 31, 23, 59)
        )

        #expect(occurrences.count == 5)
        #expect(occurrences.last == moment(2026, 7, 5, 20))
    }

    @Test("Termine vor startDate entstehen nicht")
    func nothingBeforeStartDate() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            startDate: day(2026, 7, 10)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 11, 23, 59)
        )

        #expect(occurrences == [moment(2026, 7, 10, 9), moment(2026, 7, 11, 9)])
    }

    @Test("Fenster vollständig hinter endDate ⇒ leer")
    func windowAfterEndDateIsEmpty() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            startDate: day(2026, 7, 1),
            endDate: day(2026, 7, 5)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 6)...moment(2026, 7, 20, 23, 59)
        )

        #expect(occurrences.isEmpty)
    }

    @Test("Fenster vollständig vor startDate ⇒ leer")
    func windowBeforeStartDateIsEmpty() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            startDate: day(2026, 7, 10)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 5, 23, 59)
        )

        #expect(occurrences.isEmpty)
    }

    @Test("endDate vor startDate ⇒ leer")
    func endDateBeforeStartDateIsEmpty() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            startDate: day(2026, 7, 10),
            endDate: day(2026, 7, 1)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 6, 1)...moment(2026, 8, 1, 23, 59)
        )

        #expect(occurrences.isEmpty)
    }

    @Test("Das Fenster wird zeitstempelgenau geprüft, nicht tagesweise")
    func windowIsCheckedToTheMinute() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8), TimeOfDay(hour: 20)],
            startDate: day(2026, 7, 1)
        )
        // „Jetzt" ist mittags: die 08:00-Gabe war schon, sie ist kein Termin mehr.
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: moment(2026, 7, 1, 12)...moment(2026, 7, 2, 12)
        )

        #expect(occurrences == [moment(2026, 7, 1, 20), moment(2026, 7, 2, 8)])
    }

    @Test("Fenster der Länge null trifft genau den Termin darauf")
    func degenerateWindowHitsExactMoment() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            startDate: day(2026, 7, 1)
        )
        let instant = moment(2026, 7, 1, 9)
        let occurrences = calculator.doseOccurrences(schedule: schedule, in: instant...instant)

        #expect(occurrences == [instant])
    }

    @Test("Ergebnis ist aufsteigend sortiert, auch bei unsortierten Uhrzeiten")
    func resultIsSortedEvenWithUnsortedTimes() {
        var schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8)],
            startDate: day(2026, 7, 1)
        )
        // `timesOfDay` ist veränderbar — nach dem Init kann die Sortierung des
        // Initializers wieder verloren gehen.
        schedule.timesOfDay = [TimeOfDay(hour: 20), TimeOfDay(hour: 8), TimeOfDay(hour: 14)]

        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 2, 23, 59)
        )

        #expect(occurrences == occurrences.sorted())
        #expect(occurrences == [
            moment(2026, 7, 1, 8), moment(2026, 7, 1, 14), moment(2026, 7, 1, 20),
            moment(2026, 7, 2, 8), moment(2026, 7, 2, 14), moment(2026, 7, 2, 20),
        ])
    }

    @Test("Doppelte Uhrzeit ergibt zwei Termine — so viele wie dosesPerDay sagt")
    func duplicateTimesYieldOneOccurrenceEach() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9), TimeOfDay(hour: 9)],
            startDate: day(2026, 7, 1)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 1, 23, 59)
        )

        #expect(schedule.dosesPerDay == 2)
        #expect(occurrences == [moment(2026, 7, 1, 9), moment(2026, 7, 1, 9)])
    }

    @Test("everyNDays wird auf mindestens 1 geklemmt")
    func nonPositiveEveryNDaysBecomesDaily() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 0,
            startDate: day(2026, 7, 1)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 3, 23, 59)
        )

        #expect(schedule.everyNDays == 1)
        #expect(occurrences.count == 3)
    }

    @Test("Mitternacht als Gabezeit landet genau auf Tagesbeginn")
    func midnightDoseTime() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 0)],
            startDate: day(2026, 7, 1)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 7, 2, 23, 59)
        )

        #expect(occurrences == [day(2026, 7, 1), day(2026, 7, 2)])
    }

    @Test("Jeder Termin fällt auf einen Gabetag")
    func occurrencesOnlyFallOnDoseDays() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 7), TimeOfDay(hour: 19)],
            everyNDays: 4,
            startDate: day(2026, 7, 2)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: day(2026, 7, 1)...moment(2026, 8, 15, 23, 59)
        )

        #expect(occurrences.isEmpty == false)
        for occurrence in occurrences {
            #expect(calculator.isDoseDay(schedule: schedule, day: occurrence))
        }
    }

    // MARK: - doseOccurrences: Sommerzeit

    @Test("Tägliche Gabe behält über die Zeitumstellung Ende Oktober ihre Uhrzeit")
    func dailyDosesKeepWallClockTimeAcrossFallBack() {
        let calculator = berlinCalculator()
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            startDate: berlinMoment(2026, 10, 22)
        )
        // Die Umstellung liegt am 25.10.2026 (03:00 → 02:00): 22.–28.10. = 7 Gaben.
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: berlinMoment(2026, 10, 22)...berlinMoment(2026, 10, 28, 23, 59)
        )

        #expect(occurrences.count == 7)
        // Mit 86400-Sekunden-Arithmetik wäre ab dem 25.10. jede Gabe um 08:00 —
        // genau das schlägt hier fehl.
        for occurrence in occurrences {
            #expect(berlinWallClock(occurrence) == (9, 0))
        }
        #expect(berlinDate(occurrences[0]) == (2026, 10, 22))
        #expect(berlinDate(occurrences[3]) == (2026, 10, 25))
        #expect(berlinDate(occurrences[6]) == (2026, 10, 28))
    }

    @Test("Wochenraster bleibt über die Zeitumstellung auf demselben Wochentag")
    func weeklyGridStaysAlignedAcrossFallBack() {
        let calculator = berlinCalculator()
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 7,
            startDate: berlinMoment(2026, 10, 18)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: berlinMoment(2026, 10, 18)...berlinMoment(2026, 11, 15, 23, 59)
        )

        #expect(occurrences.count == 5)
        #expect(berlinDate(occurrences[1]) == (2026, 10, 25))
        #expect(berlinDate(occurrences[2]) == (2026, 11, 1))
        #expect(berlinDate(occurrences[4]) == (2026, 11, 15))
        for occurrence in occurrences {
            #expect(berlinWallClock(occurrence) == (9, 0))
        }
    }

    @Test("Nicht existierende Uhrzeit am Umstellungstag ergibt genau einen Termin")
    func springForwardGapYieldsExactlyOneOccurrence() {
        let calculator = berlinCalculator()
        // 29.03.2026: 02:00 → 03:00, die Uhrzeit 02:30 existiert an diesem Tag nicht.
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 2, minute: 30)],
            startDate: berlinMoment(2026, 3, 29)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: berlinMoment(2026, 3, 29)...berlinMoment(2026, 3, 29, 23, 59)
        )

        // Keine Gabe darf verschwinden und keine sich verdoppeln; der Termin
        // rutscht auf den ersten existierenden Zeitpunkt.
        #expect(occurrences.count == 1)
        #expect(berlinDate(occurrences[0]) == (2026, 3, 29))
        #expect(occurrences[0] >= berlinMoment(2026, 3, 29, 3))
    }

    @Test("Zwei Gaben täglich über den Frühjahrs-Umstellungstag")
    func twoDosesPerDayAcrossSpringForward() {
        let calculator = berlinCalculator()
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8), TimeOfDay(hour: 20)],
            startDate: berlinMoment(2026, 3, 28)
        )
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: berlinMoment(2026, 3, 28)...berlinMoment(2026, 3, 30, 23, 59)
        )

        #expect(occurrences.count == 6)
        #expect(occurrences.map { berlinWallClock($0).0 } == [8, 20, 8, 20, 8, 20])
    }

    // MARK: - isDoseDay

    @Test("startDate ist ein Gabetag")
    func startDateIsDoseDay() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 3,
            startDate: day(2026, 7, 1)
        )

        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 1)))
    }

    @Test("Nur Vielfache von everyNDays sind Gabetage")
    func onlyGridMultiplesAreDoseDays() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 3,
            startDate: day(2026, 7, 1)
        )

        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 2)) == false)
        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 3)) == false)
        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 4)))
    }

    @Test("Tage vor startDate sind keine Gabetage")
    func daysBeforeStartAreNotDoseDays() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 3,
            startDate: day(2026, 7, 10)
        )

        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 9)) == false)
        // Auch ein Tag, der auf dem Raster *rückwärts* passen würde, zählt nicht.
        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 7)) == false)
    }

    @Test("endDate ist noch Gabetag, der Folgetag nicht mehr")
    func endDateIsStillADoseDay() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            startDate: day(2026, 7, 1),
            endDate: day(2026, 7, 5)
        )

        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 5)))
        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 6)) == false)
    }

    @Test("Ohne Uhrzeiten bleibt der Tag ein Gabetag – leer heißt nur „keine Erinnerung“")
    func emptyTimesOfDayIsStillADoseDay() {
        let schedule = DoseSchedule(timesOfDay: [], startDate: day(2026, 7, 1))

        #expect(calculator.isDoseDay(schedule: schedule, day: day(2026, 7, 1)))
        #expect(schedule.dosesPerDay == 1)
    }

    @Test("Die Uhrzeit des geprüften Datums spielt keine Rolle")
    func isDoseDayIgnoresTimeOfDay() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 2,
            startDate: moment(2026, 7, 1, 22, 30)
        )

        #expect(calculator.isDoseDay(schedule: schedule, day: moment(2026, 7, 3, 1, 15)))
        #expect(calculator.isDoseDay(schedule: schedule, day: moment(2026, 7, 2, 23, 59)) == false)
    }

    @Test("Gabetage bleiben über die Zeitumstellung auf dem Raster")
    func doseDaysStayOnGridAcrossFallBack() {
        let calculator = berlinCalculator()
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 9)],
            everyNDays: 7,
            startDate: berlinMoment(2026, 10, 18)
        )

        #expect(calculator.isDoseDay(schedule: schedule, day: berlinMoment(2026, 10, 25)))
        #expect(calculator.isDoseDay(schedule: schedule, day: berlinMoment(2026, 11, 1)))
        #expect(calculator.isDoseDay(schedule: schedule, day: berlinMoment(2026, 10, 26)) == false)
    }
}
