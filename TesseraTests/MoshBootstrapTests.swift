import XCTest
import TesseraCore
import TesseraSessionCore
import TmuxControlCore
import TmuxControl
@testable import Tessera

final class MoshBootstrapTests: XCTestCase {

    func test_tmuxLaunchEnablesMouseOnWorkAndViewIncludingCompactReconnect() {
        let host = Host(address: "example.com", user: "alice", launchMode: .pinnedTmux, tmuxSessionName: "shared")
        let geometry = MoshBootstrapGeometry(
            sessionID: "$7", sessionCreated: 1_721_234_567, windowID: "@11", cols: 132, rows: 44
        )
        let cases: [(Bool, MoshBootstrapGeometry?)] = [(false, nil), (true, nil), (true, geometry)]
        for (preservesGeometry, existingGeometry) in cases {
            let command = MoshBootstrap.launchCommand(
                for: host, preserveTmuxGeometry: preservesGeometry, preservedTmuxGeometry: existingGeometry
            )!
            XCTAssertTrue(command.contains("mouse on"), command)
            let view = existingGeometry == nil ? "shared-tessera-view" : "$7"
            XCTAssertTrue(command.contains("set-option -t '\\''\(view)'\\'' mouse on"), command)
            XCTAssertFalse(command.contains("set-option -g"), command)
            if existingGeometry != nil {
                XCTAssertTrue(command.contains("#{session_group}"), command)
                guard let verify = command.range(of: "$7,1721234567,@11,132,44", options: .backwards),
                      let mouse = command.range(of: "tessera_tmux_mouse_owner=") else {
                    XCTFail(command)
                    continue
                }
                XCTAssertLessThan(verify.upperBound, mouse.lowerBound)
            }
        }
    }

