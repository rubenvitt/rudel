import Foundation

/// Bestimmt die aktuelle Zyklusphase (PRD §6.2).
///
/// ## Rangfolge der Evidenz
///
/// Beobachtungen schlagen den Kalender. Die Reihenfolge, in der Signale
/// ausgewertet werden:
///
/// 1. **Klinisch** (`progesteroneNgPerMl`, `cornificationPercent`) →
///    `.clinicalSignals`, `Confidence.high`.
///    Progesteron > `progesteroneOvulationThresholdNgPerMl` ⇒ Östrus/Diöstrus-
///    Übergang; Kornifizierung > 80 % ⇒ Östrus.
/// 2. **Eigene Beobachtungen** → `.observedSignals`, `Confidence.moderate`
///    bis `.high` je nach Eindeutigkeit:
///    - `standingHeat == true` ⇒ Östrus (eindeutigstes nicht-klinisches Signal)
///    - blutiger Ausfluss + `swollenFirm` ⇒ Proöstrus
///    - strohfarben/rosa + `swollenSoft`/`softening` ⇒ Östrus
///    - kein Ausfluss + `normal` nach vorherigem Östrus ⇒ Diöstrus
/// 3. **Populations-Default** → `.populationDefault`, `Confidence.low`:
///    Tag im Zyklus gegen die typischen Phasendauern aus `StudyConstants`.
///
/// Leere Signal-Einträge (`PhaseSignals.isEmpty`) werden ignoriert — ein Tag
/// ohne Eintrag ist „nicht dokumentiert", nicht „keine Anzeichen".
public struct CyclePhaseEstimator: Sendable {
    public let dayMath: DayMath

    public init(dayMath: DayMath = .utc) {
        self.dayMath = dayMath
    }

    /// Schätzt die Phase zum Zeitpunkt `asOf`.
    ///
    /// - Parameters:
    ///   - day1: Tag-1-Anker des laufenden bzw. letzten Zyklus.
    ///   - signals: alle Beobachtungen dieses Zyklus, beliebige Reihenfolge.
    ///   - asOf: Bezugsdatum.
    /// - Returns: Phase mit Tag im Zyklus, Quelle und erwartetem Phasenende
    ///   als Spanne. Liegt `asOf` vor `day1`, wird Tag 1 als Bezug genommen und
    ///   `dayInCycle == 1` zurückgegeben (die App darf keinen negativen Tag
    ///   anzeigen).
    public func estimatePhase(day1: Date, signals: [PhaseSignals], asOf: Date) -> PhaseEstimate {
        let day = dayInCycle(day1: day1, asOf: asOf)
        let usable = usableSignals(signals, asOf: asOf)

        // Stufe 1 vor Stufe 2 vor Stufe 3 — unabhängig davon, welcher Eintrag der
        // jüngere ist: ein Laborwert von vorgestern schlägt eine Verhaltens-
        // beobachtung von heute, weil er die Phase direkt misst statt sie zu
        // erschließen.
        if let phase = clinicalPhase(in: usable, dayInCycle: day) {
            return estimate(
                phase: phase, day1: day1, dayInCycle: day, asOf: asOf,
                confidence: .high, source: .clinicalSignals
            )
        }
        if let verdict = observedPhase(in: usable) {
            return estimate(
                phase: verdict.phase, day1: day1, dayInCycle: day, asOf: asOf,
                confidence: verdict.confidence, source: .observedSignals
            )
        }
        return estimate(
            phase: phaseFromDayInCycle(day), day1: day1, dayInCycle: day, asOf: asOf,
            confidence: .low, source: .populationDefault
        )
    }

    /// Tag im Zyklus, 1-basiert: `day1` selbst ist Tag 1.
    public func dayInCycle(day1: Date, asOf: Date) -> Int {
        // Klammer bei 1: ein Bezugsdatum vor dem Anker (nachgetragener Zyklus,
        // Zeitzonensprung) darf nie Tag 0 oder einen negativen Tag ergeben.
        max(1, dayMath.days(from: day1, to: asOf) + 1)
    }

