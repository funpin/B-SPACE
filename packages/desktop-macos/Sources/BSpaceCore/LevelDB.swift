import Foundation

/// CRC-32C (Castagnoli), the checksum LevelDB puts on every log record and
/// table block.
public enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0x82f6_3b78 : value >> 1
        }
        return value
    }

    public static func checksum<Bytes: Sequence>(_ bytes: Bytes, continuing previous: UInt32 = 0) -> UInt32 where Bytes.Element == UInt8 {
        var value = ~previous
        for byte in bytes {
            value = table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
        return ~value
    }

    /// The form LevelDB stores: rotated and offset, so that a checksum of
    /// data that itself contains checksums stays well distributed.
    public static func masked(_ checksum: UInt32) -> UInt32 {
        ((checksum >> 15) | (checksum << 17)) &+ 0xa282_ead8
    }
}

/// A read-only look into a LevelDB database directory, without the LevelDB
/// library: enough of the format to list what a database holds. It exists for
/// one job, reading `localStorage` out of the Electron build's Chromium
/// profile (`ChromiumLocalStorage`), and nothing here ever writes.
///
/// The database is a manifest naming the live table files, the tables
/// themselves, and a write-ahead log of what has not reached a table yet.
/// Every entry carries a sequence number, so the reader does not need the
/// level structure: among all entries for a key, the one with the highest
/// sequence number is the current one.
public enum LevelDB {
    public enum Failure: Error, Equatable {
        /// A file the database names is not in the directory.
        case missing(String)
        /// The bytes are not what the format says they should be.
        case damaged(String)
        /// Valid, but something this reader does not read.
        case unsupported(String)
    }

