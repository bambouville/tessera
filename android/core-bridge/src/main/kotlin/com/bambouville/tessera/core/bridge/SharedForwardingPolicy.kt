package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject

/**
 * Port-forwarding policy.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraDomainCore/PortForwarding.swift`. The
 * ABI seam is `Sources/TesseraCoreABI/ForwardingABI.swift`.
 *
 * The shared model was lifted from this platform, so the Kotlin data classes
 * stay as the Room/UI layer and only the decisions cross the bridge. Two
 * deltas are deliberate: ports are unsigned 16-bit in the core, so the
 * out-of-range-port branch is unrepresentable rather than reachable, and the
 * unavailable reason is an enum rather than English prose because each
 * platform localizes its own copy.
 */

/** Which way a forward runs. */
enum class SharedForwardDirection(val wireValue: String) {
    Local("local"),
    Remote("remote"),
    Dynamic("dynamic");

    companion object {
        fun fromWire(value: String): SharedForwardDirection =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared forward direction")
    }
}

data class SharedForwardEndpoint(val host: String, val port: Int) {
    init {
        require(port in 0..65_535) { "a forwarding port must fit in 16 bits" }
    }
}

/**
 * A secret-free forwarding rule, matching Swift `PortForwardRule`.
 *
 * [id] is a canonical UUID string: the core decodes it as a UUID, and a rule
 * identity is what a bind-collision error names.
 */
data class SharedForwardRule(
    val id: String,
    val enabled: Boolean = true,
    val autoStart: Boolean = true,
    val direction: SharedForwardDirection = SharedForwardDirection.Local,
    val bind: SharedForwardEndpoint,
    val target: SharedForwardEndpoint? = null,
    val label: String = "",
)

/** The eight ways a rule can be rejected. */
enum class SharedForwardRuleErrorKind(val wireValue: String) {
    InvalidBindAddress("invalidBindAddress"),
    InvalidBindPort("invalidBindPort"),
    NonLoopbackLocalBind("nonLoopbackLocalBind"),
    MissingTarget("missingTarget"),
    InvalidTargetAddress("invalidTargetAddress"),
    InvalidTargetPort("invalidTargetPort"),
    DynamicForwardCannotHaveTarget("dynamicForwardCannotHaveTarget"),
    BindCollision("bindCollision");

    companion object {
        fun fromWire(value: String): SharedForwardRuleErrorKind =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared forwarding error")
    }
}

/** At most one payload field accompanies the kind. */
data class SharedForwardRuleError(
    val kind: SharedForwardRuleErrorKind,
    val host: String?,
    val port: Int?,
    val conflictingRuleId: String?,
)

/** The forwarding carrier, not the terminal renderer. */
sealed interface SharedForwardingTransport {
    data object Ssh : SharedForwardingTransport

    /** Mosh can forward only while its authenticated SSH side channel exists. */
    data class Mosh(val sshSideChannelAvailable: Boolean) : SharedForwardingTransport
}

/** Why a transport cannot forward. A reason, not a sentence. */
enum class SharedForwardingUnavailableReason(val wireValue: String) {
    MoshWithoutSshSideChannel("moshWithoutSSHSideChannel");

    companion object {
        fun fromWire(value: String): SharedForwardingUnavailableReason =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared forwarding unavailable reason")
    }
}

/**
 * A forwarded port this device can point a browser at. [url] is the whole
 * answer — already schemed, already bracketed for an IPv6 loopback — so
 * neither platform assembles one of its own and drifts.
 */
data class SharedForwardedWebTarget(
    val scheme: String,
    val host: String,
    val port: Int,
    val url: String,
) {
    val isSecure: Boolean get() = scheme == "https"
}

data class SharedForwardingCapabilities(
    val local: Boolean,
    val remote: Boolean,
    val dynamic: Boolean,
    val unavailableReason: SharedForwardingUnavailableReason?,
) {
    fun supports(direction: SharedForwardDirection): Boolean = when (direction) {
        SharedForwardDirection.Local -> local
        SharedForwardDirection.Remote -> remote
        SharedForwardDirection.Dynamic -> dynamic
    }
}

