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
    @Query private var vetAppointments: [VetAppointment]
    @Query private var vetPractices: [VetPractice]
    @Query private var settingsRecords: [AppSettings]

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
        .onOpenURL { url in
            guard let id = MedicationAlarmLink.reminderID(from: url) else { return }
            appState.present(.medicationReminder(reminderID: id))
        }
        .safeAreaInset(edge: .top) {
            if let issue = MedicationAlarmService.shared.issue {
                Button { appState.present(.settings) } label: {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .foregroundStyle(.orange).background(.regularMaterial)
            }
        }
        .sheet(item: sheetBinding) { sheet in
            SheetPresenter(sheet: sheet)
                .tint(RudelTheme.accent)
                .presentationCornerRadius(28)
        }
        .tint(RudelTheme.accent)
    }

    /// Ändert sich genau dann, wenn sich am geplanten Benachrichtigungs-Satz
    /// etwas ändern kann.
    ///
    /// Die Zähler decken jeden Log ab: das Journal ist append-only (PRD §8), eine
    /// neue Gabe oder Beobachtung ist also immer ein neuer Datensatz. Das gilt
    /// auch für Auslassungen — `outcomeValue` und `wasSkipped` stehen beim
    /// Anlegen fest. Für die Felder, die Erinnerungen beeinflussen **ohne**
    /// einen Datensatz anzulegen — abgesetzter Plan, geändertes Dosierschema,
    /// Zurückstellung, verschobener oder abgeschlossener Termin, erfasstes Ende
    /// der sichtbaren Hitze, Impfung, Vorrat — fließen die Werte selbst ein.
    private var notificationFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(medicationEvents.count)
        hasher.combine(doseLogs.count)
        hasher.combine(cycleObservations.count)
        for plan in medicationPlans {
            hasher.combine(plan.id)
            hasher.combine(plan.pet?.id)
            hasher.combine(plan.kindValue)
            hasher.combine(plan.productName)
            hasher.combine(plan.doseLabel)
            hasher.combine(plan.doseStartDate)
            hasher.combine(plan.isActive)
            hasher.combine(plan.intervalDays)
            hasher.combine(plan.effectiveDays)
            hasher.combine(plan.doseTimesMinutes)
            hasher.combine(plan.doseEveryNDays)
            hasher.combine(plan.doseEndDate)
            hasher.combine(plan.careClassOverride)
            hasher.combine(plan.requiresVetVisitOverride)
            hasher.combine(plan.deferredUntil)
            hasher.combine(plan.deferredAt)
            hasher.combine(plan.vaccineValue)
            // Vorrat: Zählung und Parameter. Die Gaben seit der Zählung stecken
            // schon in den Zählern oben.
            hasher.combine(plan.stockCountedAt)
            hasher.combine(plan.stockAmount)
            hasher.combine(plan.stockUnit)
            hasher.combine(plan.amountPerGiving)
            hasher.combine(plan.restockLeadDays)
            hasher.combine(plan.needsPrescription)
        }
        for appointment in vetAppointments {
            hasher.combine(appointment.id)
            hasher.combine(appointment.date)
            hasher.combine(appointment.statusValue)
            hasher.combine(appointment.title)
            hasher.combine(appointment.reasonValue)
            hasher.combine(appointment.pet?.id)
            hasher.combine(appointment.practice?.id)
            hasher.combine(appointment.practice?.name)
            hasher.combine(appointment.medicationPlan?.id)
        }
        // Der Praxisname steht im Mitteilungstext eines Termins.
        for practice in vetPractices {
            hasher.combine(practice.id)
            hasher.combine(practice.name)
        }
        for pet in pets {
            hasher.combine(pet.id)
            hasher.combine(pet.name)
        }
        for settings in settingsRecords {
            hasher.combine(settings.notificationsEnabled)
            hasher.combine(settings.medicationAlarmsEnabled)
            hasher.combine(settings.medicationLeadMinutes)
            hasher.combine(settings.medicationSnoozeMinutes)
            hasher.combine(settings.leadDays)
            hasher.combine(settings.reminderMinutesFromMidnight)
            hasher.combine(settings.notificationHorizonDays)
            hasher.combine(settings.appointmentLeadMinutes)
            hasher.combine(settings.criticalDayRemindersEnabled)
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
        // Auch das Löschen des letzten Tiers muss bestehende Alarme entfernen.
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
        .toolbarBackground(RudelTheme.canvas, for: .tabBar)
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
        case .quickLogMedication(let petID, let planID):
            QuickLogMedicationSheet(petID: petID, initialPlanID: planID)
        case .medicationReminder(let reminderID):
            MedicationReminderConfirmationSheet(reminderID: reminderID)
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
        case .deferMedication(let planID):
            MedicationDeferSheet(planID: planID)
        case .restockMedication(let planID):
            MedicationRestockSheet(planID: planID)
        case .editAppointment(let appointmentID, let petID, let planID):
            VetAppointmentEditSheet(appointmentID: appointmentID, petID: petID, planID: planID)
        case .editPractice(let practiceID):
            VetPracticeEditSheet(practiceID: practiceID)
        case .settings:
            SettingsSheet()
        }
    }
}
