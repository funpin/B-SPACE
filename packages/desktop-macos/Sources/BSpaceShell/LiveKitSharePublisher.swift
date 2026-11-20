import AVFoundation
import BSpaceCore
import CoreVideo
import Foundation
import LiveKit

/// A share's connection to a call through LiveKit's Swift library (the
/// project's fork of it, see the package README): the stream participant.
///
/// What it is given is what it sends. The picture goes from the capture's
/// own pixel buffers into the library's hardware encoder, one encode. The
/// sound goes in as ready samples, in the library's mode without devices:
/// nothing here opens a microphone or a speaker, and the app is never asked
/// for either on its account.
///
/// WebRTC's adaptation to an "overloaded" encoder is switched off
/// (`DegradationPreference.disabled`): it reads the hardware encoder's
/// latency as load and cuts a 60 frames a second share to 40 after about
/// forty seconds, while the encoder keeps up. The shell decides the size and
/// the rate of what it sends.
public final class LiveKitSharePublisher: NSObject, ScreenSharePublisher, RoomDelegate, @unchecked Sendable {
    public var onEvent: ((SharePublisherEvent) -> Void)?

    private var room: Room?
    private var videoTrack: LocalVideoTrack?
    private var videoPublication: LocalTrackPublication?
    private var audioTrack: LocalAudioTrack?
    private var audioPublication: LocalTrackPublication?
    private var statsTimer: Timer?
    private var videoMeter = BitrateMeter()
    private var audioMeter = BitrateMeter()
    /// Asked to leave: what the room says after that is not news.
    private var isLeaving = false
    /// Whether the video is to be paused in the call, whether it is, and
    /// whether a change of that is on its way: one at a time, and the last
    /// one asked for wins.
    private var wantsVideoPaused = false
    private var isVideoPaused = false
    private var isChangingPause = false
    private var wasReconnecting = false

    /// What the capture's and the sound's queues read.
    private let lock = NSLock()
    private var feed: BufferCapturer?
    private var audioFormat: AVAudioFormat?
    private var channels = 2

    /// The bitrate the system's sound is published with: music, not a voice.
    static let audioBitrate = 128_000

    override public init() {
        super.init()
    }

    // MARK: ScreenSharePublisher

