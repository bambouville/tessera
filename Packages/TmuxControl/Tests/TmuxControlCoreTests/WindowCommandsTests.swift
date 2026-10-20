import XCTest
@testable import TmuxControlCore

final class WindowCommandsTests: XCTestCase {
    func testCapabilitiesUseConservativeVersionGate() {
        XCTAssertEqual(
            TmuxWindowCapabilities.forVersion("3.1c"),
            .init(supportsMoveBefore: false, supportsSubscriptions: false)
        )
        XCTAssertEqual(
            TmuxWindowCapabilities.forVersion("3.2"),
            .init(supportsMoveBefore: true, supportsSubscriptions: true)
        )
        XCTAssertEqual(
            TmuxWindowCapabilities.forVersion("4.0-rc1"),
            .init(supportsMoveBefore: true, supportsSubscriptions: true)
        )
        XCTAssertEqual(TmuxWindowCapabilities.forVersion("next-3.6"), .forVersion("3.6"))
        for unknown in ["", "3", "tmux 3.6a", "openbsd-7.6"] {
            XCTAssertEqual(
                TmuxWindowCapabilities.forVersion(unknown),
                .init(supportsMoveBefore: false, supportsSubscriptions: false)
            )
        }
    }

    func testNewWindowBuildersUseAppendAndTruecolorSpellings() {
        XCTAssertEqual(
            TmuxWindowCommands.newWindowAtEnd(),
            "new-window -a -t '{end}' -e COLORTERM=truecolor"
        )
        XCTAssertEqual(
            TmuxWindowCommands.newWindowAtEnd(target: "dev's work"),
            "new-window -a -t 'dev'\\''s work:{end}' -e COLORTERM=truecolor"
        )
        XCTAssertEqual(
            TmuxWindowCommands.newWindowAfterCurrent(),
            "new-window -a -e COLORTERM=truecolor"
        )
    }

    func testNewWindowAtEndPreservesAgentCenterOptionsWithoutRawSplicing() {
        XCTAssertEqual(
            TmuxWindowCommands.newWindowAtEnd(
                target: "$2",
                detached: true,
                name: "Codex's worker",
                printFormat: "#{window_id}\t#{pane_id}",
                command: "exec ~/.tessera/agent-host --stdio"
            ),
            "new-window -a -t '$2:{end}' -e COLORTERM=truecolor -d"
                + " -n 'Codex'\\''s worker'"
                + " -P -F '#{window_id}\t#{pane_id}'"
                + " 'exec ~/.tessera/agent-host --stdio'"
        )
    }

    func testMutationBuildersUseStableIdsAndDetachedMoves() {
        XCTAssertEqual(TmuxWindowCommands.selectWindow(WindowId(7)), "select-window -t @7")
        XCTAssertEqual(TmuxWindowCommands.killWindow(WindowId(7)), "kill-window -t @7")
        XCTAssertEqual(
            TmuxWindowCommands.renameWindow(WindowId(7), to: "dev's logs"),
            "rename-window -t @7 'dev'\\''s logs'"
        )
        XCTAssertEqual(
            TmuxWindowCommands.moveWindow(WindowId(7), after: WindowId(3)),
            "move-window -d -a -s @7 -t @3"
        )
        XCTAssertEqual(
            TmuxWindowCommands.moveWindow(WindowId(7), before: WindowId(3)),
            "move-window -d -b -s @7 -t @3"
        )
        XCTAssertEqual(
            TmuxWindowCommands.swapWindows(WindowId(7), WindowId(3)),
            "swap-window -d -s @7 -t @3"
        )
        XCTAssertEqual(TmuxWindowCommands.renumber(target: "$2"), "move-window -r -t '$2'")
    }

