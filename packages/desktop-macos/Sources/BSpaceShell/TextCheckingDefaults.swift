import Foundation

/// The text-editing switches WebKit reads from the application's defaults when
/// a web view is created.
///
/// Left alone, `WKWebView` rewrites what the user types: `"q" -- ...` becomes
/// `«q» — …`, and a `--flag` in a code block turns into `—flag`. Electron does
/// none of that, checks spelling and does not check grammar; a `WKWebView`
/// starts out the other way round on both. Keys and measurement: the stage 0
/// pre-audit, section 2.4.
public enum TextCheckingDefaults {
    static let values: [String: Bool] = [
        "WebAutomaticQuoteSubstitutionEnabled": false,
        "WebAutomaticDashSubstitutionEnabled": false,
        "WebAutomaticTextReplacementEnabled": false,
        "WebAutomaticSpellingCorrectionEnabled": false,
        "WebContinuousSpellCheckingEnabled": true,
        "WebGrammarCheckingEnabled": false,
    ]

    /// Must run before the first `WKWebView` exists.
    public static func apply(to defaults: UserDefaults = .standard) {
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }
}
