import Foundation
import NIOSSH

/// The only host transport values accepted by nearby bootstrap.
///
/// This intentionally does not reuse `HostTransport`: keeping the wire model
/// independent prevents a future runtime-only transport property from becoming
/// syncable by accident.
public enum BootstrapHostTransport: String, Codable, CaseIterable, Sendable {
    case ssh
    case mosh
}

/// The non-secret launch modes which can be recreated on the receiving device.
public enum BootstrapHostLaunchMode: String, Codable, CaseIterable, Sendable {
    case autoTmux
    case pinnedTmux
    case customCommand
}

/// A hint used to explain which hosts can participate in key enrollment.
/// It carries no credential identifier, password, key bytes, or key handle.
public enum BootstrapAuthenticationHint: String, Codable, CaseIterable, Sendable {
    case none
    case password
    case publicKey
}

/// Sensitive or trust-bearing host setup that may cross only when the sending
/// user selects it in the nearby-bootstrap approval form. Every fresh attempt
/// starts with an empty selection.
enum BootstrapOptionalTransfer: String, CaseIterable, Hashable, Sendable, Identifiable {
    case launchCommands
    case notes
    case environmentVariables
    case startupSnippets
    case trustedHostKeys

    var id: String { rawValue }
}

/// Public identity grouping metadata. Credential mode and every Keychain/key
/// reference are absent; receiving code creates the group with no credential.
public struct BootstrapIdentityDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let user: String

    public init(id: UUID, name: String, user: String) {
        self.id = id
        self.name = name
        self.user = user
    }
}

/// A fully typed, device-independent port-forward rule.
public struct BootstrapPortForwardRule: Codable, Equatable, Sendable {
    public let id: UUID
    public let enabled: Bool
    public let autoStart: Bool
    public let localPort: UInt16
    public let remoteHost: String
    public let remotePort: UInt16
    public let label: String

    public init(
        id: UUID,
        enabled: Bool,
        autoStart: Bool,
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16,
        label: String
    ) {
        self.id = id
        self.enabled = enabled
        self.autoStart = autoStart
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.label = label
    }
}

/// Secret-free host configuration used only by nearby bootstrap.
///
/// Deliberately absent: passwords, private/stored-key identifiers, and
/// Keychain handles. The encrypted nearby-bootstrap flow performs a fresh
/// device-owner authorization before this descriptor is released. Free-text
/// fields and host-key trust material are additionally removed from the wire
/// unless the sender selects their category for the current attempt.
public struct BootstrapHostDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let address: String
    public let port: UInt16
    public let user: String
    public let transport: BootstrapHostTransport
    public let launchMode: BootstrapHostLaunchMode
    public let tmuxSessionName: String?
    public let tags: [String]
    public let osHint: String
    public let sortOrder: Int
    public let authenticationHint: BootstrapAuthenticationHint
    public let identityID: UUID?
    public let hostKeyFingerprint: String?
    public let launchCommand: String?
    public let notes: String?
    public let envVars: String?
    public let startupSnippet: String?
    public let portForwards: [BootstrapPortForwardRule]

    public init(
        id: UUID,
        name: String,
        address: String,
        port: UInt16 = 22,
        user: String,
        transport: BootstrapHostTransport,
        launchMode: BootstrapHostLaunchMode,
        tmuxSessionName: String? = nil,
        tags: [String] = [],
        osHint: String = "linux",
        sortOrder: Int = 0,
        authenticationHint: BootstrapAuthenticationHint = .none,
        identityID: UUID? = nil,
        hostKeyFingerprint: String? = nil,
        launchCommand: String? = nil,
        notes: String? = nil,
        envVars: String? = nil,
        startupSnippet: String? = nil,
        portForwards: [BootstrapPortForwardRule] = []
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.transport = transport
        self.launchMode = launchMode
        self.tmuxSessionName = tmuxSessionName
        self.tags = tags
        self.osHint = osHint
        self.sortOrder = sortOrder
        self.authenticationHint = authenticationHint
        self.identityID = identityID
        self.hostKeyFingerprint = hostKeyFingerprint
        self.launchCommand = launchCommand
        self.notes = notes
        self.envVars = envVars
        self.startupSnippet = startupSnippet
        self.portForwards = portForwards
    }
}

