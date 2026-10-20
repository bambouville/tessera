import Foundation
import XCTest
@testable import TesseraDomainCore

/// Validation cases ported from Android's
/// `android/port-forwarding/src/test/kotlin/.../PortForwardingManagerTest.kt`,
/// which was the authority the shared model was lifted from, plus the
/// codec-migration and portable-subset rules that are new to the shared model.
final class PortForwardingTests: XCTestCase {

    // MARK: - Validation (ported from Kotlin)

    func testValidatorKeepsLocalAndDynamicListenersOnLoopback() {
        let local = makeLocalRule(bindHost: "0.0.0.0")
        let dynamic = PortForwardRule(
            direction: .dynamic,
            bind: PortForwardEndpoint(host: "10.0.0.5", port: 1080)
        )

        XCTAssertEqual(
            PortForwardRuleValidator.validate(local),
            .nonLoopbackLocalBind("0.0.0.0")
        )
        XCTAssertEqual(
            PortForwardRuleValidator.validate(dynamic),
            .nonLoopbackLocalBind("10.0.0.5")
        )
    }

    func testValidatorAcceptsEveryLoopbackSpelling() {
        for host in ["localhost", "LOCALHOST", "127.0.0.1", "::1"] {
            let rule = makeLocalRule(bindHost: host)
            XCTAssertNil(
                PortForwardRuleValidator.validate(rule),
                "expected \(host) to be treated as loopback"
            )
        }
    }

    func testValidatorAllowsExplicitRemoteBindAndAllocatedRemotePort() {
        let remote = PortForwardRule(
            direction: .remote,
            bind: PortForwardEndpoint(host: "0.0.0.0", port: 0),
            target: PortForwardEndpoint(host: "127.0.0.1", port: 3000)
        )

        XCTAssertNil(PortForwardRuleValidator.validate(remote))
    }

    func testValidatorRejectsPortZeroOnLocalAndDynamicBinds() {
        XCTAssertEqual(
            PortForwardRuleValidator.validate(makeLocalRule(port: 0)),
            .invalidBindPort(0)
        )
        XCTAssertEqual(
            PortForwardRuleValidator.validate(
                PortForwardRule(
                    direction: .dynamic,
                    bind: PortForwardEndpoint(host: "127.0.0.1", port: 0)
                )
            ),
            .invalidBindPort(0)
        )
    }

    func testValidatorPreservesPortableLowLocalPortsFromTheSharedBootstrapContract() {
        // The 1024 floor is an iOS sandbox rule applied as a platform overlay,
        // not part of the shared model: a rule imported from a platform that
        // can bind port 80 must survive the shared validator intact.
        XCTAssertNil(PortForwardRuleValidator.validate(makeLocalRule(port: 80)))
    }

    func testValidatorRejectsLocalBindCollisionsButNotRemoteServerBinds() {
        let existing = makeLocalRule(port: 8080)
        let sameLocal = makeLocalRule(port: 8080)
        let remote = PortForwardRule(
            direction: .remote,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 8080),
            target: PortForwardEndpoint(host: "127.0.0.1", port: 3000)
        )

