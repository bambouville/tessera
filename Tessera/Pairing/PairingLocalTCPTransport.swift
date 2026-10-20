import Darwin
import Foundation
import Network
import TesseraCore

/// Errors from the platform-local TCP adapter. These errors intentionally carry
/// no offer, endpoint, or SAS material so diagnostics cannot accidentally
/// disclose pairing data.
enum PairingLocalTCPTransportError: Error, Equatable, LocalizedError {
    case alreadyStarted
    case notStarted
    case cancelled
    case noUsableEndpoint
    case invalidEndpoint
    case connectionClosed
    case timedOut
    case network

    var errorDescription: String? {
        switch self {
        case .alreadyStarted: return String(localized: "Pairing transport is already running.")
        case .notStarted: return String(localized: "Pairing transport is not running.")
        case .cancelled: return String(localized: "Pairing transport was cancelled.")
        case .noUsableEndpoint: return String(localized: "No usable local address is available for pairing.")
        case .invalidEndpoint: return String(localized: "The pairing endpoint is invalid.")
        case .connectionClosed: return String(localized: "The pairing connection closed.")
        case .timedOut: return String(localized: "The pairing connection timed out.")
        case .network: return String(localized: "The pairing network connection failed.")
        }
    }
}

struct PairingLocalTCPTimeouts: Equatable, Sendable {
    var connect: TimeInterval = 8
    /// Human SAS/biometric/import consent is intentionally unbounded here.
    /// The foreground coordinator owns the shared ten-minute expiry and calls
    /// cancel promptly on lifecycle changes; a short socket read timeout would
    /// otherwise disconnect a valid, user-paced approval.
    var read: TimeInterval? = nil
    var write: TimeInterval = 8
}

/// A numeric local address obtained from an interface. Keeping this small value
/// type separate from `getifaddrs` makes endpoint publication deterministic in
/// tests and prevents a hostname from entering a QR offer.
struct PairingLocalInterfaceAddress: Equatable, Sendable {
    let host: String
    let family: Int32

    init(host: String, family: Int32) {
        self.host = host
        self.family = family
    }
}

protocol PairingLocalEndpointEnumerating: Sendable {
    func candidates(port: UInt16) -> [PairingEndpointCandidateV1]
}

struct SystemPairingLocalEndpointEnumerator: PairingLocalEndpointEnumerating {
    func candidates(port: UInt16) -> [PairingEndpointCandidateV1] {
        PairingLocalEndpointFilter.candidates(
            from: PairingLocalInterfaceAddress.systemAddresses(),
            port: port
        )
    }
}

enum PairingLocalEndpointFilter {
    static func candidates(
        from addresses: [PairingLocalInterfaceAddress],
        port: UInt16
    ) -> [PairingEndpointCandidateV1] {
        guard port != 0 else { return [] }
        var seen = Set<String>()
        var result: [PairingEndpointCandidateV1] = []
        for address in addresses where result.count < PairingOfferV1.maximumEndpointCandidates {
            guard isPublishable(address), seen.insert(address.host).inserted else { continue }
            result.append(PairingEndpointCandidateV1(host: address.host, port: port))
        }
        return result
    }

    static func isPublishable(_ address: PairingLocalInterfaceAddress) -> Bool {
        switch address.family {
        case AF_INET:
            return IPv4Address(address.host).map(isPublishableIPv4) ?? false
        case AF_INET6:
            return IPv6Address(address.host).map(isPublishableIPv6) ?? false
        default:
            return false
        }
    }

    private static func isPublishableIPv4(_ address: IPv4Address) -> Bool {
        let bytes = Array(address.rawValue)
        guard bytes.count == 4 else { return false }
        // Exclude 0/8, loopback, multicast, and the unspecified address. RFC
        // 1918 is deliberately allowed: QR recipients are local peers.
        return bytes[0] != 0
            && bytes[0] != 127
            && bytes[0] < 224
    }

    private static func isPublishableIPv6(_ address: IPv6Address) -> Bool {
        let bytes = Array(address.rawValue)
        guard bytes.count == 16 else { return false }
        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isMulticast = bytes[0] == 0xff
        // fe80::/10 requires an interface scope zone, which does not travel
        // portably to Android in an offer. ULA fc00::/7 and routed v6 remain.
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        return !isUnspecified && !isLoopback && !isMulticast && !isLinkLocal
    }
}

