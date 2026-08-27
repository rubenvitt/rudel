import Foundation

/// Wie sehr während einer laufenden Läufigkeit aufgepasst werden muss.
///
/// Die Abstufung existiert, weil „läufig" und „kann aufnehmen" nicht dasselbe
/// sind: im Proöstrus zeigen Rüden bereits Interesse, die Hündin duldet aber
/// noch nicht. Eine einzige Warnstufe über drei Wochen würde stumpf und damit
/// ignoriert.
public enum HeatRiskLevel: Int, Sendable, Codable, CaseIterable, Comparable, Hashable {
    /// Proöstrus: Rüden werden angezogen, Duldung noch nicht zu erwarten.
    case elevated = 0
    /// Östrus: Deckung möglich. Die Stufe, um die es hier eigentlich geht.
    case critical = 1
    /// Früher Diöstrus: Duldung klingt ab, Restrisiko in den ersten Tagen.
    case subsiding = 2

    public static func < (lhs: HeatRiskLevel, rhs: HeatRiskLevel) -> Bool {
        // Reihenfolge nach Dringlichkeit, nicht nach rawValue: `critical` ist die
        // höchste Stufe, `subsiding` liegt darunter.
        lhs.severity < rhs.severity
    }

    private var severity: Int {
        switch self {
        case .subsiding: return 0
        case .elevated: return 1
        case .critical: return 2
        }
    }
}

/// Ein Tageshinweis während einer laufenden Läufigkeit.
public struct CriticalDayNotice: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    /// Kalendertag, für den der Hinweis gilt.
    public var date: Date
    /// Tag im Zyklus, 1-basiert.
    public var dayInCycle: Int

    /// Phase **allein aus dem Kalender** (`phaseFromDayInCycle`), nicht die
    /// Phasenschätzung der App.
    ///
    /// Bewusst so: die Hinweise gelten auch für künftige Tage, für die es keine
    /// Beobachtungen geben kann. Dadurch kann `phase` von dem abweichen, was der
    /// Zyklus-Tab für denselben Tag zeigt — eine an Tag 6 dokumentierte
    /// Standhitze ergibt hier `risk == .critical` bei `phase == .proestrus`.
    /// `risk` ist die Aussage, auf die es ankommt; `phase` ist Kontext.
    /// **Nicht** als Phasenanzeige rendern, dafür ist `CyclePhaseEstimator` da.
    public var phase: CyclePhase

    public var risk: HeatRiskLevel
    /// Erster Tag dieser Stufe — verdient eine eigene, deutlichere Meldung als
    /// der fünfte Tag in derselben Lage.
    public var isTransition: Bool
    public var title: String
    public var body: String

    public init(
        id: String,
        date: Date,
        dayInCycle: Int,
        phase: CyclePhase,
        risk: HeatRiskLevel,
        isTransition: Bool,
        title: String,
        body: String
    ) {
        self.id = id
        self.date = date
        self.dayInCycle = dayInCycle
        self.phase = phase
        self.risk = risk
        self.isTransition = isTransition
        self.title = title
        self.body = body
    }
}

/// Erzeugt die Tageshinweise für die „kritischen Tage" einer laufenden
/// Läufigkeit.
///
/// ## Warum das eine eigene Einheit ist und nicht Teil von `DueItemBuilder`
///
/// Eine Fälligkeit hat einen Termin; kritische Tage sind ein Zustand, der über
/// Wochen anhält und dessen Grenzen unscharf sind. Der Nutzer braucht dazu nicht
/// eine Erinnerung, sondern eine pro Tag — mit dem Tag im Zyklus, weil genau das
/// die Frage ist, die man morgens hat: *Muss Zola heute an der Leine bleiben?*
///
/// ## Konservativ nach vorn, nicht nach der Punktschätzung
///
/// Der Übergang Proöstrus → Östrus liegt im Median bei Tag 10, die Spanne reicht
/// aber von Tag 4 bis Tag 18. Eine Warnung, die dem Median folgt, kommt in
/// einem von zwei Fällen zu spät — und „zu spät" heißt hier: ein Deckakt, der
/// nicht rückgängig zu machen ist. Deshalb beginnt `.critical` bereits einen Tag
/// **vor** dem Median-Übergang, und beobachtete Signale (Standhitze, Farbwechsel
/// des Ausflusses) ziehen ihn weiter nach vorn, nie nach hinten.
///
/// Das Ende ist aus demselben Grund großzügig: ohne erfasstes Hitze-Ende läuft
/// `.critical` bis zum Ende der Östrus-Spanne. Wer das sichtbare Ende einträgt,
/// beendet die Hinweise früher — ein Anreiz zum Loggen, der in die richtige
/// Richtung zeigt.
public struct CriticalDaysAdvisor: Sendable {
    public let dayMath: DayMath

