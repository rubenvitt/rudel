import SwiftData
import SwiftUI

/// Gesundheits-Tab: Symptome und Gewicht (PRD §5.4, §5.5).
///
/// Zwei Bereiche in einem Tab statt zwei Tabs. Beides sind Beobachtungen am
/// Tier, die oft beim selben Anlass entstehen — und die Tab-Leiste hat mit
/// Zyklus schon fünf Einträge.
struct HealthView: View {
    @Environment(AppState.self) private var appState

    @State private var section: HealthSection = .symptoms

    var body: some View {
        PetScope(title: "Gesundheit") { pet in
            Group {
                switch section {
                case .symptoms:
                    SymptomHistorySection(pet: pet)
                case .weight:
                    WeightHistorySection(pet: pet)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                sectionPicker
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.present(section.addSheet(petID: pet.id))
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(section.addLabel)
                }
            }
        }
    }

    /// Der Umschalter steht über der Liste, nicht in der Navigationsleiste: dort
    /// sitzt links schon der Tier-Umschalter und rechts das Plus.
    private var sectionPicker: some View {
        Picker("Bereich", selection: $section) {
            ForEach(HealthSection.allCases) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Die zwei Bereiche des Tabs. Eigener Typ auf Datei-Ebene statt verschachtelt,
/// damit `Section` in den Listen nicht verdeckt wird.
private enum HealthSection: Hashable, Identifiable, CaseIterable {
    case symptoms
    case weight

    var id: Self { self }

    var label: String {
        switch self {
        case .symptoms: return "Symptome"
        case .weight: return "Gewicht"
        }
    }

    /// Beschriftung für VoiceOver — der Button zeigt nur ein Plus.
    var addLabel: String {
        switch self {
        case .symptoms: return "Symptom erfassen"
        case .weight: return "Gewicht erfassen"
        }
    }

    func addSheet(petID: UUID) -> AppState.Sheet {
        switch self {
        case .symptoms: return .logSymptom(petID: petID)
        case .weight: return .logWeight(petID: petID)
        }
    }
}
