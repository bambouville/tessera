import Foundation

/// What counts as the *end* of a session, as opposed to the end of one
/// transport attempt at carrying it.
///
/// The distinction is the whole difference between "reconnect and the user's
/// work is still there" and "delete the saved session". Both platforms have
/// shipped the wrong answer at least once, in opposite directions, so it is
/// stated here rather than re-derived per transport:
///
///  * A socket that reaches EOF proves only that the socket is gone. The
///    remote shell may still be running, and on mosh it usually is.
///  * A remote **exit status** is authenticated evidence from the far side
///    that the shell itself finished. Only that retires a restore record.
///
/// Nothing here consults a clock or a transport; the caller supplies what it
/// observed and gets back a classification it can act on.
public enum SessionEndClassification {
    /// The canonical exit-vs-EOF predicate.
    ///
    /// `nil` is EOF-without-status: recoverable transport loss, so the
    /// session stays reconnectable and its restore record stays. Any status —
    /// including `0` — is a genuine remote exit.
    public static func remoteProcessEnded(exitStatus: Int?) -> Bool {
        exitStatus != nil
    }

    /// Native mosh reports only that its local transport stopped. Unlike SSH,
    /// that callback carries no authenticated remote-shell exit status, so it
    /// must remain recoverable instead of deleting the saved session — the
    /// `mosh-server` on the far side is still there to be re-attached.
    public static func remoteProcessEndedOnMoshTransportStop() -> Bool { false }

    /// A mosh *shutdown completion*, by contrast, is the client and server
    /// agreeing that the session is over. That is a remote exit and retires
    /// the restore record.
    public static func remoteProcessEndedOnMoshShutdownCompletion() -> Bool { true }

    /// Whether a session that ended this way keeps its restore record.
    ///
    /// The inverse of a remote exit, spelled out because that is the decision
    /// the persistence layer actually makes.
    public static func retainsRestoreRecord(exitStatus: Int?) -> Bool {
        !remoteProcessEnded(exitStatus: exitStatus)
    }
}

/// When a session that lost its transport should try again, and how long it
/// should wait between tries.
///
/// The marker table below is Android's (`SessionReconnectPolicy.kt`) and is
/// canonical: it was tuned against real NIO/SSHJ failure strings. Matching is
/// a lowercase substring test against the failure's `detail` argument, so a
/// wrapped exception message still matches the marker it contains.
public enum SessionRetryPolicy {
    /// Eleven markers, ordered most specific first. Order does not affect the
    /// result — any match retries — but it documents which strings were the
    /// observed ones.
    public static let transientFailureMarkers: [String] = [
        "software caused connection abort",
        "connection reset",
        "broken pipe",
        "socket closed",
        "connection closed",
        "connection abort",
        "network is unreachable",
        "network unavailable",
        "timed out",
        "timeout",
        "eof",
    ]

    /// The failure code that means the transport dropped underneath a session
    /// that was working. It always retries, whatever detail came with it.
    public static let transportDisconnectedCode = "transport_disconnected"

    /// Shared backoff ladder, in seconds. Android carries the same values as
    /// milliseconds (250, 500, 1000, 2000, 4000); the core's unit rule is
    /// seconds as `Double`, so the Kotlin adapter converts at the edge.
    public static let backoffLadderSeconds: [TimeInterval] = [0.25, 0.5, 1.0, 2.0, 4.0]

    /// Attempts are capped at the ladder's length: five tries spanning ~7.75s
    /// of waiting. Past that the loss is not transient and a silent retry
    /// loop only hides it.
    public static let maxAttempts = backoffLadderSeconds.count

    /// True when `detail` contains any transient marker. Case-insensitive by
    /// lowercasing first, exactly as the Kotlin original does.
    public static func isTransientFailureDetail(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return transientFailureMarkers.contains { lowered.contains($0) }
    }

    /// The structural rules, in the order they are allowed to fire:
    ///
    ///  1. An explicit disconnect is never retried — the user asked for it.
    ///  2. A transport that never connected is never retried either, unless a
    ///     recovery is already in flight. A first-attempt failure is a
    ///     configuration or credential problem, and retrying it just spends
    ///     the user's lockout budget.
    ///  3. `transport_disconnected` always retries.
    ///  4. Otherwise, retry only if the detail names a transient failure.
    public static func shouldRetry(
        explicitDisconnect: Bool,
        hadConnectedTransport: Bool,
        alreadyRecovering: Bool,
        code: String,
        arguments: [String: String]
    ) -> Bool {
        if explicitDisconnect || (!hadConnectedTransport && !alreadyRecovering) {
            return false
        }
        if code == transportDisconnectedCode { return true }
        return isTransientFailureDetail(arguments["detail"] ?? "")
    }

    /// Convenience over the core's own failure type.
    public static func shouldRetry(
        failure: CoreFailure,
        explicitDisconnect: Bool,
        hadConnectedTransport: Bool,
        alreadyRecovering: Bool
    ) -> Bool {
        shouldRetry(
            explicitDisconnect: explicitDisconnect,
            hadConnectedTransport: hadConnectedTransport,
            alreadyRecovering: alreadyRecovering,
            code: failure.code,
            arguments: failure.arguments
        )
    }

    /// Delay before `attempt`, one-based. Attempts past the ladder's end hold
    /// at its last rung rather than growing without bound, so a caller that
    /// keeps asking still gets a defined answer.
    public static func retryDelaySeconds(attempt: Int) -> TimeInterval {
        let index = min(max(attempt, 1) - 1, backoffLadderSeconds.count - 1)
        return backoffLadderSeconds[index]
    }

    /// Whether a one-based `attempt` is still within the cap.
    public static func permitsAttempt(_ attempt: Int) -> Bool {
        attempt >= 1 && attempt <= maxAttempts
    }
}
