import Crypto
import Foundation

public enum BootstrapHostTransport: String, Codable, CaseIterable, Sendable {
    case ssh
    case mosh
}

public enum BootstrapHostLaunchMode: String, Codable, CaseIterable, Sendable {
    case autoTmux
    case pinnedTmux
    case customCommand
}

public enum BootstrapAuthenticationHint: String, Codable, CaseIterable, Sendable {
    case none
    case password
    case publicKey
}

public enum BootstrapOptionalTransfer: String, CaseIterable, Hashable, Sendable, Identifiable {
    case launchCommands
    case notes
    case environmentVariables
    case startupSnippets
    case trustedHostKeys

    public var id: String { rawValue }
}

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

public struct BootstrapJumpLink: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let jumpHostID: UUID

    public init(hostID: UUID, jumpHostID: UUID) {
        self.hostID = hostID
        self.jumpHostID = jumpHostID
    }
}

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

public struct BootstrapGeneralSettings: Codable, Equatable, Sendable {
    public let scrollbackLines: Int
    public let modifierBehavior: String
    public let bellSoundEnabled: Bool
    public let bellVisualEnabled: Bool
    public let bellNotificationEnabled: Bool
    public let accessoryBarKeys: [String]
    public let filesReaperDays: Int
    public let filesDefaultDestination: String
    public let agentCenterEnabled: Bool?

    public init(
        scrollbackLines: Int,
        modifierBehavior: String,
        bellSoundEnabled: Bool,
        bellVisualEnabled: Bool,
        bellNotificationEnabled: Bool,
        accessoryBarKeys: [String],
        filesReaperDays: Int,
        filesDefaultDestination: String,
        agentCenterEnabled: Bool? = nil
    ) {
        self.scrollbackLines = scrollbackLines
        self.modifierBehavior = modifierBehavior
        self.bellSoundEnabled = bellSoundEnabled
        self.bellVisualEnabled = bellVisualEnabled
        self.bellNotificationEnabled = bellNotificationEnabled
        self.accessoryBarKeys = accessoryBarKeys
        self.filesReaperDays = filesReaperDays
        self.filesDefaultDestination = filesDefaultDestination
        self.agentCenterEnabled = agentCenterEnabled
    }
}

public enum BootstrapManifestError: Error, Equatable, Sendable {
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
}

/// Manifest schema v2. Optional extensions must be omitted for receivers
/// that have not established support. Its version is independent from
/// both legacy-nearby-bootstrap v2 and pairing v1.
public struct BootstrapManifestV2: Codable, Equatable, Sendable {
    public static let currentVersion = BootstrapManifestProtocol.currentVersion
    public static let maximumEncodedByteCount = 1_048_576
    public static let maximumHostCount = 1_000
    public static let maximumIdentityCount = 1_000
    public static let maximumJumpChainCount = 1_000
    public static let maximumKnownHostCount = 1_000

    public let version: Int
    public let identities: [BootstrapIdentityDescriptor]
    public let hosts: [BootstrapHostDescriptor]
    public let jumpChains: [BootstrapJumpLink]
    public let knownHosts: [BootstrapKnownHostDescriptor]?
    public let appearance: BootstrapAppearanceSettings
    public let settings: BootstrapGeneralSettings

