package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxSurfaceDeclaration
import com.bambouville.tessera.core.bridge.SharedTmuxSurfacePresentation
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class TmuxRenderSurfacePublicationTest {
    private val authority = TmuxAuthorityReducer()
    @org.junit.After fun closeSession() = authority.close()

    @Test
    fun declarationCannotAdvertiseLiveBeforeItsLedgerPublicationOwnsTheTransportLock() {
        val lock = Any()
        val controller = bareController(lock)
        val declaration = SharedTmuxSurfaceDeclaration(
            surfaceId = "live",
            presentation = SharedTmuxSurfacePresentation.Single,
            windowId = 1,
            paneId = 1,
        )
        val started = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        val publisher = Thread {
            started.countDown()
            try {
                controller.declareTmuxRenderSurfaces(listOf(declaration))
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        try {
            synchronized(lock) {
                publisher.start()
                assertTrue(started.await(1, TimeUnit.SECONDS))
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
                while (publisher.state != Thread.State.BLOCKED && publisher.isAlive && System.nanoTime() < deadline) {
                    Thread.yield()
                }
                assertEquals("publisher must be waiting for the transport monitor", Thread.State.BLOCKED, publisher.state)
                assertEquals(
                    "a control snapshot can redrive only after the ledger declaration was admitted",
                    emptyList<SharedTmuxSurfaceDeclaration>(),
                    controller.privateValue("declaredTmuxRenderSurfaces"),
                )
            }
        } finally {
            publisher.join(2_000)
        }
        assertFalse("declaration publisher must finish after the monitor is released", publisher.isAlive)
        failure.get()?.let { throw AssertionError("declaration publication failed", it) }
        assertEquals(listOf(declaration), controller.privateValue("declaredTmuxRenderSurfaces"))
    }

    private fun bareController(lock: Any): SshSessionController =
        (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).apply {
            setPrivate("tmuxTransportLock", lock)
            setPrivate("tmuxAuthorityLifecycle", authority)
            setPrivate("authorityTime", { 0L })
            setPrivate("declaredTmuxRenderSurfaces", emptyList<SharedTmuxSurfaceDeclaration>())
            setPrivate("inlineAuthorityRepaintFence", InlineAuthorityRepaintFence())
            setPrivate("moshHistoryPresentationAcknowledgements", MoshHistoryPresentationAcknowledgements<Any>())
            setPrivate("mutableTmuxRenderHistory", MutableStateFlow(emptyMap<String, Any>()))
            setPrivate("initiallyRequestedTmuxRenderSurfaces", ConcurrentHashMap.newKeySet<String>())
        }

    private fun Any.privateValue(name: String): Any? =
        javaClass.getDeclaredField(name).apply { isAccessible = true }.get(this)

    private fun Any.setPrivate(name: String, value: Any?) {
        javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value)
    }

    private companion object {
        val unsafe: sun.misc.Unsafe = sun.misc.Unsafe::class.java
            .getDeclaredField("theUnsafe")
            .apply { isAccessible = true }
            .get(null) as sun.misc.Unsafe
    }
}
