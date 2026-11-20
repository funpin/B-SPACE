// The stage 4 experiment of plan section 12 (12.8-A): can the shell publish a
// screen share into a LiveKit room by itself, with one hardware encode.
//
// It joins a room with a token read from a file, publishes a video track fed
// with frames of its own (made up, or a real display through the shell's
// SystemScreenCapturer) and, when asked, a sound track fed with ready samples,
// and prints once a second what WebRTC says about the encoder, the frame rate,
// the bitrate, the network path and this process's CPU. With a second token it
// also joins as a viewer and prints what arrives through the server.
//
//   StreamProbe --url wss://… --token-file <path> [--viewer-token-file <path>]
//               [--source synthetic|display] [--width 1920] [--height 1080]
//               [--fps 60] [--codec h264|h265|vp9|vp8|av1] [--backup vp8|h264]
//               [--bitrate 8000] [--seconds 20] [--audio none|tone|system]
//               [--floor <kbit/s>] [--rebitrate <kbit/s>] [--change]
//               [--degradation resolution|framerate|balanced|disabled]
//   StreamProbe --url wss://… --token-file <viewer's token> --watch [--seconds 20]
//
// --source display shows the system's screen recording indicator and sends
// what is on the display to the room; nothing is saved. --audio tone feeds a
// made-up tone to the room only: nothing is played on this machine. --change
// halves the frame rate and then the size in the middle of the run, to see
// whether the track follows without being published again. --floor gives the
// encoding a bitrate it is not taken below whatever the bandwidth estimate
// says; --rebitrate changes the bitrate ceiling in the middle of the run.
// Both, and the sound's label, need the library's fork (plan 12.8, step Г0).
//
// Run by hand. Nothing here is part of the app.

import AVFoundation
import BSpaceCore
import BSpaceShell
import CoreAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import LiveKit

// MARK: - Arguments

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func stop(_ message: String) -> Never {
    FileHandle.standardError.write(Data("StreamProbe: \(message)\n".utf8))
    exit(1)
}

guard let url = argument("--url"), let tokenFile = argument("--token-file") else {
    stop("--url and --token-file are needed")
}

func token(at path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { stop("cannot read \(path)") }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

let publisherToken = token(at: tokenFile)
let viewerToken = argument("--viewer-token-file").map(token(at:))
let sourceKind = argument("--source") ?? "synthetic"
var width = Int(argument("--width") ?? "") ?? 1920
var height = Int(argument("--height") ?? "") ?? 1080
let framesPerSecond = Int(argument("--fps") ?? "") ?? 60
let codecName = argument("--codec") ?? "h264"
let backupName = argument("--backup")
let bitrateKbps = Int(argument("--bitrate") ?? "") ?? 8000
let seconds = Int(argument("--seconds") ?? "") ?? 20
let floorKbps = Int(argument("--floor") ?? "") ?? 0
let rebitrateKbps = Int(argument("--rebitrate") ?? "")
/// What WebRTC may give up when it decides the encoder cannot keep up:
/// `resolution` keeps the size and lowers the frame rate, `disabled` lets
/// it change neither.
let degradationName = argument("--degradation") ?? "resolution"
let audioKind = argument("--audio") ?? "none"
let changes = CommandLine.arguments.contains("--change")

func codec(_ name: String) -> VideoCodec {
    switch name {
    case "h264": return .h264
    case "h265": return .h265
    case "vp9": return .vp9
    case "vp8": return .vp8
    case "av1": return .av1
    default: stop("unknown codec \(name)")
    }
}

// MARK: - The microphone: is anything holding the input device open

func inputDeviceIsRunning() -> Bool? {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
          device != 0 else { return nil }
    var running = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return nil }
    return running != 0
}

func microphoneState() -> String {
    let permission: String
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined: permission = "not asked"
    case .authorized: permission = "granted"
    case .denied: permission = "denied"
    case .restricted: permission = "restricted"
    @unknown default: permission = "?"
    }
    let running = inputDeviceIsRunning().map { $0 ? "open by someone" : "closed" } ?? "?"
    return "permission \(permission), input device \(running)"
}

// MARK: - CPU of this process

func processorSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

// MARK: - The interface an address belongs to (the name only, not the address)

