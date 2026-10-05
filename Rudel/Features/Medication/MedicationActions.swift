import Foundation
import RudelEngine
import SwiftData

/// Erfassungswege, die Liste und Heute teilen. An einer Stelle, damit
/// „Auslassen" auf beiden Screens dasselbe Journal schreibt.
@MainActor
enum MedicationActions {

    /// „Diesmal auslassen": ein Journal-Eintrag mit `outcome = .skipped` am
    /// heutigen Tag. Die nächste Fälligkeit rechnet ab hier, der Schutz nicht.
    ///
    /// Ein zweites Auslassen am selben Tag ist ein Doppeltipp und legt nichts an.
    static func skip(_ plan: MedicationPlan, context: ModelContext, dayMath: DayMath, asOf: Date = Date()) {
        let today = dayMath.startOfDay(asOf)
        let alreadySkipped = plan.events.contains {
            $0.outcomeValue == .skipped && dayMath.isSameDay($0.givenOn, today)
        }
        guard !alreadySkipped else { return }
        let event = MedicationEvent(givenOn: today, outcome: .skipped)
        context.insert(event)
        // Beziehung über die To-One-Seite; `inverse:` sitzt auf `MedicationPlan.events`.
        event.plan = plan
        try? context.save()
    }

    /// Neue Zählung: Bestand und Zeitpunkt. Ab hier zählen die Gaben neu —
    /// der Restbestand wird nie direkt heruntergezählt.
    static func recordStockCount(_ plan: MedicationPlan, amount: Double, at date: Date) {
        plan.stockAmount = max(0, amount)
        plan.stockCountedAt = date
    }

    /// Plant die Mitteilungen neu. Nötig nach Änderungen, die keinen
    /// Journal-Eintrag anlegen (Zurückstellen, Erinnerungsklasse) — die zählt
    /// der Fingerabdruck in `RootView` nicht zuverlässig mit.
    static func refreshNotifications(context: ModelContext) {
        let settings = AppSettings.loadOrCreate(in: context)
        Task { await NotificationService().reschedule(context: context, settings: settings) }
    }
}
