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
    /// Darf dieser Termin einen Alarm auslösen? Nur zeitkritische Pläne.
    /// Vorsorge bleibt trotzdem in der Liste, weil `NotificationPlanner`
    /// Dosis-Mitteilungen ausschließlich hieraus nimmt; gefiltert wird erst an
    /// der Grenze zum Alarmdienst.
    public var usesAlarm: Bool

    public init(
        id: String,
        sourceID: String,
        petID: String,
        petName: String,
        title: String,
        detail: String? = nil,
        category: DueItem.Category,
        dueAt: Date,
        usesAlarm: Bool = true
    ) {
        self.id = id
        self.sourceID = sourceID
        self.petID = petID
        self.petName = petName
        self.title = title
        self.detail = detail
        self.category = category
        self.dueAt = dueAt
        self.usesAlarm = usesAlarm
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, petID, petName, title, detail, category, dueAt, usesAlarm
    }

    /// Eigenes Decoding nur wegen `usesAlarm`: bestehende Registry-Dateien
    /// stammen aus der Zeit, als jeder Termin ein Alarm war, und kennen das Feld
    /// nicht. Fehlt es, gilt deshalb `true` — genau das damalige Verhalten.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        petID = try container.decode(String.self, forKey: .petID)
        petName = try container.decode(String.self, forKey: .petName)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        category = try container.decode(DueItem.Category.self, forKey: .category)
        dueAt = try container.decode(Date.self, forKey: .dueAt)
        usesAlarm = try container.decodeIfPresent(Bool.self, forKey: .usesAlarm) ?? true
    }
}

/// Plant Medikamententermine über ein rollierendes Tagesfenster.
///
/// Anders als `DueItemBuilder` ist der Plan nicht auf heutige Dashboard-Dosen
/// begrenzt. Offene Gaben von heute bleiben enthalten, auch wenn ihre Uhrzeit
/// bereits verstrichen ist; erst ein passender Logeintrag entfernt sie.
///
/// Geplant werden Termine **aller** Pläne, auch der Vorsorge: `usesAlarm`
/// trennt die zeitkritischen ab, damit Vorsorge ihre Mitteilungen behält, aber
/// nie einen Alarm auslöst.
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
            // Zurückgestellt: das Fenster beginnt erst am Tag der Zurückstellung.
            // Hier statt im `MedicationCalculator`, weil die Zurückstellung kein
            // Teil des Dosierschemas ist, sondern ein Zustand des Plans — der
            // Rechner bleibt eine reine Funktion des Schemas.
            var lowerBound = today
            if let deferredUntil = medication.deferredUntil {
                lowerBound = max(lowerBound, dayMath.startOfDay(deferredUntil))
            }
            // Liegt die Zurückstellung hinter dem Horizont, gibt es nichts zu
            // planen — und ein Bereich mit Untergrenze über der Obergrenze würde
            // abstürzen.
            guard lowerBound <= occurrenceRange.upperBound else { continue }
            let range = lowerBound...occurrenceRange.upperBound
            let loggedMinutes = loggedMinutesBySource[medication.sourceID] ?? []
            for dueAt in calculator.doseOccurrences(schedule: schedule, in: range) {
                guard !loggedMinutes.contains(minuteKey(dueAt)) else { continue }
                reminders.append(
                    reminder(
                        medication: medication,
                        category: .dose,
                        title: medication.productName.isEmpty
                            ? "Laufendes Medikament"
                            : medication.productName,
                        detail: schedule.doseLabel.isEmpty ? nil : schedule.doseLabel,
                        dueAt: dueAt,
                        usesAlarm: medication.careClass == .timeCritical
                    )
                )
            }
        }

        // `DueItemBuilder` bleibt die einzige Quelle für Intervall- und
        // Wirkdauer-Fälligkeiten. Dessen heutige `.dose`-Items werden verworfen,
        // weil die vollständigen Dosen oben direkt aus dem Schema entstehen.
        // Vorrats-Items sind keine Gabe: sie dürfen weder Alarm noch
        // Bestätigung auslösen und laufen nur über `NotificationPlanner`.
        let nonDoseItems = DueItemBuilder(dayMath: dayMath).build(
            medications: activeMedications,
            cycles: [],
            asOf: asOf,
            forecastHorizonDays: horizon
        ).filter { $0.category != .dose && $0.category != .restock }

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
                    dueAt: dueAt,
                    // Fehlt die Klasse (nur bei Nicht-Medikamenten-Items, die
                    // hier nicht vorkommen), lieber kein Alarm als ein falscher.
                    usesAlarm: item.careClass == .timeCritical
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
        dueAt: Date,
        usesAlarm: Bool
    ) -> MedicationReminder {
        MedicationReminder(
            id: reminderID(sourceID: medication.sourceID, category: category, dueAt: dueAt),
            sourceID: medication.sourceID,
            petID: medication.petID,
            petName: medication.petName,
            title: title,
            detail: detail,
            category: category,
            dueAt: dueAt,
            usesAlarm: usesAlarm
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
