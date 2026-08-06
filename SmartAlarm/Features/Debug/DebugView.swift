#if DEBUG
import SwiftData
import SwiftUI

/// Testing a time-dependent alarm by waiting for actual mornings is not a workable loop.
/// This screen makes the whole state machine steerable: shift the app's sense of "now",
/// inject a drive time, and watch the phases and adjustment rules play out in seconds.
struct DebugView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query private var settingsList: [UserSettings]
    @Query(sort: \TravelSample.recordedAt, order: .reverse) private var samples: [TravelSample]

    @State private var injectedMinutes: Double = 30

    private var planner: WakePlanner { appEnvironment.planner }
    private var clock: DateProvider { appEnvironment.clock }
    private var settings: UserSettings? { settingsList.first }

    var body: some View {
        NavigationStack {
            List {
                clockSection
                trafficSection
                if let settings, let plan = planner.currentPlan {
                    windowSection(plan: plan, settings: settings)
                }
                historySection
                entitlementSection
                actionsSection
            }
            .navigationTitle("Debug")
        }
    }

    // MARK: - Clock

    private var clockSection: some View {
        Section {
            LabeledContent("App time", value: Format.dayAndTime(clock.now))
            LabeledContent("Offset", value: Format.signedMinutes(clock.offset))

            HStack {
                ForEach([-60.0, -15.0, 15.0, 60.0], id: \.self) { delta in
                    Button(Format.signedMinutes(delta * 60)) {
                        clock.shift(byMinutes: delta)
                        Task { await planner.refresh(trigger: .manual) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                }
            }

            Button("Reset to real time") {
                clock.reset()
                Task { await planner.refresh(trigger: .manual) }
            }
            .disabled(!clock.isShifted)
        } header: {
            Text("Time travel")
        } footer: {
            Text("Everything that reads the clock goes through one provider, so shifting it here moves the whole app forward — phases, lock windows and all.")
        }
    }

    // MARK: - Traffic injection

    private var trafficSection: some View {
        Section {
            if planner.injectedTravelMinutes != nil {
                LabeledContent("Injected drive", value: "\(Int(injectedMinutes)) min")
            }

            Slider(value: $injectedMinutes, in: 1...180, step: 1) {
                Text("Drive time")
            } minimumValueLabel: {
                Text("1")
            } maximumValueLabel: {
                Text("180")
            }

            Button("Inject \(Int(injectedMinutes)) min and re-check") {
                planner.injectedTravelMinutes = injectedMinutes
                Task { await planner.refresh(trigger: .manual) }
            }

            Button("Stop injecting, use real MapKit") {
                planner.injectedTravelMinutes = nil
                Task { await planner.refresh(trigger: .manual) }
            }
            .disabled(planner.injectedTravelMinutes == nil)
        } header: {
            Text("Traffic injection")
        } footer: {
            Text("Set a big number to watch the alarm jump earlier, then a small one inside the lock window to watch the improvement get rejected. Both land in History with the reason.")
        }
    }

    // MARK: - Window inspection

    private func windowSection(plan: AlarmPlan, settings: UserSettings) -> some View {
        Section("Computed window") {
            LabeledContent("Phase", value: planner.currentPhase.label)
            LabeledContent("Watch opens", value: Format.dayAndTime(settings.phaseCalculator.watchStart(for: plan.phaseWindow)))
            LabeledContent("Lock closes", value: Format.dayAndTime(settings.phaseCalculator.lockStart(for: plan.phaseWindow)))
            LabeledContent("Earliest possible wake", value: Format.dayAndTime(plan.earliestPossibleWake))
            LabeledContent("Scheduled wake", value: Format.dayAndTime(plan.wakeDate))
            LabeledContent("Alarm registered", value: plan.isAlarmScheduled ? "Yes" : "No")
            LabeledContent("Alarm ID", value: plan.alarmIdentifier.uuidString.prefix(8).description)
            if let pending = plan.pendingLaterProposal {
                LabeledContent("Held proposal", value: Format.time(pending.wakeDate))
            }
        }
    }

    // MARK: - Recorded history

    private var historySection: some View {
        Section {
            LabeledContent("Samples recorded", value: "\(samples.count)")
            if samples.count < HistoricalTravelModel.minimumSamplesForConfidence {
                Text("Below \(HistoricalTravelModel.minimumSamplesForConfidence) samples the model declines to answer, and the solver falls back to a cold-start seed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(samples.prefix(8)) { sample in
                LabeledContent(
                    "\(MinuteOfDay.shortWeekdayName(sample.weekday)) \(MinuteOfDay.text(sample.minuteOfDay))",
                    value: Format.minutes(sample.seconds)
                )
                .font(.caption.monospacedDigit())
            }

            Button("Seed 20 synthetic samples") {
                seedSamples()
            }
        } header: {
            Text("Historical model")
        } footer: {
            Text("Real samples are captured once per morning during the locked phase, which is the check closest to actual departure.")
        }
    }

    private var entitlementSection: some View {
        Section {
            Toggle("Pro unlocked", isOn: Binding(
                get: { appEnvironment.entitlements.isPro },
                set: { newValue in
                    appEnvironment.entitlements.setDebugOverride(newValue)
                    Task { await appEnvironment.applyEntitlementChange() }
                }
            ))
            LabeledContent(
                "Store product",
                value: appEnvironment.entitlements.product?.displayPrice ?? "not loaded"
            )
        } header: {
            Text("Entitlements")
        } footer: {
            Text("The StoreKit configuration in Config/SmartAlarm.storekit only applies when Xcode launches the app, so a real purchase can be tested from Xcode and this toggle covers everything else.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Load demo route (SF → Palo Alto)") {
                DebugSeed.apply(
                    to: planner.settings(),
                    context: appEnvironment.modelContainer.mainContext
                )
                Task { await planner.refresh(trigger: .manual) }
            }
            Button("Run a check now") {
                Task { await planner.refresh(trigger: .manual) }
            }
            Button("Run the nightly bootstrap") {
                Task {
                    await planner.refreshRouteBaselineIfNeeded()
                    await planner.refresh(trigger: .nightly)
                }
            }
            Button("Re-submit background tasks") {
                appEnvironment.background.applicationDidEnterBackground()
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Background tasks can't be forced from here — pause in the debugger and use `_simulateLaunchForTaskWithIdentifier:`. Simulators refuse BGTaskScheduler submissions entirely; that's expected.")
        }
    }

    private func seedSamples() {
        guard let settings, let home = settings.homeCoordinate, let work = settings.workCoordinate else { return }
        let routeKey = Coordinate.routeKey(from: home, to: work)
        let context = appEnvironment.modelContainer.mainContext

        for index in 0..<20 {
            // A plausible spread: mostly ~28 min with a long tail, which is what gives the
            // posture padding something to work with.
            let base = 28.0 * 60
            let jitter = Double((index * 7) % 13) * 60
            context.insert(
                TravelSample(
                    routeKey: routeKey,
                    weekday: 2 + (index % 5),
                    minuteOfDay: 8 * 60 + (index % 4) * 15,
                    seconds: base + jitter,
                    recordedAt: .now.addingTimeInterval(-Double(index) * 86_400)
                )
            )
        }
        try? context.save()
    }
}
#endif
