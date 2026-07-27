import Foundation

/// Art einer Gabe. Die vier Fälle unterscheiden sich nur darin, *wie* sich
/// Fälligkeit ergibt:
/// - `dewormer`: letzte Gabe + konfiguriertes Intervall
/// - `tickProtection`: letzte Gabe + Wirkdauer, mit Restwirksamkeits-Balken
/// - `ongoing`: Dosierschema, tägliches Abhaken
/// - `rabiesVaccination`: Datum + Gültigkeitsdauer — rechnerisch identisch zu
///   `tickProtection`, deshalb hier statt in einem eigenen Impfpass-Modul
///   (PRD §11). Ein vollständiger Impfpass mit weiteren Impfungen und
///   Reisedokumenten bleibt bewusst außen vor.
public enum MedicationKind: String, Sendable, Codable, CaseIterable, Hashable {
    case dewormer
    case tickProtection
    case ongoing
    case rabiesVaccination

    /// Rechnet dieser Typ mit einer Wirkdauer (Restwirksamkeit) statt mit
    /// einem Wiederholungsintervall?
    public var usesEffectivePeriod: Bool {
        switch self {
        case .tickProtection, .rabiesVaccination: return true
        case .dewormer, .ongoing: return false
        }
    }
}

/// Uhrzeit ohne Datum, für Dosis-Erinnerungen.
public struct TimeOfDay: Sendable, Codable, Equatable, Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    /// Klemmt auf gültige Werte, statt zu werfen — ein ungültiger Wert aus
    /// altem Persistenz-Stand darf die App nicht abstürzen lassen.
    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public var minutesFromMidnight: Int { hour * 60 + minute }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }
}

/// Dosierschema eines laufenden Medikaments.
public struct DoseSchedule: Sendable, Codable, Equatable, Hashable {
    /// Zu welchen Uhrzeiten am Tag gegeben wird. Leer = keine Erinnerung.
    public var timesOfDay: [TimeOfDay]
    /// Jeden n-ten Tag. 1 = täglich, 2 = jeden zweiten Tag.
    public var everyNDays: Int
    public var startDate: Date
    /// `nil` = unbefristet.
    public var endDate: Date?
    /// Freitext, z. B. „1/2 Tablette".
    public var doseLabel: String

    public init(
        timesOfDay: [TimeOfDay],
        everyNDays: Int = 1,
        startDate: Date,
        endDate: Date? = nil,
        doseLabel: String = ""
    ) {
        self.timesOfDay = timesOfDay.sorted()
        self.everyNDays = max(1, everyNDays)
        self.startDate = startDate
        self.endDate = endDate
        self.doseLabel = doseLabel
    }

    /// Anzahl Gaben pro Gabetag.
    public var dosesPerDay: Int { max(1, timesOfDay.count) }
}

/// Restwirksamkeit eines Schutzes (Zeckenschutz, Tollwut-Gültigkeit).
public struct ProtectionStatus: Sendable, Equatable, Hashable {
    /// 0…1. Bei abgelaufenem Schutz genau 0, nie negativ — der UI-Balken soll
    /// nicht rückwärts laufen. Wie weit der Schutz überfällig ist, steht in
    /// `remainingDays` (dann negativ).
    public var remainingFraction: Double
    /// Verbleibende Tage. Negativ, wenn der Schutz abgelaufen ist.
    public var remainingDays: Int
    public var expiresOn: Date
    public var isExpired: Bool

    public init(remainingFraction: Double, remainingDays: Int, expiresOn: Date, isExpired: Bool) {
        self.remainingFraction = remainingFraction
        self.remainingDays = remainingDays
        self.expiresOn = expiresOn
        self.isExpired = isExpired
    }
}

/// Fälligkeit einer intervallbasierten Gabe (Wurmkur).
public struct IntervalDueness: Sendable, Equatable, Hashable {
    public var dueOn: Date
    /// Negativ, wenn überfällig.
    public var daysUntilDue: Int
    public var isOverdue: Bool

    public init(dueOn: Date, daysUntilDue: Int, isOverdue: Bool) {
        self.dueOn = dueOn
        self.daysUntilDue = daysUntilDue
        self.isOverdue = isOverdue
    }
}

// MARK: - Dashboard

/// Dringlichkeitsstufe für die Dashboard-Sortierung (PRD §5.6).
public enum Urgency: Int, Sendable, Codable, CaseIterable, Comparable, Hashable {
    case scheduled = 0   // > 14 Tage hin
    case upcoming = 1    // 4–14 Tage
    case dueSoon = 2     // 1–3 Tage
    case dueToday = 3
    case overdue = 4

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Stuft anhand der Tage bis zur Fälligkeit ein.
    public init(daysUntilDue: Int) {
        switch daysUntilDue {
        case ..<0: self = .overdue
        case 0: self = .dueToday
        case 1...3: self = .dueSoon
        case 4...14: self = .upcoming
        default: self = .scheduled
        }
    }
}

/// Was auf dem Dashboard steht. Die Engine kennt keine SwiftData-IDs:
/// `sourceID` und `petID` sind opake Strings, die die App-Schicht aus
/// `PersistentIdentifier`/UUID befüllt.
public struct DueItem: Sendable, Equatable, Hashable, Identifiable {
    public enum Category: String, Sendable, Codable, CaseIterable, Hashable {
        case medication
        case protectionExpiry
        case dose
        case cycleForecast
        /// Tageshinweis während einer laufenden Läufigkeit — siehe
        /// `CriticalDaysAdvisor`. Kein Fälligkeitstermin, sondern ein Zustand,
        /// der über Wochen anhält.
        case criticalDays
    }

    public var id: String
    public var sourceID: String
    public var petID: String
    public var petName: String
    public var category: Category
    public var title: String
    public var detail: String?
    public var dueOn: Date
    public var daysUntilDue: Int
    public var urgency: Urgency
    /// Für Zeckenschutz/Tollwut: Restwirksamkeit für den Balken. Sonst `nil`.
    public var remainingFraction: Double?
    /// Prognosen sind unscharf — bei `cycleForecast` steht hier das Band.
    public var isForecast: Bool

    public init(
        id: String,
        sourceID: String,
        petID: String,
        petName: String,
        category: Category,
        title: String,
        detail: String? = nil,
        dueOn: Date,
        daysUntilDue: Int,
        urgency: Urgency,
        remainingFraction: Double? = nil,
        isForecast: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.petID = petID
        self.petName = petName
        self.category = category
        self.title = title
        self.detail = detail
        self.dueOn = dueOn
        self.daysUntilDue = daysUntilDue
        self.urgency = urgency
        self.remainingFraction = remainingFraction
        self.isForecast = isForecast
    }
}
