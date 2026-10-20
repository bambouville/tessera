package com.bambouville.tessera.networking

import java.io.ByteArrayOutputStream
import java.util.Collections
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.sftp.PacketType
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The transfer loops against a scripted server whose replies arrive only when
 * the test says so. Replies are real sshj packets parsed as
 * [PipelinedRemoteFile] parses them. Mirrors the iOS app's
 * `SFTPTransferPipelineTests`.
 */
class SftpTransferPipelineTest {
    @Test(timeout = 30_000)
    fun uploadStartsWithFourRequestsThenOpensToTheCeilingOnAFastLink() {
        val source = pattern(3_000_000 + 1_234)
        val file = ScriptedFile()
        val window = uploadWindow()
        val clock = ManualClock()
        val progress = Collections.synchronizedList(ArrayList<Long>())
        val reportedUnacknowledged = AtomicBoolean()
        val upload = startUpload(file, window, reader(source), clock) {
            if (it > file.acknowledgedEnd) reportedUnacknowledged.set(true)
            progress += it
        }

        file.quiesce(upload)
        assertEquals(List(4) { WRITE }, file.writeLog.map { it.second })
        assertEquals("queued bytes are not progress", emptyList<Long>(), progress.toList())

        // 32 KiB answered in a millisecond: a quarter second carries far more
        // than the 2 MiB ceiling.
        clock.advance(milliseconds = 1)
        file.acknowledgeWrites(1)
        file.quiesce(upload)
        assertEquals(64L * WRITE, file.pendingWriteBytes)

        drive(listOf(file), upload)
        assertNull(upload.result())
        assertArrayEquals(source, file.contents)
        assertEquals(source.size.toLong(), progress.last())
        assertEquals(progress.sorted(), progress.toList())
        assertFalse("progress counted bytes the server hadn't acknowledged", reportedUnacknowledged.get())
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun uploadOnASlowLinkDropsToOneRequestInFlightThenRecovers() {
        val source = pattern(3_000_000)
        val file = ScriptedFile()
        val window = uploadWindow()
        val clock = ManualClock()
        val upload = startUpload(file, window, reader(source), clock)

        file.quiesce(upload)
        assertEquals(4, file.pendingWrites)
        // One request a second is 32 KB/s: a round trip plus a quarter second
        // of that is less than two requests, so nothing more leaves until the
        // queue drains, and then only one at a time.
        repeat(3) {
            clock.advance(milliseconds = 1_000)
            file.acknowledgeWrites(1)
            file.quiesce(upload)
            assertEquals(4, file.writeLog.size)
        }
        repeat(3) {
            clock.advance(milliseconds = 1_000)
            file.acknowledgeWrites(1)
            file.quiesce(upload)
            assertEquals(1, file.pendingWrites)
        }
        assertEquals(7, file.writeLog.size)

        // The newest request is answered a millisecond after it left.
        clock.advance(milliseconds = 1)
        file.acknowledgeWrites(1)
        file.quiesce(upload)
        assertEquals(64L * WRITE, file.pendingWriteBytes)

        drive(listOf(file), upload)
        assertNull(upload.result())
        assertArrayEquals(source, file.contents)
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun uploadRejectedWriteFailsWithoutQueueingMoreAndReturnsItsBytes() {
        val file = ScriptedFile()
        val window = uploadWindow()
        val upload = startUpload(file, window, reader(pattern(1_000_000)), ManualClock())

        file.quiesce(upload)
        assertEquals(4, file.pendingWrites)
        file.rejectWrites(1)

        val failure = upload.result()
        assertTrue("a rejected write must fail the upload: $failure", failure is SFTPException)
        assertEquals(4, file.writeLog.size)
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun uploadCancellationStopsAtTheNextAcknowledgement() {
        val file = ScriptedFile()
        val window = uploadWindow()
        val upload = startUpload(file, window, reader(pattern(1_000_000)), ManualClock())

        file.quiesce(upload)
        assertEquals(4, file.pendingWrites)
        upload.cancel()
        file.acknowledgeWrites(1)

        val failure = upload.result()
        assertTrue("a cancelled upload must not complete: $failure", failure is CancellationException)
        assertEquals(4, file.writeLog.size)
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun uploadAsksAgainWhenTheInputHasNothingYet() {
        val source = pattern(200_000)
        val file = ScriptedFile()
        val window = uploadWindow()
        var cursor = 0
        var calls = 0
        // Every other read returns nothing; the rest return a partial chunk.
        val stalling: (ByteArray) -> Int = { buffer ->
            calls++
            when {
                cursor >= source.size -> -1
                calls % 2 == 0 -> 0
                else -> minOf(10_000, source.size - cursor).also {
                    source.copyInto(buffer, 0, cursor, cursor + it)
                    cursor += it
                }
            }
        }
        val upload = startUpload(file, window, stalling, ManualClock())

        drive(listOf(file), upload)
        assertNull(upload.result())
        assertArrayEquals(source, file.contents)
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun concurrentUploadsShareOneWindow() {
        val window = uploadWindow()
        val clock = ManualClock()
        val first = ScriptedFile()
        val second = ScriptedFile()
        val firstSource = pattern(2_000_000)
        val secondSource = pattern(1_500_000).reversedArray()
        // How far the bytes outstanding ever got past the limit as a request left.
        val overshoot = AtomicLong(Long.MIN_VALUE)
        for (file in listOf(first, second)) {
            file.onSend = { overshoot.accumulateAndGet(window.outstandingBytes - window.limitBytes, ::maxOf) }
        }

        val firstUpload = startUpload(first, window, reader(firstSource), clock)
        first.quiesce(firstUpload)
        assertEquals(4, first.pendingWrites)
        val secondUpload = startUpload(second, window, reader(secondSource), clock)
        second.quiesce(secondUpload)
        assertEquals("a second transfer queues behind the first, not in a window of its own", 1, second.pendingWrites)
        assertEquals(5L * WRITE, window.outstandingBytes)

        drive(listOf(first, second), firstUpload, secondUpload)
        assertNull(firstUpload.result())
        assertNull(secondUpload.result())
        assertArrayEquals(firstSource, first.contents)
        assertArrayEquals(secondSource, second.contents)
        assertTrue(
            "outstanding passed the limit by ${overshoot.get()}, more than a request per transfer",
            overshoot.get() <= 2L * WRITE,
        )
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun downloadReadsAheadWithinTheKnownSizeThenProbesOnceForEndOfFile() {
        val source = pattern(3 * 1024 * 1024 + 777)
        val file = ScriptedFile(source)
        val window = downloadWindow()
        val clock = ManualClock()
        val output = ByteArrayOutputStream()
        val progress = Collections.synchronizedList(ArrayList<Long>())
        val download = startDownload(file, window, source.size.toLong(), output, clock) { progress += it }

        file.quiesce(download)
        assertEquals(4, file.pendingReads.size)

        clock.advance(milliseconds = 1)
        file.answerReads(1)
        file.quiesce(download)
        assertEquals(32L * READ, file.pendingReadBytes)
        assertEquals(
            "read-ahead requests consecutive blocks",
            List(file.readLog.size) { it.toLong() * READ },
            file.readLog.map { it.first },
        )

        drive(listOf(file), download)
        assertNull(download.result())
        assertArrayEquals(source, output.toByteArray())
        assertEquals(source.size.toLong(), progress.last())
        assertEquals(progress.sorted(), progress.toList())
        assertEquals(
            "read-ahead stops at the known size; one request confirms end of file",
            listOf(source.size.toLong()),
            file.readLog.map { it.first }.filter { it >= source.size },
        )
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun downloadOnASlowLinkKeepsOneRequestInFlight() {
        val source = pattern(2_000_000)
        val file = ScriptedFile(source)
        val window = downloadWindow()
        val clock = ManualClock()
        val output = ByteArrayOutputStream()
        val download = startDownload(file, window, source.size.toLong(), output, clock)

        file.quiesce(download)
        assertEquals(4, file.pendingReads.size)
        // One 64 KiB read every two seconds: 32 KB/s over a round trip plus
        // a quarter second is less than two requests.
        repeat(3) {
            clock.advance(milliseconds = 2_000)
            file.answerReads(1)
            file.quiesce(download)
            assertEquals(4, file.readLog.size)
        }
        repeat(3) {
            clock.advance(milliseconds = 2_000)
            file.answerReads(1)
            file.quiesce(download)
            assertEquals(1, file.pendingReads.size)
        }
        assertEquals(7, file.readLog.size)

        drive(listOf(file), download)
        assertNull(download.result())
        assertArrayEquals(source, output.toByteArray())
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun downloadReleasesRepliesWhenTheyArriveNotWhenTheyAreConsumed() {
        val source = pattern(2_000_000)
        val file = ScriptedFile(source)
        val window = downloadWindow()
        val clock = ManualClock()
        val output = ByteArrayOutputStream()
        // How far the window's count ever got past the replies still to come,
        // as a request left; the request itself is one read.
        val overcount = AtomicLong(Long.MIN_VALUE)
        file.onSend = { overcount.accumulateAndGet(window.outstandingBytes - file.pendingReadBytes, ::maxOf) }
        val download = startDownload(file, window, source.size.toLong(), output, clock)

        var rounds = 0
        while (!download.finished) {
            assertTrue("the download made no progress", ++rounds < 1_000)
            file.quiesce(download)
            // Three replies at once: two arrive while the first is consumed.
            clock.advance(milliseconds = 100)
            file.answerReads(3)
            file.quiesce(download)
        }
        assertNull(download.result())
        assertArrayEquals(source, output.toByteArray())
        assertTrue("the window counted replies that had arrived: ${overcount.get()}", overcount.get() <= READ)
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun downloadResumesAtAOneOffShortReplyWithoutShrinking() {
        val source = pattern(300_000)
        val file = ScriptedFile(source)
        file.shortReplies[READ.toLong()] = 10
        val window = downloadWindow()
        val output = ByteArrayOutputStream()
        val download = startDownload(file, window, source.size.toLong(), output, ManualClock())

        drive(listOf(file), download)
        assertNull(download.result())
        assertArrayEquals(source, output.toByteArray())
        assertTrue("resume at the gap the short reply left", file.readLog.any { it.first == READ + 10L })
        assertTrue("one short reply doesn't shrink reads", file.readLog.all { it.second == READ })
        assertEquals("dropped requests went back to the window", 0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun downloadShrinksReadsAfterTwoIdenticalShortReplies() {
        val source = pattern(1_000_000)
        val file = ScriptedFile(source)
        file.readCap = 40_000
        val window = downloadWindow()
        val output = ByteArrayOutputStream()
        val download = startDownload(file, window, source.size.toLong(), output, ManualClock())

        drive(listOf(file), download)
        assertNull(download.result())
        assertArrayEquals(source, output.toByteArray())
        val lengths = file.readLog.map { it.second }
        val firstShrunk = lengths.indexOf(40_000)
        assertTrue(firstShrunk > 0)
        assertTrue(lengths.subList(0, firstShrunk).all { it == READ })
        assertTrue(lengths.subList(firstShrunk, lengths.size).all { it == 40_000 })
        assertTrue("the first short reply resumes at full length", file.readLog.contains(40_000L to READ))
        assertEquals("shrinks after the second short reply", 80_000L, file.readLog[firstShrunk].first)
        assertEquals("dropped requests went back to the window", 0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun downloadNeverShrinksReadsBelowTheMinimum() {
        val source = pattern(300_000)
        val file = ScriptedFile(source)
        file.shortReplies[READ.toLong()] = 10
        file.shortReplies[READ + 10L] = 10
        val window = downloadWindow()
        val output = ByteArrayOutputStream()
        val download = startDownload(file, window, source.size.toLong(), output, ManualClock())

        drive(listOf(file), download)
        assertNull(download.result())
        assertArrayEquals(source, output.toByteArray())
        assertEquals(READ, file.readLog.first { it.first == READ + 10L }.second)
        val resumed = file.readLog.indexOfFirst { it.first == READ + 20L }
        assertTrue(resumed > 0)
        assertTrue(
            "10-byte replies shrink reads to the minimum, not to 10 bytes",
            file.readLog.drop(resumed).all { it.second == SftpTransferPipeline.MIN_READ_REQUEST_BYTES },
        )
        assertEquals("dropped requests went back to the window", 0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun downloadReadsAheadAgainOnceTheFileOutgrowsItsSizeAtOpen() {
        val source = pattern(3_000_000)
        val file = ScriptedFile(source)
        val window = downloadWindow()
        val output = ByteArrayOutputStream()
        val download = startDownload(file, window, sizeAtOpen = 100_000, output, ManualClock())

        file.quiesce(download)
        assertEquals("read-ahead stops at the size seen at open", 2, file.pendingReads.size)
        file.answerReads(1)
        file.quiesce(download)
        assertEquals(1, file.pendingReads.size)
        // A full reply past the size at open.
        file.answerReads(1)
        file.quiesce(download)
        assertTrue(file.pendingReads.count { it.offset >= 100_000 } > 1)

        drive(listOf(file), download)
        assertNull(download.result())
        assertArrayEquals(source, output.toByteArray())
        assertEquals(0, window.outstandingBytes)
    }

    @Test(timeout = 30_000)
    fun downloadFinishesAtAnEmptyDataReplyOrAnEndOfFileStatus() {
        for (emptyDataAtEnd in listOf(false, true)) {
            for (size in listOf(300_000, 4 * READ)) {
                for (sizeAtOpen in listOf(size.toLong(), null)) {
                    val case = "empty DATA $emptyDataAtEnd, size $size, size at open $sizeAtOpen"
                    val source = pattern(size)
                    val file = ScriptedFile(source)
                    file.emptyDataAtEnd = emptyDataAtEnd
                    val window = downloadWindow()
                    val output = ByteArrayOutputStream()
                    val download = startDownload(file, window, sizeAtOpen, output, ManualClock())

                    drive(listOf(file), download)
                    assertNull(case, download.result())
                    assertArrayEquals(case, source, output.toByteArray())
                    assertEquals(case, 0, window.outstandingBytes)
                }
            }
        }
    }

    @Test(timeout = 30_000)
    fun downloadFailsOnAnErrorStatusOrAnOversizedReply() {
        val denied = ScriptedFile(pattern(300_000))
        denied.failingStatus[READ.toLong()] = Response.StatusCode.PERMISSION_DENIED
        val oversized = ScriptedFile(pattern(300_000))
        oversized.oversized += 0L

        for (file in listOf(denied, oversized)) {
            val window = downloadWindow()
            val download = startDownload(file, window, 300_000, ByteArrayOutputStream(), ManualClock())
            drive(listOf(file), download)
            val failure = download.result()
            assertTrue("expected an SFTP failure, got $failure", failure is SFTPException)
            assertEquals(0, window.outstandingBytes)
        }
    }

    @Test(timeout = 30_000)
    fun downloadReadsToEndOfFileWhateverSizeWasReportedAtOpen() {
        // Unknown, zero or too small (a bogus or unreported size) must not
        // truncate; absurdly large must not read ahead past the window.
        for (sizeAtOpen in listOf(null, 0L, 1L, Long.MAX_VALUE)) {
            val case = "size at open $sizeAtOpen"
            val source = pattern(3 * 1024 * 1024 + 777)
            val file = ScriptedFile(source)
            val window = downloadWindow()
            val clock = ManualClock()
            val output = ByteArrayOutputStream()
            val progress = Collections.synchronizedList(ArrayList<Long>())
            // The window's count as each read leaves, that read included.
            val mostInFlight = AtomicLong()
            file.onSend = { mostInFlight.accumulateAndGet(window.outstandingBytes, ::maxOf) }
            val download = startDownload(file, window, sizeAtOpen, output, clock) { progress += it }

            file.quiesce(download)
            assertTrue(case, file.pendingReads.isNotEmpty())
            // A full reply in a millisecond opens the window to its ceiling
            // and no further, whatever the size claimed.
            clock.advance(milliseconds = 1)
            file.answerReads(1)
            file.quiesce(download)
            assertEquals(case, 32L * READ, file.pendingReadBytes)

            drive(listOf(file), download)
            assertNull(case, download.result())
            assertArrayEquals(case, source, output.toByteArray())
            assertEquals(case, source.size.toLong(), progress.last())
            assertTrue("$case: ${mostInFlight.get()} bytes in flight", mostInFlight.get() <= 32L * READ)
            assertEquals(case, 0, window.outstandingBytes)
        }
    }

    @Test(timeout = 30_000)
    fun downloadOfAnEmptyFileSendsOneRequest() {
        val file = ScriptedFile(ByteArray(0))
        val window = downloadWindow()
        val output = ByteArrayOutputStream()
        val progress = Collections.synchronizedList(ArrayList<Long>())
        val download = startDownload(file, window, 0, output, ManualClock()) { progress += it }

        drive(listOf(file), download)
        assertNull(download.result())
        assertEquals(1, file.readLog.size)
        assertEquals(listOf(0L), progress.toList())
        assertEquals(0, output.size())
        assertEquals(0, window.outstandingBytes)
    }

    /** Sized like SshFileConnection's windows. */
    private fun uploadWindow() = SftpPipelineWindow(WRITE.toLong(), 64L * WRITE, 4L * WRITE)

    private fun downloadWindow() = SftpPipelineWindow(READ.toLong(), 32L * READ, 4L * READ)

    private fun startUpload(
        file: ScriptedFile,
        window: SftpPipelineWindow,
        readChunk: (ByteArray) -> Int,
        clock: ManualClock,
        progress: (Long) -> Unit = {},
    ) = Transfer { checkCancelled ->
        SftpTransferPipeline.upload(file, window, readChunk, WRITE, { progress(it) }, clock.read, checkCancelled)
    }

    private fun startDownload(
        file: ScriptedFile,
        window: SftpPipelineWindow,
        sizeAtOpen: Long?,
        output: ByteArrayOutputStream,
        clock: ManualClock,
        progress: (Long) -> Unit = {},
    ) = Transfer { checkCancelled ->
        SftpTransferPipeline.download(file, window, sizeAtOpen, output, { progress(it) }, clock.read, checkCancelled)
    }

    /** Waits until [transfer] is blocked on a reply the test hasn't given, or has ended. */
    private fun ScriptedFile.quiesce(transfer: Transfer) {
        waitUntil("the transfer to block on a reply") { transfer.finished || isBlocked(transfer.thread) }
    }

    /** Answers every request as it arrives until the transfers end. */
    private fun drive(files: List<ScriptedFile>, vararg transfers: Transfer) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(DEADLINE_MS)
        while (!transfers.all { it.finished }) {
            if (System.nanoTime() > deadline) fail("timed out waiting for the transfers to end")
            val answered = files.map { it.answerAll() }.any { it }
            if (!answered) Thread.sleep(1)
        }
    }

    private fun waitUntil(what: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(DEADLINE_MS)
        while (!condition()) {
            if (System.nanoTime() > deadline) fail("timed out waiting for $what")
            Thread.sleep(1)
        }
    }

    /** Hands out [source] a buffer at a time, -1 at the end. */
    private fun reader(source: ByteArray): (ByteArray) -> Int {
        var cursor = 0
        return { buffer ->
            if (cursor >= source.size) {
                -1
            } else {
                val count = minOf(buffer.size, source.size - cursor)
                source.copyInto(buffer, 0, cursor, cursor + count)
                cursor += count
                count
            }
        }
    }

    /** Position-dependent bytes, so data at a wrong offset cannot match. */
    private fun pattern(size: Int) = ByteArray(size) { ((it * 2_654_435_761L) ushr 13).toByte() }

    /** An uptime the test moves by hand. */
    private class ManualClock {
        private val now = AtomicLong(1_000_000_000L)
        val read: () -> Long = { now.get() }

        fun advance(milliseconds: Long) {
            now.addAndGet(TimeUnit.MILLISECONDS.toNanos(milliseconds))
        }
    }

    /** A transfer on its own thread, as on Dispatchers.IO; the test thread plays the server. */
    private class Transfer(block: suspend (checkCancelled: () -> Unit) -> Unit) {
        private val cancelled = AtomicBoolean()

        @Volatile
        var finished = false
            private set

        @Volatile
        private var failure: Throwable? = null

        val thread: Thread = thread(isDaemon = true, name = "sftp-transfer") {
            try {
                runBlocking { block { if (cancelled.get()) throw CancellationException("cancelled") } }
            } catch (thrown: Throwable) {
                failure = thrown
            } finally {
                finished = true
            }
        }

        fun cancel() = cancelled.set(true)

        /** Waits for the end; the failure, if any. */
        fun result(): Throwable? {
            thread.join(DEADLINE_MS)
            assertFalse("the transfer never ended", thread.isAlive)
            return failure
        }
    }

    /** An in-memory SFTP file whose replies arrive only when the test says so. */
    private class ScriptedFile(contents: ByteArray = ByteArray(0)) : SftpPipelineFile {
        class Write(val offset: Long, val bytes: ByteArray, val reply: ScriptedReply<Unit>)

        class Read(val offset: Long, val length: Int, val reply: ScriptedReply<SftpReadReply>)

        private val lock = Any()
        private var data = contents
        private val writes = ArrayList<Write>()
        private val reads = ArrayList<Read>()
        private val writeRecord = ArrayList<Pair<Long, Int>>()
        private val readRecord = ArrayList<Pair<Long, Int>>()

        /** What each transfer thread is blocked on. */
        private val waiting = ConcurrentHashMap<Thread, ScriptedReply<*>>()

        @Volatile
        var readCap = Int.MAX_VALUE

        @Volatile
        var emptyDataAtEnd = false

        /** Reads at these offsets return only this many bytes. */
        val shortReplies = ConcurrentHashMap<Long, Int>()

        /** Reads at these offsets fail with this status. */
        val failingStatus = ConcurrentHashMap<Long, Response.StatusCode>()

        /** Reads at these offsets claim a byte more than was asked for. */
        val oversized: MutableSet<Long> = ConcurrentHashMap.newKeySet()

        /** Runs on the transfer thread as each request leaves. */
        @Volatile
        var onSend: () -> Unit = {}

        /** The end of the bytes acknowledged so far; writes are acknowledged in order. */
        @Volatile
        var acknowledgedEnd = 0L
            private set

        val contents: ByteArray get() = synchronized(lock) { data.copyOf() }
        val pendingWrites: Int get() = synchronized(lock) { writes.size }
        val pendingWriteBytes: Long get() = synchronized(lock) { writes.sumOf { it.bytes.size.toLong() } }
        val pendingReads: List<Read> get() = synchronized(lock) { reads.toList() }
        val pendingReadBytes: Long get() = synchronized(lock) { reads.sumOf { it.length.toLong() } }
        val writeLog: List<Pair<Long, Int>> get() = synchronized(lock) { writeRecord.toList() }
        val readLog: List<Pair<Long, Int>> get() = synchronized(lock) { readRecord.toList() }

        fun isBlocked(thread: Thread): Boolean = waiting[thread]?.isAnswered == false

        override fun sendWrite(offset: Long, data: ByteArray, length: Int): SftpPendingReply<Unit> {
            onSend()
            val reply = ScriptedReply { PipelinedRemoteFile.writeReply(it) }
            synchronized(lock) {
                writes += Write(offset, data.copyOf(length), reply)
                writeRecord += offset to length
            }
            return reply
        }

        override fun sendRead(offset: Long, length: Int): SftpPendingReply<SftpReadReply> {
            onSend()
            val reply = ScriptedReply { PipelinedRemoteFile.readReply(it, length) }
            synchronized(lock) {
                reads += Read(offset, length, reply)
                readRecord += offset to length
            }
            return reply
        }

        fun acknowledgeWrites(count: Int) {
            for (write in takeWrites(count)) {
                synchronized(lock) {
                    val end = (write.offset + write.bytes.size).toInt()
                    if (data.size < end) data = data.copyOf(end)
                    write.bytes.copyInto(data, write.offset.toInt())
                }
                acknowledgedEnd = maxOf(acknowledgedEnd, write.offset + write.bytes.size)
                write.reply.arrive(status(Response.StatusCode.OK))
            }
        }

        fun rejectWrites(count: Int) {
            for (write in takeWrites(count)) write.reply.arrive(status(Response.StatusCode.FAILURE))
        }

        /** Newest first, so a transfer blocked on the oldest finds them all arrived. */
        fun answerReads(count: Int) {
            val answered = synchronized(lock) { reads.take(count).also { reads.subList(0, it.size).clear() } }
            for (read in answered.asReversed()) read.reply.arrive(readResponse(read))
        }

        /** Answers everything pending; whether there was anything. */
        fun answerAll(): Boolean {
            val (writeCount, readCount) = synchronized(lock) { writes.size to reads.size }
            acknowledgeWrites(writeCount)
            answerReads(readCount)
            return writeCount + readCount > 0
        }

        private fun takeWrites(count: Int): List<Write> =
            synchronized(lock) { writes.take(count).also { writes.subList(0, it.size).clear() } }

        private fun readResponse(read: Read): Response {
            failingStatus[read.offset]?.let { return status(it) }
            val bytes = synchronized(lock) { data }
            if (read.offset in oversized) return dataReply(ByteArray(read.length + 1))
            if (read.offset >= bytes.size) {
                return if (emptyDataAtEnd) dataReply(ByteArray(0)) else status(Response.StatusCode.EOF)
            }
            val count = minOf(
                read.length.toLong(),
                readCap.toLong(),
                bytes.size - read.offset,
                (shortReplies[read.offset] ?: Int.MAX_VALUE).toLong(),
            ).toInt()
            return dataReply(bytes.copyOfRange(read.offset.toInt(), read.offset.toInt() + count))
        }

        private fun status(code: Response.StatusCode) = response(PacketType.STATUS) {
            putUInt32(code.code.toLong())
            putString("scripted")
            putString("")
        }

        private fun dataReply(bytes: ByteArray) = response(PacketType.DATA) {
            putUInt32(bytes.size.toLong())
            putRawBytes(bytes)
        }

        private fun response(type: PacketType, body: Buffer.PlainBuffer.() -> Unit): Response {
            val packet = Buffer.PlainBuffer()
            packet.putByte(type.toByte())
            packet.putUInt32(1)
            packet.body()
            @Suppress("UNCHECKED_CAST")
            return Response(packet as Buffer<Response>, 3)
        }

        inner class ScriptedReply<T>(private val parse: (Response) -> T) : SftpPendingReply<T> {
            private val arrived = CountDownLatch(1)

            @Volatile
            private var response: Response? = null

            override val isAnswered: Boolean get() = arrived.count == 0L

            fun arrive(response: Response) {
                this.response = response
                arrived.countDown()
            }

            override fun await(): T {
                val thread = Thread.currentThread()
                waiting[thread] = this
                try {
                    check(arrived.await(DEADLINE_MS, TimeUnit.MILLISECONDS)) { "no reply before the deadline" }
                } finally {
                    waiting.remove(thread)
                }
                return parse(checkNotNull(response))
            }
        }
    }

    private companion object {
        const val WRITE = 32 * 1024
        const val READ = SftpTransferPipeline.READ_REQUEST_BYTES
        const val DEADLINE_MS = 10_000L
    }
}
