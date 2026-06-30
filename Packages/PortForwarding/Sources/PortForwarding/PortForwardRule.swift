import Foundation

public struct PortForwardRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var autoStart: Bool
    public var localPort: UInt16
    public var remoteHost: String
    public var remotePort: UInt16
    public var label: String

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        autoStart: Bool = true,
        localPort: UInt16,
        remoteHost: String = "localhost",
        remotePort: UInt16,
        label: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.autoStart = autoStart
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.label = label
    }
}
