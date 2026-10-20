import XCTest
@testable import TmuxControlCore

final class CompactClientSizingTests: XCTestCase {
    // MARK: - Ratio fallback (no layout tree)

    func testProjectsFocusedPaneToCompactViewportWithoutFlatteningLayout() {
        let viewport = (columns: 39, rows: 15)
        let window = CellRect(width: 80, height: 24, x: 0, y: 0)

        XCTAssertEqual(
            TmuxCompactClientSizing.clientSize(
                viewport: viewport,
                windowRect: window,
                focusRect: CellRect(width: 40, height: 24, x: 0, y: 0)
            ).columns,
            78
        )
        XCTAssertEqual(
            TmuxCompactClientSizing.clientSize(
                viewport: viewport,
                windowRect: window,
                focusRect: CellRect(width: 39, height: 24, x: 41, y: 0)
            ).columns,
            80
        )
        XCTAssertEqual(
            TmuxCompactClientSizing.clientSize(
                viewport: viewport,
                windowRect: window,
                focusRect: CellRect(width: 80, height: 11, x: 0, y: 13)
            ).rows,
            33
        )
    }

    func testTreeProjectionFallsBackToRatiosOnlyWithoutAUsableTree() {
        let layout = WindowLayout.parse("0000,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")!
        let window = CellRect(width: 80, height: 24, x: 0, y: 0)
        let focus = CellRect(width: 40, height: 24, x: 0, y: 0)
        let ratio = TmuxCompactClientSizing.clientSize(viewport: (39, 15), windowRect: window, focusRect: focus)

        // No tree, no focused pane, or a pane the tree lacks: ratios.
        for (tree, pane) in [(nil, PaneId(1)), (layout, nil), (layout, PaneId(9))] as [(WindowLayout?, PaneId?)] {
            let size = TmuxCompactClientSizing.clientSize(
                viewport: (39, 15),
                layout: tree,
                focusPaneId: pane,
                windowRect: window,
                focusRect: focus
            )
            XCTAssertEqual(size.columns, ratio.columns)
            XCTAssertEqual(size.rows, ratio.rows)
        }

        // With the tree, tmux's own split of the change decides: shrinking
        // 80 → 78 takes one cell from each pane and leaves %1 at 39.
        let solved = TmuxCompactClientSizing.clientSize(
            viewport: (39, 15),
            layout: layout,
            focusPaneId: PaneId(1),
            windowRect: window,
            focusRect: focus
        )
        XCTAssertEqual(solved.columns, 78)
        XCTAssertEqual(solved.rows, 15)
        XCTAssertEqual(
            TmuxLayoutReference.resized(layout, toColumns: 78, rows: 15).rect(ofPane: PaneId(1))?.width,
            39
        )

        // A zoomed window projects its visible single-pane layout: the phone
        // grid itself.
        let zoomed = WindowLayout.parse("0000,80x24,0,0,1")!
        let zoomedSize = TmuxCompactClientSizing.clientSize(
            viewport: (39, 15),
            layout: zoomed,
            focusPaneId: PaneId(1),
            windowRect: zoomed.root.rect,
            focusRect: zoomed.root.rect
        )
        XCTAssertEqual(zoomedSize.columns, 39)
        XCTAssertEqual(zoomedSize.rows, 15)
    }

    func testNestedStackGivesTheFocusedPaneTheViewportInBothDirections() {
        // {A,[B,C]}: C is the bottom of a stack on the right.
        let layout = WindowLayout.parse("0000,121x40,0,0{80x40,0,0,1,40x40,81,0[40x30,81,0,2,40x9,81,31,3]}")!
        let projected = TmuxCompactClientSizing.clientSize(
            viewport: (44, 20),
            layout: layout,
            focusPaneId: PaneId(3),
            windowRect: layout.root.rect,
            focusRect: layout.rect(ofPane: PaneId(3))
        )
        let landed = TmuxLayoutReference.resized(layout, toColumns: projected.columns, rows: projected.rows)
        XCTAssertEqual(landed.root.rect.width, projected.columns)
        XCTAssertEqual(landed.root.rect.height, projected.rows)
        XCTAssertEqual(landed.rect(ofPane: PaneId(3))?.width, 44)
        XCTAssertEqual(landed.rect(ofPane: PaneId(3))?.height, 20)
        let again = TmuxCompactClientSizing.clientSize(
            viewport: (44, 20),
            layout: landed,
            focusPaneId: PaneId(3),
            windowRect: landed.root.rect,
            focusRect: landed.rect(ofPane: PaneId(3))
        )
        XCTAssertEqual(again.columns, projected.columns)
        XCTAssertEqual(again.rows, projected.rows)
    }

    // MARK: - Fixed point on random layouts

