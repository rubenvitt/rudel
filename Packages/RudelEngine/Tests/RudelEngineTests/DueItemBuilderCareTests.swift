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

@Suite("DueItemBuilder — Vorsorge, Auslassen, Zurückstellen, Tierarzt")
struct DueItemBuilderCareTests {

    let builder = DueItemBuilder(dayMath: .utc)
    /// „Heute" in allen Tests: Sonntag, 26.07.2026.
    let today = moment(2026, 7, 26)

    // MARK: Fixtures

    private func medication(
        _ sourceID: String = "m1",
        kind: MedicationKind = .dewormer,
        productName: String = "",
        lastGivenOn: Date? = nil,
        intervalDays: Int? = nil,
        effectiveDays: Int? = nil,
        schedule: DoseSchedule? = nil,
        careClass: MedicationCareClass? = nil,
        lastSkippedOn: Date? = nil,
        deferredUntil: Date? = nil,
        requiresVetVisit: Bool = false,
        hasOpenAppointment: Bool = false
    ) -> DueItemBuilder.MedicationInput {
        DueItemBuilder.MedicationInput(
            sourceID: sourceID,
            petID: "p1",
            petName: "Nala",
            kind: kind,
            productName: productName,
            lastGivenOn: lastGivenOn,
            intervalDays: intervalDays,
            effectiveDays: effectiveDays,
            schedule: schedule,
            careClass: careClass,
            lastSkippedOn: lastSkippedOn,
            deferredUntil: deferredUntil,
            requiresVetVisit: requiresVetVisit,
            hasOpenAppointment: hasOpenAppointment
        )
    }

