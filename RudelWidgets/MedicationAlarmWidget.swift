import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

@main
struct RudelWidgets: WidgetBundle {
    var body: some Widget { MedicationAlarmWidget() }
}

struct MedicationAlarmWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<MedicationAlarmMetadata>.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: "pills.fill").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.metadata?.petName ?? "Medikamentengabe").font(.caption).foregroundStyle(.secondary)
                        Text(context.attributes.metadata?.medication ?? "Gabe prüfen").font(.headline)
                        if let dose = context.attributes.metadata?.dose, !dose.isEmpty {
                            Text(dose).font(.subheadline)
                        }
                    }
                    Spacer(minLength: 8)
                    timer(context).font(.title2.monospacedDigit()).multilineTextAlignment(.trailing)
                }
                HStack {
                    if let due = context.attributes.metadata?.dueAt {
                        Text("Geplant: \(due, format: .dateTime.hour().minute())").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Gabe bestätigen", destination: MedicationAlarmLink.url(reminderID: context.attributes.metadata?.reminderID ?? ""))
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.orange.opacity(0.16), in: Capsule())
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(.systemBackground))
            .widgetURL(MedicationAlarmLink.url(reminderID: context.attributes.metadata?.reminderID ?? ""))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.metadata?.petName ?? "Rudel", systemImage: "pills.fill")
                        .font(.headline).foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(context).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        Text(context.attributes.metadata?.medication ?? "Medikamentengabe").font(.headline)
                        if let dose = context.attributes.metadata?.dose, !dose.isEmpty { Text(dose).font(.caption) }
                        Link("Gabe bestätigen", destination: MedicationAlarmLink.url(reminderID: context.attributes.metadata?.reminderID ?? ""))
                            .font(.subheadline.bold()).foregroundStyle(.orange)
                    }
                }
            } compactLeading: {
                Image(systemName: "pills.fill").foregroundStyle(.orange)
            } compactTrailing: {
                timer(context).monospacedDigit().frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "pills.fill").foregroundStyle(.orange)
            }
            .widgetURL(MedicationAlarmLink.url(reminderID: context.attributes.metadata?.reminderID ?? ""))
            .keylineTint(.orange)
        }
    }

    @ViewBuilder
    private func timer(_ context: ActivityViewContext<AlarmAttributes<MedicationAlarmMetadata>>) -> some View {
        switch context.state.mode {
        case .countdown(let countdown):
            // Systemzeit statt ursprünglichem Termin: nach dem Schlummern muss
            // hier der neue Countdown stehen.
            Text(timerInterval: countdown.startDate...max(countdown.startDate, countdown.fireDate), countsDown: true)
        case .alert:
            Text("Gabe offen")
        case .paused:
            Text("Pausiert")
        @unknown default:
            Text("Gabe prüfen")
        }
    }
}
