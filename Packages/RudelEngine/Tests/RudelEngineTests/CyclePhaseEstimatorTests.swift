import Foundation
import Testing

import RudelEngine

/// Fester Kalendertag in UTC — nie `Date()`, damit die Fixtures deterministisch
/// bleiben und nicht von der Zeitzone der Testmaschine abhängen.
private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year, month: month, day: day
    ).date!
}

@Suite("CyclePhaseEstimator")
struct CyclePhaseEstimatorTests {
    let estimator = CyclePhaseEstimator(dayMath: .utc)
    /// Tag-1-Anker aller Fixtures. Bewusst mitten im Monat, damit Monatsgrenzen
    /// innerhalb eines Zyklus überschritten werden.
    let day1 = day(2026, 3, 1)

    /// `n`-ter Tag im Zyklus, 1-basiert: `cycleDay(1) == day1`.
    func cycleDay(_ n: Int) -> Date {
        DayMath.utc.adding(days: n - 1, to: day1)
    }

    // MARK: - dayInCycle

    @Test("Tag 1 ist der Anker selbst, nicht Tag 0")
    func dayInCycleIsOneBased() {
        #expect(estimator.dayInCycle(day1: day1, asOf: day1) == 1)
        #expect(estimator.dayInCycle(day1: day1, asOf: cycleDay(2)) == 2)
        #expect(estimator.dayInCycle(day1: day1, asOf: cycleDay(210)) == 210)
    }

    @Test("Bezugsdatum vor Tag 1 ergibt Tag 1, nie 0 oder negativ")
    func dayInCycleClampsToOne() {
        #expect(estimator.dayInCycle(day1: day1, asOf: day(2026, 2, 28)) == 1)
        #expect(estimator.dayInCycle(day1: day1, asOf: day(2025, 1, 1)) == 1)
    }

    @Test("Tagesrechnung überschreitet Monatsgrenzen korrekt")
    func dayInCycleCrossesMonthBoundary() {
        let anchor = day(2026, 1, 30)
        #expect(estimator.dayInCycle(day1: anchor, asOf: day(2026, 2, 2)) == 4)
        // 2028 ist ein Schaltjahr: 29.02. muss mitgezählt werden.
        #expect(estimator.dayInCycle(day1: day(2028, 2, 27), asOf: day(2028, 3, 1)) == 4)
    }

    @Test("Uhrzeit innerhalb des Tages verschiebt den Zyklustag nicht")
    func dayInCycleIgnoresTimeOfDay() {
        let lateOnDay1 = day1.addingTimeInterval(23 * 3600 + 59 * 60)
        #expect(estimator.dayInCycle(day1: day1, asOf: lateOnDay1) == 1)
        #expect(estimator.dayInCycle(day1: lateOnDay1, asOf: cycleDay(2)) == 2)
    }

    // MARK: - phaseFromDayInCycle

    @Test("Kumulierte Phasengrenzen: 1...9 / 10...18 / 19...93 / ab 94")
    func phaseBoundaries() {
        #expect(estimator.phaseFromDayInCycle(1) == .proestrus)
        #expect(estimator.phaseFromDayInCycle(9) == .proestrus)
        #expect(estimator.phaseFromDayInCycle(10) == .estrus)
        #expect(estimator.phaseFromDayInCycle(18) == .estrus)
        #expect(estimator.phaseFromDayInCycle(19) == .diestrus)
        #expect(estimator.phaseFromDayInCycle(93) == .diestrus)
        #expect(estimator.phaseFromDayInCycle(94) == .anestrus)
        #expect(estimator.phaseFromDayInCycle(400) == .anestrus)
    }