    /// From any start, one advertisement lands the focused pane on the
    /// viewport (or on the nearest size tmux allows, or leaves the window
    /// alone when no size reaches it), tmux leaves the window exactly at the
    /// advertisement, reprojecting from the result changes nothing, and the
    /// reprojection decision holds and settles.
    func testSolvedProjectionIsAFixedPointOnRandomLayouts() throws {
        var rng = SplitMix64(seed: 0xC0_4AC7_51E1_2026)
        var exact = 0
        var bounded = 0
        var kept = 0
        for trial in 0..<1_200 {
            let panes = trial < 1_000 ? Int.random(in: 2...4, using: &rng) : Int.random(in: 1...6, using: &rng)
            let start = RandomTmuxLayouts.random(panes: panes, maximumSide: 240, using: &rng)
            let focus = start.leaves[Int.random(in: 0..<start.leaves.count, using: &rng)].paneId
            let viewport = (
                columns: Int.random(in: 0..<10, using: &rng) == 0
                    ? Int.random(in: 1...4, using: &rng)
                    : Int.random(in: 20...130, using: &rng),
                rows: Int.random(in: 0..<10, using: &rng) == 0
                    ? Int.random(in: 1...3, using: &rng)
                    : Int.random(in: 8...50, using: &rng)
            )
            let context = "trial \(trial) viewport \(viewport) focus \(focus) \(start)"

            let projected = project(viewport, start, focus)
            let reference = TmuxLayoutReference(start)
            let window = reference.resize_window(projected.columns, projected.rows)
            XCTAssertFalse(reference.stalled, context)
            XCTAssertEqual(window.sx, projected.columns, context)
            XCTAssertEqual(window.sy, projected.rows, context)
            let landed = reference.layout
            let pane = try XCTUnwrap(landed.rect(ofPane: focus), context)

            // On target, or pinned at the bound that stopped it.
            let model = try XCTUnwrap(TmuxLayoutResizeModel(start), context)
            let cell = try XCTUnwrap(model.cellIndex(ofPane: focus), context)
            for (dimension, wanted, landedPane, advertised, before) in [
                (TmuxLayoutResizeModel.Dimension.columns, viewport.columns, pane.width, projected.columns,
                 start.rect(ofPane: focus)!.width),
                (.rows, viewport.rows, pane.height, projected.rows, start.rect(ofPane: focus)!.height),
            ] {
                let floor = model.windowSize(dimension) - model.availability(dimension)[0]
                let smallest = model.resized(dimension, to: floor)[cell]
                let largest = model.resized(dimension, to: TmuxLayoutResizeModel.windowMaximum)[cell]
                if before == wanted {
                    XCTAssertEqual(advertised, model.windowSize(dimension), "kept \(dimension) \(context)")
                    exact += 1
                } else if wanted < smallest {
                    XCTAssertEqual(advertised, floor, "floor \(dimension) \(context)")
                    bounded += 1
                } else if wanted > largest {
                    // No window reaches it (a pane after the first of a
                    // same-direction nest never grows): leave the window be.
                    XCTAssertEqual(advertised, model.windowSize(dimension), "kept \(dimension) \(context)")
                    XCTAssertLessThan(advertised, TmuxLayoutResizeModel.windowMaximum, context)
                    kept += 1
                } else {
                    XCTAssertEqual(landedPane, wanted, "exact \(dimension) \(context)")
                    // And nothing smaller would have done.
                    if advertised > floor {
                        XCTAssertLessThan(model.resized(dimension, to: advertised - 1)[cell], wanted, context)
                    }
                    exact += 1
                }
            }

            // A fixed point: reprojecting, and tmux applying it again, change
            // nothing, however many times it happens.
            var layout = landed
            for _ in 0..<3 {
                let again = project(viewport, layout, focus)
                XCTAssertEqual(again.columns, projected.columns, context)
                XCTAssertEqual(again.rows, projected.rows, context)
                layout = TmuxLayoutReference.resized(layout, toColumns: again.columns, rows: again.rows)
                XCTAssertEqual(layout, landed, context)
            }

            var memo = TmuxCompactReprojectionMemo()
            XCTAssertEqual(
                decide(viewport, last: projected, layout: landed, focus: focus, memo: &memo),
                .hold,
                context
            )
            XCTAssertEqual(memo.corrections, 0, context)
        }
        XCTAssertEqual(exact + bounded + kept, 2_400)
        XCTAssertGreaterThan(bounded, 0)
        XCTAssertGreaterThan(kept, 0)
    }

    /// The whole client loop on random layouts and real tmux semantics:
    /// hydrate, then follow layout updates until the decision holds. It holds
    /// after exactly one advertisement, and never by the cycle guard.
    func testClientLoopSettlesAfterOneAdvertisementOnRandomLayouts() {
        var rng = SplitMix64(seed: 0x5E77_1E5_0000_0042)
        for trial in 0..<600 {
            let start = RandomTmuxLayouts.random(panes: Int.random(in: 2...4, using: &rng), maximumSide: 300, using: &rng)
            let focus = start.leaves[Int.random(in: 0..<start.leaves.count, using: &rng)].paneId
            let viewport = (columns: Int.random(in: 25...120, using: &rng), rows: Int.random(in: 10...50, using: &rng))
            let run = runClientLoop(viewport: viewport, start: start, focus: focus) { layout, size, _ in
                TmuxLayoutReference.resized(layout, toColumns: size.columns, rows: size.rows)
            }
            XCTAssertLessThanOrEqual(run.advertisements.count, 1, "trial \(trial) \(start)")
            XCTAssertEqual(run.finalDecision, .hold, "trial \(trial)")
            XCTAssertEqual(run.memo.corrections, 0, "trial \(trial)")
        }
    }

    // MARK: - Nested splits of the same direction

    /// What tmux 3.6a leaves after `{A,[B,{C,D}]}` loses B: the promoted
    /// `{C,D}` stays nested in the root (`layout_destroy_cell`). A grow
    /// reaches `{C,D}` one cell at a time and each goes to C, so D keeps its
    /// size at any window. Growing toward the viewport would only end at
    /// `windowMaximum` with D unchanged, so the window stays where it is.
    func testANestedPaneThatCannotGrowKeepsTheWindowOnBothAxes() throws {
        let sideBySide = try XCTUnwrap(WindowLayout.parse(
            "0000,200x50,0,0{100x50,0,0,1,99x50,101,0{58x50,101,0,3,40x50,160,0,4}}"
        ))
        let stacked = try XCTUnwrap(WindowLayout.parse(
            "0000,50x200,0,0[50x100,0,0,1,50x99,0,101[50x58,0,101,3,50x40,0,160,4]]"
        ))
        // tmux agrees D never grows: C takes every cell.
        let wide = TmuxLayoutReference.resized(sideBySide, toColumns: 1_000, rows: 50)
        XCTAssertEqual(wide.rect(ofPane: PaneId(4))?.width, 40)
        let tall = TmuxLayoutReference.resized(stacked, toColumns: 50, rows: 1_000)
        XCTAssertEqual(tall.rect(ofPane: PaneId(4))?.height, 40)

        for (layout, viewport, expected) in [
            (sideBySide, (columns: 50, rows: 50), (columns: 200, rows: 50)),
            // The other axis is still solved: every pane spans the height.
            (sideBySide, (columns: 50, rows: 20), (columns: 200, rows: 20)),
            (stacked, (columns: 50, rows: 50), (columns: 50, rows: 200)),
            (stacked, (columns: 20, rows: 50), (columns: 20, rows: 200)),
        ] {
            let context = "\(layout) viewport \(viewport)"
            let projected = project(viewport, layout, PaneId(4))
            XCTAssertEqual(projected.columns, expected.columns, context)
            XCTAssertEqual(projected.rows, expected.rows, context)
            let landed = TmuxLayoutReference.resized(layout, toColumns: projected.columns, rows: projected.rows)
            let again = project(viewport, landed, PaneId(4))
            XCTAssertEqual(again.columns, projected.columns, context)
            XCTAssertEqual(again.rows, projected.rows, context)

            var memo = TmuxCompactReprojectionMemo()
            XCTAssertEqual(decide(viewport, last: projected, layout: landed, focus: PaneId(4), memo: &memo), .hold, context)
            XCTAssertEqual(memo.corrections, 0, context)
        }

        // Hydrating over it adopts the window as it is, which moves nothing.
        var memo = TmuxCompactReprojectionMemo()
        XCTAssertEqual(decide((50, 50), last: (50, 50), layout: sideBySide, focus: PaneId(4), memo: &memo), .reproject)
        XCTAssertEqual(project((50, 50), sideBySide, PaneId(4)).columns, 200)
    }

