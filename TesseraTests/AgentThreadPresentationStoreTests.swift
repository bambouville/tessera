import XCTest
import TesseraCore
@testable import Tessera

@MainActor
final class AgentThreadPresentationStoreTests: XCTestCase {
    func testFollowingLatestRemainsFollowingAfterReplacement() throws {
        let store = AgentThreadPresentationStore(), thread = threadID(), owner = UUID()
        var following = AgentThreadPresentationState()
        following.positionedThread = thread
        XCTAssertNil(store.mountReader(for: thread, owner: owner, snapshot: { following }))
        store.unmountReader(for: thread, owner: owner)
        let restored = try XCTUnwrap(store.mountReader(for: thread, owner: UUID(), snapshot: { .init() }))
        XCTAssertTrue(restored.followingLatest)
        XCTAssertNil(restored.visibleRowID)
        XCTAssertNil(restored.renderedLowerID)
        XCTAssertNil(restored.renderedUpperID)
    }

    func testDisappearanceRecordsTheLatestLocalReadingState() throws {
        let store = AgentThreadPresentationStore(), thread = threadID()
        let owner = UUID()
        var local = AgentThreadPresentationState()
        XCTAssertNil(store.mountReader(for: thread, owner: owner, snapshot: { local }))
        local = heldState(thread)
        store.unmountReader(for: thread, owner: owner)
        let restored = try XCTUnwrap(store.mountReader(for: thread, owner: UUID(), snapshot: { .init() }))
        XCTAssertEqual(restored, local)
        XCTAssertFalse(restored.followingLatest)
        XCTAssertEqual(restored.visibleRowID, "older#0")
        XCTAssertEqual(restored.expandedToolEntries, ["tool#0", "tool#1"])
    }

    func testReplacementSamplesOnceBeforeAnOutgoingDisappearance() throws {
        let store = AgentThreadPresentationStore(), thread = threadID()
        let oldOwner = UUID(), newOwner = UUID()
        var old = AgentThreadPresentationState()
        var samples = 0
        _ = store.mountReader(for: thread, owner: oldOwner) { samples += 1; return old }
        old = heldState(thread)
        XCTAssertEqual(samples, 0, "scrolling writes local State, without sampling the store")
        var replacement = AgentThreadPresentationState()
        replacement = try XCTUnwrap(store.mountReader(for: thread, owner: newOwner, snapshot: { replacement }))
        XCTAssertEqual(replacement, old)
        XCTAssertEqual(samples, 1)
        // Let the old view finish after the replacement has changed position.
        replacement.visibleRowID = "new-owner#0"
        old.visibleRowID = "late-old-owner#0"
        store.unmountReader(for: thread, owner: oldOwner)
        store.unmountReader(for: thread, owner: newOwner)
        XCTAssertEqual(store.mountReader(for: thread, owner: UUID(), snapshot: { .init() })?.visibleRowID, "new-owner#0")
    }

    func testThreadsStaySeparateIncludingHostAndProviderIdentity() throws {
        let store = AgentThreadPresentationStore()
        let a = threadID(), b = threadID(provider: .codex), c = threadID(host: UUID())
        for (index, thread) in [a, b, c].enumerated() {
            let owner = UUID()
            var state = heldState(thread)
            state.visibleRowID = "row-\(index)"
            _ = store.mountReader(for: thread, owner: owner, snapshot: { state })
            store.unmountReader(for: thread, owner: owner)
        }
        for (index, thread) in [a, b, c].enumerated() {
            let restored = try XCTUnwrap(store.mountReader(for: thread, owner: UUID(), snapshot: { .init() }))
            XCTAssertEqual(restored.visibleRowID, "row-\(index)")
            XCTAssertEqual(restored.positionedThread, thread)
        }
    }

    func testPruningRejectsLateReadingAndComposerWrites() {
        let store = AgentThreadPresentationStore(), removed = threadID(), retained = threadID(provider: .codex)
        let owner = UUID()
        _ = store.mountReader(for: removed, owner: owner, snapshot: { self.heldState(removed) })
        _ = store.mountComposer(for: removed, owner: owner, snapshot: { true })
        let retainedOwner = UUID()
        _ = store.mountReader(for: retained, owner: retainedOwner, snapshot: { self.heldState(retained) })
        store.unmountReader(for: retained, owner: retainedOwner)
        store.prune(retaining: [retained])
        store.unmountReader(for: removed, owner: owner)
        XCTAssertTrue(store.unmountComposer(for: removed, owner: owner), "a pruned view can clean up its model mount without saving focus")
        XCTAssertNil(store.mountReader(for: removed, owner: UUID(), snapshot: { self.heldState(removed) }))
        XCTAssertFalse(store.mountComposer(for: removed, owner: UUID(), snapshot: { true }))
        store.prune(retaining: [retained, removed])
        XCTAssertNil(store.mountReader(for: removed, owner: UUID(), snapshot: { .init() }))
        XCTAssertFalse(store.mountComposer(for: removed, owner: UUID(), snapshot: { false }))
        XCTAssertEqual(store.mountReader(for: retained, owner: UUID(), snapshot: { .init() }), heldState(retained))
    }