    @Test("Grenzen stammen aus StudyConstants, nicht aus Literalen")
    func phaseBoundariesDeriveFromStudyConstants() {
        let proestrusEnd = StudyConstants.proestrusTypicalDays
        let estrusEnd = proestrusEnd + StudyConstants.estrusTypicalDays
        let diestrusEnd = estrusEnd + StudyConstants.diestrusTypicalDays

        #expect(estimator.phaseFromDayInCycle(proestrusEnd) == .proestrus)
        #expect(estimator.phaseFromDayInCycle(proestrusEnd + 1) == .estrus)
        #expect(estimator.phaseFromDayInCycle(estrusEnd) == .estrus)
        #expect(estimator.phaseFromDayInCycle(estrusEnd + 1) == .diestrus)
        #expect(estimator.phaseFromDayInCycle(diestrusEnd) == .diestrus)
        #expect(estimator.phaseFromDayInCycle(diestrusEnd + 1) == .anestrus)
    }

    @Test("Tag <= 0 wird defensiv als Proöstrus behandelt")
    func phaseFromNonPositiveDay() {
        #expect(estimator.phaseFromDayInCycle(0) == .proestrus)
        #expect(estimator.phaseFromDayInCycle(-1) == .proestrus)
        #expect(estimator.phaseFromDayInCycle(Int.min + 1) == .proestrus)
    }

    // MARK: - Stufe 3: Populations-Default

    @Test("Ohne Signale zählt nur der Kalender, mit niedriger Konfidenz")
    func emptySignalsFallBackToPopulation() {
        for (dayNumber, expected) in [(5, CyclePhase.proestrus), (14, .estrus), (40, .diestrus), (150, .anestrus)] {
            let result = estimator.estimatePhase(day1: day1, signals: [], asOf: cycleDay(dayNumber))
            #expect(result.phase == expected)
            #expect(result.dayInCycle == dayNumber)
            #expect(result.source == .populationDefault)
            #expect(result.confidence == .low)
        }
    }

    @Test("Leere Einträge gelten als nicht dokumentiert und werden ignoriert")
    func emptySignalEntriesAreIgnored() {
        let blanks = [PhaseSignals(date: cycleDay(3)), PhaseSignals(date: cycleDay(4))]
        let result = estimator.estimatePhase(day1: day1, signals: blanks, asOf: cycleDay(5))

        // Entscheidend ist die Quelle: ein leerer Eintrag darf nicht als
        // „keine Anzeichen" durchgehen und die Phase Richtung Anöstrus ziehen.
        #expect(result.source == .populationDefault)
        #expect(result.phase == .proestrus)
    }

    @Test("Ein leerer Eintrag von heute übertönt keine echte Beobachtung von gestern")
    func blankEntryDoesNotOutrankOlderObservation() {
        let signals = [
            PhaseSignals(date: cycleDay(11), standingHeat: true),
            PhaseSignals(date: cycleDay(12)),
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(12))

        #expect(result.phase == .estrus)
        #expect(result.source == .observedSignals)
    }

    @Test("Eintrag ohne Phasenaussage fällt auf den Kalender zurück")
    func ambiguousEntryFallsBackToPopulation() {
        // Menge dokumentiert, aber weder Farbe noch Turgor: keine Regel greift.
        let signals = [PhaseSignals(date: cycleDay(6), dischargeAmount: .moderate, attractsMales: true)]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(6))

