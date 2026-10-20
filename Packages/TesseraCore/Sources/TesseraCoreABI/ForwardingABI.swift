import Foundation
import TesseraDomainCore

/// Port-forwarding policy: rule validation, transport capabilities, and the
/// restart rule.
///
/// The model was lifted from Android, so the Kotlin data classes stay as the
/// Room/UI layer and only the decisions cross here. Two deltas are deliberate
/// and Kotlin must expect them: ports are `UInt16`, so Android's
/// out-of-range-port branch is unrepresentable rather than reachable; and
/// `unavailableReason` is an enum rather than English prose, because each
/// platform localizes its own copy.

/// `{"existing":[…],"rule":{…}}` — `rule` and each `existing` element are
/// `PortForwardRule` JSON:
/// ```json
/// {"autoStart":true,"bind":{"host":"127.0.0.1","port":8080},
///  "direction":"local","enabled":true,"id":"…","label":"",
///  "target":{"host":"localhost","port":80}}
/// ```
/// `direction` is `local` | `remote` | `dynamic`. The retired flat spelling
/// (`bindAddress`/`bindPort`/`targetHost`/`targetPort`) still decodes, so a
/// payload written before the model grew endpoints still loads.
public struct PortForwardValidateABIRequest: Codable, Equatable, Sendable {
    public var rule: PortForwardRule
    public var existing: [PortForwardRule]

    public init(rule: PortForwardRule, existing: [PortForwardRule]) {
        self.rule = rule
        self.existing = existing
    }
}

/// `{"valid":false,"error":{"kind":"nonLoopbackLocalBind","host":"0.0.0.0"}}`
///
/// `kind` is one of the eight shared cases: `invalidBindAddress`,
/// `invalidBindPort`, `nonLoopbackLocalBind`, `missingTarget`,
/// `invalidTargetAddress`, `invalidTargetPort`,
/// `dynamicForwardCannotHaveTarget`, `bindCollision`. At most one payload
/// field accompanies it — `host`, `port`, or `conflictingRuleID`.
public struct PortForwardValidateABIResponse: Codable, Equatable, Sendable {
    public struct RuleError: Codable, Equatable, Sendable {
        public var kind: String
        public var host: String?
        public var port: Int?
        public var conflictingRuleID: UUID?
    }

    public var valid: Bool
    public var error: RuleError?
}

/// Validates a rule against the set it will join.
///
/// Local and dynamic listeners are loopback-only; only a remote bind may use
/// port 0 (the server allocates it and reports back); a dynamic rule must have
/// no target; and a bind collision is checked only among *enabled*, non-remote
/// rules — a disabled rule no longer reserves its port, which is Android's
/// semantics, adopted.
///
/// Returns the byte count under the string contract, or -1 for invalid
/// arguments. A rejected rule is a successful call with `valid: false`.
@_cdecl("tessera_forwarding_validate_rule")
public func tesseraForwardingValidateRule(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        PortForwardValidateABIRequest.self,
        requestBytes,
        requestCount
    ) else { return -1 }
    let error = PortForwardRuleValidator.validate(request.rule, against: request.existing)
    let projected: PortForwardValidateABIResponse.RuleError?
    switch error {
    case nil:
        projected = nil
    case let .invalidBindAddress(host):
        projected = .init(kind: "invalidBindAddress", host: host, port: nil, conflictingRuleID: nil)
    case let .invalidBindPort(port):
        projected = .init(kind: "invalidBindPort", host: nil, port: Int(port), conflictingRuleID: nil)
    case let .nonLoopbackLocalBind(host):
        projected = .init(kind: "nonLoopbackLocalBind", host: host, port: nil, conflictingRuleID: nil)
    case .missingTarget:
        projected = .init(kind: "missingTarget", host: nil, port: nil, conflictingRuleID: nil)
    case let .invalidTargetAddress(host):
        projected = .init(kind: "invalidTargetAddress", host: host, port: nil, conflictingRuleID: nil)
    case let .invalidTargetPort(port):
        projected = .init(kind: "invalidTargetPort", host: nil, port: Int(port), conflictingRuleID: nil)
    case .dynamicForwardCannotHaveTarget:
        projected = .init(
            kind: "dynamicForwardCannotHaveTarget",
            host: nil,
            port: nil,
            conflictingRuleID: nil
        )
    case let .bindCollision(conflictingRuleID):
        projected = .init(
            kind: "bindCollision",
            host: nil,
            port: nil,
            conflictingRuleID: conflictingRuleID
        )
    }
    return SharedABI.copyOutJSON(
        PortForwardValidateABIResponse(valid: projected == nil, error: projected),
        outputBytes,
        outputCapacity
    )
}

