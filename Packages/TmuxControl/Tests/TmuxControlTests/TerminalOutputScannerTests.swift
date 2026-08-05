import XCTest
@testable import TmuxControl

final class TerminalOutputScannerTests: XCTestCase {
    /// Regression: curly quotes are E2 80 9C / E2 80 9D — their trailing
    /// bytes are also the C1 OSC/ST codes. Treating 0x9D as an OSC opener
    /// let ordinary prose open a phantom OSC that swallowed the next real
    /// bell.
    func test_bellAfterCurlyQuoteProseRings() {
        var scanner = TerminalOutputScanner()
        _ = scanner.feed(Array("he said \u{201D} and then more text".utf8))
        XCTAssertTrue(scanner.feed([0x07]).audibleBell)
    }

    /// Same phantom OSC, worse outcome: prose shaped like `”0;NAME` followed
    /// by a bell parsed as a title event and renamed the pane.
    func test_curlyQuoteProseCannotForgeTitle() {
        var scanner = TerminalOutputScanner()
        var events = scanner.feed(Array("quote \u{201D}0;EVIL".utf8))
        let more = scanner.feed([0x07])
        events.titleEvents.append(contentsOf: more.titleEvents)
        XCTAssertTrue(events.titleEvents.isEmpty, "prose must not synthesize a title event")
        XCTAssertTrue(more.audibleBell, "the BEL after prose is a real bell")
    }

    func test_sevenBitTitleOSCStillParses() {
        var scanner = TerminalOutputScanner()
        let events = scanner.feed(Array("\u{1B}]0;my title\u{07}".utf8))
        XCTAssertEqual(events.titleEvents, [TerminalTitleEvent(command: 0, title: "my title")])
        XCTAssertFalse(events.audibleBell, "a BEL terminating an OSC is not a bell")
    }

    func test_titleOSCSplitAcrossChunksParses() {
        var scanner = TerminalOutputScanner()
        XCTAssertTrue(scanner.feed(Array("\u{1B}]2;par".utf8)).titleEvents.isEmpty)
        let events = scanner.feed(Array("tial\u{1B}\\".utf8))
        XCTAssertEqual(events.titleEvents, [TerminalTitleEvent(command: 2, title: "partial")])
    }
}
