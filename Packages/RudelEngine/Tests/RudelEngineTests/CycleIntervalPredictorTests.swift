import Foundation
import Testing

@testable import RudelEngine

// MARK: - Fixtures

/// Fester Kalendertag in UTC. Nie `Date()` in Tests: eine Prognose, die sich mit
/// dem Ausführungstag verschiebt, kann keine Invariante festschreiben.
private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year, month: month, day: dayOfMonth
    ).date!
}

private let math = DayMath.utc
private let predictor = CycleIntervalPredictor(dayMath: math)

/// `intervalCount + 1` Anker mit konstantem Abstand — der Fixture-Generator für
/// die Monotonie-Invariante.
private func regularAnchors(
    intervalCount: Int,
    everyDays step: Int,
    startingAt start: Date = day(2020, 1, 6)
) -> [Date] {
    (0...intervalCount).map { math.adding(days: $0 * step, to: start) }
}

/// Anker aus einer Liste von Intervallen aufbauen — so stehen in den Tests die
/// Intervalle, um die es geht, und nicht abgezählte Kalenderdaten.
private func anchors(fromIntervals intervals: [Int], startingAt start: Date = day(2020, 1, 6)) -> [Date] {
    var result = [start]
    var cursor = start
    for interval in intervals {
        cursor = math.adding(days: interval, to: cursor)
        result.append(cursor)
    }
    return result
}

private let populationBandHalfWidth = Double(
    StudyConstants.day1ToDay1IntervalMaxDays - StudyConstants.day1ToDay1IntervalMinDays
) / 2

// MARK: - intervals(from:)

@Suite("CycleIntervalPredictor.intervals")
struct CycleIntervalPredictorIntervalsTests {

    @Test("Leere Ankerliste ergibt keine Intervalle")
    func emptyAnchors() {
        #expect(predictor.intervals(from: []).isEmpty)
    }

    @Test("Ein einzelner Anker ergibt kein Intervall")
    func singleAnchor() {
        #expect(predictor.intervals(from: [day(2024, 5, 1)]).isEmpty)
    }

    @Test("n Anker ergeben n − 1 Intervalle")
    func countIsAnchorsMinusOne() {
        let three = anchors(fromIntervals: [190, 205])
        #expect(predictor.intervals(from: three) == [190, 205])
        #expect(predictor.intervals(from: three).count == three.count - 1)
    }

    @Test("Unsortierte Anker werden sortiert — nie negative Intervalle")
    func unsortedAnchorsAreSorted() {
        let unsorted = [day(2024, 8, 1), day(2023, 1, 10), day(2024, 1, 20)]
        let result = predictor.intervals(from: unsorted)

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0 > 0 })
        #expect(result == [375, 194])
    }

    @Test("Mehrfach geloggter gleicher Tag zählt einmal — kein Intervall 0")
    func duplicateDaysAreDropped() {
        let anchor = day(2024, 3, 4)
        let sameDayLater = anchor.addingTimeInterval(19 * 3600)
        let next = math.adding(days: 200, to: anchor)

        let result = predictor.intervals(from: [anchor, sameDayLater, next])

        #expect(result == [200])
        #expect(!result.contains(0))
    }

    @Test("Nur Duplikate desselben Tages ergeben kein Intervall")
    func onlyDuplicatesYieldNoInterval() {
        let anchor = day(2024, 3, 4)
        let sameDay = [anchor, anchor.addingTimeInterval(3600), anchor.addingTimeInterval(23 * 3600)]

        #expect(predictor.intervals(from: sameDay).isEmpty)
    }

    @Test("Uhrzeit der Anker verschiebt das Intervall nicht")
    func timeOfDayIsIrrelevant() {
        let a = day(2024, 3, 4).addingTimeInterval(23 * 3600)
        let b = math.adding(days: 200, to: day(2024, 3, 4)).addingTimeInterval(60)

        #expect(predictor.intervals(from: [a, b]) == [200])
    }
}

// MARK: - predictNextCycle: Punktschätzer

