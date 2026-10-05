import Foundation
import SwiftUI

/// Aufbereitung für Praxen und Termine — an einer Stelle, weil Tierarzt-Bereich,
/// Termin-Sheet und Notfallkarte im Profil dieselben Telefon- und Eurowerte
/// zeigen.
enum VetDisplay {

    /// `tel:`-Adresse aus einer frei eingegebenen Nummer. Leerzeichen,
    /// Schrägstriche und Bindestriche aus „0221 / 12 34-5" würden die URL
    /// ungültig machen; erhalten bleiben Ziffern und ein führendes „+".
    /// `nil`, wenn keine Ziffer übrig bleibt.
    static func phoneURL(_ number: String) -> URL? {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let prefix = trimmed.hasPrefix("+") ? "+" : ""
        return URL(string: "tel:\(prefix)\(digits)")
    }

    /// Eurobetrag aus dem Textfeld. Deutsche Tastatur liefert das Komma, aus
    /// anderen Quellen eingefügt kommt der Punkt — beides zulassen.
    static func parseEuro(_ text: String) -> EuroField {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "€", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value >= 0 else { return .invalid }
        return .value(value)
    }

    /// Vorbelegung des Kostenfeldes, ohne Tausendertrennzeichen (siehe
    /// `PetWeightField.text(for:)` — derselbe Grund).
    static func euroText(_ value: Double) -> String {
        guard value > 0 else { return "" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    static func euro(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR"))
    }

    static func practiceName(_ practice: VetPractice) -> String {
        let trimmed = practice.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Praxis ohne Namen" : trimmed
    }
}

/// Zustand des Kostenfeldes: „leer" (= nicht erfasst) und „unlesbar" müssen
/// unterscheidbar sein, sonst würde ein Tippfehler stumm als 0 gespeichert.
enum EuroField: Equatable {
    case empty
    case invalid
    case value(Double)

    var amount: Double {
        if case .value(let value) = self { return value }
        return 0
    }

    var isInvalid: Bool { self == .invalid }
}

/// Anruf-Knopf für eine Praxisnummer. Ein `Link` statt eines Buttons: das
/// System übernimmt die Rückfrage vor dem Wählen.
///
/// `.borderless`, weil der Knopf meist in einer antippbaren Listenzeile steht —
/// ohne das schluckt die Zeile den Tipp.
struct VetCallButton: View {
    let number: String
    /// Für VoiceOver: wen der Knopf anruft, z. B. „Praxis Weber anrufen".
    let accessibilityName: String
    var title: String?

    var body: some View {
        if let url = VetDisplay.phoneURL(number) {
            Link(destination: url) {
                if let title {
                    Label(title, systemImage: "phone.fill")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Image(systemName: "phone.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(RudelTheme.softSage, in: .circle)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(RudelTheme.accent)
            .accessibilityLabel(accessibilityName)
        }
    }
}
