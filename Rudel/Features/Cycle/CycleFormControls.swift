import RudelEngine
import SwiftUI

/// Dreiwertige Auswahl für ein `Bool?`.
///
/// „Nicht beobachtet" ist ein eigener Zustand **und** die Vorbelegung. `false`
/// wäre eine Aussage, die niemand getroffen hat — und würde die Phasenschätzung
/// in Richtung Anöstrus ziehen (siehe `PhaseSignals.isEmpty`).
///
/// Menü-Stil statt Segmented Control: „Nicht beobachtet" muss als Text lesbar
/// bleiben, auch bei den großen Dynamic-Type-Stufen, wo ein Segment abschneidet.
struct CycleTriStatePicker: View {
    let title: String
    @Binding var value: Bool?
    var yesLabel: String = "Ja"
    var noLabel: String = "Nein"

    var body: some View {
        Picker(title, selection: choice) {
            Text("Nicht beobachtet").tag(CycleTriState.unknown)
            Text(yesLabel).tag(CycleTriState.yes)
            Text(noLabel).tag(CycleTriState.no)
        }
    }

    private var choice: Binding<CycleTriState> {
        Binding(
            get: { CycleTriState(value) },
            set: { value = $0.boolValue }
        )
    }
}

/// Hilfstyp für `CycleTriStatePicker` — ein `Picker` braucht einen
/// nicht-optionalen, `Hashable`-Auswahlwert.
enum CycleTriState: Hashable {
    case unknown
    case yes
    case no

    init(_ value: Bool?) {
        switch value {
        case .none: self = .unknown
        case .some(true): self = .yes
        case .some(false): self = .no
        }
    }

    var boolValue: Bool? {
        switch self {
        case .unknown: return nil
        case .yes: return true
        case .no: return false
        }
    }
}

/// Auswahl für ein optionales Enum, mit „Nicht beobachtet" als Vorbelegung.
///
/// Bei `DischargeAmount` stehen dadurch „Nicht beobachtet" und „Keiner"
/// nebeneinander. Das ist kein Versehen: kein Ausfluss ist ein Befund, keine
/// Angabe ist keiner.
struct CycleOptionalPicker<Value: Hashable & CaseIterable>: View {
    let title: String
    @Binding var value: Value?
    let label: (Value) -> String

    var body: some View {
        Picker(title, selection: $value) {
            Text("Nicht beobachtet").tag(Value?.none)
            ForEach(Array(Value.allCases), id: \.self) { option in
                Text(label(option)).tag(Value?.some(option))
            }
        }
    }
}

/// Hinweiszeile für unplausible Eingaben und Pflicht-Caveats.
///
/// Warnt, blockiert nicht: die App weiß nicht besser als der Mensch davor, ob
/// der Sonderfall echt ist. Und der Caveat des fruchtbaren Fensters steht
/// bewusst offen im Text statt hinter einem Info-Button (PRD §6.3).
struct CycleNoticeRow: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Hinweiszeile") {
    List {
        CycleNoticeRow(text: "Nur 12 Tage Abstand zu Tag 1 am 3. Mai 2026.")
        CycleNoticeRow(
            text: "Nur aus dem Verhalten geschätzt — mehrere Tage Unsicherheit.",
            systemImage: "info.circle.fill",
            tint: .secondary
        )
    }
}