    /// Tage nach dem Ende der sichtbaren Hitze, an denen weiter gewarnt wird.
    ///
    /// Die Duldungsbereitschaft endet nicht schlagartig, und Spermien bleiben im
    /// Genitaltrakt der Hündin mehrere Tage befruchtungsfähig. Ein Puffer ist
    /// hier billiger als ein Wurf.
    public static let subsidingBufferDays = 3

    public init(dayMath: DayMath = .utc) {
        self.dayMath = dayMath
    }

    /// Tageshinweise für den Zeitraum `from ... through`.
    ///
    /// - Parameters:
    ///   - day1: Tag-1-Anker der laufenden Läufigkeit.
    ///   - signals: bisherige Beobachtungen. Sie können den Beginn der Stufe
    ///     `.critical` nur **vorziehen**, nie verschieben.
    ///   - visibleHeatEnd: erfasstes Ende der sichtbaren Hitze, falls vorhanden.
    ///   - petName: für die Meldungstexte.
    ///   - sourceID: opake ID der Läufigkeit, geht in die Notice-IDs ein.
    ///   - from: erster Tag des Fensters (üblicherweise „heute").
    ///   - through: letzter Tag des Fensters.
    /// - Returns: aufsteigend sortierte Hinweise, einer pro Kalendertag, an dem
    ///   überhaupt eine Stufe gilt. Leer, sobald der Zyklus die relevanten Phasen
    ///   hinter sich hat — im Anöstrus gibt es nichts zu warnen.
    public func notices(
        day1: Date,
        signals: [PhaseSignals],
        visibleHeatEnd: Date?,
        petName: String,
        sourceID: String,
        from: Date,
        through: Date
    ) -> [CriticalDayNotice] {
        let anchor = dayMath.startOfDay(day1)
        let windowStart = max(dayMath.startOfDay(from), anchor)
        let windowEnd = dayMath.startOfDay(through)
        guard windowStart <= windowEnd else { return [] }

        let criticalEnd = criticalEndDay(anchor: anchor, visibleHeatEnd: visibleHeatEnd)
        // Ein erfasstes Hitze-Ende kann vor dem geschätzten kritischen Beginn
        // liegen — bei einem drei Tage kurzen Proöstrus ist das biologisch
        // möglich, bei einem Tippfehler im Datum sowieso. Dann war der kritische
        // Zeitraum eben kürzer als der Populationswert, nicht leer: der Beginn
        // wird mitgezogen, statt eine leere Spanne zu erzeugen.
        let criticalStart = min(criticalStartDay(anchor: anchor, signals: signals), criticalEnd)
        let subsidingEnd = criticalEnd + Self.subsidingBufferDays

        let name = petName.isEmpty ? "Dein Tier" : petName
        var result: [CriticalDayNotice] = []

        for offset in 0...max(0, dayMath.days(from: windowStart, to: windowEnd)) {
            let date = dayMath.adding(days: offset, to: windowStart)
            let dayInCycle = dayMath.days(from: anchor, to: date) + 1

            guard let level = riskLevel(
                dayInCycle: dayInCycle,
                criticalStart: criticalStart,
                criticalEnd: criticalEnd,
                subsidingEnd: subsidingEnd
            ) else { continue }

            // Der Vortag entscheidet, ob heute ein Übergang ist — auch wenn der
            // Vortag außerhalb des Fensters liegt und selbst keinen Hinweis bekam.
            let previousLevel = riskLevel(
                dayInCycle: dayInCycle - 1,
                criticalStart: criticalStart,
                criticalEnd: criticalEnd,
                subsidingEnd: subsidingEnd
            )
            let isTransition = previousLevel != level

            result.append(
                CriticalDayNotice(
                    // Deterministisch aus Quelle und Zyklustag: derselbe Tag ergibt
                    // dieselbe ID, damit iOS den Request ersetzt statt zu doppeln.
                    id: "critical-\(sourceID)-\(dayInCycle)",
                    date: date,
                    dayInCycle: dayInCycle,
                    phase: CyclePhaseEstimator(dayMath: dayMath).phaseFromDayInCycle(dayInCycle),
                    risk: level,
                    isTransition: isTransition,
                    title: title(for: level, name: name, isTransition: isTransition),
                    body: body(
                        for: level,
                        dayInCycle: dayInCycle,
                        isTransition: isTransition,
                        hasObservations: signals.contains { !$0.isEmpty },
                        criticalEnd: criticalEnd,
                        hasRecordedEnd: visibleHeatEnd != nil
                    )
                )
            )
        }

        return result
    }

