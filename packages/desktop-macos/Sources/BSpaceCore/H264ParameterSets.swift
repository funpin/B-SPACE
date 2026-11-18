import Foundation

/// Tells a decoder that the frames of an H.264 stream come in the order they
/// are shown.
///
/// The hardware encoder is told not to reorder frames and does not, but it
/// does not say so in the stream. A decoder that is not told has to assume
/// the worst the level allows and holds that many frames before it shows the
/// first: WebKit's held 4 at 1080p, 12 at 1440p and 7 at 3024 by 1964, a
/// fifth of a second at sixty frames a second. The place to say it is the
/// sequence parameter set: `bitstream_restriction_flag` with
/// `max_num_reorder_frames` of zero. This rewrites the parameter set the
/// encoder made so that it says that and changes nothing else.
public enum H264ParameterSets {
    public struct Malformed: Error, Equatable {}

    /// What a sequence parameter set says, as far as the shell cares.
    public struct Summary: Equatable {
        public var profile: UInt8
        public var level: UInt8
        public var width: Int
        public var height: Int
        public var referenceFrames: Int
        /// How many frames a decoder may have to hold before showing one;
        /// nil when the stream does not say.
        public var reorderFrames: Int?
    }

    /// The decoder configuration record (`avcC`) with every sequence
    /// parameter set in it rewritten by `withoutReordering(sequenceParameterSet:)`.
    public static func withoutReordering(decoderConfiguration record: Data) throws -> Data {
        let bytes = [UInt8](record)
        // version, profile, constraints, level, NAL length size, count.
        guard bytes.count >= 7, bytes[0] == 1 else { throw Malformed() }
        var out = Array(bytes[0..<6])
        var position = 6
        for _ in 0..<Int(bytes[5] & 0x1f) {
            guard position + 2 <= bytes.count else { throw Malformed() }
            let length = Int(bytes[position]) << 8 | Int(bytes[position + 1])
            position += 2
            guard length > 0, position + length <= bytes.count else { throw Malformed() }
            let rewritten = try withoutReordering(
                sequenceParameterSet: Data(bytes[position..<(position + length)])
            )
            guard rewritten.count <= 0xffff else { throw Malformed() }
            out.append(UInt8(rewritten.count >> 8))
            out.append(UInt8(rewritten.count & 0xff))
            out.append(contentsOf: rewritten)
            position += length
        }
        // The picture parameter sets and whatever follows are kept as they are.
        out.append(contentsOf: bytes[position...])
        return Data(out)
    }

    /// One sequence parameter set, as a NAL unit with its header byte, saying
    /// that no frame is shown before an earlier-decoded one.
    public static func withoutReordering(sequenceParameterSet unit: Data) throws -> Data {
        let (reader, layout) = try parse(unit)
        var writer = BitWriter()
        // Everything up to the flag that says whether usability information
        // follows is copied bit for bit.
        writer.copy(from: reader.bytes, bits: layout.usabilityFlagPosition)
        writer.write(1, bits: 1)
        if let restrictionFlagPosition = layout.restrictionFlagPosition {
            writer.copy(from: reader.bytes, startingAt: layout.usabilityFlagPosition + 1, bits: restrictionFlagPosition - layout.usabilityFlagPosition - 1)
        } else {
            // No usability information at all: an empty one. Eight flags
            // that say "absent" come before the restriction.
            writer.write(0, bits: 8)
        }
        writer.write(1, bits: 1)
        let restriction = layout.restriction
        writer.write(restriction?.motionVectorsOverPictureBoundaries ?? 1, bits: 1)
        writer.writeExpGolomb(restriction?.maxBytesPerPictureDenominator ?? 0)
        writer.writeExpGolomb(restriction?.maxBitsPerMacroblockDenominator ?? 0)
        writer.writeExpGolomb(restriction?.log2MaxMotionVectorLengthHorizontal ?? 16)
        writer.writeExpGolomb(restriction?.log2MaxMotionVectorLengthVertical ?? 16)
        // max_num_reorder_frames
        writer.writeExpGolomb(0)
        // max_dec_frame_buffering: what the stream refers back to, no more.
        writer.writeExpGolomb(UInt32(max(layout.summary.referenceFrames, 1)))
        writer.finish()
        return Data([unit[unit.startIndex]] + escaped(writer.bytes))
    }

    /// What a sequence parameter set (a NAL unit with its header byte) says.
    public static func summary(sequenceParameterSet unit: Data) throws -> Summary {
        try parse(unit).1.summary
    }

    /// The first sequence parameter set of a decoder configuration record.
    public static func sequenceParameterSet(ofDecoderConfiguration record: Data) throws -> Data {
        let bytes = [UInt8](record)
        guard bytes.count >= 8, bytes[0] == 1, bytes[5] & 0x1f >= 1 else { throw Malformed() }
        let length = Int(bytes[6]) << 8 | Int(bytes[7])
        guard length > 0, 8 + length <= bytes.count else { throw Malformed() }
        return Data(bytes[8..<(8 + length)])
    }

