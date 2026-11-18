import Foundation

/// Who may use the microphone and the camera.
///
/// A web view asks the shell before it asks the system. Without an answer
/// WebKit shows its own question on top of the system's, once per page load:
/// two prompts where the Electron build shows one. The shell answers for the
/// page it loaded itself and leaves everything else without the devices.
public enum MediaCapturePolicy {
    public enum Decision: Equatable {
        /// The page gets the device; the system still asks the user once.
        case grant
        case deny
    }

    /// - Parameters:
    ///   - isMainFrame: whether the request comes from the page of the window
    ///     and not from a frame inside it.
    ///   - requestOrigin: the origin of the frame that asks, as `WebOrigin`
    ///     spells it; nil when it is not a web address.
    ///   - pageURL: the address the window shows.
    public static func decision(isMainFrame: Bool, requestOrigin: String?, pageURL: URL?) -> Decision {
        // A frame inside the page is somebody else's content: an embedded
        // player has no business with the microphone.
        guard isMainFrame else { return .deny }
        // The shell's own pages (the instance picker, recovery) are files and
        // have no origin here; they never ask.
        guard let requestOrigin, let pageURL, let pageOrigin = WebOrigin.of(pageURL) else { return .deny }
        return requestOrigin == pageOrigin ? .grant : .deny
    }
}

extension WebOrigin {
    /// The origin from its parts, as WebKit reports the origin of a frame: a
    /// port of 0 stands for the scheme's default.
    public static func of(scheme: String, host: String, port: Int) -> String? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if port != 0 {
            components.port = port
        }
        return components.url.flatMap(of)
    }
}
