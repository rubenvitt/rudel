import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// `AppSettings.loadOrCreate(in:)` — der Ersatz für ein `@Attribute(.unique)`,
/// das CloudKit nicht erlaubt. Die Einmaligkeit hängt also allein an dieser
/// Funktion; ohne Test wäre sie eine Behauptung im Kommentar.
@MainActor
@Suite("AppSettings.loadOrCreate")
struct AppSettingsStoreTests {

    @Test("Erster Aufruf legt genau eine Instanz an")
    func firstCallCreatesExactlyOne() throws {
        let context = try makeContext()
        let before = try context.fetch(FetchDescriptor<AppSettings>())
        #expect(before.isEmpty)

        let settings = AppSettings.loadOrCreate(in: context)
        let after = try context.fetch(FetchDescriptor<AppSettings>())

        #expect(after.count == 1)
        #expect(after.first?.id == settings.id)
    }

    @Test("Zweiter Aufruf gibt dieselbe Instanz zurück und legt keine zweite an")
    func secondCallReturnsSameInstance() throws {
        let context = try makeContext()
        let first = AppSettings.loadOrCreate(in: context)
        let firstID = first.id

        let second = AppSettings.loadOrCreate(in: context)
        let stored = try context.fetch(FetchDescriptor<AppSettings>())

        #expect(second.id == firstID)
        #expect(stored.count == 1)
    }

    @Test("Bestehende Einstellungen werden beim zweiten Aufruf nicht überschrieben")
    func existingValuesSurvive() throws {
        let context = try makeContext()
        let created = AppSettings.loadOrCreate(in: context)
        created.notificationsEnabled = false
        created.leadDays = [14, 3]
        created.reminderMinutesFromMidnight = 7 * 60 + 30
        created.didCompleteOnboarding = true
        try context.save()

        let again = AppSettings.loadOrCreate(in: context)

        #expect(again.notificationsEnabled == false)
        #expect(again.leadDays == [14, 3])
        #expect(again.reminderMinutesFromMidnight == 450)
        #expect(again.didCompleteOnboarding)
    }

    @Test("Zwei vorhandene Instanzen werden deterministisch auf eine reduziert")
    func twoDuplicatesCollapseDeterministically() throws {
        let context = try makeContext()
        let first = AppSettings()
        let second = AppSettings()
        context.insert(first)
        context.insert(second)
        try context.save()
        let before = try context.fetch(FetchDescriptor<AppSettings>())
        #expect(before.count == 2)

        // IDs vor dem Aufruf sichern: eine der beiden Instanzen wird gelöscht,
        // danach ist der Zugriff darauf nicht mehr verlässlich.
        let ids = [first.id, second.id]
        let expectedKeeperID = try #require(ids.min(by: { $0.uuidString < $1.uuidString }))

        let resolved = AppSettings.loadOrCreate(in: context)
        let stored = try context.fetch(FetchDescriptor<AppSettings>())

        #expect(stored.count == 1)
        #expect(resolved.id == expectedKeeperID)
        #expect(stored.first?.id == expectedKeeperID)
    }

    @Test("Auch drei Instanzen werden auf genau eine reduziert")
    func threeDuplicatesCollapseToOne() throws {
        let context = try makeContext()
        var ids: [UUID] = []
        for _ in 0..<3 {
            let settings = AppSettings()
            context.insert(settings)
            ids.append(settings.id)
        }
        try context.save()

        let expectedKeeperID = try #require(ids.min(by: { $0.uuidString < $1.uuidString }))
        let resolved = AppSettings.loadOrCreate(in: context)
        let stored = try context.fetch(FetchDescriptor<AppSettings>())

        #expect(stored.count == 1)
        #expect(resolved.id == expectedKeeperID)
    }

    @Test("Nach dem Aufräumen bleibt der nächste Aufruf stabil")
    func repeatedCallsAfterCleanupAreStable() throws {
        let context = try makeContext()
        context.insert(AppSettings())
        context.insert(AppSettings())
        try context.save()

        let firstResolve = AppSettings.loadOrCreate(in: context)
        let keeperID = firstResolve.id
        // Der zweite Durchlauf darf weder eine neue Instanz anlegen noch eine
        // andere zurückgeben — sonst wanderten die Einstellungen bei jedem
        // App-Start.
        let secondResolve = AppSettings.loadOrCreate(in: context)
        let stored = try context.fetch(FetchDescriptor<AppSettings>())

        #expect(secondResolve.id == keeperID)
        #expect(stored.count == 1)
    }
}
