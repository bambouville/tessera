import XCTest
import SwiftTerm
import TmuxControlCore
import UIKit
@testable import TmuxControl
@testable import Tessera

/// Cell-model oracle for the deep gray/BCE scrollback regression. This feeds
/// real repaint bytes into SwiftTerm and inspects every retained history row;
/// it is deterministic, sub-second, and verifies correctness rather than the
/// old harness's "some pixels changed" proxy.
@MainActor
final class TerminalScrollbackOracleTests: XCTestCase {
    private let esc = "\u{1B}"

    func testCoreGraphicsRowCacheMatchesUncachedPixelsAcrossMutations() throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.setSessionDrawingEnabled(true)
        view.layoutIfNeeded()
        view.feed(text: "\(esc)[?25l" + (0..<200).map {
            "\(esc)[48;5;\($0 % 2 == 0 ? 22 : 52)mrow \($0) mixed ASCII ┃▌ café\(esc)[K\r\n"
        }.joined())
        func pixels() throws -> Data {
            view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: view.bounds.size).image {
                // Compare the terminal painter itself; UIKit caret/selection
                // child layers can settle between two offscreen layer captures.
                $0.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
                view.draw(view.bounds)
            }
            return try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        }
        func compare(_ label: String, mutation: () -> Void) throws {
            view.cachesCoreGraphicsRows = true
            _ = try pixels() // Populate before changing content or presentation.
            mutation()
            let cached = try pixels()
            view.cachesCoreGraphicsRows = false
            let uncached = try pixels()
            if cached != uncached {
                NSLog("[TesseraTest][RowCache] mismatch=%@ offset=%.1f colors=%d/%d", label, view.contentOffset.y, Set(cached).count, Set(uncached).count)
            }
            XCTAssertTrue(cached == uncached, "Cached pixels differ: \(label)")
            XCTAssertGreaterThan(Set(uncached).count, 8, "Oracle must contain rendered text")
        }
        try compare("fractional history") { view.contentOffset.y -= 223.5 }
        try compare("sub-row motion") { view.contentOffset.y -= 2.5 }
        try compare("reverse") { view.contentOffset.y += 41.5 }
        try compare("offscreen output") { view.feed(text: "new output\r\n") }
        try compare("palette") { view.feed(text: "\(esc)]4;22;rgb:20/60/c0\u{7}") }
        try compare("foreground") { view.nativeForegroundColor = .yellow }
        try compare("selection") { view.selectAll() }
        try compare("selection color") { view.selectedTextBackgroundColor = .magenta }
        try compare("selection cleared") { view.selectNone() }
        try compare("font") { view.font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
        try compare("alternate buffer") { view.feed(text: "\(esc)[?1049h\(esc)[2J\(esc)[Halt screen") }
        try compare("same-row overwrite") { view.feed(text: "\(esc)[H\(esc)[31mNEW screen") }
        try compare("graphemes") { view.feed(text: "\(esc)[H👩🏽‍💻 e\u{301} 漢字") }
        try compare("link payload") { view.feed(text: "\(esc)[2;1H\(esc)]8;;https://example.com\u{7}link\(esc)]8;;\u{7}") }
        try compare("link style") { view.linkHighlightMode = .always }
        try compare("synchronized snapshot") { view.feed(text: "\(esc)[?2026h\(esc)[Hpending") }
        try compare("synchronized commit") { view.feed(text: "\(esc)[?2026l") }
        try compare("primary restored") { view.feed(text: "\(esc)[?1049l") }
        try compare("history cleared") { view.feed(text: "\(esc)[2J\(esc)[3J\(esc)[Hfresh screen") }
    }

    func testTransientPreviewResizeKeepsLiveGridAndPromptIntact() {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.layoutSubviews()
        let terminal = view.getTerminal()
        let cols = terminal.cols, rows = terminal.rows
        // Independent wire fixture also keeps this oracle available to Release
        // test builds, where the interactive DEBUG harness is not compiled.
        var screen = "\(esc)[0m\(esc)[H\(esc)[2J"
        for row in (rows - 2)...rows {
            screen += "\(esc)[\(row);1H\(esc)[48;2;30;30;30m" + String(repeating: " ", count: cols)
        }
        screen += "\(esc)[\(rows - 1);1HAsk Codex to do anything\(esc)[0m"
        view.feed(text: screen)
        let before = terminal.getBufferAsData()
        view.frame.size.height -= 32
        view.layoutSubviews()
        XCTAssertEqual(terminal.rows, rows, "Transient modal geometry must not resize the emulator before the remote")
        view.feed(text: "\(esc)[?2026h\(esc)[\(rows);28H\(esc)[48;2;30;30;30m⠂\(esc)[0m\(esc)[?2026l")
        view.frame.size.height += 32
        view.layoutSubviews()
        let text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "Ask Codex to do anything").count - 1, 1, text)
        XCTAssertEqual(terminal.cols, cols)
        XCTAssertEqual(terminal.rows, rows)
        for row in (rows - 3)..<rows {
            for col in 0..<cols {
                XCTAssertEqual(terminal.getCharData(col: col, row: row)?.attribute.bg,
                    .trueColor(red: 30, green: 30, blue: 30), "Background hole at \(col),\(row)")
            }
        }
        XCTAssertEqual(terminal.getBufferAsData().filter { $0 == 10 }.count, before.filter { $0 == 10 }.count, "Transient resize must not create extra history")
    }

    func testLastingLayoutResizeCommitsAfterSettleAndCancelsSupersededSize() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.layoutSubviews()
        let terminal = view.getTerminal()
        let rows = terminal.rows
        view.frame.size.height = 540
        view.layoutSubviews()
        view.frame.size.height = 570
        view.layoutSubviews()
        XCTAssertEqual(terminal.rows, rows)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(terminal.rows, 38)
        view.frame.size.height = 510
        view.layoutSubviews()
        view.frame.size.height = 570
        view.layoutSubviews()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(terminal.rows, 38, "Canceled work must not commit a stale grid")
    }

    func testAuthoritativeResizeSupersedesPendingLayout() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.layoutSubviews()
        let box = TerminalBox(traceLabel: "preview-resize-oracle")
        box.attach(view)
        view.frame.size.height = 540
        view.layoutSubviews()
        box.resize(columns: 70, rows: 30)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.getTerminal().cols, 70)
        XCTAssertEqual(view.getTerminal().rows, 30)
    }

    func testFontChangeDuringTransientLayoutReconcilesRestoredBounds() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let view = TesseraResponderAwareTerminalView(frame: bounds)
        view.layoutSubviews()
        view.frame.size.height -= 32
        view.layoutSubviews()
        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        view.font = font
        view.frame = bounds
        view.layoutSubviews()
        try await Task.sleep(for: .milliseconds(200))
        let expected = TesseraResponderAwareTerminalView(frame: bounds)
        expected.font = font
        expected.layoutSubviews()
        XCTAssertEqual(view.getTerminal().rows, expected.getTerminal().rows)
        XCTAssertEqual(view.getTerminal().cols, expected.getTerminal().cols)
    }

    func testRepaintMustNotInterruptPendingColorSequence() {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        var filter = TerminalOutputContrastFilter()
        var framer = TmuxLiveOutputFramer()
        for (index, part) in ["\(esc)[38;2;58;58;", "\(esc)[0m\(esc)[H\(esc)[2Jprompt", "58;48;2;0;0;30mX"].enumerated() {
            let bytes = index == 1 ? Array(part.utf8) : framer.process(Array(part.utf8))
            view.feed(byteArray: filter.process(bytes[...], defaultBackgroundRGB: 0,
                defaultForegroundRGB: 0xD4D4D4, minimumContrast: 0.3))
        }
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertFalse(text.contains("58;48;2;0;0;30m"), text)
        XCTAssertTrue(text.contains("promptX"), text)
    }

    func testIdleSynchronizedRedrawPreservesPrimaryHistory() {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...200).map { "history-\($0)\r\n" }.joined())
        let bottom = view.contentOffset.y
        XCTAssertGreaterThan(bottom, 600)
        view.contentOffset.y = bottom - 400
        let readingPosition = view.contentOffset.y

        // A TUI can redraw its idle prompt without adding a history line.
        // Split at both synchronized-output boundaries, as network reads do.
        for _ in 0..<8 {
            for bytes in ["\(esc)[?2026h", "\(esc)[s\(esc)[1;1Hidle prompt\(esc)[u", "\(esc)[?2026l"] {
                view.feed(text: bytes)
                XCTAssertEqual(view.contentOffset.y, readingPosition, accuracy: 0.5)
            }
        }
    }

    func testSynchronizedOutputTimeoutPreservesHistory() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...200).map { "history-\($0)\r\n" }.joined())
        view.feed(text: "\(esc)[?2026h")
        view.contentOffset.y -= 400.5
        let readingPosition = view.contentOffset.y
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(view.contentOffset.y, readingPosition, accuracy: 0.5)
    }

    func testSynchronizedHistoryOverflowPreservesContentAndFractionalOffset() async throws {
        for timeout in [false, true] {
            let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
            let terminal = view.getTerminal()
            terminal.changeScrollback(240)
            view.feed(text: (1...400).map { "history-\($0)\r\n" }.joined())
            let retainedIndices = (0..<500).filter { terminal.getScrollInvariantLine(row: $0) != nil }
            let first = try XCTUnwrap(retainedIndices.first)
            let rowHeight = view.contentSize.height / CGFloat(retainedIndices.count)
            let coordinator = TerminalSurfaceBound.Coordinator(
                onReady: {}, onSend: { _ in }, onResize: { _, _ in }, onTitle: { _ in },
                onUserActivity: nil, onBell: nil, onPrimaryScrollbackDelta: nil,
                onPrimaryScrollbackUnderflow: nil, agentScrollBlockingActive: false,
                onAgentScrollBlocked: nil, mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true, softwareModifierState: nil,
                onHardwareKey: nil, onTerminalScrolled: nil, scrollRetentionID: "overflow-test",
                onScrollDiagnostic: nil)
            coordinator.terminalView = view
            view.terminalDelegate = coordinator
            coordinator.applyPrimaryScrollbackDelta(view: view,
                pointsY: Double((view.contentOffset.y - 20 * rowHeight - 0.5) / 3),
                isInertial: false, diagnosticPrefix: "test")
            let before = view.contentOffset.y
            let text = terminal.getScrollInvariantLine(row: first + 20)?.translateToString()
            view.feed(text: "\(esc)[?2026h")
            view.feed(text: "new1\r\nnew2\r\nnew3\r\n")
            XCTAssertEqual(view.contentOffset.y, before, accuracy: 0.01, "frozen snapshot must not move")
            if timeout { try await Task.sleep(for: .milliseconds(1200)) }
            else { view.feed(text: "\(esc)[?2026l") }
            XCTAssertEqual(view.contentOffset.y, before - 3 * rowHeight, accuracy: 0.01)
            let newFirst = try XCTUnwrap((0..<500).first { terminal.getScrollInvariantLine(row: $0) != nil })
            XCTAssertEqual(newFirst, first + 3)
            XCTAssertEqual(terminal.getScrollInvariantLine(row: newFirst + Int(view.contentOffset.y / rowHeight))?.translateToString(), text)
            // Another frame invokes the production coordinator's retained
            // offset restore. It must use the rebased anchor from frame one.
            view.feed(text: "\(esc)[?2026hnew4\r\n\(esc)[?2026l")
            XCTAssertEqual(view.contentOffset.y, before - 4 * rowHeight, accuracy: 0.01)
            XCTAssertEqual(terminal.getScrollInvariantLine(row: newFirst + 1 + Int(view.contentOffset.y / rowHeight))?.translateToString(), text)
        }
    }

    func testSynchronizedAppendAndAlternateExitFollowLiveTail() {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...200).map { "history-\($0)\r\n" }.joined())
        let oldBottom = view.contentOffset.y
        view.feed(text: "\(esc)[?2026h")
        view.feed(text: "latest line\r\n")
        view.feed(text: "\(esc)[?2026l")
        XCTAssertGreaterThan(view.contentOffset.y, oldBottom)
        let primaryBottom = view.contentOffset.y
        view.feed(text: "\(esc)[?1049h\(esc)[?2026h\(esc)[?1049l\(esc)[?2026l")
        XCTAssertEqual(view.contentOffset.y, primaryBottom, accuracy: 0.5)
    }

    func testAgentScrollGuardClaimsPageKeysOnlyWhileActive() {
        let container = TesseraTerminalContainer(frame: .zero)

        XCTAssertTrue(agentPageCommands(in: container).isEmpty)

        var blockedCount = 0
        container.onAgentScrollBlocked = { blockedCount += 1 }
        container.agentScrollBlockingActive = true

        let commands = agentPageCommands(in: container)
        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(
            Set(commands.map { $0.modifierFlags.rawValue }),
            Set([UIKeyModifierFlags().rawValue, UIKeyModifierFlags.shift.rawValue])
        )
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))
        XCTAssertTrue(
            commands.allSatisfy {
                guard let action = $0.action else { return false }
                return container.canPerformAction(action, withSender: $0)
            }
        )

        guard let first = commands.first, let action = first.action else {
            return XCTFail("agent page-key command must have an action")
        }
        XCTAssertTrue(
            UIApplication.shared.sendAction(
                action,
                to: container,
                from: first,
                for: nil
            )
        )
        XCTAssertEqual(blockedCount, 1)

        container.agentScrollBlockingActive = false
        XCTAssertTrue(agentPageCommands(in: container).isEmpty)
    }

    func testForceRedrawDrainsSwiftTermDirtyRowsThroughDisplayScheduler() async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = view.getTerminal()
        terminal.clearUpdateRange()

        let box = TerminalBox(traceLabel: "force-redraw-test")
        box.attach(view)
        box.forceRedraw()

        XCTAssertNotNil(terminal.getUpdateRange())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(
            terminal.getUpdateRange(),
            "force redraw must pass dirty rows through SwiftTerm's display scheduler"
        )
    }

    func test_repaintSeamsDoNotPlantColoredTailsInDeepScrollback() {
        for columns in [40, 73] {
            assertNoColoredTails(columns: columns, rows: 8, capturePairs: 36)
        }
    }

    private func agentPageCommands(
        in container: TesseraTerminalContainer
    ) -> [UIKeyCommand] {
        (container.keyCommands ?? []).filter {
            $0.input == UIKeyCommand.inputPageUp
                || $0.input == UIKeyCommand.inputPageDown
        }
    }

    private func assertNoColoredTails(
        columns: Int,
        rows: Int,
        capturePairs: Int
    ) {
        let delegate = NullTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: columns, rows: rows, scrollback: 512)
        )
        var capture: [String] = []
        for pair in 0..<capturePairs {
            let color = UInt8(17 + (pair % 180))
            let fullPrefix = String(format: "FULL_%03d_", pair)
            capture.append(
                "\(esc)[48;5;\(color)m"
                    + fullPrefix
                    + String(repeating: "#", count: columns - fullPrefix.count)
            )
            capture.append(String(format: "SHORT_%03d", pair))
        }

        let bytes = RepaintAssembly.assemble(
            state: makeState(),
            captureLines: capture,
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: rows
        )
        terminal.feed(byteArray: bytes)

        var checkedShortRows = 0
        for row in 0..<1_024 {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            let cells = line.getData()
            let text = String(cells.map { $0.getCharacter() })
            guard text.contains("SHORT_") else { continue }
            checkedShortRows += 1

            guard let firstContent = cells.first(where: { $0.getCharacter() != " " }) else {
                XCTFail("short row unexpectedly empty at width \(columns)")
                continue
            }
            if case .ansi256 = firstContent.attribute.bg {
                // expected: capture-pane's active background applies to text
            } else {
                XCTFail("short-row content lost its intended background at width \(columns)")
            }

            XCTAssertEqual(
                cells.last?.attribute.bg,
                .defaultColor,
                "colored BCE tail survived in deep scrollback at width \(columns), row \(row)"
            )
        }
        XCTAssertEqual(checkedShortRows, capturePairs)
    }

    private func makeState() -> TmuxController.RenderedPaneState {
        TmuxController.RenderedPaneState(
            paneId: PaneId(1),
            cursorX: 0,
            cursorY: 0,
            paneTitle: nil,
            paneTitleIsDefault: true,
            windowName: nil,
            paneInAltScreen: false,
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

    // MARK: - OSC color query responder

    func testColorQueryResponderAnswersForegroundAndBackgroundQueries() {
        let responder = TerminalOSCColorQueryResponder()
        let queries = Array("\(esc)]10;?\u{07}\(esc)]11;?\(esc)\\".utf8)

        let response = responder.responses(
            for: queries[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )

        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("]10;rgb:d4d4/d4d4/d4d4"))
        XCTAssertTrue(text.contains("]11;rgb:1010/1010/1010"))
    }

    /// Regression: curly quotes are E2 80 9C / E2 80 9D — their trailing
    /// bytes are also the C1 ST/OSC codes. Treating them as control bytes
    /// opened a phantom OSC mid-prose, buffered the rest of the chunk as a
    /// "pending query", and then re-scanned that growing buffer on every
    /// later chunk (~8ms per %output message) while swallowing real queries.
    func testColorQueryResponderIgnoresCurlyQuoteProseAndStillAnswersLaterQuery() {
        let responder = TerminalOSCColorQueryResponder()
        let prose = Array("say \u{201C}hello\u{201D} and then some trailing text".utf8)

        let proseResponse = responder.responses(
            for: prose[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(proseResponse.isEmpty)

        let query = Array("\(esc)]11;?\u{07}".utf8)
        let queryResponse = responder.responses(
            for: query[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(
            String(decoding: queryResponse, as: UTF8.self).contains("]11;rgb:1010/1010/1010")
        )
    }

    /// A query split across two chunks must still be answered — the pending
    /// carry-over exists for exactly this — while the cap keeps a pathological
    /// unterminated tail from growing without bound.
    func testColorQueryResponderReassemblesSplitQueryAcrossChunks() {
        let responder = TerminalOSCColorQueryResponder()
        let query = Array("\(esc)]11;?\u{07}".utf8)

        let first = responder.responses(
            for: query[..<3],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(first.isEmpty)

        let second = responder.responses(
            for: query[3...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(
            String(decoding: second, as: UTF8.self).contains("]11;rgb:1010/1010/1010")
        )
    }

    /// Regression: a query whose leading ESC ends a long prose chunk must
    /// survive the pending cap. Only the 1–2 control-tail bytes are carried
    /// over, so the prose length no longer counts against the cap and the
    /// query completing in the next chunk is still answered.
    func testColorQueryResponderAnswersQuerySplitAtLeadingEscapeAfterLongProse() {
        let responder = TerminalOSCColorQueryResponder()
        var first = Array(repeating: UInt8(ascii: "x"), count: 300)
        first.append(0x1B)

        let firstResponse = responder.responses(
            for: first[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(firstResponse.isEmpty)

        let second = Array("]11;?\u{07}".utf8)
        let secondResponse = responder.responses(
            for: second[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(
            String(decoding: secondResponse, as: UTF8.self).contains("]11;rgb:1010/1010/1010")
        )
    }

    /// The pending cap itself: an unterminated foreign OSC longer than the
    /// cap is dropped rather than poisoning every later chunk, and a later
    /// stand-alone query is still answered.
    func testColorQueryResponderCapsUnterminatedPendingOSC() {
        let responder = TerminalOSCColorQueryResponder()
        var junk = Array("\u{1B}]junk;".utf8)
        junk.append(contentsOf: Array(repeating: UInt8(ascii: "j"), count: 400))

        let junkResponse = responder.responses(
            for: junk[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(junkResponse.isEmpty)

        let query = Array("\u{1B}]11;?\u{07}".utf8)
        let queryResponse = responder.responses(
            for: query[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(
            String(decoding: queryResponse, as: UTF8.self).contains("]11;rgb:1010/1010/1010")
        )
    }

    // MARK: - Terminal output contrast filter

    func testContrastFilterPreservesPrintableSlices() {
        var filter = TerminalOutputContrastFilter()
        let storage = Array("prefix-printable terminal output-suffix".utf8)
        let input = storage[7..<(storage.count - 7)]

        let output = filter.process(
            input,
            defaultBackgroundRGB: 0x101010,
            defaultForegroundRGB: 0xD4D4D4,
            minimumContrast: 0.30
        )

        XCTAssertEqual(Array(output), Array(input))
    }

    func testContrastFilterDoesNotBypassPendingEscapeSequence() {
        var filter = TerminalOutputContrastFilter()
        let first = [UInt8(0x1B)]
        XCTAssertTrue(filter.process(
            first[...],
            defaultBackgroundRGB: 0x101010,
            defaultForegroundRGB: 0xD4D4D4,
            minimumContrast: 0.30
        ).isEmpty)

        let remainder = Array("[38;2;20;20;20mtext".utf8)
        let output = filter.process(
            remainder[...],
            defaultBackgroundRGB: 0x101010,
            defaultForegroundRGB: 0xD4D4D4,
            minimumContrast: 0.30
        )

        XCTAssertEqual(
            Array(output),
            Array("\u{1B}[38;2;93;93;93mtext".utf8)
        )
    }

    func testContrastFilterStillRewritesC1TruecolorSGR() {
        var filter = TerminalOutputContrastFilter()
        let input = [UInt8(0x9B)] + Array("38;2;20;20;20mtext".utf8)
        let output = filter.process(
            input[...],
            defaultBackgroundRGB: 0x101010,
            defaultForegroundRGB: 0xD4D4D4,
            minimumContrast: 0.30
        )

        XCTAssertEqual(
            Array(output),
            [UInt8(0x9B)] + Array("38;2;93;93;93mtext".utf8)
        )
    }

    /// Optimized-build audit oracle. Each sample processes 64 MiB of the
    /// common printable-only path and verifies the exact byte count.
    func testContrastFilterPrintableThroughputAudit() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_RUN_PERFORMANCE_AUDIT"] == "1" else {
            throw XCTSkip("Release performance audit is opt-in")
        }
        let bytesPerSample = 64 * 1_024 * 1_024
        for chunkSize in [128, 1_024, 8_192] {
            let chunk = Array(repeating: UInt8(ascii: "x"), count: chunkSize)
            let iterations = bytesPerSample / chunkSize
            var samples: [Double] = []

            for _ in 0..<5 {
                var filter = TerminalOutputContrastFilter()
                var processed = 0
                let start = CACurrentMediaTime()
                for _ in 0..<iterations {
                    processed += filter.process(
                        chunk[...],
                        defaultBackgroundRGB: 0x101010,
                        defaultForegroundRGB: 0xD4D4D4,
                        minimumContrast: 0.30
                    ).count
                }
                samples.append((CACurrentMediaTime() - start) * 1_000)
                XCTAssertEqual(processed, bytesPerSample)
            }

            samples.sort()
            let sampleText = samples
                .map { String(format: "%.3f", $0) }
                .joined(separator: ",")
            NSLog(
                "contrast-filter chunk=\(chunkSize) bytes=\(bytesPerSample) "
                    + "medianMs=\(samples[2]) maxMs=\(samples[4]) "
                    + "samplesMs=\(sampleText)"
            )
        }
    }
}

private final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
