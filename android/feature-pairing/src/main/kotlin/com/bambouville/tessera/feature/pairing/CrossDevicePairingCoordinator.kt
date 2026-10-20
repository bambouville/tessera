package com.bambouville.tessera.feature.pairing

import android.content.Context
import android.os.Build
import android.util.Base64
import com.bambouville.tessera.core.bridge.SharedSetupFlow
import com.bambouville.tessera.core.bridge.SharedSetupFlow.Phase
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.CoreEvent
import com.bambouville.tessera.core.bridge.CoreEventListener
import com.bambouville.tessera.core.bridge.CrossDeviceRuntime
import com.bambouville.tessera.core.bridge.SharedAutomaticTmuxTarget
import com.bambouville.tessera.core.bridge.SharedContinuationEndpoint
import com.bambouville.tessera.core.bridge.SharedContinuationIdentity
import com.bambouville.tessera.core.bridge.SharedContinuationTransport
import com.bambouville.tessera.core.bridge.SharedCrossDeviceCommand
import com.bambouville.tessera.core.bridge.SharedPairingOffer
import com.bambouville.tessera.core.bridge.SharedPairingQR
import com.bambouville.tessera.core.bridge.SharedBootstrapTransactionVersions
import com.bambouville.tessera.core.bridge.SharedPairingQrDecode
import com.bambouville.tessera.core.bridge.SharedPairingQrRejection
import com.bambouville.tessera.core.bridge.SharedTrustPolicy
import com.bambouville.tessera.design.TerminalFontCatalog
import com.bambouville.tessera.data.AndroidCrossDeviceReceiptRepository
import com.bambouville.tessera.data.CredentialKinds
import com.bambouville.tessera.data.CrossDeviceReceipt
import com.bambouville.tessera.data.CrossDeviceReceiptRepository
import com.bambouville.tessera.data.PendingCrossDeviceAccess
import com.bambouville.tessera.data.continuity.AndroidPendingContinuationRecoveryStore
import com.bambouville.tessera.data.continuity.PendingContinuationRecovery
import com.bambouville.tessera.data.continuity.isFreshAt
import com.bambouville.tessera.data.AndroidAppPreferences
import com.bambouville.tessera.forwarding.AndroidPortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardDirection
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.HostRepository
import com.bambouville.tessera.data.IdentityRepository
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.KnownHostKeys
import com.bambouville.tessera.data.AndroidKnownHostsRepository
import com.bambouville.tessera.data.HostTrustEvaluation
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.security.StoredKeystoreCredential
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject

enum class PairingPurpose(val wire: String) {
    Continue("continue"), Bootstrap("bootstrap"), SetupAndContinue("setUpAndContinue"), Enroll("enroll"),
}

sealed interface PairingUiState {
    data object Idle : PairingUiState
    data class RecoveryPending(val attempts: Int, val hosts: Int) : PairingUiState
    data class Offer(val text: String, val purpose: PairingPurpose) : PairingUiState
    data class Sas(val digits: String) : PairingUiState
    data class AwaitingPeerSas(val digits: String) : PairingUiState
    data object AwaitingSetupChoice : PairingUiState
    data class AwaitingOwnerApproval(
        val summary: String,
        val hosts: List<PairingHostSummary> = emptyList(),
        val selectedHostIds: Set<String> = emptySet(),
        val selectedOptionalTransfers: Set<String> = emptySet(),
        val recipientFingerprint: String? = null,
        val recipientUsesSoftwareKey: Boolean = false,
    ) : PairingUiState
    data class AwaitingRecipientImport(val hosts: List<PairingHostSummary>) : PairingUiState
    data class AwaitingSourcePassword(val hostName: String, val username: String) : PairingUiState
    data class Working(val message: String, val phase: Phase) : PairingUiState
    data class AwaitingConnection(val hostId: String, val transport: String, val tmuxTarget: String?) : PairingUiState
    data class Completed(val message: String, val hosts: List<PairingReceiptHost> = emptyList()) : PairingUiState
    data class Failed(val message: String, val title: String = "Pairing stopped", val step: Int = 0,
        val hosts: List<PairingReceiptHost> = emptyList()) : PairingUiState
}

data class PairingReceiptHost(val id: String, val name: String, val outcome: SharedSetupFlow.Outcome)

/**
 * Every host that must travel for [selected] to arrive intact: the chosen hosts
 * plus, transitively, the hosts they route through. Keeps the sender's
 * checkboxes equal to what is actually copied.
 *
 * Uses the shared protocol route closure through the presentation ABI.
 */
internal fun hostSelectionClosure(
    selected: Set<String>,
    jumpParents: Map<String, String>,
): Set<String> {
    val all = selected + jumpParents.keys + jumpParents.values
    return SharedSetupFlow.project("bootstrap", Phase.choosing, selection = SharedSetupFlow.Selection(
        all, selected, emptySet(), jumpParents,
    )).copiedHostIds
}

data class PairingHostSummary(val id: String, val name: String, val endpoint: String)


internal data class PairingTestDependencies(
    val receipts: CrossDeviceReceiptRepository,
    val grantInstaller: suspend (hostId: String, publicLine: String) -> Boolean,
)

class PairingOwnerAuthorizationToken internal constructor(
    internal val nonce: String,
    internal val generation: Long,
    internal val policyGeneration: Long,
    internal val attemptId: String,
)

/**
 * Android's complete platform adapter around TesseraCrossDeviceCore. It never
 * decrypts, frames, or orders pairing records; those responsibilities remain in
 * the ABI. Room/Keystore/TCP/QR/UI are deliberately the only local concerns.
 */
