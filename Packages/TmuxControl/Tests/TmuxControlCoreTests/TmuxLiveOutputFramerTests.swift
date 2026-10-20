import XCTest
@testable import TmuxControlCore

final class TmuxLiveOutputFramerTests: XCTestCase {
    func testC0AndDELDoNotEndEscapePrefix() {
        for control: UInt8 in [0, 7, 10, 0x7F] {
            var framer = TmuxLiveOutputFramer()
            let prefix: [UInt8] = [0x1B, control, 0x5B, 0x33, 0x31]
            XCTAssertEqual(framer.process(prefix), [])
            XCTAssertEqual(framer.process([0x6D]), prefix + [0x6D])
            let bytes = prefix + [0x6D]
            XCTAssertEqual(TmuxLiveOutputFramer.chunkEnd(in: bytes[...], from: 0, maximumCount: 2), bytes.count)
        }
    }

    func testEveryColorSplitAndCooperativeBoundaryIsAtomic() {
        let color = Array("\u{1B}[38;2;58;58;58;48;2;0;0;30m".utf8)
        for split in 1..<color.count {
            var framer = TmuxLiveOutputFramer()
            XCTAssertEqual(framer.process(Array("prompt".utf8) + color.prefix(split)), Array("prompt".utf8))
            XCTAssertEqual(framer.process(Array(color.dropFirst(split)) + [88]), color + [88])
            XCTAssertTrue(framer.isGround)
            XCTAssertEqual(TmuxLiveOutputFramer.chunkEnd(in: color[...], from: 0, maximumCount: split), color.count)
        }
    }

    func testStringTerminationAndCancellationResumeCSIFraming() {
        let prefix = Array("\u{1B}[38;2;58;58;".utf8)
        for ending in [[UInt8]("\u{1B}\\".utf8), [7], [0x9C], [0x18], [0x1A], Array("\u{1B}[0m".utf8)] {
            var framer = TmuxLiveOutputFramer()
            let string = Array("\u{1B}]title".utf8) + ending
            XCTAssertEqual(framer.process(string), string)
            XCTAssertEqual(framer.process(prefix), [])
            XCTAssertEqual(framer.process(Array("58mX".utf8)), prefix + Array("58mX".utf8))
        }
    }

    func testUTF8ContinuationIsNotC1ControlAndPlainTextLeavesImmediately() {
        var framer = TmuxLiveOutputFramer()
        for byte in Array("hi Üɛ world".utf8) {
            XCTAssertEqual(framer.process([byte]), [byte])
        }
        XCTAssertTrue(framer.isGround)
        let bytes = Array("123Ü456".utf8)
        XCTAssertEqual(TmuxLiveOutputFramer.chunkEnd(in: bytes[...], from: 0, maximumCount: 4), 5)
        XCTAssertEqual(framer.process([0x9B, 0x33]), [])
        XCTAssertEqual(framer.process([0x31, 0x6D]), [0x9B, 0x33, 0x31, 0x6D])
    }

    func testUnboundedAndCancelledControlsDoNotLeakNumericSuffixes() {
        var framer = TmuxLiveOutputFramer()
        XCTAssertEqual(framer.process(Array("\u{1B}[".utf8) + Array(repeating: 0x33, count: 100_000)), [])
        XCTAssertEqual(framer.process(Array("31mhello".utf8)), Array("hello".utf8))
        XCTAssertTrue(framer.isGround)
        XCTAssertEqual(framer.process(Array("\u{1B}[31".utf8)), [])
        XCTAssertEqual(framer.process(Array("\u{1B}[0mX".utf8)), Array("\u{1B}[0mX".utf8))
    }
}
