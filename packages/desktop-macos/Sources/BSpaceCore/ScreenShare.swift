import Foundation

// The shell's own screen share: it joins the call as the user's stream
// participant and publishes the picture and the system's sound itself, with
// one hardware encode (plan section 12; docs/systems/voice.md, "The stream
// participant"). The page decides — which call, with which token, what to
// share and at what quality — and the shell does it. This file is what the
// two say to each other.

/// The codec a share is published in. Both are encoded in hardware on every
/// Mac the app runs on; nothing else is offered.
public enum ScreenShareCodec: String, Equatable {
    case h264
    case h265
}

/// What the page asks for when it starts a share from the shell.
///
/// `startNativeScreenShare({ url, token, sourceId, maxWidth, maxHeight,
/// frameRate, codec, maxBitrate, minBitrate, audio })`: the call's LiveKit
/// address and the stream token its server issued, the source by the id the
/// list gave it, and the quality the stream setup screen chose.
public struct ScreenShareRequest: Equatable {
    public var url: String
    public var token: String
    public var capture: ScreenCaptureRequest
    public var codec: ScreenShareCodec
    /// The bitrate ceiling and floor of the video, in bits a second. The
    /// floor is what the encoder is given even while the bandwidth estimate
    /// is lower; zero leaves it to WebRTC.
    public var maxBitrate: Int
    public var minBitrate: Int
    /// Whether the system's sound goes with the picture.
    public var audio: Bool

    public static let bitrateRange = 100_000...50_000_000
    public static let defaultMaxBitrate = 8_000_000
    /// Longer than any token a server issues, short enough to refuse rubbish.
    public static let longestToken = 8192

    /// Nil when the page named no call server, no token or no source the
    /// list could have given it. A quality that is missing or out of bounds
    /// is brought into them: the page asked for a share, and gets one.
    public init?(arguments: BridgeArguments) {
        guard let options = arguments.object(at: 0),
              let url = options["url"] as? String, Self.isCallServer(url),
              let token = options["token"] as? String, Self.isToken(token),
              let capture = ScreenCaptureRequest(arguments: arguments) else { return nil }
        self.url = url
        self.token = token
        self.capture = capture
        codec = (options["codec"] as? String).flatMap(ScreenShareCodec.init(rawValue:)) ?? .h264
        maxBitrate = Self.bitrate(options["maxBitrate"]) ?? Self.defaultMaxBitrate
        minBitrate = min(Self.floor(options["minBitrate"]) ?? 0, maxBitrate)
        audio = Self.flag(options["audio"]) ?? false
    }

    /// Whether `text` is an address the shell connects a share to: a secure
    /// WebSocket, or a plain one to this machine (a server run for
    /// development). Nothing with a user name or a password in it.
    public static func isCallServer(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        switch scheme {
        case "wss":
            return true
        case "ws":
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return bare == "localhost" || bare.hasSuffix(".localhost") || bare == "127.0.0.1" || bare == "::1"
        default:
            return false
        }
    }

    static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.count <= longestToken && !text.contains(where: \.isWhitespace)
    }

    static func bitrate(_ value: Any?) -> Int? {
        whole(value).map { min(max($0, bitrateRange.lowerBound), bitrateRange.upperBound) }
    }

    /// A floor has no lower bound of its own: zero is "none".
    static func floor(_ value: Any?) -> Int? {
        whole(value).map { min(max($0, 0), bitrateRange.upperBound) }
    }

    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func whole(_ value: Any?) -> Int? {
        // A JavaScript number; a boolean is not one.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return Int(min(max(double.rounded(), -1e15), 1e15))
    }
}

/// What a change to a running share touches.
public struct ScreenShareChanges: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Another source, size or frame rate: the capture starts again and its
    /// frames go on into the same track.
    public static let capture = ScreenShareChanges(rawValue: 1 << 0)
    /// Another bitrate or frame rate ceiling: the published track is given
    /// a new encoding.
    public static let encoding = ScreenShareChanges(rawValue: 1 << 1)
    /// The system's sound turned on or off.
    public static let audio = ScreenShareChanges(rawValue: 1 << 2)
}

