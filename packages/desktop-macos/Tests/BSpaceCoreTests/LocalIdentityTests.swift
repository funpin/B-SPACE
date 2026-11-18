import Foundation
import Security
import Testing
@testable import BSpaceCore

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

@Suite struct DERTests {
    @Test func shortAndLongLengths() {
        #expect(hex(DER.octetString(Data([1, 2, 3]))) == "0403010203")
        #expect(hex(DER.octetString(Data(count: 127)).prefix(2)) == "047f")
        #expect(hex(DER.octetString(Data(count: 128)).prefix(3)) == "048180")
        #expect(hex(DER.octetString(Data(count: 300)).prefix(4)) == "0482012c")
    }

    @Test func integersAreNeverNegative() {
        #expect(hex(DER.integer(0)) == "020100")
        #expect(hex(DER.integer(3)) == "020103")
        #expect(hex(DER.integer(128)) == "02020080")
        #expect(hex(DER.integer(2048)) == "02020800")
        #expect(hex(DER.integer(bytes: Data([0x00, 0x00, 0x7f]))) == "02017f")
        #expect(hex(DER.integer(bytes: Data([0xff, 0x01]))) == "020300ff01")
    }

    @Test func objectIdentifiers() {
        // rsadsi's arc needs two and three bytes for its numbers.
        #expect(hex(DER.objectIdentifier([1, 2, 840, 113549, 1, 7, 1])) == "06092a864886f70d010701")
        #expect(hex(DER.objectIdentifier([2, 5, 29, 17])) == "0603551d11")
    }

    @Test func datesAreUTC() {
        // 2026-11-18 14:05:09 UTC.
        let date = Date(timeIntervalSince1970: 1_795_010_709)
        #expect(String(decoding: DER.utcTime(date).dropFirst(2), as: UTF8.self) == "261118140509Z")
    }
}

@Suite struct PKCS12Tests {
    @Test func derivesAKeyAsOtherImplementationsDo() {
        // The vector Go's pkcs12 package tests its derivation with.
        let key = PKCS12.derive(
            password: "sesame", salt: Data(repeating: 0xff, count: 8), purpose: .encryption, count: 24, iterations: 2048
        )
        #expect(hex(key) == "7cd9fd3e2b3be7691a44e3bef0f9ea0fb9b897d4e325d9d1")
    }

    @Test func aPurposeChangesTheKey() {
        let salt = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let encryption = PKCS12.derive(password: "x", salt: salt, purpose: .encryption, count: 24)
        let integrity = PKCS12.derive(password: "x", salt: salt, purpose: .integrity, count: 24)
        #expect(encryption != integrity)
        #expect(PKCS12.derive(password: "x", salt: salt, purpose: .encryption, count: 24) == encryption)
        // A longer key starts with the shorter one.
        #expect(PKCS12.derive(password: "x", salt: salt, purpose: .encryption, count: 50).prefix(24) == encryption)
    }
}

@Suite struct LocalIdentityTests {
    private func imported(_ identity: LocalIdentity) -> SecIdentity? {
        var items: CFArray?
        let status = SecPKCS12Import(identity.pkcs12 as CFData, [
            kSecImportExportPassphrase: identity.password,
            kSecImportToMemoryOnly: true,
        ] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else { return nil }
        // The dictionary holds a SecIdentity under this key by contract.
        return (value as! SecIdentity)
    }

    @Test func theSystemTakesTheFileAndGivesBackTheSameCertificate() throws {
        let identity = try LocalIdentity()
        let system = try #require(imported(identity))
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(system, &certificate) == errSecSuccess)
        #expect(certificate.map { SecCertificateCopyData($0) as Data } == identity.certificate)
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(system, &key) == errSecSuccess)
        #expect(key != nil)
    }

    @Test func aWrongPasswordIsRefused() throws {
        let identity = try LocalIdentity()
        var items: CFArray?
        let status = SecPKCS12Import(identity.pkcs12 as CFData, [
            kSecImportExportPassphrase: identity.password + "x",
            kSecImportToMemoryOnly: true,
        ] as CFDictionary, &items)
        #expect(status != errSecSuccess)
    }

    /// Whether a TLS client that trusts this one certificate would accept it
    /// for a host at a moment: signature, dates, name and purpose at once.
    private func isAccepted(_ identity: LocalIdentity, host: String, at date: Date) throws -> Bool {
        let certificate = try #require(SecCertificateCreateWithData(nil, identity.certificate as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess)
        let made = try #require(trust)
        SecTrustSetAnchorCertificates(made, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(made, true)
        SecTrustSetVerifyDate(made, date as CFDate)
        return SecTrustEvaluateWithError(made, nil)
    }

    @Test func theCertificateIsATLSServersForTheLoopbackAddress() throws {
        let now = Date()
        let identity = try LocalIdentity(now: now)
        let certificate = try #require(SecCertificateCreateWithData(nil, identity.certificate as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "B:SPACE local media channel")
        #expect(try isAccepted(identity, host: "127.0.0.1", at: now))
        #expect(try isAccepted(identity, host: "127.0.0.1", at: now.addingTimeInterval(7 * 24 * 3600)))
        // Another address, or a name, is not what it is for.
        #expect(try !isAccepted(identity, host: "127.0.0.2", at: now))
        #expect(try !isAccepted(identity, host: "localhost", at: now))
        // Nor is another time.
        #expect(try !isAccepted(identity, host: "127.0.0.1", at: now.addingTimeInterval(-2 * 24 * 3600)))
        #expect(try !isAccepted(identity, host: "127.0.0.1", at: now.addingTimeInterval(60 * 24 * 3600)))
    }

    @Test func everyChannelHasItsOwnKey() throws {
        let first = try LocalIdentity()
        let second = try LocalIdentity()
        #expect(first.certificate != second.certificate)
        #expect(first.password != second.password)
        #expect(first.password.count == 32)
    }
}
