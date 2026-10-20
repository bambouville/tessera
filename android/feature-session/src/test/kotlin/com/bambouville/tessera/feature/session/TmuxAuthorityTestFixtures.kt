package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import com.bambouville.tessera.core.bridge.SharedTmuxRenderFact
import com.bambouville.tessera.core.bridge.SharedTmuxRenderLedgerOptions
import com.bambouville.tessera.core.bridge.SharedTmuxRenderProfile
import com.bambouville.tessera.core.bridge.SharedTmuxWindowSizeReplay
import com.bambouville.tessera.data.SessionRestoreRecord
import com.bambouville.tessera.data.SessionRestoreRepository
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ExecutorService
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow

/** Drive real JNI fence evidence, optionally applying each result to the adapter. */
internal fun com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySession.confirmFence(
    nowMillis: Long,
    generation: Long,
    size: SharedTmuxGridSize,
    windowId: Int = 5,
    onResult: (com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionResult) -> Unit = {},
) {
    if (state.claim?.targetGrid == null) {
        onResult(claimAdvertisedGeometry(nowMillis, generation, size.columns, size.rows))
    }
    val target = requireNotNull(state.claim?.targetGrid)
    onResult(claimFenceSent(nowMillis, generation, windowId))
    val fenceId = requireNotNull(state.claimFence).id
    onResult(claimFenceAcknowledged(nowMillis, fenceId))
    onResult(windowSizePolicyReplied(nowMillis, windowId, "latest", fenceId))
    onResult(windowFacts(nowMillis, true,
        com.bambouville.tessera.core.bridge.SharedTmuxAuthorityActiveWindow(windowId, target, true)))
    onResult(confirmClaimFence(nowMillis))
    org.junit.Assert.assertEquals(generation, state.claim?.generation)
    org.junit.Assert.assertEquals(com.bambouville.tessera.core.bridge.SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT,
        state.claim?.phase)
}

/** Records real JNI submissions; native effects and projections are never replaced. */
internal class NativeAuthorityHarness(private val now: () -> Long = { 0L }) : AutoCloseable {
    val session = com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySession.create(initialGeneration = 0)
    val calls = mutableListOf<String>()
    /** Every effect the session returned, in order, whether or not the adapter acted on it. */
    val effects = mutableListOf<com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionEffect>()
    var submissions = 0
    var snapshotCalls = 0
    /** Runtime reductions adopted from a read's event: no submission, no JNI call. */
    var adoptions = 0
    val adapter = TmuxAuthorityReducer(
        session,
        onSubmit = { response ->
            submissions++
            if (response == null) snapshotCalls++
            response?.let(::record)
        },
        onAdopt = { response -> adoptions++; record(response) },
    )
    private fun record(response: com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionResult) {
        effects.addAll(response.effects)
        response.trace?.substringAfter("event=")?.substringBefore(" authority=")?.let { label ->
            val event = label.substringBefore("(")
            calls += when (event) {
                "shown" -> "shown:${label.substringAfter("(").substringBefore(")")}"
                "abortClaim" -> "abort"
                "claimStalled" -> "claimStalled:${label.contains("canProgress=true")}"
                else -> event
            }
        }
    }
    val claim get() = session.state.claim
    fun snapshot() = com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionResult(
        adapter.snapshot(now()), emptyList(), null, changed = true,
    )
    override fun close() = adapter.close()
}

/** Wire spellings and geometry decisions are the real shared core exports. */
internal val coreWindowSelectionCommand: (Int, Int?) -> String = { windowId, ownSessionId ->
    if (ownSessionId == null) com.bambouville.tessera.core.bridge.SharedTmuxCommands.selectWindow(windowId)
    else com.bambouville.tessera.core.bridge.SharedTmuxCommands.selectWindowInOwnSession(windowId, ownSessionId)
}
internal val coreLatestFenceCommand: () -> String = { com.bambouville.tessera.core.bridge.SharedTmuxCommands.clientSizeLatestFenceCommand }
internal val coreAuthorityStampValue: (String, String, Long) -> String = { deviceId, displayName, generation ->
    com.bambouville.tessera.core.bridge.SharedTmuxCommands.authorityStampValue(deviceId, displayName, generation)
}
internal object CoreTmuxWindowForceRule : TmuxWindowForceRule {
    override fun decision(requested: SharedTmuxGridSize, observed: SharedTmuxGridSize?, lastAttempt: SharedTmuxGridSize?) =
        SharedTmuxWindowSizeReplay.decision(requested, observed, lastAttempt)
    override fun commands(windowId: Int, requested: SharedTmuxGridSize) = SharedTmuxWindowSizeReplay.commands(windowId, requested)
    override fun sizeQuery(windowId: Int) = SharedTmuxWindowSizeReplay.sizeQuery(windowId)
    override fun reportedGeometry(windowId: Int, reply: String) = SharedTmuxWindowSizeReplay.reportedGeometry(windowId, reply)
}