class CrossDevicePairingCoordinator private constructor(
    context: Context,
    private val hosts: HostRepository,
    private val identities: IdentityRepository,
    private val knownHosts: KnownHostsRepository,
    private val credentialStore: AndroidKeystoreCredentialStore,
    private val scope: CoroutineScope,
    private val onConnectionRequired: (hostId: String, transport: String, tmuxTarget: String?, attemptId: String) -> Unit,
    private val recordDiagnostic: (String, Map<String, String>) -> Unit = { _, _ -> },
    private val receipts: CrossDeviceReceiptRepository,
    private val grantInstaller: (suspend (hostId: String, publicLine: String) -> Boolean)?,
) : AutoCloseable {
    constructor(
        context: Context,
        hosts: HostRepository,
        identities: IdentityRepository,
        knownHosts: KnownHostsRepository,
        credentialStore: AndroidKeystoreCredentialStore,
        scope: CoroutineScope,
        onConnectionRequired: (hostId: String, transport: String, tmuxTarget: String?, attemptId: String) -> Unit,
        recordDiagnostic: (String, Map<String, String>) -> Unit = { _, _ -> },
    ) : this(
        context = context,
        hosts = hosts,
        identities = identities,
        knownHosts = knownHosts,
        credentialStore = credentialStore,
        scope = scope,
        onConnectionRequired = onConnectionRequired,
        recordDiagnostic = recordDiagnostic,
        receipts = AndroidCrossDeviceReceiptRepository(context.applicationContext),
        grantInstaller = null,
    )

    /** Test-only dependency boundary for a complete two-adapter transaction. */
    internal constructor(
        context: Context,
        hosts: HostRepository,
        identities: IdentityRepository,
        knownHosts: KnownHostsRepository,
        credentialStore: AndroidKeystoreCredentialStore,
        scope: CoroutineScope,
        onConnectionRequired: (hostId: String, transport: String, tmuxTarget: String?, attemptId: String) -> Unit,
        recordDiagnostic: (String, Map<String, String>) -> Unit,
        testDependencies: PairingTestDependencies,
    ) : this(
        context = context,
        hosts = hosts,
        identities = identities,
        knownHosts = knownHosts,
        credentialStore = credentialStore,
        scope = scope,
        onConnectionRequired = onConnectionRequired,
        recordDiagnostic = recordDiagnostic,
        receipts = testDependencies.receipts,
        grantInstaller = testDependencies.grantInstaller,
    )

    private val mutableState = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val state: StateFlow<PairingUiState> = mutableState.asStateFlow()
    private val pendingContinuationRecovery = AndroidPendingContinuationRecoveryStore(context.applicationContext)
    private val forwardingRules = AndroidPortForwardRuleStore(context.applicationContext)
    private val appPreferences = AndroidAppPreferences(context.applicationContext)
    private val nativeContext = context.applicationContext
    private var runtime: CrossDeviceRuntime? = null
    private var rendezvous: PairingTcpRendezvous? = null
    private var generation = 0L
    private var operationRetired = false
    private var policyGeneration = 0L
    private var purpose: PairingPurpose? = null
    val presentationPurpose: PairingPurpose get() = purpose ?: PairingPurpose.Bootstrap
    val didReceiveBootstrap: Boolean get() = !isOrigin && purpose == PairingPurpose.Bootstrap

    fun presentation(state: PairingUiState = mutableState.value): SharedSetupFlow.Output {
        val phase = when (state) {
            is PairingUiState.Sas -> Phase.compareCode
            is PairingUiState.AwaitingPeerSas -> Phase.waitingForPeerCode
            PairingUiState.AwaitingSetupChoice -> Phase.waitingForSelection
            is PairingUiState.AwaitingOwnerApproval -> Phase.choosing
            is PairingUiState.AwaitingRecipientImport -> Phase.reviewingImport
            is PairingUiState.AwaitingSourcePassword -> Phase.granting
            is PairingUiState.Working -> state.phase
            is PairingUiState.AwaitingConnection -> Phase.awaitingConnection
            is PairingUiState.Completed -> Phase.completed
            is PairingUiState.Failed -> Phase.failed
            else -> Phase.entry
        }
        val selection = (state as? PairingUiState.AwaitingOwnerApproval)?.takeIf { it.hosts.isNotEmpty() }?.let {
            val manifestHosts = pendingManifest?.let(::JSONObject)?.getJSONArray("hosts")
            val eligible = buildSet {
                if (manifestHosts != null) for (index in 0 until manifestHosts.length()) {
                    val host = manifestHosts.getJSONObject(index)
                    if (host.optString("authenticationHint") == "publicKey") add(UUID.fromString(host.getString("id")).toString())
                }
            }
            SharedSetupFlow.Selection(it.hosts.map { host -> host.id }.toSet(), it.selectedHostIds,
                eligible, originJumpParents)
        }
        return SharedSetupFlow.project(presentationPurpose.wire, phase,
            actions = listOf(SharedSetupFlow.Action.cancel, SharedSetupFlow.Action.confirmCode,
                SharedSetupFlow.Action.rejectCode, SharedSetupFlow.Action.approve, SharedSetupFlow.Action.importSetup,
                SharedSetupFlow.Action.done),
            selection = selection,
            stoppedAt = (state as? PairingUiState.Failed)?.let {
                when (it.step) { 1 -> SharedSetupFlow.Stage.verify; 2 -> SharedSetupFlow.Stage.choose;
                    3 -> SharedSetupFlow.Stage.transfer; else -> SharedSetupFlow.Stage.scan }
            })
    }
    private var isOrigin = false
    private var originDescriptor: ByteArray? = null
    private var retainedDescriptor: JSONObject? = null
    private var recipientIdentityId: String? = null
    private var pendingManifest: String? = null
    private var pendingImportManifest: JSONObject? = null
    private var pendingImportAttemptId: String? = null
    private var pendingOwnerAction: PendingOwnerAction? = null
    private var issuedOwnerToken: PairingOwnerAuthorizationToken? = null
    private var expiryJob: Job? = null
    private var pendingConnectionHostID: String? = null
    private var pendingConnectionTmuxTarget: String? = null
    private var pendingConnectionAttemptID: String? = null
    private val verifiedGrantHostIds = mutableSetOf<String>()
    private val failedGrantHostIds = mutableSetOf<String>()
    private val setupReceiptFacts = linkedMapOf<String, SharedSetupFlow.HostFact>()
    private var setupReceiptNames = emptyMap<String, String>()
    private fun setupReceipt(): List<PairingReceiptHost> {
        val outcomes = SharedSetupFlow.project(presentationPurpose.wire, Phase.completed, hosts = setupReceiptFacts.values.toList()).hosts
        return setupReceiptNames.map { (id, name) ->
            PairingReceiptHost(id, name, outcomes[id] ?: SharedSetupFlow.Outcome.uncertain)
        }
    }
    // Only the authenticated, accepted manifest can classify a skipped grant
    // as expected. Passwords stay on the source and are prompted on connect.
    private val passwordBootstrapHostIds = mutableSetOf<String>()
    private var enrollmentTargetHost: SavedHost? = null
    private var generatedIdentity: GeneratedIdentity? = null
    private var generatedIdentityRetained = false
    private var passwordDecision: CompletableDeferred<CharArray>? = null
    private var pendingEnrollmentRequest: JSONObject? = null
    private var pendingEndpointCandidates: List<PairingTcpRendezvous.Endpoint>? = null
    private var authorizedSourcePolicyFingerprint: String? = null
    private var authorizedSourceHostIds: Set<String>? = null
    /** host id -> the host it routes through, parsed from the manifest. */
    private var originJumpParents: Map<String, String> = emptyMap()
    private var originSelectedHostIds: Set<String> = emptySet()
    private var originSelectedOptionalTransfers: Set<String> = emptySet()
    /**
     * Native callbacks are synchronous but several adapter events perform
     * suspending Room/SSH work. Launching one coroutine per callback allowed a
     * later `bootstrapCompleted` event to overtake the durable access-record
     * mutation, leaving imported hosts disconnected. One actor preserves the
     * shared core's authoritative event order across every suspension.
     */
    private val coreEvents = Channel<CoreEvent>(Channel.UNLIMITED)
    private val coreEventJob = scope.launch(Dispatchers.Main.immediate) {
        for (event in coreEvents) processCoreEventSafely(event)
    }

    init {
        scope.launch {
            val pending = receipts.pendingAccess()
            if (pending.isNotEmpty() && mutableState.value == PairingUiState.Idle) {
                mutableState.value = PairingUiState.RecoveryPending(
                    attempts = pending.map(PendingCrossDeviceAccess::attemptId).distinct().size,
                    hosts = pending.map(PendingCrossDeviceAccess::hostId).distinct().size,
                )
            }
        }
    }

    fun createOrigin(purpose: PairingPurpose, host: SavedHost) = scope.launch {
        cancel()
        require(host.transportKind == TransportKinds.SSH || host.transportKind == TransportKinds.MOSH)
        this@CrossDevicePairingCoordinator.purpose = purpose
        isOrigin = true
        originDescriptor = continuationDescriptor(host)
        recordDiagnostic("pairing_begin", mapOf("role" to "origin", "purpose" to purpose.wire))
        createOriginRuntime(purpose)
    }

    private fun createOriginRuntime(purpose: PairingPurpose) {
        createRuntime()
        val socket = newRendezvous()
        val candidates = socket.listen().map {
            CanonicalCrossDeviceJson.JsonValue.Raw(
                CanonicalCrossDeviceJson.objectValue(
                    mapOf(
                        "host" to CanonicalCrossDeviceJson.JsonValue.String(it.host),
                        "port" to CanonicalCrossDeviceJson.JsonValue.Number(it.port.toLong()),
                        "transport" to CanonicalCrossDeviceJson.JsonValue.String("tcp"),
                    ),
                ),
            )
        }
        submit(
            "createOrigin",
            mapOf(
                "purpose" to CanonicalCrossDeviceJson.JsonValue.String(purpose.wire),
                "expiresAt" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis() / 1_000 + OFFER_LIFETIME_SECONDS),
                "endpointCandidates" to CanonicalCrossDeviceJson.JsonValue.Array(candidates),
                "supportedTransactionVersions" to CanonicalCrossDeviceJson.JsonValue.Array(SharedBootstrapTransactionVersions.supported(checkNotNull(purpose).wire).map { CanonicalCrossDeviceJson.JsonValue.Number(it.toLong()) }),
            ),
        )
        submit("start")
        scheduleExpiry(OFFER_LIFETIME_SECONDS)
    }

    fun createBootstrapOrigin() = scope.launch {
        cancel()
        require(hosts.observeHosts().first().isNotEmpty()) { "Add a host before sending setup." }
        purpose = PairingPurpose.Bootstrap
        isOrigin = true
        recordDiagnostic("pairing_begin", mapOf("role" to "origin", "purpose" to PairingPurpose.Bootstrap.wire))
        createOriginRuntime(PairingPurpose.Bootstrap)
    }

    fun createRecipient(qrText: String, enrollmentHost: SavedHost? = null) {
        cancel()
        val trimmed = qrText.trim()
        val offer = decodeOffer(trimmed)
        purpose = offer.pairingPurpose()
        isOrigin = false
        recordDiagnostic("pairing_begin", mapOf("role" to "recipient", "purpose" to checkNotNull(purpose).wire))
        if (purpose == PairingPurpose.Enroll) {
            enrollmentTargetHost = requireNotNull(enrollmentHost) { "Choose the host that will receive this device key." }
        }
        pendingEndpointCandidates = tcpEndpointCandidates(offer)
        createRuntime()
        newRendezvous()
        submit(
            "createRecipient",
            mapOf(
                "qrText" to CanonicalCrossDeviceJson.JsonValue.String(trimmed),
                "supportedTransactionVersions" to CanonicalCrossDeviceJson.JsonValue.Array(SharedBootstrapTransactionVersions.supported(checkNotNull(purpose).wire).map { CanonicalCrossDeviceJson.JsonValue.Number(it.toLong()) }),
            ),
        )
        submit("start")
        scheduleExpiry(offer.expiresAt - System.currentTimeMillis() / 1_000)
        // The writer queues the initial TPR1 record until local TCP finishes its
        // bounded connect; no adapter-specific prelude is added.
    }

    fun decideSas(matches: Boolean) {
        val sas = mutableState.value as? PairingUiState.Sas ?: return
        mutableState.value = if (matches) PairingUiState.AwaitingPeerSas(sas.digits) else PairingUiState.Working("Stopping the mismatched pairing…", Phase.rejecting)
        recordDiagnostic("pairing_sas_decision", mapOf("result" to if (matches) "match" else "mismatch", "phase" to "waiting_peer"))
        submit("decideSAS", mapOf("matches" to CanonicalCrossDeviceJson.JsonValue.Boolean(matches)))
    }

    fun approveBootstrapImport() {
        val manifest = pendingImportManifest ?: return
        val attemptId = pendingImportAttemptId ?: return
        val expectedGeneration = generation
        pendingImportManifest = null
        pendingImportAttemptId = null
        mutableState.value = PairingUiState.Working("Importing approved setup with this device's own key…", Phase.importing)
        recordDiagnostic("pairing_import_approved", mapOf("hosts" to manifest.optJSONArray("hosts")?.length().toString()))
        scope.launch {
            runCatching { importBootstrap(manifest, attemptId, expectedGeneration) }
                .onFailure { failure ->
                    if (failure !is CancellationException && pairingGenerationIsCurrent(expectedGeneration)) {
                        recordDiagnostic(
                            "pairing_adapter_failed",
                            mapOf("code" to failure::class.java.simpleName, "phase" to "bootstrap_import"),
                        )
                        submit("cancel")
                        closePairingTransport()
                        mutableState.value = PairingUiState.Failed(failure.message ?: "Setup import failed")
                    }
                }
        }
    }

    /** Captures the exact transaction/policy epoch before Android opens system UI. */
    fun beginOwnerAuthorization(): PairingOwnerAuthorizationToken? {
        val action = pendingOwnerAction ?: return null
        val token = PairingOwnerAuthorizationToken(
            nonce = UUID.randomUUID().toString(),
            generation = generation,
            policyGeneration = policyGeneration,
            attemptId = action.attemptId,
        )
        issuedOwnerToken = token
        return token
    }

    /** Called only with the token returned before the device-credential surface opened. */
    fun finishOwnerAuthorization(token: PairingOwnerAuthorizationToken, approved: Boolean) {
        if (token != issuedOwnerToken) return
        issuedOwnerToken = null
        val action = pendingOwnerAction ?: return
        if (!approved) return
        if (runtime == null || token.generation != generation || token.policyGeneration != policyGeneration || token.attemptId != action.attemptId) return
        mutableState.value = PairingUiState.Working("Revalidating the authorized route…", Phase.authorizing)
        scope.launch {
            if (runtime == null || token.generation != generation || token.policyGeneration != policyGeneration || pendingOwnerAction != action) return@launch
            val currentFingerprint = runCatching { sourcePolicyFingerprint(action.sourceHostIds) }.getOrNull()
            if (currentFingerprint != action.sourcePolicyFingerprint) {
                invalidateSourcePolicy("The source host, credential, or trust policy changed during authorization. Start again.")
                return@launch
            }
            authorizedSourcePolicyFingerprint = action.sourcePolicyFingerprint
            authorizedSourceHostIds = action.sourceHostIds
            pendingOwnerAction = null
            pendingManifest = null
            val now = System.currentTimeMillis()
            mutableState.value = PairingUiState.Working("Applying the authorized change…", Phase.transferring)
            when (action) {
                is PendingOwnerAction.Bootstrap -> submit(
                    "approveBootstrapManifest",
                    mapOf(
                        "manifest" to CanonicalCrossDeviceJson.JsonValue.Raw(action.manifest),
                        "selectedOptionalTransfers" to CanonicalCrossDeviceJson.JsonValue.Array(
                            originSelectedOptionalTransfers.sorted().map(CanonicalCrossDeviceJson.JsonValue::String),
                        ),
                        // Canonical spelling is uppercase, and the ABI re-encodes the
                        // decoded command and demands byte equality — a lowercase id here
                        // is rejected as a non-canonical payload, exactly as acceptedHostIDs
                        // avoids by going through the same helper.
                        "selectedHostIDs" to CanonicalCrossDeviceJson.JsonValue.Array(
                            originSelectedHostIds
                                .map { CanonicalCrossDeviceJson.uuid(UUID.fromString(it)) }
                                .sorted()
                                .map(CanonicalCrossDeviceJson.JsonValue::String),
                        ),
                        "issuedAtMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(now),
                        "expiresAuthorizationAtMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(now + OWNER_AUTHORIZATION_MILLISECONDS),
                        "policyGeneration" to CanonicalCrossDeviceJson.JsonValue.Number(policyGeneration),
                    ),
                )
                is PendingOwnerAction.Enrollment -> submit(
                    "approveEnrollment",
                    mapOf(
                        "routeIdentity" to CanonicalCrossDeviceJson.JsonValue.String(action.routeIdentity),
                        "issuedAtMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(now),
                        "expiresAuthorizationAtMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(now + OWNER_AUTHORIZATION_MILLISECONDS),
                        "policyGeneration" to CanonicalCrossDeviceJson.JsonValue.Number(policyGeneration),
                    ),
                )
            }
            if (mutableState.value !is PairingUiState.Failed) {
                recordDiagnostic("pairing_owner_approved", mapOf("purpose" to purpose?.wire.orEmpty(), "hosts" to action.sourceHostIds?.size.toString()))
            }
        }
    }

    private fun hostSelectionClosure(selected: Set<String>): Set<String> =
        hostSelectionClosure(selected, originJumpParents)

    fun setHostSelected(hostId: String, selected: Boolean) {
        val current = mutableState.value as? PairingUiState.AwaitingOwnerApproval ?: return
        originSelectedHostIds = if (selected) {
            hostSelectionClosure(originSelectedHostIds + hostId)
        } else {
            (originSelectedHostIds - hostId)
                .filterTo(mutableSetOf()) { candidate -> hostId !in hostSelectionClosure(setOf(candidate)) }
        }
        mutableState.value = current.copy(selectedHostIds = originSelectedHostIds)
    }

    fun setTrustedHostKeysSelected(selected: Boolean) {
        setOptionalTransferSelected("trustedHostKeys", selected)
    }

    fun setOptionalTransferSelected(category: String, selected: Boolean) {
        require(category in setOf("trustedHostKeys", "launchCommands", "notes", "environmentVariables", "startupSnippets"))
        val current = mutableState.value as? PairingUiState.AwaitingOwnerApproval ?: return
        originSelectedOptionalTransfers = if (selected) originSelectedOptionalTransfers + category else originSelectedOptionalTransfers - category
        mutableState.value = current.copy(selectedOptionalTransfers = originSelectedOptionalTransfers)
    }

    private fun manifestJumpParents(manifest: JSONObject): Map<String, String> = buildMap {
        val chains = manifest.optJSONArray("jumpChains") ?: JSONArray()
        for (index in 0 until chains.length()) {
            val link = chains.getJSONObject(index)
            put(
                UUID.fromString(link.getString("hostID")).toString(),
                UUID.fromString(link.getString("jumpHostID")).toString(),
            )
        }
    }

    fun submitSourcePassword(password: String) {
        if (password.isEmpty()) return
        val characters = password.toCharArray()
        if (passwordDecision?.complete(characters) != true) characters.fill('\u0000')
        else mutableState.value = PairingUiState.Working("Verifying source-host access…", Phase.granting)
    }

    /** Interrupted protocol secrets cannot be resumed; a fresh verified attempt is required. */
    fun restartAfterInterruption() {
        if (mutableState.value is PairingUiState.RecoveryPending) mutableState.value = PairingUiState.Idle
    }

    fun connectionRenderedReady(hostId: String, tmuxTarget: String?, attemptId: String?) {
        // Receipt is intentionally emitted after the session surface is live, not
        // after merely saving/importing a host row or beginning an SSH attempt.
        if (pendingConnectionHostID != hostId || pendingConnectionTmuxTarget != tmuxTarget || pendingConnectionAttemptID != attemptId) return
        val activeTransaction = runtime != null
        if (activeTransaction) {
            submit(
                "continuationConnectionCompleted",
                mapOf(
                    "hostID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(hostId))),
                    "atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis()),
                ),
            )
        }
        pendingConnectionHostID = null
        pendingConnectionTmuxTarget = null
        pendingConnectionAttemptID = null
        verifiedGrantHostIds.clear()
        attemptId?.let { completedAttempt ->
            scope.launch { pendingContinuationRecovery.clearIfAttempt(completedAttempt) }
        }
        if (!activeTransaction) {
            // Process death intentionally loses pairing secrets and transcript
            // state. A recovered terminal is useful, but it must not claim to
            // complete the old authenticated transaction.
            mutableState.value = PairingUiState.Completed(
                "Destination session recovered. Start a new pairing attempt to notify the other device.",
            )
            recordDiagnostic("pairing_continuation_recovered", mapOf("result" to "destination_rendered"))
        }
    }

    /**
     * Startup/unlock hook. Reopens only a route that still exactly matches the
     * metadata authenticated before the process died; pairing itself is never
     * resumed because its transcript keys are deliberately memory-only.
     */
    fun recoverPendingContinuationOnStartup() {
        scope.launch {
            if (runtime != null || pendingConnectionAttemptID != null) return@launch
            val record = pendingContinuationRecovery.load() ?: return@launch
            if (!record.isFreshAt(System.currentTimeMillis())) {
                pendingContinuationRecovery.clearIfAttempt(record.attemptId)
                recordDiagnostic("pairing_continuation_recovery_discarded", mapOf("reason" to "expired"))
                return@launch
            }
            val host = hosts.host(record.hostId)
            val route = runCatching { hosts.resolveRoute(record.hostId) }.getOrNull()
            if (!PendingContinuationRecoveryPolicy.matchesCurrentRoute(record, host, route)) {
                pendingContinuationRecovery.clearIfAttempt(record.attemptId)
                recordDiagnostic("pairing_continuation_recovery_discarded", mapOf("reason" to "route_changed"))
                return@launch
            }
            if (host == null || !recoveryCredentialUsable(host)) {
                // Protected Keystore material can be temporarily unavailable
                // while locked. Retain the marker for the next unlocked start.
                recordDiagnostic("pairing_continuation_recovery_deferred", mapOf("reason" to "credential_unavailable"))
                return@launch
            }
            pendingConnectionHostID = record.hostId
            pendingConnectionTmuxTarget = record.tmuxTarget
            pendingConnectionAttemptID = record.attemptId
            mutableState.value = PairingUiState.AwaitingConnection(record.hostId, record.transportKind, record.tmuxTarget)
            recordDiagnostic("pairing_continuation_recovery_offered", mapOf("transport" to record.transportKind))
            onConnectionRequired(record.hostId, record.transportKind, record.tmuxTarget, record.attemptId)
        }
    }

    fun applicationDidLock() {
        operationRetired = true
        issuedOwnerToken = null
        pendingOwnerAction = null
        authorizedSourcePolicyFingerprint = null
        authorizedSourceHostIds = null
        originJumpParents = emptyMap()
        originSelectedHostIds = emptySet()
        originSelectedOptionalTransfers = emptySet()
        setupReceiptFacts.clear()
        setupReceiptNames = emptyMap()
        passwordDecision?.completeExceptionally(CancellationException("App locked"))
        submit("applicationDidLock")
        closePairingTransport()
    }

    fun securityPolicyChanged() {
        operationRetired = true
        // ABI generation fences runtime identity. Policy generation is a separate
        // monotonic security epoch supplied to the shared runtime, never a new handle ID.
        policyGeneration += 1
        issuedOwnerToken = null
        pendingOwnerAction = null
        authorizedSourcePolicyFingerprint = null
        authorizedSourceHostIds = null
        originJumpParents = emptyMap()
        originSelectedHostIds = emptySet()
        originSelectedOptionalTransfers = emptySet()
        submit("securityPolicyChanged", mapOf("policyGeneration" to CanonicalCrossDeviceJson.JsonValue.Number(policyGeneration)))
        if (runtime != null) closePairingTransport()
    }

    fun checkExpiration() = submit("checkExpiration")

    fun cancel() {
        pendingConnectionAttemptID?.let { attempt ->
            scope.launch { pendingContinuationRecovery.clearIfAttempt(attempt) }
        }
        val abandonedIdentity = generatedIdentity.takeIf { !generatedIdentityRetained }
        passwordDecision?.completeExceptionally(CancellationException("Pairing cancelled"))
        passwordDecision = null
        runtime?.let { submit("cancel") }
        rendezvous?.close()
        rendezvous = null
        runtime?.close()
        runtime = null
        isOrigin = false
        purpose = null
        originDescriptor = null
        retainedDescriptor = null
        recipientIdentityId = null
        pendingManifest = null
        pendingImportManifest = null
        pendingImportAttemptId = null
        pendingOwnerAction = null
        issuedOwnerToken = null
        pendingConnectionHostID = null
        pendingConnectionTmuxTarget = null
        pendingConnectionAttemptID = null
        enrollmentTargetHost = null
        generatedIdentity = null
        generatedIdentityRetained = false
        pendingEnrollmentRequest = null
        pendingEndpointCandidates = null
        authorizedSourcePolicyFingerprint = null
        authorizedSourceHostIds = null
        originJumpParents = emptyMap()
        originSelectedHostIds = emptySet()
        originSelectedOptionalTransfers = emptySet()
        verifiedGrantHostIds.clear()
        setupReceiptFacts.clear()
        setupReceiptNames = emptyMap()
        failedGrantHostIds.clear()
        passwordBootstrapHostIds.clear()
        expiryJob?.cancel()
        expiryJob = null
        mutableState.value = PairingUiState.Idle
        generation += 1
        if (abandonedIdentity != null) {
            credentialStore.delete(abandonedIdentity.alias)
            abandonedIdentity.savedIdentityId?.let { id ->
                // Composition teardown cancels the injected UI scope; this tiny
                // Room cleanup must still remove the now-keyless capability row.
                scope.launch(Dispatchers.IO + NonCancellable) { identities.delete(id) }
            }
        }
    }

    override fun close() = cancel()

    private fun createRuntime(): CrossDeviceRuntime = CrossDeviceRuntime.create(CoreEventListener(::onCoreEvent)).also {
        runtime = it
        operationRetired = false
    }

    private fun newRendezvous(): PairingTcpRendezvous = PairingTcpRendezvous(
        scope = scope,
        onBytes = { bytes -> submit("receiveBytes", mapOf("bytes" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.base64(bytes)))) },
        onEof = { submit("finishStream") },
        onFailure = { error ->
            recordDiagnostic("pairing_transport_failed", mapOf("code" to error::class.java.simpleName, "phase" to "local_tcp"))
            submit("cancel")
            closePairingTransport()
            mutableState.value = PairingUiState.Failed(error.message ?: "Local pairing connection closed")
        },
    ).also { rendezvous = it }

    private fun onCoreEvent(event: CoreEvent) {
        if (coreEvents.trySend(event).isFailure && mutableState.value != PairingUiState.Idle) {
            mutableState.value = PairingUiState.Failed("Pairing event processor is unavailable")
        }
    }

    private suspend fun processCoreEventSafely(event: CoreEvent) {
        val expectedGeneration = generation
        runCatching { processCoreEvent(JSONObject(event.bytes.decodeToString())) }
            .onFailure {
                if (it is CancellationException || !pairingGenerationIsCurrent(expectedGeneration)) return
                recordDiagnostic("pairing_adapter_failed", mapOf("code" to it::class.java.simpleName, "phase" to purpose?.wire.orEmpty()))
                submit("cancel")
                closePairingTransport()
                mutableState.value = PairingUiState.Failed(it.message ?: "Pairing failed")
            }
    }

    private suspend fun processCoreEvent(event: JSONObject) {
        if (event.getLong("generation") != generation) return
        val expectedGeneration = generation
        val kind = event.getString("kind")
        if (operationRetired && kind !in setOf("terminal", "commandRejected")) return
        when (kind) {
            "configured" -> pendingEndpointCandidates?.let { candidates ->
                pendingEndpointCandidates = null
                rendezvous?.connectCandidates(candidates)
            }
            "qrOffer" -> mutableState.value = PairingUiState.Offer(
                event.payloadBytes().decodeToString(), checkNotNull(purpose),
            )
            "outboundRecord" -> rendezvous?.write(event.payloadBytes())
            "sasAvailable" -> {
                recordDiagnostic("pairing_phase", mapOf("phase" to "sas_available", "role" to if (isOrigin) "origin" else "recipient"))
                mutableState.value = PairingUiState.Sas(event.getString("code"))
            }
            "pairingApproved" -> {
                recordDiagnostic("pairing_phase", mapOf("phase" to "approved", "role" to if (isOrigin) "origin" else "recipient"))
                mutableState.value = if (purpose == PairingPurpose.Bootstrap || purpose == PairingPurpose.SetupAndContinue) {
                    PairingUiState.AwaitingSetupChoice
                } else PairingUiState.Working("The code is confirmed on both devices…", Phase.transferring)
                if (purpose == PairingPurpose.Continue || purpose == PairingPurpose.SetupAndContinue) {
                    if (isOrigin) originDescriptor?.let { submit("provideContinuationDescriptor", mapOf("descriptor" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.base64(it)))) }
                }
                if (purpose == PairingPurpose.Bootstrap && !isOrigin) submitRecipientPublicKey()
                if (purpose == PairingPurpose.Enroll && !isOrigin) submitEnrollmentRequest(event.attemptId())
            }
            "continuationDescriptorReceived" -> receiveDescriptor(event.payloadObject(), event.attemptId())
            "continuationConnectionRequired" -> requireRenderedConnection(event.payloadObject(), event.attemptId())
            "bootstrapOwnerAuthorizationRequired" -> {
                // The ABI authenticated the recipient's public key. The source still
                // needs a separate, fresh owner decision before it may mint grants.
                pendingManifest = buildManifestForAllHosts(
                    peerSupportsAgentCenterEnabled = bootstrapPeerSupportsAgentCenterEnabled(event.payloadObject()),
                )
                val sourceHostIds = manifestHostIds(checkNotNull(pendingManifest))
                pendingOwnerAction = PendingOwnerAction.Bootstrap(
                    event.attemptId(),
                    pendingManifest!!,
                    sourcePolicyFingerprint(sourceHostIds),
                    sourceHostIds,
                )
                val manifestObject = JSONObject(checkNotNull(pendingManifest))
                val summaries = manifestSummaries(manifestObject)
                originJumpParents = manifestJumpParents(manifestObject)
                // Everything is copied unless the sender says otherwise; on this
                // transport an unselected host is not transferred at all.
                originSelectedHostIds = summaries.map { it.id }.toSet()
                originSelectedOptionalTransfers = emptySet()
                val recipientKey = event.payloadObject().optJSONObject("recipientKey")
                recordDiagnostic("pairing_source_review", mapOf("hosts" to summaries.size.toString()))
                mutableState.value = PairingUiState.AwaitingOwnerApproval(
                    "Choose what to copy. Tessera installs and verifies only the recipient's public key; passwords and private keys never leave this device.",
                    summaries,
                    selectedHostIds = originSelectedHostIds,
                    selectedOptionalTransfers = originSelectedOptionalTransfers,
                    recipientFingerprint = recipientKey?.optString("fingerprint")?.takeIf { it.isNotEmpty() },
                    recipientUsesSoftwareKey =
                        recipientKey?.optString("protectionClaim") !in setOf("platformHardwareBacked", "platformStrongHardware"),
                )
            }
            "bootstrapImportRequired" -> {
                pendingImportManifest = event.payloadObject()
                pendingImportAttemptId = event.attemptId()
                val summaries = manifestSummaries(checkNotNull(pendingImportManifest))
                setupReceiptNames = summaries.associate { it.id to it.name }
                recordDiagnostic("pairing_import_review", mapOf("hosts" to summaries.size.toString()))
                mutableState.value = PairingUiState.AwaitingRecipientImport(summaries)
            }
            "bootstrapRemoteGrantVerificationRequired" -> verifyRemoteGrants(event.payloadObject())
            "bootstrapAccessRecordRequired" -> {
                val receipt = event.payloadObject()
                val installed = mutableListOf<String>()
                // BootstrapGrantReceiptV1 is encoded by the shared core with
                // the canonical `results` field. Treat its absence as a hard
                // adapter/schema failure: accepting an empty fallback marks
                // setup complete without linking the verified device key.
                val results = receipt.getJSONArray("results")
                require(results.length() > 0) { "Bootstrap grant receipt contained no host results" }
                for (index in 0 until results.length()) {
                    val result = results.getJSONObject(index)
                    val hostId = UUID.fromString(result.getString("hostID")).toString()
                    setupReceiptFacts[hostId] = SharedSetupFlow.HostFact(hostId,
                        SharedSetupFlow.Access.valueOf(result.getString("status")), accepted = true,
                        passwordNeeded = hostId in passwordBootstrapHostIds)
                    if (result.optString("status") == "skipped" && hostId in passwordBootstrapHostIds) {
                        receipts.clearPendingAccessForHost(hostId)
                        if (!pairingGenerationIsCurrent(expectedGeneration)) return
                        continue
                    } else if (result.optString("status") in setOf("installed", "alreadyInstalled")) {
                        UUID.fromString(result.getString("hostID")).toString().also { verifiedGrantHostIds += it; installed += it }
                    } else {
                        failedGrantHostIds += UUID.fromString(result.getString("hostID")).toString()
                    }
                }
                val pending = receipts.pendingAccess(event.attemptId()).associateBy { it.hostId }
                if (!pairingGenerationIsCurrent(expectedGeneration)) return
                for (hostId in installed) {
                    val staged = pending[hostId] ?: continue
                    val host = hosts.host(hostId) ?: error("Imported host disappeared before access was recorded")
                    if (!pairingGenerationIsCurrent(expectedGeneration)) return
                    hosts.save(host.asDraft(identityId = staged.identityId))
                    if (!pairingGenerationIsCurrent(expectedGeneration)) return
                    receipts.clearPendingAccessForHost(hostId)
                    if (!pairingGenerationIsCurrent(expectedGeneration)) return
                }
                if (installed.isNotEmpty()) generatedIdentityRetained = true
                recordDiagnostic(
                    "pairing_access_recorded",
                    mapOf("grants" to installed.size.toString(), "result" to if (failedGrantHostIds.isEmpty()) "verified" else "partial"),
                )
                receipts.record(CrossDeviceReceipt(event.attemptId(), "bootstrap-grant-receipt", installed, System.currentTimeMillis()))
                if (!pairingGenerationIsCurrent(expectedGeneration)) return
                submit("bootstrapAccessStateDurablyRecorded", mapOf("atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis())))
            }
            "bootstrapCompleted" -> {
                receipts.record(CrossDeviceReceipt(event.attemptId(), "bootstrap-completed", emptyList(), System.currentTimeMillis()))
                if (!pairingGenerationIsCurrent(expectedGeneration)) return
                val retainedId = retainedDescriptor?.optString("hostID")?.let(UUID::fromString)?.toString()
                if (failedGrantHostIds.isNotEmpty()) {
                    mutableState.value = PairingUiState.Failed(
                        "Your host setup was copied. Access still needs attention on ${failedGrantHostIds.size} host(s). No unverified device key was linked, and no session was opened. You can review the hosts or start a fresh pairing.",
                        title = "Setup copied · access incomplete", step = 3, hosts = setupReceipt(),
                    )
                    closePairingTransport()
                } else if (retainedDescriptor != null && retainedId !in verifiedGrantHostIds && retainedId !in passwordBootstrapHostIds) {
                    mutableState.value = PairingUiState.Failed("The continuation host did not verify an authorized_keys grant.")
                } else {
                    val retained = retainedDescriptor
                    if (retained != null) {
                        if (!descriptorMatchesLocal(retained)) {
                            submit("cancel")
                            mutableState.value = PairingUiState.Failed("The imported route does not match the authenticated continuation descriptor.")
                        } else {
                            acceptRetainedDescriptor(retained, event.attemptId())
                            // The queued connection-required event will show
                            // AwaitingConnection; setup is not completion.
                            mutableState.value = PairingUiState.Working("Setup copied. Preparing continuation…", Phase.awaitingConnection)
                        }
                    } else {
                        mutableState.value = if (purpose == PairingPurpose.SetupAndContinue) {
                            PairingUiState.Working("Setup copied. Waiting for the other device to connect…", Phase.awaitingConnection)
                        } else PairingUiState.Completed(if (passwordBootstrapHostIds.isEmpty())
                            "Bootstrap host access was imported and verified."
                        else "Host setup was copied. Password hosts will ask for their password when you connect.", hosts = setupReceipt())
                        if (purpose == PairingPurpose.Bootstrap) closePairingTransport()
                    }
                    recordDiagnostic("pairing_complete", mapOf("purpose" to purpose?.wire.orEmpty(), "result" to "success"))
                }
            }
            "enrollmentApprovalRequired" -> prepareEnrollmentApproval(event.payloadObject(), event.attemptId())
            "enrollmentInstallationRequired" -> performEnrollmentInstallation(event.payloadObject(), event.attemptId())
            "enrollmentRecordRequired" -> recordEnrollment(event.payloadObject(), event.attemptId())
            "enrollmentCompleted" -> {
                val payload = event.payloadObject()
                val enrollmentId = UUID.fromString(payload.getString("enrollmentID")).toString()
                receipts.record(CrossDeviceReceipt(event.attemptId(), "enrollment-completed", listOf(enrollmentId), System.currentTimeMillis()))
                generatedIdentityRetained = true
                mutableState.value = PairingUiState.Completed("This Android device key is enrolled for the selected host.")
                closePairingTransport()
            }
            "continuationCompleted" -> {
                mutableState.value = PairingUiState.Completed("Cross-device continuation completed.", hosts = setupReceipt())
                closePairingTransport()
            }
            "terminal", "commandRejected" -> {
                recordDiagnostic(
                    "pairing_failed",
                    mapOf("phase" to kind, "code" to event.optString("code", "pairing_ended")),
                )
                closePairingTransport()
                if (mutableState.value !is PairingUiState.Failed) {
                    val projection = SharedSetupFlow.project(presentationPurpose.wire, Phase.failed,
                        failureCode = event.optString("code", "failed"))
                    mutableState.value = PairingUiState.Failed(pairingFailureMessage(nativeContext, projection.failureReason))
                }
            }
        }
    }

    private suspend fun receiveDescriptor(descriptor: JSONObject, attemptId: String) {
        retainedDescriptor = descriptor
        val transport = descriptor.getString("transport")
        purpose = purpose ?: PairingPurpose.Continue
        if (purpose == PairingPurpose.SetupAndContinue) {
            submitRecipientPublicKey()
            return
        }
        val hostId = descriptor.getString("hostID")
        val local = hosts.host(hostId)
        if (local == null) {
            submit("cancel")
            mutableState.value = PairingUiState.Failed("This device needs setup before it can use this host.")
            return
        }
        if (!descriptorMatchesLocal(descriptor)) {
            submit("cancel")
            mutableState.value = PairingUiState.Failed("The continuation route no longer matches this device's saved jump-host route.")
            return
        }
        acceptRetainedDescriptor(descriptor, attemptId)
    }

    private suspend fun descriptorMatchesLocal(descriptor: JSONObject): Boolean {
        val local = hosts.host(descriptor.getString("hostID")) ?: return false
        val route = runCatching { descriptor.toDescriptorRoute() }.getOrNull() ?: return false
        return ContinuationRouteMatchPolicy.matches(route, local, hosts.resolveRoute(local.id))
    }

    private fun JSONObject.toDescriptorRoute(): ContinuationRouteMatchPolicy.DescriptorRoute {
        val via = getJSONArray("via")
        return ContinuationRouteMatchPolicy.DescriptorRoute(
            schemaVersion = getInt("v"),
            destination = ContinuationRouteMatchPolicy.DescriptorRoute.Endpoint(
                user = getString("user"),
                address = getString("address"),
                port = getInt("port"),
            ),
            via = (0 until via.length()).map { index ->
                val hop = via.getJSONObject(index)
                ContinuationRouteMatchPolicy.DescriptorRoute.Hop(
                    hostId = hop.getString("hostID"),
                    user = hop.getString("user"),
                    address = hop.getString("address"),
                    port = hop.getInt("port"),
                )
            },
        )
    }

    private suspend fun acceptRetainedDescriptor(descriptor: JSONObject, attemptId: String) {
        val hostId = descriptor.getString("hostID")
        receipts.record(CrossDeviceReceipt(attemptId, "continuation-descriptor", listOf(UUID.fromString(hostId).toString()), System.currentTimeMillis()))
        submit("continuationDescriptorDurablyAccepted", mapOf("atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis())))
    }

    private suspend fun requireRenderedConnection(descriptor: JSONObject, attemptId: String) {
        val hostId = UUID.fromString(descriptor.getString("hostID")).toString()
        val transport = descriptor.getString("transport")
        val tmux = descriptor.optString("tmux").takeIf { it.isNotBlank() }
        mutableState.value = PairingUiState.AwaitingConnection(hostId, transport, tmux)
        recordDiagnostic(
            "pairing_connection_required",
            mapOf("transport" to transport, "tmux" to (tmux != null).toString(), "purpose" to purpose?.wire.orEmpty()),
        )
        pendingConnectionHostID = hostId
        pendingConnectionTmuxTarget = tmux
        pendingConnectionAttemptID = attemptId
        pendingContinuationRecovery.stage(
            PendingContinuationRecovery(
                attemptId = attemptId,
                hostId = hostId,
                transportKind = transport,
                tmuxTarget = tmux,
                routeIdentity = descriptorRouteIdentity(descriptor),
                stagedAtEpochMilliseconds = System.currentTimeMillis(),
            ),
        )
        onConnectionRequired(hostId, transport, tmux, attemptId)
    }

    private suspend fun recoveryCredentialUsable(host: SavedHost): Boolean {
        val identityId = host.identityId ?: return true // Password is re-prompted by the destination session.
        val identity = identities.identity(identityId) ?: return false
        if (identity.credentialKind != CredentialKinds.ANDROID_KEYSTORE_P256) return false
        return runCatching { credentialStore.load(identity.credentialReference) }.isSuccess
    }

    private suspend fun submitRecipientPublicKey() {
        val generated = generateIdentity(saveImmediately = true)
        val stored = generated.stored
        recipientIdentityId = checkNotNull(generated.savedIdentityId)
        val claim = when {
            stored.capabilities.strongBoxBacked -> "platformStrongHardware"
            stored.capabilities.securityLevel.name != "SOFTWARE" -> "platformHardwareBacked"
            else -> "platformProtected"
        }
        recordDiagnostic("pairing_key_generated", mapOf("protection" to claim, "result" to "saved"))
        val fingerprint = SharedTrustPolicy.sha256Fingerprint(stored.publicKeyBlob)
        val descriptor = CanonicalCrossDeviceJson.objectValue(
            mapOf(
                "algorithm" to CanonicalCrossDeviceJson.JsonValue.String("ecdsa-sha2-nistp256"),
                "displayName" to CanonicalCrossDeviceJson.JsonValue.String(generated.displayName),
                "fingerprint" to CanonicalCrossDeviceJson.JsonValue.String(fingerprint),
                "id" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(stored.keyId)),
                "protectionClaim" to CanonicalCrossDeviceJson.JsonValue.String(claim),
                "sshBlob" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.base64(stored.publicKeyBlob)),
            ),
        )
        submit("provideBootstrapRecipientPublicKey", mapOf("publicKey" to CanonicalCrossDeviceJson.JsonValue.Raw(descriptor)))
    }

    private suspend fun submitEnrollmentRequest(attemptId: String) {
        val target = checkNotNull(enrollmentTargetHost) { "Choose a local host before enrollment" }
        val generated = generateIdentity(saveImmediately = true)
        val identityId = checkNotNull(generated.savedIdentityId)
        val enrollmentId = UUID.randomUUID()
        val publicKey = CanonicalCrossDeviceJson.objectValue(
            mapOf(
                "algorithm" to CanonicalCrossDeviceJson.JsonValue.String("ecdsa-sha2-nistp256"),
                "blob" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.base64(generated.stored.publicKeyBlob)),
                "displayName" to CanonicalCrossDeviceJson.JsonValue.String(generated.displayName),
                "fingerprint" to CanonicalCrossDeviceJson.JsonValue.String(generated.fingerprint),
                "id" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(generated.stored.keyId)),
                // Enrollment v1 is frozen; this field is display metadata, not authority.
                "protection" to CanonicalCrossDeviceJson.JsonValue.String("software"),
            ),
        )
        val request = CanonicalCrossDeviceJson.objectValue(
            mapOf(
                "hostID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(target.id))),
                "hostName" to CanonicalCrossDeviceJson.JsonValue.String(target.displayName.take(128)),
                "id" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(enrollmentId)),
                "publicKey" to CanonicalCrossDeviceJson.JsonValue.Raw(publicKey),
                "requestingDeviceName" to CanonicalCrossDeviceJson.JsonValue.String((Build.MODEL.ifBlank { "Android device" }).take(128)),
            ),
        )
        receipts.stagePendingAccess(PendingCrossDeviceAccess(attemptId, target.id, identityId, System.currentTimeMillis()))
        generatedIdentityRetained = true
        submit("beginEnrollment", mapOf("enrollmentRequest" to CanonicalCrossDeviceJson.JsonValue.Raw(request)))
        mutableState.value = PairingUiState.Working("Waiting for the source device to approve enrollment…", Phase.waitingForSelection)
    }

    private suspend fun generateIdentity(saveImmediately: Boolean): GeneratedIdentity {
        generatedIdentity?.let { return it }
        val alias = "tessera-pairing-${UUID.randomUUID()}"
        val stored = withContext(Dispatchers.IO) { credentialStore.generateP256(alias, ownerAuthenticationRequired = false) }
        val displayName = "paired Android device"
        val fingerprint = SharedTrustPolicy.sha256Fingerprint(stored.publicKeyBlob)
        val savedId = if (saveImmediately) {
            identities.save(displayName, CredentialKinds.ANDROID_KEYSTORE_P256, alias).id
        } else null
        return GeneratedIdentity(alias, displayName, fingerprint, stored, savedId).also { generatedIdentity = it }
    }

    private suspend fun importBootstrap(manifest: JSONObject, attemptId: String, expectedGeneration: Long) {
        if (!pairingGenerationIsCurrent(expectedGeneration)) return
        val accepted = mutableListOf<String>()
        val identityId = checkNotNull(recipientIdentityId) { "Recipient key was not generated" }
        val sourceHosts = manifest.getJSONArray("hosts")
        val byId = buildMap {
            for (index in 0 until sourceHosts.length()) {
                val item = sourceHosts.getJSONObject(index)
                put(UUID.fromString(item.getString("id")).toString(), item)
            }
        }
        val parent = buildMap {
            val chains = manifest.optJSONArray("jumpChains") ?: JSONArray()
            for (index in 0 until chains.length()) {
                val link = chains.getJSONObject(index)
                put(UUID.fromString(link.getString("hostID")).toString(), UUID.fromString(link.getString("jumpHostID")).toString())
            }
        }
        val pending = byId.keys.toMutableSet()
        while (pending.isNotEmpty()) {
            val ready = pending.filter { parent[it] == null || parent[it] in accepted }
            require(ready.isNotEmpty()) { "Bootstrap manifest has a cyclic or missing jump host" }
            for (id in ready) {
                if (!pairingGenerationIsCurrent(expectedGeneration)) return
                val source = checkNotNull(byId[id])
                val normalizedId = UUID.fromString(source.getString("id")).toString()
                val transport = source.getString("transport")
                val launch = source.getString("launchMode")
                val draft = HostDraft(
                    id = normalizedId,
                    displayName = source.getString("name"),
                    hostname = source.getString("address"),
                    port = source.getInt("port"),
                    username = source.getString("user"),
                    jumpHostId = parent[normalizedId]?.let { UUID.fromString(it).toString() },
                    // Access linkage is committed only after a verified grant receipt.
                    identityId = null,
                    transportKind = if (transport == "mosh") TransportKinds.MOSH else TransportKinds.SSH,
                    tmuxMode = when (launch) {
                        "autoTmux" -> TmuxModes.AUTOMATIC
                        "pinnedTmux" -> TmuxModes.PINNED
                        else -> TmuxModes.OFF
                    },
                    tmuxTarget = source.optString("tmuxSessionName").takeIf { it.isNotBlank() },
                    launchCommand = source.optString("launchCommand").takeIf { !source.isNull("launchCommand") && it.isNotBlank() },
                    notes = source.optString("notes").takeIf { !source.isNull("notes") && it.isNotBlank() },
                    envVars = source.optString("envVars").takeIf { !source.isNull("envVars") && it.isNotBlank() },
                    startupSnippet = source.optString("startupSnippet").takeIf { !source.isNull("startupSnippet") && it.isNotBlank() },
                )
                val existing = hosts.host(normalizedId)
                if (!pairingGenerationIsCurrent(expectedGeneration)) return
                if (existing != null) {
                    require(existing.matchesImportedHost(draft)) {
                        "Saved host $normalizedId conflicts with the authenticated bootstrap manifest"
                    }
                }
                if (source.optString("authenticationHint") == "password" && existing?.identityId == null) {
                    passwordBootstrapHostIds += normalizedId
                } else {
                    receipts.stagePendingAccess(
                        PendingCrossDeviceAccess(attemptId, normalizedId, identityId, System.currentTimeMillis()),
                    )
                }
                if (!pairingGenerationIsCurrent(expectedGeneration)) return
                if (existing == null) {
                    hosts.save(draft)
                } else {
                    // Repeated bootstrap can fill approved missing data without
                    // overwriting local text, credentials, or transport choices.
                    hosts.save(existing.asDraft(existing.identityId).copy(
                        launchCommand = existing.launchCommand ?: draft.launchCommand,
                        notes = existing.notes ?: draft.notes,
                        envVars = existing.envVars ?: draft.envVars,
                        startupSnippet = existing.startupSnippet ?: draft.startupSnippet,
                    ))
                }
                val importedForwards = source.optJSONArray("portForwards")?.let { items ->
                    buildList {
                        for (forwardIndex in 0 until items.length()) {
                            val item = items.getJSONObject(forwardIndex)
                            add(
                                PortForwardRule(
                                    id = UUID.fromString(item.getString("id")),
                                    enabled = item.getBoolean("enabled"),
                                    autoStart = item.getBoolean("autoStart"),
                                    direction = PortForwardDirection.LOCAL,
                                    bind = PortForwardEndpoint("127.0.0.1", item.getInt("localPort")),
                                    target = PortForwardEndpoint(
                                        item.getString("remoteHost"),
                                        item.getInt("remotePort"),
                                    ),
                                    label = item.getString("label"),
                                ),
                            )
                        }
                    }
                }.orEmpty()
                // The frozen cross-device manifest carries portable local
                // forwards only. Keep Android-only remote/dynamic rules when
                // refreshing an existing host from another device.
                val androidOnlyForwards = forwardingRules.observe(normalizedId).first().filter {
                    it.direction != PortForwardDirection.LOCAL
                }
                forwardingRules.replace(normalizedId, androidOnlyForwards + importedForwards)
                accepted += normalizedId
                pending -= normalizedId
            }
        }
        if (!pairingGenerationIsCurrent(expectedGeneration)) return
        // Only authenticated, selected manifest records reach this adapter.
        // Import new pins conditionally; a local pin (including a rotation)
        // always wins over a setup transfer.
        val trustedRecords = manifest.optJSONArray("knownHosts") ?: JSONArray()
        for (index in 0 until trustedRecords.length()) {
            if (!pairingGenerationIsCurrent(expectedGeneration)) return
            val record = trustedRecords.getJSONObject(index)
            val hostId = UUID.fromString(record.getString("hostID")).toString()
            if (hostId !in accepted) continue
            val source = checkNotNull(byId[hostId])
            val key = record.getString("keyString").trim().split(Regex("\\s+"))
            require(key.size >= 2) { "Invalid trusted host key" }
            val blob = Base64.decode(key[1], Base64.NO_WRAP)
            require(bootstrapFingerprint(blob) == record.getString("fingerprint"))
            // Await the repository's initial load before its compare-and-set.
            knownHosts.loadedKnownHosts.first { it != null }
            if (!pairingGenerationIsCurrent(expectedGeneration)) return
            knownHosts.trustIfUnchanged(source.getString("address"), source.getInt("port"), key[0], blob, null)
        }
        if (!pairingGenerationIsCurrent(expectedGeneration)) return
        manifest.optJSONObject("appearance")?.let { appearance ->
            appearance.optInt("terminalFontSize").takeIf { it in 8..40 }
                ?.let { appPreferences.updateTerminalTextSize(it) }
            // Normalized on ingest so a legacy PostScript name from an older
            // iOS build, or a family only the sending device has, is stored as
            // something this device can actually render.
            appearance.optString("monospacedFontName").takeIf { it.isNotEmpty() }
                ?.let { appPreferences.updateTerminalFontId(TerminalFontCatalog.resolve(it)) }
        }
        manifest.optJSONObject("settings")?.let { settings ->
            BootstrapAgentCenterSetting.importedValue(settings.opt("agentCenterEnabled"))
                ?.let { appPreferences.updateAgentCenterEnabled(it) }
            settings.optInt("scrollbackLines").takeIf { it in 1_000..50_000 }
                ?.let { appPreferences.updateScrollbackLines(it) }
            if (settings.has("bellSoundEnabled")) {
                appPreferences.updateBellSoundEnabled(settings.getBoolean("bellSoundEnabled"))
            }
            if (settings.has("bellVisualEnabled")) {
                appPreferences.updateBellVisualEnabled(settings.getBoolean("bellVisualEnabled"))
            }
            if (settings.has("bellNotificationEnabled")) {
                appPreferences.updateBellNotificationEnabled(settings.getBoolean("bellNotificationEnabled"))
            }
        }
        val now = System.currentTimeMillis()
        receipts.record(CrossDeviceReceipt(attemptId, "bootstrap-import", accepted, now))
        // A canceled import can finish a suspended storage write after a new
        // pairing starts. Its progress and acknowledgement belong only to it.
        if (!pairingGenerationIsCurrent(expectedGeneration)) return
        generatedIdentityRetained = accepted.any { it !in passwordBootstrapHostIds }
        recordDiagnostic("pairing_import_recorded", mapOf("hosts" to accepted.size.toString(), "result" to "staged"))
        mutableState.value = PairingUiState.Working(
            "Setup copied. Waiting for the sender to authorize and verify this device’s key…", Phase.waitingForGrant,
        )
        submit(
            "bootstrapImportDurablyApplied",
            mapOf(
                "acceptedHostIDs" to CanonicalCrossDeviceJson.JsonValue.Array(accepted.map { CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(it))) }),
                "atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(now),
            ),
        )
    }

    private fun pairingGenerationIsCurrent(expectedGeneration: Long): Boolean =
        generation == expectedGeneration && runtime != null && !operationRetired

    private suspend fun verifyRemoteGrants(request: JSONObject) {
        val expectedGeneration = generation
        val manifest = request.getJSONObject("manifest")
        val recipientKey = request.getJSONObject("recipientKey")
        val publicLine = recipientKey.getString("algorithm") + " " + recipientKey.getString("sshBlob")
        val acceptedHostIds = request.getJSONObject("acceptance").getJSONArray("acceptedHostIDs").let { ids ->
            buildSet { for (index in 0 until ids.length()) add(ids.getString(index)) }
        }
        val results = mutableListOf<CanonicalCrossDeviceJson.JsonValue.Raw>()
        verifiedGrantHostIds.clear()
        failedGrantHostIds.clear()
        mutableState.value = PairingUiState.Working("Installing and verifying the recipient key on source hosts…", Phase.granting)
        val sourceHosts = manifest.getJSONArray("hosts")
        setupReceiptNames = manifestSummaries(manifest).associate { it.id to it.name }
        for (index in 0 until sourceHosts.length()) {
            val host = sourceHosts.getJSONObject(index)
            val hostId = host.getString("id")
            val normalizedId = UUID.fromString(hostId).toString()
            setupReceiptFacts[normalizedId] = SharedSetupFlow.HostFact(normalizedId, SharedSetupFlow.Access.unknown,
                accepted = hostId in acceptedHostIds, passwordNeeded = host.optString("authenticationHint") == "password")
            if (hostId !in acceptedHostIds) continue
            if (host.optString("authenticationHint") == "password") {
                passwordBootstrapHostIds += UUID.fromString(hostId).toString()
                results += CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(mapOf(
                    "hostID" to CanonicalCrossDeviceJson.JsonValue.String(hostId.uppercase()),
                    "status" to CanonicalCrossDeviceJson.JsonValue.String("skipped"),
                )))
                continue
            }
            val result = runCatching {
                grantInstaller?.invoke(hostId, publicLine)
                    ?: installAndVerifyPublicKey(hostId, publicLine)
            }
            result.exceptionOrNull()?.let { if (it is CancellationException) throw it }
            // A native installer may finish after cancellation. Its external
            // grant still needs reconciliation, but must not advance or paint
            // a replacement pairing attempt.
            if (!pairingGenerationIsCurrent(expectedGeneration)) return
            if (result.isSuccess) verifiedGrantHostIds += UUID.fromString(hostId).toString()
            else failedGrantHostIds += UUID.fromString(hostId).toString()
            setupReceiptFacts[normalizedId] = SharedSetupFlow.HostFact(normalizedId,
                if (result.isSuccess) {
                    if (result.getOrThrow()) SharedSetupFlow.Access.installed else SharedSetupFlow.Access.alreadyInstalled
                } else SharedSetupFlow.Access.failed, accepted = true)
            results += CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(buildMap {
                put("hostID", CanonicalCrossDeviceJson.JsonValue.String(hostId.uppercase()))
                if (result.isSuccess) put("status", CanonicalCrossDeviceJson.JsonValue.String(if (result.getOrThrow()) "installed" else "alreadyInstalled"))
                else {
                    put("status", CanonicalCrossDeviceJson.JsonValue.String("failed"))
                    put("errorCode", CanonicalCrossDeviceJson.JsonValue.String((result.exceptionOrNull() as? PairingGrantException)?.code ?: "grant_verification_failed"))
                }
            }))
        }
        submit(
            "bootstrapRemoteGrantsDurablyVerified",
            mapOf(
                "grantResults" to CanonicalCrossDeviceJson.JsonValue.Array(results),
                "atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis()),
                "policyGeneration" to CanonicalCrossDeviceJson.JsonValue.Number(policyGeneration),
            ),
        )
        recordDiagnostic(
            "pairing_grants_verified",
            mapOf(
                "grants" to verifiedGrantHostIds.size.toString(),
                "result" to if (failedGrantHostIds.isEmpty()) "success" else "partial",
                "count" to failedGrantHostIds.size.toString(),
            ),
        )
        if (failedGrantHostIds.isNotEmpty()) {
            mutableState.value = PairingUiState.Failed("One or more source hosts did not verify the recipient public-key grant.")
        }
    }

    private suspend fun installAndVerifyPublicKey(hostId: String, publicLine: String): Boolean {
        ensureSourcePolicyIsCurrent()
        val target = hosts.host(hostId) ?: throw PairingGrantException("source_host_unavailable")
        val route = hosts.resolveRoute(hostId).map { hop ->
            val identity = hop.identityId?.let { identities.identity(it) }
            val authentication = if (identity == null) SshAuthentication.Password else {
                if (identity.credentialKind != CredentialKinds.ANDROID_KEYSTORE_P256) throw PairingGrantException("source_auth_unsupported")
                SshAuthentication.AndroidKeystoreP256(identity.credentialReference)
            }
            SshRouteHop(hop.id, SshEndpoint(hop.hostname, hop.port), hop.username, authentication)
        }
        val backend = AndroidSshBackend()
        var policyFailure: PairingGrantException? = null
        val connection = try {
            backend.connectRoute(
                SshRouteRequest(route),
                passwordProvider = SshPasswordProvider(::requestSourcePassword),
                hostKeyPolicy = SshHostKeyPolicy { observed ->
                    if (knownHosts.evaluate(observed.host, observed.port, observed.algorithm, observed.canonicalKeyBlob) != HostTrustEvaluation.Trusted) {
                        policyFailure = PairingGrantException("host_key_untrusted")
                        false
                    } else true
                },
            )
        } catch (failure: Throwable) {
            throw policyFailure ?: if (failure is CancellationException) failure else PairingGrantException("source_auth_failed")
        }
        connection.use {
            val marker = UUID.randomUUID().toString().replace("-", "")
            val line = publicLine.replace("'", "'\\''")
            val command = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; line='$line'; " +
                "grep -Fqx -- \"${'$'}line\" ~/.ssh/authorized_keys || printf '%s\\n' \"${'$'}line\" >> ~/.ssh/authorized_keys; " +
                "chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; grep -Fqx -- \"${'$'}line\" ~/.ssh/authorized_keys && " +
                "printf 'TESSERA_'; printf 'GRANT_$marker\\n'; exit"
            it.write((command + "\n").encodeToByteArray())
            val output = withTimeout(45_000) { withContext(Dispatchers.IO) { it.standardOutput.bufferedReader().readText() } }
            if ("TESSERA_GRANT_$marker" !in output) throw PairingGrantException("grant_verification_failed")
            ensureSourcePolicyIsCurrent()
            return true
        }
    }

    private suspend fun requestSourcePassword(hop: SshRouteHop): CharArray {
        val decision = CompletableDeferred<CharArray>()
        passwordDecision = decision
        mutableState.value = PairingUiState.AwaitingSourcePassword(hop.endpoint.host, hop.username)
        return try {
            decision.await()
        } finally {
            if (passwordDecision === decision) passwordDecision = null
        }
    }

    private suspend fun prepareEnrollmentApproval(request: JSONObject, attemptId: String) {
        val source = JSONObject(checkNotNull(originDescriptor).decodeToString())
        require(UUID.fromString(request.getString("hostID")) == UUID.fromString(source.getString("hostID"))) {
            "Enrollment requested a different host than the authenticated offer"
        }
        pendingEnrollmentRequest = request
        pendingOwnerAction = PendingOwnerAction.Enrollment(
            attemptId,
            source.getString("connectionKey"),
            sourcePolicyFingerprint(),
        )
        mutableState.value = PairingUiState.AwaitingOwnerApproval(
            "Enroll ${request.getString("requestingDeviceName")} for ${request.getString("hostName")}.",
        )
    }

    private suspend fun performEnrollmentInstallation(request: JSONObject, attemptId: String) {
        val enrollment = checkNotNull(pendingEnrollmentRequest) { "Enrollment approval state was lost" }
        require(UUID.fromString(request.getString("enrollmentID")) == UUID.fromString(enrollment.getString("id")))
        val hostId = enrollment.getString("hostID")
        installAndVerifyPublicKey(hostId, request.getString("authorizedKeysLine"))
        val now = System.currentTimeMillis()
        val fingerprint = enrollment.getJSONObject("publicKey").getString("fingerprint")
        val routeIdentity = JSONObject(checkNotNull(originDescriptor).decodeToString()).getString("connectionKey")
        receipts.record(CrossDeviceReceipt(attemptId, "enrollment-installed", listOf(UUID.fromString(hostId).toString()), now))
        submit(
            "enrollmentInstallationDurablyVerified",
            mapOf(
                "atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(now),
                "enrollmentID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(request.getString("enrollmentID")))),
                "publicKeyFingerprint" to CanonicalCrossDeviceJson.JsonValue.String(fingerprint),
                "routeIdentity" to CanonicalCrossDeviceJson.JsonValue.String(routeIdentity),
            ),
        )
        mutableState.value = PairingUiState.Working("The key was verified; waiting for the recipient to record access…", Phase.recordingAccess)
    }

    private suspend fun recordEnrollment(request: JSONObject, attemptId: String) {
        val generated = checkNotNull(generatedIdentity) { "Generated enrollment identity was lost" }
        val target = checkNotNull(enrollmentTargetHost) { "Enrollment host was lost" }
        require(UUID.fromString(request.getString("hostID")) == UUID.fromString(target.id))
        val publicKey = request.getJSONObject("publicKey")
        require(UUID.fromString(publicKey.getString("id")) == generated.stored.keyId)
        require(publicKey.getString("fingerprint") == generated.fingerprint)
        require(Base64.decode(publicKey.getString("blob"), Base64.NO_WRAP).contentEquals(generated.stored.publicKeyBlob))
        val identityId = checkNotNull(generated.savedIdentityId) { "Enrollment identity was not durably staged" }
        hosts.save(target.asDraft(identityId = identityId))
        receipts.clearPendingAccessForHost(target.id)
        val now = System.currentTimeMillis()
        val enrollmentId = UUID.fromString(request.getString("id"))
        receipts.record(CrossDeviceReceipt(attemptId, "enrollment-recorded", listOf(target.id), now))
        generatedIdentityRetained = true
        submit(
            "enrollmentRequesterRecordDurablyCommitted",
            mapOf(
                "atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(now),
                "enrollmentID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(enrollmentId)),
                "publicKeyFingerprint" to CanonicalCrossDeviceJson.JsonValue.String(generated.fingerprint),
            ),
        )
        mutableState.value = PairingUiState.Working("Access is recorded; waiting for the source acknowledgement…", Phase.recordingAccess)
    }

    /**
     * Builds a command locally, then submits the bytes the core hands back.
     *
     * The pairing ABI applies a strict byte-equality gate — a payload must
     * re-encode to itself — so an adapter cannot smuggle ignored fields or an
     * alternate JSON spelling past the boundary. [CanonicalCrossDeviceJson]
     * still gives the command its structure, but Swift's encoder is the
     * authority on how that structure is spelled.
     *
     * Swift authority: `Sources/TesseraCoreABI/PairingQRABI.swift`
     * (`tessera_cross_device_canonicalize_command`), reached through
     * `SharedCrossDeviceCommand`.
     */
    private fun submit(kind: String, fields: Map<String, CanonicalCrossDeviceJson.JsonValue> = emptyMap()) {
        val bridge = runtime ?: return
        val canonical = try {
            SharedCrossDeviceCommand.canonicalize(CanonicalCrossDeviceJson.command(kind, generation, fields))
        } catch (rejection: IllegalArgumentException) {
            recordDiagnostic(
                "pairing_command_rejected",
                mapOf("kind" to kind, "code" to rejection::class.java.simpleName),
            )
            mutableState.value = PairingUiState.Failed("Rejected pairing command")
            closePairingTransport()
            return
        }
        when (bridge.sendCanonical(canonical)) {
            CoreCallResult.Accepted -> Unit
            CoreCallResult.StaleHandle -> mutableState.value = PairingUiState.Failed("Pairing attempt is no longer active")
            CoreCallResult.InvalidArguments -> mutableState.value = PairingUiState.Failed("Rejected pairing command")
        }
    }

    private fun closePairingTransport() {
        rendezvous?.close()
        rendezvous = null
        pendingEndpointCandidates = null
    }

    private fun invalidateSourcePolicy(message: String) {
        operationRetired = true
        policyGeneration += 1
        issuedOwnerToken = null
        pendingOwnerAction = null
        authorizedSourcePolicyFingerprint = null
        authorizedSourceHostIds = null
        originJumpParents = emptyMap()
        originSelectedHostIds = emptySet()
        originSelectedOptionalTransfers = emptySet()
        submit("securityPolicyChanged", mapOf("policyGeneration" to CanonicalCrossDeviceJson.JsonValue.Number(policyGeneration)))
        closePairingTransport()
        mutableState.value = PairingUiState.Failed(message)
    }

    private suspend fun ensureSourcePolicyIsCurrent() {
        val expected = authorizedSourcePolicyFingerprint ?: throw PairingGrantException("source_policy_changed")
        if (sourcePolicyFingerprint(authorizedSourceHostIds) != expected) throw PairingGrantException("source_policy_changed")
    }

    private suspend fun sourcePolicyFingerprint(sourceHostIds: Set<String>? = null): String {
        val route = if (sourceHostIds == null) {
            val descriptor = JSONObject(checkNotNull(originDescriptor).decodeToString())
            hosts.resolveRoute(descriptor.getString("hostID"))
        } else {
            sourceHostIds.map { id -> hosts.host(id) ?: error("source host is unavailable") }
                .sortedBy(SavedHost::id)
        }
        val trustedHosts = knownHosts.observeKnownHosts().first().associateBy { it.normalizedEndpoint }
        val projection = route.map { host ->
            val identity = host.identityId?.let { identities.identity(it) }
            val trusted = trustedHosts[com.bambouville.tessera.data.AndroidKnownHostsRepository.normalizeEndpoint(host.hostname, host.port)]
            CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(mapOf(
                "hostID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(host.id))),
                "endpoint" to CanonicalCrossDeviceJson.JsonValue.String("${host.hostname}:${host.port}"),
                "user" to CanonicalCrossDeviceJson.JsonValue.String(host.username),
                "jumpHostID" to CanonicalCrossDeviceJson.JsonValue.String(host.jumpHostId?.let { CanonicalCrossDeviceJson.uuid(UUID.fromString(it)) }.orEmpty()),
                "transport" to CanonicalCrossDeviceJson.JsonValue.String(host.transportKind.wireTransport()),
                "tmuxMode" to CanonicalCrossDeviceJson.JsonValue.String(host.tmuxMode),
                "tmuxTarget" to CanonicalCrossDeviceJson.JsonValue.String(host.tmuxTarget.orEmpty()),
                "identityID" to CanonicalCrossDeviceJson.JsonValue.String(identity?.id.orEmpty()),
                "credentialKind" to CanonicalCrossDeviceJson.JsonValue.String(identity?.credentialKind.orEmpty()),
                "credentialReference" to CanonicalCrossDeviceJson.JsonValue.String(identity?.credentialReference.orEmpty()),
                "trustedAlgorithm" to CanonicalCrossDeviceJson.JsonValue.String(trusted?.algorithm.orEmpty()),
                "trustedKey" to CanonicalCrossDeviceJson.JsonValue.String(trusted?.canonicalKeyBlob?.let(CanonicalCrossDeviceJson::base64).orEmpty()),
            )))
        }
        val bytes = CanonicalCrossDeviceJson.objectValue(
            mapOf("route" to CanonicalCrossDeviceJson.JsonValue.Array(projection)),
        ).encodeToByteArray()
        return CanonicalCrossDeviceJson.base64(MessageDigest.getInstance("SHA-256").digest(bytes))
    }

    private fun scheduleExpiry(seconds: Long) {
        expiryJob?.cancel()
        val expectedGeneration = generation
        expiryJob = scope.launch {
            delay((seconds.coerceAtLeast(0) * 1_000) + 50)
            if (generation == expectedGeneration) submit("checkExpiration")
        }
    }

    private suspend fun continuationDescriptor(host: SavedHost): ByteArray {
        val route = hosts.resolveRoute(host.id)
        require(route.isNotEmpty() && route.last().id == host.id) { "Invalid route for continuation" }
        val hostId = CanonicalCrossDeviceJson.uuid(UUID.fromString(host.id))
        val transport = if (host.transportKind == TransportKinds.MOSH) "mosh" else "ssh"
        val launch = when (host.tmuxMode) {
            TmuxModes.AUTOMATIC -> "autoTmux"
            TmuxModes.PINNED -> "pinnedTmux"
            else -> "customCommand"
        }
        val via = ArrayList<CanonicalCrossDeviceJson.JsonValue>()
        for (hop in route.dropLast(1)) {
            via += CanonicalCrossDeviceJson.JsonValue.Raw(
                CanonicalCrossDeviceJson.objectValue(mapOf(
                    "address" to CanonicalCrossDeviceJson.JsonValue.String(hop.hostname),
                    "hostID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(hop.id))),
                    "name" to CanonicalCrossDeviceJson.JsonValue.String(hop.displayName),
                    "port" to CanonicalCrossDeviceJson.JsonValue.Number(hop.port.toLong()),
                    "transport" to CanonicalCrossDeviceJson.JsonValue.String(if (hop.transportKind == TransportKinds.MOSH) "mosh" else "ssh"),
                    "user" to CanonicalCrossDeviceJson.JsonValue.String(hop.username),
                )),
            )
        }
        val value = linkedMapOf<String, CanonicalCrossDeviceJson.JsonValue>(
            "address" to CanonicalCrossDeviceJson.JsonValue.String(host.hostname),
            "connectionKey" to CanonicalCrossDeviceJson.JsonValue.String(
                connectionKey(host, route.dropLast(1)),
            ),
            "hostID" to CanonicalCrossDeviceJson.JsonValue.String(hostId),
            "launchMode" to CanonicalCrossDeviceJson.JsonValue.String(launch),
            "name" to CanonicalCrossDeviceJson.JsonValue.String(host.displayName),
            "port" to CanonicalCrossDeviceJson.JsonValue.Number(host.port.toLong()),
            "transport" to CanonicalCrossDeviceJson.JsonValue.String(transport),
            "user" to CanonicalCrossDeviceJson.JsonValue.String(host.username),
            "v" to CanonicalCrossDeviceJson.JsonValue.Number(1),
            "via" to CanonicalCrossDeviceJson.JsonValue.Array(via),
        )
        when (host.tmuxMode) {
            TmuxModes.AUTOMATIC -> value["tmux"] = CanonicalCrossDeviceJson.JsonValue.String(host.tmuxSession()!!)
            TmuxModes.PINNED -> value["tmux"] = CanonicalCrossDeviceJson.JsonValue.String(requireNotNull(host.tmuxTarget) { "Pinned tmux requires a target" })
        }
        return CanonicalCrossDeviceJson.objectValue(value).encodeToByteArray()
    }

    private suspend fun buildManifestForAllHosts(peerSupportsAgentCenterEnabled: Boolean = false): String {
        val route = allHostsInRouteOrder()
        require(route.isNotEmpty()) { "No saved hosts are available to bootstrap" }
        val portableForwards = route.associate { host ->
            host.id to forwardingRules.observe(host.id).first().filter {
                it.direction == PortForwardDirection.LOCAL
            }
        }
        val preferences = appPreferences.values.first()
        val pins = knownHosts.observeKnownHosts().first().associateBy { it.normalizedEndpoint }
        val knownHostItems = route.mapNotNull { host ->
            val pin = pins[AndroidKnownHostsRepository.normalizeEndpoint(host.hostname, host.port)] ?: return@mapNotNull null
            CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(mapOf(
                "hostID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(host.id))),
                "fingerprint" to CanonicalCrossDeviceJson.JsonValue.String(bootstrapFingerprint(pin.canonicalKeyBlob)),
                "keyString" to CanonicalCrossDeviceJson.JsonValue.String(KnownHostKeys.openSshKeyString(pin.algorithm, pin.canonicalKeyBlob)),
                // BootstrapManifestV2 uses JSONEncoder's reference-date seconds.
                "firstSeen" to CanonicalCrossDeviceJson.JsonValue.Number(pin.firstSeenAtEpochMilliseconds / 1000 - 978307200),
                "lastSeen" to CanonicalCrossDeviceJson.JsonValue.Number(pin.lastVerifiedAtEpochMilliseconds / 1000 - 978307200),
            )))
        }
        val hostItems = route.mapIndexed { index, host ->
            val forwardItems = portableForwards[host.id].orEmpty().map { rule ->
                CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(mapOf(
                    "id" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(rule.id)),
                    "enabled" to CanonicalCrossDeviceJson.JsonValue.Boolean(rule.enabled),
                    "autoStart" to CanonicalCrossDeviceJson.JsonValue.Boolean(rule.autoStart),
                    "localPort" to CanonicalCrossDeviceJson.JsonValue.Number(rule.bind.port.toLong()),
                    "remoteHost" to CanonicalCrossDeviceJson.JsonValue.String(checkNotNull(rule.target).host),
                    "remotePort" to CanonicalCrossDeviceJson.JsonValue.Number(checkNotNull(rule.target).port.toLong()),
                    "label" to CanonicalCrossDeviceJson.JsonValue.String(rule.label),
                )))
            }
            val values = linkedMapOf<String, CanonicalCrossDeviceJson.JsonValue>(
                "address" to CanonicalCrossDeviceJson.JsonValue.String(host.hostname),
                "authenticationHint" to CanonicalCrossDeviceJson.JsonValue.String(if (host.identityId == null) "password" else "publicKey"),
                "id" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(host.id))),
                "launchMode" to CanonicalCrossDeviceJson.JsonValue.String(host.launchMode()),
                "name" to CanonicalCrossDeviceJson.JsonValue.String(host.displayName),
                "osHint" to CanonicalCrossDeviceJson.JsonValue.String("linux"),
                "port" to CanonicalCrossDeviceJson.JsonValue.Number(host.port.toLong()),
                "portForwards" to CanonicalCrossDeviceJson.JsonValue.Array(forwardItems),
                "sortOrder" to CanonicalCrossDeviceJson.JsonValue.Number(index.toLong()),
                "tags" to CanonicalCrossDeviceJson.JsonValue.Array(emptyList()),
                "transport" to CanonicalCrossDeviceJson.JsonValue.String(host.transportKind.wireTransport()),
                "user" to CanonicalCrossDeviceJson.JsonValue.String(host.username),
            )
            host.tmuxSession()?.let { values["tmuxSessionName"] = CanonicalCrossDeviceJson.JsonValue.String(it) }
            mapOf("launchCommand" to host.launchCommand, "notes" to host.notes,
                "envVars" to host.envVars, "startupSnippet" to host.startupSnippet).forEach { (key, value) ->
                value?.let { values[key] = CanonicalCrossDeviceJson.JsonValue.String(it) }
            }
            CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(values))
        }
        val jumpLinks = route.mapNotNull { host -> host.jumpHostId?.let { parent ->
            CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(mapOf(
                "hostID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(host.id))),
                "jumpHostID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(UUID.fromString(parent))),
            )))
        } }
        return CanonicalCrossDeviceJson.objectValue(mapOf(
            "appearance" to CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(mapOf(
                "accent" to CanonicalCrossDeviceJson.JsonValue.String("blue"), "chromeMaterial" to CanonicalCrossDeviceJson.JsonValue.String("regular"),
                "colorScheme" to CanonicalCrossDeviceJson.JsonValue.String("system"), "cursorBlink" to CanonicalCrossDeviceJson.JsonValue.Boolean(true),
                "cursorStyle" to CanonicalCrossDeviceJson.JsonValue.String("block"), "customAccentRGB" to CanonicalCrossDeviceJson.JsonValue.Number(0),
                "monospacedFontName" to CanonicalCrossDeviceJson.JsonValue.String(
                    TerminalFontCatalog.resolve(preferences.terminalFontId),
                ),
                "terminalFontSize" to CanonicalCrossDeviceJson.JsonValue.Number(preferences.terminalTextSizeSp.toLong()),
                "terminalThemeID" to CanonicalCrossDeviceJson.JsonValue.String("default"),
            ))),
            "hosts" to CanonicalCrossDeviceJson.JsonValue.Array(hostItems),
            "identities" to CanonicalCrossDeviceJson.JsonValue.Array(emptyList()), "jumpChains" to CanonicalCrossDeviceJson.JsonValue.Array(jumpLinks), "knownHosts" to CanonicalCrossDeviceJson.JsonValue.Array(knownHostItems),
            "settings" to CanonicalCrossDeviceJson.JsonValue.Raw(CanonicalCrossDeviceJson.objectValue(mapOf(
                "accessoryBarKeys" to CanonicalCrossDeviceJson.JsonValue.Array(listOf(CanonicalCrossDeviceJson.JsonValue.String("escape"))),
                "bellNotificationEnabled" to CanonicalCrossDeviceJson.JsonValue.Boolean(preferences.bellNotificationEnabled),
                "bellSoundEnabled" to CanonicalCrossDeviceJson.JsonValue.Boolean(preferences.bellSoundEnabled),
                "bellVisualEnabled" to CanonicalCrossDeviceJson.JsonValue.Boolean(preferences.bellVisualEnabled),
                "filesDefaultDestination" to CanonicalCrossDeviceJson.JsonValue.String("cwd"),
                "filesReaperDays" to CanonicalCrossDeviceJson.JsonValue.Number(30),
                "modifierBehavior" to CanonicalCrossDeviceJson.JsonValue.String("oneShot"),
                "scrollbackLines" to CanonicalCrossDeviceJson.JsonValue.Number(preferences.scrollbackLines.toLong()),
            ) + BootstrapAgentCenterSetting.exportFields(preferences.agentCenterEnabled, peerSupportsAgentCenterEnabled))),
            "version" to CanonicalCrossDeviceJson.JsonValue.Number(2),
        ))
    }

    private suspend fun allHostsInRouteOrder(): List<SavedHost> {
        val pending = hosts.observeHosts().first().associateByTo(linkedMapOf(), SavedHost::id)
        val ordered = mutableListOf<SavedHost>()
        val included = mutableSetOf<String>()
        while (pending.isNotEmpty()) {
            val ready = pending.values.filter { it.jumpHostId == null || it.jumpHostId in included }
            require(ready.isNotEmpty()) { "Saved hosts contain a cyclic or missing jump-host route" }
            ready.forEach { host ->
                ordered += host
                included += host.id
                pending.remove(host.id)
            }
        }
        return ordered
    }

    // Frozen BootstrapManifestV2 retains Apple's padded SHA-256 spelling.
    // DevicePublicKeyV2 and Android's local trust store remain unpadded.
    private fun bootstrapFingerprint(blob: ByteArray): String =
        "SHA256:" + Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(blob), Base64.NO_WRAP)

    private fun manifestHostIds(manifest: String): Set<String> {
        val values = JSONObject(manifest).getJSONArray("hosts")
        return buildSet {
            for (index in 0 until values.length()) {
                add(UUID.fromString(values.getJSONObject(index).getString("id")).toString())
            }
        }
    }

    private fun manifestSummaries(manifest: JSONObject): List<PairingHostSummary> {
        val values = manifest.getJSONArray("hosts")
        return buildList {
            for (index in 0 until values.length()) {
                val host = values.getJSONObject(index)
                add(
                    PairingHostSummary(
                        id = UUID.fromString(host.getString("id")).toString(),
                        name = host.getString("name"),
                        endpoint = "${host.getString("user")}@${host.getString("address")}:${host.getInt("port")}",
                    ),
                )
            }
        }
    }

    /**
     * Scanned or pasted text becomes an offer through the shared QR codec.
     *
     * Swift authority:
     * `Packages/TesseraCore/Sources/TesseraPairingCore/PairingQRTextCodecV1.swift`,
     * reached through `SharedPairingQR`. Its strictness arrives with it: the
     * strict base64url alphabet, and a canonical round-trip that refuses a
     * re-spelled offer instead of normalizing it. The returned `offerBytes`
     * are the canonical encoding, so everything below reads a payload the
     * core has already validated.
     *
     * The four [SharedPairingQrRejection] reasons are only the text codec's
     * refusals. The core also decodes the offer itself, and an offer that is
     * well-formed base64url but not a supported offer — an unknown version,
     * say — comes back through the bridge as a plain argument failure
     * carrying an internal message. That message is not something to show a
     * user, so it becomes the same generic answer the pairing screen already
     * gives. `UnsatisfiedLinkError` is an `Error`, not an exception, and
     * deliberately keeps propagating: a missing core is not a bad QR code.
     */
    private fun decodeOffer(qrText: String): SharedPairingOffer {
        require(qrText.isNotEmpty()) { "This is not a Tessera pairing QR code." }
        val outcome = try {
            SharedPairingQR.decodeOffer(qrText)
        } catch (rejected: IllegalArgumentException) {
            throw IllegalArgumentException(UNUSABLE_PAIRING_CODE, rejected)
        } catch (rejected: IllegalStateException) {
            throw IllegalArgumentException(UNUSABLE_PAIRING_CODE, rejected)
        }
        return when (outcome) {
            is SharedPairingQrDecode.Decoded -> outcome.offer
            is SharedPairingQrDecode.Rejected -> throw IllegalArgumentException(
                when (outcome.reason) {
                    SharedPairingQrRejection.InvalidFormat ->
                        "This is not a Tessera pairing QR code."
                    SharedPairingQrRejection.InvalidBase64Url ->
                        "This pairing code is damaged. Show the code again and rescan it."
                    SharedPairingQrRejection.TooLarge ->
                        "This pairing code is too large to be a Tessera offer."
                    SharedPairingQrRejection.NonCanonical ->
                        "This pairing code was re-encoded on the way here. Scan the original."
                },
            )
        }
    }

    /** The offer's wire purpose as this adapter's presentation enum. */
    private fun SharedPairingOffer.pairingPurpose(): PairingPurpose =
        PairingPurpose.entries.firstOrNull { it.wire == purpose } ?: error("Unsupported pairing purpose")

    /**
     * The locally dialable endpoints inside an already-validated offer.
     *
     * Creating the TCP client is the only adapter concern here: the core has
     * bounded the candidate list and checked every host and port, so nothing
     * is re-validated. Only the absence of a usable candidate is an adapter
     * failure, because only this side knows it has no other way to connect.
     */
    private fun tcpEndpointCandidates(offer: SharedPairingOffer): List<PairingTcpRendezvous.Endpoint> {
        val candidates = JSONObject(offer.offerBytes.decodeToString()).getJSONArray("endpointCandidates")
        return buildList {
            for (index in 0 until candidates.length()) {
                val candidate = candidates.getJSONObject(index)
                if (candidate.optString("transport") == "tcp") {
                    add(PairingTcpRendezvous.Endpoint(candidate.getString("host"), candidate.getInt("port")))
                }
            }
        }.also { require(it.isNotEmpty()) { "No supported TCP endpoint candidates" } }
    }

    private fun JSONObject.payloadBytes(): ByteArray = Base64.decode(getString("payload"), Base64.NO_WRAP)
    private fun JSONObject.payloadObject(): JSONObject = JSONObject(payloadBytes().decodeToString())
    private fun JSONObject.attemptId(): String = optString("attemptID", "${generation}")

    private companion object {
        const val OFFER_LIFETIME_SECONDS = 10 * 60L
        const val OWNER_AUTHORIZATION_MILLISECONDS = 10_000L

        /**
         * The generic answer for a code this device cannot use, worded exactly
         * as the pairing screen's own fallback so a scan never differs in
         * voice depending on which layer refused it.
         */
        const val UNUSABLE_PAIRING_CODE = "Invalid, expired, or unsupported Tessera pairing code."
    }

    private sealed interface PendingOwnerAction {
        val attemptId: String
        val sourcePolicyFingerprint: String
        val sourceHostIds: Set<String>?
        data class Bootstrap(
            override val attemptId: String,
            val manifest: String,
            override val sourcePolicyFingerprint: String,
            override val sourceHostIds: Set<String>,
        ) : PendingOwnerAction
        data class Enrollment(
            override val attemptId: String,
            val routeIdentity: String,
            override val sourcePolicyFingerprint: String,
        ) : PendingOwnerAction {
            override val sourceHostIds: Set<String>? = null
        }
    }

    private data class GeneratedIdentity(
        val alias: String,
        val displayName: String,
        val fingerprint: String,
        val stored: StoredKeystoreCredential,
        val savedIdentityId: String?,
    )

    private class PairingGrantException(val code: String) : IllegalStateException(code)
}

