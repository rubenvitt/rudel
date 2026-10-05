import Foundation

/// Welche Impfung ein Plan der Art `.vaccination` dokumentiert.
///
/// Tollwut steht bewusst **nicht** hier: sie bleibt die eigene Art
/// `MedicationKind.rabiesVaccination`, damit Bestandspläne ohne Migration
/// weiterlaufen. Die Oberfläche bietet sie trotzdem als erste Impfung an.
///
/// Die Rohwerte sind persistiert und dürfen sich nicht ändern.
public enum VaccineType: String, Sendable, Codable, CaseIterable, Hashable {
    // Hund
    case distemperHepatitisParvo
    case dogCombination
    case leptospirosis
    case kennelCough
    case lymeDisease
    case leishmaniasis
    // Katze
    case panleukopenia
    case catFlu
    case catCombination
    case felineLeukemia
    /// Freitext im Produktnamen des Plans.
    case other

    /// Deutscher Anzeigename. In der Engine, weil Dashboard-Titel und
    /// Mitteilungen ihn brauchen.
    public var displayName: String {
        switch self {
        case .distemperHepatitisParvo: return "Staupe, Hepatitis, Parvovirose (SHP)"
        case .dogCombination: return "Kombiimpfung SHPPi + L"
        case .leptospirosis: return "Leptospirose"
        case .kennelCough: return "Zwingerhusten (Parainfluenza)"
        case .lymeDisease: return "Borreliose"
        case .leishmaniasis: return "Leishmaniose"
        case .panleukopenia: return "Katzenseuche (Panleukopenie)"
        case .catFlu: return "Katzenschnupfen"
        case .catCombination: return "Kombiimpfung RCP"
        case .felineLeukemia: return "Leukose (FeLV)"
        case .other: return "Andere Impfung"
        }
    }

    /// Für welche Tierarten die Impfung angeboten wird. `.other` für alle.
    public var species: Set<Species> {
        switch self {
        case .distemperHepatitisParvo, .dogCombination, .leptospirosis, .kennelCough,
             .lymeDisease, .leishmaniasis:
            return [.dog]
        case .panleukopenia, .catFlu, .catCombination, .felineLeukemia:
            return [.cat]
        case .other:
            return Set(Species.allCases)
        }
    }

    public func applies(to species: Species) -> Bool {
        self.species.contains(species)
    }

    /// Die angebotenen Impfungen einer Tierart in fester Reihenfolge, `.other`
    /// zuletzt.
    public static func options(for species: Species) -> [VaccineType] {
        allCases.filter { $0.applies(to: species) }
    }

    /// Standard-Gültigkeit in Tagen nach der Grundimmunisierung — nur
    /// **Vorbelegung**, maßgeblich sind Impfpass und Tierarzt.
    ///
    /// Quelle: StIKo Vet am FLI, „Leitlinie zur Impfung von Kleintieren",
    /// 6. Auflage, Stand 06.01.2025 (Empfehlungsabschnitte je Erkrankung).
    ///
    /// - Feste Empfehlung der Leitlinie → übernommen: Staupe, HCC und
    ///   Parvovirose „im Abstand von 3 Jahren"; Panleukopenie „im Abstand von
    ///   3 Jahren (oder mehr)"; Leptospirose, Parainfluenza, Bordetella,
    ///   Borreliose und Leishmaniose „jährlich".
    /// - Spanne → kürzerer Wert: Katzenschnupfen (FHV/FCV) und FeLV „im Abstand
    ///   von bis zu 3 Jahren" → 1 Jahr, weil die Gebrauchsinformationen der
    ///   Impfstoffe meist 1 Jahr nennen und Freigänger kürzer geimpft werden.
    /// - Kombiimpfungen richten sich nach der kürzesten Komponente: SHPPi + L
    ///   wegen Parainfluenza und Leptospirose, RCP wegen Katzenschnupfen →
    ///   1 Jahr.
    /// - Für SHP nennt die Leitlinie zusätzlich, dass die Gebrauchsinformationen
    ///   1 bis 3 Jahre vorsehen. Die Vorbelegung folgt der Empfehlung (3 Jahre);
    ///   bei einem Impfstoff mit 1 Jahr gilt der Eintrag im Impfpass.
    public func defaultValidityDays(for species: Species) -> Int {
        switch self {
        case .distemperHepatitisParvo, .panleukopenia:
            return 3 * 365
        case .dogCombination, .leptospirosis, .kennelCough, .lymeDisease, .leishmaniasis,
             .catFlu, .catCombination, .felineLeukemia, .other:
            return 365
        }
    }
}
