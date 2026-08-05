import Foundation
import Network

public enum NearbyTransferServiceError: Error, Equatable, LocalizedError {
    case alreadyStarted
    case notStarted
    case peerUnavailable
    case invalidFrameLength(Int)
    case connectionClosed
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: return "Nearby transfer is already running."
        case .notStarted: return "Nearby transfer is not running."
        case .peerUnavailable: return "The nearby peer is no longer available."
        case .invalidFrameLength(let length): return "Invalid nearby frame length \(length)."
        case .connectionClosed: return "The nearby connection closed."
        case .network(let message): return message
        }
    }
}

/// A browser result suitable for UI display and later connection lookup.
/// `displayName` is self-asserted Bonjour metadata and must never be used as a
/// trust, key-derivation, authorization, or persistence input.
public struct NearbyDiscoveredPeer: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// Pre-connect verdict from the peer's TXT record. Advisory badge data
    /// only — TXT is unauthenticated cleartext, so this never gates
    /// connection; the handshake is the authoritative version check.
    public let compatibility: NearbyPeerCompatibility

    public init(
        id: String,
        displayName: String,
        compatibility: NearbyPeerCompatibility = .unknown
    ) {
        self.id = id
        self.displayName = displayName
        self.compatibility = compatibility
    }
}

public enum NearbyTransferServiceMode: Equatable, Sendable {
    case stopped
    case browsing
    case offering
}

public enum NearbyTransferServiceEvent {
    case peersChanged([NearbyDiscoveredPeer])
    case incomingConnection(any NearbyByteConnection)
    case failed(NearbyTransferServiceError)
}

/// Length-framed byte transport used by handshake/coordinator code. Both the
/// Bonjour implementation and the in-memory pair below obey identical framing
/// limits, making the entire protocol testable without a network or device.
public protocol NearbyByteConnection: AnyObject {
    func start() async throws
    func send(_ data: Data) async throws
    func receive(maximumSize: Int) async throws -> Data
    func cancel() async
}

/// Injectable lifecycle boundary for Bonjour. A fake can verify that browser
/// and listener resources exist only between `start...` and `stop`.
@MainActor
public protocol NearbyTransferNetworking: AnyObject {
    func startBrowsing(
        serviceType: String,
        peersChanged: @escaping ([NearbyDiscoveredPeer]) -> Void,
        failed: @escaping (NearbyTransferServiceError) -> Void
    ) throws

    func startOffering(
        serviceType: String,
        displayName: String,
        incoming: @escaping (any NearbyByteConnection) -> Void,
        failed: @escaping (NearbyTransferServiceError) -> Void
    ) throws

    func makeConnection(toPeerID peerID: String) throws -> any NearbyByteConnection
    func stop()
}

/// Owns the foreground-only discovery/listener lifecycle. Merely constructing
/// this object performs no network work; callers must explicitly start it and
/// must call `stop()` on cancel/background. Starting another mode implicitly is
/// forbidden so UI lifecycle errors are visible in tests.
@MainActor
public final class NearbyTransferService {
    public static let bonjourServiceType = "_tessera-bootstrap._tcp"

    public private(set) var mode: NearbyTransferServiceMode = .stopped
    public private(set) var discoveredPeers: [NearbyDiscoveredPeer] = []
    public var onEvent: ((NearbyTransferServiceEvent) -> Void)?

    private let networking: any NearbyTransferNetworking
    private var lifecycleGeneration = 0

    public init(networking: any NearbyTransferNetworking) {
        self.networking = networking
    }

    public convenience init() {
        self.init(networking: BonjourNearbyTransferNetworking())
    }

    public func startBrowsing() throws {
        guard mode == .stopped else { throw NearbyTransferServiceError.alreadyStarted }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        do {
            try networking.startBrowsing(
                serviceType: Self.bonjourServiceType,
                peersChanged: { [weak self] peers in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          self.mode == .browsing
                    else { return }
                    self.discoveredPeers = peers
                    self.onEvent?(.peersChanged(peers))
                },
                failed: { [weak self] error in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          self.mode == .browsing
                    else { return }
                    self.onEvent?(.failed(error))
                }
            )
            mode = .browsing
        } catch {
            lifecycleGeneration &+= 1
            networking.stop()
            mode = .stopped
            throw error
        }
    }

    public func startOffering(displayName: String) throws {
        guard mode == .stopped else { throw NearbyTransferServiceError.alreadyStarted }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        do {
            try networking.startOffering(
                serviceType: Self.bonjourServiceType,
                displayName: displayName,
                incoming: { [weak self] connection in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          self.mode == .offering
                    else {
                        Task { await connection.cancel() }
                        return
                    }
                    self.onEvent?(.incomingConnection(connection))
                },
                failed: { [weak self] error in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          self.mode == .offering
                    else { return }
                    self.onEvent?(.failed(error))
                }
            )
            mode = .offering
        } catch {
            lifecycleGeneration &+= 1
            networking.stop()
            mode = .stopped
            throw error
        }
    }

