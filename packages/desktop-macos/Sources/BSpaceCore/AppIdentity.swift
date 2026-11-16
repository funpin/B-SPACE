import Foundation

/// The names the app goes by. Mirrors `packages/desktop/src/appIdentity.ts`:
/// the product is B:SPACE, while the bundle identifier and the user-data folder
/// keep the names an installed copy already has state under.
public enum AppIdentity {
    /// Shown in menus, the About panel, the window title and notifications.
    public static let displayName = "B:SPACE"

    /// `~/Library/Application Support/<this>` holds the settings files. It
    /// predates the rename and must not move: the Electron build reads the same
    /// folder, and a roll-back to it has to find its files.
    public static let userDataDirectoryName = "Backspace"

    /// Info.plist key a build may set to keep its settings somewhere else. A
    /// development build sets it, so that trying a branch never touches the
    /// files of the installed app.
    public static let userDataDirectoryInfoKey = "BSpaceUserDataDirectory"

    /// The token the shell adds to the User-Agent. Nothing reads it to branch
    /// on: the web client detects the shell by `window.backspace`. It is there
    /// for server logs and bug reports.
    public static let userAgentToken = "BSpaceDesktop"

    /// What `window.backspace.platform` says, as Node's `process.platform` does.
    public static let platform = "darwin"

    public static func userDataDirectoryName(infoDictionary: [String: Any]?) -> String {
        guard let name = infoDictionary?[userDataDirectoryInfoKey] as? String else {
            return userDataDirectoryName
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlainName = !trimmed.isEmpty && !trimmed.contains("/") && trimmed != "." && trimmed != ".."
        return isPlainName ? trimmed : userDataDirectoryName
    }
}

/// The suffix `WKWebView` appends to its default User-Agent
/// (`applicationNameForUserAgent`).
///
/// The default ends at `AppleWebKit/605.1.15 (KHTML, like Gecko)`, with no
/// `Version/` and no `Safari/`. `livekit-client` recognises WebKit without
/// them, but takes the Safari version from `Version/`, and its checks for VP9
/// and SVC support get `undefined` when it is absent. So the shell presents
/// itself as the Safari whose engine it runs, followed by its own token.
public enum UserAgent {
    /// - Parameters:
    ///   - safariVersion: the installed Safari's `CFBundleShortVersionString`,
    ///     when it could be read. The system WebKit is the one Safari ships
    ///     with, so this is the engine's version.
    ///   - systemVersion: the fallback when Safari's version is unknown.
    ///   - appVersion: the shell's own version.
    public static func applicationName(
        safariVersion: String?,
        systemVersion: OperatingSystemVersion,
        appVersion: String
    ) -> String {
        let engine = normalised(safariVersion) ?? Self.safariVersion(forSystem: systemVersion)
        return "Version/\(engine) Safari/605.1.15 \(AppIdentity.userAgentToken)/\(token(appVersion))"
    }

    /// Since macOS 26 Safari carries the system's version number. Before that
    /// it ran three ahead (Safari 17 on macOS 14, 18 on macOS 15).
    static func safariVersion(forSystem version: OperatingSystemVersion) -> String {
        let major = version.majorVersion >= 26 ? version.majorVersion : version.majorVersion + 3
        return "\(major).\(version.minorVersion)"
    }

    /// `major.minor` out of a version string, or nil when it does not start
    /// with a number.
    private static func normalised(_ version: String?) -> String? {
        guard let version else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let major = Int(first), major > 0 else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return "\(major).\(minor)"
    }

    /// A version is a product token here, so anything that could end the token
    /// or start a comment is dropped.
    private static func token(_ version: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-+_"))
        let cleaned = String(version.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "0" : cleaned
    }
}
