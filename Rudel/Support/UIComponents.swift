import RudelEngine
import SwiftUI

// MARK: - Dringlichkeit

extension Urgency {
    var label: String {
        switch self {
        case .overdue: return "Überfällig"
        case .dueToday: return "Heute"
        case .dueSoon: return "Bald"
        case .upcoming: return "Ansteht"
        case .scheduled: return "Geplant"
        }
    }

    var tint: Color {
        switch self {
        case .overdue: return .red
        case .dueToday: return .orange
        case .dueSoon: return .yellow
        case .upcoming: return .blue
        case .scheduled: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .overdue: return "exclamationmark.triangle.fill"
        case .dueToday: return "bell.fill"
        case .dueSoon: return "clock.fill"
        case .upcoming: return "calendar"
        case .scheduled: return "calendar"
        }
    }
}

/// Kleine farbige Kapsel für die Dringlichkeit.
struct UrgencyBadge: View {
    let urgency: Urgency

    var body: some View {
        Label(urgency.label, systemImage: urgency.symbolName)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(urgency.tint.opacity(0.15), in: .capsule)
            .foregroundStyle(urgency.tint)
    }
}

/// Restwirksamkeit als Prozentbalken (PRD §5.2).
///
/// Der Balken zeigt nur die verbleibende Wirkung; wie weit ein Schutz
/// *überfällig* ist, steht daneben im Text — ein Balken kann nicht negativ sein,
/// und ihn bei Ablauf leer zu lassen wäre eine stille Untertreibung.
struct ProtectionBar: View {
    let status: ProtectionStatus
    var showsCaption: Bool = true

    private var tint: Color {
        switch status.remainingFraction {
        case ..<0.001: return .red
        case ..<0.2: return .orange
        case ..<0.4: return .yellow
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * status.remainingFraction)
                }
            }
            .frame(height: 8)

            if showsCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(status.isExpired ? Color.red : .secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Restwirksamkeit")
        .accessibilityValue(caption)
    }

    private var caption: String {
        if status.isExpired {
            let days = abs(status.remainingDays)
            return days == 0
                ? "Heute abgelaufen"
                : "Seit \(days) \(days == 1 ? "Tag" : "Tagen") abgelaufen"
        }
        let percent = Int((status.remainingFraction * 100).rounded())
        return "\(percent) % · noch \(status.remainingDays) \(status.remainingDays == 1 ? "Tag" : "Tage")"
    }
}

// MARK: - Konfidenz

extension Confidence {
    var label: String {
        switch self {
        case .low: return "niedrig"
        case .moderate: return "mittel"
        case .high: return "hoch"
        }
    }

    var symbolName: String {
        switch self {
        case .low: return "chart.bar.fill"
        case .moderate: return "chart.bar.fill"
        case .high: return "chart.bar.fill"
        }
    }

    var tint: Color {
        switch self {
        case .low: return .secondary
        case .moderate: return .orange
        case .high: return .green
        }
    }
}

/// Konfidenz einer Prognose. Muss überall dort stehen, wo eine Prognose
/// angezeigt wird — eine Spanne ohne Konfidenzangabe ist laut PRD §6 nicht
/// zulässig.
struct ConfidenceLabel: View {
    let confidence: Confidence
    var detail: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
            Text("Konfidenz \(confidence.label)")
            if let detail {
                Text("· \(detail)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(confidence.tint)
    }
}

/// Karten-Container für die Dashboard- und Übersichts-Abschnitte.
struct SectionCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    if let systemImage {
                        Image(systemName: systemImage)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

/// Zeile mit Beschriftung links und Wert rechts.
struct LabeledValueRow: View {
    let label: String
    let value: String
    var systemImage: String?

    var body: some View {
        HStack {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
