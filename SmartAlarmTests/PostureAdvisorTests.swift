import Foundation
import Testing

@testable import SmartAlarm

@Suite("Posture advisor")
struct PostureAdvisorTests {
    private let advisor = PostureAdvisor()

    private func outcomes(onTime: Int, late: Int, skipped: Int = 0) -> [MorningOutcome] {
        Array(repeating: .onTime, count: onTime)
            + Array(repeating: .late, count: late)
            + Array(repeating: .didNotTravel, count: skipped)
    }

    @Test("No outcomes, no opinion")
    func silentWithoutData() {
        #expect(advisor.recommendation(for: [], current: .balanced) == nil)
    }

    @Test("A couple of late mornings isn't enough to act on")
    func waitsForEnoughSamples() {
        #expect(advisor.recommendation(for: outcomes(onTime: 2, late: 2), current: .balanced) == nil)
    }

    @Test("A persistent late rate suggests being more careful")
    func escalatesOnLateness() {
        let recommendation = advisor.recommendation(
            for: outcomes(onTime: 6, late: 3),
            current: .balanced
        )
        #expect(recommendation?.suggested == .cautious)
        #expect(recommendation?.isMoreCautious == true)
    }

    @Test("Already at the most careful setting, there is nothing to suggest")
    func cannotEscalatePastCautious() {
        #expect(advisor.recommendation(for: outcomes(onTime: 5, late: 4), current: .cautious) == nil)
    }

    /// Trading insurance for sleep is the direction that can actually hurt, so it needs a much
    /// longer clean run than tightening up does.
    @Test("Relaxing needs a far longer spotless record than escalating")
    func relaxingIsHarderThanEscalating() {
        // Nine perfect mornings is plenty to escalate on, but not to relax on.
        #expect(advisor.recommendation(for: outcomes(onTime: 9, late: 0), current: .cautious) == nil)

        let recommendation = advisor.recommendation(
            for: outcomes(onTime: 20, late: 0),
            current: .cautious
        )
        #expect(recommendation?.suggested == .balanced)
        #expect(recommendation?.isMoreCautious == false)
    }

    @Test("A single late morning blocks relaxing, however long the record")
    func onelateBlocksRelaxing() {
        #expect(advisor.recommendation(for: outcomes(onTime: 24, late: 1), current: .cautious) == nil)
    }

    @Test("Days you didn't travel say nothing either way")
    func skippedDaysAreExcluded() {
        #expect(!MorningOutcome.didNotTravel.countsTowardCalibration)
        let summary = advisor.summarize(outcomes(onTime: 3, late: 1, skipped: 10))
        #expect(summary.total == 4)
        #expect(summary.lateRate == 0.25)
    }
}

@Suite("Driving weather")
struct DrivingWeatherTests {
    @Test("Worse conditions never buy less time")
    func padsIncreaseWithSeverity() {
        #expect(DrivingWeather.clear.padFraction == 0)
        #expect(DrivingWeather.wet.padFraction > DrivingWeather.wind.padFraction)
        #expect(DrivingWeather.heavyRain.padFraction > DrivingWeather.wet.padFraction)
        #expect(DrivingWeather.snow.padFraction > DrivingWeather.heavyRain.padFraction)
        #expect(DrivingWeather.ice.padFraction > DrivingWeather.snow.padFraction)
    }

    @Test("Only clear weather leaves the estimate alone")
    func onlyClearIsFree() {
        for weather in DrivingWeather.allCases {
            #expect(weather.affectsDriving == (weather != .clear))
            #expect(weather.padFraction >= 0)
        }
    }

    @Test("Weather padding moves the alarm earlier, never later")
    func weatherPadsEarlier() async throws {
        let now = Fixture.date(hour: 9)
        let clear = try await Fixture.solver(Fixture.inputs())
            .solve(now: now, history: Fixture.emptyHistory, estimate: Fixture.constantProvider(minutes: 30))
        let snowy = try await Fixture.solver(Fixture.inputs(weatherPadFraction: DrivingWeather.snow.padFraction))
            .solve(now: now, history: Fixture.emptyHistory, estimate: Fixture.constantProvider(minutes: 30))

        #expect(snowy.padding.weatherSeconds > 0)
        #expect(snowy.wakeTime < clear.wakeTime)
        // 25% of a 30-minute drive.
        #expect(snowy.padding.weatherSeconds == Fixture.minutes(30) * 0.25)
    }

    @Test("With weather off there is no weather term at all")
    func noWeatherTermWhenDisabled() async throws {
        let result = try await Fixture.solver(Fixture.inputs())
            .solve(
                now: Fixture.date(hour: 9),
                history: Fixture.emptyHistory,
                estimate: Fixture.constantProvider(minutes: 30)
            )
        #expect(result.padding.weatherSeconds == 0)
    }
}
