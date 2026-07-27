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
/// Der Service hält keinen Zustand — jede View darf sich eine eigene Instanz
/// anlegen (`NotificationService()`), das ist so gut wie eine geteilte. Deshalb
/// gibt es bewusst kein `shared`, das später jeder Testaufbau umgehen müsste.
@MainActor
final class NotificationService {

    /// Tagesarithmetik in der Zeitzone des Geräts. Wird für das Planungsfenster
    /// gebraucht und an die Engine weitergegeben, damit „heute" dasselbe
    /// bedeutet wie auf dem Bildschirm.
    let dayMath: DayMath

    private let center = UNUserNotificationCenter.current()

    /// `nonisolated`, damit eine SwiftUI-View den Service in einem
    /// Property-Initialisierer anlegen kann — der läuft nicht auf dem MainActor.
    /// Zulässig, weil hier nur Sendable-Werte gespeichert werden.
    nonisolated init(dayMath: DayMath = .current()) {
        self.dayMath = dayMath
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

    /// Ersetzt alle ausstehenden Erinnerungen durch `planned`.
    ///
    /// `removeAll` + neu setzen statt inkrementellem Abgleich: der Planner
    /// liefert ein vollständiges Fenster, also ist der Zielzustand bekannt. Ein
    /// Diff müsste Termine, Titel und Prioritäten vergleichen — mehr Code, mehr
    /// Wege, an denen eine Erinnerung verloren geht.
    @discardableResult
    func apply(_ planned: [NotificationPlanner.PlannedNotification]) async -> ApplyResult {
        center.removeAllPendingNotificationRequests()

        var result = ApplyResult(requested: planned.count)

        for item in planned {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            // Gruppiert die Mitteilungen je Tier — bei zwei Tieren stehen sonst
            // gleich betitelte Erinnerungen unsortiert untereinander.
            content.threadIdentifier = item.petID
            content.categoryIdentifier = item.category.rawValue
            content.userInfo = [
                "petID": item.petID,
                "category": item.category.rawValue,
            ]

            // Kalender-Trigger statt Zeitintervall: ein Intervall verschiebt sich
            // bei einem Zeitzonenwechsel mit, die 9-Uhr-Erinnerung käme dann um
            // 3 Uhr. Bewusst **ohne** `timeZone` in den Components — so gilt die
            // Wanduhr des Geräts, auch nach einem Flug.
            //
            // Und bewusst `Calendar.current` statt `dayMath.calendar`: der
            // Engine-Default für `DayMath` ist UTC. Würde der Service damit
            // gebaut, läge hier eine UTC-Wanduhrzeit, die iOS als Ortszeit
            // liest — jede Erinnerung um den Zonen-Offset verschoben. Die
            // Fenster-Arithmetik darf injizierbar bleiben, die Uhrzeit einer
            // echten Mitteilung nicht.
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: item.fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            // `item.id` als Identifier: gleiche Quelle + gleicher Termin ⇒ gleiche
            // ID, iOS ersetzt den Request dann statt zu duplizieren. Damit ist
            // auch ein Setzen, das sich mit dem Abräumen überlappt, harmlos.
            let request = UNNotificationRequest(
                identifier: item.id,
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
                result.scheduled += 1
            } catch {
                result.failures.append(
                    ScheduleFailure(
                        id: item.id,
                        title: item.title,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        return result
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
        guard settings.notificationsEnabled else {
            // Abgeschaltet heißt: auch das Bestehende muss weg. Sonst feuern
            // gestern geplante Erinnerungen weiter.
            center.removeAllPendingNotificationRequests()
            settings.lastNotificationSyncAt = asOf
            try? context.save()
            return .disabled
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

        let planned = plannedNotifications(context: context, settings: settings, asOf: asOf)
        let result = await apply(planned)
        settings.lastNotificationSyncAt = asOf
        try? context.save()
        return .applied(result)
    }

    /// Der reine Teil von `reschedule`: aus dem Store das ableiten, was die
    /// Engine braucht, und den Plan zurückgeben. Ohne
    /// `UNUserNotificationCenter`, damit das Mapping prüfbar bleibt.
    func plannedNotifications(
        context: ModelContext,
        settings: AppSettings,
        asOf: Date
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

        return NotificationPlanner(dayMath: dayMath).plan(
            dueItems: dueItems,
            doseOccurrences: doseOccurrences,
            criticalDays: criticalDays,
            settings: plannerSettings,
            asOf: asOf
        )
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
