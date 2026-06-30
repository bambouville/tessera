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

    func connect()
    func send(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func disconnect()
}
