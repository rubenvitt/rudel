import Foundation
import RudelEngine
import Testing

/// Alle Fixtures sind feste Kalendertage in UTC — nie `Date()`. Sonst wäre der
/// Test am 31. Dezember ein anderer als am 1. Januar.
private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year, month: month, day: day
    ).date!
}

@Suite("DueItemBuilder")
struct DueItemBuilderTests {

    let builder = DueItemBuilder(dayMath: .utc)
    /// „Heute" in allen Tests.
    let today = day(2026, 7, 26)

    // MARK: Fixtures

    private func medication(
        _ sourceID: String = "m1",
        pet: String = "p1",
        petName: String = "Nala",
        kind: MedicationKind = .dewormer,
        productName: String = "",
        lastGivenOn: Date? = nil,
        intervalDays: Int? = nil,
        effectiveDays: Int? = nil,
        schedule: DoseSchedule? = nil,
        isActive: Bool = true
    ) -> DueItemBuilder.MedicationInput {
        DueItemBuilder.MedicationInput(
            sourceID: sourceID,
            petID: pet,
            petName: petName,
            kind: kind,
            productName: productName,
            lastGivenOn: lastGivenOn,
            intervalDays: intervalDays,
            effectiveDays: effectiveDays,
            schedule: schedule,
            isActive: isActive
        )
    }

    /// Prognose-Fixture aus den Studienwerten: Punktschätzung = letzter Anker
    /// plus `StudyConstants.day1ToDay1IntervalDays`, Band symmetrisch darum.
    private func prediction(
        expected: Date,
        halfWidthDays: Double,
        confidence: Confidence = .low,
        basis: PredictionBasis = .population,
        observedIntervalDays: [Int] = []
    ) -> CyclePrediction {
        let half = Int(halfWidthDays.rounded())
        let bandStart = DayMath.utc.adding(days: -half, to: expected)
        let bandEnd = DayMath.utc.adding(days: half, to: expected)
        return CyclePrediction(
            expectedDate: expected,
            range: bandStart...bandEnd,
            confidence: confidence,
            basis: basis,
            observedIntervalDays: observedIntervalDays,
            effectiveIntervalDays: Double(StudyConstants.day1ToDay1IntervalDays),
            bandHalfWidthDays: halfWidthDays
        )
    }

    private func cycle(
        _ sourceID: String = "c1",
        pet: String = "p1",
        petName: String = "Nala",
        prediction: CyclePrediction?
    ) -> DueItemBuilder.CycleInput {
        DueItemBuilder.CycleInput(
            sourceID: sourceID,
            petID: pet,
            petName: petName,
            prediction: prediction
        )
    }

    // MARK: Leere und übersprungene Eingaben

    @Test("Leere Eingabe ergibt leere Liste")
    func leereEingabe() {
        #expect(builder.build(medications: [], cycles: [], asOf: today).isEmpty)
    }

    @Test("Abgesetztes Medikament erzeugt kein Item")
    func inaktiverPlan() {
        let items = builder.build(
            medications: [
                medication(lastGivenOn: day(2026, 1, 1), intervalDays: 90, isActive: false)
            ],
            cycles: [],
            asOf: today
        )
        #expect(items.isEmpty)
    }