private fun SavedHost.asDraft(identityId: String? = this.identityId) = HostDraft(
    id = id, displayName = displayName, hostname = hostname, port = port, username = username,
    jumpHostId = jumpHostId, identityId = identityId, transportKind = transportKind,
    tmuxMode = tmuxMode, tmuxTarget = tmuxTarget,
    launchCommand = launchCommand, notes = notes, envVars = envVars, startupSnippet = startupSnippet,
)

private fun SavedHost.matchesImportedHost(draft: HostDraft): Boolean =
    hostname == draft.hostname && port == draft.port && username == draft.username &&
        jumpHostId == draft.jumpHostId && transportKind == draft.transportKind &&
        tmuxMode == draft.tmuxMode && tmuxTarget == draft.tmuxTarget

private fun SavedHost.launchMode(): String = when (tmuxMode) {
    TmuxModes.AUTOMATIC -> "autoTmux"
    TmuxModes.PINNED -> "pinnedTmux"
    else -> "customCommand"
}

internal fun SavedHost.tmuxSession(): String? = when (tmuxMode) {
    TmuxModes.AUTOMATIC -> SharedAutomaticTmuxTarget.sessionName(username, hostname, port)
    TmuxModes.PINNED -> tmuxTarget
    else -> null
}

private fun String.wireTransport(): String = if (this == TransportKinds.MOSH) "mosh" else "ssh"

