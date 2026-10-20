#if DEBUG
import Network
import SwiftUI
import PortForwarding

/// `TESSERA_TUNNEL_BROWSER_HARNESS=1` — the tunnel chip and its status sheet,
/// standing on a real loopback web server instead of a real host.
///
/// The affordance under test only appears for a *live* forwarder, and reaching
/// one the honest way means dialling a host — which no automated run may do.
/// So the harness supplies both halves of what a tunnel actually is: three
/// forwarders forced into the states the sheet distinguishes, and an HTTP
/// server on loopback port 8080 that answers exactly as a forwarded dev server
/// would. From `WKWebView`'s side of the socket the two are the same thing, so
/// ATS, the scheme, the chrome, and the back/forward history are all exercised
/// for real.
///
/// The same server stands in for the far side of the tunnel when the chip asks
/// whether anything is serving there: the dev-server rule's probe dials the
/// server's own port instead of an SSH channel, and a toggle stops and starts
/// the server, so the glyph's serving/nothing-serving transition is driven by
/// a real listener going away and coming back.
struct TunnelBrowserHarnessView: View {
    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var manager = PortForwarderManager()
    @State private var server = HarnessLoopbackWebServer()
    @State private var seeded = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider().overlay(T.border)
            notes
            Spacer()
        }
        .safeAreaPadding(.top)
        .background(T.bg)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            seed()
            server.start(port: 8_080)
        }
    }

    /// A stand-in for `SessionTopBar`: the glyph renders exactly as it does
    /// there, at the same scale, so a screenshot of this bar is a screenshot
    /// of the real one. A compact width gets the phone bar's icon button, as
    /// `SessionTmuxChrome` does, so the iPhone run covers that button.
    private var bar: some View {
        HStack(spacing: 8) {
            Text(verbatim: "tunnel browser harness")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
            Spacer()
            Button {
                if server.isRunning {
                    server.stop()
                } else {
                    server.start(port: 8_080)
                }
            } label: {
                Text(verbatim: server.isRunning ? "stop server" : "start server")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.accent)
            }
            .accessibilityIdentifier("harness-toggle-server")
            if sizeClass == .compact {
                CompactForwardingStatusButton(manager: manager, T: T)
                    .accessibilityIdentifier("harness-forwarding-chip")
            } else {
                ForwardingStatusChip(manager: manager, scale: 1, T: T)
                    .accessibilityIdentifier("harness-forwarding-chip")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: sizeClass == .compact ? 44 : 28)
        .background(T.panelBg)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            note("8080 \u{2192} 3000", "listening, browsable — serving while the loopback server runs")
            note("15432 \u{2192} 5432", "listening, postgres — no browse button")
            note("9090 \u{2192} 9090", "idle — addressable but nothing is listening")
            Text(verbatim: server.status)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.accent)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private func note(_ rule: String, _ expectation: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: rule)
                .font(Typography.tesseraMono(size: 12, weight: .medium))
                .foregroundStyle(T.fg)
                .frame(width: 130, alignment: .leading)
            Text(verbatim: expectation)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
        }
    }

    private func seed() {
        let cases: [(PortForwardRule, PortForwarder.State)] = [
            (
                PortForwardRule.localForward(
                    localPort: 8_080,
                    remotePort: 3_000,
                    label: "dev server"
                ),
                // Listening, not active: a connection in flight would prove
                // the service on its own and the probe would never run.
                .listening
            ),
            (
                PortForwardRule.localForward(
                    localPort: 15_432,
                    remotePort: 5_432,
                    label: "postgres"
                ),
                .listening
            ),
            (
                PortForwardRule.localForward(
                    localPort: 9_090,
                    remotePort: 9_090,
                    label: "metrics"
                ),
                .idle
            ),
        ]
        for (rule, state) in cases {
            let forwarder = PortForwarder(rule: rule)
            forwarder.harnessForceState(state)
            // The harness's "remote" is its own loopback server, which
            // listens on the bind port; dial that rather than the target.
            let port = rule.bind.port
            forwarder.harnessServiceProbe = { _ in await HarnessLoopbackProbe.probe(port: port) }
            manager.harnessInsert(forwarder)
        }
    }
}

/// A TCP connect to loopback standing in for the SSH server's direct-tcpip
/// open: accepted is serving, refused is not.
enum HarnessLoopbackProbe {
    static func probe(port: UInt16) async -> ForwardedServiceProbeResult {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .inconclusive }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let answered = HarnessOnce()
            func answer(_ result: ForwardedServiceProbeResult) {
                guard answered.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: answer(.serving)
                // A refused loopback connect parks in `.waiting` rather than
                // failing outright.
                case .waiting, .failed: answer(.notServing)
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { answer(.inconclusive) }
        }
    }
}

/// First-caller-wins latch; everything above runs on the main queue.
private final class HarnessOnce: @unchecked Sendable {
    private var claimed = false
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// A minimal HTTP/1.1 server on loopback, standing where a forwarded port's
/// listener would stand. Two pages, so the browser's back and forward buttons
/// have real history to move through.
@Observable
@MainActor
final class HarnessLoopbackWebServer {
    private(set) var status = "server: not started"
    private(set) var isRunning = false

    @ObservationIgnored private var listener: NWListener?

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        status = "server: stopped"
    }

    func start(port: UInt16) {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.status = "server: listening on 127.0.0.1:\(port)"
                    case .failed(let error):
                        self.status = "server: failed — \(error)"
                        // A listener that never bound is not running: clear it
                        // so the toggle says so and the next start can retry.
                        // Only this one — a stop and restart may have
                        // replaced it already.
                        guard let listener, self.listener === listener else { return }
                        listener.cancel()
                        self.listener = nil
                        self.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            isRunning = true
        } catch {
            status = "server: could not bind \(port) — \(error)"
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request
                .split(separator: "\r\n", maxSplits: 1).first?
                .split(separator: " ").dropFirst().first
                .map(String.init) ?? "/"
            let body = Self.page(for: path)
            let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func page(for path: String) -> String {
        let second = path.hasPrefix("/second")
        let heading = second ? "second page" : "tunnelled dev server"
        return """
            <!doctype html><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
              body{font:16px -apple-system,system-ui,sans-serif;margin:0;padding:32px;
                   background:#101014;color:#e8e8ec}
              h1{font-size:22px;margin:0 0 6px}
              code{font-family:ui-monospace,Menlo,monospace;color:#7aa2f7}
              a{color:#7aa2f7}
              .card{border:1px solid #2a2a33;border-radius:10px;padding:18px;margin-top:20px}
            </style>
            <h1>\(heading)</h1>
            <div>served over loopback at <code>\(path)</code></div>
            <div class="card">
              <div>this page is what a forwarded port looks like from inside Tessera.</div>
              <p><a href="\(second ? "/" : "/second")">\(second ? "back to index" : "open the second page")</a></p>
            </div>
            """
    }
}
#endif
