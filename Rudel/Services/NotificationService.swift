import Foundation
import RudelEngine
import SwiftData
import UserNotifications

/// Bindeglied zwischen `NotificationPlanner` (reine Logik) und
/// `UNUserNotificationCenter` (System).
///
/// ## Was hier absichtlich *nicht* steht
///
/// Die Entscheidung, **welche** Erinnerung gesetzt wird, gehört in die Engine:
/// dort stehen die Invarianten und die Tests (`NotificationPlanner`). Dieser
/// Service übersetzt nur ein fertiges Plan-Ergebnis in `UNNotificationRequest`s
/// und liest den Systemzustand zurück. Läge die Priorisierung hier, wäre sie
/// ohne laufendes iOS nicht prüfbar.
///
/// ## Kein Singleton
///
/// Views dürfen eigene Instanzen verwenden; die gemeinsame Warteschlange
/// serialisiert Systemänderungen. Der Alarmservice ist für Tests injizierbar.
@MainActor
final class NotificationService {
    private static var schedulingTail: Task<Void, Never>?
    private static var schedulingToken = UUID()

    /// Tagesarithmetik in der Zeitzone des Geräts. Wird für das Planungsfenster
    /// gebraucht und an die Engine weitergegeben, damit „heute" dasselbe
    /// bedeutet wie auf dem Bildschirm.
    let dayMath: DayMath

    private let center = UNUserNotificationCenter.current()
    private let alarmServiceOverride: MedicationAlarmService?
    private var alarmService: MedicationAlarmService { alarmServiceOverride ?? .shared }

    /// `nonisolated`, damit eine SwiftUI-View den Service in einem
    /// Property-Initialisierer anlegen kann — der läuft nicht auf dem MainActor.
    /// Zulässig, weil hier nur Sendable-Werte gespeichert werden.
    nonisolated init(dayMath: DayMath = .current(), alarmService: MedicationAlarmService? = nil) {
        self.dayMath = dayMath
        self.alarmServiceOverride = alarmService
    }

    // MARK: - Ergebnis-Typen

    /// Ein Request, den das System nicht angenommen hat.
    ///
    /// Wird gesammelt und zurückgegeben statt verschluckt: bei einer App, deren
    /// Zweck „keine verpasste Gabe" ist, ist eine stillschweigend
    /// fehlgeschlagene Erinnerung der schlimmste Fehlermodus.
    struct ScheduleFailure: Sendable, Equatable, Identifiable {
        var id: String
        var title: String
        var reason: String
    }

    struct ApplyResult: Sendable, Equatable {
        /// Wie viele Erinnerungen gesetzt werden sollten.
        var requested: Int = 0
        /// Wie viele das System angenommen hat.
        var scheduled: Int = 0
        var failures: [ScheduleFailure] = []

        var isComplete: Bool { failures.isEmpty }
    }

    /// Ergebnis des kompletten Wegs (`reschedule`). Unterscheidet „nichts zu tun,
    /// weil abgeschaltet" von „durfte nicht" — die Einstellungen zeigen beides
    /// unterschiedlich an.
    enum RescheduleOutcome: Sendable {
        /// In den App-Einstellungen abgeschaltet. Ausstehende Erinnerungen
        /// wurden entfernt.
        case disabled
        /// Systemberechtigung fehlt. Es wurde nichts gesetzt und nichts entfernt.
        case notAuthorized(UNAuthorizationStatus)
        case applied(ApplyResult)
        case failed(String)

        var applyResult: ApplyResult? {
            if case .applied(let result) = self { return result }
            return nil
        }

        var scheduledCount: Int { applyResult?.scheduled ?? 0 }

        var failures: [ScheduleFailure] { applyResult?.failures ?? [] }
    }

    // MARK: - Berechtigung

