package com.bambouville.tessera.forwarding

import com.bambouville.tessera.core.bridge.SharedForwardDirection
import com.bambouville.tessera.core.bridge.SharedForwardEndpoint
import com.bambouville.tessera.core.bridge.SharedForwardRule
import com.bambouville.tessera.core.bridge.SharedForwardRuleErrorKind
import com.bambouville.tessera.core.bridge.SharedForwardedWebTarget
import com.bambouville.tessera.core.bridge.SharedForwardingPolicy
import com.bambouville.tessera.core.bridge.SharedForwardingTransport
import com.bambouville.tessera.core.bridge.SharedForwardingUnavailableReason
import java.util.UUID

/**
 * `LOCAL` is SSH's `-L`, `REMOTE` is `-R`, and `DYNAMIC` is a local SOCKS5
 * listener whose CONNECT requests become SSH direct-tcpip channels.
 */
enum class PortForwardDirection {
    LOCAL,
    REMOTE,
    DYNAMIC,
}

data class PortForwardEndpoint(
    val host: String,
    val port: Int,
)

/**
 * A secret-free forwarding rule. It deliberately does not retain an SSH
 * client, socket, or credential reference, so it is safe to persist with a
 * host profile.
 *
 * The shape is the Room/UI layer for the shared model in
 * `Packages/TesseraCore/Sources/TesseraDomainCore/PortForwarding.swift`, which
 * was lifted from this file. Only the decisions cross the bridge; the storage
 * and editor types stay here.
 */
data class PortForwardRule(
    val id: UUID = UUID.randomUUID(),
    val enabled: Boolean = true,
    val autoStart: Boolean = true,
    val direction: PortForwardDirection = PortForwardDirection.LOCAL,
    val bind: PortForwardEndpoint,
    val target: PortForwardEndpoint? = null,
    val label: String = "",
)

sealed interface PortForwardRuleError {
    data class InvalidBindAddress(val value: String) : PortForwardRuleError
    data class InvalidBindPort(val value: Int) : PortForwardRuleError
    data class NonLoopbackLocalBind(val value: String) : PortForwardRuleError
    data object MissingTarget : PortForwardRuleError
    data class InvalidTargetAddress(val value: String) : PortForwardRuleError
    data class InvalidTargetPort(val value: Int) : PortForwardRuleError
    data object DynamicForwardCannotHaveTarget : PortForwardRuleError
    data class BindCollision(val conflictingRuleId: UUID) : PortForwardRuleError
}

/** The range a port number can occupy at all, on either platform. */
internal val PORT_RANGE = 0..65_535

/**
 * Validation shared by editor, import, and connected-session reconciliation.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraDomainCore/PortForwarding.swift`
 * (`PortForwardRuleValidator`), reached through `SharedForwardingPolicy`.
 * Local and dynamic listeners are loopback-only; only a remote bind may use
 * port 0, because the server allocates it and reports back; a bind collision
 * counts only enabled non-remote rules.
 */
object PortForwardRuleValidator {
    fun validate(rule: PortForwardRule, against: Iterable<PortForwardRule> = emptyList()): PortForwardRuleError? {
        // Ports are unsigned 16-bit in the shared model, so a value outside
        // that range is not a port it can be asked about — it is refused here
        // instead. Such a rule is invalid either way; the only difference is
        // that this rejection can preempt one the shared order would have
        // reported first.
        if (rule.bind.port !in PORT_RANGE) return PortForwardRuleError.InvalidBindPort(rule.bind.port)
        rule.target?.let { if (it.port !in PORT_RANGE) return PortForwardRuleError.InvalidTargetPort(it.port) }

        val error = SharedForwardingPolicy.validate(
            rule.sharedRule(),
            against.mapNotNull { it.sharedRuleOrNull() },
        ) ?: return null
        return when (error.kind) {
            SharedForwardRuleErrorKind.InvalidBindAddress ->
                PortForwardRuleError.InvalidBindAddress(error.host ?: rule.bind.host)
            SharedForwardRuleErrorKind.InvalidBindPort ->
                PortForwardRuleError.InvalidBindPort(error.port ?: rule.bind.port)
            SharedForwardRuleErrorKind.NonLoopbackLocalBind ->
                PortForwardRuleError.NonLoopbackLocalBind(error.host ?: rule.bind.host)
            SharedForwardRuleErrorKind.MissingTarget -> PortForwardRuleError.MissingTarget
            SharedForwardRuleErrorKind.InvalidTargetAddress ->
                PortForwardRuleError.InvalidTargetAddress(error.host ?: rule.target?.host.orEmpty())
            SharedForwardRuleErrorKind.InvalidTargetPort ->
                PortForwardRuleError.InvalidTargetPort(error.port ?: rule.target?.port ?: 0)
            SharedForwardRuleErrorKind.DynamicForwardCannotHaveTarget ->
                PortForwardRuleError.DynamicForwardCannotHaveTarget
            SharedForwardRuleErrorKind.BindCollision ->
                PortForwardRuleError.BindCollision(UUID.fromString(checkNotNull(error.conflictingRuleId)))
        }
    }
}

