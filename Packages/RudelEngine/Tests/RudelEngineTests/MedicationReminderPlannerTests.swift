import Foundation
import RudelEngine
import Testing

@Suite("MedicationReminderPlanner")
struct MedicationReminderPlannerTests {
    private let planner = MedicationReminderPlanner(dayMath: .utc)

    private func moment(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ).date!
    }

    private func ongoing(
        sourceID: String = "med-1",
        startDate: Date,
        times: [TimeOfDay] = [TimeOfDay(hour: 8)],
        everyNDays: Int = 1,
        isActive: Bool = true
    ) -> DueItemBuilder.MedicationInput {
        DueItemBuilder.MedicationInput(
            sourceID: sourceID,
            petID: "pet-1",
            petName: "Zola",
            kind: .ongoing,
            productName: "Metacam",
            schedule: DoseSchedule(
                timesOfDay: times,
                everyNDays: everyNDays,
                startDate: startDate,
                doseLabel: "1/2 Tablette"
            ),
            isActive: isActive
        )
    }

    @Test("Ein Pausentag verschiebt das every-N-days-Raster nicht")
    func pauseDayKeepsScheduleAlignment() {
        let reminders = planner.plan(
            medications: [
                ongoing(startDate: moment(2026, 9, 4), everyNDays: 2)
            ],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 3,
            asOf: moment(2026, 9, 5, 9)
        )

        #expect(reminders.map(\.dueAt) == [
            moment(2026, 9, 6, 8),
            moment(2026, 9, 8, 8),
        ])
    }

    @Test("Ein morgen beginnender Plan enthält die erste morgige Gabe")
    func tomorrowStartIncludesTomorrowDose() {
        let reminders = planner.plan(
            medications: [ongoing(startDate: moment(2026, 9, 6))],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 1,
            asOf: moment(2026, 9, 5, 12)
        )

        #expect(reminders.map(\.dueAt) == [moment(2026, 9, 6, 8)])
    }

    @Test("Eine geloggte Gabe wird minutengenau ausgeschlossen")
    func loggedDoseIsExcludedAtMinutePrecision() {
        let reminders = planner.plan(
            medications: [ongoing(startDate: moment(2026, 9, 5))],
            loggedDoses: ["med-1": [moment(2026, 9, 6, 8, 0).addingTimeInterval(30)]],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 1,
            asOf: moment(2026, 9, 5, 9)
        )

        #expect(reminders.map(\.dueAt) == [moment(2026, 9, 5, 8)])
    }

    @Test("Eine heute verstrichene, offene Gabe bleibt im Plan")
    func missedDoseEarlierTodayIsRetained() {
        let reminders = planner.plan(
            medications: [ongoing(startDate: moment(2026, 9, 5))],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 0,
            asOf: moment(2026, 9, 5, 9)
        )

        #expect(reminders.map(\.dueAt) == [moment(2026, 9, 5, 8)])
    }

    @Test("Doppelte Eingaben werden entfernt und behalten stabile IDs")
    func duplicatesAreDeduplicatedWithStableIDs() {
        let medication = ongoing(
            startDate: moment(2026, 9, 5),
            times: [TimeOfDay(hour: 8), TimeOfDay(hour: 8), TimeOfDay(hour: 20)]
        )

        let first = planner.plan(
            medications: [medication, medication],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 0,
            asOf: moment(2026, 9, 5, 7)
        )
        let second = planner.plan(
            medications: [medication],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 0,
            asOf: moment(2026, 9, 5, 12)
        )

        #expect(first.map(\.dueAt) == [moment(2026, 9, 5, 8), moment(2026, 9, 5, 20)])
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count)
        #expect(first.allSatisfy { reminder in
            reminder.id.contains(reminder.sourceID)
                && reminder.id.contains(reminder.category.rawValue)
        })
    }

    @Test("Inaktive Pläne erzeugen keine Erinnerungen")
    func inactivePlanIsExcluded() {
        let reminders = planner.plan(
            medications: [
                ongoing(startDate: moment(2026, 9, 5), isActive: false)
            ],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 7,
            asOf: moment(2026, 9, 5, 9)
        )

        #expect(reminders.isEmpty)
    }

    @Test("Eine überfällige Wurmkur behält ihren ursprünglichen Fälligkeitstag")
    func overdueNonDoseKeepsOriginalDueDay() throws {
        let medication = DueItemBuilder.MedicationInput(
            sourceID: "worm-1",
            petID: "pet-1",
            petName: "Zola",
            kind: .dewormer,
            productName: "Milbemax",
            lastGivenOn: moment(2026, 9, 1),
            intervalDays: 2
        )

        let reminders = planner.plan(
            medications: [medication],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9, minute: 15),
            horizonDays: 7,
            asOf: moment(2026, 9, 5, 12)
        )

        let reminder = try #require(reminders.first)
        #expect(reminders.count == 1)
        #expect(reminder.category == .medication)
        #expect(reminder.dueAt == moment(2026, 9, 3, 9, 15))
        #expect(reminder.title == "Wurmkur")
        #expect(reminder.detail == "Milbemax")
    }
}