    func testNewlyPublishedThreadsCanMountBeforeTheRootsPruneCallback() throws {
        let thread = threadID(), owner = UUID()
        var retained: Set<AgentThreadID> = []
        let store = AgentThreadPresentationStore(isRetained: { retained.contains($0) })
        store.prune(retaining: [])
        retained.insert(thread)
        _ = store.mountReader(for: thread, owner: owner, snapshot: { self.heldState(thread) })
        XCTAssertFalse(store.mountComposer(for: thread, owner: owner, snapshot: { true }))
        // Root onChange follows the child's appearance, as SwiftUI may do.
        store.prune(retaining: retained)
        store.unmountReader(for: thread, owner: owner)
        XCTAssertTrue(store.unmountComposer(for: thread, owner: owner))
        XCTAssertEqual(try XCTUnwrap(store.mountReader(for: thread, owner: UUID(), snapshot: { .init() })), heldState(thread))
        XCTAssertTrue(store.mountComposer(for: thread, owner: UUID(), snapshot: { false }))
        retained.remove(thread)
        XCTAssertNil(store.mountReader(for: thread, owner: UUID(), snapshot: { .init() }))
        XCTAssertFalse(store.mountComposer(for: thread, owner: UUID(), snapshot: { true }))
    }

    func testOnlyTheSameThreadsFocusedComposerRestoresInEitherLifecycleOrder() {
        for outgoingDisappearsFirst in [false, true] {
            let store = AgentThreadPresentationStore(), a = threadID(), b = threadID(provider: .codex)
            let oldOwner = UUID(), newOwner = UUID()
            XCTAssertFalse(store.mountComposer(for: a, owner: oldOwner, snapshot: { true }))
            if outgoingDisappearsFirst { XCTAssertTrue(store.unmountComposer(for: a, owner: oldOwner)) }
            XCTAssertTrue(store.mountComposer(for: a, owner: newOwner, snapshot: { false }))
            XCTAssertFalse(store.mountComposer(for: b, owner: UUID(), snapshot: { false }))
            XCTAssertFalse(store.unmountComposer(for: a, owner: oldOwner), "a late teardown cannot clear the replacement's mount")
            XCTAssertTrue(store.isCurrentComposer(for: a, owner: newOwner))
            XCTAssertTrue(store.unmountComposer(for: a, owner: newOwner))
            XCTAssertFalse(store.mountComposer(for: a, owner: UUID(), snapshot: { false }), "an unfocused composer must remain unfocused")
        }
    }

    func testPagingBudgetsCursorsAndBackoffSurviveRemount() throws {
        let store = AgentThreadPresentationStore(), thread = threadID(), owner = UUID()
        let state = heldState(thread)
        _ = store.mountReader(for: thread, owner: owner, snapshot: { state })
        store.unmountReader(for: thread, owner: owner)
        let restored = try XCTUnwrap(store.mountReader(for: thread, owner: UUID(), snapshot: { .init() }))
        XCTAssertEqual(restored.positionedThread, thread)
        XCTAssertEqual(restored.requestedCursor, "older-cursor")
        XCTAssertEqual(restored.requestedNewerCursor, "newer-cursor")
        XCTAssertEqual(restored.requestedBridgeCursor, "bridge-cursor")
        XCTAssertEqual(restored.automaticPages, 4)
        XCTAssertEqual(restored.fillPages, 8)
        XCTAssertEqual(restored.historyDemandGeneration, 7)
        XCTAssertEqual(restored.nextPageAttempt, state.nextPageAttempt)
        XCTAssertEqual(restored.pageRetryDelay, 16)
        XCTAssertEqual(restored.bridgeRetryDelay, 8)
    }

    private func threadID(host: UUID = UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!,
                          provider: AgentProviderID = .claude) -> AgentThreadID {
        AgentThreadID(hostID: host, providerID: provider, providerSessionID: "conversation")!
    }

    private func heldState(_ thread: AgentThreadID) -> AgentThreadPresentationState {
        var state = AgentThreadPresentationState()
        state.followingLatest = false
        state.visibleRowID = "older#0"
        state.renderedLowerID = "first#0"
        state.renderedUpperID = "last#0"
        state.expandedToolEntries = ["tool#0", "tool#1"]
        state.toolRunAnchors = ["tool#0": "run#0"]
        state.positionedThread = thread
        state.windowAtLiveHead = false
        state.requestedCursor = "older-cursor"
        state.requestedNewerCursor = "newer-cursor"
        state.requestedBridgeCursor = "bridge-cursor"
        state.automaticPages = 4
        state.fillPages = 8
        state.historyDemand = "before"
        state.historyDemandGeneration = 7
        state.nextPageAttempt = Date(timeIntervalSince1970: 1_000)
        state.pageRetryDelay = 16
        state.bridgeRetryDelay = 8
        return state
    }
}
