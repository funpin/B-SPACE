// Writes the texts of the system's permission prompts into an application
// bundle, from the string catalog of the desktop shells
// (packages/desktop/src/desktopStrings.json, keys under `mac.permission.`).
// Run by scripts/bundle.sh with the Swift interpreter.
//
// Usage: swift scripts/permission-texts.swift <catalog.json> <Contents/Resources>
//
// For every language of the catalog it writes <language>.lproj/InfoPlist.strings
// into the resources folder: the system reads a prompt's text from the folder
// of its own language, and the folders are also what tells it which languages
// the app speaks. On standard output it prints the English texts as the
// <key>/<string> lines of an Info.plist, which must name every permission the
// app asks for.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("permission-texts: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: permission-texts.swift <catalog.json> <Contents/Resources>")
}
let prefix = "mac.permission."
let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

guard
    let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
    let catalogs = try? JSONDecoder().decode([String: [String: String]].self, from: data)
else { fail("cannot read \(CommandLine.arguments[1]) as a table of languages") }

func texts(of language: String) -> [(key: String, text: String)] {
    (catalogs[language] ?? [:])
        .filter { $0.key.hasPrefix(prefix) }
        .map { (String($0.key.dropFirst(prefix.count)), $0.value) }
        .sorted { $0.key < $1.key }
}

let english = texts(of: "en")
guard !english.isEmpty else { fail("the catalog has no English permission texts") }

/// The folder macOS looks in for a language. The web client's `zh` is
/// Simplified Chinese; every other code is the folder's name as it is.
func folder(for language: String) -> String {
    (language == "zh" ? "zh-Hans" : language) + ".lproj"
}

for language in catalogs.keys.sorted() {
    let own = texts(of: language)
    guard own.map(\.key) == english.map(\.key) else {
        fail("'\(language)' does not have the permission texts English has")
    }
    let lines = own.map { entry -> String in
        let escaped = entry.text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(entry.key)\" = \"\(escaped)\";"
    }
    let directory = resources.appendingPathComponent(folder(for: language), isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("InfoPlist.strings"))
    } catch {
        fail("cannot write \(directory.path): \(error.localizedDescription)")
    }
}

for entry in english {
    let escaped = entry.text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    print("  <key>\(entry.key)</key><string>\(escaped)</string>")
}
