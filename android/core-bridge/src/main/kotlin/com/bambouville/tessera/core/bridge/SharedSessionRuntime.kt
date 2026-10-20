package com.bambouville.tessera.core.bridge

import android.util.Base64
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

/** Kotlin projection of the versioned TesseraSessionCore C-ABI contract. */
class SharedSessionRuntime private constructor(
    private val runtime: CoreRuntime,
    private val listener: SharedSessionListener,
) : AutoCloseable {
    private val generation = AtomicLong(1)
    private val pending = ConcurrentHashMap<String, ConcurrentLinkedQueue<SharedBackendCommand>>()
    private val tmuxSnapshotRepublishGate = TmuxSnapshotRepublishGate()

    @Volatile private var sessionId: UUID? = null
    @Volatile private var closed = false

    fun connect(intent: SharedConnectionIntent): CoreCallResult = submit(
        command = SharedBackendCommand.Connect(intent),
        json = JSONObject()
            .put("v", COMMAND_ABI_VERSION)
            .put("kind", "connect")
            .put("requestID", intent.requestId.toString())
            .put("hostID", intent.hostId.toString())
            .put("policyGeneration", intent.policyGeneration),
    )

    fun cancelConnect(attemptId: UUID): CoreCallResult = submit(
        command = SharedBackendCommand.CancelConnect(attemptId),
        json = JSONObject()
            .put("v", COMMAND_ABI_VERSION)
            .put("kind", "cancelConnect")
            .put("requestID", attemptId.toString()),
    )

    fun disconnect(): CoreCallResult = submit(
        command = SharedBackendCommand.Disconnect,
        json = command("disconnect"),
    )

    fun sendInput(bytes: ByteArray): CoreCallResult {
        require(bytes.isNotEmpty())
        return submit(
            command = SharedBackendCommand.SendInput(bytes.copyOf()),
            json = command("sendInput").put("bytes", bytes.base64()),
        )
    }

    fun resize(columns: Int, rows: Int): CoreCallResult {
        require(columns > 0 && rows > 0)
        return submit(
            command = SharedBackendCommand.Resize(columns, rows),
            json = command("resize").put("columns", columns).put("rows", rows),
        )
    }

    fun setFocused(focused: Boolean): CoreCallResult = submit(
        command = SharedBackendCommand.SetFocused(focused),
        json = command("setFocused").put("flag", focused),
    )

    fun setVisibility(visibility: SharedSessionVisibility): CoreCallResult = submit(
        command = SharedBackendCommand.SetVisibility(visibility),
        json = command("setApplicationVisibility").put("visibility", visibility.wireValue),
    )

    fun requestFullRepaint(): CoreCallResult = submit(
        command = SharedBackendCommand.RequestFullRepaint,
        json = command("requestFullRepaint"),
    )

    fun submitChallengeResponse(
        challengeId: UUID,
        attemptId: UUID,
        policyGeneration: Long,
        decision: SharedChallengeDecision,
    ): CoreCallResult = submit(
        command = SharedBackendCommand.SubmitChallengeResponse(
            challengeId = challengeId,
            attemptId = attemptId,
            policyGeneration = policyGeneration,
            decision = decision,
        ),
        json = command("submitChallengeResponse")
            .put("challengeID", challengeId.toString())
            .put("requestID", attemptId.toString())
            .put("policyGeneration", policyGeneration)
            .put("decision", decision.wireValue),
    )

    fun selectTmuxWindow(id: String): CoreCallResult = tmuxTarget("selectTmuxWindow", id) {
        SharedBackendCommand.SelectTmuxWindow(it)
    }

    fun selectTmuxPane(id: String): CoreCallResult = tmuxTarget("selectTmuxPane", id) {
        SharedBackendCommand.SelectTmuxPane(it)
    }

    fun sendTmuxPaneInput(
        paneId: String,
        bytes: ByteArray,
        receipt: SharedSessionCommandReceipt? = null,
    ): CoreCallResult {
        require(bytes.isNotEmpty())
        return submit(
            command = SharedBackendCommand.SendTmuxPaneInput(paneId, bytes.copyOf(), receipt),
            json = command("sendTmuxPaneInput")
                .put("targetID", paneId)
                .put("bytes", bytes.base64())
                .putOptionalReceipt(receipt),
        )
    }

    fun sendTmuxPaneKey(
        paneId: String,
        key: SharedTmuxPaneKey,
        receipt: SharedSessionCommandReceipt? = null,
    ): CoreCallResult = submit(
        command = SharedBackendCommand.SendTmuxPaneKey(paneId, key, receipt),
        json = command("sendTmuxPaneKey")
            .put("targetID", paneId)
            .put("paneKey", key.wireValue)
            .putOptionalReceipt(receipt),
    )

    fun createTmuxWindow(): CoreCallResult = submit(
        command = SharedBackendCommand.CreateTmuxWindow,
        json = command("createTmuxWindow"),
    )

    fun closeTmuxWindow(id: String): CoreCallResult = tmuxTarget("closeTmuxWindow", id) {
        SharedBackendCommand.CloseTmuxWindow(it)
    }

    fun closeTmuxPane(id: String): CoreCallResult = tmuxTarget("closeTmuxPane", id) {
        SharedBackendCommand.CloseTmuxPane(it)
    }

    /// `before` is tmux's `-b`: the new pane goes left of a horizontal split
    /// or above a vertical one. It rides the record's spare `flag`, which an
    /// older peer omits and the shared core then reads as append — the only
    /// placement that existed before.
    fun splitTmuxPane(
        id: String,
        axis: SharedTmuxSplitAxis,
        before: Boolean = false,
    ): CoreCallResult = submit(
        command = SharedBackendCommand.SplitTmuxPane(id, axis, before),
        json = command("splitTmuxPane")
            .put("targetID", id)
            .put("splitAxis", axis.wireValue)
            .put("flag", before),
    )

    fun cycleTmuxPane(forward: Boolean): CoreCallResult = submit(
        command = SharedBackendCommand.CycleTmuxPane(forward),
        json = command("cycleTmuxPane").put("flag", forward),
    )

    fun setTmuxPaneZoomed(id: String, zoomed: Boolean): CoreCallResult = submit(
        command = SharedBackendCommand.SetTmuxPaneZoomed(id, zoomed),
        json = command("setTmuxPaneZoomed").put("targetID", id).put("flag", zoomed),
    )

    fun moveTmuxWindow(id: String, destination: Int): CoreCallResult = submit(
        command = SharedBackendCommand.MoveTmuxWindow(id, destination),
        json = command("moveTmuxWindow").put("targetID", id)
            .put("windowMove", JSONObject().put("position", JSONObject().put("_0", destination))),
    )

    fun renumberTmuxWindows(): CoreCallResult = submit(
        command = SharedBackendCommand.RenumberTmuxWindows,
        json = command("renumberTmuxWindows"),
    )

    fun renameTmuxWindow(id: String, name: String): CoreCallResult = submit(
        command = SharedBackendCommand.RenameTmuxWindow(id, name),
        json = command("renameTmuxWindow").put("targetID", id).put("name", name),
    )

    fun setTmuxGridPresentation(presentation: SharedTmuxGridPresentation): CoreCallResult = submit(
        command = SharedBackendCommand.SetTmuxGridPresentation(presentation),
        json = command("setTmuxGridPresentation").put("gridPresentation", presentation.wireValue),
    )

    fun claimTmuxGridAuthority(
        reason: SharedTmuxGridAuthorityReason,
        repaintEvenIfSame: Boolean,
    ): CoreCallResult = submit(
        command = SharedBackendCommand.ClaimTmuxGridAuthority(reason, repaintEvenIfSame),
        json = command("claimTmuxGridAuthority")
            .put("gridAuthorityReason", reason.wireValue)
            .put("flag", repaintEvenIfSame),
    )

    fun reclaimTmuxGridAuthority(reason: SharedTmuxGridAuthorityReason): CoreCallResult = submit(
        command = SharedBackendCommand.ReclaimTmuxGridAuthority(reason),
        json = command("reclaimTmuxGridAuthority").put("gridAuthorityReason", reason.wireValue),
    )

    fun completeTmuxGridAuthorityRepaint(authorityGeneration: Long): CoreCallResult {
        require(authorityGeneration >= 0)
        return submit(
            command = SharedBackendCommand.CompleteTmuxGridAuthorityRepaint(authorityGeneration),
            json = command("completeTmuxGridAuthorityRepaint")
                .put("authorityGeneration", authorityGeneration),
        )
    }

    fun emitTransportConnected(intent: SharedConnectionIntent): CoreCallResult = emit(
        JSONObject()
            .put("version", BACKEND_EVENT_ABI_VERSION)
            .put("kind", "transportConnected")
            .put("attemptID", intent.requestId.toString())
            .put("policyGeneration", intent.policyGeneration),
    )

    fun emitTransportDisconnected(attemptId: UUID): CoreCallResult = emit(
        JSONObject()
            .put("version", BACKEND_EVENT_ABI_VERSION)
            .put("kind", "transportDisconnected")
            .put("attemptID", attemptId.toString()),
    )

    fun emitTerminalBytes(
        bytes: ByteArray,
        receipt: SharedTerminalOutputReceipt? = null,
        attemptId: UUID,
    ): CoreCallResult {
        require(bytes.isNotEmpty())
        return emit(
            JSONObject()
                .put("version", BACKEND_EVENT_ABI_VERSION)
                .put("kind", "terminalBytes")
                .put("generation", generation.get())
                .put("attemptID", attemptId.toString())
                .put("payload", bytes.base64())
                .apply {
                    if (receipt != null) put(
                        "arguments",
                        JSONObject()
                            .put("deliveryID", receipt.deliveryId.toString())
                            .apply {
                                receipt.repaintRequestId?.let {
                                    put("repaintRequestID", it.toString())
                                }
                            },
                    )
                },
        )
    }

    fun emitFailure(attemptId: UUID, code: String, arguments: Map<String, String> = emptyMap()): CoreCallResult =
        emit(
            JSONObject()
                .put("version", BACKEND_EVENT_ABI_VERSION)
                .put("kind", "failure")
                .put("attemptID", attemptId.toString())
                .put("code", code)
                .put("arguments", JSONObject(arguments)),
        )

    fun emitHostKeyChallenge(
        challengeId: UUID,
        attemptId: UUID,
        policyGeneration: Long,
        host: String,
        port: Int,
        fingerprint: String,
        hint: String?,
        lifetimeSeconds: Long = CHALLENGE_LIFETIME_SECONDS,
    ): CoreCallResult = emitChallenge(
        caseName = "hostKey",
        challengeId = challengeId,
        attemptId = attemptId,
        policyGeneration = policyGeneration,
        lifetimeSeconds = lifetimeSeconds,
    ) { context ->
        JSONObject()
            .put("context", context)
            .put("endpoint", JSONObject().put("host", host).put("port", port))
            .put("fingerprint", fingerprint)
            .apply { if (hint != null) put("hint", hint) }
    }

    fun emitCredentialChallenge(
        challengeId: UUID,
        attemptId: UUID,
        policyGeneration: Long,
        credentialId: UUID?,
        kind: String,
        lifetimeSeconds: Long = CHALLENGE_LIFETIME_SECONDS,
    ): CoreCallResult = emitChallenge(
        caseName = "credential",
        challengeId = challengeId,
        attemptId = attemptId,
        policyGeneration = policyGeneration,
        lifetimeSeconds = lifetimeSeconds,
    ) { context ->
        JSONObject()
            .put("context", context)
            .apply { if (credentialId != null) put("credentialID", credentialId.toString()) }
            .put("kind", kind)
    }

    fun emitOwnerAuthorizationChallenge(
        challengeId: UUID,
        attemptId: UUID,
        policyGeneration: Long,
        reasonCode: String,
        lifetimeSeconds: Long = CHALLENGE_LIFETIME_SECONDS,
    ): CoreCallResult = emitChallenge(
        caseName = "ownerAuthorization",
        challengeId = challengeId,
        attemptId = attemptId,
        policyGeneration = policyGeneration,
        lifetimeSeconds = lifetimeSeconds,
    ) { context -> JSONObject().put("context", context).put("reasonCode", reasonCode) }

    /**
     * Publish a tmux snapshot to the session core. The adapter calls this for
     * every tmux runtime event, and the runtime hands back the same
     * [SharedTmuxSnapshot.rawJson] instance while the snapshot is unchanged.
     * Re-sending it would base64 it here and make the core decode and
     * re-encode the whole topology for every `%output` line, to say nothing
     * new, so [TmuxSnapshotRepublishGate] drops the repeat.
     */
    fun emitTmuxSnapshot(snapshotJson: ByteArray): CoreCallResult = synchronized(tmuxSnapshotRepublishGate) {
        val currentGeneration = generation.get()
        if (!closed && tmuxSnapshotRepublishGate.isRepeat(snapshotJson, currentGeneration)) {
            return@synchronized CoreCallResult.Accepted
        }
        emit(
            JSONObject()
                .put("version", BACKEND_EVENT_ABI_VERSION)
                .put("kind", "tmuxSnapshotChanged")
                .put("generation", currentGeneration)
                .put("payload", snapshotJson.base64()),
        ).also { result ->
            tmuxSnapshotRepublishGate.record(snapshotJson, currentGeneration, result == CoreCallResult.Accepted)
        }
    }

    fun emitGridAuthorityChanged(snapshot: SharedTmuxGridAuthoritySnapshot): CoreCallResult = emit(
        JSONObject()
            .put("version", BACKEND_EVENT_ABI_VERSION)
            .put("kind", "gridAuthorityChanged")
            .put("generation", generation.get())
            .put("payload", snapshot.toJson().toString().encodeToByteArray().base64()),
    )

    fun emitRemoteWorkingDirectoryChanged(path: String?): CoreCallResult = emit(
        JSONObject()
            .put("version", BACKEND_EVENT_ABI_VERSION)
            .put("kind", "remoteWorkingDirectoryChanged")
            .put("generation", generation.get())
            .apply { if (path != null) put("arguments", JSONObject().put("path", path)) },
    )

    fun emitForwardingStateChanged(states: List<SharedForwardingState>): CoreCallResult = emit(
        JSONObject()
            .put("version", BACKEND_EVENT_ABI_VERSION)
            .put("kind", "forwardingStateChanged")
            .put("generation", generation.get())
            .put("payload", states.toJsonArray().toString().encodeToByteArray().base64()),
    )

    fun emitCommandCompleted(completion: SharedSessionCommandCompletion): CoreCallResult = emit(
        JSONObject()
            .put("version", BACKEND_EVENT_ABI_VERSION)
            .put("kind", "commandCompleted")
            .put("generation", generation.get())
            .put("payload", completion.toJson().toString().encodeToByteArray().base64()),
    )

    fun emitDiagnostics(code: String, values: Map<String, String> = emptyMap()): CoreCallResult = emit(
        JSONObject()
            .put("version", BACKEND_EVENT_ABI_VERSION)
            .put("kind", "diagnostics")
            .put("generation", generation.get())
            .put("code", code)
            .put("arguments", JSONObject(values)),
    )

    override fun close() {
        if (closed) return
        closed = true
        pending.clear()
        runtime.close()
    }

    private fun emitChallenge(
        caseName: String,
        challengeId: UUID,
        attemptId: UUID,
        policyGeneration: Long,
        lifetimeSeconds: Long = CHALLENGE_LIFETIME_SECONDS,
        body: (JSONObject) -> JSONObject,
    ): CoreCallResult {
        val owningSession = checkNotNull(sessionId) { "shared session id is unavailable" }
        val context = JSONObject()
            .put("challengeID", challengeId.toString())
            .put("sessionID", owningSession.toString())
            .put("attemptID", attemptId.toString())
            .put("policyGeneration", policyGeneration)
            // Foundation's default Date coding is seconds since 2001-01-01.
            .put("expiresAt", (Instant.now().plusSeconds(lifetimeSeconds).epochSecond - FOUNDATION_EPOCH_SECONDS).toDouble())
        val payload = JSONObject().put(caseName, body(context)).toString().encodeToByteArray()
        return emit(
            JSONObject()
                .put("version", BACKEND_EVENT_ABI_VERSION)
                .put("kind", "challenge")
                .put("generation", generation.get())
                .put("payload", payload.base64()),
        )
    }

    private fun tmuxTarget(
        kind: String,
        id: String,
        create: (String) -> SharedBackendCommand,
    ): CoreCallResult = submit(
        command = create(id),
        json = command(kind).put("targetID", id),
    )

    private fun command(kind: String): JSONObject = JSONObject()
        .put("v", COMMAND_ABI_VERSION)
        .put("kind", kind)

    private fun submit(command: SharedBackendCommand, json: JSONObject): CoreCallResult {
        if (closed) return CoreCallResult.StaleHandle
        val queue = pending.getOrPut(command.kindCode) { ConcurrentLinkedQueue() }
        queue.add(command)
        return runtime.send(json.toString().encodeToByteArray()).also { result ->
            if (result != CoreCallResult.Accepted) queue.remove(command)
        }
    }

    private fun emit(json: JSONObject): CoreCallResult {
        if (closed) return CoreCallResult.StaleHandle
        return runtime.emit(json.toString().encodeToByteArray())
    }

    private fun receive(event: CoreEvent) {
        if (closed) return
        val envelope = JSONObject(event.bytes.decodeToString())
        val eventGeneration = envelope.optLong("generation", 0)
        if (eventGeneration > 0) generation.accumulateAndGet(eventGeneration, ::maxOf)
        when (val kind = envelope.getString("kind")) {
            "backendCommandRequested" -> {
                val code = envelope.getString("code")
                envelope.optJSONObject("arguments")?.optString("sessionID")
                    ?.takeIf(String::isNotBlank)
                    ?.let(UUID::fromString)
                    ?.let { sessionId = it }
                val command = pending[code]?.poll()
                if (command != null) listener.onBackendCommand(command)
                else listener.onEvent(SharedSessionEvent.ProtocolFailure("missing pending command for $code"))
            }
            "stateChanged" -> listener.onEvent(
                SharedSessionEvent.StateChanged(
                    generation = eventGeneration,
                    state = SharedSessionState.fromWire(envelope.getString("code")),
                ),
            )
            "terminalBytes" -> {
                val receipt = try {
                    terminalOutputReceipt(envelope.optJSONObject("arguments"))
                } catch (_: Exception) {
                    listener.onEvent(
                        SharedSessionEvent.ProtocolFailure("invalid terminal output receipt"),
                    )
                    return
                }
                listener.onEvent(
                    SharedSessionEvent.TerminalBytes(
                        generation = eventGeneration,
                        bytes = envelope.getString("payload").decodeBase64(),
                        receipt = receipt,
                    ),
                )
            }
            "challenge" -> listener.onEvent(
                SharedSessionEvent.Challenge(
                    generation = eventGeneration,
                    kind = envelope.getString("code"),
                    challengeId = UUID.fromString(envelope.getJSONObject("arguments").getString("challengeID")),
                    attemptId = UUID.fromString(envelope.getJSONObject("arguments").getString("attemptID")),
                    policyGeneration = envelope.getJSONObject("arguments").getString("policyGeneration").toLong(),
                    payload = envelope.getString("payload").decodeBase64(),
                ),
            )
            "tmuxSnapshotChanged" -> listener.onEvent(
                SharedSessionEvent.TmuxSnapshotChanged(
                    generation = eventGeneration,
                    snapshotJson = envelope.getString("payload").decodeBase64(),
                ),
            )
            "gridAuthorityChanged" -> listener.onEvent(
                SharedSessionEvent.GridAuthorityChanged(
                    generation = eventGeneration,
                    snapshot = SharedTmuxGridAuthoritySnapshot.fromJson(
                        JSONObject(envelope.getString("payload").decodeBase64().decodeToString()),
                    ),
                ),
            )
            "remoteWorkingDirectoryChanged" -> listener.onEvent(
                SharedSessionEvent.RemoteWorkingDirectoryChanged(
                    generation = eventGeneration,
                    path = envelope.optJSONObject("arguments")?.optionalString("path"),
                ),
            )
            "forwardingStateChanged" -> listener.onEvent(
                SharedSessionEvent.ForwardingStateChanged(
                    generation = eventGeneration,
                    states = org.json.JSONArray(
                        envelope.getString("payload").decodeBase64().decodeToString(),
                    ).toForwardingStates(),
                ),
            )
            "commandCompleted" -> listener.onEvent(
                SharedSessionEvent.CommandCompleted(
                    generation = eventGeneration,
                    completion = sharedSessionCommandCompletionFromJson(
                        JSONObject(envelope.getString("payload").decodeBase64().decodeToString()),
                    ),
                ),
            )
            "failure" -> listener.onEvent(
                SharedSessionEvent.Failure(
                    generation = eventGeneration,
                    code = envelope.optString("code", "unknown"),
                    arguments = envelope.optJSONObject("arguments").toStringMap(),
                ),
            )
            "recoverableWarning" -> listener.onEvent(
                SharedSessionEvent.RecoverableWarning(
                    generation = eventGeneration,
                    code = envelope.optString("code", "unknown"),
                    arguments = envelope.optJSONObject("arguments").toStringMap(),
                ),
            )
            "diagnostics" -> listener.onEvent(
                SharedSessionEvent.Diagnostics(
                    generation = eventGeneration,
                    code = envelope.optString("code", "unknown"),
                    values = envelope.optJSONObject("arguments").toStringMap(),
                ),
            )
            "commandRejected" -> {
                val commandCode = envelope.optJSONObject("arguments")
                    ?.optString("command")
                    ?.takeIf(String::isNotBlank)
                commandCode?.let { pending[it]?.poll() }
                listener.onEvent(
                    SharedSessionEvent.CommandRejected(
                        code = envelope.optString("code", "unknown"),
                        commandCode = commandCode,
                    ),
                )
            }
            "destroyed" -> listener.onEvent(SharedSessionEvent.Destroyed(eventGeneration))
            else -> listener.onEvent(SharedSessionEvent.Unhandled(kind, event.bytes.copyOf()))
        }
    }

    companion object {
        /** Core commands adopted ABI v2 with the render-ledger callback. */
        private const val COMMAND_ABI_VERSION = CoreBridge.EXPECTED_ABI_VERSION
        /** Backend events remain v1; changing them would break transport adapters. */
        private const val BACKEND_EVENT_ABI_VERSION = 1
        // The core refuses challenge lifetimes greater than 60 seconds.
        private const val CHALLENGE_LIFETIME_SECONDS = 55L
        private const val FOUNDATION_EPOCH_SECONDS = 978_307_200L

        fun create(listener: SharedSessionListener): SharedSessionRuntime {
            lateinit var owner: SharedSessionRuntime
            val runtime = CoreRuntime.create { owner.receive(it) }
            owner = SharedSessionRuntime(runtime, listener)
            return owner
        }
    }

    private fun terminalOutputReceipt(arguments: JSONObject?): SharedTerminalOutputReceipt? {
        arguments ?: return null
        val deliveryId = arguments.optString("deliveryID")
            .toLongOrNull()
            ?.takeIf { it > 0 }
            ?: throw IllegalArgumentException("invalid deliveryID")
        val repaintRequestId = if (arguments.has("repaintRequestID")) {
            arguments.optString("repaintRequestID")
                .toLongOrNull()
                ?.takeIf { it > 0 }
                ?: throw IllegalArgumentException("invalid repaintRequestID")
        } else {
            null
        }
        return SharedTerminalOutputReceipt(
            deliveryId = deliveryId,
            repaintRequestId = repaintRequestId,
        )
    }
}

