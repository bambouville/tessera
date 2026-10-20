import Crypto
import Foundation

/// Process-local replay ledger for received offers. Applications may inject a
/// longer-lived implementation boundary later, but all core entry points
/// require an atomic consume operation and use this shared ledger by default.
public final class PairingOfferConsumptionStoreV1: @unchecked Sendable {
    public static let shared = PairingOfferConsumptionStoreV1()

    private let lock = NSLock()
    private var consumedOfferExpirations: [UUID: Int64] = [:]

    public init() {}

    public func consume(_ offer: PairingOfferV1, at unixTime: Int64) throws {
        try offer.validateFresh(at: unixTime)
        lock.lock()
        defer { lock.unlock() }
        consumedOfferExpirations = consumedOfferExpirations.filter { $0.value > unixTime }
        guard consumedOfferExpirations[offer.offerID] == nil else {
            throw PairingError.offerAlreadyConsumed
        }
        consumedOfferExpirations[offer.offerID] = offer.expiresAt
    }

    public func hasConsumed(offerID: UUID, at unixTime: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        consumedOfferExpirations = consumedOfferExpirations.filter { $0.value > unixTime }
        return consumedOfferExpirations[offerID] != nil
    }
}

public struct PairingOriginDisclosureV1: Sendable {
    public let hello: PairingHelloV1
    public let encodedHello: Data

    fileprivate init(hello: PairingHelloV1, encodedHello: Data) {
        self.hello = hello
        self.encodedHello = encodedHello
    }
}

public struct PairingRecipientCompletionV1: @unchecked Sendable {
    public let hello: PairingHelloV1
    public let encodedHello: Data
    public let session: PairingSessionV1

    fileprivate init(hello: PairingHelloV1, encodedHello: Data, session: PairingSessionV1) {
        self.hello = hello
        self.encodedHello = encodedHello
        self.session = session
    }
}

/// An origin attempt can reveal its key only once and only after accepting a
/// valid recipient commitment. Invalid input is terminal, preventing oracle or
/// retry use of the same X25519 key.
public final class PairingOriginAttemptV1: @unchecked Sendable {
    public let offer: PairingOfferV1
    public let encodedOffer: Data

    fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var state: State = .waitingForCommitment

    private enum State {
        case waitingForCommitment
        case disclosed(
            commitment: PairingCommitmentV1,
            encodedCommitment: Data,
            hello: PairingHelloV1,
            encodedHello: Data
        )
        case consumed
    }

    fileprivate init(
        offer: PairingOfferV1,
        encodedOffer: Data,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        now: @escaping @Sendable () -> Int64
    ) {
        self.offer = offer
        self.encodedOffer = encodedOffer
        self.privateKey = privateKey
        self.now = now
    }

    public func reveal(after encodedCommitment: Data) throws -> PairingOriginDisclosureV1 {
        try reveal(after: encodedCommitment, currentTime: nil)
    }

    /// Internal deterministic clock override for conformance tests. Production
    /// callers always use the attempt's progressing clock.
    func reveal(
        after encodedCommitment: Data,
        currentTime: Int64?
    ) throws -> PairingOriginDisclosureV1 {
        lock.lock()
        guard case .waitingForCommitment = state else {
            lock.unlock()
            throw PairingError.attemptAlreadyConsumed
        }
        // Reserve this leg before parsing so concurrent or malformed retries
        // cannot reuse the origin key.
        state = .consumed
        lock.unlock()

        try offer.validateFresh(at: currentTime ?? now())
        let commitment = try PairingCommitmentV1.decode(encodedCommitment)
        try PairingHandshakeV1.validateCommitment(
            commitment,
            encodedCommitment: encodedCommitment,
            for: offer,
            encodedOffer: encodedOffer
        )
        let hello = PairingHelloV1(
            offerID: offer.offerID,
            purpose: offer.purpose,
            role: .origin,
            offerDigest: PairingHandshakeV1.digest(encodedOffer),
            ephemeralPublicKey: privateKey.publicKey.rawRepresentation,
            supportedPairingVersions: offer.supportedPairingVersions,
            supportedTransactionVersions: offer.supportedTransactionVersions,
            selectedPairingVersion: commitment.selectedPairingVersion,
            selectedTransactionVersion: commitment.selectedTransactionVersion
        )
        let encodedHello = try hello.encoded()

        lock.lock()
        state = .disclosed(
            commitment: commitment,
            encodedCommitment: encodedCommitment,
            hello: hello,
            encodedHello: encodedHello
        )
        lock.unlock()
        return PairingOriginDisclosureV1(hello: hello, encodedHello: encodedHello)
    }

