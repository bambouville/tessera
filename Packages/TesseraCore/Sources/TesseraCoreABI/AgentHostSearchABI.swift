import Foundation
import TesseraAgentCore

private struct AgentHostSearchInput: Decodable {
    struct Thread: Decodable { let handle: String; let threadID: AgentThreadID }
    let wire: Data
    let epoch: String
    let requestID: String
    let query: String
    let threads: [Thread]
}

private struct AgentHostSearchOutput: Encodable {
    let results: [AgentSearchResult]
    let skipped: [Skipped]
    let cursor: String?
    let oversizedRecords: UInt64
    struct Skipped: Encodable { let thread: String; let code: String; let pagedFallback: Bool }
}

/// Exact matches in one host `search` response. Original framed bytes keep
/// exact record IDs and numbers through JNI; display-only, like page search.
@_cdecl("tessera_agent_host_search")
public func tesseraAgentHostSearch(
    inputBytes: UnsafePointer<UInt8>?, inputCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard inputCount > 0, inputCount <= 6_000_000, outputCapacity >= 0, let inputBytes else { return -1 }
    do {
        let input = try JSONDecoder().decode(AgentHostSearchInput.self, from: Data(bytes: inputBytes, count: inputCount))
        guard !input.query.isEmpty, input.query.count <= 512, input.query.utf8.count <= 4096, input.threads.count <= 4096 else { return -1 }
        let reply = try AgentHostSearchReply.decode(input.wire, epoch: input.epoch, requestID: input.requestID)
        let threads = Dictionary(input.threads.map { ($0.handle, $0.threadID) }, uniquingKeysWith: { first, _ in first })
        let output = AgentHostSearchOutput(
            results: reply.matches(threads: threads, query: input.query),
            skipped: reply.skipped.map { .init(thread: $0.thread, code: $0.code,
                pagedFallback: AgentHostSearchReply.pagedFallbackCodes.contains($0.code)) },
            cursor: reply.cursor, oversizedRecords: reply.oversizedRecords)
        let encoded = try JSONEncoder().encode(output)
        guard encoded.count <= 1_048_576, encoded.count <= Int(Int32.max) else { return -1 }
        guard let outputBytes else { return Int32(encoded.count) }
        guard outputCapacity >= encoded.count else { return -1 }
        encoded.withUnsafeBytes { raw in
            if let base = raw.baseAddress { outputBytes.update(from: base.assumingMemoryBound(to: UInt8.self), count: encoded.count) }
        }
        return Int32(encoded.count)
    } catch { return -1 }
}
