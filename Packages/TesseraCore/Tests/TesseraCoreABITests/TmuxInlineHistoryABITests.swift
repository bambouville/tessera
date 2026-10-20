import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

/// The inline (SSH+tmux) history ladder's two shared-core seams: the stateless
/// gesture gate Android calls by C symbol, and the settling render effect both
/// platforms decode from the render-effect stream.
final class TmuxInlineHistoryABITests: XCTestCase {
    func testInlineHistoryGateCDeclMatchesTheSwiftRuleAndRejectsTriStates() {
        let tuples: [(Bool, Bool, Int32, Int32, Bool)] = [
            (true, false, 0, 24, true),
            (true, false, 48, 24, false),
            (true, false, 49, 24, false),
            (true, true, 0, 24, true),
            (false, false, 0, 24, true),
            (true, false, -5, 24, false),
            (true, false, 0, 0, false),
            (true, false, 0, 0, true),
        ]
        for (canDeepen, inFlight, rowsAbove, viewportRows, crossed) in tuples {
            let expected = TmuxInlineHistoryGate.shouldRequest(
                canDeepen: canDeepen,
                requestInFlight: inFlight,
                rowsAboveOldest: Int(rowsAbove),
                viewportRows: Int(viewportRows),
                crossedOldestRow: crossed
            ) ? Int32(1) : Int32(0)
            XCTAssertEqual(
                tesseraTmuxInlineHistoryShouldRequest(
                    canDeepen: canDeepen ? 1 : 0,
                    requestInFlight: inFlight ? 1 : 0,
                    rowsAboveOldest: rowsAbove,
                    viewportRows: viewportRows,
                    crossedOldestRow: crossed ? 1 : 0
                ),
                expected,
                "gate(\(canDeepen), \(inFlight), \(rowsAbove), \(viewportRows), \(crossed))"
            )
        }

        // A tri-state must not be silently read as false: the Kotlin wrapper
        // passes Int32, so an un-initialised or sentinel flag has to be loud.
        for bad: Int32 in [-1, 2, Int32.min, Int32.max] {
            XCTAssertEqual(
                tesseraTmuxInlineHistoryShouldRequest(
                    canDeepen: bad, requestInFlight: 0, rowsAboveOldest: 0,
                    viewportRows: 24, crossedOldestRow: 1
                ),
                -1
            )
            XCTAssertEqual(
                tesseraTmuxInlineHistoryShouldRequest(
                    canDeepen: 1, requestInFlight: bad, rowsAboveOldest: 0,
                    viewportRows: 24, crossedOldestRow: 1
                ),
                -1
            )
            XCTAssertEqual(
                tesseraTmuxInlineHistoryShouldRequest(
                    canDeepen: 1, requestInFlight: 0, rowsAboveOldest: 0,
                    viewportRows: 24, crossedOldestRow: bad
                ),
                -1
            )
        }
    }

    /// The published wire shape. The Kotlin reader indexes these exact keys,
    /// so a rename here is an ABI break rather than a refactor.
    func testInlineHistorySettledUsesTheDocumentedCanonicalJSON() throws {
        let effect = RenderEffect.inlineHistorySettled(
            .live,
            owner: .init(windowID: WindowId(1), paneID: PaneId(2), epoch: 3),
            depth: 10_000,
            historySize: 7_009,
            canDeepen: false
        )
        let data = try SharedABI.encoder.encode(effect)
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            "{\"canDeepen\":false,\"depth\":10000,\"historySize\":7009,"
                + "\"kind\":\"inlineHistorySettled\",\"owner\":{\"epoch\":3,\"paneID\":2,\"windowID\":1},"
                + "\"surfaceID\":\"live\"}"
        )
        XCTAssertEqual(try JSONDecoder().decode(RenderEffect.self, from: data), effect)

        // A platform that spells the object itself must decode identically.
        let handWritten = Data("""
        {"canDeepen":true,"depth":2000,"historySize":7009,"kind":"inlineHistorySettled",\
        "owner":{"epoch":1,"paneID":1,"windowID":1},"surfaceID":"live"}
        """.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(RenderEffect.self, from: handWritten),
            .inlineHistorySettled(
                .live,
                owner: .init(windowID: WindowId(1), paneID: PaneId(1), epoch: 1),
                depth: 2_000,
                historySize: 7_009,
                canDeepen: true
            )
        )
    }

    /// The render-byte ceiling is deliberately separate from, and larger than,
    /// the argument ceiling: a full-depth inline capture is sized by the tmux
    /// host, not by anything a platform composes.
    func testRenderByteCeilingIsPublishedAboveTheArgumentCeiling() {
        XCTAssertEqual(SharedABI.maximumRenderBytes, 8_388_608)
        XCTAssertEqual(SharedABI.maximumInputBytes, 1_048_576)
        XCTAssertGreaterThan(SharedABI.maximumRenderBytes, SharedABI.maximumInputBytes)
        XCTAssertGreaterThan(SharedABI.maximumRenderBytes, 2 * 1_024 * 1_024)
    }
}
