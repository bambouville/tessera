import Darwin
import Foundation
import Citadel
import NIOCore
import NIOPosix
import NIOSSH

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

private struct RepeatedHostKeyApprovalError: Error, LocalizedError {
    let endpoint: String

    var errorDescription: String? {
        "Host-key approval for \(endpoint) did not persist. The connection was stopped."
    }
}

private struct HostKeyApprovalIdentity: Hashable {
    let endpoint: String
    let fingerprint: String
}

private struct AttributedHostKeyApproval: Error {
    let approval: HostKeyApprovalRequired
    let hopIndex: Int
    let hopLabel: String
    let isFinal: Bool
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
    var approvedChallenges: Set<HostKeyApprovalIdentity> = []

    // One fresh connection attempt follows each distinct approved hop. A
    // chain cannot legitimately need more approvals than it has hops.
    while approvedChallenges.count <= hops.count {
        var upstream: [SSHClient] = []
        var resolvedRouteEndpoints: [String] = []

        func closeUpstream() async {
            for bastion in upstream.reversed() {
                try? await bastion.close()
            }
        }

        do {
            for (index, hop) in hops.enumerated() {
                let isFinal = index == hops.count - 1
                let hopLabel = hop.name.isEmpty
                    ? "\(hop.address):\(hop.port)"
                    : hop.name
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
                        prompt: hostKeyPrompt,
                        peerFingerprint: liveHost.continuationHostKeyFingerprints[current.id],
                        peerLabel: liveHost.continuationPeerLabel
                    )
                    if hops.count > 1 {
                        DiagnosticLogStore.appendSSH(
                            "chain hop=\(index + 1)/\(hops.count) port=\(current.port) final=\(isFinal)"
                        )
                    }

                    let method = resolved.authenticationMethod
                    let settings = SSHClientSettings(
                        host: current.address,
                        port: current.port,
                        authenticationMethod: { method },
                        hostKeyValidator: .custom(validator)
                    )
                    let client: SSHClient
                    if let previous = upstream.last {
                        client = try await connectSSHJump(
                            from: previous,
                            settings: settings
                        )
                    } else {
                        client = try await connectSSHDirect(settings: settings)
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
                } catch let approval as HostKeyApprovalRequired {
                    await closeUpstream()
                    throw AttributedHostKeyApproval(
                        approval: approval,
                        hopIndex: index,
                        hopLabel: hopLabel,
                        isFinal: isFinal
                    )
                } catch {
                    await closeUpstream()
                    if isFinal || error is SSHChainHopError || error is CancellationError {
                        throw error
                    }
                    // A bastion failed: attribute it. The label mirrors the host
                    // list's display naming without leaking credentials.
                    throw SSHChainHopError(
                        hopIndex: index,
                        hopLabel: hopLabel,
                        underlying: error
                    )
                }
            }
        } catch let attributed as AttributedHostKeyApproval {
            let approval = attributed.approval
            let identity = HostKeyApprovalIdentity(
                endpoint: approval.endpoint,
                fingerprint: approval.challenge.fingerprint
            )
            guard approvedChallenges.insert(identity).inserted,
                  approvedChallenges.count <= hops.count else {
                let error = RepeatedHostKeyApprovalError(endpoint: approval.endpoint)
                if attributed.isFinal { throw error }
                throw SSHChainHopError(
                    hopIndex: attributed.hopIndex,
                    hopLabel: attributed.hopLabel,
                    underlying: error
                )
            }

            let accepted = await HostKeyVerificationCoordinator.shared.resolve(
                hostKey: approval.hostKey,
                endpoint: approval.endpoint,
                prompt: approval.prompt,
                challenge: approval.challenge
            )
            try Task.checkCancellation()
            guard accepted else {
                DiagnosticLogStore.appendSSH(
                    "hostkey validation userResult=rejected keyType=\(approval.challenge.keyType)"
                )
                let error = HostKeyRejectedError()
                if attributed.isFinal { throw error }
                throw SSHChainHopError(
                    hopIndex: attributed.hopIndex,
                    hopLabel: attributed.hopLabel,
                    underlying: error
                )
            }
            DiagnosticLogStore.appendSSH(
                "hostkey validation userResult=accepted keyType=\(approval.challenge.keyType) retry=fresh-chain"
            )
            continue
        }
    }

    fatalError("unreachable: SSH approval loop exhausted")
}

