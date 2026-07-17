import XCTest
import MoshBridge

final class PrivateKeyAuditNativeMoshSecretLifetimeTests: XCTestCase {
    func test_PK011_startReleasesPrintableAndRedundantRawBootstrapKeyMaterial() throws {
        let client = try MoshBridgeClient(
            host: "127.0.0.1",
            port: 60_001,
            base64Key: "qiXpjXIk6M8/nWtBn9s6rQ"
        )

        XCTAssertTrue(client.retainsBootstrapKeyMaterial)
        try client.start()
        XCTAssertFalse(client.retainsBootstrapKeyMaterial)
        client.shutdown()
    }

    func test_PK011_invalidCanonicalKeyFailureReleasesAllRetainedBootstrapMaterial() throws {
        // Valid length/alphabet, but the final base64 pad bits are non-zero.
        // The native decoder fills the raw 16-byte buffer before rejecting it.
        let noncanonicalKey = "AAAAAAAAAAAAAAAAAAAAAB"
        let client = try MoshBridgeClient(
            host: "127.0.0.1",
            port: 60_003,
            base64Key: noncanonicalKey
        )

        XCTAssertThrowsError(try client.start()) { error in
            XCTAssertFalse(String(describing: error).contains(noncanonicalKey))
            XCTAssertFalse(error.localizedDescription.contains(noncanonicalKey))
        }
        XCTAssertFalse(client.retainsBootstrapKeyMaterial)
        client.shutdown()
    }

    func test_PK011_shutdownDestroysNativeClientImmediately() throws {
        let client = try MoshBridgeClient(
            host: "127.0.0.1",
            port: 60_002,
            base64Key: "X8YJtMJsZL0ak6kBE4FmlA"
        )

        client.shutdown()

        XCTAssertFalse(client.retainsBootstrapKeyMaterial)
        XCTAssertEqual(client.socketFD, -1)
    }
}
