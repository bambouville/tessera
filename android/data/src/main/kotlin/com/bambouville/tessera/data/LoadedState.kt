package com.bambouville.tessera.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn

/**
 * A repository's list, hot and replaying, with `null` meaning "not loaded yet".
 *
 * A screen that collects a cold Room flow with `initial = emptyList()` renders
 * one frame of "no hosts" before the database answers — and because the tab
 * content is rebuilt on every switch, that empty state flashes *every time* the
 * user taps the tab, not just at startup. Replaying the last value removes the
 * flash on re-entry, and the null sentinel removes it on first load, because
 * the screen can tell an empty database from an unanswered one.
 *
 * Eager sharing is deliberate: these are app-scoped repositories holding a
 * handful of rows, so the first tap should find the data already there.
 */
internal fun <T> Flow<T>.loadedState(scope: CoroutineScope): StateFlow<T?> =
    stateIn(scope, SharingStarted.Eagerly, null)

internal fun repositoryScope(): CoroutineScope =
    CoroutineScope(SupervisorJob() + Dispatchers.IO)
