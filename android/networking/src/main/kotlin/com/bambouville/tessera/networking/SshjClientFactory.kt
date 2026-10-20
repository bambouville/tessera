package com.bambouville.tessera.networking

import com.hierynomus.sshj.key.KeyAlgorithm
import java.security.PublicKey
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.Security
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.X509EncodedKeySpec
import java.security.interfaces.ECPublicKey
import java.util.Collections
import java.util.WeakHashMap
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.Factory
import net.schmizz.sshj.common.KeyType
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.SecurityUtils
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.signature.AbstractSignature
import javax.net.SocketFactory

data class SshHostKeyObservation(
    val host: String,
    val port: Int,
    val algorithm: String,
    val canonicalKeyBlob: ByteArray,
)

/**
 * Phase A boundary around SSHJ. Host trust remains owned by the caller so the
 * product can apply the same known-host policy on direct and jump connections.
 */
class SshjClientFactory(
    private val preferredHostKeyAlgorithms: List<String>? = null,
    /** Where direct connections get their socket; SSHJ's default when null. */
    private val socketFactory: SocketFactory? = null,
    private val hostKeyPolicy: (SshHostKeyObservation) -> Boolean,
) {
    fun create(): SSHClient {
        AndroidSshKeyFactoryProvider.install()
        val config = DefaultConfig().apply {
            keyAlgorithms = keyAlgorithms.map(AndroidHostKeyAlgorithms::wrap)
            preferredHostKeyAlgorithms?.let { preferred ->
                val order = preferred.withIndex().associate { it.value to it.index }
                keyAlgorithms = keyAlgorithms
                    .filter { it.name in order }
                    .sortedBy { order.getValue(it.name) }
                require(keyAlgorithms.isNotEmpty()) {
                    "none of the requested host-key algorithms are supported: $preferred"
                }
            }
        }
        return SSHClient(config).apply {
            this@SshjClientFactory.socketFactory?.let { setSocketFactory(it) }
            connectTimeout = CONNECT_TIMEOUT_MILLISECONDS
            // SSHJ maps this value directly to Socket.setSoTimeout. Interactive PTYs and
            // reusable SFTP side channels are intentionally idle for long periods, so a
            // finite transport read timeout tears down healthy sessions while the user is
            // reading terminal output or leaving an SFTP side channel idle between operations.
            timeout = 0
            addHostKeyVerifier(object : HostKeyVerifier {
                override fun verify(hostname: String, port: Int, key: PublicKey): Boolean =
                    (AndroidHostKeyAlgorithms.material(key) ?: KeyType.fromKey(key).let { keyType ->
                        val buffer = Buffer.PlainBuffer()
                        keyType.putPubKeyIntoBuffer(key, buffer)
                        AndroidHostKeyAlgorithms.Material(keyType.toString(), buffer.compactData)
                    }).let { material ->
                        hostKeyPolicy(
                            SshHostKeyObservation(hostname, port, material.algorithm, material.blob),
                        )
                    }

                override fun findExistingAlgorithms(hostname: String, port: Int): List<String> =
                    emptyList()
            })
        }
    }

    companion object {
        private const val CONNECT_TIMEOUT_MILLISECONDS = 15_000

        init {
            // AndroidKeyStore keys must be signed by their owning JCA provider.
            // SSHJ 0.40 does not require Bouncy Castle, so keep provider routing
            // deterministic and avoid BC intercepting the Keystore private key.
            SecurityUtils.setRegisterBouncyCastle(false)
        }
    }
}

/** Android-safe decoders for SSHJ's common EC and Ed25519 host-key formats. */
private object AndroidHostKeyAlgorithms {
    data class Material(val algorithm: String, val blob: ByteArray)

    private val decoded = Collections.synchronizedMap(WeakHashMap<PublicKey, Material>())

    fun material(key: PublicKey): Material? =
        decoded[key]?.let { Material(it.algorithm, it.blob.copyOf()) }
            ?: materialFromStandardKey(key)

    fun wrap(factory: Factory.Named<KeyAlgorithm>): Factory.Named<KeyAlgorithm> {
        val name = factory.name
        if (name.contains("-cert-")) return factory
        val decoder: ((Buffer<*>) -> PublicKey)? = when {
            name.startsWith("ecdsa-sha2-nistp") -> { buffer -> decodeEcdsa(name, buffer) }
            name == "ssh-ed25519" -> ::decodeEd25519
            else -> null
        }
        if (decoder == null) return factory
        return object : Factory.Named<KeyAlgorithm> {
            override fun getName(): String = name

            override fun create(): KeyAlgorithm {
                val delegate = factory.create()
                return object : KeyAlgorithm by delegate {
                    override fun newSignature(): net.schmizz.sshj.signature.Signature =
                        if (name == "ssh-ed25519") ConscryptEd25519Signature()
                        else delegate.newSignature()

                    override fun readPubKeyFromBuffer(buffer: Buffer<*>): PublicKey {
                        val start = buffer.rpos()
                        val key = decoder(buffer)
                        val end = buffer.rpos()
                        val contents = buffer.array().copyOfRange(start, end)
                        decoded[key] = Material(name, sshString(name.encodeToByteArray()) + contents)
                        return key
                    }
                }
            }
        }
    }

