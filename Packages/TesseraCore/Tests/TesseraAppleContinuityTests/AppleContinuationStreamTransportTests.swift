import CoreFoundation
import Foundation
import TesseraAppleContinuity
import TesseraEnrollmentCore
import XCTest

@MainActor
final class AppleContinuationStreamTransportTests: XCTestCase {
    func testDuplexTransportDeliversBytesAndUsesAppleAccountBinding() async throws {
        let pair = makeDuplexPair()
        let first = AppleContinuationStreamTransport(
            input: pair.firstInput,
            output: pair.firstOutput
        )
        let second = AppleContinuationStreamTransport(
            input: pair.secondInput,
            output: pair.secondOutput
        )
        let firstReceived = expectation(description: "first received")
        let secondReceived = expectation(description: "second received")
        var firstBytes = Data()
        var secondBytes = Data()

        first.onBytes = {
            firstBytes.append($0)
            if firstBytes == Data("from-second".utf8) { firstReceived.fulfill() }
        }
        second.onBytes = {
            secondBytes.append($0)
            if secondBytes == Data("from-first".utf8) { secondReceived.fulfill() }
        }
        first.start()
        second.start()

        try first.send(Data("from-first".utf8))
        try second.send(Data("from-second".utf8))
        await fulfillment(of: [firstReceived, secondReceived], timeout: 2)

        XCTAssertEqual(firstBytes, Data("from-second".utf8))
        XCTAssertEqual(secondBytes, Data("from-first".utf8))
        XCTAssertEqual(first.peerBinding, .appleAccountContinuationStream)
        XCTAssertEqual(second.peerBinding, .appleAccountContinuationStream)
        first.close()
        second.close()
    }

    func testCloseDrainsBackpressuredFrameAndRetainsReleasedSender() async throws {
        let pair = makeDuplexPair(capacity: 64)
        var sender: AppleContinuationStreamTransport? =
            AppleContinuationStreamTransport(
                input: pair.firstInput,
                output: pair.firstOutput
            )
        weak var drainingSender = sender
        let receiver = AppleContinuationStreamTransport(
            input: pair.secondInput,
            output: pair.secondOutput
        )
        let payload = Data(repeating: 0x5C, count: 1024)
        let received = expectation(description: "terminal frame drained")
        let senderClosed = expectation(description: "sender observed peer EOF")
        var bytes = Data()

        receiver.onBytes = {
            bytes.append($0)
            if bytes.count == payload.count { received.fulfill() }
        }
        sender?.onClose = { senderClosed.fulfill() }
        sender?.start()
        try sender?.send(payload)
        sender?.close()
        sender = nil

        XCTAssertNotNil(drainingSender)
        receiver.start()
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(bytes, payload)

        receiver.close()
        await fulfillment(of: [senderClosed], timeout: 2)
        // EOF cancels the self-retaining forced-close task. A fixed number of
        // yields does not guarantee that its cancellation continuation has
        // run. Wait for actual release with a deadline shorter than the 5s
        // forced-close timer, so a retained/cancellation-broken sender fails.
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while drainingSender != nil, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(drainingSender)
    }

    func testClosedTransportRejectsWrites() throws {
        let pair = makeDuplexPair()
        let transport = AppleContinuationStreamTransport(
            input: pair.firstInput,
            output: pair.firstOutput
        )
        transport.start()
        transport.close()

        XCTAssertThrowsError(try transport.send(Data([0x01]))) { error in
            XCTAssertEqual(
                error as? AppleContinuationStreamTransport.StreamError,
                .closed
            )
        }
        pair.secondInput.close()
        pair.secondOutput.close()
    }

    private func makeDuplexPair(capacity: Int = 64 * 1024) -> (
        firstInput: InputStream,
        firstOutput: OutputStream,
        secondInput: InputStream,
        secondOutput: OutputStream
    ) {
        let firstInbound = makeBoundPair(capacity: capacity)
        let secondInbound = makeBoundPair(capacity: capacity)
        return (
            firstInput: firstInbound.input,
            firstOutput: secondInbound.output,
            secondInput: secondInbound.input,
            secondOutput: firstInbound.output
        )
    }

    private func makeBoundPair(capacity: Int) -> (
        input: InputStream,
        output: OutputStream
    ) {
        var read: Unmanaged<CFReadStream>?
        var write: Unmanaged<CFWriteStream>?
        CFStreamCreateBoundPair(nil, &read, &write, capacity)
        return (
            read!.takeRetainedValue() as InputStream,
            write!.takeRetainedValue() as OutputStream
        )
    }
}