/// What a transport can forward.
///
/// `{"dynamic":true,"local":true,"remote":true}`
///
/// `unavailableReason` — `moshWithoutSSHSideChannel` — is present only when a
/// transport cannot forward. A reason, not a sentence, because the platforms
/// localize.
@_cdecl("tessera_forwarding_capabilities")
public func tesseraForwardingCapabilities(
    transport: Int32,
    sshSideChannelAvailable: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    let forwardingTransport: ForwardingTransport
    switch transport {
    case 0:
        forwardingTransport = .ssh
    case 1:
        // Mosh can forward only while its authenticated SSH side channel
        // exists; the flag is the whole question for this transport.
        forwardingTransport = .mosh(sshSideChannelAvailable: sshSideChannelAvailable != 0)
    default:
        return -1
    }
    return SharedABI.copyOutJSON(
        ForwardingCapabilities.forTransport(forwardingTransport),
        outputBytes,
        outputCapacity
    )
}

/// `{"other":{…},"rule":{…}}` — both `PortForwardRule` JSON.
public struct PortForwardRestartABIRequest: Codable, Equatable, Sendable {
    public var rule: PortForwardRule
    public var other: PortForwardRule

    public init(rule: PortForwardRule, other: PortForwardRule) {
        self.rule = rule
        self.other = other
    }
}

/// Whether applying `other` in place of `rule` requires tearing the listener
/// down instead of updating it. Label, enabled, and autoStart changes never
/// disturb live traffic. Returns 1, 0, or -1 for invalid arguments.
@_cdecl("tessera_forwarding_requires_restart")
public func tesseraForwardingRequiresRestart(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        PortForwardRestartABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 65_536
    ) else { return -1 }
    return request.rule.requiresRestart(other: request.other) ? 1 : 0
}

/// The subset of rules the cross-device bootstrap manifest can carry: loopback
/// local forwards that have a target.
///
/// `BootstrapPortForwardRule` predates the direction/endpoint model and
/// describes exactly one shape, so dynamic rules (no target) and remote rules
/// (bound on the server) are dropped rather than silently flattened into a
/// wrong local rule. Takes and returns a `PortForwardRule` JSON array.
/// Returns the byte count under the string contract, or -1 for invalid
/// arguments.
@_cdecl("tessera_forwarding_portable_local_subset")
public func tesseraForwardingPortableLocalSubset(
    rulesBytes: UnsafePointer<UInt8>?,
    rulesCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let rules = SharedABI.decode([PortForwardRule].self, rulesBytes, rulesCount)
    else { return -1 }
    return SharedABI.copyOutJSON(
        PortForwardRule.portableLocalSubset(of: rules),
        outputBytes,
        outputCapacity
    )
}

/// `{"browsable":true,"target":{"scheme":"http","host":"127.0.0.1",
///   "port":8080,"url":"http://127.0.0.1:8080/"}}`
///
/// `target` is absent when `browsable` is false.
public struct PortForwardWebTargetABIResponse: Codable, Equatable, Sendable {
    public var browsable: Bool
    public var target: ForwardedWebTarget?
}

/// Whether a rule can be opened in the in-app browser, and at what URL.
///
/// Addressability only: a local loopback bind whose service port is not a
/// known non-web protocol. Whether the listener is running right now is the
/// caller's question — live forwarder state never crosses this ABI.
///
/// Takes `PortForwardRule` JSON. Returns the byte count under the string
/// contract, or -1 for invalid arguments; a rule that is simply not browsable
/// is a successful call with `browsable: false`.
@_cdecl("tessera_forwarding_web_target")
public func tesseraForwardingWebTarget(
    ruleBytes: UnsafePointer<UInt8>?,
    ruleCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let rule = SharedABI.decode(
        PortForwardRule.self,
        ruleBytes,
        ruleCount,
        maximum: 65_536
    ) else { return -1 }
    let target = ForwardedWebPolicy.webTarget(for: rule)
    return SharedABI.copyOutJSON(
        PortForwardWebTargetABIResponse(browsable: target != nil, target: target),
        outputBytes,
        outputCapacity
    )
}
