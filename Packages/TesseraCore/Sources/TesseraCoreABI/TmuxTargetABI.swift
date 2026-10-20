import Foundation
import TesseraProtocolCore
import TmuxControlCore

/// Copies the shared automatic-tmux session name as UTF-8.
/// Returns the byte count (always 16 today), or -1 for invalid arguments.
@_cdecl("tessera_tmux_default_session_name")
public func tesseraTmuxDefaultSessionName(
    hostKeyBytes: UnsafePointer<UInt8>?,
    hostKeyCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let hostKeyBytes, hostKeyCount > 0,
          let outputBytes, outputCapacity > 0
    else { return -1 }
    let hostKey = String(
        decoding: UnsafeBufferPointer(start: hostKeyBytes, count: hostKeyCount),
        as: UTF8.self
    )
    let result = Array(AutomaticTmuxTarget.sessionName(forHostKey: hostKey).utf8)
    guard result.count <= outputCapacity else { return -1 }
    result.withUnsafeBytes { raw in
        guard let baseAddress = raw.baseAddress else { return }
        outputBytes.update(from: baseAddress.assumingMemoryBound(to: UInt8.self), count: result.count)
    }
    return Int32(result.count)
}

/// Validates a tmux session name against the one shared grammar.
///
/// Returns 0 when the name is usable, 1 empty, 2 too long (over 256 UTF-8
/// bytes), 3 unsafe characters, and -1 only for a genuinely malformed
/// argument — a negative count or bytes that are not UTF-8. The codes are
/// distinct so a platform can show a field-level message without keeping its
/// own charset literal — three copies of that literal on Android had already
/// drifted apart.
///
/// Size is answered, never refused: a name of any length past the ceiling is
/// `tooLong` (2), because a wrapper that maps -1 onto a programming error
/// would otherwise crash on a pathologically long paste instead of showing
/// the field message this code exists to provide.
///
/// The grammar is deliberately conservative — ASCII alphanumerics plus `-`,
/// `_`, `.` — because these names are interpolated into fixed remote commands
/// without shell quoting.
@_cdecl("tessera_tmux_session_name_validate")
public func tesseraTmuxSessionNameValidate(
    nameBytes: UnsafePointer<UInt8>?,
    nameCount: Int
) -> Int32 {
    // An empty name is a real answer (code 1), not a missing argument, so a
    // zero-length buffer is accepted here rather than rejected.
    if nameBytes == nil || nameCount == 0 { return 1 }
    guard nameCount > 0 else { return -1 }
    // Over the ceiling is `tooLong`, decided on the byte count alone: it is
    // the same verdict the grammar would reach, and reaching it here means an
    // arbitrarily long paste is never materialised as a String just to be
    // rejected.
    if nameCount > TmuxTargetValidation.maximumSessionNameBytes { return 2 }
    guard let name = SharedABI.requiredString(nameBytes, nameCount)
    else { return -1 }
    switch TmuxSessionName.validationError(for: name) {
    case nil: return 0
    case .empty: return 1
    case .tooLong: return 2
    case .unsafeCharacter: return 3
    }
}

/// Validates a tmux object ID: `kind` 0 = session (`$123`), 1 = window
/// (`@7`), 2 = pane (`%9`). Returns 1 valid, 0 invalid, -1 for invalid
/// arguments.
@_cdecl("tessera_tmux_target_id_validate")
public func tesseraTmuxTargetIDValidate(
    valueBytes: UnsafePointer<UInt8>?,
    valueCount: Int,
    kind: Int32
) -> Int32 {
    guard let value = SharedABI.requiredString(valueBytes, valueCount, maximum: 256)
    else { return -1 }
    switch kind {
    case 0: return TmuxTargetValidation.isSessionID(value) ? 1 : 0
    case 1: return TmuxTargetValidation.isWindowID(value) ? 1 : 0
    case 2: return TmuxTargetValidation.isPaneID(value) ? 1 : 0
    default: return -1
    }
}
