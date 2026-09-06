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

    var medicationAlarmsEnabled: Bool = true
    var medicationLeadMinutes: Int = 30
    var medicationSnoozeMinutes: Int = 10

    /// Vorwarnzeiten in Tagen vor Fälligkeit (PRD §5.6). Absteigend.
    var leadDays: [Int] = [7, 1, 0]

    /// Uhrzeit der Fälligkeits-Erinnerungen, Minuten nach Mitternacht.
    var reminderMinutesFromMidnight: Int = 9 * 60

    /// Länge des rollierenden Benachrichtigungs-Fensters in Tagen.
    /// Siehe `NotificationPlanner` — iOS erlaubt nur 64 ausstehende Requests,
    /// deshalb wird nicht der ganze Horizont geplant.
    var notificationHorizonDays: Int = 14

    /// Tägliche Hinweise während einer laufenden Läufigkeit (siehe
    /// `CriticalDaysAdvisor`).
    ///
    /// Standardmäßig an: die Erinnerung nützt nur, wenn sie kommt, ohne dass man
    /// sie erst sucht. Abschaltbar, weil sie über Wochen täglich auftritt und das
    /// bei einem kastrierten oder nicht gefährdeten Tier nur Lärm wäre.
    var criticalDayRemindersEnabled: Bool = true

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
    var medicationAlarmConfiguration: MedicationAlarmConfiguration {
        MedicationAlarmConfiguration(
            enabled: notificationsEnabled && medicationAlarmsEnabled,
            leadMinutes: medicationLeadMinutes,
            snoozeMinutes: medicationSnoozeMinutes
        )
    }
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

        // Nach ID sortieren, nicht nach Fetch-Reihenfolge: legten zwei Geräte
        // je eine Instanz an, müssen beide dieselbe behalten, sonst löscht jedes
        // die des anderen.
        let sorted = existing.sorted { $0.id.uuidString < $1.id.uuidString }
        if let keeper = sorted.first {
            for duplicate in sorted.dropFirst() {
                context.delete(duplicate)
            }
            if sorted.count > 1 {
                try? context.save()
            }
            return keeper
        }

        let settings = AppSettings()
        context.insert(settings)
        try? context.save()
        return settings
    }
}
