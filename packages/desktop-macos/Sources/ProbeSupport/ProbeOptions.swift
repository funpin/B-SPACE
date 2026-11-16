import Foundation

/// Command line of WebKitProbe, parsed without AppKit so it can be tested.
public struct ProbeOptions: Equatable {
    public enum TitleBar: String, Equatable {
        /// An ordinary titled window.
        case standard
        /// Transparent title bar over a full-size content view, as the app window will be.
        case hiddenInset
    }

    public var url: URL
    public var width: Int = 1280
    public var height: Int = 800
    /// File whose text is the body of an async JavaScript function run in the page.
    public var scriptPath: String?
    /// A JavaScript expression awaited in the page, for pages that carry their
    /// own probe: `--call "window.runProbe()"`. Ignored when `scriptPath` is set.
    public var callExpression: String?
    /// Where the JSON report is written. Standard output when nil.
    public var outPath: String?
    /// Snapshot of the web view taken after the script has returned.
    public var snapshotPath: String?
    /// Picture of the window as the window server composites it, title bar
    /// included, taken after the script has returned. Unlike `snapshotPath`
    /// it shows backdrop blur, which the view's own snapshot leaves out.
    public var windowCapturePath: String?
    /// Milliseconds to wait after the page has loaded, before the script runs.
    public var settleMilliseconds: Int = 500
    /// Whole-run limit; the report then carries `timedOut: true`.
    public var timeoutSeconds: Int = 60
    /// `WKWebViewConfiguration.applicationNameForUserAgent`.
    public var applicationNameForUserAgent: String?
    public var titleBar: TitleBar = .standard
    /// Bring the window to the front and make it key. Needed by probes that send clicks and keys.
    public var activate = false
    /// User defaults registered before the web view exists, as `key=value`
    /// (`true`/`false` become booleans, everything else stays a string).
    public var defaults: [String: String] = [:]
    /// Directory downloads are saved into.
    public var downloadDirectory: String?
    /// Use a non-persistent data store, so runs do not see each other's storage.
    public var ephemeral = false
    /// Turn off WebKit's ICE candidate filtering through a private preference,
    /// so a loopback connection can form without capture permission.
    /// A measuring aid only.
    public var unfilteredICE = false

    public init(url: URL) {
        self.url = url
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case unknownOption(String)
        case missingURL
        case invalid(option: String, value: String)

        public var description: String {
            switch self {
            case .missingValue(let option): return "\(option) needs a value"
            case .unknownOption(let option): return "unknown option \(option)"
            case .missingURL: return "--url is required"
            case .invalid(let option, let value): return "\(option): cannot use \"\(value)\""
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var url: URL?
        var options = ProbeOptions(url: URL(fileURLWithPath: "/"))
        var index = 0

        func value(for option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(option) }
            return arguments[index]
        }
        func integer(for option: String) throws -> Int {
            let raw = try value(for: option)
            guard let parsed = Int(raw), parsed >= 0 else { throw ParseError.invalid(option: option, value: raw) }
            return parsed
        }

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--url":
                let raw = try value(for: option)
                guard let parsed = URL(string: raw), parsed.scheme != nil else {
                    throw ParseError.invalid(option: option, value: raw)
                }
                url = parsed
            case "--size":
                let raw = try value(for: option)
                let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                    throw ParseError.invalid(option: option, value: raw)
                }
                options.width = parts[0]
                options.height = parts[1]
            case "--script": options.scriptPath = try value(for: option)
            case "--call": options.callExpression = try value(for: option)
            case "--out": options.outPath = try value(for: option)
            case "--snapshot": options.snapshotPath = try value(for: option)
            case "--window-capture": options.windowCapturePath = try value(for: option)
            case "--settle-ms": options.settleMilliseconds = try integer(for: option)
            case "--timeout": options.timeoutSeconds = try integer(for: option)
            case "--ua-app-name": options.applicationNameForUserAgent = try value(for: option)
            case "--titlebar":
                let raw = try value(for: option)
                guard let parsed = TitleBar(rawValue: raw) else {
                    throw ParseError.invalid(option: option, value: raw)
                }
                options.titleBar = parsed
            case "--activate": options.activate = true
            case "--ephemeral": options.ephemeral = true
            case "--unfiltered-ice": options.unfilteredICE = true
            case "--download-dir": options.downloadDirectory = try value(for: option)
            case "--default":
                let raw = try value(for: option)
                guard let separator = raw.firstIndex(of: "="), separator != raw.startIndex else {
                    throw ParseError.invalid(option: option, value: raw)
                }
                options.defaults[String(raw[..<separator])] = String(raw[raw.index(after: separator)...])
            default:
                throw ParseError.unknownOption(option)
            }
            index += 1
        }

        guard let url else { throw ParseError.missingURL }
        options.url = url
        return options
    }
}

/// Page coordinates (CSS pixels, origin top left) to AppKit window coordinates
/// (points, origin bottom left) for a web view that fills the content view.
public func windowPoint(clientX: Double, clientY: Double, contentHeight: Double) -> (x: Double, y: Double) {
    (clientX, contentHeight - clientY)
}
