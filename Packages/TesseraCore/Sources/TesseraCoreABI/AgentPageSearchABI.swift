import Foundation
import TesseraAgentCore

private struct AgentPageSearchInput: Decodable {
    let wire: Data
    let epoch: String
    let thread: String
    let threadID: AgentThreadID
    let query: String
}

/// Stateless display-only search; original framed bytes retain exact record IDs
/// and numeric fields through JNI. This never grants route or action authority.
@_cdecl("tessera_agent_page_search")
public func tesseraAgentPageSearch(
    inputBytes: UnsafePointer<UInt8>?, inputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard inputCount > 0, inputCount <= 410_000, outputCapacity >= 0, let inputBytes else { return -1 }
    do {
        let input = try JSONDecoder().decode(AgentPageSearchInput.self, from: Data(bytes: inputBytes, count: inputCount))
        guard !input.query.isEmpty, input.query.count <= 512, input.query.utf8.count <= 4096 else { return -1 }
        let page = try AgentIngestionProjection.decode(input.wire, epoch: input.epoch, thread: input.thread)
        let results = AgentNativePageSearch.matches(page: page, threadID: input.threadID, query: input.query)
        let encoded = try JSONEncoder().encode(results)
        guard encoded.count <= 262_144 else { return -1 }
        guard let outputBytes else { return Int32(encoded.count) }
        guard outputCapacity >= encoded.count else { return -1 }
        encoded.withUnsafeBytes { raw in
            if let base = raw.baseAddress { outputBytes.update(from: base.assumingMemoryBound(to: UInt8.self), count: encoded.count) }
        }
        return Int32(encoded.count)
    } catch { return -1 }
}
