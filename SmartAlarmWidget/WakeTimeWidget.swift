import SwiftUI
import WidgetKit

/// Tomorrow's wake time on the home and lock screens.
///
/// Read-only by design: it renders the snapshot the app last wrote and never computes anything
/// itself. All the safety logic lives in one place, and the widget can't disagree with the app.
struct WakeTimeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WakeTimeWidget", provider: Provider()) { entry in
            WakeTimeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Wake time")
        .description("When to get up, and when to leave.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }

    struct Entry: TimelineEntry {
        let date: Date
        let snapshot: WakePlanSnapshot?
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(date: .now, snapshot: .placeholder)
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            let snapshot = context.isPreview ? .placeholder : SharedStore.load()
            completion(Entry(date: .now, snapshot: snapshot))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            let snapshot = SharedStore.load()
            let entry = Entry(date: .now, snapshot: snapshot)

            // The app reloads timelines whenever the plan moves, so this is only a backstop
            // for the case where background refreshes never run.
            let next = WakePlanSnapshot.nextReload(after: .now, wakeDate: snapshot?.wakeDate)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

private struct WakeTimeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WakeTimeWidget.Entry

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.isArmed {
            content(snapshot)
        } else {
            unavailable
        }
    }

    @ViewBuilder
    private func content(_ snapshot: WakePlanSnapshot) -> some View {
        switch family {
        case .accessoryInline:
            Text("\(Self.time(snapshot.wakeDate)) · leave \(Self.time(snapshot.leaveByDate))")

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Wake \(Self.time(snapshot.wakeDate))")
                    .font(.headline)
                Text("Leave \(Self.time(snapshot.leaveByDate))")
                    .font(.caption)
                Text("\(snapshot.driveMinutes) min · \(snapshot.condition.shortLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                wakeBlock(snapshot)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Stat(label: "Leave by", value: Self.time(snapshot.leaveByDate), symbol: "car.fill")
                    Stat(
                        label: "Drive",
                        value: "\(snapshot.driveMinutes) min",
                        symbol: snapshot.condition.symbolName
                    )
                    Stat(label: "Arrive", value: Self.time(snapshot.arrivalDeadline), symbol: "flag.checkered")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        default:
            VStack(alignment: .leading, spacing: 6) {
                wakeBlock(snapshot)
                Spacer(minLength: 0)
                Label("Leave \(Self.time(snapshot.leaveByDate))", systemImage: "car.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func wakeBlock(_ snapshot: WakePlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(snapshot.phaseLabel, systemImage: snapshot.phaseSymbolName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Self.time(snapshot.wakeDate))
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if snapshot.isStale() {
                Text("Estimate is out of date")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var unavailable: some View {
        switch family {
        case .accessoryInline:
            Text("No alarm armed")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("No alarm").font(.headline)
                Text("Open SmartyAlarm").font(.caption2).foregroundStyle(.secondary)
            }
        default:
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No alarm armed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private struct Stat: View {
        let label: String
        let value: String
        let symbol: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.caption.monospacedDigit())
                        .fontWeight(.medium)
                }
            }
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
