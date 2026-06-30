import Foundation
import SwiftData

/// Reusable auth bundle — one identity can be shared by many hosts.
/// Rotating a key or changing a username means editing one identity,
/// not twenty hosts.
@Model
final class Identity {
    @Attribute(.unique) var id: UUID
    var name: String
    var user: String
    var credentialMode: CredentialMode

    var hosts: [PersistedHost] = []

    init(
        id: UUID = UUID(),
        name: String = "",
        user: String = "",
        credentialMode: CredentialMode = .none
    ) {
        self.id = id
        self.name = name
        self.user = user
        self.credentialMode = credentialMode
    }
}

/// How an Identity authenticates. Secrets live in iOS Keychain,
/// never in SwiftData.
enum CredentialMode: Codable, Equatable {
    /// No auth configured.
    case none
    /// Password stored in Keychain keyed by identity.id.
    case password
    /// SSH key stored in Keychain (Phase 2). UUID is StoredKey.id.
    case key(UUID)
    /// Dev-only: raw 32-byte Ed25519 seed file in Documents/.
    case legacyDevKey(String)
}
