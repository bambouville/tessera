package com.bambouville.tessera.security

import java.math.BigInteger
import java.security.interfaces.ECPublicKey

object SshEcdsaP256Codec {
    private val algorithm = "ecdsa-sha2-nistp256".encodeToByteArray()
    private val curve = "nistp256".encodeToByteArray()

    fun publicKeyBlob(publicKey: ECPublicKey): ByteArray {
        val point = byteArrayOf(0x04) +
            fixedUnsigned(publicKey.w.affineX, 32) +
            fixedUnsigned(publicKey.w.affineY, 32)
        return sshString(algorithm) + sshString(curve) + sshString(point)
    }

    /** SSH ECDSA signature blob: string(mpint r) || string(mpint s). */
    fun derToSshBlob(der: ByteArray): ByteArray {
        val reader = DerReader(der)
        val sequence = reader.read(0x30)
        check(reader.exhausted()) { "trailing DER signature bytes" }
        val integers = DerReader(sequence)
        val r = canonicalPositiveMpint(integers.read(0x02))
        val s = canonicalPositiveMpint(integers.read(0x02))
        check(integers.exhausted()) { "unexpected DER signature fields" }
        return sshString(r) + sshString(s)
    }

    fun sshBlobToDer(blob: ByteArray): ByteArray {
        val reader = SshReader(blob)
        val r = reader.readString()
        val s = reader.readString()
        check(reader.exhausted()) { "trailing SSH signature bytes" }
        val body = derInteger(r) + derInteger(s)
        return byteArrayOf(0x30) + derLength(body.size) + body
    }

    private fun fixedUnsigned(value: BigInteger, size: Int): ByteArray {
        val source = value.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
        require(source.size <= size) { "coordinate exceeds P-256 width" }
        return ByteArray(size - source.size) + source
    }

    private fun canonicalPositiveMpint(bytes: ByteArray): ByteArray {
        require(bytes.isNotEmpty()) { "empty DER integer" }
        require((bytes[0].toInt() and 0x80) == 0) { "negative DER integer" }
        var index = 0
        while (index < bytes.lastIndex && bytes[index] == 0.toByte() &&
            (bytes[index + 1].toInt() and 0x80) == 0
        ) {
            index += 1
        }
        return bytes.copyOfRange(index, bytes.size)
    }

    private fun derInteger(mpint: ByteArray): ByteArray {
        val canonical = canonicalPositiveMpint(mpint)
        val value = if ((canonical[0].toInt() and 0x80) != 0) {
            byteArrayOf(0) + canonical
        } else {
            canonical
        }
        return byteArrayOf(0x02) + derLength(value.size) + value
    }

    private fun sshString(value: ByteArray): ByteArray {
        val size = value.size
        return byteArrayOf(
            (size ushr 24).toByte(),
            (size ushr 16).toByte(),
            (size ushr 8).toByte(),
            size.toByte(),
        ) + value
    }

    private fun derLength(size: Int): ByteArray {
        require(size in 0..255)
        return if (size < 128) byteArrayOf(size.toByte())
        else byteArrayOf(0x81.toByte(), size.toByte())
    }

    private class DerReader(private val bytes: ByteArray) {
        private var offset = 0

        fun read(expectedTag: Int): ByteArray {
            require(offset < bytes.size && (bytes[offset++].toInt() and 0xff) == expectedTag) {
                "unexpected DER tag"
            }
            require(offset < bytes.size) { "missing DER length" }
            val first = bytes[offset++].toInt() and 0xff
            val length = when {
                first < 128 -> first
                first == 0x81 -> {
                    require(offset < bytes.size) { "missing DER long length" }
                    bytes[offset++].toInt() and 0xff
                }
                else -> error("unsupported DER length")
            }
            require(length >= 0 && offset + length <= bytes.size) { "invalid DER length" }
            return bytes.copyOfRange(offset, offset + length).also { offset += length }
        }

        fun exhausted(): Boolean = offset == bytes.size
    }

    private class SshReader(private val bytes: ByteArray) {
        private var offset = 0

        fun readString(): ByteArray {
            require(offset + 4 <= bytes.size) { "missing SSH string length" }
            var length = 0
            repeat(4) { length = (length shl 8) or (bytes[offset++].toInt() and 0xff) }
            require(length >= 0 && offset + length <= bytes.size) { "invalid SSH string length" }
            return bytes.copyOfRange(offset, offset + length).also { offset += length }
        }

        fun exhausted(): Boolean = offset == bytes.size
    }
}