    public init(
        version: Int = BootstrapManifestV2.currentVersion,
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

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedByteCount else {
            throw BootstrapManifestError.encodedSizeExceeded(
                actual: data.count,
                maximum: maximumEncodedByteCount
            )
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BootstrapManifestError.malformedJSON
        }
        guard let root = raw as? [String: Any] else {
            throw BootstrapManifestError.malformedJSON
        }
        if let version = root["version"] as? Int, version != currentVersion {
            throw BootstrapManifestError.unsupportedVersion(version)
        }
        try BootstrapManifestSchemaV2.rejectUnknownFields(root)
        let manifest = try JSONDecoder().decode(Self.self, from: data)
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
                throw BootstrapManifestError.invalidKnownHost(knownHost.hostID, field: "hostID")
            }
            try Self.validate(knownHost)
        }
        try Self.validate(appearance)
        try Self.validate(settings)
    }

    public func selectingOptionalTransfers(
        _ selected: Set<BootstrapOptionalTransfer>
    ) throws -> Self {
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
                launchCommand: selected.contains(.launchCommands) ? host.launchCommand : nil,
                notes: selected.contains(.notes) ? host.notes : nil,
                envVars: selected.contains(.environmentVariables) ? host.envVars : nil,
                startupSnippet: selected.contains(.startupSnippets) ? host.startupSnippet : nil,
                portForwards: host.portForwards
            )
        }
        let filtered = Self(
            version: version,
            identities: identities,
            hosts: filteredHosts,
            jumpChains: jumpChains,
            knownHosts: selected.contains(.trustedHostKeys) ? (knownHosts ?? []) : [],
            appearance: appearance,
            settings: settings
        )
        try filtered.validate()
        try filtered.validateOptionalTransferSelection(selected)
        return filtered
    }

    /// Every host that must travel for `selected` to arrive intact: the chosen
    /// hosts plus, transitively, the jump hosts they route through. A route
    /// cannot be copied half-formed, so a selected host silently losing its
    /// jump would change its meaning on the receiving device.
    public static func hostSelectionClosure(
        _ selected: Set<UUID>,
        jumpChains: [BootstrapJumpLink]
    ) -> Set<UUID> {
        var required = selected
        // Chains are validated acyclic, so this settles; the bound is belt and
        // braces against a malformed set reaching us before validation.
        for _ in 0...jumpChains.count {
            var added = false
            for link in jumpChains where required.contains(link.hostID) {
                if required.insert(link.jumpHostID).inserted { added = true }
            }
            if !added { break }
        }
        return required
    }

    /// Narrows the manifest to the selected hosts and their required jump
    /// hosts. Unlike the optional-transfer selection, which blanks fields on
    /// every host, an unselected host does not travel at all.
    ///
    /// Identities are pruned to those the surviving hosts reference; jump links
    /// and known-host records naming an excluded host are dropped, which is what
    /// keeps the result referentially valid.
    public func selectingHosts(_ selected: Set<UUID>) throws -> Self {
        let required = Self.hostSelectionClosure(selected, jumpChains: jumpChains)
        let keptHosts = hosts.filter { required.contains($0.id) }
        let keptHostIDs = Set(keptHosts.map(\.id))
        let referencedIdentityIDs = Set(keptHosts.compactMap(\.identityID))
        let filtered = Self(
            version: version,
            identities: identities.filter { referencedIdentityIDs.contains($0.id) },
            hosts: keptHosts,
            jumpChains: jumpChains.filter {
                keptHostIDs.contains($0.hostID) && keptHostIDs.contains($0.jumpHostID)
            },
            knownHosts: (knownHosts ?? []).filter { keptHostIDs.contains($0.hostID) },
            appearance: appearance,
            settings: settings
        )
        try filtered.validate()
        return filtered
    }

    public func validateOptionalTransferSelection(
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
        if !selected.contains(.launchCommands), hosts.contains(where: { $0.launchCommand != nil }) {
            throw BootstrapManifestError.unselectedOptionalField("launchCommand")
        }
        if !selected.contains(.notes), hosts.contains(where: { $0.notes != nil }) {
            throw BootstrapManifestError.unselectedOptionalField("notes")
        }
        if !selected.contains(.environmentVariables), hosts.contains(where: { $0.envVars != nil }) {
            throw BootstrapManifestError.unselectedOptionalField("envVars")
        }
        if !selected.contains(.startupSnippets), hosts.contains(where: { $0.startupSnippet != nil }) {
            throw BootstrapManifestError.unselectedOptionalField("startupSnippet")
        }
    }

    /// Minimal descriptor validation used by the Apple export adapter before
    /// it admits a persistence row into a portable manifest.
    public static func validateIdentityDescriptor(
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

    /// Minimal descriptor validation used by the Apple export adapter before
    /// it admits a persistence row into a portable manifest.
    public static func validateHostDescriptor(
        _ host: BootstrapHostDescriptor
    ) throws {
        guard !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              host.name.utf8.count <= 256 else {
            throw BootstrapManifestError.invalidHost(host.id, field: "name")
        }
        guard !host.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              host.address.utf8.count <= 1_024 else {
            throw BootstrapManifestError.invalidHost(host.id, field: "address")
        }
        guard host.port > 0 else {
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
            ("startupSnippet", host.startupSnippet),
        ] where value?.utf8.count ?? 0 > 65_536 {
            throw BootstrapManifestError.invalidHost(host.id, field: field)
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

    private static func validate(_ knownHost: BootstrapKnownHostDescriptor) throws {
        guard knownHost.keyString.utf8.count <= 16_384,
              let keyBlob = OpenSSHPublicKeyText.parse(knownHost.keyString) else {
            throw BootstrapManifestError.invalidKnownHost(knownHost.hostID, field: "keyString")
        }
        guard knownHost.fingerprint.utf8.count <= 256,
              OpenSSHPublicKeyText.fingerprint(keyBlob.blob) == knownHost.fingerprint else {
            throw BootstrapManifestError.invalidKnownHost(knownHost.hostID, field: "fingerprint")
        }
        guard knownHost.firstSeen <= knownHost.lastSeen else {
            throw BootstrapManifestError.invalidKnownHost(knownHost.hostID, field: "dates")
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

public typealias BootstrapManifest = BootstrapManifestV2

public struct ApprovedBootstrapManifestV2: Equatable, Sendable {
    public let manifest: BootstrapManifestV2
    public let selectedOptionalTransfers: Set<BootstrapOptionalTransfer>

    /// - Parameter selectedHostIDs: the hosts to copy, or `nil` for every host.
    ///   Selection narrows the manifest itself, so an unselected host does not
    ///   travel; the pairing transaction requires the authorization set to cover
    ///   exactly the hosts that remain.
    public init(
        exportedManifest: BootstrapManifestV2,
        selectedHostIDs: Set<UUID>? = nil,
        selectedOptionalTransfers: Set<BootstrapOptionalTransfer>
    ) throws {
        self.selectedOptionalTransfers = selectedOptionalTransfers
        let hostFiltered = try selectedHostIDs.map(exportedManifest.selectingHosts) ?? exportedManifest
        manifest = try hostFiltered.selectingOptionalTransfers(selectedOptionalTransfers)
    }

    public func validate() throws {
        try manifest.validateOptionalTransferSelection(selectedOptionalTransfers)
    }
}

private enum OpenSSHPublicKeyText {
    struct Parsed {
        let algorithm: String
        let blob: Data
    }

    static func parse(_ value: String) -> Parsed? {
        let fields = value.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2,
              let blob = Data(base64Encoded: String(fields[1])),
              blob.base64EncodedString() == fields[1],
              sshStringPrefix(blob) == fields[0]
        else { return nil }
        return Parsed(algorithm: String(fields[0]), blob: blob)
    }

    static func fingerprint(_ blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob))
        // Nearby-bootstrap v2 shipped with KnownHostsStore's padded base64
        // fingerprint spelling. Preserve those exact Apple bytes so existing
        // iOS peers remain valid across the shared-core migration.
        return "SHA256:" + digest.base64EncodedString()
    }

    private static func sshStringPrefix(_ blob: Data) -> Substring? {
        guard blob.count >= 4 else { return nil }
        let count = blob.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 128, blob.count >= 4 + count,
              let value = String(data: blob.subdata(in: 4..<(4 + count)), encoding: .utf8)
        else { return nil }
        return Substring(value)
    }
}

/// Internal so the ProtocolCore test target can prove the strict decoder
/// allowlists remain identical to the frozen v2 JSON schema. This is not part
/// of the package's public manifest API.
enum BootstrapManifestSchemaV2 {
    static let root: Set<String> = [
        "version", "identities", "hosts", "jumpChains", "knownHosts",
        "appearance", "settings",
    ]
    static let identity: Set<String> = ["id", "name", "user"]
    static let host: Set<String> = [
        "id", "name", "address", "port", "user", "transport", "launchMode",
        "tmuxSessionName", "tags", "osHint", "sortOrder", "authenticationHint",
        "identityID", "hostKeyFingerprint", "launchCommand", "notes", "envVars",
        "startupSnippet", "portForwards",
    ]
    static let jumpLink: Set<String> = ["hostID", "jumpHostID"]
    static let knownHost: Set<String> = [
        "hostID", "fingerprint", "keyString", "firstSeen", "lastSeen",
    ]
    static let appearance: Set<String> = [
        "colorScheme", "accent", "customAccentRGB", "monospacedFontName",
        "terminalFontSize", "chromeMaterial", "cursorStyle", "cursorBlink",
        "terminalThemeID",
    ]
    static let settings: Set<String> = [
        "scrollbackLines", "modifierBehavior", "bellSoundEnabled",
        "bellVisualEnabled", "bellNotificationEnabled", "accessoryBarKeys",
        "filesReaperDays", "filesDefaultDestination", "agentCenterEnabled",
    ]
    static let forward: Set<String> = [
        "id", "enabled", "autoStart", "localPort", "remoteHost", "remotePort", "label",
    ]

    static func rejectUnknownFields(_ object: [String: Any]) throws {
        try check(object, allowed: root, path: "manifest")
        guard let identities = object["identities"] as? [[String: Any]],
              let hosts = object["hosts"] as? [[String: Any]],
              let links = object["jumpChains"] as? [[String: Any]],
              let appearanceObject = object["appearance"] as? [String: Any],
              let settingsObject = object["settings"] as? [String: Any] else { return }
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
            try check(value, allowed: knownHost, path: "manifest.knownHosts[\(index)]")
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
