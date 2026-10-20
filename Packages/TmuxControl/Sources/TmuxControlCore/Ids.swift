import Foundation

/// tmux session id. Wire format: `$<number>`.
public struct SessionId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "$\(rawValue)" }

    public init?(wireValue: String) {
        guard let value = TmuxObjectIDParser.parse(wireValue, prefix: 0x24) else { return nil }
        self.init(value)
    }
}

/// tmux window id. Wire format: `@<number>`.
public struct WindowId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "@\(rawValue)" }

    public init?(wireValue: String) {
        guard let value = TmuxObjectIDParser.parse(wireValue, prefix: 0x40) else { return nil }
        self.init(value)
    }
}

/// tmux pane id. Wire format: `%<number>`.
public struct PaneId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "%\(rawValue)" }

    public init?(wireValue: String) {
        guard let value = TmuxObjectIDParser.parse(wireValue, prefix: 0x25) else { return nil }
        self.init(value)
    }
}

private enum TmuxObjectIDParser {
    static func parse(_ raw: String, prefix: UInt8) -> Int? {
        let bytes = Array(raw.utf8)
        guard bytes.count >= 2, bytes[0] == prefix else { return nil }
        guard bytes.dropFirst().allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: bytes.dropFirst(), as: UTF8.self))
    }
}