    /// The first pane of the nest grows normally, and a nested pane larger
    /// than the device still shrinks to it. tmux shrinks the nest's first
    /// child to its minimum before the second, so C ends one column wide:
    /// the price of D fitting the device, and C regains the space first when
    /// a larger client grows the window.
    func testANestedPaneStillFitsWhenGrowingTheFirstOrShrinkingTheLast() throws {
        let sideBySide = try XCTUnwrap(WindowLayout.parse(
            "0000,200x50,0,0{100x50,0,0,1,99x50,101,0{58x50,101,0,3,40x50,160,0,4}}"
        ))
        let stacked = try XCTUnwrap(WindowLayout.parse(
            "0000,50x200,0,0[50x100,0,0,1,50x99,0,101[50x58,0,101,3,50x40,0,160,4]]"
        ))
        for (layout, horizontal) in [(sideBySide, true), (stacked, false)] {
            func length(_ layout: WindowLayout, _ pane: Int) -> Int? {
                layout.rect(ofPane: PaneId(pane)).map { horizontal ? $0.width : $0.height }
            }
            func viewport(_ length: Int) -> (columns: Int, rows: Int) {
                horizontal ? (length, 50) : (50, length)
            }
            for (focus, wanted) in [(3, 80), (4, 30)] {
                let projected = project(viewport(wanted), layout, PaneId(focus))
                let landed = TmuxLayoutReference.resized(layout, toColumns: projected.columns, rows: projected.rows)
                XCTAssertEqual(length(landed, focus), wanted, "\(layout) focus \(focus)")
                let again = project(viewport(wanted), landed, PaneId(focus))
                XCTAssertEqual(again.columns, projected.columns)
                XCTAssertEqual(again.rows, projected.rows)
            }
            let shrunk = project(viewport(30), layout, PaneId(4))
            let landed = TmuxLayoutReference.resized(layout, toColumns: shrunk.columns, rows: shrunk.rows)
            XCTAssertEqual(length(landed, 3), 1, "\(layout)")
            let regrown = TmuxLayoutReference.resized(landed, toColumns: horizontal ? 200 : 50, rows: horizontal ? 50 : 200)
            XCTAssertEqual(length(regrown, 4), 30, "\(layout)")
            XCTAssertGreaterThan(length(regrown, 3) ?? 0, 50, "\(layout)")
        }
    }

    /// tmux refuses `refresh-client -C` beyond WINDOW_MAXIMUM, so even the
    /// ratio fallback never asks for more.
    func testRatioFallbackNeverExceedsTmuxsWindowMaximum() {
        let size = TmuxCompactClientSizing.clientSize(
            viewport: (50, 40),
            windowRect: CellRect(width: 9_000, height: 40, x: 0, y: 0),
            focusRect: CellRect(width: 1, height: 40, x: 0, y: 0)
        )
        XCTAssertEqual(size.columns, TmuxLayoutResizeModel.windowMaximum)
        XCTAssertEqual(size.rows, 40)
    }

    // MARK: - Reprojection decision

    func testLargerPeerLayoutDoesNotCauseCompactClientToReclaim() {
        let viewport = (columns: 39, rows: 15)
        var memo = TmuxCompactReprojectionMemo()

        XCTAssertEqual(
            TmuxCompactClientSizing.reprojection(
                viewport: viewport,
                lastClientSize: viewport,
                layout: nil,
                focusPaneId: nil,
                windowRect: CellRect(width: 80, height: 24, x: 0, y: 0),
                focusRect: CellRect(width: 40, height: 24, x: 0, y: 0),
                memo: &memo
            ),
            .reproject
        )
        XCTAssertEqual(
            TmuxCompactClientSizing.reprojection(
                viewport: viewport,
                lastClientSize: (columns: 78, rows: 15),
                layout: nil,
                focusPaneId: nil,
                windowRect: CellRect(width: 160, height: 50, x: 0, y: 0),
                focusRect: CellRect(width: 80, height: 50, x: 0, y: 0),
                memo: &memo
            ),
            .hold
        )
        // The same with the tree: an iPad's 160x50 split is not ours.
        let peer = WindowLayout.parse("0000,160x50,0,0{80x50,0,0,1,79x50,81,0,2}")!
        XCTAssertEqual(
            decide(viewport, last: (78, 15), layout: peer, focus: PaneId(1), memo: &memo),
            .hold
        )
        // A peer canvas that projects somewhere new is still not ours, even
        // when one of its dimensions happens to match the advertisement.
        for peer in [
            "0000,160x15,0,0{100x15,0,0,1,59x15,101,0,2}",
            "0000,78x40,0,0[78x20,0,0,1,78x19,0,21,2]",
        ] {
            let layout = WindowLayout.parse(peer)!
            XCTAssertNotEqual(project(viewport, layout, PaneId(1)).columns, 78, peer)
            XCTAssertEqual(
                decide(viewport, last: (78, 15), layout: layout, focus: PaneId(1), memo: &memo),
                .hold,
                peer
            )
            XCTAssertEqual(memo.corrections, 0, peer)
        }
    }

    func testWindowAlreadyAtTheProjectedGridReadvertisesAStaleClientSize() {
        var memo = TmuxCompactReprojectionMemo()
        // A landscape replay tmux refused (another client held `latest`),
        // then back to portrait: the window is portrait-sized, but tmux still
        // records the landscape client size for this client.
        XCTAssertEqual(
            TmuxCompactClientSizing.reprojection(
                viewport: (columns: 54, rows: 37),
                lastClientSize: (columns: 106, rows: 9),
                layout: nil,
                focusPaneId: nil,
                windowRect: CellRect(width: 54, height: 37, x: 0, y: 0),
                focusRect: CellRect(width: 54, height: 37, x: 0, y: 0),
                memo: &memo
            ),
            .reproject
        )
        let portrait = WindowLayout.parse("0000,54x37,0,0,4")!
        XCTAssertEqual(decide((54, 37), last: (106, 9), layout: portrait, focus: PaneId(4), memo: &memo), .reproject)
        // The same stale client size against a peer-sized window is still a
        // peer's grid, not a reason to reclaim.
        XCTAssertEqual(
            TmuxCompactClientSizing.reprojection(
                viewport: (columns: 54, rows: 37),
                lastClientSize: (columns: 106, rows: 9),
                layout: nil,
                focusPaneId: nil,
                windowRect: CellRect(width: 166, height: 54, x: 0, y: 0),
                focusRect: CellRect(width: 166, height: 54, x: 0, y: 0),
                memo: &memo
            ),
            .hold
        )
    }

