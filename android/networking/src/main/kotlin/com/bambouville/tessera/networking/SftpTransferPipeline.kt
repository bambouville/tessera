package com.bambouville.tessera.networking

import java.io.OutputStream

/** The two requests a pipelined transfer sends: sshj's file in production, a script in tests. */
internal interface SftpPipelineFile {
    /** The caller may reuse [data] once this returns. */
    fun sendWrite(offset: Long, data: ByteArray, length: Int): SftpPendingReply<Unit>

    fun sendRead(offset: Long, length: Int): SftpPendingReply<SftpReadReply>
}

internal interface SftpPendingReply<T> {
    /** The reply, or its failure, has arrived. */
    val isAnswered: Boolean

    /** Blocks for the reply; throws if it failed or never came. */
    fun await(): T
}

internal sealed interface SftpReadReply {
    /** [count] bytes, 1 to the length requested, at [offset] in [bytes]. */
    class Data(val bytes: ByteArray, val offset: Int, val count: Int) : SftpReadReply

    data object EndOfFile : SftpReadReply
}

/**
 * Pipelined SFTP transfer loops, apart from sshj so a scripted server can
 * test them. Each runs on the caller's thread and blocks on replies; the
 * [SftpPipelineWindow] the connection shares across its transfers bounds the
 * bytes in flight. The iOS app's `SFTPTransferPipeline` follows the same rules.
 */
internal object SftpTransferPipeline {
    /** Every OpenSSH release answers 64 KiB reads in full. */
    const val READ_REQUEST_BYTES = 64 * 1024

    /** A capped server shrinks reads, but never below this, so a tiny cap can't leave the rest of a file crawling. */
    const val MIN_READ_REQUEST_BYTES = 4 * 1024
    const val PROGRESS_STEP_BYTES = 256 * 1024L
    const val PROGRESS_INTERVAL_NANOS = 200_000_000L

    /**
     * Writes [readChunk]'s chunks (-1 at end of input, 0 for nothing yet) at
     * consecutive offsets, reporting bytes the server acknowledged, never
     * bytes merely queued.
     */
    suspend fun upload(
        file: SftpPipelineFile,
        window: SftpPipelineWindow,
        readChunk: (ByteArray) -> Int,
        requestBytes: Int,
        progress: suspend (Long) -> Unit,
        nanoTime: () -> Long,
        checkCancelled: () -> Unit,
    ) {
        val inFlight = ArrayDeque<InFlight<Unit>>()
        val buffer = ByteArray(requestBytes)
        val throttle = ProgressThrottle(nanoTime(), progress)
        var submitted = 0L

        // Cancellation takes effect at the next acknowledgement, before anything more is queued.
        suspend fun confirmOldest() {
            val write = inFlight.removeFirst()
            write.await(window, nanoTime)
            throttle.report(write.offset + write.length, nanoTime())
            checkCancelled()
        }

        try {
            while (true) {
                checkCancelled()
                // Replies that already arrived first, so samples and progress stay timely.
                while (inFlight.firstOrNull()?.reply?.isAnswered == true) confirmOldest()
                while (inFlight.isNotEmpty() && window.outstandingBytes + requestBytes > window.limitBytes) {
                    confirmOldest()
                }
                val count = readChunk(buffer)
                if (count < 0) break
                if (count == 0) continue
                inFlight.addLast(issue(window, submitted, count, nanoTime) { file.sendWrite(submitted, buffer, count) })
                submitted += count
            }
            while (inFlight.isNotEmpty()) confirmOldest()
            progress(submitted)
        } finally {
            abandon(window, inFlight, nanoTime)
        }
    }