    private fun decodeEcdsa(algorithm: String, buffer: Buffer<*>): PublicKey {
        val curveWire = buffer.readString()
        val expectedWire = algorithm.removePrefix("ecdsa-sha2-")
        require(curveWire == expectedWire) { "ECDSA host-key curve mismatch" }
        val encodedPoint = buffer.readStringAsBytes()
        val coordinateBytes = when (curveWire) {
            "nistp256" -> 32
            "nistp384" -> 48
            "nistp521" -> 66
            else -> error("unsupported ECDSA host-key curve")
        }
        require(encodedPoint.size == 1 + coordinateBytes * 2 && encodedPoint[0] == 4.toByte()) {
            "unsupported ECDSA host-key point"
        }
        val curveName = when (curveWire) {
            "nistp256" -> "secp256r1"
            "nistp384" -> "secp384r1"
            else -> "secp521r1"
        }
        val parameters = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec(curveName))
        }.getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(
            encodedPoint.copyOfRange(1, 1 + coordinateBytes).positiveBigInteger(),
            encodedPoint.copyOfRange(1 + coordinateBytes, encodedPoint.size).positiveBigInteger(),
        )
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters))
    }

    private fun decodeEd25519(buffer: Buffer<*>): PublicKey {
        val raw = buffer.readStringAsBytes()
        require(raw.size == 32) { "invalid Ed25519 host key" }
        val x509 = byteArrayOf(
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
        ) + raw
        val factory = Security.getProviders().asSequence()
            .filterNot { it.name == "AndroidKeyStore" }
            .mapNotNull { provider -> runCatching { KeyFactory.getInstance("Ed25519", provider) }.getOrNull() }
            .firstOrNull()
            ?: KeyFactory.getInstance("Ed25519")
        return factory.generatePublic(X509EncodedKeySpec(x509))
    }

    private fun materialFromStandardKey(key: PublicKey): Material? {
        if (key.algorithm.equals("Ed25519", ignoreCase = true) ||
            key.algorithm.equals("EdDSA", ignoreCase = true) ||
            key.algorithm == "1.3.101.112"
        ) {
            val encoded = key.encoded ?: return null
            if (encoded.size < 32) return null
            val raw = encoded.copyOfRange(encoded.size - 32, encoded.size)
            val algorithm = "ssh-ed25519"
            return Material(
                algorithm,
                sshString(algorithm.encodeToByteArray()) + sshString(raw),
            )
        }

        val ec = key as? ECPublicKey ?: return null
        val coordinateBytes = (ec.params.curve.field.fieldSize + 7) / 8
        val curve = when (coordinateBytes) {
            32 -> "nistp256"
            48 -> "nistp384"
            66 -> "nistp521"
            else -> return null
        }
        val algorithm = "ecdsa-sha2-$curve"
        val point = byteArrayOf(4) +
            ec.w.affineX.toFixedUnsigned(coordinateBytes) +
            ec.w.affineY.toFixedUnsigned(coordinateBytes)
        return Material(
            algorithm,
            sshString(algorithm.encodeToByteArray()) +
                sshString(curve.encodeToByteArray()) +
                sshString(point),
        )
    }

    private fun ByteArray.positiveBigInteger() = java.math.BigInteger(1, this)

    private fun java.math.BigInteger.toFixedUnsigned(size: Int): ByteArray {
        val raw = toByteArray()
        val unsigned = if (raw.size == size + 1 && raw[0] == 0.toByte()) raw.copyOfRange(1, raw.size) else raw
        require(unsigned.size <= size) { "EC coordinate is larger than its curve" }
        return ByteArray(size - unsigned.size) + unsigned
    }

    private fun sshString(value: ByteArray): ByteArray = byteArrayOf(
        (value.size ushr 24).toByte(),
        (value.size ushr 16).toByte(),
        (value.size ushr 8).toByte(),
        value.size.toByte(),
    ) + value

    private class ConscryptEd25519Signature : AbstractSignature(
        java.security.Signature.getInstance(
            "Ed25519",
            AndroidSshKeyFactoryProvider.importedKeys(),
        ),
        "ssh-ed25519",
    ) {
        override fun encode(signature: ByteArray): ByteArray = signature

        override fun verify(signature: ByteArray): Boolean =
            this.signature.verify(extractSig(signature, "ssh-ed25519"))
    }
}
