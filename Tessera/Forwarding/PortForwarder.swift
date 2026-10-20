import Citadel
import Foundation
import Network
import NIOCore
import Observation
import PortForwarding

@MainActor
@Observable
public final class PortForwarder: Identifiable {
    public enum State: Equatable {
        case idle
        case listening
        case active(connectionCount: Int)
        case error(reason: String)
    }

    public var id: UUID { rule.id }

    public private(set) var rule: PortForwardRule
    public private(set) var state: State = .idle
    public private(set) var bytesUp: UInt64 = 0
    public private(set) var bytesDown: UInt64 = 0

    /// Whether anything answers at this rule's target. Meaningful only while
    /// the listener is live, and reset whenever the forward stops, restarts,
    /// or is pointed somewhere else.
    public private(set) var service: ForwardedServiceState = .unknown

    /// The SSH server answered a probe by refusing direct-tcpip outright.
    public private(set) var forwardingProhibited = false

    private let listener = PortListener()

    @ObservationIgnored
    private var connections: Set<PortForwardConnection> = []

    @ObservationIgnored
    private var serveTask: Task<Void, Never>?

    /// The client this forwarder dials through, kept for service probes.
    @ObservationIgnored
    private var client: SSHClient?

    @ObservationIgnored
    private var serviceCheckedAt: ContinuousClock.Instant?

    @ObservationIgnored
    private var serviceProbeInFlight = false

    /// Looks in a row that did not see the target answer; see
    /// `ForwardedServiceCadence.unconfirmedBurst`.
    @ObservationIgnored
    private var unconfirmedStreak = 0

    /// Looks in a row that got no answer at all; see
    /// `ForwardedServiceCadence.inconclusiveLooksBeforeUnknown`.
    @ObservationIgnored
    private var inconclusiveStreak = 0

    /// Bumped by every service reset, so evidence gathered about the rule as
    /// it was before — a probe or a connection still in flight across a stop
    /// or a target edit — lands nowhere.
    @ObservationIgnored
    private var serviceEpoch = 0

    public init(rule: PortForwardRule) {
        self.rule = rule
    }

    #if DEBUG
    /// Stands a forwarder in the state an SSH-backed `start` would have
    /// produced. The tunnel-browser harness needs a *listening* forwarder to
    /// exercise the status sheet, and reaching one the honest way would mean
    /// opening a connection to a real host — which the harness exists to
    /// avoid.
    public func harnessForceState(_ forced: State) {
        state = forced
    }

    /// Answers service probes in place of the SSH client, for forwarders
    /// that `harnessForceState` stood up without one.
    @ObservationIgnored
    var harnessServiceProbe: ((PortForwardEndpoint) async -> ForwardedServiceProbeResult)?

    var probeInFlightForTesting: Bool { serviceProbeInFlight }
    #endif

    /// Something is known to answer behind this live forward. A connection in
    /// flight is its own proof: it exists only because the SSH server's open
    /// to the target succeeded.
    public var isServing: Bool {
        switch state {
        case .active: return true
        case .listening: return service == .serving
        case .idle, .error: return false
        }
    }

    /// Whether this rule's target is watched at all: looked at on a cadence,
    /// and told about by its real connections in between.
    ///
    /// Only rules the shared policy calls plain-HTTP pages are. A
    /// connect-and-close every few seconds is silent to an HTTP server, but
    /// postgres logs an incomplete startup packet for each one, MySQL counts
    /// each toward `max_connect_errors` and then blocks a non-loopback client
    /// outright, and Go's HTTPS server logs a TLS handshake error — into the
    /// dev server's output, in the terminal the user is watching. Any other
    /// rule is serving only while a connection is in flight: with nothing to
    /// refresh it, what one connection learned an hour ago would still be
    /// colouring the glyph.
    var watchesService: Bool {
        rule.direction == .local
            && rule.target != nil
            && ForwardedWebPolicy.webTarget(for: rule)?.scheme == "http"
    }

    /// Whether the target may be probed now: a watched rule whose listener is
    /// up with nothing in flight — a connection in flight is its own answer.
    var probesServiceActively: Bool {
        guard case .listening = state else { return false }
        return watchesService
    }

    /// Someone just started looking: unconfirmed targets are looked at
    /// quickly again rather than at the backed-off cadence.
    func restartServiceCadence() {
        unconfirmedStreak = 0
    }

    /// Probes the target when its cadence says so, or at once when `force`d;
    /// never with a probe already in flight.
    func probeServiceIfDue(now: ContinuousClock.Instant, force: Bool = false) {
        guard probesServiceActively, !serviceProbeInFlight, let target = rule.target else { return }
        guard force || ForwardedServiceCadence.isDue(
            service: service,
            forwardingProhibited: forwardingProhibited,
            unconfirmedStreak: unconfirmedStreak,
            lastChecked: serviceCheckedAt,
            now: now
        ) else { return }

        let probe: (PortForwardEndpoint) async -> ForwardedServiceProbeResult
        #if DEBUG
        if let harnessServiceProbe {
            probe = harnessServiceProbe
        } else if let client {
            probe = { await probeForwardedService(over: client, target: $0) }
        } else {
            return
        }
        #else
        guard let client else { return }
        probe = { await probeForwardedService(over: client, target: $0) }
        #endif

        serviceProbeInFlight = true
        let epoch = serviceEpoch
        Task { @MainActor [weak self] in
            let result = await probe(target)
            guard let self else { return }
            // Cleared whatever the epoch: a probe outliving a reset still
            // holds the one slot, so a restart cannot run two at once.
            self.serviceProbeInFlight = false
            self.recordService(result, epoch: epoch, via: "probe")
        }
    }

