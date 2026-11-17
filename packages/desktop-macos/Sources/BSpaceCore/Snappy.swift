import Foundation

/// Snappy decompression, the raw block format (not the framed stream): what
/// LevelDB compresses its table blocks with. Decompression only; nothing in
/// the app writes Snappy.
public enum Snappy {
    public enum Failure: Error, Equatable {
        /// The input ends in the middle of an element.
        case truncated
        /// The declared length is over the limit, or the elements do not add
        /// up to it.
        case wrongLength
        /// A copy reaches back before the start of the output.
        case badOffset
    }

    /// - Parameter limit: the largest output accepted. A block declares its
    ///   own uncompressed length, and a damaged one must not be able to ask
    ///   for all the memory there is.
    public static func decompress(_ input: [UInt8], limit: Int = 1 << 28) throws -> [UInt8] {
        var position = 0

        var length = 0
        var shift = 0
        while true {
            guard position < input.count, shift <= 28 else { throw Failure.truncated }
            let byte = input[position]
            position += 1
            length |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        guard length <= limit else { throw Failure.wrongLength }

        var output: [UInt8] = []
        output.reserveCapacity(length)

        func littleEndian(_ count: Int) throws -> Int {
            guard position + count <= input.count else { throw Failure.truncated }
            var value = 0
            for index in 0..<count {
                value |= Int(input[position + index]) << (8 * index)
            }
            position += count
            return value
        }

        while position < input.count {
            let tag = input[position]
            position += 1

            if tag & 3 == 0 {
                // A literal: the bytes follow as they are.
                var count = Int(tag >> 2)
                if count >= 60 {
                    count = try littleEndian(count - 59)
                }
                count += 1
                guard position + count <= input.count else { throw Failure.truncated }
                guard output.count + count <= length else { throw Failure.wrongLength }
                output.append(contentsOf: input[position..<(position + count)])
                position += count
                continue
            }

            // A copy of bytes already written, `offset` back from the end.
            let count: Int
            let offset: Int
            switch tag & 3 {
            case 1:
                count = Int((tag >> 2) & 7) + 4
                offset = (Int(tag >> 5) << 8) | (try littleEndian(1))
            case 2:
                count = Int(tag >> 2) + 1
                offset = try littleEndian(2)
            default:
                count = Int(tag >> 2) + 1
                offset = try littleEndian(4)
            }
            guard offset > 0, offset <= output.count else { throw Failure.badOffset }
            guard output.count + count <= length else { throw Failure.wrongLength }
            // Byte by byte: a copy may overlap what it is writing (a run).
            var source = output.count - offset
            for _ in 0..<count {
                output.append(output[source])
                source += 1
            }
        }

        guard output.count == length else { throw Failure.wrongLength }
        return output
    }
}
