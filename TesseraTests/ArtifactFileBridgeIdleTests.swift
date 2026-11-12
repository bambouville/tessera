import Foundation
import PortForwarding
import XCTest
@testable import Tessera

@MainActor
final class ArtifactFileBridgeIdleTests: XCTestCase {
    func testIdleTimerDefersWhilePageForwardIsListeningOrActive() async {
        for state in [PortForwarder.State.listening, .active(connectionCount: 1)] {
            let bridge = FileBridge(host: Host(address: "unused.invalid", user: "test"),
                                    requireBiometric: false, isSecureEnclave: false)
            let manager = PortForwarderManager()
            let forwarder = PortForwarder(rule: .localForward(localPort: 5173, remotePort: 5173))
            forwarder.harnessForceState(state)
            manager.harnessInsert(forwarder)
            await bridge.harnessExpireIdleTimer(forwarding: manager)
            XCTAssertEqual(bridge.state, .connected)
            XCTAssertEqual(manager.runningCount, 1)
            await manager.detach()
            await bridge.harnessExpireIdleTimer(forwarding: manager)
            XCTAssertEqual(bridge.state, .idle)
            await bridge.disconnect()
        }
    }

    func testEphemeralPageForwardDefersIdleUntilReleased() async {
        let bridge = FileBridge(host: Host(address: "unused.invalid", user: "test"),
                                requireBiometric: false, isSecureEnclave: false)
        let manager = PortForwarderManager()
        let forwarder = PortForwarder(rule: .localForward(localPort: 5173, remotePort: 5173))
        forwarder.harnessForceState(.listening)
        manager.harnessInsert(forwarder, ephemeral: true)
        await bridge.harnessExpireIdleTimer(forwarding: manager)
        XCTAssertEqual(bridge.state, .connected)
        // A tab's forward is not a rule: the status chip and background task do not count it.
        XCTAssertEqual(manager.runningCount, 0)
        XCTAssertTrue(manager.hasLiveForwards)
        await manager.stopEphemeral(forwarder.id)
        await bridge.harnessExpireIdleTimer(forwarding: manager)
        XCTAssertEqual(bridge.state, .idle)
        await bridge.disconnect()
    }

    func testIdleTimerStillDisconnectsForStoppedOrFailedForwards() async {
        for state in [PortForwarder.State.idle, .error(reason: "closed")] {
            let bridge = FileBridge(host: Host(address: "unused.invalid", user: "test"),
                                    requireBiometric: false, isSecureEnclave: false)
            let manager = PortForwarderManager()
            let forwarder = PortForwarder(rule: .localForward(localPort: 5173, remotePort: 5173))
            forwarder.harnessForceState(state)
            manager.harnessInsert(forwarder)
            await bridge.harnessExpireIdleTimer(forwarding: manager)
            XCTAssertEqual(bridge.state, .idle)
            await bridge.disconnect()
        }
    }

    func testUnconnectedBridgeAttributesNeverConnects() async throws {
        let bridge = FileBridge(host: Host(address: "unused.invalid", user: "test"),
                                requireBiometric: false, isSecureEnclave: false)
        do { _ = try await bridge.attributes("/srv/file.txt"); XCTFail("offline stat") }
        catch FileBridgeError.notConnected { }
        XCTAssertEqual(bridge.state, .idle)
        XCTAssertNil(bridge.artifactForwarding)
    }

    func testDefaultAttributesKeepsExistingListingFakesCompatible() async throws {
        let expected = RemoteFileEntry(name: "file.txt", path: "/srv/file.txt", kind: .file,
                                       size: 7, modified: Date(timeIntervalSince1970: 2), permissions: 0o600)
        let bridge = MockFileBridge(tree: ["/srv": [expected]])
        try await bridge.connect()
        let entry = try await bridge.attributes("/srv/file.txt")
        XCTAssertEqual(entry, expected)
        do { _ = try await bridge.attributes("/srv/missing.txt"); XCTFail("missing stat") }
        catch FileBridgeError.remoteStatus(let code, _) { XCTAssertEqual(code, 2) }
        await bridge.disconnect()
        do { _ = try await bridge.attributes("/srv/file.txt"); XCTFail("offline stat") }
        catch FileBridgeError.notConnected { }
    }
}
