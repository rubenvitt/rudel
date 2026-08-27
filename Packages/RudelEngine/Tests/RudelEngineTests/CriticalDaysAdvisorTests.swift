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

@Suite("CriticalDaysAdvisor — kritische Tage der Läufigkeit")
struct CriticalDaysAdvisorTests {

    private let dayMath = DayMath.utc
    private let advisor = CriticalDaysAdvisor(dayMath: .utc)
    private let day1 = day(2026, 3, 1)

    private func cycleDay(_ n: Int) -> Date {
        dayMath.adding(days: n - 1, to: day1)
    }

    private func signal(
        dayInCycle: Int,
        standingHeat: Bool? = nil,
        flagging: Bool? = nil,
        color: DischargeColor? = nil,
        turgor: VulvaTurgor? = nil,
        progesterone: Double? = nil,
        frequentUrination: Bool? = nil,
        genitalLicking: Bool? = nil,
        vulvaSwellingVisible: Bool? = nil,
        attractsMales: Bool? = nil
    ) -> PhaseSignals {
        PhaseSignals(
            date: cycleDay(dayInCycle),
            dischargeColor: color,
            vulvaTurgor: turgor,
            frequentUrination: frequentUrination,
            genitalLicking: genitalLicking,
            vulvaSwellingVisible: vulvaSwellingVisible,
            flagging: flagging,
            standingHeat: standingHeat,
            attractsMales: attractsMales,
            progesteroneNgPerMl: progesterone
        )
    }

    /// Hinweise für einen Zyklustag-Bereich.
    private func notices(
        signals: [PhaseSignals] = [],
        visibleHeatEnd: Date? = nil,
        fromDay: Int,
        throughDay: Int
    ) -> [CriticalDayNotice] {
        advisor.notices(
            day1: day1,
            signals: signals,
            visibleHeatEnd: visibleHeatEnd,
            petName: "Zola",
            sourceID: "period-1",
            from: cycleDay(fromDay),
            through: cycleDay(throughDay)
        )
    }

    // MARK: - Studienwerte als Fixtures (PRD §7)

    @Test("Die Studienwerte, auf denen die Grenzen unten beruhen")
    func studyConstantsArePinned() {
        #expect(StudyConstants.proestrusTypicalDays == 9)
        #expect(StudyConstants.proestrusMinDays == 3)
        #expect(StudyConstants.estrusMaxDays == 21)
        #expect(CriticalDaysAdvisor.subsidingBufferDays == 3)
    }

    // MARK: - Stufenfolge

    @Test("Vor dem kritischen Beginn gilt die niedrigere Stufe")
    func earlyDaysAreElevatedNotCritical() {
        let result = notices(fromDay: 1, throughDay: 8)

        #expect(result.count == 8)
        #expect(result.allSatisfy { $0.risk == .elevated })
        #expect(result.allSatisfy { $0.phase == .proestrus })
    }

    @Test("Ab Tag 9 gilt die kritische Stufe — einen Tag vor dem Median-Übergang")
    func criticalStartsOneDayBeforeMedianTransition() {
        // Der Median-Übergang Proöstrus → Östrus liegt bei Tag 10
        // (Proöstrus 1...9). Die Warnung beginnt bewusst einen Tag früher: die
        // Spanne reicht von Tag 4 bis 18, dem Median zu folgen käme in der
        // Hälfte der Fälle zu spät.
        let result = notices(fromDay: 8, throughDay: 10)

        #expect(result[0].dayInCycle == 8)
        #expect(result[0].risk == .elevated)
        #expect(result[1].dayInCycle == 9)
        #expect(result[1].risk == .critical)
        #expect(result[1].isTransition)
        #expect(result[2].risk == .critical)
        #expect(!result[2].isTransition)
    }

    @Test("Nach dem kritischen Zeitraum klingt es ab und endet dann")
    func riskSubsidesAndThenStops() {
        // Ohne erfasstes Hitze-Ende läuft `.critical` bis Tag 9 + 21 = 30,
        // danach drei Tage `.subsiding`.
        let result = notices(fromDay: 29, throughDay: 36)
        let byDay = Dictionary(uniqueKeysWithValues: result.map { ($0.dayInCycle, $0.risk) })

        #expect(byDay[30] == .critical)
        #expect(byDay[31] == .subsiding)
        #expect(byDay[33] == .subsiding)
        #expect(byDay[34] == nil, "Nach dem Puffer darf kein Hinweis mehr kommen")
        #expect(result.allSatisfy { $0.dayInCycle <= 33 })
    }

    @Test("Im Anöstrus gibt es nichts zu warnen")
    func anestrusYieldsNothing() {
        #expect(notices(fromDay: 120, throughDay: 134).isEmpty)
    }

