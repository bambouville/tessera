import XCTest
@testable import Tessera

final class MacroEncoderTests: XCTestCase {
    func test_encodeMacroSpecs() {
        XCTAssertEqual(MacroEncoder.encode(""), [])
        XCTAssertEqual(MacroEncoder.encode("1↵"), [0x31, 0x0D])
        XCTAssertEqual(MacroEncoder.encode("2↵"), [0x32, 0x0D])
        XCTAssertEqual(MacroEncoder.encode("3↵"), [0x33, 0x0D])
        XCTAssertEqual(MacroEncoder.encode("y"), [0x79])
        XCTAssertEqual(MacroEncoder.encode("esc"), [0x1B])
        XCTAssertEqual(MacroEncoder.encode("\\e"), [0x1B])
        XCTAssertEqual(MacroEncoder.encode("\\x1b"), [0x1B])
        XCTAssertEqual(MacroEncoder.encode("\\r"), [0x0D])
        XCTAssertEqual(MacroEncoder.encode("\\n"), [0x0A])
        XCTAssertEqual(MacroEncoder.encode("\\t"), [0x09])
        XCTAssertEqual(MacroEncoder.encode("tab"), [0x09])
        XCTAssertEqual(MacroEncoder.encode("shift-tab"), [0x1B, 0x5B, 0x5A])
        XCTAssertEqual(MacroEncoder.encode("p"), [0x70])
        XCTAssertEqual(MacroEncoder.encode("3 ↵"), [0x33, 0x0D])
        XCTAssertEqual(MacroEncoder.encode("yes↵"), [0x79, 0x65, 0x73, 0x0D])
        XCTAssertEqual(MacroEncoder.encode("abc"), [0x61, 0x62, 0x63])
        XCTAssertEqual(MacroEncoder.encode("\\xff"), [0xFF])
        XCTAssertEqual(MacroEncoder.encode("n↵"), [0x6E, 0x0D])
        XCTAssertEqual(MacroEncoder.encode("y↵"), [0x79, 0x0D])
    }

    func test_malformedHexFallsBackToLiteralBackslashThenContinues() {
        XCTAssertEqual(MacroEncoder.encode("\\xZZ"), [0x5C, 0x78, 0x5A, 0x5A])
    }
}
