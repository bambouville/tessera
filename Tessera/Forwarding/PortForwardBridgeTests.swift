import XCTest
import PortForwarding
@testable import Tessera

final class PortForwardBridgeTests: XCTestCase {
    func testRoundTripsThroughPersistedHost() {
        let persisted = PersistedHost()
        let rules = [
            PortForwardRule.localForward(localPort: 8080, remotePort: 80, label: "web"),
            PortForwardRule.localForward(localPort: 5432, remotePort: 5432, label: "pg")
        ]

        persisted.setPortForwardRules(rules)
        let host = Host(from: persisted)

        XCTAssertEqual(host.portForwardRules.count, 2)
        XCTAssertEqual(host.portForwardRules[0].bind.port, 8080)
        XCTAssertEqual(host.portForwardRules[0].label, "web")
        XCTAssertEqual(host.portForwardRules[1].bind.port, 5432)
        XCTAssertEqual(host.portForwardRules[1].label, "pg")
    }

    /// A blob written before the forwarding model gained a direction and
    /// bind/target endpoints still loads. Losing a stored rule to the
    /// migration is the one unacceptable outcome.
    func testPreSharedModelBlobStillLoadsAsALocalForward() {
        let persisted = PersistedHost()
        persisted.portForwardRulesData = Data("""
        [{"autoStart":true,"enabled":true,"id":"11111111-1111-1111-1111-111111111111",\
        "label":"web","localPort":8080,"remoteHost":"localhost","remotePort":80}]
        """.utf8)

        let host = Host(from: persisted)

        XCTAssertEqual(host.portForwardRules.count, 1)
        XCTAssertEqual(host.portForwardRules[0].direction, .local)
        XCTAssertEqual(
            host.portForwardRules[0].bind,
            PortForwardEndpoint(host: "127.0.0.1", port: 8080)
        )
        XCTAssertEqual(
            host.portForwardRules[0].target,
            PortForwardEndpoint(host: "localhost", port: 80)
        )
        XCTAssertEqual(host.portForwardRules[0].label, "web")
    }

    func testMissingDataDecodesToEmpty() {
        let persisted = PersistedHost()
        persisted.portForwardRulesData = nil

        let host = Host(from: persisted)

        XCTAssertTrue(host.portForwardRules.isEmpty)
    }
}