    // MARK: - Grenzen der Stufen

    /// Erster Zyklustag der Stufe `.critical`.
    ///
    /// Basis ist ein Tag vor dem Median-Übergang. Beobachtungen ziehen den Beginn
    /// nach vorn: eine dokumentierte Standhitze ist der Beweis, dass der Östrus
    /// läuft, ein strohfarbener oder rosa Ausfluss beziehungsweise eine weich
    /// werdende Vulva sind starke Hinweise darauf.
    func criticalStartDay(anchor: Date, signals: [PhaseSignals]) -> Int {
        // −1 als Sicherheitsmarge gegen die breite Proöstrus-Spanne (3–17 Tage).
        var start = StudyConstants.proestrusTypicalDays

        for signal in signals where !signal.isEmpty {
            let day = dayMath.days(from: anchor, to: signal.date) + 1
            guard day >= 1 else { continue }

            let indicatesEstrus =
                signal.standingHeat == true
                || signal.flagging == true
                || signal.dischargeColor == .strawColored
                || signal.dischargeColor == .pinkish
                || signal.vulvaTurgor == .swollenSoft
                || signal.vulvaTurgor == .softening
                || (signal.progesteroneNgPerMl ?? 0) >= StudyConstants.progesteroneLHPeakThresholdNgPerMl

            if indicatesEstrus {
                start = min(start, day)
            }

            // **Nicht** in `indicatesEstrus`: `frequentUrination`,
            // `genitalLicking`, `vulvaSwellingVisible`, `attractsMales`.
            // Alle vier setzen bereits mit dem Proöstrus ein und halten über den
            // Östrus an — sie trennen die beiden Phasen nicht. Wer sie mitzählte,
            // bekäme an Tag 2 die Stufe `.critical` und damit eine Warnung, die
            // drei Wochen durchläuft und genau das ist, was die Abstufung
            // verhindern soll. Bei der sichtbaren Schwellung zeigt der Wert sogar
            // in die falsche Richtung: sie ist im Proöstrus maximal und nimmt zum
            // Östrus hin eher ab.
        }

        return max(1, start)
    }

    /// Letzter Zyklustag der Stufe `.critical`.
    func criticalEndDay(anchor: Date, visibleHeatEnd: Date?) -> Int {
        if let visibleHeatEnd {
            let endDay = dayMath.days(from: anchor, to: dayMath.startOfDay(visibleHeatEnd)) + 1
            // Ein erfasstes Ende, das vor dem kritischen Beginn liegt (sehr kurze
            // Läufigkeit oder Tippfehler), darf das Fenster nicht negativ machen.
            return max(endDay, StudyConstants.proestrusMinDays)
        }
        // Ohne erfasstes Ende bis zum Ende der Östrus-Spanne warnen: der Östrus
        // kann 21 Tage dauern, und ein zu frühes Verstummen ist der teurere Fehler.
        return StudyConstants.proestrusTypicalDays + StudyConstants.estrusMaxDays
    }

