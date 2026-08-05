import XCTest
@testable import Tessera

final class EnrollmentMessagesTests: XCTestCase {
    func test_requestFrameRoundTripsWithExactPublicOnlyAllowlist() throws {
        let request = makeRequest()
        let frame = try EnrollmentFrameCodec.encode(.request(request))
        var decoder = EnrollmentFrameDecoder()

        let messages = try decoder.append(frame)

        XCTAssertEqual(messages, [.request(request)])
        let payload = frame.dropFirst(EnrollmentFrameCodec.headerBytes)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["v", "type", "request"])
        XCTAssertEqual(object["v"] as? Int, EnrollmentMessage.currentVersion)
        XCTAssertEqual(object["type"] as? String, "request")

        let requestObject = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(
            Set(requestObject.keys),
            ["id", "hostID", "hostName", "requestingDeviceName", "publicKey"]
        )
        let keyObject = try XCTUnwrap(requestObject["publicKey"] as? [String: Any])
        XCTAssertEqual(
            Set(keyObject.keys),
            ["id", "displayName", "algorithm", "blob", "fingerprint", "protection"]
        )

        let wire = String(decoding: payload, as: UTF8.self)
        for forbidden in [
            "private", "keychain", "storedKey", "credential", "password",
            "secureEnclaveHandle", "persistentRef"
        ] {
            XCTAssertFalse(wire.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func test_incrementalDecoderHandlesSplitHeaderPayloadAndCoalescedFrames() throws {
        let request = makeRequest()
        let first = try EnrollmentFrameCodec.encode(.request(request))
        let second = try EnrollmentFrameCodec.encode(.cancelled(enrollmentID: request.id))
        let joined = first + second
        var decoder = EnrollmentFrameDecoder()

        XCTAssertEqual(try decoder.append(joined.prefix(2)), [])
        XCTAssertEqual(try decoder.append(joined.dropFirst(2).prefix(11)), [])
        XCTAssertEqual(
            try decoder.append(joined.dropFirst(13)),
            [.request(request), .cancelled(enrollmentID: request.id)]
        )
    }

    func test_durableCompletionControlFramesRoundTrip() throws {
        let id = UUID()
        var decoder = EnrollmentFrameDecoder()
        let joined = try EnrollmentFrameCodec.encode(.installed(enrollmentID: id))
            + EnrollmentFrameCodec.encode(.recorded(enrollmentID: id))
            + EnrollmentFrameCodec.encode(.completed(enrollmentID: id))

        XCTAssertEqual(
            try decoder.append(joined),
            [
                .installed(enrollmentID: id),
                .recorded(enrollmentID: id),
                .completed(enrollmentID: id),
            ]
        )
    }

    func test_decoderRejectsOversizedLengthBeforeBufferingPayload() {
        let oversized = UInt32(EnrollmentFrameCodec.maximumPayloadBytes + 1).bigEndian
        var value = oversized
        let header = Data(bytes: &value, count: EnrollmentFrameCodec.headerBytes)
        var decoder = EnrollmentFrameDecoder()

        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(
                error as? EnrollmentFrameCodec.FrameError,
                .payloadTooLarge(EnrollmentFrameCodec.maximumPayloadBytes + 1)
            )
        }
    }

    func test_decoderRejectsFutureMessageVersion() throws {
        let payload = Data(
            "{\"v\":99,\"type\":\"cancelled\",\"enrollmentID\":\"00000000-0000-0000-0000-000000000001\"}".utf8
        )
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: EnrollmentFrameCodec.headerBytes)
        frame.append(payload)
        var decoder = EnrollmentFrameDecoder()

        XCTAssertThrowsError(try decoder.append(frame)) { error in
            XCTAssertEqual(
                error as? EnrollmentMessage.CodingError,
                .unsupportedVersion(99)
            )
        }
    }

