import SwiftUI
import UIKit

/// Farbe eines Tiers. Färbt Tierkopf, Avatar und die Auswahl im Tierwechsler,
/// damit bei mehreren Tieren sofort klar ist, um wen es gerade geht.
///
/// Jede Farbe ist ein geprüftes Paar: `deep` trägt cream-Text (mindestens 8:1),
/// `soft` ist als Zweitschrift auf `deep` lesbar (mindestens 5,9:1) und füllt
/// den Avatar-Platzhalter. Beide Werte sind in Hell und Dunkel identisch, wie
/// forest und sage in `RudelTheme`. Der Rohwert wird gespeichert und darf sich
/// deshalb nie ändern.
enum PetColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case forest
    case lake
    case berry
    case rust
    case slate
    case plum
    case olive
    case cocoa

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forest: "Tanne"
        case .lake: "See"
        case .berry: "Beere"
        case .rust: "Rost"
        case .slate: "Schiefer"
        case .plum: "Pflaume"
        case .olive: "Oliv"
        case .cocoa: "Kakao"
        }
    }

    var deep: Color {
        switch self {
        case .forest: RudelTheme.forest
        case .lake: Self.color(0x1D3B57)
        case .berry: Self.color(0x5A2140)
        case .rust: Self.color(0x7A3418)
        case .slate: Self.color(0x33393F)
        case .plum: Self.color(0x3E2A5C)
        case .olive: Self.color(0x4A4A1C)
        case .cocoa: Self.color(0x4A3024)
        }
    }

    var soft: Color {
        switch self {
        case .forest: RudelTheme.sage
        case .lake: Self.color(0xC9DAEA)
        case .berry: Self.color(0xF0CCDC)
        case .rust: RudelTheme.apricot
        case .slate: Self.color(0xD6DCE1)
        case .plum: Self.color(0xDCD0EE)
        case .olive: Self.color(0xE3E2B8)
        case .cocoa: Self.color(0xEBD6C6)
        }
    }

    private static func color(_ value: UInt32) -> Color {
        Color(uiColor: UIColor(
            red: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255,
            alpha: 1
        ))
    }
}

/// Symbole für Tiere ohne Foto. Leer gespeichert heißt: das Art-Symbol.
enum PetSymbol {
    static let all = [
        "dog", "cat", "pawprint.fill", "heart.fill", "star.fill",
        "leaf.fill", "sun.max.fill", "moon.fill", "crown.fill", "teddybear.fill",
    ]

    /// VoiceOver-Name, damit niemand „pawprint.fill" vorgelesen bekommt.
    static func label(_ symbol: String) -> String {
        switch symbol {
        case "dog": "Hund"
        case "cat": "Katze"
        case "pawprint.fill": "Pfote"
        case "heart.fill": "Herz"
        case "star.fill": "Stern"
        case "leaf.fill": "Blatt"
        case "sun.max.fill": "Sonne"
        case "moon.fill": "Mond"
        case "crown.fill": "Krone"
        case "teddybear.fill": "Teddy"
        default: symbol
        }
    }
}

extension Pet {
    /// Symbol für Avatar-Platzhalter: eigene Wahl, sonst das Art-Symbol.
    var displaySymbol: String {
        symbolName.isEmpty ? speciesValue.symbolName : symbolName
    }
}
