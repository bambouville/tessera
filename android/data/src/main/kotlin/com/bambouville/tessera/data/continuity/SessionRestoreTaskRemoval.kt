package com.bambouville.tessera.data.continuity

import com.bambouville.tessera.data.SessionRestoreRepository

/**
 * What removing Tessera's task from the recents list does to the restore stores.
 *
 * This exists as its own entry point because the behaviour is otherwise only
 * reachable through `Service.onTaskRemoved`, which a test cannot call: the
 * service publishes no binder, so neither `ServiceTestRule` nor instrumentation
 * can get hold of an instance. The rule and the wipe both live here so both can
 * be pinned — the rule on the JVM, the wipe against real stores on a device.
 */
object SessionRestoreTaskRemoval {
    /**
     * Whether removing the task discards the stored sessions.
     *
     * Only when restore is off. A swipe out of recents used to retire the
     * document outright on the grounds that removing the task is an explicit
     * request to end this app instance — but it is a request to end *this*
     * instance, and the restore setting is the user's standing answer about
     * what the next one should do. Overruling it here meant the most natural
     * way to test "restart the app" was the one way restore could never work,
     * and iOS has always treated the same gesture as an ordinary termination.
     *
     * NEVER still clears, because NEVER clears on every other path too.
     */
    fun retiresStoredSessions(policy: SessionRestorePolicy): Boolean =
        policy == SessionRestorePolicy.NEVER

    /** Apply [retiresStoredSessions] to both stores. */
    suspend fun apply(
        policy: SessionRestorePolicy,
        records: SessionRestoreRepository,
        documents: AndroidForegroundRestoreStore,
    ) {
        if (!retiresStoredSessions(policy)) return
        records.deleteAll()
        documents.clear()
    }
}
