import Foundation
import XCTest
@testable import TesseraSessionCore

final class SessionCoreTests: XCTestCase {
    func testAcknowledgedPaneRepliesAreUngatedAndGridTypingRemainsMutation() {
        for receipt in [nil, SessionCommandReceipt(rawValue: UUID())] {
            let gate: SessionCommandAuthorityGate = receipt == nil ? .mutation : .ungated
            for command: SessionCommand in [
                .sendTmuxPaneInput(data: Data([0x61]), paneID: "%3", receipt: receipt),
                .sendTmuxPaneKey(.enter, paneID: "%3", receipt: receipt),
                .sendTmuxPaneKey(.escape, paneID: "%3", receipt: receipt),
            ] {
                XCTAssertEqual(command.authorityGate, gate)
                XCTAssertEqual(SessionBackendOperation(command).authorityGate, gate)
                for refusal: SessionCommandAuthorityRefusal in [.yielded, .reclaiming, .resuming] {
                    let mutationRefusal: TmuxGridAuthorityPresentation.MutationRefusal? =
                        refusal == .yielded ? .yielded : refusal == .reclaiming ? .reclaiming : nil
                    XCTAssertEqual(
                        command.authorityGate.refusal(gatesTyping: true, mutationRefusal: mutationRefusal),
                        receipt == nil ? mutationRefusal.map(SessionCommandAuthorityRefusal.init) : nil
                    )
                }
            }
        }
        XCTAssertEqual(SessionCommand.sendInput(Data([0x61])).authorityGate, .typing)
        XCTAssertEqual(SessionCommand.selectTmuxPane("%3").authorityGate, .mutation)
        XCTAssertEqual(SessionCommand.createTmuxWindow.authorityGate, .mutation)
    }

    /// Prompt answers on tmux travel as `send-keys` names; the bytes stay
    /// for un-receipted pane input. Android still encodes only enter/escape.
    func testNamedPaneKeysRoundTripTmuxNamesAndWireValues() throws {
        let names = ["Enter", "Escape", "Tab", "BTab", "Up", "Down", "Left", "Right", "S-Left", "C-]"]
        for name in names {
            let key = try XCTUnwrap(SessionTmuxPaneKey(tmuxKeyName: name), name)
            XCTAssertEqual(key.tmuxKeyName, name)
            let decoded = try JSONDecoder().decode(SessionTmuxPaneKey.self, from: JSONEncoder().encode(key))
            XCTAssertEqual(decoded, key)
            XCTAssertFalse(key.bytes.isEmpty, name)
        }
        XCTAssertNil(SessionTmuxPaneKey(tmuxKeyName: "PageUp"))
        XCTAssertNil(SessionTmuxPaneKey(tmuxKeyName: "C-c"))
        XCTAssertEqual(SessionTmuxPaneKey.enter.rawValue, "enter")
        XCTAssertEqual(SessionTmuxPaneKey.escape.rawValue, "escape")
        XCTAssertEqual(SessionTmuxPaneKey.backTab.bytes, Array("\u{1B}[Z".utf8))
        XCTAssertEqual(SessionTmuxPaneKey.controlRightBracket.bytes, [0x1D])
    }

    func testTerminalOutputReceiptCodableUsesTheSharedSignedIdentifierRange() throws {
        let maximum = TerminalOutputReceipt.maximumIdentifier
        let receipt = TerminalOutputReceipt(
            deliveryID: maximum,
            repaintRequestID: maximum
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                TerminalOutputReceipt.self,
                from: JSONEncoder().encode(receipt)
            ),
            receipt
        )

