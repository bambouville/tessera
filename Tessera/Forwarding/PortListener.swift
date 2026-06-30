import Foundation
import Network

public enum PortListenerError: Error, Equatable {
    case portInUse(UInt16)
    case bindFailed(String)
    case cancelled
}

public struct AcceptedTCPConnection: @unchecked Sendable {
    public let connection: NWConnection
    public let remoteEndpoint: NWEndpoint?

    public init(connection: NWConnection, remoteEndpoint: NWEndpoint?) {
        self.connection = connection
        self.remoteEndpoint = remoteEndpoint
    }
}

@MainActor
public final class PortListener {
    private var listener: NWListener?

    public init() {}

    public func listen(port: UInt16) async throws -> AsyncThrowingStream<AcceptedTCPConnection, Error> {
        DiagnosticLogStore.appendForwarding("listener create begin localPort=\(port)")

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            DiagnosticLogStore.appendForwarding("listener invalid localPort=\(port)")
            throw PortListenerError.bindFailed("Invalid port \(port)")
        }

        // Pin the listener to the IPv4 loopback interface. An unconstrained
        // NWListener binds to ALL interfaces — on iOS there is no sandbox rule
        // forcing loopback, so without this any device on the same Wi-Fi could
        // reach the forwarded port and tunnel into the user's SSH target.
        // Don't combine `requiredLocalEndpoint` with `NWListener(on:)`: they
        // both pin the port, and Network.framework rejects the duplicate
        // specification with EINVAL during start (NWError 22) — so the port
        // travels inside `requiredLocalEndpoint` and the listener is created
        // with `NWListener(using:)` alone. Local clients should connect to
        // 127.0.0.1:<port> (most "localhost" resolvers fall back to IPv4 when
        // ::1 refuses).
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch let error as NWError {
            DiagnosticLogStore.appendForwarding("listener create failed localPort=\(port) error='\(error)'")
            throw portListenerError(for: error, port: port)
        } catch {
            DiagnosticLogStore.appendForwarding("listener create failed localPort=\(port) error='\(error)'")
            throw PortListenerError.bindFailed(error.localizedDescription)
        }

        self.listener = listener
        listener.newConnectionLimit = NWListener.InfiniteConnectionLimit

        return try await withCheckedThrowingContinuation { bindContinuation in
            let bindState = PortListenerBindState()

            let stream = AsyncThrowingStream<AcceptedTCPConnection, Error> { continuation in
                bindState.streamContinuation = continuation
                continuation.onTermination = { @Sendable _ in
                    listener.cancel()
                }
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .setup:
                    break
                case .waiting(let error):
                    DiagnosticLogStore.appendForwarding("listener waiting localPort=\(port) error='\(error)'")
                case .ready:
                    DiagnosticLogStore.appendForwarding("listener ready localPort=\(port)")
                    guard !bindState.bindResumed else { return }
                    bindState.bindResumed = true
                    bindContinuation.resume(returning: stream)
                case .failed(let error):
                    DiagnosticLogStore.appendForwarding("listener failed localPort=\(port) error='\(error)'")
                    let mappedError = portListenerError(for: error, port: port)
                    if !bindState.bindResumed {
                        bindState.bindResumed = true
                        bindContinuation.resume(throwing: mappedError)
                    }
                    bindState.streamContinuation?.finish(throwing: mappedError)
                case .cancelled:
                    if !bindState.bindResumed {
                        bindState.bindResumed = true
                        bindContinuation.resume(throwing: PortListenerError.cancelled)
                    }
                    bindState.streamContinuation?.finish(throwing: PortListenerError.cancelled)
                @unknown default:
                    DiagnosticLogStore.appendForwarding("listener unknown-state localPort=\(port) state=\(state)")
                }
            }

            listener.newConnectionHandler = { conn in
                DiagnosticLogStore.appendForwarding("listener accepted localPort=\(port)")
                _ = bindState.streamContinuation?.yield(
                    AcceptedTCPConnection(connection: conn, remoteEndpoint: conn.endpoint)
                )
            }

            listener.start(queue: .main)
        }
    }

    public func stop() {
        if listener != nil {
            DiagnosticLogStore.appendForwarding("listener stop")
        }
        listener?.cancel()
        listener = nil
    }
}

private final class PortListenerBindState: @unchecked Sendable {
    var bindResumed = false
    var streamContinuation: AsyncThrowingStream<AcceptedTCPConnection, Error>.Continuation?
}

private func portListenerError(for error: NWError, port: UInt16) -> PortListenerError {
    if case .posix(.EADDRINUSE) = error {
        return .portInUse(port)
    }

    return .bindFailed(error.localizedDescription)
}
