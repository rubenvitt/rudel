import Foundation

/// Grobe Schätzung des fruchtbaren Fensters (PRD §6.3).
///
/// **Bewusst schwach.** Die PRD führt das Feature als „optional/informativ".
/// Ohne Progesteronverlauf lässt sich der Eisprung nicht bestimmen; jede
/// Schätzung aus Verhalten allein hat eine Unsicherheit von mehreren Tagen.
/// Deshalb liefert jede Rückgabe ein `caveat`, das die UI zwingend anzeigt.
///
/// ## Ableitung, nach Belastbarkeit
///
/// 1. **Progesteron** (`.clinicalSignals`, `Confidence.high`): erster Messwert
///    ≥ `progesteroneLHPeakThresholdNgPerMl` markiert den LH-Peak; Eisprung
///    `ovulationDaysAfterLHPeak` später, optimaler Zeitpunkt
///    `optimalBreedingDaysAfterOvulation` nach dem Eisprung.
/// 2. **Standhitze** (`.observedSignals`, `Confidence.moderate`): erster Tag mit
///    `standingHeat == true` + `ovulationDaysAfterStandingHeatStart` als
///    Eisprung-Näherung.
/// 3. **Nur Tag im Zyklus** (`.populationDefault`, `Confidence.low`): Östrus
///    beginnt typisch an Tag `proestrusTypicalDays + 1`.
///
/// Das Fenster ist bei niedriger Konfidenz breiter — es ist ein Hinweis,
/// wohin zu schauen ist, keine Terminempfehlung.
public struct FertileWindowEstimator: Sendable {
    public let dayMath: DayMath

    /// Text, den die UI bei jeder Anzeige mitführen muss.
    public static let progesteroneCaveat =
        "Aus Progesteronwerten geschätzt. Für eine Deckplanung den Verlauf tierärztlich begleiten lassen."
    public static let behaviourCaveat =
        "Nur aus dem Verhalten geschätzt — mehrere Tage Unsicherheit. Zuverlässig ist allein ein Progesterontest."
    public static let populationCaveat =
        "Reiner Populationswert ohne eigene Beobachtungen. Nicht für eine Deckplanung geeignet — dafür ist ein Progesterontest nötig."

    public init(dayMath: DayMath = .utc) {
        self.dayMath = dayMath
    }

