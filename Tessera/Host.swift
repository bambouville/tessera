import Foundation
import PortForwarding

/// A saved host target.
///
/// Lightweight DTO bridging `PersistedHost` + `Identity` to the
/// transport session setup. All secret resolution (Keychain password
/// lookup, key material loading) happens at construction time in
/// `init(from:transientPassword:)`.
public struct Host: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    public var port: Int
    public var user: String
    public var password: String {
        didSet {
            guard password != oldValue else { return }
            passwordCredentialRevision = password.isEmpty
                ? nil
                : .ephemeral(identityID: nil, token: UUID())
        }
    }
    /// Non-secret provenance used by the live SSH policy resolver. A random
    /// token distinguishes an explicitly entered, unsaved password from a
    /// password loaded from Keychain; the latter uses KeychainHelper's
    /// monotonic mutation revision. No password hash or verifier is retained.
    var passwordCredentialRevision: HostPasswordCredentialRevision?
    public var transport: HostTransport
    /// Filename (not path) of a private key under the app's Documents
    /// directory. Legacy dev-only path.
    public var privateKeyFilename: String?
    /// UUID of a `StoredKey` whose private material is in Keychain.
    /// `SSHSession.resolveAuthMethod` looks this up via `KeyStore`.
    public var storedKeyID: UUID?
    public var autoTmux: Bool
    /// Post-connect launch mode. Source of truth at SSH-connect time —
    /// `SessionView` branches on this to decide what (if anything) to
    /// send over stdin after the shell opens.
    public var launchMode: HostLaunchMode
    /// Consulted only when `launchMode == .pinnedTmux`.
    public var tmuxSessionName: String?
    /// Consulted only when `launchMode == .customCommand`.
    public var launchCommand: String?
    /// Newline-delimited `KEY=VALUE` pairs prepended to the launch
    /// command as `export KEY='VALUE'` lines.
    public var envVars: String
    /// Free-form shell snippet executed before the launch command.
    public var startupSnippet: String
    public var portForwardRules: [PortForwardRule]
    /// Bastion hops resolved from `HostJumpLink`, outermost first (the
    /// first entry is the hop the device dials directly). Hop entries carry
    /// empty chains of their own — the flattening happened at resolution.
    /// Empty for direct hosts and for quick-connect (unmanaged) hosts.
    public var jumpChain: [Host]
    /// Set when a jump link exists but could not be resolved (dangling
    /// bastion UUID, cycle, depth overflow). Connection code fails closed
    /// on this instead of silently connecting directly.
    public var jumpChainBrokenReason: String?

    public init(
        id: UUID = UUID(),
        name: String = "",
        address: String = "",
        port: Int = 22,
        user: String = "",
        password: String = "",
        transport: HostTransport = .ssh,
        privateKeyFilename: String? = nil,
        storedKeyID: UUID? = nil,
        autoTmux: Bool = true,
        launchMode: HostLaunchMode = .autoTmux,
        tmuxSessionName: String? = nil,
        launchCommand: String? = nil,
        envVars: String = "",
        startupSnippet: String = "",
        portForwardRules: [PortForwardRule] = [],
        jumpChain: [Host] = [],
        jumpChainBrokenReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.password = password
        self.passwordCredentialRevision = password.isEmpty
            ? nil
            : .ephemeral(identityID: nil, token: UUID())
        self.transport = transport
        self.privateKeyFilename = privateKeyFilename
        self.storedKeyID = storedKeyID
        self.autoTmux = autoTmux
        self.launchMode = launchMode
        self.tmuxSessionName = tmuxSessionName
        self.launchCommand = launchCommand
        self.envVars = envVars
        self.startupSnippet = startupSnippet
        self.portForwardRules = portForwardRules
        self.jumpChain = jumpChain
        self.jumpChainBrokenReason = jumpChainBrokenReason
    }
}

extension Host {
    /// Stable identity for the complete SSH route represented by this DTO.
    /// Host IDs distinguish separately managed records that happen to use the
    /// same private address; endpoint + user fields make edits invalidate a
    /// frozen snapshot even for unmanaged/quick-connect hosts.
    var sshConnectionRouteIdentity: String {
        let route = jumpChain + [self]
        let components = route.map {
            "\($0.id.uuidString)|\($0.user)@\($0.address):\($0.port)"
        }
        let broken = jumpChainBrokenReason.map { "|broken=\($0)" } ?? ""
        return components.joined(separator: "→") + broken
    }