    public func complete(with encodedRecipientHello: Data) throws -> PairingSessionV1 {
        try complete(with: encodedRecipientHello, currentTime: nil)
    }

    /// Internal deterministic clock override for conformance tests.
    func complete(
        with encodedRecipientHello: Data,
        currentTime: Int64?
    ) throws -> PairingSessionV1 {
        lock.lock()
        guard case .disclosed(
            let commitment,
            let encodedCommitment,
            let originHello,
            let encodedOriginHello
        ) = state else {
            lock.unlock()
            throw PairingError.commitmentRequired
        }
        state = .consumed
        lock.unlock()

        try offer.validateFresh(at: currentTime ?? now())
        let recipientHello = try PairingHelloV1.decode(encodedRecipientHello)
        try PairingHandshakeV1.validateHandshakeSet(
            offer: offer,
            encodedOffer: encodedOffer,
            commitment: commitment,
            encodedCommitment: encodedCommitment,
            originHello: originHello,
            encodedOriginHello: encodedOriginHello,
            recipientHello: recipientHello,
            encodedRecipientHello: encodedRecipientHello
        )
        return try PairingHandshakeV1.complete(
            localRole: .origin,
            privateKey: privateKey,
            peerHello: recipientHello,
            offer: offer,
            encodedOffer: encodedOffer,
            commitment: commitment,
            encodedCommitment: encodedCommitment,
            originHello: originHello,
            encodedOriginHello: encodedOriginHello,
            recipientHello: recipientHello,
            encodedRecipientHello: encodedRecipientHello,
            now: now
        )
    }
}

/// A recipient attempt publishes a commitment before it can accept the origin
/// hello. Completion consumes the attempt before validating input.
public final class PairingRecipientAttemptV1: @unchecked Sendable {
    public let offer: PairingOfferV1
    public let encodedOffer: Data
    public let commitment: PairingCommitmentV1
    public let encodedCommitment: Data

    fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let now: @Sendable () -> Int64
    private let recipientHello: PairingHelloV1
    private let encodedRecipientHello: Data
    private let lock = NSLock()
    private var consumed = false

    fileprivate init(
        offer: PairingOfferV1,
        encodedOffer: Data,
        commitment: PairingCommitmentV1,
        encodedCommitment: Data,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        recipientHello: PairingHelloV1,
        encodedRecipientHello: Data,
        now: @escaping @Sendable () -> Int64
    ) {
        self.offer = offer
        self.encodedOffer = encodedOffer
        self.commitment = commitment
        self.encodedCommitment = encodedCommitment
        self.privateKey = privateKey
        self.recipientHello = recipientHello
        self.encodedRecipientHello = encodedRecipientHello
        self.now = now
    }

    public func complete(with encodedOriginHello: Data) throws -> PairingRecipientCompletionV1 {
        try complete(with: encodedOriginHello, currentTime: nil)
    }

