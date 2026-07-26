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
        let today = dayMath.startOfDay(asOf)
        // Ein negativer Horizont ist Unsinn-Eingabe und darf nicht zu
        // Zufallsverhalten führen; 0 heißt „nur Bänder, die schon begonnen haben".
        let horizonDays = max(0, forecastHorizonDays)

        var items: [DueItem] = []
        for medication in medications where medication.isActive {
            items.append(contentsOf: medicationItems(for: medication, today: today))
        }
        for cycle in cycles {
            if let item = forecastItem(for: cycle, today: today, horizonDays: horizonDays) {
                items.append(item)
            }
        }

        return sortedForDashboard(deduplicatedByID(items))
    }
}

// MARK: - Interne Rechnung

private extension DueItemBuilder {

    /// Die Items eines Plans. Mehr als eines entsteht nur bei `.ongoing` —
    /// ein Dauermedikament mit zwei Gabezeiten ist zweimal abzuhaken.
    func medicationItems(for medication: MedicationInput, today: Date) -> [DueItem] {
        switch medication.kind {
        case .ongoing:
            return doseItems(for: medication, today: today)

        case .dewormer:
            guard let lastGivenOn = medication.lastGivenOn else {
                return [neverGivenItem(for: medication, today: today)]
            }
            // Ohne konfiguriertes Intervall gibt es keine nächste Fälligkeit.
            // Nicht als „sofort fällig" behandeln: die App-Schicht mappt ein
            // nicht gesetztes Intervall auf `nil`, eine einmalige Wurmkur wäre
            // sonst für immer überfällig.
            guard let intervalDays = medication.intervalDays else { return [] }
            // `intervalDays <= 0` ⇒ Fälligkeit am Gabetag selbst.
            let dueOn = dayMath.adding(days: max(0, intervalDays), to: lastGivenOn)
            let daysUntilDue = dayMath.days(from: today, to: dueOn)
            return [
                DueItem(
                    id: itemID(for: medication),
                    sourceID: medication.sourceID,
                    petID: medication.petID,
                    petName: medication.petName,
                    category: .medication,
                    title: title(for: medication.kind),
                    detail: medication.productName.isEmpty ? nil : medication.productName,
                    dueOn: dueOn,
                    daysUntilDue: daysUntilDue,
                    urgency: Urgency(daysUntilDue: daysUntilDue)
                )
            ]

        case .tickProtection, .rabiesVaccination:
            guard let lastGivenOn = medication.lastGivenOn else {
                return [neverGivenItem(for: medication, today: today)]
            }
            // Ohne Wirkdauer ist kein Ablaufdatum berechenbar — siehe `.dewormer`.
            guard let effectiveDays = medication.effectiveDays else { return [] }
            let expiresOn = dayMath.adding(days: max(0, effectiveDays), to: lastGivenOn)
            let daysUntilDue = dayMath.days(from: today, to: expiresOn)
            let elapsedDays = dayMath.days(from: lastGivenOn, to: today)
            return [
                DueItem(
                    id: itemID(for: medication),
                    sourceID: medication.sourceID,
                    petID: medication.petID,
                    petName: medication.petName,
                    category: .protectionExpiry,
                    title: title(for: medication.kind),
                    detail: medication.productName.isEmpty ? nil : medication.productName,
                    dueOn: expiresOn,
                    daysUntilDue: daysUntilDue,
                    urgency: Urgency(daysUntilDue: daysUntilDue),
                    remainingFraction: remainingFraction(
                        elapsedDays: elapsedDays,
                        effectiveDays: effectiveDays
                    )
                )
            ]
        }
    }

    /// „Noch nie gegeben" ist die dringendste Form von offen: `.overdue` am
    /// heutigen Tag. Bewusst *nicht* `Urgency(daysUntilDue: 0)` (= `.dueToday`) —
    /// ein Schutz, der nie bestand, ist überfällig, nicht heute fällig.
    func neverGivenItem(for medication: MedicationInput, today: Date) -> DueItem {
        let usesProtection = medication.kind.usesEffectivePeriod
        return DueItem(
            id: itemID(for: medication),
            sourceID: medication.sourceID,
            petID: medication.petID,
            petName: medication.petName,
            category: usesProtection ? .protectionExpiry : .medication,
            title: title(for: medication.kind),
            detail: medication.productName.isEmpty
                ? "Noch nie gegeben"
                : "\(medication.productName) · noch nie gegeben",
            dueOn: today,
            daysUntilDue: 0,
            urgency: .overdue,
            // Kein Schutz, der je bestand: der Balken steht auf Null.
            remainingFraction: usesProtection ? 0 : nil
        )
    }

