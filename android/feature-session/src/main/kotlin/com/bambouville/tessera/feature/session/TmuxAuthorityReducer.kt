package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySession
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionResult
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionState

/** JNI session boundary. Policy and cached native responses belong to the shared session. */
internal class TmuxAuthorityReducer(
    val session: SharedTmuxAuthoritySession = SharedTmuxAuthoritySession.create(),
    /** Counts actual submissions in adapter tests; never substitutes authority policy. */
    private val onSubmit: ((SharedTmuxAuthoritySessionResult?) -> Unit)? = null,
    /** Sees each runtime reduction adopted in adapter tests; not a submission. */
    private val onAdopt: ((SharedTmuxAuthoritySessionResult) -> Unit)? = null,
) : AutoCloseable {
    fun submit(
        nowMillis: Long,
        event: (SharedTmuxAuthoritySession, Long) -> SharedTmuxAuthoritySessionResult,
    ): SharedTmuxAuthoritySessionResult {
        return event(session, nowMillis).also { onSubmit?.invoke(it) }
    }

    /** A reduction the attached runtime made of a read's stamps; no JNI call. */
    fun adopt(result: SharedTmuxAuthoritySessionResult): SharedTmuxAuthoritySessionResult =
        session.adopt(result).also { onAdopt?.invoke(it) }

    fun snapshot(nowMillis: Long): SharedTmuxAuthoritySessionState {
        onSubmit?.invoke(null)
        return session.snapshot(nowMillis)
    }

    override fun close() = session.close()
}