    /// Ableitung der Phase allein aus dem Tag im Zyklus, über die
    /// Populations-Defaults. Fallback, wenn keine Signale vorliegen.
    public func phaseFromDayInCycle(_ day: Int) -> CyclePhase {
        // Kumulierte Grenzen, nicht Einzeldauern: Tag 10 ist der erste
        // Östrus-Tag, weil der Proöstrus bis Tag 9 läuft. Tag <= 0 fällt
        // defensiv in den ersten Zweig.
        if day <= Self.proestrusLastDay { return .proestrus }
        if day <= Self.estrusLastDay { return .estrus }
        if day <= Self.diestrusLastDay { return .diestrus }
        return .anestrus
    }
}

// MARK: - Kumulierte Phasengrenzen

extension CyclePhaseEstimator {
    /// Letzter Proöstrus-Tag (Tag 9).
    static let proestrusLastDay = StudyConstants.proestrusTypicalDays
    /// Letzter Östrus-Tag (Tag 18).
    static let estrusLastDay = proestrusLastDay + StudyConstants.estrusTypicalDays
    /// Letzter Diöstrus-Tag (Tag 93) — danach Anöstrus.
    static let diestrusLastDay = estrusLastDay + StudyConstants.diestrusTypicalDays

    /// Tage von Tag 1 bis zum kalendarisch erwarteten *Beginn* der Phase.
    static func typicalStartOffsetDays(of phase: CyclePhase) -> Int {
        switch phase {
        case .proestrus: return 0
        case .estrus: return proestrusLastDay
        case .diestrus: return estrusLastDay
        case .anestrus: return diestrusLastDay
        }
    }

    /// Anteil kornifizierter Zellen, ab dem das Zellbild als Östrus gilt.
    ///
    /// Bewusst hier und nicht in `StudyConstants`: der Wert ist Teil der
    /// Auswerteregel im Doc-Kommentar dieses Typs (PRD §6.2), also eine
    /// Ableseschwelle der Zytologie und kein Populationswert einer Studie.
    static let cornificationEstrusThresholdPercent = 80.0
}

// MARK: - Auswertung