data class SharedConnectionIntent(
    val requestId: UUID,
    val hostId: UUID,
    val policyGeneration: Long,
)

fun interface SharedSessionListener {
    fun onEvent(event: SharedSessionEvent)

    fun onBackendCommand(command: SharedBackendCommand) = Unit
}

sealed interface SharedBackendCommand {
    data class Connect(val intent: SharedConnectionIntent) : SharedBackendCommand
    data class CancelConnect(val attemptId: UUID) : SharedBackendCommand
    data object Disconnect : SharedBackendCommand
    data class SendInput(val bytes: ByteArray) : SharedBackendCommand
    data class Resize(val columns: Int, val rows: Int) : SharedBackendCommand
    data class SetFocused(val focused: Boolean) : SharedBackendCommand
    data class SetVisibility(val visibility: SharedSessionVisibility) : SharedBackendCommand
    data object RequestFullRepaint : SharedBackendCommand
    data class SubmitChallengeResponse(
        val challengeId: UUID,
        val attemptId: UUID,
        val policyGeneration: Long,
        val decision: SharedChallengeDecision,
    ) : SharedBackendCommand
    data class SelectTmuxWindow(val id: String) : SharedBackendCommand
    data class SelectTmuxPane(val id: String) : SharedBackendCommand
    data class SendTmuxPaneInput(
        val paneId: String,
        val bytes: ByteArray,
        val receipt: SharedSessionCommandReceipt?,
    ) : SharedBackendCommand
    data class SendTmuxPaneKey(
        val paneId: String,
        val key: SharedTmuxPaneKey,
        val receipt: SharedSessionCommandReceipt?,
    ) : SharedBackendCommand
    data object CreateTmuxWindow : SharedBackendCommand
    data class CloseTmuxWindow(val id: String) : SharedBackendCommand
    data class CloseTmuxPane(val id: String) : SharedBackendCommand
    data class SplitTmuxPane(
        val id: String,
        val axis: SharedTmuxSplitAxis,
        val before: Boolean = false,
    ) : SharedBackendCommand
    data class CycleTmuxPane(val forward: Boolean) : SharedBackendCommand
    data class SetTmuxPaneZoomed(val id: String, val zoomed: Boolean) : SharedBackendCommand
    data class MoveTmuxWindow(val id: String, val destination: Int) : SharedBackendCommand
    data object RenumberTmuxWindows : SharedBackendCommand
    data class RenameTmuxWindow(val id: String, val name: String) : SharedBackendCommand
    data class SetTmuxGridPresentation(val presentation: SharedTmuxGridPresentation) : SharedBackendCommand
    data class ClaimTmuxGridAuthority(
        val reason: SharedTmuxGridAuthorityReason,
        val repaintEvenIfSame: Boolean,
    ) : SharedBackendCommand
    data class ReclaimTmuxGridAuthority(val reason: SharedTmuxGridAuthorityReason) : SharedBackendCommand
    data class CompleteTmuxGridAuthorityRepaint(val authorityGeneration: Long) : SharedBackendCommand
}

