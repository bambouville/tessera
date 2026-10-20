import Foundation

/// Bootstrap transaction v2 uses the frozen v1 bodies and state machine.
/// Only the envelope version and permitted manifest settings differ.
public struct BootstrapTransactionMessageV2: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public let version: Int
    public let transactionID: UUID
    public let kind: BootstrapTransactionMessageKindV1
    public let body: Data

    public init(transactionID: UUID, kind: BootstrapTransactionMessageKindV1, body: Data) {
        version = Self.currentVersion
        self.transactionID = transactionID
        self.kind = kind
        self.body = body
    }

    public func encoded() throws -> Data {
        try BootstrapTransactionMessageV1(version: version, transactionID: transactionID, kind: kind, body: body)
            .encoded(expectedVersion: Self.currentVersion)
    }

    public static func decode(_ data: Data) throws -> Self {
        let value = try BootstrapTransactionMessageV1.decode(data, expectedVersion: currentVersion)
        return Self(transactionID: value.transactionID, kind: value.kind, body: value.body)
    }
}
