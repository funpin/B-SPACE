import Foundation

/// What the page asks for when it starts a native capture.
///
/// `startNativeScreenCapture({ sourceId, maxWidth, maxHeight, frameRate })`:
/// the source by the id the list gave it, and the most the stream setup
/// screen's quality choice allows. The shell captures at the source's own
/// size when that is smaller.
public struct ScreenCaptureRequest: Equatable {
    public var source: ScreenSource.Kind
    public var maxWidth: Int
    public var maxHeight: Int
    public var framesPerSecond: Int

    /// The bounds of what can be asked for. Sixty frames a second is what
    /// the capture and the encoder were measured at.
    public static let sizeRange = 160...8192
    public static let frameRateRange = 1...60
    public static let defaultFrameRate = 30
    /// How many captures a page may have at once: the share that runs, the
    /// preview of the source it is about to switch to, and one being
    /// replaced by another of a different size.
    public static let mostAtOnce = 4

    public init(source: ScreenSource.Kind, maxWidth: Int, maxHeight: Int, framesPerSecond: Int) {
        self.source = source
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.framesPerSecond = framesPerSecond
    }

    /// Nil when the page named no source the list could have given it. A
    /// size or a rate that is missing or out of bounds is brought into them:
    /// the page asked for a share, and gets one.
    public init?(arguments: BridgeArguments) {
        guard let options = arguments.object(at: 0),
              let id = options["sourceId"] as? String,
              let source = ScreenSource.kind(ofID: id) else { return nil }
        self.source = source
        maxWidth = Self.whole(options["maxWidth"], in: Self.sizeRange, otherwise: Self.sizeRange.upperBound)
        maxHeight = Self.whole(options["maxHeight"], in: Self.sizeRange, otherwise: Self.sizeRange.upperBound)
        framesPerSecond = Self.whole(options["frameRate"], in: Self.frameRateRange, otherwise: Self.defaultFrameRate)
    }

    private static func whole(_ value: Any?, in range: ClosedRange<Int>, otherwise fallback: Int) -> Int {
        // A JavaScript number; a boolean is not one.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return fallback }
        let double = number.doubleValue
        guard double.isFinite else { return fallback }
        return min(max(Int(double.rounded()), range.lowerBound), range.upperBound)
    }
}

/// Why a native capture did not start, as the page is told.
public enum ScreenCaptureFailure: String, Error, Equatable {
    /// The request named no source.
    case badRequest = "bad-request"
    /// The app may not record the screen. The system has been asked.
    case noPermission = "no-permission"
    /// The display or window is gone.
    case noSource = "no-source"
    /// This system cannot do it (the local channel needs macOS 15).
    case unsupported
    /// The page already has as many captures as it may.
    case tooMany = "too-many"
    /// The capture, the encoder or the channel would not start.
    case failed
}

/// What the page is told when it asks for a native capture.
public enum ScreenCaptureReply: Equatable {
    /// The capture runs: the id to stop it by, where to connect, what to
    /// say first, and the size and rate of the video that will come.
    case started(id: String, url: String, token: String, width: Int, height: Int, framesPerSecond: Int)
    case refused(ScreenCaptureFailure)

    public var bridgeValue: [String: Any] {
        switch self {
        case .started(let id, let url, let token, let width, let height, let framesPerSecond):
            return [
                "ok": true, "id": id, "url": url, "token": token,
                "width": width, "height": height, "frameRate": framesPerSecond,
            ]
        case .refused(let failure):
            return ["ok": false, "reason": failure.rawValue]
        }
    }
}

/// Whether the page is told that the app lists the sources itself.
///
/// It is, when the web client says it can take a native capture
/// (`getScreenSharePickerMode({ nativeCapture: true })`) and the shell can
/// give one. A web client from before native capture says nothing, and is
/// told `system`: it calls `getDisplayMedia`, WebKit shows its own picker, and
/// the share works at what WebKit's capture gives.
public enum ScreenSharePickerMode: String {
    case app
    case system

    public static func answer(arguments: BridgeArguments, shellCanCapture: Bool) -> ScreenSharePickerMode {
        guard shellCanCapture,
              let number = arguments.object(at: 0)?["nativeCapture"] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID(), number.boolValue else { return .system }
        return .app
    }
}
