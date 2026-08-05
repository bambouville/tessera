import XCTest
@testable import Tessera

@MainActor
final class EnrollmentServiceTests: XCTestCase {
    private enum TestAuthorizationError: Error {
        case denied
    }

    private final class Authorizer: EnrollmentBiometricAuthorizing {
        var result: Result<EnrollmentFreshBiometricAuthorization, Error>
        private(set) var callCount = 0
        private(set) var reasons: [String] = []

        init(result: Result<EnrollmentFreshBiometricAuthorization, Error>) {
            self.result = result
        }

        func authorizeFreshBiometrics(
            reason: String
        ) async throws -> EnrollmentFreshBiometricAuthorization {
            callCount += 1
            reasons.append(reason)
            return try result.get()
        }
    }

    private final class SuspendingAuthorizer: EnrollmentBiometricAuthorizing {
        private var continuation: CheckedContinuation<EnrollmentFreshBiometricAuthorization, Error>?

        func authorizeFreshBiometrics(
            reason: String
        ) async throws -> EnrollmentFreshBiometricAuthorization {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func succeed(at date: Date) {
            continuation?.resume(returning: EnrollmentFreshBiometricAuthorization(evaluatedAt: date))
            continuation = nil
        }
    }

    func test_directionAgnosticLoopbackCompletesBothDeviceDirections() async throws {
        try await assertSuccessfulEnrollment(requesterUsesFirstEndpoint: true)
        try await assertSuccessfulEnrollment(requesterUsesFirstEndpoint: false)
    }

    func test_approveEmitsGrantOnlyAfterFreshBiometricAuthorization() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let pair = EnrollmentLoopbackTransport.pair()
        var boundaryEvents: [String] = []
        let grantEngine = SyncDeviceAccessGrantEngine(
            testInstaller: { request in
                boundaryEvents.append("install:\(request.hostID.uuidString)")
            },
            intentRecorder: { request in
                boundaryEvents.append("intent:\(request.hostID.uuidString)")
            },
            verificationRecorder: { request in
                boundaryEvents.append("verified:\(request.hostID.uuidString)")
            }
        )
        let requesterAuth = Authorizer(result: .failure(TestAuthorizationError.denied))
        let originAuth = Authorizer(result: .success(
            EnrollmentFreshBiometricAuthorization(evaluatedAt: now)
        ))
        let requester = try EnrollmentService(
            transport: pair.0,
            authorizer: requesterAuth,
            now: { now }
        )
        let origin = try EnrollmentService(
            transport: pair.1,
            authorizer: originAuth,
            grantEngine: grantEngine,
            now: { now }
        )
        let request = makeRequest()
        let installRequest = makeGrantInstallRequest(
            for: request,
            hostLabel: "Local Helios"
        )
        var emitted: [EnrollmentGrantRequest] = []
        origin.onGrantReady = { emitted.append($0) }

        try requester.request(request)
        XCTAssertEqual(origin.state, .awaitingApproval(request))
        XCTAssertEqual(emitted, [])

        let grant = try await origin.approve(
            authorizationHostName: "Local Helios",
            grantSnapshot: installRequest.grantSnapshot
        )

        XCTAssertEqual(originAuth.callCount, 1)
        XCTAssertEqual(
            originAuth.reasons,
            ["Authorize Dev One's iPhone on Local Helios"]
        )
        XCTAssertEqual(emitted, [grant])
        XCTAssertEqual(grant, EnrollmentGrantRequest(request: request))
        XCTAssertEqual(grant.authorizedKeysLine, request.publicKey.authorizedKeysLine)
        XCTAssertNotNil(grant.accessAuthorization)
        XCTAssertEqual(grantEngine.authorizationRequestCount, 1)
        XCTAssertEqual(origin.state, .awaitingInstallation(grant))
        XCTAssertEqual(requester.state, .requesting(request))

