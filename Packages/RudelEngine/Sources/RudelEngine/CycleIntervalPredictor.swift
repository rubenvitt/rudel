import Foundation

/// Prognostiziert die nächste Läufigkeit aus den geloggten Tag-1-Ankern (PRD §6.1).
///
/// ## Rechenmodell
///
/// Punktschätzer per **Shrinkage** gegen den Populationswert:
/// ```
/// w  = n / (n + k)                       k = StudyConstants.shrinkagePriorWeight
/// μ̂  = w · μ_eigen + (1 − w) · μ_pop     μ_pop inkl. Größenklassen-Bias
/// ```
/// Damit gibt es keine Sprungstelle: die Prognose wandert mit jedem
/// geloggten Intervall stetig von der Population zu den eigenen Daten,
/// statt bei einem willkürlichen Schwellwert umzuschalten.
///
/// Das Band folgt der **Unsicherheit über den Mittelwert**, nicht der rohen
/// Streuung, und wird nach oben von der Populationsspanne begrenzt: mehr
/// Unsicherheit als „wir wissen nichts über dieses Tier" kann durch das
/// Hinzufügen von Daten nicht entstehen.
///
/// ## Invarianten (als Tests festgeschrieben)
///
/// 1. `bandHalfWidthDays >= StudyConstants.intervalBandFloorDays` — bei *jedem* n.
///    Insbesondere bei genau einem Intervall, wo die Stichproben-SD 0 ist.
/// 2. `range` enthält `expectedDate` immer.
/// 3. Bei ≥ 1 Intervall ist das Band nie breiter als die Populationsspanne.
/// 4. Bei konstanten eigenen Intervallen verengt sich das Band monoton mit n.
///    (Bei *variablen* Intervallen darf es breiter werden — ein unregelmäßiger
///    Zyklus soll ehrlich als unsicher dargestellt werden, nicht künstlich
///    verengt.)
/// 5. `confidence == Confidence(ownIntervalCount:)` — Konfidenz hängt an der
///    Zahl der **Intervalle**, nicht der Anker.
public struct CycleIntervalPredictor: Sendable {
    public let dayMath: DayMath

    public init(dayMath: DayMath = .utc) {
        self.dayMath = dayMath
    }

    /// Die eigenen Intervalle in Tagen, aus aufeinanderfolgenden Ankern.
    ///
    /// Sortiert die Anker selbst, normalisiert auf Kalendertage und wirft
    /// Duplikate (mehrfach geloggter gleicher Tag) heraus. `n` Anker ergeben
    /// `n − 1` Intervalle; bei ≤ 1 Anker ist das Ergebnis leer.
    public func intervals(from anchors: [Date]) -> [Int] {
        // Auf Mitternacht normalisieren, *dann* sortieren: die Anker kommen aus
        // der UI mit beliebiger Uhrzeit, und ohne Normalisierung würden zwei
        // Einträge desselben Tages als zwei Anker mit Intervall 0 durchgehen.
        let days = Set(anchors.map(dayMath.startOfDay)).sorted()
        guard days.count > 1 else { return [] }

        return zip(days, days.dropFirst()).map { dayMath.days(from: $0, to: $1) }
    }

    /// Prognose der nächsten Läufigkeit.
    ///
    /// - Parameters:
    ///   - history: geloggte Tag-1-Anker plus Größenklasse.
    ///   - asOf: Bezugsdatum („heute"). Beeinflusst die Prognose nicht — der
    ///     Anker ist immer der *letzte* geloggte Tag 1 — dient aber dazu, eine
    ///     bereits überschrittene Prognose als solche erkennbar zu halten.
    /// - Returns: `nil`, wenn kein einziger Anker vorliegt. Ohne Anker gibt es
    ///   keinen Referenzpunkt, und eine Prognose „irgendwann in den nächsten
    ///   10 Monaten" wäre wertlos — die UI zeigt dann die Aufforderung, Tag 1
    ///   zu erfassen.
    public func predictNextCycle(history: CycleHistory, asOf: Date) -> CyclePrediction? {
        // `asOf` geht bewusst nicht in die Rechnung ein: der Bezugspunkt ist immer
        // der letzte geloggte Tag 1. Eine Prognose, die in der Vergangenheit liegt,
        // bleibt deshalb in der Vergangenheit — die UI soll „seit X Tagen fällig"
        // zeigen können und nicht eine stillschweigend nachgeschobene Prognose.
        guard let lastAnchor = history.day1Anchors.map(dayMath.startOfDay).max() else {
            return nil
        }

        let observed = intervals(from: history.day1Anchors)
        let n = observed.count
        let weight = Double(n) / (Double(n) + StudyConstants.shrinkagePriorWeight)

        let populationMean = Double(
            StudyConstants.day1ToDay1IntervalDays
                + StudyConstants.intervalBiasDays(for: history.sizeClass)
        )
        let ownMean = n > 0
            ? observed.reduce(0.0) { $0 + Double($1) } / Double(n)
            : populationMean
        let effectiveInterval = weight * ownMean + (1 - weight) * populationMean

        let expectedDate = dayMath.adding(
            days: Int(effectiveInterval.rounded()),
            to: lastAnchor
        )

        let halfWidth = bandHalfWidth(observed: observed, weight: weight)
        let range = band(
            halfWidthDays: halfWidth,
            around: expectedDate,
            anchor: lastAnchor,
            hasOwnIntervals: n > 0
        )

        return CyclePrediction(
            expectedDate: expectedDate,
            range: range,
            confidence: Confidence(ownIntervalCount: n),
            basis: n > 0 ? .blended(ownIntervalCount: n) : .population,
            observedIntervalDays: observed,
            effectiveIntervalDays: effectiveInterval,
            bandHalfWidthDays: halfWidth
        )
    }

