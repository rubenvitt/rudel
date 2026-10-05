import Foundation

/// Art einer Gabe. Die Fälle unterscheiden sich nur darin, *wie* sich
/// Fälligkeit ergibt:
/// - `dewormer`: letzte Gabe + konfiguriertes Intervall
/// - `tickProtection`: letzte Gabe + Wirkdauer, mit Restwirksamkeits-Balken
/// - `ongoing`: Dosierschema, tägliches Abhaken
/// - `rabiesVaccination`: Datum + Gültigkeitsdauer — rechnerisch identisch zu
///   `tickProtection`, deshalb hier statt in einem eigenen Impfpass-Modul
///   (PRD §11).
/// - `vaccination`: jede weitere Impfung (`VaccineType`), rechnet wie Tollwut.
///   Tollwut bleibt eine eigene Art, damit Bestandspläne unverändert bleiben.
public enum MedicationKind: String, Sendable, Codable, CaseIterable, Hashable {
    case dewormer
    case tickProtection
    case ongoing
    case rabiesVaccination
    case vaccination

    /// Tollwut oder eine andere Impfung — beide stehen gemeinsam im Impfpass.
    public var isVaccination: Bool {
        switch self {
        case .rabiesVaccination, .vaccination: return true
        case .dewormer, .tickProtection, .ongoing: return false
        }
    }

    /// Rechnet dieser Typ mit einer Wirkdauer (Restwirksamkeit) statt mit
    /// einem Wiederholungsintervall?
    public var usesEffectivePeriod: Bool {
        switch self {
        case .tickProtection, .rabiesVaccination, .vaccination: return true
        case .dewormer, .ongoing: return false
        }
    }

    /// Erinnerungsklasse, wenn der Plan keine eigene festlegt. Nur ein
    /// Dauermedikament hängt an der Uhrzeit; Wurmkur, Zeckenschutz und Impfung
    /// vertragen einen Tag Verzug und sollen deshalb nie einen Wecker auslösen.
    public var defaultCareClass: MedicationCareClass {
        switch self {
        case .ongoing: return .timeCritical
        case .dewormer, .tickProtection, .rabiesVaccination, .vaccination: return .preventive
        }
    }

    /// Braucht die Gabe standardmäßig einen Tierarzttermin? Nur die Impfung —
    /// Wurmkur und Zeckenschutz gibt man selbst.
    public var defaultRequiresVetVisit: Bool {
        switch self {
        case .rabiesVaccination, .vaccination: return true
        case .dewormer, .tickProtection, .ongoing: return false
        }
    }
}

/// Wie aufdringlich an eine Gabe erinnert wird.
///
/// - `timeCritical`: Vorwarnung, Alarm, Schlummern, Bestätigung — für Gaben,
///   bei denen die Uhrzeit zählt.
/// - `preventive`: ausschließlich normale Mitteilungen über die Vorwarnzeiten
///   in Tagen. Vorsorge darf nie einen Wecker auslösen und lässt sich auslassen
///   oder zurückstellen.
public enum MedicationCareClass: String, Sendable, Codable, CaseIterable, Hashable {
    case timeCritical
    case preventive
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
        /// Ein geplanter Tierarzttermin. `dueOn` trägt die Uhrzeit des
        /// Termins, nicht Mitternacht.
        case vetAppointment
        /// Der Vorrat eines Medikaments geht zur Neige. `dueOn` ist der Tag
        /// der ersten Gabe, für die er nicht mehr reicht. Nur Mitteilung, nie
        /// Alarm.
        case restock
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
    /// Erinnerungsklasse des Plans. Nur bei `.medication`, `.protectionExpiry`
    /// und `.dose` gesetzt, sonst `nil`.
    public var careClass: MedicationCareClass?
    /// Die Gabe braucht einen Tierarzttermin, und es ist noch keiner geplant.
    /// Titel und Fälligkeit bleiben; die UI bietet „Termin anlegen" an.
    public var needsVetAppointment: Bool
    /// Bis wann der Plan zurückgestellt ist — gesetzt nur, solange die
    /// Zurückstellung die Fälligkeit tatsächlich in die Zukunft schiebt, damit
    /// die UI „zurückgestellt bis …" nicht für eine verstrichene oder wirkungslose
    /// Zurückstellung zeigt. Eine verstrichene Zurückstellung kann `dueOn`
    /// trotzdem weiter verschieben — ob `dueOn` das Schutzende ist, sagt deshalb
    /// nur `protectionEndsOn`.
    public var deferredUntil: Date?
    /// Für Zeckenschutz/Tollwut: Tag, an dem der Schutz der letzten echten Gabe
    /// endet (`lastGivenOn + effectiveDays`). `nil` ohne Gabe und bei anderen
    /// Kategorien. Weicht von `dueOn` ab, sobald eine Auslassung oder
    /// Zurückstellung die Fälligkeit verschoben hat.
    public var protectionEndsOn: Date?
    /// Nur bei `.restock`: Restbestand und Reichweite.
    public var stock: StockProjection?

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
        isForecast: Bool = false,
        careClass: MedicationCareClass? = nil,
        needsVetAppointment: Bool = false,
        deferredUntil: Date? = nil,
        protectionEndsOn: Date? = nil,
        stock: StockProjection? = nil
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
        self.careClass = careClass
        self.needsVetAppointment = needsVetAppointment
        self.deferredUntil = deferredUntil
        self.protectionEndsOn = protectionEndsOn
        self.stock = stock
    }
}