    private func riskLevel(
        dayInCycle: Int,
        criticalStart: Int,
        criticalEnd: Int,
        subsidingEnd: Int
    ) -> HeatRiskLevel? {
        // Bewusst mit Vergleichen statt `ClosedRange`: eine invertierte Spanne
        // lässt `a...b` abstürzen, und die Grenzen kommen teils aus erfassten
        // Daten. Ein kaputtes Datum darf höchstens eine seltsame Einstufung
        // ergeben, nie einen Absturz.
        guard dayInCycle >= 1 else { return nil }
        if dayInCycle < criticalStart { return .elevated }
        if dayInCycle <= criticalEnd { return .critical }
        if dayInCycle <= subsidingEnd { return .subsiding }
        return nil
    }

    // MARK: - Texte

    private func title(for risk: HeatRiskLevel, name: String, isTransition: Bool) -> String {
        switch risk {
        case .elevated:
            return isTransition ? "\(name) ist läufig" : "\(name) — Läufigkeit"
        case .critical:
            return isTransition ? "\(name) — kritische Tage beginnen" : "\(name) — kritische Tage"
        case .subsiding:
            return "\(name) — kritische Tage klingen ab"
        }
    }

    private func body(
        for risk: HeatRiskLevel,
        dayInCycle: Int,
        isTransition: Bool,
        hasObservations: Bool,
        criticalEnd: Int,
        hasRecordedEnd: Bool
    ) -> String {
        let day = "Tag \(dayInCycle)"

        switch risk {
        case .elevated:
            // Ab dem Tag, an dem der Östrus frühestens beginnen kann, darf hier
            // kein „geht noch nicht" mehr stehen. Der Proöstrus dauert
            // mindestens `proestrusMinDays` Tage, also ist ab dem Tag danach
            // eine Deckung möglich — selten, aber möglich. Die Stufe bleibt
            // trotzdem `.elevated`: sonst wäre praktisch die ganze Läufigkeit
            // kritisch und die Abstufung wertlos. Also bleibt die Stufe, und der
            // Text hört auf, mehr zu versprechen, als er halten kann.
            if dayInCycle > StudyConstants.proestrusMinDays {
                var text = "\(day). Rüden zeigen Interesse. Eine Deckung ist jetzt unwahrscheinlich, "
                    + "aber nicht ausgeschlossen — der Östrus kann frühestens an Tag "
                    + "\(StudyConstants.proestrusMinDays + 1) beginnen. Nicht unbeaufsichtigt laufen lassen."
                if !hasObservations {
                    text += " Duldung oder Flagging zu prüfen macht die Einschätzung deutlich genauer."
                }
                return text
            }
            return "\(day). Rüden zeigen Interesse, gedeckt werden kann sie noch nicht — unbeaufsichtigt trotzdem nicht laufen lassen."

        case .critical:
            var text = isTransition
                ? "\(day). Ab jetzt ist eine Deckung möglich: an der Leine führen, Rüden konsequent fernhalten."
                : "\(day). Deckung möglich — an der Leine führen, Rüden fernhalten."
            if !hasObservations {
                // Ohne eigene Beobachtungen steht hier ein Populationswert. Das
                // gehört in die Meldung, nicht in eine Fußnote, die keiner liest.
                text += " Geschätzt aus Erfahrungswerten — Beobachtungen erfassen macht die Einschätzung genauer."
            }
            if !hasRecordedEnd, dayInCycle >= criticalEnd - 2 {
                text += " Ist die Hitze vorbei? Dann das Ende erfassen, dann verstummt die Erinnerung."
            }
            return text

        case .subsiding:
            return "\(day). Die Duldung klingt ab, ein Restrisiko bleibt noch wenige Tage. Danach ist der kritische Zeitraum vorbei."
        }
    }
}
