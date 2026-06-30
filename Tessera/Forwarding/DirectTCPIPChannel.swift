import Citadel
import Foundation
import NIO
import NIOCore
import NIOSSH

public enum DirectTCPIPError: Error {
    case originatorAddressFailed
    case channelOpenFailed(underlying: Error)
    case asyncWrapFailed(underlying: Error)
}

// Opens a direct-tcpip SSH channel through client to (remoteHost, remotePort)
// and returns it wrapped as NIOAsyncChannel<ByteBuffer, ByteBuffer> for
// ergonomic async iteration / writing. Caller is responsible for closing.
public func openDirectTCPIP(
    over client: SSHClient,
    remoteHost: String,
    remotePort: UInt16,
    debugID: UUID? = nil
) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
    let logID = debugID.map { String($0.uuidString.prefix(8)) } ?? "unknown"
    DiagnosticLogStore.appendForwarding("direct-tcpip open begin id=\(logID) targetPort=\(remotePort)")

    let originatorAddress: SocketAddress
    do {
        originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
    } catch {
        DiagnosticLogStore.appendForwarding("direct-tcpip originator failed id=\(logID) error='\(error)'")
        throw DirectTCPIPError.originatorAddressFailed
    }

    let settings = SSHChannelType.DirectTCPIP(
        targetHost: remoteHost,
        targetPort: Int(remotePort),
        originatorAddress: originatorAddress
    )

    let channel: Channel
    do {
        channel = try await client.createDirectTCPIPChannel(
            using: settings,
            initialize: { ch in
                ch.eventLoop.makeSucceededVoidFuture()
            }
        )
    } catch {
        DiagnosticLogStore.appendForwarding("direct-tcpip open failed id=\(logID) targetPort=\(remotePort) error='\(error)'")
        throw DirectTCPIPError.channelOpenFailed(underlying: error)
    }

    do {
        // `wrappingChannelSynchronously` precondition-fails if not running
        // on the channel's event loop. `makeCompletedFuture(withResultOf:)`
        // executes the closure on the CALLING thread (not the EL), so we
        // need `submit { ... }` which actually schedules onto the EL.
        let asyncChannel = try await channel.eventLoop.submit {
            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: channel
            )
        }.get()

        DiagnosticLogStore.appendForwarding("direct-tcpip open ok id=\(logID) targetPort=\(remotePort)")
        return asyncChannel
    } catch {
        DiagnosticLogStore.appendForwarding("direct-tcpip async-wrap failed id=\(logID) error='\(error)'")
        try? await channel.close().get()
        throw DirectTCPIPError.asyncWrapFailed(underlying: error)
    }
}
