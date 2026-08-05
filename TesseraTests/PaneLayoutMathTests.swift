import XCTest
import CoreGraphics
import TmuxControl
@testable import Tessera

/// Frame-math tests for the split-pane grid (plan risk #2: a pane's terminal
/// surface MUST be an exact integer number of cells, or SwiftTerm computes a
/// different cols/rows than tmux and every live escape mis-renders). Until now
/// `PaneLayoutMath` was exercised only live; these pin the geometry.
final class PaneLayoutMathTests: XCTestCase {

    private func root(_ string: String) -> LayoutNode {
        guard let layout = WindowLayout.parse(string) else {
            fatalError("fixture layout failed to parse: \(string)")
        }
        return layout.root
    }

    private func frame(_ frames: [PaneFrame], _ pane: Int) -> PaneFrame {
        guard let f = frames.first(where: { $0.paneId == PaneId(pane) }) else {
            fatalError("no frame for pane %\(pane)")
        }
        return f
    }

    func test_compactTmuxClientSizingProjectsFocusedPaneToPhoneViewport() throws {
        let cell = CGSize(width: 10, height: 20)
        let viewport = try XCTUnwrap(
            CompactTmuxClientSizing.viewportCells(
                for: CGSize(width: 390, height: 300),
                cellSize: cell
            )
        )
        XCTAssertEqual(viewport.cols, 39)
        XCTAssertEqual(viewport.rows, 15)

        let single = CompactTmuxClientSizing.clientSize(
            for: viewport,
            windowRect: CellRect(width: 80, height: 24, x: 0, y: 0),
            focusRect: CellRect(width: 80, height: 24, x: 0, y: 0)
        )
        XCTAssertEqual(single.cols, 39)
        XCTAssertEqual(single.rows, 15)

        let leftHalf = CompactTmuxClientSizing.clientSize(
            for: viewport,
            windowRect: CellRect(width: 80, height: 24, x: 0, y: 0),
            focusRect: CellRect(width: 40, height: 24, x: 0, y: 0)
        )
        XCTAssertEqual(leftHalf.cols, 78, "a 50/50 split needs two phone widths")
        XCTAssertEqual(leftHalf.rows, 15)

        let rightHalf = CompactTmuxClientSizing.clientSize(
            for: viewport,
            windowRect: CellRect(width: 80, height: 24, x: 0, y: 0),
            focusRect: CellRect(width: 39, height: 24, x: 41, y: 0)
        )
        XCTAssertEqual(rightHalf.cols, 80, "the gutter-adjusted right pane still gets 39 columns")
        XCTAssertEqual(rightHalf.rows, 15)

        let stackedBottom = CompactTmuxClientSizing.clientSize(
            for: viewport,
            windowRect: CellRect(width: 80, height: 24, x: 0, y: 0),
            focusRect: CellRect(width: 80, height: 11, x: 0, y: 13)
        )
        XCTAssertEqual(stackedBottom.cols, 39)
        XCTAssertEqual(stackedBottom.rows, 33, "a short stacked pane expands the client height")

        XCTAssertTrue(
            CompactTmuxClientSizing.shouldReprojectLayout(
                viewport: viewport,
                lastClientSize: viewport,
                windowRect: CellRect(width: 80, height: 24, x: 0, y: 0),
                focusRect: CellRect(width: 40, height: 24, x: 0, y: 0)
            ),
            "initial split hydration must expand an unprojected phone viewport"
        )
        XCTAssertTrue(
            CompactTmuxClientSizing.shouldReprojectLayout(
                viewport: viewport,
                lastClientSize: (78, 15),
                windowRect: CellRect(width: 78, height: 15, x: 0, y: 0),
                focusRect: CellRect(width: 78, height: 15, x: 0, y: 0)
            ),
            "a local collapse on the phone-owned canvas must return to one viewport"
        )
        XCTAssertFalse(
            CompactTmuxClientSizing.shouldReprojectLayout(
                viewport: viewport,
                lastClientSize: (78, 15),
                windowRect: CellRect(width: 160, height: 50, x: 0, y: 0),
                focusRect: CellRect(width: 80, height: 50, x: 0, y: 0)
            ),
            "a larger peer layout must not make the phone reclaim tmux sizing"
        )

        XCTAssertNil(
            CompactTmuxClientSizing.viewportCells(
                for: CGSize(width: 5, height: 10),
                cellSize: cell
            ),
            "pre-layout sub-cell viewports must never resize tmux"
        )
    }

