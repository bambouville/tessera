import XCTest
@testable import Tessera

@MainActor
final class EnrollmentContinuationStreamTransportTests: XCTestCase {
    func testDuplexTransportDeliversBytesInBothDirections() async throws {
        let pair = makeDuplexPair()
        let first = EnrollmentContinuationStreamTransport(
            input: pair.firstInput,
            output: pair.firstOutput
        )
        let second = EnrollmentContinuationStreamTransport(
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

    func testClosedTransportRejectsWrites() throws {
        let pair = makeDuplexPair()
        let transport = EnrollmentContinuationStreamTransport(
            input: pair.firstInput,
            output: pair.firstOutput
        )
        transport.start()
        transport.close()

        XCTAssertThrowsError(try transport.send(Data([0x01]))) { error in
            XCTAssertEqual(
                error as? EnrollmentContinuationStreamTransport.StreamError,
                .closed
            )
        }
        pair.secondInput.close()
        pair.secondOutput.close()
    }

    func testCloseDrainsBackpressuredTerminalFrameBeforeClosing() async throws {
        let pair = makeDuplexPair(capacity: 64)
        let sender = EnrollmentContinuationStreamTransport(
            input: pair.firstInput,
            output: pair.firstOutput
        )
        let receiver = EnrollmentContinuationStreamTransport(
            input: pair.secondInput,
            output: pair.secondOutput
        )
        // Larger than the pipe capacity, but representative of the bounded
        // enrollment control frames this adapter actually carries.
        let payload = Data(repeating: 0xA5, count: 1024)
        let received = expectation(description: "terminal frame drained")
        let senderClosed = expectation(description: "peer acknowledged close")
        var bytes = Data()

        receiver.onBytes = {
            bytes.append($0)
            if bytes.count == payload.count { received.fulfill() }
        }
        sender.onClose = { senderClosed.fulfill() }
        sender.start()
        try sender.send(payload)
        sender.close()
        XCTAssertFalse(sender.isClosed, "backpressured bytes must keep the stream alive")

        receiver.start()
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(bytes, payload)
        receiver.close()
        await fulfillment(of: [senderClosed], timeout: 2)
        XCTAssertTrue(sender.isClosed)
    }

    func testCloseRetainsReleasedSenderUntilBackpressuredFrameDrains() async throws {
        let pair = makeDuplexPair(capacity: 64)
        var sender: EnrollmentContinuationStreamTransport? =
            EnrollmentContinuationStreamTransport(
                input: pair.firstInput,
                output: pair.firstOutput
            )
        weak var drainingSender = sender
        let receiver = EnrollmentContinuationStreamTransport(
            input: pair.secondInput,
            output: pair.secondOutput
        )
        let payload = Data(repeating: 0x5C, count: 1024)
        let received = expectation(description: "released sender frame drained")
        let senderClosed = expectation(description: "released sender observed peer EOF")
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

        XCTAssertNotNil(
            drainingSender,
            "the bounded drain lifetime must not depend on the coordinator retaining it"
        )
        receiver.start()
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(bytes, payload)

        receiver.close()
        await fulfillment(of: [senderClosed], timeout: 2)
        for _ in 0..<10 where drainingSender != nil {
            await Task.yield()
        }
        XCTAssertNil(
            drainingSender,
            "the bounded drain lifetime must release after peer EOF"
        )
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

    private func makeBoundPair(capacity: Int) -> (input: InputStream, output: OutputStream) {
        var read: Unmanaged<CFReadStream>?
        var write: Unmanaged<CFWriteStream>?
        CFStreamCreateBoundPair(nil, &read, &write, capacity)
        return (
            read!.takeRetainedValue() as InputStream,
            write!.takeRetainedValue() as OutputStream
        )
    }
}
