import Foundation
import XCTest
@testable import TesseraAgentCore

final class AgentHostDeploymentTests: XCTestCase {
    func testMaximumBinaryChunkFitsBoundedStdinEvenWhenBase64IsAllSlashes() throws {
        let chunk = Data(repeating: 255, count: AgentHostDeployment.chunkBytes)
        let command = try AgentHostDeployment.command(.init(operation: "write",
            upload: String(repeating: "a", count: 32), sha256: String(repeating: "b", count: 64),
            bytes: AgentHostDeployment.maximumArtifactBytes, offset: 0, content: chunk.base64EncodedString()))
        let payload = try XCTUnwrap(command.components(separatedBy: "<<'TESSERA_ARTIFACT_REQUEST'\n").last?.components(separatedBy: "\n").first)
        XCTAssertLessThanOrEqual(payload.utf8.count + 1, 65536)
        let request = try JSONDecoder().decode(AgentHostDeployment.Request.self, from: XCTUnwrap(Data(base64Encoded: payload)))
        XCTAssertEqual(request.content.flatMap { Data(base64Encoded: $0) }, chunk)
    }

    func testNativeCurrencyRejectsStaleExecutableEvenWithCurrentHooks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent(".config/tessera")
        let versions = root.appendingPathComponent("agent-host-versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let hook = root.appendingPathComponent("agent-lifecycle-hook.sh")
        try Data((RemoteAgentLifecycleIntegrationInstaller.hookScript + "\n").utf8).write(to: hook)
        #if os(Linux) && arch(arm64)
        let target = "linux-aarch64"
        #elseif os(Linux)
        let target = "linux-x86_64"
        #elseif arch(arm64)
        let target = "darwin-arm64"
        #else
        let target = "darwin-x86_64"
        #endif
        let link = root.appendingPathComponent("tessera-agent-host")
        func publish(_ digest: String) throws {
            let binary = versions.appendingPathComponent(digest)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            if FileManager.default.fileExists(atPath: link.path) { try FileManager.default.removeItem(at: link) }
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "agent-host-versions/" + digest)
        }
        func check() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", RemoteAgentLifecycleIntegrationInstaller.nativeHostCurrencyCheck]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": directory.path]) { _, new in new }
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        try publish(String(repeating: "0", count: 64))
        XCTAssertNotEqual(try check(), 0)
        try publish(try XCTUnwrap(AgentHostBuildRevision.artifacts[target]))
        XCTAssertNotEqual(try check(), 0, "A digest-shaped filename does not attest its bytes")
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let artifact = repository.appendingPathComponent("SharedAssets/agent-host/tessera-agent-host-" + target)
        let expected = try XCTUnwrap(AgentHostBuildRevision.artifacts[target])
        try Data(contentsOf: artifact).write(to: versions.appendingPathComponent(expected))
        XCTAssertEqual(try check(), 0)
        let handle = try FileHandle(forWritingTo: versions.appendingPathComponent(expected))
        try handle.write(contentsOf: Data("tampered".utf8)); try handle.close()
        XCTAssertNotEqual(try check(), 0)
        XCTAssertTrue(RemoteAgentLifecycleIntegrationInstaller.makeStatusCommand(requireNativeHost: true)
            .contains(RemoteAgentLifecycleIntegrationInstaller.nativeHostCurrencyCheck))
    }

    func testDeploymentRejectsUnboundedOrInjectedFields() throws {
        XCTAssertThrowsError(try AgentHostDeployment.command(.init(operation: "delete")))
        XCTAssertThrowsError(try AgentHostDeployment.command(.init(operation: "begin", upload: "../user")))
        XCTAssertThrowsError(try AgentHostDeployment.command(.init(operation: "begin", bytes: 16 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try AgentHostDeployment.command(.init(operation: "write", content: Data(repeating: 1, count: 32769).base64EncodedString())))
        XCTAssertLessThan(try AgentHostDeployment.command(.init(operation: "write", content: Data(repeating: 1, count: 32768).base64EncodedString())).utf8.count, 80_000)
    }

    func testClaudeDisplayHookMergePreservesUserHandlersAndIsIdempotent() throws {
        let user = #"{"hooks":{"MessageDisplay":[{"hooks":[{"type":"command","command":"user-owned-hook"}]}]},"theme":"dark"}"#
        let merged = try RemoteAgentLifecycleIntegrationInstaller.mergeClaudeSettings(existing: user)
        let again = try RemoteAgentLifecycleIntegrationInstaller.mergeClaudeSettings(existing: merged)
        XCTAssertEqual(merged, again)
        let root = try JSONSerialization.jsonObject(with: Data(merged.utf8)) as! [String: Any]
        XCTAssertEqual(root["theme"] as? String, "dark")
        let hooks = root["hooks"] as! [String: [[String: Any]]]
        let handlers = hooks["MessageDisplay"]!.flatMap { $0["hooks"] as! [[String: Any]] }
        XCTAssertEqual(handlers.compactMap { $0["command"] as? String }, ["user-owned-hook", RemoteAgentLifecycleIntegrationInstaller.nativeClaudeHookCommand])
        XCTAssertTrue(RemoteAgentLifecycleIntegrationInstaller.nativeClaudeHookCommand.contains("--runtime-base"))
        XCTAssertFalse(RemoteAgentLifecycleIntegrationInstaller.nativeClaudeHookCommand.contains("serve"))
    }
}
