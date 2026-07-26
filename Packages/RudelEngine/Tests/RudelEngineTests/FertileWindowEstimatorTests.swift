import Foundation
import Testing

@testable import RudelEngine

/// Feste Kalendertage in UTC. Nie `Date()` — sonst hängt die Zyklus-Arithmetik
/// am Ausführungszeitpunkt.
private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year, month: month, day: day
    ).date!
}

@Suite("FertileWindowEstimator — fruchtbares Fenster (PRD §6.3)")
struct FertileWindowEstimatorTests {

    private let dayMath = DayMath.utc
    private let estimator = FertileWindowEstimator(dayMath: .utc)

    /// Tag-1-Anker aller Fixtures.
    private let day1 = day(2026, 3, 1)

    /// Datum des `n`-ten Zyklustags — Tag 1 ist der Anker selbst.
    private func cycleDay(_ n: Int) -> Date {
        dayMath.adding(days: n - 1, to: day1)
    }

    private func signal(
        dayInCycle: Int,
        progesterone: Double? = nil,
        standingHeat: Bool? = nil
    ) -> PhaseSignals {
        PhaseSignals(
            date: cycleDay(dayInCycle),
            standingHeat: standingHeat,
            progesteroneNgPerMl: progesterone
        )
    }

    private func widthInDays(_ estimate: FertileWindowEstimate) -> Int {
        dayMath.days(from: estimate.window.lowerBound, to: estimate.window.upperBound)
    }

    // MARK: - Studienwerte als Fixtures (PRD §7)

    @Test("Die Studienwerte, auf denen alle Fixtures unten beruhen")
    func studyConstantsArePinned() {
        #expect(StudyConstants.progesteroneLHPeakThresholdNgPerMl == 2.5)
        #expect(StudyConstants.progesteroneOvulationThresholdNgPerMl == 6.0)
        #expect(StudyConstants.ovulationDaysAfterLHPeak == 2)
        #expect(StudyConstants.ovulationDaysAfterStandingHeatStart == 2)
        #expect(StudyConstants.optimalBreedingDaysAfterOvulation == 2)
        #expect(StudyConstants.proestrusTypicalDays == 9)
        #expect(StudyConstants.proestrusMaxDays == 17)
        #expect(StudyConstants.estrusMaxDays == 21)
    }

    // MARK: - Weg 1: Progesteron

    @Test("Erster Wert über der LH-Schwelle ankert Eisprung und Optimum")
    func progesteronePathAnchorsOnFirstThresholdCrossing() throws {
        let result = try #require(
            estimator.estimate(
                day1: day1,
                signals: [
                    signal(dayInCycle: 8, progesterone: 1.0),
                    signal(dayInCycle: 11, progesterone: 3.0),
                    signal(dayInCycle: 13, progesterone: 8.0),
                ],
                asOf: cycleDay(13)
            )
        )

        #expect(result.source == .clinicalSignals)
        #expect(result.confidence == .high)
        #expect(result.caveat == FertileWindowEstimator.progesteroneCaveat)