    /// Internal deterministic clock override for conformance tests.
    func complete(
        with encodedOriginHello: Data,
        currentTime: Int64?
    ) throws -> PairingRecipientCompletionV1 {
        lock.lock()
        guard !consumed else {
            lock.unlock()
            throw PairingError.attemptAlreadyConsumed
        }
        consumed = true
        lock.unlock()

        try offer.validateFresh(at: currentTime ?? now())
        let originHello = try PairingHelloV1.decode(encodedOriginHello)
        try PairingHandshakeV1.validateHandshakeSet(
            offer: offer,
            encodedOffer: encodedOffer,
            commitment: commitment,
            encodedCommitment: encodedCommitment,
            originHello: originHello,
            encodedOriginHello: encodedOriginHello,
            recipientHello: recipientHello,
            encodedRecipientHello: encodedRecipientHello
        )
        let session = try PairingHandshakeV1.complete(
            localRole: .recipient,
            privateKey: privateKey,
            peerHello: originHello,
            offer: offer,
            encodedOffer: encodedOffer,
            commitment: commitment,
            encodedCommitment: encodedCommitment,
            originHello: originHello,
            encodedOriginHello: encodedOriginHello,
            recipientHello: recipientHello,
            encodedRecipientHello: encodedRecipientHello,
            now: now
        )
        return PairingRecipientCompletionV1(
            hello: recipientHello,
            encodedHello: encodedRecipientHello,
            session: session
        )
    }
}

public enum PairingHandshakeV1 {
    public static let implementedPairingVersions = [PairingOfferV1.currentVersion]
    public static let defaultOpticalSecretByteCount = 32

    private static let originKeyCommitmentLabel = Data(
        "tessera/pairing/origin-key-commitment/v1".utf8
    )
    private static let recipientCommitmentLabel = Data(
        "tessera/pairing/recipient-hello-commitment/v1".utf8
    )
    private static let transcriptLabel = Data("tessera/pairing/transcript/v1".utf8)
    private static let opticalBindingLabel = Data("tessera/pairing/optical-binding/v1".utf8)

