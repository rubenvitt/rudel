import SwiftUI
import UIKit

/// Native Umsetzung der Pfotenplan-Richtung. Laufzeitquelle für DESIGN.md.
enum RudelTheme {
    static let forest = adaptive(light: 0x173D33, dark: 0x173D33)
    static let cream = adaptive(light: 0xFAF7ED, dark: 0xFAF7ED)
    static let sage = adaptive(light: 0xD1E0C9, dark: 0xD1E0C9)
    static let apricot = adaptive(light: 0xF7C9A6, dark: 0xF7C9A6)
    static let accent = adaptive(light: 0x244F42, dark: 0xBDD8C3)
    static let canvas = adaptive(light: 0xF5F5ED, dark: 0x141D19)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x202D26)
    static let ink = adaptive(light: 0x203C32, dark: 0xEDF2E8)
    static let muted = adaptive(light: 0x5D6C61, dark: 0xB1C0B3)
    static let line = adaptive(light: 0xDEE5D9, dark: 0x39493F)
    static let softSage = adaptive(light: 0xE5EBDF, dark: 0x2A3D30)
    static let softApricot = adaptive(light: 0xF9E5D4, dark: 0x463529)
    static let warning = adaptive(light: 0x8E501A, dark: 0xF4BE85)
    static let danger = adaptive(light: 0xB2333E, dark: 0xFFACB2)
    static let success = adaptive(light: 0x2E654D, dark: 0xBDD8C3)
    static let cardRadius: CGFloat = 24

    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .serif, weight: .medium)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    /// Behält native Listen samt Wischaktionen und Tastaturnavigation.
    func rudelListStyle() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(RudelTheme.canvas)
            .listRowBackground(RudelTheme.surface)
            .listSectionSpacing(22)
            .environment(\.defaultMinListRowHeight, 52)
            .textCase(nil)
    }

    func rudelFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(RudelTheme.canvas)
            .tint(RudelTheme.accent)
    }

    /// Frei gestaltete Zeile innerhalb einer nativen Liste.
    func rudelFeatureRow() -> some View {
        self
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

struct RudelPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(minHeight: 52)
            .foregroundStyle(RudelTheme.cream)
            .background(RudelTheme.forest, in: .rect(cornerRadius: 18))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct RudelTileButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
            .hoverEffect(.highlight)
    }
}

struct RudelIcon: View {
    let symbol: String
    var color: Color = RudelTheme.accent
    var fill: Color = RudelTheme.softSage
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(fill, in: .rect(cornerRadius: size * 0.32))
            .accessibilityHidden(true)
    }
}

/// Ein gemeinsamer Leerzustand, mit einem tatsächlich ausführbaren Einstieg.
struct RudelEmptyState: View {
    let title: String
    let detail: String
    let symbol: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RudelIcon(symbol: symbol, size: 72)
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(RudelTheme.display())
                        .foregroundStyle(RudelTheme.ink)
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(RudelTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: action) {
                    HStack {
                        Text(actionTitle)
                        Spacer(minLength: 12)
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(RudelPrimaryButtonStyle())
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RudelTheme.surface, in: .rect(cornerRadius: RudelTheme.cardRadius))
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(RudelTheme.canvas)
    }
}

struct RudelSectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.title3, design: .serif, weight: .semibold))
                .foregroundStyle(RudelTheme.ink)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(RudelTheme.muted)
            }
        }
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RudelFeatureHeading: View {
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow).font(.caption.weight(.semibold)).foregroundStyle(RudelTheme.muted)
                Text(title).font(RudelTheme.display(.title)).foregroundStyle(RudelTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.subheadline).foregroundStyle(RudelTheme.muted)
            }
            Spacer(minLength: 0)
            RudelIcon(symbol: symbol, fill: RudelTheme.softApricot, size: 52)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RudelTheme.softSage, in: .rect(cornerRadius: RudelTheme.cardRadius))
    }
}

struct RudelQuickAction: View {
    let title: String
    let symbol: String
    var apricot = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: symbol).font(.title3)
                    Spacer()
                    Image(systemName: "plus").font(.caption.weight(.semibold))
                }
                Text(title).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(RudelTheme.ink)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(apricot ? RudelTheme.softApricot : RudelTheme.softSage,
                        in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(RudelTileButtonStyle())
    }
}

struct RudelPetHero<Detail: View>: View {
    let pet: Pet
    let eyebrow: String
    var introduction: String?
    var subtitle: String?
    @ViewBuilder let detail: Detail

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var nameSize = 42.0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(eyebrow)
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(RudelTheme.sage)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    if let introduction {
                        Text(introduction).font(RudelTheme.display(.title2))
                    }
                    Text(pet.name.isEmpty ? "Dein Tier" : pet.name)
                        .font(.system(size: nameSize, weight: .medium, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pet-hero-name")
                    if !pet.breed.isEmpty {
                        Text(pet.breed)
                            .font(.subheadline)
                            .foregroundStyle(RudelTheme.sage)
                            .padding(.top, 6)
                    }
                    if let subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(RudelTheme.sage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PetAvatar(pet: pet, size: 88)
                    .padding(7)
                    .overlay(Circle().strokeBorder(RudelTheme.sage.opacity(0.35), lineWidth: 1))
                    .accessibilityHidden(true)
            }

            Rectangle().fill(RudelTheme.sage.opacity(0.25)).frame(height: 1)
            detail
        }
        .padding(24)
        .foregroundStyle(RudelTheme.cream)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RudelTheme.forest, in: .rect(cornerRadius: RudelTheme.cardRadius))
    }
}