    /// Die heute noch abzuhakenden Einzelgaben — und nur die. Über den ganzen
    /// Horizont erzeugt, würde ein Dauermedikament mit zwei Gaben täglich das
    /// Dashboard mit 60 Zeilen zumauern.
    func doseItems(for medication: MedicationInput, today: Date) -> [DueItem] {
        // Ohne Gabezeiten gibt es keine Termine — gleiche Lesart wie
        // `MedicationCalculator.doseOccurrences(schedule:in:)`, damit Dashboard
        // und Notification-Planung nicht auseinanderlaufen.
        guard let schedule = medication.schedule, !schedule.timesOfDay.isEmpty else { return [] }

        let daysSinceStart = dayMath.days(from: schedule.startDate, to: today)
        guard daysSinceStart >= 0 else { return [] }
        if let endDate = schedule.endDate, dayMath.days(from: today, to: endDate) < 0 { return [] }
        guard daysSinceStart % schedule.everyNDays == 0 else { return [] }

        return schedule.timesOfDay.map { time in
            let dueAt = dayMath.calendar.date(
                bySettingHour: time.hour,
                minute: time.minute,
                second: 0,
                of: today
            ) ?? today
            return DueItem(
                id: doseItemID(for: medication, at: dueAt),
                sourceID: medication.sourceID,
                petID: medication.petID,
                petName: medication.petName,
                category: .dose,
                title: medication.productName.isEmpty
                    ? title(for: medication.kind)
                    : medication.productName,
                detail: schedule.doseLabel.isEmpty ? nil : schedule.doseLabel,
                dueOn: dueAt,
                // Immer der heutige Tag, deshalb konstant 0 / `.dueToday`.
                daysUntilDue: 0,
                urgency: .dueToday
            )
        }
    }

    /// Die Zyklus-Prognose fürs Dashboard, wenn ihr Band in den Horizont fällt.
    func forecastItem(for cycle: CycleInput, today: Date, horizonDays: Int) -> DueItem? {
        guard let prediction = cycle.prediction else { return nil }

        // Der Bandbeginn ist das relevante Datum, nicht `expectedDate`: eine
        // Läufigkeit kann am frühen Rand des Bandes losgehen, und die Vorsorge
        // (Rüden meiden, Höschen bereitlegen) muss dann schon stehen.
        let bandStart = dayMath.startOfDay(prediction.range.lowerBound)
        let daysUntilDue = dayMath.days(from: today, to: bandStart)
        guard daysUntilDue <= horizonDays else { return nil }

        let halfWidth = Int(prediction.bandHalfWidthDays.rounded())
        return DueItem(
            id: "cycle:\(cycle.sourceID)",
            sourceID: cycle.sourceID,
            petID: cycle.petID,
            petName: cycle.petName,
            category: .cycleForecast,
            title: "Läufigkeit erwartet",
            detail: "Prognosefenster ± \(halfWidth) \(halfWidth == 1 ? "Tag" : "Tage")",
            dueOn: bandStart,
            daysUntilDue: daysUntilDue,
            urgency: Urgency(daysUntilDue: daysUntilDue),
            isForecast: true
        )
    }

    /// `(Wirkdauer − vergangene Tage) / Wirkdauer`, geklemmt auf `0...1`:
    /// der UI-Balken läuft nicht rückwärts und nicht über. Wie weit der Schutz
    /// überfällig ist, steht in `daysUntilDue`.
    func remainingFraction(elapsedDays: Int, effectiveDays: Int) -> Double {
        // Defensiv statt Division durch Null: keine Wirkdauer = kein Schutz.
        guard effectiveDays > 0 else { return 0 }
        let fraction = Double(effectiveDays - elapsedDays) / Double(effectiveDays)
        return min(max(fraction, 0), 1)
    }

    func title(for kind: MedicationKind) -> String {
        switch kind {
        case .dewormer: return "Wurmkur"
        case .tickProtection: return "Zeckenschutz"
        case .ongoing: return "Laufendes Medikament"
        case .rabiesVaccination: return "Tollwut-Impfung"
        }
    }

    func itemID(for medication: MedicationInput) -> String {
        "med:\(medication.sourceID)"
    }

    /// Enthält den planmäßigen Termin, weil die App-Schicht die schon
    /// abgehakten Gaben (`DoseLogEntry.scheduledAt`) daran wiedererkennt und
    /// `NotificationPlanner` dieselbe Quelle+Termin-Stabilität braucht.
    func doseItemID(for medication: MedicationInput, at date: Date) -> String {
        let parts = dayMath.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let stamp = String(
            format: "%04d-%02d-%02dT%02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0
        )
        return "dose:\(medication.sourceID):\(stamp)"
    }

    /// Doppelte Eingaben (derselbe Plan zweimal übergeben) dürfen nicht zu zwei
    /// Items mit gleicher `id` führen: `DueItem` ist `Identifiable`, und ein
    /// `ForEach` mit doppelten IDs rendert fehlerhaft. Erstes gewinnt.
    func deduplicatedByID(_ items: [DueItem]) -> [DueItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Dringlichkeit absteigend, dann Datum, dann Titel — und als letzte Stufe
    /// die `id`. Die braucht es, weil `sorted(by:)` in Swift nicht als stabil
    /// garantiert ist: bei zwei Tieren mit gleichem Titel und gleichem Datum
    /// würde die Reihenfolge sonst von der Eingabereihenfolge abhängen, und die
    /// SwiftUI-Liste springt bei jedem Neuladen. Absichtlich ohne Locale-Collation,
    /// damit die Reihenfolge geräteunabhängig dieselbe ist.
    func sortedForDashboard(_ items: [DueItem]) -> [DueItem] {
        items.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            if lhs.dueOn != rhs.dueOn { return lhs.dueOn < rhs.dueOn }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }
}
