import Foundation
import TmuxControlCore

// MARK: - Inline history deepen gate

/// `TmuxInlineHistoryGate.shouldRequest` for Android. Flags are 0/1; any
/// other flag value returns -1 so a tri-state cannot be passed by accident.
/// Returns 1 when the platform should submit `scrollbackRequested` for the
/// surface, 0 otherwise. Row counts are clamped exactly as the Swift rule
/// clamps them, so both platforms fetch at the same distance from the
/// oldest local row.
@_cdecl("tessera_tmux_inline_history_should_request")
public func tesseraTmuxInlineHistoryShouldRequest(
    canDeepen: Int32,
    requestInFlight: Int32,
    rowsAboveOldest: Int32,
    viewportRows: Int32,
    crossedOldestRow: Int32
) -> Int32 {
    guard let canDeepen = inlineHistoryFlag(canDeepen),
          let requestInFlight = inlineHistoryFlag(requestInFlight),
          let crossedOldestRow = inlineHistoryFlag(crossedOldestRow)
    else { return -1 }
    return TmuxInlineHistoryGate.shouldRequest(
        canDeepen: canDeepen,
        requestInFlight: requestInFlight,
        rowsAboveOldest: Int(rowsAboveOldest),
        viewportRows: Int(viewportRows),
        crossedOldestRow: crossedOldestRow
    ) ? 1 : 0
}

private func inlineHistoryFlag(_ value: Int32) -> Bool? {
    switch value {
    case 0: return false
    case 1: return true
    default: return nil
    }
}
