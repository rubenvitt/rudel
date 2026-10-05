import Foundation
import RudelEngine
import Testing

/// Feste Zeitpunkte in UTC — nie `Date()`.
private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year, month: month, day: day, hour: hour, minute: minute
    ).date!
}

/// Sonntag, 26.07.2026, 08:00 UTC — vor der Standard-Erinnerungszeit 09:00.
private let now = at(2026, 7, 26, 8)

@Suite("NotificationPlanner — Tierarzttermine und Vorsorge")
struct NotificationPlannerAppointmentTests {

    private let builder = DueItemBuilder(dayMath: .utc)
    private let planner = NotificationPlanner(dayMath: .utc)
    private let settings = NotificationPlanner.Settings(
        leadDays: [7, 1, 0],
        reminderTime: TimeOfDay(hour: 9),
        horizonDays: 14
    )

    private func appointmentItems(
        at date: Date,
        title: String = "Impfung",
        detail: String? = "Praxis am Park",
        asOf: Date = now
    ) -> [DueItem] {
        builder.build(
            medications: [],
            cycles: [],
            appointments: [
                DueItemBuilder.AppointmentInput(
                    sourceID: "appt-1",
                    petID: "pet-1",
                    petName: "Zola",
                    title: title,
                    detail: detail,
                    at: date
                )
            ],
            asOf: asOf
        )
    }

    private func plan(
        _ items: [DueItem],
        settings: NotificationPlanner.Settings? = nil,
        asOf: Date = now
    ) -> [NotificationPlanner.PlannedNotification] {
        planner.plan(
            dueItems: items,
            doseOccurrences: [:],
            settings: settings ?? self.settings,
            asOf: asOf
        )
    }

    // MARK: - Termine

