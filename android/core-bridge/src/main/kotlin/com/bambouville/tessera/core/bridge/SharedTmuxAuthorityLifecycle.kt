package com.bambouville.tessera.core.bridge

import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONArray
import org.json.JSONObject

/**
 * Why a claim began. Under the show rule only user gestures claim: a show,
 * an explicit open, a veil tap, or the continuation of a contested user claim
 * whose own stamp landed last.
 */
enum class SharedTmuxAuthorityClaimReason(val wireValue: String) {
    /** The session became displayed. Present as a light "resuming" indicator. */
    SHOW("show"),

    /** An explicit open targeted the session. Presented like [SHOW]. */
    EXPLICIT_OPEN("explicitOpen"),

    /** A veil tap, Enter or printable key. Presented on the veil. */
    USER_TAKE_BACK("userTakeBack"),

    /** Our own queued stamp landed after a contesting one. Presented on the veil. */
    OWN_WRITE_WON("ownWriteWon");

    companion object {
        fun fromWire(value: String): SharedTmuxAuthorityClaimReason =
            entries.first { it.wireValue == value }
    }
}

enum class SharedTmuxAuthorityClaimPhase(val wireValue: String) {
    AWAITING_FENCE("awaitingFence"),
    AWAITING_REPAINT("awaitingRepaint"),
    AWAITING_STAMP_COMMIT("awaitingStampCommit"),
    AWAITING_SETTLEMENT("awaitingSettlement");

    companion object {
        fun fromWire(value: String): SharedTmuxAuthorityClaimPhase =
            entries.first { it.wireValue == value }
    }
}

/** What caused a show edge. A veil tap is not a show; see `requestTakeBack`. */
enum class SharedTmuxAuthorityShowSource(val wireValue: String) {
    SHOW("show"),
    EXPLICIT_OPEN("explicitOpen");

    companion object {
        fun fromWire(value: String): SharedTmuxAuthorityShowSource =
            entries.first { it.wireValue == value }
    }
}

enum class SharedTmuxAuthorityIntentSource(val wireValue: String) {
    SHOW("show"),
    EXPLICIT_OPEN("explicitOpen"),
    TAP("tap");

    companion object {
        fun fromWire(value: String): SharedTmuxAuthorityIntentSource =
            entries.first { it.wireValue == value }
    }
}

data class SharedTmuxAuthorityLifecycleClaim(
    val generation: Long,
    val reason: SharedTmuxAuthorityClaimReason,
    val phase: SharedTmuxAuthorityClaimPhase,
    val presentationVisible: Boolean,
    val contestedPeer: SharedTmuxGridAuthoritySnapshot.Peer?,
    /**
     * The claim already fenced again after losing its geometry (§6.10 rule
     * 4); one re-fence per generation. Absent from snapshots that predate
     * it, which decode false.
     */
    val geometryRefenced: Boolean = false,
    /**
     * Every grid this claim advertised to tmux, oldest first: its begin
     * replay, then local churn while it was visible. A window at any of them
     * is unsettled, never lost (§6.10 rule 3).
     */
    val advertisedGrids: List<SharedTmuxGridSize> = emptyList(),
    /** The advertised grid the claim confirms at; null until it advertises one. */
    val targetGrid: SharedTmuxGridSize? = null,
    /**
     * The settle probe of the claim's latest fence was answered: its geometry
     * provably landed, so a window at a size it never advertised is a loss,
     * not a stale layout (§6.10 rules 4–5).
     */
    val geometryLanded: Boolean = false,
)

/**
 * The fence a live claim sent last, and what it has proved. The session
 * confirms from this alone: tmux answered the fence, its own policy read
 * landed, and under `latest` the fenced window stands at the claim's target,
 * with no probe off target or window force still unproved. Under any other
 * policy the acknowledgement alone confirms.
 */
data class SharedTmuxAuthorityClaimFence(
    val generation: Long,
    val id: Long,
    val windowId: Int,
    val acknowledged: Boolean,
    /** This fence's own policy read; null until it lands. */
    val policyIsLatest: Boolean?,
    val probeOffTarget: Boolean,
    val forceOutstanding: Boolean,
)

/**
 * A user gesture waiting for a fresh authority read. The session owns the
 * intent clock and expires [token] when the adapter reports a deadline
 * through `tick`.
 *
 * A SHOW or EXPLICIT_OPEN intent never has a [baseline]: stamp lines read
 * after a show can predate it, so only the fresh read the show requested
 * decides it. A TAP intent is bound to the peer its veil named
 * ([baselineKnown] true) and ends if a read shows a different peer.
 */
data class SharedTmuxAuthorityIntent(
    val token: Long,
    val source: SharedTmuxAuthorityIntentSource,
    val baseline: SharedTmuxGridAuthoritySnapshot.Peer?,
    val baselineKnown: Boolean,
)

/**
 * The stamp parser's bounds (`TmuxGridAuthorityStamp`): null for a peer ID it would refuse,
 * else the snapshot with a longer name cut. Counted in UTF-16 units, never more Characters
 * than the core's bound, so nothing that passes here is refused there; stamp tokens are
 * ASCII, where the two counts agree. A cut never splits a surrogate pair.
 */
internal fun SharedTmuxGridAuthoritySnapshot.withinStampBounds(): SharedTmuxGridAuthoritySnapshot? {
    if (this !is SharedTmuxGridAuthoritySnapshot.Peer) return this
    if (deviceId.length > MAXIMUM_STAMP_DEVICE_ID_CHARACTERS) return null
    if (displayName.length <= MAXIMUM_STAMP_DISPLAY_NAME_CHARACTERS) return this
    var end = MAXIMUM_STAMP_DISPLAY_NAME_CHARACTERS
    if (Character.isHighSurrogate(displayName[end - 1])) end -= 1
    return copy(displayName = displayName.substring(0, end))
}

/** `TmuxGridAuthorityStamp.maximumDeviceIDCharacters`. */
internal const val MAXIMUM_STAMP_DEVICE_ID_CHARACTERS = 128