    @Test("Tage vor Tag 1 erzeugen keinen Hinweis")
    func daysBeforeAnchorAreSkipped() {
        let result = advisor.notices(
            day1: day1,
            signals: [],
            visibleHeatEnd: nil,
            petName: "Zola",
            sourceID: "period-1",
            from: dayMath.adding(days: -5, to: day1),
            through: cycleDay(3)
        )

        #expect(result.allSatisfy { $0.dayInCycle >= 1 })
        #expect(result.first?.dayInCycle == 1)
    }

    // MARK: - Beobachtungen ziehen den Beginn vor, nie nach hinten

    @Test("Beobachtete Standhitze zieht die kritische Stufe vor")
    func standingHeatPullsCriticalForward() {
        let result = notices(
            signals: [signal(dayInCycle: 6, standingHeat: true)],
            fromDay: 5,
            throughDay: 7
        )
        let byDay = Dictionary(uniqueKeysWithValues: result.map { ($0.dayInCycle, $0.risk) })

        #expect(byDay[5] == .elevated)
        #expect(byDay[6] == .critical, "Dokumentierte Duldung ist der Beweis, dass der Östrus läuft")
        #expect(byDay[7] == .critical)
    }

    @Test("Strohfarbener Ausfluss und weiche Vulva ziehen ebenfalls vor")
    func estrusSignsPullCriticalForward() {
        #expect(advisor.criticalStartDay(anchor: day1, signals: [signal(dayInCycle: 7, color: .strawColored)]) == 7)
        #expect(advisor.criticalStartDay(anchor: day1, signals: [signal(dayInCycle: 5, turgor: .swollenSoft)]) == 5)
        #expect(advisor.criticalStartDay(anchor: day1, signals: [signal(dayInCycle: 4, flagging: true)]) == 4)
        #expect(advisor.criticalStartDay(anchor: day1, signals: [signal(dayInCycle: 6, progesterone: 3.0)]) == 6)
    }

    @Test("Späte Beobachtungen verschieben den Beginn NICHT nach hinten")
    func lateSignsDoNotDelayCritical() {
        // Standhitze erst an Tag 14 dokumentiert — häufig, weil vorher niemand
        // hingesehen hat. Der kritische Zeitraum darf deshalb nicht erst dann
        // beginnen: bis dahin war die Hündin genauso gefährdet.
        let start = advisor.criticalStartDay(
            anchor: day1,
            signals: [signal(dayInCycle: 14, standingHeat: true)]
        )

        #expect(start == StudyConstants.proestrusTypicalDays)
    }

    @Test("Leere Beobachtungen ändern nichts")
    func emptySignalsAreIgnored() {
        let empty = PhaseSignals(date: cycleDay(3))
        #expect(advisor.criticalStartDay(anchor: day1, signals: [empty]) == StudyConstants.proestrusTypicalDays)
    }

    @Test("Der frühere von mehreren Hinweisen gewinnt")
    func earliestSignWins() {
        let start = advisor.criticalStartDay(
            anchor: day1,
            signals: [
                signal(dayInCycle: 11, standingHeat: true),
                signal(dayInCycle: 5, color: .pinkish),
                signal(dayInCycle: 8, flagging: true),
            ]
        )

        #expect(start == 5)
    }

    // MARK: - Ende der sichtbaren Hitze

    @Test("Ein erfasstes Hitze-Ende beendet die Hinweise früher")
    func recordedHeatEndShortensTheWindow() {
        let withoutEnd = advisor.criticalEndDay(anchor: day1, visibleHeatEnd: nil)
        let withEnd = advisor.criticalEndDay(anchor: day1, visibleHeatEnd: cycleDay(18))

        #expect(withoutEnd == StudyConstants.proestrusTypicalDays + StudyConstants.estrusMaxDays)
        #expect(withEnd == 18)
        #expect(withEnd < withoutEnd, "Loggen muss sich lohnen: es beendet die Erinnerungen")
    }

    @Test("Nach erfasstem Ende bleibt der Puffer, dann ist Ruhe")
    func bufferFollowsRecordedEnd() {
        let result = notices(visibleHeatEnd: cycleDay(18), fromDay: 17, throughDay: 24)
        let byDay = Dictionary(uniqueKeysWithValues: result.map { ($0.dayInCycle, $0.risk) })

        #expect(byDay[18] == .critical)
        #expect(byDay[19] == .subsiding)
        #expect(byDay[21] == .subsiding)
        #expect(byDay[22] == nil)
    }