    public func connect(url: String, token: String, completion: @escaping (Bool) -> Void) {
        do {
            // Before a room exists: no device of this machine is the
            // library's to open, for sound in or out.
            try AudioManager.shared.setManualRenderingMode(true)
        } catch {
            NSLog("[share] the library refused its mode without devices: %@", String(describing: error))
            completion(false)
            return
        }
        let room = Room()
        self.room = room
        room.add(delegate: self)
        Task {
            do {
                // It hears and sees nobody: its token does not let it.
                try await room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: false))
                // The track exists from here on, so that frames have somewhere
                // to go before it is published: it takes its size from them.
                let track = await LocalVideoTrack.createBufferTrack(reportStatistics: true)
                let feed = track.capturer as? BufferCapturer
                await MainActor.run {
                    guard !self.isLeaving, let feed else {
                        completion(false)
                        return
                    }
                    self.videoTrack = track
                    self.lock.lock()
                    self.feed = feed
                    self.lock.unlock()
                    completion(true)
                }
            } catch {
                NSLog("[share] the call did not let the share in: %@", String(describing: error))
                await MainActor.run { completion(false) }
            }
        }
    }

    public func publishVideo(width: Int, height: Int, settings: SharePublication, completion: @escaping (Bool) -> Void) {
        guard let room, let track = videoTrack else {
            completion(false)
            return
        }
        let options = VideoPublishOptions(
            screenShareEncoding: Self.encoding(
                maxBitrate: settings.maxBitrate, minBitrate: settings.minBitrate, framesPerSecond: settings.framesPerSecond
            ),
            simulcast: false,
            preferredCodec: settings.codec == .h265 ? .h265 : .h264,
            // A viewer that cannot decode H.265 is sent H.264, encoded only
            // while such a viewer watches.
            preferredBackupCodec: settings.codec == .h265 ? .h264 : nil,
            degradationPreference: .maintainFramerateAndResolution
        )
        Task {
            do {
                let publication = try await room.localParticipant.publish(videoTrack: track, options: options)
                await MainActor.run {
                    guard !self.isLeaving else {
                        completion(false)
                        return
                    }
                    self.videoPublication = publication
                    self.startStatistics()
                    // A source that was hidden before there was a track to pause.
                    self.applyVideoPause()
                    completion(true)
                }
            } catch {
                NSLog("[share] the video was not published: %@", String(describing: error))
                await MainActor.run { completion(false) }
            }
        }
    }

    public func setVideoPaused(_ paused: Bool) {
        wantsVideoPaused = paused
        applyVideoPause()
    }

    /// The library's mute of a track: the call's server is told and tells
    /// every viewer, the track sends nothing, and the picture comes back
    /// with a whole frame when it is undone.
    private func applyVideoPause() {
        guard let publication = videoPublication, !isLeaving, !isChangingPause else { return }
        let paused = wantsVideoPaused
        guard paused != isVideoPaused else { return }
        isChangingPause = true
        Task {
            let changed: Bool
            do {
                if paused { try await publication.mute() } else { try await publication.unmute() }
                changed = true
            } catch {
                changed = false
                NSLog("[share] the video was not %@: %@", paused ? "paused" : "resumed", String(describing: error))
            }
            await MainActor.run {
                self.isChangingPause = false
                guard changed else { return }
                self.isVideoPaused = paused
                // Asked for the other way round meanwhile.
                self.applyVideoPause()
            }
        }
    }

    public func send(frame: CVPixelBuffer) {
        lock.lock()
        let feed = self.feed
        lock.unlock()
        feed?.capture(frame)
    }

    public func setEncoding(maxBitrate: Int, minBitrate: Int, framesPerSecond: Int, completion: @escaping (Bool) -> Void) {
        guard let publication = videoPublication else {
            completion(false)
            return
        }
        let encoding = Self.encoding(maxBitrate: maxBitrate, minBitrate: minBitrate, framesPerSecond: framesPerSecond)
        Task {
            do {
                try await publication.set(videoEncoding: encoding)
                await MainActor.run { completion(true) }
            } catch {
                NSLog("[share] the encoding was not changed: %@", String(describing: error))
                await MainActor.run { completion(false) }
            }
        }
    }

    public func publishAudio(format: MediaWire.AudioFormat, completion: @escaping (Bool) -> Void) {
        guard let room, audioPublication == nil,
              let audioFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: Double(format.sampleRate),
                  channels: AVAudioChannelCount(max(1, min(format.channels, 2))), interleaved: false
              ) else {
            completion(false)
            return
        }
        Task {
            // The system's sound as it is: nothing meant for a voice is done to it.
            let track = await LocalAudioTrack.createTrack(
                name: Track.screenShareAudioName,
                source: .screenShareAudio,
                options: AudioCaptureOptions(
                    echoCancellation: false, autoGainControl: false, noiseSuppression: false, highpassFilter: false
                ),
                reportStatistics: true
            )
            do {
                let publication = try await room.localParticipant.publish(
                    audioTrack: track,
                    options: AudioPublishOptions(encoding: AudioEncoding(maxBitrate: Self.audioBitrate), dtx: false, red: false)
                )
                await MainActor.run {
                    guard !self.isLeaving else {
                        completion(false)
                        return
                    }
                    self.audioTrack = track
                    self.audioPublication = publication
                    self.audioMeter = BitrateMeter()
                    self.lock.lock()
                    self.audioFormat = audioFormat
                    self.channels = format.channels
                    self.lock.unlock()
                    completion(true)
                }
            } catch {
                NSLog("[share] the sound was not published: %@", String(describing: error))
                await MainActor.run { completion(false) }
            }
        }
    }

    public func send(audio samples: Data) {
        lock.lock()
        let format = audioFormat
        let channels = self.channels
        lock.unlock()
        guard let format, channels > 0 else { return }
        let frames = samples.count / (MemoryLayout<Float32>.size * channels)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let outChannels = Int(format.channelCount)
        samples.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Float32.self)
            for frame in 0 ..< frames {
                for channel in 0 ..< outChannels {
                    out[channel][frame] = source[frame * channels + min(channel, channels - 1)]
                }
            }
        }
        AudioManager.shared.mixer.capture(appAudio: buffer)
    }

    public func unpublishAudio() {
        lock.lock()
        audioFormat = nil
        lock.unlock()
        guard let room, let publication = audioPublication else { return }
        audioPublication = nil
        audioTrack = nil
        Task {
            try? await room.localParticipant.unpublish(publication: publication)
        }
    }

    public func disconnect() {
        isLeaving = true
        statsTimer?.invalidate()
        statsTimer = nil
        lock.lock()
        feed = nil
        audioFormat = nil
        lock.unlock()
        videoPublication = nil
        audioPublication = nil
        videoTrack = nil
        audioTrack = nil
        guard let room else { return }
        self.room = nil
        room.remove(delegate: self)
        Task {
            await room.disconnect()
        }
    }

    private static func encoding(maxBitrate: Int, minBitrate: Int, framesPerSecond: Int) -> VideoEncoding {
        VideoEncoding(maxBitrate: maxBitrate, maxFps: framesPerSecond, minBitrate: minBitrate)
    }

    // MARK: The connection

    public func room(_: Room, didUpdateConnectionState connectionState: ConnectionState, from _: ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isLeaving else { return }
            switch connectionState {
            case .reconnecting:
                self.wasReconnecting = true
                self.onEvent?(.reconnecting)
            case .connected:
                if self.wasReconnecting {
                    self.wasReconnecting = false
                    self.onEvent?(.reconnected)
                }
            case .disconnected:
                self.onEvent?(.disconnected)
            default:
                break
            }
        }
    }

    // MARK: Statistics

    private func startStatistics() {
        statsTimer?.invalidate()
        videoMeter = BitrateMeter()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.reportStatistics() }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func reportStatistics() {
        guard !isLeaving, let statistics = videoTrack?.statistics, let outbound = statistics.outboundRtpStream.first else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pair = statistics.iceCandidatePair.first(where: { $0.nominated == true }) ?? statistics.iceCandidatePair.first
        let encoder = outbound.encoderImplementation ?? ""
        var audioBitrate: Int?
        if let sound = audioTrack?.statistics?.outboundRtpStream.first {
            audioBitrate = audioMeter.rate(bytes: sound.bytesSent ?? 0, at: now)
        }
        onEvent?(.stats(ScreenShareStats(
            bitrate: videoMeter.rate(bytes: outbound.bytesSent ?? 0, at: now),
            framesPerSecond: outbound.framesPerSecond ?? 0,
            width: Int(outbound.frameWidth ?? 0),
            height: Int(outbound.frameHeight ?? 0),
            codec: statistics.codec.first(where: { $0.id == outbound.codecId })?.mimeType ?? "",
            encoder: encoder,
            hardware: outbound.powerEfficientEncoder ?? encoder.contains("VideoToolbox"),
            roundTripMilliseconds: pair?.currentRoundTripTime.map { $0 * 1000 },
            availableBitrate: pair?.availableOutgoingBitrate.map { Int($0) },
            limitedBy: outbound.qualityLimitationReason?.rawValue,
            audioBitrate: audioBitrate
        )))
    }
}