    func test_publicKeyValidationRejectsNonCanonicalOrWhitespaceBearingBlob() {
        let invalid = EnrollmentPublicKey(
            id: UUID(),
            displayName: "device key",
            algorithm: .ed25519,
            blob: "not base64 with spaces",
            fingerprint: "SHA256:public",
            protection: .software
        )

        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? EnrollmentPublicKey.ValidationError, .invalidBlob)
        }
    }

    func test_displayMetadataRejectsControlAndBidiSpoofing() {
        let safe = makeRequest()
        XCTAssertNoThrow(try safe.validate())

        let newlineHost = EnrollmentRequest(
            hostID: safe.hostID,
            hostName: "staging\nproduction",
            requestingDeviceName: safe.requestingDeviceName,
            publicKey: safe.publicKey
        )
        XCTAssertThrowsError(try newlineHost.validate()) { error in
            XCTAssertEqual(
                error as? EnrollmentRequest.ValidationError,
                .unsafeDisplayMetadata
            )
        }

        let bidiDevice = EnrollmentRequest(
            hostID: safe.hostID,
            hostName: safe.hostName,
            requestingDeviceName: "iPad\u{202E}enohPi",
            publicKey: safe.publicKey
        )
        XCTAssertThrowsError(try bidiDevice.validate()) { error in
            XCTAssertEqual(
                error as? EnrollmentRequest.ValidationError,
                .unsafeDisplayMetadata
            )
        }
    }

    func test_publicKeyValidationBindsAlgorithmAndFingerprintToWireBlob() {
        let blob = makeSSHBlob(
            algorithm: .ed25519,
            keyBytes: Data(repeating: 0x42, count: 32)
        )
        let wrongAlgorithm = EnrollmentPublicKey(
            id: UUID(),
            displayName: "device key",
            algorithm: .secureEnclaveP256,
            blob: blob.base64EncodedString(),
            fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blob),
            protection: .secureEnclave
        )
        XCTAssertThrowsError(try wrongAlgorithm.validate()) { error in
            XCTAssertEqual(error as? EnrollmentPublicKey.ValidationError, .algorithmMismatch)
        }

        let wrongFingerprint = EnrollmentPublicKey(
            id: UUID(),
            displayName: "device key",
            algorithm: .ed25519,
            blob: blob.base64EncodedString(),
            fingerprint: "SHA256:not-the-key-fingerprint",
            protection: .software
        )
        XCTAssertThrowsError(try wrongFingerprint.validate()) { error in
            XCTAssertEqual(error as? EnrollmentPublicKey.ValidationError, .fingerprintMismatch)
        }

        let impossibleProtection = EnrollmentPublicKey(
            id: UUID(),
            displayName: "device key",
            algorithm: .ed25519,
            blob: blob.base64EncodedString(),
            fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blob),
            protection: .secureEnclave
        )
        XCTAssertThrowsError(try impossibleProtection.validate()) { error in
            XCTAssertEqual(error as? EnrollmentPublicKey.ValidationError, .protectionMismatch)
        }
    }

    func test_secureEnclaveP256PublicKeyUsesCanonicalSSHPointShape() throws {
        var point = Data([0x04])
        point.append(Data(repeating: 0x5A, count: 64))
        let blob = makeSSHBlob(
            algorithm: .secureEnclaveP256,
            keyBytes: point
        )
        let key = EnrollmentPublicKey(
            id: UUID(),
            displayName: "Secure Enclave key",
            algorithm: .secureEnclaveP256,
            blob: blob.base64EncodedString(),
            fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blob),
            protection: .secureEnclave
        )

        XCTAssertNoThrow(try key.validate())

        var compressedPoint = Data([0x02])
        compressedPoint.append(Data(repeating: 0x5A, count: 64))
        let malformedBlob = makeSSHBlob(
            algorithm: .secureEnclaveP256,
            keyBytes: compressedPoint
        )
        let malformed = EnrollmentPublicKey(
            id: UUID(),
            displayName: "Secure Enclave key",
            algorithm: .secureEnclaveP256,
            blob: malformedBlob.base64EncodedString(),
            fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: malformedBlob),
            protection: .secureEnclave
        )

        XCTAssertThrowsError(try malformed.validate()) { error in
            XCTAssertEqual(error as? EnrollmentPublicKey.ValidationError, .invalidBlob)
        }
    }

    func test_grantContainsInstallerReadyPublicLineOnly() throws {
        let request = makeRequest()
        try request.validate()

        let grant = EnrollmentGrantRequest(request: request)

        XCTAssertEqual(grant.enrollmentID, request.id)
        XCTAssertEqual(grant.hostID, request.hostID)
        XCTAssertEqual(grant.publicKey, request.publicKey)
        XCTAssertEqual(
            grant.authorizedKeysLine,
            "ssh-ed25519 \(request.publicKey.blob)"
        )
    }

    private func makeRequest() -> EnrollmentRequest {
        let blob = makeSSHBlob(
            algorithm: .ed25519,
            keyBytes: Data(repeating: 0x42, count: 32)
        )
        return EnrollmentRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            hostName: "helios",
            requestingDeviceName: "Dev One's iPhone",
            publicKey: EnrollmentPublicKey(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
                displayName: "id_ed25519",
                algorithm: .ed25519,
                blob: blob.base64EncodedString(),
                fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blob),
                protection: .software
            )
        )
    }

    private func makeSSHBlob(
        algorithm: EnrollmentPublicKeyAlgorithm,
        keyBytes: Data
    ) -> Data {
        let algorithmBytes = Data(algorithm.rawValue.utf8)
        var blob = Data()
        appendSSHString(algorithmBytes, to: &blob)
        switch algorithm {
        case .ed25519:
            appendSSHString(keyBytes, to: &blob)
        case .secureEnclaveP256:
            appendSSHString(Data("nistp256".utf8), to: &blob)
            appendSSHString(keyBytes, to: &blob)
        }
        return blob
    }

    private func appendSSHString(_ value: Data, to blob: inout Data) {
        var length = UInt32(value.count).bigEndian
        blob.append(Data(bytes: &length, count: 4))
        blob.append(value)
    }
}
