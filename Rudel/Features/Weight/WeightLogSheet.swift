import SwiftData
import SwiftUI

/// Gewicht erfassen (PRD §5.5).
///
/// Das Feld ist mit dem letzten Gewicht vorbelegt und hat den Fokus: beim Wiegen
/// ändert sich meist nur die zweite Stelle, also ist Löschen-und-Neutippen der
/// falsche Weg. Wer nur den Vorschlag bestätigen will, tippt einmal auf
/// Speichern (PRD §2).
struct WeightLogSheet: View {
    let petID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Das Sheet bekommt nur die ID und löst das Tier selbst auf (siehe
    /// `AppState.Sheet`).
    @Query(sort: \Pet.createdAt) private var pets: [Pet]

    @State private var weightText = ""
    @State private var date = Date()
    @State private var bodyConditionScore: BodyConditionScore?
    @State private var foodText = ""
    @State private var note = ""
    @State private var didPrefill = false
    @State private var saveCount = 0

    @FocusState private var weightFieldFocused: Bool

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
            .navigationTitle("Gewicht erfassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(parsedWeight == nil)
                }
            }
            .task { prefill() }
            .sensoryFeedback(.success, trigger: saveCount)
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Gewicht", text: $weightText)
                        .keyboardType(.decimalPad)
                        .focused($weightFieldFocused)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .accessibilityLabel("Gewicht in Kilogramm")
                    Text("kg")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                DatePicker(
                    "Datum",
                    selection: $date,
                    in: ...Date(),
                    displayedComponents: .date
                )
            } footer: {
                if let previous = lastEntry {
                    Text("Zuletzt \(Format.weight(previous.valueKg)) am \(Format.date(previous.date)).")
                } else {
                    Text("Der erste Wert. Ab dem zweiten zeigt Rudel den Verlauf.")
                }
            }

            Section {
                Picker("Körperkondition", selection: $bodyConditionScore) {
                    Text("Nicht erfasst").tag(BodyConditionScore?.none)
                    ForEach(BodyConditionScore.allCases, id: \.self) { score in
                        Text(score.label).tag(Optional(score))
                    }
                }

                HStack {
                    TextField("Futter pro Tag", text: $foodText)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Futtermenge pro Tag in Gramm")
                    Text("g")
                        .foregroundStyle(.secondary)
                }

                TextField("Notiz", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text("Optional")
            } footer: {
                Text("Die Körperkondition folgt der 9-Punkte-Skala (WSAVA); 5 heißt idealgewichtig.")
            }
        }
    }

    // MARK: Daten

    private var pet: Pet? {
        pets.first { $0.id == petID }
    }

    private var lastEntry: WeightEntry? {
        pet?.weightEntries.max(by: { $0.date < $1.date })
    }

    /// Eingabe als Zahl. Das Komma wird mitgelesen: die Dezimal-Tastatur zeigt
    /// im deutschen Gebietsschema ein Komma, `Double(_:)` versteht aber nur den
    /// Punkt. Tausendertrennzeichen sind kein Thema — kein Haustier wiegt vier
    /// Stellen.
    private var parsedWeight: Double? {
        let normalized = weightText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0, value < 200 else { return nil }
        return value
    }

    private var parsedFoodGrams: Double? {
        let normalized = foodText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    // MARK: Aktionen

    /// Vorbelegung mit dem letzten Gewicht. Nur einmal, sonst würde jede
    /// Neuberechnung der View die Eingabe überschreiben.
    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let previous = lastEntry, previous.valueKg > 0 {
            // Lokalisiert formatiert, damit im Feld dasselbe Trennzeichen steht,
            // das die Tastatur anbietet.
            weightText = previous.valueKg.formatted(.number.precision(.fractionLength(0...2)))
        }
        weightFieldFocused = true
    }

    private func save() {
        guard let pet, let valueKg = parsedWeight else { return }

        let entry = WeightEntry(
            date: appState.dayMath.startOfDay(date),
            valueKg: valueKg,
            bodyConditionScore: bodyConditionScore,
            foodAmountGrams: parsedFoodGrams,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        context.insert(entry)
        entry.pet = pet
        try? context.save()

        saveCount += 1
        dismiss()
    }
}
