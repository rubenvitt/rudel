import Foundation
import Testing

@testable import RudelEngine

// MARK: - Fixtures
//
// Alle Daten aus festen Komponenten in UTC. Kein `Date()` — sonst hängt das
// Ergebnis vom Tag ab, an dem der Test läuft.

private let math = DayMath.utc

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year, month: month, day: day, hour: hour, minute: minute
    ).date!
}

/// „Jetzt" für die meisten Tests: Sonntag, 26.07.2026, 08:00 UTC — also **vor**
/// der Standard-Erinnerungszeit 09:00, damit heutige Termine noch in der Zukunft
/// liegen.
private let now = at(2026, 7, 26, 8)

private func item(
    _ sourceID: String,
    category: DueItem.Category,
    title: String,
    dueOn: Date,
    detail: String? = nil,
    petName: String = "Zola",
    petID: String = "pet-1",
    urgency: Urgency? = nil,
    isForecast: Bool = false,
    asOf: Date = now
) -> DueItem {
    let days = math.days(from: asOf, to: dueOn)
    return DueItem(
        id: "\(sourceID)#\(category.rawValue)",
        sourceID: sourceID,
        petID: petID,
        petName: petName,
        category: category,
        title: title,
        detail: detail,
        dueOn: dueOn,
        daysUntilDue: days,
        urgency: urgency ?? Urgency(daysUntilDue: days),
        isForecast: isForecast,
        // Ein laufender Schutz: Fälligkeit und Schutzende fallen zusammen.
        protectionEndsOn: category == .protectionExpiry ? dueOn : nil
    )
}

private let standardSettings = NotificationPlanner.Settings(
    leadDays: [7, 1, 0],
    reminderTime: TimeOfDay(hour: 9),
    horizonDays: 14
)

private extension Array where Element == NotificationPlanner.PlannedNotification {
    /// Die geplanten Erinnerungen einer Quelle — `PlannedNotification` trägt die
    /// `sourceID` nur in der ID.
    func forSource(_ sourceID: String) -> [NotificationPlanner.PlannedNotification] {
        filter { $0.id.contains(".\(sourceID).") }
    }
}

@Suite("NotificationPlanner")
struct NotificationPlannerTests {

    private let planner = NotificationPlanner(dayMath: .utc)

    // MARK: - Vorwarnzeiten