    public func connect(to peer: NearbyDiscoveredPeer) throws -> any NearbyByteConnection {
        guard mode == .browsing else { throw NearbyTransferServiceError.notStarted }
        // Only the opaque result ID reaches the networking layer. The display
        // name is never consulted and cannot become a trust input.
        return try networking.makeConnection(toPeerID: peer.id)
    }

    public func stop() {
        guard mode != .stopped else { return }
        lifecycleGeneration &+= 1
        networking.stop()
        discoveredPeers = []
        mode = .stopped
        onEvent?(.peersChanged([]))
    }

}

/// Network.framework Bonjour implementation. Listener and browser objects are
/// created lazily by the two start calls and cancelled/nil'd by `stop()`.
@MainActor
public final class BonjourNearbyTransferNetworking: NearbyTransferNetworking {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var endpointsByPeerID: [String: NWEndpoint] = [:]
    private var peerIDByEndpointDescription: [String: String] = [:]
    private var acceptedConnection: BonjourNearbyConnection?

    public init() {}

    public func startBrowsing(
        serviceType: String,
        peersChanged: @escaping ([NearbyDiscoveredPeer]) -> Void,
        failed: @escaping (NearbyTransferServiceError) -> Void
    ) throws {
        guard browser == nil, listener == nil else {
            throw NearbyTransferServiceError.alreadyStarted
        }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
            using: .tcp
        )
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor in
            guard let self,
                  let browser,
                  self.browser === browser
            else { return }
            var newEndpoints: [String: NWEndpoint] = [:]
            var newPeerIDs: [String: String] = [:]
            var peers: [NearbyDiscoveredPeer] = []

            for result in results {
                let description = String(describing: result.endpoint)
                let id = self.peerIDByEndpointDescription[description] ?? UUID().uuidString
                newPeerIDs[description] = id
                newEndpoints[id] = result.endpoint
                // TXT can arrive after the endpoint on a later results
                // change; until then the peer honestly reads `unknown`.
                let compatibility: NearbyPeerCompatibility
                if case .bonjour(let txtRecord) = result.metadata,
                   let advertisement = NearbyCompatibilityAdvertisement(txtRecord: txtRecord) {
                    compatibility = advertisement.compatibility(
                        withLocal: NearbyBootstrapProtocol.supportedVersions
                    )
                } else {
                    compatibility = .unknown
                }
                peers.append(
                    NearbyDiscoveredPeer(
                        id: id,
                        displayName: Self.displayName(for: result.endpoint),
                        compatibility: compatibility
                    )
                )
            }
            self.endpointsByPeerID = newEndpoints
            self.peerIDByEndpointDescription = newPeerIDs
            peersChanged(peers.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                guard let self,
                      let browser,
                      self.browser === browser
                else { return }
                switch state {
                case .failed(let error), .waiting(let error):
                    failed(.network(error.localizedDescription))
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }

    public func startOffering(
        serviceType: String,
        displayName: String,
        incoming: @escaping (any NearbyByteConnection) -> Void,
        failed: @escaping (NearbyTransferServiceError) -> Void
    ) throws {
        guard browser == nil, listener == nil else {
            throw NearbyTransferServiceError.alreadyStarted
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            throw NearbyTransferServiceError.network(error.localizedDescription)
        }
        self.listener = listener
        listener.service = NWListener.Service(
            name: Self.sanitizedServiceName(displayName),
            type: serviceType,
            domain: nil,
            txtRecord: NearbyCompatibilityAdvertisement.current.txtRecord
        )
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self,
                      let listener,
                      self.listener === listener
                else { return }
                switch state {
                case .failed(let error), .waiting(let error):
                    failed(.network(error.localizedDescription))
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
            guard let self,
                  let listener,
                  self.listener === listener
            else {
                connection.cancel()
                return
            }
            let wrapped = BonjourNearbyConnection(connection: connection)
            guard self.acceptedConnection == nil else {
                Task { await wrapped.cancel() }
                return
            }
            self.acceptedConnection = wrapped
            incoming(wrapped)
            // One transfer offer accepts exactly one peer. Nil the listener
            // before cancellation so already-queued callbacks fail the
            // identity guard and cancel their raw NWConnections immediately.
            self.listener = nil
            listener.cancel()
            }
        }
        listener.start(queue: .main)
    }

    public func makeConnection(toPeerID peerID: String) throws -> any NearbyByteConnection {
        guard browser != nil else { throw NearbyTransferServiceError.notStarted }
        guard let endpoint = endpointsByPeerID[peerID] else {
            throw NearbyTransferServiceError.peerUnavailable
        }
        return BonjourNearbyConnection(
            connection: NWConnection(to: endpoint, using: .tcp)
        )
    }

    public func stop() {
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        endpointsByPeerID = [:]
        peerIDByEndpointDescription = [:]
        let acceptedConnection = acceptedConnection
        self.acceptedConnection = nil
        Task { await acceptedConnection?.cancel() }
    }