    /**
     * Reads from offset 0 to end of file into [output], strictly in order.
     * [sizeAtOpen] bounds read-ahead; past it one request at a time probes
     * for end of file, until a full reply shows the file grew.
     */
    suspend fun download(
        file: SftpPipelineFile,
        window: SftpPipelineWindow,
        sizeAtOpen: Long?,
        output: OutputStream,
        progress: suspend (Long) -> Unit,
        nanoTime: () -> Long,
        checkCancelled: () -> Unit,
    ) {
        val inFlight = ArrayDeque<InFlight<SftpReadReply>>()
        val throttle = ProgressThrottle(nanoTime(), progress)
        var readAheadLimit = sizeAtOpen ?: Long.MAX_VALUE
        var requestLength = READ_REQUEST_BYTES
        var lastShortReply: Int? = null
        var nextOffset = 0L
        var delivered = 0L

        // A reply leaves the window when it arrives, not when it is consumed,
        // so the window counts only bytes still crossing the link. Servers
        // answer in order, so arrivals lead the queue.
        fun sweep() {
            for (read in inFlight) {
                if (read.answered) continue
                if (!read.reply.isAnswered) break
                read.settle(window, nanoTime(), succeeded = true)
            }
        }

        try {
            while (true) {
                checkCancelled()
                sweep()
                while (inFlight.isEmpty() ||
                    (nextOffset < readAheadLimit && window.outstandingBytes + requestLength <= window.limitBytes)
                ) {
                    inFlight.addLast(
                        issue(window, nextOffset, requestLength, nanoTime) { file.sendRead(nextOffset, requestLength) },
                    )
                    nextOffset += requestLength
                    sweep()
                }
                val read = inFlight.removeFirst()
                val data = when (val reply = read.await(window, nanoTime)) {
                    SftpReadReply.EndOfFile -> break
                    is SftpReadReply.Data -> reply
                }
                output.write(data.bytes, data.offset, data.count)
                delivered += data.count
                if (data.count < read.length) {
                    // The requests after a short reply start past a gap: drop
                    // them (their late replies are ignored) and resume at the
                    // gap. Two identical short replies in a row mean the server
                    // caps reads; one alone may be the tail of a growing file.
                    if (lastShortReply == data.count) requestLength = maxOf(data.count, MIN_READ_REQUEST_BYTES)
                    lastShortReply = data.count
                    abandon(window, inFlight, nanoTime)
                    inFlight.clear()
                    nextOffset = delivered
                } else {
                    lastShortReply = null
                    // A full reply past the size at open: the file grew.
                    if (sizeAtOpen != null && read.offset + read.length > sizeAtOpen) readAheadLimit = Long.MAX_VALUE
                }
                throttle.report(delivered, nanoTime())
            }
            output.flush()
            progress(delivered)
        } finally {
            abandon(window, inFlight, nanoTime)
        }
    }

    /** Takes [length] bytes of [window], then sends; a send that throws gives them back. */
    private inline fun <T> issue(
        window: SftpPipelineWindow,
        offset: Long,
        length: Int,
        nanoTime: () -> Long,
        send: () -> SftpPendingReply<T>,
    ): InFlight<T> {
        val ticket = window.send(length.toLong(), nanoTime())
        val reply = try {
            send()
        } catch (failure: Throwable) {
            window.answer(ticket, nanoTime(), succeeded = false)
            throw failure
        }
        return InFlight(offset, length, ticket, reply)
    }

    /** Gives back the bytes of requests whose replies will be ignored. */
    private fun abandon(window: SftpPipelineWindow, requests: Collection<InFlight<*>>, nanoTime: () -> Long) {
        if (requests.isEmpty()) return
        val now = nanoTime()
        for (request in requests) request.settle(window, now, succeeded = false)
    }

    private class InFlight<T>(
        val offset: Long,
        val length: Int,
        val ticket: SftpPipelineWindow.Ticket,
        val reply: SftpPendingReply<T>,
    ) {
        /** Its bytes went back to the window. */
        var answered = false
            private set

        fun settle(window: SftpPipelineWindow, now: Long, succeeded: Boolean) {
            if (answered) return
            answered = true
            window.answer(ticket, now, succeeded)
        }

        /** The reply; a failed one gives its bytes back without a sample. */
        fun await(window: SftpPipelineWindow, nanoTime: () -> Long): T {
            val result = try {
                reply.await()
            } catch (failure: Throwable) {
                settle(window, nanoTime(), succeeded = false)
                throw failure
            }
            settle(window, nanoTime(), succeeded = true)
            return result
        }
    }

    /** Reports every [PROGRESS_STEP_BYTES] or [PROGRESS_INTERVAL_NANOS], whichever comes first. */
    private class ProgressThrottle(private var reportedAt: Long, private val progress: suspend (Long) -> Unit) {
        private var reported = 0L

        suspend fun report(bytes: Long, now: Long) {
            if (bytes - reported < PROGRESS_STEP_BYTES && now - reportedAt < PROGRESS_INTERVAL_NANOS) return
            progress(bytes)
            reported = bytes
            reportedAt = now
        }
    }
}
