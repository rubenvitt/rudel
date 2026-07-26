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
    /// Nur Tiere anzeigen, für die das Zyklus-Modul relevant ist. Für den
    /// Zyklus-Tab: ein Kater darf dort nicht auswählbar sein.
    var cycleTrackingOnly: Bool = false
    @ViewBuilder let content: (Pet) -> Content

    @Environment(AppState.self) private var appState
    @Query(sort: \Pet.createdAt) private var allPets: [Pet]

    private var pets: [Pet] {
        cycleTrackingOnly ? allPets.filter(\.tracksCycle) : allPets
    }

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
                } else {
                    ContentUnavailableView(
                        cycleTrackingOnly ? "Kein Tier mit Zyklus" : "Kein Tier",
                        systemImage: "pawprint",
                        description: Text(
                            cycleTrackingOnly
                                ? "Der Zyklus wird nur für unkastrierte Hündinnen geführt."
                                : "Lege zuerst ein Tier an."
                        )
                    )
                }
            }
            .navigationTitle(title)
            .toolbar {
                if pets.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        PetSwitcher(pets: pets, selectedPet: selectedPet)
                    }
                }
            }
        }
    }
}

/// Tier-Umschalter im Kopfbereich. Als Menü statt Segmented Control, damit er
/// auch bei mehr als zwei Tieren trägt.
private struct PetSwitcher: View {
    let pets: [Pet]
    let selectedPet: Pet?

    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            ForEach(pets) { pet in
                Button {
                    appState.selectedPetID = pet.id
                } label: {
                    Label {
                        Text(pet.name.isEmpty ? "Unbenannt" : pet.name)
                    } icon: {
                        if pet.id == selectedPet?.id {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: pet.speciesValue.symbolName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                PetAvatar(pet: selectedPet, size: 28)
                Text(selectedPet?.name ?? "Tier")
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Tier wechseln")
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
                    Color.accentColor.opacity(0.15)
                    Image(systemName: pet?.speciesValue.symbolName ?? "pawprint")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(Color.accentColor)
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
