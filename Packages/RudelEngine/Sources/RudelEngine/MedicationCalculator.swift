import Foundation

/// Fälligkeiten und Restwirksamkeit von Gaben (PRD §6.4).
public struct MedicationCalculator: Sendable {
    public let dayMath: DayMath

    public init(dayMath: DayMath = .utc) {
        self.dayMath = dayMath
    }

    /// Restwirksamkeit eines Schutzes: `(Wirkdauer − vergangene Tage) / Wirkdauer`.
    ///
    /// - `remainingFraction` wird auf `0...1` geklemmt: der Balken läuft nicht
    ///   rückwärts, wenn der Schutz überfällig ist. Das Ausmaß der Überfälligkeit
    ///   steht in `remainingDays` (dann negativ).
    /// - Am Gabetag selbst ist die Fraktion 1,0 (voller Schutz).
    /// - `effectiveDays <= 0` ⇒ sofort abgelaufen, Fraktion 0. Defensiv statt
    ///   Division durch Null.
    public func protectionStatus(lastGivenOn: Date, effectiveDays: Int, asOf: Date) -> ProtectionStatus {
        fatalError("unimplemented")
    }

    /// Fälligkeit einer intervallbasierten Gabe (Wurmkur):
    /// `letzte Gabe + intervalDays`.
    ///
    /// - `intervalDays <= 0` ⇒ Fälligkeit = Gabetag selbst (sofort fällig).
    public func dueness(lastGivenOn: Date, intervalDays: Int, asOf: Date) -> IntervalDueness {
        fatalError("unimplemented")
    }

    /// Alle Einzelgaben eines Dosierschemas innerhalb von `range`.
    ///
    /// Grundlage für die Notification-Planung: ein tägliches Medikament mit
    /// 2 Gaben erzeugt 2 Termine pro Tag. Berücksichtigt `everyNDays` ab
    /// `schedule.startDate` und schneidet an `schedule.endDate` ab.
    ///
    /// Rückgabe aufsteigend sortiert. Leer, wenn `timesOfDay` leer ist oder
    /// `range` vollständig außerhalb der Laufzeit liegt.
    ///
    /// Die Termine tragen die Uhrzeit aus `timesOfDay` — anders als der Rest
    /// der Engine, die auf Tagesebene rechnet, weil eine Dosis-Erinnerung eine
    /// Uhrzeit braucht.
    public func doseOccurrences(schedule: DoseSchedule, in range: ClosedRange<Date>) -> [Date] {
        fatalError("unimplemented")
    }

    /// Ist an `day` laut Schema eine Gabe vorgesehen?
    public func isDoseDay(schedule: DoseSchedule, day: Date) -> Bool {
        fatalError("unimplemented")
    }
}
