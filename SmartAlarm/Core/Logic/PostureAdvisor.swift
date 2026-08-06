import Foundation

/// How a morning actually went, as reported by the person who lived it.
///
/// Without location tracking the app has no idea whether its estimate was any good. One tap
/// closes that loop: it is the only outcome label the system ever gets, so it is worth asking
/// for and worth acting on.
enum MorningOutcome: String, Codable, Sendable, CaseIterable, Hashable {
    case onTime
    case late
    case didNotTravel

    var label: String {
        switch self {
        case .onTime: "Made it"
        case .late: "Was late"
        case .didNotTravel: "Didn't go"
        }
    }

    var symbolName: String {
        switch self {
        case .onTime: "checkmark.circle.fill"
        case .late: "clock.badge.exclamationmark.fill"
        case .didNotTravel: "minus.circle"
        }
    }

    /// Days you didn't travel say nothing about the estimate's quality.
    var countsTowardCalibration: Bool { self != .didNotTravel }
}

/// Recommends a posture change from recorded outcomes.
///
/// The two directions are deliberately not symmetric. Becoming *more* careful needs only a
/// modest sample and a modest late rate, because being late is the failure this app exists to
/// prevent. Becoming *less* careful — trading insurance for sleep — needs a much longer clean
/// run, because the cost of getting that call wrong is the thing you were paying to avoid.
struct PostureAdvisor: Sendable, Hashable {
    /// Enough mornings to say anything at all about tightening up.
    var minimumSamplesToEscalate = 8
    /// Late this often or more and the posture isn't buying what it should.
    var lateRateToEscalate = 0.2
    /// A much longer clean run before suggesting the user trade insurance for sleep.
    var minimumSamplesToRelax = 20

    struct Recommendation: Sendable, Hashable {
        var suggested: ReliabilityPosture
        var reason: String
        var isMoreCautious: Bool
    }

    struct Summary: Sendable, Hashable {
        var onTime: Int
        var late: Int

        var total: Int { onTime + late }
        var lateRate: Double { total == 0 ? 0 : Double(late) / Double(total) }
    }

    func summarize(_ outcomes: [MorningOutcome]) -> Summary {
        Summary(
            onTime: outcomes.count { $0 == .onTime },
            late: outcomes.count { $0 == .late }
        )
    }

    func recommendation(
        for outcomes: [MorningOutcome],
        current: ReliabilityPosture
    ) -> Recommendation? {
        let summary = summarize(outcomes)
        guard summary.total > 0 else { return nil }

        if summary.total >= minimumSamplesToEscalate,
           summary.lateRate >= lateRateToEscalate,
           current != .cautious {
            return Recommendation(
                suggested: current.escalated,
                reason: "You've been late \(summary.late) of the last \(summary.total) mornings.",
                isMoreCautious: true
            )
        }

        // Only ever offered on a spotless record over a long stretch.
        if summary.total >= minimumSamplesToRelax,
           summary.late == 0,
           current != .relaxed {
            let suggested: ReliabilityPosture = current == .cautious ? .balanced : .relaxed
            return Recommendation(
                suggested: suggested,
                reason: "You've been on time all \(summary.total) mornings. You could trade some of that margin for sleep.",
                isMoreCautious: false
            )
        }

        return nil
    }
}
