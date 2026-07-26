import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Die Umsetzung `CycleObservation`/`CyclePeriod` → `PhaseSignals`.
///
/// Kritisch sind zwei Dinge: **Optionalität** (ein nicht beobachtetes Feld darf
/// nicht als „nein" bei der Engine ankommen, sonst zieht es die Phasenschätzung
/// in die falsche Richtung) und **Reihenfolge** (die Engine erwartet die Signale
/// chronologisch, die SwiftData-Beziehung liefert sie unsortiert).
@MainActor
@Suite("Zyklus → PhaseSignals")
struct CycleAdapterTests {

    // MARK: CycleObservation

    @Test("Alle Beobachtungsfelder wandern in PhaseSignals")
    func allObservationFieldsMapThrough() throws {
        let context = try makeContext()
        let date = Fixture.day(2026, 4, 12)
        let observation = CycleObservation(
            date: date,
            dischargePresent: true,
            dischargeColor: .strawColored,
            dischargeAmount: .moderate,
            vulvaTurgor: .swollenSoft,
            flagging: true,
            standingHeat: true,
            attractsMales: false,
            progesteroneNgPerMl: 6.4,
            cornificationPercent: 88,
            note: "Duldet den Rüden",
            loggedAt: Fixture.logged
        )
        context.insert(observation)
        try context.save()

        let signals = observation.phaseSignals
        #expect(signals.date == date)
        #expect(signals.dischargePresent == true)
        #expect(signals.dischargeColor == .strawColored)
        #expect(signals.dischargeAmount == .moderate)
        #expect(signals.vulvaTurgor == .swollenSoft)
        #expect(signals.flagging == true)
        #expect(signals.standingHeat == true)
        // Beobachtetes „nein" ist ein echter Wert und muss false bleiben —
        // nicht nil werden.
        #expect(signals.attractsMales == false)
        #expect(signals.progesteroneNgPerMl == 6.4)
        #expect(signals.cornificationPercent == 88)
    }

    @Test("Nicht beobachtete Felder bleiben nil und werden nicht still zu false")
    func unobservedFieldsStayNil() throws {
        let context = try makeContext()
        let observation = CycleObservation(
            date: Fixture.day(2026, 4, 12),
            loggedAt: Fixture.logged
        )
        context.insert(observation)
        try context.save()

        let signals = observation.phaseSignals
        #expect(signals.dischargePresent == nil)
        #expect(signals.dischargeColor == nil)
        #expect(signals.dischargeAmount == nil)
        #expect(signals.vulvaTurgor == nil)
        #expect(signals.flagging == nil)
        #expect(signals.standingHeat == nil)
        #expect(signals.attractsMales == nil)
        #expect(signals.progesteroneNgPerMl == nil)
        #expect(signals.cornificationPercent == nil)
        // Ohne verknüpfte Läufigkeit gibt es auch kein Scheinträchtigkeits-Signal.
        #expect(signals.pseudopregnancySigns == nil)
    }

    @Test("Einzelne gesetzte Felder lassen die übrigen unberührt")
    func partiallyFilledObservationKeepsRestNil() throws {
        let context = try makeContext()
        // Der Regelfall aus der Praxis: zwei Taps, ein Feld. Alles andere muss
        // „nicht beobachtet" bleiben.
        let observation = CycleObservation(
            date: Fixture.day(2026, 4, 3),
            dischargePresent: true,
            loggedAt: Fixture.logged
        )
        context.insert(observation)
        try context.save()

        let signals = observation.phaseSignals
        #expect(signals.dischargePresent == true)
        #expect(signals.dischargeColor == nil)
        #expect(signals.standingHeat == nil)
        #expect(signals.flagging == nil)
    }

    @Test("Beobachtetes false bleibt false, auch wenn alles andere leer ist")
    func explicitFalseSurvives() throws {
        let context = try makeContext()
        let observation = CycleObservation(
            date: Fixture.day(2026, 4, 20),
            dischargePresent: false,
            flagging: false,
            standingHeat: false,
            attractsMales: false,
            loggedAt: Fixture.logged
        )
        context.insert(observation)
        try context.save()

        let signals = observation.phaseSignals
        #expect(signals.dischargePresent == false)
        #expect(signals.flagging == false)
        #expect(signals.standingHeat == false)
        #expect(signals.attractsMales == false)
    }

    @Test("pseudopregnancySigns kommt aus der Läufigkeit, nicht aus der Beobachtung")
    func pseudopregnancyComesFromPeriod() throws {
        let context = try makeContext()
        let quiet = CyclePeriod(day1Date: Fixture.day(2026, 1, 5), createdAt: Fixture.logged)
        let flagged = CyclePeriod(
            day1Date: Fixture.day(2026, 8, 2),
            pseudopregnancyObserved: true,
            pseudopregnancyNote: "Milcheinschuss",
            createdAt: Fixture.logged
        )
        context.insert(quiet)
        context.insert(flagged)

        let withoutSigns = CycleObservation(date: Fixture.day(2026, 1, 6), loggedAt: Fixture.logged)
        context.insert(withoutSigns)
        withoutSigns.period = quiet

        let withSigns = CycleObservation(date: Fixture.day(2026, 8, 3), loggedAt: Fixture.logged)
        context.insert(withSigns)
        withSigns.period = flagged

        try context.save()

        #expect(withoutSigns.phaseSignals.pseudopregnancySigns == false)
        #expect(withSigns.phaseSignals.pseudopregnancySigns == true)
    }