/** Typed facade over `Sources/TesseraCoreABI/ForwardingABI.swift`. */
object SharedForwardingPolicy {
    /**
     * Validates a rule against the set it will join. Null means valid.
     *
     * Local and dynamic listeners are loopback-only; only a remote bind may use
     * port 0 (the server allocates it and reports back); a dynamic rule must
     * have no target; and a bind collision is checked only among ENABLED,
     * non-remote rules — a disabled rule no longer reserves its port.
     */
    fun validate(
        rule: SharedForwardRule,
        existing: List<SharedForwardRule> = emptyList(),
    ): SharedForwardRuleError? {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("rule", rule.toJson())
            .put(
                "existing",
                JSONArray().also { array -> existing.forEach { array.put(it.toJson()) } },
            )
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.forwardingValidateRule(request.toDirectBuffer(), request.size),
        )
        if (value.getBoolean("valid")) return null
        val error = value.getJSONObject("error")
        return SharedForwardRuleError(
            kind = SharedForwardRuleErrorKind.fromWire(error.getString("kind")),
            host = if (error.isNull("host")) null else error.getString("host"),
            port = if (error.isNull("port")) null else error.getInt("port"),
            conflictingRuleId = if (error.isNull("conflictingRuleID")) {
                null
            } else {
                error.getString("conflictingRuleID")
            },
        )
    }

    /** What a transport can forward. */
    fun capabilities(transport: SharedForwardingTransport): SharedForwardingCapabilities {
        NativeLibraries.ensureLoaded()
        val encoded = when (transport) {
            SharedForwardingTransport.Ssh -> NativeCoreBindings.forwardingCapabilities(0, false)
            is SharedForwardingTransport.Mosh -> NativeCoreBindings.forwardingCapabilities(
                1,
                transport.sshSideChannelAvailable,
            )
        }
        val value = JSONObject(encoded)
        return SharedForwardingCapabilities(
            local = value.getBoolean("local"),
            remote = value.getBoolean("remote"),
            dynamic = value.getBoolean("dynamic"),
            unavailableReason = if (value.isNull("unavailableReason")) {
                null
            } else {
                SharedForwardingUnavailableReason.fromWire(value.getString("unavailableReason"))
            },
        )
    }

    /**
     * Whether applying [other] in place of [rule] requires tearing the
     * listener down instead of updating it. Label, enabled, and autoStart
     * changes never disturb live traffic.
     */
    fun requiresRestart(rule: SharedForwardRule, other: SharedForwardRule): Boolean {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("rule", rule.toJson())
            .put("other", other.toJson())
            .toString()
            .encodeToByteArray()
        return when (
            NativeCoreBindings.forwardingRequiresRestart(request.toDirectBuffer(), request.size)
        ) {
            0 -> false
            1 -> true
            else -> error("shared forwarding restart rule rejected well-formed rules")
        }
    }

    /**
     * The subset the cross-device bootstrap manifest can carry: loopback local
     * forwards that have a target. Dynamic rules have no target and remote
     * rules bind on the server, so neither survives the round trip; they are
     * dropped rather than silently flattened into a wrong local rule.
     */
    fun portableLocalSubset(rules: List<SharedForwardRule>): List<SharedForwardRule> {
        NativeLibraries.ensureLoaded()
        val request = JSONArray().also { array -> rules.forEach { array.put(it.toJson()) } }
            .toString()
            .encodeToByteArray()
        val subset = JSONArray(
            NativeCoreBindings.forwardingPortableLocalSubset(
                request.toDirectBuffer(),
                request.size,
            ),
        )
        return List(subset.length()) { index -> subset.getJSONObject(index).toForwardRule() }
    }

    /**
     * Whether [rule] can be opened in the in-app browser, and at what URL.
     * Null means it cannot be.
     *
     * Addressability only: a local loopback bind whose service port is not a
     * known non-web protocol. A remote bind listens on the server and a
     * dynamic rule is a SOCKS5 proxy, so neither is a URL. Whether the
     * listener is running right now is this caller's separate question —
     * `PortForwardingState` never crosses the bridge.
     */
    fun webTarget(rule: SharedForwardRule): SharedForwardedWebTarget? {
        NativeLibraries.ensureLoaded()
        val request = rule.toJson().toString().encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.forwardingWebTarget(request.toDirectBuffer(), request.size),
        )
        if (!value.getBoolean("browsable")) return null
        val target = value.getJSONObject("target")
        return SharedForwardedWebTarget(
            scheme = target.getString("scheme"),
            host = target.getString("host"),
            port = target.getInt("port"),
            url = target.getString("url"),
        )
    }
}

private fun SharedForwardEndpoint.toJson(): JSONObject =
    JSONObject().put("host", host).put("port", port)

private fun SharedForwardRule.toJson(): JSONObject = JSONObject()
    .put("id", id)
    .put("enabled", enabled)
    .put("autoStart", autoStart)
    .put("direction", direction.wireValue)
    .put("bind", bind.toJson())
    .put("target", target?.toJson() ?: JSONObject.NULL)
    .put("label", label)

private fun JSONObject.toForwardEndpoint(): SharedForwardEndpoint =
    SharedForwardEndpoint(host = getString("host"), port = getInt("port"))

private fun JSONObject.toForwardRule(): SharedForwardRule = SharedForwardRule(
    id = getString("id"),
    enabled = getBoolean("enabled"),
    autoStart = getBoolean("autoStart"),
    direction = SharedForwardDirection.fromWire(getString("direction")),
    bind = getJSONObject("bind").toForwardEndpoint(),
    target = optJSONObject("target")?.toForwardEndpoint(),
    label = optString("label"),
)
