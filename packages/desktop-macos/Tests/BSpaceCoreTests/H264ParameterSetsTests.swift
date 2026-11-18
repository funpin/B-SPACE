import Foundation
import Testing
@testable import BSpaceCore

private func bytes(_ hex: String) -> Data {
    var out = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

/// Decoder configuration records the hardware encoder of macOS 27.2 made,
/// asked for the High profile with no frame reordering.
private let hardwareRecords: [(width: Int, height: Int, level: UInt8, record: String)] = [
    (1920, 1080, 42, "0164002affe1000c2764002aac5680780227e54001000428ee3cb0fdf8f800"),
    (2560, 1440, 51, "01640033ffe1000b27640033ac56802800b59001000428ee3cb0fdf8f800"),
    (3024, 1964, 52, "01640034ffe1000c27640034ac56802f40f7fb4001000428ee3cb0fdf8f800"),
    (1670, 1080, 42, "0164002affe1000c2764002aac56806902279a5401000428ee3cb0fdf8f800"),
]

/// A parameter set as x264 writes one for 1920 by 1080: with usability
/// information, a restriction that allows reordering, and two places where a
/// byte is escaped.
private let softwareSet = "6764002aacd940780227e5c044000003000400000300f03c60c658"

@Suite struct H264ParameterSetsTests {
    @Test func readsWhatTheHardwareEncoderWrites() throws {
        for sample in hardwareRecords {
            let set = try H264ParameterSets.sequenceParameterSet(ofDecoderConfiguration: bytes(sample.record))
            let summary = try H264ParameterSets.summary(sequenceParameterSet: set)
            #expect(summary.profile == 100)
            #expect(summary.level == sample.level)
            #expect(summary.width == sample.width)
            #expect(summary.height == sample.height)
            // The encoder does not say whether it reorders frames: the reason
            // for all of this.
            #expect(summary.reorderFrames == nil)
            #expect(summary.referenceFrames >= 1)
        }
    }

    @Test func theRewrittenRecordSaysFramesComeInOrder() throws {
        for sample in hardwareRecords {
            let record = bytes(sample.record)
            let rewritten = try H264ParameterSets.withoutReordering(decoderConfiguration: record)
            let before = try H264ParameterSets.summary(
                sequenceParameterSet: H264ParameterSets.sequenceParameterSet(ofDecoderConfiguration: record)
            )
            let after = try H264ParameterSets.summary(
                sequenceParameterSet: H264ParameterSets.sequenceParameterSet(ofDecoderConfiguration: rewritten)
            )
            #expect(after.reorderFrames == 0)
            var expected = before
            expected.reorderFrames = 0
            #expect(after == expected)
            // The head of the record and everything after the sequence
            // parameter set are untouched.
            #expect(rewritten.prefix(6) == record.prefix(6))
            #expect(rewritten.suffix(11) == record.suffix(11))
            // What MediaWire names the codec from still stands.
            #expect(MediaWire.VideoFormat(decoderConfiguration: rewritten, width: 2, height: 2)?.codec
                == MediaWire.VideoFormat(decoderConfiguration: record, width: 2, height: 2)?.codec)
        }
    }

    @Test func rewritingTwiceChangesNothingMore() throws {
        for sample in hardwareRecords {
            let once = try H264ParameterSets.withoutReordering(decoderConfiguration: bytes(sample.record))
            #expect(try H264ParameterSets.withoutReordering(decoderConfiguration: once) == once)
        }
    }

    @Test func aSetThatAllowsReorderingIsToldNotTo() throws {
        let set = bytes(softwareSet)
        let before = try H264ParameterSets.summary(sequenceParameterSet: set)
        #expect(before.profile == 100)
        #expect(before.level == 42)
        #expect(before.width == 1920)
        #expect(before.height == 1080)
        let reorder = try #require(before.reorderFrames)
        #expect(reorder > 0)

        let rewritten = try H264ParameterSets.withoutReordering(sequenceParameterSet: set)
        let after = try H264ParameterSets.summary(sequenceParameterSet: rewritten)
        var expected = before
        expected.reorderFrames = 0
        #expect(after == expected)
        #expect(try H264ParameterSets.withoutReordering(sequenceParameterSet: rewritten) == rewritten)
    }

    @Test func aRewrittenSetNeverLooksLikeAStartCode() throws {
        for sample in hardwareRecords {
            let rewritten = try H264ParameterSets.withoutReordering(decoderConfiguration: bytes(sample.record))
            let set = [UInt8](try H264ParameterSets.sequenceParameterSet(ofDecoderConfiguration: rewritten))
            for index in 0..<(set.count - 2) where set[index] == 0 && set[index + 1] == 0 {
                #expect(set[index + 2] == 3, "two zero bytes are followed by \(set[index + 2])")
            }
        }
    }

    @Test func escapingIsUndoneByUnescaping() {
        let cases: [[UInt8]] = [
            [0, 0, 0], [0, 0, 1], [0, 0, 2], [0, 0, 3], [0, 0, 4], [1, 0, 0, 0, 0, 0, 1], [0, 0], [], [0, 0, 3, 0, 0, 3],
        ]
        for plain in cases {
            let escaped = H264ParameterSets.escaped(plain)
            #expect(H264ParameterSets.unescaped(escaped) == plain)
        }
        #expect(H264ParameterSets.escaped([0, 0, 1]) == [0, 0, 3, 1])
        #expect(H264ParameterSets.escaped([0, 0, 4]) == [0, 0, 4])
        #expect(H264ParameterSets.unescaped([0, 0, 3, 1, 0, 0, 3, 0]) == [0, 0, 1, 0, 0, 0])
    }

    @Test func numbersSurviveTheBitCodes() throws {
        var writer = H264ParameterSets.BitWriter()
        let numbers: [UInt32] = [0, 1, 2, 3, 6, 7, 16, 255, 65_535, 1_000_000]
        for number in numbers {
            writer.writeExpGolomb(number)
        }
        writer.write(0b101, bits: 3)
        writer.finish()
        var reader = H264ParameterSets.BitReader(writer.bytes)
        for number in numbers {
            #expect(try reader.readExpGolomb() == number)
        }
        #expect(try reader.read(bits: 3) == 0b101)
        // The stop bit.
        #expect(try reader.read(bits: 1) == 1)
    }

    @Test func whatIsNotAParameterSetIsRefused() {
        #expect(throws: H264ParameterSets.Malformed.self) {
            try H264ParameterSets.withoutReordering(decoderConfiguration: Data())
        }
        #expect(throws: H264ParameterSets.Malformed.self) {
            try H264ParameterSets.withoutReordering(decoderConfiguration: bytes("0164002affe1000c2764002a"))
        }
        // A picture parameter set (type 8) is not a sequence parameter set.
        #expect(throws: H264ParameterSets.Malformed.self) {
            try H264ParameterSets.withoutReordering(sequenceParameterSet: bytes("28ee3cb0aabb"))
        }
        // Cut off in the middle.
        #expect(throws: H264ParameterSets.Malformed.self) {
            try H264ParameterSets.summary(sequenceParameterSet: bytes("2764002aac56"))
        }
    }
}
