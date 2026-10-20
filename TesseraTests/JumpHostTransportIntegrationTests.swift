import XCTest
import PortForwarding
import TesseraCore
@testable import Tessera

#if DEBUG
/// Live jump-host (ProxyJump) verification against the disposable two-droplet
/// test bed (`scripts/integration/jump/`): a public bastion and a target whose
/// app-facing sshd is firewalled to accept ONLY the bastion. Every assertion
/// here is meaningful precisely because the direct path provably fails.
///
/// Opt-in like the other real-host tests: configuration arrives base64-encoded
/// in `TESSERA_JUMP_HOST_CONFIG_B64` (see run-jump-transport-tests.sh).
final class JumpHostTransportIntegrationTests: XCTestCase {
    @MainActor
    func test_jumpNativeIngestionSharesServiceAcrossIndependentSSHAndTmuxCarriers() async throws {
        let config = try Config.load()
        await resetConnectionState(endpoints: ["\(config.bastionHost):\(config.port)", targetHostKeyEndpoint(config)])
        let first = SSHSession(host: makeJumpHost(config: config, transport: .ssh))
        let second = SSHSession(host: makeJumpHost(config: config, transport: .ssh))
        defer { first.disconnect(); second.disconnect() }
        NSLog("[JumpIngestion] stage=first-connect")
        _ = try await connect(session: first, pendingRequest: { first.pendingHostKeyVerification }, onAccept: { _ in }, timeout: 30)
        NSLog("[JumpIngestion] stage=second-connect")
        _ = try await connect(session: second, pendingRequest: { second.pendingHostKeyVerification }, onAccept: { _ in }, timeout: 30)
        NSLog("[JumpIngestion] stage=route-proof")
        // Independent transport proof before installation or fixture writes.
        // A mutually consistent install/read on the wrong hop is not a pass.
        for session in [first, second] {
            let route = try await session.executeAgentInstallationCommand("printf '%s\\n' \"$(hostname)\" \"$SSH_CONNECTION\"")
                .split(separator: "\n").map(String.init)
            guard route.count == 2, route[0] == "jump-test",
                  let source = route[1].split(separator: " ").first,
                  [config.bastionHost, config.bastionPrivate].contains(String(source)) else {
                throw IntegrationError.failed("ingestion carrier did not prove the target and bastion source")
            }
        }
        // This installer runs on the authenticated destination only. Provider
        // settings/hooks are deliberately outside this transport fixture.
        NSLog("[JumpIngestion] stage=remote-error-oracle")
        do {
            _ = try await first.executeAgentInstallationCommand("python3 -c \"raise RuntimeError('versionStorageBudget')\"")
            XCTFail("failed installer command was accepted")
        } catch AgentLifecycleIntegrationInstallError.verificationFailed(let reason) {
            XCTAssertEqual(reason, "artifact: versionStorageBudget")
        }
        NSLog("[JumpIngestion] stage=child-cancellation-oracle")
        // Installer commands run as `/bin/sh -s` with stdin closed after the
        // script, so the child must block on something other than stdin.
        let cancelledInstall = Task {
            try await first.executeAgentInstallationCommand("sleep 30")
        }
        try await Task.sleep(for: .milliseconds(100))
        // The command's 10 s deadline also surfaces as CancellationError once
        // the caller is cancelled, so only promptness proves the cancel closed it.
        let cancelledAt = ContinuousClock.now
        cancelledInstall.cancel()
        do { _ = try await cancelledInstall.value; XCTFail("cancelled installer command was accepted") }
        catch is CancellationError { }
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(3))
        let survivor = try await first.executeAgentInstallationCommand("printf TESSERA_INSTALL_CARRIER_ALIVE")
        XCTAssertEqual(survivor, "TESSERA_INSTALL_CARRIER_ALIVE")
        NSLog("[JumpIngestion] stage=helper-install")
        var installerCommand = 0
        try await RemoteAgentLifecycleIntegrationInstaller.installNativeHost {
            installerCommand += 1
            NSLog("[JumpIngestion] install-command=%d state=begin cancelled=%d", installerCommand, Task.isCancelled ? 1 : 0)
            do {
                let reply = try await first.executeAgentInstallationCommand($0)
                NSLog("[JumpIngestion] install-command=%d state=done cancelled=%d", installerCommand, Task.isCancelled ? 1 : 0)
                return reply
            } catch {
                NSLog("[JumpIngestion] install-command=%d state=failed cancelled=%d", installerCommand, Task.isCancelled ? 1 : 0)
                if case AgentLifecycleIntegrationInstallError.verificationFailed(let reason) = error {
                    NSLog("[JumpIngestion] install-failure-code=%@", reason)
                }
                throw error
            }
        }
        let nonce = UUID().uuidString.lowercased()
        let tmux = "tessera-ingestion-\(nonce)"
        // A bounded SSH exec, not the interactive command helper (which
        // appends ;exit and would corrupt a final heredoc delimiter).
        func script(_ body: String) -> String { "python3 - <<'TESSERA_INGESTION_FIXTURE'\n\(body)\nTESSERA_INGESTION_FIXTURE\n" }
        let location = """
        import os, pathlib, pwd
        base = pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR') or (pwd.getpwuid(os.geteuid()).pw_dir + '/.claude'))
        directory = base / 'projects' / 'tessera-ingestion-\(nonce)'
        path = directory / '\(nonce).jsonl'
        """
        var connections: [AppleAgentIngestionConnection] = []
        func cleanup() async throws {
            for connection in connections { await connection.close() }
            // Attempt both cleanups even if one fails, and fail a green test
            // if any run-owned fixture survives. Never hide cleanup failure.
            var failure: Error?
            do {
                let removed = try await second.executeAgentInstallationCommand(script(location + "\npath.unlink(missing_ok=True)\nif directory.exists(): directory.rmdir()\nassert not directory.exists()\nprint('TESSERA_INGESTION_FILES_REMOVED')"))
                guard removed.trimmingCharacters(in: .whitespacesAndNewlines) == "TESSERA_INGESTION_FILES_REMOVED" else {
                    throw IntegrationError.failed("run-owned transcript cleanup was not confirmed")
                }
            }
            catch { failure = error }
            do {
                let removed = try await second.executeAgentInstallationCommand("if tmux has-session -t \(tmux) 2>/dev/null; then tmux kill-session -t \(tmux); fi; if tmux has-session -t \(tmux) 2>/dev/null; then exit 1; fi; printf TESSERA_INGESTION_TMUX_REMOVED")
                guard removed.trimmingCharacters(in: .whitespacesAndNewlines) == "TESSERA_INGESTION_TMUX_REMOVED" else {
                    throw IntegrationError.failed("run-owned tmux cleanup was not confirmed")
                }
            }
            catch { if failure == nil { failure = error } }
            if let failure { throw failure }
        }
        do {
            NSLog("[JumpIngestion] stage=tmux-attach")
            second.send(Array("tmux new-session -d -s \(tmux); tmux -CC attach -t \(tmux)\n".utf8))
            _ = try await waitForOutput(second.outputStream, containing: "%session-changed", timeout: 15)
            NSLog("[JumpIngestion] stage=fixture-create")
            let locator = try await first.executeAgentInstallationCommand(script(location + """

            import base64, json
            directory.mkdir(mode=0o700, parents=True, exist_ok=False)
            with path.open('x') as output:
                for index in range(240):
                    output.write(json.dumps({'type':'user','uuid':f'\(nonce)-r{index}', 'parentUuid':f'\(nonce)-r{index-1}' if index else None,
                        'message':{'role':'user','content':f'Synthetic \(nonce) history {index}'}}) + '\\n')
            path.chmod(0o600)
            print(base64.urlsafe_b64encode(str(path).encode()).decode().rstrip('='))
            """)).trimmingCharacters(in: .whitespacesAndNewlines)
            for (session, transport) in [(first, AgentTransportKind.ssh), (second, .sshTmux)] {
                NSLog("[JumpIngestion] stage=relay-open transport=%@", String(describing: transport))
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken(nonce)!, transport: transport, capabilities: [.observe])
                guard case .available(let factory) = session.agentProjectorExecAvailability(binding: binding, isBindingCurrent: { $0 == binding })
                else { throw IntegrationError.failed("native ingestion side channel unavailable") }
                connections.append(try await AppleAgentIngestionConnection.open(factory: factory, binding: binding))
            }
            XCTAssertNotNil(connections[0].epoch)
            XCTAssertEqual(connections[0].epoch, connections[1].epoch, "independent jump carriers must reuse the same target service")
            var handles: [String] = []
            var pages: [AgentProjectionPage] = []
            NSLog("[JumpIngestion] stage=bootstrap")
            for connection in connections {
                let resolved = try await connection.request(["kind": .string("resolve"), "provider": .string("claude"), "transcriptRef": .string(locator)])
                let handle = try XCTUnwrap(resolved.object["thread"]?.stringValue)
                handles.append(handle)
                let response = try await connection.request(["kind": .string("window.read"), "thread": .string(handle),
                    "operation": .string("bootstrap"), "windowVersion": .number(0)])
                let page = try XCTUnwrap(response.page)
                XCTAssertEqual(page.records.count, 100)
                assertIngestionFixture(page, nonce: nonce, indices: 140..<240)
                let range = try XCTUnwrap(page.ingestion), window = try XCTUnwrap(range.window)
                let segment = try XCTUnwrap(window.segmentID)
                let acknowledged = try await connection.request(["kind": .string("window.ack"), "thread": .string(handle),
                    "transaction": .string(range.requestID), "windowVersion": .number(Decimal(window.version)),
                    "viewport": .array([.string(segment)]), "head": .string(segment)])
                XCTAssertEqual(acknowledged.object["kind"]?.stringValue, "window.acked")
                pages.append(page)
            }
            XCTAssertEqual(handles[0], handles[1])
            XCTAssertEqual(pages[0].records.map(\.recordID), pages[1].records.map(\.recordID))
            // Closing one device's relay and entire carrier cannot terminate
            // its sibling lease or invalidate the sibling's ranged history.
            await connections[0].close(); first.disconnect()
            NSLog("[JumpIngestion] stage=sibling-history")
            let heartbeat = try await connections[1].request(["kind": .string("heartbeat")])
            XCTAssertEqual(heartbeat.object["serviceEpoch"]?.stringValue, connections[1].epoch)
            let window = try XCTUnwrap(pages[1].ingestion?.window)
            let older = try await connections[1].request(["kind": .string("window.read"), "thread": .string(handles[1]),
                "operation": .string("before"), "windowVersion": .number(Decimal(window.version)),
                "cursor": .string(try XCTUnwrap(window.before))])
            XCTAssertEqual(older.page?.records.count, 100)
            assertIngestionFixture(try XCTUnwrap(older.page), nonce: nonce, indices: 40..<140)
            XCTAssertTrue(Set(older.page!.records.map(\.recordID)).isDisjoint(with: pages[1].records.map(\.recordID)))
            NSLog("[JumpIngestion] stage=cleanup")
            try await cleanup()
            NSLog("[JumpIngestion] stage=complete")
        } catch { try? await cleanup(); throw error }
    }

    @MainActor
    func test_jumpNativeIngestionSharesServiceAcrossMoshAndMoshTmuxCarriers() async throws {
        let config = try Config.load()
        guard config.moshUDPAllowed else { throw XCTSkip("native mosh ingestion requires the UDP-allowed fixture pass") }
        await resetConnectionState(endpoints: ["\(config.bastionHost):\(config.port)", targetHostKeyEndpoint(config)])
        let nonce = UUID().uuidString.lowercased()
        let admin = SSHSession(host: makeJumpHost(config: config, transport: .ssh))
        let plain = MoshSession(host: makeJumpHost(config: config, transport: .mosh))
        var tmuxHost = makeJumpHost(config: config, transport: .mosh)
        let sessionName = "tessera-ingestion-mosh-\(nonce)"
        tmuxHost.launchMode = .pinnedTmux; tmuxHost.autoTmux = true; tmuxHost.tmuxSessionName = sessionName
        let tmux = MoshSession(host: tmuxHost)
        let channel = TmuxControlChannel(host: tmuxHost, sessionName: sessionName, initialSize: (cols: 100, rows: 30))
        defer { channel.disconnect(); tmux.disconnect(); plain.disconnect(); admin.disconnect() }
        _ = try await connect(session: admin, pendingRequest: { admin.pendingHostKeyVerification }, onAccept: { _ in }, timeout: 30)
        let routeCommand = "printf '%s\\n' \"$(hostname)\" \"$SSH_CONNECTION\""
        func checkRoute(_ output: String) throws {
            let lines = output.split(separator: "\n")
            guard lines.count == 2, lines[0] == "jump-test", let source = lines[1].split(separator: " ").first,
                  [config.bastionHost, config.bastionPrivate].contains(String(source)) else {
                throw IntegrationError.failed("mosh ingestion fixture did not prove target and bastion source")
            }
        }
        try checkRoute(try await admin.executeAgentInstallationCommand(routeCommand))
        try await RemoteAgentLifecycleIntegrationInstaller.installNativeHost { try await admin.executeAgentInstallationCommand($0) }
        var connections: [AppleAgentIngestionConnection] = []
        var ownedServers: [(pid: Int, start: UInt64)] = []
        func script(_ body: String) -> String { "python3 - <<'TESSERA_MOSH_INGESTION'\n\(body)\nTESSERA_MOSH_INGESTION\n" }
        let processIdentity = """
        import os, pathlib, signal, time
        def identity(pid):
            try:
                directory = pathlib.Path('/proc') / str(pid)
                stat = (directory / 'stat').read_text().rsplit(')', 1)[1].split()
                if stat[0] == 'Z': return None
                return (directory.stat().st_uid, (directory / 'comm').read_text().strip(), int(stat[19]))
            except FileNotFoundError: return None
        """
        func captureServer(_ session: MoshSession) async throws {
            let pid = try XCTUnwrap(session.remoteServerPID)
            guard pid > 1 else { throw IntegrationError.failed("invalid owned mosh PID") }
            let result = try await admin.executeAgentInstallationCommand(script(processIdentity + """

            value = identity(\(pid))
            assert value and value[0] == os.geteuid() and value[1] == 'mosh-server'
            print(value[2])
            """))
            guard let start = UInt64(result.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw IntegrationError.failed("owned mosh process identity unavailable")
            }
            ownedServers.append((pid, start))
        }
        let location = """
        import os, pathlib, pwd
        base = pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR') or (pwd.getpwuid(os.geteuid()).pw_dir + '/.claude'))
        directory = base / 'projects' / 'tessera-ingestion-\(nonce)'
        path = directory / '\(nonce).jsonl'
        """
        func cleanup() async throws {
            for connection in connections { await connection.close() }
            channel.disconnect(); tmux.disconnect(); plain.disconnect()
            var failure: Error?
            do {
                let tokens = ownedServers.map { "(\($0.pid),\($0.start))" }.joined(separator: ",")
                let result = try await admin.executeAgentInstallationCommand(script(processIdentity + """

                failures = []
                for pid, start in [\(tokens)]:
                    try:
                        expected = (os.geteuid(), 'mosh-server', start)
                        # Pin kernel identity before validating. A reused PID
                        # belongs to a replacement and must never be signaled.
                        try: descriptor = os.pidfd_open(pid)
                        except ProcessLookupError: continue
                        try:
                            if identity(pid) != expected: continue
                            for sig, grace in [(None, 1), (signal.SIGTERM, 3), (signal.SIGKILL, 1)]:
                                if sig is not None:
                                    try: signal.pidfd_send_signal(descriptor, sig)
                                    except ProcessLookupError: break
                                deadline = time.monotonic() + grace
                                while time.monotonic() < deadline and identity(pid) == expected: time.sleep(.05)
                                if identity(pid) != expected: break
                            assert identity(pid) != expected, 'owned mosh process survived cleanup'
                        finally: os.close(descriptor)
                    except Exception as error: failures.append(type(error).__name__)
                assert not failures, 'one or more owned mosh process cleanups failed'
                print('MOSH_REMOVED')
                """))
                guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "MOSH_REMOVED" else {
                    throw IntegrationError.failed("owned mosh process cleanup unconfirmed")
                }
            } catch { failure = error }
            do {
                let output = try await admin.executeAgentInstallationCommand(script(location + "\npath.unlink(missing_ok=True)\nif directory.exists(): directory.rmdir()\nassert not directory.exists()\nprint('REMOVED')"))
                guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "REMOVED" else { throw IntegrationError.failed("mosh transcript cleanup unconfirmed") }
            } catch { if failure == nil { failure = error } }
            do {
                let output = try await admin.executeAgentInstallationCommand("if tmux has-session -t \(sessionName) 2>/dev/null; then tmux kill-session -t \(sessionName); fi; if tmux has-session -t \(sessionName) 2>/dev/null; then exit 1; fi; printf REMOVED")
                guard output == "REMOVED" else { throw IntegrationError.failed("mosh tmux cleanup unconfirmed") }
            } catch { if failure == nil { failure = error } }
            if let failure { throw failure }
        }
        do {
            for session in [plain, tmux] {
                do {
                    _ = try await connect(session: session, pendingRequest: { session.pendingHostKeyVerification }, onAccept: { _ in }, timeout: 45)
                } catch {
                    if session.remoteServerPID != nil { try await captureServer(session) }
                    throw error
                }
                try await captureServer(session)
                // Split the marker so terminal input echo cannot satisfy it.
                session.send(Array("printf 'TESSERA_MOSH''_TARGET=%s\\n' \"$(hostname)\"\n".utf8))
                _ = try await waitForOutput(session.outputStream, containing: "TESSERA_MOSH_TARGET=jump-test", timeout: 15)
            }
            channel.connect()
            _ = try await waitForOutput(channel.outputStream, containing: "%session-changed", timeout: 20)
            try checkRoute(try await channel.executeAgentInstallationCommand(routeCommand))
            let locator = try await admin.executeAgentInstallationCommand(script(location + """

            import base64, json
            directory.mkdir(mode=0o700, parents=True, exist_ok=False)
            with path.open('x') as output:
                for index in range(240):
                    output.write(json.dumps({'type':'user','uuid':f'\(nonce)-r{index}','parentUuid':f'\(nonce)-r{index-1}' if index else None,
                        'message':{'role':'user','content':f'Synthetic \(nonce) history {index}'}}) + '\\n')
            path.chmod(0o600)
            print(base64.urlsafe_b64encode(str(path).encode()).decode().rstrip('='))
            """)).trimmingCharacters(in: .whitespacesAndNewlines)
            for transport in [AgentTransportKind.mosh, .moshTmux] {
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                    incarnation: AgentIncarnationToken(nonce)!, transport: transport, capabilities: [.observe])
                let availability = transport == .mosh
                    ? plain.agentProjectorExecAvailability(binding: binding, isBindingCurrent: { $0 == binding })
                    : channel.agentProjectorExecAvailability(binding: binding, isBindingCurrent: { $0 == binding })
                guard case .available(let factory) = availability else { throw IntegrationError.failed("mosh ingestion factory unavailable") }
                connections.append(try await AppleAgentIngestionConnection.open(factory: factory, binding: binding))
            }
            XCTAssertNotNil(connections[0].epoch)
            XCTAssertEqual(connections[0].epoch, connections[1].epoch)
            var handles: [String] = [], pages: [AgentProjectionPage] = []
            for connection in connections {
                let resolved = try await connection.request(["kind": .string("resolve"), "provider": .string("claude"), "transcriptRef": .string(locator)])
                let handle = try XCTUnwrap(resolved.object["thread"]?.stringValue); handles.append(handle)
                let response = try await connection.request(["kind": .string("window.read"), "thread": .string(handle), "operation": .string("bootstrap"), "windowVersion": .number(0)])
                let page = try XCTUnwrap(response.page); pages.append(page)
                XCTAssertEqual(page.records.count, 100)
                assertIngestionFixture(page, nonce: nonce, indices: 140..<240)
                let range = try XCTUnwrap(page.ingestion), window = try XCTUnwrap(range.window)
                let segment = try XCTUnwrap(window.segmentID)
                let ack = try await connection.request(["kind": .string("window.ack"), "thread": .string(handle),
                    "transaction": .string(range.requestID), "windowVersion": .number(Decimal(window.version)),
                    "viewport": .array([.string(segment)]), "head": .string(segment)])
                XCTAssertEqual(ack.object["kind"]?.stringValue, "window.acked")
            }
            XCTAssertEqual(handles[0], handles[1])
            XCTAssertEqual(pages[0].records.map(\.recordID), pages[1].records.map(\.recordID))
            await connections[0].close(); plain.disconnect()
            let heartbeat = try await connections[1].request(["kind": .string("heartbeat")])
            XCTAssertEqual(heartbeat.object["serviceEpoch"]?.stringValue, connections[1].epoch)
            let window = try XCTUnwrap(pages[1].ingestion?.window)
            let older = try await connections[1].request(["kind": .string("window.read"), "thread": .string(handles[1]),
                "operation": .string("before"), "windowVersion": .number(Decimal(window.version)), "cursor": .string(try XCTUnwrap(window.before))])
            XCTAssertEqual(older.page?.records.count, 100)
            assertIngestionFixture(try XCTUnwrap(older.page), nonce: nonce, indices: 40..<140)
            XCTAssertTrue(Set(try XCTUnwrap(older.page).records.map(\.recordID)).isDisjoint(with: pages[1].records.map(\.recordID)))
            try await cleanup()
        } catch { try? await cleanup(); throw error }
    }

    private func assertIngestionFixture(_ page: AgentProjectionPage, nonce: String, indices: Range<Int>,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(page.records.count, indices.count, file: file, line: line)
        for (record, index) in zip(page.records, indices) {
            let object = record.record.objectValue
            XCTAssertEqual(object?["turnID"]?.stringValue, "\(nonce)-r\(index)", file: file, line: line)
            XCTAssertEqual(object?["role"]?.stringValue, "user", file: file, line: line)
            XCTAssertEqual(object?["blocks"]?.arrayValue?.first?.objectValue?["text"]?.stringValue,
                           "Synthetic \(nonce) history \(index)", file: file, line: line)
        }
    }

    private struct Config: Decodable {
        let bastionHost: String
        let bastionPrivate: String
        let targetHost: String
        let port: Int
        let innerPort: Int
        let pwUser: String
        let bastionPassword: String
        let targetPassword: String
        let echoPort: Int
        let localForwardPort: Int
        let moshUDPAllowed: Bool

        static func load() throws -> Self {
            guard let encoded = ProcessInfo.processInfo.environment[
                "TESSERA_JUMP_HOST_CONFIG_B64"
            ],
            let data = Data(base64Encoded: encoded) else {
                throw XCTSkip(
                    "jump fixture is opt-in; run scripts/integration/jump/run-jump-transport-tests.sh"
                )
            }
            return try JSONDecoder().decode(Self.self, from: data)
        }
    }

    private enum IntegrationError: Error, CustomStringConvertible {
        case timedOut(String)
        case failed(String)
        case streamEnded(String)

        var description: String {
            switch self {
            case .timedOut(let operation): return "timed out: \(operation)"
            case .failed(let message): return "session failed: \(message)"
            case .streamEnded(let operation): return "output stream ended: \(operation)"
            }
        }
    }

    /// Target host DTO with the bastion as its one-hop jump chain and
    /// distinct per-hop passwords (the fixtures enforce different
    /// credentials per hop, so accidental credential reuse fails).
    @MainActor
    private func makeJumpHost(config: Config, transport: HostTransport) -> Host {
        var bastion = Host(
            name: "jump-bastion",
            address: config.bastionHost,
            port: config.port,
            user: config.pwUser,
            password: config.bastionPassword,
            transport: .ssh,
            launchMode: .customCommand
        )
        bastion.jumpChain = []
        var target = Host(
            name: "jump-target",
            address: config.targetHost,
            port: config.port,
            user: config.pwUser,
            password: config.targetPassword,
            transport: transport,
            autoTmux: false,
            launchMode: .customCommand
        )
        target.jumpChain = [bastion]
        return target
    }

    @MainActor
    func test_jumpSSH_connectsAndProvablyRoutesThroughBastion() async throws {
        let config = try Config.load()
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        let session = SSHSession(host: makeJumpHost(config: config, transport: .ssh))
        defer { session.disconnect() }

        var acceptedEndpoints: [String] = []
        let sawTOFU = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            onAccept: { acceptedEndpoints.append($0) },
            timeout: 30
        )
        XCTAssertTrue(sawTOFU, "fresh jump chain must TOFU-prompt")
        XCTAssertEqual(
            acceptedEndpoints,
            [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ],
            "each hop must be verified independently, bastion first"
        )

        // The connection is on the target...
        // Markers are split in the SENT text (shell quote concatenation) so
        // the PTY's echo of the typed command can never satisfy the wait —
        // only the printf RESULT contains the assembled marker.
        let marker = "TESSERA_JUMP_WHOAMI"
        session.send(Array("printf 'TESSERA_JUMP''_WHOAMI=%s\\n' \"$(hostname)\"\n".utf8))
        let hostnameOutput = try await waitForOutput(
            session.outputStream,
            containing: "\(marker)=",
            timeout: 10
        )
        XCTAssertTrue(
            hostnameOutput.contains("\(marker)=jump-test"),
            "unexpected hostname: \(hostnameOutput.suffix(200))"
        )

        // ...and the target sees the BASTION as the TCP source, proving the
        // bytes rode the direct-tcpip channel rather than any direct path.
        session.send(Array("printf 'TESSERA_JUMP''_SRC=%s\\n' \"$SSH_CONNECTION\"\n".utf8))
        let sourceOutput = try await waitForOutput(
            session.outputStream,
            containing: "TESSERA_JUMP_SRC=",
            timeout: 10
        )
        let sawBastionSource = sourceOutput.contains("TESSERA_JUMP_SRC=\(config.bastionHost) ")
            || sourceOutput.contains("TESSERA_JUMP_SRC=\(config.bastionPrivate) ")
        XCTAssertTrue(
            sawBastionSource,
            "target must see the bastion as source: \(sourceOutput.suffix(200))"
        )

        // tmux on the target works over the tunneled PTY (the inline -CC
        // integration rides this same byte path).
        session.send(Array(
            "tmux -V >/dev/null 2>&1 && printf 'TESSERA_JUMP''_TMUX=ok\\n' || printf 'TESSERA_JUMP''_TMUX=missing\\n'\n".utf8
        ))
        let tmuxOutput = try await waitForOutput(
            session.outputStream,
            containing: "TESSERA_JUMP_TMUX=",
            timeout: 10
        )
        XCTAssertTrue(
            tmuxOutput.contains("TESSERA_JUMP_TMUX=ok"),
            "tmux missing through chain: \(tmuxOutput.suffix(200))"
        )

        // Accepted hop keys persist: a second chain must not prompt.
        session.disconnect()
        let reconnect = SSHSession(host: makeJumpHost(config: config, transport: .ssh))
        defer { reconnect.disconnect() }
        let promptedAgain = try await connect(
            session: reconnect,
            pendingRequest: { reconnect.pendingHostKeyVerification },
            onAccept: { _ in },
            timeout: 30
        )
        XCTAssertFalse(promptedAgain, "accepted per-hop keys must persist")
    }

    @MainActor
    func test_jumpSSHTmux_controlModeTraversesChain() async throws {
        let config = try Config.load()
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        let session = SSHSession(host: makeJumpHost(config: config, transport: .ssh))
        defer { session.disconnect() }
        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            onAccept: { _ in },
            timeout: 30
        )

        let name = "tessera-jump-sshcc-\(UUID().uuidString.prefix(8))"
        session.send(Array(
            "tmux new-session -d -s \(name); tmux -CC attach -t \(name)\n".utf8
        ))
        let output = try await waitForOutput(
            session.outputStream,
            containing: "%session-changed",
            timeout: 15
        )
        XCTAssertTrue(
            output.contains("%session-changed"),
            "SSH+tmux control protocol did not arrive through chain"
        )
    }

    @MainActor
    func test_jumpSSH_wrongBastionPasswordIsAttributedToBastion() async throws {
        let config = try Config.load()
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        var host = makeJumpHost(config: config, transport: .ssh)
        host.jumpChain[0].password = config.bastionPassword + "-wrong"
        let session = SSHSession(host: host)
        defer { session.disconnect() }

        session.connect()
        let message = try await waitForFailure(
            state: { session.state },
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 30
        )
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("jump host"),
            "bastion auth failure must name the failing hop: \(message)"
        )
    }

    @MainActor
    func test_jumpSSH_wrongTargetPasswordIsNotAttributedToBastion() async throws {
        let config = try Config.load()
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        var host = makeJumpHost(config: config, transport: .ssh)
        host.password = config.targetPassword + "-wrong"
        let session = SSHSession(host: host)
        defer { session.disconnect() }

        session.connect()
        let message = try await waitForFailure(
            state: { session.state },
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 30
        )
        XCTAssertFalse(
            message.localizedCaseInsensitiveContains("jump host"),
            "destination auth failure must not blame the bastion: \(message)"
        )
    }

    @MainActor
    func test_jumpMultiHop_reachesLoopbackOnlyInnerSSHD() async throws {
        // device → bastion → target → target's 127.0.0.1-only sshd. Three
        // hops; the innermost endpoint does not even have a routable
        // address.
        let config = try Config.load()
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
                innerHostKeyEndpoint(config),
            ]
        )
        var host = makeJumpHost(config: config, transport: .ssh)
        var middle = host
        middle.jumpChain = []
        var inner = Host(
            name: "jump-inner",
            address: "127.0.0.1",
            port: config.innerPort,
            user: config.pwUser,
            password: config.targetPassword,
            transport: .ssh,
            autoTmux: false,
            launchMode: .customCommand
        )
        inner.jumpChain = [host.jumpChain[0], middle]
        let session = SSHSession(host: inner)
        defer { session.disconnect() }

        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            onAccept: { _ in },
            timeout: 45
        )
        let marker = "TESSERA_JUMP_INNER"
        // Split marker: the echoed command must not satisfy the wait.
        session.send(Array("printf 'TESSERA_JUMP''_INNER=%s\\n' \"$SSH_CONNECTION\"\n".utf8))
        let output = try await waitForOutput(
            session.outputStream,
            containing: "\(marker)=",
            timeout: 10
        )
        XCTAssertTrue(
            output.contains("\(marker)=127.0.0.1 "),
            "inner hop must arrive over loopback: \(output.suffix(200))"
        )
    }

    @MainActor
    func test_jumpFileBridge_listsFixturesThroughChain() async throws {
        let config = try Config.load()
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        // The bridge prompts nobody (hostKeyPrompt nil) so pre-trust both
        // hops with a throwaway session first.
        let warmup = SSHSession(host: makeJumpHost(config: config, transport: .ssh))
        _ = try await connect(
            session: warmup,
            pendingRequest: { warmup.pendingHostKeyVerification },
            onAccept: { _ in },
            timeout: 30
        )
        warmup.disconnect()

        let bridge = FileBridge(
            host: makeJumpHost(config: config, transport: .ssh),
            requireBiometric: false,
            isSecureEnclave: false
        )
        defer { Task { await bridge.disconnect() } }
        try await bridge.connect()
        let home = try XCTUnwrap(bridge.homeDirectory)
        let entries = try await bridge.listDirectory("\(home)/fixture-files")
        let names = Set(entries.map(\.name))
        XCTAssertTrue(
            names.isSuperset(of: ["visible.txt", "testfile", "subdirectory"]),
            "fixture listing incomplete through jump chain: \(names)"
        )
    }

    @MainActor
    func test_jumpPortForward_carriesHTTPFromLoopbackOnlyEndpoint() async throws {
        let config = try Config.load()
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        var host = makeJumpHost(config: config, transport: .ssh)
        let localPort = try XCTUnwrap(UInt16(exactly: config.localForwardPort))
        host.portForwardRules = [
            PortForwardRule.localForward(
                localPort: localPort,
                remoteHost: "127.0.0.1",
                remotePort: UInt16(config.echoPort),
                label: "jump-http"
            )
        ]
        let session = SSHSession(host: host)
        defer { session.disconnect() }
        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            onAccept: { _ in },
            timeout: 30
        )

        try await waitUntil("jump forwarder listening", timeout: 10) {
            session.portForwarderManager.runningCount == 1
        }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(localPort)/visible.txt"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "visible fixture file\n",
            "forwarded HTTP body must round-trip through both hops"
        )
    }

    @MainActor
    func test_jumpMosh_bootstrapsThenRecommendsSSHFallbackWhenUDPBlocked() async throws {
        // The fixtures drop mosh's UDP range by default (the realistic
        // bastioned topology). The SSH bootstrap must succeed through the
        // chain, the driver must never sync, and the session must convert
        // that into the SSH-fallback recommendation ContentView acts on.
        let config = try Config.load()
        guard !config.moshUDPAllowed else {
            throw XCTSkip("blocked-UDP fallback runs in the blocked fixture pass")
        }
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        let session = MoshSession(host: makeJumpHost(config: config, transport: .mosh))
        defer { session.disconnect() }

        session.connect()
        let deadline = Date().addingTimeInterval(90)
        var sawFailure: String?
        while Date() < deadline {
            if let request = session.pendingHostKeyVerification {
                request.accept()
            }
            if case .failed(let message) = session.state {
                sawFailure = message
                break
            }
            if case .connected = session.state {
                XCTFail("mosh must not reach connected with UDP blocked")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let message = try XCTUnwrap(sawFailure, "mosh should fail within the watchdog window")
        XCTAssertTrue(
            session.recommendsSSHFallback,
            "UDP-blocked jump chain must recommend the SSH fallback (message: \(message))"
        )
        XCTAssertTrue(message.localizedCaseInsensitiveContains("jump chain"))
    }

    @MainActor
    func test_jumpMosh_connectsWhenUDPIsReachable() async throws {
        let config = try Config.load()
        guard config.moshUDPAllowed else {
            throw XCTSkip("successful mosh runs in the UDP-allowed fixture pass")
        }
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        let session = MoshSession(host: makeJumpHost(config: config, transport: .mosh))
        defer { session.disconnect() }
        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            onAccept: { _ in },
            timeout: 45
        )
        session.send(Array("printf 'TESSERA_JUMP''_MOSH=ok\\n'\n".utf8))
        let output = try await waitForOutput(
            session.outputStream,
            containing: "TESSERA_JUMP_MOSH=ok",
            timeout: 15
        )
        XCTAssertTrue(output.contains("TESSERA_JUMP_MOSH=ok"))
    }

    @MainActor
    func test_jumpMoshTmux_sideChannelTraversesChain() async throws {
        let config = try Config.load()
        guard config.moshUDPAllowed else {
            throw XCTSkip("mosh+tmux runs in the UDP-allowed fixture pass")
        }
        await resetConnectionState(
            endpoints: [
                "\(config.bastionHost):\(config.port)",
                targetHostKeyEndpoint(config),
            ]
        )
        var host = makeJumpHost(config: config, transport: .mosh)
        let sessionName = "tessera-jump-moshtmux-\(UUID().uuidString.prefix(8))"
        host.launchMode = .pinnedTmux
        host.autoTmux = true
        host.tmuxSessionName = sessionName
        let session = MoshSession(host: host)
        defer { session.disconnect() }
        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            onAccept: { _ in },
            timeout: 45
        )

        let channel = TmuxControlChannel(
            host: host,
            sessionName: sessionName,
            initialSize: (cols: 100, rows: 30)
        )
        defer { channel.disconnect() }
        channel.connect()
        let output = try await waitForOutput(
            channel.outputStream,
            containing: "%session-changed",
            timeout: 20
        )
        XCTAssertTrue(
            output.contains("%session-changed"),
            "mosh+tmux SSH side channel did not traverse the jump chain"
        )
    }

    // MARK: - Helpers (mirrors RealHostTransportIntegrationTests)

    private func targetHostKeyEndpoint(_ config: Config) -> String {
        "\(config.bastionHost):\(config.port)→\(config.targetHost):\(config.port)"
    }

    private func innerHostKeyEndpoint(_ config: Config) -> String {
        "\(targetHostKeyEndpoint(config))→127.0.0.1:\(config.innerPort)"
    }

    @MainActor
    private func resetConnectionState(endpoints: [String]) async {
        SSHAuthenticationPolicyStore.shared.resetForTesting()
        for endpoint in endpoints {
            await KnownHostsStore.shared.remove(endpoint: endpoint)
        }
    }

    @MainActor
    private func connect<Session: TerminalSession>(
        session: Session,
        pendingRequest: @escaping @MainActor () -> HostKeyVerificationRequest?,
        onAccept: @escaping @MainActor (String) -> Void,
        timeout: TimeInterval
    ) async throws -> Bool {
        session.connect()
        let deadline = Date().addingTimeInterval(timeout)
        var sawTOFU = false

        while Date() < deadline {
            if let request = pendingRequest() {
                sawTOFU = true
                XCTAssertFalse(request.fingerprint.isEmpty)
                onAccept(request.endpoint)
                request.accept()
            }
            switch session.state {
            case .connected:
                return sawTOFU
            case .failed(let message):
                throw IntegrationError.failed(message)
            case .idle, .connecting, .disconnected:
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut("connect \(session.host.transport.rawValue)")
    }

    @MainActor
    private func waitForFailure(
        state: @escaping @MainActor () -> SessionState,
        pendingRequest: @escaping @MainActor () -> HostKeyVerificationRequest?,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pendingRequest()?.accept()
            if case .failed(let message) = state() {
                return message
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut("failure classification")
    }

    @MainActor
    private func waitUntil(
        _ operation: String,
        timeout: TimeInterval,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut(operation)
    }

    private func waitForOutput(
        _ stream: AsyncStream<[UInt8]>,
        containing marker: String,
        timeout: TimeInterval
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for await bytes in stream {
                    text += String(decoding: bytes, as: UTF8.self)
                    if text.contains(marker) { return text }
                    if text.utf8.count > 256 * 1024 {
                        text = String(text.suffix(128 * 1024))
                    }
                }
                throw IntegrationError.streamEnded(marker)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw IntegrationError.timedOut("output marker \(marker)")
            }
            guard let value = try await group.next() else {
                throw IntegrationError.streamEnded(marker)
            }
            group.cancelAll()
            return value
        }
    }
}
#endif
