import NIO
import Crypto
import Logging
import NIOSSH

/// Configuration supported by upstream NIOSSH. Tessera leaves this at its
/// default, preserving the upstream cipher set. Fork-only custom KEX/RSA
/// registration and the unused legacy `.all` preset are intentionally absent.
public struct SSHAlgorithms: Sendable {
    public enum Modification<T: Sendable>: Sendable {
        case replace(with: [T])
        case add([T])
    }

    public var transportProtectionSchemes: Modification<NIOSSHTransportProtection.Type>?

    public init() {}

    func apply(to clientConfiguration: inout SSHClientConfiguration) {
        apply(to: &clientConfiguration.transportProtectionSchemes)
    }

    func apply(to serverConfiguration: inout SSHServerConfiguration) {
        apply(to: &serverConfiguration.transportProtectionSchemes)
    }

    private func apply(to schemes: inout [NIOSSHTransportProtection.Type]) {
        switch transportProtectionSchemes {
        case .add(let additions): schemes.append(contentsOf: additions)
        case .replace(let replacements): schemes = replacements
        case nil: break
        }
    }
}

/// Represents an SSH connection.
public final class SSHClient {
    private(set) var session: SSHClientSession
    private var userInitiatedClose = false
    let authenticationMethod: () -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    internal var connectionSettings = SSHConnectionPoolSettings()
    private let algorithms: SSHAlgorithms
    private let protocolOptions: Set<SSHProtocolOption>
    private var onDisconnect: (@Sendable () -> ())?
    public let logger = Logger(label: "nl.orlandos.citadel.client")
    public var isConnected: Bool {
        session.channel.isActive
    }

    /// The event loop that this SSH connection is running on.
    public var eventLoop: EventLoop {
        session.channel.eventLoop
    }

    init(
        session: SSHClientSession,
        authenticationMethod: @escaping @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption>
    ) {
        self.session = session
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.algorithms = algorithms
        self.protocolOptions = protocolOptions

        onNewSession(session)
    }

    public func onDisconnect(perform onDisconnect: @escaping @Sendable () -> ()) {
        self.onDisconnect = onDisconnect
    }

    /// Connects to an SSH server.
    /// - settings: The settings to use for the connection.
    /// - Returns: An SSH client.
    public static func connect(
        to settings: SSHClientSettings
    ) async throws -> SSHClient {
        let session = try await SSHClientSession.connect(settings: settings)

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    /// Connects to an SSH server.
    /// - settings: The settings to use for the connection.
    /// - Returns: An SSH client.
    public static func connect(
        on channel: Channel,
        settings: SSHClientSettings
    ) async throws -> SSHClient {
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        try await SSHClientSession.addHandlers(
            on: channel,
            inboundChannelHandler: inboundChannelHandler,
            settings: settings
        ).get()

        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let handshakeHandler = try await channel.pipeline.handler(type: ClientHandshakeHandler.self).get()
        let session = try await handshakeHandler.authenticated.map {
            SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
        }.get()

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    /// Installs the SSH pipeline and starts authentication on an already-active
    /// channel without crossing an async executor boundary.
    ///
    /// This method must be invoked from `channel.eventLoop`. Pipeline setup
    /// errors are thrown synchronously; handshake results arrive on the future.
    public static func startConnection(
        on channel: Channel,
        settings: SSHClientSettings
    ) throws -> EventLoopFuture<SSHClient> {
        channel.eventLoop.preconditionInEventLoop()

        let inboundChannelHandler = SSHClientInboundChannelHandler()
        let (sshHandler, handshakeHandler) = try SSHClientSession.addHandlersSync(
            on: channel,
            inboundChannelHandler: inboundChannelHandler,
            settings: settings
        )
        return handshakeHandler.authenticated.map {
            let session = SSHClientSession(
                channel: channel,
                inboundChannelHandler: inboundChannelHandler,
                sshHandler: sshHandler
            )
            return SSHClient(
                session: session,
                authenticationMethod: settings.authenticationMethod(),
                hostKeyValidator: settings.hostKeyValidator,
                algorithms: settings.algorithms,
                protocolOptions: settings.protocolOptions
            )
        }
    }

    public func jump(to settings: SSHClientSettings) async throws -> SSHClient {
        let originatorAddress = try SocketAddress(ipAddress: "fe80::1", port: 22)
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        let channel = try await self.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: settings.host,
                targetPort: settings.port,
                originatorAddress: originatorAddress
            )
        ) { channel in
            SSHClientSession.addHandlers(
                on: channel,
                inboundChannelHandler: inboundChannelHandler,
                settings: settings
            )
        }

        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let handshakeHandler = try await channel.pipeline.handler(type: ClientHandshakeHandler.self).get()
        let session = try await handshakeHandler.authenticated.map {
            SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
        }.get()

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    /// Connects to an SSH server.
    /// - Parameters:
    ///  - channel: The channel to use for the connection.
    /// - authenticationMethod: The authentication method to use. See `SSHAuthenticationMethod` for more information.
    /// - hostKeyValidator: The host key validator to use. See `SSHHostKeyValidator` for more information.
    /// - algorithms: The algorithms to use. See `SSHAlgorithms` for more information.
    /// - protocolOptions: The protocol options to use. See `SSHProtocolOption` for more information.
    /// - Returns: An SSH client.
    public static func connect(
        on channel: Channel,
        authenticationMethod: @escaping @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = []
    ) async throws -> SSHClient {
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        try await SSHClientSession.addHandlers(
            on: channel,
            authenticationMethod: authenticationMethod(),
            inboundChannelHandler: inboundChannelHandler,
            hostKeyValidator: hostKeyValidator,
            protocolOptions: protocolOptions
        ).get()

        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let session = SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)

        return SSHClient(
            session: session,
            authenticationMethod: authenticationMethod(),
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions
        )
    }

