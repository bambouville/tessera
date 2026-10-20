import Foundation
import XCTest
@testable import TesseraTrustCore

/// Fixtures shared by the trust-core test files.
enum TrustFixtures {
    /// SSH wire encoding of one length-prefixed string field.
    static func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let count = bytes.count
        return [
            UInt8((count >> 24) & 0xFF),
            UInt8((count >> 16) & 0xFF),
            UInt8((count >> 8) & 0xFF),
            UInt8(count & 0xFF),
        ] + bytes
    }

    /// A structurally valid `ssh-ed25519` host-key blob (32-byte key body).
    static func ed25519Blob(seed: UInt8) -> Data {
        Data(
            sshString(Array("ssh-ed25519".utf8))
                + sshString(Array(repeating: seed, count: 32))
        )
    }

    static func ed25519KeyString(seed: UInt8) -> String {
        "ssh-ed25519 \(ed25519Blob(seed: seed).base64EncodedString())"
    }

    static func ed25519Fingerprint(seed: UInt8) -> String {
        SSHHostPublicKey.sha256Fingerprint(of: ed25519Blob(seed: seed))
    }

    /// A blob whose inner algorithm name disagrees with the token in front of
    /// it: the token claims RSA, the body says ed25519.
    static func algorithmLyingKeyString() -> String {
        "ssh-rsa \(ed25519Blob(seed: 9).base64EncodedString())"
    }
}

final class HostKeyFingerprintTests: XCTestCase {
    func testSHA256FingerprintDefaultsToTheUnpaddedOpenSSHForm() {
        // SHA-256 of the empty input is a fixed, widely published vector.
        XCTAssertEqual(
            SSHHostPublicKey.sha256Fingerprint(of: Data()),
            "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"
        )
    }

    func testPaddedFingerprintDiffersOnlyByTheBase64Padding() {
        let blob = TrustFixtures.ed25519Blob(seed: 3)
        let unpadded = SSHHostPublicKey.sha256Fingerprint(of: blob)
        let padded = SSHHostPublicKey.sha256Fingerprint(of: blob, padding: .padded)

        XCTAssertTrue(padded.hasSuffix("="))
        XCTAssertFalse(unpadded.hasSuffix("="))
        XCTAssertEqual(padded.replacingOccurrences(of: "=", with: ""), unpadded)
        XCTAssertTrue(unpadded.hasPrefix("SHA256:"))
    }

    func testParseAcceptsAStructurallyValidKeyAndCanonicalizesIt() throws {
        let key = try SSHHostPublicKey.parse(
            openSSHKeyString: "  ssh-ed25519   \(TrustFixtures.ed25519Blob(seed: 4).base64EncodedString())  "
        )

        XCTAssertEqual(key.algorithm, "ssh-ed25519")
        XCTAssertEqual(key.blob, TrustFixtures.ed25519Blob(seed: 4))
        XCTAssertEqual(key.openSSHKeyString, TrustFixtures.ed25519KeyString(seed: 4))
        XCTAssertEqual(key.fingerprint, TrustFixtures.ed25519Fingerprint(seed: 4))
    }

    func testParseRejectsAKeyThatLiesAboutItsOwnAlgorithm() {
        XCTAssertThrowsError(
            try SSHHostPublicKey.parse(openSSHKeyString: TrustFixtures.algorithmLyingKeyString())
        ) { error in
            XCTAssertEqual(error as? TrustPolicyError, .keyAlgorithmMismatch)
        }
    }

    func testParseRejectsNonCanonicalBase64AndMalformedShapes() {
        // A missing key field, a payload that is not base64 at all, and an
        // unpadded payload (which is not what OpenSSH writes) all fail rather
        // than being repaired into a pin.
        XCTAssertThrowsError(try SSHHostPublicKey.parse(openSSHKeyString: "ssh-ed25519"))
        XCTAssertThrowsError(try SSHHostPublicKey.parse(openSSHKeyString: "ssh-ed25519 "))
        XCTAssertThrowsError(
            try SSHHostPublicKey.parse(openSSHKeyString: "ssh-ed25519 not!base64")
        )
        XCTAssertThrowsError(
            try SSHHostPublicKey.parse(openSSHKeyString: "ssh-ed25519 AQIDBA")
        )
    }

    func testParseRejectsABlobLargerThanTheCap() {
        let oversized = Data(
            TrustFixtures.sshString(Array("ssh-ed25519".utf8))
                + TrustFixtures.sshString(
                    Array(repeating: 0x41, count: SSHHostPublicKey.maximumBlobBytes)
                )
        )
        XCTAssertThrowsError(
            try SSHHostPublicKey.parse(
                openSSHKeyString: "ssh-ed25519 \(oversized.base64EncodedString())"
            )
        ) { error in
            XCTAssertEqual(error as? TrustPolicyError, .invalidKey)
        }
    }
}
