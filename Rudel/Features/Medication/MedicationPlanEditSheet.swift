import RudelEngine
import SwiftData
import SwiftUI

/// Plan anlegen oder bearbeiten (PRD §5.2). `planID == nil` ⇒ neuer Plan.
///
/// Die Felder hängen an der Art: ein Zeckenschutz hat keine Gabezeiten, eine
/// Wurmkur keine Wirkdauer. Statt alles zu zeigen und die Hälfte grau zu machen,
/// zeigt das Formular nur, was die gewählte Art braucht.
///
/// Bearbeitet wird auf lokalen Kopien, nicht direkt am `@Model`. Sonst wäre
/// „Abbrechen" wirkungslos — SwiftData schreibt Änderungen am Objekt auch ohne
/// `save()` in den Kontext zurück.
struct MedicationPlanEditSheet: View {
    let planID: UUID?
    let petID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pet: Pet?
    @State private var plan: MedicationPlan?
    @State private var didLoad = false

    @State private var kind: MedicationKind = .dewormer
    @State private var productName = ""
    @State private var notes = ""
    @State private var isActive = true

    @State private var intervalDays = 90
    @State private var usesFecalSampleInstead = false
    @State private var effectiveDays = 30

    @State private var doseTimes: [DoseTimeDraft] = []
    @State private var doseEveryNDays = 1
    @State private var doseStartDate = Date()
    @State private var hasDoseEndDate = false
    @State private var doseEndDate = Date()
    @State private var doseLabel = ""

    private var isNew: Bool { planID == nil }

    /// Die Art nachträglich zu ändern würde die Historie umdeuten — eine
    /// Wurmkur-Gabe wäre plötzlich eine Impfung. Solange nichts dokumentiert ist,
    /// ist es dagegen bloß eine Korrektur.
    private var canChangeKind: Bool {
        guard let plan else { return true }
        return plan.events.isEmpty && plan.doseLogs.isEmpty
    }

