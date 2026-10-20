import Foundation

// The shared port-forwarding model. Lifted from Android
// (`android/port-forwarding/src/main/kotlin/.../PortForwardingModels.kt`),
// which is the richer of the two platforms: it already carried a direction,
// a bind/target endpoint pair, dynamic SOCKS forwards, and the typed error
// set. iOS previously modelled only "local port → remote host:port" inside
// `Packages/PortForwarding`; that package is now a thin shim over this file,
// and its legacy storage blob is migrated by `RuleCodec`.
//
// Deliberate deltas from the Kotlin original, all noted where they occur:
//   * ports are `UInt16`, so Android's "port outside 0...65535" branch is
//     unrepresentable rather than validated,
//   * `unavailableReason` is a reason enum instead of English prose, because
//     each platform localizes its own copy.

/// `local` is SSH's `-L`, `remote` is `-R`, and `dynamic` is a local SOCKS5
/// listener whose CONNECT requests become SSH direct-tcpip channels.
public enum PortForwardDirection: String, Codable, CaseIterable, Sendable {
    case local
    case remote
    case dynamic
}

/// One side of a forward. A `local`/`dynamic` bind is a listener on this
/// device; a `remote` bind is a listener on the server.
public struct PortForwardEndpoint: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// A secret-free forwarding rule. It deliberately does not retain an SSH
/// client, socket, or credential reference, so it is safe to persist with a
/// host profile and to carry across a device-to-device transfer.
public struct PortForwardRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var enabled: Bool
    public var autoStart: Bool
    public var direction: PortForwardDirection
    public var bind: PortForwardEndpoint
    public var target: PortForwardEndpoint?
    public var label: String

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        autoStart: Bool = true,
        direction: PortForwardDirection = .local,
        bind: PortForwardEndpoint,
        target: PortForwardEndpoint? = nil,
        label: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.autoStart = autoStart
        self.direction = direction
        self.bind = bind
        self.target = target
        self.label = label
    }

    /// The loopback local forward that both platforms' legacy persistence and
    /// the bootstrap manifest's portable subset describe:
    /// `bind 127.0.0.1:localPort → target remoteHost:remotePort`.
    ///
    /// This is the one shape the cross-device wire format can express, so it
    /// is also the shape `RuleCodec` produces when it reads an iOS blob
    /// written before the model gained a direction.
    public static func localForward(
        id: UUID = UUID(),
        enabled: Bool = true,
        autoStart: Bool = true,
        localPort: UInt16,
        remoteHost: String = "localhost",
        remotePort: UInt16,
        label: String = ""
    ) -> PortForwardRule {
        PortForwardRule(
            id: id,
            enabled: enabled,
            autoStart: autoStart,
            direction: .local,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: localPort),
            target: PortForwardEndpoint(host: remoteHost, port: remotePort),
            label: label
        )
    }

    /// Structural check kept deliberately weaker than
    /// ``PortForwardRuleValidator``: it is called from
    /// ``HostProfile/validated(maximumJumpCount:)`` on every route hop at
    /// connect time, so tightening it would turn previously-connectable saved
    /// hosts into hard dial failures. Editors, importers, and the connected-
    /// session reconciler use the full validator instead.
    public func validated() throws -> Self {
        guard !bind.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyBindAddress
        }
        if direction != .dynamic {
            let host = target?.host.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !host.isEmpty else {
                throw DomainValidationError.emptyTargetHost
            }
        }
        return self
    }

    /// True when applying `other` in place of this rule requires tearing the
    /// listener down instead of updating it in place. Label, enabled, and
    /// autoStart changes never disturb live traffic.
    public func requiresRestart(other: PortForwardRule) -> Bool {
        direction != other.direction || bind != other.bind || target != other.target
    }

    /// The subset of rules the cross-device bootstrap manifest can carry.
    ///
    /// `BootstrapPortForwardRule` predates the shared direction/endpoint model
    /// and describes exactly one shape — a loopback local forward with a
    /// target. Dynamic rules have no target and remote rules bind on the
    /// server, so neither survives the round trip; they are dropped rather
    /// than silently flattened into a wrong local rule.
    public static func portableLocalSubset(
        of rules: [PortForwardRule]
    ) -> [PortForwardRule] {
        rules.filter { $0.direction == .local && $0.target != nil }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case autoStart
        case direction
        case bind
        case target
        case label
        // Retired flat spelling of this same type, kept decodable so payloads
        // written before the model grew endpoints still load.
        case bindAddress
        case bindPort
        case targetHost
        case targetPort
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        autoStart = try values.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        direction = try values.decodeIfPresent(
            PortForwardDirection.self,
            forKey: .direction
        ) ?? .local
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        if let bind = try values.decodeIfPresent(PortForwardEndpoint.self, forKey: .bind) {
            self.bind = bind
            target = try values.decodeIfPresent(PortForwardEndpoint.self, forKey: .target)
        } else {
            bind = PortForwardEndpoint(
                host: try values.decode(String.self, forKey: .bindAddress),
                port: try values.decode(UInt16.self, forKey: .bindPort)
            )
            target = PortForwardEndpoint(
                host: try values.decode(String.self, forKey: .targetHost),
                port: try values.decode(UInt16.self, forKey: .targetPort)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(autoStart, forKey: .autoStart)
        try values.encode(direction, forKey: .direction)
        try values.encode(bind, forKey: .bind)
        try values.encodeIfPresent(target, forKey: .target)
        try values.encode(label, forKey: .label)
    }
}

/// The eight ways a rule can be rejected, matching Android's sealed
/// `PortForwardRuleError` one for one.
public enum PortForwardRuleError: Error, Equatable, Sendable {
    case invalidBindAddress(String)
    case invalidBindPort(UInt16)
    case nonLoopbackLocalBind(String)
    case missingTarget
    case invalidTargetAddress(String)
    case invalidTargetPort(UInt16)
    case dynamicForwardCannotHaveTarget
    case bindCollision(conflictingRuleID: UUID)
}

/// Validation shared by editor, import, and connected-session reconciliation.
/// Local and dynamic listeners are deliberately loopback-only. A remote bind is
/// server-side and may be non-loopback only when the user explicitly configures
/// it; its default remains 127.0.0.1.
public enum PortForwardRuleValidator {
    public static func validate(
        _ rule: PortForwardRule,
        against existing: some Sequence<PortForwardRule>
    ) -> PortForwardRuleError? {
        let bindHost = rule.bind.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if bindHost.isEmpty { return .invalidBindAddress(rule.bind.host) }

        // Only `remote` may bind port 0: the server allocates it and reports
        // the assignment back. A local or dynamic listener on port 0 would
        // hand the user an address they can never predict.
        if rule.direction != .remote, rule.bind.port == 0 {
            return .invalidBindPort(rule.bind.port)
        }

        if rule.direction != .remote, !isLoopback(bindHost) {
            return .nonLoopbackLocalBind(rule.bind.host)
        }

        switch rule.direction {
        case .local, .remote:
            guard let target = rule.target else { return .missingTarget }
            if target.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .invalidTargetAddress(target.host)
            }
            if target.port == 0 { return .invalidTargetPort(target.port) }
        case .dynamic:
            if rule.target != nil { return .dynamicForwardCannotHaveTarget }
        }

        // A server-assigned remote port cannot collide locally, and two remote
        // rules contend on the server, not on this device.
        if rule.bind.port != 0 {
            let collision = existing.first {
                $0.id != rule.id
                    && $0.enabled
                    && $0.bind.port == rule.bind.port
                    && $0.direction != .remote
                    && rule.direction != .remote
            }
            if let collision { return .bindCollision(conflictingRuleID: collision.id) }
        }
        return nil
    }

    public static func validate(_ rule: PortForwardRule) -> PortForwardRuleError? {
        validate(rule, against: EmptyCollection<PortForwardRule>())
    }

    public static func isLoopback(_ host: String) -> Bool {
        host.caseInsensitiveCompare("localhost") == .orderedSame
            || host == "127.0.0.1"
            || host == "::1"
    }
}