    /// Every key the database holds now, with its current value. Deleted keys
    /// are left out.
    public static func entries(in directory: URL) throws -> [Data: Data] {
        func read(_ name: String) throws -> [UInt8] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name, isDirectory: false)) else {
                throw Failure.missing(name)
            }
            return [UInt8](data)
        }

        let current = String(decoding: try read("CURRENT"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manifestNumber = current.dropFirst("MANIFEST-".count)
        guard
            current.hasPrefix("MANIFEST-"),
            !manifestNumber.isEmpty,
            manifestNumber.allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            throw Failure.damaged("CURRENT does not name a manifest")
        }
        let manifest = try Manifest(records: logRecords(try read(current), strict: true))

        var latest: [Data: (sequence: UInt64, value: Data?)] = [:]
        func note(_ key: Data, sequence: UInt64, value: Data?) {
            if let known = latest[key], known.sequence >= sequence { return }
            latest[key] = (sequence, value)
        }

        for number in manifest.tables.sorted() {
            let name = String(format: "%06llu.ldb", number)
            let bytes: [UInt8]
            do {
                bytes = try read(name)
            } catch {
                // What LevelDB called its tables before 1.14.
                guard let older = try? read(String(format: "%06llu.sst", number)) else { throw error }
                bytes = older
            }
            try forEachTableEntry(bytes, name: name) { internalKey, value in
                // An internal key is the user's key followed by eight bytes:
                // the sequence number above a one-byte entry type.
                guard internalKey.count >= 8 else { throw Failure.damaged("\(name): a key without its trailer") }
                let trailer = littleEndian(internalKey, at: internalKey.endIndex - 8, count: 8)
                let key = Data(internalKey.dropLast(8))
                switch trailer & 0xff {
                case 1: note(key, sequence: trailer >> 8, value: Data(value))
                case 0: note(key, sequence: trailer >> 8, value: nil)
                default: throw Failure.damaged("\(name): unknown entry type \(trailer & 0xff)")
                }
            }
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let logs = names
            .compactMap { name -> (number: UInt64, name: String)? in
                guard name.hasSuffix(".log"), let number = UInt64(name.dropLast(".log".count)) else { return nil }
                return (number, name)
            }
            .filter { $0.number >= manifest.logNumber || ($0.number == manifest.previousLogNumber && $0.number != 0) }
            .sorted { $0.number < $1.number }
        for log in logs {
            // A log can end in a record that was being written when the
            // process stopped: everything before it still counts.
            for record in try logRecords(try read(log.name), strict: false) {
                guard record.count >= 12 else { throw Failure.damaged("\(log.name): a batch without its header") }
                let sequence = littleEndian(record[...], at: 0, count: 8)
                let count = littleEndian(record[...], at: 8, count: 4)
                var cursor = ByteCursor(record[12...], context: log.name)
                for index in 0..<count {
                    let type = try cursor.byte()
                    let key = Data(try cursor.lengthPrefixed())
                    switch type {
                    case 1: note(key, sequence: sequence + index, value: Data(try cursor.lengthPrefixed()))
                    case 0: note(key, sequence: sequence + index, value: nil)
                    default: throw Failure.damaged("\(log.name): unknown entry type \(type)")
                    }
                }
            }
        }

        return latest.compactMapValues(\.value)
    }

    // MARK: Manifest

    /// What the manifest's edits add up to: the tables that are part of the
    /// database now, and the first log file that still holds anything.
    struct Manifest {
        private struct Table: Hashable {
            let level: UInt64
            let number: UInt64
        }

        var tables: Set<UInt64> = []
        var logNumber: UInt64 = 0
        var previousLogNumber: UInt64 = 0

        init(records: [[UInt8]]) throws {
            var live: Set<Table> = []
            for record in records {
                var cursor = ByteCursor(record[...], context: "manifest")
                var removed: [Table] = []
                var added: [Table] = []
                while !cursor.isAtEnd {
                    switch try cursor.varint() {
                    case 1: // comparator name
                        _ = try cursor.lengthPrefixed()
                    case 2:
                        logNumber = try cursor.varint()
                    case 9:
                        previousLogNumber = try cursor.varint()
                    case 3, 4: // next file number, last sequence
                        _ = try cursor.varint()
                    case 5: // compaction pointer
                        _ = try cursor.varint()
                        _ = try cursor.lengthPrefixed()
                    case 6:
                        let level = try cursor.varint()
                        removed.append(Table(level: level, number: try cursor.varint()))
                    case 7:
                        let level = try cursor.varint()
                        added.append(Table(level: level, number: try cursor.varint()))
                        _ = try cursor.varint() // file size
                        _ = try cursor.lengthPrefixed() // smallest key
                        _ = try cursor.lengthPrefixed() // largest key
                    case let tag:
                        throw Failure.damaged("manifest: unknown field \(tag)")
                    }
                }
                // A table moved to another level is removed and added in one
                // edit: removals first.
                live.subtract(removed)
                live.formUnion(added)
            }
            tables = Set(live.map(\.number))
        }
    }

    // MARK: Log files (the manifest and the write-ahead log share the format)

    private static let logBlockSize = 32768
    private static let logHeaderSize = 7

    /// The records of a log file. A record is cut into fragments so that none
    /// crosses a 32 KB block boundary; each fragment has its own checksum.
    ///
    /// - Parameter strict: true throws on the first damaged fragment; false
    ///   returns what was read before it.
    static func logRecords(_ bytes: [UInt8], strict: Bool) throws -> [[UInt8]] {
        var records: [[UInt8]] = []
        var pending: [UInt8]?
        var offset = 0

        func damaged(_ what: String) throws -> [[UInt8]] {
            if strict { throw Failure.damaged("log: \(what) at byte \(offset)") }
            return records
        }

        while offset < bytes.count {
            let blockRemaining = logBlockSize - offset % logBlockSize
            if blockRemaining < logHeaderSize {
                // Too little room for a header: the writer padded the block.
                offset += blockRemaining
                continue
            }
            guard offset + logHeaderSize <= bytes.count else { return try damaged("a cut header") }
            let stored = UInt32(littleEndian(bytes[...], at: offset, count: 4))
            let length = Int(littleEndian(bytes[...], at: offset + 4, count: 2))
            let type = bytes[offset + 6]
            if type == 0 && length == 0 {
                // Space the file system preallocated and nothing was written to.
                offset += blockRemaining
                continue
            }
            guard logHeaderSize + length <= blockRemaining, offset + logHeaderSize + length <= bytes.count else {
                return try damaged("a fragment longer than what is left")
            }
            let payload = bytes[(offset + logHeaderSize)..<(offset + logHeaderSize + length)]
            let checksum = CRC32C.checksum(payload, continuing: CRC32C.checksum([type]))
            guard CRC32C.masked(checksum) == stored else { return try damaged("a wrong checksum") }

            switch type {
            case 1: // the whole record
                pending = nil
                records.append(Array(payload))
            case 2: // its first fragment
                pending = Array(payload)
            case 3: // a middle one
                guard pending != nil else { return try damaged("a fragment with no start") }
                pending?.append(contentsOf: payload)
            case 4: // the last
                guard var whole = pending else { return try damaged("a fragment with no start") }
                whole.append(contentsOf: payload)
                records.append(whole)
                pending = nil
            default:
                return try damaged("unknown fragment type \(type)")
            }
            offset += logHeaderSize + length
        }
        return records
    }

    // MARK: Tables

    private static let tableMagic: [UInt8] = [0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb]
    private static let footerSize = 48
    /// After every block: one byte naming its compression, then its checksum.
    private static let blockTrailerSize = 5

    /// Calls `visit` with every entry of a table file, tombstones included,
    /// in the file's order. The key is the internal key.
    static func forEachTableEntry(
        _ bytes: [UInt8],
        name: String,
        _ visit: (ArraySlice<UInt8>, ArraySlice<UInt8>) throws -> Void
    ) throws {
        guard bytes.count >= footerSize, Array(bytes.suffix(tableMagic.count)) == tableMagic else {
            throw Failure.damaged("\(name): not a table file")
        }
        // The footer: where the meta-index block is, where the index block is.
        var footer = ByteCursor(bytes[(bytes.count - footerSize)..<(bytes.count - tableMagic.count)], context: name)
        _ = try footer.varint()
        _ = try footer.varint()
        let indexOffset = try footer.varint()
        let index = try block(bytes, offset: indexOffset, size: try footer.varint(), name: name)

        // The index names every data block.
        try forEachBlockEntry(index, name: name) { _, handle in
            var cursor = ByteCursor(handle, context: name)
            let dataOffset = try cursor.varint()
            let data = try block(bytes, offset: dataOffset, size: try cursor.varint(), name: name)
            try forEachBlockEntry(data, name: name, visit)
        }
    }

    private static func block(_ bytes: [UInt8], offset: UInt64, size: UInt64, name: String) throws -> [UInt8] {
        guard
            let start = Int(exactly: offset),
            let count = Int(exactly: size),
            count <= bytes.count,
            start <= bytes.count - count - blockTrailerSize
        else { throw Failure.damaged("\(name): a block outside the file") }

        let end = start + count
        let stored = UInt32(littleEndian(bytes[...], at: end + 1, count: 4))
        guard CRC32C.masked(CRC32C.checksum(bytes[start...end])) == stored else {
            throw Failure.damaged("\(name): a block with a wrong checksum")
        }
        switch bytes[end] {
        case 0: return Array(bytes[start..<end])
        case 1: return try Snappy.decompress(Array(bytes[start..<end]))
        case let type: throw Failure.unsupported("\(name): block compression \(type)")
        }
    }

    /// The entries of one block. Keys are stored as what differs from the key
    /// before; the block ends with a table of restart points, which a reader
    /// that goes through every entry does not need.
    private static func forEachBlockEntry(
        _ block: [UInt8],
        name: String,
        _ visit: (ArraySlice<UInt8>, ArraySlice<UInt8>) throws -> Void
    ) throws {
        guard block.count >= 4 else { throw Failure.damaged("\(name): a block too short") }
        let restarts = Int(littleEndian(block[...], at: block.count - 4, count: 4))
        let end = block.count - 4 - 4 * restarts
        guard end >= 0 else { throw Failure.damaged("\(name): a block with a wrong restart count") }

        var cursor = ByteCursor(block[..<end], context: name)
        var key: [UInt8] = []
        while !cursor.isAtEnd {
            // How much of the previous key this one starts with: a length in
            // that key, not in what is left of the block.
            let shared = try cursor.varint()
            let unshared = try cursor.count()
            let valueLength = try cursor.count()
            guard shared <= key.count else { throw Failure.damaged("\(name): a key sharing more than there is") }
            let kept = Int(shared)
            key.removeSubrange(kept...)
            key.append(contentsOf: try cursor.slice(unshared))
            try visit(key[...], try cursor.slice(valueLength))
        }
    }

    // MARK: Bytes

    private static func littleEndian(_ bytes: ArraySlice<UInt8>, at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count {
            value |= UInt64(bytes[offset + index]) << UInt64(8 * index)
        }
        return value
    }

    /// Reads forward through a run of bytes, throwing where it runs out.
    struct ByteCursor {
        private let bytes: ArraySlice<UInt8>
        private var position: Int
        private let context: String

        init(_ bytes: ArraySlice<UInt8>, context: String) {
            self.bytes = bytes
            position = bytes.startIndex
            self.context = context
        }

        var isAtEnd: Bool { position >= bytes.endIndex }

        mutating func byte() throws -> UInt8 {
            guard position < bytes.endIndex else { throw Failure.damaged("\(context): ends early") }
            defer { position += 1 }
            return bytes[position]
        }

        /// A number in seven-bit groups, the lowest first.
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard shift <= 63 else { throw Failure.damaged("\(context): a number too long") }
                let next = try byte()
                value |= UInt64(next & 0x7f) << shift
                if next & 0x80 == 0 { return value }
                shift += 7
            }
        }

        /// A `varint` that is a length inside these bytes.
        mutating func count() throws -> Int {
            guard let value = Int(exactly: try varint()), value <= bytes.endIndex - position else {
                throw Failure.damaged("\(context): a length past the end")
            }
            return value
        }

        mutating func slice(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= bytes.endIndex - position else {
                throw Failure.damaged("\(context): ends early")
            }
            defer { position += count }
            return bytes[position..<(position + count)]
        }

        mutating func lengthPrefixed() throws -> ArraySlice<UInt8> {
            try slice(try count())
        }
    }
}
