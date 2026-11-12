import Citadel
import Foundation
import Observation
import PortForwarding

@MainActor
@Observable
public final class PortForwarderManager {
    public private(set) var forwarders: [UUID: PortForwarder] = [:]

    /// SSH client retained from the most recent `attach(...)` call so
    /// `reconcile(...)` can spin up forwarders for newly added rules
    /// without the editor having to thread the client through.
    @ObservationIgnored
    private var client: SSHClient?

    @ObservationIgnored private var clientGeneration = 0
    private var ephemeralForwarders: [UUID: PortForwarder] = [:]

    public private(set) var canStartEphemeral = false

    public func startEphemeral(_ plannedRule: PortForwardRule) async throws -> PortForwarder {
        guard let client else { throw CancellationError() }
        let generation = clientGeneration
        let rule = PortForwardRule(id: UUID(), enabled: plannedRule.enabled, autoStart: plannedRule.autoStart,
                                   direction: plannedRule.direction, bind: plannedRule.bind,
                                   target: plannedRule.target, label: plannedRule.label)
        let forwarder = PortForwarder(rule: rule)
        ephemeralForwarders[rule.id] = forwarder
        do {
            try await forwarder.startEphemeral(over: client)
            guard generation == clientGeneration, self.client != nil, !Task.isCancelled,
                  ephemeralForwarders[rule.id] === forwarder else { throw CancellationError() }
            return forwarder
        } catch {
            ephemeralForwarders.removeValue(forKey: rule.id)
            await forwarder.stop()
            throw error
        }
    }

    public func stopEphemeral(_ id: UUID) async {
        guard let forwarder = ephemeralForwarders.removeValue(forKey: id) else { return }
        await forwarder.stop()
    }

    /// Keeping a tab's forward transfers the existing listener into the
    /// saved-rule map. Reconciliation must not bind the same port twice.
    public func promoteEphemeral(_ id: UUID, to rule: PortForwardRule) {
        guard let forwarder = ephemeralForwarders.removeValue(forKey: id) else { return }
        forwarder.update(rule: rule)
        forwarders[rule.id] = forwarder
    }

    public init() {}

    #if DEBUG
    /// Harness-only: seed the map without an SSH client. See
    /// `PortForwarder.harnessForceState`.
    public func harnessInsert(_ forwarder: PortForwarder, ephemeral: Bool = false) {
        if ephemeral {
            ephemeralForwarders[forwarder.id] = forwarder
        } else {
            forwarders[forwarder.id] = forwarder
        }
    }
    #endif

    /// Called from inside SSHSession.run once the SSHClient is established.
    /// Spawns one PortForwarder per `enabled && autoStart` rule.
    /// Idempotent — calling twice with the same rules is a no-op.
    public func attach(to client: SSHClient, rules: [PortForwardRule]) {
        clientGeneration &+= 1
        self.client = client
        canStartEphemeral = true
        for rule in rules where rule.enabled && rule.autoStart {
            let forwarder = forwarders[rule.id] ?? PortForwarder(rule: rule)
            forwarder.update(rule: rule)
            forwarders[rule.id] = forwarder
            forwarder.start(over: client)
        }
    }

