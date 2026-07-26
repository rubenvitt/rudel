import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Die Kette Store → Engine-Inputs → `DueItemBuilder` → `NotificationPlanner`.
///
/// Jedes Glied ist für sich getestet, aber genau dazwischen liegt der einzige
/// Weg, auf dem Erfolgskriterium PRD §10.1 („keine verpasste Gabe") kippen kann,
/// ohne dass ein Test rot wird: `NotificationPlanner` wurde mit einem von Hand
/// gebauten `doseOccurrences`-Wörterbuch geprüft, `DueItemBuilder` mit von Hand
/// gebauten Inputs. Stimmen die Schlüssel der beiden in der echten Verdrahtung
/// nicht überein, fällt jede Dosis-Erinnerung lautlos weg — und beide
/// Test-Suites bleiben grün.
@MainActor
@Suite("Benachrichtigungs-Kette (PRD §10.1)")
struct NotificationChainTests {

    private let asOf = Fixture.day(2026, 7, 26)
    private let service = NotificationService(dayMath: .utc)

    /// Tier mit drei Plänen: ein überfälliges Intervall, ein laufender Schutz,
    /// ein Dauermedikament mit zwei Gaben täglich.
    private func makeStore() throws -> (ModelContext, AppSettings) {
        let context = try makeContext()

        let pet = Pet(
            name: "Zola",
            species: .dog,
            breed: "Rhodesian Ridgeback",
            isFemale: true,
            isNeutered: false,
            createdAt: Fixture.logged
        )
        context.insert(pet)

        // Überfällig: letzte Gabe 01.01., Intervall 90 Tage ⇒ fällig 01.04.
        let dewormer = MedicationPlan(
            kind: .dewormer,
            productName: "Milbemax",
            intervalDays: 90,
            createdAt: Fixture.logged
        )
        dewormer.pet = pet
        context.insert(dewormer)
        let lastDose = MedicationEvent(givenOn: Fixture.day(2026, 1, 1), loggedAt: Fixture.logged)
        lastDose.plan = dewormer
        context.insert(lastDose)

        // Läuft noch: 30 Tage Wirkdauer ab 20.07.
        let tick = MedicationPlan(
            kind: .tickProtection,
            productName: "Bravecto",
            effectiveDays: 30,
            createdAt: Fixture.logged
        )
        tick.pet = pet
        context.insert(tick)
        let tickDose = MedicationEvent(givenOn: Fixture.day(2026, 7, 20), loggedAt: Fixture.logged)
        tickDose.plan = tick
        context.insert(tickDose)

        // Dauermedikament, zwei Gaben täglich ab 20.07., unbefristet.
        let ongoing = MedicationPlan(
            kind: .ongoing,
            productName: "Levetiracetam",
            doseTimesMinutes: [8 * 60, 20 * 60],
            doseEveryNDays: 1,
            doseStartDate: Fixture.day(2026, 7, 20),
            doseLabel: "1 Tablette",
            createdAt: Fixture.logged
        )
        ongoing.pet = pet
        context.insert(ongoing)

        try context.save()
        return (context, AppSettings.loadOrCreate(in: context))
    }

    // MARK: - Die Verdrahtung selbst

    @Test("Die Kette liefert überhaupt Erinnerungen")
    func chainProducesNotifications() throws {
        let (context, settings) = try makeStore()
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)

