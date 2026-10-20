import XCTest
@testable import TmuxControlCore

final class CompactCanvasTests: XCTestCase {
    private let cellWidth = 10.0
    private let cellHeight = 20.0

    func testUnsplitWindowAtTheDeviceGridNeedsNoScaleOrPan() {
        let rect = CellRect(width: 40, height: 20, x: 0, y: 0)
        let projection = TmuxCompactCanvas.projection(
            window: rect,
            focus: rect,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            viewportWidth: 400,
            viewportHeight: 400
        )

        XCTAssertEqual(projection?.scale, 1)
        XCTAssertEqual(projection?.contentWidth, 400)
        XCTAssertEqual(projection?.contentHeight, 400)
        XCTAssertEqual(projection?.offsetX, 0)
        XCTAssertEqual(projection?.offsetY, 0)
    }

    func testSplitWindowIsLaidOutWholeAndPannedToTheFocusedPane() {
        // Two side-by-side panes; the focused one is the right half.
        let window = CellRect(width: 80, height: 20, x: 0, y: 0)
        let focus = CellRect(width: 40, height: 20, x: 40, y: 0)
        let projection = TmuxCompactCanvas.projection(
            window: window,
            focus: focus,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            viewportWidth: 400,
            viewportHeight: 400
        )

        // The content keeps the full window: a transport that paints the whole
        // window natively must not be squeezed into one pane's grid.
        XCTAssertEqual(projection?.contentWidth, 800)
        XCTAssertEqual(projection?.scale, 1)
        // ...and the left pane is panned off-screen so the focused half fills.
        XCTAssertEqual(projection?.offsetX, -400)
        XCTAssertEqual(projection?.offsetY, 0)
    }

    func testFocusLargerThanTheViewportScalesDownOnTheTighterAxis() {
        let rect = CellRect(width: 80, height: 20, x: 0, y: 0)
        let projection = TmuxCompactCanvas.projection(
            window: rect,
            focus: rect,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            viewportWidth: 400,
            viewportHeight: 400
        )

        XCTAssertEqual(projection?.scale, 0.5)
        XCTAssertEqual(projection?.offsetX, 0)
        XCTAssertEqual(projection?.offsetY, 100)
    }

    func testDegenerateGeometryHasNoProjection() {
        let rect = CellRect(width: 40, height: 20, x: 0, y: 0)
        XCTAssertNil(
            TmuxCompactCanvas.projection(
                window: CellRect(width: 0, height: 0, x: 0, y: 0),
                focus: rect,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                viewportWidth: 400,
                viewportHeight: 400
            )
        )
        XCTAssertNil(
            TmuxCompactCanvas.projection(
                window: rect,
                focus: rect,
                cellWidth: 0,
                cellHeight: cellHeight,
                viewportWidth: 400,
                viewportHeight: 400
            )
        )
    }
}