    // MARK: Reading

    private struct Restriction {
        var motionVectorsOverPictureBoundaries: UInt32
        var maxBytesPerPictureDenominator: UInt32
        var maxBitsPerMacroblockDenominator: UInt32
        var log2MaxMotionVectorLengthHorizontal: UInt32
        var log2MaxMotionVectorLengthVertical: UInt32
    }

    private struct Layout {
        var summary: Summary
        /// The bit at which `vui_parameters_present_flag` stands.
        var usabilityFlagPosition: Int
        /// The bit at which `bitstream_restriction_flag` stands, when there
        /// is usability information.
        var restrictionFlagPosition: Int?
        var restriction: Restriction?
    }

    private static func parse(_ unit: Data) throws -> (BitReader, Layout) {
        // The header byte says it is a sequence parameter set: type 7.
        guard unit.count > 4, unit[unit.startIndex] & 0x1f == 7 else { throw Malformed() }
        var reader = BitReader(unescaped([UInt8](unit.dropFirst())))

        let profile = UInt8(try reader.read(bits: 8))
        _ = try reader.read(bits: 8)
        let level = UInt8(try reader.read(bits: 8))
        _ = try reader.readExpGolomb()

        var chromaFormat: UInt32 = 1
        var separateColourPlanes = false
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chromaFormat = try reader.readExpGolomb()
            if chromaFormat == 3 {
                separateColourPlanes = try reader.read(bits: 1) == 1
            }
            _ = try reader.readExpGolomb()
            _ = try reader.readExpGolomb()
            _ = try reader.read(bits: 1)
            if try reader.read(bits: 1) == 1 {
                for index in 0..<(chromaFormat != 3 ? 8 : 12) where try reader.read(bits: 1) == 1 {
                    try skipScalingList(&reader, size: index < 6 ? 16 : 64)
                }
            }
        }
        _ = try reader.readExpGolomb()
        let orderCountType = try reader.readExpGolomb()
        if orderCountType == 0 {
            _ = try reader.readExpGolomb()
        } else if orderCountType == 1 {
            _ = try reader.read(bits: 1)
            _ = try reader.readSignedExpGolomb()
            _ = try reader.readSignedExpGolomb()
            let cycle = try reader.readExpGolomb()
            guard cycle <= 255 else { throw Malformed() }
            for _ in 0..<cycle {
                _ = try reader.readSignedExpGolomb()
            }
        }
        let referenceFrames = try reader.readExpGolomb()
        _ = try reader.read(bits: 1)
        let widthInMacroblocks = try reader.readExpGolomb() + 1
        let heightInMapUnits = try reader.readExpGolomb() + 1
        let frameMacroblocksOnly = try reader.read(bits: 1)
        if frameMacroblocksOnly == 0 {
            _ = try reader.read(bits: 1)
        }
        _ = try reader.read(bits: 1)
        var crop: (left: UInt32, right: UInt32, top: UInt32, bottom: UInt32) = (0, 0, 0, 0)
        if try reader.read(bits: 1) == 1 {
            crop = (try reader.readExpGolomb(), try reader.readExpGolomb(), try reader.readExpGolomb(), try reader.readExpGolomb())
        }
        guard widthInMacroblocks < 4096, heightInMapUnits < 4096, referenceFrames <= 16 else { throw Malformed() }

        // Cropping is counted in chroma samples.
        let chromaArray = separateColourPlanes ? 0 : chromaFormat
        let cropUnitX: UInt32 = chromaArray == 1 || chromaArray == 2 ? 2 : 1
        let cropUnitY: UInt32 = (chromaArray == 1 ? 2 : 1) * (2 - frameMacroblocksOnly)
        let width = Int(widthInMacroblocks * 16) - Int((crop.left + crop.right) * cropUnitX)
        let height = Int(heightInMapUnits * 16 * (2 - frameMacroblocksOnly)) - Int((crop.top + crop.bottom) * cropUnitY)

        var layout = Layout(
            summary: Summary(
                profile: profile, level: level, width: width, height: height,
                referenceFrames: Int(referenceFrames), reorderFrames: nil
            ),
            usabilityFlagPosition: reader.position
        )
        guard try reader.read(bits: 1) == 1 else { return (reader, layout) }

