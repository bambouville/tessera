import Foundation
import TesseraDomainCore

/// The iOS editor's view of a rejected rule. Its first four cases are the
/// wording the forwarding editor has always shown; `shared` carries anything
/// the shared validator rejects that this local-only editor cannot produce.
public enum RuleValidationError: Error, Equatable {
    case localPortOutOfRange       // <1024 (iOS sandbox can't bind)
    case remoteHostEmpty
    case remotePortInvalid          // 0
    case localPortCollision(otherID: UUID)
    case shared(PortForwardRuleError)
}

/// iOS validation = the shared rules plus one platform overlay.
///
/// The `localPort >= 1024` floor is that overlay: an iOS app sandbox cannot
/// bind a privileged port, so the rule can never run here. It is deliberately
/// *not* in the shared model — a rule imported from a platform that can bind
/// port 80 stays valid there and is not rewritten on the way through.
public enum RuleValidator {
    public static func validate(
        rule: PortForwardRule,
        against existing: [PortForwardRule]
    ) throws {
        if rule.direction != .remote, rule.bind.port < 1024 {
            throw RuleValidationError.localPortOutOfRange
        }
        guard let failure = PortForwardRuleValidator.validate(rule, against: existing) else {
            return
        }
        switch failure {
        case .missingTarget, .invalidTargetAddress:
            throw RuleValidationError.remoteHostEmpty
        case .invalidTargetPort:
            throw RuleValidationError.remotePortInvalid
        case .bindCollision(let conflictingRuleID):
            throw RuleValidationError.localPortCollision(otherID: conflictingRuleID)
        case .invalidBindAddress, .invalidBindPort, .nonLoopbackLocalBind,
             .dynamicForwardCannotHaveTarget:
            throw RuleValidationError.shared(failure)
        }
    }
}