    func testSessionQualificationAppliesToEveryWindowTarget() {
        let session = SessionId(2)
        XCTAssertEqual(
            TmuxWindowCommands.selectWindow(WindowId(7), sessionID: session),
            "select-window -t $2:@7"
        )
        XCTAssertEqual(
            TmuxWindowCommands.moveWindow(WindowId(7), after: WindowId(3), sessionID: session),
            "move-window -d -a -s $2:@7 -t $2:@3"
        )
        XCTAssertEqual(
            TmuxWindowCommands.swapWindows(WindowId(7), WindowId(3), sessionID: session),
            "swap-window -d -s $2:@7 -t $2:@3"
        )
    }

    /// W2: a tab switch names the issuing client's own session, so tmux never
    /// resolves the window through the most recently active grouped sibling.
    func testTabSwitchTargetIsSessionQualifiedAndSingleQuoted() {
        XCTAssertEqual(
            TmuxWindowCommands.sessionQualifiedTarget(WindowId(7), sessionID: SessionId(2)),
            "'$2:@7'"
        )
        XCTAssertEqual(
            TmuxWindowCommands.sessionQualifiedTarget(
                WindowId(7),
                sessionID: SessionId(2),
                paneID: PaneId(11)
            ),
            "'$2:@7.%11'"
        )
        XCTAssertEqual(
            TmuxWindowCommands.selectWindow(WindowId(7), inOwnSession: SessionId(2)),
            "select-window -t '$2:@7'"
        )
        XCTAssertEqual(
            TmuxWindowCommands.selectWindow(WindowId(0), inOwnSession: SessionId(0)),
            "select-window -t '$0:@0'"
        )
    }

    /// The quoted target reaches tmux's target resolver as the literal
    /// `$S:@W`, in one word, whatever the server's global environment holds.
    /// `lexTmuxWords` follows `yylex_token` / `yylex_token_variable` in
    /// cmd-parse.y (unchanged for `$` and quotes from 3.2 through 3.6a).
    func testSessionQualifiedTargetLexesToTheLiteralTargetInOneWord() {
        let environment = ["S": "hijacked", "2": "never-a-name"]
        for (session, window, pane) in [(2, 7, nil), (0, 0, nil), (41, 1_234, 9), (9_999, 3, 0)] {
            let command = pane == nil
                ? TmuxWindowCommands.selectWindow(WindowId(window), inOwnSession: SessionId(session))
                : "select-pane -t " + TmuxWindowCommands.sessionQualifiedTarget(
                    WindowId(window),
                    sessionID: SessionId(session),
                    paneID: pane.map(PaneId.init)
                )
            let words = Self.lexTmuxWords(command, environment: environment)
            let expected = "$\(session):@\(window)" + (pane.map { ".%\($0)" } ?? "")
            XCTAssertEqual(words.count, 3, command)
            XCTAssertEqual(words.last, expected, command)
        }
        // The model is not vacuous: an unquoted or double-quoted `$NAME`
        // expands, which is exactly what the single quotes rule out.
        XCTAssertEqual(Self.lexTmuxWords("select-window -t $S:@7", environment: environment).last, "hijacked:@7")
        XCTAssertEqual(Self.lexTmuxWords("select-window -t \"$S:@7\"", environment: environment).last, "hijacked:@7")
        XCTAssertEqual(Self.lexTmuxWords("select-window -t '$S:@7'", environment: environment).last, "$S:@7")
        // A digit cannot start a name (`yylex_is_var`), so the bare spelling
        // the window-order plans keep is literal too.
        XCTAssertEqual(Self.lexTmuxWords("select-window -t $2:@7", environment: environment).last, "$2:@7")
    }

