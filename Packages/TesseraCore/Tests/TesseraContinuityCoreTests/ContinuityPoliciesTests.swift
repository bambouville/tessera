import Foundation
import TesseraDomainCore
import TesseraProtocolCore
import XCTest
@testable import TesseraContinuityCore

final class ContinuityPoliciesTests: XCTestCase {
    func test_resolverIsUUIDFirstThenTypedRouteAndBrokenRoutesNeverMatch() {
        let descriptor = makeDescriptor()
        let exact = makeProfile(id: descriptor.hostID, name: "exact", address: "unrelated")
        let copy = makeProfile(id: UUID(), name: "copy", address: descriptor.address)
        let route = descriptor.resolverRoute

        XCTAssertEqual(
            ContinuationResolver.resolve(
                descriptor,
                among: [
                    ContinuationHostCandidate(
                        profile: copy,
                        connectionKey: descriptor.connectionKey,
                        resolverRoute: route
                    ),
                    ContinuationHostCandidate(
                        profile: exact,
                        connectionKey: "unrelated",
                        resolverRoute: nil
                    ),
                ]
            ),
            .fastPath(exact)
        )
        XCTAssertEqual(
            ContinuationResolver.resolve(
                descriptor,
                among: [ContinuationHostCandidate(
                    profile: copy,
                    connectionKey: descriptor.connectionKey,
                    resolverRoute: route
                )]
            ),
            .endpointMatch(copy)
        )
        XCTAssertEqual(
            ContinuationResolver.resolve(
                descriptor,
                among: [ContinuationHostCandidate(
                    profile: copy,
                    connectionKey: descriptor.connectionKey,
                    resolverRoute: nil
                )]
            ),
            .prefill(descriptor)
        )
    }

    func test_trustHintsRemapByVerifiedRoutePositionAndFailClosed() {
        let descriptor = makeDescriptor()
        let localViaID = UUID()
        let localHostID = UUID()
        let localRoute = [
            ContinuationLocalRouteEndpoint(
                hostID: localViaID,
                user: descriptor.via[0].user,
                address: descriptor.via[0].address,
                port: descriptor.via[0].port,
                transport: descriptor.via[0].transport
            ),
            ContinuationLocalRouteEndpoint(
                hostID: localHostID,
                user: descriptor.user,
                address: descriptor.address,
                port: descriptor.port,
                transport: descriptor.transport
            ),
        ]
        let hints = ContinuationTrustHintPolicy.hints(from: descriptor, for: localRoute)
        XCTAssertEqual(hints[localViaID], descriptor.via[0].hostKeyFingerprint)
        XCTAssertEqual(hints[localHostID], descriptor.hostKeyFingerprint)
        XCTAssertNil(hints[descriptor.hostID])

        var mismatched = localRoute
        mismatched[1] = ContinuationLocalRouteEndpoint(
            hostID: localHostID,
            user: descriptor.user,
            address: "attacker.example",
            port: descriptor.port,
            transport: descriptor.transport
        )
        XCTAssertTrue(
            ContinuationTrustHintPolicy.hints(from: descriptor, for: mismatched).isEmpty
        )
    }

    func test_routeReuseNeverMutatesExistingSavedHop() {
        let descriptor = makeDescriptor()
        let via = descriptor.via[0]
        XCTAssertNil(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: false,
                savedVia: [via.hostID: ContinuationSavedRouteEndpoint(
                    endpoint: via,
                    jumpHostID: nil
                )]
            )
        )
        XCTAssertEqual(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: false,
                savedVia: [via.hostID: ContinuationSavedRouteEndpoint(
                    endpoint: via,
                    jumpHostID: UUID()
                )]
            ),
            .routeDiffers(via.hostID)
        )
        XCTAssertEqual(
            ContinuationRouteReusePolicy.conflict(
                for: descriptor,
                destinationIdentifierExists: true,
                savedVia: [:]
            ),
            .destinationIdentifierAlreadyExists
        )
    }

    func test_insertionAndAdmissionAreAtomic() {
        let descriptor = makeDescriptor()
        let viaID = descriptor.via[0].hostID
        let onlyDestination = ContinuationInsertionPlanner.plan(for: descriptor) {
            $0 == viaID
        }
        XCTAssertEqual(onlyDestination.insertedHostIDs, [descriptor.hostID])
        XCTAssertEqual(
            ContinuationAdmissionPolicy.decision(
                existingHostCount: 0,
                insertionPlan: onlyDestination,
                access: .limited(maximumSavedHosts: 1)
            ),
            .allow
        )

        let destinationAndVia = ContinuationInsertionPlanner.plan(for: descriptor) { _ in false }
        XCTAssertEqual(destinationAndVia.insertedHostIDs, [descriptor.hostID, viaID])
        XCTAssertEqual(
            ContinuationAdmissionPolicy.decision(
                existingHostCount: 0,
                insertionPlan: onlyDestination,
                access: .checking(includedMaximumSavedHosts: 1)
            ),
            .allow
        )
        XCTAssertEqual(
            ContinuationAdmissionPolicy.decision(
                existingHostCount: 0,
                insertionPlan: destinationAndVia,
                access: .limited(maximumSavedHosts: 1)
            ),
            .requiresUpgrade
        )
        XCTAssertEqual(
            ContinuationAdmissionPolicy.decision(
                existingHostCount: 1,
                insertionPlan: destinationAndVia,
                access: .checking(includedMaximumSavedHosts: 1)
            ),
            .checkingEntitlement
        )
        XCTAssertEqual(
            ContinuationAdmissionPolicy.decision(
                existingHostCount: 100,
                insertionPlan: ContinuationInsertionPlan(insertedHostIDs: []),
                access: .checking(includedMaximumSavedHosts: 1)
            ),
            .allow
        )
    }

    func test_tmuxReuseRequiresExactNamedRendezvous() {
        XCTAssertTrue(
            ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                requestedSessionName: nil,
                activeSessionName: "anything"
            )
        )
        XCTAssertTrue(
            ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                requestedSessionName: " live ",
                activeSessionName: "live"
            )
        )
        XCTAssertFalse(
            ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                requestedSessionName: "live",
                activeSessionName: "other"
            )
        )
    }

    private func makeProfile(id: UUID, name: String, address: String) -> HostProfile {
        HostProfile(
            id: id,
            name: name,
            endpoint: HostEndpoint(user: "alice", address: address, port: 22),
            transport: .mosh,
            launch: .customCommand
        )
    }
}

func makeDescriptor() -> ContinuationDescriptorV1 {
    let via = ContinuationEndpointV1(
        hostID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        name: "bastion",
        user: "jump",
        address: "edge.example",
        port: 2222,
        transport: .ssh,
        hostKeyFingerprint: "SHA256:via"
    )
    return ContinuationDescriptorV1(
        endpoint: ContinuationEndpointV1(
            hostID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            name: "zeus",
            user: "alice",
            address: "zeus.internal",
            port: 22,
            transport: .mosh,
            hostKeyFingerprint: "SHA256:destination"
        ),
        launchMode: .customCommand,
        tmuxSessionName: nil,
        via: [via]
    )
}
