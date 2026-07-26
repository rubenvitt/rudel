import Foundation
import RudelEngine
import SwiftData

/// Ein Tier. Alle Datensätze hängen an genau einem `Pet`.
///
/// ## CloudKit-Kompatibilität
///
/// Das gesamte Schema ist CloudKit-fähig gebaut, auch wenn Sync in v1
/// abgeschaltet ist (`ModelConfiguration(cloudKitDatabase: .none)`, siehe
/// `RudelApp`). Das kostet jetzt fast nichts und erspart später eine
/// Schema-Migration. Daraus folgen drei Regeln, die für **alle** Modelle gelten:
///
/// 1. Kein `@Attribute(.unique)` — CloudKit kennt keine Unique-Constraints.
/// 2. Jede nicht-optionale Property hat einen Default-Wert.
/// 3. Beziehungen sind auf der To-One-Seite optional, auf der To-Many-Seite
///    Arrays mit Default `[]`; `inverse:` steht nur auf **einer** Seite.
@Model
final class Pet {
    var id: UUID = UUID()
    var name: String = ""
    var speciesValue: Species = Species.dog
    var breed: String = ""
    var birthDate: Date?

    /// Zielbereich Gewicht in kg. `0` = nicht gesetzt.
    var weightTargetMinKg: Double = 0
    var weightTargetMaxKg: Double = 0

    /// Profilfoto. `.externalStorage`, damit große Bilder nicht in der
    /// SQLite-Datei landen.
    @Attribute(.externalStorage) var photoData: Data?

    /// Kastriert/sterilisiert. Steuert, ob das Zyklus-Modul überhaupt
    /// angezeigt wird.
    var isNeutered: Bool = false

    /// Weiblich. Nur für unkastrierte Hündinnen ist der Zyklus relevant.
    var isFemale: Bool = true

    /// Überschreibt die aus dem Gewicht abgeleitete Größenklasse. `nil` =
    /// automatisch. Relevant für den Startwert des Zyklusintervalls
    /// (`StudyConstants.intervalBiasDays(for:)`).
    var sizeClassOverride: DogSizeClass?

    var createdAt: Date = Date.distantPast

    @Relationship(deleteRule: .cascade, inverse: \MedicationPlan.pet)
    var medicationPlans: [MedicationPlan] = []

    @Relationship(deleteRule: .cascade, inverse: \CyclePeriod.pet)
    var cyclePeriods: [CyclePeriod] = []

    @Relationship(deleteRule: .cascade, inverse: \SymptomEntry.pet)
    var symptomEntries: [SymptomEntry] = []

    @Relationship(deleteRule: .cascade, inverse: \WeightEntry.pet)
    var weightEntries: [WeightEntry] = []

    init(
        name: String = "",
        species: Species = .dog,
        breed: String = "",
        birthDate: Date? = nil,
        weightTargetMinKg: Double = 0,
        weightTargetMaxKg: Double = 0,
        isFemale: Bool = true,
        isNeutered: Bool = false,
        sizeClassOverride: DogSizeClass? = nil,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.name = name
        self.speciesValue = species
        self.breed = breed
        self.birthDate = birthDate
        self.weightTargetMinKg = weightTargetMinKg
        self.weightTargetMaxKg = weightTargetMaxKg
        self.isFemale = isFemale
        self.isNeutered = isNeutered
        self.sizeClassOverride = sizeClassOverride
        self.createdAt = createdAt
    }
}

extension Pet {
    /// Zeigt die App für dieses Tier das Zyklus-Modul?
    ///
    /// Nur unkastrierte Hündinnen. Katzen sind bewusst ausgeschlossen: sie sind
    /// saisonal polyöstrisch mit induzierter Ovulation, die Engine modelliert
    /// das nicht (siehe `Species`).
    var tracksCycle: Bool {
        speciesValue == .dog && isFemale && !isNeutered
    }

    /// Zuletzt gewogenes Gewicht in kg, falls vorhanden.
    var latestWeightKg: Double? {
        weightEntries.max(by: { $0.date < $1.date })?.valueKg
    }

    /// Größenklasse für die Zyklus-Prognose: manuelle Vorgabe, sonst aus dem
    /// letzten Gewicht, sonst `.medium`.
    var effectiveSizeClass: DogSizeClass {
        if let sizeClassOverride { return sizeClassOverride }
        if let weight = latestWeightKg, weight > 0 { return DogSizeClass(weightKg: weight) }
        return .medium
    }

    /// Alter in Jahren und Monaten, für die Profilanzeige.
    func ageComponents(asOf: Date = Date(), calendar: Calendar = .current) -> (years: Int, months: Int)? {
        guard let birthDate, birthDate <= asOf else { return nil }
        let parts = calendar.dateComponents([.year, .month], from: birthDate, to: asOf)
        return (parts.year ?? 0, parts.month ?? 0)
    }

    /// Opake ID für die Engine-Value-Types.
    var engineID: String { id.uuidString }
}
