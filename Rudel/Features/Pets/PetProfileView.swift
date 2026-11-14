import RudelEngine
import SwiftData
import SwiftUI

/// Profil eines Tiers (PRD §5.1): Stammdaten, Bericht, Bearbeiten, Löschen.
///
/// Wird aus dem Rudel-Tab heraus geöffnet. Der eigentliche Inhalt steckt in
/// `PetProfileContent`, damit dessen `@State` (der Löschdialog) je Tier
/// zurückgesetzt wird.
struct PetProfileView: View {
    let pet: Pet

    var body: some View {
        Group {
            if pet.isDeleted {
                // Zwischenzustand unmittelbar nach dem Löschen: das Modell ist
                // ungültig, seine Properties dürfen nicht mehr gelesen werden.
                Color.clear
            } else {
                PetProfileContent(pet: pet)
                    .id(pet.id)
            }
        }
        .rudelReadableWidth()
        .background(RudelTheme.canvas)
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
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
    @Environment(\.dismiss) private var dismiss

    /// Momentaufnahme für den Löschdialog. Siehe `PetDeletionSummary`.
    @State private var pendingDeletion: PetDeletionSummary?

    var body: some View {
        List {
            headerSection
            actionsSection
            baseDataSection
            if pet.speciesValue == .dog {
                sizeClassSection
            }
            statisticsSection
            deleteSection
        }
        .rudelListStyle()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bearbeiten") {
                    appState.present(.editPet(petID: pet.id))
                }
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
            RudelPetHero(pet: pet, eyebrow: String(localized: "DEIN RUDEL")) {
                HStack(alignment: .firstTextBaseline) {
                    Label(pet.speciesValue.label, systemImage: pet.speciesValue.symbolName)
                    Spacer(minLength: 12)
                    Text(ageText ?? String(localized: "Geburtstag noch nicht erfasst"))
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .foregroundStyle(pet.colorValue.soft)
            }
            .rudelFeatureRow()
        }
    }

