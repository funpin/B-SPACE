import Foundation

/// The sound of the system, for a share: everything the Mac plays except
/// what this app plays itself (the call, its own sounds), so that viewers do
/// not hear themselves.
///
/// It is a capture of its own, apart from the video's: the System Audio
/// switch turns it on and off while the picture goes on, and one content
/// filter cannot keep the app's window in the picture and its sound out of
/// the audio. The page starts it with `startNativeSystemAudio()`, reads it
/// from a local media channel and stops it by its id.
public enum SystemAudio {
    /// What the shell asks the system for and announces to the page. 48 kHz
    /// stereo is what a call's music-grade audio track carries, so nothing
    /// is resampled on the way.
    public static let format = MediaWire.AudioFormat(sampleRate: 48_000, channels: 2)

    /// How many the page may have at once: the share that runs and the
    /// preview of the one it is about to switch to, with room to spare.
    public static let mostAtOnce = 4

    /// Samples the system gave one channel at a time, as the page takes
    /// them: frame after frame, each channel's sample in turn, 32-bit floats
    /// in the byte order of the machine (little-endian on every Mac).
    ///
    /// Nil when the channels are not the number announced or do not agree
    /// on how many frames there are: the page would play them as noise.
    public static func interleaved(_ planes: [UnsafeBufferPointer<Float32>], channels: Int) -> Data? {
        guard channels > 0, planes.count == channels, let frames = planes.first?.count,
              planes.allSatisfy({ $0.count == frames }) else { return nil }
        var data = Data(count: frames * channels * MemoryLayout<Float32>.size)
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Float32.self)
            for (channel, plane) in planes.enumerated() {
                var index = channel
                for sample in plane {
                    samples[index] = sample
                    index += channels
                }
            }
        }
        return data
    }

    /// What `getSystemAudioCapability` answers: what a system-audio share
    /// from this client carries of the app's own playback.
    ///
    /// `excluded` for a web client that says it takes the shell's capture
    /// (`getSystemAudioCapability({ nativeAudio: true })`) when the shell can
    /// give one. A web client from before it captures through WebKit, which
    /// gives a share no system audio at all: `unavailable`.
    public static func capability(arguments: BridgeArguments, shellCanCapture: Bool) -> String {
        guard shellCanCapture,
              let number = arguments.object(at: 0)?["nativeAudio"] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID(), number.boolValue else { return "unavailable" }
        return "excluded"
    }
}

/// What the page is told when it asks for the system's sound.
public enum SystemAudioReply: Equatable {
    /// The capture runs: the id to stop it by, where to connect, what to
    /// say first, and the shape of the samples that will come.
    case started(id: String, url: String, token: String, format: MediaWire.AudioFormat)
    case refused(ScreenCaptureFailure)

    public var bridgeValue: [String: Any] {
        switch self {
        case .started(let id, let url, let token, let format):
            return [
                "ok": true, "id": id, "url": url, "token": token,
                "sampleRate": format.sampleRate, "channels": format.channels,
            ]
        case .refused(let failure):
            return ["ok": false, "reason": failure.rawValue]
        }
    }
}
