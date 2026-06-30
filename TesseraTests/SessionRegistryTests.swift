import XCTest
@testable import Tessera

@MainActor
final class SessionRegistryTests: XCTestCase {
    func test_syncActiveSessions_mirrorsArray() {
        let registry = SessionRegistry()
        let a = makeLive(name: "alpha")
        let b = makeLive(name: "beta")

        registry.syncActiveSessions([a, b])

        XCTAssertEqual(registry.activeSessions.map(\.id), [a.id, b.id])
    }

    func test_markTouched_setsTimestamp() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        registry.syncActiveSessions([a])

        registry.markTouched(a.id)

        XCTAssertNotNil(registry.lastTouched[a.id])
    }

    func test_markTouched_ignoresUnknownID() {
        let registry = SessionRegistry()
        registry.syncActiveSessions([])

        registry.markTouched(UUID())

        XCTAssertTrue(registry.lastTouched.isEmpty)
    }

    func test_syncActiveSessions_dropsLastTouchedForRemovedSessions() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        registry.syncActiveSessions([a, b])
        registry.markTouched(a.id)
        registry.markTouched(b.id)

        registry.syncActiveSessions([a])

        XCTAssertNotNil(registry.lastTouched[a.id])
        XCTAssertNil(registry.lastTouched[b.id])
    }

    func test_mruOrder_sortsTouchedFirstByMostRecent() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        let c = makeLive(name: "c")
        registry.syncActiveSessions([a, b, c])

        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        registry.markTouched(a.id, at: t0.addingTimeInterval(1))
        registry.markTouched(b.id, at: t0.addingTimeInterval(3))
        registry.markTouched(c.id, at: t0.addingTimeInterval(2))

        XCTAssertEqual(registry.mruOrder, [b.id, c.id, a.id])
    }

    func test_mruOrder_appendsUntouchedSessionsLast() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        let c = makeLive(name: "c")
        registry.syncActiveSessions([a, b, c])
        registry.markTouched(b.id, at: Date())

        XCTAssertEqual(registry.mruOrder.first, b.id)
        XCTAssertEqual(Set(registry.mruOrder.dropFirst()), Set([a.id, c.id]))
    }

    func test_isRenderReady_defaultsFalse() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        registry.syncActiveSessions([a])

        // A freshly connected session is still showing its launch shield
        // until the owning view marks it ready.
        XCTAssertFalse(registry.isRenderReady(a.id))
    }

    func test_markRenderReady_setsReady() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        registry.syncActiveSessions([a])

        registry.markRenderReady(a.id)

        XCTAssertTrue(registry.isRenderReady(a.id))
    }

    func test_markRenderReady_isIdempotent() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        registry.syncActiveSessions([a])

        registry.markRenderReady(a.id)
        registry.markRenderReady(a.id)

        XCTAssertEqual(registry.renderReadyIDs, [a.id])
    }

    func test_syncActiveSessions_dropsRenderReadyForRemovedSessions() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        let b = makeLive(name: "b")
        registry.syncActiveSessions([a, b])
        registry.markRenderReady(a.id)
        registry.markRenderReady(b.id)

        registry.syncActiveSessions([a])

        XCTAssertTrue(registry.isRenderReady(a.id))
        XCTAssertFalse(registry.isRenderReady(b.id))
    }

    func test_sessionFor_returnsMatchingSession() {
        let registry = SessionRegistry()
        let a = makeLive(name: "a")
        registry.syncActiveSessions([a])

        XCTAssertEqual(registry.session(for: a.id)?.id, a.id)
        XCTAssertNil(registry.session(for: UUID()))
    }

    // MARK: helpers

    private func makeLive(name: String) -> LiveSession {
        let host = Host(
            name: name,
            address: "10.0.0.\(Int.random(in: 1...254))",
            port: 22,
            user: "user"
        )
        return LiveSession(
            session: .ssh(SSHSession(host: host)),
            hostName: name,
            hostKey: "ssh:user@\(host.address):22",
            launchMode: .autoTmux
        )
    }
}
