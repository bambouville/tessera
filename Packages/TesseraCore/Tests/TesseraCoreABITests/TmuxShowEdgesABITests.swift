import Foundation
import XCTest
@testable import TesseraCoreABI

/// The show-edge tracker's JSON handle. Timing policy is pinned in
/// `ShowEdgeTrackerTests`; these tests pin the wire: event names, the edge
/// and state shapes, the unchanged reply and reject-before-mutate.
final class TmuxShowEdgesABITests: XCTestCase {
    private static let unchanged = #"{"version":1,"unchanged":true}"#

    private func rawReduce(
        _ handle: UnsafeMutableRawPointer,
        _ request: [String: Any],
        outputCapacity: Int = TmuxShowEdgesABI.maximumPayloadBytes
    ) throws -> (status: Int32, bytes: Data) {
        let input = try JSONSerialization.data(withJSONObject: request)
        var output = [UInt8](repeating: 0, count: outputCapacity)
        let count = input.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                tesseraTmuxShowEdgesReduce(
                    handle: handle,
                    requestBytes: inputRaw.bindMemory(to: UInt8.self).baseAddress,
                    requestCount: input.count,
                    outputBytes: outputRaw.bindMemory(to: UInt8.self).baseAddress,
                    outputCapacity: outputCapacity
                )
            }
        }
        return (count, count > 0 ? Data(output.prefix(Int(count))) : Data())
    }

    @discardableResult
    private func reduce(
        _ handle: UnsafeMutableRawPointer,
        _ event: String,
        at now: Int64,
        _ fields: [String: Any] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        var request = fields
        request["version"] = 1
        request["event"] = event
        request["nowMillis"] = now
        let (status, bytes) = try rawReduce(handle, request)
        XCTAssertGreaterThan(status, 0, "rejected \(request)", file: file, line: line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any], file: file, line: line)
    }

    private func assertUnchanged(
        _ handle: UnsafeMutableRawPointer,
        _ event: String,
        at now: Int64,
        _ fields: [String: Any] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var request = fields
        request["version"] = 1
        request["event"] = event
        request["nowMillis"] = now
        let (status, bytes) = try rawReduce(handle, request)
        XCTAssertGreaterThan(status, 0, file: file, line: line)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), Self.unchanged, file: file, line: line)
    }

    private func assertRejectedWithoutMutation(
        _ handle: UnsafeMutableRawPointer,
        _ request: [String: Any],
        outputCapacity: Int = TmuxShowEdgesABI.maximumPayloadBytes,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let before = try reduce(handle, "snapshot", at: 0, file: file, line: line)
        let (status, _) = try rawReduce(handle, request, outputCapacity: outputCapacity)
        XCTAssertEqual(status, -1, "accepted \(request)", file: file, line: line)
        let after = try reduce(handle, "snapshot", at: 0, file: file, line: line)
        XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: before), file: file, line: line)
    }

    private func edges(_ response: [String: Any]) -> [[String: Any]] {
        response["edges"] as? [[String: Any]] ?? []
    }

    private func int(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

    private func assertShow(
        _ response: [String: Any],
        source: String,
        stepAt: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let edges = edges(response)
        XCTAssertEqual(edges.count, 1, file: file, line: line)
        XCTAssertEqual(edges.first?["kind"] as? String, "show", file: file, line: line)
        XCTAssertEqual(edges.first?["source"] as? String, source, file: file, line: line)
        XCTAssertEqual(int(edges.first?["stepAtMillis"]), stepAt, file: file, line: line)
    }

    func testAShowWaitsForTheSettleAndAHideForTheDebounce() throws {
        let handle = tesseraTmuxShowEdgesCreate()
        defer { tesseraTmuxShowEdgesDestroy(handle: handle) }
        let fresh = try reduce(handle, "snapshot", at: 0)
        XCTAssertEqual(fresh["version"] as? Int, 1)
        XCTAssertEqual(fresh["displayed"] as? Bool, false)
        XCTAssertEqual(fresh["isShown"] as? Bool, false)
        XCTAssertEqual(fresh["showPending"] as? Bool, false)
        XCTAssertEqual(fresh["transparent"] as? Bool, false)
        XCTAssertNil(fresh["nextDeadlineMillis"])
        XCTAssertTrue(edges(fresh).isEmpty)

        let displayed = try reduce(handle, "displayed", at: 0, ["displayed": true])
        XCTAssertTrue(edges(displayed).isEmpty)
        XCTAssertEqual(displayed["showPending"] as? Bool, true)
        XCTAssertEqual(int(displayed["nextDeadlineMillis"]), 350)
        try assertUnchanged(handle, "tick", at: 349)
        let shown = try reduce(handle, "tick", at: 350)
        assertShow(shown, source: "show", stepAt: 350)
        XCTAssertEqual(shown["isShown"] as? Bool, true)
        XCTAssertNil(shown["nextDeadlineMillis"])

        let leaving = try reduce(handle, "displayed", at: 1_000, ["displayed": false])
        XCTAssertTrue(edges(leaving).isEmpty)
        XCTAssertEqual(leaving["isShown"] as? Bool, true, "a debouncing hide still counts as shown")
        XCTAssertEqual(int(leaving["nextDeadlineMillis"]), 2_500)
        let hidden = try reduce(handle, "tick", at: 2_500)
        XCTAssertEqual(edges(hidden).map { $0["kind"] as? String }, ["hide"])
        XCTAssertEqual(hidden["isShown"] as? Bool, false)
    }

    func testAReturnAfterAnUnreportedDebounceHidesThenShows() throws {
        let handle = tesseraTmuxShowEdgesCreate()
        defer { tesseraTmuxShowEdgesDestroy(handle: handle) }
        try reduce(handle, "displayed", at: 0, ["displayed": true])
        try reduce(handle, "tick", at: 350)
        try reduce(handle, "displayed", at: 1_000, ["displayed": false])
        // The device slept through the debounce; no tick reported it.
        let back = try reduce(handle, "displayed", at: 90_000, ["displayed": true])
        XCTAssertEqual(edges(back).map { $0["kind"] as? String }, ["hide"])
        XCTAssertEqual(back["showPending"] as? Bool, true)
        assertShow(try reduce(handle, "tick", at: 90_350), source: "show", stepAt: 90_350)
    }

    func testAnExplicitOpenShowsAgainWhileDisplayed() throws {
        let handle = tesseraTmuxShowEdgesCreate()
        defer { tesseraTmuxShowEdgesDestroy(handle: handle) }
        try reduce(handle, "displayed", at: 0, ["displayed": true])
        try reduce(handle, "tick", at: 350)
        let open = try reduce(handle, "explicitOpen", at: 1_000)
        XCTAssertEqual(open["showPending"] as? Bool, true)
        assertShow(try reduce(handle, "tick", at: 1_350), source: "explicitOpen", stepAt: 1_350)
    }

    func testATransparencyPastItsCapIsABackgroundFromItsStart() throws {
        let handle = tesseraTmuxShowEdgesCreate()
        defer { tesseraTmuxShowEdgesDestroy(handle: handle) }
        try reduce(handle, "displayed", at: 0, ["displayed": true])
        try reduce(handle, "tick", at: 350)
        let began = try reduce(handle, "transparentBegan", at: 1_000)
        XCTAssertEqual(began["transparent"] as? Bool, true)
        XCTAssertEqual(int(began["nextDeadlineMillis"]), 61_000)
        try assertUnchanged(handle, "transparentBegan", at: 2_000)
        let capped = try reduce(handle, "tick", at: 61_000)
        XCTAssertEqual(edges(capped).map { $0["kind"] as? String }, ["hide"])
        XCTAssertEqual(capped["displayed"] as? Bool, false)
        XCTAssertEqual(capped["transparent"] as? Bool, false)
        XCTAssertEqual(capped["isShown"] as? Bool, false)
    }

    func testMalformedAndOversizedRequestsAreRejectedBeforeMutation() throws {
        let handle = tesseraTmuxShowEdgesCreate()
        defer { tesseraTmuxShowEdgesDestroy(handle: handle) }
        try reduce(handle, "displayed", at: 0, ["displayed": true])
        let rejected: [[String: Any]] = [
            ["version": 1, "event": "tick"],
            ["version": 1, "event": "displayed", "nowMillis": 100],
            ["version": 1, "event": "hidden", "nowMillis": 100],
            ["version": 2, "event": "tick", "nowMillis": 400],
            ["event": "tick", "nowMillis": 400],
            ["version": 1, "event": "tick", "nowMillis": 400, "padding": String(repeating: "x", count: TmuxShowEdgesABI.maximumPayloadBytes)],
        ]
        for request in rejected {
            try assertRejectedWithoutMutation(handle, request)
        }
        try assertRejectedWithoutMutation(handle, ["version": 1, "event": "tick", "nowMillis": 400], outputCapacity: 64)
        XCTAssertEqual(try reduce(handle, "snapshot", at: 0)["showPending"] as? Bool, true, "the show never settled")
        XCTAssertEqual(rejected.count, 6)
    }

    /// Review F5: a negative clock is rejected; the far end of the valid
    /// range clamps rather than trapping through JNI.
    func testExtremeClockValuesAreRejectedOrClampedNeverTrapped() throws {
        let handle = tesseraTmuxShowEdgesCreate()
        defer { tesseraTmuxShowEdgesDestroy(handle: handle) }
        try assertRejectedWithoutMutation(handle, ["version": 1, "event": "tick", "nowMillis": Int64.min])
        try assertRejectedWithoutMutation(handle, ["version": 1, "event": "transparentBegan", "nowMillis": -1])
        try reduce(handle, "transparentBegan", at: 0)
        try reduce(handle, "displayed", at: Int64.max - 1, ["displayed": true])
        let late = try reduce(handle, "explicitOpen", at: Int64.max - 1)
        XCTAssertEqual(int(late["nextDeadlineMillis"]), Int64.max, "clamped, not wrapped")
        try reduce(handle, "tick", at: Int64.max)
    }

    func testDestroyedAndUnknownHandlesAreRejected() throws {
        let handle = tesseraTmuxShowEdgesCreate()
        tesseraTmuxShowEdgesDestroy(handle: handle)
        let (status, _) = try rawReduce(handle, ["version": 1, "event": "snapshot", "nowMillis": 0])
        XCTAssertEqual(status, -1)
        XCTAssertEqual(tesseraTmuxShowEdgesMaxPayloadBytes(), TmuxShowEdgesABI.maximumPayloadBytes)
    }
}
