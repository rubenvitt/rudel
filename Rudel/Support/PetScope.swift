import RudelEngine
import SwiftData
import SwiftUI

/// Löst das gewählte Tier auf und stellt den Umschalter bereit (PRD §5.1).
///
/// Jede tierbezogene Feature-View wickelt ihren Inhalt hierin ein, statt selbst
/// `AppState` und `@Query` zu verdrahten. Damit sitzt der Umschalter überall
/// an derselben Stelle (oben links), und der „kein Tier gewählt"-Fall ist an
/// einer Stelle behandelt.
///
/// ```swift
/// struct DashboardView: View {
///     var body: some View {
///         PetScope(title: "Heute") { pet in
///             // pet ist garantiert vorhanden
///         }
///     }
/// }
/// ```
struct PetScope<Content: View>: View {
    let title: String
    @ViewBuilder let content: (Pet) -> Content

    @Environment(AppState.self) private var appState
    @Query(sort: \Pet.createdAt) private var pets: [Pet]

    private var selectedPet: Pet? {
        if let id = appState.selectedPetID, let match = pets.first(where: { $0.id == id }) {
            return match
        }
        return pets.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let pet = selectedPet {
                    content(pet)
                        .rudelReadableWidth()
                } else {
                    ContentUnavailableView(
                        "Kein Tier",
                        systemImage: "pawprint",
                        description: Text("Lege zuerst ein Tier an.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(RudelTheme.canvas)
            .toolbarBackground(RudelTheme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PetSwitcher(pets: pets, selected: selectedPet)
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(RudelTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        // Ein Tierwechsel führt zurück auf die Startseite des Tabs. Sonst bliebe
        // eine geöffnete Unterseite beim alten Tier stehen.
        .id(selectedPet?.id)
    }
}

/// Tierbild mit Namen oben links. Ein Tipp öffnet die Auswahl aller Tiere —
/// sichtbar auch mit nur einem Tier, damit „weiteres Tier“ nie gesucht werden
/// muss.
struct PetSwitcher: View {
    let pets: [Pet]
    let selected: Pet?

    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            Section("Tier wählen") {
                ForEach(pets) { pet in
                    Button {
                        appState.selectedPetID = pet.id
                    } label: {
                        if pet.id == selected?.id {
                            Label(displayName(pet), systemImage: "checkmark")
                        } else {
                            Text(displayName(pet))
                        }
                    }
                    .accessibilityLabel("Tier wechseln: \(displayName(pet))")
                    .accessibilityAddTraits(pet.id == selected?.id ? [.isSelected] : [])
                }
            }
            Section {
                Button {
                    appState.present(.editPet(petID: nil))
                } label: {
                    Label("Tier hinzufügen", systemImage: "plus")
                }
                Button {
                    appState.selectedTab = .rudel
                } label: {
                    Label("Tiere verwalten", systemImage: "pawprint")
                }
            }
        } label: {
            HStack(spacing: 6) {
                PetAvatar(pet: selected, size: 28)
                Text(selected.map(displayName) ?? String(localized: "Tier"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(RudelTheme.ink)
        }
        .accessibilityLabel("Tier: \(selected.map(displayName) ?? String(localized: "keins", comment: "Kein Tier gewählt")). Wechseln")
        .accessibilityIdentifier("pet-switcher")
    }

    private func displayName(_ pet: Pet) -> String {
        pet.name.isEmpty ? String(localized: "Unbenannt", comment: "Tier ohne Namen") : pet.name
    }
}

/// Rundes Profilbild, mit Art-Symbol als Platzhalter.
struct PetAvatar: View {
    let pet: Pet?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let data = pet?.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                let color = pet?.colorValue ?? .forest
                ZStack {
                    color.soft
                    Image(systemName: pet?.displaySymbol ?? "pawprint")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(color.deep)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

extension Species {
    var symbolName: String {
        switch self {
        case .dog: return "dog"
        case .cat: return "cat"
        }
    }

    var label: String {
        switch self {
        case .dog: return String(localized: "Hund")
        case .cat: return String(localized: "Katze")
        }
    }
}