func interfaceName(of address: String?) -> String {
    guard let address else { return "?" }
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return "?" }
    defer { freeifaddrs(list) }
    var found = "not this machine's"
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        if let socketAddress = entry.pointee.ifa_addr,
           socketAddress.pointee.sa_family == UInt8(AF_INET) || socketAddress.pointee.sa_family == UInt8(AF_INET6) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
               String(cString: host).split(separator: "%").first.map(String.init) == address {
                found = String(cString: entry.pointee.ifa_name)
                break
            }
        }
        cursor = entry.pointee.ifa_next
    }
    return found
}

// MARK: - Made-up frames

/// A few frames drawn once and shown in turn: a gradient that moves and a
/// small block of noise (a large one cannot be compressed, and the encoder
/// then drops frames to keep the bitrate), so that every frame differs from the one before and the
/// encoder has work to do, while making them costs this process nothing
/// during the run.
final class MadeUpFrames {
    private(set) var frames: [CVPixelBuffer] = []

    init(width: Int, height: Int, count: Int = 12) {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0 ..< count {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &made)
            guard let buffer = made else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let shift = index * width / count
                for y in 0 ..< height {
                    let row = luma.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    let inNoise = y < 32
                    for x in 0 ..< width {
                        if inNoise, x < 32 {
                            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                            row[x] = UInt8(truncatingIfNeeded: seed >> 33) & 0x7F &+ 40
                        } else {
                            row[x] = UInt8(16 + ((x + shift) * 219 / width + y / 8) % 219)
                        }
                    }
                }
            }
            if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
                memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            frames.append(buffer)
        }
    }
}

// MARK: - Counting what a viewer is given

final class FrameCounter: NSObject, VideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var size = ""

    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }
    nonisolated func set(size _: CGSize) {}
    nonisolated func render(frame: VideoFrame) {
        lock.lock()
        count += 1
        size = "\(frame.dimensions.width)x\(frame.dimensions.height)"
        lock.unlock()
    }

    nonisolated func render(frame: VideoFrame, captureDevice _: AVCaptureDevice?, captureOptions _: VideoCaptureOptions?) {
        render(frame: frame)
    }

    func take() -> (frames: Int, size: String) {
        lock.lock()
        defer { count = 0; lock.unlock() }
        return (count, size)
    }
}

final class SoundMeter: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var sum = 0.0
    private var samples = 0

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let channel = pcmBuffer.floatChannelData?[0] else {
            if let whole = pcmBuffer.int16ChannelData?[0] {
                var total = 0.0
                for index in 0 ..< Int(pcmBuffer.frameLength) {
                    let value = Double(whole[index]) / 32768
                    total += value * value
                }
                lock.lock(); sum += total; samples += Int(pcmBuffer.frameLength); lock.unlock()
            }
            return
        }
        var total = 0.0
        for index in 0 ..< Int(pcmBuffer.frameLength) {
            total += Double(channel[index]) * Double(channel[index])
        }
        lock.lock(); sum += total; samples += Int(pcmBuffer.frameLength); lock.unlock()
    }

    func take() -> String {
        lock.lock()
        defer { sum = 0; samples = 0; lock.unlock() }
        guard samples > 0 else { return "no samples" }
        return String(format: "rms %.3f over %d samples", (sum / Double(samples)).squareRoot(), samples)
    }
}

/// What a viewer's connection was given during the last second.
final class Watching {
    private let counter = FrameCounter()
    private let meter = SoundMeter()
    private var attachedVideo = false
    private var attachedSound = false
    private var received = UInt64(0)
    private var soundReceived = UInt64(0)

    func line(for room: Room, over interval: Double) -> String {
        var line = ""
        for participant in room.remoteParticipants.values {
            for publication in participant.trackPublications.values {
                guard let remote = publication.track else { continue }
                if let video = remote as? RemoteVideoTrack {
                    if !attachedVideo { video.add(videoRenderer: counter); attachedVideo = true }
                    let given = counter.take()
                    if let statistics = video.statistics, let inbound = statistics.inboundRtpStream.first {
                        let bytes = inbound.bytesReceived ?? 0
                        let mime = statistics.codec.first(where: { $0.id == inbound.codecId })?.mimeType ?? "?"
                        line += String(
                            format: "  |  viewer %@ %@ given %d frames, decodes %.0f fps with %@, %d kbit/s, lost %d, freezes %d",
                            mime, given.size, given.frames, inbound.framesPerSecond ?? 0, inbound.decoderImplementation ?? "?",
                            kilobits(bytes, received, over: interval), inbound.packetsLost ?? 0, inbound.freezeCount ?? 0
                        )
                        received = bytes
                    } else {
                        line += "  |  viewer \(given.size) given \(given.frames) frames"
                    }
                } else if let sound = remote as? RemoteAudioTrack {
                    if !attachedSound { sound.add(audioRenderer: meter); attachedSound = true }
                    let bytes = sound.statistics?.inboundRtpStream.first?.bytesReceived ?? 0
                    line += "  sound (\(publication.source)) \(kilobits(bytes, soundReceived, over: interval)) kbit/s, \(meter.take())"
                    soundReceived = bytes
                }
            }
        }
        return line
    }
}

