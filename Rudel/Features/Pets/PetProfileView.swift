import RudelEngine
import SwiftData
import SwiftUI

/// Stammdaten des gewählten Tiers (PRD §5.1) — und der Einstiegspunkt für
/// Bearbeiten, Einstellungen, weiteres Tier und Löschen.
///
/// Den Tier-Umschalter und die Auflösung des gewählten Tiers übernimmt
/// `PetScope`; der eigentliche Inhalt steckt in `PetProfileContent`, damit
/// dessen `@State` (der Löschdialog) beim Tierwechsel über `.id(pet.id)`
/// zurückgesetzt wird.
struct PetProfileView: View {
    var body: some View {
        PetScope(title: "Profil") { pet in
            if pet.isDeleted {
                // Zwischenzustand unmittelbar nach dem Löschen: das Modell ist
                // ungültig, seine Properties dürfen nicht mehr gelesen werden.
                // `PetScope` bzw. `RootView` lösen im nächsten Durchlauf auf ein
                // anderes Tier oder auf `WelcomeView` auf.
                Color.clear
            } else {
                PetProfileContent(pet: pet)
                    .id(pet.id)
            }
        }
    }
}

private struct PetProfileContent: View {
    let pet: Pet

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    /// Momentaufnahme für den Löschdialog. Siehe `PetDeletionSummary`.
    @State private var pendingDeletion: PetDeletionSummary?

