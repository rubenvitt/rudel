import Foundation
import RudelEngine

/// Aufbereitete Fälligkeit eines Plans — an **einer** Stelle berechnet, weil
/// Liste und Schnell-Erfassung dieselben Texte und dieselbe Reihenfolge brauchen.
/// Läge das in beiden Views, würde die Vorauswahl der Schnell-Erfassung
/// irgendwann von der Sortierung der Liste abweichen.
struct PlanStatus {
    /// Für den `UrgencyBadge`. `nil`, wenn sich keine Fälligkeit berechnen lässt
    /// — bei fehlender Konfiguration wäre jede Dringlichkeitsstufe erfunden.
    var urgency: Urgency?
    /// Zeile unter dem Präparatnamen.
    var dueText: String
    /// Nur `.tickProtection` / `.rabiesVaccination` — Grundlage des `ProtectionBar`.
    var protection: ProtectionStatus?
    var sortKey: SortKey

    /// Kleiner = dringender. `group` trennt die Fälle vor dem Tagesvergleich:
    /// „noch nie gegeben" steht immer vorn (siehe `DueItemBuilder`), und
    /// unkonfigurierte oder beendete Pläne dürfen die Vorauswahl der
    /// Schnell-Erfassung nicht kapern, obwohl sie rechnerisch bei 0 Tagen liegen.
    struct SortKey: Equatable, Comparable {
        var group: Int
        var days: Int

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            lhs.group == rhs.group ? lhs.days < rhs.days : lhs.group < rhs.group
        }
    }
}

/// Ableitungen aus einem `MedicationPlan`, die mehrere Screens teilen.
/// Bewusst ein Namensraum statt einer `MedicationPlan`-Extension: `Rudel/Models`
/// ist eingefroren, und eine Extension dort hineinzuschmuggeln würde die
/// Zuständigkeit verwischen.
enum MedicationDisplay {

    // MARK: Benennung

    /// Anzeigename. Fällt auf die Gattungsbezeichnung zurück, weil `productName`
    /// im Modell auf `""` steht und ein leerer Zeilenkopf schlimmer ist als
    /// „Wurmkur".
    static func title(for plan: MedicationPlan) -> String {
        let trimmed = plan.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        if plan.kindValue.isVaccination {
            return vaccineName(for: plan)
        }
        return trimmed.isEmpty ? Format.label(plan.kindValue) : trimmed
    }

    /// Name der Impfung für den Impfpass: „Tollwut", „Leptospirose", bei
    /// „andere Impfung" das Präparat. `nil` für Nicht-Impfungen.
    static func vaccineName(for plan: MedicationPlan) -> String {
        let product = plan.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch plan.kindValue {
        case .rabiesVaccination:
            return "Tollwut"
        case .vaccination:
            let vaccine = plan.vaccineValue ?? .other
            if vaccine != .other { return vaccine.displayName }
            return product.isEmpty ? Format.label(.vaccination) : product
        case .dewormer, .tickProtection, .ongoing:
            return product.isEmpty ? Format.label(plan.kindValue) : product
        }
    }

    /// Das Präparat unter dem Impfnamen — nur, wenn es nicht schon der Name ist.
    static func vaccineProduct(for plan: MedicationPlan) -> String? {
        let product = plan.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plan.kindValue.isVaccination, !product.isEmpty, product != vaccineName(for: plan) else { return nil }
        return product
    }

    /// „90 Tage", „3 Jahre". Jahre nur bei glatten Vielfachen — die
    /// Tollwut-Gültigkeit von 1095 Tagen liest sich als „3 Jahre", eine
    /// Zeckenschutz-Wirkdauer von 84 Tagen nicht als „12 Wochen" (eine Liste,
    /// die Tage und Wochen mischt, ist schwerer zu vergleichen).
    static func durationLabel(days: Int) -> String {
        if days >= 365, days % 365 == 0 {
            let years = days / 365
            return years == 1 ? "1 Jahr" : "\(years) Jahre"
        }
        return Format.dayCount(days)
    }

