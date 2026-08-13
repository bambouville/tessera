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

    func test_openSSHCodecUsesStandardDefaultAndNondefaultPortSyntax() throws {
        let keyString = String(openSSHPublicKey: try makeKey())

        XCTAssertEqual(
            KnownHostsOpenSSHCodec.exportLine(
                endpoint: "host.example:22",
                keyString: keyString
            ),
            "host.example \(keyString)"
        )
        XCTAssertEqual(
            KnownHostsOpenSSHCodec.exportLine(
                endpoint: "host.example:2222",
                keyString: keyString
            ),
            "[host.example]:2222 \(keyString)"
        )
    }

    func test_openSSHImportPlanClassifiesAddsReplacementsAndUnchanged() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let unchangedKey = try makeKey()
        let oldReplacementKey = try makeKey()
        let replacementKey = try makeKey()
        let addedKey = try makeKey()
        await store.trust(unchangedKey, for: "same.example:22")
        await store.trust(oldReplacementKey, for: "rotate.example:2222")

        let text = """
        # exported by OpenSSH

        same.example \(String(openSSHPublicKey: unchangedKey))
        [rotate.example]:2222 \(String(openSSHPublicKey: replacementKey))
        new.example \(String(openSSHPublicKey: addedKey)) comment ignored
        """
        let plan = KnownHostsOpenSSHCodec.importPlan(
            text: text,
            currentRows: await store.list()
        )

        XCTAssertEqual(plan.addCount, 1)
        XCTAssertEqual(plan.replaceCount, 1)
        XCTAssertEqual(plan.unchangedCount, 1)
        XCTAssertTrue(plan.rejections.isEmpty)
        XCTAssertEqual(
            plan.entries.first { $0.action == .replace }?.endpoint,
            "rotate.example:2222"
        )
    }

    func test_openSSHImportPlanReportsUnsupportedAndMalformedLines() throws {
        let validKey = String(openSSHPublicKey: try makeKey())
        let text = """
        |1|hash|hash \(validKey)
        @cert-authority host.example \(validKey)
        *.example \(validKey)
        missing-fields
        host.example ssh-ed25519 invalid-base64
        """

        let plan = KnownHostsOpenSSHCodec.importPlan(text: text, currentRows: [])

        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertEqual(plan.rejections.count, 5)
        XCTAssertTrue(plan.rejections.contains {
            $0.reason.contains("hashed hosts")
        })
        XCTAssertTrue(plan.rejections.contains {
            $0.reason.contains("marker")
        })
        XCTAssertTrue(plan.rejections.contains {
            $0.reason.contains("wildcard")
        })
    }

    func test_confirmedOpenSSHImportAddsAndReplacesPreservingHistory() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let oldKey = try makeKey()
        let replacementKey = try makeKey()
        let addedKey = try makeKey()
        await store.trust(oldKey, for: "rotate.example:22")
        let oldFingerprint = KnownHostsStore.fingerprint(of: oldKey)

        let plan = KnownHostsOpenSSHCodec.importPlan(
            text: """
            rotate.example \(String(openSSHPublicKey: replacementKey))
            added.example \(String(openSSHPublicKey: addedKey))
            """,
            currentRows: await store.list()
        )
        let summary = try await store.applyConfirmedOpenSSHImport(plan.entries)
        let rows = await store.list()

        XCTAssertEqual(
            summary,
            KnownHostsStore.OpenSSHImportSummary(
                added: 1,
                replaced: 1,
                unchanged: 0,
                stalePlanConflicts: 0
            )
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(
            rows.first { $0.id == "rotate.example:22" }?.previousFingerprint,
            oldFingerprint
        )
        XCTAssertEqual(
            rows.first { $0.id == "rotate.example:22" }?.fingerprint,
            KnownHostsStore.fingerprint(of: replacementKey)
        )
    }

    func test_openSSHExportRoundTripsThroughImportParser() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let first = try makeKey()
        let second = try makeKey()
        await store.trust(first, for: "default.example:22")
        await store.trust(second, for: "custom.example:2200")

        let exported = await store.openSSHExportText()
        let plan = KnownHostsOpenSSHCodec.importPlan(
            text: exported,
            currentRows: await store.list()
        )

        XCTAssertTrue(exported.contains("default.example ssh-"))
        XCTAssertTrue(exported.contains("[custom.example]:2200 ssh-"))
        XCTAssertEqual(plan.unchangedCount, 2)
        XCTAssertTrue(plan.rejections.isEmpty)
    }

    func test_openSSHImportRejectsEveryLineForAmbiguousEndpoint() throws {
        let first = String(openSSHPublicKey: try makeKey())
        let second = String(openSSHPublicKey: try makeKey())

        let plan = KnownHostsOpenSSHCodec.importPlan(
            text: "same.example \(first)\nsame.example \(second)\n",
            currentRows: []
        )

        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertEqual(plan.rejections.count, 2)
        XCTAssertTrue(plan.rejections.allSatisfy {
            $0.reason.contains("ambiguous")
        })
    }

    func test_confirmedImportSkipsEndpointChangedSinceReview() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeTempStore(clock: clock)
        let reviewedPrior = try makeKey()
        let reviewedReplacement = try makeKey()
        let concurrentReplacement = try makeKey()
        await store.trust(reviewedPrior, for: "race.example:22")
        let plan = KnownHostsOpenSSHCodec.importPlan(
            text: "race.example \(String(openSSHPublicKey: reviewedReplacement))",
            currentRows: await store.list()
        )

        await store.trust(concurrentReplacement, for: "race.example:22")
        let summary = try await store.applyConfirmedOpenSSHImport(plan.entries)
        let row = await store.list().first

        XCTAssertEqual(summary.stalePlanConflicts, 1)
        XCTAssertEqual(summary.replaced, 0)
        XCTAssertEqual(
            row?.fingerprint,
            KnownHostsStore.fingerprint(of: concurrentReplacement)
        )
    }

    func test_confirmedImportPersistenceFailureDoesNotMutateMemory() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let store = KnownHostsStore(
            fileURL: missingDirectory.appendingPathComponent("known_hosts.json"),
            now: { clock.now }
        )
        let key = try makeKey()
        let plan = KnownHostsOpenSSHCodec.importPlan(
            text: "durable.example \(String(openSSHPublicKey: key))",
            currentRows: []
        )

        do {
            _ = try await store.applyConfirmedOpenSSHImport(plan.entries)
            XCTFail("expected durable write failure")
        } catch {
            // Expected: the parent directory intentionally does not exist.
        }
        let finalRows = await store.list()
        XCTAssertTrue(finalRows.isEmpty)
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
