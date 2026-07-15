import XCTest
@testable import TmuxControl

@MainActor
final class TmuxControllerTests: XCTestCase {

    // Helper: make a controller whose feed/send closures append into
    // accumulator arrays we can assert on.
    private func makeController(
        controlPath: TmuxController.ControlPath = .inline
    ) -> (
        TmuxController,
        fed: Accumulator<UInt8>,
        sent: Accumulator<UInt8>
    ) {
        let fed = Accumulator<UInt8>()
        let sent = Accumulator<UInt8>()
        let controller = TmuxController(controlPath: controlPath)
        controller.feedTerminal = { slice in fed.append(contentsOf: slice) }
        controller.sendBytes = { bytes in sent.append(contentsOf: bytes) }
        return (controller, fed, sent)
    }

    private func renderedMetadataCommand(windowId: Int) -> String {
        "display-message -p -t @\(windowId) '\(TmuxController.renderedPaneMetadataFormat)'\n"
    }

    private func renderedPaneMetadataLine(
        paneId: Int,
        cursorX: Int = 0,
        cursorY: Int = 0,
        paneTitle: String = "pane title",
        windowName: String = "editor",
        host: String = "host",
        alternateOn: Bool = false,
        historySize: Int? = nil,
        scrollRegionUpper: Int? = nil,
        scrollRegionLower: Int? = nil,
        cursorVisible: Bool? = nil,
        insertMode: Bool? = nil,
        keypadCursor: Bool? = nil,
        keypadApplication: Bool? = nil,
        wrapMode: Bool? = nil,
        mouseStandard: Bool? = nil,
        mouseButton: Bool? = nil,
        mouseAll: Bool? = nil,
        mouseSgr: Bool? = nil,
        originMode: Bool? = nil,
        altSavedX: Int? = nil,
        altSavedY: Int? = nil
    ) -> String {
        [
            "%\(paneId)",
            "\(cursorX)",
            "\(cursorY)",
            paneTitle,
            windowName,
            host,
            flag(alternateOn),
            optional(historySize),
            optional(scrollRegionUpper),
            optional(scrollRegionLower),
            optionalFlag(cursorVisible),
            optionalFlag(insertMode),
            optionalFlag(keypadCursor),
            optionalFlag(keypadApplication),
            optionalFlag(wrapMode),
            optionalFlag(mouseStandard),
            optionalFlag(mouseButton),
            optionalFlag(mouseAll),
            optionalFlag(mouseSgr),
            optionalFlag(originMode),
            optional(altSavedX),
            optional(altSavedY),
        ].joined(separator: "\t")
    }

    private func responseFrame(
        _ number: Int,
        body: [String] = [],
        flags: Int = 1,
        time: Int = 0,
        status: String = "%end"
    ) -> [UInt8] {
        var lines = ["%begin \(time) \(number) \(flags)"]
        lines.append(contentsOf: body)
        lines.append("\(status) \(time) \(number) \(flags)")
        return Array((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private func errorFrame(
        _ number: Int,
        body: [String] = [],
        flags: Int = 1,
        time: Int = 0
    ) -> [UInt8] {
        responseFrame(number, body: body, flags: flags, time: time, status: "%error")
    }

    private func expectSent(
        _ sent: Accumulator<UInt8>,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self), expected, file: file, line: line)
    }

    private func expectedRepaintBytes(
        captureLines: [String],
        terminalWasInAltScreen: Bool = false,
        paneInAltScreen: Bool = false,
        historyLines: [String] = [],
        savedPrimaryLines: [String] = [],
        altScreenLines: [String]? = nil,
        cursorX: Int = 0,
        cursorY: Int = 0,
        scrollRegionUpper: Int? = nil,
        scrollRegionLower: Int? = nil,
        cursorVisible: Bool? = nil,
        insertMode: Bool? = nil,
        keypadCursor: Bool? = nil,
        keypadApplication: Bool? = nil,
        wrapMode: Bool? = nil,
        mouseStandard: Bool? = nil,
        mouseButton: Bool? = nil,
        mouseAll: Bool? = nil,
        mouseSgr: Bool? = nil,
        originMode: Bool? = nil,
        altSavedX: Int? = nil,
        altSavedY: Int? = nil
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        appendEscape("\u{1B}[?2026l", to: &bytes)
        if terminalWasInAltScreen {
            appendEscape("\u{1B}[?1049l", to: &bytes)
        }
        appendEscape("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l", to: &bytes)
        appendEscape("\u{1B}[?6l\u{1B}[?7h\u{1B}[4l\u{1B}[r", to: &bytes)
        appendEscape("\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[?25h", to: &bytes)

        if paneInAltScreen {
            appendLines(historyLines, to: &bytes)
            // Segment reset precedes the seam CRLF so a scroll fill at the
            // seam uses the default background (BCE ghost guard).
            appendEscape("\u{1B}[0m", to: &bytes)
            if !historyLines.isEmpty && !savedPrimaryLines.isEmpty {
                appendCRLF(to: &bytes)
            }
            appendLines(savedPrimaryLines, to: &bytes)
            let savedRow = max(1, (altSavedY ?? 0) + 1)
            let savedCol = max(1, (altSavedX ?? 0) + 1)
            appendEscape("\u{1B}[\(savedRow);\(savedCol)H", to: &bytes)
            appendEscape("\u{1B}[0m\u{1B}[?1049h\u{1B}[H", to: &bytes)
            appendLines(altScreenLines ?? captureLines, to: &bytes)
        } else {
            appendLines(captureLines, to: &bytes)
        }

        // Trailing SGR reset so live %output after the repaint can't inherit a
        // background the capture left open (cross-window gray-block bleed guard).
        appendEscape("\u{1B}[0m", to: &bytes)

        if let upper = scrollRegionUpper,
           let lower = scrollRegionLower,
           upper >= 0,
           lower >= upper {
            appendEscape("\u{1B}[\(upper + 1);\(lower + 1)r", to: &bytes)
        }
        if insertMode == true {
            appendEscape("\u{1B}[4h", to: &bytes)
        }
        if wrapMode == false {
            appendEscape("\u{1B}[?7l", to: &bytes)
        }
        if mouseStandard == true {
            appendEscape("\u{1B}[?1000h", to: &bytes)
        } else if mouseButton == true {
            appendEscape("\u{1B}[?1002h", to: &bytes)
        } else if mouseAll == true {
            appendEscape("\u{1B}[?1003h", to: &bytes)
        }
        if mouseSgr == true {
            appendEscape("\u{1B}[?1006h", to: &bytes)
        }
        if let keypadApplication {
            appendEscape(keypadApplication ? "\u{1B}=" : "\u{1B}>", to: &bytes)
        }
        if let keypadCursor {
            appendEscape(keypadCursor ? "\u{1B}[?1h" : "\u{1B}[?1l", to: &bytes)
        }
        appendEscape(cursorVisible ?? true ? "\u{1B}[?25h" : "\u{1B}[?25l", to: &bytes)
        appendEscape("\u{1B}[\(max(1, cursorY + 1));\(max(1, cursorX + 1))H", to: &bytes)
        if originMode == true {
            appendEscape("\u{1B}[?6h", to: &bytes)
        }
        return bytes
    }

    private func assertMarker(
        _ first: String,
        precedes second: String,
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstRange = text.range(of: first) else {
            return XCTFail("missing marker \(first)", file: file, line: line)
        }
        guard let secondRange = text.range(of: second) else {
            return XCTFail("missing marker \(second)", file: file, line: line)
        }
        let firstOffset = text.distance(from: text.startIndex, to: firstRange.lowerBound)
        let secondOffset = text.distance(from: text.startIndex, to: secondRange.lowerBound)
        XCTAssertLessThan(firstOffset, secondOffset, file: file, line: line)
    }

    private func appendEscape(_ sequence: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: sequence.utf8)
    }

    private func appendLines(_ lines: [String], to bytes: inout [UInt8]) {
        for (index, line) in lines.enumerated() {
            bytes.append(contentsOf: line.utf8)
            if index < lines.count - 1 {
                appendCRLF(to: &bytes)
            }
        }
    }

    private func appendCRLF(to bytes: inout [UInt8]) {
        bytes.append(0x0D)
        bytes.append(0x0A)
    }

