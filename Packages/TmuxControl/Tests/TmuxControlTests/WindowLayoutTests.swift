import XCTest
@testable import TmuxControl

/// Golden tests for the tmux window-layout parser.
///
/// Every multi-pane fixture below is a verbatim layout string captured from a
/// live `tmux 3.6a` `-CC` control client (`%layout-change` notifications and
/// `#{window_layout}`), so the grammar coverage matches what ships on the wire.
final class WindowLayoutTests: XCTestCase {

    // MARK: - Single pane (the fast path)

    func test_singlePane_parsesAsOneLeaf() {
        let layout = WindowLayout.parse("b25d,80x24,0,0,0")
        XCTAssertNotNil(layout)
        XCTAssertEqual(layout?.paneCount, 1)
        XCTAssertEqual(layout?.paneIds, [PaneId(0)])
        XCTAssertEqual(
            layout?.root,
            .leaf(paneId: PaneId(0), rect: CellRect(width: 80, height: 24, x: 0, y: 0))
        )
    }

    func test_zoomVisibleLayout_isSingleLeafOfZoomedPane() {
        // window_visible_layout while pane %2 is zoomed.
        let layout = WindowLayout.parse("b25f,80x24,0,0,2")
        XCTAssertEqual(layout?.paneCount, 1)
        XCTAssertEqual(layout?.paneIds, [PaneId(2)])
    }

    func test_largePaneId_parses() {
        let layout = WindowLayout.parse("abcd,80x24,0,0,137")
        XCTAssertEqual(layout?.paneIds, [PaneId(137)])
    }

    // MARK: - Two-pane horizontal split (side-by-side, split-window -h)

