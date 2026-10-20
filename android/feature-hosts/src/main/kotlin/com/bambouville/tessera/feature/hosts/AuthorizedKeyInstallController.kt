package com.bambouville.tessera.feature.hosts

import android.util.Base64
import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.HostRepository
import com.bambouville.tessera.data.HostTrustEvaluation
import com.bambouville.tessera.data.IdentityRepository
import com.bambouville.tessera.data.KnownHostKeys
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.SavedIdentity
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshHostKeyObservation
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

sealed interface AuthorizedKeyInstallState {
    data object Idle : AuthorizedKeyInstallState
    data object Connecting : AuthorizedKeyInstallState
    data class AwaitingPassword(val hop: SshRouteHop) : AuthorizedKeyInstallState
    data class AwaitingHostKey(
        val observation: SshHostKeyObservation,
        val fingerprint: String,
        val changed: Boolean,
        val reverted: Boolean,
        val previousFingerprint: String?,
    ) : AuthorizedKeyInstallState
    data class AwaitingOwnerAuthorization(val hop: SshRouteHop, val requestId: UUID) : AuthorizedKeyInstallState
    data object Installing : AuthorizedKeyInstallState
    data object Succeeded : AuthorizedKeyInstallState
    data class Failed(val message: String) : AuthorizedKeyInstallState
}

