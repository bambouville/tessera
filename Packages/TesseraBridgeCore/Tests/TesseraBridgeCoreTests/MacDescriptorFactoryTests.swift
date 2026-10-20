import Foundation
import TesseraBridgeCore
import TesseraProtocolCore
import XCTest

final class MacDescriptorFactoryTests: XCTestCase {
    private let hostID = UUID(uuidString: "50BF00B8-5654-46E5-A900-A220492D7391")!

    func testMacEncodeRoundTripsThroughReleasedMobileDecoder() throws {
        let bytes = try MacDescriptorFactory.makePublicationBytes(
            from: configuration()
        )

        let mobileDecoded = try ContinuationActivityCodec.decode(bytes)

        XCTAssertEqual(mobileDecoded.schemaVersion, 1)
        XCTAssertEqual(mobileDecoded.hostID, hostID)
        XCTAssertEqual(mobileDecoded.connectionKey, "ssh:avery@averys-mac.local:22")
        XCTAssertEqual(mobileDecoded.transport, .ssh)
        XCTAssertEqual(mobileDecoded.launchMode, .pinnedTmux)
        XCTAssertEqual(mobileDecoded.tmuxSessionName, "tessera-mac-9f2c1a7e")
        XCTAssertEqual(mobileDecoded.via, [])
        XCTAssertEqual(
            mobileDecoded.hostKeyFingerprint,
            "SHA256:phase-zero-fingerprint"
        )
    }

    func testMacVectorIsStableAndSecretFree() throws {
        let bytes = try MacDescriptorFactory.makePublicationBytes(
            from: configuration()
        )
        let encoded = try XCTUnwrap(String(data: bytes, encoding: .utf8))

        XCTAssertEqual(
            encoded,
            #"{"address":"averys-mac.local","connectionKey":"ssh:avery@averys-mac.local:22","hostID":"50BF00B8-5654-46E5-A900-A220492D7391","hostKeyFP":"SHA256:phase-zero-fingerprint","launchMode":"pinnedTmux","name":"Avery’s Mac","port":22,"tmux":"tessera-mac-9f2c1a7e","transport":"ssh","user":"avery","v":1,"via":[]}"#
        )
        XCTAssertFalse(encoded.contains("password"))
        XCTAssertFalse(encoded.contains("private"))
        XCTAssertFalse(encoded.contains("workingDirectory"))
        XCTAssertLessThanOrEqual(bytes.count, ContinuationDescriptorV1.maximumHandoffBytes)
    }

    func testTrimsDisplayFieldsBeforeEncoding() throws {
        let descriptor = try MacDescriptorFactory.makeDescriptor(
            from: MacContinuationConfiguration(
                hostID: hostID,
                displayName: "  Mac  ",
                user: " avery ",
                address: " mac.local ",
                tmuxSessionName: " dev ",
                hostKeyFingerprint: "  SHA256:test  "
            )
        )

        XCTAssertEqual(descriptor.name, "Mac")
        XCTAssertEqual(descriptor.user, "avery")
        XCTAssertEqual(descriptor.address, "mac.local")
        XCTAssertEqual(descriptor.tmuxSessionName, "dev")
        XCTAssertEqual(descriptor.hostKeyFingerprint, "SHA256:test")
    }

    func testRejectsLoopbackWildcardAndUnsafeTmuxTargets() throws {
        for address in ["localhost", "localhost.", "127.0.0.1", "[::1]", "0.0.0.0", "::"] {
            XCTAssertThrowsError(
                try MacDescriptorFactory.makeDescriptor(
                    from: configuration(address: address)
                )
            ) { error in
                XCTAssertEqual(
                    error as? MacDescriptorFactoryError,
                    .nonRoutableAddress
                )
            }
        }

        XCTAssertThrowsError(
            try MacDescriptorFactory.makeDescriptor(
                from: configuration(tmuxSessionName: "dev; rm -rf")
            )
        ) { error in
            XCTAssertEqual(
                error as? MacDescriptorFactoryError,
                .invalidTmuxSessionName
            )
        }
    }

    func testMacOriginCannotRepresentMoshOrBastions() throws {
        let descriptor = try MacDescriptorFactory.makeDescriptor(from: configuration())
        XCTAssertEqual(descriptor.transport, .ssh)
        XCTAssertEqual(descriptor.via, [])
        XCTAssertEqual(descriptor.continuationAction, .continueSession)
    }

    private func configuration(
        address: String = "averys-mac.local",
        tmuxSessionName: String = "tessera-mac-9f2c1a7e"
    ) -> MacContinuationConfiguration {
        MacContinuationConfiguration(
            hostID: hostID,
            displayName: "Avery’s Mac",
            user: "avery",
            address: address,
            port: 22,
            tmuxSessionName: tmuxSessionName,
            hostKeyFingerprint: "SHA256:phase-zero-fingerprint"
        )
    }
}