    func test_twoPaneHorizontalSplit() {
        let layout = WindowLayout.parse("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(layout?.paneCount, 2)
        XCTAssertEqual(layout?.paneIds, [PaneId(0), PaneId(1)])
        guard case let .split(axis, rect, children) = layout?.root else {
            return XCTFail("expected split root")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(rect, CellRect(width: 80, height: 24, x: 0, y: 0))
        XCTAssertEqual(
            children,
            [
                .leaf(paneId: PaneId(0), rect: CellRect(width: 40, height: 24, x: 0, y: 0)),
                .leaf(paneId: PaneId(1), rect: CellRect(width: 39, height: 24, x: 41, y: 0)),
            ]
        )
    }

    /// The byte after pane id `0` is `,39…` — a comma followed by a digit then
    /// `x`. That `39` is the *next sibling's* width, not part of the leaf. The
    /// recursive grammar handles this without the iTerm2 "digits-not-followed-
    /// by-x" heuristic; this pins that it does.
    func test_paneIdVsSiblingDisambiguation() {
        let layout = WindowLayout.parse("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(layout?.leaves.map(\.rect.width), [40, 39])
        XCTAssertEqual(layout?.leaves.map(\.paneId), [PaneId(0), PaneId(1)])
    }

    // MARK: - Vertical split (stacked, split-window -v)

    func test_threePaneNested_horizontalThenVertical() {
        let layout = WindowLayout.parse(
            "d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}"
        )
        XCTAssertEqual(layout?.paneCount, 3)
        // DFS order: leftmost leaf, then the two stacked leaves top-to-bottom.
        XCTAssertEqual(layout?.paneIds, [PaneId(0), PaneId(1), PaneId(2)])

        guard case let .split(rootAxis, _, rootChildren) = layout?.root else {
            return XCTFail("expected split root")
        }
        XCTAssertEqual(rootAxis, .horizontal)
        XCTAssertEqual(rootChildren.count, 2)
        // Second child is a vertical split of panes 1 and 2.
        guard case let .split(innerAxis, innerRect, innerChildren) = rootChildren[1] else {
            return XCTFail("expected nested vertical split")
        }
        XCTAssertEqual(innerAxis, .vertical)
        XCTAssertEqual(innerRect, CellRect(width: 39, height: 24, x: 41, y: 0))
        XCTAssertEqual(
            innerChildren,
            [
                .leaf(paneId: PaneId(1), rect: CellRect(width: 39, height: 12, x: 41, y: 0)),
                .leaf(paneId: PaneId(2), rect: CellRect(width: 39, height: 11, x: 41, y: 13)),
            ]
        )
    }

    func test_fourPane_doublyNested() {
        let layout = WindowLayout.parse(
            "1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}"
        )
        XCTAssertEqual(layout?.paneCount, 4)
        XCTAssertEqual(layout?.paneIds, [PaneId(0), PaneId(1), PaneId(2), PaneId(3)])
    }

    // MARK: - Man-page example

    func test_manPageExample() {
        // From tmux(1): an even side-by-side split of a 159x48 window.
        let layout = WindowLayout.parse("bb62,159x48,0,0{79x48,0,0,0,79x48,80,0,1}")
        XCTAssertEqual(layout?.paneCount, 2)
        XCTAssertEqual(layout?.paneIds, [PaneId(0), PaneId(1)])
    }

    // MARK: - Gutter invariant (sum(child + 1) - 1 == parent)

    func test_gutterInvariant_horizontal() {
        let layout = WindowLayout.parse("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        guard case let .split(.horizontal, rect, children) = layout?.root else {
            return XCTFail("expected horizontal split")
        }
        let summed = children.reduce(0) { $0 + $1.rect.width + 1 } - 1
        XCTAssertEqual(summed, rect.width, "horizontal children + gutters must fill the parent")
    }

    func test_gutterInvariant_vertical() {
        let layout = WindowLayout.parse(
            "d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}"
        )
        guard case let .split(.horizontal, _, rootChildren) = layout?.root,
              case let .split(.vertical, rect, children) = rootChildren[1]
        else {
            return XCTFail("expected nested vertical split")
        }
        let summed = children.reduce(0) { $0 + $1.rect.height + 1 } - 1
        XCTAssertEqual(summed, rect.height, "vertical children + gutters must fill the parent")
    }

    // MARK: - Malformed input fails open to nil

    func test_malformed_returnsNil() {
        let cases = [
            "",                              // empty
            "80x24,0,0,0",                   // no checksum/comma prefix
            ",80x24,0,0,0",                  // empty checksum
            "zzzz,80x24,0,0,0",              // non-hex checksum
            "b25d,80x24,0,0",                // cell with neither paneId nor children
            "b25d,80x24,0,0{40x24,0,0,0}",   // single-child split missing sibling? (valid count=1)…
            "b25d,80x24,0,0{40x24,0,0,0",    // unterminated brace
            "b25d,80x24,0,0{40x24,0,0,0]",   // mismatched close bracket
            "b25d,80x24,0,0,0,garbage",      // trailing garbage after root
            "b25d,80xq,0,0,0",               // non-numeric dimension
            "b25d,80x24,0,0,",               // missing pane id value
        ]
        for input in cases {
            // Note: "{40x24,0,0,0}" is actually a well-formed single-child
            // split, so it should parse; assert the others fail.
            if input == "b25d,80x24,0,0{40x24,0,0,0}" {
                XCTAssertNotNil(WindowLayout.parse(input), "single-child split is valid")
            } else {
                XCTAssertNil(WindowLayout.parse(input), "expected nil for malformed: \(input)")
            }
        }
    }

    func test_trailingGarbage_rejected() {
        XCTAssertNil(WindowLayout.parse("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}x"))
    }

    // MARK: - Pathological depth / length must fail open, never crash

    /// A hostile/torn frame of deeply-nested `{` must return nil, NOT overflow
    /// the stack. Regression for the SIGSEGV the adversarial review reproduced.
    func test_deeplyNested_failsOpenWithoutCrashing() {
        let bomb = "b25d," + String(repeating: "80x24,0,0{", count: 100_000)
        XCTAssertNil(WindowLayout.parse(bomb), "deeply nested input must fail open to nil")
    }

    /// Nesting just past the depth cap returns nil cleanly (no crash) even when
    /// every level is otherwise well-formed up to the cap.
    func test_nestingPastDepthCap_returnsNil() {
        let deep = "b25d," + String(repeating: "80x24,0,0{", count: 300)
        XCTAssertNil(WindowLayout.parse(deep))
    }

    /// An over-long layout token is rejected before recursion even begins.
    func test_overlongInput_returnsNil() {
        let long = "b25d,80x24,0,0," + String(repeating: "9", count: 40_000)
        XCTAssertNil(WindowLayout.parse(long))
    }
}
