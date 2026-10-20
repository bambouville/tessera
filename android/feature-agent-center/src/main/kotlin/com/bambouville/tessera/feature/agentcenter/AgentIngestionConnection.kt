package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentExecRequest
import com.bambouville.tessera.agent.platform.AgentRemoteExecStream
import com.bambouville.tessera.agent.platform.AgentSessionEndpoint
import com.bambouville.tessera.core.bridge.SharedAgentReadStatus
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.selects.select
import org.json.JSONObject

internal class AgentIngestionReadFailure(val status: SharedAgentReadStatus) : IllegalStateException(status.code)

/** Bounded multiplexing only; original page bytes go to the shared Swift
 * decoder/reducer. No provider parsing, lossy numeric conversion, or action
 * authority is implemented in Kotlin. */
internal class AgentIngestionConnection private constructor(
    private val endpoint: AgentSessionEndpoint,
    val binding: AgentEndpointBinding,
    private val stream: AgentRemoteExecStream,
    parent: CoroutineScope,
    private val diagnostics: ((String, Map<String, String>) -> Unit)?,
) : AutoCloseable {
    data class Reply(val end: JSONObject, val wire: ByteArray? = null, val inventory: List<JSONObject> = emptyList(),
        val sourceIdentity: String? = null, val firstOrder: String? = null)
    data class WindowCommit(val snapshot: JSONObject, val accepted: Boolean)
    private class Transaction(val inventoryPage: Boolean) {
        val bytes = ByteArrayOutputStream()
        var frames = 0
        val inventory = mutableListOf<JSONObject>()
        var sourceIdentity: String? = null
        var firstOrder: String? = null
    }
    private val scope = CoroutineScope(parent.coroutineContext + SupervisorJob(parent.coroutineContext[Job]))
    private val lock = Any()
    private val pending = linkedMapOf<String, CompletableDeferred<Reply>>()
    private class ReadProgress(val thread: String, val idleMillis: Long) {
        var deadlineNanos = System.nanoTime() + idleMillis * 1_000_000
        var sequence = 0uL
        var bytes = 0uL
        var sent = false
        val advanced = Channel<Unit>(Channel.CONFLATED)
    }
    private val readProgress = mutableMapOf<String, ReadProgress>()
    private val pendingThreads = mutableMapOf<String, String>()
    private data class SubscriptionRequest(val thread: String, var revoked: Boolean = false)
    private val pendingSubscriptions = mutableMapOf<String, SubscriptionRequest>()
    private val subscribedThreads = mutableSetOf<String>()
    private val pages = linkedMapOf<String, Transaction>() // reader-owned
    private val writer = Mutex()
    // A manual read must not cancel a watch transaction already committed by
    // Core but not yet ACKed on the wire. Never block the reader on a request.
    private val pausedWatches = mutableSetOf<String>()
    private val activeWatches = mutableMapOf<String, CompletableDeferred<Unit>>()
    private val activeControls = mutableSetOf<String>()
    private val reads = Semaphore(2)
    private val requests = AtomicInteger()
    private val closed = AtomicBoolean(false)
    private val hello = CompletableDeferred<Reply>()
    @Volatile private var epochValue: String? = null
    val epoch: String get() = checkNotNull(epochValue)
    val isClosed: Boolean get() = closed.get()
    var contextScope: String? = null; private set
    var supportsPiSessions: Boolean = false; private set
    var supportsOpenCodeSessions: Boolean = false; private set
    var supportsKimiSessions: Boolean = false; private set
    var supportsReadProgress: Boolean = false; private set
    /** Largest viewport this host accepts in `window.ack` (from its hello). */
    var maxWindowSegments: Int = LEGACY_WINDOW_SEGMENTS; private set
    fun supportsProvider(provider: String): Boolean = when (provider) {
        "codex", "claude" -> true
        "pi" -> supportsPiSessions
        "opencode" -> supportsOpenCodeSessions
        "kimi" -> supportsKimiSessions
        else -> false
    }
    @Volatile var onPage: (suspend (String, Reply) -> Boolean)? = null
    @Volatile var onWindowPage: (suspend (String, Reply) -> WindowCommit?)? = null
    private val windowLimits = java.util.concurrent.ConcurrentHashMap<String, Int>()
    @Volatile var onResync: (suspend (String) -> Unit)? = null
    @Volatile var onCapacity: (suspend (String) -> Unit)? = null
    @Volatile var onReadStatus: (suspend (String, SharedAgentReadStatus) -> Unit)? = null
    @Volatile var onReadComplete: (suspend (String) -> Unit)? = null
    // Latest accepted progress per thread (request id), so a terminal
    // read.complete or resync can end only the preparation it belongs to.
    private data class DisplayedReadProgress(val id: String, val sequence: ULong, val bytes: ULong)
    private val displayedReadProgress = mutableMapOf<String, DisplayedReadProgress>()
    internal fun isSubscribed(thread: String): Boolean = synchronized(lock) { !isClosed && thread in subscribedThreads }

    private suspend fun finishReadProgress(id: String, thread: String) {
        val finished = synchronized(lock) {
            if (displayedReadProgress[thread]?.id != id) false
            else { displayedReadProgress.remove(thread); true }
        }
        if (finished) onReadComplete?.invoke(thread)
    }

    companion object {
        internal fun validateTransactionFrame(inventoryPage: Boolean, kind: String, frames: Int, bytes: Int, totalBytes: Int) {
            when (kind) {
                "inventory.begin", "inventory.thread", "inventory.end" -> require(inventoryPage)
                "page.begin", "page.record", "page.end" -> require(!inventoryPage)
                else -> error("unknown transaction frame")
            }
            require(frames in 1..(if (inventoryPage) 502 else 102))
            if (kind == "inventory.thread") require(frames <= 501)
            require(bytes in 0..300_000)
            require(totalBytes in 0..1_048_576)
        }

        internal fun validateHello(value: JSONObject) {
            require(value.opt("v") == 3) // getInt coerces strings and fractions.
            val capabilities = value.getJSONArray("capabilities")
            require((0 until capabilities.length()).any { capabilities.opt(it) == "bounded.windows" })
            require((0 until capabilities.length()).any { capabilities.opt(it) == "window.partitions" })
        }

        internal fun helloSupportsPiSessions(value: JSONObject): Boolean {
            validateHello(value)
            val capabilities = value.getJSONArray("capabilities")
            return (0 until capabilities.length()).any { capabilities.opt(it) == "pi.sessions.v1-v3" }
        }
        internal fun helloSupportsOpenCodeSessions(value: JSONObject): Boolean {
            validateHello(value)
            val capabilities = value.getJSONArray("capabilities")
            return (0 until capabilities.length()).any { capabilities.opt(it) == "opencode.sqlite.v1-v2" }
        }
        internal fun helloSupportsKimiSessions(value: JSONObject): Boolean {
            validateHello(value)
            val capabilities = value.getJSONArray("capabilities")
            return (0 until capabilities.length()).any { capabilities.opt(it) == "kimi.wire.v1.4-v1.5" }
        }

        /** Hosts without `window.capacity.v1` accept four viewport segments.
         * A malformed advertisement (string, fraction, missing) never grows
         * the window: it reads as a legacy host. Core clamps the same range. */
        internal fun helloMaxWindowSegments(value: JSONObject): Int {
            validateHello(value)
            val capabilities = value.getJSONArray("capabilities")
            if ((0 until capabilities.length()).none { capabilities.opt(it) == "window.capacity.v1" }) return LEGACY_WINDOW_SEGMENTS
            val advertised = when (val raw = value.opt("maxWindowSegments")) {
                is Int -> raw.toLong()
                is Long -> raw
                else -> return LEGACY_WINDOW_SEGMENTS
            }
            return advertised.coerceIn(LEGACY_WINDOW_SEGMENTS.toLong(), MAXIMUM_WINDOW_SEGMENTS.toLong()).toInt()
        }

        internal const val LEGACY_WINDOW_SEGMENTS = 4
        internal const val MAXIMUM_WINDOW_SEGMENTS = 64
        private const val INLINE_PARSE_BYTES = 16 * 1024

        suspend fun open(endpoint: AgentSessionEndpoint, scope: CoroutineScope, contextPID: Int? = null, contextScope: String? = null,
                         diagnostics: ((String, Map<String, String>) -> Unit)? = null): AgentIngestionConnection {
            val binding = endpoint.ingestionBinding
            val hello = JSONObject().put("kind", "hello").put("id", "hello").put("v", 3)
            if (contextScope != null) {
                require(contextScope.matches(Regex("[0-9a-f]{16}"))); hello.put("contextScope", contextScope)
            } else contextPID?.let { require(it > 1); hello.put("contextPID", it) }
            val opened = endpoint.execute(binding, AgentExecRequest("tessera-agent-host",
                frame(hello)))
            val stream = (opened as? AgentEndpointResult.Success)?.value ?: run {
                diagnostics?.invoke("agent_ingestion_open_failed", mapOf("stage" to "exec", "code" to "execUnavailable",
                    "resultType" to opened.javaClass.simpleName, "transport" to binding.transport.name))
                error("execUnavailable")
            }
            val connection = AgentIngestionConnection(endpoint, binding, stream, scope, diagnostics)
            connection.start()
            try {
                val reply = withTimeout(15_000) { connection.hello.await() }
                validateHello(reply.end)
                val selectedScope = reply.end.optString("contextScope").takeIf { it.isNotEmpty() }
                require(selectedScope == null || selectedScope.matches(Regex("[0-9a-f]{16}")))
                require(contextScope == null || contextScope == selectedScope)
                require((contextPID == null && contextScope == null) || selectedScope != null)
                connection.contextScope = selectedScope
                connection.supportsPiSessions = helloSupportsPiSessions(reply.end)
                connection.supportsOpenCodeSessions = helloSupportsOpenCodeSessions(reply.end)
                connection.supportsKimiSessions = helloSupportsKimiSessions(reply.end)
                connection.supportsReadProgress = reply.end.getJSONArray("capabilities").let { values ->
                    (0 until values.length()).any { values.opt(it) == "read.progress.v1" }
                }
                connection.maxWindowSegments = helloMaxWindowSegments(reply.end)
                diagnostics?.invoke("agent_ingestion_opened", mapOf("transport" to binding.transport.name,
                    "contextPID" to (contextPID != null).toString(), "reusedScope" to (contextScope != null).toString(), "protocol" to "3",
                    "serviceEpoch" to connection.epoch, "contextScope" to (selectedScope ?: "default"),
                    "maxWindowSegments" to connection.maxWindowSegments.toString()))
                connection.scope.launch {
                    try {
                        while (!connection.isClosed) {
                            delay(10_000)
                            connection.request(JSONObject().put("kind", "heartbeat"))
                        }
                    } catch (failure: Throwable) { connection.reportFailure("heartbeat", failure); connection.close() }
                }
                return connection
            } catch (failure: Throwable) { connection.reportFailure("hello", failure); connection.close(); throw failure }
        }

        fun frame(value: JSONObject): ByteArray {
            val bytes = value.toString().encodeToByteArray()
            require(bytes.size in 1..65_536)
            return ByteBuffer.allocate(bytes.size + 4).putInt(bytes.size).put(bytes).array()
        }

        private fun identifier(value: String): Boolean = value.length in 1..128 && value.all {
            it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '_' || it == '-'
        }
    }

    suspend fun request(fields: JSONObject, timeoutMillis: Long = 15_000): Reply {
        require(timeoutMillis in 1..15_000)
        if (requests.incrementAndGet() > 16) { requests.decrementAndGet(); error("ingestion request budget") }
        var control: String? = null
        try {
            val kind = fields.getString("kind")
            if (kind in setOf("subscribe", "unsubscribe", "window.release")) {
                val thread = fields.getString("thread")
                synchronized(lock) { check(activeControls.add(thread)) { "controlBusy" } }
                control = thread
            }
            return if (kind in setOf("resolve", "inventory", "window.read", "summary")) {
                reads.withPermit {
                    var attempt = 0
                    while (true) {
                        try { return@withPermit requestNow(fields, timeoutMillis) }
                        catch (failure: IllegalStateException) {
                            // The server rejected admission, so no read or
                            // transaction was started. Retry only that code,
                            // bounded, cancellable, and with a fresh request ID.
                            if (failure.message != "busy" || attempt == 4) throw failure
                            delay(50L shl attempt++)
                        }
                    }
                    @Suppress("UNREACHABLE_CODE") error("unreachable")
                }
            } else requestNow(fields, timeoutMillis)
        } finally {
            control?.let { synchronized(lock) { activeControls.remove(it) } }
            requests.decrementAndGet()
        }
    }

    private suspend fun requestNow(fields: JSONObject, timeoutMillis: Long): Reply {
        check(!isClosed && endpoint.isCurrentIngestion(binding))
        val id = UUID.randomUUID().toString()
        val started = System.nanoTime()
        val deferred = CompletableDeferred<Reply>()
        val wireFields = JSONObject(fields.toString()).put("id", id)
        wireFields.remove("readProgress")
        val thread = fields.optString("thread")
        val progress = if (supportsReadProgress && thread.isNotEmpty() &&
            fields.optString("kind") in setOf("window.read", "summary", "bootstrap", "history", "updates")) {
            wireFields.put("readProgress", true)
            ReadProgress(thread, timeoutMillis)
        } else null
        if (supportsReadProgress && fields.optString("kind") == "subscribe") wireFields.put("readProgress", true)
        val control = fields.optString("kind") in setOf("subscribe", "unsubscribe", "window.release")
        var writeAttempted = false
        var completed = false
        var previousWatchPause: Boolean? = null
        if (fields.optString("kind") == "subscribe" && fields.optString("interest") == "fast")
            wireFields.put("limit", windowLimits[thread] ?: 100)
        synchronized(lock) {
            check(!isClosed); pending[id] = deferred
            pendingThreads[id] = thread
            if (fields.optString("kind") == "subscribe") pendingSubscriptions[id] = SubscriptionRequest(thread)
            if (progress != null) readProgress[id] = progress
        }
        try {
            suspend fun sendRequest() {
                val watch = synchronized(lock) {
                    when (fields.optString("kind")) {
                        "unsubscribe", "window.release" -> {
                            previousWatchPause = thread in pausedWatches
                            pausedWatches.add(thread)
                            activeWatches[thread]
                        }
                        "subscribe" -> {
                            previousWatchPause = thread in pausedWatches
                            pausedWatches.remove(thread); null
                        }
                        else -> null
                    }
                }
                watch?.await()
                send(frame(wireFields)) {
                    writeAttempted = true
                    synchronized(lock) { progress?.sent = true }
                }
            }
            val reply = if (progress == null) {
                withTimeout(timeoutMillis) { sendRequest(); deferred.await() }
            } else {
                withTimeout(timeoutMillis) { sendRequest() }
                awaitProgressRead(deferred, progress)
            }
            return reply.also {
                completed = true
                if (fields.optString("kind") == "window.release") windowLimits.remove(thread)
                if (control) synchronized(lock) {
                    if (fields.optString("kind") != "subscribe") subscribedThreads.remove(thread)
                }
                if (control && fields.optString("kind") != "subscribe") {
                    val watch = synchronized(lock) { displayedReadProgress[thread]?.id?.takeIf { it.startsWith("watch_") } }
                    if (watch != null) finishReadProgress(watch, thread)
                }
            }
        } catch (failure: Throwable) {
            // A cancelled control may already have changed remote ownership.
            // Retire only this duplex child instead of leaving an untracked
            // subscription alive until the whole app is relaunched.
            if (control && writeAttempted && failure is kotlinx.coroutines.CancellationException) close()
            reportFailure("request", failure, mapOf("request" to id,
                "operation" to fields.optString("kind").takeIf { it in setOf("resolve", "inventory", "window.read", "summary",
                    "subscribe", "unsubscribe", "window.release", "heartbeat", "bootstrap", "history", "receipt.frontier") }.orEmpty(),
                "elapsedMs" to ((System.nanoTime() - started) / 1_000_000).toString()))
            throw failure
        } finally {
            // Unsent cancellation and explicit rejection preserve the prior
            // watch gate while this request still owns activeControls.
            if (control && !completed && !isClosed) previousWatchPause?.let { wasPaused ->
                synchronized(lock) { if (wasPaused) pausedWatches.add(thread) else pausedWatches.remove(thread) }
            }
            synchronized(lock) {
                pending.remove(id); pendingThreads.remove(id); pendingSubscriptions.remove(id); readProgress.remove(id)?.advanced?.close()
            }; deferred.cancel()
            // Timeout/cancellation has no terminal wire reply. End only this
            // request's displayed progress, even in a cancelled caller; a
            // newer read or a typed failure keeps its own presentation.
            withContext(kotlinx.coroutines.NonCancellable) { finishReadProgress(id, thread) }
            if (!deferred.isCompleted || deferred.isCancelled) {
                if (fields.optString("kind") == "window.read") scope.launch {
                    try { cancelWindow(id, fields.getString("thread")) } catch (_: Throwable) { close() }
                }
            }
        }
    }

    private suspend fun awaitProgressRead(deferred: CompletableDeferred<Reply>, progress: ReadProgress): Reply {
        while (true) {
            if (deferred.isCompleted) return deferred.await()
            val remainingNanos = synchronized(lock) { progress.deadlineNanos - System.nanoTime() }
            val remainingMillis = if (remainingNanos <= 0) 0 else (remainingNanos + 999_999) / 1_000_000
            val reply = try {
                withTimeout(remainingMillis) {
                    select<Reply?> {
                        deferred.onAwait { it }
                        progress.advanced.onReceive { null }
                    }
                }
            } catch (timeout: TimeoutCancellationException) {
                // A progress frame may renew on the reader exactly as this
                // older timer fires. Parent cancellation still wins.
                currentCoroutineContext().ensureActive()
                if (synchronized(lock) { progress.deadlineNanos > System.nanoTime() }) continue
                throw timeout
            }
            if (reply != null) return reply
        }
    }

    suspend fun acknowledgeWindow(reply: Reply, checkpoint: JSONObject) {
        require(checkpoint.getString("epoch") == epoch &&
            checkpoint.getLong("version") == reply.end.getJSONObject("window").getLong("version"))
        val viewport = checkpoint.getJSONArray("viewportSegmentIDs")
        // Never ask a host to retain more pages than its hello accepts.
        require(viewport.length() in 1..maxWindowSegments) { "invalidWindowAck" }
        send(frame(JSONObject().put("kind", "window.ack").put("id", UUID.randomUUID().toString())
            .put("thread", reply.end.getString("thread")).put("transaction", reply.end.getString("id"))
            .put("windowVersion", checkpoint.getLong("version"))
            .put("viewport", viewport).put("head", checkpoint.getString("headSegmentID"))))
    }

    suspend fun cancelWindow(transaction: String, thread: String) {
        send(frame(JSONObject().put("kind", "window.cancel").put("id", UUID.randomUUID().toString())
            .put("thread", thread).put("transaction", transaction)))
    }

    private suspend fun send(bytes: ByteArray, beforeWrite: (() -> Unit)? = null) = writer.withLock {
        check(!isClosed && endpoint.isCurrentIngestion(binding))
        beforeWrite?.invoke()
        stream.send(bytes)
    }

    private fun start() {
        scope.launch {
            try {
                val framer = AgentIngestionFramer()
                stream.stdout.collect { chunk ->
                    check(endpoint.isCurrentIngestion(binding))
                    // UTF-8 validation and JSON parsing are pure and can cost
                    // tens of milliseconds for a full page. Only they leave
                    // the caller's (Main) dispatcher, and only when there is
                    // enough to parse to outweigh the extra dispatch that
                    // small control replies would pay. The collector is still
                    // sequential, so frame order and every protocol state
                    // change below stay exactly where they were.
                    val raws = framer.append(chunk)
                    val frames = if (raws.sumOf { it.size } <= INLINE_PARSE_BYTES) raws.map { it to parseFrame(it) }
                        else withContext(Dispatchers.Default) { raws.map { it to parseFrame(it) } }
                            .also { check(endpoint.isCurrentIngestion(binding)) }
                    for ((raw, value) in frames) receive(raw, value)
                }
                framer.finish()
                if (!isClosed) reportFailure("stdout", IllegalStateException("streamClosed"))
            } catch (failure: Throwable) { reportFailure("decode", failure); close() }
            finally { pages.clear(); close() }
        }
        scope.launch {
            try { stream.stderr.collect { if (it.isNotEmpty()) error("helperStderr") } }
            catch (failure: Throwable) { reportFailure("stderr", failure); close() }
            finally { if (!isClosed) close() }
        }
    }

    private fun parseFrame(raw: ByteArray): JSONObject {
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(raw)).toString()
        return JSONObject(text)
    }

    private suspend fun receive(raw: ByteArray, value: JSONObject) {
        val kind = value.getString("kind")
        val incomingEpoch = value.getString("serviceEpoch")
        require(identifier(incomingEpoch))
        if (epochValue == null) {
            require(kind == "hello" && value.getString("id") == "hello")
            epochValue = incomingEpoch; hello.complete(Reply(value)); return
        }
        require(incomingEpoch == epoch)
        if (kind == "read.progress") {
            require(supportsReadProgress)
            val id = value.getString("id")
            val thread = value.getString("thread")
            require(identifier(id) && identifier(thread))
            val sequenceText = value.opt("sequence") as? String ?: error("malformed read progress")
            val bytesText = value.opt("bytesRead") as? String ?: error("malformed read progress")
            val sequence = sequenceText.toULongOrNull()?.takeIf { it.toString() == sequenceText } ?: error("malformed read progress")
            val bytes = bytesText.toULongOrNull()?.takeIf { it.toString() == bytesText } ?: error("malformed read progress")
            val status = checkNotNull(SharedAgentReadStatus.decode(value.getJSONObject("status")))
            require(status.isProgress)
            val accepted = synchronized(lock) {
                val progress = readProgress[id]
                if (progress != null && progress.thread == thread && progress.sent && pending.containsKey(id)) {
                    if (sequence <= progress.sequence || bytes <= progress.bytes) false
                    else {
                        progress.sequence = sequence; progress.bytes = bytes
                        progress.deadlineNanos = System.nanoTime() + progress.idleMillis * 1_000_000
                        progress.advanced.trySend(Unit); true
                    }
                } else if (id.startsWith("watch_") && thread in subscribedThreads && thread !in pausedWatches) {
                    val prior = displayedReadProgress[thread]
                    sequence > 0uL && bytes > 0uL && (prior?.id != id ||
                        (sequence > prior.sequence && bytes > prior.bytes))
                } else false
            }
            if (accepted) {
                synchronized(lock) { displayedReadProgress[thread] = DisplayedReadProgress(id, sequence, bytes) }
                onReadStatus?.invoke(thread, status)
            }
            return
        }
        if (kind == "read.complete") {
            require(supportsReadProgress)
            val id = value.getString("id")
            val thread = value.getString("thread")
            require(identifier(id) && identifier(thread) && id.startsWith("watch_"))
            // Only the watch whose progress is displayed can end it; a stale
            // or foreign completion changes no cursor, ACK or status.
            if (synchronized(lock) { thread in subscribedThreads && thread !in pausedWatches }) finishReadProgress(id, thread)
            return
        }
        if (kind == "resyncRequired") {
            val status = value.optJSONObject("status")?.let { checkNotNull(SharedAgentReadStatus.decode(it)) }
            diagnostics?.invoke("agent_ingestion_resync", mapOf("code" to (status?.code ?: AgentIngestionDiagnostics.code(value.optString("reason")))))
            val thread = value.getString("thread")
            val priorProgress = synchronized(lock) {
                subscribedThreads.remove(thread)
                pendingSubscriptions.values.filter { it.thread == thread }.forEach { it.revoked = true }
                displayedReadProgress.remove(thread)
            }
            if (status != null) {
                onReadStatus?.invoke(thread, status)
                if (status.recovery == "rebootstrap") onResync?.invoke(thread)
            } else {
                if (priorProgress != null) onReadComplete?.invoke(thread)
                onResync?.invoke(thread)
            }
            return
        }
        val id = value.optString("id")
        if (kind == "hookPreview") {
            require(identifier(id))
            onPage?.invoke(value.getString("thread"), Reply(value, raw))
            return
        }
        if (kind == "summary") {
            if (value.has("metadataIssue")) diagnostics?.invoke("agent_ingestion_metadata_failed",
                mapOf("code" to AgentIngestionDiagnostics.code(value.optString("metadataIssue"))) +
                    (if (value.has("metadataReason")) mapOf("reason" to AgentIngestionDiagnostics.code(value.optString("metadataReason"))) else emptyMap()))
            require(identifier(id))
            val reply = Reply(value, raw)
            finishReadProgress(id, value.getString("thread"))
            val waiter = synchronized(lock) { pending.remove(id) }
            if (waiter != null) waiter.complete(reply)
            else {
                // An explicit metadata request can complete after selection
                // cancellation/timeout. Discard it just like a late page;
                // it is not an unsolicited subscription and must not close
                // sibling threads sharing this connection.
                if (!id.startsWith("watch_")) return
                val thread = value.getString("thread")
                if (onPage?.invoke(thread, reply) == true) {
                    send(frame(JSONObject().put("kind", "ack").put("id", UUID.randomUUID().toString()).put("requestID", id)))
                } else {
                    send(frame(JSONObject().put("kind", "unsubscribe").put("id", UUID.randomUUID().toString()).put("thread", thread)))
                    onResync?.invoke(thread)
                }
            }
            return
        }
        if (kind.startsWith("page.") || kind.startsWith("inventory.")) {
            require(identifier(id))
            if (kind == "page.begin" || kind == "inventory.begin") {
                require(id !in pages && pages.size < 16)
                pages[id] = Transaction(kind == "inventory.begin")
            }
            val transaction = checkNotNull(pages[id])
            validateTransactionFrame(transaction.inventoryPage, kind, ++transaction.frames,
                transaction.bytes.size() + raw.size + 4, pages.values.sumOf { it.bytes.size() } + raw.size + 4)
            transaction.bytes.write(ByteBuffer.allocate(4).putInt(raw.size).array()); transaction.bytes.write(raw)
            if (kind == "page.begin") transaction.sourceIdentity = value.getString("sourceIdentity")
            if (kind == "page.record" && transaction.firstOrder == null) transaction.firstOrder = value.get("order").toString()
            if (kind == "inventory.thread") transaction.inventory.add(value)
            if (kind != "page.end" && kind != "inventory.end") return
            pages.remove(id)
            val reply = Reply(value, if (kind == "page.end") transaction.bytes.toByteArray() else null, transaction.inventory,
                transaction.sourceIdentity, transaction.firstOrder)
            if (kind == "page.end") finishReadProgress(id, value.getString("thread"))
            val waiter = synchronized(lock) { pending.remove(id) }
            if (waiter != null) waiter.complete(reply)
            else if (id.startsWith("watch_")) {
                val thread = value.getString("thread")
                if (value.has("window")) {
                    val completion = synchronized(lock) {
                        if (thread in pausedWatches) null
                        else CompletableDeferred<Unit>().also { activeWatches[thread] = it }
                    }
                    if (completion == null) { cancelWindow(id, thread); return }
                    try {
                    val commit = onWindowPage?.invoke(thread, reply)
                    if (commit?.accepted == true) acknowledgeWindow(reply, commit.snapshot)
                    else if (commit != null) {
                        cancelWindow(id, thread)
                        if (windowLimits[thread] == 1) {
                            send(frame(JSONObject().put("kind", "unsubscribe").put("id", UUID.randomUUID().toString()).put("thread", thread)))
                            onCapacity?.invoke(thread); return
                        }
                        val limit = ((windowLimits[thread] ?: 100) / 2).coerceAtLeast(1)
                        windowLimits[thread] = limit
                        send(frame(JSONObject().put("kind", "subscribe").put("id", UUID.randomUUID().toString())
                            .put("thread", thread).put("interest", "fast").put("limit", limit)
                            .put("readProgress", supportsReadProgress)
                            .put("windowVersion", commit.snapshot.getLong("version"))
                            .put("liveCursor", commit.snapshot.getString("liveCursor"))))
                    }
                    else {
                        cancelWindow(id, thread)
                        send(frame(JSONObject().put("kind", "unsubscribe").put("id", UUID.randomUUID().toString()).put("thread", thread)))
                        onResync?.invoke(thread)
                    }
                    } finally {
                        synchronized(lock) { activeWatches.remove(thread, completion) }
                        completion.complete(Unit)
                    }
                } else if (onPage?.invoke(thread, reply) == true) {
                    send(frame(JSONObject().put("kind", "ack").put("id", UUID.randomUUID().toString()).put("requestID", id)))
                } else {
                    send(frame(JSONObject().put("kind", "unsubscribe").put("id", UUID.randomUUID().toString()).put("thread", thread)))
                    onResync?.invoke(thread)
                }
            }
            return
        }
        val status = if (kind == "error") value.optJSONObject("status")?.let { checkNotNull(SharedAgentReadStatus.decode(it)) } else null
        val (waiter, thread) = synchronized(lock) { pending.remove(id) to pendingThreads[id] }
        if (waiter == null) return
        if (kind != "error") synchronized(lock) {
            pendingSubscriptions[id]?.takeIf { !it.revoked }?.let { subscribedThreads.add(it.thread) }
        }
        if (kind == "error") {
            if (status != null) {
                synchronized(lock) {
                    if (displayedReadProgress[thread]?.id == id) displayedReadProgress.remove(thread)
                }
                if (!thread.isNullOrEmpty()) onReadStatus?.invoke(thread, status)
                waiter.completeExceptionally(AgentIngestionReadFailure(status))
            } else waiter.completeExceptionally(IllegalStateException(AgentIngestionDiagnostics.code(value.optString("code"))))
        }
        else waiter.complete(Reply(value))
    }

    private fun reportFailure(stage: String, failure: Throwable, fields: Map<String, String> = emptyMap()) {
        if (failure is kotlinx.coroutines.CancellationException && failure !is kotlinx.coroutines.TimeoutCancellationException) return
        diagnostics?.invoke("agent_ingestion_connection_failed", AgentIngestionDiagnostics.failure(failure) + fields +
            mapOf("stage" to stage, "transport" to binding.transport.name))
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        // Detach first, wake after. On Main.immediate a cancelled waiter
        // resumes inline on this thread, and its finally re-enters the
        // (reentrant) lock to remove itself from these maps; waking while
        // iterating them threw ConcurrentModificationException.
        val (waiters, progress) = synchronized(lock) {
            val detached = pending.values.toList() to readProgress.values.toList()
            pending.clear(); pendingThreads.clear(); pendingSubscriptions.clear()
            readProgress.clear(); displayedReadProgress.clear(); subscribedThreads.clear()
            detached
        }
        waiters.forEach { it.cancel() }; progress.forEach { it.advanced.close() }
        hello.cancel(); scope.cancel()
        // Ownership is fenced synchronously above. Blocking SSH channel
        // teardown is independent of the cancelled reader/UI scope.
        CoroutineScope(Dispatchers.IO).launch {
            try { stream.cancel() } finally { stream.close() }
        }
    }
}

