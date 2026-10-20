import Foundation

/// A freshly sampled source frontier, independent of canonical history indexing.
/// Portable file offsets exclude preexisting bytes; they do not establish causal
/// receipt because other writers and truncation/regrowth cannot be excluded.
public struct AgentOutgoingFrontier: Equatable, Codable, Sendable {
    public enum Consistency: String, Codable, Sendable { case observedPrefix, unavailable }
    public let version: Int
    public let actionID: UUID
    public let serviceEpoch: String?
    public let provider: AgentProviderID
    public let providerSessionID: String
    public let sourceIdentity: String?
    public let sourceEnd: UInt64?
    public let consistency: Consistency

    public init?(version: Int = 1, actionID: UUID, serviceEpoch: String? = nil,
                 provider: AgentProviderID, providerSessionID: String,
                 sourceIdentity: String? = nil, sourceEnd: UInt64? = nil,
                 consistency: Consistency) {
        guard version == 1, !providerSessionID.isEmpty, providerSessionID.utf8.count <= 512,
              !providerSessionID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              serviceEpoch.map(AgentIngestionRange.identifier) ?? true,
              sourceIdentity.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) ?? true,
              consistency == .observedPrefix ? (serviceEpoch != nil && sourceIdentity != nil && sourceEnd != nil)
                : (sourceIdentity == nil && sourceEnd == nil) else { return nil }
        self.version = version; self.actionID = actionID; self.serviceEpoch = serviceEpoch
        self.provider = provider; self.providerSessionID = providerSessionID
        self.sourceIdentity = sourceIdentity; self.sourceEnd = sourceEnd; self.consistency = consistency
    }

    public static func unavailable(for lease: AgentActionLease) -> Self {
        Self(actionID: lease.token, provider: lease.threadID.providerID,
             providerSessionID: lease.threadID.providerSessionID, consistency: .unavailable)!
    }

    private enum CodingKeys: String, CodingKey {
        case version, actionID, serviceEpoch, provider, providerSessionID, sourceIdentity, sourceEnd, consistency
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawEnd = try values.decodeIfPresent(String.self, forKey: .sourceEnd)
        guard rawEnd == nil || rawEnd.flatMap(UInt64.init) != nil,
              let provider = AgentProviderID(rawValue: try values.decode(String.self, forKey: .provider)),
              let value = Self(version: try values.decode(Int.self, forKey: .version),
                actionID: try values.decode(UUID.self, forKey: .actionID),
                serviceEpoch: try values.decodeIfPresent(String.self, forKey: .serviceEpoch),
                provider: provider,
                providerSessionID: try values.decode(String.self, forKey: .providerSessionID),
                sourceIdentity: try values.decodeIfPresent(String.self, forKey: .sourceIdentity),
                sourceEnd: rawEnd.flatMap(UInt64.init),
                consistency: try values.decode(Consistency.self, forKey: .consistency)) else {
            throw DecodingError.dataCorruptedError(forKey: .sourceEnd, in: values, debugDescription: "Invalid outgoing frontier")
        }
        self = value
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(actionID, forKey: .actionID)
        try values.encodeIfPresent(serviceEpoch, forKey: .serviceEpoch)
        try values.encode(provider.rawValue, forKey: .provider); try values.encode(providerSessionID, forKey: .providerSessionID)
        try values.encodeIfPresent(sourceIdentity, forKey: .sourceIdentity)
        try values.encodeIfPresent(sourceEnd.map(String.init), forKey: .sourceEnd)
        try values.encode(consistency, forKey: .consistency)
    }
}
