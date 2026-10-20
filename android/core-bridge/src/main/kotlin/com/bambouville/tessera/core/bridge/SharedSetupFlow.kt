package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject

/** Native views consume semantics from Swift, not a second Kotlin state machine. */
object SharedSetupFlow {
    enum class Phase {
        entry, connecting, compareCode, waitingForPeerCode, preparingKey, choosing,
        waitingForSelection, reviewingImport, authorizing, transferring, importing,
        waitingForGrant, granting, recordingAccess, awaitingConnection, completed, failed, rejecting,
    }
    enum class Stage { scan, discover, verify, choose, transfer, connect }
    enum class Action { cancel, confirmCode, rejectCode, approve, importSetup, retry, done, configureLater }
    enum class Outcome { configurationCopied, authorized, alreadyAuthorized, passwordNeeded, failed, skipped,
        notSelected, notImported, excluded, uncertain }
    enum class Access { unknown, installed, alreadyInstalled, failed, skipped, notSelected, excluded, uncertain }
    enum class FailureReason { expired, codeMismatch, disconnected, locked, policyChanged, protocolError, other }
    data class Selection(
        val allHostIds: Set<String>, val selectedHostIds: Set<String>, val grantEligibleHostIds: Set<String>,
        val jumpParents: Map<String, String> = emptyMap(), val mode: String = "copy",
    )
    data class HostFact(val id: String, val access: Access, val accepted: Boolean? = null, val passwordNeeded: Boolean = false)
    data class Output(
        val stages: List<Stage>, val currentStage: Stage, val status: Phase,
        val copiedHostIds: Set<String>, val grantedHostIds: Set<String>, val requiredRouteHostIds: Set<String>,
        val unavailableActions: Map<Action, String?>, val hosts: Map<String, Outcome>,
        val failureReason: FailureReason?,
    ) {
        fun allows(action: Action) = unavailableActions.containsKey(action) && unavailableActions[action] == null
    }
    fun project(
        purpose: String, phase: Phase, actions: List<Action> = emptyList(),
        selection: Selection? = null, hosts: List<HostFact> = emptyList(), stoppedAt: Stage? = null,
        failureCode: String? = null,
    ): Output {
        val input = JSONObject().put("purpose", purpose).put("entry", "qr").put("phase", phase.name)
            .put("supportedActions", JSONArray(actions.map { it.name }))
            .put("hosts", JSONArray(hosts.map { host ->
                JSONObject().put("id", host.id).put("access", host.access.name).put("passwordNeeded", host.passwordNeeded)
                    .apply { host.accepted?.let { put("wasAccepted", it) } }
            }))
        stoppedAt?.let { input.put("stoppedAt", it.name) }
        failureCode?.let { input.put("failureCode", it) }
        selection?.let {
            input.put("selection", JSONObject().put("mode", it.mode).put("allHostIDs", JSONArray(it.allHostIds.toList()))
                .put("selectedHostIDs", JSONArray(it.selectedHostIds.toList()))
                .put("grantEligibleHostIDs", JSONArray(it.grantEligibleHostIds.toList()))
                .put("jumpLinks", JSONArray(it.jumpParents.map { (host, jump) ->
                    JSONObject().put("hostID", host).put("jumpHostID", jump)
                })))
        }
        NativeLibraries.ensureLoaded()
        val bytes = input.toString().encodeToByteArray()
        val value = JSONObject(NativeCoreBindings.setupFlowProject(bytes.toDirectBuffer(), bytes.size))
        fun strings(key: String): List<String> = value.getJSONArray(key).let { list -> List(list.length()) { list.getString(it) } }
        val actionValues = value.getJSONArray("actions")
        val hostValues = value.getJSONArray("hosts")
        return Output(strings("stages").map(Stage::valueOf), Stage.valueOf(value.getString("currentStage")),
            Phase.valueOf(value.getString("status")), strings("copiedHostIDs").map(String::lowercase).toSet(),
            strings("grantedHostIDs").map(String::lowercase).toSet(), strings("requiredRouteHostIDs").map(String::lowercase).toSet(),
            (0 until actionValues.length()).associate { index -> actionValues.getJSONObject(index).let {
                Action.valueOf(it.getString("action")) to if (it.has("unavailableReason")) it.getString("unavailableReason") else null
            } },
            (0 until hostValues.length()).associate { index -> hostValues.getJSONObject(index).let {
                it.getString("id").lowercase() to Outcome.valueOf(it.getString("outcome"))
            } }, value.optString("failureReason").takeIf { it.isNotEmpty() }?.let(FailureReason::valueOf))
    }
}
