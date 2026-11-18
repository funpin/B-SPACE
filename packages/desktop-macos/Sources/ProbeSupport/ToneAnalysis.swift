import Foundation

/// How loud one frequency is in a recording.
///
/// CaptureProbe plays a tone of its own frequency through each audio path of a
/// web view and then asks which of them a capture heard. Looking at one
/// frequency, not at the level of the whole recording, keeps whatever else the
/// machine is playing out of the answer.
public enum ToneAnalysis {
    /// Peak amplitude of the sine at `frequency` in `samples`, on the scale the
    /// samples use: a full-scale sine gives 1. The Goertzel recurrence, which
    /// is one bin of a Fourier transform.
    public static func amplitude(of samples: [Float], sampleRate: Double, frequency: Double) -> Double {
        guard !samples.isEmpty, sampleRate > 0 else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        return 2 * sqrt(max(power, 0)) / Double(samples.count)
    }

    /// Root mean square of the whole recording.
    public static func rootMeanSquare(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        return sqrt(sum / Double(samples.count))
    }

    /// Decibels relative to full scale; silence is reported as -160.
    public static func decibels(_ amplitude: Double) -> Double {
        guard amplitude > 1e-8 else { return -160 }
        return 20 * log10(amplitude)
    }

    public enum Presence: String, Equatable {
        case present
        case absent
        /// Neither at the level the tone was played at nor clearly below it.
        case unclear
    }

    /// A tone within this many decibels of the level it was played at is present.
    public static let presentWithin = 3.0
    /// A tone at least this many decibels under the level it was played at is absent.
    public static let absentBelow = 10.0

    /// Whether a recording holds a tone, judged against the amplitude it was
    /// played at. A system capture records an application's sound at the
    /// level the application gave it, so a tone that got through reads at
    /// its own amplitude. Music playing on the machine at the same time
    /// puts some energy at every frequency, which is why absence is "well
    /// below", not "silent", and why comparing a frequency with the ones
    /// next to it does not work: next to it there may be a note.
    public static func presence(amplitude: Double, played: Double) -> Presence {
        let difference = decibels(amplitude) - decibels(played)
        if abs(difference) <= presentWithin { return .present }
        if difference <= -absentBelow { return .absent }
        return .unclear
    }
}