/// Exact public host-key trust material released only inside the encrypted,
/// owner-authorized nearby-bootstrap manifest. The endpoint is derived from
/// `hostID` and the manifest jump graph so a peer cannot redirect a valid key
/// to unrelated local endpoint text.
public struct BootstrapKnownHostDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let hostID: UUID
    public let fingerprint: String
    public let keyString: String
    public let firstSeen: Date
    public let lastSeen: Date

    public var id: UUID { hostID }

    public init(
        hostID: UUID,
        fingerprint: String,
        keyString: String,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.hostID = hostID
        self.fingerprint = fingerprint
        self.keyString = keyString
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// A jump relationship expressed only in terms of manifest host identifiers.
/// A complete chain is reconstructed by following these links.
public struct BootstrapJumpLink: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let jumpHostID: UUID

    public init(hostID: UUID, jumpHostID: UUID) {
        self.hostID = hostID
        self.jumpHostID = jumpHostID
    }
}

/// Device-neutral appearance choices. Image filenames and chrome geometry are
/// intentionally absent: neither has a meaningful cross-device interpretation.
public struct BootstrapAppearanceSettings: Codable, Equatable, Sendable {
    public let colorScheme: String
    public let accent: String
    public let customAccentRGB: Int
    public let monospacedFontName: String
    public let terminalFontSize: Double
    public let chromeMaterial: String
    public let cursorStyle: String
    public let cursorBlink: Bool
    public let terminalThemeID: String

    public init(
        colorScheme: String,
        accent: String,
        customAccentRGB: Int,
        monospacedFontName: String,
        terminalFontSize: Double,
        chromeMaterial: String,
        cursorStyle: String,
        cursorBlink: Bool,
        terminalThemeID: String
    ) {
        self.colorScheme = colorScheme
        self.accent = accent
        self.customAccentRGB = customAccentRGB
        self.monospacedFontName = monospacedFontName
        self.terminalFontSize = terminalFontSize
        self.chromeMaterial = chromeMaterial
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.terminalThemeID = terminalThemeID
    }
}

/// Device-neutral behavioral preferences. Security policy, restore state,
/// notification permission, files state, onboarding state, and idiom-specific
/// control placement are local decisions and therefore absent.
public struct BootstrapGeneralSettings: Codable, Equatable, Sendable {
    public let scrollbackLines: Int
    public let modifierBehavior: String
    public let bellSoundEnabled: Bool
    public let bellVisualEnabled: Bool
    public let bellNotificationEnabled: Bool
    public let accessoryBarKeys: [String]
    public let filesReaperDays: Int
    public let filesDefaultDestination: String

    public init(
        scrollbackLines: Int,
        modifierBehavior: String,
        bellSoundEnabled: Bool,
        bellVisualEnabled: Bool,
        bellNotificationEnabled: Bool,
        accessoryBarKeys: [String],
        filesReaperDays: Int,
        filesDefaultDestination: String
    ) {
        self.scrollbackLines = scrollbackLines
        self.modifierBehavior = modifierBehavior
        self.bellSoundEnabled = bellSoundEnabled
        self.bellVisualEnabled = bellVisualEnabled
        self.bellNotificationEnabled = bellNotificationEnabled
        self.accessoryBarKeys = accessoryBarKeys
        self.filesReaperDays = filesReaperDays
        self.filesDefaultDestination = filesDefaultDestination
    }
}

