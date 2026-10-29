import Foundation
import Observation
import StoreKit

/// Ob Rudel Plus aktiv ist: Abo (Monat/Jahr) oder Einmalkauf.
///
/// Kostenlos bleibt ein Tier mit allem, was für seine Gesundheit zählt.
/// Plus schaltet weitere Tiere, den Tierarzt-Bericht und alle Farben frei.
/// Läuft ein Abo aus, bleiben vorhandene Tiere und Daten vollständig nutzbar;
/// gesperrt wird nur, was neu hinzukäme.
///
/// Der zuletzt bekannte Stand liegt in `UserDefaults`, damit die App offline
/// und beim Start nicht kurz „kostenlos" zeigt. Die Wahrheit kommt aus
/// `Transaction.currentEntitlements`.
@MainActor
@Observable
final class PlusStore {
    static let shared = PlusStore()

    enum ProductID {
        static let monthly = "rudel.plus.monthly"
        static let yearly = "rudel.plus.yearly"
        static let lifetime = "rudel.plus.lifetime"
        static let all: Set<String> = [monthly, yearly, lifetime]
    }

    /// So viele Tiere gehen ohne Plus.
    static let freePetLimit = 1

    private(set) var isPlus: Bool

    private static let cacheKey = "rudel.plus.active"
    private let defaults: UserDefaults
    private var updates: Task<Void, Never>?
    /// Läuft ein Abo ohne Verlängerung aus, meldet `Transaction.updates`
    /// nichts. Deshalb zum Ablauf einmal neu prüfen.
    private var expiryCheck: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // UI-Tests legen mehrere Tiere an und teilen Berichte.
        if ProcessInfo.processInfo.arguments.contains("-rudelPlus") {
            isPlus = true
            return
        }
        #endif
        isPlus = defaults.bool(forKey: Self.cacheKey)
        // Käufe von anderen Geräten, Verlängerungen, Erstattungen.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    func handle(_ result: VerificationResult<Transaction>) async {
        if case .verified(let transaction) = result {
            await transaction.finish()
        }
        await refresh()
    }

    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-rudelPlus") { return }
        #endif
        var active = false
        var nextExpiry: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.ProductID.all.contains(transaction.productID),
                  transaction.revocationDate == nil
            else { continue }
            active = true
            if let expiry = transaction.expirationDate {
                nextExpiry = max(nextExpiry ?? expiry, expiry)
            } else {
                nextExpiry = nil // Einmalkauf: läuft nie ab
                break
            }
        }
        isPlus = active
        defaults.set(active, forKey: Self.cacheKey)
        scheduleExpiryCheck(at: nextExpiry)
    }

    private func scheduleExpiryCheck(at date: Date?) {
        expiryCheck?.cancel()
        guard let date else { return }
        expiryCheck = Task { [weak self] in
            // Schon abgelaufen, aber noch berechtigt: Kulanzfrist bei
            // Zahlungsproblemen. Dann stündlich statt sofort erneut prüfen.
            let remaining = date.timeIntervalSinceNow
            let delay = remaining > 0 ? remaining + 1 : 3600
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Wirft, wenn der App Store nicht erreichbar ist oder die Anmeldung
    /// abgebrochen wurde, damit das Angebot es anzeigen kann.
    func restore() async throws {
        try await AppStore.sync()
        await refresh()
    }

    /// Darf ein weiteres Tier angelegt werden?
    func canAddPet(existing count: Int) -> Bool {
        isPlus || count < Self.freePetLimit
    }
}
