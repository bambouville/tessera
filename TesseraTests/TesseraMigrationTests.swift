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
        XCTAssertEqual(TesseraMigrationPlan.schemas.count, 2)
        XCTAssertTrue(
            ObjectIdentifier(TesseraMigrationPlan.schemas[0])
                == ObjectIdentifier(TesseraSchemaV1.self),
            "V1 must be the first (baseline) schema in the plan"
        )
        XCTAssertTrue(
            ObjectIdentifier(TesseraMigrationPlan.schemas[1])
                == ObjectIdentifier(TesseraSchemaV2.self),
            "V2 (HostJumpLink) must follow the V1 baseline"
        )
    }

    func test_migrationPlan_hasOneStagePerVersionBump() {
        // One stage: V1 → V2 (adds the HostJumpLink entity, no column
        // changes on existing models). When this assertion starts failing
        // because a stage was added, double-check the matching
        // VersionedSchema was appended to `schemas` too — a stage without
        // its schema is a no-op.
        XCTAssertEqual(TesseraMigrationPlan.stages.count, 1)
    }

    func test_v2_versionIdentifier_isTwoZeroZero() {
        XCTAssertEqual(TesseraSchemaV2.versionIdentifier, Schema.Version(2, 0, 0))
    }

    func test_v2_models_addOnlyHostJumpLink() {
        let names = Set(TesseraSchemaV2.models.map { String(describing: $0) })
        XCTAssertEqual(
            names,
            ["PersistedHost", "Identity", "StoredKey", "HostJumpLink"]
        )
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

    func test_currentSchema_reopensARealOnDiskStoreWithoutLosingRows() throws {
        // An in-memory container cannot catch SQLite/CloudKit metadata and
        // array materialization failures. Exercise the same migration plan
        // against a disposable physical store, close every context, then open
        // it again exactly as an upgrade launch would.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("default.store")

        do {
            let container = try makeDiskContainer(at: storeURL)
            let context = ModelContext(container)
            let key = StoredKey(
                name: "disk-key",
                algorithm: .ed25519,
                authorizedKeysLine: "ssh-ed25519 AAAA disk"
            )
            let identity = Identity(
                name: "disk-identity",
                user: "alice",
                credentialMode: .key(key.id)
            )
            let host = PersistedHost(
                name: "disk-host",
                address: "192.0.2.10",
                port: 2222,
                identity: identity
            )
            host.tags = ["upgrade", "array-column"]
            host.envVars = "TESSERA_MIGRATION=preserved"
            context.insert(key)
            context.insert(identity)
            context.insert(host)
            try context.save()
        }

        do {
            let reopened = try makeDiskContainer(at: storeURL)
            let context = ModelContext(reopened)
            let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
            let identities = try context.fetch(FetchDescriptor<Identity>())
            let keys = try context.fetch(FetchDescriptor<StoredKey>())

            XCTAssertEqual(hosts.map(\.name), ["disk-host"])
            XCTAssertEqual(hosts.first?.tags, ["upgrade", "array-column"])
            XCTAssertEqual(hosts.first?.envVars, "TESSERA_MIGRATION=preserved")
            XCTAssertEqual(hosts.first?.identity?.user, "alice")
            XCTAssertEqual(identities.map(\.name), ["disk-identity"])
            XCTAssertEqual(keys.map(\.name), ["disk-key"])
        }
    }

    func test_v2_entityShapes_areFrozen() {
        let schema = Schema(versionedSchema: TesseraSchemaV2.self)
        let entities = Dictionary(uniqueKeysWithValues: schema.entities.map { ($0.name, $0) })
        XCTAssertEqual(
            Set(entities.keys),
            ["PersistedHost", "Identity", "StoredKey", "HostJumpLink"]
        )
        XCTAssertEqual(
            Set(entities["HostJumpLink"]?.attributes.map(\.name) ?? []),
            ["hostID", "jumpHostID"]
        )
        // Load-bearing: HostJumpLink must never grow a SwiftData
        // relationship — an inverse would alter PersistedHost's schema and
        // re-trip the iOS 26 [String] lightweight-migration bug.
        XCTAssertEqual(entities["HostJumpLink"]?.relationships.isEmpty, true)
    }

    func test_v1StoreOnDisk_migratesToV2_keepingHostsAndArrayColumn() throws {
        // The real upgrade oracle: write a store frozen at the V1 schema
        // (exactly what every existing install has on disk), then reopen it
        // through the migration plan at the V2 head. The [String] `tags`
        // column crossing the stage is the load-bearing part — iOS 26
        // lightweight migration aborts on array re-materialization when the
        // stage also changes columns on that model (it must not here, since
        // V2 only ADDS an entity).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-v1v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("default.store")

        let hostID = UUID()
        let bastionID = UUID()
        do {
            // V1 container: no migration plan, V1 schema only.
            let v1Schema = Schema(versionedSchema: TesseraSchemaV1.self)
            let configuration = ModelConfiguration(
                "TesseraMigrationDiskTest",
                schema: v1Schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: v1Schema,
                configurations: configuration
            )
            let context = ModelContext(container)
            let bastion = PersistedHost(
                id: bastionID,
                name: "bastion",
                address: "198.51.100.1",
                port: 2222
            )
            let host = PersistedHost(
                id: hostID,
                name: "inner",
                address: "203.0.113.9",
                port: 2222
            )
            host.tags = ["prod", "behind-bastion"]
            context.insert(bastion)
            context.insert(host)
            try context.save()
        }

        do {
            // Upgrade launch: V2 head + plan, same file.
            let reopened = try makeDiskContainer(at: storeURL)
            let context = ModelContext(reopened)
            let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
            XCTAssertEqual(Set(hosts.map(\.name)), ["bastion", "inner"])
            XCTAssertEqual(
                hosts.first(where: { $0.id == hostID })?.tags,
                ["prod", "behind-bastion"]
            )

            // The new table is usable immediately after migration.
            HostJumpChainResolver.setJumpHost(bastionID, for: hostID, in: context)
            try context.save()
            let inner = try XCTUnwrap(hosts.first(where: { $0.id == hostID }))
            let resolution = HostJumpChainResolver.resolve(for: inner, in: context)
            XCTAssertFalse(resolution.isBroken)
            XCTAssertEqual(resolution.hops.map(\.id), [bastionID])
        }
    }

    func test_v1StoreOnDisk_migratesToV2_underProductionShapedConfiguration() throws {
        // Same oracle as above but WITHOUT the named configuration /
        // explicit cloudKitDatabase overrides, matching the production
        // container factory as closely as a test can while still pointing
        // at a disposable URL. Guards against the migration behaving
        // differently under the default configuration shape.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-v1v2-prod-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("default.store")

        let hostID = UUID()
        do {
            let v1Schema = Schema(versionedSchema: TesseraSchemaV1.self)
            let container = try ModelContainer(
                for: v1Schema,
                configurations: ModelConfiguration(schema: v1Schema, url: storeURL)
            )
            let context = ModelContext(container)
            let host = PersistedHost(id: hostID, name: "aged", address: "203.0.113.7", port: 22)
            host.tags = ["prod", "array-column", "third"]
            context.insert(host)
            try context.save()
        }

        do {
            let container = try ModelContainer(
                for: TesseraModelContainer.currentSchema,
                migrationPlan: TesseraMigrationPlan.self,
                configurations: ModelConfiguration(
                    schema: TesseraModelContainer.currentSchema,
                    url: storeURL
                )
            )
            let context = ModelContext(container)
            let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
            XCTAssertEqual(hosts.map(\.name), ["aged"])
            XCTAssertEqual(hosts.first?.tags, ["prod", "array-column", "third"])
        }
    }

    private func makeDiskContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "TesseraMigrationDiskTest",
            schema: TesseraModelContainer.currentSchema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: TesseraModelContainer.currentSchema,
            migrationPlan: TesseraMigrationPlan.self,
            configurations: configuration
        )
    }
}
