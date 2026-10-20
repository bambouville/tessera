import XCTest
@testable import TmuxControlCore

/// `feed` reuses the last snapshot it built while the engine's revision is
/// unchanged, and the Android ABI elides an unchanged snapshot by the same
/// token. Both are only correct if every mutation of published state moves
/// the revision; these tests hold the engine to that.
final class RuntimeSnapshotMemoTests: XCTestCase {
    private static let twoPaneLayout = "0000,80x24,0,0{39x24,0,0,8,40x24,40,0,9}"
    private static let threePaneLayout = "0000,80x24,0,0{39x24,0,0,8,40x24,40,0[40x12,40,0,9,40x11,40,13,11]}"

    /// One line per element; framed replies are kept whole so each element
    /// is a complete wire unit.
    private static let corpus: [String] = [
        "%session-changed $1 work",
        "%output %8 before hydration",
        "%begin 1 1 1\n__tessera_windows__\t@4\t0\t%8\t\(twoPaneLayout)\t\(twoPaneLayout)\t0\tmain\n"
            + "__tessera_windows__\t@5\t1\t%10\t0000,80x24,0,0,10\t0000,80x24,0,0,10\t0\tlogs\n%end 1 1 1",
        "%begin 1 2 1\n__tessera_panes__\t@4\t%8\t1\t0\t0\t39\t24\tvps\t/home/dev\tvps\n"
            + "__tessera_panes__\t@4\t%9\t0\t40\t0\t40\t24\ttop\t/tmp\tvps\n%end 1 2 1",
        "%begin 1 3 1\n__tessera_active_window__\t@4\t3.4\n%end 1 3 1",
        "%session-window-changed $1 @4",
        "%output %8 hello",
        "%window-renamed @4 editor",
        "%output %9 world",
        "%layout-change @4 \(threePaneLayout) \(threePaneLayout) *",
        "%window-pane-changed @4 %9",
        "%subscription-changed tessera-pane-meta $1 @4 0 %9 : "
            + ["@4", "%9", "1", "0", "0", "40", "12", "vim", "vps", "editor", "notes", "/srv", "", "1", "1", "0"]
                .joined(separator: "\t"),
        "%subscription-changed tessera-pane-meta $1 @4 0 %9 : "
            + ["@4", "%9", "1", "0", "0", "40", "12", "vim", "vps", "editor", "notes", "/srv", "", "1", "1", "0"]
                .joined(separator: "\t"),
        "%subscription-changed tessera-authority $1 @4 0 %8 : v1 tablet 3 iPad",
        "%subscription-changed tessera-authority $1 @4 0 %9 : v1 tablet 3 iPad",
        "%subscription-changed tessera-window-order $1 - - - : 0=@5 1=@4* ",
        "%window-add @6",
        "%session-window-changed $1 @6",
        "%output %8 after add",
        "%unlinked-window-close @6",
        "%session-renamed $1 renamed",
        "%window-close @5",
        "%session-changed $2 other",
    ]

    private func bytes(_ line: String) -> [UInt8] { Array((line + "\n").utf8) }

    private func assertMemoIsCurrent(
        _ engine: TmuxRuntimeEngine,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(engine.snapshot, engine.buildSnapshot(), "stale snapshot after \(label)", file: file, line: line)
        XCTAssertEqual(engine.revision, engine.buildSnapshot().revision, file: file, line: line)
    }

    func testEveryOrderedStepCarriesTheSnapshotAsOfThatStep() {
        // One read with every line, against the same lines read one at a time
        // with the memo checked after each: the memo must not change any step.
        var whole = TmuxRuntimeEngine()
        let batch = whole.feed(Self.corpus.flatMap(bytes))

        var single = TmuxRuntimeEngine()
        var expected: [TmuxRuntimeBatch.OrderedStep] = []
        for line in Self.corpus {
            let lineBatch = single.feed(bytes(line))
            if let last = lineBatch.orderedSteps.last {
                XCTAssertEqual(last.snapshot, single.buildSnapshot(), line)
            }
            XCTAssertEqual(lineBatch.snapshot, single.buildSnapshot(), line)
            assertMemoIsCurrent(single, line)
            expected += lineBatch.orderedSteps
        }

        XCTAssertGreaterThan(batch.orderedSteps.count, Self.corpus.count)
        // A step's stamp tag is the read's: a repeated edge collapses within
        // one read only (`RuntimeAuthorityProjectionTests`).
        func untagged(_ steps: [TmuxRuntimeBatch.OrderedStep]) -> [TmuxRuntimeBatch.OrderedStep] {
            steps.map { .init(event: $0.event, snapshot: $0.snapshot, isActiveWindowAuthoritative: $0.isActiveWindowAuthoritative) }
        }
        XCTAssertEqual(untagged(batch.orderedSteps), untagged(expected))
        XCTAssertEqual(batch.snapshot, single.buildSnapshot())
        // The corpus moves topology, labels, modes and order; stamps are edges.
        XCTAssertGreaterThan(Set(expected.map(\.snapshot.revision)).count, 8)
        // A step's own active-window flag and its snapshot's are one fact, and
        // the corpus both earns it (the active-window reply) and loses it (the
        // close fallback, the session switch).
        XCTAssertTrue(batch.orderedSteps.allSatisfy {
            $0.isActiveWindowAuthoritative == $0.snapshot.isActiveWindowAuthoritative
        })
        XCTAssertEqual(Set(batch.orderedSteps.map(\.snapshot.isActiveWindowAuthoritative)), [false, true])
    }

