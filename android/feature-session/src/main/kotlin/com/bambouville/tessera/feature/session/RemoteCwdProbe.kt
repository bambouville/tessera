package com.bambouville.tessera.feature.session

/**
 * Android peer of iOS RemoteCwdPoller command policy.
 *
 * The probe runs over a short-lived authenticated SSH exec channel, never the
 * interactive terminal. Plain Mosh has an exact mosh-server parent PID;
 * Files scopes plain SSH to its authenticated route. Callers on a separate
 * exec route retain the iOS newest tty-attached shell fallback.
 */
internal object RemoteCwdProbe {
    private const val MARKER = "TESSERA_CWD="

    private val cwdLookup =
        "[ -n \"\$sp\" ] && d=\$(readlink \"/proc/\$sp/cwd\" 2>/dev/null " +
            "|| lsof -a -p \"\$sp\" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1); " +
            "[ -n \"\$d\" ] && printf 'TESSERA_CWD=%s\\n' \"\$d\"; exit 0"

    internal val sshRouteShellSelector =
        "{ parent[\$1]=\$2; tty[\$1]=\$3; cmd[\$1]=\$4 } " +
        "END { root=parent[probe]; for (depth=0; root>1 && depth<32; depth++) { " +
        "best=0; for (pid in parent) { " +
        "if (tty[pid] !~ /^(pts\\/|ttys)/ || cmd[pid] !~ /sh\$/ || cmd[pid] ~ /ssh\$/) continue; " +
        "ancestor=pid; for (n=0; ancestor>1 && n<128; n++) { " +
        "if (parent[ancestor]==root) { if (pid+0>best) best=pid+0; break } " +
        "ancestor=parent[ancestor] } } " +
        "if (best) { print best; exit } " +
        "if (cmd[root] ~ /sshd/) exit; root=parent[root] } }"

    fun discoveryCommand(moshServerPid: Int?, sameSshRoute: Boolean = false): String {
        val payload = if (moshServerPid != null && moshServerPid > 0) {
            "sp=\$(pgrep -P $moshServerPid 2>/dev/null | head -n1); $cwdLookup"
        } else if (sameSshRoute) {
            // The browser's exec and terminal are children of the same sshd.
            // Walk past any login-shell wrappers, then search only that process
            // tree. A newer terminal on another connection must never win.
            "sp=\$(ps -u \"\${USER:-\$(id -un)}\" -o pid= -o ppid= -o tty= -o comm= 2>/dev/null " +
                "| awk -v probe=\"\$\$\" '" +
                "$sshRouteShellSelector'); $cwdLookup"
        } else {
            "sp=\$(ps -u \"\${USER:-\$(id -un)}\" -o pid= -o tty= -o comm= 2>/dev/null " +
                "| awk '\$2 ~ /^(pts\\/|ttys)/ && \$3 ~ /sh\$/ && \$3 !~ /ssh\$/ " +
                "{ if (\$1+0 > p) p = \$1+0 } END { if (p) print p }'); $cwdLookup"
        }
        return "sh -c '${payload.replace("'", "'\\''")}'"
    }

    fun reportedPath(output: String): String? = output.lineSequence()
        .map(String::trim)
        .firstOrNull { it.startsWith(MARKER) }
        ?.removePrefix(MARKER)
        ?.takeIf { path -> path.startsWith('/') && path.none(Char::isISOControl) }

    /**
     * Time between follow polls. Slow on purpose: this is a fallback signal and
     * every tick costs a remote exec. Mirrors the 2.5 s in
     * `TesseraDomainCore.RemoteCwdProbe.pollIntervalSeconds`.
     */
    const val POLL_INTERVAL_MILLIS = 2_500L

    /** A single miss is noise (shell mid-exec, pgrep hiccup); follow only clears after this many in a row. */
    const val MISSES_BEFORE_CLEARING_FOLLOW = 2

    /**
     * Identity for the coroutine driving a poll loop. Any change — panel
     * toggled, session backgrounded, tmux attached, bootstrap delivered a PID —
     * cancels the running loop so a fresh one re-decides whether to poll at all.
     */
    fun followTaskKey(
        panelOpen: Boolean,
        sessionActive: Boolean,
        tmuxAttached: Boolean,
        moshServerPid: Int?,
    ): String = listOf(
        if (panelOpen) "open" else "closed",
        if (sessionActive) "active" else "bg",
        if (tmuxAttached) "tmux" else "plain",
        moshServerPid?.toString() ?: "nopid",
    ).joinToString(":")

    /** What happened on one tick of the loop. */
    sealed interface Tick {
        /** The terminal's own OSC 7 is live and owns follow, so the probe is skipped. */
        data object OscSignalLive : Tick

        /** The probe ran; [output] is its merged stdout/stderr. */
        data class Probed(val output: String) : Tick

        /**
         * Nothing to poll (no live file channel). Deliberately not a miss: a
         * connection that is down says nothing about where the shell is.
         */
        data object NotPolled : Tick
    }

    /** What the loop should do with the browser's follow state. */
    sealed interface Outcome {
        data object Hold : Outcome
        data class Report(val path: String) : Outcome
        data object ClearFollow : Outcome
    }

    /**
     * The miss debounce as pure state, so both platforms flicker (or rather,
     * don't) identically. One instance per poll loop.
     */
    class FollowDebounce {
        var consecutiveMisses = 0
            private set

        fun step(tick: Tick): Outcome = when (tick) {
            Tick.NotPolled -> Outcome.Hold
            Tick.OscSignalLive -> {
                consecutiveMisses = 0
                Outcome.Hold
            }
            is Tick.Probed -> {
                val path = reportedPath(tick.output)
                if (path == null) {
                    consecutiveMisses += 1
                    // Exactly at the limit, never again: a host that stays
                    // silent must not re-clear an already-cleared follow.
                    if (consecutiveMisses == MISSES_BEFORE_CLEARING_FOLLOW) Outcome.ClearFollow else Outcome.Hold
                } else {
                    consecutiveMisses = 0
                    Outcome.Report(path)
                }
            }
        }
    }
}