    nonisolated private static func displayName(for endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint {
            return NearbyDeviceLabel.sanitized(name)
        }
        return NearbyDeviceLabel.generic
    }

    private static func sanitizedServiceName(_ displayName: String) -> String {
        NearbyDeviceLabel.serviceName(displayName)
    }
}

/// TCP length-framing adapter. Network.framework's stream delivery does not
/// preserve send boundaries, so every logical protocol message is prefixed by
/// a four-byte big-endian length and received exactly.
public actor BonjourNearbyConnection: NearbyByteConnection {
    public static let maximumWireMessageSize = BootstrapManifest.maximumEncodedByteCount + 65_536

    private let connection: NWConnection
    private var started = false
    private var cancelled = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func start() async throws {
        guard !cancelled else { throw NearbyTransferServiceError.connectionClosed }
        guard !started else { return }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = NearbyConnectionStartState(continuation: continuation)
            connection.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    state.resume(.success(()))
                case .failed(let error):
                    state.resume(.failure(NearbyTransferServiceError.network(error.localizedDescription)))
                case .cancelled:
                    state.resume(.failure(NearbyTransferServiceError.connectionClosed))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        started = true
    }

    public func send(_ data: Data) async throws {
        guard started, !cancelled else { throw NearbyTransferServiceError.connectionClosed }
        guard data.count <= Self.maximumWireMessageSize else {
            throw NearbyTransferServiceError.invalidFrameLength(data.count)
        }
        var frame = Data()
        frame.append(contentsOf: UInt32(data.count).bigEndianBytes)
        frame.append(data)
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: NearbyTransferServiceError.network(error.localizedDescription)
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    public func receive(maximumSize: Int = BonjourNearbyConnection.maximumWireMessageSize) async throws -> Data {
        guard started, !cancelled else { throw NearbyTransferServiceError.connectionClosed }
        let prefix = try await Self.receiveExactly(4, from: connection)
        let length = Int(prefix.uint32BigEndian)
        guard length > 0,
              length <= maximumSize,
              length <= Self.maximumWireMessageSize else {
            throw NearbyTransferServiceError.invalidFrameLength(length)
        }
        return try await Self.receiveExactly(length, from: connection)
    }

    public func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        connection.cancel()
    }

    private static func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(
                            throwing: NearbyTransferServiceError.network(error.localizedDescription)
                        )
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: NearbyTransferServiceError.connectionClosed)
                    } else {
                        continuation.resume(throwing: NearbyTransferServiceError.connectionClosed)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }
}

/// A deterministic in-memory pair for protocol and coordinator tests.
public actor NearbyLoopbackConnection: NearbyByteConnection {
    private let inbound: NearbyLoopbackMailbox
    private let outbound: NearbyLoopbackMailbox
    private var started = false
    private var cancelled = false

    private init(inbound: NearbyLoopbackMailbox, outbound: NearbyLoopbackMailbox) {
        self.inbound = inbound
        self.outbound = outbound
    }

    public static func makePair() -> (NearbyLoopbackConnection, NearbyLoopbackConnection) {
        let first = NearbyLoopbackMailbox()
        let second = NearbyLoopbackMailbox()
        return (
            NearbyLoopbackConnection(inbound: first, outbound: second),
            NearbyLoopbackConnection(inbound: second, outbound: first)
        )
    }

    public func start() async throws {
        guard !cancelled else { throw NearbyTransferServiceError.connectionClosed }
        started = true
    }

    public func send(_ data: Data) async throws {
        try requireUsable()
        guard data.count <= BonjourNearbyConnection.maximumWireMessageSize else {
            throw NearbyTransferServiceError.invalidFrameLength(data.count)
        }
        try await outbound.send(data)
    }

    public func receive(maximumSize: Int = BonjourNearbyConnection.maximumWireMessageSize) async throws -> Data {
        try requireUsable()
        let data = try await inbound.receive()
        guard data.count <= maximumSize else {
            throw NearbyTransferServiceError.invalidFrameLength(data.count)
        }
        return data
    }

    public func cancel() async {
        let shouldClose = !cancelled
        cancelled = true
        if shouldClose {
            await inbound.close()
            await outbound.close()
        }
    }

    private func requireUsable() throws {
        guard started, !cancelled else { throw NearbyTransferServiceError.connectionClosed }
    }
}

private actor NearbyLoopbackMailbox {
    private var queued: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    func send(_ data: Data) throws {
        guard !closed else { throw NearbyTransferServiceError.connectionClosed }
        if waiters.isEmpty {
            queued.append(data)
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }

    func receive() async throws -> Data {
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        guard !closed else { throw NearbyTransferServiceError.connectionClosed }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(throwing: NearbyTransferServiceError.connectionClosed)
        }
    }
}

private final class NearbyConnectionStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private extension Data {
    var uint32BigEndian: UInt32 {
        reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}
