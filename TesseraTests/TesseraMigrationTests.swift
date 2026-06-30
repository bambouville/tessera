import XCTest
import SwiftData
@testable import Tessera

/// Guards the SwiftData migration baseline. These tests lock the v1 schema
/// shape and prove the migration plan + container build are self-consistent, so
/// a future schema change that breaks the plan fails CI here instead of wiping a
/// real user's hosts on first launch of the new build.
@MainActor
final class TesseraMigrationTests: XCTestCase {

    func test_v1_versionIdentifier_isOneZeroZero() {
        XCTAssertEqual(TesseraSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
    }

    func test_v1_models_areTheThreePersistedTypes() {
        let names = Set(TesseraSchemaV1.models.map { String(describing: $0) })
        XCTAssertEqual(names, ["PersistedHost", "Identity", "StoredKey"])
    }

    func test_migrationPlan_startsAtV1Baseline() {
        XCTAssertEqual(TesseraMigrationPlan.schemas.count, 1)
        XCTAssertTrue(
            ObjectIdentifier(TesseraMigrationPlan.schemas[0])
                == ObjectIdentifier(TesseraSchemaV1.self),
            "V1 must be the first (baseline) schema in the plan"
        )
    }

    func test_migrationPlan_hasNoStagesYet() {
        // Baseline: zero stages. When this assertion starts failing because a
        // stage was added, double-check the matching VersionedSchema was
        // appended to `schemas` too — a stage without its schema is a no-op.
        XCTAssertEqual(TesseraMigrationPlan.stages.count, 0)
    }

    func test_v1_entityShapes_areFrozen() {
        // The real shape lock. TesseraSchemaV1.models points at the LIVE types
        // while V1 is the head version, so without this test any property
        // add/rename/remove would sail through the name-level checks above and
        // only fail in production as a botched (or skipped) migration. If this
        // test fails, you changed the persisted schema: freeze V1, add
        // TesseraSchemaV2 + a MigrationStage (see TesseraMigrationPlan's doc
        // comment), and only then update these fixtures to describe V2.
        let schema = Schema(versionedSchema: TesseraSchemaV1.self)
        let entities = Dictionary(uniqueKeysWithValues: schema.entities.map { ($0.name, $0) })
        XCTAssertEqual(Set(entities.keys), ["PersistedHost", "Identity", "StoredKey"])

        XCTAssertEqual(
            Set(entities["PersistedHost"]?.attributes.map(\.name) ?? []),
            [
                "id", "name", "address", "port", "autoTmux", "transportRaw",
                "launchModeRaw", "tmuxSessionName", "launchCommand", "tags",
                "osHint", "notes", "envVars", "startupSnippet",
                "portForwardRulesData", "user", "sortOrder",
            ]
        )
        XCTAssertEqual(
            Set(entities["PersistedHost"]?.relationships.map(\.name) ?? []),
            ["identity"]
        )

        XCTAssertEqual(
            Set(entities["Identity"]?.attributes.map(\.name) ?? []),
            ["id", "name", "user", "credentialMode"]
        )
        XCTAssertEqual(
            Set(entities["Identity"]?.relationships.map(\.name) ?? []),
            ["hosts"]
        )

        XCTAssertEqual(
            Set(entities["StoredKey"]?.attributes.map(\.name) ?? []),
            [
                "id", "name", "algorithm", "authorizedKeysLine", "createdAt",
                "requiresBiometric", "isSecureEnclave", "agentForwarding",
            ]
        )
        XCTAssertEqual(entities["StoredKey"]?.relationships.isEmpty, true)
    }

    func test_currentSchema_buildsInMemoryContainerUnderMigrationPlan() throws {
        // Proves the schema, the plan, and the model list all agree and a store
        // can actually be opened with the plan attached — then round-trips every
        // model through it, exercising the load-bearing `tags: [String]` column.
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)

        let key = StoredKey(
            name: "k",
            algorithm: .ed25519,
            authorizedKeysLine: "ssh-ed25519 AAAA k"
        )
        let identity = Identity(
            name: "id",
            user: "alice",
            credentialMode: .key(key.id)
        )
        let host = PersistedHost(
            name: "h",
            address: "10.0.0.1",
            port: 22,
            identity: identity
        )
        host.user = "alice"
        host.tags = ["prod", "db"]
        context.insert(key)
        context.insert(identity)
        context.insert(host)
        try context.save()

        let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.tags, ["prod", "db"])
        XCTAssertEqual(hosts.first?.identity?.user, "alice")

        // Value-level round-trips, not just counts: `credentialMode` is a
        // Codable enum with an associated value (a real storage risk) and
        // StoredKey's fields prove the composite-attribute encoding survives.
        let keys = try context.fetch(FetchDescriptor<StoredKey>())
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.name, "k")
        XCTAssertEqual(keys.first?.algorithm, .ed25519)
        XCTAssertEqual(keys.first?.authorizedKeysLine, "ssh-ed25519 AAAA k")

        let identities = try context.fetch(FetchDescriptor<Identity>())
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.credentialMode, .key(key.id))
    }
}
