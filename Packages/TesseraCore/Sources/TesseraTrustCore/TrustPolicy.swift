import Foundation

public struct KnownHostEndpoint: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 22) {
        self.host = host
        self.port = port
    }

    public var openSSHHostField: String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}

public struct SSHHostPublicKey: Codable, Equatable, Sendable {
    public let algorithm: String
    public let blob: Data
    public let fingerprint: String

    public init(algorithm: String, blob: Data, fingerprint: String) throws {
        guard !algorithm.isEmpty,
              algorithm.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !blob.isEmpty,
              fingerprint.hasPrefix("SHA256:"),
              fingerprint.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw TrustPolicyError.invalidKey }
        self.algorithm = algorithm
        self.blob = blob
        self.fingerprint = fingerprint
    }
}

public struct TrustedHostRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let endpoint: KnownHostEndpoint
    public let key: SSHHostPublicKey
    public let trustedAt: Date

    public init(
        id: UUID = UUID(),
        endpoint: KnownHostEndpoint,
        key: SSHHostPublicKey,
        trustedAt: Date
    ) {
        self.id = id
        self.endpoint = endpoint
        self.key = key
        self.trustedAt = trustedAt
    }
}

public struct PendingHostKeyChange: Equatable, Sendable {
    public let endpoint: KnownHostEndpoint
    public let trusted: SSHHostPublicKey
    public let presented: SSHHostPublicKey

    public init(
        endpoint: KnownHostEndpoint,
        trusted: SSHHostPublicKey,
        presented: SSHHostPublicKey
    ) {
        self.endpoint = endpoint
        self.trusted = trusted
        self.presented = presented
    }
}

public enum KnownHostCheckResult: Equatable, Sendable {
    case unknown(presented: SSHHostPublicKey, comparisonHint: String?)
    case trusted(TrustedHostRecord)
    case changed(PendingHostKeyChange)
    /// The presented key is not the pinned one, but it *is* the key this
    /// endpoint was pinned to before the last rotation.
    ///
    /// Android's `HostTrustEvaluation.Reverted` is the canonical model here.
    /// It is still a mismatch and still blocks — but it is a materially
    /// different story to tell the user ("this host went back to the key you
    /// replaced on the 3rd") than an unrecognised key, and collapsing the two
    /// throws away the one piece of evidence that distinguishes a botched
    /// server rollback from an attacker.
    ///
    /// `trusted` on the payload stays the *currently pinned* key, so a caller
    /// that does not care about the distinction can treat this exactly like
    /// `.changed`.
    case revertedToPrevious(PendingHostKeyChange)
}

public enum KnownHostConflictPolicy: String, Codable, Sendable {
    case preserveLocalAndReview
}

public enum KnownHostImportResult: Equatable, Sendable {
    case inserted(TrustedHostRecord)
    case unchanged(TrustedHostRecord)
    case conflict(local: TrustedHostRecord, imported: TrustedHostRecord)
}

public enum KnownHostTrustPolicy {
    /// Classifies a presented host key against the local pin.
    ///
    /// - Parameters:
    ///   - previous: the key this endpoint was pinned to before the most recent
    ///     rotation, if the platform keeps rotation history. Supplying it turns
    ///     a "went back to the old key" event into `.revertedToPrevious`
    ///     instead of a bare `.changed`. With `previous == nil` — what iOS
    ///     passes today — the result is byte-identical to the pre-rotation-
    ///     history behavior, so adding the parameter changes nothing for a
    ///     caller that does not opt in.
    ///
    /// Order matters: the *current* pin is checked first. A platform that
    /// stored the same key as both current and previous must still report
    /// `.trusted`, never `.revertedToPrevious`.
    public static func check(
        endpoint: KnownHostEndpoint,
        presented: SSHHostPublicKey,
        trusted: TrustedHostRecord?,
        previous: SSHHostPublicKey? = nil,
        comparisonHint: String? = nil
    ) -> KnownHostCheckResult {
        guard let trusted else {
            return .unknown(presented: presented, comparisonHint: comparisonHint)
        }
        guard trusted.key == presented else {
            let change = PendingHostKeyChange(
                endpoint: endpoint,
                trusted: trusted.key,
                presented: presented
            )
            if let previous, previous == presented {
                return .revertedToPrevious(change)
            }
            return .changed(change)
        }
        return .trusted(trusted)
    }

    public static func importRecord(
        _ imported: TrustedHostRecord,
        local: TrustedHostRecord?
    ) -> KnownHostImportResult {
        guard let local else { return .inserted(imported) }
        guard local.endpoint == imported.endpoint, local.key == imported.key else {
            return .conflict(local: local, imported: imported)
        }
        return .unchanged(local)
    }
}

public protocol KnownHostsRepository: Sendable {
    func record(for endpoint: KnownHostEndpoint) async throws -> TrustedHostRecord?
    func save(_ record: TrustedHostRecord) async throws
    func remove(endpoint: KnownHostEndpoint) async throws
}

public enum TrustPolicyError: Error, Equatable, Sendable {
    case invalidKey
    case invalidKnownHostsLine(Int)
    case unsupportedMarker(String)
    case lineTooLong(Int)
    /// The algorithm name written inside the key blob disagrees with the
    /// algorithm token in front of it. A key that lies about what it is never
    /// becomes a pin.
    case keyAlgorithmMismatch
}
