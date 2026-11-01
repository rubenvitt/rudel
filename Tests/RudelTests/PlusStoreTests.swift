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

    @Test("Ein Kauf gilt, solange er weder erstattet noch abgelaufen ist")
    func activePurchases() {
        let now = Date(timeIntervalSince1970: 1_000)
        func isActive(
            _ productID: String = PlusStore.ProductID.lifetime,
            revoked: Date? = nil,
            expires: Date? = nil,
            upgraded: Bool = false
        ) -> Bool {
            PlusStore.isActive(
                productID: productID, revocationDate: revoked, expirationDate: expires,
                isUpgraded: upgraded, now: now
            )
        }

        #expect(isActive())
        #expect(isActive(PlusStore.ProductID.monthly, expires: now.addingTimeInterval(1)))
        #expect(!isActive(PlusStore.ProductID.monthly, expires: now))
        #expect(!isActive(revoked: now))
        #expect(!isActive(PlusStore.ProductID.monthly, expires: now.addingTimeInterval(1), upgraded: true))
        #expect(!isActive("fremdes.produkt"))
    }

    @Test("Vier Farben sind kostenlos")
    func freeColors() {
        #expect(PetColor.allCases.filter(\.isFree) == [.forest, .lake, .berry, .rust])
    }
}
