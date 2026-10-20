package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedBackendCommand
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * Splits backend commands into two lanes: one ordered stream for the commands
 * that carry user input, and an independent coroutine for everything else.
 *
 * Input is a byte stream, so the commands carrying it have to reach the
 * transport in the order the terminal produced them. A coroutine per command
 * does not preserve that: a burst is dispatched onto a multi-threaded pool and
 * every byte then races through the transport's own dispatcher hop
 * (`MoshTransport.send` hops to `Dispatchers.IO` and takes a mutex; the SSH
 * writer and the tmux control queue are reached the same way). Typing hides it
 * because keystrokes are ~100 ms apart, far wider than the dispatch window. An
 * IME autocorrect revision is not: Gboard replaces a word with four DELs and
 * nine characters roughly 2 ms apart, and those arrived at the pty shuffled --
 * "something" typed, "smehtiong" echoed, the right letters in the wrong order.
 *
 * So input takes one unlimited channel with a single consumer, the shape
 * [MoshResizeRequest]'s writer already uses so that two resizes cannot land on
 * the PTY inverted. Everything else keeps its own coroutine, which is what
 * stops a slow connect or teardown from wedging typing behind it, and stops a
 * cancel from queueing behind the connect it cancels.
 */
internal class BackendCommandDispatcher(
    private val scope: CoroutineScope,
    private val perform: suspend (SharedBackendCommand) -> Unit,
) {
    private val ordered = Channel<SharedBackendCommand>(Channel.UNLIMITED)
    private val consumer: Job = scope.launch {
        for (command in ordered) perform(command)
    }

    fun dispatch(command: SharedBackendCommand) {
        if (command.carriesOrderedInput()) {
            // Unlimited, so this never blocks the caller and never drops a
            // byte; it fails only once the lane is closed, past which `perform`
            // would refuse the command anyway.
            ordered.trySend(command)
        } else {
            scope.launch { perform(command) }
        }
    }

    fun close() {
        ordered.close()
        consumer.cancel()
    }
}

/**
 * Whether this command's bytes belong to the one ordered input stream.
 *
 * `SendTmuxPaneKey` joins the byte-carrying commands because an Enter that
 * follows typed bytes must still follow them on the wire. Resize deliberately
 * stays out: it is not part of the stream, and the mosh path already conflates
 * it through its own single-consumer writer.
 */
internal fun SharedBackendCommand.carriesOrderedInput(): Boolean = when (this) {
    is SharedBackendCommand.SendInput,
    is SharedBackendCommand.SendTmuxPaneInput,
    is SharedBackendCommand.SendTmuxPaneKey,
    -> true
    else -> false
}
