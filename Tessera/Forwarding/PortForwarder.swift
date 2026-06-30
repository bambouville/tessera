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

    private let listener = PortListener()

    @ObservationIgnored
    private var connections: Set<PortForwardConnection> = []

    @ObservationIgnored
    private var serveTask: Task<Void, Never>?

    public init(rule: PortForwardRule) {
        self.rule = rule
    }

    public func start(over client: SSHClient) {
        DiagnosticLogStore.appendForwarding(
            "rule start rule=\(ruleShortID) localPort=\(rule.localPort) targetPort=\(rule.remotePort)"
        )

        serveTask?.cancel()
        listener.stop()
        state = .listening

        let listener = self.listener
        let localPort = rule.localPort

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
                        "connection accepted id=\(connectionLogID) rule=\(ruleLogID) localPort=\(currentRule.localPort) targetPort=\(currentRule.remotePort)"
                    )

                    do {
                        let remote = try await openDirectTCPIP(
                            over: client,
                            remoteHost: currentRule.remoteHost,
                            remotePort: currentRule.remotePort,
                            debugID: connectionID
                        )

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
                            "connection open failed id=\(connectionLogID) rule=\(ruleLogID) targetPort=\(currentRule.remotePort) error='\(error)'"
                        )
                        accepted.connection.cancel()

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
                self?.state = .error(reason: self?.describe(listenerError) ?? listenerError.localizedDescription)
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                DiagnosticLogStore.appendForwarding("rule listener-unexpected-error localPort=\(localPort) error='\(error)'")
                self?.state = .error(reason: error.localizedDescription)
            }
        }
    }

    public func stop() async {
        DiagnosticLogStore.appendForwarding("rule stop rule=\(ruleShortID) localPort=\(rule.localPort) activeConnections=\(connections.count)")

        serveTask?.cancel()
        serveTask = nil
        listener.stop()

        let activeConnections = connections
        for conn in activeConnections {
            await conn.close()
        }

        connections.removeAll()
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
        self.rule = rule
    }

    private func describe(_ error: PortListenerError) -> String {
        switch error {
        case .portInUse(let port):
            return "Port \(port) is already in use."
        case .bindFailed(let reason):
            return "Bind failed: \(reason)"
        case .cancelled:
            return "Listener cancelled."
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