/** The shared core's `SessionBackendOperation.kindCode`, which tags the command's backend request. */
val SharedBackendCommand.kindCode: String
    get() = when (this) {
        is SharedBackendCommand.Connect -> "connect"
        is SharedBackendCommand.CancelConnect -> "cancel_connect"
        SharedBackendCommand.Disconnect -> "disconnect"
        is SharedBackendCommand.SendInput -> "send_input"
        is SharedBackendCommand.Resize -> "resize"
        is SharedBackendCommand.SetFocused -> "set_focused"
        is SharedBackendCommand.SetVisibility -> "set_application_visibility"
        SharedBackendCommand.RequestFullRepaint -> "request_full_repaint"
        is SharedBackendCommand.SubmitChallengeResponse -> "submit_challenge_response"
        is SharedBackendCommand.SelectTmuxWindow -> "select_tmux_window"
        is SharedBackendCommand.SelectTmuxPane -> "select_tmux_pane"
        is SharedBackendCommand.SendTmuxPaneInput -> "send_tmux_pane_input"
        is SharedBackendCommand.SendTmuxPaneKey -> "send_tmux_pane_key"
        SharedBackendCommand.CreateTmuxWindow -> "create_tmux_window"
        is SharedBackendCommand.CloseTmuxWindow -> "close_tmux_window"
        is SharedBackendCommand.CloseTmuxPane -> "close_tmux_pane"
        is SharedBackendCommand.SplitTmuxPane -> "split_tmux_pane"
        is SharedBackendCommand.CycleTmuxPane -> "cycle_tmux_pane"
        is SharedBackendCommand.SetTmuxPaneZoomed -> "set_tmux_pane_zoomed"
        is SharedBackendCommand.MoveTmuxWindow -> "move_tmux_window"
        SharedBackendCommand.RenumberTmuxWindows -> "renumber_tmux_windows"
        is SharedBackendCommand.RenameTmuxWindow -> "rename_tmux_window"
        is SharedBackendCommand.SetTmuxGridPresentation -> "set_tmux_grid_presentation"
        is SharedBackendCommand.ClaimTmuxGridAuthority -> "claim_tmux_grid_authority"
        is SharedBackendCommand.ReclaimTmuxGridAuthority -> "reclaim_tmux_grid_authority"
        is SharedBackendCommand.CompleteTmuxGridAuthorityRepaint -> "complete_tmux_grid_authority_repaint"
    }

