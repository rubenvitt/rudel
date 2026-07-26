import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Die abgeleiteten Eigenschaften von `Pet`.
///
/// `tracksCycle` entscheidet, ob ein ganzes Modul sichtbar ist; `effectiveSizeClass`
/// bestimmt den Startwert der Zyklusprognose. Beide sind Konjunktionen bzw.
/// Prioritätsketten — die klassische Stelle, an der ein `||` statt `&&` oder eine
/// vertauschte Priorität lange unentdeckt bleibt.
@MainActor
@Suite("Pet-Adapter")
struct PetAdapterTests {

    // MARK: tracksCycle

    @Test("tracksCycle ist genau dann wahr, wenn Hund + weiblich + nicht kastriert")
    func tracksCycleCoversAllCombinations() throws {
        let context = try makeContext()

        // Alle acht Kombinationen. Katzen sind bewusst ausgeschlossen (siehe
        // `Species`), kastrierte Tiere und Rüden ebenso.
        let cases: [(species: Species, isFemale: Bool, isNeutered: Bool, expected: Bool)] = [
            (.dog, true, false, true),
            (.dog, true, true, false),
            (.dog, false, false, false),
            (.dog, false, true, false),
            (.cat, true, false, false),
            (.cat, true, true, false),
            (.cat, false, false, false),
            (.cat, false, true, false),
        ]

        for testCase in cases {
            let pet = Pet(
                name: "Testtier",
                species: testCase.species,
                isFemale: testCase.isFemale,
                isNeutered: testCase.isNeutered,
                createdAt: Fixture.logged
            )
            context.insert(pet)
            #expect(
                pet.tracksCycle == testCase.expected,
                """
                \(testCase.species.rawValue), weiblich=\(testCase.isFemale), \
                kastriert=\(testCase.isNeutered)
                """
            )
        }
        try context.save()

        // Absicherung der Tabelle selbst: genau eine Kombination darf wahr sein.
        let expectedTrueCases = cases.filter { $0.expected }
        #expect(cases.count == 8)
        #expect(expectedTrueCases.count == 1)
    }

    // MARK: effectiveSizeClass

    @Test("Override schlägt das Gewicht")
    func overrideBeatsWeight() throws {
        let context = try makeContext()
        let pet = Pet(
            name: "Nala",
            species: .dog,
            sizeClassOverride: .giant,
            createdAt: Fixture.logged
        )
        context.insert(pet)

        // 5 kg würde ohne Override `.small` ergeben — der Override muss gewinnen.
        let entry = WeightEntry(
            date: Fixture.day(2026, 6, 1),
            valueKg: 5,
            loggedAt: Fixture.logged
        )
        context.insert(entry)
        entry.pet = pet
        try context.save()

        #expect(pet.latestWeightKg == 5)
        #expect(pet.effectiveSizeClass == .giant)
    }

    @Test("Ohne Override entscheidet das Gewicht")
    func weightBeatsDefault() throws {
        let context = try makeContext()

        // Bewusst Werte, die nicht `.medium` ergeben — sonst wäre nicht zu
        // unterscheiden, ob das Gewicht oder der Default gegriffen hat.
        let expectations: [(weightKg: Double, sizeClass: DogSizeClass)] = [
            (5, .small),
            (50, .giant),
            (30, .large),
        ]
        for expectation in expectations {
            let pet = Pet(name: "Testtier", species: .dog, createdAt: Fixture.logged)
            context.insert(pet)
            let entry = WeightEntry(
                date: Fixture.day(2026, 6, 1),
                valueKg: expectation.weightKg,
                loggedAt: Fixture.logged
            )
            context.insert(entry)
            entry.pet = pet
            try context.save()

            #expect(
                pet.effectiveSizeClass == expectation.sizeClass,
                "\(expectation.weightKg) kg muss \(expectation.sizeClass.rawValue) ergeben"
            )
        }
    }

    @Test("Ohne Gewicht und ohne Override bleibt es medium")
    func defaultSizeClassIsMedium() throws {
        let context = try makeContext()
        let pet = Pet(name: "Nala", species: .dog, createdAt: Fixture.logged)
        context.insert(pet)
        try context.save()

        #expect(pet.weightEntries.isEmpty)
        #expect(pet.latestWeightKg == nil)
        #expect(pet.effectiveSizeClass == .medium)
    }

    @Test("Ein Gewicht von 0 zählt als nicht gesetzt")
    func zeroWeightFallsBackToMedium() throws {
        let context = try makeContext()
        let pet = Pet(name: "Nala", species: .dog, createdAt: Fixture.logged)
        context.insert(pet)
        // `DogSizeClass(weightKg: 0)` wäre `.small`; ein Nullgewicht ist aber
        // ein leerer Eintrag, keine Angabe.
        let entry = WeightEntry(
            date: Fixture.day(2026, 6, 1),
            valueKg: 0,
            loggedAt: Fixture.logged
        )
        context.insert(entry)
        entry.pet = pet
        try context.save()

        #expect(pet.latestWeightKg == 0)
        #expect(pet.effectiveSizeClass == .medium)
    }

    @Test("latestWeightKg nimmt den neuesten Eintrag, nicht den zuerst eingefügten")
    func latestWeightUsesNewestEntry() throws {
        let context = try makeContext()
        let pet = Pet(name: "Nala", species: .dog, createdAt: Fixture.logged)
        context.insert(pet)

        // Der neueste Eintrag steht in der Mitte der Einfügereihenfolge, und
        // jedes Gewicht ergibt eine andere Größenklasse: 22 kg → medium,
        // 48 kg → giant, 30 kg → large. Ein Griff auf den falschen Eintrag ist
        // damit sichtbar, nicht nur zufällig gleich.
        let entries: [(date: Date, weightKg: Double)] = [
            (Fixture.day(2026, 1, 10), 22),
            (Fixture.day(2026, 6, 1), 48),
            (Fixture.day(2026, 3, 5), 30),
        ]
        for entry in entries {
            let weight = WeightEntry(
                date: entry.date,
                valueKg: entry.weightKg,
                loggedAt: Fixture.logged
            )
            context.insert(weight)
            weight.pet = pet
        }
        try context.save()

        #expect(pet.weightEntries.count == 3)
        #expect(pet.latestWeightKg == 48)
        #expect(pet.effectiveSizeClass == .giant)
    }

    @Test("engineID ist die UUID des Tiers als String")
    func engineIDIsUUIDString() throws {
        let context = try makeContext()
        let pet = Pet(name: "Nala", species: .dog, createdAt: Fixture.logged)
        context.insert(pet)
        try context.save()

        #expect(pet.engineID == pet.id.uuidString)
    }
}
