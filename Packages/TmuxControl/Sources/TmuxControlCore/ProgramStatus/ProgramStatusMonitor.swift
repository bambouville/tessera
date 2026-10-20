import Foundation

private final class ProgramStatusReportTokenAllocator: @unchecked Sendable {
    static let shared = ProgramStatusReportTokenAllocator()
    private let lock = NSLock()
    private var token: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        precondition(token < UInt64.max, "Program status report tokens exhausted")
        token += 1
        return token
    }
}

public enum ProgramStatusTerminalKey: Hashable, Sendable, Comparable {
    case raw
    case pane(PaneId)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.raw, .pane): return true
        case (.pane(let left), .pane(let right)): return left.rawValue < right.rawValue
        default: return false
        }
    }
}

public enum ProgramStatusAttention: Equatable, Sendable {
    case needsInput(ProgramStatusBlockedKind?)
    case failed
    case finished

    public var precedence: Int {
        switch self {
        case .needsInput: return 3
        case .failed: return 2
        case .finished: return 1
        }
    }
}

public struct ProgramStatusEntry: Equatable, Sendable {
    public let terminal: ProgramStatusTerminalKey
    public let idPath: [String]
    public let state: ProgramStatusState
    public let kind: ProgramStatusBlockedKind?
    public let progress: Int?
    public let app: String?
    public let title: String?
    public let message: String?
    public let isHistorical: Bool
    public let isUnreadResult: Bool
    public let updateToken: UInt64
    public let resultToken: UInt64?

    public var attention: ProgramStatusAttention? {
        guard !isHistorical else { return nil }
        switch state {
        case .blocked: return .needsInput(kind)
        case .error: return isUnreadResult ? .failed : nil
        case .done: return isUnreadResult ? .finished : nil
        default: return nil
        }
    }
}

public struct ProgramStatusTerminalSnapshot: Equatable, Sendable {
    public let key: ProgramStatusTerminalKey
    public let entries: [ProgramStatusEntry]

    public var attention: ProgramStatusAttention? {
        primaryEntry?.attention
    }

    /// Stable path order resolves otherwise equal candidates. Attention always
    /// wins over the root fallback, so a blocked child remains discoverable.
    public var primaryEntry: ProgramStatusEntry? {
        let candidates = entries.filter { $0.attention != nil }
        if !candidates.isEmpty {
            return candidates.max {
                let left = $0.attention!.precedence
                let right = $1.attention!.precedence
                if left != right { return left < right }
                if $0.idPath.isEmpty != $1.idPath.isEmpty { return !$0.idPath.isEmpty }
                return $0.updateToken < $1.updateToken
            }
        }
        return entries.first(where: { $0.idPath.isEmpty })
            ?? entries.max { $0.updateToken < $1.updateToken }
    }

    public var latestUnreadResultToken: UInt64? {
        entries.filter(\.isUnreadResult).compactMap(\.resultToken).max()
    }
}

public struct ProgramStatusSnapshot: Equatable, Sendable {
    public static let empty = ProgramStatusSnapshot(revision: 0, terminals: [])
    public let revision: UInt64
    public let terminals: [ProgramStatusTerminalSnapshot]

    public func terminal(_ key: ProgramStatusTerminalKey) -> ProgramStatusTerminalSnapshot? {
        terminals.first { $0.key == key }
    }
}

