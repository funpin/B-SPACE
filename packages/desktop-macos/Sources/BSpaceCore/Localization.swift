import Foundation

/// One of the languages the shell has strings for. Which ones there are is
/// read from the string catalog, so a language is added there and nowhere in
/// this code; a value of this type can only come from `DesktopStrings`.
///
/// The web client owns the choice (Settings → Language) and reports it on the
/// `set-language` channel; the shell remembers it in `language.json`, so the
/// menus are right from the first moment of the next launch. Before the web
/// client has ever said anything, the system's language decides.
public struct DesktopLanguage: Hashable {
    /// The code the web client uses for it: `en`, `ru`, `de`, `pt`, `zh`.
    public let code: String

    fileprivate init(code: String) {
        self.code = code
    }
}

/// `language.json` in the user-data folder, in the format
/// `packages/desktop/src/l10n.ts` writes (`{"language":"ru"}`).
public struct LanguageStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("language.json", isDirectory: false)
    }

    /// The stored language code, or nil when there is none. Whether the shell
    /// has that language is for `DesktopStrings` to say.
    public func load() -> String? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["language"] as? String
    }

    public func save(_ language: DesktopLanguage) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: ["language": language.code])
        try data.write(to: fileURL, options: .atomic)
    }
}

/// The strings the shell shows on its own: menu items now, the tray and the
/// update actions in later stages.
///
/// They are read from `packages/desktop/src/desktopStrings.json`, the one
/// catalog of both desktop shells (the Electron build's `l10n.ts` reads the
/// same file). The keys under `mac.` are this app's own: the standard menu
/// items Electron fills in from its roles, and under `mac.permission.` the
/// texts of the system's permission prompts, which `scripts/bundle.sh` writes
/// into the bundle.
public struct DesktopStrings {
    public enum Key: String, CaseIterable {
        case sourceCode = "tray.sourceCode"
        case changeInstance = "tray.changeInstance"
        case trayShow = "tray.show"
        case trayQuit = "tray.quit"
        case trayInVoice = "tray.inVoice"
        case trayDisconnect = "tray.disconnect"
        case trayStatusDnd = "tray.status.dnd"
        case trayMicrophoneOn = "mac.tray.microphoneOn"
        case trayMicrophoneOff = "mac.tray.microphoneOff"
        case traySoundOn = "mac.tray.soundOn"
        case traySoundOff = "mac.tray.soundOff"
        case trayPointersOn = "mac.tray.pointersOn"
        case trayPointersOff = "mac.tray.pointersOff"
        case trayStopCamera = "mac.tray.stopCamera"
        case trayStopScreenShare = "mac.tray.stopScreenShare"
        case editMenu = "menu.edit"
        case windowMenu = "menu.window"

        case about = "mac.menu.about"
        case hide = "mac.menu.hide"
        case hideOthers = "mac.menu.hideOthers"
        case showAll = "mac.menu.showAll"
        case quit = "mac.menu.quit"
        case undo = "mac.menu.undo"
        case redo = "mac.menu.redo"
        case cut = "mac.menu.cut"
        case copy = "mac.menu.copy"
        case paste = "mac.menu.paste"
        case selectAll = "mac.menu.selectAll"
        case minimize = "mac.menu.minimize"
        case zoom = "mac.menu.zoom"
        case close = "mac.menu.close"
        case bringAllToFront = "mac.menu.bringAllToFront"
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The prefix of the keys that hold a permission prompt's text. What
    /// follows it is the Info.plist key the text belongs to.
    public static let permissionPrefix = "mac.permission."
    private static let englishCode = "en"

    private let catalogs: [String: [String: String]]

    /// Every language of the catalog, English first, the rest by code.
    public let languages: [DesktopLanguage]
    /// The language of last resort.
    public let english: DesktopLanguage

