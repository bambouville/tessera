package com.bambouville.tessera.feature.pairing

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.data.CrossDeviceReceipt
import com.bambouville.tessera.data.CrossDeviceReceiptRepository
import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.HostRepository
import com.bambouville.tessera.data.HostTrustEvaluation
import com.bambouville.tessera.data.IdentityRepository
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.AndroidKnownHostsRepository
import com.bambouville.tessera.data.PendingCrossDeviceAccess
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.SavedIdentity
import com.bambouville.tessera.data.SavedKnownHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith

/**
 * Complete Android adapter proof around two independent shared-core runtimes.
 * The grant mutation itself is captured instead of touching a real account;
 * the networking gate separately proves the same generated P-256 key can be
 * installed into authorized_keys and used for direct and jump-host SSH.
 */
@RunWith(AndroidJUnit4::class)
class CrossDeviceBootstrapAdapterInstrumentedTest {
    @Before
    fun requireUnlockedTestDevice() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue("Unlock the disposable test device before running credential/storage pairing tests",
            !context.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked)
    }
    @Test
    fun continuationAllFourTransportsWaitsForTheExactRenderedAttempt() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for (transport in listOf(TransportKinds.SSH, TransportKinds.MOSH)) {
            for (tmux in listOf(false, true)) {
                val host = SavedHost(
                    UUID.randomUUID().toString(), "Continuation fixture", "continuation.example", 22, "developer",
                    null, null, transport, if (tmux) TmuxModes.PINNED else TmuxModes.OFF,
                    if (tmux) "exact-workspace" else null,
                )
                val originScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                val recipientScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                val connection = kotlinx.coroutines.CompletableDeferred<Triple<String, String?, String>>()
                val origin = CrossDevicePairingCoordinator(context, FakeHostRepository(listOf(host)), FakeIdentityRepository(),
                    FakeKnownHostsRepository(), AndroidKeystoreCredentialStore(), originScope,
                    onConnectionRequired = { _, _, _, _ -> error("source must not reconnect") },
                    recordDiagnostic = { _, _ -> },
                    testDependencies = PairingTestDependencies(FakeReceiptRepository()) { _, _ -> error("no grant") })
                val recipient = CrossDevicePairingCoordinator(context, FakeHostRepository(listOf(host)), FakeIdentityRepository(),
                    FakeKnownHostsRepository(), AndroidKeystoreCredentialStore(), recipientScope,
                    onConnectionRequired = { id, wireTransport, target, attempt ->
                        assertEquals(transport, wireTransport)
                        connection.complete(Triple(id, target, attempt))
                    },
                    recordDiagnostic = { _, _ -> },
                    testDependencies = PairingTestDependencies(FakeReceiptRepository()) { _, _ -> error("no grant") })
                try {
                    origin.createOrigin(PairingPurpose.Continue, host).join()
                    recipient.createRecipient(origin.awaitState<PairingUiState.Offer>().text)
                    val sas = origin.awaitState<PairingUiState.Sas>()
                    assertEquals(sas.digits, recipient.awaitState<PairingUiState.Sas>().digits)
                    recipient.decideSas(true)
                    origin.decideSas(true)
                    val (id, target, attempt) = withTimeout(20_000) { connection.await() }
                    assertEquals(host.id, id)
                    assertEquals(host.tmuxTarget, target)
                    recipient.connectionRenderedReady(id, target, "stale-attempt")
                    delay(100)
                    assertTrue(recipient.state.value is PairingUiState.AwaitingConnection)
                    assertTrue(origin.state.value !is PairingUiState.Completed)
                    recipient.connectionRenderedReady(id, target, attempt)
                    recipient.awaitState<PairingUiState.Completed>()
                    origin.awaitState<PairingUiState.Completed>()
                } finally {
                    recipient.close(); origin.close()
                    recipientScope.cancel(); originScope.cancel()
                }
            }
        }
    }

    @Test
    fun freshRecipientImportsEveryHostAndLinksOnlyVerifiedDeviceKey() = verifyBootstrap(false)

    @Test
    fun selectedTrustedKeysCrossTheCanonicalManifestAndPreserveConflicts() = verifyBootstrap(true)

    @Test
    fun incompleteAccessKeepsCopiedHostsButNeverLinksAnUnverifiedKey() = verifyBootstrap(false, failGrants = true)

    @Test
    fun setupAndContinueWaitsForRenderedConnectionAfterImport() = verifyBootstrap(false, continueAfterSetup = true)

    @Test
    fun passwordBootstrapContinuesWithoutGrantOrIdentitySubstitution() = verifyBootstrap(false, continueAfterSetup = true, passwordHosts = true)

    @Test
    fun selectedOptionalHostDataSurvivesBootstrap() = verifyBootstrap(false, includeMetadata = true)

    @Test
    fun canceledImportCannotOverwriteANewOfferAfterItsReceiptWriteResumes() =
        verifyBootstrap(false, cancelDuringImport = true)

    @Test
    fun canceledGrantReceiptCannotAcknowledgeANewAttempt() =
        verifyBootstrap(false, cancelAtReceipt = "bootstrap-grant-receipt")

    @Test
    fun canceledCompletionCannotCompleteANewOffer() =
        verifyBootstrap(false, cancelAtReceipt = "bootstrap-completed")

    @Test
    fun canceledPasswordAccessRecordCannotRepopulateANewAttempt() =
        verifyBootstrap(false, passwordHosts = true, cancelAtAccessClear = true)

    private fun verifyBootstrap(includeTrustedKeys: Boolean, failGrants: Boolean = false, continueAfterSetup: Boolean = false,
        passwordHosts: Boolean = false, includeMetadata: Boolean = false, cancelDuringImport: Boolean = false,
        cancelAtReceipt: String? = null, cancelAtAccessClear: Boolean = false) = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val originHosts = FakeHostRepository(
            listOf(
                SavedHost(
                    id = UUID.randomUUID().toString(),
                    displayName = "build box",
                    hostname = "build.example",
                    port = 22,
                    username = "builder",
                    jumpHostId = null,
                    identityId = if (passwordHosts) null else UUID.randomUUID().toString(),
                    transportKind = TransportKinds.SSH,
                    tmuxMode = TmuxModes.AUTOMATIC,
                    tmuxTarget = null,
                    launchCommand = "printf 'custom command\\n'", notes = "fixture notes",
                    envVars = "QR_TEST=selected", startupSnippet = "printf 'startup\\n'",
                ),
            ),
        )
        val jump = originHosts.snapshot().single()
        originHosts.save(
            HostDraft(
                id = UUID.randomUUID().toString(),
                displayName = "windows",
                hostname = "windows.example",
                port = 2222,
                username = "developer",
                jumpHostId = jump.id,
                identityId = if (passwordHosts) null else UUID.randomUUID().toString(),
                transportKind = TransportKinds.SSH,
                tmuxMode = TmuxModes.PINNED,
                tmuxTarget = "windows",
            ),
        )

        val recipientHosts = FakeHostRepository()
        val originIdentities = FakeIdentityRepository()
        val recipientIdentities = FakeIdentityRepository()
        val originReceipts = FakeReceiptRepository()
        val importBlocked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val releaseImport = kotlinx.coroutines.CompletableDeferred<Unit>()
        val recipientReceipts = FakeReceiptRepository(beforeClear = {
            if (cancelAtAccessClear && !importBlocked.isCompleted) {
                importBlocked.complete(Unit)
                releaseImport.await()
            }
        }) { receipt ->
            if ((cancelDuringImport && receipt.kind == "bootstrap-import") || receipt.kind == cancelAtReceipt) {
                importBlocked.complete(Unit)
                releaseImport.await()
            }
        }
        val credentialStore = AndroidKeystoreCredentialStore()
        val serverAlias = "qr-test-server-${UUID.randomUUID()}"
        val serverKey = credentialStore.generateP256(serverAlias, ownerAuthenticationRequired = false)
        val pin = SavedKnownHost(
            normalizedEndpoint = AndroidKnownHostsRepository.normalizeEndpoint(jump.hostname, jump.port),
            algorithm = "ecdsa-sha2-nistp256", canonicalKeyBlob = serverKey.publicKeyBlob,
            previousAlgorithm = null, previousCanonicalKeyBlob = null,
            firstSeenAtEpochMilliseconds = 1_700_000_000_000, lastVerifiedAtEpochMilliseconds = 1_700_000_100_000,
        )
        val conflict = pin.copy(normalizedEndpoint = AndroidKnownHostsRepository.normalizeEndpoint("windows.example", 2222))
        val originTrust = FakeKnownHostsRepository(listOf(pin, conflict))
        val recipientTrust = FakeKnownHostsRepository(listOf(conflict.copy(canonicalKeyBlob = byteArrayOf(1, 2, 3))))
        val originDiagnostics = mutableListOf<String>()
        val recipientDiagnostics = mutableListOf<String>()
        val grants = linkedMapOf<String, String>()
        val originScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val recipientScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val continuedConnection = kotlinx.coroutines.CompletableDeferred<Triple<String, String?, String>>()

        val origin = CrossDevicePairingCoordinator(
            context = context,
            hosts = originHosts,
            identities = originIdentities,
            knownHosts = originTrust,
            credentialStore = credentialStore,
            scope = originScope,
            onConnectionRequired = { _, _, _, _ -> error("source must not auto-connect") },
            recordDiagnostic = { code, _ -> synchronized(originDiagnostics) { originDiagnostics += code } },
            testDependencies = PairingTestDependencies(
                receipts = originReceipts,
                grantInstaller = { hostId, publicLine ->
                    if (failGrants) error("fixture refuses remote access")
                    synchronized(grants) { grants[UUID.fromString(hostId).toString()] = publicLine }
                    true
                },
            ),
        )
        val recipient = CrossDevicePairingCoordinator(
            context = context,
            hosts = recipientHosts,
            identities = recipientIdentities,
            knownHosts = recipientTrust,
            credentialStore = credentialStore,
            scope = recipientScope,
            onConnectionRequired = { id, _, target, attempt ->
                check(continueAfterSetup) { "bootstrap must not auto-connect" }
                continuedConnection.complete(Triple(id, target, attempt))
            },
            recordDiagnostic = { code, _ -> synchronized(recipientDiagnostics) { recipientDiagnostics += code } },
            testDependencies = PairingTestDependencies(
                receipts = recipientReceipts,
                grantInstaller = { _, _ -> error("recipient must not install source grants") },
            ),
        )

        try {
            if (continueAfterSetup) origin.createOrigin(PairingPurpose.SetupAndContinue, jump).join()
            else origin.createBootstrapOrigin().join()
            val offer = origin.awaitState<PairingUiState.Offer>()
            recipient.createRecipient(offer.text)

            val originSas = origin.awaitState<PairingUiState.Sas>()
            val recipientSas = recipient.awaitState<PairingUiState.Sas>()
            assertEquals(originSas.digits, recipientSas.digits)

            origin.decideSas(matches = true)
            assertEquals(originSas.digits, origin.awaitState<PairingUiState.AwaitingPeerSas>().digits)
            recipient.decideSas(matches = true)

            val sourceReview = origin.awaitState<PairingUiState.AwaitingOwnerApproval>()
            assertEquals(listOf("build box", "windows"), sourceReview.hosts.map { it.name })
            assertTrue(sourceReview.selectedOptionalTransfers.isEmpty())
            origin.setTrustedHostKeysSelected(includeTrustedKeys)
            if (includeMetadata) listOf("launchCommands", "notes", "environmentVariables", "startupSnippets")
                .forEach { origin.setOptionalTransferSelected(it, true) }
            val authorization = origin.beginOwnerAuthorization()
            assertNotNull(authorization)
            origin.finishOwnerAuthorization(checkNotNull(authorization), approved = true)

            val importReview = try {
                recipient.awaitState<PairingUiState.AwaitingRecipientImport>()
            } catch (failure: Exception) {
                error("Import did not arrive: origin=${origin.state.value}; recipient=${recipient.state.value}; origin events=$originDiagnostics; ${failure.message}")
            }
            assertEquals(listOf("build box", "windows"), importReview.hosts.map { it.name })
            recipient.approveBootstrapImport()

            if (cancelDuringImport || cancelAtReceipt != null || cancelAtAccessClear) {
                withTimeout(20_000) { importBlocked.await() }
                recipient.cancel()
                recipient.createBootstrapOrigin().join()
                val resumedStates = mutableListOf<PairingUiState>()
                val watch = recipientScope.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                    recipient.state.collect { resumedStates += it }
                }
                // Core-event handlers are serial: their queued new offer can
                // only be delivered after the blocked old handler retires.
                releaseImport.complete(Unit)
                val nextOffer = recipient.awaitState<PairingUiState.Offer>()
                delay(300)
                assertEquals(nextOffer, recipient.state.value)
                watch.cancel()
                assertTrue("stale handler published $resumedStates", resumedStates.all {
                    it is PairingUiState.Idle || it is PairingUiState.Offer
                })
                return@runBlocking
            }

            if (failGrants) {
                val result = recipient.awaitState<PairingUiState.Failed>(30_000)
                assertEquals("Setup copied · access incomplete", result.title)
                assertEquals(3, result.step)
                assertEquals(2, recipientHosts.snapshot().size)
                assertTrue(recipientHosts.snapshot().all { it.identityId == null })
                assertEquals(2, recipientReceipts.pendingAccess().size)
                return@runBlocking
            }
            if (continueAfterSetup) {
                val (id, target, attempt) = withTimeout(30_000) { continuedConnection.await() }
                assertEquals(jump.id, id)
                assertTrue(recipient.state.value is PairingUiState.AwaitingConnection)
                assertTrue(origin.state.value !is PairingUiState.Completed)
                recipient.connectionRenderedReady(id, target, "stale-attempt")
                delay(100)
                assertTrue(origin.state.value !is PairingUiState.Completed)
                recipient.connectionRenderedReady(id, target, attempt)
            }
            origin.awaitState<PairingUiState.Completed>(30_000)
            recipient.awaitState<PairingUiState.Completed>(30_000)
            assertEquals(!continueAfterSetup, recipient.didReceiveBootstrap)
            assertTrue(!origin.didReceiveBootstrap)

            val imported = recipientHosts.snapshot()
            assertEquals(2, imported.size)
            assertEquals(jump.id, imported.single { it.displayName == "windows" }.jumpHostId)
            val importedBuild = imported.single { it.id == jump.id }
            assertEquals(if (includeMetadata) jump.notes else null, importedBuild.notes)
            assertEquals(if (includeMetadata) jump.envVars else null, importedBuild.envVars)
            assertEquals(if (includeMetadata) jump.startupSnippet else null, importedBuild.startupSnippet)
            assertEquals(if (includeMetadata) jump.launchCommand else null, importedBuild.launchCommand)
            if (passwordHosts) {
                assertTrue(imported.all { it.identityId == null })
                assertTrue(grants.isEmpty())
                assertTrue(recipientReceipts.pendingAccess().isEmpty())
                return@runBlocking
            }
            val linkedIdentities = imported.mapNotNull(SavedHost::identityId).distinct()
            assertEquals(
                "hosts=$imported pending=${recipientReceipts.pendingAccess()} originDiagnostics=$originDiagnostics recipientDiagnostics=$recipientDiagnostics grants=$grants",
                1,
                linkedIdentities.size,
            )
            val linkedIdentity = linkedIdentities.single()
            assertEquals(setOf(linkedIdentity), imported.mapNotNull(SavedHost::identityId).toSet())
            assertEquals(linkedIdentity, recipientIdentities.snapshot().single().id)

            assertEquals(originHosts.snapshot().map(SavedHost::id).toSet(), synchronized(grants) { grants.keys.toSet() })
            assertTrue(synchronized(grants) { grants.values.all { it.startsWith("ecdsa-sha2-nistp256 ") } })
            assertTrue(synchronized(originDiagnostics) { "pairing_grants_verified" in originDiagnostics })
            assertTrue(synchronized(recipientDiagnostics) { "pairing_import_recorded" in recipientDiagnostics })
            assertTrue(recipientReceipts.pendingAccess().isEmpty())
            val receivedPins = recipientTrust.loadedKnownHosts.value.orEmpty()
            assertEquals(if (includeTrustedKeys) 2 else 1, receivedPins.size)
            assertTrue(receivedPins.single { it.normalizedEndpoint == conflict.normalizedEndpoint }.canonicalKeyBlob.contentEquals(byteArrayOf(1, 2, 3)))
            if (includeTrustedKeys) assertTrue(receivedPins.single { it.normalizedEndpoint == pin.normalizedEndpoint }.canonicalKeyBlob.contentEquals(pin.canonicalKeyBlob))
        } finally {
            credentialStore.delete(serverAlias)
            recipientIdentities.snapshot().forEach { credentialStore.delete(it.credentialReference) }
            recipient.close()
            origin.close()
            recipientScope.cancel()
            originScope.cancel()
        }
    }

    private suspend inline fun <reified T : PairingUiState> CrossDevicePairingCoordinator.awaitState(
        timeoutMilliseconds: Long = 20_000,
    ): T = withTimeoutOrNull(timeoutMilliseconds) {
        while (true) {
            val current = state.value
            if (current is T) return@withTimeoutOrNull current
            if (current is PairingUiState.Failed) error("pairing failed: ${current.message}")
            delay(10)
        }
        error("unreachable")
    } ?: error("Expected ${T::class.java.simpleName}; actual ${state.value}")
}