    private func flag(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    private func optionalFlag(_ value: Bool?) -> String {
        value.map(flag) ?? ""
    }

    private func optional(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private func enterTmuxModeAndStartAttachInit(_ controller: TmuxController) {
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(responseFrame(1, flags: 0))
    }

    /// Drive the controller all the way through the `-CC` mode entry
    /// dance — DCS prologue, tmux's spontaneous handshake `%begin/%end`,
    /// AND the attach-init query flow (history-limit, optional refresh-client,
    /// pause-after, bell subscription, list-windows, list-panes,
    /// display-message active window, and the pane metadata subscription) —
    /// leaving the controller in `.tmuxControl` mode
    /// with empty pendingCommands. Tests that just
    /// want a "controller in tmux mode, ready for action" baseline can
    /// call this and then `fed.clear()` / `sent.clear()` to start fresh.
    ///
    /// The init flow's responses are all empty so no windows or active
    /// pane are populated; tests that need specific state should ingest
    /// `%window-add` / `%output` notifications afterwards.
    private func enterTmuxModeAndDrainAttachInit(
        _ controller: TmuxController
    ) {
        // DCS prologue + tmux's spontaneous "I'm in -CC mode" handshake.
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(chunk)

        // The handshake drain triggers shared hydration. With no
        // `lastKnownSize` cached, history-limit, pause-after, bell
        // subscription, list-windows, list-panes, active-window, and pane
        // metadata subscription queries go out. (Test cases that DO want to
        // assert on the refresh-client -C emission set a size before calling
        // this helper.)
        if controller.controlPath == .inline {
            // Empty history-limit response.
            controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
            // Empty pause-after response.
            controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
            // Empty bell subscription response.
            controller.ingest(Array("%begin 0 4 1\r\n%end 0 4 1\r\n".utf8))
            // Empty list-windows response.
            controller.ingest(Array("%begin 0 5 1\r\n%end 0 5 1\r\n".utf8))
            // Empty list-panes response.
            controller.ingest(Array("%begin 0 6 1\r\n%end 0 6 1\r\n".utf8))
            // Empty active-window response.
            controller.ingest(Array("%begin 0 7 1\r\n%end 0 7 1\r\n".utf8))
            // Empty pane metadata subscription response.
            controller.ingest(Array("%begin 0 8 1\r\n%end 0 8 1\r\n".utf8))
        } else {
            // Empty pause-after response.
            controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
            // Empty bell subscription response.
            controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
            // Empty list-windows response.
            controller.ingest(Array("%begin 0 4 1\r\n%end 0 4 1\r\n".utf8))
            // Empty list-panes response.
            controller.ingest(Array("%begin 0 5 1\r\n%end 0 5 1\r\n".utf8))
            // Empty active-window response.
            controller.ingest(Array("%begin 0 6 1\r\n%end 0 6 1\r\n".utf8))
            // Empty pane metadata subscription response.
            controller.ingest(Array("%begin 0 7 1\r\n%end 0 7 1\r\n".utf8))
        }
    }

    private func enterSideChannelWithActivePane(
        _ controller: TmuxController,
        windowId: Int = 5,
        paneId: Int = 12
    ) {
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(chunk)
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8)) // pause-after
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8)) // bell subscription
        controller.ingest(Array("%begin 0 4 1\r\n@\(windowId)\teditor\r\n%end 0 4 1\r\n".utf8)) // windows
        controller.ingest(Array(
            "%begin 0 5 1\r\n@\(windowId)\t%\(paneId)\t1\tzsh\tpane title\thost\r\n%end 0 5 1\r\n".utf8
        )) // panes
        controller.ingest(Array("%begin 0 6 1\r\n@\(windowId)\r\n%end 0 6 1\r\n".utf8)) // active-window
        controller.ingest(Array("%begin 0 7 1\r\n%end 0 7 1\r\n".utf8)) // pane metadata subscription
    }

    private func populateBellFixture(_ controller: TmuxController) {
        let wire = """
        %window-renamed @1 editor\r
        %window-renamed @2 logs\r
        %session-window-changed $0 @1\r
        %window-pane-changed @1 %10\r
        %window-pane-changed @2 %20\r
        %output %10 seed\r

        """
        controller.ingest(Array(wire.utf8))
    }

    private func seedInlineRenderedWindow(
        _ controller: TmuxController,
        windowId: Int = 0,
        paneId: Int = 0,
        name: String = "zsh"
    ) {
        controller.ingest(Array("%window-add @\(windowId)\r\n".utf8))
        controller.ingest(Array("%begin 0 50 1\r\n\(name)\r\n%end 0 50 1\r\n".utf8))
        controller.ingest(Array("%output %\(paneId) boot\r\n".utf8))
    }

    // MARK: - Passthrough byte routing

    func test_passthrough_flushesFullChunkWhenTailIsNotDcsPrefix() {
        // When no byte at the tail of the chunk could start a DCS
        // (ESC = 0x1B), the whole chunk flushes immediately — no
        // character is held back as a reserve. This is the key
        // invariant that keeps typing echo feeling instant: a 1-byte
        // character echo arrives, gets forwarded, done.
        let (controller, fed, sent) = makeController()

        controller.ingest(Array("hello shell world!\r\n".utf8))

        XCTAssertEqual(controller.mode, .passthrough)
        XCTAssertEqual(sent.bytes, [])
        XCTAssertEqual(fed.bytes, Array("hello shell world!\r\n".utf8))
    }

    func test_passthrough_singleByteChunksFlushImmediately() {
        // The scenario that motivated the no-reserve fix: the shell
        // echoes keystrokes one byte at a time. Each byte must reach
        // the terminal on the ingest that delivered it, or typing
        // feels laggy (a held reserve of 6 bytes means the user sees
        // characters 6 behind where the cursor actually is).
        let (controller, fed, _) = makeController()

        for byte in Array("hi".utf8) {
            controller.ingest([byte])
            XCTAssertEqual(
                fed.bytes.last, byte,
                "every non-ESC single-byte chunk must flush on the same ingest"
            )
        }
        XCTAssertEqual(fed.bytes, Array("hi".utf8))
    }

    func test_passthrough_reservesOnlyDcsPrefixAtTail() {
        // If the tail byte is ESC (0x1B, first byte of DCS), we reserve
        // just that single byte — everything before it flushes. The
        // reserve grows only as far as the observed prefix matches.
        let (controller, fed, _) = makeController()

        // "foo" + ESC — tail reserves 1 byte (the ESC), flushes "foo".
        controller.ingest(Array("foo\u{1B}".utf8))
        XCTAssertEqual(fed.bytes, Array("foo".utf8))

        // Next chunk: "X" (random byte, not 'P'). Reserve was ESC alone,
        // which doesn't complete a DCS with 'X'. Flush "ESC X".
        controller.ingest([0x58])
        XCTAssertEqual(fed.bytes, Array("foo".utf8) + [0x1B, 0x58])
    }

    func test_passthrough_sendInputForwardsRaw() {
        let (controller, _, sent) = makeController()
        var observed: [(PaneId?, [UInt8])] = []
        controller.inputObserver = { observed.append(($0, $1)) }

        controller.sendInput(Array("echo hi\r".utf8))

        XCTAssertEqual(sent.bytes, Array("echo hi\r".utf8))
        XCTAssertEqual(observed.count, 1)
        XCTAssertNil(observed.first?.0)
        XCTAssertEqual(observed.first?.1, Array("echo hi\r".utf8))
    }

    // MARK: - DCS entry detection

    func test_ingest_dcsInCleanChunkFlipsMode() {
        let (controller, fed, _) = makeController()

        // Bytes before the DCS should end up on the terminal; bytes
        // after are tmux control-mode data and must not leak to
        // SwiftTerm as escape-sequence garbage.
        var chunk = Array("pre\n".utf8)
        chunk.append(contentsOf: [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]) // ESC P 1 0 0 0 p
        chunk.append(contentsOf: Array("%begin 1 0 0\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.mode, .tmuxControl)
        XCTAssertFalse(controller.isInitialRenderReady)
        XCTAssertEqual(fed.bytes, Array("pre\n".utf8),
                       "only pre-DCS bytes should reach the terminal")
    }

    func test_ingest_dcsSplitAcrossChunksStillDetected() {
        let (controller, fed, _) = makeController()

        // First chunk: prefix plus the first 4 bytes of the DCS (not
        // enough to match on its own).
        controller.ingest(Array("shell\n".utf8) + [0x1B, 0x50, 0x31, 0x30])
        XCTAssertEqual(controller.mode, .passthrough,
                       "partial DCS should not flip mode")

        // Second chunk: the remaining 3 DCS bytes plus tmux body.
        controller.ingest([0x30, 0x30, 0x70] + Array("%begin 1 0 0\n".utf8))
        XCTAssertEqual(controller.mode, .tmuxControl)

        // The shell prefix should be intact. The DCS bytes themselves
        // should not have leaked to the terminal.
        XCTAssertEqual(fed.bytes, Array("shell\n".utf8))
    }

    func test_ingest_tmuxOutputPaneBytesAreRendered() {
        let (controller, fed, _) = makeController()

        // Enter tmux mode and deliver a %output line for pane %0.
        // (Using \r\n and simple ASCII keeps the escape decoding trivial.)
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%output %0 hello-from-tmux\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.mode, .tmuxControl)
        XCTAssertEqual(controller.activePaneId, PaneId(0),
                       "first pane seen should be latched as active")
        XCTAssertTrue(controller.isInitialRenderReady)
        XCTAssertEqual(fed.bytes, Array("hello-from-tmux".utf8))
    }

    func test_passthroughSuppressionHidesBootstrapOutputUntilTmuxRender() {
        let (controller, fed, _) = makeController()
        controller.suppressPassthroughOutputUntilControlMode = true

        controller.ingest(Array("export COLORTERM=truecolor; clear; exec tmux -CC attach\r\n".utf8))
        XCTAssertEqual(fed.bytes, [],
                       "suppressed bootstrap output should not paint into the terminal")
        XCTAssertFalse(controller.isInitialRenderReady)

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%output %0 ready\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.mode, .tmuxControl)
        XCTAssertFalse(controller.suppressPassthroughOutputUntilControlMode)
        XCTAssertTrue(controller.isInitialRenderReady)
        XCTAssertEqual(fed.bytes, Array("ready".utf8))
    }

    func test_ingest_tmuxOutputInSideChannelModeIsDropped() {
        let (controller, fed, _) = makeController(controlPath: .sideChannel)

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%output %0 hello-from-tmux\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.mode, .tmuxControl)
        XCTAssertTrue(controller.isInitialRenderReady,
                      "side-channel control readiness is independent from terminal rendering")
        XCTAssertNil(controller.activePaneId,
                     "side-channel mode should not latch pane output as the render source")
        XCTAssertEqual(fed.bytes, [],
                       "side-channel control output must not reach the terminal renderer")
    }

    func test_paneOutputObserverSeesBackgroundSideChannelBytes() {
        let (controller, _, _) = makeController(controlPath: .sideChannel)
        var observed: [(PaneId, [UInt8])] = []
        controller.paneOutputObserver = { paneID, data in
            observed.append((paneID, Array(data)))
        }

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%output %17 prompt-ready\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, PaneId(17))
        XCTAssertEqual(observed.first?.1, Array("prompt-ready".utf8))
    }

    func test_ingest_exitMessageDropsBackToPassthrough() {
        let (controller, _, _) = makeController()

        // Enter tmux mode, latch pane, then see %exit.
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%output %0 x\r\n".utf8))
        chunk.append(contentsOf: Array("%exit\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.mode, .passthrough)
        XCTAssertNil(controller.activePaneId)
    }

    // MARK: - Input routing in tmux mode

    func test_sendInput_tmuxModeWrapsInSendKeysHex() {
        let (controller, _, sent) = makeController()

        // Enter tmux mode and latch pane %3 via an %output message.
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%output %3 seed\r\n".utf8))
        controller.ingest(chunk)
        XCTAssertEqual(controller.activePaneId, PaneId(3))

        // Now type "ab\n" — should become `send-keys -t %3 -H 61 62 0a\n`.
        // Each byte is a separate space-delimited hex argument so tmux
        // parses them individually via strtoull, not as one large integer.
        sent.clear()
        controller.sendInput([0x61, 0x62, 0x0A])

        let expected = Array("send-keys -t %3 -H 61 62 0a\n".utf8)
        XCTAssertEqual(sent.bytes, expected)
    }

    func test_sendInput_tmuxModeMultiByteSequenceSpaceSeparated() {
        // Arrow-Up escape sequence: ESC [ A (0x1B 0x5B 0x41).
        // Previously these 3 bytes were concatenated into "1b5b41",
        // which tmux parsed as one hex integer 0x1B5B41 — not 3 bytes.
        // With the space separator, tmux sees 3 arguments and sends
        // 3 bytes to the pane, which htop (and any TUI) interprets
        // as the Up arrow key.
        let (controller, _, sent) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%output %3 seed\r\n".utf8))
        controller.ingest(chunk)
        sent.clear()

        controller.sendInput([0x1B, 0x5B, 0x41])

        let expected = Array("send-keys -t %3 -H 1b 5b 41\n".utf8)
        XCTAssertEqual(sent.bytes, expected)
    }

    func test_sendInput_tmuxModeSingleByteHasNoSurroundingSpaces() {
        // Single-byte inputs must produce a single hex token with no
        // leading or trailing spaces — regression guard against an
        // over-correction that could add spurious whitespace.
        let (controller, _, sent) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%output %3 seed\r\n".utf8))
        controller.ingest(chunk)
        sent.clear()

        controller.sendInput([0x61]) // ASCII 'a'

        let expected = Array("send-keys -t %3 -H 61\n".utf8)
        XCTAssertEqual(sent.bytes, expected)
    }

    func test_sendInput_tmuxModeTracksReplyBeforeNextControlCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, paneId: 3)
        sent.clear()

        controller.sendInput([0x61])

        let capture = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand(
            "display-message -p -t %3 'cmd=#{pane_current_command}|pid=#{pane_pid}'"
        ) { result in
            capture.store(result)
        }

        XCTAssertEqual(
            sent.bytes,
            Array("send-keys -t %3 -H 61\ndisplay-message -p -t %3 'cmd=#{pane_current_command}|pid=#{pane_pid}'\n".utf8)
        )

        controller.ingest(Array("%begin 1 10 1\r\n%end 1 10 1\r\n".utf8))
        XCTAssertNil(
            capture.result,
            "empty send-keys response must drain the sendInput no-op, not the following command"
        )

        controller.ingest(Array("%begin 1 11 1\r\ncmd=codex|pid=42\r\n%end 1 11 1\r\n".utf8))

        guard case .success(let lines) = capture.result else {
            return XCTFail("display-message completion should receive its own response, got \(String(describing: capture.result))")
        }
        XCTAssertEqual(lines, ["cmd=codex|pid=42"])
    }

    func test_sendInput_tmuxModeWithoutPaneIsDropped() {
        let (controller, _, sent) = makeController()

        // Force tmux mode without delivering any %output — activePaneId
        // is still nil. sendInput should drop silently rather than
        // target a bogus pane.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        XCTAssertEqual(controller.mode, .tmuxControl)
        XCTAssertNil(controller.activePaneId)

        controller.sendInput([0x61])
        XCTAssertEqual(sent.bytes, [])
    }

    // MARK: - Window lifecycle (commit B)

    func test_windowAdd_appendsWindowAndLatchesActive() {
        let (controller, _, _) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @1\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.windows.map(\.id), [WindowId(0), WindowId(1)])
        XCTAssertEqual(controller.activeWindowId, WindowId(0),
                       "first window should be latched as active until tmux says otherwise")
    }

    func test_windowRenamed_updatesExistingEntry() {
        let (controller, _, _) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @2\r\n".utf8))
        chunk.append(contentsOf: Array("%window-renamed @2 editor\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.windows.count, 1)
        XCTAssertEqual(controller.windows.first?.name, "editor")
    }

    func test_windowRenamed_eagerlyCreatesEntryIfMissing() {
        let (controller, _, _) = makeController()

        // Rename arrives before add — tab should still appear with
        // the right label.
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-renamed @5 logs\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.windows, [.init(id: WindowId(5), name: "logs")])
    }

    func test_windowClose_removesAndReselects() {
        let (controller, _, _) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @1\r\n".utf8))
        chunk.append(contentsOf: Array("%window-close @0\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.windows.map(\.id), [WindowId(1)])
        XCTAssertEqual(controller.activeWindowId, WindowId(1),
                       "closing the active window should fall back to the next remaining one")
    }

    func test_unlinkedWindowClose_removesWindowFromTabList() {
        // tmux 3.6 emits `%unlinked-window-close @N` (NOT `%window-close`)
        // when `kill-window` removes the current window, because the
        // window is no longer in any winlink of the observing client's
        // session. See `control_notify_window_unlinked` in tmux
        // control-notify.c — the `%window-close` variant is reserved for
        // the rare case where the window is unlinked from one slot but
        // still exists in another winlink of the same session.
        //
        // Regression: the controller previously ignored
        // `.unlinkedWindowClose` entirely, leaving stale tab entries
        // after every ⌘⇧W in -CC mode. Bytes below are a verbatim
        // fragment of the real tmux -CC response to `kill-window`.
        let (controller, _, _) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @1\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @2\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @3\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @4\r\n".utf8))
        chunk.append(contentsOf: Array("%session-window-changed $0 @4\r\n".utf8))
        controller.ingest(chunk)
        XCTAssertEqual(controller.windows.count, 5)
        XCTAssertEqual(controller.activeWindowId, WindowId(4))

        // Exact bytes tmux 3.6 sends in response to `kill-window` when
        // the current window @4 is closed. The command-response frame
        // is empty (kill-window writes nothing to stdout), but the
        // async notifications update our state.
        let killResponse = """
        %begin 1775937936 298 1\r
        %end 1775937936 298 1\r
        %session-window-changed $0 @3\r
        %unlinked-window-close @4\r

        """
        controller.ingest(Array(killResponse.utf8))

        XCTAssertEqual(
            controller.windows.map(\.id),
            [WindowId(0), WindowId(1), WindowId(2), WindowId(3)],
            "%unlinked-window-close must remove the window from the tab list"
        )
        XCTAssertEqual(
            controller.activeWindowId,
            WindowId(3),
            "session-window-changed (sent before the close) already set @3 active"
        )
    }

    func test_unlinkedWindowClose_fallsBackWhenActiveDies() {
        // Defensive: even if tmux didn't send `%session-window-changed`
        // before `%unlinked-window-close` (an unexpected order but not
        // forbidden by the protocol), we should still reselect some
        // remaining window so the tab strip isn't left with a dangling
        // activeWindowId.
        let (controller, _, _) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @1\r\n".utf8))
        chunk.append(contentsOf: Array("%unlinked-window-close @1\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.windows.map(\.id), [WindowId(0)])
        XCTAssertEqual(controller.activeWindowId, WindowId(0),
                       "closing the active window without a prior session-window-changed should fall back to the first remaining window")
    }

    func test_sessionWindowChanged_updatesActiveWindow() {
        let (controller, _, _) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @1\r\n".utf8))
        chunk.append(contentsOf: Array("%session-window-changed $0 @1\r\n".utf8))
        controller.ingest(chunk)

        XCTAssertEqual(controller.activeWindowId, WindowId(1))
    }

    // MARK: - Cross-session broadcast filtering
    //
    // One tmux server hosts many sessions. `%session-window-changed`
    // and the `%*` pane-metadata subscription are broadcast to EVERY
    // `-CC` control client in the server, tagged with the session they
    // refer to. The controller must latch its own session id (from
    // `%session-changed` / `%client-session-changed`) and ignore the
    // broadcasts for other sessions — otherwise two clients attached to
    // different sessions of the same server (an iPad + the simulator
    // both hitting one Mac) drag each other's active window around.

    func test_sessionChanged_setsOwnSessionId() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array("%session-changed $0 main\r\n".utf8))

        XCTAssertEqual(controller.ownSessionId, SessionId(0))
    }

    func test_sessionChanged_toDifferentSessionBlocksOldWindowUntilRehydrated() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%session-changed $0 main\r\n%window-add @7\r\n".utf8))
        controller.ingest(Array("%begin 0 9 1\r\n%end 0 9 1\r\n".utf8)) // @7 metadata query
        XCTAssertTrue(controller.isWindowListHydrated)

        let oldGeneration = controller.controlConnectionGeneration
        sent.clear()
        controller.ingest(Array("%session-changed $1 work\r\n".utf8))

        XCTAssertEqual(controller.ownSessionId, SessionId(1))
        XCTAssertNotEqual(controller.controlConnectionGeneration, oldGeneration)
        XCTAssertFalse(controller.isWindowListHydrated)
        XCTAssertTrue(
            String(decoding: sent.bytes, as: UTF8.self).contains("list-windows -F"),
            "switching sessions must request an authoritative window list"
        )

        sent.clear()
        controller.killWindow(WindowId(7))
        XCTAssertEqual(sent.bytes, [], "an old-session tab must not remain a valid kill target")

        // history-limit, pause-after, bell subscription, then the new
        // session's authoritative list-windows response.
        controller.ingest(Array("%begin 0 10 1\r\n%end 0 10 1\r\n".utf8))
        controller.ingest(Array("%begin 0 11 1\r\n%end 0 11 1\r\n".utf8))
        controller.ingest(Array("%begin 0 12 1\r\n%end 0 12 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 13 1\r\n@9\tb25d,80x24,0,0,70\tb25d,80x24,0,0,70\t0\twork\r\n%end 0 13 1\r\n".utf8
        ))

        XCTAssertTrue(controller.isWindowListHydrated)
        XCTAssertEqual(controller.windows.map(\.id), [WindowId(9)])
        sent.clear()

        controller.killWindow(WindowId(9))

        XCTAssertEqual(sent.bytes, Array("kill-window -t @9\n".utf8))
    }

    func test_clientSessionChanged_doesNotChangeOwnSession() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        // Our own session ($0) comes from %session-changed.
        controller.ingest(Array("%session-changed $0 main\r\n".utf8))
        XCTAssertEqual(controller.ownSessionId, SessionId(0))

        // %client-session-changed announces ANOTHER client's session
        // change (leading token is that peer's client name). It must NOT
        // touch our ownSessionId — otherwise the peer's broadcasts would
        // start passing the foreign-session filter (the live regression
        // that re-opened this bug).
        controller.ingest(Array("%client-session-changed peer-client $5 work\r\n".utf8))
        XCTAssertEqual(controller.ownSessionId, SessionId(0))

        // The peer's window switch ($5) is therefore still dropped.
        controller.ingest(Array("%session-window-changed $5 @50\r\n".utf8))
        XCTAssertNil(controller.activeWindowId)
        XCTAssertFalse(controller.windows.contains { $0.id == WindowId(50) })
    }

    func test_sessionWindowChanged_ownSessionSwitches() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array("%session-changed $0 main\r\n".utf8))
        controller.ingest(Array("%window-renamed @0 zsh\r\n".utf8))
        controller.ingest(Array("%window-renamed @1 editor\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))

        XCTAssertEqual(controller.activeWindowId, WindowId(1))
    }

    func test_sessionWindowChanged_foreignSessionIgnored() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        // Latch our own session ($0), then switch to one of our windows.
        controller.ingest(Array("%session-changed $0 main\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        XCTAssertEqual(controller.ownSessionId, SessionId(0))
        XCTAssertEqual(controller.activeWindowId, WindowId(1))

        // A window switch in ANOTHER session ($1) of the same server must
        // not move us and must not add the foreign window @99 to our list.
        controller.ingest(Array("%session-window-changed $1 @99\r\n".utf8))
        XCTAssertEqual(controller.activeWindowId, WindowId(1))
        XCTAssertFalse(controller.windows.contains { $0.id == WindowId(99) })
    }

    func test_sessionWindowChanged_failOpenWithoutSessionChanged() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        // No %session-changed observed → ownSessionId stays nil → the
        // filter FAILS OPEN so the single-client path behaves exactly as
        // before (mirrors test_sessionWindowChanged_updatesActiveWindow).
        XCTAssertNil(controller.ownSessionId)
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        XCTAssertEqual(controller.activeWindowId, WindowId(1))
    }

    func test_subscriptionChanged_foreignSessionIgnored() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array("%session-changed $0 main\r\n".utf8))
        let paneBefore = controller.activePaneId

        // Pane metadata delivered for a window in another session ($1)
        // via the server-wide `%*` subscription must not touch our model.
        controller.ingest(Array(
            "%subscription-changed tessera-pane-meta $1 @77 0 %88 : @77\t%88\t1\tbash\tforeign\tlogs\thost\r\n".utf8
        ))

        XCTAssertFalse(controller.windows.contains { $0.id == WindowId(77) })
        XCTAssertEqual(controller.activePaneId, paneBefore)
    }

    // MARK: - Bell notifications

    func test_bellForInactiveWindowFiresCallbackAndTracksWindow() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        var received: (windowID: Int, isActiveWindow: Bool, windowName: String?)?
        controller.onBell = { windowID, isActiveWindow, windowName in
            received = (windowID, isActiveWindow, windowName)
        }

        controller.ingest(Array("%output %20 hello\u{07}world\r\n".utf8))

        XCTAssertEqual(received?.windowID, 2)
        XCTAssertEqual(received?.isActiveWindow, false)
        XCTAssertEqual(received?.windowName, "logs")
        XCTAssertEqual(controller.bellingWindows, [2])
    }

    func test_bellForActiveWindowFiresCallbackWithoutTrackingWindow() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        var received: (windowID: Int, isActiveWindow: Bool, windowName: String?)?
        controller.onBell = { windowID, isActiveWindow, windowName in
            received = (windowID, isActiveWindow, windowName)
        }

        controller.ingest(Array("%output %10 \u{07}\r\n".utf8))

        XCTAssertEqual(received?.windowID, 1)
        XCTAssertEqual(received?.isActiveWindow, true)
        XCTAssertEqual(received?.windowName, "editor")
        XCTAssertTrue(controller.bellingWindows.isEmpty)
    }

    func test_clearBellRemovesWindowFromTrackedSet() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)
        controller.ingest(Array("%output %20 \u{07}\r\n".utf8))
        XCTAssertEqual(controller.bellingWindows, [2])

        controller.clearBell(forWindowID: 2)

        XCTAssertTrue(controller.bellingWindows.isEmpty)
    }

    func test_selectWindowClearsBellForTargetWindow() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)
        controller.ingest(Array("%output %20 \u{07}\r\n".utf8))
        XCTAssertEqual(controller.bellingWindows, [2])
        sent.clear()

        controller.selectWindow(atPosition: 2)

        XCTAssertTrue(controller.bellingWindows.isEmpty)
        XCTAssertEqual(sent.bytes, Array("select-window -t @2\n".utf8))
    }

    func test_bellSubscription_edgeTriggersForBackgroundWindowOnly() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        var received: [(Int, Bool, String?)] = []
        controller.onBell = { windowID, isActiveWindow, windowName in
            received.append((windowID, isActiveWindow, windowName))
        }

        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 0\r\n".utf8
        ))
        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 1\r\n".utf8
        ))
        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 1\r\n".utf8
        ))
        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @1 0 %10 : 1\r\n".utf8
        ))

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, 2)
        XCTAssertEqual(received.first?.1, false)
        XCTAssertEqual(received.first?.2, "logs")
        XCTAssertEqual(controller.bellingWindows, [2])
    }

    func test_bellSubscription_foreignSessionIgnoredBeforeNameDispatch() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)
        controller.ingest(Array("%session-changed $0 main\r\n".utf8))

        var received: [Int] = []
        controller.onBell = { windowID, _, _ in
            received.append(windowID)
        }

        controller.ingest(Array(
            "%subscription-changed tessera-bell $1 @2 1 %20 : 1\r\n".utf8
        ))
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(controller.bellingWindows.isEmpty)

        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 1\r\n".utf8
        ))
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(controller.bellingWindows.isEmpty)

        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 0\r\n".utf8
        ))
        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(controller.bellingWindows.isEmpty)

        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 1\r\n".utf8
        ))
        XCTAssertEqual(received, [2])
        XCTAssertEqual(controller.bellingWindows, [2])
    }

    func test_bellSubscription_firstObservationOneSeedsWithoutRinging() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        var received: [Int] = []
        controller.onBell = { windowID, _, _ in
            received.append(windowID)
        }

        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 1\r\n".utf8
        ))

        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(controller.bellingWindows.isEmpty)
    }

    func test_bellSubscription_zeroThenOneRingsOnce() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        var received: [Int] = []
        controller.onBell = { windowID, _, _ in
            received.append(windowID)
        }

        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 0\r\n".utf8
        ))
        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 1\r\n".utf8
        ))
        controller.ingest(Array(
            "%subscription-changed tessera-bell $0 @2 1 %20 : 1\r\n".utf8
        ))

        XCTAssertEqual(received, [2])
        XCTAssertEqual(controller.bellingWindows, [2])
    }

    // MARK: - Window-name discovery (§3.2 commit C part 3)

    func test_windowAdd_queriesWindowName() {
        // After the attach-init drain leaves a clean state, ingest a
        // %window-add for a brand-new window and assert the controller
        // immediately fires display-message -p -t @N '#{window_name}'.
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        controller.ingest(Array("%window-add @5\r\n".utf8))

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "display-message -p -t @5 '#{window_name}'\n",
            "windowAdd should query window_name when the entry is still on the @N placeholder"
        )
        XCTAssertEqual(controller.windows.first?.name, "@5",
                       "name stays on placeholder until the query response arrives")
    }

    func test_windowAdd_queryResponseUpdatesName() {
        // End-to-end: %window-add → query fired → response arrives →
        // windows[@5].windowName is updated as the display fallback.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array("%window-add @5\r\n".utf8))
        XCTAssertEqual(controller.windows.first?.name, "@5")

        controller.ingest(Array("%begin 1 1 1\r\neditor\r\n%end 1 1 1\r\n".utf8))

        XCTAssertEqual(controller.windows.first?.name, "editor",
                       "query response should update the window's name")
    }

    func test_windowAdd_queryResponseDoesNotOverwriteRealRename() {
        // Race: tmux sends %window-renamed (e.g. shell-startup
        // auto-rename for default `new-window`) between our query and
        // its reply. The rename arrives first, replacing the
        // placeholder. Our subsequent query response must not overwrite
        // the confirmed name.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array(
            "%window-add @5\r\n%window-renamed @5 hello\r\n".utf8
        ))
        XCTAssertEqual(controller.windows.first?.name, "hello",
                       "rename should land before the query response")

        // Late query response carrying a different (stale) name.
        controller.ingest(Array("%begin 1 1 1\r\neditor\r\n%end 1 1 1\r\n".utf8))

        XCTAssertEqual(controller.windows.first?.name, "hello",
                       "query response must not overwrite a real %window-renamed")
    }

    func test_windowAdd_doesNotQueryWhenAttachInitAlreadyNamedTheWindow() {
        // The attach-init list-windows response populates window names
        // up front. If %window-add arrives afterwards for the same id
        // (idempotent dedupe), the handler must NOT issue a redundant
        // window_name query — the name is already known.
        let (controller, _, sent) = makeController()

        // Drive the attach-init flow with a populated list-windows.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5 editor\r\n%end 0 5 1\r\n".utf8
        ))
        XCTAssertEqual(controller.windows.first?.name, "editor")
        sent.clear()

        // Idempotent windowAdd. The entry already has a real name.
        controller.ingest(Array("%window-add @5\r\n".utf8))

        XCTAssertEqual(
            sent.bytes,
            [],
            "windowAdd must NOT re-query when the entry already has a non-placeholder name"
        )
    }

    // MARK: - OSC title → pane title

    func test_windowInfoDisplayNamePrefersNonDefaultPaneTitleThenWindowNameThenId() {
        XCTAssertEqual(
            TmuxController.WindowInfo(id: WindowId(3)).displayName,
            "@3"
        )
        XCTAssertEqual(
            TmuxController.WindowInfo(id: WindowId(3), windowName: "logs").displayName,
            "logs"
        )
        XCTAssertEqual(
            TmuxController.WindowInfo(
                id: WindowId(3),
                windowName: "logs",
                activePaneId: PaneId(8),
                activePaneTitle: "htop"
            ).displayName,
            "htop"
        )
        XCTAssertEqual(
            TmuxController.WindowInfo(
                id: WindowId(3),
                windowName: "htop",
                activePaneTitle: "remote.example.com",
                activePaneTitleIsDefault: true
            ).displayName,
            "htop"
        )
        XCTAssertEqual(
            TmuxController.WindowInfo(
                id: WindowId(3),
                windowName: "logs",
                activePaneTitle: "   "
            ).displayName,
            "logs"
        )
    }

    func test_updateActiveWindowName_setsActivePaneTitleInTmuxMode() {
        // OSC titles are pane_title updates. They should drive the
        // display label without clobbering tmux's window_name fallback.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array(
            "%window-add @0\r\n%window-renamed @0 zsh\r\n".utf8
        ))
        // Drain the window-name query — rename arrived first so the
        // callback no-ops, but we need to keep the FIFO tidy.
        controller.ingest(Array("%begin 0 99 1\r\nzsh\r\n%end 0 99 1\r\n".utf8))
        XCTAssertEqual(controller.windows.first?.name, "zsh")

        controller.updateActiveWindowName("user@host:~/dir")

        XCTAssertEqual(controller.windows.first?.windowName, "zsh")
        XCTAssertEqual(controller.windows.first?.activePaneTitle, "user@host:~/dir")
        XCTAssertEqual(controller.windows.first?.displayName, "user@host:~/dir")
    }

    func test_updateActiveWindowName_preservesWindowNameFallback() {
        // Explicit window names remain as windowName fallback; a pane
        // title can still become the visible display name.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array("%window-add @5\r\n".utf8))
        // Feed the name query response — this locks the window.
        controller.ingest(Array("%begin 0 99 1\r\neditor\r\n%end 0 99 1\r\n".utf8))
        XCTAssertEqual(controller.windows.first?.name, "editor")

        controller.updateActiveWindowName("htop - monitoring")

        XCTAssertEqual(controller.windows.first?.windowName, "editor")
        XCTAssertEqual(controller.windows.first?.activePaneTitle, "htop - monitoring")
        XCTAssertEqual(controller.windows.first?.displayName, "htop - monitoring")
    }

    func test_windowRenamed_updatesFallbackWithoutClobberingPaneTitle() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        // Named window: queryWindowName locks it.
        controller.ingest(Array("%window-add @5\r\n".utf8))
        controller.ingest(Array("%begin 0 99 1\r\neditor\r\n%end 0 99 1\r\n".utf8))
        XCTAssertEqual(controller.windows.first?.name, "editor")

        controller.updateActiveWindowName("pane-title")
        XCTAssertEqual(controller.windows.first?.displayName, "pane-title")

        // tmux fires a rename (user: `tmux rename-window logs`).
        controller.ingest(Array("%window-renamed @5 logs\r\n".utf8))

        XCTAssertEqual(controller.windows.first?.windowName, "logs")
        XCTAssertEqual(controller.windows.first?.activePaneTitle, "pane-title")
        XCTAssertEqual(controller.windows.first?.displayName, "pane-title")
    }

    func test_updateActiveWindowName_noOpInPassthrough() {
        // No tmux mode, no tab strip — the call should be a silent no-op.
        let (controller, _, _) = makeController()
        XCTAssertEqual(controller.mode, .passthrough)

        controller.updateActiveWindowName("title")
        // No crash, no state change.
        XCTAssertTrue(controller.windows.isEmpty)
    }

    // MARK: - Control commands (commit C)

    func test_sendControlCommand_tmuxModeAppendsNewlineAndSends() {
        let (controller, _, sent) = makeController()

        // Enter tmux mode via DCS so the command is actually dispatched.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        XCTAssertEqual(controller.mode, .tmuxControl)
        sent.clear()

        controller.sendControlCommand("new-window")

        XCTAssertEqual(sent.bytes, Array("new-window\n".utf8),
                       "sendControlCommand should send the command followed by a single newline")
    }

    func test_sendControlCommand_doesNotDoubleNewline() {
        let (controller, _, sent) = makeController()

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        sent.clear()

        // Caller already included a trailing newline — we must not add a second.
        controller.sendControlCommand("kill-window\n")

        XCTAssertEqual(sent.bytes, Array("kill-window\n".utf8))
    }

    func test_sendControlCommand_passthroughIsNoOp() {
        let (controller, _, sent) = makeController()
        // No DCS — controller is still in passthrough.
        XCTAssertEqual(controller.mode, .passthrough)

        controller.sendControlCommand("new-window")

        XCTAssertEqual(sent.bytes, [],
                       "control commands in passthrough must drop silently — no tmux to talk to")
    }

    func test_newWindow_sendsNewWindowCommand() {
        let (controller, _, sent) = makeController()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        sent.clear()

        controller.newWindow()

        XCTAssertEqual(sent.bytes, Array("new-window -e COLORTERM=truecolor\n".utf8))
    }

    func test_newWindow_replaysCachedClientSizeBeforeCommand() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        controller.updateClientSize(cols: 166, rows: 54)
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        sent.clear()

        controller.newWindow()

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "refresh-client -C 166,54\nnew-window -e COLORTERM=truecolor\n"
        )
    }

    func test_killCurrentWindow_sendsKillWindowCommand() {
        let (controller, _, sent) = makeController()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        sent.clear()

        controller.killCurrentWindow()

        XCTAssertEqual(sent.bytes, Array("kill-window\n".utf8))
    }

    func test_killWindow_targetsTrackedWindowById() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @7\r\n".utf8))
        sent.clear()

        controller.killWindow(WindowId(7))

        XCTAssertEqual(sent.bytes, Array("kill-window -t @7\n".utf8))
    }

    func test_killWindow_unknownWindowIsNoOp() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        sent.clear()

        controller.killWindow(WindowId(9))

        XCTAssertEqual(sent.bytes, [])
    }

    func test_killWindow_blocksPreservedSideChannelTabUntilRehydrated() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @7\r\n".utf8))
        XCTAssertTrue(controller.isWindowListHydrated)

        let oldGeneration = controller.controlConnectionGeneration
        controller.sideChannelDisconnected()
        XCTAssertFalse(controller.isWindowListHydrated)
        XCTAssertNotEqual(controller.controlConnectionGeneration, oldGeneration)

        // Re-enter control mode, but leave the queued list-windows response
        // pending. The preserved @7 is stale until that response arrives.
        sent.clear()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 10 0\r\n%end 0 10 0\r\n".utf8))
        XCTAssertEqual(controller.mode, .tmuxControl)
        XCTAssertFalse(controller.isWindowListHydrated)
        sent.clear()

        controller.killWindow(WindowId(7))

        XCTAssertEqual(sent.bytes, [], "a stale preserved tab must not emit a targeted kill")

        // pause-after, bell subscription, then authoritative list-windows.
        controller.ingest(Array("%begin 0 11 1\r\n%end 0 11 1\r\n".utf8))
        controller.ingest(Array("%begin 0 12 1\r\n%end 0 12 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 13 1\r\n@7\tb25d,80x24,0,0,70\tb25d,80x24,0,0,70\t0\tlogs\r\n%end 0 13 1\r\n".utf8
        ))
        XCTAssertTrue(controller.isWindowListHydrated)
        sent.clear()

        controller.killWindow(WindowId(7))

        XCTAssertEqual(sent.bytes, Array("kill-window -t @7\n".utf8))
    }

    func test_previousWindow_sendsPreviousWindowCommand() {
        let (controller, _, sent) = makeController()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        sent.clear()

        controller.previousWindow()

        XCTAssertEqual(sent.bytes, Array("previous-window\n".utf8))
    }

    func test_nextWindow_sendsNextWindowCommand() {
        let (controller, _, sent) = makeController()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        sent.clear()

        controller.nextWindow()

        XCTAssertEqual(sent.bytes, Array("next-window\n".utf8))
    }

    func test_selectWindow_targetsWindowById_notPositionalIndex() {
        // ⌘1 / ⌘2 / ⌘3 map to the 1st, 2nd, 3rd known windows. We
        // target by @id so it doesn't depend on the server's base-index
        // configuration — ⌘1 always means "the window currently shown
        // as the first tab," whatever @id tmux gave it.
        let (controller, _, sent) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @5\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @7\r\n".utf8))
        chunk.append(contentsOf: Array("%window-add @9\r\n".utf8))
        controller.ingest(chunk)
        sent.clear()

        controller.selectWindow(atPosition: 2)

        XCTAssertEqual(sent.bytes, Array("select-window -t @7\n".utf8),
                       "position 2 should target the second window in our list, which is @7")
    }

    func test_selectWindow_outOfRangeIsNoOp() {
        let (controller, _, sent) = makeController()
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @0\r\n".utf8))
        controller.ingest(chunk)
        sent.clear()

        // Only one window. Position 5 has no target.
        controller.selectWindow(atPosition: 5)
        XCTAssertEqual(sent.bytes, [])

        // Sanity: zero and negative positions also drop.
        controller.selectWindow(atPosition: 0)
        controller.selectWindow(atPosition: -1)
        XCTAssertEqual(sent.bytes, [])
    }

    func test_selectWindow_passthroughIsNoOp() {
        let (controller, _, sent) = makeController()
        // Never entered tmux mode.
        controller.selectWindow(atPosition: 1)
        XCTAssertEqual(sent.bytes, [])
    }

    // MARK: - Command-response (§3.2 commit C)

    func test_sendControlCommand_withCompletion_firesOnEndWithBody() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        let capture = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("display-message -p '#{pane_id}'") { result in
            capture.store(result)
        }

        XCTAssertEqual(
            sent.bytes,
            Array("display-message -p '#{pane_id}'\n".utf8),
            "command should be sent with trailing newline"
        )
        XCTAssertNil(capture.result, "completion should not fire until tmux replies")

        // Tmux response: empty body, single line, terminated by %end.
        controller.ingest(Array("%begin 1 1 1\r\n%5\r\n%end 1 1 1\r\n".utf8))

        guard case .success(let lines) = capture.result else {
            return XCTFail("completion should have fired with .success, got \(String(describing: capture.result))")
        }
        XCTAssertEqual(lines, ["%5"])
    }

    func test_sendControlCommand_withCompletion_firesOnErrorWithBodyLines() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        let capture = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("select-window -t @99") { result in
            capture.store(result)
        }

        controller.ingest(Array(
            "%begin 1 1 1\r\ncan't find window @99\r\n%error 1 1 1\r\n".utf8
        ))

        guard case .failure(let err) = capture.result,
              case .tmuxError(let lines) = err
        else {
            return XCTFail("expected tmuxError, got \(String(describing: capture.result))")
        }
        XCTAssertEqual(lines, ["can't find window @99"])
    }

    func test_sendControlCommand_withCompletion_passthroughFiresNotInTmuxMode() {
        let (controller, _, sent) = makeController()
        // No DCS ingested — still passthrough.

        let capture = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("new-window") { result in
            capture.store(result)
        }

        XCTAssertEqual(sent.bytes, [], "no bytes should be sent in passthrough mode")
        guard case .failure(.notInTmuxMode) = capture.result else {
            return XCTFail("expected .notInTmuxMode, got \(String(describing: capture.result))")
        }
    }

    func test_sendControlCommand_multipleInFlight_poppedInFIFOOrder() {
        // tmux serializes control commands, so when we queue A then B
        // the first %end pops A's completion and the second pops B's.
        // Verifies that the FIFO correlation stays correct even when
        // bodies differ in line count.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        let captureA = CompletionCapture<[String], TmuxController.CommandError>()
        let captureB = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("query-a") { captureA.store($0) }
        controller.sendControlCommand("query-b") { captureB.store($0) }

        // First response (A): single-line body.
        controller.ingest(Array("%begin 1 1 1\r\nalpha\r\n%end 1 1 1\r\n".utf8))
        // Second response (B): two-line body.
        controller.ingest(Array("%begin 1 2 1\r\nbeta\r\ngamma\r\n%end 1 2 1\r\n".utf8))

        guard case .success(let linesA) = captureA.result else {
            return XCTFail("A should have succeeded, got \(String(describing: captureA.result))")
        }
        guard case .success(let linesB) = captureB.result else {
            return XCTFail("B should have succeeded, got \(String(describing: captureB.result))")
        }
        XCTAssertEqual(linesA, ["alpha"])
        XCTAssertEqual(linesB, ["beta", "gamma"])
    }

    func test_sendControlCommand_fireAndForgetStaysInSyncWithQueue() {
        // The fire-and-forget `sendControlCommand(String)` path must
        // still queue a pending entry so a subsequent callback-variant
        // command sees its own %end, not the fire-and-forget's.
        // Regression guard for a subtle FIFO mismatch if the two
        // variants went through separate codepaths.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        let capture = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("new-window") // fire-and-forget
        controller.sendControlCommand("display-message -p '#{pane_id}'") { capture.store($0) }

        // First %end drains the fire-and-forget; the callback variant
        // should not see it.
        controller.ingest(Array("%begin 1 1 1\r\n%end 1 1 1\r\n".utf8))
        XCTAssertNil(capture.result, "fire-and-forget's %end must not fire the callback's completion")

        // Second %end drains the callback variant.
        controller.ingest(Array("%begin 1 2 1\r\n%1\r\n%end 1 2 1\r\n".utf8))
        guard case .success(let lines) = capture.result else {
            return XCTFail("callback should have fired, got \(String(describing: capture.result))")
        }
        XCTAssertEqual(lines, ["%1"])
    }

    func test_captureActivePrimaryPaneScrollback_sideChannelReturnsRepaintBytes() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterSideChannelWithActivePane(controller)
        XCTAssertEqual(controller.activePaneId, PaneId(12))
        sent.clear()

        var capture: TmuxController.ScrollbackCapture?
        controller.captureActivePrimaryPaneScrollback(depth: 42) { value in
            capture = value
        }

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "display-message -p -t %12 '\(TmuxController.renderedPaneMetadataFormat)'\n"
        )
        XCTAssertNil(capture)

        sent.clear()
        controller.ingest(responseFrame(
            100,
            body: [renderedPaneMetadataLine(
                paneId: 12,
                cursorX: 3,
                cursorY: 4,
                alternateOn: false,
                historySize: 400
            )]
        ))

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -S -42 -t %12\n"
        )
        XCTAssertNil(capture)

        controller.ingest(responseFrame(101, body: ["history 1", "history 2", "visible"]))

        XCTAssertEqual(capture?.paneId, PaneId(12))
        XCTAssertEqual(capture?.requestedDepth, 42)
        XCTAssertEqual(capture?.historySize, 400)
        XCTAssertEqual(capture?.capturedLineCount, 3)
        let repaint = String(decoding: capture?.repaintBytes ?? [], as: UTF8.self)
        XCTAssertTrue(repaint.contains("\u{1B}[2J"))
        XCTAssertTrue(repaint.contains("history 1\r\nhistory 2\r\nvisible"))
        XCTAssertTrue(repaint.contains("\u{1B}[5;4H"))
    }

    func test_captureActivePrimaryPaneScrollback_clientRowsOverrideSuppressesFullPaneScrollRegion() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterSideChannelWithActivePane(controller)
        sent.clear()

        var capture: TmuxController.ScrollbackCapture?
        controller.captureActivePrimaryPaneScrollback(depth: 42, clientRows: 10) { value in
            capture = value
        }

        sent.clear()
        controller.ingest(responseFrame(
            100,
            body: [renderedPaneMetadataLine(
                paneId: 12,
                scrollRegionUpper: 0,
                scrollRegionLower: 9
            )]
        ))

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -S -42 -t %12\n"
        )

        controller.ingest(responseFrame(101, body: ["visible"]))

        let repaint = String(decoding: capture?.repaintBytes ?? [], as: UTF8.self)
        XCTAssertFalse(
            repaint.contains("\u{1B}[1;10r"),
            "a full-pane scroll region should be suppressed against the pane row count"
        )
    }

    func test_captureActivePrimaryPaneScrollback_altScreenDoesNotCapture() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterSideChannelWithActivePane(controller)
        sent.clear()

        var captureWasCalled = false
        controller.captureActivePrimaryPaneScrollback(depth: 42) { value in
            captureWasCalled = true
            XCTAssertNil(value)
        }

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "display-message -p -t %12 '\(TmuxController.renderedPaneMetadataFormat)'\n"
        )

        sent.clear()
        controller.ingest(responseFrame(
            100,
            body: [renderedPaneMetadataLine(paneId: 12, alternateOn: true)]
        ))

        XCTAssertTrue(captureWasCalled)
        XCTAssertEqual(sent.bytes, [], "alt-screen gate must not issue capture-pane")
    }

    func test_captureActivePrimaryPaneScrollbackResult_reportsAltScreenAndCachesState() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterSideChannelWithActivePane(controller)
        XCTAssertEqual(controller.windows.first?.panes.first?.isAlternateScreen, nil)
        sent.clear()

        var result: TmuxController.ScrollbackCaptureResult?
        controller.captureActivePrimaryPaneScrollbackResult(depth: 42) { value in
            result = value
        }

        sent.clear()
        controller.ingest(responseFrame(
            100,
            body: [renderedPaneMetadataLine(
                paneId: 12,
                alternateOn: true,
                mouseStandard: true,
                mouseSgr: true
            )]
        ))

        XCTAssertEqual(result, .skipped(.alternateScreen))
        XCTAssertEqual(controller.windows.first?.panes.first?.isAlternateScreen, true)
        XCTAssertEqual(controller.windows.first?.panes.first?.isMouseReporting, true)
        XCTAssertEqual(controller.windows.first?.panes.first?.isSgrMouse, true)
        XCTAssertEqual(sent.bytes, [], "alt-screen gate must not issue capture-pane")
    }

    func test_queryActivePaneInteractionState_reportsAltScreenMouseAndCachesState() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterSideChannelWithActivePane(controller)
        sent.clear()

        var state: TmuxController.PaneInteractionState?
        controller.queryActivePaneInteractionState { value in
            state = value
        }

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "display-message -p -t %12 '\(TmuxController.renderedPaneMetadataFormat)'\n"
        )

        sent.clear()
        controller.ingest(responseFrame(
            100,
            body: [renderedPaneMetadataLine(
                paneId: 12,
                alternateOn: true,
                mouseButton: true,
                mouseSgr: true
            )]
        ))

        XCTAssertEqual(state?.paneId, PaneId(12))
        XCTAssertEqual(state?.isAlternateScreen, true)
        XCTAssertEqual(state?.isMouseReporting, true)
        XCTAssertEqual(state?.isSgrMouse, true)
        XCTAssertEqual(controller.windows.first?.panes.first?.isAlternateScreen, true)
        XCTAssertEqual(controller.windows.first?.panes.first?.isMouseReporting, true)
        XCTAssertEqual(controller.windows.first?.panes.first?.isSgrMouse, true)
        XCTAssertEqual(sent.bytes, [], "interaction query must not issue capture-pane")
    }

    func test_parseRenderedPaneState_legacySevenFieldLine() {
        let state = TmuxController.parseRenderedPaneState("%3\t12\t5\tpane title\teditor\thost\t1")

        XCTAssertEqual(state?.paneId, PaneId(3))
        XCTAssertEqual(state?.cursorX, 12)
        XCTAssertEqual(state?.cursorY, 5)
        XCTAssertEqual(state?.paneTitle, "pane title")
        XCTAssertEqual(state?.windowName, "editor")
        XCTAssertEqual(state?.paneInAltScreen, true)
        XCTAssertEqual(state?.paneTitleIsDefault, false)
        XCTAssertNil(state?.historySize)
        XCTAssertNil(state?.mouseAll)
    }

    func test_parseRenderedPaneState_fullExtendedLine() {
        let fields = [
            "%7", "8", "9", "htop", "ops", "host", "1",
            "1234", "4", "19", "0", "1", "1", "1", "0",
            "0", "0", "1", "1", "1", "2", "3",
        ]

        let state = TmuxController.parseRenderedPaneState(fields.joined(separator: "\t"))

        XCTAssertEqual(state?.paneId, PaneId(7))
        XCTAssertEqual(state?.cursorX, 8)
        XCTAssertEqual(state?.cursorY, 9)
        XCTAssertEqual(state?.paneInAltScreen, true)
        XCTAssertEqual(state?.historySize, 1234)
        XCTAssertEqual(state?.scrollRegionUpper, 4)
        XCTAssertEqual(state?.scrollRegionLower, 19)
        XCTAssertEqual(state?.cursorVisible, false)
        XCTAssertEqual(state?.insertMode, true)
        XCTAssertEqual(state?.keypadCursor, true)
        XCTAssertEqual(state?.keypadApplication, true)
        XCTAssertEqual(state?.wrapMode, false)
        XCTAssertEqual(state?.mouseStandard, false)
        XCTAssertEqual(state?.mouseButton, false)
        XCTAssertEqual(state?.mouseAll, true)
        XCTAssertEqual(state?.mouseSgr, true)
        XCTAssertEqual(state?.originMode, true)
        XCTAssertEqual(state?.altSavedX, 2)
        XCTAssertEqual(state?.altSavedY, 3)
    }

    func test_parseRenderedPaneState_emptyOptionalFieldsAreNil() {
        let fields = ["%1", "0", "0", "", "win", "host", "0"] + Array(repeating: "", count: 15)

        let state = TmuxController.parseRenderedPaneState(fields.joined(separator: "\t"))

        XCTAssertEqual(state?.paneId, PaneId(1))
        XCTAssertEqual(state?.paneInAltScreen, false)
        XCTAssertNil(state?.paneTitle)
        XCTAssertNil(state?.historySize)
        XCTAssertNil(state?.scrollRegionUpper)
        XCTAssertNil(state?.cursorVisible)
        XCTAssertNil(state?.originMode)
        XCTAssertNil(state?.altSavedY)
    }

    func test_parseRenderedPaneState_alternateOnSurvivesTrailingFields() {
        let fields = [
            "%2", "1", "2", "", "", "", "1",
            "42", "", "", "", "", "", "", "",
            "", "", "", "", "", "", "",
        ]

        let state = TmuxController.parseRenderedPaneState(fields.joined(separator: "\t"))

        XCTAssertEqual(state?.paneId, PaneId(2))
        XCTAssertEqual(state?.paneInAltScreen, true)
        XCTAssertEqual(state?.historySize, 42)
    }

    func test_parseRenderedPaneState_alternateSavedSentinelAndCoordinates() {
        var fields = [
            "%5", "0", "0", "vim", "code", "host", "1",
            "0", "", "", "", "", "", "", "",
            "", "", "", "", "", "4294967295", "4294967295",
        ]

        var state = TmuxController.parseRenderedPaneState(fields.joined(separator: "\t"))

        XCTAssertNil(state?.altSavedX)
        XCTAssertNil(state?.altSavedY)

        fields[20] = "12"
        fields[21] = "3"
        state = TmuxController.parseRenderedPaneState(fields.joined(separator: "\t"))

        XCTAssertEqual(state?.altSavedX, 12)
        XCTAssertEqual(state?.altSavedY, 3)
    }

    func test_repaintBytes_nonAltViewportStage_matchesSpec() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        let metadata = renderedPaneMetadataLine(
            paneId: 31,
            cursorX: 4,
            cursorY: 2,
            paneTitle: "viewport pane",
            windowName: "editor"
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        let captureLines = ["view one", "view two"]
        controller.ingest(responseFrame(2, body: captureLines, time: 1))

        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(captureLines: captureLines, cursorX: 4, cursorY: 2)
        )
        expectSent(sent, renderedMetadataCommand(windowId: 1))
    }

    func test_foregroundRefreshRetriesViewportInPlaceWithoutReplayingHistory() async throws {
        let (controller, fed, sent) = makeController()
        controller.renderRefreshRetryDelay = 0.01
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        XCTAssertEqual(controller.activeWindowId, WindowId(1))
        XCTAssertEqual(controller.activePaneId, PaneId(31))
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(31))

        var willSwapCount = 0
        var didSwapCount = 0
        controller.displayWillSwap = { _, _, _ in willSwapCount += 1 }
        controller.displayDidSwap = { _ in didSwapCount += 1 }
        fed.clear()
        sent.clear()

        controller.refreshActiveWindowOnForeground()
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        // Match the device log: metadata is temporarily unavailable after
        // foregrounding. The existing terminal identity and scrollback must
        // remain live while the controller retries.
        controller.ingest(errorFrame(1, body: ["recovering"], time: 1))
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(31))

        // Foreground metadata/capture can take seconds while the SSH channel
        // catches up. Same-pane output must be retained without presenting
        // each queued redraw as a separate visible scroll step.
        fed.clear()
        controller.ingest(Array("%output %31 live-while-refreshing\r\n".utf8))
        XCTAssertEqual(fed.bytes, [])

        try await Task.sleep(nanoseconds: 100_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        let metadata = renderedPaneMetadataLine(
            paneId: 31,
            cursorX: 5,
            cursorY: 6,
            historySize: 1_000
        )
        controller.ingest(responseFrame(2, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.ingest(responseFrame(3, body: ["visible viewport"], time: 1))

        XCTAssertEqual(
            fed.bytes,
            Array("live-while-refreshing".utf8)
                + expectedRepaintBytes(captureLines: ["visible viewport"], cursorX: 5, cursorY: 6)
        )
        XCTAssertEqual(fed.chunks.count, 2)
        XCTAssertEqual(fed.chunks.first, Array("live-while-refreshing".utf8))
        XCTAssertEqual(sent.bytes, [], "foreground repair must not request a deep capture")
        XCTAssertEqual(willSwapCount, 0, "in-place repair must preserve local scrollback")
        XCTAssertEqual(didSwapCount, 0)
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(31))
    }

    func test_appInactivityCoalescesOutputBeforeForegroundRefreshAndPreservesScrollbackBytes() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %31 queued-one\r\n".utf8))
        controller.ingest(Array("%output %31 -queued-two\r\n".utf8))
        XCTAssertEqual(fed.bytes, [], "inactive output must not present intermediate redraws")

        controller.refreshActiveWindowOnForeground()
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 31, cursorX: 3, cursorY: 4, historySize: 1_000)
        ], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.ingest(Array("%output %31 -queued-three\r\n".utf8))
        XCTAssertEqual(fed.bytes, [])
        controller.ingest(responseFrame(2, body: ["current viewport"], time: 1))

        let retained = Array("queued-one-queued-two-queued-three".utf8)
        XCTAssertEqual(fed.chunks.count, 2, "retained output and repaint should be atomic feed calls")
        XCTAssertEqual(fed.chunks[0], retained)
        XCTAssertEqual(
            fed.chunks[1],
            expectedRepaintBytes(captureLines: ["current viewport"], cursorX: 3, cursorY: 4)
        )

        fed.clear()
        controller.ingest(Array("%output %31 live-after-refresh\r\n".utf8))
        XCTAssertEqual(fed.bytes, Array("live-after-refresh".utf8))
    }

    func test_foregroundRefreshKeepsRetryingAndRetainingAfterOrdinaryAttemptLimit() async throws {
        let (controller, fed, sent) = makeController()
        controller.maxRenderRefreshAttempts = 2
        controller.renderRefreshRetryDelay = 0.01
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %31 retained-during-failure\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        sent.clear()
        controller.ingest(errorFrame(1, body: ["unavailable"], time: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        controller.ingest(errorFrame(2, body: ["still unavailable"], time: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        controller.ingest(errorFrame(3, body: ["exhausted"], time: 1))

        controller.ingest(Array("%output %31 live-after-failure\r\n".utf8))
        XCTAssertEqual(fed.bytes, [], "foreground recovery must remain gated past the ordinary retry limit")
        try await Task.sleep(nanoseconds: 150_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        controller.ingest(responseFrame(4, body: [
            renderedPaneMetadataLine(paneId: 31, historySize: 1_000)
        ], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()
        controller.ingest(responseFrame(5, body: ["recovered viewport"], time: 1))

        XCTAssertEqual(
            fed.chunks.first,
            Array("retained-during-failurelive-after-failure".utf8)
        )
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("recovered viewport"))
    }

    func test_foregroundRenderWaitsForOlderBackgroundQueryAndRejectsNewObservers() async throws {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        var olderResult: Result<[String], TmuxController.CommandError>?
        controller.sendBackgroundControlQuery(
            "display-message -p -t %31 '#{cursor_y}'"
        ) { olderResult = $0 }
        expectSent(sent, "display-message -p -t %31 '#{cursor_y}'\n")
        sent.clear()

        controller.prepareForAppInactivity()
        controller.refreshActiveWindowOnForeground()
        XCTAssertEqual(sent.bytes, [], "render metadata must wait until older observer replies drain")

        var rejectedResult: Result<[String], TmuxController.CommandError>?
        controller.sendBackgroundControlQuery(
            "display-message -p -t %31 '#{pane_current_command}'"
        ) { rejectedResult = $0 }
        guard case .failure(.cancelled)? = rejectedResult else {
            return XCTFail("new background observers must fail fast while authoritative rendering owns the queue")
        }
        XCTAssertEqual(sent.bytes, [])

        controller.ingest(responseFrame(1, body: ["51"], time: 1))
        guard case .success(let lines)? = olderResult else {
            return XCTFail("the older query should receive its own response")
        }
        XCTAssertEqual(lines, ["51"])

        try await Task.sleep(nanoseconds: 100_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 1))
    }

    func test_pauseDuringForegroundBarrierWaitsForViewportThenContinuesPane() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %31 retained-before-pause\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        controller.ingest(Array("%pause %31\r\n".utf8))
        XCTAssertEqual(sent.bytes, [], "pause must not supersede foreground recovery with a deep replay")
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 31, cursorX: 1, cursorY: 2, historySize: 1_000)
        ], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()
        controller.ingest(responseFrame(2, body: ["authoritative viewport"], time: 1))

        XCTAssertEqual(fed.chunks.first, Array("retained-before-pause".utf8))
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("authoritative viewport"))
        expectSent(sent, "refresh-client -A '%31:continue'\n")
        XCTAssertFalse(String(decoding: sent.bytes, as: UTF8.self).contains("-S -2000"))
    }

    func test_captureCompletingAfterInactiveEdgeCannotFeedUntilNewForegroundCapture() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.refreshActiveWindowOnForeground()
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 31, historySize: 1_000)
        ], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %31 arrived-while-inactive\r\n".utf8))
        controller.ingest(responseFrame(2, body: ["stale in-flight capture"], time: 1))
        XCTAssertEqual(fed.bytes, [], "an old capture completion must not paint while inactive")

        controller.refreshActiveWindowOnForeground()
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        controller.ingest(responseFrame(3, body: [
            renderedPaneMetadataLine(paneId: 31, historySize: 1_000)
        ], time: 1))
        sent.clear()
        controller.ingest(responseFrame(4, body: ["fresh foreground capture"], time: 1))

        XCTAssertEqual(fed.chunks.first, Array("arrived-while-inactive".utf8))
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("fresh foreground capture"))
        XCTAssertFalse(String(decoding: fed.bytes, as: UTF8.self).contains("stale in-flight capture"))
    }

    func test_metadataCompletingAfterInactiveEdgeDoesNotStartCapture() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.refreshActiveWindowOnForeground()
        sent.clear()
        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %31 retained-before-metadata\r\n".utf8))
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 31, historySize: 1_000)
        ], time: 1))
        XCTAssertEqual(sent.bytes, [], "inactive metadata completion must not start capture-pane")
        XCTAssertEqual(fed.bytes, [])

        controller.refreshActiveWindowOnForeground()
        sent.clear()
        controller.ingest(responseFrame(2, body: [
            renderedPaneMetadataLine(paneId: 31, historySize: 1_000)
        ], time: 1))
        sent.clear()
        controller.ingest(responseFrame(3, body: ["fresh capture after metadata deferral"], time: 1))

        XCTAssertEqual(fed.chunks.first, Array("retained-before-metadata".utf8))
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("fresh capture after metadata deferral"))
    }

    func test_foregroundBufferOverflowDropsWholeEscapeStreamBeforeViewportRepaint() {
        let (controller, fed, sent) = makeController()
        controller.maxForegroundOutputBytes = 8
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.prepareForAppInactivity()
        let oversizedEscapeStream = "\u{1B}[2J0123456789"
        controller.ingest(Array("%output %31 \(oversizedEscapeStream)\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 31, cursorX: 2, cursorY: 3)
        ], time: 1))
        sent.clear()
        controller.ingest(responseFrame(2, body: ["overflow-safe viewport"], time: 1))

        XCTAssertEqual(fed.chunks.count, 1, "overflow must never feed a truncated retained stream")
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("overflow-safe viewport"))
        XCTAssertFalse(String(decoding: fed.bytes, as: UTF8.self).contains("0123456789"))

        fed.clear()
        controller.ingest(Array("%output %31 live-after-overflow\r\n".utf8))
        XCTAssertEqual(fed.bytes, Array("live-after-overflow".utf8))
    }

    func test_enteringTmuxWhileInactiveKeepsFirstOutputBehindForegroundCapture() {
        let (controller, fed, sent) = makeController()
        controller.prepareForAppInactivity()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        XCTAssertEqual(fed.bytes, [], "attach output must stay gated while the app remains inactive")
        sent.clear()

        controller.refreshActiveWindowOnForeground()
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 31, cursorX: 1, cursorY: 1)
        ], time: 1))
        sent.clear()
        controller.ingest(responseFrame(2, body: ["foreground attach viewport"], time: 1))

        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("foreground attach viewport"))
        XCTAssertFalse(String(decoding: fed.bytes, as: UTF8.self).contains("boot"))
    }

    func test_establishedWindowSwapMetadataFailuresNeverPaintIncrementalSliver() async throws {
        let (controller, fed, sent) = makeController()
        controller.maxRenderRefreshAttempts = 2
        controller.renderRefreshRetryDelay = 0.01
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%window-add @2\r\n".utf8))
        // Drain the name lookup generated by %window-add before switching.
        sent.clear()
        controller.ingest(responseFrame(50, body: ["two"], time: 1))
        sent.clear()
        controller.ingest(Array("%window-pane-changed @2 %2\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        controller.ingest(errorFrame(1, body: ["metadata unavailable"], time: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()
        controller.ingest(errorFrame(2, body: ["metadata unavailable again"], time: 1))

        // Retry 2 also fails, exhausting the ordinary established-swap limit.
        try await Task.sleep(nanoseconds: 150_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()
        controller.ingest(errorFrame(3, body: ["metadata permanently unavailable"], time: 1))

        // This is the user-visible corruption from the device log: once the
        // retry limit was exhausted, a tiny TUI update from the new pane used
        // to paint over the otherwise stale previous screen.
        controller.ingest(Array("%output %2 NEW-WINDOW-SLIVER\r\n".utf8))
        XCTAssertEqual(fed.bytes, [])
        XCTAssertNil(controller.renderedWindowId)
        XCTAssertNil(controller.renderedPaneId)

        // Established swaps also keep retrying past the ordinary cap rather
        // than leaving the selected tab stale forever.
        try await Task.sleep(nanoseconds: 200_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()
        controller.ingest(responseFrame(4, body: [
            renderedPaneMetadataLine(paneId: 2, paneTitle: "two", windowName: "two")
        ], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @2\n")
        sent.clear()
        controller.ingest(responseFrame(5, body: ["authoritative window two"], time: 1))

        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("authoritative window two"))
        XCTAssertFalse(String(decoding: fed.bytes, as: UTF8.self).contains("NEW-WINDOW-SLIVER"))
        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
    }

    func test_establishedSharedRecoveryRetiresWhenTargetBecomesGrid() {
        let (controller, _, sent) = makeController()
        controller.renderRefreshRetryDelay = 10
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        sent.clear()

        controller.ingest(Array("%window-add @2\r\n".utf8))
        sent.clear()
        controller.ingest(responseFrame(50, body: ["two"], time: 1))
        sent.clear()
        controller.ingest(Array("%window-pane-changed @2 %2\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        sent.clear()
        controller.ingest(errorFrame(1, body: ["metadata unavailable"], time: 1))

        XCTAssertTrue(controller.isAuthoritativeRenderRefreshPending)

        controller.ingest(Array(
            "%layout-change @2 8205,80x24,0,0{40x24,0,0,2,39x24,41,0,3} 8205,80x24,0,0{40x24,0,0,2,39x24,41,0,3} *\r\n".utf8
        ))

        XCTAssertFalse(
            controller.isAuthoritativeRenderRefreshPending,
            "a grid has no shared terminal for the established retry to own"
        )
        sent.clear()
        var observerResult: Result<[String], TmuxController.CommandError>?
        controller.sendBackgroundControlQuery(
            "display-message -p -t %2 '#{cursor_y}'"
        ) { observerResult = $0 }
        XCTAssertNil(observerResult)
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("#{cursor_y}"))
    }

    func test_establishedSharedRecoveryRetiresWhenLastWindowCloses() {
        let (controller, _, sent) = makeController()
        controller.renderRefreshRetryDelay = 10
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        sent.clear()

        controller.ingest(Array("%window-add @2\r\n".utf8))
        sent.clear()
        controller.ingest(responseFrame(50, body: ["two"], time: 1))
        sent.clear()
        controller.ingest(Array("%window-pane-changed @2 %2\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        sent.clear()
        controller.ingest(errorFrame(1, body: ["metadata unavailable"], time: 1))
        XCTAssertTrue(controller.isAuthoritativeRenderRefreshPending)

        controller.ingest(Array("%window-close @2\r\n".utf8))
        controller.ingest(Array("%window-close @1\r\n".utf8))

        XCTAssertNil(controller.activeWindowId)
        XCTAssertFalse(
            controller.isAuthoritativeRenderRefreshPending,
            "closing the final window must retire its ownerless shared retry"
        )
    }

    func test_foregroundSharedCaptureTransfersToGridBeforeSinksMount() async throws {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %31 retained-shared-output\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        sent.clear()

        controller.ingest(Array(
            "%layout-change @1 8205,80x24,0,0{40x24,0,0,31,39x24,41,0,32} 8205,80x24,0,0{40x24,0,0,31,39x24,41,0,32} *\r\n".utf8
        ))
        controller.ingest(Array("%output %31 grid-output-before-mount\r\n".utf8))
        XCTAssertEqual(fed.bytes, [])

        let paneFeed = Accumulator<UInt8>()
        controller.setPaneSink(PaneId(31)) { paneFeed.append(contentsOf: $0) }
        controller.refreshPane(paneId: PaneId(31), deep: false)

        // The obsolete shared metadata response is stale and must not start a
        // hidden shared-terminal capture after the grid handoff. Once it drains,
        // the mounted grid pane inherits recovery ownership and repaints.
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 31)
        ], time: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        expectSent(sent, "display-message -p -t %31 '\(TmuxController.renderedPaneMetadataFormat)'\n")
        sent.clear()
        controller.ingest(responseFrame(2, body: [
            renderedPaneMetadataLine(paneId: 31)
        ], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t %31\n")
        sent.clear()
        controller.ingest(responseFrame(3, body: ["authoritative grid viewport"], time: 1))

        XCTAssertEqual(
            paneFeed.chunks.first,
            Array("retained-shared-outputgrid-output-before-mount".utf8)
        )
        XCTAssertTrue(String(decoding: paneFeed.bytes, as: UTF8.self).contains("authoritative grid viewport"))
        controller.ingest(Array("%output %31 grid-live-after-handoff\r\n".utf8))
        XCTAssertTrue(String(decoding: paneFeed.bytes, as: UTF8.self).contains("grid-live-after-handoff"))
    }

    func test_inactiveSharedToGridKeepsOutputBarrierBeforeSinkRegistration() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array(
            ("%layout-change @1 8205,80x24,0,0{40x24,0,0,31,39x24,41,0,32} "
             + "8205,80x24,0,0{40x24,0,0,31,39x24,41,0,32} *\r\n"
             + "%output %31 must-remain-buffered-before-grid-mount\r\n").utf8
        ))

        XCTAssertEqual(fed.bytes, [])
        XCTAssertTrue(controller.isAuthoritativeRenderRefreshPending)

        // Foreground activation can beat SwiftUI's grid mount. With no sinks
        // yet, the barrier must stay armed rather than replaying into the old
        // shared terminal during that gap.
        controller.refreshActiveWindowOnForeground()
        controller.ingest(Array("%output %31 still-buffered-after-activation\r\n".utf8))
        XCTAssertEqual(fed.bytes, [])
        XCTAssertTrue(controller.isAuthoritativeRenderRefreshPending)

        let paneFeed = Accumulator<UInt8>()
        controller.setPaneSink(PaneId(31)) { paneFeed.append(contentsOf: $0) }
        controller.refreshPane(paneId: PaneId(31), deep: false)
        expectSent(sent, "display-message -p -t %31 '\(TmuxController.renderedPaneMetadataFormat)'\n")
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 31)
        ], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t %31\n")
        controller.ingest(responseFrame(2, body: ["authoritative grid viewport"], time: 1))

        XCTAssertEqual(
            paneFeed.chunks.first,
            Array(
                "must-remain-buffered-before-grid-mountstill-buffered-after-activation".utf8
            )
        )
        XCTAssertTrue(String(decoding: paneFeed.bytes, as: UTF8.self).contains("authoritative grid viewport"))
        XCTAssertFalse(controller.isAuthoritativeRenderRefreshPending)
    }

    func test_foregroundBarrierReleasesWhenLastActiveWindowCloses() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        fed.clear()
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %31 retained-before-close\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        controller.ingest(Array("%window-close @1\r\n".utf8))

        controller.ingest(Array("%window-add @2\r\n".utf8))
        sent.clear()
        controller.ingest(responseFrame(50, body: ["two"], time: 1))
        controller.ingest(Array("%output %2 live-new-window\r\n".utf8))

        XCTAssertEqual(fed.bytes, Array("live-new-window".utf8))
    }

    func test_foregroundRefreshRepaintsAlternateBufferWithoutSwitchingBuffers() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        controller.terminalIsInAltScreen = { true }

        var willSwapCount = 0
        var didSwapCount = 0
        var didRefreshCount = 0
        controller.displayWillSwap = { _, _, _ in willSwapCount += 1 }
        controller.displayDidSwap = { _ in didSwapCount += 1 }
        controller.displayDidRefresh = { _ in didRefreshCount += 1 }
        fed.clear()
        sent.clear()

        controller.refreshActiveWindowOnForeground()
        sent.clear()
        let metadata = renderedPaneMetadataLine(
            paneId: 31,
            cursorX: 2,
            cursorY: 3,
            alternateOn: true,
            historySize: 1_000,
            altSavedX: 7,
            altSavedY: 8
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.ingest(responseFrame(2, body: ["alternate viewport"], time: 1))

        let repaint = String(decoding: fed.bytes, as: UTF8.self)
        XCTAssertTrue(repaint.contains("alternate viewport"))
        XCTAssertFalse(repaint.contains("\u{1B}[?1049l"), "in-place alt repair must preserve the saved primary buffer")
        XCTAssertFalse(repaint.contains("\u{1B}[?1049h"), "in-place alt repair must stay in the current alternate buffer")
        XCTAssertEqual(sent.bytes, [], "in-place alt repair must not request primary/history captures")
        XCTAssertEqual(willSwapCount, 0)
        XCTAssertEqual(didSwapCount, 0)
        XCTAssertEqual(didRefreshCount, 1)
    }

    func test_foregroundRefreshFallsBackToDeepRebuildWhenPaneIdentityChanged() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        sent.clear()

        controller.refreshActiveWindowOnForeground()
        sent.clear()

        let metadata = renderedPaneMetadataLine(paneId: 32, historySize: 1_000)
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.ingest(responseFrame(2, body: ["new pane viewport"], time: 1))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
    }

    func test_foregroundRefreshPromotesPaneMismatchBeforeCaptureFailure() {
        let (controller, _, sent) = makeController()
        controller.renderRefreshRetryDelay = 10
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 31)
        sent.clear()

        controller.refreshActiveWindowOnForeground()
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 32, historySize: 1_000)
        ], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.ingest(errorFrame(2, body: ["capture unavailable"], time: 1))

        XCTAssertNil(controller.renderedWindowId, "a confirmed pane change must use real-swap failure semantics")
        XCTAssertNil(controller.renderedPaneId)
    }

    func test_repaintBytes_nonAltDeepStage_matchesSpec() {
        let (controller, fed, sent) = makeController()
        controller.deepRepaintHistoryDepth = 42
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        sent.clear()
        let metadata = renderedPaneMetadataLine(
            paneId: 32,
            cursorX: 6,
            cursorY: 4,
            paneTitle: "deep pane",
            windowName: "editor"
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.ingest(responseFrame(2, body: ["viewport"], time: 1))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        fed.clear()

        controller.ingest(responseFrame(3, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -42 -t @1\n")
        sent.clear()

        let deepLines = ["history line", "visible line"]
        controller.ingest(responseFrame(4, body: deepLines, time: 1))

        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(captureLines: deepLines, cursorX: 6, cursorY: 4)
        )
        XCTAssertEqual(sent.bytes, [])
    }

    /// Regression: capture-pane -e emits SGR cumulatively, so a suffix slice
    /// of the deep capture strands bg openers above the slice boundary — the
    /// old slice-based scrub repainted a colored panel's visible rows in
    /// default black (full-width black band). The scrub must instead paint
    /// from a fresh viewport capture chained after the deep one, where tmux
    /// re-serializes all open SGR state at row 0.
    func test_deepScrubPaintsFromFreshViewportCapture_notDeepSuffixSlice() {
        let (controller, fed, sent) = makeController()
        controller.deepRepaintHistoryDepth = 42
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        controller.updateClientSize(cols: 80, rows: 2)
        controller.ingest(responseFrame(60)) // drain refresh-client -C
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        sent.clear()
        let metadata = renderedPaneMetadataLine(
            paneId: 32,
            cursorX: 6,
            cursorY: 1,
            paneTitle: "deep pane",
            windowName: "editor"
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.ingest(responseFrame(2, body: ["viewport"], time: 1))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        fed.clear()

        controller.ingest(responseFrame(3, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -42 -t @1\n")
        sent.clear()

        // The grey panel's bg opener appears exactly once, in the history
        // prefix; the visible suffix rows carry NO bg SGR of their own
        // (cumulative emission) — the shape that broke the slice-based scrub.
        let greyOpener = "\u{1B}[48;2;30;30;30m"
        let deepLines = [
            greyOpener + "panel top (history)",
            "panel body (history)",
            "plain paragraph one",
            "plain paragraph two",
        ]
        controller.ingest(responseFrame(4, body: deepLines, time: 1))

        // History scrolled (4 captured rows > 2 visible) → the controller
        // must chain a fresh viewport capture instead of slicing, and the
        // deep repaint must wait for it.
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()
        XCTAssertEqual(fed.bytes, [], "deep repaint must land together with its scrub")

        // tmux re-serializes the open bg state at row 0 of a viewport capture.
        let scrubLines = [greyOpener + "plain paragraph one", "plain paragraph two"]
        controller.ingest(responseFrame(5, body: scrubLines, time: 1))

        // Assemble the golden through RepaintAssembly itself (its seam
        // neutralization re-opens the tracked pen per row — byte details are
        // pinned by RepaintAssemblyTests); THIS test pins which lines the
        // controller feeds: the deep capture, then the fresh viewport lines.
        let state = TmuxController.parseRenderedPaneState(metadata)!
        let expectedDeep = RepaintAssembly.assemble(
            state: state,
            captureLines: deepLines,
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: 2
        )
        let expectedScrub = RepaintAssembly.assemble(
            state: state,
            captureLines: scrubLines,
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: 2
        )
        XCTAssertEqual(fed.bytes, expectedDeep + expectedScrub)

        let scrubSegment = String(decoding: fed.bytes.dropFirst(expectedDeep.count), as: UTF8.self)
        XCTAssertTrue(
            scrubSegment.contains(greyOpener + "plain paragraph one"),
            "scrub must carry the panel's bg opener ahead of the SGR-free paragraph rows"
        )
        XCTAssertEqual(sent.bytes, [])
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(32))
    }

    func test_deepStageWithoutScrolledHistory_skipsScrubCapture() {
        let (controller, fed, sent) = makeController()
        controller.deepRepaintHistoryDepth = 42
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        controller.updateClientSize(cols: 80, rows: 30)
        controller.ingest(responseFrame(60)) // drain refresh-client -C
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        sent.clear()
        let metadata = renderedPaneMetadataLine(
            paneId: 32,
            cursorX: 6,
            cursorY: 4,
            paneTitle: "deep pane",
            windowName: "editor"
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        sent.clear()
        controller.ingest(responseFrame(2, body: ["viewport"], time: 1))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        fed.clear()

        controller.ingest(responseFrame(3, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -42 -t @1\n")
        sent.clear()

        // 2 captured rows fit inside the 30 visible rows: nothing scrolled,
        // so no scrub — and therefore no chained viewport capture.
        let deepLines = ["history line", "visible line"]
        controller.ingest(responseFrame(4, body: deepLines, time: 1))

        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(captureLines: deepLines, cursorX: 6, cursorY: 4)
        )
        XCTAssertEqual(sent.bytes, [], "no scrub capture when history did not scroll")
    }

    func test_deepScrubCaptureFailureKeepsRenderedIdsAndRetriesDeepStage() async throws {
        let (controller, fed, sent) = makeController()
        controller.renderRefreshRetryDelay = 0.05
        controller.deepRepaintHistoryDepth = 42
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        controller.updateClientSize(cols: 80, rows: 2)
        controller.ingest(responseFrame(60)) // drain refresh-client -C
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        sent.clear()
        let metadata = renderedPaneMetadataLine(
            paneId: 2,
            paneTitle: "two",
            windowName: "two"
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        sent.clear()
        controller.ingest(responseFrame(2, body: ["viewport two"], time: 1))
        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        controller.ingest(responseFrame(3, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -42 -t @2\n")
        sent.clear()
        fed.clear()

        // Deep capture succeeds with scrolled history → scrub capture chains.
        controller.ingest(responseFrame(4, body: ["h1", "h2", "v1", "v2"], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @2\n")
        sent.clear()

        // The chained scrub capture fails → same semantics as any deep-chain
        // capture failure: nothing feeds, rendered ids survive, and one retry
        // re-runs the deep stage from the metadata query.
        controller.ingest(errorFrame(5, body: ["scrub failed"], time: 1))

        XCTAssertEqual(fed.bytes, [], "no partial repaint may land when the scrub capture fails")
        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
        XCTAssertEqual(sent.bytes, [])

        try await Task.sleep(nanoseconds: 300_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
    }

    func test_repaintBytes_altDeepWithHistory_chainsHistoryPrimaryAltAndMatchesSpec() {
        let (controller, fed, sent) = makeController()
        controller.deepRepaintHistoryDepth = 17

        enterTmuxModeAndStartAttachInit(controller)
        sent.clear()
        controller.ingest(responseFrame(2))
        controller.ingest(responseFrame(3))
        controller.ingest(responseFrame(4))
        controller.ingest(responseFrame(5, body: ["@4 editor"]))
        controller.ingest(responseFrame(6, body: ["@4\t%44\t1\t\tpane title\thost"]))
        controller.ingest(responseFrame(7, body: ["@4"]))
        expectSent(sent, renderedMetadataCommand(windowId: 4))
        sent.clear()

        controller.ingest(responseFrame(8))
        let metadata = renderedPaneMetadataLine(
            paneId: 44,
            cursorX: 6,
            cursorY: 7,
            paneTitle: "pane title",
            windowName: "editor",
            alternateOn: true,
            historySize: 9,
            cursorVisible: true,
            altSavedX: 2,
            altSavedY: 3
        )
        controller.ingest(responseFrame(9, body: [metadata]))
        expectSent(sent, "capture-pane -p -e -N -S -17 -E -1 -t @4\n")
        sent.clear()

        let historyLines = ["hist one", "hist two"]
        controller.ingest(responseFrame(10, body: historyLines))
        expectSent(sent, "capture-pane -p -e -N -a -q -t @4\n")
        sent.clear()

        let savedPrimaryLines = ["primary one", "primary two"]
        controller.ingest(responseFrame(11, body: savedPrimaryLines))
        expectSent(sent, "capture-pane -p -e -N -t @4\n")
        sent.clear()

        let altLines = ["alt one", "alt two"]
        controller.ingest(responseFrame(12, body: altLines))

        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(
                captureLines: altLines,
                paneInAltScreen: true,
                historyLines: historyLines,
                savedPrimaryLines: savedPrimaryLines,
                altScreenLines: altLines,
                cursorX: 6,
                cursorY: 7,
                cursorVisible: true,
                altSavedX: 2,
                altSavedY: 3
            )
        )
    }

    func test_repaintBytes_altDeepWithZeroHistory_skipsHistoryCapture() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        sent.clear()
        let viewportMetadata = renderedPaneMetadataLine(
            paneId: 52,
            paneTitle: "alt pane",
            windowName: "alt"
        )
        controller.ingest(responseFrame(1, body: [viewportMetadata], time: 1))
        sent.clear()
        controller.ingest(responseFrame(2, body: ["viewport"], time: 1))
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()
        fed.clear()

        let altMetadata = renderedPaneMetadataLine(
            paneId: 52,
            cursorX: 3,
            cursorY: 4,
            paneTitle: "alt pane",
            windowName: "alt",
            alternateOn: true,
            historySize: 0,
            altSavedX: 1,
            altSavedY: 2
        )
        controller.ingest(responseFrame(3, body: [altMetadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -a -q -t @2\n")
        sent.clear()

        let savedPrimaryLines = ["primary"]
        controller.ingest(responseFrame(4, body: savedPrimaryLines, time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @2\n")
        sent.clear()

        let altLines = ["alt viewport"]
        controller.ingest(responseFrame(5, body: altLines, time: 1))
        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(
                captureLines: altLines,
                paneInAltScreen: true,
                historyLines: [],
                savedPrimaryLines: savedPrimaryLines,
                altScreenLines: altLines,
                cursorX: 3,
                cursorY: 4,
                altSavedX: 1,
                altSavedY: 2
            )
        )
    }

    func test_repaintPrologue_gatesTerminalAltScreenExit() {
        func repaintText(terminalWasInAltScreen: Bool) -> String {
            let (controller, fed, sent) = makeController()
            controller.terminalIsInAltScreen = { terminalWasInAltScreen }
            enterTmuxModeAndDrainAttachInit(controller)
            seedInlineRenderedWindow(controller)
            fed.clear()
            sent.clear()

            controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
            sent.clear()
            controller.ingest(responseFrame(1, body: [
                renderedPaneMetadataLine(paneId: 61, cursorX: 1, cursorY: 1)
            ], time: 1))
            sent.clear()
            controller.ingest(responseFrame(2, body: ["body"], time: 1))
            return String(decoding: fed.bytes, as: UTF8.self)
        }

        XCTAssertTrue(repaintText(terminalWasInAltScreen: true).contains("\u{1B}[?1049l"))
        XCTAssertFalse(repaintText(terminalWasInAltScreen: false).contains("\u{1B}[?1049l"))
    }

    func test_repaintEpilogue_ordersModeRestoresAndOriginAfterCup() {
        let (htopController, htopFed, htopSent) = makeController()
        enterTmuxModeAndDrainAttachInit(htopController)
        seedInlineRenderedWindow(htopController)
        htopFed.clear()
        htopSent.clear()

        htopController.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        htopSent.clear()
        htopController.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(
                paneId: 71,
                cursorX: 9,
                cursorY: 10,
                paneTitle: "htop",
                windowName: "ops",
                alternateOn: true,
                historySize: 0,
                cursorVisible: true,
                mouseAll: true,
                mouseSgr: true,
                originMode: true,
                altSavedX: 0,
                altSavedY: 0
            )
        ], time: 1))
        htopSent.clear()
        htopController.ingest(responseFrame(2, body: ["alt body"], time: 1))
        let htopText = String(decoding: htopFed.bytes, as: UTF8.self)

        assertMarker("\u{1B}[?1006l", precedes: "\u{1B}[?1003h", in: htopText)
        assertMarker("\u{1B}[?1006l", precedes: "\u{1B}[?1006h", in: htopText)
        assertMarker("\u{1B}[11;10H", precedes: "\u{1B}[?6h", in: htopText)
        if let altSet = htopText.range(of: "\u{1B}[?1049h"),
           let finalCursor = htopText.range(of: "\u{1B}[?25h", options: .backwards) {
            XCTAssertLessThan(
                htopText.distance(from: htopText.startIndex, to: altSet.lowerBound),
                htopText.distance(from: htopText.startIndex, to: finalCursor.lowerBound)
            )
        } else {
            XCTFail("missing alt-screen set or final cursor restore")
        }

        let (vimController, vimFed, vimSent) = makeController()
        enterTmuxModeAndDrainAttachInit(vimController)
        seedInlineRenderedWindow(vimController)
        vimFed.clear()
        vimSent.clear()

        vimController.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        vimSent.clear()
        vimController.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(
                paneId: 72,
                cursorX: 2,
                cursorY: 3,
                paneTitle: "vim",
                windowName: "code",
                scrollRegionUpper: 5,
                scrollRegionLower: 20,
                cursorVisible: false,
                wrapMode: false
            )
        ], time: 1))
        vimSent.clear()
        vimController.ingest(responseFrame(2, body: ["vim body"], time: 1))
        let vimText = String(decoding: vimFed.bytes, as: UTF8.self)

        assertMarker("vim body", precedes: "\u{1B}[6;21r", in: vimText)
        assertMarker("\u{1B}[6;21r", precedes: "\u{1B}[?7l", in: vimText)
        assertMarker("\u{1B}[?7l", precedes: "\u{1B}[?25l", in: vimText)
        assertMarker("\u{1B}[?25l", precedes: "\u{1B}[4;3H", in: vimText)
    }

    func test_windowSwitchDeepStageAbortsWhenGenerationChanges() async throws {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        sent.clear()
        let metadata = renderedPaneMetadataLine(paneId: 81, paneTitle: "one", windowName: "one")
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        sent.clear()
        controller.ingest(responseFrame(2, body: ["viewport one"], time: 1))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()
        fed.clear()

        controller.ingest(responseFrame(3, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -2000 -t @1\n")
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        XCTAssertEqual(sent.bytes, [], "replacement metadata waits for the stale deep command to drain")
        controller.ingest(responseFrame(4, body: ["stale deep"], time: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))

        XCTAssertEqual(fed.bytes, [], "stale deep capture must not feed after a newer window switch")
        XCTAssertEqual(controller.activeWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
    }

    func test_attachInit_deepCaptureReadinessAndDisplayDidSwapAfterFeed() {
        let (controller, fed, sent) = makeController()
        var events: [String] = []
        controller.feedTerminal = { slice in
            events.append("feed")
            fed.append(contentsOf: slice)
        }
        controller.displayDidSwap = { windowId in
            events.append("did:\(windowId.description)")
        }

        enterTmuxModeAndStartAttachInit(controller)
        sent.clear()
        controller.ingest(responseFrame(2))
        controller.ingest(responseFrame(3))
        controller.ingest(responseFrame(4))
        controller.ingest(responseFrame(5, body: ["@1 editor"]))
        controller.ingest(responseFrame(6, body: ["@1\t%91\t1\t\tpane title\thost"]))
        controller.ingest(responseFrame(7, body: ["@1"]))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        controller.ingest(responseFrame(8))
        let metadata = renderedPaneMetadataLine(
            paneId: 91,
            cursorX: 5,
            cursorY: 6,
            paneTitle: "pane title",
            windowName: "editor"
        )
        controller.ingest(responseFrame(9, body: [metadata]))
        expectSent(sent, "capture-pane -p -e -N -S -2000 -t @1\n")
        XCTAssertFalse(controller.isInitialRenderReady)
        sent.clear()

        controller.ingest(responseFrame(10, body: ["attach body"]))

        XCTAssertEqual(events, ["feed", "did:@1"])
        XCTAssertTrue(controller.isInitialRenderReady)
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(91))
        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(captureLines: ["attach body"], cursorX: 5, cursorY: 6)
        )
    }

    func test_chattyAttachSuppressesOutputUntilHydratedDeepCapture() {
        let (controller, fed, sent) = makeController()

        enterTmuxModeAndStartAttachInit(controller)
        sent.clear()
        controller.ingest(Array("%output %9 chatty\r\n".utf8))

        XCTAssertEqual(fed.bytes, [])
        XCTAssertFalse(controller.isInitialRenderReady)
        XCTAssertNil(controller.activePaneId)

        controller.ingest(responseFrame(2))
        controller.ingest(responseFrame(3))
        controller.ingest(responseFrame(4))
        controller.ingest(responseFrame(5, body: ["@1 editor"]))
        controller.ingest(responseFrame(6, body: ["@1\t%1\t1\t\tpane title\thost"]))
        controller.ingest(responseFrame(7, body: ["@1"]))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        controller.ingest(responseFrame(8))
        let metadata = renderedPaneMetadataLine(
            paneId: 1,
            cursorX: 2,
            cursorY: 3,
            paneTitle: "pane title",
            windowName: "editor"
        )
        controller.ingest(responseFrame(9, body: [metadata]))
        expectSent(sent, "capture-pane -p -e -N -S -2000 -t @1\n")
        sent.clear()

        controller.ingest(responseFrame(10, body: ["hydrated truth"]))

        let text = String(decoding: fed.bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("hydrated truth"))
        XCTAssertFalse(text.contains("chatty"))
        XCTAssertEqual(controller.activeWindowId, WindowId(1))
        XCTAssertEqual(controller.activePaneId, PaneId(1))
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(1))
    }

    func test_hookFrameFlagsZeroDoesNotPopPendingCommandFIFO() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        let first = CompletionCapture<[String], TmuxController.CommandError>()
        let second = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("first-command") { first.store($0) }
        controller.sendControlCommand("second-command") { second.store($0) }
        expectSent(sent, "first-command\nsecond-command\n")

        controller.ingest(responseFrame(1, body: ["first body"], time: 10))
        XCTAssertEqual(first.result, .success(["first body"]))
        XCTAssertNil(second.result)

        controller.ingest(responseFrame(99, body: ["hook body"], flags: 0, time: 11))
        XCTAssertNil(second.result, "flags=0 hook frame must not consume the next command completion")

        controller.ingest(responseFrame(2, body: ["second body"], time: 12))
        XCTAssertEqual(second.result, .success(["second body"]))
    }

    func test_initialRenderWatchdogFailOpenAllowsOutputAfterTimeout() async throws {
        let (controller, fed, _) = makeController()
        controller.initialRenderWatchdogInterval = 0.05

        enterTmuxModeAndStartAttachInit(controller)
        controller.ingest(Array("%output %9 early\r\n".utf8))

        XCTAssertEqual(fed.bytes, [])
        XCTAssertFalse(controller.isInitialRenderReady)
        XCTAssertNil(controller.activePaneId)

        try await Task.sleep(nanoseconds: 250_000_000)
        controller.ingest(Array("%output %9 late\r\n".utf8))

        XCTAssertEqual(String(decoding: fed.bytes, as: UTF8.self), "late")
        XCTAssertEqual(controller.activePaneId, PaneId(9))
        XCTAssertEqual(controller.renderedPaneId, PaneId(9))
        XCTAssertTrue(controller.isInitialRenderReady)
    }

    func test_abortedSwapRetryReissuesMetadataAfterDelay() async throws {
        let (controller, _, sent) = makeController()
        controller.renderRefreshRetryDelay = 0.05
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        controller.ingest(errorFrame(1, body: ["can't find window"], time: 1))
        XCTAssertNil(controller.renderedWindowId)
        XCTAssertNil(controller.renderedPaneId)
        XCTAssertEqual(sent.bytes, [])

        try await Task.sleep(nanoseconds: 300_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
    }

    func test_pauseMidSwapDoesNotResumeOldPaneAndSwapStillCompletes() {
        let (controller, fed, sent) = makeController()
        var events: [String] = []
        controller.feedTerminal = { slice in
            events.append("feed:\(String(decoding: slice, as: UTF8.self))")
            fed.append(contentsOf: slice)
        }
        controller.sendBytes = { bytes in
            events.append("send:\(String(decoding: bytes, as: UTF8.self))")
            sent.append(contentsOf: bytes)
        }

        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        fed.clear()
        sent.clear()
        events.removeAll()

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        controller.ingest(Array("%pause %1\r\n".utf8))

        expectSent(sent, renderedMetadataCommand(windowId: 2))
        XCTAssertFalse(String(decoding: sent.bytes, as: UTF8.self).contains("continue"))
        sent.clear()

        let windowTwoMetadata = renderedPaneMetadataLine(
            paneId: 2,
            paneTitle: "two",
            windowName: "two"
        )
        controller.ingest(responseFrame(1, body: [windowTwoMetadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @2\n")
        sent.clear()

        controller.ingest(responseFrame(2, body: ["window two"], time: 1))

        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("window two"))
        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()
        fed.clear()

        controller.ingest(responseFrame(3, body: [windowTwoMetadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -2000 -t @2\n")
        sent.clear()
        controller.ingest(responseFrame(4, body: ["window two deep"], time: 1))
        XCTAssertEqual(sent.bytes, [])
        fed.clear()
        events.removeAll()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        let windowOneMetadata = renderedPaneMetadataLine(
            paneId: 1,
            paneTitle: "one",
            windowName: "one"
        )
        controller.ingest(responseFrame(5, body: [windowOneMetadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @1\n")
        sent.clear()

        controller.ingest(responseFrame(6, body: ["window one"], time: 1))

        let feedIndex = events.firstIndex { $0.hasPrefix("feed:") && $0.contains("window one") }
        let continueIndex = events.firstIndex { $0 == "send:refresh-client -A '%1:continue'\n" }
        XCTAssertNotNil(feedIndex)
        XCTAssertNotNil(continueIndex)
        if let feedIndex, let continueIndex {
            XCTAssertLessThan(feedIndex, continueIndex)
        }
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(1))
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).hasPrefix("refresh-client -A '%1:continue'\n"))
    }

    func test_displayWillSwapPreservesFromWindowAcrossAbortedRetry() async throws {
        let (controller, fed, sent) = makeController()
        controller.renderRefreshRetryDelay = 0.05
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        fed.clear()
        sent.clear()

        var hooks: [String] = []
        controller.displayWillSwap = { from, to, paneInAltScreen in
            hooks.append("\(from?.description ?? "nil")->\(to.description):\(paneInAltScreen)")
        }

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        controller.ingest(errorFrame(1, body: ["can't find pane"], time: 1))
        XCTAssertNil(controller.renderedWindowId)
        XCTAssertNil(controller.renderedPaneId)

        try await Task.sleep(nanoseconds: 300_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        let metadata = renderedPaneMetadataLine(
            paneId: 2,
            paneTitle: "two",
            windowName: "two"
        )
        controller.ingest(responseFrame(2, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @2\n")
        sent.clear()

        controller.ingest(responseFrame(3, body: ["retry two"], time: 1))

        XCTAssertEqual(hooks, ["@1->@2:false"])
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("retry two"))
        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
    }

    func test_initialRenderLatchStaysClosedDuringHydrateRetry() async throws {
        let (controller, fed, sent) = makeController()
        controller.renderRefreshRetryDelay = 0.05

        enterTmuxModeAndStartAttachInit(controller)
        sent.clear()

        controller.ingest(responseFrame(2))
        controller.ingest(responseFrame(3))
        controller.ingest(responseFrame(4))
        controller.ingest(responseFrame(5, body: ["@1 editor"]))
        controller.ingest(responseFrame(6, body: ["@1\t%9\t1\t\tpane title\thost"]))
        controller.ingest(responseFrame(7, body: ["@1"]))
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        controller.ingest(responseFrame(8))
        controller.ingest(errorFrame(9, body: ["metadata failed"], time: 1))
        XCTAssertFalse(controller.isInitialRenderReady)
        XCTAssertNil(controller.renderedPaneId)

        controller.ingest(Array("%output %9 chatty\r\n".utf8))

        XCTAssertEqual(fed.bytes, [])
        XCTAssertFalse(controller.isInitialRenderReady)

        try await Task.sleep(nanoseconds: 300_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 1))
        sent.clear()

        let metadata = renderedPaneMetadataLine(
            paneId: 9,
            cursorX: 1,
            cursorY: 2,
            paneTitle: "pane title",
            windowName: "editor"
        )
        controller.ingest(responseFrame(10, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -2000 -t @1\n")
        sent.clear()

        controller.ingest(responseFrame(11, body: ["hydrated retry truth"], time: 1))

        let text = String(decoding: fed.bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("hydrated retry truth"))
        XCTAssertFalse(text.contains("chatty"))
        XCTAssertTrue(controller.isInitialRenderReady)
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(9))
    }

    func test_pauseRenderedPaneContinuesAndRunsDeepRefresh() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        sent.clear()

        controller.ingest(Array("%pause %1\r\n".utf8))

        expectSent(
            sent,
            "refresh-client -A '%1:continue'\n" + renderedMetadataCommand(windowId: 1)
        )
        sent.clear()

        controller.ingest(responseFrame(1, time: 1))
        let metadata = renderedPaneMetadataLine(
            paneId: 1,
            paneTitle: "one",
            windowName: "one"
        )
        controller.ingest(responseFrame(2, body: [metadata], time: 1))

        expectSent(sent, "capture-pane -p -e -N -S -2000 -t @1\n")
    }

    func test_pauseBackgroundPaneDoesNotContinueOrRepaintUntilSwapIn() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        controller.ingest(Array("%window-pane-changed @3 %3\r\n".utf8))
        sent.clear()
        fed.clear()

        controller.ingest(Array("%pause %3\r\n".utf8))

        XCTAssertEqual(sent.bytes, [])
        XCTAssertEqual(fed.bytes, [])
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(1))

        controller.ingest(Array("%session-window-changed $0 @3\r\n".utf8))
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(paneId: 3, paneTitle: "three", windowName: "three")
        ], time: 1))
        sent.clear()
        controller.ingest(responseFrame(2, body: ["window three"], time: 1))

        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("refresh-client -A '%3:continue'\n"))
        XCTAssertEqual(controller.renderedWindowId, WindowId(3))
        XCTAssertEqual(controller.renderedPaneId, PaneId(3))
    }

    func test_swapInResumeSendsContinueAfterRepaintFeed() {
        let (controller, fed, sent) = makeController()
        var events: [String] = []
        controller.feedTerminal = { slice in
            events.append("feed:\(String(decoding: slice, as: UTF8.self))")
            fed.append(contentsOf: slice)
        }
        controller.sendBytes = { bytes in
            events.append("send:\(String(decoding: bytes, as: UTF8.self))")
            sent.append(contentsOf: bytes)
        }

        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        controller.ingest(Array("%window-pane-changed @3 %3\r\n".utf8))
        controller.ingest(Array("%pause %3\r\n".utf8))
        sent.clear()
        fed.clear()
        events.removeAll()

        controller.ingest(Array("%session-window-changed $0 @3\r\n".utf8))
        expectSent(sent, renderedMetadataCommand(windowId: 3))
        sent.clear()

        let metadata = renderedPaneMetadataLine(
            paneId: 3,
            paneTitle: "three",
            windowName: "three"
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @3\n")
        sent.clear()

        controller.ingest(responseFrame(2, body: ["window three"], time: 1))

        let feedIndex = events.firstIndex { $0.hasPrefix("feed:") && $0.contains("window three") }
        let continueIndex = events.firstIndex { $0 == "send:refresh-client -A '%3:continue'\n" }
        XCTAssertNotNil(feedIndex)
        XCTAssertNotNil(continueIndex)
        if let feedIndex, let continueIndex {
            XCTAssertLessThan(feedIndex, continueIndex)
        }
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).hasPrefix("refresh-client -A '%3:continue'\n"))
    }

    func test_extendedOutputRoutesLikeOutputAndScansTitles() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%extended-output %1 17 : rendered\r\n".utf8))
        XCTAssertEqual(String(decoding: fed.bytes, as: UTF8.self), "rendered")

        controller.ingest(Array("%extended-output %2 17 : hidden\r\n".utf8))
        XCTAssertEqual(String(decoding: fed.bytes, as: UTF8.self), "rendered")

        controller.ingest(Array("%extended-output %1 17 : \u{1B}]0;Extended Title\u{07}\r\n".utf8))

        XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(1) })?.activePaneTitle, "Extended Title")
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("\u{1B}]0;Extended Title\u{07}"))
        XCTAssertEqual(sent.bytes, [])
    }

    func test_hydrateCommandsIncludePauseAfterAndBellSubscriptionInOrder() {
        let (controller, _, sent) = makeController()
        controller.updateClientSize(cols: 100, rows: 30)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(responseFrame(1, flags: 0))

        let actual = String(decoding: sent.bytes, as: UTF8.self)
        let resize = "refresh-client -C 100,30\n"
        let pauseAfter = "refresh-client -f pause-after=5\n"
        let bell = "refresh-client -B 'tessera-bell:%*:#{window_bell_flag}'\n"
        let listWindows = "list-windows -F"

        XCTAssertTrue(actual.contains(pauseAfter))
        XCTAssertTrue(actual.contains(bell))
        assertMarker(resize, precedes: pauseAfter, in: actual)
        assertMarker(pauseAfter, precedes: bell, in: actual)
        assertMarker(bell, precedes: listWindows, in: actual)
    }

    func test_deepStageFailureKeepsRenderedIdsAndRetriesOnceThenGivesUp() async throws {
        let (controller, fed, sent) = makeController()
        controller.renderRefreshRetryDelay = 0.05
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        sent.clear()

        let metadata = renderedPaneMetadataLine(
            paneId: 2,
            paneTitle: "two",
            windowName: "two"
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))
        sent.clear()

        controller.ingest(responseFrame(2, body: ["viewport two"], time: 1))

        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        controller.ingest(responseFrame(3, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -2000 -t @2\n")
        sent.clear()

        controller.ingest(errorFrame(4, body: ["deep failed"], time: 1))

        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
        XCTAssertEqual(sent.bytes, [])

        try await Task.sleep(nanoseconds: 300_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        controller.ingest(responseFrame(5, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -S -2000 -t @2\n")
        sent.clear()

        controller.ingest(errorFrame(6, body: ["deep failed again"], time: 1))

        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sent.bytes, [])
    }

    /// Foreground-restore gray-bleed self-heal: tmux returns empty/aborting
    /// render metadata for several seconds after the app resumes, so the
    /// viewport repaint must keep retrying past the first attempt and land once
    /// the channel recovers — otherwise the active window never repaints and the
    /// pre-background screen (another window's content) bleeds through.
    func test_viewportMetadataRetriesPastFirstAttemptThenRecovers() async throws {
        let (controller, fed, sent) = makeController()
        controller.renderRefreshRetryDelay = 0.02
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller, windowId: 1, paneId: 1)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        // First attempt fails (empty/aborting metadata) → abort + schedule retry.
        controller.ingest(errorFrame(1, body: ["empty"], time: 1))
        XCTAssertNil(controller.renderedWindowId)

        // Retry 1 re-sends the metadata query — and also fails.
        try await Task.sleep(nanoseconds: 150_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()
        controller.ingest(errorFrame(2, body: ["empty again"], time: 1))
        XCTAssertNil(controller.renderedWindowId)

        // The old logic gave up here. The self-heal keeps trying: retry 2 fires.
        try await Task.sleep(nanoseconds: 150_000_000)
        expectSent(sent, renderedMetadataCommand(windowId: 2))
        sent.clear()

        // Channel recovers: valid metadata → capture → repaint lands.
        let metadata = renderedPaneMetadataLine(
            paneId: 2,
            paneTitle: "two",
            windowName: "two"
        )
        controller.ingest(responseFrame(3, body: [metadata], time: 1))
        expectSent(sent, "capture-pane -p -e -N -t @2\n")
        sent.clear()
        controller.ingest(responseFrame(4, body: ["viewport two"], time: 1))

        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(2))
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("viewport two"))
    }

    func test_reset_cancelsPendingCommands() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        let captureA = CompletionCapture<[String], TmuxController.CommandError>()
        let captureB = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("query-a") { captureA.store($0) }
        controller.sendControlCommand("query-b") { captureB.store($0) }

        controller.reset()

        XCTAssertFalse(controller.isInitialRenderReady)
        guard case .failure(.cancelled) = captureA.result else {
            return XCTFail("A should have been cancelled, got \(String(describing: captureA.result))")
        }
        guard case .failure(.cancelled) = captureB.result else {
            return XCTFail("B should have been cancelled, got \(String(describing: captureB.result))")
        }
    }

    func test_exitMessage_cancelsPendingCommands() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)

        let capture = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("query") { capture.store($0) }

        // %exit tears down tmux mode and should cancel pending commands.
        controller.ingest(Array("%exit\r\n".utf8))

        guard case .failure(.cancelled) = capture.result else {
            return XCTFail("expected .cancelled, got \(String(describing: capture.result))")
        }
        XCTAssertEqual(controller.mode, .passthrough)
    }

    // MARK: - Display swap on session-window-changed (§3.2 commit C)

    func test_displaySwap_onSessionWindowChanged_queriesAndRepaints() {
        // End-to-end viewport stage: session-window-changed queries
        // metadata, captures the viewport, paints the section C
        // reset/content/restore byte stream, then schedules deep repaint.
        let (controller, fed, sent) = makeController()

        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        XCTAssertEqual(controller.activePaneId, PaneId(0))
        fed.clear()
        sent.clear()

        // Simulate tmux auto-switching to a new window @1 (as it does
        // on `new-window`). We omit %window-add @1 here because its
        // C3 window-name query would interleave with the display-swap
        // FIFO and complicate this test. The C3 name-discovery flow
        // has its own dedicated tests.
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))

        // The controller should have emitted the combined display-message
        // query for @1 immediately on session-window-changed.
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            renderedMetadataCommand(windowId: 1),
            "display-message query should target the new window id with pane, cursor, and title metadata"
        )
        sent.clear()

        let metadata = renderedPaneMetadataLine(
            paneId: 3,
            cursorX: 12,
            cursorY: 5,
            paneTitle: "pane title",
            windowName: "editor"
        )
        controller.ingest(responseFrame(1, body: [metadata], time: 1))

        // That completion should have fired and enqueued the capture-pane query.
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -t @1\n",
            "capture-pane query should target the new window id after metadata resolves"
        )
        XCTAssertNil(fed.bytes.first,
                     "no terminal bytes should have been written yet — still waiting on capture")
        sent.clear()

        let captureLines = ["line one", "line two"]
        controller.ingest(responseFrame(2, body: captureLines, time: 1))

        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(captureLines: captureLines, cursorX: 12, cursorY: 5),
            "viewport repaint should follow the section C reset-prologue/content/restore-epilogue order"
        )
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            renderedMetadataCommand(windowId: 1),
            "successful viewport paint should immediately schedule the deep stage metadata query"
        )

        XCTAssertEqual(controller.activePaneId, PaneId(3),
                       "activePaneId should swap to the new window's active pane after the capture arrives")
        XCTAssertEqual(controller.renderedWindowId, WindowId(1))
        XCTAssertEqual(controller.renderedPaneId, PaneId(3))
        XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(1) })?.activePaneTitle, "pane title")
    }

    func test_displayWillSwap_reportsWindowTransitionAndAltScreenBeforeFeed() {
        let (controller, fed, sent) = makeController()

        var events: [String] = []
        controller.feedTerminal = { slice in
            events.append("feed")
            fed.append(contentsOf: slice)
        }
        controller.displayWillSwap = { from, to, paneInAltScreen in
            events.append("hook:\(from?.description ?? "nil")->\(to.description):\(paneInAltScreen)")
        }

        // Attach init with two known windows and @5 as the active
        // window. This drives the first guarded render refresh without
        // any prior renderer owner, so the hook's from-window is nil.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        sent.clear()

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array("%begin 0 5 1\r\n@5 editor\r\n@7 logs\r\n%end 0 5 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 6 1\r\n@5\t%12\t1\t\tpane title\thost\r\n@7\t%99\t1\t\tlogs title\thost\r\n%end 0 6 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 7 1\r\n@5\r\n%end 0 7 1\r\n".utf8))
        sent.clear()

        // The pane metadata subscription was queued before the render
        // metadata query, so its response drains first.
        controller.ingest(Array("%begin 0 8 1\r\n%end 0 8 1\r\n".utf8))
        controller.ingest(responseFrame(9, body: [
            renderedPaneMetadataLine(
                paneId: 12,
                cursorX: 8,
                cursorY: 3,
                paneTitle: "pane title",
                windowName: "editor",
                alternateOn: true,
                historySize: 0,
                altSavedX: 4,
                altSavedY: 2
            )
        ]))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -a -q -t @5\n"
        )
        sent.clear()

        controller.ingest(responseFrame(10, body: ["saved primary"]))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -t @5\n"
        )
        sent.clear()

        controller.ingest(responseFrame(11, body: ["editor body"]))

        controller.ingest(Array("%session-window-changed $0 @7\r\n".utf8))
        sent.clear()
        controller.ingest(responseFrame(1, body: [
            renderedPaneMetadataLine(
                paneId: 99,
                cursorX: 1,
                cursorY: 2,
                paneTitle: "logs title",
                windowName: "logs",
                alternateOn: false
            )
        ], time: 1))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -t @7\n"
        )
        sent.clear()

        controller.ingest(responseFrame(2, body: ["logs body"], time: 1))

        XCTAssertEqual(
            events,
            [
                "hook:nil->@5:true",
                "feed",
                "hook:@5->@7:false",
                "feed",
            ],
            "displayWillSwap should receive the previous/rendered window and fire before terminal feed"
        )
        XCTAssertEqual(controller.renderedWindowId, WindowId(7))
        XCTAssertEqual(controller.renderedPaneId, PaneId(99))
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("logs body"))
    }

    func test_displayWillSwap_sameWindowLegacyMetadataDefaultsAltScreenFalse() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        var hooks: [String] = []
        controller.displayWillSwap = { from, to, paneInAltScreen in
            hooks.append("\(from?.description ?? "nil")->\(to.description):\(paneInAltScreen)")
        }

        controller.ingest(Array("%window-pane-changed @0 %4\r\n".utf8))
        sent.clear()

        // Six fields is the legacy rendered metadata shape:
        // pane, cursor x/y, pane title, window name, host.
        controller.ingest(Array("%begin 1 1 1\r\n%4\t2\t1\tnew pane\tzsh\thost\r\n%end 1 1 1\r\n".utf8))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -t @0\n"
        )
        sent.clear()

        controller.ingest(Array("%begin 1 2 1\r\npane four\r\n%end 1 2 1\r\n".utf8))

        XCTAssertEqual(hooks, ["@0->@0:false"])
        XCTAssertEqual(controller.renderedPaneId, PaneId(4))
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("pane four"))
    }

    func test_displaySwap_sessionWindowChangedQueriesWhenActivePaneNil() {
        // Even without a latched pane, session-window-changed is
        // authoritative tmux focus and should trigger the guarded
        // render refresh.
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @0\r\n".utf8))

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            renderedMetadataCommand(windowId: 0)
        )
    }

    func test_displaySwap_skippedWhenSameWindow() {
        // session-window-changed to the SAME window is a no-op — tmux
        // sometimes emits this on reattach or select-window of the
        // current window, and repainting would be wasteful.
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        sent.clear()

        // Another session-window-changed to the same window.
        controller.ingest(Array("%session-window-changed $0 @0\r\n".utf8))

        XCTAssertEqual(sent.bytes, [],
                       "same-window session-window-changed should not re-query")
    }

    func test_displaySwap_queryErrorLeavesActivePaneIntact() {
        // If the display-message query comes back with %error (e.g.
        // the target window was killed between the notification and
        // our query), the refresh should abort silently and activePaneId
        // should not keep targeting the old pane after tmux focus moved.
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        XCTAssertEqual(controller.activePaneId, PaneId(0))
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        // display-message query was sent.
        XCTAssertFalse(sent.bytes.isEmpty)
        sent.clear()

        // Tmux replies with an error.
        controller.ingest(Array(
            "%begin 1 1 1\r\ncan't find window\r\n%error 1 1 1\r\n".utf8
        ))

        XCTAssertEqual(sent.bytes, [],
                       "no follow-up capture query should be sent after an error")
        XCTAssertNil(controller.activePaneId,
                     "activePaneId should not keep targeting the old pane on query failure")
        XCTAssertNil(controller.renderedWindowId,
                     "query failure should clear stale rendered ownership")
        XCTAssertNil(controller.renderedPaneId,
                     "query failure should stop the old pane from painting after focus moved")
    }

    func test_displaySwap_malformedResponseAborts() {
        // If display-message returns something that doesn't match the
        // expected tab-separated metadata format, the refresh aborts gracefully.
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        sent.clear()

        // Response body is garbled — no pane id, no cursor position.
        controller.ingest(Array(
            "%begin 1 1 1\r\ngarbage response\r\n%end 1 1 1\r\n".utf8
        ))

        XCTAssertEqual(sent.bytes, [],
                       "malformed response should not produce a capture-pane follow-up")
        XCTAssertNil(controller.activePaneId,
                     "activePaneId should not keep targeting the old pane when the response can't be parsed")
        XCTAssertNil(controller.renderedWindowId)
        XCTAssertNil(controller.renderedPaneId)
    }

    func test_displaySwap_fastSwitchIgnoresLateFirstRefresh() async throws {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            renderedMetadataCommand(windowId: 1)
        )
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        XCTAssertEqual(controller.activeWindowId, WindowId(2))
        XCTAssertEqual(sent.bytes, [], "the replacement refresh waits for the older metadata response")

        controller.ingest(Array("%begin 1 1 1\r\n%11\t4\t5\tlate one\tone\r\n%end 1 1 1\r\n".utf8))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            renderedMetadataCommand(windowId: 2),
            "late @1 metadata must not capture, then @2 should run alone"
        )
        sent.clear()

        controller.ingest(Array("%begin 1 2 1\r\n%22\t6\t7\tcurrent two\ttwo\r\n%end 1 2 1\r\n".utf8))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -t @2\n"
        )
        sent.clear()

        controller.ingest(Array("%begin 1 3 1\r\nwindow two\r\n%end 1 3 1\r\n".utf8))

        XCTAssertEqual(controller.activeWindowId, WindowId(2))
        XCTAssertEqual(controller.activePaneId, PaneId(22))
        XCTAssertEqual(controller.renderedWindowId, WindowId(2))
        XCTAssertEqual(controller.renderedPaneId, PaneId(22))
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("window two"))
    }

    func test_displaySwap_dropsOldPaneOutputWhileRefreshPending() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        sent.clear()

        controller.ingest(Array("%output %0 stale bytes\r\n".utf8))

        XCTAssertEqual(fed.bytes, [],
                       "old rendered pane output must be ignored during pending active-window refresh")
    }

    func test_pendingInlineRefreshStillAnswersTerminalColorQueries() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        var queriedPane: PaneId?
        controller.terminalResponseForOutput = { paneId, data in
            guard String(decoding: data, as: UTF8.self).contains("\u{1B}]10;?") else {
                return nil
            }
            queriedPane = paneId
            return [0x52]
        }

        controller.ingest(Array("%window-pane-changed @0 %4\r\n".utf8))
        sent.clear()

        controller.ingest(Array("%output %4 \u{1B}]10;?\u{07}\r\n".utf8))

        XCTAssertEqual(queriedPane, PaneId(4))
        XCTAssertEqual(fed.bytes, [],
                       "pane output should still be withheld while the guarded render refresh is pending")
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "refresh-client -r '%4:R'\n",
            "terminal color query responses must still reach the pane during a pending render refresh"
        )
    }

    func test_initialRenderedPanePreloadsTerminalDefaultColorReport() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%window-add @0\r\n".utf8))
        controller.ingest(Array("%begin 0 50 1\r\nzsh\r\n%end 0 50 1\r\n".utf8))
        fed.clear()
        sent.clear()

        var queriedPane: PaneId?
        controller.terminalResponseForOutput = { paneId, data in
            guard String(decoding: data, as: UTF8.self).contains("\u{1B}]10;?") else {
                return nil
            }
            queriedPane = paneId
            return [0x52]
        }

        controller.ingest(Array("%output %3 boot\r\n".utf8))

        XCTAssertEqual(queriedPane, PaneId(3))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "refresh-client -r '%3:R'\n"
        )
        XCTAssertEqual(String(decoding: fed.bytes, as: UTF8.self), "boot")
    }

    func test_renderedInlinePaneAnswersTerminalColorQueriesBeforeRendererRoundTrip() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        var queriedPane: PaneId?
        controller.terminalResponseForOutput = { paneId, data in
            guard String(decoding: data, as: UTF8.self).contains("\u{1B}]10;?") else {
                return nil
            }
            queriedPane = paneId
            return [0x52]
        }

        controller.ingest(Array("%output %0 \u{1B}]10;?\u{07}after\r\n".utf8))

        XCTAssertEqual(queriedPane, PaneId(0))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "refresh-client -r '%0:R'\n"
        )
        XCTAssertEqual(
            String(decoding: fed.bytes, as: UTF8.self),
            "\u{1B}]10;?\u{07}after",
            "the rendered terminal should still see the original output after the low-latency synthesized reply is sent"
        )
    }

    func test_windowPaneChanged_activeInlineWindowRefreshesRenderAndInputTarget() {
        let (controller, fed, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller)
        fed.clear()
        sent.clear()

        controller.ingest(Array("%window-pane-changed @0 %4\r\n".utf8))

        XCTAssertEqual(controller.activePaneId, PaneId(4),
                       "input target should move to tmux's new active pane immediately")
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            renderedMetadataCommand(windowId: 0)
        )
        sent.clear()

        controller.ingest(Array("%begin 1 1 1\r\n%4\t2\t1\tnew pane\tzsh\r\n%end 1 1 1\r\n".utf8))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -t @0\n"
        )
        sent.clear()

        controller.ingest(Array("%begin 1 2 1\r\npane four\r\n%end 1 2 1\r\n".utf8))

        XCTAssertEqual(controller.renderedPaneId, PaneId(4))
        XCTAssertEqual(controller.windows.first?.activePaneTitle, "new pane")
        XCTAssertTrue(String(decoding: fed.bytes, as: UTF8.self).contains("pane four"))
    }

    // MARK: - %window-pane-changed window-id filter + pending-focus latch

    func test_windowPaneChanged_unknownWindowIsStashedNotLeaked() {
        // %window-pane-changed is broadcast to every control client with NO
        // session filter, so it can name a foreign session's window. It must NOT
        // ensureWindow-create a phantom tab, move our active window/pane, or emit
        // any command — it is stashed pending the window's (never-arriving)
        // appearance.
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller) // @0 active
        let activeWindowBefore = controller.activeWindowId
        let activePaneBefore = controller.activePaneId
        sent.clear()

        controller.ingest(Array("%window-pane-changed @9 %77\r\n".utf8))

        XCTAssertFalse(
            controller.windows.contains(where: { $0.id == WindowId(9) }),
            "a broadcast pane-changed for an unknown window must not leak a phantom window"
        )
        XCTAssertEqual(controller.activeWindowId, activeWindowBefore)
        XCTAssertEqual(controller.activePaneId, activePaneBefore)
        XCTAssertEqual(sent.bytes, [], "stashing must not emit any command")
    }

    func test_windowPaneChanged_stashAppliedWhenWindowAddArrives() {
        // Same-session window whose focus broadcast outraces its %window-add.
        // The stash is applied when the session-scoped add brings it into view.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller) // @0 active

        controller.ingest(Array("%window-pane-changed @5 %50\r\n".utf8))
        XCTAssertFalse(
            controller.windows.contains(where: { $0.id == WindowId(5) }),
            "still stashed; the window is not created from the broadcast"
        )

        controller.ingest(Array("%window-add @5\r\n".utf8))

        let w5 = controller.windows.first(where: { $0.id == WindowId(5) })
        XCTAssertEqual(
            w5?.activePaneId, PaneId(50),
            "stashed pane focus should seed the window's active pane on appearance"
        )
        XCTAssertEqual(
            controller.activeWindowId, WindowId(0),
            "a background window-add must not steal the active window"
        )
    }

    func test_windowPaneChanged_stashAppliedWhenWindowRenamedCreatesWindowFirst() {
        // Regression: a %window-renamed that materializes the window before
        // %window-add must also apply the stash (it creates via ensureWindow).
        // Otherwise the stash could be stranded until hydration clears it, and a
        // late %window-add would find nothing to drain.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller) // @0 active

        controller.ingest(Array("%window-pane-changed @5 %50\r\n".utf8)) // unknown -> stash
        controller.ingest(Array("%window-renamed @5 editor\r\n".utf8))   // creates @5 -> drains

        let w5 = controller.windows.first(where: { $0.id == WindowId(5) })
        XCTAssertEqual(w5?.windowName, "editor")
        XCTAssertEqual(
            w5?.activePaneId, PaneId(50),
            "the window-renamed creation must apply the stashed pane focus, not strand it"
        )

        // A later %window-add for the same window is now a no-op for the stash
        // (already drained) and must not disturb the applied focus.
        controller.ingest(Array("%window-add @5\r\n".utf8))
        XCTAssertEqual(
            controller.windows.first(where: { $0.id == WindowId(5) })?.activePaneId,
            PaneId(50)
        )
    }

    func test_windowPaneChanged_stashAppliedWhenSessionWindowChangedArrives() {
        // The pre-cache the side-channel design relies on, now expressed through
        // the latch: focus stashed for an unknown window is applied when a
        // session-scoped %session-window-changed makes it active.
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        seedInlineRenderedWindow(controller) // @0 active

        controller.ingest(Array("%window-pane-changed @9 %77\r\n".utf8))   // unknown -> stash
        controller.ingest(Array("%session-window-changed $0 @9\r\n".utf8)) // becomes active -> drain

        XCTAssertEqual(controller.activeWindowId, WindowId(9))
        XCTAssertEqual(
            controller.activePaneId, PaneId(77),
            "selecting the now-known window applies its stashed active pane"
        )
    }

    func test_windowPaneChanged_hydrationClearsStash() {
        // Hydration is the authoritative active-pane snapshot, so a pre-hydration
        // stash for a window absent from the list must be dropped — never applied
        // afterward.
        let (controller, _, _) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%window-pane-changed @9 %77\r\n".utf8)) // stash before hydration

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8)) // pause-after
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8)) // bell subscription
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n%end 0 4 1\r\n".utf8)) // list-windows (no @9)
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%12\t1\thtop\tremote.example.com\tremote.example.com\r\n%end 0 5 1\r\n".utf8
        )) // list-panes
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8)) // active-window

        XCTAssertFalse(
            controller.windows.contains(where: { $0.id == WindowId(9) }),
            "hydration must not materialize a window that was only stashed"
        )

        // Prove the stash was dropped (not merely shadowed): a later window-add
        // of @9 seeds NO active pane, because nothing remains stashed for it.
        controller.ingest(Array("%window-add @9\r\n".utf8))
        let w9 = controller.windows.first(where: { $0.id == WindowId(9) })
        XCTAssertNotNil(w9, "window-add should now create @9")
        XCTAssertNil(
            w9?.activePaneId,
            "the pre-hydration stash must have been cleared, so nothing seeds @9"
        )
    }

    func test_windowPaneChanged_activeWindowPaneFocusKeepsActiveWindowAndStaysInert() {
        // M6 invariant: the mosh scrollback clear keys on activeWindowId ONLY,
        // so a pane focus change WITHIN the active window must leave
        // activeWindowId untouched (never trip a gratuitous clear) and must not
        // feed the terminal on the render-inert side channel.
        let (controller, fed, _) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8)) // pause-after
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8)) // bell subscription
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n%end 0 4 1\r\n".utf8)) // list-windows
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%12\t1\thtop\tremote.example.com\tremote.example.com\r\n%end 0 5 1\r\n".utf8
        )) // list-panes
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8)) // active-window
        XCTAssertEqual(controller.activeWindowId, WindowId(5))
        fed.clear()

        controller.ingest(Array("%window-pane-changed @5 %13\r\n".utf8))

        XCTAssertEqual(
            controller.activeWindowId, WindowId(5),
            "pane focus within the active window must not move the active window"
        )
        XCTAssertEqual(controller.activePaneId, PaneId(13))
        XCTAssertEqual(
            fed.bytes, [],
            "side-channel pane focus must stay render-inert (no terminal feed)"
        )
    }

    // MARK: - Client size (refresh-client -C) (§3.2 commit C)

    func test_updateClientSize_passthroughDoesNotSend() {
        // In passthrough there's no tmux to talk to — the SSH session
        // handles SIGWINCH separately, and tmux mode is the only place
        // refresh-client -C makes sense.
        let (controller, _, sent) = makeController()
        controller.updateClientSize(cols: 130, rows: 40)
        XCTAssertEqual(sent.bytes, [])
    }

    func test_updateClientSize_tmuxModeSendsRefreshClient() {
        let (controller, _, sent) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        controller.updateClientSize(cols: 130, rows: 40)

        XCTAssertEqual(
            sent.bytes,
            Array("refresh-client -C 130,40\n".utf8),
            "tmux -CC needs refresh-client -C <cols>,<rows> — SIGWINCH to the PTY is ignored"
        )
    }

    func test_updateClientSize_sideChannelModeSendsRefreshClient() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        controller.updateClientSize(cols: 130, rows: 40)

        XCTAssertEqual(
            sent.bytes,
            Array("refresh-client -C 130,40\n".utf8),
            "side-channel tmux -CC also ignores PTY resize; keep command context at the visible mosh size"
        )
    }

    func test_enteringTmuxMode_pushesCachedSizeAfterHandshake() {
        // The happy path: SwiftTerm reports its real size before the
        // user launches tmux -CC. When the DCS arrives AND tmux's
        // spontaneous handshake frame drains, the cached size should
        // get pushed via refresh-client -C as part of the attach init
        // flow. The flush is deferred to AFTER the handshake so the
        // pendingCommands FIFO doesn't misalign with the server-originated
        // %end (flags bit0 clear).
        let (controller, _, sent) = makeController()
        controller.updateClientSize(cols: 130, rows: 40) // passthrough: caches but sends nothing
        XCTAssertEqual(sent.bytes, [])

        // DCS prologue alone doesn't flush yet — we have to wait for
        // tmux's spontaneous %begin/%end first.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        XCTAssertEqual(sent.bytes, [],
                       "must not send anything until tmux's handshake frame is drained")

        // Now feed the spontaneous frame. This should trigger
        // flushAttachInitQueries → refresh-client + list-windows.
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        let actual = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(
            actual.contains("set-option -g history-limit 10000\n"),
            "inline attach should raise history-limit for windows created after attach"
        )
        XCTAssertTrue(
            actual.contains("refresh-client -C 130,40\n"),
            "refresh-client -C should land in the post-handshake init queries; got: \(actual)"
        )
        XCTAssertTrue(
            actual.contains("list-windows -F"),
            "list-windows should also be part of the attach init flow; got: \(actual)"
        )
    }

    func test_enteringTmuxMode_withoutCachedSize_skipsRefreshClient() {
        // If the outer view never called updateClientSize, the attach
        // init flow should skip refresh-client -C (no bogus 0,0) and
        // go straight to metadata discovery. tmux falls back to its
        // launch-time PTY winsize which is fine for the bare-test case.
        let (controller, _, sent) = makeController()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        let actual = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(
            actual.contains("set-option -g history-limit 10000\n"),
            "inline attach should set history-limit even when no size is cached"
        )
        XCTAssertFalse(
            actual.contains("refresh-client -C"),
            "no refresh-client -C should be sent when no client size has been cached"
        )
        XCTAssertTrue(
            actual.contains("list-windows -F"),
            "list-windows should still be part of the attach init flow even without a cached size"
        )
    }

    func test_enteringTmuxMode_sideChannelPushesCachedSizeAndStillQueriesWindows() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        controller.updateClientSize(cols: 130, rows: 40)
        XCTAssertEqual(sent.bytes, [])

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        let actual = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertFalse(
            actual.contains("set-option -g history-limit"),
            "side-channel mode should not mutate server options on the control-only channel"
        )
        XCTAssertTrue(
            actual.contains("refresh-client -C 130,40\n"),
            "side-channel mode should replay cached size so new tmux windows use the visible mosh geometry"
        )
        XCTAssertTrue(
            actual.contains("list-windows -F"),
            "side-channel mode still needs the attach-init window query to rebuild the tab model"
        )
    }

    func test_attachInit_sideChannelPopulatesTabsWithoutDisplaySwap() {
        let (controller, fed, sent) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        let initialCommands = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(initialCommands.contains("list-windows -F"))
        XCTAssertTrue(initialCommands.contains("list-panes -s -F"))
        XCTAssertTrue(initialCommands.contains("display-message -p '#{window_id}'"))
        XCTAssertTrue(initialCommands.contains("refresh-client -B 'tessera-pane-meta:%*"))
        XCTAssertFalse(initialCommands.contains("refresh-client -C"))
        sent.clear()

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 4 1\r\n@5 editor\r\n@7 logs\r\n%end 0 4 1\r\n".utf8
        ))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%41\t1\t\teditor title\thost\r\n@7\t%42\t1\t\tlogs title\thost\r\n%end 0 5 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 6 1\r\n@7\r\n%end 0 6 1\r\n".utf8))

        XCTAssertEqual(
            controller.windows,
            [
                .init(id: WindowId(5), windowName: "editor", activePaneId: PaneId(41), activePaneTitle: "editor title",
                      panes: [TmuxController.PaneInfo(id: PaneId(41), title: "editor title", isActive: true)]),
                .init(id: WindowId(7), windowName: "logs", activePaneId: PaneId(42), activePaneTitle: "logs title",
                      panes: [TmuxController.PaneInfo(id: PaneId(42), title: "logs title", isActive: true)]),
            ]
        )
        XCTAssertEqual(controller.activeWindowId, WindowId(7))
        XCTAssertEqual(controller.activePaneId, PaneId(42),
                       "side-channel mode should learn the active pane for targeted tmux queries")
        XCTAssertEqual(controller.windows.last?.displayName, "logs title")
        XCTAssertEqual(fed.bytes, [],
                       "attach-init in side-channel mode must not repaint the terminal")
        XCTAssertEqual(sent.bytes, [],
                       "no capture-pane/display-swap follow-up should be sent in side-channel mode")
    }

    func test_attachInit_defaultPaneTitleFallsBackToWindowName() {
        let (controller, fed, sent) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        sent.clear()

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@5 htop\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%41\t1\t\tremote.example.com\tremote.example.com\r\n%end 0 5 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))

        let window = controller.windows.first
        XCTAssertEqual(window?.windowName, "htop")
        XCTAssertEqual(window?.activePaneTitle, "remote.example.com")
        XCTAssertEqual(window?.activePaneTitleIsDefault, true)
        XCTAssertEqual(window?.displayName, "htop")
        XCTAssertEqual(fed.bytes, [])
        XCTAssertEqual(sent.bytes, [])
    }

    func test_attachInitHydrationPopulatesPaneCurrentCommand() {
        let (controller, _, _) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%12\t1\thtop\tremote.example.com\tremote.example.com\r\n%end 0 5 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))

        let pane = controller.windows.first?.panes.first
        XCTAssertEqual(pane?.currentCommand, "htop")
        XCTAssertEqual(pane?.title, "remote.example.com")
    }

    func test_sideChannelOutputOSCUpdatesPaneTitleWithoutTerminalFeed() {
        let (controller, fed, sent) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        sent.clear()

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%12\t1\t\tremote.example.com\tremote.example.com\r\n%end 0 5 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))
        XCTAssertEqual(controller.windows.first?.displayName, "editor")

        controller.ingest(Array("%output %12 \u{1B}]0;Semantic Title\u{07}\r\n".utf8))

        XCTAssertEqual(controller.windows.first?.activePaneTitle, "Semantic Title")
        XCTAssertEqual(controller.windows.first?.activePaneTitleIsDefault, false)
        XCTAssertEqual(controller.windows.first?.displayName, "Semantic Title")
        XCTAssertEqual(fed.bytes, [],
                       "side-channel title tracking must not repaint/feed the terminal")
        XCTAssertEqual(sent.bytes, [])
    }

    func test_paneMetadataSubscriptionUpdatesActivePaneTitleWithoutTerminalFeed() {
        let (controller, fed, sent) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        sent.clear()

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%12\t1\t\tremote.example.com\tremote.example.com\r\n%end 0 5 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))

        controller.ingest(Array(
            "%subscription-changed tessera-pane-meta $0 @5 0 %12 : @5\\t%12\\t1\\tvim\\tCodex semantic probe\\teditor\\tremote.example.com\r\n".utf8
        ))

        XCTAssertEqual(controller.windows.first?.activePaneTitle, "Codex semantic probe")
        XCTAssertEqual(controller.windows.first?.activePaneTitleIsDefault, false)
        XCTAssertEqual(controller.windows.first?.displayName, "Codex semantic probe")
        XCTAssertEqual(fed.bytes, [])
        XCTAssertEqual(sent.bytes, [])
    }

    func test_paneMetadataSubscriptionTracksCurrentCommandAndDefaultTitle() {
        let (controller, _, _) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%12\t1\t\tremote.example.com\tremote.example.com\r\n%end 0 5 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))

        controller.ingest(Array(
            "%subscription-changed tessera-pane-meta $0 @5 0 %12 : @5\\t%12\\t1\\thtop\\tremote.example.com\\teditor\\tremote.example.com\r\n".utf8
        ))

        let pane = controller.windows.first?.panes.first
        XCTAssertEqual(pane?.currentCommand, "htop")
        XCTAssertEqual(pane?.titleIsDefault, true)
    }

    func test_paneMetadataTracksContentRectFromHydrationAndSubscription() {
        let (controller, _, _) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%12\t1\t41\t1\t39\t23\tzsh\tpane title\tremote.example.com\r\n%end 0 5 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))

        XCTAssertEqual(
            controller.windows.first?.panes.first?.contentRect,
            CellRect(width: 39, height: 23, x: 41, y: 1)
        )

        controller.ingest(Array(
            "%subscription-changed tessera-pane-meta $0 @5 0 %12 : @5\\t%12\\t1\\t0\\t1\\t40\\t23\\tvim\\tupdated\\teditor\\tremote.example.com\r\n".utf8
        ))

        XCTAssertEqual(
            controller.windows.first?.panes.first?.contentRect,
            CellRect(width: 40, height: 23, x: 0, y: 1)
        )
        XCTAssertEqual(controller.windows.first?.panes.first?.currentCommand, "vim")
    }

    func test_sideChannelOutputOSCTracksSplitAndClearedTitles() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        sent.clear()

        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array("%begin 0 5 1\r\n@5\t%12\t1\t\t\t\r\n%end 0 5 1\r\n".utf8))
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))
        sent.clear()

        controller.ingest(Array("%output %12 \u{1B}]2;Semantic\r\n".utf8))
        XCTAssertEqual(controller.windows.first?.displayName, "editor")

        controller.ingest(Array("%output %12  Title\u{07}\r\n".utf8))
        XCTAssertEqual(controller.windows.first?.displayName, "Semantic Title")

        controller.ingest(Array("%output %12 \u{1B}]2;\u{07}\r\n".utf8))
        XCTAssertEqual(controller.windows.first?.activePaneTitle, nil)
        XCTAssertEqual(controller.windows.first?.displayName, "editor")
        XCTAssertEqual(sent.bytes, [])
    }

    // MARK: - Mosh native per-pane title row (Option 2: pane-border-status)

    private func twoPaneLayoutChange(_ windowId: Int, flags: String = "*") -> [UInt8] {
        let layout = "8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6}"
        return Array("%layout-change @\(windowId) \(layout) \(layout) \(flags)\r\n".utf8)
    }

    private func onePaneLayoutChange(_ windowId: Int) -> [UInt8] {
        let layout = "b25d,80x24,0,0,5"
        return Array("%layout-change @\(windowId) \(layout) \(layout) *\r\n".utf8)
    }

    private var expectedPaneBorderTopCommands: String {
        "set -t @1 pane-border-status top\n"
            + "set -t @1 pane-border-format \"\(TmuxController.moshPaneBorderFormat)\"\n"
    }

    func test_moshPaneBorder_splitEmitsTopAndFormatOnSideChannel() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        sent.clear()

        controller.ingest(twoPaneLayoutChange(1))

        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self), expectedPaneBorderTopCommands,
                       "a window going 1→N panes must set tmux's native title row + format")
    }

    func test_moshPaneBorder_geometryOnlyRelayoutDoesNotResend() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        controller.ingest(twoPaneLayoutChange(1))
        sent.clear()

        // A second multi-pane layout-change (resize/drag) must NOT resend the
        // option — membership tracks "already top".
        controller.ingest(twoPaneLayoutChange(1))

        XCTAssertEqual(sent.bytes, [], "geometry-only %layout-change must not resend pane-border")
    }

    func test_moshPaneBorder_collapseEmitsOff() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        controller.ingest(twoPaneLayoutChange(1))
        sent.clear()

        controller.ingest(onePaneLayoutChange(1))

        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self),
                       "set -t @1 pane-border-status off\n",
                       "collapsing N→1 panes must turn the title row back off")
    }

    func test_moshPaneBorder_singlePaneNeverSets() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        sent.clear()

        // A window that only ever holds one pane must never get a title row
        // (it would shrink the content of every single-pane mosh window).
        controller.ingest(onePaneLayoutChange(1))

        XCTAssertEqual(sent.bytes, [], "single-pane windows must not set pane-border-status")
    }

    func test_moshPaneBorder_inlinePathNeverSets() {
        let (controller, _, sent) = makeController(controlPath: .inline)
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        sent.clear()

        // SSH (inline) draws its own per-pane headers; tmux's native row would
        // double-reserve. The toggle must be side-channel-only.
        controller.ingest(twoPaneLayoutChange(1))

        let commands = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertFalse(commands.contains("pane-border-status"),
                       "inline path must never set pane-border-status (SSH draws its own headers)")
    }

    func test_moshPaneBorder_collapseThenResplitSetsAgain() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        controller.ingest(twoPaneLayoutChange(1))
        controller.ingest(onePaneLayoutChange(1))
        sent.clear()

        // After a full off cycle, a new split must set it again (membership was
        // cleared on collapse).
        controller.ingest(twoPaneLayoutChange(1))

        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self), expectedPaneBorderTopCommands)
    }

    func test_sessionWindowChanged_sideChannelQueriesMissingPaneTitle() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        controller.ingest(Array("%window-pane-changed @9 %77\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @9\r\n".utf8))

        XCTAssertEqual(controller.activeWindowId, WindowId(9))
        XCTAssertEqual(controller.activePaneId, PaneId(77))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "display-message -p -t @9 '#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{pane_current_command}\t#{pane_title}\t#{window_name}\t#{host}'\n",
            "side-channel should query metadata when only the pane id is cached"
        )
    }

    func test_sessionWindowChanged_sideChannelQueriesMissingActivePane() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @9\r\n".utf8))

        XCTAssertEqual(controller.activeWindowId, WindowId(9))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "display-message -p -t @9 '#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{pane_current_command}\t#{pane_title}\t#{window_name}\t#{host}'\n"
        )
        sent.clear()

        controller.ingest(Array("%begin 0 9 1\r\n%88\t0\t13\t80\t11\tbash\tpane title\tlogs\thost\r\n%end 0 9 1\r\n".utf8))

        XCTAssertEqual(controller.activePaneId, PaneId(88))
        XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(9) })?.displayName, "pane title")
        XCTAssertEqual(
            controller.windows.first(where: { $0.id == WindowId(9) })?.panes.first(where: { $0.id == PaneId(88) })?.contentRect,
            CellRect(width: 80, height: 11, x: 0, y: 13)
        )
        XCTAssertEqual(sent.bytes, [])
    }

    func test_sideChannelActivePaneQueryDoesNotOverwriteAfterWindowSwitch() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeAndDrainAttachInit(controller)
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @9\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @10\r\n".utf8))
        XCTAssertEqual(controller.activeWindowId, WindowId(10))
        sent.clear()

        controller.ingest(Array("%begin 0 9 1\r\n%88\told title\told\r\n%end 0 9 1\r\n".utf8))

        XCTAssertNil(controller.activePaneId,
                     "stale side-channel pane query must not replace the current active pane")

        controller.ingest(Array("%begin 0 10 1\r\n%99\tnew title\tnew\r\n%end 0 10 1\r\n".utf8))

        XCTAssertEqual(controller.activePaneId, PaneId(99))
    }

    func test_resetAndReconnect_sideChannelRequeriesFreshTmuxState() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@1 old\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array("%begin 0 5 1\r\n@1\t%11\t1\t\told title\thost\r\n%end 0 5 1\r\n".utf8))
        controller.ingest(Array("%begin 0 6 1\r\n@1\r\n%end 0 6 1\r\n".utf8))
        XCTAssertEqual(
            controller.windows,
            [.init(id: WindowId(1), windowName: "old", activePaneId: PaneId(11), activePaneTitle: "old title",
                   panes: [TmuxController.PaneInfo(id: PaneId(11), title: "old title", isActive: true)])]
        )
        XCTAssertEqual(controller.activeWindowId, WindowId(1))

        controller.reset()
        XCTAssertTrue(controller.windows.isEmpty)
        XCTAssertNil(controller.activeWindowId)

        sent.clear()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 4 0\r\n%end 0 4 0\r\n".utf8))

        let requeryCommands = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(
            requeryCommands.contains("list-windows -F"),
            "reconnect should rebuild state from tmux truth rather than diffing stale local tabs"
        )
        sent.clear()

        controller.ingest(Array("%begin 0 5 1\r\n%end 0 5 1\r\n".utf8))
        controller.ingest(Array("%begin 0 6 1\r\n%end 0 6 1\r\n".utf8))
        controller.ingest(Array("%begin 0 7 1\r\n@9 fresh\r\n%end 0 7 1\r\n".utf8))
        controller.ingest(Array("%begin 0 8 1\r\n@9\t%19\t1\t\tfresh title\thost\r\n%end 0 8 1\r\n".utf8))
        controller.ingest(Array("%begin 0 9 1\r\n@9\r\n%end 0 9 1\r\n".utf8))

        XCTAssertEqual(
            controller.windows,
            [.init(id: WindowId(9), windowName: "fresh", activePaneId: PaneId(19), activePaneTitle: "fresh title",
                   panes: [TmuxController.PaneInfo(id: PaneId(19), title: "fresh title", isActive: true)])]
        )
        XCTAssertEqual(controller.activeWindowId, WindowId(9))
    }

    func test_sideChannelDisconnected_preservesTabsButCancelsPendingCommands() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n@5 editor\r\n@7 logs\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array("%begin 0 5 1\r\n@5\t%51\t1\t\teditor title\thost\r\n@7\t%71\t1\t\tlogs title\thost\r\n%end 0 5 1\r\n".utf8))
        controller.ingest(Array("%begin 0 6 1\r\n@7\r\n%end 0 6 1\r\n".utf8))

        XCTAssertEqual(
            controller.windows,
            [
                .init(id: WindowId(5), windowName: "editor", activePaneId: PaneId(51), activePaneTitle: "editor title",
                      panes: [TmuxController.PaneInfo(id: PaneId(51), title: "editor title", isActive: true)]),
                .init(id: WindowId(7), windowName: "logs", activePaneId: PaneId(71), activePaneTitle: "logs title",
                      panes: [TmuxController.PaneInfo(id: PaneId(71), title: "logs title", isActive: true)]),
            ]
        )
        XCTAssertEqual(controller.activeWindowId, WindowId(7))

        sent.clear()
        let capture = CompletionCapture<[String], TmuxController.CommandError>()
        controller.sendControlCommand("select-window -t @5") { result in
            capture.store(result)
        }
        XCTAssertEqual(sent.bytes, Array("select-window -t @5\n".utf8))

        controller.sideChannelDisconnected()

        XCTAssertEqual(controller.mode, .passthrough)
        XCTAssertEqual(
            controller.windows,
            [
                .init(id: WindowId(5), windowName: "editor", activePaneId: PaneId(51), activePaneTitle: "editor title",
                      panes: [TmuxController.PaneInfo(id: PaneId(51), title: "editor title", isActive: true)]),
                .init(id: WindowId(7), windowName: "logs", activePaneId: PaneId(71), activePaneTitle: "logs title",
                      panes: [TmuxController.PaneInfo(id: PaneId(71), title: "logs title", isActive: true)]),
            ],
            "degraded-state UI needs the last known tab model even after the side channel drops"
        )
        XCTAssertEqual(controller.activeWindowId, WindowId(7))

        switch capture.result {
        case .some(.failure(.cancelled)):
            break
        default:
            XCTFail("expected pending tmux command to be cancelled when the side channel disconnects")
        }

        sent.clear()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 4 0\r\n%end 0 4 0\r\n".utf8))

        let reattachCommands = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(
            reattachCommands.contains("list-windows -F"),
            "reattach should use the normal attach-init query path"
        )
        sent.clear()

        controller.ingest(Array("%begin 0 5 1\r\n%end 0 5 1\r\n".utf8))
        controller.ingest(Array("%begin 0 6 1\r\n%end 0 6 1\r\n".utf8))
        controller.ingest(Array("%begin 0 7 1\r\n@9 fresh\r\n%end 0 7 1\r\n".utf8))
        controller.ingest(Array("%begin 0 8 1\r\n@9\t%91\t1\t\tfresh title\thost\r\n%end 0 8 1\r\n".utf8))
        controller.ingest(Array("%begin 0 9 1\r\n@9\r\n%end 0 9 1\r\n".utf8))

        XCTAssertEqual(
            controller.windows,
            [.init(id: WindowId(9), windowName: "fresh", activePaneId: PaneId(91), activePaneTitle: "fresh title",
                   panes: [TmuxController.PaneInfo(id: PaneId(91), title: "fresh title", isActive: true)])]
        )
        XCTAssertEqual(
            controller.activeWindowId,
            WindowId(9),
            "reattach should replace stale degraded tabs with tmux's current state"
        )
    }

    // MARK: - Attach init flow (bug fix: stuck on second connect)

    func test_attachInit_handshakeFrameDoesNotMisalignFIFO() {
        // tmux's spontaneous %begin/%end handshake right after the
        // DCS prologue must NOT pop a pending command's completion —
        // if it did, the list-windows callback (the head of the
        // post-handshake init queue) would fire on the empty
        // handshake body and parse zero windows, leaving the tab
        // strip empty even when the session has windows. This is the
        // exact failure mode that was producing the user's "stuck on
        // second connect" symptom.
        let (controller, _, _) = makeController()

        // DCS + handshake.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        // Drain history-limit, pause-after, and bell subscription, then feed
        // the list-windows response with a real window list. If the FIFO was
        // misaligned, my list-windows callback would have fired on the empty
        // handshake body above and the controller's `windows` would still be
        // empty. Instead it should fire on this response and populate the
        // windows.
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5 editor\r\n@7 logs\r\n%end 0 5 1\r\n".utf8
        ))

        XCTAssertEqual(
            controller.windows.map(\.id),
            [WindowId(5), WindowId(7)],
            "list-windows callback should fire on its real response, NOT the spontaneous handshake's empty body"
        )
    }

    func test_attachInit_querysListWindowsAndPaints() {
        // Verify the attach path: after the DCS+handshake, the
        // controller runs shared window/pane/active-window hydration,
        // then performs an inline render refresh. End-to-end, this
        // populates the tab strip when re-attaching to an existing
        // tmux session that doesn't replay %window-add.
        let (controller, fed, sent) = makeController()
        controller.updateClientSize(cols: 100, rows: 30)

        // DCS + handshake.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))

        // The init flow should have sent history-limit, refresh-client
        // (cached size), plus the shared hydration queries before we feed responses.
        let postHandshakeSent = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(
            postHandshakeSent.contains("set-option -g history-limit 10000\n"),
            "should set history-limit before creating post-attach windows"
        )
        XCTAssertTrue(
            postHandshakeSent.contains("refresh-client -C 100,30\n"),
            "should have sent refresh-client with the cached size"
        )
        XCTAssertTrue(
            postHandshakeSent.contains("list-windows -F '#{window_id}\t#{window_layout}\t#{window_visible_layout}\t#{window_zoomed_flag}\t#{window_name}'\n"),
            "should have sent the widened list-windows (name last) to discover existing windows + layouts"
        )
        XCTAssertTrue(postHandshakeSent.contains("list-panes -s -F"))
        XCTAssertTrue(postHandshakeSent.contains("display-message -p '#{window_id}'"))
        sent.clear()

        // Drain history-limit, refresh-client, pause-after, and bell subscription.
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array("%begin 0 5 1\r\n%end 0 5 1\r\n".utf8))
        // Feed the list-windows response with two windows.
        controller.ingest(Array(
            "%begin 0 6 1\r\n@5 editor\r\n@7 logs\r\n%end 0 6 1\r\n".utf8
        ))

        XCTAssertEqual(controller.windows.count, 2,
                       "list-windows response should populate the windows list")
        XCTAssertEqual(controller.windows.map(\.id), [WindowId(5), WindowId(7)])
        XCTAssertEqual(controller.windows.map(\.windowName), ["editor", "logs"])

        // Feed the shared pane metadata response before the active
        // window response, matching command order.
        controller.ingest(Array(
            "%begin 0 7 1\r\n@5\t%12\t1\t\tpane title\thost\r\n@7\t%99\t1\t\tlogs title\thost\r\n%end 0 7 1\r\n".utf8
        ))
        XCTAssertEqual(
            controller.windows.first(where: { $0.id == WindowId(5) })?.activePaneId,
            PaneId(12)
        )

        // Reply with @5 as the active window.
        controller.ingest(Array("%begin 0 8 1\r\n@5\r\n%end 0 8 1\r\n".utf8))

        XCTAssertEqual(controller.activeWindowId, WindowId(5),
                       "active window should be set from the display-message response")

        // The active-window handler should chain into the guarded
        // render metadata query.
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            renderedMetadataCommand(windowId: 5),
            "active-window callback should trigger the guarded render metadata query"
        )
        sent.clear()

        // The pane metadata subscription was sent during attach init
        // before the render metadata query could be queued, so its
        // command response drains first.
        controller.ingest(Array("%begin 0 9 1\r\n%end 0 9 1\r\n".utf8))

        let metadata = renderedPaneMetadataLine(
            paneId: 12,
            cursorX: 8,
            cursorY: 3,
            paneTitle: "pane title",
            windowName: "editor",
            alternateOn: false
        )
        controller.ingest(responseFrame(10, body: [metadata]))

        // Attach hydration paints only a deep stage; readiness waits
        // for this capture to finish.
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -S -2000 -t @5\n"
        )
        XCTAssertFalse(controller.isInitialRenderReady)
        sent.clear()

        let captureLines = ["hello world", "$ "]
        controller.ingest(responseFrame(11, body: captureLines))

        // Now the terminal should be cleared + filled + cursor restored,
        // and activePaneId should be %12.
        XCTAssertEqual(controller.activePaneId, PaneId(12),
                       "after the capture-pane drain, activePaneId should equal the queried pane")
        XCTAssertEqual(controller.renderedWindowId, WindowId(5))
        XCTAssertEqual(controller.renderedPaneId, PaneId(12))
        XCTAssertEqual(controller.windows.first?.displayName, "pane title")
        XCTAssertFalse(fed.bytes.isEmpty,
                       "feedTerminal should have received the clear+capture+cursor bytes")
        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(captureLines: captureLines, cursorX: 8, cursorY: 3),
            "attach repaint should match the section C deep repaint byte contract"
        )
        XCTAssertTrue(controller.isInitialRenderReady)
    }

    func test_attachInit_repaintsEvenWhenActivePaneAlreadyLatched() {
        // Create path: %output arrives during the init flow and
        // latches activePaneId. The list-windows + active-window
        // queries are still part of the init flow, and the authoritative
        // capture should still happen so early output cannot suppress
        // tmux-truth hydration.
        let (controller, fed, sent) = makeController()

        // DCS + handshake.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        // Inject %output before the init responses come back — this
        // mimics tmux's create-path notification burst.
        // pendingCommands at this point:
        // [history-limit, pause-after, bell-subscription, list-windows,
        //  list-panes, active-window, pane-subscription]
        controller.ingest(Array("%window-add @0\r\n%output %0 boot\r\n".utf8))
        // C3: %window-add @0 queued a window-name query.
        // pendingCommands:
        // [history-limit, pause-after, bell-subscription, list-windows,
        //  list-panes, active-window, pane-subscription, name@0]
        XCTAssertEqual(controller.activePaneId, PaneId(0),
                       "%output should latch activePaneId even mid-init")
        fed.clear()

        // Drain history-limit, pause-after, bell subscription, then
        // list-windows. The handler parses
        // "@0 zsh", updates the name, and chains the active-window
        // pendingCommands after:
        // [list-panes, active-window, pane-subscription, name@0]
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array("%begin 0 4 1\r\n%end 0 4 1\r\n".utf8))
        controller.ingest(Array("%begin 0 5 1\r\n@0 zsh\r\n%end 0 5 1\r\n".utf8))

        // Drain list-panes, then active-window.
        controller.ingest(Array("%begin 0 6 1\r\n@0\t%0\t1\t\tboot title\thost\r\n%end 0 6 1\r\n".utf8))

        sent.clear()
        controller.ingest(Array("%begin 0 7 1\r\n@0\r\n%end 0 7 1\r\n".utf8))

        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            renderedMetadataCommand(windowId: 0),
            "active-window callback should still chain into the guarded render refresh"
        )
        sent.clear()

        // Drain the pane metadata subscription and C3 window-name
        // query before the render metadata response because both were
        // queued earlier.
        controller.ingest(Array("%begin 0 97 1\r\n%end 0 97 1\r\n".utf8))
        controller.ingest(Array("%begin 0 98 1\r\nzsh\r\n%end 0 98 1\r\n".utf8))
        controller.ingest(responseFrame(8, body: [
            renderedPaneMetadataLine(
                paneId: 0,
                cursorX: 1,
                cursorY: 2,
                paneTitle: "boot title",
                windowName: "zsh",
                alternateOn: false
            )
        ]))
        XCTAssertEqual(
            String(decoding: sent.bytes, as: UTF8.self),
            "capture-pane -p -e -N -S -2000 -t @0\n"
        )
        sent.clear()

        controller.ingest(responseFrame(9, body: ["boot"]))

        XCTAssertEqual(
            fed.bytes,
            expectedRepaintBytes(captureLines: ["boot"], cursorX: 1, cursorY: 2)
        )
        XCTAssertEqual(controller.renderedPaneId, PaneId(0))
    }

    // MARK: - Reset

    func test_reset_returnsToPassthroughAndClearsState() {
        let (controller, _, _) = makeController()

        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%window-add @3\r\n".utf8))
        chunk.append(contentsOf: Array("%output %7 hi\r\n".utf8))
        controller.ingest(chunk)
        XCTAssertEqual(controller.mode, .tmuxControl)
        XCTAssertEqual(controller.activePaneId, PaneId(7))
        XCTAssertEqual(controller.windows.count, 1)

        controller.reset()
        XCTAssertEqual(controller.mode, .passthrough)
        XCTAssertNil(controller.activePaneId)
        XCTAssertTrue(controller.windows.isEmpty)
        XCTAssertNil(controller.activeWindowId)
    }

    // MARK: - M1: layout decode + per-pane model

    func test_layoutChange_decodesPanesLayoutAndZoom() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        // Split @2 into two panes (%20 active, %21 new). Verbatim 3.6a shape.
        controller.ingest(Array(
            "%layout-change @2 8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21} 8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21} *\r\n".utf8
        ))

        let window = controller.windows.first(where: { $0.id == WindowId(2) })
        XCTAssertEqual(window?.layout?.paneCount, 2)
        XCTAssertEqual(window?.layout?.paneIds, [PaneId(20), PaneId(21)])
        XCTAssertEqual(window?.panes.map(\.id), [PaneId(20), PaneId(21)])
        XCTAssertEqual(window?.isZoomed, false)
        XCTAssertEqual(window?.rendersAsPaneGrid, true)
        // The active pane (%20) is flagged active in the per-pane model.
        XCTAssertEqual(window?.panes.first(where: { $0.isActive })?.id, PaneId(20))
    }

    func test_layoutChange_zoomKeepsFullLayoutAndGridMode() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        controller.ingest(Array(
            "%layout-change @2 d67e,80x24,0,0{40x24,0,0,20,39x24,41,0,21} b25f,80x24,0,0,20 *Z\r\n".utf8
        ))

        let window = controller.windows.first(where: { $0.id == WindowId(2) })
        XCTAssertEqual(window?.isZoomed, true)
        // FULL layout stays multi-pane while zoomed → still renders as a grid.
        XCTAssertEqual(window?.layout?.paneCount, 2)
        XCTAssertEqual(window?.rendersAsPaneGrid, true)
        // visibleLayout collapses to the single zoomed leaf.
        XCTAssertEqual(window?.visibleLayout?.paneCount, 1)
        XCTAssertEqual(window?.visibleLayout?.paneIds, [PaneId(20)])
    }

    func test_layoutChange_foreignUnknownWindowIgnored() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        // @99 is not in our window list → must be dropped, no phantom tab.
        controller.ingest(Array(
            "%layout-change @99 8205,80x24,0,0{40x24,0,0,90,39x24,41,0,91} 8205,80x24,0,0{40x24,0,0,90,39x24,41,0,91} *\r\n".utf8
        ))

        XCTAssertNil(controller.windows.first(where: { $0.id == WindowId(99) }))
    }

    /// The dropped-bell bug: a BEL from a non-active pane of a background
    /// window. Before paneWindowTable, `windowInfo(forPaneId:)` returned nil
    /// for such a pane and the bell was silently dropped.
    func test_bellFromNonActiveBackgroundPane_glowsTheTab() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller)

        // @2 (background) splits: %20 active, %21 non-active.
        controller.ingest(Array(
            "%layout-change @2 8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21} 8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21} *\r\n".utf8
        ))

        var received: (windowID: Int, isActiveWindow: Bool, windowName: String?)?
        controller.onBell = { windowID, isActiveWindow, windowName in
            received = (windowID, isActiveWindow, windowName)
        }

        // BEL from the NON-active pane %21 of background window @2.
        controller.ingest(Array("%output %21 \u{07}\r\n".utf8))

        XCTAssertEqual(received?.windowID, 2, "non-active-pane bell must route to its window")
        XCTAssertEqual(received?.isActiveWindow, false)
        XCTAssertEqual(controller.bellingWindows, [2])
    }

    func test_backgroundPaneOSCTitle_doesNotClobberActiveTabLabel() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller) // @1 active (pane %10), @2 background.

        // Active pane %10 of the active window sets the tab label.
        controller.ingest(Array("%output %10 \u{1B}]2;EDITOR\u{07}\r\n".utf8))
        XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(1) })?.displayName, "EDITOR")

        // Split @1 → %10 active + %11 background.
        controller.ingest(Array(
            "%layout-change @1 8205,80x24,0,0{40x24,0,0,10,39x24,41,0,11} 8205,80x24,0,0{40x24,0,0,10,39x24,41,0,11} *\r\n".utf8
        ))

        // A background pane printing an OSC title must NOT rewrite the tab.
        controller.ingest(Array("%output %11 \u{1B}]2;BACKGROUND-JUNK\u{07}\r\n".utf8))
        XCTAssertEqual(
            controller.windows.first(where: { $0.id == WindowId(1) })?.activePaneTitle,
            "EDITOR",
            "a non-active pane's OSC title must not clobber the active tab label"
        )
        XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(1) })?.displayName, "EDITOR")
    }

    func test_backgroundPaneOSCTitle_updatesPaneTitleWithoutChangingTabLabel() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller) // @1 active (pane %10), @2 background.

        controller.ingest(Array("%output %10 \u{1B}]2;EditorTitle\u{07}\r\n".utf8))
        controller.ingest(Array(
            "%layout-change @1 8205,80x24,0,0{40x24,0,0,10,39x24,41,0,11} 8205,80x24,0,0{40x24,0,0,10,39x24,41,0,11} *\r\n".utf8
        ))

        controller.ingest(Array("%output %11 \u{1B}]2;BgTitle\u{07}\r\n".utf8))

        let window = controller.windows.first(where: { $0.id == WindowId(1) })
        XCTAssertEqual(window?.activePaneTitle, "EditorTitle")
        XCTAssertEqual(window?.panes.first(where: { $0.id == PaneId(11) })?.title, "BgTitle")
        XCTAssertEqual(window?.panes.first(where: { $0.id == PaneId(11) })?.titleIsDefault, false)
    }

    func test_activePaneOSCTitle_updatesTabLabelAndPaneTitle() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller) // @1 active (pane %10), @2 background.

        controller.ingest(Array(
            "%layout-change @1 8205,80x24,0,0{40x24,0,0,10,39x24,41,0,11} 8205,80x24,0,0{40x24,0,0,10,39x24,41,0,11} *\r\n".utf8
        ))

        controller.ingest(Array("%output %10 \u{1B}]2;ActiveTitle\u{07}\r\n".utf8))

        let window = controller.windows.first(where: { $0.id == WindowId(1) })
        XCTAssertEqual(window?.activePaneTitle, "ActiveTitle")
        XCTAssertEqual(window?.panes.first(where: { $0.id == PaneId(10) })?.title, "ActiveTitle")
        XCTAssertEqual(window?.panes.first(where: { $0.id == PaneId(10) })?.titleIsDefault, false)
    }

    func test_nonLastKill_keepsSingleActivePaneInvariant() {
        let (controller, _, _) = makeController()
        enterTmuxModeAndDrainAttachInit(controller)
        populateBellFixture(controller) // @2 background, active pane %20.

        // Split @2 → %20 active + %21.
        controller.ingest(Array(
            "%layout-change @2 8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21} 8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21} *\r\n".utf8
        ))
        XCTAssertEqual(
            controller.windows.first(where: { $0.id == WindowId(2) })?.panes.first(where: { $0.isActive })?.id,
            PaneId(20)
        )

        // Non-last kill of the active pane %20: tmux emits %layout-change
        // (still referencing the dead active pane) THEN %window-pane-changed.
        controller.ingest(Array(
            "%layout-change @2 b25d,80x24,0,0,21 b25d,80x24,0,0,21 *\r\n".utf8
        ))
        controller.ingest(Array("%window-pane-changed @2 %21\r\n".utf8))

        let window = controller.windows.first(where: { $0.id == WindowId(2) })
        XCTAssertEqual(window?.activePaneId, PaneId(21))
        XCTAssertEqual(window?.panes.count, 1)
        XCTAssertEqual(
            window?.panes.first(where: { $0.isActive })?.id,
            PaneId(21),
            "after a non-last kill the survivor must be flagged active (single-active invariant)"
        )
    }

    // MARK: - M1: widened hydration

    func test_hydration_decodesLayoutsAndAllPanes() {
        let (controller, _, _) = makeController(controlPath: .sideChannel)
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        // pause-after, bell-subscription drained.
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        // Widened list-windows: id \t layout \t visible \t zoom \t name.
        controller.ingest(Array(
            "%begin 0 4 1\r\n@5\t8205,80x24,0,0{40x24,0,0,50,39x24,41,0,51}\t8205,80x24,0,0{40x24,0,0,50,39x24,41,0,51}\t0\teditor\r\n%end 0 4 1\r\n".utf8
        ))
        // list-panes: both panes of @5.
        controller.ingest(Array(
            "%begin 0 5 1\r\n@5\t%50\t1\t\tleft title\thost\r\n@5\t%51\t0\t\tright title\thost\r\n%end 0 5 1\r\n".utf8
        ))
        // active-window @5.
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))

        let window = controller.windows.first(where: { $0.id == WindowId(5) })
        XCTAssertEqual(window?.layout?.paneCount, 2)
        XCTAssertEqual(window?.rendersAsPaneGrid, true)
        // ALL panes tracked, in DFS order, with their titles.
        XCTAssertEqual(window?.panes.map(\.id), [PaneId(50), PaneId(51)])
        XCTAssertEqual(window?.panes.map(\.title), ["left title", "right title"])
        XCTAssertEqual(window?.panes.first(where: { $0.isActive })?.id, PaneId(50))
    }

    func test_hydration_hostileWindowNameWithTabsIsPreserved() {
        let (controller, _, _) = makeController(controlPath: .sideChannel)
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        // Window name itself contains tabs — it is LAST so it can't shift the
        // fixed-grammar columns. The single-pane layout must still decode.
        controller.ingest(Array(
            "%begin 0 4 1\r\n@5\tb25d,80x24,0,0,50\tb25d,80x24,0,0,50\t0\tweird\tname\twith\ttabs\r\n%end 0 4 1\r\n".utf8
        ))
        controller.ingest(Array("%begin 0 5 1\r\n%end 0 5 1\r\n".utf8))
        controller.ingest(Array("%begin 0 6 1\r\n@5\r\n%end 0 6 1\r\n".utf8))

        let window = controller.windows.first(where: { $0.id == WindowId(5) })
        XCTAssertEqual(window?.windowName, "weird\tname\twith\ttabs")
        XCTAssertEqual(window?.layout?.paneCount, 1)
        XCTAssertEqual(window?.rendersAsPaneGrid, false)
    }
}

/// Tiny append-only byte buffer used as a test sink for feed/send
/// closures. Class so the controller's stored closures can capture
/// a mutable reference without self-mutation gymnastics.
@MainActor
private final class Accumulator<Element> {
    private(set) var bytes: [Element] = []
    private(set) var chunks: [[Element]] = []

    func append(contentsOf sequence: some Sequence<Element>) {
        let chunk = Array(sequence)
        chunks.append(chunk)
        bytes.append(contentsOf: chunk)
    }

    func clear() {
        bytes.removeAll(keepingCapacity: true)
        chunks.removeAll(keepingCapacity: true)
    }
}

/// Reference wrapper for capturing a single `Result` out of a
/// `sendControlCommand(_:completion:)` callback. Class so the
/// completion closure can mutate the `result` field after the test
/// has observed (or not yet observed) it.
@MainActor
private final class CompletionCapture<Success, Failure: Error> {
    private(set) var result: Result<Success, Failure>?

    func store(_ value: Result<Success, Failure>) {
        result = value
    }
}
