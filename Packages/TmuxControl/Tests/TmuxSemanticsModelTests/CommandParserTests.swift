import XCTest
@testable import TmuxSemanticsModel

/// The lexer and command lookup of cmd-parse.y and cmd.c.
final class CommandParserTests: XCTestCase {
    private func words(_ line: String, version: TmuxVersion = .v3_4) -> [[String]]? {
        guard case .success(let commands) = CommandParser.parse(line, version: version) else { return nil }
        return commands.map { command in
            var result = [command.spec.name]
            for flag in command.flags.keys.sorted() {
                for value in command.flags[flag]! {
                    result.append(value.isEmpty ? "-\(flag)" : "-\(flag)=\(value)")
                }
            }
            return result + command.arguments
        }
    }

    private func failure(_ line: String, version: TmuxVersion = .v3_4) -> String? {
        guard case .failure(let message) = CommandParser.parse(line, version: version) else { return nil }
        return message
    }

    private func unsupported(_ line: String) -> String? {
        guard case .unsupported(let message) = CommandParser.parse(line, version: .v3_4) else { return nil }
        return message
    }

    func testQuotingEscapesAndSemicolons() {
        XCTAssertEqual(words("set-option @a 'v1 A 1 iPad'"), [["set-option", "@a", "v1 A 1 iPad"]])
        XCTAssertEqual(words("set @a \"x y\"z"), [["set-option", "@a", "x yz"]])
        XCTAssertEqual(words("set @a a\\;b"), [["set-option", "@a", "a;b"]])
        XCTAssertEqual(words("set @a 'a;b'"), [["set-option", "@a", "a;b"]])
        XCTAssertEqual(words("selectw ; refresh -C 1,2"), [["select-window"], ["refresh-client", "-C=1,2"]])
        XCTAssertEqual(words("selectw; refresh -C 1,2;"), [["select-window"], ["refresh-client", "-C=1,2"]])
        XCTAssertEqual(words("selectw ;; selectw"), [["select-window"], ["select-window"]])
        XCTAssertEqual(words("selectw -t $0:@1"), [["select-window", "-t=$0:@1"]], "$ before a digit stays literal")
        XCTAssertEqual(words("selectw -t %3"), [["select-window", "-t=%3"]])
        XCTAssertEqual(words("display -p '#{session_name}' # trailing comment"), [["display-message", "-p", "#{session_name}"]])
        XCTAssertEqual(words("display -p #{session_name}"), [["display-message", "-p"]], "an unquoted # starts a comment")
        XCTAssertEqual(words("display -p \\e\\s\\101"), [["display-message", "-p", "\u{1B} A"]])
        XCTAssertEqual(words("   "), [])
        XCTAssertEqual(words("display -p 'unterminated"), [["display-message", "-p", "unterminated"]])
    }

    func testFlagParsing() {
        XCTAssertEqual(words("resize-window -x100 -y 30 -t @1"), [["resize-window", "-t=@1", "-x=100", "-y=30"]])
        XCTAssertEqual(words("show -gv @x"), [["show-options", "-g", "-v", "@x"]])
        XCTAssertEqual(words("refresh -B a:b:c -B d:e:f"), [["refresh-client", "-B=a:b:c", "-B=d:e:f"]])
        XCTAssertEqual(words("set -- -x"), [["set-option", "-x"]])
        XCTAssertEqual(words("set - x"), [["set-option", "-", "x"]])
    }

    func testCommandLookup() {
        XCTAssertEqual(words("select-w")?.first?.first, "select-window", "a unique prefix")
        XCTAssertEqual(words("set @x 1")?.first?.first, "set-option", "an alias beats the ambiguous prefix")
        XCTAssertEqual(failure("sel"), "ambiguous command: sel, could be: select-layout, select-pane, select-window")
        XCTAssertEqual(failure("bogus"), "unknown command: bogus")
        XCTAssertEqual(unsupported("send-keys x"), "command send-keys")
        XCTAssertEqual(unsupported("ls"), "command list-sessions")
    }

    func testParseErrorsPerVersion() {
        XCTAssertEqual(failure("selectw -Q"), "command select-window: unknown flag -Q")
        XCTAssertEqual(failure("selectw -Q", version: .v3_2), "usage: select-window [-lnpT] [-t target-window]")
        XCTAssertEqual(failure("selectw -t"), "command select-window: -t expects an argument")
        XCTAssertEqual(failure("set"), "command set-option: too few arguments (need at least 1)")
        XCTAssertEqual(failure("set a b c"), "command set-option: too many arguments (need at most 2)")
        XCTAssertEqual(failure("set a b c", version: .v3_2), "usage: set-option [-aFgopqsuUw] [-t target-pane] option [value]")
        XCTAssertEqual(failure("; selectw"), "syntax error")
        XCTAssertEqual(failure("display \\9"), "invalid octal escape")
        XCTAssertEqual(failure("refresh -r '%1:x'", version: .v3_4), "command refresh-client: unknown flag -r")
        XCTAssertNotNil(words("refresh -r '%1:x'", version: .v3_6a))
        XCTAssertEqual(failure("refresh -r %1:x", version: .v3_6a), "syntax error",
                       "an unquoted word starting with % and not all digits is a condition (cmd-parse.y:1312-1347)")
    }

    func testUnsupportedSyntax() {
        XCTAssertEqual(unsupported("display -p $HOME"), "environment variable $HOME")
        XCTAssertEqual(unsupported("display -p ~"), "~ expansion")
        XCTAssertEqual(unsupported("if -F 1 { selectw }"), "command blocks ({ })")
        XCTAssertEqual(unsupported("A=1 selectw"), "environment assignment A=1")
        XCTAssertEqual(unsupported("%if 1"), "conditional directive %if")
    }

    func testParseErrorReachesControlClientAsOneBlock() {
        let m = TmuxServerModel()
        let (session, _) = m.newSession("O", size: CellSize(80, 24))
        let client = m.connect(control: "device", session: session)
        XCTAssertEqual(normalized(m.send(client, "selectw -Q")),
                       ["%begin 1", "parse error: command select-window: unknown flag -Q", "%error 1"])
        XCTAssertEqual(m.send(client, "  "), [], "a blank line parses to nothing and prints nothing")
        assertFullyModelled(m)
    }
}
