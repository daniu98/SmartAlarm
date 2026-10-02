import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query private var settingsList: [UserSettings]

    @State private var showingWhy = false
    @State private var showingOverride = false
    @State private var overrideDate = Date.now
    @State private var outcomePrompt: AlarmPlan?
    @State private var postureAdvice: PostureAdvisor.Recommendation?

    private var planner: WakePlanner { appEnvironment.planner }
    private var settings: UserSettings? { settingsList.first }

    var body: some View {
        NavigationStack {
            Group {
                if let settings, settings.isRouteConfigured {
                    configuredBody(settings: settings)
                } else {
                    NeedsSetupView()
                }
            }
            .navigationTitle("Today")
            .task { refreshPrompts() }
            .onChange(of: planner.currentPlan?.wakeDate) { _, _ in refreshPrompts() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await planner.refresh(trigger: .manual) }
                    } label: {
                        if planner.isChecking {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(planner.isChecking)
                }
            }
        }
    }

    @ViewBuilder
    private func configuredBody(settings: UserSettings) -> some View {
        List {
            if appEnvironment.isRunningOnFallbackStore {
                Section {
                    NoticeRow(
                        symbol: "externaldrive.badge.exclamationmark",
                        tint: .red,
                        title: "Settings aren't being saved",
                        message: "The database couldn't be opened, so this session is temporary. Reinstalling the app will fix it."
                    )
                }
            }

            if appEnvironment.alarmAuthorization != .authorized {
                Section {
                    AlarmPermissionRow()
                }
            }

            if let plan = outcomePrompt {
                Section {
                    OutcomePromptRow(plan: plan) { outcome in
                        planner.record(outcome: outcome, for: plan)
                        refreshPrompts()
                    }
                } header: {
                    Text("How did \(Format.relativeDay(plan.targetDayStart).lowercased()) go?")
                }
            }

            if let advice = postureAdvice {
                Section {
                    PostureAdviceRow(advice: advice) {
                        Task {
                            await planner.applyPosture(advice.suggested)
                            refreshPrompts()
                        }
                    } onDismiss: {
                        postureAdvice = nil
                    }
                }
            }

            Section {
                WakeTimeHeader(plan: planner.currentPlan, phase: planner.currentPhase)
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
            }

            if let message = planner.lastErrorMessage {
                Section {
                    NoticeRow(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        title: "Last traffic check didn't complete",
                        message: message
                    )
                }
            }

            if let message = planner.schedulingErrorMessage {
                Section {
                    NoticeRow(
                        symbol: "bell.slash.fill",
                        tint: .red,
                        title: "Alarm not set",
                        message: message
                    )
                }
            }

            if planner.isAnomalousMorning {
                Section {
                    NoticeRow(
                        symbol: "chart.line.uptrend.xyaxis",
                        tint: .red,
                        title: "Unusual traffic",
                        message: "Today's drive is worse than almost every morning we've recorded on this route."
                    )
                }
            }

            if let plan = planner.currentPlan {
                Section("The plan") {
                    DetailRow(label: "Wake", value: Format.time(plan.wakeDate), symbol: "alarm")
                    DetailRow(label: "Leave by", value: Format.time(plan.leaveByDate), symbol: "car.fill")
                    DetailRow(
                        label: "Drive",
                        value: Format.minutes(plan.lastGoodTravelSeconds),
                        symbol: plan.lastCondition.symbolName,
                        detail: plan.lastCondition.shortLabel
                    )
                    DetailRow(label: "Arrive by", value: Format.time(plan.arrivalDeadline), symbol: "flag.checkered")

                    if plan.weather.affectsDriving {
                        DetailRow(
                            label: plan.weather.label,
                            value: "+\(Int((plan.weather.padFraction * 100).rounded()))%",
                            symbol: plan.weather.symbolName,
                            detail: "Added to the drive"
                        )
                    }

                    DetailRow(
                        label: "Asleep by",
                        value: Format.time(SleepTarget.asleepBy(
                            wake: plan.wakeDate,
                            sleepTargetMinutes: settings.sleepTargetMinutes
                        )),
                        symbol: "moon.zzz.fill",
                        detail: "for \(SleepTarget.text(settings.sleepTargetMinutes))"
                    )

                    Button {
                        showingWhy = true
                    } label: {
                        Label("Why this time?", systemImage: "questionmark.circle")
                    }

                    ConfidenceRow(sampleCount: planner.routeSampleCount)
                }

                if !plan.routeAdvisories.isEmpty {
                    Section("Route notices") {
                        ForEach(plan.routeAdvisories, id: \.self) { notice in
                            Label(notice, systemImage: "exclamationmark.bubble")
                                .font(.subheadline)
                        }
                        if let name = plan.routeName {
                            Text("Via \(name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Destination") {
                    DestinationRow(plan: plan)
                    if plan.importance != .normal {
                        NoticeRow(
                            symbol: "exclamationmark.circle.fill",
                            tint: .indigo,
                            title: plan.importance.label,
                            message: "Added \(plan.extraBufferMinutes) minutes of buffer and using a more cautious estimate."
                        )
                    }
                }

                Section("Status") {
                    PhaseRow(phase: planner.currentPhase, plan: plan, settings: settings)
                    DetailRow(
                        label: "Leave-by alarm",
                        value: plan.isLeaveAlarmScheduled ? Format.time(plan.leaveByDate) : "Not set",
                        symbol: plan.isLeaveAlarmScheduled ? "bell.badge.fill" : "bell.slash",
                        detail: plan.isLeaveAlarmScheduled ? "Rings even if you snooze through" : nil
                    )
                    if let last = plan.lastSuccessfulCheckAt {
                        DetailRow(
                            label: "Last good check",
                            value: Format.time(last),
                            symbol: "checkmark.circle",
                            detail: plan.lastEstimateSource.label
                        )
                    }
                    if plan.consecutiveFailureCount > 0 {
                        DetailRow(
                            label: "Failed checks",
                            value: "\(plan.consecutiveFailureCount)",
                            symbol: "wifi.exclamationmark"
                        )
                    }
                }

                Section {
                    if plan.isManuallyOverridden {
                        Button(role: .destructive) {
                            Task { await planner.setManualOverride(nil) }
                        } label: {
                            Label("Remove manual override", systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button {
                            overrideDate = plan.wakeDate
                            showingOverride = true
                        } label: {
                            Label("Set the time myself", systemImage: "hand.raised")
                        }
                    }
                } footer: {
                    Text("A manual override freezes the alarm. Traffic checks keep running and are still logged, but they stop moving the time.")
                }
            }

            Section {
                if let fires = planner.testAlarmFiresAt, fires > .now {
                    HStack {
                        Label("Test alarm at \(Format.time(fires))", systemImage: "bell.badge.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Cancel") { planner.cancelTestAlarm() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else {
                    Button {
                        Task {
                            if appEnvironment.alarmAuthorization != .authorized {
                                await appEnvironment.requestAlarmAuthorization()
                            }
                            await planner.scheduleTestAlarm()
                        }
                    } label: {
                        Label("Ring a test alarm in 1 minute", systemImage: "bell.badge")
                    }
                }
            } footer: {
                Text("Lock your phone and flip the silent switch. It should still ring — that's the difference between a system alarm and a notification, and it's worth checking once before you rely on it.")
            }

            Section {
                Toggle("Alarm armed", isOn: alarmEnabledBinding(settings: settings))
            } footer: {
                Text(settings.isEnabled
                    ? "Next alarm arms automatically for your next active weekday."
                    : "Turn this on to arm the alarm.")
            }
        }
        .sheet(isPresented: $showingWhy) {
            WhyThisTimeView(breakdown: planner.lastBreakdown, plan: planner.currentPlan)
        }
        .sheet(isPresented: $showingOverride) {
            OverrideSheet(date: $overrideDate) {
                Task { await planner.setManualOverride(overrideDate) }
            }
        }
    }

    private func refreshPrompts() {
        outcomePrompt = planner.planAwaitingOutcome()
        postureAdvice = planner.postureRecommendation()
    }

    private func alarmEnabledBinding(settings: UserSettings) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled },
            set: { newValue in
                Task {
                    if newValue {
                        if appEnvironment.alarmAuthorization != .authorized {
                            await appEnvironment.requestAlarmAuthorization()
                        }
                        await planner.enableAlarm()
                    } else {
                        await planner.disableAlarm()
                    }
                }
            }
        )
    }
}

// MARK: - Header

private struct WakeTimeHeader: View {
    let plan: AlarmPlan?
    let phase: SchedulePhase
    /// Scales with Dynamic Type instead of sitting at a fixed 56pt.
    @ScaledMetric(relativeTo: .largeTitle) private var timeSize: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(plan.map { Format.relativeDay($0.targetDayStart) } ?? "No alarm")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                PhasePill(phase: phase)
            }

            Text(plan.map { Format.time($0.wakeDate) } ?? "—")
                .font(.system(size: timeSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
                .accessibilityLabel(plan.map { "Wake at \(Format.time($0.wakeDate))" } ?? "No alarm set")

            if let plan {
                Text("Leave by \(Format.time(plan.leaveByDate)) · \(Format.minutes(plan.lastGoodTravelSeconds)) drive")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PhasePill: View {
    let phase: SchedulePhase

    var body: some View {
        Label(phase.label, systemImage: phase.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("Status: \(phase.label). \(phase.detail)")
    }

    private var tint: Color {
        switch phase {
        case .disabled, .done: .secondary
        case .idle: .blue
        case .watching: .green
        case .locked: .orange
        case .gettingReady: .teal
        case .overdue: .red
        }
    }
}

// MARK: - Rows

private struct DetailRow: View {
    let label: String
    let value: String
    var symbol: String?
    var detail: String?

    var body: some View {
        HStack {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            Text(label)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .monospacedDigit()
                    .fontWeight(.medium)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DestinationRow: View {
    let plan: AlarmPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: plan.destinationFromCalendar ? "calendar.badge.clock" : "building.2")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(plan.destinationLabel)
                    .lineLimit(2)
            }
            if plan.destinationFromCalendar, let title = plan.eventTitle {
                Text("Routing here because of “\(title)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if plan.arrivalSource == .calendar, let title = plan.eventTitle {
                Text("Arrival pulled earlier by “\(title)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PhaseRow: View {
    let phase: SchedulePhase
    let plan: AlarmPlan
    let settings: UserSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(phase.label, systemImage: phase.symbolName)
                .font(.subheadline.weight(.medium))
            Text(phase.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if phase == .idle {
                Text("Checks start at \(Format.time(settings.phaseCalculator.watchStart(for: plan.phaseWindow))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if phase == .watching {
                Text("Later moves stop being accepted at \(Format.time(settings.phaseCalculator.lockStart(for: plan.phaseWindow))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct NoticeRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AlarmPermissionRow: View {
    @Environment(AppEnvironment.self) private var appEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Alarm permission needed", systemImage: "bell.badge")
                .font(.subheadline.weight(.medium))
            Text("SmartyAlarm uses a system alarm so it rings even when the app is closed and the phone is silenced.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Grant permission") {
                Task {
                    let result = await appEnvironment.requestAlarmAuthorization()
                    // Permission was the only thing between an already-computed plan and a
                    // real system alarm: `ensureAlarmScheduled` bails out when it isn't
                    // granted. Without this the banner disappears and the alarm still isn't
                    // registered until the app next returns to the foreground — an armed
                    // alarm that silently wouldn't ring. The trigger is deliberately
                    // `.foreground`, which registers the existing plan without spending a
                    // fresh MapKit request.
                    if result.isAuthorized {
                        await appEnvironment.planner.refresh(trigger: .foreground)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct NeedsSetupView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Set up your commute", systemImage: "map")
        } description: {
            Text("Add your home and work addresses in Setup, and SmartyAlarm will work backwards from when you need to arrive.")
        }
    }
}

private struct OverrideSheet: View {
    @Binding var date: Date
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Wake at", selection: $date, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
            }
            .navigationTitle("Set the time myself")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}


// MARK: - Calibration prompts

/// The one question that closes the loop. Without location tracking the app never learns
/// whether its estimate was any good; a single tap here is the only ground truth it gets.
private struct OutcomePromptRow: View {
    let plan: AlarmPlan
    let onSelect: (MorningOutcome) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You were due at \(Format.time(plan.arrivalDeadline)), leaving at \(Format.time(plan.leaveByDate)).")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(MorningOutcome.allCases, id: \.self) { outcome in
                    Button {
                        onSelect(outcome)
                    } label: {
                        Label(outcome.label, systemImage: outcome.symbolName)
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(outcome.label)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PostureAdviceRow: View {
    let advice: PostureAdvisor.Recommendation
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                advice.isMoreCautious ? "Consider waking earlier" : "You have margin to spare",
                systemImage: advice.isMoreCautious ? "arrow.up.circle.fill" : "moon.stars.fill"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(advice.isMoreCautious ? .orange : .indigo)

            Text(advice.reason)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Switch to \(advice.suggested.label)", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Not now", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}


/// How much evidence is behind today's estimate.
///
/// The padding maths is invisible and the number it produces looks equally authoritative
/// whether it rests on forty mornings or none. Saying which changes how much the user should
/// trust it — and sets the expectation that it improves.
private struct ConfidenceRow: View {
    let sampleCount: Int

    private var isConfident: Bool {
        sampleCount >= HistoricalTravelModel.minimumSamplesForConfidence
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isConfident ? "chart.bar.fill" : "chart.bar")
                .foregroundStyle(isConfident ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headline: String {
        sampleCount == 0
            ? "No history for this route yet"
            : "Learned from \(sampleCount) morning\(sampleCount == 1 ? "" : "s")"
    }

    private var detail: String {
        if isConfident {
            return "Padding is sized from how much this route actually varies at this hour."
        }
        return "Until \(HistoricalTravelModel.minimumSamplesForConfidence) mornings are recorded, a conservative default is used instead. It sharpens as you go."
    }
}
