import XCTest
@testable import PortForwarding

final class RuleTests: XCTestCase {

    // MARK: - Codec

    func test_emptyArrayRoundTripsToEmptyArray() {
        let encoded = RuleCodec.encode([])
        let decoded = RuleCodec.decode(encoded)

        XCTAssertEqual(decoded, [])
    }

    func test_singleRuleRoundTripsWithAllFieldsPreserved() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let rule = PortForwardRule(
            id: id,
            enabled: false,
            autoStart: false,
            localPort: 8080,
            remoteHost: "example.com",
            remotePort: 443,
            label: "HTTPS"
        )

        let decoded = RuleCodec.decode(RuleCodec.encode([rule]))

        XCTAssertEqual(decoded, [rule])
        XCTAssertEqual(decoded.first?.id, id)
        XCTAssertEqual(decoded.first?.enabled, false)
        XCTAssertEqual(decoded.first?.autoStart, false)
        XCTAssertEqual(decoded.first?.localPort, 8080)
        XCTAssertEqual(decoded.first?.remoteHost, "example.com")
        XCTAssertEqual(decoded.first?.remotePort, 443)
        XCTAssertEqual(decoded.first?.label, "HTTPS")
    }

    func test_multiRuleArrayRoundTripsOrderPreserving() {
        let rules = [
            makeRule(id: "22222222-2222-2222-2222-222222222222", localPort: 2000, remotePort: 20),
            makeRule(id: "33333333-3333-3333-3333-333333333333", localPort: 3000, remotePort: 30),
            makeRule(id: "44444444-4444-4444-4444-444444444444", localPort: 4000, remotePort: 40),
        ]

        let decoded = RuleCodec.decode(RuleCodec.encode(rules))

        XCTAssertEqual(decoded, rules)
        XCTAssertEqual(decoded.map(\.id), rules.map(\.id))
    }

    func test_decodeNilReturnsEmptyArray() {
        XCTAssertEqual(RuleCodec.decode(nil), [])
    }

    func test_decodeEmptyDataReturnsEmptyArray() {
        XCTAssertEqual(RuleCodec.decode(Data()), [])
    }

    func test_decodeGarbageReturnsEmptyArrayWithoutThrowing() {
        XCTAssertEqual(RuleCodec.decode(Data("garbage".utf8)), [])
    }

    func test_encodeUsesSortedKeysAndStableBytes() {
        let rules = [
            makeRule(id: "55555555-5555-5555-5555-555555555555", localPort: 5555, remotePort: 55)
        ]

        let first = RuleCodec.encode(rules)
        let second = RuleCodec.encode(rules)

        XCTAssertEqual(first, second)
        let json = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(json.contains(#""autoStart""#))
        XCTAssertLessThan(
            json.range(of: #""autoStart""#)!.lowerBound,
            json.range(of: #""enabled""#)!.lowerBound
        )
    }

    // MARK: - Validation

    func test_localPort1023ThrowsOutOfRange() {
        let rule = PortForwardRule(localPort: 1023, remotePort: 1)

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .localPortOutOfRange)
        }
    }

    func test_localPort1024Passes() throws {
        let rule = PortForwardRule(localPort: 1024, remotePort: 1)

        XCTAssertNoThrow(try RuleValidator.validate(rule: rule, against: []))
    }

    func test_localPort65535Passes() {
        let rule = PortForwardRule(localPort: 65535, remotePort: 1)

        XCTAssertNoThrow(try RuleValidator.validate(rule: rule, against: []))
    }

    func test_emptyRemoteHostThrowsRemoteHostEmpty() {
        let rule = PortForwardRule(localPort: 8080, remoteHost: "", remotePort: 1)

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .remoteHostEmpty)
        }
    }

    func test_whitespaceOnlyRemoteHostThrowsRemoteHostEmpty() {
        let rule = PortForwardRule(localPort: 8080, remoteHost: " \n\t ", remotePort: 1)

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .remoteHostEmpty)
        }
    }

    func test_remotePort0ThrowsRemotePortInvalid() {
        let rule = PortForwardRule(localPort: 8080, remotePort: 0)

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .remotePortInvalid)
        }
    }

    func test_remotePort1Passes() {
        let rule = PortForwardRule(localPort: 8080, remotePort: 1)

        XCTAssertNoThrow(try RuleValidator.validate(rule: rule, against: []))
    }

    func test_collisionWithDifferentIDThrowsFirstRuleID() {
        let firstID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let secondID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let existing = PortForwardRule(id: firstID, localPort: 8080, remotePort: 80)
        let newRule = PortForwardRule(id: secondID, localPort: 8080, remotePort: 443)

        XCTAssertThrowsError(try RuleValidator.validate(rule: newRule, against: [existing])) { error in
            guard case .localPortCollision(let otherID) = error as? RuleValidationError else {
                return XCTFail("Expected localPortCollision, got \(error)")
            }
            XCTAssertEqual(otherID, firstID)
        }
    }

    func test_selfIDCollisionIsIgnored() {
        let id = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let rule = PortForwardRule(id: id, localPort: 8080, remotePort: 80)

        XCTAssertNoThrow(try RuleValidator.validate(rule: rule, against: [rule]))
    }

    func test_differentLocalPortsDoNotCollide() {
        let existing = makeRule(id: "99999999-9999-9999-9999-999999999999", localPort: 8080, remotePort: 80)
        let newRule = makeRule(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", localPort: 8081, remotePort: 80)

        XCTAssertNoThrow(try RuleValidator.validate(rule: newRule, against: [existing]))
    }

    // MARK: - Identifiable / Equatable

    func test_twoRulesWithSameIDAreEqualOnlyIfAllFieldsMatch() {
        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let first = PortForwardRule(
            id: id,
            enabled: true,
            autoStart: true,
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80,
            label: "web"
        )
        let same = PortForwardRule(
            id: id,
            enabled: true,
            autoStart: true,
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80,
            label: "web"
        )
        let changed = PortForwardRule(
            id: id,
            enabled: false,
            autoStart: true,
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80,
            label: "web"
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, changed)
    }

    func test_identifiableIDRoundTrips() {
        let id = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let rule = PortForwardRule(id: id, localPort: 8080, remotePort: 80)

        XCTAssertEqual(rule.id, id)
        XCTAssertEqual(RuleCodec.decode(RuleCodec.encode([rule])).first?.id, id)
    }

    private func makeRule(id: String, localPort: UInt16, remotePort: UInt16) -> PortForwardRule {
        PortForwardRule(
            id: UUID(uuidString: id)!,
            localPort: localPort,
            remoteHost: "host-\(localPort).example",
            remotePort: remotePort,
            label: "rule-\(localPort)"
        )
    }
}