    @Test("Ein unplausibel frühes Hitze-Ende macht das Fenster nicht negativ")
    func implausibleEndDoesNotInvertTheWindow() {
        // Tippfehler oder eine extrem kurze Läufigkeit: Ende auf Tag 1.
        let end = advisor.criticalEndDay(anchor: day1, visibleHeatEnd: day1)
        #expect(end >= StudyConstants.proestrusMinDays)

        let result = notices(visibleHeatEnd: day1, fromDay: 1, throughDay: 14)
        #expect(!result.isEmpty, "Auch bei kaputtem Ende muss gewarnt werden")
        #expect(result.allSatisfy { $0.dayInCycle >= 1 })
    }

    // MARK: - Übergänge

    @Test("Ein Übergang wird auch erkannt, wenn der Vortag außerhalb des Fensters lag")
    func transitionIsDetectedAcrossTheWindowEdge() {
        // Das Fenster beginnt genau am ersten kritischen Tag. Der Vortag hat
        // keinen Hinweis bekommen — trotzdem ist heute ein Übergang, und die
        // Meldung muss die deutlichere Variante sein.
        let result = notices(fromDay: 9, throughDay: 9)

        #expect(result.count == 1)
        #expect(result[0].isTransition)
        #expect(result[0].title.contains("beginnen"))
    }

    @Test("Innerhalb einer Stufe ist nur der erste Tag ein Übergang")
    func onlyFirstDayOfALevelIsATransition() {
        let result = notices(fromDay: 9, throughDay: 14)
        #expect(result.filter(\.isTransition).count == 1)
        #expect(result.first?.isTransition == true)
    }

    // MARK: - IDs und Texte

    @Test("IDs sind deterministisch und über den Zeitraum eindeutig")
    func identifiersAreStableAndUnique() {
        let first = notices(fromDay: 1, throughDay: 20)
        let second = notices(fromDay: 1, throughDay: 20)

        #expect(first.map(\.id) == second.map(\.id), "Gleiche Eingabe, gleiche IDs")
        #expect(Set(first.map(\.id)).count == first.count)
    }

    @Test("Kein Titel und kein Text ist leer")
    func textsAreNeverEmpty() {
        for notice in notices(fromDay: 1, throughDay: 33) {
            #expect(!notice.title.isEmpty)
            #expect(!notice.body.isEmpty)
            #expect(notice.body.contains("Tag \(notice.dayInCycle)"))
        }
    }

    @Test("Ohne Beobachtungen benennt der Text, dass geschätzt wird")
    func textAdmitsWhenItIsOnlyAnEstimate() {
        let estimated = notices(fromDay: 10, throughDay: 10).first
        #expect(estimated?.body.contains("Erfahrungswerten") == true)

        // Mit dokumentierter Standhitze ist es keine Schätzung mehr.
        let observed = notices(
            signals: [signal(dayInCycle: 9, standingHeat: true)],
            fromDay: 10,
            throughDay: 10
        ).first
        #expect(observed?.body.contains("Erfahrungswerten") == false)
    }

    @Test("Ein leerer Tiername führt nicht zu einem kopflosen Titel")
    func emptyPetNameGetsAFallback() {
        let result = advisor.notices(
            day1: day1,
            signals: [],
            visibleHeatEnd: nil,
            petName: "",
            sourceID: "period-1",
            from: cycleDay(10),
            through: cycleDay(10)
        )

        #expect(result.first?.title.isEmpty == false)
        #expect(result.first?.title.hasPrefix(" ") == false)
    }

    @Test("Umgekehrtes Fenster ergibt keine Hinweise statt eines Absturzes")
    func invertedWindowIsEmpty() {
        let result = advisor.notices(
            day1: day1,
            signals: [],
            visibleHeatEnd: nil,
            petName: "Zola",
            sourceID: "period-1",
            from: cycleDay(20),
            through: cycleDay(10)
        )

        #expect(result.isEmpty)
    }

    // MARK: - Die niedrige Stufe verspricht nicht zu viel

    @Test("Ab Tag 4 behauptet die niedrige Stufe nicht mehr, eine Deckung sei unmöglich")
    func elevatedStopsClaimingImpossibleOnceEstrusCouldStart() {
        let result = notices(fromDay: 1, throughDay: 8)
        let byDay = Dictionary(uniqueKeysWithValues: result.map { ($0.dayInCycle, $0) })

        // Tag 1–3: der Proöstrus dauert mindestens 3 Tage, hier stimmt das „noch nicht".
        #expect(byDay[3]?.body.contains("noch nicht") == true)
        // Ab Tag 4 kann der Östrus laut Populationsspanne beginnen.
        for dayNumber in 4...8 {
            #expect(byDay[dayNumber]?.body.contains("noch nicht") == false)
            #expect(byDay[dayNumber]?.body.contains("nicht ausgeschlossen") == true)
        }
        // Die Stufe bleibt trotzdem die niedrige — sonst wäre fast die ganze
        // Läufigkeit kritisch und die Abstufung wertlos.
        #expect(result.allSatisfy { $0.risk == .elevated })
    }

