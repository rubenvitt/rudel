import RudelEngine
import SwiftData
import SwiftUI

/// Wurzel der App: Tab-Navigation plus zentrale Sheet-Präsentation.
///
/// Der Tier-Umschalter sitzt in jedem Tab im Kopfbereich (PRD §5.1), nicht
/// hier — so bleibt er dort sichtbar, wo gerade gearbeitet wird.
struct RootView: View {
    @Environment(AppState.self) private var appState

    @Query(sort: \Pet.createdAt) private var pets: [Pet]

    var body: some View {
        Group {
            if pets.isEmpty {
                WelcomeView()
            } else {
                tabs
            }
        }
        .task { syncSelection() }
        .onChange(of: pets.count) { syncSelection() }
        .sheet(item: sheetBinding) { sheet in
            SheetPresenter(sheet: sheet)
        }
    }

    private var tabs: some View {
        TabView(selection: tabBinding) {
            Tab("Heute", systemImage: "calendar.badge.clock", value: AppState.Tab.today) {
                DashboardView()
            }
            Tab("Medikamente", systemImage: "pills", value: AppState.Tab.medication) {
                MedicationListView()
            }
            if showsCycleTab {
                Tab("Zyklus", systemImage: "circle.hexagonpath", value: AppState.Tab.cycle) {
                    CycleOverviewView()
                }
            }
            Tab("Gesundheit", systemImage: "heart.text.square", value: AppState.Tab.health) {
                HealthView()
            }
            Tab("Profil", systemImage: "pawprint", value: AppState.Tab.profile) {
                PetProfileView()
            }
        }
    }

    /// `@Observable` über `@Environment` liefert kein `$`-Binding — deshalb
    /// hier von Hand gebaut.
    private var sheetBinding: Binding<AppState.Sheet?> {
        Binding(
            get: { appState.presentedSheet },
            set: { appState.presentedSheet = $0 }
        )
    }

    private var tabBinding: Binding<AppState.Tab> {
        Binding(
            get: { appState.selectedTab },
            set: { appState.selectedTab = $0 }
        )
    }

    /// Der Zyklus-Tab erscheint nur, wenn mindestens ein Tier ihn braucht —
    /// eine unkastrierte Hündin. Für Kater/Katze und kastrierte Tiere wäre er
    /// leerer Ballast.
    private var showsCycleTab: Bool {
        pets.contains { $0.tracksCycle }
    }

    /// Hält die Auswahl gültig: gelöschtes Tier ⇒ auf das erste zurückfallen.
    /// Ohne das zeigt die App nach einem Löschen leere Screens.
    private func syncSelection() {
        if let id = appState.selectedPetID, pets.contains(where: { $0.id == id }) {
            return
        }
        appState.selectedPetID = pets.first?.id
        if appState.selectedTab == .cycle, !showsCycleTab {
            appState.selectedTab = .today
        }
    }
}

/// Löst den `AppState.Sheet`-Fall in die zugehörige View auf. Eine Stelle für
/// alle Sheets — so kann kein Screen ein Sheet auf eine andere Art öffnen.
private struct SheetPresenter: View {
    let sheet: AppState.Sheet

    var body: some View {
        switch sheet {
        case .quickLogMedication(let petID):
            QuickLogMedicationSheet(petID: petID)
        case .editMedicationPlan(let planID, let petID):
            MedicationPlanEditSheet(planID: planID, petID: petID)
        case .logCycleObservation(let petID):
            CycleObservationLogSheet(petID: petID)
        case .startCyclePeriod(let petID):
            CyclePeriodStartSheet(petID: petID)
        case .logSymptom(let petID):
            SymptomLogSheet(petID: petID)
        case .logWeight(let petID):
            WeightLogSheet(petID: petID)
        case .editPet(let petID):
            PetEditSheet(petID: petID)
        case .settings:
            SettingsSheet()
        }
    }
}
