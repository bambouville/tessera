import AVFoundation
import Darwin
import Network
import XCTest
@testable import Tessera
import TesseraCore

@MainActor
final class PairingLocalTCPTransportTests: XCTestCase {
    func test_endpointFilterPreservesOrderDeduplicatesAndCapsAtOfferLimit() {
        let addresses = [
            PairingLocalInterfaceAddress(host: "127.0.0.1", family: AF_INET),
            PairingLocalInterfaceAddress(host: "192.168.1.8", family: AF_INET),
            PairingLocalInterfaceAddress(host: "192.168.1.8", family: AF_INET),
            PairingLocalInterfaceAddress(host: "0.0.0.0", family: AF_INET),
            PairingLocalInterfaceAddress(host: "fe80::1", family: AF_INET6),
            PairingLocalInterfaceAddress(host: "fd12::1", family: AF_INET6),
            PairingLocalInterfaceAddress(host: "ff02::1", family: AF_INET6),
        ] + (0..<10).map { PairingLocalInterfaceAddress(host: "10.0.0.\($0 + 1)", family: AF_INET) }

        let candidates = PairingLocalEndpointFilter.candidates(from: addresses, port: 4_321)
        XCTAssertEqual(candidates.count, PairingOfferV1.maximumEndpointCandidates)
        XCTAssertEqual(candidates.map(\.host), [
            "192.168.1.8", "fd12::1", "10.0.0.1", "10.0.0.2",
            "10.0.0.3", "10.0.0.4", "10.0.0.5", "10.0.0.6",
        ])
        XCTAssertTrue(candidates.allSatisfy { $0.port == 4_321 && $0.transport == .tcp })
    }

    func test_listenerPublishesInjectedCandidatesAndAcceptsPeer() async throws {
        let enumerator = PairingFixedEndpointEnumerator(
            candidates: [PairingEndpointCandidateV1(host: "127.0.0.1", port: 1)]
        )
        let listener = PairingLocalTCPListener(endpointEnumerator: enumerator)
        let offered = try await listener.start()
        guard let port = offered.first?.port else { return XCTFail("missing offered endpoint") }

        let first = try await PairingTCPRecordConnection.connect(
            to: [PairingEndpointCandidateV1(host: "127.0.0.1", port: port)]
        )
        let accepted = try await listener.acceptConnection()
        try await accepted.start()

        await first.cancel()
        await accepted.cancel()
        listener.cancel()
    }

    func test_loopbackRecordTransportHandlesCoalescingAndCancellation() async throws {
        let enumerator = PairingFixedEndpointEnumerator(
            candidates: [PairingEndpointCandidateV1(host: "127.0.0.1", port: 1)]
        )
        let listener = PairingLocalTCPListener(endpointEnumerator: enumerator)
        let offered = try await listener.start()
        guard let port = offered.first?.port else { return XCTFail("missing offered endpoint") }
        let client = try await PairingTCPRecordConnection.connect(
            to: [PairingEndpointCandidateV1(host: "127.0.0.1", port: port)]
        )
        let server = try await listener.acceptConnection()
        try await server.start()

        let first = try PairingStreamRecordV1(kind: .recipientCommitment, payload: Data([1, 2]))
        let second = try PairingStreamRecordV1(kind: .originHello, payload: Data([3, 4]))
        try await client.send(first)
        try await client.send(second)
        let receivedFirst = try await server.receiveRecord()
        let receivedSecond = try await server.receiveRecord()
        XCTAssertEqual(receivedFirst, first)
        XCTAssertEqual(receivedSecond, second)

        await client.cancel()
        do {
            _ = try await server.receiveRecord()
            XCTFail("cancelled peer must unblock a pending read")
        } catch {
            XCTAssertTrue(error is PairingLocalTCPTransportError)
        }
        await server.cancel()
        listener.cancel()
    }

    func test_idleConsentGapDoesNotExpireAnOpenPairingSocket() async throws {
        let listener = PairingLocalTCPListener(
            endpointEnumerator: PairingFixedEndpointEnumerator(
                candidates: [PairingEndpointCandidateV1(host: "127.0.0.1", port: 1)]
            )
        )
        let offered = try await listener.start()
        guard let port = offered.first?.port else { return XCTFail("missing offered endpoint") }
        let client = try await PairingTCPRecordConnection.connect(
            to: [PairingEndpointCandidateV1(host: "127.0.0.1", port: port)]
        )
        let server = try await listener.acceptConnection()
        try await server.start()

        // A human may spend minutes comparing SAS or approving import. The
        // socket must remain live; attempt expiry/cancellation owns that
        // lifetime, not a short per-read deadline.
        try await Task.sleep(for: .milliseconds(120))
        let record = try PairingStreamRecordV1(kind: .recipientCommitment, payload: Data([9]))
        try await client.send(record)
        let received = try await server.receiveRecord()
        XCTAssertEqual(received, record)

        await client.cancel()
        await server.cancel()
        listener.cancel()
    }

    func test_qrRendererAndManualScannerValidationRequireCanonicalText() throws {
        let text = try Self.makeCanonicalText()
        let image = try PairingQRCodeRenderer.image(forCanonicalText: text, side: 320)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(image.size.width, image.size.height)

        let model = PairingQRCodeScannerModel()
        var accepted: String?
        model.onCanonicalText = { accepted = $0 }
        XCTAssertTrue(model.submitManualText(text))
        XCTAssertEqual(accepted, text)
        XCTAssertFalse(model.submitManualText(text + "="))
        XCTAssertEqual(model.status, .invalidManualText)
    }

    private static func makeCanonicalText() throws -> String {
        let origin = try PairingOriginDriverV1(
            configuration: PairingOriginDriverConfigurationV1(
                purpose: .continueSession,
                expiresAt: PairingHandshakeV1.unixTimeNow() + 120,
                endpointCandidates: [PairingEndpointCandidateV1(host: "192.168.1.8", port: 4_321)],
                oneTimeOpticalSecret: Data(repeating: 7, count: 32)
            )
        )
        return try PairingQRTextCodecV1.encode(origin.offer)
    }
}

private struct PairingFixedEndpointEnumerator: PairingLocalEndpointEnumerating {
    let candidates: [PairingEndpointCandidateV1]

    func candidates(port: UInt16) -> [PairingEndpointCandidateV1] {
        candidates.map { PairingEndpointCandidateV1(host: $0.host, port: port) }
    }
}
