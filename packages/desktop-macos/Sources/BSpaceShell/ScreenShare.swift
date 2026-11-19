import AppKit
import BSpaceCore
import CoreVideo

// The shell's own screen share (plan section 12): it joins the call as the
// user's stream participant and publishes what it captures, with one
// hardware encode. `ShareSession` is the share; `ScreenSharePublisher` is its
// connection to the call, behind a protocol so that the session is checked
// with a made-up publisher and no network.

/// How a share's video is published.
public struct SharePublication: Equatable {
    public var codec: ScreenShareCodec
    public var maxBitrate: Int
    public var minBitrate: Int
    public var framesPerSecond: Int

    public init(codec: ScreenShareCodec, maxBitrate: Int, minBitrate: Int, framesPerSecond: Int) {
        self.codec = codec
        self.maxBitrate = maxBitrate
        self.minBitrate = minBitrate
        self.framesPerSecond = framesPerSecond
    }
}

/// What a publisher says about its connection while a share runs.
public enum SharePublisherEvent: Equatable {
    /// The connection is being restored; frames may go on being sent.
    case reconnecting
    case reconnected
    /// The connection is gone and will not come back by itself.
    case disconnected
    case stats(ScreenShareStats)
}

/// A share's connection to a call: joins it with a stream token and
/// publishes the picture and the sound it is handed.
public protocol ScreenSharePublisher: AnyObject {
    /// Called on the main queue.
    var onEvent: ((SharePublisherEvent) -> Void)? { get set }

    /// Joins the call. Answers on the main queue with whether it is in.
    func connect(url: String, token: String, completion: @escaping (Bool) -> Void)

    /// Publishes the video. Frames are already being sent when this is
    /// called: the track takes its size from them. Answers on the main queue.
    func publishVideo(width: Int, height: Int, settings: SharePublication, completion: @escaping (Bool) -> Void)

    /// One frame of the picture, of whatever size the source has now. Called
    /// on a queue of the capturer's own.
    func send(frame: CVPixelBuffer)

    /// Gives the published video another bitrate ceiling and floor and
    /// another frame rate ceiling, without publishing it again. Answers on
    /// the main queue.
    func setEncoding(maxBitrate: Int, minBitrate: Int, framesPerSecond: Int, completion: @escaping (Bool) -> Void)

    /// Publishes the sound that `send(audio:)` will hand over, in `format`.
    /// Answers on the main queue.
    func publishAudio(format: MediaWire.AudioFormat, completion: @escaping (Bool) -> Void)

    /// Samples as `SystemAudio.interleaved` lays them out. Called on a queue
    /// of the capturer's own.
    func send(audio samples: Data)

    func unpublishAudio()

    /// Leaves the call. Nothing is said through `onEvent` about a leaving
    /// that was asked for.
    func disconnect()
}

/// One share: a capture of a display or a window and, when asked, of the
/// system's sound, published into a call through a publisher. Everything
/// but the frames and the samples happens on the main queue.
final class ShareSession {
    /// Called on the main queue.
    var onEvent: ((ScreenShareEvent) -> Void)?

    private(set) var request: ScreenShareRequest
    private let publisher: ScreenSharePublisher
    private let makeCapturer: () -> ScreenCapturer
    private let makeSoundCapturer: (() -> SystemAudioCapturer)?
    /// The windows a capture of a source leaves out: the shell's own that
    /// draws viewers' pointers over a shared display.
    private let excludedWindows: (ScreenSource.Kind) -> [UInt32]

    private enum Phase { case idle, starting, running, changing, over }
    private var phase = Phase.idle
    private var capturer: ScreenCapturer?
    private var sound: SystemAudioCapturer?
    private var size: (width: Int, height: Int) = (0, 0)
    /// The change of size that waits for the window to settle.
    private var resizing: DispatchWorkItem?

    /// Which capturer's frames go to the call: while one capture replaces
    /// another both run for a moment, and only one may be seen.
    private let feedLock = NSLock()
    private var feeding = 0
    private var feedsMade = 0
    /// Whether samples go to the call: the sound's track is published.
    private var soundFlows = false