    // MARK: - maxVerticalLeaves (header reserve-rows count)

    func test_maxVerticalLeaves_singlePane() {
        XCTAssertEqual(PaneLayoutMath.maxVerticalLeaves(root("b25d,80x24,0,0,0")), 1)
    }

    func test_maxVerticalLeaves_sideBySideIsOne() {
        // {a,b}: a vertical line through the layout crosses exactly one column,
        // so the tallest header stack is a single header.
        XCTAssertEqual(
            PaneLayoutMath.maxVerticalLeaves(root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")),
            1
        )
    }

    func test_maxVerticalLeaves_stackedIsTwo() {
        // [a,b]: a vertical line crosses both stacked leaves.
        XCTAssertEqual(
            PaneLayoutMath.maxVerticalLeaves(root("abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]")),
            2
        )
    }

    func test_maxVerticalLeaves_nestedColumnStack() {
        // {leaf , [leaf , leaf]}: left column 1 leaf, right column 2 stacked.
        XCTAssertEqual(
            PaneLayoutMath.maxVerticalLeaves(
                root("d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}")
            ),
            2
        )
    }

    func test_maxVerticalLeaves_fourPaneNested() {
        // {leaf , [leaf , {leaf,leaf}]}: deepest column is leaf-over-(side-by-
        // side pair) = 2 stacked.
        XCTAssertEqual(
            PaneLayoutMath.maxVerticalLeaves(
                root("1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}")
            ),
            2
        )
    }

    // MARK: - frames: positions and exact cell multiples

    func test_frames_singlePaneNoHeader() {
        let cell = CGSize(width: 8, height: 16)
        let frames = PaneLayoutMath.frames(root: root("b25d,80x24,0,0,0"), cellSize: cell, headerHeight: 0)
        XCTAssertEqual(frames.count, 1)
        let p0 = frame(frames, 0)
        XCTAssertEqual(p0.headerFrame.height, 0, "no header reserved for a single pane")
        XCTAssertEqual(p0.surfaceFrame, CGRect(x: 0, y: 0, width: 80 * 8, height: 24 * 16))
    }

    func test_frames_sideBySideNoHeader_matchesTmuxRectOrigins() {
        // The walk accumulates child sizes + a 1-cell gutter; the result must
        // reproduce tmux's own pane origins (pane 1 at cell x=41).
        let cell = CGSize(width: 10, height: 20)
        let frames = PaneLayoutMath.frames(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"),
            cellSize: cell, headerHeight: 0
        )
        XCTAssertEqual(frame(frames, 0).surfaceFrame, CGRect(x: 0, y: 0, width: 400, height: 480))
        XCTAssertEqual(frame(frames, 1).surfaceFrame, CGRect(x: 410, y: 0, width: 390, height: 480))
    }

    func test_frames_sideBySideWithHeader_pushesSurfaceDownByOneHeader() {
        let cell = CGSize(width: 10, height: 20)
        let header: CGFloat = 24
        let frames = PaneLayoutMath.frames(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"),
            cellSize: cell, headerHeight: header
        )
        // Each pane in a side-by-side has exactly one header above its surface.
        XCTAssertEqual(frame(frames, 0).headerFrame, CGRect(x: 0, y: 0, width: 400, height: 24))
        XCTAssertEqual(frame(frames, 0).surfaceFrame, CGRect(x: 0, y: 24, width: 400, height: 480))
        XCTAssertEqual(frame(frames, 1).headerFrame, CGRect(x: 410, y: 0, width: 390, height: 24))
        XCTAssertEqual(frame(frames, 1).surfaceFrame, CGRect(x: 410, y: 24, width: 390, height: 480))
    }

    func test_frames_nestedColumn_accumulatesHeadersAbove() {
        // Right column stacks pane 1 over pane 2; pane 2's surface is pushed
        // down by BOTH headers above it plus pane 1's content plus the gutter.
        let cell = CGSize(width: 10, height: 20)
        let header: CGFloat = 16
        let frames = PaneLayoutMath.frames(
            root: root("d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}"),
            cellSize: cell, headerHeight: header
        )
        // Left pane: single header above its 40x24 surface.
        XCTAssertEqual(frame(frames, 0).surfaceFrame, CGRect(x: 0, y: 16, width: 400, height: 480))
        // Right-top pane 1: 39x12 surface under one header.
        XCTAssertEqual(frame(frames, 1).headerFrame, CGRect(x: 410, y: 0, width: 390, height: 16))
        XCTAssertEqual(frame(frames, 1).surfaceFrame, CGRect(x: 410, y: 16, width: 390, height: 240))
        // Right-bottom pane 2: header at y = header + pane1(header+content) +
        // gutter = 16 + 256 + 20 = 292 - 16 = 276; surface at 292.
        XCTAssertEqual(frame(frames, 2).headerFrame, CGRect(x: 410, y: 276, width: 390, height: 16))
        XCTAssertEqual(frame(frames, 2).surfaceFrame, CGRect(x: 410, y: 292, width: 390, height: 220))
    }

    func test_frames_allSurfacesAreExactCellMultiples() {
        // The load-bearing invariant (risk #2): across layouts, cell sizes, and
        // header heights, every surface is an exact integer number of cells.
        let layouts = [
            "b25d,80x24,0,0,0",
            "8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}",
            "abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]",
            "d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}",
            "1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}",
        ]
        let cells = [CGSize(width: 8, height: 16), CGSize(width: 10.5, height: 21.5), CGSize(width: 7, height: 15)]
        let headers: [CGFloat] = [0, 16, 28]

        for layoutString in layouts {
            for cell in cells {
                for header in headers {
                    let frames = PaneLayoutMath.frames(
                        root: root(layoutString), cellSize: cell, headerHeight: header
                    )
                    for f in frames {
                        let cols = f.surfaceFrame.width / cell.width
                        let rows = f.surfaceFrame.height / cell.height
                        XCTAssertEqual(
                            cols, cols.rounded(), accuracy: 0.0001,
                            "surface width must be an exact cell multiple (layout \(layoutString) cell \(cell) header \(header) pane \(f.paneId.rawValue))"
                        )
                        XCTAssertEqual(
                            rows, rows.rounded(), accuracy: 0.0001,
                            "surface height must be an exact cell multiple (layout \(layoutString) cell \(cell) header \(header) pane \(f.paneId.rawValue))"
                        )
                    }
                }
            }
        }
    }

    // MARK: - dividers (hairlines in gutters)

    func test_dividers_singlePaneHasNone() {
        let cell = CGSize(width: 10, height: 20)
        XCTAssertTrue(
            PaneLayoutMath.dividers(root: root("b25d,80x24,0,0,0"), cellSize: cell, headerHeight: 0, thickness: 1).isEmpty
        )
    }

    func test_dividers_sideBySideOneVerticalHairlineCenteredInGutter() {
        let cell = CGSize(width: 10, height: 20)
        let header: CGFloat = 16
        let lines = PaneLayoutMath.dividers(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"),
            cellSize: cell, headerHeight: header, thickness: 1
        )
        XCTAssertEqual(lines.count, 1)
        // Gutter occupies cell column x∈[400,410); a 1pt line centered → x=404.5.
        // It spans the full split height: header(16) + 24*20 = 496.
        XCTAssertEqual(lines[0], CGRect(x: 404.5, y: 0, width: 1, height: 496))
    }

    func test_dividers_stackedOneHorizontalHairlineCenteredInGutter() {
        let cell = CGSize(width: 10, height: 20)
        let lines = PaneLayoutMath.dividers(
            root: root("abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]"),
            cellSize: cell, headerHeight: 0, thickness: 2
        )
        XCTAssertEqual(lines.count, 1)
        // Top pane 12 rows * 20 = 240; gutter y∈[240,260); 2pt line centered → y=249.
        // Width spans the split: 80 cells * 10 = 800.
        XCTAssertEqual(lines[0], CGRect(x: 0, y: 249, width: 800, height: 2))
    }

    func test_dividers_nestedLayoutHasOuterAndInnerGutters() {
        // {leaf , [leaf,leaf]}: one outer vertical line (between the two columns)
        // and one inner horizontal line (between the right column's stacked panes).
        let cell = CGSize(width: 10, height: 20)
        let lines = PaneLayoutMath.dividers(
            root: root("d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}"),
            cellSize: cell, headerHeight: 0, thickness: 1
        )
        XCTAssertEqual(lines.count, 2)
        let verticals = lines.filter { $0.height > $0.width }
        let horizontals = lines.filter { $0.width > $0.height }
        XCTAssertEqual(verticals.count, 1, "one vertical gutter between the two columns")
        XCTAssertEqual(horizontals.count, 1, "one horizontal gutter inside the right column")
        // Vertical divider sits in the gutter after the 40-cell left column.
        XCTAssertEqual(verticals.first?.minX ?? -1, 404.5, accuracy: 0.0001)
    }

    func test_frames_paneBoxUnionsHeaderAndSurfaceWhenHeaderPresent() {
        let cell = CGSize(width: 10, height: 20)
        let withHeader = PaneLayoutMath.frames(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"),
            cellSize: cell, headerHeight: 24
        )
        let p0 = frame(withHeader, 0)
        XCTAssertEqual(p0.paneBox, CGRect(x: 0, y: 0, width: 400, height: 504),
                       "paneBox spans header + surface for the focus ring")

        let noHeader = PaneLayoutMath.frames(
            root: root("b25d,80x24,0,0,0"), cellSize: cell, headerHeight: 0
        )
        XCTAssertEqual(noHeader[0].paneBox, noHeader[0].surfaceFrame,
                       "with no header the pane box is just the surface")
    }

    // MARK: - pane(at:) hit-testing (mosh tap-to-focus)

    func test_paneAt_sideBySide_mapsLeftAndRightTaps() {
        // {40x24 , 39x24}: left pane surface x∈[0,400), right x∈[410,800).
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 50, y: 100), root: r, cellSize: cell), PaneId(0))
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 600, y: 100), root: r, cellSize: cell), PaneId(1))
    }

    func test_paneAt_dividerGutterResolvesToNil() {
        // The 1-cell gutter column x∈[400,410) belongs to no surface — a tap
        // there must not switch focus (mirrors the SSH grid's exact tap).
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 405, y: 100), root: r, cellSize: cell))
    }

    func test_paneAt_boundaryIsHalfOpen() {
        // Pane 0 surface is x∈[0,400); x=400 is the gutter, x=399 still pane 0.
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 399, y: 0), root: r, cellSize: cell), PaneId(0))
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 400, y: 0), root: r, cellSize: cell))
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 410, y: 0), root: r, cellSize: cell), PaneId(1))
    }

    func test_paneAt_stacked_mapsTopAndBottomTaps() {
        // [80x12 , 80x11]: top pane y∈[0,240), bottom y∈[260,480).
        let cell = CGSize(width: 10, height: 20)
        let r = root("abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]")
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 50), root: r, cellSize: cell), PaneId(0))
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 300), root: r, cellSize: cell), PaneId(1))
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 250), root: r, cellSize: cell),
                     "the horizontal gutter row maps to no pane")
    }

    func test_paneAt_nestedFourPane_eachQuadrantResolves() {
        // {leaf , [leaf , {leaf,leaf}]} — exercise every leaf of a nested tree.
        let cell = CGSize(width: 10, height: 20)
        let r = root("1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}")
        // Left full-height column → pane 0.
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 240), root: r, cellSize: cell), PaneId(0))
        // Right-top stacked leaf → pane 1 (x≥410, y<240).
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 500, y: 100), root: r, cellSize: cell), PaneId(1))
        // Right-bottom inner side-by-side: pane 2 (left) and pane 3 (right).
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 450, y: 400), root: r, cellSize: cell), PaneId(2))
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 700, y: 400), root: r, cellSize: cell), PaneId(3))
    }

    func test_paneAt_outOfBoundsResolvesToNil() {
        // A tap past the grid's painted extent (remainder margin) hits nothing.
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 5000, y: 5000), root: r, cellSize: cell))
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 999), root: r, cellSize: cell))
    }

    func test_frameAt_returnsTheHitPaneFrame() {
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(PaneLayoutMath.frame(at: CGPoint(x: 50, y: 100), root: r, cellSize: cell)?.paneId, PaneId(0))
        XCTAssertEqual(PaneLayoutMath.frame(at: CGPoint(x: 600, y: 100), root: r, cellSize: cell)?.surfaceFrame,
                       CGRect(x: 410, y: 0, width: 390, height: 480))
        XCTAssertNil(PaneLayoutMath.frame(at: CGPoint(x: 405, y: 100), root: r, cellSize: cell))
    }

    // MARK: - closeButtonRect (mosh ✕ affordance)

    func test_closeButtonRect_anchoredTopRightOnePaneTall() {
        // Side-by-side {40x24, 39x24}, cell 10×20: each ✕ is a cellH square at
        // the pane's top-right corner (matching the SSH header's height×height ✕).
        let cell = CGSize(width: 10, height: 20)
        let frames = PaneLayoutMath.frames(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"), cellSize: cell, headerHeight: 0
        )
        let left = frame(frames, 0)   // surface (0,0,400,480)
        let right = frame(frames, 1)  // surface (410,0,390,480)
        XCTAssertEqual(PaneLayoutMath.closeButtonRect(for: left, cellSize: cell),
                       CGRect(x: 380, y: 0, width: 20, height: 20))
        XCTAssertEqual(PaneLayoutMath.closeButtonRect(for: right, cellSize: cell),
                       CGRect(x: 780, y: 0, width: 20, height: 20))
    }

    func test_closeButtonRect_isInsideItsPaneSurface() {
        // The ✕ rect must never poke outside its own pane (else a tap there would
        // hit-test to the neighbour / gutter and the kill would target the wrong
        // pane or no pane).
        let layouts = [
            "8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}",
            "abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]",
            "1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}",
        ]
        let cell = CGSize(width: 10, height: 20)
        for layoutString in layouts {
            for f in PaneLayoutMath.frames(root: root(layoutString), cellSize: cell, headerHeight: 0) {
                let x = PaneLayoutMath.closeButtonRect(for: f, cellSize: cell)
                XCTAssertTrue(f.surfaceFrame.contains(x),
                              "✕ rect \(x) escaped pane %\(f.paneId.rawValue) surface \(f.surfaceFrame) in \(layoutString)")
            }
        }
    }

    func test_closeButtonRect_aTapInItResolvesToTheSamePane() {
        // The center of a pane's ✕ rect must hit-test (via frame(at:)) back to
        // that same pane — the property the tap handler relies on to close it.
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        for f in PaneLayoutMath.frames(root: r, cellSize: cell, headerHeight: 0) {
            let x = PaneLayoutMath.closeButtonRect(for: f, cellSize: cell)
            let center = CGPoint(x: x.midX, y: x.midY)
            XCTAssertEqual(PaneLayoutMath.frame(at: center, root: r, cellSize: cell)?.paneId, f.paneId)
        }
    }

    func test_closeButtonRect_narrowPaneClampsToWidth() {
        // A pane narrower than one cell-height keeps the ✕ within its width.
        let cell = CGSize(width: 10, height: 20)
        let tiny = PaneFrame(
            paneId: PaneId(9),
            headerFrame: .zero,
            surfaceFrame: CGRect(x: 0, y: 0, width: 12, height: 200)
        )
        let x = PaneLayoutMath.closeButtonRect(for: tiny, cellSize: cell)
        XCTAssertEqual(x.width, 12, "✕ width clamps to the pane width when narrower than cellH")
        XCTAssertTrue(tiny.surfaceFrame.contains(x))
    }
}