@Suite("CycleIntervalPredictor.prediction")
struct CycleIntervalPredictorPredictionTests {

    let asOf = day(2025, 6, 15)

    @Test("Ohne Anker gibt es keine Prognose")
    func noAnchorsYieldsNil() {
        let history = CycleHistory(day1Anchors: [], sizeClass: .medium)
        #expect(predictor.predictNextCycle(history: history, asOf: asOf) == nil)
    }

    @Test("Ein Anker: reiner Populationswert, Konfidenz niedrig")
    func singleAnchorUsesPopulation() throws {
        let anchor = day(2025, 1, 10)
        let history = CycleHistory(day1Anchors: [anchor], sizeClass: .medium)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        #expect(prediction.basis == .population)
        #expect(prediction.confidence == .low)
        #expect(prediction.observedIntervalDays.isEmpty)
        #expect(prediction.effectiveIntervalDays == Double(StudyConstants.day1ToDay1IntervalDays))
        #expect(math.days(from: anchor, to: prediction.expectedDate)
            == StudyConstants.day1ToDay1IntervalDays)
    }

    @Test("Ohne eigene Intervalle ist das Band die Populationsspanne")
    func zeroIntervalsUsePopulationSpan() throws {
        let anchor = day(2025, 1, 10)
        let history = CycleHistory(day1Anchors: [anchor], sizeClass: .medium)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        #expect(math.days(from: anchor, to: prediction.range.lowerBound)
            == StudyConstants.day1ToDay1IntervalMinDays)
        #expect(math.days(from: anchor, to: prediction.range.upperBound)
            == StudyConstants.day1ToDay1IntervalMaxDays)
        #expect(prediction.bandHalfWidthDays == populationBandHalfWidth)
    }

    /// Bewusste Entscheidung, hier festgeschrieben: der Größenklassen-Bias
    /// verschiebt bei n = 0 den **Punktschätzer**, nicht die Spanne. Die Spanne
    /// 135–300 d ist der publizierte Populationsbefund; der Bias ist eine
    /// Heuristik (Design-Doc §4.4) und rechtfertigt kein Verschieben der Spanne.
    /// Folge: das Band ist bei n = 0 asymmetrisch um `expectedDate` — die UI muss
    /// `range` nehmen und darf es nicht aus `bandHalfWidthDays` rekonstruieren.
    @Test("Bei n = 0 verschiebt der Bias nur den Punktschätzer, nicht die Spanne")
    func zeroIntervalsKeepPopulationSpanAcrossSizeClasses() throws {
        let anchor = day(2025, 1, 10)

        for sizeClass in DogSizeClass.allCases {
            let history = CycleHistory(day1Anchors: [anchor], sizeClass: sizeClass)
            let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

            #expect(
                math.days(from: anchor, to: prediction.range.lowerBound)
                    == StudyConstants.day1ToDay1IntervalMinDays,
                "\(sizeClass)"
            )
            #expect(
                math.days(from: anchor, to: prediction.range.upperBound)
                    == StudyConstants.day1ToDay1IntervalMaxDays,
                "\(sizeClass)"
            )
            #expect(
                math.days(from: anchor, to: prediction.expectedDate)
                    == StudyConstants.day1ToDay1IntervalDays
                        + StudyConstants.intervalBiasDays(for: sizeClass),
                "\(sizeClass)"
            )
            #expect(prediction.range.contains(prediction.expectedDate), "\(sizeClass)")
        }
    }

    @Test(
        "Größenklassen-Bias verschiebt den Startwert",
        arguments: [
            (DogSizeClass.small, 195),
            (DogSizeClass.medium, 210),
            (DogSizeClass.large, 225),
            (DogSizeClass.giant, 240),
        ]
    )
    func sizeClassBias(sizeClass: DogSizeClass, expectedDays: Int) throws {
        let anchor = day(2025, 1, 10)
        let history = CycleHistory(day1Anchors: [anchor], sizeClass: sizeClass)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        #expect(math.days(from: anchor, to: prediction.expectedDate) == expectedDays)
        #expect(prediction.effectiveIntervalDays == Double(expectedDays))
        #expect(expectedDays
            == StudyConstants.day1ToDay1IntervalDays
                + StudyConstants.intervalBiasDays(for: sizeClass))
    }

    @Test("Ein eigenes Intervall zählt ein Drittel (k = 2)")
    func oneIntervalCountsOneThird() throws {
        let history = CycleHistory(day1Anchors: anchors(fromIntervals: [240]), sizeClass: .medium)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        // w = 1/3 ⇒ 1/3·240 + 2/3·210 = 220
        #expect(abs(prediction.effectiveIntervalDays - 220) < 1e-9)
        #expect(prediction.basis == .blended(ownIntervalCount: 1))
        #expect(prediction.observedIntervalDays == [240])
    }

    @Test("Vier eigene Intervalle zählen zwei Drittel")
    func fourIntervalsCountTwoThirds() throws {
        let history = CycleHistory(
            day1Anchors: regularAnchors(intervalCount: 4, everyDays: 240),
            sizeClass: .medium
        )
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        // w = 4/6 ⇒ 2/3·240 + 1/3·210 = 230
        #expect(abs(prediction.effectiveIntervalDays - 230) < 1e-9)
        #expect(prediction.basis == .blended(ownIntervalCount: 4))
    }

    @Test("Eigene Intervalle gleich dem Studienwert lassen die Prognose unverändert")
    func studyValueIntervalsAreAFixedPoint() throws {
        for n in 1...5 {
            let history = CycleHistory(
                day1Anchors: regularAnchors(
                    intervalCount: n,
                    everyDays: StudyConstants.day1ToDay1IntervalDays
                ),
                sizeClass: .medium
            )
            let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

            #expect(
                abs(prediction.effectiveIntervalDays
                    - Double(StudyConstants.day1ToDay1IntervalDays)) < 1e-9,
                "n = \(n)"
            )
        }
    }

    @Test("Der Anker ist immer der letzte geloggte Tag 1, auch bei unsortierter Eingabe")
    func lastAnchorIsTheReference() throws {
        let last = day(2025, 2, 20)
        let unsorted = [last, day(2023, 6, 1), day(2024, 4, 15)]
        let history = CycleHistory(day1Anchors: unsorted, sizeClass: .medium)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        let offset = Int(prediction.effectiveIntervalDays.rounded())
        #expect(prediction.expectedDate == math.adding(days: offset, to: last))
    }

    @Test("Der Punktschätzer wird auf ganze Tage gerundet")
    func expectedDateRoundsToWholeDays() throws {
        let history = CycleHistory(day1Anchors: anchors(fromIntervals: [200, 201]), sizeClass: .medium)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        // w = 0.5 ⇒ 0.5·200,5 + 0.5·210 = 205,25 ⇒ 205 Tage
        #expect(abs(prediction.effectiveIntervalDays - 205.25) < 1e-9)
        let lastAnchor = try #require(history.day1Anchors.max())
        #expect(math.days(from: lastAnchor, to: prediction.expectedDate) == 205)
    }

    @Test("`asOf` beeinflusst die Prognose nicht")
    func asOfDoesNotChangeThePrediction() throws {
        let history = CycleHistory(
            day1Anchors: regularAnchors(intervalCount: 3, everyDays: 205),
            sizeClass: .large
        )
        let early = try #require(predictor.predictNextCycle(history: history, asOf: day(2020, 2, 1)))
        let late = try #require(predictor.predictNextCycle(history: history, asOf: day(2030, 12, 31)))

        #expect(early == late)
    }

    @Test("Eine überschrittene Prognose bleibt in der Vergangenheit")
    func overduePredictionStaysInThePast() throws {
        let history = CycleHistory(
            day1Anchors: regularAnchors(intervalCount: 2, everyDays: 200, startingAt: day(2019, 1, 1)),
            sizeClass: .medium
        )
        let today = day(2026, 7, 26)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: today))

        #expect(prediction.expectedDate < today)
        #expect(prediction.range.upperBound < today)
    }

    @Test("Nur Duplikate desselben Tages: Prognose wie mit einem Anker")
    func duplicateAnchorsBehaveLikeOne() throws {
        let anchor = day(2025, 1, 10)
        let history = CycleHistory(
            day1Anchors: [anchor, anchor.addingTimeInterval(7200), anchor.addingTimeInterval(50_000)],
            sizeClass: .medium
        )
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        #expect(prediction.basis == .population)
        #expect(prediction.observedIntervalDays.isEmpty)
        #expect(prediction.confidence == .low)
    }
}

