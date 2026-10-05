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

    /// Wirkdauer in Tagen — für `.tickProtection` und die Impfungen.
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

    // MARK: Vorsorge oder zeitkritisch

    /// `nil` = Standard der Art (`MedicationKind.defaultCareClass`). Als
    /// Override gespeichert, damit Bestandspläne ohne Migration den Standard
    /// erhalten — Vorsorge verliert dadurch ihren Wecker.
    var careClassOverride: MedicationCareClass?

    /// `nil` = Standard der Art (`MedicationKind.defaultRequiresVetVisit`).
    /// Aus demselben Grund optional: bestehende Tollwut-Pläne sollen den
    /// Standard „Termin nötig" bekommen, nicht `false`.
    var requiresVetVisitOverride: Bool?

    /// Manuell zurückgestellt bis zu diesem Tag (Zeckenschutz im Winter).
    var deferredUntil: Date?
    /// Wann zurückgestellt wurde. Ein danach erfasster Journal-Eintrag hebt
    /// die Zurückstellung auf, siehe `engineInput()`.
    var deferredAt: Date?

    // MARK: Impfung

    /// Welche Impfung — nur bei `.vaccination`. Tollwut bleibt die eigene Art
    /// `.rabiesVaccination` und hat hier `nil`.
    var vaccineValue: VaccineType?

    // MARK: Vorrat
    //
    // Der Restbestand wird nicht heruntergezählt, sondern aus dem Journal
    // abgeleitet (`remainingStock`) — so bleibt das Journal append-only, und ein
    // gelöschter Fehleintrag korrigiert den Bestand von selbst.

    /// Zeitpunkt der letzten Zählung. `nil` = keine Vorratsverwaltung.
    var stockCountedAt: Date?
    /// Bestand bei dieser Zählung.
    var stockAmount: Double = 0
    /// Einheit, z. B. „Tabletten".
    var stockUnit: String = ""
    var amountPerGiving: Double = 1
    /// Packungsgröße für „+ 1 Packung". `0` = unbekannt.
    var packageSize: Double = 0
    /// Ab welcher Reichweite in Tagen erinnert wird.
    var restockLeadDays: Int = 7
    var needsPrescription: Bool = false

    var pet: Pet?

    @Relationship(deleteRule: .nullify, inverse: \VetAppointment.medicationPlan)
    var appointments: [VetAppointment] = []

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
    /// Letzte dokumentierte **Gabe**. Ausgelassene Termine zählen nicht — eine
    /// ausgelassene Zeckentablette schützt nicht.
    var lastEvent: MedicationEvent? {
        events.filter { $0.outcomeValue == .given }.max(by: { $0.givenOn < $1.givenOn })
    }

    var lastGivenOn: Date? { lastEvent?.givenOn }

    /// Letzter bewusst ausgelassener Termin. Ab hier rechnet das Intervall neu.
    var lastSkippedOn: Date? {
        events.filter { $0.outcomeValue == .skipped }.map(\.givenOn).max()
    }

    var careClass: MedicationCareClass { careClassOverride ?? kindValue.defaultCareClass }

    var requiresVetVisit: Bool { requiresVetVisitOverride ?? kindValue.defaultRequiresVetVisit }

    /// Ein verknüpfter, noch nicht abgeschlossener Termin — unabhängig vom
    /// Datum. Sonst tauchte nach Terminbeginn, aber vor dem Abschluss wieder
    /// „Termin vereinbaren" auf.
    var openAppointment: VetAppointment? {
        appointments.filter(\.isOpen).min(by: { $0.date < $1.date })
    }

    /// Die Zurückstellung gilt nur, solange seitdem nichts erfasst wurde.
    var activeDeferral: Date? {
        guard let deferredUntil else { return nil }
        if let deferredAt, events.contains(where: { $0.loggedAt > deferredAt }) { return nil }
        if let deferredAt, doseLogs.contains(where: { $0.takenAt > deferredAt }) { return nil }
        return deferredUntil
    }

    var managesStock: Bool { stockCountedAt != nil }

    /// Gaben seit der letzten Zählung: echte Gaben (nach Erfassungszeitpunkt,
    /// weil `givenOn` auf Mitternacht steht) und abgehakte, nicht ausgelassene
    /// Einzelgaben. Gelöschte Einträge fallen von selbst heraus.
    var givingsSinceStockCount: Int {
        guard let countedAt = stockCountedAt else { return 0 }
        let events = events.filter { $0.outcomeValue == .given && $0.loggedAt > countedAt }.count
        let doses = doseLogs.filter { !$0.wasSkipped && $0.takenAt > countedAt }.count
        return events + doses
    }

    /// Abgeleiteter Restbestand. `nil` ohne Vorratsverwaltung. Kann negativ
    /// werden, wenn mehr erfasst als gezählt wurde.
    var remainingStock: Double? {
        guard managesStock else { return nil }
        return stockAmount - Double(givingsSinceStockCount) * max(0, amountPerGiving)
    }

    /// Vorrat für die Engine. `asOf` und `dayMath` bestimmen nur, welche
    /// heutigen Einzelgaben schon erfasst sind.
    func stockInput(asOf: Date, dayMath: DayMath) -> StockInput? {
        guard managesStock else { return nil }
        let handledToday = doseLogs.filter { dayMath.isSameDay($0.scheduledAt, asOf) }.count
        return StockInput(
            amountAtCount: stockAmount,
            givingsSinceCount: givingsSinceStockCount,
            amountPerGiving: amountPerGiving,
            unit: stockUnit,
            restockLeadDays: restockLeadDays,
            needsPrescription: needsPrescription,
            dosesHandledToday: handledToday
        )
    }

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
    func engineInput(asOf: Date = Date(), dayMath: DayMath = .current()) -> DueItemBuilder.MedicationInput {
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
            isActive: isActive,
            careClass: careClass,
            lastSkippedOn: lastSkippedOn,
            deferredUntil: activeDeferral,
            requiresVetVisit: requiresVetVisit,
            hasOpenAppointment: openAppointment != nil,
            vaccine: kindValue == .vaccination ? (vaccineValue ?? .other) : nil,
            stock: stockInput(asOf: asOf, dayMath: dayMath)
        )
    }
}

