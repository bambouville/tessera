import Foundation
import XCTest
@testable import TesseraEnrollmentCore

final class EnrollmentMessageV1Tests: XCTestCase {
    func test_requestFramePreservesShippedCanonicalBytes() throws {
        let request = makeRequest()
        let frame = try EnrollmentFrameCodecV1.encode(.request(request))
        let payload = try XCTUnwrap(String(data: frame.dropFirst(4), encoding: .utf8))
        let expected = #"{"request":{"hostID":"33333333-3333-3333-3333-333333333333","hostName":"zeus","id":"22222222-2222-2222-2222-222222222222","publicKey":{"algorithm":"ssh-ed25519","blob":"AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f","displayName":"iPhone key","fingerprint":"SHA256:ZkAslGjFiUHdGf\/WUL8rQvkib4PTvQatUV0OUQSncCA","id":"11111111-1111-1111-1111-111111111111","protection":"software"},"requestingDeviceName":"iPhone"},"type":"request","v":1}"#
        XCTAssertEqual(payload, expected)
        XCTAssertEqual(frame.prefix(4), Data([0, 0, 1, 0xCB]))
    }

    func test_controlReceiptBytesAndIncrementalFraming() throws {
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let messages: [EnrollmentMessageV1] = [
            .installed(enrollmentID: id),
            .recorded(enrollmentID: id),
            .completed(enrollmentID: id),
        ]
        let combined = try messages.reduce(into: Data()) {
            $0.append(try EnrollmentFrameCodecV1.encode($1))
        }
        var decoder = EnrollmentFrameDecoderV1()
        XCTAssertEqual(try decoder.append(combined.prefix(3)), [])
        XCTAssertEqual(try decoder.append(combined.dropFirst(3)), messages)

        let installed = try EnrollmentFrameCodecV1.encode(messages[0]).dropFirst(4)
        XCTAssertEqual(
            String(decoding: installed, as: UTF8.self),
            "{\"enrollmentID\":\"22222222-2222-2222-2222-222222222222\",\"type\":\"installed\",\"v\":1}"
        )
    }

    func test_decoderRejectsVersionAndIllegalPayloadShapes() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                EnrollmentMessageV1.self,
                from: Data("{\"type\":\"installed\",\"v\":2,\"enrollmentID\":\"22222222-2222-2222-2222-222222222222\"}".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? EnrollmentMessageV1.CodingError, .unsupportedVersion(2))
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                EnrollmentMessageV1.self,
                from: Data("{\"type\":\"request\",\"v\":1}".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? EnrollmentMessageV1.CodingError, .missingRequest)
        }
    }

    func test_frameDecoderRejectsOversizedClaimBeforeBufferingPayload() {
        var decoder = EnrollmentFrameDecoderV1()
        XCTAssertThrowsError(try decoder.append(Data([0, 1, 0, 1]))) { error in
            XCTAssertEqual(error as? EnrollmentFrameError, .payloadTooLarge(65_537))
        }
    }

    func test_checkedInEnrollmentVectorsDecodeAndReencodeCanonically() throws {
        let directory = repositoryRoot()
            .appendingPathComponent("ProtocolVectors/enrollment/v1", isDirectory: true)
        for name in [
            "request", "installed", "recorded", "completed", "rejected",
            "cancelled", "failed-installation",
        ] {
            let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
            let message = try JSONDecoder().decode(EnrollmentMessageV1.self, from: data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(message), data.trimmingTrailingNewline())
        }
        let invalid = try Data(
            contentsOf: directory.appendingPathComponent("invalid-unsupported-version.json")
        )
        XCTAssertThrowsError(try JSONDecoder().decode(EnrollmentMessageV1.self, from: invalid)) {
            XCTAssertEqual($0 as? EnrollmentMessageV1.CodingError, .unsupportedVersion(2))
        }
    }

    private func makeRequest() -> EnrollmentRequestV1 {
        EnrollmentRequestV1(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            hostID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            hostName: "zeus",
            requestingDeviceName: "iPhone",
            publicKey: TestPublicKeys.ed25519V1()
        )
    }
}

func repositoryRoot(filePath: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return url
}

private extension Data {
    func trimmingTrailingNewline() -> Data {
        last == 0x0A ? Data(dropLast()) : self
    }
}

enum TestPublicKeys {
    static let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
    static let fingerprint = "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA"

    static func ed25519V1() -> EnrollmentPublicKeyV1 {
        EnrollmentPublicKeyV1(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            displayName: "iPhone key",
            algorithm: .ed25519,
            blob: blob,
            fingerprint: fingerprint,
            protection: .software
        )
    }
}