    /// How long a window has to keep a new size before the video takes it.
    static let patienceForASize: TimeInterval = 0.3

    init(
        request: ScreenShareRequest,
        publisher: ScreenSharePublisher,
        makeCapturer: @escaping () -> ScreenCapturer,
        makeSoundCapturer: (() -> SystemAudioCapturer)?,
        excludedWindows: @escaping (ScreenSource.Kind) -> [UInt32]
    ) {
        self.request = request
        self.publisher = publisher
        self.makeCapturer = makeCapturer
        self.makeSoundCapturer = makeSoundCapturer
        self.excludedWindows = excludedWindows
    }

    var isOver: Bool { phase == .over }

    /// The display the share shows whole, for the pointers drawn over it.
    var display: UInt32? {
        if case .display(let id) = request.capture.source { return id }
        return nil
    }

    // MARK: Starting

    /// The capture first, so that a missing permission or a source that is
    /// gone is said before the call hears of anything; then the call, the
    /// frames, the track, and the sound when it was asked for.
    func start(_ completion: @escaping (ScreenShareReply) -> Void) {
        guard phase == .idle else {
            completion(.refused(.busy))
            return
        }
        phase = .starting
        publisher.onEvent = { [weak self] event in self?.heard(event) }
        capture(request.capture) { [weak self] result in
            guard let self, self.phase == .starting else {
                if case .success(let made) = result { made.capturer.stop() }
                completion(.refused(.failed))
                return
            }
            let feed: Feed
            switch result {
            case .success(let made):
                feed = made
            case .failure(let failure):
                self.finish()
                completion(.refused(ScreenShareFailure(failure)))
                return
            }
            self.publisher.connect(url: self.request.url, token: self.request.token) { [weak self] connected in
                guard let self, self.phase == .starting else {
                    feed.capturer.stop()
                    completion(.refused(.failed))
                    return
                }
                guard connected else {
                    feed.capturer.stop()
                    self.finish()
                    completion(.refused(.connectFailed))
                    return
                }
                self.begin(feed) { [weak self] began in
                    guard let self, self.phase == .starting else {
                        completion(.refused(.failed))
                        return
                    }
                    guard began else {
                        self.finish()
                        completion(.refused(.failed))
                        return
                    }
                    self.publisher.publishVideo(width: feed.width, height: feed.height, settings: self.publication) { [weak self] published in
                        guard let self, self.phase == .starting else {
                            completion(.refused(.failed))
                            return
                        }
                        guard published else {
                            self.finish()
                            completion(.refused(.publishFailed))
                            return
                        }
                        self.phase = .running
                        completion(.running(width: self.size.width, height: self.size.height, framesPerSecond: self.request.capture.framesPerSecond))
                        // The sound is the share's, and the share is not its:
                        // a sound that would not start is said as one that ended.
                        if self.request.audio { self.startSound { _ in } }
                    }
                }
            }
        }
    }

    private var publication: SharePublication {
        SharePublication(
            codec: request.codec, maxBitrate: request.maxBitrate, minBitrate: request.minBitrate,
            framesPerSecond: request.capture.framesPerSecond
        )
    }

    // MARK: The capture

    private struct Feed {
        let capturer: ScreenCapturer
        let number: Int
        let width: Int
        let height: Int
    }

    /// Makes a capturer for `asked` and has it find its source. Its frames
    /// do not go anywhere yet.
    private func capture(_ asked: ScreenCaptureRequest, completion: @escaping (Result<Feed, ScreenCaptureFailure>) -> Void) {
        var asked = asked
        asked.excludedWindows = excludedWindows(asked.source)
        let capturer = makeCapturer()
        feedsMade += 1
        let number = feedsMade
        capturer.prepare(asked) { result in
            completion(result.map { Feed(capturer: capturer, number: number, width: $0.width, height: $0.height) })
        }
    }

