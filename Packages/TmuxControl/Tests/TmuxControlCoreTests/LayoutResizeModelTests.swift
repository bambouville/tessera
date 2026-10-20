import XCTest
@testable import TmuxControlCore

/// Pins the tmux resize port to real tmux 3.6a and the production model to the
/// port.
final class LayoutResizeModelTests: XCTestCase {
    // MARK: - The measured bug

    /// What real tmux 3.6a did, measured on a disposable server with the
    /// ratio projection Tessera shipped: a 200x40 window split left|right,
    /// the right pane focused, a 50-column phone, and `resize-window -x` to
    /// each projection in turn (the same `layout_resize` a control client's
    /// `refresh-client -C` reaches under `window-size latest`). The probe
    /// clamped requests to 1000 columns. Entries are window/focused-pane
    /// columns before each resize.
    func testRatioProjectionAgainstTmuxResizeReproducesTheMeasuredSequences() {
        // 99 of 200: settles after one resize.
        let settled = ratioProbe(rightPane: 99)
        XCTAssertEqual(settled.observed, ["200/99", "102/50"])
        XCTAssertTrue(settled.stable)

        // 59 of 200: eleven resizes before it settles.
        let slow = ratioProbe(rightPane: 59)
        XCTAssertEqual(slow.observed, [
            "200/59", "170/44", "194/56", "174/46", "190/54", "176/47",
            "188/53", "178/48", "186/52", "179/49", "183/51", "180/50",
        ])
        XCTAssertTrue(slow.stable)
        XCTAssertEqual(slow.resizes, 11)

        // 45 of 200: a two-cycle, forever.
        let twoCycle = ratioProbe(rightPane: 45, steps: 40)
        XCTAssertFalse(twoCycle.stable)
        XCTAssertEqual(Array(twoCycle.observed.prefix(4)), ["200/45", "223/56", "200/45", "223/56"])
        XCTAssertEqual(Set(twoCycle.observed), ["200/45", "223/56"])

        // 30 of 200: diverges to the clamp, then cycles 113 <-> 1000 forever.
        let divergent = ratioProbe(rightPane: 30, steps: 40)
        XCTAssertFalse(divergent.stable)
        XCTAssertEqual(Array(divergent.observed.prefix(10)), [
            "200/30", "334/97", "173/17", "509/185", "138/1",
            "1000/432", "116/1", "1000/443", "113/1", "1000/444",
        ])
        XCTAssertEqual(Set(divergent.observed.dropFirst(8)), ["113/1", "1000/444"])
    }

    /// The same four cases through the solved projection: one advertisement,
    /// the focused pane exactly 50 columns, and reprojecting changes nothing.
    func testSolvedProjectionLandsEveryMeasuredCaseInOneAdvertisement() {
        for (rightPane, expectedWindow) in [(99, 101), (59, 181), (45, 210), (30, 240)] {
            let start = Self.twoPane(columns: 200, rows: 40, rightPane: rightPane)
            let projected = TmuxCompactClientSizing.clientSize(
                viewport: (50, 40),
                layout: start,
                focusPaneId: PaneId(1),
                windowRect: start.root.rect,
                focusRect: start.rect(ofPane: PaneId(1))
            )
            XCTAssertEqual(projected.columns, expectedWindow, "right pane \(rightPane)")
            XCTAssertEqual(projected.rows, 40)

            let landed = TmuxLayoutReference.resized(start, toColumns: projected.columns, rows: projected.rows)
            XCTAssertEqual(landed.root.rect.width, expectedWindow)
            XCTAssertEqual(landed.rect(ofPane: PaneId(1))?.width, 50, "right pane \(rightPane)")

            let again = TmuxCompactClientSizing.clientSize(
                viewport: (50, 40),
                layout: landed,
                focusPaneId: PaneId(1),
                windowRect: landed.root.rect,
                focusRect: landed.rect(ofPane: PaneId(1))
            )
            XCTAssertEqual(again.columns, projected.columns, "right pane \(rightPane)")
            XCTAssertEqual(again.rows, projected.rows)
        }
    }

    // MARK: - Port fidelity