// MARK: - Vorrat

/// Vorratsangaben eines Plans. Der Restbestand wird nicht heruntergezählt,
/// sondern abgeleitet: Bestand bei der Zählung minus Gaben seit der Zählung
/// mal Menge je Gabe. Die Gaben zählt die App-Schicht aus dem Journal — so
/// korrigiert ein gelöschter Fehleintrag den Bestand von selbst.
public struct StockInput: Sendable, Equatable, Hashable {
    /// Bestand bei der letzten Zählung.
    public var amountAtCount: Double
    /// Gaben (ohne Auslassungen), die nach der Zählung erfasst wurden.
    public var givingsSinceCount: Int
    /// Menge je Gabe, z. B. 0,5 Tabletten.
    public var amountPerGiving: Double
    /// Freitext, z. B. „Tabletten".
    public var unit: String
    /// Ab welcher Reichweite in Tagen erinnert wird.
    public var restockLeadDays: Int
    public var needsPrescription: Bool
    /// Wie viele der **heutigen** Einzelgaben eines Dauermedikaments schon
    /// erfasst sind (gegeben oder ausgelassen). Die Projektion beginnt am
    /// Tagesanfang; ohne diese Zahl zählte eine heute schon gegebene Tablette
    /// doppelt — einmal in `givingsSinceCount`, einmal als künftige Gabe.
    public var dosesHandledToday: Int

    public init(
        amountAtCount: Double,
        givingsSinceCount: Int = 0,
        amountPerGiving: Double = 1,
        unit: String = "",
        restockLeadDays: Int = 7,
        needsPrescription: Bool = false,
        dosesHandledToday: Int = 0
    ) {
        self.amountAtCount = amountAtCount
        self.givingsSinceCount = max(0, givingsSinceCount)
        self.amountPerGiving = amountPerGiving
        self.unit = unit
        self.restockLeadDays = max(0, restockLeadDays)
        self.needsPrescription = needsPrescription
        self.dosesHandledToday = max(0, dosesHandledToday)
    }

    /// Restbestand. Darf negativ werden, wenn mehr erfasst wurde als gezählt —
    /// die Anzeige klemmt, die Rechnung nicht.
    public var remainingAmount: Double {
        amountAtCount - Double(givingsSinceCount) * max(0, amountPerGiving)
    }
}

/// Wie lange der Vorrat reicht.
public struct StockProjection: Sendable, Equatable, Hashable {
    public var remainingAmount: Double
    public var unit: String
    public var amountPerGiving: Double
    /// Wie viele künftige Gaben der Restbestand noch abdeckt.
    public var coveredGivings: Int
    /// Tag der letzten vollständig abgedeckten Gabe. `nil`, wenn nicht einmal
    /// die nächste Gabe abgedeckt ist oder sich keine Gaben projizieren lassen.
    public var lastCoveredOn: Date?
    /// Tag der ersten Gabe, für die der Vorrat nicht mehr reicht. `nil`, wenn
    /// er bis zum Ende des Schemas reicht oder sich nicht projizieren lässt.
    public var runsOutOn: Date?
    /// Tage bis `runsOutOn`, vom Stichtag aus.
    public var daysOfSupply: Int?
    public var restockLeadDays: Int
    public var needsPrescription: Bool

    public init(
        remainingAmount: Double,
        unit: String,
        amountPerGiving: Double,
        coveredGivings: Int,
        lastCoveredOn: Date?,
        runsOutOn: Date?,
        daysOfSupply: Int?,
        restockLeadDays: Int,
        needsPrescription: Bool
    ) {
        self.remainingAmount = remainingAmount
        self.unit = unit
        self.amountPerGiving = amountPerGiving
        self.coveredGivings = coveredGivings
        self.lastCoveredOn = lastCoveredOn
        self.runsOutOn = runsOutOn
        self.daysOfSupply = daysOfSupply
        self.restockLeadDays = restockLeadDays
        self.needsPrescription = needsPrescription
    }

    /// Nachfüllen nötig: die erste nicht mehr gedeckte Gabe liegt innerhalb
    /// des Vorlaufs. Bewusst nicht schon bei `coveredGivings == 0`: bei einer
    /// Wurmkur mit leerem Vorrat und nächster Gabe in 60 Tagen wäre das sonst
    /// zwei Monate lang eine tägliche Mitteilung.
    public var needsRestock: Bool {
        guard let daysOfSupply else { return false }
        return daysOfSupply <= restockLeadDays
    }
}
