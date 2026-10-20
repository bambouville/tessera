import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Compile-only app dependencies; neither diagnostics nor remote installs run.
final class FileBridge {
    func connect() async throws {}
    func exec(_ command: String, inShell: Bool) async throws -> String { "" }
}
enum DiagnosticLogStore {
    static func appendAgentCenter(_ message: String) {} // Never export content.
}

private func monotonicNS() -> UInt64 {
    var value = timespec()
    clock_gettime(CLOCK_MONOTONIC, &value)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private actor CapturedStream: AgentExecStream {
    var frames: [AgentExecFrame]
    var index = 0
    init(data: Data, generation: UInt64, status: Int32) {
        frames = stride(from: 0, to: data.count, by: 4093).map { offset in
            AgentExecFrame(carrierGeneration: generation,
                           kind: .stdout(data.subdata(in: offset..<min(offset + 4093, data.count))))!
        }
        frames.append(AgentExecFrame(carrierGeneration: generation, kind: .exit(status: status))!)
    }
    func nextFrame() async throws -> AgentExecFrame? {
        guard index < frames.count else { return nil }
        defer { index += 1 }
        return frames[index]
    }
    func cancel() async {}
}

private struct CapturedExec: AgentRemoteExecPort {
    let data: Data
    let status: Int32
    func execute(_ request: AgentExecRequest) async throws -> AgentExecStream {
        CapturedStream(data: data, generation: request.binding.carrierGeneration, status: status)
    }
}

@main
struct FirstPageConsumer {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 2,
                  let provider = AgentProviderID(rawValue: CommandLine.arguments[1]) else { exit(64) }
            let native = CommandLine.arguments.contains("--native")
            let status = !native && CommandLine.arguments.count > 2 ? Int32(CommandLine.arguments[2]) ?? 1 : 0
            var data = Data()
            while let bytes = try FileHandle.standardInput.read(upToCount: 65_536), !bytes.isEmpty {
                guard data.count + bytes.count <= 2_097_152 else { exit(65) }
                data.append(bytes)
            }
            let started = monotonicNS()
            let hostID = UUID()
            var thread = AgentThreadID(hostID: hostID, providerID: provider, providerSessionID: "cold-fixture")!
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("cold-fixture")!, transport: .ssh, capabilities: [.observe])
            let runtime = AgentCenterRuntime()
            let endpoint = AppleAgentProjectionEndpoint.projector(exec: CapturedExec(data: data, status: status))
            let channel = AppleAgentRemoteDataChannel(binding: binding, endpoint: endpoint)
            let request = AgentProjectionRequest(kind: .project, providerID: provider, transcriptRef: "cold-fixture")!
            var count = 0
            var captured: [AgentProjectionPage] = []
            var inventory: [[String: AgentJSONValue]] = []
            var nativeThread: String?
            if native {
                var framer = AgentIngestionFramer()
                var decoder: AgentIngestionPageDecoder?
                try framer.append(data) { frame in
                    let object = try JSONDecoder().decode(AgentJSONValue.self, from: frame).objectValue
                    if object?["kind"]?.stringValue == "hello", let epoch = object?["serviceEpoch"]?.stringValue {
                        decoder = try AgentIngestionPageDecoder(epoch: epoch)
                    }
                    if let object, object["kind"]?.stringValue == "inventory.thread" {
                        guard inventory.count < 16384 else { throw AgentProjectionError.malformed }
                        inventory.append(object)
                    }
                    if let page = try decoder?.accept(frame) { captured.append(page.page); nativeThread = page.thread }
                }
                try framer.finish(); try decoder?.finish()
            } else {
                for try await page in try await channel.project(request) { captured.append(page) }
            }
            var inventoryIDs = Set<AgentThreadID>()
            for row in inventory {
                guard let providerName = row["provider"]?.stringValue,
                      let inventoryProvider = AgentProviderID(rawValue: providerName),
                      let sessionID = row["sessionID"]?.stringValue,
                      let id = AgentThreadID(hostID: hostID, providerID: inventoryProvider, providerSessionID: sessionID)
                else { throw AgentProjectionError.malformed }
                inventoryIDs.insert(id)
                await runtime.register(.init(id: id, providerName: providerName,
                    availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: true)))
                if row["thread"]?.stringValue == nativeThread { thread = id }
            }
            if !inventoryIDs.contains(thread) {
                await runtime.register(.init(id: thread, providerName: provider.rawValue,
                    availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false)))
            }
            _ = await runtime.listSnapshot()
            for page in captured {
                let applied = await runtime.apply(page: page, to: thread)
                if applied == .capacityExceeded {
                    FileHandle.standardOutput.write(Data("{\"capacityExceeded\":true}\n".utf8)); return
                }
                guard applied == .applied || (native && applied == .sourceReset),
                      let snapshot = await runtime.snapshot(for: thread) else {
                    throw AgentProjectionError.malformed
                }
                let ready = monotonicNS()
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                #if canImport(Darwin)
                let rss = usage.ru_maxrss
                #else
                let rss = usage.ru_maxrss * 1024
                #endif
                var result: [String: Any] = ["ready_monotonic_ns": ready,
                    "consumer_work_ms": Double(ready - started) / 1_000_000,
                    "consumer_peak_rss_bytes": rss, "renderable_records": page.records.count,
                    "inventory_model_threads": inventoryIDs.count,
                    "renderable_messages": snapshot.messages.count]
                if let window = snapshot.ingestionWindow {
                    result["window"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(window))
                }
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
                FileHandle.standardOutput.write(Data([10]))
                count += 1
            }
            guard count == 1 else { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("page_not_renderable\n".utf8))
            exit(1)
        }
    }
}