/** The grid-authority gate a backend command passes (review §6.5 S5′). */
enum class SharedCommandAuthorityGate(val wireValue: String) {
    /** Keys, paste, paths, mouse and mosh bytes: refused while typing is gated. */
    TYPING("typing"),
    /** Window and pane mutations, un-receipted pane sends, the forced repaint. */
    MUTATION("mutation"),
    UNGATED("ungated"),
}

/**
 * The shared core's classification (`SessionBackendOperation.authorityGate`).
 * Copied so a keystroke costs no JNI call; `SharedAuthorityGateParityTest`
 * compares the copy with `tessera_session_authority_gates`.
 * Receipted Agent Center pane replies are neutral; grid typing has no receipt.
 */
val SharedBackendCommand.authorityGate: SharedCommandAuthorityGate
    get() = when (this) {
        is SharedBackendCommand.SendInput -> SharedCommandAuthorityGate.TYPING
        is SharedBackendCommand.SendTmuxPaneInput ->
            if (receipt == null) SharedCommandAuthorityGate.MUTATION else SharedCommandAuthorityGate.UNGATED
        is SharedBackendCommand.SendTmuxPaneKey ->
            if (receipt == null) SharedCommandAuthorityGate.MUTATION else SharedCommandAuthorityGate.UNGATED
        is SharedBackendCommand.SelectTmuxWindow,
        is SharedBackendCommand.SelectTmuxPane,
        SharedBackendCommand.CreateTmuxWindow,
        is SharedBackendCommand.CloseTmuxWindow,
        is SharedBackendCommand.CloseTmuxPane,
        is SharedBackendCommand.SplitTmuxPane,
        is SharedBackendCommand.CycleTmuxPane,
        is SharedBackendCommand.SetTmuxPaneZoomed,
        is SharedBackendCommand.MoveTmuxWindow,
        SharedBackendCommand.RenumberTmuxWindows,
        is SharedBackendCommand.RenameTmuxWindow,
        is SharedBackendCommand.ClaimTmuxGridAuthority,
        -> SharedCommandAuthorityGate.MUTATION
        // Resize is latched while yielded: `publishTmuxClientSize` withholds
        // what would reach the peer, and the take-back replays the latest size.
        is SharedBackendCommand.Connect,
        is SharedBackendCommand.CancelConnect,
        SharedBackendCommand.Disconnect,
        is SharedBackendCommand.Resize,
        is SharedBackendCommand.SetFocused,
        is SharedBackendCommand.SetVisibility,
        SharedBackendCommand.RequestFullRepaint,
        is SharedBackendCommand.SubmitChallengeResponse,
        is SharedBackendCommand.SetTmuxGridPresentation,
        is SharedBackendCommand.ReclaimTmuxGridAuthority,
        is SharedBackendCommand.CompleteTmuxGridAuthorityRepaint,
        -> SharedCommandAuthorityGate.UNGATED
    }