/** The forwarding carrier, not the terminal renderer or tmux presentation. */
sealed interface ForwardingTransport {
    data object Ssh : ForwardingTransport

    /** Mosh can forward only while its authenticated SSH side channel exists. */
    data class Mosh(val sshSideChannelAvailable: Boolean) : ForwardingTransport
}

/**
 * Why a transport cannot forward. A reason, not a sentence: the shared model
 * deliberately stopped carrying English here so each platform writes its own
 * copy at the point it is shown.
 */
enum class ForwardingUnavailableReason {
    MoshWithoutSshSideChannel,
}

data class ForwardingCapabilities(
    val local: Boolean,
    val remote: Boolean,
    val dynamic: Boolean,
    val unavailableReason: ForwardingUnavailableReason? = null,
) {
    fun supports(direction: PortForwardDirection): Boolean = when (direction) {
        PortForwardDirection.LOCAL -> local
        PortForwardDirection.REMOTE -> remote
        PortForwardDirection.DYNAMIC -> dynamic
    }

    companion object {
        /**
         * Swift authority: `PortForwarding.swift` (`ForwardingCapabilities.forTransport`),
         * reached through `SharedForwardingPolicy.capabilities`.
         */
        fun forTransport(transport: ForwardingTransport): ForwardingCapabilities {
            val shared = SharedForwardingPolicy.capabilities(
                when (transport) {
                    ForwardingTransport.Ssh -> SharedForwardingTransport.Ssh
                    is ForwardingTransport.Mosh ->
                        SharedForwardingTransport.Mosh(transport.sshSideChannelAvailable)
                },
            )
            return ForwardingCapabilities(
                local = shared.local,
                remote = shared.remote,
                dynamic = shared.dynamic,
                unavailableReason = when (shared.unavailableReason) {
                    null -> null
                    SharedForwardingUnavailableReason.MoshWithoutSshSideChannel ->
                        ForwardingUnavailableReason.MoshWithoutSshSideChannel
                },
            )
        }
    }
}

/**
 * Whether applying [other] in place of this rule requires tearing the listener
 * down instead of updating it; label, enabled, and autoStart changes never
 * disturb live traffic.
 *
 * Swift authority: `PortForwarding.swift` (`PortForwardRule.requiresRestart`).
 * A rule whose ports fall outside [PORT_RANGE] cannot be described to the
 * shared model at all — and could never have been started — so the
 * conservative answer is returned rather than claiming a live listener may
 * keep running.
 */
internal fun PortForwardRule.requiresRestart(other: PortForwardRule): Boolean {
    val from = sharedRuleOrNull() ?: return true
    val to = other.sharedRuleOrNull() ?: return true
    return SharedForwardingPolicy.requiresRestart(from, to)
}

/**
 * Whether this rule can be opened in the in-app browser, and at what URL.
 * Null means it cannot be.
 *
 * Swift authority: `PortForwarding.swift` (`ForwardedWebPolicy`), reached
 * through `SharedForwardingPolicy.webTarget`. Addressability only — a rule
 * whose ports fall outside [PORT_RANGE] cannot be described to the shared
 * model at all, and a listener's liveness is the caller's separate question,
 * asked of [PortForwardingState].
 */
fun PortForwardRule.browsableWebTarget(): SharedForwardedWebTarget? =
    sharedRuleOrNull()?.let(SharedForwardingPolicy::webTarget)

/**
 * Whether a forwarder is carrying, so there is something at the bind port to
 * open. Matches the rules `ForwardingChromePresentation` counts: a rule that
 * is starting, idle, or failed is configured but not listening.
 */
fun PortForwardingStatus.isCarrying(): Boolean =
    this is PortForwardingStatus.Listening || this is PortForwardingStatus.Active

private fun PortForwardEndpoint.sharedEndpoint(): SharedForwardEndpoint =
    SharedForwardEndpoint(host = host, port = port)

private fun PortForwardRule.sharedRule(): SharedForwardRule = SharedForwardRule(
    id = id.toString(),
    enabled = enabled,
    autoStart = autoStart,
    direction = when (direction) {
        PortForwardDirection.LOCAL -> SharedForwardDirection.Local
        PortForwardDirection.REMOTE -> SharedForwardDirection.Remote
        PortForwardDirection.DYNAMIC -> SharedForwardDirection.Dynamic
    },
    bind = bind.sharedEndpoint(),
    target = target?.sharedEndpoint(),
    label = label,
)

/** Null when a port puts the rule outside anything the shared model can hold. */
private fun PortForwardRule.sharedRuleOrNull(): SharedForwardRule? {
    if (bind.port !in PORT_RANGE) return null
    if (target != null && target.port !in PORT_RANGE) return null
    return sharedRule()
}