    /// Ein Dauermedikament ohne Gabezeit hätte kein Dosierschema und damit keine
    /// Fälligkeit — das darf nicht speicherbar sein. Ohne Tier gäbe es keinen
    /// Besitzer, der Plan wäre unsichtbar.
    private var canSave: Bool {
        guard pet != nil || plan != nil else { return false }
        if kind == .ongoing { return !doseTimes.isEmpty }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                if didLoad {
                    form
                } else {
                    // Erste Zeichenrunde: `task` hat den Plan noch nicht geladen.
                    // Ohne diesen Zweig blitzen die Startwerte auf, bevor die
                    // gespeicherten Werte einlaufen.
                    Color.clear
                }
            }
            .navigationTitle(isNew ? "Neuer Plan" : "Plan bearbeiten")
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
            .onChange(of: kind) { _, newKind in
                // Nur bei neuen Plänen: bei einem bestehenden würde das stillschweigend
                // eine konfigurierte Wirkdauer überschreiben.
                if isNew { applyDefaults(for: newKind) }
            }
        }
    }

    // MARK: Abschnitte

    private var form: some View {
        Form {
            kindSection
            productSection

            switch kind {
            case .dewormer:
                dewormerSection
            case .tickProtection, .rabiesVaccination:
                protectionSection
            case .ongoing:
                doseTimesSection
                doseRhythmSection
            }

            notesSection

            if !isNew {
                activationSection
            }
        }
    }

    @ViewBuilder
    private var kindSection: some View {
        Section {
            if canChangeKind {
                Picker("Art", selection: $kind) {
                    ForEach(MedicationKind.allCases, id: \.self) { option in
                        Label(Format.label(option), systemImage: Format.symbolName(option))
                            .tag(option)
                    }
                }
            } else {
                LabeledValueRow(
                    label: "Art",
                    value: Format.label(kind),
                    systemImage: Format.symbolName(kind)
                )
            }
        } footer: {
            if canChangeKind {
                Text(kindExplanation)
            } else {
                Text("Die Art lässt sich nicht mehr ändern, weil zu diesem Plan schon Gaben dokumentiert sind.")
            }
        }
    }

    private var kindExplanation: String {
        switch kind {
        case .dewormer:
            return "Fällig wird die nächste Gabe aus der letzten Gabe plus Intervall."
        case .tickProtection:
            return "Der Schutz läuft ab der Gabe für die eingestellte Wirkdauer, die Restwirksamkeit steht als Balken in der Liste."
        case .ongoing:
            return "Ein Dauermedikament wird nicht als Ganzes fällig, sondern Gabe für Gabe abgehakt."
        case .rabiesVaccination:
            return "Rechnerisch wie der Zeckenschutz: Impfdatum plus Gültigkeitsdauer."
        }
    }

    private var productSection: some View {
        Section {
            TextField("Präparat", text: $productName, prompt: Text(Format.label(kind)))
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("medication-product-name")
        } footer: {
            Text("Ohne Angabe steht in der Liste „\(Format.label(kind))“.")
        }
    }

    private var dewormerSection: some View {
        Section {
            Picker("Intervall", selection: $intervalDays) {
                ForEach(intervalOptions, id: \.self) { days in
                    Text(MedicationDisplay.durationLabel(days: days)).tag(days)
                }
            }
            dayCountField(label: "Tage", value: $intervalDays)
            Toggle("Kotprobe statt Pauschalgabe", isOn: $usesFecalSampleInstead)
        } header: {
            Text("Wiederholung")
        } footer: {
            Text(
                usesFecalSampleInstead
                    ? "Fällig wird dann die Kotprobe, nicht die Gabe — entwurmt wird nur bei Befund."
                    : "Alle \(MedicationDisplay.durationLabel(days: intervalDays)) nach der letzten Gabe."
            )
        }
    }

    private var protectionSection: some View {
        Section {
            Picker(kind == .rabiesVaccination ? "Gültigkeit" : "Wirkdauer", selection: $effectiveDays) {
                ForEach(effectiveOptions, id: \.self) { days in
                    Text(MedicationDisplay.durationLabel(days: days)).tag(days)
                }
            }
            dayCountField(label: "Tage", value: $effectiveDays)
        } header: {
            Text(kind == .rabiesVaccination ? "Gültigkeit der Impfung" : "Wirkdauer des Präparats")
        } footer: {
            Text("Daraus ergibt sich die Restwirksamkeit: \(MedicationDisplay.durationLabel(days: effectiveDays)) ab der letzten Gabe.")
        }
    }

    private var doseTimesSection: some View {
        Section {
            ForEach($doseTimes) { $draft in
                DatePicker(
                    "Gabezeit",
                    selection: $draft.time,
                    displayedComponents: .hourAndMinute
                )
            }
            .onDelete { offsets in
                doseTimes.remove(atOffsets: offsets)
            }

            Button {
                addDoseTime()
            } label: {
                Label("Gabezeit hinzufügen", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Gabezeiten")
        } footer: {
            // Ohne diesen Hinweis wäre nach dem Löschen der letzten Gabezeit nur
            // „Speichern" ausgegraut, ohne dass der Grund irgendwo steht.
            Text(
                doseTimes.isEmpty
                    ? "Mindestens eine Gabezeit ist nötig — ohne sie hätte das Medikament keine Fälligkeit."
                    : "Jede Uhrzeit ist eine eigene Gabe pro Gabetag und wird einzeln abgehakt."
            )
            .foregroundStyle(doseTimes.isEmpty ? Color.red : Color.secondary)
        }
    }

    private var doseRhythmSection: some View {
        Section {
            Stepper(value: $doseEveryNDays, in: 1...30) {
                LabeledValueRow(
                    label: "Rhythmus",
                    value: doseEveryNDays == 1 ? "täglich" : "jeden \(doseEveryNDays). Tag"
                )
            }
            TextField("Dosis", text: $doseLabel, prompt: Text("z. B. 1/2 Tablette"))
            DatePicker("Beginn", selection: $doseStartDate, displayedComponents: .date)
            Toggle("Enddatum", isOn: $hasDoseEndDate)
            if hasDoseEndDate {
                DatePicker(
                    "Ende",
                    selection: $doseEndDate,
                    in: doseStartDate...,
                    displayedComponents: .date
                )
            }
        } header: {
            Text("Dosierung")
        } footer: {
            Text("Ohne Enddatum läuft das Medikament unbefristet.")
        }
    }

    private var notesSection: some View {
        Section("Notizen") {
            TextField("Notiz", text: $notes, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    /// Absetzen statt löschen: die dokumentierten Gaben bleiben erhalten, der
    /// Plan erzeugt nur keine Fälligkeiten und keine Erinnerungen mehr.
    private var activationSection: some View {
        Section {
            if isActive {
                Button("Medikament absetzen", role: .destructive) {
                    setActive(false)
                }
            } else {
                Button("Wieder aktivieren") {
                    setActive(true)
                }
            }
        } footer: {
            Text("Abgesetzte Medikamente rutschen in den Bereich „Abgesetzt“. Ihre Historie bleibt vollständig erhalten.")
        }
    }

    /// Freie Tageseingabe neben den Vorgaben — die Vorgaben decken den Alltag ab,
    /// aber ein Präparat mit 45 Tagen Wirkdauer darf nicht unmöglich sein.
    private func dayCountField(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
        }
    }

    /// Gängige Vorgaben plus der aktuelle Wert, damit die Auswahl des Pickers
    /// immer zu einem Eintrag passt — sonst zeigt er nichts an.
    private var intervalOptions: [Int] {
        options([30, 60, 90, 120, 180, 365], including: intervalDays)
    }

    private var effectiveOptions: [Int] {
        let presets = kind == .rabiesVaccination
            ? [365, 730, 1095]
            : [28, 30, 56, 84, 90, 120]
        return options(presets, including: effectiveDays)
    }

    private func options(_ presets: [Int], including current: Int) -> [Int] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    // MARK: Laden

    private func load() {
        guard !didLoad else { return }
        didLoad = true

        let targetPet = petID
        var petDescriptor = FetchDescriptor<Pet>(predicate: #Predicate<Pet> { $0.id == targetPet })
        petDescriptor.fetchLimit = 1
        pet = (try? context.fetch(petDescriptor))?.first

        guard let planID else {
            doseStartDate = appState.dayMath.startOfDay(Date())
            doseEndDate = appState.dayMath.adding(days: 30, to: doseStartDate)
            applyDefaults(for: kind)
            return
        }

        var planDescriptor = FetchDescriptor<MedicationPlan>(
            predicate: #Predicate<MedicationPlan> { $0.id == planID }
        )
        planDescriptor.fetchLimit = 1
        guard let existing = (try? context.fetch(planDescriptor))?.first else {
            // Der Plan wurde unter uns gelöscht — schließen statt ein leeres
            // Formular anzubieten, das einen zweiten Plan anlegen würde.
            dismiss()
            return
        }
        plan = existing
        seed(from: existing)
    }

    /// Der Parameter heißt `source`, nicht `plan`: er soll den gleichnamigen
    /// `@State` nicht verdecken.
    private func seed(from source: MedicationPlan) {
        kind = source.kindValue
        productName = source.productName
        notes = source.notes
        isActive = source.isActive

        intervalDays = source.intervalDays > 0 ? source.intervalDays : 90
        usesFecalSampleInstead = source.usesFecalSampleInstead
        effectiveDays = source.effectiveDays > 0
            ? source.effectiveDays
            : defaultEffectiveDays(for: source.kindValue)

        let dayStart = appState.dayMath.startOfDay(Date())
        doseTimes = source.doseTimesMinutes.sorted().map {
            DoseTimeDraft(time: date(fromMinutes: $0, on: dayStart))
        }
        doseEveryNDays = max(1, source.doseEveryNDays)
        doseStartDate = source.doseStartDate ?? source.createdAt
        hasDoseEndDate = source.doseEndDate != nil
        doseEndDate = source.doseEndDate ?? appState.dayMath.adding(days: 30, to: doseStartDate)
        doseLabel = source.doseLabel
    }

    /// Sinnvolle Startwerte, damit ein neuer Plan ohne Zahlendreherei
    /// speicherbar ist. Tollwut mit drei Jahren: das ist die übliche
    /// Wiederholungsimpfung.
    private func applyDefaults(for newKind: MedicationKind) {
        switch newKind {
        case .dewormer:
            intervalDays = 90
        case .tickProtection, .rabiesVaccination:
            effectiveDays = defaultEffectiveDays(for: newKind)
        case .ongoing:
            if doseTimes.isEmpty { addDoseTime() }
        }
    }

    private func defaultEffectiveDays(for someKind: MedicationKind) -> Int {
        someKind == .rabiesVaccination ? 1095 : 30
    }

    /// Erste Gabezeit 08:00, jede weitere zwölf Stunden später — das trifft den
    /// häufigsten Fall „morgens und abends" ohne Nachjustieren. Belegte Zeiten
    /// werden übersprungen, weil zwei gleiche Zeiten beim Speichern zu einer
    /// zusammenfallen würden und die zusätzliche Zeile stumm verschwände.
    private func addDoseTime() {
        let existing = Set(doseTimes.map { minutes(from: $0.time) })
        var candidate = existing.isEmpty ? 8 * 60 : ((existing.max() ?? 0) + 12 * 60) % (24 * 60)
        var attempts = 0
        while existing.contains(candidate), attempts < 24 {
            candidate = (candidate + 60) % (24 * 60)
            attempts += 1
        }
        let dayStart = appState.dayMath.startOfDay(Date())
        doseTimes.append(DoseTimeDraft(time: date(fromMinutes: candidate, on: dayStart)))
    }

    // MARK: Speichern

    /// Absetzen und Reaktivieren gehen absichtlich nicht über `save()`: sonst
    /// könnte ein Plan, dem eine Gabezeit fehlt, nicht abgesetzt werden — genau
    /// dann will man ihn aber loswerden.
    private func setActive(_ value: Bool) {
        isActive = value
        guard let plan else { return }
        plan.isActive = value
        try? context.save()
        dismiss()
    }

    private func save() {
        guard canSave else { return }

        let target: MedicationPlan
        if let plan {
            target = plan
        } else {
            let created = MedicationPlan(kind: kind)
            context.insert(created)
            // Beziehung über die `pet`-Property, nicht über `pet.medicationPlans`
            // — dort steht das `inverse:`.
            created.pet = pet
            plan = created
            target = created
        }

        target.kindValue = kind
        target.productName = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        target.isActive = isActive

        // Felder anderer Arten werden zurückgesetzt: bliebe eine alte Wirkdauer
        // stehen, würde die Engine sie nach einem Artwechsel weiterrechnen.
        target.intervalDays = kind == .dewormer ? max(1, intervalDays) : 0
        target.usesFecalSampleInstead = kind == .dewormer ? usesFecalSampleInstead : false
        target.effectiveDays = kind.usesEffectivePeriod ? max(1, effectiveDays) : 0

        if kind == .ongoing {
            target.doseTimesMinutes = Array(Set(doseTimes.map { minutes(from: $0.time) })).sorted()
            target.doseEveryNDays = max(1, doseEveryNDays)
            target.doseStartDate = appState.dayMath.startOfDay(doseStartDate)
            target.doseEndDate = hasDoseEndDate ? appState.dayMath.startOfDay(doseEndDate) : nil
            target.doseLabel = doseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            target.doseTimesMinutes = []
            target.doseEveryNDays = 1
            target.doseStartDate = nil
            target.doseEndDate = nil
            target.doseLabel = ""
        }

        try? context.save()
        dismiss()
    }

    // MARK: Uhrzeit ↔ Minuten

    private func minutes(from date: Date) -> Int {
        let calendar = appState.dayMath.calendar
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return hour * 60 + minute
    }

    private func date(fromMinutes value: Int, on day: Date) -> Date {
        let calendar = appState.dayMath.calendar
        return calendar.date(
            bySettingHour: min(max(value / 60, 0), 23),
            minute: min(max(value % 60, 0), 59),
            second: 0,
            of: day
        ) ?? day
    }
}

/// Eine Gabezeit im Formular. `DatePicker` braucht ein `Date`, gespeichert
/// werden Minuten nach Mitternacht — die `id` hält die Zeilen beim Bearbeiten
/// auseinander, auch wenn zwei Zeiten gleich sind.
private struct DoseTimeDraft: Identifiable, Equatable {
    let id = UUID()
    var time: Date
}

// Kein `#Preview`: das Formular liest sein Tier über den `ModelContext`, und die
// Vorschau hätte keinen.
