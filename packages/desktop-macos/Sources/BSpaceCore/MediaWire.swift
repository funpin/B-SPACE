import Foundation

/// What travels on a local media channel, from the shell to the page.
///
/// Text messages are JSON and say what is coming: the format of the video
/// before its first frame and whenever it changes, the format of the sound
/// when the page connects. Binary messages are the media itself, each with
/// a nine-byte header:
///
///     byte 0      what it is (`Kind`)
///     bytes 1-8   when it was captured: milliseconds since 1970 as a
///                 little-endian IEEE 754 double, the page's `Date.now()` clock
///     the rest    the payload
///
/// A video payload is one H.264 access unit in the form VideoToolbox makes
/// and WebCodecs reads when it is given a description: each NAL unit behind
/// its length in four bytes. A sound payload is samples as 32-bit
/// little-endian floats, frame after frame, each channel's sample in turn.
public enum MediaWire {
    public enum Kind: UInt8 {
        /// A frame that can be decoded on its own.
        case videoKeyFrame = 1
        /// A frame that needs the ones before it.
        case videoDeltaFrame = 2
        /// Samples of sound.
        case audio = 3
    }

    public static let headerLength = 9

    public static func message(kind: Kind, capturedAt milliseconds: Double, payload: Data) -> Data {
        var message = Data(capacity: headerLength + payload.count)
        message.append(kind.rawValue)
        withUnsafeBytes(of: milliseconds.bitPattern.littleEndian) { message.append(contentsOf: $0) }
        message.append(payload)
        return message
    }

    /// The format of the video that follows, as the page's decoder wants it.
    public struct VideoFormat: Equatable {
        /// The codec as WebCodecs names it: `avc1.` and the profile,
        /// constraints and level of the stream in hexadecimal.
        public let codec: String
        public let width: Int
        public let height: Int
        /// The decoder configuration record (`avcC`): the parameter sets.
        public let description: Data

        /// Nil when the record is too short to be one.
        public init?(decoderConfiguration: Data, width: Int, height: Int) {
            // version, profile, constraints, level.
            guard decoderConfiguration.count >= 4, decoderConfiguration.first == 1 else { return nil }
            let bytes = [UInt8](decoderConfiguration.prefix(4))
            codec = String(format: "avc1.%02x%02x%02x", bytes[1], bytes[2], bytes[3])
            self.width = width
            self.height = height
            description = decoderConfiguration
        }

        /// The text message that announces it.
        public var message: String {
            let object: [String: Any] = [
                "type": "video",
                "codec": codec,
                "width": width,
                "height": height,
                "description": description.base64EncodedString(),
            ]
            // The object holds strings and whole numbers only.
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The format of the sound that follows.
    public struct AudioFormat: Equatable {
        /// Frames a second.
        public let sampleRate: Int
        public let channels: Int

        public init(sampleRate: Int, channels: Int) {
            self.sampleRate = sampleRate
            self.channels = channels
        }

        /// The text message that announces it.
        public var message: String {
            #"{"channels":\#(channels),"sampleRate":\#(sampleRate),"type":"audio"}"#
        }
    }

    /// What the page may say on the channel after its token.
    public enum Request: Equatable {
        /// The decoder lost its place: the next frame should be a key frame.
        case keyFrame

        public init?(message: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                  object["type"] as? String == "keyframe" else { return nil }
            self = .keyFrame
        }
    }
}

/// How large and how heavy the video of a share is.
public enum VideoShape {
    /// The size to encode something `width` by `height` pixels at, when the
    /// user asked for no more than `maxWidth` by `maxHeight`: the proportions
    /// are kept, nothing is enlarged, and both sides are even, as the encoder
    /// requires.
    public static func encodedSize(
        width: Int, height: Int, maxWidth: Int, maxHeight: Int
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxWidth > 0, maxHeight > 0 else { return (2, 2) }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height), 1)
        func even(_ value: Double) -> Int {
            max(2, Int(value.rounded(.down)) & ~1)
        }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// The bitrate of the local stream. The page decodes it and the browser
    /// encodes it again for the call, so this one is kept well above what
    /// the call will carry: its losses would be paid twice. About 0.12 bits a
    /// pixel, between 4 and 60 megabits a second.
    public static func bitsPerSecond(width: Int, height: Int, framesPerSecond: Int) -> Int {
        let wanted = Double(width * height * framesPerSecond) * 0.12
        return Int(min(max(wanted, 4_000_000), 60_000_000))
    }
}
