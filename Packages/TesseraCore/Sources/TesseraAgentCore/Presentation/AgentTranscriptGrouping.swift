import Foundation

/// One entry of a rendered transcript: either a slice of a message or a
/// collapsed run of tool activity.
///
/// Tool calls and their results dominate a live agent transcript, and each one
/// is rarely interesting on its own. Consecutive tool activity, across message
/// boundaries, collapses into a single `toolRun` entry ("12 tool calls ·
/// latest: Bash ls") that the reader can expand into the ordinary per-block
/// cards. Thinking blocks adjacent to tool activity ride along inside the run
/// because they are the same kind of work narration; thinking that stands
/// alone keeps its own card. Android consumes this rule through the ABI's
/// tool-run descriptors; it does not reimplement grouping or summaries.
public enum AgentTranscriptItem: Equatable, Sendable, Identifiable {
    case message(AgentTranscriptMessagePart)
    case toolRun(AgentToolRun)

    public var id: String {
        switch self {
        case .message(let part): return part.id
        case .toolRun(let run): return run.id
        }
    }
}

/// A message, or the part of it that is not inside a tool run. `displayTime`
/// is carried by the last part of its message only, so a split message still
/// shows its timestamp exactly once.
public struct AgentTranscriptMessagePart: Equatable, Sendable {
    public let recordID: String
    public let role: AgentRole
    public let displayTime: Date?
    public let blocks: [AgentBlock]
    public let firstBlockIndex: Int

    public init(recordID: String, role: AgentRole, displayTime: Date?, blocks: [AgentBlock], firstBlockIndex: Int) {
        self.recordID = recordID
        self.role = role
        self.displayTime = displayTime
        self.blocks = blocks
        self.firstBlockIndex = firstBlockIndex
    }

    public var id: String { "\(recordID)#\(firstBlockIndex)" }

    public var message: AgentMessage {
        AgentMessage(recordID: recordID, role: role, displayTime: displayTime, blocks: blocks)
    }
}

public struct AgentToolRunEntry: Equatable, Sendable {
    public let recordID: String
    public let role: AgentRole
    public let blockIndex: Int
    public let block: AgentBlock
    public let displayTime: Date?

    public init(recordID: String, role: AgentRole, blockIndex: Int, block: AgentBlock, displayTime: Date? = nil) {
        self.recordID = recordID
        self.role = role
        self.blockIndex = blockIndex
        self.block = block
        self.displayTime = displayTime
    }

    public var id: String { "\(recordID)#\(blockIndex)" }
}

public struct AgentToolRun: Equatable, Sendable {
    public let entries: [AgentToolRunEntry]

    /// `entries` must not be empty; `AgentTranscriptGrouping.items` never
    /// builds an empty run.
    public init(entries: [AgentToolRunEntry]) {
        self.entries = entries
    }

    /// Keyed by the first entry so appending live output keeps the run's
    /// identity (and the reader's expanded state) stable.
    public var id: String { entries.first?.id ?? "tool-run" }
    public var latestRecordID: String? { entries.last?.recordID }

    public var callCount: Int {
        entries.filter { if case .toolCall = $0.block { return true } else { return false } }.count
    }

    public var resultCount: Int {
        entries.filter { if case .toolResult = $0.block { return true } else { return false } }.count
    }

    public var latestCall: (name: String, preview: String)? {
        for entry in entries.reversed() {
            if case .toolCall(let name, let preview) = entry.block { return (name, preview) }
        }
        return nil
    }

    public var summaryTitle: String {
        let title = AgentTranscriptGrouping.summaryTitle(callCount: callCount, resultCount: resultCount)
        return entries.contains { $0.block == .shortenedPreviewNotice } ? title + " · shortened preview" : title
    }

    public var latestSummary: String? {
        latestCall.map { AgentTranscriptGrouping.latestSummary(name: $0.name, preview: $0.preview) }
    }
}

public enum AgentTranscriptGrouping {
    /// Display-only ABI metadata references existing blocks without duplicating
    /// transcript bodies inside the bounded snapshot frame.
    public struct ToolRunDescriptor: Codable, Equatable, Sendable {
        public let id: String
        public let entryIDs: [String]
        public let summaryTitle: String
        public let latestSummary: String?
    }

    public static func toolRunDescriptors(_ messages: [AgentMessage]) -> [ToolRunDescriptor] {
        items(messages).compactMap {
            guard case .toolRun(let run) = $0 else { return nil }
            return ToolRunDescriptor(id: run.id, entryIDs: run.entries.map(\.id),
                                     summaryTitle: run.summaryTitle, latestSummary: run.latestSummary)
        }
    }

    /// Tool calls and results are the activity a run exists to hide.
    public static func isToolActivity(_ block: AgentBlock) -> Bool {
        switch block {
        case .toolCall, .toolResult: return true
        default: return false
        }
    }

