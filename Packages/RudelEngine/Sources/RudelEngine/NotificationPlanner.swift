import Foundation

/// Entscheidet, **welche** lokalen Benachrichtigungen gesetzt werden (PRD §5.6).
///
/// ## Warum das Logik und nicht nur ein UNUserNotificationCenter-Aufruf ist
///
/// iOS hält pro App maximal **64** ausstehende `UNNotificationRequest`s. Wird
/// mehr geplant, verwirft das System stillschweigend die überzähligen — und
/// zwar nicht notwendigerweise die unwichtigsten. Ein Dauermedikament mit
/// 2 Gaben täglich verbraucht das Budget in 32 Tagen komplett und würde
/// die Wurmkur-Erinnerung verdrängen. Genau das Szenario, das Erfolgskriterium
/// §10.1 („keine verpasste Gabe") kaputt macht.
///
/// Deshalb: rollierendes Fenster (`horizonDays`) statt vollem Horizont, harte
/// Priorisierung, und Neuplanung bei App-Vordergrund und nach jedem Log.
public struct NotificationPlanner: Sendable {
    /// Hartes Systemlimit ausstehender Requests pro App.
    public static let iosPendingRequestLimit = 64

    /// Reserve unterhalb des Limits, damit eine Neuplanung, die sich mit noch
    /// nicht abgeräumten alten Requests überlappt, nicht ins Limit läuft.
    public static let safetyMargin = 8

    /// Effektives Budget: 56.
    public static var budget: Int { iosPendingRequestLimit - safetyMargin }

    public let dayMath: DayMath

    /// Eine geplante Benachrichtigung. Rein deklarativ — die App-Schicht
    /// übersetzt das in `UNNotificationRequest`.
    public struct PlannedNotification: Sendable, Equatable, Hashable, Identifiable {
        /// Stabil über Neuplanungen hinweg: gleiche Quelle + gleicher Termin
        /// ⇒ gleiche ID. So ersetzt iOS den Request statt zu duplizieren.
        public var id: String
        public var fireDate: Date
        public var title: String
        public var body: String
        public var petID: String
        public var category: DueItem.Category
        /// Priorität für den Fall, dass gekürzt werden muss. Höher = wichtiger.
        public var priority: Int

        public init(
            id: String,
            fireDate: Date,
            title: String,
            body: String,
            petID: String,
            category: DueItem.Category,
            priority: Int
        ) {
            self.id = id
            self.fireDate = fireDate
            self.title = title
            self.body = body
            self.petID = petID
            self.category = category
            self.priority = priority
        }
    }

    /// Nutzer-Einstellungen zur Vorwarnzeit.
    public struct Settings: Sendable, Equatable, Hashable {
        /// Wie viele Tage vor Fälligkeit erinnert wird. Mehrere Werte ⇒ mehrere
        /// Erinnerungen, z. B. `[7, 1, 0]`.
        public var leadDays: [Int]
        /// Uhrzeit der Fälligkeits-Erinnerungen (Dosis-Erinnerungen nutzen die
        /// Zeiten aus dem Dosierschema).
        public var reminderTime: TimeOfDay
        /// Länge des rollierenden Fensters in Tagen.
        public var horizonDays: Int

        public init(
            leadDays: [Int] = [7, 1, 0],
            reminderTime: TimeOfDay = TimeOfDay(hour: 9),
            horizonDays: Int = 14
        ) {
            self.leadDays = leadDays.sorted(by: >)
            self.reminderTime = reminderTime
            self.horizonDays = max(1, horizonDays)
        }
    }

    public init(dayMath: DayMath = .utc) {
        self.dayMath = dayMath
    }

