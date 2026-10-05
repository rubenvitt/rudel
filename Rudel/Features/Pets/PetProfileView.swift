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

extension PetProfileView {
    /// Beide Journale zusammen: eine Einzeldosis eines Dauermedikaments ist für
    /// den Nutzer genauso „eine Gabe" wie eine Wurmkur. Auslassungen stehen
    /// ebenfalls im Journal, sind aber keine Gaben und werden getrennt gezählt.
    static func medicationCounts(of pet: Pet) -> (given: Int, skipped: Int) {
        var given = 0
        var skipped = 0
        for plan in pet.medicationPlans {
            for event in plan.events {
                if event.outcomeValue == .given { given += 1 } else { skipped += 1 }
            }
            for log in plan.doseLogs {
                if log.wasSkipped { skipped += 1 } else { given += 1 }
            }
        }
        return (given, skipped)
    }
}

private struct PetProfileContent: View {
    let pet: Pet

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    /// Momentaufnahme für den Löschdialog. Siehe `PetDeletionSummary`.
    @State private var pendingDeletion: PetDeletionSummary?

    /// Notfallkliniken gelten für alle Tiere, deshalb die Abfrage über alle
    /// Praxen statt über das Tier.
    @Query(sort: \VetPractice.name) private var practices: [VetPractice]

    var body: some View {
        List {
            headerSection
            emergencySection
            baseDataSection
            if pet.speciesValue == .dog {
                sizeClassSection
            }
            statisticsSection
            actionsSection
            deleteSection
        }
        .rudelListStyle()
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
            RudelPetHero(pet: pet, eyebrow: "DEIN RUDEL") {
                HStack(alignment: .firstTextBaseline) {
                    Label(pet.speciesValue.label, systemImage: pet.speciesValue.symbolName)
                    Spacer(minLength: 12)
                    Text(ageText ?? "Geburtstag noch nicht erfasst")
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .foregroundStyle(RudelTheme.sage)
            }
            .rudelFeatureRow()
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

    /// Notfallkarte: was man in der Hektik braucht, ohne zu suchen. Fehlende
    /// Angaben bleiben sichtbar, damit klar ist, was noch einzutragen wäre.
    private var emergencySection: some View {
        Section {
            primaryPracticeRow

            ForEach(emergencyClinics) { clinic in
                EmergencyPracticeRow(
                    role: "Notdienst",
                    practice: clinic,
                    number: clinic.emergencyPhone.isEmpty ? clinic.phone : clinic.emergencyPhone
                )
            }

            emergencyValueRow(
                label: "Chipnummer",
                value: pet.microchipNumber,
                systemImage: "wave.3.right",
                monospaced: true
            )
            emergencyValueRow(label: "Allergien", value: pet.allergies, systemImage: "allergens")
            emergencyValueRow(label: "Versicherung", value: pet.insuranceInfo, systemImage: "doc.text")

            if hasMissingEmergencyData {
                Button {
                    appState.present(.editPet(petID: pet.id))
                } label: {
                    Label("Notfalldaten ergänzen", systemImage: "square.and.pencil")
                }
            }
        } header: {
            RudelSectionHeading(title: "Notfall")
        }
    }

    @ViewBuilder
    private var primaryPracticeRow: some View {
        if let practice = pet.primaryPractice {
            EmergencyPracticeRow(role: "Haustierarzt", practice: practice, number: practice.phone)
            if !practice.emergencyPhone.isEmpty {
                HStack {
                    LabeledValueRow(
                        label: "Notfallnummer",
                        value: practice.emergencyPhone,
                        systemImage: "phone.badge.waveform"
                    )
                    VetCallButton(
                        number: practice.emergencyPhone,
                        accessibilityName: "Notfallnummer von \(VetDisplay.practiceName(practice)) anrufen"
                    )
                }
            }
        } else {
            LabeledValueRow(label: "Haustierarzt", value: "Nicht hinterlegt", systemImage: "stethoscope")
        }
    }

    /// Die Hauspraxis steht schon oben, auch wenn sie Notdienst hat.
    private var emergencyClinics: [VetPractice] {
        practices.filter { $0.isEmergencyClinic && $0.id != pet.primaryPractice?.id }
    }

    /// Allergien und Versicherung dürfen zu Recht leer sein; der Einstieg
    /// erscheint nur für die Angaben, die praktisch jedes Tier hat.
    private var hasMissingEmergencyData: Bool {
        pet.primaryPractice == nil || pet.microchipNumber.isEmpty
    }

    /// Wert einer Notfallangabe. Text auswählbar, damit sich etwa die
    /// Chipnummer kopieren und in ein Register einfügen lässt.
    private func emergencyValueRow(
        label: String,
        value: String,
        systemImage: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(RudelTheme.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(label)
            Spacer(minLength: 12)
            if value.isEmpty {
                Text("Nicht erfasst")
                    .foregroundStyle(RudelTheme.muted)
            } else {
                Text(value)
                    .monospaced(monospaced)
                    .foregroundStyle(RudelTheme.ink)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
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
                value: "\(medicationCounts.given)",
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

            VetReportShareLink(petID: pet.id, petName: pet.name, title: "Tierarzt-Bericht teilen")

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
            Text("Löscht das Profil samt aller Gaben, Tierarzttermine, Läufigkeiten, Symptome und Gewichtseinträge.")
        }
    }

    // MARK: - Abgeleitete Texte

    private var displayName: String {
        pet.name.isEmpty ? "Unbenannt" : pet.name
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

    private var medicationCounts: (given: Int, skipped: Int) {
        PetProfileView.medicationCounts(of: pet)
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

        let counts = medicationCounts
        if counts.given > 0 {
            parts.append("\(counts.given) \(counts.given == 1 ? "Gabe" : "Gaben")")
        }
        // Die Kaskade löscht Auslassungen mit — der Dialog muss sie nennen.
        if counts.skipped > 0 {
            parts.append("\(counts.skipped) \(counts.skipped == 1 ? "Auslassung" : "Auslassungen")")
        }

        let appointments = pet.vetAppointments.count
        if appointments > 0 {
            parts.append("\(appointments) \(appointments == 1 ? "Tierarzttermin" : "Tierarzttermine")")
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

/// Eine Praxis auf der Notfallkarte: Rolle, Name, Ansprechpartner und
/// Anruf-Knopf.
private struct EmergencyPracticeRow: View {
    let role: String
    let practice: VetPractice
    let number: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(role)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RudelTheme.muted)
                Text(VetDisplay.practiceName(practice))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(RudelTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(RudelTheme.muted)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            VetCallButton(
                number: number,
                accessibilityName: "\(VetDisplay.practiceName(practice)) anrufen"
            )
        }
        .padding(.vertical, 2)
    }

    private var detail: String? {
        let parts = [practice.veterinarian, number]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