    /// Connects to an SSH server.
    /// - Parameters:
    /// - host: The host to connect to.
    /// - port: The port to connect to. Defaults to 22.
    /// - authenticationMethod: The authentication method to use. See `SSHAuthenticationMethod` for more information.
    /// - hostKeyValidator: The host key validator to use. See `SSHHostKeyValidator` for more information.
    /// - reconnect: The reconnect mode to use. See `SSHReconnectMode` for more information.
    /// - algorithms: The algorithms to use. See `SSHAlgorithms` for more information.
    /// - protocolOptions: The protocol options to use. See `SSHProtocolOption` for more information.
    /// - group: The event loop group to use. Defaults to a single-threaded event loop group.
    /// - channelHandlers: Pass in an array of channel prehandlers that execute first. Default empty array
    /// - connectTimeout: Pass in the time before the connection times out. Default 30 seconds.
    /// - Returns: An SSH client.
    public static func connect(
        host: String,
        port: Int = 22,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        reconnect: SSHReconnectMode,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = [],
        group: MultiThreadedEventLoopGroup = .singleton,
        channelHandlers: [ChannelHandler] = [],
        connectTimeout:TimeAmount = .seconds(30)
    ) async throws -> SSHClient {
        let session = try await SSHClientSession.connect(
            host: host,
            port: port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions,
            group: group,
            channelHandlers: channelHandlers,
            connectTimeout: connectTimeout
        )

        let client = SSHClient(
            session: session,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions
        )

        switch reconnect.mode {
        case .always:
            client.connectionSettings.reconnect = .always(to: host, port: port)
        case .once:
            client.connectionSettings.reconnect = .once(to: host, port: port)
        case .never:
            client.connectionSettings.reconnect = .never
        }

        return client
    }

    private func onNewSession(_ session: SSHClientSession) {
        session.channel.closeFuture.whenComplete { [weak self] _ in
            self?.onClose()
        }
    }

    private func onClose() {
        Task {
            self.onDisconnect?()

            switch connectionSettings.reconnect.mode {
            case .never:
                return
            case .once(let host, let port):
                _ = try? await self.recreateSession(host: host, port: port)
            case .always(let host, let port):
                func tryAgain() async throws {
                    do {
                        try await self.recreateSession(host: host, port: port)
                    } catch {
                        return try await tryAgain()
                    }
                }

                _ = try? await tryAgain()
            }
        }
    }

    private func recreateSession(host: String, port: Int) async throws {
        if userInitiatedClose {
            return
        }

        self.session = try await SSHClientSession.connect(
            host: host,
            port: port,
            authenticationMethod: self.authenticationMethod(),
            hostKeyValidator: self.hostKeyValidator,
            protocolOptions: protocolOptions,
            group: session.channel.eventLoop
        )

        onNewSession(session)
    }

    public func close() async throws {
        self.userInitiatedClose = true
        try await self.session.channel.close()
    }
}
