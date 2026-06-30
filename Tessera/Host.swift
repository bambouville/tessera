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
    public var password: String
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
        portForwardRules: [PortForwardRule] = []
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.password = password
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
    }
}

extension Host {
    /// Bridge from a persisted host + identity pair into the DTO.
    init(from persisted: PersistedHost, transientPassword: String = "") {
        let identity = persisted.identity
        let rules = RuleCodec.decode(persisted.portForwardRulesData)
        var keyFilename: String?
        var resolvedPassword: String = transientPassword
        var keyID: UUID?

        switch identity?.credentialMode {
        case .legacyDevKey(let f):
            keyFilename = f
            resolvedPassword = ""
        case .password:
            resolvedPassword = identity.flatMap {
                KeychainHelper.password(forIdentityID: $0.id)
            } ?? transientPassword
        case .key(let id):
            keyID = id
        default:
            break
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
            portForwardRules: rules
        )
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

extension PersistedHost {
    func setPortForwardRules(_ rules: [PortForwardRule]) {
        portForwardRulesData = RuleCodec.encode(rules)
    }
}