/** `TmuxGridAuthorityStamp.maximumDisplayNameCharacters`. */
internal const val MAXIMUM_STAMP_DISPLAY_NAME_CHARACTERS = 64

private fun SharedTmuxGridAuthoritySnapshot.putWireFields(value: JSONObject) {
    when (this) {
        SharedTmuxGridAuthoritySnapshot.Unknown -> value.put("authorityKind", "unknown")
        is SharedTmuxGridAuthoritySnapshot.Mine -> value
            .put("authorityKind", "mine")
            .put("authorityGeneration", generation)
        is SharedTmuxGridAuthoritySnapshot.Peer -> value
            .put("authorityKind", "peer")
            .put("authorityDeviceID", deviceId)
            .put("authorityDisplayName", displayName)
            .put("authorityGeneration", generation)
    }
}

private fun JSONObject.peer(): SharedTmuxGridAuthoritySnapshot.Peer =
    SharedTmuxGridAuthoritySnapshot.Peer(
        getString("deviceID"),
        getString("displayName"),
        getLong("generation"),
    )

private fun JSONObject.authority(prefix: String = "authority"): SharedTmuxGridAuthoritySnapshot =
    when (getString("${prefix}Kind")) {
        "unknown" -> SharedTmuxGridAuthoritySnapshot.Unknown
        "mine" -> SharedTmuxGridAuthoritySnapshot.Mine(getLong("${prefix}Generation"))
        "peer" -> SharedTmuxGridAuthoritySnapshot.Peer(
            getString("${prefix}DeviceID"),
            getString("${prefix}DisplayName"),
            getLong("${prefix}Generation"),
        )
        else -> error("unknown tmux authority")
    }

private fun JSONObject.grid(): SharedTmuxGridSize = SharedTmuxGridSize(getInt("columns"), getInt("rows"))

private fun JSONObject.optionalString(key: String): String? =
    takeIf { has(key) && !isNull(key) }?.getString(key)

/** Which prompt pauses the session's intent clock. */
enum class SharedTmuxAuthorityPromptScope(val wireValue: String) {
    /** This session's own password/OTP challenge: always pauses. */
    SESSION("session"),

    /**
     * A connect-path prompt (host key, biometric unlock, the credential sheet)
     * that can belong to any connecting session: pauses only while this
     * session's control channel is down.
     */
    CONNECT("connect"),
}

/** Why the adapter gave up a claim. A contest is the core's own verdict. */
enum class SharedTmuxAuthorityAbortReason(val wireValue: String) {
    /** A claim command failed; a gesture's claim replays when the surface can paint. */
    ADAPTER_FAILURE("adapterFailure"),

    /** An unsent claim abandoned at a hide or cancel; never replayed. */
    SUPERSEDED("superseded"),
    TRANSPORT_RESET("transportReset"),
}

/** What ordinary geometry (keyboard, rotation, font, split screen) may do now. */
enum class SharedTmuxAuthorityGeometryHold(val wireValue: String) {
    /** Send nothing: authority is unresolved, a peer holds the grid, or the session is hidden. */
    WITHHELD("withheld"),

    /** No stamp on the server: advertise this client's size with a bare `refresh-client -C` only. */
    ADVERTISE_ONLY("advertiseOnly"),

    /** This device owns the grid: ordinary owner resizes flow. */
    OWNER("owner");

    companion object {
        fun fromWire(value: String): SharedTmuxAuthorityGeometryHold =
            entries.first { it.wireValue == value }
    }
}

/** What a read that released the geometry hold asks the adapter to send. */
enum class SharedTmuxAuthorityGeometryRelease(val wireValue: String) {
    /** Nothing beyond what changes from here on. */
    NONE("none"),

    /** The client size and a bare `refresh-client -C`, no stamp: this connection has not advertised yet. */
    ADVERTISE("advertise"),

    /** One ordinary owner resize at the local size; never a claim, never a stamp write. */
    OWNER_REPLAY("ownerReplay");

    companion object {
        fun fromWire(value: String): SharedTmuxAuthorityGeometryRelease =
            entries.first { it.wireValue == value }
    }
}

/** Why a size or layout mutation must be refused now. */
enum class SharedTmuxAuthorityMutationRefusal(val wireValue: String) {
    YIELDED("yielded"),
    RECLAIMING("reclaiming");

    companion object {
        fun fromWire(value: String): SharedTmuxAuthorityMutationRefusal =
            entries.first { it.wireValue == value }
    }
}

/** What the session's surface shows about grid authority. */
sealed interface SharedTmuxAuthorityPresentation {
    data object None : SharedTmuxAuthorityPresentation

    /** A show or explicit open is being resolved: the light "resuming" indicator. */
    data class Resuming(val awaitingConnection: Boolean) : SharedTmuxAuthorityPresentation

    /** Another device holds the grid. */
    data class Veiled(val peerName: String) : SharedTmuxAuthorityPresentation

    /** A take-back from [peerName] is in progress, on the veil. */
    data class Reclaiming(val peerName: String, val awaitingConnection: Boolean) : SharedTmuxAuthorityPresentation
}

/** An unfinished show a successor session object in the same slot resumes. */
data class SharedTmuxAuthorityCarriedShow(
    val source: SharedTmuxAuthorityShowSource,
    val stepAtMillis: Long,
)

/** The window tmux names active, and its grid when its layout is known. */
data class SharedTmuxAuthorityActiveWindow(
    val id: Int,
    val size: SharedTmuxGridSize?,
    /** tmux itself named it active; false for a model's provisional pick. */
    val authoritative: Boolean,
)

