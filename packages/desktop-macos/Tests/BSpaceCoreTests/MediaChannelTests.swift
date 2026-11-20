import Foundation
import Testing
@testable import BSpaceCore

@Suite struct MediaChannelGateTests {
    @Test func theTokenIsLongAndNeverTheSame() {
        let first = MediaChannelGate.newToken()
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(first != MediaChannelGate.newToken())
    }

    @Test func theConnectionThatSaysTheTokenGetsTheChannel() {
        var gate = MediaChannelGate(token: "secret")
        #expect(gate.client == nil)
        #expect(gate.firstMessage(from: 1, text: "secret") == .accept)
        #expect(gate.client == 1)
    }

    @Test func anythingElseIsRefused() {
        var gate = MediaChannelGate(token: "secret")
        #expect(gate.firstMessage(from: 1, text: "guess!") == .refuse)
        #expect(gate.firstMessage(from: 2, text: "secre") == .refuse)
        #expect(gate.firstMessage(from: 3, text: "secret ") == .refuse)
        #expect(gate.firstMessage(from: 4, text: "") == .refuse)
        // A binary message is not a token.
        #expect(gate.firstMessage(from: 5, text: nil) == .refuse)
        #expect(gate.client == nil)
        // A wrong guess does not spend the token.
        #expect(gate.firstMessage(from: 6, text: "secret") == .accept)
    }

    @Test func theTokenWorksOnce() {
        var gate = MediaChannelGate(token: "secret")
        #expect(gate.firstMessage(from: 1, text: "secret") == .accept)
        #expect(gate.firstMessage(from: 2, text: "secret") == .refuse)
        #expect(gate.client == 1)
        // Not even after the page's connection is gone.
        gate.closed(1)
        #expect(gate.client == nil)
        #expect(gate.firstMessage(from: 3, text: "secret") == .refuse)
    }

    @Test func aConnectionThatWasNeverTheClientClosesQuietly() {
        var gate = MediaChannelGate(token: "secret")
        #expect(gate.firstMessage(from: 1, text: "secret") == .accept)
        gate.closed(2)
        #expect(gate.client == 1)
    }

    @Test func onlyThePagesOriginIsLetThrough() {
        let page = "https://chat.example.org"
        #expect(MediaChannelGate.isOriginAllowed(page, page: page))
        #expect(!MediaChannelGate.isOriginAllowed("https://other.example.org", page: page))
        #expect(!MediaChannelGate.isOriginAllowed("http://chat.example.org", page: page))
        // A program that is not a browser sends none.
        #expect(!MediaChannelGate.isOriginAllowed(nil, page: page))
        // A channel that was not told its page lets the token decide.
        #expect(MediaChannelGate.isOriginAllowed("https://anything.example", page: nil))
        #expect(MediaChannelGate.isOriginAllowed(nil, page: nil))
    }

    @Test func comparesWholeStrings() {
        #expect(MediaChannelGate.isSame("abc", "abc"))
        #expect(!MediaChannelGate.isSame("abc", "abd"))
        #expect(!MediaChannelGate.isSame("abc", "ab"))
        #expect(!MediaChannelGate.isSame("", "a"))
        #expect(MediaChannelGate.isSame("", ""))
    }
}

@Suite struct LocalIdentityChannelTests {
    @Test func onlyItsOwnCertificateOnItsOwnPortIsTheChannel() throws {
        let identity = try LocalIdentity()
        let other = try LocalIdentity()
        #expect(identity.isChannel(host: "127.0.0.1", port: 50123, certificateChain: [identity.certificate], channelPort: 50123))
        #expect(!identity.isChannel(host: "127.0.0.1", port: 50124, certificateChain: [identity.certificate], channelPort: 50123))
        #expect(!identity.isChannel(host: "localhost", port: 50123, certificateChain: [identity.certificate], channelPort: 50123))
        #expect(!identity.isChannel(host: "chat.example.org", port: 50123, certificateChain: [identity.certificate], channelPort: 50123))
        #expect(!identity.isChannel(host: "127.0.0.1", port: 50123, certificateChain: [other.certificate], channelPort: 50123))
        #expect(!identity.isChannel(host: "127.0.0.1", port: 50123, certificateChain: [], channelPort: 50123))
        #expect(!identity.isChannel(
            host: "127.0.0.1", port: 50123, certificateChain: [identity.certificate, other.certificate], channelPort: 50123
        ))
    }
}