        XCTAssertEqual(
            PortForwardRuleValidator.validate(sameLocal, against: [existing]),
            .bindCollision(conflictingRuleID: existing.id)
        )
        XCTAssertNil(PortForwardRuleValidator.validate(remote, against: [existing]))
    }

    func testValidatorIgnoresDisabledRulesWhenLookingForCollisions() {
        var existing = makeLocalRule(port: 8080)
        existing.enabled = false

        XCTAssertNil(
            PortForwardRuleValidator.validate(makeLocalRule(port: 8080), against: [existing])
        )
    }

    func testValidatorIgnoresACollisionWithTheRuleBeingEdited() {
        let rule = makeLocalRule(port: 8080)

        XCTAssertNil(PortForwardRuleValidator.validate(rule, against: [rule]))
    }

    func testValidatorRejectsEmptyAndWhitespaceBindAddresses() {
        XCTAssertEqual(
            PortForwardRuleValidator.validate(makeLocalRule(bindHost: "")),
            .invalidBindAddress("")
        )
        XCTAssertEqual(
            PortForwardRuleValidator.validate(makeLocalRule(bindHost: " \n\t ")),
            .invalidBindAddress(" \n\t ")
        )
    }

    func testValidatorRequiresATargetForLocalAndRemoteRules() {
        let local = PortForwardRule(
            direction: .local,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 8080)
        )
        let remote = PortForwardRule(
            direction: .remote,
            bind: PortForwardEndpoint(host: "0.0.0.0", port: 8080)
        )

        XCTAssertEqual(PortForwardRuleValidator.validate(local), .missingTarget)
        XCTAssertEqual(PortForwardRuleValidator.validate(remote), .missingTarget)
    }

    func testValidatorRejectsEmptyTargetHostAndZeroTargetPort() {
        var emptyHost = makeLocalRule()
        emptyHost.target = PortForwardEndpoint(host: "   ", port: 80)
        var zeroPort = makeLocalRule()
        zeroPort.target = PortForwardEndpoint(host: "localhost", port: 0)

        XCTAssertEqual(
            PortForwardRuleValidator.validate(emptyHost),
            .invalidTargetAddress("   ")
        )
        XCTAssertEqual(
            PortForwardRuleValidator.validate(zeroPort),
            .invalidTargetPort(0)
        )
    }

    func testValidatorRejectsADynamicRuleThatCarriesATarget() {
        let dynamic = PortForwardRule(
            direction: .dynamic,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 1080),
            target: PortForwardEndpoint(host: "localhost", port: 80)
        )

        XCTAssertEqual(
            PortForwardRuleValidator.validate(dynamic),
            .dynamicForwardCannotHaveTarget
        )
    }

    func testDynamicRuleWithoutATargetIsValid() {
        let dynamic = PortForwardRule(
            direction: .dynamic,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 1080),
            label: "SOCKS"
        )

        XCTAssertNil(PortForwardRuleValidator.validate(dynamic))
    }

    // MARK: - requiresRestart

    func testRequiresRestartOnlyForCarryingFieldChanges() {
        let rule = makeLocalRule(port: 8080)

        var relabelled = rule
        relabelled.label = "web"
        relabelled.enabled = false
        relabelled.autoStart = false
        XCTAssertFalse(rule.requiresRestart(other: relabelled))

        var rebound = rule
        rebound.bind = PortForwardEndpoint(host: "127.0.0.1", port: 8081)
        XCTAssertTrue(rule.requiresRestart(other: rebound))

        var retargeted = rule
        retargeted.target = PortForwardEndpoint(host: "db.internal", port: 5432)
        XCTAssertTrue(rule.requiresRestart(other: retargeted))

        var redirected = rule
        redirected.direction = .remote
        XCTAssertTrue(rule.requiresRestart(other: redirected))
    }

    // MARK: - Capabilities

    func testCapabilitiesForTransport() {
        let ssh = ForwardingCapabilities.forTransport(.ssh)
        XCTAssertTrue(ssh.local && ssh.remote && ssh.dynamic)
        XCTAssertNil(ssh.unavailableReason)

        let liveMosh = ForwardingCapabilities.forTransport(
            .mosh(sshSideChannelAvailable: true)
        )
        XCTAssertEqual(liveMosh, ssh)

        let deadMosh = ForwardingCapabilities.forTransport(
            .mosh(sshSideChannelAvailable: false)
        )
        XCTAssertFalse(deadMosh.local || deadMosh.remote || deadMosh.dynamic)
        XCTAssertEqual(deadMosh.unavailableReason, .moshWithoutSSHSideChannel)
        for direction in PortForwardDirection.allCases {
            XCTAssertFalse(deadMosh.supports(direction))
            XCTAssertTrue(ssh.supports(direction))
        }
    }

    // MARK: - Codec migration

    func testRuleRoundTripsThroughItsOwnCodableShape() throws {
        let rules = [
            makeLocalRule(port: 8100),
            PortForwardRule(
                direction: .remote,
                bind: PortForwardEndpoint(host: "0.0.0.0", port: 0),
                target: PortForwardEndpoint(host: "127.0.0.1", port: 3000),
                label: "preview | remote"
            ),
            PortForwardRule(
                direction: .dynamic,
                bind: PortForwardEndpoint(host: "::1", port: 1080),
                label: "SOCKS\nlocal"
            ),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rules)

        XCTAssertEqual(try JSONDecoder().decode([PortForwardRule].self, from: data), rules)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("privateKey"))
    }

    func testDynamicRuleEncodesWithoutATargetKey() throws {
        let dynamic = PortForwardRule(
            id: uuid("D1"),
            direction: .dynamic,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 1080)
        )

        let text = String(decoding: try JSONEncoder().encode(dynamic), as: UTF8.self)

        XCTAssertFalse(text.contains("\"target\""))
        XCTAssertNil(try JSONDecoder().decode(PortForwardRule.self, from: Data(text.utf8)).target)
    }

    /// The retired flat spelling this same type used before it grew endpoints.
    /// Any payload written by the previous DomainCore build must still decode.
    func testRetiredFlatDomainCoreShapeStillDecodes() throws {
        let json = """
        {
          "id": "\(uuid("A1").uuidString)",
          "enabled": false,
          "autoStart": false,
          "direction": "local",
          "bindAddress": "127.0.0.1",
          "bindPort": 8080,
          "targetHost": "example.com",
          "targetPort": 443,
          "label": "HTTPS"
        }
        """

        let rule = try JSONDecoder().decode(PortForwardRule.self, from: Data(json.utf8))

        XCTAssertEqual(rule.id, uuid("A1"))
        XCTAssertFalse(rule.enabled)
        XCTAssertFalse(rule.autoStart)
        XCTAssertEqual(rule.direction, .local)
        XCTAssertEqual(rule.bind, PortForwardEndpoint(host: "127.0.0.1", port: 8080))
        XCTAssertEqual(rule.target, PortForwardEndpoint(host: "example.com", port: 443))
        XCTAssertEqual(rule.label, "HTTPS")
    }

    func testHostProfileCarryingForwardsRoundTripsAndStaysSecretFree() throws {
        let profile = HostProfile(
            id: uuid("B1"),
            name: "production",
            endpoint: HostEndpoint(user: "alice", address: "server.example", port: 22),
            portForwards: [
                makeLocalRule(port: 8080),
                PortForwardRule(
                    direction: .dynamic,
                    bind: PortForwardEndpoint(host: "127.0.0.1", port: 1080)
                ),
            ]
        )

        let data = try JSONEncoder().encode(profile)

        XCTAssertEqual(try JSONDecoder().decode(HostProfile.self, from: data), profile)
        XCTAssertEqual(try profile.validated(), profile)
    }

    // MARK: - validated() stays weaker than the full validator

    func testValidatedAcceptsRulesTheFullValidatorRejects() throws {
        // A non-loopback local bind is rejected by the editor but must not turn
        // an already-saved host into a hard dial failure at route-resolve time.
        let rule = makeLocalRule(bindHost: "0.0.0.0")

        XCTAssertNotNil(PortForwardRuleValidator.validate(rule))
        XCTAssertEqual(try rule.validated(), rule)
    }

    func testValidatedRejectsEmptyBindHostAndMissingTarget() {
        var noTarget = makeLocalRule()
        noTarget.target = nil

        XCTAssertThrowsError(try makeLocalRule(bindHost: "  ").validated()) {
            XCTAssertEqual($0 as? DomainValidationError, .emptyBindAddress)
        }
        XCTAssertThrowsError(try noTarget.validated()) {
            XCTAssertEqual($0 as? DomainValidationError, .emptyTargetHost)
        }
    }

    func testValidatedAcceptsATargetlessDynamicRule() throws {
        let dynamic = PortForwardRule(
            direction: .dynamic,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 1080)
        )

        XCTAssertEqual(try dynamic.validated(), dynamic)
    }

    // MARK: - Portable local-rule subset (bootstrap manifest filter)

    /// `BootstrapPortForwardRule` can only describe a loopback local forward.
    /// This is the pin: dynamic and remote rules must never reach the manifest,
    /// where they would be flattened into a wrong local rule on the peer.
    func testPortableLocalSubsetExcludesDynamicAndRemoteRules() {
        let local = makeLocalRule(port: 8080)
        let remote = PortForwardRule(
            direction: .remote,
            bind: PortForwardEndpoint(host: "0.0.0.0", port: 0),
            target: PortForwardEndpoint(host: "127.0.0.1", port: 3000)
        )
        let dynamic = PortForwardRule(
            direction: .dynamic,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 1080)
        )

        let portable = PortForwardRule.portableLocalSubset(
            of: [remote, local, dynamic]
        )

        XCTAssertEqual(portable.map(\.id), [local.id])
    }

    func testPortableLocalSubsetDropsATargetlessLocalRule() {
        var broken = makeLocalRule(port: 9000)
        broken.target = nil

        XCTAssertTrue(PortForwardRule.portableLocalSubset(of: [broken]).isEmpty)
    }

    func testPortableLocalSubsetPreservesOrderAndAllCarryingFields() {
        let first = makeLocalRule(port: 8080)
        let second = makeLocalRule(port: 8081)

        XCTAssertEqual(
            PortForwardRule.portableLocalSubset(of: [first, second]),
            [first, second]
        )
    }

    // MARK: - Browsable web targets

    func testOnlyALocalLoopbackForwardIsBrowsable() {
        XCTAssertEqual(
            ForwardedWebPolicy.webTarget(for: makeLocalRule(port: 8080))?.url,
            "http://127.0.0.1:8080/"
        )

        // A remote bind listens on the server, so there is nothing to dial here.
        let remote = PortForwardRule(
            direction: .remote,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 8080),
            target: PortForwardEndpoint(host: "localhost", port: 80)
        )
        XCTAssertNil(ForwardedWebPolicy.webTarget(for: remote))

        // A dynamic rule is a SOCKS5 proxy: dialling it with HTTP is a
        // protocol error, not a page.
        let dynamic = PortForwardRule(
            direction: .dynamic,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 1080)
        )
        XCTAssertNil(ForwardedWebPolicy.webTarget(for: dynamic))

        // A non-loopback local bind cannot exist (the validator refuses it),
        // but an imported rule can still carry one.
        XCTAssertNil(ForwardedWebPolicy.webTarget(for: makeLocalRule(bindHost: "0.0.0.0")))
    }

    func testTheTargetPortNamesTheServiceNotTheBindPort() {
        let postgres = PortForwardRule(
            direction: .local,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 18080),
            target: PortForwardEndpoint(host: "localhost", port: 5432)
        )
        XCTAssertNil(ForwardedWebPolicy.webTarget(for: postgres))

        // The mirror case: a web server reached on a port that would look like
        // ssh locally is still a web server.
        let webOnPort22Locally = PortForwardRule(
            direction: .local,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 22),
            target: PortForwardEndpoint(host: "localhost", port: 3000)
        )
        XCTAssertEqual(
            ForwardedWebPolicy.webTarget(for: webOnPort22Locally)?.url,
            "http://127.0.0.1:22/"
        )
    }

    func testATLSServicePortCarriesTheHTTPSSchemeThroughTheTunnel() {
        let https = PortForwardRule(
            direction: .local,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 8443),
            target: PortForwardEndpoint(host: "localhost", port: 443)
        )
        let target = ForwardedWebPolicy.webTarget(for: https)
        XCTAssertEqual(target?.url, "https://127.0.0.1:8443/")
        XCTAssertEqual(target?.isSecure, true)
    }

    func testAnIPv6LoopbackIsBracketedBeforeItCarriesAPort() {
        XCTAssertEqual(
            ForwardedWebPolicy.webTarget(for: makeLocalRule(bindHost: "::1", port: 8080))?.url,
            "http://[::1]:8080/"
        )
        XCTAssertEqual(
            ForwardedWebPolicy.webTarget(for: makeLocalRule(bindHost: "localhost"))?.url,
            "http://localhost:8080/"
        )
    }

    func testATargetlessLocalRuleFallsBackToItsBindPort() {
        // The model allows it even though the validator does not; the service
        // question then has only the bind port to ask about.
        let targetless = PortForwardRule(
            direction: .local,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 3000)
        )
        XCTAssertEqual(ForwardedWebPolicy.webTarget(for: targetless)?.url, "http://127.0.0.1:3000/")

        let targetlessSSH = PortForwardRule(
            direction: .local,
            bind: PortForwardEndpoint(host: "127.0.0.1", port: 22)
        )
        XCTAssertNil(ForwardedWebPolicy.webTarget(for: targetlessSSH))
    }

    // MARK: - Helpers

    private func makeLocalRule(
        bindHost: String = "127.0.0.1",
        port: UInt16 = 8080
    ) -> PortForwardRule {
        PortForwardRule(
            direction: .local,
            bind: PortForwardEndpoint(host: bindHost, port: port),
            target: PortForwardEndpoint(host: "localhost", port: 80)
        )
    }

    private func uuid(_ prefix: String) -> UUID {
        let padded = prefix.padding(toLength: 8, withPad: "0", startingAt: 0)
        return UUID(uuidString: "\(padded)-1111-2222-3333-444444444444")!
    }
}
