import Foundation
import SwiftData

/// Body Condition Score, 9-Punkte-Skala (WSAVA). 5 = idealgewichtig.
enum BodyConditionScore: Int, Codable, CaseIterable, Hashable, Sendable {
    case veryThin = 1
    case underweight = 3
    case ideal = 5
    case overweight = 7
    case obese = 9

    var label: String {
        switch self {
        case .veryThin: return "Stark untergewichtig (1/9)"
        case .underweight: return "Untergewichtig (3/9)"
        case .ideal: return "Idealgewicht (5/9)"
        case .overweight: return "Übergewichtig (7/9)"
        case .obese: return "Stark übergewichtig (9/9)"
        }
    }
}

/// Ein Gewichtseintrag (PRD §5.5). **Append-only.**
@Model
final class WeightEntry {
    var id: UUID = UUID()
    var date: Date = Date.distantPast
    var valueKg: Double = 0
    var bodyConditionScoreValue: BodyConditionScore?
    /// Tagesfuttermenge in Gramm, optional.
    var foodAmountGrams: Double?
    var note: String = ""
    var loggedAt: Date = Date.distantPast

    var pet: Pet?

    init(
        date: Date,
        valueKg: Double,
        bodyConditionScore: BodyConditionScore? = nil,
        foodAmountGrams: Double? = nil,
        note: String = "",
        loggedAt: Date = Date()
    ) {
        self.id = UUID()
        self.date = date
        self.valueKg = valueKg
        self.bodyConditionScoreValue = bodyConditionScore
        self.foodAmountGrams = foodAmountGrams
        self.note = note
        self.loggedAt = loggedAt
    }
}
