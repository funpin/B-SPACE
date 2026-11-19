import Foundation

/// The parts of a page the window is dragged by, as the page reports them with
/// `setDragRegions({ drag, noDrag })`.
///
/// A `WKWebView` does not know `-webkit-app-region`, the CSS property the
/// Electron build marks these parts with, and drops it when it reads the style
/// sheet. So the web client measures the elements it marked and reports their
/// rectangles, in the viewport's coordinates: points from the top left corner
/// of the page, as `getBoundingClientRect()` gives them.
public struct DragRegions: Equatable {
    /// More rectangles of one kind than this is not a title bar; the report
    /// is refused.
    public static let limit = 64

    /// Where pressing the mouse button drags the window.
    public var drag: [PlainRect]
    /// The exceptions inside those: controls that sit in a dragged part and
    /// are clicked, not dragged by.
    public var noDrag: [PlainRect]

    public init(drag: [PlainRect], noDrag: [PlainRect] = []) {
        self.drag = drag
        self.noDrag = noDrag
    }

    /// Reads the call's one argument. `drag` has to be there, as a list; a
    /// page with nothing to drag by sends an empty one. `noDrag` may be left
    /// out. Anything else, a rectangle that is not four finite numbers with a
    /// size that is not negative, or more rectangles than `limit`, and the
    /// whole report is refused: half a title bar is worse than the one before.
    public init?(arguments: BridgeArguments) {
        guard
            let report = arguments.object(at: 0),
            let drag = Self.rectangles(report["drag"])
        else { return nil }
        let exceptions: [PlainRect]
        switch report["noDrag"] {
        case nil, is NSNull:
            exceptions = []
        case let listed:
            guard let read = Self.rectangles(listed) else { return nil }
            exceptions = read
        }
        self.init(drag: drag, noDrag: exceptions)
    }

    /// Whether pressing the mouse button at this point drags the window:
    /// inside a dragged part and outside every exception.
    public func contains(x: Double, y: Double) -> Bool {
        func holds(_ rect: PlainRect) -> Bool {
            x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
        }
        return drag.contains(where: holds) && !noDrag.contains(where: holds)
    }

    private static func rectangles(_ value: Any?) -> [PlainRect]? {
        guard let list = value as? [Any], list.count <= limit else { return nil }
        var rectangles: [PlainRect] = []
        for entry in list {
            guard
                let fields = entry as? [String: Any],
                let x = number(fields["x"]),
                let y = number(fields["y"]),
                let width = number(fields["width"]),
                let height = number(fields["height"]),
                width >= 0, height >= 0
            else { return nil }
            // An element that is not laid out measures as nothing.
            if width > 0, height > 0 {
                rectangles.append(PlainRect(x: x, y: y, width: width, height: height))
            }
        }
        return rectangles
    }

    /// A finite JavaScript number. A boolean is not one.
    private static func number(_ value: Any?) -> Double? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }
}

/// Where the window can be dragged by on the page it shows now.
public struct WindowDragMap {
    /// The strip along the top edge that drags the window on a page that has
    /// reported nothing: the height of the title bar of the shell's own pages
    /// (the instance picker, recovery) and, short of its one-pixel separator,
    /// of the web client's. A server whose web client is older than
    /// `setDragRegions` is dragged by it.
    public static let fallbackStripHeight = 32.0

    /// What the page reported, once it has.
    public private(set) var reported: DragRegions?

    public init() {}

    /// The window shows another page: what the last one reported is gone.
    public mutating func pageChanged() {
        reported = nil
    }

    public mutating func report(_ regions: DragRegions) {
        reported = regions
    }

    /// - Parameters x, y: points from the top left corner of the page.
    public func canDrag(x: Double, y: Double) -> Bool {
        if let reported {
            return reported.contains(x: x, y: y)
        }
        return x >= 0 && y >= 0 && y < Self.fallbackStripHeight
    }

    /// The parts of a view of this size that must stay a page: everything
    /// the window is not dragged by, as rectangles in the page's coordinates.
    ///
    /// The system starts a window drag itself, from the rectangles of the
    /// views that say they move the window, so the shell cannot decide press
    /// by press. Its web view says it moves the window, and views that say
    /// they do not are laid over these rectangles. A point of the view is
    /// covered by one of them exactly when `canDrag` is false there. They may
    /// overlap: an exception is added whole on top of what is left around the
    /// dragged parts.
    public func stayRects(width: Double, height: Double) -> [PlainRect] {
        guard width > 0, height > 0 else { return [] }
        let bounds = PlainRect(x: 0, y: 0, width: width, height: height)
        let regions = reported
            ?? DragRegions(drag: [PlainRect(x: 0, y: 0, width: width, height: Self.fallbackStripHeight)])

        var stay = [bounds]
        for dragged in regions.drag {
            stay = stay.flatMap { Self.subtract(dragged, from: $0) }
        }
        return stay + regions.noDrag.compactMap { Self.intersection($0, bounds) }
    }

    private static func intersection(_ a: PlainRect, _ b: PlainRect) -> PlainRect? {
        let left = max(a.x, b.x)
        let top = max(a.y, b.y)
        let right = min(a.x + a.width, b.x + b.width)
        let bottom = min(a.y + a.height, b.y + b.height)
        guard left < right, top < bottom else { return nil }
        return PlainRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// What is left of a rectangle with another cut out of it: the full-width
    /// bands above and below the cut, then the pieces to its left and right.
    private static func subtract(_ cut: PlainRect, from rect: PlainRect) -> [PlainRect] {
        guard let hole = intersection(cut, rect) else { return [rect] }
        var pieces: [PlainRect] = []
        let rectRight = rect.x + rect.width
        let rectBottom = rect.y + rect.height
        let holeRight = hole.x + hole.width
        let holeBottom = hole.y + hole.height
        if hole.y > rect.y {
            pieces.append(PlainRect(x: rect.x, y: rect.y, width: rect.width, height: hole.y - rect.y))
        }
        if holeBottom < rectBottom {
            pieces.append(PlainRect(x: rect.x, y: holeBottom, width: rect.width, height: rectBottom - holeBottom))
        }
        if hole.x > rect.x {
            pieces.append(PlainRect(x: rect.x, y: hole.y, width: hole.x - rect.x, height: hole.height))
        }
        if holeRight < rectRight {
            pieces.append(PlainRect(x: holeRight, y: hole.y, width: rectRight - holeRight, height: hole.height))
        }
        return pieces
    }
}

/// What a double click on the title bar does, by the system's setting
/// (System Settings → Desktop & Dock → "Double-click a window's title bar to").
/// The title bar here is drawn by the page, so the shell does it by hand.
public enum TitleBarDoubleClick: Equatable {
    case zoom
    case minimize
    case nothing

    /// - Parameters:
    ///   - setting: `AppleActionOnDoubleClick` of the global domain, when set.
    ///   - minimizesOnDoubleClick: `AppleMiniaturizeOnDoubleClick`, the older
    ///     setting, read when the newer one is not there.
    public static func action(setting: String?, minimizesOnDoubleClick: Bool) -> TitleBarDoubleClick {
        switch setting {
        case "Minimize":
            return .minimize
        case "None":
            return .nothing
        case nil:
            return minimizesOnDoubleClick ? .minimize : .zoom
        default:
            // "Maximize" is zoom. "Fill" has no public call, and neither will
            // whatever a later system adds: zoom is the nearest thing.
            return .zoom
        }
    }
}
