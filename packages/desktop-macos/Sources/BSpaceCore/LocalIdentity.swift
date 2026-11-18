import CommonCrypto
import CryptoKit
import Foundation

/// The key and certificate of one local media channel.
///
/// The shell hands captured video and sound to the page over
/// `wss://127.0.0.1`: a page served over `https` may open nothing less
/// (`ws://` and a custom scheme are refused as mixed content). TLS needs a
/// certificate, and nobody can issue one for the loopback address, so each
/// channel makes its own: a fresh P-256 key and a certificate signed with it,
/// naming `127.0.0.1`. Nothing trusts it except the shell's own web view, for
/// that address and port, by comparing the certificate byte for byte.
///
/// The system turns a key and a certificate into something a TLS server can
/// use only through a PKCS#12 file, so this writes one, in memory; imported
/// with `kSecImportToMemoryOnly` it never reaches a keychain.
public struct LocalIdentity {
    /// The certificate, DER.
    public let certificate: Data
    /// The key and the certificate as a PKCS#12 file.
    public let pkcs12: Data
    /// The password of that file. It protects nothing, the file never
    /// leaves the process; the format wants one.
    public let password: String

    /// The address the certificate is for.
    public static let host = "127.0.0.1"
    static let commonName = "B:SPACE local media channel"
    /// A share may run for days; the certificate dies with the process long
    /// before this.
    static let lifetime: TimeInterval = 30 * 24 * 3600

    public init(now: Date = Date()) throws {
        let key = P256.Signing.PrivateKey()
        let certificate = try Self.certificate(for: key, now: now)
        self.certificate = certificate
        password = Self.randomBytes(16).map { String(format: "%02x", $0) }.joined()
        pkcs12 = try PKCS12.file(
            privateKeyInfo: key.derRepresentation, certificate: certificate, password: password,
            keySalt: Self.randomBytes(8), macSalt: Self.randomBytes(8),
            localKeyID: Data(SHA256.hash(data: certificate).prefix(20))
        )
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// A version 3 certificate for `127.0.0.1`, signed with its own key.
    static func certificate(for key: P256.Signing.PrivateKey, now: Date) throws -> Data {
        let ecdsaWithSHA256 = DER.sequence([DER.objectIdentifier([1, 2, 840, 10045, 4, 3, 2])])
        let name = DER.sequence([
            DER.set([DER.sequence([DER.objectIdentifier([2, 5, 4, 3]), DER.utf8String(commonName)])]),
        ])
        // A positive serial number of 16 bytes.
        var serial = randomBytes(16)
        serial[0] = (serial[0] & 0x7f) | 0x01

        func ext(_ identifier: [UInt], critical: Bool, _ value: Data) -> Data {
            DER.sequence(
                [DER.objectIdentifier(identifier)] + (critical ? [DER.boolean(true)] : []) + [DER.octetString(value)]
            )
        }
        let extensions = DER.sequence([
            // subjectAltName: the address, as four bytes.
            ext([2, 5, 29, 17], critical: false, DER.sequence([DER.tagged(0x87, Data([127, 0, 0, 1]))])),
            // basicConstraints: not an authority.
            ext([2, 5, 29, 19], critical: true, DER.sequence([])),
            // keyUsage: digitalSignature.
            ext([2, 5, 29, 15], critical: true, DER.bitString(Data([0x80]), unusedBits: 7)),
            // extendedKeyUsage: a TLS server.
            ext([2, 5, 29, 37], critical: false, DER.sequence([DER.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 1])])),
        ])

        let toBeSigned = DER.sequence([
            DER.tagged(0xa0, DER.integer(2)),
            DER.integer(bytes: serial),
            ecdsaWithSHA256,
            name,
            DER.sequence([
                DER.utcTime(now.addingTimeInterval(-3600)),
                DER.utcTime(now.addingTimeInterval(lifetime)),
            ]),
            name,
            key.publicKey.derRepresentation,
            DER.tagged(0xa3, extensions),
        ])
        let signature = try key.signature(for: toBeSigned).derRepresentation
        return DER.sequence([toBeSigned, ecdsaWithSHA256, DER.bitString(signature)])
    }
}

