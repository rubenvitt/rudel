import Foundation

/// Populationswerte aus der Literatur. Sie sind **Startwerte**, keine Wahrheit:
/// sobald eigene Zyklen geloggt sind, verschiebt `CycleIntervalPredictor`
/// die Schätzung Richtung der individuellen Daten (PRD §6).
///
/// Quellen:
/// - Concannon, P.W. (2011): *Reproductive cycles of the domestic bitch.*
///   Animal Reproduction Science 124(3–4), 200–210.
/// - Cornell University College of Veterinary Medicine – Dog estrous cycles.
/// - UC Davis School of Veterinary Medicine – Breeding Management of the Bitch.
/// - dvm360 – Canine estrous cycle and ovulation.
public enum StudyConstants {

    // MARK: - Zyklusintervall

    /// Abstand von Tag 1 einer Läufigkeit bis Tag 1 der nächsten, in Tagen.
    ///
    /// **Bewusst so benannt, nicht „Interöstrus-Intervall".** Die Literatur benutzt
    /// „interestrous interval" uneinheitlich: teils Tag-1→Tag-1, teils Ende Östrus →
    /// Beginn nächster Proöstrus. Die beiden Größen unterscheiden sich um die
    /// Proöstrus+Östrus-Dauer (~18 Tage) — genug, um eine Prognose um Wochen zu
    /// verschieben. Der Name beschreibt deshalb, was die App tatsächlich messen
    /// kann: den Abstand zweier beobachteter Tag-1-Anker.
    ///
    /// 210 d ≈ 7 Monate (Concannon 2011: mittleres Intervall ~7 Monate).
    /// Die in Ratgebern verbreitete „alle 6 Monate"-Faustregel wird absichtlich
    /// *nicht* zur Berechnung verwendet — sie ist der Median populärer Darstellung,
    /// nicht der publizierte Mittelwert.
    public static let day1ToDay1IntervalDays = 210

    /// Untere Grenze der Populationsspanne (~4,5 Monate).
    public static let day1ToDay1IntervalMinDays = 135

    /// Obere Grenze der Populationsspanne (~10 Monate).
    public static let day1ToDay1IntervalMaxDays = 300

    /// Streuung des Intervalls in der Population, in Tagen.
    ///
    /// Abgeleitet aus der Spanne 135–300 d unter Normalverteilungsannahme
    /// (Spanne ≈ ±2 SD um den Mittelwert ⇒ SD ≈ (300−135)/4 ≈ 41).
    /// Näherung, weil die Primärquellen die Spanne, nicht die SD berichten.
    public static let day1ToDay1IntervalPopulationSDDays = 41.0

    /// Untere Schranke für die halbe Breite des Konfidenzbandes, in Tagen.
    ///
    /// **UX-Schranke gegen Scheingenauigkeit, kein biologischer Befund** (PRD §6:
    /// „Prognosen stets als Spanne […] nie als Scheingenauigkeit"). Auch bei
    /// perfekt regelmäßigen geloggten Zyklen bleibt der Beginn der Läufigkeit
    /// auf ±1 Woche unscharf, weil bereits der Tag-1-Anker selbst eine
    /// Beobachtung mit Unsicherheit ist.
    public static let intervalBandFloorDays = 7.0

    /// Shrinkage-Gewicht: Anzahl „virtueller" Populationsbeobachtungen, gegen
    /// die eigene Messungen aufgewogen werden. Bei `k = 2` zählt das erste eigene
    /// Intervall 1/3, bei vier eigenen Intervallen bereits 2/3.
    /// Wert gewählt, damit ab 2–3 eigenen Zyklen die eigenen Daten dominieren
    /// (PRD §6: „Ab 2–3 eigenen Zyklen rechnet die App mit den individuell
    /// geloggten Intervallen").
    public static let shrinkagePriorWeight = 2.0

    // MARK: - Zyklusphasen (Tage ab Tag 1)

    /// Proöstrus: ~9 d (Spanne 3–17).
    public static let proestrusTypicalDays = 9
    public static let proestrusMinDays = 3
    public static let proestrusMaxDays = 17

    /// Östrus: ~9 d (Spanne 3–21).
    public static let estrusTypicalDays = 9
    public static let estrusMinDays = 3
    public static let estrusMaxDays = 21

    /// Diöstrus (nicht tragend): 60–90 d, typisch 75.
    public static let diestrusTypicalDays = 75
    public static let diestrusMinDays = 60
    public static let diestrusMaxDays = 90

    /// Anöstrus: ~120 d (Spanne 60–200).
    public static let anestrusTypicalDays = 120
    public static let anestrusMinDays = 60
    public static let anestrusMaxDays = 200

    // MARK: - Fruchtbares Fenster

    /// Bester Deckzeitpunkt: ~2 Tage nach Eisprung.
    public static let optimalBreedingDaysAfterOvulation = 2

    /// Eisprung: ~2 Tage nach LH-Peak; bester Deckzeitpunkt damit ~4 d nach LH-Peak.
    public static let ovulationDaysAfterLHPeak = 2

    /// Ohne Progesterontest ist der Eisprung nur grob über den Beginn der
    /// Standhitze schätzbar: Eisprung fällt typisch auf die ersten Tage des
    /// Östrus. Reine Orientierung — die UI muss darauf hinweisen, dass allein
    /// ein Progesterontest belastbar ist (PRD §6.3).
    public static let ovulationDaysAfterStandingHeatStart = 2

    /// Progesteron-Schwelle (ng/ml), ab der der LH-Peak als überschritten gilt.
    /// Grobe klinische Orientierung (UC Davis): ~2–3 ng/ml um den LH-Peak,
    /// ~5–8 ng/ml um den Eisprung.
    public static let progesteroneLHPeakThresholdNgPerMl = 2.5
    public static let progesteroneOvulationThresholdNgPerMl = 6.0

    // MARK: - Größenklassen-Bias

    /// Verschiebung des erwarteten Intervalls je Größenklasse, in Tagen.
    ///
    /// **Heuristik, kein publizierter Punktwert.** UC Davis beschreibt, dass große
    /// Rassen ans obere Ende der Intervallspanne tendieren, ohne Werte je
    /// Größenklasse zu nennen. Die Verschiebung ist deshalb bewusst klein
    /// gegenüber der Populations-SD (41 d) gehalten und wird von eigenen
    /// geloggten Intervallen schnell überstimmt.
    public static func intervalBiasDays(for sizeClass: DogSizeClass) -> Int {
        switch sizeClass {
        case .small: return -15
        case .medium: return 0
        case .large: return 15
        case .giant: return 30
        }
    }
}