/// Own the TCP channel so a deliberately aborted host-key handshake can be
/// closed before Tessera waits on human approval. Citadel's convenience
/// connect API does not expose a failed channel to its caller.
private final class PendingSSHChannelOwner: @unchecked Sendable {
    private struct OwnedChannel {
        let channel: Channel
        let readGate: SSHInboundReadGate
    }

    private let lock = NSLock()
    private var channels: [ObjectIdentifier: OwnedChannel] = [:]
    private var cancelled = false

    /// Called from the bootstrap/channel initializer, which runs after channel
    /// registration but before TCP or direct-tcpip establishment completes.
    func adopt(_ channel: Channel, readGate: SSHInboundReadGate) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            channel.close(promise: nil)
            return false
        }
        channels[ObjectIdentifier(channel)] = OwnedChannel(
            channel: channel,
            readGate: readGate
        )
        lock.unlock()
        return true
    }

    func readGate(for channel: Channel) -> SSHInboundReadGate? {
        lock.lock()
        let gate = channels[ObjectIdentifier(channel)]?.readGate
        lock.unlock()
        return gate
    }

    func cancel() {
        let channelsToClose: [Channel]
        lock.lock()
        cancelled = true
        channelsToClose = channels.values.map(\.channel)
        channels.removeAll()
        lock.unlock()
        for channel in channelsToClose {
            channel.close(promise: nil)
        }
    }

    /// Happy Eyeballs may register multiple IPv4/IPv6 candidates. Retain the
    /// winner for its SSH client and close any candidates the connector has
    /// not already discarded.
    func relinquish(_ winner: Channel) {
        let winnerID = ObjectIdentifier(winner)
        let losingChannels: [Channel]
        lock.lock()
        losingChannels = channels.compactMap { id, owned in
            id == winnerID ? nil : owned.channel
        }
        channels.removeAll()
        lock.unlock()
        for channel in losingChannels {
            channel.close(promise: nil)
        }
    }
}

/// Bridges an EventLoopFuture without inheriting `future.get()`'s deliberate
/// cancellation blindness. The future may still complete later, but the
/// cancelled task resumes immediately and the channel owner rejects/closes any
/// candidate that appears after cancellation.
private final class CancellableFutureWaiter<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var bufferedResult: Result<Value, Error>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let resultToResume: Result<Value, Error>?
        lock.lock()
        if completed {
            resultToResume = bufferedResult
            bufferedResult = nil
        } else {
            self.continuation = continuation
            resultToResume = nil
        }
        lock.unlock()
        if let resultToResume {
            continuation.resume(with: resultToResume)
        }
    }

    func complete(_ result: Result<Value, Error>) {
        let continuationToResume: CheckedContinuation<Value, Error>?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        continuationToResume = continuation
        continuation = nil
        if continuationToResume == nil {
            bufferedResult = result
        }
        lock.unlock()
        continuationToResume?.resume(with: result)
    }
}

private func awaitCancellableFuture<Value>(
    _ future: EventLoopFuture<Value>,
    owner: PendingSSHChannelOwner
) async throws -> Value {
    let waiter = CancellableFutureWaiter<Value>()
    future.whenComplete { result in
        waiter.complete(result)
    }
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            waiter.install(continuation)
        }
    } onCancel: {
        owner.cancel()
        waiter.complete(.failure(CancellationError()))
    }
}

