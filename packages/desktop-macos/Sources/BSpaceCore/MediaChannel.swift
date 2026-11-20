import Foundation

/// Who may speak on a local media channel.
///
/// The channel listens on the loopback address, where every program of the
/// machine can connect. The shell gives the page a token over the bridge, and
/// the first message of a connection has to be that token. It works once: the
/// first connection that says it has the channel to itself, and nothing that
/// connects afterwards is heard, even after that connection is gone. A new
/// share makes a new channel.
public struct MediaChannelGate {
    public enum Verdict: Equatable {
        /// The connection is the page's: captured media may go to it.
        case accept
        /// Close it.
        case refuse
    }

    public let token: String
    /// The connection the token was spent on, while it is open.
    public private(set) var client: Int?
    private var isSpent = false

    /// How long a connection may stay silent before it is closed.
    public static let timeToSpeak: TimeInterval = 5
    /// How much may wait to be sent before the next message is dropped: the
    /// page reads too slowly, and old frames are worth nothing.
    public static let mostBytesWaiting = 4 * 1024 * 1024

    public init(token: String = MediaChannelGate.newToken()) {
        self.token = token
    }

    /// 32 random bytes, in hexadecimal.
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// Whether a handshake from this origin is let through to say its token.
    /// A page of another origin has no business here, and a program that is
    /// not a browser sends no origin at all.
    public static func isOriginAllowed(_ origin: String?, page: String?) -> Bool {
        guard let page else { return true }
        return origin == page
    }

    /// The first message of a connection. `text` is nil when it was not text.
    public mutating func firstMessage(from connection: Int, text: String?) -> Verdict {
        guard !isSpent, let text, Self.isSame(text, token) else { return .refuse }
        isSpent = true
        client = connection
        return .accept
    }

    public mutating func closed(_ connection: Int) {
        if client == connection {
            client = nil
        }
    }

    /// Compares without stopping at the first difference, so that how long
    /// it takes says nothing about how much of a guess was right.
    static func isSame(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

extension LocalIdentity {
    /// Whether a TLS server is this identity's channel: the loopback address,
    /// the channel's port, and this very certificate and nothing else. It is
    /// the whole of the trust the certificate gets.
    public func isChannel(host: String, port: Int, certificateChain: [Data], channelPort: Int) -> Bool {
        host == Self.host && port == channelPort && certificateChain == [certificate]
    }
}
