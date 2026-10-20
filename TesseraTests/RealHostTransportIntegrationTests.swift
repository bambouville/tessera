import XCTest
import UIKit
import CryptoKit
import PortForwarding
import SwiftTerm
import TesseraCore
import TmuxControlCore
@testable import TmuxControl
@testable import Tessera

#if DEBUG
final class RealHostTransportIntegrationTests: XCTestCase {
    private struct Config: Decodable {
        let stableHost: String
        let chaosHost: String
        let port: Int
        let user: String
        let password: String
        let echoPort: Int
        let localForwardPort: Int

        static func load() throws -> Self {
            guard let encoded = ProcessInfo.processInfo.environment[
                "TESSERA_REAL_HOST_CONFIG_B64"
            ],
            let data = Data(base64Encoded: encoded) else {
                throw XCTSkip(
                    "real-host fixture is opt-in; run scripts/integration/run-integration-tests.sh"
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
            case .timedOut(let operation):
                return "timed out: \(operation)"
            case .failed(let message):
                return "session failed: \(message)"
            case .streamEnded(let operation):
                return "output stream ended: \(operation)"
            }
        }
    }

    @MainActor
    func test_liveSSHLatencyDiagnosticsCoverWriteReceiveDeliveryAndDraw() async throws {
        let config = try Config.load()
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        let host = makeHost(config: config, transport: .ssh)
        let session = SSHSession(host: host)
        let facade = AppleSessionCommandFacade(session: session)
        let delivery = SessionLatencyDiagnostics.queue(host: host.id, stage: "publication-to-terminal-consumer")
        let events = facade.events(diagnostics: delivery)
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let box = TerminalBox(traceLabel: "latency-live-test")
        box.bindLatencyDiagnostics(host: host.id)
        box.attach(view)
        box.markRenderReady()
        var received = ""
        let pump = Task { @MainActor in
            for await event in events.mainActorDelivery(diagnostics: delivery) {
                if case .terminalBytes(_, let data, _) = event {
                    received += String(decoding: data, as: UTF8.self)
                    box.feed(Array(data)[...])
                    // Exercise UIKit's actual draw dispatch (including the
                    // subclass callback) without a user window or host UI.
                    _ = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
                        view.layer.render(in: context.cgContext)
                    }
                }
            }
        }
        defer { pump.cancel(); session.disconnect() }
        facade.connect()
        try await waitUntil("diagnostic fixture connection", timeout: 25) {
            session.pendingHostKeyVerification?.accept()
            return facade.state == .connected
        }
        let marker = "TESSERA_LATENCY_DIAGNOSTIC_OK"
        facade.sendInput(Array("\(unechoedPrintf(marker))\n".utf8))
        try await waitUntil("diagnostic fixture echo", timeout: 15) { received.contains(marker) }
        // Two sampling windows include the first NIO heartbeat's completion.
        try await Task.sleep(for: .seconds(11))
        let data = try XCTUnwrap(DiagnosticLogStore.attachmentData())
        let log = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").filter { $0.contains("host=\(host.id.uuidString.prefix(8))") }
            .joined(separator: "\n")
        for stage in ["nio-to-ssh-reader", "ssh-read-to-stream-publication",
                      "ssh-published-to-facade", "engine-to-publication",
                      "publication-to-terminal-consumer", "ssh-nio-event-loop-pulse",
                      "renderer-coregraphics-draw-hidden-call"] {
            XCTAssertTrue(log.contains("stage=\(stage)"), "missing \(stage): \(log)")
        }
        XCTAssertTrue(log.contains("stage=write-complete"), log)
        XCTAssertTrue(log.contains("mode=coregraphics callback=subclass-draw"), log)
        NSLog("[LatencyLiveTest] %@", log)
    }

    /// The SSH reader may publish a large final burst immediately before the
    /// PTY reaches EOF. Keep consuming the production facade event stream past
    /// its disconnected event and prove that lifecycle delivery cannot discard
    /// bytes which the transport yielded first.
    @MainActor
    func test_liveSSHFacadePreservesEOFTailBeforeDisconnect() async throws {
        let config = try Config.load()
        let host = makeHost(config: config, transport: .ssh)
        let session = SSHSession(host: host)
        let facade = AppleSessionCommandFacade(session: session)
        let delivery = SessionLatencyDiagnostics.queue(
            host: host.id,
            stage: "eof-tail-publication-to-test"
        )
        let events = facade.events(diagnostics: delivery)
        let payloadByteCount = 256 * 1_024
        let suffix = UUID().uuidString
        let beginMarker = "TESSERA_EOF_BEGIN_\(suffix)"
        let endMarker = "TESSERA_EOF_END_\(suffix)"
        let beginData = Data(beginMarker.utf8)
        let endData = Data(endMarker.utf8)
        var received = Data()
        var eventOrdinal = 0
        var endMarkerEventOrdinal: Int?
        var disconnectEventOrdinal: Int?
        var sawConnected = false
        let pump = Task { @MainActor in
            for await event in events.mainActorDelivery(diagnostics: delivery) {
                eventOrdinal += 1
                switch event {
                case .terminalBytes(_, let bytes, _):
                    received.append(bytes)
                    if endMarkerEventOrdinal == nil, received.range(of: endData) != nil {
                        endMarkerEventOrdinal = eventOrdinal
                    }
                case .stateChanged(_, let state):
                    if state == .connected {
                        sawConnected = true
                    } else if state == .disconnected, sawConnected,
                              disconnectEventOrdinal == nil {
                        disconnectEventOrdinal = eventOrdinal
                    }
                default:
                    break
                }
            }
        }
        defer { pump.cancel(); session.disconnect() }

        facade.connect()
        try await waitUntil("EOF-tail fixture connection", timeout: 25) {
            session.pendingHostKeyVerification?.accept()
            return facade.state == .connected
        }

        func splitPythonByteLiteral(_ value: String) -> String {
            let middle = value.index(value.startIndex, offsetBy: value.count / 2)
            return "b'\(value[..<middle])' + b'\(value[middle...])'"
        }
        let script = "import sys; sys.stdout.buffer.write("
            + "\(splitPythonByteLiteral(beginMarker)) + "
            + "b'x' * \(payloadByteCount) + "
            + "\(splitPythonByteLiteral(endMarker))); "
            + "sys.stdout.buffer.flush()"
        facade.sendInput(Array("python3 -c \(shellQuote(script)); exit\n".utf8))

        // Do not stop the event pump when disconnect arrives: the regression
        // under test is precisely a lifecycle event overtaking the final
        // already-received output queued for facade admission.
        try await waitUntil("SSH EOF disconnect", timeout: 20) {
            disconnectEventOrdinal != nil
        }
        try await waitUntil("SSH EOF tail marker", timeout: 5) {
            endMarkerEventOrdinal != nil
        }

        let beginRange = try XCTUnwrap(received.range(of: beginData))
        let endRange = try XCTUnwrap(
            received.range(
                of: endData,
                options: [],
                in: beginRange.upperBound..<received.endIndex
            )
        )
        let payload = received[beginRange.upperBound..<endRange.lowerBound]
        XCTAssertEqual(payload.count, payloadByteCount)
        XCTAssertTrue(payload.allSatisfy { $0 == 0x78 })
        XCTAssertLessThan(
            try XCTUnwrap(endMarkerEventOrdinal),
            try XCTUnwrap(disconnectEventOrdinal),
            "the transport's final marker must be admitted before disconnected"
        )
    }

    @MainActor
    func test_liveSSHPasswordTOFUAndPTY() async throws {
        let config = try Config.load()
        await resetConnectionState(endpoint: "\(config.stableHost):\(config.port)")
        let session = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { session.disconnect() }

        let sawTOFU = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertTrue(sawTOFU, "an unknown live host must produce a TOFU request")

        let marker = "TESSERA_LIVE_SSH_PTY_OK"
        session.send(Array("printf '\(marker)\\n'\n".utf8))
        let output = try await waitForOutput(
            session.outputStream,
            containing: marker,
            timeout: 10
        )
        XCTAssertTrue(output.contains(marker))

        session.disconnect()
        let pairing = try await beginLiveQRContinuation(host: session.host)
        defer { pairing.origin.cancel(); pairing.recipient.cancel() }
        let reconnect = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { reconnect.disconnect() }
        let promptedAgain = try await connect(
            session: reconnect,
            pendingRequest: { reconnect.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertFalse(promptedAgain, "an accepted live host key must persist")
        reconnect.send(Array("\(unechoedPrintf(marker + "_RECONNECTED"))\n".utf8))
        _ = try await waitForOutput(reconnect.outputStream, containing: marker + "_RECONNECTED", timeout: 10)
        try await completeLiveQRContinuation(pairing)
    }

    @MainActor
    func test_liveMoshPasswordTOFUAndPTY() async throws {
        let config = try Config.load()
        await resetConnectionState(endpoint: "\(config.chaosHost):\(config.port)")
        let host = makeHost(config: config, transport: .mosh, useChaosHost: true)
        let session = MoshSession(host: host)
        defer { session.disconnect() }

        let sawTOFU = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 35
        )
        XCTAssertTrue(sawTOFU, "mosh bootstrap must use the same live TOFU path")

        let marker = "TESSERA_LIVE_MOSH_PTY_OK"
        session.send(Array("printf '\(marker)\\n'\n".utf8))
        let output = try await waitForOutput(
            session.outputStream,
            containing: marker,
            timeout: 15
        )
        XCTAssertTrue(output.contains(marker))

        session.disconnect()
        let pairing = try await beginLiveQRContinuation(host: host)
        defer { pairing.origin.cancel(); pairing.recipient.cancel() }
        let reconnect = MoshSession(host: host)
        defer { reconnect.disconnect() }
        let promptedAgain = try await connect(
            session: reconnect,
            pendingRequest: { reconnect.pendingHostKeyVerification },
            timeout: 35
        )
        XCTAssertFalse(promptedAgain, "mosh bootstrap must reuse accepted trust")
        reconnect.send(Array("\(unechoedPrintf(marker + "_RECONNECTED"))\n".utf8))
        _ = try await waitForOutput(reconnect.outputStream, containing: marker + "_RECONNECTED", timeout: 15)
        try await completeLiveQRContinuation(pairing)
    }

    /// Real TCP teardown must not require rebuilding the surviving UDP terminal.
    /// Config is supplied only by the disposable-VPS integration runner.
    @MainActor
    func test_liveRawMoshAgentCarrierRecoversWithoutRestartingTerminal() async throws {
        let config = try Config.load()
        let session = MoshSession(host: makeHost(config: config, transport: .mosh))
        var output = ""
        let pump = Task { @MainActor in
            for await bytes in session.outputStream {
                output += String(decoding: bytes, as: UTF8.self)
                if output.utf8.count > 256 * 1024 { output = String(output.suffix(128 * 1024)) }
            }
        }
        defer { pump.cancel(); session.disconnect() }
        _ = try await connect(session: session,
            pendingRequest: { session.pendingHostKeyVerification }, timeout: 35)

        let attemptID = try XCTUnwrap(session.appleActiveSessionAttemptID)
        let serverPID = try XCTUnwrap(session.remoteServerPID)
        let originalLease = try XCTUnwrap(session.agentReadCarrierIDForTesting)
        let token = "TESSERA_CARRIER_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        session.send(Array("TESSERA_CARRIER_TEST_TOKEN='\(token)'; printf '%s_READY\\n' \"$TESSERA_CARRIER_TEST_TOKEN\"\n".utf8))
        try await waitUntil("initial raw-Mosh shell", timeout: 15) { output.contains(token + "_READY") }
        let initialSnapshotValue = await session.detectForegroundProcessSnapshotIfAvailable(rootPID: serverPID)
        let initialSnapshot = try XCTUnwrap(initialSnapshotValue)
        XCTAssertFalse(initialSnapshot.processIDs.isEmpty)
        let installationBefore = try await RemoteAgentLifecycleIntegrationInstaller.probe {
            try await session.executeAgentIntegrationProbeCommand($0)
        }

        await session.dropAgentReadCarrierForTesting()
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.appleActiveSessionAttemptID, attemptID)
        XCTAssertEqual(session.remoteServerPID, serverPID)

        // Concurrent detection consumers must share the one replacement route.
        async let installationAfter = RemoteAgentLifecycleIntegrationInstaller.probe {
            try await session.executeAgentIntegrationProbeCommand($0)
        }
        async let recoveredSnapshotValue = session.detectForegroundProcessSnapshotIfAvailable(rootPID: serverPID)
        let (recoveredInstallation, recoveredSnapshotOptional) = try await (installationAfter, recoveredSnapshotValue)
        let recoveredSnapshot = try XCTUnwrap(recoveredSnapshotOptional)
        XCTAssertEqual(recoveredInstallation, installationBefore)
        XCTAssertFalse(recoveredSnapshot.processIDs.intersection(initialSnapshot.processIDs).isEmpty)
        XCTAssertNotEqual(session.agentReadCarrierIDForTesting, originalLease)
        XCTAssertNil(session.pendingHostKeyVerification, "trusted auxiliary renewal must not prompt again")
        XCTAssertEqual(session.appleActiveSessionAttemptID, attemptID)
        XCTAssertEqual(session.remoteServerPID, serverPID)

        // A fresh Mosh session would lose this unexported shell variable.
        session.send(Array("printf '%s_RECOVERED\\n' \"$TESSERA_CARRIER_TEST_TOKEN\"\n".utf8))
        try await waitUntil("same raw-Mosh shell after auxiliary reconnect", timeout: 15) {
            output.contains(token + "_RECOVERED")
        }
        XCTAssertEqual(session.state, .connected)
    }

    /// A host restart takes the detached `mosh-server` with it, and mosh's
    /// client has no timeout: the session must ask the host over SSH and act
    /// only when the host answers that the server is gone. A stopped server is
    /// the negative control — unreachable but alive, it must stay connected.
    /// Signalling the server's PID is the same loss without rebooting a shared
    /// fixture.
    @MainActor
    func test_liveMoshTmuxServerLossEndsTheSessionOnlyWhenTheHostSaysGone() async throws {
        let config = try Config.load()
        let tmuxSession = try runOwnedTmuxSessionName(
            "ios-serverloss", token: String(UUID().uuidString.prefix(8).lowercased()))
        let helper = SSHSession(host: makeHost(config: config, transport: .ssh))
        _ = try await connect(session: helper,
            pendingRequest: { helper.pendingHostKeyVerification }, timeout: 35)

        var moshHost = makeHost(config: config, transport: .mosh)
        moshHost.autoTmux = true
        moshHost.launchMode = .pinnedTmux
        moshHost.tmuxSessionName = tmuxSession
        moshHost.launchCommand = nil
        let session = MoshSession(host: moshHost)
        var replacement: MoshSession?
        var stoppedServer: StoppedMoshServer?

        func cleanUp() async {
            session.disconnect()
            replacement?.disconnect()
            if let server = stoppedServer {
                // A server left stopped outlives its session and client and
                // makes the next native gate refuse the fixture account.
                do {
                    _ = try await signalMoshServer(server, "CONT", using: helper)
                    stoppedServer = nil
                } catch {
                    XCTFail("stopped mosh-server \(server.pid) was not confirmed continued: \(error)")
                }
            }
            let view = AutoTmuxCommands.moshViewSessionName(for: tmuxSession)
            _ = try? await helper.executeConnectedCommand(
                "tmux kill-session -t '\(view)' >/dev/null 2>&1; tmux kill-session -t '\(tmuxSession)' >/dev/null 2>&1; true"
            )
            helper.disconnect()
        }

        do {
            _ = try await connect(session: session,
                pendingRequest: { session.pendingHostKeyVerification }, timeout: 35)
            try await waitUntil("mosh transport reachable", timeout: 15) {
                session.transportState == .connected
            }
            let serverPID = try XCTUnwrap(session.remoteServerPID)

            // Unreachable but alive: the host answers `alive`, nothing ends.
            // Record the resume obligation before signalling: a STOP whose
            // reply is lost still left the server stopped.
            let server = try await moshServerIdentity(serverPID, using: helper)
            stoppedServer = server
            let paused = try await signalMoshServer(server, "STOP", using: helper)
            XCTAssertEqual(paused, .confirmed, "the run-owned mosh-server must still exist to be stopped")
            try await waitUntil("stopped server unreachable", timeout: 20) {
                session.transportState == .disconnected
            }
            try await waitUntil("host answers alive for a stopped server", timeout: 30) {
                session.serverLivenessLastOutcomeForTesting == .alive
            }
            XCTAssertEqual(session.state, .connected)
            XCTAssertFalse(session.recommendsReconnectAfterServerLoss)
            let resumed = try await signalMoshServer(server, "CONT", using: helper)
            stoppedServer = nil
            XCTAssertEqual(resumed, .confirmed, "the stopped mosh-server must be continued, not lost")
            try await waitUntil("resumed server reachable again", timeout: 20) {
                session.transportState == .connected
            }
            XCTAssertEqual(session.state, .connected)
            XCTAssertEqual(session.remoteServerPID, serverPID)

            // Gone: the session ends and asks to be rebuilt.
            _ = try await helper.executeConnectedCommand("kill -KILL \(serverPID)")
            try await waitUntil("killed server unreachable", timeout: 20) {
                session.transportState == .disconnected
            }
            try await waitUntil("session fails once the host says gone", timeout: 30) {
                if case .failed = session.state { return true }
                return false
            }
            XCTAssertTrue(session.recommendsReconnectAfterServerLoss)
            XCTAssertEqual(session.serverLivenessLastOutcomeForTesting, .gone)
            XCTAssertNil(session.remoteServerPID)

            // ContentView's rebuild: same host snapshot on a fresh server.
            let rebuilt = MoshSession(host: session.host)
            replacement = rebuilt
            _ = try await connect(session: rebuilt,
                pendingRequest: { rebuilt.pendingHostKeyVerification }, timeout: 35)
            try await waitUntil("rebuilt session reachable", timeout: 15) {
                rebuilt.transportState == .connected
            }
            let rebuiltPID = try XCTUnwrap(rebuilt.remoteServerPID)
            XCTAssertNotEqual(rebuiltPID, serverPID)
            XCTAssertFalse(rebuilt.recommendsReconnectAfterServerLoss)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    /// Optimized audit measurement using the production contrast-filter implementation
    /// and actual SSH output chunk sizes delivered by the stable VPS. Run the
    /// same harness on baseline and candidate checkouts for the A/B result.
    @MainActor
    func test_liveSSHPrintableContrastFilterPerformanceAudit() async throws {
        guard ProcessInfo.processInfo.environment["TESSERA_RUN_PERFORMANCE_AUDIT"] == "1" else {
            throw XCTSkip("Release performance audit is opt-in")
        }
        let config = try Config.load()
        await resetConnectionState(endpoint: "\(config.stableHost):\(config.port)")
        let session = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { session.disconnect() }

        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )

        let payloadByteCount = 16 * 1_024 * 1_024
        let markerPrefix = "TESSERA_PERF_"
        let markerSuffix = "COMPLETE_\(UUID().uuidString)"
        let marker = markerPrefix + markerSuffix
        let script = "import sys; "
            + "sys.stdout.buffer.write(b'x' * \(payloadByteCount)); "
            + "sys.stdout.buffer.write(b'\\n' + b'\(markerPrefix)' "
            + "+ b'\(markerSuffix)' + b'\\n'); "
            + "sys.stdout.buffer.flush()"
        session.send(Array("python3 -c \(shellQuote(script))\n".utf8))

        let received = try await collectOutputChunks(
            session.outputStream,
            containing: marker,
            timeout: 30
        )
        let printableChunks = received.filter { chunk in
            !chunk.contains(0x1B) && !chunk.contains(0x9B)
        }
        let receivedByteCount = printableChunks.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThanOrEqual(receivedByteCount, payloadByteCount)

        var validationFilter = TerminalOutputContrastFilter()
        for chunk in printableChunks {
            let output = validationFilter.process(
                chunk[...],
                defaultBackgroundRGB: 0x101010,
                defaultForegroundRGB: 0xD4D4D4,
                minimumContrast: 0.30
            )
            XCTAssertEqual(Array(output), chunk)
        }

        var samples: [Double] = []
        var checksum: Int?
        for _ in 0..<5 {
            let sample = timePrintableFilter(printableChunks)
            samples.append(sample.milliseconds)
            if let checksum {
                XCTAssertEqual(sample.checksum, checksum)
            } else {
                checksum = sample.checksum
            }
        }
        samples.sort()
        let sampleText = samples
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")

        NSLog(
            "live-ssh-contrast bytes=%d chunks=%d "
                + "filterMedianMs=%.3f filterMaxMs=%.3f checksum=%d samplesMs=%@",
            receivedByteCount,
            printableChunks.count,
            samples[2],
            samples[4],
            checksum ?? 0,
            sampleText
        )
    }

    @MainActor
    func test_liveSSHInformedTOFUMismatchRequiresExplicitUnsafeOverride() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)

        var host = makeHost(config: config, transport: .ssh)
        let stalePeerFingerprint = "SHA256:"
            + Data(repeating: 0, count: 32).base64EncodedString()
        host.continuationHostKeyFingerprints[host.id] = stalePeerFingerprint
        host.continuationPeerLabel = "fixture iPad"

        let rejected = SSHSession(host: host)
        rejected.connect()
        let firstRequest = try await waitForHostKeyRequest(
            { rejected.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertEqual(firstRequest.peerFingerprint, stalePeerFingerprint)
        XCTAssertEqual(firstRequest.peerLabel, "fixture iPad")
        XCTAssertEqual(firstRequest.peerFingerprintMatches, false)
        firstRequest.reject()
        try await waitUntil("informed TOFU rejection", timeout: 10) {
            if case .failed = rejected.state { return true }
            return false
        }
        rejected.disconnect()
        let fingerprintAfterRejection = await KnownHostsStore.shared.trustedFingerprint(
            for: endpoint
        )
        XCTAssertNil(
            fingerprintAfterRejection,
            "the promoted safe action must not create a local trust pin"
        )

        let overridden = SSHSession(host: host)
        defer { overridden.disconnect() }
        overridden.connect()
        let secondRequest = try await waitForHostKeyRequest(
            { overridden.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertEqual(secondRequest.peerFingerprintMatches, false)
        secondRequest.accept()
        try await waitUntil("explicit informed TOFU override", timeout: 20) {
            overridden.state == .connected
        }

        let trusted = await KnownHostsStore.shared.list().first {
            $0.id == endpoint
        }
        XCTAssertNotNil(trusted)
        XCTAssertNil(
            trusted?.matchedPeerLabel,
            "a mismatching peer hint must never be recorded as corroboration"
        )
    }

    @MainActor
    func test_liveSSHWrongPasswordIsClassifiedAsFailure() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)
        var host = makeHost(config: config, transport: .ssh)
        host.password = config.password + "-wrong"
        let session = SSHSession(host: host)
        defer { session.disconnect() }

        session.connect()
        let message = try await waitForFailure(
            state: { session.state },
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("auth")
                || message.localizedCaseInsensitiveContains("permission")
                || message.localizedCaseInsensitiveContains("credential"),
            "unexpected authentication error: \(message)"
        )
    }

    @MainActor
    func test_liveMoshWrongPasswordIsClassifiedAsFailure() async throws {
        let config = try Config.load()
        let endpoint = "\(config.chaosHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)
        var host = makeHost(config: config, transport: .mosh, useChaosHost: true)
        host.password = config.password + "-wrong"
        let session = MoshSession(host: host)
        defer { session.disconnect() }

        session.connect()
        let message = try await waitForFailure(
            state: { session.state },
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 35
        )
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("auth")
                || message.localizedCaseInsensitiveContains("permission")
                || message.localizedCaseInsensitiveContains("credential"),
            "unexpected mosh authentication error: \(message)"
        )
    }

    @MainActor
    func test_liveSSHAndMoshPreserveLargeRawInputPayload() async throws {
        let config = try Config.load()
        let payload = makeInputPayload()
        let expectedDigest = SHA256.hash(data: Data(payload))
            .map { String(format: "%02x", $0) }
            .joined()

        let ssh = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { ssh.disconnect() }
        _ = try await connect(
            session: ssh,
            pendingRequest: { ssh.pendingHostKeyVerification },
            timeout: 20
        )
        try await assertRawPayload(
            session: ssh,
            payload: payload,
            expectedDigest: expectedDigest,
            label: "ssh",
            timeout: 12
        )
        ssh.disconnect()

        let mosh = MoshSession(
            host: makeHost(config: config, transport: .mosh, useChaosHost: true)
        )
        defer { mosh.disconnect() }
        _ = try await connect(
            session: mosh,
            pendingRequest: { mosh.pendingHostKeyVerification },
            timeout: 35
        )
        try await assertRawPayload(
            session: mosh,
            payload: payload,
            expectedDigest: expectedDigest,
            label: "mosh",
            timeout: 18
        )
    }

    @MainActor
    func test_liveAgentIntegrationInstallAndRuntimeDetection() async throws {
        let config = try Config.load()
        let session = SSHSession(host: makeHost(config: config, transport: .ssh))
        defer { session.disconnect() }
        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )

        let suffix = UUID().uuidString.lowercased()
        let home = "/tmp/tessera-agent-center-\(suffix)"
        let tmuxSession = "tessera-agent-\(suffix.prefix(10))"
        let quotedHome = shellQuote(home)
        let prefix = "HOME=\(quotedHome); SHELL=/bin/zsh; umask 002; export HOME SHELL; "
        // A body that runs several hooks drops a marker before its final
        // sleep. Wait for it: each Python hook takes a few hundred ms on a
        // single-CPU fixture, so a fixed sleep raced the last hook.
        func awaitBodyMarker(_ name: String) -> String {
            "tessera_wait=0; while [ ! -e \"$HOME/\(name)\" ] && [ \"$tessera_wait\" -lt 150 ]; do "
                + "sleep 0.1; tessera_wait=$((tessera_wait + 1)); done"
        }
        let integrationVersion = RemoteAgentLifecycleIntegrationInstaller.integrationVersion
        let expectedLoadedVersions = "\(integrationVersion)|\(integrationVersion)"
        let existingCodexHooks = #"{"description":"preserve this user description","hooks":{"SessionStart":[{"matcher":"user","hooks":[{"type":"command","command":"user-session-hook"}]}],"CustomEvent":[{"hooks":[{"type":"command","command":"user-custom-hook"}]}]}}"#
        let existingClaudeSettings = #"{"theme":"dark","permissions":{"allow":["Read"]},"hooks":{"SessionStart":[{"matcher":"user","hooks":[{"type":"command","command":"user-claude-session-hook"}]}]}}"#
        _ = try await session.executeConnectedCommand(
            "rm -rf \(quotedHome); mkdir -p \(quotedHome); "
                + "mkdir -p \(quotedHome)/.codex \(quotedHome)/.claude \(quotedHome)/dotfiles; "
                + "printf '%s\\n' \(shellQuote(existingCodexHooks)) > \(quotedHome)/dotfiles/codex-hooks.json; "
                + "ln -s \(quotedHome)/dotfiles/codex-hooks.json \(quotedHome)/.codex/hooks.json; "
                + "printf '%s\\n' \(shellQuote(existingClaudeSettings)) > \(quotedHome)/dotfiles/claude-settings.json; "
                + "ln -s \(quotedHome)/dotfiles/claude-settings.json \(quotedHome)/.claude/settings.json; "
                + "printf 'existing-bash-without-newline' > \(quotedHome)/.bashrc; "
                + "printf 'existing-zsh-without-newline' > \(quotedHome)/.zshrc"
        )

        var spawnedPIDs: [Int] = []
        do {
            print("TESSERA_AGENT_LIVE_STAGE initial-install")
            // Exercise the complete production install over stdin. A scripts-
            // only fixture cannot satisfy the native artifact integrity probe.
            try await RemoteAgentLifecycleIntegrationInstaller.installNativeAndLifecycle { command in
                // Production deliberately derives HOME from the account, not
                // the environment. Keep this fixture's install run-scoped.
                let isolated = command.replacingOccurrences(of: "home=pwd.getpwuid(os.geteuid()).pw_dir", with: "home=os.environ[\"HOME\"]")
                return try await session.executeAgentInstallationCommand(prefix + isolated)
            }
            print("TESSERA_AGENT_LIVE_STAGE initial-probe")
            let installation = try await RemoteAgentLifecycleIntegrationInstaller.probe {
                command in
                try await session.executeConnectedCommand(prefix + command)
            }
            XCTAssertEqual(installation, .current)

            let codexMergeOutput = try await session.executeConnectedCommand(
                prefix
                    + "test -L \"$HOME/.codex/hooks.json\" && "
                    + "test \"$(readlink \"$HOME/.codex/hooks.json\")\" = \"$HOME/dotfiles/codex-hooks.json\" && "
                    + "grep -Fq 'preserve this user description' \"$HOME/.codex/hooks.json\" && "
                    + "grep -Fq 'user-session-hook' \"$HOME/.codex/hooks.json\" && "
                    + "grep -Fq 'user-custom-hook' \"$HOME/.codex/hooks.json\" && "
                    + "test \"$(grep -Fo 'codex SessionStart idle session-start' \"$HOME/.codex/hooks.json\" | wc -l | tr -d '[:space:]')\" = 1 && "
                    + "printf 'TESSERA_AGENT_CODEX_MERGE_OK\\n'"
            )
            XCTAssertTrue(
                codexMergeOutput.contains("TESSERA_AGENT_CODEX_MERGE_OK"),
                codexMergeOutput
            )
            let claudeMergeOutput = try await session.executeConnectedCommand(
                prefix
                    + "test -L \"$HOME/.claude/settings.json\" && "
                    + "test \"$(readlink \"$HOME/.claude/settings.json\")\" = \"$HOME/dotfiles/claude-settings.json\" && "
                    + "grep -Fq '\"theme\":\"dark\"' \"$HOME/.claude/settings.json\" && "
                    + "grep -Fq 'user-claude-session-hook' \"$HOME/.claude/settings.json\" && "
                    + "test \"$(grep -Fo 'claude SessionStart idle session-start' \"$HOME/.claude/settings.json\" | wc -l | tr -d '[:space:]')\" = 1 && "
                    + "printf 'TESSERA_AGENT_CLAUDE_MERGE_OK\\n'"
            )
            XCTAssertTrue(
                claudeMergeOutput.contains("TESSERA_AGENT_CLAUDE_MERGE_OK"),
                claudeMergeOutput
            )
            let legacyClaudeOutput = try await session.executeConnectedCommand(
                prefix
                    + "test -r \"$HOME/.config/tessera/claude-agent-hooks.json\" && "
                    + "grep -Fq 'claude SessionStart idle session-start' \"$HOME/.config/tessera/claude-agent-hooks.json\" && "
                    + "grep -Fq 'claude PermissionRequest waitingForInput permission' \"$HOME/.config/tessera/claude-agent-hooks.json\" && "
                    + "printf 'TESSERA_AGENT_CLAUDE_LEGACY_OK\\n'"
            )
            XCTAssertTrue(
                legacyClaudeOutput.contains("TESSERA_AGENT_CLAUDE_LEGACY_OK"),
                legacyClaudeOutput
            )

            print("TESSERA_AGENT_LIVE_STAGE generated-script-syntax")
            let syntaxOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/sh -n \"$HOME/.config/tessera/agent-lifecycle-hook.sh\" && "
                    + "/bin/sh -n \"$HOME/.config/tessera/agent-launch.sh\" && "
                    + "/bin/sh -n \"$HOME/.config/tessera/agent-codex-readiness.sh\" && "
                    + "/bin/sh -n \"$HOME/.config/tessera/bin/claude\" && "
                    + "/bin/sh -n \"$HOME/.config/tessera/bin/codex\" && "
                    + "/bin/bash -n \"$HOME/.config/tessera/agent-lifecycle.sh\" && "
                    + "{ if command -v zsh >/dev/null 2>&1; then "
                    + "zsh -n \"$HOME/.config/tessera/agent-lifecycle.sh\"; fi; } && "
                    + "printf 'TESSERA_AGENT_SYNTAX_OK\\n'"
            )
            XCTAssertTrue(syntaxOutput.contains("TESSERA_AGENT_SYNTAX_OK"), syntaxOutput)

            print("TESSERA_AGENT_LIVE_STAGE executable-status")
            _ = try await session.executeConnectedCommand(
                prefix + "chmod 600 \"$HOME/.config/tessera/agent-launch.sh\""
            )
            let nonExecutableInstallation = try await RemoteAgentLifecycleIntegrationInstaller.probe {
                command in
                try await session.executeConnectedCommand(prefix + command)
            }
            XCTAssertEqual(nonExecutableInstallation, .missing)
            _ = try await session.executeConnectedCommand(
                prefix + "chmod 700 \"$HOME/.config/tessera/agent-launch.sh\""
            )
            let restoredInstallation = try await RemoteAgentLifecycleIntegrationInstaller.probe {
                command in
                try await session.executeConnectedCommand(prefix + command)
            }
            XCTAssertEqual(restoredInstallation, .current)

            let rcOutput = try await session.executeConnectedCommand(
                prefix
                    + "test -f \"$HOME/.zshrc\" && "
                    + "grep -qFx 'existing-bash-without-newline' \"$HOME/.bashrc\" && "
                    + "grep -qFx 'existing-zsh-without-newline' \"$HOME/.zshrc\" && "
                    + "grep -qF 'TESSERA-AGENT-LIFECYCLE' \"$HOME/.bashrc\" && "
                    + "grep -qF 'TESSERA-AGENT-LIFECYCLE' \"$HOME/.zshrc\" && "
                    + "test \"$(stat -c %a \"$HOME/.config/tessera\")\" = 700 && "
                    + "test \"$(stat -c %a \"$HOME/.config/tessera/bin\")\" = 700 && "
                    + "printf 'TESSERA_AGENT_RC_OK\\n'"
            )
            XCTAssertTrue(rcOutput.contains("TESSERA_AGENT_RC_OK"))

            // A later, unrelated startup file must not invalidate the shell
            // actually selected by $SHELL.
            _ = try await session.executeConnectedCommand(
                prefix + "printf 'unrelated-bash-config\\n' > \"$HOME/.bashrc\""
            )
            let zshStillCurrent = try await RemoteAgentLifecycleIntegrationInstaller.probe {
                command in
                try await session.executeConnectedCommand(prefix + command)
            }
            XCTAssertEqual(zshStillCurrent, .current)

            // Bash login shells do not necessarily read ~/.bashrc. A repair
            // performed with bash as the configured shell must install and
            // verify the guarded login startup line too.
            print("TESSERA_AGENT_LIVE_STAGE bash-login-install")
            let bashPrefix = "HOME=\(quotedHome); SHELL=/bin/bash; export HOME SHELL; "
            try await RemoteAgentLifecycleIntegrationInstaller.install { command in
                try await session.executeConnectedCommand(bashPrefix + command)
            }
            print("TESSERA_AGENT_LIVE_STAGE bash-login-launch")
            let bashLoginOutput = try await session.executeConnectedCommand(
                bashPrefix
                    + "/bin/bash --login -i -c "
                    + shellQuote(
                        #"printf 'TESSERA_AGENT_BASH_LOGIN=%s|%s\n' "${TESSERA_AGENT_INTEGRATION_VERSION:-}" "${TESSERA_AGENT_SHIM_VERSION:-}""#
                    )
            )
            XCTAssertTrue(
                bashLoginOutput.contains("TESSERA_AGENT_BASH_LOGIN=\(expectedLoadedVersions)")
            )

            // zsh resolves .zshrc relative to ZDOTDIR when set.
            let zdotPrefix = prefix
                + "ZDOTDIR=\"$HOME/custom-zdot\"; export ZDOTDIR; "
            print("TESSERA_AGENT_LIVE_STAGE zdot-install")
            try await RemoteAgentLifecycleIntegrationInstaller.install { command in
                try await session.executeConnectedCommand(zdotPrefix + command)
            }
            print("TESSERA_AGENT_LIVE_STAGE zdot-verify")
            let zdotOutput = try await session.executeConnectedCommand(
                zdotPrefix
                    + "if [ ! -f \"$ZDOTDIR/.zshrc\" ]; then printf 'TESSERA_AGENT_ZDOTDIR_MISSING=%s\\n' \"$ZDOTDIR/.zshrc\"; "
                    + "elif grep -qFx "
                    + shellQuote(RemoteAgentLifecycleIntegrationInstaller.rcMarkerLine)
                    + " \"$ZDOTDIR/.zshrc\"; then printf 'TESSERA_AGENT_ZDOTDIR_OK\\n'; "
                    + "else printf 'TESSERA_AGENT_ZDOTDIR_MARKER_MISSING\\n'; fi"
            )
            XCTAssertTrue(
                zdotOutput.contains("TESSERA_AGENT_ZDOTDIR_OK"),
                zdotOutput
            )

            print("TESSERA_AGENT_LIVE_STAGE inherited-child")
            let childOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c "
                    + shellQuote(
                        #". "$HOME/.config/tessera/agent-lifecycle.sh"; exec sleep 20"#
                    )
                    + " >/dev/null 2>&1 & printf 'TESSERA_AGENT_CHILD_PID=%s\\n' \"$!\""
            )
            let childPID = try XCTUnwrap(
                integerValue(after: "TESSERA_AGENT_CHILD_PID=", in: childOutput)
            )
            spawnedPIDs.append(childPID)
            var childShellActive: Bool?
            for _ in 0..<10 where childShellActive != true {
                let childStatus = try await session.executeConnectedCommand(
                    prefix
                        + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                            processIDs: [childPID]
                        )
                )
                childShellActive = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(
                    childStatus
                )
                if childShellActive != true {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            XCTAssertEqual(
                childShellActive,
                true,
                "a foreground child such as vim that inherited the v8 environment must stay ready"
            )

            print("TESSERA_AGENT_LIVE_STAGE stripped-path-child")
            let strippedChildOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c "
                    + shellQuote(
                        #". "$HOME/.config/tessera/agent-lifecycle.sh"; PATH=/usr/bin:/bin; export PATH; exec sleep 20"#
                    )
                    + " >/dev/null 2>&1 & printf 'TESSERA_AGENT_STRIPPED_PID=%s\\n' \"$!\""
            )
            let strippedChildPID = try XCTUnwrap(
                integerValue(
                    after: "TESSERA_AGENT_STRIPPED_PID=",
                    in: strippedChildOutput
                )
            )
            spawnedPIDs.append(strippedChildPID)
            let strippedChildStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [strippedChildPID]
                    )
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(
                    strippedChildStatus
                ),
                true,
                "a foreground child remains in an activated shell even if it changes PATH: \(strippedChildStatus)"
            )

            print("TESSERA_AGENT_LIVE_STAGE nested-shell")
            // Keep a command after the nested shell so Bash cannot optimize
            // its final child into an `exec` that legitimately preserves the
            // sourced process's PID/start identity.
            let nestedBody = #". "$HOME/.config/tessera/agent-lifecycle.sh"; /bin/bash --noprofile --norc -c 'printf "%s\n" "$$" > "$HOME/nested-shell.pid"; while :; do sleep 1; done'; :"#
            _ = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c \(shellQuote(nestedBody)) "
                    + ">/dev/null 2>&1 & printf 'TESSERA_AGENT_NESTED_LAUNCHED\\n'"
            )
            print("TESSERA_AGENT_LIVE_STAGE nested-launched")
            var nestedPID: Int?
            for _ in 0..<10 where nestedPID == nil {
                let output = try await session.executeConnectedCommand(
                    prefix + "cat \"$HOME/nested-shell.pid\" 2>/dev/null || true"
                )
                nestedPID = Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
                if nestedPID == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            let exactNestedPID = try XCTUnwrap(nestedPID)
            print("TESSERA_AGENT_LIVE_STAGE nested-pid")
            spawnedPIDs.append(exactNestedPID)
            let strictNestedCommand =
                RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                    processIDs: [exactNestedPID],
                    allowInheritedEnvironment: false
                )
            let strictNestedStatus = try await session.executeConnectedCommand(
                prefix
                    + "/bin/sh -c \(shellQuote(strictNestedCommand)) 2>&1 || true"
            )
            print("TESSERA_AGENT_LIVE_STAGE nested-status")
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(strictNestedStatus),
                false,
                "an unsourced nested shell must not be ready merely because it inherited the version: \(strictNestedStatus)"
            )

            // Exercise alias shapes rather than special-casing the physical
            // device's definition. Self-references, `command`, `env`, a
            // differently named shortcut, and a helper function must all keep
            // their arguments while resolving the provider through PATH.
            print("TESSERA_AGENT_LIVE_STAGE alias-matrix")
            _ = try await session.executeConnectedCommand(
                prefix
                    + "mkdir -p \"$HOME/real-bin\"; "
                    + "mkdir -p \"$HOME/real-bin-v2\" \"$HOME/alias-bin\"; "
                    + "ln -sf /bin/echo \"$HOME/real-bin/claude\"; "
                    + "ln -sf /bin/echo \"$HOME/real-bin/codex\"; "
                    + "ln -sf /bin/echo \"$HOME/real-bin-v2/claude\"; "
                    + "ln -sf /bin/echo \"$HOME/real-bin-v2/codex\"; "
                    + "ln -sf \"$HOME/.config/tessera/bin/claude\" \"$HOME/alias-bin/claude\"; "
                    + "ln -sf \"$HOME/.config/tessera/bin/codex\" \"$HOME/alias-bin/codex\""
            )
            let aliasBody = #"PATH="$HOME/real-bin:/usr/bin:/bin"; export PATH; shopt -s expand_aliases; alias claude='claude --allow-dangerously-skip-permissions'; alias codex='codex --version --user-codex-flag'; alias clauded='claude --settings "$HOME/.config/tessera/claude-agent-hooks.json"'; . "$HOME/.config/tessera/agent-lifecycle.sh"; PATH="$HOME/alias-bin:$HOME/real-bin-v2:/usr/bin:/bin"; export PATH; alias claude > "$HOME/alias-definition"; alias clauded > "$HOME/clauded-definition"; eval 'claude --user-claude-flag' > "$HOME/alias-claude-args"; eval 'clauded --resume legacy-session' > "$HOME/alias-clauded-args"; eval 'codex --user-codex-tail' > "$HOME/alias-codex-args"; alias claude='command claude --command-prefix'; alias codex='command codex --version --command-prefix'; eval 'claude --command-tail' > "$HOME/alias-claude-command"; eval 'codex --command-tail' > "$HOME/alias-codex-command"; alias claude='env TESSERA_ALIAS_ENV=claude claude --env-prefix'; alias codex='env TESSERA_ALIAS_ENV=codex codex --version --env-prefix'; eval 'claude --env-tail' > "$HOME/alias-claude-env"; eval 'codex --env-tail' > "$HOME/alias-codex-env"; alias claude='claude --settings "$HOME/custom-claude.json" --custom-settings-prefix'; eval 'claude --custom-settings-tail' > "$HOME/alias-claude-settings"; unalias claude codex; alias tessera_claude='claude --shortcut-prefix'; eval 'tessera_claude --shortcut-tail' > "$HOME/alias-claude-shortcut"; function tessera_codex { command codex --version --function-prefix "$@"; }; tessera_codex --function-tail > "$HOME/alias-codex-function"; env HOME="$HOME/alternate-home" claude --home-change > "$HOME/alias-claude-home-change"; "$HOME/real-bin-v2/claude" --absolute-claude > "$HOME/alias-claude-absolute"; "$HOME/real-bin-v2/codex" --absolute-codex > "$HOME/alias-codex-absolute"; printf '%s|%s|%s\n' "${TESSERA_AGENT_INTEGRATION_VERSION:-}" "${TESSERA_AGENT_SHIM_VERSION:-}" "$PATH" > "$HOME/alias-shell-ready"; exec sleep 20"#
            let aliasOutput = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME/alias-shell-ready\"; "
                    + "/bin/bash --noprofile --norc -c \(shellQuote(aliasBody)) "
                    + ">/dev/null 2>&1 & tessera_alias_pid=$!; "
                    + "tessera_attempt=0; while [ ! -f \"$HOME/alias-shell-ready\" ] && [ \"$tessera_attempt\" -lt 120 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                    + "[ -f \"$HOME/alias-shell-ready\" ] || exit 1; "
                    + "printf 'TESSERA_AGENT_ALIAS_PID=%s\\n' \"$tessera_alias_pid\""
            )
            let aliasPID = try XCTUnwrap(
                integerValue(after: "TESSERA_AGENT_ALIAS_PID=", in: aliasOutput)
            )
            spawnedPIDs.append(aliasPID)
            let aliasStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [aliasPID]
                    )
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(aliasStatus),
                true,
                "a preserved alias and an inherited foreground program must remain active"
            )
            let aliasDiagnostics = try await session.executeConnectedCommand(
                prefix
                    + "printf 'ALIAS='; cat \"$HOME/alias-definition\"; "
                    + "printf 'READY='; cat \"$HOME/alias-shell-ready\"; "
                    + "printf 'CLAUDE='; cat \"$HOME/alias-claude-args\"; "
                    + "printf 'CLAUDED_DEF='; cat \"$HOME/clauded-definition\"; "
                    + "printf 'CLAUDED='; cat \"$HOME/alias-clauded-args\"; "
                    + "printf 'CODEX='; cat \"$HOME/alias-codex-args\"; "
                    + "printf 'CLAUDE_COMMAND='; cat \"$HOME/alias-claude-command\"; "
                    + "printf 'CODEX_COMMAND='; cat \"$HOME/alias-codex-command\"; "
                    + "printf 'CLAUDE_ENV='; cat \"$HOME/alias-claude-env\"; "
                    + "printf 'CODEX_ENV='; cat \"$HOME/alias-codex-env\"; "
                    + "printf 'CLAUDE_SETTINGS='; cat \"$HOME/alias-claude-settings\"; "
                    + "printf 'CLAUDE_SHORTCUT='; cat \"$HOME/alias-claude-shortcut\"; "
                    + "printf 'CODEX_FUNCTION='; cat \"$HOME/alias-codex-function\"; "
                    + "printf 'CLAUDE_HOME_CHANGE='; cat \"$HOME/alias-claude-home-change\"; "
                    + "printf 'CLAUDE_ABSOLUTE='; cat \"$HOME/alias-claude-absolute\"; "
                    + "printf 'CODEX_ABSOLUTE='; cat \"$HOME/alias-codex-absolute\""
            )
            XCTAssertTrue(
                aliasDiagnostics.contains("alias claude='claude --allow-dangerously-skip-permissions'"),
                aliasDiagnostics
            )
            XCTAssertTrue(
                aliasDiagnostics.contains("READY=\(expectedLoadedVersions)|"),
                aliasDiagnostics
            )
            XCTAssertTrue(aliasDiagnostics.contains("/alias-bin:"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("/real-bin-v2:"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--allow-dangerously-skip-permissions"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--user-claude-flag"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--resume legacy-session"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains(".config/tessera/claude-agent-hooks.json"), aliasDiagnostics)
            // These aliases invoke --version. Noninteractive helpers must
            // bypass lifecycle hooks and cannot end the parent conversation.
            XCTAssertFalse(aliasDiagnostics.contains("--enable hooks"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--user-codex-flag"), aliasDiagnostics)
            XCTAssertTrue(aliasDiagnostics.contains("--user-codex-tail"), aliasDiagnostics)
            for argument in [
                "--command-prefix", "--command-tail", "--env-prefix", "--env-tail",
                "--shortcut-prefix", "--shortcut-tail", "--function-prefix", "--function-tail",
                "--custom-settings-prefix", "--custom-settings-tail", "--home-change",
                "--absolute-claude", "--absolute-codex",
            ] {
                XCTAssertTrue(aliasDiagnostics.contains(argument), aliasDiagnostics)
            }
            XCTAssertEqual(
                aliasDiagnostics.components(separatedBy: "--settings").count - 1,
                3,
                "both explicit user aliases must preserve exactly their own settings flag without Tessera injecting one: \(aliasDiagnostics)"
            )
            XCTAssertEqual(
                aliasDiagnostics.components(separatedBy: "--enable hooks").count - 1,
                0,
                aliasDiagnostics
            )

            // A provider-named user function has higher shell precedence.
            // Preserve it byte-for-byte while still marking the shell-level
            // integration as loaded; runtime provider hooks decide whether an
            // agent launched by that function is actually available.
            let functionOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c "
                    + shellQuote(
                        #"function claude { printf 'USER_CLAUDE_FUNCTION=%s\n' "$*"; }; . "$HOME/.config/tessera/agent-lifecycle.sh"; claude untouched; typeset -f claude >/dev/null && printf 'TESSERA_AGENT_FUNCTION=%s|%s\n' "${TESSERA_AGENT_INTEGRATION_VERSION:-}" "${TESSERA_AGENT_SHIM_VERSION:-}""#
                    )
            )
            XCTAssertTrue(
                functionOutput.contains("USER_CLAUDE_FUNCTION=untouched")
                    && functionOutput.contains(
                        "TESSERA_AGENT_FUNCTION=\(expectedLoadedVersions)"
                    ),
                functionOutput
            )

            // Preserve the shell's exact PATH topology, including the unusual
            // but valid empty PATH whose sole empty component means cwd.
            print("TESSERA_AGENT_LIVE_STAGE empty-path")
            let emptyPathOutput = try await session.executeConnectedCommand(
                prefix
                    + "/bin/bash --noprofile --norc -c "
                    + shellQuote(
                        #"PATH=''; export PATH; . "$HOME/.config/tessera/agent-lifecycle.sh"; printf 'TESSERA_AGENT_EMPTY_PATH=%s\n' "$PATH""#
                    )
                    + " 2>/dev/null"
            )
            XCTAssertTrue(
                emptyPathOutput.contains(
                    "TESSERA_AGENT_EMPTY_PATH=\(home)/.config/tessera/bin:"
                ),
                emptyPathOutput
            )

            // zsh has different alias expansion and command hashing rules;
            // keep a live-shell proof for its self-referential and `command`
            // forms as well, since it is the default shell on Apple hosts.
            print("TESSERA_AGENT_LIVE_STAGE zsh-alias")
            let zshPath = try await session.executeConnectedCommand(
                prefix + "command -v zsh 2>/dev/null || true"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !zshPath.isEmpty {
                let zshAliasBody = #"PATH="$HOME/real-bin:/usr/bin:/bin"; export PATH; alias claude='claude --zsh-self'; alias codex='command codex --version --zsh-command'; . "$HOME/.config/tessera/agent-lifecycle.sh"; eval 'claude --zsh-tail' > "$HOME/zsh-alias-claude"; eval 'codex --zsh-tail' > "$HOME/zsh-alias-codex"; kill -WINCH $$; sleep 0.05; printf 'safe\n' > "$HOME/zsh-unrelated-winch"; printf '%s|%s|%s\n' "${TESSERA_AGENT_INTEGRATION_VERSION:-}" "${TESSERA_AGENT_SHIM_VERSION:-}" "$PATH" > "$HOME/zsh-alias-ready"; exec sleep 20"#
                let zshAliasOutput = try await session.executeConnectedCommand(
                    prefix
                        + "rm -f \"$HOME/zsh-alias-ready\"; "
                        + "\(shellQuote(zshPath)) -f -c \(shellQuote(zshAliasBody)) "
                        + ">/dev/null 2>&1 & tessera_zsh_alias_pid=$!; "
                        + "tessera_attempt=0; while [ ! -f \"$HOME/zsh-alias-ready\" ] && [ \"$tessera_attempt\" -lt 80 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                        + "[ -f \"$HOME/zsh-alias-ready\" ] || exit 1; "
                        + "printf 'TESSERA_AGENT_ZSH_ALIAS_PID=%s\\n' \"$tessera_zsh_alias_pid\""
                )
                let zshAliasPID = try XCTUnwrap(
                    integerValue(after: "TESSERA_AGENT_ZSH_ALIAS_PID=", in: zshAliasOutput)
                )
                spawnedPIDs.append(zshAliasPID)
                let zshAliasStatus = try await session.executeConnectedCommand(
                    prefix
                        + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                            processIDs: [zshAliasPID]
                        )
                )
                XCTAssertEqual(
                    RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(zshAliasStatus),
                    true,
                    zshAliasStatus
                )
                let zshAliasDiagnostics = try await session.executeConnectedCommand(
                    prefix
                        + "printf 'READY='; cat \"$HOME/zsh-alias-ready\"; "
                        + "printf 'CLAUDE='; cat \"$HOME/zsh-alias-claude\"; "
                        + "printf 'CODEX='; cat \"$HOME/zsh-alias-codex\"; "
                        + "printf 'WINCH='; cat \"$HOME/zsh-unrelated-winch\""
                )
                XCTAssertTrue(
                    zshAliasDiagnostics.contains("READY=\(expectedLoadedVersions)|"),
                    zshAliasDiagnostics
                )
                XCTAssertTrue(zshAliasDiagnostics.contains("--zsh-self"), zshAliasDiagnostics)
                XCTAssertTrue(zshAliasDiagnostics.contains("--zsh-command"), zshAliasDiagnostics)
                XCTAssertTrue(zshAliasDiagnostics.contains("--zsh-tail"), zshAliasDiagnostics)
                XCTAssertTrue(zshAliasDiagnostics.contains("WINCH=safe"), zshAliasDiagnostics)
                XCTAssertFalse(zshAliasDiagnostics.contains("--settings"), zshAliasDiagnostics)
                XCTAssertFalse(zshAliasDiagnostics.contains("--enable hooks"), zshAliasDiagnostics)
            }

            // A user-owned compound WINCH trap remains byte-for-byte in
            // control. Activation uses process identity and therefore neither
            // replaces the trap nor leaves this otherwise valid shell inactive.
            print("TESSERA_AGENT_LIVE_STAGE compound-winch-trap")
            let compoundTrapBody = #"trap 'printf "user-winch\n" >> "$HOME/compound-winch-fired"; :' WINCH; . "$HOME/.config/tessera/agent-lifecycle.sh"; trap -p WINCH > "$HOME/compound-winch-definition"; printf '%s\n' "$$" > "$HOME/compound-winch-pid"; while :; do sleep 1; done"#
            let compoundTrapLaunch = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME/compound-winch-fired\" \"$HOME/compound-winch-pid\"; "
                    + "/bin/bash --noprofile --norc -c \(shellQuote(compoundTrapBody)) "
                    + ">\"$HOME/compound-winch-launch.log\" 2>&1 & "
                    + "tessera_attempt=0; while [ ! -f \"$HOME/compound-winch-pid\" ] && [ \"$tessera_attempt\" -lt 40 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                    + "if [ -f \"$HOME/compound-winch-pid\" ]; then printf 'TESSERA_AGENT_COMPOUND_TRAP_READY\\n'; "
                    + "else printf 'TESSERA_AGENT_COMPOUND_TRAP_MISSING\\n'; cat \"$HOME/compound-winch-launch.log\" 2>/dev/null || true; fi"
            )
            XCTAssertTrue(
                compoundTrapLaunch.contains("TESSERA_AGENT_COMPOUND_TRAP_READY"),
                compoundTrapLaunch
            )
            let compoundTrapPIDOutput = try await session.executeConnectedCommand(
                prefix + "cat \"$HOME/compound-winch-pid\""
            )
            let compoundTrapPID = try XCTUnwrap(
                Int(compoundTrapPIDOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            )
            spawnedPIDs.append(compoundTrapPID)
            let compoundTrapStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [compoundTrapPID],
                        allowInheritedEnvironment: false
                    )
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(compoundTrapStatus),
                true,
                compoundTrapStatus
            )
            let compoundTrapDiagnostics = try await session.executeConnectedCommand(
                prefix
                    + "kill -WINCH \(compoundTrapPID); "
                    + "tessera_attempt=0; while [ ! -s \"$HOME/compound-winch-fired\" ] && [ \"$tessera_attempt\" -lt 40 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                    + "printf 'TRAP='; cat \"$HOME/compound-winch-definition\"; "
                    + "printf 'FIRED='; cat \"$HOME/compound-winch-fired\" 2>/dev/null || true"
            )
            XCTAssertTrue(
                compoundTrapDiagnostics.contains("user-winch")
                    && compoundTrapDiagnostics.contains("FIRED=user-winch"),
                compoundTrapDiagnostics
            )

            // `exec` preserves PID/start time and the exported activation/PATH.
            // The replacement shell is therefore still integrated even though
            // it did not source an rc file of its own.
            print("TESSERA_AGENT_LIVE_STAGE exec-shell")
            let execShellBody = #". "$HOME/.config/tessera/agent-lifecycle.sh"; exec /bin/bash --noprofile --norc -c ': > "$HOME/exec-shell-ready"; while :; do sleep 1; done'"#
            let execShellOutput = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME/exec-shell-ready\"; "
                    + "/bin/bash --noprofile --norc -c \(shellQuote(execShellBody)) "
                    + ">/dev/null 2>&1 & tessera_exec_pid=$!; "
                    + "tessera_attempt=0; while [ ! -f \"$HOME/exec-shell-ready\" ] && [ \"$tessera_attempt\" -lt 20 ]; do tessera_attempt=$((tessera_attempt + 1)); sleep 0.05; done; "
                    + "[ -f \"$HOME/exec-shell-ready\" ] || exit 1; "
                    + "printf 'TESSERA_AGENT_EXEC_PID=%s\\n' \"$tessera_exec_pid\""
            )
            let execShellPID = try XCTUnwrap(
                integerValue(after: "TESSERA_AGENT_EXEC_PID=", in: execShellOutput)
            )
            spawnedPIDs.append(execShellPID)
            let execShellStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [execShellPID],
                        allowInheritedEnvironment: false
                    )
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(execShellStatus),
                true,
                "an exec-replaced shell must retain inherited activation"
            )

            // tmux servers outlive this exec channel and therefore retain
            // their original HOME. Pass the isolated fixture home into the
            // pane explicitly instead of relying on update-environment.
            print("TESSERA_AGENT_LIVE_STAGE tmux-marker")
            let tmuxCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "/bin/bash --noprofile --norc"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "tmux new-session -d -s \(tmuxSession) \(tmuxCommand); "
                    + "tmux send-keys -t \(tmuxSession):0.0 "
                    + shellQuote(#". "$HOME/.config/tessera/agent-lifecycle.sh"; trap -p WINCH > "$HOME/tmux-winch-trap"; printf '%s\n' "$$" > "$HOME/tmux-shell-pid""#)
                    + " Enter; "
                    + "sleep 1"
            )
            let tmuxOutput = try await session.executeConnectedCommand(
                prefix
                    + "tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{pane_pid}|#{pane_current_command}|#{@tessera_agent_shell}")
            )
            let tmuxFields = try XCTUnwrap(tmuxOutput
                .split(whereSeparator: \.isNewline)
                .last?
                .split(separator: "|", omittingEmptySubsequences: false))
            guard tmuxFields.count == 3 else {
                throw IntegrationError.failed("invalid tmux integration probe: \(tmuxOutput)")
            }
            XCTAssertEqual(String(tmuxFields[1]), "bash")
            let panePID = try XCTUnwrap(Int(tmuxFields[0]))
            let markerFields = tmuxFields[2].split(
                separator: ":",
                omittingEmptySubsequences: false
            )
            XCTAssertEqual(markerFields.count, 3)
            XCTAssertEqual(
                markerFields.first.flatMap { Int($0) },
                RemoteAgentLifecycleIntegrationInstaller.integrationVersion
            )
            XCTAssertEqual(markerFields.dropFirst().first.flatMap { Int($0) }, panePID)
            XCTAssertEqual(
                markerFields.last.flatMap { Int($0) },
                RemoteAgentLifecycleIntegrationInstaller.integrationVersion
            )
            let tmuxStatus = try await session.executeConnectedCommand(
                prefix
                    + RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: [panePID]
                    )
            )
            let tmuxProbeDiagnostics = try await session.executeConnectedCommand(
                prefix
                    + "printf 'PANE=%s SHELL=' \(shellQuote(String(panePID))); "
                    + "cat \"$HOME/tmux-shell-pid\" 2>/dev/null || true; "
                    + "printf ' TRAP='; cat \"$HOME/tmux-winch-trap\" 2>/dev/null || true; "
                    + "printf ' MARKER='; cat \"$HOME/.config/tessera/active-shells/\(panePID)\" 2>/dev/null || true"
            )
            XCTAssertEqual(
                RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(tmuxStatus),
                true,
                "\(tmuxStatus) \(tmuxProbeDiagnostics)"
            )

            print("TESSERA_AGENT_LIVE_STAGE concurrent-shell-probes")
            let concurrentProbe =
                RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                    processIDs: [panePID],
                    allowInheritedEnvironment: false
                )
            let concurrentOutput = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME\"/concurrent-probe.*; tessera_probe="
                    + shellQuote(concurrentProbe)
                    + "; tessera_index=1; while [ \"$tessera_index\" -le 8 ]; do "
                    + "/bin/sh -c \"$tessera_probe\" > \"$HOME/concurrent-probe.$tessera_index\" & "
                    + "tessera_index=$((tessera_index + 1)); done; wait; "
                    + "tessera_passed=$(grep -l '^TESSERA_AGENT_SHELL_STATUS active$' \"$HOME\"/concurrent-probe.* 2>/dev/null | wc -l | tr -d '[:space:]'); "
                    + "printf 'TESSERA_AGENT_CONCURRENT=%s\\n' \"$tessera_passed\""
            )
            XCTAssertTrue(
                concurrentOutput.contains("TESSERA_AGENT_CONCURRENT=8"),
                concurrentOutput
            )

            // The launcher alone must never publish availability: hooks may
            // be disabled or untrusted. Then exercise a provider-owned
            // SessionStart and verify its ancestor PID survives the launcher's
            // exec boundary.
            print("TESSERA_AGENT_LIVE_STAGE production-launcher-no-false-ready")
            _ = try await session.executeConnectedCommand(
                prefix
                    + "tmux set-option -pu -t \(tmuxSession):0.0 @tessera_agent_state >/dev/null 2>&1 || true; "
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(
                        "env HOME=\(quotedHome) \(quotedHome)/.config/tessera/agent-launch.sh codex /bin/sleep 2"
                    )
                    + "; sleep 0.2"
            )
            let launcherOnlyState = try await session.executeConnectedCommand(
                prefix
                    + "tmux show-options -pv -t \(tmuxSession):0.0 @tessera_agent_state 2>/dev/null || true"
            )
            XCTAssertTrue(
                launcherOnlyState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                launcherOnlyState
            )

            print("TESSERA_AGENT_LIVE_STAGE production-launcher-provider-hook")
            let launchedProviderBody = #"printf '%s\n' "$$" > "$HOME/launcher-provider.pid"; printf '%s\n' '{"type":"session_meta","payload":{"id":"launcher-session","source":"cli"}}' > "$HOME/launcher-session.jsonl"; printf '{"session_id":"launcher-session","transcript_path":"%s/launcher-session.jsonl"}' "$HOME" | "$HOME/.config/tessera/agent-lifecycle-hook.sh" codex SessionStart idle session-start; exec sleep 20"#
            let launchedProviderCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/.config/tessera/agent-launch.sh codex "
                + "\(quotedHome)/provider-bin/codex -c \(shellQuote(launchedProviderBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "rm -f \"$HOME/launcher-provider.pid\"; mkdir -p \"$HOME/provider-bin\"; "
                    + "ln -sf /bin/sh \"$HOME/provider-bin/codex\"; "
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(launchedProviderCommand)
                    + "; sleep 1"
            )
            let launcherOutput = try await session.executeConnectedCommand(
                prefix
                    + "printf 'PID='; cat \"$HOME/launcher-provider.pid\"; "
                    + "printf 'STATE='; tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
            )
            let launchedPID = try XCTUnwrap(
                integerValue(after: "PID=", in: launcherOutput)
            )
            let launcherJSON = try XCTUnwrap(
                launcherOutput.split(separator: "\n")
                    .first(where: { $0.hasPrefix("STATE=") })
                    .map { String($0.dropFirst("STATE=".count)) }
            )
            let launcherEvent = try XCTUnwrap(
                AgentLifecycleEvent.decode(json: launcherJSON)
            )
            XCTAssertEqual(launcherEvent.provider, "codex")
            XCTAssertEqual(launcherEvent.event, "SessionStart")
            XCTAssertEqual(launcherEvent.state, .idle)
            XCTAssertEqual(launcherEvent.providerSessionID, "launcher-session")
            XCTAssertEqual(launcherEvent.agentPID, launchedPID)

            // Execute the installed production hook under an actual
            // provider-named ancestor. This covers JSON stdin parsing,
            // provider PID binding, and tmux retained-state publication rather
            // than only comparing the generated shell source as a string.
            print("TESSERA_AGENT_LIVE_STAGE production-hook")
            let fakeAgentBody = #"printf '%s\n' '{"type":"session_meta","payload":{"id":"fixture-session","source":"cli"}}' > "$HOME/fixture-session.jsonl"; printf '{"session_id":"fixture-session","turn_id":"fixture-turn","transcript_path":"%s/fixture-session.jsonl"}' "$HOME" | "$HOME/.config/tessera/agent-lifecycle-hook.sh" codex UserPromptSubmit working agent-turn; exec sleep 20"#
            let fakeAgentCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/codex -c \(shellQuote(fakeAgentBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "ln -sf /bin/sh \"$HOME/codex\"; "
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(fakeAgentCommand)
                    + "; sleep 1"
            )
            let lifecycleOutput = try await session.executeConnectedCommand(
                prefix
                    + "tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
            )
            let lifecycleJSON = lifecycleOutput
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? ""
            let lifecycleEvent = try XCTUnwrap(AgentLifecycleEvent.decode(json: lifecycleJSON))
            XCTAssertEqual(lifecycleEvent.provider, "codex")
            XCTAssertEqual(lifecycleEvent.event, "UserPromptSubmit")
            XCTAssertEqual(lifecycleEvent.state, .working)
            XCTAssertEqual(lifecycleEvent.providerSessionID, "fixture-session")
            XCTAssertEqual(lifecycleEvent.turnID, "fixture-turn")
            XCTAssertNotNil(lifecycleEvent.agentPID)

            // Exercise the fallback metadata parser rather than assuming
            // Python exists. Neither a child Stop nor its later SubagentStop
            // boundary may overwrite the root Stop/idle pane state, and a new
            // root boundary must clear stale markers.
            print("TESSERA_AGENT_LIVE_STAGE pythonless-hook")
            let minimalBin = "\(quotedHome)/minimal-bin"
            let toolNames = [
                "base64", "cat", "chmod", "date", "dd", "find", "grep", "head",
                "mkdir", "ps", "rm", "sed", "sleep", "tmux", "tr", "tty",
            ].joined(separator: " ")
            _ = try await session.executeConnectedCommand(
                prefix
                    + "mkdir -p \(minimalBin); for tessera_tool in \(toolNames); do "
                    + "tessera_path=$(command -v \"$tessera_tool\" 2>/dev/null || true); "
                    + "[ -n \"$tessera_path\" ] && ln -sf \"$tessera_path\" \(minimalBin)/\"$tessera_tool\"; done; "
                    + "ln -sf /bin/sh \"$HOME/claude\""
            )
            let pythonlessBody = #"hook="$HOME/.config/tessera/agent-lifecycle-hook.sh"; printf '%s' '{"session_id":"root-session"}' | "$hook" claude UserPromptSubmit working agent-turn; printf '%s' '{"session_id":"root-session","agent_id":"child-1"}' | env PATH="$HOME/minimal-bin" "$hook" claude SubagentStart working subagent-start; printf '%s' '{"session_id":"root-session","agent_id":"child-1"}' | env PATH="$HOME/minimal-bin" "$hook" claude Stop idle turn-stopped; printf '%s' '{"session_id":"root-session"}' | "$hook" claude Stop idle turn-stopped; printf '%s' '{"session_id":"root-session","agent_id":"child-1"}' | env PATH="$HOME/minimal-bin" "$hook" claude SubagentStop working subagent-stop; : > "$HOME/pythonless-done"; exec sleep 20"#
            let pythonlessCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/claude -c \(shellQuote(pythonlessBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(pythonlessCommand)
                    + "; " + awaitBodyMarker("pythonless-done")
            )
            let pythonlessOutput = try await session.executeConnectedCommand(
                prefix
                    + "tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
            )
            let pythonlessJSON = pythonlessOutput
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? ""
            let pythonlessEvent = try XCTUnwrap(
                AgentLifecycleEvent.decode(json: pythonlessJSON)
            )
            XCTAssertEqual(pythonlessEvent.event, "Stop")
            XCTAssertEqual(pythonlessEvent.state, .idle)

            let cleanupBody = #"hook="$HOME/.config/tessera/agent-lifecycle-hook.sh"; printf '%s' '{"session_id":"cleanup-session","agent_id":"child-2"}' | env PATH="$HOME/minimal-bin" "$hook" claude SubagentStart working subagent-start; printf '%s' '{"session_id":"cleanup-session"}' | env PATH="$HOME/minimal-bin" "$hook" claude SessionStart idle session-start; if find "$HOME/.config/tessera/active-subagents/$$" -type f -print -quit 2>/dev/null | grep -q .; then printf '%s' '{"session_id":"cleanup-session"}' | "$hook" claude StopFailure unavailable cleanup-failed; else printf '%s' '{"session_id":"cleanup-session"}' | "$hook" claude UserPromptSubmit working cleanup-passed; fi; : > "$HOME/cleanup-done"; exec sleep 20"#
            let cleanupCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/claude -c \(shellQuote(cleanupBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(cleanupCommand)
                    + "; " + awaitBodyMarker("cleanup-done")
            )
            let cleanupOutput = try await session.executeConnectedCommand(
                prefix
                    + "tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
            )
            let cleanupJSON = cleanupOutput
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init) ?? ""
            let cleanupEvent = try XCTUnwrap(AgentLifecycleEvent.decode(json: cleanupJSON))
            XCTAssertEqual(cleanupEvent.event, "UserPromptSubmit")
            XCTAssertEqual(cleanupEvent.reason, "cleanup-passed")

            // An agent's background agents (Codex started by Claude) inherit
            // its pane. Real job control and /proc decide here: the detached
            // child's hook must leave the foreground agent's retained state
            // and terminal alone, and that agent's own next hook still lands.
            print("TESSERA_AGENT_LIVE_STAGE background-agent-defers")
            let backgroundBody = #"hook="$HOME/.config/tessera/agent-lifecycle-hook.sh"; printf '%s' '{"session_id":"foreground-session"}' | "$hook" claude UserPromptSubmit working agent-turn; printf '%s\n' '{"type":"session_meta","payload":{"id":"background-session","source":"cli"}}' > "$HOME/background-session.jsonl"; setsid -w "$HOME/codex" -c 'printf "{\"session_id\":\"background-session\",\"transcript_path\":\"%s/background-session.jsonl\"}" "$HOME" | "$HOME/.config/tessera/agent-lifecycle-hook.sh" codex UserPromptSubmit working agent-turn' </dev/null >/dev/null 2>&1; tmux show-options -pqv -t "$TMUX_PANE" @tessera_agent_state > "$HOME/after-background.state"; printf '%s' '{"session_id":"foreground-session"}' | "$hook" claude Stop idle turn-stopped; : > "$HOME/background-done"; exec sleep 20"#
            let backgroundCommand = "env HOME=\(quotedHome) SHELL=/bin/zsh "
                + "\(quotedHome)/claude -c \(shellQuote(backgroundBody))"
            _ = try await session.executeConnectedCommand(
                prefix
                    + ": > \"$HOME/.config/tessera/agent-lifecycle-diagnostics.log\"; "
                    + "tmux respawn-pane -k -t \(tmuxSession):0.0 "
                    + shellQuote(backgroundCommand)
                    + "; " + awaitBodyMarker("background-done")
            )
            let backgroundOutput = try await session.executeConnectedCommand(
                prefix
                    + "printf 'AFTER='; cat \"$HOME/after-background.state\"; "
                    + "printf 'FINAL='; tmux display-message -p -t \(tmuxSession):0.0 "
                    + shellQuote("#{@tessera_agent_state}")
                    + "; printf '\\n'; grep ' phase=resolved ' \"$HOME/.config/tessera/agent-lifecycle-diagnostics.log\""
            )
            let backgroundLines = backgroundOutput.split(whereSeparator: \.isNewline).map(String.init)
            let afterBackground = try XCTUnwrap(
                backgroundLines.first(where: { $0.hasPrefix("AFTER=") })
                    .flatMap { AgentLifecycleEvent.decode(json: String($0.dropFirst("AFTER=".count))) },
                backgroundOutput
            )
            XCTAssertEqual(afterBackground.provider, "claude", backgroundOutput)
            XCTAssertEqual(afterBackground.event, "UserPromptSubmit", backgroundOutput)
            XCTAssertEqual(afterBackground.providerSessionID, "foreground-session", backgroundOutput)
            let finalBackground = try XCTUnwrap(
                backgroundLines.first(where: { $0.hasPrefix("FINAL=") })
                    .flatMap { AgentLifecycleEvent.decode(json: String($0.dropFirst("FINAL=".count))) },
                backgroundOutput
            )
            XCTAssertEqual(finalBackground.provider, "claude", backgroundOutput)
            XCTAssertEqual(finalBackground.event, "Stop", backgroundOutput)
            XCTAssertEqual(finalBackground.agentPID, afterBackground.agentPID, backgroundOutput)
            XCTAssertTrue(backgroundLines.contains {
                $0.contains("provider=codex event=UserPromptSubmit")
                    && $0.contains("tmuxState=deferred terminalEmission=deferred")
            }, backgroundOutput)
            XCTAssertEqual(backgroundLines.filter {
                $0.contains("provider=claude") && $0.contains("tmuxState=written")
            }.count, 2, backgroundOutput)

            _ = try? await session.executeConnectedCommand(
                "for tessera_pid in \(spawnedPIDs.map(String.init).joined(separator: " ")); do kill \"$tessera_pid\" >/dev/null 2>&1 || true; done; "
                    + "tmux kill-session -t \(tmuxSession) >/dev/null 2>&1 || true; "
                    + "rm -rf \(quotedHome)"
            )
        } catch {
            _ = try? await session.executeConnectedCommand(
                "for tessera_pid in \(spawnedPIDs.map(String.init).joined(separator: " ")); do kill \"$tessera_pid\" >/dev/null 2>&1 || true; done; "
                    + "tmux kill-session -t \(tmuxSession) >/dev/null 2>&1 || true; "
                    + "rm -rf \(quotedHome)"
            )
            throw error
        }
    }

    @MainActor
    func test_generateInstallAndAuthenticateWithEd25519Key() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)

        let key = try KeyStore.generateEd25519(
            name: "tessera-live-\(UUID().uuidString.prefix(8))",
            context: ()
        )
        defer { _ = try? KeyStore.deleteKey(forKeyID: key.id) }

        let ledgerSuite = "RealHostTransportIntegrationTests.\(UUID().uuidString)"
        let ledgerDefaults = try XCTUnwrap(UserDefaults(suiteName: ledgerSuite))
        defer { ledgerDefaults.removePersistentDomain(forName: ledgerSuite) }
        let ledger = KeySecurityMetadataStore(
            defaults: ledgerDefaults,
            storageKey: "live-self-revoke"
        )
        let passwordHost = makeHost(config: config, transport: .ssh)
        let ledgerContext = RemoteAuthorizedKeysInstaller.LedgerContext(
            metadata: ledger,
            keyID: key.id,
            hostID: passwordHost.id,
            hostLabel: passwordHost.name,
            endpoint: "\(passwordHost.user)@\(passwordHost.address):\(passwordHost.port)",
            routeIdentity: RemoteAccessRouteIdentity.value(for: passwordHost),
            publicKeyFingerprint: key.canonicalFingerprint,
            authorizedKeysLine: key.authorizedKeysLine
        )

        let installer = SSHSession(host: passwordHost)
        defer { installer.disconnect() }
        _ = try await connect(
            session: installer,
            pendingRequest: { installer.pendingHostKeyVerification },
            timeout: 20
        )
        installer.disconnect()

        // Exercise the production durable install path, including its remote
        // verifier, rather than mutating authorized_keys through the fixture
        // shell directly.
        try await RemoteAuthorizedKeysInstaller.install(
            line: key.authorizedKeysLine,
            keyID: key.id,
            on: passwordHost,
            ledgerContext: ledgerContext
        )
        XCTAssertEqual(
            ledger.record(for: key.id).remoteInstallations.first?.verificationState,
            .verified
        )

        var sshKeyHost = passwordHost
        sshKeyHost.password = ""
        sshKeyHost.storedKeyID = key.id
        var moshKeyHost = makeHost(config: config, transport: .mosh)
        moshKeyHost.password = ""
        moshKeyHost.storedKeyID = key.id

        SSHAuthenticationPolicyStore.shared.resetForTesting()
        let keyedHosts = [sshKeyHost.id: sshKeyHost, moshKeyHost.id: moshKeyHost]
        SSHAuthenticationPolicyStore.shared.configureCurrentPolicyProvider { id, _ in
            guard let host = keyedHosts[id] else { return nil }
            return SSHConnectionPolicyDraft(
                host: host,
                requireBiometric: false,
                isSecureEnclave: false,
                keyAlgorithm: .ed25519
            )
        }
        SSHAuthenticationPolicyStore.shared.registerPersistedHosts(keyedHosts.keys)

        let ssh = SSHSession(host: sshKeyHost)
        _ = try await connect(
            session: ssh,
            pendingRequest: { ssh.pendingHostKeyVerification },
            timeout: 20
        )
        ssh.send(Array("printf 'TESSERA_ED25519_SSH_OK\\n'\n".utf8))
        _ = try await waitForOutput(
            ssh.outputStream,
            containing: "TESSERA_ED25519_SSH_OK",
            timeout: 10
        )
        ssh.disconnect()

        let mosh = MoshSession(host: moshKeyHost)
        _ = try await connect(
            session: mosh,
            pendingRequest: { mosh.pendingHostKeyVerification },
            timeout: 35
        )
        mosh.send(Array("printf 'TESSERA_ED25519_MOSH_OK\\n'\n".utf8))
        _ = try await waitForOutput(
            mosh.outputStream,
            containing: "TESSERA_ED25519_MOSH_OK",
            timeout: 15
        )
        mosh.disconnect()

        // The target key authenticates this connection, then removes itself
        // over the already-established client and verifies absence before the
        // connection closes.
        try await RemoteAuthorizedKeysInstaller.revokeUsingTargetKey(
            line: key.authorizedKeysLine,
            keyID: key.id,
            on: sshKeyHost,
            ledgerContext: ledgerContext
        )
        XCTAssertTrue(ledger.record(for: key.id).remoteInstallations.isEmpty)
        XCTAssertNotNil(ledger.record(for: key.id).lastRemoteRevocationAt)

        let revoked = SSHSession(host: sshKeyHost)
        defer { revoked.disconnect() }
        revoked.connect()
        let failure = try await waitForFailure(
            state: { revoked.state },
            pendingRequest: { revoked.pendingHostKeyVerification },
            timeout: 20
        )
        XCTAssertTrue(
            failure.localizedCaseInsensitiveContains("auth")
                || failure.localizedCaseInsensitiveContains("permission")
                || failure.localizedCaseInsensitiveContains("credential"),
            "revoked key unexpectedly produced a non-auth failure: \(failure)"
        )
    }

    @MainActor
    func test_liveSSHLocalForwardCarriesHTTPAndCountsBytes() async throws {
        let config = try Config.load()
        await resetConnectionState(endpoint: "\(config.stableHost):\(config.port)")
        let rule = PortForwardRule.localForward(
            localPort: UInt16(config.localForwardPort),
            remoteHost: "127.0.0.1",
            remotePort: UInt16(config.echoPort),
            label: "fixture-http"
        )
        var host = makeHost(config: config, transport: .ssh)
        host.launchMode = .autoTmux
        host.autoTmux = true
        host.portForwardRules = [rule]
        let session = SSHSession(host: host)
        defer { session.disconnect() }

        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )
        try await waitUntil("forwarder listening", timeout: 8) {
            session.portForwarderManager.runningCount == 1
        }

        let url = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(config.localForwardPort)/probe")
        )
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "TESSERA_FORWARD_OK\n")

        try await waitUntil("forwarder byte accounting", timeout: 5) {
            guard let forwarder = session.portForwarderManager.forwarders[rule.id] else {
                return false
            }
            return forwarder.bytesUp > 0 && forwarder.bytesDown >= data.count
        }
    }

    /// The top-bar glyph's question, asked of a real sshd: a forward whose
    /// target accepts is serving, one whose target refuses is not — decided
    /// by the server's answer to a real connection, and by its answer to a
    /// probe the same way.
    @MainActor
    func test_liveSSHForwardedServiceTellsServingFromRefused() async throws {
        let config = try Config.load()
        await resetConnectionState(endpoint: "\(config.stableHost):\(config.port)")
        // Local ports clear of the side-channel test's +1/+2. The closed
        // target is tcpmux: assigned, never run, and not a port the web
        // policy refuses, so it is watched like any dev-server port.
        func rule(_ offset: Int, target: Int, _ label: String) -> PortForwardRule {
            PortForwardRule.localForward(
                localPort: UInt16(config.localForwardPort + offset),
                remoteHost: "127.0.0.1",
                remotePort: UInt16(target),
                label: label
            )
        }
        let connectedServing = rule(3, target: config.echoPort, "connected-http")
        let connectedRefused = rule(4, target: 1, "connected-closed")
        let probedServing = rule(5, target: config.echoPort, "probed-http")
        let probedRefused = rule(6, target: 1, "probed-closed")

        var host = makeHost(config: config, transport: .ssh)
        host.portForwardRules = [connectedServing, connectedRefused]
        let session = SSHSession(host: host)
        defer { session.disconnect() }

        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )
        let manager = session.portForwarderManager
        try await waitUntil("forwarders listening", timeout: 8) {
            manager.runningCount == 2
        }

        // Real connections, with no probe running: each one's direct-tcpip
        // open is the answer.
        let open = try XCTUnwrap(URL(string: "http://127.0.0.1:\(config.localForwardPort + 3)/probe"))
        let (data, _) = try await URLSession.shared.data(from: open)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "TESSERA_FORWARD_OK\n")
        let closed = try XCTUnwrap(URL(string: "http://127.0.0.1:\(config.localForwardPort + 4)/"))
        _ = try? await URLSession.shared.data(from: closed)
        try await waitUntil("connections reported", timeout: 8) {
            manager.forwarders[connectedServing.id]?.service == .serving
                && manager.forwarders[connectedRefused.id]?.service == .notServing
        }

        // Probes, for rules nothing has connected through.
        await manager.reconcile(newRules: [connectedServing, connectedRefused, probedServing, probedRefused])
        try await waitUntil("probed forwarders listening", timeout: 8) {
            manager.runningCount == 4
        }
        XCTAssertEqual(manager.forwarders[probedServing.id]?.service, .unknown)
        XCTAssertEqual(manager.forwarders[probedRefused.id]?.service, .unknown)

        let monitor = Task { await manager.monitorServices() }
        defer { monitor.cancel() }
        try await waitUntil("probes answered", timeout: 12) {
            manager.forwarders[probedServing.id]?.service == .serving
                && manager.forwarders[probedRefused.id]?.service == .notServing
        }
        XCTAssertEqual(manager.servingCount, 2)
        XCTAssertEqual(manager.forwarders[probedRefused.id]?.forwardingProhibited, false)
    }

    @MainActor
    func test_liveSSHAndMoshApplyEnvironmentAndStartupSnippet() async throws {
        let config = try Config.load()
        let marker = "TESSERA_PROLOGUE_\(UUID().uuidString.prefix(8))"
        // TERM is part of the contract: the SSH PTY asks for xterm-256color and
        // mosh-server exports the same from the bootstrap's `-c 256`; a mosh
        // shell that reads `xterm` is an 8-colour session.
        let expected = "\(marker)|space value|snippet-ok|/home/\(config.user)|xterm-256color"

        for (transport, useChaosHost) in [(HostTransport.ssh, false), (.mosh, true)] {
            var host = makeHost(
                config: config,
                transport: transport,
                useChaosHost: useChaosHost
            )
            host.envVars = "TESSERA_VALUE='space value'\nTESSERA_HOME=$HOME"
            host.startupSnippet = "export TESSERA_SNIPPET=snippet-ok"
            host.launchCommand =
                "printf '\(marker)|%s|%s|%s|%s\\n' \"$TESSERA_VALUE\" \"$TESSERA_SNIPPET\" \"$TESSERA_HOME\" \"$TERM\"; "
                + "exec /bin/bash --noprofile --norc"

            if transport == .ssh {
                let session = SSHSession(host: host)
                defer { session.disconnect() }
                _ = try await connect(
                    session: session,
                    pendingRequest: { session.pendingHostKeyVerification },
                    timeout: 20
                )
                var command = HostLaunchPrologue.multilineStdin(
                    envVars: host.envVars,
                    startupSnippet: host.startupSnippet
                ) ?? ""
                command += host.launchCommand ?? ""
                if !command.hasSuffix("\n") { command += "\n" }
                session.send(Array(command.utf8))
                let output = try await waitForOutput(
                    session.outputStream,
                    containing: expected,
                    timeout: 10
                )
                XCTAssertTrue(output.contains(expected))
            } else {
                let session = MoshSession(host: host)
                defer { session.disconnect() }
                _ = try await connect(
                    session: session,
                    pendingRequest: { session.pendingHostKeyVerification },
                    timeout: 35
                )
                let output = try await waitForOutput(
                    session.outputStream,
                    containing: expected,
                    timeout: 15
                )
                XCTAssertTrue(output.contains(expected))
            }
        }
    }

    @MainActor
    func test_liveFileBridgeListsAndRoundTripsFiles() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)

        let trustSession = SSHSession(host: makeHost(config: config, transport: .ssh))
        _ = try await connect(
            session: trustSession,
            pendingRequest: { trustSession.pendingHostKeyVerification },
            timeout: 20
        )
        trustSession.disconnect()

        let host = makeHost(config: config, transport: .mosh)
        let bridge = FileBridge(host: host, requireBiometric: false, isSecureEnclave: false)
        defer { Task { await bridge.disconnect() } }
        try await bridge.connect()

        XCTAssertEqual(bridge.state, .connected)
        XCTAssertEqual(bridge.homeDirectory, "/home/\(config.user)")
        let fixturePath = "/home/\(config.user)/fixture-files"
        let fixtureNames = Set(try await bridge.listDirectory(fixturePath).map(\.name))
        XCTAssertTrue(fixtureNames.isSuperset(of: ["visible.txt", ".hidden", "testfile"]))

        let runName = "bridge-\(UUID().uuidString.lowercased())"
        let remoteDirectory = "\(fixturePath)/\(runName)"
        let remoteOriginal = "\(remoteDirectory)/upload.bin"
        let remoteRenamed = "\(remoteDirectory)/renamed.bin"
        let remoteImage = "\(remoteDirectory)/image space.png"
        let remoteMarkdown = "\(remoteDirectory)/readme.md"
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(runName, isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        var payload = Data()
        for index in 0..<8_192 {
            payload.append(UInt8(truncatingIfNeeded: index &* 31))
        }
        let uploadURL = localRoot.appendingPathComponent("upload.bin")
        let downloadURL = localRoot.appendingPathComponent("download.bin")
        try payload.write(to: uploadURL)

        try await bridge.createDirectory(remoteDirectory)
        do {
            try await bridge.upload(localURL: uploadURL, to: remoteOriginal, progress: nil)
            try await bridge.rename(from: remoteOriginal, to: remoteRenamed)
            let names = Set(try await bridge.listDirectory(remoteDirectory).map(\.name))
            XCTAssertEqual(names, Set(["renamed.bin"]))
            try await bridge.download(remotePath: remoteRenamed, to: downloadURL, progress: nil)
            XCTAssertEqual(try Data(contentsOf: downloadURL), payload)
            let execOutput = try await bridge.exec(
                "wc -c < \(remoteRenamed)",
                inShell: false
            )
            XCTAssertEqual(execOutput.trimmingCharacters(in: .whitespacesAndNewlines), "8192")
            let imageURL = localRoot.appendingPathComponent("image.png")
            try MarkdownImagePreviewFixture.image(color: .systemBlue, label: "REMOTE IMAGE").write(to: imageURL)
            try await bridge.upload(localURL: imageURL, to: remoteImage, progress: nil)
            let sourceURL = localRoot.appendingPathComponent("source.md")
            let markdownURL = localRoot.appendingPathComponent("readme.md")
            let source = "![relative](image%20space.png) ![absolute](\(remoteDirectory)/image%20space.png) ![parent](../\(runName)/image%20space.png) ![missing](missing.png)"
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)
            try await bridge.upload(localURL: sourceURL, to: remoteMarkdown, progress: nil)
            try await bridge.download(remotePath: remoteMarkdown, to: markdownURL, progress: nil)
            try await MarkdownImageStaging.stage(document: markdownURL, remotePath: remoteMarkdown, bridge: bridge)
            let images = MarkdownImageStaging.images(for: markdownURL)
            XCTAssertEqual(images.count, 3)
            for url in images.values { XCTAssertNotNil(UIImage(contentsOfFile: url.path)) }
            XCTAssertEqual(try String(contentsOf: markdownURL, encoding: .utf8), source)
            try await bridge.removeFile(remoteImage)
            try await bridge.removeFile(remoteMarkdown)
            try await bridge.removeFile(remoteRenamed)
            try await bridge.removeDirectory(remoteDirectory)
        } catch {
            try? await bridge.removeFile(remoteImage)
            try? await bridge.removeFile(remoteMarkdown)
            try? await bridge.removeFile(remoteOriginal)
            try? await bridge.removeFile(remoteRenamed)
            try? await bridge.removeDirectory(remoteDirectory)
            throw error
        }
    }

    /// Uploads and downloads a multi-megabyte file whose length is not a
    /// multiple of any request size, through the production bridge. Byte
    /// equality proves pipelined requests land at the right offsets; the
    /// activity records throughput beside the stop-and-wait ceiling
    /// (one 32 KB write per round trip) for the same link.
    @MainActor
    func test_liveFileBridgePipelinesLargeTransfers() async throws {
        let config = try Config.load()
        let bridge = try await connectedFileBridge(config: config)
        defer { Task { await bridge.disconnect() } }

        var roundTrips: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            _ = try await bridge.realPath(".")
            roundTrips.append(Self.seconds(ContinuousClock.now - start))
        }
        let roundTrip = roundTrips.sorted()[roundTrips.count / 2]

        let runName = "bridge-pipeline-\(UUID().uuidString.lowercased())"
        let remoteDirectory = "/home/\(config.user)/fixture-files/\(runName)"
        let remotePath = "\(remoteDirectory)/payload.bin"
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(runName, isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        let byteCount = 24 * 1024 * 1024 + 12_345
        let payload = Self.pseudoRandomPayload(byteCount: byteCount)
        let uploadURL = localRoot.appendingPathComponent("upload.bin")
        let downloadURL = localRoot.appendingPathComponent("download.bin")
        try payload.write(to: uploadURL)

        let uploadProgress = ProgressLog()
        let downloadProgress = ProgressLog()
        try await bridge.createDirectory(remoteDirectory)
        do {
            let uploadStart = ContinuousClock.now
            try await bridge.upload(localURL: uploadURL, to: remotePath) { transferred, total in
                uploadProgress.record(transferred, total)
            }
            let uploadSeconds = Self.seconds(ContinuousClock.now - uploadStart)

            let listed = try await bridge.listDirectory(remoteDirectory)
            XCTAssertEqual(listed.first { $0.path == remotePath }?.size, UInt64(byteCount))

            let downloadStart = ContinuousClock.now
            try await bridge.download(remotePath: remotePath, to: downloadURL) { transferred, total in
                downloadProgress.record(transferred, total)
            }
            let downloadSeconds = Self.seconds(ContinuousClock.now - downloadStart)
            XCTAssertTrue(try Data(contentsOf: downloadURL) == payload, "downloaded bytes differ")

            for (name, log) in [("upload", uploadProgress), ("download", downloadProgress)] {
                XCTAssertEqual(log.values.first, 0, "\(name) progress must start at zero")
                XCTAssertEqual(log.values.last, Int64(byteCount), "\(name) progress must end at the file size")
                XCTAssertEqual(log.values, log.values.sorted(), "\(name) progress must not go backwards")
                XCTAssertEqual(Set(log.totals), [Int64(byteCount)], "\(name) progress total")
            }

            let megabytes = Double(byteCount) / 1_000_000
            let marker = String(
                format: "TESSERA_FILES_PIPELINE bytes=%d rtt_ms=%.1f upload_MBps=%.2f download_MBps=%.2f stop_and_wait_upload_ceiling_MBps=%.2f",
                byteCount,
                roundTrip * 1000,
                megabytes / uploadSeconds,
                megabytes / downloadSeconds,
                0.032 / roundTrip
            )
            NSLog("[LiveTransport] %@", marker)
            XCTContext.runActivity(named: marker) { _ in }
        } catch {
            _ = try? await bridge.exec("rm -rf -- \(shellQuote(remoteDirectory))", inShell: false)
            throw error
        }
        _ = try await bridge.exec("rm -rf -- \(shellQuote(remoteDirectory))", inShell: false)
    }

    /// Browsing shares the SFTP channel with a running transfer, so a listing
    /// waits behind whatever the transfer has queued. Through a 10 Mbit/s
    /// relay a fixed 2 MB queue holds each of the listing's requests for
    /// 1.6 s, until the transfer ends; the adaptive window keeps the whole
    /// listing near a second. On a fast link it passes trivially.
    @MainActor
    func test_liveFileBridgeListsPromptlyDuringTransfers() async throws {
        let config = try Config.load()
        let bridge = try await connectedFileBridge(config: config)
        defer { Task { await bridge.disconnect() } }

        let runName = "bridge-responsive-\(UUID().uuidString.lowercased())"
        let remoteDirectory = "/home/\(config.user)/fixture-files/\(runName)"
        let remotePath = "\(remoteDirectory)/payload.bin"
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(runName, isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        let byteCount = 16 * 1024 * 1024
        let payload = Self.pseudoRandomPayload(byteCount: byteCount)
        let uploadURL = localRoot.appendingPathComponent("upload.bin")
        let downloadURL = localRoot.appendingPathComponent("download.bin")
        try payload.write(to: uploadURL)

        try await bridge.createDirectory(remoteDirectory)
        do {
            var idleListings: [Double] = []
            for _ in 0..<3 {
                let start = ContinuousClock.now
                _ = try await bridge.listDirectory(remoteDirectory)
                idleListings.append(Self.seconds(ContinuousClock.now - start))
            }
            let idleListing = idleListings.sorted()[1]

            let uploadProgress = ProgressLog()
            let uploadStart = ContinuousClock.now
            let upload = Task { @MainActor in
                try await bridge.upload(localURL: uploadURL, to: remotePath) { transferred, total in
                    uploadProgress.record(transferred, total)
                }
            }
            let duringUpload = try await Self.timeListing(
                of: remoteDirectory, on: bridge, during: uploadProgress, of: byteCount
            )
            try await upload.value
            let uploadSeconds = Self.seconds(ContinuousClock.now - uploadStart)

            let downloadProgress = ProgressLog()
            let downloadStart = ContinuousClock.now
            let download = Task { @MainActor in
                try await bridge.download(remotePath: remotePath, to: downloadURL) { transferred, total in
                    downloadProgress.record(transferred, total)
                }
            }
            let duringDownload = try await Self.timeListing(
                of: remoteDirectory, on: bridge, during: downloadProgress, of: byteCount
            )
            try await download.value
            let downloadSeconds = Self.seconds(ContinuousClock.now - downloadStart)
            XCTAssertTrue(try Data(contentsOf: downloadURL) == payload, "downloaded bytes differ")

            let megabytes = Double(byteCount) / 1_000_000
            let marker = String(
                format: "TESSERA_FILES_RESPONSIVE idle_list_ms=%.0f upload_list_ms=%.0f upload_overlapped=%d download_list_ms=%.0f download_overlapped=%d upload_MBps=%.2f download_MBps=%.2f",
                idleListing * 1000,
                duringUpload.seconds * 1000,
                duringUpload.overlapped ? 1 : 0,
                duringDownload.seconds * 1000,
                duringDownload.overlapped ? 1 : 0,
                megabytes / uploadSeconds,
                megabytes / downloadSeconds
            )
            NSLog("[LiveTransport] %@", marker)
            XCTContext.runActivity(named: marker) { _ in }
            for (name, listing) in [("upload", duringUpload), ("download", duringDownload)] {
                XCTAssertLessThan(listing.seconds, 4, "listing waited behind the \(name)'s queue")
            }
        } catch {
            _ = try? await bridge.exec("rm -rf -- \(shellQuote(remoteDirectory))", inShell: false)
            throw error
        }
        _ = try await bridge.exec("rm -rf -- \(shellQuote(remoteDirectory))", inShell: false)
    }

    /// Lists `directory` once the transfer has 2 MB behind it, so its window
    /// has adapted. `overlapped` says the transfer was still running when the
    /// listing returned.
    @MainActor
    private static func timeListing(
        of directory: String,
        on bridge: FileBridge,
        during progress: ProgressLog,
        of byteCount: Int
    ) async throws -> (seconds: Double, overlapped: Bool) {
        let deadline = ContinuousClock.now + .seconds(120)
        while (progress.values.last ?? 0) < 2_000_000, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let start = ContinuousClock.now
        _ = try await bridge.listDirectory(directory)
        let seconds = Self.seconds(ContinuousClock.now - start)
        return (seconds, (progress.values.last ?? 0) < Int64(byteCount))
    }

    /// A Files bridge on the stable fixture, its host key already trusted.
    @MainActor
    private func connectedFileBridge(config: Config) async throws -> FileBridge {
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)

        let trustSession = SSHSession(host: makeHost(config: config, transport: .ssh))
        _ = try await connect(
            session: trustSession,
            pendingRequest: { trustSession.pendingHostKeyVerification },
            timeout: 20
        )
        trustSession.disconnect()

        let bridge = FileBridge(
            host: makeHost(config: config, transport: .ssh),
            requireBiometric: false,
            isSecureEnclave: false
        )
        try await bridge.connect()
        return bridge
    }

    @MainActor
    private final class ProgressLog {
        private(set) var values: [Int64] = []
        private(set) var totals: [Int64?] = []

        func record(_ transferred: Int64, _ total: Int64?) {
            values.append(transferred)
            totals.append(total)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// xorshift64 bytes: incompressible and position-dependent, so a request
    /// written at the wrong offset cannot round-trip unnoticed.
    private static func pseudoRandomPayload(byteCount: Int) -> Data {
        var payload = Data(count: byteCount)
        payload.withUnsafeMutableBytes { raw in
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            var offset = 0
            while offset < byteCount {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                withUnsafeBytes(of: state.littleEndian) { word in
                    let count = min(word.count, byteCount - offset)
                    raw.baseAddress!.advanced(by: offset)
                        .copyMemory(from: word.baseAddress!, byteCount: count)
                }
                offset += 8
            }
        }
        return payload
    }

    @MainActor
    func test_liveTransferQueuePreservesModeAndSymlinkTarget() async throws {
        let config = try Config.load()
        let endpoint = "\(config.stableHost):\(config.port)"
        await resetConnectionState(endpoint: endpoint)

        let trustSession = SSHSession(host: makeHost(config: config, transport: .ssh))
        _ = try await connect(
            session: trustSession,
            pendingRequest: { trustSession.pendingHostKeyVerification },
            timeout: 20
        )
        trustSession.disconnect()

        let host = makeHost(config: config, transport: .mosh)
        let bridge = FileBridge(host: host, requireBiometric: false, isSecureEnclave: false)
        defer { Task { await bridge.disconnect() } }
        try await bridge.connect()

        let runName = "upload-semantics-\(UUID().uuidString.lowercased())"
        let remoteDirectory = "/home/\(config.user)/fixture-files/\(runName)"
        let privatePath = "\(remoteDirectory)/private.txt"
        let executablePath = "\(remoteDirectory)/deploy.sh"
        let targetPath = "\(remoteDirectory)/actual.txt"
        let symlinkPath = "\(remoteDirectory)/current.txt"
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(runName, isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        try await bridge.createDirectory(remoteDirectory)
        do {
            _ = try await bridge.exec(
                "printf old > \(shellQuote(privatePath)); chmod 600 \(shellQuote(privatePath)); "
                + "printf old > \(shellQuote(executablePath)); chmod 751 \(shellQuote(executablePath)); "
                + "printf old > \(shellQuote(targetPath)); chmod 600 \(shellQuote(targetPath)); "
                + "ln -s actual.txt \(shellQuote(symlinkPath))",
                inShell: false
            )

            let privateURL = localRoot.appendingPathComponent("private.txt")
            let executableURL = localRoot.appendingPathComponent("deploy.sh")
            let symlinkURL = localRoot.appendingPathComponent("current.txt")
            try Data("private-new".utf8).write(to: privateURL)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
            try Data("target-new".utf8).write(to: symlinkURL)

            let queue = TransferQueue(bridge: bridge)
            let privateItem = queue.enqueueUpload(localURL: privateURL, toDirectory: remoteDirectory)
            let executableItem = queue.enqueueUpload(localURL: executableURL, toDirectory: remoteDirectory)
            let symlinkItem = queue.enqueueUpload(localURL: symlinkURL, toDirectory: remoteDirectory)
            try await waitUntil("live staged uploads", timeout: 20) {
                privateItem.phase == .completed
                    && executableItem.phase == .completed
                    && symlinkItem.phase == .completed
            }

            let entries = try await bridge.listDirectory(remoteDirectory)
            XCTAssertEqual(entries.first { $0.path == privatePath }?.permissions, 0o600)
            XCTAssertEqual(entries.first { $0.path == executablePath }?.permissions, 0o751)
            XCTAssertEqual(entries.first { $0.path == symlinkPath }?.kind, .symlink)
            XCTAssertFalse(entries.contains {
                $0.name.contains(".tessera-upload-") || $0.name.contains(".tessera-replaced-")
            })

            let evidence = try await bridge.exec(
                "stat -c '%a' \(shellQuote(privatePath)); "
                + "stat -c '%a' \(shellQuote(executablePath)); "
                + "readlink \(shellQuote(symlinkPath)); "
                + "cat \(shellQuote(targetPath))",
                inShell: false
            ).split(separator: "\n").map(String.init)
            XCTAssertEqual(evidence, ["600", "751", "actual.txt", "target-new"])
        } catch {
            _ = try? await bridge.exec("rm -rf -- \(shellQuote(remoteDirectory))", inShell: false)
            throw error
        }
        _ = try await bridge.exec("rm -rf -- \(shellQuote(remoteDirectory))", inShell: false)
        let remainingEntries = try await bridge.listDirectory("/home/\(config.user)/fixture-files")
        XCTAssertFalse(remainingEntries.contains { $0.path == remoteDirectory })
    }

    @MainActor
    func test_liveInlineTmuxControllersHydrateBothFixtureVersions() async throws {
        let config = try Config.load()
        try await assertInlineTmuxHydration(config: config, useChaosHost: false)
        try await assertInlineTmuxHydration(config: config, useChaosHost: true)
    }

    @MainActor
    func test_liveSideChannelTmuxIsolationAndForwarding() async throws {
        let config = try Config.load()
        try await assertSideChannelTmuxIsolation(
            config: config,
            useChaosHost: false,
            localPortOffset: 1
        )
        try await assertSideChannelTmuxIsolation(
            config: config,
            useChaosHost: true,
            localPortOffset: 2
        )
    }

    /// OSC 7501 over every included transport: plain SSH answers the
    /// detection query only while enabled and reports the raw terminal;
    /// SSH+tmux's inline control channel and mosh+tmux's side channel carry
    /// pane reports on both fixture tmux versions. Reports are printed by
    /// the remote shell, so they cross the real wire, not a fixture parser.
    @MainActor
    func test_liveProgramStatusReportsCrossEveryIncludedTransport() async throws {
        let config = try Config.load()
        try await assertRawSSHProgramStatus(config: config)
        for useChaosHost in [false, true] {
            try await assertTmuxProgramStatus(config: config, useChaosHost: useChaosHost, sideChannel: false)
            try await assertTmuxProgramStatus(config: config, useChaosHost: useChaosHost, sideChannel: true)
        }
    }

    @MainActor
    func test_tmuxIsolationSnapshotErasesPriorGlyphsCoreGraphics() throws {
        let terminal = TmuxIsolationTerminal(label: "snapshot-erasure", columns: 48, rows: 24)
        let view = terminal.view
        let erase = "\u{1B}[?25l\u{1B}[0m\u{1B}[2J\u{1B}[H"

        func feed(_ text: String) {
            terminal.box.feed(Array(text.utf8)[...])
        }

        func capture(_ name: String, of target: TerminalView? = nil) -> UIImage {
            // Match the live fixture's repeated capture of one reused layer.
            let surface = target ?? view
            surface.layer.setNeedsDisplay()
            surface.layer.displayIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: surface.bounds, format: format).image {
                surface.layer.render(in: $0.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return image
        }

        func pixels(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
            let cgImage = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            try bytes.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(
                    data: storage.baseAddress,
                    width: cgImage.width,
                    height: cgImage.height,
                    bitsPerComponent: 8,
                    bytesPerRow: cgImage.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            }
            return (bytes, cgImage.width, cgImage.height)
        }

        func changedPixels(_ image: UIImage, from baseline: UIImage) throws -> Set<Int> {
            let current = try pixels(image)
            let blank = try pixels(baseline)
            XCTAssertEqual(current.width, blank.width)
            XCTAssertEqual(current.height, blank.height)
            return Set((0..<(current.width * current.height)).filter { pixel in
                let offset = pixel * 4
                return (0..<3).contains {
                    abs(Int(current.bytes[offset + $0]) - Int(blank.bytes[offset + $0])) > 8
                }
            })
        }

        feed(erase)
        let blank = capture("snapshot-erasure-blank")
        var measurements: [[String: Any]] = []
        for pass in 1...3 {
            feed(erase + (1...6).map {
                "\u{1B}[\($0);1H" + String(repeating: "A", count: 24)
            }.joined())
            let before = capture("snapshot-erasure-A-\(pass)")
            XCTAssertTrue(terminal.transcript.contains(String(repeating: "A", count: 24)))
            let paintedA = try changedPixels(before, from: blank)
            XCTAssertGreaterThan(paintedA.count, 50, "the prior glyphs must actually be painted")

            let currentB = erase + "\u{1B}[\(12 + pass);1H" + String(repeating: "B", count: 24)
            feed(currentB)
            let after = capture("snapshot-erasure-B-\(pass)")
            XCTAssertFalse(terminal.transcript.contains("A"), "old glyphs must be absent from the native model")
            XCTAssertTrue(terminal.transcript.contains(String(repeating: "B", count: 24)))
            XCTAssertEqual(terminal.transcript.filter { $0 == "B" }.count, 24)
            XCTAssertEqual(terminal.surfaceState.columns, 48)
            XCTAssertEqual(terminal.surfaceState.rows, 24)
            // A fresh layer sees only the current native text. Compare the
            // whole surface so alternating reused backing buffers cannot
            // hide retained pixels from an earlier B frame.
            let reference = TmuxIsolationTerminal(label: "snapshot-reference-\(pass)", columns: 48, rows: 24)
            reference.box.feed(Array(currentB.utf8)[...])
            XCTAssertEqual(reference.transcript, terminal.transcript)
            XCTAssertEqual(reference.surfaceState.columns, 48)
            XCTAssertEqual(reference.surfaceState.rows, 24)
            let expected = capture("snapshot-erasure-reference-B-\(pass)", of: reference.view)
            let referencePaint = try changedPixels(expected, from: blank).count
            XCTAssertGreaterThan(referencePaint, 50, "the fresh current-text reference must actually paint")
            let stalePixels = try changedPixels(after, from: expected).count
            XCTAssertEqual(stalePixels, 0, "reused-layer pixels must match a fresh layer with the exact current model")
            let changed = try changedPixels(after, from: blank)
            let residualA = changed.intersection(paintedA).count
            let paintedB = changed.subtracting(paintedA).count
            XCTAssertGreaterThan(paintedB, 50, "fresh glyphs must survive the redraw")
            XCTAssertEqual(residualA, 0, "erased glyph pixels must match the original blank surface")
            measurements.append([
                "pass": pass, "paintedAPixels": paintedA.count, "residualAPixels": residualA,
                "paintedBPixels": paintedB, "referencePaintedBPixels": referencePaint,
                "stalePixels": stalePixels, "currentNativeText": terminal.transcript,
                "referenceNativeText": reference.transcript, "isOpaque": view.isOpaque,
                "nativeBackgroundAlpha": view.nativeBackgroundColor.cgColor.alpha,
                "clearsContextBeforeDrawing": view.clearsContextBeforeDrawing
            ])
        }
        let metrics = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurements, options: .prettyPrinted), uniformTypeIdentifier: "public.json")
        metrics.name = "snapshot-erasure-pixel-metrics"
        metrics.lifetime = .keepAlways
        add(metrics)
    }

    @MainActor
    func test_liveSSHtmuxAppliesPhoneViewportThenIPadViewport() async throws {
        let config = try Config.load()
        try await assertInlineTmuxViewportHandoff(config: config)
    }

    @MainActor
    func test_liveSSHtmuxLateMeasuredViewportReclaimCompletes() async throws {
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        try await assertInlineTmuxLateMeasuredViewport(config: Config.load())
    }

    @MainActor
    func test_liveMoshTmuxAppliesPhoneViewportThenIPadViewport() async throws {
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        let config = try Config.load()
        try await assertMoshTmuxViewportHandoff(config: config)
    }

    /// D2: the plain peer types last but stays idle during the single
    /// take-back. Success requires the post-unset grid and an owner-bound
    /// consumed Mosh frame, not the temporary resize-window notification.
    @MainActor
    func test_liveMoshTmuxTakeBackWinsLatestFromPlainClient() async throws {
        let config = try Config.load()
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        let baseHost = makeHost(config: config, transport: .mosh)
        await resetConnectionState(endpoint: "\(baseHost.address):\(baseHost.port)")
        let setup = SSHSession(host: baseHost)
        defer { setup.disconnect() }
        _ = try await connect(session: setup, pendingRequest: { setup.pendingHostKeyVerification }, timeout: 20)
        let token = UUID().uuidString.prefix(8).lowercased()
        let sessionName = try runOwnedTmuxSessionName("latest", token: token)
        let viewName = AutoTmuxCommands.moshViewSessionName(for: sessionName)
        let fifo = "/tmp/\(sessionName).fifo"
        let peerLog = "/tmp/\(sessionName).script.log"
        let keeper = "\(sessionName)-fifo-keeper"
        let cleanup = "tmux kill-session -t '=\(viewName)' >/dev/null 2>&1 || true; "
            + "tmux kill-session -t '=\(sessionName)' >/dev/null 2>&1 || true; "
            + "pkill -u \"$(id -u)\" -xf '\(keeper) 3600' >/dev/null 2>&1 || true; "
            + "rm -f '\(fifo)' '\(peerLog)'"
        var host = baseHost
        host.autoTmux = true
        host.launchMode = .pinnedTmux
        host.tmuxSessionName = sessionName
        host.launchCommand = nil
        let client = MoshContinuationClient(host: host, sessionName: sessionName,
            identity: .init(id: "latest-ipad-\(token)", displayName: "iPad"), columns: 132, rows: 44)
        defer { client.stop() }
        do {
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -s '\(sessionName)' -x 132 -y 44 && "
                    + "tmux set-option -t '\(sessionName)' window-size latest")
            // The fixture injects its identity into the visible-client bootstrap.
            do {
                _ = try await connect(session: client.mosh,
                    pendingRequest: { client.mosh.pendingHostKeyVerification }, timeout: 35)
            }
            client.channel.connect()
            try await waitForTmuxHydration(client.controller, operation: "latest iPad hydration", channel: client.channel)
            try await showAndWaitForControl(client.controller, operation: "latest iPad initial show")
            try await waitUntil("initial show consumes the owned Mosh frame", timeout: 5) {
                client.completedAuthorityRepaints > 0
                    && client.lastCompletedAuthorityRepaintOwner == client.terminal.box.boundOwner
            }
            try await waitForTmuxGeometry(TmuxGeometry(cols: 132, rows: 44),
                sessionName: viewName, using: setup, operation: "initial iPad grid", timeout: 3)

            // A run-owned plain tty, never a control client. The keeper holds
            // the FIFO open; exact session/argv cleanup also works on failure.
            let plain = "stty cols 160 rows 48; exec tmux attach -t \(sessionName)"
            _ = try await setup.executeConnectedCommand(
                "mkfifo '\(fifo)' && "
                    + "(nohup bash -c 'exec -a \"$0\" sleep 3600 > \(fifo)' '\(keeper)' </dev/null >/dev/null 2>&1 &) && "
                    + "(nohup setsid env TERM=xterm-256color script -qfc \(shellQuote(plain)) /dev/null "
                    + "<'\(fifo)' >'\(peerLog)' 2>&1 &) && sleep 2 && "
                    + "tmux list-clients -t '=\(sessionName)' -F '#{client_width}x#{client_height}'")
            let peerSize = try await setup.executeConnectedCommand(
                "tmux list-clients -t '=\(sessionName)' -F '#{client_width}x#{client_height}'")
            XCTAssertTrue(peerSize.split(whereSeparator: { $0.isWhitespace }).contains("160x48"), peerSize)
            _ = try await setup.executeConnectedCommand("printf x > '\(fifo)'")
            try await waitForTmuxGeometry(TmuxGeometry(cols: 160, rows: 47),
                sessionName: viewName, using: setup, operation: "plain peer holds latest", timeout: 3)
            try await waitUntil("plain peer yields the iPad to another device", timeout: 5) {
                client.controller.gridAuthority == .peer(displayName: "another device")
                    && !client.controller.gridAuthorityReclaimInFlight
            }

            let repaintFloor = client.completedAuthorityRepaints
            XCTAssertTrue(client.controller.reclaimGridAuthority(reason: "plain-latest-fixture")) // exactly one tap
            try await waitUntil("one take-back settles with a consumed owned frame", timeout: 5) {
                client.controller.gridAuthority == .mine
                    && !client.controller.gridAuthorityReclaimInFlight
                    && client.completedAuthorityRepaints > repaintFloor
                    && client.lastCompletedAuthorityRepaintOwner == client.terminal.box.boundOwner
            }
            try await waitForTmuxGeometry(TmuxGeometry(cols: client.columns, rows: client.rows),
                sessionName: viewName, using: setup, operation: "post-unset take-back iPad grid", timeout: 3)
            // `show-options -t` resolves a pane target; name the session
            // exactly and its current window, as the geometry reads do.
            let stampOutput = try await setup.executeConnectedCommand(
                "tmux show-options -qv -t '=\(viewName):' \(TmuxController.gridAuthorityOption); "
                    + "tmux show-options -qv -t '=\(sessionName):' \(TmuxController.gridAuthorityOption) | sed 's/^/owner: /'")
            let viewStamp = stampOutput.split(separator: "\n").first { !$0.hasPrefix("owner: ") }.map(String.init) ?? ""
            let stamp = try XCTUnwrap(
                TmuxGridAuthorityStamp.parse(viewStamp.trimmingCharacters(in: .whitespacesAndNewlines)),
                "stamp read: \(stampOutput.debugDescription)"
            )
            XCTAssertEqual(stamp.deviceID, client.identity.id)
            XCTAssertEqual(client.controlPaneOutputEvents, 0)

            // A fresh peer keystroke must still take latest back natively:
            // the retained resize/unset must not leave a manual override.
            _ = try await setup.executeConnectedCommand("printf y > '\(fifo)'")
            try await waitForTmuxGeometry(TmuxGeometry(cols: 160, rows: 47),
                sessionName: viewName, using: setup, operation: "plain peer retakes latest", timeout: 3)
            try await waitUntil("the second peer key yields again", timeout: 5) {
                client.controller.gridAuthority == .peer(displayName: "another device")
                    && !client.controller.gridAuthorityReclaimInFlight
            }
            let evidence = XCTAttachment(string: "TESSERA_IOS_MOSH_PLAIN_LATEST_OK peer=160x48 peerWindow=160x47 takeBackAttempt=1 ipadWindow=132x44 consumedOwnedFrame=1 yieldedAgain=1")
            evidence.name = "mosh-plain-latest-success"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTContext.runActivity(named: "TESSERA_IOS_MOSH_PLAIN_LATEST_OK") { _ in }
            client.stop()
            _ = try await setup.executeConnectedCommand(cleanup)
        } catch {
            if let data = DiagnosticLogStore.attachmentData() {
                let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
                evidence.name = "mosh-plain-latest-failure-diagnostics"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
            client.stop()
            _ = try? await setup.executeConnectedCommand(cleanup)
            throw error
        }
    }

    /// D2 sizing and D1 owner-scoped peer names must work across the
    /// owner/view boundary in both directions.
    @MainActor
    func test_liveMixedSSHAndMoshTmuxTakeBacksWinLatestEachWay() async throws {
        let config = try Config.load()
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        let baseHost = makeHost(config: config, transport: .mosh)
        await resetConnectionState(endpoint: "\(baseHost.address):\(baseHost.port)")
        let setup = SSHSession(host: baseHost)
        defer { setup.disconnect() }
        _ = try await connect(session: setup, pendingRequest: { setup.pendingHostKeyVerification }, timeout: 20)
        let token = UUID().uuidString.prefix(8).lowercased()
        let sessionName = try runOwnedTmuxSessionName("mixed", token: token)
        let viewName = AutoTmuxCommands.moshViewSessionName(for: sessionName)
        let cleanup = "tmux kill-session -t '=\(viewName)' >/dev/null 2>&1 || true; "
            + "tmux kill-session -t '=\(sessionName)' >/dev/null 2>&1 || true"
        var moshHost = baseHost
        moshHost.autoTmux = true
        moshHost.launchMode = .pinnedTmux
        moshHost.tmuxSessionName = sessionName
        moshHost.launchCommand = nil
        let mosh = MoshContinuationClient(host: moshHost, sessionName: sessionName,
            identity: .init(id: "mixed-mosh-\(token)", displayName: "Mosh iPad"), columns: 132, rows: 44)
        defer { mosh.stop() }
        let inlineIdentity = TmuxController.GridAuthorityIdentity(id: "mixed-ssh-\(token)", displayName: "SSH iPad")
        let inlineGrid = TmuxGeometry(cols: 100, rows: 30)
        let inlineSession = SSHSession(host: makeHost(config: config, transport: .ssh))
        let inline = TmuxController(controlPath: .inline, clientSizePolicy: .resizeTmux)
        let inlineTerminal = TmuxIsolationTerminal(label: "mixed-inline", columns: inlineGrid.cols, rows: inlineGrid.rows)
        inline.gridAuthorityIdentity = inlineIdentity
        inlineSession.resize(cols: inlineGrid.cols, rows: inlineGrid.rows)
        inline.updateClientSize(cols: inlineGrid.cols, rows: inlineGrid.rows)
        installInlineTerminalSurface(inline, terminal: inlineTerminal)
        var inlineWire: [String] = []
        inline.sendBytes = { [weak inlineSession] bytes in
            inlineWire.append(String(decoding: bytes, as: UTF8.self))
            inlineSession?.send(bytes)
        }
        // Use the production inline cooperative ingestion path.
        let inlinePump = Task { @MainActor in
            for await bytes in inlineSession.outputStream { await inline.ingestCooperatively(bytes) }
        }
        defer { inlinePump.cancel(); inlineSession.disconnect() }
        var moshTakeBackAttempts = 0
        var inlineTakeBackAttempts = 0
        var attachedFailureDiagnostics = false

        func attachFailureDiagnostics() {
            guard !attachedFailureDiagnostics, let data = DiagnosticLogStore.attachmentData() else { return }
            let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
            evidence.name = "mixed-pair-failure-diagnostics"
            evidence.lifetime = .keepAlways
            add(evidence)
            attachedFailureDiagnostics = true
        }
        // XCTest assertions record issues without throwing. Keep diagnostics
        // for those failures too, including an authority peer-name assertion.
        defer {
            if (testRun?.failureCount ?? 0) > 0 { attachFailureDiagnostics() }
        }

        func readStamp(on target: String) async throws -> TmuxGridAuthorityStamp? {
            // A bare `=<session>` resolves a pane; the colon makes this an
            // exact session/current-window target for the session option.
            let output = try await setup.executeConnectedCommand(
                "tmux show-options -qv -t '=\(target):' \(TmuxController.gridAuthorityOption)")
            return TmuxGridAuthorityStamp.parse(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Names the step a thrown error interrupted: a cancelled sleep or
        // exec otherwise surfaces as a bare `caught error` with no line.
        var phase = "fixture"
        do {
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -s '\(sessionName)' -x 132 -y 44 && "
                    + "tmux set-option -t '=\(sessionName):' status off && "
                    + "tmux set-option -t '=\(sessionName):' window-size latest")
            phase = "Mosh connect and initial show"
            // The fixture injects the same identity into painter and control clients.
            do {
                _ = try await connect(session: mosh.mosh,
                    pendingRequest: { mosh.mosh.pendingHostKeyVerification }, timeout: 35)
            }
            mosh.channel.connect()
            try await waitForTmuxHydration(mosh.controller, operation: "mixed Mosh hydration", channel: mosh.channel)
            try await showAndWaitForControl(mosh.controller, operation: "mixed Mosh initial show")
            try await waitUntil("mixed initial show consumes an owned Mosh frame", timeout: 5) {
                mosh.completedAuthorityRepaints > 0
                    && mosh.lastCompletedAuthorityRepaintOwner == mosh.terminal.box.boundOwner
            }
            try await waitForTmuxGeometry(TmuxGeometry(cols: mosh.columns, rows: mosh.rows),
                sessionName: viewName, using: setup, operation: "mixed initial Mosh grid", timeout: 3)
            let initialViewStamp = try await readStamp(on: viewName)
            XCTAssertEqual(try XCTUnwrap(initialViewStamp).deviceID, mosh.identity.id)
            let initialOwnerStamp = try await readStamp(on: sessionName)
            XCTAssertEqual(initialOwnerStamp, initialViewStamp)

            phase = "inline attach"
            let ownerStampBeforeAttach = try await readStamp(on: sessionName)
            _ = try await connect(session: inlineSession,
                pendingRequest: { inlineSession.pendingHostKeyVerification }, timeout: 20)
            inlineSession.send(Array("exec tmux -CC attach -t '=\(sessionName)'\n".utf8))
            try await waitForTmuxHydration(inline, operation: "mixed inline hydration")
            try await waitForControlFence(inline, operation: "mixed inline attach read")
            XCTAssertNotEqual(inline.ownSessionId, mosh.controller.ownSessionId, "mixed clients must attach owner and view separately")
            XCTAssertEqual(inline.activeWindowId, mosh.controller.activeWindowId, "mixed clients must share the window")
            XCTAssertNotEqual(inline.gridAuthority, .mine, "§6.9: attach alone claimed without a show")
            XCTAssertFalse(inline.gridAuthorityReclaimInFlight, "§6.9: attach alone started a claim")
            XCTAssertFalse(inline.gridAuthorityHasPendingIntent, "attach invented a show intent")
            let ownerStampAfterAttach = try await readStamp(on: sessionName)
            XCTAssertEqual(ownerStampAfterAttach, ownerStampBeforeAttach, "attach wrote an authority stamp without a show")
            let attachCommands = inlineWire.flatMap {
                $0.split(whereSeparator: { $0 == "\n" || $0 == ";" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            XCTAssertFalse(attachCommands.contains {
                ($0.hasPrefix("set-option ") || $0.hasPrefix("set ")) && $0.contains(TmuxController.gridAuthorityOption)
            }, "attach wrote the authority option without a show")
            XCTAssertFalse(attachCommands.contains {
                $0.hasPrefix("select-window") || $0.hasPrefix("resize-window")
            }, "attach fenced or forced the window without a show")
            // A bare refresh-client on attach may affect latest's geometry;
            // only the explicit show below is permitted to claim authority.
            phase = "inline show"
            inline.gridAuthorityShown()
            try await waitForShownControl(inline, operation: "mixed inline initial show")
            try await waitForTmuxGeometry(inlineGrid, sessionName: sessionName,
                using: setup, operation: "mixed inline show grid", timeout: 3)
            let inlineShowStamp = try await readStamp(on: sessionName)
            XCTAssertEqual(try XCTUnwrap(inlineShowStamp).deviceID, inlineIdentity.id)
            try await waitUntil("mixed Mosh yields to inline without reclaiming", timeout: 5) {
                mosh.controller.gridAuthority.isPeer && !mosh.controller.gridAuthorityReclaimInFlight
            }
            // Geometry can veil before the 1 s stamp subscription delivers
            // the peer name. Allow that delivery before asserting the peer name.
            do {
                try await waitUntil("mixed Mosh sees the inline name", timeout: 3) {
                    mosh.controller.gridAuthority == .peer(displayName: inlineIdentity.displayName)
                }
            } catch IntegrationError.timedOut(_) { /* D1 is asserted below. */ }
            XCTAssertTrue(mosh.controller.gridAuthority.isPeer)
            XCTAssertFalse(mosh.controller.gridAuthorityReclaimInFlight)
            XCTAssertEqual(mosh.controller.gridAuthority, .peer(displayName: inlineIdentity.displayName))

            phase = "Mosh take-back"
            let repaintFloor = mosh.completedAuthorityRepaints
            moshTakeBackAttempts += 1
            XCTAssertTrue(mosh.controller.reclaimGridAuthority(reason: "mixed-mosh-take-back")) // exactly one tap
            try await waitUntil("mixed Mosh take-back settles with a consumed owned frame", timeout: 5) {
                mosh.controller.gridAuthority == .mine
                    && !mosh.controller.gridAuthorityReclaimInFlight
                    && mosh.completedAuthorityRepaints > repaintFloor
                    && mosh.lastCompletedAuthorityRepaintOwner == mosh.terminal.box.boundOwner
            }
            try await waitForTmuxGeometry(TmuxGeometry(cols: mosh.columns, rows: mosh.rows),
                sessionName: viewName, using: setup, operation: "mixed post-unset Mosh take-back grid", timeout: 3)
            let moshTakeBackStamp = try await readStamp(on: sessionName)
            XCTAssertEqual(try XCTUnwrap(moshTakeBackStamp).deviceID, mosh.identity.id)
            XCTAssertEqual(mosh.controlPaneOutputEvents, 0)
            try await waitUntil("mixed inline yields to Mosh without reclaiming", timeout: 5) {
                inline.gridAuthority.isPeer && !inline.gridAuthorityReclaimInFlight
            }
            do {
                try await waitUntil("mixed inline sees the Mosh name", timeout: 3) {
                    inline.gridAuthority == .peer(displayName: mosh.identity.displayName)
                }
            } catch IntegrationError.timedOut(_) { /* D1 is asserted below. */ }
            XCTAssertTrue(inline.gridAuthority.isPeer)
            XCTAssertFalse(inline.gridAuthorityReclaimInFlight)
            XCTAssertEqual(inline.gridAuthority, .peer(displayName: mosh.identity.displayName))

            phase = "inline take-back"
            inlineTakeBackAttempts += 1
            XCTAssertTrue(inline.reclaimGridAuthority(reason: "mixed-inline-take-back")) // exactly one tap
            try await waitUntil("mixed inline take-back settles", timeout: 5) {
                inline.gridAuthority == .mine && !inline.gridAuthorityReclaimInFlight
            }
            try await waitForTmuxGeometry(inlineGrid, sessionName: sessionName,
                using: setup, operation: "mixed inline take-back grid", timeout: 3)
            let inlineTakeBackStamp = try await readStamp(on: sessionName)
            XCTAssertEqual(try XCTUnwrap(inlineTakeBackStamp).deviceID, inlineIdentity.id)
            XCTAssertEqual(moshTakeBackAttempts, 1)
            XCTAssertEqual(inlineTakeBackAttempts, 1)
            let evidence = XCTAttachment(string: "TESSERA_IOS_MIXED_PAIR_OK moshGrid=\(mosh.columns)x\(mosh.rows) inlineGrid=\(inlineGrid.cols)x\(inlineGrid.rows) moshTakeBackAttempts=\(moshTakeBackAttempts) inlineTakeBackAttempts=\(inlineTakeBackAttempts) consumedOwnedMoshFrame=1")
            evidence.name = "mixed-pair-success"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTContext.runActivity(named: "TESSERA_IOS_MIXED_PAIR_OK") { _ in }
            phase = "cleanup"
            inlinePump.cancel()
            inlineSession.disconnect()
            mosh.stop()
            _ = try await setup.executeConnectedCommand(cleanup)
        } catch {
            XCTFail("mixed pair failed during \(phase): \(error)")
            attachFailureDiagnostics()
            inlinePump.cancel()
            inlineSession.disconnect()
            mosh.stop()
            _ = try? await setup.executeConnectedCommand(cleanup)
            throw error
        }
    }

    /// Two live Mosh painters and control clients must complete the same
    /// authority fence that dismisses the production continuation veil.
    @MainActor
    func test_liveMoshTmuxContinuationReclaimsAcrossTwoVisibleClients() async throws {
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        try await assertMoshTmuxContinuationClaims(config: Config.load())
    }

    /// Equal widths expose peer handoff races caused only by differing usable
    /// heights, as when a software keyboard changes one client's viewport.
    @MainActor
    func test_liveMoshTmuxContinuationReclaimsAcrossEqualWidthDifferentHeightClients() async throws {
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        try await assertMoshTmuxContinuationClaims(config: Config.load(), phoneColumns: 132)
    }

    @MainActor
    func test_liveMoshTmuxForegroundRepairsRemoteGridWithoutWindowSwitch() async throws {
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        try await assertMoshTmuxContinuationClaims(config: Config.load(), verifiesForegroundGridRepair: true)
    }

    @MainActor
    func test_liveMoshTmuxHeightOnlyDriftRepairsWithoutWindowSwitch() async throws {
        let previousVerbose = DiagnosticLogStore.isVerboseEnabled
        UserDefaults.standard.set(true, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey)
        defer { UserDefaults.standard.set(previousVerbose, forKey: DiagnosticLogStore.verboseDiagnosticsDefaultsKey) }
        try await assertMoshTmuxHeightOnlyDrift(config: Config.load())
    }

    /// End-to-end owner-isolation acceptance for the four production transport
    /// shapes.  The tmux fixtures deliberately retain 300 marker rows in each
    /// owner. SSH and both tmux paths prove those rows are available below the
    /// viewport; plain mosh proves its independently painted visible marker.
    /// Every asserted transcript is emitted into the XCTest log for the
    /// integration artifact.
    @MainActor
    func test_liveTmuxRenderSurfaceIsolationAcrossFourTransportsAndReconnects() async throws {
        guard ProcessInfo.processInfo.environment[
            "TESSERA_REAL_HOST_TMUX_ISOLATION_GATE"
        ] == "1" else {
            throw XCTSkip(
                "tmux render isolation is enabled by run-app-transport-tests.sh"
            )
        }

        let config = try Config.load()
        guard let token = ProcessInfo.processInfo.environment[
            "TESSERA_REAL_HOST_TMUX_ISOLATION_TOKEN"
        ], !token.isEmpty, token.count <= 40,
           token.utf8.allSatisfy({ byte in
               (byte >= 48 && byte <= 57)
                   || (byte >= 65 && byte <= 90)
                   || (byte >= 97 && byte <= 122)
                   || byte == 45 || byte == 46 || byte == 95
           })
        else {
            throw IntegrationError.failed(
                "run-app-transport-tests.sh must provide a cleanup-safe tmux isolation token"
            )
        }
        let inlineSession = try tmuxIsolationFixtureSession(
            environment: "TESSERA_REAL_HOST_TMUX_INLINE_SESSION"
        )
        let moshSession = try tmuxIsolationFixtureSession(
            environment: "TESSERA_REAL_HOST_TMUX_MOSH_SESSION"
        )

        try await assertPlainIsolation(
            session: SSHSession(host: makeHost(config: config, transport: .ssh)),
            transportLabel: "ssh",
            expectedOwner: "W1",
            token: token,
            connectTimeout: 20,
            outputTimeout: 12
        )
        try await assertInlineTmuxIsolation(
            config: config,
            token: token,
            sessionName: inlineSession
        )

        try await assertPlainIsolation(
            session: MoshSession(host: makeHost(
                config: config,
                transport: .mosh,
                useChaosHost: true
            )),
            transportLabel: "mosh",
            expectedOwner: "W1",
            token: token,
            connectTimeout: 35,
            outputTimeout: 18
        )
        try await assertMoshTmuxIsolation(
            config: config,
            token: token,
            sessionName: moshSession
        )

        let successMarker = "TESSERA_IOS_TMUX_ISOLATION_OK ssh=1 sshTmux=1 mosh=1 "
            + "moshTmux=1 reconnect=1 sideChannelDrop=1 dropped_foreign=0"
        // The runner reads this activity from the xcresult instead of relying
        // on console buffering. A skipped XCTest case therefore cannot look
        // like a green owner-isolation gate merely because xcodebuild itself
        // exited successfully.
        XCTContext.runActivity(named: successMarker) { _ in }
        print(successMarker)
    }

    /// Inline (SSH+tmux) history ladder against a real pane whose tmux history
    /// is three times the ledger's first inline fill.
    ///
    /// The fixture pane is filled with 6 000 numbered marker rows under a
    /// raised session `history-limit`, so `min(2000, scrollbackLimit)` provably
    /// cannot reach the oldest row. The deepen is triggered by the exact fact
    /// `SessionView` submits from a scroll gesture, and the only completion
    /// signal awaited is the ledger's own `inlineHistorySettled`.
    ///
    /// A row count alone would not prove the rebind is clean: the deepened
    /// capture replaces the transcript behind a continuity break, so a
    /// mid-history marker is also asserted to occur exactly once. Live output
    /// after the settle proves the deepen left the pane attached.
    @MainActor
    func test_liveInlineTmuxHistoryDeepensToScrollbackLimit() async throws {
        let config = try Config.load()
        let host = makeHost(config: config, transport: .ssh)
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )

        // Unique per run, and cleanup-safe for the kill-session below: this
        // case creates its own fixture rather than sharing the run-scoped
        // isolation sessions, which carry their own 300-row topology.
        let fixtureSession = "tessera-ios-inlinehist-"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                .prefix(12).lowercased()
        let pane = "'=\(fixtureSession):0.0'"

        let terminal = TmuxIsolationTerminal(label: "inline-history", columns: 100, rows: 30)
        let controller = TmuxController(controlPath: .inline)
        controller.updateClientSize(cols: 100, rows: 30)
        // The SwiftTerm scrollback has to outlast the deepened capture; the
        // 2 000-row default used by the isolation surfaces would silently
        // truncate the very rows this case is about.
        installInlineTerminalSurface(controller, terminal: terminal, scrollbackLimit: 12_000)
        controller.submitRenderFact(.scrollbackLimit(lines: 10_000))

        var settles: [(depth: Int, historySize: Int, canDeepen: Bool)] = []
        controller.renderInlineHistorySettled = { surfaceID, _, depth, historySize, canDeepen in
            guard surfaceID == .live else { return }
            settles.append((depth: depth, historySize: historySize, canDeepen: canDeepen))
        }

        var inline: SSHSession?
        var pump: Task<Void, Never>?
        func detachInline() {
            pump?.cancel()
            pump = nil
            inline?.disconnect()
            inline = nil
        }
        defer { detachInline() }

        do {
            // Scoped to this session: `show-options -g` fails on a fixture
            // with no tmux server yet, and a global limit would leak into
            // every concurrent checkout's sessions. history-limit sizes only
            // panes created after it, hence the replacement first window.
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -s '\(fixtureSession)' -x 100 -y 30 -c /tmp \\; "
                    + "set-option -t '\(fixtureSession)' history-limit 20000 \\; "
                    + "set-option -t '\(fixtureSession)' default-size 100x30 \\; "
                    + "new-window -k -t '\(fixtureSession):0' -c /tmp"
            )
            // 150 pad rows keep the history comfortably above the 6 000
            // numbered markers, so the post-deepen row assertion is not
            // measuring the shell prompt. `send-keys -l` forbids key-name
            // interpretation of the loop text.
            let fill = "for i in $(seq 1 150); do printf \"TESSERA-HIST-PAD-%03d\\n\" $i; done; "
                + "for i in $(seq 1 6000); do printf \"TESSERA-HIST-%06d\\n\" $i; done; "
                + "printf \"TESSERA-HIST-DONE\\n\""
            _ = try await setup.executeConnectedCommand(
                "tmux send-keys -l -t \(pane) '\(fill)' && tmux send-keys -t \(pane) Enter"
            )
            var fixtureHistorySize = -1
            for _ in 1...90 {
                fixtureHistorySize = Int(
                    try await setup.executeConnectedCommand(
                        "tmux display -p -t \(pane) '#{history_size}'"
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                ) ?? -1
                if fixtureHistorySize >= 5_900 { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard fixtureHistorySize >= 5_900 else {
                throw IntegrationError.failed(
                    "fixture pane never reached 5900 history rows;"
                        + " last history_size=\(fixtureHistorySize)"
                )
            }
            print(
                "TESSERA_IOS_INLINE_HISTORY_FIXTURE session=\(fixtureSession)"
                    + " history_size=\(fixtureHistorySize)"
            )

            let connection = SSHSession(host: host)
            controller.sendBytes = { [weak connection] bytes in connection?.send(bytes) }
            // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
            let connectionPump = Task { @MainActor in
                for await bytes in connection.outputStream {
                    await controller.ingestCooperatively(bytes)
                }
            }
            _ = try await connect(
                session: connection,
                pendingRequest: { connection.pendingHostKeyVerification },
                timeout: 20
            )
            connection.send(Array("exec tmux -CC attach -t \(fixtureSession)\n".utf8))
            inline = connection
            pump = connectionPump

            try await waitUntil("inline tmux hydration", timeout: 20) {
                controller.mode == .tmuxControl
                    && controller.isWindowListHydrated
                    && controller.windows.count == 1
            }

            // The attach `.deep` stage, capped at the ledger's inline depth
            // rather than at the scrollback preference.
            try await waitUntil("inline attach capture", timeout: 30) {
                terminal.transcript.contains("TESSERA-HIST-DONE")
                    && self.historyRowCount(of: terminal) >= 1_990
            }
            try await waitUntil("inline attach settle", timeout: 20) { !settles.isEmpty }
            let attachSettle = try XCTUnwrap(settles.last)
            let attachTranscript = terminal.transcript
            let rowsBeforeDeepen = historyRowCount(of: terminal)
            print(
                "TESSERA_IOS_INLINE_HISTORY_ATTACH rows=\(rowsBeforeDeepen)"
                    + " depth=\(attachSettle.depth) history=\(attachSettle.historySize)"
                    + " canDeepen=\(attachSettle.canDeepen)"
            )
            XCTAssertTrue(
                attachTranscript.contains("TESSERA-HIST-DONE"),
                "attach capture must hold the pane tail"
            )
            XCTAssertTrue(
                attachTranscript.contains("TESSERA-HIST-004500"),
                "attach capture must hold the middle of the first fill"
            )
            XCTAssertFalse(
                attachTranscript.contains("TESSERA-HIST-000001"),
                "attach capture must stop short of the oldest row: rows=\(rowsBeforeDeepen)"
            )
            XCTAssertTrue(
                (1_990...2_100).contains(rowsBeforeDeepen),
                "attach capture must be the ~2000-row first fill, got rows=\(rowsBeforeDeepen)"
            )
            XCTAssertTrue(
                attachSettle.canDeepen,
                "a pane with \(fixtureHistorySize) history rows must leave the ladder open:"
                    + " \(attachSettle)"
            )

            // Arm the completion signal only now, so the attach settle above
            // cannot satisfy the expectation this deepen has to earn.
            let exhausted = XCTestExpectation(
                description: "inline history settled with an exhausted ladder"
            )
            var deepenSettle: (depth: Int, historySize: Int, canDeepen: Bool)?
            controller.renderInlineHistorySettled = {
                surfaceID, _, depth, historySize, canDeepen in
                guard surfaceID == .live, !canDeepen, deepenSettle == nil else { return }
                deepenSettle = (depth: depth, historySize: historySize, canDeepen: canDeepen)
                exhausted.fulfill()
            }
            // Exactly the fact `SessionView.requestInlineScrollbackHistory`
            // submits when a scroll frame nears the oldest row.
            controller.submitRenderFact(.scrollbackRequested(
                .live,
                pointsY: 180,
                isInertial: false
            ))
            await fulfillment(of: [exhausted], timeout: 60)
            let settled = try XCTUnwrap(deepenSettle)

            try await waitUntil("deepened inline transcript", timeout: 30) {
                terminal.transcript.contains("TESSERA-HIST-000001")
                    && self.historyRowCount(of: terminal) >= 6_000
            }
            let deepTranscript = terminal.transcript
            let rowsAfterDeepen = historyRowCount(of: terminal)
            print(
                "TESSERA_IOS_INLINE_HISTORY_DEEPENED rows=\(rowsAfterDeepen)"
                    + " depth=\(settled.depth) history=\(settled.historySize)"
                    + " canDeepen=\(settled.canDeepen)"
            )
            XCTAssertTrue(
                deepTranscript.contains("TESSERA-HIST-000001"),
                "deepened capture must reach the oldest marker row"
            )
            XCTAssertEqual(
                deepTranscript.components(separatedBy: "TESSERA-HIST-004500").count - 1,
                1,
                "the deepened capture replaces the transcript; a mid-history marker"
                    + " may not be duplicated across the rebind"
            )
            XCTAssertGreaterThanOrEqual(
                rowsAfterDeepen,
                6_000,
                "deepened transcript must hold the whole pane history (was"
                    + " \(rowsBeforeDeepen), fixture history_size=\(fixtureHistorySize))"
            )
            XCTAssertFalse(
                settled.canDeepen,
                "a capture at the scrollback limit must exhaust the ladder: \(settled)"
            )
            XCTAssertGreaterThanOrEqual(
                settled.historySize,
                5_900,
                "the settle must credit at least the pane's history: \(settled)"
            )
            XCTAssertGreaterThanOrEqual(
                settled.depth,
                6_000,
                "the deepened capture must be charged the full inline depth: \(settled)"
            )

            // `unechoedPrintf` keeps the typed command line from matching, so
            // only the pane's real output can satisfy this wait.
            _ = try await setup.executeConnectedCommand(
                "tmux send-keys -l -t \(pane) \"\(unechoedPrintf("TESSERA-HIST-AFTER"))\""
                    + " && tmux send-keys -t \(pane) Enter"
            )
            try await waitUntil("live output after the deepen", timeout: 30) {
                terminal.transcript.contains("TESSERA-HIST-AFTER")
            }
            XCTAssertEqual(
                terminal.box.droppedForeignFeeds,
                0,
                "the deepen must not cost the surface a foreign-feed-free painter"
            )
            let successMarker = "TESSERA_IOS_INLINE_HISTORY_OK"
                + " rowsBefore=\(rowsBeforeDeepen) rowsAfter=\(rowsAfterDeepen)"
                + " depth=\(settled.depth) historySize=\(settled.historySize)"
                + " canDeepen=\(settled.canDeepen)"
            XCTContext.runActivity(named: successMarker) { _ in }
            print(successMarker)

            try await cleanupInlineHistoryFixture(named: fixtureSession, using: setup)
        } catch {
            detachInline()
            do {
                try await cleanupInlineHistoryFixture(named: fixtureSession, using: setup)
            } catch let cleanupError {
                throw TmuxIsolationFixtureCleanupFailure(primary: error, cleanup: cleanupError)
            }
            throw error
        }
    }

    /// Rows retained above the viewport, the iOS counterpart of Termux's
    /// `activeTranscriptRows`. `getBufferAsData` walks the whole circular
    /// buffer, so the scrollback depth is its line count less the viewport.
    @MainActor
    private func historyRowCount(of terminal: TmuxIsolationTerminal) -> Int {
        let transcript = terminal.transcript
        var lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).count
        if transcript.hasSuffix("\n") { lines -= 1 }
        return max(0, lines - terminal.surfaceState.rows)
    }

    /// The case's history-limit lives on its own session, so killing that
    /// session is the whole cleanup.
    @MainActor
    private func cleanupInlineHistoryFixture(
        named sessionName: String,
        using session: SSHSession
    ) async throws {
        _ = try await session.executeConnectedCommand(
            "tmux kill-session -t '=\(sessionName)' >/dev/null 2>&1 || true"
        )
        let remaining = try await session.executeConnectedCommand(
            "tmux has-session -t '=\(sessionName)' >/dev/null 2>&1 && echo PRESENT || echo ABSENT"
        )
        guard remaining.contains("ABSENT") else {
            throw IntegrationError.failed(
                "inline history fixture \(sessionName) survived cleanup: \(remaining)"
            )
        }
    }

    @MainActor
    private func resetConnectionState(endpoint: String) async {
        SSHAuthenticationPolicyStore.shared.resetForTesting()
        await KnownHostsStore.shared.remove(endpoint: endpoint)
    }

    private func makeHost(
        config: Config,
        transport: HostTransport,
        useChaosHost: Bool = false
    ) -> Host {
        Host(
            name: "Integration \(transport.rawValue)",
            address: useChaosHost ? config.chaosHost : config.stableHost,
            port: config.port,
            user: config.user,
            password: config.password,
            transport: transport,
            autoTmux: false,
            launchMode: .customCommand,
            launchCommand: "exec /bin/bash --noprofile --norc"
        )
    }

    private func makeInputPayload() -> [UInt8] {
        var payload = Array("\u{1B}[200~".utf8)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\n".utf8)
        while payload.count < 4_096 {
            payload.append(contentsOf: alphabet)
        }
        payload.append(contentsOf: Array("\u{1B}[<0;10;5M\u{1B}[<0;10;5m".utf8))
        payload.append(contentsOf: Array("\u{1B}[201~".utf8))
        return payload
    }

    private struct TmuxIsolationFixture: Decodable {
        struct Target: Decodable {
            let windowID: String
            let paneID: String

            private enum CodingKeys: String, CodingKey {
                case windowID = "window_id"
                case paneID = "pane_id"
            }
        }

        let marker: String
        let session: String
        let token: String
        let markers: [String: String]
        let topology: [String: Target]

        func target(named owner: String) throws -> (windowID: WindowId, paneID: PaneId) {
            guard let target = topology[owner],
                  let windowRaw = Int(target.windowID.dropFirst()),
                  let paneRaw = Int(target.paneID.dropFirst())
            else {
                throw IntegrationError.failed("missing or invalid \(owner) isolation topology")
            }
            return (WindowId(windowRaw), PaneId(paneRaw))
        }

        func marker(for owner: String) throws -> String {
            guard let marker = markers[owner] else {
                throw IntegrationError.failed("missing \(owner) isolation marker")
            }
            return marker
        }
    }

    /// Real Codex runs against an offline provider and a seeded transcript.
    /// The runner invokes initial and restore in separate disposable app
    /// processes, while the same remote TUI retains its unsent composer draft.
    @MainActor
    func test_liveCodexMouseSurvivesLifecycleOnBothTransports() async throws {
        let config = try Config.load()
        let verboseKey = DiagnosticLogStore.verboseDiagnosticsDefaultsKey
        let previousVerbose = UserDefaults.standard.object(forKey: verboseKey)
        UserDefaults.standard.set(true, forKey: verboseKey)
        defer {
            if let previousVerbose { UserDefaults.standard.set(previousVerbose, forKey: verboseKey) }
            else { UserDefaults.standard.removeObject(forKey: verboseKey) }
        }
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["TESSERA_CODEX_SCROLL_FIXTURE_ROOT"],
              root.range(of: "^/tmp/tessera-codex-[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              let base = environment["TESSERA_CODEX_SCROLL_SESSION"],
              base.range(of: "^tessera-ios-codex-[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw XCTSkip("run-owned offline Codex fixture is required")
        }
        let phase = environment["TESSERA_CODEX_SCROLL_PHASE"] ?? "initial"
        guard ["initial", "restore"].contains(phase) else { throw IntegrationError.failed("invalid Codex phase") }
        let setupHost = makeHost(config: config, transport: .ssh)
        let setup = SSHSession(host: setupHost)
        defer { setup.disconnect() }
        _ = try await connect(session: setup, pendingRequest: { setup.pendingHostKeyVerification }, timeout: 20)
        let columns = phase == "initial" ? 100 : 56
        let rows = phase == "initial" ? 30 : 20
        let rowPattern = try NSRegularExpression(pattern: "ROW_(\\d{5})")
        func numberedRows(_ text: String) -> [Int] {
            rowPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
            }
        }
        for (label, transport) in [("ssh", HostTransport.ssh), ("mosh", HostTransport.mosh)] {
            let target = "\(base)-\(label)"
            let viewTarget = AutoTmuxCommands.moshViewSessionName(for: target)
            let cleanup = "tmux kill-session -t '=\(viewTarget)' 2>/dev/null || true; "
                + "tmux kill-session -t '=\(target)' 2>/dev/null || true"
            var host = makeHost(config: config, transport: transport)
            let identity = TmuxController.GridAuthorityIdentity(id: "codex-\(target)", displayName: phase == "initial" ? "iPad" : "iPhone")
            var moshClient: MoshContinuationClient?
            var moshTraceTask: Task<Void, Never>?
            var moshTraceBytes: [UInt8] = []
            var inline: SSHSession?
            var inlinePump: Task<Void, Never>?
            var replacementChannel: TmuxControlChannel?
            var replacementPump: Task<Void, Never>?
            let terminal: TmuxIsolationTerminal
            let controller: TmuxController
            if transport == .mosh {
                host.autoTmux = true
                host.launchMode = .pinnedTmux
                host.tmuxSessionName = target
                host.launchCommand = nil
                let client = MoshContinuationClient(host: host, sessionName: target, identity: identity, columns: columns, rows: rows)
                moshClient = client
                moshTraceTask = Task { @MainActor [mosh = client.mosh] in
                    for await bytes in mosh.outputStream {
                        moshTraceBytes.append(contentsOf: bytes)
                        if moshTraceBytes.count > 524_288 {
                            moshTraceBytes.removeFirst(moshTraceBytes.count - 524_288)
                        }
                    }
                }
                terminal = client.terminal
                controller = client.controller
            } else {
                terminal = TmuxIsolationTerminal(label: "codex-\(phase)-\(label)", columns: columns, rows: rows)
                controller = TmuxController(controlPath: .inline)
                controller.gridAuthorityIdentity = identity
                controller.setGridAuthorityUsesCompactSinglePaneGrid(phase == "restore")
                controller.updateClientSize(cols: columns, rows: rows)
                installInlineTerminalSurface(controller, terminal: terminal)
            }
            // SwiftTerm exports cleared space cells as NUL bytes after a
            // differential Mosh repaint; compare the text the grid displays.
            func codexTranscript() -> String {
                terminal.transcript.replacingOccurrences(of: "\u{0}", with: " ")
            }
            let input = CodexMouseInputDelegate { [weak moshClient, weak controller, box = terminal.box] bytes in
                box.noteOutOfBandInput()
                if let moshClient { moshClient.mosh.send(bytes) }
                else { controller?.sendInput(bytes) }
            }
            terminal.view.terminalDelegate = input
            func stopClients() {
                moshTraceTask?.cancel()
                replacementPump?.cancel()
                replacementChannel?.disconnect()
                inlinePump?.cancel()
                inline?.disconnect()
                moshClient?.stop()
            }
            defer { stopClients() }
            func attachInline() async throws {
                let connection = SSHSession(host: host)
                connection.resize(cols: columns, rows: rows)
                controller.sendBytes = { [weak connection] bytes in connection?.send(bytes) }
                // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
                inlinePump = Task { @MainActor in
                    for await bytes in connection.outputStream { await controller.ingestCooperatively(bytes) }
                }
                inline = connection
                _ = try await connect(session: connection, pendingRequest: { connection.pendingHostKeyVerification }, timeout: 20)
                connection.send(Array((AutoTmuxCommands.controlModeSessionCommand(sessionTarget: target) + "\n").utf8))
                try await waitForTmuxHydration(controller, operation: "Codex \(label) hydration")
                controller.declareRenderSurfaces([SurfaceDeclaration(surfaceID: .live, presentation: .single)])
            }
            do {
                if phase == "initial" {
                    _ = try await setup.executeConnectedCommand("python3 '\(root)/seed.py' '\(root)/\(target)' >/dev/null; "
                        + "ln -s '\(root)/codex-x86_64-unknown-linux-musl' '\(root)/\(target)/codex-x86_64-unknown-linux-musl'")
                    _ = try await setup.executeConnectedCommand("tmux new-session -d -s '\(target)' -c /tmp -x 100 -y 30; tmux set-option -t '\(target)' mouse off")
                }
                if let client = moshClient {
                    _ = try await connect(session: client.mosh, pendingRequest: { client.mosh.pendingHostKeyVerification }, timeout: 35)
                    client.channel.connect()
                    try await waitForTmuxHydration(controller, operation: "Codex mosh hydration", channel: client.channel)
                } else {
                    try await attachInline()
                }
                // Opening the session (and relaunching into it in the restore
                // phase) is a show. Attach alone never sizes the window; the
                // show takes control at this device's grid.
                try await showAndWaitForControl(controller, operation: "Codex \(label) \(phase) open")
                if phase == "initial" {
                    input.input(Array("python3 '\(root)/\(target)/run.py'\n".utf8))
                    try await waitUntil("\(label) offline Codex transcript", timeout: 20) {
                        codexTranscript().contains("ROW_00300") && codexTranscript().contains("Ask Codex to do anything")
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    input.input(Array("KEEP MY DRAFT".utf8))
                    _ = try await setup.executeConnectedCommand("tmux display-message -p -t '\(target):0.0' '#{pane_pid}' > '\(root)/\(target)-pane.pid'")
                }
                let panePID = try await setup.executeConnectedCommand("cat '\(root)/\(target)-pane.pid'")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                func observe(_ stage: String) async throws -> [Int] {
                    do {
                        try await waitUntil("\(label) \(phase) \(stage) draft and mouse", timeout: 20) {
                            codexTranscript().contains("KEEP MY DRAFT") && !numberedRows(codexTranscript()).isEmpty
                                && terminal.view.getTerminal().mouseMode != .off
                        }
                    } catch {
                        let failure = XCTAttachment(string: "mouse=\(terminal.view.getTerminal().mouseMode) alt=\(terminal.view.getTerminal().isCurrentBufferAlternate) owner=\(String(describing: terminal.box.boundOwner)) authority=\(controller.gridAuthority) transport=\(String(describing: moshClient?.mosh.state))\n\(codexTranscript())")
                        failure.name = "codex-\(label)-\(phase)-\(stage)-failure-state"
                        failure.lifetime = .keepAlways
                        add(failure)
                        if !moshTraceBytes.isEmpty {
                            let wire = XCTAttachment(string: String(decoding: moshTraceBytes, as: UTF8.self).debugDescription)
                            wire.name = "codex-\(label)-\(phase)-\(stage)-failure-wire"
                            wire.lifetime = .keepAlways
                            add(wire)
                        }
                        if let data = DiagnosticLogStore.attachmentData() {
                            let diagnostics = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
                            diagnostics.name = "codex-\(label)-\(phase)-\(stage)-failure-diagnostics"
                            diagnostics.lifetime = .keepAlways
                            add(diagnostics)
                        }
                        throw error
                    }
                    let remoteState = try await setup.executeConnectedCommand("tmux display-message -p -t '\(target):0.0' '#{pane_pid}|#{alternate_on}|#{mouse_standard_flag}|#{mouse_button_flag}|#{mouse_all_flag}|#{mouse_sgr_flag}|#{pane_in_mode}'")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    XCTAssertEqual(remoteState, "\(panePID)|1|0|0|1|1|0", "Codex process, all-motion request and copy-mode state must survive \(stage)")
                    // Read the cells after the remote query so no await can
                    // separate the recorded row range from its native frame.
                    let text = codexTranscript()
                    let visible = numberedRows(text)
                    terminal.view.layer.setNeedsDisplay()
                    terminal.view.layer.displayIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: terminal.view.bounds).image { terminal.view.layer.render(in: $0.cgContext) }
                    let frame = XCTAttachment(image: image)
                    frame.name = "codex-\(label)-\(phase)-\(stage)-CoreGraphics-grid"
                    frame.lifetime = .keepAlways
                    add(frame)
                    let evidence = XCTAttachment(string: "pid=\(ProcessInfo.processInfo.processIdentifier) rows=\(visible) mouse=\(terminal.view.getTerminal().mouseMode) owner=\(String(describing: terminal.box.boundOwner))\n\(text)")
                    evidence.name = "codex-\(label)-\(phase)-\(stage)-state"
                    evidence.lifetime = .keepAlways
                    add(evidence)
                    return visible
                }
                func assertScroll(_ stage: String) async throws {
                    let before = try await observe("\(stage)-before")
                    let wireStart = input.sent.count
                    for _ in 0..<6 { terminal.view.getTerminal().sendEvent(buttonFlags: 64, x: 20, y: 5) }
                    try await waitUntil("\(label) \(stage) scrolls older Codex rows", timeout: 10) {
                        guard let last = numberedRows(codexTranscript()).last, let previous = before.last else { return false }
                        return last < previous
                    }
                    let older = try await observe("\(stage)-up")
                    for _ in 0..<6 { terminal.view.getTerminal().sendEvent(buttonFlags: 65, x: 20, y: 5) }
                    try await waitUntil("\(label) \(stage) scrolls newer Codex rows", timeout: 10) {
                        guard let last = numberedRows(codexTranscript()).last, let previous = older.last else { return false }
                        return last > previous
                    }
                    _ = try await observe("\(stage)-down")
                    let wire = String(decoding: input.sent.dropFirst(wireStart), as: UTF8.self)
                    XCTAssertTrue(wire.contains("\u{1b}[<64;21;6M"), wire.debugDescription)
                    XCTAssertTrue(wire.contains("\u{1b}[<65;21;6M"), wire.debugDescription)
                }
                try await assertScroll(phase == "initial" ? "fresh" : "app-restart-compact")
                controller.prepareForAppInactivity()
                try await Task.sleep(for: .milliseconds(600))
                controller.refreshActiveWindowOnForeground()
                try await assertScroll("foreground")
                // A sub-1.5 s interruption is not a show edge: the foreground
                // read finds this device's stamp at its own grid and keeps it.
                XCTAssertEqual(controller.gridAuthority, .mine, "a brief inactive interval must not yield")
                XCTAssertFalse(controller.gridAuthorityReclaimInFlight, "a brief inactive interval must not claim")
                if phase == "initial" {
                    let oldOwner = terminal.box.boundOwner
                    let dropTarget = transport == .mosh ? viewTarget : target
                    let receipt = try await setup.executeConnectedCommand("/usr/local/bin/tessera-fixture-probe tmux-isolation-drop-transport --session '\(dropTarget)'")
                    XCTAssertTrue(receipt.contains("\"control_client_count\": 1"), receipt)
                    if let client = moshClient {
                        try await waitUntil("Codex control transport closed", timeout: 10) { client.channel.terminationReason != nil }
                        controller.sideChannelDisconnected()
                        client.channel.disconnect()
                        let channel = TmuxControlChannel(host: host, sessionName: target, initialSize: (columns, rows))
                        replacementChannel = channel
                        controller.sendBytes = { [weak channel] bytes in channel?.send(bytes) }
                        // Synchronous on purpose: production's side-channel loop also calls `ingest` (SessionView).
                        replacementPump = Task { @MainActor in
                            for await bytes in channel.outputStream { controller.ingest(bytes) }
                        }
                        channel.connect()
                        try await waitForTmuxHydration(controller, operation: "Codex replacement side channel", channel: channel)
                    } else {
                        inlinePump?.cancel()
                        inline?.disconnect()
                        controller.reset()
                        try await attachInline()
                    }
                    controller.declareRenderSurfaces([SurfaceDeclaration(surfaceID: .live, presentation: .single)])
                    try await waitUntil("Codex new render owner", timeout: 15) {
                        terminal.box.boundOwner != nil && terminal.box.boundOwner != oldOwner
                    }
                    try await assertScroll("reconnect")
                    // The reconnect read finds this device's own stamp at its
                    // own grid: control is kept without another show.
                    try await waitUntil("Codex \(label) reconnect keeps control", timeout: 3) {
                        controller.gridAuthority == .mine && !controller.gridAuthorityReclaimInFlight
                    }
                }
                stopClients()
                if phase == "restore" { _ = try await setup.executeConnectedCommand(cleanup) }
            } catch {
                stopClients()
                _ = try? await setup.executeConnectedCommand(cleanup)
                throw error
            }
        }
        XCTContext.runActivity(named: "TESSERA_IOS_CODEX_MOUSE_OK phase=\(phase) ssh=1 mosh=1") { _ in }
    }

    @MainActor
    private final class CodexMouseInputDelegate: TerminalViewDelegate {
        let input: ([UInt8]) -> Void
        var sent: [UInt8] = []
        init(input: @escaping ([UInt8]) -> Void) { self.input = input }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data); input(Array(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// Keeps the real SwiftTerm view alive while the `TerminalBox` owns only a
    /// weak reference. This is the same surface ingress and search adapter as
    /// the app, without mounting any SwiftUI chrome in the integration host.
    @MainActor
    private final class TmuxLandscapeFixtureViewController: UIViewController {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeLeft }
    }

    @MainActor
    private final class TmuxIsolationTerminal {
        let box: TerminalBox
        let view: TerminalView

        init(label: String, columns: Int = 120, rows: Int = 40) {
            view = TerminalView(
                frame: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(columns) * 8,
                    height: CGFloat(rows) * 16
                )
            )
            view.nativeBackgroundColor = .black
            view.backgroundColor = .black
            view.isOpaque = true
            view.resize(cols: columns, rows: rows)
            box = TerminalBox(traceLabel: "live-isolation-\(label)")
            box.attach(view)
            box.markRenderReady()
        }

        var transcript: String {
            String(
                decoding: view.getTerminal().getBufferAsData(kind: .active),
                as: UTF8.self
            )
        }

        var surfaceState: (
            altScreen: Bool,
            mouseMode: RenderMouseMode,
            columns: Int,
            rows: Int
        ) {
            let terminal = view.getTerminal()
            return (
                altScreen: terminal.isCurrentBufferAlternate,
                mouseMode: terminal.mouseMode == .off ? .off : .tracking,
                columns: terminal.cols,
                rows: terminal.rows
            )
        }
    }

    /// Plain SSH and plain mosh do not have tmux ownership transitions, but
    /// they still pass through the exact TerminalBox + FindController ingress
    /// used by the two tmux paths. This catches a future accidental attempt to
    /// apply tmux owner filtering to a transport painter.
    @MainActor
    private func assertPlainIsolation<Session: TerminalSession>(
        session: Session,
        transportLabel: String,
        expectedOwner: String,
        token: String,
        connectTimeout: TimeInterval,
        outputTimeout: TimeInterval
    ) async throws {
        let terminal = TmuxIsolationTerminal(label: "plain-\(transportLabel)")
        var receivedByteCount = 0
        let pump = Task { @MainActor in
            for await bytes in session.outputStream {
                receivedByteCount += bytes.count
                terminal.box.feed(owner: nil, bytes[...])
            }
        }
        defer {
            pump.cancel()
            session.disconnect()
        }

        _ = try await connect(
            session: session,
            pendingRequest: {
                if let ssh = session as? SSHSession {
                    return ssh.pendingHostKeyVerification
                }
                if let mosh = session as? MoshSession {
                    return mosh.pendingHostKeyVerification
                }
                return nil
            },
            timeout: connectTimeout
        )
        session.send(Array(
            ("/usr/local/bin/tessera-fixture-probe tmux-isolation-stream"
                + " --owner \(expectedOwner) --token=\(token)"
                + " --count 300 --hold-seconds 8\n").utf8
        ))

        let expected = try isolationMarker(owner: expectedOwner, token: token)
        try await waitUntil("plain \(transportLabel) isolation marker", timeout: outputTimeout) {
            terminal.transcript.contains(expected)
        }
        if transportLabel != "mosh" {
            try await waitForIsolationHistory(
                expected,
                in: terminal,
                operation: "plain \(transportLabel) deep isolation history"
            )
        }
        XCTAssertGreaterThan(receivedByteCount, expected.utf8.count)
        assertIsolationSurface(
            terminal,
            expectedOwner: expectedOwner,
            token: token,
            label: "\(transportLabel)-plain",
            requiresDeepHistory: transportLabel != "mosh"
        )
    }

    @MainActor
    private func assertInlineTmuxIsolation(
        config: Config,
        token: String,
        sessionName: String
    ) async throws {
        var diagnostics: [String] = []
        let previousDiagnosticsSink = TmuxDiagnostics.sink
        TmuxDiagnostics.sink = { message in
            diagnostics.append(message)
            previousDiagnosticsSink?(message)
        }
        defer { TmuxDiagnostics.sink = previousDiagnosticsSink }

        let host = makeHost(config: config, transport: .ssh)
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )

        let fixtureSession = sessionName
        let fixture: TmuxIsolationFixture
        do {
            fixture = try await createTmuxIsolationFixture(
                using: setup,
                token: token,
                sessionName: fixtureSession
            )
        } catch {
            do {
                try await cleanupTmuxIsolationFixture(named: fixtureSession, using: setup)
            } catch let cleanupError {
                throw TmuxIsolationFixtureCleanupFailure(primary: error, cleanup: cleanupError)
            }
            throw error
        }
        let w1 = try fixture.target(named: "W1")
        let w2 = try fixture.target(named: "W2")
        let p2b = try fixture.target(named: "P2b")
        let sharedTerminal = TmuxIsolationTerminal(label: "inline-live")
        let w2Terminal = TmuxIsolationTerminal(label: "inline-w2")
        let p2bTerminal = TmuxIsolationTerminal(label: "inline-p2b")
        let controller = TmuxController(controlPath: .inline)
        controller.updateClientSize(cols: 120, rows: 40)
        installInlineTerminalSurface(controller, terminal: sharedTerminal)

        var inline: SSHSession?
        var pump: Task<Void, Never>?
        func attachInline() async throws {
            let connection = SSHSession(host: host)
            controller.sendBytes = { [weak connection] bytes in connection?.send(bytes) }
            // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
            let connectionPump = Task { @MainActor in
                for await bytes in connection.outputStream {
                    await controller.ingestCooperatively(bytes)
                }
            }
            _ = try await connect(
                session: connection,
                pendingRequest: { connection.pendingHostKeyVerification },
                timeout: 20
            )
            connection.send(Array("exec tmux -CC attach -t \(fixture.session)\n".utf8))
            inline = connection
            pump = connectionPump
        }
        func detachInline() {
            pump?.cancel()
            pump = nil
            inline?.disconnect()
            inline = nil
        }
        defer { detachInline() }

        do {
            // Enter through the single-pane window so the first proof covers
            // the shared iPad/iPhone surface before exercising the grid seam.
            _ = try await setup.executeConnectedCommand(
                "tmux select-window -t \(fixture.session):W1"
            )
            try await attachInline()
            try await waitUntil("inline tmux W1 hydration", timeout: 15) {
                controller.mode == .tmuxControl
                    && controller.isWindowListHydrated
                    && controller.windows.count == 2
                    && controller.activeWindowId == w1.windowID
                    && controller.activePaneId == w1.paneID
            }
            try await waitForIsolationMarker(
                fixture.marker(for: "W1"),
                in: sharedTerminal,
                operation: "inline W1 history"
            )
            assertIsolationSurface(
                sharedTerminal,
                expectedOwner: "W1",
                token: token,
                label: "ssh-tmux-w1"
            )

            controller.selectWindow(w2.windowID)
            try await waitUntil("inline tmux W2 split", timeout: 12) {
                controller.activeWindowId == w2.windowID
                    && controller.windows.first(where: { $0.id == w2.windowID })?.panes.count == 2
            }
            installInlinePaneSurface(
                controller,
                paneID: w2.paneID,
                terminal: w2Terminal
            )
            installInlinePaneSurface(
                controller,
                paneID: p2b.paneID,
                terminal: p2bTerminal
            )
            // Match PaneGridView's production mount policy: the focused pane
            // receives deep history, while its background sibling starts with
            // a viewport-only capture until focus moves to it.
            controller.refreshPane(paneId: w2.paneID, deep: true)
            controller.refreshPane(paneId: p2b.paneID, deep: false)
            try await waitForIsolationHistory(
                fixture.marker(for: "W2"),
                in: w2Terminal,
                operation: "inline W2 focused split history"
            )
            try await waitForIsolationMarker(
                fixture.marker(for: "P2b"),
                in: p2bTerminal,
                operation: "inline P2b background viewport"
            )
            assertIsolationSurface(
                w2Terminal,
                expectedOwner: "W2",
                token: token,
                label: "ssh-tmux-w2-pane"
            )
            assertIsolationSurface(
                p2bTerminal,
                expectedOwner: "P2b",
                token: token,
                label: "ssh-tmux-p2b-pane-background",
                requiresDeepHistory: false
            )

            controller.sendControlCommand("select-pane -t \(p2b.paneID.description)")
            try await waitUntil("inline tmux P2b focus", timeout: 12) {
                controller.activeWindowId == w2.windowID
                    && controller.activePaneId == p2b.paneID
            }
            controller.refreshPane(paneId: p2b.paneID, deep: true)
            try await waitForIsolationHistory(
                fixture.marker(for: "P2b"),
                in: p2bTerminal,
                operation: "inline P2b focused split history"
            )
            assertIsolationSurface(
                p2bTerminal,
                expectedOwner: "P2b",
                token: token,
                label: "ssh-tmux-p2b-pane-focused"
            )

            // Collapse back to a shared surface before the reconnect. This
            // gives the new control client the exact old-owner/new-owner
            // boundary that historically leaked retained rows.
            controller.selectWindow(w1.windowID)
            try await waitUntil("inline tmux return W1", timeout: 12) {
                controller.activeWindowId == w1.windowID
            }
            controller.clearAllPaneSinks()
            try await waitForIsolationMarker(
                fixture.marker(for: "W1"),
                in: sharedTerminal,
                operation: "inline W1 before forced reconnect"
            )

            // The fixture kills only the SSH transport carrying the remote
            // `tmux -CC` client. The replacement connection must hydrate and
            // repaint the same W1 without retaining stale W2/P2b rows in the
            // real TerminalBox.
            let dropped = try await setup.executeConnectedCommand(
                "/usr/local/bin/tessera-fixture-probe tmux-isolation-drop-transport"
                    + " --session \(fixture.session)"
            )
            XCTAssertTrue(
                dropped.contains("TESSERA_TMUX_ISOLATION_TRANSPORT_DROPPED_V1"),
                dropped
            )
            try await Task.sleep(nanoseconds: 250_000_000)
            detachInline()
            controller.reset()
            try await attachInline()
            try await waitUntil("inline tmux reconnect hydration", timeout: 15) {
                controller.mode == .tmuxControl
                    && controller.isWindowListHydrated
                    && controller.windows.count == 2
                    && controller.activeWindowId == w1.windowID
                    && controller.activePaneId == w1.paneID
            }
            try await waitForIsolationHistory(
                fixture.marker(for: "W1"),
                in: sharedTerminal,
                operation: "inline W1 after forced reconnect"
            )
            assertIsolationSurface(
                sharedTerminal,
                expectedOwner: "W1",
                token: token,
                label: "ssh-tmux-w1-reconnect"
            )
            XCTAssertEqual(sharedTerminal.box.droppedForeignFeeds, 0)
            XCTAssertEqual(w2Terminal.box.droppedForeignFeeds, 0)
            XCTAssertEqual(p2bTerminal.box.droppedForeignFeeds, 0)

            try await assertLiveSplitRoundTrip(controller: controller, token: token)

            try await cleanupTmuxIsolationFixture(fixture, using: setup)
        } catch {
            print("TESSERA_IOS_TMUX_ISOLATION_CONTROLLER_DIAGNOSTICS_BEGIN")
            diagnostics.forEach { print($0) }
            print("TESSERA_IOS_TMUX_ISOLATION_CONTROLLER_DIAGNOSTICS_END")
            do {
                try await cleanupTmuxIsolationFixture(fixture, using: setup)
            } catch let cleanupError {
                throw TmuxIsolationFixtureCleanupFailure(primary: error, cleanup: cleanupError)
            }
            throw error
        }
    }

    @MainActor
    private func assertMoshTmuxIsolation(
        config: Config,
        token: String,
        sessionName: String
    ) async throws {
        let controlHost = makeHost(
            config: config,
            transport: .ssh,
            useChaosHost: true
        )
        let setup = SSHSession(host: controlHost)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )

        let fixtureSession = sessionName
        let fixture: TmuxIsolationFixture
        do {
            fixture = try await createTmuxIsolationFixture(
                using: setup,
                token: token,
                sessionName: fixtureSession
            )
        } catch {
            do {
                try await cleanupTmuxIsolationFixture(named: fixtureSession, using: setup)
            } catch let cleanupError {
                throw TmuxIsolationFixtureCleanupFailure(primary: error, cleanup: cleanupError)
            }
            throw error
        }
        let w1 = try fixture.target(named: "W1")
        let w2 = try fixture.target(named: "W2")
        let p2b = try fixture.target(named: "P2b")
        let p2bSurface = SurfaceId("overlay:\(p2b.paneID.description)")
        var moshHost = makeHost(
            config: config,
            transport: .mosh,
            useChaosHost: true
        )
        moshHost.autoTmux = true
        moshHost.launchMode = .pinnedTmux
        moshHost.tmuxSessionName = fixture.session
        moshHost.launchCommand = nil

        // `MoshSessionView` retains one compact live terminal: Mosh paints it
        // directly while the ledger binds the same box for `.live` history.
        // Keep the actual terminal at an iPhone-sized 50×20 instead of hiding
        // owner transitions behind a second, test-only history surface.
        let compactColumns = 50
        let compactRows = 20
        let liveTerminal = TmuxIsolationTerminal(
            label: "mosh-live-compact",
            columns: compactColumns,
            rows: compactRows
        )
        let overlayTerminal = TmuxIsolationTerminal(label: "mosh-overlay-history")
        let historyAdapter = MoshRenderLedgerSurfaceAdapter()
        var lastReadyOwner: [SurfaceId: TerminalRenderOwner] = [:]
        var lastPresentedOwner: [SurfaceId: TerminalRenderOwner] = [:]
        var lastReadyPayload: [SurfaceId: String] = [:]
        var appliedHistoryCount = 0
        let mosh = MoshSession(host: moshHost)
        let moshPump = Task { @MainActor in
            for await chunk in mosh.appleAttemptOutputEvents {
                guard chunk.attemptID == mosh.appleActiveSessionAttemptID else { continue }
                // Mosh is the painter for the visible surface. This remains
                // legal while the side-channel history surface is bound.
                let outputLease = historyAdapter.makeTransportOutputLease(
                    deliveryID: chunk.deliveryID,
                    repaintRequestID: chunk.repaintRequestID
                )
                let renderedFully = outputLease.acceptsNextSlice()
                if renderedFully {
                    liveTerminal.box.feed(owner: outputLease.owner, chunk.bytes[...])
                }
                if let deliveryID = chunk.deliveryID {
                    historyAdapter.noteTransportOutputResult(
                        deliveryID: deliveryID,
                        repaintRequestID: chunk.repaintRequestID,
                        renderedFully: renderedFully
                    )
                }
            }
        }
        defer {
            moshPump.cancel()
            mosh.disconnect()
        }

        let deviceIdentity = GridAuthorityDeviceIdentity.current()
        let deviceID = deviceIdentity.id
        let authorityVisibleClientOption = TmuxController.gridAuthorityVisibleClientOption(
            identityID: deviceID
        )
        let controller = TmuxController(controlPath: .sideChannel)
        controller.gridAuthorityIdentity = deviceIdentity
        controller.updateClientSize(cols: compactColumns, rows: compactRows)
        historyAdapter.install(
            on: controller,
            scrollbackLimit: { 2_000 },
            boxForSurface: { surfaceID in
                surfaceID == .live ? liveTerminal.box : overlayTerminal.box
            },
            fallbackSurfaceState: { _ in nil },
            onHistoryReady: { surfaceID, history in
                let terminal = surfaceID == .live ? liveTerminal : overlayTerminal
                let oldMaxOffsetY = max(
                    0,
                    terminal.view.contentSize.height - terminal.view.bounds.height
                )
                let oldOffsetY = min(
                    max(0, terminal.view.contentOffset.y),
                    oldMaxOffsetY
                )
                lastReadyPayload[surfaceID] = String(decoding: history.bytes, as: UTF8.self)
                terminal.box.feed(owner: history.owner, history.bytes[...])
                lastReadyOwner[surfaceID] = history.owner
                // Exercise the product's two-phase seam: `historyReady` feeds
                // first, then a later UI turn physically places the real
                // SwiftTerm scroll view before the exact owner is presented.
                Task { @MainActor in
                    await Task.yield()
                    guard terminal.box.boundOwner == history.owner else {
                        controller.submitRenderFact(.historyPresentationFailed(
                            surfaceID,
                            owner: RenderOwner(
                                windowID: history.owner.windowId,
                                paneID: history.owner.paneId,
                                epoch: history.owner.epoch
                            )
                        ))
                        return
                    }
                    let newMaxOffsetY = max(
                        0,
                        terminal.view.contentSize.height - terminal.view.bounds.height
                    )
                    let targetY: CGFloat
                    switch history.placement {
                    case .preserveDistanceFromBottom:
                        targetY = max(
                            0,
                            newMaxOffsetY - (oldMaxOffsetY - oldOffsetY)
                                - history.scrollPoints * 3
                        )
                    case .bottom:
                        targetY = max(0, newMaxOffsetY - history.scrollPoints * 3)
                    }
                    terminal.view.contentOffset = CGPoint(
                        x: terminal.view.contentOffset.x,
                        y: min(max(0, targetY), newMaxOffsetY)
                    )
                    guard terminal.box.boundOwner == history.owner else {
                        controller.submitRenderFact(.historyPresentationFailed(
                            surfaceID,
                            owner: RenderOwner(
                                windowID: history.owner.windowId,
                                paneID: history.owner.paneId,
                                epoch: history.owner.epoch
                            )
                        ))
                        return
                    }
                    controller.submitRenderFact(.historyPresented(
                        surfaceID,
                        owner: RenderOwner(
                            windowID: history.owner.windowId,
                            paneID: history.owner.paneId,
                            epoch: history.owner.epoch
                        )
                    ))
                    lastPresentedOwner[surfaceID] = history.owner
                    appliedHistoryCount += 1
                }
            },
            onHistoryDropped: { surfaceID, _, reason in
                XCTFail("production mosh adapter dropped \(surfaceID): \(reason)")
            },
            onRequestTransportFullFrame: { onScheduled, completion in
                mosh.forceFullRepaint(
                    onScheduled: onScheduled,
                    completion: completion
                )
            },
            onCancelTransportFullFrame: { requestID in
                mosh.cancelFullRepaint(requestID: requestID)
            },
            onRetireAllTransportFullFrames: {
                mosh.retireOutstandingFullRepaints()
            },
            currentTransportOutputDeliveryID: {
                mosh.latestOutputDeliveryID
            },
            onSaveWindowModes: { _, _ in }
        )
        // Match MoshSessionView's authority-repaint bridge as well as its
        // history bridge. Initial attach reserves a correlated frame too;
        // leaving that reservation unacknowledged contaminates later rebinds.
        var authorityRepaintRequestID: UInt64?
        var authorityRepaintHookActive = true
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            var scheduledRequestID: UInt64?
            historyAdapter.requestOwnedTransportFullFrame(
                retargetsAcrossSurfaceRebind: true,
                onScheduled: { requestID in
                    scheduledRequestID = requestID
                    authorityRepaintRequestID = requestID
                },
                completion: { acceptedDeliveryID in
                    guard authorityRepaintHookActive else { return }
                    if let requestID = scheduledRequestID {
                        guard requestID == authorityRepaintRequestID else { return }
                        authorityRepaintRequestID = nil
                    }
                    if acceptedDeliveryID != nil {
                        controller.completeGridAuthoritySideChannelRepaint(generation: generation)
                    } else {
                        controller.failGridAuthoritySideChannelRepaint(generation: generation)
                    }
                }
            )
        }
        defer {
            authorityRepaintHookActive = false
            controller.onGridAuthoritySideChannelRepaintRequired = nil
            historyAdapter.deactivate()
        }
        var channel: TmuxControlChannel?
        var channelPump: Task<Void, Never>?
        func attachSideChannel() {
            let connection = TmuxControlChannel(
                host: moshHost,
                sessionName: fixture.session,
                initialSize: (compactColumns, compactRows)
            )
            controller.sendBytes = { [weak connection] bytes in connection?.send(bytes) }
            // Synchronous on purpose: production's side-channel loop also calls `ingest` (SessionView).
            let connectionPump = Task { @MainActor in
                for await bytes in connection.outputStream {
                    controller.ingest(bytes)
                }
            }
            connection.connect()
            channel = connection
            channelPump = connectionPump
        }
        func detachSideChannel() {
            channelPump?.cancel()
            channelPump = nil
            channel?.disconnect()
            channel = nil
        }
        defer { detachSideChannel() }

        do {
            // The fixture defaults to W2. Exercise the real compact switcher
            // path from W1 so the ledger must clear the shared `.live` owner
            // before it exposes W2 history.
            _ = try await setup.executeConnectedCommand(
                "tmux select-window -t \(fixture.session):W1"
            )
            _ = try await connect(
                session: mosh,
                pendingRequest: { mosh.pendingHostKeyVerification },
                timeout: 35
            )
            mosh.resize(cols: compactColumns, rows: compactRows)
            attachSideChannel()
            try await waitForTmuxHydration(
                controller,
                operation: "mosh tmux isolation hydration"
            )
            try await waitUntil("mosh tmux W1 active pane", timeout: 12) {
                controller.windows.count == 2
                    && controller.activeWindowId == w1.windowID
                    && controller.activePaneId == w1.paneID
            }
            controller.declareRenderSurfaces([SurfaceDeclaration(
                surfaceID: .live,
                presentation: .single
            )])
            controller.submitRenderFact(.scrollbackLimit(lines: 2_000))
            // Attach never sizes the window; opening the displayed session is
            // the show that takes control at the compact grid. Show before
            // waiting for the painter: the show's claim is what forces the
            // compact size and the bound, consumed authority frame.
            controller.gridAuthorityShown()
            try await waitUntil("mosh compact W1 painter ready", timeout: 15) {
                liveTerminal.box.boundOwner?.paneId == w1.paneID
                    && liveTerminal.box.painterFeedsAdmitted
            }
            try await waitForShownControl(controller, operation: "mosh tmux isolation open")
            // This is the same reducer fact emitted by an upward mosh scroll.
            // The subsequent FindController scan then scrolls to a real
            // retained marker in the synthesized local history.
            historyAdapter.noteHistoryRequest(surfaceID: .live, pointsY: 180, isInertial: false)
            let w1HistoryBaseline = appliedHistoryCount
            controller.submitRenderFact(.scrollbackRequested(
                .live,
                pointsY: 180,
                isInertial: false
            ))
            try await waitUntil("mosh compact W1 history ready", timeout: 15) {
                appliedHistoryCount > w1HistoryBaseline
                    && lastReadyOwner[.live]?.paneId == w1.paneID
                    && lastReadyOwner[.live] == liveTerminal.box.boundOwner
                    && lastPresentedOwner[.live] == lastReadyOwner[.live]
            }
            try await waitForIsolationMarker(
                fixture.marker(for: "W1"),
                in: liveTerminal,
                operation: "mosh W1 compact shared-live scrollback"
            )
            assertIsolationSurface(
                liveTerminal,
                expectedOwner: "W1",
                token: token,
                label: "mosh-tmux-w1-compact-shared-live-history"
            )
            XCTAssertEqual(
                lastReadyOwner[.live]?.paneId,
                w1.paneID,
                "Mosh compact history must pass through the shared live ready adapter before W2"
            )
            XCTAssertGreaterThan(
                appliedHistoryCount,
                0,
                "Mosh compact history adapter must apply a ready-anchored capture before W2"
            )

            let w1OwnerBeforeVisibility = try XCTUnwrap(
                liveTerminal.box.boundOwner,
                "W1 history must bind the compact live terminal before lifecycle facts"
            )
            let w1TranscriptBeforeVisibility = liveTerminal.transcript
            // This harness owns the sole iterator over the raw attempt-output
            // stream above. Creating a facade here would start a competing
            // iterator and split receipt-bearing Mosh frames between them.
            // Exercise the exact controller effects that the production
            // application-visibility facade dispatches instead.
            controller.prepareForAppInactivity()
            controller.refreshActiveWindowOnForeground()
            XCTAssertEqual(liveTerminal.box.boundOwner, w1OwnerBeforeVisibility)
            XCTAssertEqual(liveTerminal.transcript, w1TranscriptBeforeVisibility)
            // Inactive without a background is transparent: the foreground
            // read keeps control and starts no claim.
            try await waitForControlFence(controller, operation: "mosh tmux isolation foreground read")
            XCTAssertEqual(controller.gridAuthority, .mine)
            XCTAssertFalse(controller.gridAuthorityReclaimInFlight)

            controller.selectWindow(w2.windowID)
            do {
                try await waitUntil("mosh compact W1 to W2 switch", timeout: 12) {
                    controller.activeWindowId == w2.windowID
                        && controller.activePaneId == w2.paneID
                        && liveTerminal.box.boundOwner?.paneId == w2.paneID
                        && liveTerminal.box.painterFeedsAdmitted
                }
            } catch {
                print(
                    "TESSERA_IOS_MOSH_W2_SWITCH_TIMEOUT "
                        + "active=\(String(describing: controller.activeWindowId))"
                        + "/\(String(describing: controller.activePaneId)) "
                        + "bound=\(String(describing: liveTerminal.box.boundOwner)) "
                        + "latestDelivery=\(mosh.latestOutputDeliveryID) "
                        + "adapter=\(historyAdapter.painterStateForTesting)"
                )
                throw error
            }
            let w2OwnerAfterSwitch = try XCTUnwrap(liveTerminal.box.boundOwner)
            XCTAssertEqual(w2OwnerAfterSwitch.windowId, w2.windowID)
            XCTAssertEqual(w2OwnerAfterSwitch.paneId, w2.paneID)
            XCTAssertGreaterThan(
                w2OwnerAfterSwitch.epoch,
                w1OwnerBeforeVisibility.epoch,
                "the compact shared terminal must receive a fresh ledger owner for W2"
            )
            historyAdapter.noteHistoryRequest(surfaceID: .live, pointsY: 180, isInertial: false)
            let w2HistoryBaseline = appliedHistoryCount
            controller.submitRenderFact(.scrollbackRequested(
                .live,
                pointsY: 180,
                isInertial: false
            ))
            do {
                try await waitUntil("mosh compact W2 history ready", timeout: 15) {
                    appliedHistoryCount > w2HistoryBaseline
                        && lastReadyOwner[.live]?.paneId == w2.paneID
                        && lastReadyOwner[.live] == liveTerminal.box.boundOwner
                        && lastPresentedOwner[.live] == lastReadyOwner[.live]
                }
            } catch {
                print(
                    "TESSERA_IOS_MOSH_W2_HISTORY_TIMEOUT "
                        + "applied=\(appliedHistoryCount) baseline=\(w2HistoryBaseline) "
                        + "lastReady=\(String(describing: lastReadyOwner[.live])) "
                        + "bound=\(String(describing: liveTerminal.box.boundOwner)) "
                        + "latestDelivery=\(mosh.latestOutputDeliveryID) "
                        + "adapter=\(historyAdapter.painterStateForTesting)"
                )
                throw error
            }
            let w2Marker = try fixture.marker(for: "W2")
            guard lastReadyPayload[.live]?.contains(w2Marker) == true else {
                throw IntegrationError.failed(
                    "mosh W2 history-ready payload did not contain its owner marker; suffix="
                        + String((lastReadyPayload[.live] ?? "<missing>").suffix(800))
                )
            }
            try await waitForIsolationMarker(
                w2Marker,
                in: liveTerminal,
                operation: "mosh W2 compact shared-live scrollback after switch"
            )
            assertIsolationSurface(
                liveTerminal,
                expectedOwner: "W2",
                token: token,
                label: "mosh-tmux-w2-compact-shared-live-history"
            )
            XCTAssertEqual(lastReadyOwner[.live]?.paneId, w2.paneID)

            let p2bHeartbeatMarker = try fixture.marker(for: "P2b")
            let p2bHeartbeatBeforeSelection = isolationHeartbeat(
                in: liveTerminal,
                marker: p2bHeartbeatMarker
            ) ?? 0
            controller.selectPanePreservingWindowZoom(p2b.paneID)
            try await waitUntil("mosh tmux P2b active pane", timeout: 12) {
                controller.activeWindowId == w2.windowID
                    && controller.activePaneId == p2b.paneID
                    && liveTerminal.box.boundOwner?.paneId == p2b.paneID
                    && liveTerminal.box.painterFeedsAdmitted
            }
            try await waitForVisibleMoshClientTuple(
                using: setup,
                sessionName: fixture.session,
                authorityVisibleClientOption: authorityVisibleClientOption,
                expectedWindowID: w2.windowID,
                expectedPaneID: p2b.paneID,
                operation: "mosh P2b exact visible-client tuple after initial selection"
            )
            do {
                try await waitForIsolationMarker(
                    p2bHeartbeatMarker,
                    in: liveTerminal,
                    operation: "mosh P2b UDP painter heartbeat source"
                )
            } catch {
                let diagnostics = DiagnosticLogStore.attachmentData().map {
                    String(decoding: $0, as: UTF8.self)
                } ?? "<no diagnostics>"
                let relevantDiagnostics = diagnostics
                    .split(separator: "\n")
                    .filter { line in
                        line.localizedCaseInsensitiveContains("mosh")
                            || line.localizedCaseInsensitiveContains("tmux")
                            || line.localizedCaseInsensitiveContains("repaint")
                    }
                    .suffix(200)
                    .joined(separator: "\n")
                print(
                    "TESSERA_IOS_MOSH_PAINTER_TIMEOUT "
                        + "latestDelivery=\(mosh.latestOutputDeliveryID) "
                        + "adapter=\(historyAdapter.painterStateForTesting)\n"
                        + "TESSERA_IOS_MOSH_PAINTER_TRANSCRIPT_BEGIN\n"
                        + liveTerminal.transcript
                        + "\nTESSERA_IOS_MOSH_PAINTER_TRANSCRIPT_END\n"
                        + relevantDiagnostics
                )
                throw error
            }
            do {
                try await waitUntil("mosh P2b initial UDP heartbeat", timeout: 8) {
                    (self.isolationHeartbeat(
                        in: liveTerminal,
                        marker: p2bHeartbeatMarker
                    ) ?? 0) > p2bHeartbeatBeforeSelection
                }
            } catch {
                let diagnostics = DiagnosticLogStore.attachmentData().map {
                    String(decoding: $0, as: UTF8.self)
                } ?? "<no diagnostics>"
                let relevantDiagnostics = diagnostics
                    .split(separator: "\n")
                    .filter { line in
                        line.localizedCaseInsensitiveContains("mosh")
                            || line.localizedCaseInsensitiveContains("tmux")
                            || line.localizedCaseInsensitiveContains("repaint")
                    }
                    .suffix(300)
                    .joined(separator: "\n")
                print(
                    "TESSERA_IOS_MOSH_P2B_HEARTBEAT_TIMEOUT "
                        + "baseline=\(p2bHeartbeatBeforeSelection) "
                        + "current=\(String(describing: isolationHeartbeat(in: liveTerminal, marker: p2bHeartbeatMarker))) "
                        + "latestDelivery=\(mosh.latestOutputDeliveryID) "
                        + "adapter=\(historyAdapter.painterStateForTesting)\n"
                        + "TESSERA_IOS_MOSH_P2B_TRANSCRIPT_BEGIN\n"
                        + liveTerminal.transcript
                        + "\nTESSERA_IOS_MOSH_P2B_TRANSCRIPT_END\n"
                        + relevantDiagnostics
                )
                throw error
            }
            let heartbeatBeforeDrop = try XCTUnwrap(
                isolationHeartbeat(in: liveTerminal, marker: p2bHeartbeatMarker),
                "Mosh P2b UDP painter must emit a heartbeat before overlay history or side-channel loss"
            )

            // Establish live-painter liveness before revealing the detached
            // overlay. The side-channel capture and its repaint fence may run
            // while another heartbeat is already in flight; taking the
            // baseline afterwards would make that harmless ordering look like
            // a stalled UDP painter.
            controller.declareRenderSurfaces([
                SurfaceDeclaration(surfaceID: .live, presentation: .single),
                SurfaceDeclaration(
                    surfaceID: p2bSurface,
                    presentation: .overlay,
                    windowID: w2.windowID,
                    paneID: p2b.paneID
                ),
            ])
            controller.submitRenderFact(.scrollbackReturnedToTail(p2bSurface))
            let p2bHistoryBaseline = appliedHistoryCount
            historyAdapter.noteHistoryRequest(surfaceID: p2bSurface, pointsY: 180, isInertial: false)
            controller.submitRenderFact(.scrollbackRequested(
                p2bSurface,
                pointsY: 180,
                isInertial: false
            ))
            try await waitUntil("mosh P2b overlay history ready", timeout: 15) {
                appliedHistoryCount > p2bHistoryBaseline
                    && lastReadyOwner[p2bSurface]?.paneId == p2b.paneID
                    && lastReadyOwner[p2bSurface] == overlayTerminal.box.boundOwner
                    && lastPresentedOwner[p2bSurface] == lastReadyOwner[p2bSurface]
            }
            try await waitForIsolationMarker(
                fixture.marker(for: "P2b"),
                in: overlayTerminal,
                operation: "mosh P2b detached-overlay scrollback"
            )
            assertIsolationSurface(
                overlayTerminal,
                expectedOwner: "P2b",
                token: token,
                label: "mosh-tmux-p2b-overlay-history"
            )
            let ownerBeforeReconnect = try XCTUnwrap(
                overlayTerminal.box.boundOwner,
                "Mosh P2b history must have a ledger owner before side-channel loss"
            )

            // This intentionally kills only the SSH transport carrying the
            // `-CC` client. The fixture stream keeps changing the visible P2b
            // pane. A later numeric heartbeat proves the UDP painter stayed
            // live; raw byte growth alone could have been buffered output.
            let dropped = try await setup.executeConnectedCommand(
                "/usr/local/bin/tessera-fixture-probe tmux-isolation-drop-transport"
                    + " --session \(AutoTmuxCommands.moshViewSessionName(for: fixture.session))"
            )
            XCTAssertTrue(
                dropped.contains("TESSERA_TMUX_ISOLATION_TRANSPORT_DROPPED_V1"),
                dropped
            )
            try await waitUntil("mosh UDP after side-channel drop", timeout: 8) {
                mosh.state == .connected
                    && (self.isolationHeartbeat(in: liveTerminal, marker: p2bHeartbeatMarker) ?? 0)
                        > heartbeatBeforeDrop
            }
            controller.sideChannelDisconnected()
            detachSideChannel()

            attachSideChannel()
            try await waitForTmuxHydration(
                controller,
                operation: "mosh tmux side-channel reconnect hydration"
            )
            try await waitUntil("mosh reconnect P2b active pane", timeout: 12) {
                controller.windows.count == 2
                    && controller.activeWindowId == w2.windowID
                    && controller.activePaneId == p2b.paneID
            }
            // The reconnect read finds this device's stamp at its own grid
            // and keeps control without another show.
            try await waitUntil("mosh side-channel reconnect keeps control", timeout: 3) {
                controller.gridAuthority == .mine && !controller.gridAuthorityReclaimInFlight
            }
            try await waitForVisibleMoshClientTuple(
                using: setup,
                sessionName: fixture.session,
                authorityVisibleClientOption: authorityVisibleClientOption,
                expectedWindowID: w2.windowID,
                expectedPaneID: p2b.paneID,
                operation: "mosh P2b exact visible-client tuple after side-channel reconnect"
            )
            controller.declareRenderSurfaces([
                SurfaceDeclaration(surfaceID: .live, presentation: .single),
                SurfaceDeclaration(
                    surfaceID: p2bSurface,
                    presentation: .overlay,
                    windowID: w2.windowID,
                    paneID: p2b.paneID
                ),
            ])
            controller.submitRenderFact(.scrollbackReturnedToTail(p2bSurface))
            let reconnectHistoryBaseline = appliedHistoryCount
            historyAdapter.noteHistoryRequest(surfaceID: p2bSurface, pointsY: 180, isInertial: false)
            controller.submitRenderFact(.scrollbackRequested(
                p2bSurface,
                pointsY: 180,
                isInertial: false
            ))
            try await waitUntil("mosh P2b reconnect history ready", timeout: 15) {
                appliedHistoryCount > reconnectHistoryBaseline
                    && lastReadyOwner[p2bSurface]?.paneId == p2b.paneID
                    && lastReadyOwner[p2bSurface] == overlayTerminal.box.boundOwner
                    && lastPresentedOwner[p2bSurface] == lastReadyOwner[p2bSurface]
            }
            try await waitForIsolationMarker(
                fixture.marker(for: "P2b"),
                in: overlayTerminal,
                operation: "mosh P2b overlay history after side-channel reconnect"
            )
            assertIsolationSurface(
                overlayTerminal,
                expectedOwner: "P2b",
                token: token,
                label: "mosh-tmux-p2b-overlay-reconnect"
            )
            let ownerAfterReconnect = try XCTUnwrap(
                overlayTerminal.box.boundOwner,
                "Mosh P2b history must rebind after side-channel recovery"
            )
            XCTAssertEqual(ownerAfterReconnect.windowId, ownerBeforeReconnect.windowId)
            XCTAssertEqual(ownerAfterReconnect.paneId, ownerBeforeReconnect.paneId)
            XCTAssertGreaterThan(
                ownerAfterReconnect.epoch,
                ownerBeforeReconnect.epoch,
                "Mosh side-channel recovery must advance the P2b owner epoch"
            )
            XCTAssertEqual(
                lastReadyOwner[p2bSurface],
                ownerAfterReconnect,
                "the production adapter must apply the fresh overlay owner at history-ready"
            )
            XCTAssertEqual(overlayTerminal.box.droppedForeignFeeds, 0)
            XCTAssertEqual(liveTerminal.box.droppedForeignFeeds, 0)

            try await assertLiveSplitRoundTrip(
                controller: controller, token: token, nativeMoshTerminal: liveTerminal,
                nativeMoshInput: { mosh.send($0) },
                nativeMoshDiagnostics: {
                    "state=\(MoshDiagnostics.stateDescription(mosh.state)) "
                        + "transport=\(mosh.transportState.logDescription) "
                        + "latestDelivery=\(mosh.latestOutputDeliveryID) "
                        + "adapter={\(historyAdapter.painterStateForTesting)}"
                },
                verifyNativeSelection: { windowID, paneID in
                    try await self.waitForVisibleMoshClientTuple(
                        using: setup, sessionName: fixture.session,
                        authorityVisibleClientOption: authorityVisibleClientOption,
                        expectedWindowID: windowID, expectedPaneID: paneID,
                        operation: "new split native Mosh input target"
                    )
                }
            )

            try await cleanupTmuxIsolationFixture(fixture, using: setup)
        } catch {
            do {
                try await cleanupTmuxIsolationFixture(fixture, using: setup)
            } catch let cleanupError {
                throw TmuxIsolationFixtureCleanupFailure(primary: error, cleanup: cleanupError)
            }
            throw error
        }
    }

    /// Exercise the controller operation behind Cmd-D on a newly-created window, not
    /// only attaching to a fixture that was already split before connection.
    @MainActor
    private func assertLiveSplitRoundTrip(
        controller: TmuxController,
        token: String,
        nativeMoshTerminal: TmuxIsolationTerminal? = nil,
        nativeMoshInput: (([UInt8]) -> Void)? = nil,
        nativeMoshDiagnostics: (() -> String)? = nil,
        verifyNativeSelection: ((WindowId, PaneId) async throws -> Void)? = nil
    ) async throws {
        var completed = false
        var diagnostics: [String] = []
        let previousDiagnosticsSink = TmuxDiagnostics.sink
        TmuxDiagnostics.sink = { message in
            diagnostics.append(message)
            previousDiagnosticsSink?(message)
        }
        defer {
            TmuxDiagnostics.sink = previousDiagnosticsSink
            if !completed {
                print("TESSERA_LIVE_SPLIT_FAILURE snapshot=\(controller.snapshot)")
                print("TESSERA_LIVE_SPLIT_FAILURE mosh=\(nativeMoshTerminal?.transcript ?? "inline")")
                if let nativeMoshTerminal {
                    print("TESSERA_LIVE_SPLIT_FAILURE boundOwner=\(String(describing: nativeMoshTerminal.box.boundOwner)) "
                        + "painterAdmitted=\(nativeMoshTerminal.box.painterFeedsAdmitted) "
                        + (nativeMoshDiagnostics?() ?? ""))
                }
                diagnostics.forEach { print($0) }
            }
        }
        if nativeMoshTerminal != nil {
            // Dismiss the previous case's history overlay, as the product does
            // when leaving its pane. This sequence verifies the live painter.
            controller.declareRenderSurfaces([SurfaceDeclaration(surfaceID: .live, presentation: .single)])
            controller.submitRenderFact(.scrollbackReturnedToTail(.live))
        }
        let previous = try XCTUnwrap(controller.activeWindowId)
        controller.newWindow()
        try await waitUntil("fresh split test window", timeout: 15) {
            controller.activeWindowId != previous && controller.activePaneId != nil
                && controller.windows.first(where: { $0.id == controller.activeWindowId })?.layout?.paneCount == 1
        }
        let windowID = try XCTUnwrap(controller.activeWindowId)
        let originalPane = try XCTUnwrap(controller.activePaneId)
        let leftMarker = "LEFT-\(token)"
        let rightMarker = "RIGHT-\(token)"
        func send(_ marker: String) {
            let bytes = Array((unechoedPrintf(marker) + "\n").utf8)
            if let nativeMoshInput { nativeMoshInput(bytes) }
            else { controller.sendInput(bytes) }
        }
        try await verifyNativeSelection?(windowID, originalPane)
        send(leftMarker)
        if let nativeMoshTerminal {
            // UDP input and SSH control have independent delivery ordering.
            try await waitForIsolationMarker(leftMarker, in: nativeMoshTerminal, operation: "Mosh input before split")
        }
        controller.splitActivePane(.horizontal)
        try await waitUntil("Cmd-D publishes two panes and new focus", timeout: 15) {
            controller.windows.first(where: { $0.id == windowID })?.layout?.paneCount == 2
                && controller.activePaneId != nil && controller.activePaneId != originalPane
        }
        let newPane = try XCTUnwrap(controller.activePaneId)
        let splitBeforeReorder = try XCTUnwrap(controller.windows.first { $0.id == windowID })
        controller.moveWindow(windowID, to: 0)
        try await waitUntil("split window reorder preserves focus", timeout: 10) {
            !controller.isWindowReorderPending && controller.windows.first?.id == windowID
        }
        let splitAfterReorder = try XCTUnwrap(controller.windows.first { $0.id == windowID })
        XCTAssertEqual(splitAfterReorder.panes.map(\.id), splitBeforeReorder.panes.map(\.id))
        XCTAssertEqual(splitAfterReorder.layout, splitBeforeReorder.layout)
        XCTAssertEqual(splitAfterReorder.isZoomed, splitBeforeReorder.isZoomed)
        XCTAssertEqual(controller.activeWindowId, windowID)
        XCTAssertEqual(controller.activePaneId, newPane)
        try await verifyNativeSelection?(windowID, newPane)

        var left = TmuxIsolationTerminal(label: "split-left")
        var right = TmuxIsolationTerminal(label: "split-right")
        let isInline = nativeMoshTerminal == nil
        func mountGrid() {
            guard isInline else { return }
            installInlinePaneSurface(controller, paneID: originalPane, terminal: left)
            installInlinePaneSurface(controller, paneID: newPane, terminal: right)
            controller.refreshPane(paneId: originalPane, deep: controller.activePaneId == originalPane)
            controller.refreshPane(paneId: newPane, deep: controller.activePaneId == newPane)
        }
        func unmountGrid() {
            guard isInline else { return }
            controller.setPaneSink(originalPane, nil)
            controller.setPaneSink(newPane, nil)
        }
        defer { unmountGrid() }
        mountGrid()
        try await verifyNativeSelection?(windowID, newPane)
        send(rightMarker)
        if let nativeMoshTerminal {
            try await waitUntil("Mosh paints both new split panes", timeout: 15) {
                nativeMoshTerminal.transcript.contains(leftMarker)
                    && nativeMoshTerminal.transcript.contains(rightMarker)
            }
        } else {
            try await waitForIsolationMarker(leftMarker, in: left, operation: "original split pane rendered")
            try await waitForIsolationMarker(rightMarker, in: right, operation: "new split pane rendered")
            XCTAssertFalse(left.transcript.contains(rightMarker), "post-split typing reached the original pane")
            XCTAssertFalse(right.transcript.contains(leftMarker), "new surface contains original pane output")
        }

        controller.selectWindow(previous)
        try await waitUntil("leave new split", timeout: 12) { controller.activeWindowId == previous }
        unmountGrid()
        if let nativeMoshTerminal {
            try await waitUntil("Mosh visibly leaves new split", timeout: 15) {
                nativeMoshTerminal.box.boundOwner?.windowId == previous
                    && nativeMoshTerminal.box.painterFeedsAdmitted
                    && !nativeMoshTerminal.transcript.contains(rightMarker)
            }
        }
        controller.selectWindow(windowID)
        try await waitUntil("return to new split", timeout: 12) { controller.activeWindowId == windowID }
        XCTAssertEqual(controller.windows.first(where: { $0.id == windowID })?.layout?.paneCount, 2)
        XCTAssertEqual(controller.activePaneId, newPane)
        // New view instances prove rehydration rather than retained old pixels.
        left = TmuxIsolationTerminal(label: "split-left-returned")
        right = TmuxIsolationTerminal(label: "split-right-returned")
        mountGrid()
        if let nativeMoshTerminal {
            do {
                try await waitUntil("Mosh restores both split panes", timeout: 15) {
                    nativeMoshTerminal.transcript.contains(leftMarker)
                        && nativeMoshTerminal.transcript.contains(rightMarker)
                }
            } catch {
                print("TESSERA_LIVE_SPLIT_RETURN_FAILURE expected=\(windowID)/\(newPane) "
                    + "leftPresent=\(nativeMoshTerminal.transcript.contains(leftMarker)) "
                    + "rightPresent=\(nativeMoshTerminal.transcript.contains(rightMarker))")
                throw error
            }
        } else {
            try await waitForIsolationMarker(leftMarker, in: left, operation: "original pane after return")
            try await waitForIsolationMarker(rightMarker, in: right, operation: "new pane after return")
        }
        controller.togglePaneZoom()
        try await waitUntil("zoom split", timeout: 12) {
            controller.windows.first(where: { $0.id == windowID })?.isZoomed == true
        }
        XCTAssertEqual(controller.windows.first(where: { $0.id == windowID })?.layout?.paneCount, 2)
        controller.togglePaneZoom()
        try await waitUntil("unzoom split", timeout: 12) {
            controller.windows.first(where: { $0.id == windowID })?.isZoomed == false
        }
        controller.killPane(newPane)
        try await waitUntil("collapse split", timeout: 12) {
            controller.windows.first(where: { $0.id == windowID })?.layout?.paneCount == 1
                && controller.activePaneId == originalPane
        }
        unmountGrid()
        controller.splitActivePane(.vertical)
        try await waitUntil("stacked split publishes layout and focus", timeout: 12) {
            controller.windows.first(where: { $0.id == windowID })?.layout?.paneCount == 2
                && controller.activePaneId != originalPane
        }
        controller.killWindow(windowID)
        try await waitUntil("close owned split window", timeout: 12) {
            !controller.windows.contains(where: { $0.id == windowID })
        }
        print("TESSERA_LIVE_SPLIT_OK transport=\(isInline ? "ssh-tmux" : "mosh-tmux") horizontal=1 vertical=1 input=1 return=1 zoom=1 collapse=1")
        completed = true
    }

    private struct TmuxIsolationFixtureCleanupFailure: Error, CustomStringConvertible {
        let primary: Error
        let cleanup: Error

        var description: String {
            "tmux isolation primary failure: \(primary); fixture cleanup failure: \(cleanup)"
        }
    }

    private func tmuxIsolationFixtureSession(environment name: String) throws -> String {
        guard let session = ProcessInfo.processInfo.environment[name],
              !session.isEmpty,
              session.utf8.count <= 80,
              session.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || byte == 45 || byte == 46 || byte == 95
              })
        else {
            throw IntegrationError.failed(
                "run-app-transport-tests.sh must provide cleanup-safe \(name)"
            )
        }
        return session
    }

    private func createTmuxIsolationFixture(
        using session: SSHSession,
        token: String,
        sessionName: String
    ) async throws -> TmuxIsolationFixture {
        let output = try await session.executeConnectedCommand(
            "/usr/local/bin/tessera-fixture-probe tmux-isolation-session"
                + " --session \(sessionName) --token=\(token) --count 300"
                + " --hold-seconds 180 --heartbeat-seconds 0.5"
                + " --columns 120 --rows 40"
        )
        guard let line = output.split(separator: "\n").first(where: {
            $0.contains("TESSERA_TMUX_ISOLATION_FIXTURE_V1")
        }) else {
            throw IntegrationError.failed("missing tmux isolation fixture output: \(output)")
        }
        let fixture = try JSONDecoder().decode(
            TmuxIsolationFixture.self,
            from: Data(line.utf8)
        )
        guard fixture.token == token, fixture.session == sessionName else {
            throw IntegrationError.failed("mismatched tmux isolation fixture: \(output)")
        }
        return fixture
    }

    @MainActor
    private func cleanupTmuxIsolationFixture(
        _ fixture: TmuxIsolationFixture,
        using session: SSHSession
    ) async throws {
        try await cleanupTmuxIsolationFixture(named: fixture.session, using: session)
    }

    @MainActor
    private func cleanupTmuxIsolationFixture(
        named sessionName: String,
        using session: SSHSession
    ) async throws {
        // A keep-last grouped view can outlive its owner. Both names derive
        // from this run's exact fixture, so retire the view before the owner.
        _ = try await session.executeConnectedCommand(
            "tmux kill-session -t '\(AutoTmuxCommands.moshViewSessionName(for: sessionName))' >/dev/null 2>&1 || true"
        )
        let output = try await session.executeConnectedCommand(
            "/usr/local/bin/tessera-fixture-probe tmux-isolation-cleanup"
                + " --session \(sessionName)"
        )
        guard output.contains("TESSERA_TMUX_ISOLATION_CLEANUP_V1"),
              output.contains("\"session\": \"\(sessionName)\"")
        else {
            throw IntegrationError.failed("targeted tmux isolation cleanup failed: \(output)")
        }
    }

    /// The side-channel controller and Mosh's visible tmux client are distinct
    /// clients. Prove the latter's exact remote selection against the device
    /// stamp written by `AutoTmuxCommands.moshVisibleClientCommand`, rather
    /// than inferring it from the controller's local active-pane model or the
    /// visible UDP heartbeat.
    @MainActor
    private func waitForVisibleMoshClientTuple(
        using session: SSHSession,
        sessionName: String,
        authorityVisibleClientOption: String,
        expectedWindowID: WindowId,
        expectedPaneID: PaneId,
        operation: String
    ) async throws {
        let deadline = Date().addingTimeInterval(12)
        // The visible-client identity marker belongs to the grouped view.
        // Query that marker on the same target as the visible-client bootstrap.
        let viewSessionName = AutoTmuxCommands.moshViewSessionName(for: sessionName)
        var lastStampOutput = "<not queried>"
        var lastClientTuples = "<not queried>"

        while Date() < deadline {
            let stampOutput = try await session.executeConnectedCommand(
                "tmux show-options -qv -t \(viewSessionName) \(authorityVisibleClientOption)"
            )
            let stamps = stampOutput
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
            lastStampOutput = stampOutput

            let clientOutput = try await session.executeConnectedCommand(
                "tmux list-clients -t \(viewSessionName) "
                    + "-F '#{client_name}|#{client_pid}|#{client_created}|#{window_id}|#{pane_id}'"
            )
            let clientTuples = clientOutput
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
            lastClientTuples = clientOutput

            if stamps.count == 1, let stamp = stamps.first {
                let expectedTuple = "\(stamp)|\(expectedWindowID.description)|\(expectedPaneID.description)"
                let matchingTuples = clientTuples.filter { $0 == expectedTuple }
                if matchingTuples.count == 1 {
                    XCTAssertEqual(
                        matchingTuples.count,
                        1,
                        "\(operation) must have one exact stamped visible tmux client tuple"
                    )
                    print(
                        "TESSERA_IOS_MOSH_VISIBLE_CLIENT_TUPLE label=\(operation) "
                            + "tuple=\(expectedTuple)"
                    )
                    return
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw IntegrationError.timedOut(
            "\(operation); option=\(authorityVisibleClientOption) "
                + "stamp=\(lastStampOutput.debugDescription) "
                + "clientTuples=\(lastClientTuples.debugDescription)"
        )
    }

    @MainActor
    private func installInlineTerminalSurface(
        _ controller: TmuxController,
        terminal: TmuxIsolationTerminal,
        // The SwiftTerm scrollback the bind restores. A case that deepens the
        // inline ladder needs this above the user's scrollback preference, or
        // the capture it is asserting is truncated on arrival.
        scrollbackLimit: Int = 2_000
    ) {
        controller.displayWillSwapWithContext = { [box = terminal.box] _, context, _ in
            guard let owner = TerminalRenderOwner(feedContext: context) else { return }
            box.bind(owner: owner, restoringScrollbackLimit: scrollbackLimit)
        }
        controller.feedTerminalWithContext = { [box = terminal.box] bytes, context in
            guard let owner = TerminalRenderOwner(feedContext: context) else { return }
            if box.boundOwner == nil {
                box.bind(owner: owner, restoringScrollbackLimit: scrollbackLimit)
            }
            box.feed(owner: owner, bytes)
        }
        controller.terminalIsInAltScreen = { [view = terminal.view] in
            view.getTerminal().isCurrentBufferAlternate
        }
    }

    @MainActor
    private func installInlinePaneSurface(
        _ controller: TmuxController,
        paneID: PaneId,
        terminal: TmuxIsolationTerminal
    ) {
        controller.setPaneRenderSurface(
            paneID,
            legacyFeed: { [box = terminal.box] bytes in box.feed(bytes) },
            bind: { [box = terminal.box] owner, scrollbackLimit in
                guard let terminalOwner = Self.terminalRenderOwner(owner),
                      terminalOwner.paneId == paneID
                else { return }
                box.bind(owner: terminalOwner, restoringScrollbackLimit: scrollbackLimit)
            },
            feed: { [box = terminal.box] owner, bytes in
                guard let terminalOwner = Self.terminalRenderOwner(owner),
                      terminalOwner.paneId == paneID
                else { return }
                box.feed(owner: terminalOwner, bytes)
            },
            state: { [terminal] in terminal.surfaceState }
        )
    }

    @MainActor
    private func waitForIsolationMarker(
        _ marker: String,
        in terminal: TmuxIsolationTerminal,
        operation: String
    ) async throws {
        try await waitUntil(operation, timeout: 15) {
            terminal.transcript.contains(marker)
        }
    }

    @MainActor
    private func waitForIsolationHistory(
        _ marker: String,
        in terminal: TmuxIsolationTerminal,
        operation: String
    ) async throws {
        try await waitUntil(operation, timeout: 15) {
            let find = FindController()
            find.handlers = TerminalSearchAdapter.handlers(for: terminal.box)
            find.query = marker
            find.updateSearch()
            return find.matchCount > terminal.surfaceState.rows
        }
    }

    @MainActor
    private func isolationHeartbeat(
        in terminal: TmuxIsolationTerminal,
        marker: String
    ) -> Int? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: marker))-HEARTBEAT-(\\d+)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        // A heartbeat is wider than the narrowest split-pane surface used by
        // this gate. On a split window, row-major transcript text interleaves
        // the other pane and the `│` divider between the first and second soft
        // wrap rows. Search both the whole buffer and each pane-column
        // projection so `...-HE` + `ARTBEAT-17` remains semantically adjacent.
        let rows = terminal.transcript.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let maximumColumns = rows.map { row in
            row.split(separator: "│", omittingEmptySubsequences: false).count
        }.max() ?? 1
        var candidates = [terminal.transcript]
        for column in 0..<maximumColumns {
            candidates.append(rows.compactMap { row -> Substring? in
                let columns = row.split(separator: "│", omittingEmptySubsequences: false)
                return columns.indices.contains(column) ? columns[column] : nil
            }.joined())
        }

        return candidates.flatMap { candidate -> [Int] in
            let normalizedScalars = candidate.unicodeScalars.filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.controlCharacters.contains(scalar)
            }
            let normalized = String(String.UnicodeScalarView(normalizedScalars))
            let range = NSRange(normalized.startIndex..., in: normalized)
            return expression.matches(in: normalized, range: range).compactMap { match in
                guard let range = Range(match.range(at: 1), in: normalized) else { return nil }
                return Int(normalized[range])
            }
        }.max()
    }

    @MainActor
    private func assertIsolationSurface(
        _ terminal: TmuxIsolationTerminal,
        expectedOwner: String,
        token: String,
        label: String,
        requiresDeepHistory: Bool = true
    ) {
        let transcript = terminal.transcript
        print("TESSERA_IOS_TMUX_ISOLATION_TRANSCRIPT_BEGIN label=\(label)")
        print(transcript)
        print("TESSERA_IOS_TMUX_ISOLATION_TRANSCRIPT_END label=\(label)")
        print(
            "TESSERA_IOS_TMUX_ISOLATION_DIAGNOSTIC label=\(label) "
                + "dropped_foreign=\(terminal.box.droppedForeignFeeds)"
        )

        let expected = try! isolationMarker(owner: expectedOwner, token: token)
        XCTAssertTrue(transcript.contains(expected), "\(label) transcript: \(transcript)")
        for owner in ["W1", "W2", "P2b"] where owner != expectedOwner {
            let foreign = try! isolationMarker(owner: owner, token: token)
            XCTAssertFalse(
                transcript.contains(foreign),
                "\(label) contains foreign \(owner) marker: \(transcript)"
            )
        }

        let find = FindController()
        find.handlers = TerminalSearchAdapter.handlers(for: terminal.box)
        find.query = expected
        find.updateSearch()
        if requiresDeepHistory {
            XCTAssertGreaterThan(
                find.matchCount,
                terminal.surfaceState.rows,
                "\(label) FindController did not find history deeper than its viewport"
            )
        } else {
            XCTAssertGreaterThan(
                find.matchCount,
                0,
                "\(label) FindController did not find the visible painter marker"
            )
        }
        XCTAssertEqual(
            terminal.box.droppedForeignFeeds,
            0,
            "\(label) seam caught a planner bug despite a clean transcript"
        )
    }

    private func isolationMarker(owner: String, token: String) throws -> String {
        guard ["W1", "W2", "P2b"].contains(owner),
              !token.isEmpty,
              token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else {
            throw IntegrationError.failed("invalid isolation marker request")
        }
        return "TESSERA-\(owner)-\(token)"
    }

    private static func terminalRenderOwner(_ owner: RenderOwner) -> TerminalRenderOwner? {
        guard let windowID = owner.windowID, let paneID = owner.paneID else { return nil }
        return TerminalRenderOwner(windowId: windowID, paneId: paneID, epoch: owner.epoch)
    }

    /// C4/C5/W1/W3/W4: production adapters against both disposable tmux versions.
    /// External commands use a second SSH connection, never the controller's writer.
    @MainActor
    private func assertLiveWindowOrdering(
        controller: TmuxController,
        external: SSHSession
    ) async throws {
        try await waitUntil("ordering mutation admission", timeout: 10) { controller.canReorderWindows }
        let sessionID = try XCTUnwrap(controller.snapshot.sessionID).description
        func query(_ command: String) async throws -> [String] {
            try await withCheckedThrowingContinuation { continuation in
                controller.sendControlCommand(command) { continuation.resume(with: $0) }
            }
        }
        func create() async throws -> WindowId {
            let previousIDs = Set(controller.windows.map(\.id))
            controller.newWindow()
            try await waitUntil("appended window details", timeout: 12) {
                controller.windows.count == previousIDs.count + 1
                    && controller.windows.last?.index != nil
                    && !previousIDs.contains(controller.windows.last!.id)
            }
            return try XCTUnwrap(controller.windows.last?.id)
        }
        let gap = try await create()
        _ = try await create()
        controller.killWindow(gap)
        try await waitUntil("closed gap window", timeout: 10) {
            !controller.windows.contains { $0.id == gap }
        }
        let maximum = try XCTUnwrap(controller.windows.compactMap(\.index).max())
        let appended = try await create()
        XCTAssertGreaterThan(try XCTUnwrap(controller.windows.last?.index), maximum)
        XCTAssertEqual(controller.windows.last?.id, appended)
        let originalOrder = controller.windows.map(\.id)
        let originalActive = try XCTUnwrap(controller.activeWindowId)
        let topology = Dictionary(uniqueKeysWithValues: controller.windows.map {
            ($0.id, $0.panes.map(\.id))
        })
        controller.moveWindow(appended, to: 0)
        try await waitUntil("active window reordered and reconciled", timeout: 10) {
            !controller.isWindowReorderPending && controller.windows.first?.id == appended
        }
        XCTAssertEqual(controller.activeWindowId, originalActive)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: controller.windows.map {
            ($0.id, $0.panes.map(\.id))
        }), topology, "reordering recreated pane topology")
        let background = try XCTUnwrap(originalOrder.first)
        controller.moveWindow(background, to: controller.windows.count - 1)
        try await waitUntil("background reorder reconciled", timeout: 10) {
            !controller.isWindowReorderPending && controller.windows.last?.id == background
        }
        XCTAssertEqual(controller.activeWindowId, originalActive, "background drag selected a tab")
        let serverOrder = try await query("list-windows -F '#{window_id}'")
        XCTAssertEqual(serverOrder, controller.windows.map { $0.id.description })

        let last = try XCTUnwrap(controller.windows.last?.id)
        let first = try XCTUnwrap(controller.windows.first?.id)
        _ = try await external.executeConnectedCommand(
            "tmux move-window -d -b -s '\(sessionID):\(last)' -t '\(sessionID):\(first)'"
        )
        try await waitUntil("external move survives relink", timeout: 10) {
            controller.windows.first?.id == last && controller.windows.count == originalOrder.count
        }
        let swapA = controller.windows[1].id
        let swapB = controller.windows[2].id
        var swapped = controller.windows.map(\.id)
        swapped.swapAt(1, 2)
        _ = try await external.executeConnectedCommand(
            "tmux swap-window -s '\(sessionID):\(swapA)' -t '\(sessionID):\(swapB)'"
        )
        try await waitUntil("silent external swap subscription", timeout: 5) {
            controller.windows.map(\.id) == swapped
        }
        _ = try await external.executeConnectedCommand("tmux rename-window -t '\(sessionID):\(last)' external-ordered-name")
        try await waitUntil("external rename preserves order", timeout: 5) {
            controller.windows.first { $0.id == last }?.windowName == "external-ordered-name"
        }
        XCTAssertEqual(controller.windows.map(\.id), swapped)
        controller.renumberWindows()
        try await waitUntil("tidy completes", timeout: 10) { !controller.isWindowReorderPending }
        let rows = try await query("list-windows -F '#{window_index}'")
        let indices = rows.compactMap(Int.init)
        XCTAssertEqual(indices.count, controller.windows.count)
        XCTAssertTrue(zip(indices, indices.dropFirst()).allSatisfy { $1 == $0 + 1 })
        XCTAssertEqual(controller.windows.map(\.id), swapped)
        try await assertSameSessionOrderingPeers(controller: controller, external: external)
    }

    /// Two real app controllers on one session: simultaneous convergence,
    /// then a fresh attachment after the detached peer misses a host reorder.
    @MainActor
    private func assertSameSessionOrderingPeers(controller: TmuxController, external: SSHSession) async throws {
        let sessionID = try XCTUnwrap(controller.snapshot.sessionID).description
        for round in 0..<2 {
            let peer = SSHSession(host: external.host)
            let observer = TmuxController(controlPath: .inline)
            observer.updateClientSize(cols: 120, rows: 40)
            observer.sendBytes = { [weak peer] in peer?.send($0) }
            // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
            let pump = Task { @MainActor in
                for await bytes in peer.outputStream { await observer.ingestCooperatively(bytes) }
            }
            defer { pump.cancel(); peer.disconnect() }
            _ = try await connect(session: peer, pendingRequest: { peer.pendingHostKeyVerification }, timeout: 20)
            peer.send(Array("exec tmux -CC attach-session -t '\(sessionID)'\n".utf8))
            try await waitUntil("same-session peer hydration round \(round)", timeout: 15) {
                observer.isWindowListHydrated && observer.windows.map(\.id) == controller.windows.map(\.id)
            }
            let moving = try XCTUnwrap(controller.windows.last?.id)
            controller.moveWindow(moving, to: 0)
            try await waitUntil("two app controllers converge", timeout: 12) {
                !controller.isWindowReorderPending && controller.windows.first?.id == moving &&
                    observer.windows.map(\.id) == controller.windows.map(\.id)
            }
            XCTAssertEqual(observer.windows.map(\.index), controller.windows.map(\.index))
            peer.disconnect()
            pump.cancel()
            if round == 0 {
                let order = controller.windows.map(\.id)
                _ = try await external.executeConnectedCommand("tmux swap-window -d -s '\(sessionID):\(order[0])' -t '\(sessionID):\(order[1])'")
                try await waitUntil("host reorder while peer detached", timeout: 5) { controller.windows.first?.id == order[1] }
            }
        }
    }

    @MainActor
    private func assertInlineTmuxHydration(
        config: Config,
        useChaosHost: Bool
    ) async throws {
        let host = makeHost(
            config: config,
            transport: .ssh,
            useChaosHost: useChaosHost
        )
        let sessionName = "tessera-inline-\(UUID().uuidString.prefix(10).lowercased())"
        let setupMarker = "TESSERA_TMUX_SETUP_\(UUID().uuidString.prefix(8))"
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )
        setup.send(Array(
            ("tmux new-session -d -s \(sessionName) -n shell; "
                + "tmux new-window -d -t \(sessionName) -n editor; "
                + "tmux select-window -t \(sessionName):shell; "
                + "\(unechoedPrintf(setupMarker))\n").utf8
        ))
        _ = try await waitForOutput(setup.outputStream, containing: setupMarker, timeout: 10)

        let inline = SSHSession(host: host)
        let controller = TmuxController(controlPath: .inline)
        controller.updateClientSize(cols: 120, rows: 40)
        controller.sendBytes = { [weak inline] bytes in inline?.send(bytes) }
        // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
        let pump = Task { @MainActor in
            for await bytes in inline.outputStream {
                await controller.ingestCooperatively(bytes)
            }
        }
        defer {
            pump.cancel()
            inline.disconnect()
        }
        _ = try await connect(
            session: inline,
            pendingRequest: { inline.pendingHostKeyVerification },
            timeout: 20
        )
        inline.send(Array("exec tmux -CC attach -t \(sessionName)\n".utf8))

        try await waitUntil("inline tmux hydration", timeout: 15) {
            controller.mode == .tmuxControl
                && Set(controller.windows.compactMap(\.windowName))
                    .isSuperset(of: ["shell", "editor"])
                && controller.activeWindowId != nil
        }
        XCTAssertEqual(controller.windows.count, 2)

        let agentPaneID = try XCTUnwrap(
            controller.renderedPaneId ?? controller.activePaneId,
            "hydrated inline tmux controller must expose an active pane"
        )
        let agentCapture = await AgentSessionSourceFactory.capturePane(
            paneID: agentPaneID
        ) { command in
            await withCheckedContinuation { continuation in
                controller.sendControlCommand(command) { result in
                    continuation.resume(returning: result)
                }
            }
        }
        XCTAssertNotNil(
            agentCapture,
            "Agent Center cursor and capture queries must survive real -CC reply framing"
        )

        // This command also proves the two Agent Center replies drained in
        // FIFO order instead of leaving the controller one response out of
        // phase, which was the physical-iPad disappearance regression.
        controller.sendControlCommand("rename-window -t \(sessionName):shell locked-name")
        try await waitUntil("inline tmux rename", timeout: 8) {
            controller.windows.contains { $0.windowName == "locked-name" }
        }

        try await assertLiveWindowOrdering(controller: controller, external: setup)

        let cleanupMarker = "TESSERA_TMUX_CLEAN_\(UUID().uuidString.prefix(8))"
        setup.send(Array(
            ("tmux kill-session -t \(sessionName); \(unechoedPrintf(cleanupMarker))\n").utf8
        ))
        _ = try await waitForOutput(setup.outputStream, containing: cleanupMarker, timeout: 10)
    }

    @MainActor
    private func assertSideChannelTmuxIsolation(
        config: Config,
        useChaosHost: Bool,
        localPortOffset: Int
    ) async throws {
        let host = makeHost(
            config: config,
            transport: .mosh,
            useChaosHost: useChaosHost
        )
        let prefix = try runOwnedTmuxSessionName("side", token: String(UUID().uuidString.prefix(8).lowercased()))
        let sessionA = "\(prefix)-a"
        let sessionB = "\(prefix)-b"
        let viewA = AutoTmuxCommands.moshViewSessionName(for: sessionA)
        let viewB = AutoTmuxCommands.moshViewSessionName(for: sessionB)
        let cleanupCommand = [viewA, viewB, sessionA, sessionB]
            .map { "tmux kill-session -t '\($0)' >/dev/null 2>&1 || true" }
            .joined(separator: "; ")
        let setupMarker = "TESSERA_SIDE_SETUP_\(UUID().uuidString.prefix(8))"
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )
        do {
            setup.send(Array(
                ("tmux new-session -d -s \(sessionA) -n a-shell; "
                    + "tmux new-window -d -t \(sessionA) -n a-editor; "
                    + "tmux select-window -t \(sessionA):a-shell; "
                    + "tmux new-session -d -s \(sessionB) -n b-shell; "
                    + "tmux new-window -d -t \(sessionB) -n b-editor; "
                    + "tmux select-window -t \(sessionB):b-shell; "
                    // Production's visible mosh client creates these grouped
                    // views. The attach-only control channel must never create
                    // them itself; this control-only fixture supplies them.
                    + "tmux new-session -d -s \(viewA) -t \(sessionA); "
                    + "tmux new-session -d -s \(viewB) -t \(sessionB); "
                    + "\(unechoedPrintf(setupMarker))\n").utf8
            ))
            _ = try await waitForOutput(setup.outputStream, containing: setupMarker, timeout: 10)

            let localPort = try XCTUnwrap(UInt16(exactly: config.localForwardPort + localPortOffset))
            let rule = PortForwardRule.localForward(
                localPort: localPort,
                remoteHost: "127.0.0.1",
                remotePort: UInt16(config.echoPort),
                label: "mosh-sidechannel-http"
            )
            let manager = PortForwarderManager()
            let controllerA = TmuxController(controlPath: .sideChannel)
            let controllerB = TmuxController(controlPath: .sideChannel)
            let channelA = TmuxControlChannel(
                host: host,
                sessionName: sessionA,
                initialSize: (120, 40),
                portForwarderManager: manager,
                portForwardRules: [rule]
            )
            let channelB = TmuxControlChannel(
                host: host,
                sessionName: sessionB,
                initialSize: (120, 40)
            )
            controllerA.sendBytes = { [weak channelA] bytes in channelA?.send(bytes) }
            controllerB.sendBytes = { [weak channelB] bytes in channelB?.send(bytes) }
            // Synchronous on purpose: production's side-channel loop also calls `ingest` (SessionView).
            let pumpA = Task { @MainActor in
                for await bytes in channelA.outputStream { controllerA.ingest(bytes) }
            }
            let pumpB = Task { @MainActor in
                for await bytes in channelB.outputStream { controllerB.ingest(bytes) }
            }
            defer {
                pumpA.cancel()
                pumpB.cancel()
                channelA.disconnect()
                channelB.disconnect()
            }
            channelA.connect()
            channelB.connect()

            try await waitUntil("side-channel tmux hydration", timeout: 15) {
                controllerA.mode == .tmuxControl
                    && controllerB.mode == .tmuxControl
                    && controllerA.windows.count == 2
                    && controllerB.windows.count == 2
                    && controllerA.activeWindowId != nil
                    && controllerB.activeWindowId != nil
            }
            let activeA = controllerA.activeWindowId
            let activeB = controllerB.activeWindowId
            controllerB.nextWindow()
            try await waitUntil("side-channel session B switch", timeout: 8) {
                controllerB.activeWindowId != activeB
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(
                controllerA.activeWindowId,
                activeA,
                "session B's broadcast tmux notification changed session A"
            )

            try await waitUntil("mosh side-channel forwarder listening", timeout: 8) {
                manager.runningCount == 1
            }
            // Before any real connection: only the probe over the side
            // channel can have answered this.
            manager.probeServicesNow()
            try await waitUntil("mosh side-channel service probe", timeout: 10) {
                manager.forwarders[rule.id]?.service == .serving
            }
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(localPort)/probe"))
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "TESSERA_FORWARD_OK\n")
            try await waitUntil("mosh side-channel byte accounting", timeout: 5) {
                guard let forwarder = manager.forwarders[rule.id] else { return false }
                return forwarder.bytesUp > 0 && forwarder.bytesDown >= data.count
            }

            try await assertLiveWindowOrdering(controller: controllerA, external: setup)
            XCTAssertEqual(controllerB.windows.count, 2, "ordering crossed session boundaries")

            _ = try await setup.executeConnectedCommand(cleanupCommand)
        } catch {
            _ = try? await setup.executeConnectedCommand(cleanupCommand)
            throw error
        }
    }

    private final class ProgramStatusTextLog {
        var text = ""

        /// The hex a `psprobe` printed after `PSREPLY_<name>_`, once its line
        /// ended. Scalars, not Characters: "\r\n" is a single Character, so a
        /// Character search never sees the "\r" that ends an empty reply.
        func probeReply(_ name: String) -> String? {
            let scalars = Array(text.unicodeScalars)
            let marker = Array("PSREPLY_\(name)_".unicodeScalars)
            guard scalars.count >= marker.count else { return nil }
            for start in 0...(scalars.count - marker.count)
            where scalars[start..<start + marker.count].elementsEqual(marker) {
                let rest = scalars[(start + marker.count)...]
                guard let end = rest.firstIndex(where: { $0 == "\r" || $0 == "\n" }) else { return nil }
                var reply = String.UnicodeScalarView()
                reply.append(contentsOf: rest[..<end])
                return String(reply)
            }
            return nil
        }
    }

    @MainActor
    private func assertRawSSHProgramStatus(config: Config) async throws {
        let session = SSHSession(host: makeHost(config: config, transport: .ssh))
        let controller = TmuxController(controlPath: .inline)
        controller.programStatusEnabled = true
        controller.sendBytes = { [weak session] bytes in session?.send(bytes) }
        let log = ProgramStatusTextLog()
        // Production's raw SSH output reaches the terminal through this
        // controller's passthrough, which answers the query first.
        let pump = Task { @MainActor in
            for await bytes in session.outputStream {
                log.text += String(decoding: bytes, as: UTF8.self)
                await controller.ingestCooperatively(bytes)
            }
        }
        defer {
            pump.cancel()
            session.disconnect()
        }
        _ = try await connect(
            session: session,
            pendingRequest: { session.pendingHostKeyVerification },
            timeout: 20
        )
        // Sends the query with echo off and reads at most one reply for up
        // to three seconds, then prints what arrived as hex.
        let probe = #"psprobe() { stty -echo -icanon min 0 time 30; printf '\033]7501;?\033\\'; r=$(dd bs=1 count=10 2>/dev/null | od -An -tx1 | tr -d ' \n'); stty sane; printf 'PSREPLY_%s_%s\n' "$1" "$r"; }"#
        session.send(Array((probe + "\npsprobe on\n").utf8))
        try await waitUntil("raw SSH program status query reply", timeout: 15) {
            log.probeReply("on") != nil
        }
        XCTAssertEqual(log.probeReply("on"), "1b5d373530313b3f1b5c", "the reply is exactly OSC 7501 ; ? ST")

        session.send(Array((#"printf '\033]7501;state=blocked:kind=question:app=deploy\007'"# + "\n").utf8))
        try await waitUntil("raw SSH blocked report", timeout: 10) {
            controller.programStatus.terminal(.raw)?.attention == .needsInput(.question)
        }
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.primaryEntry?.app, "deploy")

        session.send(Array((#"printf '\033]7501;state=done\007'"# + "\n").utf8))
        try await waitUntil("raw SSH done report", timeout: 10) {
            controller.programStatus.terminal(.raw)?.attention == .finished
        }
        let token = try XCTUnwrap(controller.programStatus.terminal(.raw)?.latestUnreadResultToken)
        controller.acknowledgeProgramStatus(terminal: .raw, through: token)
        XCTAssertNil(controller.programStatus.terminal(.raw)?.attention, "a checked result stops asking")

        // The Terminal setting gates everything, the query reply included.
        controller.programStatusEnabled = false
        XCTAssertTrue(controller.programStatus.terminals.isEmpty, "turning program status off discards records")
        session.send(Array("psprobe off\n".utf8))
        try await waitUntil("raw SSH probe without a reply", timeout: 15) {
            log.probeReply("off") != nil
        }
        XCTAssertEqual(log.probeReply("off"), "", "a disabled monitor must not answer the query")
    }

    @MainActor
    private func assertTmuxProgramStatus(
        config: Config,
        useChaosHost: Bool,
        sideChannel: Bool
    ) async throws {
        let label = "\(sideChannel ? "mosh+tmux side channel" : "SSH+tmux inline") \(useChaosHost ? "chaos" : "stable")"
        let token = String(UUID().uuidString.prefix(8).lowercased())
        let sessionName = try runOwnedTmuxSessionName(sideChannel ? "psside" : "psinline", token: token)
        let viewName = AutoTmuxCommands.moshViewSessionName(for: sessionName)
        let cleanupCommand = [viewName, sessionName]
            .map { "tmux kill-session -t '\($0)' >/dev/null 2>&1 || true" }
            .joined(separator: "; ")
        let setup = SSHSession(host: makeHost(config: config, transport: .ssh, useChaosHost: useChaosHost))
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )
        func report(_ window: String, _ fields: String) -> String {
            let target = "'\(sessionName):\(window)'"
            return "tmux send-keys -t \(target) -l 'printf \"\\033]7501;\(fields)\\007\"'; tmux send-keys -t \(target) Enter"
        }
        do {
            let setupMarker = "TESSERA_PS_SETUP_\(UUID().uuidString.prefix(8))"
            var commands = "tmux new-session -d -s '\(sessionName)' -n build; "
                + "tmux new-window -d -t '\(sessionName)' -n deploy; "
                + "tmux select-window -t '\(sessionName):build'; "
            // Production's visible mosh client creates the grouped view; the
            // control-only fixture supplies it, as the isolation lane does.
            if sideChannel { commands += "tmux new-session -d -s '\(viewName)' -t '\(sessionName)'; " }
            setup.send(Array((commands + unechoedPrintf(setupMarker) + "\n").utf8))
            _ = try await waitForOutput(setup.outputStream, containing: setupMarker, timeout: 10)

            let host = makeHost(config: config, transport: sideChannel ? .mosh : .ssh, useChaosHost: useChaosHost)
            let controller = TmuxController(controlPath: sideChannel ? .sideChannel : .inline)
            controller.programStatusEnabled = true
            controller.updateClientSize(cols: 120, rows: 40)
            let inline = sideChannel ? nil : SSHSession(host: host)
            let channel = sideChannel
                ? TmuxControlChannel(host: host, sessionName: sessionName, initialSize: (120, 40))
                : nil
            if let inline { controller.sendBytes = { [weak inline] bytes in inline?.send(bytes) } }
            if let channel { controller.sendBytes = { [weak channel] bytes in channel?.send(bytes) } }
            // Each path ingests the way SessionView does.
            let pump = Task { @MainActor in
                if let inline {
                    for await bytes in inline.outputStream { await controller.ingestCooperatively(bytes) }
                }
                if let channel {
                    for await bytes in channel.outputStream { controller.ingest(bytes) }
                }
            }
            defer {
                pump.cancel()
                inline?.disconnect()
                channel?.disconnect()
            }
            if let inline {
                _ = try await connect(
                    session: inline,
                    pendingRequest: { inline.pendingHostKeyVerification },
                    timeout: 20
                )
                inline.send(Array("exec tmux -CC attach -t '\(sessionName)'\n".utf8))
            }
            channel?.connect()
            func paneID(_ name: String) -> PaneId? {
                controller.windows.first { $0.windowName == name }.flatMap { $0.activePaneId ?? $0.panes.first?.id }
            }
            try await waitUntil("\(label) hydration", timeout: 15) {
                controller.mode == .tmuxControl && paneID("build") != nil && paneID("deploy") != nil
            }
            let build = try XCTUnwrap(paneID("build"))
            let deploy = try XCTUnwrap(paneID("deploy"))

            setup.send(Array((report("build", "state=error:app=cargo") + "; "
                + report("deploy", "state=blocked:kind=permission:app=deploy") + "\n").utf8))
            try await waitUntil("\(label) pane reports", timeout: 10) {
                controller.programStatus.terminal(.pane(build))?.attention == .failed
                    && controller.programStatus.terminal(.pane(deploy))?.attention == .needsInput(.permission)
            }
            XCTAssertNil(controller.programStatus.terminal(.raw), "\(label): tmux's own output is not a raw terminal")

            let result = try XCTUnwrap(controller.programStatus.terminal(.pane(build))?.latestUnreadResultToken)
            controller.acknowledgeProgramStatus(terminal: .pane(build), through: result)
            XCTAssertNil(controller.programStatus.terminal(.pane(build))?.attention, "\(label): checked result")
            controller.acknowledgeProgramStatus(terminal: .pane(deploy), through: .max)
            XCTAssertEqual(
                controller.programStatus.terminal(.pane(deploy))?.attention,
                .needsInput(.permission),
                "\(label): a blocked program is never acknowledged"
            )

            // A closed pane takes its records with it.
            setup.send(Array("tmux kill-window -t '\(sessionName):deploy'\n".utf8))
            try await waitUntil("\(label) closed pane drops its record", timeout: 10) {
                controller.programStatus.terminal(.pane(deploy)) == nil
            }

            // Off ignores reports; on starts empty and reads new ones.
            controller.programStatusEnabled = false
            XCTAssertTrue(controller.programStatus.terminals.isEmpty, "\(label): off discards records")
            setup.send(Array((report("build", "state=error:app=ignored") + "\n").utf8))
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertTrue(controller.programStatus.terminals.isEmpty, "\(label): reports while off are ignored")
            controller.programStatusEnabled = true
            XCTAssertTrue(controller.programStatus.terminals.isEmpty, "\(label): on starts empty")
            setup.send(Array((report("build", "state=done:app=make") + "\n").utf8))
            try await waitUntil("\(label) report after re-enabling", timeout: 10) {
                controller.programStatus.terminal(.pane(build))?.attention == .finished
            }

            _ = try await setup.executeConnectedCommand(cleanupCommand)
        } catch {
            _ = try? await setup.executeConnectedCommand(cleanupCommand)
            throw error
        }
    }

    /// Connect before the first positive viewport measurement, then take back
    /// an actual peer's grid through the same inline owner-bound ingress.
    @MainActor
    private func assertInlineTmuxLateMeasuredViewport(config: Config) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TESSERA_REAL_HOST_TMUX_ISOLATION_GATE"] == "1",
              let sessionName = environment["TESSERA_REAL_HOST_TMUX_INLINE_SESSION"],
              sessionName.hasPrefix("tessera-ios-inline-"), sessionName.count <= 80,
              sessionName.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            throw XCTSkip("late viewport requires the run-owned inline fixture")
        }
        let host = makeHost(config: config, transport: .ssh)
        await resetConnectionState(endpoint: "\(host.address):\(host.port)")
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(session: setup, pendingRequest: { setup.pendingHostKeyVerification }, timeout: 20)
        let token = UUID().uuidString.prefix(8).lowercased()
        let identity = TmuxController.GridAuthorityIdentity(id: "late-ipad-\(token)", displayName: "iPad")
        let peerIdentity = TmuxController.GridAuthorityIdentity(id: "late-peer-\(token)", displayName: "Peer")
        let session = SSHSession(host: host)
        let peerSession = SSHSession(host: host)
        let controller = TmuxController(controlPath: .inline, clientSizePolicy: .resizeTmux)
        let peer = TmuxController(controlPath: .inline, clientSizePolicy: .resizeTmux)
        let terminal = TmuxIsolationTerminal(label: "late-measured-inline")
        let peerTerminal = TmuxIsolationTerminal(label: "late-measured-peer", columns: 56, rows: 24)
        controller.gridAuthorityIdentity = identity
        peer.gridAuthorityIdentity = peerIdentity
        peerSession.resize(cols: 56, rows: 24)
        peer.updateClientSize(cols: 56, rows: 24)
        installInlineTerminalSurface(peer, terminal: peerTerminal)
        var forwardedMeasuredViewport = false
        var measured: TmuxGeometry?
        var ownedFeedCount = 0
        var lastFeedOwner: TerminalRenderOwner?
        var targetWire: [String] = []
        controller.displayWillSwapWithContext = { [box = terminal.box] _, context, _ in
            guard let owner = TerminalRenderOwner(feedContext: context) else { return }
            box.bind(owner: owner, restoringScrollbackLimit: 2_000)
        }
        controller.feedTerminalWithContext = { [box = terminal.box] bytes, context in
            guard let owner = TerminalRenderOwner(feedContext: context) else { return }
            if box.boundOwner == nil { box.bind(owner: owner, restoringScrollbackLimit: 2_000) }
            box.feed(owner: owner, bytes)
            if box.boundOwner == owner, box.painterFeedsAdmitted, forwardedMeasuredViewport {
                ownedFeedCount += 1
                lastFeedOwner = owner
            }
        }
        controller.terminalIsInAltScreen = { terminal.view.getTerminal().isCurrentBufferAlternate }
        controller.sendBytes = { [weak session] bytes in
            targetWire.append(String(decoding: bytes, as: UTF8.self))
            session?.send(bytes)
        }
        var peerWire: [String] = []
        peer.sendBytes = { [weak peerSession] bytes in
            peerWire.append(String(decoding: bytes, as: UTF8.self))
            peerSession?.send(bytes)
        }
        // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
        let pump = Task { @MainActor in
            for await bytes in session.outputStream { await controller.ingestCooperatively(bytes) }
        }
        // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
        let peerPump = Task { @MainActor in
            for await bytes in peerSession.outputStream { await peer.ingestCooperatively(bytes) }
        }
        defer { pump.cancel(); peerPump.cancel(); session.disconnect(); peerSession.disconnect() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let viewHost = TmuxLandscapeFixtureViewController()
        viewHost.view.backgroundColor = .black
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = viewHost
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        var geometryRequestError: String?
        viewHost.setNeedsUpdateOfSupportedInterfaceOrientations()
        await Task.yield()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft), errorHandler: { error in
            geometryRequestError = String(describing: error)
            NSLog("[LateViewport] landscape request failed %@", String(describing: error))
        })
        // iPadOS 26 refuses a scene's orientation request in every windowing
        // mode (UISceneErrorDomain 101, Full Screen Apps included), so a
        // portrait-booted device keeps a portrait scene. The claim only needs
        // a landscape-shaped measured viewport, so the test-owned window then
        // takes a 4:3 landscape frame inside the portrait scene instead.
        func landscapeFrame() -> CGRect {
            let bounds = scene.coordinateSpace.bounds
            guard bounds.height > bounds.width, geometryRequestError != nil else { return bounds }
            return CGRect(x: 0, y: 0, width: bounds.width, height: (bounds.width * 3 / 4).rounded(.down))
        }
        do {
            try await waitUntil("late viewport disposable iPad landscape", timeout: 5) {
                window.frame = landscapeFrame()
                window.setNeedsLayout()
                window.layoutIfNeeded()
                viewHost.view.setNeedsLayout()
                viewHost.view.layoutIfNeeded()
                let sceneReady = scene.interfaceOrientation.isLandscape || geometryRequestError != nil
                return sceneReady && viewHost.view.bounds.width > viewHost.view.bounds.height
            }
        } catch {
            let facts = "sceneOrientation=\(scene.interfaceOrientation.rawValue) sceneBounds=\(scene.coordinateSpace.bounds) "
                + "windowBounds=\(window.bounds) rootBounds=\(viewHost.view.bounds) "
                + "windowVisible=\(!window.isHidden) geometryRequestError=\(geometryRequestError ?? "none")"
            NSLog("[LateViewport] landscape readiness failed %@", facts)
            let diagnostic = XCTAttachment(string: facts)
            diagnostic.name = "inline-late-viewport-landscape-readiness-failure"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
            throw error
        }

        func attachState(_ label: String) {
            let view = terminal.view
            view.layer.setNeedsDisplay()
            view.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
                view.layer.render(in: context.cgContext)
            }
            let frame = XCTAttachment(image: image)
            frame.name = "inline-late-viewport-\(label)-native-CoreGraphics"
            frame.lifetime = .keepAlways
            add(frame)
            let mounted = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                window.layer.render(in: context.cgContext)
            })
            mounted.name = "inline-late-viewport-\(label)-test-owned-UIWindow"
            mounted.lifetime = .keepAlways
            add(mounted)
            let facts = XCTAttachment(string: "phase=\(label) authority=\(controller.gridAuthority) reclaimInFlight=\(controller.gridAuthorityReclaimInFlight) "
                + "viewportForwarded=\(forwardedMeasuredViewport) measured=\(String(describing: measured)) "
                + "native=\(terminal.surfaceState.columns)x\(terminal.surfaceState.rows) owner=\(String(describing: terminal.box.boundOwner)) "
                + "ownedFeeds=\(ownedFeedCount) lastFeedOwner=\(String(describing: lastFeedOwner)) "
                + "windowVisible=\(!window.isHidden) terminalMounted=\(view.window === window) "
                + "windowBounds=\(window.bounds) viewBounds=\(view.bounds) contentOffset=\(view.contentOffset) "
                + "landscape=\(view.bounds.width > view.bounds.height) sceneLandscape=\(scene.interfaceOrientation.isLandscape) "
                + "geometryRequestError=\(geometryRequestError ?? "none")\n\(terminal.transcript)")
            facts.name = "inline-late-viewport-\(label)-state"
            facts.lifetime = .keepAlways
            add(facts)
            NSLog("TESSERA_LATE_VIEWPORT_STAGE %@ token=%@ reclaim=%@ mounted=%@", label, token,
                String(controller.gridAuthorityReclaimInFlight), String(view.window === window))
        }
        func stamp() async throws -> TmuxGridAuthorityStamp? {
            let ownSessionID = try XCTUnwrap(controller.ownSessionId)
            let value = try await setup.executeConnectedCommand(
                "tmux show-options -qv -t '\(ownSessionID.description)' \(TmuxController.gridAuthorityOption)"
            )
            return TmuxGridAuthorityStamp.parse(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let cleanup = "tmux kill-session -t '=\(sessionName)' >/dev/null 2>&1 || true"
        do {
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -x 80 -y 24 -s '\(sessionName)'; "
                    + "tmux set-option -t '\(sessionName)' status off; "
                    + "tmux set-window-option -t '\(sessionName)' window-size latest"
            )
            _ = try await connect(session: session, pendingRequest: { session.pendingHostKeyVerification }, timeout: 20)
            session.send(Array("exec tmux -CC attach -t '=\(sessionName)'\n".utf8))
            try await waitForTmuxHydration(controller, operation: "inline attach before measured viewport")
            let windowID = try XCTUnwrap(controller.activeWindowId)
            let paneID = try XCTUnwrap(controller.activePaneId)
            XCTAssertFalse(targetWire.contains { $0.contains("refresh-client -C ") }, "nil viewport issued requested geometry")
            try await waitForTmuxGeometry(TmuxGeometry(cols: 80, rows: 24), sessionName: sessionName,
                using: setup, operation: "unmeasured initial SSH grid", timeout: 3)
            // This controller stands for a displayed tab whose show already
            // resolved: adopt that visibility without a gesture (a hidden
            // session draws no veil and admits no tap).
            controller.gridAuthorityAdoptShown()

            _ = try await connect(session: peerSession, pendingRequest: { peerSession.pendingHostKeyVerification }, timeout: 20)
            peerSession.send(Array("exec tmux -CC attach -t '=\(sessionName)'\n".utf8))
            try await waitForTmuxHydration(peer, operation: "real peer baseline hydration")
            XCTAssertEqual(peer.ownSessionId, controller.ownSessionId, "peer attached another fixture session")
            // S2': the peer's attach alone never claims or sizes the window.
            try await waitForControlFence(peer, operation: "real peer attach read")
            XCTAssertNotEqual(peer.gridAuthority, .mine, "attach claimed without a show")
            XCTAssertFalse(peer.gridAuthorityReclaimInFlight, "attach started a claim without a show")
            // The fixture session carries no stamp, so the attach read
            // releases ordinary geometry as a bare `refresh-client -C` (M3):
            // under `latest` tmux may follow it, so the window size proves
            // nothing here. Only a stamp, a latest fence or a claim would
            // mean the attach took control.
            let attachStamp = try await stamp()
            XCTAssertNil(attachStamp, "attach wrote an authority stamp without a show")
            let peerAttachLines = peerWire.flatMap { $0.split(separator: "\n").map(String.init) }
            XCTAssertFalse(peerAttachLines.contains {
                $0.hasPrefix("set-option") && $0.contains(TmuxController.gridAuthorityOption)
            }, "attach wrote the authority option without a show")
            XCTAssertFalse(peerAttachLines.contains { $0.hasPrefix("select-window") || $0.hasPrefix("resize-window") },
                "attach fenced or forced the window without a show")
            // Displaying the session on the peer is the show that takes control.
            peer.gridAuthorityShown()
            try await waitUntil("real peer show claims before first viewport", timeout: 3) {
                peer.gridAuthority == .mine && !peer.gridAuthorityReclaimInFlight
            }
            try await waitForTmuxGeometry(TmuxGeometry(cols: 56, rows: 24), sessionName: sessionName,
                using: setup, operation: "real peer's grid", timeout: 3)
            let recordedPeerStamp = try await stamp()
            let peerStamp = try XCTUnwrap(recordedPeerStamp)
            XCTAssertEqual(peerStamp.deviceID, peerIdentity.id)
            try await waitUntil("unmeasured controller observes peer baseline", timeout: 3) {
                controller.gridAuthority == .peer(displayName: peerIdentity.displayName)
            }
            XCTAssertTrue(controller.reclaimGridAuthority(reason: "late-viewport-fixture"))
            XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
            XCTAssertFalse(targetWire.contains { $0.contains("refresh-client -C ") }, "take-back invented geometry before measurement")
            let beforeMeasurement = try await stamp()
            XCTAssertEqual(beforeMeasurement, peerStamp, "unmeasured take-back stole the peer stamp")
            attachState("before-measurement")
            // Give the external owned-simulator video/screenshot collector a
            // stable before-state; this never changes protocol/geometry facts.
            try await Task.sleep(nanoseconds: 750_000_000)

            terminal.view.frame = viewHost.view.bounds
            terminal.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            viewHost.view.addSubview(terminal.view)
            viewHost.view.setNeedsLayout()
            viewHost.view.layoutIfNeeded()
            terminal.view.layoutIfNeeded()
            XCTAssertTrue(terminal.view.window === window)
            let native = terminal.view.getTerminal()
            let geometry = TmuxGeometry(cols: native.cols, rows: native.rows)
            XCTAssertGreaterThan(geometry.cols, 56)
            XCTAssertGreaterThan(geometry.rows, 24)
            measured = geometry
            let feedFloor = ownedFeedCount
            forwardedMeasuredViewport = true
            session.resize(cols: geometry.cols, rows: geometry.rows)
            controller.updateClientSize(cols: geometry.cols, rows: geometry.rows)
            try await waitUntil("late viewport claim settles with actual owned inline frame", timeout: 3) {
                controller.gridAuthority == .mine && !controller.gridAuthorityReclaimInFlight
                    && ownedFeedCount > feedFloor && lastFeedOwner == terminal.box.boundOwner
                    && peer.gridAuthority == .peer(displayName: identity.displayName)
            }
            try await waitForTmuxGeometry(geometry, sessionName: sessionName, using: setup,
                operation: "late measured viewport exact remote grid", timeout: 3)
            XCTAssertEqual(controller.activeWindowId, windowID)
            XCTAssertEqual(controller.activePaneId, paneID)
            XCTAssertEqual(terminal.box.boundOwner?.windowId, windowID)
            XCTAssertEqual(terminal.box.boundOwner?.paneId, paneID)
            XCTAssertEqual(terminal.surfaceState.columns, geometry.cols)
            XCTAssertEqual(terminal.surfaceState.rows, geometry.rows)
            let recordedLocalStamp = try await stamp()
            let localStamp = try XCTUnwrap(recordedLocalStamp)
            XCTAssertEqual(localStamp.deviceID, identity.id)
            let marker = "LATE-VIEWPORT-\(token)"
            terminal.box.noteOutOfBandInput()
            controller.sendInput(Array((unechoedPrintf(marker) + "\r").utf8))
            try await waitUntil("late viewport fresh input rendered", timeout: 3) { terminal.transcript.contains(marker) }
            await Task.yield()
            attachState("settled")
            let success = XCTAttachment(string: "TESSERA_IOS_INLINE_LATE_VIEWPORT_OK beforeSizeNil=1 realPeer=1 takebackBeforeSize=1 measuredOnce=1 mountedWindow=1 landscape=1 sceneRotated=\(scene.interfaceOrientation.isLandscape ? 1 : 0) exactRemoteNativeGrid=1 sameWindowPane=1 ownedInlineFrame=1 freshInput=1 reclaimSpinnerSettled=1 columns=\(geometry.cols) rows=\(geometry.rows)")
            success.name = "inline-late-viewport-success"
            success.lifetime = .keepAlways
            add(success)
            try await Task.sleep(nanoseconds: 750_000_000)
            _ = try await setup.executeConnectedCommand(cleanup)
        } catch {
            attachState("failure")
            NSLog("[LateViewport] failure %@", String(describing: error))
            if let data = DiagnosticLogStore.attachmentData() {
                let diagnostic = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
                diagnostic.name = "inline-late-viewport-failure-diagnostics"
                diagnostic.lifetime = .keepAlways
                add(diagnostic)
            }
            _ = try? await setup.executeConnectedCommand(cleanup)
            throw error
        }
    }

    /// Live acceptance for the cross-device viewport handoff on SSH+tmux.
    /// A phone must resize an existing large session to its physical viewport;
    /// a later iPad client on the same session must expand it again.
    @MainActor
    private func assertInlineTmuxViewportHandoff(config: Config) async throws {
        let host = makeHost(config: config, transport: .ssh)
        await resetConnectionState(endpoint: "\(host.address):\(host.port)")
        let setup = SSHSession(host: host)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )

        let sessionName = "tessera-viewport-ssh-\(UUID().uuidString.prefix(8).lowercased())"
        do {
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -x 160 -y 50 -s \(sessionName); "
                    + "tmux set-option -t \(sessionName) status off"
            )
            let initialGeometry = try await tmuxGeometry(
                sessionName: sessionName,
                using: setup
            )
            XCTAssertEqual(initialGeometry, TmuxGeometry(cols: 160, rows: 50))

            let phone = SSHSession(host: host)
            let phoneController = TmuxController(
                controlPath: .inline,
                clientSizePolicy: .resizeTmux
            )
            phone.resize(cols: 50, rows: 20)
            phoneController.updateClientSize(cols: 50, rows: 20)
            var phoneOutput = ""
            phoneController.feedTerminal = { bytes in
                phoneOutput += String(decoding: bytes, as: UTF8.self)
            }
            phoneController.sendBytes = { [weak phone] bytes in phone?.send(bytes) }
            // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
            let phonePump = Task { @MainActor in
                for await bytes in phone.outputStream {
                    await phoneController.ingestCooperatively(bytes)
                }
            }
            defer {
                phonePump.cancel()
                phone.disconnect()
            }
            _ = try await connect(
                session: phone,
                pendingRequest: { phone.pendingHostKeyVerification },
                timeout: 20
            )
            phone.send(Array("exec tmux -CC attach -t \(sessionName)\n".utf8))
            try await waitForTmuxHydration(
                phoneController,
                operation: "phone inline viewport hydration"
            )
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 20),
                sessionName: sessionName,
                using: setup,
                operation: "phone inline attach geometry"
            )

            phone.resize(cols: 50, rows: 12)
            phoneController.updateClientSize(cols: 50, rows: 12)
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 12),
                sessionName: sessionName,
                using: setup,
                operation: "phone inline keyboard geometry"
            )
            phone.resize(cols: 50, rows: 20)
            phoneController.updateClientSize(cols: 50, rows: 20)
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 20),
                sessionName: sessionName,
                using: setup,
                operation: "phone inline restored geometry"
            )

            var continuedHost = host
            continuedHost.launchMode = .pinnedTmux
            continuedHost.tmuxSessionName = sessionName
            let pairing = try await beginLiveQRContinuation(host: continuedHost)
            defer { pairing.origin.cancel(); pairing.recipient.cancel() }
            let ipad = SSHSession(host: host)
            let ipadController = TmuxController(
                controlPath: .inline,
                clientSizePolicy: .resizeTmux
            )
            ipad.resize(cols: 132, rows: 44)
            ipadController.updateClientSize(cols: 132, rows: 44)
            ipadController.feedTerminal = { _ in }
            ipadController.sendBytes = { [weak ipad] bytes in ipad?.send(bytes) }
            // Production's inline SSH loop ingests cooperatively (SessionView); prove that path.
            let ipadPump = Task { @MainActor in
                for await bytes in ipad.outputStream {
                    await ipadController.ingestCooperatively(bytes)
                }
            }
            defer {
                ipadPump.cancel()
                ipad.disconnect()
            }
            _ = try await connect(
                session: ipad,
                pendingRequest: { ipad.pendingHostKeyVerification },
                timeout: 20
            )
            ipad.send(Array("exec tmux -CC attach -t \(sessionName)\n".utf8))
            try await waitForTmuxHydration(
                ipadController,
                operation: "iPad inline viewport hydration"
            )
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 132, rows: 44),
                sessionName: sessionName,
                using: setup,
                operation: "iPad inline attach geometry"
            )
            try await completeLiveQRContinuation(pairing)

            let marker = "TESSERA_SSH_TMUX_VIEWPORT_\(UUID().uuidString.prefix(8))"
            phoneController.sendInput(Array("printf '\(marker)\\n'\r".utf8))
            try await waitUntil("phone shell liveness after iPad resize", timeout: 10) {
                phoneOutput.contains(marker)
            }
            _ = try await setup.executeConnectedCommand(
                "tmux kill-session -t \(sessionName)"
            )
        } catch {
            _ = try? await setup.executeConnectedCommand(
                "tmux kill-session -t \(sessionName) >/dev/null 2>&1 || true"
            )
            throw error
        }
    }

    /// The same handoff through the production mosh+tmux split. Each device
    /// has a real visible mosh client and a normal SSH `-CC` side channel.
    @MainActor
    private func assertMoshTmuxViewportHandoff(config: Config) async throws {
        let baseHost = makeHost(
            config: config,
            transport: .mosh,
            useChaosHost: true
        )
        await resetConnectionState(endpoint: "\(baseHost.address):\(baseHost.port)")
        let setup = SSHSession(host: baseHost)
        defer { setup.disconnect() }
        _ = try await connect(
            session: setup,
            pendingRequest: { setup.pendingHostKeyVerification },
            timeout: 20
        )

        let sessionName = try runOwnedTmuxSessionName(
            "viewport-mosh", token: String(UUID().uuidString.prefix(8).lowercased()))
        do {
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -x 160 -y 50 -s \(sessionName); "
                    + "tmux set-option -t \(sessionName) status off"
            )
            let initialGeometry = try await tmuxGeometry(
                sessionName: sessionName,
                using: setup
            )
            XCTAssertEqual(initialGeometry, TmuxGeometry(cols: 160, rows: 50))

            var pinnedHost = baseHost
            pinnedHost.autoTmux = true
            pinnedHost.launchMode = .pinnedTmux
            pinnedHost.tmuxSessionName = sessionName
            pinnedHost.launchCommand = nil

            let phoneMosh = MoshSession(host: pinnedHost)
            defer { phoneMosh.disconnect() }
            phoneMosh.resize(cols: 50, rows: 20)
            _ = try await connect(
                session: phoneMosh,
                pendingRequest: { phoneMosh.pendingHostKeyVerification },
                timeout: 35
            )
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 20),
                sessionName: sessionName,
                using: setup,
                operation: "phone visible mosh attach geometry",
                timeout: 15
            )

            let phoneController = TmuxController(
                controlPath: .sideChannel,
                clientSizePolicy: .resizeTmux
            )
            phoneController.updateClientSize(cols: 50, rows: 20)
            let phoneChannel = TmuxControlChannel(
                host: pinnedHost,
                sessionName: sessionName,
                initialSize: (50, 20)
            )
            phoneController.sendBytes = { [weak phoneChannel] bytes in
                phoneChannel?.send(bytes)
            }
            // Synchronous on purpose: production's side-channel loop also calls `ingest` (SessionView).
            let phonePump = Task { @MainActor in
                for await bytes in phoneChannel.outputStream {
                    phoneController.ingest(bytes)
                }
            }
            defer {
                phonePump.cancel()
                phoneChannel.disconnect()
            }
            phoneChannel.connect()
            try await waitForTmuxHydration(
                phoneController,
                operation: "phone mosh side-channel hydration",
                channel: phoneChannel
            )

            phoneMosh.resize(cols: 50, rows: 12)
            phoneController.updateClientSize(cols: 50, rows: 12)
            phoneChannel.resize(cols: 50, rows: 12)
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 12),
                sessionName: sessionName,
                using: setup,
                operation: "phone mosh keyboard geometry"
            )
            phoneMosh.resize(cols: 50, rows: 20)
            phoneController.updateClientSize(cols: 50, rows: 20)
            phoneChannel.resize(cols: 50, rows: 20)
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 50, rows: 20),
                sessionName: sessionName,
                using: setup,
                operation: "phone mosh restored geometry"
            )

            let pairing = try await beginLiveQRContinuation(host: pinnedHost)
            defer { pairing.origin.cancel(); pairing.recipient.cancel() }
            let ipadMosh = MoshSession(host: pinnedHost)
            defer { ipadMosh.disconnect() }
            ipadMosh.resize(cols: 132, rows: 44)
            _ = try await connect(
                session: ipadMosh,
                pendingRequest: { ipadMosh.pendingHostKeyVerification },
                timeout: 35
            )

            let ipadController = TmuxController(
                controlPath: .sideChannel,
                clientSizePolicy: .resizeTmux
            )
            ipadController.updateClientSize(cols: 132, rows: 44)
            let ipadChannel = TmuxControlChannel(
                host: pinnedHost,
                sessionName: sessionName,
                initialSize: (132, 44)
            )
            ipadController.sendBytes = { [weak ipadChannel] bytes in
                ipadChannel?.send(bytes)
            }
            // Synchronous on purpose: production's side-channel loop also calls `ingest` (SessionView).
            let ipadPump = Task { @MainActor in
                for await bytes in ipadChannel.outputStream {
                    ipadController.ingest(bytes)
                }
            }
            defer {
                ipadPump.cancel()
                ipadChannel.disconnect()
            }
            ipadChannel.connect()
            try await waitForTmuxHydration(
                ipadController,
                operation: "iPad mosh side-channel hydration"
            )
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: 132, rows: 44),
                sessionName: sessionName,
                using: setup,
                operation: "iPad mosh attach geometry",
                timeout: 15
            )
            try await completeLiveQRContinuation(pairing)

            let marker = "TESSERA_MOSH_TMUX_VIEWPORT_\(UUID().uuidString.prefix(8))"
            phoneMosh.send(Array("printf '\(marker)\\n'\r".utf8))
            _ = try await waitForOutput(
                phoneMosh.outputStream,
                containing: marker,
                timeout: 15
            )
            try await Task.sleep(nanoseconds: 300_000_000)
            let geometryAfterPhoneInput = try await tmuxGeometry(
                sessionName: sessionName,
                using: setup
            )
            XCTAssertEqual(
                geometryAfterPhoneInput,
                TmuxGeometry(cols: 132, rows: 44),
                "visible phone mosh input reclaimed tmux sizing from the iPad side channel"
            )
            _ = try await setup.executeConnectedCommand(
                "tmux kill-session -t '\(AutoTmuxCommands.moshViewSessionName(for: sessionName))' >/dev/null 2>&1 || true; "
                    + "tmux kill-session -t \(sessionName)"
            )
        } catch {
            _ = try? await setup.executeConnectedCommand(
                "tmux kill-session -t '\(AutoTmuxCommands.moshViewSessionName(for: sessionName))' >/dev/null 2>&1 || true; "
                    + "tmux kill-session -t \(sessionName) >/dev/null 2>&1 || true"
            )
            throw error
        }
    }

    /// Uses the production owner-bound Mosh repaint receipt rather than
    /// acknowledging a claim when a driver merely schedules a frame.
    @MainActor
    private final class MoshContinuationClient {
        let identity: TmuxController.GridAuthorityIdentity
        let columns: Int
        let rows: Int
        let mosh: MoshSession
        let controller = TmuxController(controlPath: .sideChannel)
        let terminal: TmuxIsolationTerminal
        let adapter = MoshRenderLedgerSurfaceAdapter()
        let channel: TmuxControlChannel
        private var outputPump: Task<Void, Never>?
        private var controlPump: Task<Void, Never>?
        private var authorityRepaintRequestID: UInt64?
        private var authorityRepaintGeneration: UInt64?
        private var stopped = false
        private(set) var completedAuthorityRepaints = 0
        private(set) var controlPaneOutputEvents = 0
        private(set) var lastCompletedAuthorityRepaintOwner: TerminalRenderOwner?
        private(set) var acceptedOwnedForcedFrameCount = 0
        private(set) var lastAcceptedOwnedForcedFrameDeliveryID: UInt64?
        private(set) var lastAcceptedOwnedForcedFrameRequestID: UInt64?
        private(set) var lastAcceptedOwnedForcedFrameOwner: TerminalRenderOwner?
        private(set) var observedLayoutChanges: [(window: String, columns: Int, rows: Int)] = []
        private var layoutNotificationBytes: [UInt8] = []
        var hasPendingAuthorityRepaint: Bool { authorityRepaintGeneration != nil }

        init(host: Host, sessionName: String, identity: TmuxController.GridAuthorityIdentity, columns: Int, rows: Int) {
            self.identity = identity
            self.columns = columns
            self.rows = rows
            mosh = MoshSession(host: host, gridAuthorityDeviceID: identity.id)
            controller.gridAuthorityOwnerSessionName = sessionName
            terminal = TmuxIsolationTerminal(label: "continuation-\(identity.displayName)", columns: columns, rows: rows)
            channel = TmuxControlChannel(host: host, sessionName: sessionName, initialSize: (columns, rows))
            mosh.resize(cols: columns, rows: rows)
            controller.gridAuthorityIdentity = identity
            controller.updateClientSize(cols: columns, rows: rows)
            controller.setGridAuthorityUsesCompactSinglePaneGrid(identity.displayName == "iPhone")
            controller.sendBytes = { [weak channel] bytes in channel?.send(bytes) }
            controller.paneDidOutput = { [weak self] _ in self?.controlPaneOutputEvents += 1 }
            adapter.install(
                on: controller,
                scrollbackLimit: { 2_000 },
                boxForSurface: { [terminal] surface in surface == .live ? terminal.box : nil },
                fallbackSurfaceState: { [terminal] surface in surface == .live ? terminal.surfaceState : nil },
                onHistoryReady: { _, _ in XCTFail("continuation fixture did not request history") },
                onHistoryDropped: { _, _, reason in XCTFail("continuation history dropped: \(reason)") },
                onRequestTransportFullFrame: { [mosh, controller] onScheduled, completion in
                    mosh.forceFullRepaint(
                        requiringFreshRemoteState: controller.gridAuthorityRepaintRequiresFreshRemoteState,
                        onScheduled: onScheduled,
                        completion: completion
                    )
                },
                onCancelTransportFullFrame: { [mosh] request in mosh.cancelFullRepaint(requestID: request) },
                onRetireAllTransportFullFrames: { [mosh] in mosh.retireOutstandingFullRepaints() },
                currentTransportOutputDeliveryID: { [mosh] in mosh.latestOutputDeliveryID },
                onSaveWindowModes: { _, _ in }
            )
            controller.onGridAuthoritySideChannelRepaintRequired = { [weak self] _, generation in
                guard let self else { return }
                // A layout handoff can hold the authority frame in the
                // adapter's deferred queue until its own fresh SSP frame
                // arrives. Track the logical reservation at this boundary;
                // onScheduled belongs to the later native request.
                self.authorityRepaintGeneration = generation
                NSLog("[MoshContinuation] authority repaint queued client=%@ generation=%llu",
                      self.identity.displayName, generation)
                var scheduledRequestID: UInt64?
                self.adapter.requestOwnedTransportFullFrame(
                    retargetsAcrossSurfaceRebind: true,
                    onScheduled: { [weak self] requestID in
                        scheduledRequestID = requestID
                        guard let self, self.authorityRepaintGeneration == generation else { return }
                        self.authorityRepaintRequestID = requestID
                        NSLog("[MoshContinuation] authority native repaint scheduled client=%@ generation=%llu request=%llu",
                              self.identity.displayName, generation, requestID)
                    },
                    completion: { [weak self] acceptedDeliveryID in
                        guard let self, !self.stopped,
                              self.authorityRepaintGeneration == generation else { return }
                        if let requestID = scheduledRequestID {
                            guard requestID == self.authorityRepaintRequestID else { return }
                            self.authorityRepaintRequestID = nil
                        }
                        self.authorityRepaintGeneration = nil
                        NSLog("[MoshContinuation] authority repaint receipt client=%@ generation=%llu delivery=%@ owner=%@",
                              self.identity.displayName, generation, String(describing: acceptedDeliveryID),
                              String(describing: self.terminal.box.boundOwner))
                        if acceptedDeliveryID != nil {
                            self.completedAuthorityRepaints += 1
                            self.lastCompletedAuthorityRepaintOwner = self.terminal.box.boundOwner
                            self.controller.completeGridAuthoritySideChannelRepaint(generation: generation)
                        } else {
                            self.controller.failGridAuthoritySideChannelRepaint(generation: generation)
                        }
                    }
                )
            }
            outputPump = Task { @MainActor [weak self, mosh] in
                for await chunk in mosh.appleAttemptOutputEvents {
                    guard let self, !self.stopped,
                          chunk.attemptID == mosh.appleActiveSessionAttemptID else { continue }
                    self.adapter.noteTransportOutputActivity(
                        deliveryID: chunk.deliveryID,
                        repaintRequestID: chunk.repaintRequestID,
                        byteCount: chunk.bytes.count
                    )
                    let lease = self.adapter.makeTransportOutputLease(
                        deliveryID: chunk.deliveryID,
                        repaintRequestID: chunk.repaintRequestID
                    )
                    let renderedFully = lease.acceptsNextSlice()
                    if renderedFully { self.terminal.box.feed(owner: lease.owner, chunk.bytes[...]) }
                    if let deliveryID = chunk.deliveryID {
                        self.adapter.noteTransportOutputResult(
                            deliveryID: deliveryID,
                            repaintRequestID: chunk.repaintRequestID,
                            renderedFully: renderedFully
                        )
                        if renderedFully,
                           let requestID = chunk.repaintRequestID,
                           let owner = lease.owner,
                           owner == self.terminal.box.boundOwner {
                            self.acceptedOwnedForcedFrameCount += 1
                            self.lastAcceptedOwnedForcedFrameDeliveryID = deliveryID
                            self.lastAcceptedOwnedForcedFrameRequestID = requestID
                            self.lastAcceptedOwnedForcedFrameOwner = owner
                        }
                    }
                }
            }
            // Synchronous on purpose: production's side-channel loop also calls `ingest` (SessionView).
            controlPump = Task { @MainActor [weak self, channel] in
                var initializationBytes: [UInt8] = []
                for await bytes in channel.outputStream {
                    guard let self, !self.stopped else { return }
                    self.recordLayoutNotifications(bytes)
                    if self.terminal.box.boundOwner != nil {
                        self.controller.ingest(bytes)
                        continue
                    }
                    // SwiftUI observes the first authoritative window/pane
                    // and declares the mounted live surface before its later
                    // fence reply. Drive that observation at protocol line
                    // boundaries in this host-free presentation adapter;
                    // initial metadata and the fence may share one SSH read.
                    for (index, byte) in bytes.enumerated() {
                        initializationBytes.append(byte)
                        guard byte == 0x0A else { continue }
                        self.controller.ingest(initializationBytes)
                        initializationBytes.removeAll(keepingCapacity: true)
                        if self.controller.activeWindowId != nil,
                           self.controller.activePaneId != nil {
                            self.controller.declareRenderSurfaces([
                                SurfaceDeclaration(surfaceID: .live, presentation: .single)
                            ])
                            self.controller.submitRenderFact(.scrollbackLimit(lines: 2_000))
                        }
                        if self.terminal.box.boundOwner != nil {
                            if index + 1 < bytes.count {
                                self.controller.ingest(Array(bytes[(index + 1)...]))
                            }
                            break
                        }
                    }
                }
            }
        }

        private func recordLayoutNotifications(_ bytes: [UInt8]) {
            for byte in bytes {
                layoutNotificationBytes.append(byte)
                guard byte == 0x0A else { continue }
                defer { layoutNotificationBytes.removeAll(keepingCapacity: true) }
                let line = String(decoding: layoutNotificationBytes, as: UTF8.self)
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 3, fields[0] == "%layout-change",
                      let layout = WindowLayout.parse(String(fields[2])) else { continue }
                observedLayoutChanges.append((String(fields[1]), layout.root.rect.width, layout.root.rect.height))
                if observedLayoutChanges.count > 256 { observedLayoutChanges.removeFirst() }
            }
        }

        func stop() {
            stopped = true
            authorityRepaintGeneration = nil
            authorityRepaintRequestID = nil
            controller.onGridAuthoritySideChannelRepaintRequired = nil
            adapter.deactivate()
            outputPump?.cancel()
            controlPump?.cancel()
            channel.disconnect()
            mosh.disconnect()
        }
    }

    @MainActor
    private func assertMoshTmuxHeightOnlyDrift(config: Config) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TESSERA_REAL_HOST_TMUX_ISOLATION_GATE"] == "1",
              let sessionName = environment["TESSERA_REAL_HOST_TMUX_MOSH_SESSION"],
              sessionName.hasPrefix("tessera-ios-mosh-"), sessionName.count <= 80,
              sessionName.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            throw XCTSkip("height drift requires the run-owned fixture from run-app-transport-tests.sh")
        }
        let baseHost = makeHost(config: config, transport: .mosh, useChaosHost: true)
        await resetConnectionState(endpoint: "\(baseHost.address):\(baseHost.port)")
        let setup = SSHSession(host: baseHost)
        defer { setup.disconnect() }
        _ = try await connect(session: setup, pendingRequest: { setup.pendingHostKeyVerification }, timeout: 20)
        let token = UUID().uuidString.prefix(8).lowercased()
        let viewName = AutoTmuxCommands.moshViewSessionName(for: sessionName)
        let cleanup = "tmux kill-session -t '=\(viewName)' >/dev/null 2>&1 || true; "
            + "tmux kill-session -t '=\(sessionName)' >/dev/null 2>&1 || true"
        var host = baseHost
        host.autoTmux = true
        host.launchMode = .pinnedTmux
        host.tmuxSessionName = sessionName
        host.launchCommand = nil
        let client = MoshContinuationClient(
            host: host, sessionName: sessionName,
            identity: .init(id: "height-ipad-\(token)", displayName: "iPad"), columns: 132, rows: 44
        )
        defer { client.stop() }

        func attachGrid(_ label: String) {
            client.terminal.view.layer.setNeedsDisplay()
            client.terminal.view.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: client.terminal.view.bounds).image { context in
                client.terminal.view.layer.render(in: context.cgContext)
            }
            let frame = XCTAttachment(image: image)
            frame.name = "mosh-height-\(label)-CoreGraphics-grid"
            frame.lifetime = .keepAlways
            add(frame)
            let facts = XCTAttachment(string: "phase=\(label) native=\(client.terminal.surfaceState.columns)x\(client.terminal.surfaceState.rows) "
                + "authority=\(client.controller.gridAuthority) repaints=\(client.completedAuthorityRepaints) "
                + "ownedForcedFrames=\(client.acceptedOwnedForcedFrameCount) forcedDelivery=\(String(describing: client.lastAcceptedOwnedForcedFrameDeliveryID)) "
                + "forcedRequest=\(String(describing: client.lastAcceptedOwnedForcedFrameRequestID)) forcedOwner=\(String(describing: client.lastAcceptedOwnedForcedFrameOwner)) "
                + "owner=\(String(describing: client.terminal.box.boundOwner)) layouts=\(client.observedLayoutChanges)\n\(client.terminal.transcript)")
            facts.name = "mosh-height-\(label)-state"
            facts.lifetime = .keepAlways
            add(facts)
        }

        func stamp() async throws -> TmuxGridAuthorityStamp {
            let output = try await setup.executeConnectedCommand(
                "tmux show-options -qv -t '\(viewName)' \(TmuxController.gridAuthorityOption)"
            )
            return try XCTUnwrap(TmuxGridAuthorityStamp.parse(output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        var inputs = 0
        func assertRestored(
            _ label: String,
            repaintFloor: Int?,
            forcedFrameFloor: Int? = nil,
            owner: TerminalRenderOwner
        ) async throws {
            try await waitForTmuxGeometry(TmuxGeometry(cols: client.columns, rows: client.rows),
                sessionName: sessionName, using: setup, operation: "\(label) repaired height", timeout: 3)
            try await waitUntil("\(label) consumed fresh owner-bound height frame", timeout: 3) {
                client.controller.gridAuthority == .mine
                    && !client.controller.gridAuthorityReclaimInFlight
                    && (repaintFloor.map { client.completedAuthorityRepaints > $0
                        && client.lastCompletedAuthorityRepaintOwner == client.terminal.box.boundOwner } ?? true)
                    && (forcedFrameFloor.map { client.acceptedOwnedForcedFrameCount > $0
                        && client.lastAcceptedOwnedForcedFrameOwner == client.terminal.box.boundOwner } ?? true)
            }
            let currentOwner = try XCTUnwrap(client.terminal.box.boundOwner)
            XCTAssertEqual(currentOwner.windowId, owner.windowId, "height repair switched windows")
            XCTAssertEqual(currentOwner.paneId, owner.paneId, "height repair switched panes")
            XCTAssertEqual(client.controller.activeWindowId, owner.windowId)
            XCTAssertEqual(client.controller.activePaneId, owner.paneId)
            XCTAssertEqual(client.terminal.surfaceState.columns, client.columns)
            XCTAssertEqual(client.terminal.surfaceState.rows, client.rows, "native canvas drifted with the remote pane")
            inputs += 1
            client.mosh.send(Array("r".utf8))
            let input = String(format: "HEIGHT_INPUT_%04d", inputs)
            try await waitUntil("\(label) fresh input and bottom row", timeout: 3) {
                client.terminal.transcript.contains("HEIGHT_ROWS_0044")
                    && client.terminal.transcript.contains("HEIGHT_BOTTOM_0044")
                    && client.terminal.transcript.contains(input)
            }
            let restoredStamp = try await stamp()
            XCTAssertEqual(restoredStamp.deviceID, client.identity.id)
            attachGrid(label)
        }

        func injectDrift(rows: Int, owner: TerminalRenderOwner, label: String) async throws {
            let before = try await stamp()
            let notificationFloor = client.observedLayoutChanges.count
            // One tmux command list records the changed pane and standing
            // stamp before its layout notification can trigger mobile repair.
            let output = try await setup.executeConnectedCommand(
                "tmux resize-window -t '\(owner.windowId)' -x \(client.columns) -y \(rows) \\; "
                    + "display-message -p -t '\(owner.paneId)' 'HEIGHT_DRIFT_\(rows) #{pane_width}x#{pane_height}' \\; "
                    + "show-options -qv -t '\(viewName)' \(TmuxController.gridAuthorityOption)"
            )
            XCTAssertTrue(output.contains("HEIGHT_DRIFT_\(rows) \(client.columns)x\(rows)"), output)
            let recordedStamp = try XCTUnwrap(output.split(whereSeparator: { $0.isNewline })
                .compactMap { TmuxGridAuthorityStamp.parse(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }.first)
            XCTAssertEqual(recordedStamp, before, "fixture drift introduced another authority claim")
            try await waitUntil("\(label) real same-window height layout notification", timeout: 3) {
                client.observedLayoutChanges.dropFirst(notificationFloor).contains {
                    $0.window == owner.windowId.description && $0.columns == client.columns && $0.rows == rows
                }
            }
            XCTAssertEqual(client.terminal.surfaceState.columns, client.columns)
            XCTAssertEqual(client.terminal.surfaceState.rows, client.rows)
            let drift = XCTAttachment(string: output)
            drift.name = "mosh-height-\(label)-server-drift-before-layout-repair"
            drift.lifetime = .keepAlways
            add(drift)
        }

        let program = "import os,select,sys,termios,time,tty\n"
            + "fd=sys.stdin.fileno(); saved=termios.tcgetattr(fd); tty.setraw(fd); inputs=0; deadline=time.monotonic()+120\n"
            + "sys.stdout.write('\\x1b[?1049h\\x1b[?25l'); sys.stdout.flush()\n"
            + "try:\n"
            + " while time.monotonic()<deadline:\n"
            + "  cols,rows=os.get_terminal_size(fd); output=['\\x1b[H\\x1b[2J']\n"
            + "  for row in range(rows):\n"
            + "   text=('HEIGHT_COLS_%04d HEIGHT_ROWS_%04d HEIGHT_INPUT_%04d'%(cols,rows,inputs)) if row==0 else ('HEIGHT_BOTTOM_%04d'%rows if row==rows-1 else 'HEIGHT_ROW_%04d'%row)\n"
            + "   output.append('\\x1b[%d;1H'%(row+1)+text)\n"
            + "  sys.stdout.write(''.join(output)); sys.stdout.flush()\n"
            + "  if select.select([fd],[],[],0.1)[0]: inputs+=os.read(fd,1024).count(b'r')\n"
            + "finally:\n"
            + " sys.stdout.write('\\x1b[?1049l\\x1b[?25h'); sys.stdout.flush(); termios.tcsetattr(fd,termios.TCSANOW,saved)\n"
        do {
            let command = "exec python3 -u -c \(shellQuote(program))"
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -x 132 -y 44 -s '\(sessionName)' \(shellQuote(command)); "
                    + "tmux set-option -t '\(sessionName)' status off"
            )
            _ = try await connect(session: client.mosh, pendingRequest: { client.mosh.pendingHostKeyVerification }, timeout: 35)
            client.channel.connect()
            try await waitForTmuxHydration(client.controller, operation: "height fixture hydration", channel: client.channel)
            // Attach never claims; opening the displayed session is the show,
            // and the show is what takes control and binds the owner. Show
            // first, then wait for owner evidence.
            client.controller.gridAuthorityShown()
            try await waitUntil("initial height owner", timeout: 3) { client.terminal.box.boundOwner != nil }
            let initialOwner = try XCTUnwrap(client.terminal.box.boundOwner)
            try await assertRestored("initial-healthy", repaintFloor: 0, owner: initialOwner)

            let layoutOwner = try XCTUnwrap(client.terminal.box.boundOwner)
            let layoutFloor = client.completedAuthorityRepaints
            let layoutForcedFrameFloor = client.acceptedOwnedForcedFrameCount
            let layoutStamp = try await stamp()
            try await injectDrift(rows: client.rows - 2, owner: layoutOwner, label: "layout-only")
            try await assertRestored("layout-only-restored", repaintFloor: nil,
                forcedFrameFloor: layoutForcedFrameFloor, owner: layoutOwner)
            XCTAssertEqual(client.completedAuthorityRepaints, layoutFloor,
                "ordinary layout repair unnecessarily started an authority claim")
            let stampAfterLayoutRepair = try await stamp()
            XCTAssertEqual(stampAfterLayoutRepair, layoutStamp,
                "ordinary layout repair changed the standing authority stamp")

            let backgroundOwner = try XCTUnwrap(client.terminal.box.boundOwner)
            let backgroundFloor = client.completedAuthorityRepaints
            let stampBeforeBackground = try await stamp()
            client.controller.prepareForAppInactivity()
            try await injectDrift(rows: client.rows - 3, owner: backgroundOwner, label: "background")
            let geometryBeforeForeground = try await tmuxGeometry(sessionName: sessionName, using: setup)
            let stampBeforeForeground = try await stamp()
            XCTAssertEqual(geometryBeforeForeground, TmuxGeometry(cols: client.columns, rows: client.rows - 3),
                "the inactive phase repaired geometry before foreground could exercise recovery")
            XCTAssertEqual(client.completedAuthorityRepaints, backgroundFloor,
                "the inactive phase completed the frame attributed to foreground")
            XCTAssertEqual(stampBeforeForeground, stampBeforeBackground,
                "the inactive phase committed another claim")
            attachGrid("background-before-foreground")

            // Inactive without a background is transparent, so this return is
            // a read, not a show. Our stamp over a grid this device never
            // pushed means a stamp-less client sized it (D5): yield, never
            // resize, and leave the stamp alone.
            client.controller.refreshActiveWindowOnForeground()
            try await waitForControlFence(client.controller, operation: "inactive-return foreground read")
            try await waitUntil("inactive return yields to the stamp-less resize", timeout: 3) {
                client.controller.gridAuthority == .peer(displayName: "another device")
                    && !client.controller.gridAuthorityReclaimInFlight
            }
            let geometryAfterRead = try await tmuxGeometry(sessionName: sessionName, using: setup)
            XCTAssertEqual(geometryAfterRead, TmuxGeometry(cols: client.columns, rows: client.rows - 3),
                "a foreground read without a show resized a stamp-less client's grid")
            let stampAfterRead = try await stamp()
            XCTAssertEqual(stampAfterRead, stampBeforeBackground, "a foreground read without a show wrote the stamp")
            XCTAssertEqual(client.completedAuthorityRepaints, backgroundFloor,
                "a foreground read without a show started a claim")
            attachGrid("inactive-return-yielded")

            // A real show (returning from the background after more than the
            // hide debounce) takes control back and repairs the same window.
            client.controller.gridAuthorityShown()
            try await assertRestored("show-restored", repaintFloor: backgroundFloor, owner: backgroundOwner)
            let stampAfterShow = try await stamp()
            XCTAssertGreaterThan(stampAfterShow.generation, stampBeforeBackground.generation,
                "the show must commit its own fresh claim")

            let stableStamp = try await stamp()
            let stableRepaints = client.completedAuthorityRepaints
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let stampAfterIdle = try await stamp()
            XCTAssertEqual(stampAfterIdle, stableStamp, "settled height repair entered a claim loop")
            XCTAssertEqual(client.completedAuthorityRepaints, stableRepaints, "settled height repair repeated its native repaint")
            try await waitForTmuxGeometry(TmuxGeometry(cols: client.columns, rows: client.rows),
                sessionName: sessionName, using: setup, operation: "quiescent repaired height", timeout: 3)
            XCTAssertEqual(client.controlPaneOutputEvents, 0)
            _ = try await setup.executeConnectedCommand(cleanup)
            let success = XCTAttachment(string: "TESSERA_IOS_MOSH_HEIGHT_DRIFT_OK columns=132 rows=44 layoutDrift=42 backgroundDrift=41 inactiveReturnYielded=1 showReclaimed=1 sameWindow=1 samePane=1 unchangedCanvas=1 unchangedDriftStamp=1 freshOwnedFrame=1 freshInput=1 boundedRepair=1 settledNoClaimLoop=1")
            success.name = "mosh-height-drift-success"
            success.lifetime = .keepAlways
            add(success)
        } catch {
            attachGrid("failure")
            if let data = DiagnosticLogStore.attachmentData() {
                let diagnostics = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
                diagnostics.name = "mosh-height-failure-diagnostics"
                diagnostics.lifetime = .keepAlways
                add(diagnostics)
            }
            _ = try? await setup.executeConnectedCommand(cleanup)
            throw error
        }
    }

    @MainActor
    private func assertMoshTmuxContinuationClaims(
        config: Config,
        verifiesForegroundGridRepair: Bool = false,
        phoneColumns: Int = 50
    ) async throws {
        let baseHost = makeHost(config: config, transport: .mosh, useChaosHost: true)
        await resetConnectionState(endpoint: "\(baseHost.address):\(baseHost.port)")
        let setup = SSHSession(host: baseHost)
        defer { setup.disconnect() }
        _ = try await connect(session: setup, pendingRequest: { setup.pendingHostKeyVerification }, timeout: 20)
        let token = UUID().uuidString.prefix(8).lowercased()
        let sessionName = try runOwnedTmuxSessionName("continuation", token: String(token))
        let viewName = AutoTmuxCommands.moshViewSessionName(for: sessionName)
        let floodGate = "/tmp/\(sessionName)-flood-go"
        var stoppedMoshServer: StoppedMoshServer?
        func resumeStoppedMoshServer() async {
            guard let server = stoppedMoshServer else { return }
            // A server left stopped outlives both clients and the session
            // cleanup, and makes the next native gate refuse the account.
            do {
                _ = try await signalMoshServer(server, "CONT", using: setup)
                stoppedMoshServer = nil
            } catch {
                XCTFail("stopped mosh-server \(server.pid) was not confirmed continued: \(error)")
            }
        }
        let cleanupCommand = "tmux kill-session -t '=\(viewName)' >/dev/null 2>&1 || true; "
            + "tmux kill-session -t '=\(sessionName)' >/dev/null 2>&1 || true; "
            + "rm -f '\(floodGate)'"
        var host = baseHost
        host.autoTmux = true
        host.launchMode = .pinnedTmux
        host.tmuxSessionName = sessionName
        host.launchCommand = nil
        let phone = MoshContinuationClient(
            host: host, sessionName: sessionName,
            identity: .init(id: "continuation-phone-\(token)", displayName: "iPhone"), columns: phoneColumns, rows: 20
        )
        let ipad = MoshContinuationClient(
            host: host, sessionName: sessionName,
            identity: .init(id: "continuation-ipad-\(token)", displayName: "iPad"), columns: 132, rows: 44
        )
        defer { phone.stop(); ipad.stop() }

        func attachGrid(_ client: MoshContinuationClient, label: String) {
            // These native SwiftTerm surfaces are CoreGraphics-backed. Their
            // grids document frame delivery, not SwiftUI continuation chrome.
            client.terminal.view.layer.setNeedsDisplay()
            client.terminal.view.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: client.terminal.view.bounds).image { context in
                client.terminal.view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "mosh-continuation-\(label)-\(client.identity.displayName)-CoreGraphics-grid"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func connectClient(_ client: MoshContinuationClient) async throws {
            // Each fixture supplies its own visible-client identity.
            _ = try await connect(session: client.mosh, pendingRequest: { client.mosh.pendingHostKeyVerification }, timeout: 35)
            client.channel.connect()
            try await waitForTmuxHydration(client.controller, operation: "\(client.identity.displayName) continuation hydration", channel: client.channel)
        }

        func assertSettled(_ winner: MoshContinuationClient, loser: MoshContinuationClient?, repaintFloor: Int, label: String) async throws {
            try await waitUntil("\(label) authority fence and consumed Mosh repaint", timeout: 3) {
                guard case .mine = winner.controller.gridAuthority,
                      !winner.controller.gridAuthorityReclaimInFlight,
                      winner.completedAuthorityRepaints > repaintFloor else { return false }
                guard let loser else { return true }
                guard case .peer(let displayName) = loser.controller.gridAuthority else { return false }
                return displayName == winner.identity.displayName && !loser.controller.gridAuthorityReclaimInFlight
            }
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: winner.columns, rows: winner.rows),
                sessionName: sessionName, using: setup, operation: "\(label) remote grid", timeout: 3
            )
            let stampOutput = try await setup.executeConnectedCommand(
                "tmux show-options -qv -t '\(viewName)' \(TmuxController.gridAuthorityOption)"
            )
            let stamp = try XCTUnwrap(TmuxGridAuthorityStamp.parse(stampOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(stamp.deviceID, winner.identity.id, "\(label) committed the wrong installation")
            try await waitForVisibleMoshClientTuple(
                using: setup, sessionName: sessionName,
                authorityVisibleClientOption: TmuxController.gridAuthorityVisibleClientOption(identityID: winner.identity.id),
                expectedWindowID: XCTUnwrap(winner.controller.activeWindowId),
                expectedPaneID: XCTUnwrap(winner.controller.activePaneId), operation: label
            )
            let marker = "TESSERA-CONT-\(label)-\(token)"
            winner.mosh.send(Array((unechoedPrintf(marker) + "\r").utf8))
            try await waitUntil("\(label) fresh output in winning terminal", timeout: 3) {
                winner.terminal.transcript.contains(marker)
            }
            NSLog("[MoshContinuation] %@ local=%@ peer=%@ repaints=%d marker=%@", label,
                  String(describing: winner.controller.gridAuthority), String(describing: loser?.controller.gridAuthority),
                  winner.completedAuthorityRepaints, marker)
            attachGrid(winner, label: "\(label)-owner")
            if let loser { attachGrid(loser, label: "\(label)-peer") }
        }

        func assertForegroundGridRepair() async throws {
            // A real alternate-screen program redraws at its PTY's current
            // dimensions. Widening that PTY leaves EDGE_R0 outside a phone's
            // cached Mosh grid; repainting that cache cannot correct geometry.
            let edgeMarker = "EDGE_R0_\(token)"
            let gridProgram = "import os,select,signal,sys,termios,time,tty\n"
                + "fd=sys.stdin.fileno(); saved=termios.tcgetattr(fd); tty.setraw(fd)\n"
                + "inputs=0; ticks=0; deadline=time.monotonic()+120\n"
                + "sys.stdout.write('\\x1b[?1049h\\x1b[?25l'); sys.stdout.flush()\n"
                + "try:\n"
                + " while time.monotonic()<deadline:\n"
                + "  cols,rows=os.get_terminal_size(fd); ticks+=1\n"
                + "  output=['\\x1b[H\\x1b[2J']\n"
                + "  for row in range(rows):\n"
                + "   left=('GRID_COLS_%04d GRID_INPUT_%04d'%(cols,inputs)) if row==0 else ('ROW_%04d TICK_%04d'%(row,ticks))\n"
                + "   edge=\(String(reflecting: edgeMarker)) if row==0 else ('EDGE_R%d'%row)\n"
                + "   output.append('\\x1b[%d;1H'%(row+1)+left+'.'*max(0,cols-len(left)-len(edge))+edge)\n"
                + "  sys.stdout.write(''.join(output)); sys.stdout.flush()\n"
                + "  ready=select.select([fd],[],[],0.25)[0]\n"
                + "  if ready: inputs+=os.read(fd,1024).count(b'r')\n"
                + "finally:\n"
                + " sys.stdout.write('\\x1b[?1049l\\x1b[?25h'); sys.stdout.flush(); termios.tcsetattr(fd,termios.TCSANOW,saved)\n"
            let gridCommand = "exec python3 -u -c \(shellQuote(gridProgram))"
            _ = try await setup.executeConnectedCommand(
                "tmux respawn-pane -k -t '\(sessionName):0.0' \(shellQuote(gridCommand))"
            )
            try await waitUntil("wide owning iPad right-edge grid", timeout: 5) {
                ipad.terminal.transcript.contains(edgeMarker)
                    && ipad.terminal.transcript.contains("GRID_INPUT_0000")
            }

            func authorityStamp() async throws -> TmuxGridAuthorityStamp {
                let output = try await setup.executeConnectedCommand(
                    "tmux show-options -qv -t '\(viewName)' \(TmuxController.gridAuthorityOption)"
                )
                return try XCTUnwrap(TmuxGridAuthorityStamp.parse(output.trimmingCharacters(in: .whitespacesAndNewlines)))
            }

            func controlFence(_ client: MoshContinuationClient, label: String) async throws {
                let marker = "TESSERA-FG-FENCE-\(label)-\(token)"
                var result: Result<[String], TmuxController.CommandError>?
                client.controller.sendControlCommand("display-message -p '\(marker)'") { result = $0 }
                try await waitUntil("\(label) foreground authority query fence", timeout: 3) { result != nil }
                XCTAssertTrue(try XCTUnwrap(result).get().contains(marker))
            }

            var inputCounter = 0
            func assertOwningGrid(_ client: MoshContinuationClient, peer: MoshContinuationClient,
                                  repaintFloor: Int, priorOwner: TerminalRenderOwner, label: String) async throws {
                try await waitUntil("\(label) fresh foreground authority frame", timeout: 3) {
                    client.controller.gridAuthority == .mine
                        && !client.controller.gridAuthorityReclaimInFlight
                        && client.completedAuthorityRepaints > repaintFloor
                        && client.lastCompletedAuthorityRepaintOwner == client.terminal.box.boundOwner
                        && peer.controller.gridAuthority == .peer(displayName: client.identity.displayName)
                }
                try await waitForTmuxGeometry(TmuxGeometry(cols: client.columns, rows: client.rows),
                    sessionName: sessionName, using: setup, operation: "\(label) corrected PTY geometry", timeout: 3)
                let currentOwner = try XCTUnwrap(client.terminal.box.boundOwner)
                XCTAssertEqual(currentOwner.windowId, priorOwner.windowId, "foreground must retain the same window")
                XCTAssertEqual(currentOwner.paneId, priorOwner.paneId, "foreground must retain the same pane")
                XCTAssertEqual(client.controller.activeWindowId, priorOwner.windowId)
                XCTAssertEqual(client.controller.activePaneId, priorOwner.paneId)
                try await waitUntil("\(label) right edge restored", timeout: 3) { client.terminal.transcript.contains(edgeMarker) }
                inputCounter += 1
                client.mosh.send(Array("r".utf8))
                let inputMarker = String(format: "GRID_INPUT_%04d", inputCounter)
                try await waitUntil("\(label) fresh input and right edge rendered", timeout: 3) {
                    client.terminal.transcript.contains(inputMarker) && client.terminal.transcript.contains(edgeMarker)
                }
                attachGrid(client, label: "foreground-\(label)-restored")
            }

            func driftAndForeground(_ client: MoshContinuationClient, peer: MoshContinuationClient,
                                    label: String) async throws {
                let priorOwner = try XCTUnwrap(client.terminal.box.boundOwner)
                let priorStamp = try await authorityStamp()
                XCTAssertEqual(priorStamp.deviceID, client.identity.id)
                let repaintFloor = client.completedAuthorityRepaints
                // A real background: the hide edge, then inactivity.
                client.controller.gridAuthorityHidden()
                client.controller.prepareForAppInactivity()
                let driftColumns = client.columns + 32
                _ = try await setup.executeConnectedCommand(
                    "tmux resize-window -t \(priorOwner.windowId.description) -x \(driftColumns) -y \(client.rows)"
                )
                try await waitForTmuxGeometry(TmuxGeometry(cols: driftColumns, rows: client.rows),
                    sessionName: sessionName, using: setup, operation: "\(label) same-window remote drift", timeout: 3)
                let driftStamp = try await authorityStamp()
                XCTAssertEqual(driftStamp, priorStamp, "the fixture drift must not introduce a peer claim")
                let driftMarker = String(format: "GRID_COLS_%04d", driftColumns)
                try await waitUntil("\(label) cached wider SSP grid visibly clips its right edge", timeout: 3) {
                    client.terminal.transcript.contains(driftMarker)
                        && !client.terminal.transcript.contains(edgeMarker)
                }
                attachGrid(client, label: "foreground-\(label)-drift")

                // Pause only the mosh-server launched by this fixture client.
                // Its SSH side channel remains responsive, so a cached-frame
                // receipt must never settle the geometry recovery by itself.
                let serverPID = try XCTUnwrap(client.mosh.remoteServerPID)
                XCTAssertGreaterThan(serverPID, 0)
                let server = try await moshServerIdentity(serverPID, using: setup)
                stoppedMoshServer = server
                let paused = try await signalMoshServer(server, "STOP", using: setup)
                XCTAssertEqual(paused, .confirmed, "the fixture client's mosh-server must still exist to be stopped")
                let stoppedState = try await setup.executeConnectedCommand("awk '{print $3}' /proc/\(serverPID)/stat")
                XCTAssertEqual(stoppedState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), "T")
                // Returning from the background past the hide debounce is a
                // show: the foreground read, then the show's own fresh read,
                // which claims over the stamp-less drift.
                client.controller.refreshActiveWindowOnForeground()
                client.controller.gridAuthorityShown()
                try await waitUntil("\(label) authoritative repaint requested after SSH geometry fence", timeout: 3) {
                    client.hasPendingAuthorityRepaint
                }
                let correctedGeometryWhilePaused = try await tmuxGeometry(sessionName: sessionName, using: setup)
                XCTAssertEqual(correctedGeometryWhilePaused, TmuxGeometry(cols: client.columns, rows: client.rows),
                    "the SSH geometry fence must finish before awaiting fresh SSP state")
                try await Task.sleep(nanoseconds: 250_000_000)
                XCTAssertTrue(client.hasPendingAuthorityRepaint,
                    "the exact authority repaint must still await the stopped SSP server")
                XCTAssertEqual(client.completedAuthorityRepaints, repaintFloor,
                    "a cached native framebuffer must not acknowledge the resized remote grid")
                let pausedStamp = try await authorityStamp()
                XCTAssertEqual(pausedStamp, priorStamp, "no fresh authority stamp may commit while SSP remains paused")
                attachGrid(client, label: "foreground-\(label)-SSP-paused")
                let resumed = try await signalMoshServer(server, "CONT", using: setup)
                stoppedMoshServer = nil
                XCTAssertEqual(resumed, .confirmed, "the stopped mosh-server must be continued, not lost")
                try await controlFence(client, label: "\(label)-SSP-resumed")
                try await assertOwningGrid(client, peer: peer, repaintFloor: repaintFloor, priorOwner: priorOwner, label: label)
                let repairedStamp = try await authorityStamp()
                XCTAssertEqual(repairedStamp.deviceID, client.identity.id)
                XCTAssertGreaterThan(repairedStamp.generation, priorStamp.generation, "foreground recovery must commit its own fresh claim")
            }

            try await driftAndForeground(ipad, peer: phone, label: "ipad")

            // An inactive-only interruption (no background, so no show edge)
            // on a yielded device reads the standing peer claim; its old local
            // viewport is never authority to resize this grid.
            let peerStamp = try await authorityStamp()
            let peerRepaints = phone.completedAuthorityRepaints
            phone.controller.prepareForAppInactivity()
            phone.controller.refreshActiveWindowOnForeground()
            try await controlFence(phone, label: "paused-phone")
            XCTAssertEqual(phone.controller.gridAuthority, .peer(displayName: ipad.identity.displayName))
            XCTAssertFalse(phone.controller.gridAuthorityReclaimInFlight)
            XCTAssertEqual(phone.completedAuthorityRepaints, peerRepaints)
            let stampAfterPeerForeground = try await authorityStamp()
            XCTAssertEqual(stampAfterPeerForeground, peerStamp, "paused foreground must not steal the peer stamp")
            try await waitForTmuxGeometry(TmuxGeometry(cols: ipad.columns, rows: ipad.rows),
                sessionName: sessionName, using: setup, operation: "paused foreground preserves iPad grid", timeout: 3)
            attachGrid(phone, label: "foreground-paused-phone")

            let phoneOwner = try XCTUnwrap(phone.terminal.box.boundOwner)
            let phoneFloor = phone.completedAuthorityRepaints
            XCTAssertTrue(phone.controller.reclaimGridAuthority(reason: "foreground-fixture"))
            try await assertOwningGrid(phone, peer: ipad, repaintFloor: phoneFloor, priorOwner: phoneOwner, label: "phone-takeback")
            try await driftAndForeground(phone, peer: ipad, label: "phone")

            // R2: a show over this device's own stamp at its own grid
            // resolves with zero commands: no claim, no stamp write, no
            // authority repaint, and the same owner epoch.
            let unchangedOwner = try XCTUnwrap(phone.terminal.box.boundOwner)
            let unchangedFloor = phone.completedAuthorityRepaints
            let unchangedStamp = try await authorityStamp()
            phone.controller.gridAuthorityHidden()
            phone.controller.prepareForAppInactivity()
            phone.controller.refreshActiveWindowOnForeground()
            phone.controller.gridAuthorityShown()
            try await controlFence(phone, label: "phone-same-grid")
            try await waitUntil("phone-same-grid show resolves without a claim", timeout: 3) {
                phone.controller.gridAuthority == .mine
                    && !phone.controller.gridAuthorityReclaimInFlight
                    && !phone.controller.gridAuthorityHasPendingIntent
            }
            XCTAssertEqual(phone.completedAuthorityRepaints, unchangedFloor,
                "a same-grid show must not run an authority repaint")
            let sameGridStamp = try await authorityStamp()
            XCTAssertEqual(sameGridStamp, unchangedStamp, "a same-grid show must not rewrite the stamp")
            XCTAssertEqual(ipad.controller.gridAuthority, .peer(displayName: phone.identity.displayName))
            try await waitForTmuxGeometry(TmuxGeometry(cols: phone.columns, rows: phone.rows),
                sessionName: sessionName, using: setup, operation: "phone-same-grid geometry", timeout: 3)
            XCTAssertEqual(phone.terminal.box.boundOwner, unchangedOwner, "same-grid foreground must preserve the owner epoch")
            inputCounter += 1
            phone.mosh.send(Array("r".utf8))
            let sameGridInput = String(format: "GRID_INPUT_%04d", inputCounter)
            try await waitUntil("phone-same-grid fresh input and right edge rendered", timeout: 3) {
                phone.terminal.transcript.contains(sameGridInput) && phone.terminal.transcript.contains(edgeMarker)
            }
            attachGrid(phone, label: "foreground-phone-same-grid")
            XCTAssertEqual(phone.controlPaneOutputEvents, 0)
            XCTAssertEqual(ipad.controlPaneOutputEvents, 0)
        }

        do {
            // A small real PTY redraw stream keeps the same natural-output
            // boundary as a user's active shell while both painters stay live.
            // The loop ends on its own first failed write: once the pane's
            // PTY is gone (the session killed, or a crashed test's lane
            // cleanup), nothing else ever stops a background job here.
            let heartbeat = "while sleep 0.25 && printf 'TESSERA-CONT-TICK\\n'; do :; done &"
            _ = try await setup.executeConnectedCommand(
                "tmux new-session -d -x 160 -y 50 -s '\(sessionName)'; "
                    + "tmux set-option -t '\(sessionName)' status off; "
                    + "tmux send-keys -l -t '\(sessionName):0.0' \(shellQuote(heartbeat)); "
                    + "tmux send-keys -t '\(sessionName):0.0' Enter"
            )
            try await connectClient(phone)
            // Attach never claims; displaying the session on the phone does.
            phone.controller.gridAuthorityShown()
            try await assertSettled(phone, loser: nil, repaintFloor: 0, label: "phone1")
            try await connectClient(ipad)
            // S2': the iPad's attach alone reads the phone's stamp and yields.
            // It never sizes the window or writes the stamp.
            try await waitForControlFence(ipad.controller, operation: "iPad attach read")
            try await waitUntil("iPad attach yields to the phone", timeout: 3) {
                ipad.controller.gridAuthority == .peer(displayName: phone.identity.displayName)
                    && !ipad.controller.gridAuthorityReclaimInFlight
            }
            XCTAssertEqual(ipad.completedAuthorityRepaints, 0, "attach started a claim without a show")
            XCTAssertEqual(phone.controller.gridAuthority, .mine, "a passive attach displaced the phone")
            try await waitForTmuxGeometry(
                TmuxGeometry(cols: phone.columns, rows: phone.rows),
                sessionName: sessionName, using: setup, operation: "iPad attach keeps the phone grid", timeout: 3
            )
            let attachStampOutput = try await setup.executeConnectedCommand(
                "tmux show-options -qv -t '\(viewName)' \(TmuxController.gridAuthorityOption)"
            )
            let attachStamp = try XCTUnwrap(TmuxGridAuthorityStamp.parse(
                attachStampOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(attachStamp.deviceID, phone.identity.id, "a passive attach wrote the stamp")
            // The Handoff/QR continuation receipt is an explicit open: it
            // takes control from the phone.
            ipad.controller.gridAuthorityShown(source: .explicitOpen)
            try await assertSettled(ipad, loser: phone, repaintFloor: 0, label: "ipad1")

            if verifiesForegroundGridRepair {
                try await assertForegroundGridRepair()
                _ = try await setup.executeConnectedCommand(cleanupCommand)
                let attachment = XCTAttachment(string: "TESSERA_IOS_MOSH_FOREGROUND_GRID_OK sameWindow=1 samePane=1 phone=1 ipad=1 delayedSSPBarrier=1 consumedOwnedFrame=1 freshStamp=1 rightEdge=1 input=1 peerPreserved=1 unchangedEpoch=1 sameGridShowZeroCommands=1 controlPaneOutput=0")
                attachment.name = "mosh-foreground-grid-success"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }

            for client in [phone, ipad] {
                var flagsResult: Result<[String], TmuxController.CommandError>?
                client.controller.sendControlCommand("display-message -p '#{client_control_mode}|#{client_flags}'") {
                    flagsResult = $0
                }
                try await waitUntil("\(client.identity.displayName) control-client flags", timeout: 3) { flagsResult != nil }
                let lines = try XCTUnwrap(flagsResult).get()
                XCTAssertTrue(
                    lines.contains { $0.hasPrefix("1|") && $0.contains("no-output") },
                    "the \(client.identity.displayName) side channel must suppress duplicate pane output: \(lines)"
                )
            }

            // The side channel needs topology, subscriptions and replies,
            // while SSP owns terminal painting. Four inactive panes expose
            // redundant control-mode %output starving a continuation fence.
            // Every process is scoped to this disposable tmux group, waits
            // for the metadata fence, and exits within ten seconds of release.
            let floodProgram = "import os,sys,time\n"
                + "gate=\(String(reflecting: floodGate))\n"
                + "ready=time.monotonic()+10\n"
                + "while not os.path.exists(gate) and time.monotonic()<ready: time.sleep(0.05)\n"
                + "deadline=time.monotonic()+10\n"
                + "block=('TESSERA-CONT-FLOOD-\(token)-'+'x'*1000+'\\n')*50\n"
                + "while os.path.exists(gate) and time.monotonic()<deadline:\n"
                + " sys.stdout.write(block); sys.stdout.flush(); time.sleep(0.05)\n"
            let floodCommand = "exec python3 -u -c \(shellQuote(floodProgram))"
            let floodWindowCount = 4
            for index in 1...floodWindowCount {
                _ = try await setup.executeConnectedCommand(
                    "tmux new-window -d -t '\(sessionName)' -n 'continuation-flood-\(index)' \(shellQuote(floodCommand))"
                )
            }
            try await waitUntil("both continuation clients hydrated background windows", timeout: 10) {
                phone.controller.windows.count == floodWindowCount + 1
                    && ipad.controller.windows.count == floodWindowCount + 1
            }
            _ = try await setup.executeConnectedCommand("touch '\(floodGate)'")
            try await Task.sleep(nanoseconds: 300_000_000)
            let fenceMarker = "TESSERA-CONT-FENCE-\(token)"
            var fenceFinished = false
            var fenceResult = "<pending>"
            phone.controller.sendControlCommand("display-message -p '\(fenceMarker)'") { result in
                fenceResult = String(describing: result)
                if case .success(let lines) = result {
                    fenceFinished = lines.contains(fenceMarker)
                }
            }
            try await waitUntil("background-output continuation control fence: \(fenceResult)", timeout: 3) {
                fenceFinished
            }
            let phoneRepaints = phone.completedAuthorityRepaints
            XCTAssertTrue(phone.controller.reclaimGridAuthority(reason: "continuation-fixture"))
            try await assertSettled(phone, loser: ipad, repaintFloor: phoneRepaints, label: "phone2")
            let ipadRepaints = ipad.completedAuthorityRepaints
            XCTAssertTrue(ipad.controller.reclaimGridAuthority(reason: "continuation-fixture"))
            try await assertSettled(ipad, loser: phone, repaintFloor: ipadRepaints, label: "ipad2")
            XCTAssertEqual(phone.controlPaneOutputEvents, 0, "phone control channel duplicated SSP pane output")
            XCTAssertEqual(ipad.controlPaneOutputEvents, 0, "iPad control channel duplicated SSP pane output")
            _ = try await setup.executeConnectedCommand(cleanupCommand)
            let attachment = XCTAttachment(string: "TESSERA_IOS_MOSH_CONTINUATION_OK distinctInstalls=1 visibleClients=2 reclaim=2 consumedFrames=1 authorityStates=1 freshOutput=1 backgroundFloodWindows=4 boundedControlFence=1 controlPaneOutput=0 phoneColumns=\(phone.columns) phoneRows=\(phone.rows) ipadColumns=\(ipad.columns) ipadRows=\(ipad.rows) equalWidth=\(phone.columns == ipad.columns ? 1 : 0)")
            attachment.name = "mosh-continuation-success"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            // Await the run-owned server's resume before either disconnect
            // defer can retire its UDP connection or the fixture SSH route.
            await resumeStoppedMoshServer()
            NSLog("[MoshContinuation] failure %@ phone=%@ ipad=%@ phonePainter=%@ ipadPainter=%@", String(describing: error),
                  String(describing: phone.controller.gridAuthority), String(describing: ipad.controller.gridAuthority),
                  phone.adapter.painterStateForTesting, ipad.adapter.painterStateForTesting)
            if let data = DiagnosticLogStore.attachmentData() {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
                attachment.name = "mosh-continuation-failure-diagnostics"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            for client in [phone, ipad] { attachGrid(client, label: "failure") }
            _ = try? await setup.executeConnectedCommand(cleanupCommand)
            throw error
        }
    }

    private struct TmuxGeometry: Equatable {
        let cols: Int
        let rows: Int
    }

    private func tmuxGeometry(
        sessionName: String,
        using session: SSHSession
    ) async throws -> TmuxGeometry {
        let output = try await session.executeConnectedCommand(
            "tmux display-message -p -t \(sessionName):0 '#{window_width}x#{window_height}'"
        )
        for token in output.split(whereSeparator: { $0.isWhitespace }).reversed() {
            let dimensions = token.split(separator: "x", omittingEmptySubsequences: false)
            if dimensions.count == 2,
               let cols = Int(dimensions[0]),
               let rows = Int(dimensions[1]) {
                return TmuxGeometry(cols: cols, rows: rows)
            }
        }
        throw IntegrationError.failed(
            "tmux returned an invalid geometry for \(sessionName): \(output.debugDescription)"
        )
    }

    private func waitForTmuxGeometry(
        _ expected: TmuxGeometry,
        sessionName: String,
        using session: SSHSession,
        operation: String,
        timeout: TimeInterval = 8
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastGeometry: TmuxGeometry?
        while Date() < deadline {
            lastGeometry = try await tmuxGeometry(
                sessionName: sessionName,
                using: session
            )
            if lastGeometry == expected { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.failed(
            "\(operation) expected \(expected.cols)x\(expected.rows), "
                + "got \(lastGeometry?.cols ?? -1)x\(lastGeometry?.rows ?? -1)"
        )
    }

    @MainActor
    private func waitForTmuxHydration(
        _ controller: TmuxController,
        operation: String,
        channel: TmuxControlChannel? = nil
    ) async throws {
        do {
            try await waitUntil(operation, timeout: 15) {
                controller.mode == .tmuxControl
                    && controller.isWindowListHydrated
                    && controller.activeWindowId != nil
                    && controller.activePaneId != nil
            }
        } catch {
            NSLog("[LiveTransport] hydration failed mode=%@ hydrated=%d channel=%@", String(describing: controller.mode), controller.isWindowListHydrated ? 1 : 0, String(describing: channel?.terminationReason))
            if let data = DiagnosticLogStore.attachmentData(), let log = String(data: data, encoding: .utf8) {
                for line in log.split(separator: "\n").filter({ $0.contains(DiagnosticLogCategory.mosh.rawValue) || $0.contains(DiagnosticLogCategory.tmux.rawValue) }).suffix(60) {
                    NSLog("[LiveTransport] %@", String(line))
                }
            }
            throw error
        }
    }

    /// tmux answers control commands in order, so a fence reply proves every
    /// earlier command (an attach or foreground authority read) was answered.
    @MainActor
    private func waitForControlFence(_ controller: TmuxController, operation: String) async throws {
        let marker = "TESSERA-FENCE-\(UUID().uuidString.prefix(8))"
        var result: Result<[String], TmuxController.CommandError>?
        controller.sendControlCommand("display-message -p '\(marker)'") { result = $0 }
        try await waitUntil("\(operation) control fence", timeout: 3) { result != nil }
        XCTAssertTrue(try XCTUnwrap(result).get().contains(marker), operation)
    }

    /// Phase 0a (S2'): attach never claims. Opening a displayed session is a
    /// show; it takes control and settles with a consumed authority frame.
    @MainActor
    private func showAndWaitForControl(_ controller: TmuxController, operation: String) async throws {
        controller.gridAuthorityShown()
        try await waitForShownControl(controller, operation: operation)
    }

    /// Waits for a show already delivered to `controller` to settle as mine.
    /// Live cases show first and only then wait for owner, painter or
    /// geometry evidence: the show is what takes control.
    @MainActor
    private func waitForShownControl(_ controller: TmuxController, operation: String) async throws {
        try await waitUntil("\(operation) show takes control", timeout: 5) {
            controller.gridAuthority == .mine
                && !controller.gridAuthorityReclaimInFlight
                && !controller.gridAuthorityHasPendingIntent
        }
    }

    @MainActor
    private func assertRawPayload<Session: TerminalSession>(
        session: Session,
        payload: [UInt8],
        expectedDigest: String,
        label: String,
        timeout: TimeInterval
    ) async throws {
        let runID = UUID().uuidString.lowercased()
        let output = "/var/lib/tessera-fixture/runs/\(runID)/\(label)-input.json"
        let command = "/usr/local/bin/tessera-fixture-probe capture"
            + " --output \(output)"
            + " --bytes \(payload.count)"
            + " --timeout \(timeout)"
            + " --expect-sha256 \(expectedDigest)"
            + " --mouse --bracketed-paste --alt-screen\n"
        session.send(Array(command.utf8))
        _ = try await waitForOutput(
            session.outputStream,
            containing: "TESSERA_CAPTURE_READY",
            timeout: timeout
        )
        session.send(payload)
        let completion = try await waitForOutput(
            session.outputStream,
            containing: "TESSERA_CAPTURE_COMPLETE",
            timeout: timeout
        )
        XCTAssertTrue(
            completion.contains("verdict=pass"),
            "\(label) PTY payload checksum failed: \(completion.debugDescription)"
        )
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

    @MainActor
    private func waitForHostKeyRequest(
        _ request: @escaping @MainActor () -> HostKeyVerificationRequest?,
        timeout: TimeInterval
    ) async throws -> HostKeyVerificationRequest {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = request() { return request }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut("host-key verification request")
    }

    @MainActor
    private struct LiveQRContinuation {
        let origin: CrossDevicePairingCoordinator
        let recipient: CrossDevicePairingCoordinator
        let continuationID: UUID
        let hostID: UUID
    }

    private struct QRLoopbackEndpoint: PairingLocalEndpointEnumerating {
        func candidates(port: UInt16) -> [PairingEndpointCandidateV1] {
            [PairingEndpointCandidateV1(host: "127.0.0.1", port: port)]
        }
    }

    /// Real QR codec, TCP and authenticated protocol; remote connections below
    /// use only the run-owned VPS fixture. This is not camera or UI evidence.
    @MainActor
    private func beginLiveQRContinuation(host: Host) async throws -> LiveQRContinuation {
        let descriptor = try SessionActivityDescriptor(
            host: host, resolvedTmuxSessionName: host.tmuxSessionName
        ).core
        let continuationID = UUID()
        var received: ContinuationDescriptorV1?
        let adapters = CrossDevicePairingPlatformAdapters(
            receiveDescriptor: { value, _ in received = value; return continuationID },
            cancelDescriptor: { _ in },
            recipientKey: { throw IntegrationError.failed("unexpected bootstrap") },
            exportManifest: { _ in throw IntegrationError.failed("unexpected bootstrap") },
            importManifest: { _, _ in throw IntegrationError.failed("unexpected import") },
            verifyGrants: { _ in XCTFail("continuation must not install keys"); return [] },
            recordAccess: { _, _, _ in XCTFail("continuation must not record grants") },
            freshOwnerApproval: { _ in throw IntegrationError.failed("unexpected grant") }
        )
        let origin = CrossDevicePairingCoordinator(adapters: adapters, listenerFactory: {
            PairingLocalTCPListener(endpointEnumerator: QRLoopbackEndpoint())
        })
        let recipient = CrossDevicePairingCoordinator(adapters: adapters)
        do {
            origin.beginOrigin(purpose: .continueSession, descriptor: descriptor)
            try await waitUntil("QR offer", timeout: 5) { origin.qrText != nil }
            recipient.beginRecipient(qrText: try XCTUnwrap(origin.qrText))
            try await waitUntil("QR comparison", timeout: 5) {
                if case .compareSAS = origin.phase, case .compareSAS = recipient.phase { return true }
                return false
            }
            XCTAssertEqual(origin.phase, recipient.phase)
            origin.decideSAS(matches: true)
            recipient.decideSAS(matches: true)
            try await waitUntil("QR descriptor", timeout: 5) { received != nil }
            XCTAssertEqual(try received?.encoded(), try descriptor.encoded())
            recipient.continuationDurablyAccepted(continuationID: continuationID, hostID: descriptor.hostID)
            // A late callback from an older connection cannot complete pairing.
            recipient.continuationConnectionCompleted(continuationID: UUID(), hostID: descriptor.hostID)
            try await Task.sleep(for: .milliseconds(100))
            if case .completed = origin.phase { XCTFail("completed before live connection") }
            return LiveQRContinuation(origin: origin, recipient: recipient,
                continuationID: continuationID, hostID: descriptor.hostID)
        } catch {
            origin.cancel(); recipient.cancel()
            throw error
        }
    }

    @MainActor
    private func completeLiveQRContinuation(_ pairing: LiveQRContinuation) async throws {
        pairing.recipient.continuationConnectionCompleted(
            continuationID: pairing.continuationID, hostID: pairing.hostID
        )
        try await waitUntil("QR live connection receipt", timeout: 5) {
            if case .completed = pairing.origin.phase, case .completed = pairing.recipient.phase { return true }
            return false
        }
    }

    @MainActor
    private func connect<Session: TerminalSession>(
        session: Session,
        pendingRequest: @escaping @MainActor () -> HostKeyVerificationRequest?,
        timeout: TimeInterval
    ) async throws -> Bool {
        session.connect()
        let deadline = Date().addingTimeInterval(timeout)
        var sawTOFU = false

        while Date() < deadline {
            if let request = pendingRequest() {
                sawTOFU = true
                XCTAssertFalse(request.fingerprint.isEmpty)
                XCTAssertFalse(request.keyType.isEmpty)
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
            switch state() {
            case .failed(let message):
                return message
            case .idle, .connecting, .connected, .disconnected:
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationError.timedOut("authentication failure")
    }

    /// A `printf` of `marker` whose typed command line never contains the
    /// marker verbatim. The setup shell is a PTY, so it echoes what is typed;
    /// waiting for a marker that the echo already carries returns before the
    /// commands ahead of it have run, and the deferred disconnect then hangs
    /// up on a half-finished cleanup (a `tessera-side-*-b` session was left
    /// on the fixture that way, which the Android gate refuses to share a
    /// server with).
    private func unechoedPrintf(_ marker: String) -> String {
        let split = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        return "printf '%s%s\\n' '\(marker[..<split])' '\(marker[split...])'"
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
                    if text.contains(marker) {
                        return text
                    }
                    if text.utf8.count > 256 * 1024 {
                        text = String(text.suffix(128 * 1024))
                    }
                }
                throw IntegrationError.streamEnded(marker)
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
                throw IntegrationError.timedOut("output marker \(marker)")
            }

            guard let value = try await group.next() else {
                throw IntegrationError.streamEnded(marker)
            }
            group.cancelAll()
            return value
        }
    }

    private func collectOutputChunks(
        _ stream: AsyncStream<[UInt8]>,
        containing marker: String,
        timeout: TimeInterval
    ) async throws -> [[UInt8]] {
        try await withThrowingTaskGroup(of: [[UInt8]].self) { group in
            group.addTask {
                var chunks: [[UInt8]] = []
                var markerWindow = ""
                for await bytes in stream {
                    chunks.append(bytes)
                    markerWindow += String(decoding: bytes, as: UTF8.self)
                    if markerWindow.contains(marker) {
                        return chunks
                    }
                    if markerWindow.utf8.count > 16 * 1_024 {
                        markerWindow = String(markerWindow.suffix(8 * 1_024))
                    }
                }
                throw IntegrationError.streamEnded(marker)
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
                throw IntegrationError.timedOut("output marker \(marker)")
            }

            guard let value = try await group.next() else {
                throw IntegrationError.streamEnded(marker)
            }
            group.cancelAll()
            return value
        }
    }

    private func timePrintableFilter(
        _ chunks: [[UInt8]]
    ) -> (milliseconds: Double, checksum: Int) {
        let start = ContinuousClock.now
        var filter = TerminalOutputContrastFilter()
        var checksum = 0
        for chunk in chunks {
            let output = filter.process(
                chunk[...],
                defaultBackgroundRGB: 0x101010,
                defaultForegroundRGB: 0xD4D4D4,
                minimumContrast: 0.30
            )
            checksum &+= output.count
            checksum &+= Int(output.first ?? 0)
            checksum &+= Int(output.last ?? 0)
        }
        return (millisecondsSince(start), checksum)
    }

    private func millisecondsSince(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    /// Names a tmux session a test drives over mosh. Under
    /// run-app-transport-tests.sh it carries that run's prefix
    /// (`TESSERA_REAL_HOST_RUN_SESSION_PREFIX`), so the lane's cleanup can
    /// prove the session, its `-view` and every mosh-server naming them are
    /// this run's and reap them when this process dies before its own
    /// cleanup: a mosh-server whose client is gone never exits on its own.
    private func runOwnedTmuxSessionName(_ kind: String, token: String) throws -> String {
        guard let prefix = ProcessInfo.processInfo.environment["TESSERA_REAL_HOST_RUN_SESSION_PREFIX"] else {
            return "tessera-\(kind)-\(token)"
        }
        guard prefix.hasPrefix("tessera-"), prefix.utf8.count <= 48,
              prefix.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122) || byte == 45
              })
        else {
            throw IntegrationError.failed("TESSERA_REAL_HOST_RUN_SESSION_PREFIX is not a cleanup-safe run prefix")
        }
        return "\(prefix)-\(kind)-\(token)"
    }

    /// A mosh-server a test pauses with SIGSTOP, identified by PID and kernel
    /// start time (field 22 of /proc/PID/stat) so that neither the pause nor
    /// the resume can reach a recycled PID.
    private struct StoppedMoshServer {
        let pid: Int
        let startTicks: String
    }

    private enum MoshServerSignalOutcome: Equatable {
        /// The signal reached exactly that process.
        case confirmed
        /// That process no longer exists, so nothing is left stopped.
        case absent
    }

    private func moshServerIdentity(_ pid: Int, using session: SSHSession) async throws -> StoppedMoshServer {
        // The marker word is assembled by printf so the typed command, which
        // an interactive shell may echo, can never satisfy the parse below.
        let output = try await session.executeConnectedCommand(
            "p=\(pid); test \"$(cat /proc/$p/comm 2>/dev/null)\" = mosh-server && "
                + "printf 'TESSERA_MOSH_%s pid=%s start=%s\\n' IDENTITY \"$p\" "
                + "\"$(sed 's/.*) //' /proc/$p/stat | awk '{print $20}')\""
        )
        let marker = "TESSERA_MOSH_IDENTITY pid=\(pid) start="
        guard let range = output.range(of: marker) else {
            throw IntegrationError.failed("mosh-server \(pid) identity unavailable: \(output)")
        }
        let start = String(output[range.upperBound...].prefix { $0.isNumber })
        guard !start.isEmpty, start != "0" else {
            throw IntegrationError.failed("mosh-server \(pid) start time unavailable: \(output)")
        }
        return StoppedMoshServer(pid: pid, startTicks: start)
    }

    /// Sends SIGSTOP or SIGCONT to exactly `server` and returns only on the
    /// host's word: `confirmed` once kill succeeded against that PID and
    /// start time, `absent` once the process is gone. A reply with neither
    /// throws, so a caller never releases a resume obligation on a guess.
    private func signalMoshServer(
        _ server: StoppedMoshServer,
        _ signal: String,
        using session: SSHSession
    ) async throws -> MoshServerSignalOutcome {
        precondition(signal == "STOP" || signal == "CONT")
        let output = try await session.executeConnectedCommand(
            "p=\(server.pid); s=\"$(sed 's/.*) //' /proc/$p/stat 2>/dev/null | awk '{print $20}')\"; "
                + "if [ \"$s\" != '\(server.startTicks)' ]; then printf 'TESSERA_MOSH_%s pid=%s\\n' ABSENT \"$p\"; "
                + "elif kill -\(signal) \"$p\"; then printf 'TESSERA_MOSH_%s_OK pid=%s\\n' \(signal) \"$p\"; fi"
        )
        if output.contains("TESSERA_MOSH_\(signal)_OK pid=\(server.pid)\n")
            || output.contains("TESSERA_MOSH_\(signal)_OK pid=\(server.pid)\r") {
            return .confirmed
        }
        if output.contains("TESSERA_MOSH_ABSENT pid=\(server.pid)\n")
            || output.contains("TESSERA_MOSH_ABSENT pid=\(server.pid)\r") {
            return .absent
        }
        throw IntegrationError.failed("mosh-server \(server.pid) did not confirm SIG\(signal): \(output)")
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func integerValue(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
#endif
