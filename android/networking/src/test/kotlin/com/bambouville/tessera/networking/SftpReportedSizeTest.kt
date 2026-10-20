package com.bambouville.tessera.networking

import java.io.IOException
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.sftp.FileAttributes
import net.schmizz.sshj.sftp.FileMode
import net.schmizz.sshj.sftp.PacketType
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * SFTP sends a file's size as a uint64 and sshj reads it into a signed Long.
 * Whatever a hostile or buggy server claims, a download sees either a real
 * size or "unknown", never a negative number. Mirrors the iOS FileBridge fix.
 */
class SftpReportedSizeTest {
    @Test
    fun sshjRefusesASizePastLongMaxValueSoTheDownloadTreatsItAsUnknown() {
        for (wire in listOf(ULong.MAX_VALUE, 1uL shl 63)) {
            assertThrows("size $wire", SFTPException::class.java) { attributesReply(wire).readFileAttributes() }
            assertNull("size $wire", sizeAtOpen { attributesReply(wire).readFileAttributes() })
        }
        // The largest size a Long holds is still a size: read-ahead is
        // bounded by the transfer window, not by this number.
        val largest = Long.MAX_VALUE.toULong()
        assertEquals(Long.MAX_VALUE, sizeAtOpen { attributesReply(largest).readFileAttributes() })
    }

    @Test
    fun negativeOrUnreportedSizesAreUnknown() {
        for (size in listOf(-1L, Long.MIN_VALUE)) {
            assertNull("size $size", FileAttributes.Builder().withSize(size).build().reportedSize())
            assertNull("size $size", sizeAtOpen { FileAttributes.Builder().withSize(size).build() })
        }
        // The field is optional; sshj leaves 0 behind when it is absent.
        val unsized = FileAttributes.Builder().withType(FileMode.Type.REGULAR).build()
        assertEquals(0L, unsized.size)
        assertNull(unsized.reportedSize())
        assertNull(FileAttributes.EMPTY.reportedSize())
        assertNull(sizeAtOpen { throw IOException("FSTAT failed") })
    }

    @Test
    fun realSizesPassThrough() {
        for (size in listOf(0L, 1L, 3L * 1024 * 1024 + 777)) {
            assertEquals(size, FileAttributes.Builder().withSize(size).build().reportedSize())
            assertEquals(size, sizeAtOpen { attributesReply(size.toULong()).readFileAttributes() })
        }
    }

    /** An ATTRS reply carrying only a size, exactly as it crosses the wire. */
    private fun attributesReply(size: ULong): Response {
        val packet = Buffer.PlainBuffer()
        packet.putByte(PacketType.ATTRS.toByte())
        packet.putUInt32(1)
        packet.putUInt32(FileAttributes.Flag.SIZE.get().toLong())
        packet.putRawBytes(ByteArray(8) { index -> (size shr (56 - 8 * index)).toByte() })
        @Suppress("UNCHECKED_CAST")
        return Response(packet as Buffer<Response>, 3)
    }
}