    @MainActor
    func test_agentReadCarrierCoalescesRecoveryAndKeepsOtherWaitersWhenOneCancels() async throws {
        let started = expectation(description: "one authentication")
        let gate = MoshAgentCarrierTestGate(started: started)
        let carrier = MoshAgentReadCarrier<Int>(close: { _ in })
        let first = Task { try await carrier.acquire(isUsable: { _ in true }) { await gate.open() } }
        await fulfillment(of: [started], timeout: 2)
        let secondStarted = expectation(description: "second waiter entered")
        let second = Task {
            secondStarted.fulfill()
            return try await carrier.acquire(isUsable: { _ in true }) { await gate.open() }
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        first.cancel()
        do { _ = try await first.value; XCTFail("cancelled waiter succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        await gate.release(7)
        let lease = try await second.value
        XCTAssertEqual(lease.value, 7)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(carrier.current?.id, lease.id)
        carrier.reset()
    }

    @MainActor
    func test_agentReadCarrierDeadlineClosesLateAuthenticationWithoutReplacingNewLease() async throws {
        let started = expectation(description: "blocked authentication")
        let closed = expectation(description: "late route closed")
        let gate = MoshAgentCarrierTestGate(started: started)
        let carrier = MoshAgentReadCarrier<Int>(deadline: .milliseconds(20), retryDelay: .zero,
            close: { if $0 == 1 { closed.fulfill() } })
        let first = Task { try await carrier.acquire(isUsable: { _ in true }) { await gate.open() } }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await first.value; XCTFail("deadline did not fire") }
        catch { XCTAssertEqual(error as? AgentProjectionError, .channelUnavailable) }
        let fresh = try await carrier.acquire(isUsable: { _ in true }) { 2 }
        await gate.release(1)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(carrier.current?.id, fresh.id)
        carrier.invalidate(UUID())
        XCTAssertEqual(carrier.current?.value, 2, "late failure cannot retire a different lease")
        carrier.reset()
    }

    @MainActor
    func test_agentReadCarrierDisconnectCancelsRenewalAndDisposesLateRoute() async throws {
        let started = expectation(description: "authentication started")
        let closed = expectation(description: "route arriving after disconnect closed")
        let gate = MoshAgentCarrierTestGate(started: started)
        let carrier = MoshAgentReadCarrier<Int>(close: { _ in closed.fulfill() })
        let pending = Task { try await carrier.acquire(isUsable: { _ in true }) { await gate.open() } }
        await fulfillment(of: [started], timeout: 2)
        carrier.reset()
        do { _ = try await pending.value; XCTFail("disconnected waiter succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        await gate.release(1)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertNil(carrier.current)
    }

    @MainActor
    func test_agentReadCarrierLastWaiterCancellationRetiresAuthentication() async throws {
        let started = expectation(description: "authentication started")
        let closed = expectation(description: "late cancelled route closed")
        let gate = MoshAgentCarrierTestGate(started: started)
        let carrier = MoshAgentReadCarrier<Int>(close: { _ in closed.fulfill() })
        let pending = Task { try await carrier.acquire(isUsable: { _ in true }) { await gate.open() } }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("cancelled waiter succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        await gate.release(1)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertNil(carrier.current)
    }

    @MainActor
    func test_agentReadCarrierBacksOffAfterFailedAuthentication() async {
        let carrier = MoshAgentReadCarrier<Int>(retryDelay: .seconds(60), close: { _ in })
        do {
            _ = try await carrier.acquire(isUsable: { _ in true }) { throw AgentProjectionError.channelUnavailable }
            XCTFail("failed authentication succeeded")
        } catch {}
        do {
            _ = try await carrier.acquire(isUsable: { _ in true }) { XCTFail("authentication storm"); return 1 }
            XCTFail("cooldown did not apply")
        } catch { XCTAssertEqual(error as? AgentProjectionError, .channelUnavailable) }
        carrier.reset()
    }

    @MainActor
    func test_agentReadCarrierRenewsDeadRouteButReusesHealthyRoute() async throws {
        let closed = expectation(description: "dead route closed")
        let carrier = MoshAgentReadCarrier<Int>(close: { if $0 == 1 { closed.fulfill() } })
        carrier.replace(with: 1)
        let fresh = try await carrier.acquire(isUsable: { $0 != 1 }) { 2 }
        let reused = try await carrier.acquire(isUsable: { _ in true }) { XCTFail("unnecessary authentication"); return 3 }
        XCTAssertEqual(fresh.id, reused.id)
        XCTAssertEqual(reused.value, 2)
        await fulfillment(of: [closed], timeout: 2)
        carrier.reset()
    }

    @MainActor
    func test_agentReadHandleRejectsFrameCompletingAfterCarrierReplacement() async throws {
        let started = expectation(description: "waiting for frame")
        let gate = MoshAgentCarrierTestGate(started: started)
        var current = true
        let handle = MoshAgentReadExecHandle(
            base: MoshAgentCarrierTestExecHandle(gate: gate),
            isCurrent: { current }, failed: { _ in }
        )
        let read = Task { try await handle.nextFrame() }
        await fulfillment(of: [started], timeout: 2)
        current = false
        await gate.release(1)
        do { _ = try await read.value; XCTFail("stale frame accepted") }
        catch { XCTAssertEqual(error as? AppleAgentPlatformError, .staleBinding) }
    }

    @MainActor
    func test_agentReadRouteAllowsCredentialRotationButRejectsAccountEndpointAndJumpChanges() {
        let bastion = Host(address: "bastion.test", user: "relay")
        let original = Host(address: "host.test", user: "alice", jumpChain: [bastion])
        var edited = original
        edited.storedKeyID = UUID()
        XCTAssertTrue(MoshSession.isSameAgentReadRoute(original, edited))
        edited.user = "bob"
        XCTAssertFalse(MoshSession.isSameAgentReadRoute(original, edited))
        edited = original; edited.address = "other.test"
        XCTAssertFalse(MoshSession.isSameAgentReadRoute(original, edited))
        edited = original; edited.port = 2222
        XCTAssertFalse(MoshSession.isSameAgentReadRoute(original, edited))
        edited = original; edited.jumpChain = []
        XCTAssertFalse(MoshSession.isSameAgentReadRoute(original, edited))
        edited = original; edited.jumpChain[0].address = "other-bastion.test"
        XCTAssertFalse(MoshSession.isSameAgentReadRoute(original, edited))
        edited = original; edited.jumpChainBrokenReason = "deleted"
        XCTAssertFalse(MoshSession.isSameAgentReadRoute(original, edited))
    }

    @MainActor
    func test_controlChannelDeliversCompoundAttachThroughPOSIXShell() {
        let command = TmuxControlChannel.attachCommand(sessionName: "quoted' session")
        XCTAssertTrue(command.hasPrefix("if command -v tmux"))
        XCTAssertEqual(
            TmuxControlChannel.commandLine(command),
            "exec /bin/sh -c \(MoshBootstrapGrammar.singleQuotedShellString(command))\n"
        )
        XCTAssertFalse(TmuxControlChannel.commandLine(command).hasPrefix("exec if "))
    }

    func test_bootstrapCommand_autoTmuxUsesResolvedSessionName() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .autoTmux
        )

        let command = MoshBootstrap.bootstrapCommand(for: host) { _ in
            "tessera-auto1234"
        }

        XCTAssertEqual(
            command,
            MoshBootstrapGrammar.serverNewCommand(
                launchCommand: AutoTmuxCommands.moshVisibleClientCommand(sessionTarget: "tessera-auto1234", ignoresSize: false)
            )
        )
    }

    @MainActor
    func test_bootstrapCommand_visibleMoshTmuxClientCanIgnoreSize() {
        let host = Host(
            address: "example.test",
            user: "test",
            transport: .mosh,
            launchMode: .autoTmux
        )

        let command = MoshBootstrap.bootstrapCommand(
            for: host,
            visibleTmuxClientIgnoresSize: true
        ) { _ in
            "tessera-auto1234"
        }

        XCTAssertTrue(command.contains("exec mosh-server new -c 256 -- sh -lc "))
        XCTAssertTrue(command.contains("tmux -V 2>/dev/null"))
        XCTAssertTrue(command.contains("-f ignore-size"))
        XCTAssertTrue(command.contains("show-options -gv terminal-overrides"))
        // Both mosh clients join Tessera's own view of the session; the user's
        // session is only ever asked to exist. `bootstrapCommand` re-quotes the
        // launch argv for PATH resolution, so the exact quoting is asserted on
        // the single-layer `launchCommand` below.
        XCTAssertTrue(command.contains("tessera-auto1234-view"))
        XCTAssertTrue(
            TmuxControlChannel.attachCommand(sessionName: "tessera-auto1234")
                .contains("tmux -CC attach-session -t 'tessera-auto1234-view'")
        )
        let sideChannelCommand = TmuxControlChannel.attachCommand(
            sessionName: "tessera-auto1234",
            preserveTmuxGeometry: true
        )
        XCTAssertTrue(sideChannelCommand.contains("tmux -V 2>/dev/null"))
        XCTAssertTrue(sideChannelCommand.contains(
            "exec tmux -CC attach-session -f no-output,ignore-size -t 'tessera-auto1234-view'"
        ))
        XCTAssertTrue(sideChannelCommand.contains(
            "exec tmux -CC attach-session -t 'tessera-auto1234-view'"
        ))
        // The reported bug: `status` is a tmux *session* option, so setting it
        // on the session the user asked for hid the status line for every
        // client of that session, and kept it hidden after Tessera left.
        let launch = MoshBootstrap.launchCommand(
            for: host,
            visibleTmuxClientIgnoresSize: true
        ) { _ in "tessera-auto1234" } ?? ""
        XCTAssertTrue(launch.contains("-s '\\''tessera-auto1234-view'\\''"), launch)
        XCTAssertTrue(launch.contains("-t '\\''tessera-auto1234'\\''"), launch)
        XCTAssertFalse(launch.contains("-t '\\''tessera-auto1234'\\'' status"), launch)
        XCTAssertTrue(launch.contains("-t '\\''tessera-auto1234-view'\\'' status off"), launch)
    }

    func test_bootstrapCommand_tagsVisibleTmuxClientForSafeAutoReclaim() {
        let host = Host(
            address: "example.test",
            user: "test",
            transport: .mosh,
            launchMode: .autoTmux
        )
        let option = TmuxController.gridAuthorityVisibleClientOption(
            identityID: "DEVICE 123"
        )

        let command = MoshBootstrap.bootstrapCommand(
            for: host,
            visibleTmuxClientIgnoresSize: true,
            gridAuthorityDeviceID: "DEVICE 123"
        ) { _ in
            "tessera-auto1234"
        }

        XCTAssertEqual(option, "@tessera-visible-DEVICE-123")
        XCTAssertTrue(command.contains(option), command)
        XCTAssertTrue(
            command.contains("#{client_name}|#{client_pid}|#{client_created}"),
            command
        )

        let preservingNewSession = MoshBootstrap.bootstrapCommand(
            for: host,
            preserveTmuxGeometry: true,
            gridAuthorityDeviceID: "DEVICE 123"
        ) { _ in
            "tessera-auto1234"
        }
        XCTAssertTrue(preservingNewSession.contains(option), preservingNewSession)
        XCTAssertTrue(
            preservingNewSession.contains("set-option -F"),
            preservingNewSession
        )

        let preservingExistingSession = MoshBootstrap.bootstrapCommand(
            for: host,
            preserveTmuxGeometry: true,
            preservedTmuxGeometry: MoshBootstrapGeometry(
                sessionID: "$7",
                sessionCreated: 1_721_234_567,
                windowID: "@11",
                cols: 132,
                rows: 44
            ),
            gridAuthorityDeviceID: "DEVICE 123"
        )
        XCTAssertTrue(
            preservingExistingSession.contains(option),
            preservingExistingSession
        )
        XCTAssertTrue(
            preservingExistingSession.contains("attach-session $tessera_tmux_f"),
            preservingExistingSession
        )
    }

    func test_bootstrapCommand_geometryNeutralTmuxPreservesOnlyExistingSession() throws {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .autoTmux
        )

        // The launch argv is what `mosh-server new --` receives; the bootstrap
        // command wraps it in a further quoting layer for PATH resolution.
        let command = try XCTUnwrap(MoshBootstrap.launchCommand(
            for: host,
            preserveTmuxGeometry: true
        ) { _ in
            "tessera-auto1234"
        })
        XCTAssertTrue(
            MoshBootstrap.bootstrapCommand(for: host, preserveTmuxGeometry: true) { _ in "tessera-auto1234" }
                .contains("exec mosh-server new -c 256 -- sh -lc ")
        )

        XCTAssertFalse(command.contains("stty cols"))
        XCTAssertTrue(command.contains("then exit 75"))
        XCTAssertTrue(command.contains(
            "exec tmux -u new-session $tessera_tmux_f "
                + "-s '\\''tessera-auto1234-view'\\'' -t '\\''tessera-auto1234'\\''"
        ), command)
        // Joining work that already exists must not resize it to this compact
        // client; only a launch that started the owner may adopt the grid.
        XCTAssertTrue(command.contains(
            "else tmux -u new-session -d -s '\\''tessera-auto1234'\\''; "
                + "tessera_tmux_f='\\'''\\''; fi"
        ), command)
        XCTAssertTrue(command.contains(
            "@tessera-size-owner '\\''#{client_name}'\\''"
        ))
    }

    func test_bootstrapCommand_geometryNeutralExistingSessionWaitsForVerifiedMoshPTY() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .pinnedTmux,
            tmuxSessionName: "shared"
        )

        let command = MoshBootstrap.bootstrapCommand(
            for: host,
            preserveTmuxGeometry: true,
            preservedTmuxGeometry: MoshBootstrapGeometry(
                sessionID: "$7",
                sessionCreated: 1_721_234_567,
                windowID: "@11",
                cols: 132,
                rows: 44
            )
        )

        XCTAssertFalse(command.contains("stty cols"))
        XCTAssertTrue(command.contains("stty size 2>/dev/null"))
        XCTAssertTrue(command.contains("[ \"$1\" = \"44\" ]"))
        XCTAssertTrue(command.contains("[ \"$2\" = \"132\" ]"))
        XCTAssertTrue(command.contains("[ \"$attempts\" -lt 200 ]"))
        XCTAssertTrue(command.contains("matched=1"))
        XCTAssertTrue(command.contains("[ \"$matched\" = 1 ]"))
        XCTAssertTrue(command.contains("exit 77"))
        XCTAssertTrue(command.contains("attach-session $tessera_tmux_f -t"))
        XCTAssertTrue(command.contains("$7,1721234567,@11,132,44"))
        XCTAssertTrue(command.contains("show-options -gv terminal-overrides"))
        XCTAssertTrue(command.contains("@tessera-size-owner"))
        XCTAssertFalse(command.contains("refresh-client -C"))
    }

