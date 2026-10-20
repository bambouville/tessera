import XCTest
@testable import TesseraAgentCore

final class AgentComposerEvidenceTests: XCTestCase {
    /// Claude Code 2.1.302 paints a reverse-video software cursor and hides
    /// the hardware cursor, including in Max + Ultracode mode.
    func testClaudeSoftwareCursorKeepsDimSuggestionAndTypedDraftProofDistinct() {
        let footer = "\n────────\nctx:5%\n◈ max · ultracode · /effort"
        let placeholder = "❯\u{00a0}\u{1b}[7mT\u{1b}[0;2mry\u{1b}[0m \u{1b}[2m\"refactor\u{1b}[0m \u{1b}[2m<filepath>\"\u{1b}[0m"
        func assess(_ row: String, column: Int? = 2, empty: Bool = true, text: String? = nil) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "claude", visibleText: "────────\n" + row + footer,
                cursorRow: 1, cursorColumn: column, cursorVisible: false, requireEmpty: empty,
                queueWhenWorking: false, text: text)
        }
        XCTAssertEqual(assess(placeholder), .readyReturn)
        XCTAssertEqual(assess(placeholder.replacingOccurrences(of: "[7m", with: "[0m")), .blocked)
        XCTAssertEqual(assess(placeholder, column: nil), .blocked)
        XCTAssertEqual(assess(placeholder, column: 3), .blocked)
        let typedAtHome = placeholder.replacingOccurrences(of: "[0;2m", with: "[0m").replacingOccurrences(of: "[2m", with: "[0m")
        XCTAssertEqual(assess(typedAtHome), .occupied)
        let inserted = "❯ hello draft\u{1b}[7m \u{1b}[0m"
        XCTAssertEqual(assess(inserted, column: 13, empty: false, text: "hello draft"), .readyReturn)
        XCTAssertEqual(assess(inserted, column: 12, empty: false, text: "hello draft"), .blocked)
        XCTAssertEqual(assess(inserted, column: 13), .occupied)
        XCTAssertEqual(assess("❯ \u{1b}[7mhello\u{1b}[0m draft", column: 2, empty: false, text: "hello draft"), .blocked)
        // A stale hidden VT position must not give a different provider the
        // software-cursor exception.
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "codex", visibleText: "› \u{1b}[7mA\u{1b}[0;2msk Codex to do anything\u{1b}[0m\n\n? for shortcuts",
            cursorRow: 0, cursorColumn: 2, cursorVisible: false, requireEmpty: true, queueWhenWorking: false), .blocked)
    }

    func testClaudeCurrentPermissionAndEffortFooterKeepsExactPayloadEvidence() {
        let modes = ["⏸ manual mode on", "⏸ plan mode on", "⏵⏵ accept edits on", "⏵⏵ bypass permissions on", "⏵⏵ don't ask on", "⏵⏵ auto mode on"]
        let efforts = ["○ low", "◐ medium", "● high", "◉ xhigh", "◈ max", "effort: max"]
        for mode in modes {
            for effort in efforts {
                for idleHints in ["", " · ? for shortcuts · ← for agents"] {
                    let footer = mode + idleHints + String(repeating: " ", count: 20) + effort + " · ultracode · /effort"
                    let capture = "────\n❯ hello draft\u{1b}[7m \u{1b}[0m\n────\n" + footer
                    XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: capture,
                        cursorLine: "❯ hello draft ", text: "hello draft", cursorRow: 1), .present, footer)
                    XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "claude", visibleText: capture,
                        cursorLine: "❯ hello draft ", text: "hello draft", queueWhenWorking: false, cursorRow: 1), .return, footer)
                    XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: capture + " unknown",
                        cursorLine: "❯ hello draft ", text: "hello draft", cursorRow: 1), .unavailable)
                }
            }
        }
    }

    /// Codex CLI 0.162.1 uses › for default/max and » for ultra. The
    /// latter was mistaken for an older prompt still visible in history.
    func testCodexEffortMarkersKeepEmptyTypedWrappedAndQueuedEvidence() {
        let status = "GPT-6.1-Sol ultra · ~/projects/OpenTTD · Review OpenT…"
        let footer = "\n\n\(status)\n? for shortcuts              ⚠ 2 warnings · f2 to view"
        for marker in ["›", "»"] {
            let history = "› old message\nold response\n\n"
            let empty = history + "\u{1b}[1;35m\(marker)\u{1b}[0m \u{1b}[2mAsk Codex to do anything\u{1b}[0m" + footer
            func safety(_ value: String, column: Int? = 2, queue: Bool = false) -> AgentComposerEvidence.Safety {
                AgentComposerEvidence.safety(provider: "codex", visibleText: value, cursorRow: 3,
                    cursorColumn: column, cursorVisible: true, requireEmpty: true, queueWhenWorking: queue)
            }
            XCTAssertEqual(safety(empty), .readyReturn, marker)
            XCTAssertEqual(safety(empty, queue: true), .readyTab, marker)
            XCTAssertEqual(safety(empty, column: 3), .occupied, marker)
            let typedLiteral = history + marker + " Ask Codex to do anything" + footer
            XCTAssertEqual(safety(typedLiteral), .occupied, marker)
            XCTAssertEqual(safety(empty.replacingOccurrences(of: "\u{1b}[2mAsk", with: "A\u{1b}[2msk")), .occupied, marker)
            XCTAssertEqual(safety(empty.replacingOccurrences(of: "\n\n\(status)", with: "\nretained draft\n\n\(status)")), .occupied, marker)
            XCTAssertTrue(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: marker + " Ask Codex to do anything"))
            XCTAssertTrue(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: marker + " Implement {feature}",
                visibleText: empty.replacingOccurrences(of: "Ask Codex to do anything", with: "Implement {feature}"), cursorRow: 3))
            XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: marker + " typed draft"))
            XCTAssertTrue(AgentComposerEvidence.diagnosticShape(provider: "codex", visibleText: empty,
                cursorRow: 3, cursorColumn: 2, cursorVisible: true).contains("marker=3"))

            let text = "hello draft that wraps onto another row"
            let inserted = history + marker + " hello draft that wraps\n  onto another row" + footer
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: inserted,
                cursorLine: "  onto another row", text: text, cursorRow: 4), .present, marker)
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: inserted,
                cursorLine: "  onto another row", text: text + " extra", cursorRow: 4), .absent, marker)
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: empty,
                cursorLine: marker + " Ask Codex to do anything", text: text, cursorRow: 3), .absent, marker)
            let queued = marker + " hello draft\n\n\(status)\ntab to queue message    ⚠ 2 warnings · f2 to view"
            XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: queued,
                cursorLine: marker + " hello draft", text: "hello draft", queueWhenWorking: true, cursorRow: 0), .tab, marker)
        }
        // Similar glyphs and cross-provider prompts do not grant input authority.
        for marker in ["«", ">>", "❯"] {
            XCTAssertEqual(AgentComposerEvidence.safety(provider: "codex", visibleText: marker + " \u{1b}[2mAsk Codex to do anything\u{1b}[0m" + footer,
                cursorRow: 0, cursorColumn: 2, cursorVisible: true, requireEmpty: true, queueWhenWorking: false), .unavailable, marker)
        }
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: "» \u{1b}[2msuggestion\u{1b}[0m\n────\nctx:5%",
            cursorRow: 0, cursorColumn: 2, cursorVisible: true, requireEmpty: true, queueWhenWorking: false), .unavailable)
    }

    func testCodexEffortAnimationsKeepPlaceholderProofAndRealDraftsSeparate() {
        for marker in ["›", "»"] {
            let footer = "\n\nGPT-6.1-Sol max · ~/repo\n? for shortcuts"
            let animated = "\u{1b}[1m\(marker)\u{1b}[0m⠁\u{1b}[2mAsk⠂Codex to do anything\u{1b}[0m ⠐\n  ⠁ ⢀" + footer
            func assess(_ value: String) -> AgentComposerEvidence.Safety {
                AgentComposerEvidence.safety(provider: "codex", visibleText: value, cursorRow: 0,
                    cursorColumn: 2, cursorVisible: true, requireEmpty: true, queueWhenWorking: false)
            }
            XCTAssertEqual(assess(animated), .readyReturn, marker)
            XCTAssertNotEqual(assess(animated.replacingOccurrences(of: "\u{1b}[2m", with: "")), .readyReturn, marker)
            XCTAssertNotEqual(assess(animated.replacingOccurrences(of: "⠁ ⢀", with: "real draft")), .readyReturn, marker)
        }
    }

    /// Row titles and previews come from the cursor line only when the user
    /// typed it. Plain text recognizes a bare glyph and Codex's placeholder
    /// literal, particles included; styled evidence recognizes any DIM
    /// suggestion, so a renamed placeholder or Claude's suggestion cannot
    /// name a row, while typed drafts, which are never DIM, still do.
    func testPlaceholderTitleLineRecognizesGlyphsLiteralsAndDimSuggestions() {
        for line in ["› Ask Codex to do anything", "  ›  Ask Codex to do anything  ", "Ask Codex to do anything",
                     "› \u{28ff}Ask Codex\u{2801} to do anything", "›⠁Ask⠂Codex to do anything", "›", "› ", "", "   "] {
            XCTAssertTrue(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: line), line)
        }
        for line in ["❯", "❯\u{00a0}", ""] {
            XCTAssertTrue(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: line), line)
        }
        for line in ["› Ask Codex to do anything now", "› Ask Codex to do anything.", "› fix the bug", "› 1. Yes",
                     "› Implement {feature}", "❯ Try \"fix the bug\""] {
            XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: line), line)
            XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: line), line)
        }
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: "Ask Codex to do anything"))

        // tmux captures keep SGR: a DIM suggestion after the glyph is a placeholder whatever it says.
        let dim = "banner\n› \u{1b}[2mImplement {feature}\u{1b}[0m\n  gpt-5.6"
        let typed = "banner\n› Implement {feature}\n  gpt-5.6"
        XCTAssertTrue(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› Implement {feature}", visibleText: dim, cursorRow: 1))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› Implement {feature}", visibleText: typed, cursorRow: 1))
        // Only the row the line came from may vouch for it.
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› Implement {feature}", visibleText: dim, cursorRow: 0))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› ship it", visibleText: dim, cursorRow: 1))
        // A partly DIM row is a draft with an inline completion, not a placeholder.
        let completion = "› Impl\u{1b}[2mement {feature}\u{1b}[0m"
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› Implement {feature}", visibleText: completion, cursorRow: 0))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: "› Implement {feature}", visibleText: completion, cursorRow: 0))
        // Claude repaints the first glyph as its cursor; the rest of the suggestion stays DIM.
        let claude = "❯\u{00a0}\u{1b}[7mT\u{1b}[27m\u{1b}[2mry \"fix the bug\"\u{1b}[0m\n────────"
        let claudeLine = "❯\u{00a0}Try \"fix the bug\""
        XCTAssertTrue(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: claudeLine, visibleText: claude, cursorRow: 0))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: claudeLine, visibleText: claude, cursorRow: 0))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: claudeLine, visibleText: claudeLine + "\n────────", cursorRow: 0))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: "❯ T", visibleText: "❯ \u{1b}[7mT\u{1b}[0m", cursorRow: 0))
        // Other providers keep their typed reading; unparsable escapes prove nothing.
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "kimi", line: "› Implement {feature}", visibleText: dim, cursorRow: 1))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› Implement {feature}", visibleText: "\u{1b}[2J" + dim, cursorRow: 1))

        // Native captures carry cell styles instead of escapes.
        func screen(_ text: String, dimFrom: Int?) -> TerminalScreenEvidence {
            let cells = text.enumerated().map { index, character in
                TerminalScreenEvidence.Cell(text: String(character), width: 1, style: dimFrom.map { index >= $0 ? 32 : 0 } ?? 0)
            }
            return TerminalScreenEvidence(columns: cells.count, cells: [cells], wrappedRows: [false],
                cursorRow: 0, cursorColumn: 2, cursorVisible: true, isAlternate: false)
        }
        XCTAssertTrue(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› Write tests for @filename",
            screen: screen("› Write tests for @filename", dimFrom: 2)))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› Write tests for @filename",
            screen: screen("› Write tests for @filename", dimFrom: nil)))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "codex", line: "› ship it",
            screen: screen("› Write tests for @filename", dimFrom: 2)))
    }

    func testCodexTypedPlaceholderLiteralIsOccupiedWithoutDimProof() {
        let literal = "› Ask Codex to do anything\n\ncustom footer"
        let styled = "› \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\ncustom footer"
        func assess(_ screen: String, column: Int? = nil) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "codex", visibleText: screen, cursorRow: 0,
                cursorColumn: column, cursorVisible: true, requireEmpty: true, queueWhenWorking: false)
        }
        for column in [nil, 2, 26] as [Int?] {
            XCTAssertEqual(assess(literal, column: column), .occupied)
            XCTAssertEqual(assess(literal.replacingOccurrences(of: "Ask", with: "\u{1b}[38;2;2;2;2mAsk\u{1b}[0m"), column: column), .occupied)
        }
        XCTAssertEqual(assess(styled), .readyReturn)
        XCTAssertEqual(assess(styled, column: 2), .readyReturn)
        XCTAssertEqual(assess(styled, column: 3), .occupied)
        XCTAssertEqual(assess(styled, column: 26), .occupied)
    }

    func testClaudeSuggestedInputIsEmptyOnlyWithStyleAndCursorProof() {
        // Modeled from Claude Code 2.1.278's placeholder renderer, inspected
        // read-only: DIM text, except the focused cursor may repaint glyph one.
        // This is a deterministic classifier reproduction, not a live session.
        for suggested in [
            "\u{1b}[2mSummarize the changes\u{1b}[0m",
            "S\u{1b}[2mummarize the changes\u{1b}[0m",
            "\u{1b}[7mS\u{1b}[27m\u{1b}[2mummarize the changes\u{1b}[0m",
            "\u{1b}[38;2;90;90;90mS\u{1b}[2mummarize the changes\u{1b}[0m",
            "\u{1b}[2mExplain 日本語 and café\u{1b}[0m",
            "👋\u{1b}[2m explain the changes\u{1b}[0m",
            "e\u{0301}\u{1b}[2mcrire les tests\u{1b}[0m",
            "S\u{1b}[2mummarize the\n  changes and tests\u{1b}[0m",
        ] {
            let screen = "────\n❯\u{00a0}" + suggested + "\n────\ncustom footer"
            XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: screen,
                cursorRow: 1, cursorColumn: 2, cursorVisible: true, requireEmpty: true,
                queueWhenWorking: false), .readyReturn, suggested)
        }
    }

    /// tmux 3.4+ `capture-pane -e` keeps OSC 8 links (rows from tmux 3.6a);
    /// a file link printed above must not void the composer's DIM proof.
    func testTmuxOSC8LinksPreserveClaudeAndCodexEmptySuggestions() {
        let rule = "\u{1b}[38;2;136;136;136m────────\u{1b}[39m"
        let claude = "❯ \u{1b}[7mb\u{1b}[0;2mundle option a in WG-1\u{1b}[0m"
        let codex = "› \u{1b}[2mAsk Codex to do anything\u{1b}[0m"
        for terminator in ["\u{7}", "\u{1b}\\"] {
            let link = "see \u{1b}]8;;file:///tmp/x.swift\(terminator)x.swift\u{1b}]8;;\(terminator) done"
            XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude",
                visibleText: "\(link)\n\(rule)\n\(claude)\n\(rule)\nctx:25%",
                cursorRow: 2, cursorColumn: 2, cursorVisible: true, requireEmpty: true,
                queueWhenWorking: false), .readyReturn, terminator)
            XCTAssertEqual(AgentComposerEvidence.safety(provider: "codex",
                visibleText: "\(link)\n\(codex)\n\n95% context left",
                cursorRow: 1, cursorColumn: 2, cursorVisible: true, requireEmpty: true,
                queueWhenWorking: false), .readyReturn, terminator)
        }
    }

    func testOSC8LinksNeverHideComposerDrafts() {
        let open = "\u{1b}]8;;file:///tmp/x.swift\u{1b}\\"
        let close = "\u{1b}]8;;\u{1b}\\"
        let bodies = [
            "typed draft",
            "\(open)typed draft\(close)",
            "t y\(open)\u{1b}[2mped suggestion\u{1b}[0m\(close)",
        ]
        for body in bodies {
            XCTAssertNotEqual(AgentComposerEvidence.safety(provider: "claude",
                visibleText: "────\n❯ \(body)\n────\nctx:25%",
                cursorRow: 1, cursorColumn: 2, cursorVisible: true, requireEmpty: true,
                queueWhenWorking: false), .readyReturn, body)
        }
        XCTAssertNotEqual(AgentComposerEvidence.safety(provider: "codex",
            visibleText: "› \(open)typed draft\(close)\n\n95% context left",
            cursorRow: 0, cursorColumn: 2, cursorVisible: true, requireEmpty: true,
            queueWhenWorking: false), .readyReturn)
    }

    func testInvalidOrUnsupportedOSCSequencesFailClosed() {
        let suggestion = "────\n❯ \u{1b}[7mb\u{1b}[0;2mundle option a in WG-1\u{1b}[0m\n────\nctx:25%"
        let invalid = [
            "\u{1b}]8;;file:///tmp/x.swift",
            "\u{1b}]8;;file:///tmp/\(String(repeating: "x", count: 4_096))\u{7}",
            "\u{1b}]0;window title\u{7}",
            "\u{1b}]52;c;SGVsbG8=\u{1b}\\",
            "\u{1b}]8;;file:///tmp/\nname\u{7}",
        ]
        for sequence in invalid {
            XCTAssertNotEqual(AgentComposerEvidence.safety(provider: "claude",
                visibleText: "\(sequence)\n\(suggestion)",
                cursorRow: 2, cursorColumn: 2, cursorVisible: true, requireEmpty: true,
                queueWhenWorking: false), .readyReturn, String(sequence.prefix(40)))
        }
    }

    func testClaudePlaceholderTitleRecognizesDimSuggestionWithOSC8Elsewhere() {
        let link = "see \u{1b}]8;id=source;file:///tmp/x.swift\u{7}x.swift\u{1b}]8;;\u{7} done"
        let line = "❯ bundle option a in WG-1"
        let capture = "\(link)\n────\n❯ \u{1b}[7mb\u{1b}[0;2mundle option a in WG-1\u{1b}[0m\n────"
        XCTAssertTrue(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: line,
            visibleText: capture, cursorRow: 2))
        XCTAssertFalse(AgentComposerEvidence.isPlaceholderTitleLine(provider: "claude", line: line,
            visibleText: capture.replacingOccurrences(of: "\u{1b}[0;2m", with: "\u{1b}[0m"), cursorRow: 2))
    }

    func testClaudeSuggestionsNeverDiscardRealDraftsOrUnprovenRendering() {
        func assess(_ body: String, column: Int? = 2, row: Int = 1, visible: Bool = true) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "claude", visibleText: "────\n❯ " + body + "\n────\nfooter",
                cursorRow: row, cursorColumn: column, cursorVisible: visible, requireEmpty: true,
                queueWhenWorking: false)
        }
        let ghost = "S\u{1b}[2mummarize the changes\u{1b}[0m"
        for column in [nil, -1, 0, 1, 3, 24] as [Int?] {
            XCTAssertEqual(assess(ghost, column: column), .occupied)
        }
        for body in ["Summarize the changes", "S", "\u{1b}[7mS\u{1b}[0m", "e\u{1b}[2m\u{0301}\u{1b}[0m",
                     "typed\u{1b}[2m suggestion\u{1b}[0m", "\u{1b}[38;2;2;2;2mgray draft\u{1b}[0m",
                     "\u{1b}[3mitalic draft\u{1b}[0m", "\u{1b}[2mghost\u{1b}[22m typed tail",
                     ghost + "\n  typed second line", ghost + "\u{1b}[2K",
                     "\u{1b}[2mghost\u{1b}[999m", "\t\u{1b}[2mghost\u{1b}[0m"] {
            XCTAssertNotEqual(assess(body), .readyReturn, body)
        }
        XCTAssertEqual(assess(ghost, visible: false), .blocked)
        XCTAssertNotEqual(assess(ghost + "\n  \u{1b}[2mmore\u{1b}[0m", row: 2), .readyReturn)
    }

    func testAnimatedCodexEmptyPlaceholderRequiresDimEvidenceAndPreservesDrafts() {
        let styled = "\u{1b}[1m›\u{1b}[0m\u{1b}[38;2;80;80;80m⠁\u{1b}[2m\u{1b}[39mAsk Codex to do anything\u{1b}[0m ⠐\n  ⠁ ⢀\ncustom footer\n"
        func assess(_ text: String, column: Int? = nil) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "codex", visibleText: text, cursorRow: 0,
                cursorColumn: column, cursorVisible: true, requireEmpty: true, queueWhenWorking: false)
        }
        XCTAssertEqual(assess(styled), .readyReturn)
        XCTAssertEqual(assess(styled, column: 2), .readyReturn)
        XCTAssertNotEqual(assess(styled, column: 3), .readyReturn)
        XCTAssertNotEqual(assess(styled.replacingOccurrences(of: "\u{1b}[2m", with: "")), .readyReturn)
        XCTAssertNotEqual(assess(styled.replacingOccurrences(of: "\u{1b}[39mAsk", with: "\u{1b}[22mAsk")), .readyReturn)
        XCTAssertNotEqual(assess(styled.replacingOccurrences(of: "\u{1b}[2m", with: "\u{1b}[38;2;80;80;80m")), .readyReturn)
        XCTAssertNotEqual(assess(styled.replacingOccurrences(of: "anything", with: "anything extra draft")), .readyReturn)
        XCTAssertNotEqual(assess(styled.replacingOccurrences(of: "  ⠁ ⢀", with: "  actual second draft line")), .readyReturn)
        XCTAssertNotEqual(assess("› ⠁⢀\n\ncustom footer"), .readyReturn)
        XCTAssertNotEqual(assess("› Ask Codex to do anything⠁\n\ncustom footer"), .readyReturn)
    }
    func testFastSafetyAcceptsCustomFooterAndArbitraryPayloadButBlocksModalAndExistingDraft() {
        func assess(_ screen: String, row: Int = 0, visible: Bool? = true, empty: Bool = false, queue: Bool = false) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "codex", visibleText: screen, cursorRow: row, cursorVisible: visible, requireEmpty: empty, queueWhenWorking: queue)
        }
        XCTAssertEqual(assess("›\n\nmy completely custom status", empty: true), .readyReturn)
        XCTAssertEqual(assess("› first test sending a message to you\n\nany footer"), .readyReturn)
        XCTAssertEqual(assess("› 1. check this\n────\nnext", row: 2), .readyReturn)
        XCTAssertEqual(assess("›\n\ncustom", queue: true), .readyTab, "unchanged pre-render capture must not steer")
        XCTAssertEqual(assess("› 1. current model", visible: false), .blocked)
        XCTAssertEqual(assess("›", visible: nil), .unavailable)
        XCTAssertEqual(assess("› stranded draft\n\ncustom", empty: true), .occupied)
        XCTAssertEqual(assess("›\nexisting draft\n\ncustom", empty: true), .occupied)
    }
    func testClaudeMultilineEditorHintFromLiveCapture() {
        let message = "Reply exactly TESSERA_ANDROID_SEND_OK_1788904997384.\n\nDo not run tools or modify files.\n"
        let visible = "────\n❯ Reply exactly\n  TESSERA_ANDROID_SEND_OK_1788904997384.\n\n  Do not run tools or modify files.\n\n────\n  ctx:6%  Fable 5.1  eff:xhigh  main  tessera\n  ⏵⏵ auto mode on (shift+tab to cycle)\n  ctrl+g to edit in VS Code\n"
        XCTAssertTrue(AgentComposerEvidence.matches(provider: "claude", visibleText: visible, cursorLine: "", text: message, cursorRow: 5))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "claude", visibleText: visible + "unknown trailing content", cursorLine: "", text: message, cursorRow: 5))
    }

    func testClaudePasteEventsPreserveExactBytesWithoutOpaqueMultilineBadges() throws {
        for text in ["first line\n\nsecond line\n", "\nfirst  \nsecond", String(repeating: "é", count: 700) + "\nlast"] {
            let bytes = try XCTUnwrap(AgentTextInsertion.bytes(provider: "claude", text: text, bracketedPasteEnabled: true))
            let encoded = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            let parts = encoded.components(separatedBy: "\u{1b}[200~").dropFirst().map { String($0.dropLast("\u{1b}[201~".count)) }
            XCTAssertEqual(parts.joined(), text)
            XCTAssertTrue(parts.allSatisfy { $0.filter { $0 == "\n" }.count <= 1 && $0.utf8.count <= 259 })
            XCTAssertEqual(encoded, parts.map { "\u{1b}[200~" + $0 + "\u{1b}[201~" }.joined())
        }
        XCTAssertEqual(AgentTextInsertion.bytes(provider: "codex", text: "hello", bracketedPasteEnabled: false), Data("\u{1b}[200~hello\u{1b}[201~".utf8))
        XCTAssertNil(AgentTextInsertion.bytes(provider: "claude", text: "hello\u{1b}", bracketedPasteEnabled: true))
        XCTAssertNil(AgentTextInsertion.bytes(provider: "unknown", text: "hello\nworld", bracketedPasteEnabled: false))
    }

    func testPhysicalCursorRowsProveMultilineAndRepeatedDraftRows() {
        for provider in ["codex", "claude"] {
            let marker = provider == "codex" ? "› " : "❯\u{00a0}"
            let footer = provider == "codex" ? "\n\n95% context left" : "\n────\nctx:25%"
            for (text, rows) in [
                ("first line\nsecond line", ["first line", "second line"]),
                ("first line  \nsecond line", ["first line", "second line"]),
                ("first line\n\nsecond line", ["first line", "", "second line"]),
                ("line\nline\nline", ["line", "line", "line"]),
                ("first line\nsecond line\n", ["first line", "second line", ""]),
                ("\n\nhello", ["", "", "hello"]),
            ] {
                let screen = marker + rows.joined(separator: "\n") + footer
                let cursor = rows.count == 1 ? marker + rows[0] : rows.last!
                XCTAssertEqual(AgentComposerEvidence.presence(provider: provider, visibleText: screen,
                    cursorLine: cursor, text: text, cursorRow: rows.count - 1), .present, text)
                XCTAssertEqual(AgentComposerEvidence.presence(provider: provider, visibleText: screen,
                    cursorLine: cursor, text: text), .unavailable)
                XCTAssertEqual(AgentComposerEvidence.presence(provider: provider, visibleText: screen,
                    cursorLine: cursor, text: text, cursorRow: rows.count + 1), .unavailable)
            }
            XCTAssertEqual(AgentComposerEvidence.presence(provider: provider, visibleText: marker + "abc" + footer,
                cursorLine: marker + "abc", text: "a\tbc", cursorRow: 0), .unavailable)
            XCTAssertEqual(AgentComposerEvidence.presence(provider: provider, visibleText: marker + "hello" + footer,
                cursorLine: marker + "hello", text: "hello\n\n", cursorRow: 0), .unavailable)
            XCTAssertEqual(AgentComposerEvidence.presence(provider: provider, visibleText: marker + "one\ntwo\nextra" + footer,
                cursorLine: "two", text: "one\ntwo", cursorRow: 1), .unavailable)
        }
    }

    func testCodexDefaultOrDisabledStatusLineDoesNotStrandInput() {
        let text = "Reply exactly TOKEN. Do not run tools or modify files."
        for footer in ["95% context left", "? for shortcuts                     95% context left", "? for shortcuts", ""] {
            let visible = "› Reply exactly TOKEN. Do not run tools or\n  modify files.\n\n\(footer)"
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: visible,
                cursorLine: "  modify files.", text: text), .present)
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: "› Ask Codex to do anything\n\n\(footer)",
                cursorLine: "› Ask Codex to do anything", text: text), .absent)
        }
    }
    func testLiveClaudeComposerUsesNonbreakingPromptSpacing() {
        // Captured from the real narrow Claude Code pane after Agent Center
        // inserted this message but withheld Return.
        let screen = "❯\u{00a0}Reply exactly\n  TESSERA_ANDROID_SEND_OK_1788883012255. Do not\n  run tools or modify files.\n──────────────────────────────────────────────────\n  ctx:6%  Fable 5.1  eff:xhigh  main  tessera\n  ⏵⏵ auto mode on (shift+tab to cycle)\n"
        let message = "Reply exactly TESSERA_ANDROID_SEND_OK_1788883012255. Do not run tools or modify files."
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: screen,
            cursorLine: "  run tools or modify files.", text: message), .present)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText:
            "❯\u{00a0}\n──────────────────────────────────────────────────\n  ctx:6%  Fable 5.1  eff:xhigh  main  tessera\n  ⏵⏵ auto mode on (shift+tab to cycle)\n", cursorLine: "❯\u{00a0}", text: message), .absent)
    }

    func testComposerMarginsAreNotAReasonToStrandInsertedText() {
        for text in ["hello world ", "  hello world", "  hello world  "] {
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex",
                visibleText: "›   hello world  \n\ngpt-6-astra high · /repo", cursorLine: "›   hello world  ", text: text), .present)
        }
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex",
            visibleText: "› hello world extra\n\ngpt-6-astra high · /repo", cursorLine: "› hello world extra", text: "hello world "), .unavailable)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex",
            visibleText: "› \n\ngpt-6-astra high · /repo", cursorLine: "› ", text: "   "), .unavailable)
    }

    /// Captured with tmux 3.6a `capture-pane -p -e -N` from Codex CLI 0.157.1
    /// in a 49-column pane, with a configured status line (model, directory,
    /// context) and one config warning. The footer is two rows: the status
    /// line, then "? for shortcuts" (idle), "tab to queue message" (typing in
    /// a turn) or only the right-aligned indicators (typing while idle).
    func testLiveCodex0157FooterWithStatusLineAndWarningAcceptsSends() {
        let status = "  \u{1b}[38;2;246;226;183mGPT-6-Luna medium\u{1b}[39m · \u{1b}[38;2;171;223;167m~/projects/tessera\u{1b}[39m · \u{1b}[38;2;242;181;144mConte…"
        let idle = "\n\u{1b}[2m  6:57 PM\n\u{1b}[0m  \u{1b}[1mTip:\u{1b}[0m Press \u{1b}[38;2;166;227;161mctrl+t\u{1b}[39m to open the full transcript.\n\n\u{1b}[1m›\u{1b}[0m \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n\(status)\n\u{1b}[39m  \u{1b}[1m?\u{1b}[0m for shortcuts                       ⚠ \u{1b}[38;2;196;167;103m1\u{1b}[39m · \u{1b}[1mf2\u{1b}[0m"
        let wide = "\n\n\u{1b}[0m          \u{1b}[1mTip:\u{1b}[0m Use \u{1b}[1m/init\u{1b}[0m to create an \u{1b}[38;2;166;227;161mAGENTS.md\u{1b}[39m with project-specific guidance.\n\n\u{1b}[1m›\u{1b}[0m \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n  \u{1b}[38;2;246;226;183mGPT-6-Luna medium\u{1b}[39m · \u{1b}[38;2;171;223;167m~/projects/tessera\u{1b}[39m · \u{1b}[38;2;242;181;144mContext 4% used\u{1b}[39m\n  \u{1b}[1m?\u{1b}[0m for shortcuts                                      ⚠ \u{1b}[38;2;196;167;103m1 warning\u{1b}[39m · \u{1b}[1mf2\u{1b}[0m to view"
        let noStatus = "\n\n      \u{1b}[1mTip:\u{1b}[0m Press \u{1b}[38;2;166;227;161mf3\u{1b}[39m to search this conversation.\n\n\u{1b}[1m›\u{1b}[0m \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n  \u{1b}[1m?\u{1b}[0m for shortcuts  100% context left    ⚠ \u{1b}[38;2;196;167;103m1\u{1b}[39m · \u{1b}[1mf2\u{1b}[0m"
        func empty(_ screen: String, column: Int? = 2) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "codex", visibleText: screen, cursorRow: 4, cursorColumn: column,
                cursorVisible: true, requireEmpty: true, queueWhenWorking: false)
        }
        for screen in [idle, wide, noStatus] {
            XCTAssertEqual(empty(screen), .readyReturn)
            XCTAssertEqual(empty(screen, column: nil), .readyReturn)
            XCTAssertEqual(empty(screen, column: 3), .occupied)
            XCTAssertEqual(empty(screen.replacingOccurrences(of: "\u{1b}[2mAsk", with: "Ask")), .occupied)
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: screen,
                cursorLine: "› Ask Codex to do anything", text: "hello draft", cursorRow: 4), .absent)
        }
        // A typed row under the placeholder, a draft that begins with a blank
        // line, and a paste chip (cyan, cursor after it) all stay occupied.
        XCTAssertEqual(empty(idle.replacingOccurrences(of: "anything\u{1b}[0m\n\n", with: "anything\u{1b}[0m\n  typed row\n")), .occupied)
        XCTAssertEqual(empty(idle.replacingOccurrences(of: "\u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n", with: "\n  typed row\n\n")), .occupied)
        let chip = idle.replacingOccurrences(of: "\u{1b}[2mAsk Codex to do anything", with: "\u{1b}[38;5;6m[Pasted Content 1600 chars]\u{1b}[39m")
        XCTAssertEqual(empty(chip), .occupied)
        XCTAssertEqual(empty(chip, column: 29), .occupied)

        let wrapped = "\u{1b}[2m  6:57 PM\n\u{1b}[0m\n\n\u{1b}[1m›\u{1b}[0m hello draft that is long enough to wrap across\n  the narrow phone width\n\n\(status)\n\u{1b}[39m                                        ⚠ \u{1b}[38;2;196;167;103m1\u{1b}[39m · \u{1b}[1mf2\u{1b}[0m"
        let wrappedText = "hello draft that is long enough to wrap across the narrow phone width"
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: wrapped,
            cursorLine: "  the narrow phone width", text: wrappedText, cursorRow: 4), .present)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: wrapped,
            cursorLine: "  the narrow phone width", text: wrappedText), .present)
        XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: wrapped,
            cursorLine: "  the narrow phone width", text: wrappedText, queueWhenWorking: true, cursorRow: 4), .return)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: wrapped.replacingOccurrences(of: "\n\n\(status)", with: "\n  more typed text\n\(status)"),
            cursorLine: "  the narrow phone width", text: wrappedText, cursorRow: 4), .unavailable)

        // Review captures: text further down under a placeholder or bare
        // marker, a draft row posing as a status line, and a typed trailing
        // newline after a short row stay unconfirmed.
        let keep = "\u{1b}[1m›\u{1b}[0m \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n  KEEP MY DRAFT\n\n  GPT-6-Luna medium · ~/repo\n  ? for shortcuts        ⚠ 1 · f2"
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "codex", visibleText: keep, cursorRow: 0, cursorColumn: 2,
            cursorVisible: true, requireEmpty: true, queueWhenWorking: false), .occupied)
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "codex", visibleText: "›\n\n  KEEP MY DRAFT\n  ? for shortcuts", cursorRow: 0,
            cursorColumn: 2, cursorVisible: true, requireEmpty: true, queueWhenWorking: false), .occupied)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: "› wanted\n\n  EXTRA\n  ? for shortcuts",
            cursorLine: "› wanted", text: "wanted", cursorRow: 0), .unavailable)
        let newline = "› wanted" + String(repeating: " ", count: 41) + "\n" + String(repeating: " ", count: 49) + "\n\n  GPT-6-Luna medium · ~/repo\n  ? for shortcuts"
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: newline,
            cursorLine: "", text: "wanted", cursorRow: 1), .unavailable)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: "❯ wanted" + String(repeating: " ", count: 41) + "\n\n\n────────\nctx:25%",
            cursorLine: "", text: "wanted", cursorRow: 1), .unavailable)

        let noStatusDraft = "\n\n\n\n\u{1b}[1m›\u{1b}[0m hello draft\n\n                   100% context left    ⚠ \u{1b}[38;2;196;167;103m1\u{1b}[39m · \u{1b}[1mf2\u{1b}[0m"
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: noStatusDraft,
            cursorLine: "› hello draft", text: "hello draft", cursorRow: 4), .present)
        // A payload filling the 46-column wrap width parks the cursor alone on
        // the next row; a longer or shorter payload is still not confirmed.
        let full = "\n\n\u{1b}[1m›\u{1b}[0m Reply with only the word ok. Do not run tools. \n" + String(repeating: " ", count: 49) + "\n\n                   100% context left    ⚠ \u{1b}[38;2;196;167;103m1\u{1b}[39m · \u{1b}[1mf2\u{1b}[0m"
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: full,
            cursorLine: "", text: "Reply with only the word ok. Do not run tools.", cursorRow: 3), .present)
        for text in ["Reply with only the word ok. Do not run tools. More", "Reply with only the word ok."] {
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: full,
                cursorLine: "", text: text, cursorRow: 3), .unavailable, text)
        }
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: full,
            cursorLine: "", text: "Reply with only the word ok. Do not run tools."), .unavailable)

        let working = "\n\u{1b}[1m\u{1b}[38;2;167;167;167m•\u{1b}[0m \u{1b}[2mWorking\u{1b}[0m \u{1b}[2m(10s • \u{1b}[0;1mesc\u{1b}[0;2m to interrupt) · 1 backgroun…\n\u{1b}[0m\n\n\u{1b}[1m›\u{1b}[0m queued draft while working\n\n\(status)\n\u{1b}[39m  \u{1b}[1mtab\u{1b}[0m to queue message"
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: working,
            cursorLine: "› queued draft while working", text: "queued draft while working", cursorRow: 4), .present)
        XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: working,
            cursorLine: "› queued draft while working", text: "queued draft while working", queueWhenWorking: true, cursorRow: 4), .tab)
        XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: working.replacingOccurrences(of: "to queue message", with: "to queue message    ⚠ 1 · f2"),
            cursorLine: "› queued draft while working", text: "queued draft while working", queueWhenWorking: true, cursorRow: 4), .tab)
    }

    /// Codex releases have rotated other DIM placeholders through the empty
    /// input ("Implement {feature}", "Write tests for @filename", …). With the
    /// cursor proven at the input origin any DIM wording is the placeholder;
    /// a partly DIM row is a draft with an inline completion.
    func testCodexRotatingDimPlaceholdersAreEmptyOnlyWithCursorAtOrigin() {
        let footer = "\n\n  gpt-5.6-luna low · ~/repo\n  ? for shortcuts"
        func empty(_ row: String, column: Int?) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "codex", visibleText: "\u{1b}[1m›\u{1b}[0m " + row + footer, cursorRow: 0,
                cursorColumn: column, cursorVisible: true, requireEmpty: true, queueWhenWorking: false)
        }
        for wording in ["Implement {feature}", "Write tests for @filename", "Ask a follow-up question", "Explain this codebase"] {
            XCTAssertEqual(empty("\u{1b}[2m\(wording)\u{1b}[0m", column: 2), .readyReturn, wording)
            XCTAssertEqual(empty("\u{1b}[2m\(wording)\u{1b}[0m", column: nil), .occupied, wording)
            XCTAssertEqual(empty("\u{1b}[2m\(wording)\u{1b}[0m", column: 5), .occupied, wording)
            XCTAssertEqual(empty(wording, column: 2), .occupied, wording)
        }
        XCTAssertEqual(empty("Impl\u{1b}[2mement {feature}\u{1b}[0m", column: 2), .occupied)
        XCTAssertEqual(empty("\u{1b}[2mImplement\u{1b}[0m {feature}", column: 2), .occupied)
        // A bare marker proves nothing about the rows below: only padding may
        // separate it from the recognized two-row footer.
        func bare(_ screen: String) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "codex", visibleText: screen, cursorRow: 0,
                cursorColumn: 2, cursorVisible: true, requireEmpty: true, queueWhenWorking: false)
        }
        XCTAssertEqual(bare("›" + footer), .readyReturn)
        XCTAssertEqual(bare("›\n  draft row" + footer), .occupied)
        XCTAssertEqual(bare("›\n\n  draft row" + footer), .occupied)
    }

    /// Codex's collapsed async questions wait above a live composer; its
    /// expanded panel replaces the composer.
    func testCodexDeferredQuestionsLeaveTheComposerUsable() {
        func safety(_ screen: String) -> AgentComposerEvidence.Safety {
            let rows = screen.components(separatedBy: "\n")
            let row = rows.lastIndex { $0.hasPrefix("› ") || $0.hasPrefix("  › ") } ?? 0
            return AgentComposerEvidence.safety(provider: "codex", visibleText: screen, cursorRow: row, cursorVisible: true,
                                                requireEmpty: false, queueWhenWorking: false)
        }
        let collapsed = AgentPromptScreenFixtures.codexAsync2Collapsed.text
            .replacingOccurrences(of: "› Ask Codex to do anything", with: "› wanted")
        XCTAssertEqual(safety(collapsed), .readyReturn)
        XCTAssertEqual(safety(AgentPromptScreenFixtures.codexAsync2OpenQ1.text), .blocked)
    }

    func testLiveCodexWorkingComposerUsesQueueHintInsteadOfModelFooter() {
        // Captured in the owned 56-column Codex rig while a sleep tool ran.
        let text = "testing sending a message from agent center too, if you receive it means test successful and you can ignore this test message"
        let screen = """
        • Working (28s • esc to interrupt) · 1 background termi…


        › testing sending a message from agent center too, if
          you receive it means test successful and you can
          ignore this test message

          tab to queue message                97% context left
        """
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: screen,
            cursorLine: "  ignore this test message", text: text), .present)
        XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: screen,
            cursorLine: "  ignore this test message", text: text, queueWhenWorking: true), .tab)
        XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: screen,
            cursorLine: "  ignore this test message", text: text, queueWhenWorking: false), .return)
        let idle = screen.replacingOccurrences(of: "tab to queue message                97% context left", with: "gpt-5.6-luna low · /repo")
            .replacingOccurrences(of: "• Working (28s • esc to interrupt) · 1 background termi…", with: "")
        XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: idle,
            cursorLine: "  ignore this test message", text: text, queueWhenWorking: true), .return)
        // A turn still on screen without its queue hint must not be steered.
        let inFlux = screen.replacingOccurrences(of: "tab to queue message                97% context left", with: "gpt-5.6-luna low · /repo")
        XCTAssertNil(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: inFlux,
            cursorLine: "  ignore this test message", text: text, queueWhenWorking: true))
        XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: inFlux,
            cursorLine: "  ignore this test message", text: text, queueWhenWorking: false), .return)
        XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "codex",
            visibleText: "Tip: press esc to interrupt a running task.\n\n› wanted\n\n? for shortcuts",
            cursorLine: "› wanted", text: "wanted", queueWhenWorking: true, cursorRow: 2), .return)
        for invalid in ["tab to queue message extra", "tab to queue message 101% context left", "status tab to queue message", "tab to queue message\nunknown footer"] {
            let screen = "› wanted\n\n\(invalid)"
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex", visibleText: screen, cursorLine: "› wanted", text: "wanted"), .unavailable)
            XCTAssertNil(AgentComposerEvidence.submissionKey(provider: "codex", visibleText: screen, cursorLine: "› wanted", text: "wanted", queueWhenWorking: true))
        }
    }

    func testSubmissionNeedsRecognizedAbsenceNotUnavailableEvidence() {
        for (provider, screen, cursor) in [
            ("codex", "› hello world\nunknown footer", "› hello world"),
            ("codex", "› hello world!\n\ngpt-5.6 low · /repo", "› hello world!"),
            ("codex", "› prefix hello\nworld suffix\n\ngpt-5.6 low · /repo", "world suffix"),
            ("codex", "› hello world\n\ngpt-5.6 low · /repo", "missing cursor"),
            ("codex", "› hello\nworld\nworld\n\ngpt-5.6 low · /repo", "world"),
            ("claude", "❯ hello world\n────\nunknown footer", "❯ hello world")
        ] {
            XCTAssertEqual(AgentComposerEvidence.presence(provider: provider, visibleText: screen,
                cursorLine: cursor, text: "hello world"), .unavailable)
        }
        for (provider, screen, cursor) in [
            ("codex", "› \n\ngpt-5.6 low · /repo", "› "),
            ("codex", "› Ask Codex to do anything\n\ngpt-5.6 low · /repo", "› Ask Codex to do anything"),
            ("claude", "❯ \n────\nctx:25%", "❯ ")
        ] {
            XCTAssertEqual(AgentComposerEvidence.presence(provider: provider, visibleText: screen,
                cursorLine: cursor, text: "hello world"), .absent)
        }
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "codex",
            visibleText: "› hello world\n\ngpt-5.6 low · /repo", cursorLine: "› hello world", text: "hello world"), .present)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "kimi",
            visibleText: "", cursorLine: "prompt: hello world", text: "hello world"), .present)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "kimi",
            visibleText: "", cursorLine: "prompt: ", text: "hello world"), .absent)
    }

    func testWrappedComposerKeepsExactCharactersAndCursorOwnership() {
        let text = "Reply exactly TESSERA_ANDROID_SEND_OK. Do not run tools or modify files."
        let screen = "old output\n\u{1b}[1m›\u{1b}[0m Reply exactly TESSERA_ANDROID_SEND_OK. Do not   \n  run tools or modify files.  \n\ngpt-5.6-luna low · /repo"
        XCTAssertTrue(AgentComposerEvidence.matches(provider: "codex", visibleText: screen, cursorLine: "  run tools or modify files.  ", text: text))
        for wrong in [text + "!", text.replacingOccurrences(of: "not", with: "now"), "Reply exactly", ""] {
            XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: screen, cursorLine: "run tools or modify files.", text: wrong))
        }
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: screen, cursorLine: "status", text: text))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: screen, cursorLine: nil, text: text))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "claude", visibleText: screen, cursorLine: "run tools or modify files.", text: text))
    }

    func testWordSplitUnicodeAndWhitespaceStayBounded() {
        XCTAssertTrue(AgentComposerEvidence.matches(provider: "claude", visibleText: "❯ café_\n  abc\n────\nctx:25% Opus 5\n", cursorLine: "abc", text: "café_abc"))
        XCTAssertTrue(AgentComposerEvidence.matches(provider: "codex", visibleText: "› a  b\n\ngpt-5.6 low · /repo", cursorLine: "› a  b", text: "a  b"))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: "› a b", cursorLine: "› a b", text: "a  b"))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: "› abc\n› other", cursorLine: "› other", text: "abc"))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: "› abc", cursorLine: "› abc", text: "abc\n"))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: "› abc\u{1b}x", cursorLine: "› abc\u{1b}x", text: "abc"))
    }

    func testTrailingDraftAfterBlankRowsAndAmbiguousCursorFailClosed() {
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "claude", visibleText: "❯ wanted\n────", cursorLine: "❯ wanted", text: "wanted"))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "claude", visibleText: "❯ wanted\n────\nctx:25%\nunrecognized extra content", cursorLine: "❯ wanted", text: "wanted"))
        for suffix in ["  extra", "\n\n  extra"] {
            XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: "› wanted\n\(suffix)\n\ngpt-5.6 low · /repo", cursorLine: "› wanted", text: "wanted"))
        }
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: "› wanted\n\nunknown footer", cursorLine: "› wanted", text: "wanted"))
        XCTAssertFalse(AgentComposerEvidence.matches(provider: "codex", visibleText: "› a\n  b\n  b\n\ngpt-5.6 low · /repo", cursorLine: "b", text: "abb"))
    }
}
