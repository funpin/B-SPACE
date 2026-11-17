import Foundation

/// A rectangle with no opinion about which way its vertical axis points; the
/// functions that take one say which coordinate system they mean.
public struct PlainRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Whether the two rectangles share any area. Touching edges do not count.
    public func intersects(_ other: PlainRect) -> Bool {
        intersectionArea(with: other) > 0
    }

    public func intersectionArea(with other: PlainRect) -> Double {
        let overlapWidth = min(x + width, other.x + other.width) - max(x, other.x)
        let overlapHeight = min(y + height, other.y + other.height) - max(y, other.y)
        return overlapWidth > 0 && overlapHeight > 0 ? overlapWidth * overlapHeight : 0
    }
}

/// What `window-state.json` holds, in the format and the coordinate system of
/// the Electron build (`packages/desktop/src/main.ts`, `WindowState`): points,
/// origin at the top left corner of the primary display, Y growing downwards.
/// Both shells read and write the same file, so a window keeps its place when
/// one replaces the other.
public struct WindowState: Equatable {
    public var width: Double
    public var height: Double
    /// Absent when the window has never been placed, or its place is no longer
    /// on any display: the window is then centred.
    public var x: Double?
    public var y: Double?
    public var isMaximized: Bool

    public static let `default` = WindowState(width: 1280, height: 800, x: nil, y: nil, isMaximized: false)

    public init(width: Double, height: Double, x: Double?, y: Double?, isMaximized: Bool) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.isMaximized = isMaximized
    }

    /// The saved bounds, when the state has a position.
    public var bounds: PlainRect? {
        guard let x, let y else { return nil }
        return PlainRect(x: x, y: y, width: width, height: height)
    }
}

/// One display, in the Electron coordinate system.
public struct DisplayGeometry: Equatable {
    /// The whole display.
    public var frame: PlainRect
    /// The display without the menu bar and the Dock.
    public var workArea: PlainRect

    public init(frame: PlainRect, workArea: PlainRect) {
        self.frame = frame
        self.workArea = workArea
    }
}

public enum WindowPlacement {
    /// Converts a rectangle between AppKit's coordinates (origin at the bottom
    /// left corner of the primary display, Y growing upwards) and Electron's
    /// (origin at its top left corner, Y growing downwards). The same formula
    /// works in both directions, and for a display's frame as well as for a
    /// window's.
    public static func flipped(_ rect: PlainRect, primaryDisplayHeight: Double) -> PlainRect {
        PlainRect(
            x: rect.x,
            y: primaryDisplayHeight - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// The saved state as it can be applied now: the size is never below the
    /// window's minimum, and the position is dropped when the window would not
    /// be at least partly inside the work area of the display it mostly lies
    /// on, as when the monitor it was on is gone. A port of
    /// `validateWindowBounds`.
    public static func restorable(
        _ state: WindowState,
        displays: [DisplayGeometry],
        minimumWidth: Double,
        minimumHeight: Double
    ) -> WindowState {
        var result = state
        result.width = max(state.width, minimumWidth)
        result.height = max(state.height, minimumHeight)
        guard let bounds = result.bounds else {
            result.x = nil
            result.y = nil
            return result
        }

        let matching = displays
            .map { (display: $0, area: bounds.intersectionArea(with: $0.frame)) }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }?
            .display
        if let matching, bounds.intersects(matching.workArea) {
            return result
        }
        result.x = nil
        result.y = nil
        return result
    }
}

/// Reads and writes `window-state.json` in the user-data folder.
public struct WindowStateStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("window-state.json", isDirectory: false)
    }

    /// The saved state. A field that is missing or of the wrong type takes its
    /// default, as in the Electron build; a file that is not JSON gives the
    /// default state.
    public func load() -> WindowState {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .default }

        return WindowState(
            width: Self.number(object["width"]) ?? WindowState.default.width,
            height: Self.number(object["height"]) ?? WindowState.default.height,
            x: Self.number(object["x"]),
            y: Self.number(object["y"]),
            isMaximized: Self.boolean(object["isMaximized"]) ?? false
        )
    }

    /// Written atomically (deviation 1 in the plan). Whole numbers are written
    /// without a fraction, as Electron writes its integer bounds.
    public func save(_ state: WindowState) throws {
        var object: [String: Any] = [
            "width": Self.json(state.width),
            "height": Self.json(state.height),
            "isMaximized": state.isMaximized,
        ]
        if let x = state.x, let y = state.y {
            object["x"] = Self.json(x)
            object["y"] = Self.json(y)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: fileURL, options: .atomic)
    }

    /// A JSON number. `true` and `false` are numbers to Foundation and are not
    /// to JavaScript's `typeof`.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func json(_ value: Double) -> Any {
        let rounded = value.rounded()
        if rounded == value, abs(value) < 1e15 { return Int(rounded) }
        return value
    }
}
