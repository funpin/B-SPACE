import Foundation
import Testing
@testable import BSpaceCore

@Suite struct MediaCapturePolicyTests {
    private let page = URL(string: "https://chat.example.org/channels/1")!

    @Test func thePageOfTheWindowGetsTheDevices() {
        #expect(MediaCapturePolicy.decision(
            isMainFrame: true, requestOrigin: "https://chat.example.org", pageURL: page
        ) == .grant)
    }

    @Test func aFrameInsideThePageDoesNot() {
        #expect(MediaCapturePolicy.decision(
            isMainFrame: false, requestOrigin: "https://chat.example.org", pageURL: page
        ) == .deny)
        #expect(MediaCapturePolicy.decision(
            isMainFrame: false, requestOrigin: "https://player.example.com", pageURL: page
        ) == .deny)
    }

    @Test func anOriginOtherThanThePagesDoesNot() {
        // The window was sent elsewhere between the request and the answer.
        #expect(MediaCapturePolicy.decision(
            isMainFrame: true, requestOrigin: "https://other.example.org", pageURL: page
        ) == .deny)
        #expect(MediaCapturePolicy.decision(
            isMainFrame: true, requestOrigin: "http://chat.example.org", pageURL: page
        ) == .deny)
    }

    @Test func theShellsOwnPagesDoNot() {
        let picker = URL(string: "file:///Applications/B-SPACE.app/Contents/Resources/instance-picker.html")!
        #expect(MediaCapturePolicy.decision(isMainFrame: true, requestOrigin: nil, pageURL: picker) == .deny)
        #expect(MediaCapturePolicy.decision(
            isMainFrame: true, requestOrigin: "https://chat.example.org", pageURL: picker
        ) == .deny)
        #expect(MediaCapturePolicy.decision(
            isMainFrame: true, requestOrigin: "https://chat.example.org", pageURL: nil
        ) == .deny)
    }

    @Test func anInstanceOverPlainHTTPOnItsOwnPortGetsThem() {
        let local = URL(string: "http://192.168.1.50:3000/")!
        #expect(MediaCapturePolicy.decision(
            isMainFrame: true, requestOrigin: WebOrigin.of(scheme: "http", host: "192.168.1.50", port: 3000), pageURL: local
        ) == .grant)
    }
}

@Suite struct WebOriginPartsTests {
    @Test func aPortOfZeroIsTheDefaultPort() {
        #expect(WebOrigin.of(scheme: "https", host: "chat.example.org", port: 0) == "https://chat.example.org")
        #expect(WebOrigin.of(scheme: "https", host: "chat.example.org", port: 443) == "https://chat.example.org")
        #expect(WebOrigin.of(scheme: "http", host: "Chat.Example.org", port: 8080) == "http://chat.example.org:8080")
    }

    @Test func whatIsNotAWebAddressHasNoOrigin() {
        #expect(WebOrigin.of(scheme: "file", host: "", port: 0) == nil)
        #expect(WebOrigin.of(scheme: "about", host: "", port: 0) == nil)
    }
}
