package com.bambouville.tessera.core.bridge

/**
 * The name and identifier grammars every platform must agree on.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraProtocolCore/TmuxTargetValidation.swift`
 * and `Sources/TesseraAgentCore/Actions/AgentActions.swift`
 * (`AgentLaunchValidator.isValidBranch`). The ABI seams are
 * `Sources/TesseraCoreABI/TmuxTargetABI.swift` and
 * `AgentIntegrationCommandsABI.swift`.
 *
 * These replace local charset literals. Three copies of the tmux session-name
 * literal on this platform had already drifted apart, and the branch check's
 * `isLetterOrDigit`-style Unicode acceptance diverged from the launch path
 * that actually runs the command.
 */

/** Why a tmux session name is unusable. */
enum class SharedTmuxNameRejection {
    Empty,
    TooLong,
    UnsafeCharacter,
}

/** Which kind of tmux object an identifier names. */
enum class SharedTmuxTargetKind(internal val code: Int) {
    /** `$123` */
    Session(0),

    /** `@7` */
    Window(1),

    /** `%9` */
    Pane(2),
}

object SharedTargetValidation {
    /**
     * Null when the name is usable.
     *
     * The grammar is deliberately conservative — ASCII alphanumerics plus `-`,
     * `_`, `.` — because these names are interpolated into fixed remote
     * commands without shell quoting.
     *
     * Every string has an answer here, [TooLong] included: the core decides
     * oversize on the byte count rather than refusing the argument, so a
     * pathologically long pasted name reaches the field message below instead
     * of the [error] branch. That branch is left for a core that answered
     * something this build does not know.
     */
    fun tmuxSessionNameRejection(name: String): SharedTmuxNameRejection? {
        NativeLibraries.ensureLoaded()
        val bytes = name.encodeToByteArray()
        return when (
            NativeCoreBindings.tmuxSessionNameValidate(
                if (bytes.isEmpty()) null else bytes.toDirectBuffer(),
                bytes.size,
            )
        ) {
            0 -> null
            1 -> SharedTmuxNameRejection.Empty
            2 -> SharedTmuxNameRejection.TooLong
            3 -> SharedTmuxNameRejection.UnsafeCharacter
            else -> error("shared tmux session name validation rejected a well-formed argument")
        }
    }

    fun isValidTmuxSessionName(name: String): Boolean = tmuxSessionNameRejection(name) == null

    /** Whether [value] is a well-formed tmux id of [kind]. */
    fun isValidTmuxTargetId(value: String, kind: SharedTmuxTargetKind): Boolean {
        NativeLibraries.ensureLoaded()
        val bytes = value.encodeToByteArray()
        return when (
            NativeCoreBindings.tmuxTargetIdValidate(
                if (bytes.isEmpty()) null else bytes.toDirectBuffer(),
                bytes.size,
                kind.code,
            )
        ) {
            0 -> false
            1 -> true
            // A zero-length or non-UTF-8 identifier is simply not one.
            else -> false
        }
    }

    /**
     * The one git-branch grammar behind agent launches: ASCII-only and bounded
     * in UTF-8 bytes. Pre-validate the field with this and show a field-level
     * message, rather than letting the launch path return an opaque failure.
     */
    fun isValidBranch(branch: String): Boolean {
        NativeLibraries.ensureLoaded()
        val bytes = branch.encodeToByteArray()
        return when (
            NativeCoreBindings.agentValidateBranch(
                if (bytes.isEmpty()) null else bytes.toDirectBuffer(),
                bytes.size,
            )
        ) {
            1 -> true
            else -> false
        }
    }
}
