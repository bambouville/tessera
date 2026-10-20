import XCTest
@testable import TmuxControlCore

final class WindowOrderSubscriptionTests: XCTestCase {
    func testNameAndFormat() {
        XCTAssertEqual(TmuxWindowOrderSubscription.name, "tessera-window-order")
        XCTAssertEqual(
            TmuxWindowOrderSubscription.format,
            "#{W:#{window_index}=#{window_id} ,#{window_index}=#{window_id}* }"
        )
    }

    func testParsesCaptured36aValueAndIgnoresActiveMarker() {
        let parsed = TmuxWindowOrderSubscription.parse("0=@0 1=@2 2=@1* 3=@3")
        XCTAssertEqual(parsed?.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(parsed?.map(\.id), ids(0, 2, 1, 3))
    }

    func testSortsByServerIndexAndAcceptsEmptySession() {
        let parsed = TmuxWindowOrderSubscription.parse("9=@4 2=@8*")
        XCTAssertEqual(parsed?.map(\.index), [2, 9])
        XCTAssertEqual(parsed?.map(\.id), ids(8, 4))
        XCTAssertEqual(TmuxWindowOrderSubscription.parse("")?.count, 0)
    }

    func testRejectsMalformedDuplicateAndOutOfBoundsValues() {
        for malformed in [
            "0=@0 junk",
            "0=@0 0=@1",
            "0=@0 1=@0",
            "0=@0* 1=@1*",
            "-1=@0",
            "1000001=@0",
            "0=0",
            "0=@-1",
            "0=@0=extra",
        ] {
            XCTAssertNil(TmuxWindowOrderSubscription.parse(malformed), malformed)
        }
        let tooMany = (0...512).map { "\($0)=@\($0)" }.joined(separator: " ")
        XCTAssertNil(TmuxWindowOrderSubscription.parse(tooMany))
    }

    private func ids(_ values: Int...) -> [WindowId] { values.map(WindowId.init) }
}
