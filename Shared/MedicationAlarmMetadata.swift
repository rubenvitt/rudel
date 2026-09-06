import AlarmKit
import Foundation

struct MedicationAlarmMetadata: AlarmMetadata {
    var reminderID: String
    var petName: String
    var medication: String
    var dose: String
    var dueAt: Date
}

enum MedicationAlarmLink {
    static func url(reminderID: String) -> URL {
        var components = URLComponents()
        components.scheme = "rudel"
        components.host = "medication-reminder"
        components.queryItems = [URLQueryItem(name: "reminder", value: reminderID)]
        return components.url!
    }

    static func reminderID(from url: URL) -> String? {
        guard url.scheme == "rudel", url.host == "medication-reminder",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "reminder" })?.value, !id.isEmpty else { return nil }
        return id
    }
}