public enum BootstrapManifestError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case encodedSizeExceeded(actual: Int, maximum: Int)
    case tooManyHosts(Int)
    case tooManyIdentities(Int)
    case tooManyJumpChains(Int)
    case tooManyKnownHosts(Int)
    case duplicateIdentityID(UUID)
    case invalidIdentity(UUID, field: String)
    case duplicateHostID(UUID)
    case invalidHost(UUID, field: String)
    case duplicateJumpLink(UUID)
    case danglingJumpLink(UUID)
    case cyclicJumpChain(UUID)
    case jumpChainTooDeep(UUID)
    case duplicateKnownHost(UUID)
    case invalidKnownHost(UUID, field: String)
    case invalidAppearance(field: String)
    case invalidSettings(field: String)
    case unselectedOptionalField(String)
    case malformedJSON
    case unknownField(path: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported bootstrap manifest version \(version)."
        case .encodedSizeExceeded(let actual, let maximum):
            return "Bootstrap manifest is \(actual) bytes; maximum is \(maximum)."
        case .tooManyHosts(let count):
            return "Bootstrap manifest contains too many hosts (\(count))."
        case .tooManyIdentities(let count):
            return "Bootstrap manifest contains too many identities (\(count))."
        case .tooManyJumpChains(let count):
            return "Bootstrap manifest contains too many jump-chain links (\(count))."
        case .tooManyKnownHosts(let count):
            return "Bootstrap manifest contains too many known-host records (\(count))."
        case .duplicateIdentityID(let id):
            return "Bootstrap manifest repeats identity \(id)."
        case .invalidIdentity(let id, let field):
            return "Bootstrap identity \(id) has an invalid \(field)."
        case .duplicateHostID(let id):
            return "Bootstrap manifest repeats host \(id)."
        case .invalidHost(let id, let field):
            return "Bootstrap host \(id) has an invalid \(field)."
        case .duplicateJumpLink(let id):
            return "Bootstrap manifest repeats the jump link for \(id)."
        case .danglingJumpLink(let id):
            return "Bootstrap jump link references missing host \(id)."
        case .cyclicJumpChain(let id):
            return "Bootstrap jump chain contains a cycle at \(id)."
        case .jumpChainTooDeep(let id):
            return "Bootstrap jump chain for \(id) is too deep."
        case .duplicateKnownHost(let id):
            return "Bootstrap manifest repeats the known-host record for \(id)."
        case .invalidKnownHost(let id, let field):
            return "Bootstrap known-host record \(id) has an invalid \(field)."
        case .invalidAppearance(let field):
            return "Bootstrap appearance field \(field) is invalid."
        case .invalidSettings(let field):
            return "Bootstrap setting \(field) is invalid."
        case .unselectedOptionalField(let field):
            return "Bootstrap optional field \(field) was not approved for transfer."
        case .malformedJSON:
            return "Bootstrap manifest is not a JSON object."
        case .unknownField(let path, let field):
            return "Bootstrap manifest contains unknown field \(path).\(field)."
        }
    }
}

/// Versioned, explicit allowlist for first-open nearby bootstrap.
public struct BootstrapManifest: Codable, Equatable, Sendable {
    public static let currentVersion = NearbyBootstrapProtocol.version
    public static let maximumEncodedByteCount = 1_048_576
    public static let maximumHostCount = 1_000
    public static let maximumIdentityCount = 1_000
    public static let maximumJumpChainCount = 1_000
    public static let maximumKnownHostCount = 1_000

    public let version: Int
    public let identities: [BootstrapIdentityDescriptor]
    public let hosts: [BootstrapHostDescriptor]
    public let jumpChains: [BootstrapJumpLink]
    /// Optional on the wire so an older v1 payload decodes far enough to
    /// report its unsupported version instead of failing on a missing field.
    public let knownHosts: [BootstrapKnownHostDescriptor]?
    public let appearance: BootstrapAppearanceSettings
    public let settings: BootstrapGeneralSettings

    public init(
        version: Int = BootstrapManifest.currentVersion,
        identities: [BootstrapIdentityDescriptor] = [],
        hosts: [BootstrapHostDescriptor],
        jumpChains: [BootstrapJumpLink],
        knownHosts: [BootstrapKnownHostDescriptor] = [],
        appearance: BootstrapAppearanceSettings,
        settings: BootstrapGeneralSettings
    ) {
        self.version = version
        self.identities = identities
        self.hosts = hosts
        self.jumpChains = jumpChains
        self.knownHosts = knownHosts
        self.appearance = appearance
        self.settings = settings
    }

