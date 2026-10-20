import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

/// Public-API reproduction of apple/swift-nio-ssh#143 / Tessera's iPad SIGTRAP.
/// Two real encrypted SSH pipelines run entirely in memory: no socket, host,
/// simulator, fork internals, or timing sleeps. Keep this test unchanged across
/// dependency migrations so it proves behavior, not just presence of a patch.
final class SSHChannelCloseRegressionTests: XCTestCase {
    func testBufferedStdoutDrainsAfterLocalCloseWithoutWindowAdjust() throws {
        try checkBufferedOutput(type: .channel, closeBeforeRead: true)
    }

    func testBufferedStderrDrainsAfterLocalCloseWithoutWindowAdjust() throws {
        try checkBufferedOutput(type: .stdErr, closeBeforeRead: true)
    }

    func testOpenChannelStillReplenishesReceiveWindow() throws {
        try checkBufferedOutput(type: .channel, closeBeforeRead: false)
    }

    private func checkBufferedOutput(
        type: SSHChannelData.DataType,
        closeBeforeRead: Bool
    ) throws {
        let pair = try InMemorySSH()
        defer { pair.finish() }
        let receiver = OutputRecorder()
        let promise = pair.loop.makePromise(of: Channel.self)
        var opened: Result<Channel, Error>?
        promise.futureResult.whenComplete { opened = $0 }
        pair.clientHandler.createChannel(promise, channelType: .session) { channel, _ in
            channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(receiver)
            }
        }
        try pair.pump()
        let client = try XCTUnwrap(opened, "Channel open must complete within the bounded wire pump").get()
        let server = try XCTUnwrap(pair.serverChild)

        // Fill the advertised receive window without assuming its size: the
        // fork and upstream advertise different windows. Every write completes
        // on the wire, while autoRead=false retains that data at the receiver.
        // Reading it must replenish an OPEN channel, but never a closed one.
        var total = 0
        var completed = 0
        var expectedHash = SHA256()
        while server.isWritable && total < 32 * 1024 * 1024 {
            let count = 32 * 1024
            var data = server.allocator.buffer(capacity: count)
            // Unique sequence headers detect equal-length loss, duplication,
            // and reordering, not just dropping all output to avoid the crash.
            let sequence = UInt64(total / count)
            data.writeInteger(sequence)
            data.writeRepeatingByte(UInt8(truncatingIfNeeded: sequence), count: count - 8)
            expectedHash.update(data: Data(data.readableBytesView))
            server.writeAndFlush(SSHChannelData(type: type, data: .byteBuffer(data))).whenSuccess {
                completed += count
            }
            total += count
            try pair.pump()
        }
        XCTAssertFalse(server.isWritable, "Fixture must exhaust the receive window")
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(completed, total, "All fixture bytes must reach the wire before closing")
        XCTAssertEqual(receiver.bytes, 0, "autoRead=false must retain pending input")
        XCTAssertNil(try pair.client.readOutbound(as: IOData.self))

        if closeBeforeRead {
            client.close(promise: nil)
            pair.loop.run()
            // Hold the local close on the wire: the peer has not acknowledged
            // it, so didClose is false while the SSH state is closedLocally.
            // Discarding this one encrypted wire chunk is only fixture control;
            // finish() closes the parent pipelines without a peer handshake.
            XCTAssertNotNil(try pair.client.readOutbound(as: IOData.self))
            XCTAssertNil(try pair.client.readOutbound(as: IOData.self))
        }

        // The affected dependency fatally asserts here, before the byte checks.
        client.read()
        pair.loop.run()
        XCTAssertEqual(receiver.bytes, total, "Closing must not discard buffered output")
        XCTAssertEqual(receiver.hash.finalize(), expectedHash.finalize(), "Buffered output must remain byte-exact and ordered")
        XCTAssertEqual(receiver.types, [type])
        XCTAssertTrue(receiver.errors.isEmpty, "\(receiver.errors)")
        let windowUpdate = try pair.client.readOutbound(as: IOData.self)
        if closeBeforeRead {
            XCTAssertNil(windowUpdate, "No window update is legal after local close")
        } else {
            XCTAssertNotNil(windowUpdate, "Control: an open channel must replenish its window")
        }
    }
}

private final class OutputRecorder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    var bytes = 0
    var hash = SHA256()
    var types: Set<SSHChannelData.DataType> = []
    var errors: [Error] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let output = unwrapInboundIn(data)
        types.insert(output.type)
        guard case .byteBuffer(let buffer) = output.data else {
            XCTFail("Expected in-memory bytes")
            return
        }
        bytes += buffer.readableBytes
        hash.update(data: Data(buffer.readableBytesView))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        errors.append(error)
    }
}

private final class InMemorySSH {
    let loop = EmbeddedEventLoop()
    let client: EmbeddedChannel
    let server: EmbeddedChannel
    let clientHandler: NIOSSHHandler
    var serverChild: Channel?

    init() throws {
        client = EmbeddedChannel(loop: loop)
        server = EmbeddedChannel(loop: loop)
        var clientConfig = SSHClientConfiguration(
            userAuthDelegate: FixtureClientAuth(),
            serverAuthDelegate: FixtureHostTrust()
        )
        clientConfig.maximumPacketSize = 1 << 18
        clientHandler = NIOSSHHandler(
            role: .client(clientConfig), allocator: client.allocator,
            inboundChildChannelInitializer: nil
        )
        let serverConfig = SSHServerConfiguration(
            hostKeys: [.init(ed25519Key: .init())], userAuthDelegate: FixtureServerAuth()
        )
        let serverHandler = NIOSSHHandler(
            role: .server(serverConfig), allocator: server.allocator
        ) { [weak self] channel, _ in
            self?.serverChild = channel
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        try client.pipeline.syncOperations.addHandler(clientHandler)
        try server.pipeline.syncOperations.addHandler(serverHandler)
        // EmbeddedChannel.connect only activates its pipeline; no socket opens.
        let address = try SocketAddress(unixDomainSocketPath: "/tessera-in-memory-ssh-test")
        try client.connect(to: address).wait()
        try server.connect(to: address).wait()
        try pump()
    }

    func pump() throws {
        for _ in 0..<10_000 {
            loop.run()
            let fromClient = try client.readOutbound(as: IOData.self)
            let fromServer = try server.readOutbound(as: IOData.self)
            if let fromClient { try server.writeInbound(fromClient) }
            if let fromServer { try client.writeInbound(fromServer) }
            if fromClient == nil && fromServer == nil { return }
        }
        XCTFail("SSH fixture did not quiesce within the bounded wire pump")
    }

    func finish() {
        _ = try? client.finish(acceptAlreadyClosed: true)
        _ = try? server.finish(acceptAlreadyClosed: true)
        loop.run()
    }
}

private final class FixtureClientAuth: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(.init(
            username: "in-memory", serviceName: "ssh-connection",
            offer: .password(.init(password: "fixture-only"))
        ))
    }
}

private final class FixtureHostTrust: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private final class FixtureServerAuth: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(.success)
    }
}