    private func recordService(_ result: ForwardedServiceProbeResult, epoch: Int, via source: String) {
        guard epoch == serviceEpoch else { return }
        // Inconclusive still counts as a look, so a target that times out is
        // asked again on the cadence rather than on every tick.
        serviceCheckedAt = .now

        if result == .serving {
            unconfirmedStreak = 0
        } else {
            unconfirmedStreak += 1
        }

        let next: ForwardedServiceState
        let prohibited: Bool
        switch result {
        case .serving:
            (next, prohibited) = (.serving, false)
        case .notServing:
            (next, prohibited) = (.notServing, false)
        case .forwardingProhibited:
            (next, prohibited) = (.unknown, true)
        case .inconclusive:
            inconclusiveStreak += 1
            guard inconclusiveStreak >= ForwardedServiceCadence.inconclusiveLooksBeforeUnknown else { return }
            (next, prohibited) = (.unknown, forwardingProhibited)
        }
        if result != .inconclusive {
            inconclusiveStreak = 0
        }

        if prohibited != forwardingProhibited {
            forwardingProhibited = prohibited
        }
        guard next != service else { return }
        DiagnosticLogStore.appendForwarding(
            "service \(next) rule=\(ruleShortID) targetPort=\(rule.targetPortLogText) prohibited=\(prohibited) via=\(source)"
        )
        service = next
    }

    private func resetService() {
        serviceEpoch &+= 1
        serviceCheckedAt = nil
        unconfirmedStreak = 0
        inconclusiveStreak = 0
        if forwardingProhibited { forwardingProhibited = false }
        if service != .unknown { service = .unknown }
    }

    public func start(over client: SSHClient) {
        resetService()
        self.client = client

        // The shared model admits remote (`-R`) and dynamic (SOCKS) forwards;
        // this runtime implements only the local (`-L`) one. Nothing on iOS
        // stores another direction today — the editor and the bootstrap
        // importer both produce loopback local forwards — but a rule arriving
        // from a platform that does would otherwise silently open a *local*
        // listener on a server-side bind port and forward the wrong way.
        guard rule.direction == .local else {
            DiagnosticLogStore.appendForwarding(
                "rule skipped rule=\(ruleShortID) direction=\(rule.direction.rawValue) reason='only local forwards run on iOS'"
            )
            serveTask?.cancel()
            serveTask = nil
            listener.stop()
            state = .idle
            return
        }

        DiagnosticLogStore.appendForwarding(
            "rule start rule=\(ruleShortID) localPort=\(rule.bind.port) targetPort=\(rule.targetPortLogText)"
        )

        serveTask?.cancel()
        listener.stop()
        state = .listening

        let listener = self.listener
        // iOS forwards are local-only this round: the listener always binds
        // loopback, so only the bind port reaches `PortListener`.
        let localPort = rule.bind.port

        serveTask = Task { @MainActor [weak self, listener, client] in
            do {
                let acceptedConnections = try await listener.listen(port: localPort)
                DiagnosticLogStore.appendForwarding("rule listening rule=\(self?.ruleShortID ?? "unknown") localPort=\(localPort)")

                for try await accepted in acceptedConnections {
                    if Task.isCancelled {
                        accepted.connection.cancel()
                        break
                    }

                    guard let currentRule = self?.rule else {
                        accepted.connection.cancel()
                        continue
                    }

                    let connectionID = UUID()
                    let connectionLogID = String(connectionID.uuidString.prefix(8))
                    let ruleLogID = String(currentRule.id.uuidString.prefix(8))
                    DiagnosticLogStore.appendForwarding(
                        "connection accepted id=\(connectionLogID) rule=\(ruleLogID) localPort=\(currentRule.bind.port) targetPort=\(currentRule.targetPortLogText)"
                    )

                    guard let currentTarget = currentRule.target else {
                        // Only a dynamic rule has no target, and the iOS editor
                        // cannot produce one yet. Refuse the connection rather
                        // than dialing a guessed endpoint.
                        DiagnosticLogStore.appendForwarding(
                            "connection refused id=\(connectionLogID) rule=\(ruleLogID) reason='rule has no target'"
                        )
                        accepted.connection.cancel()
                        continue
                    }

                    // A real connection is the best evidence there is about
                    // a watched target, and it arrives between probes.
                    let serviceEpoch = self?.watchesService == true ? self?.serviceEpoch : nil

                    do {
                        let remote = try await openDirectTCPIP(
                            over: client,
                            remoteHost: currentTarget.host,
                            remotePort: currentTarget.port,
                            debugID: connectionID
                        )

                        if let serviceEpoch {
                            self?.recordService(.serving, epoch: serviceEpoch, via: "connection")
                        }

                        if Task.isCancelled {
                            accepted.connection.cancel()
                            await Self.closeRemote(remote)
                            break
                        }

                        guard let self else {
                            accepted.connection.cancel()
                            await Self.closeRemote(remote)
                            continue
                        }

                        let conn = PortForwardConnection(
                            id: connectionID,
                            local: accepted.connection,
                            remote: remote
                        )

                        conn.onClose = { [weak self, weak conn] in
                            guard let self, let conn else {
                                return
                            }

                            self.bytesUp += conn.bytesUp
                            self.bytesDown += conn.bytesDown
                            self.removeConnection(conn)
                        }

                        connections.insert(conn)
                        refreshState()

                        Task { @MainActor [conn, accepted] in
                            do {
                                try await conn.start()
                            } catch {
                                DiagnosticLogStore.appendForwarding(
                                    "connection task failed id=\(String(conn.id.uuidString.prefix(8))) error='\(error)'"
                                )
                                accepted.connection.cancel()
                            }
                        }
                    } catch {
                        DiagnosticLogStore.appendForwarding(
                            "connection open failed id=\(connectionLogID) rule=\(ruleLogID) targetPort=\(currentRule.targetPortLogText) error='\(error)'"
                        )
                        accepted.connection.cancel()
                        if let serviceEpoch {
                            self?.recordService(.classifying(error), epoch: serviceEpoch, via: "connection")
                        }

                        if Task.isCancelled {
                            break
                        }

                        continue
                    }
                }
            } catch let listenerError as PortListenerError {
                guard !Task.isCancelled else {
                    return
                }

                DiagnosticLogStore.appendForwarding("rule listener-error localPort=\(localPort) error='\(listenerError)'")
                self?.resetService()
                self?.state = .error(reason: self?.describe(listenerError) ?? listenerError.localizedDescription)
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                DiagnosticLogStore.appendForwarding("rule listener-unexpected-error localPort=\(localPort) error='\(error)'")
                self?.resetService()
                self?.state = .error(reason: error.localizedDescription)
            }
        }
    }

