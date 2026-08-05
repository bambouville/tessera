import Network
import XCTest
@testable import Tessera

@MainActor
final class BootstrapNearbyTransferServiceTests: XCTestCase {
    func test_browserAndListenerLifecycleExistOnlyWhileStarted() throws {
        let backend = BootstrapFakeNetworking()
        let service = NearbyTransferService(networking: backend)

        XCTAssertEqual(service.mode, .stopped)
        XCTAssertEqual(backend.startBrowsingCount, 0)
        try service.startBrowsing()
        XCTAssertEqual(service.mode, .browsing)
        XCTAssertEqual(backend.startBrowsingCount, 1)
        XCTAssertThrowsError(try service.startOffering(displayName: "ignored")) { error in
            XCTAssertEqual(error as? NearbyTransferServiceError, .alreadyStarted)
        }
        service.stop()
        XCTAssertEqual(service.mode, .stopped)
        XCTAssertEqual(backend.stopCount, 1)

        try service.startOffering(displayName: "Dev One's iPad")
        XCTAssertEqual(service.mode, .offering)
        XCTAssertEqual(backend.startOfferingCount, 1)
        service.stop()
        XCTAssertEqual(backend.stopCount, 2)
    }

    func test_discoveryDisplayNameIsNeverUsedToConnect() throws {
        let backend = BootstrapFakeNetworking()
        let service = NearbyTransferService(networking: backend)
        try service.startBrowsing()
        let peer = NearbyDiscoveredPeer(id: "opaque-endpoint-7", displayName: "untrusted iPad name")
        backend.emitPeers([peer])

        XCTAssertEqual(service.discoveredPeers, [peer])
        _ = try service.connect(to: peer)
        XCTAssertEqual(backend.lastConnectedPeerID, "opaque-endpoint-7")
        XCTAssertNotEqual(backend.lastConnectedPeerID, peer.displayName)
    }

    func test_cancelledBrowserCallbacksCannotMutateRestartedRun() throws {
        let backend = BootstrapFakeNetworking()
        let service = NearbyTransferService(networking: backend)
        var failures: [NearbyTransferServiceError] = []
        service.onEvent = { event in
            if case .failed(let error) = event {
                failures.append(error)
            }
        }

        try service.startBrowsing()
        service.stop()
        try service.startBrowsing()

        let stale = NearbyDiscoveredPeer(id: "stale", displayName: "Old browser")
        backend.emitPeers(fromRun: 0, [stale])
        backend.emitFailure(fromRun: 0, .network("cancelled browser failed"))
        XCTAssertEqual(service.discoveredPeers, [])
        XCTAssertEqual(failures, [])

        let current = NearbyDiscoveredPeer(id: "current", displayName: "Current browser")
        backend.emitPeers(fromRun: 1, [current])
        XCTAssertEqual(service.discoveredPeers, [current])
    }

    func test_compatibilityAdvertisementTXTRoundTripAndRangeLogic() throws {
        let local = NearbyBootstrapProtocol.supportedVersions

        let parsed = NearbyCompatibilityAdvertisement(
            txtRecord: NearbyCompatibilityAdvertisement.current.txtRecord
        )
        XCTAssertEqual(parsed?.supportedVersions, local)
        XCTAssertEqual(parsed?.compatibility(withLocal: local), .compatible)

        func verdict(_ value: String) -> NearbyPeerCompatibility? {
            NearbyCompatibilityAdvertisement(txtRecord: NWTXTRecord(["v": value]))?
                .compatibility(withLocal: local)
        }
        XCTAssertEqual(verdict("3"), .localRequiresUpdate)
        XCTAssertEqual(verdict("1"), .peerRequiresUpdate)
        XCTAssertEqual(verdict("2,3"), .compatible)
        XCTAssertEqual(verdict("1, 2"), .compatible)

        XCTAssertNil(NearbyCompatibilityAdvertisement(txtRecord: NWTXTRecord()))
        XCTAssertNil(NearbyCompatibilityAdvertisement(txtRecord: NWTXTRecord(["other": "2"])))
        XCTAssertNil(NearbyCompatibilityAdvertisement(txtRecord: NWTXTRecord(["v": "abc"])))
        XCTAssertNil(
            NearbyCompatibilityAdvertisement(
                txtRecord: NWTXTRecord(["v": "1,2,3,4,5,6,7,8,9"])
            ),
            "version lists above the cap are rejected, mapping to .unknown"
        )
    }

