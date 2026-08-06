import Foundation

/// Turns a wake time and a sleep target into an asleep-by time.
///
/// The app spends all its effort deciding when to wake you and then says nothing about the
/// other end of the night, which is the half you can actually control.
enum SleepTarget {
    static let minMinutes = 4 * 60
    static let maxMinutes = 12 * 60

    static func asleepBy(wake: Date, sleepTargetMinutes: Int) -> Date {
        wake.addingTimeInterval(-Double(clamp(sleepTargetMinutes)) * 60)
    }

    /// How much sleep you'd get going to sleep at `bedtime`. Negative is impossible, so it
    /// floors at zero rather than reporting nonsense.
    static func availableMinutes(from bedtime: Date, wake: Date) -> Int {
        max(0, Int(wake.timeIntervalSince(bedtime) / 60))
    }

    /// True when the asleep-by time has already passed — i.e. hitting the target tonight is
    /// no longer possible.
    static func isUnreachable(asleepBy: Date, now: Date) -> Bool {
        asleepBy <= now
    }

    static func clamp(_ minutes: Int) -> Int {
        min(max(minutes, minMinutes), maxMinutes)
    }

    static func text(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
