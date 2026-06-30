import Foundation
import SwiftData

/// Metadata for a stored SSH key. The actual private key bytes
/// live in iOS Keychain — this model stores only the public
/// information needed for UI display and `authorized_keys` export.
@Model
final class StoredKey {
    @Attribute(.unique) var id: UUID
    var name: String
    var algorithm: KeyAlgorithm
    /// The full `authorized_keys` line: "ssh-ed25519 AAAA... name"
    var authorizedKeysLine: String
    var createdAt: Date
    /// UI-only toggle (§14.4): "require face id per use".
    /// Literal default is load-bearing for SwiftData lightweight migration —
    /// see `PersistedHost.transportRaw` for the rationale. Backend plumbing
    /// (Secure Enclave + LAContext) is deferred.
    var requiresBiometric: Bool = false
    /// True when the P-256 private key is backed by this device's
    /// Secure Enclave. Literal default required for SwiftData migration.
    var isSecureEnclave: Bool = false
    /// UI-only toggle (§14.4): "agent forwarding".
    /// Literal default required for migration. Backend plumbing through
    /// Citadel `SSHClient` is deferred.
    var agentForwarding: Bool = false

    init(
        id: UUID = UUID(),
        name: String = "",
        algorithm: KeyAlgorithm = .ed25519,
        authorizedKeysLine: String = "",
        createdAt: Date = Date(),
        requiresBiometric: Bool = false,
        agentForwarding: Bool = false
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.authorizedKeysLine = authorizedKeysLine
        self.createdAt = createdAt
        self.requiresBiometric = requiresBiometric
        self.agentForwarding = agentForwarding
    }
}

enum KeyAlgorithm: String, Codable, CaseIterable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case rsa = "ssh-rsa"

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        case .rsa: return "RSA"
        }
    }
}