private class FakeHostRepository(initial: List<SavedHost> = emptyList()) : HostRepository {
    private val values = MutableStateFlow(initial)
    override val loadedHosts: StateFlow<List<SavedHost>?> = values

    fun snapshot(): List<SavedHost> = values.value
    override fun observeHosts(): Flow<List<SavedHost>> = values
    override suspend fun host(id: String): SavedHost? = values.value.firstOrNull { it.id == UUID.fromString(id).toString() }
    override suspend fun save(draft: HostDraft): SavedHost {
        val saved = SavedHost(
            id = draft.id?.let { UUID.fromString(it).toString() } ?: UUID.randomUUID().toString(),
            displayName = draft.displayName,
            hostname = draft.hostname,
            port = draft.port,
            username = draft.username,
            jumpHostId = draft.jumpHostId?.let { UUID.fromString(it).toString() },
            identityId = draft.identityId,
            transportKind = draft.transportKind,
            tmuxMode = draft.tmuxMode,
            tmuxTarget = draft.tmuxTarget,
            launchCommand = draft.launchCommand, notes = draft.notes,
            envVars = draft.envVars, startupSnippet = draft.startupSnippet,
        )
        values.value = values.value.filterNot { it.id == saved.id } + saved
        return saved
    }
    override suspend fun delete(id: String): Boolean {
        val normalized = UUID.fromString(id).toString()
        val before = values.value.size
        values.value = values.value.filterNot { it.id == normalized }
        return values.value.size != before
    }
    override suspend fun resolveRoute(hostId: String): List<SavedHost> {
        val reversed = mutableListOf<SavedHost>()
        var current: String? = UUID.fromString(hostId).toString()
        while (current != null) {
            val host = host(current) ?: error("route host missing")
            reversed += host
            current = host.jumpHostId
        }
        return reversed.asReversed()
    }
}

