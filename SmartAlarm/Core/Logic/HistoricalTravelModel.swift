import Foundation

/// A local, on-device model of how long this route actually takes, built from the estimates
/// the app has already logged. No extra permissions and no network — it is purely a
/// re-reading of `TravelSample` rows.
///
/// It earns its keep in four places:
///  1. Seeding the fixed-point solve, so the first MapKit query is already close.
///  2. Supplying `spread`, which is how much padding the posture buys.
///  3. Standing in as an estimate when every live check fails and there is no plan yet.
///  4. Flagging a morning as anomalous when live traffic blows past the historical p90.
struct HistoricalTravelModel: Sendable {
    struct Sample: Sendable, Hashable {
        var weekday: Int          // Calendar convention: 1 = Sunday ... 7 = Saturday
        var minuteOfDay: Int
        var seconds: Double
        var recordedAt: Date

        init(weekday: Int, minuteOfDay: Int, seconds: Double, recordedAt: Date) {
            self.weekday = weekday
            self.minuteOfDay = minuteOfDay
            self.seconds = seconds
            self.recordedAt = recordedAt
        }
    }

    /// 15-minute departure buckets. Fine enough to separate 7:15 from 8:15 traffic,
    /// coarse enough that a handful of mornings fills a bucket.
    static let bucketMinutes = 15
    /// Below this we widen the search rather than trust the number.
    static let minimumSamplesForConfidence = 4

    private let byWeekdayBucket: [BucketKey: [Double]]
    let sampleCount: Int

    private struct BucketKey: Hashable {
        var weekday: Int
        var bucket: Int
    }

    static func bucket(forMinuteOfDay minute: Int) -> Int {
        minute / bucketMinutes
    }

    init(samples: [Sample]) {
        var grouped: [BucketKey: [Double]] = [:]
        for sample in samples where sample.seconds > 0 {
            let key = BucketKey(
                weekday: sample.weekday,
                bucket: Self.bucket(forMinuteOfDay: sample.minuteOfDay)
            )
            grouped[key, default: []].append(sample.seconds)
        }
        for key in grouped.keys {
            grouped[key]?.sort()
        }
        byWeekdayBucket = grouped
        sampleCount = samples.count
    }

    /// Widens outward from the exact bucket until it has enough samples to be meaningful:
    /// exact bucket → ±1 → ±2 → same day-class (weekday vs weekend) → anything.
    /// Returns `nil` rather than guessing when there is genuinely nothing to go on.
    func samples(weekday: Int, minuteOfDay: Int) -> [Double]? {
        let targetBucket = Self.bucket(forMinuteOfDay: minuteOfDay)

        for spread in 0...2 {
            var collected: [Double] = []
            for offset in -spread...spread {
                let key = BucketKey(weekday: weekday, bucket: targetBucket + offset)
                collected.append(contentsOf: byWeekdayBucket[key] ?? [])
            }
            if collected.count >= Self.minimumSamplesForConfidence {
                return collected.sorted()
            }
        }

        // Fall back to the same kind of day at a similar hour.
        let targetIsWeekend = Self.isWeekend(weekday)
        var sameClass: [Double] = []
        for (key, values) in byWeekdayBucket
        where Self.isWeekend(key.weekday) == targetIsWeekend && abs(key.bucket - targetBucket) <= 2 {
            sameClass.append(contentsOf: values)
        }
        if sameClass.count >= Self.minimumSamplesForConfidence {
            return sameClass.sorted()
        }

        // Last resort: everything we've ever seen for this route.
        let everything = byWeekdayBucket.values.flatMap { $0 }
        return everything.count >= Self.minimumSamplesForConfidence ? everything.sorted() : nil
    }

    static func isWeekend(_ weekday: Int) -> Bool {
        weekday == 1 || weekday == 7
    }

    /// Linear-interpolated percentile over the sorted samples.
    func percentile(_ p: Double, weekday: Int, minuteOfDay: Int) -> Double? {
        guard let values = samples(weekday: weekday, minuteOfDay: minuteOfDay) else { return nil }
        return Self.percentile(p, of: values)
    }

    static func percentile(_ p: Double, of sortedValues: [Double]) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        guard sortedValues.count > 1 else { return sortedValues[0] }
        let clamped = min(max(p, 0), 1)
        let position = clamped * Double(sortedValues.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sortedValues[lower] }
        let fraction = position - Double(lower)
        return sortedValues[lower] + (sortedValues[upper] - sortedValues[lower]) * fraction
    }

    /// How unpredictable this route is at this time of day: the gap between the posture's
    /// target percentile and the median. A route that is always 22 minutes has a spread of
    /// zero and earns no padding; one that swings 18–40 earns a lot.
    func spread(posture: ReliabilityPosture, weekday: Int, minuteOfDay: Int) -> Double {
        guard let values = samples(weekday: weekday, minuteOfDay: minuteOfDay),
              let target = Self.percentile(posture.percentile, of: values),
              let median = Self.percentile(0.5, of: values)
        else { return 0 }
        return max(0, target - median)
    }

    /// Seed for the fixed-point solve, and the offline fallback estimate.
    func expectedSeconds(posture: ReliabilityPosture, weekday: Int, minuteOfDay: Int) -> Double? {
        percentile(posture.percentile, weekday: weekday, minuteOfDay: minuteOfDay)
    }

    /// True when the live estimate is worse than almost anything we've recorded here —
    /// surfaced to the user as "unusually heavy for a Tuesday".
    func isAnomalous(observedSeconds: Double, weekday: Int, minuteOfDay: Int) -> Bool {
        guard let values = samples(weekday: weekday, minuteOfDay: minuteOfDay),
              values.count >= Self.minimumSamplesForConfidence,
              let p90 = Self.percentile(0.9, of: values)
        else { return false }
        return observedSeconds > p90
    }
}
