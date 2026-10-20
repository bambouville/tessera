import Foundation
import CryptoKit
import TesseraCore

/// Apple transport convenience for the portable v9 integration command source.
/// The command construction and provider-config merge policy live in
/// `TesseraAgentCore` so Android receives the exact same bytes through its ABI.
extension RemoteAgentLifecycleIntegrationInstaller {
    static func probe(
        using bridge: FileBridge,
        diagnostic: ((String) -> Void)? = nil
    ) async throws -> AgentLifecycleHostInstallation {
        try await probe(
            execute: { command in
                try await bridge.connect()
                return try await bridge.exec(command, inShell: true)
            },
            diagnostic: diagnostic
        )
    }

    static func install(using bridge: FileBridge) async throws {
        // An explicit installation may acquire its carrier once. Abort must
        // never reconnect or wait for fresh authentication after cancellation.
        try await bridge.connect()
        try await installNativeAndLifecycle { command in
            return try await bridge.executeAgentInstallationCommand(command)
        }
    }

    static func installNativeAndLifecycle(execute: @escaping (String) async throws -> String) async throws {
        try await installNativeHost(execute: execute)
        try await install(execute: execute)
    }

    /// Artifact-only deployment is also used by authenticated fixture gates;
    /// probing the ingestion data plane must not rewrite provider hook settings.
    static func installNativeHost(execute: @escaping (String) async throws -> String) async throws {
        func invoke(_ request: AgentHostDeployment.Request) async throws -> [String: Any] {
            let output = try await execute(AgentHostDeployment.command(request))
            guard output.utf8.count <= 4096,
                  let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            else { throw AgentLifecycleIntegrationInstallError.verificationFailed("artifact reply") }
            return result
        }
        let probe = try await invoke(.init(operation: "probe"))
        // Checked before any upload, so a newer app's host is never touched.
        if probe["newerIntegration"] as? Bool == true {
            throw AgentLifecycleIntegrationInstallError.newerInstalled
        }
        guard let target = probe["target"] as? String,
              ["darwin-arm64", "darwin-x86_64", "linux-aarch64", "linux-x86_64"].contains(target),
              let resources = Bundle.main.resourceURL?.appendingPathComponent("agent-host"),
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("manifest.json"))) as? [String: Any],
              let entries = manifest["artifacts"] as? [[String: Any]],
              let entry = entries.first(where: { $0["target"] as? String == target }),
              let digest = entry["sha256"] as? String, let size = entry["bytes"] as? Int,
              (1...AgentHostDeployment.maximumArtifactBytes).contains(size)
        else { throw AgentLifecycleIntegrationInstallError.verificationFailed("artifact unavailable") }
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("tessera-agent-host-" + target + ".lzfse"), options: .mappedIfSafe),
              let artifact = try? (data as NSData).decompressed(using: .lzfse) as Data
        else { throw AgentLifecycleIntegrationInstallError.verificationFailed("artifact unavailable") }
        guard artifact.count == size, SHA256.hash(data: artifact).map({ String(format: "%02x", $0) }).joined() == digest
        else { throw AgentLifecycleIntegrationInstallError.verificationFailed("bundled artifact checksum") }
        let upload = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func request(_ operation: String, offset: Int? = nil, content: String? = nil) -> AgentHostDeployment.Request {
            .init(operation: operation, upload: upload, sha256: digest, bytes: size, offset: offset, content: content)
        }
        do {
            guard try await invoke(request("begin"))["ready"] as? Bool == true else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed("artifact staging")
            }
            for offset in stride(from: 0, to: artifact.count, by: AgentHostDeployment.chunkBytes) {
                try Task.checkCancellation()
                let chunk = artifact.subdata(in: offset..<min(artifact.count, offset + AgentHostDeployment.chunkBytes))
                guard try await invoke(request("write", offset: offset, content: chunk.base64EncodedString()))["written"] as? Bool == true else {
                    throw AgentLifecycleIntegrationInstallError.verificationFailed("artifact upload")
                }
            }
            guard try await invoke(request("activate"))["installed"] as? Bool == true else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed("artifact activation")
            }
        } catch {
            // Only this invocation's private staging names can be removed.
            // An unstructured cleanup task does not inherit the cancelled
            // install task's cancellation flag. It only targets this nonce.
            let cleanup = Task { _ = try? await invoke(request("abort")) }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                cleanup.cancel()
            }
            await cleanup.value
            deadline.cancel()
            throw error
        }
    }
}