        let invalidPayloads = [
            #"{"deliveryID":0}"#,
            #"{"deliveryID":1,"repaintRequestID":0}"#,
            #"{"deliveryID":9223372036854775808}"#,
            #"{"deliveryID":1,"repaintRequestID":9223372036854775808}"#,
        ]
        for payload in invalidPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    TerminalOutputReceipt.self,
                    from: Data(payload.utf8)
                ),
                payload
            )
        }
    }

    func testChallengeRejectsStalePolicyAndIsOneShot() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let registry = ChallengeRegistry(now: { now })
        let attempt = UUID()
        let context = ChallengeContext(
            sessionID: UUID(),
            attemptID: attempt,
            policyGeneration: 5,
            expiresAt: now.addingTimeInterval(30)
        )
        let challenge = SessionChallenge.ownerAuthorization(
            context: context,
            reasonCode: "install_key"
        )
        try await registry.insert(challenge)

        do {
            _ = try await registry.consume(
                ChallengeResponse(
                    challengeID: context.challengeID,
                    attemptID: attempt,
                    policyGeneration: 4,
                    decision: .approve
                ),
                currentAttemptID: attempt,
                currentPolicyGeneration: 5
            )
            XCTFail("expected a stale policy response to fail")
        } catch {
            XCTAssertEqual(error as? ChallengeValidationError, .stalePolicy)
        }

        let response = ChallengeResponse(
            challengeID: context.challengeID,
            attemptID: attempt,
            policyGeneration: 5,
            decision: .approve
        )
        let consumedChallenge = try await registry.consume(
            response,
            currentAttemptID: attempt,
            currentPolicyGeneration: 5
        )
        XCTAssertEqual(consumedChallenge, challenge)
        do {
            _ = try await registry.consume(
                response,
                currentAttemptID: attempt,
                currentPolicyGeneration: 5
            )
            XCTFail("expected a consumed response to fail")
        } catch {
            XCTAssertEqual(error as? ChallengeValidationError, .alreadyConsumed)
        }
    }

    func testChallengeRegistrationBoundsLifetimeMetadataAndIdentity() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let registry = ChallengeRegistry(now: { now })
        let context = ChallengeContext(
            sessionID: UUID(),
            attemptID: UUID(),
            policyGeneration: 5,
            expiresAt: now.addingTimeInterval(SessionChallenge.maximumLifetime)
        )
        let valid = SessionChallenge.ownerAuthorization(
            context: context,
            reasonCode: "install_key"
        )
        try await registry.insert(valid)

        do {
            try await registry.insert(valid)
            XCTFail("expected duplicate challenge registration to fail")
        } catch {
            XCTAssertEqual(error as? ChallengeValidationError, .duplicateChallenge)
        }

        let tooLong = SessionChallenge.ownerAuthorization(
            context: ChallengeContext(
                sessionID: UUID(),
                attemptID: UUID(),
                policyGeneration: 5,
                expiresAt: now.addingTimeInterval(SessionChallenge.maximumLifetime + 1)
            ),
            reasonCode: "install_key"
        )
        do {
            try await registry.insert(tooLong)
            XCTFail("expected an overlong lifetime to fail")
        } catch {
            XCTAssertEqual(error as? ChallengeValidationError, .invalidLifetime)
        }

        let controlText = SessionChallenge.credential(
            context: ChallengeContext(
                sessionID: UUID(),
                attemptID: UUID(),
                policyGeneration: 5,
                expiresAt: now.addingTimeInterval(30)
            ),
            credentialID: nil,
            kind: "password\nspoof"
        )
        do {
            try await registry.insert(controlText)
            XCTFail("expected control characters to fail")
        } catch {
            XCTAssertEqual(
                error as? ChallengeValidationError,
                .invalidDisplayMetadata(field: "credentialKind")
            )
        }
    }

    func testChallengeGenerationContractMatchesCheckedInVector() throws {
        struct Contract: Decodable {
            struct Limits: Decodable {
                let maximumLifetimeSeconds: Int
                let maximumEncodedBytes: Int
                let maximumHostBytes: Int
                let maximumFingerprintBytes: Int
                let maximumHintBytes: Int
                let maximumCodeBytes: Int
            }

            struct Valid: Decodable {
                let challengeID: UUID
                let sessionID: UUID
                let attemptID: UUID
                let policyGeneration: UInt64
                let now: TimeInterval
                let expiresAt: TimeInterval
                let reasonCode: String
            }

            struct Rejection: Decodable {
                let `case`: String
                let expectedError: String
            }

            let limits: Limits
            let validOwnerAuthorization: Valid
            let rejections: [Rejection]
        }

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorURL = repositoryURL
            .appendingPathComponent("ProtocolVectors/session/v1/challenges.json")
        let contract = try JSONDecoder().decode(
            Contract.self,
            from: Data(contentsOf: vectorURL)
        )

        XCTAssertEqual(
            contract.limits.maximumLifetimeSeconds,
            Int(SessionChallenge.maximumLifetime)
        )
        XCTAssertEqual(contract.limits.maximumEncodedBytes, SessionChallenge.maximumEncodedBytes)
        XCTAssertEqual(contract.limits.maximumHostBytes, SessionChallenge.maximumHostBytes)
        XCTAssertEqual(contract.limits.maximumFingerprintBytes, SessionChallenge.maximumFingerprintBytes)
        XCTAssertEqual(contract.limits.maximumHintBytes, SessionChallenge.maximumHintBytes)
        XCTAssertEqual(contract.limits.maximumCodeBytes, SessionChallenge.maximumCodeBytes)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: contract.rejections.map { ($0.case, $0.expectedError) }),
            [
                "zeroLifetime": "invalidLifetime",
                "overlongLifetime": "invalidLifetime",
                "controlCharacter": "invalidDisplayMetadata",
                "staleSessionChallenge": "staleSession",
                "stalePolicyResponse": "stalePolicy",
                "secondConsumption": "alreadyConsumed",
            ]
        )

        let valid = contract.validOwnerAuthorization
        let challenge = SessionChallenge.ownerAuthorization(
            context: ChallengeContext(
                challengeID: valid.challengeID,
                sessionID: valid.sessionID,
                attemptID: valid.attemptID,
                policyGeneration: valid.policyGeneration,
                expiresAt: Date(timeIntervalSince1970: valid.expiresAt)
            ),
            reasonCode: valid.reasonCode
        )
        XCTAssertNoThrow(try challenge.validate(now: Date(timeIntervalSince1970: valid.now)))
    }

    func testGrantIsExactScopeAndOneShot() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let engine = DeviceAccessGrantEngine(now: { now })
        let attempt = UUID()
        let scope = OwnerAuthorizationScope(
            routeIdentity: "alice@host:22/ssh",
            hostID: UUID(),
            publicKeyFingerprint: "SHA256:key"
        )
        let request = OwnerAuthorizationRequest(
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            expiresAt: now.addingTimeInterval(30)
        )
        let fresh = FreshOwnerAuthorization(
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )
        let capability = try await engine.mint(from: fresh, expected: request)
        try await engine.consume(
            capability,
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope
        )
        do {
            try await engine.consume(
                capability,
                attemptID: attempt,
                policyGeneration: 8,
                scope: scope
            )
            XCTFail("expected a consumed capability to fail")
        } catch {
            XCTAssertEqual(error as? OwnerAuthorizationError, .alreadyConsumed)
        }
    }

    func testFreshOwnerAuthorizationIsOneShotAndAgeBound() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let clock = AuthorizationTestClock(now)
        let engine = DeviceAccessGrantEngine(now: { clock.value })
        let attempt = UUID()
        let scope = OwnerAuthorizationScope(
            routeIdentity: "alice@host:22/ssh",
            hostID: UUID(),
            publicKeyFingerprint: "SHA256:key"
        )
        let request = OwnerAuthorizationRequest(
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            expiresAt: now.addingTimeInterval(30)
        )
        let token = UUID()
        let fresh = FreshOwnerAuthorization(
            token: token,
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            issuedAt: now,
            expiresAt: request.expiresAt
        )

        _ = try await engine.mint(from: fresh, expected: request)
        await XCTAssertThrowsErrorAsync(
            try await engine.mint(from: fresh, expected: request),
            equals: OwnerAuthorizationError.alreadyConsumed
        )

        clock.value = now.addingTimeInterval(31)
        let recycledRequest = OwnerAuthorizationRequest(
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            expiresAt: now.addingTimeInterval(60)
        )
        let recycled = FreshOwnerAuthorization(
            token: token,
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            issuedAt: clock.value,
            expiresAt: recycledRequest.expiresAt
        )
        await XCTAssertThrowsErrorAsync(
            try await engine.mint(from: recycled, expected: recycledRequest),
            equals: OwnerAuthorizationError.alreadyConsumed
        )
        clock.value = now

        let stale = FreshOwnerAuthorization(
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            issuedAt: now.addingTimeInterval(
                -DeviceAccessGrantEngine.maximumFreshAuthorizationAge - 1
            ),
            expiresAt: request.expiresAt
        )
        await XCTAssertThrowsErrorAsync(
            try await engine.mint(from: stale, expected: request),
            equals: OwnerAuthorizationError.notFresh
        )

        let future = FreshOwnerAuthorization(
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            issuedAt: now.addingTimeInterval(
                DeviceAccessGrantEngine.maximumAuthorizationFutureSkew + 1
            ),
            expiresAt: request.expiresAt
        )
        await XCTAssertThrowsErrorAsync(
            try await engine.mint(from: future, expected: request),
            equals: OwnerAuthorizationError.notFresh
        )

        let longRequest = OwnerAuthorizationRequest(
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            expiresAt: now.addingTimeInterval(
                DeviceAccessGrantEngine.maximumGrantLifetime + 1
            )
        )
        let longLived = FreshOwnerAuthorization(
            attemptID: attempt,
            policyGeneration: 8,
            scope: scope,
            issuedAt: now,
            expiresAt: longRequest.expiresAt
        )
        await XCTAssertThrowsErrorAsync(
            try await engine.mint(from: longLived, expected: longRequest),
            equals: OwnerAuthorizationError.lifetimeTooLong
        )
    }

    func testSessionGenerationDropsLateBytesAfterDisconnect() async throws {
        let capture = EventCapture()
        let engine = SessionEngine(eventSink: { capture.append($0) })
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        try await engine.handle(.connect(intent))
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        let oldGeneration = await engine.snapshot().0
        try await engine.handle(.disconnect)
        await engine.transportBytes(Data([0x41]), generation: oldGeneration)
        XCTAssertFalse(capture.events.contains { event in
            if case .terminalBytes = event { return true }
            return false
        })
    }

    func testSessionBackendPortReceivesTmuxLifecycleAndRepaintCommands() async throws {
        let capture = BackendCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { capture.append($0) },
            eventSink: { _ in }
        )
        try await engine.handle(.selectTmuxWindow("@7"))
        try await engine.handle(.selectTmuxPane("%9"))
        try await engine.handle(.sendTmuxPaneInput(
            data: Data([0x41]),
            paneID: "%9",
            receipt: nil
        ))
        try await engine.handle(.sendTmuxPaneKey(.enter, paneID: "%9", receipt: nil))
        try await engine.handle(.createTmuxWindow)
        try await engine.handle(.closeTmuxWindow("@7"))
        try await engine.handle(.closeTmuxPane("%9"))
        try await engine.handle(.splitTmuxPane("%9", axis: .horizontal, before: false))
        try await engine.handle(.cycleTmuxPane(forward: true))
        try await engine.handle(.setTmuxPaneZoomed("%9", zoomed: true))
        try await engine.handle(.renameTmuxWindow("@7", name: "work"))
        try await engine.handle(.setTmuxGridPresentation(.singlePane))
        try await engine.handle(.claimTmuxGridAuthority(
            reason: .forceRefresh,
            repaintEvenIfSame: true
        ))
        try await engine.handle(.reclaimTmuxGridAuthority(reason: .user))
        try await engine.handle(.completeTmuxGridAuthorityRepaint(generation: 12))
        try await engine.handle(.setFocused(true))
        try await engine.handle(.setApplicationVisibility(.background))
        try await engine.handle(.requestFullRepaint)

        XCTAssertEqual(capture.operations.map(\.kindCode), [
            "select_tmux_window",
            "select_tmux_pane",
            "send_tmux_pane_input",
            "send_tmux_pane_key",
            "create_tmux_window",
            "close_tmux_window",
            "close_tmux_pane",
            "split_tmux_pane",
            "cycle_tmux_pane",
            "set_tmux_pane_zoomed",
            "rename_tmux_window",
            "set_tmux_grid_presentation",
            "claim_tmux_grid_authority",
            "reclaim_tmux_grid_authority",
            "complete_tmux_grid_authority_repaint",
            "set_focused",
            "set_application_visibility",
            "request_full_repaint",
        ])
    }

    func testSessionEngineBoundsEveryTmuxMutationBeforeBackendDispatch() async throws {
        let backend = BackendCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { backend.append($0) },
            eventSink: { _ in }
        )
        let oversizedInput = Data(
            repeating: 0x41,
            count: SessionCommandLimits.maximumInputBytes + 1
        )
        let oversizedName = String(
            repeating: "a",
            count: SessionCommandLimits.maximumRenameUnicodeScalars + 1
        )
        let oversizedID = SessionCommandLimits.maximumTmuxObjectID + 1

        let invalidCommands: [SessionCommand] = [
            .resize(columns: SessionCommandLimits.maximumColumns + 1, rows: 24),
            .selectTmuxWindow("@\(oversizedID)"),
            .selectTmuxPane("%\(oversizedID)"),
            .sendTmuxPaneInput(data: oversizedInput, paneID: "%9", receipt: nil),
            .sendTmuxPaneKey(.enter, paneID: "not-a-pane", receipt: nil),
            .closeTmuxWindow("7"),
            .closeTmuxPane("9"),
            .splitTmuxPane("%-1", axis: .vertical, before: false),
            .setTmuxPaneZoomed("%\(oversizedID)", zoomed: true),
            .renameTmuxWindow("@7", name: oversizedName),
            .renameTmuxWindow("@7", name: "spoof\nname"),
        ]

        for command in invalidCommands {
            do {
                try await engine.handle(command)
                XCTFail("expected invalid command to be rejected: \(command)")
            } catch SessionEngineError.invalidGeometry {
                // Resize has its dedicated validation error.
            } catch SessionEngineError.invalidTmuxPayload {
                // Every tmux payload is rejected before reaching the backend.
            } catch {
                XCTFail("unexpected error \(error) for \(command)")
            }
        }
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testAcknowledgedCommandEmitsExactlyOneTerminalEvent() async throws {
        let events = EventCapture()
        let backend = BackendCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { backend.append($0) },
            eventSink: { events.append($0) }
        )
        let receipt = SessionCommandReceipt()
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)

        try await engine.handle(.connect(intent))
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        try await engine.handle(.sendTmuxPaneInput(
            data: Data([0x41]),
            paneID: "%9",
            receipt: receipt
        ))
        await engine.backendCommandCompleted(receipt: receipt, result: .succeeded)
        await engine.backendCommandCompleted(
            receipt: receipt,
            result: .failed(CoreFailure(code: "late_duplicate"))
        )

        XCTAssertEqual(commandCompletions(in: events.events), [
            SessionCommandCompletion(receipt: receipt, result: .succeeded),
        ])
    }

    func testDisconnectFailsPendingReceiptOnceAndIgnoresLateBackendCompletion() async throws {
        let events = EventCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { _ in },
            eventSink: { events.append($0) }
        )
        let receipt = SessionCommandReceipt()
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)

        try await engine.handle(.connect(intent))
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        try await engine.handle(.sendTmuxPaneKey(.escape, paneID: "%3", receipt: receipt))
        try await engine.handle(.disconnect)
        await engine.backendCommandCompleted(receipt: receipt, result: .succeeded)

        XCTAssertEqual(commandCompletions(in: events.events), [
            SessionCommandCompletion(
                receipt: receipt,
                result: .failed(CoreFailure(code: "session_disconnected"))
            ),
        ])
    }

    func testAcknowledgedCommandWithoutBackendFailsTerminallyInsteadOfHanging() async throws {
        let events = EventCapture()
        let engine = SessionEngine(eventSink: { events.append($0) })
        let receipt = SessionCommandReceipt()
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)

        try await engine.handle(.connect(intent))
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        try await engine.handle(.sendTmuxPaneKey(.enter, paneID: "%4", receipt: receipt))

        XCTAssertEqual(commandCompletions(in: events.events), [
            SessionCommandCompletion(
                receipt: receipt,
                result: .failed(CoreFailure(code: "backend_unconfigured"))
            ),
        ])
    }

    func testAcknowledgedPaneCommandRejectsWhileDisconnectedAndSecondDisconnectIsInert() async throws {
        let events = EventCapture()
        let backend = BackendCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { backend.append($0) },
            eventSink: { events.append($0) }
        )
        let receipt = SessionCommandReceipt()
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)

        try await engine.adoptTransportAttempt(intent)
        try await engine.transportDisconnected(attemptID: intent.requestID)
        do {
            try await engine.handle(.sendTmuxPaneKey(.enter, paneID: "%4", receipt: receipt))
            XCTFail("expected disconnected acknowledged command rejection")
        } catch {
            XCTAssertEqual(error as? SessionEngineError, .notConnected)
        }
        try await engine.transportDisconnected(attemptID: intent.requestID)

        XCTAssertTrue(backend.operations.isEmpty)
        XCTAssertEqual(commandCompletions(in: events.events), [
            SessionCommandCompletion(
                receipt: receipt,
                result: .failed(CoreFailure(code: "command_rejected"))
            ),
        ])
    }

    func testConnectDidNotStartDoesNotDuplicateRejectedAcknowledgedCommandCompletion() async throws {
        let events = EventCapture()
        let backend = BackendCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { backend.append($0) },
            eventSink: { events.append($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        let receipt = SessionCommandReceipt()

        try await engine.handle(.connect(intent))
        do {
            try await engine.handle(.sendTmuxPaneInput(
                data: Data([0x41]),
                paneID: "%4",
                receipt: receipt
            ))
            XCTFail("expected connecting acknowledged command rejection")
        } catch {
            XCTAssertEqual(error as? SessionEngineError, .notConnected)
        }
        try await engine.transportConnectDidNotStart(attemptID: intent.requestID)

        XCTAssertEqual(backend.operations.map(\.kindCode), ["connect"])
        XCTAssertEqual(commandCompletions(in: events.events), [
            SessionCommandCompletion(
                receipt: receipt,
                result: .failed(CoreFailure(code: "command_rejected"))
            ),
        ])
    }

    func testDisconnectFailsPendingReceiptsInAdmissionOrder() async throws {
        let events = EventCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { _ in },
            eventSink: { events.append($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        let first = SessionCommandReceipt()
        let second = SessionCommandReceipt()

        try await engine.handle(.connect(intent))
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        try await engine.handle(.sendTmuxPaneKey(.enter, paneID: "%4", receipt: first))
        try await engine.handle(.sendTmuxPaneInput(
            data: Data([0x41]),
            paneID: "%4",
            receipt: second
        ))
        try await engine.transportDisconnected(attemptID: intent.requestID)

        XCTAssertEqual(commandCompletions(in: events.events).map(\.receipt), [first, second])
    }

    func testFailureFailsPendingReceiptsInAdmissionOrder() async throws {
        let events = EventCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { _ in },
            eventSink: { events.append($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        let first = SessionCommandReceipt()
        let second = SessionCommandReceipt()

        try await engine.handle(.connect(intent))
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        try await engine.handle(.sendTmuxPaneKey(.escape, paneID: "%4", receipt: first))
        try await engine.handle(.sendTmuxPaneInput(
            data: Data([0x42]),
            paneID: "%4",
            receipt: second
        ))
        try await engine.transportFailed(
            CoreFailure(code: "transport_failed"),
            attemptID: intent.requestID
        )

        XCTAssertEqual(commandCompletions(in: events.events).map(\.receipt), [first, second])
    }

    func testPendingReceiptCapRejectsNewestCommandWithCorrelatedFailure() async throws {
        let events = EventCapture()
        let backend = BackendCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { backend.append($0) },
            eventSink: { events.append($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        try await engine.handle(.connect(intent))
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )

        for _ in 0..<SessionCommandLimits.maximumPendingReceipts {
            try await engine.handle(.sendTmuxPaneKey(
                .enter,
                paneID: "%4",
                receipt: SessionCommandReceipt()
            ))
        }
        let rejected = SessionCommandReceipt()
        do {
            try await engine.handle(.sendTmuxPaneKey(
                .escape,
                paneID: "%4",
                receipt: rejected
            ))
            XCTFail("expected pending receipt cap rejection")
        } catch {
            XCTAssertEqual(error as? SessionEngineError, .tooManyPendingReceipts)
        }

        XCTAssertEqual(
            backend.operations.count,
            SessionCommandLimits.maximumPendingReceipts + 1 // connect plus admitted receipts
        )
        XCTAssertEqual(commandCompletions(in: events.events), [
            SessionCommandCompletion(
                receipt: rejected,
                result: .failed(CoreFailure(code: "too_many_pending_commands"))
            ),
        ])
    }

    func testFailureInvalidatesGenerationAndDropsLateAttemptBytes() async throws {
        let capture = EventCapture()
        let engine = SessionEngine(eventSink: { capture.append($0) })
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 8)
        try await engine.handle(.connect(intent))
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        let connectedGeneration = await engine.snapshot().0
        try await engine.fail(CoreFailure(code: "network_lost"), attemptID: intent.requestID)
        let failedGeneration = await engine.snapshot().0

        XCTAssertNotEqual(failedGeneration, connectedGeneration)
        await engine.transportBytes(Data([0x41]), generation: connectedGeneration)
        await engine.transportBytes(Data([0x42]), generation: failedGeneration)
        XCTAssertFalse(capture.events.contains { event in
            if case .terminalBytes = event { return true }
            return false
        })
    }

    func testInitialGenerationAndAdoptedTransportAttemptAreProjected() async throws {
        let capture = EventCapture()
        let initial = SessionGeneration(rawValue: 41)
        let engine = SessionEngine(
            initialGeneration: initial,
            eventSink: { capture.append($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 9)

        try await engine.adoptTransportAttempt(intent)
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.0, initial)
        XCTAssertEqual(snapshot.1, .connected)
        XCTAssertEqual(capture.events.first, .stateChanged(
            generation: initial,
            state: .connecting(attemptID: intent.requestID)
        ))
    }

    func testSessionEngineRejectsUnsafeBackendChallengeBeforePublishing() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let capture = EventCapture()
        let engine = SessionEngine(
            now: { now },
            eventSink: { capture.append($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 9)
        try await engine.adoptTransportAttempt(intent)
        let generation = await engine.snapshot().0
        let invalid = SessionChallenge.ownerAuthorization(
            context: ChallengeContext(
                sessionID: await engine.sessionID,
                attemptID: intent.requestID,
                policyGeneration: intent.policyGeneration,
                expiresAt: now.addingTimeInterval(30)
            ),
            reasonCode: "authorize\nspoof"
        )

        await XCTAssertThrowsErrorAsync(
            try await engine.challenge(invalid, generation: generation),
            equals: ChallengeValidationError.invalidDisplayMetadata(field: "reasonCode")
        )
        XCTAssertFalse(capture.events.contains { event in
            if case .challenge = event { return true }
            return false
        })
    }

    func testSessionEngineOwnsExactOneShotChallengeLifecycle() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let events = EventCapture()
        let backend = BackendCapture()
        let sessionID = UUID()
        let engine = SessionEngine(
            sessionID: sessionID,
            backendPorts: SessionBackendPorts { backend.append($0) },
            now: { now },
            eventSink: { events.append($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 7)
        try await engine.adoptTransportAttempt(intent)
        let generation = await engine.snapshot().0
        let context = ChallengeContext(
            sessionID: sessionID,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            expiresAt: now.addingTimeInterval(30)
        )
        let challenge = SessionChallenge.ownerAuthorization(
            context: context,
            reasonCode: "install_key"
        )

        try await engine.challenge(challenge, generation: generation)
        await XCTAssertThrowsErrorAsync(
            try await engine.challenge(challenge, generation: generation),
            equals: ChallengeValidationError.duplicateChallenge
        )

        let response = ChallengeResponse(
            challengeID: context.challengeID,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            decision: .approve
        )
        try await engine.handle(.submitChallengeResponse(response))
        await XCTAssertThrowsErrorAsync(
            try await engine.handle(.submitChallengeResponse(response)),
            equals: ChallengeValidationError.alreadyConsumed
        )
        await XCTAssertThrowsErrorAsync(
            try await engine.handle(.submitChallengeResponse(ChallengeResponse(
                challengeID: UUID(),
                attemptID: intent.requestID,
                policyGeneration: intent.policyGeneration,
                decision: .reject
            ))),
            equals: ChallengeValidationError.unknownChallenge
        )

        XCTAssertEqual(backend.operations.map(\.kindCode), ["submit_challenge_response"])
        XCTAssertTrue(events.events.contains(.challenge(
            generation: generation,
            challenge: challenge
        )))
    }

    func testSessionEngineRejectsExpiredAndStaleChallengeResponsesBeforeBackend() async throws {
        let initialNow = Date(timeIntervalSince1970: 100)
        let clock = AuthorizationTestClock(initialNow)
        let backend = BackendCapture()
        let sessionID = UUID()
        let engine = SessionEngine(
            sessionID: sessionID,
            backendPorts: SessionBackendPorts { backend.append($0) },
            now: { clock.value },
            eventSink: { _ in }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 8)
        try await engine.adoptTransportAttempt(intent)
        let generation = await engine.snapshot().0
        let context = ChallengeContext(
            sessionID: sessionID,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            expiresAt: initialNow.addingTimeInterval(1)
        )
        try await engine.challenge(
            .credential(context: context, credentialID: UUID(), kind: "password"),
            generation: generation
        )

        await XCTAssertThrowsErrorAsync(
            try await engine.handle(.submitChallengeResponse(ChallengeResponse(
                challengeID: context.challengeID,
                attemptID: UUID(),
                policyGeneration: intent.policyGeneration,
                decision: .approve
            ))),
            equals: ChallengeValidationError.staleAttempt
        )
        await XCTAssertThrowsErrorAsync(
            try await engine.handle(.submitChallengeResponse(ChallengeResponse(
                challengeID: context.challengeID,
                attemptID: intent.requestID,
                policyGeneration: intent.policyGeneration + 1,
                decision: .approve
            ))),
            equals: ChallengeValidationError.stalePolicy
        )

        clock.value = initialNow.addingTimeInterval(2)
        await XCTAssertThrowsErrorAsync(
            try await engine.handle(.submitChallengeResponse(ChallengeResponse(
                challengeID: context.challengeID,
                attemptID: intent.requestID,
                policyGeneration: intent.policyGeneration,
                decision: .approve
            ))),
            equals: ChallengeValidationError.expired
        )
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testSessionEngineRejectsWrongSessionAndInvalidatesChallengesOnDisconnect() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let backend = BackendCapture()
        let sessionID = UUID()
        let engine = SessionEngine(
            sessionID: sessionID,
            backendPorts: SessionBackendPorts { backend.append($0) },
            now: { now },
            eventSink: { _ in }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 9)
        try await engine.adoptTransportAttempt(intent)
        let generation = await engine.snapshot().0
        let wrongSession = SessionChallenge.ownerAuthorization(
            context: ChallengeContext(
                sessionID: UUID(),
                attemptID: intent.requestID,
                policyGeneration: intent.policyGeneration,
                expiresAt: now.addingTimeInterval(30)
            ),
            reasonCode: "install_key"
        )
        await XCTAssertThrowsErrorAsync(
            try await engine.challenge(wrongSession, generation: generation),
            equals: ChallengeValidationError.staleSession
        )

        let context = ChallengeContext(
            sessionID: sessionID,
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration,
            expiresAt: now.addingTimeInterval(30)
        )
        try await engine.challenge(
            .ownerAuthorization(context: context, reasonCode: "install_key"),
            generation: generation
        )
        try await engine.transportDisconnected(attemptID: intent.requestID)
        try await engine.adoptTransportAttempt(intent)

        await XCTAssertThrowsErrorAsync(
            try await engine.handle(.submitChallengeResponse(ChallengeResponse(
                challengeID: context.challengeID,
                attemptID: intent.requestID,
                policyGeneration: intent.policyGeneration,
                decision: .approve
            ))),
            equals: ChallengeValidationError.unknownChallenge
        )
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testBackendDisconnectIsIdempotentAndBumpsGenerationOnce() async throws {
        let capture = EventCapture()
        let engine = SessionEngine(eventSink: { capture.append($0) })
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 2)
        try await engine.adoptTransportAttempt(intent)
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        let connectedGeneration = await engine.snapshot().0

        try await engine.transportDisconnected(attemptID: intent.requestID)
        let first = await engine.snapshot()
        try await engine.transportDisconnected(attemptID: intent.requestID)
        let second = await engine.snapshot()

        XCTAssertEqual(first.1, .disconnected)
        XCTAssertEqual(first.0.rawValue, connectedGeneration.rawValue + 1)
        XCTAssertEqual(second.0, first.0)
        XCTAssertEqual(capture.events.filter {
            if case .stateChanged(_, .disconnected) = $0 { return true }
            return false
        }.count, 1)
    }

    func testDelayedDisconnectFromAttemptACannotTearDownActiveAttemptB() async throws {
        let capture = EventCapture()
        let engine = SessionEngine(eventSink: { capture.append($0) })
        let first = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        let second = ConnectionIntent(hostID: first.hostID, policyGeneration: 2)

        try await engine.adoptTransportAttempt(first)
        try await engine.transportConnected(
            attemptID: first.requestID,
            policyGeneration: first.policyGeneration
        )
        try await engine.transportDisconnected(attemptID: first.requestID)
        try await engine.adoptTransportAttempt(second)
        try await engine.transportConnected(
            attemptID: second.requestID,
            policyGeneration: second.policyGeneration
        )
        let beforeStaleReport = await engine.snapshot()

        await XCTAssertThrowsErrorAsync(
            try await engine.transportDisconnected(attemptID: first.requestID),
            equals: SessionEngineError.staleAttempt
        )

        let afterStaleReport = await engine.snapshot()
        XCTAssertEqual(afterStaleReport.0, beforeStaleReport.0)
        XCTAssertEqual(afterStaleReport.1, .connected)
        try await engine.transportDisconnected(attemptID: second.requestID)
        let afterCurrentReport = await engine.snapshot()
        XCTAssertEqual(afterCurrentReport.1, .disconnected)
        XCTAssertEqual(capture.events.filter {
            if case .stateChanged(_, .disconnected) = $0 { return true }
            return false
        }.count, 2)
    }

    func testDuplicateBackendConnectedProjectionIsIdempotent() async throws {
        let capture = EventCapture()
        let engine = SessionEngine(eventSink: { capture.append($0) })
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 3)
        try await engine.adoptTransportAttempt(intent)

        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )

        XCTAssertEqual(capture.events.filter {
            if case .stateChanged(_, .connected) = $0 { return true }
            return false
        }.count, 1)
    }

    func testConnectDidNotStartReturnsToIdleWithoutBumpingGeneration() async throws {
        let capture = EventCapture()
        let backend = BackendCapture()
        let engine = SessionEngine(
            backendPorts: SessionBackendPorts { backend.append($0) },
            eventSink: { capture.append($0) }
        )
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 3)

        try await engine.handle(.connect(intent))
        let connecting = await engine.snapshot()
        try await engine.transportConnectDidNotStart(attemptID: intent.requestID)
        let idle = await engine.snapshot()

        XCTAssertEqual(connecting.0, idle.0)
        XCTAssertEqual(idle.1, .idle)
        XCTAssertEqual(backend.operations.map(\.kindCode), ["connect"])
        XCTAssertEqual(capture.events.compactMap { event -> SharedSessionState? in
            guard case .stateChanged(_, let state) = event else { return nil }
            return state
        }, [
            .connecting(attemptID: intent.requestID),
            .idle,
        ])
    }

    func testConnectDidNotStartReleasesAttemptForRetry() async throws {
        let engine = SessionEngine(eventSink: { _ in })
        let first = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        let second = ConnectionIntent(hostID: first.hostID, policyGeneration: 2)

        try await engine.handle(.connect(first))
        try await engine.transportConnectDidNotStart(attemptID: first.requestID)
        try await engine.handle(.connect(second))

        let snapshot = await engine.snapshot()
        XCTAssertEqual(
            snapshot.1,
            .connecting(attemptID: second.requestID)
        )
    }

    func testStaleConnectDidNotStartCannotRewindNewAttempt() async throws {
        let engine = SessionEngine(eventSink: { _ in })
        let first = ConnectionIntent(hostID: UUID(), policyGeneration: 1)
        let second = ConnectionIntent(hostID: first.hostID, policyGeneration: 2)
        try await engine.handle(.connect(first))
        try await engine.transportConnectDidNotStart(attemptID: first.requestID)
        try await engine.handle(.connect(second))

        await XCTAssertThrowsErrorAsync(
            try await engine.transportConnectDidNotStart(attemptID: first.requestID),
            equals: SessionEngineError.staleAttempt
        )

        let snapshot = await engine.snapshot()
        XCTAssertEqual(
            snapshot.1,
            .connecting(attemptID: second.requestID)
        )
    }

    func testConnectedTransportPreservesEmptyOutputChunkBoundary() async throws {
        let capture = EventCapture()
        let engine = SessionEngine(eventSink: { capture.append($0) })
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 4)
        try await engine.adoptTransportAttempt(intent)
        try await engine.transportConnected(
            attemptID: intent.requestID,
            policyGeneration: intent.policyGeneration
        )
        let generation = await engine.snapshot().0

        await engine.transportBytes(Data(), generation: generation)

        XCTAssertTrue(capture.events.contains(
            .terminalBytes(generation: generation, bytes: Data())
        ))
    }

    func testBackendFailureRejectsStaleAttemptWithoutInvalidatingActiveOne() async throws {
        let engine = SessionEngine(eventSink: { _ in })
        let intent = ConnectionIntent(hostID: UUID(), policyGeneration: 5)
        try await engine.adoptTransportAttempt(intent)
        let before = await engine.snapshot()

        await XCTAssertThrowsErrorAsync(
            try await engine.transportFailed(
                CoreFailure(code: "late_failure"),
                attemptID: UUID()
            ),
            equals: SessionEngineError.staleAttempt
        )
        let after = await engine.snapshot()
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)

        try await engine.transportFailed(
            CoreFailure(code: "active_failure"),
            attemptID: intent.requestID
        )
        let failed = await engine.snapshot()
        XCTAssertEqual(failed.0.rawValue, before.0.rawValue + 1)
        XCTAssertEqual(failed.1, .failed(CoreFailure(code: "active_failure")))
    }
}

private func commandCompletions(in events: [SessionEvent]) -> [SessionCommandCompletion] {
    events.compactMap { event in
        guard case .commandCompleted(_, let receipt, let result) = event else { return nil }
        return SessionCommandCompletion(receipt: receipt, result: result)
    }
}

private final class EventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SessionEvent] = []

    var events: [SessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: SessionEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private final class AuthorizationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ value: Date) { storage = value }

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class BackendCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SessionBackendOperation] = []

    var operations: [SessionBackendOperation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ operation: SessionBackendOperation) {
        lock.lock()
        storage.append(operation)
        lock.unlock()
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
