import RudelEngine
import SwiftUI

/// Erster Start: es existiert noch kein Tier. `RootView` zeigt diesen Screen,
/// solange `pets.isEmpty` — er ist damit auch die einzige Stelle, an der Rudel
/// erklärt, wofür es gut ist.
///
/// Bewusst **kein mehrseitiges Onboarding**: der einzige sinnvolle nächste
/// Schritt ist, ein Tier anzulegen. Alles andere erklärt die App dort, wo es
/// gebraucht wird. Ein Tap führt ins Formular; das Sheet präsentiert `RootView`.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                features
                privacyNote
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)
            // Auf dem iPad soll der Text nicht über die ganze Breite laufen.
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { createButton }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Willkommen bei Rudel")
                    .font(.largeTitle.weight(.bold))

                Text("Tierarzt-Apps verwalten Termine. Rudel verwaltet, was dazwischen passiert — und behält die Historie, aus der sich das Nächste ausrechnen lässt.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 24) {
            WelcomeFeatureRow(
                systemImage: "pills",
                title: "Intervalle statt Kalendernotizen",
                detail: "Wurmkur, Zeckenschutz, Tollwut: Rudel rechnet aus letzter Gabe und Wirkdauer, wann die nächste fällig ist — und erinnert vorher, nicht erst am Tag danach."
            )
            WelcomeFeatureRow(
                systemImage: "circle.hexagonpath",
                title: "Läufigkeit als Spanne",
                detail: "Tag 1 eintragen genügt. Die Prognose kommt als Zeitraum mit Konfidenzangabe und rückt mit jedem geloggten Zyklus näher an dein Tier heran."
            )
            WelcomeFeatureRow(
                systemImage: "stethoscope",
                title: "Symptome belegen",
                detail: "Die dritte Ohrenentzündung in diesem Jahr — mit Datum, Schweregrad und Foto dokumentiert, statt sie beim Tierarzt aus dem Gedächtnis zu rekonstruieren."
            )
            WelcomeFeatureRow(
                systemImage: "scalemass",
                title: "Gewicht im Blick",
                detail: "Verlauf, Zielbereich und Futtermenge an einer Stelle. So fällt ein halbes Kilo auf, bevor es zwei sind."
            )
        }
    }

    private var privacyNote: some View {
        Label(
            "Alle Einträge bleiben auf diesem Gerät.",
            systemImage: "lock"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var createButton: some View {
        Button {
            appState.present(.editPet(petID: nil))
        } label: {
            Text("Tier anlegen")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

/// Eine Zeile der Kurzvorstellung. Icon und Text nebeneinander, wobei das Icon
/// eine feste Breite hat — so bleibt die Liste auch bei großer Schrift bündig,
/// ohne dass der Text abgeschnitten wird.
private struct WelcomeFeatureRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    WelcomeView()
        .environment(AppState())
}
