package com.bambouville.tessera.networking.mosh

import com.bambouville.tessera.networking.BuildConfig
import java.io.Closeable

/** Private Kotlin projection of Packages/MoshBridge/Sources/MoshCABI/MoshCABI.h. */
interface MoshNativeClient : Closeable {
    fun start()
    /** @return the next tick deadline in milliseconds, or [NO_DEADLINE]. */
    fun tick(): Long
    fun inject(bytes: ByteArray)
    fun resize(columns: Int, rows: Int)
    /** Queue the current resize after the last sent SSP state; zero means unavailable. */
    fun beginFullRepaintFence(): Long
    /** Fresh sent state, post-input server echo ack, and exact current framebuffer grid. */
    fun fullRepaintFenceReady(token: Long): Boolean
    fun forceFullRepaint()
    val connected: Boolean
    val transportReachable: Boolean
    val serverContactAgeMilliseconds: Long
    val replyAgeMilliseconds: Long
    val shutdownComplete: Boolean

    /**
     * The UDP sockets the client currently receives on. Empty until the
     * transport has been created, and again once it has terminated; the set
     * changes while mosh roams between addresses, so callers re-read it before
     * every wait rather than caching it.
     */
    fun socketFds(): IntArray = IntArray(0)

    /**
     * Blocks the calling thread until one of [fds] is readable or
     * [timeoutMillis] elapses. Must be called without any client lock held:
     * the pump lives here between ticks, and an [inject]/[resize] from another
     * thread must never queue behind it.
     */
    fun awaitReadable(fds: IntArray, timeoutMillis: Int): MoshSocketWake = MoshSocketWake.UNSUPPORTED

    companion object {
        const val NO_DEADLINE = Long.MAX_VALUE
    }
}

/** Why a socket wait returned. */
enum class MoshSocketWake { READABLE, TIMEOUT, INTERRUPTED, UNSUPPORTED }

fun interface MoshNativeClientFactory {
    fun create(host: String, udpPort: Int, base64Key: ByteArray, onOutput: (ByteArray) -> Unit): MoshNativeClient
}

object JniMoshNativeClientFactory : MoshNativeClientFactory {
    val isAvailable: Boolean
        get() = BuildConfig.TESSERA_MOSH_NATIVE_ENABLED

    override fun create(host: String, udpPort: Int, base64Key: ByteArray, onOutput: (ByteArray) -> Unit): MoshNativeClient =
        if (isAvailable) JniMoshNativeClient(host, udpPort, base64Key, onOutput)
        else error(
            "This Android build was assembled with -Ptessera.enableMoshNative=false and does not " +
                "package native Mosh support. Rebuild without that flag.",
        )
}

private class JniMoshNativeClient(
    host: String,
    udpPort: Int,
    base64Key: ByteArray,
    private val output: (ByteArray) -> Unit,
) : MoshNativeClient {
    /** Guards the raw JNI pointer for the complete duration of every call. */
    private val lifetimeLock = Any()
    private var handle: Long

    init {
        require(host.isNotBlank())
        require(udpPort in 1..65535)
        try {
            handle = nativeCreate(host, udpPort, base64Key)
            check(handle != 0L) { "Could not create native Mosh client" }
        } finally {
            base64Key.fill(0)
        }
    }

    override fun start() = synchronized(lifetimeLock) { nativeStart(requireHandleLocked()) }
    override fun tick(): Long = synchronized(lifetimeLock) { nativeTick(requireHandleLocked()) }
    override fun inject(bytes: ByteArray) {
        if (bytes.isNotEmpty()) synchronized(lifetimeLock) { nativeInject(requireHandleLocked(), bytes) }
    }
    override fun resize(columns: Int, rows: Int) {
        require(columns >= 4 && rows >= 4)
        synchronized(lifetimeLock) { nativeResize(requireHandleLocked(), columns, rows) }
    }
    override fun forceFullRepaint() = synchronized(lifetimeLock) {
        nativeForceFullRepaint(requireHandleLocked())
    }
    override fun beginFullRepaintFence(): Long = synchronized(lifetimeLock) {
        nativeBeginFullRepaintFence(requireHandleLocked())
    }
    override fun fullRepaintFenceReady(token: Long): Boolean = token > 0 && synchronized(lifetimeLock) {
        nativeFullRepaintFenceReady(requireHandleLocked(), token)
    }
    override val connected: Boolean get() = synchronized(lifetimeLock) { nativeConnected(requireHandleLocked()) }
    override val transportReachable: Boolean get() = synchronized(lifetimeLock) {
        nativeTransportReachable(requireHandleLocked())
    }
    override val serverContactAgeMilliseconds: Long get() = synchronized(lifetimeLock) {
        nativeServerContactAgeMilliseconds(requireHandleLocked())
    }
    override val replyAgeMilliseconds: Long get() = synchronized(lifetimeLock) {
        nativeReplyAgeMilliseconds(requireHandleLocked())
    }
    override val shutdownComplete: Boolean get() = synchronized(lifetimeLock) {
        nativeShutdownComplete(requireHandleLocked())
    }

    override fun socketFds(): IntArray = synchronized(lifetimeLock) {
        if (handle == 0L) IntArray(0) else nativeSocketFds(handle) ?: IntArray(0)
    }

    override fun awaitReadable(fds: IntArray, timeoutMillis: Int): MoshSocketWake {
        if (fds.isEmpty()) return MoshSocketWake.UNSUPPORTED
        // Deliberately outside lifetimeLock: this is a blocking wait.
        return when (val ready = nativePollReadable(fds, timeoutMillis.coerceAtLeast(0))) {
            0 -> MoshSocketWake.TIMEOUT
            -2 -> MoshSocketWake.INTERRUPTED
            else -> if (ready > 0) MoshSocketWake.READABLE else MoshSocketWake.UNSUPPORTED
        }
    }

    override fun close() {
        synchronized(lifetimeLock) {
            val active = handle
            if (active == 0L) return
            handle = 0L
            nativeDestroy(active)
        }
    }

    @Suppress("unused") // Called by JNI; the callback owns a copied byte array.
    private fun onNativeOutput(bytes: ByteArray) = output(bytes)

    private fun requireHandleLocked(): Long = checkNotNull(handle.takeIf { it != 0L }) {
        "Native Mosh client is closed"
    }

    private external fun nativeCreate(host: String, udpPort: Int, base64Key: ByteArray): Long
    private external fun nativeStart(handle: Long)
    private external fun nativeTick(handle: Long): Long
    private external fun nativeInject(handle: Long, bytes: ByteArray)
    private external fun nativeResize(handle: Long, columns: Int, rows: Int)
    private external fun nativeForceFullRepaint(handle: Long)
    private external fun nativeBeginFullRepaintFence(handle: Long): Long
    private external fun nativeFullRepaintFenceReady(handle: Long, token: Long): Boolean
    private external fun nativeConnected(handle: Long): Boolean
    private external fun nativeTransportReachable(handle: Long): Boolean
    private external fun nativeServerContactAgeMilliseconds(handle: Long): Long
    private external fun nativeReplyAgeMilliseconds(handle: Long): Long
    private external fun nativeShutdownComplete(handle: Long): Boolean
    private external fun nativeSocketFds(handle: Long): IntArray?
    private external fun nativePollReadable(fds: IntArray, timeoutMillis: Int): Int
    private external fun nativeDestroy(handle: Long)

    private companion object {
        init { System.loadLibrary("tessera_mosh_jni") }
    }
}