private extension PairingLocalInterfaceAddress {
    static func systemAddresses() -> [PairingLocalInterfaceAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var result: [PairingLocalInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            guard let address = interface.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            result.append(PairingLocalInterfaceAddress(host: String(cString: host), family: family))
        }
        return result
    }
}

/// A single accepted local TCP listener. It has no discovery mechanism: the
/// origin places only vetted numeric candidates in the Pairing-v1 QR offer.
@MainActor
final class PairingLocalTCPListener {
    private let endpointEnumerator: any PairingLocalEndpointEnumerating
    private var listener: NWListener?
    private var accepted: PairingTCPRecordConnection?
    private var acceptWaiter: CheckedContinuation<PairingTCPRecordConnection, Error>?
    private var startWaiter: CheckedContinuation<[PairingEndpointCandidateV1], Error>?
    private var cancelled = false

    init(endpointEnumerator: any PairingLocalEndpointEnumerating = SystemPairingLocalEndpointEnumerator()) {
        self.endpointEnumerator = endpointEnumerator
    }

    func start() async throws -> [PairingEndpointCandidateV1] {
        guard listener == nil, startWaiter == nil else { throw PairingLocalTCPTransportError.alreadyStarted }
        cancelled = false
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            throw PairingLocalTCPTransportError.network
        }
        self.listener = listener
        listener.newConnectionLimit = 1
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener, self.accepted == nil else {
                    connection.cancel()
                    return
                }
                let recordConnection = PairingTCPRecordConnection(connection: connection)
                self.accepted = recordConnection
                self.listener = nil
                listener.cancel()
                self.acceptWaiter?.resume(returning: recordConnection)
                self.acceptWaiter = nil
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        self.failStart(PairingLocalTCPTransportError.network)
                        return
                    }
                    let candidates = self.endpointEnumerator.candidates(port: port)
                    guard !candidates.isEmpty else {
                        self.failStart(PairingLocalTCPTransportError.noUsableEndpoint)
                        return
                    }
                    self.startWaiter?.resume(returning: candidates)
                    self.startWaiter = nil
                case .failed:
                    self.failStart(PairingLocalTCPTransportError.network)
                case .cancelled where !self.cancelled:
                    self.failStart(PairingLocalTCPTransportError.connectionClosed)
                default:
                    break
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.startWaiter = continuation
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func acceptConnection() async throws -> PairingTCPRecordConnection {
        if let accepted { return accepted }
        guard listener != nil else {
            throw cancelled ? PairingLocalTCPTransportError.cancelled : PairingLocalTCPTransportError.notStarted
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                acceptWaiter = continuation
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        listener?.cancel()
        listener = nil
        startWaiter?.resume(throwing: PairingLocalTCPTransportError.cancelled)
        startWaiter = nil
        acceptWaiter?.resume(throwing: PairingLocalTCPTransportError.cancelled)
        acceptWaiter = nil
        let accepted = accepted
        self.accepted = nil
        Task { await accepted?.cancel() }
    }

    private func failStart(_ error: Error) {
        listener?.cancel()
        listener = nil
        startWaiter?.resume(throwing: error)
        startWaiter = nil
        acceptWaiter?.resume(throwing: error)
        acceptWaiter = nil
    }
}

