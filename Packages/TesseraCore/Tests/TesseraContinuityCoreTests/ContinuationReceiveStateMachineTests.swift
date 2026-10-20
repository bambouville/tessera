import Foundation
import TesseraDomainCore
import TesseraProtocolCore
import XCTest
@testable import TesseraContinuityCore

final class ContinuationReceiveStateMachineTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 2_000_000_000)

    func test_lockedReceiveReplaysThroughAdmissionCredentialAndConnection() throws {
        let descriptor = makeDescriptor()
        var machine = ContinuationReceiveStateMachine(now: { self.instant })
        let pending = try machine.receiveDescriptor(
            descriptor.encoded(),
            transportBinding: .appleAccountHandoff,
            isLocked: true,
            policyGeneration: 9
        )
        XCTAssertEqual(machine.state, .stashedBehindLock(pending))

        try machine.unlock()
        XCTAssertEqual(try machine.consume(pending.id, policyGeneration: 9), pending)
        _ = try machine.resolve(among: []) { _ in false }
        guard case .needsHostAdmission(_, let plan) = machine.state else {
            return XCTFail("expected admission")
        }
        XCTAssertEqual(plan.insertedHostIDs, [descriptor.hostID, descriptor.via[0].hostID])
        try machine.hostAdmissionCompleted(
            continuationID: pending.id,
            admittedHostID: descriptor.hostID,
            insertedHostIDs: plan.insertedHostIDs,
            policyGeneration: 9
        )
        guard case .needsCredential = machine.state else {
            return XCTFail("expected credential revalidation")
        }
        try machine.credentialEnrollmentCompleted(
            continuationID: pending.id,
            hostID: descriptor.hostID,
            policyGeneration: 9
        )
        let receipt = try machine.connectionCompleted(
            continuationID: pending.id,
            hostID: descriptor.hostID,
            policyGeneration: 9
        )
        XCTAssertEqual(machine.state, .completed(receipt))
    }

    func test_appLockPreservesConsumedAppleContinuationWork() throws {
        let descriptor = makeDescriptor()
        let local = HostProfile(
            id: descriptor.hostID,
            name: "zeus",
            endpoint: HostEndpoint(user: descriptor.user, address: descriptor.address),
            transport: .mosh,
            launch: .customCommand
        )
        var machine = ContinuationReceiveStateMachine(now: { self.instant })
        let pending = try machine.receiveDescriptor(
            descriptor.encoded(),
            transportBinding: .appleAccountHandoff,
            isLocked: false,
            policyGeneration: 9
        )
        _ = try machine.consume(pending.id, policyGeneration: 9)
        _ = try machine.resolve(
            among: [ContinuationHostCandidate(
                profile: local,
                connectionKey: descriptor.connectionKey,
                resolverRoute: descriptor.resolverRoute
            )]
        ) { _ in true }
        guard case .needsCredential = machine.state else {
            return XCTFail("expected credential")
        }

        machine.applicationDidLock()
        guard case .needsCredential(let lockedPending, _) = machine.state else {
            return XCTFail("consumed Apple continuation must preserve released lock semantics")
        }
        XCTAssertEqual(lockedPending, pending)
    }

    func test_invalidDescriptorPreservesStructuredProtocolFailure() throws {
        var machine = ContinuationReceiveStateMachine()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: makeDescriptor().encoded()) as? [String: Any]
        )
        object["port"] = 0

        XCTAssertThrowsError(
            try machine.receiveDescriptor(
                JSONSerialization.data(withJSONObject: object),
                transportBinding: .appleAccountHandoff,
                isLocked: false,
                policyGeneration: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ContinuationReceiveError,
                .invalidDescriptor(.invalidPort(0))
            )
        }
    }

    func test_busyReceiveDoesNotDiscardValidPendingIntent() throws {
        let descriptor = makeDescriptor()
        var machine = ContinuationReceiveStateMachine(now: { self.instant })
        let pending = try machine.receiveDescriptor(
            descriptor.encoded(),
            transportBinding: .appleAccountHandoff,
            isLocked: false,
            policyGeneration: 9
        )
        XCTAssertThrowsError(
            try machine.receiveDescriptor(
                descriptor.encoded(),
                transportBinding: .appleAccountHandoff,
                isLocked: false,
                policyGeneration: 9
            )
        ) { error in
            XCTAssertEqual(error as? ContinuationReceiveError, .busy)
        }
        XCTAssertEqual(machine.state, .ready(pending))
        XCTAssertEqual(machine.lastFailure, .busy)
    }

    func test_completedReceiptStaysBusyUntilExplicitReset() throws {
        let descriptor = makeDescriptor()
        let profile = HostProfile(
            id: descriptor.hostID,
            name: descriptor.name,
            endpoint: HostEndpoint(
                user: descriptor.user,
                address: descriptor.address,
                port: UInt16(descriptor.port)
            ),
            transport: .mosh,
            launch: .pinnedTmux(sessionName: "dev")
        )
        var machine = ContinuationReceiveStateMachine(now: { self.instant })
        let pending = try machine.receiveDescriptor(
            descriptor.encoded(),
            transportBinding: .appleAccountHandoff,
            isLocked: false,
            policyGeneration: 9
        )
        _ = try machine.consume(pending.id, policyGeneration: 9)
        _ = try machine.resolve(
            among: [ContinuationHostCandidate(
                profile: profile,
                connectionKey: descriptor.connectionKey,
                resolverRoute: descriptor.resolverRoute
            )]
        ) { _ in true }
        try machine.credentialEnrollmentCompleted(
            continuationID: pending.id,
            hostID: descriptor.hostID,
            policyGeneration: 9
        )
        let receipt = try machine.connectionCompleted(
            continuationID: pending.id,
            hostID: descriptor.hostID,
            policyGeneration: 9
        )

        XCTAssertThrowsError(
            try machine.receiveDescriptor(
                descriptor.encoded(),
                transportBinding: .appleAccountHandoff,
                isLocked: false,
                policyGeneration: 9
            )
        ) { error in
            XCTAssertEqual(error as? ContinuationReceiveError, .busy)
        }
        XCTAssertEqual(machine.state, .completed(receipt))

        machine.reset()
        XCTAssertNoThrow(
            try machine.receiveDescriptor(
                descriptor.encoded(),
                transportBinding: .appleAccountHandoff,
                isLocked: false,
                policyGeneration: 9
            )
        )
    }

    func test_failedAcceptedReceiptStaysBusyButCancellationReleases() throws {
        let descriptor = makeDescriptor()
        var machine = ContinuationReceiveStateMachine(now: { self.instant })
        let pending = try machine.receiveDescriptor(
            descriptor.encoded(),
            transportBinding: .appleAccountHandoff,
            isLocked: false,
            policyGeneration: 9
        )
        machine.securityPolicyChanged(to: 10)
        XCTAssertEqual(machine.state, .failed(pending.id, .policyInvalidated))

        XCTAssertThrowsError(
            try machine.receiveDescriptor(
                descriptor.encoded(),
                transportBinding: .appleAccountHandoff,
                isLocked: false,
                policyGeneration: 10
            )
        ) { error in
            XCTAssertEqual(error as? ContinuationReceiveError, .busy)
        }
        XCTAssertEqual(machine.state, .failed(pending.id, .policyInvalidated))

        machine.cancel()
        XCTAssertNoThrow(
            try machine.receiveDescriptor(
                descriptor.encoded(),
                transportBinding: .appleAccountHandoff,
                isLocked: false,
                policyGeneration: 10
            )
        )
    }

    func test_unboundTransportAndPolicyMutationFailClosed() throws {
        let descriptor = makeDescriptor()
        var unbound = ContinuationReceiveStateMachine()
        XCTAssertThrowsError(
            try unbound.receiveDescriptor(
                descriptor.encoded(),
                transportBinding: .unbound,
                isLocked: false,
                policyGeneration: 1
            )
        ) { error in
            XCTAssertEqual(error as? ContinuationReceiveError, .unauthenticatedTransport)
        }

        var machine = ContinuationReceiveStateMachine(now: { self.instant })
        let pending = try machine.receiveDescriptor(
            descriptor.encoded(),
            transportBinding: .authenticatedPairing(
                transcriptHash: Data([1, 2, 3]),
                purpose: .continueSession
            ),
            isLocked: false,
            policyGeneration: 9
        )
        machine.securityPolicyChanged(to: 10)
        XCTAssertEqual(machine.state, .failed(pending.id, .policyInvalidated))
        XCTAssertEqual(machine.lastFailure, .stalePolicy)
    }

    func test_hostAndContinuationIdentityMismatchesCannotAdvance() throws {
        let descriptor = makeDescriptor()
        let local = HostProfile(
            id: descriptor.hostID,
            name: "zeus",
            endpoint: HostEndpoint(user: descriptor.user, address: descriptor.address),
            transport: .mosh,
            launch: .customCommand
        )
        var machine = ContinuationReceiveStateMachine(now: { self.instant })
        let pending = try machine.receiveDescriptor(
            descriptor.encoded(),
            transportBinding: .appleAccountHandoff,
            isLocked: false,
            policyGeneration: 9
        )
        XCTAssertThrowsError(try machine.consume(UUID(), policyGeneration: 9)) { error in
            XCTAssertEqual(error as? ContinuationReceiveError, .mismatchedContinuation)
        }
        _ = try machine.consume(pending.id, policyGeneration: 9)
        _ = try machine.resolve(
            among: [ContinuationHostCandidate(
                profile: local,
                connectionKey: descriptor.connectionKey,
                resolverRoute: descriptor.resolverRoute
            )]
        ) { _ in true }
        XCTAssertThrowsError(
            try machine.credentialEnrollmentCompleted(
                continuationID: pending.id,
                hostID: UUID(),
                policyGeneration: 9
            )
        ) { error in
            XCTAssertEqual(error as? ContinuationReceiveError, .mismatchedHost)
        }
    }
}
