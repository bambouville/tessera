import XCTest
@testable import PortForwarding

/// The iOS shim's own surface: the storage codec (including the legacy blob
/// migration that must never lose a stored rule) and the sandbox validation
/// overlay. The shared model's rules are pinned in `TesseraDomainCoreTests`.
final class RuleTests: XCTestCase {

    // MARK: - Codec

    func test_emptyArrayRoundTripsToEmptyArray() {
        let encoded = RuleCodec.encode([])
        let decoded = RuleCodec.decode(encoded)

        XCTAssertEqual(decoded, [])
    }

    func test_singleRuleRoundTripsWithAllFieldsPreserved() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let rule = PortForwardRule.localForward(
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
        XCTAssertEqual(decoded.first?.direction, .local)
        XCTAssertEqual(decoded.first?.bind, PortForwardEndpoint(host: "127.0.0.1", port: 8080))
        XCTAssertEqual(decoded.first?.target, PortForwardEndpoint(host: "example.com", port: 443))
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

    func test_remoteAndDynamicRulesRoundTripThroughStorage() {
        let rules = [
            PortForwardRule(
                id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                direction: .remote,
                bind: PortForwardEndpoint(host: "0.0.0.0", port: 0),
                target: PortForwardEndpoint(host: "127.0.0.1", port: 3000),
                label: "preview"
            ),
            PortForwardRule(
                id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
                direction: .dynamic,
                bind: PortForwardEndpoint(host: "::1", port: 1080),
                label: "SOCKS"
            ),
        ]

        XCTAssertEqual(RuleCodec.decode(RuleCodec.encode(rules)), rules)
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

    // MARK: - Legacy blob migration (never lose a stored rule)

    /// Exactly what a build before the shared model wrote into
    /// `PersistedHost.portForwardRulesData`.
    private static let legacyBlob = Data("""
    [{"autoStart":false,"enabled":false,"id":"11111111-1111-1111-1111-111111111111",\
    "label":"HTTPS","localPort":8080,"remoteHost":"example.com","remotePort":443}]
    """.utf8)

    func test_legacyBlobDecodesAsALoopbackLocalForward() {
        let decoded = RuleCodec.decode(Self.legacyBlob)

        XCTAssertEqual(decoded.count, 1)
        let rule = decoded[0]
        XCTAssertEqual(rule.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(rule.enabled, false)
        XCTAssertEqual(rule.autoStart, false)
        XCTAssertEqual(rule.direction, .local)
        XCTAssertEqual(rule.bind, PortForwardEndpoint(host: "127.0.0.1", port: 8080))
        XCTAssertEqual(rule.target, PortForwardEndpoint(host: "example.com", port: 443))
        XCTAssertEqual(rule.label, "HTTPS")
    }

    func test_legacyBlobReEncodesInTheSharedShapeAndStaysStable() {
        let migrated = RuleCodec.decode(Self.legacyBlob)
        let reEncoded = RuleCodec.encode(migrated)

        XCTAssertTrue(String(decoding: reEncoded, as: UTF8.self).contains(#""bind""#))
        XCTAssertEqual(RuleCodec.decode(reEncoded), migrated)
    }

    func test_legacyBlobWithMissingOptionalFieldsTakesTheOldDefaults() {
        let data = Data("""
        [{"id":"22222222-2222-2222-2222-222222222222","localPort":9000,"remotePort":90}]
        """.utf8)

        let decoded = RuleCodec.decode(data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].enabled, true)
        XCTAssertEqual(decoded[0].autoStart, true)
        XCTAssertEqual(decoded[0].target, PortForwardEndpoint(host: "localhost", port: 90))
        XCTAssertEqual(decoded[0].label, "")
    }

    func test_oneUnreadableRuleDoesNotTakeItsNeighborsWithIt() {
        let data = Data("""
        [{"id":"33333333-3333-3333-3333-333333333333","localPort":9000,"remotePort":90},
         {"id":"not-a-uuid","localPort":9001,"remotePort":91},
         {"autoStart":true,"bind":{"host":"127.0.0.1","port":9002},"direction":"local",\
        "enabled":true,"id":"44444444-4444-4444-4444-444444444444","label":"",\
        "target":{"host":"localhost","port":92}}]
        """.utf8)

        let decoded = RuleCodec.decode(data)

        XCTAssertEqual(decoded.map(\.bind.port), [9000, 9002])
    }

    func test_aBlobMixingBothSpellingsDecodesBoth() {
        let data = Data("""
        [{"id":"55555555-5555-5555-5555-555555555555","localPort":1234,"remotePort":80},
         {"autoStart":true,"bind":{"host":"127.0.0.1","port":1080},"direction":"dynamic",\
        "enabled":true,"id":"66666666-6666-6666-6666-666666666666","label":"socks"}]
        """.utf8)

        let decoded = RuleCodec.decode(data)

        XCTAssertEqual(decoded.map(\.direction), [.local, .dynamic])
        XCTAssertNil(decoded[1].target)
    }

    // MARK: - Validation (iOS sandbox overlay + shared rules)

    func test_localPort1023ThrowsOutOfRange() {
        let rule = PortForwardRule.localForward(localPort: 1023, remotePort: 1)

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .localPortOutOfRange)
        }
    }

    func test_localPort1024Passes() {
        let rule = PortForwardRule.localForward(localPort: 1024, remotePort: 1)

        XCTAssertNoThrow(try RuleValidator.validate(rule: rule, against: []))
    }

    func test_localPort65535Passes() {
        let rule = PortForwardRule.localForward(localPort: 65535, remotePort: 1)

        XCTAssertNoThrow(try RuleValidator.validate(rule: rule, against: []))
    }

    func test_emptyRemoteHostThrowsRemoteHostEmpty() {
        let rule = PortForwardRule.localForward(localPort: 8080, remoteHost: "", remotePort: 1)

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .remoteHostEmpty)
        }
    }

