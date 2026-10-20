import Foundation
import XCTest
@testable import TesseraTrustCore

final class KnownHostEndpointTests: XCTestCase {
    func testStorageKeyIsHostColonPort() {
        XCTAssertEqual(KnownHostEndpoint(host: "host.example").storageKey, "host.example:22")
        XCTAssertEqual(
            KnownHostEndpoint(host: "host.example", port: 2222).storageKey,
            "host.example:2222"
        )
    }

    func testOpenSSHHostFieldUsesBareHostAtTheDefaultPort() {
        XCTAssertEqual(KnownHostEndpoint(host: "host.example").openSSHHostField, "host.example")
        XCTAssertEqual(
            KnownHostEndpoint(host: "host.example", port: 2222).openSSHHostField,
            "[host.example]:2222"
        )
    }

    func testNormalizationTrimsLowercasesAndDropsOneTrailingDot() throws {
        XCTAssertEqual(
            try KnownHostEndpoint.normalized(host: "  Host.Example.  ", port: 22),
            KnownHostEndpoint(host: "host.example", port: 22)
        )
    }

    func testNormalizationDropsOnlyOneTrailingDot() throws {
        // "example.com.." is malformed input, not a doubly-rooted name: it must
        // not silently collapse onto the same pin as "example.com".
        XCTAssertEqual(
            try KnownHostEndpoint.normalized(host: "example.com..", port: 22).host,
            "example.com."
        )
    }

    func testNormalizationStripsOneBracketPairSoIPv6RendersOnce() throws {
        let bracketed = try KnownHostEndpoint.normalized(host: "[2001:DB8::1]", port: 2222)
        let bare = try KnownHostEndpoint.normalized(host: "2001:db8::1", port: 2222)

        XCTAssertEqual(bracketed, bare)
        XCTAssertEqual(bracketed.host, "2001:db8::1")
        XCTAssertEqual(bracketed.openSSHHostField, "[2001:db8::1]:2222")
        XCTAssertEqual(
            try KnownHostEndpoint.normalized(host: "[::1]", port: 22).openSSHHostField,
            "::1"
        )
    }

    func testNormalizationRejectsEmptyWhitespaceAndOutOfRangePorts() {
        XCTAssertThrowsError(try KnownHostEndpoint.normalized(host: "   ", port: 22)) {
            XCTAssertEqual($0 as? KnownHostEndpointError, .emptyHost)
        }
        XCTAssertThrowsError(try KnownHostEndpoint.normalized(host: ".", port: 22)) {
            XCTAssertEqual($0 as? KnownHostEndpointError, .emptyHost)
        }
        XCTAssertThrowsError(try KnownHostEndpoint.normalized(host: "a b", port: 22)) {
            XCTAssertEqual($0 as? KnownHostEndpointError, .hostContainsWhitespace)
        }
        XCTAssertThrowsError(try KnownHostEndpoint.normalized(host: "host", port: 0)) {
            XCTAssertEqual($0 as? KnownHostEndpointError, .portOutOfRange)
        }
        XCTAssertThrowsError(try KnownHostEndpoint.normalized(host: "host", port: 65_536)) {
            XCTAssertEqual($0 as? KnownHostEndpointError, .portOutOfRange)
        }
        XCTAssertNoThrow(try KnownHostEndpoint.normalized(host: "host", port: 1))
        XCTAssertNoThrow(try KnownHostEndpoint.normalized(host: "host", port: 65_535))
    }
}

final class KnownHostTrustVerdictTests: XCTestCase {
    private let endpoint = KnownHostEndpoint(host: "server.example")

    private func key(_ seed: UInt8) throws -> SSHHostPublicKey {
        try SSHHostPublicKey.parse(openSSHKeyString: TrustFixtures.ed25519KeyString(seed: seed))
    }

    private func record(_ key: SSHHostPublicKey) -> TrustedHostRecord {
        TrustedHostRecord(
            endpoint: endpoint,
            key: key,
            trustedAt: Date(timeIntervalSince1970: 1)
        )
    }

    func testPresentedPreviousKeyReportsRevertedRatherThanAPlainChange() throws {
        let current = try key(1)
        let previous = try key(2)

        XCTAssertEqual(
            KnownHostTrustPolicy.check(
                endpoint: endpoint,
                presented: previous,
                trusted: record(current),
                previous: previous
            ),
            .revertedToPrevious(PendingHostKeyChange(
                endpoint: endpoint,
                trusted: current,
                presented: previous
            ))
        )
    }

    func testAnUnrelatedKeyIsStillAPlainChangeEvenWithRotationHistory() throws {
        let current = try key(1)
        let previous = try key(2)
        let stranger = try key(3)

        XCTAssertEqual(
            KnownHostTrustPolicy.check(
                endpoint: endpoint,
                presented: stranger,
                trusted: record(current),
                previous: previous
            ),
            .changed(PendingHostKeyChange(
                endpoint: endpoint,
                trusted: current,
                presented: stranger
            ))
        )
    }

    func testOmittingPreviousReproducesTheOriginalVerdictsExactly() throws {
        let current = try key(1)
        let rotated = try key(2)
        let pin = record(current)

        XCTAssertEqual(
            KnownHostTrustPolicy.check(endpoint: endpoint, presented: current, trusted: nil),
            .unknown(presented: current, comparisonHint: nil)
        )
        XCTAssertEqual(
            KnownHostTrustPolicy.check(
                endpoint: endpoint,
                presented: current,
                trusted: pin
            ),
            .trusted(pin)
        )
        XCTAssertEqual(
            KnownHostTrustPolicy.check(
                endpoint: endpoint,
                presented: rotated,
                trusted: pin
            ),
            .changed(PendingHostKeyChange(
                endpoint: endpoint,
                trusted: current,
                presented: rotated
            ))
        )
    }

    func testCurrentPinWinsWhenItAlsoAppearsAsThePreviousKey() throws {
        let current = try key(1)
        let pin = record(current)

        XCTAssertEqual(
            KnownHostTrustPolicy.check(
                endpoint: endpoint,
                presented: current,
                trusted: pin,
                previous: current
            ),
            .trusted(pin)
        )
    }

    func testAnUnknownEndpointIsNeverRevertedRegardlessOfHistory() throws {
        let presented = try key(1)

        XCTAssertEqual(
            KnownHostTrustPolicy.check(
                endpoint: endpoint,
                presented: presented,
                trusted: nil,
                previous: presented
            ),
            .unknown(presented: presented, comparisonHint: nil)
        )
    }
}