data class SharedTerminalOutputReceipt(
    val deliveryId: Long,
    val repaintRequestId: Long? = null,
) {
    init {
        require(deliveryId > 0)
        require(repaintRequestId == null || repaintRequestId > 0)
    }
}

sealed interface SharedSessionEvent {
    data class StateChanged(val generation: Long, val state: SharedSessionState) : SharedSessionEvent
    data class TerminalBytes(
        val generation: Long,
        val bytes: ByteArray,
        val receipt: SharedTerminalOutputReceipt? = null,
    ) : SharedSessionEvent
    data class Challenge(
        val generation: Long,
        val kind: String,
        val challengeId: UUID,
        val attemptId: UUID,
        val policyGeneration: Long,
        val payload: ByteArray,
    ) : SharedSessionEvent
    data class TmuxSnapshotChanged(val generation: Long, val snapshotJson: ByteArray) : SharedSessionEvent
    data class GridAuthorityChanged(
        val generation: Long,
        val snapshot: SharedTmuxGridAuthoritySnapshot,
    ) : SharedSessionEvent
    data class RemoteWorkingDirectoryChanged(val generation: Long, val path: String?) : SharedSessionEvent
    data class ForwardingStateChanged(
        val generation: Long,
        val states: List<SharedForwardingState>,
    ) : SharedSessionEvent
    data class CommandCompleted(
        val generation: Long,
        val completion: SharedSessionCommandCompletion,
    ) : SharedSessionEvent
    data class Failure(val generation: Long, val code: String, val arguments: Map<String, String>) : SharedSessionEvent
    data class RecoverableWarning(val generation: Long, val code: String, val arguments: Map<String, String>) : SharedSessionEvent
    data class Diagnostics(val generation: Long, val code: String, val values: Map<String, String>) : SharedSessionEvent
    data class CommandRejected(
        val code: String,
        val commandCode: String?,
    ) : SharedSessionEvent
    data class Destroyed(val generation: Long) : SharedSessionEvent
    data class ProtocolFailure(val detail: String) : SharedSessionEvent
    data class Unhandled(val kind: String, val envelope: ByteArray) : SharedSessionEvent
}

