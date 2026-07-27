import Foundation
import Testing

@testable import RudelEngine

/// Wie `NotificationPlanner` mit den Tageshinweisen aus `CriticalDaysAdvisor`
/// umgeht. Eigene Datei, weil hier nicht die Fälligkeitslogik geprüft wird,
/// sondern die Frage, ob ein zeitgebundener Hinweis das Budget übersteht.
@Suite("NotificationPlanner — kritische Tage")
struct NotificationPlannerCriticalDaysTests {

    private let math = DayMath.utc
    private let planner = NotificationPlanner(dayMath: .utc)

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year, month: month, day: day, hour: hour
        ).date!
    }

    /// 08:00 — vor der Standard-Erinnerungszeit 09:00, damit heutige Termine
    /// noch in der Zukunft liegen.
    private var now: Date { at(2026, 7, 26, 8) }

    private var settings: NotificationPlanner.Settings {
        NotificationPlanner.Settings(
            leadDays: [7, 1, 0],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 14
        )
    }

    /// Läufigkeit, die vor `dayInCycleToday - 1` Tagen begann.
    private func heatNotices(
        dayInCycleToday: Int,
        visibleHeatEnd: Date? = nil,
        signals: [PhaseSignals] = []
    ) -> [CriticalDayNotice] {
        let day1 = math.adding(days: -(dayInCycleToday - 1), to: now)
        return CriticalDaysAdvisor(dayMath: .utc).notices(
            day1: day1,
            signals: signals,
            visibleHeatEnd: visibleHeatEnd,
            petName: "Zola",
            sourceID: "period-1",
            from: now,
            through: math.adding(days: settings.horizonDays, to: now)
        )
    }

    private func dueItem(
        _ sourceID: String,
        category: DueItem.Category,
        title: String,
        dueOn: Date,
        petID: String = "pet-1"
    ) -> DueItem {
        let days = math.days(from: now, to: dueOn)
        return DueItem(
            id: "\(sourceID)#\(category.rawValue)",
            sourceID: sourceID,
            petID: petID,
            petName: "Zola",
            category: category,
            title: title,
            dueOn: dueOn,
            daysUntilDue: days,
            urgency: Urgency(daysUntilDue: days)
        )
    }

    // MARK: - Grundverhalten

    @Test("Tageshinweise werden geplant")
    func criticalDaysAreScheduled() {
        let planned = planner.plan(
            dueItems: [],
            doseOccurrences: [:],
            criticalDays: ["pet-1": heatNotices(dayInCycleToday: 10)],
            settings: settings,
            asOf: now
        )

        #expect(!planned.isEmpty)
        #expect(planned.allSatisfy { $0.category == .criticalDays })
        #expect(planned.allSatisfy { $0.petID == "pet-1" })
    }

    @Test("Ohne Hinweise ändert sich nichts am bisherigen Verhalten")
    func emptyCriticalDaysChangeNothing() {
        let wurmkur = dueItem("plan-1", category: .medication, title: "Wurmkur", dueOn: now)

        let withParameter = planner.plan(
            dueItems: [wurmkur],
            doseOccurrences: [:],
            criticalDays: [:],
            settings: settings,
            asOf: now
        )
        // Derselbe Aufruf ohne den neuen Parameter — der Default muss identisch sein,
        // sonst hätte die Erweiterung bestehendes Verhalten verändert.
        let withoutParameter = planner.plan(
            dueItems: [wurmkur],
            doseOccurrences: [:],
            settings: settings,
            asOf: now
        )

        #expect(withParameter == withoutParameter)
    }

    @Test("Die petID kommt aus dem Schlüssel, nicht aus einem DueItem")
    func petIDComesFromTheKey() {
        // Der entscheidende Unterschied zu `doseOccurrences`: dort werden Termine
        // ohne passendes `DueItem` verworfen, weil die petID fehlt. Hier gibt es
        // bewusst kein DueItem — und trotzdem muss geplant werden.
        let planned = planner.plan(
            dueItems: [],
            doseOccurrences: [:],
            criticalDays: ["pet-hegel": heatNotices(dayInCycleToday: 12)],
            settings: settings,
            asOf: now
        )

        #expect(!planned.isEmpty, "Kritische Tage dürfen nicht an einem fehlenden DueItem scheitern")
        #expect(planned.allSatisfy { $0.petID == "pet-hegel" })
    }

    // MARK: - Invarianten

    @Test("Invariante 5: ein kritischer Tag wird von nichts verdrängt")
    func criticalDayIsNeverCrowdedOut() {
        // 20 Dauermedikamente mit je 3 Gaben täglich über 14 Tage = 840 Termine,
        // plus 30 überfällige Behandlungen. Weit über dem Budget von 56.
        var dueItems: [DueItem] = []
        var doses: [String: [Date]] = [:]

        for index in 0..<20 {
            let sourceID = "ongoing-\(index)"
            dueItems.append(
                dueItem(sourceID, category: .dose, title: "Medikament \(index)", dueOn: now)
            )
            var dates: [Date] = []
            for dayOffset in 0..<14 {
                let day = math.adding(days: dayOffset, to: now)
                for hour in [9, 14, 20] {
                    dates.append(
                        math.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
                    )
                }
            }
            doses[sourceID] = dates
        }
        for index in 0..<30 {
            dueItems.append(
                dueItem(
                    "overdue-\(index)",
                    category: .medication,
                    title: "Behandlung \(index)",
                    dueOn: math.adding(days: -index - 1, to: now)
                )
            )
        }

        let notices = heatNotices(dayInCycleToday: 10)
        let criticalToday = notices.first { $0.risk == .critical }

        let planned = planner.plan(
            dueItems: dueItems,
            doseOccurrences: doses,
            criticalDays: ["pet-1": notices],
            settings: settings,
            asOf: now
        )

        #expect(planned.count <= NotificationPlanner.budget)
        let criticalID = try? #require(criticalToday?.id)
        #expect(
            planned.contains { $0.id == criticalID },
            """
            Der kritische Tag ist unter dem Andrang verschwunden. Eine verpasste \
            Gabe kann man nachholen, eine ungewollte Deckung nicht.
            """
        )
    }

    @Test("Kritische Tage stehen über überfälligen Fälligkeiten")
    func criticalOutranksOverdue() {
        let overdue = dueItem(
            "plan-1",
            category: .medication,
            title: "Wurmkur",
            dueOn: math.adding(days: -90, to: now)
        )
        let notices = heatNotices(dayInCycleToday: 10)

        let planned = planner.plan(
            dueItems: [overdue],
            doseOccurrences: [:],
            criticalDays: ["pet-1": notices],
            settings: settings,
            asOf: now
        )

        let critical = planned.filter { $0.category == .criticalDays && $0.title.contains("kritische") }
        let medication = planned.filter { $0.category == .medication }

        let highestCritical = critical.map(\.priority).max() ?? 0
        let highestMedication = medication.map(\.priority).max() ?? 0
        #expect(highestCritical > highestMedication)
    }

    @Test("Die niedrigere Stufe rangiert unter überfälligen Fälligkeiten")
    func heatWatchRanksBelowOverdue() {
        // Tag 3: Läufigkeit läuft, Deckung noch nicht zu erwarten. Das darf keine
        // überfällige Behandlung verdrängen.
        let overdue = dueItem(
            "plan-1",
            category: .medication,
            title: "Wurmkur",
            dueOn: math.adding(days: -90, to: now)
        )
        let notices = heatNotices(dayInCycleToday: 3)
        let planned = planner.plan(
            dueItems: [overdue],
            doseOccurrences: [:],
            criticalDays: ["pet-1": notices],
            settings: settings,
            asOf: now
        )

        // Nach Stufe filtern, nicht nach Kategorie: im 14-Tage-Fenster ab Tag 3
        // liegen auch schon die kritischen Tage ab Tag 9, und die rangieren
        // absichtlich oben.
        let elevatedIDs = Set(notices.filter { $0.risk == .elevated }.map(\.id))
        let elevated = planned.filter { elevatedIDs.contains($0.id) }
        let medication = planned.filter { $0.category == .medication }

        #expect(!elevated.isEmpty)
        #expect(!medication.isEmpty)
        #expect((elevated.map(\.priority).max() ?? 0) < (medication.map(\.priority).max() ?? 0))
    }

    @Test("Kein Termin liegt in der Vergangenheit")
    func noPastFireDates() {
        let planned = planner.plan(
            dueItems: [],
            doseOccurrences: [:],
            criticalDays: ["pet-1": heatNotices(dayInCycleToday: 10)],
            settings: settings,
            asOf: now
        )

        #expect(planned.allSatisfy { $0.fireDate >= now })
    }

    @Test("Kein Termin liegt jenseits des Fensters")
    func noFireDatesBeyondHorizon() {
        let planned = planner.plan(
            dueItems: [],
            doseOccurrences: [:],
            criticalDays: ["pet-1": heatNotices(dayInCycleToday: 10)],
            settings: settings,
            asOf: now
        )

        #expect(
            planned.allSatisfy { math.days(from: now, to: $0.fireDate) <= settings.horizonDays }
        )
    }

    @Test("IDs bleiben eindeutig, auch neben Fälligkeiten und Gaben")
    func identifiersStayUnique() {
        let planned = planner.plan(
            dueItems: [
                dueItem("plan-1", category: .medication, title: "Wurmkur", dueOn: now),
                dueItem("plan-2", category: .dose, title: "Levetiracetam", dueOn: now),
            ],
            doseOccurrences: [
                "plan-2": [math.calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now]
            ],
            criticalDays: ["pet-1": heatNotices(dayInCycleToday: 10)],
            settings: settings,
            asOf: now
        )

        let ids = planned.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Ein Hinweis für heute, dessen Uhrzeit vorbei ist, wird verworfen")
    func todaysPassedSlotIsDropped() {
        // 20:00, die Erinnerungszeit 09:00 ist längst durch. Der heutige Hinweis
        // darf nicht sofort feuern — das Dashboard zeigt den Zustand ohnehin.
        let evening = at(2026, 7, 26, 20)
        let day1 = math.adding(days: -9, to: evening)
        let notices = CriticalDaysAdvisor(dayMath: .utc).notices(
            day1: day1,
            signals: [],
            visibleHeatEnd: nil,
            petName: "Zola",
            sourceID: "period-1",
            from: evening,
            through: math.adding(days: 14, to: evening)
        )

        let planned = planner.plan(
            dueItems: [],
            doseOccurrences: [:],
            criticalDays: ["pet-1": notices],
            settings: settings,
            asOf: evening
        )

        #expect(planned.allSatisfy { $0.fireDate >= evening })
        #expect(
            !planned.contains { math.isSameDay($0.fireDate, evening) },
            "Der heutige Slot war vorbei und darf nicht nachgeholt werden"
        )
    }

    @Test("Titel und Text kommen unverändert aus dem Advisor")
    func textsArePassedThroughUnchanged() {
        let notices = heatNotices(dayInCycleToday: 10)
        let planned = planner.plan(
            dueItems: [],
            doseOccurrences: [:],
            criticalDays: ["pet-1": notices],
            settings: settings,
            asOf: now
        )

        for entry in planned {
            let source = notices.first { $0.id == entry.id }
            #expect(source != nil)
            #expect(entry.title == source?.title)
            #expect(entry.body == source?.body)
        }
    }
}