    func test_parsePreservedTmuxGeometryProbe() throws {
        XCTAssertEqual(
            try MoshBootstrap.parsePreservedTmuxGeometryProbe(
                "shell noise\ntessera-geometry:$2,1721234567,@4,120,40\n"
            ),
            MoshBootstrapGeometry(
                sessionID: "$2",
                sessionCreated: 1_721_234_567,
                windowID: "@4",
                cols: 120,
                rows: 40
            )
        )
        XCTAssertNil(try MoshBootstrap.parsePreservedTmuxGeometryProbe(
            "noise without newline before marker tessera-geometry:missing\n"
        ))
        XCTAssertThrowsError(
            try MoshBootstrap.parsePreservedTmuxGeometryProbe(
                "tessera-geometry:$2,1721234567,@4,0,40\n"
            )
        )
        XCTAssertThrowsError(
            try MoshBootstrap.parsePreservedTmuxGeometryProbe("not-a-probe\n")
        )
    }

    @MainActor
    func test_moshSessionPromotesCededGridIntoDurableRemoteHold() {
        let session = MoshSession(
            host: Host(address: "example.com", user: "alice"),
            preserveTmuxGeometry: true
        )

        XCTAssertNil(session.preservedRemoteTmuxSize)
        session.preserveRemoteTmuxSizeAfterCede(cols: 132, rows: 44)
        XCTAssertEqual(session.preservedRemoteTmuxSize?.cols, 132)
        XCTAssertEqual(session.preservedRemoteTmuxSize?.rows, 44)
    }