    public func stop() async {
        DiagnosticLogStore.appendForwarding("rule stop rule=\(ruleShortID) localPort=\(rule.bind.port) activeConnections=\(connections.count)")

        serveTask?.cancel()
        serveTask = nil
        listener.stop()

        let activeConnections = connections
        for conn in activeConnections {
            await conn.close()
        }

        connections.removeAll()
        resetService()
        client = nil
        state = .idle
    }

    private func removeConnection(_ conn: PortForwardConnection) {
        connections.remove(conn)

        guard state != .idle else {
            return
        }

        refreshState()
    }

    private func refreshState() {
        if connections.isEmpty {
            state = .listening
        } else {
            state = .active(connectionCount: connections.count)
        }
    }

    public func update(rule: PortForwardRule) {
        // Each accept re-reads the target, so an edit takes effect without a
        // restart — and what was learned about the old target means nothing.
        // A rule that stops being watched is never looked at again, so what
        // it last learned would colour the glyph for good.
        let wasWatched = watchesService
        let retargeted = rule.target != self.rule.target || rule.direction != self.rule.direction
        self.rule = rule
        if retargeted || watchesService != wasWatched {
            resetService()
        }
    }

    private func describe(_ error: PortListenerError) -> String {
        switch error {
        case .portInUse(let port):
            // A port is an identifier, not a quantity: interpolated as a
            // number it would be grouped by locale ("8,080").
            return String(
                localized: "Port \(String(port)) is already in use.",
                comment: "Port forwarding failure; the argument is a TCP port number"
            )
        case .bindFailed(let reason):
            return String(
                localized: "Bind failed: \(reason)",
                comment: "Port forwarding failure; the argument is a system error"
            )
        case .cancelled:
            return String(localized: "Listener cancelled.")
        }
    }

    private static func closeRemote(_ remote: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        remote.outbound.finish()
        try? await remote.channel.close().get()
    }

    private var ruleShortID: String {
        String(rule.id.uuidString.prefix(8))
    }
}

private extension PortForwardRule {
    /// The target as forwarding diagnostics may carry it: the port alone,
    /// under the `targetPort=` key `DirectTCPIPChannel` already uses.
    ///
    /// Two constraints meet here, and both point at the same spelling.
    /// `DiagnosticLogStore.sanitizationRules` redacts the value of any
    /// `target=` field, so writing `target=host:port` silently dropped the
    /// port out of a log the user sends to a developer — a `targetPort=`
    /// integer is what survived before the shared endpoint model arrived, and
    /// still does. And the host stays out of the line by the same rule that
    /// makes `host=` elsewhere a short id rather than a hostname: a forward's
    /// target is often an internal name, and this file is written at a level
    /// that lands in the log with verbose diagnostics off.
    var targetPortLogText: String {
        guard let target else { return "none" }
        return String(target.port)
    }
}
