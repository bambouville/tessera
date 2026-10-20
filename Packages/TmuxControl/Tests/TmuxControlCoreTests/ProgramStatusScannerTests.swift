import XCTest
@testable import TmuxControlCore

final class ProgramStatusScannerTests: XCTestCase {
    private let escape = "\u{1B}"

    func testMixedStreamSplitAtEveryBoundaryAndBytewise() {
        let stream = "plain\(escape)]0;title\u{7}\(escape)]7501;state=working\u{7}"
            + "\(escape)]7501;state=done\(escape)\\\(escape)]133;A;extra\u{7}\(escape)c"
            + "\(escape)]7501;state=idle:x=\(String(repeating: "a", count: 4096))\u{7}"
            + "\(escape)]7501;state=error\u{18}"
            + "\(escape)]7501;state=idle\(escape)]7501;?\u{7}"
        let bytes = Array(stream.utf8)
        let expected: [ProgramStatusScanEvent] = [
            .sequence(.report(.init(action: .set(.working)))),
            .sequence(.report(.init(action: .set(.done)))), .promptStart, .reset, .sequence(.query),
        ]
        for split in 0...bytes.count {
            var scanner = ProgramStatusScanner()
            let events = scanner.feed(bytes[..<split]) + scanner.feed(bytes[split...])
            XCTAssertEqual(events, expected, "split \(split)")
        }
        var scanner = ProgramStatusScanner()
        var events: [ProgramStatusScanEvent] = []
        for byte in bytes { events += scanner.feed([byte]) }
        XCTAssertEqual(events, expected)
    }

    func testOnlySevenBitOSCOpensAndOrdinaryChunksAreEmpty() {
        var scanner = ProgramStatusScanner()
        XCTAssertEqual(scanner.feed([0x9D] + Array("7501;state=done".utf8) + [7]), [])
        XCTAssertEqual(scanner.feed(Array("curly ” and ordinary output\u{7}".utf8)), [])
        XCTAssertEqual(scanner.feed(Array(repeating: 65, count: 100_000)), [])
        XCTAssertEqual(scanner.feed(Array("\(escape)]7501;?\u{7}".utf8)), [.sequence(.query)])
    }

    func testAbortRulesInBufferedAndSkippedOSCs() {
        for prefix in ["7501;state=idle", "0;unrelated", "7501;" + String(repeating: "a", count: 4097)] {
            for abort: UInt8 in [0x18, 0x1A] {
                var scanner = ProgramStatusScanner()
                XCTAssertEqual(scanner.feed(Array("\(escape)]\(prefix)".utf8) + [abort]), [])
                XCTAssertEqual(scanner.feed(Array("\(escape)]7501;?\u{7}".utf8)), [.sequence(.query)])
            }
            var scanner = ProgramStatusScanner()
            XCTAssertEqual(scanner.feed(Array("\(escape)]\(prefix)\(escape)]7501;?\u{7}".utf8)), [.sequence(.query)])
            XCTAssertEqual(scanner.feed(Array("\(escape)]\(prefix)\(escape)c".utf8)), [.reset])
            XCTAssertEqual(scanner.feed(Array("\(escape)]\(prefix)\(escape)x7501;?\u{7}".utf8)), [])
        }
    }

    func testOSCByteLimitBoundaryAndSkipUntilTerminator() {
        for length in [4095, 4096, 4097] {
            let start = "7501;state=idle:x="
            for terminator in ["\u{7}", "\(escape)\\"] {
                let content = start + String(repeating: "a", count: length - 2 - terminator.utf8.count - start.utf8.count)
                let bytes = Array("\(escape)]\(content)\(terminator)".utf8)
                XCTAssertEqual(bytes.count, length)
                var scanner = ProgramStatusScanner()
                let expected: [ProgramStatusScanEvent] = length <= 4096 ? [.sequence(.report(.init(action: .set(.idle))))] : []
                XCTAssertEqual(scanner.feed(bytes), expected)
                for split in [bytes.count - terminator.utf8.count, bytes.count - 1] {
                    var splitScanner = ProgramStatusScanner()
                    XCTAssertEqual(splitScanner.feed(bytes[..<split]) + splitScanner.feed(bytes[split...]), expected)
                }
                XCTAssertEqual(scanner.feed(Array("\(escape)]7501;?\u{7}".utf8)), [.sequence(.query)])
            }
        }
        var scanner = ProgramStatusScanner()
        XCTAssertEqual(scanner.feed(Array("\(escape)]7501;\(String(repeating: "x", count: 4097))7501;?\u{7}".utf8)), [])
    }

    func testPromptCommandsAndPrefixes() {
        var scanner = ProgramStatusScanner()
        for content in ["133;A", "133;A;", "133;A;anything"] {
            XCTAssertEqual(scanner.feed(Array("\(escape)]\(content)\u{7}".utf8)), [.promptStart])
        }
        for content in ["133;", "133;B", "133;AA", "133;Aanything", "7501", "7502;?", "1333;A", "7501;"] {
            XCTAssertEqual(scanner.feed(Array("\(escape)]\(content)\u{7}".utf8)), [], content)
        }
        XCTAssertEqual(scanner.feed(Array("\(escape)\(escape)]7501;?\(escape)\\".utf8)), [.sequence(.query)])
    }

    func testExplicitResetDropsPartialStateAndNonzeroSliceOffsets() {
        var scanner = ProgramStatusScanner()
        XCTAssertEqual(scanner.feed(Array("\(escape)]7501;state=".utf8)), [])
        scanner.reset()
        XCTAssertEqual(scanner.feed(Array("done\u{7}".utf8)), [])
        let bytes = Array("prefix\(escape)]7501;?\u{7}suffix".utf8)
        XCTAssertEqual(scanner.feed(bytes[6..<(bytes.count - 6)]), [.sequence(.query)])
    }
}
