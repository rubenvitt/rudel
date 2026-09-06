import Foundation
import Testing
@testable import Rudel

@Suite("Live-Activity-Verweis")
struct MedicationReminderLinkTests {
    @Test("Der Link bindet die Gabe unabhängig von einer wechselnden Systemalarm-ID")
    func stableOccurrenceLink() {
        let id = "rudel.dose.1234.1788607200"
        let link = MedicationAlarmLink.url(reminderID: id)
        #expect(MedicationAlarmLink.reminderID(from: link) == id)
        #expect(MedicationAlarmLink.reminderID(from: URL(string: "https://example.org/?reminder=\(id)")!) == nil)
        #expect(MedicationAlarmLink.reminderID(from: URL(string: "rudel://medication-reminder")!) == nil)
    }
}