// MARK: - The run

func kilobits(_ bytes: UInt64, _ before: UInt64, over interval: Double) -> Int {
    bytes >= before ? Int(Double(bytes - before) * 8 / 1000 / interval) : 0
}

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

let run = Task {
    say("LiveKit \(LiveKitSDK.version); the microphone before anything: \(microphoneState())")

    // No device of this machine is opened for sound: what the room is sent
    // is what this process hands over, and what the room sends is not played.
    do {
        try AudioManager.shared.setManualRenderingMode(true)
    } catch {
        stop("the manual sound mode was refused: \(error)")
    }

    if CommandLine.arguments.contains("--watch") {
        let room = Room()
        do {
            try await room.connect(
                url: url, token: publisherToken,
                connectOptions: ConnectOptions(autoSubscribe: true),
                roomOptions: RoomOptions(reportRemoteTrackStatistics: true)
            )
        } catch {
            stop("the viewer could not join the room: \(error)")
        }
        say("watching as \(room.localParticipant.identity?.stringValue ?? "?")")
        let watching = Watching()
        var processor = processorSeconds()
        for second in 1 ... seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = processorSeconds()
            let attributes = room.remoteParticipants.values.map { "\($0.identity?.stringValue ?? "?") \($0.attributes)" }.joined(separator: ", ")
            say(String(format: "%2d s  cpu %3.0f %%", second, (now - processor) * 100) + watching.line(for: room, over: 1) + (second == 2 ? "\n       in the room: \(attributes)" : ""))
            processor = now
        }
        await room.disconnect()
        exit(0)
    }

    // Frames.
    var madeUp: MadeUpFrames?
    var smaller: MadeUpFrames?
    let capturer = SystemScreenCapturer()
    if sourceKind == "display" {
        let request = ScreenCaptureRequest(source: .display(CGMainDisplayID()), maxWidth: width, maxHeight: height, framesPerSecond: framesPerSecond)
        let prepared = await withCheckedContinuation { continuation in
            capturer.prepare(request) { continuation.resume(returning: $0) }
        }
        guard case .success(let size) = prepared else { stop("the capture was refused: \(prepared)") }
        width = size.width
        height = size.height
    } else {
        madeUp = MadeUpFrames(width: width, height: height)
        if changes { smaller = MadeUpFrames(width: width / 2 & ~1, height: height / 2 & ~1) }
    }
    say("the video: \(sourceKind), \(width)x\(height) at \(framesPerSecond) frames a second, \(codecName)\(backupName.map { " with \($0) kept for viewers that need it" } ?? ""), up to \(bitrateKbps) kbit/s")

    let room = Room()
    do {
        try await room.connect(url: url, token: publisherToken, connectOptions: ConnectOptions(autoSubscribe: false))
    } catch {
        stop("could not join the room: \(error)")
    }
    say("joined the room as \(room.localParticipant.identity?.stringValue ?? "?")")

    let track = await LocalVideoTrack.createBufferTrack(
        options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(width), height: Int32(height)), fps: framesPerSecond),
        reportStatistics: true
    )
    guard let feed = track.capturer as? BufferCapturer else { stop("the track has no buffer capturer") }

    // The feed: a timer for made-up frames, the capturer's own queue for a
    // real display. `divider` and `useSmaller` are what --change turns.
    let feedState = FeedState()
    var timer: DispatchSourceTimer?
    if let madeUp {
        let queue = DispatchQueue(label: "space.b.stream-probe.frames", qos: .userInteractive)
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0 / Double(framesPerSecond), leeway: .microseconds(200))
        var index = 0
        source.setEventHandler {
            index += 1
            let (divider, useSmaller) = feedState.read()
            guard index % divider == 0 else { return }
            let frames = (useSmaller ? smaller?.frames : nil) ?? madeUp.frames
            feed.capture(frames[index % frames.count])
        }
        source.resume()
        timer = source
    } else {
        var index = 0
        let began = await withCheckedContinuation { continuation in
            capturer.begin(frame: { frame, _, _ in
                index += 1
                guard index % feedState.read().divider == 0 else { return }
                feed.capture(frame)
            }, completion: { continuation.resume(returning: $0) })
        }
        guard began else { stop("the capture did not begin") }
    }

    let degradation: DegradationPreference
    switch degradationName {
    case "resolution": degradation = .maintainResolution
    case "framerate": degradation = .maintainFramerate
    case "balanced": degradation = .balanced
    case "disabled": degradation = .maintainFramerateAndResolution
    default: stop("unknown degradation preference \(degradationName)")
    }
    let publishOptions = VideoPublishOptions(
        screenShareEncoding: VideoEncoding(maxBitrate: bitrateKbps * 1000, maxFps: framesPerSecond, minBitrate: floorKbps * 1000),
        simulcast: false,
        preferredCodec: codec(codecName),
        preferredBackupCodec: backupName.map(codec),
        degradationPreference: degradation
    )
    let started = Date()
    let publication: LocalTrackPublication
    do {
        publication = try await room.localParticipant.publish(videoTrack: track, options: publishOptions)
    } catch {
        stop("the video was not published: \(error)")
    }
    say(String(format: "the video was published %.2f s after it was asked for", Date().timeIntervalSince(started)))

    // Sound: ready samples handed to the library's mixer.
    var soundTrack: LocalAudioTrack?
    var toneTimer: DispatchSourceTimer?
    let systemSound = SystemSoundCapturer()
    if audioKind != "none" {
        let made = await LocalAudioTrack.createTrack(
            name: Track.screenShareAudioName,
            source: .screenShareAudio,
            options: AudioCaptureOptions(echoCancellation: false, autoGainControl: false, noiseSuppression: false, highpassFilter: false),
            reportStatistics: true
        )
        do {
            try await room.localParticipant.publish(audioTrack: made, options: AudioPublishOptions(dtx: false, red: false))
        } catch {
            stop("the sound was not published: \(error)")
        }
        soundTrack = made
        say("the sound was published as a track the library calls \(made.source); the microphone now: \(microphoneState())")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false) else {
            stop("no sound format")
        }
        if audioKind == "tone" {
            let queue = DispatchQueue(label: "space.b.stream-probe.tone", qos: .userInteractive)
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .microseconds(200))
            var phase = 0.0
            source.setEventHandler {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480) else { return }
                buffer.frameLength = 480
                for frame in 0 ..< 480 {
                    let value = Float(sin(phase) * 0.25)
                    phase += 2 * .pi * 440 / 48000
                    buffer.floatChannelData?[0][frame] = value
                    buffer.floatChannelData?[1][frame] = value
                }
                AudioManager.shared.mixer.capture(appAudio: buffer)
            }
            source.resume()
            toneTimer = source
        } else {
            let wire = SystemAudio.format
            let failure = await withCheckedContinuation { continuation in
                systemSound.start(format: wire, samples: { data, _ in
                    let channels = Int(wire.channels)
                    let frames = data.count / (4 * channels)
                    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    data.withUnsafeBytes { raw in
                        let samples = raw.bindMemory(to: Float32.self)
                        for frame in 0 ..< frames {
                            buffer.floatChannelData?[0][frame] = samples[frame * channels]
                            buffer.floatChannelData?[1][frame] = samples[frame * channels + (channels > 1 ? 1 : 0)]
                        }
                    }
                    AudioManager.shared.mixer.capture(appAudio: buffer)
                }, completion: { continuation.resume(returning: $0) })
            }
            if let failure { stop("the system's sound was refused: \(failure.rawValue)") }
        }
    }

    // The viewer, when there is a token for one.
    var viewer: Room?
    let watching = Watching()
    if let viewerToken {
        let second = Room()
        do {
            try await second.connect(
                url: url, token: viewerToken,
                connectOptions: ConnectOptions(autoSubscribe: true),
                roomOptions: RoomOptions(reportRemoteTrackStatistics: true)
            )
        } catch {
            stop("the viewer could not join the room: \(error)")
        }
        viewer = second
        say("the viewer joined as \(second.localParticipant.identity?.stringValue ?? "?")")
    }

    // Once a second.
    var last = (sent: UInt64(0), encoded: UInt(0), encodeTime: 0.0, processor: processorSeconds(), at: Date(), soundSent: UInt64(0))
    for second in 1 ... seconds {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let now = Date()
        let interval = now.timeIntervalSince(last.at)
        let processor = processorSeconds()
        var line = String(format: "%2d s  cpu %3.0f %%", second, (processor - last.processor) / interval * 100)
        last.processor = processor
        last.at = now

        if let statistics = track.statistics, let outbound = statistics.outboundRtpStream.first {
            let sent = outbound.bytesSent ?? 0
            let encoded = outbound.framesEncoded ?? 0
            let encodeTime = outbound.totalEncodeTime ?? 0
            let perFrame = encoded > last.encoded ? (encodeTime - last.encodeTime) / Double(encoded - last.encoded) * 1000 : 0
            let mime = statistics.codec.first(where: { $0.id == outbound.codecId })?.mimeType ?? "?"
            line += String(
                format: "  sends %@ %dx%d %2.0f fps %5d kbit/s  encoder %@%@ %.1f ms/frame  limited by %@",
                mime, outbound.frameWidth ?? 0, outbound.frameHeight ?? 0, outbound.framesPerSecond ?? 0,
                kilobits(sent, last.sent, over: interval),
                outbound.encoderImplementation ?? "?",
                outbound.powerEfficientEncoder == true ? " (power efficient)" : "",
                perFrame, outbound.qualityLimitationReason?.rawValue ?? "?"
            )
            let room = (statistics.iceCandidatePair.first(where: { $0.nominated == true }) ?? statistics.iceCandidatePair.first)?.availableOutgoingBitrate
            line += room.map { String(format: " (target %.0f, room %.0f)", (outbound.targetBitrate ?? 0) / 1000, $0 / 1000) } ?? ""
            last.sent = sent
            last.encoded = encoded
            last.encodeTime = encodeTime
            if second == 3 || second == seconds {
                let pair = statistics.iceCandidatePair.first(where: { $0.nominated == true }) ?? statistics.iceCandidatePair.first
                say("       path: local \(statistics.localIceCandidate?.candidateType.map { "\($0)" } ?? "?") \(statistics.localIceCandidate?.protocol ?? "?") on \(interfaceName(of: statistics.localIceCandidate?.address)), remote \(statistics.remoteIceCandidate?.candidateType.map { "\($0)" } ?? "?"), round trip \(pair?.currentRoundTripTime.map { String(format: "%.0f ms", $0 * 1000) } ?? "?"), room for \(pair?.availableOutgoingBitrate.map { String(format: "%.0f kbit/s", $0 / 1000) } ?? "?")")
            }
        } else {
            line += "  no statistics of the video yet"
        }

        if let soundTrack, let statistics = soundTrack.statistics, let outbound = statistics.outboundRtpStream.first {
            let sent = outbound.bytesSent ?? 0
            line += "  sound \(kilobits(sent, last.soundSent, over: interval)) kbit/s"
            last.soundSent = sent
        }

        if let viewer { line += watching.line(for: viewer, over: interval) }
        say(line)

        if let rebitrateKbps, second == seconds / 2 {
            do {
                try await publication.set(videoEncoding: VideoEncoding(maxBitrate: rebitrateKbps * 1000, maxFps: framesPerSecond, minBitrate: min(floorKbps, rebitrateKbps) * 1000))
                say("       -- from here up to \(rebitrateKbps) kbit/s, on the same track \(publication.sid)")
            } catch {
                say("       -- the bitrate was not changed: \(error)")
            }
        }
        if changes, second == seconds / 3 {
            feedState.set(divider: 2, useSmaller: false)
            say("       -- from here every second frame only")
        }
        if changes, second == seconds * 2 / 3 {
            if sourceKind == "display" {
                capturer.resize(width: width / 2 & ~1, height: height / 2 & ~1)
            } else {
                feedState.set(divider: 2, useSmaller: true)
            }
            say("       -- from here frames of half the size")
        }
    }

    say("the microphone at the end: \(microphoneState())")
    timer?.cancel()
    toneTimer?.cancel()
    capturer.stop()
    systemSound.stop()
    await viewer?.disconnect()
    await room.disconnect()
    exit(0)
}

final class FeedState: @unchecked Sendable {
    private let lock = NSLock()
    private var divider = 1
    private var useSmaller = false

    func read() -> (divider: Int, useSmaller: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (divider, useSmaller)
    }

    func set(divider: Int, useSmaller: Bool) {
        lock.lock()
        self.divider = divider
        self.useSmaller = useSmaller
        lock.unlock()
    }
}

_ = run
RunLoop.main.run()