    /// Fragt die Berechtigung an und liefert den Stand **danach**.
    @discardableResult
    func requestAuthorization() async -> UNAuthorizationStatus {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Ein Fehler hier heißt nicht „verweigert" — was wirklich gilt, sagt
            // nur `notificationSettings()`. Deshalb unten frisch lesen statt
            // hier zu raten.
        }
        return await authorizationStatus()
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Darf mit diesem Status gesetzt werden?
    ///
    /// Ein unbekannter künftiger Status wird als „versuchen" behandelt: ein
    /// echter Fehler landet sichtbar in `ApplyResult.failures`, während stilles
    /// Nichtstun niemandem auffällt.
    private static func canSchedule(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return true
        }
    }

    // MARK: - Setzen

    /// Gleiche Requests bleiben bestehen: insbesondere darf ein laufender
    /// Wiederholungs-Countdown nicht bei jedem App-Abgleich von vorn anfangen.
    @discardableResult
    func apply(_ planned: [NotificationPlanner.PlannedNotification], reminders: [MedicationReminder] = []) async -> ApplyResult {
        let existing = Dictionary(uniqueKeysWithValues: await center.pendingNotificationRequests().map { ($0.identifier, $0) })
        let desiredIDs = Set(planned.map(\.id))
        center.removePendingNotificationRequests(withIdentifiers: existing.keys.filter { !desiredIDs.contains($0) })
        var result = ApplyResult(requested: planned.count)
        for item in planned {
            let reminder = reminders.first { $0.sourceID == item.sourceID && $0.dueAt == item.dueAt && $0.category == item.category }
            let request = Self.request(for: item, reminder: reminder)
            if let old = existing[item.id], Self.canKeep(old, for: request) {
                result.scheduled += 1
                continue
            }
            do {
                try await center.add(request)
                result.scheduled += 1
            } catch {
                result.failures.append(ScheduleFailure(id: item.id, title: item.title, reason: error.localizedDescription))
            }
        }
        return result
    }

    static func request(for item: NotificationPlanner.PlannedNotification, reminder: MedicationReminder? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        content.threadIdentifier = item.petID
        content.categoryIdentifier = item.category.rawValue
        content.userInfo = ["petID": item.petID, "category": item.category.rawValue]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let reminder, Self.isMedication(reminder.category), let data = try? encoder.encode(reminder) {
            content.userInfo["medicationReminder"] = data
        }
        if Self.isMedication(item.category),
           let dueAt = item.dueAt, !item.sourceID.isEmpty {
            content.userInfo["medicationOccurrence"] = occurrenceKey(sourceID: item.sourceID, category: item.category, dueAt: dueAt)
        }
        let trigger: UNNotificationTrigger
        if let interval = item.repeatInterval {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, interval), repeats: true)
        } else {
            // Ortszeit ohne festgehaltene Zeitzone: die Wanduhr des Geräts gilt.
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }
        return UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
    }

    static func canKeep(_ existing: UNNotificationRequest, for desired: UNNotificationRequest) -> Bool {
        existing.identifier == desired.identifier && existing.content.isEqual(desired.content)
            && existing.trigger?.isEqual(desired.trigger) == true
    }

    static func reminders(from requests: [UNNotificationRequest]) -> [MedicationReminder] {
        requests.compactMap {
            guard let data = $0.content.userInfo["medicationReminder"] as? Data,
                  let reminder = try? JSONDecoder().decode(MedicationReminder.self, from: data),
                  Self.isMedication(reminder.category) else { return nil }
            return reminder
        }
    }

    func notificationReminders() async -> [MedicationReminder] {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications().map(\.request)
        return Self.reminders(from: pending + delivered)
    }

    private static func occurrenceKey(sourceID: String, category: DueItem.Category, dueAt: Date) -> String {
        "\(category.rawValue)|\(sourceID)|\(Int(dueAt.timeIntervalSince1970))"
    }

    private static func isMedication(_ category: DueItem.Category) -> Bool {
        switch category {
        case .medication, .protectionExpiry, .dose: return true
        case .cycleForecast, .criticalDays: return false
        }
    }

    private func removeCompletedMedicationNotifications(open reminders: [MedicationReminder]) async {
        let open = Set(reminders.map { Self.occurrenceKey(sourceID: $0.sourceID, category: $0.category, dueAt: $0.dueAt) })
        let completed = await center.deliveredNotifications().compactMap { notification -> String? in
            guard let category = DueItem.Category(rawValue: notification.request.content.categoryIdentifier),
                  Self.isMedication(category),
                  let key = notification.request.content.userInfo["medicationOccurrence"] as? String,
                  !open.contains(key) else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: completed)
    }

    /// Anzahl ausstehender Erinnerungen — für die Diagnose in den Einstellungen.
    func pendingCount() async -> Int {
        await center.pendingNotificationRequests().count
    }

    // MARK: - Der ganze Weg

    /// Modelle laden, Engine rechnen lassen, Erinnerungen setzen.
    ///
    /// Ein Aufruf pro Log-Vorgang: Dashboard und Sheets sollen nicht wissen
    /// müssen, welche Engine-Bausteine dafür nötig sind.
    ///
    /// Aktualisiert `settings.lastNotificationSyncAt`, wenn tatsächlich am
    /// System gearbeitet wurde — bei fehlender Berechtigung bleibt der alte
    /// Zeitstempel stehen, weil dann nichts gesetzt wurde.
    @discardableResult
    func reschedule(
        context: ModelContext,
        settings: AppSettings,
        asOf: Date = Date()
    ) async -> RescheduleOutcome {
        // Alle Aufrufer teilen dieselbe Warteschlange. Zwei View-Tasks dürfen
        // sich nicht gegenseitig Requests entfernen oder Schlummern zurücksetzen.
        let previous = Self.schedulingTail
        let token = UUID()
        Self.schedulingToken = token
        let task = Task { @MainActor in
            await previous?.value
            return await self.performReschedule(context: context, settings: settings, asOf: asOf)
        }
        Self.schedulingTail = Task { _ = await task.value }
        let result = await task.value
        if Self.schedulingToken == token { Self.schedulingTail = nil }
        return result
    }

    private func performReschedule(context: ModelContext, settings: AppSettings, asOf: Date) async -> RescheduleOutcome {
        let alarmService = self.alarmService
        guard settings.notificationsEnabled else {
            // Abschalten funktioniert unabhängig davon, ob die Alarmdatei
            // lesbar ist. Es benötigt nur den tatsächlichen Systemzustand.
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            _ = await alarmService.reconcile(reminders: [], configuration: settings.medicationAlarmConfiguration, asOf: asOf)
            settings.lastNotificationSyncAt = asOf
            do { try context.save() } catch { return .failed(error.localizedDescription) }
            if let issue = alarmService.issue { return .failed(issue) }
            return .disabled
        }
        let reminders: [MedicationReminder]
        let registryAvailable: Bool
        do {
            // Ein noch nicht gespeicherter Log darf keinen Alarm endgültig
            // abschalten. Bei Storefehlern bleibt der bisherige Systemstand stehen.
            try context.save()
            let notificationReminders = await notificationReminders()
            (reminders, registryAvailable) = try medicationSchedulingInput(context: context, settings: settings, retaining: notificationReminders, asOf: asOf)
        } catch {
            alarmService.reportFailure(error)
            return .failed(error.localizedDescription)
        }
        await removeCompletedMedicationNotifications(open: reminders)
        var handled = Set<String>()
        if registryAvailable || !settings.medicationAlarmsEnabled {
            handled = await alarmService.reconcile(
                reminders: reminders, configuration: settings.medicationAlarmConfiguration, asOf: asOf
            )
        }

        let planned = plannedNotifications(
            context: context, settings: settings, asOf: asOf,
            reminders: reminders, handledByAlarms: handled
        )
        if planned.isEmpty {
            return .applied(await apply([]))
        }
        var status = await authorizationStatus()
        if status == .notDetermined {
            // Der Nutzer hat Erinnerungen in der App eingeschaltet — der erste
            // echte Setz-Versuch ist der passende Moment für die Systemfrage.
            // Ohne das würde die App still nie erinnern.
            status = await requestAuthorization()
        }
        guard Self.canSchedule(status) else {
            return .notAuthorized(status)
        }

        let result = await apply(planned, reminders: reminders)
        settings.lastNotificationSyncAt = asOf
        try? context.save()
        return .applied(result)
    }

    /// Eine defekte Alarmdatei darf den unabhängigen Mitteilungsweg nicht
    /// blockieren. Ein unlesbarer medizinischer Store bleibt dagegen ein Fehler.
    func medicationSchedulingInput(context: ModelContext, settings: AppSettings, retaining notifications: [MedicationReminder] = [], asOf: Date) throws -> ([MedicationReminder], Bool) {
        var retained = notifications
        var registryAvailable = true
        do { retained += try alarmService.registeredReminders() }
        catch {
            registryAvailable = false
            alarmService.reportFailure(error)
        }
        return (try MedicationReminderData(dayMath: dayMath).reminders(
            context: context, settings: settings, retaining: retained, asOf: asOf
        ), registryAvailable)
    }

    /// Der Alarm übernimmt den eigentlichen Termin, eine normale Vorwarnung
    /// macht zusätzlich auf den beginnenden Countdown aufmerksam.
    private func notificationPlan(
        base: [NotificationPlanner.PlannedNotification], reminders: [MedicationReminder],
        handledByAlarms: Set<String>, settings: AppSettings, asOf: Date
    ) -> [NotificationPlanner.PlannedNotification] {
        let overdue = reminders.filter { $0.dueAt < asOf && !handledByAlarms.contains($0.id) }
        var candidates = base.filter { notification in
            !overdue.contains { $0.sourceID == notification.sourceID && $0.dueAt == notification.dueAt }
        }
        let retryInterval = Double(settings.medicationAlarmConfiguration.snoozeMinutes * 60)
        for reminder in overdue {
            candidates.append(NotificationPlanner.PlannedNotification(
                id: "retry:\(reminder.id)", fireDate: asOf.addingTimeInterval(retryInterval),
                title: "\(reminder.petName): Gabe noch offen",
                body: "\(reminder.title) · geplant \(Format.dateTime(reminder.dueAt)). Bitte die Gabe prüfen und bestätigen.",
                petID: reminder.petID, category: reminder.category, priority: 50,
                sourceID: reminder.sourceID, dueAt: reminder.dueAt, repeatInterval: retryInterval
            ))
        }
        let lead = settings.medicationAlarmConfiguration.leadMinutes
        if lead > 0 {
            for reminder in reminders {
                let fireDate = reminder.dueAt.addingTimeInterval(-Double(lead * 60))
                guard fireDate >= asOf else { continue }
                candidates.append(NotificationPlanner.PlannedNotification(
                    id: "advance:\(reminder.id)", fireDate: fireDate,
                    title: "\(reminder.petName): \(reminder.title) in \(lead) Minuten",
                    body: [reminder.detail, "Geplant um \(Format.time(reminder.dueAt))."].compactMap { $0 }.joined(separator: " · "),
                    petID: reminder.petID, category: reminder.category,
                    priority: dayMath.isSameDay(fireDate, asOf) ? 35 : 15,
                    sourceID: reminder.sourceID, dueAt: reminder.dueAt
                ))
            }
        }
        candidates.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.fireDate == $1.fireDate ? $0.id < $1.id : $0.fireDate < $1.fireDate
        }
        return Array(candidates.prefix(NotificationPlanner.budget)).sorted { $0.fireDate < $1.fireDate }
    }

    /// Der reine Teil von `reschedule`: aus dem Store das ableiten, was die
    /// Engine braucht, und den Plan zurückgeben. Ohne
    /// `UNUserNotificationCenter`, damit das Mapping prüfbar bleibt.
    func plannedNotifications(
        context: ModelContext,
        settings: AppSettings,
        asOf: Date,
        reminders: [MedicationReminder]? = nil,
        handledByAlarms: Set<String> = []
    ) -> [NotificationPlanner.PlannedNotification] {
        let descriptor = FetchDescriptor<Pet>(sortBy: [SortDescriptor(\.createdAt)])
        let pets = (try? context.fetch(descriptor)) ?? []

        let plannerSettings = settings.plannerSettings
        let windowStart = dayMath.startOfDay(asOf)
        let windowEnd = dayMath.adding(days: plannerSettings.horizonDays, to: asOf)
        // `ClosedRange` verlangt lower <= upper. `horizonDays` ist in
        // `NotificationPlanner.Settings` auf >= 1 geklemmt; das `max` hält die
        // Invariante trotzdem sichtbar, statt sie zu unterstellen.
        let window = windowStart...max(windowStart, windowEnd)

        let calculator = MedicationCalculator(dayMath: dayMath)
        let predictor = CycleIntervalPredictor(dayMath: dayMath)
        let criticalDaysAdvisor = CriticalDaysAdvisor(dayMath: dayMath)

        var medications: [DueItemBuilder.MedicationInput] = []
        var cycles: [DueItemBuilder.CycleInput] = []
        var doseOccurrences: [String: [Date]] = [:]
        var criticalDays: [String: [CriticalDayNotice]] = [:]

        for pet in pets {
            for plan in pet.medicationPlans {
                // Alle Pläne an die Engine: ob ein abgesetzter Plan ein Item
                // erzeugt, entscheidet `DueItemBuilder` über `isActive`.
                medications.append(plan.engineInput())

                // Einzelgaben dagegen müssen hier gefiltert werden — der Planner
                // bekommt sie als fertige Terminliste und kann `isActive` nicht
                // mehr sehen. Ohne diese Zeile erinnert ein abgesetztes
                // Dauermedikament weiter.
                guard plan.isActive, let schedule = plan.doseSchedule else { continue }
                let occurrences = calculator.doseOccurrences(schedule: schedule, in: window)
                let open = occurrences.filter { !isLogged($0, in: plan) }
                if !open.isEmpty {
                    doseOccurrences[plan.engineID] = open
                }
            }

            guard pet.tracksCycle else { continue }
            let periods = pet.cyclePeriods
            let anchors = periods.map(\.day1Date)
            // Ohne Tag-1-Anker gibt es keinen Referenzpunkt und damit keine
            // Prognose — die UI fordert dann zum Erfassen auf.
            guard !anchors.isEmpty else { continue }
            let history = CycleHistory(day1Anchors: anchors, sizeClass: pet.effectiveSizeClass)
            let prediction = predictor.predictNextCycle(history: history, asOf: asOf)
            // `sourceID` ist die letzte Läufigkeit, nicht das Tier: so kann eine
            // Zyklus-Prognose keine ID mit einem Medikament desselben Tieres
            // teilen.
            let latest = periods.max(by: { $0.day1Date < $1.day1Date })
            cycles.append(
                DueItemBuilder.CycleInput(
                    sourceID: latest?.engineID ?? pet.engineID,
                    petID: pet.engineID,
                    petName: pet.name,
                    prediction: prediction
                )
            )

            // Tageshinweise für die kritischen Tage der letzten Läufigkeit.
            //
            // Immer die neueste `CyclePeriod`: ob sie überhaupt noch relevant ist,
            // entscheidet der Advisor selbst — im Anöstrus gibt er nichts zurück.
            // Hier zu prüfen, ob die Hitze „noch läuft", würde diese Grenze an
            // zwei Stellen definieren, und die App-Schicht kennt sie schlechter.
            guard settings.criticalDayRemindersEnabled, let latest else { continue }
            let notices = criticalDaysAdvisor.notices(
                day1: latest.day1Date,
                signals: latest.phaseSignals,
                visibleHeatEnd: latest.visibleHeatEndDate,
                petName: pet.name,
                sourceID: latest.engineID,
                from: asOf,
                through: window.upperBound
            )
            if !notices.isEmpty {
                criticalDays[pet.engineID] = notices
            }
        }

        let dueItems = DueItemBuilder(dayMath: dayMath).build(
            medications: medications,
            cycles: cycles,
            asOf: asOf
        )

        let medicationReminders = reminders ?? ((try? MedicationReminderData(dayMath: dayMath).reminders(
            context: context, settings: settings, asOf: asOf
        )) ?? [])
        let base = NotificationPlanner(dayMath: dayMath).plan(
            dueItems: dueItems,
            doseOccurrences: doseOccurrences,
            medicationReminders: medicationReminders,
            criticalDays: criticalDays,
            alarmHandledReminders: medicationReminders.filter { handledByAlarms.contains($0.id) },
            settings: plannerSettings,
            asOf: asOf
        )
        return notificationPlan(base: base, reminders: medicationReminders, handledByAlarms: handledByAlarms, settings: settings, asOf: asOf)
    }

    /// Ist diese Einzelgabe schon abgehakt?
    ///
    /// Vergleich auf Minutengenauigkeit statt auf Gleichheit: `scheduledAt` und
    /// der von der Engine berechnete Termin entstehen an verschiedenen Stellen,
    /// eine Sekunde Abweichung darf keine doppelte Erinnerung erzeugen.
    private func isLogged(_ occurrence: Date, in plan: MedicationPlan) -> Bool {
        let key = minuteKey(occurrence)
        return plan.doseLogs.contains { minuteKey($0.scheduledAt) == key }
    }

    private func minuteKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }
}
