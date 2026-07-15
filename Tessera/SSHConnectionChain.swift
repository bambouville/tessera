import Foundation
import Citadel
import NIOCore

/// Jump-host (ProxyJump) support: one shared implementation used by every
/// SSH connection the app opens — the interactive terminal, the mosh
/// bootstrap + tmux side channel, the Files panel bridge, port forwarding
/// (which rides the final client), and the key/shell installers.
///
/// Each hop authenticates independently (own Identity/StoredKey/password
/// via `resolveSSHConnection`) and is host-key-verified independently
/// (own `TesseraHostKeyValidator`, keyed by the hop's `address:port`
/// endpoint — TOFU per hop). Hop *i+1*'s SSH transport runs over a
/// direct-tcpip channel opened on hop *i* (`SSHClient.jump(to:)`).
struct EstablishedSSHChain {
    /// The destination client. Callers use it exactly as they used the
    /// direct `SSHClient` before jump support existed.
    let client: SSHClient
    /// Bastion clients, outermost first. Empty for direct connections.
    let upstream: [SSHClient]
    /// The resolved destination host from the final hop's policy snapshot
    /// (mirrors the `currentHost` existing call sites read).
    let resolvedHost: Host

    /// Close the whole chain, innermost first. Closing a bastion also
    /// collapses every channel tunneled through it, so this is belt and
    /// braces — but explicit teardown keeps droplet-side sshd sessions
    /// from lingering until TCP timeouts fire.
    func closeAll() async {
        try? await client.close()
        for bastion in upstream.reversed() {
            try? await bastion.close()
        }
    }
}

/// Attributes a connection failure to the bastion hop that produced it, so
/// "wrong key on the second bastion" doesn't surface as a generic failure
/// on the destination host.
struct SSHChainHopError: Error, LocalizedError {
    let hopIndex: Int
    let hopLabel: String
    let underlying: Error

    var errorDescription: String? {
        "Jump host \(hopLabel): \(describeSSHError(underlying))"
    }
}

enum SSHChainError: Error, LocalizedError {
    /// A jump link exists but could not be resolved (deleted bastion,
    /// cycle, depth overflow). Failing closed — never silently direct.
    case brokenChain(reason: String?)

    var errorDescription: String? {
        switch self {
        case .brokenChain(let reason):
            return reason ?? "The jump-host chain could not be resolved."
        }
    }
}

/// Known-hosts identity for a hop. The outermost hop keeps the historical
/// bare `address:port` key. Every tunneled hop is namespaced by the network
/// route used to reach it, because the same private address can legitimately
/// name different machines behind different bastions.
func sshHostKeyEndpoint(routeEndpoints: [String]) -> String {
    precondition(!routeEndpoints.isEmpty)
    return routeEndpoints.joined(separator: "→")
}

/// Establish the SSH client chain for `host`, dialing each configured
/// bastion in order and tunneling the next hop through it.
///
/// Behavior for a host with no jump chain is byte-identical to the previous
/// direct `SSHClient.connect` idiom (resolve → validate → connect →
/// revalidate), so every transport shares this single code path.
///
/// `hostKeyPrompt` fires per hop; `HostKeyVerificationChallenge.endpoint`
/// tells the sheet which hop is being verified. Biometric / Secure Enclave
/// fallback flags apply to the destination hop; bastion hops derive their
/// own flags from the live policy resolver (per-host StoredKey metadata).
func establishSSHChain(
    for host: Host,
    requireBiometric: Bool,
    isSecureEnclave: Bool,
    hostKeyPrompt: HostKeyVerificationPrompt?
) async throws -> EstablishedSSHChain {
    // Topology comes from the LIVE policy authority, not the caller's Host
    // snapshot: long-lived owners (mosh side-channel reconnect loop, Files
    // bridge reconnects, the remote-exit monitor, bootstrap retries) hold a
    // Host frozen at session start, and a jump chain the user added,
    // swapped, or removed since then must apply to every NEW leg — a chain
    // added mid-session silently dialing direct would fail open. For
    // unmanaged quick-connect hosts the policy resolver returns the
    // snapshot itself, so behavior there is unchanged (no chain).
    let livePolicy = try await resolveSSHConnectionPolicy(
        for: host,
        requireBiometric: requireBiometric,
        isSecureEnclave: isSecureEnclave
    )
    let liveHost = livePolicy.host
    if let reason = liveHost.jumpChainBrokenReason {
        throw SSHChainError.brokenChain(reason: reason)
    }

    let hops = liveHost.jumpChain + [liveHost]
    var upstream: [SSHClient] = []
    var resolvedRouteEndpoints: [String] = []

    func closeUpstream() async {
        for bastion in upstream.reversed() {
            try? await bastion.close()
        }
    }

    for (index, hop) in hops.enumerated() {
        let isFinal = index == hops.count - 1
        do {
            if !isFinal, await SSHAuthenticationPolicyStore.shared.hasCurrentPolicyProvider {
                // Bastion hops are persisted hosts by construction (the
                // editor's picker only offers saved hosts), but may have
                // been created after ContentView's launch-time fetch-all
                // registration — register so the live policy resolver (the
                // sole source of StoredKey metadata such as keyAlgorithm)
                // is consulted for the hop instead of the bare fallback.
                // Guarded on a live provider: DTO-only callers (tests)
                // must keep the fallback path.
                await SSHAuthenticationPolicyStore.shared.registerPersistedHost(hop.id)
            }
            let resolved = try await resolveSSHConnection(
                for: hop,
                requireBiometric: isFinal ? requireBiometric : false,
                isSecureEnclave: isFinal ? isSecureEnclave : false
            )
            try Task.checkCancellation()
            let current = resolved.policy.host
            let currentEndpoint = "\(current.address):\(current.port)"
            resolvedRouteEndpoints.append(currentEndpoint)
            let validator = TesseraHostKeyValidator(
                endpoint: sshHostKeyEndpoint(routeEndpoints: resolvedRouteEndpoints),
                prompt: hostKeyPrompt
            )
            if !hops.isEmpty, hops.count > 1 {
                DiagnosticLogStore.appendSSH(
                    "chain hop=\(index + 1)/\(hops.count) port=\(current.port) final=\(isFinal)"
                )
            }

            let client: SSHClient
            if let previous = upstream.last {
                let method = resolved.authenticationMethod
                client = try await previous.jump(to: SSHClientSettings(
                    host: current.address,
                    port: current.port,
                    authenticationMethod: { method },
                    hostKeyValidator: .custom(validator)
                ))
            } else {
                client = try await SSHClient.connect(
                    host: current.address,
                    port: current.port,
                    authenticationMethod: resolved.authenticationMethod,
                    hostKeyValidator: .custom(validator),
                    reconnect: .never
                )
            }

            do {
                try Task.checkCancellation()
                try await SSHAuthenticationPolicyStore.shared.revalidate(resolved.policy)
            } catch {
                try? await client.close()
                throw error
            }

            if isFinal {
                return EstablishedSSHChain(
                    client: client,
                    upstream: upstream,
                    resolvedHost: current
                )
            }
            upstream.append(client)
        } catch {
            await closeUpstream()
            if isFinal || error is SSHChainHopError || error is CancellationError {
                throw error
            }
            // A bastion failed: attribute it. The label mirrors the host
            // list's display naming without leaking credentials.
            let label = hop.name.isEmpty
                ? "\(hop.address):\(hop.port)"
                : hop.name
            throw SSHChainHopError(
                hopIndex: index,
                hopLabel: label,
                underlying: error
            )
        }
    }
    // hops always contains at least the destination host.
    fatalError("unreachable: empty SSH hop list")
}
