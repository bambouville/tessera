package com.bambouville.tessera.core.bridge

import org.json.JSONObject

/**
 * Remote-OS detection.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraDomainCore/RemoteOSDetection.swift`.
 * The ABI seam is `Sources/TesseraCoreABI/OSDetectionABI.swift`.
 *
 * The transport that runs the probe and the per-host persistence of what it
 * found stay here; the probe text and both classifiers are the core's.
 */

/**
 * A high-confidence match for Tailscale's documented WSL2 MTU failure shape.
 * The inner tunnel interface is expected to stay at 1280; the problem is the
 * smaller-than-1340 outer interface that has to carry the encrypted packet.
 */
data class SharedWslTailscaleMtuWarning(
    val defaultInterfaceMtu: Int,
    val tailscaleInterfaceMtu: Int,
)

/** What the probe could say about the network path. */
sealed interface SharedNetworkPathAssessment {
    /** The host rejected the probe or said too little. Keep any cached
     * warning. */
    data object Unavailable : SharedNetworkPathAssessment

    /** The probe completed and did not match the documented failure shape. A
     * cached warning may be cleared. */
    data object NotAtRisk : SharedNetworkPathAssessment

    data class Warning(val measurement: SharedWslTailscaleMtuWarning) :
        SharedNetworkPathAssessment
}

data class SharedOsDetectionResult(
    /** Null when nothing in the output identified a family, which is the
     * ordinary "no badge update" outcome. */
    val osHint: String?,
    val networkPath: SharedNetworkPathAssessment,
)

/** Typed facade over `Sources/TesseraCoreABI/OSDetectionABI.swift`. */
object SharedOSDetection {
    /**
     * The probe command, verbatim.
     *
     * Run it NON-interactively (an exec channel, i.e. `$SHELL -c`) so the
     * host's login/interactive dotfiles are not sourced: a very common "auto
     * tmux" setup runs `exec tmux` from those, and with no PTY on the channel
     * tmux exits before `uname` ever runs. The command's trailing `exit 0` is
     * equally load-bearing — a missing release file makes the last `cat` exit
     * non-zero, which a client turns into a command failure and discards the
     * accumulated stdout with.
     */
    fun probeCommand(): String {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.osDetectionProbeCommand()
    }

    /** Parses probe output into an OS hint and a network-path assessment. */
    fun parse(probeOutput: String): SharedOsDetectionResult {
        require(probeOutput.isNotEmpty())
        NativeLibraries.ensureLoaded()
        val bytes = probeOutput.encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.osDetectionParse(bytes.toDirectBuffer(), bytes.size),
        )
        val path = value.getJSONObject("networkPath")
        val assessment = when (val kind = path.getString("kind")) {
            "unavailable" -> SharedNetworkPathAssessment.Unavailable
            "notAtRisk" -> SharedNetworkPathAssessment.NotAtRisk
            "warning" -> path.getJSONObject("warning").let { warning ->
                SharedNetworkPathAssessment.Warning(
                    SharedWslTailscaleMtuWarning(
                        defaultInterfaceMtu = warning.getInt("defaultInterfaceMTU"),
                        tailscaleInterfaceMtu = warning.getInt("tailscaleInterfaceMTU"),
                    ),
                )
            }
            else -> throw IllegalArgumentException("unknown shared network path fact: $kind")
        }
        return SharedOsDetectionResult(
            osHint = if (value.isNull("osHint")) null else value.getString("osHint"),
            networkPath = assessment,
        )
    }

    /** The OS family alone, for a caller that only wants the badge. */
    fun parseFamily(probeOutput: String): String? {
        require(probeOutput.isNotEmpty())
        NativeLibraries.ensureLoaded()
        val bytes = probeOutput.encodeToByteArray()
        return NativeCoreBindings.osDetectionParseFamily(bytes.toDirectBuffer(), bytes.size)
    }
}
