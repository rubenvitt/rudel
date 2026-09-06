import Foundation
import RudelEngine
import SwiftData

/// Gemeinsame Sicht für Systemalarme, Mitteilungen und die Bestätigung einer
/// konkreten Gabe. Dashboard-Zeilen sind dafür keine vollständige Datenquelle.
@MainActor
struct MedicationReminderData {
    let dayMath: DayMath

    init(dayMath: DayMath = .current()) { self.dayMath = dayMath }

    func reminders(
        context: ModelContext, settings: AppSettings,
        retaining registered: [MedicationReminder] = [], asOf: Date
    ) throws -> [MedicationReminder] {
        let plans = try context.fetch(FetchDescriptor<MedicationPlan>())
        let inputs = plans.filter { $0.pet != nil }.map { $0.engineInput() }
        let logged = Dictionary(uniqueKeysWithValues: plans.map { ($0.engineID, $0.doseLogs.map(\.scheduledAt)) })
        let fresh = MedicationReminderPlanner(dayMath: dayMath).plan(
            medications: inputs, loggedDoses: logged,
            reminderTime: settings.reminderTime, horizonDays: settings.notificationHorizonDays, asOf: asOf
        )
        let byID = Dictionary(uniqueKeysWithValues: plans.map { ($0.engineID, $0) })
        // Bereits gemeldete, weiterhin offene Gaben überleben den Tageswechsel.
        // Termine außerhalb des heutigen Horizonts werden nicht neu erfunden.
        let retained = registered.compactMap { reminder -> MedicationReminder? in
            guard reminder.dueAt < dayMath.startOfDay(asOf), let plan = byID[reminder.sourceID],
                  isOpen(reminder, plan: plan, settings: settings) else { return nil }
            return MedicationReminderPlanner(dayMath: dayMath).plan(
                medications: [plan.engineInput()], loggedDoses: [:], reminderTime: settings.reminderTime,
                horizonDays: 0, asOf: reminder.dueAt
            ).first { $0.id == reminder.id }
        }
        var unique: [String: MedicationReminder] = [:]
        for reminder in retained + fresh { unique[reminder.id] = reminder }
        // Bei einem Plan ohne erste Gabe ist das bisherige Fälligkeitsdatum
        // maßgeblich; es soll nicht jede Mitternacht ein weiterer Alarm entstehen.
        let neverGivenSources = Set(retained.filter { $0.category != .dose && byID[$0.sourceID]?.lastGivenOn == nil }.map(\.sourceID))
        return unique.values.filter {
            !neverGivenSources.contains($0.sourceID) || $0.dueAt < dayMath.startOfDay(asOf)
        }.sorted { $0.dueAt == $1.dueAt ? $0.id < $1.id : $0.dueAt < $1.dueAt }
    }

    func isOpen(_ reminder: MedicationReminder, plan: MedicationPlan, settings: AppSettings) -> Bool {
        guard plan.isActive, plan.pet != nil, plan.engineID == reminder.sourceID else { return false }
        if reminder.category == .dose {
            guard let schedule = plan.doseSchedule else { return false }
            guard !plan.doseLogs.contains(where: { sameMinute($0.scheduledAt, reminder.dueAt) }) else { return false }
            let occurrences = MedicationCalculator(dayMath: dayMath).doseOccurrences(
                schedule: schedule, in: reminder.dueAt...reminder.dueAt
            )
            return !occurrences.isEmpty
        }
        guard plan.kindValue != .ongoing else { return false }
        let expected = MedicationReminderPlanner(dayMath: dayMath).plan(
            medications: [plan.engineInput()], loggedDoses: [:], reminderTime: settings.reminderTime,
            horizonDays: 1, asOf: reminder.dueAt
        )
        return expected.contains { $0.id == reminder.id }
    }

    func plan(for reminder: MedicationReminder, context: ModelContext) throws -> MedicationPlan? {
        guard let id = UUID(uuidString: reminder.sourceID) else { return nil }
        var descriptor = FetchDescriptor<MedicationPlan>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Die Bestätigung ist idempotent. Erst ein erfolgreicher Save erlaubt dem
    /// Aufrufer, Alarme abzuräumen; ein Fehler bleibt in der Ansicht sichtbar.
    @discardableResult
    func confirm(_ reminder: MedicationReminder, context: ModelContext, settings: AppSettings, asOf: Date) throws -> Bool {
        guard let plan = try plan(for: reminder, context: context) else { throw ConfirmationError.noLongerCurrent }
        if reminder.category == .dose,
           plan.doseLogs.contains(where: { sameMinute($0.scheduledAt, reminder.dueAt) }) { return false }
        if reminder.category != .dose,
           plan.events.contains(where: { dayMath.isSameDay($0.givenOn, asOf) }) { return false }
        guard isOpen(reminder, plan: plan, settings: settings) else { throw ConfirmationError.noLongerCurrent }

        if reminder.category == .dose {
            let log = DoseLogEntry(scheduledAt: reminder.dueAt, takenAt: asOf)
            context.insert(log)
            log.plan = plan
            do { try context.save() }
            catch { context.delete(log); throw error }
        } else {
            let event = MedicationEvent(givenOn: dayMath.startOfDay(asOf), loggedAt: asOf)
            context.insert(event)
            event.plan = plan
            do { try context.save() }
            catch { context.delete(event); throw error }
        }
        return true
    }

    private func sameMinute(_ lhs: Date, _ rhs: Date) -> Bool {
        Int(floor(lhs.timeIntervalSince1970 / 60)) == Int(floor(rhs.timeIntervalSince1970 / 60))
    }

    enum ConfirmationError: LocalizedError {
        case noLongerCurrent
        var errorDescription: String? { "Diese Gabe gehört nicht mehr zum aktuellen Plan. Bitte prüfe die Medikamentenliste." }
    }
}
