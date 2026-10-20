import XCTest
@testable import TesseraSessionCore

final class MainActorDeliverySequenceTests: XCTestCase {
    @MainActor
    func testFinishedSourceDrainsEveryBufferedValueInOrder() async {
        let pair = AsyncStream.makeStream(of: Int.self)
        for value in 0..<10_000 { pair.continuation.yield(value) }
        pair.continuation.finish()
        var received: [Int] = []
        for await value in pair.stream.mainActorDelivery() { received.append(value) }
        XCTAssertEqual(received, Array(0..<10_000))
    }

    @MainActor
    func testCancellationUnblocksAnEmptyConsumerAndCancelsItsSource() async {
        let pair = AsyncStream.makeStream(of: Int.self)
        let terminated = expectation(description: "source cancelled")
        pair.continuation.onTermination = { reason in
            if case .cancelled = reason { terminated.fulfill() }
        }
        let task = Task { @MainActor in
            var count = 0
            for await _ in pair.stream.mainActorDelivery() { count += 1 }
            return count
        }
        await Task.yield()
        task.cancel()
        let count = await task.value
        XCTAssertEqual(count, 0)
        await fulfillment(of: [terminated], timeout: 2)
    }

    @MainActor
    func testReleasingIteratorCancelsItsOwnedPump() async {
        let pair = AsyncStream.makeStream(of: Int.self)
        let terminated = expectation(description: "iterator release cancels source")
        pair.continuation.onTermination = { reason in
            if case .cancelled = reason { terminated.fulfill() }
        }
        pair.continuation.yield(17)
        let sequence = pair.stream.mainActorDelivery()
        var iterator: MainActorDeliverySequence<Int>.Iterator? = sequence.makeAsyncIterator()
        let value = await iterator?.next()
        XCTAssertEqual(value, 17)
        iterator = nil
        await fulfillment(of: [terminated], timeout: 2)
    }

    @MainActor
    func testProducerWakeupsDoNotLoseValuesAtEmptyBufferBoundaries() async {
        let pair = AsyncStream.makeStream(of: Int.self)
        let producer = Task.detached {
            for value in 0..<500 {
                pair.continuation.yield(value)
                await Task.yield()
            }
            pair.continuation.finish()
        }
        var received: [Int] = []
        for await value in pair.stream.mainActorDelivery() {
            received.append(value)
            if value % 3 == 0 { await Task.yield() }
        }
        await producer.value
        XCTAssertEqual(received, Array(0..<500))
    }

    @MainActor
    func testBufferedCancellationDoesNotDrainAfterCancellationEvenIfSourceFinishes() async {
        for _ in 0..<20 {
            let pair = AsyncStream.makeStream(of: Int.self)
            for value in 0..<500 { pair.continuation.yield(value) }
            let task = Task { @MainActor in
                let iterator = pair.stream.mainActorDelivery().makeAsyncIterator()
                let first = await iterator.next()
                withUnsafeCurrentTask { $0?.cancel() }
                pair.continuation.finish()
                let second = await iterator.next()
                XCTAssertEqual(first, 0)
                XCTAssertNil(second)
            }
            await task.value
        }
    }

    @MainActor
    func testBufferedDrainYieldsToOtherMainActorWork() async {
        let pair = AsyncStream.makeStream(of: Int.self)
        for value in 0..<100 { pair.continuation.yield(value) }
        pair.continuation.finish()
        var competitorRan = false
        var progressWhenCompetitorRan = 0
        var received = 0
        var competitor: Task<Void, Never>?
        for await _ in pair.stream.mainActorDelivery() {
            received += 1
            if competitor == nil {
                competitor = Task { @MainActor in
                    competitorRan = true
                    progressWhenCompetitorRan = received
                }
            }
            let end = ContinuousClock.now.advanced(by: .milliseconds(1))
            while ContinuousClock.now < end {}
        }
        await competitor?.value
        XCTAssertTrue(competitorRan)
        XCTAssertLessThan(progressWhenCompetitorRan, 100)
        XCTAssertEqual(received, 100)
    }

    @MainActor
    func testCooperativeConsumerResetsFairnessAfterItsSuspension() async {
        let pair = AsyncStream.makeStream(of: Int.self)
        for value in 0..<30 { pair.continuation.yield(value) }
        pair.continuation.finish()
        let iterator = pair.stream.mainActorDelivery().makeAsyncIterator()
        var received: [Int] = []
        while let value = await iterator.next() {
            received.append(value)
            try? await Task.sleep(for: .milliseconds(5))
            iterator.consumerDidYield()
        }
        XCTAssertEqual(received, Array(0..<30))
    }
}
