import Citadel
import Crypto
import CryptoKit
import NIOCore
import NIOSSH

public final class EnclaveAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: SecureEnclave.P256.Signing.PrivateKey
    private var didOffer = false

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
        let privateKey = NIOSSHPrivateKey(secureEnclaveP256Key: key)
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
}