    /// A split on this device's own canvas reprojects once, the layout it
    /// produces settles, and closing the pane is one correction back.
    func testSplitOnOwnCanvasReprojectsOnceAndSettles() {
        let viewport = (columns: 50, rows: 30)
        var memo = TmuxCompactReprojectionMemo()
        // Settled single pane at the phone grid, then `split-window -h`. The
        // advertisement is still the bare phone grid, so this is the
        // hydration rule, not a correction.
        let single = WindowLayout.parse("0000,50x30,0,0,1")!
        XCTAssertEqual(decide(viewport, last: (50, 30), layout: single, focus: PaneId(1), memo: &memo), .hold)
        let split = WindowLayout.parse("0000,50x30,0,0{25x30,0,0,1,24x30,26,0,2}")!
        XCTAssertEqual(decide(viewport, last: (50, 30), layout: split, focus: PaneId(2), memo: &memo), .reproject)
        XCTAssertEqual(memo.corrections, 0)
        let advertised = project(viewport, split, PaneId(2))
        let landed = TmuxLayoutReference.resized(split, toColumns: advertised.columns, rows: advertised.rows)
        XCTAssertEqual(landed.rect(ofPane: PaneId(2))?.width, 50)
        XCTAssertEqual(decide(viewport, last: advertised, layout: landed, focus: PaneId(2), memo: &memo), .hold)
        XCTAssertEqual(memo.corrections, 0)
        // Closing the pane is another layout: one correction back to the grid.
        let closed = WindowLayout.parse("0000,\(advertised.columns)x30,0,0,1")!
        XCTAssertEqual(decide(viewport, last: advertised, layout: closed, focus: PaneId(1), memo: &memo), .reproject)
        XCTAssertEqual(memo.corrections, 1)
        XCTAssertEqual(project(viewport, closed, PaneId(1)).columns, 50)
    }

    /// The probe's two-cycle (45 of 200 columns) on the ratio fallback, the
    /// path a client without a layout tree still takes: the guard stops it
    /// after `maximumUnsettledCorrections` corrections.
    func testCycleGuardStopsTheRatioFallbackTwoCycle() {
        let start = LayoutResizeModelTests.twoPane(columns: 200, rows: 40, rightPane: 45)
        let run = runClientLoop(viewport: (50, 40), start: start, focus: PaneId(1), useTree: false) { layout, size, _ in
            TmuxLayoutReference.resized(layout, toColumns: size.columns, rows: size.rows)
        }
        XCTAssertEqual(run.advertisements.map(\.columns), [223, 200, 223, 200])
        XCTAssertEqual(run.finalDecision, .holdCycle)
        XCTAssertEqual(
            run.advertisements.count,
            1 + TmuxCompactClientSizing.maximumUnsettledCorrections
        )
    }

    /// A tmux that hands the focused pane one cell more, then one fewer,
    /// than the model predicts can never settle. The guard bounds the storm,
    /// also when unrelated updates (a pane title, a stale layout) are judged
    /// between an advertisement and tmux applying it.
    func testCycleGuardBoundsAModelMismatchEvenWithUpdatesInBetween() throws {
        for unrelatedUpdates in [false, true] {
            let start = LayoutResizeModelTests.twoPane(columns: 200, rows: 40, rightPane: 59)
            let run = runClientLoop(
                viewport: (50, 40),
                start: start,
                focus: PaneId(1),
                unrelatedUpdates: unrelatedUpdates
            ) { _, size, step in
                // Off by one, alternating.
                LayoutResizeModelTests.twoPane(
                    columns: size.columns,
                    rows: size.rows,
                    rightPane: 50 + (step.isMultiple(of: 2) ? 1 : -1)
                )
            }
            XCTAssertEqual(
                run.advertisements.count,
                1 + TmuxCompactClientSizing.maximumUnsettledCorrections,
                "unrelated updates \(unrelatedUpdates)"
            )
            XCTAssertEqual(run.finalDecision, .holdCycle)
            // Held, and holding again is quiet: the memo reports it once.
            let lastAdvertised = try XCTUnwrap(run.advertisements.last)
            var memo = run.memo
            let before = memo
            XCTAssertEqual(
                decide((50, 40), last: lastAdvertised, layout: run.layout, focus: PaneId(1), memo: &memo),
                .holdCycle
            )
            XCTAssertEqual(memo, before)
        }
    }

    func testANewShapeFocusOrViewportStartsAFreshCorrectionCount() {
        let viewport = (columns: 50, rows: 40)
        // tmux answering each correction with a window one column off, as in
        // the model-mismatch test: every answer is a resize of this layout.
        func answer(_ step: Int) -> WindowLayout {
            LayoutResizeModelTests.twoPane(columns: 120 + step % 2, rows: 40, rightPane: 40 + step % 2)
        }
        var memo = TmuxCompactReprojectionMemo()
        for step in 0..<TmuxCompactClientSizing.maximumUnsettledCorrections {
            XCTAssertEqual(decide(viewport, last: (120 + step % 2, 40), layout: answer(step), focus: PaneId(1), memo: &memo), .reproject)
        }
        let held = TmuxCompactClientSizing.maximumUnsettledCorrections
        XCTAssertEqual(decide(viewport, last: (120 + held % 2, 40), layout: answer(held), focus: PaneId(1), memo: &memo), .holdCycle)
        XCTAssertTrue(memo.isHoldingCycle)
        let layout = answer(held)
        let last = (columns: 120 + held % 2, rows: 40)
        // Focusing the other pane, rotating, or changing the tree is a new
        // layout to fit.
        var focusMemo = memo
        XCTAssertEqual(decide(viewport, last: last, layout: layout, focus: PaneId(0), memo: &focusMemo), .reproject)
        XCTAssertEqual(focusMemo.corrections, 1)
        var viewportMemo = memo
        XCTAssertEqual(decide((52, 40), last: last, layout: layout, focus: PaneId(1), memo: &viewportMemo), .reproject)
        var shapeMemo = memo
        let stacked = WindowLayout.parse("0000,121x40,0,0{80x40,0,0,0,40x40,81,0[40x20,81,0,1,40x19,81,21,2]}")!
        XCTAssertEqual(decide(viewport, last: last, layout: stacked, focus: PaneId(1), memo: &shapeMemo), .reproject)
        // Only the shape counts, not the sizes a correction changes: tmux
        // resizing the same tree again is still the held cycle.
        var sizeMemo = memo
        let resized = LayoutResizeModelTests.twoPane(columns: 122, rows: 40, rightPane: 42)
        XCTAssertEqual(decide(viewport, last: (122, 40), layout: resized, focus: PaneId(1), memo: &sizeMemo), .holdCycle)
    }

