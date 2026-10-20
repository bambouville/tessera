package com.bambouville.tessera.agent.platform

import java.util.Base64

/** Bounded transport parser for the private lifecycle OSC; it does not parse provider state. */
class AgentLifecycleOscScanner {
    private enum class State { NORMAL, ESCAPE, OSC, SKIP, OSC_ESCAPE, SKIP_ESCAPE }

    private var state = State.NORMAL
    private val buffer = ArrayList<Byte>(MAX_OSC_BYTES)
    private var skipped = 0

    fun feed(bytes: ByteArray): List<ByteArray> {
        val frames = mutableListOf<ByteArray>()
        var index = 0
        while (index < bytes.size) {
            when (state) {
                State.NORMAL -> if (bytes[index] == ESC) state = State.ESCAPE
                State.ESCAPE -> when (bytes[index]) {
                    OSC -> begin()
                    ESC -> Unit
                    else -> state = State.NORMAL
                }
                State.OSC -> when (bytes[index]) {
                    BEL -> finish(frames)
                    ESC -> state = State.OSC_ESCAPE
                    else -> append(bytes[index])
                }
                State.OSC_ESCAPE -> if (bytes[index] == ST) finish(frames) else {
                    append(ESC)
                    append(bytes[index])
                    if (state == State.OSC_ESCAPE) state = State.OSC
                }
                State.SKIP -> when (bytes[index]) {
                    BEL -> state = State.NORMAL
                    ESC -> state = State.SKIP_ESCAPE
                    else -> if (++skipped > MAX_OSC_BYTES) state = State.NORMAL
                }
                State.SKIP_ESCAPE -> if (bytes[index] == ST) state = State.NORMAL else {
                    skipped += 2
                    state = if (skipped > MAX_OSC_BYTES) State.NORMAL else State.SKIP
                }
            }
            index += 1
        }
        return frames
    }

    private fun begin() {
        state = State.OSC
        buffer.clear()
        skipped = 0
    }

    private fun append(byte: Byte) {
        if (buffer.size >= MAX_OSC_BYTES) {
            state = State.NORMAL
            buffer.clear()
            return
        }
        buffer += byte
        val check = minOf(buffer.size, PREFIX.size)
        for (index in 0 until check) {
            if (buffer[index] != PREFIX[index]) {
                state = State.SKIP
                buffer.clear()
                skipped = 0
                return
            }
        }
    }

    private fun finish(frames: MutableList<ByteArray>) {
        if (buffer.size > PREFIX.size && buffer.take(PREFIX.size) == PREFIX) {
            val encoded = buffer.drop(PREFIX.size).toByteArray().decodeToString()
            val decoded = runCatching { Base64.getDecoder().decode(encoded) }.getOrNull()
            if (decoded != null && decoded.isNotEmpty() && decoded.size <= MAX_LIFECYCLE_BYTES) frames += decoded
        }
        state = State.NORMAL
        buffer.clear()
        skipped = 0
    }

    private companion object {
        const val ESC: Byte = 0x1b
        const val OSC: Byte = 0x5d
        const val ST: Byte = 0x5c
        const val BEL: Byte = 0x07
        const val MAX_OSC_BYTES = 16 * 1024
        const val MAX_LIFECYCLE_BYTES = 12 * 1024
        val PREFIX = "1337;TesseraAgentState=".encodeToByteArray().toList()
    }
}
