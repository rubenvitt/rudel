import SwiftData
import SwiftUI

/// Gesundheits-Tab: Symptome, Gewicht und Tierarzt (PRD §5.4, §5.5).
///
/// Drei Bereiche in einem Tab statt drei Tabs. Symptome und Gewicht sind
/// Beobachtungen am Tier, die oft beim selben Anlass entstehen, und der
/// Tierarzt ist der Ort, an dem sie gebraucht werden. Die Tab-Leiste hat mit
/// Zyklus schon fünf Einträge; ein sechster zwänge iOS in „Mehr".
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
                case .vet:
                    VetSection(pet: pet)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                sectionPicker
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    addButton(petID: pet.id)
                }
            }
        }
    }

    /// Im Tierarzt-Bereich gibt es zwei Dinge anzulegen; dort wird das Plus
    /// zum Menü, statt einen der beiden Einstiege zu verstecken.
    @ViewBuilder
    private func addButton(petID: UUID) -> some View {
        if section == .vet {
            Menu {
                Button {
                    appState.present(.editAppointment(appointmentID: nil, petID: petID))
                } label: {
                    Label("Termin", systemImage: "calendar.badge.plus")
                }
                Button {
                    appState.present(.editPractice(practiceID: nil))
                } label: {
                    Label("Praxis", systemImage: "building.2")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(section.addLabel)
            .accessibilityIdentifier("vet-add-menu")
        } else if let sheet = section.addSheet(petID: petID) {
            Button {
                appState.present(sheet)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(section.addLabel)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RudelTheme.canvas)
    }
}

/// Die Bereiche des Tabs. Eigener Typ auf Datei-Ebene statt verschachtelt,
/// damit `Section` in den Listen nicht verdeckt wird.
private enum HealthSection: Hashable, Identifiable, CaseIterable {
    case symptoms
    case weight
    case vet

    var id: Self { self }

    var label: String {
        switch self {
        case .symptoms: return "Symptome"
        case .weight: return "Gewicht"
        case .vet: return "Tierarzt"
        }
    }

    /// Beschriftung für VoiceOver — der Button zeigt nur ein Plus.
    var addLabel: String {
        switch self {
        case .symptoms: return "Symptom erfassen"
        case .weight: return "Gewicht erfassen"
        case .vet: return "Termin oder Praxis anlegen"
        }
    }

    /// `nil` für den Tierarzt-Bereich: dort öffnet das Plus ein Menü.
    func addSheet(petID: UUID) -> AppState.Sheet? {
        switch self {
        case .symptoms: return .logSymptom(petID: petID)
        case .weight: return .logWeight(petID: petID)
        case .vet: return nil
        }
    }
}
