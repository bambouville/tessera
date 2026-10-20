package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedMoshGrammar
import com.bambouville.tessera.core.bridge.SharedMoshServerLiveness
import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy
import com.bambouville.tessera.core.bridge.SharedSessionPolicy
import com.bambouville.tessera.data.continuity.SessionRestorePolicy

/**
 * The Mosh recovery decisions this platform still owns, plus the delegations
 * for the ones it does not.
 *
 * Swift authority for the delegated parts:
 * `Packages/TesseraCore/Sources/TesseraSessionCore/MoshBootstrapGrammar.swift`
 * (`makeServerTerminationScript`) and `SessionEndClassification.swift`
 * (`SessionRetryPolicy`, the mosh end-event rule), reached through
 * `SharedMoshGrammar` / `SharedSessionPolicy`.
 */
internal object MoshSessionRecoveryPolicy {
    enum class ServerLossDecision(val diagnosticValue: String) {
        REBUILD("rebuild"),
        KEEP_FOR_LAUNCH_COMMAND("launch-command"),
    }

    /** A lost server cannot replay a custom command without the user's explicit always policy. */
    fun serverLossDecision(
        hasTmuxTarget: Boolean,
        launchCommand: String?,
        restorePolicy: SessionRestorePolicy,
    ): ServerLossDecision = if (
        hasTmuxTarget || launchCommand.isNullOrBlank() || restorePolicy == SessionRestorePolicy.ALWAYS
    ) ServerLossDecision.REBUILD else ServerLossDecision.KEEP_FOR_LAUNCH_COMMAND

    /**
     * Jump-route fallback is genuinely Android's: it exists because this
     * platform's UDP path over a jump host can stay unestablished while the
     * remote server is demonstrably running.
     */
    fun shouldFallBackFromJumpRoute(
        hopCount: Int,
        connected: Boolean,
        remoteServerPid: Int?,
    ): Boolean = hopCount > 1 && !connected && remoteServerPid != null && remoteServerPid > 0

    /** The shared reconnect ladder, one-based and clamped at both ends. */
    fun sideChannelRetryDelayMillis(attempt: Int): Long =
        SharedSessionPolicy.retryDelayMilliseconds(attempt)

    /**
     * Native Mosh reports only that its local transport stopped. Unlike SSH,
     * that callback carries no authenticated remote-shell exit status and the
     * far-side `mosh-server` is still there to re-attach, so it must remain
     * recoverable instead of deleting the saved session. A shutdown
     * *completion* — client and server agreeing the session is over — is the
     * event that does end the remote process, and this call site is not it.
     */
    fun remoteProcessEndedOnTransportDisconnect(): Boolean =
        SharedSessionPolicy.moshRemoteProcessEnded(isShutdownCompletion = false)

    /**
     * The PID-reuse-fenced termination script.
     *
     * The pid comes from mosh-server's detached banner and may be arbitrarily
     * stale, so the script re-checks `ps -o comm=` before signalling, treats an
     * already-exited server as success, and never escalates past TERM.
     */
    fun remoteServerTerminationCommand(serverPid: Int): String =
        SharedMoshGrammar.serverTerminationScript(serverPid)

    /** Read-only probe and verdict from `MoshBootstrapGrammar.swift`, via the C ABI. */
    fun serverLivenessCommand(pid: Int): String = SharedMoshGrammar.serverLivenessScript(pid)

    fun serverLiveness(output: String): SharedMoshServerLiveness = SharedMoshGrammar.serverLiveness(output)

    /** Grace and retry timing from `MoshServerLivenessPolicy.swift`; no platform ladder. */
    fun serverLivenessGraceMillis(): Long = SharedMoshServerLivenessPolicy.graceMillis()

    fun serverLivenessNextProbe(
        outcome: SharedMoshServerLivenessPolicy.Outcome,
        consecutiveHostFailures: Int,
        askedOwner: Boolean,
    ): SharedMoshServerLivenessPolicy.NextProbe =
        SharedMoshServerLivenessPolicy.nextProbe(outcome, consecutiveHostFailures, askedOwner)
}
