import Foundation
import XCTest
@testable import TesseraProtocolCore

final class ProtocolCoreTests: XCTestCase {
    func testContinuationV1MatchesFrozenBytes() throws {
        let descriptor = fixtureDescriptor()
        var expected = try Data(contentsOf: vectorURL("continuation/v1/canonical.json"))
        if expected.last == Character("\n").asciiValue {
            expected.removeLast()
        }
        XCTAssertEqual(try descriptor.encoded(), expected)
        XCTAssertEqual(try ContinuationDescriptorV1(encoded: expected), descriptor)
    }

    func testContinuationRejectsReplayShapeChanges() throws {
        let changed = try Data(
            contentsOf: vectorURL("continuation/v1/invalid-connection-key.json")
        )
        XCTAssertThrowsError(try ContinuationDescriptorV1(encoded: changed)) {
            guard case .connectionKeyMismatch = $0 as? ContinuationDescriptorError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testContinuationV1RejectionAndLimitVectors() throws {
        let cases: [(String, (ContinuationDescriptorError) -> Bool)] = [
            ("invalid-schema-version.json", {
                if case .unsupportedSchemaVersion(2) = $0 { return true }
                return false
            }),
            ("invalid-port.json", {
                if case .invalidPort(0) = $0 { return true }
                return false
            }),
            ("invalid-missing-tmux.json", { $0 == .missingTmuxSessionName }),
        ]
        for (file, matches) in cases {
            let data = try Data(contentsOf: vectorURL("continuation/v1/\(file)"))
            XCTAssertThrowsError(try ContinuationDescriptorV1(encoded: data), file) {
                guard let error = $0 as? ContinuationDescriptorError,
                      matches(error) else {
                    return XCTFail("unexpected \(file) error: \($0)")
                }
            }
        }

        let limitData = try Data(contentsOf: vectorURL("continuation/v1/limits.json"))
        let limits = try XCTUnwrap(
            JSONSerialization.jsonObject(with: limitData) as? [String: Int]
        )
        XCTAssertEqual(limits["maximumHandoffBytes"], ContinuationDescriptorV1.maximumHandoffBytes)
        XCTAssertEqual(limits["maximumViaCount"], ContinuationDescriptorV1.maximumViaCount)
    }

    func testContinuationV1PreservesReleasedUnknownFieldTolerance() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: vectorURL("continuation/v1/canonical.json"))
            ) as? [String: Any]
        )
        object["futureReleasedField"] = "ignored-by-v1"
        let extended = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try ContinuationDescriptorV1(encoded: extended), fixtureDescriptor())
    }

    func testManifestVersionIsIndependentFromTransportEpoch() {
        XCTAssertEqual(BootstrapManifestV2.currentVersion, 2)
        XCTAssertEqual(LegacyNearbyBootstrapV2.version, 2)
        XCTAssertEqual(ContinuationDescriptorV1.currentSchemaVersion, 1)
    }

    func testLegacyNearbyVersionProbeRejectsBooleanVersionPortably() throws {
        let valid = try XCTUnwrap(
            LegacyNearbyVersionProbeV2.probe(
                Data(#"{"version":2,"appVersion":"0.3.6"}"#.utf8)
            )
        )
        XCTAssertEqual(valid.version, 2)
        XCTAssertEqual(valid.appVersion, "0.3.6")
        XCTAssertEqual(
            LegacyNearbyVersionProbeV2.probe(Data(#"{"version":1}"#.utf8))?.version,
            1
        )
        XCTAssertNil(
            LegacyNearbyVersionProbeV2.probe(Data(#"{"version":true}"#.utf8))
        )
    }

    func testManifestRejectsUnknownFieldsBeforeDecode() throws {
        let poisoned = try Data(
            contentsOf: vectorURL("bootstrap-manifest/v2/invalid-unknown-root.json")
        )
        XCTAssertThrowsError(try BootstrapManifestV2.decode(poisoned)) {
            XCTAssertEqual(
                $0 as? BootstrapManifestError,
                .unknownField(path: "manifest", field: "password")
            )
        }
    }

    func testManifestDecoderAllowlistsMatchFrozenV2SchemaAndApprovedExtension() throws {
        let schemaData = try Data(
            contentsOf: repositoryURL(
                "docs/schemas/nearby-bootstrap/v2/manifest.schema.json"
            )
        )
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        )

        func keys(_ pointer: [String]) throws -> Set<String> {
            var node = schema
            for step in pointer {
                if step == "items" {
                    node = try XCTUnwrap(node["items"] as? [String: Any])
                } else {
                    let properties = try XCTUnwrap(
                        node["properties"] as? [String: Any]
                    )
                    node = try XCTUnwrap(properties[step] as? [String: Any])
                }
            }
            let properties = try XCTUnwrap(
                node["properties"] as? [String: Any]
            )
            return Set(properties.keys)
        }

        XCTAssertEqual(BootstrapManifestSchemaV2.root, try keys([]))
        XCTAssertEqual(
            BootstrapManifestSchemaV2.identity,
            try keys(["identities", "items"])
        )
        XCTAssertEqual(
            BootstrapManifestSchemaV2.host,
            try keys(["hosts", "items"])
        )
        XCTAssertEqual(
            BootstrapManifestSchemaV2.forward,
            try keys(["hosts", "items", "portForwards", "items"])
        )
        XCTAssertEqual(
            BootstrapManifestSchemaV2.jumpLink,
            try keys(["jumpChains", "items"])
        )
        XCTAssertEqual(
            BootstrapManifestSchemaV2.knownHost,
            try keys(["knownHosts", "items"])
        )
        XCTAssertEqual(
            BootstrapManifestSchemaV2.appearance,
            try keys(["appearance"])
        )
        XCTAssertEqual(
            BootstrapManifestSchemaV2.settings,
            try keys(["settings"]).union(["agentCenterEnabled"])
        )
    }

    func testManifestAgentCenterSharedExtensionVectors() throws {
        for (name, expected) in [("true", true), ("false", false), ("absent", nil)] as [(String, Bool?)] {
            let bytes = try Data(contentsOf: vectorURL("bootstrap-manifest/v2/agent-center-\(name).json"))
            let manifest = try BootstrapManifestV2.decode(bytes)
            XCTAssertEqual(manifest.settings.agentCenterEnabled, expected, name)
            XCTAssertEqual(try manifest.encoded(), Data(bytes.dropLast()), name)
        }
        for name in ["invalid-string", "invalid-number"] {
            let bytes = try Data(contentsOf: vectorURL("bootstrap-manifest/v2/agent-center-\(name).json"))
            XCTAssertThrowsError(try BootstrapManifestV2.decode(bytes), name)
        }
    }

    func testManifestAgentCenterOptionalSettingRoundTripsTrueAndFalse() throws {
        for enabled in [true, false] {
            let manifest = fixtureManifest(agentCenterEnabled: enabled)
            let decoded = try BootstrapManifestV2.decode(manifest.encoded())
            XCTAssertEqual(decoded, manifest)
            XCTAssertEqual(decoded.settings.agentCenterEnabled, enabled)
            let selected = try manifest.selectingOptionalTransfers([])
            XCTAssertEqual(selected.settings.agentCenterEnabled, enabled)
        }
    }

    func testManifestOlderSenderOmitsAgentCenterSetting() throws {
        let manifest = fixtureManifest()
        let data = try manifest.encoded()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertNil(settings["agentCenterEnabled"])
        XCTAssertNil(try BootstrapManifestV2.decode(data).settings.agentCenterEnabled)
    }

    func testManifestAgentCenterExtensionKeepsSettingsStrict() throws {
        let data = try fixtureManifest().encoded()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for value in ["true", 1, ["enabled": true]] as [Any] {
            var root = original
            var settings = try XCTUnwrap(root["settings"] as? [String: Any])
            settings["agentCenterEnabled"] = value
            root["settings"] = settings
            XCTAssertThrowsError(try BootstrapManifestV2.decode(
                JSONSerialization.data(withJSONObject: root)
            ))
        }
        var root = original
        var settings = try XCTUnwrap(root["settings"] as? [String: Any])
        settings["agentCenterSecret"] = true
        root["settings"] = settings
        XCTAssertThrowsError(try BootstrapManifestV2.decode(JSONSerialization.data(withJSONObject: root))) {
            XCTAssertEqual($0 as? BootstrapManifestError,
                           .unknownField(path: "manifest.settings", field: "agentCenterSecret"))
        }
    }

    func testManifestRejectsInheritedSessionAndAutomaticConnectionState() throws {
        let encoded = try fixtureManifest().encoded()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for field in ["sessionRestore", "selectedSessionID"] {
            var root = original
            root[field] = "inherited"
            XCTAssertThrowsError(try BootstrapManifestV2.decode(JSONSerialization.data(withJSONObject: root))) {
                XCTAssertEqual($0 as? BootstrapManifestError, .unknownField(path: "manifest", field: field))
            }
        }
        var root = original
        var settings = try XCTUnwrap(root["settings"] as? [String: Any])
        settings["sessionRestorePolicy"] = "always"
        root["settings"] = settings
        XCTAssertThrowsError(try BootstrapManifestV2.decode(JSONSerialization.data(withJSONObject: root))) {
            XCTAssertEqual($0 as? BootstrapManifestError,
                           .unknownField(path: "manifest.settings", field: "sessionRestorePolicy"))
        }
        root = original
        var hosts = try XCTUnwrap(root["hosts"] as? [[String: Any]])
        hosts[0]["connectOnLaunch"] = true
        root["hosts"] = hosts
        XCTAssertThrowsError(try BootstrapManifestV2.decode(JSONSerialization.data(withJSONObject: root))) {
            XCTAssertEqual($0 as? BootstrapManifestError,
                           .unknownField(path: "manifest.hosts[0]", field: "connectOnLaunch"))
        }
    }

    func testManifestV2MatchesCanonicalVectorExactly() throws {
        let manifest = fixtureManifest()
        var expected = try Data(
            contentsOf: vectorURL("bootstrap-manifest/v2/canonical.json")
        )
        if expected.last == Character("\n").asciiValue {
            expected.removeLast()
        }
        XCTAssertEqual(try manifest.encoded(), expected)
        XCTAssertEqual(try BootstrapManifestV2.decode(expected), manifest)
    }

    func testManifestV2AcceptsShippedAppleKnownHostFingerprintSpelling() throws {
        let fixture = fixtureManifest()
        let knownHost = BootstrapKnownHostDescriptor(
            hostID: fixture.hosts[0].id,
            fingerprint: "SHA256:cQoXbReba908/C49JxLoCDmoLE25BznKXbJG8nfohEg=",
            keyString: "ssh-ed25519 "
                + "AAAAC3NzaC1lZDI1NTE5AAAAIOqcFFoJtrRM4aFUrs7PZI8Zz4GfdpExu4M1fWpnD0Ge",
            firstSeen: Date(timeIntervalSinceReferenceDate: 0),
            lastSeen: Date(timeIntervalSinceReferenceDate: 86_400)
        )
        let manifest = BootstrapManifestV2(
            identities: fixture.identities,
            hosts: fixture.hosts,
            jumpChains: fixture.jumpChains,
            knownHosts: [knownHost],
            appearance: fixture.appearance,
            settings: fixture.settings
        )

        let encoded = try manifest.encoded()
        XCTAssertEqual(try BootstrapManifestV2.decode(encoded), manifest)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("hEg="))
    }

    func testManifestV2CheckedLimitsAreEnforcedBeforeElementValidation() throws {
        let limitsData = try Data(
            contentsOf: vectorURL("bootstrap-manifest/v2/limits.json")
        )
        let limits = try XCTUnwrap(
            JSONSerialization.jsonObject(with: limitsData) as? [String: Int]
        )
        XCTAssertEqual(limits["maximumEncodedByteCount"], BootstrapManifestV2.maximumEncodedByteCount)
        XCTAssertEqual(limits["maximumHostCount"], BootstrapManifestV2.maximumHostCount)
        XCTAssertEqual(limits["maximumIdentityCount"], BootstrapManifestV2.maximumIdentityCount)
        XCTAssertEqual(limits["maximumJumpChainCount"], BootstrapManifestV2.maximumJumpChainCount)
        XCTAssertEqual(limits["maximumKnownHostCount"], BootstrapManifestV2.maximumKnownHostCount)

        let fixture = fixtureManifest()
        let host = fixture.hosts[0]
        XCTAssertThrowsError(
            try BootstrapManifestV2(
                hosts: Array(
                    repeating: host,
                    count: BootstrapManifestV2.maximumHostCount + 1
                ),
                jumpChains: [],
                appearance: fixture.appearance,
                settings: fixture.settings
            ).validate()
        ) {
            XCTAssertEqual(
                $0 as? BootstrapManifestError,
                .tooManyHosts(BootstrapManifestV2.maximumHostCount + 1)
            )
        }

        let identity = BootstrapIdentityDescriptor(id: UUID(), name: "identity", user: "alice")
        XCTAssertThrowsError(
            try BootstrapManifestV2(
                identities: Array(
                    repeating: identity,
                    count: BootstrapManifestV2.maximumIdentityCount + 1
                ),
                hosts: [host],
                jumpChains: [],
                appearance: fixture.appearance,
                settings: fixture.settings
            ).validate()
        ) {
            XCTAssertEqual(
                $0 as? BootstrapManifestError,
                .tooManyIdentities(BootstrapManifestV2.maximumIdentityCount + 1)
            )
        }

        let jump = BootstrapJumpLink(hostID: host.id, jumpHostID: host.id)
        XCTAssertThrowsError(
            try BootstrapManifestV2(
                hosts: [host],
                jumpChains: Array(
                    repeating: jump,
                    count: BootstrapManifestV2.maximumJumpChainCount + 1
                ),
                appearance: fixture.appearance,
                settings: fixture.settings
            ).validate()
        ) {
            XCTAssertEqual(
                $0 as? BootstrapManifestError,
                .tooManyJumpChains(BootstrapManifestV2.maximumJumpChainCount + 1)
            )
        }

        let knownHost = BootstrapKnownHostDescriptor(
            hostID: host.id,
            fingerprint: "invalid-after-limit-check",
            keyString: "invalid-after-limit-check",
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 0)
        )
        XCTAssertThrowsError(
            try BootstrapManifestV2(
                hosts: [host],
                jumpChains: [],
                knownHosts: Array(
                    repeating: knownHost,
                    count: BootstrapManifestV2.maximumKnownHostCount + 1
                ),
                appearance: fixture.appearance,
                settings: fixture.settings
            ).validate()
        ) {
            XCTAssertEqual(
                $0 as? BootstrapManifestError,
                .tooManyKnownHosts(BootstrapManifestV2.maximumKnownHostCount + 1)
            )
        }

        let oversized = Data(
            repeating: 0x20,
            count: BootstrapManifestV2.maximumEncodedByteCount + 1
        )
        XCTAssertThrowsError(try BootstrapManifestV2.decode(oversized)) {
            XCTAssertEqual(
                $0 as? BootstrapManifestError,
                .encodedSizeExceeded(
                    actual: BootstrapManifestV2.maximumEncodedByteCount + 1,
                    maximum: BootstrapManifestV2.maximumEncodedByteCount
                )
            )
        }
    }

    func testTmuxTargetValidationIsSharedAndShellSafe() throws {
        XCTAssertTrue(TmuxTargetValidation.isSafeSessionName("dev-1.2_prod"))
        XCTAssertFalse(TmuxTargetValidation.isSafeSessionName("dev;rm -rf"))
        XCTAssertTrue(TmuxTargetValidation.isSessionID("$123"))
        XCTAssertTrue(TmuxTargetValidation.isWindowID("@7"))
        XCTAssertTrue(TmuxTargetValidation.isPaneID("%9"))
        XCTAssertEqual(
            try TmuxTargetValidation.displaySessionQuery(name: "dev"),
            "display-message -p -t =dev '#{session_id}\\t#{session_name}\\t#{session_attached}'"
        )
    }

    private func fixtureDescriptor() -> ContinuationDescriptorV1 {
        let via = ContinuationEndpointV1(
            hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "bastion",
            user: "jump",
            address: "jump.example",
            port: 22,
            transport: .ssh,
            hostKeyFingerprint: "SHA256:via"
        )
        return ContinuationDescriptorV1(
            endpoint: ContinuationEndpointV1(
                hostID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "production",
                user: "alice",
                address: "server.example",
                port: 2222,
                transport: .mosh,
                hostKeyFingerprint: "SHA256:destination"
            ),
            launchMode: .pinnedTmux,
            tmuxSessionName: "dev",
            via: [via]
        )
    }

    // MARK: - Host selection

    private func selectionFixture() -> (
        manifest: BootstrapManifestV2,
        a: UUID, b: UUID, c: UUID, identityA: UUID, identityC: UUID
    ) {
        let a = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "11111111-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "11111111-0000-0000-0000-000000000003")!
        let identityA = UUID(uuidString: "22222222-0000-0000-0000-000000000001")!
        let identityC = UUID(uuidString: "22222222-0000-0000-0000-000000000003")!
        let fixture = fixtureManifest()
        func host(_ id: UUID, _ name: String, identity: UUID?) -> BootstrapHostDescriptor {
            BootstrapHostDescriptor(
                id: id,
                name: name,
                address: "\(name).example",
                user: "alice",
                transport: .ssh,
                launchMode: .autoTmux,
                authenticationHint: .publicKey,
                identityID: identity
            )
        }
        func knownHost(_ id: UUID) -> BootstrapKnownHostDescriptor {
            BootstrapKnownHostDescriptor(
                hostID: id,
                fingerprint: "SHA256:cQoXbReba908/C49JxLoCDmoLE25BznKXbJG8nfohEg=",
                keyString: "ssh-ed25519 "
                    + "AAAAC3NzaC1lZDI1NTE5AAAAIOqcFFoJtrRM4aFUrs7PZI8Zz4GfdpExu4M1fWpnD0Ge",
                firstSeen: Date(timeIntervalSinceReferenceDate: 0),
                lastSeen: Date(timeIntervalSinceReferenceDate: 86_400)
            )
        }
        let manifest = BootstrapManifestV2(
            identities: [
                BootstrapIdentityDescriptor(id: identityA, name: "a", user: "alice"),
                BootstrapIdentityDescriptor(id: identityC, name: "c", user: "alice"),
            ],
            hosts: [
                host(a, "alpha", identity: identityA),
                host(b, "bravo", identity: nil),
                host(c, "charlie", identity: identityC),
            ],
            // alpha reaches its destination only through bravo.
            jumpChains: [BootstrapJumpLink(hostID: a, jumpHostID: b)],
            knownHosts: [knownHost(a), knownHost(c)],
            appearance: fixture.appearance,
            settings: fixture.settings
        )
        return (manifest, a, b, c, identityA, identityC)
    }

    func testSelectingHostsKeepsJumpDependenciesOfSelectedHosts() throws {
        let f = selectionFixture()

        let filtered = try f.manifest.selectingHosts([f.a])

        XCTAssertEqual(
            Set(filtered.hosts.map(\.id)), [f.a, f.b],
            "a selected host must bring the jump host it routes through"
        )
        XCTAssertEqual(filtered.jumpChains.map(\.hostID), [f.a])
        XCTAssertEqual(
            Set((filtered.knownHosts ?? []).map(\.hostID)), [f.a],
            "trust for an excluded host must not travel"
        )
        XCTAssertEqual(
            Set(filtered.identities.map(\.id)), [f.identityA],
            "identities are pruned to those the surviving hosts reference"
        )
    }

    func testSelectingHostsDropsLinksAndTrustNamingExcludedHosts() throws {
        let f = selectionFixture()

        // charlie has no jump dependency, so alpha and bravo both leave.
        let filtered = try f.manifest.selectingHosts([f.c])

        XCTAssertEqual(Set(filtered.hosts.map(\.id)), [f.c])
        XCTAssertTrue(
            filtered.jumpChains.isEmpty,
            "a link naming an excluded host would be dangling"
        )
        XCTAssertEqual(Set((filtered.knownHosts ?? []).map(\.hostID)), [f.c])
        XCTAssertEqual(Set(filtered.identities.map(\.id)), [f.identityC])
        // selectingHosts validates, so referential integrity is already proven;
        // assert it independently so a future change cannot quietly skip it.
        XCTAssertNoThrow(try filtered.validate())
    }

    func testHostSelectionClosureFollowsChainedJumpHosts() {
        let a = UUID(), b = UUID(), c = UUID(), unrelated = UUID()
        let chains = [
            BootstrapJumpLink(hostID: a, jumpHostID: b),
            BootstrapJumpLink(hostID: b, jumpHostID: c),
        ]

        XCTAssertEqual(
            BootstrapManifestV2.hostSelectionClosure([a], jumpChains: chains),
            [a, b, c],
            "the closure must follow the whole chain, not one hop"
        )
        XCTAssertEqual(
            BootstrapManifestV2.hostSelectionClosure([unrelated], jumpChains: chains),
            [unrelated]
        )
    }

    func testApprovedManifestHostSelectionNarrowsTheWireManifest() throws {
        let f = selectionFixture()

        let approved = try ApprovedBootstrapManifestV2(
            exportedManifest: f.manifest,
            selectedHostIDs: [f.c],
            selectedOptionalTransfers: []
        )

        XCTAssertEqual(Set(approved.manifest.hosts.map(\.id)), [f.c])
        // The pairing transaction binds authorizations to exactly these hosts.
        XCTAssertEqual(approved.manifest.hosts.count, 1)
    }

    func testApprovedManifestWithoutHostSelectionKeepsEveryHost() throws {
        let f = selectionFixture()

        let approved = try ApprovedBootstrapManifestV2(
            exportedManifest: f.manifest,
            selectedOptionalTransfers: []
        )

        XCTAssertEqual(Set(approved.manifest.hosts.map(\.id)), [f.a, f.b, f.c])
    }

    private func fixtureManifest(agentCenterEnabled: Bool? = nil) -> BootstrapManifestV2 {
        BootstrapManifestV2(
            hosts: [BootstrapHostDescriptor(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                name: "production",
                address: "server.example",
                user: "alice",
                transport: .ssh,
                launchMode: .autoTmux
            )],
            jumpChains: [],
            appearance: BootstrapAppearanceSettings(
                colorScheme: "system",
                accent: "blue",
                customAccentRGB: 0x00_7A_FF,
                monospacedFontName: "JetBrains Mono",
                terminalFontSize: 14,
                chromeMaterial: "system",
                cursorStyle: "block",
                cursorBlink: true,
                terminalThemeID: "default"
            ),
            settings: BootstrapGeneralSettings(
                scrollbackLines: 10_000,
                modifierBehavior: "oneShot",
                bellSoundEnabled: true,
                bellVisualEnabled: true,
                bellNotificationEnabled: false,
                accessoryBarKeys: ["escape"],
                filesReaperDays: 7,
                filesDefaultDestination: "cwd",
                agentCenterEnabled: agentCenterEnabled
            )
        )
    }

    private func vectorURL(_ relativePath: String) -> URL {
        repositoryURL("ProtocolVectors/\(relativePath)")
    }

    private func repositoryURL(_ relativePath: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent(relativePath)
    }
}
