import XCTest
@testable import TesseraSessionCore

final class AsyncDeliveryDiagnosticsTests: XCTestCase {
    func testMeasuresBacklogBeforeConsumptionAndResetsOnlyWindow() {
        let d = AsyncDeliveryDiagnostics()
        d.enqueued(nanos: 1_000_000)
        d.enqueued(nanos: 2_000_000)
        let blocked = d.snapshot(nanos: 5_001_000_000)
        XCTAssertEqual(blocked.pending, 2)
        XCTAssertEqual(blocked.oldestPendingMs, 5_000)
        XCTAssertEqual(blocked.maximumPending, 2)
        d.consumed(nanos: 5_002_000_000)
        let first = d.snapshot(nanos: 5_003_000_000)
        XCTAssertEqual(first.pending, 1)
        XCTAssertEqual(first.oldestPendingMs, 5_001)
        XCTAssertEqual(first.maximumWaitMs, 5_001)
        XCTAssertEqual(first.consumed, 1)
        XCTAssertEqual(first.received, 0)
        d.consumed(nanos: 5_004_000_000)
        XCTAssertEqual(d.snapshot(nanos: 5_005_000_000).pending, 0)
    }

    func testSamplingClipsMetadataNotCountsAndDoesNotReportFalseZeroAge() {
        let d = AsyncDeliveryDiagnostics()
        for i in 0..<65_540 { d.enqueued(nanos: UInt64(i)) }
        XCTAssertEqual(d.snapshot(nanos: 1_000_000).clippedSamples, 4)
        for _ in 0..<65_536 { d.consumed(nanos: 2_000_000) }
        let clipped = d.snapshot(nanos: 3_000_000)
        XCTAssertEqual(clipped.pending, 4)
        XCTAssertNil(clipped.oldestPendingMs)
        for _ in 0..<4 { d.consumed(nanos: 4_000_000) }
        d.enqueued(nanos: 5_000_000)
        d.consumed(nanos: 6_000_000)
        XCTAssertEqual(d.snapshot(nanos: 7_000_000).maximumWaitMs, 1)
    }

    func testDiscardResolvesOnlyOldestPendingValuesWithoutRecordingWait() {
        let d = AsyncDeliveryDiagnostics()
        d.enqueued(nanos: 1_000_000)
        d.enqueued(nanos: 2_000_000)
        d.enqueued(nanos: 3_000_000)
        d.discarded(count: 2)

        let afterDiscard = d.snapshot(nanos: 5_000_000)
        XCTAssertEqual(afterDiscard.pending, 1)
        XCTAssertEqual(afterDiscard.received, 3)
        XCTAssertEqual(afterDiscard.consumed, 0)
        XCTAssertEqual(afterDiscard.discarded, 2)
        XCTAssertEqual(afterDiscard.oldestPendingMs, 2)
        XCTAssertEqual(afterDiscard.maximumWaitMs, 0)

        d.consumed(nanos: 7_000_000)
        let drained = d.snapshot(nanos: 8_000_000)
        XCTAssertEqual(drained.pending, 0)
        XCTAssertEqual(drained.consumed, 1)
        XCTAssertEqual(drained.discarded, 0)
        XCTAssertEqual(drained.maximumWaitMs, 4)
    }

    func testDisabledDiagnosticsRemainZero() {
        let d = AsyncDeliveryDiagnostics(enabled: false)
        XCTAssertFalse(d.isEnabled)
        d.enqueued(nanos: 1)
        d.consumed(nanos: 2)
        d.discarded(count: 1)
        let result = d.snapshot(nanos: 3)
        XCTAssertEqual(result.pending, 0)
        XCTAssertEqual(result.received, 0)
        XCTAssertEqual(result.consumed, 0)
        XCTAssertEqual(result.discarded, 0)
    }

    @MainActor
    func testMainActorDeliveryMeasuresFromProducerNotBackgroundPump() async {
        let pair = AsyncStream.makeStream(of: Int.self)
        let d = AsyncDeliveryDiagnostics()
        for i in 0..<100 { d.enqueued(); pair.continuation.yield(i) }
        pair.continuation.finish()
        var values: [Int] = []
        for await value in pair.stream.mainActorDelivery(diagnostics: d) { values.append(value) }
        XCTAssertEqual(values, Array(0..<100))
        let result = d.snapshot()
        XCTAssertEqual(result.received, 100)
        XCTAssertEqual(result.consumed, 100)
        XCTAssertEqual(result.pending, 0)
        XCTAssertEqual(result.maximumPending, 100)
    }

    @MainActor
    func testMainActorDeliveryCancellationAccountsBufferedValues() async {
        let pair = AsyncStream.makeStream(of: Int.self)
        let d = AsyncDeliveryDiagnostics()
        for i in 0..<100 { d.enqueued(); pair.continuation.yield(i) }
        let iterator = pair.stream.mainActorDelivery(diagnostics: d).makeAsyncIterator()

        let first = await iterator.next()
        XCTAssertNotNil(first)
        let pumpFilled = await waitUntil { iterator.bufferedCount == 99 }
        XCTAssertTrue(pumpFilled)
        iterator.cancel()

        let result = d.snapshot(resetWindow: false)
        XCTAssertEqual(result.pending, 0)
        XCTAssertEqual(result.consumed, 1)
        XCTAssertEqual(result.discarded, 99)
        pair.continuation.finish()
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
