import Foundation
import Testing

@testable import SmartAlarm

@Suite("Historical travel model")
struct HistoricalTravelModelTests {
    @Test("Percentiles interpolate across the sorted samples")
    func percentileInterpolation() {
        let values: [Double] = [10, 20, 30, 40, 50]
        #expect(HistoricalTravelModel.percentile(0.0, of: values) == 10)
        #expect(HistoricalTravelModel.percentile(0.5, of: values) == 30)
        #expect(HistoricalTravelModel.percentile(1.0, of: values) == 50)
        #expect(HistoricalTravelModel.percentile(0.25, of: values) == 20)
    }

    @Test("Percentile of nothing is nothing")
    func percentileOfEmpty() {
        #expect(HistoricalTravelModel.percentile(0.5, of: []) == nil)
        #expect(Fixture.emptyHistory.percentile(0.8, weekday: 5, minuteOfDay: 480) == nil)
    }

    @Test("A single sample is its own percentile")
    func singleSample() {
        #expect(HistoricalTravelModel.percentile(0.9, of: [42]) == 42)
    }

    @Test("Too few samples to be meaningful yields nothing")
    func belowConfidenceThreshold() {
        let model = HistoricalTravelModel(
            samples: [
                .init(weekday: 5, minuteOfDay: 480, seconds: 1800, recordedAt: .now),
                .init(weekday: 5, minuteOfDay: 480, seconds: 1900, recordedAt: .now),
            ]
        )
        #expect(model.percentile(0.5, weekday: 5, minuteOfDay: 480) == nil)
    }

    @Test("Adjacent 15-minute buckets are pulled in when the exact one is thin")
    func widensToNeighbouringBuckets() {
        // Four samples spread across 8:00, 8:15 and 8:30 — none of those buckets alone
        // reaches the confidence threshold.
        let model = HistoricalTravelModel(
            samples: [
                .init(weekday: 5, minuteOfDay: 480, seconds: 1800, recordedAt: .now),
                .init(weekday: 5, minuteOfDay: 495, seconds: 1860, recordedAt: .now),
                .init(weekday: 5, minuteOfDay: 495, seconds: 1900, recordedAt: .now),
                .init(weekday: 5, minuteOfDay: 510, seconds: 1950, recordedAt: .now),
            ]
        )
        #expect(model.percentile(0.5, weekday: 5, minuteOfDay: 495) != nil)
    }

    @Test("A different weekday at a similar hour is a valid last resort")
    func fallsBackAcrossWeekdays() {
        let model = HistoricalTravelModel(
            samples: (0..<6).map { index in
                .init(weekday: 3, minuteOfDay: 480, seconds: 1800 + Double(index) * 60, recordedAt: .now)
            }
        )
        // Asking about Thursday when everything recorded is Tuesday still answers, because
        // both are weekdays at the same hour.
        #expect(model.percentile(0.5, weekday: 5, minuteOfDay: 480) != nil)
    }

    @Test("Spread is the gap between the posture's target and the median")
    func spreadMeasuresVariability() {
        let steady = Fixture.history(secondsValues: Array(repeating: 1800, count: 8))
        let erratic = Fixture.history(
            secondsValues: [1200, 1400, 1600, 1800, 2000, 2400, 2800, 3200]
        )

        #expect(steady.spread(posture: .balanced, weekday: 5, minuteOfDay: 480) == 0)
        #expect(erratic.spread(posture: .balanced, weekday: 5, minuteOfDay: 480) > 0)
        // A more cautious posture reaches further up the distribution.
        #expect(
            erratic.spread(posture: .cautious, weekday: 5, minuteOfDay: 480)
                >= erratic.spread(posture: .balanced, weekday: 5, minuteOfDay: 480)
        )
    }

    @Test("Posture selects which percentile becomes the expected drive time")
    func expectedSecondsFollowsPosture() {
        let model = Fixture.history(
            secondsValues: [1200, 1400, 1600, 1800, 2000, 2400, 2800, 3200]
        )
        let relaxed = model.expectedSeconds(posture: .relaxed, weekday: 5, minuteOfDay: 480)!
        let balanced = model.expectedSeconds(posture: .balanced, weekday: 5, minuteOfDay: 480)!
        let cautious = model.expectedSeconds(posture: .cautious, weekday: 5, minuteOfDay: 480)!

        #expect(relaxed < balanced)
        #expect(balanced < cautious)
    }

    @Test("Traffic well past the historical p90 reads as anomalous")
    func anomalyDetection() {
        let model = Fixture.history(
            secondsValues: [1700, 1750, 1800, 1850, 1900, 1950]
        )
        #expect(model.isAnomalous(observedSeconds: 3600, weekday: 5, minuteOfDay: 480))
        #expect(!model.isAnomalous(observedSeconds: 1800, weekday: 5, minuteOfDay: 480))
    }

    @Test("With no history, nothing is anomalous")
    func noHistoryMeansNoAnomaly() {
        #expect(!Fixture.emptyHistory.isAnomalous(observedSeconds: 9999, weekday: 5, minuteOfDay: 480))
    }

    @Test("Buckets are 15 minutes wide")
    func bucketing() {
        #expect(HistoricalTravelModel.bucket(forMinuteOfDay: 0) == 0)
        #expect(HistoricalTravelModel.bucket(forMinuteOfDay: 14) == 0)
        #expect(HistoricalTravelModel.bucket(forMinuteOfDay: 15) == 1)
        #expect(HistoricalTravelModel.bucket(forMinuteOfDay: 480) == 32)
    }
}
