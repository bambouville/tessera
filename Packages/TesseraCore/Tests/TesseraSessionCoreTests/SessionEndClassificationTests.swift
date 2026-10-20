import XCTest
@testable import TesseraSessionCore

/// The end-of-session invariants both platforms must agree on.
///
/// Ported from Android `SessionReconnectPolicyTest` plus the mosh half of
/// `MoshSessionRecoveryPolicyTest`, because the wrong answer here is not a
/// crash — it is a saved session quietly deleted, or a dead one that never
/// stops retrying.
final class SessionEndClassificationTests: XCTestCase {

    // MARK: - Exit status versus EOF

    /// Ported from Android
    /// `eofWithoutRemoteExitStatusIsRecoverableTransportLossNotSessionTermination`.
    func test_eofWithoutRemoteExitStatusIsNotARemoteExit() {
        XCTAssertFalse(SessionEndClassification.remoteProcessEnded(exitStatus: nil))
        XCTAssertTrue(SessionEndClassification.remoteProcessEnded(exitStatus: 0))
        XCTAssertTrue(SessionEndClassification.remoteProcessEnded(exitStatus: 255))
    }

    /// A clean `exit 0` is still an exit. The status's *value* never enters
    /// the decision — only its presence.
    func test_everyStatusValueCountsAsARemoteExit() {
        for status in [-1, 0, 1, 2, 127, 130, 255, 1_000] {
            XCTAssertTrue(
                SessionEndClassification.remoteProcessEnded(exitStatus: status),
                "status \(status) is authenticated evidence the shell finished"
            )
        }
    }

    /// EOF-without-status keeps the restore record; a remote exit retires it.
    func test_restoreRecordSurvivesEOFButNotARemoteExit() {
        XCTAssertTrue(SessionEndClassification.retainsRestoreRecord(exitStatus: nil))
        XCTAssertFalse(SessionEndClassification.retainsRestoreRecord(exitStatus: 0))
    }

    // MARK: - Mosh

    /// Native mosh reports only that its local transport stopped; the
    /// `mosh-server` on the far side is still there to re-attach to, so the
    /// session stays restorable.
    func test_moshTransportStopIsNotARemoteExit() {
        XCTAssertFalse(SessionEndClassification.remoteProcessEndedOnMoshTransportStop())
    }

    /// A mosh shutdown completion is the two ends agreeing the session is
    /// over — that does retire the record.
    func test_moshShutdownCompletionIsARemoteExit() {
        XCTAssertTrue(SessionEndClassification.remoteProcessEndedOnMoshShutdownCompletion())
    }

    // MARK: - Retry: the transient-marker table

    func test_transientMarkerTableIsTheElevenSharedMarkers() {
        XCTAssertEqual(
            SessionRetryPolicy.transientFailureMarkers,
            [
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
        )
    }

    /// Matching is a lowercased substring test, so a wrapped exception message
    /// still matches the marker buried in it.
    func test_transientDetectionIsCaseInsensitiveAndSubstringBased() {
        XCTAssertTrue(
            SessionRetryPolicy.isTransientFailureDetail(
                "SSHException: Software caused connection abort"
            )
        )
        XCTAssertTrue(SessionRetryPolicy.isTransientFailureDetail("Broken Pipe"))
        XCTAssertTrue(SessionRetryPolicy.isTransientFailureDetail("read timed out"))
        XCTAssertFalse(SessionRetryPolicy.isTransientFailureDetail("authentication failed"))
        XCTAssertFalse(SessionRetryPolicy.isTransientFailureDetail(""))
    }

    func test_everyMarkerInTheTableIsDetected() {
        for marker in SessionRetryPolicy.transientFailureMarkers {
            XCTAssertTrue(
                SessionRetryPolicy.isTransientFailureDetail("prefix \(marker.uppercased()) suffix"),
                "marker '\(marker)' must be recognised"
            )
        }
    }

    // MARK: - Retry: the structural rules

    /// Ported from Android `retriesForegroundResumeAbortAfterAConnectedTransport`.
    func test_retriesAnAbortAfterAConnectedTransport() {
        XCTAssertTrue(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: false,
                hadConnectedTransport: true,
                alreadyRecovering: false,
                code: "ssh_connection_failed",
                arguments: ["detail": "SSHException: Software caused connection abort"]
            )
        )
    }