/// Owns report ordering and lifetime for one session. Scanner state is separate
/// from visible records: clearing records must not lose a split next OSC.
public struct ProgramStatusMonitor: Sendable {
    public static let shellCommands: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh",
        "nu", "elvish", "xonsh", "pwsh", "ash", "busybox",
    ]

    private struct Terminal: Sendable {
        var scanner = ProgramStatusScanner()
        var store = ProgramStatusTerminalStore()
    }

    private let answersQueries: Bool
    private var terminals: [ProgramStatusTerminalKey: Terminal] = [:]
    private var previousSnapshot: TmuxSnapshot?
    /// After a transport loss, the next hydrated window list decides which
    /// historical panes still exist; the rest are removed.
    private var prunesOnHydration = false
    private var enabled = true
    public private(set) var revision: UInt64 = 0

    public init(answersQueries: Bool) {
        self.answersQueries = answersQueries
    }

    public var isEnabled: Bool {
        get { enabled }
        set {
            guard enabled != newValue else { return }
            if terminals.values.contains(where: { !$0.store.isEmpty }) { revision += 1 }
            terminals.removeAll()
            previousSnapshot = nil
            prunesOnHydration = false
            enabled = newValue
            // Tokens deliberately survive settings changes and terminal closes.
        }
    }

    public func snapshot() -> ProgramStatusSnapshot {
        let snapshots = terminals.keys.sorted().compactMap { key -> ProgramStatusTerminalSnapshot? in
            guard let terminal = terminals[key], !terminal.store.isEmpty else { return nil }
            let records = terminal.store.records
            let apps = Dictionary(uniqueKeysWithValues: records.compactMap { record in
                record.app.map { (record.idPath, $0) }
            })
            let entries = records.map { record in
                var app = record.app
                var ancestor = record.idPath
                while app == nil && !ancestor.isEmpty {
                    ancestor.removeLast()
                    app = apps[ancestor]
                }
                return ProgramStatusEntry(
                    terminal: key, idPath: record.idPath, state: record.state,
                    kind: record.kind, progress: record.progress, app: app,
                    title: record.title.flatMap(Self.displayText),
                    message: record.message.flatMap(Self.displayText),
                    isHistorical: record.isHistorical,
                    isUnreadResult: (record.state == .done || record.state == .error)
                        && !record.isResultAcknowledged && !record.isHistorical,
                    updateToken: record.updateToken, resultToken: record.resultToken
                )
            }
            return ProgramStatusTerminalSnapshot(key: key, entries: entries)
        }
        return ProgramStatusSnapshot(revision: revision, terminals: snapshots)
    }

    private static func displayText(_ text: String) -> String? {
        let sanitized = ProgramStatusText.displaySanitized(text)
        return sanitized.isEmpty ? nil : sanitized
    }

    public mutating func feed(_ bytes: ArraySlice<UInt8>, terminal: ProgramStatusTerminalKey) -> [UInt8] {
        guard enabled else { return [] }
        if terminals[terminal]?.scanner.isInNormalState ?? true {
            // Do not create or copy a terminal for ordinary printable data.
            let hasEscape = bytes.withUnsafeBufferPointer { buffer in
                var index = 0
                while index < buffer.count {
                    if buffer[index] == 0x1B { return true }
                    index += 1
                }
                return false
            }
            guard hasEscape else { return [] }
        }
        let events = terminals[terminal, default: Terminal()].scanner.feed(bytes)
        var replies: [UInt8] = []
        for event in events {
            switch event {
            case .sequence(.report(let report)):
                // Replacing a runtime must not reuse a stale acknowledgement's token.
                let token = ProgramStatusReportTokenAllocator.shared.next()
                if terminals[terminal]!.store.apply(report, token: token) { revision += 1 }
            case .sequence(.query):
                if answersQueries && terminal == .raw { replies.append(contentsOf: ProgramStatusReply.query) }
            case .promptStart:
                if terminals[terminal]!.store.dropLiveRecords() { revision += 1 }
            case .reset:
                if terminals[terminal]!.store.removeAll() { revision += 1 }
            }
        }
        return replies
    }

    public mutating func observe(batch: TmuxRuntimeBatch) {
        guard enabled else { return }
        for message in batch.messages {
            switch message {
            case .output(let paneID, let bytes), .extendedOutput(let paneID, _, let bytes):
                _ = feed(bytes[...], terminal: .pane(paneID))
            case .pause(let paneID): noteStreamGap(terminal: .pane(paneID))
            case .exit: markAllHistorical()
            default: break
            }
        }
        defer { previousSnapshot = batch.snapshot }
        if prunesOnHydration, batch.snapshot.isWindowListHydrated {
            prunesOnHydration = false
            let live = Set(batch.snapshot.windows.flatMap(\.panes).map(\.id))
            for key in Array(terminals.keys) {
                if case .pane(let paneID) = key, !live.contains(paneID) { noteTerminalClosed(key) }
            }
            return
        }
        // Most batches carry pane output only; an unchanged topology has
        // nothing to diff.
        guard let previous = previousSnapshot,
              previous.revision != batch.snapshot.revision,
              previous.isWindowListHydrated, batch.snapshot.isWindowListHydrated else { return }
        let currentPanes = batch.snapshot.windows.flatMap(\.panes)
        let current = Dictionary(currentPanes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for pane in previous.windows.flatMap(\.panes) {
            let key = ProgramStatusTerminalKey.pane(pane.id)
            guard let updated = current[pane.id] else {
                noteTerminalClosed(key)
                continue
            }
            if let command = pane.currentCommand, !Self.isShell(command),
               let newCommand = updated.currentCommand, Self.isShell(newCommand),
               terminals[key]?.store.markLiveHistorical() == true {
                revision += 1
            }
        }
    }

    private static func isShell(_ command: String) -> Bool {
        let name = command.hasPrefix("-") ? String(command.dropFirst()) : command
        return shellCommands.contains(name)
    }

    public mutating func noteStreamGap(terminal: ProgramStatusTerminalKey) {
        guard enabled, terminals[terminal] != nil else { return }
        terminals[terminal]!.scanner.reset()
        if terminals[terminal]!.store.markAllHistorical() { revision += 1 }
    }

    public mutating func markAllHistorical() {
        guard enabled else { return }
        for key in Array(terminals.keys) { noteStreamGap(terminal: key) }
    }

    /// The control channel or transport is gone. Every record becomes
    /// historical; once a reconnect hydrates the window list, panes that no
    /// longer exist are removed. The raw terminal keeps its historical
    /// records until a fresh report or the session ends.
    public mutating func noteTransportLost() {
        guard enabled else { return }
        markAllHistorical()
        previousSnapshot = nil
        prunesOnHydration = true
    }

    public mutating func noteTerminalClosed(_ terminal: ProgramStatusTerminalKey) {
        if let removed = terminals.removeValue(forKey: terminal), !removed.store.isEmpty { revision += 1 }
    }

    @discardableResult
    public mutating func acknowledge(terminal: ProgramStatusTerminalKey, through token: UInt64) -> Bool {
        guard enabled, let store = terminals[terminal]?.store else { return false }
        let visibleChange = store.records.contains {
            !$0.isHistorical && !$0.isResultAcknowledged && $0.resultToken.map { $0 <= token } == true
        }
        let changed = terminals[terminal]!.store.acknowledgeResults(through: token)
        if visibleChange { revision += 1 }
        return changed
    }
}
