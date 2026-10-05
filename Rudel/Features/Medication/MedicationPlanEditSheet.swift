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

    @State private var careClass: MedicationCareClass = MedicationKind.dewormer.defaultCareClass
    @State private var requiresVetVisit = MedicationKind.dewormer.defaultRequiresVetVisit
    /// Laufende Zurückstellung, nur zur Anzeige. Eine heute endende oder
    /// verstrichene steht hier nicht, wirkt im Plan aber weiter.
    @State private var deferredUntil: Date?
    /// Nur „Aufheben" setzt das. Ein leeres `deferredUntil` allein heißt nicht
    /// „aufheben" — sonst löschte jedes Speichern eine nicht angezeigte
    /// Zurückstellung mit.
    @State private var didClearDeferral = false

    /// Welche Impfung — bestimmt bei Impfungen die gespeicherte Art.
    @State private var vaccineChoice: VaccineChoice = .rabies

    // Vorrat. Mengen als Text, damit Komma und halbe Tabletten beim Tippen
    // nicht vom Zahlenformat zurückgesetzt werden und der letzte Wert auch
    // ohne Verlassen des Feldes ankommt.
    @State private var managesStock = false
    @State private var stockAmountText = ""
    /// Restbestand beim Laden, wie angezeigt. Nur wenn sich der Text ändert,
    /// entsteht eine neue Zählung — sonst zögen die Gaben seit der alten
    /// Zählung vom neuen Wert noch einmal ab.
    @State private var loadedStockAmountText = ""
    @State private var stockUnit = ""
    @State private var amountPerGivingText = "1"
    @State private var loadedAmountPerGivingText = "1"
    @State private var packageSizeText = ""
    @State private var restockLeadDays = 7
    @State private var needsPrescription = false

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
        if kind == .ongoing, doseTimes.isEmpty { return false }
        if managesStock, !kind.isVaccination {
            guard let amount = Self.parseAmount(stockAmountText), amount >= 0,
                  let perGiving = Self.parseAmount(amountPerGivingText), perGiving > 0 else { return false }
        }
        return true
    }

    private var species: Species { pet?.speciesValue ?? plan?.pet?.speciesValue ?? .dog }

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
            .rudelFormStyle()
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
                // eine konfigurierte Wirkdauer überschreiben. Auch `seed` ändert
                // die Art und löst das hier aus.
                if isNew {
                    applyDefaults(for: newKind)
                    applyReminderDefaults(for: newKind)
                }
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
            case .tickProtection, .rabiesVaccination, .vaccination:
                protectionSection
            case .ongoing:
                doseTimesSection
                doseRhythmSection
            }

            // Impfungen gibt die Praxis, ein Vorrat zu Hause ist dort nicht üblich.
            if !kind.isVaccination {
                stockSection
            }

            reminderSection
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
                Picker("Art", selection: kindOptionBinding) {
                    ForEach(Self.kindOptions, id: \.self) { option in
                        Label(Format.label(option), systemImage: Format.symbolName(option))
                            .tag(option)
                    }
                }
                if kind.isVaccination {
                    Picker("Impfung gegen", selection: vaccineBinding) {
                        ForEach(vaccineOptions, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .accessibilityIdentifier("medication-vaccine")
                }
            } else {
                LabeledValueRow(
                    label: "Art",
                    value: Format.label(kind.isVaccination ? .vaccination : kind),
                    systemImage: Format.symbolName(kind)
                )
                if kind.isVaccination {
                    LabeledValueRow(label: "Impfung gegen", value: vaccineChoice.label)
                }
            }
        } footer: {
            if canChangeKind {
                Text(kindExplanation)
            } else {
                Text("Die Art lässt sich nicht mehr ändern, weil zu diesem Plan schon Einträge dokumentiert sind.")
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
        case .rabiesVaccination, .vaccination:
            return "Impfdatum plus Gültigkeit laut Impfpass."
        }
    }

    /// Im Art-Picker gibt es nur eine „Impfung"; welche, entscheidet der
    /// zweite Picker. Tollwut bleibt dabei die eigene Art.
    static let kindOptions: [MedicationKind] = [.dewormer, .tickProtection, .ongoing, .vaccination]

    private var kindOptionBinding: Binding<MedicationKind> {
        Binding(
            get: { kind.isVaccination ? .vaccination : kind },
            set: { option in
                if option == .vaccination {
                    if !kind.isVaccination { selectVaccine(vaccineChoice) }
                } else {
                    kind = option
                }
            }
        )
    }

    /// Nur Nutzer-Eingaben laufen hierüber — `seed` setzt `vaccineChoice`
    /// direkt, damit eine eigene Gültigkeit eines Bestandsplans beim Öffnen
    /// nicht vom Katalog überschrieben wird.
    private var vaccineBinding: Binding<VaccineChoice> {
        Binding(get: { vaccineChoice }, set: { selectVaccine($0) })
    }

    private func selectVaccine(_ choice: VaccineChoice) {
        vaccineChoice = choice
        // Vorbelegung aus dem Katalog nur, solange nichts dokumentiert ist.
        if canChangeKind {
            effectiveDays = choice.defaultValidityDays(for: species)
        }
        kind = choice.kind
    }

    /// Tollwut zuerst, dann die Impfungen der Tierart. Eine gespeicherte Wahl
    /// bleibt auswählbar, auch wenn sie nicht zur Tierart passt — sonst zeigte
    /// der Picker nichts an.
    private var vaccineOptions: [VaccineChoice] {
        let options = [VaccineChoice.rabies] + VaccineType.options(for: species).map(VaccineChoice.vaccine)
        return options.contains(vaccineChoice) ? options : options + [vaccineChoice]
    }

    private var productSection: some View {
        Section {
            TextField("Präparat", text: $productName, prompt: Text(kind.isVaccination ? "Impfstoff" : Format.label(kind)))
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("medication-product-name")
        } footer: {
            if !kind.isVaccination {
                Text("Ohne Angabe steht in der Liste „\(Format.label(kind))“.")
            }
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
            Picker(kind.isVaccination ? "Gültigkeit" : "Wirkdauer", selection: $effectiveDays) {
                ForEach(effectiveOptions, id: \.self) { days in
                    Text(MedicationDisplay.durationLabel(days: days)).tag(days)
                }
            }
            dayCountField(label: "Tage", value: $effectiveDays)
        } header: {
            Text(kind.isVaccination ? "Gültigkeit der Impfung" : "Wirkdauer des Präparats")
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

    private var stockSection: some View {
        Section {
            Toggle("Vorrat verwalten", isOn: $managesStock)
                .accessibilityIdentifier("medication-manage-stock")
            if managesStock {
                amountField("Bestand", text: $stockAmountText, identifier: "medication-stock-amount")
                HStack {
                    Text("Einheit")
                    Spacer(minLength: 8)
                    TextField("Einheit", text: $stockUnit, prompt: Text("Tabletten"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("medication-stock-unit")
                }
                amountField("Menge je Gabe", text: $amountPerGivingText, identifier: "medication-amount-per-giving")
                amountField("Packungsgröße", text: $packageSizeText, identifier: "medication-package-size", prompt: "unbekannt")
                Stepper(value: $restockLeadDays, in: 1...60) {
                    LabeledValueRow(label: "Erinnern", value: "\(Format.dayCount(restockLeadDays)) vorher")
                }
                Toggle("Rezeptpflichtig", isOn: $needsPrescription)
            }
        } header: {
            Text("Vorrat")
        } footer: {
            if managesStock {
                Text("Jede erfasste Gabe zieht die Menge je Gabe ab.")
            }
        }
    }

    private func amountField(_ label: String, text: Binding<String>, identifier: String, prompt: String = "0") -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            TextField(label, text: text, prompt: Text(prompt))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .accessibilityIdentifier(identifier)
        }
    }

    /// Vorsorge löst nie einen Wecker aus; zeitkritisch heißt Alarm zur
    /// Gabezeit. Der Standard hängt an der Art.
    private var reminderSection: some View {
        Section {
            Picker("Erinnerung", selection: $careClass) {
                Text("Zeitkritisch").tag(MedicationCareClass.timeCritical)
                Text("Vorsorge").tag(MedicationCareClass.preventive)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("medication-care-class")

            if kind != .ongoing {
                Toggle("Tierarzttermin nötig", isOn: $requiresVetVisit)
            }

            if let deferredUntil {
                HStack {
                    Text("Zurückgestellt bis \(Format.date(deferredUntil))")
                    Spacer(minLength: 8)
                    Button("Aufheben") {
                        self.deferredUntil = nil
                        didClearDeferral = true
                    }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Erinnerung")
        } footer: {
            Text(careClass == .timeCritical ? "Alarm zur Gabezeit" : "Nur Mitteilung, kein Alarm")
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
        let presets = kind.isVaccination
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
            applyReminderDefaults(for: kind)
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

        careClass = source.careClass
        requiresVetVisit = source.requiresVetVisit
        vaccineChoice = VaccineChoice(kind: source.kindValue, vaccine: source.vaccineValue) ?? .rabies

        managesStock = source.managesStock
        stockAmountText = source.remainingStock.map { Format.amount(max(0, $0)) } ?? ""
        loadedStockAmountText = stockAmountText
        stockUnit = source.stockUnit
        amountPerGivingText = Format.amount(source.amountPerGiving > 0 ? source.amountPerGiving : 1)
        loadedAmountPerGivingText = amountPerGivingText
        packageSizeText = source.packageSize > 0 ? Format.amount(source.packageSize) : ""
        restockLeadDays = max(1, source.restockLeadDays)
        needsPrescription = source.needsPrescription
        // Eine verstrichene Zurückstellung wirkt nicht mehr und wird nicht gezeigt.
        deferredUntil = source.activeDeferral.flatMap { appState.dayMath.startOfDay($0) > dayStart ? $0 : nil }
    }

    /// Sinnvolle Startwerte, damit ein neuer Plan ohne Zahlendreherei
    /// speicherbar ist. Tollwut mit drei Jahren: das ist die übliche
    /// Wiederholungsimpfung.
    private func applyDefaults(for newKind: MedicationKind) {
        switch newKind {
        case .dewormer:
            intervalDays = 90
        case .tickProtection, .rabiesVaccination, .vaccination:
            effectiveDays = defaultEffectiveDays(for: newKind)
        case .ongoing:
            if doseTimes.isEmpty { addDoseTime() }
        }
    }

    private func applyReminderDefaults(for newKind: MedicationKind) {
        careClass = newKind.defaultCareClass
        requiresVetVisit = newKind.defaultRequiresVetVisit
    }

    /// Impfungen aus dem Katalog (Tollwut 3 Jahre), Zeckenschutz 30 Tage.
    private func defaultEffectiveDays(for someKind: MedicationKind) -> Int {
        guard someKind.isVaccination else { return 30 }
        return (VaccineChoice(kind: someKind, vaccine: vaccineChoice.vaccine) ?? vaccineChoice)
            .defaultValidityDays(for: species)
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

        Self.applyKind(kind, vaccine: vaccineChoice.vaccine, to: target)
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

        // `nil` heißt „Standard der Art" — nur Abweichungen werden gespeichert,
        // damit ein späterer anderer Standard Bestandspläne mitnimmt.
        target.careClassOverride = careClass == kind.defaultCareClass ? nil : careClass
        if kind == .ongoing {
            // Bei Dauermedikamenten greift „Termin nötig" in der Engine nicht.
            target.requiresVetVisitOverride = nil
        } else {
            target.requiresVetVisitOverride = requiresVetVisit == kind.defaultRequiresVetVisit ? nil : requiresVetVisit
        }
        Self.applyDeferralEdit(didClearDeferral: didClearDeferral, to: target)
        if kind.isVaccination {
            target.stockCountedAt = nil
        } else {
            Self.applyStockEdit(
                StockDraft(
                    managesStock: managesStock,
                    amount: Self.parseAmount(stockAmountText) ?? 0,
                    unit: stockUnit,
                    amountPerGiving: Self.parseAmount(amountPerGivingText) ?? 1,
                    packageSize: Self.parseAmount(packageSizeText) ?? 0,
                    restockLeadDays: restockLeadDays,
                    needsPrescription: needsPrescription
                ),
                recount: stockAmountText != loadedStockAmountText || amountPerGivingText != loadedAmountPerGivingText,
                to: target,
                at: Date()
            )
        }

        try? context.save()
        MedicationActions.refreshNotifications(context: context)
        dismiss()
    }

    /// Art und Impfung. Tollwut speichert `.rabiesVaccination` ohne
    /// `vaccineValue` — wie Bestandspläne —, alles andere `.vaccination` mit
    /// der gewählten Impfung. Nicht-Impfungen tragen nie eine.
    static func applyKind(_ kind: MedicationKind, vaccine: VaccineType?, to plan: MedicationPlan) {
        plan.kindValue = kind
        plan.vaccineValue = kind == .vaccination ? (vaccine ?? .other) : nil
    }

    struct StockDraft {
        var managesStock: Bool
        var amount: Double
        var unit: String
        var amountPerGiving: Double
        var packageSize: Double
        var restockLeadDays: Int
        var needsPrescription: Bool
    }

    /// Übernimmt den Vorrat. Eine neue Zählung (Bestand + jetzt) entsteht nur
    /// beim Einschalten oder wenn Bestand oder Menge je Gabe geändert wurden
    /// (`recount`) — sonst zöge der bisher angezeigte Rest die Gaben seit der
    /// alten Zählung ein zweites Mal ab. Ausschalten setzt nur die Zählung
    /// zurück; die Parameter bleiben für ein späteres Wiedereinschalten.
    static func applyStockEdit(_ draft: StockDraft, recount: Bool, to plan: MedicationPlan, at now: Date) {
        guard draft.managesStock else {
            plan.stockCountedAt = nil
            return
        }
        plan.stockUnit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.amountPerGiving = draft.amountPerGiving > 0 ? draft.amountPerGiving : 1
        plan.packageSize = max(0, draft.packageSize)
        plan.restockLeadDays = max(0, draft.restockLeadDays)
        plan.needsPrescription = draft.needsPrescription
        if plan.stockCountedAt == nil || recount {
            plan.stockAmount = max(0, draft.amount)
            plan.stockCountedAt = now
        }
    }

    /// „12", „1,5" oder „1.5" — `nil` bei leerer oder ungültiger Eingabe.
    static func parseAmount(_ text: String) -> Double? {
        var normalized = text.filter { !$0.isWhitespace }
        guard !normalized.isEmpty else { return nil }
        // Mit Komma ist ein Punkt der Tausendertrenner, sonst der Dezimalpunkt.
        if normalized.contains(",") {
            normalized = normalized
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
        }
        // „inf", „nan" und absurde Größen nicht speichern — die Projektion
        // würde sie bei jedem Start durchrechnen.
        guard let value = Double(normalized), value.isFinite, abs(value) < 1_000_000 else { return nil }
        return value
    }

    /// Hebt die Zurückstellung nur auf, wenn „Aufheben" getippt wurde. Eigene
    /// Funktion, damit die Regel ohne View prüfbar ist.
    static func applyDeferralEdit(didClearDeferral: Bool, to plan: MedicationPlan) {
        guard didClearDeferral else { return }
        plan.deferredUntil = nil
        plan.deferredAt = nil
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

/// Die Auswahl im Impfungs-Picker. Tollwut ist ein eigener Fall, weil sie als
/// eigene Art gespeichert wird.
enum VaccineChoice: Hashable {
    case rabies
    case vaccine(VaccineType)

    /// `nil` für Nicht-Impfungen.
    init?(kind: MedicationKind, vaccine: VaccineType?) {
        switch kind {
        case .rabiesVaccination: self = .rabies
        case .vaccination: self = .vaccine(vaccine ?? .other)
        case .dewormer, .tickProtection, .ongoing: return nil
        }
    }

    var kind: MedicationKind {
        switch self {
        case .rabies: return .rabiesVaccination
        case .vaccine: return .vaccination
        }
    }

    var vaccine: VaccineType? {
        switch self {
        case .rabies: return nil
        case .vaccine(let vaccine): return vaccine
        }
    }

    var label: String {
        switch self {
        case .rabies: return "Tollwut"
        case .vaccine(let vaccine): return vaccine.displayName
        }
    }

    /// Tollwut: 3 Jahre (übliche Wiederholungsimpfung, StIKo Vet).
    func defaultValidityDays(for species: Species) -> Int {
        switch self {
        case .rabies: return 1095
        case .vaccine(let vaccine): return vaccine.defaultValidityDays(for: species)
        }
    }
}
