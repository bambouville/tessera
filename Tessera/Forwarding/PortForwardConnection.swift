import Foundation
import Network
import NIOCore

private enum PortForwardConnectionError: Error {
    case cancelled
}

@MainActor
final class PortForwardConnection: Identifiable, Hashable {
    nonisolated let id: UUID
    let local: NWConnection
    let remote: NIOAsyncChannel<ByteBuffer, ByteBuffer>

    private(set) var bytesUp: UInt64 = 0
    private(set) var bytesDown: UInt64 = 0

    var onClose: (@MainActor () -> Void)?

    private var didCleanUp = false
    private var didNotifyClose = false
    private var readyWaiter: PortForwardConnectionReadyWaiter?
    private var localCancelWatchdog: Task<Void, Never>?
    private let startedAt = Date()

    init(
        id: UUID = UUID(),
        local: NWConnection,
        remote: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    ) {
        self.id = id
        self.local = local
        self.remote = remote
    }

    func start() async throws {
        DiagnosticLogStore.appendForwarding("connection start id=\(shortID)")

        do {
            try await waitUntilReady()

            // This NIO checkout deprecates direct inbound/outbound access; executeThenClose is the scoped API.
            try await remote.executeThenClose { inbound, outbound in
                try await pumpBothDirections(inbound: inbound, outbound: outbound)
            }
        } catch {
            DiagnosticLogStore.appendForwarding("connection failed id=\(shortID) error='\(error)'")
            await cleanUp(cancelLocal: true)
            notifyClosed()
            throw error
        }

        await cleanUp(cancelLocal: false)
        notifyClosed()
    }

    func close() async {
        DiagnosticLogStore.appendForwarding("connection close-requested id=\(shortID)")
        await cleanUp(cancelLocal: true)
    }

    private func waitUntilReady() async throws {
        let waiter = PortForwardConnectionReadyWaiter()
        readyWaiter = waiter

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.continuation = continuation

            local.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    waiter.resume(returning: ())
                case .failed(let error):
                    DiagnosticLogStore.appendForwarding("connection local failed id=\(String(self.id.uuidString.prefix(8))) error='\(error)'")
                    waiter.resume(throwing: error)
                case .cancelled:
                    waiter.resume(throwing: PortForwardConnectionError.cancelled)
                default:
                    break
                }
            }

            local.start(queue: .main)
        }

        readyWaiter = nil
    }

    private func pumpBothDirections(
        inbound: NIOAsyncChannelInboundStream<ByteBuffer>,
        outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    ) async throws {
        // Run both pumps concurrently and let each exit on its own
        // half-close (FIN). The original "cancel sibling on first
        // completion" pattern broke HTTP keep-alive: when the local
        // side's GET request finished sending and `receiveFromLocal`
        // returned `isComplete=true`, the local→remote pump exited
        // cleanly — triggering cancellation of the remote→local pump
        // mid-response and a broken pipe on the upstream server.
        //
        // Correct TCP-forward semantics: a clean half-close on one
        // direction does NOT terminate the other. When the remote
        // stream drains, send a FIN to the local peer, then use a
        // short watchdog cancel only if the local receive stays stuck.
        let logID = shortID
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                do {
                    try await pumpLocalToRemote(outbound: outbound)
                } catch {
                    DiagnosticLogStore.appendForwarding("connection pump-failed id=\(logID) direction=up error='\(error)'")
                    // local→remote pump ended on error. The remote
                    // channel will close when `executeThenClose`
                    // returns, finishing the inbound iterator.
                }
            }

            group.addTask { [self] in
                var endedCleanly = false
                do {
                    try await pumpRemoteToLocal(inbound: inbound)
                    endedCleanly = true
                } catch {
                    DiagnosticLogStore.appendForwarding("connection pump-failed id=\(logID) direction=down error='\(error)'")
                    // Same — fall through to local.cancel() below.
                }

                if endedCleanly {
                    await scheduleLocalCancelWatchdog()
                } else {
                    local.cancel()
                }
            }

            await group.waitForAll()
        }
    }

    private func pumpLocalToRemote(outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws {
        while true {
            try Task.checkCancellation()

            let received = try await receiveFromLocal()
            if let data = received.data, !data.isEmpty {
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)

                try await outbound.write(buffer)
                bytesUp += UInt64(data.count)
            }

            if received.isComplete {
                outbound.finish()
                return
            }
        }
    }

    private func pumpRemoteToLocal(inbound: NIOAsyncChannelInboundStream<ByteBuffer>) async throws {
        for try await buffer in inbound {
            try Task.checkCancellation()

            let data = Data(buffer.readableBytesView)
            guard !data.isEmpty else {
                continue
            }

            try await sendToLocal(data)
            bytesDown += UInt64(data.count)
        }

        try await halfCloseLocal()
    }

    private func receiveFromLocal() async throws -> (data: Data?, isComplete: Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            local.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func sendToLocal(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            local.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func halfCloseLocal() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            local.send(content: nil, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func scheduleLocalCancelWatchdog() {
        localCancelWatchdog?.cancel()

        let local = local
        localCancelWatchdog = Task { @MainActor [weak self, local] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard let self, !Task.isCancelled, !self.didCleanUp else {
                return
            }

            local.cancel()
        }
    }

    private func cleanUp(cancelLocal: Bool) async {
        guard !didCleanUp else {
            return
        }

        didCleanUp = true
        localCancelWatchdog?.cancel()
        localCancelWatchdog = nil
        readyWaiter?.resume(throwing: PortForwardConnectionError.cancelled)
        readyWaiter = nil

        remote.outbound.finish()
        if cancelLocal {
            local.cancel()
        }
        local.stateUpdateHandler = nil
        try? await remote.channel.close().get()

        DiagnosticLogStore.appendForwarding(
            "connection summary id=\(shortID) cancelLocal=\(cancelLocal) durationMs=\(durationMs) bytesUp=\(bytesUp) bytesDown=\(bytesDown)"
        )
    }

    private func notifyClosed() {
        guard !didNotifyClose else {
            return
        }

        didNotifyClose = true
        Task { @MainActor in
            self.onClose?()
        }
    }

    nonisolated static func == (lhs: PortForwardConnection, rhs: PortForwardConnection) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private var shortID: String {
        String(id.uuidString.prefix(8))
    }

    private var durationMs: Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
}

private final class PortForwardConnectionReadyWaiter: @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Error>?
    private var didResume = false

    func resume(returning value: Void) {
        guard !didResume else {
            return
        }

        didResume = true
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        guard !didResume else {
            return
        }

        didResume = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