    // MARK: - Bandbreite

    /// Halbe Breite der Populationsspanne (135–300 d ⇒ 82,5 d). Obergrenze für
    /// jedes Band ab einem eigenen Intervall: durch Datenzugewinn kann nicht
    /// mehr Unsicherheit entstehen als „wir wissen nichts über dieses Tier".
    private static let populationBandHalfWidthDays = Double(
        StudyConstants.day1ToDay1IntervalMaxDays - StudyConstants.day1ToDay1IntervalMinDays
    ) / 2

    /// Halbe Bandbreite in Tagen — Unsicherheit über den **Mittelwert**, nicht
    /// die rohe Streuung. Deshalb `SD / √n` und nicht `SD`: mit jedem Intervall
    /// wird der Schätzer präziser, auch wenn der Zyklus selbst gleich unruhig
    /// bleibt.
    private func bandHalfWidth(observed: [Int], weight: Double) -> Double {
        let n = observed.count
        guard n > 0 else { return Self.populationBandHalfWidthDays }

        // Bei genau einem Intervall trägt die Stichprobe *keine* Information über
        // Streuung — ihre SD ist nicht 0, sondern undefiniert. Würde man 0
        // einsetzen, kollabierte das Band auf die UX-Schranke, genau dort, wo die
        // App am wenigsten weiß (PRD §6.1, Design-Doc §4.2). Also springt die
        // Populations-SD vollständig ein.
        let effectiveSD: Double
        if n == 1 {
            effectiveSD = StudyConstants.day1ToDay1IntervalPopulationSDDays
        } else {
            effectiveSD = weight * sampleSD(observed)
                + (1 - weight) * StudyConstants.day1ToDay1IntervalPopulationSDDays
        }

        let standardError = effectiveSD / Double(n).squareRoot()
        return min(
            max(standardError, StudyConstants.intervalBandFloorDays),
            Self.populationBandHalfWidthDays
        )
    }

    /// Stichproben-SD mit Bessel-Korrektur (n − 1). Nur für n ≥ 2 sinnvoll.
    private func sampleSD(_ values: [Int]) -> Double {
        guard values.count > 1 else { return 0 }
        let samples = values.map(Double.init)
        let mean = samples.reduce(0, +) / Double(samples.count)
        let sumOfSquares = samples.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumOfSquares / Double(samples.count - 1)).squareRoot()
    }

    /// Das Band als Datumsspanne.
    ///
    /// Ohne eigene Intervalle ist es die publizierte Populationsspanne relativ
    /// zum Anker — und damit bewusst **asymmetrisch** um `expectedDate`, weil
    /// 210 d nicht die Mitte von 135–300 d ist. Die Literatur gibt die Spanne
    /// vor, nicht wir; sie glattzuziehen wäre eine Erfindung.
    ///
    /// Ab einem eigenen Intervall ist das Band symmetrisch um den Punktschätzer.
    /// Die Tagesgrenzen werden **abgerundet**, damit die Breite in Kalendertagen
    /// die Populationsspanne nicht durch Rundung überschreitet.
    private func band(
        halfWidthDays: Double,
        around expectedDate: Date,
        anchor: Date,
        hasOwnIntervals: Bool
    ) -> ClosedRange<Date> {
        guard hasOwnIntervals else {
            return dayMath.adding(days: StudyConstants.day1ToDay1IntervalMinDays, to: anchor)
                ... dayMath.adding(days: StudyConstants.day1ToDay1IntervalMaxDays, to: anchor)
        }

        let offset = Int(halfWidthDays.rounded(.down))
        return dayMath.adding(days: -offset, to: expectedDate)
            ... dayMath.adding(days: offset, to: expectedDate)
    }
}