    /// Produces the canonical transport representation after all structural
    /// and resource-limit checks have passed.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedByteCount else {
            throw BootstrapManifestError.encodedSizeExceeded(
                actual: data.count,
                maximum: Self.maximumEncodedByteCount
            )
        }
        return data
    }

    /// Strictly decodes an allowlisted manifest. Unknown keys are rejected
    /// instead of silently ignored by `Codable`, so a newer sender cannot move
    /// unreviewed data through an older receiver.
    public static func decode(_ data: Data) throws -> BootstrapManifest {
        guard data.count <= maximumEncodedByteCount else {
            throw BootstrapManifestError.encodedSizeExceeded(
                actual: data.count,
                maximum: maximumEncodedByteCount
            )
        }
        // Version before schema: a future manifest must report its version
        // cleanly instead of failing the unknown-field allowlist on whatever
        // field it added. A payload claiming the current version still faces
        // the full strict allowlist below.
        if let info = NearbyVersionProbe.probe(data), info.version != currentVersion {
            throw BootstrapManifestError.unsupportedVersion(info.version)
        }
        try BootstrapManifestSchema.rejectUnknownFields(in: data)
        let manifest = try JSONDecoder().decode(BootstrapManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw BootstrapManifestError.unsupportedVersion(version)
        }
        guard hosts.count <= Self.maximumHostCount else {
            throw BootstrapManifestError.tooManyHosts(hosts.count)
        }
        guard identities.count <= Self.maximumIdentityCount else {
            throw BootstrapManifestError.tooManyIdentities(identities.count)
        }
        guard jumpChains.count <= Self.maximumJumpChainCount else {
            throw BootstrapManifestError.tooManyJumpChains(jumpChains.count)
        }
        let knownHostRecords = knownHosts ?? []
        guard knownHostRecords.count <= Self.maximumKnownHostCount else {
            throw BootstrapManifestError.tooManyKnownHosts(knownHostRecords.count)
        }

        var identityIDs = Set<UUID>()
        for identity in identities {
            guard identityIDs.insert(identity.id).inserted else {
                throw BootstrapManifestError.duplicateIdentityID(identity.id)
            }
            try Self.validateIdentityDescriptor(identity)
        }

        var hostIDs = Set<UUID>()
        for host in hosts {
            guard hostIDs.insert(host.id).inserted else {
                throw BootstrapManifestError.duplicateHostID(host.id)
            }
            try Self.validateHostDescriptor(host)
            if let identityID = host.identityID, !identityIDs.contains(identityID) {
                throw BootstrapManifestError.invalidHost(host.id, field: "identityID")
            }
        }

        var linkedHosts = Set<UUID>()
        for link in jumpChains {
            guard linkedHosts.insert(link.hostID).inserted else {
                throw BootstrapManifestError.duplicateJumpLink(link.hostID)
            }
            guard hostIDs.contains(link.hostID) else {
                throw BootstrapManifestError.danglingJumpLink(link.hostID)
            }
            guard hostIDs.contains(link.jumpHostID) else {
                throw BootstrapManifestError.danglingJumpLink(link.jumpHostID)
            }
            guard link.hostID != link.jumpHostID else {
                throw BootstrapManifestError.cyclicJumpChain(link.hostID)
            }
        }
        try Self.validateJumpGraph(jumpChains)
        var knownHostIDs = Set<UUID>()
        for knownHost in knownHostRecords {
            guard knownHostIDs.insert(knownHost.hostID).inserted else {
                throw BootstrapManifestError.duplicateKnownHost(knownHost.hostID)
            }
            guard hostIDs.contains(knownHost.hostID) else {
                throw BootstrapManifestError.invalidKnownHost(
                    knownHost.hostID,
                    field: "hostID"
                )
            }
            try Self.validateKnownHostDescriptor(knownHost)
        }
        try Self.validate(appearance)
        try Self.validate(settings)
    }

    static func validateIdentityDescriptor(
        _ identity: BootstrapIdentityDescriptor
    ) throws {
        guard !identity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identity.name.utf8.count <= 256 else {
            throw BootstrapManifestError.invalidIdentity(identity.id, field: "name")
        }
        guard identity.user.utf8.count <= 256 else {
            throw BootstrapManifestError.invalidIdentity(identity.id, field: "user")
        }
    }

    static func validateHostDescriptor(_ host: BootstrapHostDescriptor) throws {
        guard !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              host.name.utf8.count <= 256 else {
            throw BootstrapManifestError.invalidHost(host.id, field: "name")
        }
        guard !host.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              host.address.utf8.count <= 1_024 else {
            throw BootstrapManifestError.invalidHost(host.id, field: "address")
        }
        guard (1...65_535).contains(host.port) else {
            throw BootstrapManifestError.invalidHost(host.id, field: "port")
        }
        guard host.user.utf8.count <= 256 else {
            throw BootstrapManifestError.invalidHost(host.id, field: "user")
        }
        guard host.tags.count <= 128,
              host.tags.allSatisfy({ $0.utf8.count <= 128 }) else {
            throw BootstrapManifestError.invalidHost(host.id, field: "tags")
        }
        guard host.osHint.utf8.count <= 64 else {
            throw BootstrapManifestError.invalidHost(host.id, field: "osHint")
        }
        if let session = host.tmuxSessionName, session.utf8.count > 256 {
            throw BootstrapManifestError.invalidHost(host.id, field: "tmuxSessionName")
        }
        if host.launchMode == .pinnedTmux,
           host.tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw BootstrapManifestError.invalidHost(host.id, field: "tmuxSessionName")
        }
        // Only pinned-tmux mode may carry a tmux session name. Custom launch
        // commands are transferred separately in `launchCommand`.
        if host.launchMode == .customCommand, host.tmuxSessionName != nil {
            throw BootstrapManifestError.invalidHost(host.id, field: "tmuxSessionName")
        }
        if let fingerprint = host.hostKeyFingerprint {
            guard !fingerprint.isEmpty,
                  fingerprint.utf8.count <= 256,
                  fingerprint.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }) else {
                throw BootstrapManifestError.invalidHost(host.id, field: "hostKeyFingerprint")
            }
        }
        for (field, value) in [
            ("launchCommand", host.launchCommand),
            ("notes", host.notes),
            ("envVars", host.envVars),
            ("startupSnippet", host.startupSnippet)
        ] {
            if let value, value.utf8.count > 65_536 {
                throw BootstrapManifestError.invalidHost(host.id, field: field)
            }
        }
        guard host.portForwards.count <= 256 else {
            throw BootstrapManifestError.invalidHost(host.id, field: "portForwards")
        }
        for forward in host.portForwards {
            guard forward.localPort > 0,
                  forward.remotePort > 0,
                  !forward.remoteHost.isEmpty,
                  forward.remoteHost.utf8.count <= 1_024,
                  forward.label.utf8.count <= 256 else {
                throw BootstrapManifestError.invalidHost(host.id, field: "portForwards")
            }
        }
    }

    private static func validateKnownHostDescriptor(
        _ knownHost: BootstrapKnownHostDescriptor
    ) throws {
        guard knownHost.keyString.utf8.count <= 16_384,
              let key = try? NIOSSHPublicKey(openSSHPublicKey: knownHost.keyString)
        else {
            throw BootstrapManifestError.invalidKnownHost(
                knownHost.hostID,
                field: "keyString"
            )
        }
        guard knownHost.fingerprint.utf8.count <= 256,
              KnownHostsStore.fingerprint(of: key) == knownHost.fingerprint else {
            throw BootstrapManifestError.invalidKnownHost(
                knownHost.hostID,
                field: "fingerprint"
            )
        }
        guard knownHost.firstSeen <= knownHost.lastSeen else {
            throw BootstrapManifestError.invalidKnownHost(
                knownHost.hostID,
                field: "dates"
            )
        }
    }

    private static func validateJumpGraph(_ links: [BootstrapJumpLink]) throws {
        let next = Dictionary(uniqueKeysWithValues: links.map { ($0.hostID, $0.jumpHostID) })
        for start in next.keys {
            var seen = Set<UUID>()
            var current: UUID? = start
            var depth = 0
            while let id = current, let jump = next[id] {
                guard seen.insert(id).inserted else {
                    throw BootstrapManifestError.cyclicJumpChain(id)
                }
                depth += 1
                guard depth <= 8 else {
                    throw BootstrapManifestError.jumpChainTooDeep(start)
                }
                current = jump
            }
        }
    }

    private static func validate(_ appearance: BootstrapAppearanceSettings) throws {
        guard ["system", "dark", "light"].contains(appearance.colorScheme) else {
            throw BootstrapManifestError.invalidAppearance(field: "colorScheme")
        }
        guard !appearance.accent.isEmpty, appearance.accent.utf8.count <= 64 else {
            throw BootstrapManifestError.invalidAppearance(field: "accent")
        }
        guard (0...0xFF_FF_FF).contains(appearance.customAccentRGB) else {
            throw BootstrapManifestError.invalidAppearance(field: "customAccentRGB")
        }
        guard !appearance.monospacedFontName.isEmpty,
              appearance.monospacedFontName.utf8.count <= 256 else {
            throw BootstrapManifestError.invalidAppearance(field: "monospacedFontName")
        }
        guard (6...72).contains(appearance.terminalFontSize) else {
            throw BootstrapManifestError.invalidAppearance(field: "terminalFontSize")
        }
        guard !appearance.chromeMaterial.isEmpty,
              appearance.chromeMaterial.utf8.count <= 64 else {
            throw BootstrapManifestError.invalidAppearance(field: "chromeMaterial")
        }
        guard ["block", "bar", "underline"].contains(appearance.cursorStyle) else {
            throw BootstrapManifestError.invalidAppearance(field: "cursorStyle")
        }
        guard !appearance.terminalThemeID.isEmpty,
              appearance.terminalThemeID.utf8.count <= 128 else {
            throw BootstrapManifestError.invalidAppearance(field: "terminalThemeID")
        }
    }

    private static func validate(_ settings: BootstrapGeneralSettings) throws {
        guard (1_000...50_000).contains(settings.scrollbackLines) else {
            throw BootstrapManifestError.invalidSettings(field: "scrollbackLines")
        }
        guard ["oneShot", "sticky"].contains(settings.modifierBehavior) else {
            throw BootstrapManifestError.invalidSettings(field: "modifierBehavior")
        }
        guard settings.accessoryBarKeys.count <= 64,
              settings.accessoryBarKeys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else {
            throw BootstrapManifestError.invalidSettings(field: "accessoryBarKeys")
        }
        guard (0...365).contains(settings.filesReaperDays) else {
            throw BootstrapManifestError.invalidSettings(field: "filesReaperDays")
        }
        guard ["cwd", "temp"].contains(settings.filesDefaultDestination) else {
            throw BootstrapManifestError.invalidSettings(field: "filesDefaultDestination")
        }
    }
}