    /// Starts a prepared capturer's frames and makes it the one whose
    /// frames the call sees; the capturer before it, if any, is stopped.
    private func begin(_ feed: Feed, completion: @escaping (Bool) -> Void) {
        let publisher = self.publisher
        feed.capturer.begin(frame: { [weak self] frame, _, _ in
            guard let self else { return }
            self.feedLock.lock()
            let isCurrent = self.feeding == feed.number
            self.feedLock.unlock()
            if isCurrent { publisher.send(frame: frame) }
        }, completion: { [weak self] began in
            guard let self, began, self.phase != .over else {
                feed.capturer.stop()
                completion(false)
                return
            }
            let before = self.capturer
            self.feedLock.lock()
            self.feeding = feed.number
            self.feedLock.unlock()
            before?.onEnded = nil
            before?.onSourceResized = nil
            before?.stop()
            self.capturer = feed.capturer
            self.size = (feed.width, feed.height)
            self.resizing?.cancel()
            feed.capturer.onEnded = { [weak self] in self?.end(.sourceEnded) }
            feed.capturer.onSourceResized = { [weak self] width, height in self?.sourceBecame(width: width, height: height) }
            completion(true)
        })
    }

    /// The shared window has another size. A window that is being dragged
    /// by its corner reports a size many times a second; the video takes
    /// the one it settles on, fitted into what the page allowed.
    private func sourceBecame(width: Int, height: Int) {
        resizing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .running || self.phase == .changing else { return }
            let fitted = VideoShape.encodedSize(
                width: width, height: height,
                maxWidth: self.request.capture.maxWidth, maxHeight: self.request.capture.maxHeight
            )
            guard fitted.width != self.size.width || fitted.height != self.size.height else { return }
            self.size = (fitted.width, fitted.height)
            self.capturer?.resize(width: fitted.width, height: fitted.height)
            self.onEvent?(.resized(width: fitted.width, height: fitted.height))
        }
        resizing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patienceForASize, execute: work)
    }

    // MARK: Changing

    /// Changes what the page named and nothing else, one thing after
    /// another: the capture, the encoding, the sound. A capture that cannot
    /// be replaced leaves the share as it was.
    func update(_ update: ScreenShareUpdate, completion: @escaping (ScreenShareReply) -> Void) {
        guard phase == .running else {
            completion(.refused(phase == .starting || phase == .changing ? .busy : .notRunning))
            return
        }
        let (next, changes) = update.applied(to: request)
        let answer: (ScreenShareFailure?) -> Void = { [weak self] failure in
            guard let self else { return }
            if self.phase == .changing { self.phase = .running }
            if let failure {
                completion(.refused(failure))
            } else if self.phase == .over {
                completion(.refused(.notRunning))
            } else {
                completion(.running(width: self.size.width, height: self.size.height, framesPerSecond: self.request.capture.framesPerSecond))
            }
        }
        guard !changes.isEmpty else {
            answer(nil)
            return
        }
        phase = .changing
        let encodeThenSound = { [weak self] in
            guard let self, self.phase == .changing else {
                answer(.notRunning)
                return
            }
            self.changeEncoding(to: next, when: changes.contains(.encoding)) { [weak self] failure in
                guard let self, self.phase == .changing, failure == nil else {
                    answer(failure ?? .notRunning)
                    return
                }
                guard changes.contains(.audio) else {
                    answer(nil)
                    return
                }
                self.request.audio = next.audio
                if next.audio {
                    self.startSound { started in answer(started ? nil : .failed) }
                } else {
                    self.stopSound()
                    answer(nil)
                }
            }
        }
        guard changes.contains(.capture) else {
            encodeThenSound()
            return
        }
        capture(next.capture) { [weak self] result in
            guard let self, self.phase == .changing else {
                if case .success(let feed) = result { feed.capturer.stop() }
                answer(.notRunning)
                return
            }
            switch result {
            case .failure(let failure):
                answer(ScreenShareFailure(failure))
            case .success(let feed):
                self.begin(feed) { [weak self] began in
                    guard let self, self.phase == .changing else {
                        answer(.notRunning)
                        return
                    }
                    guard began else {
                        answer(.failed)
                        return
                    }
                    self.request.capture = next.capture
                    encodeThenSound()
                }
            }
        }
    }

    private func changeEncoding(to next: ScreenShareRequest, when needed: Bool, completion: @escaping (ScreenShareFailure?) -> Void) {
        guard needed else {
            completion(nil)
            return
        }
        publisher.setEncoding(
            maxBitrate: next.maxBitrate, minBitrate: next.minBitrate, framesPerSecond: next.capture.framesPerSecond
        ) { [weak self] changed in
            guard changed else {
                completion(.failed)
                return
            }
            self?.request.maxBitrate = next.maxBitrate
            self?.request.minBitrate = next.minBitrate
            completion(nil)
        }
    }

    // MARK: The sound

    private func startSound(_ completion: @escaping (Bool) -> Void) {
        guard sound == nil else {
            completion(true)
            return
        }
        guard let makeSoundCapturer else {
            soundEnded()
            completion(false)
            return
        }
        let format = SystemAudio.format
        publisher.publishAudio(format: format) { [weak self] published in
            guard let self, self.phase == .running || self.phase == .changing, self.request.audio else {
                completion(false)
                return
            }
            guard published else {
                self.soundEnded()
                completion(false)
                return
            }
            let capturer = makeSoundCapturer()
            let publisher = self.publisher
            self.sound = capturer
            self.feedLock.lock()
            self.soundFlows = true
            self.feedLock.unlock()
            capturer.onEnded = { [weak self] in self?.soundEnded() }
            capturer.start(format: format, samples: { [weak self] samples, _ in
                guard let self else { return }
                self.feedLock.lock()
                let flows = self.soundFlows
                self.feedLock.unlock()
                if flows { publisher.send(audio: samples) }
            }, completion: { [weak self] failure in
                guard let self else { return }
                if failure != nil, self.sound === capturer {
                    self.soundEnded()
                    completion(false)
                } else {
                    completion(failure == nil)
                }
            })
        }
    }

    private func stopSound() {
        feedLock.lock()
        soundFlows = false
        feedLock.unlock()
        guard let capturer = sound else { return }
        sound = nil
        capturer.onEnded = nil
        capturer.stop()
        publisher.unpublishAudio()
    }

    /// The sound stopped by itself, or would not start: the picture goes on
    /// and the page is told, so that its switch shows what is true.
    private func soundEnded() {
        stopSound()
        guard phase == .running || phase == .changing else { return }
        request.audio = false
        onEvent?(.audioEnded)
    }

    // MARK: Ending

    private func heard(_ event: SharePublisherEvent) {
        guard phase != .over, phase != .idle else { return }
        switch event {
        case .reconnecting:
            onEvent?(.reconnecting)
        case .reconnected:
            onEvent?(.reconnected)
        case .disconnected:
            // While it starts, the start's own answer says what went wrong.
            if phase == .starting { return }
            end(.disconnected)
        case .stats(let stats):
            if phase == .running || phase == .changing { onEvent?(.stats(stats)) }
        }
    }

    /// The share is over by itself: the page is told once.
    private func end(_ reason: ScreenShareEndReason) {
        guard phase == .running || phase == .changing else { return }
        finish()
        onEvent?(.ended(reason))
    }

    /// The page stopped the share, or the window shows another page.
    func stop() {
        finish()
    }

    private func finish() {
        guard phase != .over else { return }
        phase = .over
        resizing?.cancel()
        feedLock.lock()
        feeding = 0
        soundFlows = false
        feedLock.unlock()
        capturer?.onEnded = nil
        capturer?.onSourceResized = nil
        capturer?.stop()
        capturer = nil
        sound?.onEnded = nil
        sound?.stop()
        sound = nil
        publisher.onEvent = nil
        publisher.disconnect()
    }
}
