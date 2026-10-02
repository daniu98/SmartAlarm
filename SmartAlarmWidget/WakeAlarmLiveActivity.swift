import AlarmKit
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island face of the alarm.
///
/// `AlarmAttributes` is an `ActivityAttributes`, so AlarmKit needs a widget extension to have
/// anywhere to draw. Everything shown here comes from `WakeAlarmMetadata`, which rides along
/// with the alarm itself — the extension never reads the app's database, which is what keeps
/// it free of an App Group.
struct WakeAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<WakeAlarmMetadata>.self) { context in
            LockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.55))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.presentation.alert.title)
                            .font(.headline)
                    } icon: {
                        Image(systemName: "alarm.fill")
                    }
                    .foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let metadata = context.attributes.metadata {
                        Text(metadata.leaveByDate, style: .time)
                            .font(.title3.monospacedDigit())
                            .fontWeight(.semibold)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ModeDetailView(context: context)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                CompactTrailingView(context: context)
            } minimal: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(context.attributes.tintColor)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<AlarmAttributes<WakeAlarmMetadata>>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text(context.attributes.presentation.alert.title)
                        .font(.headline)
                } icon: {
                    Image(systemName: "alarm.fill")
                }
                .foregroundStyle(context.attributes.tintColor)

                Spacer()

                if let metadata = context.attributes.metadata {
                    Label(metadata.condition.shortLabel, systemImage: metadata.condition.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ModeDetailView(context: context)

            if let metadata = context.attributes.metadata {
                Divider().opacity(0.4)

                HStack(spacing: 16) {
                    Stat(title: "Leave by", value: metadata.leaveByDate.formatted(date: .omitted, time: .shortened))
                    Stat(title: "Drive", value: "\(metadata.driveMinutes) min")
                    Stat(title: "Arrive", value: metadata.arrivalDeadline.formatted(date: .omitted, time: .shortened))
                }

                Text(metadata.destinationLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private struct Stat: View {
        let title: String
        let value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(.medium)
            }
        }
    }
}

/// AlarmKit drives the alarm through alert → countdown (snooze) → paused. Each needs a
/// different thing on screen.
private struct ModeDetailView: View {
    let context: ActivityViewContext<AlarmAttributes<WakeAlarmMetadata>>

    var body: some View {
        switch context.state.mode {
        case .alert:
            // The alarm's own title, not a fixed string: the same Live Activity draws the
            // leave-by alarm and the test alarm, and telling someone to "get up" as they
            // are walking out of the door is worse than saying nothing.
            alertTitle
        case .countdown(let countdown):
            VStack(alignment: .leading, spacing: 2) {
                Text("Snoozed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(timerInterval: Date.now...countdown.fireDate, countsDown: true)
                    .font(.title2.monospacedDigit())
                    .fontWeight(.semibold)
            }
        case .paused:
            Text("Paused")
                .font(.title3)
                .foregroundStyle(.secondary)
        @unknown default:
            alertTitle
        }
    }

    private var alertTitle: some View {
        Text(context.attributes.presentation.alert.title)
            .font(.title2)
            .fontWeight(.semibold)
    }
}

private struct CompactTrailingView: View {
    let context: ActivityViewContext<AlarmAttributes<WakeAlarmMetadata>>

    var body: some View {
        switch context.state.mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...countdown.fireDate, countsDown: true)
                .monospacedDigit()
                .frame(maxWidth: 44)
        case .alert, .paused:
            leaveByText
        @unknown default:
            leaveByText
        }
    }

    @ViewBuilder
    private var leaveByText: some View {
        if let metadata = context.attributes.metadata {
            Text(metadata.leaveByDate, style: .time)
                .monospacedDigit()
        }
    }
}
