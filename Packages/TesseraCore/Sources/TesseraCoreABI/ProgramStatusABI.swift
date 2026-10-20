import Foundation
import TmuxControlCore

/// Version 1 OSC 7501 document shared by the pane runtime and raw monitor.
/// Optional fields are omitted, and monitor ordering and display values survive unchanged.
struct ProgramStatusABIDocument: Encodable {
    let snapshot: ProgramStatusSnapshot

    init(_ snapshot: ProgramStatusSnapshot) { self.snapshot = snapshot }

    private enum CodingKeys: String, CodingKey { case version, revision, terminals }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(snapshot.revision, forKey: .revision)
        try container.encode(snapshot.terminals.map(Terminal.init), forKey: .terminals)
    }

    private struct Terminal: Encodable {
        let snapshot: ProgramStatusTerminalSnapshot
        init(_ snapshot: ProgramStatusTerminalSnapshot) { self.snapshot = snapshot }
        private enum CodingKeys: String, CodingKey { case paneID, primary, latestUnreadResultToken, entries }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let paneID: Int?
            switch snapshot.key {
            case .raw: paneID = nil
            case .pane(let pane): paneID = pane.rawValue
            }
            let primary = snapshot.primaryEntry.flatMap { primary in
                snapshot.entries.firstIndex { $0.idPath == primary.idPath }
            }
            try container.encodeIfPresent(paneID, forKey: .paneID)
            try container.encodeIfPresent(primary, forKey: .primary)
            try container.encodeIfPresent(snapshot.latestUnreadResultToken, forKey: .latestUnreadResultToken)
            try container.encode(snapshot.entries.map(Entry.init), forKey: .entries)
        }
    }

    private struct Entry: Encodable {
        let entry: ProgramStatusEntry
        init(_ entry: ProgramStatusEntry) { self.entry = entry }
        private enum CodingKeys: String, CodingKey {
            case idPath, state, kind, progress, app, title, message, historical, unreadResult
            case updateToken, resultToken, attention
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let attention: String?
            switch entry.attention {
            case .needsInput: attention = "needsInput"
            case .failed: attention = "failed"
            case .finished: attention = "finished"
            case nil: attention = nil
            }
            try container.encode(entry.idPath, forKey: .idPath)
            try container.encode(entry.state.rawValue, forKey: .state)
            try container.encodeIfPresent(entry.kind?.rawValue, forKey: .kind)
            try container.encodeIfPresent(entry.progress, forKey: .progress)
            try container.encodeIfPresent(entry.app, forKey: .app)
            try container.encodeIfPresent(entry.title, forKey: .title)
            try container.encodeIfPresent(entry.message, forKey: .message)
            try container.encode(entry.isHistorical, forKey: .historical)
            try container.encode(entry.isUnreadResult, forKey: .unreadResult)
            try container.encode(entry.updateToken, forKey: .updateToken)
            try container.encodeIfPresent(entry.resultToken, forKey: .resultToken)
            try container.encodeIfPresent(attention, forKey: .attention)
        }
    }

    /// A short buffer is refused before any byte is written, including zero capacity.
    func copy(to output: UnsafeMutablePointer<UInt8>?, capacity: Int) -> Int32 {
        guard let data = try? SharedABI.encoder.encode(self), data.count <= Int(Int32.max) else { return -1 }
        guard let output else { return Int32(data.count) }
        guard capacity >= data.count else { return -1 }
        data.copyBytes(to: output, count: data.count)
        return Int32(data.count)
    }
}

private final class CProgramStatusMonitor {
    private let lock = NSLock()
    private var monitor = ProgramStatusMonitor(answersQueries: true)
    private var isDestroyed = false

    init() { monitor.isEnabled = false }

    func withMonitor(_ body: (inout ProgramStatusMonitor) -> Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isDestroyed else { return -2 }
        return body(&monitor)
    }

    func destroy() {
        lock.lock()
        defer { lock.unlock() }
        isDestroyed = true
        monitor.isEnabled = false
    }
}

