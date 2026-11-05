import SwiftData
import SwiftUI

/// Gesundheit-Tab: Übersicht über Zyklus, Symptome und Gewicht (PRD §5.3–5.5).
///
/// Jeder Bereich hat seine eigene Seite. Die Übersicht zeigt pro Bereich den
/// letzten Stand, damit man oft gar nicht erst hineintippen muss. Der Zyklus
/// erscheint nur für Tiere, die ihn brauchen — als Zeile, nicht als eigener
/// Tab, damit die Tab-Leiste für jedes Tier gleich bleibt.
struct HealthView: View {
    var body: some View {
        PetScope(title: "Gesundheit") { pet in
            HealthOverview(pet: pet)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        RudelAddMenu {
                            HealthAddItems(pet: pet)
                        }
                    }
                }
        }
    }
}

/// Die Einträge des „+“-Menüs im Gesundheit-Tab.
private struct HealthAddItems: View {
    let pet: Pet

    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.present(.logSymptom(petID: pet.id))
        } label: {
            Label("Symptom erfassen", systemImage: "stethoscope")
        }
        Button {
            appState.present(.logWeight(petID: pet.id))
        } label: {
            Label("Gewicht erfassen", systemImage: "scalemass")
        }
        if pet.tracksCycle {
            Button {
                appState.present(.logCycleObservation(petID: pet.id))
            } label: {
                Label("Zyklus-Beobachtung", systemImage: "drop")
            }
            Button {
                appState.present(.startCyclePeriod(petID: pet.id))
            } label: {
                Label("Läufigkeit begonnen", systemImage: "calendar.badge.plus")
            }
        }
    }
}

private struct HealthOverview: View {
    let pet: Pet

    /// Abfragen statt `pet.symptomEntries` usw.: nur so aktualisiert sich die
    /// Übersicht, wenn ein Sheet speichert.
    @Query(sort: \SymptomEntry.date, order: .reverse) private var allSymptoms: [SymptomEntry]
    @Query(sort: \WeightEntry.date, order: .reverse) private var allWeights: [WeightEntry]
    @Query(sort: \CyclePeriod.day1Date, order: .reverse) private var allPeriods: [CyclePeriod]

    private var symptoms: [SymptomEntry] { allSymptoms.filter { $0.pet?.id == pet.id } }
    private var weights: [WeightEntry] { allWeights.filter { $0.pet?.id == pet.id } }
    private var periods: [CyclePeriod] { allPeriods.filter { $0.pet?.id == pet.id } }

    var body: some View {
        List {
            Section {
                if pet.tracksCycle {
                    NavigationLink {
                        CycleOverviewPage(pet: pet)
                    } label: {
                        HealthAreaRow(
                            title: "Zyklus",
                            detail: cycleDetail,
                            symbol: "circle.hexagonpath"
                        )
                    }
                    .accessibilityIdentifier("health-cycle")
                }
                NavigationLink {
                    SymptomHistorySection(pet: pet)
                        .healthPage(title: "Symptome") {
                            AddButton(title: "Symptom erfassen", sheet: .logSymptom(petID: pet.id))
                        }
                } label: {
                    HealthAreaRow(title: "Symptome", detail: symptomDetail, symbol: "heart.text.square")
                }
                .accessibilityIdentifier("health-symptoms")
                NavigationLink {
                    WeightHistorySection(pet: pet)
                        .healthPage(title: "Gewicht") {
                            AddButton(title: "Gewicht erfassen", sheet: .logWeight(petID: pet.id))
                        }
                } label: {
                    HealthAreaRow(title: "Gewicht", detail: weightDetail, symbol: "scalemass")
                }
                .accessibilityIdentifier("health-weight")
            } header: {
                RudelSectionHeading(title: "Bereiche")
            } footer: {
                Text("Tierarzttermine, Praxen und die Notfallkarte findest du im Tab Tierarzt.")
            }
        }
        .rudelListStyle()
    }

    private var cycleDetail: String {
        guard let latest = periods.first else { return "Noch keine Läufigkeit erfasst" }
        return "Letzte Läufigkeit ab \(Format.date(latest.day1Date))"
    }

    private var symptomDetail: String {
        guard let latest = symptoms.first else { return "Noch nichts erfasst" }
        let count = symptoms.count == 1 ? "1 Eintrag" : "\(symptoms.count) Einträge"
        return "\(count) · zuletzt \(Format.date(latest.date))"
    }

    private var weightDetail: String {
        guard let latest = weights.first else { return "Noch nicht gewogen" }
        return "\(Format.weight(latest.valueKg)) am \(Format.date(latest.date))"
    }
}

/// Eine Zeile der Übersicht: Symbol, Bereich, letzter Stand.
private struct HealthAreaRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            RudelIcon(symbol: symbol, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(RudelTheme.ink)
                Text(detail).font(.subheadline).foregroundStyle(RudelTheme.muted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Plus-Knopf einer Unterseite: legt genau das an, worum es auf der Seite geht.
private struct AddButton: View {
    let title: String
    let sheet: AppState.Sheet

    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.present(sheet)
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel(title)
    }
}

extension View {
    /// Gemeinsamer Rahmen für die Unterseiten im Gesundheit-Tab.
    func healthPage<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        let item = trailing()
        return self
            .rudelReadableWidth()
            .background(RudelTheme.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { item }
            }
    }
}
