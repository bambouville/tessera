import Foundation
import XCTest
@testable import TesseraTrustCore

final class TrustCoreTests: XCTestCase {
    func testContinuationHintNeverCreatesTrust() throws {
        let endpoint = KnownHostEndpoint(host: "server.example")
        let key = try SSHHostPublicKey(
            algorithm: "ssh-ed25519",
            blob: Data([1, 2, 3]),
            fingerprint: "SHA256:presented"
        )
        XCTAssertEqual(
            KnownHostTrustPolicy.check(
                endpoint: endpoint,
                presented: key,
                trusted: nil,
                comparisonHint: "SHA256:peer-hint"
            ),
            .unknown(presented: key, comparisonHint: "SHA256:peer-hint")
        )
    }

    func testConflictingImportedPinPreservesLocalForReview() throws {
        let endpoint = KnownHostEndpoint(host: "server.example")
        let local = TrustedHostRecord(
            endpoint: endpoint,
            key: try SSHHostPublicKey(
                algorithm: "ssh-ed25519",
                blob: Data([1]),
                fingerprint: "SHA256:local"
            ),
            trustedAt: Date(timeIntervalSince1970: 1)
        )
        let imported = TrustedHostRecord(
            endpoint: endpoint,
            key: try SSHHostPublicKey(
                algorithm: "ssh-ed25519",
                blob: Data([2]),
                fingerprint: "SHA256:imported"
            ),
            trustedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(
            KnownHostTrustPolicy.importRecord(imported, local: local),
            .conflict(local: local, imported: imported)
        )
    }

    func testOpenSSHCodecRoundTripsAndRejectsMalformedBase64() throws {
        let entries = [OpenSSHKnownHostEntry(
            hosts: ["example.com", "[example.com]:2222"],
            algorithm: "ssh-ed25519",
            blob: Data([0, 1, 2, 3]),
            comment: "fixture"
        )]
        let encoded = try OpenSSHKnownHostsCodec.encode(entries)
        XCTAssertEqual(try OpenSSHKnownHostsCodec.decode(encoded), entries)
        XCTAssertThrowsError(try OpenSSHKnownHostsCodec.decode(
            Data("example.com ssh-ed25519 not_base64!\n".utf8)
        ))
    }
}
