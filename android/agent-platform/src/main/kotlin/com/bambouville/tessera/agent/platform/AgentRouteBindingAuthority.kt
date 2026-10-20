package com.bambouville.tessera.agent.platform

import com.bambouville.tessera.core.bridge.SharedAgentRuntime
import com.bambouville.tessera.core.bridge.CoordinatorOnlyAgentRouteAuthority
import org.json.JSONArray
import org.json.JSONObject

/**
 * The only Android path that can exchange route/process facts for Agent ABI
 * authority. It asks the live endpoint to prove a PID itself; presentation
 * code cannot pass process IDs or manufacture a proof handle.
 *
 * A proof handle is deliberately consumed immediately by the binding exchange.
 * The returned token is scoped to this runtime and exact route binding.
 */
@OptIn(CoordinatorOnlyAgentRouteAuthority::class)
internal class AgentRouteBindingAuthority(
    private val runtime: SharedAgentRuntime,
) {
    suspend fun issue(
        endpoint: AgentSessionEndpoint,
        threadID: JSONObject,
        binding: AgentEndpointBinding,
        claimedPID: Int?,
        hostObservation: Boolean = false,
    ): AgentEndpointResult<AgentIssuedBinding> {
        if (hostObservation && claimedPID != null) return AgentEndpointResult.Failed("observation_cannot_prove_process")
        fun current() = if (hostObservation) endpoint.isCurrentIngestion(binding) else endpoint.isCurrentRoute(binding)
        if (!current()) return AgentEndpointResult.StaleBinding
        val expectedProvider = threadID.optJSONObject("providerID")?.optString("rawValue")
            ?.let(AgentProofProvider::fromWire)
        // A lifecycle identity with an unknown provider is useful only as
        // observe-only discovery. It must never ask a lower layer to certify a
        // process under an attacker-chosen executable class.
        if (claimedPID != null && expectedProvider == null) return AgentEndpointResult.Failed("invalid_provider")
        val proof = claimedPID?.let { endpoint.proveProcess(binding, it, checkNotNull(expectedProvider)) }
        if (proof is AgentEndpointResult.StaleBinding) return proof
        if (proof is AgentEndpointResult.Unavailable) return proof
        if (proof is AgentEndpointResult.Failed) return proof
        val proven = (proof as? AgentEndpointResult.Success)?.value
        val provenIDs = proven?.processIDs.orEmpty()
        val actionable = claimedPID != null && expectedProvider != null &&
            proven?.provider == expectedProvider && claimedPID in provenIDs
        val coreBinding = if (actionable) {
            binding.actionableCoreBinding(claimedPID, endpoint.capabilities.value)
        } else {
            // No independently fresh process proof means discovery only. Never
            // self-attest the PID carried by an OSC lifecycle frame.
            binding.observeOnlyCoreBinding()
        }
        val directories = if (actionable) {
            when (val result = endpoint.validatedDirectories(binding)) {
                is AgentEndpointResult.Success -> result.value.filter(::validProvenDirectory)
                AgentEndpointResult.StaleBinding -> return AgentEndpointResult.StaleBinding
                is AgentEndpointResult.Unavailable -> emptyList()
                is AgentEndpointResult.Failed -> emptyList()
            }
        } else emptyList()
        // Re-check the carrier after every potentially remote proof operation.
        if (!current()) return AgentEndpointResult.StaleBinding
        val sourceIdentity = binding.sourceIdentity()
        val proofHandle = runtime.issuePlatformRouteProof(
            JSONObject()
                .put("threadID", threadID)
                .put("hostID", binding.hostID)
                .put("binding", coreBinding)
                .put("sourceIdentity", sourceIdentity)
                .put("processIDs", JSONArray(if (actionable) provenIDs.sorted() else emptyList<Int>()))
                .put("validatedDirectories", JSONArray(if (actionable) directories else emptyList<String>())),
        ) ?: return AgentEndpointResult.Failed("platform_proof_rejected")
        val mode = if (actionable) "actionable" else if (hostObservation) "inventoryObservation" else "observeOnly"
        val token = runtime.exchangePlatformRouteProof(
            JSONObject()
                .put("threadID", threadID)
                .put("hostID", binding.hostID)
                .put("binding", coreBinding)
                .put("sourceIdentity", sourceIdentity)
                .put("validatedDirectories", JSONArray(if (actionable) directories else emptyList<String>()))
                .put("mode", mode)
                .put("proofHandle", proofHandle),
        ) ?: return AgentEndpointResult.Failed("platform_binding_rejected")
        return AgentEndpointResult.Success(
            AgentIssuedBinding(
                coreBinding = coreBinding,
                bindingToken = token,
                actionable = actionable,
                provenDirectories = directories,
                processStart = proven?.processStart.takeIf { actionable },
            ),
        )
    }
}

