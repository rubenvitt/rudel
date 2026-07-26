import Foundation

/// Baut die Dashboard-Liste (PRD §5.6): alle offenen Aufgaben über alle Tiere,
/// nach Dringlichkeit sortiert.
///
/// Nimmt bewusst flache Value-Structs statt `@Model`-Objekte — die Engine kennt
/// SwiftData nicht (PRD §7). Die App-Schicht mappt ihre Modelle auf diese
/// Inputs; genau dieses Mapping ist in `Tests/RudelTests` abgedeckt.
public struct DueItemBuilder: Sendable {
    public let dayMath: DayMath

    /// Ein Medikamenten-Eintrag in der Form, in der die Engine ihn braucht.
    public struct MedicationInput: Sendable, Equatable, Hashable {
        public var sourceID: String
        public var petID: String
        public var petName: String
        public var kind: MedicationKind
        public var productName: String
        /// Letzte dokumentierte Gabe. `nil` = noch nie gegeben.
        public var lastGivenOn: Date?
        /// Wiederholungsintervall für `.dewormer`.
        public var intervalDays: Int?
        /// Wirkdauer für `.tickProtection` / `.rabiesVaccination`.
        public var effectiveDays: Int?
        /// Dosierschema für `.ongoing`.
        public var schedule: DoseSchedule?
        /// Deaktivierte Einträge (abgesetztes Medikament) erzeugen keine Items.
        public var isActive: Bool

        public init(
            sourceID: String,
            petID: String,
            petName: String,
            kind: MedicationKind,
            productName: String,
            lastGivenOn: Date? = nil,
            intervalDays: Int? = nil,
            effectiveDays: Int? = nil,
            schedule: DoseSchedule? = nil,
            isActive: Bool = true
        ) {
            self.sourceID = sourceID
            self.petID = petID
            self.petName = petName
            self.kind = kind
            self.productName = productName
            self.lastGivenOn = lastGivenOn
            self.intervalDays = intervalDays
            self.effectiveDays = effectiveDays
            self.schedule = schedule
            self.isActive = isActive
        }
    }

    /// Zyklus-Prognose eines Tieres fürs Dashboard.
    public struct CycleInput: Sendable, Equatable, Hashable {
        public var sourceID: String
        public var petID: String
        public var petName: String
        public var prediction: CyclePrediction?

        public init(
            sourceID: String,
            petID: String,
            petName: String,
            prediction: CyclePrediction?
        ) {
            self.sourceID = sourceID
            self.petID = petID
            self.petName = petName
            self.prediction = prediction
        }
    }

    public init(dayMath: DayMath = .utc) {
        self.dayMath = dayMath
    }

    /// Erzeugt die sortierte Dashboard-Liste.
    ///
    /// ## Regeln
    ///
    /// - `isActive == false` ⇒ übersprungen.
    /// - `lastGivenOn == nil` bei `.dewormer`/`.tickProtection`/`.rabiesVaccination`
    ///   ⇒ ein Item mit `urgency == .overdue` und `dueOn == asOf`: „noch nie
    ///   gegeben" ist die dringendste Form von offen, nicht die unwichtigste.
    /// - `.ongoing` erzeugt Items nur für Gaben **des heutigen Tages**, die noch
    ///   offen sind — nicht für den ganzen Horizont, sonst überflutet ein
    ///   Dauermedikament das Dashboard.
    /// - `.tickProtection`/`.rabiesVaccination` tragen `remainingFraction`.
    /// - Zyklus-Prognosen sind `isForecast == true` und werden nur aufgenommen,
    ///   wenn der Bandbeginn (`prediction.range.lowerBound`) innerhalb von
    ///   `forecastHorizonDays` liegt. Ihre Dringlichkeit richtet sich nach dem
    ///   *Bandbeginn*, nicht nach `expectedDate` — eine Läufigkeit kann am
    ///   frühen Rand des Bandes losgehen.
    ///
    /// ## Sortierung
    ///
    /// Absteigend nach `urgency`, bei gleicher Stufe aufsteigend nach `dueOn`,
    /// bei gleichem Datum alphabetisch nach `title` — damit die Reihenfolge
    /// bei unveränderten Daten stabil bleibt und die Liste in SwiftUI nicht
    /// springt.
    public func build(
        medications: [MedicationInput],
        cycles: [CycleInput],
        asOf: Date,
        forecastHorizonDays: Int = 30
    ) -> [DueItem] {
        fatalError("unimplemented")
    }
}
