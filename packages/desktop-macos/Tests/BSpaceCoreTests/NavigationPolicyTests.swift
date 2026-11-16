import Foundation
import Testing
@testable import BSpaceCore

private let picker = URL(string: "file:///Applications/B-SPACE.app/Contents/Resources/instance-picker.html")!

private func request(
    _ target: String,
    current: String? = nil,
    known: Set<String> = [],
    shellLoad: String? = nil
) -> NavigationRequest {
    NavigationRequest(
        target: URL(string: target)!,
        currentURL: current.flatMap(URL.init(string:)),
        pickerFileURL: picker,
        knownInstanceOrigins: known,
        shellLoad: shellLoad.flatMap(URL.init(string:))
    )
}

@Suite struct WebOriginTests {
    @Test func spellsAnOriginAsABrowserDoes() {
        #expect(WebOrigin.of(URL(string: "https://Chat.Example.com/app?x=1#y")!) == "https://chat.example.com")
        #expect(WebOrigin.of(URL(string: "https://chat.example.com:443/")!) == "https://chat.example.com")
        #expect(WebOrigin.of(URL(string: "http://chat.example.com:80/")!) == "http://chat.example.com")
        #expect(WebOrigin.of(URL(string: "https://chat.example.com:8443/")!) == "https://chat.example.com:8443")
        #expect(WebOrigin.of(URL(string: "http://localhost:3005/login")!) == "http://localhost:3005")
        #expect(WebOrigin.of(URL(string: "http://[::1]:3005/")!) == "http://[::1]:3005")
        #expect(WebOrigin.of(URL(string: "http://192.168.1.20/")!) == "http://192.168.1.20")
    }

    @Test func hasNoOriginForWhatIsNotAWebAddress() {
        #expect(WebOrigin.of(URL(string: "file:///etc/passwd")!) == nil)
        #expect(WebOrigin.of(URL(string: "javascript:alert(1)")!) == nil)
        #expect(WebOrigin.of(URL(string: "backspace://join/abc")!) == nil)
        #expect(WebOrigin.of(URL(string: "about:blank")!) == nil)
    }
}

/// The cases of `packages/desktop/src/navigationPolicy.test.ts`, then the ones
/// that exist only here because the shell's own loads pass through the policy.
@Suite struct NavigationPolicyTests {
    @Test func allowsSameOriginNavigation() {
        #expect(NavigationPolicy.isAllowed(request("https://chat.example.com/channels/123", current: "https://chat.example.com/app")))
    }

    @Test func allowsThePicker() {
        #expect(NavigationPolicy.isAllowed(request(picker.absoluteString)))
    }

    @Test func deniesAnyOtherFile() {
        #expect(!NavigationPolicy.isAllowed(request("file:///etc/passwd")))
        #expect(!NavigationPolicy.isAllowed(request(picker.absoluteString + "?lang=ru")))
    }

    @Test func allowsAKnownFederationPeer() {
        #expect(NavigationPolicy.isAllowed(request(
            "https://peer.example.org/invite",
            current: "https://chat.example.com/app",
            known: ["https://peer.example.org"]
        )))
    }

    @Test func deniesAForeignOrigin() {
        #expect(!NavigationPolicy.isAllowed(request(
            "https://evil.example.net/phish",
            current: "https://chat.example.com/app",
            known: ["https://peer.example.org"]
        )))
        #expect(!NavigationPolicy.isAllowed(request("https://evil.example.net/")))
    }

    @Test func deniesWhatIsNotAWebAddress() {
        #expect(!NavigationPolicy.isAllowed(request("javascript:alert(1)", current: "https://chat.example.com/app")))
        #expect(!NavigationPolicy.isAllowed(request("backspace://join/abc", current: "https://chat.example.com/app")))
        #expect(!NavigationPolicy.isAllowed(request("about:blank", current: "https://chat.example.com/app")))
    }

    @Test func treatsADifferentPortOrSchemeAsForeign() {
        #expect(!NavigationPolicy.isAllowed(request("https://chat.example.com:8443/", current: "https://chat.example.com/app")))
        #expect(!NavigationPolicy.isAllowed(request("http://chat.example.com/", current: "https://chat.example.com/app")))
    }

    @Test func allowsTheAddressTheShellItselfLoads() {
        #expect(NavigationPolicy.isAllowed(request("https://chat.example.com/", shellLoad: "https://chat.example.com/")))
        let localised = picker.absoluteString + "?lang=ru"
        #expect(NavigationPolicy.isAllowed(request(localised, current: "https://chat.example.com/app", shellLoad: localised)))
    }

    @Test func allowsARedirectOfTheShellLoadThatStaysOnItsSite() {
        #expect(NavigationPolicy.isAllowed(request("https://chat.example.com/login", shellLoad: "https://chat.example.com/")))
        #expect(NavigationPolicy.isAllowed(request("https://chat.example.com/", shellLoad: "http://chat.example.com/")))
    }

    @Test func deniesARedirectOfTheShellLoadToAnotherSite() {
        #expect(!NavigationPolicy.isAllowed(request("https://evil.example.net/", shellLoad: "https://chat.example.com/")))
        #expect(!NavigationPolicy.isAllowed(request("https://chat.example.com:8443/", shellLoad: "http://chat.example.com/")))
        #expect(!NavigationPolicy.isAllowed(request("http://chat.example.com/", shellLoad: "https://chat.example.com/")))
        #expect(!NavigationPolicy.isAllowed(request("file:///etc/passwd", shellLoad: "https://chat.example.com/")))
    }
}

@Suite struct WindowOpenDecisionTests {
    private let known: Set<String> = ["https://chat.example.com"]

    @Test func routesAnInviteOfAConnectedInstanceIntoTheClient() {
        let decision = NavigationPolicy.windowOpenDecision(url: URL(string: "https://chat.example.com/join/abc?x=1")!, knownInstanceOrigins: known)
        #expect(decision == .internalRoute("/join/abc?x=1"))
        let plain = NavigationPolicy.windowOpenDecision(url: URL(string: "https://chat.example.com/join/abc")!, knownInstanceOrigins: known)
        #expect(plain == .internalRoute("/join/abc"))
    }

    @Test func sendsEveryOtherWebAddressToTheBrowser() {
        let other = URL(string: "https://chat.example.com/channels/1")!
        #expect(NavigationPolicy.windowOpenDecision(url: other, knownInstanceOrigins: known) == .external(other))
        let foreign = URL(string: "https://elsewhere.example.org/join/abc")!
        #expect(NavigationPolicy.windowOpenDecision(url: foreign, knownInstanceOrigins: known) == .external(foreign))
    }

    @Test func ignoresWhatIsNotAWebAddress() {
        #expect(NavigationPolicy.windowOpenDecision(url: URL(string: "file:///etc/passwd")!, knownInstanceOrigins: known) == .ignore)
        #expect(NavigationPolicy.windowOpenDecision(url: URL(string: "javascript:alert(1)")!, knownInstanceOrigins: known) == .ignore)
    }
}