private func connectSSHDirect(settings: SSHClientSettings) async throws -> SSHClient {
    let owner = PendingSSHChannelOwner()
    let channelFuture = ClientBootstrap(group: settings.group)
        .channelInitializer { channel in
            // Happy Eyeballs can run this initializer for concurrent IPv4 and
            // IPv6 candidates. Each pipeline needs independent banner state.
            let readGate = SSHInboundReadGate()
            guard owner.adopt(channel, readGate: readGate) else {
                return channel.eventLoop.makeFailedFuture(CancellationError())
            }
            return channel.pipeline.addHandler(readGate, position: .first)
        }
        .connectTimeout(settings.connectTimeout)
        .channelOption(
            ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
            value: 1
        )
        .channelOption(
            ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY),
            value: 1
        )
        .connect(host: settings.host, port: settings.port)
    return try await withTaskCancellationHandler {
        do {
            try Task.checkCancellation()
            let channel = try await awaitCancellableFuture(
                channelFuture,
                owner: owner
            )
            guard let readGate = owner.readGate(for: channel) else {
                throw CancellationError()
            }
            let client = try await connectSSH(
                on: channel,
                through: readGate,
                settings: settings,
                owner: owner
            )
            owner.relinquish(channel)
            return client
        } catch {
            owner.cancel()
            throw error
        }
    } onCancel: {
        owner.cancel()
    }
}

/// Own the tunneled child channel for the same reason as the direct path.
private func connectSSHJump(
    from previous: SSHClient,
    settings: SSHClientSettings
) async throws -> SSHClient {
    let originatorAddress = try SocketAddress(ipAddress: "fe80::1", port: 22)
    let owner = PendingSSHChannelOwner()
    return try await withTaskCancellationHandler {
        do {
            try Task.checkCancellation()
            let channelFuture = previous.createDirectTCPIPChannelFuture(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: settings.host,
                    targetPort: settings.port,
                    originatorAddress: originatorAddress
                )
            ) { channel in
                let readGate = SSHInboundReadGate()
                guard owner.adopt(channel, readGate: readGate) else {
                    return channel.eventLoop.makeFailedFuture(CancellationError())
                }
                // Citadel's DataToBufferCodec is already present, so the gate
                // belongs after it and receives ByteBuffer values.
                return channel.pipeline.addHandler(readGate, position: .last)
            }
            let channel = try await awaitCancellableFuture(
                channelFuture,
                owner: owner
            )
            guard let readGate = owner.readGate(for: channel) else {
                throw CancellationError()
            }
            let client = try await connectSSH(
                on: channel,
                through: readGate,
                settings: settings,
                owner: owner
            )
            owner.relinquish(channel)
            return client
        } catch {
            owner.cancel()
            throw error
        }
    } onCancel: {
        owner.cancel()
    }
}

/// Citadel's `connect(on:)` installs its SSH pipeline on an already-active
/// channel. Hold any eager server banner bytes until that pipeline exists, then
/// replay them in order. This retains ownership of failed direct and tunneled
/// channels without the empty-pipeline data-loss window.
private final class SSHInboundReadGate: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var buffered: ByteBuffer?
    private var readCompletePending = false
    private var released = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if released {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        if buffered == nil {
            buffered = incoming
        } else {
            buffered?.writeBuffer(&incoming)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if released {
            context.fireChannelReadComplete()
        } else {
            readCompletePending = true
        }
    }

    func release(on channel: Channel) throws {
        channel.eventLoop.preconditionInEventLoop()
        let context = try channel.pipeline.syncOperations.context(handler: self)
        released = true
        if let buffered {
            self.buffered = nil
            context.fireChannelRead(wrapInboundOut(buffered))
        }
        if readCompletePending {
            readCompletePending = false
            context.fireChannelReadComplete()
        }
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}

/// Citadel's future-based adapter performs its synchronous pipeline mutation on
/// the channel's own loop. Tessera then releases any buffered banner bytes and
/// cancellation-bridges the authentication future while retaining the socket.
private func connectSSH(
    on channel: Channel,
    through readGate: SSHInboundReadGate,
    settings: SSHClientSettings,
    owner: PendingSSHChannelOwner
) async throws -> SSHClient {
    let authenticationFuture = channel.eventLoop.submit {
        do {
            let future = try SSHClient.startConnection(
                on: channel,
                settings: settings
            )
            try readGate.release(on: channel)
            return future
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }.flatMap { $0 }
    return try await awaitCancellableFuture(
        authenticationFuture,
        owner: owner
    )
}
