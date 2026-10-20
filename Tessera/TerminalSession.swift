import Foundation
import TesseraCore

/// A background sampler, deliberately not a MainActor task: a frozen UI must
/// still leave evidence of the queue it is preventing from draining. Weak
/// registrations do not extend session/stream lifetimes. No terminal content
/// or input bytes are logged.
enum SessionLatencyDiagnostics {
    private final class Registration {
        weak var queue: AsyncDeliveryDiagnostics?
        let label: String
        init(_ queue: AsyncDeliveryDiagnostics, label: String) {
            self.queue = queue; self.label = label
        }
    }
    private static let lock = NSLock()
    private static var registrations: [Registration] = []
    private static var sampler: Task<Void, Never>?
    private static let mainPulse = AsyncDeliveryDiagnostics()

    static func queue(host: UUID, stage: String) -> AsyncDeliveryDiagnostics {
        // Freeze enablement for this queue lifetime: toggling halfway through
        // a FIFO would misalign producer/consumer timestamps. Reconnect after
        // enabling verbose diagnostics to start a fresh measurement.
        let queue = AsyncDeliveryDiagnostics(enabled: DiagnosticLogStore.isVerboseEnabled)
        guard queue.isEnabled else { return queue }
        lock.lock()
        registrations.append(Registration(queue, label: "host=\(host.uuidString.prefix(8)) stage=\(stage)"))
        if sampler == nil {
            sampler = Task.detached(priority: .utility) {
                var ticks = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    mainPulse.enqueued()
                    DispatchQueue.main.async { mainPulse.consumed() }
                    ticks += 1
                    if ticks % 20 == 0 { sample() }
                }
            }
        }
        lock.unlock()
        return queue
    }

    private static func sample() {
        lock.lock()
        registrations.removeAll { $0.queue == nil }
        let current = registrations.compactMap { entry in entry.queue.map { ($0, entry.label) } }
        lock.unlock()
        let records = (current + [(mainPulse, "host=app stage=main-actor-pulse")]).map { queue, label in
            let s = queue.snapshot()
            return "latency-v3 \(label) pending=\(s.pending) peak=\(s.maximumPending) oldestMs=\(s.oldestPendingMs.map { String(Int($0)) } ?? "unknown") received=\(s.received) consumed=\(s.consumed) discarded=\(s.discarded) maxWaitMs=\(Int(s.maximumWaitMs)) sumWaitMs=\(Int(s.totalWaitMs)) clipped=\(s.clippedSamples)"
        }
        DiagnosticLogStore.appendSSHBatch(records)
    }
}

/// Lifecycle state for a single terminal transport session.
///
/// Shared between SSH and (future) mosh sessions. The five cases map
/// 1:1 onto the top-bar status-dot color (grey → grey → green → grey →
/// red) and onto the sidebar row's label text; any new transport added
/// later must project its internal state into one of these five buckets.
public enum SessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)

    /// The case name alone — the only form of this value that may reach the
    /// diagnostics log.
    ///
    /// `String(describing:)` renders `.failed`'s payload, which is
    /// `describeSSHError(_:)` and falls through to `String(describing: error)`
    /// for anything that is neither a `LocalizedError` nor POSIX — NIO's
    /// connection errors among them. The sanitizer's only guard is
    /// `failed\([^)]*\)`, and `[^)]*` stops at the **first** `)`. NIO reports one
    /// `SingleConnectionFailure` per resolved address, so on a host with more
    /// than one A/AAAA record every address after the first sits outside the
    /// match and survives verbatim into a file the user is invited to send to a
    /// developer (`LaunchDiagnosticsPrivacyTests` pins that leak).
    ///
    /// Nothing diagnostic is lost by dropping the payload here: the reason is
    /// already logged, redacted, as `error='…'` by the transport.
    public var diagnosticName: String {
        switch self {
        case .idle:         return "idle"
        case .connecting:   return "connecting"
        case .connected:    return "connected"
        case .disconnected: return "disconnected"
        case .failed:       return "failed"
        }
    }
}

/// Output provenance captured by a concrete transport run. The attempt ID is
/// assigned by `SessionEngine` before connect and travels with every chunk, so
/// teardown from an older SSH task cannot be relabeled as reconnect output.
struct SessionAttemptOutputChunk: Sendable {
    let attemptID: UUID
    let bytes: [UInt8]
    let deliveryID: UInt64?
    let repaintRequestID: UInt64?

    init(
        attemptID: UUID,
        bytes: [UInt8],
        deliveryID: UInt64? = nil,
        repaintRequestID: UInt64? = nil
    ) {
        self.attemptID = attemptID
        self.bytes = bytes
        self.deliveryID = deliveryID
        self.repaintRequestID = repaintRequestID
    }
}

/// Transport-agnostic API surface for a live terminal session.
///
/// The concrete types (`SSHSession` today, `MoshSession` later) each
/// conform. `SessionView` and friends do NOT consume this as an
/// existential — SwiftUI's `@StateObject` / `@ObservedObject` property
/// wrappers reject `any TerminalSession` because an existential does
/// not itself satisfy `ObservableObject`. The `Session` enum exists
/// precisely to work around that: SwiftUI layers branch on the enum
/// case and wrap the matching concrete type. This protocol is for
/// test harnesses and transport-agnostic wiring (e.g. `TmuxController`
/// fanout) that only need the common surface. SwiftUI presentation dispatches
/// shared `SessionCommand` values through `sessionCommands`; these primitive
/// methods are the Apple transport implementation boundary, not UI policy.
@MainActor
public protocol TerminalSession: AnyObject {
    var host: Host { get }
    var state: SessionState { get }
    var outputStream: AsyncStream<[UInt8]> { get }

    /// Last cwd this session's terminal reported (tmux pane path, OSC 7,
    /// or the bridge cwd poller) — the session view keeps it current so
    /// transport-agnostic consumers (Upload sheet host rows) can read it
    /// without reaching into per-view state. nil until a signal arrives.
    var remoteWorkingDirectory: String? { get set }

    /// Absolute remote path queued for typing into this session's
    /// terminal (Upload sheet's "paste path"). Producers set it from
    /// anywhere; the session view consumes it via its tmux controller
    /// (which routes per transport) and resets it to nil.
    var pendingPathInjection: String? { get set }

    func connect()
    func send(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func disconnect()
}
