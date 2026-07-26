import Foundation

/// Tierart. Die Zyklus-Logik gilt ausschließlich für Hündinnen: Katzen sind
/// saisonal polyöstrisch mit induzierter Ovulation und einem ganz anderen
/// Rhythmus (Östrus alle 2–3 Wochen innerhalb der Saison). Die Engine
/// modelliert das bewusst nicht — `CycleIntervalPredictor` ist nur für
/// `.dog` definiert, und die UI blendet das Zyklus-Modul für Katzen aus.
public enum Species: String, Sendable, Codable, CaseIterable, Hashable {
    case dog
    case cat
}

/// Größenklasse einer Hündin, abgeleitet aus dem Gewicht.
/// Beeinflusst nur den Startwert des Zyklusintervalls
/// (`StudyConstants.intervalBiasDays(for:)`).
public enum DogSizeClass: String, Sendable, Codable, CaseIterable, Hashable {
    case small   // < 10 kg
    case medium  // 10–25 kg
    case large   // 25–45 kg
    case giant   // > 45 kg

    /// Ordnet ein Gewicht der Größenklasse zu. Die Grenzen sind die in der
    /// Kleintiermedizin üblichen Klassen, keine Studienwerte.
    public init(weightKg: Double) {
        switch weightKg {
        case ..<10: self = .small
        case ..<25: self = .medium
        case ..<45: self = .large
        default: self = .giant
        }
    }
}

/// Wie belastbar eine Prognose ist. Wird in der UI immer mitangezeigt —
/// eine Prognose ohne Konfidenzangabe darf nicht dargestellt werden (PRD §6).
public enum Confidence: Int, Sendable, Codable, CaseIterable, Comparable, Hashable {
    /// Nur Populationswerte, keine eigenen Intervalle.
    case low = 0
    /// 1–2 eigene Intervalle: Richtung stimmt, Breite noch grob.
    case moderate = 1
    /// Ab 3 eigenen Intervallen.
    case high = 2

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Konfidenz aus der Anzahl **Intervalle** (nicht Zyklen!).
    ///
    /// Der Unterschied ist der Grund, warum PRD §6.1 in der ursprünglichen
    /// Fassung nicht rechnete: 2 geloggte Tag-1-Daten ergeben *ein* Intervall.
    /// Mittelwert einer Einzelstichprobe ist sie selbst, ihre SD ist 0 — das
    /// Konfidenzband wäre auf Breite null kollabiert, genau dort, wo es sich
    /// erst anfangen soll zu verengen.
    public init(ownIntervalCount: Int) {
        switch ownIntervalCount {
        case ..<1: self = .low
        case 1...2: self = .moderate
        default: self = .high
        }
    }
}

/// Tagesgenaue Datumsarithmetik. Der Zyklus wird in *Kalendertagen* gerechnet,
/// nicht in 86400-Sekunden-Schritten — sonst verschiebt Sommerzeit Prognosen.
/// Kalender und Zeitzone sind injizierbar, damit Tests deterministisch sind.
public struct DayMath: Sendable {
    public let calendar: Calendar

    /// Gregorianischer Kalender in UTC. Default für Tests und Engine-Rechnung:
    /// die Engine kennt keine Uhrzeiten, nur Tage.
    public static let utc: DayMath = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return DayMath(calendar: cal)
    }()

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    /// Kalender der aktuellen Umgebung — für die App-Schicht, damit „heute"
    /// dem entspricht, was der Nutzer auf dem Gerät sieht.
    public static func current() -> DayMath {
        DayMath(calendar: .current)
    }

    /// Mitternacht des Tages, in dem `date` liegt.
    public func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Ganze Kalendertage von `from` bis `to`. Negativ, wenn `to` früher liegt.
    public func days(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(from), to: startOfDay(to)).day ?? 0
    }

    /// `date` plus `days` Kalendertage, auf Mitternacht normalisiert.
    /// Fällt auf `date` zurück, wenn der Kalender kein Ergebnis liefert
    /// (praktisch unerreichbar, aber die Engine wirft nicht).
    public func adding(days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: startOfDay(date)) ?? startOfDay(date)
    }

    /// Liegen beide Daten am selben Kalendertag?
    public func isSameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }
}