        let authorization = try XCTUnwrap(grant.accessAuthorization)
        try await grantEngine.install(
            installRequest,
            authorization: authorization
        )
        XCTAssertEqual(grantEngine.installationAttemptCount, 1)
        XCTAssertEqual(boundaryEvents, [
            "intent:\(request.hostID.uuidString)",
            "install:\(request.hostID.uuidString)",
            "verified:\(request.hostID.uuidString)"
        ])
        do {
            try await grantEngine.install(
                installRequest,
                authorization: authorization
            )
            XCTFail("A consumed host authorization must not be reusable")
        } catch {
            XCTAssertEqual(
                error as? SyncDeviceAccessGrantEngine.GrantError,
                .authorizationRequired
            )
        }
        XCTAssertEqual(grantEngine.installationAttemptCount, 1)
    }

    func test_grantSnapshotRejectsRouteEndpointLabelKeyPeerAndFlowSubstitution() async throws {
        var installerCalls = 0
        let engine = SyncDeviceAccessGrantEngine(testInstaller: { _ in
            installerCalls += 1
        })
        let request = makeRequest()
        let jumpID = UUID()
        var host = Host(
            id: request.hostID,
            name: "helios",
            address: "private.example",
            user: "dev",
            storedKeyID: UUID()
        )
        host.jumpChain = [
            Host(
                id: jumpID,
                name: "bastion",
                address: "bastion.example",
                user: "jump",
                storedKeyID: UUID()
            )
        ]
        let original = SyncDeviceAccessGrantEngine.InstallRequest(
            host: host,
            hostLabel: "Helios",
            endpoint: "dev@private.example:22",
            peerDeviceName: "Dev One's iPhone",
            flow: .enrollment,
            publicKey: request.publicKey
        )
        let authorization = try await engine.authorize(
            snapshots: [original.grantSnapshot],
            authenticating: {}
        )

        var changedRouteHost = host
        changedRouteHost.jumpChain[0].address = "substitute.example"
        let alternatePublicKey = makeRequest().publicKey
        let substitutions = [
            SyncDeviceAccessGrantEngine.InstallRequest(
                host: changedRouteHost,
                hostLabel: original.hostLabel,
                endpoint: original.endpoint,
                peerDeviceName: original.peerDeviceName,
                flow: original.flow,
                publicKey: original.publicKey
            ),
            SyncDeviceAccessGrantEngine.InstallRequest(
                host: host,
                hostLabel: original.hostLabel,
                endpoint: "dev@other.example:22",
                peerDeviceName: original.peerDeviceName,
                flow: original.flow,
                publicKey: original.publicKey
            ),
            SyncDeviceAccessGrantEngine.InstallRequest(
                host: host,
                hostLabel: "Substituted host label",
                endpoint: original.endpoint,
                peerDeviceName: original.peerDeviceName,
                flow: original.flow,
                publicKey: original.publicKey
            ),
            SyncDeviceAccessGrantEngine.InstallRequest(
                host: host,
                hostLabel: original.hostLabel,
                endpoint: original.endpoint,
                peerDeviceName: original.peerDeviceName,
                flow: original.flow,
                publicKey: alternatePublicKey
            ),
            SyncDeviceAccessGrantEngine.InstallRequest(
                host: host,
                hostLabel: original.hostLabel,
                endpoint: original.endpoint,
                peerDeviceName: "Substituted peer",
                flow: original.flow,
                publicKey: original.publicKey
            ),
            SyncDeviceAccessGrantEngine.InstallRequest(
                host: host,
                hostLabel: original.hostLabel,
                endpoint: original.endpoint,
                peerDeviceName: original.peerDeviceName,
                flow: .bootstrap,
                publicKey: original.publicKey
            )
        ]

        for substituted in substitutions {
            do {
                try await engine.install(substituted, authorization: authorization)
                XCTFail("Substituted grant unexpectedly reached the installer")
            } catch {
                XCTAssertEqual(
                    error as? SyncDeviceAccessGrantEngine.GrantError,
                    .grantSnapshotMismatch
                )
            }
        }
        XCTAssertEqual(engine.installationAttemptCount, 0)
        XCTAssertEqual(installerCalls, 0)
        XCTAssertEqual(engine.activeAuthorizationCount, 1)
        engine.invalidate(authorization)
    }