    func test_bootstrapCommand_pinnedTmuxUsesTrimmedPinnedName() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .pinnedTmux,
            tmuxSessionName: "  dev-session  "
        )

        let command = MoshBootstrap.bootstrapCommand(for: host) { _ in
            "tessera-fallback"
        }

        XCTAssertEqual(
            command,
            MoshBootstrapGrammar.serverNewCommand(
                launchCommand: AutoTmuxCommands.moshVisibleClientCommand(sessionTarget: "dev-session", ignoresSize: false)
            )
        )
    }

    func test_bootstrapCommand_pinnedTmuxFallsBackWhenNameIsEmpty() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .pinnedTmux,
            tmuxSessionName: "   "
        )

        let command = MoshBootstrap.bootstrapCommand(for: host) { _ in
            "tessera-fallback"
        }

        XCTAssertEqual(
            command,
            MoshBootstrapGrammar.serverNewCommand(
                launchCommand: AutoTmuxCommands.moshVisibleClientCommand(sessionTarget: "tessera-fallback", ignoresSize: false)
            )
        )
    }

    func test_bootstrapCommand_pinnedTmuxFallsBackWhenNameIsUnsafe() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .pinnedTmux,
            tmuxSessionName: "prod; rm -rf /"
        )

        let command = MoshBootstrap.bootstrapCommand(for: host) { _ in
            "tessera-fallback"
        }

        XCTAssertEqual(
            command,
            MoshBootstrapGrammar.serverNewCommand(
                launchCommand: AutoTmuxCommands.moshVisibleClientCommand(sessionTarget: "tessera-fallback", ignoresSize: false)
            )
        )
    }

    func test_bootstrapCommand_customCommandUsesSingleQuotedShellWrapper() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .customCommand,
            launchCommand: "printf 'hi'; echo done"
        )

        let command = MoshBootstrap.bootstrapCommand(for: host)

        XCTAssertEqual(
            command,
            MoshBootstrapGrammar.serverNewCommand(
                launchCommand: "sh -lc 'printf '\\''hi'\\''; echo done'"
            )
        )
    }

    func test_bootstrapCommand_emptyCustomCommandFallsBackToLoginShell() {
        let host = Host(
            address: "example.com",
            user: "alice",
            launchMode: .customCommand,
            launchCommand: ""
        )

        let command = MoshBootstrap.bootstrapCommand(for: host)

        XCTAssertEqual(command, MoshBootstrapGrammar.serverNewCommand(launchCommand: nil))
    }

    func test_parseConnectResponse_readsPortAndKey() throws {
        let result = try MoshBootstrap.parseConnectResponse(
            stdout: "MOSH CONNECT 60001 qiXpjXIk6M8/nWtBn9s6rQ\n"
        )

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_001,
            base64Key: "qiXpjXIk6M8/nWtBn9s6rQ",
            serverPID: nil,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_readsPortAndKeyFromStderr() throws {
        let result = try MoshBootstrap.parseConnectResponse(
            stdout: "",
            stderr: "MOSH CONNECT 60004 X8YJtMJsZL0ak6kBE4FmlA\n"
        )

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_004,
            base64Key: "X8YJtMJsZL0ak6kBE4FmlA",
            serverPID: nil,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_ignoresSurroundingNoise() throws {
        let stdout = """
        mosh-server (mosh 1.4.0)
        MOSH CONNECT 60002 8aBls0YgYKK/xIYqQ9uKJg
        mosh-server detached
        """

        let result = try MoshBootstrap.parseConnectResponse(stdout: stdout)

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_002,
            base64Key: "8aBls0YgYKK/xIYqQ9uKJg",
            serverPID: nil,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_normalizesOptionalPadding() throws {
        let result = try MoshBootstrap.parseConnectResponse(
            stdout: "MOSH CONNECT 60003 qiXpjXIk6M8/nWtBn9s6rQ==\n"
        )

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_003,
            base64Key: "qiXpjXIk6M8/nWtBn9s6rQ",
            serverPID: nil,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_readsRealServerTranscript() throws {
        let stdout = """
        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
        License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
        This is free software: you are free to change and redistribute it.
        There is NO WARRANTY, to the extent permitted by law.

        [mosh-server detached, pid = 111904]
        MOSH CONNECT 60001 qiXpjXIk6M8/nWtBn9s6rQ
        """

        let result = try MoshBootstrap.parseConnectResponse(stdout: stdout)

        XCTAssertEqual(result, MoshBootstrapResult(
            udpPort: 60_001,
            base64Key: "qiXpjXIk6M8/nWtBn9s6rQ",
            serverPID: 111_904,
            detectedOSHint: nil
        ))
    }

    func test_parseConnectResponse_throwsWhenLineMissing() {
        XCTAssertThrowsError(
            try MoshBootstrap.parseConnectResponse(stdout: "mosh-server ready\n")
        ) { error in
            XCTAssertEqual(
                error as? MoshBootstrapError,
                .missingConnect
            )
        }
    }

    func test_parseConnectResponse_throwsWhenPortIsMalformed() {
        let stdout = "MOSH CONNECT nope qiXpjXIk6M8/nWtBn9s6rQ\n"

        XCTAssertThrowsError(
            try MoshBootstrap.parseConnectResponse(stdout: stdout)
        ) { error in
            XCTAssertEqual(
                error as? MoshBootstrapError,
                .malformedConnect
            )
        }
    }

    func test_parseConnectResponse_throwsWhenKeyIsMalformed() {
        let stdout = "MOSH CONNECT 60003 ***\n"

        XCTAssertThrowsError(
            try MoshBootstrap.parseConnectResponse(stdout: stdout)
        ) { error in
            XCTAssertEqual(
                error as? MoshBootstrapError,
                .malformedConnect
            )
        }
    }
}

final class PrivateKeyAuditMoshCredentialRedactionTests: XCTestCase {
    private let sessionKey = "qiXpjXIk6M8/nWtBn9s6rQ"

    func test_PK009_redactorRemovesConnectKeyFromMultilineText() {
        let text = "before\nMOSH CONNECT 60001 \(sessionKey)\nafter"

        let redacted = SensitiveDataRedactor.redact(text)

        XCTAssertFalse(redacted.contains(sessionKey))
        XCTAssertTrue(redacted.contains("MOSH CONNECT 60001 <redacted>"))
    }

    func test_PK009_redactorDoesNotPreserveKeyInMalformedPortPosition() {
        let keyFirst = SensitiveDataRedactor.redact(
            "failure MOSH CONNECT \(sessionKey) malformed"
        )
        let keyOnly = SensitiveDataRedactor.redact(
            "failure MOSH CONNECT \(sessionKey)"
        )

        XCTAssertFalse(keyFirst.contains(sessionKey))
        XCTAssertFalse(keyOnly.contains(sessionKey))
        XCTAssertEqual(keyFirst, "failure MOSH CONNECT <redacted>")
        XCTAssertEqual(keyOnly, "failure MOSH CONNECT <redacted>")
    }

    func test_PK009_redactorPreservesOnlyValidatedPort() {
        let valid = SensitiveDataRedactor.redact(
            "MOSH CONNECT 65535 \(sessionKey) trailing-noise"
        )
        let zero = SensitiveDataRedactor.redact(
            "MOSH CONNECT 0 \(sessionKey)"
        )
        let tooLarge = SensitiveDataRedactor.redact(
            "MOSH CONNECT 65536 \(sessionKey)"
        )

        XCTAssertEqual(valid, "MOSH CONNECT 65535 <redacted>")
        XCTAssertEqual(zero, "MOSH CONNECT <redacted>")
        XCTAssertEqual(tooLarge, "MOSH CONNECT <redacted>")
    }

    func test_PK009_redactorRemovesSplitAndEncodedBareKeys() {
        let split = SensitiveDataRedactor.redact(
            "MOSH CONNECT 60001\n\(sessionKey)"
        )
        let padded = SensitiveDataRedactor.redact(
            "native failure payload=\(sessionKey)=="
        )
        let escapedNewline = SensitiveDataRedactor.redact(
            "wrapped=MOSH CONNECT 60001\\n\(sessionKey)"
        )

        XCTAssertFalse(split.contains(sessionKey))
        XCTAssertFalse(padded.contains(sessionKey))
        XCTAssertFalse(escapedNewline.contains(sessionKey))
        XCTAssertEqual(split, "MOSH CONNECT <redacted>\n<redacted-key>")
        XCTAssertEqual(padded, "native failure payload=<redacted-key>")
        XCTAssertEqual(escapedNewline, "wrapped=MOSH CONNECT <redacted>")
    }

    func test_PK009_diagnosticBoundaryRemovesBareNativeKeyPayload() {
        let sanitized = DiagnosticLogStore.sanitizedMessageForTesting(
            "session failed message=Unexpected output from base64_encode: \(sessionKey)=="
        )

        XCTAssertFalse(sanitized.contains(sessionKey))
        XCTAssertTrue(sanitized.contains("message=Unexpected output from base64_encode"))
        XCTAssertTrue(sanitized.contains("<redacted-key>"))
    }

    func test_agentCenterDiagnosticBoundaryRedactsContentBearingFields() {
        let sanitized = DiagnosticLogStore.sanitizedMessageForTesting(
            "send sid=ABCDEF12 pane=7 provider=claude command='secret command' payload='secret prompt' path=/private/secret env=TOKEN-secret result=failed"
        )

        XCTAssertTrue(sanitized.contains("sid=ABCDEF12"))
        XCTAssertTrue(sanitized.contains("pane=7"))
        XCTAssertTrue(sanitized.contains("provider=claude"))
        XCTAssertFalse(sanitized.contains("secret command"))
        XCTAssertFalse(sanitized.contains("secret prompt"))
        XCTAssertFalse(sanitized.contains("/private/secret"))
        XCTAssertFalse(sanitized.contains("TOKEN-secret"))
    }

    func test_PK009_malformedParserErrorRetainsNoBootstrapTranscript() {
        let transcript = "MOSH CONNECT nope \(sessionKey)\n"

        XCTAssertThrowsError(try MoshBootstrap.parseConnectResponse(stdout: transcript)) { error in
            XCTAssertEqual(error as? MoshBootstrapError, .malformedConnect)
            XCTAssertFalse(String(describing: error).contains(sessionKey))
            XCTAssertFalse(error.localizedDescription.contains(sessionKey))
        }
    }

    func test_PK009_missingParserErrorRetainsNoStderrTranscript() {
        let stderr = "diagnostic MOSH CONNECT\nsecret=\(sessionKey)"

        XCTAssertThrowsError(
            try MoshBootstrap.parseConnectResponse(stdout: "", stderr: stderr)
        ) { error in
            XCTAssertEqual(error as? MoshBootstrapError, .missingConnect)
            XCTAssertFalse(String(describing: error).contains(sessionKey))
            XCTAssertFalse(error.localizedDescription.contains(sessionKey))
        }
    }

    func test_PK009_transcriptSummaryContainsOnlyBoundedMetadata() {
        let summary = SensitiveDataRedactor.bootstrapTranscriptSummary(
            stdout: "MOSH CONNECT 60001 \(sessionKey)",
            stderr: sessionKey
        )

        XCTAssertFalse(summary.contains(sessionKey))
        XCTAssertEqual(summary, "stdoutBytes=41 stderrBytes=22 connectMarker=true")
    }
}

#if DEBUG
final class PrivateKeyAuditMoshCredentialLifetimeTests: XCTestCase {
    func test_PK011_driverReleasesSwiftAndNativeBootstrapKeyAtHandoff() {
        let driver = MoshTransportDriver(
            host: "127.0.0.1",
            diagnosticHostID: UUID(),
            udpPort: 60_004,
            base64Key: "qiXpjXIk6M8/nWtBn9s6rQ",
            onOutput: { _, _, _, _ in },
            onConnected: {},
            onDisconnected: {},
            onFailed: { _ in },
            onTransportReachabilityChanged: { _ in }
        )

        let retainedBeforeConnect = driver.retainsBootstrapKeyMaterialForTesting()
        XCTAssertTrue(retainedBeforeConnect)
        driver.connect()
        let retainedAfterHandoff = driver.retainsBootstrapKeyMaterialForTesting()
        XCTAssertFalse(retainedAfterHandoff)
        driver.disconnect()
        let retainedAfterDisconnect = driver.retainsBootstrapKeyMaterialForTesting()
        XCTAssertFalse(retainedAfterDisconnect)
    }
}
#endif

#if DEBUG
final class PrivateKeyAuditDevRawKeyMigrationTests: XCTestCase {
    func test_PK012_sourceRemovalRequiresVerifiedKeychainAndSavedModels() {
        XCTAssertFalse(
            DevRawKeyMigrationVerification.mayRemoveSource(
                keychainVerified: false,
                modelSaveSucceeded: true
            )
        )
        XCTAssertFalse(
            DevRawKeyMigrationVerification.mayRemoveSource(
                keychainVerified: true,
                modelSaveSucceeded: false
            )
        )
        XCTAssertTrue(
            DevRawKeyMigrationVerification.mayRemoveSource(
                keychainVerified: true,
                modelSaveSucceeded: true
            )
        )
    }

    func test_PK012_keychainReadbackComparisonRejectsAnySeedDifference() {
        let seed = Data(repeating: 0xA5, count: 32)
        var different = seed
        different[31] ^= 0x01

        XCTAssertTrue(
            DevRawKeyMigrationVerification.storedSeedMatches(seed, expectedSeed: seed)
        )
        XCTAssertFalse(
            DevRawKeyMigrationVerification.storedSeedMatches(different, expectedSeed: seed)
        )
        XCTAssertFalse(
            DevRawKeyMigrationVerification.storedSeedMatches(nil, expectedSeed: seed)
        )
    }
}
#endif

final class HostTransportModelTests: XCTestCase {

    func test_persistedHostTransportDefaultsToSSH() {
        let persisted = PersistedHost()

        XCTAssertEqual(persisted.transportRaw, "ssh")
        XCTAssertEqual(persisted.transport, .ssh)
    }

    func test_persistedHostTransportFallsBackToSSHForUnknownRawValue() {
        let persisted = PersistedHost()
        persisted.transportRaw = "telnet"

        XCTAssertEqual(persisted.transport, .ssh)
    }

    func test_persistedHostTransportRoundTripsAndBridgesToHost() {
        let persisted = PersistedHost()
        persisted.transport = .mosh

        XCTAssertEqual(persisted.transportRaw, "mosh")
        XCTAssertEqual(persisted.transport, .mosh)
        XCTAssertEqual(Host(from: persisted).transport, .mosh)
    }

    func test_persistedHostConnectionKeyIncludesTransport() {
        let persisted = PersistedHost(
            address: "example.com",
            port: 2200,
            transport: .mosh
        )

        XCTAssertEqual(
            persisted.connectionKey,
            "mosh:@example.com:2200"
        )
    }
}

final class MoshInputNormalizerTests: XCTestCase {

    func test_normalizeArrowKeys_convertsCSIArrowsToSS3() {
        let bytes = Array("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D".utf8)

        let normalized = MoshInputNormalizer.normalizeArrowKeysForMosh(bytes)

        XCTAssertEqual(
            normalized,
            Array("\u{1B}OA\u{1B}OB\u{1B}OC\u{1B}OD".utf8)
        )
    }

    func test_normalizeArrowKeys_leavesSS3ArrowsUntouched() {
        let bytes = Array("\u{1B}OA\u{1B}OB".utf8)

        let normalized = MoshInputNormalizer.normalizeArrowKeysForMosh(bytes)

        XCTAssertEqual(normalized, bytes)
    }

    func test_normalizeArrowKeys_ignoresNonArrowEscapeSequences() {
        let bytes = Array("\u{1B}[200~hello\u{1B}[A".utf8)

        let normalized = MoshInputNormalizer.normalizeArrowKeysForMosh(bytes)

        XCTAssertEqual(
            normalized,
            Array("\u{1B}[200~hello\u{1B}OA".utf8)
        )
    }

    func test_terminalHardwareKeys_useStandardVTSequences() {
        XCTAssertEqual(
            TesseraTerminalHardwareKey.pageUp.escapeSequence,
            Array("\u{1B}[5~".utf8)
        )
        XCTAssertEqual(
            TesseraTerminalHardwareKey.pageDown.escapeSequence,
            Array("\u{1B}[6~".utf8)
        )
    }
}

final class MoshSessionFailureClassificationTests: XCTestCase {

    func test_postConnectClosedFailureIsTreatedAsDisconnect() {
        XCTAssertTrue(
            MoshSession.shouldTreatPostConnectFailureAsDisconnect("Connection closed")
        )
        XCTAssertTrue(
            MoshSession.shouldTreatPostConnectFailureAsDisconnect("channel EOF")
        )
    }

    func test_nonDisconnectFailureIsNotTreatedAsDisconnect() {
        XCTAssertFalse(
            MoshSession.shouldTreatPostConnectFailureAsDisconnect("Permission denied")
        )
    }
}

@MainActor
final class MoshSessionFailureMessageTests: XCTestCase {

    func test_userFacingStartupFailureMessage_upgradesGenericConnectionClosed() {
        XCTAssertEqual(
            MoshSession.userFacingStartupFailureMessage(from: "Connection closed"),
            "Could not start mosh. The remote host may not have `mosh-server` installed or on PATH, or it exited immediately during startup."
        )
    }

    func test_userFacingStartupFailureMessage_preservesSpecificMissingServerReason() {
        let reason = "Could not start mosh: the remote host does not have `mosh-server` installed or on PATH."

        XCTAssertEqual(
            MoshSession.userFacingStartupFailureMessage(from: reason),
            reason
        )
    }
}

final class HostLaunchPrologueTests: XCTestCase {
    func test_multilineSSHFormPreservesRemoteShellExpansionAndSnippetOrder() {
        let result = HostLaunchPrologue.multilineStdin(
            envVars: """
            FOO="hello world"
            export PATH=$HOME/bin:$PATH
            # ignored
            9INVALID=nope
            """,
            startupSnippet: "cd /tmp && printf ready"
        )

        XCTAssertEqual(
            result,
            "export FOO=\"hello world\"\n"
                + "export PATH=$HOME/bin:$PATH\n"
                + "cd /tmp && printf ready\n"
        )
    }

    func test_inlineMoshFormIsSemicolonJoinedForShellArgv() {
        XCTAssertEqual(
            HostLaunchPrologue.inlineForArgv(
                envVars: "FOO='space value'\nBAR=$(printf dynamic)",
                startupSnippet: "umask 077"
            ),
            "export FOO='space value'; export BAR=$(printf dynamic); umask 077; "
        )
    }

    func test_emptyOrInvalidConfigurationProducesNoPrologue() {
        XCTAssertNil(
            HostLaunchPrologue.multilineStdin(
                envVars: "# comment\nnot-an-assignment",
                startupSnippet: "  "
            )
        )
        XCTAssertNil(
            HostLaunchPrologue.inlineForArgv(envVars: "", startupSnippet: "")
        )
    }

    // MARK: - Side-channel lifetime

    func test_theSideChannelSurvivesTheUserLookingAtAnotherSession() {
        // The 2026-09-11 report: with a mosh+tmux and an ssh+tmux session both
        // open, switching to the SSH one dropped the mosh session's control
        // connection. Its TCP control read as disconnected, its forwarded
        // ports stopped, and switching back paid a fresh SSH connect plus a
        // tmux re-attach — one to two seconds, every time.
        //
        // Which session is on screen is not an input to this rule at all, so
        // there is no "inactive" case to pass: that is the fix.
        for launchMode in [HostLaunchMode.autoTmux, .pinnedTmux] {
            XCTAssertTrue(
                MoshSideChannelLifetime.shouldMaintain(
                    launchMode: launchMode,
                    isConnected: true
                ),
                "\(launchMode) should hold its side channel while connected"
            )
        }
    }

    func test_aSessionThatIsNotConnectedHasNothingToControl() {
        XCTAssertFalse(
            MoshSideChannelLifetime.shouldMaintain(
                launchMode: .autoTmux,
                isConnected: false
            )
        )
    }

    func test_plainMoshNeverOpensATmuxSideChannel() {
        // `.customCommand` has no tmux control channel. Its Agent Center read
        // carrier has a separate lifetime, independent of the UDP terminal.
        XCTAssertFalse(
            MoshSideChannelLifetime.shouldMaintain(
                launchMode: .customCommand,
                isConnected: true
            )
        )
    }
}

private actor MoshAgentCarrierTestGate {
    let started: XCTestExpectation
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Int, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func open() async -> Int {
        calls += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release(_ value: Int) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private struct MoshAgentCarrierTestExecHandle: AppleAgentStreamingExecHandle {
    let gate: MoshAgentCarrierTestGate
    func nextFrame() async throws -> AgentExecFrame? { _ = await gate.open(); return nil }
    func cancel() async {}
}