    func test_whitespaceOnlyRemoteHostThrowsRemoteHostEmpty() {
        let rule = PortForwardRule.localForward(
            localPort: 8080,
            remoteHost: " \n\t ",
            remotePort: 1
        )

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .remoteHostEmpty)
        }
    }

    func test_missingTargetThrowsRemoteHostEmpty() {
        var rule = PortForwardRule.localForward(localPort: 8080, remotePort: 80)
        rule.target = nil

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .remoteHostEmpty)
        }
    }

    func test_remotePort0ThrowsRemotePortInvalid() {
        let rule = PortForwardRule.localForward(localPort: 8080, remotePort: 0)

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(error as? RuleValidationError, .remotePortInvalid)
        }
    }

    func test_remotePort1Passes() {
        let rule = PortForwardRule.localForward(localPort: 8080, remotePort: 1)

        XCTAssertNoThrow(try RuleValidator.validate(rule: rule, against: []))
    }

    func test_collisionWithDifferentIDThrowsFirstRuleID() {
        let firstID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let secondID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let existing = PortForwardRule.localForward(id: firstID, localPort: 8080, remotePort: 80)
        let newRule = PortForwardRule.localForward(id: secondID, localPort: 8080, remotePort: 443)

        XCTAssertThrowsError(try RuleValidator.validate(rule: newRule, against: [existing])) { error in
            guard case .localPortCollision(let otherID) = error as? RuleValidationError else {
                return XCTFail("Expected localPortCollision, got \(error)")
            }
            XCTAssertEqual(otherID, firstID)
        }
    }

    /// Adopted from the shared (Android) model: a disabled rule no longer
    /// reserves its port in the editor. Two enabled rules on one port still
    /// collide; if the user enables both later the second listener reports
    /// `portInUse` at runtime, as it always did.
    func test_collisionWithADisabledRuleIsAllowed() {
        var existing = PortForwardRule.localForward(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            localPort: 8080,
            remotePort: 80
        )
        existing.enabled = false
        let newRule = PortForwardRule.localForward(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            localPort: 8080,
            remotePort: 443
        )

        XCTAssertNoThrow(try RuleValidator.validate(rule: newRule, against: [existing]))
    }

    func test_selfIDCollisionIsIgnored() {
        let id = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let rule = PortForwardRule.localForward(id: id, localPort: 8080, remotePort: 80)

        XCTAssertNoThrow(try RuleValidator.validate(rule: rule, against: [rule]))
    }

    func test_differentLocalPortsDoNotCollide() {
        let existing = makeRule(id: "99999999-9999-9999-9999-999999999999", localPort: 8080, remotePort: 80)
        let newRule = makeRule(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", localPort: 8081, remotePort: 80)

        XCTAssertNoThrow(try RuleValidator.validate(rule: newRule, against: [existing]))
    }

    func test_nonLoopbackLocalBindSurfacesTheSharedFailure() {
        let rule = PortForwardRule(
            direction: .local,
            bind: PortForwardEndpoint(host: "0.0.0.0", port: 8080),
            target: PortForwardEndpoint(host: "localhost", port: 80)
        )

        XCTAssertThrowsError(try RuleValidator.validate(rule: rule, against: [])) { error in
            XCTAssertEqual(
                error as? RuleValidationError,
                .shared(.nonLoopbackLocalBind("0.0.0.0"))
            )
        }
    }

    // MARK: - Display helper

    func test_targetDisplayTextIsEmptyForADynamicRule() {
        let dynamic = PortForwardRule(
            direction: .dynamic,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 1080)
        )

        XCTAssertEqual(dynamic.targetDisplayText, "")
        XCTAssertEqual(
            PortForwardRule.localForward(localPort: 8080, remoteHost: "db", remotePort: 5432)
                .targetDisplayText,
            "db:5432"
        )
    }

    // MARK: - Identifiable / Equatable

    func test_twoRulesWithSameIDAreEqualOnlyIfAllFieldsMatch() {
        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let first = PortForwardRule.localForward(
            id: id,
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80,
            label: "web"
        )
        let same = PortForwardRule.localForward(
            id: id,
            localPort: 8080,
            remoteHost: "localhost",
            remotePort: 80,
            label: "web"
        )
        var changed = first
        changed.enabled = false

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, changed)
    }

    func test_identifiableIDRoundTrips() {
        let id = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let rule = PortForwardRule.localForward(id: id, localPort: 8080, remotePort: 80)

        XCTAssertEqual(rule.id, id)
        XCTAssertEqual(RuleCodec.decode(RuleCodec.encode([rule])).first?.id, id)
    }

    private func makeRule(id: String, localPort: UInt16, remotePort: UInt16) -> PortForwardRule {
        PortForwardRule.localForward(
            id: UUID(uuidString: id)!,
            localPort: localPort,
            remoteHost: "host-\(localPort).example",
            remotePort: remotePort,
            label: "rule-\(localPort)"
        )
    }
}