class AuthorizedKeyInstallController(
    private val hosts: HostRepository,
    private val identities: IdentityRepository,
    private val knownHosts: KnownHostsRepository,
    private val credentialStore: AndroidKeystoreCredentialStore,
    private val scope: CoroutineScope,
    private val backend: AndroidSshBackend = AndroidSshBackend(),
) {
    private val mutableState = MutableStateFlow<AuthorizedKeyInstallState>(AuthorizedKeyInstallState.Idle)
    val state: StateFlow<AuthorizedKeyInstallState> = mutableState.asStateFlow()
    private var job: Job? = null
    private var passwordDecision: CompletableDeferred<CharArray>? = null
    private var hostKeyDecision: CompletableDeferred<Boolean>? = null
    private var ownerDecision: CompletableDeferred<Boolean>? = null

    fun install(target: SavedHost, identity: SavedIdentity) {
        if (job?.isActive == true) return
        job = scope.launch {
            try {
                mutableState.value = AuthorizedKeyInstallState.Connecting
                val route = hosts.resolveRoute(target.id).map { host ->
                    val savedIdentity = host.identityId?.let { identities.identity(it) }
                    SshRouteHop(
                        id = host.id,
                        endpoint = SshEndpoint(host.hostname, host.port),
                        username = host.username,
                        authentication = savedIdentity?.let {
                            SshAuthentication.AndroidKeystoreP256(it.credentialReference)
                        } ?: SshAuthentication.Password,
                    )
                }
                val credential = withContext(Dispatchers.IO) {
                    credentialStore.load(identity.credentialReference)
                }
                val publicKey = "ecdsa-sha2-nistp256 ${Base64.encodeToString(credential.publicKeyBlob, Base64.NO_WRAP)} " +
                    identity.displayName.installComment()
                val connection = backend.connectRoute(
                    request = SshRouteRequest(route),
                    passwordProvider = SshPasswordProvider(::requestPassword),
                    hostKeyPolicy = SshHostKeyPolicy(::verifyHostKey),
                    keyAuthorizationProvider = SshKeyAuthorizationProvider(::requestOwnerAuthorization),
                )
                connection.use {
                    mutableState.value = AuthorizedKeyInstallState.Installing
                    val quoted = publicKey.replace("'", "'\\''")
                    val markerSuffix = UUID.randomUUID().toString().replace("-", "")
                    val marker = "TESSERA_KEY_INSTALLED_$markerSuffix"
                    // The success marker is emitted in two pieces so an echoing PTY cannot make
                    // the source command itself look like a successful verification.
                    val command = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; " +
                        "line='$quoted'; grep -Fqx -- \"${'$'}line\" ~/.ssh/authorized_keys || printf '%s\\n' \"${'$'}line\" >> ~/.ssh/authorized_keys; " +
                        "chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; grep -Fqx -- \"${'$'}line\" ~/.ssh/authorized_keys && " +
                        "printf 'TESSERA_KEY_'; printf 'INSTALLED_$markerSuffix\\n'; exit"
                    connection.write((command + "\n").encodeToByteArray())
                    val output = withTimeout(45_000L) {
                        withContext(Dispatchers.IO) { connection.standardOutput.bufferedReader().readText() }
                    }
                    check(marker in output) { "The host did not confirm the public-key installation" }
                }
                hosts.save(
                    HostDraft(
                        id = target.id,
                        displayName = target.displayName,
                        hostname = target.hostname,
                        port = target.port,
                        username = target.username,
                        jumpHostId = target.jumpHostId,
                        identityId = identity.id,
                        transportKind = target.transportKind,
                        tmuxMode = target.tmuxMode,
                        tmuxTarget = target.tmuxTarget,
                        launchCommand = target.launchCommand, notes = target.notes,
                        envVars = target.envVars, startupSnippet = target.startupSnippet,
                    ),
                )
                mutableState.value = AuthorizedKeyInstallState.Succeeded
            } catch (_: CancellationException) {
                mutableState.value = AuthorizedKeyInstallState.Idle
            } catch (failure: Throwable) {
                mutableState.value = AuthorizedKeyInstallState.Failed(
                    failure.message?.take(240) ?: failure::class.java.simpleName,
                )
            } finally {
                passwordDecision = null
                hostKeyDecision = null
                ownerDecision = null
            }
        }
    }

    fun submitPassword(password: String) {
        if (password.isNotEmpty()) passwordDecision?.complete(password.toCharArray())
    }

    fun decideHostKey(accept: Boolean) {
        hostKeyDecision?.complete(accept)
    }

    fun decideOwnerAuthorization(accept: Boolean) {
        ownerDecision?.complete(accept)
    }

    fun cancel() {
        passwordDecision?.completeExceptionally(CancellationException())
        hostKeyDecision?.complete(false)
        ownerDecision?.complete(false)
        job?.cancel()
        job = null
        mutableState.value = AuthorizedKeyInstallState.Idle
    }

    private suspend fun requestPassword(hop: SshRouteHop): CharArray {
        val decision = CompletableDeferred<CharArray>()
        passwordDecision = decision
        mutableState.value = AuthorizedKeyInstallState.AwaitingPassword(hop)
        return decision.await().also {
            passwordDecision = null
            mutableState.value = AuthorizedKeyInstallState.Connecting
        }
    }

    private suspend fun verifyHostKey(observation: SshHostKeyObservation): Boolean {
        val evaluation = knownHosts.evaluate(
            observation.host,
            observation.port,
            observation.algorithm,
            observation.canonicalKeyBlob,
        )
        if (evaluation == HostTrustEvaluation.Trusted) return true
        val decision = CompletableDeferred<Boolean>()
        hostKeyDecision = decision
        mutableState.value = AuthorizedKeyInstallState.AwaitingHostKey(
            observation = observation,
            fingerprint = observation.canonicalKeyBlob.fingerprint(),
            changed = evaluation is HostTrustEvaluation.Changed,
            reverted = evaluation is HostTrustEvaluation.Reverted,
            previousFingerprint = when (evaluation) {
                is HostTrustEvaluation.Changed -> evaluation.previousCanonicalKeyBlob.fingerprint()
                is HostTrustEvaluation.Reverted -> evaluation.currentCanonicalKeyBlob.fingerprint()
                else -> null
            },
        )
        val accepted = decision.await()
        hostKeyDecision = null
        if (accepted) {
            knownHosts.trust(
                observation.host,
                observation.port,
                observation.algorithm,
                observation.canonicalKeyBlob,
            )
            mutableState.value = AuthorizedKeyInstallState.Connecting
        }
        return accepted
    }

    private suspend fun requestOwnerAuthorization(hop: SshRouteHop) {
        val authentication = hop.authentication as? SshAuthentication.AndroidKeystoreP256 ?: return
        val credential = withContext(Dispatchers.IO) { credentialStore.load(authentication.alias) }
        if (!credential.capabilities.ownerAuthenticationRequired) return
        val decision = CompletableDeferred<Boolean>()
        ownerDecision = decision
        mutableState.value = AuthorizedKeyInstallState.AwaitingOwnerAuthorization(hop, UUID.randomUUID())
        if (!decision.await()) throw CancellationException("Device authentication cancelled")
        ownerDecision = null
        mutableState.value = AuthorizedKeyInstallState.Connecting
    }
}

/**
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraTrustCore/HostKeyFingerprint.swift`
 * (`SSHHostPublicKey.sha256Fingerprint`) via `KnownHostKeys`.
 */
private fun ByteArray.fingerprint(): String = KnownHostKeys.fingerprint(this)

private fun String.installComment(): String =
    trim().replace(Regex("\\s+"), "-").filter { it.code in 33..126 && it != '\'' }.take(64)
        .ifEmpty { "tessera-android" }