sealed interface SharedTmuxAuthoritySessionEffect {
    /** Send `show-options -qv @tessera_authority`; report its reply or failure with [queryId]. */
    data class QueryAuthority(val queryId: Long) : SharedTmuxAuthoritySessionEffect
    data class BeginClaim(
        val generation: Long,
        val reason: SharedTmuxAuthorityClaimReason,
        val presentationVisible: Boolean,
    ) : SharedTmuxAuthoritySessionEffect
    data class RequestRepaint(val generation: Long) : SharedTmuxAuthoritySessionEffect
    data class CommitAuthorityStamp(val generation: Long) : SharedTmuxAuthoritySessionEffect
    data class AuthorityChanged(val authority: SharedTmuxGridAuthoritySnapshot) : SharedTmuxAuthoritySessionEffect
    /**
     * The deadline only hides. While a claim is live, run the rule 6 stall
     * check: [SharedTmuxAuthoritySession.claimStalled] with `canProgress = false`
     * when no own command or repaint remains in flight.
     */
    data object HideReclaimPresentation : SharedTmuxAuthoritySessionEffect

    /** [reason] is `contestedByPeer` (with [peer]), `adapterFailure`, `transportReset`, `superseded` or `geometryLost`. */
    data class ClaimAborted(
        val reason: String,
        val peer: SharedTmuxGridAuthoritySnapshot.Peer?,
    ) : SharedTmuxAuthoritySessionEffect
    data class ClaimSettled(val generation: Long) : SharedTmuxAuthoritySessionEffect
    data class ReleaseGeometry(val release: SharedTmuxAuthorityGeometryRelease) : SharedTmuxAuthoritySessionEffect

    /**
     * The session yielded to the stamp-less peer: mirror it into the runtime
     * so its snapshot names the same peer. Follows the [AuthorityChanged] it
     * explains.
     */
    data object RaiseStamplessPeer : SharedTmuxAuthoritySessionEffect

    /** A read went unanswered past its bound. Mosh side channels reconnect; inline ones only log. */
    data object ControlChannelUnresponsive : SharedTmuxAuthoritySessionEffect

    /**
     * Send this generation's fence again: inline a targetless `select-window`,
     * side channel the window force at its target. Policy and the earlier ack
     * stand; this fence's settle probe proves landing again (§6.10 rule 4).
     */
    data class RefenceClaim(val generation: Long) : SharedTmuxAuthoritySessionEffect
}

/** The session's projection after a reduction. */
data class SharedTmuxAuthoritySessionState(
    val authority: SharedTmuxGridAuthoritySnapshot,
    val claim: SharedTmuxAuthorityLifecycleClaim?,
    val hasAttached: Boolean,
    /** True between `attached` and `resetTransport`. */
    val channelAttached: Boolean,
    /** Attached, not reported dead, and no read overdue. */
    val channelLive: Boolean,
    val nextGeneration: Long,
    val pendingIntent: SharedTmuxAuthorityIntent?,
    val hidden: Boolean,
    val presentation: SharedTmuxAuthorityPresentation,
    /** Keys reach the shell only while this is false. */
    val gatesTyping: Boolean,
    val mutationRefusal: SharedTmuxAuthorityMutationRefusal?,
    val geometryHold: SharedTmuxAuthorityGeometryHold,
    /**
     * Evaluated at the `nowMillis` of the reply that carried this state. Read
     * it fresh with [SharedTmuxAuthoritySession.snapshot] when replacing the
     * session object.
     */
    val carriedShow: SharedTmuxAuthorityCarriedShow?,
    /** When to call [SharedTmuxAuthoritySession.tick]; null when nothing is pending. */
    val nextDeadlineMillis: Long?,
    /** §6.10 rule 2: only a live claim with visible presentation sends geometry. */
    val claimMayAdvertiseGeometry: Boolean = claim?.presentationVisible == true,
    /**
     * The read whose reply decides; null when none is outstanding. One
     * reduction can replace a due retry with a newer read, so a
     * [SharedTmuxAuthoritySessionEffect.QueryAuthority] is sent only while
     * its id is still this one.
     */
    val currentQueryId: Long? = null,
    /** The live claim's latest fence; null before its first fence and outside a claim. */
    val claimFence: SharedTmuxAuthorityClaimFence? = null,
)

data class SharedTmuxAuthoritySessionResult(
    val state: SharedTmuxAuthoritySessionState,
    val effects: List<SharedTmuxAuthoritySessionEffect>,
    /** The core's one-line description of this reduction, identical to iOS's; null when unchanged. */
    val trace: String?,
    /** False for the core's unchanged reply: [state] is the previous one. */
    val changed: Boolean,
)

/**
 * Stateful JNI projection of the core's `TmuxGridAuthoritySession` (lifecycle
 * ABI version 2): the show rule's authority reads, geometry hold, intent
 * clock, claim fence confirmation, claim replay and the projection to render,
 * so the adapter reports facts and performs effects.
 *
 * Every call takes `nowMillis` on one monotonic clock that keeps running
 * while the device sleeps. The session owns no timer: schedule [tick] at
 * [state]'s `nextDeadlineMillis`. A call that changed nothing returns a
 * result with `changed` false and no effects without parsing JSON.
 *
 * The handle accepts version 2 requests only.
 *
 * Facts the wire cannot carry never throw: a non-positive size is dropped
 * (logged once), a reply the core rejects is reported as a failed read, a
 * peer stamp whose device ID the stamp parser would refuse is ignored (logged
 * once) and a longer name is cut as the parser cuts it. Every other request
 * the core rejects is an adapter bug and throws.
 *
 * A session created while the app is in the background must hear
 * [backgrounded] before [attached]: it starts active, and its attach read
 * would otherwise size the grid from the background.
 */
