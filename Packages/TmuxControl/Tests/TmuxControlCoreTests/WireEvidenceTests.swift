import XCTest
@testable import TmuxControlCore

final class WireEvidenceTests: XCTestCase {
    func test_separatorsAndControlBytesStayVisible() {
        XCTAssertEqual(
            TmuxWireEvidence.snippet("%3\t12\t4\r\n\u{1b}P1000p\u{01}", limit: 100),
            "%3\\t12\\t4\\r\\n\\eP1000p\\x01"
        )
    }

    func test_snippetIsBoundedWithAnEllipsis() {
        XCTAssertEqual(TmuxWireEvidence.snippet("abcdef", limit: 3), "abc…")
        XCTAssertEqual(TmuxWireEvidence.snippet("abc", limit: 3), "abc")
    }
}