/**
 * One hop of a route in the shape the shared identity expects.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraProtocolCore/ContinuationRouteIdentity.swift`.
 */
private fun SavedHost.continuationEndpoint(): SharedContinuationEndpoint = SharedContinuationEndpoint(
    hostId = CanonicalCrossDeviceJson.uuid(UUID.fromString(id)),
    name = displayName,
    user = username,
    address = hostname,
    port = port,
    transport = if (transportKind == TransportKinds.MOSH) {
        SharedContinuationTransport.Mosh
    } else {
        SharedContinuationTransport.Ssh
    },
)

/**
 * `transport:user@address:port[&via=…]` — the route's stable name, and the
 * field the peer's descriptor must reproduce exactly.
 */
internal fun connectionKey(host: SavedHost, via: List<SavedHost>): String =
    SharedContinuationIdentity.routeIdentity(
        host.continuationEndpoint(),
        via.map { it.continuationEndpoint() },
    ).connectionKey

/**
 * `routeKey#fingerprint`: what a recovery record stores, so an interrupted
 * continuation can be recognised after process death without persisting a
 * second plaintext copy of the route. Neither half names a transport: the
 * sender and the receiver may reach the same route over different transports,
 * and the record must still match.
 *
 * The shared rendering length-prefixes each field in UTF-8 bytes; the local
 * implementation this replaces counted UTF-16 code units. A recovery record
 * staged before the change and holding a non-ASCII field therefore stops
 * matching and simply retires early — the interrupted attempt is not offered
 * for resume, which is the same outcome as a changed route.
 */
internal fun continuationRouteIdentity(host: SavedHost, via: List<SavedHost>): String =
    SharedContinuationIdentity.routeIdentity(
        host.continuationEndpoint(),
        via.map { it.continuationEndpoint() },
    ).identity

/**
 * The same identity derived from a received descriptor. It agrees byte for
 * byte with [continuationRouteIdentity] for the same route — that agreement is
 * why both go through one implementation.
 */
private fun descriptorRouteIdentity(descriptor: JSONObject): String =
    SharedContinuationIdentity.descriptorRouteIdentity(descriptor.toString().encodeToByteArray())

private fun JSONObject.optNullableString(name: String): String? =
    if (!has(name) || isNull(name)) null else getString(name)

/** Reads the authenticated owner-authorization payload used by the coordinator. */
internal fun bootstrapPeerSupportsAgentCenterEnabled(payload: JSONObject): Boolean =
    SharedBootstrapTransactionVersions.supportsAgentCenterEnabled(payload.optInt("transactionVersion", 1))
