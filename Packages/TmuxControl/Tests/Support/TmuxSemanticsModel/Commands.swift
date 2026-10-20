import Foundation

// Command-line parsing: the lexer of cmd-parse.y (yylex, yylex_token and its
// helpers, cmd-parse.y:1191-1717), command lookup (cmd_find, cmd.c:450-496)
// and flag parsing (args_parse in arguments.c, which is not in the verified
// source subset; its error texts are reproduced from memory and marked so).
//
// A control-mode line is parsed as one unit with CMD_PARSE_ONEGROUP: any
// parse error rejects the whole line before anything runs, and the client
// receives a single `%begin`/`parse error: ...`/`%error` block
// (control_read_callback and control_error, control.c:521-575).
// cmd_parse_build_commands frees the accumulated list on a later parse error;
// no successfully parsed prefix executes (verified in 3.2, 3.3a, 3.4, 3.6a).

/// The commands the model executes.
enum CommandKind {
    case attachSession
    case selectWindow
    case refreshClient
    case resizeWindow
    case setOption
    case setWindowOption
    case showOptions
    case showWindowOptions
    case displayMessage
    case listClients
}

/// How cmdq_fire_command finds the target client (cmd-queue.c:624-640).
enum ClientLookup {
    /// `cmd_find_client(item, NULL, 1)`.
    case current
    /// CMD_CLIENT_TFLAG: `-t` names the client.
    case tFlag(quiet: Bool)
    /// CMD_CLIENT_CFLAG: `-c` names the client.
    case cFlag(quiet: Bool)
}

struct CommandTargetSpec {
    let flag: Character
    let type: FindType
    let flags: FindFlags
}

/// `struct cmd_entry` for one modelled command.
struct CommandSpec {
    let name: String
    let alias: String?
    let kind: CommandKind
    let lower: Int
    let upper: Int
    let target: CommandTargetSpec?
    let client: ClientLookup
    let templates: (TmuxVersion) -> String
    let usages: (TmuxVersion) -> String

    func template(_ version: TmuxVersion) -> String { templates(version) }
    func usage(_ version: TmuxVersion) -> String { usages(version) }
}

private let targetSessionUsage = "[-t target-session]"
private let targetWindowUsage = "[-t target-window]"
private let targetPaneUsage = "[-t target-pane]"
private let targetClientUsage = "[-t target-client]"

