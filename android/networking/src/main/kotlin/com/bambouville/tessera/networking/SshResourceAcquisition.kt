package com.bambouville.tessera.networking

import java.io.Closeable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * Transfers an SSH resource from a blocking IO open to its coroutine caller.
 * withContext can discard its result when cancellation wins the return to the
 * caller's dispatcher, even after the open succeeded. Retain the resource
 * outside that boundary so a discarded exec cannot consume a remote session
 * slot until the entire terminal route is disconnected.
 */
internal suspend fun <T : Closeable> acquireSshResource(
    dispose: (T) -> Unit = { it.close() },
    open: suspend CoroutineScope.() -> T,
): T {
    var acquired: T? = null
    try {
        return withContext(Dispatchers.IO) { open().also { acquired = it } }
    } catch (failure: Throwable) {
        withContext(NonCancellable + Dispatchers.IO) {
            acquired?.let { resource -> runCatching { dispose(resource) } }
        }
        throw failure
    }
}
