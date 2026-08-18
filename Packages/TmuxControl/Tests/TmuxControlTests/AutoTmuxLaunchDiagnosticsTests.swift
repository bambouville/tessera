import XCTest
@testable import TmuxControl

final class AutoTmuxLaunchDiagnosticsTests: XCTestCase {

    private func classify(_ text: String) -> AutoTmuxLaunchDiagnostics.Shape {
        AutoTmuxLaunchDiagnostics.classify(
            chunk: Array(text.utf8),
            launchCommand: AutoTmuxScript.command(sessionName: "tessera-abcdef01")
        )
    }

    func test_recognisesControlModePrologue() {
        let shape = classify("\u{1B}P1000p%begin 1 2 0\r\n")
        XCTAssertTrue(shape.hasControlPrologue)
        XCTAssertTrue(shape.hasDCS)
    }

    func test_recognisesFullScreenTakeoverAndPrompt() {
        XCTAssertTrue(classify("\u{1B}[?1049h\u{1B}[H").entersAltScreen)
        XCTAssertTrue(classify("\u{1B}[?2004h$ ").hasShellPromptMarker)
    }

    func test_recognisesOurOwnCommandEcho() {
        let echo = AutoTmuxScript.command(sessionName: "tessera-abcdef01")
        XCTAssertTrue(classify(echo).echoesLaunchCommand)
        XCTAssertFalse(classify("total 24\r\n").echoesLaunchCommand)
    }

    func test_reportsKnownRemoteFailuresByName() {
        XCTAssertEqual(
            classify("sessions should be nested with care, unset $TMUX to force\r\n").markers,
            [.nestedSession]
        )
        XCTAssertEqual(
            classify("protocol version mismatch (client 8, server 7)\r\n").markers,
            [.protocolMismatch]
        )
        XCTAssertEqual(
            classify("open terminal failed: missing or unsuitable terminal: xterm-256color\r\n")
                .markers.sorted { $0.logName < $1.logName },
            [.openTerminalFailed, .unsuitableTerminal].sorted { $0.logName < $1.logName }
        )
        XCTAssertTrue(classify("hello world\r\n").markers.isEmpty)
    }

    func test_logDescriptionNeverContainsChunkText() {
        // The whole point: a shareable diagnostics line must not carry
        // remote output, which can hold secrets.
        let secret = "export AWS_SECRET_ACCESS_KEY=hunter2 # sessions should be nested"
        let description = classify(secret).logDescription
        XCTAssertFalse(description.contains("hunter2"))
        XCTAssertFalse(description.contains("AWS"))
        XCTAssertTrue(description.contains("markers=nested"))
        XCTAssertTrue(description.contains("printable="))
    }

    func test_countsControlBytesSeparatelyFromText() {
        let shape = classify("ab\u{1B}[0m")
        XCTAssertEqual(shape.printableCount, 5)
        XCTAssertEqual(shape.controlCount, 1)
    }
}
