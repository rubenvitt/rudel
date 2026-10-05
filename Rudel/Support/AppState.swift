import Foundation
import Observation
import RudelEngine
import SwiftUI

/// Sitzungs-Zustand, der nicht in die Datenbank gehört: welches Tier gerade
/// gewählt ist, welcher Tab offen ist, welches Sheet gerade präsentiert wird.
///
/// Bewusst schlank. Alles, was persistent sein muss, liegt in `AppSettings`;
/// alles, was aus der Datenbank ableitbar ist, wird per `@Query` in der View
/// geholt, nicht hier gespiegelt.
@MainActor
@Observable
final class AppState {
    /// Gewähltes Tier. `nil` = noch keins angelegt oder gewählt.
    var selectedPetID: UUID?

    var selectedTab: Tab = .today

    /// Aktuell offenes Sheet. Ein einziger Zustand statt mehrerer
    /// `@State`-Booleans, damit sich nie zwei Sheets überlagern können.
    var presentedSheet: Sheet?

    enum Tab: Hashable {
        case today
        case medication
        case cycle
        case health
        case profile
    }

    enum Sheet: Hashable, Identifiable {
        case quickLogMedication(petID: UUID, planID: UUID? = nil)
        case medicationReminder(reminderID: String)
        case editMedicationPlan(planID: UUID?, petID: UUID)
        case logCycleObservation(petID: UUID)
        case startCyclePeriod(petID: UUID)
        case logSymptom(petID: UUID)
        case logWeight(petID: UUID)
        case editPet(petID: UUID?)
        /// Zurückstellen eines Vorsorge-Plans (Datum wählen).
        case deferMedication(planID: UUID)
        /// Vorrat aufgefüllt: neuen Bestand erfassen.
        case restockMedication(planID: UUID)
        /// `appointmentID == nil` ⇒ neuer Termin, optional vorbelegt mit dem
        /// Plan, für den er vereinbart wird.
        case editAppointment(appointmentID: UUID?, petID: UUID, planID: UUID? = nil)
        case editPractice(practiceID: UUID?)
        case settings

        var id: String {
            switch self {
            case .quickLogMedication(let petID, let planID): return "quickLogMedication-\(petID)-\(planID?.uuidString ?? "")"
            case .medicationReminder(let reminderID): return "medicationReminder-\(reminderID)"
            case .editMedicationPlan(let planID, let petID):
                return "editMedicationPlan-\(planID?.uuidString ?? "new")-\(petID)"
            case .logCycleObservation(let petID): return "logCycleObservation-\(petID)"
            case .startCyclePeriod(let petID): return "startCyclePeriod-\(petID)"
            case .logSymptom(let petID): return "logSymptom-\(petID)"
            case .logWeight(let petID): return "logWeight-\(petID)"
            case .editPet(let petID): return "editPet-\(petID?.uuidString ?? "new")"
            case .deferMedication(let planID): return "deferMedication-\(planID)"
            case .restockMedication(let planID): return "restockMedication-\(planID)"
            case .editAppointment(let appointmentID, let petID, let planID):
                return "editAppointment-\(appointmentID?.uuidString ?? "new")-\(petID)-\(planID?.uuidString ?? "")"
            case .editPractice(let practiceID): return "editPractice-\(practiceID?.uuidString ?? "new")"
            case .settings: return "settings"
            }
        }
    }

    /// Kalender-Rechnung in der Zeitzone des Geräts — „heute" muss dem
    /// entsprechen, was der Nutzer auf dem Bildschirm sieht.
    let dayMath = DayMath.current()

    func present(_ sheet: Sheet) {
        presentedSheet = sheet
    }

    func dismissSheet() {
        presentedSheet = nil
    }
}