    /// Plant die Benachrichtigungen für das Fenster `asOf ... asOf + horizonDays`.
    ///
    /// - Parameters:
    ///   - dueItems: Dashboard-Items aus `DueItemBuilder`.
    ///   - doseOccurrences: Einzelgaben-Termine je Medikament, Schlüssel ist
    ///     `MedicationInput.sourceID`. Werden von der App aus
    ///     `MedicationCalculator.doseOccurrences(schedule:in:)` befüllt.
    ///   - criticalDays: Tageshinweise einer laufenden Läufigkeit aus
    ///     `CriticalDaysAdvisor`, geschlüsselt nach **`petID`**.
    ///
    ///     Anders als `doseOccurrences` bewusst nach dem Tier und nicht nach der
    ///     Quelle geschlüsselt: eine `CriticalDayNotice` bringt Titel und Text
    ///     schon mit, ihr fehlt nur die `petID`. Über den Schlüssel kommt sie
    ///     direkt herein, statt aus einem passenden `DueItem` erschlossen werden
    ///     zu müssen — genau die Abhängigkeit, an der Dosis-Termine ohne
    ///     Gegenstück verworfen werden müssen.
    ///   - settings: Vorwarnzeiten und Fensterlänge.
    ///   - asOf: „jetzt". Termine in der Vergangenheit werden verworfen — iOS
    ///     würde sie sofort feuern.
    ///
    /// ## Priorisierung beim Kürzen auf `budget`
    ///
    /// 1. Tage, an denen eine Deckung möglich ist (höchste Priorität — die
    ///    einzige Kategorie, deren Versäumnis irreversibel ist)
    /// 2. Überfällige und heute fällige Fälligkeiten
    /// 3. Heutige Einzelgaben
    /// 4. Läufigkeit läuft, Deckung aber noch nicht bzw. nicht mehr zu erwarten
    /// 5. Fälligkeiten innerhalb der Vorwarnzeit, näher = wichtiger
    /// 6. Künftige Einzelgaben, chronologisch
    /// 7. Zyklus-Prognosen (unscharf, deshalb zuletzt)
    ///
    /// Innerhalb gleicher Priorität gewinnt der frühere Termin. Die Rückgabe
    /// ist chronologisch sortiert und enthält höchstens `budget` Einträge.
    ///
    /// ## Invarianten (als Tests festgeschrieben)
    ///
    /// 1. `result.count <= NotificationPlanner.budget`.
    /// 2. Kein `fireDate` liegt vor `asOf`.
    /// 3. IDs sind eindeutig.
    /// 4. Ein überfälliges Item wird niemals von Dosis-Erinnerungen verdrängt —
    ///    auch nicht bei 20 Dauermedikamenten.
    /// 5. Ein kritischer Tag wird von nichts verdrängt.
    public func plan(
        dueItems: [DueItem],
        doseOccurrences: [String: [Date]],
        criticalDays: [String: [CriticalDayNotice]] = [:],
        settings: Settings,
        asOf: Date
    ) -> [PlannedNotification] {
        var candidates: [PlannedNotification] = []

        // Metadaten je Quelle. `doseOccurrences` ist nach der opaken `sourceID`
        // geschlüsselt und trägt weder Tiernamen noch Präparat — beides kommt
        // nur aus einem `DueItem` derselben Quelle.
        var metaBySource: [String: DueItem] = [:]
        for item in dueItems {
            // Ein `.dose`-Item beschreibt die Gabe am genauesten; sonst reicht
            // jedes Item derselben Quelle für Name und Bezeichnung.
            if let known = metaBySource[item.sourceID], known.category == .dose { continue }
            metaBySource[item.sourceID] = item
        }

        for item in dueItems {
            candidates.append(contentsOf: notifications(for: item, settings: settings, asOf: asOf))
        }

        for (sourceID, dates) in doseOccurrences {
            // Ohne passendes `DueItem` fehlen Tiername und `petID`. Eine
            // Erinnerung, die die App-Schicht keinem Tier zuordnen kann, ist
            // schlimmer als keine — deshalb überspringen (siehe `concerns`).
            guard let meta = metaBySource[sourceID] else { continue }
            for date in dates {
                guard let planned = doseNotification(
                    source: meta,
                    fireDate: date,
                    settings: settings,
                    asOf: asOf
                ) else { continue }
                candidates.append(planned)
            }
        }

        for (petID, notices) in criticalDays {
            for notice in notices {
                guard let planned = criticalDayNotification(
                    notice,
                    petID: petID,
                    settings: settings,
                    asOf: asOf
                ) else { continue }
                candidates.append(planned)
            }
        }

        // Totale Ordnung, damit das Ergebnis nicht von der (undefinierten)
        // Iterationsreihenfolge des Dictionaries abhängt: Priorität schlägt
        // Termin, danach entscheiden ID und Text.
        let ranked = candidates.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if a.fireDate != b.fireDate { return a.fireDate < b.fireDate }
            if a.id != b.id { return a.id < b.id }
            if a.title != b.title { return a.title < b.title }
            return a.body < b.body
        }

