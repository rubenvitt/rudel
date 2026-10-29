import StoreKit
import SwiftUI

/// Angebot für Rudel Plus. Kurz, ehrlich, ohne Druck: was dazukommt, was
/// kostenlos bleibt, drei Wege zu kaufen.
struct PlusPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlusStore.self) private var plus

    @State private var isRestoring = false

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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(let verification)) = result {
                await plus.handle(verification)
            }
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
            ForEach([PlusStore.ProductID.yearly, PlusStore.ProductID.monthly, PlusStore.ProductID.lifetime], id: \.self) { id in
                ProductView(id: id)
                    .productViewStyle(.compact)
                    .padding(16)
                    .background(RudelTheme.surface, in: .rect(cornerRadius: 20))
            }
        }
        .tint(RudelTheme.accent)
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
                    await plus.restore()
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
