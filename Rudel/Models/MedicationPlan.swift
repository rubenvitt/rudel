import Foundation
import RudelEngine
import SwiftData

/// Die **Konfiguration** einer wiederkehrenden Gabe — Wurmkur alle 90 Tage,
/// Zeckenschutz mit 30 Tagen Wirkdauer, ein Dauermedikament mit Dosierschema.
///
/// Absichtlich getrennt von `MedicationEvent`: der Plan ist veränderlich (das
/// Intervall darf angepasst werden), die Gaben sind ein append-only Journal
/// (PRD §5.2, §8). Würde beides in einem Modell stecken, würde eine
/// Intervall-Änderung die Historie rückwirkend verfälschen.
@Model
final class MedicationPlan {
    var id: UUID = UUID()
    var kindValue: MedicationKind = MedicationKind.dewormer
    var productName: String = ""

    /// Wiederholungsintervall in Tagen — für `.dewormer`. `0` = nicht gesetzt.
    var intervalDays: Int = 0

    /// Wirkdauer in Tagen — für `.tickProtection` und `.rabiesVaccination`.
    /// `0` = nicht gesetzt.
    var effectiveDays: Int = 0

    /// Kotprobe statt Pauschalgabe (PRD §5.2). Wenn gesetzt, formuliert die UI
    /// die Fälligkeit als „Kotprobe fällig" statt „Wurmkur fällig".
    var usesFecalSampleInstead: Bool = false

    // MARK: Dosierschema für `.ongoing`
    //
    // Flach gespeichert statt als eingebettetes Codable-Struct: einzelne Skalare
    // und `[Int]` sind in SwiftData und CloudKit unproblematisch, ein optionales
    // Codable-Struct ist es nicht immer. `doseSchedule` setzt daraus wieder den
    // Engine-Typ zusammen.

    /// Gabezeiten als Minuten nach Mitternacht.
    var doseTimesMinutes: [Int] = []
    /// Jeden n-ten Tag. 1 = täglich.
    var doseEveryNDays: Int = 1
    var doseStartDate: Date?
    var doseEndDate: Date?
    var doseLabel: String = ""

    /// Abgesetzte Medikamente bleiben für die Historie erhalten, erzeugen aber
    /// keine Fälligkeiten und keine Erinnerungen mehr.
    var isActive: Bool = true

    var notes: String = ""
    var createdAt: Date = Date.distantPast

    var pet: Pet?

    @Relationship(deleteRule: .cascade, inverse: \MedicationEvent.plan)
    var events: [MedicationEvent] = []

    @Relationship(deleteRule: .cascade, inverse: \DoseLogEntry.plan)
    var doseLogs: [DoseLogEntry] = []

    init(
        kind: MedicationKind = .dewormer,
        productName: String = "",
        intervalDays: Int = 0,
        effectiveDays: Int = 0,
        usesFecalSampleInstead: Bool = false,
        doseTimesMinutes: [Int] = [],
        doseEveryNDays: Int = 1,
        doseStartDate: Date? = nil,
        doseEndDate: Date? = nil,
        doseLabel: String = "",
        isActive: Bool = true,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.kindValue = kind
        self.productName = productName
        self.intervalDays = intervalDays
        self.effectiveDays = effectiveDays
        self.usesFecalSampleInstead = usesFecalSampleInstead
        self.doseTimesMinutes = doseTimesMinutes
        self.doseEveryNDays = max(1, doseEveryNDays)
        self.doseStartDate = doseStartDate
        self.doseEndDate = doseEndDate
        self.doseLabel = doseLabel
        self.isActive = isActive
        self.notes = notes
        self.createdAt = createdAt
    }
}

extension MedicationPlan {
    /// Letzte dokumentierte Gabe.
    var lastEvent: MedicationEvent? {
        events.max(by: { $0.givenOn < $1.givenOn })
    }

    var lastGivenOn: Date? { lastEvent?.givenOn }

    /// Setzt das Dosierschema für die Engine zusammen. `nil`, wenn der Plan
    /// kein `.ongoing` ist oder keine Gabezeiten hinterlegt sind.
    var doseSchedule: DoseSchedule? {
        guard kindValue == .ongoing, !doseTimesMinutes.isEmpty else { return nil }
        let times = doseTimesMinutes.map { TimeOfDay(hour: $0 / 60, minute: $0 % 60) }
        return DoseSchedule(
            timesOfDay: times,
            everyNDays: doseEveryNDays,
            startDate: doseStartDate ?? createdAt,
            endDate: doseEndDate,
            doseLabel: doseLabel
        )
    }

    var engineID: String { id.uuidString }

    /// Mappt den Plan auf den Engine-Input. Diese Umsetzung ist die
    /// fehleranfälligste Stelle der App-Schicht und deshalb in
    /// `Tests/RudelTests` abgedeckt.
    func engineInput() -> DueItemBuilder.MedicationInput {
        DueItemBuilder.MedicationInput(
            sourceID: engineID,
            petID: pet?.engineID ?? "",
            petName: pet?.name ?? "",
            kind: kindValue,
            productName: productName,
            lastGivenOn: lastGivenOn,
            intervalDays: intervalDays > 0 ? intervalDays : nil,
            effectiveDays: effectiveDays > 0 ? effectiveDays : nil,
            schedule: doseSchedule,
            isActive: isActive
        )
    }
}

/// Eine konkrete Gabe. **Append-only** — Einträge werden nicht bearbeitet,
/// nur angelegt (PRD §8, Journal-Prinzip). Ein Tippfehler wird durch Löschen
/// und Neuanlegen korrigiert, nicht durch stilles Überschreiben.
@Model
final class MedicationEvent {
    var id: UUID = UUID()
    /// Tag der Gabe. Auf Mitternacht normalisiert speichern.
    var givenOn: Date = Date.distantPast
    /// Falls abweichend vom Plan (anderes Präparat, andere Dosis).
    var productNameOverride: String = ""
    var note: String = ""
    var loggedAt: Date = Date.distantPast

    var plan: MedicationPlan?

    init(
        givenOn: Date,
        productNameOverride: String = "",
        note: String = "",
        loggedAt: Date = Date()
    ) {
        self.id = UUID()
        self.givenOn = givenOn
        self.productNameOverride = productNameOverride
        self.note = note
        self.loggedAt = loggedAt
    }
}

/// Abhaken einer **Einzelgabe** eines Dauermedikaments (PRD §5.2).
///
/// Nur abgehakte Gaben werden gespeichert — eine fehlende Zeile bedeutet
/// „nicht gegeben". Das hält das Journal append-only und vermeidet, für jeden
/// Tag im Voraus leere Platzhalter anzulegen.
@Model
final class DoseLogEntry {
    var id: UUID = UUID()
    /// Der planmäßige Termin dieser Gabe, mit Uhrzeit.
    var scheduledAt: Date = Date.distantPast
    /// Wann tatsächlich abgehakt wurde.
    var takenAt: Date = Date.distantPast
    var note: String = ""

    var plan: MedicationPlan?

    init(scheduledAt: Date, takenAt: Date = Date(), note: String = "") {
        self.id = UUID()
        self.scheduledAt = scheduledAt
        self.takenAt = takenAt
        self.note = note
    }
}