/** Opaque output of the route authority; it has no caller-supplied UUID or PID field. */
@ConsistentCopyVisibility
data class AgentIssuedBinding internal constructor(
    val coreBinding: JSONObject,
    val bindingToken: String,
    val actionable: Boolean,
    val provenDirectories: List<String>,
    /** Immutable identity to compare against uncached pre-write process probes. */
    val processStart: String? = null,
)

internal fun AgentEndpointBinding.sourceIdentity(): String =
    "android:${key.liveSessionID}:${key.carrierGeneration}:${paneID ?: "raw"}"

internal fun AgentEndpointBinding.observeOnlyCoreBinding(): JSONObject {
    val raw = 1 // AgentTerminalCapabilities.observe
    return coreBinding(capabilities = raw, agentPID = null)
}

internal fun AgentEndpointBinding.actionableCoreBinding(
    agentPID: Int,
    endpoint: AgentEndpointCapabilities,
): JSONObject {
    var raw = 1 // observe
    if (endpoint.verifiedInput && endpoint.semanticKeys) raw = raw or 2 or 4 // send + interrupt
    if (endpoint.verifiedInput && endpoint.freshTerminalObservation) raw = raw or 8 // prompt answer
    if (transport in setOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX) &&
        endpoint.acknowledgedTmuxPlacement
    ) raw = raw or 16
    return coreBinding(capabilities = raw, agentPID = agentPID)
}

internal fun AgentEndpointBinding.candidateCoreBinding(agentPID: Int): JSONObject =
    coreBinding(capabilities = 1, agentPID = agentPID)

private fun AgentEndpointBinding.coreBinding(capabilities: Int, agentPID: Int?): JSONObject = JSONObject()
    .put("liveSessionID", key.liveSessionID)
    .put("carrierGeneration", key.carrierGeneration)
    .put("incarnation", JSONObject().put("rawValue", "${key.liveSessionID}:${key.carrierGeneration}${agentPID?.let { ":$it" }.orEmpty()}"))
    .put("transport", when (transport) {
        AgentEndpointTransport.SSH -> "ssh"
        AgentEndpointTransport.SSH_TMUX -> "sshTmux"
        AgentEndpointTransport.MOSH -> "mosh"
        AgentEndpointTransport.MOSH_TMUX -> "moshTmux"
    })
    .putOpt("tmuxSession", tmuxSession).putOpt("windowID", windowID).putOpt("paneID", paneID)
    .putOpt("agentPID", agentPID)
    // A bare number, not {"rawValue": n}. `AgentTerminalCapabilities` is a
    // Swift OptionSet, so it takes RawRepresentable's Codable conformance and
    // crosses the ABI as the raw integer alone. `incarnation` and `providerID`
    // one line up look identical in Kotlin but declare explicit CodingKeys, so
    // those really are wrapped. Wrapping this one made every platform proof,
    // binding and Tier-A candidate registration fail to decode, which the C
    // ABI reports as the same -1 it uses for a policy refusal.
    .put("capabilities", capabilities)

private fun validProvenDirectory(path: String): Boolean =
    (path.startsWith("/") || path.startsWith("~/")) &&
        !path.contains("..") && path.encodeToByteArray().size <= 2_048
