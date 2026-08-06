import SwiftUI

/// Shows the arithmetic behind the wake time.
///
/// This is not decoration. An alarm whose reasoning is opaque is one the user sets a backup
/// for, and a backup alarm defeats the entire feature. Every padding term is itemised so the
/// number is auditable — including the ones that cost sleep.
struct WhyThisTimeView: View {
    let breakdown: WakeTimeBreakdown?
    let plan: AlarmPlan?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let breakdown {
                    content(breakdown)
                } else {
                    ContentUnavailableView(
                        "No calculation yet",
                        systemImage: "function",
                        description: Text("Run a check from the Today screen and the working will show up here.")
                    )
                }
            }
            .navigationTitle("Why this time?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ breakdown: WakeTimeBreakdown) -> some View {
        List {
            Section("Working backwards") {
                MathRow(
                    label: "Arrive by",
                    value: Format.time(breakdown.arrivalDeadline),
                    note: plan?.arrivalSource == .calendar ? plan?.eventTitle : nil
                )
                MathRow(
                    label: "− Drive time",
                    value: Format.minutes(breakdown.padding.totalSeconds),
                    note: breakdown.estimate.source.label
                )
                MathRow(
                    label: "− Arrival buffer",
                    value: Format.minutes(breakdown.arrivalBufferSeconds),
                    note: "Parking, walking in"
                )
                if breakdown.extraBufferSeconds > 0 {
                    MathRow(
                        label: "− Importance buffer",
                        value: Format.minutes(breakdown.extraBufferSeconds),
                        note: plan?.importance.label
                    )
                }
                MathRow(
                    label: "= Leave by",
                    value: Format.time(breakdown.leaveBy),
                    emphasised: true
                )
                MathRow(
                    label: "− Get ready",
                    value: Format.minutes(breakdown.getReadySeconds)
                )
                MathRow(
                    label: "= Wake",
                    value: Format.time(breakdown.wakeTime),
                    emphasised: true
                )
            }

            Section {
                MathRow(
                    label: "Map estimate",
                    value: Format.minutes(breakdown.padding.baseSeconds),
                    note: "What the route service said"
                )
                if breakdown.padding.spreadSeconds > 0 {
                    MathRow(
                        label: "+ Route variability",
                        value: Format.minutes(breakdown.padding.spreadSeconds),
                        note: "How much this route swings at this hour"
                    )
                }
                if breakdown.padding.horizonSeconds > 0 {
                    MathRow(
                        label: "+ Forecast uncertainty",
                        value: Format.minutes(breakdown.padding.horizonSeconds),
                        note: "Shrinks as departure gets closer"
                    )
                }
                if breakdown.padding.weatherSeconds > 0 {
                    MathRow(
                        label: "+ Weather",
                        value: Format.minutes(breakdown.padding.weatherSeconds),
                        note: plan?.weather.label ?? "Forecast conditions"
                    )
                }
                MathRow(
                    label: "= Drive time used",
                    value: Format.minutes(breakdown.padding.totalSeconds),
                    emphasised: true
                )
            } header: {
                Text("How the drive time was padded")
            } footer: {
                Text("Padding is insurance against being late. It is added when the estimate is least trustworthy — far from departure, on a route that varies a lot, in weather the traffic model hasn't caught up with — and melts away as the morning gets closer.")
            }

            if breakdown.clampedToFloor {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Held at your earliest wake time")
                                .font(.subheadline.weight(.medium))
                            Text("The maths asked for \(Format.time(breakdown.uncappedWakeTime)), which is earlier than the floor you set. The alarm is at \(Format.time(breakdown.wakeTime)) instead — expect to be about \(Format.duration(from: breakdown.uncappedWakeTime, to: breakdown.wakeTime)) behind.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if breakdown.padding.wasClamped {
                Section {
                    Label(
                        "The padded drive time hit your min/max bounds and was clamped.",
                        systemImage: "arrow.left.and.right.square"
                    )
                    .font(.caption)
                }
            }

            Section("Details") {
                MathRow(label: "Estimate source", value: breakdown.estimate.source.label)
                MathRow(label: "Solver passes", value: "\(breakdown.iterations)")
                if breakdown.estimate.distanceMeters > 0 {
                    MathRow(
                        label: "Distance",
                        value: Measurement(value: breakdown.estimate.distanceMeters, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road))
                    )
                }
                MathRow(
                    label: "Asked about departure",
                    value: Format.time(breakdown.estimate.departureDate),
                    note: "Not \"right now\" — the time you'll actually leave"
                )
            }
        }
    }
}

private struct MathRow: View {
    let label: String
    let value: String
    var note: String?
    var emphasised: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .fontWeight(emphasised ? .semibold : .regular)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(value)
                .monospacedDigit()
                .fontWeight(emphasised ? .semibold : .regular)
        }
    }
}
