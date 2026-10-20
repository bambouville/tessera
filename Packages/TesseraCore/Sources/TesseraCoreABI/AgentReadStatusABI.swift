import Foundation
import TesseraAgentCore

@_cdecl("tessera_agent_ingestion_read_status")
public func tesseraAgentIngestionReadStatus(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let requestBytes, requestCount > 0, requestCount <= 4096,
          let status = try? JSONDecoder().decode(AgentIngestionReadStatus.self,
              from: Data(bytes: requestBytes, count: requestCount)) else { return -1 }
    struct Reply: Encodable {
        let state: AgentIngestionReadStatus.State
        let domain: AgentIngestionReadStatus.Domain
        let recovery: AgentIngestionReadStatus.Recovery
        let code: String
        let message: String
        let isProgress: Bool
        let survivesReaderClosure: Bool
    }
    let reply = Reply(state: status.state, domain: status.domain, recovery: status.recovery,
        code: status.code, message: status.message, isProgress: status.isProgress,
        survivesReaderClosure: status.survivesReaderClosure)
    guard let data = try? SharedABI.encoder.encode(reply), data.count <= Int32.max else { return -1 }
    if outputBytes == nil || outputCapacity == 0 { return Int32(data.count) }
    guard let outputBytes, outputCapacity >= data.count else { return -1 }
    data.copyBytes(to: outputBytes, count: data.count)
    return Int32(data.count)
}
