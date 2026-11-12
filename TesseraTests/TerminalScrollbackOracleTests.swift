import XCTest
import SwiftTerm
import SwiftUI
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

    /// Plain mosh keeps full-screen programs on the primary screen. A frame a
    /// part row taller than its grid rests on the live tail with that part
    /// row above the grid, where the newest history row showed over htop.
    /// Off the tail, even by a point, the row slides in with the finger. A
    /// frame whole rows taller, which its grid has yet to refit to, shows
    /// history there rather than blank rows, from exactly one row on. The
    /// program's first row stays the grid's first row throughout.
    func testLiveTailDrawsNoHistoryAboveTheGrid() throws {
        for rowsAboveGrid in [0.97, 0.3, 1, 1.5, 2.5] as [CGFloat] {
            try checkRowsAboveGrid(rowsAboveGrid)
        }
    }

    private func checkRowsAboveGrid(_ rowsAboveGrid: CGFloat) throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.setSessionDrawingEnabled(true)
        view.layoutIfNeeded()
        let terminal = view.getTerminal()
        let grid = view.getOptimalFrameSize()
        let cell = grid.height / CGFloat(terminal.rows)
        let rows = terminal.rows
        view.frame.size.height = grid.height + rowsAboveGrid * cell
        view.layoutIfNeeded()
        XCTAssertEqual(terminal.rows, rows, "The grid refits only once the layout settles")
        view.feed(text: "\(esc)[?25l" + (0..<100).map {
            "\(esc)[48;2;255;0;0mhistory \($0)\(esc)[K\(esc)[0m\r\n"
        }.joined())
        // A full-screen program on the primary screen: clear, then a green
        // header on its first row and its body below.
        view.feed(text: "\(esc)[2J\(esc)[H\(esc)[48;2;0;255;0mheader\(esc)[K"
            + "\(esc)[2;1H\(esc)[48;2;0;0;255mprogram\(esc)[K\(esc)[0m")
        func clamp() { view.contentOffset.y = view.contentSize.height - view.bounds.height }
        /// Red (history) pixels above the grid, and green (the program's
        /// header) pixels on the grid's first row and anywhere else.
        func pixelCounts() throws -> (redAboveGrid: Int, headerOnFirstRow: Int, headerElsewhere: Int) {
            view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image {
                $0.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
                view.draw(view.bounds)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let width = cgImage.width, height = cgImage.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            // The grid starts where the bounds' clamp leaves the part row.
            let gridTop = view.contentSize.height - grid.height - view.bounds.minY
            var red = 0, onFirstRow = 0, elsewhere = 0
            for y in 0..<height {
                let aboveGrid = CGFloat(y + 1) <= gridTop
                let firstRow = CGFloat(y) >= gridTop && CGFloat(y + 1) <= gridTop + cell
                let firstRowEdge = !aboveGrid && !firstRow && CGFloat(y) < gridTop + cell
                for x in 0..<width {
                    let pixel = (y * width + x) * 4
                    let r = bytes[pixel], g = bytes[pixel + 1], b = bytes[pixel + 2]
                    if aboveGrid && r > 200 && g < 60 && b < 60 { red += 1 }
                    if g > 200 && r < 60 && b < 60 {
                        if firstRow { onFirstRow += 1 } else if !firstRowEdge { elsewhere += 1 }
                    }
                }
            }
            return (red, onFirstRow, elsewhere)
        }
        func redPixelsAboveGrid() throws -> Int { try pixelCounts().redAboveGrid }

        let label = "\(rowsAboveGrid) rows above the grid"
        func checkTail() throws {
            let counts = try pixelCounts()
            if rowsAboveGrid < 1 {
                XCTAssertEqual(counts.redAboveGrid, 0, "The live tail drew a history row above the grid: \(label)")
            } else {
                XCTAssertGreaterThan(counts.redAboveGrid, 0, "A frame the grid has yet to fill showed blank rows: \(label)")
            }
            XCTAssertGreaterThan(counts.headerOnFirstRow, Int(grid.width), "The grid's first row went undrawn: \(label)")
            XCTAssertEqual(counts.headerElsewhere, 0, "The program's first row left the grid's first row: \(label)")
        }
        clamp()
        XCTAssertGreaterThan(view.contentSize.height - grid.height - view.bounds.minY, rowsAboveGrid * cell - 1,
                             "The oracle needs the rows above the grid: \(label)")
        try checkTail()
        view.contentOffset.y -= 1
        XCTAssertGreaterThan(try redPixelsAboveGrid(), 0, "A finger a point off the tail must see the row above the grid: \(label)")
        view.contentOffset.y -= cell
        XCTAssertGreaterThan(try redPixelsAboveGrid(), 0, "A reader in history must see the row above the grid: \(label)")
        clamp()
        try checkTail()
        if rowsAboveGrid > 0.5 && rowsAboveGrid < 1 {
            // A frame that shrinks by part of that part row keeps its grid,
            // and the reader resting on the live tail stays on it.
            view.frame.size.height -= 0.5 * cell
            view.layoutIfNeeded()
            XCTAssertEqual(terminal.rows, rows, "The grid still fits: \(label)")
            try checkTail()
        }
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

    /// VoiceOver's page scroll moved contentOffset behind every reader hook:
    /// output snapped a held reader back to the tail, and rebuilds saw one at
    /// the bottom. Mounted, it takes the trackpad's primary-history path.
    func testAccessibilityPageScrollHoldsTheReaderLikeATrackpad() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe)
        defer { close() }
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        let row = cellHeight(of: view)
        // SwiftTerm parks whole rows at the tail; the slack is under a row.
        let bottom = view.contentOffset.y
        XCTAssertGreaterThan(bottom, 3 * view.bounds.height)
        XCTAssertEqual(bottom, view.contentSize.height - view.bounds.height, accuracy: row)
        let scrolledByOutput = probe.scrolled

        XCTAssertTrue(view.accessibilityScroll(.up))
        let page = bottom - view.contentOffset.y
        XCTAssertEqual(page, CGFloat(view.getTerminal().rows - 1) * row, accuracy: 1, "a page less a row")
        XCTAssertTrue(view.accessibilityScroll(.up))
        let held = view.contentOffset.y
        XCTAssertEqual(bottom - held, 2 * page, accuracy: 1)
        XCTAssertEqual(probe.readerInputs, 2)
        XCTAssertEqual(probe.scrolled - scrolledByOutput, 2, "each page reports its committed position")

        view.feed(text: "new-1\r\nnew-2\r\nnew-3\r\n")
        // Let deferred display and restore passes run before judging.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(view.contentOffset.y, held, accuracy: 0.5, "output must not snap a held reader to the tail")

        // The oldest row is an edge: the page reports it rather than moving.
        var pages = 0
        while view.accessibilityScroll(.up), pages < 100 { pages += 1 }
        XCTAssertLessThan(pages, 100)
        XCTAssertEqual(view.contentOffset.y, 0, accuracy: 0.5)
        while view.accessibilityScroll(.down), pages < 200 { pages += 1 }
        XCTAssertEqual(view.contentOffset.y, max(0, view.contentSize.height - view.bounds.height), accuracy: 0.5)
    }

    /// A full-screen program has no local history: a page went nowhere
    /// there. It pages the program with its Page Up and Page Down keys,
    /// the mouse on or off, and leaves the scroller alone.
    func testAccessibilityPageInAFullScreenProgramSendsItsPageKeys() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe)
        defer { close() }
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined() + "\(esc)[?1049h")
        let offset = view.contentOffset.y
        let pageUp: [UInt8] = [0x1B, 0x5B, 0x35, 0x7E], pageDown: [UInt8] = [0x1B, 0x5B, 0x36, 0x7E]
        probe.sent = []
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertEqual(probe.sent, pageUp)
        XCTAssertTrue(view.accessibilityScroll(.down))
        XCTAssertEqual(probe.sent, pageUp + pageDown)
        XCTAssertEqual(probe.readerInputs, 2)

        view.feed(text: "\(esc)[?1000h\(esc)[?1006h")
        probe.sent = []
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertEqual(probe.sent, pageUp, "a program with the mouse on still takes the key, not a wheel")
        XCTAssertEqual(view.contentOffset.y, offset, accuracy: 0.5)

        view.feed(text: "\(esc)[?1000l\(esc)[?1006l\(esc)[?1049l")
        probe.sent = []
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertEqual(probe.sent, [], "back on the shell, a page moves history")
    }

    /// A VoiceOver page key is typing: a session refusing keys, or the agent
    /// scroll block, sends none and VoiceOver hears the edge; a mosh+tmux
    /// pane's full-screen program takes it though the canvas shows the
    /// primary screen; a reader mosh's mouse mode left in history goes back
    /// to the live screen with it; and pages in a row never repeat a status.
    func testAccessibilityPageKeysFollowTheSessionsInputRules() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe)
        defer { close() }
        let coordinator = try XCTUnwrap(view.terminalDelegate as? TerminalSurfaceBound.Coordinator)
        let pageUp: [UInt8] = [0x1B, 0x5B, 0x35, 0x7E]
        func onTheTail() -> Bool { view.contentOffset.y >= view.contentSize.height - view.bounds.height - 1 }
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined() + "\(esc)[?1049h")
        probe.sent = []

        coordinator.refusesInput = true
        XCTAssertFalse(view.accessibilityScroll(.up), "a refused key is no page")
        XCTAssertEqual(probe.sent, [])
        coordinator.refusesInput = false

        coordinator.setAgentScrollBlockingActive(true)
        XCTAssertFalse(view.accessibilityScroll(.up), "the agent scroll block holds the key")
        XCTAssertEqual(probe.sent, [])
        coordinator.setAgentScrollBlockingActive(false)
        // A split's canvas holds history per pane, so its own block is off;
        // the focused pane's still holds the key.
        coordinator.agentPageKeysBlocked = true
        XCTAssertFalse(view.accessibilityScroll(.up), "the focused pane's agent block holds the key")
        XCTAssertEqual(probe.sent, [])
        coordinator.agentPageKeysBlocked = false
        // UIKit's input mirror holds what the view typed; the key is sent
        // past it, so later edits must not be measured against that line.
        view.insertText("a")
        view.insertText(" ")
        func mirror() -> String {
            view.textRange(from: view.beginningOfDocument, to: view.endOfDocument).flatMap { view.text(in: $0) } ?? ""
        }
        XCTAssertEqual(mirror(), "a ", "precondition: the mirror holds the typed line")
        probe.sent = []
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertEqual(probe.sent, pageUp)
        XCTAssertEqual(mirror(), "", "the key leaves the mirror behind")

        view.feed(text: "\(esc)[?1049l")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let offset = view.contentOffset.y
        coordinator.paneTakesPageKeys = { _ in true }
        probe.sent = []
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertEqual(probe.sent, pageUp, "the pane's program takes the page as its key")
        XCTAssertEqual(view.contentOffset.y, offset, accuracy: 0.5, "the canvas's history stays put")
        coordinator.paneTakesPageKeys = nil

        // Plain mosh: mouse reporting stands in for the alternate screen.
        coordinator.mouseReportingImpliesAltScreen = true
        view.feed(text: "\(esc)[?1000h")
        view.contentOffset.y -= 50 * cellHeight(of: view)
        XCTAssertFalse(onTheTail())
        probe.sent = []
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertEqual(probe.sent, pageUp)
        XCTAssertTrue(onTheTail(), "the key takes the reader to the live screen")

        _ = TerminalSurfaceBound.Coordinator.pageKeyAnnouncement(.pageDown)
        let up = TerminalSurfaceBound.Coordinator.pageKeyAnnouncement(.pageUp)
        let again = TerminalSurfaceBound.Coordinator.pageKeyAnnouncement(.pageUp)
        let down = TerminalSurfaceBound.Coordinator.pageKeyAnnouncement(.pageDown)
        XCTAssertEqual(again, "\(up) 2", "a second page up in a row says so")
        XCTAssertNotEqual(down, again)
        XCTAssertEqual(TerminalSurfaceBound.Coordinator.pageKeyAnnouncement(.pageUp), up, "a turn starts over")

        let now = ProcessInfo.processInfo.systemUptime
        let pause = TerminalSurfaceBound.Coordinator.pageKeyCountPause
        func announce(_ at: TimeInterval) -> String {
            TerminalSurfaceBound.Coordinator.pageKeyAnnouncement(.pageUp, now: at)
        }
        XCTAssertEqual(announce(now + 1), "\(up) 2")
        XCTAssertEqual(announce(now + 2), "\(up) 3")
        XCTAssertEqual(announce(now + 3 + pause), up, "a page after a pause starts over")
        XCTAssertEqual(announce(now + 4 + 2 * pause), "\(up) 2", "but never on the status VoiceOver heard last")
        XCTAssertEqual(announce(now + 5 + 2 * pause), "\(up) 3")
    }

    /// The keyboard's page keys stop at the focused pane's agent block too,
    /// which a split's canvas sets without its own: a finger still scrolls
    /// the canvas.
    func testTheFocusedPanesAgentBlockTakesTheKeyboardsPageKeys() throws {
        for blocked in [false, true] {
            let probe = AccessibilityScrollProbe()
            let (view, close) = try mountAccessibilityScrollSurface(probe, agentPageKeysBlocked: blocked)
            defer { close() }
            let container = try XCTUnwrap(view.superview as? TesseraTerminalContainer)
            let blocksPageUp = container.keyCommands?.contains {
                $0.input == UIKeyCommand.inputPageUp && $0.action == NSSelectorFromString("agentScrollPageKeyBlocked")
            } == true
            XCTAssertEqual(blocksPageUp, blocked)
            XCTAssertFalse(view.agentScrollBlockingActive, "the canvas's own pan is not blocked")
            // VoiceOver's page key in a full-screen program stops there too.
            view.feed(text: "\(esc)[?1049h")
            probe.sent = []
            XCTAssertEqual(view.accessibilityScroll(.up), !blocked)
            XCTAssertEqual(probe.sent, blocked ? [] : [0x1B, 0x5B, 0x35, 0x7E])
        }
    }

    /// A trackpad or VoiceOver page holds a reader through output anywhere
    /// above the bounds' clamp, even less than a row above the grid's tail:
    /// a new font keeps them on their line, and the place held for output
    /// follows them there.
    func testAFontChangeKeepsAHeldReaderLessThanARowAboveTheGridsTail() throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined() + "PROMPT$ ")
        let coordinator = TerminalSurfaceBound.Coordinator(
            onReady: {}, onSend: { _ in }, onResize: { _, _ in }, onTitle: { _ in },
            onUserActivity: nil, onBell: nil, onPrimaryScrollbackDelta: nil,
            onPrimaryScrollbackUnderflow: nil, agentScrollBlockingActive: false,
            onAgentScrollBlocked: nil, mouseReportingImpliesAltScreen: false,
            suppressDirectColorQueryResponses: true, softwareModifierState: nil,
            onHardwareKey: nil, onTerminalScrolled: nil, scrollRetentionID: "held-gap-test",
            onScrollDiagnostic: nil)
        coordinator.terminalView = view
        view.terminalDelegate = coordinator
        view.onReaderReplaced = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.followReaderReplacement(in: view)
        }
        view.holdsReader = { [weak coordinator] in coordinator?.holdsReader ?? false }
        let cell = cellHeight(of: view)
        func settle() {
            view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(TerminalResizeCoalescer.settleSeconds + 0.2))
        }
        func clamp() -> CGFloat { view.contentSize.height - view.bounds.height }
        view.frame.size.height = (CGFloat(view.getTerminal().rows) + 0.2) * cell
        settle()
        let rows = view.getTerminal().rows
        view.contentOffset.y = clamp()
        // One wheel notch: 9 points, less than a row above the grid's tail.
        coordinator.applyPrimaryScrollbackDelta(view: view, pointsY: 3, isInertial: false, diagnosticPrefix: "test")
        XCTAssertTrue(coordinator.holdsReader)
        let gridTail = view.contentSize.height - CGFloat(rows) * cell
        XCTAssertGreaterThan(view.contentOffset.y, gridTail - cell, "precondition: less than a row above the grid's tail")
        let held = try XCTUnwrap(topTranscriptRow(of: view))

        view.setFontKeepingReader(view.font.withSize(view.font.pointSize + 4))
        settle()
        XCTAssertLessThan(view.getTerminal().rows, rows, "the bigger font must refit the grid")
        XCTAssertEqual(topTranscriptRow(of: view), held, "a new font keeps the held reader's line")
        view.feed(text: "after-1\r\nafter-2\r\n")
        XCTAssertEqual(topTranscriptRow(of: view), held, "output returns them to the place that followed them")
    }

    /// A finger takes the reader from the place a trackpad or VoiceOver page
    /// held, which the next output pulled them back to: output leaves them
    /// where the finger did.
    func testAFingerPanLetsGoOfTheHeldPlace() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe)
        defer { close() }
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        for _ in 0..<3 { XCTAssertTrue(view.accessibilityScroll(.up)) }
        let held = view.contentOffset.y
        let coordinator = try XCTUnwrap(view.terminalDelegate as? TerminalSurfaceBound.Coordinator)
        coordinator.handleNativeTouchPan(BeganPan())
        let dragged = held - 50 * cellHeight(of: view)
        view.contentOffset.y = dragged
        view.feed(text: "new-1\r\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(view.contentOffset.y, dragged, accuracy: 0.5,
                       "output after a finger pan must leave the reader where the finger did")
    }

    /// Only a synchronized frame (DEC 2026) kept a reader whom a finger put
    /// in history; any other output that scrolled a line parked them at the
    /// live tail. They stay on their rows now, as on Android, through rows
    /// the scrollback limit trims above them; a reader on the tail follows
    /// output, and typing takes a reader back to it.
    func testOutputKeepsAFingerReaderOnTheirRows() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe)
        defer { close() }
        let cell = cellHeight(of: view)
        func onTheTail() -> Bool { view.contentOffset.y >= view.contentSize.height - view.bounds.height - 1 }
        func output(_ text: String) {
            view.feed(text: text)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        view.getTerminal().changeScrollback(400)
        output((1...300).map { "history-\($0)\r\n" }.joined())
        view.contentOffset.y -= 100 * cell
        let read = try XCTUnwrap(topTranscriptRow(of: view))
        let offset = view.contentOffset.y
        output((1...20).map { "plain-\($0)\r\n" }.joined())
        XCTAssertEqual(topTranscriptRow(of: view), read, "plain output must leave the reader on their rows")
        XCTAssertEqual(view.contentOffset.y, offset, accuracy: 0.5)

        // Past the scrollback limit, each line trims one from above them.
        output((1...200).map { "over-\($0)\r\n" }.joined())
        XCTAssertEqual(topTranscriptRow(of: view), read, "trimmed rows must not move the reader's rows")
        XCTAssertLessThan(view.contentOffset.y, offset - 50 * cell, "the place moves up with the rows")
        XCTAssertFalse(onTheTail())

        let coordinator = try XCTUnwrap(view.terminalDelegate as? TerminalSurfaceBound.Coordinator)
        coordinator.send(source: view, data: ArraySlice("x".utf8))
        XCTAssertTrue(onTheTail(), "typing takes the reader to the live prompt")
        output((1...20).map { "after-\($0)\r\n" }.joined())
        XCTAssertTrue(onTheTail(), "a reader on the tail follows output")

        // An accessory-bar key, a swipe-pad macro or a custom shortcut is
        // sent past the view, and takes the reader back the same way.
        view.contentOffset.y -= 100 * cell
        output("held-1\r\n")
        XCTAssertFalse(onTheTail())
        let box = TerminalBox(traceLabel: "oracle-out-of-band")
        box.attach(view)
        box.noteOutOfBandTyping()
        XCTAssertTrue(onTheTail(), "typing sent past the view takes the reader to the live prompt")
        output((1...20).map { "later-\($0)\r\n" }.joined())
        XCTAssertTrue(onTheTail())

        // A typed path drops the mirror at once and takes the reader only
        // once the session has it; an undelivered one leaves them reading.
        for delivery: AppleSessionCommandFacade.InputDelivery in [.refused, .dropped, .sent] {
            view.insertText("a")
            view.contentOffset.y = view.contentSize.height - view.bounds.height - 100 * cell
            output("held-\(delivery)\r\n")
            XCTAssertFalse(onTheTail(), "precondition: reading history")
            var sent = 0
            var undelivered: [Bool] = []
            let completion = SessionDuoInput.typePath(
                into: [box], onSent: { sent += 1 }, onUndelivered: { undelivered.append($0) }
            )
            XCTAssertEqual(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)
                .flatMap { view.text(in: $0) }, "", "the mirror goes before the path is sent")
            XCTAssertFalse(onTheTail(), "the reader waits for the session")
            completion(delivery)
            XCTAssertEqual(onTheTail(), delivery == .sent, "\(delivery)")
            XCTAssertEqual(sent, delivery == .sent ? 1 : 0)
            XCTAssertEqual(undelivered, delivery == .sent ? [] : [delivery == .refused])
        }
    }

    /// A finger pan as the coordinator's target sees it starting.
    private final class BeganPan: UIPanGestureRecognizer {
        override var state: UIGestureRecognizer.State {
            get { .began }
            set {}
        }
    }

    /// A split's pane on a shared mosh canvas is shorter than the surface:
    /// a page moves that pane's rows, so no history is skipped.
    func testAccessibilityPageFollowsTheHostsPaneHeight() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe, pageRows: 10)
        defer { close() }
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        let row = cellHeight(of: view)
        let bottom = view.contentOffset.y
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertEqual(bottom - view.contentOffset.y, 9 * row, accuracy: 1)
    }

    /// The split's history overlay scrolls natively; UIKit's own page left
    /// its host treating the move as output (snapping back, never dismissing
    /// at the tail). It now reports a settled reader move.
    func testAccessibilityPageOnANativeSurfaceReportsAReaderMove() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe, native: true)
        defer { close() }
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        let row = cellHeight(of: view)
        let bottom = view.contentOffset.y
        XCTAssertTrue(view.accessibilityScroll(.up))
        XCTAssertEqual(bottom - view.contentOffset.y, CGFloat(view.getTerminal().rows - 1) * row, accuracy: 1)
        XCTAssertEqual(probe.readerMoves, [view.contentOffset.y])
        XCTAssertEqual(probe.readerInputs, 1)

        view.contentOffset.y = 0
        XCTAssertFalse(view.accessibilityScroll(.up), "the top is an edge")
        XCTAssertEqual(probe.readerMoves.count, 2, "the top still asks the host for older rows")
    }

    /// SwiftTerm parks the scroller at the live tail after every grid change,
    /// so a font change dropped a reader in history at the tail before a tmux
    /// rebuild could record their place, and the rebuild put them back there
    /// (Duo retest M5 item 1). The reader keeps their row, through output too.
    func testAFontChangeKeepsTheReaderOnTheirRow() throws {
        let key = "tessera.pref.fontSize"
        let savedFontSize = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(savedFontSize, forKey: key) }
        let appearance = AppearancePreferences()
        appearance.fontSize = 13
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe, appearance: appearance)
        defer { close() }
        let terminal = view.getTerminal()
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        func topRow() -> String? { topTranscriptRow(of: view) }
        for _ in 0..<3 { XCTAssertTrue(view.accessibilityScroll(.up)) }
        let held = try XCTUnwrap(topRow())
        XCTAssertLessThan(view.contentOffset.y, view.contentSize.height - view.bounds.height - view.bounds.height,
                          "the reader must be in history")

        for size in [17.0, 11.0] {
            let grid = (terminal.cols, terminal.rows)
            appearance.fontSize = size
            let deadline = Date().addingTimeInterval(3)
            while terminal.cols == grid.0, terminal.rows == grid.1, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertNotEqual(terminal.rows, grid.1, "\(size) pt must refit the grid")
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(topRow(), held, "\(size) pt keeps the reader's row")
            view.feed(text: "new-\(size)\r\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(topRow(), held, "output after \(size) pt holds the reader")
        }
    }

    /// A family with the same cell width and a different row height can leave
    /// the grid as it was. SwiftTerm keeps the reader's row in the new font's
    /// offsets and no grid change follows to re-place them, so the host's
    /// retained offset must follow the font itself, or the next output puts
    /// the reader back at the old font's offset.
    func testAFontChangeThatKeepsTheGridHoldsTheReaderThroughOutput() throws {
        let keys = ["tessera.pref.fontSize", "tessera.pref.terminalFontID"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let scale = TesseraResponderAwareTerminalView(frame: .zero).contentScaleFactor
        func cell(_ id: String) -> CGSize {
            // SwiftTerm's own cell metrics (`computeFontDimensions`).
            let font = TerminalFontResolver.uiFont(id: id, size: 13)
            let ct = font as CTFont
            let height = ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct))
            let width = "W".size(withAttributes: [.font: font]).width
            return CGSize(width: ceil(width * scale) / scale, height: ceil(height * scale) / scale)
        }
        let cells: [(id: String, size: CGSize)] = TerminalFontCatalog.all.map { ($0.id, cell($0.id)) }
        var pair: (from: String, to: String, short: CGSize, tall: CGSize)?
        for a in cells {
            for b in cells where a.size.width == b.size.width && a.size.height < b.size.height {
                let gap = b.size.height - a.size.height
                if let pair, pair.tall.height - pair.short.height <= gap { continue }
                pair = (a.id, b.id, a.size, b.size)
            }
        }
        let (from, to, short, tall) = try XCTUnwrap(pair, "two catalog families must share a cell width")
        // The most rows both heights fill alike: rows × tall < (rows + 1) × short.
        let rows = min(12, Int(((short.height / (tall.height - short.height)) - 0.01).rounded(.down)))
        XCTAssertGreaterThanOrEqual(rows, 5, "\(from) and \(to) differ too much in height")
        let height = (CGFloat(rows) * tall.height + CGFloat(rows + 1) * short.height) / 2
        let appearance = AppearancePreferences()
        appearance.fontSize = 13
        appearance.terminalFontID = from
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe, appearance: appearance,
                                                                size: CGSize(width: 900, height: height))
        defer { close() }
        let terminal = view.getTerminal()
        XCTAssertEqual(terminal.rows, rows, "\(from) fills \(rows) rows of \(view.bounds.height) pt")
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        for _ in 0..<3 { XCTAssertTrue(view.accessibilityScroll(.up)) }
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        let grid = (terminal.cols, terminal.rows)

        appearance.terminalFontID = to
        let deadline = Date().addingTimeInterval(3)
        while cellHeight(of: view) != tall.height, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(cellHeight(of: view), tall.height, "\(to) must be applied")
        let kept = terminal.cols == grid.0 && terminal.rows == grid.1
        XCTAssertTrue(kept, "\(to) must keep the \(grid.0)x\(grid.1) grid")
        XCTAssertEqual(topTranscriptRow(of: view), held, "the font change keeps the reader's row")
        view.feed(text: "new-1\r\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(topTranscriptRow(of: view), held, "output after the font change holds the reader")
    }

    /// The same for a grid the host sets outright (`TerminalBox.resize`),
    /// which SwiftTerm parks at the tail a turn later, and the host's
    /// retained offset follows.
    func testAnExplicitGridChangeKeepsTheReaderOnTheirRow() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe)
        defer { close() }
        let box = TerminalBox(traceLabel: "explicit-grid")
        box.attach(view)
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        for _ in 0..<3 { XCTAssertTrue(view.accessibilityScroll(.up)) }
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        box.resize(columns: 60, rows: 20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(view.getTerminal().rows, 20)
        XCTAssertEqual(topTranscriptRow(of: view), held)
        XCTAssertEqual(probe.replacements.last, view.contentOffset.y, "the host must hear where the reader went")
    }

    /// SwiftTerm parks the scroller even for the grid it already has.
    func testAnExplicitResizeToTheSameGridKeepsTheReaderOnTheirRow() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        view.contentOffset.y -= 40 * cellHeight(of: view)
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        view.resizeKeepingReader(cols: view.getTerminal().cols, rows: view.getTerminal().rows)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(topTranscriptRow(of: view), held)
    }

    /// A shorter grid over a full scrollback trims as many rows from its top
    /// as it pushes in below, and SwiftTerm doesn't count those in the rows
    /// it numbers: the reader's row is found from the cursor's.
    func testAShorterGridOverAFullScrollbackKeepsTheReaderOnTheirRow() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.changeScrollback(500)
        view.feed(text: (1...1_000).map { "history-\($0)\r\n" }.joined())
        view.contentOffset.y -= 100 * cellHeight(of: view)
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        let rows = view.getTerminal().rows
        view.resizeKeepingReader(cols: view.getTerminal().cols, rows: rows - 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.getTerminal().rows, rows - 5)
        XCTAssertEqual(topTranscriptRow(of: view), held)
    }

    /// A shorter grid drops the blank rows below the cursor, so the end of
    /// the transcript comes up toward the reader: their row is found again
    /// from the cursor's, not from the end.
    func testAShorterGridUnderAClearedScreenKeepsTheReaderOnTheirRow() async throws {
        let (view, held, rows) = try readerAboveAClearedScreen()
        view.resizeKeepingReader(cols: view.getTerminal().cols, rows: rows - 10)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.getTerminal().rows, rows - 10)
        XCTAssertEqual(topTranscriptRow(of: view), held)
    }

    /// The second of two grids in one turn is set before SwiftTerm's park
    /// for the first, while the scroller still holds the first's rows.
    func testTwoGridsInOneTurnKeepTheReaderOnTheirRow() async throws {
        let (view, held, rows) = try readerAboveAClearedScreen()
        view.resizeKeepingReader(cols: view.getTerminal().cols, rows: rows - 10)
        view.resizeKeepingReader(cols: view.getTerminal().cols, rows: rows - 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.getTerminal().rows, rows - 5)
        XCTAssertEqual(topTranscriptRow(of: view), held)
    }

    /// A reader in history above a cleared screen: blank rows below the cursor.
    private func readerAboveAClearedScreen() throws -> (TesseraResponderAwareTerminalView, String, Int) {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        view.feed(text: "\(esc)[2J\(esc)[Hprompt$ ")
        let rows = view.getTerminal().rows
        XCTAssertGreaterThan(rows, 20)
        view.contentOffset.y -= CGFloat(rows + 40) * cellHeight(of: view)
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        XCTAssertTrue(held.hasPrefix("history-"), held)
        return (view, held, rows)
    }

    /// A refit the host answers with its own resize: SwiftTerm queues a
    /// second park while the scroller still holds the old rows, where the
    /// reader can't be measured.
    func testARefitTheHostAnswersKeepsTheReaderOnTheirRow() throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let host = ResizeEchoingHost()
        view.terminalDelegate = host
        view.layoutIfNeeded()
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        view.feed(text: "\(esc)[2J\(esc)[Hprompt$ ")
        let rows = view.getTerminal().rows
        let cell = cellHeight(of: view)
        view.contentOffset.y -= CGFloat(rows + 40) * cell
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        view.frame.size.height -= 10 * cell
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(TerminalResizeCoalescer.settleSeconds + 0.2))
        XCTAssertEqual(view.getTerminal().rows, rows - 10)
        XCTAssertEqual(host.echoes, 1, "the host never answered the refit")
        XCTAssertEqual(topTranscriptRow(of: view), held)
    }

    private final class ResizeEchoingHost: NSObject, TerminalViewDelegate {
        var echoes = 0
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard echoes == 0, let view = source as? TesseraResponderAwareTerminalView else { return }
            echoes += 1
            MainActor.assumeIsolated { view.resizeKeepingReader(cols: newCols, rows: newRows) }
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// A narrower grid rewraps long rows, so the reader's offset moves with
    /// their row; the host's retained offset must follow it, or the next
    /// output puts them back at the old grid's offset.
    func testOutputAfterARewrapHoldsTheReader() async throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe)
        defer { close() }
        let pad = String(repeating: ".", count: 90)
        view.feed(text: (1...300).map { "history-\($0)\(pad)\r\n" }.joined())
        for _ in 0..<3 { XCTAssertTrue(view.accessibilityScroll(.up)) }
        let before = view.contentSize.height
        view.resizeKeepingReader(cols: 50, rows: 20)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(view.contentSize.height, 1.5 * before, "the rows must rewrap")
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        let offset = view.contentOffset.y
        XCTAssertLessThan(offset, view.contentSize.height - 2 * view.bounds.height, "the reader must stay in history")
        view.feed(text: "new-1\r\n")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.contentOffset.y, offset, accuracy: 0.5, "output must not move the reader")
        XCTAssertEqual(topTranscriptRow(of: view), held)
    }

    /// A narrower grid rewraps the lines between the reader and the cursor
    /// and a wider one joins them again: the reader keeps their line, not a
    /// count of rows, from its first row or from a row partway down it.
    func testARewrapKeepsTheReaderOnTheirLine() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let pad = String(repeating: ".", count: 90)
        view.feed(text: (1...300).map { "history-\($0)\(pad)\r\n" }.joined())
        let grid = (cols: view.getTerminal().cols, rows: view.getTerminal().rows)
        XCTAssertGreaterThan(grid.cols, 101, "every line must fit one row before the rewrap")
        view.contentOffset.y -= 100 * cellHeight(of: view)
        func line() -> Substring? { topTranscriptRow(of: view)?.prefix { $0 != "." } }
        let held = try XCTUnwrap(line())
        XCTAssertTrue(held.hasPrefix("history-"), String(held))

        view.resizeKeepingReader(cols: 50, rows: grid.rows)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(line(), held, "a narrower grid keeps the reader's line")
        view.contentOffset.y += cellHeight(of: view)
        XCTAssertEqual(topTranscriptRow(of: view)?.first, ".", "the reader is partway down their line")

        view.resizeKeepingReader(cols: grid.cols, rows: grid.rows)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(line(), held, "a wider grid keeps the reader's line")
    }

    /// Output between an explicit grid change and SwiftTerm's park moves the
    /// cursor the reader is kept from: their row is found before it does.
    func testOutputBeforeTheParkKeepsTheReaderOnTheirRow() async throws {
        let (view, held, rows) = try readerAboveAClearedScreen()
        view.resizeKeepingReader(cols: view.getTerminal().cols, rows: rows - 10)
        view.feed(text: (1...5).map { "out-\($0)\r\n" }.joined())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(topTranscriptRow(of: view), held)
    }

    /// A synchronized-output frame shows the scroller the rows from before
    /// it while the live buffer, and its cursor, move on. A refit in the
    /// middle of one still keeps the reader's row.
    func testARefitInsideASynchronizedFrameKeepsTheReaderOnTheirRow() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        view.contentOffset.y -= 100 * cellHeight(of: view)
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        let shown = view.contentSize.height
        view.feed(text: "\(esc)[?2026h" + (1...30).map { "frame-\($0)\r\n" }.joined())
        XCTAssertEqual(view.contentSize.height, shown, "the frame must still show the rows from before it")
        view.resizeKeepingReader(cols: view.getTerminal().cols, rows: view.getTerminal().rows - 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(view.contentSize.height, shown, "the refit ends the frame")
        XCTAssertEqual(topTranscriptRow(of: view), held)
    }

    /// The host keeps a reader offset of its own (the mosh overlay's), which
    /// a font change re-placing a reader in history updates. A surface's
    /// first font, or one under a reader on the live tail, has no reader to
    /// report, and reporting one would reset a remounted overlay's offset.
    func testAFontChangeWithoutAReaderLeavesTheHostsOffsetAlone() throws {
        let key = "tessera.pref.fontSize"
        let savedFontSize = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(savedFontSize, forKey: key) }
        let appearance = AppearancePreferences()
        appearance.fontSize = 13
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe, appearance: appearance)
        defer { close() }
        XCTAssertEqual(probe.replacements, [], "the surface's first font")
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        let rows = view.getTerminal().rows
        appearance.fontSize = 17
        let deadline = Date().addingTimeInterval(3)
        while view.getTerminal().rows == rows, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotEqual(view.getTerminal().rows, rows, "17 pt must refit the grid")
        XCTAssertEqual(probe.replacements, [], "a reader on the live tail")
    }

    /// A tmux rebuild at a new width repaints the transcript in tmux's rows,
    /// not SwiftTerm's: a line tmux wrapped came back from the last capture
    /// as two rows SwiftTerm can't join, and comes back from this one joined.
    /// The rows from the tail land elsewhere; the reader's text doesn't.
    func testARebuiltPageInTmuxRowsFindsTheReadersText() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let box = TerminalBox(traceLabel: "reader-text")
        box.attach(view)
        box.markRenderReady()
        let owner = { TerminalRenderOwner(windowId: WindowId(1), paneId: PaneId(11), epoch: $0) }
        let wide = view.getTerminal().cols
        let rows = view.getTerminal().rows
        XCTAssertGreaterThan(wide, 70, "a line must fit one row of the wide grid")
        view.resizeKeepingReader(cols: 50, rows: rows)
        try await Task.sleep(for: .milliseconds(100))
        // Each line starts as the last one's tail goes on: its text is found
        // past a false start.
        let lines = (1...200).map { "aaab\($0)-" + String(repeating: "a", count: 61) }
        box.bind(owner: owner(1), restoringScrollbackLimit: 2_000)
        for line in lines {
            XCTAssertTrue(box.feed(owner: owner(1), Array("\(line.prefix(50))\r\n\(line.dropFirst(50))\r\n".utf8)[...]))
        }
        let cell = cellHeight(of: view)
        let tail = view.contentSize.height - view.bounds.height
        view.contentOffset.y = (((tail / cell).rounded(.down) - 100) / 2).rounded(.down) * 2 * cell
        func line() -> Substring? { topTranscriptRow(of: view)?.prefix { $0 != "-" } }
        let held = try XCTUnwrap(line())
        XCTAssertTrue(held.hasPrefix("aaab"), String(held))

        box.bind(owner: owner(2), restoringScrollbackLimit: 2_000)
        view.resizeKeepingReader(cols: wide, rows: rows)
        try await Task.sleep(for: .milliseconds(100))
        let place = try XCTUnwrap(box.takeScrollPositionBeforeRebind(for: owner(2)))
        let text = try XCTUnwrap(place.readerText, "the bind must record what the reader saw")
        let anchor = InlineTmuxHistoryRequestState.ScrollAnchor(offsetY: place.offsetY, maxOffsetY: place.maxOffsetY)
        XCTAssertEqual(view.offsetY(restoring: anchor, text: text).matched, false, "the emptied buffer has no page yet")
        for line in lines { XCTAssertTrue(box.feed(owner: owner(2), Array("\(line)\r\n".utf8)[...])) }
        let estimate = view.offsetY(restoring: anchor, text: nil)
        XCTAssertNil(estimate.matched)
        view.contentOffset.y = estimate.offsetY
        XCTAssertNotEqual(line(), held, "the rows from the tail must land elsewhere in tmux's rows")
        let restored = view.offsetY(restoring: anchor, text: text)
        XCTAssertEqual(restored.matched, true)
        view.contentOffset.y = restored.offsetY
        XCTAssertEqual(line(), held)
    }

    /// A tmux rebuild empties the buffer under a reader the view holds, then
    /// repaints it, and the host puts the reader back in the new page. The
    /// next output parked them at the tail: the clear dropped the held place
    /// and the placement never took it up (Duo retest M6 items 1 and 3). The
    /// bind's record carries the hold through a refit before the page, and a
    /// page still growing can put the reader on its tail first. A reader the
    /// view no longer held at the bind (a `clear` took their rows; a find
    /// match put them in history) stays too, as any reader in history.
    func testAReaderPutBackInARebuiltPageIsHeldThroughOutput() throws {
        let probe = AccessibilityScrollProbe()
        let (view, close) = try mountAccessibilityScrollSurface(probe)
        defer { close() }
        let box = TerminalBox(traceLabel: "placed-reader")
        box.attach(view)
        box.markRenderReady()
        let owner = { TerminalRenderOwner(windowId: WindowId(1), paneId: PaneId(11), epoch: $0) }
        let history = (1...300).map { "history-\($0)\r\n" }.joined()
        func onTheTail() -> Bool { view.contentOffset.y >= view.contentSize.height - view.bounds.height - 1 }
        func top() -> String? { topTranscriptRow(of: view) }
        func output(_ text: String) {
            view.feed(text: text)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        /// The bind empties the buffer, tmux repaints the pane, and the host
        /// puts the reader back where the bind recorded them.
        func rebuild(
            _ epoch: UInt64, page: String = history, held: Bool = true,
            refitBeforeThePage: Bool = false, onTheTailFirst: Bool = false
        ) throws {
            box.bind(owner: owner(epoch), restoringScrollbackLimit: 2_000)
            if refitBeforeThePage {
                view.resizeKeepingReader(cols: view.getTerminal().cols, rows: view.getTerminal().rows - 2)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            XCTAssertTrue(box.feed(owner: owner(epoch), Array(page.utf8)[...]))
            let place = try XCTUnwrap(box.takeScrollPositionBeforeRebind(for: owner(epoch)))
            XCTAssertEqual(place.held, held, "the bind records whether the view held the reader")
            let anchor = InlineTmuxHistoryRequestState.ScrollAnchor(offsetY: place.offsetY, maxOffsetY: place.maxOffsetY)
            if onTheTailFirst {
                view.contentOffset.y = view.contentSize.height - view.bounds.height
                view.onReaderPlaced?(place.held)
            }
            view.contentOffset.y = view.offsetY(restoring: anchor, text: place.readerText).offsetY
            view.onReaderPlaced?(place.held)
        }
        box.bind(owner: owner(1), restoringScrollbackLimit: 2_000)
        XCTAssertTrue(box.feed(owner: owner(1), Array(history.utf8)[...]))
        for _ in 0..<3 { XCTAssertTrue(view.accessibilityScroll(.up)) }
        let held = try XCTUnwrap(top())

        try rebuild(2)
        XCTAssertEqual(top(), held, "the placement")
        output("new-1\r\nnew-2\r\n")
        XCTAssertEqual(top(), held, "output after a rebuild holds the reader")

        try rebuild(3, refitBeforeThePage: true, onTheTailFirst: true)
        XCTAssertEqual(top(), held, "the placement after a refit")
        output("new-3\r\n")
        XCTAssertEqual(top(), held, "a refit before the page, and a placement on a growing page's tail first")

        output("\(esc)[3J")
        let later = (1...300).map { "later-\($0)\r\n" }.joined()
        output(later)
        XCTAssertTrue(onTheTail(), "the clear let go of the reader")
        view.contentOffset.y -= 100 * cellHeight(of: view)
        let unheld = try XCTUnwrap(top())
        try rebuild(4, page: later, held: false)
        XCTAssertEqual(top(), unheld)
        output("new-4\r\n")
        XCTAssertEqual(top(), unheld, "output keeps a reader the view no longer held, as any reader in history")
    }

    /// A reader scrolled back down to the bottom sits at the bounds' clamp,
    /// which a frame a part row taller than its rows puts above SwiftTerm's
    /// own tail. A shorter frame, or a bigger font, leaves them on the live
    /// tail: keeping their top row would hide the prompt below the view.
    func testAReaderAtTheBoundsClampStaysOnTheLiveTail() throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined() + "PROMPT$ ")
        func settle() {
            view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(TerminalResizeCoalescer.settleSeconds + 0.2))
        }
        func onTheTail() -> Bool { view.contentOffset.y >= view.contentSize.height - view.bounds.height - 1 }
        let cell = cellHeight(of: view)
        view.frame.size.height = (CGFloat(view.getTerminal().rows) + 0.6) * cell
        settle()
        let rows = view.getTerminal().rows
        view.contentOffset.y = view.contentSize.height - view.bounds.height

        view.frame.size.height -= 5 * cell
        settle()
        XCTAssertEqual(view.getTerminal().rows, rows - 5)
        XCTAssertTrue(onTheTail(), "a shorter frame: offset \(view.contentOffset.y) of \(view.contentSize.height - view.bounds.height)")

        view.contentOffset.y = view.contentSize.height - view.bounds.height
        view.setFontKeepingReader(view.font.withSize(view.font.pointSize + 4))
        settle()
        XCTAssertLessThan(view.getTerminal().rows, rows - 5, "the bigger font must refit the grid")
        XCTAssertTrue(onTheTail(), "a bigger font: offset \(view.contentOffset.y) of \(view.contentSize.height - view.bounds.height)")
    }

    /// Output keeps a reader in history, so it must know the live tail
    /// wherever a reader on it sits: at the bounds' clamp when the frame is
    /// taller than the grid, a part row above the clamp where a finger rests
    /// them short of a row above the grid's last screen (a frame that shrinks
    /// without a new grid settles them back on its clamp), and at the grid's
    /// last screen while a transient frame (a sheet's preview) is shorter
    /// than the grid it keeps. Each follows output; a reader a whole row up
    /// is reading history and stays.
    func testAReaderOnTheLiveTailFollowsOutputWhicheverTailHoldsThem() throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined())
        let cell = cellHeight(of: view)
        func settle() {
            view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(TerminalResizeCoalescer.settleSeconds + 0.2))
        }
        func clamp() -> CGFloat { view.contentSize.height - view.bounds.height }
        view.frame.size.height = (CGFloat(view.getTerminal().rows) + 0.6) * cell
        settle()
        let rows = view.getTerminal().rows
        func gridTail() -> CGFloat { view.contentSize.height - CGFloat(rows) * cell }
        view.contentOffset.y = clamp()
        view.feed(text: "clamp-1\r\nclamp-2\r\n")
        XCTAssertGreaterThanOrEqual(view.contentOffset.y, clamp() - 1, "a reader at the bounds' clamp follows output")

        view.contentOffset.y = gridTail() - cell
        let reading = view.contentOffset.y
        view.feed(text: "row-1\r\n")
        XCTAssertEqual(view.contentOffset.y, reading, accuracy: 0.5, "a reader a whole row up is reading history")

        // Rested at the clamp, then a frame a third of a row shorter keeps
        // the grid and settles the reader on its own clamp.
        view.contentOffset.y = clamp()
        view.frame.size.height -= 0.35 * cell
        settle()
        XCTAssertEqual(view.getTerminal().rows, rows, "a part row shorter frame keeps the grid")
        XCTAssertEqual(view.contentOffset.y, clamp(), accuracy: 0.5, "the shrink settles the reader on the shorter frame's clamp")
        // A finger can still rest them a part row above it.
        view.contentOffset.y = clamp() - 0.35 * cell
        view.feed(text: "shrunk-1\r\nshrunk-2\r\n")
        XCTAssertGreaterThanOrEqual(view.contentOffset.y, clamp() - 1,
                                    "a reader a part row above the tail follows output")

        // A frame rows taller before the grid catches up: its clamp is the tail.
        view.frame.size.height += 2.35 * cell
        view.layoutSubviews()
        XCTAssertEqual(view.getTerminal().rows, rows, "the taller frame waits for its grid")
        view.contentOffset.y = clamp()
        view.feed(text: "tall-1\r\ntall-2\r\n")
        XCTAssertGreaterThanOrEqual(view.contentOffset.y, clamp() - 1,
                                    "a reader at a taller frame's clamp follows output")
        view.frame.size.height = (CGFloat(rows) + 0.6) * cell
        settle()
        XCTAssertEqual(view.getTerminal().rows, rows, "the frame went back before its grid changed")

        view.frame.size.height -= 3 * cell
        view.layoutSubviews()
        XCTAssertEqual(view.getTerminal().rows, rows, "the transient frame keeps the grid")
        view.feed(text: "grid-1\r\n")
        view.contentOffset.y = gridTail()
        view.feed(text: "grid-2\r\ngrid-3\r\n")
        XCTAssertEqual(view.contentOffset.y, gridTail(), accuracy: 0.5,
                       "a reader on the grid's last screen follows output under a shorter frame")
    }

    /// A reader less than a row above the grid's tail is on it, whatever the
    /// bounds' clamp says: a finger can rest them a part row above the clamp
    /// of a frame part of a row taller than its grid (a frame that shrinks to
    /// it without a new grid settles them back on the clamp). Output and a
    /// bigger font both keep them on the live tail, as SwiftTerm's rule and
    /// the refit's agree.
    func testAReaderLessThanARowAboveTheGridsTailIsOnIt() throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined() + "PROMPT$ ")
        let cell = cellHeight(of: view)
        func settle() {
            view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(TerminalResizeCoalescer.settleSeconds + 0.2))
        }
        func clamp() -> CGFloat { view.contentSize.height - view.bounds.height }
        view.frame.size.height = (CGFloat(view.getTerminal().rows) + 0.97) * cell
        settle()
        let rows = view.getTerminal().rows
        func restInTheGap() {
            view.frame.size.height = (CGFloat(rows) + 0.97) * cell
            settle()
            view.contentOffset.y = clamp()
            view.frame.size.height -= 0.35 * cell
            settle()
            XCTAssertEqual(view.getTerminal().rows, rows, "a part row shorter frame keeps the grid")
            XCTAssertEqual(view.contentOffset.y, clamp(), accuracy: 0.5, "the shrink settles the reader on the new clamp")
            // A finger rests them where the shrink once left them.
            view.contentOffset.y = clamp() - 0.35 * cell
            let gridTail = view.contentSize.height - CGFloat(rows) * cell
            XCTAssertLessThan(view.contentOffset.y, clamp() - 1, "the reader sits above the shorter frame's clamp")
            XCTAssertGreaterThan(view.contentOffset.y, gridTail - cell, "less than a row above the grid's tail")
        }

        restInTheGap()
        view.feed(text: "gap-1\r\ngap-2\r\n")
        XCTAssertGreaterThanOrEqual(view.contentOffset.y, clamp() - 1, "output takes the reader with the tail")

        restInTheGap()
        view.setFontKeepingReader(view.font.withSize(view.font.pointSize + 4))
        settle()
        XCTAssertLessThan(view.getTerminal().rows, rows, "the bigger font must refit the grid")
        XCTAssertGreaterThanOrEqual(view.contentOffset.y, clamp() - 1,
                                    "a bigger font: offset \(view.contentOffset.y) of \(clamp())")

        // A whole row up is history: a font change keeps the reader's line.
        view.setFontKeepingReader(view.font.withSize(view.font.pointSize - 4))
        settle()
        XCTAssertEqual(view.getTerminal().rows, rows, "the font went back")
        restInTheGap()
        view.contentOffset.y = view.contentSize.height - CGFloat(rows) * cell - cell
        let held = try XCTUnwrap(topTranscriptRow(of: view))
        view.setFontKeepingReader(view.font.withSize(view.font.pointSize + 4))
        settle()
        XCTAssertEqual(topTranscriptRow(of: view), held, "a reader a whole row up keeps their line")
    }

    /// A reader a part of a point above the tail, where a scroll can settle,
    /// is on it: a shorter frame leaves them there.
    func testAReaderAHairAboveTheTailStaysOnIt() throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.feed(text: (1...300).map { "history-\($0)\r\n" }.joined() + "PROMPT$ ")
        let cell = cellHeight(of: view)
        view.contentOffset.y = view.contentSize.height - view.bounds.height - 0.5

        view.frame.size.height -= 5 * cell
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(TerminalResizeCoalescer.settleSeconds + 0.2))
        let tail = view.contentSize.height - view.bounds.height
        XCTAssertGreaterThanOrEqual(view.contentOffset.y, tail - 1, "offset \(view.contentOffset.y) of \(tail)")
    }

    /// A row whose last two cells hold a wide character is full: its line
    /// goes on in the next row, through a rewrap. An emoji its variation
    /// selector widened leaves its second cell blank.
    func testARewrapKeepsALineWhoseRowEndsInAWideCharacter() async throws {
        let view = TesseraResponderAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let cols = view.getTerminal().cols
        let fill = String(repeating: "a", count: cols - 7) + "\u{2764}\u{FE0F}"
        view.feed(text: (1...300).map { String(format: "L%03d ", $0) + fill + "tail\r\n" }.joined())
        let cell = cellHeight(of: view)
        view.contentOffset.y -= 100 * cell
        if topTranscriptRow(of: view)?.hasPrefix("L") != true { view.contentOffset.y -= cell }
        func line() -> String? { topTranscriptRow(of: view).map { String($0.prefix(4)) } }
        let held = try XCTUnwrap(line())
        XCTAssertTrue(held.hasPrefix("L"), held)

        view.resizeKeepingReader(cols: cols - 20, rows: view.getTerminal().rows)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(line(), held, "a narrower grid keeps the reader's line")
    }

    /// The transcript row at the top of the view.
    private func topTranscriptRow(of view: TerminalView) -> String? {
        let terminal = view.getTerminal()
        guard let first = (0..<2_000).first(where: { terminal.getScrollInvariantLine(row: $0) != nil }) else { return nil }
        let row = first + Int((view.contentOffset.y / cellHeight(of: view)).rounded())
        return terminal.getScrollInvariantLine(row: row)?.translateToString(trimRight: true)
    }

    private final class AccessibilityScrollProbe {
        var view: TesseraResponderAwareTerminalView?
        var readerInputs = 0
        var sent: [UInt8] = []
        var scrolled = 0
        var readerMoves: [CGFloat] = []
        var replacements: [CGFloat] = []
    }

    private func mountAccessibilityScrollSurface(
        _ probe: AccessibilityScrollProbe,
        pageRows: Int? = nil,
        native: Bool = false,
        appearance: AppearancePreferences = AppearancePreferences(),
        size: CGSize = CGSize(width: 900, height: 600),
        agentPageKeysBlocked: Bool = false
    ) throws -> (TesseraResponderAwareTerminalView, () -> Void) {
        let surface = TerminalSurfaceBound(
            initialData: [],
            onMade: { probe.view = $0 as? TesseraResponderAwareTerminalView },
            onReady: {}, onSend: { probe.sent += $0 }, onResize: { _, _ in }, onTitle: { _ in },
            onUserActivity: nil,
            onReaderInput: { probe.readerInputs += 1 },
            onBell: nil,
            primaryScrollPageRows: pageRows.map { rows in { rows } },
            mouseReportingImpliesAltScreen: false,
            suppressDirectColorQueryResponses: true,
            tmuxShortcutsEnabled: false,
            onTmuxShortcut: { _ in },
            onFindShortcut: nil,
            onSwitcherShortcut: nil,
            onOpenSettings: nil,
            suppressFirstResponderReclaim: true,
            onHardwareKey: nil,
            agentPageKeysBlocked: agentPageKeysBlocked,
            onTerminalScrolled: { _ in probe.scrolled += 1 },
            onNativeReaderScroll: { probe.readerMoves.append($0.contentOffset.y) },
            onReaderReplaced: { probe.replacements.append($0.contentOffset.y) },
            nativeScrollSurface: native
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: surface
            .frame(width: size.width, height: size.height)
            .environment(appearance)
            .environment(ShortcutStore()))
        window.isHidden = false
        let close = {
            window.isHidden = true
            window.rootViewController = nil
        }
        let deadline = Date().addingTimeInterval(3)
        while ((probe.view?.bounds.height ?? 0) <= size.height * 5 / 6 || (probe.view?.getTerminal().rows ?? 0) < 5),
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        do {
            return (try XCTUnwrap(probe.view, "the surface never mounted"), close)
        } catch {
            close()
            throw error
        }
    }

    /// SwiftTerm's row height, which the coordinator's pages are made of.
    private func cellHeight(of view: TerminalView) -> CGFloat {
        let font = view.font as CTFont
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        return ceil(height * view.contentScaleFactor) / view.contentScaleFactor
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
