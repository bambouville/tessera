import XCTest
import Crypto
import NIOSSH
@testable import Tessera

final class KnownHostsStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Mutable, Sendable clock so a test can advance time after the
    /// store has been created with the now-closure already captured.
    private final class TestClock: @unchecked Sendable {
        var now: Date
        init(_ initial: Date) { self.now = initial }
    }

    private func makeTempStore(clock: TestClock) -> KnownHostsStore {
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("tessera-knownhosts-\(UUID().uuidString).json")
        return KnownHostsStore(fileURL: tmpURL, now: { clock.now })
    }

    private func makeKey() throws -> NIOSSHPublicKey {
        let priv = Curve25519.Signing.PrivateKey()
        let line = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: priv.publicKey, comment: "test"
        )
        let head = line.split(separator: " ").prefix(2).joined(separator: " ")
        return try NIOSSHPublicKey(openSSHPublicKey: head)
    }

    // MARK: - Pure helpers

    func test_endpointHost_stripsDefaultPort() {
        XCTAssertEqual(KnownHostsStore.endpointHost(endpoint: "127.0.0.1:22"), "127.0.0.1")
        XCTAssertEqual(KnownHostsStore.endpointHost(endpoint: "host.example:2222"), "host.example:2222")
        XCTAssertEqual(KnownHostsStore.endpointHost(endpoint: "host.example"), "host.example")
    }

    func test_algorithmName_classifiesCommonKeys() {
        XCTAssertEqual(KnownHostsStore.algorithmName(from: "ssh-ed25519 AAAA..."), "ed25519")
        XCTAssertEqual(KnownHostsStore.algorithmName(from: "ssh-rsa AAAA..."), "rsa")
        XCTAssertEqual(KnownHostsStore.algorithmName(from: "ecdsa-sha2-nistp256 AAAA..."), "ecdsa")
        XCTAssertEqual(KnownHostsStore.algorithmName(from: "ecdsa-sha2-nistp521 AAAA..."), "ecdsa")
    }

    // MARK: - Status semantics

    func test_list_emptyWhenStoreEmpty() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let rows = await store.list()
        XCTAssertEqual(rows, [])
    }

    func test_trustThenList_marksOk() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let key = try makeKey()
        await store.trust(key, for: "host.test:22")

        let rows = await store.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .ok)
        XCTAssertEqual(rows.first?.host, "host.test")
        XCTAssertNil(rows.first?.previousFingerprint)
        XCTAssertNil(rows.first?.pendingFingerprint)
    }

    func test_check_migratesLegacyPaddedFingerprint() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("tessera-knownhosts-\(UUID().uuidString).json")
        let key = try makeKey()
        let fingerprint = KnownHostsStore.fingerprint(of: key)
        XCTAssertFalse(fingerprint.hasSuffix("="))

        let store = KnownHostsStore(fileURL: tmpURL, now: { clock.now })
        await store.trust(key, for: "host.test:22")

        // Rewrite the stored record the way pre-fix builds saved it:
        // base64 "=" padding on every fingerprint value.
        let data = try Data(contentsOf: tmpURL)
        let padded = Self.padFingerprints(try JSONSerialization.jsonObject(with: data))
        try JSONSerialization.data(withJSONObject: padded).write(to: tmpURL)

        let reloaded = KnownHostsStore(fileURL: tmpURL, now: { clock.now })
        guard case .trusted = await reloaded.check(key, for: "host.test:22") else {
            return XCTFail("legacy padded fingerprint must still be trusted")
        }

        // The record migrates to the unpadded form on the trusted check.
        let rows = await reloaded.list()
        XCTAssertEqual(rows.first?.fingerprint, fingerprint)
    }

    private static func padFingerprints(_ object: Any) -> Any {
        if let dict = object as? [String: Any] {
            return dict.mapValues { padFingerprints($0) }
        }
        if let array = object as? [Any] {
            return array.map { padFingerprints($0) }
        }
        if let string = object as? String, string.hasPrefix("SHA256:") {
            return string + "="
        }
        return object
    }

    func test_list_marksStaleAfterThreshold() async throws {
        let trustTime = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(trustTime)
        let store = makeTempStore(clock: clock)
        let key = try makeKey()
        await store.trust(key, for: "host.stale:22")

        clock.now = trustTime.addingTimeInterval(
            Double(KnownHostsStore.staleThresholdDays + 1) * 86400
        )
        let rows = await store.list()
        XCTAssertEqual(rows.first?.status, .stale)
    }

    func test_list_marksOkJustBeforeThreshold() async throws {
        let trustTime = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(trustTime)
        let store = makeTempStore(clock: clock)
        let key = try makeKey()
        await store.trust(key, for: "host.fresh:22")

        clock.now = trustTime.addingTimeInterval(
            Double(KnownHostsStore.staleThresholdDays - 1) * 86400
        )
        let rows = await store.list()
        XCTAssertEqual(rows.first?.status, .ok)
    }

    // MARK: - check() side effects

    func test_check_recordsPendingFingerprint_onChange() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let originalKey = try makeKey()
        let rotatedKey = try makeKey()
        await store.trust(originalKey, for: "host.rotate:22")

        let result = await store.check(rotatedKey, for: "host.rotate:22")
        if case .changed = result {} else {
            XCTFail("expected .changed on key rotation")
        }

        let rows = await store.list()
        XCTAssertEqual(rows.first?.status, .changed)
        XCTAssertNotNil(rows.first?.pendingFingerprint)
    }

    func test_check_clearsPending_whenHostRevertsToTrustedKey() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let originalKey = try makeKey()
        let rotatedKey = try makeKey()
        await store.trust(originalKey, for: "host.flap:22")
        _ = await store.check(rotatedKey, for: "host.flap:22")

        let result = await store.check(originalKey, for: "host.flap:22")
        if case .trusted = result {} else {
            XCTFail("expected .trusted after host reverted to original key")
        }

        let rows = await store.list()
        XCTAssertEqual(rows.first?.status, .ok)
        XCTAssertNil(rows.first?.pendingFingerprint)
    }

    // MARK: - trust() rotation history

    func test_trust_overrideStoresPreviousFingerprint() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let originalKey = try makeKey()
        let rotatedKey = try makeKey()
        await store.trust(originalKey, for: "host.override:22")
        let originalFingerprint = KnownHostsStore.fingerprint(of: originalKey)

        await store.trust(rotatedKey, for: "host.override:22")

        let rows = await store.list()
        XCTAssertEqual(rows.first?.previousFingerprint, originalFingerprint)
        XCTAssertEqual(rows.first?.fingerprint, KnownHostsStore.fingerprint(of: rotatedKey))
        XCTAssertEqual(rows.first?.status, .ok)
        XCTAssertNil(rows.first?.pendingFingerprint)
    }

    func test_trust_sameKeyTwice_keepsExistingPreviousFingerprint() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let k1 = try makeKey()
        let k2 = try makeKey()
        await store.trust(k1, for: "host.same:22")
        await store.trust(k2, for: "host.same:22")
        let priorFingerprint = KnownHostsStore.fingerprint(of: k1)

        await store.trust(k2, for: "host.same:22")

        let rows = await store.list()
        XCTAssertEqual(rows.first?.previousFingerprint, priorFingerprint)
    }

    // MARK: - remove() / sort

    func test_remove_dropsRecord() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let key = try makeKey()
        await store.trust(key, for: "host.bye:22")

        await store.remove(endpoint: "host.bye:22")

        let rows = await store.list()
        XCTAssertEqual(rows, [])
    }

    func test_listSortedByLastSeenDesc() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)

        await store.trust(try makeKey(), for: "old:22")

        clock.now = clock.now.addingTimeInterval(3600)
        await store.trust(try makeKey(), for: "middle:22")

        clock.now = clock.now.addingTimeInterval(3600)
        await store.trust(try makeKey(), for: "newest:22")

        let rows = await store.list()
        XCTAssertEqual(rows.map(\.host), ["newest", "middle", "old"])
    }
}
