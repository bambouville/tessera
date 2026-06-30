import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// SSH-level auth resolution and host-key validation primitives,
/// lifted out of `SSHSession` so a future `MoshBootstrap` can reuse
/// the same credential resolution without owning a full SSH session.
///
/// Today only `SSHSession` calls `resolveSSHAuthMethod`; when the mosh
/// transport lands, its bootstrap step (which opens an SSH exec
/// channel to run `mosh-server new`) will resolve credentials the
/// same way.

enum AuthResolutionError: LocalizedError {
    case storedKeyNotFound(UUID)
    case biometricCancelled
    case biometricFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .storedKeyNotFound(let id):
            // The "edit host" action on the connection-failed overlay now
            // points the user at the identity picker, so the old trailing
            // "Edit the identity…" sentence is redundant.
            return "SSH key \(id.uuidString.prefix(8))… not found in Keychain."
        case .biometricCancelled:
            return "Face ID was cancelled - connection wasn't started."
        case .biometricFailed(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "Face ID authentication failed - connection wasn't started."
            }
            return "Face ID authentication failed - \(trimmed)"
        }
    }
}

/// Auth resolution priority:
///   1. StoredKey (Keychain) — from identity's .key(UUID) mode
///   2. Legacy dev key — raw 32-byte Ed25519 seed from Documents/
///   3. Password — from Keychain or transient entry
///
/// Fails closed: if a stored key is configured but can't be loaded,
/// throws instead of silently falling back to password.
func resolveSSHAuthMethod(
    for host: Host,
    requireBiometric: Bool,
    isSecureEnclave: Bool = false
) async throws -> SSHAuthenticationMethod {
    // 1. Keychain-stored SSH key (Phase 2 key management).
    if let keyID = host.storedKeyID {
        if requireBiometric {
            try await evaluateBiometricForKeyUse(hostID: host.id, username: host.user)
        }

        let algorithms: [KeyAlgorithm] = isSecureEnclave
            ? [.ecdsaP256]
            : [.ed25519, .ecdsaP256, .rsa]
        for algo in algorithms {
            if let method = await KeyStore.authMethod(
                forKeyID: keyID,
                algorithm: algo,
                username: host.user,
                isSecureEnclave: isSecureEnclave
            ) {
                return method
            }
        }
        // Key was configured but couldn't be loaded — fail closed.
        throw AuthResolutionError.storedKeyNotFound(keyID)
    }

    // 2. Legacy dev key file in Documents/.
    if let filename = host.privateKeyFilename,
       let rawKey = loadRawDevKey(filename: filename + ".raw"),
       rawKey.count == 32,
       let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
    {
        return .ed25519(username: host.user, privateKey: privateKey)
    }

    // 3. Password.
    return .passwordBased(username: host.user, password: host.password)
}

func describeSSHError(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }

    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
        return "\(nsError.localizedDescription) (\(nsError.code))"
    }
    return String(describing: error)
}

private func evaluateBiometricForKeyUse(hostID: UUID, username: String) async throws {
    let result = await BiometricSessionCache.shared.evaluate(
        hostID: hostID,
        reason: "unlock SSH key for \(username)"
    )

    switch result {
    case .authenticated:
        return
    case .userCancelled:
        throw AuthResolutionError.biometricCancelled
    case .unavailable(let reason), .failed(let reason):
        throw AuthResolutionError.biometricFailed(reason: reason)
    }
}

private func loadRawDevKey(filename: String) -> Data? {
    guard let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    ).first else { return nil }
    let url = docs.appendingPathComponent(filename)
    return try? Data(contentsOf: url)
}

// MARK: - Host key TOFU validator

struct HostKeyVerificationChallenge: Sendable {
    let endpoint: String
    let fingerprint: String
    let keyType: String
    let isChanged: Bool
    let oldFingerprint: String?
}

typealias HostKeyVerificationPrompt = @MainActor @Sendable (HostKeyVerificationChallenge) async -> Bool

/// Bridges Citadel/NIO SSH's promise-based host key validation to
/// Tessera's async TOFU store + SwiftUI verification sheet.
///
/// Called on the NIO event loop during SSH handshake. Must complete
/// the promise exactly once. For unknown/changed keys, dispatches
/// to @MainActor to post a `HostKeyVerificationRequest` on the
/// session, then suspends via `CheckedContinuation` until the UI
/// responds.
///
final class TesseraHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let endpoint: String
    let prompt: HostKeyVerificationPrompt?

    init(endpoint: String, prompt: HostKeyVerificationPrompt?) {
        self.endpoint = endpoint
        self.prompt = prompt
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let endpoint = self.endpoint
        let prompt = self.prompt

        Task {
            let result = await KnownHostsStore.shared.check(hostKey, for: endpoint)
            let keyType = String(
                String(openSSHPublicKey: hostKey).prefix(while: { $0 != " " })
            )

            switch result {
            case .trusted:
                DiagnosticLogStore.appendSSH("hostkey validation result=trusted keyType=\(keyType)")
                await KnownHostsStore.shared.touch(for: endpoint)
                validationCompletePromise.succeed(())

            case .unknown(let fingerprint, _):
                DiagnosticLogStore.appendSSH("hostkey validation result=unknown keyType=\(keyType) promptAvailable=\(prompt != nil)")
                let userAccepted = await promptUser(
                    prompt: prompt,
                    challenge: HostKeyVerificationChallenge(
                        endpoint: endpoint,
                        fingerprint: fingerprint,
                        keyType: keyType,
                        isChanged: false,
                        oldFingerprint: nil
                    )
                )
                if userAccepted {
                    DiagnosticLogStore.appendSSH("hostkey validation userResult=accepted status=unknown keyType=\(keyType)")
                    await KnownHostsStore.shared.trust(hostKey, for: endpoint)
                    validationCompletePromise.succeed(())
                } else {
                    DiagnosticLogStore.appendSSH("hostkey validation userResult=rejected status=unknown keyType=\(keyType)")
                    validationCompletePromise.fail(HostKeyRejectedError())
                }

            case .changed(let oldFP, let newFP, _):
                DiagnosticLogStore.appendSSH("hostkey validation result=changed keyType=\(keyType) promptAvailable=\(prompt != nil)")
                let userAccepted = await promptUser(
                    prompt: prompt,
                    challenge: HostKeyVerificationChallenge(
                        endpoint: endpoint,
                        fingerprint: newFP,
                        keyType: keyType,
                        isChanged: true,
                        oldFingerprint: oldFP
                    )
                )
                if userAccepted {
                    DiagnosticLogStore.appendSSH("hostkey validation userResult=accepted status=changed keyType=\(keyType)")
                    await KnownHostsStore.shared.trust(hostKey, for: endpoint)
                    validationCompletePromise.succeed(())
                } else {
                    DiagnosticLogStore.appendSSH("hostkey validation userResult=rejected status=changed keyType=\(keyType)")
                    validationCompletePromise.fail(HostKeyRejectedError())
                }
            }
        }
    }

    /// Post a verification request to the session's published property
    /// and suspend until the user taps Trust or Cancel.
    private func promptUser(
        prompt: HostKeyVerificationPrompt?,
        challenge: HostKeyVerificationChallenge
    ) async -> Bool {
        guard let prompt else { return false }
        return await prompt(challenge)
    }
}

struct HostKeyRejectedError: Error {}
