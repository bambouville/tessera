import Foundation

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
/// fanout) that only need the common surface.
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
