import Foundation

public enum RuleValidationError: Error, Equatable {
    case localPortOutOfRange       // <1024 (iOS sandbox can't bind)
    case remoteHostEmpty
    case remotePortInvalid          // 0
    case localPortCollision(otherID: UUID)
}

public enum RuleValidator {
    public static func validate(
        rule: PortForwardRule,
        against existing: [PortForwardRule]
    ) throws {
        guard rule.localPort >= 1024 else {
            throw RuleValidationError.localPortOutOfRange
        }
        let trimmedHost = rule.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw RuleValidationError.remoteHostEmpty
        }
        guard rule.remotePort >= 1 else {
            throw RuleValidationError.remotePortInvalid
        }
        if let conflict = existing.first(where: { $0.id != rule.id && $0.localPort == rule.localPort }) {
            throw RuleValidationError.localPortCollision(otherID: conflict.id)
        }
    }
}