private class FakeIdentityRepository : IdentityRepository {
    private val values = MutableStateFlow<List<SavedIdentity>>(emptyList())
    override val loadedIdentities: StateFlow<List<SavedIdentity>?> = values
    fun snapshot(): List<SavedIdentity> = values.value
    override fun observeIdentities(): Flow<List<SavedIdentity>> = values
    override suspend fun identity(id: String): SavedIdentity? = values.value.firstOrNull { it.id == id }
    override suspend fun save(displayName: String, credentialKind: String, credentialReference: String, id: String?): SavedIdentity {
        val saved = SavedIdentity(id ?: UUID.randomUUID().toString(), displayName, credentialKind, credentialReference)
        values.value = values.value.filterNot { it.id == saved.id } + saved
        return saved
    }
    override suspend fun delete(id: String): Boolean {
        val before = values.value.size
        values.value = values.value.filterNot { it.id == id }
        return values.value.size != before
    }
}

private class FakeKnownHostsRepository(initial: List<SavedKnownHost> = emptyList()) : KnownHostsRepository {
    private val values = MutableStateFlow(initial)
    override val loadedKnownHosts: StateFlow<List<SavedKnownHost>?> = values
    override fun observeKnownHosts(): Flow<List<SavedKnownHost>> = values
    override suspend fun evaluate(hostname: String, port: Int, algorithm: String, canonicalKeyBlob: ByteArray): HostTrustEvaluation =
        HostTrustEvaluation.Unknown
    override suspend fun trust(hostname: String, port: Int, algorithm: String, canonicalKeyBlob: ByteArray) {
        val endpoint = AndroidKnownHostsRepository.normalizeEndpoint(hostname, port)
        values.value = values.value.filterNot { it.normalizedEndpoint == endpoint } + SavedKnownHost(
            endpoint, algorithm, canonicalKeyBlob, null, null, 1_700_000_000_000, 1_700_000_000_000,
        )
    }
    override suspend fun forget(hostname: String, port: Int): Boolean = false
}

