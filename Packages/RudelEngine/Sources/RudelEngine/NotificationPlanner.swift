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
    ///   - settings: Vorwarnzeiten und Fensterlänge.
    ///   - asOf: „jetzt". Termine in der Vergangenheit werden verworfen — iOS
    ///     würde sie sofort feuern.
    ///
    /// ## Priorisierung beim Kürzen auf `budget`
    ///
    /// 1. Überfällige und heute fällige Fälligkeiten (höchste Priorität)
    /// 2. Heutige Einzelgaben
    /// 3. Fälligkeiten innerhalb der Vorwarnzeit, näher = wichtiger
    /// 4. Künftige Einzelgaben, chronologisch
    /// 5. Zyklus-Prognosen (unscharf, deshalb zuletzt)
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
    public func plan(
        dueItems: [DueItem],
        doseOccurrences: [String: [Date]],
        settings: Settings,
        asOf: Date
    ) -> [PlannedNotification] {
        fatalError("unimplemented")
    }
}