    /// Android judges on every runtime event, `%output` included. Judging
    /// the same inputs again must give the same answer and leave the memo
    /// alone, or an advertisement that is withheld (background, a hidden
    /// tab, an authority read in flight) or waits for a Mosh ownership proof
    /// turns into a held cycle within four events.
    func testJudgingTheSameInputsAgainChangesNothing() throws {
        let viewport = (columns: 50, rows: 40)
        // A settled 210-column canvas, then a pane closes on it.
        let three = try XCTUnwrap(WindowLayout.parse("0000,210x40,0,0{100x40,0,0,0,58x40,101,0,2,50x40,160,0,1}"))
        var memo = TmuxCompactReprojectionMemo()
        XCTAssertEqual(decide(viewport, last: (210, 40), layout: three, focus: PaneId(1), memo: &memo), .hold)
        let closed = try XCTUnwrap(WindowLayout.parse("0000,210x40,0,0{100x40,0,0,0,109x40,101,0,1}"))
        XCTAssertEqual(decide(viewport, last: (210, 40), layout: closed, focus: PaneId(1), memo: &memo), .reproject)
        let judged = memo
        for _ in 0..<10 {
            XCTAssertEqual(decide(viewport, last: (210, 40), layout: closed, focus: PaneId(1), memo: &memo), .reproject)
            XCTAssertEqual(memo, judged)
        }
        // Once it does go out, tmux's answer settles it.
        let advertised = project(viewport, closed, PaneId(1))
        let landed = TmuxLayoutReference.resized(closed, toColumns: advertised.columns, rows: advertised.rows)
        XCTAssertEqual(decide(viewport, last: advertised, layout: landed, focus: PaneId(1), memo: &memo), .hold)
        XCTAssertEqual(memo.corrections, 0)
        XCTAssertEqual(landed.rect(ofPane: PaneId(1))?.width, 50)

        // A held cycle judged again stays held, without reporting again.
        let run = runClientLoop(viewport: viewport, start: closed, focus: PaneId(1)) { _, size, step in
            LayoutResizeModelTests.twoPane(columns: size.columns, rows: size.rows, rightPane: 50 + (step.isMultiple(of: 2) ? 1 : -1))
        }
        XCTAssertEqual(run.finalDecision, .holdCycle)
        var held = run.memo
        let lastAdvertised = try XCTUnwrap(run.advertisements.last)
        for _ in 0..<5 {
            XCTAssertEqual(decide(viewport, last: lastAdvertised, layout: run.layout, focus: PaneId(1), memo: &held), .holdCycle)
            XCTAssertEqual(held, run.memo)
        }
    }

    /// Another client dragging a divider on this device's canvas (a desktop
    /// client, a script, a key-repeated `resize-pane`) moves panes without
    /// resizing the window, several times per round trip of this device's
    /// advertisements. Those edits are not tmux answering a correction, so
    /// they never add up to a held cycle, and once the drag stops the
    /// focused pane lands back on the device grid.
    func testAnotherClientsDividerDragNeverFreezesTheCanvas() {
        for (dragTicks, step, movesPerTick) in [
            (6, 1, 2), (12, 1, 2), (6, 1, 3), (12, 1, 4), (6, -1, 2), (12, -1, 3), (20, 1, 8), (20, -1, 8),
        ] {
            let context = "ticks \(dragTicks) step \(step) moves \(movesPerTick)"
            var layout = LayoutResizeModelTests.twoPane(columns: 200, rows: 40, rightPane: 50)
            var last = (columns: 200, rows: 40)
            var memo = TmuxCompactReprojectionMemo()
            var pending: (columns: Int, rows: Int)?
            var final = TmuxCompactReprojection.hold
            func judge() {
                final = decide((50, 40), last: last, layout: layout, focus: PaneId(1), memo: &memo)
                XCTAssertNotEqual(final, .holdCycle, context)
                if final == .reproject {
                    last = project((50, 40), layout, PaneId(1))
                    pending = last
                }
            }
            for tick in 0..<(dragTicks + 6) {
                // This device's latest advertisement lands one tick later.
                if let advertised = pending {
                    pending = nil
                    layout = TmuxLayoutReference.resized(layout, toColumns: advertised.columns, rows: advertised.rows)
                    judge()
                }
                if tick < dragTicks {
                    for _ in 0..<movesPerTick {
                        let window = layout.root.rect.width
                        let right = max(1, min(window - 2, layout.rect(ofPane: PaneId(1))!.width + step))
                        layout = LayoutResizeModelTests.twoPane(columns: window, rows: 40, rightPane: right)
                        judge()
                    }
                }
            }
            XCTAssertNil(pending, context)
            XCTAssertEqual(final, .hold, context)
            XCTAssertEqual(layout.rect(ofPane: PaneId(1))?.width, 50, context)
            XCTAssertEqual(layout.root.rect.width, last.columns, context)
        }
    }

    /// A held cycle ends when someone edits the layout: that is a new
    /// arrangement to fit, and it buys at most the usual corrections.
    func testAnEditReleasesAHeldCycle() throws {
        let start = LayoutResizeModelTests.twoPane(columns: 200, rows: 40, rightPane: 59)
        let run = runClientLoop(viewport: (50, 40), start: start, focus: PaneId(1)) { _, size, step in
            LayoutResizeModelTests.twoPane(columns: size.columns, rows: size.rows, rightPane: 50 + (step.isMultiple(of: 2) ? 1 : -1))
        }
        XCTAssertEqual(run.finalDecision, .holdCycle)
        XCTAssertTrue(run.memo.isHoldingCycle)
        let lastAdvertised = try XCTUnwrap(run.advertisements.last)
        var memo = run.memo
        let edited = LayoutResizeModelTests.twoPane(columns: run.layout.root.rect.width, rows: 40, rightPane: 70)
        XCTAssertEqual(decide((50, 40), last: lastAdvertised, layout: edited, focus: PaneId(1), memo: &memo), .reproject)
        XCTAssertEqual(memo.corrections, 0)
        XCTAssertFalse(memo.isHoldingCycle)
    }