    func testReferenceDistributesRoundRobinFromTheFirstChild() {
        // Grow 3 over {A,B}: A gets the odd cell. Shrink 3: A gives the odd
        // cell.
        let start = Self.twoPane(columns: 21, rows: 5, rightPane: 10)
        XCTAssertEqual(widths(TmuxLayoutReference.resized(start, toColumns: 24, rows: 5)), [12, 11])
        XCTAssertEqual(widths(TmuxLayoutReference.resized(start, toColumns: 18, rows: 5)), [8, 9])
        // Shrink past B's minimum: B stops at 1 and A gives the rest.
        let uneven = Self.twoPane(columns: 21, rows: 5, rightPane: 5)
        XCTAssertEqual(widths(TmuxLayoutReference.resized(uneven, toColumns: 9, rows: 5)), [7, 1])
        // Nothing can shrink below 1+1+1: the window stays at the layout.
        let floor = TmuxLayoutReference(start)
        let window = floor.resize_window(2, 5)
        XCTAssertEqual(window.sx, 3)
        XCTAssertEqual(widths(floor.layout), [1, 1])
    }

    func testReferenceHandsAPerpendicularSplitTheWholeChange() {
        // {A,[B,C]} widened by 4: A and the stack split it 2/2, and both B
        // and C inside the stack get the stack's whole 2.
        let layout = WindowLayout.parse("0000,41x20,0,0{20x20,0,0,1,20x20,21,0[20x10,21,0,2,20x9,21,11,3]}")!
        let grown = TmuxLayoutReference.resized(layout, toColumns: 45, rows: 20)
        XCTAssertEqual(grown.leaves.map(\.rect.width), [22, 22, 22])
        // Shrinking rows only touches the stack: B then C, round-robin.
        let shorter = TmuxLayoutReference.resized(layout, toColumns: 41, rows: 17)
        XCTAssertEqual(shorter.leaves.map(\.rect.height), [17, 8, 8])
    }

    func testReferenceKeepsAPaneStatusLineRowOnTheTopmostPanes() {
        let layout = WindowLayout.parse("0000,20x7,0,0[20x3,0,0,1,20x3,0,4,2]")!
        let top = TmuxLayoutReference.resized(
            layout,
            toColumns: 20,
            rows: 1,
            options: TmuxLayoutResizeOptions(paneBorderStatus: .top)
        )
        XCTAssertEqual(top.leaves.map(\.rect.height), [2, 1])
        let bottom = TmuxLayoutReference.resized(
            layout,
            toColumns: 20,
            rows: 1,
            options: TmuxLayoutResizeOptions(paneBorderStatus: .bottom)
        )
        XCTAssertEqual(bottom.leaves.map(\.rect.height), [1, 2])
    }

    /// The batched model against the cell-by-cell port, every cell, both
    /// directions, on random trees of 1–6 panes (nested, uneven, some at
    /// their minimum) under every option tmux's minimum depends on.
    func testModelMatchesTheReferencePortOnRandomTrees() throws {
        var rng = SplitMix64(seed: 0x7E55_E2A0_1A70_0001)
        var compared = 0
        for trial in 0..<1_500 {
            let panes = Int.random(in: 1...6, using: &rng)
            let layout = RandomTmuxLayouts.random(panes: panes, maximumSide: 160, using: &rng)
            let options = TmuxLayoutResizeOptions(
                paneBorderStatus: [.off, .top, .bottom][Int.random(in: 0..<3, using: &rng)],
                scrollbarColumns: [0, 0, 1, 2][Int.random(in: 0..<4, using: &rng)]
            )
            let model = try XCTUnwrap(TmuxLayoutResizeModel(layout, options: options), "trial \(trial)")
            for _ in 0..<6 {
                let columns = Self.randomTarget(around: layout.root.rect.width, using: &rng)
                let rows = Self.randomTarget(around: layout.root.rect.height, using: &rng)
                let reference = TmuxLayoutReference(layout, options: options)
                reference.layout_resize(columns, rows)
                XCTAssertFalse(reference.stalled)
                let expected = reference.preorderSizes()
                let modelColumns = model.resized(.columns, to: columns)
                let modelRows = model.resized(.rows, to: rows)
                XCTAssertEqual(modelColumns, expected.map(\.sx), "trial \(trial) columns \(columns) \(layout)")
                XCTAssertEqual(modelRows, expected.map(\.sy), "trial \(trial) rows \(rows) \(layout)")
                compared += 1
            }
        }
        XCTAssertEqual(compared, 9_000)
    }

