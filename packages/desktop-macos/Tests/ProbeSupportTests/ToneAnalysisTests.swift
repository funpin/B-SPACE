import Foundation
import Testing
@testable import ProbeSupport

@Suite struct ToneAnalysisTests {
    private func sine(frequency: Double, amplitude: Double, seconds: Double = 2, sampleRate: Double = 48_000) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { index in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func mix(_ signals: [Float]...) -> [Float] {
        guard let first = signals.first else { return [] }
        return first.indices.map { index in signals.reduce(Float(0)) { $0 + $1[index] } }
    }

    /// Noise as loud as music played at a high volume; a fixed sequence, so
    /// the tests read the same numbers on every run.
    private func loudNoise() -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0..<96_000).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
    }

    private func presence(of frequency: Double, in samples: [Float], played: Double) -> ToneAnalysis.Presence {
        ToneAnalysis.presence(
            amplitude: ToneAnalysis.amplitude(of: samples, sampleRate: 48_000, frequency: frequency),
            played: played
        )
    }

    @Test func readsTheAmplitudeOfATone() {
        let samples = sine(frequency: 700, amplitude: 0.05)
        let amplitude = ToneAnalysis.amplitude(of: samples, sampleRate: 48_000, frequency: 700)
        #expect(abs(amplitude - 0.05) < 0.0005)
        #expect(presence(of: 700, in: samples, played: 0.05) == .present)
    }

    @Test func tellsTheProbeTonesApart() {
        // Two of the tones play; a third frequency must read as absent however
        // loud the others are.
        let samples = mix(sine(frequency: 700, amplitude: 0.05), sine(frequency: 1500, amplitude: 0.05))
        #expect(presence(of: 700, in: samples, played: 0.05) == .present)
        #expect(presence(of: 1500, in: samples, played: 0.05) == .present)
        #expect(presence(of: 1100, in: samples, played: 0.05) == .absent)
    }

    @Test func aToneIsFoundUnderLoudNoise() {
        let noise = loudNoise()
        #expect(ToneAnalysis.rootMeanSquare(of: noise) > 0.25)
        #expect(presence(of: 1100, in: noise, played: 0.05) == .absent)
        #expect(presence(of: 1100, in: mix(noise, sine(frequency: 1100, amplitude: 0.05)), played: 0.05) == .present)
    }

    @Test func aToneAtAnotherLevelIsUnclear() {
        // Half the amplitude it was played at is 6 dB down: not the tone as it
        // was played, and not gone either.
        let samples = sine(frequency: 700, amplitude: 0.025)
        #expect(presence(of: 700, in: samples, played: 0.05) == .unclear)
        #expect(ToneAnalysis.presence(amplitude: 0.2, played: 0.05) == .unclear)
    }

    @Test func silenceIsAbsent() {
        let samples = [Float](repeating: 0, count: 48_000)
        #expect(ToneAnalysis.amplitude(of: samples, sampleRate: 48_000, frequency: 700) == 0)
        #expect(ToneAnalysis.rootMeanSquare(of: samples) == 0)
        #expect(ToneAnalysis.decibels(0) == -160)
        #expect(presence(of: 700, in: samples, played: 0.05) == .absent)
    }

    @Test func anEmptyRecordingIsAbsent() {
        #expect(ToneAnalysis.amplitude(of: [], sampleRate: 48_000, frequency: 700) == 0)
        #expect(ToneAnalysis.rootMeanSquare(of: []) == 0)
    }

    @Test func rootMeanSquareOfASine() {
        let level = ToneAnalysis.rootMeanSquare(of: sine(frequency: 1100, amplitude: 0.5))
        #expect(abs(level - 0.5 / sqrt(2)) < 0.001)
    }

    @Test func decibelsOfFullScale() {
        #expect(ToneAnalysis.decibels(1) == 0)
        #expect(abs(ToneAnalysis.decibels(0.05) + 26.02) < 0.01)
    }
}
