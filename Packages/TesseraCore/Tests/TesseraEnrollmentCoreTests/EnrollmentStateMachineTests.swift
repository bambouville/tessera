import Foundation
import TesseraSessionCore
import XCTest
@testable import TesseraEnrollmentCore

final class EnrollmentStateMachineTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 2_000_000_000)

    func test_installRecordCompleteReceiptsAreStrictAndDurabilityGated() async throws {
        let request = makeRequest()
        let requester = try makeMachine()
        let origin = try makeMachine()
        let requestMessage = try await requester.request(request)
        let originRequestResponse = await origin.receive(requestMessage)
        XCTAssertNil(originRequestResponse)
        guard case .awaitingApproval = await origin.state else {
            return XCTFail("origin did not await approval")
        }

        let scope = makeScope(request)
        let grant = try await origin.approve(
            scope: scope,
            policyGeneration: 7,
            expiresAt: instant.addingTimeInterval(30)
        )
        XCTAssertEqual(grant.enrollmentID, request.id)
        _ = try await origin.beginInstallation(policyGeneration: 7, scope: scope)

        let installReceipt = DurableEnrollmentInstallReceipt(
            enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint,
            routeIdentity: scope.routeIdentity,
            recordedAt: instant
        )
        let installed = try await origin.installationDurablyVerified(installReceipt)
        let requesterInstallResponse = await requester.receive(installed)
        XCTAssertNil(requesterInstallResponse)
        guard case .recordingRequester = await requester.state else {
            return XCTFail("requester did not enter durable recording")
        }

        let recordReceipt = DurableEnrollmentRecordReceipt(
            enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint,
            recordedAt: instant
        )
        let recorded = try await requester.requesterRecordDurablyCommitted(recordReceipt)
        let originRecordResponse = await origin.receive(recorded)
        let completed = try XCTUnwrap(originRecordResponse)
        XCTAssertEqual(completed, .completed(enrollmentID: request.id))
        let requesterCompletionResponse = await requester.receive(completed)
        XCTAssertNil(requesterCompletionResponse)

        guard case .completed(let originReceipt) = await origin.state,
              case .completed(let requesterReceipt) = await requester.state else {
            return XCTFail("both roles must complete")
        }
        XCTAssertEqual(originReceipt.enrollmentID, request.id)
        XCTAssertEqual(requesterReceipt.enrollmentID, request.id)
    }

    func test_installedCannotEmitBeforeCapabilityConsumptionAndExactReceipt() async throws {
        let request = makeRequest()
        let origin = try makeMachine()
        _ = await origin.receive(.request(request))
        let scope = makeScope(request)
        _ = try await origin.approve(
            scope: scope,
            policyGeneration: 7,
            expiresAt: instant.addingTimeInterval(30)
        )

        let receipt = DurableEnrollmentInstallReceipt(
            enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint,
            routeIdentity: scope.routeIdentity,
            recordedAt: instant
        )
        await XCTAssertThrowsErrorAsync(
            try await origin.installationDurablyVerified(receipt),
            equals: EnrollmentStateMachineError.invalidTransition
        )
        _ = try await origin.beginInstallation(policyGeneration: 7, scope: scope)

        let wrong = DurableEnrollmentInstallReceipt(
            enrollmentID: request.id,
            publicKeyFingerprint: request.publicKey.fingerprint,
            routeIdentity: "changed-route",
            recordedAt: instant
        )
        await XCTAssertThrowsErrorAsync(
            try await origin.installationDurablyVerified(wrong),
            equals: EnrollmentStateMachineError.receiptMismatch
        )
        guard case .failed(_, .installationFailed) = await origin.state else {
            return XCTFail("receipt mismatch must fail closed")
        }
    }

    func test_policyMutationRevokesPendingGrant() async throws {
        let request = makeRequest()
        let engine = DeviceAccessGrantEngine(now: { self.instant })
        let origin = try makeMachine(grantEngine: engine)
        _ = await origin.receive(.request(request))
        let scope = makeScope(request)
        let grant = try await origin.approve(
            scope: scope,
            policyGeneration: 7,
            expiresAt: instant.addingTimeInterval(30)
        )

        let invalidationMessage = await origin.securityPolicyChanged()
        XCTAssertEqual(
            invalidationMessage,
            .failed(enrollmentID: request.id, failure: .authorizationFailed)
        )
        await XCTAssertThrowsErrorAsync(
            try await engine.consume(
                grant.accessAuthorization,
                attemptID: request.id,
                policyGeneration: 7,
                scope: scope
            ),
            equals: OwnerAuthorizationError.revoked
        )
    }

    func test_defaultGrantEngineUsesTheEnrollmentClock() async throws {
        let request = makeRequest()
        let origin = try EnrollmentStateMachine(
            peerBinding: .appleAccountContinuationStream,
            authorizer: TestOwnerAuthorizer(instant: instant),
            now: { self.instant }
        )
        _ = await origin.receive(.request(request))

        let grant = try await origin.approve(
            scope: makeScope(request),
            policyGeneration: 7,
            expiresAt: instant.addingTimeInterval(30)
        )

        XCTAssertEqual(grant.enrollmentID, request.id)
        guard case .awaitingInstallation = await origin.state else {
            return XCTFail("shared grant engine rejected the adapter clock")
        }
    }

    func test_adapterValidationAndTransportLossBecomeSharedTerminalStates() async throws {
        let request = makeRequest()
        let validationMachine = try makeMachine()
        _ = await validationMachine.receive(.request(request))

        let response = await validationMachine.adapterValidationFailed()
        XCTAssertEqual(
            response,
            .failed(enrollmentID: request.id, failure: .protocolViolation)
        )
        let validationState = await validationMachine.state
        XCTAssertEqual(
            validationState,
            .failed(request.id, .invalidRequest)
        )

        let transportMachine = try makeMachine()
        _ = await transportMachine.receive(.request(request))
        await transportMachine.transportFailed()
        let transportState = await transportMachine.state
        XCTAssertEqual(
            transportState,
            .failed(request.id, .transportFailure)
        )
    }

    func test_outboundFailureOverridesLogicalTerminalState() async throws {
        let request = makeRequest()
        let machine = try makeMachine()
        _ = await machine.receive(.request(request))
        _ = try await machine.reject()
        let rejectedState = await machine.state
        XCTAssertEqual(rejectedState, .rejected(request.id))

        await machine.outboundSendFailed()

        let failedState = await machine.state
        XCTAssertEqual(failedState, .failed(request.id, .transportFailure))
    }

    func test_unboundAndWrongPurposePeersCannotConstructMachine() {
        XCTAssertThrowsError(
            try EnrollmentStateMachine(
                peerBinding: .unbound,
                authorizer: TestOwnerAuthorizer(instant: instant)
            )
        ) { error in
            XCTAssertEqual(error as? EnrollmentStateMachineError, .peerBindingRequired)
        }
    }

    private func makeMachine(
        grantEngine: DeviceAccessGrantEngine? = nil
    ) throws -> EnrollmentStateMachine {
        try EnrollmentStateMachine(
            peerBinding: .appleAccountContinuationStream,
            authorizer: TestOwnerAuthorizer(instant: instant),
            grantEngine: grantEngine ?? DeviceAccessGrantEngine(now: { self.instant }),
            now: { self.instant }
        )
    }

    private func makeRequest() -> EnrollmentRequestV1 {
        EnrollmentRequestV1(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            hostID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            hostName: "zeus",
            requestingDeviceName: "iPhone",
            publicKey: TestPublicKeys.ed25519V1()
        )
    }

    private func makeScope(_ request: EnrollmentRequestV1) -> OwnerAuthorizationScope {
        OwnerAuthorizationScope(
            routeIdentity: "ssh:alice@zeus.example:22",
            hostID: request.hostID,
            publicKeyFingerprint: request.publicKey.fingerprint
        )
    }
}

private struct TestOwnerAuthorizer: FreshOwnerAuthorizing {
    let instant: Date

    func authorize(_ request: OwnerAuthorizationRequest) async throws -> FreshOwnerAuthorization {
        FreshOwnerAuthorization(
            attemptID: request.attemptID,
            policyGeneration: request.policyGeneration,
            scope: request.scope,
            issuedAt: instant,
            expiresAt: request.expiresAt
        )
    }
}

private func XCTAssertThrowsErrorAsync<T, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
