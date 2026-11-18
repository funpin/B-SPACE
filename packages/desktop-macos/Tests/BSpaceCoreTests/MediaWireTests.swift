import Foundation
import Testing
@testable import BSpaceCore

@Suite struct MediaWireTests {
    @Test func aMessageIsItsKindItsTimeAndItsPayload() {
        let message = MediaWire.message(kind: .videoKeyFrame, capturedAt: 1_795_000_000_123.5, payload: Data([9, 8, 7]))
        #expect(message.count == MediaWire.headerLength + 3)
        #expect(message[0] == 1)
        // The page reads the time with DataView.getFloat64(1, true).
        let bits = message[1..<9].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        #expect(Double(bitPattern: bits) == 1_795_000_000_123.5)
        #expect([UInt8](message[9...]) == [9, 8, 7])
        #expect(MediaWire.message(kind: .videoDeltaFrame, capturedAt: 0, payload: Data())[0] == 2)
    }

    @Test func theCodecIsNamedFromTheDecoderConfiguration() throws {
        // High profile, no constraints, level 5.1; the rest is the parameter sets.
        let record = Data([0x01, 0x64, 0x00, 0x33, 0xff, 0xe1, 0x00, 0x00])
        let format = try #require(MediaWire.VideoFormat(decoderConfiguration: record, width: 2560, height: 1440))
        #expect(format.codec == "avc1.640033")
        #expect(format.description == record)
        let baseline = Data([0x01, 0x42, 0xe0, 0x1f])
        #expect(MediaWire.VideoFormat(decoderConfiguration: baseline, width: 2, height: 2)?.codec == "avc1.42e01f")
    }

    @Test func whatIsNotADecoderConfigurationHasNoFormat() {
        #expect(MediaWire.VideoFormat(decoderConfiguration: Data(), width: 2, height: 2) == nil)
        #expect(MediaWire.VideoFormat(decoderConfiguration: Data([0x01, 0x64, 0x00]), width: 2, height: 2) == nil)
        // The record's version is 1.
        #expect(MediaWire.VideoFormat(decoderConfiguration: Data([0x00, 0x64, 0x00, 0x33]), width: 2, height: 2) == nil)
    }

    @Test func theFormatIsAnnouncedAsJSON() throws {
        let format = try #require(
            MediaWire.VideoFormat(decoderConfiguration: Data([0x01, 0x64, 0x00, 0x28]), width: 1920, height: 1080)
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(format.message.utf8)) as? [String: Any]
        )
        #expect(object["type"] as? String == "video")
        #expect(object["codec"] as? String == "avc1.640028")
        #expect(object["width"] as? Int == 1920)
        #expect(object["height"] as? Int == 1080)
        #expect(object["description"] as? String == "AWQAKA==")
        #expect(object.count == 5)
    }

    @Test func thePageMayAskForAKeyFrame() {
        #expect(MediaWire.Request(message: Data(#"{"type":"keyframe"}"#.utf8)) == .keyFrame)
        #expect(MediaWire.Request(message: Data(#"{"type":"anything"}"#.utf8)) == nil)
        #expect(MediaWire.Request(message: Data(#"["keyframe"]"#.utf8)) == nil)
        #expect(MediaWire.Request(message: Data([0, 1, 2])) == nil)
        #expect(MediaWire.Request(message: Data()) == nil)
    }
}

@Suite struct VideoShapeTests {
    @Test func aSourceIsFittedIntoWhatWasAskedFor() {
        // A 16:10 display into 1080p: the height decides.
        #expect(VideoShape.encodedSize(width: 3456, height: 2234, maxWidth: 1920, maxHeight: 1080) == (1670, 1080))
        // 16:9 into 1440p.
        #expect(VideoShape.encodedSize(width: 3840, height: 2160, maxWidth: 2560, maxHeight: 1440) == (2560, 1440))
        // A tall window: the height decides again.
        #expect(VideoShape.encodedSize(width: 800, height: 2400, maxWidth: 1920, maxHeight: 1080) == (360, 1080))
    }

    @Test func nothingIsEnlargedAndBothSidesAreEven() {
        #expect(VideoShape.encodedSize(width: 1281, height: 721, maxWidth: 1920, maxHeight: 1080) == (1280, 720))
        #expect(VideoShape.encodedSize(width: 3024, height: 1964, maxWidth: 8192, maxHeight: 8192) == (3024, 1964))
        #expect(VideoShape.encodedSize(width: 3, height: 1, maxWidth: 1920, maxHeight: 1080) == (2, 2))
        #expect(VideoShape.encodedSize(width: 0, height: 0, maxWidth: 1920, maxHeight: 1080) == (2, 2))
    }

    @Test func theBitrateFollowsTheSizeWithinItsBounds() {
        #expect(VideoShape.bitsPerSecond(width: 1920, height: 1080, framesPerSecond: 60) == 14_929_920)
        #expect(VideoShape.bitsPerSecond(width: 2560, height: 1440, framesPerSecond: 60) == 26_542_080)
        #expect(VideoShape.bitsPerSecond(width: 3024, height: 1964, framesPerSecond: 60) == 42_761_779)
        #expect(VideoShape.bitsPerSecond(width: 640, height: 360, framesPerSecond: 15) == 4_000_000)
        #expect(VideoShape.bitsPerSecond(width: 7680, height: 4320, framesPerSecond: 60) == 60_000_000)
    }
}