        #expect(result.source == .populationDefault)
        #expect(result.confidence == .low)
    }

    // MARK: - Stufe 2: eigene Beobachtungen

    @Test("Duldung ⇒ Östrus mit hoher Konfidenz, auch gegen den Kalender")
    func standingHeatWinsOverCalendar() {
        let signals = [PhaseSignals(date: cycleDay(3), standingHeat: true)]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(3))

        #expect(result.phase == .estrus)          // Kalender hätte Proöstrus gesagt
        #expect(result.source == .observedSignals)
        #expect(result.confidence == .high)
    }

    @Test("Blutiger Ausfluss + pralle Vulva ⇒ Proöstrus, auch am Kalender-Östrustag")
    func bloodyAndFirmMeansProestrus() {
        let signals = [
            PhaseSignals(
                date: cycleDay(12), dischargePresent: true,
                dischargeColor: .bloody, vulvaTurgor: .swollenFirm
            )
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(12))

        #expect(result.phase == .proestrus)
        #expect(result.source == .observedSignals)
        #expect(result.confidence == .moderate)
    }

    @Test("Strohfarben/rosa + weiche Vulva ⇒ Östrus")
    func strawColoredAndSofteningMeansEstrus() {
        let straw = PhaseSignals(
            date: cycleDay(5), dischargePresent: true,
            dischargeColor: .strawColored, vulvaTurgor: .swollenSoft
        )
        let pink = PhaseSignals(
            date: cycleDay(5), dischargePresent: true,
            dischargeColor: .pinkish, vulvaTurgor: .softening
        )

        for signal in [straw, pink] {
            let result = estimator.estimatePhase(day1: day1, signals: [signal], asOf: cycleDay(5))
            #expect(result.phase == .estrus)
            #expect(result.source == .observedSignals)
            #expect(result.confidence == .moderate)
        }
    }

    @Test("Kein Ausfluss + normale Vulva ⇒ Diöstrus nur nach belegtem Östrus")
    func quietFindingsMeanDiestrusOnlyAfterEstrus() {
        let quiet = PhaseSignals(date: cycleDay(5), dischargePresent: false, vulvaTurgor: .normal)

        // Ohne vorherigen Östrus ist derselbe Befund keine Aussage.
        let withoutEstrus = estimator.estimatePhase(day1: day1, signals: [quiet], asOf: cycleDay(5))
        #expect(withoutEstrus.source == .populationDefault)
        #expect(withoutEstrus.phase == .proestrus)

        // Mit belegtem Östrus davor ⇒ Diöstrus.
        let quietLater = PhaseSignals(date: cycleDay(22), dischargePresent: false, vulvaTurgor: .normal)
        let withEstrus = estimator.estimatePhase(
            day1: day1,
            signals: [PhaseSignals(date: cycleDay(11), standingHeat: true), quietLater],
            asOf: cycleDay(22)
        )
        #expect(withEstrus.phase == .diestrus)
        #expect(withEstrus.source == .observedSignals)
        #expect(withEstrus.confidence == .moderate)
    }

    @Test("Schwanzflaggen allein ⇒ Östrus mit mittlerer Konfidenz")
    func flaggingAloneMeansEstrus() {
        let signals = [PhaseSignals(date: cycleDay(4), flagging: true)]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(4))

        #expect(result.phase == .estrus)
        #expect(result.source == .observedSignals)
        #expect(result.confidence == .moderate)
    }

    @Test("Anzeichen einer Scheinträchtigkeit ⇒ Diöstrus")
    func pseudopregnancyMeansDiestrus() {
        let signals = [PhaseSignals(date: cycleDay(45), pseudopregnancySigns: true)]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(45))

        #expect(result.phase == .diestrus)
        #expect(result.source == .observedSignals)  // nicht nur der Kalender
        #expect(result.confidence == .moderate)
    }

    @Test("Der neueste relevante Eintrag gewinnt, nicht der erste")
    func newestObservationWins() {
        let early = PhaseSignals(
            date: cycleDay(3), dischargePresent: true,
            dischargeColor: .bloody, vulvaTurgor: .swollenFirm
        )
        let late = PhaseSignals(
            date: cycleDay(11), dischargePresent: true,
            dischargeColor: .strawColored, vulvaTurgor: .swollenSoft
        )

        let sorted = estimator.estimatePhase(day1: day1, signals: [early, late], asOf: cycleDay(12))
        let shuffled = estimator.estimatePhase(day1: day1, signals: [late, early], asOf: cycleDay(12))

        #expect(sorted.phase == .estrus)
        // Eingabereihenfolge darf das Ergebnis nicht verändern.
        #expect(shuffled == sorted)
    }

    @Test("Innerhalb eines Tages entscheidet die Uhrzeit, nicht die Eingabereihenfolge")
    func timeOfDayOutranksInputOrder() {
        let evening = PhaseSignals(
            date: cycleDay(5).addingTimeInterval(18 * 3600), standingHeat: true
        )
        let morning = PhaseSignals(
            date: cycleDay(5).addingTimeInterval(8 * 3600), dischargePresent: true,
            dischargeColor: .bloody, vulvaTurgor: .swollenFirm
        )
        // Der Morgen-Eintrag steht hinten im Array, ist aber der ältere.
        let result = estimator.estimatePhase(day1: day1, signals: [evening, morning], asOf: cycleDay(5))

        #expect(result.phase == .estrus)
        #expect(result.source == .observedSignals)
    }

    @Test("Bei zwei Einträgen desselben Tages gilt der zuletzt eingetragene")
    func lastEntryOfTheSameDayWins() {
        let bloody = PhaseSignals(
            date: cycleDay(5), dischargePresent: true,
            dischargeColor: .bloody, vulvaTurgor: .swollenFirm
        )
        let heat = PhaseSignals(date: cycleDay(5), standingHeat: true)

        #expect(estimator.estimatePhase(day1: day1, signals: [bloody, heat], asOf: cycleDay(5)).phase == .estrus)
        #expect(estimator.estimatePhase(day1: day1, signals: [heat, bloody], asOf: cycleDay(5)).phase == .proestrus)
    }

    @Test("Identische Duplikate ändern das Ergebnis nicht")
    func duplicateEntriesAreIdempotent() {
        let signal = PhaseSignals(
            date: cycleDay(11), dischargePresent: true,
            dischargeColor: .strawColored, vulvaTurgor: .swollenSoft
        )
        let single = estimator.estimatePhase(day1: day1, signals: [signal], asOf: cycleDay(12))
        let tripled = estimator.estimatePhase(
            day1: day1, signals: [signal, signal, signal], asOf: cycleDay(12)
        )

        #expect(tripled == single)
    }

    @Test("Signale nach dem Bezugsdatum bleiben unberücksichtigt")
    func futureSignalsAreIgnored() {
        let heatLater = PhaseSignals(date: cycleDay(20), standingHeat: true)

        let asOfBefore = estimator.estimatePhase(day1: day1, signals: [heatLater], asOf: cycleDay(5))
        #expect(asOfBefore.source == .populationDefault)
        #expect(asOfBefore.phase == .proestrus)

        // Gegenprobe: derselbe Eintrag am Bezugstag zählt sehr wohl.
        let asOfSameDay = estimator.estimatePhase(day1: day1, signals: [heatLater], asOf: cycleDay(20))
        #expect(asOfSameDay.source == .observedSignals)
        #expect(asOfSameDay.phase == .estrus)
    }

    @Test("Ein zukünftiger Laborwert hebt die heutige Beobachtung nicht auf")
    func futureClinicalValueDoesNotOverrideToday() {
        let signals = [
            PhaseSignals(
                date: cycleDay(4), dischargePresent: true,
                dischargeColor: .bloody, vulvaTurgor: .swollenFirm
            ),
            PhaseSignals(date: cycleDay(9), progesteroneNgPerMl: 20),
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(4))

        #expect(result.phase == .proestrus)
        #expect(result.source == .observedSignals)
    }

    // MARK: - Stufe 1: klinische Werte

    @Test("Kornifizierung über 80 % ⇒ Östrus mit hoher Konfidenz")
    func highCornificationMeansEstrus() {
        let signals = [PhaseSignals(date: cycleDay(4), cornificationPercent: 95)]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(4))

        #expect(result.phase == .estrus)
        #expect(result.source == .clinicalSignals)
        #expect(result.confidence == .high)
    }

    @Test("Kornifizierung auf oder unter der Schwelle benennt keine Phase")
    func lowCornificationNamesNoPhase() {
        let signals = [
            PhaseSignals(
                date: cycleDay(6), dischargePresent: true, dischargeColor: .bloody,
                vulvaTurgor: .swollenFirm, cornificationPercent: 80
            )
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(6))

        // Fällt auf Stufe 2 durch, statt Stufe 1 zu blockieren.
        #expect(result.phase == .proestrus)
        #expect(result.source == .observedSignals)
    }

    @Test("Progesteron ab LH-Schwelle ⇒ Östrus, auch wenn der Kalender Proöstrus sagt")
    func progesteroneAtLHThresholdMeansEstrus() {
        let signals = [
            PhaseSignals(
                date: cycleDay(5),
                progesteroneNgPerMl: StudyConstants.progesteroneLHPeakThresholdNgPerMl
            )
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(5))

        #expect(result.phase == .estrus)
        #expect(result.source == .clinicalSignals)
        #expect(result.confidence == .high)
    }

    @Test("Progesteron ab Ovulationsschwelle: Kalender entscheidet Östrus vs. Diöstrus")
    func progesteroneAboveOvulationThresholdNarrowsToEstrusOrDiestrus() {
        let value = StudyConstants.progesteroneOvulationThresholdNgPerMl

        // Innerhalb des Kalender-Östrus ⇒ Östrus …
        let inEstrus = estimator.estimatePhase(
            day1: day1,
            signals: [PhaseSignals(date: cycleDay(12), progesteroneNgPerMl: value)],
            asOf: cycleDay(12)
        )
        #expect(inEstrus.phase == .estrus)
        #expect(inEstrus.source == .clinicalSignals)

        // … danach ⇒ Diöstrus, und nicht mehr Anöstrus, selbst spät im Zyklus.
        let afterEstrus = estimator.estimatePhase(
            day1: day1,
            signals: [PhaseSignals(date: cycleDay(30), progesteroneNgPerMl: value + 20)],
            asOf: cycleDay(30)
        )
        #expect(afterEstrus.phase == .diestrus)
        #expect(afterEstrus.source == .clinicalSignals)
        #expect(afterEstrus.confidence == .high)
    }

    @Test("Ein Basalwert entscheidet nichts und blockiert Stufe 2 nicht")
    func basalProgesteroneFallsThrough() {
        let below = StudyConstants.progesteroneLHPeakThresholdNgPerMl - 1
        let signals = [
            PhaseSignals(
                date: cycleDay(5), dischargePresent: true, dischargeColor: .bloody,
                vulvaTurgor: .swollenFirm, progesteroneNgPerMl: below
            )
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(5))

        #expect(result.phase == .proestrus)
        #expect(result.source == .observedSignals)
        #expect(result.confidence == .moderate)
    }

    @Test("Basalwert von heute lässt den älteren aussagekräftigen Laborwert gelten")
    func basalValueDoesNotHideOlderClinicalValue() {
        let signals = [
            PhaseSignals(date: cycleDay(10), progesteroneNgPerMl: 25),
            PhaseSignals(date: cycleDay(30), progesteroneNgPerMl: 0.5),
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(30))

        #expect(result.phase == .diestrus)
        #expect(result.source == .clinicalSignals)
    }

    // MARK: - Rangfolge zwischen den Stufen

    @Test("Klinisch schlägt Beobachtung, auch wenn die Beobachtung neuer ist")
    func clinicalBeatsNewerObservation() {
        let signals = [
            // Laborwert von Tag 4: Eisprung überschritten.
            PhaseSignals(
                date: cycleDay(4),
                progesteroneNgPerMl: StudyConstants.progesteroneOvulationThresholdNgPerMl + 2
            ),
            // Widersprechende Beobachtung von Tag 6: sähe nach Proöstrus aus.
            PhaseSignals(
                date: cycleDay(6), dischargePresent: true,
                dischargeColor: .bloody, vulvaTurgor: .swollenFirm
            ),
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(7))

        #expect(result.phase == .estrus)
        #expect(result.source == .clinicalSignals)
        #expect(result.confidence == .high)
    }

    @Test("Beobachtung schlägt den Populations-Default")
    func observationBeatsPopulationDefault() {
        // Kalendarisch wäre Tag 40 Diöstrus; die Beobachtung sagt Proöstrus.
        let signals = [
            PhaseSignals(
                date: cycleDay(40), dischargePresent: true,
                dischargeColor: .bloody, vulvaTurgor: .swollenFirm
            )
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(40))

        #expect(estimator.phaseFromDayInCycle(40) == .diestrus)
        #expect(result.phase == .proestrus)
        #expect(result.source == .observedSignals)
        #expect(result.confidence > .low)
    }

    @Test("Duldung schlägt die Ausfluss-Kombination desselben Eintrags")
    func standingHeatOutranksDischargeOfSameEntry() {
        let signals = [
            PhaseSignals(
                date: cycleDay(7), dischargePresent: true, dischargeColor: .bloody,
                vulvaTurgor: .swollenFirm, standingHeat: true
            )
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(7))

        #expect(result.phase == .estrus)
        #expect(result.confidence == .high)
    }

    // MARK: - Erwartetes Phasenende

    @Test("Phasenende ist die Populationsspanne ab Phasenbeginn")
    func expectedPhaseEndSpansPopulationRange() {
        let result = estimator.estimatePhase(day1: day1, signals: [], asOf: day1)

        #expect(result.phase == .proestrus)
        #expect(result.expectedPhaseEnd.lowerBound == cycleDay(StudyConstants.proestrusMinDays))
        #expect(result.expectedPhaseEnd.upperBound == cycleDay(StudyConstants.proestrusMaxDays))
    }

    @Test("Das Phasenende liegt nie in der Vergangenheit")
    func expectedPhaseEndNeverInThePast() {
        // Proöstrus an Tag 40: kalendarisch längst vorbei, die Beobachtung sagt
        // aber, dass er noch läuft — dann heißt die Aussage „kann heute enden".
        let signals = [
            PhaseSignals(
                date: cycleDay(40), dischargePresent: true,
                dischargeColor: .bloody, vulvaTurgor: .swollenFirm
            )
        ]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(40))

        #expect(result.expectedPhaseEnd.lowerBound == cycleDay(40))
        #expect(result.expectedPhaseEnd.upperBound == cycleDay(40))
    }

    @Test("Beobachtete Phase vor dem Kalender: Ende zählt ab heute")
    func expectedPhaseEndAnchorsOnTodayWhenPhaseStartsEarly() {
        // Östrus schon an Tag 4 belegt, kalendarisch beginnt er erst an Tag 10.
        let signals = [PhaseSignals(date: cycleDay(4), standingHeat: true)]
        let result = estimator.estimatePhase(day1: day1, signals: signals, asOf: cycleDay(4))

        #expect(result.phase == .estrus)
        #expect(result.expectedPhaseEnd.lowerBound == cycleDay(4 + StudyConstants.estrusMinDays - 1))
        #expect(result.expectedPhaseEnd.upperBound == cycleDay(4 + StudyConstants.estrusMaxDays - 1))
    }

    @Test("Invarianten der Spanne über einen ganzen Zyklus")
    func expectedPhaseEndInvariants() {
        for dayNumber in 1...300 {
            let asOf = cycleDay(dayNumber)
            let result = estimator.estimatePhase(day1: day1, signals: [], asOf: asOf)

            #expect(result.expectedPhaseEnd.lowerBound <= result.expectedPhaseEnd.upperBound)
            #expect(result.expectedPhaseEnd.lowerBound >= DayMath.utc.startOfDay(asOf))
            #expect(result.dayInCycle == dayNumber)
        }
    }

    @Test("Bezugsdatum vor Tag 1: Tag 1, Proöstrus, gültige Spanne")
    func asOfBeforeDay1() {
        let asOf = day(2026, 2, 20)
        let result = estimator.estimatePhase(day1: day1, signals: [], asOf: asOf)

        #expect(result.dayInCycle == 1)
        #expect(result.phase == .proestrus)
        #expect(result.source == .populationDefault)
        #expect(result.expectedPhaseEnd.lowerBound <= result.expectedPhaseEnd.upperBound)
        #expect(result.expectedPhaseEnd.lowerBound >= DayMath.utc.startOfDay(asOf))
    }
}