    /// An edit seen while this device's advertisement is still in flight
    /// reads as a peer's window (the window is far from the advertisement)
    /// and holds, but it is still an edit: the corrections before it do not
    /// carry over into the arrangement it made.
    func testAnEditSeenWhileAnAdvertisementIsInFlightStartsTheCountOver() {
        let viewport = (columns: 50, rows: 40)
        func pane(_ window: Int, _ right: Int) -> WindowLayout {
            LayoutResizeModelTests.twoPane(columns: window, rows: 40, rightPane: right)
        }
        var memo = TmuxCompactReprojectionMemo()
        // The ratio fallback's two-cycle, up to the last correction it may
        // make: 223 is in flight.
        XCTAssertEqual(decide(viewport, last: (50, 40), layout: pane(200, 45), focus: PaneId(1), useTree: false, memo: &memo), .reproject)
        XCTAssertEqual(decide(viewport, last: (223, 40), layout: pane(223, 56), focus: PaneId(1), useTree: false, memo: &memo), .reproject)
        XCTAssertEqual(decide(viewport, last: (200, 40), layout: pane(200, 45), focus: PaneId(1), useTree: false, memo: &memo), .reproject)
        XCTAssertEqual(decide(viewport, last: (223, 40), layout: pane(223, 56), focus: PaneId(1), useTree: false, memo: &memo), .reproject)
        XCTAssertEqual(memo.corrections, TmuxCompactClientSizing.maximumUnsettledCorrections)
        // Someone drags the divider on the 223-column window before tmux
        // applies the 200 in flight.
        XCTAssertEqual(decide(viewport, last: (200, 40), layout: pane(223, 60), focus: PaneId(1), useTree: false, memo: &memo), .hold)
        XCTAssertEqual(memo.corrections, 0)
        // The 200 lands (not an answer to anything since the edit), the
        // next correction goes out, and tmux's answer to it is the first
        // correction of the new arrangement, not a stop.
        XCTAssertEqual(decide(viewport, last: (200, 40), layout: pane(200, 54), focus: PaneId(1), useTree: false, memo: &memo), .reproject)
        XCTAssertEqual(decide(viewport, last: (186, 40), layout: pane(186, 49), focus: PaneId(1), useTree: false, memo: &memo), .reproject)
        XCTAssertEqual(memo.corrections, 1)
    }

    func testMemoRoundTripsThroughItsRawValue() {
        var memo = TmuxCompactReprojectionMemo(signature: 0xDEAD_BEEF)
        _ = memo.record(
            window: CellRect(width: 10_000, height: 213, x: 0, y: 0),
            layoutHash: 0x1234_5678,
            lastClientSize: (9_999, 212)
        )
        memo.corrections = TmuxCompactClientSizing.maximumUnsettledCorrections + 1
        let restored = TmuxCompactReprojectionMemo(rawValue: memo.rawValue)
        XCTAssertEqual(restored, memo)
        XCTAssertEqual(restored.signature, 0xDEAD_BEEF)
        XCTAssertEqual(restored.layoutHash, 0x1234_5678)
        XCTAssertEqual(restored.windowColumns, 10_000)
        XCTAssertEqual(restored.windowRows, 213)
        XCTAssertEqual(restored.advertisedColumns, 9_999)
        XCTAssertEqual(restored.advertisedRows, 212)
        XCTAssertTrue(restored.hasLayout)
        XCTAssertTrue(restored.isHoldingCycle)
        XCTAssertEqual(TmuxCompactReprojectionMemo(rawValue: (0, 0)), TmuxCompactReprojectionMemo())
        XCTAssertFalse(TmuxCompactReprojectionMemo().isHoldingCycle)

        // Sizes no tmux produces keep the packing intact by clamping.
        var huge = TmuxCompactReprojectionMemo()
        _ = huge.record(
            window: CellRect(width: 70_000, height: -3, x: 0, y: 0),
            layoutHash: 1,
            lastClientSize: (65_535, 20_000)
        )
        let unpacked = TmuxCompactReprojectionMemo(rawValue: huge.rawValue)
        XCTAssertEqual(unpacked, huge)
        XCTAssertEqual(unpacked.windowColumns, 0x3fff)
        XCTAssertEqual(unpacked.windowRows, 0)
        XCTAssertEqual(unpacked.advertisedColumns, 0x3fff)
        XCTAssertEqual(unpacked.advertisedRows, 0x3fff)
    }

    /// An advertisement the platform withholds (background, a hidden tab, a
    /// peer's grid, an authority read in flight) or that waits for a Mosh
    /// ownership proof never reaches tmux, so window resizes that arrive
    /// meanwhile are not answers to it. However many there are, they never
    /// add up to a held cycle; once the advertisement goes out, its landing
    /// settles. The same resizes answering advertisements that did go out
    /// are a cycle the guard stops.
    func testWindowResizesWhileAnAdvertisementIsWithheldAreNotCorrections() throws {
        let viewport = (columns: 50, rows: 40)
        // tmux recalculating the window a cell either way of this device's
        // canvas with the focused pane off the grid: our canvas each time.
        func drifted(_ step: Int) -> WindowLayout {
            LayoutResizeModelTests.twoPane(columns: 201 + step % 2, rows: 40, rightPane: 45)
        }
        var memo = TmuxCompactReprojectionMemo()
        let settled = LayoutResizeModelTests.twoPane(columns: 200, rows: 40, rightPane: 50)
        XCTAssertEqual(decide(viewport, last: (200, 40), layout: settled, focus: PaneId(1), memo: &memo), .hold)
        for step in 0..<12 {
            XCTAssertEqual(
                decide(viewport, last: (200, 40), layout: drifted(step), focus: PaneId(1), memo: &memo),
                .reproject,
                "step \(step)"
            )
            XCTAssertEqual(memo.corrections, 0, "step \(step)")
        }
        let layout = drifted(11)
        let advertised = project(viewport, layout, PaneId(1))
        let landed = TmuxLayoutReference.resized(layout, toColumns: advertised.columns, rows: advertised.rows)
        XCTAssertEqual(landed.rect(ofPane: PaneId(1))?.width, 50)
        XCTAssertEqual(decide(viewport, last: advertised, layout: landed, focus: PaneId(1), memo: &memo), .hold)

        // Each resize following an advertisement that went out counts.
        var counted = TmuxCompactReprojectionMemo()
        XCTAssertEqual(decide(viewport, last: (200, 40), layout: settled, focus: PaneId(1), memo: &counted), .hold)
        var decisions: [TmuxCompactReprojection] = []
        for step in 0..<6 {
            decisions.append(decide(viewport, last: (202 - step % 2, 40), layout: drifted(step), focus: PaneId(1), memo: &counted))
        }
        let cap = TmuxCompactClientSizing.maximumUnsettledCorrections
        XCTAssertEqual(decisions, Array(repeating: .reproject, count: cap) + Array(repeating: .holdCycle, count: 6 - cap))
    }