extension BootstrapManifest {
    /// Produce the only manifest eligible for sealing onto the nearby wire.
    /// Optional free-text and host-trust material fail closed unless the sender
    /// selected their individual category for this attempt.
    func selectingOptionalTransfers(
        _ selected: Set<BootstrapOptionalTransfer>
    ) throws -> BootstrapManifest {
        let filteredHosts = hosts.map { host in
            BootstrapHostDescriptor(
                id: host.id,
                name: host.name,
                address: host.address,
                port: host.port,
                user: host.user,
                transport: host.transport,
                launchMode: host.launchMode,
                tmuxSessionName: host.tmuxSessionName,
                tags: host.tags,
                osHint: host.osHint,
                sortOrder: host.sortOrder,
                authenticationHint: host.authenticationHint,
                identityID: host.identityID,
                hostKeyFingerprint: selected.contains(.trustedHostKeys)
                    ? host.hostKeyFingerprint : nil,
                launchCommand: selected.contains(.launchCommands)
                    ? host.launchCommand : nil,
                notes: selected.contains(.notes) ? host.notes : nil,
                envVars: selected.contains(.environmentVariables)
                    ? host.envVars : nil,
                startupSnippet: selected.contains(.startupSnippets)
                    ? host.startupSnippet : nil,
                portForwards: host.portForwards
            )
        }
        let filtered = BootstrapManifest(
            version: version,
            identities: identities,
            hosts: filteredHosts,
            jumpChains: jumpChains,
            knownHosts: selected.contains(.trustedHostKeys)
                ? (knownHosts ?? []) : [],
            appearance: appearance,
            settings: settings
        )
        try filtered.validate()
        try filtered.validateOptionalTransferSelection(selected)
        return filtered
    }