    func test_grantSnapshotRejectsLiveStoredKeyAndPasswordRevisionSubstitution() {
        let request = makeRequest()
        var host = Host(
            id: request.hostID,
            name: "helios",
            address: "private.example",
            user: "dev",
            password: "initial password"
        )
        host.jumpChain = [
            Host(
                id: UUID(),
                name: "bastion",
                address: "bastion.example",
                user: "jump",
                storedKeyID: UUID()
            )
        ]
        let snapshot = SyncDeviceAccessGrantEngine.InstallRequest(
            host: host,
            hostLabel: "Helios",
            endpoint: "dev@private.example:22",
            peerDeviceName: "Dev One's iPhone",
            flow: .enrollment,
            publicKey: request.publicKey
        ).grantSnapshot

        XCTAssertTrue(snapshot.matchesResolvedHost(host))

        var changedStoredKey = host
        changedStoredKey.jumpChain[0].storedKeyID = UUID()
        XCTAssertFalse(snapshot.matchesResolvedHost(changedStoredKey))

        var changedPasswordRevision = host
        changedPasswordRevision.password = "replacement password"
        XCTAssertFalse(snapshot.matchesResolvedHost(changedPasswordRevision))
    }

    func test_failedBiometricNeverEmitsGrantAndTerminatesBothSides() async throws {
        let pair = EnrollmentLoopbackTransport.pair()
        let requesterAuth = Authorizer(result: .failure(TestAuthorizationError.denied))
        let originAuth = Authorizer(result: .failure(TestAuthorizationError.denied))
        let requester = try EnrollmentService(transport: pair.0, authorizer: requesterAuth)
        let origin = try EnrollmentService(transport: pair.1, authorizer: originAuth)
        let request = makeRequest()
        var grants: [EnrollmentGrantRequest] = []
        origin.onGrantReady = { grants.append($0) }
        try requester.request(request)

        do {
            _ = try await origin.approve(
                grantSnapshot: makeGrantInstallRequest(for: request).grantSnapshot
            )
            XCTFail("approval unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .authorizationFailed)
        }

        XCTAssertEqual(originAuth.callCount, 1)
        XCTAssertEqual(grants, [])
        XCTAssertEqual(origin.state, .failed(request.id, .authorizationFailed))
        XCTAssertEqual(
            requester.state,
            .failed(request.id, .remote(.authorizationFailed))
        )
    }

    func test_staleBiometricResultCannotAuthorizeGrant() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let pair = EnrollmentLoopbackTransport.pair()
        let requester = try EnrollmentService(
            transport: pair.0,
            authorizer: Authorizer(result: .failure(TestAuthorizationError.denied)),
            now: { now }
        )
        let origin = try EnrollmentService(
            transport: pair.1,
            authorizer: Authorizer(result: .success(
                EnrollmentFreshBiometricAuthorization(evaluatedAt: now.addingTimeInterval(-60))
            )),
            now: { now }
        )
        let request = makeRequest()
        try requester.request(request)

        do {
            _ = try await origin.approve(
                grantSnapshot: makeGrantInstallRequest(for: request).grantSnapshot
            )
            XCTFail("stale authorization unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .staleAuthorization)
        }

        XCTAssertEqual(origin.state, .failed(request.id, .staleAuthorization))
        XCTAssertEqual(
            requester.state,
            .failed(request.id, .remote(.authorizationFailed))
        )
    }

    func test_cancelDuringBiometricPromptCannotResumeIntoGrant() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let pair = EnrollmentLoopbackTransport.pair()
        let requester = try EnrollmentService(
            transport: pair.0,
            authorizer: Authorizer(result: .failure(TestAuthorizationError.denied)),
            now: { now }
        )
        let authorizer = SuspendingAuthorizer()
        let origin = try EnrollmentService(
            transport: pair.1,
            authorizer: authorizer,
            now: { now }
        )
        let request = makeRequest()
        var grants: [EnrollmentGrantRequest] = []
        origin.onGrantReady = { grants.append($0) }
        try requester.request(request)

        let approval = Task {
            try await origin.approve(
                grantSnapshot: makeGrantInstallRequest(for: request).grantSnapshot
            )
        }
        await Task.yield()
        XCTAssertEqual(origin.state, .authorizing(request))
        try origin.cancel()
        authorizer.succeed(at: now)

        do {
            _ = try await approval.value
            XCTFail("cancelled authorization emitted a grant")
        } catch {
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .invalidTransition)
        }
        XCTAssertEqual(grants, [])
        XCTAssertEqual(origin.state, .cancelled(request.id))
        XCTAssertEqual(requester.state, .cancelled(request.id))
    }

    func test_installationFailurePropagatesWithoutSuccess() async throws {
        let now = Date()
        let pair = EnrollmentLoopbackTransport.pair()
        let originGrantEngine = SyncDeviceAccessGrantEngine(testInstaller: { _ in })
        let requester = try EnrollmentService(
            transport: pair.0,
            authorizer: Authorizer(result: .failure(TestAuthorizationError.denied)),
            now: { now }
        )
        let origin = try EnrollmentService(
            transport: pair.1,
            authorizer: Authorizer(result: .success(
                EnrollmentFreshBiometricAuthorization(evaluatedAt: now)
            )),
            grantEngine: originGrantEngine,
            now: { now }
        )
        let request = makeRequest()
        try requester.request(request)
        _ = try await origin.approve(
            grantSnapshot: makeGrantInstallRequest(for: request).grantSnapshot
        )
        XCTAssertEqual(originGrantEngine.activeAuthorizationCount, 1)

        try origin.installationFailed()

        XCTAssertEqual(originGrantEngine.activeAuthorizationCount, 0)
        XCTAssertEqual(origin.state, .failed(request.id, .installationFailed))
        XCTAssertEqual(
            requester.state,
            .failed(request.id, .remote(.installationFailed))
        )
    }

    func test_originDoesNotCompleteUntilRequesterDurablyRecordsAndFinalAckReturns() async throws {
        let now = Date()
        let pair = EnrollmentLoopbackTransport.pair()
        let requester = try EnrollmentService(
            transport: pair.0,
            authorizer: Authorizer(result: .failure(TestAuthorizationError.denied)),
            now: { now }
        )
        let origin = try EnrollmentService(
            transport: pair.1,
            authorizer: Authorizer(result: .success(
                EnrollmentFreshBiometricAuthorization(evaluatedAt: now)
            )),
            now: { now }
        )
        let request = makeRequest()
        try requester.request(request)
        let grant = try await origin.approve(
            grantSnapshot: makeGrantInstallRequest(for: request).grantSnapshot
        )

        try origin.installationSucceeded()

        XCTAssertEqual(origin.state, .awaitingRequesterRecord(grant))
        XCTAssertEqual(requester.state, .recordingRequester(request))
        XCTAssertFalse(origin.state.isTerminal)
        XCTAssertFalse(requester.state.isTerminal)

        try requester.requesterPersistenceSucceeded()

        XCTAssertEqual(origin.state, .completed(request.id))
        XCTAssertEqual(requester.state, .completed(request.id))
    }

    func test_requesterPersistenceFailurePreventsOriginCompletion() async throws {
        let now = Date()
        let pair = EnrollmentLoopbackTransport.pair()
        let requester = try EnrollmentService(
            transport: pair.0,
            authorizer: Authorizer(result: .failure(TestAuthorizationError.denied)),
            now: { now }
        )
        let origin = try EnrollmentService(
            transport: pair.1,
            authorizer: Authorizer(result: .success(
                EnrollmentFreshBiometricAuthorization(evaluatedAt: now)
            )),
            now: { now }
        )
        let request = makeRequest()
        try requester.request(request)
        _ = try await origin.approve(
            grantSnapshot: makeGrantInstallRequest(for: request).grantSnapshot
        )
        try origin.installationSucceeded()

        try requester.requesterPersistenceFailed()

        XCTAssertEqual(requester.state, .failed(request.id, .persistenceFailed))
        XCTAssertEqual(
            origin.state,
            .failed(request.id, .remote(.persistenceFailed))
        )
    }

    func test_rejectAndCancelAreStrictTerminalTransitions() throws {
        let rejectPair = EnrollmentLoopbackTransport.pair()
        let denied = Authorizer(result: .failure(TestAuthorizationError.denied))
        let requester = try EnrollmentService(transport: rejectPair.0, authorizer: denied)
        let origin = try EnrollmentService(transport: rejectPair.1, authorizer: denied)
        let request = makeRequest()
        try requester.request(request)

        try origin.reject()

        XCTAssertEqual(origin.state, .rejected(request.id))
        XCTAssertEqual(requester.state, .rejected(request.id))
        XCTAssertThrowsError(try origin.reject()) { error in
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .invalidTransition)
        }

        let cancelPair = EnrollmentLoopbackTransport.pair()
        let cancellingRequester = try EnrollmentService(
            transport: cancelPair.0,
            authorizer: denied
        )
        let cancellingOrigin = try EnrollmentService(
            transport: cancelPair.1,
            authorizer: denied
        )
        try cancellingRequester.request(request)
        try cancellingRequester.cancel()

        XCTAssertEqual(cancellingRequester.state, .cancelled(request.id))
        XCTAssertEqual(cancellingOrigin.state, .cancelled(request.id))
    }

    func test_invalidRoleTransitionsCannotReachGrantOrCompletion() async throws {
        let pair = EnrollmentLoopbackTransport.pair()
        let denied = Authorizer(result: .failure(TestAuthorizationError.denied))
        let requester = try EnrollmentService(transport: pair.0, authorizer: denied)
        let origin = try EnrollmentService(transport: pair.1, authorizer: denied)
        let request = makeRequest()

        do {
            _ = try await requester.approve(
                grantSnapshot: makeGrantInstallRequest(for: request).grantSnapshot
            )
            XCTFail("idle requester approved")
        } catch {
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .invalidTransition)
        }
        XCTAssertThrowsError(try origin.installationSucceeded()) { error in
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .invalidTransition)
        }

        try requester.request(request)
        XCTAssertThrowsError(try requester.request(request)) { error in
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .invalidTransition)
        }
        XCTAssertThrowsError(try origin.installationSucceeded()) { error in
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .invalidTransition)
        }
    }

    func test_peerBindingAssertionRejectsUnboundAndEmptySASTransports() throws {
        let denied = Authorizer(result: .failure(TestAuthorizationError.denied))

        for binding in [
            EnrollmentPeerBinding.unbound,
            .sasBound(transcriptHash: Data())
        ] {
            let pair = EnrollmentLoopbackTransport.pair(peerBinding: binding)
            XCTAssertThrowsError(
                try EnrollmentService(transport: pair.0, authorizer: denied)
            ) { error in
                XCTAssertEqual(error as? EnrollmentService.ServiceError, .peerBindingRequired)
            }
        }

        let applePair = EnrollmentLoopbackTransport.pair(
            peerBinding: .appleAccountContinuationStream
        )
        XCTAssertNoThrow(try EnrollmentService(transport: applePair.0, authorizer: denied))

        let sasPair = EnrollmentLoopbackTransport.pair(
            peerBinding: .sasBound(transcriptHash: Data("verified transcript".utf8))
        )
        XCTAssertNoThrow(try EnrollmentService(transport: sasPair.0, authorizer: denied))
    }

    func test_mismatchedEnrollmentIDIsProtocolFailure() throws {
        let pair = EnrollmentLoopbackTransport.pair()
        let denied = Authorizer(result: .failure(TestAuthorizationError.denied))
        let requester = try EnrollmentService(transport: pair.0, authorizer: denied)
        _ = try EnrollmentService(transport: pair.1, authorizer: denied)
        let request = makeRequest()
        try requester.request(request)

        try pair.1.send(EnrollmentFrameCodec.encode(
            .installed(enrollmentID: UUID())
        ))

        guard case .failed(let id, .protocolViolation) = requester.state else {
            return XCTFail("unexpected state: \(requester.state)")
        }
        XCTAssertEqual(id, request.id)
    }

    func test_rawUnsafeRequestIsRejectedBeforeApproval() throws {
        let pair = EnrollmentLoopbackTransport.pair()
        let denied = Authorizer(result: .failure(TestAuthorizationError.denied))
        let origin = try EnrollmentService(transport: pair.1, authorizer: denied)
        let valid = makeRequest()
        let validFrame = try EnrollmentFrameCodec.encode(.request(valid))
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: validFrame.dropFirst(EnrollmentFrameCodec.headerBytes)
            ) as? [String: Any]
        )
        var rawRequest = try XCTUnwrap(envelope["request"] as? [String: Any])
        rawRequest["hostName"] = "helios\ntrusted-host"
        envelope["request"] = rawRequest
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        var length = UInt32(payload.count).bigEndian
        var rawFrame = Data(bytes: &length, count: EnrollmentFrameCodec.headerBytes)
        rawFrame.append(payload)

        try pair.0.send(rawFrame)

        XCTAssertEqual(origin.state, .failed(nil, .protocolViolation))
        XCTAssertTrue(pair.0.isClosed)
        XCTAssertEqual(denied.callCount, 0)
    }

    func test_requestTransportFailureIsTerminal() throws {
        let pair = EnrollmentLoopbackTransport.pair()
        pair.1.close()
        let denied = Authorizer(result: .failure(TestAuthorizationError.denied))
        let requester = try EnrollmentService(transport: pair.0, authorizer: denied)
        let request = makeRequest()

        XCTAssertThrowsError(try requester.request(request)) { error in
            XCTAssertEqual(error as? EnrollmentService.ServiceError, .transportFailure)
        }
        XCTAssertEqual(requester.state, .failed(request.id, .transportFailure))
    }

    func test_deviceEnrollmentKeyReuseRequiresLiveIntegrityAndMutableSecureEnclaveBoundary() {
        let key = StoredKey(
            name: "Tessera device key",
            algorithm: .ecdsaP256,
            requiresBiometric: true
        )
        key.isSecureEnclave = true

        XCTAssertTrue(EnrollmentCoordinator.isReusableDeviceEnrollmentKey(
            key,
            integrity: .valid,
            protection: .deviceUnlocked(deviceOnly: true)
        ))
        XCTAssertFalse(EnrollmentCoordinator.isReusableDeviceEnrollmentKey(
            key,
            integrity: .missing,
            protection: .deviceUnlocked(deviceOnly: true)
        ))
        XCTAssertFalse(EnrollmentCoordinator.isReusableDeviceEnrollmentKey(
            key,
            integrity: .authenticationRequired,
            protection: .deviceUnlocked(deviceOnly: true)
        ))
        XCTAssertFalse(EnrollmentCoordinator.isReusableDeviceEnrollmentKey(
            key,
            integrity: .valid,
            protection: .userPresence
        ))

        key.requiresBiometric = false
        XCTAssertTrue(EnrollmentCoordinator.isReusableDeviceEnrollmentKey(
            key,
            integrity: .valid,
            protection: .deviceUnlocked(deviceOnly: true)
        ))
        XCTAssertFalse(EnrollmentCoordinator.isReusableDeviceEnrollmentKey(
            key,
            integrity: .valid,
            protection: .deviceUnlocked(deviceOnly: true),
            expectedBiometric: true
        ))
    }

    func test_deviceEnrollmentKeyReuseAllowsRecoverableSoftwareSimulatorBacking() {
        let key = StoredKey(
            name: "Tessera device key",
            algorithm: .ed25519,
            requiresBiometric: false
        )

        XCTAssertTrue(EnrollmentCoordinator.isReusableDeviceEnrollmentKey(
            key,
            integrity: .valid,
            protection: .deviceUnlocked(deviceOnly: false),
            expectedSecureEnclave: false,
            expectedBiometric: false,
            expectedProtection: .deviceUnlocked(deviceOnly: false),
            expectedAlgorithm: .ed25519
        ))
        XCTAssertFalse(EnrollmentCoordinator.isReusableDeviceEnrollmentKey(
            key,
            integrity: .valid,
            protection: .deviceUnlocked(deviceOnly: false),
            expectedSecureEnclave: true,
            expectedAlgorithm: .ed25519
        ))
    }

    private func assertSuccessfulEnrollment(
        requesterUsesFirstEndpoint: Bool
    ) async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let pair = EnrollmentLoopbackTransport.pair()
        let requesterTransport = requesterUsesFirstEndpoint ? pair.0 : pair.1
        let originTransport = requesterUsesFirstEndpoint ? pair.1 : pair.0
        let requesterAuth = Authorizer(result: .failure(TestAuthorizationError.denied))
        let originAuth = Authorizer(result: .success(
            EnrollmentFreshBiometricAuthorization(evaluatedAt: now)
        ))
        let requester = try EnrollmentService(
            transport: requesterTransport,
            authorizer: requesterAuth,
            now: { now }
        )
        let origin = try EnrollmentService(
            transport: originTransport,
            authorizer: originAuth,
            now: { now }
        )
        let request = makeRequest()

        try requester.request(request)
        XCTAssertEqual(origin.state, .awaitingApproval(request))
        let grant = try await origin.approve(
            grantSnapshot: makeGrantInstallRequest(for: request).grantSnapshot
        )
        XCTAssertEqual(grant, EnrollmentGrantRequest(request: request))
        try origin.installationSucceeded()

        XCTAssertEqual(origin.state, .awaitingRequesterRecord(grant))
        XCTAssertEqual(requester.state, .recordingRequester(request))
        try requester.requesterPersistenceSucceeded()

        XCTAssertEqual(originAuth.callCount, 1)
        XCTAssertEqual(requesterAuth.callCount, 0)
        XCTAssertEqual(origin.state, .completed(request.id))
        XCTAssertEqual(requester.state, .completed(request.id))
    }

    private func makeRequest() -> EnrollmentRequest {
        let blob = makeSSHBlob(
            algorithm: .ed25519,
            keyBytes: Data(repeating: 0x24, count: 32)
        )
        return EnrollmentRequest(
            hostID: UUID(),
            hostName: "helios",
            requestingDeviceName: "Dev One's iPhone",
            publicKey: EnrollmentPublicKey(
                id: UUID(),
                displayName: "id_ed25519",
                algorithm: .ed25519,
                blob: blob.base64EncodedString(),
                fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blob),
                protection: .software
            )
        )
    }

    private func makeGrantInstallRequest(
        for request: EnrollmentRequest,
        hostLabel: String = "this host"
    ) -> SyncDeviceAccessGrantEngine.InstallRequest {
        SyncDeviceAccessGrantEngine.InstallRequest(
            host: Host(
                id: request.hostID,
                name: hostLabel,
                address: "helios.example",
                user: "dev"
            ),
            hostLabel: hostLabel,
            endpoint: "helios.example:22",
            peerDeviceName: request.requestingDeviceName,
            flow: .enrollment,
            publicKey: request.publicKey
        )
    }

    private func makeSSHBlob(
        algorithm: EnrollmentPublicKeyAlgorithm,
        keyBytes: Data
    ) -> Data {
        let algorithmBytes = Data(algorithm.rawValue.utf8)
        var blob = Data()
        appendSSHString(algorithmBytes, to: &blob)
        switch algorithm {
        case .ed25519:
            appendSSHString(keyBytes, to: &blob)
        case .secureEnclaveP256:
            appendSSHString(Data("nistp256".utf8), to: &blob)
            appendSSHString(keyBytes, to: &blob)
        }
        return blob
    }

    private func appendSSHString(_ value: Data, to blob: inout Data) {
        var length = UInt32(value.count).bigEndian
        blob.append(Data(bytes: &length, count: 4))
        blob.append(value)
    }
}
