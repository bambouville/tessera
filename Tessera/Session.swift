import Foundation

/// Transport-typed wrapper around a live session object.
///
/// SwiftUI layers that need to bind an `ObservableObject` to a view
/// branch on this enum and declare their `@StateObject` /
/// `@ObservedObject` of the matching concrete type per branch.
/// Existentials of `ObservableObject` do not satisfy SwiftUI property
/// wrappers, so the enum is the chosen workaround — see the note on
/// `TerminalSession`.
///
/// Both SSH and mosh live here so `LiveSession`, `ContentView`, and
/// `SessionSidebar` can keep the transport split at the enum boundary
/// while still binding concrete `ObservableObject` session types.
enum Session {
    case ssh(SSHSession)
    case mosh(MoshSession)

    /// Type-erased view of the wrapped session. Useful for code paths
    /// that only need the transport-agnostic surface (lifecycle, byte
    /// I/O, resize) and don't care which transport is in play.
    @MainActor
    var terminalSession: any TerminalSession {
        switch self {
        case .ssh(let session): return session
        case .mosh(let session): return session
        }
    }
}