class SharedTmuxAuthoritySession internal constructor(
    handle: Long,
    initial: SharedTmuxAuthoritySessionState,
    /** The core's reduction; null when it rejected the request. A seam for JVM tests. */
    private val reduceRequest: (Long, JSONObject) -> ByteArray? = { native, request -> reduceNativeOrNull(native, request) },
    private val warn: (String) -> Unit = { message -> Log.w(TAG, message) },
) : AutoCloseable {
    private val nativeHandle = AtomicLong(handle)
    private val droppedSizeLogged = AtomicBoolean(false)
    private val rejectedReplyLogged = AtomicBoolean(false)
    private val rejectedObservationLogged = AtomicBoolean(false)

    @Volatile
    private var unchanged = SharedTmuxAuthoritySessionResult(initial, emptyList(), null, changed = false)

    /** The projection after the last reduction. */
    val state: SharedTmuxAuthoritySessionState get() = unchanged.state

    /** The native handle a runtime reduces stamps into; 0 once closed. */
    internal val runtimeHandle: Long get() = nativeHandle.get()

    /**
     * Takes a reduction the attached runtime made ([SharedTmuxEvent.authoritySession])
     * as this session's latest, as if it had been one of its own calls.
     */
    @Synchronized
    fun adopt(result: SharedTmuxAuthoritySessionResult): SharedTmuxAuthoritySessionResult {
        if (result.changed) unchanged = SharedTmuxAuthoritySessionResult(result.state, emptyList(), null, changed = false)
        adoptions += 1
        return result
    }

    /** How many runtime results [adopt] took: a feed's runtime counts its own. */
    @Volatile
    internal var adoptions = 0L
        private set

    /** A control channel attached. Reads, never claims. */
    fun attached(nowMillis: Long, localDeviceId: String? = null): SharedTmuxAuthoritySessionResult =
        submit(Requests.attached(nowMillis, localDeviceId))

    fun resetTransport(nowMillis: Long, preservingPeer: Boolean): SharedTmuxAuthoritySessionResult =
        submit(Requests.resetTransport(nowMillis, preservingPeer))

    /** Whether the attached control channel can carry a command now. */
    fun channelLiveness(nowMillis: Long, live: Boolean): SharedTmuxAuthoritySessionResult =
        submit(Requests.channelLiveness(nowMillis, live))

    /** A show edge or explicit open. [stepAtMillis] is the user's step when it precedes delivery. */
    fun shown(
        nowMillis: Long,
        source: SharedTmuxAuthorityShowSource = SharedTmuxAuthorityShowSource.SHOW,
        stepAtMillis: Long = nowMillis,
    ): SharedTmuxAuthoritySessionResult = submit(Requests.shown(nowMillis, source, stepAtMillis))

    /** This session object replaced the one behind a shown slot. */
    fun adoptShown(nowMillis: Long): SharedTmuxAuthoritySessionResult = submit(Requests.bare("adoptShown", nowMillis))
    fun hidden(nowMillis: Long): SharedTmuxAuthoritySessionResult = submit(Requests.bare("hidden", nowMillis))

    /** The veil gesture. */
    fun requestTakeBack(nowMillis: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.bare("requestTakeBack", nowMillis))

    /** The pending-state cancel: ends the intent as its expiry would. Not a hide. */
    fun cancelIntent(nowMillis: Long): SharedTmuxAuthoritySessionResult = submit(Requests.bare("cancelIntent", nowMillis))

    /** A prompt answered or Retry: the intent window restarts. */
    fun userStep(nowMillis: Long): SharedTmuxAuthoritySessionResult = submit(Requests.bare("userStep", nowMillis))

    fun prompt(nowMillis: Long, scope: SharedTmuxAuthorityPromptScope, active: Boolean): SharedTmuxAuthoritySessionResult =
        submit(Requests.prompt(nowMillis, scope, active))

    /** Ordinary geometry is withheld until the foreground read resolves it. Not a hide. */
    fun backgrounded(nowMillis: Long): SharedTmuxAuthoritySessionResult = submit(Requests.bare("backgrounded", nowMillis))
    fun foregrounded(nowMillis: Long): SharedTmuxAuthoritySessionResult = submit(Requests.bare("foregrounded", nowMillis))

    /**
     * A classified authority observation, held to the stamp parser's bounds before it crosses:
     * a peer device ID the parser would refuse changes nothing (the next read decides), and a
     * longer peer name is cut as the parser cuts it. Anything else the core rejects (a
     * negative clock or generation) is an adapter bug and throws.
     */
    fun observedAuthority(nowMillis: Long, authority: SharedTmuxGridAuthoritySnapshot): SharedTmuxAuthoritySessionResult {
        val bounded = authority.withinStampBounds() ?: run {
            if (rejectedObservationLogged.compareAndSet(false, true)) {
                // Never the identity itself: it names a device.
                warn("tmux authority observation: a peer device ID past the stamp bound; ignored")
            }
            return unchanged
        }
        return submit(Requests.observedAuthority(nowMillis, bounded))
    }

    /** Raw subscription value: classification and own-write continuation share one reduction. */
    fun stampObserved(nowMillis: Long, raw: String): SharedTmuxAuthoritySessionResult =
        submit(Requests.stampObserved(nowMillis, raw))

    /**
     * One JNI reduction for an entire batch, preserving every stamp's arrival order. The
     * runtime bounds each value to a canonical stamp's length; a batch past
     * [MAXIMUM_STAMPS_PER_REQUEST] (tmux reports a changed stamp at most once a second, so
     * only a long backlog) is reduced part by part, in order, as one result.
     */
    fun stampsObserved(nowMillis: Long, rawValues: List<String>): SharedTmuxAuthoritySessionResult {
        if (rawValues.isEmpty()) return unchanged
        if (rawValues.size == 1) return stampObserved(nowMillis, rawValues.single())
        if (rawValues.size <= MAXIMUM_STAMPS_PER_REQUEST) return submit(Requests.stampsObserved(nowMillis, rawValues))
        val parts = rawValues.chunked(MAXIMUM_STAMPS_PER_REQUEST).map { stampsObserved(nowMillis, it) }
        return SharedTmuxAuthoritySessionResult(
            state = parts.last().state,
            effects = parts.flatMap { it.effects },
            trace = parts.mapNotNull { it.trace }.takeIf { it.isNotEmpty() }?.joinToString("\n"),
            changed = parts.any { it.changed },
        )
    }

    fun ownStampObserved(nowMillis: Long, generation: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.generation("ownStampObserved", nowMillis, generation))

    /**
     * The raw reply to [SharedTmuxAuthoritySessionEffect.QueryAuthority] [queryId]. A reply the
     * core cannot take (one too large for the wire) is reported as [queryFailed] instead, so the
     * read retries and then fails closed rather than staying outstanding.
     */
    fun queryReplied(
        nowMillis: Long,
        queryId: Long,
        rawValue: String,
        localDeviceId: String? = null,
    ): SharedTmuxAuthoritySessionResult =
        submitOrNull(Requests.queryReplied(nowMillis, queryId, rawValue, localDeviceId)) ?: run {
            if (rejectedReplyLogged.compareAndSet(false, true)) {
                // Never the value itself: a stamp names a device.
                warn("tmux authority read r$queryId: the core rejected its ${rawValue.length}-char reply; reported failed")
            }
            queryFailed(nowMillis, queryId)
        }

    fun queryFailed(nowMillis: Long, queryId: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.queryFailed(nowMillis, queryId))

    /**
     * Send only on change: the core compares, but each call still crosses JNI. A non-positive
     * window size is sent as an unknown layout.
     */
    fun windowFacts(
        nowMillis: Long,
        hydrated: Boolean,
        activeWindow: SharedTmuxAuthorityActiveWindow?,
    ): SharedTmuxAuthoritySessionResult {
        activeWindow?.size?.takeUnless { it.isWireSize }?.let { noteDroppedSize("windowFacts", it) }
        return submit(Requests.windowFacts(nowMillis, hydrated, activeWindow))
    }

    /**
     * The client size this device would advertise now; null before it is measured. A
     * non-positive size (a view collapsed mid-layout) changes nothing.
     */
    fun localSize(nowMillis: Long, size: SharedTmuxGridSize?): SharedTmuxAuthoritySessionResult =
        Requests.localSize(nowMillis, size)?.let(::submit) ?: droppedSize("localSize", size)

    /** A policy read; [fenceId] names the claim fence it was queued behind. */
    fun windowSizePolicyReplied(
        nowMillis: Long, windowId: Int, rawPolicy: String, fenceId: Long? = null,
    ): SharedTmuxAuthoritySessionResult =
        submit(Requests.windowSizePolicyReplied(nowMillis, windowId, rawPolicy, fenceId))

    /** An ordinary advertisement; while a claim exists use [claimAdvertisedGeometry]. A non-positive size changes nothing. */
    fun sizeAdvertised(nowMillis: Long, size: SharedTmuxGridSize): SharedTmuxAuthoritySessionResult =
        Requests.sizeAdvertised(nowMillis, size)?.let(::submit) ?: droppedSize("sizeAdvertised", size)

    fun ordinaryRecovery(nowMillis: Long, active: Boolean, proven: Boolean = false): SharedTmuxAuthoritySessionResult =
        submit(Requests.ordinaryRecovery(nowMillis, active, proven))

    /** A render surface could carry a claim's repaint now. */
    fun paintable(nowMillis: Long, paintable: Boolean): SharedTmuxAuthoritySessionResult =
        submit(Requests.paintable(nowMillis, paintable))

    fun controlSessionChanged(nowMillis: Long, replacedKnownSession: Boolean): SharedTmuxAuthoritySessionResult =
        submit(Requests.controlSessionChanged(nowMillis, replacedKnownSession))

    /** A new fence for the live claim on [windowId]; only replies tagged with `claimFence.id` count. */
    fun claimFenceSent(nowMillis: Long, generation: Long, windowId: Int): SharedTmuxAuthoritySessionResult =
        submit(Requests.claimFenceSent(nowMillis, generation, windowId))

    /** tmux answered [fenceId]: everything queued before the fence has run. */
    fun claimFenceAcknowledged(nowMillis: Long, fenceId: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.claimFenceAcknowledged(nowMillis, fenceId))

    /** A window force for [fenceId] still awaits its proof ([outstanding]), or has it. */
    fun claimFenceForce(nowMillis: Long, fenceId: Long, outstanding: Boolean): SharedTmuxAuthoritySessionResult =
        submit(Requests.claimFenceForce(nowMillis, fenceId, outstanding))

    /** The render path applied the layout: confirm a settled fence where its repaint may start. */
    fun confirmClaimFence(nowMillis: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.confirmClaimFence(nowMillis))

    /**
     * The claim's begin replay or visible churn, with its own fence. A late
     * report changes nothing; in the geometry phases this re-targets the
     * claim and drops its repaint. A non-positive grid never crosses JNI.
     */
    fun claimAdvertisedGeometry(
        nowMillis: Long, generation: Long, columns: Int, rows: Int,
    ): SharedTmuxAuthoritySessionResult =
        Requests.claimAdvertisedGeometry(nowMillis, generation, columns, rows)?.let(::submit)
            ?: droppedSize("claimAdvertisedGeometry", SharedTmuxGridSize(columns, rows))

    /**
     * A claimed-window observation under `latest`; [settleProbe] marks the
     * latest fence landed before classifying the grid (§6.10 rules 3–5).
     * A landed foreign size re-fences once while visible, else aborts.
     */
    fun claimObservedGeometry(
        nowMillis: Long, generation: Long, columns: Int, rows: Int, settleProbe: Boolean,
    ): SharedTmuxAuthoritySessionResult =
        Requests.claimObservedGeometry(nowMillis, generation, columns, rows, settleProbe)?.let(::submit)
            ?: droppedSize("claimObservedGeometry", SharedTmuxGridSize(columns, rows))

    fun claimGeometryLost(nowMillis: Long, generation: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.generation("claimGeometryLost", nowMillis, generation))

    /** A visible claim that can progress returns to geometry; anything else aborts as adapterFailure. */
    fun claimStalled(nowMillis: Long, generation: Long, canProgress: Boolean): SharedTmuxAuthoritySessionResult =
        submit(Requests.claimStalled(nowMillis, generation, canProgress))
    fun repaintSucceeded(nowMillis: Long, generation: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.generation("repaintSucceeded", nowMillis, generation))
    fun stampCommitSucceeded(nowMillis: Long, generation: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.generation("stampCommitSucceeded", nowMillis, generation))
    fun settle(nowMillis: Long, generation: Long): SharedTmuxAuthoritySessionResult =
        submit(Requests.generation("settle", nowMillis, generation))

    fun abort(
        nowMillis: Long,
        generation: Long,
        reason: SharedTmuxAuthorityAbortReason = SharedTmuxAuthorityAbortReason.ADAPTER_FAILURE,
    ): SharedTmuxAuthoritySessionResult = submit(Requests.abort(nowMillis, generation, reason))

    /** A deadline passed; see `nextDeadlineMillis`. */
    fun tick(nowMillis: Long): SharedTmuxAuthoritySessionResult = submit(Requests.bare("tick", nowMillis))

    /** Reads the projection without advancing it, with [SharedTmuxAuthoritySessionState.carriedShow] at [nowMillis]. */
    fun snapshot(nowMillis: Long): SharedTmuxAuthoritySessionState = submit(Requests.bare("snapshot", nowMillis)).state

    private fun submit(request: JSONObject): SharedTmuxAuthoritySessionResult =
        checkNotNull(submitOrNull(request)) { "shared tmux authority session rejected ${request.optString("event")}" }

    /** Null when the core rejected [request], which then changed nothing. */
    @Synchronized
    private fun submitOrNull(request: JSONObject): SharedTmuxAuthoritySessionResult? {
        val handle = nativeHandle.get()
        check(handle != 0L) { "tmux authority session is closed" }
        val response = reduceRequest(handle, request) ?: return null
        // Ticks and repeated facts usually change nothing; skip the JSON parse.
        if (response.contentEquals(UNCHANGED_RESPONSE)) return unchanged
        val result = checkNotNull(parse(JSONObject(response.decodeToString())))
        unchanged = SharedTmuxAuthoritySessionResult(result.state, emptyList(), null, changed = false)
        return result
    }

    override fun close() {
        val handle = nativeHandle.getAndSet(0)
        if (handle != 0L) NativeCoreBindings.destroyTmuxAuthorityLifecycle(handle)
    }

    /** The wire carries only positive grids; the core would reject the request. */
    private fun droppedSize(event: String, size: SharedTmuxGridSize?): SharedTmuxAuthoritySessionResult {
        size?.let { noteDroppedSize(event, it) }
        return unchanged
    }

    private fun noteDroppedSize(event: String, size: SharedTmuxGridSize) {
        if (droppedSizeLogged.compareAndSet(false, true)) {
            warn("tmux authority $event: dropped the non-positive size ${size.columns}x${size.rows}")
        }
    }

    /** The version 2 request for each event; the field names are the core's. */
    internal object Requests {
        private const val VERSION = 2

        fun bare(event: String, nowMillis: Long): JSONObject =
            JSONObject().put("version", VERSION).put("event", event).put("nowMillis", nowMillis)

        fun attached(nowMillis: Long, localDeviceId: String?): JSONObject =
            bare("attached", nowMillis).apply { localDeviceId?.let { put("localDeviceID", it) } }

        fun resetTransport(nowMillis: Long, preservingPeer: Boolean): JSONObject =
            bare("resetTransport", nowMillis).put("preservingPeer", preservingPeer)

        fun channelLiveness(nowMillis: Long, live: Boolean): JSONObject =
            bare("channelLiveness", nowMillis).put("channelLive", live)

        fun shown(nowMillis: Long, source: SharedTmuxAuthorityShowSource, stepAtMillis: Long): JSONObject =
            bare("shown", nowMillis).put("source", source.wireValue).put("stepAtMillis", stepAtMillis)

        fun prompt(nowMillis: Long, scope: SharedTmuxAuthorityPromptScope, active: Boolean): JSONObject =
            bare("prompt", nowMillis).put("scope", scope.wireValue).put("active", active)

        fun stampObserved(nowMillis: Long, raw: String): JSONObject =
            bare("stampObserved", nowMillis).put("raw", raw)

        fun stampsObserved(nowMillis: Long, rawValues: List<String>): JSONObject =
            bare("stampObserved", nowMillis).put("rawValues", JSONArray(rawValues))

        fun observedAuthority(nowMillis: Long, authority: SharedTmuxGridAuthoritySnapshot): JSONObject =
            bare("observedAuthority", nowMillis).apply { authority.putWireFields(this) }

        fun generation(event: String, nowMillis: Long, generation: Long): JSONObject =
            bare(event, nowMillis).put("generation", generation)

        fun claimFenceSent(nowMillis: Long, generation: Long, windowId: Int): JSONObject =
            generation("claimFenceSent", nowMillis, generation).put("windowID", windowId)

        fun claimFenceAcknowledged(nowMillis: Long, fenceId: Long): JSONObject =
            bare("claimFenceAcknowledged", nowMillis).put("fenceID", fenceId)

        fun claimFenceForce(nowMillis: Long, fenceId: Long, outstanding: Boolean): JSONObject =
            bare("claimFenceForce", nowMillis).put("fenceID", fenceId).put("outstanding", outstanding)

        fun confirmClaimFence(nowMillis: Long): JSONObject = bare("confirmClaimFence", nowMillis)

        fun claimAdvertisedGeometry(nowMillis: Long, generation: Long, columns: Int, rows: Int): JSONObject? =
            claimGeometry("claimAdvertisedGeometry", nowMillis, generation, columns, rows)

        fun claimObservedGeometry(
            nowMillis: Long, generation: Long, columns: Int, rows: Int, settleProbe: Boolean,
        ): JSONObject? =
            claimGeometry("claimObservedGeometry", nowMillis, generation, columns, rows)?.put("settleProbe", settleProbe)

        private fun claimGeometry(event: String, nowMillis: Long, generation: Long, columns: Int, rows: Int): JSONObject? =
            SharedTmuxGridSize(columns, rows).takeIf { it.isWireSize }?.let {
                generation(event, nowMillis, generation).put("columns", columns).put("rows", rows)
            }

        fun claimStalled(nowMillis: Long, generation: Long, canProgress: Boolean): JSONObject =
            generation("claimStalled", nowMillis, generation).put("canProgress", canProgress)

        fun queryReplied(nowMillis: Long, queryId: Long, rawValue: String, localDeviceId: String?): JSONObject =
            bare("queryReplied", nowMillis)
                .put("queryID", queryId)
                .put("rawAuthorityValue", rawValue)
                .apply { localDeviceId?.let { put("localDeviceID", it) } }

        fun queryFailed(nowMillis: Long, queryId: Long): JSONObject =
            bare("queryFailed", nowMillis).put("queryID", queryId)

        /** A non-positive window size is left out: the layout is unknown. */
        fun windowFacts(nowMillis: Long, hydrated: Boolean, activeWindow: SharedTmuxAuthorityActiveWindow?): JSONObject =
            bare("windowFacts", nowMillis).put("windowListHydrated", hydrated).apply {
                activeWindow?.let { window ->
                    put("windowID", window.id)
                    put("windowAuthoritative", window.authoritative)
                    window.size?.takeIf { it.isWireSize }?.let { size ->
                        put("windowColumns", size.columns)
                        put("windowRows", size.rows)
                    }
                }
            }

        /** Null for a non-positive size, which the core rejects. */
        fun localSize(nowMillis: Long, size: SharedTmuxGridSize?): JSONObject? {
            if (size != null && !size.isWireSize) return null
            return bare("localSize", nowMillis).apply {
                size?.let {
                    put("columns", it.columns)
                    put("rows", it.rows)
                }
            }
        }

        fun windowSizePolicyReplied(
            nowMillis: Long, windowId: Int, rawPolicy: String, fenceId: Long? = null,
        ): JSONObject =
            bare("windowSizePolicyReplied", nowMillis).put("windowID", windowId).put("rawPolicy", rawPolicy)
                .apply { fenceId?.let { put("fenceID", it) } }

        /** Null for a non-positive size, which the core rejects. */
        fun sizeAdvertised(nowMillis: Long, size: SharedTmuxGridSize): JSONObject? =
            size.takeIf { it.isWireSize }?.let {
                bare("sizeAdvertised", nowMillis).put("columns", it.columns).put("rows", it.rows)
            }

        fun ordinaryRecovery(nowMillis: Long, active: Boolean, proven: Boolean): JSONObject =
            bare("ordinaryRecovery", nowMillis).put("active", active).put("proven", proven)

        fun paintable(nowMillis: Long, paintable: Boolean): JSONObject =
            bare("paintable", nowMillis).put("paintable", paintable)

        fun controlSessionChanged(nowMillis: Long, replacedKnownSession: Boolean): JSONObject =
            bare("controlSessionChanged", nowMillis).put("replacedKnownSession", replacedKnownSession)

        fun abort(nowMillis: Long, generation: Long, reason: SharedTmuxAuthorityAbortReason): JSONObject =
            generation("abort", nowMillis, generation).put("reason", reason.wireValue)
    }

    companion object {
        private const val TAG = "TesseraTmuxAuthority"
        /**
         * Stamps per request. A bounded value escapes to at most six JSON bytes per byte
         * (`TmuxGridAuthorityStamp.maximumWireBytes` is 216), so this many stay well inside
         * the session's 64 KiB request bound.
         */
        const val MAXIMUM_STAMPS_PER_REQUEST = 32
        private val UNCHANGED_RESPONSE = """{"version":2,"unchanged":true}""".encodeToByteArray()

        fun create(initialGeneration: Long? = null): SharedTmuxAuthoritySession {
            require(initialGeneration == null || initialGeneration >= 0)
            NativeLibraries.ensureLoaded()
            val handle = if (initialGeneration == null) NativeCoreBindings.createTmuxAuthorityLifecycle()
            else NativeCoreBindings.createTmuxAuthorityLifecycleSeeded(initialGeneration)
            check(handle != 0L) { "shared tmux authority session is unavailable" }
            // A fresh session is hidden, so its carried show is null at any time.
            val initial = runCatching {
                val response = checkNotNull(reduceNativeOrNull(handle, Requests.bare("snapshot", 0))) {
                    "shared tmux authority session rejected snapshot"
                }
                checkNotNull(parse(JSONObject(response.decodeToString())))
            }.getOrElse { error ->
                NativeCoreBindings.destroyTmuxAuthorityLifecycle(handle)
                throw error
            }
            return SharedTmuxAuthoritySession(handle, initial.state)
        }

        private fun reduceNativeOrNull(handle: Long, request: JSONObject): ByteArray? {
            val bytes = request.toString().encodeToByteArray()
            return NativeCoreBindings.reduceTmuxAuthorityLifecycle(handle, bytes.toDirectBuffer(), bytes.size)
        }

        /** Null for the core's unchanged reply. */
        internal fun parse(value: JSONObject): SharedTmuxAuthoritySessionResult? {
            require(value.getInt("version") == 2)
            if (value.optBoolean("unchanged", false)) return null
            val effects = value.getJSONArray("effects")
            val presentation = value.getJSONObject("presentation")
            val state = SharedTmuxAuthoritySessionState(
                authority = value.authority(),
                claim = value.optJSONObject("claim")?.claim(),
                hasAttached = value.getBoolean("hasAttached"),
                channelAttached = value.getBoolean("channelAttached"),
                channelLive = value.getBoolean("channelLive"),
                nextGeneration = value.getLong("nextGeneration"),
                pendingIntent = value.optJSONObject("pendingIntent")?.intent(),
                hidden = value.getBoolean("hidden"),
                presentation = when (presentation.getString("kind")) {
                    "none" -> SharedTmuxAuthorityPresentation.None
                    "resuming" -> SharedTmuxAuthorityPresentation.Resuming(presentation.getBoolean("awaitingConnection"))
                    "veiled" -> SharedTmuxAuthorityPresentation.Veiled(presentation.getString("peerName"))
                    "reclaiming" -> SharedTmuxAuthorityPresentation.Reclaiming(
                        presentation.getString("peerName"),
                        presentation.getBoolean("awaitingConnection"),
                    )
                    else -> error("unknown tmux authority presentation")
                },
                gatesTyping = value.getBoolean("gatesTyping"),
                mutationRefusal = value.optionalString("mutationRefusal")
                    ?.let(SharedTmuxAuthorityMutationRefusal::fromWire),
                geometryHold = SharedTmuxAuthorityGeometryHold.fromWire(value.getString("geometryHold")),
                carriedShow = value.optJSONObject("carriedShow")?.let { carried ->
                    SharedTmuxAuthorityCarriedShow(
                        SharedTmuxAuthorityShowSource.fromWire(carried.getString("source")),
                        carried.getLong("stepAtMillis"),
                    )
                },
                nextDeadlineMillis = value.takeIf { it.has("nextDeadlineMillis") && !it.isNull("nextDeadlineMillis") }
                    ?.getLong("nextDeadlineMillis"),
                claimMayAdvertiseGeometry = if (value.has("claimMayAdvertiseGeometry")) {
                    value.getBoolean("claimMayAdvertiseGeometry")
                } else value.optJSONObject("claim")?.optBoolean("presentationVisible", false) == true,
                currentQueryId = value.takeIf { it.has("currentQueryID") && !it.isNull("currentQueryID") }
                    ?.getLong("currentQueryID"),
                claimFence = value.optJSONObject("claimFence")?.claimFence(),
            )
            return SharedTmuxAuthoritySessionResult(
                state = state,
                effects = buildList {
                    repeat(effects.length()) { add(effects.getJSONObject(it).sessionEffect()) }
                },
                trace = value.optionalString("trace"),
                changed = true,
            )
        }
    }
}

