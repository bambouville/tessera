@testable import Citadel
import Logging
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

final class SFTPDirectoryHandleTests: XCTestCase {
    func testListDirectoryClosesHandleAfterEOFAndIgnoresCloseFailure() async throws {
        for closeStatus: UInt32 in [0, 4] {
            try await withClient { client, channel in
                let listing = Task { try await client.listDirectory(atPath: "/srv") }
                defer { listing.cancel() }
                try await openDirectory(channel)
                let firstRead = try await request(channel, type: .readdir)
                XCTAssertEqual(firstRead.argument, "directory-handle")
                try await name(channel, id: firstRead.id, filename: "report.md")
                let nextRead = try await request(channel, type: .readdir)
                try await status(channel, id: nextRead.id, code: 1)
                let close = try await request(channel, type: .close)
                XCTAssertEqual(close.argument, "directory-handle")
                try await status(channel, id: close.id, code: closeStatus)
                let entries = try await listing.value
                XCTAssertEqual(entries.flatMap(\.components).map(\.filename), ["report.md"])
                let extra = try await channel.readOutbound(as: SSHChannelData.self)
                XCTAssertNil(extra, "the directory must close exactly once")
            }
        }
    }

    func testListDirectoryClosesHandleAfterReadFailureAndPreservesThatFailure() async throws {
        try await withClient { client, channel in
            let listing = Task { try await client.listDirectory(atPath: "/srv") }
            defer { listing.cancel() }
            try await openDirectory(channel)
            let read = try await request(channel, type: .readdir)
            try await status(channel, id: read.id, code: 3)
            let close = try await request(channel, type: .close)
            XCTAssertEqual(close.argument, "directory-handle")
            try await status(channel, id: close.id, code: 4)
            do { _ = try await listing.value; XCTFail("read failure must escape") }
            catch let error as SFTPMessage.Status { XCTAssertEqual(error.errorCode.rawValue, 3) }
        }
    }

    func testListDirectoryClosesHandleAfterLaterReadFails() async throws {
        try await withClient { client, channel in
            let listing = Task { try await client.listDirectory(atPath: "/srv") }
            defer { listing.cancel() }
            try await openDirectory(channel)
            let first = try await request(channel, type: .readdir)
            try await name(channel, id: first.id, filename: "report.md")
            let next = try await request(channel, type: .readdir)
            try await status(channel, id: next.id, code: 3)
            let close = try await request(channel, type: .close)
            try await status(channel, id: close.id, code: 0)
            do { _ = try await listing.value; XCTFail("later read failure must escape") }
            catch let error as SFTPMessage.Status { XCTAssertEqual(error.errorCode.rawValue, 3) }
        }
    }

    func testGetAttributesSendsStatAndPreservesMissingStatus() async throws {
        try await withClient { client, channel in
            let stat = Task { try await client.getAttributes(at: "/srv/link.md") }
            defer { stat.cancel() }
            let request = try await request(channel, type: .stat)
            XCTAssertEqual(request.argument, "/srv/link.md")
            try await status(channel, id: request.id, code: 2)
            do { _ = try await stat.value; XCTFail("missing stat must escape") }
            catch let error as SFTPMessage.Status { XCTAssertEqual(error.errorCode.rawValue, 2) }
        }
    }

    private func withClient(_ body: (SFTPClient, NIOAsyncTestingChannel) async throws -> Void) async throws {
        // This channel is entirely in memory; no socket or SSH connection opens.
        let channel = NIOAsyncTestingChannel()
        let client = try await SFTPClient.setupChannelHanders(channel: channel, logger: Logger(label: "directory-handle-test")).get()
        do {
            try await body(client, channel)
            _ = try await channel.finish()
        } catch {
            _ = try? await channel.finish()
            throw error
        }
    }

    private enum Packet: UInt8 {
        case close = 4
        case opendir = 11
        case readdir = 12
        case realpath = 16
        case stat = 17
        case status = 101
        case handle = 102
        case name = 104
    }

    private struct Request {
        let id: UInt32
        let argument: String
    }

    private enum FixtureError: Error { case requestTimedOut }

    private func request(_ channel: NIOAsyncTestingChannel, type: Packet) async throws -> Request {
        for _ in 0..<1_000 {
            if let message = try await channel.readOutbound(as: SSHChannelData.self) {
                guard case .byteBuffer(var packet) = message.data else { throw SFTPError.invalidResponse }
                _ = try XCTUnwrap(packet.readInteger(as: UInt32.self))
                XCTAssertEqual(packet.readInteger(as: UInt8.self), type.rawValue)
                let id = try XCTUnwrap(packet.readInteger(as: UInt32.self))
                let length = try XCTUnwrap(packet.readInteger(as: UInt32.self))
                return Request(id: id, argument: try XCTUnwrap(packet.readString(length: Int(length))))
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("missing SFTP request \(type)")
        throw FixtureError.requestTimedOut
    }

    private func openDirectory(_ channel: NIOAsyncTestingChannel) async throws {
        let realpath = try await request(channel, type: .realpath)
        XCTAssertEqual(realpath.argument, "/srv")
        try await name(channel, id: realpath.id, filename: "/srv")
        let open = try await request(channel, type: .opendir)
        XCTAssertEqual(open.argument, "/srv")
        var body = ByteBuffer()
        body.writeInteger(open.id)
        writeString("directory-handle", to: &body)
        try await deliver(channel, type: .handle, body: body)
    }

    private func name(_ channel: NIOAsyncTestingChannel, id: UInt32, filename: String) async throws {
        var body = ByteBuffer()
        body.writeInteger(id)
        body.writeInteger(UInt32(1))
        writeString(filename, to: &body)
        writeString("", to: &body)
        body.writeInteger(UInt32(0)) // no file attributes
        try await deliver(channel, type: .name, body: body)
    }

    private func status(_ channel: NIOAsyncTestingChannel, id: UInt32, code: UInt32) async throws {
        var body = ByteBuffer()
        body.writeInteger(id)
        body.writeInteger(code)
        writeString("", to: &body)
        writeString("", to: &body)
        try await deliver(channel, type: .status, body: body)
    }

    private func writeString(_ value: String, to buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt32(value.utf8.count))
        buffer.writeString(value)
    }

    private func deliver(_ channel: NIOAsyncTestingChannel, type: Packet, body: ByteBuffer) async throws {
        var packet = ByteBuffer()
        packet.writeInteger(UInt32(1 + body.readableBytes))
        packet.writeInteger(type.rawValue)
        var body = body
        packet.writeBuffer(&body)
        _ = try await channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(packet)))
    }
}