/** Frame boundaries only. Semantic validation lives in TesseraAgentCore. */
internal class AgentIngestionFramer {
    private val header = ByteArray(4)
    private var headerBytes = 0
    private var body: ByteArray? = null
    private var bodyBytes = 0
    fun append(chunk: ByteArray): List<ByteArray> {
        // Transport callbacks are already bounded to 64KiB; rejecting a
        // larger callback avoids allocating an unbounded list of tiny frames.
        require(chunk.size <= 65_536)
        val complete = mutableListOf<ByteArray>()
        var index = 0
        while (index < chunk.size) {
            if (body == null) {
                val length = minOf(4 - headerBytes, chunk.size - index)
                chunk.copyInto(header, headerBytes, index, index + length); index += length; headerBytes += length
                if (headerBytes != 4) continue
                val size = ByteBuffer.wrap(header).int
                require(size in 1..65_536)
                body = ByteArray(size); bodyBytes = 0
            }
            val target = checkNotNull(body)
            val length = minOf(target.size - bodyBytes, chunk.size - index)
            chunk.copyInto(target, bodyBytes, index, index + length); index += length; bodyBytes += length
            if (bodyBytes == target.size) { complete.add(target); body = null; bodyBytes = 0; headerBytes = 0 }
        }
        return complete
    }
    fun finish() { require(headerBytes == 0 && body == null) }
}
