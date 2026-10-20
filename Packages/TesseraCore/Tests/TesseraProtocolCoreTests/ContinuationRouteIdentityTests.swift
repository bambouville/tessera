import XCTest
@testable import TesseraProtocolCore

/// Golden values computed independently (python hashlib) from the canonical
/// form: rows of `<utf8len>:<field>` NUL-joined, rows `\n`-joined, SHA-256,
/// base64url unpadded. These pin the cross-platform contract — the Kotlin side
/// must produce identical strings once it delegates through the ABI.
final class ContinuationRouteIdentityTests: XCTestCase {
    private let hostID = UUID(uuidString: "9C0A1B2C-3D4E-5F60-7182-93A4B5C6D7E8")!
    private let jumpID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func endpoint(
        id: UUID,
        user: String = "dev",
        address: String = "host.example.com",
        port: Int = 22,
        transport: ContinuationWireTransport = .ssh
    ) -> ContinuationEndpointV1 {
        ContinuationEndpointV1(
            hostID: id, name: "n", user: user, address: address,
            port: port, transport: transport
        )
    }

    func testSingleHopFingerprintMatchesGolden() {
        XCTAssertEqual(
            ContinuationRouteIdentity.fingerprint(for: endpoint(id: hostID), via: []),
            "t8VdF2AuJyORhoyP0SMu8J_LItQUzWmdOKmnCecAHeU"
        )
    }

    func testJumpChainFingerprintMatchesGolden() {
        let via = endpoint(id: jumpID, user: "jump", address: "bastion.example.com", port: 2222)
        let dest = endpoint(id: hostID, transport: .mosh)
        XCTAssertEqual(
            ContinuationRouteIdentity.fingerprint(for: dest, via: [via]),
            "HeW6ygRFml6EZibEqOzBy4oza89JFSfN02GhuE9rwgQ"
        )
    }

    func testNonASCIIFieldCountsUTF8Bytes() {
        XCTAssertEqual(
            ContinuationRouteIdentity.fingerprint(for: endpoint(id: hostID, user: "dévé"), via: []),
            "ApDOMuRQ-0ipI9e5W1SBqGn8GRbxgJoutxuvbNd4JP0"
        )
    }

    func testIdentityPrefixesRouteKey() {
        let dest = endpoint(id: hostID)
        let identity = ContinuationRouteIdentity.identity(for: dest, via: [])
        XCTAssertTrue(identity.hasPrefix("dev@host.example.com:22#"))
        XCTAssertEqual(
            identity,
            "dev@host.example.com:22#t8VdF2AuJyORhoyP0SMu8J_LItQUzWmdOKmnCecAHeU"
        )
    }

    func testDescriptorIdentityAgreesWithOriginDerivation() throws {
        let via = endpoint(id: jumpID, user: "jump", address: "bastion.example.com", port: 2222)
        let dest = endpoint(id: hostID, transport: .mosh)
        let descriptor = ContinuationDescriptorV1(
            endpoint: dest, launchMode: .autoTmux, tmuxSessionName: nil, via: [via]
        )
        XCTAssertEqual(
            ContinuationRouteIdentity.identity(for: descriptor),
            ContinuationRouteIdentity.identity(for: dest, via: [via])
        )
    }

    /// The transport is how a client talks to a host, not which route it is: a
    /// sender on mosh and a receiver on ssh are continuing the SAME route, so
    /// every derivation of the identity must ignore the transport entirely.
    func testIdentityIsIndependentOfWireTransport() throws {
        let sshVia = endpoint(id: jumpID, user: "jump", address: "bastion.example.com", port: 2222)
        let moshVia = endpoint(
            id: jumpID, user: "jump", address: "bastion.example.com",
            port: 2222, transport: .mosh
        )
        let sshDest = endpoint(id: hostID)
        let moshDest = endpoint(id: hostID, transport: .mosh)

        // Same route, both hops flipped to the other transport.
        XCTAssertEqual(
            ContinuationRouteIdentity.identity(for: sshDest, via: [sshVia]),
            ContinuationRouteIdentity.identity(for: moshDest, via: [moshVia])
        )
        XCTAssertEqual(
            ContinuationRouteIdentity.routeKey(for: sshDest, via: [sshVia]),
            ContinuationRouteIdentity.routeKey(for: moshDest, via: [moshVia])
        )
        XCTAssertEqual(
            ContinuationRouteIdentity.fingerprint(for: sshDest, via: [sshVia]),
            ContinuationRouteIdentity.fingerprint(for: moshDest, via: [moshVia])
        )

        // A descriptor received from a mosh sender must resolve to the identity
        // an ssh receiver derives from its own saved host rows.
        let moshDescriptor = ContinuationDescriptorV1(
            endpoint: moshDest, launchMode: .autoTmux, tmuxSessionName: "work", via: [moshVia]
        )
        XCTAssertEqual(
            ContinuationRouteIdentity.identity(for: moshDescriptor),
            ContinuationRouteIdentity.identity(for: sshDest, via: [sshVia])
        )

        // The wire key, by contrast, is untouched and still carries transport.
        XCTAssertTrue(moshDescriptor.connectionKey.hasPrefix("mosh:"))
        XCTAssertNotEqual(
            moshDescriptor.connectionKey,
            ContinuationDescriptorV1.connectionKey(for: sshDest, via: [sshVia])
        )
    }
}