    /// Schätzt das fruchtbare Fenster des Zyklus mit dem Anker `day1`.
    ///
    /// - Returns: `nil`, wenn `asOf` außerhalb des plausiblen Zyklusfensters
    ///   liegt (Tag > `proestrusMaxDays + estrusMaxDays`) — dann ist der Östrus
    ///   vorbei und ein fruchtbares Fenster zu zeigen wäre irreführend.
    public func estimate(day1: Date, signals: [PhaseSignals], asOf: Date) -> FertileWindowEstimate? {
        let anchor = dayMath.startOfDay(day1)

        // Tag 1 ist der Anker selbst. Liegt `asOf` davor, wird Tag 1 als Bezug
        // genommen — die App darf keinen negativen Zyklustag anzeigen, und ein
        // Blick nach vorn auf das kommende Fenster ist legitim.
        let dayInCycle = max(1, dayMath.days(from: anchor, to: asOf) + 1)

        // Nach dem Maximum aus Proöstrus und Östrus ist der Östrus in jedem Fall
        // vorbei. Dann noch ein fruchtbares Fenster zu zeigen wäre nicht
        // informativ, sondern irreführend.
        let lastPlausibleDay = StudyConstants.proestrusMaxDays + StudyConstants.estrusMaxDays
        guard dayInCycle <= lastPlausibleDay else { return nil }

        // Nur Beobachtungen aus diesem Zyklus. Die untere Schranke verhindert,
        // dass ein Wert des vorherigen Zyklus diesen ankert; die obere, dass ein
        // Progesteronwert aus dem Diöstrus — dort über Wochen hoch — als LH-Peak
        // dieses Zyklus gelesen wird.
        let horizon = dayMath.adding(days: lastPlausibleDay - 1, to: anchor)
        let inCycle = signals.filter { signal in
            let day = dayMath.startOfDay(signal.date)
            return day >= anchor && day <= horizon
        }

        // 1. Progesteron. Der *erste* Wert über der Schwelle markiert den Peak:
        //    spätere, höhere Werte liegen schon dahinter und würden das Fenster
        //    nach hinten verschieben. `min()` statt Sortieren, damit mehrere
        //    Messungen am selben Tag zum selben Ergebnis führen.
        let lhPeak = inCycle.compactMap { signal -> Date? in
            guard let value = signal.progesteroneNgPerMl,
                  value >= StudyConstants.progesteroneLHPeakThresholdNgPerMl
            else { return nil }
            return dayMath.startOfDay(signal.date)
        }.min()

        if let lhPeak {
            return makeEstimate(
                ovulation: dayMath.adding(days: StudyConstants.ovulationDaysAfterLHPeak, to: lhPeak),
                confidence: .high,
                source: .clinicalSignals,
                caveat: Self.progesteroneCaveat
            )
        }

        // 2. Standhitze. Das eindeutigste nicht-klinische Signal, aber ihr
        //    Beginn ist selbst schon eine unscharfe Beobachtung.
        let standingHeatStart = inCycle.compactMap { signal -> Date? in
            signal.standingHeat == true ? dayMath.startOfDay(signal.date) : nil
        }.min()

        if let standingHeatStart {
            return makeEstimate(
                ovulation: dayMath.adding(
                    days: StudyConstants.ovulationDaysAfterStandingHeatStart,
                    to: standingHeatStart
                ),
                confidence: .moderate,
                source: .observedSignals,
                caveat: Self.behaviourCaveat
            )
        }

        // 3. Nur der Tag im Zyklus. Östrus beginnt typisch am Tag nach dem
        //    Proöstrus-Median; der Eisprung fällt laut Literatur auf die ersten
        //    Tage des Östrus, weshalb hier derselbe Abstand gilt wie ab Beginn
        //    der Standhitze.
        let estrusStart = dayMath.adding(days: StudyConstants.proestrusTypicalDays, to: anchor)
        return makeEstimate(
            ovulation: dayMath.adding(
                days: StudyConstants.ovulationDaysAfterStandingHeatStart,
                to: estrusStart
            ),
            confidence: .low,
            source: .populationDefault,
            caveat: Self.populationCaveat
        )
    }

    /// Baut die Rückgabe aus einem geschätzten Eisprung. Der optimale
    /// Deckzeitpunkt liegt `optimalBreedingDaysAfterOvulation` dahinter und ist
    /// per Konstruktion die Mitte von `window` — die UI darf sich darauf
    /// verlassen, dass `window` `optimalDate` enthält.
    private func makeEstimate(
        ovulation: Date,
        confidence: Confidence,
        source: PhaseEstimateSource,
        caveat: String
    ) -> FertileWindowEstimate {
        let optimal = dayMath.adding(
            days: StudyConstants.optimalBreedingDaysAfterOvulation,
            to: ovulation
        )
        let halfWidth = Self.windowHalfWidthDays(for: confidence)
        let start = dayMath.adding(days: -halfWidth, to: optimal)
        let end = dayMath.adding(days: halfWidth, to: optimal)

        return FertileWindowEstimate(
            window: start...end,
            optimalDate: optimal,
            confidence: confidence,
            source: source,
            caveat: caveat
        )
    }

    /// Halbe Fensterbreite in Tagen. Wächst mit sinkender Konfidenz: eine dünne
    /// Datenlage darf sich nicht als schmales Fenster tarnen, sonst liest der
    /// Nutzer eine Terminempfehlung, wo nur ein Hinweis steht (PRD §6.3).
    private static func windowHalfWidthDays(for confidence: Confidence) -> Int {
        switch confidence {
        case .high: return 1      // Progesteronverlauf — Eisprung tagesgenau eingegrenzt
        case .moderate: return 3  // Standhitze — Beginn selbst auf ein paar Tage unscharf
        case .low: return 5       // reiner Populationswert — deckt den typischen Östrus ab
        }
    }
}