    /// Ported from Android
    /// `neverRetriesExplicitDisconnectOrInitialAuthenticationFailure`.
    func test_neverRetriesAnExplicitDisconnectOrAnInitialAuthFailure() {
        XCTAssertFalse(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: true,
                hadConnectedTransport: true,
                alreadyRecovering: false,
                code: SessionRetryPolicy.transportDisconnectedCode,
                arguments: [:]
            )
        )
        XCTAssertFalse(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: false,
                hadConnectedTransport: false,
                alreadyRecovering: false,
                code: "ssh_connection_failed",
                arguments: ["detail": "authentication failed"]
            )
        )
    }

    /// The explicit-disconnect veto outranks everything, including the
    /// always-retry code.
    func test_explicitDisconnectOutranksTheAlwaysRetryCode() {
        XCTAssertFalse(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: true,
                hadConnectedTransport: true,
                alreadyRecovering: true,
                code: SessionRetryPolicy.transportDisconnectedCode,
                arguments: ["detail": "connection reset"]
            )
        )
    }

    /// A transport that never connected is not retried — unless a recovery is
    /// already in flight, which is what makes a reconnect attempt's own
    /// failure retryable.
    func test_aTransportThatNeverConnectedRetriesOnlyWhileAlreadyRecovering() {
        XCTAssertFalse(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: false,
                hadConnectedTransport: false,
                alreadyRecovering: false,
                code: SessionRetryPolicy.transportDisconnectedCode,
                arguments: [:]
            )
        )
        XCTAssertTrue(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: false,
                hadConnectedTransport: false,
                alreadyRecovering: true,
                code: SessionRetryPolicy.transportDisconnectedCode,
                arguments: [:]
            )
        )
    }

    /// `transport_disconnected` always retries, whatever detail rode along.
    func test_transportDisconnectedAlwaysRetries() {
        XCTAssertEqual(SessionRetryPolicy.transportDisconnectedCode, "transport_disconnected")
        XCTAssertTrue(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: false,
                hadConnectedTransport: true,
                alreadyRecovering: false,
                code: SessionRetryPolicy.transportDisconnectedCode,
                arguments: ["detail": "authentication failed"]
            )
        )
    }

    /// A non-transient detail after a working transport is a real failure, not
    /// a blip: retrying it hides it.
    func test_aNonTransientDetailIsNotRetried() {
        XCTAssertFalse(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: false,
                hadConnectedTransport: true,
                alreadyRecovering: false,
                code: "ssh_connection_failed",
                arguments: ["detail": "host key mismatch"]
            )
        )
        XCTAssertFalse(
            SessionRetryPolicy.shouldRetry(
                explicitDisconnect: false,
                hadConnectedTransport: true,
                alreadyRecovering: false,
                code: "ssh_connection_failed",
                arguments: [:]
            )
        )
    }

    func test_coreFailureConvenienceMatchesThePrimitiveForm() {
        let failure = CoreFailure(
            code: "ssh_connection_failed",
            arguments: ["detail": "Connection reset by peer"]
        )

        XCTAssertTrue(
            SessionRetryPolicy.shouldRetry(
                failure: failure,
                explicitDisconnect: false,
                hadConnectedTransport: true,
                alreadyRecovering: false
            )
        )
        XCTAssertFalse(
            SessionRetryPolicy.shouldRetry(
                failure: failure,
                explicitDisconnect: true,
                hadConnectedTransport: true,
                alreadyRecovering: false
            )
        )
    }

    // MARK: - Retry: the backoff ladder

    func test_backoffLadderIsTheSharedFiveRungTable() {
        XCTAssertEqual(SessionRetryPolicy.backoffLadderSeconds, [0.25, 0.5, 1.0, 2.0, 4.0])
        XCTAssertEqual(SessionRetryPolicy.maxAttempts, 5)
    }

    /// Attempts are one-based, and anything past the ladder holds at its last
    /// rung rather than growing without bound. Android's
    /// `side channel retry backoff is bounded`, in seconds.
    func test_retryDelayClimbsTheLadderAndThenHolds() {
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: 1), 0.25)
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: 2), 0.5)
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: 3), 1.0)
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: 4), 2.0)
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: 5), 4.0)
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: 6), 4.0)
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: 99), 4.0)
    }

    /// A zero or negative attempt is clamped up to the first rung rather than
    /// trapping — a caller that miscounts still gets a defined delay.
    func test_retryDelayClampsANonPositiveAttemptToTheFirstRung() {
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: 0), 0.25)
        XCTAssertEqual(SessionRetryPolicy.retryDelaySeconds(attempt: -3), 0.25)
    }

    func test_attemptCapMatchesTheLadderLength() {
        XCTAssertFalse(SessionRetryPolicy.permitsAttempt(0))
        for attempt in 1...5 {
            XCTAssertTrue(SessionRetryPolicy.permitsAttempt(attempt))
        }
        XCTAssertFalse(SessionRetryPolicy.permitsAttempt(6))
    }
}
