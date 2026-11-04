import OSLog
import StoreKit
import SwiftUI

/// Angebot für Rudel Plus. Kurz, ehrlich, ohne Druck: was dazukommt, was
/// kostenlos bleibt, drei Wege zu kaufen.
struct PlusPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlusStore.self) private var plus

    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var offers: Offers = .loading

    /// Angebote vorab laden, damit ein Ladefehler sichtbar wird und sich
    /// wiederholen lässt, statt leere Kacheln zu zeigen.
    private enum Offers {
        case loading
        case loaded([Product])
        case failed
    }

    private static let order = [PlusStore.ProductID.yearly, PlusStore.ProductID.monthly, PlusStore.ProductID.lifetime]
    private static let log = Logger(subsystem: "dev.rubeen.apps.rudel", category: "plus")

    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyURL = URL(string: "https://github.com/rubenvitt/rudel/blob/main/PRIVACY.md")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    features
                    products
                    footer
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(RudelTheme.canvas)
            .task { await loadOffers() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .onInAppPurchaseCompletion { _, result in
            switch result {
            case .success(.success(let verification)):
                await plus.handle(verification)
                if case .unverified = verification {
                    errorMessage = "Der Kauf ließ sich nicht bestätigen. Versuch es mit „Käufe wiederherstellen“."
                }
            case .success(.pending):
                errorMessage = "Der Kauf wartet noch auf eine Freigabe. Rudel Plus schaltet sich danach von selbst frei."
            case .success(.userCancelled), .success:
                break
            case .failure:
                errorMessage = "Der Kauf hat nicht geklappt. Prüf deine Verbindung und versuch es noch einmal."
            }
        }
        .alert("Rudel Plus", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: plus.isPlus) { _, active in
            if active { dismiss() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "pawprint.fill")
                .font(.title)
                .foregroundStyle(RudelTheme.cream)
                .frame(width: 60, height: 60)
                .background(RudelTheme.forest, in: .circle)
                .accessibilityHidden(true)
            Text("Rudel Plus")
                .font(RudelTheme.display(.largeTitle))
                .foregroundStyle(RudelTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Für alle, deren Rudel größer ist als ein Tier.")
                .foregroundStyle(RudelTheme.muted)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            feature("Beliebig viele Tiere", systemImage: "pawprint")
            feature("Tierarzt-Bericht als PDF", systemImage: "doc.text")
            feature("Alle Farben", systemImage: "paintpalette")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RudelTheme.surface, in: .rect(cornerRadius: RudelTheme.cardRadius))
    }

    private func feature(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(RudelTheme.ink)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(RudelTheme.accent)
        }
        .font(.body.weight(.medium))
    }

    private var products: some View {
        VStack(spacing: 12) {
            switch offers {
            case .loading:
                ProgressView("Angebote werden geladen …")
                    .frame(maxWidth: .infinity)
                    .padding(16)
            case .loaded(let products):
                ForEach(products) { product in
                    ProductView(product)
                        .productViewStyle(.compact)
                        .padding(16)
                        .background(RudelTheme.surface, in: .rect(cornerRadius: 20))
                }
            case .failed:
                VStack(spacing: 12) {
                    Text("Die Angebote lassen sich gerade nicht laden. Prüf deine Verbindung.")
                        .foregroundStyle(RudelTheme.muted)
                        .multilineTextAlignment(.center)
                    Button("Erneut versuchen") {
                        Task { await loadOffers() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(RudelTheme.surface, in: .rect(cornerRadius: 20))
            }
        }
        .tint(RudelTheme.accent)
    }

    /// Der App Store antwortet beim ersten Aufruf manchmal leer oder langsam,
    /// deshalb bis zu dreimal mit kurzer Pause versuchen.
    private func loadOffers() async {
        offers = .loading
        var best: [Product] = []
        for attempt in 1...3 {
            do {
                let found = try await Product.products(for: Self.order)
                let sorted = Self.order.compactMap { id in found.first { $0.id == id } }
                if sorted.count == Self.order.count {
                    offers = .loaded(sorted)
                    return
                }
                if sorted.count > best.count { best = sorted }
                Self.log.error("paywall: \(sorted.count, privacy: .public) of \(Self.order.count, privacy: .public) products (attempt \(attempt, privacy: .public))")
            } catch {
                Self.log.error("paywall: load failed (attempt \(attempt, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
            if attempt < 3 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
        }
        // Fehlt ein Angebot auch nach drei Versuchen, wenigstens die übrigen zeigen.
        offers = best.isEmpty ? .failed : .loaded(best)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text("Medikamente, Erinnerungen und alles für die Gesundheit bleiben für ein Tier kostenlos.")
                Text("Abos verlängern sich automatisch und lassen sich jederzeit in den Einstellungen deines Apple-Accounts kündigen.")
            }
            .foregroundStyle(RudelTheme.muted)
            Button(isRestoring ? "Wird geprüft …" : "Käufe wiederherstellen") {
                isRestoring = true
                Task {
                    do {
                        try await plus.restore()
                        if !plus.isPlus {
                            errorMessage = "Es wurde kein Kauf gefunden."
                        }
                    } catch {
                        errorMessage = "Wiederherstellen hat nicht geklappt. Prüf deine Verbindung und versuch es noch einmal."
                    }
                    isRestoring = false
                }
            }
            .disabled(isRestoring)
            HStack(spacing: 16) {
                Link("Nutzungsbedingungen", destination: Self.termsURL)
                Link("Datenschutz", destination: Self.privacyURL)
            }
        }
        .font(.footnote)
        .tint(RudelTheme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
