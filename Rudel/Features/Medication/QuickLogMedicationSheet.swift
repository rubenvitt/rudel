import RudelEngine
import SwiftData
import SwiftUI

/// Eine Gabe erfassen (PRD §5.2, §2: „Erfassung in maximal zwei Taps").
///
/// Das Formular ist so vorbelegt, dass ein Tap auf „Speichern" reicht: Präparat
/// = der am längsten überfällige Plan, Datum = heute, alles andere optional.
/// Wer etwas anderes meint, korrigiert — wer den Normalfall meint, tippt einmal.
struct QuickLogMedicationSheet: View {
    let petID: UUID
    var initialPlanID: UUID? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Das Tier wird selbst geholt: Sheets bekommen nur die ID, damit sie nicht
    /// von der aufrufenden View abhängen.
    @State private var pet: Pet?
    @State private var selectedPlanID: UUID?
    @State private var givenOn = Date()
    @State private var note = ""
    @State private var productOverride = ""
    @State private var didPrepare = false
    @State private var selectedDoseAt: Date?
    @State private var errorMessage: String?

    private var now: Date { Date() }

    private var plans: [MedicationPlan] {
        guard let pet else { return [] }
        return MedicationDisplay.sortedActivePlans(of: pet, asOf: now, dayMath: appState.dayMath)
    }

    private var selectedPlan: MedicationPlan? {
        plans.first { $0.id == selectedPlanID }
    }

    private var doseOptions: [MedicationReminder] {
        guard let plan = selectedPlan, plan.kindValue == .ongoing else { return [] }
        return MedicationReminderPlanner(dayMath: appState.dayMath).plan(
            medications: [plan.engineInput()], loggedDoses: [plan.engineID: plan.doseLogs.map(\.scheduledAt)],
            reminderTime: TimeOfDay(hour: 9), horizonDays: 0, asOf: givenOn
        )
    }

    private var selectedDose: MedicationReminder? {
        doseOptions.first { $0.dueAt == selectedDoseAt } ?? doseOptions.first
    }

    private var canSave: Bool {
        guard let selectedPlan else { return false }
        return selectedPlan.kindValue != .ongoing || selectedDose != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if !didPrepare {
                    // Erste Zeichenrunde: `task` hat noch nicht geladen. Ohne
                    // diesen Zweig blitzt „Kein aktiver Plan" auf, obwohl Pläne
                    // existieren.
                    Color.clear
                } else if plans.isEmpty {
                    emptyState
                } else {
                    form
                }
            }
            .navigationTitle("Gabe erfassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(!canSave)
                }
            }
            .task { prepare() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Kein aktiver Plan", systemImage: "pills")
        } description: {
            Text("Lege im Tab „Medikamente“ zuerst einen Plan an — eine Gabe hängt immer an einem Plan, damit die Historie zusammenbleibt.")
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Präparat", selection: $selectedPlanID) {
                    ForEach(plans) { plan in
                        Text(MedicationDisplay.title(for: plan))
                            .tag(plan.id as UUID?)
                    }
                }
                .accessibilityIdentifier("medication-plan-selection")
                DatePicker(
                    "Datum",
                    selection: $givenOn,
                    in: ...now,
                    displayedComponents: .date
                )
                if selectedPlan?.kindValue == .ongoing {
                    if doseOptions.isEmpty {
                        Text("An diesem Tag gibt es keine offene Gabe.").foregroundStyle(.secondary)
                    } else {
                        Picker("Gabezeit", selection: Binding(
                            get: { selectedDose?.dueAt }, set: { selectedDoseAt = $0 }
                        )) {
                            ForEach(doseOptions) { dose in
                                Text(Format.time(dose.dueAt)).tag(dose.dueAt as Date?)
                            }
                        }
                        .accessibilityIdentifier("medication-dose-selection")
                    }
                }
            } footer: {
                if let plan = selectedPlan {
                    Text(MedicationDisplay.status(for: plan, asOf: now, dayMath: appState.dayMath).dueText)
                }
            }

            Section {
                if selectedPlan?.kindValue != .ongoing { TextField(
                    "Abweichendes Präparat",
                    text: $productOverride,
                    prompt: Text(selectedPlan.map { MedicationDisplay.title(for: $0) } ?? "wie im Plan")
                ) }
                TextField("Notiz", text: $note, axis: .vertical)
            } footer: {
                Text("Nur ausfüllen, wenn etwas anderes als im Plan gegeben wurde. Leer heißt: wie geplant.")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    // MARK: Vorbelegung

    /// Läuft genau einmal. Die Vorauswahl kommt aus derselben Sortierung wie die
    /// Liste, deshalb ist der erste Eintrag der am längsten überfällige.
    ///
    /// Rechnet mit dem lokal geholten Tier statt über `plans`: der `@State`-Wert
    /// ist erst im nächsten Zeichendurchlauf im Body sichtbar.
    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true

        let target = petID
        var descriptor = FetchDescriptor<Pet>(predicate: #Predicate<Pet> { $0.id == target })
        descriptor.fetchLimit = 1
        let fetched = (try? context.fetch(descriptor))?.first
        pet = fetched

        givenOn = appState.dayMath.startOfDay(Date())
        if let fetched {
            selectedPlanID = initialPlanID ?? MedicationDisplay
                .sortedActivePlans(of: fetched, asOf: Date(), dayMath: appState.dayMath)
                .first?.id
        }
    }

    // MARK: Speichern

    private func save() {
        guard let plan = selectedPlan else { return }
        if plan.kindValue == .ongoing {
            guard let dose = selectedDose else { return }
            let entry = DoseLogEntry(scheduledAt: dose.dueAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(entry)
            entry.plan = plan
            do { try context.save(); dismiss() }
            catch { context.delete(entry); errorMessage = error.localizedDescription }
            return
        }
        let event = MedicationEvent(
            givenOn: appState.dayMath.startOfDay(givenOn),
            productNameOverride: productOverride.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        context.insert(event)
        event.plan = plan
        do { try context.save(); dismiss() }
        catch { context.delete(event); errorMessage = error.localizedDescription }
    }
}