// MARK: - Invarianten (Design-Doc §4.3)

@Suite("CycleIntervalPredictor.invariants")
struct CycleIntervalPredictorInvariantTests {

    let asOf = day(2025, 6, 15)

    /// Invariante 1
    @Test("Die Bandbreite unterschreitet die UX-Schranke bei keinem n")
    func bandNeverBelowFloor() throws {
        for n in 0...8 {
            let history = CycleHistory(
                day1Anchors: regularAnchors(intervalCount: n, everyDays: 200),
                sizeClass: .medium
            )
            let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

            #expect(
                prediction.bandHalfWidthDays >= StudyConstants.intervalBandFloorDays,
                "n = \(n): \(prediction.bandHalfWidthDays)"
            )
        }
    }

    /// Invariante 1, der Fall aus PRD §6.1: eine Einzelstichprobe hat SD 0.
    @Test("Bei genau einem Intervall springt die Populations-SD ein")
    func singleIntervalDoesNotCollapse() throws {
        let history = CycleHistory(day1Anchors: anchors(fromIntervals: [200]), sizeClass: .medium)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        #expect(
            abs(prediction.bandHalfWidthDays
                - StudyConstants.day1ToDay1IntervalPopulationSDDays) < 1e-9
        )
        // Nicht auf die Schranke kollabiert — genau der Fehler, den das Modell vermeidet.
        #expect(prediction.bandHalfWidthDays > StudyConstants.intervalBandFloorDays)
    }

    /// Invariante 2
    @Test("Das Band enthält den Punktschätzer immer")
    func rangeContainsExpectedDate() throws {
        for sizeClass in DogSizeClass.allCases {
            for n in 0...6 {
                for step in [140, 200, 295] {
                    let history = CycleHistory(
                        day1Anchors: regularAnchors(intervalCount: n, everyDays: step),
                        sizeClass: sizeClass
                    )
                    let prediction = try #require(
                        predictor.predictNextCycle(history: history, asOf: asOf)
                    )

                    #expect(
                        prediction.range.contains(prediction.expectedDate),
                        "\(sizeClass), n = \(n), step = \(step)"
                    )
                    #expect(prediction.range.lowerBound <= prediction.range.upperBound)
                }
            }
        }
    }

    @Test("Das Band enthält den Punktschätzer auch bei stark schwankenden Intervallen")
    func rangeContainsExpectedDateForErraticIntervals() throws {
        let cases: [[Int]] = [[90, 480], [135, 300, 135, 300], [40, 520, 150], [200, 201]]
        for intervals in cases {
            let history = CycleHistory(
                day1Anchors: anchors(fromIntervals: intervals),
                sizeClass: .giant
            )
            let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

            #expect(prediction.range.contains(prediction.expectedDate), "\(intervals)")
        }
    }

    /// Invariante 3
    @Test("Ab einem Intervall ist das Band nie breiter als die Populationsspanne")
    func bandNeverWiderThanPopulationSpan() throws {
        let maxWidth = StudyConstants.day1ToDay1IntervalMaxDays
            - StudyConstants.day1ToDay1IntervalMinDays
        let cases: [[Int]] = [
            [200],
            [90, 480],
            [40, 520],
            [135, 300, 135, 300],
            [200, 200, 200],
            [30, 600, 60, 500],
        ]

        for intervals in cases {
            let history = CycleHistory(
                day1Anchors: anchors(fromIntervals: intervals),
                sizeClass: .giant
            )
            let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

            #expect(
                prediction.bandHalfWidthDays <= populationBandHalfWidth,
                "\(intervals): \(prediction.bandHalfWidthDays)"
            )
            #expect(
                math.days(from: prediction.range.lowerBound, to: prediction.range.upperBound)
                    <= maxWidth,
                "\(intervals)"
            )
        }
    }

    @Test("Extreme Streuung wird an der Populationsspanne gekappt")
    func extremeSpreadIsCapped() throws {
        let history = CycleHistory(day1Anchors: anchors(fromIntervals: [40, 520]), sizeClass: .medium)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        #expect(prediction.bandHalfWidthDays == populationBandHalfWidth)
    }

    /// Invariante 4
    @Test("Konstante Intervalle: das Band verengt sich monoton mit n")
    func constantIntervalsNarrowMonotonically() throws {
        var previous = Double.infinity
        var widths: [Double] = []

        for n in 1...8 {
            let history = CycleHistory(
                day1Anchors: regularAnchors(intervalCount: n, everyDays: 200),
                sizeClass: .medium
            )
            let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

            #expect(
                prediction.bandHalfWidthDays <= previous + 1e-9,
                "n = \(n): \(prediction.bandHalfWidthDays) > \(previous)"
            )
            previous = prediction.bandHalfWidthDays
            widths.append(prediction.bandHalfWidthDays)
        }

        // Nicht nur monoton, sondern tatsächlich enger geworden.
        let firstWidth = try #require(widths.first)
        let lastWidth = try #require(widths.last)
        #expect(lastWidth < firstWidth)
    }

    /// Invariante 4, Gegenprobe: Monotonie gilt *nur* bei konstanten Intervallen.
    /// Ein unregelmäßiger Zyklus darf ehrlich unsicherer werden.
    @Test("Schwankende Intervalle dürfen das Band verbreitern")
    func erraticIntervalsMayWidenTheBand() throws {
        let oneInterval = CycleHistory(
            day1Anchors: anchors(fromIntervals: [200]),
            sizeClass: .medium
        )
        let twoErraticIntervals = CycleHistory(
            day1Anchors: anchors(fromIntervals: [200, 380]),
            sizeClass: .medium
        )

        let narrow = try #require(predictor.predictNextCycle(history: oneInterval, asOf: asOf))
        let wide = try #require(predictor.predictNextCycle(history: twoErraticIntervals, asOf: asOf))

        #expect(wide.bandHalfWidthDays > narrow.bandHalfWidthDays)
        // Und trotzdem nicht breiter als die Populationsspanne (Invariante 3).
        #expect(wide.bandHalfWidthDays <= populationBandHalfWidth)
    }

    /// Invariante 5
    @Test("Konfidenz hängt an der Zahl der Intervalle, nicht der Anker")
    func confidenceFollowsIntervalCount() throws {
        for n in 0...5 {
            let history = CycleHistory(
                day1Anchors: regularAnchors(intervalCount: n, everyDays: 200),
                sizeClass: .medium
            )
            let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

            #expect(prediction.confidence == Confidence(ownIntervalCount: n), "n = \(n)")
            #expect(prediction.observedIntervalDays.count == n)
        }
    }

    @Test("Zwei Anker sind ein Intervall — Konfidenz mittel, nicht hoch")
    func twoAnchorsAreOneInterval() throws {
        let history = CycleHistory(day1Anchors: anchors(fromIntervals: [200]), sizeClass: .medium)
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        #expect(history.day1Anchors.count == 2)
        #expect(prediction.observedIntervalDays.count == 1)
        #expect(prediction.confidence == .moderate)
    }

    @Test("Ab drei Intervallen ist die Konfidenz hoch")
    func threeIntervalsAreHighConfidence() throws {
        let history = CycleHistory(
            day1Anchors: regularAnchors(intervalCount: 3, everyDays: 200),
            sizeClass: .medium
        )
        let prediction = try #require(predictor.predictNextCycle(history: history, asOf: asOf))

        #expect(prediction.confidence == .high)
        #expect(prediction.basis == .blended(ownIntervalCount: 3))
    }
}