    /// The random trees must look like what tmux sends, and tmux routinely
    /// sends a split nested in one of the same direction (closing a pane,
    /// `join-pane`, `move-pane`, a restored layout). Those are where a pane
    /// after the first can never grow, so a generator that turned most of
    /// them the other way (about a quarter of trees nested, measured) hid the
    /// solver running to tmux's maximum. This one nests about half.
    func testRandomLayoutsKeepTmuxsSameDirectionNests() {
        func nested(_ node: LayoutNode, inside parent: LayoutAxis?) -> Bool {
            guard case let .split(axis, _, children) = node else { return false }
            return axis == parent || children.contains { nested($0, inside: axis) }
        }
        var rng = SplitMix64(seed: 0xC0_4AC7_51E1_2026)
        var nests = 0
        for _ in 0..<1_000 {
            let layout = RandomTmuxLayouts.random(panes: Int.random(in: 3...6, using: &rng), maximumSide: 240, using: &rng)
            if nested(layout.root, inside: nil) { nests += 1 }
        }
        XCTAssertGreaterThan(nests, 400)
    }

    func testModelRejectsLayoutsTmuxCannotSend() {
        // Children plus dividers must fill the parent along the split...
        XCTAssertNil(WindowLayout.parse("0000,80x24,0,0{40x24,0,0,1,40x24,41,0,2}").flatMap { TmuxLayoutResizeModel($0) })
        // ...and match it across.
        XCTAssertNil(WindowLayout.parse("0000,81x24,0,0{40x24,0,0,1,40x23,41,0,2}").flatMap { TmuxLayoutResizeModel($0) })
        // tmux never makes a window larger than WINDOW_MAXIMUM.
        XCTAssertNil(WindowLayout.parse("0000,10001x24,0,0,1").flatMap { TmuxLayoutResizeModel($0) })
        XCTAssertNil(WindowLayout.parse("0000,0x24,0,0,1").flatMap { TmuxLayoutResizeModel($0) })
        XCTAssertNotNil(WindowLayout.parse("0000,81x24,0,0{40x24,0,0,1,40x24,41,0,2}").flatMap { TmuxLayoutResizeModel($0) })
    }

    func testCellOnlyLayoutParsesLikeTheWireForm() {
        let cells = "200x40,0,0{140x40,0,0,1,59x40,141,0,2}"
        XCTAssertEqual(WindowLayout.parse(cellBytes: Array(cells.utf8)), WindowLayout.parse("b25d," + cells))
        XCTAssertNotNil(WindowLayout.parse(cellBytes: Array(cells.utf8)))
        XCTAssertNil(WindowLayout.parse(cellBytes: Array("b25d,\(cells)".utf8)))
        XCTAssertNil(WindowLayout.parse(cellBytes: []))
    }

    // MARK: - Helpers

    static func twoPane(columns: Int, rows: Int, rightPane: Int) -> WindowLayout {
        let left = columns - rightPane - 1
        return WindowLayout(root: .split(
            axis: .horizontal,
            rect: CellRect(width: columns, height: rows, x: 0, y: 0),
            children: [
                .leaf(paneId: PaneId(0), rect: CellRect(width: left, height: rows, x: 0, y: 0)),
                .leaf(paneId: PaneId(1), rect: CellRect(width: rightPane, height: rows, x: left + 1, y: 0)),
            ]
        ))
    }

    private func widths(_ layout: WindowLayout) -> [Int] {
        layout.leaves.map(\.rect.width)
    }

    private static func randomTarget(around current: Int, using rng: inout SplitMix64) -> Int {
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: return Int.random(in: 1...max(1, current), using: &rng)
        case 1: return Int.random(in: current...(current * 3 + 5), using: &rng)
        case 2: return current
        default: return Int.random(in: 1...400, using: &rng)
        }
    }

    /// The probe from the bug report: the ratio projection (today's fallback,
    /// clamped to 1000 as the probe did) replayed through tmux's resize.
    private func ratioProbe(
        rightPane: Int,
        steps: Int = 16
    ) -> (observed: [String], stable: Bool, resizes: Int) {
        var layout = Self.twoPane(columns: 200, rows: 40, rightPane: rightPane)
        var observed: [String] = []
        var last: Int?
        var resizes = 0
        for _ in 0..<steps {
            let window = layout.root.rect
            let focus = layout.rect(ofPane: PaneId(1))!
            observed.append("\(window.width)/\(focus.width)")
            let projected = min(
                1_000,
                TmuxCompactClientSizing.clientSize(
                    viewport: (50, 40),
                    windowRect: window,
                    focusRect: focus
                ).columns
            )
            if projected == last {
                return (observed, true, resizes)
            }
            layout = TmuxLayoutReference.resized(layout, toColumns: projected, rows: 40)
            resizes += 1
            last = projected
        }
        return (observed, false, resizes)
    }
}
