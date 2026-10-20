package com.bambouville.tessera.core.bridge

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject

/**
 * Native proof issuance is not a general Agent ABI command.  Only the
 * coordinator-owned endpoint authority opts in; feature modules must use its
 * typed endpoint/proof path and cannot silently self-attest JSON authority.
 */
@RequiresOptIn(
    message = "Only coordinator-owned endpoint authority may register Agent route proof",
    level = RequiresOptIn.Level.ERROR,
)
annotation class CoordinatorOnlyAgentRouteAuthority

/**
 * Typed Kotlin facade over the independently versioned Agent Core ABI.
 *
 * Agent reduction remains inside TesseraAgentCore. This class only validates
 * bounded canonical command bytes, copies JNI callback memory, fences stale
 * callback generations, and publishes immutable normalized snapshots.
 */
class SharedAgentRuntime private constructor(
    handle: Long,
    private val eventSink: NativeAgentEventSink,
) : AutoCloseable {
    private val nativeHandle = AtomicLong(handle)
    private val highestAcceptedGeneration = AtomicLong(0)
    private val mutableSnapshot = MutableStateFlow<SharedAgentSnapshot?>(null)
    private val mutableEvents = MutableSharedFlow<SharedAgentRuntimeEvent>(
        replay = 0,
        extraBufferCapacity = EVENT_BUFFER_CAPACITY,
    )

    // Core emits on its asynchronous, ordered worker, never inside JNI send.
    // Backpressure that worker when the bounded queue fills: parser replies,
    // action leases and commit results must not be dropped or pile up without
    // a memory bound. The UI only enqueues commands and never waits here.
    // close cancels the queue first to release a blocked callback.
    private val deliveryScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val queuedEvents = Channel<SharedAgentRuntimeEvent>(EVENT_BUFFER_CAPACITY)
    private val callbackLock = Any()
    init {
        deliveryScope.launch {
            for (event in queuedEvents) {
                mutableEvents.subscriptionCount.first { it > 0 }
                mutableEvents.emit(event)
            }
        }
    }

    /** The latest accepted immutable Agent snapshot, or null before the first callback. */
    val snapshot: StateFlow<SharedAgentSnapshot?> = mutableSnapshot.asStateFlow()

    /** Snapshot, failure, and notice callbacks after runtime-generation fencing. */
    val events: SharedFlow<SharedAgentRuntimeEvent> = mutableEvents.asSharedFlow()

    /**
     * Receives a fixed, content-free description of every callback that never
     * reached [events] because decoding failed. Accepted callbacks queue until
     * the collector can receive them. Called on the native callback thread.
     */
    @Volatile var droppedEventSink: ((Map<String, String>) -> Unit)? = null

    fun sendCanonical(command: ByteArray): CoreCallResult {
        require(command.size in 1..CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES.toInt()) {
            "Agent Core command must contain 1..${CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES} bytes"
        }
        return sendCanonical(command.toDirectBuffer())
    }

    fun sendCanonical(command: ByteBuffer): CoreCallResult {
        require(command.isDirect) { "Agent Core commands must use a direct ByteBuffer" }
        val count = command.remaining()
        require(count in 1..CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES.toInt()) {
            "Agent Core command must contain 1..${CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES} bytes"
        }
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.sendAgentRuntime(handle, command, command.position(), count).toCoreCallResult()
    }

    /**
     * Privileged route bridge only: turns freshly endpoint-verified process
     * facts into a one-use runtime-local proof handle. This is deliberately a
     * separate native entry point from canonical commands and binding exchange.
     */
    @CoordinatorOnlyAgentRouteAuthority
    fun issuePlatformRouteProof(registration: JSONObject): String? = platformResponse(
        registration.toString().encodeToByteArray(),
        NativeCoreBindings::registerAgentPlatformProof,
        "proofHandle",
    )

    /**
     * Privileged route bridge only: exchanges the one-use proof handle for a
     * binding token. Callers cannot submit PIDs through this registration.
     */
    @CoordinatorOnlyAgentRouteAuthority
    fun exchangePlatformRouteProof(registration: JSONObject): String? = platformResponse(
        registration.toString().encodeToByteArray(),
        NativeCoreBindings::registerAgentPlatformBinding,
        "bindingToken",
    )

    /**
     * Privileged Tier-C registration. The platform provides only fixed
     * provider IDs after a live, bounded data-route probe; native Core selects
     * the adapter ID and fixture digest from its compiled attestation.
     */
    @CoordinatorOnlyAgentRouteAuthority
    fun registerPlatformConformingProviders(providerIDs: Set<String>): Boolean {
        val allowed = setOf("opencode", "pi", "kimi")
        if (providerIDs.size > allowed.size || !providerIDs.all(allowed::contains)) return false
        val registration = JSONObject().put("providers", JSONArray(providerIDs.sorted()))
        val encoded = registration.toString().encodeToByteArray()
        if (encoded.size !in 1..4_096) return false
        val handle = nativeHandle.get()
        if (handle == 0L) return false
        return NativeCoreBindings.registerAgentPlatformConformances(
            handle, encoded.toDirectBuffer(), 0, encoded.size,
        ) == 0
    }

    /** Route-owner-only Tier-A registration. Canonical JSON is validated by
     * Core and creates an observe-only list candidate, never action authority. */
    @CoordinatorOnlyAgentRouteAuthority
    fun registerPlatformCandidate(registration: JSONObject): CoreCallResult {
        val encoded = registration.toString().encodeToByteArray()
        require(encoded.size in 1..32_768)
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.registerAgentPlatformCandidate(
            handle, encoded.toDirectBuffer(), 0, encoded.size,
        ).toCoreCallResult()
    }

    @CoordinatorOnlyAgentRouteAuthority
    fun removePlatformCandidate(registration: JSONObject): CoreCallResult {
        val encoded = registration.toString().encodeToByteArray()
        require(encoded.size in 1..2_048)
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.removeAgentPlatformCandidate(
            handle, encoded.toDirectBuffer(), 0, encoded.size,
        ).toCoreCallResult()
    }

    private fun platformResponse(
        authority: ByteArray,
        native: (Long, ByteBuffer, Int, Int, ByteBuffer, Int, Int) -> Int,
        responseKey: String,
    ): String? {
        require(authority.size in 1..16_384) { "Agent platform registration must contain 1..16384 bytes" }
        val handle = nativeHandle.get()
        if (handle == 0L) return null
        val request = authority.toDirectBuffer()
        val response = ByteBuffer.allocateDirect(16_384)
        val count = native(
            handle, request, 0, authority.size, response, 0, response.capacity(),
        )
        if (count !in 1..response.capacity()) return null
        val copied = ByteArray(count)
        response.position(0); response.get(copied)
        return runCatching {
            JSONObject(copied.decodeToString()).optString(responseKey).takeIf { token ->
                runCatching { java.util.UUID.fromString(token) }.isSuccess
            }
        }.getOrNull()
    }

    override fun close() {
        val handle = nativeHandle.getAndSet(0)
        if (handle == 0L) return
        queuedEvents.cancel()
        deliveryScope.cancel()
        NativeCoreBindings.destroyAgentRuntime(handle)
        eventSink.clear()
    }

    private fun receiveCallback(bytes: ByteArray) = synchronized(callbackLock) {
        if (nativeHandle.get() == 0L) return
        val event = runCatching { SharedAgentEventDecoder.decode(bytes) }.getOrElse { failure ->
            reportDropped(decodeFailureDiagnostics(bytes.size, failure))
            return
        }
        while (true) {
            val accepted = highestAcceptedGeneration.get()
            if (event.runtimeGeneration <= accepted) return
            if (highestAcceptedGeneration.compareAndSet(accepted, event.runtimeGeneration)) {
                break
            }
        }
        if (nativeHandle.get() == 0L) return
        if (event is SharedAgentRuntimeEvent.Snapshot) mutableSnapshot.value = event.snapshot
        queuedEvents.trySendBlocking(event)
        Unit
    }

    private fun reportDropped(fields: Map<String, String>) {
        droppedEventSink?.let { sink -> runCatching { sink(fields) } }
    }

    companion object {
        private const val EVENT_BUFFER_CAPACITY = 64

        /** Exception messages can quote payload text; only fixed codes leave. */
        internal fun decodeFailureDiagnostics(byteCount: Int, failure: Throwable): Map<String, String> = mapOf(
            "code" to ((failure as? SharedAgentEventDecodeException)?.code ?: "malformedJSON"),
            "errorType" to failure.javaClass.simpleName,
            "bytes" to byteCount.toString(),
        )

        fun create(): SharedAgentRuntime {
            val state = CoreBridge.inspectAgent()
            check(state is AgentBridgeState.Ready) {
                "Agent Core unavailable: ${(state as AgentBridgeState.Failed).reason}"
            }
            val sink = NativeAgentEventSink()
            val handle = NativeCoreBindings.createAgentRuntime(sink)
            check(handle != 0L) { "Agent Core refused to create a runtime" }
            return SharedAgentRuntime(handle, sink).also { runtime ->
                sink.activate(runtime::receiveCallback)
            }
        }
    }
}

/**
 * JNI callback sink. Native bytes are borrowed only for this call; this sink
 * copies them before publication and queues an early callback until the owning
 * [SharedAgentRuntime] is fully constructed.
 */
internal class NativeAgentEventSink {
    private companion object {
        const val MAX_PENDING_EVENTS = 64
    }

    private val callbackLock = Any()
    private val pending = ArrayDeque<ByteArray>()

    @Volatile
    private var listener: ((ByteArray) -> Unit)? = null

    @Suppress("unused") // Called by tessera_core_jni.cpp.
    fun onEvent(buffer: ByteBuffer) {
        val copy = ByteArray(buffer.remaining())
        buffer.get(copy)
        synchronized(callbackLock) {
            val receiver = listener
            if (receiver == null) {
                if (pending.size == MAX_PENDING_EVENTS) pending.removeFirst()
                pending += copy
            } else {
                receiver(copy)
            }
        }
    }

    fun activate(receiver: (ByteArray) -> Unit) {
        synchronized(callbackLock) {
            listener = receiver
            while (pending.isNotEmpty()) receiver(pending.removeFirst())
        }
    }

    fun clear() {
        synchronized(callbackLock) {
            listener = null
            pending.clear()
        }
    }
}
