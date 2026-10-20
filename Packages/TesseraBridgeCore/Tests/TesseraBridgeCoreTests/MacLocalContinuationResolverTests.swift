import Foundation
import TesseraBridgeCore
import TesseraProtocolCore
import XCTest

final class MacLocalContinuationResolverTests: XCTestCase {
    private let localHostID = UUID(uuidString: "81BCA9C1-2319-4DBB-8499-F525C3D03D30")!

    func testStableHostIDResolvesAutoTmuxLocally() throws {
        let descriptor = try makeDescriptor(hostID: localHostID, launchMode: .autoTmux)

        XCTAssertEqual(
            MacLocalContinuationResolver.resolve(descriptor, local: snapshot()),
            .local(
                MacLocalTmuxAttachIntent(
                    descriptor: descriptor,
                    sessionName: try .init(validating: "work"),
                    matchedByStableHostID: true
                )
            )
        )
    }

    func testIndependentHostIDUsesEndpointAndFingerprintFallback() throws {
        let descriptor = try makeDescriptor(
            hostID: UUID(),
            address: "MY-MAC.LOCAL.",
            fingerprint: "SHA256:local"
        )

        XCTAssertEqual(
            MacLocalContinuationResolver.resolve(descriptor, local: snapshot()),
            .local(
                MacLocalTmuxAttachIntent(
                    descriptor: descriptor,
                    sessionName: try .init(validating: "work"),
                    matchedByStableHostID: false
                )
            )
        )
    }

    func testEndpointFallbackRejectsMissingOrMismatchedFingerprint() throws {
        let missing = try makeDescriptor(hostID: UUID(), fingerprint: nil)
        let mismatched = try makeDescriptor(
            hostID: UUID(),
            fingerprint: "SHA256:someone-else"
        )

        XCTAssertEqual(
            MacLocalContinuationResolver.resolve(missing, local: snapshot()),
            .rejected(.localHostKeyMismatch)
        )
        XCTAssertEqual(
            MacLocalContinuationResolver.resolve(mismatched, local: snapshot()),
            .rejected(.localHostKeyMismatch)
        )
    }

    func testStableHostIDRejectsWrongUserAndFingerprint() throws {
        let wrongUser = try makeDescriptor(hostID: localHostID, user: "other")
        let wrongKey = try makeDescriptor(
            hostID: localHostID,
            fingerprint: "SHA256:someone-else"
        )

        XCTAssertEqual(
            MacLocalContinuationResolver.resolve(wrongUser, local: snapshot()),
            .rejected(.localUserMismatch)
        )
        XCTAssertEqual(
            MacLocalContinuationResolver.resolve(wrongKey, local: snapshot()),
            .rejected(.localHostKeyMismatch)
        )
    }

    func testUnrelatedEndpointRemainsRemote() throws {
        let descriptor = try makeDescriptor(
            hostID: UUID(),
            address: "server.example.com",
            fingerprint: "SHA256:remote"
        )

        XCTAssertEqual(
            MacLocalContinuationResolver.resolve(descriptor, local: snapshot()),
            .remote(descriptor)
        )
    }

    func testLocalHostRejectsBastionRoute() throws {
        let via = ContinuationEndpointV1(
            hostID: UUID(),
            name: "jump",
            user: "jump",
            address: "jump.example.com",
            port: 22,
            transport: .ssh
        )
        let descriptor = try makeDescriptor(hostID: localHostID, via: [via])

        XCTAssertEqual(
            MacLocalContinuationResolver.resolve(descriptor, local: snapshot()),
            .rejected(.localRouteUnsupported)
        )
    }

    func testAuthorityStampUsesSharedWireGrammar() {
        XCTAssertEqual(
            MacGridAuthorityStampFactory.wireValue(
                deviceID: localHostID,
                generation: 42
            ),
            "v1 81BCA9C1-2319-4DBB-8499-F525C3D03D30 42 Mac"
        )
    }

    private func snapshot() -> MacLocalEndpointSnapshot {
        MacLocalEndpointSnapshot(
            hostID: localHostID,
            user: "avery",
            addressCandidates: ["my-mac.local", "192.0.2.10"],
            sshHostKeyFingerprints: ["SHA256:local"]
        )
    }

    private func makeDescriptor(
        hostID: UUID,
        user: String = "avery",
        address: String = "my-mac.local",
        fingerprint: String? = "SHA256:local",
        launchMode: ContinuationWireLaunchMode = .pinnedTmux,
        via: [ContinuationEndpointV1] = []
    ) throws -> ContinuationDescriptorV1 {
        let endpoint = ContinuationEndpointV1(
            hostID: hostID,
            name: "My Mac",
            user: user,
            address: address,
            port: 22,
            transport: .ssh,
            hostKeyFingerprint: fingerprint
        )
        let descriptor = ContinuationDescriptorV1(
            endpoint: endpoint,
            launchMode: launchMode,
            tmuxSessionName: "work",
            via: via
        )
        try descriptor.validate()
        return descriptor
    }
}
