import SwiftData
import XCTest
@testable import Tessera

/// Checked-in allowlist/denylist for every persisted host, identity, and
/// settings property. A newly-added property is intentionally a test failure
/// until its cross-device security posture is reviewed and recorded here.
final class SyncClassificationTests: XCTestCase {
    private static let persistedHost = BootstrapSyncClassification.persistedHost
    private static let identity = BootstrapSyncClassification.identity
    private static let appearancePreferences = BootstrapSyncClassification.appearancePreferences

    func test_everyPersistedHostPropertyHasAnExplicitClassification() throws {
        let actual = try modelPropertyNames(PersistedHost.self)
        assertExactClassification(
            actual: actual,
            table: Self.persistedHost,
            typeName: "PersistedHost"
        )
    }

    func test_everyIdentityPropertyHasAnExplicitClassification() throws {
        let actual = try modelPropertyNames(Identity.self)
        assertExactClassification(
            actual: actual,
            table: Self.identity,
            typeName: "Identity"
        )
    }

    func test_everyAppearancePreferenceHasAnExplicitClassification() {
        let actual = reflectedPreferenceNames(AppearancePreferences())
        assertExactClassification(
            actual: actual,
            table: Self.appearancePreferences,
            typeName: "AppearancePreferences"
        )
    }

    func test_everyHostJumpLinkPropertyHasAnExplicitClassification() throws {
        let actual = try modelPropertyNames(HostJumpLink.self)
        assertExactClassification(
            actual: actual,
            table: BootstrapSyncClassification.hostJumpLink,
            typeName: "HostJumpLink"
        )
    }

    func test_sensitiveFieldsRequireExplicitNearbyOptIn() {
        XCTAssertEqual(Self.identity["credentialMode"], .neverSyncs)
        for field in ["launchCommand", "notes", "envVars", "startupSnippet"] {
            XCTAssertEqual(Self.persistedHost[field], .explicitNearbyOptIn)
        }
    }

    func test_deviceLocalFieldsNeverSync() {
        for field in [
            "requireFaceIDToUnlock", "autoLockMinutes", "lockWhenBackgrounded",
            "requireBiometricForKeyUse", "terminalBackgroundImageID",
            "sessionRestorePolicy", "hasSeenWelcome"
        ] {
            XCTAssertEqual(Self.appearancePreferences[field], .neverSyncs)
        }
    }

    private func modelPropertyNames<T: PersistentModel>(
        _ type: T.Type
    ) throws -> Set<String> {
        let schema = Schema([type])
        let entity = try XCTUnwrap(
            schema.entities.first { $0.name == String(describing: type) }
        )
        return Set(entity.properties.map(\.name))
    }

    /// `@Observable` may expose stored members as `_name` plus a synthesized
    /// registrar. Normalize that macro detail while still deriving the field
    /// set from the real type at runtime.
    private func reflectedPreferenceNames(_ preferences: AppearancePreferences) -> Set<String> {
        Set(Mirror(reflecting: preferences).children.compactMap { child in
            guard var label = child.label else { return nil }
            while label.hasPrefix("_") { label.removeFirst() }
            guard !label.hasPrefix("$") else { return nil }
            return label
        })
    }

    private func assertExactClassification(
        actual: Set<String>,
        table: [String: BootstrapFieldDisposition],
        typeName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let classified = Set(table.keys)
        let missing = actual.subtracting(classified).sorted()
        let stale = classified.subtracting(actual).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "\(typeName) has unclassified fields: \(missing)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            stale.isEmpty,
            "\(typeName) classification has stale fields: \(stale)",
            file: file,
            line: line
        )
    }
}
