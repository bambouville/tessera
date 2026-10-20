package com.bambouville.tessera.networking

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SftpPipelineWindowTest {
    private val request = 32 * 1024L
    private val floor = request
    private val ceiling = 64 * request

    /** Sized like SshFileConnection's upload window: one request floor, 2 MiB ceiling, four to start. */
    private fun uploadWindow() = SftpPipelineWindow(floor, ceiling, initialBytes = 4 * request)

    /** Sends [bytes] at [sentAt] and answers them [latency] later, alone on the window. */
    private fun SftpPipelineWindow.sample(bytes: Long, sentAt: Long, latency: Long) {
        answer(send(bytes, sentAt), sentAt + latency, succeeded = true)
    }

    @Test
    fun initialLimitIsClampedToTheBounds() {
        assertEquals(4 * request, uploadWindow().limitBytes)
        assertEquals(floor, SftpPipelineWindow(floor, ceiling, initialBytes = 1).limitBytes)
        assertEquals(ceiling, SftpPipelineWindow(floor, ceiling, initialBytes = 10 * ceiling).limitBytes)
    }

    @Test
    fun fastLinkReachesTheCeilingAfterOneSample() {
        val window = uploadWindow()

        window.sample(bytes = 256 * 1024L, sentAt = 0, latency = 20 * MS)

        assertEquals(ceiling, window.limitBytes)
    }

    @Test
    fun unsaturatedLinkGrowsByRoundTripPlusBudgetOverRoundTrip() {
        val window = uploadWindow()

        window.sample(bytes = 4 * request, sentAt = 0, latency = 100 * MS)

        assertEquals(4 * request * 3.5, window.limitBytes.toDouble(), 1.0)
    }

    @Test
    fun slowSaturatedLinkQueuesAboutTheBudgetPastTheRoundTrip() {
        val bytesPerNano = 1.25e6 / 1e9
        val window = uploadWindow()
        // The first reply has only its own request ahead of it: a round trip
        // plus the time its bytes take at 10 Mbit/s.
        val firstLatency = 50 * MS + (request / bytesPerNano).toLong()
        var now = 0L
        window.sample(request, now, firstLatency)
        now += firstLatency
        // Saturated from then on: every reply waits behind the whole window.
        repeat(20) {
            val outstanding = window.limitBytes
            val latency = (outstanding / bytesPerNano).toLong()
            window.sample(outstanding, now, latency)
            now += latency
        }

        val expected = 1.25e6 * (firstLatency + SftpPipelineWindow.QUEUE_BUDGET_NANOS) / 1e9
        assertEquals(expected, window.limitBytes.toDouble(), expected * 0.01)
        assertTrue(window.limitBytes < ceiling / 4)
    }

    @Test
    fun verySlowLinkSitsAtTheFloor() {
        val window = uploadWindow()

        // 4 KiB answered in two seconds: 2 KB/s wants a few KB, below one request.
        window.sample(bytes = 4096, sentAt = 0, latency = 2_000 * MS)

        assertEquals(floor, window.limitBytes)
    }

    @Test
    fun highRoundTripWidensTheWindowPastTheBudget() {
        val window = uploadWindow()
        window.sample(bytes = 600_000, sentAt = 0, latency = 150 * MS) // 4 MB/s
        assertEquals(1_600_000.0, window.limitBytes.toDouble(), 1_600_000 * 0.01)

        val fast = uploadWindow()
        fast.sample(bytes = 1_500_000, sentAt = 0, latency = 150 * MS) // 10 MB/s wants 4 MB
        assertEquals(ceiling, fast.limitBytes)
    }

    @Test
    fun aStallShorterThanTheRateWindowKeepsTheLimitWhileAFastSampleIsRecent() {
        val window = uploadWindow()
        window.sample(bytes = 256 * 1024L, sentAt = 0, latency = 20 * MS)
        assertEquals(ceiling, window.limitBytes)

        // Stalled for 1.5 s: the fast sample from 20 ms is still recent.
        window.sample(bytes = request, sentAt = 20 * MS, latency = 1_500 * MS)
        assertEquals(ceiling, window.limitBytes)

        // Now past two seconds, the fast sample has aged out.
        window.sample(bytes = request, sentAt = 1_520 * MS, latency = 600 * MS)
        assertTrue(window.limitBytes < ceiling)
    }

    @Test
    fun aStaleMinimumYieldsToAQuietSampleButNotToAQueuedOne() {
        val window = uploadWindow()
        // A 30 ms round trip, then the path slows to one lone request per 1.03 s.
        window.sample(bytes = request, sentAt = 0, latency = 30 * MS)
        var now = 30 * MS
        repeat(9) {
            window.sample(bytes = request, sentAt = now, latency = 1_030 * MS)
            now += 1_030 * MS
        }
        // The minimum is not yet ten seconds old: 32 KB/s × (30 ms + budget)
        // is below one request.
        assertEquals(floor, window.limitBytes)

        // Past ten seconds a sample with nothing queued ahead of it replaces
        // the minimum: 32 KB/s × (1.03 s + budget) is more than one request.
        window.sample(bytes = request, sentAt = now, latency = 1_030 * MS)
        val expected = request.toDouble() / (1_030 * MS) * (1_030 * MS + SftpPipelineWindow.QUEUE_BUDGET_NANOS)
        assertEquals(expected, window.limitBytes.toDouble(), 1.0)
        assertTrue(window.limitBytes > floor)

        // Samples sent behind a queue never raise the minimum, however old.
        val queued = uploadWindow()
        queued.sample(bytes = request, sentAt = 0, latency = 30 * MS)
        var queuedNow = 30 * MS
        repeat(20) {
            val ahead = queued.send(request, queuedNow)
            val ticket = queued.send(request, queuedNow)
            queuedNow += 1_030 * MS
            queued.answer(ahead, queuedNow, succeeded = false)
            queued.answer(ticket, queuedNow, succeeded = true)
        }
        assertEquals(floor, queued.limitBytes)
    }

    @Test
    fun transfersShareOneAccountOfOutstandingBytes() {
        val window = uploadWindow()
        val first = window.send(request, 0)
        val second = window.send(request, 0)
        assertEquals(2 * request, window.outstandingBytes)
        assertEquals("the second request waits behind the first", 2 * request, second.outstandingAtSend)

        window.answer(first, 10 * MS, succeeded = true)
        window.answer(second, 10 * MS, succeeded = true)
        assertEquals(0, window.outstandingBytes)

        // An abandoned request gives its bytes back without a sample: an
        // instant reply would otherwise open the window to the ceiling.
        val abandoned = uploadWindow()
        abandoned.answer(abandoned.send(request, 0), 0, succeeded = false)
        assertEquals(0, abandoned.outstandingBytes)
        assertEquals(4 * request, abandoned.limitBytes)

        // Answering can't take the account below zero.
        abandoned.answer(SftpPipelineWindow.Ticket(request, request, 0), 0, succeeded = false)
        assertEquals(0, abandoned.outstandingBytes)
    }

    @Test
    fun idleWindowRelearnsAfterTenSeconds() {
        val window = uploadWindow()
        window.sample(bytes = 256 * 1024L, sentAt = 0, latency = 20 * MS)
        assertEquals(ceiling, window.limitBytes)

        // Idle just short of the lifetime: nothing changes.
        window.send(request, 20 * MS + SftpPipelineWindow.MIN_LATENCY_LIFETIME_NANOS - 1).let {
            assertEquals(ceiling, window.limitBytes)
            window.answer(it, 20 * MS + SftpPipelineWindow.MIN_LATENCY_LIFETIME_NANOS, succeeded = false)
        }

        // Ten seconds idle: back to the initial limit, the old minimum and rates forgotten.
        val later = 40 * MS + 2 * SftpPipelineWindow.MIN_LATENCY_LIFETIME_NANOS
        val ticket = window.send(4 * request, later)
        assertEquals(4 * request, window.limitBytes)
        window.answer(ticket, later + 100 * MS, succeeded = true)
        assertEquals(4 * request * 3.5, window.limitBytes.toDouble(), 1.0)

        // Bytes still outstanding mean the window isn't idle.
        val busy = uploadWindow()
        busy.sample(bytes = 256 * 1024L, sentAt = 0, latency = 20 * MS)
        busy.send(request, 20 * MS)
        busy.send(request, 20 * MS + 3 * SftpPipelineWindow.MIN_LATENCY_LIFETIME_NANOS)
        assertEquals(ceiling, busy.limitBytes)
    }

    @Test
    fun zeroOrNegativeLatencyDoesNotDivideByZero() {
        val window = uploadWindow()
        window.sample(bytes = request, sentAt = 0, latency = 0)
        assertEquals(ceiling, window.limitBytes)
        window.sample(bytes = request, sentAt = 10, latency = -5)
        assertEquals(ceiling, window.limitBytes)

        val empty = uploadWindow()
        empty.sample(bytes = 0, sentAt = 0, latency = 0)
        assertEquals(floor, empty.limitBytes)
    }

    @Test
    fun hugeLatencyDoesNotOverflowTheHorizon() {
        val window = uploadWindow()

        window.sample(bytes = 4 * request, sentAt = 0, latency = Long.MAX_VALUE)

        // A wrapped horizon would be negative and pin the floor instead.
        assertEquals(4.0 * request, window.limitBytes.toDouble(), 1.0)
    }

    private companion object {
        const val MS = 1_000_000L
    }
}