    @Test("Zyklus ohne Prognose erzeugt kein Item")
    func zyklusOhnePrognose() {
        #expect(builder.build(
            medications: [],
            cycles: [cycle(prediction: nil)],
            asOf: today
        ).isEmpty)
    }

    // MARK: „Noch nie gegeben"

    @Test("Noch nie gegebene Wurmkur ist überfällig, fällig heute")
    func nochNieGegebenIstUeberfaellig() throws {
        let items = builder.build(
            medications: [medication(kind: .dewormer, productName: "Milbemax")],
            cycles: [],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.urgency == .overdue)
        #expect(item.dueOn == today)
        #expect(item.daysUntilDue == 0)
        #expect(item.category == .medication)
        #expect(item.remainingFraction == nil)
        #expect(item.isForecast == false)
    }

    @Test("Noch nie gegebener Zeckenschutz hat Restwirksamkeit 0")
    func nochNieGegebenerZeckenschutz() throws {
        let items = builder.build(
            medications: [
                medication(kind: .tickProtection, productName: "Bravecto", effectiveDays: 84)
            ],
            cycles: [],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.urgency == .overdue)
        #expect(item.dueOn == today)
        #expect(item.category == .protectionExpiry)
        #expect(item.remainingFraction == 0)
    }

    @Test("Noch nie gegeben schlägt ein fehlendes Intervall — kein stilles Verschwinden")
    func nochNieGegebenOhneKonfiguration() {
        let items = builder.build(
            medications: [
                medication("m1", kind: .dewormer),
                medication("m2", kind: .rabiesVaccination),
            ],
            cycles: [],
            asOf: today
        )
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.urgency == .overdue })
    }

    @Test("Überfällig steht in der Liste vor heute fällig")
    func nochNieGegebenStehtGanzOben() throws {
        // Dosis-Item wäre `.dueToday`; „noch nie gegeben" muss darüber landen.
        let items = builder.build(
            medications: [
                medication("m2", kind: .ongoing, productName: "Apoquel", schedule: DoseSchedule(
                    timesOfDay: [TimeOfDay(hour: 8)],
                    startDate: day(2026, 7, 1)
                )),
                medication("m1", kind: .dewormer),
            ],
            cycles: [],
            asOf: today
        )
        #expect(items.count == 2)
        #expect(try #require(items.first).urgency == .overdue)
        #expect(items[1].urgency == .dueToday)
    }

    // MARK: Intervall-Fälligkeit (Wurmkur)

    @Test("Wurmkur wird letzte Gabe plus Intervall fällig")
    func wurmkurIntervall() throws {
        let items = builder.build(
            medications: [
                medication(
                    kind: .dewormer,
                    productName: "Milbemax",
                    lastGivenOn: day(2026, 5, 1),
                    intervalDays: 90
                )
            ],
            cycles: [],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.dueOn == day(2026, 7, 30))
        #expect(item.daysUntilDue == 4)
        #expect(item.urgency == .upcoming)
        #expect(item.category == .medication)
        #expect(item.detail == "Milbemax")
    }

    @Test("Überfällige Wurmkur zählt negative Tage")
    func wurmkurUeberfaellig() throws {
        let items = builder.build(
            medications: [
                medication(kind: .dewormer, lastGivenOn: day(2026, 1, 1), intervalDays: 90)
            ],
            cycles: [],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.dueOn == day(2026, 4, 1))
        #expect(item.daysUntilDue == -116)
        #expect(item.urgency == .overdue)
    }

    @Test("Wurmkur ohne Intervall erzeugt kein Item, wenn sie schon gegeben wurde")
    func wurmkurOhneIntervall() {
        let items = builder.build(
            medications: [medication(kind: .dewormer, lastGivenOn: day(2026, 5, 1))],
            cycles: [],
            asOf: today
        )
        #expect(items.isEmpty)
    }

    @Test("Negatives oder null Intervall ist am Gabetag selbst fällig")
    func negativesIntervall() throws {
        for interval in [0, -5] {
            let items = builder.build(
                medications: [
                    medication(
                        kind: .dewormer,
                        lastGivenOn: day(2026, 7, 20),
                        intervalDays: interval
                    )
                ],
                cycles: [],
                asOf: today
            )
            let item = try #require(items.first)
            #expect(item.dueOn == day(2026, 7, 20))
            #expect(item.daysUntilDue == -6)
            #expect(item.urgency == .overdue)
        }
    }

    // MARK: Restwirksamkeit (Zeckenschutz, Tollwut)

    @Test("Restwirksamkeit ist der lineare Anteil der Wirkdauer")
    func restwirksamkeit() throws {
        let items = builder.build(
            medications: [
                medication(
                    kind: .tickProtection,
                    lastGivenOn: day(2026, 7, 11),
                    effectiveDays: 30
                )
            ],
            cycles: [],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.remainingFraction == 0.5)
        #expect(item.dueOn == day(2026, 8, 10))
        #expect(item.daysUntilDue == 15)
        #expect(item.urgency == .scheduled)
        #expect(item.category == .protectionExpiry)
    }

    @Test("Am Gabetag ist der Schutz voll")
    func schutzAmGabetag() throws {
        let items = builder.build(
            medications: [medication(kind: .tickProtection, lastGivenOn: today, effectiveDays: 30)],
            cycles: [],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.remainingFraction == 1.0)
        #expect(item.daysUntilDue == 30)
        #expect(item.urgency == .scheduled)
    }

    @Test("Abgelaufener Schutz hat Fraktion 0 und läuft nicht rückwärts")
    func abgelaufenerSchutz() throws {
        let items = builder.build(
            medications: [
                medication(
                    kind: .tickProtection,
                    lastGivenOn: day(2026, 6, 16),
                    effectiveDays: 30
                )
            ],
            cycles: [],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.remainingFraction == 0)
        #expect(item.daysUntilDue == -10)
        #expect(item.urgency == .overdue)
    }

    @Test("Wirkdauer 0 oder negativ ⇒ sofort abgelaufen, keine Division durch Null")
    func wirkdauerNullOderNegativ() throws {
        for effective in [0, -30] {
            let items = builder.build(
                medications: [
                    medication(kind: .tickProtection, lastGivenOn: today, effectiveDays: effective)
                ],
                cycles: [],
                asOf: today
            )
            let item = try #require(items.first)
            #expect(item.remainingFraction == 0)
            #expect(item.dueOn == today)
            #expect(item.daysUntilDue == 0)
            #expect(item.urgency == .dueToday)
        }
    }

    @Test("Tollwut rechnet identisch zum Zeckenschutz")
    func tollwutWieZeckenschutz() throws {
        let items = builder.build(
            medications: [
                medication(
                    kind: .rabiesVaccination,
                    productName: "Rabisin",
                    lastGivenOn: day(2025, 7, 26),
                    effectiveDays: 1095
                )
            ],
            cycles: [],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.category == .protectionExpiry)
        #expect(item.title == "Tollwut-Impfung")
        #expect(item.dueOn == day(2028, 7, 25))
        #expect(item.remainingFraction != nil)
        #expect(item.urgency == .scheduled)
    }

    @Test("Zeckenschutz ohne Wirkdauer erzeugt kein Item, wenn er schon gegeben wurde")
    func zeckenschutzOhneWirkdauer() {
        let items = builder.build(
            medications: [medication(kind: .tickProtection, lastGivenOn: day(2026, 7, 1))],
            cycles: [],
            asOf: today
        )
        #expect(items.isEmpty)
    }

    // MARK: Dauermedikament

    @Test("Dauermedikament erzeugt nur die heutigen Gaben, nicht den Horizont")
    func dauermedikamentNurHeute() throws {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 20), TimeOfDay(hour: 8)],
            startDate: day(2026, 7, 1),
            doseLabel: "1/2 Tablette"
        )
        let items = builder.build(
            medications: [
                medication(kind: .ongoing, productName: "Apoquel", schedule: schedule)
            ],
            cycles: [],
            asOf: today,
            forecastHorizonDays: 30
        )
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.category == .dose })
        #expect(items.allSatisfy { $0.urgency == .dueToday })
        #expect(items.allSatisfy { $0.daysUntilDue == 0 })
        #expect(items.allSatisfy { $0.title == "Apoquel" })
        #expect(items.allSatisfy { $0.detail == "1/2 Tablette" })
        #expect(items.allSatisfy { DayMath.utc.isSameDay($0.dueOn, today) })
        // Frühere Gabe zuerst: gleiche Stufe, aufsteigend nach `dueOn`.
        #expect(try #require(items.first).dueOn < items[1].dueOn)
    }

    @Test("Dauermedikament ohne Gabe in der Historie ist heute fällig, nicht überfällig")
    func dauermedikamentOhneHistorie() throws {
        let items = builder.build(
            medications: [
                medication(kind: .ongoing, productName: "Apoquel", schedule: DoseSchedule(
                    timesOfDay: [TimeOfDay(hour: 8)],
                    startDate: day(2026, 7, 1)
                ))
            ],
            cycles: [],
            asOf: today
        )
        #expect(try #require(items.first).urgency == .dueToday)
    }

    @Test("An einem Nicht-Gabetag entsteht kein Item")
    func nichtGabetag() {
        // Start 25.7., jeden 2. Tag ⇒ 25., 27., … — der 26. ist keiner.
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8)],
            everyNDays: 2,
            startDate: day(2026, 7, 25)
        )
        let items = builder.build(
            medications: [medication(kind: .ongoing, schedule: schedule)],
            cycles: [],
            asOf: today
        )
        #expect(items.isEmpty)
    }

    @Test("Vor Laufzeitbeginn und nach Laufzeitende entsteht kein Item")
    func ausserhalbDerLaufzeit() {
        let kuenftig = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8)],
            startDate: day(2026, 8, 1)
        )
        let beendet = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8)],
            startDate: day(2026, 6, 1),
            endDate: day(2026, 7, 25)
        )
        #expect(builder.build(
            medications: [medication("a", kind: .ongoing, schedule: kuenftig)],
            cycles: [],
            asOf: today
        ).isEmpty)
        #expect(builder.build(
            medications: [medication("b", kind: .ongoing, schedule: beendet)],
            cycles: [],
            asOf: today
        ).isEmpty)
    }

    @Test("Laufzeitende ist inklusiv")
    func laufzeitendeInklusiv() {
        let schedule = DoseSchedule(
            timesOfDay: [TimeOfDay(hour: 8)],
            startDate: day(2026, 6, 1),
            endDate: today
        )
        #expect(builder.build(
            medications: [medication(kind: .ongoing, schedule: schedule)],
            cycles: [],
            asOf: today
        ).count == 1)
    }

    @Test("Leere Gabezeiten erzeugen kein Item")
    func leereGabezeiten() {
        let schedule = DoseSchedule(timesOfDay: [], startDate: day(2026, 7, 1))
        #expect(builder.build(
            medications: [medication(kind: .ongoing, schedule: schedule)],
            cycles: [],
            asOf: today
        ).isEmpty)
    }

    @Test("Dauermedikament ohne Schema ist nicht überfällig, obwohl es nie gegeben wurde")
    func ongoingOhneSchema() {
        // Die „noch nie gegeben ⇒ überfällig"-Regel gilt ausdrücklich nur für
        // Wurmkur, Zeckenschutz und Tollwut. Ein Dauermedikament ohne
        // Dosierschema hat keinen Termin, den man verpassen könnte — es wäre
        // dauerhaft rot im Dashboard, ohne dass es etwas abzuhaken gäbe.
        let items = builder.build(
            medications: [medication(kind: .ongoing, productName: "Apoquel")],
            cycles: [],
            asOf: today
        )
        #expect(items.isEmpty)
    }

    // MARK: Zyklus-Prognose

    @Test("Dringlichkeit einer Prognose richtet sich nach dem Bandbeginn")
    func prognoseNutztBandbeginn() throws {
        // Punktschätzung liegt 10 Tage weg (⇒ wäre `.upcoming`), das Band
        // beginnt aber in 3 Tagen (⇒ `.dueSoon`).
        let expected = DayMath.utc.adding(days: 10, to: today)
        let items = builder.build(
            medications: [],
            cycles: [cycle(prediction: prediction(
                expected: expected,
                halfWidthDays: StudyConstants.intervalBandFloorDays
            ))],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.dueOn == DayMath.utc.adding(days: 3, to: today))
        #expect(item.daysUntilDue == 3)
        #expect(item.urgency == .dueSoon)
        #expect(item.category == .cycleForecast)
        #expect(item.isForecast == true)
        #expect(item.title == "Läufigkeit erwartet")
        #expect(item.detail == "Prognosefenster ± 7 Tage")
    }

    @Test("Prognose mit Studien-Startwerten: Bandbeginn jenseits des Horizonts fehlt")
    func prognoseAusserhalbDesHorizonts() {
        // Cold Start: letzter Anker + 210 Tage, Band ± Populations-SD (41 d).
        let anchor = day(2026, 3, 1)
        let expected = DayMath.utc.adding(
            days: StudyConstants.day1ToDay1IntervalDays,
            to: anchor
        )
        let vorhersage = prediction(
            expected: expected,
            halfWidthDays: StudyConstants.day1ToDay1IntervalPopulationSDDays
        )
        // Bandbeginn = 27.9.2026 − 41 d = 17.8.2026, also 22 Tage nach „heute".
        #expect(builder.build(
            medications: [],
            cycles: [cycle(prediction: vorhersage)],
            asOf: today,
            forecastHorizonDays: 21
        ).isEmpty)
        #expect(builder.build(
            medications: [],
            cycles: [cycle(prediction: vorhersage)],
            asOf: today,
            forecastHorizonDays: 22
        ).count == 1)
    }

    @Test("Größenklassen-Bias verschiebt die Prognose, ändert aber nicht die Regel")
    func prognoseMitGroessenklassenBias() throws {
        let anchor = day(2026, 1, 1)
        let expected = DayMath.utc.adding(
            days: StudyConstants.day1ToDay1IntervalDays
                + StudyConstants.intervalBiasDays(for: .large),
            to: anchor
        )
        let items = builder.build(
            medications: [],
            cycles: [cycle(prediction: prediction(
                expected: expected,
                halfWidthDays: StudyConstants.intervalBandFloorDays,
                confidence: .high,
                basis: .blended(ownIntervalCount: 3),
                observedIntervalDays: [212, 208, 215]
            ))],
            asOf: today,
            forecastHorizonDays: 30
        )
        // 1.1. + 210 + 15 = 14.8.2026, Bandbeginn 7.8.2026 ⇒ in 12 Tagen.
        let item = try #require(items.first)
        #expect(item.dueOn == day(2026, 8, 7))
        #expect(item.daysUntilDue == 12)
        #expect(item.urgency == .upcoming)
    }

    @Test("Bereits begonnenes Prognoseband ist überfällig, nicht unsichtbar")
    func prognoseBandbeginnInDerVergangenheit() throws {
        let expected = DayMath.utc.adding(days: 4, to: today)
        let items = builder.build(
            medications: [],
            cycles: [cycle(prediction: prediction(
                expected: expected,
                halfWidthDays: StudyConstants.intervalBandFloorDays
            ))],
            asOf: today
        )
        let item = try #require(items.first)
        #expect(item.dueOn == DayMath.utc.adding(days: -3, to: today))
        #expect(item.daysUntilDue == -3)
        #expect(item.urgency == .overdue)
        #expect(item.isForecast == true)
    }

    @Test("Horizont 0 lässt nur schon begonnene Bänder durch, negativer Horizont zählt als 0")
    func horizontNullUndNegativ() {
        let begonnen = cycle("c1", prediction: prediction(
            expected: today,
            halfWidthDays: StudyConstants.intervalBandFloorDays
        ))
        let kuenftig = cycle("c2", prediction: prediction(
            expected: DayMath.utc.adding(days: 30, to: today),
            halfWidthDays: StudyConstants.intervalBandFloorDays
        ))
        for horizon in [0, -10] {
            let items = builder.build(
                medications: [],
                cycles: [begonnen, kuenftig],
                asOf: today,
                forecastHorizonDays: horizon
            )
            #expect(items.count == 1)
            #expect(items.first?.sourceID == "c1")
        }
    }

    @Test("Der Horizont gilt nur für Prognosen, nicht für Medikamente")
    func horizontGiltNichtFuerMedikamente() throws {
        let items = builder.build(
            medications: [
                medication(kind: .tickProtection, lastGivenOn: today, effectiveDays: 200)
            ],
            cycles: [],
            asOf: today,
            forecastHorizonDays: 30
        )
        #expect(items.count == 1)
        #expect(try #require(items.first).urgency == .scheduled)
    }

    // MARK: Sortierung

    @Test("Sortierung: Dringlichkeit absteigend, dann Datum, dann Titel")
    func sortierung() {
        let items = builder.build(
            medications: [
                // `.scheduled`, in 100 Tagen
                medication("far", kind: .tickProtection, lastGivenOn: today, effectiveDays: 100),
                // `.overdue`
                medication("over", kind: .dewormer, lastGivenOn: day(2026, 1, 1), intervalDays: 30),
                // `.dueToday` (zwei Gaben heute)
                medication("dose", kind: .ongoing, productName: "Apoquel", schedule: DoseSchedule(
                    timesOfDay: [TimeOfDay(hour: 8), TimeOfDay(hour: 20)],
                    startDate: day(2026, 7, 1)
                )),
                // `.dueSoon`, in 2 Tagen
                medication("soon", kind: .dewormer, lastGivenOn: day(2026, 7, 26), intervalDays: 2),
                // `.upcoming`, in 10 Tagen
                medication("up", kind: .dewormer, lastGivenOn: day(2026, 7, 26), intervalDays: 10),
            ],
            cycles: [],
            asOf: today
        )
        #expect(items.map(\.sourceID) == ["over", "dose", "dose", "soon", "up", "far"])
        #expect(items.map(\.urgency) == [
            .overdue, .dueToday, .dueToday, .dueSoon, .upcoming, .scheduled,
        ])
    }

    @Test("Bei gleicher Stufe entscheidet das frühere Datum, dann der Titel")
    func sortierungInnerhalbEinerStufe() {
        let items = builder.build(
            medications: [
                // beide `.upcoming`: 10 bzw. 5 Tage
                medication("spaet", lastGivenOn: today, intervalDays: 10),
                medication("frueh", lastGivenOn: today, intervalDays: 5),
                // gleiches Datum wie „frueh", also entscheidet der Titel
                medication(
                    "gleich",
                    kind: .tickProtection,
                    lastGivenOn: today,
                    effectiveDays: 5
                ),
            ],
            cycles: [],
            asOf: today
        )
        // 5 Tage: Titel „Wurmkur" vs. „Zeckenschutz" ⇒ W vor Z; dann 10 Tage.
        #expect(items.map(\.sourceID) == ["frueh", "gleich", "spaet"])
    }

    @Test("Sortierung ist stabil, wenn die Eingabereihenfolge wechselt")
    func sortierungIstStabil() {
        // Zwei Tiere, gleiche Art, gleicher Produktname, gleiches Datum: alle
        // dokumentierten Sortierkriterien sind identisch. Ohne totale Ordnung
        // würde die Reihenfolge von der Eingabe abhängen und die SwiftUI-Liste
        // bei jedem Neuladen springen.
        let a = medication("a", pet: "p1", petName: "Nala", productName: "Milbemax",
                           lastGivenOn: today, intervalDays: 30)
        let b = medication("b", pet: "p2", petName: "Hegel", productName: "Milbemax",
                           lastGivenOn: today, intervalDays: 30)

        let vorwaerts = builder.build(medications: [a, b], cycles: [], asOf: today)
        let rueckwaerts = builder.build(medications: [b, a], cycles: [], asOf: today)
        #expect(vorwaerts == rueckwaerts)
        #expect(vorwaerts.count == 2)

        // Und zweimal derselbe Aufruf ergibt ebenfalls dasselbe.
        #expect(vorwaerts == builder.build(medications: [a, b], cycles: [], asOf: today))
    }

    @Test("Auch mit Prognosen und Dosen ist die Reihenfolge unabhängig von der Eingabe")
    func sortierungIstStabilImGemischtenFall() {
        let meds = [
            medication("m1", kind: .dewormer, lastGivenOn: day(2026, 1, 1), intervalDays: 30),
            medication("m2", kind: .tickProtection, lastGivenOn: today, effectiveDays: 30),
            medication("m3", kind: .ongoing, productName: "Apoquel", schedule: DoseSchedule(
                timesOfDay: [TimeOfDay(hour: 8), TimeOfDay(hour: 20)],
                startDate: day(2026, 7, 1)
            )),
            medication("m4", kind: .rabiesVaccination),
        ]
        let cycles = [
            cycle("c1", pet: "p1", petName: "Nala", prediction: prediction(
                expected: DayMath.utc.adding(days: 12, to: today),
                halfWidthDays: StudyConstants.intervalBandFloorDays
            )),
            cycle("c2", pet: "p2", petName: "Luna", prediction: prediction(
                expected: DayMath.utc.adding(days: 12, to: today),
                halfWidthDays: StudyConstants.intervalBandFloorDays
            )),
        ]
        let vorwaerts = builder.build(medications: meds, cycles: cycles, asOf: today)
        let rueckwaerts = builder.build(
            medications: meds.reversed(),
            cycles: cycles.reversed(),
            asOf: today
        )
        #expect(vorwaerts == rueckwaerts)
        #expect(vorwaerts.count == 7)
    }

    // MARK: Invarianten und Duplikate

    @Test("Derselbe Plan zweimal übergeben erzeugt ein Item")
    func duplikateWerdenZusammengefasst() {
        let plan = medication(kind: .dewormer, lastGivenOn: day(2026, 5, 1), intervalDays: 90)
        let vorhersage = cycle(prediction: prediction(
            expected: DayMath.utc.adding(days: 5, to: today),
            halfWidthDays: StudyConstants.intervalBandFloorDays
        ))
        let items = builder.build(
            medications: [plan, plan],
            cycles: [vorhersage, vorhersage],
            asOf: today
        )
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test("IDs sind über die ganze Liste eindeutig")
    func idsSindEindeutig() {
        let items = gemischteListe()
        #expect(items.count == 7)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test("Dringlichkeit passt zu daysUntilDue — außer bei „noch nie gegeben\"")
    func dringlichkeitPasstZuTagen() {
        // „Noch nie gegeben" bricht diese Kopplung absichtlich: dueOn == asOf,
        // daysUntilDue == 0, aber `.overdue` statt `.dueToday`.
        for item in gemischteListe() where item.detail?.hasSuffix("nie gegeben") != true {
            #expect(Urgency(daysUntilDue: item.daysUntilDue) == item.urgency)
        }
    }

    @Test("Nur Schutz-Arten tragen eine Restwirksamkeit")
    func nurSchutzHatRestwirksamkeit() {
        for item in gemischteListe() {
            switch item.category {
            case .protectionExpiry:
                #expect(item.remainingFraction != nil)
            case .medication, .dose, .cycleForecast, .criticalDays:
                #expect(item.remainingFraction == nil)
            }
        }
    }

    @Test("Nur Zyklus-Prognosen sind Prognosen")
    func nurZyklusIstPrognose() {
        for item in gemischteListe() {
            #expect(item.isForecast == (item.category == .cycleForecast))
        }
    }

    @Test("Restwirksamkeit liegt immer in 0…1")
    func restwirksamkeitImmerGeklemmt() {
        for item in gemischteListe() {
            if let fraction = item.remainingFraction {
                #expect(fraction >= 0 && fraction <= 1)
            }
        }
    }

    @Test("Mehrere Tiere landen in einer Liste, Tierbezug bleibt erhalten")
    func mehrereTiere() {
        let items = builder.build(
            medications: [
                medication("m1", pet: "p1", petName: "Nala", lastGivenOn: today, intervalDays: 5),
                medication("m2", pet: "p2", petName: "Hegel", lastGivenOn: today, intervalDays: 3),
            ],
            cycles: [],
            asOf: today
        )
        #expect(items.map(\.petID) == ["p2", "p1"])
        #expect(items.map(\.petName) == ["Hegel", "Nala"])
    }

    /// Ein Querschnitt über alle Kategorien für die Invarianten-Tests.
    private func gemischteListe() -> [DueItem] {
        builder.build(
            medications: [
                medication("m1", kind: .dewormer, productName: "Milbemax",
                           lastGivenOn: day(2026, 1, 1), intervalDays: 90),
                medication("m2", kind: .tickProtection, productName: "Bravecto",
                           lastGivenOn: day(2026, 7, 11), effectiveDays: 30),
                medication("m3", kind: .rabiesVaccination, productName: "Rabisin"),
                medication("m4", kind: .ongoing, productName: "Apoquel", schedule: DoseSchedule(
                    timesOfDay: [TimeOfDay(hour: 8), TimeOfDay(hour: 20)],
                    startDate: day(2026, 7, 1),
                    doseLabel: "1/2 Tablette"
                )),
                medication("m5", kind: .dewormer, lastGivenOn: today, intervalDays: 90),
            ],
            cycles: [
                cycle("c1", pet: "p1", petName: "Nala", prediction: prediction(
                    expected: DayMath.utc.adding(days: 20, to: today),
                    halfWidthDays: StudyConstants.intervalBandFloorDays
                ))
            ],
            asOf: today
        )
    }
}
