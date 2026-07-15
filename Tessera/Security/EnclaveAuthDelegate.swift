import Citadel
import Crypto
import CryptoKit
import NIOCore
import NIOSSH

public final class EnclaveAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    private var key: SecureEnclave.P256.Signing.PrivateKey?
    private var didOffer = false

    var retainsPrivateKey: Bool { key != nil }

    init(username: String, key: SecureEnclave.P256.Signing.PrivateKey) {
        self.username = username
        self.key = key
    }

    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !didOffer else {
            nextChallengePromise.fail(EnclaveAuthError.noMoreAuthenticationOffers)
            return
        }

        didOffer = true
        guard availableMethods.contains(.publicKey), let key else {
            self.key = nil
            nextChallengePromise.fail(EnclaveAuthError.publicKeyUnavailable)
            return
        }
        let privateKey = NIOSSHPrivateKey(secureEnclaveP256Key: key)
        // The NIOSSH offer owns the signing handle during authentication. The
        // delegate/client retained by Citadel is exhausted and credential-free.
        self.key = nil
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        )
        nextChallengePromise.succeed(offer)
    }

    public static func makeAuthMethod(
        username: String,
        key: SecureEnclave.P256.Signing.PrivateKey
    ) -> SSHAuthenticationMethod {
        .custom(EnclaveAuthDelegate(username: username, key: key))
    }
}

private enum EnclaveAuthError: Error {
    case noMoreAuthenticationOffers
    case publicKeyUnavailable
}

/// Citadel retains `SSHAuthenticationMethod` for the client's lifetime even
/// when reconnect is disabled. This delegate makes that retained object
/// harmless: the CryptoKit private key moves into one NIOSSH authentication
/// offer, and the delegate clears its reference before returning.
final class OneShotSoftwareKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
    @unchecked Sendable {
    enum PrivateKey {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
    }

    private let username: String
    private var key: PrivateKey?
    private var didOffer = false

    var retainsPrivateKey: Bool { key != nil }

    init(username: String, key: PrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !didOffer else {
            nextChallengePromise.fail(EnclaveAuthError.noMoreAuthenticationOffers)
            return
        }
        didOffer = true

        guard availableMethods.contains(.publicKey), let key else {
            self.key = nil
            nextChallengePromise.fail(EnclaveAuthError.publicKeyUnavailable)
            return
        }

        let privateKey: NIOSSHPrivateKey
        switch key {
        case .ed25519(let key):
            privateKey = NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key):
            privateKey = NIOSSHPrivateKey(p256Key: key)
        }
        self.key = nil

        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        ))
    }

    static func makeAuthMethod(username: String, key: PrivateKey) -> SSHAuthenticationMethod {
        .custom(OneShotSoftwareKeyAuthDelegate(username: username, key: key))
    }
}
