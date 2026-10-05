import Foundation
import RudelEngine
import SwiftData

/// Anlass eines Tierarzttermins. Bestimmt Symbol und vorgeschlagenen Titel;
/// der Freitext in `VetAppointment.title` bleibt maßgeblich.
enum VetVisitReason: String, Codable, CaseIterable, Hashable, Sendable {
    case checkup
    case vaccination
    case illness
    case followUp
    case surgery
    case dental
    case other

    var label: String {
        switch self {
        case .checkup: return "Vorsorge-Check"
        case .vaccination: return "Impfung"
        case .illness: return "Krankheit"
        case .followUp: return "Kontrolle"
        case .surgery: return "Operation"
        case .dental: return "Zähne"
        case .other: return "Sonstiges"
        }
    }

    var symbolName: String {
        switch self {
        case .checkup: return "stethoscope"
        case .vaccination: return "syringe"
        case .illness: return "cross.case"
        case .followUp: return "arrow.triangle.2.circlepath"
        case .surgery: return "bandage"
        case .dental: return "mouth"
        case .other: return "ellipsis.circle"
        }
    }
}

enum AppointmentStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case planned
    case done
    case cancelled

    var label: String {
        switch self {
        case .planned: return "Geplant"
        case .done: return "Erledigt"
        case .cancelled: return "Abgesagt"
        }
    }
}

/// Eine Tierarztpraxis oder Tierklinik. Tierübergreifend: mehrere Tiere teilen
/// sich meist dieselbe Praxis, und eine Notfallklinik gilt für alle.
///
/// CloudKit-Regeln wie bei `Pet`. Jede To-One-Beziehung auf eine Praxis hat
/// hier ihr To-Many-Gegenstück; Löschen einer Praxis lässt Termine und Tiere
/// bestehen (nullify) — die Historie eines Termins hängt nicht an der Praxis.
@Model
final class VetPractice {
    var id: UUID = UUID()
    var name: String = ""
    /// Ansprechpartner, z. B. „Dr. Weber".
    var veterinarian: String = ""
    var phone: String = ""
    /// Nummer für Notfälle außerhalb der Sprechzeiten, falls abweichend.
    var emergencyPhone: String = ""
    var email: String = ""
    var address: String = ""
    var openingHours: String = ""
    /// Tierklinik mit Notdienst. Die Notfallkarte im Profil zeigt diese Praxen
    /// zusätzlich zum Haustierarzt.
    var isEmergencyClinic: Bool = false
    var notes: String = ""
    var createdAt: Date = Date.distantPast

    @Relationship(deleteRule: .nullify, inverse: \VetAppointment.practice)
    var appointments: [VetAppointment] = []

    @Relationship(deleteRule: .nullify, inverse: \Pet.primaryPractice)
    var primaryForPets: [Pet] = []

    init(
        name: String = "",
        veterinarian: String = "",
        phone: String = "",
        emergencyPhone: String = "",
        email: String = "",
        address: String = "",
        openingHours: String = "",
        isEmergencyClinic: Bool = false,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.name = name
        self.veterinarian = veterinarian
        self.phone = phone
        self.emergencyPhone = emergencyPhone
        self.email = email
        self.address = address
        self.openingHours = openingHours
        self.isEmergencyClinic = isEmergencyClinic
        self.notes = notes
        self.createdAt = createdAt
    }
}

/// Ein Tierarzttermin — geplant, erledigt oder abgesagt.
///
/// Anders als das Gabe-Journal ist ein Termin bearbeitbar: vorher stehen
/// Fragen an die Praxis drin, nachher Befund und Kosten. Ein erledigter Termin
/// wird nicht gelöscht, sondern bleibt als Krankengeschichte stehen.
@Model
final class VetAppointment {
    var id: UUID = UUID()
    /// Termin mit Uhrzeit.
    var date: Date = Date.distantPast
    var reasonValue: VetVisitReason = VetVisitReason.checkup
    var title: String = ""
    /// Was beim Termin angesprochen werden soll.
    var preparationNotes: String = ""
    /// Befund, Diagnose, Empfehlungen der Praxis.
    var findings: String = ""
    /// Kosten in Euro. `0` = nicht erfasst.
    var costEuro: Double = 0
    var statusValue: AppointmentStatus = AppointmentStatus.planned
    var createdAt: Date = Date.distantPast

    /// Wann der Termin über den System-Editor in einen Kalender übernommen
    /// wurde. Rudel hat nur Schreibzugriff über die Systemansicht und kann den
    /// Eintrag danach weder lesen noch nachziehen.
    var calendarExportedAt: Date?
    /// Das damals exportierte Termindatum. Weicht `date` davon ab, steht der
    /// Kalendereintrag auf dem alten Termin.
    var calendarExportedDate: Date?

    var pet: Pet?
    var practice: VetPractice?
    /// Die Vorsorge, für die der Termin vereinbart wurde (z. B. Tollwut-Impfung).
    /// Solange der Termin geplant ist, übernimmt er deren Erinnerungen.
    var medicationPlan: MedicationPlan?

    init(
        date: Date,
        reason: VetVisitReason = .checkup,
        title: String = "",
        preparationNotes: String = "",
        findings: String = "",
        costEuro: Double = 0,
        status: AppointmentStatus = .planned,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.date = date
        self.reasonValue = reason
        self.title = title
        self.preparationNotes = preparationNotes
        self.findings = findings
        self.costEuro = costEuro
        self.statusValue = status
        self.createdAt = createdAt
    }
}

extension VetAppointment {
    /// Titel für Listen und Mitteilungen: Freitext, sonst der Anlass.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? reasonValue.label : trimmed
    }

    var isOpen: Bool { statusValue == .planned }

    /// Exportiert, aber das Termindatum hat sich seither geändert.
    func calendarEntryIsStale(comparedTo currentDate: Date) -> Bool {
        guard let calendarExportedDate else { return false }
        return calendarExportedDate != currentDate
    }

    var engineID: String { id.uuidString }

    /// Nur geplante Termine eines Tiers erscheinen in Fälligkeiten und
    /// Mitteilungen; erledigte und abgesagte sind Historie.
    func engineInput() -> DueItemBuilder.AppointmentInput? {
        guard isOpen, let pet else { return nil }
        let place = practice.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        return DueItemBuilder.AppointmentInput(
            sourceID: engineID,
            petID: pet.engineID,
            petName: pet.name,
            title: displayTitle,
            detail: place,
            at: date,
            linkedMedicationSourceID: medicationPlan?.engineID
        )
    }
}