    /// Last-mile invariant at the trust boundary. Call this again immediately
    /// before sealing so a future refactor cannot accidentally substitute the
    /// unfiltered export after the approval UI has frozen its selection.
    func validateOptionalTransferSelection(
        _ selected: Set<BootstrapOptionalTransfer>
    ) throws {
        if !selected.contains(.trustedHostKeys) {
            guard (knownHosts ?? []).isEmpty else {
                throw BootstrapManifestError.unselectedOptionalField("knownHosts")
            }
            guard hosts.allSatisfy({ $0.hostKeyFingerprint == nil }) else {
                throw BootstrapManifestError.unselectedOptionalField("hostKeyFingerprint")
            }
        }
        if !selected.contains(.launchCommands),
           !hosts.allSatisfy({ $0.launchCommand == nil }) {
            throw BootstrapManifestError.unselectedOptionalField("launchCommand")
        }
        if !selected.contains(.notes),
           !hosts.allSatisfy({ $0.notes == nil }) {
            throw BootstrapManifestError.unselectedOptionalField("notes")
        }
        if !selected.contains(.environmentVariables),
           !hosts.allSatisfy({ $0.envVars == nil }) {
            throw BootstrapManifestError.unselectedOptionalField("envVars")
        }
        if !selected.contains(.startupSnippets),
           !hosts.allSatisfy({ $0.startupSnippet == nil }) {
            throw BootstrapManifestError.unselectedOptionalField("startupSnippet")
        }
    }
}