/// Just enough of DER to write a certificate and a PKCS#12 file.
enum DER {
    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xff), at: 0)
                length >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data {
        tagged(0x30, items.reduce(Data(), +))
    }

    static func set(_ items: [Data]) -> Data {
        tagged(0x31, items.reduce(Data(), +))
    }

    static func octetString(_ bytes: Data) -> Data {
        tagged(0x04, bytes)
    }

    static func boolean(_ value: Bool) -> Data {
        tagged(0x01, Data([value ? 0xff : 0x00]))
    }

    static func utf8String(_ text: String) -> Data {
        tagged(0x0c, Data(text.utf8))
    }

    static var null: Data { Data([0x05, 0x00]) }

    /// A non-negative integer given as big-endian bytes.
    static func integer(bytes: Data) -> Data {
        var content = Data(bytes.drop { $0 == 0 })
        if content.isEmpty || content[content.startIndex] & 0x80 != 0 {
            content.insert(0, at: content.startIndex)
        }
        return tagged(0x02, content)
    }

    static func integer(_ value: UInt) -> Data {
        var bytes: [UInt8] = []
        var rest = value
        repeat {
            bytes.insert(UInt8(rest & 0xff), at: 0)
            rest >>= 8
        } while rest > 0
        return integer(bytes: Data(bytes))
    }

    static func bitString(_ bytes: Data, unusedBits: UInt8 = 0) -> Data {
        tagged(0x03, Data([unusedBits]) + bytes)
    }

    static func objectIdentifier(_ arcs: [UInt]) -> Data {
        precondition(arcs.count >= 2)
        var content = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var groups: [UInt8] = [UInt8(arc & 0x7f)]
            var rest = arc >> 7
            while rest > 0 {
                groups.insert(UInt8(rest & 0x7f) | 0x80, at: 0)
                rest >>= 7
            }
            content.append(contentsOf: groups)
        }
        return tagged(0x06, content)
    }

    /// `YYMMDDHHMMSSZ`: what a certificate uses for dates before 2050.
    static func utcTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(
            format: "%02d%02d%02d%02d%02d%02dZ",
            (parts.year ?? 0) % 100, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return tagged(0x17, Data(text.utf8))
    }
}

/// A PKCS#12 file with one key and its certificate, in the oldest and most
/// widely read form: the key encrypted with triple DES, the file's integrity
/// kept by HMAC-SHA1, both keys derived from the password as RFC 7292 says.
enum PKCS12 {
    struct Failure: Error {}

    static let iterations = 2048