/// Ob ein Termin wahrgenommen oder bewusst ausgelassen wurde.
enum MedicationEventOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case given
    case skipped
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
    /// Optional, weil das Feld nachträglich hinzukam: Die Leichtmigration
    /// befüllt bestehende Zeilen bei Codable-Enums nicht mit dem Default, ein
    /// nicht-optionaler Typ crasht dann beim Lesen. `nil` heißt „gegeben".
    @Attribute(originalName: "outcomeValue")
    var storedOutcome: MedicationEventOutcome?

    /// `.skipped` = bewusst ausgelassen. Dann ist `givenOn` der Tag der
    /// Entscheidung, nicht einer Gabe.
    var outcomeValue: MedicationEventOutcome {
        get { storedOutcome ?? .given }
        set { storedOutcome = newValue }
    }

    var plan: MedicationPlan?

    init(
        givenOn: Date,
        productNameOverride: String = "",
        note: String = "",
        outcome: MedicationEventOutcome = .given,
        loggedAt: Date = Date()
    ) {
        self.id = UUID()
        self.givenOn = givenOn
        self.productNameOverride = productNameOverride
        self.note = note
        self.outcomeValue = outcome
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
    /// Bewusst ausgelassen (z. B. auf Anweisung der Praxis). Gilt wie eine
    /// abgehakte Gabe als erledigt — sonst re-armiert der Alarm endlos —, wird
    /// aber als „ausgelassen" angezeigt. `takenAt` ist dann der Zeitpunkt der
    /// Entscheidung.
    var wasSkipped: Bool = false

    var plan: MedicationPlan?

    init(scheduledAt: Date, takenAt: Date = Date(), note: String = "", wasSkipped: Bool = false) {
        self.id = UUID()
        self.scheduledAt = scheduledAt
        self.takenAt = takenAt
        self.note = note
        self.wasSkipped = wasSkipped
    }
}