        // Kürzen auf das Budget und gleichzeitig nach ID entdoppeln: dieselbe
        // Quelle zum selben Termin darf nur einen Request belegen, sonst
        // verschenkt eine doppelte Vorwarnzeit ([7, 7, 0]) Budget.
        var seen = Set<String>()
        var kept: [PlannedNotification] = []
        kept.reserveCapacity(min(ranked.count, Self.budget))
        for candidate in ranked {
            if kept.count >= Self.budget { break }
            guard seen.insert(candidate.id).inserted else { continue }
            kept.append(candidate)
        }

        return kept.sorted { a, b in
            if a.fireDate != b.fireDate { return a.fireDate < b.fireDate }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.id < b.id
        }
    }

    // MARK: - Prioritäten
    //
    // Die Werte spiegeln die Prioritätsliste aus dem Doc-Kommentar von `plan`.
    // Nur die Ordnung zählt; die Lücken lassen Platz für Zwischenstufen, ohne
    // alles umzunummerieren.

    /// Ein Tag, an dem eine Deckung möglich ist.
    ///
    /// Steht bewusst **über** allen Fälligkeiten. Jede andere Kategorie ist
    /// nachholbar: eine Wurmkur kann man einen Tag später geben, ein
    /// Zeckenschutz-Fenster einen Tag später schließen. Ein verpasster kritischer
    /// Tag ist die einzige Kategorie mit irreversibler Folge.
    private static let priorityCriticalDay = 55
    /// Überfällig oder heute fällig.
    private static let priorityDueNow = 50
    /// Einzelgabe heute.
    private static let priorityDoseToday = 40
    /// Läufigkeit läuft, Deckung aber noch nicht bzw. nicht mehr zu erwarten.
    private static let priorityHeatWatch = 35
    /// Fälligkeit innerhalb der Vorwarnzeit.
    private static let priorityDueUpcoming = 30
    /// Einzelgabe in der Zukunft.
    private static let priorityDoseFuture = 20
    /// Zyklus-Prognose — unscharf, deshalb zuletzt.
    private static let priorityCycleForecast = 10

    // MARK: - Kandidaten je Item

    private func notifications(
        for item: DueItem,
        settings: Settings,
        asOf: Date
    ) -> [PlannedNotification] {
        // Einzelgaben tragen ihre Uhrzeit selbst (siehe `Settings.reminderTime`:
        // „Dosis-Erinnerungen nutzen die Zeiten aus dem Dosierschema"). Eine
        // Gabe um 08:00 darf nicht um 09:00 erinnert werden, und eine Vorwarnung
        // „7 Tage vor der Gabe" gibt es nicht.
        if item.category == .dose {
            guard let planned = doseNotification(
                source: item,
                fireDate: item.dueOn,
                settings: settings,
                asOf: asOf
            ) else { return [] }
            return [planned]
        }

        var fireDates: [Date] = []
        for leadDays in settings.leadDays {
            let day = dayMath.adding(days: -leadDays, to: item.dueOn)
            let fireDate = at(settings.reminderTime, on: day)
            guard fireDate >= asOf else { continue }
            guard dayMath.days(from: asOf, to: fireDate) <= settings.horizonDays else { continue }
            fireDates.append(fireDate)
        }

        // Bewusst nach dem Horizont-Filter: bleibt für ein überfälliges oder
        // heute fälliges Item kein Termin übrig, kommt genau eine Erinnerung zum
        // nächsten regulären Zeitpunkt. Nicht rückwirkend — iOS würde einen
        // Termin in der Vergangenheit sofort feuern —, aber auch nicht stumm.
        if fireDates.isEmpty, item.urgency >= .dueToday {
            fireDates = [nextReminderSlot(settings.reminderTime, notBefore: asOf)]
        }

        return fireDates.map { fireDate in
            PlannedNotification(
                id: notificationID(sourceID: item.sourceID, category: item.category, fireDate: fireDate),
                fireDate: fireDate,
                title: headline(petName: item.petName, subject: subject(for: item)),
                body: body(for: item, firingAt: fireDate),
                petID: item.petID,
                category: item.category,
                priority: priority(for: item)
            )
        }
    }

    /// Erinnerung an eine Einzelgabe zum Termin `fireDate`.
    ///
    /// Termine vor `asOf` werden verworfen statt nachgeholt: der Request stand
    /// beim vorigen Planungslauf schon und ist längst gefeuert — nachträglich
    /// wäre er nur eine Fehlmeldung.
    private func doseNotification(
        source item: DueItem,
        fireDate: Date,
        settings: Settings,
        asOf: Date
    ) -> PlannedNotification? {
        guard fireDate >= asOf else { return nil }
        guard dayMath.days(from: asOf, to: fireDate) <= settings.horizonDays else { return nil }

        let base = baseSubject(for: item)
        var text = "\(base): Gabe um \(timeText(fireDate))"
        if let detail = trimmed(item.detail) { text += " — \(detail)" }

        return PlannedNotification(
            id: notificationID(sourceID: item.sourceID, category: .dose, fireDate: fireDate),
            fireDate: fireDate,
            title: headline(petName: item.petName, subject: appending("geben", to: base)),
            body: sentence(text),
            petID: item.petID,
            category: .dose,
            priority: dayMath.isSameDay(fireDate, asOf) ? Self.priorityDoseToday : Self.priorityDoseFuture
        )
    }

    /// Übersetzt einen Tageshinweis in eine geplante Benachrichtigung.
    ///
    /// Titel und Text kommen fertig aus `CriticalDaysAdvisor` — hier wird nur
    /// noch über Zeitpunkt, Priorität und Fenstergrenze entschieden. Die Trennung
    /// hält die fachliche Beurteilung („ab wann ist eine Deckung möglich") von
    /// der Zustellfrage getrennt.
    ///
    /// Ein Hinweis für heute, dessen Erinnerungszeit schon verstrichen ist, wird
    /// verworfen und nicht sofort gefeuert: die App zeigt den Zustand ohnehin auf
    /// dem Dashboard, und eine Benachrichtigung, die in der Sekunde eintrifft, in
    /// der man die App öffnet, ist nur Lärm.
    private func criticalDayNotification(
        _ notice: CriticalDayNotice,
        petID: String,
        settings: Settings,
        asOf: Date
    ) -> PlannedNotification? {
        let fireDate = at(settings.reminderTime, on: notice.date)
        guard fireDate >= asOf else { return nil }
        guard dayMath.days(from: asOf, to: fireDate) <= settings.horizonDays else { return nil }

        return PlannedNotification(
            id: notice.id,
            fireDate: fireDate,
            title: notice.title,
            body: notice.body,
            petID: petID,
            category: .criticalDays,
            priority: notice.risk == .critical ? Self.priorityCriticalDay : Self.priorityHeatWatch
        )
    }

    private func priority(for item: DueItem) -> Int {
        // Prognosen sind die unschärfste Kategorie und fliegen zuerst raus,
        // egal wie dringend das Datum aussieht.
        if item.isForecast || item.category == .cycleForecast { return Self.priorityCycleForecast }

        switch item.category {
        case .dose:
            // Nur der Vollständigkeit wegen: `.dose` läuft über `doseNotification`.
            return Self.priorityDoseFuture
        case .medication, .protectionExpiry:
            return item.urgency >= .dueToday ? Self.priorityDueNow : Self.priorityDueUpcoming
        case .cycleForecast:
            return Self.priorityCycleForecast
        case .criticalDays:
            // Erreichbar nur, wenn irgendwann ein `DueItem` mit dieser Kategorie
            // gebaut wird — Tageshinweise laufen über `criticalDayNotification`.
            // Dieselbe Einstufung wie dort, damit beide Wege nicht auseinanderlaufen.
            return Self.priorityCriticalDay
        }
    }

    // MARK: - Termine

    /// `time` am Kalendertag von `day`.
    ///
    /// Über `DateComponents` und nicht über `date(bySettingHour:)`, weil dessen
    /// „nächster passender Zeitpunkt"-Politik bei `00:00` auf den Folgetag
    /// springen kann — und nicht über Minuten-Addition auf Mitternacht, weil die
    /// an Zeitumstellungstagen die Uhrzeit um eine Stunde verschiebt.
    private func at(_ time: TimeOfDay, on day: Date) -> Date {
        let midnight = dayMath.startOfDay(day)
        var parts = dayMath.calendar.dateComponents([.year, .month, .day], from: midnight)
        parts.hour = time.hour
        parts.minute = time.minute
        parts.second = 0
        return dayMath.calendar.date(from: parts) ?? midnight
    }

    /// Der nächste `time`-Zeitpunkt, der nicht vor `notBefore` liegt: heute,
    /// wenn die Uhrzeit noch kommt, sonst morgen.
    private func nextReminderSlot(_ time: TimeOfDay, notBefore: Date) -> Date {
        let today = at(time, on: notBefore)
        if today >= notBefore { return today }
        return at(time, on: dayMath.adding(days: 1, to: notBefore))
    }

    /// Stabil über Neuplanungen: gleiche Quelle + gleicher Termin ⇒ gleiche ID,
    /// damit iOS den ausstehenden Request ersetzt statt zu duplizieren. Bewusst
    /// ohne UUID und ohne `Date()` — beides würde bei jedem Lauf neue Requests
    /// erzeugen und das 64er-Limit sprengen.
    private func notificationID(
        sourceID: String,
        category: DueItem.Category,
        fireDate: Date
    ) -> String {
        "rudel.\(category.rawValue).\(sourceID).\(Int(fireDate.timeIntervalSince1970))"
    }

    // MARK: - Texte

    /// „Zola — Wurmkur fällig". Ohne Tiernamen bleibt der Vorgang allein stehen.
    private func headline(petName: String, subject: String) -> String {
        guard let name = trimmed(petName) else { return subject }
        return "\(name) — \(subject)"
    }

    /// Der Vorgang ohne Verb — `DueItem.title`, oder ein Ersatz, falls der
    /// Titel leer ist.
    private func baseSubject(for item: DueItem) -> String {
        if let title = trimmed(item.title) { return title }
        switch item.category {
        case .medication: return "Behandlung"
        case .protectionExpiry: return "Schutz"
        case .dose: return "Medikament"
        case .cycleForecast: return "Läufigkeit"
        case .criticalDays: return "Kritische Tage"
        }
    }

    private func subject(for item: DueItem) -> String {
        let base = baseSubject(for: item)
        switch item.category {
        case .medication: return appending("fällig", to: base)
        case .protectionExpiry: return appending("läuft ab", to: base)
        case .dose: return appending("geben", to: base)
        case .cycleForecast: return appending("erwartet", to: base)
        // Kein Verb: „Kritische Tage" beschreibt einen Zustand, keine Fälligkeit.
        case .criticalDays: return base
        }
    }

    /// Hängt das Verb nur an, wenn der Titel es nicht schon trägt: `DueItem.title`
    /// ist normalerweise das nackte Substantiv („Wurmkur"), aber manche Titel
    /// formulieren die Fälligkeit bereits mit („Läufigkeit erwartet") — dann wäre
    /// die Wiederholung im Titel peinlich.
    private func appending(_ verb: String, to title: String) -> String {
        title.lowercased().contains(verb.lowercased()) ? title : "\(title) \(verb)"
    }

    private func body(for item: DueItem, firingAt fireDate: Date) -> String {
        // Relativ zum **Termin der Erinnerung**, nicht zum Planungslauf:
        // `DueItem.daysUntilDue` gilt für `asOf`, eine Erinnerung sieben Tage
        // später würde damit falsch texten.
        let days = dayMath.days(from: fireDate, to: item.dueOn)
        let base = baseSubject(for: item)
        var text: String

        if item.isForecast || item.category == .cycleForecast {
            text = "\(base): erwartet ab \(dateText(item.dueOn)) (\(relativeDayText(days)))."
                + " Prognose, keine Gewissheit — bitte auf erste Anzeichen achten"
        } else {
            switch item.category {
            case .protectionExpiry:
                text = "\(base): \(protectionPhrase(days: days, expiresOn: item.dueOn))"
            case .criticalDays:
                // Zustand statt Termin — `duenessPhrase` („in 3 Tagen fällig")
                // wäre hier sprachlich falsch.
                text = "\(base): \(relativeDayText(days))"
            case .medication, .dose, .cycleForecast:
                text = "\(base) \(duenessPhrase(days: days, dueOn: item.dueOn))"
            }
        }

        if let detail = trimmed(item.detail) { text += " — \(detail)" }
        return sentence(text)
    }

    /// Schließt den Satz ab, ohne einen Punkt zu verdoppeln — `DueItem.detail`
    /// kommt aus der App-Schicht und bringt manchmal schon einen mit.
    private func sentence(_ text: String) -> String {
        text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") ? text : text + "."
    }

    private func duenessPhrase(days: Int, dueOn: Date) -> String {
        switch days {
        case ..<0:
            return "war am \(dateText(dueOn)) fällig — \(overdueText(-days))"
        case 0:
            return "ist heute fällig"
        case 1:
            return "ist morgen fällig (\(dateText(dueOn)))"
        default:
            return "ist in \(days) Tagen fällig (\(dateText(dueOn)))"
        }
    }

    private func protectionPhrase(days: Int, expiresOn: Date) -> String {
        switch days {
        case ..<0:
            return "der Schutz ist am \(dateText(expiresOn)) abgelaufen — \(overdueText(-days))"
        case 0:
            return "der Schutz läuft heute ab"
        case 1:
            return "der Schutz läuft morgen ab (\(dateText(expiresOn)))"
        default:
            return "der Schutz läuft in \(days) Tagen ab (\(dateText(expiresOn)))"
        }
    }

    private func overdueText(_ days: Int) -> String {
        days == 1 ? "seit 1 Tag überfällig" : "seit \(days) Tagen überfällig"
    }

    private func relativeDayText(_ days: Int) -> String {
        switch days {
        case ..<(-1): return "seit \(-days) Tagen"
        case -1: return "seit gestern"
        case 0: return "heute"
        case 1: return "morgen"
        default: return "in \(days) Tagen"
        }
    }

    /// Bewusst von Hand statt mit `DateFormatter`: die Engine soll unabhängig
    /// von der Locale des Geräts immer das deutsche Format liefern — und Tests
    /// sollen auf jeder Maschine denselben String sehen.
    private func dateText(_ date: Date) -> String {
        let parts = dayMath.calendar.dateComponents([.day, .month, .year], from: date)
        guard let day = parts.day, let month = parts.month, let year = parts.year else { return "" }
        return String(format: "%02d.%02d.%04d", day, month, year)
    }

    private func timeText(_ date: Date) -> String {
        let parts = dayMath.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func trimmed(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
