import Foundation

/// An origin the way a browser spells it: `scheme://host`, with the port only
/// when it is not the scheme's default. The web client reports the instances
/// it is connected to as `URL.origin` strings, and they are compared with this.
public enum WebOrigin {
    public static func of(_ url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            var host = components.encodedHost?.lowercased(),
            !host.isEmpty
        else { return nil }

        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = components.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

/// One top-level navigation of the main window, with what the shell knows at
/// the moment it has to decide.
public struct NavigationRequest {
    /// Where the navigation goes.
    public var target: URL
    /// The page the window shows now, if any.
    public var currentURL: URL?
    /// The bundled server picker, without a query.
    public var pickerFileURL: URL
    /// Origins the web client has reported as connected (its own instance and
    /// its federation peers).
    public var knownInstanceOrigins: Set<String>
    /// The address the shell itself asked the window to load, for as long as
    /// that load has not finished: the saved instance, the one just chosen in
    /// the picker, or the picker.
    public var shellLoad: URL?

    public init(
        target: URL,
        currentURL: URL?,
        pickerFileURL: URL,
        knownInstanceOrigins: Set<String>,
        shellLoad: URL? = nil
    ) {
        self.target = target
        self.currentURL = currentURL
        self.pickerFileURL = pickerFileURL
        self.knownInstanceOrigins = knownInstanceOrigins
        self.shellLoad = shellLoad
    }
}

/// What to do with a link that asks for a new window.
public enum WindowOpenDecision: Equatable {
    /// An invite link of a connected instance: hand its path to the web client.
    case internalRoute(String)
    /// Any other web address: the default browser opens it.
    case external(URL)
    /// Not a web address: nothing happens.
    case ignore
}

/// Which navigations the main window may make. A port of
/// `packages/desktop/src/navigationPolicy.ts` and of the window-open handler in
/// `main.ts`, with one difference in mechanism.
///
/// Electron raises `will-navigate` only for navigations a page starts; its own
/// `loadURL` calls and the redirects a server answers them with never reach the
/// policy. `WKNavigationDelegate` is asked about every navigation, so the shell
/// passes the address it is loading itself as `shellLoad`, and the policy lets
/// through that address, anything else on its origin, and the same host moved
/// to `https`. A redirect anywhere else is refused, which is stricter than
/// Electron (deviation 3 in the plan).
public enum NavigationPolicy {
    public static func isAllowed(_ request: NavigationRequest) -> Bool {
        let target = request.target
        if let shellLoad = request.shellLoad, target.absoluteString == shellLoad.absoluteString {
            return true
        }

        let scheme = target.scheme?.lowercased()
        if scheme == "file" {
            return target.absoluteString == request.pickerFileURL.absoluteString
        }
        guard let targetOrigin = WebOrigin.of(target) else { return false }

        if let currentURL = request.currentURL, WebOrigin.of(currentURL) == targetOrigin {
            return true
        }
        if request.knownInstanceOrigins.contains(targetOrigin) {
            return true
        }
        if let shellLoad = request.shellLoad {
            return isSameSiteRedirect(from: shellLoad, to: target, targetOrigin: targetOrigin)
        }
        return false
    }

    /// A redirect of the shell's own load that stays on the address the user
    /// gave: the same origin, or `http` answered with `https` on the same host
    /// and the default port.
    private static func isSameSiteRedirect(from shellLoad: URL, to target: URL, targetOrigin: String) -> Bool {
        guard let loadOrigin = WebOrigin.of(shellLoad) else { return false }
        if loadOrigin == targetOrigin { return true }
        guard loadOrigin.hasPrefix("http://"), targetOrigin.hasPrefix("https://") else { return false }
        return loadOrigin.dropFirst("http://".count) == targetOrigin.dropFirst("https://".count)
    }

    public static func windowOpenDecision(url: URL, knownInstanceOrigins: Set<String>) -> WindowOpenDecision {
        guard let origin = WebOrigin.of(url) else { return .ignore }
        if
            knownInstanceOrigins.contains(origin),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
            components.percentEncodedPath.hasPrefix("/join/")
        {
            let query = components.percentEncodedQuery.flatMap { $0.isEmpty ? nil : "?\($0)" } ?? ""
            return .internalRoute(components.percentEncodedPath + query)
        }
        return .external(url)
    }
}
