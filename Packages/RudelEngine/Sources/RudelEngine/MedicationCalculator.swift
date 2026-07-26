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
        // Eine nicht-positive Wirkdauer wird als Dauer null behandelt: der
        // Ablauftag ist dann der Gabetag selbst. Ein negatives `effectiveDays`
        // (kaputter Persistenz-Stand) darf `expiresOn` nicht vor die Gabe
        // schieben — das würde die UI „vor der Gabe abgelaufen" anzeigen.
        let duration = max(0, effectiveDays)
        let expiresOn = dayMath.adding(days: duration, to: lastGivenOn)
        let remainingDays = dayMath.days(from: asOf, to: expiresOn)

        // Am Gabetag ist `remainingDays == duration`, die Fraktion also genau 1,0.
        // Die Klemmung fängt beides ab: Überfälligkeit (negativ) und ein `asOf`
        // vor der Gabe (> 1).
        let remainingFraction = duration > 0
            ? min(max(Double(remainingDays) / Double(duration), 0), 1)
            : 0

        return ProtectionStatus(
            remainingFraction: remainingFraction,
            remainingDays: remainingDays,
            expiresOn: expiresOn,
            // Fraktion 0 und „abgelaufen" müssen dasselbe bedeuten, sonst zeigt
            // ProtectionBar einen leeren Balken ohne Ablauf-Hinweis. Am Ablauftag
            // selbst ist der Schutz damit schon weg („Heute abgelaufen").
            isExpired: remainingDays <= 0 || duration == 0
        )
    }

    /// Fälligkeit einer intervallbasierten Gabe (Wurmkur):
    /// `letzte Gabe + intervalDays`.
    ///
    /// - `intervalDays <= 0` ⇒ Fälligkeit = Gabetag selbst (sofort fällig).
    public func dueness(lastGivenOn: Date, intervalDays: Int, asOf: Date) -> IntervalDueness {
        let dueOn = dayMath.adding(days: max(0, intervalDays), to: lastGivenOn)
        let daysUntilDue = dayMath.days(from: asOf, to: dueOn)

        return IntervalDueness(
            dueOn: dueOn,
            daysUntilDue: daysUntilDue,
            // Heute fällig ist noch nicht überfällig — dieselbe Grenze wie in
            // `Urgency(daysUntilDue:)`, wo 0 auf `.dueToday` und erst < 0 auf
            // `.overdue` fällt. Sonst widersprechen sich Badge und Text.
            isOverdue: daysUntilDue < 0
        )
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
        // Ohne Uhrzeiten gibt es nichts zu erinnern (`timesOfDay` leer =
        // „keine Erinnerung", siehe DoseSchedule).
        guard !schedule.timesOfDay.isEmpty else { return [] }

        let step = max(1, schedule.everyNDays)
        let startDay = dayMath.startOfDay(schedule.startDate)

        // Letzter zu prüfender Gabetag: das Fenster begrenzt, zusätzlich die
        // Laufzeit. `endDate` schneidet auf *Tagesebene* ab — der Ablauftag wird
        // noch komplett gegeben, auch wenn `endDate` auf Mitternacht steht.
        var lastDay = dayMath.startOfDay(range.upperBound)
        if let endDate = schedule.endDate {
            lastDay = min(lastDay, dayMath.startOfDay(endDate))
        }
        guard startDay <= lastDay else { return [] }

        // Auf dem n-Tage-Raster ab `startDay` in das Fenster springen, statt jeden
        // Tag zu prüfen: bei everyNDays = 30 wären das 29 Leerläufe pro Gabe.
        let daysToWindow = dayMath.days(from: startDay, to: range.lowerBound)
        var offset = 0
        if daysToWindow > 0 {
            // Aufrunden auf das nächste Vielfache. Ist der Fensterbeginn selbst
            // ein Gabetag, bleibt er drin — eine spätere Uhrzeit an diesem Tag
            // kann noch im Fenster liegen.
            offset = ((daysToWindow + step - 1) / step) * step
        }

        var result: [Date] = []
        var previousDay: Date?
        while true {
            // Immer vom Startzeitpunkt aus rechnen (nicht Tag um Tag
            // weiterschieben), damit sich Rundungen nicht aufaddieren.
            let day = dayMath.adding(days: offset, to: startDay)
            // Bricht ab, falls der Kalender keinen Fortschritt liefert; praktisch
            // unerreichbar, aber die Schleife darf nicht hängen bleiben.
            if let previousDay, day <= previousDay { break }
            if day > lastDay { break }

            for time in schedule.timesOfDay {
                guard let moment = moment(of: time, on: day) else { continue }
                // Das Fenster wird zeitstempelgenau geprüft: eine Gabe, die heute
                // früh schon war, ist kein künftiger Termin mehr.
                if range.contains(moment) { result.append(moment) }
            }

            previousDay = day
            offset += step
        }

        // `timesOfDay` ist zwar veränderbar und könnte unsortiert sein — die
        // Zusage „aufsteigend" gilt trotzdem.
        return result.sorted()
    }

    /// Ist an `day` laut Schema eine Gabe vorgesehen?
    public func isDoseDay(schedule: DoseSchedule, day: Date) -> Bool {
        let step = max(1, schedule.everyNDays)
        let offset = dayMath.days(from: schedule.startDate, to: day)
        guard offset >= 0, offset % step == 0 else { return false }

        // `endDate` inklusiv: am Ablauftag wird noch gegeben.
        if let endDate = schedule.endDate, dayMath.days(from: day, to: endDate) < 0 {
            return false
        }
        // `timesOfDay` spielt hier bewusst keine Rolle: leer heißt „keine
        // Erinnerung", nicht „keine Gabe" — deshalb ist auch `dosesPerDay`
        // mindestens 1.
        return true
    }

    /// Setzt eine Uhrzeit auf einen Kalendertag.
    ///
    /// Über den Kalender statt über Sekunden-Addition: am Tag der Zeitumstellung
    /// hat der Tag 23 oder 25 Stunden, „09:00 lokal" bleibt aber 09:00. Existiert
    /// die Uhrzeit an diesem Tag nicht (Sprung nach vorn), liefert `.nextTime` den
    /// ersten Zeitpunkt danach — eine Erinnerung ausfallen zu lassen wäre der
    /// schlechtere Ausgang.
    private func moment(of time: TimeOfDay, on day: Date) -> Date? {
        let midnight = dayMath.startOfDay(day)
        return dayMath.calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: midnight
        ) ?? {
            var components = dayMath.calendar.dateComponents([.year, .month, .day], from: midnight)
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
            return dayMath.calendar.date(from: components)
        }()
    }
}
