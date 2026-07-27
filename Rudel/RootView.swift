import RudelEngine
import SwiftData
import SwiftUI

/// Wurzel der App: Tab-Navigation plus zentrale Sheet-Präsentation.
///
/// Der Tier-Umschalter sitzt in jedem Tab im Kopfbereich (PRD §5.1), nicht
/// hier — so bleibt er dort sichtbar, wo gerade gearbeitet wird.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \Pet.createdAt) private var pets: [Pet]

    // Für die Neuplanung der Benachrichtigungen, siehe `notificationFingerprint`.
    @Query private var medicationPlans: [MedicationPlan]
    @Query private var medicationEvents: [MedicationEvent]
    @Query private var doseLogs: [DoseLogEntry]
    @Query private var cyclePeriods: [CyclePeriod]
    @Query private var cycleObservations: [CycleObservation]

    private let notificationService = NotificationService()

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
        // Zwei Auslöser, weil das Benachrichtigungs-Fenster rollierend ist
        // (siehe `NotificationPlanner`): beim Wechsel in den Vordergrund rückt es
        // vor, nach einem Log ändert sich sein Inhalt.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refreshNotifications()
        }
        .task(id: notificationFingerprint) {
            await refreshNotifications()
        }
        .sheet(item: sheetBinding) { sheet in
            SheetPresenter(sheet: sheet)
        }
    }

    /// Ändert sich genau dann, wenn sich am geplanten Benachrichtigungs-Satz
    /// etwas ändern kann.
    ///
    /// Die Zähler decken jeden Log ab: das Journal ist append-only (PRD §8), eine
    /// neue Gabe oder Beobachtung ist also immer ein neuer Datensatz. Für die
    /// wenigen Felder, die Erinnerungen beeinflussen **ohne** einen Datensatz
    /// anzulegen — abgesetzter Plan, geändertes Dosierschema, erfasstes Ende der
    /// sichtbaren Hitze — fließen die Werte selbst ein.
    private var notificationFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(medicationEvents.count)
        hasher.combine(doseLogs.count)
        hasher.combine(cycleObservations.count)
        for plan in medicationPlans {
            hasher.combine(plan.isActive)
            hasher.combine(plan.intervalDays)
            hasher.combine(plan.effectiveDays)
            hasher.combine(plan.doseTimesMinutes)
            hasher.combine(plan.doseEveryNDays)
            hasher.combine(plan.doseEndDate)
        }
        for period in cyclePeriods {
            hasher.combine(period.day1Date)
            hasher.combine(period.visibleHeatEndDate)
        }
        return hasher.finalize()
    }

    /// Setzt die Benachrichtigungen neu.
    ///
    /// Ohne diesen Aufruf lieferte die App nur Erinnerungen für das Fenster, das
    /// beim letzten Öffnen der Einstellungen geplant wurde — bei einer laufenden
    /// Läufigkeit hieße das Hinweise für die ersten zwei Wochen und danach
    /// Schweigen, ausgerechnet in der Phase mit der höchsten Priorität.
    private func refreshNotifications() async {
        guard !pets.isEmpty else { return }
        let settings = AppSettings.loadOrCreate(in: modelContext)
        await notificationService.reschedule(context: modelContext, settings: settings)
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
