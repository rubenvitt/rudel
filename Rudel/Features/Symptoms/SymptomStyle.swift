import SwiftUI

/// Darstellung des Schweregrads (PRD §5.4).
///
/// Als eigener Namensraum statt als `SymptomSeverity`-Extension: die
/// Support-Schicht ist eingefroren, und eine `tint`-Extension auf einem
/// Modell-Enum wäre genau die Art Erweiterung, die zwei Feature-Ordner
/// unabhängig voneinander anlegen — mit einem Namenskonflikt beim Build.
enum SymptomStyle {
    /// Ampelfarben. Grün heißt nicht „harmlos", sondern „leichteste der drei
    /// dokumentierbaren Stufen" — die Skala hat keine Stufe für „unauffällig",
    /// weil ein Eintrag immer eine Beobachtung ist.
    static func tint(_ severity: SymptomSeverity) -> Color {
        switch severity {
        case .mild: return .green
        case .moderate: return .orange
        case .severe: return .red
        }
    }
}

/// Schweregrad als farbiger Punkt mit Text.
///
/// Der Text steht bewusst immer daneben: Rot gegen Grün ist für einen Teil der
/// Nutzer nicht unterscheidbar, und farbige Schrift in Grün wäre auf Weiß
/// zusätzlich kontrastarm — deshalb trägt nur der Punkt die Farbe.
struct SymptomSeverityTag: View {
    let severity: SymptomSeverity

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(SymptomStyle.tint(severity))
                .frame(width: 8, height: 8)
            Text(severity.label)
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Schweregrad \(severity.label)")
    }
}
