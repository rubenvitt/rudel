import RudelEngine
import SwiftData
import SwiftUI

/// Termin anlegen, bearbeiten und abschließen. `appointmentID == nil` ⇒ neuer
/// Termin, optional vorbelegt mit einer Vorsorge (`planID`), etwa aus
/// „Tierarzttermin vereinbaren" auf Heute.
///
/// Bearbeitet wird auf lokalen Kopien wie in `MedicationPlanEditSheet`:
/// SwiftData schreibt Änderungen am Objekt auch ohne `save()` zurück, und
/// „Abbrechen" soll nichts übernehmen.
struct VetAppointmentEditSheet: View {
    let appointmentID: UUID?
    let petID: UUID
    let planID: UUID?

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \VetPractice.name) private var practices: [VetPractice]

    @State private var pet: Pet?
    @State private var appointment: VetAppointment?
    @State private var didLoad = false
    @State private var isConfirmingDeletion = false

    @State private var date = Date()
    @State private var reason: VetVisitReason = .checkup
    @State private var title = ""
    @State private var practiceID: UUID?
    @State private var linkedPlanID: UUID?
    @State private var preparationNotes = ""
    @State private var findings = ""
    @State private var costText = ""
    @State private var status: AppointmentStatus = .planned
    /// Status beim Öffnen. Die Gabe am Termintag wird nur beim Abschließen
    /// vorgeschlagen — wer später einen Befund nachträgt, soll nicht nebenbei
    /// eine zweite Gabe erzeugen.
    @State private var originalStatus: AppointmentStatus = .planned
    @State private var documentsTreatment = false
    @State private var isCreatingPractice = false
    @State private var isShowingCalendar = false

    private var isNew: Bool { appointmentID == nil }

    private var parsedCost: EuroField { VetDisplay.parseEuro(costText) }

    private var canSave: Bool {
        guard pet != nil || appointment != nil else { return false }
        return !parsedCost.isInvalid
    }

    var body: some View {
        NavigationStack {
            Group {
                if didLoad {
                    form
                } else {
                    Color.clear
                }
            }
            .sheet(isPresented: $isShowingCalendar) {
                VetCalendarEditor(draft: calendarDraft) { saved in
                    if saved { markCalendarExported() }
                    isShowingCalendar = false
                }
                .ignoresSafeArea()
            }
            .rudelFormStyle()
            .navigationTitle("Termin")
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
            .task { load() }
            .sheet(isPresented: $isCreatingPractice) {
                VetPracticeEditSheet(practiceID: nil, petForPrimary: pet) { created in
                    practiceID = created.id
                }
            }
            .onChange(of: linkedPlanID) { oldValue, newValue in
                applyPlanPreset(from: oldValue, to: newValue)
            }
            .confirmationDialog(
                "Termin löschen?",
                isPresented: $isConfirmingDeletion,
                titleVisibility: .visible
            ) {
                Button("Termin löschen", role: .destructive) { delete() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Befund und Kosten gehen mit verloren. Ein abgesagter Termin kann auch einfach im Verlauf bleiben.")
            }
        }
    }

    // MARK: - Formular

    private var form: some View {
        Form {
            whenSection
            whatSection
            linkSection
            preparationSection
            if !isNew {
                statusSection
                if status == .done {
                    resultSection
                }
            }
            // Nach Status und Ergebnis: Abschließen ist beim Öffnen eines
            // Termins die häufigere Handlung als Teilen.
            shareSection
            if !isNew {
                deleteSection
            }
        }
    }

    private var whenSection: some View {
        Section {
            DatePicker("Datum", selection: $date, displayedComponents: [.date, .hourAndMinute])
        }
    }

    private var whatSection: some View {
        Section {
            Picker("Anlass", selection: $reason) {
                ForEach(VetVisitReason.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.symbolName).tag(option)
                }
            }
            TextField("Titel", text: $title, prompt: Text(reason.label))
                .textInputAutocapitalization(.sentences)
                .accessibilityLabel("Titel")
                .accessibilityIdentifier("appointment-title")
        }
    }

    private var linkSection: some View {
        Section {
            Picker("Praxis", selection: $practiceID) {
                Text("Keine").tag(nil as UUID?)
                ForEach(practices) { practice in
                    Text(VetDisplay.practiceName(practice)).tag(Optional(practice.id))
                }
            }
            .accessibilityIdentifier("appointment-practice")

            Button {
                isCreatingPractice = true
            } label: {
                Label("Neue Praxis …", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("appointment-new-practice")

            if !planOptions.isEmpty {
                Picker("Vorsorge", selection: $linkedPlanID) {
                    Text("Keine").tag(nil as UUID?)
                    ForEach(planOptions) { plan in
                        Text(MedicationDisplay.title(for: plan)).tag(Optional(plan.id))
                    }
                }
            }
        } footer: {
            if linkedPlanID != nil {
                Text("Solange der Termin geplant ist, übernimmt er die Erinnerung der Vorsorge.")
            }
        }
    }

    private var preparationSection: some View {
        Section("Vorbereitung / Fragen") {
            TextField("Was ansprechen?", text: $preparationNotes, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    /// Bericht und Kalender arbeiten mit dem Stand im Formular, nicht mit dem
    /// gespeicherten — gerade notierte Fragen sollen schon mitgehen.
    @ViewBuilder
    private var shareSection: some View {
        if let pet {
            Section {
                VetReportShareLink(
                    petID: pet.id,
                    petName: pet.name,
                    occasion: currentOccasion,
                    title: "Bericht für diesen Termin",
                    accessibilityID: "appointment-report-share"
                )
                calendarRows
            }
        }
    }

    /// Nur für gespeicherte, geplante Termine: der Exportzeitpunkt hängt am
    /// Termin, und ein erledigter Termin gehört nicht mehr in den Kalender.
    @ViewBuilder
    private var calendarRows: some View {
        if let appointment, appointment.statusValue == .planned, status == .planned {
            if appointment.calendarExportedAt != nil {
                if appointment.calendarEntryIsStale(comparedTo: date),
                   let exported = appointment.calendarExportedDate {
                    Label {
                        Text("Der Kalendereintrag steht noch auf \(Format.dateTime(exported)) und wandert nicht mit.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(RudelTheme.warning)
                    }
                    .accessibilityIdentifier("appointment-calendar-stale")
                    calendarButton(title: "Erneut in Kalender übernehmen")
                } else {
                    Label("Im Kalender eingetragen", systemImage: "calendar.badge.checkmark")
                        .foregroundStyle(RudelTheme.success)
                        .accessibilityIdentifier("appointment-calendar-exported")
                }
            } else {
                calendarButton(title: "In Kalender übernehmen")
            }
        }
    }

    private func calendarButton(title: String) -> some View {
        Button {
            isShowingCalendar = true
        } label: {
            Label(title, systemImage: "calendar.badge.plus")
        }
        .accessibilityIdentifier("appointment-add-to-calendar")
    }

    private var currentOccasion: VetReportContent.Occasion {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return VetReportContent.Occasion(
            appointmentID: appointmentID,
            title: trimmedTitle.isEmpty ? reason.label : trimmedTitle,
            date: date,
            practiceName: selectedPractice.map(VetDisplay.practiceName),
            questions: preparationNotes
        )
    }

    private var selectedPractice: VetPractice? {
        practiceID.flatMap { id in practices.first { $0.id == id } }
    }

    private var calendarDraft: VetCalendarDraft {
        VetCalendarDraft(
            petName: pet?.name ?? "",
            appointmentTitle: currentOccasion.title,
            start: date,
            practice: selectedPractice,
            questions: preparationNotes
        )
    }

    /// Nur die Exportfelder schreiben: die übrigen Eingaben liegen in lokalen
    /// Kopien und bleiben bis „Speichern" unangetastet.
    private func markCalendarExported() {
        guard let appointment else { return }
        appointment.calendarExportedAt = Date()
        appointment.calendarExportedDate = date
        try? context.save()
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch status {
            case .planned:
                Button {
                    markDone()
                } label: {
                    Label("Als erledigt markieren", systemImage: "checkmark.circle")
                }
                Button(role: .destructive) {
                    cancelAppointment()
                } label: {
                    Label("Termin absagen", systemImage: "xmark.circle")
                }
            case .done:
                LabeledValueRow(label: "Status", value: AppointmentStatus.done.label, systemImage: "checkmark.circle.fill")
                Button("Doch noch offen") { status = .planned }
            case .cancelled:
                LabeledValueRow(label: "Status", value: AppointmentStatus.cancelled.label, systemImage: "xmark.circle")
                Button("Wieder als geplant führen") { status = .planned }
            }
        } header: {
            Text("Status")
        }
    }

    private var resultSection: some View {
        Section {
            TextField("Befund", text: $findings, prompt: Text("Befund, Diagnose, Empfehlung"), axis: .vertical)
                .lineLimit(2...8)
                .accessibilityLabel("Befund")
                .accessibilityIdentifier("appointment-findings")
            HStack {
                Text("Kosten")
                TextField("Kosten", text: $costText, prompt: Text("0,00"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Kosten in Euro")
                    .accessibilityIdentifier("appointment-cost")
                Text("€").foregroundStyle(.secondary)
            }
            treatmentRow
        } header: {
            Text("Ergebnis")
        } footer: {
            if parsedCost.isInvalid {
                Text("Bitte einen Betrag eingeben, z. B. 45,50.")
                    .foregroundStyle(RudelTheme.danger)
            }
        }
    }

    /// Nur mit verknüpfter Vorsorge. Gibt es am Termintag schon eine Gabe,
    /// bleibt es bei einem Hinweis — eine zweite würde die Historie doppeln.
    @ViewBuilder
    private var treatmentRow: some View {
        if let plan = linkedPlan {
            if hasGivenEvent(plan, on: date) {
                Label("Gabe am Termintag ist dokumentiert", systemImage: "checkmark.seal")
                    .foregroundStyle(RudelTheme.success)
            } else {
                Toggle("Behandlung erfolgt: Gabe am Termintag dokumentieren", isOn: $documentsTreatment)
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Termin löschen", role: .destructive) {
                isConfirmingDeletion = true
            }
        }
    }

    // MARK: - Abgeleitete Werte

    /// Aktive Vorsorge des Tiers; Dauermedikamente haben keinen Terminbezug.
    /// Der aktuell verknüpfte Plan steht immer drin, auch wenn er abgesetzt
    /// ist — sonst zeigte der Picker eine Auswahl ohne passenden Eintrag.
    private var planOptions: [MedicationPlan] {
        let plans = pet?.medicationPlans ?? appointment?.pet?.medicationPlans ?? []
        return plans
            .filter { ($0.isActive && $0.kindValue != .ongoing) || $0.id == linkedPlanID }
            .sorted { MedicationDisplay.title(for: $0) < MedicationDisplay.title(for: $1) }
    }

    private var linkedPlan: MedicationPlan? {
        guard let linkedPlanID else { return nil }
        return planOptions.first { $0.id == linkedPlanID }
    }

    private func hasGivenEvent(_ plan: MedicationPlan, on day: Date) -> Bool {
        let dayMath = appState.dayMath
        return plan.events.contains {
            $0.outcomeValue == .given && dayMath.isSameDay($0.givenOn, day)
        }
    }

    // MARK: - Laden

    private func load() {
        guard !didLoad else { return }
        defer { didLoad = true }

        let targetPet = petID
        var petDescriptor = FetchDescriptor<Pet>(predicate: #Predicate<Pet> { $0.id == targetPet })
        petDescriptor.fetchLimit = 1
        pet = (try? context.fetch(petDescriptor))?.first

        guard let appointmentID else {
            date = defaultDate()
            practiceID = pet?.primaryPractice?.id
            // Die Vorbelegung direkt setzen: `onChange` läuft erst nach dem
            // Laden und lässt einen bereits passenden Titel stehen.
            linkedPlanID = planID
            if let planID, let plan = pet?.medicationPlans.first(where: { $0.id == planID }) {
                applyPreset(for: plan)
            }
            return
        }

        var descriptor = FetchDescriptor<VetAppointment>(
            predicate: #Predicate<VetAppointment> { $0.id == appointmentID }
        )
        descriptor.fetchLimit = 1
        guard let existing = (try? context.fetch(descriptor))?.first else {
            // Unter uns gelöscht — schließen statt einen neuen anzulegen.
            dismiss()
            return
        }
        appointment = existing
        if pet == nil { pet = existing.pet }
        date = existing.date
        reason = existing.reasonValue
        title = existing.title
        practiceID = existing.practice?.id
        linkedPlanID = existing.medicationPlan?.id
        preparationNotes = existing.preparationNotes
        findings = existing.findings
        costText = VetDisplay.euroText(existing.costEuro)
        status = existing.statusValue
        originalStatus = existing.statusValue
    }

    /// Morgen um 9 Uhr — ein Termin für heute ist selten, und eine runde
    /// Uhrzeit spart das Drehen am Rad.
    private func defaultDate() -> Date {
        let dayMath = appState.dayMath
        let tomorrow = dayMath.adding(days: 1, to: dayMath.startOfDay(Date()))
        return dayMath.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Impfungen bekommen den Anlass „Impfung"; der Titel nennt Impfung bzw.
    /// Präparat, damit der Termin auf Heute und in Mitteilungen erkennbar ist.
    private func applyPreset(for plan: MedicationPlan) {
        if plan.kindValue.isVaccination { reason = .vaccination }
        title = MedicationDisplay.title(for: plan)
    }

    /// Wechsel der Vorsorge bei einem neuen Termin: den Titel nur nachziehen,
    /// solange er noch der Vorschlag des vorherigen Plans ist — Eigenes bleibt.
    private func applyPlanPreset(from oldID: UUID?, to newID: UUID?) {
        guard didLoad, isNew else { return }
        let options = planOptions
        let previousTitle = oldID.flatMap { id in options.first { $0.id == id } }.map(MedicationDisplay.title(for:))
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == previousTitle else { return }
        if let newID, let plan = options.first(where: { $0.id == newID }) {
            applyPreset(for: plan)
        } else {
            title = ""
        }
    }

    // MARK: - Status

    private func markDone() {
        status = .done
        // Behandlung erfolgt ist der Normalfall eines Vorsorge-Termins.
        if originalStatus != .done { documentsTreatment = true }
    }

    /// Absagen wirkt sofort, wie „Medikament absetzen": man will den Termin
    /// loswerden, nicht noch ein Formular bestätigen. Andere ungespeicherte
    /// Änderungen werden dabei nicht übernommen.
    private func cancelAppointment() {
        guard let appointment else { return }
        appointment.statusValue = .cancelled
        try? context.save()
        dismiss()
    }

    // MARK: - Speichern

    private func save() {
        guard canSave else { return }

        let target: VetAppointment
        if let appointment {
            target = appointment
        } else {
            let created = VetAppointment(date: date, createdAt: Date())
            context.insert(created)
            // Beziehung über `appointment.pet` — das `inverse:` steht am Tier.
            created.pet = pet
            appointment = created
            target = created
        }

        target.date = date
        target.reasonValue = reason
        target.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.practice = selectedPractice
        target.medicationPlan = linkedPlan
        target.preparationNotes = preparationNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        target.statusValue = status
        target.findings = findings.trimmingCharacters(in: .whitespacesAndNewlines)
        target.costEuro = parsedCost.amount

        if status == .done, documentsTreatment, let plan = linkedPlan, !hasGivenEvent(plan, on: date) {
            let event = MedicationEvent(givenOn: appState.dayMath.startOfDay(date), loggedAt: Date())
            context.insert(event)
            event.plan = plan
        }

        try? context.save()
        dismiss()
    }

    /// Erst den Zustand leeren, dann löschen: der Body wird beim Schließen des
    /// Dialogs noch einmal gezeichnet und darf dabei kein gelöschtes Modell
    /// lesen (gleiche Falle wie im Praxis-Sheet).
    private func delete() {
        guard let target = appointment else { return }
        appointment = nil
        context.delete(target)
        try? context.save()
        dismiss()
    }
}
