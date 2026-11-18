import Foundation

/// Viewers' pointers on the sharer's own screen.
///
/// Viewers of a screen share can point at it. Inside the app their pointers
/// are drawn on the stream tile; the sharer, though, is looking at the real
/// desktop, not at the tile. The shell draws the pointers there, in a
/// transparent window over the display being shared (`SystemPointerOverlay`).
///
/// The page owns the state (who is pointing, fading, colours, names) and
/// sends the whole list on every change (`setStreamPointerOverlay`); what is
/// here checks that list and decides which display it belongs on. It is the
/// Electron build's `pointerOverlay.ts`, rule for rule.

/// One pointer as the page sends it.
public struct OverlayPointer: Equatable {
    public let id: String
    public let name: String
    public let color: OverlayColor
    /// Where it points, as fractions of the shared picture: 0 to 1 from the
    /// left and from the top.
    public let x: Double
    public let y: Double
    /// Faded: the pointer has not moved for a while.
    public let isIdle: Bool
    /// Changes on every click, so the ring starts again. 0 draws none.
    public let ping: Double

    public init(id: String, name: String, color: OverlayColor, x: Double, y: Double, isIdle: Bool, ping: Double) {
        self.id = id
        self.name = name
        self.color = color
        self.x = x
        self.y = y
        self.isIdle = isIdle
        self.ping = ping
    }
}

/// A pointer's colour: what the page computed from the participant.
public struct OverlayColor: Equatable {
    public let red: Int
    public let green: Int
    public let blue: Int

    /// What a pointer gets when the page's colour cannot be read.
    public static let fallback = OverlayColor(red: 232, green: 188, blue: 104)

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    // `rgb(1 2 3)` or `rgb(1, 2, 3)`: the two forms a computed colour has.
    private static let pattern = try? NSRegularExpression(
        pattern: #"^rgb\(\s*(\d{1,3})(?:\s*,\s*|\s+)(\d{1,3})(?:\s*,\s*|\s+)(\d{1,3})\s*\)$"#
    )

    /// Nil for anything that is not a plain `rgb(…)` colour. A component
    /// above 255 is 255, as it is in CSS.
    public init?(css: String) {
        let whole = NSRange(css.startIndex..., in: css)
        guard let match = Self.pattern?.firstMatch(in: css, range: whole), match.numberOfRanges == 4 else { return nil }
        let parts = (1...3).compactMap { index -> Int? in
            Range(match.range(at: index), in: css).flatMap { Int(css[$0]) }.map { min($0, 255) }
        }
        guard parts.count == 3 else { return nil }
        self.init(red: parts[0], green: parts[1], blue: parts[2])
    }
}

public enum OverlayPointers {
    /// No call shows more pointers than this; it bounds what one message costs.
    public static let most = 32
    /// In UTF-16 units, as the page counts them.
    public static let longestName = 64
    public static let longestID = 128

    /// The pointers in what the page sent, or none when it is not a list of
    /// them. An entry without an id or a place is left out; a name too long
    /// is cut, a colour that cannot be read replaced.
    public static func sanitized(_ value: Any?) -> [OverlayPointer] {
        guard let list = value as? [Any] else { return [] }
        var pointers: [OverlayPointer] = []
        for raw in list.prefix(most) {
            guard let entry = raw as? [String: Any],
                  let id = entry["id"] as? String, !id.isEmpty, id.utf16.count <= longestID,
                  let x = fraction(entry["x"]), let y = fraction(entry["y"]) else { continue }
            let color = (entry["color"] as? String).flatMap(OverlayColor.init(css:)) ?? .fallback
            let ping = number(entry["ping"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
            pointers.append(OverlayPointer(
                id: id, name: cut(entry["name"] as? String ?? ""), color: color,
                x: x, y: y, isIdle: isTrue(entry["idle"]), ping: ping
            ))
        }
        return pointers
    }

    /// A JavaScript number; a boolean is not one.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let number = number(value), number.isFinite, number >= 0, number <= 1 else { return nil }
        return number
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// The name, no longer than the page's limit, and never ending in half
    /// of a character.
    private static func cut(_ name: String) -> String {
        var short = String(name.prefix(longestName))
        while short.utf16.count > longestName {
            short.removeLast()
        }
        return short
    }
}

/// Which display the pointers belong on: the one the share shows.
///
/// The shell does not know which of the page's captures is published, only
/// which run. The pointers go on the display of the newest capture of a
/// whole display that still runs: a share, or the share that replaced it.
/// A window share has none, as in the Electron build: where another
/// application's window sits on the desktop changes under it, and the shell
/// is not told. While the stream setup screen previews another display the
/// pointers are on that one, and come back when the preview is dropped.
public struct PointerOverlayTarget: Equatable {
    private var captures: [Capture] = []

    private struct Capture: Equatable {
        let id: String
        let display: UInt32?
    }

    public init() {}

    /// A capture started. `display` is nil for a capture of a window.
    public mutating func started(_ id: String, display: UInt32?) {
        captures.removeAll { $0.id == id }
        captures.append(Capture(id: id, display: display))
    }

    public mutating func stopped(_ id: String) {
        captures.removeAll { $0.id == id }
    }

    public var display: UInt32? {
        captures.last { $0.display != nil }?.display
    }
}