enum CommandTable {
    /// The modelled entries. Templates and usages are copied from each
    /// release's `cmd_entry` (cmd-attach-session.c:36-48,
    /// cmd-select-window.c:32-43, cmd-refresh-client.c:33-43,
    /// cmd-resize-window.c:32-44, cmd-set-option.c:35-59,
    /// cmd-show-options.c:37-61, cmd-list-clients.c:40-51). display-message
    /// is not in the verified subset; its template is from memory.
    static let modelled: [CommandSpec] = [
        CommandSpec(
            name: "attach-session", alias: "attach", kind: .attachSession, lower: 0, upper: 0,
            target: nil, client: .current,
            templates: { _ in "c:dEf:rt:x" },
            usages: { _ in "[-dErx] [-c working-directory] [-f flags] " + targetSessionUsage }
        ),
        CommandSpec(
            name: "select-window", alias: "selectw", kind: .selectWindow, lower: 0, upper: 0,
            target: CommandTargetSpec(flag: "t", type: .window, flags: []), client: .current,
            templates: { _ in "lnpTt:" },
            usages: { _ in "[-lnpT] " + targetWindowUsage }
        ),
        CommandSpec(
            name: "refresh-client", alias: "refresh", kind: .refreshClient, lower: 0, upper: 1,
            target: nil, client: .tFlag(quiet: false),
            templates: { version in
                switch version {
                case .v3_2: "A:B:cC:Df:F:lLRSt:U"
                case .v3_3a, .v3_4: "A:B:cC:Df:F:l::LRSt:U"
                case .v3_6a: "A:B:cC:Df:r:F:l::LRSt:U"
                }
            },
            usages: { version in
                version >= .v3_6a
                    ? "[-cDlLRSU] [-A pane:state] [-B name:what:format] [-C XxY] [-f flags] [-r pane:report] " + targetClientUsage + " [adjustment]"
                    : "[-cDlLRSU] [-A pane:state] [-B name:what:format] [-C XxY] [-f flags] " + targetClientUsage + " [adjustment]"
            }
        ),
        CommandSpec(
            name: "resize-window", alias: "resizew", kind: .resizeWindow, lower: 0, upper: 1,
            target: CommandTargetSpec(flag: "t", type: .window, flags: []), client: .current,
            templates: { _ in "aADLRt:Ux:y:" },
            usages: { _ in "[-aADLRU] [-x width] [-y height] " + targetWindowUsage + " [adjustment]" }
        ),
        CommandSpec(
            name: "set-option", alias: "set", kind: .setOption, lower: 1, upper: 2,
            target: CommandTargetSpec(flag: "t", type: .pane, flags: [.canFail]), client: .current,
            templates: { _ in "aFgopqst:uUw" },
            usages: { _ in "[-aFgopqsuUw] " + targetPaneUsage + " option [value]" }
        ),
        CommandSpec(
            name: "set-window-option", alias: "setw", kind: .setWindowOption, lower: 1, upper: 2,
            target: CommandTargetSpec(flag: "t", type: .window, flags: [.canFail]), client: .current,
            templates: { _ in "aFgoqt:u" },
            usages: { _ in "[-aFgoqu] " + targetWindowUsage + " option [value]" }
        ),
        CommandSpec(
            name: "show-options", alias: "show", kind: .showOptions, lower: 0, upper: 1,
            target: CommandTargetSpec(flag: "t", type: .pane, flags: [.canFail]), client: .current,
            templates: { _ in "AgHpqst:vw" },
            usages: { _ in "[-AgHpqsvw] " + targetPaneUsage + " [option]" }
        ),
        CommandSpec(
            name: "show-window-options", alias: "showw", kind: .showWindowOptions, lower: 0, upper: 1,
            target: CommandTargetSpec(flag: "t", type: .window, flags: [.canFail]), client: .current,
            templates: { _ in "gvt:" },
            usages: { _ in "[-gv] " + targetWindowUsage + " [option]" }
        ),
        CommandSpec(
            name: "display-message", alias: "display", kind: .displayMessage, lower: 0, upper: 1,
            target: CommandTargetSpec(flag: "t", type: .pane, flags: []), client: .cFlag(quiet: true),
            // From memory (cmd-display-message.c is not in the verified subset).
            templates: { version in
                switch version {
                case .v3_2: "ac:d:INpt:F:v"
                case .v3_3a: "aCc:d:INpt:F:v"
                case .v3_4, .v3_6a: "aCc:d:lINpt:F:v"
                }
            },
            usages: { version in
                version >= .v3_4
                    ? "[-aCIlNpv] [-c target-client] [-d delay] [-F format] " + targetPaneUsage + " [message]"
                    : "[-aCINpv] [-c target-client] [-d delay] [-F format] " + targetPaneUsage + " [message]"
            }
        ),
        CommandSpec(
            name: "list-clients", alias: "lsc", kind: .listClients, lower: 0, upper: 0,
            target: CommandTargetSpec(flag: "t", type: .session, flags: []), client: .current,
            // `-f` arrived in 3.4 (cmd-list-clients.c:44; 3.2 and 3.3a are "F:t:").
            templates: { version in version.hasListClientsFilter ? "F:f:t:" : "F:t:" },
            usages: { version in
                version.hasListClientsFilter
                    ? "[-F format] [-f filter] " + targetSessionUsage
                    : "[-F format] " + targetSessionUsage
            }
        ),
    ]

