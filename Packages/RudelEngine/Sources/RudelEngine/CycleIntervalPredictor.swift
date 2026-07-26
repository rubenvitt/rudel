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
        fatalError("unimplemented")
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
        fatalError("unimplemented")
    }
}
