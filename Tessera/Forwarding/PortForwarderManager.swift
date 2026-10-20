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

    public init() {}

    #if DEBUG
    /// Harness-only: seed the map without an SSH client. See
    /// `PortForwarder.harnessForceState`.
    public func harnessInsert(_ forwarder: PortForwarder) {
        forwarders[forwarder.id] = forwarder
    }
    #endif

    /// Called from inside SSHSession.run once the SSHClient is established.
    /// Spawns one PortForwarder per `enabled && autoStart` rule.
    /// Idempotent — calling twice with the same rules is a no-op.
    public func attach(to client: SSHClient, rules: [PortForwardRule]) {
        self.client = client
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
        for forwarder in forwarders.values {
            await forwarder.stop()
        }
        forwarders.removeAll()
        client = nil
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
