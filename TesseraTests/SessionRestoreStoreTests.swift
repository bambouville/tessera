import XCTest
@testable import Tessera

final class SessionRestoreStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var key: String!
    private var store: SessionRestoreStore!

    override func setUp() {
        super.setUp()
        let suiteName = "tessera-session-restore-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        key = "restore-\(UUID().uuidString)"
        store = SessionRestoreStore(defaults: defaults, key: key)
    }

    override func tearDown() {
        defaults.removeObject(forKey: key)
        store = nil
        key = nil
        defaults = nil
        super.tearDown()
    }

    func test_saveAndLoad_roundTripsDocument() {
        let selected = UUID()
        let snapshot = makeSnapshot(liveSessionID: selected)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

        store.save(
            sessions: [snapshot],
            selectedSessionID: selected,
            savedAt: savedAt
        )

        let loaded = store.load()
        XCTAssertEqual(loaded?.schemaVersion, SessionRestoreDocument.currentSchemaVersion)
        XCTAssertEqual(loaded?.savedAt, savedAt)
        XCTAssertEqual(loaded?.sessions, [snapshot])
        XCTAssertEqual(loaded?.selectedSessionID, selected)
    }

    func test_save_dropsUnknownSelectedID() {
        let snapshot = makeSnapshot()

        store.save(sessions: [snapshot], selectedSessionID: UUID())

        XCTAssertNil(store.load()?.selectedSessionID)
    }

    func test_clear_removesStoredDocument() {
        store.save(sessions: [makeSnapshot()], selectedSessionID: nil)

        store.clear()

        XCTAssertNil(store.load())
    }

    func test_load_invalidJSON_clearsAndReturnsNil() {
        defaults.set(Data("not json".utf8), forKey: key)

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: key))
    }

    func test_load_unknownSchema_clearsAndReturnsNil() throws {
        let document = SessionRestoreDocument(
            schemaVersion: SessionRestoreDocument.currentSchemaVersion + 1,
            savedAt: Date(),
            sessions: [makeSnapshot()],
            selectedSessionID: nil
        )
        defaults.set(try JSONEncoder().encode(document), forKey: key)

        XCTAssertNil(store.load())
        XCTAssertNil(defaults.data(forKey: key))
    }

    private func makeSnapshot(
        liveSessionID: UUID = UUID(),
        persistedHostID: UUID = UUID(),
        name: String = "host"
    ) -> SessionRestoreSnapshot {
        SessionRestoreSnapshot(
            liveSessionID: liveSessionID,
            persistedHostID: persistedHostID,
            displayName: name,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
