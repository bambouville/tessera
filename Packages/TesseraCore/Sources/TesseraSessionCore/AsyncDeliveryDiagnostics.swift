import Foundation

/// Metadata-only FIFO timing. Producers record immediately before yielding;
/// consumers record on delivery, so executor waits are included. Optional at
/// call sites and independent of the queue's admission/delivery policy.
public final class AsyncDeliveryDiagnostics: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let pending: UInt64
        public let maximumPending: UInt64
        public let oldestPendingMs: Double?
        public let received: UInt64
        public let consumed: UInt64
        public let discarded: UInt64
        public let maximumWaitMs: Double
        public let totalWaitMs: Double
        public let clippedSamples: UInt64
    }
    public let isEnabled: Bool
    private struct Entry { let sequence: UInt64; let nanos: UInt64 }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var head = 0
    private var sent: UInt64 = 0
    private var read: UInt64 = 0
    private var maximumPending: UInt64 = 0
    private var receivedWindow: UInt64 = 0
    private var consumedWindow: UInt64 = 0
    private var discardedWindow: UInt64 = 0
    private var maximumWaitMs = 0.0
    private var totalWaitMs = 0.0
    private var clipped: UInt64 = 0

    public init(enabled: Bool = true) { isEnabled = enabled }

    public func enqueued(nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        // A stranded consumer must not give diagnostics unbounded storage.
        // Preserve counts and explicitly report unavailable ages if clipped.
        if entries.count - head < 65_536 {
            entries.append(Entry(sequence: sent, nanos: nanos))
        } else { clipped += 1 }
        sent += 1
        receivedWindow += 1
        maximumPending = max(maximumPending, sent - read)
    }

    public func consumed(nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard read < sent else { return }
        if head < entries.count, entries[head].sequence == read {
            let start = entries[head].nanos
            let age = Double(nanos >= start ? nanos - start : 0) / 1e6
            maximumWaitMs = max(maximumWaitMs, age)
            totalWaitMs += age
            head += 1
            if head >= 64, head * 2 >= entries.count {
                entries.removeFirst(head)
                head = 0
            }
        }
        read += 1
        consumedWindow += 1
    }

    /// Resolves values removed by the queue without presenting them to its
    /// consumer. Only the oldest pending values may be discarded: callers
    /// with generation- or identity-aware queues should keep separate
    /// diagnostic instances rather than resetting a shared FIFO.
    public func discarded(count: Int) {
        guard isEnabled, count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let available = sent - read
        let amount = min(UInt64(count), available)
        guard amount > 0 else { return }
        let nextRead = read + amount
        while head < entries.count, entries[head].sequence < nextRead {
            head += 1
        }
        read = nextRead
        discardedWindow += amount
        if head >= 64, head * 2 >= entries.count {
            entries.removeFirst(head)
            head = 0
        }
    }

    public func snapshot(nanos: UInt64 = DispatchTime.now().uptimeNanoseconds,
                         resetWindow: Bool = true) -> Snapshot {
        guard isEnabled else {
            return Snapshot(pending: 0, maximumPending: 0, oldestPendingMs: 0,
                received: 0, consumed: 0, discarded: 0, maximumWaitMs: 0,
                totalWaitMs: 0, clippedSamples: 0)
        }
        lock.lock(); defer { lock.unlock() }
        let oldest: Double?
        if read == sent { oldest = 0 }
        else if head < entries.count, entries[head].sequence == read {
            oldest = Double(nanos >= entries[head].nanos ? nanos - entries[head].nanos : 0) / 1e6
        } else { oldest = nil }
        let result = Snapshot(pending: sent - read, maximumPending: maximumPending,
            oldestPendingMs: oldest, received: receivedWindow, consumed: consumedWindow,
            discarded: discardedWindow,
            maximumWaitMs: maximumWaitMs, totalWaitMs: totalWaitMs, clippedSamples: clipped)
        if resetWindow {
            maximumPending = sent - read
            receivedWindow = 0
            consumedWindow = 0
            discardedWindow = 0
            maximumWaitMs = 0
            totalWaitMs = 0
            clipped = 0
        }
        return result
    }
}