    /// Apply a new rule set to a session that's already connected.
    /// Diffs by `rule.id` against the current forwarder map and:
    ///   - stops + drops removed rules
    ///   - starts newly added rules (if enabled)
    ///   - on enabled flip: starts or stops as needed
    ///   - on local-port change: stops the existing listener and restarts on the new port (closes any active connections through it)
    ///   - on remote / label / autoStart change: updates the rule in place without disrupting traffic
    ///
    /// The shared model also offers `PortForwardRule.requiresRestart(other:)`,
    /// which additionally restarts on a direction or target change. Adopting it
    /// here is a one-line swap, deliberately not taken this round: it would
    /// drop live connections on a target edit, which this reconciler has always
    /// carried through (each accept re-reads the rule's current target).
    public func reconcile(newRules: [PortForwardRule]) async {
        let oldByID = self.forwarders
        let newByID: [UUID: PortForwardRule] = Dictionary(uniqueKeysWithValues: newRules.map { ($0.id, $0) })

        for (id, fwd) in oldByID where newByID[id] == nil {
            DiagnosticLogStore.appendForwarding("reconcile remove rule=\(Self.shortID(id)) localPort=\(fwd.rule.bind.port)")
            await fwd.stop()
            forwarders.removeValue(forKey: id)
        }

        for (id, rule) in newByID where oldByID[id] == nil {
            DiagnosticLogStore.appendForwarding("reconcile add rule=\(Self.shortID(id)) enabled=\(rule.enabled) localPort=\(rule.bind.port)")
            guard rule.enabled, let client else { continue }
            let fwd = PortForwarder(rule: rule)
            forwarders[id] = fwd
            fwd.start(over: client)
        }

        for (id, newRule) in newByID {
            guard let fwd = oldByID[id] else { continue }
            let oldRule = fwd.rule
            guard oldRule != newRule else { continue }

            let portChanged = oldRule.bind.port != newRule.bind.port
            let oldEnabled = oldRule.enabled
            let newEnabled = newRule.enabled
            DiagnosticLogStore.appendForwarding(
                "reconcile update rule=\(Self.shortID(id)) portChanged=\(portChanged) enabledFlip=\(oldEnabled)->\(newEnabled)"
            )

            switch (oldEnabled, newEnabled, portChanged) {
            case (_, false, _):
                await fwd.stop()
                fwd.update(rule: newRule)

            case (false, true, _):
                fwd.update(rule: newRule)
                if let client { fwd.start(over: client) }

            case (true, true, true):
                await fwd.stop()
                fwd.update(rule: newRule)
                if let client { fwd.start(over: client) }

            case (true, true, false):
                fwd.update(rule: newRule)
            }
        }
    }

    /// Tear-down hook called when the SSH session ends.
    public func detach() async {
        clientGeneration &+= 1
        client = nil
        canStartEphemeral = false
        let stopping = Array(forwarders.values) + Array(ephemeralForwarders.values)
        forwarders.removeAll()
        ephemeralForwarders.removeAll()
        for forwarder in stopping {
            await forwarder.stop()
        }
    }

    /// Total connections currently active across all rules in this session.
    public var activeConnectionCount: Int {
        forwarders.values.reduce(0) { partial, forwarder in
            if case .active(let n) = forwarder.state { return partial + n }
            return partial
        }
    }

    /// Number of forwarders currently listening (running, regardless of in-flight connections).
    public var runningCount: Int {
        forwarders.values.reduce(0) { partial, forwarder in
            switch forwarder.state {
            case .listening, .active: return partial + 1
            case .idle, .error:       return partial
            }
        }
    }

    /// Rules and tab-owned ephemeral forwards that are listening or carrying
    /// traffic. The status chip and background task count rules only.
    public var hasLiveForwards: Bool {
        (Array(forwarders.values) + Array(ephemeralForwarders.values)).contains { forwarder in
            switch forwarder.state {
            case .listening, .active: return true
            case .idle, .error:       return false
            }
        }
    }

    /// True if any forwarder is in `.error`.
    public var hasError: Bool {
        forwarders.values.contains { if case .error = $0.state { return true } else { return false } }
    }

    /// Live forwarders with something known to answer behind them.
    public var servingCount: Int {
        forwarders.values.reduce(0) { $0 + ($1.isServing ? 1 : 0) }
    }

    /// Looks at each forward's target on its cadence until the calling task
    /// is cancelled. Run it only while someone can see the answer — the
    /// session's bar on screen with the app in front, or the Tunnels page —
    /// since each look is a real connection to the target. Callers may
    /// overlap: a forwarder never has two probes in flight, and the cadence
    /// is per forwarder, not per caller.
    public func monitorServices() async {
        for forwarder in forwarders.values {
            forwarder.restartServiceCadence()
        }
        while !Task.isCancelled {
            probeServices(force: false)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Looks at every eligible target now, cadence aside — for a surface that
    /// just opened to show per-tunnel detail.
    public func probeServicesNow() {
        for forwarder in forwarders.values {
            forwarder.restartServiceCadence()
        }
        probeServices(force: true)
    }

    private func probeServices(force: Bool) {
        let now = ContinuousClock.now
        for forwarder in forwarders.values {
            forwarder.probeServiceIfDue(now: now, force: force)
        }
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
