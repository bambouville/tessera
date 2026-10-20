import XCTest
import TesseraInputCore
@testable import TesseraCoreABI

/// The C seam Termux's view drives; the table must match `TerminalScrollRouting`
/// case for case, and reject anything that is not a 0/1 flag.
final class ScrollRoutingABITests: XCTestCase {
    func testRouteCodesMatchTheSharedRule() {
        let codes: [TerminalScrollRoute: Int32] = [
            .localScrollback: 0, .mouseWheel: 1, .arrowKeys: 2,
        ]
        for alternate in [false, true] {
            for reporting in [false, true] {
                for implies in [false, true] {
                    let expected = TerminalScrollRouting.route(
                        bufferIsAlternate: alternate,
                        mouseReporting: reporting,
                        mouseReportingImpliesAltScreen: implies
                    )
                    XCTAssertEqual(
                        tesseraInputScrollRoute(
                            bufferIsAlternate: alternate ? 1 : 0,
                            mouseReporting: reporting ? 1 : 0,
                            mouseReportingImpliesAltScreen: implies ? 1 : 0
                        ),
                        codes[expected],
                        "alt=\(alternate) mouse=\(reporting) implies=\(implies)"
                    )
                }
            }
        }
    }

    func testNonFlagInputsAreRejected() {
        XCTAssertEqual(tesseraInputScrollRoute(bufferIsAlternate: 2, mouseReporting: 0, mouseReportingImpliesAltScreen: 0), -1)
        XCTAssertEqual(tesseraInputScrollRoute(bufferIsAlternate: 0, mouseReporting: -1, mouseReportingImpliesAltScreen: 0), -1)
        XCTAssertEqual(tesseraInputScrollRoute(bufferIsAlternate: 0, mouseReporting: 0, mouseReportingImpliesAltScreen: 7), -1)
    }
}
