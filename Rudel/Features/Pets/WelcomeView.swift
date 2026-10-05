import SwiftUI

/// Ein Einstieg, eine Aktion; keine Beispieldaten im persönlichen Journal.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Label {
                    Text("rudel").font(.system(.title2, design: .serif, weight: .bold))
                } icon: {
                    Image(systemName: "pawprint.fill").font(.title3)
                }
                .foregroundStyle(RudelTheme.accent)

                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        RudelIcon(symbol: "dog", color: RudelTheme.forest, fill: RudelTheme.sage, size: 68)
                        RudelIcon(symbol: "cat", color: RudelTheme.forest, fill: RudelTheme.apricot, size: 68)
                    }
                    Text("Für alles,\nwas euch gut tut.")
                        .font(RudelTheme.display())
                        .foregroundStyle(RudelTheme.cream)
                    Text("Medikamente, kleine Beobachtungen und große Entwicklungen. Ein Platz für die Gesundheit deines Rudels.")
                        .font(.body)
                        .foregroundStyle(RudelTheme.sage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RudelTheme.forest, in: .rect(cornerRadius: 28))

                RudelSectionHeading(title: "Euer Alltag. Gut im Blick.")
                VStack(alignment: .leading, spacing: 22) {
                    feature("Gaben im richtigen Moment", detail: "Medikamente und Schutzintervalle mit Erinnerungen.", symbol: "pills")
                    feature("Veränderungen festhalten", detail: "Symptome, Fotos und Gewicht im Verlauf.", symbol: "heart.text.square")
                    feature("Zyklen besser kennenlernen", detail: "Läufigkeit dokumentieren und Spannen einschätzen.", symbol: "circle.hexagonpath")
                }
                Label("Alle Einträge bleiben auf diesem Gerät.", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(RudelTheme.muted)
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(RudelTheme.canvas)
        .safeAreaInset(edge: .bottom) {
            Button {
                appState.present(.editPet(petID: nil))
            } label: {
                HStack {
                    Text("Tier anlegen")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(RudelPrimaryButtonStyle())
            .frame(maxWidth: 552)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(RudelTheme.canvas)
        }
    }

    private func feature(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RudelIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(RudelTheme.ink)
                Text(detail).font(.subheadline).foregroundStyle(RudelTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    WelcomeView().environment(AppState())
}
