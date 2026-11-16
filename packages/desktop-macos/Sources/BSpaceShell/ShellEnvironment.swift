import BSpaceCore
import Foundation

/// The files the shell loads at run time. In the application bundle they sit in
/// `Contents/Resources`, copied there by `scripts/bundle.sh` from
/// `packages/desktop`, which owns them for both shells.
public struct ShellResources {
    /// `instance-picker.html`, the page where the user names their instance.
    public let pickerURL: URL
    /// `bridgeContract.json`, the description of the bridges.
    public let contractURL: URL

    public init(pickerURL: URL, contractURL: URL) {
        self.pickerURL = pickerURL
        self.contractURL = contractURL
    }

    public static func bundled(in bundle: Bundle = .main) -> ShellResources? {
        guard
            let picker = bundle.url(forResource: "instance-picker", withExtension: "html"),
            let contract = bundle.url(forResource: "bridgeContract", withExtension: "json")
        else { return nil }
        return ShellResources(pickerURL: picker, contractURL: contract)
    }
}

/// Everything the shell takes from the machine it runs on, gathered once at
/// launch so the rest of it can be driven with other values in a test run.
public struct ShellEnvironment {
    public var resources: ShellResources
    /// Where the settings files live.
    public var userDataDirectory: URL
    /// The shell's own version, as `getVersion()` reports it.
    public var appVersion: String
    /// The installed Safari's version, when it could be read.
    public var safariVersion: String?
    /// `BACKSPACE_URL`: an address that overrides the saved instance, for
    /// managed deployments.
    public var overrideURL: String?
    /// The language the picker opens in before the web client has ever run.
    public var language: String

    public init(
        resources: ShellResources,
        userDataDirectory: URL,
        appVersion: String,
        safariVersion: String?,
        overrideURL: String?,
        language: String
    ) {
        self.resources = resources
        self.userDataDirectory = userDataDirectory
        self.appVersion = appVersion
        self.safariVersion = safariVersion
        self.overrideURL = overrideURL
        self.language = language
    }

    public enum Failure: Error, CustomStringConvertible {
        case resourcesMissing
        case noApplicationSupportDirectory

        public var description: String {
            switch self {
            case .resourcesMissing:
                return "The application bundle is incomplete: instance-picker.html or bridgeContract.json is missing from its resources."
            case .noApplicationSupportDirectory:
                return "The Application Support folder of this user could not be found."
            }
        }
    }

    /// The environment of the running application bundle.
    public static func ofRunningApplication(bundle: Bundle = .main) throws -> ShellEnvironment {
        guard let resources = ShellResources.bundled(in: bundle) else { throw Failure.resourcesMissing }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure.noApplicationSupportDirectory
        }
        let directoryName = AppIdentity.userDataDirectoryName(infoDictionary: bundle.infoDictionary)
        let override = ProcessInfo.processInfo.environment["BACKSPACE_URL"].flatMap { $0.isEmpty ? nil : $0 }
        return ShellEnvironment(
            resources: resources,
            userDataDirectory: support.appendingPathComponent(directoryName, isDirectory: true),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            safariVersion: installedSafariVersion(),
            overrideURL: override,
            language: preferredLanguage()
        )
    }

    /// Safari is part of the system and ships the WebKit this app renders with,
    /// so its version is the engine's.
    public static func installedSafariVersion() -> String? {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// The first of the user's languages, as a two-letter code. The picker
    /// falls back to English for one it has no strings for.
    public static func preferredLanguage() -> String {
        let identifier = Locale.preferredLanguages.first ?? "en"
        return Locale(identifier: identifier).language.languageCode?.identifier ?? "en"
    }

    /// What `WKWebView` appends to its User-Agent.
    public var userAgentApplicationName: String {
        UserAgent.applicationName(
            safariVersion: safariVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            appVersion: appVersion
        )
    }
}
