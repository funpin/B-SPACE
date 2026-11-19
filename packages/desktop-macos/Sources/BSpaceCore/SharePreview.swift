import Foundation

// The live preview of a source on the stream setup screen, before a share
// starts and while another source is being chosen for one that runs. The
// shell captures the source and draws it itself, in a layer over the page:
// the frames go from the capture to the screen without an encoder and without
// the page. The page says which source and where its preview box is.

/// Where the page's preview box is: a rectangle in the viewport's
/// coordinates (points from the top left corner of the page, as
/// `getBoundingClientRect()` gives them) and the radius of its corners.
public struct SharePreviewFrame: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var cornerRadius: Double

    /// Further than any window reaches; a box beyond it is a mistake.
    static let farthest = 100_000.0
    static let largest = 16_384.0

    public init(x: Double, y: Double, width: Double, height: Double, cornerRadius: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    /// `setNativeSharePreviewFrame({ x, y, width, height, radius? })`. Nil for
    /// anything that is not a box with a size: `null`, numbers that are not
    /// finite, a box with no width. The page hides the preview by sending
    /// one of those, so nil means "show nothing", never "keep the last".
    public init?(arguments: BridgeArguments) {
        guard let box = arguments.object(at: 0),
              let x = Self.number(box["x"]), let y = Self.number(box["y"]),
              let width = Self.number(box["width"]), let height = Self.number(box["height"]),
              abs(x) <= Self.farthest, abs(y) <= Self.farthest,
              width >= 1, height >= 1, width <= Self.largest, height <= Self.largest else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        let radius = Self.number(box["radius"]) ?? 0
        cornerRadius = min(max(radius, 0), min(width, height) / 2)
    }

    private static func number(_ value: Any?) -> Double? {
        // A JavaScript number; a boolean is not one.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

public enum SharePreview {
    /// The most a preview's picture measures: enough for the setup screen's
    /// box on a Retina display, and no more than it shows.
    public static let maxWidth = 1280
    public static let maxHeight = 800
    public static let framesPerSecond = 30

    /// `startNativeSharePreview({ sourceId })`: the capture a preview of that
    /// source needs. Nil when the page named no source the list could have
    /// given it.
    public static func capture(arguments: BridgeArguments) -> ScreenCaptureRequest? {
        guard let id = arguments.object(at: 0)?["sourceId"] as? String,
              let source = ScreenSource.kind(ofID: id) else { return nil }
        return ScreenCaptureRequest(source: source, maxWidth: maxWidth, maxHeight: maxHeight, framesPerSecond: framesPerSecond)
    }

    /// What the page is told when it asks for a preview. `hidden` when the
    /// system does not draw the source now, so there is no picture of it
    /// to show; `ScreenShareEvent.previewHidden` says when that changes.
    public static func started(width: Int, height: Int, hidden: Bool) -> [String: Any] {
        ["ok": true, "width": width, "height": height, "hidden": hidden]
    }

    public static func refused(_ failure: ScreenCaptureFailure) -> [String: Any] {
        ["ok": false, "reason": failure.rawValue]
    }
}