    /// Minimal word splitter for one control-mode line, following
    /// cmd-parse.y: whitespace ends a word outside quotes; `'…'` and `"…"`
    /// are consumed; `$` outside single quotes starts a variable whose first
    /// character must not be a digit (`yylex_is_var`), else `$` is literal.
    private static func lexTmuxWords(_ line: String, environment: [String: String]) -> [String] {
        enum State { case none, double, single }
        func isVariable(_ character: Character, first: Bool) -> Bool {
            guard character.isASCII, character != "=" else { return false }
            if first, character.isNumber { return false }
            return character.isLetter || character.isNumber || character == "_"
        }
        var words: [String] = []
        var word: String?
        var state = State.none
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if state == .none, character == " " || character == "\t" {
                if let finished = word { words.append(finished) }
                word = nil
                continue
            }
            if character == "$", state != .single {
                guard index < characters.count, isVariable(characters[index], first: true) else {
                    word = (word ?? "") + "$"
                    continue
                }
                var name = ""
                while index < characters.count, isVariable(characters[index], first: false) {
                    name.append(characters[index])
                    index += 1
                }
                word = (word ?? "") + (environment[name] ?? "")
                continue
            }
            if character == "'", state != .double {
                state = state == .single ? .none : .single
                word = word ?? ""
                continue
            }
            if character == "\"", state != .single {
                state = state == .double ? .none : .double
                word = word ?? ""
                continue
            }
            word = (word ?? "") + String(character)
        }
        if let finished = word { words.append(finished) }
        return words
    }

    func testStringArgumentsCannotInjectAControlModeCommand() {
        XCTAssertEqual(
            TmuxWindowCommands.newWindowAtEnd(target: "dev\nkill-server\u{0}"),
            "new-window -a -t 'devkill-server:{end}' -e COLORTERM=truecolor"
        )
        XCTAssertEqual(
            TmuxWindowCommands.newWindowAtEnd(
                detached: true,
                name: "agent\nkill-server",
                printFormat: "#{window_id}\rkill-server",
                command: "run-helper\nkill-server"
            ),
            "new-window -a -t '{end}' -e COLORTERM=truecolor -d"
                + " -n 'agentkill-server'"
                + " -P -F '#{window_id}kill-server'"
                + " 'run-helperkill-server'"
        )
        XCTAssertEqual(
            TmuxWindowCommands.renameWindow(WindowId(7), to: "x\r\nkill-server\u{0}y"),
            "rename-window -t @7 'xkill-servery'"
        )
        XCTAssertEqual(
            TmuxWindowCommands.renumber(target: "$2\nkill-server"),
            "move-window -r -t '$2kill-server'"
        )
    }

    func testSessionGroupQueryParsesOnlyTheContainingGroupAndPreservesSelections() throws {
        XCTAssertEqual(
            TmuxSessionGroupQuery.command,
            "list-sessions -F '#{session_id}\t#{session_group}\t#{window_id}'"
        )
        let members = try XCTUnwrap(TmuxSessionGroupQuery.parse(
            lines: [
                "$4\talpha\t@8",
                "$2\talpha\t@7",
                "$9\tbeta\t@1",
            ],
            containing: SessionId(4)
        ))
        XCTAssertEqual(
            members,
            [
                .init(sessionID: SessionId(2), activeWindowID: WindowId(7)),
                .init(sessionID: SessionId(4), activeWindowID: WindowId(8)),
            ]
        )
        XCTAssertEqual(
            TmuxSessionGroupQuery.renumberCommands(
                for: members,
                preservingAttached: SessionId(2)
            ),
            [
                "move-window -r -t '$2'",
                "move-window -r -t '$4'",
                "select-window -t $4:@8",
                "select-window -t $2:@7",
            ]
        )
    }

    func testUngroupedSessionQueryKeepsOnlyTheAttachedSession() {
        XCTAssertEqual(
            TmuxSessionGroupQuery.parse(
                lines: ["$1\t\t@3", "$2\tgroup\t@4"],
                containing: SessionId(1)
            ),
            [.init(sessionID: SessionId(1), activeWindowID: WindowId(3))]
        )
        XCTAssertNil(TmuxSessionGroupQuery.parse(
            lines: ["$1\tgroup"],
            containing: SessionId(1)
        ))
        XCTAssertNil(TmuxSessionGroupQuery.parse(
            lines: ["$1\tgroup\t@3", "$1\tgroup\t@3"],
            containing: SessionId(1)
        ))
    }
}
