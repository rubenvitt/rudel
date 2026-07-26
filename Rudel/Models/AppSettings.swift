import Foundation
import RudelEngine
import SwiftData

/// Einstellungen der App. Genau **eine** Instanz im Store.
///
/// Kein `@Attribute(.unique)` zur Erzwingung — CloudKit erlaubt das nicht.
/// Stattdessen sorgt `AppSettings.loadOrCreate(in:)` für Einmaligkeit und
/// räumt Duplikate ab, falls je zwei Geräte gleichzeitig eine Instanz anlegen.
@Model
final class AppSettings {
    var id: UUID = UUID()

    var notificationsEnabled: Bool = true

    /// Vorwarnzeiten in Tagen vor Fälligkeit (PRD §5.6). Absteigend.
    var leadDays: [Int] = [7, 1, 0]

    /// Uhrzeit der Fälligkeits-Erinnerungen, Minuten nach Mitternacht.
    var reminderMinutesFromMidnight: Int = 9 * 60

    /// Länge des rollierenden Benachrichtigungs-Fensters in Tagen.
    /// Siehe `NotificationPlanner` — iOS erlaubt nur 64 ausstehende Requests,
    /// deshalb wird nicht der ganze Horizont geplant.
    var notificationHorizonDays: Int = 14

    /// Zuletzt gewähltes Tier, damit die App dort weitermacht, wo sie war.
    var selectedPetID: UUID?

    /// Wann zuletzt Benachrichtigungen neu gesetzt wurden — für Diagnose.
    var lastNotificationSyncAt: Date?

    /// Wurde der Erst-Setup-Flow abgeschlossen?
    var didCompleteOnboarding: Bool = false

    init() {
        self.id = UUID()
    }
}

extension AppSettings {
    var reminderTime: TimeOfDay {
        TimeOfDay(
            hour: reminderMinutesFromMidnight / 60,
            minute: reminderMinutesFromMidnight % 60
        )
    }

    var plannerSettings: NotificationPlanner.Settings {
        NotificationPlanner.Settings(
            leadDays: leadDays,
            reminderTime: reminderTime,
            horizonDays: notificationHorizonDays
        )
    }

    /// Holt die Einstellungen, legt sie beim ersten Start an und räumt
    /// eventuelle Duplikate ab (siehe Klassenkommentar).
    @MainActor
    static func loadOrCreate(in context: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        let existing = (try? context.fetch(descriptor)) ?? []

        if let first = existing.first {
            // Deterministisch die älteste behalten, damit zwei Geräte zum
            // gleichen Ergebnis kommen.
            let sorted = existing.sorted { $0.id.uuidString < $1.id.uuidString }
            let keeper = sorted[0]
            for duplicate in sorted.dropFirst() {
                context.delete(duplicate)
            }
            if existing.count > 1 {
                try? context.save()
            }
            return existing.count > 1 ? keeper : first
        }

        let settings = AppSettings()
        context.insert(settings)
        try? context.save()
        return settings
    }
}
