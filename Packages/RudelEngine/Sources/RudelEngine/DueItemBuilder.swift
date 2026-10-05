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
        /// Erinnerungsklasse. Bestimmt nicht die Fälligkeit, nur wie
        /// aufdringlich erinnert wird — sie wird an die Items durchgereicht.
        public var careClass: MedicationCareClass
        /// Letzte ausgelassene Gabe („Diesmal auslassen"). Schiebt die nächste
        /// Fälligkeit, aber nicht den Schutzbalken: eine ausgelassene
        /// Zeckentablette schützt nicht.
        public var lastSkippedOn: Date?
        /// Zurückgestellt bis zu diesem Tag (Zeckentablette im Winter). Die
        /// App-Schicht gibt das nur weiter, solange nach der Zurückstellung nichts
        /// dokumentiert wurde.
        public var deferredUntil: Date?
        /// Die Gabe braucht einen Tierarzttermin (Impfung).
        public var requiresVetVisit: Bool
        /// Ein verknüpfter Termin ist geplant — unabhängig von seinem Datum, damit
        /// nach Terminbeginn, aber vor dem Abschluss nicht wieder „Termin
        /// vereinbaren" erscheint.
        public var hasOpenAppointment: Bool
        /// Welche Impfung — nur bei `.vaccination`. Bestimmt den Titel.
        public var vaccine: VaccineType?
        /// Vorratsverwaltung. `nil` = keine.
        public var stock: StockInput?

        /// `careClass == nil` heißt „Standard der Art" (`kind.defaultCareClass`) —
        /// so behalten Bestandspläne ohne Override ihr Verhalten.
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
            isActive: Bool = true,
            careClass: MedicationCareClass? = nil,
            lastSkippedOn: Date? = nil,
            deferredUntil: Date? = nil,
            requiresVetVisit: Bool = false,
            hasOpenAppointment: Bool = false,
            vaccine: VaccineType? = nil,
            stock: StockInput? = nil
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
            self.careClass = careClass ?? kind.defaultCareClass
            self.lastSkippedOn = lastSkippedOn
            self.deferredUntil = deferredUntil
            self.requiresVetVisit = requiresVetVisit
            self.hasOpenAppointment = hasOpenAppointment
            self.vaccine = vaccine
            self.stock = stock
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

    /// Ein geplanter Tierarzttermin. Die App-Schicht übergibt nur Termine im
    /// Status „geplant"; abgeschlossene und abgesagte gehören nicht aufs Dashboard.
    public struct AppointmentInput: Sendable, Equatable, Hashable {
        public var sourceID: String
        public var petID: String
        public var petName: String
        public var title: String
        /// Z. B. die Praxis.
        public var detail: String?
        /// Terminbeginn mit Uhrzeit.
        public var at: Date
        /// Der Medikamentenplan, dessen Gabe dieser Termin erledigt. Nur
        /// informativ: ob ein Plan durch einen Termin abgedeckt ist, sagt
        /// `MedicationInput.hasOpenAppointment` — ein zweiter Weg hierüber könnte
        /// der App-Schicht widersprechen.
        public var linkedMedicationSourceID: String?

        public init(
            sourceID: String,
            petID: String,
            petName: String,
            title: String,
            detail: String? = nil,
            at: Date,
            linkedMedicationSourceID: String? = nil
        ) {
            self.sourceID = sourceID
            self.petID = petID
            self.petName = petName
            self.title = title
            self.detail = detail
            self.at = at
            self.linkedMedicationSourceID = linkedMedicationSourceID
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
    /// - Basis der Fälligkeit ist die spätere von `lastGivenOn` und
    ///   `lastSkippedOn`. Fehlen beide bei `.dewormer`/`.tickProtection`/
    ///   `.rabiesVaccination` ⇒ ein Item mit `urgency == .overdue` und
    ///   `dueOn == asOf`: „noch nie gegeben" ist die dringendste Form von offen,
    ///   nicht die unwichtigste.
    /// - `.ongoing` erzeugt Items nur für Gaben **des heutigen Tages**, die noch
    ///   offen sind — nicht für den ganzen Horizont, sonst überflutet ein
    ///   Dauermedikament das Dashboard.
    /// - `.tickProtection`/`.rabiesVaccination` tragen `remainingFraction` und
    ///   `protectionEndsOn`, beide nur aus `lastGivenOn` (ohne Gabe: 0 bzw.
    ///   `nil`). `protectionEndsOn` bleibt von Auslassung und Zurückstellung
    ///   unberührt.
    /// - `deferredUntil` (auf Tagesbeginn) gilt für alle Pfade inklusive „noch
    ///   nie gegeben": `dueOn = max(regulär, deferredUntil)`, Dringlichkeit aus
    ///   dem verschobenen Datum. Bei `.ongoing` entfallen die Dosis-Items bis
    ///   dahin.
    /// - `hasOpenAppointment` ⇒ kein Item für Wurmkur, Zeckenschutz und Impfung;
    ///   der Termin übernimmt. `requiresVetVisit` ohne offenen Termin ⇒
    ///   `needsVetAppointment`. Beides gilt nicht für `.ongoing`: ein
    ///   Kontrolltermin darf die täglichen Gaben eines Dauermedikaments nicht
    ///   verschlucken, und `MedicationReminderPlanner` plant dessen Dosen ohnehin
    ///   direkt aus dem Schema.
    /// - Termine: künftige nur innerhalb von `forecastHorizonDays` mit
    ///   Dringlichkeit aus dem Termintag; begonnene bleiben bis zum Abschluss mit
    ///   `.dueToday` stehen — vergessen werden soll der Abschluss nicht, rot
    ///   leuchten wie eine überfällige Behandlung soll er aber auch nicht.
    /// - Vorrat: ein `.restock`-Item je aktivem Plan mit Vorratsverwaltung,
    ///   sobald die Reichweite höchstens `restockLeadDays` beträgt oder der
    ///   Bestand nicht mehr für die nächste Gabe reicht (siehe
    ///   `stockProjection(for:asOf:)`). Unabhängig von einem offenen Termin.
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
        appointments: [AppointmentInput] = [],
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
            if let item = restockItem(for: medication, asOf: asOf, today: today) {
                items.append(item)
            }
        }
        for cycle in cycles {
            if let item = forecastItem(for: cycle, today: today, horizonDays: horizonDays) {
                items.append(item)
            }
        }
        for appointment in appointments {
            if let item = appointmentItem(
                for: appointment,
                asOf: asOf,
                today: today,
                horizonDays: horizonDays
            ) {
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
        if medication.kind == .ongoing {
            return doseItems(for: medication, today: today)
        }
        // Ein geplanter Termin übernimmt die Gabe samt Item und Mitteilungen.
        // Zwei Zeilen für dieselbe Sache („Impfung fällig" und „Termin am …")
        // wären doppelt.
        guard !medication.hasOpenAppointment else { return [] }
        guard var item = scheduledItem(for: medication, today: today) else { return [] }

        item.careClass = medication.careClass
        item.needsVetAppointment = medication.requiresVetVisit
        applyDeferral(medication.deferredUntil, to: &item, today: today)
        return [item]
    }

    /// Fälligkeit einer Wurmkur, eines Schutzes oder einer Impfung ohne
    /// Zurückstellung.
    func scheduledItem(for medication: MedicationInput, today: Date) -> DueItem? {
        // Eine Auslassung zählt für die Fälligkeit wie eine Gabe: wer die
        // Wurmkur bewusst ausgelassen hat, will erst ein Intervall später
        // wieder daran erinnert werden.
        guard let dueBase = laterDate(medication.lastGivenOn, medication.lastSkippedOn) else {
            return neverGivenItem(for: medication, today: today)
        }

        switch medication.kind {
        case .ongoing:
            // Läuft über `doseItems`, siehe `medicationItems`.
            return nil

        case .dewormer:
            // Ohne konfiguriertes Intervall gibt es keine nächste Fälligkeit.
            // Nicht als „sofort fällig" behandeln: die App-Schicht mappt ein
            // nicht gesetztes Intervall auf `nil`, eine einmalige Wurmkur wäre
            // sonst für immer überfällig.
            guard let intervalDays = medication.intervalDays else { return nil }
            // `intervalDays <= 0` ⇒ Fälligkeit am Gabetag selbst.
            let dueOn = dayMath.adding(days: max(0, intervalDays), to: dueBase)
            let daysUntilDue = dayMath.days(from: today, to: dueOn)
            return DueItem(
                id: itemID(for: medication),
                sourceID: medication.sourceID,
                petID: medication.petID,
                petName: medication.petName,
                category: .medication,
                title: title(for: medication),
                detail: detail(for: medication),
                dueOn: dueOn,
                daysUntilDue: daysUntilDue,
                urgency: Urgency(daysUntilDue: daysUntilDue)
            )

        case .tickProtection, .rabiesVaccination, .vaccination:
            // Ohne Wirkdauer ist kein Ablaufdatum berechenbar — siehe `.dewormer`.
            guard let effectiveDays = medication.effectiveDays else { return nil }
            let dueOn = dayMath.adding(days: max(0, effectiveDays), to: dueBase)
            let daysUntilDue = dayMath.days(from: today, to: dueOn)
            // Der Balken rechnet nur ab echten Gaben: eine ausgelassene
            // Zeckentablette schützt nicht, auch wenn sie die nächste
            // Erinnerung verschiebt.
            let fraction = medication.lastGivenOn.map { lastGivenOn in
                remainingFraction(
                    elapsedDays: dayMath.days(from: lastGivenOn, to: today),
                    effectiveDays: effectiveDays
                )
            } ?? 0
            // Schutzende getrennt von `dueOn`: Auslassung und Zurückstellung
            // schieben die Fälligkeit, nicht das Ende des Schutzes.
            let protectionEndsOn = medication.lastGivenOn.map {
                dayMath.adding(days: max(0, effectiveDays), to: $0)
            }
            return DueItem(
                id: itemID(for: medication),
                sourceID: medication.sourceID,
                petID: medication.petID,
                petName: medication.petName,
                category: .protectionExpiry,
                title: title(for: medication),
                detail: detail(for: medication),
                dueOn: dueOn,
                daysUntilDue: daysUntilDue,
                urgency: Urgency(daysUntilDue: daysUntilDue),
                remainingFraction: fraction,
                protectionEndsOn: protectionEndsOn
            )
        }
    }

    /// Schiebt die Fälligkeit auf `deferredUntil`, falls das später liegt.
    ///
    /// Eine Zurückstellung, die vor der regulären Fälligkeit endet, ist
    /// wirkungslos — sie darf eine spätere Fälligkeit nicht vorziehen. Eine
    /// abgelaufene Zurückstellung verschiebt weiterhin, damit die
    /// Überfälligkeit ab dem verschobenen Tag zählt und nicht ab der alten
    /// Fälligkeit; nur das Item-Feld `deferredUntil` bleibt dann leer, weil
    /// nichts mehr zurückgestellt *ist*. `protectionEndsOn` bleibt in jedem Fall
    /// stehen — sonst hielte man den verschobenen Tag für das Schutzende. Bei „noch nie gegeben" (heute, `.overdue`)
    /// greift sie damit erst, wenn sie in der Zukunft liegt — sonst würde eine
    /// verstrichene Zurückstellung aus „überfällig" ein „heute fällig" machen.
    func applyDeferral(_ deferredUntil: Date?, to item: inout DueItem, today: Date) {
        guard let deferredUntil else { return }
        let deferredDay = dayMath.startOfDay(deferredUntil)
        guard deferredDay > item.dueOn else { return }

        let daysUntilDue = dayMath.days(from: today, to: deferredDay)
        item.dueOn = deferredDay
        item.daysUntilDue = daysUntilDue
        item.urgency = Urgency(daysUntilDue: daysUntilDue)
        item.deferredUntil = deferredDay > today ? deferredDay : nil
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
            title: title(for: medication),
            detail: detail(for: medication).map { "\($0) · noch nie gegeben" } ?? "Noch nie gegeben",
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
        // Zurückgestellt: bis zum Tag der Zurückstellung keine Gaben. Am Tag
        // selbst geht es wieder los — dieselbe Grenze wie im
        // `MedicationReminderPlanner`.
        if let deferredUntil = medication.deferredUntil, dayMath.startOfDay(deferredUntil) > today {
            return []
        }

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
                urgency: .dueToday,
                careClass: medication.careClass
            )
        }
    }

    /// Ein Tierarzttermin fürs Dashboard.
    ///
    /// Ein begonnener Termin bleibt stehen, bis die App-Schicht ihn nicht mehr
    /// übergibt (Abschluss oder Absage) — sonst geht der Befund nie ein. Er steht
    /// als `.dueToday` da: nicht vergessen, aber auch keine überfällige
    /// Behandlung.
    func appointmentItem(
        for appointment: AppointmentInput,
        asOf: Date,
        today: Date,
        horizonDays: Int
    ) -> DueItem? {
        let daysUntilDue: Int
        let urgency: Urgency
        if appointment.at < asOf {
            daysUntilDue = 0
            urgency = .dueToday
        } else {
            daysUntilDue = dayMath.days(from: today, to: appointment.at)
            guard daysUntilDue <= horizonDays else { return nil }
            urgency = Urgency(daysUntilDue: daysUntilDue)
        }

        return DueItem(
            id: "appt:\(appointment.sourceID)",
            sourceID: appointment.sourceID,
            petID: appointment.petID,
            petName: appointment.petName,
            category: .vetAppointment,
            title: appointment.title,
            detail: appointment.detail,
            // Mit Uhrzeit: Mitteilungen und Anzeige brauchen den Terminbeginn.
            dueOn: appointment.at,
            daysUntilDue: daysUntilDue,
            urgency: urgency
        )
    }

    func laterDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
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
        case .vaccination: return "Impfung"
        }
    }

    /// Titel eines Items: bei einer Impfung deren Name („Leptospirose"), bei
    /// „andere Impfung" das Präparat — sonst die Gattung.
    func title(for medication: MedicationInput) -> String {
        guard medication.kind == .vaccination else { return title(for: medication.kind) }
        if let vaccine = medication.vaccine, vaccine != .other { return vaccine.displayName }
        let product = medication.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        return product.isEmpty ? title(for: medication.kind) : product
    }

    /// Das Präparat als Zusatz — außer es steht schon im Titel.
    func detail(for medication: MedicationInput) -> String? {
        let product = medication.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !product.isEmpty, title(for: medication) != product else { return nil }
        return product
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

// MARK: - Vorrat

extension DueItemBuilder {
    /// Wie weit über den Stichtag hinaus Gaben eines Dauermedikaments gezählt
    /// werden. Drei Jahre reichen für jede sinnvolle Vorlaufzeit; darüber steht
    /// nur der Restbestand ohne Datum.
    static let stockProjectionLimitDays = 3 * 365

    /// Obergrenze für gedeckte Gaben. Absurde Eingaben (20 Stellen Bestand,
    /// winzige Menge je Gabe) dürfen beim Umwandeln in `Int` nicht abstürzen —
    /// der Wert ist gespeichert und würde jeden Start treffen.
    static let maxCoveredGivings = 1_000_000

    /// Restbestand und Reichweite eines Plans. `nil` ohne Vorratsverwaltung.
    ///
    /// - Dauermedikament: die Gaben aus dem Schema ab Tagesbeginn (bzw. ab dem
    ///   Ende einer Zurückstellung), heute schon erfasste abgezogen. Endet das
    ///   Schema, bevor der Vorrat aufgebraucht ist, gibt es kein `runsOutOn`.
    /// - Wurmkur, Zeckenschutz, Impfung: eine Gabe je Intervall bzw. Wirkdauer ab
    ///   der nächsten Fälligkeit (inklusive Auslassung und Zurückstellung,
    ///   aber nie vor heute — eine überfällige Gabe wird heute gegeben).
    /// - Ohne berechenbare nächste Gabe: nur der Restbestand; reicht er nicht
    ///   einmal für eine Gabe, gilt er ab heute als aufgebraucht.
    public func stockProjection(for medication: MedicationInput, asOf: Date) -> StockProjection? {
        guard let stock = medication.stock else { return nil }
        let today = dayMath.startOfDay(asOf)
        let remaining = stock.remainingAmount
        let perGiving = stock.amountPerGiving
        // Ohne positive Menge je Gabe verbraucht keine Gabe etwas — der Vorrat
        // reicht dann unbegrenzt, statt durch Null zu teilen.
        let covered: Int
        if perGiving > 0 {
            // Kleine Toleranz gegen Rundungsfehler bei halben Tabletten.
            let ratio = (remaining / perGiving) + 1e-9
            covered = ratio.isFinite
                ? Int(min(max(ratio, 0), Double(Self.maxCoveredGivings)).rounded(.down))
                : (ratio > 0 ? Self.maxCoveredGivings : 0)
        } else {
            covered = Int.max
        }

        var lastCoveredOn: Date?
        var runsOutOn: Date?
        switch givingPattern(for: medication, today: today) {
        case .schedule(let schedule, let startDay):
            (lastCoveredOn, runsOutOn) = projectSchedule(
                schedule,
                from: startDay,
                today: today,
                handledToday: stock.dosesHandledToday,
                covered: covered
            )
        case .interval(let firstDay, let days):
            if covered == Int.max {
                break
            } else if covered == 0 {
                runsOutOn = firstDay
            } else {
                lastCoveredOn = dayMath.adding(days: (covered - 1) * days, to: firstDay)
                runsOutOn = dayMath.adding(days: covered * days, to: firstDay)
            }
        case .unknown:
            if covered == 0 { runsOutOn = today }
        case .none:
            break
        }

        return StockProjection(
            remainingAmount: remaining,
            unit: stock.unit,
            amountPerGiving: perGiving,
            coveredGivings: covered,
            lastCoveredOn: lastCoveredOn,
            runsOutOn: runsOutOn,
            daysOfSupply: runsOutOn.map { dayMath.days(from: today, to: $0) },
            restockLeadDays: stock.restockLeadDays,
            needsPrescription: stock.needsPrescription
        )
    }

    /// Wann künftig gegeben wird.
    enum GivingPattern {
        /// Dosierschema ab `startDay` (heute oder Ende der Zurückstellung).
        case schedule(DoseSchedule, startDay: Date)
        /// Eine Gabe alle `days` Tage ab `firstDay`.
        case interval(firstDay: Date, days: Int)
        /// Gaben sind vorgesehen, lassen sich aber nicht datieren.
        case unknown
        /// Es kommt keine Gabe mehr (Schema beendet).
        case none
    }

    func givingPattern(for medication: MedicationInput, today: Date) -> GivingPattern {
        if medication.kind == .ongoing {
            guard let schedule = medication.schedule else { return .unknown }
            if let endDate = schedule.endDate, dayMath.startOfDay(endDate) < today { return .none }
            var startDay = today
            if let deferredUntil = medication.deferredUntil {
                startDay = max(startDay, dayMath.startOfDay(deferredUntil))
            }
            return .schedule(schedule, startDay: startDay)
        }

        let days = medication.kind == .dewormer ? medication.intervalDays : medication.effectiveDays
        // Bewusst an `medicationItems` vorbei: ein offener Termin verschluckt das
        // Fälligkeits-Item, die Gabe kommt aber trotzdem.
        guard let days, days > 0, var item = scheduledItem(for: medication, today: today) else {
            return .unknown
        }
        applyDeferral(medication.deferredUntil, to: &item, today: today)
        return .interval(firstDay: max(dayMath.startOfDay(item.dueOn), today), days: days)
    }

    /// Geht das Schema Gabetag für Gabetag durch, bis der Vorrat nicht mehr
    /// reicht, das Schema endet oder die Rechengrenze erreicht ist.
    func projectSchedule(
        _ schedule: DoseSchedule,
        from startDay: Date,
        today: Date,
        handledToday: Int,
        covered: Int
    ) -> (lastCoveredOn: Date?, runsOutOn: Date?) {
        guard covered != Int.max else { return (nil, nil) }
        let step = max(1, schedule.everyNDays)
        let scheduleStart = dayMath.startOfDay(schedule.startDate)
        let limit = dayMath.adding(days: Self.stockProjectionLimitDays, to: today)
        let endDay = schedule.endDate.map { dayMath.startOfDay($0) }

        // Auf das n-Tage-Raster des Schemas springen.
        var offset = 0
        let daysFromStart = dayMath.days(from: scheduleStart, to: startDay)
        if daysFromStart > 0 {
            offset = ((daysFromStart + step - 1) / step) * step
        }

        var left = covered
        var lastCoveredOn: Date?
        var previousDay: Date?
        while true {
            let day = dayMath.adding(days: offset, to: scheduleStart)
            if let previousDay, day <= previousDay { break }
            if day > limit { break }
            if let endDay, day > endDay { break }

            var count = schedule.dosesPerDay
            if day == today { count = max(0, count - handledToday) }
            if count > 0 {
                guard left >= count else { return (lastCoveredOn, day) }
                left -= count
                lastCoveredOn = day
            }
            previousDay = day
            offset += step
        }
        return (lastCoveredOn, nil)
    }

    /// Das Vorrats-Item eines Plans, wenn nachgefüllt werden muss.
    func restockItem(for medication: MedicationInput, asOf: Date, today: Date) -> DueItem? {
        guard let projection = stockProjection(for: medication, asOf: asOf),
              projection.needsRestock,
              let runsOutOn = projection.runsOutOn,
              let daysOfSupply = projection.daysOfSupply else { return nil }

        let name = stockName(for: medication)

        var detail = projection.remainingAmount > 0
            ? "Noch \(Self.amountText(projection.remainingAmount))"
                + (projection.unit.isEmpty ? "" : " \(projection.unit)")
            : "Vorrat aufgebraucht"
        if projection.needsPrescription { detail += " · Rezept nötig" }

        return DueItem(
            id: "restock:\(medication.sourceID)",
            sourceID: medication.sourceID,
            petID: medication.petID,
            petName: medication.petName,
            category: .restock,
            title: "Vorrat \(name)",
            detail: detail,
            dueOn: runsOutOn,
            daysUntilDue: daysOfSupply,
            urgency: Urgency(daysUntilDue: daysOfSupply),
            stock: projection
        )
    }

    /// Das Präparat, sonst der Titel der Art („Vorrat Apoquel").
    private func stockName(for medication: MedicationInput) -> String {
        let product = medication.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        return product.isEmpty ? title(for: medication) : product
    }

    /// „12", „1,5" — locale-unabhängig deutsch, wie die übrigen Engine-Texte.
    static func amountText(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e12 else { return "sehr viele" }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",")
    }
}
