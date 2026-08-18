import XCTest
import Combine
@testable import TmuxControl
@testable import Tessera

#if DEBUG
/// Live reproduction rig for the "stuck at starting tmux on a freshly added
/// host" report. Mirrors `SessionView`'s auto-tmux launch flow byte for byte:
/// connect, and the instant `session.state` reports `.connected`, write the
/// `AutoTmuxScript` one-liner over the shell's stdin and wait for the tmux
/// control-mode DCS.
///
/// The rig records every pre-control-mode chunk so a failure prints what the
/// remote actually said instead of an unexplained timeout.
final class AutoTmuxLaunchRegressionTests: XCTestCase {
    private struct Config: Decodable {
        let stableHost: String
        let chaosHost: String
        let port: Int
        let user: String
        let password: String

        static func load() throws -> Self {
            guard let encoded = ProcessInfo.processInfo.environment[
                "TESSERA_REAL_HOST_CONFIG_B64"
            ],
            let data = Data(base64Encoded: encoded) else {
                throw XCTSkip("real-host fixture is opt-in")
            }
            return try JSONDecoder().decode(Self.self, from: data)
        }
    }

    private struct Transcript {
        var chunks: [[UInt8]] = []

        var byteCount: Int { chunks.reduce(0) { $0 + $1.count } }

        var rendered: String {
            chunks.enumerated().map { index, chunk in
                "  [\(index)] \(chunk.count)B  \(SessionView.launchTracePreview(chunk, limit: 400))"
            }.joined(separator: "\n")
        }
    }

    /// The exact `SessionView` sequence against a host whose tmux server is
    /// not running (the state a freshly added host is in).
    @MainActor
    func test_liveAutoTmuxAttachesOnFreshlyAddedHost() async throws {
        let config = try Config.load()
        try await runAutoTmuxLaunch(config: config, label: "fresh-host")
    }

    /// Same flow run twice back to back — a second connect to the same host
    /// after the first one has already created the server-side session.
    @MainActor
    func test_liveAutoTmuxAttachesOnSecondConnect() async throws {
        let config = try Config.load()
        try await runAutoTmuxLaunch(config: config, label: "second-connect")
    }

    /// The production timing: `SessionView` writes the one-liner from
    /// `.onChange(of: session.state)`, which runs on the very next main-actor
    /// hop after `.connected` is published — i.e. *before* Citadel has opened
    /// the PTY channel. The polling rig above waits up to 100ms and so can
    /// miss the race entirely.
    @MainActor
    func test_liveAutoTmuxSendsImmediatelyOnConnectedPublish() async throws {
        let config = try Config.load()
        try await runAutoTmuxLaunch(
            config: config,
            label: "immediate-send",
            sendOnStatePublish: true
        )
    }

    /// The chaos fixture runs tmux 3.6a behind a wrapper shell; auto-tmux
    /// must cold-start there too.
    @MainActor
    func test_liveAutoTmuxAttachesOnChaosFixture() async throws {
        let config = try Config.load()
        try await runAutoTmuxLaunch(
            config: config,
            label: "chaos-fresh",
            sendOnStatePublish: true,
            useChaosHost: true
        )
    }

    @MainActor
    private func runAutoTmuxLaunch(
        config: Config,
        label: String,
        sendOnStatePublish: Bool = false,
        useChaosHost: Bool = false
    ) async throws {
        let address = useChaosHost ? config.chaosHost : config.stableHost
        let host = Host(
            name: "AutoTmux \(label)",
            address: address,
            port: config.port,
            user: config.user,
            password: config.password,
            transport: .ssh,
            autoTmux: true,
            launchMode: .autoTmux
        )
        await KnownHostsStore.shared.remove(endpoint: "\(address):\(config.port)")
        SSHAuthenticationPolicyStore.shared.resetForTesting()

        let session = SSHSession(host: host)
        let tmux = TmuxController(clientSizePolicy: .resizeTmux)
        tmux.updateClientSize(cols: 120, rows: 40)
        tmux.sendBytes = { [weak session] bytes in session?.send(bytes) }

        var transcript = Transcript()
        let transcriptBox = TranscriptBox()
        let pump = Task { @MainActor in
            for await chunk in session.outputStream {
                if tmux.mode == .passthrough {
                    transcriptBox.append(chunk)
                }
                await tmux.ingestCooperatively(chunk)
            }
        }
        defer {
            pump.cancel()
            session.disconnect()
        }

        let name = HostRuntimeStateStore.sessionName(for: host)
        let command = AutoTmuxScript.command(sessionName: name)
        var sentAt = Date()

        // Production timing: the send is scheduled on the main actor the
        // instant `.connected` is published, which is before `withPTY` has
        // opened the shell channel.
        var immediateSendDone = false
        var cancellable: AnyCancellable?
        if sendOnStatePublish {
            cancellable = session.$state.sink { newState in
                guard case .connected = newState, !immediateSendDone else { return }
                immediateSendDone = true
                DispatchQueue.main.async {
                    tmux.suppressPassthroughOutputUntilControlMode = true
                    sentAt = Date()
                    session.send(Array(command.utf8))
                }
            }
        }
        defer { cancellable?.cancel() }

        session.connect()
        try await waitUntil("ssh connect (\(label))", timeout: 30) {
            if case .failed(let reason) = session.state {
                XCTFail("connect failed: \(reason)")
                return true
            }
            if case .connected = session.state { return true }
            if let pending = session.pendingHostKeyVerification, !pending.isResolved {
                pending.accept()
            }
            return false
        }

        // SessionView's send site.
        if !sendOnStatePublish {
            tmux.suppressPassthroughOutputUntilControlMode = true
            sentAt = Date()
            session.send(Array(command.utf8))
        }

        var reachedControlMode = false
        do {
            try await waitUntil("tmux control mode (\(label))", timeout: 25) {
                tmux.mode == .tmuxControl
            }
            reachedControlMode = true
        } catch {
            reachedControlMode = false
        }

        transcript.chunks = transcriptBox.chunks
        let elapsed = Date().timeIntervalSince(sentAt)
        let report = """
            auto-tmux launch [\(label)]
              session name: \(name)
              control mode: \(reachedControlMode) after \(String(format: "%.2f", elapsed))s
              passthrough chunks: \(transcript.chunks.count) (\(transcript.byteCount) bytes)
            \(transcript.rendered)
            """
        print(report)
        try? report.write(
            toFile: NSTemporaryDirectory() + "autotmux-\(label).log",
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(
            reachedControlMode,
            "auto-tmux never reached control mode.\n\(report)"
        )
    }

    @MainActor
    private final class TranscriptBox {
        var chunks: [[UInt8]] = []
        func append(_ chunk: [UInt8]) { chunks.append(chunk) }
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        struct TimedOut: Error, CustomStringConvertible {
            let label: String
            var description: String { "timed out: \(label)" }
        }
        throw TimedOut(label: label)
    }
}
#endif