enum class SharedSessionState {
    IDLE,
    CONNECTING,
    CONNECTED,
    DISCONNECTED,
    FAILED;

    companion object {
        fun fromWire(value: String): SharedSessionState = when (value) {
            "idle" -> IDLE
            "connecting" -> CONNECTING
            "connected" -> CONNECTED
            "disconnected" -> DISCONNECTED
            // The shared core encodes a failed state's stable failure code here so callers can
            // diagnose it from the adjacent Failure event without widening this state enum.
            else -> FAILED
        }
    }
}

enum class SharedChallengeDecision(val wireValue: String) { APPROVE("approve"), REJECT("reject"), CANCEL("cancel") }
enum class SharedSessionVisibility(val wireValue: String) { ACTIVE("active"), INACTIVE("inactive"), BACKGROUND("background") }
enum class SharedTmuxSplitAxis(val wireValue: String) { HORIZONTAL("horizontal"), VERTICAL("vertical") }
enum class SharedTmuxGridPresentation(val wireValue: String) { SINGLE_PANE("singlePane"), PANE_GRID("paneGrid") }
enum class SharedTmuxPaneKey(val wireValue: String) { ENTER("enter"), ESCAPE("escape") }
enum class SharedTmuxGridAuthorityReason(val wireValue: String) { USER("user"), FORCE_REFRESH("forceRefresh") }

