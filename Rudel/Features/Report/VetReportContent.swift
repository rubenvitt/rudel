import Foundation
import RudelEngine

/// Inhalt des Tierarzt-Berichts als reiner Wert — getrennt vom Zeichnen, damit
/// sich Auswahl und Zeiträume ohne PDF prüfen lassen.
///
/// Gebaut aus den Modellen auf dem Main Actor; danach hängt nichts mehr an
/// SwiftData. Daten bleiben `Date`, formatiert wird erst in `sections`.
struct VetReportContent: Sendable, Equatable {

    /// Anlass des Berichts. Ein Schnappschuss statt des Termins, damit das
    /// Termin-Formular auch ungespeicherte Fragen mitgeben kann.
    struct Occasion: Sendable, Equatable {
        var appointmentID: UUID?
        var title: String
        var date: Date
        var practiceName: String?
        var questions: String
    }

    struct PetFacts: Sendable, Equatable {
        var name: String
        var species: String
        var breed: String
        var birthDate: Date?
        var sex: String
        var isNeutered: Bool
        var microchipNumber: String
        var allergies: String
        var insuranceInfo: String
        var primaryPractice: String?
        var primaryPracticePhone: String?
    }

    struct MedicationLine: Sendable, Equatable {
        var title: String
        var kind: String
        var schedule: String?
        var lastGiven: Date?
        var status: String
        var stock: String?
    }

    struct WeightPoint: Sendable, Equatable {
        var date: Date
        var kg: Double
    }

    enum WeightTrend: Sendable, Equatable {
        case rising
        case falling
        case stable
    }

    struct WeightSummary: Sendable, Equatable {
        /// Chronologisch, ältester zuerst.
        var points: [WeightPoint]
        var minKg: Double
        var maxKg: Double
        /// Letzter minus erster Wert im Zeitraum.
        var deltaKg: Double
        var trend: WeightTrend
    }

    struct SymptomLine: Sendable, Equatable {
        var date: Date
        var name: String
        var severity: String
        var note: String
    }

    struct CycleLine: Sendable, Equatable {
        var day1: Date
        var visibleHeatEnd: Date?
        var pseudopregnancy: Bool
    }

    struct CycleSummary: Sendable, Equatable {
        /// Jüngste zuerst.
        var periods: [CycleLine]
        var observedIntervalDays: [Int]
        var nextRange: ClosedRange<Date>?
    }

    struct AppointmentLine: Sendable, Equatable {
        var date: Date
        var title: String
        var practiceName: String?
        var findings: String
    }

    var generatedAt: Date
    var pet: PetFacts
    var occasion: Occasion?
    var medications: [MedicationLine]
    var preventives: [MedicationLine]
    var weight: WeightSummary?
    /// Beginn des Symptom-Zeitraums.
    var symptomsSince: Date
    var symptoms: [SymptomLine]
    /// `nil`, wenn das Tier keinen Zyklus hat (nur unkastrierte Hündinnen).
    var cycle: CycleSummary?
    var appointments: [AppointmentLine]

    // MARK: Regeln

    /// Mindestens so weit reicht der Symptom-Rückblick zurück.
    static let minimumSymptomDays = 90
    /// Zeitraum der Gewichtsübersicht.
    static let weightMonths = 12
    /// Unterhalb dieser Änderung (Anteil am Startgewicht) gilt das Gewicht
    /// als stabil — Waagen und Tagesform schwanken um ein, zwei Prozent.
    static let stableWeightFraction = 0.02
    static let maximumAppointments = 5
    static let maximumCyclePeriods = 4
}

// MARK: - Aufbau aus den Modellen

extension VetReportContent {

    @MainActor
    init(pet: Pet, appointment: VetAppointment?, asOf: Date, dayMath: DayMath) {
        self.init(pet: pet, occasion: appointment.map(Occasion.init(appointment:)), asOf: asOf, dayMath: dayMath)
    }

