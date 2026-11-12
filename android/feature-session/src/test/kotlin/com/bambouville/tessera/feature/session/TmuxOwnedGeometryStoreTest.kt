package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
import com.bambouville.tessera.core.bridge.SharedTmuxOwnedGeometryRecord
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The kept records iOS's `TmuxOwnedGeometryFileStore` keeps, as Android keeps them. */
class TmuxOwnedGeometryStoreTest {
    private val directory = kotlin.io.path.createTempDirectory("owned-geometry").toFile()
    private val file = File(directory, "tmux-owned-geometry.json")
    private val host = TmuxOwnedGeometryStore.hostKey("dev", "dev.example", 22)

    @After fun removeDirectory() { directory.deleteRecursively() }

    private fun store() = TmuxOwnedGeometryStore(file, writer = { it.run() })
    private fun record(generation: Long, columns: Int = 92) =
        SharedTmuxOwnedGeometryRecord(generation, listOf(SharedTmuxGridSize(columns, 38)))

    @Test fun aNewProcessReadsTheRecordsKeptPerHostAndSession() {
        val other = TmuxOwnedGeometryStore.hostKey("dev", "other.example", 22)
        store().apply {
            keep(host, "main", record(3))
            keep(host, "main", record(3, columns = 100))
            keep(host, "main", record(4))
            keep(other, "main", record(9))
        }
        val relaunched = store()
        val generation3 = SharedTmuxOwnedGeometryRecord(3, listOf(SharedTmuxGridSize(92, 38), SharedTmuxGridSize(100, 38)))
        assertEquals("a generation's grids stay together", listOf(record(4), generation3), relaunched.records(host, "main"))
        assertEquals(listOf(record(9)), relaunched.records(other, "main"))
        assertEquals(emptyList<SharedTmuxOwnedGeometryRecord>(), relaunched.records(host, "other"))
        val text = file.readText()
        assertFalse("only hashed keys are stored", text.contains("dev.example") || text.contains("main"))
        assertFalse(File(directory, "${file.name}.tmp").exists())
    }

    @Test fun onlyTheNewestGenerationsAndSessionsStay() {
        val store = store()
        for (generation in 1L..(SharedTmuxOwnedGeometryRecord.RESTORE_LIMIT + 3L)) store.keep(host, "main", record(generation))
        assertEquals((SharedTmuxOwnedGeometryRecord.RESTORE_LIMIT + 3L downTo 4L).toList(), store.records(host, "main").map { it.generation })
        repeat(TmuxOwnedGeometryStore.SESSION_LIMIT) { store.keep(host, "s$it", record(1)) }
        assertEquals("the least recently kept session goes", emptyList<SharedTmuxOwnedGeometryRecord>(), store().records(host, "main"))
        assertEquals(listOf(record(1)), store().records(host, "s0"))
    }

    @Test fun anUnreadableFileKeepsNothing() {
        file.writeText("not json")
        assertEquals(emptyList<SharedTmuxOwnedGeometryRecord>(), store().records(host, "main"))
    }

    @Test fun keepsBeforeTheWriterRunsShareOneWriteOfTheNewest() {
        val queued = ArrayDeque<Runnable>()
        val store = TmuxOwnedGeometryStore(file, writer = { queued.addLast(it) })
        store.keep(host, "main", record(3))
        store.keep(host, "main", record(4))
        store.keep(host, "other", record(5))
        assertEquals("one write is queued for the burst", 1, queued.size)
        queued.removeFirst().run()
        assertEquals(listOf(record(4), record(3)), store().records(host, "main"))
        assertEquals(listOf(record(5)), store().records(host, "other"))
        store.keep(host, "main", record(6))
        assertEquals(1, queued.size)
        queued.removeFirst().run()
        assertEquals(listOf(record(6), record(4), record(3)), store().records(host, "main"))
    }

    /** Sessions keep from their own feed threads; the file ends with every session's newest record. */
    @Test fun concurrentKeepsNeverLeaveAnOlderFile() {
        val writer = Executors.newSingleThreadExecutor()
        try {
            val store = TmuxOwnedGeometryStore(file, writer)
            val threads = 8
            val start = CountDownLatch(1)
            val done = CountDownLatch(threads)
            repeat(threads) { session ->
                Thread {
                    start.await()
                    for (generation in 1L..40L) store.keep(host, "s$session", record(generation))
                    done.countDown()
                }.start()
            }
            start.countDown()
            assertTrue(done.await(30, TimeUnit.SECONDS))
            writer.submit {}.get(30, TimeUnit.SECONDS)
            repeat(threads) { session ->
                assertEquals(40L, store().records(host, "s$session").first().generation)
            }
        } finally {
            writer.shutdownNow()
        }
    }

    @Test fun aPreloadNeverUndoesAKeep() {
        store().keep(host, "main", record(3))
        val queued = ArrayDeque<Runnable>()
        val store = TmuxOwnedGeometryStore(file, writer = { queued.addLast(it) })
        store.preload()
        store.keep(host, "main", record(4))
        while (queued.isNotEmpty()) queued.removeFirst().run()
        assertEquals(listOf(record(4), record(3)), store.records(host, "main"))

        val preloaded = TmuxOwnedGeometryStore(file, writer = { it.run() })
        preloaded.preload()
        assertEquals(listOf(record(4), record(3)), preloaded.records(host, "main"))
    }

    @Test fun aFailedWriteIsReported() {
        val blocked = File(directory, "blocked").apply { writeText("a file, not a directory") }
        val failures = mutableListOf<Throwable>()
        TmuxOwnedGeometryStore(File(blocked, "tmux-owned-geometry.json"), writer = { it.run() }, onWriteFailed = { failures += it })
            .keep(host, "main", record(3))
        assertEquals(1, failures.size)
    }

    @Test fun aWriterThatRefusesWorkLeavesNothingPending() {
        var refusing = true
        val failures = mutableListOf<Throwable>()
        val store = TmuxOwnedGeometryStore(
            file,
            writer = { if (refusing) throw RejectedExecutionException("shut down") else it.run() },
            onWriteFailed = { failures += it },
        )
        store.preload()
        store.keep(host, "main", record(3))
        assertEquals(1, failures.size)
        assertFalse(file.exists())
        refusing = false
        store.keep(host, "main", record(4))
        assertEquals(listOf(record(4), record(3)), store().records(host, "main"))
    }

    @Test fun theKeyIsIOSsDigest() {
        // `TmuxOwnedGeometryFileStore.key(hostKey:session:)`: SHA-256 of the host key, NUL, the session.
        assertEquals("e5dd6243ef3e958d54310afd3c5bed0e07c2144b60a91430d2c54840656a2143", TmuxOwnedGeometryStore.key(host, "main"))
    }
}
