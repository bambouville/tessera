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

    func test_backgroundLeftOpen_foregroundTruecolorComponentsNotMisreadAsBackground() {
        // Legacy `38;2;r;g;b` operands must be consumed — a green component of
        // 100 is not SGR 100 (bright-black background).
        let line = "\(esc)[38;2;100;107;42mtext"
        XCTAssertFalse(RepaintAssembly.backgroundLeftOpen(in: [line]))
    }

    // MARK: row-seam background neutralization (gray-box ghost)
    //
    // A CRLF fed while the background pen is open scrolls (on the bottom row)
    // and BCE-fills the scrolled-in line with that background; rows that then
    // land in scrollback keep the stale colored tail forever. The assembler
    // must close the background before every seam CRLF and re-establish it
    // right after.

    func test_assemble_neutralizesOpenBackgroundAtRowSeam_indexed() {
        let grayRow = "\(esc)[100m                    "
        let bytes = RepaintAssembly.assemble(
            state: Self.makeState(cursorX: 0, cursorY: 0),
            captureLines: [grayRow, "\(esc)[49mshort"],
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: 24
        )
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(
            text.contains("\(grayRow)\(esc)[49m\r\n\(esc)[100m\(esc)[49mshort"),
            "expected bg closed before the seam CRLF and re-opened after"
        )
    }

    func test_assemble_neutralizesOpenBackgroundAtRowSeam_extendedForms() {
        for opener in ["48;5;236", "48;2;40;40;40", "48:2::64:64:64"] {
            let grayRow = "\(esc)[\(opener)m box"
            let bytes = RepaintAssembly.assemble(
                state: Self.makeState(cursorX: 0, cursorY: 0),
                captureLines: [grayRow, "next"],
                historyLines: [],
                savedPrimaryLines: [],
                altScreenLines: nil,
                terminalIsInAltScreen: false,
                clientRows: 24
            )
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(
                text.contains("\(grayRow)\(esc)[49m\r\n\(esc)[\(opener)mnext"),
                "expected \(opener) re-established after the seam"
            )
        }
    }

    func test_assemble_openBackgroundCarriesAcrossRowsToLaterSeams() {
        // Pen opened on row 0, row 1 has no SGR of its own: the row1→row2 seam
        // must still be neutralized and re-opened.
        let lines = ["\(esc)[100mheader", "body", "footer"]
        let bytes = RepaintAssembly.assemble(
            state: Self.makeState(cursorX: 0, cursorY: 0),
            captureLines: lines,
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: 24
        )
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("header\(esc)[49m\r\n\(esc)[100mbody"))
        XCTAssertTrue(text.contains("body\(esc)[49m\r\n\(esc)[100mfooter"))
    }

    func test_assemble_plainSeamsStayPlain() {
        let bytes = RepaintAssembly.assemble(
            state: Self.makeState(cursorX: 0, cursorY: 0),
            captureLines: ["plain", "text", "\(esc)[41mred\(esc)[49m", "after"],
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: 24
        )
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("plain\r\ntext"))
        XCTAssertTrue(
            text.contains("\(esc)[49m\r\nafter"),
            "a seam whose pen was closed by the row itself must not be rewritten"
        )
        XCTAssertFalse(text.contains("\(esc)[49m\r\n\(esc)["))
    }

    func test_assemble_altBranchResetsBeforeSegmentSeamCRLF() {
        // The history → saved-primary segment seam: the full reset must come
        // BEFORE the CRLF so a scroll fill at the seam uses the default
        // background.
        let historyTail = "\(esc)[100mgray history tail"
        let bytes = RepaintAssembly.assemble(
            state: Self.makeState(cursorX: 0, cursorY: 0, paneInAltScreen: true),
            captureLines: ["alt screen row"],
            historyLines: ["old row", historyTail],
            savedPrimaryLines: ["saved primary row"],
            altScreenLines: ["alt screen row"],
            terminalIsInAltScreen: false,
            clientRows: 24
        )
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(
            text.contains("\(historyTail)\(esc)[0m\r\nsaved primary row"),
            "expected the segment reset ahead of the seam CRLF"
        )
    }

    func test_assemble_inPlaceAltRefreshNeverTouchesSavedPrimaryBuffer() {
        let bytes = RepaintAssembly.assemble(
            state: Self.makeState(cursorX: 4, cursorY: 5, paneInAltScreen: true),
            captureLines: ["alternate viewport"],
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: ["alternate viewport"],
            terminalIsInAltScreen: true,
            clientRows: 24,
            preservePrimaryDuringAltRefresh: true
        )
        let text = String(decoding: bytes, as: UTF8.self)

        XCTAssertTrue(text.contains("alternate viewport"))
        XCTAssertFalse(text.contains("\(esc)[?1049l"))
        XCTAssertFalse(text.contains("\(esc)[?1049h"))
        XCTAssertTrue(text.contains("\(esc)[6;5H"))
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