    /// Every command name in `cmd_table` order (cmd.c), with its alias, so
    /// that prefixes and aliases resolve as tmux resolves them. The aliases of
    /// unmodelled commands are from memory. `clear-prompt-history`,
    /// `server-access` and `show-prompt-history` are absent from 3.2.
    static let all: [(name: String, alias: String?)] = [
        ("attach-session", "attach"), ("bind-key", "bind"), ("break-pane", "breakp"),
        ("capture-pane", "capturep"), ("choose-buffer", nil), ("choose-client", nil),
        ("choose-tree", nil), ("clear-history", "clearhist"), ("clear-prompt-history", "clearphist"),
        ("clock-mode", nil), ("command-prompt", nil), ("confirm-before", "confirm"),
        ("copy-mode", nil), ("customize-mode", nil), ("delete-buffer", "deleteb"),
        ("detach-client", "detach"), ("display-menu", "menu"), ("display-message", "display"),
        ("display-popup", "popup"), ("display-panes", "displayp"), ("find-window", "findw"),
        ("has-session", "has"), ("if-shell", "if"), ("join-pane", "joinp"),
        ("kill-pane", "killp"), ("kill-server", nil), ("kill-session", nil),
        ("kill-window", "killw"), ("last-pane", "lastp"), ("last-window", "last"),
        ("link-window", "linkw"), ("list-buffers", "lsb"), ("list-clients", "lsc"),
        ("list-commands", "lscm"), ("list-keys", "lsk"), ("list-panes", "lsp"),
        ("list-sessions", "ls"), ("list-windows", "lsw"), ("load-buffer", "loadb"),
        ("lock-client", "lockc"), ("lock-server", "lock"), ("lock-session", "locks"),
        ("move-pane", "movep"), ("move-window", "movew"), ("new-session", "new"),
        ("new-window", "neww"), ("next-layout", "nextl"), ("next-window", "next"),
        ("paste-buffer", "pasteb"), ("pipe-pane", "pipep"), ("previous-layout", "prevl"),
        ("previous-window", "prev"), ("refresh-client", "refresh"), ("rename-session", "rename"),
        ("rename-window", "renamew"), ("resize-pane", "resizep"), ("resize-window", "resizew"),
        ("respawn-pane", "respawnp"), ("respawn-window", "respawnw"), ("rotate-window", "rotatew"),
        ("run-shell", "run"), ("save-buffer", "saveb"), ("select-layout", "selectl"),
        ("select-pane", "selectp"), ("select-window", "selectw"), ("send-keys", "send"),
        ("send-prefix", nil), ("server-access", nil), ("set-buffer", "setb"),
        ("set-environment", "setenv"), ("set-hook", nil), ("set-option", "set"),
        ("set-window-option", "setw"), ("show-buffer", "showb"), ("show-environment", "showenv"),
        ("show-hooks", nil), ("show-messages", "showmsgs"), ("show-options", "show"),
        ("show-prompt-history", "showphist"), ("show-window-options", "showw"),
        ("source-file", "source"), ("split-window", "splitw"), ("start-server", "start"),
        ("suspend-client", "suspendc"), ("swap-pane", "swapp"), ("swap-window", "swapw"),
        ("switch-client", "switchc"), ("unbind-key", "unbind"), ("unlink-window", "unlinkw"),
        ("wait-for", "wait"),
    ]

    static func table(for version: TmuxVersion) -> [(name: String, alias: String?)] {
        guard version == .v3_2 else { return all }
        let missing: Set<String> = ["clear-prompt-history", "server-access", "show-prompt-history"]
        return all.filter { !missing.contains($0.name) }
    }
}

/// One parsed command: `struct cmd` with its `struct args`.
struct ParsedCommand {
    let spec: CommandSpec
    /// Flag → values in order; a flag without an argument has one empty value.
    var flags: [Character: [String]] = [:]
    var arguments: [String] = []

    func has(_ flag: Character) -> Bool { flags[flag] != nil }

    /// args_get: the last value given for the flag.
    func value(_ flag: Character) -> String? { flags[flag]?.last }

    func values(_ flag: Character) -> [String] { flags[flag] ?? [] }
}

enum ParseOutcome {
    case success([ParsedCommand])
    /// What tmux reports after `parse error: `.
    case failure(String)
    /// Valid tmux that the model does not implement.
    case unsupported(String)
}

