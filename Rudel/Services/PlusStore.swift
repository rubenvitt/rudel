import Foundation
import Observation
import OSLog
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
/// `Transaction.currentEntitlements`, ergänzt um `Transaction.latest(for:)` und
/// die Käufe dieser Sitzung: Auf TestFlight (iOS 27) blieb die erste Quelle trotz
/// verifizierter Käufe leer, das Angebot ließ sich dann nicht mehr verlassen.
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
    private static let log = Logger(subsystem: "dev.rubeen.apps.rudel", category: "plus")
    private let defaults: UserDefaults
    /// Verifizierte Käufe seit dem Start, je Produkt. Sie gelten sofort, auch
    /// wenn StoreKit sie noch nicht als Berechtigung meldet.
    private var sessionGrants: [String: Transaction] = [:]
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
            record(transaction)
            await transaction.finish()
        }
        await refresh()
    }

    private func record(_ transaction: Transaction) {
        guard Self.ProductID.all.contains(transaction.productID) else { return }
        let current = isCurrent(transaction)
        sessionGrants[transaction.productID] = current ? transaction : nil
        if current { publish(true) }
    }

    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-rudelPlus") { return }
        #endif
        var active: [Transaction] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.ProductID.all.contains(transaction.productID),
                  transaction.revocationDate == nil
            else { continue }
            active.append(transaction)
        }
        let entitlementCount = active.count
        if active.isEmpty {
            for id in Self.ProductID.all {
                if case .verified(let transaction)? = await Transaction.latest(for: id), isCurrent(transaction) {
                    active.append(transaction)
                }
            }
        }
        let latestCount = active.count - entitlementCount
        // Erst nach allen `await`: ein Kauf während der Abfrage zählt so mit.
        let grants = sessionGrants.values.filter(isCurrent)
        active += grants
        Self.log.info("""
            refresh entitlements=\(entitlementCount, privacy: .public) \
            latest=\(latestCount, privacy: .public) \
            session=\(grants.count, privacy: .public) \
            products=\(active.map(\.productID).joined(separator: ","), privacy: .public)
            """)

        publish(!active.isEmpty)
        let neverExpires = active.contains { $0.expirationDate == nil }
        scheduleExpiryCheck(at: neverExpires ? nil : active.compactMap(\.expirationDate).max())
    }

    private func publish(_ active: Bool) {
        isPlus = active
        defaults.set(active, forKey: Self.cacheKey)
    }

    private func isCurrent(_ transaction: Transaction) -> Bool {
        Self.isActive(
            productID: transaction.productID,
            revocationDate: transaction.revocationDate,
            expirationDate: transaction.expirationDate,
            isUpgraded: transaction.isUpgraded,
            now: .now
        )
    }

    /// Für Quellen ohne Apples Berechtigungsprüfung. Kulanzfristen nach Ablauf
    /// kennt nur `currentEntitlements`, deshalb zählt hier das Ablaufdatum.
    static func isActive(
        productID: String,
        revocationDate: Date?,
        expirationDate: Date?,
        isUpgraded: Bool,
        now: Date
    ) -> Bool {
        guard ProductID.all.contains(productID), revocationDate == nil, !isUpgraded else { return false }
        return expirationDate.map { $0 > now } ?? true
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
