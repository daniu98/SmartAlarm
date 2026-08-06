import Foundation

enum ImportanceLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case normal
    case elevated
    case critical

    private var rank: Int {
        switch self {
        case .normal: 0
        case .elevated: 1
        case .critical: 2
        }
    }

    static func < (lhs: ImportanceLevel, rhs: ImportanceLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Importance may only ever *add* time. It can never shave the buffer down.
    var extraBufferMinutes: Int {
        switch self {
        case .normal: 0
        case .elevated: 10
        case .critical: 20
        }
    }

    var escalatesPosture: Bool { self != .normal }

    var label: String {
        switch self {
        case .normal: "Normal morning"
        case .elevated: "Important morning"
        case .critical: "High-stakes morning"
        }
    }
}

/// A calendar event, flattened to just what the scoring needs. Keeps EventKit out of the
/// logic layer so this is testable without a calendar database.
struct CommitmentCandidate: Sendable, Hashable {
    var title: String
    var start: Date
    var isAllDay: Bool
    var isBusy: Bool
    var isDeclinedBySelf: Bool
    var attendeeCount: Int
    var organizerIsSelf: Bool
    var location: Coordinate?
    var locationText: String?
    var notes: String?

    init(
        title: String,
        start: Date,
        isAllDay: Bool = false,
        isBusy: Bool = true,
        isDeclinedBySelf: Bool = false,
        attendeeCount: Int = 0,
        organizerIsSelf: Bool = true,
        location: Coordinate? = nil,
        locationText: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.start = start
        self.isAllDay = isAllDay
        self.isBusy = isBusy
        self.isDeclinedBySelf = isDeclinedBySelf
        self.attendeeCount = attendeeCount
        self.organizerIsSelf = organizerIsSelf
        self.location = location
        self.locationText = locationText
        self.notes = notes
    }
}

enum CommitmentSelector {
    /// The first thing you actually have to show up for. All-day banners, events you've
    /// declined, and anything marked free are not commitments.
    static func firstCommitment(
        among candidates: [CommitmentCandidate],
        notBefore: Date,
        notAfter: Date
    ) -> CommitmentCandidate? {
        candidates
            .filter { !$0.isAllDay && $0.isBusy && !$0.isDeclinedBySelf }
            .filter { $0.start >= notBefore && $0.start <= notAfter }
            .min { $0.start < $1.start }
    }
}

struct ImportanceScorer: Sendable {
    var keywords: [String]

    static let defaultKeywords = [
        "interview", "flight", "exam", "onsite", "on-site", "presentation",
        "deadline", "board", "offsite", "off-site", "closing", "court",
        "surgery", "keynote", "demo day", "final",
    ]

    init(keywords: [String] = ImportanceScorer.defaultKeywords) {
        self.keywords = keywords
    }

    func matchesKeyword(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lowered = text.lowercased()
        return keywords.contains { !$0.isEmpty && lowered.contains($0.lowercased()) }
    }

    func level(
        for candidate: CommitmentCandidate?,
        highPriorityReminderTitles: [String] = []
    ) -> ImportanceLevel {
        var score = 0

        if let candidate {
            if matchesKeyword(candidate.title) { score += 2 }
            if matchesKeyword(candidate.notes) { score += 1 }
            if candidate.attendeeCount >= 3 { score += 1 }
            // Something someone else called, that you accepted: harder to be late to.
            if !candidate.organizerIsSelf, candidate.attendeeCount > 0 { score += 1 }
        }

        if !highPriorityReminderTitles.isEmpty {
            score += 1
            if highPriorityReminderTitles.contains(where: { matchesKeyword($0) }) { score += 1 }
        }

        if score >= 3 { return .critical }
        if score >= 1 { return .elevated }
        return .normal
    }
}

enum ArrivalSource: String, Codable, Sendable, Hashable {
    case settings
    case calendar
}

struct ArrivalResolution: Sendable, Hashable {
    var deadline: Date
    var source: ArrivalSource
    var eventTitle: String?
    var destination: Coordinate
    var destinationLabel: String
    var destinationFromCalendar: Bool
    var importance: ImportanceLevel

    var extraBufferMinutes: Int { importance.extraBufferMinutes }
}

/// Turns "my usual arrival time" plus "what the calendar says" into the deadline the solver
/// works backwards from.
///
/// The one rule that matters: **the calendar can only pull the deadline earlier.** A stale,
/// wrong, or simply empty calendar must never be able to let you sleep in. That asymmetry is
/// deliberate and is enforced here rather than trusted to callers.
enum ArrivalResolver {
    /// A meeting location this close to the office is the office.
    static let minimumDestinationOffsetMeters: Double = 500

    static func resolve(
        defaultArrival: Date,
        commitment: CommitmentCandidate?,
        importance: ImportanceLevel,
        workCoordinate: Coordinate,
        workLabel: String,
        allowDestinationOverride: Bool
    ) -> ArrivalResolution {
        guard let commitment else {
            return ArrivalResolution(
                deadline: defaultArrival,
                source: .settings,
                eventTitle: nil,
                destination: workCoordinate,
                destinationLabel: workLabel,
                destinationFromCalendar: false,
                importance: importance
            )
        }

        // Earlier-only. `min` is the entire safety guarantee.
        let deadline = min(defaultArrival, commitment.start)
        let calendarDrivesDeadline = commitment.start < defaultArrival

        // Only reroute when the commitment is the thing we're actually racing to get to.
        // Otherwise a 4pm client visit would send you to the wrong side of town at 9am.
        var destination = workCoordinate
        var destinationLabel = workLabel
        var fromCalendar = false
        if allowDestinationOverride,
           calendarDrivesDeadline,
           let eventLocation = commitment.location,
           eventLocation.distance(to: workCoordinate) > minimumDestinationOffsetMeters {
            destination = eventLocation
            destinationLabel = commitment.locationText ?? commitment.title
            fromCalendar = true
        }

        return ArrivalResolution(
            deadline: deadline,
            source: calendarDrivesDeadline ? .calendar : .settings,
            eventTitle: commitment.title,
            destination: destination,
            destinationLabel: destinationLabel,
            destinationFromCalendar: fromCalendar,
            importance: importance
        )
    }
}