    @Test("Ein Termin erinnert am Vortag zur Erinnerungszeit und zwei Stunden vorher")
    func dayBeforeAndLead() {
        let start = at(2026, 7, 28, 10, 30)
        let notifications = plan(appointmentItems(at: start))

        #expect(notifications.map(\.fireDate) == [at(2026, 7, 27, 9), at(2026, 7, 28, 8, 30)])
        #expect(notifications.map(\.body) == [
            "Morgen um 10:30 · Impfung · Praxis am Park.",
            "Heute um 10:30 · Impfung · Praxis am Park.",
        ])
        #expect(notifications.allSatisfy { $0.title == "Zola — Tierarzttermin" })
        #expect(notifications.allSatisfy { $0.category == .vetAppointment })
        #expect(notifications.allSatisfy { $0.sourceID == "appt-1" && $0.dueAt == start })
        #expect(notifications.allSatisfy { $0.petID == "pet-1" && $0.repeatInterval == nil })
        #expect(Set(notifications.map(\.id)).count == 2)
    }

    @Test("Die Vorlaufzeit ist einstellbar")
    func customLead() {
        let notifications = plan(
            appointmentItems(at: at(2026, 7, 28, 10, 30)),
            settings: .init(leadDays: [7, 1, 0], horizonDays: 14, appointmentLeadMinutes: 30)
        )
        #expect(notifications.map(\.fireDate) == [at(2026, 7, 27, 9), at(2026, 7, 28, 10)])
    }

    @Test("Standard-Vorlauf sind 120 Minuten")
    func defaultLead() {
        #expect(NotificationPlanner.Settings().appointmentLeadMinutes == 120)
    }

    @Test("Der Tag im Text richtet sich nach dem Abstand, nicht nach der Art der Mitteilung")
    func leadCrossingMidnight() {
        let notifications = plan(appointmentItems(at: at(2026, 7, 28, 1), title: "Tierarzttermin", detail: nil))

        #expect(notifications.map(\.fireDate) == [at(2026, 7, 27, 9), at(2026, 7, 27, 23)])
        // Zwei Stunden vor 01:00 ist noch der Vorabend — also „Morgen". Ein
        // Titel, der nur die Überschrift wiederholt, fällt weg.
        #expect(notifications.map(\.body) == ["Morgen um 01:00.", "Morgen um 01:00."])
    }

    @Test("Ein verstrichener Vortag fällt weg, die Vorlauf-Mitteilung bleibt")
    func dayBeforeAlreadyPassed() {
        let asOf = at(2026, 7, 28, 7)
        let notifications = plan(appointmentItems(at: at(2026, 7, 28, 10, 30), asOf: asOf), asOf: asOf)
        #expect(notifications.map(\.fireDate) == [at(2026, 7, 28, 8, 30)])
    }

    @Test("Nach Terminbeginn kommt nichts mehr — auch nicht der nächste reguläre Slot")
    func nothingAfterStart() throws {
        for asOf in [at(2026, 7, 28, 11), at(2026, 8, 3, 8)] {
            let items = appointmentItems(at: at(2026, 7, 28, 10, 30), asOf: asOf)
            // Der Termin steht noch offen auf dem Dashboard …
            let item = try #require(items.first)
            #expect(item.urgency == .dueToday)
            // … erzeugt aber keine Mitteilung.
            #expect(plan(items, asOf: asOf).isEmpty)
        }
    }

    @Test("Ein Termin außerhalb des Fensters erzeugt keine Mitteilung")
    func outsideHorizon() {
        // Der Builder nimmt ihn auf (30 Tage), das Mitteilungsfenster ist 14 Tage.
        let items = appointmentItems(at: at(2026, 8, 20, 10))
        #expect(items.count == 1)
        #expect(plan(items).isEmpty)
    }

    @Test("Termine stehen zwischen „fällig jetzt\" und den heutigen Gaben")
    func appointmentPriority() throws {
        let overdue = builder.build(
            medications: [
                DueItemBuilder.MedicationInput(
                    sourceID: "worm-1",
                    petID: "pet-1",
                    petName: "Zola",
                    kind: .dewormer,
                    productName: "Milbemax"
                )
            ],
            cycles: [],
            asOf: now
        )
        let dose = DueItem(
            id: "dose",
            sourceID: "med-1",
            petID: "pet-1",
            petName: "Zola",
            category: .dose,
            title: "Metacam",
            dueOn: at(2026, 7, 26, 20),
            daysUntilDue: 0,
            urgency: .dueToday
        )
        let notifications = plan(overdue + [dose] + appointmentItems(at: at(2026, 7, 26, 18)))

        let dueNow = try #require(notifications.first { $0.sourceID == "worm-1" })
        let doseToday = try #require(notifications.first { $0.category == .dose })
        let appointment = try #require(notifications.first { $0.category == .vetAppointment })
        #expect(appointment.priority == 45)
        #expect(dueNow.priority > appointment.priority)
        #expect(appointment.priority > doseToday.priority)
    }

    // MARK: - Tierarzttermin vereinbaren

    @Test("Ohne geplanten Termin: Überschrift und Text sagen „Tierarzttermin vereinbaren\"")
    func needsAppointmentWording() throws {
        let items = builder.build(
            medications: [
                DueItemBuilder.MedicationInput(
                    sourceID: "rabies-1",
                    petID: "pet-1",
                    petName: "Zola",
                    kind: .rabiesVaccination,
                    productName: "Rabisin",
                    lastGivenOn: at(2025, 8, 2),
                    effectiveDays: 365,
                    requiresVetVisit: true
                )
            ],
            cycles: [],
            asOf: now
        )
        let notifications = plan(items)

        let first = try #require(notifications.first)
        #expect(notifications.count == 3)
        #expect(notifications.allSatisfy { $0.title == "Zola — Tierarzttermin vereinbaren" })
        #expect(first.fireDate == at(2026, 7, 26, 9))
        #expect(first.body
            == "Tollwut-Impfung: der Schutz läuft in 7 Tagen ab (02.08.2026) — Rabisin. Termin beim Tierarzt vereinbaren.")
    }

    @Test("Ein offener Termin unterdrückt die Mitteilungen der Gabe")
    func openAppointmentSilencesMedication() {
        let items = builder.build(
            medications: [
                DueItemBuilder.MedicationInput(
                    sourceID: "rabies-1",
                    petID: "pet-1",
                    petName: "Zola",
                    kind: .rabiesVaccination,
                    productName: "",
                    lastGivenOn: at(2025, 8, 2),
                    effectiveDays: 365,
                    requiresVetVisit: true,
                    hasOpenAppointment: true
                )
            ],
            cycles: [],
            asOf: now
        )
        #expect(plan(items).isEmpty)
    }

    // MARK: - Vorsorge: Zurückstellen und Auslassen

    @Test("Ein zurückgestellter Zeckenschutz erinnert ans neue Datum und spricht von „fällig\"")
    func deferredProtectionWording() throws {
        let items = builder.build(
            medications: [
                DueItemBuilder.MedicationInput(
                    sourceID: "tick-1",
                    petID: "pet-1",
                    petName: "Zola",
                    kind: .tickProtection,
                    productName: "Bravecto",
                    lastGivenOn: at(2026, 7, 1),
                    effectiveDays: 30,
                    deferredUntil: at(2026, 8, 5)
                )
            ],
            cycles: [],
            asOf: now
        )
        let notifications = plan(items)

        #expect(notifications.map(\.fireDate) == [at(2026, 7, 29, 9), at(2026, 8, 4, 9), at(2026, 8, 5, 9)])
        #expect(notifications.allSatisfy { $0.title == "Zola — Zeckenschutz fällig" })
        let first = try #require(notifications.first)
        #expect(first.body == "Zeckenschutz ist in 7 Tagen fällig (05.08.2026) — Bravecto.")
    }

    @Test("Nach einer Auslassung ist der Schutz weg — die Mitteilung spricht von der nächsten Gabe")
    func skippedProtectionWording() throws {
        let items = builder.build(
            medications: [
                DueItemBuilder.MedicationInput(
                    sourceID: "tick-1",
                    petID: "pet-1",
                    petName: "Zola",
                    kind: .tickProtection,
                    productName: "",
                    lastGivenOn: at(2026, 6, 1),
                    effectiveDays: 30,
                    lastSkippedOn: at(2026, 7, 1)
                )
            ],
            cycles: [],
            asOf: now
        )
        let notifications = plan(items, settings: .init(leadDays: [0], horizonDays: 14))

        let notification = try #require(notifications.first)
        #expect(notifications.count == 1)
        #expect(notification.fireDate == at(2026, 7, 31, 9))
        #expect(notification.title == "Zola — Zeckenschutz fällig")
        #expect(notification.body == "Zeckenschutz ist heute fällig.")
    }

    @Test("Nach verstrichener Zurückstellung behauptet keine Mitteilung, der Schutz ende am verschobenen Tag",
          arguments: [(1, "Zeckenschutz ist heute fällig."),
                      (10, "Zeckenschutz war am 01.03.2027 fällig — seit 9 Tagen überfällig.")])
    func expiredDeferralProtectionWording(day: Int, expectedBody: String) throws {
        // Gabe 01.11., 30 Tage ⇒ Schutz seit 01.12. weg; zurückgestellt bis 01.03.
        let asOf = at(2027, 3, day, 8)
        let items = builder.build(
            medications: [
                DueItemBuilder.MedicationInput(
                    sourceID: "tick-1",
                    petID: "pet-1",
                    petName: "Zola",
                    kind: .tickProtection,
                    productName: "",
                    lastGivenOn: at(2026, 11, 1),
                    effectiveDays: 30,
                    deferredUntil: at(2027, 3, 1)
                )
            ],
            cycles: [],
            asOf: asOf
        )
        let item = try #require(items.first)
        #expect(item.protectionEndsOn == at(2026, 12, 1))

        let notifications = plan(items, settings: .init(leadDays: [0], horizonDays: 14), asOf: asOf)
        let notification = try #require(notifications.first)
        #expect(notifications.allSatisfy { $0.title == "Zola — Zeckenschutz fällig" })
        #expect(notification.body == expectedBody)
        #expect(notifications.allSatisfy { !$0.body.contains("Schutz läuft") && !$0.body.contains("abgelaufen") })
    }

    @Test("Noch nie gegeben: kein Schutz, der ablaufen könnte — die Mitteilung spricht von „fällig\"")
    func neverGivenProtectionWording() throws {
        let items = builder.build(
            medications: [
                DueItemBuilder.MedicationInput(
                    sourceID: "tick-1",
                    petID: "pet-1",
                    petName: "Zola",
                    kind: .tickProtection,
                    productName: "",
                    effectiveDays: 30
                )
            ],
            cycles: [],
            asOf: now
        )
        let notification = try #require(plan(items, settings: .init(leadDays: [0], horizonDays: 14)).first)
        #expect(notification.title == "Zola — Zeckenschutz fällig")
        #expect(!notification.body.contains("läuft"))
    }

    @Test("Ein laufender Schutz behält seine Ablauf-Formulierung")
    func regularProtectionWordingUnchanged() throws {
        let items = builder.build(
            medications: [
                DueItemBuilder.MedicationInput(
                    sourceID: "tick-1",
                    petID: "pet-1",
                    petName: "Zola",
                    kind: .tickProtection,
                    productName: "",
                    lastGivenOn: at(2026, 7, 1),
                    effectiveDays: 30
                )
            ],
            cycles: [],
            asOf: now
        )
        let notifications = plan(items, settings: .init(leadDays: [1], horizonDays: 14))

        let notification = try #require(notifications.first)
        #expect(notification.title == "Zola — Zeckenschutz läuft ab")
        #expect(notification.body == "Zeckenschutz: der Schutz läuft morgen ab (31.07.2026).")
    }
}