    func test_discoveredPeerDefaultsToUnknownCompatibility() {
        let peer = NearbyDiscoveredPeer(id: "legacy", displayName: "Pre-TXT build")
        XCTAssertEqual(peer.compatibility, .unknown)
        XCTAssertFalse(NearbyPeerCompatibility.unknown.indicatesVersionMismatch)
        XCTAssertFalse(NearbyPeerCompatibility.compatible.indicatesVersionMismatch)
        XCTAssertTrue(NearbyPeerCompatibility.peerRequiresUpdate.indicatesVersionMismatch)
        XCTAssertTrue(NearbyPeerCompatibility.localRequiresUpdate.indicatesVersionMismatch)
    }

    func test_loopbackTransportRoundTripsAndEnforcesCallerSizeLimit() async throws {
        let (first, second) = NearbyLoopbackConnection.makePair()
        try await first.start()
        try await second.start()

        let payload = Data("bootstrap-frame".utf8)
        try await first.send(payload)
        let received = try await second.receive(maximumSize: 128)
        XCTAssertEqual(received, payload)

        try await first.send(Data(repeating: 0xAA, count: 129))
        do {
            _ = try await second.receive(maximumSize: 128)
            XCTFail("expected size rejection")
        } catch {
            XCTAssertEqual(error as? NearbyTransferServiceError, .invalidFrameLength(129))
        }

        await first.cancel()
        await second.cancel()
    }
}

@MainActor
private final class BootstrapFakeNetworking: NearbyTransferNetworking {
    var startBrowsingCount = 0
    var startOfferingCount = 0
    var stopCount = 0
    var lastConnectedPeerID: String?

    private var peersChanged: (([NearbyDiscoveredPeer]) -> Void)?
    private var incoming: ((any NearbyByteConnection) -> Void)?
    private var browsingRuns: [(
        peersChanged: ([NearbyDiscoveredPeer]) -> Void,
        failed: (NearbyTransferServiceError) -> Void
    )] = []

    func startBrowsing(
        serviceType: String,
        peersChanged: @escaping ([NearbyDiscoveredPeer]) -> Void,
        failed: @escaping (NearbyTransferServiceError) -> Void
    ) throws {
        XCTAssertEqual(serviceType, NearbyTransferService.bonjourServiceType)
        startBrowsingCount += 1
        self.peersChanged = peersChanged
        browsingRuns.append((peersChanged, failed))
    }

    func startOffering(
        serviceType: String,
        displayName: String,
        incoming: @escaping (any NearbyByteConnection) -> Void,
        failed: @escaping (NearbyTransferServiceError) -> Void
    ) throws {
        XCTAssertEqual(serviceType, NearbyTransferService.bonjourServiceType)
        XCTAssertEqual(displayName, "Dev One's iPad")
        startOfferingCount += 1
        self.incoming = incoming
    }

    func makeConnection(toPeerID peerID: String) throws -> any NearbyByteConnection {
        lastConnectedPeerID = peerID
        return NearbyLoopbackConnection.makePair().0
    }

    func stop() {
        stopCount += 1
        peersChanged = nil
        incoming = nil
    }

    func emitPeers(_ peers: [NearbyDiscoveredPeer]) {
        peersChanged?(peers)
    }

    func emitPeers(fromRun index: Int, _ peers: [NearbyDiscoveredPeer]) {
        browsingRuns[index].peersChanged(peers)
    }

    func emitFailure(fromRun index: Int, _ error: NearbyTransferServiceError) {
        browsingRuns[index].failed(error)
    }
}