extension CyclePhaseEstimator {
    /// Beobachtungen, die in die Schätzung eingehen dürfen — neueste zuerst.
    ///
    /// Zwei Filter: leere Einträge fliegen raus (ein undokumentierter Tag ist
    /// keine Aussage, sonst zöge er die Phase Richtung Anöstrus), und alles nach
    /// `asOf` fliegt raus — ein nachgetragener oder in die Zukunft datierter
    /// Eintrag darf die Aussage über „heute" nicht verändern.
    func usableSignals(_ signals: [PhaseSignals], asOf: Date) -> [PhaseSignals] {
        signals
            .enumerated()
            .filter { !$0.element.isEmpty && dayMath.days(from: $0.element.date, to: asOf) >= 0 }
            // Sortiert nach dem vollen Zeitstempel, nicht nach dem Kalendertag:
            // zwei Einträge desselben Tages tragen echte Reihenfolge-Information
            // (morgens blutig, abends duldend). Der Ursprungsindex steht nur als
            // letzter Tiebreak dahinter, damit die Reihenfolge auch bei exakt
            // gleichem Zeitstempel definiert ist — die Liste kommt aus einer
            // SwiftData-Relation und ist von dort aus unsortiert.
            .sorted { lhs, rhs in
                if lhs.element.date != rhs.element.date {
                    return lhs.element.date > rhs.element.date
                }
                return lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    /// Stufe 1: der jüngste Eintrag mit Labor- oder Zytologiewert, der überhaupt
    /// eine Phase benennt.
    ///
    /// `nil` heißt „kein klinischer Wert, oder der Wert benennt keine Phase":
    /// ein Basalwert — Progesteron unter der LH-Schwelle, wenig kornifizierte
    /// Zellen — kommt im Proöstrus *und* im Anöstrus vor und entscheidet damit
    /// nichts. Solche Einträge blockieren Stufe 2 nicht.
    func clinicalPhase(in usable: [PhaseSignals], dayInCycle day: Int) -> CyclePhase? {
        for signal in usable {
            if let cornification = signal.cornificationPercent,
               cornification > Self.cornificationEstrusThresholdPercent {
                return .estrus
            }
            guard let progesterone = signal.progesteroneNgPerMl else { continue }

            // Schwellen inklusive gelesen — `StudyConstants` formuliert sie als
            // „ab, der der LH-Peak als überschritten gilt". Exklusiv gelesen
            // fiele ein Messwert genau auf der Ovulationsschwelle auf die
            // LH-Regel zurück und sprang von Diöstrus wieder nach Östrus.
            if progesterone >= StudyConstants.progesteroneOvulationThresholdNgPerMl {
                // Eisprung überschritten: möglich sind nur noch Östrus und
                // Diöstrus. Welcher von beiden, entscheidet der Kalender — die
                // klinische Evidenz verengt ihn, statt ihn zu ersetzen.
                return day <= Self.estrusLastDay ? .estrus : .diestrus
            }
            if progesterone >= StudyConstants.progesteroneLHPeakThresholdNgPerMl {
                // LH-Peak überschritten ⇒ Östrus hat begonnen, auch wenn der
                // Kalender noch Proöstrus erwartet.
                return .estrus
            }
        }
        return nil
    }

    struct ObservedVerdict: Equatable {
        var phase: CyclePhase
        var confidence: Confidence
    }

    /// Stufe 2: der jüngste Eintrag, dessen Beobachtungen eine Phase benennen.
    func observedPhase(in usable: [PhaseSignals]) -> ObservedVerdict? {
        for signal in usable {
            // Duldung ist das eindeutigste nicht-klinische Signal und schlägt
            // jede Ausfluss-/Turgor-Kombination desselben Eintrags.
            if signal.standingHeat == true {
                return ObservedVerdict(phase: .estrus, confidence: .high)
            }
            if let phase = phaseFromDischargeAndTurgor(signal, in: usable) {
                return ObservedVerdict(phase: phase, confidence: .moderate)
            }
            if signal.pseudopregnancySigns == true {
                // Scheinträchtigkeit ist ein Diöstrus-Phänomen: sie tritt im
                // Nachlauf der Gelbkörperphase auf.
                return ObservedVerdict(phase: .diestrus, confidence: .moderate)
            }
            if signal.flagging == true {
                return ObservedVerdict(phase: .estrus, confidence: .moderate)
            }
            // `attractsMales` bleibt bewusst ohne Regel: Rüden reagieren schon
            // im Proöstrus, das Signal trennt die beiden Phasen nicht.
            // `standingHeat == false` ebenso — nicht zu dulden heißt „noch
            // nicht" oder „nicht mehr", je nach Tag, und benennt keine Phase.
        }
        return nil
    }

    /// Die Ausfluss-/Turgor-Regeln der Rangfolge, in absteigender Eindeutigkeit.
    /// `nil`, wenn die Kombination keine Phase festlegt.
    private func phaseFromDischargeAndTurgor(
        _ signal: PhaseSignals,
        in usable: [PhaseSignals]
    ) -> CyclePhase? {
        let bloodyish = signal.dischargeColor == .bloody || signal.dischargeColor == .brownish
        let estrusColor = signal.dischargeColor == .strawColored || signal.dischargeColor == .pinkish
        let firm = signal.vulvaTurgor == .swollenFirm
        let yielding = signal.vulvaTurgor == .swollenSoft || signal.vulvaTurgor == .softening

        if bloodyish && firm { return .proestrus }
        if estrusColor && yielding { return .estrus }
        if signal.dischargePresent == false && signal.vulvaTurgor == .normal {
            // „Nach vorherigem Östrus": ohne belegten Östrus ist ein ruhiger
            // Befund genauso gut Anöstrus oder ein Tag vor der Läufigkeit — dann
            // lieber keine Aussage als eine falsche.
            return hasEstrusEvidence(before: signal.date, in: usable) ? .diestrus : nil
        }
        // Einzelsignal ohne Partner, und nur wenn der Turgor gar nicht
        // dokumentiert ist: PRD §2 verlangt, dass zwei Taps reichen. `brownish`
        // fehlt hier absichtlich — älteres Blut kommt im späten Proöstrus wie im
        // frühen Diöstrus vor und wäre allein nicht eindeutig.
        guard signal.vulvaTurgor == nil else { return nil }
        if signal.dischargeColor == .bloody { return .proestrus }
        if estrusColor { return .estrus }
        return nil
    }

    /// Gab es vor `date` einen Hinweis auf Östrus? Nur die Diöstrus-Regel braucht
    /// das, weil sie einen abgeschlossenen Östrus voraussetzt.
    private func hasEstrusEvidence(before date: Date, in usable: [PhaseSignals]) -> Bool {
        let cutoff = dayMath.startOfDay(date)
        return usable.contains { earlier in
            dayMath.startOfDay(earlier.date) < cutoff && Self.indicatesEstrus(earlier)
        }
    }

    /// Zeigt dieser Eintrag Östrus an? Absichtlich eine flache Prüfung ohne
    /// Rangfolge — sie beantwortet nur „war schon mal Östrus", nicht „welche
    /// Phase ist jetzt".
    private static func indicatesEstrus(_ signal: PhaseSignals) -> Bool {
        if signal.standingHeat == true || signal.flagging == true { return true }
        if let cornification = signal.cornificationPercent,
           cornification > cornificationEstrusThresholdPercent {
            return true
        }
        if let progesterone = signal.progesteroneNgPerMl,
           progesterone >= StudyConstants.progesteroneLHPeakThresholdNgPerMl {
            return true
        }
        let estrusColor = signal.dischargeColor == .strawColored || signal.dischargeColor == .pinkish
        let yielding = signal.vulvaTurgor == .swollenSoft || signal.vulvaTurgor == .softening
        return estrusColor && (yielding || signal.vulvaTurgor == nil)
    }
}

// MARK: - Phasenende

extension CyclePhaseEstimator {
    func estimate(
        phase: CyclePhase,
        day1: Date,
        dayInCycle day: Int,
        asOf: Date,
        confidence: Confidence,
        source: PhaseEstimateSource
    ) -> PhaseEstimate {
        PhaseEstimate(
            phase: phase,
            dayInCycle: day,
            confidence: confidence,
            source: source,
            expectedPhaseEnd: expectedPhaseEnd(phase: phase, day1: day1, asOf: asOf)
        )
    }

    /// Erwartetes Phasenende als Spanne, aus `durationRangeDays` der Phase.
    ///
    /// Der Phasenbeginn ist kalendarisch angesetzt, aber nach oben durch „heute"
    /// begrenzt: belegen Beobachtungen die Phase früher, als der Kalender sie
    /// erwartet, hat sie spätestens heute begonnen. Beide Grenzen werden
    /// zusätzlich auf „nicht vor heute" gezogen — ein Phasenende in der
    /// Vergangenheit wäre für die UI unbrauchbar; bei überlangen Phasen bleibt
    /// die Aussage „kann heute enden".
    func expectedPhaseEnd(phase: CyclePhase, day1: Date, asOf: Date) -> ClosedRange<Date> {
        let today = dayMath.startOfDay(asOf)
        let calendarStart = dayMath.adding(days: Self.typicalStartOffsetDays(of: phase), to: day1)
        let start = min(calendarStart, today)
        let duration = phase.durationRangeDays
        // −1, weil der Starttag selbst schon der erste Tag der Phase ist.
        let earliest = max(dayMath.adding(days: duration.lowerBound - 1, to: start), today)
        let latest = max(dayMath.adding(days: duration.upperBound - 1, to: start), earliest)
        return earliest...latest
    }
}