    /// „Täglich · 08:00, 20:00 · 1/2 Tablette". `nil`, wenn der Plan kein
    /// Dosierschema hat.
    static func scheduleSummary(for plan: MedicationPlan) -> String? {
        guard let schedule = plan.doseSchedule else { return nil }
        let rhythm = schedule.everyNDays == 1 ? "Täglich" : "Jeden \(schedule.everyNDays). Tag"
        var parts = [rhythm, schedule.timesOfDay.map { Format.time($0) }.joined(separator: ", ")]
        if !schedule.doseLabel.isEmpty {
            parts.append(schedule.doseLabel)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Fälligkeit

    static func status(for plan: MedicationPlan, asOf: Date, dayMath: DayMath) -> PlanStatus {
        if plan.kindValue == .ongoing {
            return ongoingStatus(for: plan, asOf: asOf, dayMath: dayMath)
        }
        if let hint = missingConfiguration(for: plan) {
            return unconfigured(hint)
        }

        let today = dayMath.startOfDay(asOf)

        // Ein geplanter Termin übernimmt die Gabe — die Engine liefert dann kein
        // Item mehr, deshalb vor dem Engine-Aufruf.
        if let appointment = plan.openAppointment {
            let days = appointment.date < asOf ? 0 : dayMath.days(from: today, to: appointment.date)
            return PlanStatus(
                urgency: Urgency(daysUntilDue: days),
                dueText: appointmentText(appointment),
                protection: protection(for: plan, today: today, dayMath: dayMath),
                sortKey: .init(group: 1, days: days)
            )
        }

        // Fälligkeit aus derselben Engine-Rechnung wie auf Heute — sonst laufen
        // Liste und Dashboard bei Auslassung und Zurückstellung auseinander.
        // Ohne Vorrats-Item: es ist dringlicher sortiert und würde sonst die
        // Fälligkeit des Plans verdrängen.
        let item = DueItemBuilder(dayMath: dayMath)
            .build(medications: [plan.engineInput(asOf: asOf, dayMath: dayMath)], cycles: [], asOf: asOf, forecastHorizonDays: 0)
            .first { $0.category != .restock }
        guard let item else {
            return unconfigured("Keine Fälligkeit berechenbar")
        }
        let protection = protection(for: plan, today: today, dayMath: dayMath)
        let sortKey = PlanStatus.SortKey(group: 1, days: item.daysUntilDue)

        if let deferredUntil = item.deferredUntil {
            return PlanStatus(
                urgency: item.urgency,
                dueText: "Zurückgestellt bis \(Format.date(deferredUntil))",
                protection: protection,
                sortKey: sortKey
            )
        }

        if item.needsVetAppointment {
            return PlanStatus(
                urgency: item.urgency,
                dueText: "Tierarzttermin vereinbaren · fällig \(dueLabel(item))",
                protection: protection,
                sortKey: plan.lastGivenOn == nil && plan.lastSkippedOn == nil
                    ? .init(group: 0, days: 0)
                    : sortKey
            )
        }

        if plan.lastGivenOn == nil, plan.lastSkippedOn == nil {
            return neverGiven()
        }

        // Nach einer Auslassung rechnet die Fälligkeit ab ihr, der Schutz aber
        // nur ab der letzten echten Gabe — beides muss dann sichtbar sein.
        if let skipped = plan.lastSkippedOn, skipped > (plan.lastGivenOn ?? .distantPast) {
            return PlanStatus(
                urgency: item.urgency,
                dueText: "Ausgelassen am \(Format.shortDate(skipped)) · nächste \(dueNoun(plan)) \(dueLabel(item))",
                protection: protection,
                sortKey: sortKey
            )
        }

        switch plan.kindValue {
        case .tickProtection, .rabiesVaccination, .vaccination:
            let isRabies = plan.kindValue.isVaccination
            // Eine verstrichene Zurückstellung schiebt `dueOn` hinter das
            // Schutzende — der Schutz ist dann schon weg, und „Schutz bis" darf
            // nicht den verschobenen Tag nennen.
            if let end = item.protectionEndsOn, !dayMath.isSameDay(end, item.dueOn) {
                let ended = isRabies ? "Abgelaufen am" : "Schutz endete am"
                return PlanStatus(
                    urgency: item.urgency,
                    dueText: "\(ended) \(Format.date(end)) · nächste \(dueNoun(plan)) \(dueLabel(item))",
                    protection: protection,
                    sortKey: sortKey
                )
            }
            let prefix = isRabies ? "Gültig bis" : "Schutz bis"
            return PlanStatus(
                urgency: item.urgency,
                dueText: "\(prefix) \(Format.date(item.protectionEndsOn ?? item.dueOn))",
                protection: protection,
                sortKey: sortKey
            )
        case .dewormer, .ongoing:
            return PlanStatus(
                urgency: item.urgency,
                dueText: "Nächste \(dueNoun(plan)): \(Format.date(item.dueOn)) · \(Format.relativeDue(days: item.daysUntilDue))",
                protection: nil,
                sortKey: sortKey
            )
        }
    }

    /// „Termin am 12. Okt., 10:30 · Praxis am Park".
    static func appointmentText(_ appointment: VetAppointment) -> String {
        var text = "Termin am \(Format.dateTime(appointment.date))"
        if let practice = appointment.practice?.name, !practice.isEmpty {
            text += " · \(practice)"
        }
        return text
    }

    /// Bei Kotprobe statt Pauschalgabe fällig ist nicht die Gabe, sondern
    /// die Probe (PRD §5.2) — dieselbe Rechnung, andere Handlung.
    private static func dueNoun(_ plan: MedicationPlan) -> String {
        plan.kindValue == .dewormer && plan.usesFecalSampleInstead ? "Kotprobe" : "Gabe"
    }

    /// „12. Okt. 2026 · in 7 Tagen", bei „noch nie gegeben" nur „sofort".
    private static func dueLabel(_ item: DueItem) -> String {
        if item.urgency == .overdue, item.daysUntilDue == 0 {
            return "sofort"
        }
        return "\(Format.date(item.dueOn)) · \(Format.relativeDue(days: item.daysUntilDue))"
    }

    private static func missingConfiguration(for plan: MedicationPlan) -> String? {
        switch plan.kindValue {
        case .dewormer:
            return plan.intervalDays > 0 ? nil : "Intervall nicht hinterlegt"
        case .tickProtection:
            return plan.effectiveDays > 0 ? nil : "Wirkdauer nicht hinterlegt"
        case .rabiesVaccination, .vaccination:
            return plan.effectiveDays > 0 ? nil : "Gültigkeit nicht hinterlegt"
        case .ongoing:
            return plan.doseSchedule == nil ? "Keine Gabezeiten hinterlegt" : nil
        }
    }

    /// Restwirksamkeit nur aus echten Gaben — eine ausgelassene Zeckentablette
    /// schützt nicht.
    private static func protection(for plan: MedicationPlan, today: Date, dayMath: DayMath) -> ProtectionStatus? {
        guard plan.kindValue.usesEffectivePeriod, plan.effectiveDays > 0,
              let lastGivenOn = plan.lastGivenOn else { return nil }
        return MedicationCalculator(dayMath: dayMath).protectionStatus(
            lastGivenOn: lastGivenOn,
            effectiveDays: plan.effectiveDays,
            asOf: today
        )
    }

    private static func ongoingStatus(for plan: MedicationPlan, asOf: Date, dayMath: DayMath) -> PlanStatus {
        let calculator = MedicationCalculator(dayMath: dayMath)
        let today = dayMath.startOfDay(asOf)

        guard let schedule = plan.doseSchedule else {
            return unconfigured("Keine Gabezeiten hinterlegt")
        }
        if let endDate = plan.doseEndDate, dayMath.startOfDay(endDate) < today {
            return PlanStatus(
                urgency: nil,
                dueText: "Beendet am \(Format.date(endDate))",
                protection: nil,
                sortKey: .init(group: 3, days: 0)
            )
        }
        // Gleiche Grenze wie in der Engine: am Tag der Zurückstellung geht es
        // wieder los.
        if let deferral = plan.activeDeferral, dayMath.startOfDay(deferral) > today {
            let days = dayMath.days(from: today, to: deferral)
            return PlanStatus(
                urgency: Urgency(daysUntilDue: days),
                dueText: "Zurückgestellt bis \(Format.date(deferral))",
                protection: nil,
                sortKey: .init(group: 2, days: days)
            )
        }
        let occurrences = calculator.doseOccurrences(
            schedule: schedule,
            in: today...dayMath.adding(days: 30, to: today)
        )
        // Die nächste *noch offene* Uhrzeit, sonst die erste des Tages —
        // abends soll nicht die Morgengabe als „nächste" dastehen.
        guard let next = occurrences.first(where: { $0 >= asOf }) ?? occurrences.first else {
            return PlanStatus(
                urgency: nil,
                dueText: "Keine Gabe in den nächsten 30 Tagen",
                protection: nil,
                sortKey: .init(group: 3, days: 0)
            )
        }
        let days = dayMath.days(from: today, to: next)
        let when = dayMath.isSameDay(next, asOf)
            ? "heute \(Format.time(next))"
            : "\(Format.date(next)) · \(Format.time(next))"
        return PlanStatus(
            urgency: Urgency(daysUntilDue: days),
            dueText: "Nächste Gabe: \(when)",
            protection: nil,
            // Dauermedikamente werden über die Einzelgaben abgehakt, nicht
            // über „Gegeben" — deshalb hinter den Intervall-Fällen.
            sortKey: .init(group: 2, days: days)
        )
    }

    /// Die Gabezeiten eines Dauermedikaments am Tag von `asOf` — leer, solange
    /// der Plan über diesen Tag hinaus zurückgestellt ist. Gleiche Grenze wie
    /// `DueItemBuilder` und `MedicationReminderPlanner`: am Tag der
    /// Zurückstellung geht es wieder los. Das Ende liegt eine Sekunde vor
    /// Mitternacht, damit eine Gabe um 00:00 von morgen nicht mitkommt.
    static func todaysDoseOccurrences(for plan: MedicationPlan, asOf: Date, dayMath: DayMath) -> [Date] {
        guard let schedule = plan.doseSchedule else { return [] }
        let start = dayMath.startOfDay(asOf)
        if let deferral = plan.activeDeferral, dayMath.startOfDay(deferral) > start { return [] }
        let end = dayMath.adding(days: 1, to: start).addingTimeInterval(-1)
        return MedicationCalculator(dayMath: dayMath).doseOccurrences(schedule: schedule, in: start...end)
    }

    /// „Noch nie gegeben" ist die dringendste Form von offen, nicht die
    /// unwichtigste — gleiche Regel wie in `DueItemBuilder`, damit Liste und
    /// Dashboard dasselbe sagen.
    private static func neverGiven() -> PlanStatus {
        PlanStatus(
            urgency: .overdue,
            dueText: "Noch nie gegeben",
            protection: nil,
            sortKey: .init(group: 0, days: 0)
        )
    }

    private static func unconfigured(_ hint: String) -> PlanStatus {
        PlanStatus(urgency: nil, dueText: hint, protection: nil, sortKey: .init(group: 3, days: 0))
    }

    // MARK: Konfiguration im Detail

    struct ConfigurationRow: Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    /// Was der Plan konfiguriert hat — für den aufgeklappten Bereich.
    static func configuration(for plan: MedicationPlan) -> [ConfigurationRow] {
        kindConfiguration(for: plan) + stockConfiguration(for: plan)
    }

    private static func stockConfiguration(for plan: MedicationPlan) -> [ConfigurationRow] {
        guard plan.managesStock else { return [] }
        var rows = [ConfigurationRow(label: "Menge je Gabe", value: Format.amount(plan.amountPerGiving, unit: plan.stockUnit))]
        if plan.packageSize > 0 {
            rows.append(ConfigurationRow(label: "Packung", value: Format.amount(plan.packageSize, unit: plan.stockUnit)))
        }
        if let countedAt = plan.stockCountedAt {
            rows.append(ConfigurationRow(label: "Gezählt", value: Format.date(countedAt)))
        }
        if plan.needsPrescription {
            rows.append(ConfigurationRow(label: "Rezept", value: "nötig"))
        }
        return rows
    }

    private static func kindConfiguration(for plan: MedicationPlan) -> [ConfigurationRow] {
        switch plan.kindValue {
        case .dewormer:
            var rows = [
                ConfigurationRow(
                    label: "Intervall",
                    value: plan.intervalDays > 0 ? "alle \(durationLabel(days: plan.intervalDays))" : "nicht gesetzt"
                )
            ]
            if plan.usesFecalSampleInstead {
                rows.append(ConfigurationRow(label: "Statt Pauschalgabe", value: "Kotprobe"))
            }
            return rows

        case .tickProtection:
            return [
                ConfigurationRow(
                    label: "Wirkdauer",
                    value: plan.effectiveDays > 0 ? durationLabel(days: plan.effectiveDays) : "nicht gesetzt"
                )
            ]

        case .rabiesVaccination, .vaccination:
            var rows: [ConfigurationRow] = []
            if let lastGivenOn = plan.lastGivenOn {
                rows.append(ConfigurationRow(label: "Zuletzt geimpft", value: Format.date(lastGivenOn)))
            }
            rows.append(ConfigurationRow(
                label: "Gültigkeit",
                value: plan.effectiveDays > 0 ? durationLabel(days: plan.effectiveDays) : "nicht gesetzt"
            ))
            return rows

        case .ongoing:
            var rows: [ConfigurationRow] = []
            if let summary = scheduleSummary(for: plan) {
                rows.append(ConfigurationRow(label: "Dosierung", value: summary))
            }
            if let start = plan.doseStartDate {
                rows.append(ConfigurationRow(label: "Beginn", value: Format.date(start)))
            }
            if let end = plan.doseEndDate {
                rows.append(ConfigurationRow(label: "Ende", value: Format.date(end)))
            }
            return rows
        }
    }

    // MARK: Vorrat

    static func stockProjection(for plan: MedicationPlan, asOf: Date, dayMath: DayMath) -> StockProjection? {
        guard plan.managesStock else { return nil }
        return DueItemBuilder(dayMath: dayMath)
            .stockProjection(for: plan.engineInput(asOf: asOf, dayMath: dayMath), asOf: asOf)
    }

    /// „Vorrat: noch 12 Tabletten · reicht bis 17. Okt." `nil` ohne
    /// Vorratsverwaltung.
    static func stockText(for plan: MedicationPlan, asOf: Date, dayMath: DayMath) -> String? {
        guard let projection = stockProjection(for: plan, asOf: asOf, dayMath: dayMath) else { return nil }
        guard projection.remainingAmount > 0 else { return "Vorrat aufgebraucht" }
        var text = "Vorrat: noch \(Format.amount(projection.remainingAmount, unit: projection.unit))"
        if let reach = reachText(projection) { text += " · \(reach)" }
        return text
    }

    /// „reicht bis 17. Okt." — `nil`, wenn sich das nicht datieren lässt.
    static func reachText(_ projection: StockProjection) -> String? {
        if projection.coveredGivings == 0, projection.runsOutOn != nil {
            return "reicht nicht für die nächste Gabe"
        }
        // Ohne `runsOutOn` reicht der Vorrat bis zum Schemaende oder über die
        // Rechengrenze hinaus — dann steht nur die Menge da.
        guard projection.runsOutOn != nil, let last = projection.lastCoveredOn else { return nil }
        return "reicht bis \(Format.shortDate(last))"
    }

    // MARK: Historie

    /// Gaben absteigend nach Tag. Bei zwei Gaben am selben Tag entscheidet der
    /// Zeitpunkt der Erfassung — sonst springt die Liste bei jedem Neuzeichnen.
    static func history(for plan: MedicationPlan) -> [MedicationEvent] {
        plan.events.sorted {
            $0.givenOn == $1.givenOn ? $0.loggedAt > $1.loggedAt : $0.givenOn > $1.givenOn
        }
    }

    /// Abgehakte und ausgelassene Einzelgaben, jüngste zuerst.
    static func doseHistory(for plan: MedicationPlan, limit: Int = 10) -> [DoseLogEntry] {
        Array(plan.doseLogs.sorted { $0.scheduledAt > $1.scheduledAt }.prefix(limit))
    }

    // MARK: Sortierung

    /// Aktive Pläne, dringendstes zuerst, bei Gleichstand alphabetisch — damit
    /// die Reihenfolge bei unveränderten Daten stabil bleibt.
    static func sortedActivePlans(of pet: Pet, asOf: Date, dayMath: DayMath) -> [MedicationPlan] {
        // Schlüssel einmal vorberechnen statt im Vergleich: `status` ruft die
        // Engine, und ein `sorted`-Prädikat wird pro Vergleich neu ausgewertet.
        let ranked = pet.medicationPlans.filter(\.isActive).map { plan in
            (plan: plan, key: status(for: plan, asOf: asOf, dayMath: dayMath).sortKey, title: title(for: plan))
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            // Kein `map(\.plan)`: Key-Paths greifen nicht auf Tupel-Elemente zu.
            .map { $0.plan }
    }
}