/** The version 2 wire carries only positive grids. */
private val SharedTmuxGridSize.isWireSize: Boolean get() = columns > 0 && rows > 0

private fun JSONObject.claim(): SharedTmuxAuthorityLifecycleClaim =
    SharedTmuxAuthorityLifecycleClaim(
        generation = getLong("generation"),
        reason = SharedTmuxAuthorityClaimReason.fromWire(getString("reason")),
        phase = SharedTmuxAuthorityClaimPhase.fromWire(getString("phase")),
        presentationVisible = getBoolean("presentationVisible"),
        contestedPeer = optJSONObject("contestedPeer")?.peer(),
        geometryRefenced = optBoolean("geometryRefenced", false),
        advertisedGrids = optJSONArray("advertisedGrids")?.let { grids ->
            List(grids.length()) { grids.getJSONObject(it).grid() }
        }.orEmpty(),
        targetGrid = optJSONObject("targetGrid")?.grid(),
        geometryLanded = optBoolean("geometryLanded", false),
    )

private fun JSONObject.claimFence(): SharedTmuxAuthorityClaimFence =
    SharedTmuxAuthorityClaimFence(
        generation = getLong("generation"),
        id = getLong("id"),
        windowId = getInt("windowID"),
        acknowledged = getBoolean("acknowledged"),
        policyIsLatest = takeIf { has("policyIsLatest") && !isNull("policyIsLatest") }
            ?.getBoolean("policyIsLatest"),
        probeOffTarget = getBoolean("probeOffTarget"),
        forceOutstanding = getBoolean("forceOutstanding"),
    )