    @MainActor
    init(pet: Pet, occasion: Occasion?, asOf: Date, dayMath: DayMath) {
        generatedAt = asOf
        self.pet = PetFacts(pet: pet)
        self.occasion = occasion

        let activePlans = pet.medicationPlans
            .filter(\.isActive)
            .sorted { MedicationDisplay.title(for: $0).localizedStandardCompare(MedicationDisplay.title(for: $1)) == .orderedAscending }
        // Nicht nach allen Arten unterscheiden: neue Arten (Impfungen) landen so
        // ohne Anpassung bei der Vorsorge.
        medications = activePlans.filter { $0.kindValue == .ongoing }
            .map { MedicationLine(plan: $0, asOf: asOf, dayMath: dayMath) }
        preventives = activePlans.filter { $0.kindValue != .ongoing }
            .map { MedicationLine(plan: $0, asOf: asOf, dayMath: dayMath) }

        weight = Self.weightSummary(pet.weightEntries, asOf: asOf, dayMath: dayMath)

        let previousVisit = Self.lastDoneAppointment(of: pet, excluding: occasion?.appointmentID, asOf: asOf)
        symptomsSince = Self.symptomWindowStart(lastVisit: previousVisit?.date, asOf: asOf, dayMath: dayMath)
        let since = symptomsSince
        symptoms = pet.symptomEntries
            .filter { $0.date >= since && $0.date <= asOf }
            .sorted { $0.date > $1.date }
            .map { SymptomLine(date: $0.date, name: $0.displayName, severity: $0.severityValue.label, note: $0.note) }

        cycle = pet.tracksCycle ? Self.cycleSummary(pet, asOf: asOf, dayMath: dayMath) : nil

        appointments = pet.vetAppointments
            .filter { $0.statusValue == .done && $0.date <= asOf && $0.id != occasion?.appointmentID }
            .sorted { $0.date > $1.date }
            .prefix(Self.maximumAppointments)
            .map(AppointmentLine.init(appointment:))
    }

    /// Ab dem letzten erledigten Besuch, aber nie kürzer als 90 Tage: wer
    /// gestern beim Tierarzt war, will trotzdem den Verlauf zeigen können.
    static func symptomWindowStart(lastVisit: Date?, asOf: Date, dayMath: DayMath) -> Date {
        let minimum = dayMath.adding(days: -minimumSymptomDays, to: dayMath.startOfDay(asOf))
        guard let lastVisit else { return minimum }
        return min(dayMath.startOfDay(lastVisit), minimum)
    }

    @MainActor
    static func lastDoneAppointment(of pet: Pet, excluding appointmentID: UUID?, asOf: Date) -> VetAppointment? {
        pet.vetAppointments
            .filter { $0.statusValue == .done && $0.date <= asOf && $0.id != appointmentID }
            .max { $0.date < $1.date }
    }

    @MainActor
    static func weightSummary(_ entries: [WeightEntry], asOf: Date, dayMath: DayMath) -> WeightSummary? {
        let start = dayMath.calendar.date(byAdding: .month, value: -weightMonths, to: dayMath.startOfDay(asOf)) ?? asOf
        let points = entries
            .filter { $0.date >= start && $0.date <= asOf && $0.valueKg > 0 }
            .sorted { $0.date < $1.date }
            .map { WeightPoint(date: $0.date, kg: $0.valueKg) }
        guard let first = points.first, let last = points.last else { return nil }
        let values = points.map(\.kg)
        let delta = last.kg - first.kg
        let trend: WeightTrend
        if abs(delta) < first.kg * stableWeightFraction {
            trend = .stable
        } else {
            trend = delta > 0 ? .rising : .falling
        }
        return WeightSummary(
            points: points,
            minKg: values.min() ?? first.kg,
            maxKg: values.max() ?? first.kg,
            deltaKg: delta,
            trend: trend
        )
    }

    @MainActor
    static func cycleSummary(_ pet: Pet, asOf: Date, dayMath: DayMath) -> CycleSummary? {
        let periods = pet.cyclePeriods.filter { $0.day1Date <= asOf }.sorted { $0.day1Date > $1.day1Date }
        guard !periods.isEmpty else { return nil }
        // Dieselbe Rechnung wie in der Zyklus-Übersicht.
        let prediction = CycleIntervalPredictor(dayMath: dayMath).predictNextCycle(
            history: CycleHistory(day1Anchors: periods.map(\.day1Date), sizeClass: pet.effectiveSizeClass),
            asOf: asOf
        )
        return CycleSummary(
            periods: periods.prefix(maximumCyclePeriods).map {
                CycleLine(day1: $0.day1Date, visibleHeatEnd: $0.visibleHeatEndDate, pseudopregnancy: $0.pseudopregnancyObserved)
            },
            observedIntervalDays: prediction?.observedIntervalDays ?? [],
            nextRange: prediction?.range
        )
    }