        // LH-Peak an Tag 11 ⇒ Eisprung Tag 13 ⇒ Optimum Tag 15.
        let expectedOptimal = cycleDay(
            11 + StudyConstants.ovulationDaysAfterLHPeak
                + StudyConstants.optimalBreedingDaysAfterOvulation
        )
        #expect(result.optimalDate == expectedOptimal)
        #expect(result.window == cycleDay(14)...cycleDay(16))
    }

    @Test("Ein späterer, höherer Wert verschiebt den Peak nicht nach hinten")
    func progesteroneLaterHigherValueDoesNotMovePeak() throws {
        let early = try #require(
            estimator.estimate(
                day1: day1,
                signals: [signal(dayInCycle: 10, progesterone: 2.5)],
                asOf: cycleDay(12)
            )
        )
        let withLaterPeak = try #require(
            estimator.estimate(
                day1: day1,
                signals: [
                    signal(dayInCycle: 10, progesterone: 2.5),
                    signal(dayInCycle: 12, progesterone: 25.0),
                ],
                asOf: cycleDay(12)
            )
        )

        #expect(early.optimalDate == cycleDay(14))
        #expect(withLaterPeak == early)
    }

    @Test("Genau auf der Schwelle zählt, knapp darunter nicht")
    func progesteroneThresholdIsInclusive() throws {
        let onThreshold = try #require(
            estimator.estimate(
                day1: day1,
                signals: [
                    signal(dayInCycle: 12, progesterone: StudyConstants.progesteroneLHPeakThresholdNgPerMl)
                ],
                asOf: cycleDay(12)
            )
        )
        #expect(onThreshold.source == .clinicalSignals)

        let belowThreshold = try #require(
            estimator.estimate(
                day1: day1,
                signals: [signal(dayInCycle: 12, progesterone: 2.4)],
                asOf: cycleDay(12)
            )
        )
        // Unterhalb der Schwelle bleibt nur der Populationswert.
        #expect(belowThreshold.source == .populationDefault)
    }

    @Test("Progesteron schlägt Standhitze")
    func progesteroneOutranksStandingHeat() throws {
        let result = try #require(
            estimator.estimate(
                day1: day1,
                signals: [
                    PhaseSignals(date: cycleDay(10), standingHeat: true),
                    signal(dayInCycle: 12, progesterone: 4.0),
                ],
                asOf: cycleDay(12)
            )
        )

        #expect(result.source == .clinicalSignals)
        #expect(result.confidence == .high)
        #expect(result.optimalDate == cycleDay(16))
    }

    @Test("Doppelte Messungen am selben Tag ändern nichts")
    func duplicateSameDayMeasurementsAreIdempotent() throws {
        let single = try #require(
            estimator.estimate(
                day1: day1,
                signals: [signal(dayInCycle: 11, progesterone: 3.0)],
                asOf: cycleDay(11)
            )
        )
        let duplicated = try #require(
            estimator.estimate(
                day1: day1,
                signals: [
                    signal(dayInCycle: 11, progesterone: 3.0),
                    signal(dayInCycle: 11, progesterone: 9.0),
                    signal(dayInCycle: 11, progesterone: 3.0),
                ],
                asOf: cycleDay(11)
            )
        )
        #expect(duplicated == single)
    }

    @Test("Die Reihenfolge der Signale ist irrelevant")
    func inputOrderDoesNotMatter() throws {
        let signals = [
            signal(dayInCycle: 8, progesterone: 0.4),
            signal(dayInCycle: 11, progesterone: 3.0),
            signal(dayInCycle: 14, progesterone: 18.0),
            PhaseSignals(date: cycleDay(12), standingHeat: true),
        ]

        let ascending = try #require(
            estimator.estimate(day1: day1, signals: signals, asOf: cycleDay(14))
        )
        let descending = try #require(
            estimator.estimate(day1: day1, signals: signals.reversed(), asOf: cycleDay(14))
        )
        #expect(descending == ascending)
    }

    // MARK: - Weg 2: Standhitze

    @Test("Erster Standhitze-Tag ankert die Eisprung-Näherung")
    func standingHeatPath() throws {
        let result = try #require(
            estimator.estimate(
                day1: day1,
                signals: [
                    PhaseSignals(date: cycleDay(9), flagging: true),
                    PhaseSignals(date: cycleDay(12), standingHeat: true),
                    PhaseSignals(date: cycleDay(13), standingHeat: true),
                ],
                asOf: cycleDay(13)
            )
        )

        #expect(result.source == .observedSignals)
        #expect(result.confidence == .moderate)
        #expect(result.caveat == FertileWindowEstimator.behaviourCaveat)

        // Standhitze ab Tag 12 ⇒ Eisprung Tag 14 ⇒ Optimum Tag 16.
        let expectedOptimal = cycleDay(
            12 + StudyConstants.ovulationDaysAfterStandingHeatStart
                + StudyConstants.optimalBreedingDaysAfterOvulation
        )
        #expect(result.optimalDate == expectedOptimal)
        #expect(result.window == cycleDay(13)...cycleDay(19))
    }

    @Test("Eine implausibel frühe Standhitze wird ungeprüft übernommen")
    func earlyStandingHeatIsTakenAtFaceValue() throws {
        // Festgeschrieben, weil es eine bekannte Grenze ist, kein Zufall: der
        // Doc-Kommentar kennt für die Standhitze keine Untergrenze, also ankert
        // auch ein Eintrag an Tag 2 — Fehl-Tipp oder aus dem Gedächtnis
        // nachgetragen — und das Fenster liegt dann im Proöstrus.
        let result = try #require(
            estimator.estimate(
                day1: day1,
                signals: [PhaseSignals(date: cycleDay(2), standingHeat: true)],
                asOf: cycleDay(5)
            )
        )

        #expect(result.source == .observedSignals)
        #expect(result.optimalDate == cycleDay(6))
        #expect(result.window == cycleDay(3)...cycleDay(9))
    }

    @Test("standingHeat == false ist keine Standhitze")
    func standingHeatFalseFallsThroughToPopulation() throws {
        let result = try #require(
            estimator.estimate(
                day1: day1,
                signals: [
                    PhaseSignals(date: cycleDay(6), standingHeat: false),
                    PhaseSignals(date: cycleDay(7), standingHeat: false),
                ],
                asOf: cycleDay(7)
            )
        )
        #expect(result.source == .populationDefault)
    }

    // MARK: - Weg 3: Populations-Default

    @Test("Leere Eingabe ergibt den Populationswert")
    func emptySignalsFallBackToPopulation() throws {
        let result = try #require(
            estimator.estimate(day1: day1, signals: [], asOf: cycleDay(5))
        )

        #expect(result.source == .populationDefault)
        #expect(result.confidence == .low)
        #expect(result.caveat == FertileWindowEstimator.populationCaveat)

        // Östrus ab Tag 10 ⇒ Eisprung Tag 12 ⇒ Optimum Tag 14.
        let expectedOptimal = cycleDay(
            StudyConstants.proestrusTypicalDays + 1
                + StudyConstants.ovulationDaysAfterStandingHeatStart
                + StudyConstants.optimalBreedingDaysAfterOvulation
        )
        #expect(result.optimalDate == expectedOptimal)
        #expect(result.window == cycleDay(9)...cycleDay(19))
    }

    @Test("Ein Eintrag ohne jede Angabe zieht die Schätzung nicht weg vom Default")
    func emptySignalEntryIsIgnored() throws {
        let onlyEmpty = PhaseSignals(date: cycleDay(8))
        #expect(onlyEmpty.isEmpty)

        let result = try #require(
            estimator.estimate(day1: day1, signals: [onlyEmpty], asOf: cycleDay(8))
        )
        #expect(result.source == .populationDefault)
    }

    @Test("Nullwerte lösen keinen klinischen Weg aus")
    func zeroValuesDoNotTriggerClinicalPath() throws {
        let result = try #require(
            estimator.estimate(
                day1: day1,
                signals: [signal(dayInCycle: 4, progesterone: 0.0, standingHeat: false)],
                asOf: cycleDay(4)
            )
        )
        #expect(result.source == .populationDefault)
    }

    // MARK: - Fensterbreite

    @Test("Die Fensterbreite wächst mit sinkender Konfidenz")
    func windowWidthGrowsAsConfidenceDrops() throws {
        let clinical = try #require(
            estimator.estimate(
                day1: day1,
                signals: [signal(dayInCycle: 11, progesterone: 3.0)],
                asOf: cycleDay(11)
            )
        )
        let observed = try #require(
            estimator.estimate(
                day1: day1,
                signals: [PhaseSignals(date: cycleDay(11), standingHeat: true)],
                asOf: cycleDay(11)
            )
        )
        let population = try #require(
            estimator.estimate(day1: day1, signals: [], asOf: cycleDay(11))
        )

        #expect(clinical.confidence == .high)
        #expect(observed.confidence == .moderate)
        #expect(population.confidence == .low)

        // ±1 / ±3 / ±5 Tage — streng monoton wachsend.
        #expect(widthInDays(clinical) == 2)
        #expect(widthInDays(observed) == 6)
        #expect(widthInDays(population) == 10)
        #expect(widthInDays(clinical) < widthInDays(observed))
        #expect(widthInDays(observed) < widthInDays(population))
    }

    @Test("Das Fenster enthält das Optimum und ist tagesgenau normalisiert")
    func windowAlwaysContainsOptimalDate() throws {
        let cases: [[PhaseSignals]] = [
            [],
            [PhaseSignals(date: cycleDay(11), standingHeat: true)],
            [signal(dayInCycle: 11, progesterone: 3.0)],
        ]

        for signals in cases {
            let result = try #require(
                estimator.estimate(day1: day1, signals: signals, asOf: cycleDay(11))
            )
            #expect(result.window.contains(result.optimalDate))
            #expect(result.window.lowerBound <= result.window.upperBound)
            #expect(result.window.lowerBound == dayMath.startOfDay(result.window.lowerBound))
            #expect(result.window.upperBound == dayMath.startOfDay(result.window.upperBound))
            #expect(result.optimalDate == dayMath.startOfDay(result.optimalDate))
        }
    }

    // MARK: - Caveat

    @Test("Jede Rückgabe trägt ein nicht-leeres Caveat")
    func caveatIsNeverEmpty() throws {
        let lastPlausibleDay = StudyConstants.proestrusMaxDays + StudyConstants.estrusMaxDays

        for dayNumber in 1...lastPlausibleDay {
            let variants: [[PhaseSignals]] = [
                [],
                [PhaseSignals(date: cycleDay(dayNumber), standingHeat: true)],
                [signal(dayInCycle: dayNumber, progesterone: 7.0)],
                [signal(dayInCycle: dayNumber, progesterone: 0.2)],
            ]
            for signals in variants {
                let result = try #require(
                    estimator.estimate(day1: day1, signals: signals, asOf: cycleDay(dayNumber))
                )
                #expect(!result.caveat.isEmpty)
            }
        }
    }

    // MARK: - Zyklusfenster-Grenze

    @Test("Am letzten plausiblen Tag noch eine Schätzung, einen Tag später nicht mehr")
    func returnsNilBeyondPlausibleCycleWindow() {
        let lastPlausibleDay = StudyConstants.proestrusMaxDays + StudyConstants.estrusMaxDays
        #expect(lastPlausibleDay == 38)

        #expect(estimator.estimate(day1: day1, signals: [], asOf: cycleDay(lastPlausibleDay)) != nil)
        #expect(estimator.estimate(day1: day1, signals: [], asOf: cycleDay(lastPlausibleDay + 1)) == nil)
        #expect(estimator.estimate(day1: day1, signals: [], asOf: cycleDay(200)) == nil)
    }

    @Test("Auch belastbare Progesteronwerte retten den abgelaufenen Zyklus nicht")
    func nilBeyondWindowEvenWithClinicalSignals() {
        let signals = [signal(dayInCycle: 11, progesterone: 6.0)]
        #expect(estimator.estimate(day1: day1, signals: signals, asOf: cycleDay(39)) == nil)
    }

    // MARK: - Bezugsdatum vor dem Anker

    @Test("Ein asOf vor Tag 1 wird auf Tag 1 gezogen, nicht zu nil")
    func asOfBeforeAnchorIsClampedToDayOne() throws {
        let atAnchor = try #require(estimator.estimate(day1: day1, signals: [], asOf: day1))
        let beforeAnchor = try #require(
            estimator.estimate(day1: day1, signals: [], asOf: dayMath.adding(days: -30, to: day1))
        )

        #expect(beforeAnchor == atAnchor)
        #expect(beforeAnchor.optimalDate == cycleDay(14))
    }

    @Test("Uhrzeiten innerhalb des Tages spielen keine Rolle")
    func timeOfDayIsIrrelevant() throws {
        let midday = dayMath.adding(days: 0, to: cycleDay(11)).addingTimeInterval(13 * 3600)

        let fromMidnight = try #require(
            estimator.estimate(
                day1: day1,
                signals: [signal(dayInCycle: 11, progesterone: 3.0)],
                asOf: cycleDay(11)
            )
        )
        let fromMidday = try #require(
            estimator.estimate(
                day1: day1.addingTimeInterval(9 * 3600),
                signals: [PhaseSignals(date: midday, progesteroneNgPerMl: 3.0)],
                asOf: midday
            )
        )
        #expect(fromMidday == fromMidnight)
    }

    // MARK: - Signale außerhalb des Zyklus

    @Test("Werte vor Tag 1 gehören zum vorherigen Zyklus und ankern nicht")
    func signalsBeforeAnchorAreIgnored() throws {
        let result = try #require(
            estimator.estimate(
                day1: day1,
                signals: [
                    PhaseSignals(
                        date: dayMath.adding(days: -3, to: day1),
                        standingHeat: true,
                        progesteroneNgPerMl: 12.0
                    )
                ],
                asOf: cycleDay(6)
            )
        )
        #expect(result.source == .populationDefault)
    }

    @Test("Diöstrus-Progesteron jenseits des Zyklusfensters ankert nicht")
    func signalsBeyondHorizonAreIgnored() throws {
        let result = try #require(
            estimator.estimate(
                day1: day1,
                signals: [signal(dayInCycle: 60, progesterone: 20.0)],
                asOf: cycleDay(20)
            )
        )
        #expect(result.source == .populationDefault)
    }

    // MARK: - Injizierter Kalender

    @Test("Ein anderer Kalender verschiebt die Tagesrechnung nicht")
    func alternateCalendarKeepsDayArithmetic() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let berlinMath = DayMath(calendar: berlin)
        let berlinEstimator = FertileWindowEstimator(dayMath: berlinMath)

        // Anker mittags, damit die Zeitzonenverschiebung den Kalendertag nicht kippt.
        let anchor = day(2026, 3, 1).addingTimeInterval(12 * 3600)
        let result = try #require(
            berlinEstimator.estimate(day1: anchor, signals: [], asOf: anchor)
        )

        #expect(result.confidence == .low)
        #expect(berlinMath.days(from: anchor, to: result.optimalDate) == 13)
        #expect(berlinMath.days(from: result.window.lowerBound, to: result.window.upperBound) == 10)
    }
}
