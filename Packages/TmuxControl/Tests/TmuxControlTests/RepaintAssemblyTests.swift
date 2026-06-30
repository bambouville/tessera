import XCTest
@testable import TmuxControl

/// Cross-window "gray block" bleed: `capture-pane -e` only closes SGR on rows
/// with trailing blank cells, so a full-width colored final row (a TUI's
/// full-row input box, e.g. Codex) leaves the background pen open. With one
/// shared terminal repainted across tmux windows, the live `%output` that
/// resumes after a swap would inherit that background. These tests pin the
/// detector (`backgroundLeftOpen`) used to surface the precondition in
/// diagnostics, and that `assemble` now closes the pen at the content tail.
@MainActor
final class RepaintAssemblyTests: XCTestCase {
    private let esc = "\u{1B}"

    // MARK: backgroundLeftOpen detector

    func test_backgroundLeftOpen_indexedBackgroundNeverClosed() {
        // `\e[100m` = bright-black (gray) background, row painted to the edge
        // with no trailing reset — the bleed precondition.
        let line = "\(esc)[100m gray input box filling the row"
        XCTAssertTrue(RepaintAssembly.backgroundLeftOpen(in: [line]))
    }

    func test_backgroundLeftOpen_truecolorGrayBackgroundNeverClosed() {
        let line = "\(esc)[48;2;128;128;128m   codex prompt   "
        XCTAssertTrue(RepaintAssembly.backgroundLeftOpen(in: [line]))
    }

    func test_backgroundLeftOpen_colonExtendedBackgroundNeverClosed() {
        // ITU colon form with empty colorspace token: `48:2::r:g:b`.
        let line = "\(esc)[48:2::64:64:64m shaded"
        XCTAssertTrue(RepaintAssembly.backgroundLeftOpen(in: [line]))
    }

    func test_backgroundLeftOpen_falseWhenResetTerminated() {
        let line = "\(esc)[100m gray\(esc)[0m"
        XCTAssertFalse(RepaintAssembly.backgroundLeftOpen(in: [line]))
    }

    func test_backgroundLeftOpen_falseWhenDefaultBackgroundRestored() {
        // `\e[49m` returns just the background to default, leaving any
        // foreground intact — still no open background.
        let line = "\(esc)[41m\(esc)[38;5;9mred on red\(esc)[49m tail"
        XCTAssertFalse(RepaintAssembly.backgroundLeftOpen(in: [line]))
    }

    func test_backgroundLeftOpen_falseForForegroundOnly() {
        let line = "\(esc)[31m\(esc)[1mbold red text"
        XCTAssertFalse(RepaintAssembly.backgroundLeftOpen(in: [line]))
    }

    func test_backgroundLeftOpen_carriesAcrossRows() {
        // capture-pane streams cumulative SGR: bg opened on an early row and
        // never closed must still read as open at the final row.
        let lines = [
            "\(esc)[100mheader",
            "body still gray",
            "footer still gray",
        ]
        XCTAssertTrue(RepaintAssembly.backgroundLeftOpen(in: lines))
    }

    func test_backgroundLeftOpen_falseForPlainText() {
        XCTAssertFalse(RepaintAssembly.backgroundLeftOpen(in: ["just text", "more text"]))
    }

    func test_backgroundLeftOpen_ignoresNonSGRCSI() {
        // `\e[?25h` (cursor show) and `\e[2J` (erase) must not be mistaken for
        // background selects.
        let line = "\(esc)[?25h\(esc)[2Jplain"
        XCTAssertFalse(RepaintAssembly.backgroundLeftOpen(in: [line]))
    }

    // MARK: assemble closes the pen at the content tail

    func test_assemble_primaryClosesOpenBackgroundAfterContent() {
        let grayTail = "\(esc)[100m gray full-row input box"
        let bytes = RepaintAssembly.assemble(
            state: Self.makeState(cursorX: 3, cursorY: 1),
            captureLines: ["clean line", grayTail],
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: 24
        )
        let text = String(decoding: bytes, as: UTF8.self)
        // The reset must immediately follow the (unterminated) capture content,
        // before the cursor is repositioned and live output resumes.
        XCTAssertTrue(
            text.contains("\(grayTail)\(esc)[0m"),
            "expected a trailing SGR reset right after the gray capture tail"
        )
        // And the assembled bytes ahead of the cursor restore must no longer
        // leave the background open.
        let beforeCursor = text.components(separatedBy: "\(esc)[?25h\(esc)[2;4H").first ?? text
        XCTAssertFalse(RepaintAssembly.backgroundLeftOpen(in: [beforeCursor]))
    }

    private static func makeState(
        cursorX: Int,
        cursorY: Int,
        paneInAltScreen: Bool = false
    ) -> TmuxController.RenderedPaneState {
        TmuxController.RenderedPaneState(
            paneId: PaneId(1),
            cursorX: cursorX,
            cursorY: cursorY,
            paneTitle: nil,
            paneTitleIsDefault: true,
            windowName: nil,
            paneInAltScreen: paneInAltScreen,
            historySize: nil,
            scrollRegionUpper: nil,
            scrollRegionLower: nil,
            cursorVisible: true,
            insertMode: nil,
            keypadCursor: nil,
            keypadApplication: nil,
            wrapMode: nil,
            mouseStandard: nil,
            mouseButton: nil,
            mouseAll: nil,
            mouseSgr: nil,
            originMode: nil,
            altSavedX: nil,
            altSavedY: nil
        )
    }
}
