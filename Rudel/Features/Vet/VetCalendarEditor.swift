import EventKit
import EventKitUI
import SwiftUI

/// Vorbelegung eines Kalendereintrags für einen Tierarzttermin. Ein Wert, damit
/// das Formular den aktuellen (auch ungespeicherten) Stand übergeben kann.
struct VetCalendarDraft: Equatable {
    var title: String
    var start: Date
    var location: String?
    var notes: String?

    /// Ein Termin dauert selten länger; im Kalender lässt sich das anpassen.
    static let duration: TimeInterval = 60 * 60

    init(petName: String, appointmentTitle: String, start: Date, practice: VetPractice?, questions: String) {
        title = "Tierarzt: \(petName) – \(appointmentTitle)"
        self.start = start

        let place = practice.map { practice in
            [VetDisplay.practiceName(practice), practice.address]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        location = place.flatMap { $0.isEmpty ? nil : $0 }

        var noteParts: [String] = []
        let trimmedQuestions = questions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuestions.isEmpty {
            noteParts.append("Fragen an die Praxis:\n\(trimmedQuestions)")
        }
        if let phone = practice?.phone.trimmingCharacters(in: .whitespacesAndNewlines), !phone.isEmpty {
            noteParts.append("Telefon: \(phone)")
        }
        notes = noteParts.isEmpty ? nil : noteParts.joined(separator: "\n\n")
    }
}

/// Der System-Editor für Kalendereinträge. Seit iOS 17 läuft er außerhalb der
/// App und braucht keine Kalenderberechtigung — Rudel fragt deshalb nie nach
/// Zugriff und liest den gesicherten Eintrag auch nicht zurück.
struct VetCalendarEditor: UIViewControllerRepresentable {
    let draft: VetCalendarDraft
    /// `true`, wenn der Eintrag gesichert wurde.
    let onComplete: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.start.addingTimeInterval(VetCalendarDraft.duration)
        event.location = draft.location
        event.notes = draft.notes
        // Kein Alarm am Ereignis: Rudel erinnert selbst an Termine, ein
        // zweiter Hinweis aus dem Kalender wäre doppelt.
        event.alarms = nil

        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        // `editViewDelegate`, nicht `delegate` — Letzteres ist der
        // UINavigationController-Delegate.
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {
        context.coordinator.onComplete = onComplete
    }

    /// EventKitUI ruft den Delegate auf dem Main Thread, ist aber nicht als
    /// `@MainActor` annotiert — daher `@preconcurrency`.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
        var onComplete: (Bool) -> Void

        init(onComplete: @escaping (Bool) -> Void) {
            self.onComplete = onComplete
        }

        func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            onComplete(action == .saved)
        }
    }
}
