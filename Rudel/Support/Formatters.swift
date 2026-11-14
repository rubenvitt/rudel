import Foundation
import RudelEngine

/// Aufbereitung für die Anzeige. An einer Stelle, damit „in 3 Tagen" überall
/// gleich formuliert ist.
enum Format {

    // MARK: Datum

    static func date(_ value: Date) -> String {
        value.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func shortDate(_ value: Date) -> String {
        value.formatted(.dateTime.day().month(.abbreviated))
    }

    static func dateTime(_ value: Date) -> String {
        value.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func time(_ value: Date) -> String {
        value.formatted(.dateTime.hour().minute())
    }

    /// Uhrzeit ohne Datum im Format des Gebietsschemas („08:00", „8:00 AM").
    static func time(_ value: TimeOfDay) -> String {
        // Fester Bezugstag ohne Zeitumstellung, damit keine Uhrzeit ausfällt.
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = value.hour
        components.minute = value.minute
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d:%02d", value.hour, value.minute)
        }
        return time(date)
    }

    /// Datumsspanne als „12. – 26. Aug." bzw. mit Jahr, wenn sie es kreuzt.
    static func dateRange(_ range: ClosedRange<Date>, calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: range.lowerBound)
            == calendar.component(.year, from: range.upperBound)
        if sameYear {
            return "\(shortDate(range.lowerBound)) – \(date(range.upperBound))"
        }
        return "\(date(range.lowerBound)) – \(date(range.upperBound))"
    }

    // MARK: Relative Fälligkeit

    /// „Heute", „Morgen", „in 5 Tagen", „3 Tage überfällig".
    ///
    /// Bewusst nicht `RelativeDateTimeFormatter`: der sagt bei negativen Werten
    /// „vor 3 Tagen", was bei einer Fälligkeit falsch klingt — überfällig ist
    /// kein Rückblick, sondern ein offener Posten.
    static func relativeDue(days: Int) -> String {
        switch days {
        case 0: return String(localized: "Heute")
        case 1: return String(localized: "Morgen", comment: "Fälligkeit: morgen (der nächste Tag)")
        case 2...: return String(localized: "in \(days) Tagen", comment: "Fälligkeit in der Zukunft")
        default:
            let overdue = abs(days)
            return String(localized: "\(overdue) Tage überfällig", comment: "Fälligkeit überschritten")
        }
    }

    /// „vor 3 Tagen", „heute", für zurückliegende Einträge.
    static func relativePast(days: Int) -> String {
        switch days {
        case 0: return String(localized: "heute", comment: "Rückblick, kleingeschrieben im Satz")
        case 1: return String(localized: "gestern", comment: "Rückblick, kleingeschrieben im Satz")
        case 2...: return String(localized: "vor \(days) Tagen", comment: "Rückblick")
        default:
            let ahead = abs(days)
            return String(localized: "in \(ahead) Tagen", comment: "Fälligkeit in der Zukunft")
        }
    }

    static func dayCount(_ days: Int) -> String {
        String(localized: "\(days) Tage", comment: "Anzahl Tage")
    }

    /// Breite des Prognosebandes als Text.
    ///
    /// Ohne eigene Intervalle ist das Band die publizierte Populationsspanne
    /// (135–300 Tage ab dem Anker) und liegt damit **asymmetrisch** um die
    /// Punktschätzung — 210 ist nicht die Mitte von 135 und 300, und der
    /// Größenklassen-Bias verschiebt sie zusätzlich. Ein „± 83 Tage" wäre dort
    /// nicht nur ungenau, es widerspräche der direkt daneben angezeigten
    /// Spanne. Deshalb wird in dem Fall die Herkunft benannt statt eine
    /// Halbbreite behauptet.
    static func bandWidth(_ prediction: CyclePrediction) -> String {
        switch prediction.basis {
        case .population:
            return String(localized: "Populationsspanne", comment: "Prognoseband aus der publizierten Spanne der Population statt aus eigenen Daten")
        case .blended:
            return "± " + dayCount(Int(prediction.bandHalfWidthDays.rounded()))
        }
    }