    public static func makeOpticalSecret(byteCount: Int = defaultOpticalSecretByteCount) throws -> Data {
        guard (PairingOfferV1.minimumOpticalSecretBytes...PairingOfferV1.maximumOpticalSecretBytes)
            .contains(byteCount) else {
            throw PairingError.invalidOpticalSecret
        }
        var generator = SystemRandomNumberGenerator()
        return Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func beginOrigin(
        purpose: PairingPurpose,
        offerID: UUID = UUID(),
        currentTime: Int64 = unixTimeNow(),
        expiresAt: Int64,
        endpointCandidates: [PairingEndpointCandidateV1],
        oneTimeOpticalSecret: Data?,
        supportedTransactionVersions: [Int],
        optionalPayloadDigest: Data? = nil
    ) throws -> PairingOriginAttemptV1 {
        try makeOriginAttempt(
            purpose: purpose,
            offerID: offerID,
            currentTime: currentTime,
            expiresAt: expiresAt,
            endpointCandidates: endpointCandidates,
            oneTimeOpticalSecret: oneTimeOpticalSecret,
            supportedTransactionVersions: supportedTransactionVersions,
            optionalPayloadDigest: optionalPayloadDigest,
            privateKey: Curve25519.KeyAgreement.PrivateKey()
        )
    }

    #if DEBUG
    /// Deterministic construction for tests and checked-in conformance vectors.
    /// Production builds expose only the fresh-entropy overload above.
    public static func beginOrigin(
        purpose: PairingPurpose,
        offerID: UUID,
        currentTime: Int64,
        expiresAt: Int64,
        endpointCandidates: [PairingEndpointCandidateV1],
        oneTimeOpticalSecret: Data?,
        supportedTransactionVersions: [Int],
        optionalPayloadDigest: Data? = nil,
        deterministicPrivateKey: Data
    ) throws -> PairingOriginAttemptV1 {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: deterministicPrivateKey
            )
        } catch {
            throw PairingError.invalidPrivateKey
        }
        return try makeOriginAttempt(
            purpose: purpose,
            offerID: offerID,
            currentTime: currentTime,
            expiresAt: expiresAt,
            endpointCandidates: endpointCandidates,
            oneTimeOpticalSecret: oneTimeOpticalSecret,
            supportedTransactionVersions: supportedTransactionVersions,
            optionalPayloadDigest: optionalPayloadDigest,
            privateKey: privateKey
        )
    }
    #endif

    public static func beginRecipient(
        encodedOffer: Data,
        currentTime: Int64 = unixTimeNow(),
        supportedTransactionVersions: [Int],
        consumptionStore: PairingOfferConsumptionStoreV1 = .shared
    ) throws -> PairingRecipientAttemptV1 {
        try makeRecipientAttempt(
            encodedOffer: encodedOffer,
            currentTime: currentTime,
            supportedTransactionVersions: supportedTransactionVersions,
            consumptionStore: consumptionStore,
            privateKey: Curve25519.KeyAgreement.PrivateKey()
        )
    }

    #if DEBUG
    public static func beginRecipient(
        encodedOffer: Data,
        currentTime: Int64,
        supportedTransactionVersions: [Int],
        consumptionStore: PairingOfferConsumptionStoreV1,
        deterministicPrivateKey: Data
    ) throws -> PairingRecipientAttemptV1 {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: deterministicPrivateKey
            )
        } catch {
            throw PairingError.invalidPrivateKey
        }
        return try makeRecipientAttempt(
            encodedOffer: encodedOffer,
            currentTime: currentTime,
            supportedTransactionVersions: supportedTransactionVersions,
            consumptionStore: consumptionStore,
            privateKey: privateKey
        )
    }
    #endif

    public static func makeTranscript(
        offerData: Data,
        commitmentData: Data,
        originHelloData: Data,
        recipientHelloData: Data
    ) throws -> Data {
        let offer = try PairingOfferV1.decode(offerData)
        let commitment = try PairingCommitmentV1.decode(commitmentData)
        let originHello = try PairingHelloV1.decode(originHelloData)
        let recipientHello = try PairingHelloV1.decode(recipientHelloData)
        try validateHandshakeSet(
            offer: offer,
            encodedOffer: offerData,
            commitment: commitment,
            encodedCommitment: commitmentData,
            originHello: originHello,
            encodedOriginHello: originHelloData,
            recipientHello: recipientHello,
            encodedRecipientHello: recipientHelloData
        )
        return try buildTranscript(
            offer: offer,
            encodedOffer: offerData,
            encodedCommitment: commitmentData,
            encodedOriginHello: originHelloData,
            encodedRecipientHello: recipientHelloData
        )
    }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func validateCommitment(
        _ commitment: PairingCommitmentV1,
        encodedCommitment: Data,
        for offer: PairingOfferV1,
        encodedOffer: Data
    ) throws {
        try commitment.validate()
        guard commitment.offerID == offer.offerID,
              commitment.purpose == offer.purpose,
              commitment.offerDigest == digest(encodedOffer) else {
            throw PairingError.commitmentMismatch
        }
        guard commitment.selectedPairingVersion == selectedVersion(
            offer.supportedPairingVersions,
            commitment.supportedPairingVersions
        ) else {
            throw PairingError.downgradeDetected
        }
        guard commitment.selectedPairingVersion == PairingOfferV1.currentVersion else {
            throw PairingError.unsupportedPairingVersion(
                commitment.selectedPairingVersion
            )
        }
        guard commitment.selectedTransactionVersion == selectedVersion(
            offer.supportedTransactionVersions,
            commitment.supportedTransactionVersions
        ) else {
            throw PairingError.downgradeDetected
        }
        _ = encodedCommitment // Explicitly retained and transcript-bound later.
    }

    static func validateHandshakeSet(
        offer: PairingOfferV1,
        encodedOffer: Data,
        commitment: PairingCommitmentV1,
        encodedCommitment: Data,
        originHello: PairingHelloV1,
        encodedOriginHello: Data,
        recipientHello: PairingHelloV1,
        encodedRecipientHello: Data
    ) throws {
        try validateCommitment(
            commitment,
            encodedCommitment: encodedCommitment,
            for: offer,
            encodedOffer: encodedOffer
        )
        guard originHello.role == .origin else {
            throw PairingError.unexpectedRole(expected: .origin, actual: originHello.role)
        }
        guard recipientHello.role == .recipient else {
            throw PairingError.unexpectedRole(expected: .recipient, actual: recipientHello.role)
        }
        for hello in [originHello, recipientHello] {
            guard hello.offerID == offer.offerID,
                  hello.purpose == offer.purpose,
                  hello.offerDigest == digest(encodedOffer),
                  hello.selectedPairingVersion == commitment.selectedPairingVersion,
                  hello.selectedTransactionVersion == commitment.selectedTransactionVersion else {
                throw PairingError.invalidHello
            }
        }
        guard originHello.supportedPairingVersions == offer.supportedPairingVersions,
              originHello.supportedTransactionVersions == offer.supportedTransactionVersions,
              recipientHello.supportedPairingVersions == commitment.supportedPairingVersions,
              recipientHello.supportedTransactionVersions == commitment.supportedTransactionVersions else {
            throw PairingError.downgradeDetected
        }
        guard originHello.ephemeralPublicKey != recipientHello.ephemeralPublicKey else {
            throw PairingError.reflectedPublicKey
        }
        guard try recipientHelloCommitment(
            encodedOffer: encodedOffer,
            encodedRecipientHello: encodedRecipientHello
        ) == commitment.helloDigest else {
            throw PairingError.commitmentMismatch
        }
        guard try originKeyCommitment(
            offerID: offer.offerID,
            purpose: offer.purpose,
            publicKey: originHello.ephemeralPublicKey
        ) == offer.originEphemeralKeyOrCommitment.value else {
            throw PairingError.originKeyCommitmentMismatch
        }
        // These exact bytes are included rather than re-encoded projections.
        // Strict decoders above ensure each is canonical before binding.
        _ = encodedOriginHello
    }

    static func complete(
        localRole: PairingRoleV1,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerHello: PairingHelloV1,
        offer: PairingOfferV1,
        encodedOffer: Data,
        commitment: PairingCommitmentV1,
        encodedCommitment: Data,
        originHello: PairingHelloV1,
        encodedOriginHello: Data,
        recipientHello: PairingHelloV1,
        encodedRecipientHello: Data,
        now: @escaping @Sendable () -> Int64
    ) throws -> PairingSessionV1 {
        let peerPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerHello.ephemeralPublicKey
            )
        } catch {
            throw PairingError.invalidPublicKey
        }
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        } catch {
            throw PairingError.invalidPublicKey
        }
        let transcript = try buildTranscript(
            offer: offer,
            encodedOffer: encodedOffer,
            encodedCommitment: encodedCommitment,
            encodedOriginHello: encodedOriginHello,
            encodedRecipientHello: encodedRecipientHello
        )
        let transcriptHash = digest(transcript)
        let material = deriveMaterial(sharedSecret: sharedSecret, transcriptHash: transcriptHash)
        return try PairingSessionV1(
            localRole: localRole,
            purpose: offer.purpose,
            offerID: offer.offerID,
            selectedPairingVersion: commitment.selectedPairingVersion,
            selectedTransactionVersion: commitment.selectedTransactionVersion,
            transcript: transcript,
            transcriptHash: transcriptHash,
            material: material,
            expiresAt: offer.expiresAt,
            now: now
        )
    }

    private static func makeOriginAttempt(
        purpose: PairingPurpose,
        offerID: UUID,
        currentTime: Int64,
        expiresAt: Int64,
        endpointCandidates: [PairingEndpointCandidateV1],
        oneTimeOpticalSecret: Data?,
        supportedTransactionVersions: [Int],
        optionalPayloadDigest: Data?,
        privateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> PairingOriginAttemptV1 {
        guard PairingWireCodecV1.isCanonicalVersionList(
            supportedTransactionVersions,
            maximumCount: PairingOfferV1.maximumVersionCount
        ) else {
            throw PairingError.invalidOffer(field: "supportedTransactionVersions")
        }
        let commitment = try originKeyCommitment(
            offerID: offerID,
            purpose: purpose,
            publicKey: privateKey.publicKey.rawRepresentation
        )
        let offer = PairingOfferV1(
            offerID: offerID,
            purpose: purpose,
            expiresAt: expiresAt,
            originEphemeralKeyOrCommitment: PairingOriginKeyMaterialV1(value: commitment),
            endpointCandidates: endpointCandidates,
            oneTimeOpticalSecret: oneTimeOpticalSecret,
            supportedPairingVersions: implementedPairingVersions,
            supportedTransactionVersions: supportedTransactionVersions,
            optionalPayloadDigest: optionalPayloadDigest
        )
        try offer.validateFresh(at: currentTime)
        let transitionClock = progressingClock(from: currentTime)
        return try PairingOriginAttemptV1(
            offer: offer,
            encodedOffer: offer.encoded(),
            privateKey: privateKey,
            now: transitionClock
        )
    }

    private static func makeRecipientAttempt(
        encodedOffer: Data,
        currentTime: Int64,
        supportedTransactionVersions: [Int],
        consumptionStore: PairingOfferConsumptionStoreV1,
        privateKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> PairingRecipientAttemptV1 {
        guard PairingWireCodecV1.isCanonicalVersionList(
            supportedTransactionVersions,
            maximumCount: PairingOfferV1.maximumVersionCount
        ) else {
            throw PairingError.invalidHello
        }
        let offer = try PairingOfferV1.decode(encodedOffer)
        try consumptionStore.consume(offer, at: currentTime)
        let transitionClock = progressingClock(from: currentTime)
        guard let selectedPairingVersion = selectedVersion(
            offer.supportedPairingVersions,
            implementedPairingVersions
        ) else {
            throw PairingError.noCommonPairingVersion
        }
        guard selectedPairingVersion == PairingOfferV1.currentVersion else {
            throw PairingError.unsupportedPairingVersion(selectedPairingVersion)
        }
        guard let selectedTransactionVersion = selectedVersion(
            offer.supportedTransactionVersions,
            supportedTransactionVersions
        ) else {
            throw PairingError.noCommonTransactionVersion
        }
        let offerDigest = digest(encodedOffer)
        let hello = PairingHelloV1(
            offerID: offer.offerID,
            purpose: offer.purpose,
            role: .recipient,
            offerDigest: offerDigest,
            ephemeralPublicKey: privateKey.publicKey.rawRepresentation,
            supportedPairingVersions: implementedPairingVersions,
            supportedTransactionVersions: supportedTransactionVersions,
            selectedPairingVersion: selectedPairingVersion,
            selectedTransactionVersion: selectedTransactionVersion
        )
        let encodedHello = try hello.encoded()
        let commitment = PairingCommitmentV1(
            offerID: offer.offerID,
            purpose: offer.purpose,
            offerDigest: offerDigest,
            supportedPairingVersions: implementedPairingVersions,
            supportedTransactionVersions: supportedTransactionVersions,
            selectedPairingVersion: selectedPairingVersion,
            selectedTransactionVersion: selectedTransactionVersion,
            helloDigest: try recipientHelloCommitment(
                encodedOffer: encodedOffer,
                encodedRecipientHello: encodedHello
            )
        )
        return try PairingRecipientAttemptV1(
            offer: offer,
            encodedOffer: encodedOffer,
            commitment: commitment,
            encodedCommitment: commitment.encoded(),
            privateKey: privateKey,
            recipientHello: hello,
            encodedRecipientHello: encodedHello,
            now: transitionClock
        )
    }

    private static func selectedVersion(_ lhs: [Int], _ rhs: [Int]) -> Int? {
        Set(lhs).intersection(rhs).max()
    }

    private static func originKeyCommitment(
        offerID: UUID,
        purpose: PairingPurpose,
        publicKey: Data
    ) throws -> Data {
        guard publicKey.count == 32 else { throw PairingError.invalidPublicKey }
        var input = Data()
        try input.pairingAppendLengthPrefixed(originKeyCommitmentLabel)
        try input.pairingAppendLengthPrefixed(
            Data(offerID.uuidString.lowercased().utf8)
        )
        try input.pairingAppendLengthPrefixed(Data(purpose.rawValue.utf8))
        try input.pairingAppendLengthPrefixed(publicKey)
        return digest(input)
    }

    private static func recipientHelloCommitment(
        encodedOffer: Data,
        encodedRecipientHello: Data
    ) throws -> Data {
        var input = Data()
        try input.pairingAppendLengthPrefixed(recipientCommitmentLabel)
        try input.pairingAppendLengthPrefixed(digest(encodedOffer))
        try input.pairingAppendLengthPrefixed(encodedRecipientHello)
        return digest(input)
    }

    private static func buildTranscript(
        offer: PairingOfferV1,
        encodedOffer: Data,
        encodedCommitment: Data,
        encodedOriginHello: Data,
        encodedRecipientHello: Data
    ) throws -> Data {
        var transcript = Data()
        try transcript.pairingAppendLengthPrefixed(transcriptLabel)
        transcript.pairingAppendUInt16(UInt16(PairingOfferV1.currentVersion))
        try transcript.pairingAppendLengthPrefixed(encodedOffer)
        try transcript.pairingAppendLengthPrefixed(encodedCommitment)
        try transcript.pairingAppendLengthPrefixed(encodedOriginHello)
        try transcript.pairingAppendLengthPrefixed(encodedRecipientHello)

        let proof: Data
        if let secret = offer.oneTimeOpticalSecret {
            var proofInput = Data()
            try proofInput.pairingAppendLengthPrefixed(opticalBindingLabel)
            try proofInput.pairingAppendLengthPrefixed(transcript)
            proof = Data(HMAC<SHA256>.authenticationCode(
                for: proofInput,
                using: SymmetricKey(data: secret)
            ))
        } else {
            proof = Data()
        }
        try transcript.pairingAppendLengthPrefixed(proof)
        return transcript
    }

    private static func deriveMaterial(
        sharedSecret: SharedSecret,
        transcriptHash: Data
    ) -> PairingDerivedMaterialV1 {
        func bytes(_ label: String, count: Int) -> Data {
            let key = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: transcriptHash,
                sharedInfo: Data("tessera/pairing/v1/\(label)".utf8),
                outputByteCount: count
            )
            return key.withUnsafeBytes { Data($0) }
        }
        return PairingDerivedMaterialV1(
            originToRecipientKey: bytes("key/origin-to-recipient", count: 32),
            recipientToOriginKey: bytes("key/recipient-to-origin", count: 32),
            originToRecipientNonce: bytes("nonce/origin-to-recipient", count: 12),
            recipientToOriginNonce: bytes("nonce/recipient-to-origin", count: 12),
            sasBytes: bytes("sas", count: 8)
        )
    }

    public static func unixTimeNow() -> Int64 {
        Int64(Date().timeIntervalSince1970.rounded(.down))
    }

    /// Keeps injected/vector timestamps deterministic while ensuring production
    /// attempts continue to age after construction.
    private static func progressingClock(from baseTime: Int64) -> @Sendable () -> Int64 {
        let wallTimeAtCreation = unixTimeNow()
        return {
            let elapsed = max(0, unixTimeNow() - wallTimeAtCreation)
            return baseTime.addingReportingOverflow(elapsed).overflow
                ? Int64.max
                : baseTime + elapsed
        }
    }
}

struct PairingDerivedMaterialV1: Equatable {
    let originToRecipientKey: Data
    let recipientToOriginKey: Data
    let originToRecipientNonce: Data
    let recipientToOriginNonce: Data
    let sasBytes: Data
}
