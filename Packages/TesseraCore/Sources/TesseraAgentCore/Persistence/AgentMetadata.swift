import Foundation

public struct AgentThreadMetadata: Equatable, Codable, Sendable {
    public let threadID: AgentThreadID
    public var lastReadRecordID: String?
    public var routeToken: UUID?
    public var pinnedTitle: String?
    /// Content-free identity of a completion that was still unread when it
    /// was last persisted (see `AgentThreadSnapshot.unreadCompletionKey`).
    /// A relaunch restores it even after a later neutral hook state, such as
    /// Claude's idle prompt, has overwritten the retained Stop.
    public var unreadCompletionKey: String?
    /// Content-free identity of the newest completion the reader
    /// acknowledged. A retained Stop replayed after a relaunch with this
    /// identity is already read.
    public var acknowledgedCompletionKey: String?

    public init(threadID: AgentThreadID, lastReadRecordID: String? = nil, routeToken: UUID? = nil, pinnedTitle: String? = nil,
                unreadCompletionKey: String? = nil, acknowledgedCompletionKey: String? = nil) {
        self.threadID = threadID
        self.lastReadRecordID = lastReadRecordID
        self.routeToken = routeToken
        self.pinnedTitle = pinnedTitle.map { String($0.prefix(512)) }
        self.unreadCompletionKey = unreadCompletionKey.map { String($0.prefix(128)) }
        self.acknowledgedCompletionKey = acknowledgedCompletionKey.map { String($0.prefix(128)) }
    }
}

/// Deliberately metadata-only: no transcript text, paths, locators, command data, or search excerpts.
public protocol AgentMetadataRepository: Sendable {
    func metadata(for threadID: AgentThreadID) async -> AgentThreadMetadata?
    func save(_ metadata: AgentThreadMetadata) async throws
}