    /// A held peer layout may arrive between every publication and its
    /// answer. It is an observation, never evidence that our publication was
    /// answered. The exact 200/49 -> 203/51 mismatch used to run forever.
    func testHeldPeerLayoutsCannotConsumeOutstandingPublications() {
        exerciseInterleavedPeerLayouts(vertical: false, useTree: true, peerUpdates: 1)
    }

    func testRepeatedAndChangingPeerLayoutsStillBoundCorrections() {
        exerciseInterleavedPeerLayouts(vertical: false, useTree: true, peerUpdates: 4)
    }

    func testHeldPeerLayoutsPreserveVerticalPublicationEvidence() {
        exerciseInterleavedPeerLayouts(vertical: true, useTree: true, peerUpdates: 3)
    }

    func testHeldPeerLayoutsPreserveRatioFallbackPublicationEvidence() {
        exerciseInterleavedPeerLayouts(vertical: false, useTree: false, peerUpdates: 2)
    }

    func testOnePublicationIsConsumedOnlyByItsFirstEligibleAnswer() {
        var memo = TmuxCompactReprojectionMemo()
        let settled = LayoutResizeModelTests.twoPane(columns: 200, rows: 40, rightPane: 50)
        XCTAssertEqual(decide((50, 40), last: (200, 40), layout: settled, focus: PaneId(1), memo: &memo), .hold)
        let peer = LayoutResizeModelTests.twoPane(columns: 1_000, rows: 40, rightPane: 400)
        for step in 0..<40 {
            XCTAssertEqual(decide((50, 40), last: (202, 40), layout: peer, focus: PaneId(1), memo: &memo), .hold)
            let answer = LayoutResizeModelTests.twoPane(columns: 201 + step % 2, rows: 40, rightPane: 49)
            XCTAssertEqual(decide((50, 40), last: (202, 40), layout: answer, focus: PaneId(1), memo: &memo), .reproject)
            XCTAssertEqual(memo.corrections, 1, "no further publication went out at step \(step)")
        }
    }

    func testSettledPublicationDoesNotCountLaterPeerResizes() {
        var memo = TmuxCompactReprojectionMemo()
        for columns in [200, 202] {
            let settled = LayoutResizeModelTests.twoPane(columns: columns, rows: 40, rightPane: 50)
            XCTAssertEqual(decide((50, 40), last: (columns, 40), layout: settled, focus: PaneId(1), memo: &memo), .hold)
        }
        let peer = LayoutResizeModelTests.twoPane(columns: 1_000, rows: 40, rightPane: 400)
        XCTAssertEqual(decide((50, 40), last: (202, 40), layout: peer, focus: PaneId(1), memo: &memo), .hold)
        let drifted = LayoutResizeModelTests.twoPane(columns: 201, rows: 40, rightPane: 49)
        XCTAssertEqual(decide((50, 40), last: (202, 40), layout: drifted, focus: PaneId(1), memo: &memo), .reproject)
        XCTAssertEqual(memo.corrections, 0, "the already settled publication is no longer outstanding")
    }

    private func exerciseInterleavedPeerLayouts(
        vertical: Bool,
        useTree: Bool,
        peerUpdates: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func layout(_ window: Int, _ focus: Int) -> WindowLayout {
            if vertical {
                return WindowLayout.parse("0000,40x\(window),0,0[40x\(window - focus - 1),0,0,0,40x\(focus),0,\(window - focus),1]")!
            }
            return LayoutResizeModelTests.twoPane(columns: window, rows: 40, rightPane: focus)
        }
        let viewport = vertical ? (columns: 40, rows: 50) : (columns: 50, rows: 40)
        var last = vertical ? (columns: 40, rows: 200) : (columns: 200, rows: 40)
        var memo = TmuxCompactReprojectionMemo()
        var advertisements: [Int] = []
        var stopped = false
        for step in 0..<40 {
            let window = useTree ? (step.isMultiple(of: 2) ? 200 : 203) : (step.isMultiple(of: 2) ? 200 : 223)
            let focus = useTree ? (step.isMultiple(of: 2) ? 49 : 51) : (step.isMultiple(of: 2) ? 45 : 56)
            let own = layout(window, focus)
            let decision = decide(viewport, last: last, layout: own, focus: PaneId(1), useTree: useTree, memo: &memo)
            if decision == .reproject {
                XCTAssertFalse(stopped, "a held cycle restarted", file: file, line: line)
                last = useTree ? project(viewport, own, PaneId(1)) : TmuxCompactClientSizing.clientSize(
                    viewport: viewport, windowRect: own.root.rect, focusRect: own.rect(ofPane: PaneId(1))
                )
                advertisements.append(vertical ? last.rows : last.columns)
            } else {
                if !stopped {
                    XCTAssertEqual(decision, .holdCycle, file: file, line: line)
                }
                stopped = stopped || decision == .holdCycle
            }
            let publicationEvidence = (memo.advertisedColumns, memo.advertisedRows)
            for peerStep in 0..<peerUpdates {
                // Includes repeated identical snapshots and successive peer
                // resizes. Cross the native ABI's two-word memo boundary too.
                memo = TmuxCompactReprojectionMemo(rawValue: memo.rawValue)
                let peer = layout(1_000 + peerStep / 2, 400)
                XCTAssertEqual(decide(viewport, last: last, layout: peer, focus: PaneId(1), useTree: useTree, memo: &memo), .hold, file: file, line: line)
                XCTAssertEqual(memo.advertisedColumns, publicationEvidence.0, file: file, line: line)
                XCTAssertEqual(memo.advertisedRows, publicationEvidence.1, file: file, line: line)
            }
        }
        XCTAssertTrue(stopped, file: file, line: line)
        XCTAssertEqual(advertisements.count, TmuxCompactClientSizing.maximumUnsettledCorrections, file: file, line: line)
        XCTAssertEqual(Array(advertisements.prefix(3)), useTree ? [202, 200, 202] : [223, 200, 223], file: file, line: line)
    }