    // MARK: CyclePeriod

    @Test("sortedObservations ist chronologisch, auch bei unsortiertem Einfügen")
    func sortedObservationsAreChronological() throws {
        let context = try makeContext()
        let period = CyclePeriod(day1Date: Fixture.day(2026, 4, 1), createdAt: Fixture.logged)
        context.insert(period)

        // Bewusst verdrehte Einfügereihenfolge: die Reihenfolge von
        // SwiftData-To-Many-Arrays ist nicht zugesichert, der Adapter muss
        // selbst sortieren.
        for day in [12, 5, 8, 1, 6] {
            let observation = CycleObservation(
                date: Fixture.day(2026, 4, day),
                loggedAt: Fixture.logged
            )
            context.insert(observation)
            observation.period = period
        }
        try context.save()

        let expected = [1, 5, 6, 8, 12].map { Fixture.day(2026, 4, $0) }
        #expect(period.observations.count == 5)
        #expect(period.sortedObservations.map(\.date) == expected)
        // phaseSignals muss dieselbe Reihenfolge haben — die Engine rechnet
        // Tagesabstände aus der Sequenz.
        #expect(period.phaseSignals.map(\.date) == expected)
    }

    @Test("Eine Läufigkeit ohne Beobachtungen liefert leere Signale")
    func emptyPeriodYieldsNoSignals() throws {
        let context = try makeContext()
        let period = CyclePeriod(day1Date: Fixture.day(2026, 4, 1), createdAt: Fixture.logged)
        context.insert(period)
        try context.save()

        #expect(period.sortedObservations.isEmpty)
        #expect(period.phaseSignals.isEmpty)
        #expect(period.firstStandingHeatDate == nil)
    }

    @Test("Alle Signale einer Läufigkeit tragen deren Scheinträchtigkeits-Flag")
    func periodSignalsCarryPseudopregnancyFlag() throws {
        let context = try makeContext()
        let period = CyclePeriod(
            day1Date: Fixture.day(2026, 4, 1),
            pseudopregnancyObserved: true,
            createdAt: Fixture.logged
        )
        context.insert(period)
        for day in [3, 9] {
            let observation = CycleObservation(
                date: Fixture.day(2026, 4, day),
                loggedAt: Fixture.logged
            )
            context.insert(observation)
            observation.period = period
        }
        try context.save()

        let allFlagged = period.phaseSignals.allSatisfy { $0.pseudopregnancySigns == true }
        #expect(period.phaseSignals.count == 2)
        #expect(allFlagged)
    }

    @Test("firstStandingHeatDate ist der erste Tag mit Duldung, nicht ein späterer")
    func firstStandingHeatDateIsTheEarliest() throws {
        let context = try makeContext()
        let period = CyclePeriod(day1Date: Fixture.day(2026, 4, 1), createdAt: Fixture.logged)
        context.insert(period)

        // Die spätere Duldung kommt zuerst in den Store; false und nil dürfen
        // nicht als Duldung zählen.
        let entries: [(day: Int, standingHeat: Bool?)] = [
            (13, true),
            (5, false),
            (9, true),
            (7, nil),
            (11, true),
        ]
        for entry in entries {
            let observation = CycleObservation(
                date: Fixture.day(2026, 4, entry.day),
                standingHeat: entry.standingHeat,
                loggedAt: Fixture.logged
            )
            context.insert(observation)
            observation.period = period
        }
        try context.save()

        #expect(period.firstStandingHeatDate == Fixture.day(2026, 4, 9))
    }

    @Test("Ohne dokumentierte Duldung bleibt firstStandingHeatDate nil")
    func noStandingHeatYieldsNil() throws {
        let context = try makeContext()
        let period = CyclePeriod(day1Date: Fixture.day(2026, 4, 1), createdAt: Fixture.logged)
        context.insert(period)

        // Ausdrücklich „duldet nicht" und „nicht beobachtet" — beides ist keine
        // Standhitze.
        for entry in [(day: 4, standingHeat: false), (day: 6, standingHeat: false)] {
            let observation = CycleObservation(
                date: Fixture.day(2026, 4, entry.day),
                standingHeat: entry.standingHeat,
                loggedAt: Fixture.logged
            )
            context.insert(observation)
            observation.period = period
        }
        let unobserved = CycleObservation(date: Fixture.day(2026, 4, 8), loggedAt: Fixture.logged)
        context.insert(unobserved)
        unobserved.period = period
        try context.save()

        #expect(period.sortedObservations.count == 3)
        #expect(period.firstStandingHeatDate == nil)
    }

    @Test("engineID ist die UUID der Läufigkeit als String")
    func periodEngineIDIsUUIDString() throws {
        let context = try makeContext()
        let period = CyclePeriod(day1Date: Fixture.day(2026, 4, 1), createdAt: Fixture.logged)
        context.insert(period)
        try context.save()

        #expect(period.engineID == period.id.uuidString)
    }
}
