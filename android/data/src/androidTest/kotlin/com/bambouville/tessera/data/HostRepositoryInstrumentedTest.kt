package com.bambouville.tessera.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HostRepositoryInstrumentedTest {
    @Test
    fun simultaneousBootstrapPinsInsertExactlyOneAndNeverReplaceIt() = runBlocking {
        val repository = AndroidKnownHostsRepository(InstrumentationRegistry.getInstrumentation().targetContext)
        val hostname = "qr-race-${UUID.randomUUID()}.example"
        try {
            val results = (1..24).map { value ->
                async(Dispatchers.IO) {
                    repository.trustIfUnchanged(hostname, 22, "ssh-ed25519", byteArrayOf(value.toByte()), null)
                }
            }.awaitAll()
            assertEquals(1, results.count { it })
            val winner = repository.observeKnownHosts().first().single {
                it.normalizedEndpoint == AndroidKnownHostsRepository.normalizeEndpoint(hostname, 22)
            }.canonicalKeyBlob.copyOf()
            assertTrue(!repository.trustIfUnchanged(hostname, 22, "ssh-ed25519", byteArrayOf(99), null))
            assertTrue(repository.observeKnownHosts().first().single {
                it.normalizedEndpoint == AndroidKnownHostsRepository.normalizeEndpoint(hostname, 22)
            }.canonicalKeyBlob.contentEquals(winner))
        } finally {
            repository.forget(hostname, 22)
        }
    }

    @Test
    fun persistsDirectAndOrderedJumpHostsWithoutSecrets() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AndroidHostRepository(context)
        val token = UUID.randomUUID().toString()

        val jump = repository.save(
            HostDraft(
                displayName = "Jump $token",
                hostname = "jump-$token.example",
                username = "jumpuser",
            ),
        )
        val destination = repository.save(
            HostDraft(
                displayName = "Destination $token",
                hostname = "destination-$token.example",
                port = 2222,
                username = "destinationuser",
                jumpHostId = jump.id,
                launchCommand = "printf 'launch\\n'",
                notes = "Preserved bootstrap notes",
                envVars = "QR_TEST='two words'",
                startupSnippet = "printf 'startup\\n'",
            ),
        )

        try {
            assertEquals(destination, repository.host(destination.id))
            assertEquals(jump.id, repository.host(destination.id)?.jumpHostId)
            assertEquals(listOf(jump, destination), repository.resolveRoute(destination.id))
            assertTrue(repository.observeHosts().first().any { it.id == destination.id })
        } finally {
            assertTrue(repository.delete(destination.id))
            assertTrue(repository.delete(jump.id))
            assertNull(repository.host(destination.id))
        }
    }

    @Test
    fun knownHostRequiresExplicitTrustAndDetectsChange() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AndroidKnownHostsRepository(context)
        val hostname = "known-${UUID.randomUUID()}.example"
        val algorithm = "ssh-ed25519"
        fun key(fill: Byte): ByteArray = java.nio.ByteBuffer.allocate(51)
            .putInt(11).put("ssh-ed25519".toByteArray()).putInt(32).put(ByteArray(32) { fill }).array()
        val original = key(1)
        val changed = key(2)

        assertEquals(
            HostTrustEvaluation.Unknown,
            repository.evaluate(hostname, 22, algorithm, original),
        )
        repository.trust(hostname, 22, algorithm, original)
        try {
            assertEquals(
                HostTrustEvaluation.Trusted,
                repository.evaluate(hostname, 22, algorithm, original),
            )
            val evaluation = repository.evaluate(hostname, 22, algorithm, changed)
            assertTrue(evaluation is HostTrustEvaluation.Changed)
            assertTrue(
                (evaluation as HostTrustEvaluation.Changed)
                    .previousCanonicalKeyBlob
                    .contentEquals(original),
            )
            assertTrue(
                repository.evaluate(hostname, 22, "ssh-rsa", original) is
                    HostTrustEvaluation.Changed,
            )
            repository.trust(hostname, 22, algorithm, changed)
            val reverted = repository.evaluate(hostname, 22, algorithm, original)
            assertTrue(reverted is HostTrustEvaluation.Reverted)
            assertTrue(
                (reverted as HostTrustEvaluation.Reverted)
                    .currentCanonicalKeyBlob
                    .contentEquals(changed),
            )
        } finally {
            assertTrue(repository.forget(hostname, 22))
        }
    }

    @Test
    fun rejectsJumpCyclesBeforePersistingThem() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AndroidHostRepository(context)
        val token = UUID.randomUUID().toString()
        val first = repository.save(
            HostDraft(displayName = "First $token", hostname = "first-$token.example", username = "tester"),
        )
        val second = repository.save(
            HostDraft(
                displayName = "Second $token",
                hostname = "second-$token.example",
                username = "tester",
                jumpHostId = first.id,
            ),
        )
        try {
            val failure = runCatching {
                repository.save(
                    HostDraft(
                        id = first.id,
                        displayName = first.displayName,
                        hostname = first.hostname,
                        port = first.port,
                        username = first.username,
                        jumpHostId = second.id,
                    ),
                )
            }.exceptionOrNull()
            assertTrue(failure is IllegalArgumentException)
            assertNull(repository.host(first.id)?.jumpHostId)
        } finally {
            repository.delete(second.id)
            repository.delete(first.id)
        }
    }

    @Test
    fun interruptedAccessMarkersSurviveAcrossAttemptsAndClearAfterVerifiedHostLinkage() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AndroidCrossDeviceReceiptRepository(context)
        val hostId = UUID.randomUUID().toString()
        val firstAttempt = UUID.randomUUID().toString()
        val secondAttempt = UUID.randomUUID().toString()

        repository.stagePendingAccess(
            PendingCrossDeviceAccess(firstAttempt, hostId, "identity-first", 1),
        )
        repository.stagePendingAccess(
            PendingCrossDeviceAccess(secondAttempt, hostId, "identity-second", 2),
        )

        assertEquals(1, repository.pendingAccess(firstAttempt).size)
        assertEquals(2, repository.pendingAccess().count { it.hostId == hostId })

        repository.clearPendingAccessForHost(hostId)
        assertTrue(repository.pendingAccess().none { it.hostId == hostId })
    }
}
