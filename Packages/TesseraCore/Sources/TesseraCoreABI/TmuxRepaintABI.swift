import Foundation
import TmuxControlCore

@_cdecl("tessera_tmux_assemble_repaint")
public func tesseraTmuxAssembleRepaint(
    metadataBytes: UnsafePointer<UInt8>?,
    metadataCount: Int,
    captureBytes: UnsafePointer<UInt8>?,
    captureCount: Int,
    terminalIsInAltScreen: Int32,
    clientRows: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let metadataBytes, metadataCount > 0,
          let captureBytes, captureCount >= 0
    else { return -1 }
    let metadata = String(
        decoding: UnsafeBufferPointer(start: metadataBytes, count: metadataCount),
        as: UTF8.self
    )
    guard let state = TmuxRenderedPaneStateParser.parse(metadata) else { return -1 }
    let capture = String(
        decoding: UnsafeBufferPointer(start: captureBytes, count: captureCount),
        as: UTF8.self
    )
    let lines = capture.split(separator: "\n", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }
    let result = TmuxRepaintAssembly.assemble(
        state: state,
        captureLines: lines,
        historyLines: [],
        savedPrimaryLines: [],
        altScreenLines: nil,
        terminalIsInAltScreen: terminalIsInAltScreen != 0,
        clientRows: clientRows > 0 ? Int(clientRows) : nil,
        preservePrimaryDuringAltRefresh: state.paneInAltScreen && terminalIsInAltScreen != 0
    )
    guard result.count <= Int(Int32.max) else { return -1 }
    guard let outputBytes else { return Int32(result.count) }
    guard outputCapacity >= result.count else { return -1 }
    result.withUnsafeBytes { raw in
        guard let baseAddress = raw.baseAddress else { return }
        outputBytes.update(from: baseAddress.assumingMemoryBound(to: UInt8.self), count: result.count)
    }
    return Int32(result.count)
}
