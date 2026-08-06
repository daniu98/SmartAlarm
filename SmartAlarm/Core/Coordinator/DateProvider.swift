import Foundation

/// The app's single source of "now".
///
/// Every time-dependent decision reads from here rather than calling `Date()` directly, which
/// makes the whole state machine steerable from the debug menu: shift the offset and you can
/// watch a morning play out in seconds instead of waiting for 5 a.m.
@Observable
@MainActor
final class DateProvider {
    /// Debug-only time travel. Always zero in release builds.
    var offset: TimeInterval = 0

    var now: Date { Date.now.addingTimeInterval(offset) }

    func callAsFunction() -> Date { now }

    var isShifted: Bool { offset != 0 }

    func shift(byMinutes minutes: Double) { offset += minutes * 60 }

    func reset() { offset = 0 }
}
