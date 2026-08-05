import Foundation
import NIOSSH
import XCTest
@testable import Tessera

/// Pins the live nearby-bootstrap encoders against the frozen wire schemas in
/// `docs/schemas/nearby-bootstrap/v2/`. A failure here means the wire shape
/// changed at v2 — either revert the change or bump
/// `NearbyBootstrapProtocol.version` and add a new schema folder (see the
/// archive README for the freeze rule).
@MainActor
final class BootstrapWireSchemaTests: XCTestCase {
    func test_wireShapesMatchFrozenV2Schemas() throws {
        XCTAssertEqual(
            NearbyBootstrapProtocol.version, 2,
            "protocol version no longer matches the v2 schema folder this test reads"
        )
        XCTAssertEqual(NearbyBootstrapProtocol.supportedVersions, [2])
        XCTAssertEqual(NearbyHandshakeHello.currentVersion, NearbyBootstrapProtocol.version)
        XCTAssertEqual(NearbyHandshakeCommitment.currentVersion, NearbyBootstrapProtocol.version)
        XCTAssertEqual(BootstrapManifest.currentVersion, NearbyBootstrapProtocol.version)

        try assertManifestMatchesSchema()
        try assertManifestAllowlistsMatchSchema()
        try assertHelloMatchesSchema()
        try assertCommitmentMatchesSchema()
        try assertEnvelopeKindsMatchSchema()
        try assertEncryptedPayloadsMatchSchemas()
    }

    // MARK: - Per-message checks

    private func assertManifestMatchesSchema() throws {
        let schema = try loadSchema("manifest.schema.json")
        let base = BootstrapManifestTests.makeManifestForCrossTest()
        let keyString = "ssh-ed25519 "
            + "AAAAC3NzaC1lZDI1NTE5AAAAIOqcFFoJtrRM4aFUrs7PZI8Zz4GfdpExu4M1fWpnD0Ge"
        let fingerprint = KnownHostsStore.fingerprint(
            of: try NIOSSHPublicKey(openSSHPublicKey: keyString)
        )
        // Fully populated fixture: every optional field present so emitted
        // key paths must EQUAL the schema's property paths (strict schema).
        let manifest = BootstrapManifest(
            identities: base.identities,
            hosts: base.hosts,
            jumpChains: base.jumpChains,
            knownHosts: [
                BootstrapKnownHostDescriptor(
                    hostID: base.hosts[0].id,
                    fingerprint: fingerprint,
                    keyString: keyString,
                    firstSeen: Date(timeIntervalSinceReferenceDate: 0),
                    lastSeen: Date(timeIntervalSinceReferenceDate: 86_400)
                )
            ],
            appearance: base.appearance,
            settings: base.settings
        )
        let instance = try JSONSerialization.jsonObject(with: manifest.encoded())
        XCTAssertEqual(
            instanceKeyPaths(instance),
            schemaKeyPaths(schema),
            "manifest wire shape drifted from docs/schemas/nearby-bootstrap/v2/manifest.schema.json"
        )
        XCTAssertEqual(schemaVersionConst(schema), NearbyBootstrapProtocol.version)
    }

    /// Pins the DECODER side too: every strict-allowlist set in
    /// BootstrapManifestSchema must equal the frozen schema's property keys,
    /// so widening an allowlist without a schema-folder bump fails CI even if
    /// the encoder fixture never emits the new field.
    private func assertManifestAllowlistsMatchSchema() throws {
        let schema = try loadSchema("manifest.schema.json")
        func keys(_ pointer: [String]) throws -> Set<String> {
            var node = schema
            for step in pointer {
                if step == "items" {
                    node = try XCTUnwrap(node["items"] as? [String: Any])
                } else {
                    let properties = try XCTUnwrap(node["properties"] as? [String: Any])
                    node = try XCTUnwrap(properties[step] as? [String: Any])
                }
            }
            let properties = try XCTUnwrap(node["properties"] as? [String: Any])
            return Set(properties.keys)
        }

        XCTAssertEqual(BootstrapManifestSchema.root, try keys([]))
        XCTAssertEqual(BootstrapManifestSchema.identity, try keys(["identities", "items"]))
        XCTAssertEqual(BootstrapManifestSchema.host, try keys(["hosts", "items"]))
        XCTAssertEqual(
            BootstrapManifestSchema.forward,
            try keys(["hosts", "items", "portForwards", "items"])
        )
        XCTAssertEqual(BootstrapManifestSchema.jumpLink, try keys(["jumpChains", "items"]))
        XCTAssertEqual(BootstrapManifestSchema.knownHost, try keys(["knownHosts", "items"]))
        XCTAssertEqual(BootstrapManifestSchema.appearance, try keys(["appearance"]))
        XCTAssertEqual(BootstrapManifestSchema.settings, try keys(["settings"]))
    }

    private func assertHelloMatchesSchema() throws {
        let schema = try loadSchema("hello.schema.json")
        let hello = NearbyHandshakeHello(
            role: .origin,
            ephemeralPublicKey: Data(repeating: 6, count: 32),
            displayName: "Fixture iPad",
            appVersion: "1.0",
            supportedVersions: [2]
        )
        let instance = try JSONSerialization.jsonObject(with: hello.encoded())
        XCTAssertEqual(
            instanceKeyPaths(instance),
            schemaKeyPaths(schema),
            "hello wire shape drifted from docs/schemas/nearby-bootstrap/v2/hello.schema.json"
        )
        XCTAssertEqual(schemaVersionConst(schema), NearbyBootstrapProtocol.version)
    }

