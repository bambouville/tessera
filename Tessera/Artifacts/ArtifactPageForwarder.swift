import CryptoKit
import Foundation
import Network
import Observation
import PortForwarding
import TesseraArtifactsCore

struct ArtifactSSHSource {
    let sessionID: UUID
    let hostID: String
    let manager: PortForwarderManager
    var isFileBridge: Bool = false

    static func bridgeSessionID(for key: FileBridgeKey) -> UUID {
        let components = ["artifacts-files", key.hostID?.uuidString ?? "", key.user, key.address, String(key.port)] + key.jumpPath
        let identity = components.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

enum ArtifactPageForwardError: Error {
    case noSSHSession
    case ruleNotRunning
}

/// Tab leases never own an SSH client. A session or connected Files bridge
/// lends a forward and tears it down with its client, even if the browser is hidden.
///
/// Tabs on one host's port share one forward, as a browser's tabs share one
/// origin: a second tab on `localhost:8001` leases the first tab's listener,
/// and a tab-owned forward stops only when the last tab leasing it lets go.
@MainActor
@Observable
final class ArtifactPageForwarder {
    private struct Lease {
        let source: ArtifactSSHSource
        let forwarder: PortForwarder
        let remotePort: UInt16
        var ephemeral: Bool
    }
    /// One tab-owned forward per source and remote port.
    private struct ForwardKey: Hashable {
        let sessionID: UUID
        let manager: ObjectIdentifier
        let remotePort: UInt16

        init(_ source: ArtifactSSHSource, remotePort: UInt16) {
            sessionID = source.sessionID
            manager = ObjectIdentifier(source.manager)
            self.remotePort = remotePort
        }
    }
    /// A forward being started for one or more tabs. Each waiting tab holds
    /// it until its lease is in place, so a tab that gives up first cannot
    /// stop the listener another tab is about to lease.
    private final class PendingForward {
        let task: Task<PortForwarder, Error>
        var waiters = 0
        /// The started listener, once the first waiter has it. Only this
        /// listener is held for the waiters still to lease it.
        weak var forwarder: PortForwarder?
        init(task: Task<PortForwarder, Error>) { self.task = task }
    }
    private var leases: [String: Lease] = [:]
    @ObservationIgnored private var pending: [ForwardKey: PendingForward] = [:]

    #if DEBUG
    @ObservationIgnored private var harnessSources: Set<UUID> = []

    /// Seeds a lease without a client or listener, alongside the forwarding
    /// manager's harnessInsert and the forwarder's harnessForceState.
    func harnessInsert(_ tab: ArtifactTab, source: ArtifactSSHSource, forwarder: PortForwarder, ephemeral: Bool) {
        guard case let .page(_, port, _) = tab.target else { return }
        harnessSources.insert(source.sessionID)
        leases[tab.id] = Lease(source: source, forwarder: forwarder, remotePort: port, ephemeral: ephemeral)
    }
    #endif

    private func isAvailable(_ source: ArtifactSSHSource) -> Bool {
        #if DEBUG
        if harnessSources.contains(source.sessionID) { return true }
        #endif
        return source.manager.canStartEphemeral
    }

    private static func matches(_ rule: PortForwardRule, remotePort: UInt16) -> Bool {
        if case let .reuse(ruleID, _) = ArtifactsForwardPlanner.plan(remotePort: remotePort, hostRules: [rule]) {
            return ruleID == rule.id
        }
        return false
    }

    private func isValid(_ lease: Lease, rules: [PortForwardRule]? = nil) -> Bool {
        guard !lease.ephemeral else { return true }
        let rule = lease.forwarder.rule
        guard lease.source.manager.forwarders[rule.id] === lease.forwarder,
              Self.matches(rule, remotePort: lease.remotePort) else { return false }
        return rules.map { $0.contains { $0.id == rule.id && Self.matches($0, remotePort: lease.remotePort) } } ?? true
    }

    func content(for tab: ArtifactTab) -> ArtifactContent? {
        guard case .page = tab.target, let lease = leases[tab.id] else { return nil }
        guard isAvailable(lease.source), isValid(lease) else {
            close(tab.id)
            return nil
        }
        switch lease.forwarder.state {
        case .idle: return .unavailable(.offline)
        case let .error(reason): return .unavailable(.failed(reason))
        case .listening, .active: break
        }
        guard let address = Self.url(for: tab, localPort: lease.forwarder.rule.bind.port) else {
            return .unavailable(.failed(String(localized: "this page address is invalid")))
        }
        let label = lease.forwarder.rule.label
        return .forwardedPage(url: address, ruleLabel: label.isEmpty ? tab.title : label, isEphemeral: lease.ephemeral)
    }

    static func url(for tab: ArtifactTab, localPort: UInt16) -> URL? {
        guard case let .page(scheme, _, path) = tab.target, localPort > 0,
              ["http", "https"].contains(scheme), let location = URLComponents(string: path) else { return nil }
        var url = URLComponents()
        // Both iOS listeners bind IPv4 loopback, including when a saved rule
        // spells its bind as localhost or ::1. Use the actual listener here.
        // An explicit page's scheme wins over port-based HTTP/TLS guesses.
        url.scheme = scheme
        url.host = "127.0.0.1"
        url.port = Int(localPort)
        url.percentEncodedPath = location.percentEncodedPath.hasPrefix("/") ? location.percentEncodedPath : "/" + location.percentEncodedPath
        url.percentEncodedQuery = location.percentEncodedQuery
        url.percentEncodedFragment = location.percentEncodedFragment
        return url.url
    }

    func open(_ tab: ArtifactTab, rules: [PortForwardRule], sources: [ArtifactSSHSource]) async throws {
        if let lease = leases[tab.id], !isValid(lease, rules: rules) { close(tab.id) }
        if case .forwardedPage? = content(for: tab) { return }
        close(tab.id)
        guard case let .page(_, port, _) = tab.target else { return }
        let candidates = Self.orderedSources(
            sources.filter { $0.hostID == tab.hostID && isAvailable($0) },
            sessionHint: tab.sessionHint
        )
        guard !candidates.isEmpty else { throw ArtifactPageForwardError.noSSHSession }
        switch ArtifactsForwardPlanner.plan(remotePort: port, hostRules: rules) {
        case let .reuse(ruleID, _):
            for source in candidates {
                guard let forwarder = source.manager.forwarders[ruleID], Self.matches(forwarder.rule, remotePort: port) else { continue }
                switch forwarder.state {
                case .listening, .active:
                    leases[tab.id] = Lease(source: source, forwarder: forwarder, remotePort: port, ephemeral: false)
                    return
                case .idle, .error: continue
                }
            }
            // Files attaches without host rules. A saved rule may exist on
            // disk while no SSH session is running it; borrow an ephemeral
            // forward from the already-connected Files client in that case.
            guard let source = candidates.first(where: \.isFileBridge),
                  case let .ephemeral(rule) = ArtifactsForwardPlanner.plan(remotePort: port, hostRules: [])
            else { throw ArtifactPageForwardError.ruleNotRunning }
            try await openEphemeral(tab, rule: rule, source: source)
        case let .ephemeral(rule):
            // Another tab's forward on this port, from whichever of the
            // host's sessions holds it, before a listener of its own.
            let shared = candidates.first {
                let key = ForwardKey($0, remotePort: port)
                return sharedEphemeral(key) != nil || pending[key] != nil
            }
            try await openEphemeral(tab, rule: rule, source: shared ?? candidates[0])
        }
    }

    static func orderedSources(_ sources: [ArtifactSSHSource], sessionHint: String?) -> [ArtifactSSHSource] {
        sources.sorted {
            if $0.isFileBridge != $1.isFileBridge { return !$0.isFileBridge }
            if ($0.sessionID.uuidString == sessionHint) != ($1.sessionID.uuidString == sessionHint) {
                return $0.sessionID.uuidString == sessionHint
            }
            return $0.sessionID.uuidString < $1.sessionID.uuidString
        }
    }

    private func openEphemeral(_ tab: ArtifactTab, rule: PortForwardRule, source: ArtifactSSHSource) async throws {
        guard case let .page(_, port, _) = tab.target else { return }
        let key = ForwardKey(source, remotePort: port)
        // Another tab on this port already holds a running forward.
        if let shared = sharedEphemeral(key) {
            leases[tab.id] = Lease(source: source, forwarder: shared, remotePort: port, ephemeral: true)
            return
        }
        let start: PendingForward
        if let existing = pending[key] { start = existing }
        else {
            let manager = source.manager
            start = PendingForward(task: Task { @MainActor in try await manager.startEphemeral(rule) })
            pending[key] = start
        }
        start.waiters += 1
        let result = await start.task.result
        start.waiters -= 1
        if case let .success(started) = result { start.forwarder = started }
        if pending[key] === start, start.waiters == 0 { pending[key] = nil }
        let forwarder = try result.get()
        guard !Task.isCancelled, source.manager.canStartEphemeral else {
            if start.waiters == 0, !isLeased(forwarder) { await source.manager.stopEphemeral(forwarder.id) }
            throw CancellationError()
        }
        if let previous = leases[tab.id], previous.forwarder !== forwarder { close(tab.id) }
        leases[tab.id] = Lease(source: source, forwarder: forwarder, remotePort: port, ephemeral: true)
    }

    /// A tab-owned forward another tab leases on this source and port, while
    /// it still listens.
    private func sharedEphemeral(_ key: ForwardKey) -> PortForwarder? {
        leases.values.first { lease in
            guard lease.ephemeral, ForwardKey(lease.source, remotePort: lease.remotePort) == key,
                  isAvailable(lease.source) else { return false }
            switch lease.forwarder.state {
            case .listening, .active: return true
            case .idle, .error: return false
            }
        }?.forwarder
    }

    private func isLeased(_ forwarder: PortForwarder) -> Bool {
        leases.values.contains { $0.forwarder === forwarder }
    }

    /// Tabs leasing the same listener as this one, itself included.
    func tabsSharingForward(with tabID: String) -> Set<String> {
        guard let forwarder = leases[tabID]?.forwarder else { return [] }
        return Set(leases.filter { $0.value.forwarder === forwarder }.keys)
    }

    func reconcile(sources: [ArtifactSSHSource], rulesByHost: [String: [PortForwardRule]]? = nil) {
        for (tabID, lease) in leases {
            let available = sources.contains {
                $0.sessionID == lease.source.sessionID && $0.manager === lease.source.manager && isAvailable($0)
            }
            let rules = rulesByHost.map { $0[lease.source.hostID] ?? [] }
            if !available || !isValid(lease, rules: rules) { close(tabID) }
        }
    }

    /// Releases the tab's lease. A tab-owned forward stops with its last tab.
    func close(_ tabID: String) {
        guard let lease = leases.removeValue(forKey: tabID), lease.ephemeral, !isLeased(lease.forwarder) else { return }
        let key = ForwardKey(lease.source, remotePort: lease.remotePort)
        // A tab still to lease this listener from its start keeps it alive;
        // a start of a replacement listener does not hold this one.
        if let start = pending[key], start.waiters > 0, start.forwarder === lease.forwarder { return }
        let id = lease.forwarder.id
        Task { await lease.source.manager.stopEphemeral(id) }
    }

    func canKeepAsRule(_ tabID: String) -> Bool {
        guard let lease = leases[tabID], lease.ephemeral, !lease.source.isFileBridge, isAvailable(lease.source) else { return false }
        switch lease.forwarder.state {
        case .listening, .active: return lease.forwarder.rule.bind.port > 0
        case .idle, .error: return false
        }
    }

    func ruleToKeep(_ tabID: String, title: String) -> PortForwardRule? {
        guard canKeepAsRule(tabID), let lease = leases[tabID] else { return nil }
        return ArtifactsForwardPlanner.keepAsRule(lease.forwarder.rule, label: title, ruleID: UUID())
    }

    func kept(_ tabID: String, rule: PortForwardRule) {
        guard canKeepAsRule(tabID), let lease = leases[tabID] else { return }
        lease.source.manager.promoteEphemeral(lease.forwarder.id, to: rule)
        // Every tab on the listener now borrows the saved rule.
        for (id, var shared) in leases where shared.forwarder === lease.forwarder {
            shared.ephemeral = false
            leases[id] = shared
        }
    }
}

/// A separate listener is needed only for tab-owned forwards: the existing
/// PortListener intentionally has no ephemeral-port API. Network.framework
/// chooses the fallback port while retaining the socket, with no bind race.
@MainActor
final class ArtifactEphemeralListener {
    struct Bound {
        let port: UInt16
        let connections: AsyncThrowingStream<AcceptedTCPConnection, Error>
    }
    private var listener: NWListener?

    func listen(preferredPort: UInt16) async throws -> Bound {
        do { return try await bind(port: preferredPort) }
        catch PortListenerError.portInUse where preferredPort != 0 { return try await bind(port: 0) }
    }

    private func bind(port: UInt16) async throws -> Bound {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch let error as NWError {
            if case .posix(.EADDRINUSE) = error { throw PortListenerError.portInUse(port) }
            throw error
        }
        self.listener = listener
        let state = ArtifactListenerBindState()
        let stream = AsyncThrowingStream<AcceptedTCPConnection, Error> { continuation in
            state.stream = continuation
            continuation.onTermination = { @Sendable _ in listener.cancel() }
        }
        return try await withTaskCancellationHandler {
            let bound: Bound = try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { update in
                    switch update {
                    case .ready:
                        guard !state.resumed else { return }
                        state.resumed = true
                        if let actual = listener.port?.rawValue, actual > 0 {
                            continuation.resume(returning: Bound(port: actual, connections: stream))
                        } else {
                            continuation.resume(throwing: PortListenerError.bindFailed(String(localized: "no local port was assigned")))
                            listener.cancel()
                        }
                    case let .failed(error), let .waiting(error):
                        let failure: PortListenerError
                        if case .posix(.EADDRINUSE) = error { failure = .portInUse(port) }
                        else { failure = .bindFailed(error.localizedDescription) }
                        if !state.resumed {
                            state.resumed = true
                            continuation.resume(throwing: failure)
                        }
                        state.stream?.finish(throwing: failure)
                        listener.cancel()
                    case .cancelled:
                        if !state.resumed {
                            state.resumed = true
                            continuation.resume(throwing: CancellationError())
                        }
                        state.stream?.finish()
                    default: break
                    }
                }
                listener.newConnectionHandler = { connection in
                    state.stream?.yield(AcceptedTCPConnection(connection: connection, remoteEndpoint: connection.endpoint))
                }
                listener.start(queue: .main)
                if Task.isCancelled { listener.cancel() }
            }
            try Task.checkCancellation()
            return bound
        } onCancel: { listener.cancel() }
    }

    func stop() { listener?.cancel(); listener = nil }
}

private final class ArtifactListenerBindState: @unchecked Sendable {
    var resumed = false
    var stream: AsyncThrowingStream<AcceptedTCPConnection, Error>.Continuation?
}
