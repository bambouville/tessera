package com.bambouville.tessera.core.bridge

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * The pairing QR text codec and the cross-device command canonicalizer.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraPairingCore/PairingQRTextCodecV1.swift`
 * and `Sources/TesseraCoreABI/CrossDevicePairingABI.swift`. The ABI seam is
 * `Sources/TesseraCoreABI/PairingQRABI.swift`.
 *
 * Both exist for one reason: the pairing boundary accepts exactly one byte
 * sequence for a given meaning, and a builder on this side will eventually
 * disagree with Swift's encoder about key order or escaping. Rather than
 * reproduce Swift's JSON here, submit what you have and take back the
 * canonical form.
 */

/** Why a scanned QR payload was refused. */
enum class SharedPairingQrRejection(val wireValue: String) {
    /** Wrong prefix, or a character outside the strict base64url alphabet. */
    InvalidFormat("invalidFormat"),

    /** The alphabet was right but the bytes are not. */
    InvalidBase64Url("invalidBase64URL"),

    TooLarge("tooLarge"),

    /**
     * The payload decoded but does not re-encode to the exact text that was
     * scanned. A re-spelled offer is rejected rather than normalized.
     */
    NonCanonical("nonCanonical");

    companion object {
        fun fromWire(value: String): SharedPairingQrRejection =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared pairing QR rejection")
    }
}

/** A decoded pairing offer. */
data class SharedPairingOffer(
    /**
     * The CANONICAL offer encoding — what to forward to the pairing runtime,
     * not the scanned text and not a local re-encoding.
     */
    val offerBytes: ByteArray,
    val offerId: String,
    val version: Int,
    val purpose: String,
    val originRole: String,
    /** Unix time in whole seconds. */
    val expiresAt: Long,
    val supportedPairingVersions: List<Int>,
    val supportedTransactionVersions: List<Int>,
) {
    override fun equals(other: Any?): Boolean =
        other is SharedPairingOffer && offerBytes.contentEquals(other.offerBytes) &&
            offerId == other.offerId && version == other.version && purpose == other.purpose &&
            originRole == other.originRole && expiresAt == other.expiresAt &&
            supportedPairingVersions == other.supportedPairingVersions &&
            supportedTransactionVersions == other.supportedTransactionVersions

    override fun hashCode(): Int = offerBytes.contentHashCode() * 31 + offerId.hashCode()
}

sealed interface SharedPairingQrDecode {
    data class Decoded(val offer: SharedPairingOffer) : SharedPairingQrDecode
    data class Rejected(val reason: SharedPairingQrRejection) : SharedPairingQrDecode
}

sealed interface SharedPairingQrEncode {
    data class Encoded(val text: String) : SharedPairingQrEncode
    data class Rejected(val reason: SharedPairingQrRejection) : SharedPairingQrEncode
}

/** Typed facade over `Sources/TesseraCoreABI/PairingQRABI.swift`. */
object SharedPairingQR {
    /**
     * Decodes scanner text into a canonical offer.
     *
     * The grammar is a small closed one, parsed directly rather than through
     * URL normalization: no percent escapes, no alternate query layouts, no
     * optional URL components.
     */
    fun decodeOffer(text: String): SharedPairingQrDecode {
        require(text.isNotEmpty())
        NativeLibraries.ensureLoaded()
        val bytes = text.encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.pairingQrDecodeOffer(bytes.toDirectBuffer(), bytes.size),
        )
        if (!value.getBoolean("ok")) {
            return SharedPairingQrDecode.Rejected(
                SharedPairingQrRejection.fromWire(value.getString("error")),
            )
        }
        fun versions(key: String): List<Int> = value.getJSONArray(key).let { array ->
            List(array.length()) { array.getInt(it) }
        }
        return SharedPairingQrDecode.Decoded(
            SharedPairingOffer(
                offerBytes = Base64.decode(value.getString("offerBytes"), Base64.DEFAULT),
                offerId = value.getString("offerID"),
                version = value.getInt("version"),
                purpose = value.getString("purpose"),
                originRole = value.getString("originRole"),
                expiresAt = value.getLong("expiresAt"),
                supportedPairingVersions = versions("supportedPairingVersions"),
                supportedTransactionVersions = versions("supportedTransactionVersions"),
            ),
        )
    }

    /**
     * Renders offer bytes as QR text. The bytes are re-decoded and re-encoded
     * canonically first, so a hand-built offer cannot reach a QR image that the
     * scanning side would then reject as non-canonical.
     */
    fun encodeOffer(offerBytes: ByteArray): SharedPairingQrEncode {
        require(offerBytes.isNotEmpty())
        NativeLibraries.ensureLoaded()
        val value = JSONObject(
            NativeCoreBindings.pairingQrEncodeOffer(
                offerBytes.toDirectBuffer(),
                offerBytes.size,
            ),
        )
        if (!value.getBoolean("ok")) {
            return SharedPairingQrEncode.Rejected(
                SharedPairingQrRejection.fromWire(value.getString("error")),
            )
        }
        return SharedPairingQrEncode.Encoded(value.getString("text"))
    }
}

/**
 * Re-encodes a cross-device command into the exact bytes
 * [CrossDeviceRuntime.sendCanonical] will accept.
 *
 * That entry point applies a strict byte-equality gate: the payload must
 * re-encode to itself, so an adapter cannot smuggle ignored fields or
 * alternate JSON spellings past the boundary. The gate is correct, but it
 * means a Kotlin builder would otherwise have to reproduce Swift's encoder
 * exactly. Keep the local builder for structure, then pass its output through
 * here and submit what comes back.
 */
object SharedCrossDeviceCommand {
    /** Throws [IllegalArgumentException] when the command is malformed, an
     * unsupported version, or carries a field its kind does not allow —
     * canonicalizing is not a way around validation. */
    fun canonicalize(command: ByteArray): ByteArray {
        require(command.isNotEmpty())
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.crossDeviceCanonicalizeCommand(
            command.toDirectBuffer(),
            command.size,
        )
    }

    /** Convenience for a builder that already produced a [JSONObject]. */
    fun canonicalize(command: JSONObject): ByteArray =
        canonicalize(command.toString().encodeToByteArray())

    /** Convenience for a builder that produced a JSON array payload. */
    fun canonicalize(command: JSONArray): ByteArray =
        canonicalize(command.toString().encodeToByteArray())
}
