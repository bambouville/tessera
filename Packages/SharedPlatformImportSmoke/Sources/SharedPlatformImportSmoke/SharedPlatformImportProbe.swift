import Foundation
import TesseraBootstrapCore
import TesseraContinuityCore
import TesseraCoreABI
import TesseraCrossDeviceCore
import TesseraDomainCore
import TesseraEnrollmentCore
import TesseraInputCore
import TesseraPairingCore
import TesseraProtocolCore
import TesseraSessionCore
import TesseraTrustCore
import TmuxControlCore

/// A deliberately small downstream consumer that compiles using public shared
/// APIs only. It must remain free of Tessera's application target and Apple UI
/// adapters so macOS CI catches accidental dependency regressions.
public enum SharedPlatformImportProbe {
    public struct Result: Equatable, Sendable {
        public let appleHandoffAccepted: Bool
        public let appleEnrollmentAccepted: Bool
        public let publicKeyFingerprint: String
        public let tmuxIdentityQuery: String
        public let parsedTmuxMessageCount: Int
        public let abiInputByteCount: Int
        public let terminalKeyBytes: [UInt8]
        public let terminalMouseBytes: [UInt8]

        public init(
            appleHandoffAccepted: Bool,
            appleEnrollmentAccepted: Bool,
            publicKeyFingerprint: String,
            tmuxIdentityQuery: String,
            parsedTmuxMessageCount: Int,
            abiInputByteCount: Int,
            terminalKeyBytes: [UInt8],
            terminalMouseBytes: [UInt8]
        ) {
            self.appleHandoffAccepted = appleHandoffAccepted
            self.appleEnrollmentAccepted = appleEnrollmentAccepted
            self.publicKeyFingerprint = publicKeyFingerprint
            self.tmuxIdentityQuery = tmuxIdentityQuery
            self.parsedTmuxMessageCount = parsedTmuxMessageCount
            self.abiInputByteCount = abiInputByteCount
            self.terminalKeyBytes = terminalKeyBytes
            self.terminalMouseBytes = terminalMouseBytes
        }
    }

    public static func run() throws -> Result {
        // Compile-time branch contract: every concrete symbol named as a
        // stable Android/Mac prerequisite must be importable by a downstream
        // package without depending on Tessera's application target.
        _ = HostProfile.self
        _ = HostEndpoint.self
        _ = HostRoute.self
        _ = HostLaunchPolicy.self
        _ = LocalCredentialReference.self
        _ = ConnectionRequest.self
        _ = CredentialCapability.self
        _ = TrustedHostRecord.self
        _ = PortForwardRule.self
        _ = ContinuationDescriptorV1.self
        _ = PairingOfferV1.self
        _ = PairingHandshakeV1.self
        _ = PairingFrameV1.self
        _ = PairingStreamRecordV1.self
        _ = CrossDevicePairingRuntimeV1.self
        _ = ContinuationTransactionV1.self
        _ = BootstrapManifestV2.self
        _ = BootstrapTransactionV1.self
        _ = LegacyNearbyBootstrapV2.self
        _ = LegacyNearbyHandshakeHelloV2.self
        _ = LegacyNearbyHandshakeCommitmentV2.self
        _ = LegacyNearbyHandshakeV2.self
        _ = LegacyNearbyManifestTransferSessionV2.self
        _ = EnrollmentMessageV1.self
        _ = DevicePublicKeyDescriptorV2.self
        _ = SessionCommand.self
        _ = SessionEvent.self
        _ = SessionChallenge.self
        _ = SessionGeneration.self
        _ = TmuxSnapshot.self
        _ = GridAuthoritySnapshot.self
        _ = TmuxRuntimeEngine.self
        _ = TmuxFixedQuery.self
        _ = TerminalModifiers.self
        _ = TerminalKey.self
        _ = TerminalKeySequenceEncoder.self
        _ = TerminalMouseEvent.self
        _ = TerminalMouseSequenceEncoder.self
        _ = TerminalInputMode.self
        _ = TerminalInputReset.self
        _ = TerminalInputStateMachine.self

        let key = DevicePublicKeyDescriptorV2(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            displayName: "macOS import smoke",
            algorithm: .ed25519,
            sshBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            fingerprint: "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA",
            protectionClaim: .platformProtected
        )
        try key.validate()

        let sessionName = try TmuxSessionName(validating: "shared-smoke")
        let query = TmuxFixedQuery.displaySessionIdentity(
            .sessionName(sessionName)
        )
        var parser = TmuxControlParser()
        let messages = parser.feed("%session-changed $1 smoke\n".utf8)

        let input = Data(repeating: 0x41, count: 16 * 1024)
        let command = CoreABICommand(kind: .sendInput, bytes: input)
        let decoded = try CoreABICommand.decode(command.encoded())
        let keyBytes = TerminalKeySequenceEncoder.encode(
            .up,
            modifiers: TerminalModifiers(ctrl: true),
            mode: TerminalKeyMode(applicationCursorKeys: true)
        )
        let mouseBytes = TerminalMouseSequenceEncoder.encode(
            .wheel(
                .up,
                column: 42,
                row: 7,
                modifiers: .none
            ),
            using: .sgr
        )

        return Result(
            appleHandoffAccepted: ContinuationTransportBinding.appleAccountHandoff
                .allowsContinuity,
            appleEnrollmentAccepted: PeerBinding.appleAccountContinuationStream
                .allowsEnrollment,
            publicKeyFingerprint: key.fingerprint,
            tmuxIdentityQuery: query,
            parsedTmuxMessageCount: messages.count,
            abiInputByteCount: decoded.bytes?.count ?? 0,
            terminalKeyBytes: keyBytes,
            terminalMouseBytes: mouseBytes
        )
    }
}
