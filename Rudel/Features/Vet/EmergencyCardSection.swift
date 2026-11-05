import SwiftData
import SwiftUI

/// Notfallkarte eines Tiers: Haustierarzt, Notdienste, Chipnummer, Allergien,
/// Versicherung. Steht oben im Tierarzt-Tab, weil man sie in der Hektik dort
/// sucht, wo auch die Praxen stehen.
struct EmergencyCardSection: View {
    let pet: Pet

    @Environment(AppState.self) private var appState

    /// Notfallkliniken gelten für alle Tiere, deshalb die Abfrage über alle
    /// Praxen statt über das Tier.
    @Query(sort: \VetPractice.name) private var practices: [VetPractice]

    var body: some View {
        emergencySection
    }

    /// Notfallkarte: was man in der Hektik braucht, ohne zu suchen. Fehlende
    /// Angaben bleiben sichtbar, damit klar ist, was noch einzutragen wäre.
    private var emergencySection: some View {
        Section {
            primaryPracticeRow

            ForEach(emergencyClinics) { clinic in
                EmergencyPracticeRow(
                    role: "Notdienst",
                    practice: clinic,
                    number: clinic.emergencyPhone.isEmpty ? clinic.phone : clinic.emergencyPhone
                )
            }

            emergencyValueRow(
                label: "Chipnummer",
                value: pet.microchipNumber,
                systemImage: "wave.3.right",
                monospaced: true
            )
            emergencyValueRow(label: "Allergien", value: pet.allergies, systemImage: "allergens")
            emergencyValueRow(label: "Versicherung", value: pet.insuranceInfo, systemImage: "doc.text")

            if hasMissingEmergencyData {
                Button {
                    appState.present(.editPet(petID: pet.id))
                } label: {
                    Label("Notfalldaten ergänzen", systemImage: "square.and.pencil")
                }
            }
        } header: {
            RudelSectionHeading(title: "Notfall")
        }
    }

    @ViewBuilder
    private var primaryPracticeRow: some View {
        if let practice = pet.primaryPractice {
            EmergencyPracticeRow(role: "Haustierarzt", practice: practice, number: practice.phone)
            if !practice.emergencyPhone.isEmpty {
                HStack {
                    LabeledValueRow(
                        label: "Notfallnummer",
                        value: practice.emergencyPhone,
                        systemImage: "phone.badge.waveform"
                    )
                    VetCallButton(
                        number: practice.emergencyPhone,
                        accessibilityName: "Notfallnummer von \(VetDisplay.practiceName(practice)) anrufen"
                    )
                }
            }
        } else {
            LabeledValueRow(label: "Haustierarzt", value: "Nicht hinterlegt", systemImage: "stethoscope")
        }
    }

    /// Die Hauspraxis steht schon oben, auch wenn sie Notdienst hat.
    private var emergencyClinics: [VetPractice] {
        practices.filter { $0.isEmergencyClinic && $0.id != pet.primaryPractice?.id }
    }

    /// Allergien und Versicherung dürfen zu Recht leer sein; der Einstieg
    /// erscheint nur für die Angaben, die praktisch jedes Tier hat.
    private var hasMissingEmergencyData: Bool {
        pet.primaryPractice == nil || pet.microchipNumber.isEmpty
    }

    /// Wert einer Notfallangabe. Text auswählbar, damit sich etwa die
    /// Chipnummer kopieren und in ein Register einfügen lässt.
    private func emergencyValueRow(
        label: String,
        value: String,
        systemImage: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(RudelTheme.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(label)
            Spacer(minLength: 12)
            if value.isEmpty {
                Text("Nicht erfasst")
                    .foregroundStyle(RudelTheme.muted)
            } else {
                Text(value)
                    .monospaced(monospaced)
                    .foregroundStyle(RudelTheme.ink)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Eine Praxis auf der Notfallkarte: Rolle, Name, Ansprechpartner und
/// Anruf-Knopf.
struct EmergencyPracticeRow: View {
    let role: String
    let practice: VetPractice
    let number: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(role)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RudelTheme.muted)
                Text(VetDisplay.practiceName(practice))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(RudelTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(RudelTheme.muted)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            VetCallButton(
                number: number,
                accessibilityName: "\(VetDisplay.practiceName(practice)) anrufen"
            )
        }
        .padding(.vertical, 2)
    }

    private var detail: String? {
        let parts = [practice.veterinarian, number]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
