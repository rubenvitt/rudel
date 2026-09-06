import Foundation

/// Ein vollständiger Medikamententermin mit allen Metadaten, die App-Dienste
/// ohne Rückgriff auf die tagesbezogene Dashboard-Liste benötigen.
public struct MedicationReminder: Sendable, Codable, Equatable, Hashable, Identifiable {
    /// Stabil für dieselbe Quelle, Kategorie und planmäßige Fälligkeitsminute.
    public var id: String
    public var sourceID: String
    public var petID: String
    public var petName: String
    public var title: String
    public var detail: String?
    public var category: DueItem.Category
    public var dueAt: Date

    public init(
        id: String,
        sourceID: String,
        petID: String,
        petName: String,
        title: String,
        detail: String? = nil,
        category: DueItem.Category,
        dueAt: Date
    ) {
        self.id = id
        self.sourceID = sourceID
        self.petID = petID
        self.petName = petName
        self.title = title
        self.detail = detail
        self.category = category
        self.dueAt = dueAt
    }
}

/// Plant Medikamententermine über ein rollierendes Tagesfenster.
///
/// Anders als `DueItemBuilder` ist der Plan nicht auf heutige Dashboard-Dosen
/// begrenzt. Offene Gaben von heute bleiben enthalten, auch wenn ihre Uhrzeit
/// bereits verstrichen ist; erst ein passender Logeintrag entfernt sie.
public struct MedicationReminderPlanner: Sendable {
    public let dayMath: DayMath

    public init(dayMath: DayMath = .utc) {
        self.dayMath = dayMath
    }

    public func plan(
        medications: [DueItemBuilder.MedicationInput],
        loggedDoses: [String: [Date]],
        reminderTime: TimeOfDay,
        horizonDays: Int,
        asOf: Date
    ) -> [MedicationReminder] {
        let activeMedications = medications.filter(\.isActive)
        let today = dayMath.startOfDay(asOf)
        let horizon = max(0, horizonDays)
        let dayAfterHorizon = dayMath.adding(days: horizon + 1, to: today)
        // Gabezeiten sind minutengenau. Eine Sekunde vor dem nächsten Tag hält
        // deshalb den kompletten letzten Horizonttag im geschlossenen Fenster.
        let occurrenceRange = today...dayAfterHorizon.addingTimeInterval(-1)

        let loggedMinutesBySource = loggedDoses.mapValues { dates in
            Set(dates.map(minuteKey))
        }
        let calculator = MedicationCalculator(dayMath: dayMath)
        var reminders: [MedicationReminder] = []

        for medication in activeMedications where medication.kind == .ongoing {
            guard let schedule = medication.schedule else { continue }
            let loggedMinutes = loggedMinutesBySource[medication.sourceID] ?? []
            for dueAt in calculator.doseOccurrences(schedule: schedule, in: occurrenceRange) {
                guard !loggedMinutes.contains(minuteKey(dueAt)) else { continue }
                reminders.append(
                    reminder(
                        medication: medication,
                        category: .dose,
                        title: medication.productName.isEmpty
                            ? "Laufendes Medikament"
                            : medication.productName,
                        detail: schedule.doseLabel.isEmpty ? nil : schedule.doseLabel,
                        dueAt: dueAt
                    )
                )
            }
        }

        // `DueItemBuilder` bleibt die einzige Quelle für Intervall- und
        // Wirkdauer-Fälligkeiten. Dessen heutige `.dose`-Items werden verworfen,
        // weil die vollständigen Dosen oben direkt aus dem Schema entstehen.
        let nonDoseItems = DueItemBuilder(dayMath: dayMath).build(
            medications: activeMedications,
            cycles: [],
            asOf: asOf,
            forecastHorizonDays: horizon
        ).filter { $0.category != .dose }

        for item in nonDoseItems {
            let daysUntilDue = dayMath.days(from: today, to: item.dueOn)
            guard daysUntilDue <= horizon else { continue }
            let dueAt = moment(of: reminderTime, on: item.dueOn)
            reminders.append(
                MedicationReminder(
                    id: reminderID(
                        sourceID: item.sourceID,
                        category: item.category,
                        dueAt: dueAt
                    ),
                    sourceID: item.sourceID,
                    petID: item.petID,
                    petName: item.petName,
                    title: item.title,
                    detail: item.detail,
                    category: item.category,
                    dueAt: dueAt
                )
            )
        }

        var seen = Set<String>()
        return reminders
            .sorted { lhs, rhs in
                if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
                return lhs.id < rhs.id
            }
            .filter { seen.insert($0.id).inserted }
    }
}

private extension MedicationReminderPlanner {
    func reminder(
        medication: DueItemBuilder.MedicationInput,
        category: DueItem.Category,
        title: String,
        detail: String?,
        dueAt: Date
    ) -> MedicationReminder {
        MedicationReminder(
            id: reminderID(sourceID: medication.sourceID, category: category, dueAt: dueAt),
            sourceID: medication.sourceID,
            petID: medication.petID,
            petName: medication.petName,
            title: title,
            detail: detail,
            category: category,
            dueAt: dueAt
        )
    }

    func reminderID(sourceID: String, category: DueItem.Category, dueAt: Date) -> String {
        "rudel.\(category.rawValue).\(sourceID).\(Int(dueAt.timeIntervalSince1970))"
    }

    func minuteKey(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 60))
    }

    func moment(of time: TimeOfDay, on day: Date) -> Date {
        let midnight = dayMath.startOfDay(day)
        var parts = dayMath.calendar.dateComponents([.year, .month, .day], from: midnight)
        parts.hour = time.hour
        parts.minute = time.minute
        parts.second = 0
        return dayMath.calendar.date(from: parts) ?? midnight
    }
}
