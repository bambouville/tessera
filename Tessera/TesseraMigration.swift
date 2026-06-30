import Foundation
import SwiftData

// MARK: - Versioned schema

/// `TesseraSchemaV1` freezes the SwiftData schema exactly as shipped in the
/// first public TestFlight / App Store build. It is the baseline the migration
/// plan migrates *from*.
///
/// The three persisted models — `PersistedHost`, `Identity`, `StoredKey` — are
/// referenced here as the live top-level types. That is correct *only* while V1
/// is the current head version. The moment you need a `TesseraSchemaV2`, follow
/// the procedure documented on `TesseraMigrationPlan` below: V1 must keep
/// describing the OLD shape, so its model definitions have to be frozen (copied
/// into this namespace) before the live types are mutated — otherwise V1 and V2
/// point at the same types, SwiftData sees no delta, and your migration stage
/// never runs.
enum TesseraSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [PersistedHost.self, Identity.self, StoredKey.self]
    }
}

// MARK: - Migration plan

/// The single source of truth for how Tessera's on-disk SwiftData store evolves
/// across app updates.
///
/// Today there is exactly one version (`TesseraSchemaV1`) and zero stages — the
/// plan exists so the *first* shipped schema change can migrate real users'
/// hosts / identities / keys instead of silently resetting the store. (SwiftUI's
/// default `.modelContainer(for:)` falls back to an empty container when
/// lightweight migration fails, which reads to the user as "all my saved hosts
/// vanished" — see `feedback_swiftdata_migration_defaults` in project memory.)
///
/// ## Adding `TesseraSchemaV2` (the recipe for the next schema change)
///
/// 1. **Freeze V1.** Make `TesseraSchemaV1.models` keep describing the *old*
///    columns. The cheapest way is to snapshot the old `@Model` definitions into
///    a V1-namespaced copy before you mutate the live types. If V1 keeps
///    pointing at the live types after you change them, SwiftData detects no
///    delta between V1 and V2 and will skip your stage entirely.
/// 2. Add `enum TesseraSchemaV2: VersionedSchema` with the new model shapes and
///    `versionIdentifier = Schema.Version(2, 0, 0)`.
/// 3. Append `TesseraSchemaV2.self` to `schemas` (oldest-first order matters).
/// 4. Append a `MigrationStage` to `stages`:
///    - `.lightweight(fromVersion:toVersion:)` for purely additive changes — a
///      new optional column, or a new non-optional column **with a literal
///      property-level default** — UNLESS a `[String]` array column is involved
///      (see the trap below).
///    - `.custom(fromVersion:toVersion:willMigrate:didMigrate:)` when you must
///      transform data, or to work around the array-migration bug.
/// 5. Point `TesseraModelContainer.currentSchema` at the newest version.
///
/// ## ⚠️ The `[String]` array trap (load-bearing)
///
/// `PersistedHost.tags` is a `[String]`. On iOS 26 / Xcode 26, SwiftData's
/// *lightweight* migration cannot re-materialize an `Array<String>` attribute
/// when any other attribute changes in the same step — it aborts with
/// `Could not materialize Objective-C class named "Array"` and the store fails
/// to open (see `project_swiftdata_array_migration_bug` in project memory).
/// Therefore **any future stage that touches `PersistedHost` must be a `.custom`
/// stage**, even for an otherwise-trivial additive change: a custom stage runs
/// `willMigrate` / `didMigrate` with a real `ModelContext`, so you read the old
/// rows and re-write the array explicitly instead of relying on lightweight
/// inference. Until a stage like that exists, the established workaround is to
/// put new fields on `Identity` (which has no array columns).
enum TesseraMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [TesseraSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        // No migrations yet — V1 is the baseline. The first real schema bump
        // appends a stage here. See the doc comment above for the procedure.
        []
    }
}

// MARK: - Container factory (single source of truth for the live store)

/// Builds the production `ModelContainer` wired to `TesseraMigrationPlan`. Both
/// the app scene (`TesseraApp`) and the DEBUG dev-state seeder share this, so
/// there is exactly one model list + migration plan governing the on-disk store.
enum TesseraModelContainer {
    /// The destination schema — always the newest `VersionedSchema` in the plan.
    static let currentSchema = Schema(versionedSchema: TesseraSchemaV1.self)

    /// Create the container. `inMemory` is for tests / previews; the production
    /// path uses the default on-disk store (`default.store`) — the same URL the
    /// previous `.modelContainer(for:)` modifier used, so existing installs keep
    /// their data.
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: currentSchema,
            migrationPlan: TesseraMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
    }
}
