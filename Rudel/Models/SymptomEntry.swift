import Foundation
import RudelEngine
import SwiftData

/// Häufige Symptome als Schnellauswahl (PRD §5.4). `.other` trägt den Freitext
/// in `SymptomEntry.customType`.
enum SymptomType: String, Codable, CaseIterable, Hashable, Sendable {
    case earInfection
    case vomiting
    case diarrhea
    case limping
    case appetiteLoss
    case itching
    case coughing
    case lethargy
    case other

    var label: String {
        switch self {
        case .earInfection: return "Ohrenentzündung"
        case .vomiting: return "Erbrechen"
        case .diarrhea: return "Durchfall"
        case .limping: return "Humpeln"
        case .appetiteLoss: return "Appetitlosigkeit"
        case .itching: return "Juckreiz"
        case .coughing: return "Husten"
        case .lethargy: return "Mattigkeit"
        case .other: return "Sonstiges"
        }
    }

    var symbolName: String {
        switch self {
        case .earInfection: return "ear"
        case .vomiting: return "arrow.up.circle"
        case .diarrhea: return "drop.triangle"
        case .limping: return "figure.walk.motion"
        case .appetiteLoss: return "fork.knife"
        case .itching: return "hand.raised"
        case .coughing: return "lungs"
        case .lethargy: return "zzz"
        case .other: return "questionmark.circle"
        }
    }

    /// Schnellauswahl auf dem Log-Screen — `.other` steht separat.
    static var quickPick: [SymptomType] {
        allCases.filter { $0 != .other }
    }
}

/// Schweregrad in drei Stufen (PRD §5.4).
enum SymptomSeverity: Int, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case mild = 1
    case moderate = 2
    case severe = 3

    var label: String {
        switch self {
        case .mild: return "Leicht"
        case .moderate: return "Mittel"
        case .severe: return "Stark"
        }
    }

    static func < (lhs: SymptomSeverity, rhs: SymptomSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Eine Symptom-Beobachtung. **Append-only.**
@Model
final class SymptomEntry {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var typeValue: SymptomType = SymptomType.other
    /// Freitext-Bezeichnung, wenn `typeValue == .other`.
    var customType: String = ""
    var severityValue: SymptomSeverity = SymptomSeverity.mild
    var note: String = ""

    @Attribute(.externalStorage) var photoData: Data?

    /// Verknüpfte Behandlung (PRD §5.4). Delete-Rule `.nullify`: wird der Plan
    /// gelöscht, bleibt die Symptom-Historie erhalten — sie ist die wertvollere
    /// Information.
    @Relationship(deleteRule: .nullify)
    var linkedTreatment: MedicationPlan?

    var loggedAt: Date = Date.distantPast

    var pet: Pet?

    init(
        date: Date,
        type: SymptomType = .other,
        customType: String = "",
        severity: SymptomSeverity = .mild,
        note: String = "",
        photoData: Data? = nil,
        linkedTreatment: MedicationPlan? = nil,
        loggedAt: Date = Date()
    ) {
        self.id = UUID()
        self.date = date
        self.typeValue = type
        self.customType = customType
        self.severityValue = severity
        self.note = note
        self.photoData = photoData
        self.linkedTreatment = linkedTreatment
        self.loggedAt = loggedAt
    }
}

extension SymptomEntry {
    /// Anzeigename: bei `.other` der Freitext, sonst das Label.
    var displayName: String {
        if typeValue == .other {
            let trimmed = customType.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? SymptomType.other.label : trimmed
        }
        return typeValue.label
    }

    /// Schlüssel für die Gruppierung der Verlaufsansicht: gleiche Symptome
    /// werden zusammengefasst, `.other`-Einträge nach ihrem Freitext.
    var groupingKey: String {
        typeValue == .other
            ? "other:\(customType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            : typeValue.rawValue
    }
}