    private var baseDataSection: some View {
        Section {
            LabeledValueRow(
                label: String(localized: "Art"),
                value: pet.speciesValue.label,
                systemImage: pet.speciesValue.symbolName
            )

            if !pet.breed.isEmpty {
                LabeledValueRow(label: String(localized: "Rasse"), value: pet.breed, systemImage: "list.bullet")
            }

            LabeledValueRow(
                label: String(localized: "Geburtsdatum"),
                value: pet.birthDate.map(Format.date) ?? String(localized: "Nicht erfasst"),
                systemImage: "birthday.cake"
            )

            LabeledValueRow(
                label: String(localized: "Geschlecht"),
                value: pet.isFemale ? String(localized: "Weiblich") : String(localized: "Männlich"),
                systemImage: "figure.stand.dress.line.vertical.figure"
            )

            LabeledValueRow(
                label: String(localized: "Kastriert"),
                value: pet.isNeutered ? String(localized: "Ja") : String(localized: "Nein"),
                systemImage: "cross.case"
            )

            LabeledValueRow(
                label: String(localized: "Zielbereich Gewicht"),
                value: weightTargetText ?? String(localized: "Nicht festgelegt"),
                systemImage: "scalemass"
            )

            if let latest = pet.latestWeightKg {
                LabeledValueRow(
                    label: String(localized: "Letztes Gewicht"),
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
                label: String(localized: "Größenklasse"),
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
                label: String(localized: "Gaben"),
                value: "\(medicationCounts.given)",
                systemImage: "pills"
            )

            if showsCycleCount {
                LabeledValueRow(
                    label: String(localized: "Läufigkeiten"),
                    value: "\(pet.cyclePeriods.count)",
                    systemImage: "circle.hexagonpath"
                )
            }

            LabeledValueRow(
                label: String(localized: "Symptome"),
                value: "\(pet.symptomEntries.count)",
                systemImage: "stethoscope"
            )

            LabeledValueRow(
                label: String(localized: "Gewichtseinträge"),
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
                Label("Profil bearbeiten", systemImage: "square.and.pencil")
            }

            VetReportShareLink(petID: pet.id, petName: pet.name, title: String(localized: "Tierarzt-Bericht teilen"))
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
        pet.name.isEmpty ? String(localized: "Unbenannt") : pet.name
    }

    /// Alter als „3 Jahre, 4 Monate". Kein `Format`-Helfer vorhanden, deshalb
    /// hier formuliert.
    private var ageText: String? {
        guard let parts = pet.ageComponents() else { return nil }
        let years = parts.years
        let months = parts.months

        if years == 0 && months == 0 { return String(localized: "Wenige Tage alt") }
        let yearText = String(localized: "\(years) Jahre", comment: "Alter in Jahren")
        let monthText = String(localized: "\(months) Monate", comment: "Alter in Monaten")
        if years == 0 { return monthText }
        if months == 0 { return yearText }
        return String(localized: "\(yearText), \(monthText)", comment: "Alter aus Jahren und Monaten, z. B. „3 Jahre, 4 Monate“")
    }

    private var weightTargetText: String? {
        let minKg = pet.weightTargetMinKg
        let maxKg = pet.weightTargetMaxKg
        guard minKg > 0 || maxKg > 0 else { return nil }
        if minKg > 0 && maxKg > 0 {
            // Die Einheit nur einmal nennen — „22 kg – 28 kg" liest sich zäh.
            return "\(plainNumber(minKg)) – \(Format.weight(maxKg))"
        }
        if minKg > 0 { return String(localized: "ab \(Format.weight(minKg))", comment: "Zielgewicht nur mit Untergrenze") }
        return String(localized: "bis \(Format.weight(maxKg))", comment: "Zielgewicht nur mit Obergrenze")
    }

    private func plainNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Macht sichtbar, dass Loggen etwas bringt: die Einträge sind nicht Archiv,
    /// sie sind die Rechengrundlage.
    private var statisticsFooter: String {
        guard showsCycleCount else {
            return String(localized: "Diese Einträge sind die Rechengrundlage: die Fälligkeiten kommen aus den Gaben. Je länger die Historie, desto belastbarer die Prognose.")
        }
        return String(localized: "Diese Einträge sind die Rechengrundlage: die Fälligkeiten kommen aus den Gaben, die Zyklusprognose aus den Tag-1-Daten der Läufigkeiten. Je mehr eigene Zyklen erfasst sind, desto engere Spannen zeigt Rudel.")
    }

    /// Hinweis für unkastrierte Katzen: hier fehlt das Zyklus-Modul mit Absicht.
    private var baseDataFooter: String? {
        guard pet.speciesValue == .cat, pet.isFemale, !pet.isNeutered else { return nil }
        return String(localized: "Für Katzen gibt es keine Zyklusprognose, ihr Zyklus lässt sich nicht verlässlich vorhersagen.")
    }

    private var sizeClassFooter: String {
        // Ganze Sätze, die nur mit Leerzeichen aneinandergereiht werden.
        let origin = pet.sizeClassOverride == nil
            ? (pet.latestWeightKg == nil
                ? String(localized: "Ohne Gewichtseintrag greift Rudel auf „Mittel“ zurück.")
                : String(localized: "Automatisch aus dem letzten Gewichtseintrag abgeleitet."))
            : String(localized: "Manuell festgelegt.")

        guard pet.tracksCycle else {
            let noEffect = String(localized: "Die Klasse wirkt nur auf die Zyklusprognose und bleibt für dieses Tier ohne Effekt.")
            return "\(origin) \(noEffect)"
        }

        let bias = StudyConstants.intervalBiasDays(for: pet.effectiveSizeClass)
        let effect: String
        if bias == 0 {
            effect = String(localized: "Sie verschiebt den Startwert der Zyklusprognose nicht.")
        } else if bias > 0 {
            effect = String(localized: "Sie verschiebt den Startwert der Zyklusprognose um +\(bias) Tage.", comment: "Größenklasse verschiebt den Startwert nach hinten")
        } else {
            effect = String(localized: "Sie verschiebt den Startwert der Zyklusprognose um −\(abs(bias)) Tage.", comment: "Größenklasse verschiebt den Startwert nach vorn")
        }
        let ownIntervals = String(localized: "Sobald eigene Intervalle geloggt sind, überstimmen sie diesen Startwert.")
        return "\(origin) \(effect) \(ownIntervals)"
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
            parts.append(String(localized: "\(planCount) Medikamentenpläne"))
        }

        let counts = medicationCounts
        if counts.given > 0 {
            parts.append(String(localized: "\(counts.given) Gaben"))
        }
        // Die Kaskade löscht Auslassungen mit — der Dialog muss sie nennen.
        if counts.skipped > 0 {
            parts.append(String(localized: "\(counts.skipped) Auslassungen"))
        }

        let appointments = pet.vetAppointments.count
        if appointments > 0 {
            parts.append(String(localized: "\(appointments) Tierarzttermine"))
        }

        let periods = pet.cyclePeriods.count
        if periods > 0 {
            let observations = pet.cyclePeriods.reduce(0) { $0 + $1.observations.count }
            let periodText = String(localized: "\(periods) Läufigkeiten")
            if observations > 0 {
                let observationText = String(localized: "\(observations) Beobachtungen")
                parts.append(String(
                    localized: "\(periodText) mit \(observationText)",
                    comment: "Löschdialog, z. B. „2 Läufigkeiten mit 14 Beobachtungen“"
                ))
            } else {
                parts.append(periodText)
            }
        }

        let symptoms = pet.symptomEntries.count
        if symptoms > 0 {
            parts.append(String(localized: "\(symptoms) Symptome"))
        }

        let weights = pet.weightEntries.count
        if weights > 0 {
            parts.append(String(localized: "\(weights) Gewichtseinträge"))
        }

        let name = displayName
        let message: String
        if parts.isEmpty {
            message = String(localized: "Für \(name) sind noch keine Einträge erfasst. Es wird nur das Profil gelöscht.")
        } else {
            message = String(localized: "Mit \(name) werden \(enumerated(parts)) gelöscht. Das lässt sich nicht rückgängig machen.")
        }

        return PetDeletionSummary(name: name, message: message)
    }

    /// „a, b und c" — Aufzählung in der Sprache des Geräts statt einer Komma-Liste.
    private func enumerated(_ parts: [String]) -> String {
        parts.formatted(.list(type: .and))
    }

    private func delete() {
        // Auswahl **vor** dem Löschen umlenken: sonst zeigt `PetScope` für einen
        // Frame ein Modell, das gleich ungültig ist. `RootView.syncSelection()`
        // würde das auch reparieren, aber erst nach dem Löschen.
        let remaining = ((try? context.fetch(FetchDescriptor<Pet>())) ?? [])
            .filter { $0.id != pet.id }
            .sorted { $0.createdAt < $1.createdAt }
        appState.selectedPetID = remaining.first?.id

        pendingDeletion = nil
        dismiss()
        context.delete(pet)
        try? context.save()
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
