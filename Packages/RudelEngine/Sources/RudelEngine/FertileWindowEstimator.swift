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
        fatalError("unimplemented")
    }
}