enum CommandParser {
    enum Token: Equatable {
        case word(String)
        case semicolon
        case brace
    }

    enum LexError: Error {
        case failure(String)
        case unsupported(String)
    }

    static func parse(_ line: String, version: TmuxVersion) -> ParseOutcome {
        let tokens: [Token]
        do {
            tokens = try lex(line)
        } catch LexError.failure(let message) {
            return .failure(message)
        } catch LexError.unsupported(let message) {
            return .unsupported(message)
        } catch {
            return .failure("syntax error")
        }
        // statement/commands (cmd-parse.y:153-184, 372-450): commands are
        // separated by `;`, trailing and repeated `;` are accepted, a leading
        // `;` is a syntax error, and `{ }` blocks are not modelled.
        var statements: [[String]] = []
        var current: [String] = []
        var sawCommand = false
        for token in tokens {
            switch token {
            case .brace:
                return .unsupported("command blocks ({ })")
            case .semicolon:
                if !sawCommand { return .failure("syntax error") }
                if !current.isEmpty { statements.append(current) }
                current = []
            case .word(let word):
                if current.isEmpty, isAssignment(word) {
                    return .unsupported("environment assignment \(word)")
                }
                current.append(word)
                sawCommand = true
            }
        }
        if !current.isEmpty { statements.append(current) }

        var commands: [ParsedCommand] = []
        for words in statements {
            switch buildCommand(words, version: version) {
            case .success(let parsed): commands.append(contentsOf: parsed)
            case .failure(let message): return .failure(message)
            case .unsupported(let message): return .unsupported(message)
            }
        }
        return .success(commands)
    }