    func testUnchangedMessagesReuseOneSnapshot() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Self.corpus.prefix(6).flatMap(bytes))
        let revision = engine.revision
        let batch = engine.feed((0..<16).flatMap { bytes("%output %8 line \($0)") })
        XCTAssertEqual(batch.orderedSteps.count, 16)
        XCTAssertEqual(engine.revision, revision)
        XCTAssertTrue(batch.orderedSteps.allSatisfy { $0.snapshot == engine.buildSnapshot() })
    }

    func testEveryPublicMutationMovesTheRevisionWhenItChangesTheSnapshot() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Self.corpus.prefix(6).flatMap(bytes))
        let window = TmuxWindowSnapshot(
            id: WindowId(4),
            index: 0,
            name: "main",
            activePaneID: PaneId(8),
            activePaneTitle: "shell",
            panes: [
                TmuxPaneSnapshot(id: PaneId(8), title: "shell", isActive: true),
                TmuxPaneSnapshot(id: PaneId(9), title: "top"),
            ]
        )
        let mutations: [(String, (inout TmuxRuntimeEngine) -> Void)] = [
            ("projectAuthority peer", { $0.projectAuthority(.peer(deviceID: "laptop", displayName: "Mac", generation: 4)) }),
            ("projectAuthority mine", { $0.projectAuthority(.mine(generation: 5)) }),
            ("projectAuthority equal", { $0.projectAuthority(.mine(generation: 5)) }),
            ("projectAuthority generation", { $0.projectAuthority(.mine(generation: 6)) }),
            ("projectAuthority fallback", { $0.projectAuthority(.peer(deviceID: "-", displayName: "laptop", generation: 0)) }),
            ("projectAuthority unknown", { $0.projectAuthority(.unknown) }),
            ("ingestWindowPresentation", { _ = $0.ingestWindowPresentation(window) }),
            ("ingestWindowMetadata", { _ = $0.ingestWindowMetadata(window) }),
            ("ingestActivePaneQuery", { _ = $0.ingestActivePaneQuery(windowID: WindowId(4), paneID: PaneId(9)) }),
            ("ingestActiveWindowQuery", { _ = $0.ingestActiveWindowQuery(WindowId(5)) }),
            ("ingestProvisionalActivePane", { $0.ingestProvisionalActivePane(PaneId(10)) }),
            ("beginReorder", { _ = $0.beginReorder(expecting: [WindowId(5), WindowId(4)]) }),
            ("confirmReorder", { _ = $0.confirmReorder(token: 1) }),
            ("takePendingOrderRefreshCommand", { _ = $0.takePendingOrderRefreshCommand() }),
            ("completeOrderRefresh", { $0.completeOrderRefresh(succeeded: true) }),
            ("beginReorder again", { _ = $0.beginReorder(expecting: [WindowId(4), WindowId(5)]) }),
            ("abandonReorder", { _ = $0.abandonReorder(token: 2) }),
            ("ingestWindowOrderSubscription", {
                _ = $0.ingestWindowOrderSubscription("0=@5 1=@4*", sessionID: SessionId(1))
            }),
            ("ingestWindowListQuery", { _ = $0.ingestWindowListQuery([window]) }),
            ("replayTopologyNotification", {
                _ = $0.replayTopologyNotification(.windowRenamed(windowId: WindowId(4), name: "replayed"))
            }),
            ("takePendingWindowDetailQueries", { _ = $0.takePendingWindowDetailQueries() }),
            ("reset(keepingSnapshot:)", { $0.reset(keepingSnapshot: true) }),
            ("reset", { $0.reset() }),
        ]
        for (label, mutate) in mutations {
            // Refresh the memo first, so a mutation that changes published
            // state without moving the revision would be served stale.
            _ = engine.feed(bytes("%output %8 refresh"))
            assertMemoIsCurrent(engine, "refresh before \(label)")
            mutate(&engine)
            assertMemoIsCurrent(engine, label)
            // Filled as the mutator returns, so the reads an adapter makes
            // after it do not each rebuild until the next feed.
            XCTAssertTrue(engine.servesSnapshotFromMemo, "\(label) left the snapshot to be rebuilt")
        }
    }

    /// The memo is a stored value: a copy that diverges keeps its own.
    func testEngineCopiesNeverShareAMemo() {
        var original = TmuxRuntimeEngine()
        _ = original.feed(Self.corpus.prefix(6).flatMap(bytes))
        _ = original.snapshot
        var copy = original
        copy.projectAuthority(.mine(generation: 9))
        _ = copy.feed(bytes("%window-renamed @4 copied"))
        original.projectAuthority(.peer(deviceID: "-", displayName: "laptop", generation: 0))

        assertMemoIsCurrent(original, "mutating the original after a copy")
        assertMemoIsCurrent(copy, "mutating the copy")
        XCTAssertEqual(copy.snapshot.authority, .mine(generation: 9))
        XCTAssertEqual(original.snapshot.authority.peerDisplayName, "laptop")
        XCTAssertNotEqual(original.snapshot.windows.first?.name, "copied")
    }

    /// The capabilities ride the active-window reply, which can name a window
    /// this parser has not met yet. They were published without a revision.
    func testCapabilitiesFromAnActiveWindowReplyForAnUnknownWindowMoveTheRevision() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(bytes("%session-changed $1 work"))
        XCTAssertNil(engine.snapshot.capabilities)
        let revision = engine.revision

        let batch = engine.feed(bytes("%begin 1 1 1\n__tessera_active_window__\t@99\t3.4\n%end 1 1 1"))

        XCTAssertEqual(batch.snapshot.capabilities, .forVersion("3.4"))
        XCTAssertNotEqual(engine.revision, revision)
        assertMemoIsCurrent(engine, "active-window reply for an unknown window")

        // The same reply again changes nothing and so moves nothing.
        let settled = engine.revision
        _ = engine.feed(bytes("%begin 1 2 1\n__tessera_active_window__\t@99\t3.4\n%end 1 2 1"))
        XCTAssertEqual(engine.revision, settled)
    }

    // MARK: - Active-window authority

    private func activeWindowReply(_ window: Int, number: Int) -> String {
        "%begin 1 \(number) 1\n__tessera_active_window__\t@\(window)\t3.4\n%end 1 \(number) 1"
    }

    private func windowListReply(_ windows: Int..., number: Int) -> String {
        let rows = windows.enumerated().map { index, window in
            "__tessera_windows__\t@\(window)\t\(index)\t%\(window)\t\t\t0\tw\(window)\n"
        }
        return "%begin 1 \(number) 1\n" + rows.joined() + "%end 1 \(number) 1"
    }

    /// The snapshot publishes whether tmux named the active window or the
    /// engine only guessed it. Every transition must move the revision like
    /// any other published field, or the memo would serve the old value and
    /// the Android ABI would elide the flip. Several of these flips leave the
    /// active id and the windows untouched, so nothing else would carry them.
    func testActiveWindowAuthorityIsPublishedAndEveryFlipMovesTheRevision() {
        func wire(_ line: String) -> (inout TmuxRuntimeEngine) -> Void {
            { engine in _ = engine.feed(Array((line + "\n").utf8)) }
        }
        let transitions: [(String, (inout TmuxRuntimeEngine) -> Void, WindowId?, Bool)] = [
            ("session", wire("%session-changed $1 work"), nil, false),
            // Capabilities first, so the later reply changes nothing but the flag.
            ("reply naming an unknown window", wire(activeWindowReply(99, number: 1)), nil, false),
            ("first window-add is a provisional pick", wire("%window-add @4"), WindowId(4), false),
            ("tmux selects that same window", wire("%session-window-changed $1 @4"), WindowId(4), true),
            ("a later window-add leaves the active window", wire("%window-add @5"), WindowId(4), true),
            ("closing the active window falls back provisionally", wire("%unlinked-window-close @4"), WindowId(5), false),
            ("the active-window reply names the fallback", wire(activeWindowReply(5, number: 2)), WindowId(5), true),
            ("a list reply keeping the active window keeps the flag", wire(windowListReply(5, 6, number: 3)), WindowId(5), true),
            ("a list reply without the active window clears it", wire(windowListReply(6, number: 4)), nil, false),
            ("window-add with no active window picks provisionally", wire("%window-add @7"), WindowId(7), false),
            ("a list reply never promotes a pick", wire(windowListReply(6, 7, number: 5)), WindowId(7), false),
            ("another session's selection is ignored", wire("%session-window-changed $2 @7"), WindowId(7), false),
            ("our selection names the pick", wire("%session-window-changed $1 @7"), WindowId(7), true),
            ("switching session unproves it", wire("%session-changed $2 other"), WindowId(7), false),
            ("selection in the new session", wire("%session-window-changed $2 @7"), WindowId(7), true),
            ("ingestActiveWindowQuery for an unknown window", { _ = $0.ingestActiveWindowQuery(WindowId(42)) }, WindowId(7), true),
            ("reset forgets it", { $0.reset() }, nil, false),
            // Before `%session-changed` a broadcast cannot be proved ours.
            ("pick before any session", wire("%window-add @9"), WindowId(9), false),
            ("selection before any session", wire("%session-window-changed $3 @9"), WindowId(9), false),
            ("session-changed proves the earlier selection", wire("%session-changed $3 work"), WindowId(9), true),
            ("ingestActiveWindowQuery for a known window", { _ = $0.ingestActiveWindowQuery(WindowId(9)) }, WindowId(9), true),
        ]
        var engine = TmuxRuntimeEngine()
        var flips = 0
        var flagOnlyFlips = 0
        for (label, apply, expectedActive, expectedAuthoritative) in transitions {
            let before = engine.snapshot
            apply(&engine)
            let after = engine.snapshot
            assertMemoIsCurrent(engine, label)
            XCTAssertEqual(after.activeWindowID, expectedActive, label)
            XCTAssertEqual(after.isActiveWindowAuthoritative, expectedAuthoritative, label)
            XCTAssertEqual(after.isActiveWindowAuthoritative, engine.isActiveWindowAuthoritative, label)
            guard before.isActiveWindowAuthoritative != after.isActiveWindowAuthoritative else { continue }
            flips += 1
            XCTAssertNotEqual(after.revision, before.revision, "\(label) flipped the flag without a revision")
            if after.activeWindowID == before.activeWindowID,
               after.windows == before.windows,
               after.capabilities == before.capabilities,
               after.sessionID == before.sessionID {
                flagOnlyFlips += 1
            }
        }
        XCTAssertEqual(flips, 9)
        // Selection of the provisional window, the reply naming the fallback,
        // and both selections of @7: only the flag and the revision moved.
        XCTAssertEqual(flagOnlyFlips, 4)
    }

    /// The flag crosses every wire the snapshot does. A payload from before it
    /// existed reads as a provisional active window, never as tmux's answer.
    func testActiveWindowAuthorityRoundTripsAndAnOlderPayloadDecodesAsProvisional() throws {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(["%session-changed $1 work", "%window-add @4", "%session-window-changed $1 @4"].flatMap(bytes))
        let snapshot = engine.snapshot
        XCTAssertTrue(snapshot.isActiveWindowAuthoritative)

        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["isActiveWindowAuthoritative"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(TmuxSnapshot.self, from: encoded), snapshot)

        object.removeValue(forKey: "isActiveWindowAuthoritative")
        let older = try JSONDecoder().decode(
            TmuxSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(older.isActiveWindowAuthoritative)
        XCTAssertNotEqual(older, snapshot, "equality must see the flag")
        XCTAssertEqual(older, TmuxSnapshot(
            sessionID: snapshot.sessionID,
            sessionName: snapshot.sessionName,
            activeWindowID: snapshot.activeWindowID,
            isActiveWindowAuthoritative: false,
            windows: snapshot.windows,
            authority: snapshot.authority,
            capabilities: snapshot.capabilities,
            isReorderPending: snapshot.isReorderPending,
            authoritativeWindowOrder: snapshot.authoritativeWindowOrder,
            isWindowListHydrated: snapshot.isWindowListHydrated,
            revision: snapshot.revision
        ))
    }
}
