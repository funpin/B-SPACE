import AppKit
import BSpaceCore
import CoreMedia
import ScreenCaptureKit

/// Where captured frames come from.
///
/// Starting is in two steps because the size of the video is the capturer's
/// to decide and the encoder has to exist before the first frame: `prepare`
/// answers with the size, `begin` starts the frames.
public protocol ScreenCapturer: AnyObject {
    /// Called on the main queue when the capture ended by itself: the window
    /// was closed, the display unplugged, the permission taken away.
    var onEnded: (() -> Void)? { get set }

    /// Finds the source and decides the size of the video. Answers on the
    /// main queue.
    func prepare(
        _ request: ScreenCaptureRequest,
        completion: @escaping (Result<(width: Int, height: Int), ScreenCaptureFailure>) -> Void
    )

    /// Starts the frames. `frame` is called on a queue of the capturer's
    /// own, one frame at a time, with the picture, its place in the stream
    /// and the moment it was captured (milliseconds since 1970). Answers on
    /// the main queue with whether the capture started.
    func begin(
        frame: @escaping (CVPixelBuffer, CMTime, Double) -> Void,
        completion: @escaping (Bool) -> Void
    )

    func stop()
}

/// The screen, through ScreenCaptureKit.
public final class SystemScreenCapturer: NSObject, ScreenCapturer, SCStreamOutput, SCStreamDelegate {
    public var onEnded: (() -> Void)?

    private let queue = DispatchQueue(label: "screen-capture", qos: .userInteractive)
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var frame: ((CVPixelBuffer, CMTime, Double) -> Void)?
    private var isStopped = false

    public func prepare(
        _ request: ScreenCaptureRequest,
        completion: @escaping (Result<(width: Int, height: Int), ScreenCaptureFailure>) -> Void
    ) {
        guard CGPreflightScreenCaptureAccess() else {
            // The system asks the user the first time and does nothing after.
            CGRequestScreenCaptureAccess()
            completion(.failure(.noPermission))
            return
        }
        Task { @MainActor in
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            } catch {
                NSLog("[capture] the system did not list what can be shared: %@", error.localizedDescription)
                completion(.failure(.failed))
                return
            }
            let filter: SCContentFilter
            switch request.source {
            case .display(let id):
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    completion(.failure(.noSource))
                    return
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
            case .window(let id):
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    completion(.failure(.noSource))
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
            }

            // The source in its own pixels, fitted into what was asked for.
            let info = SCShareableContent.info(for: filter)
            let scale = Double(info.pointPixelScale)
            let size = VideoShape.encodedSize(
                width: Int((Double(info.contentRect.width) * scale).rounded()),
                height: Int((Double(info.contentRect.height) * scale).rounded()),
                maxWidth: request.maxWidth, maxHeight: request.maxHeight
            )

            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.framesPerSecond))
            // What the hardware encoder takes without a conversion.
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.showsCursor = true
            configuration.queueDepth = 5
            self.filter = filter
            self.configuration = configuration
            completion(.success(size))
        }
    }

    public func begin(
        frame: @escaping (CVPixelBuffer, CMTime, Double) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        guard let filter, let configuration, !isStopped else {
            completion(false)
            return
        }
        self.frame = frame
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            NSLog("[capture] the stream would not take an output: %@", error.localizedDescription)
            completion(false)
            return
        }
        self.stream = stream
        stream.startCapture { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("[capture] the capture did not start: %@", error.localizedDescription)
                    self?.stream = nil
                }
                completion(error == nil)
            }
        }
    }

    public func stop() {
        isStopped = true
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        // The system also sends a sample when nothing changed on screen, and
        // while it is starting; only a whole new picture is a frame.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        guard let raw = attachments?.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }

        // The sample is stamped on the host's clock; the page's is the wall clock.
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let age = CACurrentMediaTime() - time.seconds
        frame?(pixelBuffer, time, (Date().timeIntervalSince1970 - age) * 1000)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[capture] the capture ended: %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.stream = nil
            self.onEnded?()
        }
    }
}

/// One share: a capturer's frames, encoded, on a local media channel.
///
/// It also keeps the page supplied with a picture when the screen stands
/// still. The system sends a frame only when something changed, so a page
/// that connects a moment after the capture started, or whose decoder asks
/// for a key frame, would wait for the next change with nothing to show. The
/// last frame is kept and encoded again as a key frame for it.
final class CaptureSession {
    /// Called on the main queue when the capture ended by itself.
    var onEnded: (() -> Void)?