        // Usability information: every part before the restriction is read
        // only to find where the restriction stands.
        if try reader.read(bits: 1) == 1, try reader.read(bits: 8) == 255 {
            _ = try reader.read(bits: 32)
        }
        if try reader.read(bits: 1) == 1 {
            _ = try reader.read(bits: 1)
        }
        if try reader.read(bits: 1) == 1 {
            _ = try reader.read(bits: 4)
            if try reader.read(bits: 1) == 1 {
                _ = try reader.read(bits: 24)
            }
        }
        if try reader.read(bits: 1) == 1 {
            _ = try reader.readExpGolomb()
            _ = try reader.readExpGolomb()
        }
        if try reader.read(bits: 1) == 1 {
            _ = try reader.read(bits: 32)
            _ = try reader.read(bits: 32)
            _ = try reader.read(bits: 1)
        }
        let hasNetworkBufferModel = try reader.read(bits: 1) == 1
        if hasNetworkBufferModel {
            try skipBufferModel(&reader)
        }
        let hasCodingBufferModel = try reader.read(bits: 1) == 1
        if hasCodingBufferModel {
            try skipBufferModel(&reader)
        }
        if hasNetworkBufferModel || hasCodingBufferModel {
            _ = try reader.read(bits: 1)
        }
        _ = try reader.read(bits: 1)

        layout.restrictionFlagPosition = reader.position
        if try reader.read(bits: 1) == 1 {
            let restriction = Restriction(
                motionVectorsOverPictureBoundaries: try reader.read(bits: 1),
                maxBytesPerPictureDenominator: try reader.readExpGolomb(),
                maxBitsPerMacroblockDenominator: try reader.readExpGolomb(),
                log2MaxMotionVectorLengthHorizontal: try reader.readExpGolomb(),
                log2MaxMotionVectorLengthVertical: try reader.readExpGolomb()
            )
            layout.restriction = restriction
            layout.summary.reorderFrames = Int(try reader.readExpGolomb())
            _ = try reader.readExpGolomb()
        }
        return (reader, layout)
    }

    private static func skipScalingList(_ reader: inout BitReader, size: Int) throws {
        var last: Int32 = 8
        var next: Int32 = 8
        for _ in 0..<size {
            if next != 0 {
                next = (last + (try reader.readSignedExpGolomb()) + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }

    /// The hypothetical reference decoder's parameters.
    private static func skipBufferModel(_ reader: inout BitReader) throws {
        let count = try reader.readExpGolomb() + 1
        guard count <= 32 else { throw Malformed() }
        _ = try reader.read(bits: 8)
        for _ in 0..<count {
            _ = try reader.readExpGolomb()
            _ = try reader.readExpGolomb()
            _ = try reader.read(bits: 1)
        }
        _ = try reader.read(bits: 20)
    }

    // MARK: Bytes and bits

    /// A NAL unit's payload without the bytes that keep it from looking like
    /// a start code: `00 00 03` stands for `00 00`.
    static func unescaped(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    /// The reverse: `03` goes in wherever two zero bytes are followed by a
    /// byte of 3 or less.
    static func escaped(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte <= 3 {
                out.append(3)
                zeros = 0
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    struct BitReader {
        let bytes: [UInt8]
        private(set) var position = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func read(bits count: Int) throws -> UInt32 {
            guard count <= 32, position + count <= bytes.count * 8 else { throw Malformed() }
            var value: UInt32 = 0
            for _ in 0..<count {
                let bit = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
                value = value << 1 | UInt32(bit)
                position += 1
            }
            return value
        }

        /// An unsigned number in the code H.264 calls ue(v).
        mutating func readExpGolomb() throws -> UInt32 {
            var zeros = 0
            while try read(bits: 1) == 0 {
                zeros += 1
                guard zeros < 32 else { throw Malformed() }
            }
            guard zeros > 0 else { return 0 }
            return (UInt32(1) << UInt32(zeros)) - 1 + (try read(bits: zeros))
        }

        /// A signed number, se(v).
        mutating func readSignedExpGolomb() throws -> Int32 {
            let code = try readExpGolomb()
            let magnitude = Int32((code + 1) / 2)
            return code % 2 == 1 ? magnitude : -magnitude
        }
    }

    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var used = 0

        mutating func write(_ value: UInt32, bits count: Int) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                if used == 0 {
                    bytes.append(0)
                }
                if (value >> UInt32(shift)) & 1 == 1 {
                    bytes[bytes.count - 1] |= 1 << UInt8(7 - used)
                }
                used = (used + 1) & 7
            }
        }

        mutating func writeExpGolomb(_ value: UInt32) {
            let code = UInt64(value) + 1
            let length = 64 - code.leadingZeroBitCount
            write(0, bits: length - 1)
            for shift in stride(from: length - 1, through: 0, by: -1) {
                write(UInt32((code >> UInt64(shift)) & 1), bits: 1)
            }
        }

        mutating func copy(from source: [UInt8], startingAt start: Int = 0, bits count: Int) {
            for position in start..<(start + count) {
                write(UInt32((source[position >> 3] >> (7 - UInt8(position & 7))) & 1), bits: 1)
            }
        }

        /// The stop bit, and zeros to the end of the byte.
        mutating func finish() {
            write(1, bits: 1)
            while used != 0 {
                write(0, bits: 1)
            }
        }
    }
}