    @Test("Jede Vorwarnzeit erzeugt eine Erinnerung zur Erinnerungszeit")
    func leadDaysProduceOneReminderEach() {
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 8, 5))

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.map(\.fireDate) == [
            at(2026, 7, 29, 9),  // 7 Tage vorher
            at(2026, 8, 4, 9),   // 1 Tag vorher
            at(2026, 8, 5, 9),   // am Fälligkeitstag
        ])
        #expect(plan.allSatisfy { $0.title == "Zola — Wurmkur fällig" })
        #expect(plan[0].body == "Wurmkur ist in 7 Tagen fällig (05.08.2026).")
        #expect(plan[1].body == "Wurmkur ist morgen fällig (05.08.2026).")
        #expect(plan[2].body == "Wurmkur ist heute fällig.")
    }

    @Test("Vorwarn-Termine in der Vergangenheit fallen weg")
    func leadDaysInThePastAreDropped() throws {
        // Fällig in 3 Tagen: die 7-Tage-Vorwarnung lag vor vier Tagen.
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 7, 29))

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.map(\.fireDate) == [at(2026, 7, 28, 9), at(2026, 7, 29, 9)])
    }

    @Test("Termine jenseits des Fensters werden nicht geplant")
    func candidatesBeyondHorizonAreDropped() {
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 8, 20))

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.isEmpty)
    }

    @Test("Negative Vorwarnzeit erinnert nach der Fälligkeit")
    func negativeLeadDaysRemindAfterDueDate() throws {
        let settings = NotificationPlanner.Settings(
            leadDays: [-2],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 14
        )
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 7, 26))

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: settings,
            asOf: now
        )

        let only = try #require(plan.first)
        #expect(plan.count == 1)
        #expect(only.fireDate == at(2026, 7, 28, 9))
    }

    @Test("Ohne Vorwarnzeiten bleibt ein künftiges Item stumm")
    func emptyLeadDaysPlansNothingForFutureItems() {
        let settings = NotificationPlanner.Settings(leadDays: [], horizonDays: 14)
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 8, 5))

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: settings,
            asOf: now
        )

        #expect(plan.isEmpty)
    }

    // MARK: - Überfällig

    @Test("Überfälliges Item: genau eine Erinnerung zum nächsten Zeitpunkt heute")
    func overdueItemGetsOneReminderToday() throws {
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur",
                            dueOn: at(2026, 7, 20), detail: "Milbemax")

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: now
        )

        let only = try #require(plan.first)
        #expect(plan.count == 1)
        #expect(only.fireDate == at(2026, 7, 26, 9))
        #expect(only.title == "Zola — Wurmkur fällig")
        #expect(only.body == "Wurmkur war am 20.07.2026 fällig — seit 6 Tagen überfällig — Milbemax.")
    }

    @Test("Ist die Erinnerungszeit vorbei, kommt die Erinnerung morgen — nicht rückwirkend")
    func overdueItemAfterReminderTimeFiresTomorrow() throws {
        let afterReminderTime = at(2026, 7, 26, 10)
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur",
                            dueOn: at(2026, 7, 25), asOf: afterReminderTime)

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: afterReminderTime
        )

        let only = try #require(plan.first)
        #expect(plan.count == 1)
        #expect(only.fireDate == at(2026, 7, 27, 9))
        // Relativ zum Termin der Erinnerung, nicht zum Planungslauf.
        #expect(only.body == "Wurmkur war am 25.07.2026 fällig — seit 2 Tagen überfällig.")
    }

    @Test("Heute fällig mit verstrichener Erinnerungszeit rutscht auf morgen")
    func dueTodayAfterReminderTimeFallsBackToNextSlot() throws {
        let afternoon = at(2026, 7, 26, 14)
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur",
                            dueOn: at(2026, 7, 26), asOf: afternoon)
        #expect(dewormer.urgency == .dueToday)

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: afternoon
        )

        let only = try #require(plan.first)
        #expect(plan.count == 1)
        #expect(only.fireDate == at(2026, 7, 27, 9))
    }

    @Test("Ohne Vorwarnzeiten bekommt ein überfälliges Item trotzdem eine Erinnerung")
    func emptyLeadDaysStillRemindsForOverdueItems() throws {
        let settings = NotificationPlanner.Settings(leadDays: [], horizonDays: 14)
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 7, 1))

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: settings,
            asOf: now
        )

        let only = try #require(plan.first)
        #expect(plan.count == 1)
        #expect(only.fireDate == at(2026, 7, 26, 9))
    }

    // MARK: - Einzelgaben

    @Test("Dosis-Termine tragen ihre eigene Uhrzeit, nicht die Erinnerungszeit")
    func doseOccurrencesKeepTheirOwnTimeOfDay() {
        let dose = item("ongoing-1", category: .dose, title: "Metacam",
                        dueOn: at(2026, 7, 26, 8), detail: "1/2 Tablette")

        let plan = planner.plan(
            dueItems: [dose],
            doseOccurrences: ["ongoing-1": [
                at(2026, 7, 26, 8),
                at(2026, 7, 26, 20),
                at(2026, 7, 27, 8),
            ]],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.map(\.fireDate) == [
            at(2026, 7, 26, 8),
            at(2026, 7, 26, 20),
            at(2026, 7, 27, 8),
        ])
        #expect(plan.allSatisfy { $0.title == "Zola — Metacam geben" })
        #expect(plan[0].body == "Metacam: Gabe um 08:00 — 1/2 Tablette.")
        #expect(plan[1].body == "Metacam: Gabe um 20:00 — 1/2 Tablette.")
        // Das `.dose`-Item und der gleiche Termin aus `doseOccurrences` sind
        // dieselbe Erinnerung — eine ID, ein Request.
        #expect(plan.count == 3)
    }

    @Test("Verstrichene Dosis-Termine werden nicht nachgeholt")
    func pastDoseOccurrencesAreDropped() {
        let noon = at(2026, 7, 26, 12)
        let dose = item("ongoing-1", category: .dose, title: "Metacam",
                        dueOn: at(2026, 7, 26, 8), asOf: noon)

        let plan = planner.plan(
            dueItems: [dose],
            doseOccurrences: ["ongoing-1": [at(2026, 7, 26, 8), at(2026, 7, 26, 20)]],
            settings: standardSettings,
            asOf: noon
        )

        #expect(plan.map(\.fireDate) == [at(2026, 7, 26, 20)])
    }

    @Test("Dosis-Termine jenseits des Fensters werden nicht geplant")
    func doseOccurrencesBeyondHorizonAreDropped() {
        let settings = NotificationPlanner.Settings(
            leadDays: [0],
            reminderTime: TimeOfDay(hour: 9),
            horizonDays: 2
        )
        let dose = item("ongoing-1", category: .dose, title: "Metacam", dueOn: at(2026, 7, 26, 20))

        let plan = planner.plan(
            dueItems: [dose],
            doseOccurrences: ["ongoing-1": [
                at(2026, 7, 26, 20),
                at(2026, 7, 28, 20),
                at(2026, 7, 30, 20),
            ]],
            settings: settings,
            asOf: now
        )

        #expect(plan.map(\.fireDate) == [at(2026, 7, 26, 20), at(2026, 7, 28, 20)])
    }

    @Test("Ein Fenster von 0 Tagen wird auf 1 geklemmt")
    func horizonIsClampedToAtLeastOneDay() {
        let settings = NotificationPlanner.Settings(leadDays: [0], horizonDays: 0)
        #expect(settings.horizonDays == 1)

        let dose = item("ongoing-1", category: .dose, title: "Metacam", dueOn: at(2026, 7, 27, 8))

        let plan = planner.plan(
            dueItems: [dose],
            doseOccurrences: ["ongoing-1": [at(2026, 7, 27, 8), at(2026, 7, 28, 8)]],
            settings: settings,
            asOf: now
        )

        #expect(plan.map(\.fireDate) == [at(2026, 7, 27, 8)])
    }

    @Test("Dosis-Termine ohne zugehöriges DueItem werden übersprungen")
    func doseOccurrencesWithoutMetadataAreSkipped() {
        // `doseOccurrences` ist nur nach `sourceID` geschlüsselt: ohne DueItem
        // gibt es weder Tiernamen noch `petID`, die Erinnerung wäre nicht
        // zuordenbar.
        let plan = planner.plan(
            dueItems: [],
            doseOccurrences: ["unbekannt": [at(2026, 7, 27, 8)]],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.isEmpty)
    }

    @Test("Dosis-Termine erben Tiername und Bezeichnung aus einem Fälligkeits-Item")
    func doseOccurrencesInheritMetadataFromAnyItemOfTheSameSource() throws {
        let ongoing = item("ongoing-1", category: .medication, title: "Metacam",
                           dueOn: at(2026, 8, 5), petName: "Hegel", petID: "pet-2")

        let plan = planner.plan(
            dueItems: [ongoing],
            doseOccurrences: ["ongoing-1": [at(2026, 7, 27, 8)]],
            settings: standardSettings,
            asOf: now
        )

        let dose = try #require(plan.first { $0.category == .dose })
        #expect(dose.title == "Hegel — Metacam geben")
        #expect(dose.petID == "pet-2")
    }

    // MARK: - Weitere Kategorien

    @Test("Ablaufender Schutz wird als Ablauf formuliert")
    func protectionExpiryUsesItsOwnWording() throws {
        let settings = NotificationPlanner.Settings(leadDays: [7], horizonDays: 14)
        let protection = item("tick-1", category: .protectionExpiry, title: "Zeckenschutz",
                              dueOn: at(2026, 8, 2))

        let plan = planner.plan(
            dueItems: [protection],
            doseOccurrences: [:],
            settings: settings,
            asOf: now
        )

        let only = try #require(plan.first)
        #expect(plan.count == 1)
        #expect(only.fireDate == at(2026, 7, 26, 9))
        #expect(only.title == "Zola — Zeckenschutz läuft ab")
        #expect(only.body == "Zeckenschutz: der Schutz läuft in 7 Tagen ab (02.08.2026).")
    }

    @Test("Zyklus-Prognose aus dem Studienintervall wird als Prognose getextet")
    func cycleForecastFromStudyIntervalIsPlanned() throws {
        // Letzter Tag 1 so gelegt, dass das Populationsintervall in fünf Tagen
        // landet — mit dem Studienwert gerechnet, nicht mit einer Faustregel.
        let lastDay1 = math.adding(days: -205, to: now)
        let expected = math.adding(days: StudyConstants.day1ToDay1IntervalDays, to: lastDay1)
        #expect(expected == at(2026, 7, 31))

        let forecast = item("cycle-1", category: .cycleForecast, title: "Läufigkeit",
                            dueOn: expected, detail: "Band 28.07.–03.08.", isForecast: true)

        let plan = planner.plan(
            dueItems: [forecast],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.map(\.fireDate) == [at(2026, 7, 30, 9), at(2026, 7, 31, 9)])
        #expect(plan.allSatisfy { $0.title == "Zola — Läufigkeit erwartet" })
        #expect(plan[1].body == "Läufigkeit: erwartet ab 31.07.2026 (heute)."
            + " Prognose, keine Gewissheit — bitte auf erste Anzeichen achten — Band 28.07.–03.08.")
    }

    @Test("Ein Titel, der das Verb schon trägt, wird nicht verdoppelt")
    func titleVerbIsNotDuplicated() throws {
        let forecast = item("cycle-1", category: .cycleForecast, title: "Läufigkeit erwartet",
                            dueOn: at(2026, 7, 31), isForecast: true)
        let settings = NotificationPlanner.Settings(leadDays: [0], horizonDays: 14)

        let plan = planner.plan(
            dueItems: [forecast],
            doseOccurrences: [:],
            settings: settings,
            asOf: now
        )

        let only = try #require(plan.first)
        #expect(only.title == "Zola — Läufigkeit erwartet")
    }

    @Test("Ohne Tiernamen bleibt der Vorgang allein im Titel")
    func missingPetNameLeavesTheSubjectAlone() throws {
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur",
                            dueOn: at(2026, 7, 26), detail: nil, petName: "  ")
        let settings = NotificationPlanner.Settings(leadDays: [0], horizonDays: 14)

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: settings,
            asOf: now
        )

        let only = try #require(plan.first)
        #expect(only.title == "Wurmkur fällig")
        #expect(only.body == "Wurmkur ist heute fällig.")
    }

    // MARK: - Randfälle

    @Test("Leere Eingabe ergibt leeres Ergebnis")
    func emptyInputProducesEmptyPlan() {
        let plan = planner.plan(
            dueItems: [],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.isEmpty)
    }

    @Test("Leere Terminliste einer Quelle erzeugt keine zusätzliche Erinnerung")
    func emptyOccurrenceListAddsNothing() {
        let dose = item("ongoing-1", category: .dose, title: "Metacam", dueOn: at(2026, 7, 27, 8))

        let plan = planner.plan(
            dueItems: [dose],
            doseOccurrences: ["ongoing-1": []],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.map(\.fireDate) == [at(2026, 7, 27, 8)])
    }

    @Test("Doppelte Vorwarnzeiten erzeugen keine doppelte Erinnerung")
    func duplicateLeadDaysAreCollapsed() {
        let settings = NotificationPlanner.Settings(leadDays: [7, 7, 0], horizonDays: 14)
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 8, 5))

        let plan = planner.plan(
            dueItems: [dewormer],
            doseOccurrences: [:],
            settings: settings,
            asOf: now
        )

        #expect(plan.map(\.fireDate) == [at(2026, 7, 29, 9), at(2026, 8, 5, 9)])
    }

    @Test("Doppelt geliefertes DueItem erzeugt keine doppelten Erinnerungen")
    func duplicateDueItemsAreCollapsed() {
        let dewormer = item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 8, 5))

        let plan = planner.plan(
            dueItems: [dewormer, dewormer],
            doseOccurrences: [:],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.count == 3)
        #expect(Set(plan.map(\.id)).count == 3)
    }

    @Test("Gleiche Eingabe, gleiches Ergebnis — inklusive IDs")
    func planningIsDeterministic() {
        let items = [
            item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 7, 20)),
            item("tick-1", category: .protectionExpiry, title: "Zeckenschutz", dueOn: at(2026, 8, 2)),
            item("ongoing-1", category: .dose, title: "Metacam", dueOn: at(2026, 7, 26, 20)),
        ]
        let occurrences = [
            "ongoing-1": [at(2026, 7, 26, 20), at(2026, 7, 27, 8), at(2026, 7, 27, 20)],
        ]

        let first = planner.plan(dueItems: items, doseOccurrences: occurrences,
                                 settings: standardSettings, asOf: now)
        let second = planner.plan(dueItems: items, doseOccurrences: occurrences,
                                  settings: standardSettings, asOf: now)

        #expect(first == second)
        #expect(!first.isEmpty)
        #expect(first.allSatisfy { !$0.id.isEmpty })
    }

    @Test("Das Ergebnis ist chronologisch sortiert")
    func resultIsSortedChronologically() {
        let plan = planner.plan(
            dueItems: [
                item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 8, 5)),
                item("tick-1", category: .protectionExpiry, title: "Zeckenschutz", dueOn: at(2026, 8, 2)),
                item("ongoing-1", category: .dose, title: "Metacam", dueOn: at(2026, 7, 26, 20)),
            ],
            doseOccurrences: ["ongoing-1": [at(2026, 7, 30, 8), at(2026, 7, 27, 8)]],
            settings: standardSettings,
            asOf: now
        )

        #expect(plan.count > 3)
        #expect(zip(plan, plan.dropFirst()).allSatisfy { $0.fireDate <= $1.fireDate })
    }

    // MARK: - Priorisierung

    @Test("Die Prioritäten folgen der Liste aus dem Doc-Kommentar")
    func prioritiesFollowTheDocumentedOrder() throws {
        let plan = planner.plan(
            dueItems: [
                item("worm-1", category: .medication, title: "Wurmkur", dueOn: at(2026, 7, 20)),
                item("tick-1", category: .medication, title: "Zeckenschutz", dueOn: at(2026, 7, 31)),
                item("ongoing-1", category: .dose, title: "Metacam", dueOn: at(2026, 7, 26, 20)),
                item("cycle-1", category: .cycleForecast, title: "Läufigkeit",
                     dueOn: at(2026, 7, 31), isForecast: true),
            ],
            doseOccurrences: ["ongoing-1": [at(2026, 7, 26, 20), at(2026, 7, 28, 8)]],
            settings: standardSettings,
            asOf: now
        )

        let overdue = try #require(plan.forSource("worm-1").first)
        let doseToday = try #require(plan.forSource("ongoing-1").first { math.isSameDay($0.fireDate, now) })
        let upcoming = try #require(plan.forSource("tick-1").first)
        let doseFuture = try #require(plan.forSource("ongoing-1").first { !math.isSameDay($0.fireDate, now) })
        let forecast = try #require(plan.forSource("cycle-1").first)

        #expect(overdue.priority > doseToday.priority)
        #expect(doseToday.priority > upcoming.priority)
        #expect(upcoming.priority > doseFuture.priority)
        #expect(doseFuture.priority > forecast.priority)
    }

    // MARK: - Invarianten

    /// 20 Dauermedikamente mit je drei Gaben täglich plus eine überfällige
    /// Wurmkur. Die Erinnerungszeit liegt bewusst auf 22:00 und `asOf` auf 23:00:
    /// damit fällt die Wurmkur-Erinnerung auf morgen 22:00 und **60 Dosis-Termine
    /// liegen chronologisch davor**. Ein Planer, der nur nach Datum kürzt, würde
    /// die Wurmkur verlieren.
    private func saturatedFixture() -> (
        items: [DueItem],
        occurrences: [String: [Date]],
        settings: NotificationPlanner.Settings,
        asOf: Date
    ) {
        let asOf = at(2026, 7, 26, 23)
        let settings = NotificationPlanner.Settings(
            leadDays: [7, 1, 0],
            reminderTime: TimeOfDay(hour: 22),
            horizonDays: 14
        )

        var items: [DueItem] = []
        var occurrences: [String: [Date]] = [:]

        for index in 1...20 {
            let sourceID = "ongoing-\(index)"
            // Das offene `.dose`-Item des heutigen Tages liefert die Metadaten.
            items.append(item(sourceID, category: .dose, title: "Medikament \(index)",
                              dueOn: at(2026, 7, 26, 18), asOf: asOf))
            occurrences[sourceID] = (0..<14).flatMap { offset -> [Date] in
                let day = math.adding(days: offset, to: at(2026, 7, 27))
                return [6, 12, 18].map { hour in
                    math.calendar.date(byAdding: .hour, value: hour, to: day)!
                }
            }
        }

        items.append(item("worm-1", category: .medication, title: "Wurmkur",
                          dueOn: at(2026, 7, 20), detail: "Milbemax", asOf: asOf))

        return (items, occurrences, settings, asOf)
    }

    @Test("Invariante 1: höchstens `budget` Erinnerungen")
    func invariantOneRespectsBudget() {
        let fixture = saturatedFixture()

        let plan = planner.plan(
            dueItems: fixture.items,
            doseOccurrences: fixture.occurrences,
            settings: fixture.settings,
            asOf: fixture.asOf
        )

        // Die Invariante ist die Obergrenze; das Fixture sättigt sie bewusst
        // (841 Kandidaten), deshalb steht hier zusätzlich die Gleichheit.
        #expect(plan.count <= NotificationPlanner.budget)
        #expect(plan.count == NotificationPlanner.budget)
        #expect(NotificationPlanner.budget == 56)
    }

    @Test("Invariante 2: kein Termin liegt in der Vergangenheit")
    func invariantTwoNeverFiresInThePast() {
        let fixture = saturatedFixture()

        let plan = planner.plan(
            dueItems: fixture.items,
            doseOccurrences: fixture.occurrences,
            settings: fixture.settings,
            asOf: fixture.asOf
        )

        #expect(!plan.isEmpty)
        #expect(plan.allSatisfy { $0.fireDate >= fixture.asOf })

        // Zusätzlich der Fall, in dem *alle* Kandidaten in der Vergangenheit
        // liegen: nachmittags geplant, Erinnerungszeit morgens.
        let afternoon = at(2026, 7, 26, 14)
        let pastOnly = planner.plan(
            dueItems: [
                item("ongoing-1", category: .dose, title: "Metacam",
                     dueOn: at(2026, 7, 26, 8), asOf: afternoon),
            ],
            doseOccurrences: ["ongoing-1": [at(2026, 7, 26, 8), at(2026, 7, 25, 8)]],
            settings: standardSettings,
            asOf: afternoon
        )
        #expect(pastOnly.isEmpty)
    }

    @Test("Invariante 3: IDs sind eindeutig")
    func invariantThreeHasUniqueIDs() {
        let fixture = saturatedFixture()

        let plan = planner.plan(
            dueItems: fixture.items,
            doseOccurrences: fixture.occurrences,
            settings: fixture.settings,
            asOf: fixture.asOf
        )

        #expect(Set(plan.map(\.id)).count == plan.count)
        // Im gesättigten Fixture ist jedes Paar (Quelle, Termin) verschieden,
        // Eindeutigkeit also geschenkt. Das Entdoppeln selbst prüfen
        // `duplicateLeadDaysAreCollapsed`, `duplicateDueItemsAreCollapsed` und
        // `doseOccurrencesKeepTheirOwnTimeOfDay`.
    }

    @Test("Invariante 4: die überfällige Wurmkur überlebt 20 Dauermedikamente")
    func invariantFourOverdueItemSurvivesDoseFlood() throws {
        let fixture = saturatedFixture()

        let plan = planner.plan(
            dueItems: fixture.items,
            doseOccurrences: fixture.occurrences,
            settings: fixture.settings,
            asOf: fixture.asOf
        )

        let dewormer = try #require(plan.forSource("worm-1").first)
        #expect(plan.forSource("worm-1").count == 1)
        #expect(dewormer.fireDate == at(2026, 7, 27, 22))
        #expect(dewormer.title == "Zola — Wurmkur fällig")

        // Der Beweis, dass hier tatsächlich priorisiert und nicht nur nach Datum
        // gekürzt wurde: chronologisch stehen mehr als `budget` Dosis-Termine vor
        // der Wurmkur-Erinnerung.
        let dosesBefore = fixture.occurrences.values.flatMap { $0 }
            .filter { $0 >= fixture.asOf && $0 < dewormer.fireDate }
        #expect(dosesBefore.count > NotificationPlanner.budget)
        #expect(dewormer.priority == plan.map(\.priority).max())
    }

    @Test("Zyklus-Prognosen fliegen vor Fälligkeiten aus dem Budget")
    func forecastsAreDroppedBeforeDueItems() {
        var fixture = saturatedFixture()
        fixture.items.append(
            item("cycle-1", category: .cycleForecast, title: "Läufigkeit",
                 dueOn: at(2026, 7, 31), isForecast: true, asOf: fixture.asOf)
        )

        let plan = planner.plan(
            dueItems: fixture.items,
            doseOccurrences: fixture.occurrences,
            settings: fixture.settings,
            asOf: fixture.asOf
        )

        #expect(plan.forSource("cycle-1").isEmpty)
        #expect(plan.forSource("worm-1").count == 1)
    }
}