    var body: some View {
        List {
            headerSection
            baseDataSection
            if pet.speciesValue == .dog {
                sizeClassSection
            }
            statisticsSection
            actionsSection
            deleteSection
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.present(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Einstellungen")
            }
        }
        .confirmationDialog(
            "Tier löschen?",
            isPresented: deletionDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { summary in
            Button("\(summary.name) löschen", role: .destructive) {
                delete()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { summary in
            Text(summary.message)
        }
    }

    // MARK: - Abschnitte

    private var headerSection: some View {
        Section {
            HStack(spacing: 16) {
                PetAvatar(pet: pet, size: 76)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.title2.weight(.semibold))

                    Text(speciesAndBreed)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let ageText {
                        Text(ageText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var baseDataSection: some View {
        Section {
            LabeledValueRow(
                label: "Art",
                value: pet.speciesValue.label,
                systemImage: pet.speciesValue.symbolName
            )

            if !pet.breed.isEmpty {
                LabeledValueRow(label: "Rasse", value: pet.breed, systemImage: "list.bullet")
            }

            LabeledValueRow(
                label: "Geburtsdatum",
                value: pet.birthDate.map(Format.date) ?? "Nicht erfasst",
                systemImage: "birthday.cake"
            )

            LabeledValueRow(
                label: "Geschlecht",
                value: pet.isFemale ? "Weiblich" : "Männlich",
                systemImage: "figure.stand.dress.line.vertical.figure"
            )

            LabeledValueRow(
                label: "Kastriert",
                value: pet.isNeutered ? "Ja" : "Nein",
                systemImage: "cross.case"
            )

            LabeledValueRow(
                label: "Zielbereich Gewicht",
                value: weightTargetText ?? "Nicht festgelegt",
                systemImage: "scalemass"
            )

            if let latest = pet.latestWeightKg {
                LabeledValueRow(
                    label: "Letztes Gewicht",
                    value: Format.weight(latest),
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            }
        } header: {
            Text("Stammdaten")
        } footer: {
            if let baseDataFooter {
                Text(baseDataFooter)
            }
        }
    }

    /// Die Größenklasse ist eine Hunde-Größe (`DogSizeClass`) und wirkt allein
    /// auf den Startwert der Zyklusprognose. Für Katzen wird der Abschnitt
    /// deshalb gar nicht gezeigt — dort wäre der Wert eine Zahl ohne Bedeutung.
    private var sizeClassSection: some View {
        Section {
            LabeledValueRow(
                label: "Größenklasse",
                value: Format.label(pet.effectiveSizeClass),
                systemImage: "ruler"
            )
        } header: {
            Text("Größenklasse")
        } footer: {
            Text(sizeClassFooter)
        }
    }

    private var statisticsSection: some View {
        Section {
            LabeledValueRow(
                label: "Gaben",
                value: "\(medicationEntryCount)",
                systemImage: "pills"
            )

            if showsCycleCount {
                LabeledValueRow(
                    label: "Läufigkeiten",
                    value: "\(pet.cyclePeriods.count)",
                    systemImage: "circle.hexagonpath"
                )
            }

            LabeledValueRow(
                label: "Symptome",
                value: "\(pet.symptomEntries.count)",
                systemImage: "stethoscope"
            )

            LabeledValueRow(
                label: "Gewichtseinträge",
                value: "\(pet.weightEntries.count)",
                systemImage: "scalemass"
            )
        } header: {
            Text("Erfasste Daten")
        } footer: {
            Text(statisticsFooter)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                appState.present(.editPet(petID: pet.id))
            } label: {
                Label("Bearbeiten", systemImage: "square.and.pencil")
            }

            Button {
                appState.present(.editPet(petID: nil))
            } label: {
                Label("Weiteres Tier anlegen", systemImage: "plus.circle")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                pendingDeletion = makeDeletionSummary()
            } label: {
                Label("Tier löschen", systemImage: "trash")
            }
        } footer: {
            Text("Löscht das Profil samt aller Gaben, Läufigkeiten, Symptome und Gewichtseinträge.")
        }
    }

    // MARK: - Abgeleitete Texte

    private var displayName: String {
        pet.name.isEmpty ? "Unbenannt" : pet.name
    }

    private var speciesAndBreed: String {
        pet.breed.isEmpty ? pet.speciesValue.label : "\(pet.speciesValue.label) · \(pet.breed)"
    }

    /// Alter als „3 Jahre, 4 Monate". Kein `Format`-Helfer vorhanden, deshalb
    /// hier formuliert.
    private var ageText: String? {
        guard let parts = pet.ageComponents() else { return nil }
        let years = parts.years
        let months = parts.months

        if years == 0 && months == 0 { return "Wenige Tage alt" }
        let yearText = "\(years) \(years == 1 ? "Jahr" : "Jahre")"
        let monthText = "\(months) \(months == 1 ? "Monat" : "Monate")"
        if years == 0 { return monthText }
        if months == 0 { return yearText }
        return "\(yearText), \(monthText)"
    }

    private var weightTargetText: String? {
        let minKg = pet.weightTargetMinKg
        let maxKg = pet.weightTargetMaxKg
        guard minKg > 0 || maxKg > 0 else { return nil }
        if minKg > 0 && maxKg > 0 {
            // Die Einheit nur einmal nennen — „22 kg – 28 kg" liest sich zäh.
            return "\(plainNumber(minKg)) – \(Format.weight(maxKg))"
        }
        if minKg > 0 { return "ab \(Format.weight(minKg))" }
        return "bis \(Format.weight(maxKg))"
    }

    private func plainNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Macht sichtbar, dass Loggen etwas bringt: die Einträge sind nicht Archiv,
    /// sie sind die Rechengrundlage.
    private var statisticsFooter: String {
        let base = "Diese Einträge sind die Rechengrundlage: die Fälligkeiten kommen aus den Gaben"
        guard showsCycleCount else {
            return "\(base). Je länger die Historie, desto belastbarer die Prognose."
        }
        return "\(base), die Zyklusprognose aus den Tag-1-Daten der Läufigkeiten. Je mehr eigene Zyklen erfasst sind, desto engere Spannen zeigt Rudel."
    }

    /// Hinweis für unkastrierte Katzen: hier fehlt das Zyklus-Modul mit Absicht.
    private var baseDataFooter: String? {
        guard pet.speciesValue == .cat, pet.isFemale, !pet.isNeutered else { return nil }
        return "Für Katzen führt Rudel keine Zyklusprognose: Katzen sind saisonal polyöstrisch mit induzierter Ovulation, innerhalb der Saison folgt der Östrus alle zwei bis drei Wochen. Dieses Muster rechnet die App nicht."
    }

    private var sizeClassFooter: String {
        let origin = pet.sizeClassOverride == nil
            ? (pet.latestWeightKg == nil
                ? "Ohne Gewichtseintrag greift Rudel auf „Mittel“ zurück."
                : "Automatisch aus dem letzten Gewichtseintrag abgeleitet.")
            : "Manuell festgelegt."

        guard pet.tracksCycle else {
            return "\(origin) Die Klasse wirkt nur auf die Zyklusprognose und bleibt für dieses Tier ohne Effekt."
        }

        let bias = StudyConstants.intervalBiasDays(for: pet.effectiveSizeClass)
        let biasText = bias == 0
            ? "verschiebt den Startwert der Zyklusprognose nicht"
            : "verschiebt den Startwert der Zyklusprognose um \(bias > 0 ? "+" : "−")\(abs(bias)) Tage"
        return "\(origin) Sie \(biasText). Sobald eigene Intervalle geloggt sind, überstimmen sie diesen Startwert."
    }

    // MARK: - Zählungen

    /// Beide Journale zusammen: eine Einzeldosis eines Dauermedikaments ist für
    /// den Nutzer genauso „eine Gabe" wie eine Wurmkur.
    private var medicationEntryCount: Int {
        pet.medicationPlans.reduce(0) { $0 + $1.events.count + $1.doseLogs.count }
    }

    private var showsCycleCount: Bool {
        pet.tracksCycle || !pet.cyclePeriods.isEmpty
    }

    // MARK: - Löschen

    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    /// Baut die Aufzählung, die im Dialog steht. `deleteRule: .cascade` räumt
    /// alles ab, was am Tier hängt — der Nutzer muss vorher wissen, wie viel das
    /// ist.
    private func makeDeletionSummary() -> PetDeletionSummary {
        var parts: [String] = []

        let planCount = pet.medicationPlans.count
        if planCount > 0 {
            parts.append("\(planCount) \(planCount == 1 ? "Medikamentenplan" : "Medikamentenpläne")")
        }

        let doses = medicationEntryCount
        if doses > 0 {
            parts.append("\(doses) \(doses == 1 ? "Gabe" : "Gaben")")
        }

        let periods = pet.cyclePeriods.count
        if periods > 0 {
            let observations = pet.cyclePeriods.reduce(0) { $0 + $1.observations.count }
            let periodText = "\(periods) \(periods == 1 ? "Läufigkeit" : "Läufigkeiten")"
            parts.append(
                observations > 0
                    ? "\(periodText) mit \(observations) \(observations == 1 ? "Beobachtung" : "Beobachtungen")"
                    : periodText
            )
        }

        let symptoms = pet.symptomEntries.count
        if symptoms > 0 {
            parts.append("\(symptoms) \(symptoms == 1 ? "Symptom" : "Symptome")")
        }

        let weights = pet.weightEntries.count
        if weights > 0 {
            parts.append("\(weights) \(weights == 1 ? "Gewichtseintrag" : "Gewichtseinträge")")
        }

        let name = displayName
        let message: String
        if parts.isEmpty {
            message = "Für \(name) sind noch keine Einträge erfasst. Es wird nur das Profil gelöscht."
        } else {
            message = "Mit \(name) werden \(enumerated(parts)) gelöscht. Das lässt sich nicht rückgängig machen."
        }

        return PetDeletionSummary(name: name, message: message)
    }

    /// „a, b und c" — deutsche Aufzählung statt einer Komma-Liste.
    private func enumerated(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        guard parts.count > 1 else { return last }
        return parts.dropLast().joined(separator: ", ") + " und " + last
    }

    private func delete() {
        // Auswahl **vor** dem Löschen umlenken: sonst zeigt `PetScope` für einen
        // Frame ein Modell, das gleich ungültig ist. `RootView.syncSelection()`
        // würde das auch reparieren, aber erst nach dem Löschen.
        let remaining = ((try? context.fetch(FetchDescriptor<Pet>())) ?? [])
            .filter { $0.id != pet.id }
            .sorted { $0.createdAt < $1.createdAt }
        appState.selectedPetID = remaining.first?.id

        context.delete(pet)
        try? context.save()
        pendingDeletion = nil
    }
}

/// Momentaufnahme des Tiers für den Löschdialog.
///
/// Bewusst ein Wert und keine Referenz auf das `Pet`: nach `context.delete(...)`
/// ist das Modell ungültig, ein Zugriff auf seine Properties aus dem noch
/// eingeblendeten Dialog würde abstürzen.
private struct PetDeletionSummary {
    let name: String
    let message: String
}