    private func assertCommitmentMatchesSchema() throws {
        let schema = try loadSchema("commitment.schema.json")
        let attempt = try NearbyHandshake.begin(
            role: .recipient,
            deterministicPrivateKey: Data((32..<64).map(UInt8.init))
        )
        let commitment = try NearbyHandshake.recipientCommitment(for: attempt)
        let instance = try JSONSerialization.jsonObject(with: commitment.encoded())
        let instancePaths = instanceKeyPaths(instance)
        // Advisory fields default from the bundle, which a test runner may
        // not populate — so: emitted paths must be a subset of the schema,
        // and every schema-required path must be emitted.
        XCTAssertTrue(
            instancePaths.isSubset(of: schemaKeyPaths(schema)),
            "commitment emitted keys outside the frozen v2 schema: "
                + "\(instancePaths.subtracting(schemaKeyPaths(schema)).sorted())"
        )
        let required = Set((schema["required"] as? [String]) ?? [])
        XCTAssertEqual(required, ["version", "role", "helloDigest"])
        XCTAssertTrue(required.isSubset(of: instancePaths))
        XCTAssertTrue(
            instancePaths.contains("supportedVersions"),
            "commitment must always advertise supportedVersions — it is the signal a future origin downgrades on"
        )
        XCTAssertEqual(schemaVersionConst(schema), NearbyBootstrapProtocol.version)
    }

    private func assertEncryptedPayloadsMatchSchemas() throws {
        let publicKey = BootstrapCoordinatorTests.fixturePublicKey()
        try assertInstance(
            canonicallyEncoded(publicKey),
            matches: "recipient-public-key.schema.json"
        )

        let manifest = BootstrapManifestTests.makeManifestForCrossTest()
        let acceptance = try BootstrapImportAcceptance.acknowledging(
            manifest,
            acceptedHostIDs: Set(manifest.hosts.map(\.id))
        )
        try assertInstance(
            canonicallyEncoded(acceptance),
            matches: "import-acceptance.schema.json"
        )

        // One failed result (with detail) and one exclusion, so every
        // receipt key path — including the conditional `detail` — is emitted.
        let receipt = BootstrapGrantBatchReceipt(
            publicKeyID: publicKey.id,
            publicKeyFingerprint: publicKey.fingerprint,
            results: [
                BootstrapHostGrantResult(
                    hostID: manifest.hosts[0].id,
                    hostName: manifest.hosts[0].name,
                    status: .failed,
                    detail: "fixture install failure"
                ),
                BootstrapHostGrantResult(
                    hostID: manifest.hosts[1].id,
                    hostName: manifest.hosts[1].name,
                    status: .excludedAuthentication,
                    detail: nil
                )
            ]
        )
        try assertInstance(
            canonicallyEncoded(receipt),
            matches: "grant-receipt.schema.json"
        )

        let acknowledgement = try BootstrapGrantCompletionAcknowledgement
            .acknowledging(receipt)
        try assertInstance(
            canonicallyEncoded(acknowledgement),
            matches: "completion-acknowledgement.schema.json"
        )
    }

    private func canonicallyEncoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func assertInstance(_ data: Data, matches schemaName: String) throws {
        let schema = try loadSchema(schemaName)
        let instance = try JSONSerialization.jsonObject(with: data)
        XCTAssertEqual(
            instanceKeyPaths(instance),
            schemaKeyPaths(schema),
            "wire shape drifted from docs/schemas/nearby-bootstrap/v2/\(schemaName)"
        )
    }

    private func assertEnvelopeKindsMatchSchema() throws {
        let schema = try loadSchema("encrypted-envelope.schema.json")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["kind", "payload"])
        XCTAssertEqual(Set((schema["required"] as? [String]) ?? []), ["kind", "payload"])

        let kindSchema = try XCTUnwrap(properties["kind"] as? [String: Any])
        let frozenKinds = Set(try XCTUnwrap(kindSchema["enum"] as? [String]))
        // The DEBUG-only "test" hook never ships and stays out of the schema.
        let liveKinds = Set(
            NearbyEncryptedEnvelopeKind.allCases.map(\.rawValue)
        ).subtracting(["test"])
        XCTAssertEqual(liveKinds, frozenKinds)
    }

    // MARK: - Schema plumbing

    private func loadSchema(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TesseraTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/schemas/nearby-bootstrap/v2")
            .appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func schemaVersionConst(_ schema: [String: Any]) -> Int? {
        let properties = schema["properties"] as? [String: Any]
        let version = properties?["version"] as? [String: Any]
        return version?["const"] as? Int
    }

    /// All dotted key paths a schema allows. Array `items` contribute to the
    /// same path as the array itself, matching `instanceKeyPaths`.
    private func schemaKeyPaths(_ schema: [String: Any], at path: String = "") -> Set<String> {
        var paths: Set<String> = []
        let resolved = (schema["items"] as? [String: Any]) ?? schema
        if let properties = resolved["properties"] as? [String: Any] {
            for (key, value) in properties {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                paths.insert(childPath)
                if let child = value as? [String: Any] {
                    paths.formUnion(schemaKeyPaths(child, at: childPath))
                }
            }
        }
        return paths
    }

    /// All dotted key paths an encoded instance emits; array elements merge
    /// into their parent path.
    private func instanceKeyPaths(_ value: Any, at path: String = "") -> Set<String> {
        var paths: Set<String> = []
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                paths.insert(childPath)
                paths.formUnion(instanceKeyPaths(child, at: childPath))
            }
        } else if let array = value as? [Any] {
            for element in array {
                paths.formUnion(instanceKeyPaths(element, at: path))
            }
        }
        return paths
    }
}
