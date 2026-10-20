import XCTest
@testable import TmuxControlCore

final class RenderCommandsTests: XCTestCase {
    func testRenderedPaneMetadataFormatMatchesTheParserContract() {
        XCTAssertEqual(
            RenderCommands.renderedPaneMetadataFormat.split(separator: "\t", omittingEmptySubsequences: false),
            [
                "#{pane_id}",
                "#{cursor_x}",
                "#{cursor_y}",
                "#{pane_title}",
                "#{window_name}",
                "#{host}",
                "#{alternate_on}",
                "#{history_size}",
                "#{scroll_region_upper}",
                "#{scroll_region_lower}",
                "#{cursor_flag}",
                "#{insert_flag}",
                "#{keypad_cursor_flag}",
                "#{keypad_flag}",
                "#{wrap_flag}",
                "#{mouse_standard_flag}",
                "#{mouse_button_flag}",
                "#{mouse_all_flag}",
                "#{mouse_sgr_flag}",
                "#{origin_flag}",
                "#{alternate_saved_x}",
                "#{alternate_saved_y}",
                "#{pane_width}",
                "#{pane_height}",
            ]
        )
    }

    func testMetadataCommandKeepsTheFormatInOneQuotedArgument() {
        XCTAssertEqual(
            RenderCommands.renderedPaneMetadata(target: PaneId(12)),
            "display-message -p -t %12 '\(RenderCommands.renderedPaneMetadataFormat)'"
        )
        XCTAssertEqual(
            RenderCommands.renderedPaneMetadata(target: WindowId(7)),
            "display-message -p -t @7 '\(RenderCommands.renderedPaneMetadataFormat)'"
        )
    }

    func testViewportAndDeepPrimaryCommandsMatchTheExistingInlinePath() {
        XCTAssertEqual(
            RenderCommands.viewport(target: WindowId(7)),
            "capture-pane -p -e -N -t @7"
        )
        XCTAssertEqual(
            RenderCommands.deepPrimary(target: WindowId(7), depth: 2_000),
            "capture-pane -p -e -N -S -2000 -t @7"
        )
    }

    func testAlternateScreenCaptureCommandsPreserveTheirDistinctRanges() {
        XCTAssertEqual(
            RenderCommands.deepAltHistory(target: PaneId(12), depth: 2_000),
            "capture-pane -p -e -N -S -2000 -E -1 -t %12"
        )
        XCTAssertEqual(
            RenderCommands.savedPrimary(target: PaneId(12)),
            "capture-pane -p -e -N -a -q -t %12"
        )
    }

    func testMoshHistoryIncludesTheLiveViewportAndClampsNegativeDepth() {
        XCTAssertEqual(
            RenderCommands.moshHistory(target: PaneId(12), depth: 42),
            "capture-pane -p -e -N -S -42 -t %12"
        )
        XCTAssertEqual(
            RenderCommands.deepPrimary(target: PaneId(12), depth: -1),
            "capture-pane -p -e -N -S -0 -t %12"
        )
        XCTAssertFalse(RenderCommands.moshHistory(target: PaneId(12), depth: 42).contains(" -E "))
    }

    func testPauseAfterAndContinueCommandsMatchTheExistingFlowControlPath() {
        XCTAssertEqual(RenderCommands.pauseAfter(), "refresh-client -f pause-after=5")
        XCTAssertEqual(RenderCommands.pauseAfter(seconds: -1), "refresh-client -f pause-after=0")
        XCTAssertEqual(RenderCommands.continuePane(PaneId(12)), "refresh-client -A '%12:continue'")
    }
}