    @Test("Die Grenze folgt der Studienkonstante, nicht einer Zahl im Text")
    func elevatedWordingBoundaryFollowsStudyConstant() {
        let result = notices(fromDay: 4, throughDay: 4)
        #expect(result.first?.body.contains("Tag \(StudyConstants.proestrusMinDays + 1)") == true)
    }

    // MARK: - Flagging zieht den kritischen Beginn nach vorn

    @Test("Flagging an Tag 4 macht Tag 4 kritisch — nicht erst Tag 9")
    func flaggingOnDayFourMakesDayFourCritical() {
        let result = notices(
            signals: [signal(dayInCycle: 4, flagging: true)],
            fromDay: 1,
            throughDay: 10
        )

        let byDay = Dictionary(uniqueKeysWithValues: result.map { ($0.dayInCycle, $0) })
        #expect(byDay[3]?.risk == .elevated)
        #expect(byDay[4]?.risk == .critical)
        // Der erste kritische Tag verdient die deutlichere Meldung.
        #expect(byDay[4]?.isTransition == true)
        #expect(byDay[5]?.risk == .critical)
        #expect(byDay[9]?.risk == .critical)
    }

    @Test("Flagging ist absichtlich weniger spezifisch als Duldung — beide ziehen gleich weit vor")
    func flaggingAndStandingHeatPullForwardAlike() {
        let viaFlagging = advisor.criticalStartDay(
            anchor: day1, signals: [signal(dayInCycle: 5, flagging: true)]
        )
        let viaStandingHeat = advisor.criticalStartDay(
            anchor: day1, signals: [signal(dayInCycle: 5, standingHeat: true)]
        )

        // Gleiche Wirkung, unterschiedliche Verfügbarkeit: das Flagging tritt
        // früher auf, also greift die Regel über dasselbe Signal früher.
        #expect(viaFlagging == 5)
        #expect(viaStandingHeat == 5)
    }

    // MARK: - Alltagszeichen ziehen nichts vor

    @Test("Alltagszeichen an Tag 2 machen Tag 2 nicht kritisch")
    func everydaySignsDoNotPullCriticalForward() {
        let result = notices(
            signals: [
                signal(
                    dayInCycle: 2,
                    frequentUrination: true,
                    genitalLicking: true,
                    vulvaSwellingVisible: true,
                    attractsMales: true
                )
            ],
            fromDay: 1,
            throughDay: 10
        )

        let byDay = Dictionary(uniqueKeysWithValues: result.map { ($0.dayInCycle, $0) })
        // Alle vier setzen mit dem Proöstrus ein und halten über den Östrus an —
        // sie trennen die Phasen nicht. Zählte man sie mit, liefe die Stufe
        // `.critical` ab Tag 2 durch und wäre damit wertlos.
        #expect(byDay[2]?.risk == .elevated)
        #expect(byDay[8]?.risk == .elevated)
        #expect(byDay[9]?.risk == .critical)
    }

    @Test("Alltagszeichen verschieben den kritischen Beginn auch einzeln nicht")
    func everydaySignsLeaveCriticalStartAtPopulationValue() {
        let cases: [PhaseSignals] = [
            signal(dayInCycle: 2, frequentUrination: true),
            signal(dayInCycle: 2, genitalLicking: true),
            signal(dayInCycle: 2, vulvaSwellingVisible: true),
            signal(dayInCycle: 2, attractsMales: true)
        ]

        for candidate in cases {
            #expect(advisor.criticalStartDay(anchor: day1, signals: [candidate])
                == StudyConstants.proestrusTypicalDays)
        }
    }

    @Test("Ein Alltagszeichen belegt trotzdem, dass eine Läufigkeit läuft")
    func everydaySignsProveActiveHeat() {
        #expect(signal(dayInCycle: 2, frequentUrination: true).indicatesActiveHeat)
        #expect(signal(dayInCycle: 2, genitalLicking: true).indicatesActiveHeat)
        #expect(signal(dayInCycle: 2, vulvaSwellingVisible: true).indicatesActiveHeat)
        // `false` ist ein Befund, aber kein Beleg.
        #expect(!signal(dayInCycle: 2, frequentUrination: false).indicatesActiveHeat)
        #expect(!signal(dayInCycle: 2).indicatesActiveHeat)
    }

    // MARK: - Risikostufen-Ordnung

    @Test("Kritisch ist die höchste Stufe, abklingend die niedrigste")
    func riskOrderingFollowsUrgencyNotRawValue() {
        #expect(HeatRiskLevel.critical > HeatRiskLevel.elevated)
        #expect(HeatRiskLevel.elevated > HeatRiskLevel.subsiding)
        #expect(HeatRiskLevel.allCases.max() == .critical)
    }
}