private fun JSONObject.intent(): SharedTmuxAuthorityIntent =
    SharedTmuxAuthorityIntent(
        token = getLong("token"),
        source = SharedTmuxAuthorityIntentSource.fromWire(getString("source")),
        baseline = optJSONObject("baseline")?.peer(),
        baselineKnown = getBoolean("baselineKnown"),
    )

private fun JSONObject.sessionEffect(): SharedTmuxAuthoritySessionEffect = when (getString("kind")) {
    "queryAuthority" -> SharedTmuxAuthoritySessionEffect.QueryAuthority(getLong("queryID"))
    "beginClaim" -> SharedTmuxAuthoritySessionEffect.BeginClaim(
        getLong("generation"),
        SharedTmuxAuthorityClaimReason.fromWire(getString("reason")),
        optBoolean("presentationVisible", false),
    )
    "requestRepaint" -> SharedTmuxAuthoritySessionEffect.RequestRepaint(getLong("generation"))
    "commitAuthorityStamp" -> SharedTmuxAuthoritySessionEffect.CommitAuthorityStamp(getLong("generation"))
    "refenceClaim" -> SharedTmuxAuthoritySessionEffect.RefenceClaim(getLong("generation"))
    "authorityChanged" -> SharedTmuxAuthoritySessionEffect.AuthorityChanged(authority())
    "hideReclaimPresentation" -> SharedTmuxAuthoritySessionEffect.HideReclaimPresentation
    "claimAborted" -> SharedTmuxAuthoritySessionEffect.ClaimAborted(
        reason = getString("reason"),
        peer = takeIf { optString("authorityKind") == "peer" }
            ?.authority() as? SharedTmuxGridAuthoritySnapshot.Peer,
    )
    "claimSettled" -> SharedTmuxAuthoritySessionEffect.ClaimSettled(getLong("generation"))
    "releaseGeometry" -> SharedTmuxAuthoritySessionEffect.ReleaseGeometry(
        SharedTmuxAuthorityGeometryRelease.fromWire(getString("release")),
    )
    "raiseStamplessPeer" -> SharedTmuxAuthoritySessionEffect.RaiseStamplessPeer
    "controlChannelUnresponsive" -> SharedTmuxAuthoritySessionEffect.ControlChannelUnresponsive
    else -> error("unknown tmux authority session effect")
}
