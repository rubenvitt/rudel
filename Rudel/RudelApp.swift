import RudelEngine
import SwiftData
import SwiftUI

@main
struct RudelApp: App {
    /// Alle persistenten Typen an einer Stelle. Neue `@Model`-Typen müssen hier
    /// eingetragen werden, sonst sind sie zur Laufzeit unsichtbar.
    static let schema = Schema([
        Pet.self,
        MedicationPlan.self,
        MedicationEvent.self,
        DoseLogEntry.self,
        CyclePeriod.self,
        CycleObservation.self,
        SymptomEntry.self,
        WeightEntry.self,
        AppSettings.self,
    ])

    /// Der Store wird bewusst **nicht** mit `try!` geöffnet.
    ///
    /// Fällt die App bei einem Store-Fehler auf einen In-Memory-Container
    /// zurück, wirkt sie funktionsfähig, verliert aber jeden Eintrag beim
    /// Beenden — bei einer App, deren Zweck lückenlose Historie ist, der
    /// schlimmste mögliche Fehlermodus. Stattdessen wird der Fehler angezeigt
    /// und nichts geschrieben.
    private let containerResult: Result<ModelContainer, Error>

    @State private var appState = AppState()

    init() {
        // CloudKit-Sync ist in v1 aus (PRD §11: „CloudKit-Sync in v1 oder
        // später?"). Das Schema ist trotzdem CloudKit-kompatibel gebaut, siehe
        // `Pet` — Umstellung auf `.private(...)` später ohne Migration.
        let configuration = ModelConfiguration(
            schema: Self.schema,
            cloudKitDatabase: .none
        )
        containerResult = Result {
            try ModelContainer(for: Self.schema, configurations: [configuration])
        }
    }

    var body: some Scene {
        WindowGroup {
            switch containerResult {
            case .success(let container):
                RootView()
                    .environment(appState)
                    .modelContainer(container)
            case .failure(let error):
                StoreFailureView(error: error)
            }
        }
    }
}

/// Letzter Ausweg, wenn der Store nicht geöffnet werden kann. Zeigt den Fehler
/// im Klartext, statt stillschweigend ohne Persistenz weiterzulaufen.
struct StoreFailureView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Datenbank nicht verfügbar", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 12) {
                Text("Rudel kann seine Datenbank nicht öffnen. Damit keine Einträge verloren gehen, wird nichts gespeichert.")
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
