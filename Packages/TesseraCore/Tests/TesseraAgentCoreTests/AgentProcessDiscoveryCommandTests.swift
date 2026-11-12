import Foundation
import XCTest
@testable import TesseraAgentCore

#if os(macOS) || os(Linux)
/// Runs the real discovery program against a scripted `ps`, so the program
/// and the root-scoped parser are checked together.
final class AgentProcessDiscoveryCommandTests: XCTestCase {
    private typealias Installer = RemoteAgentLifecycleIntegrationInstaller

    /// A process whose name falls outside the executable alphabet (WSL's
    /// `Relay(n)`, a Node `process.title`) still parents the agent below it.
    func testAnUnnameableProcessKeepsItsDescendantsInTheTree() throws {
        let output = try discover(root: 42, rows: [
            "42 1 42 60 bash",
            "50 42 50 60 Relay(50)",
            "60 50 60 60 codex",
            "61 60 60 60 node",
            "99 1 99 99 codex",
        ])
        let result = try parse(output, root: 42)
        XCTAssertEqual(result.processes.map(\.processID), [42, 50, 60, 61])
        XCTAssertEqual(result.processes.map(\.executable), ["bash", "unnamed", "codex", "node"])
        XCTAssertEqual(result.foreground, .agent)
        XCTAssertEqual(result.foregroundLifecycleProviderProcessIDs, [60])
        XCTAssertTrue(output.contains(#""truncated":false"#), output)
    }

    /// A name is the whole `comm` field: its first word can name a shell or a
    /// provider that is not running.
    func testANameWithASpaceIsUnnamed() throws {
        let output = try discover(root: 42, rows: [
            "42 1 42 60 bash",
            "60 42 60 60 codex worker",
            "61 60 60 60 /opt/bash tools/codex",
        ])
        let result = try parse(output, root: 42)
        XCTAssertEqual(result.processes.map(\.executable), ["bash", "unnamed", "unnamed"])
        XCTAssertTrue(result.foregroundProviderProcessIDs.isEmpty)
        XCTAssertTrue(result.foregroundShellProcessIDs.isEmpty)
    }

    /// PIDs wrap, so children can sort before their parent. The cap must cut
    /// whole subtrees, never an ancestor of an emitted process.
    func testTheCapKeepsAClosedTreeAndReportsTruncation() throws {
        let output = try discover(root: 42, rows: (100...299).map { "\($0) 30000 \($0) 30000 sleep" } + [
            "42 1 42 30000 bash",
            "30000 42 30000 30000 codex",
        ])
        let result = try parse(output, root: 42)
        XCTAssertEqual(result.processes.count, 128)
        XCTAssertEqual(Array(result.processes.map(\.processID).prefix(3)), [42, 30000, 100])
        XCTAssertEqual(result.foregroundLifecycleProviderProcessIDs, [30000])
        XCTAssertTrue(output.contains(#""truncated":true"#), output)
    }

    /// The foreground job decides what the pane runs. Background siblings
    /// that fill the cap first must not hide the agent and leave a shell.
    func testTheForegroundJobIsKeptBeyondTheCap() throws {
        let output = try discover(root: 42, rows: [
            "42 1 42 50 bash",
            "50 42 50 50 sh",
            "51 50 50 50 codex",
        ] + (100...226).map { "\($0) 42 \($0) 50 sleep" })
        let result = try parse(output, root: 42)
        XCTAssertEqual(result.processes.count, 128)
        XCTAssertTrue(result.processes.map(\.processID).contains(51))
        XCTAssertEqual(result.foreground, .agent)
        XCTAssertEqual(result.foregroundLifecycleProviderProcessIDs, [51])
        XCTAssertTrue(output.contains(#""truncated":true"#), output)
    }

    /// A foreground job too large to describe whole fails the read.
    func testAForegroundJobOverTheCapFailsTheRead() throws {
        let output = try discover(root: 42, rows: [
            "42 1 42 30000 bash",
            "30000 42 30000 30000 make",
        ] + (100...299).map { "\($0) 30000 30000 30000 cc" }, status: 1)
        XCTAssertNil(Installer.parseProcessDiscovery(output, scope: try scope(42)), output)
    }

    /// One PID with two parents is two process generations; the program must
    /// not stitch a child of one under the other.
    func testAPIDListedTwiceFailsTheRead() throws {
        let output = try discover(root: 42, rows: [
            "42 1 42 60 bash",
            "50 42 50 60 sleep",
            "50 900 50 60 sh",
            "60 50 60 60 codex",
        ], status: 1)
        XCTAssertNil(Installer.parseProcessDiscovery(output, scope: try scope(42)), output)
    }

    private func scope(_ root: Int) throws -> AgentIntegrationProcessDiscoveryScope {
        try XCTUnwrap(AgentIntegrationProcessDiscoveryScope(rootProcessID: root))
    }

    private func parse(_ output: String, root: Int) throws -> AgentIntegrationProcessDiscoveryResult {
        try XCTUnwrap(Installer.parseProcessDiscovery(output, scope: try scope(root)), output)
    }

    /// Rows are `pid ppid pgid tpgid comm`, as the program asks `ps` for them.
    private func discover(root: Int, rows: [String], status expectedStatus: Int32 = 0) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ps = directory.appendingPathComponent("ps")
        try Data(("#!/bin/sh\ncat <<'ROWS'\n" + rows.joined(separator: "\n") + "\nROWS\n").utf8).write(to: ps)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Installer.makeProcessDiscoveryCommand(scope: try scope(root))]
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": directory.path + ":/usr/bin:/bin"]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, expectedStatus)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