/**
 * The ledger's client-size replay (`TmuxRenderLedger.clientSizeChanged` over
 * `TmuxClientSizeReplay.commands`), a wire test double around the controller's render-fact injection seam: the adapter-owned switches, the transport profile, and the grid
 * this connection advertised (P6), which an attach, a transport loss and a
 * rejected `-C` forget. A replay reaches [emit] as the runtime's synchronous
 * callback delivers it; with no profile yet, it records nothing it sends.
 * `TmuxRuntimeClaimSettlementABITests.testClientSizeReplayFollowsTheOptions`
 * drives the native rule through the same steps.
 */
internal class CoreClientSizeLedger(private val emit: (List<SharedTmuxRenderEffect>) -> Unit) {
    /** Every fact submitted, in order. */
    val facts = mutableListOf<SharedTmuxRenderFact>()
    /** Every switch set accepted, in order. */
    val optionHistory = mutableListOf<Int>()
    private var options = 0
    private var profile: SharedTmuxRenderProfile? = null
    private var advertised: SharedTmuxGridSize? = null

    fun setOptions(bits: Int): Boolean {
        if (bits and DEFINED_OPTIONS.inv() != 0) return false
        options = bits
        optionHistory += bits
        return true
    }

    fun submit(fact: SharedTmuxRenderFact): Boolean {
        facts += fact
        when (fact) {
            is SharedTmuxRenderFact.TransportAttached -> {
                profile = fact.profile
                advertised = null
            }
            SharedTmuxRenderFact.TransportLost -> {
                profile = null
                advertised = null
            }
            is SharedTmuxRenderFact.ClientSize -> clientSize(SharedTmuxGridSize(fact.columns, fact.rows))
            else -> Unit
        }
        return true
    }

    /** tmux answered the `-C` for [size] with an error. */
    fun rejected(size: SharedTmuxGridSize) {
        if (advertised == size) advertised = null
    }

    private fun clientSize(size: SharedTmuxGridSize) {
        val path = profile ?: return
        val suppresses = options and SharedTmuxRenderLedgerOptions.SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY != 0
        val belongs = options and SharedTmuxRenderLedgerOptions.INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM != 0
        val commands = buildList {
            if (!(suppresses && advertised == size)) {
                add("refresh-client -C ${size.columns},${size.rows}")
                advertised = size
            }
            if (path == SharedTmuxRenderProfile.Inline && !belongs) add("select-window")
        }
        if (commands.isNotEmpty()) emit(commands.map(SharedTmuxRenderEffect::SendCommand))
    }

    private companion object {
        const val DEFINED_OPTIONS = SharedTmuxRenderLedgerOptions.SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY or
            SharedTmuxRenderLedgerOptions.INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM or
            SharedTmuxRenderLedgerOptions.PIPELINES_VISIBLE_CAPTURE
    }
}

/** A diagnostics store for controllers built without an Android Context. */
internal fun testDiagnosticLogStore(): DiagnosticLogStore {
    // These fixtures assert adapter behaviour, never diagnostic text. The
    // production writer's redaction crosses JNI on its own thread, outside
    // JUnit's failure collector. Shut it down so record takes its existing
    // best-effort rejection path without starting Android diagnostics workers.
    (DiagnosticLogStore::class.java.getDeclaredField("writer")
        .apply { isAccessible = true }.get(null) as ExecutorService).shutdown()
    val unsafe = sun.misc.Unsafe::class.java.getDeclaredField("theUnsafe")
        .apply { isAccessible = true }.get(null) as sun.misc.Unsafe
    val directory = Files.createTempDirectory("tessera-diagnostics").toFile().apply { deleteOnExit() }
    return (unsafe.allocateInstance(DiagnosticLogStore::class.java) as DiagnosticLogStore).apply {
        fun set(name: String, value: Any) {
            DiagnosticLogStore::class.java.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
        }
        set("directory", directory)
        set("file", File(directory, "tessera-diagnostics.log"))
        set("previousFile", File(directory, "tessera-diagnostics.log.previous"))
    }
}

/** A restore store in memory: the controller's selection saves land here. */
internal class RecordingSessionRestoreRepository : SessionRestoreRepository {
    private val saved = MutableStateFlow<List<SessionRestoreRecord>>(emptyList())
    override fun observeRecords(): Flow<List<SessionRestoreRecord>> = saved
    override suspend fun records(): List<SessionRestoreRecord> = saved.value
    override suspend fun record(sessionId: String): SessionRestoreRecord? = saved.value.lastOrNull { it.sessionId == sessionId }
    override suspend fun save(record: SessionRestoreRecord) {
        saved.value = saved.value.filterNot { it.sessionId == record.sessionId } + record
    }
    override suspend fun delete(sessionId: String) {
        saved.value = saved.value.filterNot { it.sessionId == sessionId }
    }
    override suspend fun deleteForHost(hostId: String) {
        saved.value = saved.value.filterNot { it.hostId == hostId }
    }
    override suspend fun deleteAll() {
        saved.value = emptyList()
    }
}
