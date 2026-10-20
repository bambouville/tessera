import Foundation
import XCTest
@testable import TesseraAgentCore

#if os(macOS) || os(Linux)
final class AgentProcessSnapshotCommandTests: XCTestCase {
    func testBusyCodexIdentitySurvivesTheBoundedProcessInventory() throws {
        let output = try probe(expectedPID: 101)
        let rows = output.split(separator: "\n")
        XCTAssertLessThanOrEqual(rows.count, AgentProcessSnapshotCommand.outputLineLimit)
        XCTAssertLessThanOrEqual(output.utf8.count, AgentProcessSnapshotCommand.maximumExpectedOutputBytes)
        XCTAssertTrue(rows.contains { $0.hasPrefix("101 ") }, "Fresh input proof must retain the expected Codex process")
        XCTAssertFalse(rows.contains { $0.hasPrefix("9999 ") }, "Another route's Codex is never input authority")
    }

    func testExpectedPIDCannotPullAnotherRoutesAgentIntoTheInventory() throws {
        let output = try probe(expectedPID: 9999)
        XCTAssertFalse(output.split(separator: "\n").contains { $0.hasPrefix("9999 ") })
    }

    private func probe(expectedPID: Int) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = ["100 1 Ss pts/1 bash bash", "101 100 Sl+ pts/1 codex codex"]
            + (102...301).map { "\($0) 101 S+ pts/1 sleep sleep" }
            + ["9999 1 Sl+ pts/2 codex codex"]
        let ps = directory.appendingPathComponent("ps")
        try Data(("#!/bin/sh\ncat <<'ROWS'\n" + rows.joined(separator: "\n") + "\nROWS\n").utf8).write(to: ps)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentProcessSnapshotCommand.makeCommand(rootPID: 100, expectedPID: expectedPID)]
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": directory.path + ":/usr/bin:/bin"]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
