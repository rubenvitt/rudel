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
        fatalError("unimplemented")
    }

    /// Tag im Zyklus, 1-basiert: `day1` selbst ist Tag 1.
    public func dayInCycle(day1: Date, asOf: Date) -> Int {
        fatalError("unimplemented")
    }

    /// Ableitung der Phase allein aus dem Tag im Zyklus, über die
    /// Populations-Defaults. Fallback, wenn keine Signale vorliegen.
    public func phaseFromDayInCycle(_ day: Int) -> CyclePhase {
        fatalError("unimplemented")
    }
}
