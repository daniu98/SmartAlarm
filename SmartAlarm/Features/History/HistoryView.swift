import SwiftData
import SwiftUI

/// Every check, successful or not, grouped by the morning it was working towards.
///
/// This is the debugging tool. "Why did it wake me at 6:05?" is answerable here: you can see
/// the estimate that caused it, and equally the improvements that were ignored because they
/// arrived inside the lock window.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query(sort: \CheckLog.timestamp, order: .reverse) private var logs: [CheckLog]
    @State private var showingPaywall = false

    private var isPro: Bool { appEnvironment.entitlements.isPro }

    private var cutoff: Date? {
        isPro ? nil : Date.now.addingTimeInterval(-FreeTier.historyInterval)
    }

    private var visibleLogs: [CheckLog] {
        guard let cutoff else { return logs }
        return logs.filter { $0.timestamp >= cutoff }
    }

    private var hiddenCount: Int { logs.count - visibleLogs.count }

    private var grouped: [(day: Date, entries: [CheckLog])] {
        Dictionary(grouping: visibleLogs, by: \.targetDayStart)
            .map { (day: $0.key, entries: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if logs.isEmpty {
                    ContentUnavailableView(
                        "No checks yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Once the alarm is armed, every traffic check lands here — including the ones that failed or were ignored.")
                    )
                } else {
                    List {
                        if hiddenCount > 0 {
                            Section {
                                Button { showingPaywall = true } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text("\(hiddenCount) older check\(hiddenCount == 1 ? "" : "s")")
                                                    .font(.subheadline.weight(.medium))
                                                ProBadge()
                                            }
                                            Text("Free history covers the last \(FreeTier.historyDays) days.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        ForEach(grouped, id: \.day) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    CheckLogRow(entry: entry)
                                }
                            } header: {
                                HStack {
                                    Text(Format.relativeDay(group.day))
                                    Spacer()
                                    Text(summary(for: group.entries))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .sheet(isPresented: $showingPaywall) {
                PaywallView(highlighted: .extendedHistory)
            }
        }
    }

    private func summary(for entries: [CheckLog]) -> String {
        let moves = entries.filter { $0.outcome == .movedEarlier || $0.outcome == .movedLater }.count
        let failures = entries.filter(\.outcome.isFailure).count
        var parts = ["\(entries.count) check\(entries.count == 1 ? "" : "s")"]
        if moves > 0 { parts.append("\(moves) move\(moves == 1 ? "" : "s")") }
        if failures > 0 { parts.append("\(failures) failed") }
        return parts.joined(separator: " · ")
    }
}

private struct CheckLogRow: View {
    let entry: CheckLog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.outcome.symbolName)
                    .foregroundStyle(tint)
                    .frame(width: 20)

                Text(entry.outcome.label)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(Format.time(entry.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(entry.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Chip(text: entry.phase.label, symbol: entry.phase.symbolName)
                Chip(text: entry.trigger.label, symbol: "bolt")
                if let minutes = entry.travelMinutes {
                    Chip(text: "\(minutes) min", symbol: entry.condition.symbolName)
                }
                if entry.wasAnomalous {
                    Chip(text: "Unusual", symbol: "chart.line.uptrend.xyaxis", tint: .red)
                }
            }

            if let wake = entry.wakeDate {
                Text("Wake \(Format.time(wake))\(entry.leaveByDate.map { " · leave \(Format.time($0))" } ?? "")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let error = entry.errorText {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch entry.outcome {
        case .movedEarlier: .green
        case .movedLater: .blue
        case .scheduled: .accentColor
        case .held: .yellow
        case .rejectedLocked: .orange
        case .rejectedImplausible, .failed: .red
        case .noChange: .secondary
        }
    }
}

private struct Chip: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
