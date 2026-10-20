package com.bambouville.tessera.networking

/**
 * How many bytes pipelined SFTP requests on one connection may leave
 * unanswered in one direction. That is the queue every other request on the
 * connection waits behind: browsing, the CLOSE that ends a cancelled
 * transfer, the terminal when the files channel rides the live route.
 *
 * The limit is the fastest rate answered in the last [RATE_WINDOW_NANOS]
 * times (the quickest latency + [QUEUE_BUDGET_NANOS]): enough to keep the
 * link busy with about the budget queued. Below saturation a sample's latency
 * is mostly round trip, so the limit grows by (round trip + budget) / round
 * trip each round trip; at saturation it is mostly queue, so the limit holds.
 *
 * Only a sample sent with at most the floor outstanding may replace a minimum
 * older than [MIN_LATENCY_LIFETIME_NANOS]. Its latency is a round trip rather
 * than queue, so a path that got slower is learned, while samples taken
 * behind a queue can't ratchet the minimum up.
 *
 * Transfers on a connection share its window for their direction. Private
 * windows would each count only their own bytes: a transfer starting behind
 * another would take that queue for its round trip, and together they would
 * queue twice the budget.
 *
 * The iOS app's `SFTPPipelineWindow` is the same controller. Thread-safe;
 * callers pass nanoseconds from one monotonic clock.
 */
internal class SftpPipelineWindow(
    private val floorBytes: Long,
    private val ceilingBytes: Long,
    initialBytes: Long,
) {
    /** A sent request's share of the window; [answer] each ticket once. */
    class Ticket(val bytes: Long, val outstandingAtSend: Long, val sentAt: Long)

    private class RateSample(val answeredAt: Long, val bytesPerNano: Double)

    private val initialLimitBytes = initialBytes.coerceIn(floorBytes, ceilingBytes)
    private var limit = initialLimitBytes
    private var outstanding = 0L
    private var minimumLatencyNanos = Long.MAX_VALUE
    private var minimumLatencyStamp = 0L
    private var lastActivity = 0L

    /**
     * Rate samples, oldest first and fastest first: a sample that a newer,
     * faster one outranks can never be the maximum again, so it goes at once.
     */
    private val rates = ArrayDeque<RateSample>()

    val limitBytes: Long
        @Synchronized get() = limit

    val outstandingBytes: Long
        @Synchronized get() = outstanding

    /** [bytes] leave now; the ticket counts all unanswered bytes, these included. */
    @Synchronized
    fun send(bytes: Long, now: Long): Ticket {
        if (outstanding == 0L && rates.isNotEmpty() && now - lastActivity >= MIN_LATENCY_LIFETIME_NANOS) {
            // Idle long enough for the path to have changed: learn it again.
            limit = initialLimitBytes
            minimumLatencyNanos = Long.MAX_VALUE
            rates.clear()
        }
        outstanding += bytes
        lastActivity = now
        return Ticket(bytes, outstanding, now)
    }

    /**
     * [ticket]'s reply arrived at [now], or it was abandoned. Only an arrival
     * is a sample: the server answers in order, so every byte outstanding
     * when the request left crossed in that time.
     */
    @Synchronized
    fun answer(ticket: Ticket, now: Long, succeeded: Boolean) {
        outstanding = (outstanding - ticket.bytes).coerceAtLeast(0)
        lastActivity = now
        if (succeeded) record(ticket.outstandingAtSend, maxOf(now - ticket.sentAt, 1), now)
    }

    private fun record(outstandingAtSend: Long, latency: Long, now: Long) {
        if (latency < minimumLatencyNanos ||
            (outstandingAtSend <= floorBytes && now - minimumLatencyStamp >= MIN_LATENCY_LIFETIME_NANOS)
        ) {
            minimumLatencyNanos = latency
            minimumLatencyStamp = now
        }
        val rate = outstandingAtSend.toDouble() / latency
        while (rates.isNotEmpty() && rates.last().bytesPerNano <= rate) rates.removeLast()
        rates.addLast(RateSample(now, rate))
        while (rates.size > 1 && now - rates.first().answeredAt > RATE_WINDOW_NANOS) rates.removeFirst()
        // In Double, so a huge latency can't overflow the horizon.
        val horizon = minimumLatencyNanos.toDouble() + QUEUE_BUDGET_NANOS
        limit = (rates.first().bytesPerNano * horizon)
            .coerceIn(floorBytes.toDouble(), ceilingBytes.toDouble())
            .toLong()
    }

    companion object {
        const val QUEUE_BUDGET_NANOS = 250_000_000L

        /** The limit follows the fastest sample this recent, so one stalled reply doesn't shrink it. */
        const val RATE_WINDOW_NANOS = 2_000_000_000L

        /** A minimum latency this old yields to a near-empty sample; an idle window this long relearns. */
        const val MIN_LATENCY_LIFETIME_NANOS = 10_000_000_000L
    }
}
