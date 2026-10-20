import Foundation
import TesseraAgentCore

private let agentMarkdownMaximumInputBytes = 128 * 1024
private let agentMarkdownMaximumOutputBytes = 2 * 1024 * 1024

private func agentMarkdownInput(
    bytes: UnsafePointer<UInt8>?,
    count: Int
) -> String? {
    guard count >= 0, count <= agentMarkdownMaximumInputBytes else { return nil }
    guard count > 0 else { return "" }
    guard let bytes else { return nil }
    return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
}

private func agentMarkdownCopyOut(
    _ value: AgentMarkdownDocument,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard outputCapacity >= 0, let encoded = try? JSONEncoder().encode(value), encoded.count <= agentMarkdownMaximumOutputBytes else {
        return -1
    }
    guard let outputBytes else { return Int32(encoded.count) }
    guard outputCapacity >= encoded.count else { return -1 }
    encoded.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        outputBytes.update(from: base.assumingMemoryBound(to: UInt8.self), count: encoded.count)
    }
    return Int32(encoded.count)
}

/// Parses bounded, valid UTF-8 agent Markdown into a display-only canonical
/// JSON tree. A nil input pointer is valid only for the empty document.
/// Passing a nil output pointer queries the exact required byte count.
@_cdecl("tessera_agent_markdown_parse")
public func tesseraAgentMarkdownParse(
    inputBytes: UnsafePointer<UInt8>?, inputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let input = agentMarkdownInput(bytes: inputBytes, count: inputCount) else { return -1 }
    return agentMarkdownCopyOut(
        AgentMarkdownDocument.parse(input),
        outputBytes: outputBytes,
        outputCapacity: outputCapacity
    )
}