private class FakeReceiptRepository(
    private val beforeClear: suspend () -> Unit = {},
    private val beforeRecord: suspend (CrossDeviceReceipt) -> Unit = {},
) : CrossDeviceReceiptRepository {
    private val receipts = mutableListOf<CrossDeviceReceipt>()
    private val pending = mutableListOf<PendingCrossDeviceAccess>()
    override suspend fun record(receipt: CrossDeviceReceipt) { beforeRecord(receipt); receipts.removeAll { it.attemptId == receipt.attemptId && it.kind == receipt.kind }; receipts += receipt }
    override suspend fun receipt(attemptId: String): CrossDeviceReceipt? = receipts.lastOrNull { it.attemptId == attemptId }
    override suspend fun stagePendingAccess(record: PendingCrossDeviceAccess) { pending.removeAll { it.attemptId == record.attemptId && it.hostId == record.hostId }; pending += record }
    override suspend fun pendingAccess(attemptId: String): List<PendingCrossDeviceAccess> = pending.filter { it.attemptId == attemptId }
    override suspend fun pendingAccess(): List<PendingCrossDeviceAccess> = pending.toList()
    override suspend fun clearPendingAccess(attemptId: String, hostId: String) { pending.removeAll { it.attemptId == attemptId && it.hostId == hostId } }
    override suspend fun clearPendingAccessForHost(hostId: String) { beforeClear(); pending.removeAll { it.hostId == hostId } }
}
