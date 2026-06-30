import Foundation

/// tmux session id. Wire format: `$<number>`.
public struct SessionId: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "$\(rawValue)" }
}

/// tmux window id. Wire format: `@<number>`.
public struct WindowId: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "@\(rawValue)" }
}

/// tmux pane id. Wire format: `%<number>`.
public struct PaneId: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { "%\(rawValue)" }
}