    /// Reads the catalog and refuses one that would leave something without
    /// its text: English must be there, and every language must have every
    /// key the shell uses and every permission text English has.
    public init(data: Data) throws {
        let decoded: [String: [String: String]]
        do {
            decoded = try JSONDecoder().decode([String: [String: String]].self, from: data)
        } catch {
            throw Failure(description: "the string catalog is not a table of languages: \(error.localizedDescription)")
        }
        guard let english = decoded[Self.englishCode] else {
            throw Failure(description: "the string catalog has no '\(Self.englishCode)'")
        }
        let permissionKeys = english.keys.filter { $0.hasPrefix(Self.permissionPrefix) }
        let required = (Key.allCases.map(\.rawValue) + permissionKeys).sorted()
        for (code, catalog) in decoded.sorted(by: { $0.key < $1.key }) {
            let missing = required.filter { (catalog[$0] ?? "").isEmpty }
            guard missing.isEmpty else {
                throw Failure(description: "'\(code)' lacks \(missing.joined(separator: ", "))")
            }
        }
        catalogs = decoded
        self.english = DesktopLanguage(code: Self.englishCode)
        languages = [self.english] + decoded.keys.filter { $0 != Self.englishCode }.sorted().map(DesktopLanguage.init(code:))
    }

    /// The language with this code, if the catalog has it.
    public func language(code: String?) -> DesktopLanguage? {
        guard let code, catalogs[code] != nil else { return nil }
        return DesktopLanguage(code: code)
    }

    /// The language of a locale tag: `de-AT` gives `de`, `zh-Hans-CN` gives
    /// `zh`; a language the catalog lacks gives nil. The same rule as the web
    /// client's.
    public func language(tag: String?) -> DesktopLanguage? {
        guard let tag else { return nil }
        let lowered = tag.trimmingCharacters(in: .whitespaces).lowercased()
        return language(code: lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init))
    }

    /// The language to start in: the stored choice first, then the system's
    /// language, then English.
    public func resolve(stored: String?, systemLanguage: String?) -> DesktopLanguage {
        language(code: stored) ?? language(tag: systemLanguage) ?? english
    }

    /// The text of a key, with `{name}` placeholders filled in from `values`.
    /// A placeholder with no value stays as it is written.
    public func text(_ key: Key, in language: DesktopLanguage, _ values: [String: String] = [:]) -> String {
        var text = catalogs[language.code]?[key.rawValue] ?? key.rawValue
        for (name, value) in values {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return text
    }

    /// The texts of the system's permission prompts in a language, by the
    /// Info.plist key each belongs to.
    public func permissionTexts(in language: DesktopLanguage) -> [String: String] {
        var texts: [String: String] = [:]
        for (key, text) in catalogs[language.code] ?? [:] where key.hasPrefix(Self.permissionPrefix) {
            texts[String(key.dropFirst(Self.permissionPrefix.count))] = text
        }
        return texts
    }
}

/// Where the source code of the software the user is talking to can be found.
/// The licence (AGPL) gives every user of an instance the right to its
/// source, and an operator running a modified build names their own
/// repository in `GET /api/instance/info`.
public enum SourceCode {
    public static let projectAddress = "https://github.com/funpin/B-SPACE"

    /// The address to ask an instance at, from the address it was loaded
    /// from. Nil when that is not a web address.
    public static func instanceInfoURL(instanceAddress: String?) -> URL? {
        guard
            let instanceAddress,
            let url = URL(string: instanceAddress),
            let origin = WebOrigin.of(url)
        else { return nil }
        return URL(string: origin + "/api/instance/info")
    }

    /// The source address from an instance's answer, or the project's own
    /// when the answer is missing, is not what it should be, or names
    /// something that is not a web address.
    public static func address(fromInstanceInfo data: Data?) -> String {
        guard
            let data,
            let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let address = info["sourceCodeUrl"] as? String,
            let scheme = URL(string: address)?.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return projectAddress }
        return address
    }
}