    private func dailyDose(startDate: Date) -> DoseSchedule {
        DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8), TimeOfDay(hour: 20)],
            startDate: startDate,
            doseLabel: "1 Tablette"
        )
    }

    private func appointment(
        _ sourceID: String = "a1",
        at: Date,
        title: String = "Impfung",
        detail: String? = "Praxis am Park",
        linkedMedicationSourceID: String? = nil
    ) -> DueItemBuilder.AppointmentInput {
        DueItemBuilder.AppointmentInput(
            sourceID: sourceID,
            petID: "p1",
            petName: "Nala",
            title: title,
            detail: detail,
            at: at,
            linkedMedicationSourceID: linkedMedicationSourceID
        )
    }

    private func build(
        _ medications: [DueItemBuilder.MedicationInput],
        appointments: [DueItemBuilder.AppointmentInput] = [],
        asOf: Date? = nil,
        horizon: Int = 30
    ) -> [DueItem] {
        builder.build(
            medications: medications,
            cycles: [],
            appointments: appointments,
            asOf: asOf ?? today,
            forecastHorizonDays: horizon
        )
    }

    // MARK: Erinnerungsklasse

    @Test("Nur das Dauermedikament ist standardmäßig zeitkritisch")
    func defaultCareClasses() {
        #expect(MedicationKind.ongoing.defaultCareClass == .timeCritical)
        #expect(MedicationKind.dewormer.defaultCareClass == .preventive)
        #expect(MedicationKind.tickProtection.defaultCareClass == .preventive)
        #expect(MedicationKind.rabiesVaccination.defaultCareClass == .preventive)
    }

    @Test("Nur die Tollwut-Impfung braucht standardmäßig einen Tierarzttermin")
    func defaultRequiresVetVisit() {
        #expect(MedicationKind.rabiesVaccination.defaultRequiresVetVisit)
        #expect(!MedicationKind.dewormer.defaultRequiresVetVisit)
        #expect(!MedicationKind.tickProtection.defaultRequiresVetVisit)
        #expect(!MedicationKind.ongoing.defaultRequiresVetVisit)
    }

    @Test("Ohne Override gilt der Standard der Art, ein Override bleibt")
    func inputCareClassFallsBackToKind() {
        #expect(medication(kind: .ongoing).careClass == .timeCritical)
        #expect(medication(kind: .dewormer).careClass == .preventive)
        #expect(medication(kind: .ongoing, careClass: .preventive).careClass == .preventive)
        #expect(medication(kind: .dewormer, careClass: .timeCritical).careClass == .timeCritical)
    }

    @Test("Jeder Medikamenten-Pfad reicht die Klasse ans Item durch")
    func careClassOnEveryMedicationPath() throws {
        let items = build([
            medication("worm", kind: .dewormer, lastGivenOn: moment(2026, 7, 1), intervalDays: 30),
            medication("tick", kind: .tickProtection, lastGivenOn: moment(2026, 7, 1), effectiveDays: 30),
            medication("never", kind: .rabiesVaccination, careClass: .timeCritical),
            medication("dose", kind: .ongoing, schedule: dailyDose(startDate: moment(2026, 7, 1))),
        ], appointments: [appointment(at: moment(2026, 7, 28, 10))])

        let byID = Dictionary(grouping: items, by: \.sourceID)
        #expect(try #require(byID["worm"]?.first).careClass == .preventive)
        #expect(try #require(byID["tick"]?.first).careClass == .preventive)
        #expect(try #require(byID["never"]?.first).careClass == .timeCritical)
        let doses = try #require(byID["dose"])
        #expect(doses.count == 2)
        #expect(doses.allSatisfy { $0.careClass == .timeCritical })
        // Termine sind keine Medikamente.
        #expect(try #require(byID["a1"]?.first).careClass == nil)
    }

    // MARK: Auslassen

    @Test("Eine Auslassung verschiebt die nächste Wurmkur wie eine Gabe")
    func skipShiftsDewormer() throws {
        let item = try #require(build([
            medication(lastGivenOn: moment(2026, 6, 1), intervalDays: 30, lastSkippedOn: moment(2026, 7, 1))
        ]).first)
        #expect(item.dueOn == moment(2026, 7, 31))
        #expect(item.daysUntilDue == 5)
        #expect(item.urgency == .upcoming)
    }

    @Test("Eine ältere Auslassung ändert nichts — es zählt das spätere Datum")
    func olderSkipIsIgnored() throws {
        let item = try #require(build([
            medication(lastGivenOn: moment(2026, 7, 1), intervalDays: 30, lastSkippedOn: moment(2026, 6, 1))
        ]).first)
        #expect(item.dueOn == moment(2026, 7, 31))
    }

    @Test("Eine Auslassung schiebt die Fälligkeit, nicht den Schutzbalken")
    func skipDoesNotRefillProtection() throws {
        // Gabe am 01.06., Wirkdauer 30 Tage ⇒ Schutz seit 01.07. weg. Am 01.07.
        // ausgelassen ⇒ nächste Erinnerung am 31.07., Balken bleibt leer.
        let item = try #require(build([
            medication(
                kind: .tickProtection,
                lastGivenOn: moment(2026, 6, 1),
                effectiveDays: 30,
                lastSkippedOn: moment(2026, 7, 1)
            )
        ]).first)
        #expect(item.category == .protectionExpiry)
        #expect(item.dueOn == moment(2026, 7, 31))
        #expect(item.remainingFraction == 0)
        #expect(item.urgency == .upcoming)
    }

    @Test("Nur ausgelassen, nie gegeben: kein „noch nie gegeben\", Balken auf null")
    func skippedButNeverGiven() throws {
        let item = try #require(build([
            medication(
                kind: .tickProtection,
                productName: "Bravecto",
                effectiveDays: 30,
                lastSkippedOn: moment(2026, 7, 20)
            )
        ]).first)
        #expect(item.dueOn == moment(2026, 8, 19))
        #expect(item.daysUntilDue == 24)
        #expect(item.urgency == .scheduled)
        #expect(item.remainingFraction == 0)
        #expect(item.detail == "Bravecto")
    }

    // MARK: Zurückstellen

    @Test("Zurückstellen schiebt die Fälligkeit und stuft nach dem neuen Datum ein")
    func deferralShiftsDueDate() throws {
        let item = try #require(build([
            medication(
                lastGivenOn: moment(2026, 7, 1),
                intervalDays: 30,
                // Uhrzeit wird auf den Tagesbeginn normalisiert.
                deferredUntil: moment(2026, 9, 1, 15, 30)
            )
        ]).first)
        #expect(item.dueOn == moment(2026, 9, 1))
        #expect(item.daysUntilDue == 37)
        #expect(item.urgency == .scheduled)
        #expect(item.deferredUntil == moment(2026, 9, 1))
    }

    @Test("Eine Zurückstellung vor der regulären Fälligkeit ist wirkungslos")
    func deferralBeforeRegularDueHasNoEffect() throws {
        let item = try #require(build([
            medication(lastGivenOn: moment(2026, 7, 1), intervalDays: 30, deferredUntil: moment(2026, 7, 28))
        ]).first)
        #expect(item.dueOn == moment(2026, 7, 31))
        #expect(item.deferredUntil == nil)
    }

    @Test("Zurückstellen gilt auch für „noch nie gegeben\"")
    func deferralAppliesToNeverGiven() throws {
        let item = try #require(build([
            medication(kind: .tickProtection, productName: "Bravecto", deferredUntil: moment(2027, 3, 1))
        ]).first)
        #expect(item.dueOn == moment(2027, 3, 1))
        #expect(item.urgency == .scheduled)
        #expect(item.deferredUntil == moment(2027, 3, 1))
        #expect(item.remainingFraction == 0)
        #expect(item.detail == "Bravecto · noch nie gegeben")
    }

    @Test("Eine verstrichene Zurückstellung macht „noch nie gegeben\" nicht harmloser")
    func pastDeferralKeepsNeverGivenOverdue() throws {
        let item = try #require(build([
            medication(kind: .dewormer, deferredUntil: moment(2026, 7, 20))
        ]).first)
        #expect(item.dueOn == today)
        #expect(item.urgency == .overdue)
        #expect(item.deferredUntil == nil)
    }

    @Test("Nach Ablauf der Zurückstellung zählt die Überfälligkeit ab deren Ende")
    func expiredDeferralCountsOverdueFromItsEnd() throws {
        // Regulär fällig am 31.05., zurückgestellt bis 20.07. — heute 26.07.
        let item = try #require(build([
            medication(lastGivenOn: moment(2026, 5, 1), intervalDays: 30, deferredUntil: moment(2026, 7, 20))
        ]).first)
        #expect(item.dueOn == moment(2026, 7, 20))
        #expect(item.daysUntilDue == -6)
        #expect(item.urgency == .overdue)
        #expect(item.deferredUntil == nil)
    }

    @Test("Das Schutzende bleibt nach Zurückstellung und Auslassung beim Gabetag plus Wirkdauer",
          arguments: [(2027, 3, 1), (2027, 3, 10)])
    func protectionEndSurvivesExpiredDeferral(year: Int, month: Int, day: Int) throws {
        // Gabe 01.11., 30 Tage ⇒ Schutz bis 01.12., zurückgestellt bis 01.03.
        let item = try #require(build([
            medication(
                kind: .tickProtection,
                lastGivenOn: moment(2026, 11, 1),
                effectiveDays: 30,
                deferredUntil: moment(2027, 3, 1)
            )
        ], asOf: moment(year, month, day, 8)).first)
        #expect(item.dueOn == moment(2027, 3, 1))
        #expect(item.deferredUntil == nil)
        #expect(item.remainingFraction == 0)
        #expect(item.protectionEndsOn == moment(2026, 12, 1))
    }

    @Test("Schutzende: laufend gleich der Fälligkeit, nach Auslassung davor, ohne Gabe nil")
    func protectionEndPerPath() throws {
        let running = try #require(build([
            medication(kind: .tickProtection, lastGivenOn: moment(2026, 7, 1), effectiveDays: 30)
        ]).first)
        #expect(running.protectionEndsOn == running.dueOn)

        let skipped = try #require(build([
            medication(kind: .tickProtection, lastGivenOn: moment(2026, 6, 1), effectiveDays: 30,
                       lastSkippedOn: moment(2026, 7, 1))
        ]).first)
        #expect(skipped.protectionEndsOn == moment(2026, 7, 1))
        #expect(skipped.dueOn == moment(2026, 7, 31))

        let neverGiven = try #require(build([
            medication(kind: .tickProtection, effectiveDays: 30)
        ]).first)
        #expect(neverGiven.protectionEndsOn == nil)

        let onlySkipped = try #require(build([
            medication(kind: .tickProtection, effectiveDays: 30, lastSkippedOn: moment(2026, 7, 20))
        ]).first)
        #expect(onlySkipped.protectionEndsOn == nil)

        let dewormer = try #require(build([
            medication(lastGivenOn: moment(2026, 7, 1), intervalDays: 30)
        ]).first)
        #expect(dewormer.protectionEndsOn == nil)
    }

    @Test("Ein zurückgestelltes Dauermedikament hat bis dahin keine Dosis-Items")
    func deferredOngoingHasNoDoseItems() {
        let schedule = dailyDose(startDate: moment(2026, 7, 1))
        let deferred = build([
            medication(kind: .ongoing, schedule: schedule, deferredUntil: moment(2026, 7, 28))
        ])
        #expect(deferred.isEmpty)

        // Am Tag der Zurückstellung geht es wieder los.
        let resumed = build([
            medication(kind: .ongoing, schedule: schedule, deferredUntil: moment(2026, 7, 26, 18))
        ])
        #expect(resumed.count == 2)
    }

    // MARK: Tierarzttermin

    @Test("Ein offener Termin ersetzt das Medikamenten-Item")
    func openAppointmentSuppressesItem() {
        let items = build([
            medication(
                kind: .rabiesVaccination,
                lastGivenOn: moment(2025, 7, 1),
                effectiveDays: 365,
                requiresVetVisit: true,
                hasOpenAppointment: true
            ),
            // Auch ohne Pflicht zum Termin und bei „noch nie gegeben".
            medication("m2", kind: .dewormer, hasOpenAppointment: true),
        ])
        #expect(items.isEmpty)
    }

    @Test("Ein Termin am Dauermedikament verschluckt keine Gaben")
    func appointmentDoesNotSuppressDoses() {
        let items = build([
            medication(
                kind: .ongoing,
                schedule: dailyDose(startDate: moment(2026, 7, 1)),
                requiresVetVisit: true,
                hasOpenAppointment: true
            )
        ])
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.needsVetAppointment })
    }

    @Test("Ohne geplanten Termin: Tierarzttermin vereinbaren")
    func needsVetAppointmentWithoutOpenAppointment() throws {
        let item = try #require(build([
            medication(
                kind: .rabiesVaccination,
                lastGivenOn: moment(2025, 8, 1),
                effectiveDays: 365,
                requiresVetVisit: true
            )
        ]).first)
        #expect(item.needsVetAppointment)
        #expect(item.title == "Tollwut-Impfung")
        #expect(item.dueOn == moment(2026, 8, 1))
    }

    @Test("Ohne Tierarzt-Pflicht kein Termin-Hinweis")
    func noVetAppointmentFlagWithoutRequirement() throws {
        let item = try #require(build([
            medication(kind: .rabiesVaccination, lastGivenOn: moment(2025, 8, 1), effectiveDays: 365)
        ]).first)
        #expect(!item.needsVetAppointment)
    }

    @Test("Ein verknüpfter Termin allein unterdrückt nichts — maßgeblich ist hasOpenAppointment")
    func linkedAppointmentAloneSuppressesNothing() {
        let items = build(
            [medication(lastGivenOn: moment(2026, 7, 1), intervalDays: 30)],
            appointments: [appointment(at: moment(2026, 7, 28, 10), linkedMedicationSourceID: "m1")],
            asOf: moment(2026, 7, 26, 8)
        )
        #expect(Set(items.map(\.category)) == [.medication, .vetAppointment])
    }

    // MARK: Termine

    @Test("Ein künftiger Termin trägt Uhrzeit und Dringlichkeit aus dem Termintag")
    func futureAppointment() throws {
        let at = moment(2026, 7, 29, 10, 30)
        let item = try #require(build([], appointments: [appointment(at: at)], asOf: moment(2026, 7, 26, 8)).first)
        #expect(item.id == "appt:a1")
        #expect(item.sourceID == "a1")
        #expect(item.category == .vetAppointment)
        #expect(item.title == "Impfung")
        #expect(item.detail == "Praxis am Park")
        #expect(item.dueOn == at)
        #expect(item.daysUntilDue == 3)
        #expect(item.urgency == .dueSoon)
        #expect(!item.isForecast)
        #expect(item.remainingFraction == nil)
    }

    @Test("Ein Termin heute, noch nicht begonnen, ist heute fällig")
    func appointmentLaterToday() throws {
        let item = try #require(build(
            [],
            appointments: [appointment(at: moment(2026, 7, 26, 15))],
            asOf: moment(2026, 7, 26, 8)
        ).first)
        #expect(item.daysUntilDue == 0)
        #expect(item.urgency == .dueToday)
    }

    @Test("Ein Termin hinter dem Horizont erscheint nicht")
    func appointmentBeyondHorizon() {
        let items = build(
            [],
            appointments: [appointment(at: moment(2026, 9, 30, 10))],
            asOf: moment(2026, 7, 26, 8),
            horizon: 30
        )
        #expect(items.isEmpty)
    }

    @Test("Ein begonnener, offener Termin bleibt als heute fällig stehen — auch Tage später")
    func startedAppointmentStaysDueToday() throws {
        for at in [moment(2026, 7, 26, 7), moment(2026, 7, 10, 10)] {
            let item = try #require(build([], appointments: [appointment(at: at)], asOf: moment(2026, 7, 26, 8)).first)
            #expect(item.dueOn == at)
            #expect(item.daysUntilDue == 0)
            #expect(item.urgency == .dueToday)
        }
    }

    @Test("Ohne Termine-Argument bleibt alles wie bisher")
    func omittedAppointmentsChangeNothing() {
        let medications = [medication(lastGivenOn: moment(2026, 7, 1), intervalDays: 30)]
        #expect(
            builder.build(medications: medications, cycles: [], asOf: today)
                == builder.build(medications: medications, cycles: [], appointments: [], asOf: today)
        )
    }
}
