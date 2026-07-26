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

    static func time(_ value: TimeOfDay) -> String {
        String(format: "%02d:%02d", value.hour, value.minute)
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
        case 0: return "Heute"
        case 1: return "Morgen"
        case 2...: return "in \(days) Tagen"
        case -1: return "1 Tag überfällig"
        default: return "\(abs(days)) Tage überfällig"
        }
    }

    /// „vor 3 Tagen", „heute", für zurückliegende Einträge.
    static func relativePast(days: Int) -> String {
        switch days {
        case 0: return "heute"
        case 1: return "gestern"
        case 2...: return "vor \(days) Tagen"
        default: return "in \(abs(days)) Tagen"
        }
    }

    static func dayCount(_ days: Int) -> String {
        "\(days) \(abs(days) == 1 ? "Tag" : "Tage")"
    }

    // MARK: Werte

    static func weight(_ kg: Double) -> String {
        kg.formatted(.number.precision(.fractionLength(0...2))) + " kg"
    }

    static func grams(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + " g"
    }

    static func percent(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(0))) + " %"
    }

    static func progesterone(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " ng/ml"
    }

    // MARK: Domänen-Begriffe

    static func label(_ phase: CyclePhase) -> String {
        switch phase {
        case .proestrus: return "Proöstrus"
        case .estrus: return "Östrus"
        case .diestrus: return "Diöstrus"
        case .anestrus: return "Anöstrus"
        }
    }

    /// Was in der Phase gerade passiert — für die Erklärzeile unter der Phase.
    static func explanation(_ phase: CyclePhase) -> String {
        switch phase {
        case .proestrus:
            return "Vorbereitung. Blutiger Ausfluss, pralle Vulva, Rüden interessieren sich — sie duldet aber noch nicht."
        case .estrus:
            return "Fruchtbare Phase. Ausfluss wird strohfarben, Vulva weicher, Duldungsbereitschaft."
        case .diestrus:
            return "Nachlauf, 60–90 Tage. Anzeichen klingen ab; Scheinträchtigkeit ist hier möglich."
        case .anestrus:
            return "Ruhephase bis zur nächsten Läufigkeit."
        }
    }

    static func label(_ kind: MedicationKind) -> String {
        switch kind {
        case .dewormer: return "Wurmkur"
        case .tickProtection: return "Zeckenschutz"
        case .ongoing: return "Laufendes Medikament"
        case .rabiesVaccination: return "Tollwut-Impfung"
        }
    }

    static func symbolName(_ kind: MedicationKind) -> String {
        switch kind {
        case .dewormer: return "pill"
        case .tickProtection: return "shield.lefthalf.filled"
        case .ongoing: return "calendar.badge.clock"
        case .rabiesVaccination: return "syringe"
        }
    }

    static func label(_ color: DischargeColor) -> String {
        switch color {
        case .bloody: return "Blutig"
        case .brownish: return "Bräunlich"
        case .pinkish: return "Rosa"
        case .strawColored: return "Strohfarben"
        case .clear: return "Klar"
        }
    }

    static func label(_ amount: DischargeAmount) -> String {
        switch amount {
        case .none: return "Keiner"
        case .scant: return "Wenig"
        case .moderate: return "Mittel"
        case .heavy: return "Viel"
        }
    }

    static func label(_ turgor: VulvaTurgor) -> String {
        switch turgor {
        case .normal: return "Normal"
        case .swollenFirm: return "Geschwollen, prall"
        case .softening: return "Wird weicher"
        case .swollenSoft: return "Geschwollen, weich"
        }
    }

    static func label(_ sizeClass: DogSizeClass) -> String {
        switch sizeClass {
        case .small: return "Klein (< 10 kg)"
        case .medium: return "Mittel (10–25 kg)"
        case .large: return "Groß (25–45 kg)"
        case .giant: return "Sehr groß (> 45 kg)"
        }
    }
}
