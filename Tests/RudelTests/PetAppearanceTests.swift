import Foundation
import RudelEngine
import SwiftData
import Testing

@testable import Rudel

/// Farbe und Symbol eines Tiers. Die Rohwerte stehen in der Datenbank; ein
/// umbenannter Fall würde jedes gespeicherte Tier stillschweigend umfärben.
@MainActor
@Suite("Tier-Aussehen")
struct PetAppearanceTests {

    @Test("Rohwerte der Farben bleiben stabil")
    func colorRawValuesAreStable() {
        #expect(PetColor.allCases.map(\.rawValue) == [
            "forest", "lake", "berry", "rust", "slate", "plum", "olive", "cocoa",
        ])
    }

    @Test("Neues Tier ist tannengrün und zeigt sein Art-Symbol")
    func defaultsFollowSpecies() throws {
        let context = try makeContext()
        let cat = Pet(name: "Mia", species: .cat)
        context.insert(cat)
        #expect(cat.colorValue == .forest)
        #expect(cat.displaySymbol == "cat")

        cat.symbolName = "star.fill"
        #expect(cat.displaySymbol == "star.fill")
    }

    @Test("Farbe und Symbol überstehen das Speichern")
    func appearancePersists() throws {
        let context = try makeContext()
        let pet = Pet(name: "Zola")
        pet.colorValue = .berry
        pet.symbolName = "heart.fill"
        context.insert(pet)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Pet>()).first)
        #expect(fetched.colorValue == .berry)
        #expect(fetched.symbolName == "heart.fill")
    }
}
