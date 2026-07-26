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
        return trimmed.isEmpty ? Format.label(plan.kindValue) : trimmed
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
        let calculator = MedicationCalculator(dayMath: dayMath)
        let today = dayMath.startOfDay(asOf)

        switch plan.kindValue {
        case .dewormer:
            guard plan.intervalDays > 0 else {
                return unconfigured("Intervall nicht hinterlegt")
            }
            guard let lastGivenOn = plan.lastGivenOn else { return neverGiven() }
            let dueness = calculator.dueness(
                lastGivenOn: lastGivenOn,
                intervalDays: plan.intervalDays,
                asOf: today
            )
            // Bei Kotprobe statt Pauschalgabe fällig ist nicht die Gabe, sondern
            // die Probe (PRD §5.2) — dieselbe Rechnung, andere Handlung.
            let noun = plan.usesFecalSampleInstead ? "Kotprobe" : "Gabe"
            return PlanStatus(
                urgency: Urgency(daysUntilDue: dueness.daysUntilDue),
                dueText: "Nächste \(noun): \(Format.date(dueness.dueOn)) · \(Format.relativeDue(days: dueness.daysUntilDue))",
                protection: nil,
                sortKey: .init(group: 1, days: dueness.daysUntilDue)
            )

        case .tickProtection, .rabiesVaccination:
            guard plan.effectiveDays > 0 else {
                return unconfigured(
                    plan.kindValue == .rabiesVaccination
                        ? "Gültigkeit nicht hinterlegt"
                        : "Wirkdauer nicht hinterlegt"
                )
            }
            guard let lastGivenOn = plan.lastGivenOn else { return neverGiven() }
            let protection = calculator.protectionStatus(
                lastGivenOn: lastGivenOn,
                effectiveDays: plan.effectiveDays,
                asOf: today
            )
            let prefix = plan.kindValue == .rabiesVaccination ? "Gültig bis" : "Schutz bis"
            return PlanStatus(
                urgency: Urgency(daysUntilDue: protection.remainingDays),
                dueText: "\(prefix) \(Format.date(protection.expiresOn))",
                protection: protection,
                sortKey: .init(group: 1, days: protection.remainingDays)
            )

        case .ongoing:
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

        case .rabiesVaccination:
            return [
                ConfigurationRow(
                    label: "Gültigkeit",
                    value: plan.effectiveDays > 0 ? durationLabel(days: plan.effectiveDays) : "nicht gesetzt"
                )
            ]

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

    // MARK: Historie

    /// Gaben absteigend nach Tag. Bei zwei Gaben am selben Tag entscheidet der
    /// Zeitpunkt der Erfassung — sonst springt die Liste bei jedem Neuzeichnen.
    static func history(for plan: MedicationPlan) -> [MedicationEvent] {
        plan.events.sorted {
            $0.givenOn == $1.givenOn ? $0.loggedAt > $1.loggedAt : $0.givenOn > $1.givenOn
        }
    }

    /// Abgehakte Einzelgaben, jüngste zuerst.
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
