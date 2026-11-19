import Foundation

/// A notification the web client asked for: `showNotification(title, body,
/// options)`. `options` says what a click should open (a channel, a space, a
/// user) and is handed back to the page, untouched, when the notification is
/// clicked.
///
/// The notification outlives the page that asked for it: it can be clicked
/// minutes later, after the user has moved to another instance. So it carries
/// the origin of the page at the moment of the call, and the click reaches the
/// page only if the page is still of that origin: identifiers from one
/// instance must not open things on another.
public struct NotificationRequest: Equatable {
    public let title: String
    public let body: String
    /// The origin of the page that asked, or nil when it has none (a file).
    public let origin: String?
    /// The click payload as JSON text, or nil when the page gave none.
    public let optionsJSON: String?

    public init(title: String, body: String, origin: String?, optionsJSON: String?) {
        self.title = title
        self.body = body
        self.origin = origin
        self.optionsJSON = optionsJSON
    }

    /// From the arguments of the bridge call. Nil when there is no title to
    /// show: a notification with nothing on it is not shown.
    public init?(arguments: BridgeArguments, pageURL: URL?) {
        guard let title = arguments.string(at: 0), !title.isEmpty else { return nil }
        var optionsJSON: String?
        if
            let options = arguments.object(at: 2),
            JSONSerialization.isValidJSONObject(options),
            let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
        {
            optionsJSON = String(decoding: data, as: UTF8.self)
        }
        self.init(
            title: title,
            body: arguments.string(at: 1) ?? "",
            origin: pageURL.flatMap(WebOrigin.of),
            optionsJSON: optionsJSON
        )
    }

    private static let originKey = "origin"
    private static let optionsKey = "options"

    /// What travels with the notification through the system, to be read
    /// again when it is clicked. Strings only: the system stores it as a
    /// property list.
    public var userInfo: [String: String] {
        var info: [String: String] = [:]
        if let origin { info[Self.originKey] = origin }
        if let optionsJSON { info[Self.optionsKey] = optionsJSON }
        return info
    }

    /// What to send the page on `notification-click` for a notification that
    /// was clicked, given the page the window shows now. Nil when the click
    /// should only bring the window forward: the notification had no payload,
    /// or the page is no longer of the origin that asked for it.
    public static func clickPayload(userInfo: [AnyHashable: Any], currentPageURL: URL?) -> [String: Any]? {
        guard
            let origin = userInfo[originKey] as? String,
            let current = currentPageURL.flatMap(WebOrigin.of),
            origin == current,
            let json = userInfo[optionsKey] as? String,
            let options = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        return options
    }
}

public enum BadgeCount {
    /// The label of the Dock icon's badge for what the page passed to
    /// `setBadgeCount`: the whole number when it is one or more, no badge
    /// otherwise (zero, a negative number, or something that is not a number).
    public static func label(for value: Double?) -> String? {
        guard let value, value.isFinite, value >= 1, value < 1e15 else { return nil }
        return String(Int(value))
    }
}
