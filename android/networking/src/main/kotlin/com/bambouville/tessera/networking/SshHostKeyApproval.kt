package com.bambouville.tessera.networking

import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

/** A local trust check can defer a human decision without changing policy SAM callers. */
class SshHostKeyApprovalRequired(
    val observation: SshHostKeyObservation,
    val approve: suspend () -> Boolean,
) : Exception("SSH host key requires approval")

/** The person declined the key, or let its prompt expire: retrying would only ask again. */
class SshHostKeyRejected(
    val observation: SshHostKeyObservation,
    cause: Throwable,
) : java.io.IOException("The server's host key was not trusted", cause)

/**
 * SSHJ's 30 s KEX wait cannot contain a human decision. Each attempt must close
 * all of its resources before throwing; only then may we ask and restart at hop zero.
 */
internal suspend fun <T> withSshHostKeyApproval(
    policy: SshHostKeyPolicy,
    decisionTimeoutMilliseconds: Long = AndroidSshBackend.HOST_KEY_DECISION_TIMEOUT_MILLISECONDS,
    connect: suspend ((SshHostKeyObservation) -> Boolean) -> T,
): T {
    val context = currentCoroutineContext()
    val approvals = mutableMapOf<Pair<String, Int>, Int>()
    while (true) {
        context.ensureActive()
        val rejected = AtomicReference<SshHostKeyApprovalRequired?>()
        val verify: (SshHostKeyObservation) -> Boolean = { observation ->
            try {
                // Only local known-host storage runs here, never the challenge UI.
                runBlocking {
                    withTimeout(LOCAL_TRUST_TIMEOUT_MILLISECONDS) { policy.verify(observation) }
                }
            } catch (approval: SshHostKeyApprovalRequired) {
                rejected.compareAndSet(null, approval)
                false
            }
        }
        try {
            return connect(verify)
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            context.ensureActive()
            val approval = rejected.get() ?: throw failure
            val endpoint = approval.observation.let { it.host to it.port }
            val count = approvals.getOrDefault(endpoint, 0)
            if (count >= MAX_APPROVALS_PER_ENDPOINT) throw failure
            approvals[endpoint] = count + 1
            val accepted = withTimeoutOrNull(decisionTimeoutMilliseconds) { approval.approve() } ?: false
            context.ensureActive()
            if (!accepted) throw SshHostKeyRejected(approval.observation, failure)
        }
    }
}

private const val LOCAL_TRUST_TIMEOUT_MILLISECONDS = 5_000L
private const val MAX_APPROVALS_PER_ENDPOINT = 2