        #expect(!planned.isEmpty, "Die komplette Kette hat nichts geplant")
    }

    @Test("Die überfällige Wurmkur wird erinnert")
    func overdueDewormerIsScheduled() throws {
        let (context, settings) = try makeStore()
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)

        #expect(
            planned.contains { $0.title.contains("Wurmkur") || $0.body.contains("Wurmkur") },
            "Keine Erinnerung für die seit Monaten überfällige Wurmkur"
        )
    }

    /// Das eigentliche Risiko dieser Naht: `doseOccurrences` ist nach der opaken
    /// `sourceID` geschlüsselt, und die kommt aus `MedicationPlan.engineID`.
    /// Weicht dieser Schlüssel von dem ab, den `engineInput()` als `sourceID`
    /// setzt, findet der Planner zu keinem Termin ein passendes `DueItem` und
    /// verwirft alle Dosis-Erinnerungen — lautlos.
    @Test("Dosis-Erinnerungen überleben die Schlüssel-Naht zwischen Builder und Planner")
    func doseNotificationsSurviveTheKeySeam() throws {
        let (context, settings) = try makeStore()
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)

        let doses = planned.filter { $0.category == .dose }
        #expect(
            !doses.isEmpty,
            "Kein einziger Dosis-Termin geplant — Schlüssel zwischen doseOccurrences und DueItem passen nicht zusammen"
        )
    }

    /// Ein Dauermedikament muss über das ganze Fenster erinnern, nicht nur heute.
    ///
    /// Sonst hängt jede Erinnerung daran, dass die App an dem Tag geöffnet wurde
    /// — wer sie drei Tage nicht anfasst, bekommt drei Tage lang nichts. Das ist
    /// genau der Ausfall, den §10.1 ausschließt.
    @Test("Dosis-Erinnerungen decken das Fenster ab, nicht nur den heutigen Tag")
    func doseNotificationsCoverTheWholeWindow() throws {
        let (context, settings) = try makeStore()
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)

        let doseDays = Set(
            planned
                .filter { $0.category == .dose }
                .map { DayMath.utc.startOfDay($0.fireDate) }
        )

        #expect(
            doseDays.count > 1,
            """
            Dosis-Erinnerungen nur für \(doseDays.count) Tag(e). Bei zwei Gaben \
            täglich und einem Fenster von \(settings.notificationHorizonDays) Tagen \
            müssen es mehrere sein — sonst erinnert die App nur an Tagen, an denen \
            sie ohnehin geöffnet wurde.
            """
        )
    }

    // MARK: - Invarianten über die echte Kette

    @Test("IDs sind auch über die echte Verdrahtung eindeutig")
    func identifiersAreUniqueAcrossTheRealChain() throws {
        let (context, settings) = try makeStore()
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)

        let identifiers = planned.map(\.id)
        #expect(
            Set(identifiers).count == identifiers.count,
            "Doppelte Identifier — iOS ersetzt dann Requests, statt sie zu setzen"
        )
    }

    @Test("Doppelte Gabezeiten erzeugen keine kollidierenden Identifier")
    func duplicateDoseTimesDoNotCollide() throws {
        let context = try makeContext()
        let pet = Pet(name: "Zola", species: .dog, createdAt: Fixture.logged)
        context.insert(pet)

        // Ein kaputter Persistenz-Stand mit doppelter Uhrzeit. `doseOccurrences`
        // liefert dafür zwei identische Zeitstempel; würde der Planner seine IDs
        // ungefiltert aus (sourceID, fireDate) bilden, kollidierten sie.
        let plan = MedicationPlan(
            kind: .ongoing,
            productName: "Levetiracetam",
            doseTimesMinutes: [8 * 60, 8 * 60],
            doseStartDate: Fixture.day(2026, 7, 20),
            createdAt: Fixture.logged
        )
        plan.pet = pet
        context.insert(plan)
        try context.save()

        let settings = AppSettings.loadOrCreate(in: context)
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)

        let identifiers = planned.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("Kein Termin liegt in der Vergangenheit und das Budget wird gehalten")
    func windowAndBudgetAreRespected() throws {
        let (context, settings) = try makeStore()
        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)

        #expect(planned.allSatisfy { $0.fireDate >= asOf })
        #expect(planned.count <= NotificationPlanner.budget)
    }

    @Test("Ein abgesetztes Dauermedikament erinnert nicht weiter")
    func inactivePlanStopsReminding() throws {
        let (context, settings) = try makeStore()

        let plans = try context.fetch(FetchDescriptor<MedicationPlan>())
        let ongoing = try #require(plans.first { $0.kindValue == .ongoing })
        ongoing.isActive = false
        try context.save()

        let planned = service.plannedNotifications(context: context, settings: settings, asOf: asOf)
        #expect(planned.filter { $0.category == .dose }.isEmpty)
    }
}
