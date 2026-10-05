import PhotosUI
import RudelEngine
import SwiftData
import SwiftUI

/// Symptom erfassen (PRD §5.4).
///
/// Der Screen ist auf zwei Taps ausgelegt (PRD §2): Symptomtyp antippen,
/// speichern. Alles andere ist vorbelegt — Datum auf heute, Schweregrad auf die
/// niedrigste Stufe, und der Typ auf den zuletzt erfassten. Bei einer
/// wiederkehrenden Ohrenentzündung ist der Eintrag damit ein einziger Tap.
struct SymptomLogSheet: View {
    let petID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Das Tier wird selbst aufgelöst — ein Sheet bekommt nur die ID (siehe
    /// `AppState.Sheet`). Über `@Query` statt `#Predicate`, weil die Liste der
    /// Tiere einstellig ist und ein Prädikat hier nur Fehlerquellen hätte.
    @Query(sort: \Pet.createdAt) private var pets: [Pet]

    @State private var type: SymptomType?
    @State private var customType = ""
    @State private var severity: SymptomSeverity = .mild
    @State private var date = Date()
    @State private var note = ""
    @State private var linkedPlanID: UUID?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var isPreparingPhoto = false
    @State private var didPrefill = false
    @State private var saveCount = 0

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if pet == nil {
                    ContentUnavailableView(
                        "Tier nicht gefunden",
                        systemImage: "pawprint",
                        description: Text("Das Tier wurde inzwischen gelöscht.")
                    )
                } else {
                    form
                }
            }
            .rudelFormStyle()
            .navigationTitle("Symptom erfassen")
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
            .task { prefill() }
            .sensoryFeedback(.success, trigger: saveCount)
        }
    }

    private var form: some View {
        Form {
            Section("Was ist aufgefallen?") {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(SymptomType.quickPick, id: \.self) { candidate in
                        SymptomTypeChip(
                            symbolName: candidate.symbolName,
                            label: candidate.label,
                            isSelected: type == candidate
                        ) {
                            type = candidate
                        }
                    }
                    // `.other` steht bewusst als letzte Karte in derselben
                    // Auswahl: ein separater Schalter darunter wäre ein Tap mehr.
                    SymptomTypeChip(
                        symbolName: SymptomType.other.symbolName,
                        label: SymptomType.other.label,
                        isSelected: type == SymptomType.other
                    ) {
                        type = .other
                    }
                }
                .padding(.vertical, 6)

                if type == SymptomType.other {
                    TextField("Bezeichnung", text: $customType)
                        .textInputAutocapitalization(.sentences)
                }
            }

            Section {
                Picker("Schweregrad", selection: $severity) {
                    ForEach(SymptomSeverity.allCases, id: \.self) { step in
                        Text(step.label).tag(step)
                    }
                }
                .pickerStyle(.segmented)

                DatePicker(
                    "Datum",
                    selection: $date,
                    in: ...Date(),
                    displayedComponents: .date
                )
            }

            Section("Notiz") {
                TextField("Beobachtung, Auslöser, Verlauf", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }

            photoSection

            if !activePlans.isEmpty {
                Section {
                    Picker("Behandlung", selection: $linkedPlanID) {
                        Text("Keine").tag(UUID?.none)
                        ForEach(activePlans) { plan in
                            Text(planName(plan)).tag(Optional(plan.id))
                        }
                    }
                } footer: {
                    Text("Verknüpft die Beobachtung mit einer laufenden Behandlung — so ist später nachvollziehbar, ob sie gewirkt hat.")
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            loadPhoto(item)
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        Section("Foto") {
            if let photoData, let image = UIImage(data: photoData) {
                HStack(spacing: 12) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 10))
                        .accessibilityLabel("Gewähltes Foto")
                    Spacer()
                    Button("Entfernen", role: .destructive) {
                        self.photoData = nil
                        photoItem = nil
                    }
                }
            }

            // Beschriftung bewusst konstant: der Label-Closure von `PhotosPicker`
            // ist `@Sendable`, ein Zugriff auf `photoData` darin wäre ein
            // Isolationsverstoß. Ob schon ein Foto gewählt ist, zeigt die
            // Vorschau darüber.
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                Label("Foto auswählen", systemImage: "photo.badge.plus")
            }

            if isPreparingPhoto {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Foto wird verkleinert …")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Daten

    private var pet: Pet? {
        pets.first { $0.id == petID }
    }

    /// Nur laufende Behandlungen — ein abgesetztes Medikament als Verknüpfung
    /// anzubieten würde die Auswahl mit Historie zumüllen.
    private var activePlans: [MedicationPlan] {
        (pet?.medicationPlans ?? [])
            .filter(\.isActive)
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var trimmedCustomType: String {
        customType.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard let type else { return false }
        // Ein `.other`-Eintrag ohne Bezeichnung wäre in der Historie nicht
        // wiederzuerkennen und würde die Gruppierung sprengen.
        return type == .other ? !trimmedCustomType.isEmpty : true
    }

    private func planName(_ plan: MedicationPlan) -> String {
        plan.productName.isEmpty ? Format.label(plan.kindValue) : plan.productName
    }

    // MARK: Aktionen

    /// Vorbelegung aus der Historie. Läuft nur einmal — sonst würde jede
    /// Neuberechnung der View die Auswahl des Nutzers zurücksetzen.
    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let last = pet?.symptomEntries.max(by: { $0.loggedAt < $1.loggedAt }) else { return }
        type = last.typeValue
        if last.typeValue == .other {
            customType = last.customType
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isPreparingPhoto = true
        Task {
            let original = try? await item.loadTransferable(type: Data.self)
            // Verkleinern außerhalb des Main-Actors: ein 12-Megapixel-Bild aus
            // der Kamera blockiert sonst sichtbar die Oberfläche.
            let reduced = await Task.detached(priority: .userInitiated) {
                original.flatMap { SymptomPhoto.downscaledJPEG(from: $0) }
            }.value
            // Fällt die Verkleinerung aus (unbekanntes Format), lieber das
            // Original speichern als das Foto zu verlieren.
            photoData = reduced ?? original
            isPreparingPhoto = false
        }
    }

    private func save() {
        guard let pet, let type, canSave else { return }

        let entry = SymptomEntry(
            date: appState.dayMath.startOfDay(date),
            type: type,
            customType: type == .other ? trimmedCustomType : "",
            severity: severity,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            photoData: photoData
        )
        context.insert(entry)
        entry.pet = pet
        entry.linkedTreatment = activePlans.first { $0.id == linkedPlanID }
        try? context.save()

        saveCount += 1
        dismiss()
    }
}

/// Eine Karte der Schnellauswahl.
private struct SymptomTypeChip: View {
    let symbolName: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.title3)
                Text(label)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    // Kein `lineLimit`: bei großen Schriftgraden soll
                    // „Appetitlosigkeit" umbrechen und die Karte wachsen, nicht
                    // abgeschnitten werden. Der Skalierungsfaktor fängt nur den
                    // Fall ab, dass ein einzelnes Wort selbst dann nicht passt.
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color(.secondarySystemFill),
                in: .rect(cornerRadius: 12)
            )
            .overlay {
                // Rahmen zusätzlich zur Füllung: die Auswahl darf nicht allein
                // an der Farbe hängen, sonst ist sie bei „Farben umkehren" weg.
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
