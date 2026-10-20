import Foundation
import TesseraPairingCore
import XCTest
@testable import TesseraEnrollmentCore

final class DevicePublicKeyDescriptorTests: XCTestCase {
    func test_v1AndV2ValidateSameSSHIdentityWithNeutralProtectionMapping() throws {
        let legacy = TestPublicKeys.ed25519V1()
        try legacy.validate()
        let v2 = DevicePublicKeyDescriptorV2(legacy: legacy)
        try v2.validate()

        XCTAssertEqual(v2.algorithm, .ed25519)
        XCTAssertEqual(v2.sshBlob, legacy.blob)
        XCTAssertEqual(v2.fingerprint, legacy.fingerprint)
        XCTAssertEqual(v2.protectionClaim, .softwareExportable)
        XCTAssertEqual(v2.authorizedKeysLine, legacy.authorizedKeysLine)
    }

    func test_v2CanonicalFieldsArePlatformNeutral() throws {
        let v2 = DevicePublicKeyDescriptorV2(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            displayName: "Android key",
            algorithm: .ed25519,
            sshBlob: TestPublicKeys.blob,
            fingerprint: TestPublicKeys.fingerprint,
            protectionClaim: .platformStrongHardware
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(v2), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"algorithm":"ssh-ed25519","displayName":"Android key","fingerprint":"SHA256:ZkAslGjFiUHdGf\/WUL8rQvkib4PTvQatUV0OUQSncCA","id":"11111111-1111-1111-1111-111111111111","protectionClaim":"platformStrongHardware","sshBlob":"AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"}"#
        )
        XCTAssertFalse(json.contains("secureEnclave"))
    }

    func test_validationRejectsFingerprintAlgorithmAndDisplaySpoofing() {
        let key = TestPublicKeys.ed25519V1()
        let wrongFingerprint = EnrollmentPublicKeyV1(
            id: key.id,
            displayName: key.displayName,
            algorithm: key.algorithm,
            blob: key.blob,
            fingerprint: "SHA256:wrong",
            protection: key.protection
        )
        XCTAssertThrowsError(try wrongFingerprint.validate()) { error in
            XCTAssertEqual(error as? DevicePublicKeyValidationError, .fingerprintMismatch)
        }

        let wrongAlgorithm = EnrollmentPublicKeyV1(
            id: key.id,
            displayName: key.displayName,
            algorithm: .ecdsaNistP256,
            blob: key.blob,
            fingerprint: key.fingerprint,
            protection: .secureEnclave
        )
        XCTAssertThrowsError(try wrongAlgorithm.validate()) { error in
            XCTAssertEqual(error as? DevicePublicKeyValidationError, .algorithmMismatch)
        }

        let unsafe = EnrollmentPublicKeyV1(
            id: key.id,
            displayName: "safe\u{202E}txt",
            algorithm: key.algorithm,
            blob: key.blob,
            fingerprint: key.fingerprint,
            protection: key.protection
        )
        XCTAssertThrowsError(try unsafe.validate()) { error in
            XCTAssertEqual(error as? DevicePublicKeyValidationError, .unsafeDisplayName)
        }
    }

    func test_peerBindingRequiresAppleIdentityOrValidatedPairingTransaction() {
        XCTAssertTrue(PeerBinding.appleAccountContinuationStream.allowsEnrollment)
        XCTAssertFalse(PeerBinding.unbound.allowsEnrollment)
    }

    func test_checkedInPublicKeyVectorsMatchBothSchemaEpochs() throws {
        let root = repositoryRoot().appendingPathComponent("ProtocolVectors/device-public-key")
        let v1Data = try Data(
            contentsOf: root.appendingPathComponent("v1/ed25519-software.json")
        )
        let v1 = try DevicePublicKeyDescriptorCodecV1.decode(v1Data)
        XCTAssertEqual(v1, TestPublicKeys.ed25519V1())

        let v2Data = try Data(
            contentsOf: root.appendingPathComponent("v2/ed25519-strong-hardware.json")
        )
        let v2 = try DevicePublicKeyDescriptorCodecV2.decode(v2Data)
        XCTAssertEqual(v2.protectionClaim, .platformStrongHardware)
        XCTAssertEqual(v2.sshBlob, v1.blob)
        XCTAssertEqual(v2.fingerprint, v1.fingerprint)

        let p256V1Data = try Data(
            contentsOf: root.appendingPathComponent("v1/p256-secure-enclave.json")
        )
        let p256V1 = try DevicePublicKeyDescriptorCodecV1.decode(p256V1Data)
        XCTAssertEqual(p256V1.algorithm, .ecdsaNistP256)
        XCTAssertEqual(p256V1.protection, .secureEnclave)
        let mapped = DevicePublicKeyDescriptorV2(legacy: p256V1)
        XCTAssertEqual(mapped.protectionClaim, .platformHardwareBacked)

        let p256V2Data = try Data(
            contentsOf: root.appendingPathComponent("v2/p256-hardware-backed.json")
        )
        let p256V2 = try DevicePublicKeyDescriptorCodecV2.decode(p256V2Data)
        XCTAssertEqual(p256V2, mapped)
    }

    func test_descriptorCodecsApplyLimitsBeforeDecode() {
        let oversized = Data(
            repeating: 0,
            count: DevicePublicKeyDescriptorCodecV2.maximumPayloadBytes + 1
        )
        XCTAssertThrowsError(try DevicePublicKeyDescriptorCodecV2.decode(oversized)) { error in
            XCTAssertEqual(
                error as? DevicePublicKeyDescriptorCodecError,
                .payloadTooLarge(
                    actual: oversized.count,
                    maximum: DevicePublicKeyDescriptorCodecV2.maximumPayloadBytes
                )
            )
        }
    }
}