    /// Vorratszeile (Abschnitt 2 der Spec); `nil` ohne Vorratsverwaltung.
    @MainActor
    static func stockLine(for plan: MedicationPlan, asOf: Date, dayMath: DayMath) -> String? {
        MedicationDisplay.stockText(for: plan, asOf: asOf, dayMath: dayMath)
    }
}

extension VetReportContent.Occasion {
    @MainActor
    init(appointment: VetAppointment) {
        self.init(
            appointmentID: appointment.id,
            title: appointment.displayTitle,
            date: appointment.date,
            practiceName: appointment.practice.map(VetDisplay.practiceName),
            questions: appointment.preparationNotes
        )
    }
}

extension VetReportContent.PetFacts {
    @MainActor
    init(pet: Pet) {
        let practice = pet.primaryPractice
        self.init(
            name: pet.name.isEmpty ? "Unbenannt" : pet.name,
            species: pet.speciesValue.label,
            breed: pet.breed,
            birthDate: pet.birthDate,
            sex: pet.isFemale ? "weiblich" : "männlich",
            isNeutered: pet.isNeutered,
            microchipNumber: pet.microchipNumber,
            allergies: pet.allergies,
            insuranceInfo: pet.insuranceInfo,
            primaryPractice: practice.map(VetDisplay.practiceName),
            primaryPracticePhone: practice.map(\.phone).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

extension VetReportContent.MedicationLine {
    @MainActor
    init(plan: MedicationPlan, asOf: Date, dayMath: DayMath) {
        // Dauermedikamente werden über Einzelgaben abgehakt, alles andere über
        // das Gabe-Journal.
        let lastDose = plan.doseLogs.filter { !$0.wasSkipped }.map(\.scheduledAt).max()
        // Impfungen nach der Krankheit benennen („Tollwut"), das Präparat
        // steht in Klammern dahinter.
        let product = plan.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isVaccination = plan.kindValue.isVaccination
        self.init(
            title: isVaccination ? MedicationDisplay.vaccineName(for: plan) : MedicationDisplay.title(for: plan),
            kind: isVaccination && !product.isEmpty ? product : Format.label(plan.kindValue),
            schedule: MedicationDisplay.scheduleSummary(for: plan),
            lastGiven: [plan.lastGivenOn, lastDose].compactMap { $0 }.max(),
            status: MedicationDisplay.status(for: plan, asOf: asOf, dayMath: dayMath).dueText,
            stock: VetReportContent.stockLine(for: plan, asOf: asOf, dayMath: dayMath)
        )
    }
}

extension VetReportContent.AppointmentLine {
    @MainActor
    init(appointment: VetAppointment) {
        self.init(
            date: appointment.date,
            title: appointment.displayTitle,
            practiceName: appointment.practice.map(VetDisplay.practiceName),
            findings: appointment.findings
        )
    }
}

// MARK: - Abschnitte für die Darstellung

extension VetReportContent {

    struct Section: Sendable, Equatable {
        var title: String
        var rows: [Row]
    }

    /// Eine Zeile: Datum oder Bezeichnung links, Text rechts, optional eine
    /// zweite, eingerückte Zeile (Notiz, Befund).
    struct Row: Sendable, Equatable {
        var label: String
        var text: String
        var detail: String?
    }

    static let emptyText = "Keine Einträge"

    /// Fester Satz Überschriften. Abschnitte ohne Inhalt bleiben mit „Keine
    /// Einträge" stehen — für die Praxis ist „nichts erfasst" auch eine Aussage.
    /// Nur Anlass und Zyklus entfallen, wenn sie nicht zutreffen.
    var sections: [Section] {
        var result: [Section] = [petSection]
        if let occasion {
            result.append(occasionSection(occasion))
        }
        result.append(Section(title: "Aktuelle Medikamente", rows: medications.map(Self.row(for:))))
        result.append(Section(title: "Impfungen und Vorsorge", rows: preventives.map(Self.row(for:))))
        result.append(weightSection)
        result.append(Section(
            title: "Symptome seit \(Format.date(symptomsSince))",
            rows: symptoms.map {
                Row(label: Format.date($0.date), text: "\($0.name) · \($0.severity)", detail: Self.nonEmpty($0.note))
            }
        ))
        if let cycle {
            result.append(cycleSection(cycle))
        }
        result.append(Section(
            title: "Letzte Tierarzttermine",
            rows: appointments.map {
                let place = $0.practiceName.map { " · \($0)" } ?? ""
                return Row(label: Format.date($0.date), text: $0.title + place, detail: Self.nonEmpty($0.findings).map { "Befund: \($0)" })
            }
        ))
        return result
    }

    private var petSection: Section {
        var rows = [Row(label: "Art", text: [pet.species, Self.nonEmpty(pet.breed)].compactMap { $0 }.joined(separator: " · "))]
        if let birthDate = pet.birthDate {
            rows.append(Row(label: "Geboren", text: Format.date(birthDate)))
        }
        rows.append(Row(label: "Geschlecht", text: pet.sex + (pet.isNeutered ? ", kastriert" : ", nicht kastriert")))
        if let latest = weight?.points.last {
            rows.append(Row(label: "Gewicht", text: "\(Format.weight(latest.kg)) am \(Format.date(latest.date))"))
        }
        rows.append(Row(label: "Chipnummer", text: Self.nonEmpty(pet.microchipNumber) ?? "nicht erfasst"))
        rows.append(Row(label: "Allergien", text: Self.nonEmpty(pet.allergies) ?? "keine bekannt"))
        if let insurance = Self.nonEmpty(pet.insuranceInfo) {
            rows.append(Row(label: "Versicherung", text: insurance))
        }
        if let practice = pet.primaryPractice {
            let phone = pet.primaryPracticePhone.map { " · \($0)" } ?? ""
            rows.append(Row(label: "Haustierarzt", text: practice + phone))
        }
        return Section(title: "Tier und Notfalldaten", rows: rows)
    }

    private func occasionSection(_ occasion: Occasion) -> Section {
        var rows = [Row(label: "Termin", text: "\(occasion.title) · \(Format.dateTime(occasion.date))")]
        if let practice = occasion.practiceName {
            rows.append(Row(label: "Praxis", text: practice))
        }
        rows.append(Row(label: "Fragen an die Praxis", text: Self.nonEmpty(occasion.questions) ?? "keine notiert"))
        return Section(title: "Anlass", rows: rows)
    }

    private var weightSection: Section {
        guard let weight else { return Section(title: "Gewicht (12 Monate)", rows: []) }
        let trend: String
        switch weight.trend {
        case .stable: trend = "stabil"
        case .rising: trend = "steigend (+\(Format.weight(weight.deltaKg)))"
        case .falling: trend = "fallend (−\(Format.weight(abs(weight.deltaKg))))"
        }
        var rows = [
            Row(label: "Spanne", text: "\(Format.weight(weight.minKg)) – \(Format.weight(weight.maxKg))"),
            Row(label: "Trend", text: weight.points.count > 1 ? trend : "nur ein Messwert"),
        ]
        rows += weight.points.reversed().map { Row(label: Format.date($0.date), text: Format.weight($0.kg)) }
        return Section(title: "Gewicht (12 Monate)", rows: rows)
    }

    private func cycleSection(_ cycle: CycleSummary) -> Section {
        var rows = cycle.periods.map { period in
            let end = period.visibleHeatEnd.map { "sichtbare Hitze bis \(Format.date($0))" } ?? "Ende nicht erfasst"
            return Row(
                label: Format.date(period.day1),
                text: "Tag 1 · \(end)",
                detail: period.pseudopregnancy ? "Anzeichen von Scheinträchtigkeit" : nil
            )
        }
        if !cycle.observedIntervalDays.isEmpty {
            rows.append(Row(label: "Intervalle", text: cycle.observedIntervalDays.map(Format.dayCount).joined(separator: ", ")))
        }
        if let range = cycle.nextRange {
            rows.append(Row(label: "Nächste erwartet", text: Format.dateRange(range)))
        }
        return Section(title: "Läufigkeit", rows: rows)
    }

    private static func row(for line: MedicationLine) -> Row {
        var details: [String] = []
        if let schedule = line.schedule { details.append(schedule) }
        if let lastGiven = line.lastGiven { details.append("zuletzt \(Format.date(lastGiven))") }
        if let stock = line.stock { details.append(stock) }
        details.append(line.status)
        let title = line.title == line.kind ? line.title : "\(line.title) (\(line.kind))"
        return Row(label: title, text: "", detail: details.joined(separator: " · "))
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