/// Opaque, never-dereferenced tokens retain objects across concurrent lookups.
/// Removal rejects new calls; the object's lock rejects lookups racing destruction.
private enum CProgramStatusRegistry {
    private static let lock = NSLock()
    private static var nextToken: UInt = 1
    private static var monitors: [UInt: CProgramStatusMonitor] = [:]

    static func insert(_ monitor: CProgramStatusMonitor) -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        monitors[token] = monitor
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    static func withMonitor(_ handle: UnsafeMutableRawPointer?, _ body: (inout ProgramStatusMonitor) -> Int32) -> Int32 {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return -2 }
        lock.lock()
        let monitor = monitors[token]
        lock.unlock()
        return monitor?.withMonitor(body) ?? -2
    }

    static func remove(_ handle: UnsafeMutableRawPointer?) -> CProgramStatusMonitor? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return monitors.removeValue(forKey: token)
    }
}

@_cdecl("tessera_program_status_monitor_create")
public func tesseraProgramStatusMonitorCreate() -> UnsafeMutableRawPointer {
    CProgramStatusRegistry.insert(CProgramStatusMonitor())
}

@_cdecl("tessera_program_status_monitor_destroy")
public func tesseraProgramStatusMonitorDestroy(handle: UnsafeMutableRawPointer?) {
    CProgramStatusRegistry.remove(handle)?.destroy()
}

@_cdecl("tessera_program_status_monitor_set_enabled")
public func tesseraProgramStatusMonitorSetEnabled(handle: UnsafeMutableRawPointer?, enabled: Int32) -> Int32 {
    CProgramStatusRegistry.withMonitor(handle) { monitor in
        monitor.isEnabled = enabled != 0
        return 0
    }
}

@_cdecl("tessera_program_status_monitor_feed")
public func tesseraProgramStatusMonitorFeed(
    handle: UnsafeMutableRawPointer?, bytes: UnsafePointer<UInt8>?, count: Int,
    reply: UnsafeMutablePointer<UInt8>?, replyCapacity: Int, revisionOut: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    CProgramStatusRegistry.withMonitor(handle) { monitor in
        guard count >= 0, count <= SharedABI.maximumInputBytes, bytes != nil || count == 0,
              replyCapacity >= 0, reply != nil || replyCapacity == 0 else { return -1 }
        // Every raw SSH read lands here; a disabled monitor reads nothing.
        guard monitor.isEnabled else {
            revisionOut?.pointee = monitor.revision
            return 0
        }
        let input = Array(UnsafeBufferPointer(start: bytes, count: count))
        let replies = monitor.feed(input[...], terminal: .raw)
        revisionOut?.pointee = monitor.revision
        // All shared-monitor replies are ProgramStatusReply.query. Copy only whole replies.
        let replySize = ProgramStatusReply.query.count
        let copied = min(replies.count, replyCapacity / replySize * replySize)
        if let reply, copied > 0 {
            replies.withUnsafeBufferPointer { reply.update(from: $0.baseAddress!, count: copied) }
        }
        return Int32(copied)
    }
}

@_cdecl("tessera_program_status_monitor_copy_snapshot")
public func tesseraProgramStatusMonitorCopySnapshot(
    handle: UnsafeMutableRawPointer?, outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    CProgramStatusRegistry.withMonitor(handle) {
        ProgramStatusABIDocument($0.snapshot()).copy(to: outputBytes, capacity: outputCapacity)
    }
}

@_cdecl("tessera_program_status_monitor_acknowledge")
public func tesseraProgramStatusMonitorAcknowledge(handle: UnsafeMutableRawPointer?, through: UInt64) -> Int32 {
    CProgramStatusRegistry.withMonitor(handle) { monitor in
        let before = monitor.revision
        monitor.acknowledge(terminal: .raw, through: through)
        return monitor.revision != before ? 1 : 0
    }
}

@_cdecl("tessera_program_status_monitor_note_transport_lost")
public func tesseraProgramStatusMonitorNoteTransportLost(handle: UnsafeMutableRawPointer?) -> Int32 {
    CProgramStatusRegistry.withMonitor(handle) { monitor in
        monitor.noteTransportLost()
        return 0
    }
}
