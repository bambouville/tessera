import Foundation
import TmuxControlCore

@_cdecl("tessera_tmux_window_size_replay_decision")
public func tesseraTmuxWindowSizeReplayDecision(
    requestedColumns: Int32,
    requestedRows: Int32,
    observedColumns: Int32,
    observedRows: Int32,
    lastAttemptColumns: Int32,
    lastAttemptRows: Int32
) -> Int32 {
    guard let requested = try? TmuxClientGeometry(
        columns: Int(requestedColumns), rows: Int(requestedRows)
    ) else { return -1 }
    do {
        let observed = try optionalWindowReplayGeometry(observedColumns, observedRows)
        let lastAttempt = try optionalWindowReplayGeometry(lastAttemptColumns, lastAttemptRows)
        return TmuxWindowSizeReplay.decision(
            requested: requested, observed: observed, lastAttempt: lastAttempt
        ).rawValue
    } catch {
        return -1
    }
}

@_cdecl("tessera_tmux_window_size_replay_commands")
public func tesseraTmuxWindowSizeReplayCommands(
    windowID: Int32,
    columns: Int32,
    rows: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard windowID >= 0, outputCapacity >= 0,
          let requested = try? TmuxClientGeometry(columns: Int(columns), rows: Int(rows))
    else { return -1 }
    let commands = TmuxWindowSizeReplay.commands(
        windowID: WindowId(Int(windowID)), requested: requested
    )
    let result = Array(commands.joined(separator: "\n").utf8)
    guard let outputBytes, outputCapacity > 0 else { return Int32(result.count) }
    guard result.count <= outputCapacity else { return -1 }
    result.withUnsafeBufferPointer {
        if let source = $0.baseAddress {
            outputBytes.update(from: source, count: $0.count)
        }
    }
    return Int32(result.count)
}

@_cdecl("tessera_tmux_window_size_replay_confirm")
public func tesseraTmuxWindowSizeReplayConfirm(
    windowID: Int32,
    columns: Int32,
    rows: Int32,
    replyBytes: UnsafePointer<UInt8>?,
    replyCount: Int
) -> Int32 {
    guard windowID >= 0, replyCount >= 0, replyCount <= 256,
          replyCount == 0 || replyBytes != nil,
          let requested = try? TmuxClientGeometry(columns: Int(columns), rows: Int(rows))
    else { return -1 }
    guard let replyBytes, replyCount > 0,
          let reply = String(
            bytes: UnsafeBufferPointer(start: replyBytes, count: replyCount),
            encoding: .utf8
          )
    else { return 0 }
    return TmuxWindowSizeReplay.confirms(
        windowID: WindowId(Int(windowID)), requested: requested, reply: reply
    ) ? 1 : 0
}

/// The tagged size read alone: the confirmation `commands` ends with, and
/// the take-back claim's settle probe (§6.10 rule 5), written in its own
/// write after the claim's fence was acknowledged. Same output contract as
/// `tessera_tmux_window_size_replay_commands`.
@_cdecl("tessera_tmux_window_size_replay_size_query")
public func tesseraTmuxWindowSizeReplaySizeQuery(
    windowID: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard windowID >= 0, outputCapacity >= 0 else { return -1 }
    let result = Array(TmuxWindowSizeReplay.sizeQuery(windowID: WindowId(Int(windowID))).utf8)
    guard let outputBytes, outputCapacity > 0 else { return Int32(result.count) }
    guard result.count <= outputCapacity else { return -1 }
    result.withUnsafeBufferPointer {
        if let source = $0.baseAddress {
            outputBytes.update(from: source, count: $0.count)
        }
    }
    return Int32(result.count)
}

/// The grid a tagged size read reports for `windowID`: `columns << 32 |
/// rows`, 0 for a reply that names another window or is malformed, -1 for
/// invalid arguments. A settle probe's answer is a size, not a match.
@_cdecl("tessera_tmux_window_size_replay_reported_geometry")
public func tesseraTmuxWindowSizeReplayReportedGeometry(
    windowID: Int32,
    replyBytes: UnsafePointer<UInt8>?,
    replyCount: Int
) -> Int64 {
    guard windowID >= 0, replyCount >= 0, replyCount <= 256,
          replyCount == 0 || replyBytes != nil
    else { return -1 }
    guard let replyBytes, replyCount > 0,
          let reply = String(
            bytes: UnsafeBufferPointer(start: replyBytes, count: replyCount),
            encoding: .utf8
          ),
          let geometry = TmuxWindowSizeReplay.reportedGeometry(
            windowID: WindowId(Int(windowID)), reply: reply
          )
    else { return 0 }
    return Int64(geometry.columns) << 32 | Int64(geometry.rows)
}

@_cdecl("tessera_tmux_window_size_replay_proves_exclusive_ownership")
public func tesseraTmuxWindowSizeReplayProvesExclusiveOwnership(
    windowID: Int32,
    controlIdentityBytes: UnsafePointer<UInt8>?,
    controlIdentityCount: Int,
    visibleIdentityBytes: UnsafePointer<UInt8>?,
    visibleIdentityCount: Int,
    inventoryBytes: UnsafePointer<UInt8>?,
    inventoryCount: Int
) -> Int32 {
    guard windowID >= 0,
          validOwnershipBuffer(controlIdentityBytes, controlIdentityCount, maximum: TmuxWindowSizeReplay.maximumIdentityBytes),
          validOwnershipBuffer(visibleIdentityBytes, visibleIdentityCount, maximum: TmuxWindowSizeReplay.maximumIdentityBytes),
          validOwnershipBuffer(inventoryBytes, inventoryCount, maximum: TmuxWindowSizeReplay.maximumInventoryBytes)
    else { return -1 }
    guard let control = ownershipString(controlIdentityBytes, controlIdentityCount),
          let visible = ownershipString(visibleIdentityBytes, visibleIdentityCount),
          let inventory = ownershipString(inventoryBytes, inventoryCount)
    else { return 0 }
    return TmuxWindowSizeReplay.provesExclusiveOwnership(
        windowID: WindowId(Int(windowID)), controlIdentity: control,
        visibleIdentity: visible, inventory: inventory
    ) ? 1 : 0
}

private func validOwnershipBuffer(
    _ bytes: UnsafePointer<UInt8>?, _ count: Int, maximum: Int
) -> Bool {
    count >= 0 && count <= maximum && (count == 0 || bytes != nil)
}

private func ownershipString(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> String? {
    guard let bytes, count > 0 else { return nil }
    return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
}

private func optionalWindowReplayGeometry(
    _ columns: Int32, _ rows: Int32
) throws -> TmuxClientGeometry? {
    if columns == 0, rows == 0 { return nil }
    return try TmuxClientGeometry(columns: Int(columns), rows: Int(rows))
}