    /// The EQUALS token test of yylex (cmd-parse.y:1357-1364).
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), let first = word.first, isVariableCharacter(first, first: true) else {
            return false
        }
        return word[..<equals].allSatisfy { isVariableCharacter($0, first: false) }
    }

    /// yylex_is_var (cmd-parse.y:1137-1144).
    static func isVariableCharacter(_ character: Character, first: Bool) -> Bool {
        if character == "=" { return false }
        guard character.isASCII else { return false }
        if first, character.isNumber { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    // MARK: Lexer

    /// yylex (cmd-parse.y:1241-1368) over one line.
    static func lex(_ line: String) throws -> [Token] {
        var reader = Reader(Array(line))
        var tokens: [Token] = []
        while let ch = reader.next() {
            switch ch {
            case " ", "\t":
                continue
            case "\n":
                return tokens
            case ";":
                tokens.append(.semicolon)
            case "{", "}":
                tokens.append(.brace)
            case "#":
                // A comment runs to the end of the line (cmd-parse.y:1291-1310).
                return tokens
            case "%":
                // `%` starts a condition unless the word is all `%` and
                // digits (cmd-parse.y:1312-1347).
                var word = "%"
                while let next = reader.peek(), next != " ", next != "\t", next != "\n" {
                    word.append(next)
                    _ = reader.next()
                }
                if word.allSatisfy({ $0 == "%" || ($0.isASCII && $0.isNumber) }) {
                    tokens.append(.word(word))
                } else if ["%if", "%else", "%elif", "%endif", "%hidden"].contains(word) {
                    throw LexError.unsupported("conditional directive \(word)")
                } else {
                    throw LexError.failure("syntax error")
                }
            default:
                tokens.append(.word(try lexToken(first: ch, reader: &reader)))
            }
        }
        return tokens
    }

    struct Reader {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) { self.characters = characters }

        mutating func next() -> Character? {
            guard index < characters.count else { return nil }
            defer { index += 1 }
            return characters[index]
        }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        mutating func unget() { index -= 1 }
    }

    enum QuoteState { case start, none, double, single }

    /// yylex_token (cmd-parse.y:1603-1717). An unterminated quote simply
    /// ends at the end of the line, as in tmux.
    static func lexToken(first: Character, reader: inout Reader) throws -> String {
        var buffer = ""
        var state = QuoteState.none
        var last = QuoteState.start
        var current: Character? = first
        while let ch = current {
            if state == .none, ch == "\n" || ch == " " || ch == "\t" || ch == ";" || ch == "}" {
                reader.unget()
                return buffer
            }
            var skipLast = false
            if ch == "\\", state != .single {
                try lexEscape(into: &buffer, reader: &reader)
            } else if ch == "~", last != state, state != .single {
                throw LexError.unsupported("~ expansion")
            } else if ch == "$", state != .single {
                try lexVariable(into: &buffer, reader: &reader)
            } else if ch == "'", state == .none || state == .single {
                state = state == .none ? .single : .none
                skipLast = true
            } else if ch == "\"", state == .none || state == .double {
                state = state == .none ? .double : .none
                skipLast = true
            } else {
                buffer.append(ch)
            }
            if !skipLast { last = state }
            current = reader.next()
        }
        return buffer
    }

    /// yylex_token_escape (cmd-parse.y:1411-1507).
    static func lexEscape(into buffer: inout String, reader: inout Reader) throws {
        guard let ch = reader.next() else { throw LexError.failure("syntax error") }
        if let digit = ch.wholeNumberValue, ch.isASCII {
            guard digit <= 3 else { throw LexError.failure("invalid octal escape") }
            guard let o2 = reader.next(), let d2 = o2.wholeNumberValue, o2.isASCII, d2 <= 7,
                  let o3 = reader.next(), let d3 = o3.wholeNumberValue, o3.isASCII, d3 <= 7
            else { throw LexError.failure("invalid octal escape") }
            buffer.unicodeScalars.append(Unicode.Scalar(UInt8(64 * digit + 8 * d2 + d3)))
            return
        }
        switch ch {
        case "a": buffer.append("\u{07}")
        case "b": buffer.append("\u{08}")
        case "e": buffer.append("\u{1B}")
        case "f": buffer.append("\u{0C}")
        case "s": buffer.append(" ")
        case "v": buffer.append("\u{0B}")
        case "r": buffer.append("\r")
        case "n": buffer.append("\n")
        case "t": buffer.append("\t")
        case "u", "U":
            let size = ch == "u" ? 4 : 8
            var hex = ""
            for _ in 0..<size {
                guard let digit = reader.next(), digit != "\n" else { throw LexError.failure("syntax error") }
                guard digit.isHexDigit else { throw LexError.failure("invalid \\\(ch) argument") }
                hex.append(digit)
            }
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                throw LexError.failure("invalid \\\(ch) argument")
            }
            buffer.unicodeScalars.append(scalar)
        default:
            buffer.append(ch)
        }
    }

    /// yylex_token_variable (cmd-parse.y:1509-1559). `$` before a character
    /// that cannot start a name stays literal (so `$0` is a session id); a
    /// real variable reads the server's global environment, which the model
    /// does not have.
    static func lexVariable(into buffer: inout String, reader: inout Reader) throws {
        guard let ch = reader.next() else { throw LexError.failure("syntax error") }
        var name = ""
        if ch == "{" {
            while true {
                guard let next = reader.next() else { throw LexError.failure("invalid environment variable") }
                if next == "}" { break }
                guard isVariableCharacter(next, first: false) else {
                    throw LexError.failure("invalid environment variable")
                }
                name.append(next)
            }
        } else {
            guard isVariableCharacter(ch, first: true) else {
                buffer.append("$")
                reader.unget()
                return
            }
            name.append(ch)
            while let next = reader.peek(), isVariableCharacter(next, first: false) {
                name.append(next)
                _ = reader.next()
            }
        }
        throw LexError.unsupported("environment variable $\(name)")
    }

    // MARK: Commands and flags

    /// cmd_parse (cmd.c:500-536) for one command's words.
    static func buildCommand(_ words: [String], version: TmuxVersion) -> ParseOutcome {
        let name = words[0]
        let resolved: String
        switch findCommand(name, version: version) {
        case .failure(let message): return .failure(message)
        case .unsupported(let message): return .unsupported(message)
        case .success(let found): resolved = found
        }
        guard let spec = CommandTable.modelled.first(where: { $0.name == resolved }) else {
            return .unsupported("command \(resolved)")
        }
        switch parseArguments(spec, Array(words.dropFirst()), version: version) {
        case .success(let command):
            return .success([command])
        case .usage:
            return .failure("usage: \(spec.name) \(spec.usage(version))")
        case .error(let message):
            return .failure("command \(spec.name): \(message)")
        }
    }

    enum FindOutcome {
        case success(String)
        case failure(String)
        case unsupported(String)
    }

    /// cmd_find (cmd.c:450-496): an exact alias wins; otherwise a name or a
    /// prefix, and a prefix of several names is ambiguous.
    static func findCommand(_ name: String, version: TmuxVersion) -> FindOutcome {
        var found: String?
        var ambiguous = false
        for entry in CommandTable.table(for: version) {
            if entry.alias == name {
                ambiguous = false
                found = entry.name
                break
            }
            guard entry.name.hasPrefix(name) else { continue }
            if found != nil { ambiguous = true }
            found = entry.name
            if entry.name == name { break }
        }
        if ambiguous {
            let candidates = CommandTable.table(for: version).map(\.name).filter { $0.hasPrefix(name) }
            return .failure("ambiguous command: \(name), could be: \(candidates.joined(separator: ", "))")
        }
        guard let found else { return .failure("unknown command: \(name)") }
        return .success(found)
    }

    enum ArgumentsOutcome {
        case success(ParsedCommand)
        /// A NULL result with no cause: cmd_parse prints the usage line.
        case usage
        case error(String)
    }

    /// args_parse. 3.3a+ (arguments.c, from memory) names the problem:
    /// "unknown flag -X", "invalid flag -X", "-X expects an argument",
    /// "too few arguments (need at least N)", "too many arguments (need at
    /// most N)"; 3.2 used getopt and reports every failure as a usage line
    /// (3.2 cmd.c:541).
    static func parseArguments(_ spec: CommandSpec, _ words: [String], version: TmuxVersion) -> ArgumentsOutcome {
        let template = Array(spec.template(version))
        var command = ParsedCommand(spec: spec)
        var index = 0
        flagLoop: while index < words.count {
            let word = Array(words[index])
            guard word.count >= 2, word[0] == "-" else { break }
            index += 1
            if word == ["-", "-"] { break }
            var position = 1
            while position < word.count {
                let flag = word[position]
                position += 1
                if flag == "?" { return .usage }
                guard flag.isASCII, flag.isLetter || flag.isNumber else {
                    return version.namesBadFlags ? .error("invalid flag -\(flag)") : .usage
                }
                guard let at = template.firstIndex(of: flag) else {
                    return version.namesBadFlags ? .error("unknown flag -\(flag)") : .usage
                }
                let takesArgument = at + 1 < template.count && template[at + 1] == ":"
                let optionalArgument = takesArgument && at + 2 < template.count && template[at + 2] == ":"
                if !takesArgument {
                    command.flags[flag, default: []].append("")
                    continue
                }
                if position < word.count {
                    command.flags[flag, default: []].append(String(word[position...]))
                    continue flagLoop
                }
                if optionalArgument {
                    if index == words.count || words[index].hasPrefix("-") {
                        command.flags[flag, default: []].append("")
                        continue flagLoop
                    }
                }
                guard index < words.count else {
                    return version.namesBadFlags ? .error("-\(flag) expects an argument") : .usage
                }
                command.flags[flag, default: []].append(words[index])
                index += 1
                continue flagLoop
            }
        }
        command.arguments = Array(words[index...])
        let count = command.arguments.count
        if count < spec.lower {
            return version.namesBadFlags ? .error("too few arguments (need at least \(spec.lower))") : .usage
        }
        if spec.upper >= 0, count > spec.upper {
            return version.namesBadFlags ? .error("too many arguments (need at most \(spec.upper))") : .usage
        }
        return .success(command)
    }
}
