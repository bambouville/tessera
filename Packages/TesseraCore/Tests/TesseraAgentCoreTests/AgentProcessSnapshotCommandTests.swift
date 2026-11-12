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

    /// A raw SSH terminal's root is the connection's sshd, which parents every
    /// channel's command. A login shell such as tcsh forks the probe instead
    /// of becoming it, so the probe's parent is that shell (50 here), under
    /// which the terminal's agent never runs.
    func testRawSSHRootIsTheConnectionsSSHDThroughAForkingLoginShell() throws {
        // macOS lists sshd by the title it sets, as "sshd-session: user@ttys002".
        for sshd in ["sshd", "/usr/sbin/sshd", "sshd-session", "sshd-session: dev@ttys002", "sshd: dev@ttys002"] {
            let rows = ["40 1 Ss ? \(sshd) sshd", "50 40 Ss ? tcsh tcsh", "100 40 Ss pts/1 bash bash",
                        "101 100 Sl+ pts/1 codex codex", "9999 1 Sl+ pts/2 codex codex"]
            let output = try probe(rows: rows, rootPID: nil, expectedPID: 101).split(separator: "\n")
            XCTAssertTrue(output.contains { $0.hasPrefix("101 ") }, "\(sshd): \(output)")
            XCTAssertFalse(output.contains { $0.hasPrefix("9999 ") }, "\(sshd): \(output)")
        }
        // With no sshd above it, the probe's parent stays the root.
        let rows = ["50 1 Ss pts/3 tcsh tcsh", "60 50 S+ pts/3 codex codex", "101 1 Sl+ pts/1 codex codex"]
        let output = try probe(rows: rows, rootPID: nil, expectedPID: 101).split(separator: "\n")
        XCTAssertTrue(output.contains { $0.hasPrefix("60 ") }, "\(output)")
        XCTAssertFalse(output.contains { $0.hasPrefix("101 ") }, "\(output)")
    }

    /// `ps` answers from `rows` (pid ppid stat tty comm args); a process it
    /// does not list, which is the probe's own shell, is `sh` under 50.
    private func probe(
        rows: [String] = ["100 1 Ss pts/1 bash bash", "101 100 Sl+ pts/1 codex codex"]
            + (102...301).map { "\($0) 101 S+ pts/1 sleep sleep" }
            + ["9999 1 Sl+ pts/2 codex codex"],
        rootPID: Int? = 100,
        expectedPID: Int
    ) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ps = directory.appendingPathComponent("ps")
        try Data(("""
            #!/bin/sh
            pid=''; field=''
            while [ $# -gt 0 ]; do
                case "$1" in -p) pid=$2; shift ;; -o) [ -n "$field" ] || field=$2; shift ;; esac
                shift
            done
            rows() { cat <<'ROWS'
            \(rows.joined(separator: "\n"))
            ROWS
            }
            [ -n "$pid" ] || { rows; exit 0; }
            rows | awk -v pid="$pid" -v field="$field" '
                $1 == pid { found = 1; if (field == "ppid=") print $2; else if (field == "comm=") print $5 }
                END { if (!found) print (field == "ppid=" ? "50" : "sh") }'

            """).utf8).write(to: ps)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentProcessSnapshotCommand.makeCommand(rootPID: rootPID, expectedPID: expectedPID)]
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
