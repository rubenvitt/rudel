import SwiftData

/// App und Alarmaktionen öffnen denselben Container im selben Prozess.
@MainActor
enum RudelPersistence {
    static let containerResult: Result<ModelContainer, Error> = Result {
        let configuration = ModelConfiguration(schema: RudelApp.schema, cloudKitDatabase: .none)
        return try ModelContainer(for: RudelApp.schema, configurations: [configuration])
    }
}
