import Foundation

/// Transcript retention scales with the device. Each platform reports its
/// physical memory once at launch; shared Core owns the tier table so iOS and
/// Android retain comparable history on comparable hardware.
public struct AgentContentBudget: Equatable, Codable, Sendable {
    /// Estimated retained bytes for one conversation: canonical records plus
    /// the messages derived from them.
    public let perThreadBytes: Int
    /// Estimated retained bytes across every cached conversation.
    public let globalBytes: Int

    public init(perThreadBytes: Int, globalBytes: Int) {
        let perThread = min(max(perThreadBytes, 1 << 20), 64 << 20)
        self.perThreadBytes = perThread
        self.globalBytes = min(max(globalBytes, perThread), 256 << 20)
    }

    /// ≤ 3 GB, or a platform-declared low-RAM device.
    public static let compact = Self(perThreadBytes: 4 << 20, globalBytes: 16 << 20)
    /// 4–6 GB.
    public static let standard = Self(perThreadBytes: 8 << 20, globalBytes: 32 << 20)
    /// 8 GB and larger.
    public static let large = Self(perThreadBytes: 16 << 20, globalBytes: 64 << 20)

    /// Devices report somewhat less than their marketed memory, so the tier
    /// boundaries sit between the marketed sizes rather than on them.
    public static func forDevice(physicalMemoryBytes: UInt64, isLowRAMDevice: Bool = false) -> Self {
        let gibibytes = Double(physicalMemoryBytes) / 1_073_741_824
        if isLowRAMDevice || gibibytes < 3.5 { return .compact }
        return gibibytes < 7 ? .standard : .large
    }

    /// Whole wire pages the retained window may hold. Records and their
    /// derived messages each take about half of the per-thread budget.
    public var windowSegments: Int {
        min(AgentIngestionWindowCapacity.maximumSegments, max(AgentIngestionWindowCapacity.legacy.segments, perThreadBytes / 262_144))
    }
}

/// The bounded viewport shared with the remote host. Hosts that do not
/// advertise a larger capacity keep the original four-page window.
public struct AgentIngestionWindowCapacity: Equatable, Codable, Sendable {
    public static let maximumSegments = 64
    public static let recordsPerSegment = 100
    public static let legacy = Self(segments: 4, records: 400, bytes: 1_048_576)

    public let segments: Int
    public let records: Int
    public let bytes: Int

    public init(segments: Int, records: Int, bytes: Int) {
        self.segments = min(max(segments, 1), Self.maximumSegments)
        self.records = min(max(records, 1), self.segments * Self.recordsPerSegment)
        self.bytes = max(bytes, 262_144)
    }

    /// `hostSegments` is the largest viewport the connected host accepts in
    /// an acknowledgement; hosts without `window.capacity.v1` accept four.
    public static func negotiated(budget: AgentContentBudget, hostSegments: Int) -> Self {
        let segments = min(budget.windowSegments, max(legacy.segments, hostSegments))
        guard segments > legacy.segments else { return legacy }
        return .init(segments: segments, records: segments * recordsPerSegment,
                     bytes: max(legacy.bytes, budget.perThreadBytes / 2))
    }
}