    static func file(
        privateKeyInfo: Data, certificate: Data, password: String, keySalt: Data, macSalt: Data, localKeyID: Data
    ) throws -> Data {
        let pkcs7Data: [UInt] = [1, 2, 840, 113549, 1, 7, 1]
        let attributes = DER.set([
            DER.sequence([DER.objectIdentifier([1, 2, 840, 113549, 1, 9, 21]), DER.set([DER.octetString(localKeyID)])]),
        ])

        let encryptedKey = try encrypt(privateKeyInfo, password: password, salt: keySalt)
        let keyBag = DER.sequence([
            DER.objectIdentifier([1, 2, 840, 113549, 1, 12, 10, 1, 2]),
            DER.tagged(0xa0, DER.sequence([
                DER.sequence([
                    // pbeWithSHAAnd3-KeyTripleDES-CBC
                    DER.objectIdentifier([1, 2, 840, 113549, 1, 12, 1, 3]),
                    DER.sequence([DER.octetString(keySalt), DER.integer(UInt(iterations))]),
                ]),
                DER.octetString(encryptedKey),
            ])),
            attributes,
        ])
        let certificateBag = DER.sequence([
            DER.objectIdentifier([1, 2, 840, 113549, 1, 12, 10, 1, 3]),
            DER.tagged(0xa0, DER.sequence([
                DER.objectIdentifier([1, 2, 840, 113549, 1, 9, 22, 1]),
                DER.tagged(0xa0, DER.octetString(certificate)),
            ])),
            attributes,
        ])

        let safeContents = DER.sequence([keyBag, certificateBag])
        let authenticatedSafe = DER.sequence([
            DER.sequence([DER.objectIdentifier(pkcs7Data), DER.tagged(0xa0, DER.octetString(safeContents))]),
        ])

        let macKey = derive(password: password, salt: macSalt, purpose: .integrity, count: Int(CC_SHA1_DIGEST_LENGTH))
        var mac = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        mac.withUnsafeMutableBytes { out in
            macKey.withUnsafeBytes { key in
                authenticatedSafe.withUnsafeBytes { message in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA1), key.baseAddress, key.count,
                        message.baseAddress, message.count, out.baseAddress
                    )
                }
            }
        }

        return DER.sequence([
            DER.integer(3),
            DER.sequence([DER.objectIdentifier(pkcs7Data), DER.tagged(0xa0, DER.octetString(authenticatedSafe))]),
            DER.sequence([
                DER.sequence([DER.sequence([DER.objectIdentifier([1, 3, 14, 3, 2, 26]), DER.null]), DER.octetString(mac)]),
                DER.octetString(macSalt),
                DER.integer(UInt(iterations)),
            ]),
        ])
    }

    /// What a derived value is for: the ID byte of RFC 7292, appendix B.3.
    enum Purpose: UInt8 {
        case encryption = 1
        case initialVector = 2
        case integrity = 3
    }

    /// The key derivation of RFC 7292, appendix B.2, with SHA-1.
    static func derive(password: String, salt: Data, purpose: Purpose, count: Int, iterations: Int = iterations) -> Data {
        let block = 64
        let digestLength = Int(CC_SHA1_DIGEST_LENGTH)
        // The password as a BMPString with its terminator: two bytes a unit.
        var passwordBytes = Data()
        for unit in password.utf16 {
            passwordBytes.append(UInt8(unit >> 8))
            passwordBytes.append(UInt8(unit & 0xff))
        }
        passwordBytes.append(contentsOf: [0, 0])

        func filled(_ source: Data) -> Data {
            guard !source.isEmpty else { return Data() }
            let length = block * ((source.count + block - 1) / block)
            return Data((0..<length).map { source[source.startIndex + $0 % source.count] })
        }
        func sha1(_ data: Data) -> Data {
            var digest = Data(count: digestLength)
            digest.withUnsafeMutableBytes { out in
                data.withUnsafeBytes { input in
                    _ = CC_SHA1(input.baseAddress, CC_LONG(input.count), out.bindMemory(to: UInt8.self).baseAddress)
                }
            }
            return digest
        }

        let diversifier = Data(repeating: purpose.rawValue, count: block)
        var input = [UInt8](filled(salt) + filled(passwordBytes))
        var output = Data()
        while output.count < count {
            var digest = sha1(diversifier + Data(input))
            for _ in 1..<iterations {
                digest = sha1(digest)
            }
            output.append(digest)
            // Every block of the input has the digest, repeated to a block
            // and plus one, added to it as one long number.
            let addend = [UInt8]((0..<block).map { digest[$0 % digestLength] })
            for start in stride(from: 0, to: input.count, by: block) {
                var carry: UInt16 = 1
                for offset in stride(from: block - 1, through: 0, by: -1) {
                    let sum = UInt16(input[start + offset]) + UInt16(addend[offset]) + carry
                    input[start + offset] = UInt8(sum & 0xff)
                    carry = sum >> 8
                }
            }
        }
        return output.prefix(count)
    }

    /// Triple DES in CBC mode with the key and vector the password gives.
    static func encrypt(_ plain: Data, password: String, salt: Data) throws -> Data {
        let key = derive(password: password, salt: salt, purpose: .encryption, count: kCCKeySize3DES)
        let vector = derive(password: password, salt: salt, purpose: .initialVector, count: kCCBlockSize3DES)
        var out = Data(count: plain.count + kCCBlockSize3DES)
        var written = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            plain.withUnsafeBytes { plainBytes in
                key.withUnsafeBytes { keyBytes in
                    vector.withUnsafeBytes { vectorBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithm3DES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, vectorBytes.baseAddress,
                            plainBytes.baseAddress, plain.count, outBytes.baseAddress, capacity, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure() }
        return out.prefix(written)
    }
}