/// The forwarding carrier, not the terminal renderer or tmux presentation.
public enum ForwardingTransport: Equatable, Hashable, Sendable {
    case ssh
    /// Mosh can forward only while its authenticated SSH side channel exists.
    case mosh(sshSideChannelAvailable: Bool)
}

/// Why a transport cannot forward. Android carried English prose here; the
/// shared model carries a reason so each platform localizes its own copy.
public enum ForwardingUnavailableReason: String, Codable, Equatable, Sendable {
    case moshWithoutSSHSideChannel
}

public struct ForwardingCapabilities: Codable, Equatable, Hashable, Sendable {
    public let local: Bool
    public let remote: Bool
    public let dynamic: Bool
    public let unavailableReason: ForwardingUnavailableReason?

    public init(
        local: Bool,
        remote: Bool,
        dynamic: Bool,
        unavailableReason: ForwardingUnavailableReason? = nil
    ) {
        self.local = local
        self.remote = remote
        self.dynamic = dynamic
        self.unavailableReason = unavailableReason
    }

    public func supports(_ direction: PortForwardDirection) -> Bool {
        switch direction {
        case .local: return local
        case .remote: return remote
        case .dynamic: return dynamic
        }
    }

    public static func forTransport(
        _ transport: ForwardingTransport
    ) -> ForwardingCapabilities {
        switch transport {
        case .ssh:
            return ForwardingCapabilities(local: true, remote: true, dynamic: true)
        case .mosh(let sshSideChannelAvailable):
            guard sshSideChannelAvailable else {
                return ForwardingCapabilities(
                    local: false,
                    remote: false,
                    dynamic: false,
                    unavailableReason: .moshWithoutSSHSideChannel
                )
            }
            return ForwardingCapabilities(local: true, remote: true, dynamic: true)
        }
    }
}

