import SwiftData
import SwiftUI

struct SetupView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query private var settingsList: [UserSettings]

    @State private var homeField = ""
    @State private var workField = ""
    @State private var geocodingHome = false
    @State private var geocodingWork = false
    @State private var geocodeError: String?
    @State private var showingAdvanced = false
    @State private var loadedFields = false
    @State private var recomputeTask: Task<Void, Never>?
    @State private var paywallFeature: ProFeature?
    @State private var showingPaywall = false

    private var isPro: Bool { appEnvironment.entitlements.isPro }

    private var settings: UserSettings? { settingsList.first }

    var body: some View {
        NavigationStack {
            Form {
                if let settings {
                    routeSection(settings)
                    scheduleSection(settings)
                    timingsSection(settings)
                    calendarSection(settings)
                    advancedSection(settings)
                    proSection
                }
            }
            .navigationTitle("Setup")
            .sheet(item: $paywallFeature) { feature in
                PaywallView(highlighted: feature)
            }
            .onChange(of: settings?.planSignature) { _, _ in scheduleRecompute() }
            .task {
                guard !loadedFields, let settings else { return }
                homeField = settings.homeAddress
                workField = settings.workAddress
                loadedFields = true
            }
            .alert(
                "Address lookup failed",
                isPresented: Binding(get: { geocodeError != nil }, set: { if !$0 { geocodeError = nil } })
            ) {
                Button("OK", role: .cancel) { geocodeError = nil }
            } message: {
                Text(geocodeError ?? "")
            }
        }
    }

    // MARK: - Route

    @ViewBuilder
    private func routeSection(_ settings: UserSettings) -> some View {
        Section {
            AddressField(
                title: "Home",
                systemImage: "house",
                text: $homeField,
                isResolving: geocodingHome,
                isResolved: settings.homeCoordinate != nil
            ) {
                await resolveHome(settings)
            }

            AddressField(
                title: "Work",
                systemImage: "building.2",
                text: $workField,
                isResolving: geocodingWork,
                isResolved: settings.workCoordinate != nil
            ) {
                await resolveWork(settings)
            }
        } header: {
            Text("Commute")
        } footer: {
            Text("Addresses are geocoded once and stored on your device. Nothing leaves the phone except the route lookups themselves.")
        }
    }

    private func resolveHome(_ settings: UserSettings) async {
        geocodingHome = true
        defer { geocodingHome = false }
        do {
            let result = try await appEnvironment.geocoder.geocode(homeField)
            settings.homeAddress = result.formattedAddress
            settings.setHomeCoordinate(result.coordinate)
            homeField = result.formattedAddress
            settings.updatedAt = .now
            await appEnvironment.planner.refresh(trigger: .manual)
        } catch {
            geocodeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func resolveWork(_ settings: UserSettings) async {
        geocodingWork = true
        defer { geocodingWork = false }
        do {
            let result = try await appEnvironment.geocoder.geocode(workField)
            settings.workAddress = result.formattedAddress
            settings.setWorkCoordinate(result.coordinate)
            workField = result.formattedAddress
            settings.updatedAt = .now
            await appEnvironment.planner.refresh(trigger: .manual)
        } catch {
            geocodeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private func scheduleSection(_ settings: UserSettings) -> some View {
        Section {
            DatePicker(
                "Usual arrival",
                selection: minuteBinding(
                    get: { settings.defaultArrivalMinuteOfDay },
                    set: { settings.defaultArrivalMinuteOfDay = $0 }
                ),
                displayedComponents: .hourAndMinute
            )

            NavigationLink {
                ActiveDaysView(settings: settings)
            } label: {
                LabeledContent("Active days", value: activeDaysSummary(settings))
            }

            if isPro {
                NavigationLink {
                    PerDayArrivalView(settings: settings)
                } label: {
                    LabeledContent(
                        "Per-day arrival",
                        value: settings.arrivalOverrides.isEmpty
                            ? "Same every day"
                            : "\(settings.arrivalOverrides.count) override\(settings.arrivalOverrides.count == 1 ? "" : "s")"
                    )
                }
            } else {
                Button { paywallFeature = .perDayArrival } label: {
                    LockedRow(title: "Per-day arrival", value: "Same every day")
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Arrival")
        }
    }

    private func activeDaysSummary(_ settings: UserSettings) -> String {
        let days = settings.activeWeekdays.sorted()
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days.isEmpty { return "None" }
        return days.map { MinuteOfDay.shortWeekdayName($0) }.joined(separator: " ")
    }

    // MARK: - Timings

    @ViewBuilder
    private func timingsSection(_ settings: UserSettings) -> some View {
        Section {
            Stepper(
                value: Binding(get: { settings.getReadyMinutes }, set: { settings.getReadyMinutes = $0 }),
                in: 5...180,
                step: 5
            ) {
                LabeledContent("Get ready", value: "\(settings.getReadyMinutes) min")
            }

            Stepper(
                value: Binding(get: { settings.arrivalBufferMinutes }, set: { settings.arrivalBufferMinutes = $0 }),
                in: 0...60,
                step: 5
            ) {
                LabeledContent("Arrival buffer", value: "\(settings.arrivalBufferMinutes) min")
            }

            Stepper(
                value: Binding(
                    get: { settings.sleepTargetMinutes },
                    set: { settings.sleepTargetMinutes = SleepTarget.clamp($0) }
                ),
                in: SleepTarget.minMinutes...SleepTarget.maxMinutes,
                step: 15
            ) {
                LabeledContent("Sleep target", value: SleepTarget.text(settings.sleepTargetMinutes))
            }

            Picker(
                "How careful",
                selection: Binding(get: { settings.posture }, set: { settings.posture = $0 })
            ) {
                ForEach(ReliabilityPosture.allCases, id: \.self) { posture in
                    Text(posture.label).tag(posture)
                }
            }

            if isPro {
                Toggle("Pad for weather", isOn: Binding(
                    get: { settings.weatherEnabled },
                    set: { newValue in
                        settings.weatherEnabled = newValue
                        Task { await appEnvironment.planner.refresh(trigger: .manual) }
                    }
                ))
            } else {
                Button { paywallFeature = .weather } label: {
                    LockedRow(title: "Pad for weather", value: "Off")
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Timings")
        } footer: {
            Text("\(settings.posture.detail) Weather padding adds time for rain, snow and ice — the one input that leads the traffic model instead of trailing it.")
        }
    }

    // MARK: - Calendar

    @ViewBuilder
    private func calendarSection(_ settings: UserSettings) -> some View {
        Section {
            if !isPro {
                Button { paywallFeature = .calendar } label: {
                    LockedRow(title: "Use my calendar", value: "Off")
                }
                .buttonStyle(.plain)
            } else {
            Toggle("Use my calendar", isOn: Binding(
                get: { settings.calendarEnabled },
                set: { newValue in
                    settings.calendarEnabled = newValue
                    Task {
                        if newValue {
                            _ = await appEnvironment.calendarProvider.requestEventAccess()
                        }
                        appEnvironment.syncEntitlementGatedFeatures()
                        await appEnvironment.planner.refresh(trigger: .manual)
                    }
                }
            ))

            if settings.calendarEnabled {
                Toggle("Route to off-site meetings", isOn: Binding(
                    get: { settings.calendarCanOverrideDestination },
                    set: { settings.calendarCanOverrideDestination = $0 }
                ))

                Toggle("Check high-priority reminders", isOn: Binding(
                    get: { settings.remindersEnabled },
                    set: { newValue in
                        settings.remindersEnabled = newValue
                        if newValue {
                            Task { _ = await appEnvironment.calendarProvider.requestReminderAccess() }
                        }
                    }
                ))

                NavigationLink {
                    KeywordsView(settings: settings)
                } label: {
                    LabeledContent("Important keywords", value: "\(settings.importanceKeywords.count)")
                }
            }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("An earlier first commitment pulls the alarm earlier. A clear morning never pushes it later — a stale or unreadable calendar can't make you oversleep.")
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private func advancedSection(_ settings: UserSettings) -> some View {
        Section(isExpanded: $showingAdvanced) {
            DatePicker(
                "Never wake before",
                selection: minuteBinding(
                    get: { settings.earliestAcceptableWakeMinuteOfDay },
                    set: { settings.earliestAcceptableWakeMinuteOfDay = $0 }
                ),
                displayedComponents: .hourAndMinute
            )

            Stepper(
                value: Binding(get: { settings.refreshIntervalMinutes }, set: { settings.refreshIntervalMinutes = $0 }),
                in: 5...60,
                step: 5
            ) {
                LabeledContent("Check every", value: "\(settings.refreshIntervalMinutes) min")
            }

            Stepper(
                value: Binding(get: { settings.refreshWindowStartMinutes }, set: { settings.refreshWindowStartMinutes = $0 }),
                in: 30...360,
                step: 30
            ) {
                LabeledContent("Start checking", value: "\(settings.refreshWindowStartMinutes) min early")
            }

            Stepper(
                value: Binding(
                    get: { settings.lockLaterAdjustmentsInsideMinutes },
                    set: { settings.lockLaterAdjustmentsInsideMinutes = $0 }
                ),
                in: 0...180,
                step: 5
            ) {
                LabeledContent("Freeze later moves", value: "\(settings.lockLaterAdjustmentsInsideMinutes) min before")
            }

            Stepper(
                value: Binding(get: { settings.minTravelTimeMinutes }, set: { settings.minTravelTimeMinutes = $0 }),
                in: 1...60,
                step: 1
            ) {
                LabeledContent("Min plausible drive", value: "\(settings.minTravelTimeMinutes) min")
            }

            Stepper(
                value: Binding(get: { settings.maxTravelTimeMinutes }, set: { settings.maxTravelTimeMinutes = $0 }),
                in: 15...300,
                step: 15
            ) {
                LabeledContent("Max plausible drive", value: "\(settings.maxTravelTimeMinutes) min")
            }

            Stepper(
                value: Binding(get: { settings.snoozeMinutes }, set: { settings.snoozeMinutes = $0 }),
                in: 1...30,
                step: 1
            ) {
                LabeledContent("Snooze", value: "\(settings.snoozeMinutes) min")
            }

            // The expandable `Section(isExpanded:content:header:)` has no footer variant,
            // so the explanation lives inside the disclosure instead.
            Text("Drive estimates outside the plausible range are thrown away rather than trusted, and the last good alarm time is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Advanced")
        }
    }

    // MARK: - Pro

    @ViewBuilder
    private var proSection: some View {
        Section {
            if isPro {
                Label("SmartyAlarm Pro is unlocked", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    showingPaywall = true
                } label: {
                    Label("Upgrade to Pro", systemImage: "sparkles")
                }
            }
        } footer: {
            Text("The traffic-aware alarm and the leave-by backstop are free, and stay free.")
        }
        .sheet(isPresented: $showingPaywall) { PaywallView() }
    }

    // MARK: - Helpers

    /// Steppers fire on every tap, so a recompute per change would mean a burst of pointless
    /// work. Debounced, and deliberately using the cached drive estimate: changing get-ready
    /// time changes the arithmetic, not the traffic.
    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            settings?.updatedAt = .now
            await appEnvironment.planner.refresh(trigger: .manual, useCachedEstimate: true)
        }
    }

    private func minuteBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        let dayStart = Calendar.current.startOfDay(for: .now)
        return Binding(
            get: { MinuteOfDay.date(get(), onDayStarting: dayStart) },
            set: { set(MinuteOfDay.from($0)) }
        )
    }
}

// MARK: - Sub-screens

private struct ActiveDaysView: View {
    @Bindable var settings: UserSettings

    var body: some View {
        List {
            ForEach(1...7, id: \.self) { weekday in
                Toggle(MinuteOfDay.weekdayName(weekday), isOn: Binding(
                    get: { settings.activeWeekdays.contains(weekday) },
                    set: { isOn in
                        if isOn {
                            if !settings.activeWeekdays.contains(weekday) {
                                settings.activeWeekdays.append(weekday)
                            }
                        } else {
                            settings.activeWeekdays.removeAll { $0 == weekday }
                        }
                    }
                ))
            }
        }
        .navigationTitle("Active days")
    }
}

private struct PerDayArrivalView: View {
    @Bindable var settings: UserSettings

    var body: some View {
        List {
            Section {
                ForEach(settings.activeWeekdays.sorted(), id: \.self) { weekday in
                    DatePicker(
                        MinuteOfDay.weekdayName(weekday),
                        selection: binding(for: weekday),
                        displayedComponents: .hourAndMinute
                    )
                }
            } footer: {
                Text("Days left at your usual arrival time don't create an override.")
            }

            if !settings.arrivalOverrides.isEmpty {
                Section {
                    Button("Reset all to usual time", role: .destructive) {
                        settings.arrivalOverrides.removeAll()
                    }
                }
            }
        }
        .navigationTitle("Per-day arrival")
    }

    private func binding(for weekday: Int) -> Binding<Date> {
        let dayStart = Calendar.current.startOfDay(for: .now)
        return Binding(
            get: {
                MinuteOfDay.date(settings.arrivalMinuteOfDay(forWeekday: weekday), onDayStarting: dayStart)
            },
            set: { newDate in
                let minute = MinuteOfDay.from(newDate)
                settings.arrivalOverrides.removeAll { $0.weekday == weekday }
                if minute != settings.defaultArrivalMinuteOfDay {
                    settings.arrivalOverrides.append(ArrivalOverride(weekday: weekday, minuteOfDay: minute))
                }
            }
        )
    }
}

private struct KeywordsView: View {
    @Bindable var settings: UserSettings
    @State private var newKeyword = ""

    var body: some View {
        List {
            Section {
                ForEach(settings.importanceKeywords, id: \.self) { keyword in
                    Text(keyword)
                }
                .onDelete { offsets in
                    settings.importanceKeywords.remove(atOffsets: offsets)
                }

                HStack {
                    TextField("Add a keyword", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("A morning whose first commitment matches one of these gets extra buffer and a more cautious drive estimate. It never gets less time.")
            }
        }
        .navigationTitle("Important keywords")
    }

    private func add() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, !settings.importanceKeywords.contains(trimmed) else { return }
        settings.importanceKeywords.append(trimmed)
        newKeyword = ""
    }
}

private struct AddressField: View {
    let title: String
    let systemImage: String
    @Binding var text: String
    let isResolving: Bool
    let isResolved: Bool
    let onResolve: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isResolving {
                    ProgressView()
                } else if isResolved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            TextField("Street, city", text: $text, axis: .vertical)
                .textContentType(.fullStreetAddress)
                .autocorrectionDisabled()
                .onSubmit { Task { await onResolve() } }

            Button("Look up address") {
                Task { await onResolve() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isResolving)
        }
        .padding(.vertical, 4)
    }
}


/// A settings row that looks like the real thing but opens the paywall instead.
private struct LockedRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
            ProBadge()
        }
    }
}