data class SharedSessionCommandReceipt(val rawValue: UUID)

sealed interface SharedSessionCommandResult {
    data object Succeeded : SharedSessionCommandResult
    data class Failed(val failure: SharedSessionFailure) : SharedSessionCommandResult
}

data class SharedSessionFailure(val code: String, val arguments: Map<String, String> = emptyMap())

data class SharedSessionCommandCompletion(
    val receipt: SharedSessionCommandReceipt,
    val result: SharedSessionCommandResult,
)

data class SharedForwardingState(val ruleId: UUID, val state: String)

sealed interface SharedTmuxGridAuthoritySnapshot {
    data object Unknown : SharedTmuxGridAuthoritySnapshot
    data class Mine(val generation: Long) : SharedTmuxGridAuthoritySnapshot
    data class Peer(val deviceId: String, val displayName: String, val generation: Long) : SharedTmuxGridAuthoritySnapshot

    fun toJson(): JSONObject = when (this) {
        Unknown -> JSONObject().put("unknown", JSONObject())
        is Mine -> JSONObject().put("mine", JSONObject().put("generation", generation))
        is Peer -> JSONObject().put(
            "peer",
            JSONObject()
                .put("deviceID", deviceId)
                .put("displayName", displayName)
                .put("generation", generation),
        )
    }