/// Immutable wire payload produced from the exact optional-data choices shown
/// on the origin approval screen. The encrypted transport accepts this type,
/// rather than a raw export, so unfiltered trust material cannot be substituted
/// at the final sealing call.
struct ApprovedBootstrapManifest: Equatable, Sendable {
    let manifest: BootstrapManifest
    let selectedOptionalTransfers: Set<BootstrapOptionalTransfer>

    init(
        exportedManifest: BootstrapManifest,
        selectedOptionalTransfers: Set<BootstrapOptionalTransfer>
    ) throws {
        self.selectedOptionalTransfers = selectedOptionalTransfers
        manifest = try exportedManifest.selectingOptionalTransfers(
            selectedOptionalTransfers
        )
    }

    func validate() throws {
        try manifest.validateOptionalTransferSelection(selectedOptionalTransfers)
    }
}

/// Checked-in classification for fields on the source models. Tests compare
/// this table with reflection so adding a model property without a deliberate
/// sync decision fails CI.
public enum BootstrapFieldDisposition: String, Hashable, Sendable {
    case syncable
    case explicitNearbyOptIn
    case neverSyncs
}

public enum BootstrapSyncClassification {
    public static let persistedHost: [String: BootstrapFieldDisposition] = [
        "id": .syncable,
        "name": .syncable,
        "address": .syncable,
        "port": .syncable,
        "autoTmux": .neverSyncs, // derived from launchMode
        "transportRaw": .syncable,
        "launchModeRaw": .syncable,
        "tmuxSessionName": .syncable,
        "launchCommand": .explicitNearbyOptIn, // arbitrary shell text can hold secrets
        "tags": .syncable,
        "osHint": .syncable,
        "notes": .explicitNearbyOptIn, // arbitrary user text can hold secrets
        "envVars": .explicitNearbyOptIn, // commonly contains tokens
        "startupSnippet": .explicitNearbyOptIn, // arbitrary shell text can hold secrets
        "portForwardRulesData": .syncable, // decoded into the typed allowlist
        "user": .syncable,
        "sortOrder": .syncable,
        "identity": .syncable // represented by credential-free identityID
    ]

    public static let identity: [String: BootstrapFieldDisposition] = [
        "id": .syncable,
        "name": .syncable,
        "user": .syncable, // copied into each host's public login field
        "credentialMode": .neverSyncs,
        "hosts": .syncable
    ]

    public static let hostJumpLink: [String: BootstrapFieldDisposition] = [
        "hostID": .syncable,
        "jumpHostID": .syncable
    ]

    public static let appearancePreferences: [String: BootstrapFieldDisposition] = [
        "mode": .syncable,
        "accent": .syncable,
        "customAccentRGB": .syncable,
        "monoFontName": .syncable,
        "fontSize": .syncable,
        "topBarHeight": .neverSyncs,
        "handoffSessionsEnabled": .neverSyncs,
        "chromeMaterial": .syncable,
        "cursorStyle": .syncable,
        "cursorBlink": .syncable,
        "scrollbackLines": .syncable,
        "smoothScrollingEnabled": .neverSyncs,
        "smoothScrollingSpeed": .neverSyncs,
        "sessionRestorePolicy": .neverSyncs,
        "terminalThemeID": .syncable,
        "terminalBackgroundUsesImage": .neverSyncs,
        "terminalBackgroundImageID": .neverSyncs,
        "terminalBackgroundDim": .neverSyncs,
        "terminalBackgroundFillMode": .neverSyncs,
        "terminalBackgroundBlur": .neverSyncs,
        "naturalTextEditingEnabled": .neverSyncs,
        "showAccessoryBar": .neverSyncs,
        "accessoryBarKeys": .syncable,
        "modifierBehavior": .syncable,
        "filesReaperDays": .syncable,
        "filesDefaultDestination": .syncable,
        "requireFaceIDToUnlock": .neverSyncs,
        "autoLockMinutes": .neverSyncs,
        "lockWhenBackgrounded": .neverSyncs,
        "requireBiometricForKeyUse": .neverSyncs,
        "bellSoundEnabled": .syncable,
        "bellVisualEnabled": .syncable,
        "bellNotificationEnabled": .syncable,
        "agentCenterNotificationsEnabled": .neverSyncs,
        "agentCenterEnabled": .neverSyncs,
        "swipePadEnabled": .neverSyncs,
        "swipePadCorner": .neverSyncs,
        "swipePadSize": .neverSyncs,
        "swipePadLastX": .neverSyncs,
        "swipePadLastY": .neverSyncs,
        "voiceDictationEnabled": .neverSyncs,
        "voiceCommitOnSilence": .neverSyncs,
        "voiceAppendReturn": .neverSyncs,
        "voiceWaveformOnPuck": .neverSyncs,
        "hasSeenWelcome": .neverSyncs
    ]
}

