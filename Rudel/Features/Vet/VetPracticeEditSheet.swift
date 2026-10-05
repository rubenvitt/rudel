import SwiftData
import SwiftUI

/// Praxis anlegen oder bearbeiten. `practiceID == nil` ⇒ neue Praxis.
///
/// Bearbeitet wird auf lokalen Kopien wie in `MedicationPlanEditSheet`, damit
/// „Abbrechen" tatsächlich nichts übernimmt.
///
/// Aus dem Termin-Formular heraus kommt `onCreate` mit: die neue Praxis wird
/// dort direkt ausgewählt. `petForPrimary` bietet in diesem Einstieg an, die
/// Praxis als Haustierarzt des Tiers zu setzen, solange es keinen hat.
struct VetPracticeEditSheet: View {
    let practiceID: UUID?
    var petForPrimary: Pet?
    var onCreate: ((VetPractice) -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var practice: VetPractice?
    @State private var didLoad = false
    /// Text des Löschdialogs als Momentaufnahme: der Dialog kann nach
    /// `context.delete` noch einmal gezeichnet werden, und das gelöschte Modell
    /// darf dann nicht mehr gelesen werden (siehe `PetDeletionSummary`).
    @State private var pendingDeletionMessage: String?

    @State private var name = ""
    @State private var veterinarian = ""
    @State private var phone = ""
    @State private var emergencyPhone = ""
    @State private var email = ""
    @State private var address = ""
    @State private var openingHours = ""
    @State private var isEmergencyClinic = false
    @State private var notes = ""
    /// Standard an: wer aus einem Termin heraus die erste Praxis anlegt, legt
    /// fast immer den eigenen Tierarzt an.
    @State private var setsAsPrimary = true

    @FocusState private var nameFocused: Bool

    private var isNew: Bool { practiceID == nil }

    /// Nur beim Anlegen und nur, wenn das Tier noch keinen Haustierarzt hat —
    /// einen bestehenden still zu ersetzen wäre eine Überraschung.
    private var offersPrimary: Bool {
        guard isNew, let petForPrimary else { return false }
        return petForPrimary.primaryPractice == nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .rudelFormStyle()
            .navigationTitle("Praxis")
            .navigationBarTitleDisplayMode(.inline)
            .defaultFocus($nameFocused, isNew)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .task { load() }
            .confirmationDialog(
                "Praxis löschen?",
                isPresented: deletionDialogBinding,
                titleVisibility: .visible,
                presenting: pendingDeletionMessage
            ) { _ in
                Button("Praxis löschen", role: .destructive) { delete() }
                Button("Abbrechen", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    // MARK: - Formular

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("z. B. Tierarztpraxis am Park"))
                    .focused($nameFocused)
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("Name der Praxis")
                    .accessibilityIdentifier("practice-name")
                TextField("Tierärztin / Tierarzt", text: $veterinarian, prompt: Text("Tierärztin / Tierarzt"))
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("Tierärztin oder Tierarzt")
            } footer: {
                if trimmedName.isEmpty {
                    Text("Der Name ist Pflicht.")
                }
            }

            Section("Kontakt") {
                TextField("Telefon", text: $phone, prompt: Text("Telefon"))
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .accessibilityLabel("Telefon")
                    .accessibilityIdentifier("practice-phone")
                TextField("Notfallnummer", text: $emergencyPhone, prompt: Text("Notfallnummer"))
                    .keyboardType(.phonePad)
                    .accessibilityLabel("Notfallnummer")
                TextField("E-Mail", text: $email, prompt: Text("E-Mail"))
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("E-Mail")
                TextField("Adresse", text: $address, prompt: Text("Adresse"), axis: .vertical)
                    .textContentType(.fullStreetAddress)
                    .lineLimit(1...3)
                    .accessibilityLabel("Adresse")
                TextField("Sprechzeiten", text: $openingHours, prompt: Text("Sprechzeiten"), axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityLabel("Sprechzeiten")
            }

            if offersPrimary, let petForPrimary {
                Section {
                    Toggle(
                        "Haustierarzt von \(petForPrimary.name.isEmpty ? "deinem Tier" : petForPrimary.name)",
                        isOn: $setsAsPrimary
                    )
                    .accessibilityIdentifier("practice-set-primary")
                }
            }

            Section {
                Toggle("Notfallklinik / Notdienst", isOn: $isEmergencyClinic)
            } footer: {
                Text("Notfallpraxen stehen im Profil jedes Tiers unter „Notfall“.")
            }

            Section("Notizen") {
                TextField("Notiz", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }

            if !isNew {
                Section {
                    Button("Praxis löschen", role: .destructive) {
                        pendingDeletionMessage = makeDeletionMessage()
                    }
                }
            }
        }
    }

    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionMessage != nil },
            set: { if !$0 { pendingDeletionMessage = nil } }
        )
    }

    private func makeDeletionMessage() -> String {
        let count = practice?.appointments.count ?? 0
        guard count > 0 else { return "Das lässt sich nicht rückgängig machen." }
        let terms = count == 1 ? "Der Termin bleibt" : "Die \(count) Termine bleiben"
        return "\(terms) im Verlauf erhalten, nur ohne Praxisangabe."
    }

    // MARK: - Laden und Speichern

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let practiceID else { return }

        var descriptor = FetchDescriptor<VetPractice>(
            predicate: #Predicate<VetPractice> { $0.id == practiceID }
        )
        descriptor.fetchLimit = 1
        guard let existing = (try? context.fetch(descriptor))?.first else {
            // Unter uns gelöscht — schließen statt eine Kopie anzulegen.
            dismiss()
            return
        }
        practice = existing
        name = existing.name
        veterinarian = existing.veterinarian
        phone = existing.phone
        emergencyPhone = existing.emergencyPhone
        email = existing.email
        address = existing.address
        openingHours = existing.openingHours
        isEmergencyClinic = existing.isEmergencyClinic
        notes = existing.notes
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }

        let target: VetPractice
        var created: VetPractice?
        if let practice {
            target = practice
        } else {
            let new = VetPractice()
            context.insert(new)
            practice = new
            target = new
            created = new
        }

        target.name = trimmedName
        target.veterinarian = trimmed(veterinarian)
        target.phone = trimmed(phone)
        target.emergencyPhone = trimmed(emergencyPhone)
        target.email = trimmed(email)
        target.address = trimmed(address)
        target.openingHours = trimmed(openingHours)
        target.isEmergencyClinic = isEmergencyClinic
        target.notes = trimmed(notes)

        if offersPrimary, setsAsPrimary, let petForPrimary {
            // Beziehung über das Tier — `inverse:` steht an der Praxis.
            petForPrimary.primaryPractice = target
        }

        try? context.save()
        if let created { onCreate?(created) }
        dismiss()
    }

    /// Termine und Tiere verweisen mit `nullify` auf die Praxis: die Historie
    /// bleibt, nur die Praxisangabe fällt weg.
    private func delete() {
        guard let practice else { return }
        context.delete(practice)
        try? context.save()
        dismiss()
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