    companion object {
        fun fromJson(value: JSONObject): SharedTmuxGridAuthoritySnapshot = when {
            value.has("unknown") -> Unknown
            value.has("mine") -> Mine(value.getJSONObject("mine").getLong("generation"))
            value.has("peer") -> value.getJSONObject("peer").let {
                Peer(it.getString("deviceID"), it.getString("displayName"), it.getLong("generation"))
            }
            else -> throw IllegalArgumentException("unknown tmux grid authority snapshot")
        }
    }
}

private fun ByteArray.base64(): String = Base64.encodeToString(this, Base64.NO_WRAP)
private fun String.decodeBase64(): ByteArray = Base64.decode(this, Base64.DEFAULT)
private fun JSONObject.putOptionalReceipt(receipt: SharedSessionCommandReceipt?): JSONObject = apply {
    if (receipt != null) put("receipt", JSONObject().put("rawValue", receipt.rawValue.toString()))
}
private fun JSONObject?.toStringMap(): Map<String, String> {
    if (this == null) return emptyMap()
    return keys().asSequence().associateWith { getString(it) }
}

private fun JSONObject.optionalString(key: String): String? =
    takeIf { has(key) && !isNull(key) }?.getString(key)

private fun List<SharedForwardingState>.toJsonArray(): org.json.JSONArray = org.json.JSONArray().also { states ->
    forEach { state -> states.put(JSONObject().put("ruleID", state.ruleId.toString()).put("state", state.state)) }
}

private fun org.json.JSONArray.toForwardingStates(): List<SharedForwardingState> = buildList {
    repeat(length()) { index ->
        getJSONObject(index).let { add(SharedForwardingState(UUID.fromString(it.getString("ruleID")), it.getString("state"))) }
    }
}

private fun SharedSessionCommandCompletion.toJson(): JSONObject = JSONObject()
    .put("receipt", JSONObject().put("rawValue", receipt.rawValue.toString()))
    .put("result", result.toJson())

private fun SharedSessionCommandResult.toJson(): JSONObject = when (this) {
    SharedSessionCommandResult.Succeeded -> JSONObject().put("succeeded", JSONObject())
    is SharedSessionCommandResult.Failed -> JSONObject().put(
        "failed",
        JSONObject().put("_0", JSONObject().put("code", failure.code).put("arguments", JSONObject(failure.arguments))),
    )
}

private fun sharedSessionCommandCompletionFromJson(value: JSONObject): SharedSessionCommandCompletion {
    val receipt = SharedSessionCommandReceipt(UUID.fromString(value.getJSONObject("receipt").getString("rawValue")))
    val result = value.getJSONObject("result").let { encoded ->
        when {
            encoded.has("succeeded") -> SharedSessionCommandResult.Succeeded
            encoded.has("failed") -> encoded.getJSONObject("failed").getJSONObject("_0").let { failure ->
                SharedSessionCommandResult.Failed(
                    SharedSessionFailure(failure.getString("code"), failure.optJSONObject("arguments").toStringMap()),
                )
            }
            else -> throw IllegalArgumentException("unknown session command result")
        }
    }
    return SharedSessionCommandCompletion(receipt, result)
}

/**
 * Decides whether a tmux snapshot was already published. A repeat is the same
 * payload instance, which the tmux runtime reuses for exactly as long as the
 * snapshot is unchanged, under the same generation: the session core accepts
 * a snapshot on its generation alone and otherwise only relays it, so a
 * repeat it already accepted cannot tell it anything. Anything not accepted
 * is never a repeat. Not thread-safe; the owner serializes access.
 *
 * This holds only while the core stays a pure relay. The invariant is stated
 * on `SessionEngine.tmuxSnapshotChanged`: a core that kept or reset tmux
 * state without bumping the generation would need the repeat this skips.
 */
internal class TmuxSnapshotRepublishGate {
    private var json: ByteArray? = null
    private var generation = 0L

    fun isRepeat(json: ByteArray, generation: Long): Boolean =
        this.json === json && this.generation == generation

    fun record(json: ByteArray, generation: Long, accepted: Boolean) {
        this.json = if (accepted) json else null
        this.generation = generation
    }
}
