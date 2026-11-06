import SwiftUI

/// Feste Adressen, die an mehreren Stellen gebraucht werden.
enum RudelLinks {
    /// Apples Standard-Lizenzvertrag (EULA) — gilt für Rudel als Nutzungsbedingungen.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://github.com/rubenvitt/rudel/blob/main/PRIVACY.md")!
}

/// Das „+“ oben rechts. Überall ein Menü mit beschrifteten Einträgen, damit das
/// Symbol in jedem Tab dasselbe bedeutet: „Hier etwas Neues anlegen“.
struct RudelAddMenu<Items: View>: View {
    var accessibilityID = "add-menu"
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Hinzufügen")
        .accessibilityIdentifier(accessibilityID)
    }
}

/// Sichtbarer Weg zu den Aktionen einer Zeile. Wischen und langes Drücken
/// bleiben, sind aber nicht mehr der einzige Zugang.
struct RudelRowMenu<Items: View>: View {
    let title: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(RudelTheme.accent)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Aktionen: \(title)")
    }
}

extension View {
    /// Begrenzt Listen und Scroll-Inhalte auf eine lesbare Breite. Auf dem
    /// iPhone wirkt das nicht, auf dem iPad laufen Zeilen sonst über den ganzen
    /// Bildschirm.
    func rudelReadableWidth(_ maxWidth: CGFloat = 720) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var margin: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                margin = max(0, (width - maxWidth) / 2)
            }
    }
}

/// Eine Aktion für `RudelRowMenu`, wenn die Liste der Aktionen erst zur
/// Laufzeit feststeht.
struct RowAction: Identifiable {
    let title: String
    let symbol: String
    let run: @MainActor () -> Void

    var id: String { title }

    init(title: String, symbol: String, run: @escaping @MainActor () -> Void) {
        self.title = title
        self.symbol = symbol
        self.run = run
    }
}
