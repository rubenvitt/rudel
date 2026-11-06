import SwiftUI

/// Tierarzt-Tab: alles, was man beim Tierarzt oder im Notfall braucht, an
/// einem Ort — Notfallkarte, Termine, Praxen, Bericht.
struct VetTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        PetScope(title: "Tierarzt") { pet in
            VetSection(pet: pet)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        RudelAddMenu(accessibilityID: "vet-add-menu") {
                            Button {
                                appState.present(.editAppointment(appointmentID: nil, petID: pet.id))
                            } label: {
                                Label("Termin", systemImage: "calendar.badge.plus")
                            }
                            Button {
                                appState.present(.editPractice(practiceID: nil))
                            } label: {
                                Label("Praxis", systemImage: "building.2")
                            }
                            Button {
                                appState.present(.editPet(petID: pet.id))
                            } label: {
                                Label("Notfalldaten", systemImage: "cross.case")
                            }
                        }
                    }
                }
        }
    }
}