    private let capturer: ScreenCapturer
    private let channel: LocalMediaChannel
    private let request: ScreenCaptureRequest
    private var encoder: VideoEncoder?
    /// What the frames and the re-encoding share.
    private let lock = NSLock()
    private var lastFrame: CVPixelBuffer?
    private var lastFormat: MediaWire.VideoFormat?
    private var framesEncoded = 0
    private var isStopped = false
    /// One frame is given to the encoder at a time, whichever thread it
    /// comes from.
    private let encoding = NSLock()

    /// How long a request for a key frame waits for the screen to change
    /// before the last frame is encoded again.
    static let patienceForAChange: TimeInterval = 0.05

    init(capturer: ScreenCapturer, channel: LocalMediaChannel, request: ScreenCaptureRequest) {
        self.capturer = capturer
        self.channel = channel
        self.request = request
    }

    /// Starts the capture. Answers on the main queue with the size of the
    /// video that will come.
    func start(_ completion: @escaping (Result<(width: Int, height: Int), ScreenCaptureFailure>) -> Void) {
        capturer.onEnded = { [weak self] in
            self?.onEnded?()
        }
        channel.onClientConnected = { [weak self] in
            self?.pageNeedsAKeyFrame(announcingTheFormat: true)
        }
        channel.onMessage = { [weak self] message in
            if MediaWire.Request(message: message) == .keyFrame {
                self?.pageNeedsAKeyFrame(announcingTheFormat: false)
            }
        }
        capturer.prepare(request) { [weak self] result in
            guard let self, !self.isStopped else {
                completion(.failure(.failed))
                return
            }
            switch result {
            case .failure(let failure):
                completion(.failure(failure))
            case .success(let size):
                do {
                    let encoder = try VideoEncoder(settings: .init(
                        width: size.width, height: size.height, framesPerSecond: self.request.framesPerSecond
                    ))
                    self.wire(encoder)
                    self.encoder = encoder
                } catch {
                    NSLog("[capture] no encoder for %dx%d: %@", size.width, size.height, String(describing: error))
                    completion(.failure(.failed))
                    return
                }
                self.capturer.begin(frame: { [weak self] pixelBuffer, time, capturedAt in
                    self?.encode(pixelBuffer, at: time, capturedAt: capturedAt)
                }, completion: { started in
                    completion(started ? .success(size) : .failure(.failed))
                })
            }
        }
    }

    func stop() {
        lock.lock()
        isStopped = true
        lastFrame = nil
        lock.unlock()
        capturer.onEnded = nil
        capturer.stop()
        channel.onClientConnected = nil
        channel.onMessage = nil
    }

    private func wire(_ encoder: VideoEncoder) {
        encoder.onFormat = { [weak self] format in
            guard let self else { return }
            self.lock.lock()
            self.lastFormat = format
            self.lock.unlock()
            self.channel.send(text: format.message)
        }
        encoder.onFrame = { [weak self, weak encoder] message in
            guard let self else { return }
            // A frame that could not be sent breaks the chain the next ones
            // hang on: the next one has to stand on its own.
            if !self.channel.send(message) {
                encoder?.requestKeyFrame()
            }
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime, capturedAt: Double) {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        lastFrame = pixelBuffer
        framesEncoded += 1
        lock.unlock()
        encoding.lock()
        encoder?.encode(pixelBuffer, presentationTime: time, capturedAt: capturedAt)
        encoding.unlock()
    }

    /// The page connected, or its decoder lost its place.
    private func pageNeedsAKeyFrame(announcingTheFormat: Bool) {
        lock.lock()
        let format = lastFormat
        let before = framesEncoded
        lock.unlock()
        if announcingTheFormat, let format {
            channel.send(text: format.message)
        }
        encoder?.requestKeyFrame()
        // If the screen does not change in the meantime, the frame the page
        // gets is the last one, again.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Self.patienceForAChange) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let frame = self.framesEncoded == before && !self.isStopped ? self.lastFrame : nil
            if frame != nil {
                self.framesEncoded += 1
            }
            self.lock.unlock()
            guard let frame else { return }
            self.encoding.lock()
            self.encoder?.encode(
                frame, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()),
                capturedAt: Date().timeIntervalSince1970 * 1000
            )
            self.encoding.unlock()
        }
    }
}