/// Raw TCP stream adapter. It sends concatenated self-framed `TPR1` records;
/// it never adds an outer message length or interprets pairing protocol state.
actor PairingTCPRecordConnection {
    private let connection: NWConnection
    private let timeouts: PairingLocalTCPTimeouts
    private let decoder = PairingStreamRecordDecoderV1()
    private var queued: [PairingStreamRecordV1] = []
    private var started = false
    private var cancelled = false

    init(connection: NWConnection, timeouts: PairingLocalTCPTimeouts = .init()) {
        self.connection = connection
        self.timeouts = timeouts
    }

    static func connect(
        to candidates: [PairingEndpointCandidateV1],
        timeouts: PairingLocalTCPTimeouts = .init()
    ) async throws -> PairingTCPRecordConnection {
        var lastError: Error = PairingLocalTCPTransportError.invalidEndpoint
        for candidate in candidates where candidate.transport == .tcp {
            guard var endpoint = endpoint(for: candidate) else { continue }
            #if DEBUG && targetEnvironment(simulator)
            // The Android emulator is NAT-isolated from CoreSimulator. An
            // explicitly opted-in test may forward this exact advertised port
            // with adb. Keep the authenticated offer/transcript unchanged.
            if ProcessInfo.processInfo.environment["TESSERA_QR_EMULATOR_LOOPBACK"] == "1",
               ["10.0.2.15", "10.0.2.16"].contains(candidate.host),
               let port = NWEndpoint.Port(rawValue: candidate.port) {
                endpoint = .hostPort(host: "127.0.0.1", port: port)
            }
            #endif
            let recordConnection = PairingTCPRecordConnection(
                connection: NWConnection(to: endpoint, using: .tcp),
                timeouts: timeouts
            )
            do {
                try await recordConnection.start()
                return recordConnection
            } catch {
                lastError = error
                await recordConnection.cancel()
            }
        }
        throw lastError
    }

    func start() async throws {
        guard !cancelled else { throw PairingLocalTCPTransportError.cancelled }
        guard !started else { return }
        let connection = self.connection
        try await withTimeout(timeouts.connect) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let state = PairingTCPConnectionStartState(continuation: continuation)
                    connection.stateUpdateHandler = { update in
                        switch update {
                        case .ready: state.resume(.success(()))
                        case .failed: state.resume(.failure(PairingLocalTCPTransportError.network))
                        case .cancelled: state.resume(.failure(PairingLocalTCPTransportError.connectionClosed))
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            } onCancel: {
                connection.cancel()
            }
        }
        started = true
    }

    func send(_ record: PairingStreamRecordV1) async throws {
        try requireStarted()
        let bytes = try record.encoded()
        let connection = self.connection
        try await withTimeout(timeouts.write) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(
                        content: bytes,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { error in
                        if error == nil { continuation.resume() }
                        else { continuation.resume(throwing: PairingLocalTCPTransportError.network) }
                        }
                    )
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    func receiveRecord() async throws -> PairingStreamRecordV1 {
        try requireStarted()
        if !queued.isEmpty { return queued.removeFirst() }
        while true {
            let chunk = try await receiveChunk()
            let records = try decoder.append(chunk)
            if let first = records.first {
                queued.append(contentsOf: records.dropFirst())
                return first
            }
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        connection.cancel()
    }

    private func receiveChunk() async throws -> Data {
        let connection = self.connection
        let operation = {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: PairingStreamRecordV1.headerByteCount + PairingStreamRecordV1.maximumPayloadBytes
                    ) { data, _, complete, error in
                        if error != nil { continuation.resume(throwing: PairingLocalTCPTransportError.network) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if complete {
                            do {
                                try self.decoder.finish()
                                continuation.resume(throwing: PairingLocalTCPTransportError.connectionClosed)
                            } catch {
                                continuation.resume(throwing: PairingLocalTCPTransportError.network)
                            }
                        }
                        else { continuation.resume(throwing: PairingLocalTCPTransportError.connectionClosed) }
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        }
        if let readTimeout = timeouts.read {
            return try await withTimeout(readTimeout, operation: operation)
        }
        return try await operation()
    }

    private func requireStarted() throws {
        guard started else { throw PairingLocalTCPTransportError.notStarted }
        guard !cancelled else { throw PairingLocalTCPTransportError.cancelled }
    }

    private static func endpoint(for candidate: PairingEndpointCandidateV1) -> NWEndpoint? {
        guard let port = NWEndpoint.Port(rawValue: candidate.port) else { return nil }
        if let ipv4 = IPv4Address(candidate.host) {
            return .hostPort(host: .ipv4(ipv4), port: port)
        }
        if let ipv6 = IPv6Address(candidate.host) {
            return .hostPort(host: .ipv6(ipv6), port: port)
        }
        return nil
    }
}

private final class PairingTCPConnectionStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard seconds > 0 else { throw PairingLocalTCPTransportError.timedOut }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            try Task.checkCancellation()
            throw PairingLocalTCPTransportError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw PairingLocalTCPTransportError.connectionClosed
        }
        return result
    }
}