    // MARK: Werte

    static func weight(_ kg: Double) -> String {
        kg.formatted(.number.precision(.fractionLength(0...2))) + " kg"
    }

    /// Vorratsmenge: „12", „1,5". Ohne Tausendertrenner, weil der Wert auch
    /// als Eingabe vorbelegt wird und „1.000" sonst als 1 zurückkäme.
    static func amount(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    /// „12 Tabletten", ohne Einheit nur die Zahl.
    static func amount(_ value: Double, unit: String) -> String {
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        return unit.isEmpty ? amount(value) : "\(amount(value)) \(unit)"
    }

    static func grams(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + " g"
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func progesterone(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " ng/ml"
    }

    // MARK: Domänen-Begriffe

    static func label(_ phase: CyclePhase) -> String {
        switch phase {
        case .proestrus: return String(localized: "Proöstrus")
        case .estrus: return String(localized: "Östrus")
        case .diestrus: return String(localized: "Diöstrus")
        case .anestrus: return String(localized: "Anöstrus")
        }
    }

    /// Was in der Phase gerade passiert — für die Erklärzeile unter der Phase.
    static func explanation(_ phase: CyclePhase) -> String {
        switch phase {
        case .proestrus:
            return String(localized: "Vorbereitung. Blutiger Ausfluss, pralle Vulva, Rüden interessieren sich — sie duldet aber noch nicht.")
        case .estrus:
            return String(localized: "Fruchtbare Phase. Ausfluss wird strohfarben, Vulva weicher, Duldungsbereitschaft.")
        case .diestrus:
            return String(localized: "Nachlauf, 60–90 Tage. Anzeichen klingen ab; Scheinträchtigkeit ist hier möglich.")
        case .anestrus:
            return String(localized: "Ruhephase bis zur nächsten Läufigkeit.")
        }
    }

    static func label(_ kind: MedicationKind) -> String {
        switch kind {
        case .dewormer: return String(localized: "Wurmkur")
        case .tickProtection: return String(localized: "Zeckenschutz")
        case .ongoing: return String(localized: "Laufendes Medikament")
        case .rabiesVaccination: return String(localized: "Tollwut-Impfung")
        case .vaccination: return String(localized: "Impfung")
        }
    }

    static func symbolName(_ kind: MedicationKind) -> String {
        switch kind {
        case .dewormer: return "pill"
        case .tickProtection: return "shield.lefthalf.filled"
        case .ongoing: return "calendar.badge.clock"
        case .rabiesVaccination, .vaccination: return "syringe"
        }
    }

    static func label(_ color: DischargeColor) -> String {
        switch color {
        case .bloody: return String(localized: "Blutig")
        case .brownish: return String(localized: "Bräunlich")
        case .pinkish: return String(localized: "Rosa")
        case .strawColored: return String(localized: "Strohfarben")
        case .clear: return String(localized: "Klar")
        }
    }

    static func label(_ amount: DischargeAmount) -> String {
        switch amount {
        case .none: return String(localized: "Keiner")
        case .scant: return String(localized: "Wenig")
        case .moderate: return String(localized: "Mittel", comment: "Menge oder Schweregrad: mittel")
        case .heavy: return String(localized: "Viel")
        }
    }

    static func label(_ turgor: VulvaTurgor) -> String {
        switch turgor {
        case .normal: return String(localized: "Normal")
        case .swollenFirm: return String(localized: "Geschwollen, prall")
        case .softening: return String(localized: "Wird weicher")
        case .swollenSoft: return String(localized: "Geschwollen, weich")
        }
    }

    static func label(_ sizeClass: DogSizeClass) -> String {
        switch sizeClass {
        case .small: return String(localized: "Klein (< 10 kg)")
        case .medium: return String(localized: "Mittel (10–25 kg)")
        case .large: return String(localized: "Groß (25–45 kg)")
        case .giant: return String(localized: "Sehr groß (> 45 kg)")
        }
    }
}
