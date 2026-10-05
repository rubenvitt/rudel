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
        /// Opake ID des zugrundeliegenden Plans, sofern vorhanden.
        public var sourceID: String
        /// Ursprünglicher Fälligkeitstermin. Bei Vorwarnungen ist dieser später
        /// als `fireDate`; Dosis-Termine tragen hier ihre planmäßige Gabezeit.
        public var dueAt: Date?
        /// Optionales Wiederholungsintervall für App-seitig erzeugte Fallbacks.
        /// Der Standardplaner erzeugt ausschließlich einmalige Termine.
        public var repeatInterval: TimeInterval?
        /// Priorität für den Fall, dass gekürzt werden muss. Höher = wichtiger.
        public var priority: Int

        public init(
            id: String,
            fireDate: Date,
            title: String,
            body: String,
            petID: String,
            category: DueItem.Category,
            priority: Int,
            sourceID: String = "",
            dueAt: Date? = nil,
            repeatInterval: TimeInterval? = nil
        ) {
            self.id = id
            self.fireDate = fireDate
            self.title = title
            self.body = body
            self.petID = petID
            self.category = category
            self.priority = priority
            self.sourceID = sourceID
            self.dueAt = dueAt
            self.repeatInterval = repeatInterval
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
        /// Wie viele Minuten vor einem Tierarzttermin zusätzlich zur Mitteilung
        /// am Vortag erinnert wird. Negative Werte werden zu 0 (zum Terminbeginn).
        public var appointmentLeadMinutes: Int

        public init(
            leadDays: [Int] = [7, 1, 0],
            reminderTime: TimeOfDay = TimeOfDay(hour: 9),
            horizonDays: Int = 14,
            appointmentLeadMinutes: Int = 120
        ) {
            self.leadDays = leadDays.sorted(by: >)
            self.reminderTime = reminderTime
            self.horizonDays = max(1, horizonDays)
            self.appointmentLeadMinutes = max(0, appointmentLeadMinutes)
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
    ///   - medicationReminders: Vollständige Engine-Termine. Wenn gesetzt, ist
    ///     diese Liste für Dosis-Benachrichtigungen maßgeblich; Dashboard-Dosen
    ///     und `doseOccurrences` werden dann nicht berücksichtigt.
    ///   - criticalDays: Tageshinweise einer laufenden Läufigkeit aus
    ///     `CriticalDaysAdvisor`, geschlüsselt nach **`petID`**.
    ///
    ///     Anders als `doseOccurrences` bewusst nach dem Tier und nicht nach der
    ///     Quelle geschlüsselt: eine `CriticalDayNotice` bringt Titel und Text
    ///     schon mit, ihr fehlt nur die `petID`. Über den Schlüssel kommt sie
    ///     direkt herein, statt aus einem passenden `DueItem` erschlossen werden
    ///     zu müssen — genau die Abhängigkeit, an der Dosis-Termine ohne
    ///     Gegenstück verworfen werden müssen.
    ///   - alarmHandledReminders: Termine, deren Fälligkeitsbenachrichtigung ein
    ///     Alarm übernimmt. Vorab-Erinnerungen derselben Fälligkeit bleiben.
    ///   - settings: Vorwarnzeiten und Fensterlänge.
    ///   - asOf: „jetzt". Termine in der Vergangenheit werden verworfen — iOS
    ///     würde sie sofort feuern.
    ///
    /// ## Priorisierung beim Kürzen auf `budget`
    ///
    /// 1. Tage, an denen eine Deckung möglich ist (höchste Priorität — die
    ///    einzige Kategorie, deren Versäumnis irreversibel ist)
    /// 2. Überfällige und heute fällige Fälligkeiten
    /// 3. Tierarzttermine (Vortag und kurz vorher)
    /// 4. Heutige Einzelgaben
    /// 5. Läufigkeit läuft, Deckung aber noch nicht bzw. nicht mehr zu erwarten
    /// 6. Fälligkeiten innerhalb der Vorwarnzeit, näher = wichtiger
    /// 7. Vorrat geht zur Neige (höchstens eine Mitteilung pro Plan und Lauf)
    /// 8. Künftige Einzelgaben, chronologisch
    /// 9. Zyklus-Prognosen (unscharf, deshalb zuletzt)
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
        medicationReminders: [MedicationReminder]? = nil,
        criticalDays: [String: [CriticalDayNotice]] = [:],
        alarmHandledReminders: [MedicationReminder] = [],
        settings: Settings,
        asOf: Date
    ) -> [PlannedNotification] {
        var candidates: [PlannedNotification] = []

        // Metadaten je Quelle. `doseOccurrences` ist nach der opaken `sourceID`
        // geschlüsselt und trägt weder Tiernamen noch Präparat — beides kommt
        // nur aus einem `DueItem` derselben Quelle.
        var metaBySource: [String: DueItem] = [:]
        for item in dueItems where item.category != .restock {
            // Ein `.dose`-Item beschreibt die Gabe am genauesten; sonst reicht
            // jedes Item derselben Quelle für Name und Bezeichnung.
            if let known = metaBySource[item.sourceID], known.category == .dose { continue }
            metaBySource[item.sourceID] = item
        }

        for item in dueItems where medicationReminders == nil || item.category != .dose {
            candidates.append(contentsOf: notifications(for: item, settings: settings, asOf: asOf))
        }

        if let medicationReminders {
            for reminder in medicationReminders where reminder.category == .dose {
                guard let planned = doseNotification(
                    reminder: reminder,
                    settings: settings,
                    asOf: asOf
                ) else { continue }
                candidates.append(planned)
            }
        } else {
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

        // Vor dem Ranking entfernen: sonst belegen später verworfene
        // Alarm-Termine bereits Plätze im 56er-Budget. `fireDate == dueAt`
        // schützt Vorab-Erinnerungen, die dieselbe Fälligkeit referenzieren.
        if !alarmHandledReminders.isEmpty {
            let handled = Set(alarmHandledReminders.map {
                MedicationOccurrenceKey(
                    sourceID: $0.sourceID,
                    category: $0.category,
                    dueAt: $0.dueAt
                )
            })
            candidates.removeAll { candidate in
                guard let dueAt = candidate.dueAt, candidate.fireDate == dueAt else {
                    return false
                }
                return handled.contains(
                    MedicationOccurrenceKey(
                        sourceID: candidate.sourceID,
                        category: candidate.category,
                        dueAt: dueAt
                    )
                )
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

    private struct MedicationOccurrenceKey: Hashable {
        var sourceID: String
        var category: DueItem.Category
        var dueAt: Date
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
    /// Tierarzttermin. Über den heutigen Gaben, weil ein verpasster Termin
    /// Wochen kostet, eine verspätete Gabe meist nur Stunden; unter „fällig
    /// jetzt", weil der Termin feststeht und die Praxis notfalls anruft.
    private static let priorityAppointment = 45
    /// Einzelgabe heute.
    private static let priorityDoseToday = 40
    /// Läufigkeit läuft, Deckung aber noch nicht bzw. nicht mehr zu erwarten.
    private static let priorityHeatWatch = 35
    /// Fälligkeit innerhalb der Vorwarnzeit.
    private static let priorityDueUpcoming = 30
    /// Vorrat geht zur Neige. Unter fälligen Behandlungen — nachkaufen hat
    /// meist ein paar Tage Luft —, aber vor künftigen Einzelgaben, die bis
    /// zu ihrem Tag ohnehin neu geplant werden.
    private static let priorityRestock = 25
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
        // Eigener Zweig, bevor der generische Pfad greift: ein begonnener Termin
        // steht bis zum Abschluss als `.dueToday` auf dem Dashboard, und der
        // „nächster Slot"-Rückfall unten würde dann täglich erinnern.
        if item.category == .vetAppointment {
            return appointmentNotifications(for: item, settings: settings, asOf: asOf)
        }
        // Ebenfalls eigener Zweig: der Vorrat hat keine Vorwarnzeiten, und die
        // Vorwarnungen des generischen Pfads ergäben mehrere Mitteilungen.
        if item.category == .restock {
            return restockNotifications(for: item, settings: settings, asOf: asOf)
        }

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

        // Ohne geplanten Termin ist der nächste Schritt der Anruf in der Praxis,
        // nicht die Gabe — das muss schon in der Überschrift stehen.
        let title = item.needsVetAppointment
            ? headline(petName: item.petName, subject: "Tierarzttermin vereinbaren")
            : headline(petName: item.petName, subject: subject(for: item))

        return fireDates.map { fireDate in
            var text = body(for: item, firingAt: fireDate)
            if item.needsVetAppointment { text += " Termin beim Tierarzt vereinbaren." }
            return PlannedNotification(
                id: notificationID(sourceID: item.sourceID, category: item.category, fireDate: fireDate),
                fireDate: fireDate,
                title: title,
                body: text,
                petID: item.petID,
                category: item.category,
                priority: priority(for: item),
                sourceID: item.sourceID,
                dueAt: at(settings.reminderTime, on: item.dueOn)
            )
        }
    }

    /// Mitteilungen zu einem Tierarzttermin: am Vortag zur Erinnerungszeit und
    /// `appointmentLeadMinutes` vor Beginn.
    ///
    /// Beide nur, wenn sie noch kommen und im Fenster liegen. Nach Terminbeginn
    /// gibt es nichts mehr — anders als bei einer Fälligkeit wäre „überfällig"
    /// hier falsch: der Termin hat stattgefunden oder ist verpasst, beides klärt
    /// der Abschluss in der App, nicht eine Mitteilung.
    private func appointmentNotifications(
        for item: DueItem,
        settings: Settings,
        asOf: Date
    ) -> [PlannedNotification] {
        let start = item.dueOn
        guard start >= asOf else { return [] }

        let dayBefore = at(settings.reminderTime, on: dayMath.adding(days: -1, to: start))
        let shortlyBefore = start.addingTimeInterval(-TimeInterval(settings.appointmentLeadMinutes * 60))

        return [dayBefore, shortlyBefore]
            .filter { $0 >= asOf && dayMath.days(from: asOf, to: $0) <= settings.horizonDays }
            .map { fireDate in
                PlannedNotification(
                    id: notificationID(sourceID: item.sourceID, category: .vetAppointment, fireDate: fireDate),
                    fireDate: fireDate,
                    title: headline(petName: item.petName, subject: "Tierarzttermin"),
                    body: appointmentBody(for: item, firingAt: fireDate),
                    petID: item.petID,
                    category: .vetAppointment,
                    priority: Self.priorityAppointment,
                    sourceID: item.sourceID,
                    dueAt: start
                )
            }
    }

    /// Genau eine Mitteilung zum nächsten Erinnerungszeitpunkt. Weil jeder
    /// Planungslauf nur diese eine setzt und ihre ID am Zeitpunkt hängt, kommt
    /// höchstens eine pro Tag — und nur, solange der Vorrat knapp bleibt.
    /// Nie ein Alarm: das Item gelangt nicht in `MedicationReminderPlanner`.
    private func restockNotifications(
        for item: DueItem,
        settings: Settings,
        asOf: Date
    ) -> [PlannedNotification] {
        let fireDate = nextReminderSlot(settings.reminderTime, notBefore: asOf)
        guard dayMath.days(from: asOf, to: fireDate) <= settings.horizonDays else { return [] }

        return [
            PlannedNotification(
                id: notificationID(sourceID: item.sourceID, category: .restock, fireDate: fireDate),
                fireDate: fireDate,
                title: headline(petName: item.petName, subject: baseSubject(for: item)),
                body: restockBody(for: item, firingAt: fireDate),
                petID: item.petID,
                category: .restock,
                priority: Self.priorityRestock,
                sourceID: item.sourceID
            )
        ]
    }

    /// „Reicht noch etwa 5 Tage. Rezept beim Tierarzt anfordern." Die Tage
    /// zählen ab der Mitteilung, nicht ab dem Planungslauf.
    private func restockBody(for item: DueItem, firingAt fireDate: Date) -> String {
        let days = dayMath.days(from: fireDate, to: item.dueOn)
        var text: String
        switch days {
        case ..<1: text = "Reicht nicht mehr für die nächste Gabe."
        case 1: text = "Reicht noch etwa 1 Tag."
        default: text = "Reicht noch etwa \(days) Tage."
        }
        if item.stock?.needsPrescription == true {
            text += " Rezept beim Tierarzt anfordern."
        }
        return text
    }

    /// „Morgen um 10:30 · Impfung · Praxis am Park." Der Tag ergibt sich aus dem
    /// Abstand zwischen Mitteilung und Termin, nicht daraus, welche der beiden
    /// Mitteilungen es ist: zwei Stunden vor einem Termin um 01:00 ist noch
    /// der Vorabend.
    private func appointmentBody(for item: DueItem, firingAt fireDate: Date) -> String {
        let days = dayMath.days(from: fireDate, to: item.dueOn)
        let dayWord: String
        switch days {
        case 0: dayWord = "Heute"
        case 1: dayWord = "Morgen"
        default: dayWord = "Am \(dateText(item.dueOn))"
        }

        var parts = ["\(dayWord) um \(timeText(item.dueOn))"]
        // Der Titel steht nur im Text, wenn er mehr sagt als die Überschrift.
        if let title = trimmed(item.title), title != "Tierarzttermin" { parts.append(title) }
        if let detail = trimmed(item.detail) { parts.append(detail) }
        return sentence(parts.joined(separator: " · "))
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
            priority: dayMath.isSameDay(fireDate, asOf) ? Self.priorityDoseToday : Self.priorityDoseFuture,
            sourceID: item.sourceID,
            dueAt: fireDate
        )
    }

    /// Dosis-Erinnerung mit vollständigen Metadaten aus dem authoritative Plan.
    private func doseNotification(
        reminder: MedicationReminder,
        settings: Settings,
        asOf: Date
    ) -> PlannedNotification? {
        guard reminder.dueAt >= asOf else { return nil }
        guard dayMath.days(from: asOf, to: reminder.dueAt) <= settings.horizonDays else { return nil }

        let base = trimmed(reminder.title) ?? "Medikament"
        var text = "\(base): Gabe um \(timeText(reminder.dueAt))"
        if let detail = trimmed(reminder.detail) { text += " — \(detail)" }

        return PlannedNotification(
            id: reminder.id,
            fireDate: reminder.dueAt,
            title: headline(petName: reminder.petName, subject: appending("geben", to: base)),
            body: sentence(text),
            petID: reminder.petID,
            category: .dose,
            priority: dayMath.isSameDay(reminder.dueAt, asOf)
                ? Self.priorityDoseToday
                : Self.priorityDoseFuture,
            sourceID: reminder.sourceID,
            dueAt: reminder.dueAt
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
        case .vetAppointment:
            // Nur der Vollständigkeit wegen: Termine laufen über
            // `appointmentNotifications`.
            return Self.priorityAppointment
        case .restock:
            // Nur der Vollständigkeit wegen: läuft über `restockNotifications`.
            return Self.priorityRestock
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
        case .vetAppointment: return "Tierarzttermin"
        case .restock: return "Vorrat"
        }
    }

    /// Ist `dueOn` eines Schutz-Items wirklich das Ende des Schutzes?
    ///
    /// Nur, wenn `protectionEndsOn` auf denselben Tag fällt. Auslassung und
    /// Zurückstellung — auch eine schon verstrichene — schieben `dueOn` hinter
    /// das Schutzende; „der Schutz läuft am 1. März ab" wäre dann falsch, er ist
    /// längst weg. Ohne Gabe gab es nie einen Schutz, der ablaufen könnte.
    private func dueOnIsProtectionEnd(_ item: DueItem) -> Bool {
        guard let protectionEndsOn = item.protectionEndsOn else { return false }
        return dayMath.isSameDay(protectionEndsOn, item.dueOn)
    }

    private func subject(for item: DueItem) -> String {
        let base = baseSubject(for: item)
        switch item.category {
        case .medication: return appending("fällig", to: base)
        case .protectionExpiry:
            return appending(dueOnIsProtectionEnd(item) ? "läuft ab" : "fällig", to: base)
        case .dose: return appending("geben", to: base)
        case .cycleForecast: return appending("erwartet", to: base)
        // Kein Verb: „Kritische Tage" beschreibt einen Zustand, keine Fälligkeit.
        case .criticalDays: return base
        // Kein Verb: ein Termin ist weder fällig noch läuft er ab.
        case .vetAppointment: return base
        case .restock: return base
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
            case .protectionExpiry where !dueOnIsProtectionEnd(item):
                text = "\(base) \(duenessPhrase(days: days, dueOn: item.dueOn))"
            case .protectionExpiry:
                text = "\(base): \(protectionPhrase(days: days, expiresOn: item.dueOn))"
            case .criticalDays:
                // Zustand statt Termin — `duenessPhrase` („in 3 Tagen fällig")
                // wäre hier sprachlich falsch.
                text = "\(base): \(relativeDayText(days))"
            case .medication, .dose, .cycleForecast:
                text = "\(base) \(duenessPhrase(days: days, dueOn: item.dueOn))"
            case .vetAppointment:
                // Unerreichbar über `plan`: Termine texten in `appointmentBody`.
                text = "\(base) \(relativeDayText(days)) um \(timeText(item.dueOn))"
            case .restock:
                // Unerreichbar über `plan`: Vorrat textet in `restockBody`.
                text = "\(base) reicht bis \(dateText(item.dueOn))"
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