    func testObservationKeyIncludesShapeWhenWindowAndFocusRectanglesMatch() throws {
        let nested = try XCTUnwrap(WindowLayout.parse("0000,200x40,0,0{100x40,0,0,0,99x40,101,0{58x40,101,0,2,40x40,160,0,1}}"))
        let flat = try XCTUnwrap(WindowLayout.parse("0000,200x40,0,0{100x40,0,0,0,58x40,101,0,2,40x40,160,0,1}"))
        let focus = PaneId(1)
        XCTAssertEqual(nested.root.rect, flat.root.rect)
        XCTAssertEqual(nested.rect(ofPane: focus), flat.rect(ofPane: focus))
        func key(_ layout: WindowLayout) -> String {
            TmuxCompactClientSizing.observationKey(mode: "tmuxControl", windowId: WindowId(0), focusPaneId: focus,
                layout: layout, windowRect: layout.root.rect, focusRect: layout.rect(ofPane: focus))
        }
        XCTAssertNotEqual(key(nested), key(flat), "SSH must observe a shape-only layout change")
        XCTAssertEqual(key(flat), key(flat))
        XCTAssertEqual(project((50, 40), nested, focus).columns, 200)
        XCTAssertEqual(project((50, 40), flat, focus).columns, 230)
        let landed = TmuxLayoutReference.resized(flat, toColumns: 230, rows: 40)
        XCTAssertEqual(landed.rect(ofPane: focus)?.width, 50)
    }

    // MARK: - Helpers

    private func project(
        _ viewport: (columns: Int, rows: Int),
        _ layout: WindowLayout,
        _ focus: PaneId
    ) -> (columns: Int, rows: Int) {
        TmuxCompactClientSizing.clientSize(
            viewport: viewport,
            layout: layout,
            focusPaneId: focus,
            windowRect: layout.root.rect,
            focusRect: layout.rect(ofPane: focus)
        )
    }

    private func decide(
        _ viewport: (columns: Int, rows: Int),
        last: (columns: Int, rows: Int)?,
        layout: WindowLayout,
        focus: PaneId,
        useTree: Bool = true,
        memo: inout TmuxCompactReprojectionMemo
    ) -> TmuxCompactReprojection {
        TmuxCompactClientSizing.reprojection(
            viewport: viewport,
            lastClientSize: last,
            layout: useTree ? layout : nil,
            focusPaneId: useTree ? focus : nil,
            windowRect: layout.root.rect,
            focusRect: layout.rect(ofPane: focus),
            memo: &memo
        )
    }

    /// What both platforms do: judge each layout update, advertise when told
    /// to, and let `tmux` turn the advertisement into the next layout. Starts
    /// hydrating (only the physical viewport advertised) and stops at the
    /// first hold, or after 50 advertisements.
    private func runClientLoop(
        viewport: (columns: Int, rows: Int),
        start: WindowLayout,
        focus: PaneId,
        useTree: Bool = true,
        unrelatedUpdates: Bool = false,
        tmux: (WindowLayout, (columns: Int, rows: Int), Int) -> WindowLayout
    ) -> (
        advertisements: [(columns: Int, rows: Int)],
        finalDecision: TmuxCompactReprojection,
        memo: TmuxCompactReprojectionMemo,
        layout: WindowLayout
    ) {
        var layout = start
        var last: (columns: Int, rows: Int) = viewport
        var memo = TmuxCompactReprojectionMemo()
        var advertisements: [(columns: Int, rows: Int)] = []
        for step in 0..<50 {
            let decision = decide(viewport, last: last, layout: layout, focus: focus, useTree: useTree, memo: &memo)
            guard decision == .reproject else {
                return (advertisements, decision, memo, layout)
            }
            last = useTree
                ? project(viewport, layout, focus)
                : TmuxCompactClientSizing.clientSize(
                    viewport: viewport,
                    windowRect: layout.root.rect,
                    focusRect: layout.rect(ofPane: focus)
                )
            advertisements.append(last)
            if unrelatedUpdates {
                // tmux has not applied it yet: the old layout again.
                let corrections = memo.corrections
                XCTAssertEqual(
                    decide(viewport, last: last, layout: layout, focus: focus, useTree: useTree, memo: &memo),
                    .hold
                )
                XCTAssertEqual(memo.corrections, corrections)
            }
            layout = tmux(layout, last, step)
        }
        return (advertisements, .reproject, memo, layout)
    }
}

extension CompactClientSizingTests {
    func testObservationKeyIncludesUnfocusedPaneOrigins() throws {
        let a = try XCTUnwrap(WindowLayout.parse(
            "0000,204x40,0,0{75x40,0,0,0,76x40,76,0,1,51x40,153,0,2}"
        ))
        let b = try XCTUnwrap(WindowLayout.parse(
            "0000,204x40,0,0{75x40,1,0,0,76x40,77,0,1,51x40,153,0,2}"
        ))
        func key(_ layout: WindowLayout) -> String {
            TmuxCompactClientSizing.observationKey(mode: "tmuxControl", windowId: WindowId(0),
                focusPaneId: PaneId(2), layout: layout, windowRect: layout.root.rect,
                focusRect: layout.rect(ofPane: PaneId(2)))
        }
        XCTAssertEqual(a.root.rect, b.root.rect)
        XCTAssertEqual(a.rect(ofPane: PaneId(2)), b.rect(ofPane: PaneId(2)))
        XCTAssertNotEqual(key(a), key(b), "observe full pane rectangles, including origins")
    }

    func testObservationKeyIncludesUnfocusedPaneSizes() throws {
        let a = try XCTUnwrap(WindowLayout.parse(
            "0000,204x40,0,0{75x40,0,0,0,76x40,76,0,1,51x40,153,0,2}"
        ))
        let b = try XCTUnwrap(WindowLayout.parse(
            "0000,204x40,0,0{1x40,0,0,0,150x40,2,0,1,51x40,153,0,2}"
        ))
        let focus = PaneId(2)

        XCTAssertEqual(a.root.rect, b.root.rect)
        XCTAssertEqual(a.rect(ofPane: focus), b.rect(ofPane: focus))
        XCTAssertEqual(project((50, 40), a, focus).columns, 199)
        XCTAssertEqual(project((50, 40), b, focus).columns, 201)

        func key(_ layout: WindowLayout) -> String {
            TmuxCompactClientSizing.observationKey(
                mode: "tmuxControl",
                windowId: WindowId(0),
                focusPaneId: focus,
                layout: layout,
                windowRect: layout.root.rect,
                focusRect: layout.rect(ofPane: focus)
            )
        }
        XCTAssertNotEqual(key(a), key(b))
    }
}
