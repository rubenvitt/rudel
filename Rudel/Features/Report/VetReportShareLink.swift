import CoreTransferable
import RudelEngine
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Was geteilt wird: nur Kennungen und ein Schnappschuss des Anlasses, kein
/// Modell. Das PDF entsteht erst, wenn das Teilen-Menü die Datei anfordert.
struct VetReportRequest: Transferable, Sendable {
    let petID: UUID
    let occasion: VetReportContent.Occasion?
    let container: ModelContainer
    let dayMath: DayMath

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { request in
            let url = try await MainActor.run { try request.writeFile(asOf: Date()) }
            return SentTransferredFile(url)
        }
    }

    @MainActor
    func writeFile(asOf: Date) throws -> URL {
        let context = container.mainContext
        let target = petID
        var descriptor = FetchDescriptor<Pet>(predicate: #Predicate<Pet> { $0.id == target })
        descriptor.fetchLimit = 1
        guard let pet = try context.fetch(descriptor).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let content = VetReportContent(pet: pet, occasion: occasion, asOf: asOf, dayMath: dayMath)
        return try VetReportFile.write(VetReportRenderer.render(content), petName: content.pet.name, date: asOf, calendar: dayMath.calendar)
    }
}

enum VetReportFile {
    /// `Rudel-Bericht-<Tier>-<yyyy-MM-dd>.pdf`. Das Datum fest formatiert, nicht
    /// nach Gerätesprache — der Name soll sortierbar bleiben.
    static func fileName(petName: String, date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let cleaned = petName.components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
        return "Rudel-Bericht-\(cleaned.isEmpty ? "Tier" : cleaned)-\(formatter.string(from: date)).pdf"
    }

    /// Eigener Unterordner je Bericht, damit der Dateiname exakt bleibt, auch
    /// wenn am selben Tag zweimal geteilt wird.
    static func write(_ data: Data, petName: String, date: Date, calendar: Calendar) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VetReports", isDirectory: true)
        removeStaleReports(in: root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(petName: petName, date: date, calendar: calendar))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Ältere Berichte räumen, sobald ein neuer entsteht. Eine Stunde Abstand,
    /// damit ein gerade laufendes Teilen seine Datei nicht verliert.
    private static func removeStaleReports(in root: URL) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created, created < cutoff { try? manager.removeItem(at: folder) }
        }
    }
}

/// Teilen-Knopf für den Bericht. Überall gleich beschriftet, damit der
/// Einstieg wiedererkennbar ist.
struct VetReportShareLink: View {
    let petID: UUID
    let petName: String
    var occasion: VetReportContent.Occasion?
    var title = "Bericht für die Praxis"
    var accessibilityID = "vet-report-share"

    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState

    var body: some View {
        ShareLink(
            item: VetReportRequest(petID: petID, occasion: occasion, container: context.container, dayMath: appState.dayMath),
            preview: SharePreview("Tierarzt-Bericht \(petName)", image: Image(systemName: "doc.text"))
        ) {
            Label(title, systemImage: "doc.text")
        }
        .accessibilityIdentifier(accessibilityID)
    }
}
