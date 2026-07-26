import Foundation
import SwiftData

@testable import Rudel

/// Frischer, leerer Store für einen einzelnen Test.
///
/// In-Memory statt Datei: kein Aufräumen zwischen Tests, kein geteilter Zustand.
/// Ein `ModelContext` ist trotzdem nötig und nicht optional — SwiftData löst die
/// Gegenseite einer Beziehung (`plan.events`, `pet.weightEntries`,
/// `period.observations`) nur für Objekte auf, die in einem Container hängen.
/// Genau diese Arrays sind der Kern der hier geprüften Adapter.
@MainActor
func makeContext() throws -> ModelContext {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: RudelApp.schema, configurations: [configuration])
    return ModelContext(container)
}

/// Feste Datums-Fixtures.
///
/// Niemals `Date()` in diesen Tests: die Adapter sortieren und vergleichen
/// Daten: mit einem wandernden Bezugspunkt wäre ein Fehlschlag nicht
/// reproduzierbar. Wichtig ist außerdem, dass **jeder** Datums-Parameter der
/// Modell-Initializer explizit gesetzt wird — deren Defaults sind `Date()`.
enum Fixture {
    /// Gregorianisch in UTC, dieselbe Rechenbasis wie `DayMath.utc`. Sonst
    /// verschöbe die Zeitzone des Testrechners die Tagesgrenzen.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// Mitternacht des angegebenen Tages.
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        // Für ein gültiges Datum liefert der gregorianische Kalender immer ein
        // Ergebnis; der Fallback steht hier nur, damit kein `!` im Testcode ist.
        return calendar.date(from: parts) ?? .distantPast
    }

    /// Ersatz für „jetzt" in `loggedAt`/`createdAt`-Parametern, die keine Rolle
    /// für die geprüfte Logik spielen, aber sonst `Date()` wären.
    static let logged: Date = day(2026, 7, 26)
}
