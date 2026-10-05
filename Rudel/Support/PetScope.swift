import RudelEngine
import SwiftData
import SwiftUI

/// Löst das gewählte Tier auf und stellt den Umschalter bereit (PRD §5.1).
///
/// Jede Feature-View wickelt ihren Inhalt hierin ein, statt selbst `AppState`
/// und `@Query` zu verdrahten. Damit ist der Umschalter überall identisch und
/// der „kein Tier gewählt"-Fall an einer Stelle behandelt.
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
            VStack(spacing: 0) {
                if pets.count > 1 {
                    petStrip
                }
                Group {
                    if let pet = selectedPet {
                        content(pet)
                    } else {
                        ContentUnavailableView(
                            "Kein Tier",
                            systemImage: "pawprint",
                            description: Text("Lege zuerst ein Tier an.")
                        )
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(RudelTheme.canvas)
            .toolbarBackground(RudelTheme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "pawprint.fill").font(.caption)
                        Text("rudel").font(.system(.title3, design: .serif, weight: .bold))
                    }
                    .foregroundStyle(RudelTheme.accent)
                    .accessibilityLabel("Rudel")
                    .fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(RudelTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }

    private var petStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(pets) { pet in
                    let selected = pet.id == selectedPet?.id
                    Button {
                        appState.selectedPetID = pet.id
                    } label: {
                        HStack(spacing: 8) {
                            PetAvatar(pet: pet, size: 30)
                            Text(pet.name.isEmpty ? "Unbenannt" : pet.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .frame(maxWidth: 220, alignment: .leading)
                            if selected {
                                Image(systemName: "checkmark").font(.caption.weight(.bold))
                            }
                        }
                        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 7)
                        .foregroundStyle(selected ? RudelTheme.cream : RudelTheme.ink)
                        .background(selected ? RudelTheme.forest : RudelTheme.surface, in: .capsule)
                    }
                    .buttonStyle(RudelTileButtonStyle())
                    .accessibilityLabel("Tier wechseln: \(pet.name)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("pet-switcher")
        .background(RudelTheme.canvas)
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
                ZStack {
                    RudelTheme.sage
                    Image(systemName: pet?.speciesValue.symbolName ?? "pawprint")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(RudelTheme.forest)
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
        case .dog: return "Hund"
        case .cat: return "Katze"
        }
    }
}
