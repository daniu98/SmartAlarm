import Foundation
import Testing

@testable import SmartAlarm

@Suite("Calendar commitments and importance")
struct EventImportanceTests {
    private let work = Coordinate(latitude: 37.7749, longitude: -122.4194)
    private let clientSite = Coordinate(latitude: 37.8044, longitude: -122.2712) // ~18 km away
    private let nextDoor = Coordinate(latitude: 37.7752, longitude: -122.4196)   // ~40 m away

    private var windowStart: Date { Fixture.date(hour: 4) }
    private var windowEnd: Date { Fixture.date(hour: 13) }

    // MARK: - Selecting the first real commitment

    @Test("Picks the earliest event you actually have to attend")
    func picksEarliest() {
        let events = [
            CommitmentCandidate(title: "Standup", start: Fixture.date(hour: 9, minute: 30)),
            CommitmentCandidate(title: "Client call", start: Fixture.date(hour: 8, minute: 15)),
            CommitmentCandidate(title: "Lunch", start: Fixture.date(hour: 12)),
        ]

        let first = CommitmentSelector.firstCommitment(
            among: events, notBefore: windowStart, notAfter: windowEnd
        )
        #expect(first?.title == "Client call")
    }

    @Test("All-day banners, declined invites and free-time blocks are not commitments")
    func filtersNonCommitments() {
        let events = [
            CommitmentCandidate(title: "Sprint week", start: Fixture.date(hour: 5), isAllDay: true),
            CommitmentCandidate(title: "Optional sync", start: Fixture.date(hour: 6), isBusy: false),
            CommitmentCandidate(title: "Declined review", start: Fixture.date(hour: 7), isDeclinedBySelf: true),
            CommitmentCandidate(title: "Real meeting", start: Fixture.date(hour: 8)),
        ]

        let first = CommitmentSelector.firstCommitment(
            among: events, notBefore: windowStart, notAfter: windowEnd
        )
        #expect(first?.title == "Real meeting")
    }

    @Test("Events outside the morning window are ignored")
    func respectsWindow() {
        let events = [
            CommitmentCandidate(title: "Overnight page", start: Fixture.date(hour: 2)),
            CommitmentCandidate(title: "Evening dinner", start: Fixture.date(hour: 19)),
        ]
        let first = CommitmentSelector.firstCommitment(
            among: events, notBefore: windowStart, notAfter: windowEnd
        )
        #expect(first == nil)
    }

