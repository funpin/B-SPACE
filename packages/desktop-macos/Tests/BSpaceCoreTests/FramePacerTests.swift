import Foundation
import Testing
@testable import BSpaceCore

/// Frames a source gives over `seconds`, one every `step` seconds, each
/// shifted by what `jitter` says for its number.
private func taken(
    rate: Int, step: Double, seconds: Double, jitter: (Int) -> Double = { _ in 0 }
) -> Int {
    var pacer = FramePacer(framesPerSecond: rate)
    var count = 0
    var index = 0
    while Double(index) * step < seconds {
        if pacer.takes(at: Double(index) * step + jitter(index)) { count += 1 }
        index += 1
    }
    return count
}

@Suite struct FramePacerTests {
    @Test func aSourceTwiceAsFastGivesEveryOtherFrame() {
        // A 120 Hz display, 60 asked for.
        #expect(abs(taken(rate: 60, step: 1.0 / 120, seconds: 10) - 600) <= 1)
        #expect(abs(taken(rate: 30, step: 1.0 / 120, seconds: 10) - 300) <= 1)
    }

    @Test func aSourceALittleFasterThanTheRateIsTrimmedToIt() {
        // What the system gives when asked for frames with room to spare.
        #expect(abs(taken(rate: 60, step: 1.0 / 66.9, seconds: 10) - 600) <= 2)
        #expect(abs(taken(rate: 30, step: 1.0 / 38.3, seconds: 10) - 300) <= 2)
    }

    @Test func aRateTheDisplaysGridDoesNotHoldIsKeptOnAverage() {
        // 45 a second out of refreshes 120 times a second: the gaps are
        // two and three refreshes by turns, and the count is still the rate.
        #expect(abs(taken(rate: 45, step: 1.0 / 120, seconds: 10) - 450) <= 2)
    }

    @Test func aSlowerSourceHasEveryFrameTaken() {
        #expect(taken(rate: 60, step: 1.0 / 24, seconds: 10) == 240)
        #expect(taken(rate: 60, step: 1.0 / 60, seconds: 10) == 600)
    }

    @Test func framesAHairEarlyOrLateDoNotAddUp() {
        // Every frame up to a millisecond off its time, by turns.
        let count = taken(rate: 60, step: 1.0 / 120, seconds: 30) { $0 % 3 == 0 ? -0.001 : ($0 % 3 == 1 ? 0.001 : 0) }
        #expect(abs(count - 1800) <= 2)
    }

    @Test func aScreenThatStoodStillDoesNotMakeUpForIt() {
        var pacer = FramePacer(framesPerSecond: 60)
        let first = pacer.takes(at: 0)
        #expect(first)
        // Five seconds of nothing, then frames at 120 a second again.
        var count = 0
        for index in 0 ..< 120 where pacer.takes(at: 5 + Double(index) / 120) { count += 1 }
        #expect(abs(count - 60) <= 1)
    }

    @Test func theFirstFrameIsTakenAndARateOfNothingIsOne() {
        var pacer = FramePacer(framesPerSecond: 0)
        #expect(pacer.interval == 1)
        let answers = [pacer.takes(at: 100), pacer.takes(at: 100.5), pacer.takes(at: 101)]
        #expect(answers == [true, false, true])
    }
}
