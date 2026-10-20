import XCTest
@testable import TmuxControlCore

/// The one gesture rule the platforms evaluate themselves. Everything else
/// about the inline history ladder is ledger reducer state, so this table is
/// the whole shared contract iOS calls directly and Android calls through
/// `tessera_tmux_inline_history_should_request`.
final class InlineHistoryGateTests: XCTestCase {
    private struct Case {
        let name: String
        let canDeepen: Bool
        let requestInFlight: Bool
        let rowsAboveOldest: Int
        let viewportRows: Int
        let crossedOldestRow: Bool
        let expected: Bool
    }

    func test_shouldRequestTable() {
        let cases: [Case] = [
            .init(
                name: "an exhausted surface never asks again",
                canDeepen: false, requestInFlight: false, rowsAboveOldest: 0,
                viewportRows: 24, crossedOldestRow: true, expected: false
            ),
            .init(
                name: "exhaustion wins over a request already in flight",
                canDeepen: false, requestInFlight: true, rowsAboveOldest: 0,
                viewportRows: 24, crossedOldestRow: true, expected: false
            ),
            .init(
                name: "single-flight: one unanswered request suppresses the next",
                canDeepen: true, requestInFlight: true, rowsAboveOldest: 0,
                viewportRows: 24, crossedOldestRow: true, expected: false
            ),
            .init(
                name: "scrolling past the oldest local row always asks",
                canDeepen: true, requestInFlight: false, rowsAboveOldest: 0,
                viewportRows: 24, crossedOldestRow: true, expected: true
            ),
            .init(
                name: "the prefetch band is two viewports above the oldest row",
                canDeepen: true, requestInFlight: false, rowsAboveOldest: 48,
                viewportRows: 24, crossedOldestRow: false, expected: true
            ),
            .init(
                name: "one row beyond the band stays quiet",
                canDeepen: true, requestInFlight: false, rowsAboveOldest: 49,
                viewportRows: 24, crossedOldestRow: false, expected: false
            ),
            .init(
                name: "deep in the transcript nothing is fetched",
                canDeepen: true, requestInFlight: false, rowsAboveOldest: 5_000,
                viewportRows: 24, crossedOldestRow: false, expected: false
            ),
            .init(
                name: "an unmeasured viewport disables the band, not the crossing",
                canDeepen: true, requestInFlight: false, rowsAboveOldest: 0,
                viewportRows: 0, crossedOldestRow: false, expected: false
            ),
            .init(
                name: "an unmeasured viewport still honours the crossing",
                canDeepen: true, requestInFlight: false, rowsAboveOldest: 0,
                viewportRows: 0, crossedOldestRow: true, expected: true
            ),
            .init(
                name: "a negative viewport cannot invert the band",
                canDeepen: true, requestInFlight: false, rowsAboveOldest: 0,
                viewportRows: -24, crossedOldestRow: false, expected: false
            ),
            .init(
                name: "an overscrolled row count clamps to the oldest row",
                canDeepen: true, requestInFlight: false, rowsAboveOldest: -120,
                viewportRows: 24, crossedOldestRow: false, expected: true
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                TmuxInlineHistoryGate.shouldRequest(
                    canDeepen: testCase.canDeepen,
                    requestInFlight: testCase.requestInFlight,
                    rowsAboveOldest: testCase.rowsAboveOldest,
                    viewportRows: testCase.viewportRows,
                    crossedOldestRow: testCase.crossedOldestRow
                ),
                testCase.expected,
                testCase.name
            )
        }
    }

    /// The band is stated in viewports so it scales with the device: a phone
    /// prefetches after fewer rows than a landscape iPad, at the same moment
    /// in the reader's scroll.
    func test_prefetchBandScalesWithTheViewport() {
        XCTAssertEqual(TmuxInlineHistoryGate.prefetchViewports, 2)
        for viewportRows in [10, 24, 45, 60] {
            let edge = viewportRows * TmuxInlineHistoryGate.prefetchViewports
            XCTAssertTrue(TmuxInlineHistoryGate.shouldRequest(
                canDeepen: true, requestInFlight: false, rowsAboveOldest: edge,
                viewportRows: viewportRows, crossedOldestRow: false
            ))
            XCTAssertFalse(TmuxInlineHistoryGate.shouldRequest(
                canDeepen: true, requestInFlight: false, rowsAboveOldest: edge + 1,
                viewportRows: viewportRows, crossedOldestRow: false
            ))
        }
    }
}
