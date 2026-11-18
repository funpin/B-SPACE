import AppKit
import BSpaceCore
import CoreMedia
import ScreenCaptureKit

/// Where the sound of the system comes from.
public protocol SystemAudioCapturer: AnyObject {
    /// Called on the main queue when the capture ended by itself: the
    /// permission was taken away, the system stopped the stream.
    var onEnded: (() -> Void)? { get set }

    /// Starts the sound. `samples` is called on a queue of the capturer's
    /// own with samples in `format`, as `SystemAudio.interleaved` lays them
    /// out, and the moment they were captured (milliseconds since 1970).
    /// Answers on the main queue: nil when the capture started.
    func start(
        format: MediaWire.AudioFormat,
        samples: @escaping (Data, Double) -> Void,
        completion: @escaping (ScreenCaptureFailure?) -> Void
    )

    func stop()
}

/// Everything the Mac plays except this app, through ScreenCaptureKit.
///
/// The app is named in the content filter's excluded applications. The
/// system counts the sound of the web view's helper processes as the app's
/// (measured with CaptureProbe; see the package README), so the call and the
/// app's own sounds stay out and viewers do not hear themselves. That holds
/// for an app started the usual way: one started from a terminal has its
/// helpers counted as the terminal's, and hears itself.
///
/// A stream cannot be of sound alone, so it also takes a picture two pixels
/// wide once a second, which nobody reads.
public final class SystemSoundCapturer: NSObject, SystemAudioCapturer, SCStreamOutput, SCStreamDelegate {
    public var onEnded: (() -> Void)?

    private let queue = DispatchQueue(label: "system-audio-capture", qos: .userInteractive)
    private var stream: SCStream?
    private var format: MediaWire.AudioFormat?
    private var samples: ((Data, Double) -> Void)?
    private var isStopped = false
    /// Only on `queue`: whether samples in an unexpected shape were
    /// reported already.
    private var hasComplained = false

    public func start(
        format: MediaWire.AudioFormat,
        samples: @escaping (Data, Double) -> Void,
        completion: @escaping (ScreenCaptureFailure?) -> Void
    ) {
        guard CGPreflightScreenCaptureAccess() else {
            // The system asks the user the first time and does nothing after.
            CGRequestScreenCaptureAccess()
            completion(.noPermission)
            return
        }
        self.format = format
        self.samples = samples
        Task { @MainActor in
            let content: SCShareableContent
            do {
                // Every application, with a window on screen or not: the app
                // itself may be in the tray with its window closed.
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                NSLog("[system-audio] the system did not list what can be captured: %@", error.localizedDescription)
                completion(.failed)
                return
            }
            guard !self.isStopped else {
                completion(.failed)
                return
            }
            // The sound is the applications', not a display's; the filter
            // still has to name one.
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
                NSLog("[system-audio] no display to build the capture on")
                completion(.failed)
                return
            }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            if own.isEmpty {
                NSLog("[system-audio] the app is not among the applications the system lists; its own sound may be captured")
            }

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = format.sampleRate
            configuration.channelCount = format.channels
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false

            let stream = SCStream(
                filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                configuration: configuration, delegate: self
            )
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                // Without an output for the picture the system logs every
                // frame it has nowhere to put.
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                NSLog("[system-audio] the stream would not take an output: %@", error.localizedDescription)
                completion(.failed)
                return
            }
            self.stream = stream
            do {
                try await stream.startCapture()
            } catch {
                NSLog("[system-audio] the capture did not start: %@", error.localizedDescription)
                self.stream = nil
                completion(.failed)
                return
            }
            if self.isStopped {
                // Stopped while it was starting.
                try? await stream.stopCapture()
                completion(.failed)
                return
            }
            completion(nil)
        }
    }

    public func stop() {
        isStopped = true
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let format,
              let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat, description.mBitsPerChannel == 32,
              Int(description.mSampleRate) == format.sampleRate,
              Int(description.mChannelsPerFrame) == format.channels else {
            if !hasComplained {
                hasComplained = true
                NSLog(
                    "[system-audio] the system gave %d channel(s) at %.0f Hz, %d bits, flags %u; asked for %d at %d",
                    description.mChannelsPerFrame, description.mSampleRate, description.mBitsPerChannel,
                    description.mFormatFlags, format.channels, format.sampleRate
                )
            }
            return
        }
        let isInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var payload: Data?
        try? sampleBuffer.withAudioBufferList { list, _ in
            if isInterleaved {
                guard let first = list.first, let bytes = first.mData else { return }
                payload = Data(bytes: bytes, count: Int(first.mDataByteSize))
            } else {
                let planes = list.compactMap { buffer -> UnsafeBufferPointer<Float32>? in
                    guard let bytes = buffer.mData else { return nil }
                    return UnsafeBufferPointer(
                        start: bytes.assumingMemoryBound(to: Float32.self),
                        count: Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
                    )
                }
                payload = SystemAudio.interleaved(planes, channels: format.channels)
            }
        }
        guard let payload, !payload.isEmpty else { return }

        // The sample is stamped on the host's clock; the page's is the wall clock.
        let age = CACurrentMediaTime() - CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        samples?(payload, (Date().timeIntervalSince1970 - age) * 1000)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[system-audio] the capture ended: %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.stream = nil
            self.onEnded?()
        }
    }
}

/// One capture of the system's sound, on a local media channel.
final class SystemAudioSession {
    /// Called on the main queue when the capture ended by itself.
    var onEnded: (() -> Void)?

    private let capturer: SystemAudioCapturer
    private let channel: LocalMediaChannel
    private let format: MediaWire.AudioFormat

    init(capturer: SystemAudioCapturer, channel: LocalMediaChannel, format: MediaWire.AudioFormat) {
        self.capturer = capturer
        self.channel = channel
        self.format = format
    }

    /// Starts the capture. Answers on the main queue: nil when it started.
    func start(_ completion: @escaping (ScreenCaptureFailure?) -> Void) {
        capturer.onEnded = { [weak self] in
            self?.onEnded?()
        }
        let channel = self.channel
        let announcement = format.message
        channel.onClientConnected = { [weak channel] in
            channel?.send(text: announcement)
        }
        // Samples from before the page connected go nowhere, and samples the
        // channel cannot take are dropped: sound that is late is worth less
        // than a gap.
        capturer.start(format: format, samples: { [weak channel] payload, capturedAt in
            channel?.send(MediaWire.message(kind: .audio, capturedAt: capturedAt, payload: payload))
        }, completion: completion)
    }

    func stop() {
        capturer.onEnded = nil
        capturer.stop()
        channel.onClientConnected = nil
    }
}
