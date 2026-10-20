import Foundation
import XCTest
import TesseraSessionCore

/// Runs `MoshBootstrapGrammar.serverNewCommand` through a real POSIX shell the
/// way sshd's exec channel does (`$SHELL -c "<command>"`), against a stand-in
/// mosh-server that prints its argv and a stand-in login shell that models a
/// profile putting Homebrew on PATH. The shape test in
/// `MoshBootstrapGrammarTests` pins the text; this proves both branches of it
/// deliver the identical argv, and that a host which resolves mosh-server
/// directly never pays for the login shell.
final class MoshBootstrapCommandDeliveryTests: XCTestCase {
    #if os(macOS)
    private var root: URL!
    private var loginBin: URL { root.appendingPathComponent("login-bin") }
    private var loginShell: URL { root.appendingPathComponent("login-shell") }
    private var loginLog: URL { root.appendingPathComponent("login-shell.log") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-mosh-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: loginBin, withIntermediateDirectories: true)
        try write(
            loginBin.appendingPathComponent("mosh-server"),
            """
            #!/bin/sh
            printf 'MOSH CONNECT 60001 qiXpjXIk6M8/nWtBn9s6rQ\\n'
            for argument in "$@"; do printf 'argv=%s\\n' "$argument"; done
            """
        )
        // Records how it was invoked; on `-l` prepends TESSERA_LOGIN_BIN to
        // PATH the way `.zprofile` would, then behaves like sh.
        try write(
            loginShell,
            """
            #!/bin/sh
            printf 'login-shell:%s\\n' "$*" >> '\(loginLog.path)'
            if [ "$1" = -l ]; then
                shift
                PATH="${TESSERA_LOGIN_BIN}:$PATH"; export PATH
            fi
            exec /bin/sh "$@"
            """
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let launchCommand = "tmux -u new-session -A -s 'x' \\; set-option -t 'x' status off"
    private let expectedArgv = [
        "new", "-c", "256", "--", "tmux", "-u", "new-session", "-A", "-s", "x", ";", "set-option", "-t", "x", "status", "off",
    ]

    func testAHostThatResolvesMoshServerExecsItDirectly() throws {
        let run = try execChannel(
            MoshBootstrapGrammar.serverNewCommand(launchCommand: launchCommand),
            path: "\(loginBin.path):/usr/bin:/bin",
            loginBin: loginBin.path
        )
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stdout.contains("MOSH CONNECT 60001 qiXpjXIk6M8/nWtBn9s6rQ"), run.stdout)
        XCTAssertEqual(argv(in: run.stdout), expectedArgv)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: loginLog.path),
            "a host that resolves mosh-server must not pay for a login shell"
        )
    }

    func testALoginOnlyPathReachesMoshServerThroughTheLoginShellWithIdenticalArgv() throws {
        let run = try execChannel(
            MoshBootstrapGrammar.serverNewCommand(launchCommand: launchCommand),
            path: "/usr/bin:/bin",
            loginBin: loginBin.path
        )
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stdout.contains("MOSH CONNECT 60001 qiXpjXIk6M8/nWtBn9s6rQ"), run.stdout)
        XCTAssertEqual(argv(in: run.stdout), expectedArgv)
        let log = try String(contentsOf: loginLog, encoding: .utf8)
        XCTAssertEqual(
            log,
            "login-shell:-l -c exec mosh-server new -c 256 -- \(launchCommand)\n",
            "the login shell must receive the very same argv"
        )
    }

    func testAHostWithoutMoshServerStillReadsAsMissingAfterTheFallback() throws {
        let empty = root.appendingPathComponent("empty-bin")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let run = try execChannel(
            MoshBootstrapGrammar.serverNewCommand(launchCommand: nil),
            path: "/usr/bin:/bin",
            loginBin: empty.path
        )
        XCTAssertNotEqual(run.status, 0)
        XCTAssertFalse(run.stdout.contains("MOSH CONNECT"))
        XCTAssertTrue(
            MoshBootstrapGrammar.transcriptSuggestsMissingServer(stdout: run.stdout, stderr: run.stderr),
            "stdout=\(run.stdout) stderr=\(run.stderr)"
        )
    }

    // MARK: - Helpers

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// `$SHELL -c "<command>"`, exactly what sshd does for an exec request.
    private func execChannel(_ command: String, path: String, loginBin: String) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "PATH": path,
            "SHELL": loginShell.path,
            "TESSERA_LOGIN_BIN": loginBin,
            "HOME": root.path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    private func argv(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("argv=") }
            .map { String($0.dropFirst("argv=".count)) }
    }

    private func write(_ url: URL, _ script: String) throws {
        try (script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    #endif
}
