import XCTest
import PortForwarding
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
            PortForwardRule(
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
