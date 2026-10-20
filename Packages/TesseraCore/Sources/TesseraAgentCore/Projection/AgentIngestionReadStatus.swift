import Foundation

/// The native reader classifies failures once. Platforms carry this status
/// without treating host work limits as local retained-page exhaustion.
public struct AgentIngestionReadStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case preparing, verifying, retryable, sourceChanged, unsupported, resourceLimited, failed
    }
    public enum Domain: String, Codable, Sendable { case source, provider, transport, host, client }
    public enum Recovery: String, Codable, Sendable {
        case `continue`, retryRead, rebootstrap, renewConnection, manual
    }
    public let v: Int
    public let state: State
    public let domain: Domain
    public let recovery: Recovery
    /// An opaque, native-allowlisted diagnostic token, never provider content.
    public let code: String
    public var isProgress: Bool { state == .preparing || state == .verifying }
    public var survivesReaderClosure: Bool { AgentReadRecoveryPolicy.retainsStatusAfterReaderClosure(self) }
    public var message: String {
        switch state {
        case .preparing: return "Preparing conversation…"
        case .verifying: return "Checking conversation changes…"
        case .retryable: return "Conversation read interrupted. Retrying…"
        case .sourceChanged: return "Conversation changed. Refreshing…"
        case .unsupported: return "This conversation format is not supported."
        case .resourceLimited: return "The host could not finish reading this conversation."
        case .failed: return "The conversation could not be read."
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        v = try values.decode(Int.self, forKey: .v)
        state = try values.decode(State.self, forKey: .state)
        domain = try values.decode(Domain.self, forKey: .domain)
        recovery = try values.decode(Recovery.self, forKey: .recovery)
        code = try values.decode(String.self, forKey: .code)
        guard v == 1, !code.isEmpty, code.utf8.count <= 80,
              code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }),
              isProgress == (recovery == .continue) else { throw AgentIngestionError.malformedFrame }
    }

    public static func decode(_ value: AgentJSONValue) throws -> Self {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 4096 else { throw AgentIngestionError.malformedFrame }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
