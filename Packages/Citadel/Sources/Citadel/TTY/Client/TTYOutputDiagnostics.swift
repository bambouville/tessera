import Foundation
import NIOConcurrencyHelpers

/// Opt-in metadata-only measurement of the NIO-to-async-reader FIFO. Sampling
/// does not require the UI actor and never records terminal contents.
public final class TTYOutputDiagnostics: Sendable {
    public struct Snapshot: Sendable {
        public let pendingChunks: Int
        public let pendingBytes: Int
        public let oldestPendingMs: Double?
        public let clippedSamples: Int
        public let maximumPendingChunks: Int
        public let receivedChunks: Int
        public let consumedChunks: Int
        public let maximumReadWaitMs: Double
    }

    private struct Entry {
        let sequence: Int
        let nanos: UInt64
    }
    private struct State {
        var entries: [Entry] = []
        var head = 0
        var pendingBytes = 0
        var totalReceived = 0
        var totalConsumed = 0
        var clippedSamples = 0
        var maximumPendingChunks = 0
        var receivedChunks = 0
        var consumedChunks = 0
        var maximumReadWaitMs = 0.0
    }
    private let state = NIOLockedValueBox(State())

    public init() {}

    func received(bytes: Int, nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state.withLockedValue {
            if $0.entries.count - $0.head < 65_536 {
                $0.entries.append(Entry(sequence: $0.totalReceived, nanos: nanos))
            } else { $0.clippedSamples += 1 }
            $0.totalReceived += 1
            $0.pendingBytes += bytes
            $0.receivedChunks += 1
            $0.maximumPendingChunks = max($0.maximumPendingChunks, $0.totalReceived - $0.totalConsumed)
        }
    }

    func consumed(bytes: Int, nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state.withLockedValue {
            guard $0.totalConsumed < $0.totalReceived else { return }
            if $0.head < $0.entries.count, $0.entries[$0.head].sequence == $0.totalConsumed {
                $0.maximumReadWaitMs = max($0.maximumReadWaitMs, Self.age(nanos, $0.entries[$0.head].nanos))
                $0.head += 1
            }
            $0.totalConsumed += 1
            $0.pendingBytes -= bytes
            $0.consumedChunks += 1
            if $0.head >= 64, $0.head * 2 >= $0.entries.count {
                $0.entries.removeFirst($0.head)
                $0.head = 0
            }
        }
    }

    public func snapshot(resetWindow: Bool = true) -> Snapshot {
        snapshot(nanos: DispatchTime.now().uptimeNanoseconds, resetWindow: resetWindow)
    }

    func snapshot(nanos: UInt64, resetWindow: Bool) -> Snapshot {
        state.withLockedValue {
            let pending = $0.totalReceived - $0.totalConsumed
            let oldest: Double? = pending == 0 ? 0
                : ($0.head < $0.entries.count && $0.entries[$0.head].sequence == $0.totalConsumed
                    ? Self.age(nanos, $0.entries[$0.head].nanos) : nil)
            let result = Snapshot(
                pendingChunks: pending,
                pendingBytes: $0.pendingBytes,
                oldestPendingMs: oldest,
                clippedSamples: $0.clippedSamples,
                maximumPendingChunks: $0.maximumPendingChunks,
                receivedChunks: $0.receivedChunks,
                consumedChunks: $0.consumedChunks,
                maximumReadWaitMs: $0.maximumReadWaitMs
            )
            if resetWindow {
                $0.maximumPendingChunks = pending
                $0.receivedChunks = 0
                $0.consumedChunks = 0
                $0.maximumReadWaitMs = 0
                $0.clippedSamples = 0
            }
            return result
        }
    }

    private static func age(_ now: UInt64, _ start: UInt64) -> Double {
        Double(now >= start ? now - start : 0) / 1_000_000
    }
}