/// What the page changes about a share that runs.
///
/// `updateNativeScreenShare({ sourceId?, maxWidth?, maxHeight?, frameRate?,
/// maxBitrate?, minBitrate?, audio? })`: only what is named changes. The
/// call and the token are the share's for its whole life, and the codec is
/// decided when it is published: a page that wants another one stops the
/// share and starts it again.
public struct ScreenShareUpdate: Equatable {
    public var source: ScreenSource.Kind?
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var framesPerSecond: Int?
    public var maxBitrate: Int?
    public var minBitrate: Int?
    public var audio: Bool?

    /// Nil when nothing that can change is named, or a source is named that
    /// the list could not have given.
    public init?(arguments: BridgeArguments) {
        guard let options = arguments.object(at: 0) else { return nil }
        if let id = options["sourceId"] {
            guard let text = id as? String, let kind = ScreenSource.kind(ofID: text) else { return nil }
            source = kind
        }
        let bounds = ScreenCaptureRequest.self
        maxWidth = Self.whole(options["maxWidth"], in: bounds.sizeRange)
        maxHeight = Self.whole(options["maxHeight"], in: bounds.sizeRange)
        framesPerSecond = Self.whole(options["frameRate"], in: bounds.frameRateRange)
        maxBitrate = ScreenShareRequest.bitrate(options["maxBitrate"])
        minBitrate = ScreenShareRequest.floor(options["minBitrate"])
        audio = ScreenShareRequest.flag(options["audio"])
        if source == nil, maxWidth == nil, maxHeight == nil, framesPerSecond == nil,
           maxBitrate == nil, minBitrate == nil, audio == nil { return nil }
    }

    /// The share as it is after the update, and what has to be done for it.
    public func applied(to request: ScreenShareRequest) -> (request: ScreenShareRequest, changes: ScreenShareChanges) {
        var next = request
        if let source { next.capture.source = source }
        if let maxWidth { next.capture.maxWidth = maxWidth }
        if let maxHeight { next.capture.maxHeight = maxHeight }
        if let framesPerSecond { next.capture.framesPerSecond = framesPerSecond }
        if let maxBitrate { next.maxBitrate = maxBitrate }
        if let minBitrate { next.minBitrate = minBitrate }
        next.minBitrate = min(next.minBitrate, next.maxBitrate)
        if let audio { next.audio = audio }

        var changes: ScreenShareChanges = []
        if next.capture != request.capture { changes.insert(.capture) }
        if next.maxBitrate != request.maxBitrate || next.minBitrate != request.minBitrate
            || next.capture.framesPerSecond != request.capture.framesPerSecond { changes.insert(.encoding) }
        if next.audio != request.audio { changes.insert(.audio) }
        return (next, changes)
    }

    private static func whole(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return min(max(Int(min(max(double.rounded(), -1e9), 1e9)), range.lowerBound), range.upperBound)
    }
}

/// Why a share did not start, or a change to it was not made, as the page
/// is told.
public enum ScreenShareFailure: String, Error, Equatable {
    /// The request named no call server, no token or no source.
    case badRequest = "bad-request"
    /// The app may not record the screen. The system has been asked.
    case noPermission = "no-permission"
    /// The display or window is gone.
    case noSource = "no-source"
    /// This shell does not publish shares: nothing makes publishers for it.
    case unsupported
    /// A share already runs in this window, or one is starting.
    case busy
    /// The call server did not let the stream participant in.
    case connectFailed = "connect-failed"
    /// It was let in, and the track was not published.
    case publishFailed = "publish-failed"
    /// No share runs to be changed.
    case notRunning = "not-running"
    /// The capture would not start, or something else went wrong.
    case failed

    /// A capture's refusal, as a share's.
    public init(_ capture: ScreenCaptureFailure) {
        switch capture {
        case .badRequest: self = .badRequest
        case .noPermission: self = .noPermission
        case .noSource: self = .noSource
        case .unsupported: self = .unsupported
        case .tooMany, .failed: self = .failed
        }
    }
}

/// What the page is told when it starts or changes a share.
public enum ScreenShareReply: Equatable {
    /// The share runs, with video of this size and rate.
    case running(width: Int, height: Int, framesPerSecond: Int)
    case refused(ScreenShareFailure)

