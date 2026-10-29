import Foundation
import Testing

@testable import Rudel

@MainActor
@Suite("Rudel Plus")
struct PlusStoreTests {

    private func makeStore(cachedPlus: Bool) -> PlusStore {
        let defaults = UserDefaults(suiteName: "PlusStoreTests-\(UUID().uuidString)")!
        defaults.set(cachedPlus, forKey: "rudel.plus.active")
        return PlusStore(defaults: defaults)
    }

    @Test("Ohne Plus geht genau ein Tier")
    func freeAllowsOnePet() {
        let store = makeStore(cachedPlus: false)
        #expect(store.canAddPet(existing: 0))
        #expect(!store.canAddPet(existing: 1))
        #expect(!store.canAddPet(existing: 3))
    }

    @Test("Mit Plus gehen beliebig viele Tiere")
    func plusAllowsMore() {
        let store = makeStore(cachedPlus: true)
        #expect(store.isPlus)
        #expect(store.canAddPet(existing: 5))
    }

    @Test("Ein zweites Tier öffnet das Angebot, das erste das Formular")
    func appStateRoutesNewPet() {
        let store = makeStore(cachedPlus: false)
        let state = AppState()
        state.present(.editPet(petID: nil), plus: store)
        #expect(state.presentedSheet == .editPet(petID: nil))

        state.petCount = 1
        state.present(.editPet(petID: nil), plus: store)
        #expect(state.presentedSheet == .plus)

        let existing = UUID()
        state.present(.editPet(petID: existing), plus: store)
        #expect(state.presentedSheet == .editPet(petID: existing))
    }

    @Test("Vier Farben sind kostenlos")
    func freeColors() {
        #expect(PetColor.allCases.filter(\.isFree) == [.forest, .lake, .berry, .rust])
    }
}
