import XCTest
@testable import Tessera

final class BootstrapManifestTests: XCTestCase {
    func test_manifestRoundTripsWithExactAllowlist() throws {
        let manifest = Self.makeManifestForCrossTest()
        let data = try manifest.encoded()

        XCTAssertEqual(try BootstrapManifest.decode(data), manifest)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(root.keys),
            [
                "version", "identities", "hosts", "jumpChains", "knownHosts",
                "appearance", "settings"
            ]
        )
        let hosts = try XCTUnwrap(root["hosts"] as? [[String: Any]])
        XCTAssertEqual(
            Set(hosts[0].keys),
            [
                "id", "name", "address", "port", "user", "transport", "launchMode",
                "tmuxSessionName", "tags", "osHint", "sortOrder", "authenticationHint",
                "identityID", "hostKeyFingerprint", "launchCommand", "notes",
                "envVars", "startupSnippet", "portForwards"
            ]
        )
        XCTAssertEqual(hosts[0]["hostKeyFingerprint"] as? String, "SHA256:public-fingerprint")
        XCTAssertEqual(hosts[0]["launchCommand"] as? String, "exec fish -l")
        XCTAssertEqual(hosts[0]["notes"] as? String, "primary development host")
        XCTAssertEqual(hosts[0]["envVars"] as? String, "LANG=en_US.UTF-8")
        XCTAssertEqual(hosts[0]["startupSnippet"] as? String, "cd ~/src")
    }

    func test_manifestWireContainsFullHostSettingsButNoCredentialSecrets() throws {
        let wire = String(decoding: try Self.makeManifestForCrossTest().encoded(), as: UTF8.self)
        for forbidden in [
            "\"password\":", "\"privateKey", "\"storedKey", "\"keychain",
            "\"credentialMode\":"
        ] {
            XCTAssertFalse(wire.localizedCaseInsensitiveContains(forbidden), "wire exposed \(forbidden)")
        }
        for expected in [
            "\"launchCommand\":\"exec fish -l\"",
            "\"notes\":\"primary development host\"",
            "\"envVars\":\"LANG=en_US.UTF-8\"",
            "\"startupSnippet\":\"cd ~/src\""
        ] {
            XCTAssertTrue(wire.contains(expected), "wire omitted \(expected)")
        }
    }

    func test_decoderRejectsUnknownSecretShapedField() throws {
        let encoded = try Self.makeManifestForCrossTest().encoded()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var hosts = try XCTUnwrap(root["hosts"] as? [[String: Any]])
        hosts[0]["password"] = "must-not-cross"
        root["hosts"] = hosts
        let poisoned = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(try BootstrapManifest.decode(poisoned)) { error in
            XCTAssertEqual(
                error as? BootstrapManifestError,
                .unknownField(path: "manifest.hosts[0]", field: "password")
            )
        }
    }

    func test_futureManifestVersionReportsVersionBeforeUnknownFieldLeak() throws {
        let encoded = try Self.makeManifestForCrossTest().encoded()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var hosts = try XCTUnwrap(root["hosts"] as? [[String: Any]])
        hosts[0]["newColumn"] = "added by a future sender"
        root["hosts"] = hosts
        root["version"] = 3
        let future = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(try BootstrapManifest.decode(future)) { error in
            XCTAssertEqual(
                error as? BootstrapManifestError,
                .unsupportedVersion(3),
                "a future manifest must report its version, not leak an unknown-field path"
            )
        }
    }

    func test_v1ManifestReportsUnsupportedVersion() throws {
        let encoded = try Self.makeManifestForCrossTest().encoded()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root["version"] = 1
        root.removeValue(forKey: "knownHosts")
        let v1 = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(try BootstrapManifest.decode(v1)) { error in
            XCTAssertEqual(error as? BootstrapManifestError, .unsupportedVersion(1))
        }
    }

    func test_manifestRejectsDanglingAndCyclicJumpChains() throws {
        let base = Self.makeManifestForCrossTest()
        let unknown = UUID()
        let dangling = BootstrapManifest(
            identities: base.identities,
            hosts: base.hosts,
            jumpChains: [BootstrapJumpLink(hostID: base.hosts[0].id, jumpHostID: unknown)],
            appearance: base.appearance,
            settings: base.settings
        )
        XCTAssertThrowsError(try dangling.encoded()) { error in
            XCTAssertEqual(error as? BootstrapManifestError, .danglingJumpLink(unknown))
        }

        let cycle = BootstrapManifest(
            identities: base.identities,
            hosts: base.hosts,
            jumpChains: [
                BootstrapJumpLink(hostID: base.hosts[0].id, jumpHostID: base.hosts[1].id),
                BootstrapJumpLink(hostID: base.hosts[1].id, jumpHostID: base.hosts[0].id)
            ],
            appearance: base.appearance,
            settings: base.settings
        )
        XCTAssertThrowsError(try cycle.encoded()) { error in
            guard case .cyclicJumpChain = error as? BootstrapManifestError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func test_manifestEnforcesEncodedSizeBudget() throws {
        let base = Self.makeManifestForCrossTest()
        let tags = (0..<4).map { index in
            "tag-\(index)-" + String(repeating: "x", count: 112)
        }
        let hosts = (0..<1_000).map { index in
            BootstrapHostDescriptor(
                id: UUID(),
                name: "host-\(index)",
                address: "host-\(index)." + String(repeating: "a", count: 900),
                user: "operator",
                transport: .ssh,
                launchMode: .autoTmux,
                tags: tags,
                osHint: "linux"
            )
        }
        let oversized = BootstrapManifest(
            hosts: hosts,
            jumpChains: [],
            appearance: base.appearance,
            settings: base.settings
        )

        XCTAssertThrowsError(try oversized.encoded()) { error in
            guard case .encodedSizeExceeded(let actual, let maximum) = error as? BootstrapManifestError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, BootstrapManifest.maximumEncodedByteCount)
        }
    }

    func test_manifestRejectsIdentityAndJumpLinkCountExhaustion() {
        let base = Self.makeManifestForCrossTest()
        let tooManyIdentities = BootstrapManifest(
            identities: Array(
                repeating: base.identities[0],
                count: BootstrapManifest.maximumIdentityCount + 1
            ),
            hosts: base.hosts,
            jumpChains: base.jumpChains,
            appearance: base.appearance,
            settings: base.settings
        )
        XCTAssertThrowsError(try tooManyIdentities.validate()) { error in
            XCTAssertEqual(
                error as? BootstrapManifestError,
                .tooManyIdentities(BootstrapManifest.maximumIdentityCount + 1)
            )
        }

        let tooManyLinks = BootstrapManifest(
            identities: base.identities,
            hosts: base.hosts,
            jumpChains: Array(
                repeating: base.jumpChains[0],
                count: BootstrapManifest.maximumJumpChainCount + 1
            ),
            appearance: base.appearance,
            settings: base.settings
        )
        XCTAssertThrowsError(try tooManyLinks.validate()) { error in
            XCTAssertEqual(
                error as? BootstrapManifestError,
                .tooManyJumpChains(BootstrapManifest.maximumJumpChainCount + 1)
            )
        }
    }

    static func makeManifestForCrossTest() -> BootstrapManifest {
        let identityID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let destinationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let jumpID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        return BootstrapManifest(
            identities: [
                BootstrapIdentityDescriptor(id: identityID, name: "operations", user: "alice")
            ],
            hosts: [
                BootstrapHostDescriptor(
                    id: destinationID,
                    name: "zeus",
                    address: "zeus.lan",
                    user: "alice",
                    transport: .mosh,
                    launchMode: .pinnedTmux,
                    tmuxSessionName: "dev",
                    tags: ["production"],
                    osHint: "linux",
                    sortOrder: 0,
                    authenticationHint: .publicKey,
                    identityID: identityID,
                    hostKeyFingerprint: "SHA256:public-fingerprint",
                    launchCommand: "exec fish -l",
                    notes: "primary development host",
                    envVars: "LANG=en_US.UTF-8",
                    startupSnippet: "cd ~/src",
                    portForwards: [
                        BootstrapPortForwardRule(
                            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                            enabled: true,
                            autoStart: false,
                            localPort: 8_080,
                            remoteHost: "localhost",
                            remotePort: 80,
                            label: "web"
                        )
                    ]
                ),
                BootstrapHostDescriptor(
                    id: jumpID,
                    name: "atlas",
                    address: "atlas.internal",
                    port: 2_222,
                    user: "deploy",
                    transport: .ssh,
                    launchMode: .autoTmux,
                    authenticationHint: .password
                )
            ],
            jumpChains: [BootstrapJumpLink(hostID: destinationID, jumpHostID: jumpID)],
            appearance: BootstrapAppearanceSettings(
                colorScheme: "dark",
                accent: "blue",
                customAccentRGB: 0xFF_66_AA,
                monospacedFontName: "JetBrainsMono-Regular",
                terminalFontSize: 13,
                chromeMaterial: "frosted",
                cursorStyle: "block",
                cursorBlink: true,
                terminalThemeID: "void"
            ),
            settings: BootstrapGeneralSettings(
                scrollbackLines: 10_000,
                modifierBehavior: "oneShot",
                bellSoundEnabled: false,
                bellVisualEnabled: true,
                bellNotificationEnabled: true,
                accessoryBarKeys: ["esc", "ctrl", "alt"],
                filesReaperDays: 7,
                filesDefaultDestination: "temp"
            )
        )
    }

}