    @Test("An empty calendar yields no commitment")
    func emptyCalendar() {
        #expect(
            CommitmentSelector.firstCommitment(among: [], notBefore: windowStart, notAfter: windowEnd) == nil
        )
    }

    // MARK: - Earlier-only arrival resolution

    @Test("An early meeting pulls the arrival deadline earlier")
    func earlyMeetingPullsDeadlineEarlier() {
        let meeting = CommitmentCandidate(title: "Design review", start: Fixture.date(hour: 8))

        let resolution = ArrivalResolver.resolve(
            defaultArrival: Fixture.date(hour: 9),
            commitment: meeting,
            importance: .normal,
            workCoordinate: work,
            workLabel: "Work",
            allowDestinationOverride: true
        )

        #expect(resolution.deadline == Fixture.date(hour: 8))
        #expect(resolution.source == .calendar)
        #expect(resolution.eventTitle == "Design review")
    }

    /// The core safety guarantee of the calendar feature: a clear morning, a stale calendar,
    /// or a calendar the app simply failed to read can never let you sleep in.
    @Test("A late first meeting never pushes the deadline later")
    func lateMeetingCannotDelayDeadline() {
        let meeting = CommitmentCandidate(title: "Afternoon sync", start: Fixture.date(hour: 11))

        let resolution = ArrivalResolver.resolve(
            defaultArrival: Fixture.date(hour: 9),
            commitment: meeting,
            importance: .normal,
            workCoordinate: work,
            workLabel: "Work",
            allowDestinationOverride: true
        )

        #expect(resolution.deadline == Fixture.date(hour: 9))
        #expect(resolution.source == .settings)
    }

    @Test("No commitment falls back to the configured arrival and destination")
    func noCommitmentUsesSettings() {
        let resolution = ArrivalResolver.resolve(
            defaultArrival: Fixture.date(hour: 9),
            commitment: nil,
            importance: .normal,
            workCoordinate: work,
            workLabel: "Work",
            allowDestinationOverride: true
        )

        #expect(resolution.deadline == Fixture.date(hour: 9))
        #expect(resolution.source == .settings)
        #expect(resolution.destination == work)
        #expect(!resolution.destinationFromCalendar)
    }

    // MARK: - Destination override

    @Test("An early meeting somewhere else becomes the day's destination")
    func destinationOverrideApplies() {
        let meeting = CommitmentCandidate(
            title: "Client onsite",
            start: Fixture.date(hour: 8),
            location: clientSite,
            locationText: "1 Broadway, Oakland"
        )

        let resolution = ArrivalResolver.resolve(
            defaultArrival: Fixture.date(hour: 9),
            commitment: meeting,
            importance: .normal,
            workCoordinate: work,
            workLabel: "Work",
            allowDestinationOverride: true
        )

        #expect(resolution.destination == clientSite)
        #expect(resolution.destinationFromCalendar)
        #expect(resolution.destinationLabel == "1 Broadway, Oakland")
    }

    /// A 4pm client visit must not send you across town for a 9am office arrival.
    @Test("A later meeting elsewhere does not redirect the morning commute")
    func lateMeetingDoesNotRedirect() {
        let meeting = CommitmentCandidate(
            title: "Client onsite",
            start: Fixture.date(hour: 16),
            location: clientSite
        )

        let resolution = ArrivalResolver.resolve(
            defaultArrival: Fixture.date(hour: 9),
            commitment: meeting,
            importance: .normal,
            workCoordinate: work,
            workLabel: "Work",
            allowDestinationOverride: true
        )

        #expect(resolution.destination == work)
        #expect(!resolution.destinationFromCalendar)
    }

    @Test("A meeting in the office building is not a different destination")
    func nearbyMeetingIsNotAnOverride() {
        let meeting = CommitmentCandidate(
            title: "Conf room B",
            start: Fixture.date(hour: 8),
            location: nextDoor
        )

        let resolution = ArrivalResolver.resolve(
            defaultArrival: Fixture.date(hour: 9),
            commitment: meeting,
            importance: .normal,
            workCoordinate: work,
            workLabel: "Work",
            allowDestinationOverride: true
        )

        #expect(resolution.destination == work)
        #expect(!resolution.destinationFromCalendar)
    }

    @Test("Destination override can be switched off")
    func destinationOverrideRespectsSetting() {
        let meeting = CommitmentCandidate(
            title: "Client onsite",
            start: Fixture.date(hour: 8),
            location: clientSite
        )

        let resolution = ArrivalResolver.resolve(
            defaultArrival: Fixture.date(hour: 9),
            commitment: meeting,
            importance: .normal,
            workCoordinate: work,
            workLabel: "Work",
            allowDestinationOverride: false
        )

        #expect(resolution.destination == work)
        // The deadline still moves earlier — only the routing is suppressed.
        #expect(resolution.deadline == Fixture.date(hour: 8))
    }

    // MARK: - Importance scoring

    @Test("An ordinary meeting is an ordinary morning")
    func ordinaryMeeting() {
        let scorer = ImportanceScorer()
        let meeting = CommitmentCandidate(title: "Weekly sync", start: Fixture.date(hour: 9))
        #expect(scorer.level(for: meeting) == .normal)
    }

    @Test("A keyword in the title raises the stakes")
    func keywordInTitle() {
        let scorer = ImportanceScorer()
        let meeting = CommitmentCandidate(title: "Final interview — Priya", start: Fixture.date(hour: 9))
        #expect(scorer.level(for: meeting) >= .elevated)
    }

    @Test("A big external meeting on a keyword lands at critical")
    func externalKeywordMeetingIsCritical() {
        let scorer = ImportanceScorer()
        let meeting = CommitmentCandidate(
            title: "Board presentation",
            start: Fixture.date(hour: 9),
            attendeeCount: 8,
            organizerIsSelf: false
        )
        #expect(scorer.level(for: meeting) == .critical)
    }

    @Test("High-priority reminders raise the stakes on their own")
    func remindersContribute() {
        let scorer = ImportanceScorer()
        #expect(scorer.level(for: nil, highPriorityReminderTitles: ["Pick up dry cleaning"]) == .elevated)
        #expect(
            scorer.level(
                for: nil,
                highPriorityReminderTitles: ["Print boarding pass for flight"]
            ) >= .elevated
        )
    }

    @Test("Importance only ever adds buffer")
    func importanceOnlyAddsTime() {
        #expect(ImportanceLevel.normal.extraBufferMinutes == 0)
        #expect(ImportanceLevel.elevated.extraBufferMinutes > 0)
        #expect(ImportanceLevel.critical.extraBufferMinutes > ImportanceLevel.elevated.extraBufferMinutes)
    }

    @Test("Escalating a posture never makes it more relaxed")
    func postureEscalationIsMonotonic() {
        #expect(ReliabilityPosture.relaxed.escalated == .balanced)
        #expect(ReliabilityPosture.balanced.escalated == .cautious)
        #expect(ReliabilityPosture.cautious.escalated == .cautious)
    }

    @Test("Custom keyword lists are honoured")
    func customKeywords() {
        let scorer = ImportanceScorer(keywords: ["dentist"])
        let meeting = CommitmentCandidate(title: "Dentist appointment", start: Fixture.date(hour: 9))
        #expect(scorer.level(for: meeting) >= .elevated)
        #expect(scorer.level(for: CommitmentCandidate(title: "Interview", start: Fixture.date(hour: 9))) == .normal)
    }
}
