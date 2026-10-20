@testable import Citadel
import Logging
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

/// Tessera's future-based SFTP requests over an in-memory channel: every
/// request reaches the wire before any reply exists, and replies may arrive
/// in any order.
final class SFTPPipelinedRequestTests: XCTestCase {
    private enum PacketType: UInt8 {
        case read = 5
        case write = 6
        case status = 101
        case data = 103
    }

    func testWriteFutureSendsEverySliceBeforeAnyReplyAndWaitsForAll() throws {
        let (channel, file) = try openFile()
        let payload = ByteBuffer(bytes: (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var completion: Result<Void, Error>?
        file.writeFuture(payload, at: 100).whenComplete { completion = $0 }
        channel.embeddedEventLoop.run()

        let writes = try outboundRequests(channel)
        XCTAssertEqual(writes.map(\.type), [.write, .write, .write])
        XCTAssertEqual(writes.map(\.offset), [100, 32_100, 64_100])
        XCTAssertEqual(writes.map(\.data.readableBytes), [32_000, 32_000, 6_000])
        var reassembled = ByteBuffer()
        for var write in writes { reassembled.writeBuffer(&write.data) }
        XCTAssertEqual(reassembled, payload)

        try reply(channel, status: 0, to: writes[2].id)
        try reply(channel, status: 0, to: writes[0].id)
        XCTAssertNil(completion, "one write is still unacknowledged")
        try reply(channel, status: 0, to: writes[1].id)
        XCTAssertNoThrow(try XCTUnwrap(completion).get())
    }

    func testWriteFutureFailsWhenAnySliceIsRejected() throws {
        let (channel, file) = try openFile()
        var completion: Result<Void, Error>?
        file.writeFuture(ByteBuffer(repeating: 1, count: 40_000), at: 0).whenComplete { completion = $0 }
        channel.embeddedEventLoop.run()

        let writes = try outboundRequests(channel)
        XCTAssertEqual(writes.count, 2)
        try reply(channel, status: 0, to: writes[0].id)
        try reply(channel, status: 4, to: writes[1].id)
        XCTAssertThrowsError(try XCTUnwrap(completion).get())
    }

    func testReadFuturesAreAllInFlightAndResolveOutOfOrder() throws {
        let (channel, file) = try openFile()
        var first: Result<ByteBuffer, Error>?
        var second: Result<ByteBuffer, Error>?
        file.readFuture(from: 0, length: 65_536).whenComplete { first = $0 }
        file.readFuture(from: 65_536, length: 65_536).whenComplete { second = $0 }
        channel.embeddedEventLoop.run()

        let reads = try outboundRequests(channel)
        XCTAssertEqual(reads.map(\.type), [.read, .read])
        XCTAssertEqual(reads.map(\.offset), [0, 65_536])
        XCTAssertEqual(reads.map(\.length), [65_536, 65_536])

        try reply(channel, status: 1, to: reads[1].id)
        XCTAssertEqual(try XCTUnwrap(second).get().readableBytes, 0, "end of file reads as empty")
        XCTAssertNil(first)
        try reply(channel, data: ByteBuffer(string: "tessera"), to: reads[0].id)
        XCTAssertEqual(try XCTUnwrap(first).get(), ByteBuffer(string: "tessera"))
    }

    private func openFile() throws -> (EmbeddedChannel, SFTPFile) {
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        var client: SFTPClient?
        SFTPClient.setupChannelHanders(channel: channel, logger: Logger(label: "sftp-pipeline-test"))
            .whenSuccess { client = $0 }
        channel.embeddedEventLoop.run()
        let file = SFTPFile(
            client: try XCTUnwrap(client),
            path: "/fixture/payload.bin",
            handle: ByteBuffer(string: "handle-1")
        )
        addTeardownBlock { _ = try? channel.finish() }
        return (channel, file)
    }

    private struct Request {
        let type: PacketType
        let id: UInt32
        let offset: UInt64
        var length: UInt32 = 0
        var data = ByteBuffer()
    }

    private func outboundRequests(_ channel: EmbeddedChannel) throws -> [Request] {
        var requests: [Request] = []
        while let message = try channel.readOutbound(as: SSHChannelData.self) {
            guard case .byteBuffer(var packet) = message.data else {
                XCTFail("SFTP requests travel as byte buffers")
                continue
            }
            _ = try XCTUnwrap(packet.readInteger(as: UInt32.self))
            let type = try XCTUnwrap(PacketType(rawValue: XCTUnwrap(packet.readInteger(as: UInt8.self))))
            let id = try XCTUnwrap(packet.readInteger(as: UInt32.self))
            let handleLength = try XCTUnwrap(packet.readInteger(as: UInt32.self))
            XCTAssertEqual(packet.readString(length: Int(handleLength)), "handle-1")
            var request = Request(type: type, id: id, offset: try XCTUnwrap(packet.readInteger(as: UInt64.self)))
            switch type {
            case .read:
                request.length = try XCTUnwrap(packet.readInteger(as: UInt32.self))
            case .write:
                let count = try XCTUnwrap(packet.readInteger(as: UInt32.self))
                request.data = try XCTUnwrap(packet.readSlice(length: Int(count)))
            default:
                XCTFail("unexpected request type \(type)")
            }
            requests.append(request)
        }
        return requests
    }

    private func reply(_ channel: EmbeddedChannel, status code: UInt32, to id: UInt32) throws {
        var body = ByteBuffer()
        body.writeInteger(id)
        body.writeInteger(code)
        body.writeInteger(UInt32(0)) // empty error message
        body.writeInteger(UInt32(0)) // empty language tag
        try deliver(channel, type: .status, body: body)
    }

    private func reply(_ channel: EmbeddedChannel, data: ByteBuffer, to id: UInt32) throws {
        var body = ByteBuffer()
        body.writeInteger(id)
        body.writeInteger(UInt32(data.readableBytes))
        var data = data
        body.writeBuffer(&data)
        try deliver(channel, type: .data, body: body)
    }

    private func deliver(_ channel: EmbeddedChannel, type: PacketType, body: ByteBuffer) throws {
        var packet = ByteBuffer()
        packet.writeInteger(UInt32(1 + body.readableBytes))
        packet.writeInteger(type.rawValue)
        var body = body
        packet.writeBuffer(&body)
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(packet)))
        channel.embeddedEventLoop.run()
    }
}