    /// Bridge from a persisted host + identity pair into the DTO.
    ///
    /// `resolveJumpChain` is true for destination hosts (the default) and
    /// false when this init builds a bastion-hop DTO — the flattened chain
    /// was already computed by `HostJumpChainResolver`, so hops must not
    /// re-resolve their own tails (which would duplicate work and recurse
    /// on malformed cyclic data).
    init(
        from persisted: PersistedHost,
        transientPassword: String = "",
        transientPasswordCredentialRevision: HostPasswordCredentialRevision? = nil,
        transientJumpPasswords: [UUID: HostTransientPasswordCredential] = [:],
        keychain: KeychainClient = .live,
        resolveJumpChain: Bool = true
    ) {
        let identity = persisted.identity
        let rules = RuleCodec.decode(persisted.portForwardRulesData)
        var keyFilename: String?
        var resolvedPassword = ""
        var resolvedPasswordRevision: HostPasswordCredentialRevision?
        var keyID: UUID?
        let explicitTransientRevision = transientPasswordCredentialRevision
            ?? (transientPassword.isEmpty
                ? nil
                : .ephemeral(identityID: identity?.id, token: UUID()))

        switch identity?.credentialMode {
        case .legacyDevKey(let f):
            keyFilename = f
        case .password:
            if let identity {
                do {
                    let credential = try KeychainHelper.passwordCredential(
                        forIdentityID: identity.id,
                        keychain: keychain
                    )
                    if let current = credential.password {
                        resolvedPassword = current
                        if !current.isEmpty {
                            resolvedPasswordRevision = .keychain(
                                identityID: identity.id,
                                revision: credential.revision
                            )
                        }
                    } else if !transientPassword.isEmpty,
                              case .ephemeral(let sourceIdentityID, _) = explicitTransientRevision,
                              sourceIdentityID == identity.id {
                        // A missing Keychain item may use the password explicitly
                        // entered for this live session. Keychain read failures do
                        // not take this path and therefore fail closed.
                        resolvedPassword = transientPassword
                        resolvedPasswordRevision = explicitTransientRevision
                    }
                } catch {
                    // Protected-data, entitlement, and decode failures must not
                    // resurrect a password frozen in an older Host snapshot.
                    resolvedPassword = ""
                    resolvedPasswordRevision = nil
                }
            }
        case .key(let id):
            keyID = id
        default:
            // Identity removal is authoritative. In particular, never carry a
            // transient or formerly Keychain-backed password into `.none`.
            break
        }

        // Jump chain: resolved from the standalone HostJumpLink table via
        // the persisted object's own context. Hop DTOs resolve their own
        // Keychain credentials exactly like a destination host; their
        // chains stay empty (flattening happened in the resolver).
        var chain: [Host] = []
        var chainBrokenReason: String?
        if resolveJumpChain, let context = persisted.modelContext {
            let resolution = HostJumpChainResolver.resolve(for: persisted, in: context)
            if resolution.isBroken {
                chainBrokenReason = resolution.brokenReason
            } else {
                chain = resolution.hops.map {
                    let transient = transientJumpPasswords[$0.id]
                    return Host(
                        from: $0,
                        transientPassword: transient?.password ?? "",
                        transientPasswordCredentialRevision: transient?.revision,
                        keychain: keychain,
                        resolveJumpChain: false
                    )
                }
            }
        }

        self.init(
            id: persisted.id,
            name: persisted.name,
            address: persisted.address,
            port: persisted.port,
            user: persisted.effectiveUser,
            password: resolvedPassword,
            transport: persisted.transport,
            privateKeyFilename: keyFilename,
            storedKeyID: keyID,
            autoTmux: persisted.autoTmux,
            launchMode: persisted.launchMode,
            tmuxSessionName: persisted.tmuxSessionName,
            launchCommand: persisted.launchCommand,
            envVars: persisted.envVars,
            startupSnippet: persisted.startupSnippet,
            portForwardRules: rules,
            jumpChain: chain,
            jumpChainBrokenReason: chainBrokenReason
        )
        passwordCredentialRevision = resolvedPasswordRevision
    }

    /// A password-free Host snapshot suitable for retaining in the policy
    /// authority solely to re-evaluate SwiftData changes. An ephemeral
    /// placeholder preserves only credential kind/revision; it is never
    /// returned to an authentication caller.
    var policyRefreshFallback: Host {
        var fallback = self
        let revision = passwordCredentialRevision
        switch revision {
        case .ephemeral:
            fallback.password = "<ephemeral>"
            fallback.passwordCredentialRevision = revision
        case .keychain, .none:
            fallback.password = ""
            fallback.passwordCredentialRevision = revision
        }
        // Hop credentials must not be retained in the policy authority
        // either — scrub each bastion the same way.
        fallback.jumpChain = jumpChain.map(\.policyRefreshFallback)
        return fallback
    }

    /// Dev-only localhost example.
    public static var localhostExample: Host {
        Host(
            name: "Local Mac",
            address: "127.0.0.1",
            port: 22,
            user: "user",
            password: "",
            privateKeyFilename: "tessera-dev-key"
        )
    }
}

enum HostPasswordCredentialRevision: Hashable, Sendable {
    case ephemeral(identityID: UUID?, token: UUID)
    case keychain(identityID: UUID, revision: UInt64)
}

struct HostTransientPasswordCredential: Sendable {
    let password: String
    let revision: HostPasswordCredentialRevision?
}

extension PersistedHost {
    func setPortForwardRules(_ rules: [PortForwardRule]) {
        portForwardRulesData = RuleCodec.encode(rules)
    }
}
