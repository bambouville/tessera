import XCTest
import PortForwarding
@testable import Tessera

final class PortForwardBridgeTests: XCTestCase {
    func testRoundTripsThroughPersistedHost() {
        let persisted = PersistedHost()
        let rules = [
            PortForwardRule(localPort: 8080, remotePort: 80, label: "web"),
            PortForwardRule(localPort: 5432, remotePort: 5432, label: "pg")
        ]

        persisted.setPortForwardRules(rules)
        let host = Host(from: persisted)

        XCTAssertEqual(host.portForwardRules.count, 2)
        XCTAssertEqual(host.portForwardRules[0].localPort, 8080)
        XCTAssertEqual(host.portForwardRules[0].label, "web")
        XCTAssertEqual(host.portForwardRules[1].localPort, 5432)
        XCTAssertEqual(host.portForwardRules[1].label, "pg")
    }

    func testMissingDataDecodesToEmpty() {
        let persisted = PersistedHost()
        persisted.portForwardRulesData = nil

        let host = Host(from: persisted)

        XCTAssertTrue(host.portForwardRules.isEmpty)
    }
}