// Internal (not private) so BootstrapWireSchemaTests can pin every decoder
// allowlist set against the frozen v2 schema files — widening an allowlist
// without a schema-folder bump must fail CI.
enum BootstrapManifestSchema {
    static let root: Set<String> = [
        "version", "identities", "hosts", "jumpChains", "knownHosts",
        "appearance", "settings"
    ]
    static let identity: Set<String> = ["id", "name", "user"]
    static let host: Set<String> = [
        "id", "name", "address", "port", "user", "transport", "launchMode",
        "tmuxSessionName", "tags", "osHint", "sortOrder", "authenticationHint",
        "identityID", "hostKeyFingerprint", "launchCommand", "notes", "envVars",
        "startupSnippet", "portForwards"
    ]
    static let jumpLink: Set<String> = ["hostID", "jumpHostID"]
    static let knownHost: Set<String> = [
        "hostID", "fingerprint", "keyString", "firstSeen", "lastSeen"
    ]
    static let appearance: Set<String> = [
        "colorScheme", "accent", "customAccentRGB", "monospacedFontName",
        "terminalFontSize", "chromeMaterial", "cursorStyle", "cursorBlink", "terminalThemeID"
    ]
    static let settings: Set<String> = [
        "scrollbackLines", "modifierBehavior", "bellSoundEnabled",
        "bellVisualEnabled", "bellNotificationEnabled",
        "accessoryBarKeys", "filesReaperDays", "filesDefaultDestination"
    ]
    static let forward: Set<String> = [
        "id", "enabled", "autoStart", "localPort", "remoteHost", "remotePort", "label"
    ]

    static func rejectUnknownFields(in data: Data) throws {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BootstrapManifestError.malformedJSON
        }
        guard let object = raw as? [String: Any] else {
            throw BootstrapManifestError.malformedJSON
        }
        try check(object, allowed: root, path: "manifest")

        guard let identities = object["identities"] as? [[String: Any]],
              let hosts = object["hosts"] as? [[String: Any]],
              let links = object["jumpChains"] as? [[String: Any]],
              let appearanceObject = object["appearance"] as? [String: Any],
              let settingsObject = object["settings"] as? [String: Any] else {
            // Codable will provide the useful missing/type error.
            return
        }
        let knownHosts = object["knownHosts"] as? [[String: Any]] ?? []
        for (index, value) in identities.enumerated() {
            try check(value, allowed: identity, path: "manifest.identities[\(index)]")
        }
        for (index, value) in hosts.enumerated() {
            try check(value, allowed: host, path: "manifest.hosts[\(index)]")
            if let forwards = value["portForwards"] as? [[String: Any]] {
                for (forwardIndex, forwardValue) in forwards.enumerated() {
                    try check(
                        forwardValue,
                        allowed: forward,
                        path: "manifest.hosts[\(index)].portForwards[\(forwardIndex)]"
                    )
                }
            }
        }
        for (index, value) in links.enumerated() {
            try check(value, allowed: jumpLink, path: "manifest.jumpChains[\(index)]")
        }
        for (index, value) in knownHosts.enumerated() {
            try check(
                value,
                allowed: knownHost,
                path: "manifest.knownHosts[\(index)]"
            )
        }
        try check(appearanceObject, allowed: appearance, path: "manifest.appearance")
        try check(settingsObject, allowed: settings, path: "manifest.settings")
    }

    private static func check(
        _ object: [String: Any],
        allowed: Set<String>,
        path: String
    ) throws {
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
            throw BootstrapManifestError.unknownField(path: path, field: unknown)
        }
    }
}