/// A forwarded port this device can point a browser at.
///
/// `url` is the whole answer — already schemed, already bracketed for an IPv6
/// loopback — so neither platform assembles one of its own and drifts.
public struct ForwardedWebTarget: Codable, Equatable, Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: UInt16
    public let url: String

    public init(scheme: String, host: String, port: UInt16, url: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.url = url
    }

    public var isSecure: Bool { scheme == "https" }
}

/// Whether a forwarding rule is something a browser can open, and at what URL.
///
/// This answers *addressability* only — can this rule's bind address be dialled
/// from this device, and is what answers there plausibly a web server. Whether
/// the listener is up right now is a separate question, asked of live state
/// that the shared model deliberately does not hold: iOS reads its
/// `PortForwarder.state`, Android its `PortForwardingState`.
public enum ForwardedWebPolicy {
    /// Ports that answer a protocol no browser speaks. Opening one produces a
    /// hung request or a protocol error, never a page, so the affordance is
    /// withheld rather than offered and disappointed.
    public static let nonWebPorts: Set<UInt16> = [
        22,     // ssh
        23,     // telnet
        25, 465, 587,       // smtp
        110, 995,           // pop3
        143, 993,           // imap
        3306,   // mysql
        3389,   // rdp
        5432,   // postgres
        5900,   // vnc
        6379,   // redis
        11211,  // memcached
        27017,  // mongodb
    ]

    /// Ports where the forwarded service speaks TLS. The tunnel is transparent,
    /// so TLS is end to end: the browser must speak `https` on this side too.
    public static let secureWebPorts: Set<UInt16> = [443, 4443, 8443, 9443]

    public static func webTarget(for rule: PortForwardRule) -> ForwardedWebTarget? {
        // Only a local forward leaves a listener on this device that speaks the
        // forwarded service. A remote bind listens on the server — unreachable
        // from here — and a dynamic rule is a SOCKS5 proxy: dialling it with
        // HTTP gets a protocol error, not a page.
        guard rule.direction == .local, rule.bind.port != 0 else { return nil }
        let host = rule.bind.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PortForwardRuleValidator.isLoopback(host) else { return nil }

        // The *target* port names the service; the bind port is only the door
        // this device knocks on. `18080 → 5432` is postgres, not a site.
        let servicePort = rule.target?.port ?? rule.bind.port
        guard !nonWebPorts.contains(servicePort) else { return nil }

        let scheme = secureWebPorts.contains(servicePort) ? "https" : "http"
        // An IPv6 literal has to be bracketed before it can carry a port.
        let authority = host.contains(":") ? "[\(host)]" : host
        return ForwardedWebTarget(
            scheme: scheme,
            host: host,
            port: rule.bind.port,
            url: "\(scheme)://\(authority):\(rule.bind.port)/"
        )
    }
}