    /// Blocks that may sit inside a run. A run still needs at least one tool
    /// activity block; thinking on its own stays a card.
    public static func isRunMember(_ block: AgentBlock) -> Bool {
        switch block {
        case .toolCall, .toolResult, .thinking: return true
        default: return false
        }
    }

    public static func summaryTitle(callCount: Int, resultCount: Int) -> String {
        if callCount > 0 { return callCount == 1 ? "1 tool call" : "\(callCount) tool calls" }
        return resultCount == 1 ? "1 tool result" : "\(resultCount) tool results"
    }

    /// "latest: Bash · ls -la", one line, bounded.
    public static func latestSummary(name: String, preview: String) -> String {
        let firstLine = preview
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let clipped = firstLine.count > 160 ? String(firstLine.prefix(160)) + "…" : firstLine
        return clipped.isEmpty ? "latest: \(name)" : "latest: \(name) · \(clipped)"
    }

    public static func items(_ messages: [AgentMessage]) -> [AgentTranscriptItem] {
        struct Flat {
            let messageIndex: Int
            let blockIndex: Int
            let block: AgentBlock?
        }
        func isMember(_ entry: Flat) -> Bool {
            guard let block = entry.block else { return false }
            if isRunMember(block) { return true }
            let message = messages[entry.messageIndex]
            // A notice may travel with its tool-only message, but a user or
            // assistant preview warning must not be swallowed by the preceding
            // tool run. Collapsed tool summaries also disclose shortening.
            return block == .shortenedPreviewNotice && message.role == .tool &&
                message.blocks.contains(where: isToolActivity) &&
                message.blocks.allSatisfy { isRunMember($0) || $0 == .shortenedPreviewNotice }
        }
        var flat: [Flat] = []
        for (messageIndex, message) in messages.enumerated() {
            if message.blocks.isEmpty {
                flat.append(Flat(messageIndex: messageIndex, blockIndex: 0, block: nil))
                continue
            }
            for (blockIndex, block) in message.blocks.enumerated() {
                flat.append(Flat(messageIndex: messageIndex, blockIndex: blockIndex, block: block))
            }
        }

        var inRun = [Bool](repeating: false, count: flat.count)
        var start = 0
        while start < flat.count {
            guard isMember(flat[start]) else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < flat.count, isMember(flat[end + 1]) { end += 1 }
            if flat[start...end].contains(where: { $0.block.map(isToolActivity) == true }) {
                for index in start...end { inRun[index] = true }
            }
            start = end + 1
        }

        var items: [AgentTranscriptItem] = []
        var itemMessageIndex: [Int?] = []
        var runEntries: [AgentToolRunEntry] = []
        var partMessageIndex: Int?
        var partFirstBlockIndex = 0
        var partBlocks: [AgentBlock] = []

        func flushPart() {
            guard let messageIndex = partMessageIndex else { return }
            let message = messages[messageIndex]
            items.append(.message(AgentTranscriptMessagePart(
                recordID: message.recordID,
                role: message.role,
                displayTime: nil,
                blocks: partBlocks,
                firstBlockIndex: partFirstBlockIndex
            )))
            itemMessageIndex.append(messageIndex)
            partMessageIndex = nil
            partBlocks = []
        }

        func flushRun() {
            guard !runEntries.isEmpty else { return }
            items.append(.toolRun(AgentToolRun(entries: runEntries)))
            itemMessageIndex.append(nil)
            runEntries = []
        }

        for (index, entry) in flat.enumerated() {
            if inRun[index], let block = entry.block {
                flushPart()
                let message = messages[entry.messageIndex]
                runEntries.append(AgentToolRunEntry(
                    recordID: message.recordID,
                    role: message.role,
                    blockIndex: entry.blockIndex,
                    block: block,
                    displayTime: entry.blockIndex == message.blocks.count - 1 ? message.displayTime : nil
                ))
                continue
            }
            flushRun()
            if partMessageIndex != entry.messageIndex {
                flushPart()
                partMessageIndex = entry.messageIndex
                partFirstBlockIndex = entry.blockIndex
            }
            if let block = entry.block { partBlocks.append(block) }
        }
        flushPart()
        flushRun()

        // The timestamp belongs to the last visible part of each message.
        var stamped = Set<Int>()
        for index in items.indices.reversed() {
            guard let messageIndex = itemMessageIndex[index], !stamped.contains(messageIndex),
                  case .message(let part) = items[index],
                  part.firstBlockIndex + part.blocks.count == messages[messageIndex].blocks.count
            else { continue }
            stamped.insert(messageIndex)
            items[index] = .message(AgentTranscriptMessagePart(
                recordID: part.recordID,
                role: part.role,
                displayTime: messages[messageIndex].displayTime,
                blocks: part.blocks,
                firstBlockIndex: part.firstBlockIndex
            ))
        }
        return items
    }
}
