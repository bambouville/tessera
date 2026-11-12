import Foundation
import TesseraDomainCore

/// {"type":"reuse","ruleID":"…","target":{…}} or
/// {"type":"ephemeral","rule":{…}}. The ephemeral ID is the nil UUID,
/// a deterministic sentinel, never an ID to persist. A lease is keyed by
/// its tab in the platform layer. keepAsRule replaces it with a caller ID.
public enum ArtifactsForwardPlan: Codable, Equatable, Sendable {
    case reuse(ruleID: UUID, target: ForwardedWebTarget)
    case ephemeral(PortForwardRule)

    private struct Wire: Codable {
        var type: String
        var ruleID: UUID?
        var target: ForwardedWebTarget?
        var rule: PortForwardRule?
    }

    public init(from decoder: Decoder) throws {
        let w = try Wire(from: decoder)
        switch w.type {
        case "reuse":
            guard let id = w.ruleID, let target = w.target else { throw ArtifactsCoding.invalid(decoder, "missing reused rule") }
            self = .reuse(ruleID: id, target: target)
        case "ephemeral":
            guard let rule = w.rule else { throw ArtifactsCoding.invalid(decoder, "missing ephemeral rule") }
            self = .ephemeral(rule)
        default: throw ArtifactsCoding.invalid(decoder, "unknown forward plan")
        }
    }

    public func encode(to encoder: Encoder) throws {
        let w: Wire
        switch self {
        case let .reuse(id, target): w = Wire(type: "reuse", ruleID: id, target: target)
        case let .ephemeral(rule): w = Wire(type: "ephemeral", rule: rule)
        }
        try w.encode(to: encoder)
    }
}

public enum ArtifactsForwardPlanner {
    private static let ephemeralID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// remotePort must be nonzero. The ABI rejects zero before calling.
    /// Reuse is limited to enabled, valid local loopback rules targeting the
    /// remote loopback. A rule to another service host is not interchangeable.
    public static func plan(remotePort: UInt16, hostRules: [PortForwardRule]) -> ArtifactsForwardPlan {
        let reusable = hostRules.sorted { $0.id.uuidString < $1.id.uuidString }.first {
            $0.target?.port == remotePort && isReusable($0, hostRules: hostRules)
        }
        if let rule = reusable, let target = ForwardedWebPolicy.webTarget(for: rule) {
            return .reuse(ruleID: rule.id, target: target)
        }
        let occupied = hostRules.contains { $0.enabled && $0.direction != .remote && $0.bind.port == remotePort }
        let bindPort = remotePort >= 1024 && !occupied ? remotePort : 0
        return .ephemeral(.localForward(id: ephemeralID, autoStart: false, localPort: bindPort,
                                        remoteHost: "localhost", remotePort: remotePort))
    }

    /// Whether a page tab for this rule's target port borrows the rule
    /// rather than opening a forward of its own.
    static func isReusable(_ rule: PortForwardRule, hostRules: [PortForwardRule]) -> Bool {
        rule.enabled && rule.direction == .local
            && ArtifactsLinkClassifier.isRemoteLoopback(rule.target?.host ?? "")
            && PortForwardRuleValidator.validate(rule, against: hostRules) == nil
            && ForwardedWebPolicy.webTarget(for: rule) != nil
    }

    /// The caller first replaces bind.port=0 with the actual allocated port.
    /// The returned persistent rule is enabled, with autoStart=true.
    public static func keepAsRule(_ ephemeral: PortForwardRule, label: String, ruleID: UUID) -> PortForwardRule {
        PortForwardRule(id: ruleID, enabled: true, autoStart: true, direction: ephemeral.direction,
                        bind: ephemeral.bind, target: ephemeral.target, label: label)
    }

    /// DomainCore forbids port 0 on persisted local rules. Ephemeral rules
    /// deliberately use it for OS allocation, so validate their structure
    /// with a temporary nonzero port, then validate any assigned port exactly.
    public static func isValidEphemeral(_ rule: PortForwardRule) -> Bool {
        guard rule.direction == .local else { return false }
        var structural = rule
        if structural.bind.port == 0 { structural.bind.port = 1 }
        return PortForwardRuleValidator.validate(structural) == nil
    }
}
