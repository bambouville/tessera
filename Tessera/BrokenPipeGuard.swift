// Tessera/BrokenPipeGuard.swift
// Keeps a write to a closed socket or pipe from ending the app without a trace.
import Darwin

/// Writing to a socket or pipe that can no longer carry data raises SIGPIPE,
/// and its default action ends the process on the spot: no crash report, no
/// final log line. While the app is suspended, iOS may reclaim its sockets;
/// XNU then fails a send on one with EPIPE and raises SIGPIPE unless the
/// socket has SO_NOSIGPIPE. Mosh's UDP socket had neither, and the first send
/// after a long suspension ended the app: reopening it showed its snapshot
/// for a moment and dropped back to the home screen. The mosh-client frontend
/// handles SIGPIPE, but Tessera does not build it. SwiftNIO and
/// Network.framework mark their own sockets.
///
/// Ignoring the signal for the whole process covers every other writer too:
/// a write to a dead descriptor fails with EPIPE, which its caller handles.
enum BrokenPipeGuard {
    /// Call first thing at launch, before anything opens a socket.
    static func install() {
        signal(SIGPIPE, SIG_IGN)
        DiagnosticLogStore.appendApp(
            "process-start pid=\(getpid()) sigpipe=\(isIgnoringBrokenPipes ? "ignored" : "default")"
        )
    }

    /// Whether SIGPIPE is ignored for the whole process.
    static var isIgnoringBrokenPipes: Bool {
        var current = sigaction()
        guard sigaction(SIGPIPE, nil, &current) == 0 else { return false }
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
            == unsafeBitCast(SIG_IGN, to: Int.self)
    }
}