    public var bridgeValue: [String: Any] {
        switch self {
        case .running(let width, let height, let framesPerSecond):
            return ["ok": true, "width": width, "height": height, "frameRate": framesPerSecond]
        case .refused(let failure):
            return ["ok": false, "reason": failure.rawValue]
        }
    }
}

/// Why a share ended without the page stopping it.
public enum ScreenShareEndReason: String, Equatable {
    /// The window was closed, the display unplugged, the permission taken away.
    case sourceEnded = "source-ended"
    /// The connection to the call was lost and did not come back.
    case disconnected
    /// The capture or the publication failed while the share ran.
    case failed
}

/// What the connection panel shows of a share the shell publishes.
public struct ScreenShareStats: Equatable {
    /// Bits a second sent, video and sound apart.
    public var bitrate: Int
    public var framesPerSecond: Double
    public var width: Int
    public var height: Int
    /// As WebRTC names them: `video/H265`, `VideoToolbox`.
    public var codec: String
    public var encoder: String
    public var hardware: Bool
    public var roundTripMilliseconds: Double?
    /// What the bandwidth estimate leaves for sending, bits a second.
    public var availableBitrate: Int?
    /// `none`, `cpu`, `bandwidth` or `other`, as WebRTC says.
    public var limitedBy: String?
    public var audioBitrate: Int?

    public init(
        bitrate: Int, framesPerSecond: Double, width: Int, height: Int, codec: String, encoder: String, hardware: Bool,
        roundTripMilliseconds: Double?, availableBitrate: Int?, limitedBy: String?, audioBitrate: Int?
    ) {
        self.bitrate = bitrate
        self.framesPerSecond = framesPerSecond
        self.width = width
        self.height = height
        self.codec = codec
        self.encoder = encoder
        self.hardware = hardware
        self.roundTripMilliseconds = roundTripMilliseconds
        self.availableBitrate = availableBitrate
        self.limitedBy = limitedBy
        self.audioBitrate = audioBitrate
    }
}

/// What the shell tells the page about a share that runs
/// (`onNativeScreenShareEvent`).
public enum ScreenShareEvent: Equatable {
    /// The share is over; the page did not stop it.
    case ended(ScreenShareEndReason)
    /// The connection to the call is being restored; the share is kept.
    case reconnecting
    case reconnected
    /// The shared window has another size, and the video follows it.
    case resized(width: Int, height: Int)
    /// The system's sound ended by itself; the picture goes on.
    case audioEnded
    case stats(ScreenShareStats)

    public var bridgeValue: [String: Any] {
        switch self {
        case .ended(let reason):
            return ["type": "ended", "reason": reason.rawValue]
        case .reconnecting:
            return ["type": "reconnecting"]
        case .reconnected:
            return ["type": "reconnected"]
        case .resized(let width, let height):
            return ["type": "resized", "width": width, "height": height]
        case .audioEnded:
            return ["type": "audio-ended"]
        case .stats(let stats):
            var value: [String: Any] = [
                "type": "stats", "bitrate": stats.bitrate, "frameRate": stats.framesPerSecond,
                "width": stats.width, "height": stats.height, "codec": stats.codec,
                "encoder": stats.encoder, "hardware": stats.hardware,
            ]
            if let roundTrip = stats.roundTripMilliseconds { value["roundTripMs"] = roundTrip }
            if let available = stats.availableBitrate { value["availableBitrate"] = available }
            if let limitedBy = stats.limitedBy { value["limitedBy"] = limitedBy }
            if let audio = stats.audioBitrate { value["audioBitrate"] = audio }
            return value
        }
    }
}

/// Turns a counter of bytes sent, read now and then, into bits a second.
public struct BitrateMeter {
    private var last: (bytes: UInt64, at: TimeInterval)?

    public init() {}

    /// The rate since the reading before, zero for the first reading, for
    /// two readings at one moment, and for a counter that started again (a
    /// track published anew).
    public mutating func rate(bytes: UInt64, at moment: TimeInterval) -> Int {
        defer { last = (bytes, moment) }
        guard let last, moment > last.at, bytes >= last.bytes else { return 0 }
        return Int((Double(bytes - last.bytes) * 8 / (moment - last.at)).rounded())
    }
}
