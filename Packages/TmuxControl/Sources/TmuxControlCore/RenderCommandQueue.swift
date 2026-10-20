/// A command submitted through the shared tmux FIFO.
public struct RenderCommandSubmission: Equatable, Sendable {
    public let tag: UInt64
    public let command: String

    public init(tag: UInt64, command: String) {
        self.tag = tag
        self.command = command
    }
}

/// A client-originated tmux reply, with per-frame parts for a command list.
public struct RenderCommandResult: Codable, Equatable, Sendable {
    public let success: Bool
    public let lines: [String]
    public let parts: [RenderCommandResult]

    public init(success: Bool, lines: [String], parts: [RenderCommandResult] = []) {
        self.success = success
        self.lines = lines
        self.parts = parts
    }

    private enum CodingKeys: String, CodingKey {
        case success, lines, parts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        lines = try container.decode([String].self, forKey: .lines)
        parts = try container.decodeIfPresent([RenderCommandResult].self, forKey: .parts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(success, forKey: .success)
        try container.encode(lines, forKey: .lines)
        if !parts.isEmpty { try container.encode(parts, forKey: .parts) }
    }
}

/// The destination selected when a client-response frame drains the FIFO.
public enum RenderCommandCompletion: Equatable, Sendable {
    case platform(tag: UInt64, result: RenderCommandResult)
    case ledger(token: UInt64, result: RenderCommandResult)
}

/// Portable owner for the one command-response FIFO on a tmux control client.
///
/// `TmuxRuntimeEngine` remains responsible for parsing and classifying frames.
/// This adjacent queue owns command purpose. In particular, hook frames whose
/// opening guard has flags bit 0 clear never consume an entry.
public struct RenderCommandQueue: Sendable {
    private enum Purpose: Sendable {
        case platform(tag: UInt64)
        case ledger(token: UInt64)
    }

    private struct Entry: Sendable {
        let command: String
        let purpose: Purpose
        var expectedFrames: Int = 1
        var parts: [RenderCommandResult] = []
    }

    private var entries: [Entry] = []
    private var nextTag: UInt64 = 1

    public init() {}

    public var pendingCount: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Ledger token at the head of the shared response FIFO. Kept internal so
    /// the render reducer can classify the next correlation without exposing
    /// queue implementation details to either platform adapter.
    var nextLedgerToken: UInt64? {
        guard let first = entries.first else { return nil }
        guard case .ledger(let token) = first.purpose else { return nil }
        return token
    }

    @discardableResult
    public mutating func enqueuePlatform(_ command: String) -> RenderCommandSubmission {
        let tag = allocateTag()
        entries.append(.init(command: command, purpose: .platform(tag: tag)))
        return .init(tag: tag, command: command)
    }

    /// Each element must describe one concrete tmux command. Separators are
    /// rejected here; quoting, comments and command aliases remain tmux syntax.
    @discardableResult
    public mutating func enqueuePlatformList(_ commands: [String]) -> RenderCommandSubmission? {
        guard !commands.isEmpty, commands.allSatisfy({ command in
            !command.isEmpty && !command.utf8.contains { $0 == 0 || $0 == 10 || $0 == 13 || $0 == 59 }
        }) else { return nil }
        if commands.count == 1 { return enqueuePlatform(commands[0]) }
        let tag = allocateTag()
        let command = commands.joined(separator: " ; ")
        entries.append(.init(command: command, purpose: .platform(tag: tag), expectedFrames: commands.count))
        return .init(tag: tag, command: command)
    }

    @discardableResult
    public mutating func enqueueLedger(
        _ command: String,
        token: UInt64
    ) -> RenderCommandSubmission {
        let tag = allocateTag()
        entries.append(.init(command: command, purpose: .ledger(token: token)))
        return .init(tag: tag, command: command)
    }

    /// Roll back reservations only while the adapter still owns the writer
    /// admission lock and proves none of this exact suffix reached the wire.
    public mutating func cancelUnwrittenPlatformSuffix(tags: [UInt64]) -> Bool {
        guard !tags.isEmpty, tags.count <= entries.count else { return false }
        let suffix = entries.suffix(tags.count).compactMap { entry -> UInt64? in
            if case .platform(let tag) = entry.purpose { return tag }
            return nil
        }
        guard suffix == tags else { return false }
        entries.removeLast(tags.count)
        return true
    }

    /// Consume a completed response frame. Server-originated frames and
    /// framing-only events leave the FIFO untouched.
    public mutating func consume(_ event: TmuxCorrelationEvent) -> RenderCommandCompletion? {
        guard case .frameCompleted(let frame) = event, frame.isClientResponse else {
            return nil
        }
        guard !entries.isEmpty else { return nil }
        let part = RenderCommandResult(
            success: frame.status == .success,
            lines: frame.lines
        )
        let result: RenderCommandResult
        if entries[0].expectedFrames > 1 {
            entries[0].parts.append(part)
            // cmdq_fire_command guards each item; cmdq_next calls
            // cmdq_remove_group after an error, so the tail has no replies.
            guard !part.success || entries[0].parts.count == entries[0].expectedFrames else {
                return nil
            }
            result = .init(
                success: entries[0].parts.count == entries[0].expectedFrames
                    && entries[0].parts.allSatisfy(\.success),
                lines: entries[0].parts.flatMap(\.lines),
                parts: entries[0].parts
            )
        } else {
            result = part
        }
        let entry = entries.removeFirst()
        switch entry.purpose {
        case .platform(let tag):
            return .platform(tag: tag, result: result)
        case .ledger(let token):
            return .ledger(token: token, result: result)
        }
    }

    /// Drop every entry up to and including the ledger entry holding `token`,
    /// returning a failed completion for each so no purpose is stranded.
    ///
    /// This is the realignment half of the FIFO synchronisation probe: the
    /// probe's reply is recognised by its content, so whatever is still queued
    /// ahead of it was answered by a frame that belonged to someone else and
    /// can never be completed correctly. Returns nil when the token is not
    /// queued, which means the probe's own entry was already consumed by an
    /// earlier reply and only the state reset is left to do.
    public mutating func drainThrough(ledgerToken token: UInt64) -> [RenderCommandCompletion]? {
        guard let index = entries.firstIndex(where: { entry in
            if case .ledger(let queued) = entry.purpose { return queued == token }
            return false
        }) else { return nil }
        let dropped = entries[...index]
        entries.removeFirst(index + 1)
        return dropped.map { entry in
            let failure = RenderCommandResult(
                success: false,
                lines: entry.parts.flatMap(\.lines),
                parts: entry.parts
            )
            switch entry.purpose {
            case .platform(let tag): return .platform(tag: tag, result: failure)
            case .ledger(let queued): return .ledger(token: queued, result: failure)
            }
        }
    }

    /// The command whose reply the FIFO expects next. Evidence only: a
    /// desynchronisation is invisible in a reply that parses, so the diagnosis
    /// needs to name what the queue believed it was answering.
    public var headCommand: String? { entries.first?.command }

    /// Invalidate every outstanding purpose at a transport boundary. The
    /// platform owns failure delivery to any completion closures it retains.
    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    private mutating func allocateTag() -> UInt64 {
        let tag = nextTag
        nextTag &+= 1
        if nextTag == 0 || nextTag > UInt64(Int64.max) { nextTag = 1 }
        return tag
    }
}
