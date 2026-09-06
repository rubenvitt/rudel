import Foundation
import RudelEngine
import Testing

@Suite("NotificationPlanner authoritative medication reminders")
struct NotificationPlannerMedicationReminderTests {
    private let medicationPlanner = MedicationReminderPlanner(dayMath: .utc)
    private let notificationPlanner = NotificationPlanner(dayMath: .utc)

    private func moment(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0
    ) -> Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour
        ).date!
    }

    private func ongoing() -> DueItemBuilder.MedicationInput {
        DueItemBuilder.MedicationInput(
            sourceID: "med-1",
            petID: "pet-1",
            petName: "Zola",
            kind: .ongoing,
            productName: "Metacam",
            schedule: DoseSchedule(
                timesOfDay: [TimeOfDay(hour: 8)],
                everyNDays: 2,
                startDate: moment(2026, 9, 4),
                doseLabel: "1/2 Tablette"
            )
        )
    }

    private func doseItem(at dueAt: Date) -> DueItem {
        DueItem(
            id: "dashboard-dose",
            sourceID: "med-1",
            petID: "pet-1",
            petName: "Zola",
            category: .dose,
            title: "Metacam",
            detail: "1/2 Tablette",
            dueOn: dueAt,
            daysUntilDue: 0,
            urgency: .dueToday
        )
    }

    private func medicationItem(dueOn: Date) -> DueItem {
        DueItem(
            id: "worm-reminder",
            sourceID: "worm-1",
            petID: "pet-1",
            petName: "Zola",
            category: .medication,
            title: "Wurmkur",
            detail: "Milbemax",
            dueOn: dueOn,
            daysUntilDue: 7,
            urgency: .upcoming
        )
    }

    @Test("Autoritative Metadaten planen künftige Gaben ohne Dashboard-Zeile")
    func authoritativeRemindersNeedNoDashboardMetadata() {
        let asOf = moment(2026, 9, 5, 9)
        let reminders = medicationPlanner.plan(
            medications: [ongoing()],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 3,
            asOf: asOf
        )

        let notifications = notificationPlanner.plan(
            dueItems: [],
            doseOccurrences: [:],
            medicationReminders: reminders,
            settings: .init(leadDays: [0], horizonDays: 3),
            asOf: asOf
        )

        #expect(notifications.map(\.fireDate) == [
            moment(2026, 9, 6, 8),
            moment(2026, 9, 8, 8),
        ])
        #expect(notifications.allSatisfy { $0.title == "Zola — Metacam geben" })
        #expect(notifications.allSatisfy { $0.petID == "pet-1" && $0.category == .dose })
        #expect(notifications.allSatisfy { $0.sourceID == "med-1" && $0.dueAt == $0.fireDate })
    }

    @Test("Eine leere authoritative Liste unterdrückt Dashboard- und Legacy-Dosen")
    func emptyAuthoritativeListSuppressesLegacyDoses() {
        let dueAt = moment(2026, 9, 5, 20)

        let notifications = notificationPlanner.plan(
            dueItems: [doseItem(at: dueAt)],
            doseOccurrences: ["med-1": [dueAt]],
            medicationReminders: [],
            settings: .init(leadDays: [0], horizonDays: 1),
            asOf: moment(2026, 9, 5, 9)
        )

        #expect(notifications.isEmpty)
    }

    @Test("Legacy-Dosen tragen Quelle und planmäßige Gabezeit")
    func legacyDoseCarriesOccurrenceMetadata() throws {
        let dueAt = moment(2026, 9, 6, 8)
        let metadata = DueItem(
            id: "med-metadata",
            sourceID: "med-1",
            petID: "pet-1",
            petName: "Zola",
            category: .medication,
            title: "Metacam",
            dueOn: moment(2026, 9, 12),
            daysUntilDue: 7,
            urgency: .upcoming
        )

        let notifications = notificationPlanner.plan(
            dueItems: [metadata],
            doseOccurrences: ["med-1": [dueAt]],
            settings: .init(leadDays: [], horizonDays: 3),
            asOf: moment(2026, 9, 5, 9)
        )

        let notification = try #require(notifications.first)
        #expect(notifications.count == 1)
        #expect(notification.sourceID == "med-1")
        #expect(notification.dueAt == dueAt)
    }

    @Test("Medikamenten-Vorwarnungen tragen den ursprünglichen Fälligkeitstermin")
    func nonDoseNotificationCarriesOriginalDueTimestamp() throws {
        let notifications = notificationPlanner.plan(
            dueItems: [medicationItem(dueOn: moment(2026, 9, 12))],
            doseOccurrences: [:],
            medicationReminders: [],
            settings: .init(
                leadDays: [7],
                reminderTime: TimeOfDay(hour: 9),
                horizonDays: 14
            ),
            asOf: moment(2026, 9, 5, 8)
        )

        let notification = try #require(notifications.first)
        #expect(notification.fireDate == moment(2026, 9, 5, 9))
        #expect(notification.sourceID == "worm-1")
        #expect(notification.dueAt == moment(2026, 9, 12, 9))
    }

    @Test("Alarm-behandelte Dosen werden vor dem Benachrichtigungsbudget entfernt")
    func alarmHandledDosesAreRemovedBeforeBudgeting() {
        let asOf = moment(2026, 9, 5, 7)
        let medication = DueItemBuilder.MedicationInput(
            sourceID: "daily-1",
            petID: "pet-1",
            petName: "Zola",
            kind: .ongoing,
            productName: "Metacam",
            schedule: DoseSchedule(
                timesOfDay: [TimeOfDay(hour: 8)],
                startDate: moment(2026, 9, 5),
                doseLabel: "1/2 Tablette"
            )
        )
        let reminders = medicationPlanner.plan(
            medications: [medication],
            loggedDoses: [:],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 60,
            asOf: asOf
        )
        #expect(reminders.count == 61)

        let notifications = notificationPlanner.plan(
            dueItems: [],
            doseOccurrences: [:],
            medicationReminders: reminders,
            criticalDays: [:],
            alarmHandledReminders: Array(reminders.prefix(32)),
            settings: .init(leadDays: [30, 7, 1, 0], horizonDays: 60),
            asOf: asOf
        )

        #expect(notifications.count == 29)
        #expect(notifications.map(\.fireDate) == reminders.dropFirst(32).map(\.dueAt))
    }

    @Test("Ein Alarm ersetzt nur die Fälligkeits-, nicht die Vorab-Erinnerung")
    func handledReminderKeepsAdvanceLeadNotice() {
        let dueAt = moment(2026, 9, 12, 9)
        let handled = MedicationReminder(
            id: "rudel.medication.worm-1.due",
            sourceID: "worm-1",
            petID: "pet-1",
            petName: "Zola",
            title: "Wurmkur",
            category: .medication,
            dueAt: dueAt
        )

        let notifications = notificationPlanner.plan(
            dueItems: [medicationItem(dueOn: moment(2026, 9, 12))],
            doseOccurrences: [:],
            medicationReminders: [],
            criticalDays: [:],
            alarmHandledReminders: [handled],
            settings: .init(
                leadDays: [7, 0],
                reminderTime: TimeOfDay(hour: 9),
                horizonDays: 14
            ),
            asOf: moment(2026, 9, 5, 8)
        )

        #expect(notifications.map(\.fireDate) == [moment(2026, 9, 5, 9)])
    }

    @Test("Wiederholungsintervall ist optional und über den Initializer setzbar")
    func plannedNotificationSupportsOptionalRepeatInterval() {
        let repeating = NotificationPlanner.PlannedNotification(
            id: "repeat",
            fireDate: moment(2026, 9, 5, 8),
            title: "Metacam",
            body: "Gabe",
            petID: "pet-1",
            category: .dose,
            priority: 40,
            repeatInterval: 600
        )
        let standard = NotificationPlanner.PlannedNotification(
            id: "standard",
            fireDate: moment(2026, 9, 5, 8),
            title: "Metacam",
            body: "Gabe",
            petID: "pet-1",
            category: .dose,
            priority: 40
        )

        #expect(repeating.repeatInterval == 600)
        #expect(standard.repeatInterval == nil)
    }
}
