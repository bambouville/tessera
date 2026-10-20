package com.bambouville.tessera.agent.platform

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext

/**
 * Drains a bounded helper stream as one cancellable transaction.  Projectors
 * run remotely, so a child which keeps one pipe open must never pin a UI
 * request or a lifecycle-owned job indefinitely.
 */
object AgentRemoteStreamDrain {
    sealed interface Result {
        data class Complete(val stdout: ByteArray, val exit: AgentExecExitStatus) : Result
        data object TimedOut : Result
        data class Failed(val reason: String) : Result
    }

    suspend fun drain(
        stream: AgentRemoteExecStream,
        maxStdoutBytes: Int,
        timeoutMillis: Long,
    ): Result {
        require(maxStdoutBytes > 0)
        require(timeoutMillis > 0)
        return supervisorScope {
            val streamLifetimeLock = Any()
            var cancellationRequested = false
            suspend fun cancelStream() = withContext(NonCancellable + Dispatchers.IO) {
                synchronized(streamLifetimeLock) {
                    if (!cancellationRequested) {
                        cancellationRequested = true
                        stream.cancel()
                    }
                }
            }
            suspend fun <T> cancelOnFailure(block: suspend () -> T): T = try {
                block()
            } catch (failure: Throwable) {
                // Unblock the other pipe and exit waiter before their parent
                // waits for completion, including output-limit failures.
                cancelStream()
                throw failure
            }
            // The SSH adapter performs blocking reads and joins. Keep the
            // transaction outside withTimeout's child scope: that scope waits
            // for its children before throwing, so putting the readers inside
            // it prevented cancel() from unblocking them at the deadline.
            val transaction = async {
                coroutineScope {
                    val output = async {
                        cancelOnFailure {
                            val bytes = java.io.ByteArrayOutputStream(minOf(maxStdoutBytes, 262_144))
                            stream.stdout.collect { chunk ->
                                if (chunk.size > maxStdoutBytes - bytes.size()) error("stdout_too_large")
                                bytes.write(chunk)
                            }
                            bytes.toByteArray()
                        }
                    }
                    // The remote child may block on stderr before it closes
                    // stdout, so this must always run concurrently.
                    val errors = async { cancelOnFailure { stream.stderr.collect {} } }
                    val status = async { cancelOnFailure { stream.awaitExit() } }
                    val stdout = output.await()
                    errors.await()
                    Result.Complete(stdout, status.await())
                }
            }
            try {
                withTimeout(timeoutMillis) { transaction.await() }
            } catch (_: TimeoutCancellationException) {
                cancelStream()
                Result.TimedOut
            } catch (cancelled: CancellationException) {
                cancelStream()
                throw cancelled
            } catch (failure: Throwable) {
                cancelStream()
                Result.Failed(failure.message ?: "stream_failed")
            } finally {
                transaction.cancel()
                // cancel() and close() are blocking platform operations. Keep
                // them off the UI thread and prevent ordinary close from
                // overtaking a worker's in-progress cancellation.
                withContext(NonCancellable + Dispatchers.IO) {
                    synchronized(streamLifetimeLock) { stream.close() }
                }
            }
        }
    }
}
