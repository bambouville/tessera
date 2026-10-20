import Foundation

// Scenario scripts: one format for the model's self-tests and for the
// differential lane, which replays the same file against real tmux on a
// disposable fixture (scripts/integration/run-tmux-model-differential.sh).
//
// Grammar, one directive per line; `#` starts a comment line:
//
//   scenario NAME                        first directive
//   versions 3.2 3.3a 3.4 3.6a           optional; the default is all four
//   session NAME WxH WINDOW              new-session -d -s NAME -x W -y H -n WINDOW
//   window SESSION WINDOW                new-window -d -t SESSION: -n WINDOW
//   group NAME TARGET                    new-session -d -s NAME -t TARGET
//   control CLIENT SESSION [FLAGS]       tmux -C attach-session -t SESSION [-f FLAGS]
//   tty CLIENT SESSION WxH [FLAGS]       tmux attach-session in a WxH terminal
//   send CLIENT LINE...                  one control-mode input line
//   key CLIENT                           one keystroke on a terminal client
//   resize CLIENT WxH                    the terminal changes size (SIGWINCH)
//   detach CLIENT                        the client process goes away
//   advance SECONDS                      wait
//   expect CLIENT TEXT...                (model only) the client received a
//                                        line matching TEXT in the last action
//                                        step; `*` in TEXT matches any run
//   expect-not CLIENT TEXT...            (model only) it did not
//   expect-size WINDOW WxH               (model only)
//   expect-latest WINDOW CLIENT          (model only) also `none`, `dangling:CLIENT`
//   expect-current SESSION WINDOW        (model only)
//
// Setup directives (session, window, group) must come before the first
// client. In `send` and `expect` text, `{NAME}` becomes the id of a session
// (`$N`) or window (`@N`) and `{pane:WINDOW}` the window's pane (`%N`).
// Guard lines in `expect` text are written without time and number
// (`%begin 1`).

public enum ScenarioStep: Equatable, Sendable {
    case session(name: String, size: CellSize, window: String)
    case window(session: String, label: String)
    case group(name: String, target: String)
    case control(client: String, session: String, flags: [String])
    case tty(client: String, session: String, size: CellSize, flags: [String])
    case send(client: String, line: String)
    case key(client: String)
    case resize(client: String, size: CellSize)
    case detach(client: String)
    case advance(seconds: Double)
    case expect(client: String, text: String, present: Bool)
    case expectSize(window: String, size: CellSize)
    case expectLatest(window: String, latest: String)
    case expectCurrent(session: String, window: String)

    /// Steps that the differential lane performs and reads back.
    public var isAction: Bool {
        switch self {
        case .control, .tty, .send, .key, .resize, .detach, .advance: true
        default: false
        }
    }

    public var isSetup: Bool {
        switch self {
        case .session, .window, .group: true
        default: false
        }
    }
}

public struct ScenarioError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

public struct ScenarioScript: Sendable {
    public let name: String
    public let versions: [TmuxVersion]
    public let steps: [ScenarioStep]
    /// The source line of each step.
    public let lines: [Int]

    public static func parse(_ text: String) throws -> ScenarioScript {
        var name: String?
        var versions = TmuxVersion.allCases
        var steps: [ScenarioStep] = []
        var lines: [Int] = []
        var sessions: Set<String> = []
        var windows: Set<String> = []
        var clients: [String: Bool] = [:] // name → is control
        var detached: Set<String> = []
        var sawClient = false

        for (offset, raw) in text.components(separatedBy: "\n").enumerated() {
            let number = offset + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (keyword, rest) = Self.split(line)
            let words = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            func fail(_ message: String) -> ScenarioError { ScenarioError(line: number, message: message) }
            func size(_ text: String) throws -> CellSize {
                guard let size = CellSize.parse(text), text.contains("x"), size.columns > 0, size.rows > 0 else {
                    throw fail("bad size \(text) (want WxH)")
                }
                return size
            }
            func knownClient(_ client: String, control: Bool? = nil) throws {
                guard let isControl = clients[client] else { throw fail("unknown client \(client)") }
                if detached.contains(client) { throw fail("client \(client) has detached") }
                if let control, control != isControl {
                    throw fail("\(client) is \(isControl ? "a control" : "a terminal") client")
                }
            }
            func expectCount(_ count: Int) throws {
                guard words.count == count else { throw fail("\(keyword) takes \(count) arguments") }
            }

            if name == nil {
                guard keyword == "scenario", words.count == 1 else { throw fail("the first directive must be `scenario NAME`") }
                name = words[0]
                continue
            }
            if keyword == "versions" {
                guard steps.isEmpty else { throw fail("`versions` must precede the steps") }
                versions = try words.map { word in
                    guard let version = TmuxVersion(rawValue: word) else { throw fail("unknown version \(word)") }
                    return version
                }
                guard !versions.isEmpty else { throw fail("`versions` needs at least one version") }
                continue
            }
            let step: ScenarioStep
            switch keyword {
            case "session":
                try expectCount(3)
                step = .session(name: words[0], size: try size(words[1]), window: words[2])
                guard !sessions.contains(words[0]), !windows.contains(words[2]), !sessions.contains(words[2]), words[0] != words[2] else {
                    throw fail("duplicate name")
                }
                sessions.insert(words[0])
                windows.insert(words[2])
            case "window":
                try expectCount(2)
                guard sessions.contains(words[0]) else { throw fail("unknown session \(words[0])") }
                guard !windows.contains(words[1]), !sessions.contains(words[1]) else { throw fail("duplicate name \(words[1])") }
                windows.insert(words[1])
                step = .window(session: words[0], label: words[1])
            case "group":
                try expectCount(2)
                guard sessions.contains(words[1]) else { throw fail("unknown session \(words[1])") }
                guard !sessions.contains(words[0]), !windows.contains(words[0]) else { throw fail("duplicate name \(words[0])") }
                sessions.insert(words[0])
                step = .group(name: words[0], target: words[1])
            case "control":
                guard words.count == 2 || words.count == 3 else { throw fail("control CLIENT SESSION [FLAGS]") }
                guard sessions.contains(words[1]) else { throw fail("unknown session \(words[1])") }
                guard clients[words[0]] == nil else { throw fail("duplicate client \(words[0])") }
                clients[words[0]] = true
                step = .control(client: words[0], session: words[1], flags: words.count == 3 ? words[2].split(separator: ",").map(String.init) : [])
            case "tty":
                guard words.count == 3 || words.count == 4 else { throw fail("tty CLIENT SESSION WxH [FLAGS]") }
                guard sessions.contains(words[1]) else { throw fail("unknown session \(words[1])") }
                guard clients[words[0]] == nil else { throw fail("duplicate client \(words[0])") }
                clients[words[0]] = false
                step = .tty(client: words[0], session: words[1], size: try size(words[2]), flags: words.count == 4 ? words[3].split(separator: ",").map(String.init) : [])
            case "send":
                guard let client = words.first else { throw fail("send CLIENT LINE") }
                try knownClient(client, control: true)
                let commandLine = Self.split(rest).rest
                guard !commandLine.isEmpty else { throw fail("send needs a command line") }
                step = .send(client: client, line: commandLine)
            case "key":
                try expectCount(1)
                try knownClient(words[0], control: false)
                step = .key(client: words[0])
            case "resize":
                try expectCount(2)
                try knownClient(words[0], control: false)
                step = .resize(client: words[0], size: try size(words[1]))
            case "detach":
                try expectCount(1)
                try knownClient(words[0])
                detached.insert(words[0])
                step = .detach(client: words[0])
            case "advance":
                try expectCount(1)
                guard let seconds = Double(words[0]), seconds > 0, seconds <= 30 else { throw fail("advance takes 0 < SECONDS <= 30") }
                step = .advance(seconds: seconds)
            case "expect", "expect-not":
                guard let client = words.first, clients[client] == true else { throw fail("\(keyword) needs a control client") }
                let text = Self.split(rest).rest
                guard !text.isEmpty else { throw fail("\(keyword) needs text") }
                step = .expect(client: client, text: text, present: keyword == "expect")
            case "expect-size":
                try expectCount(2)
                guard windows.contains(words[0]) else { throw fail("unknown window \(words[0])") }
                step = .expectSize(window: words[0], size: try size(words[1]))
            case "expect-latest":
                try expectCount(2)
                guard windows.contains(words[0]) else { throw fail("unknown window \(words[0])") }
                step = .expectLatest(window: words[0], latest: words[1])
            case "expect-current":
                try expectCount(2)
                guard sessions.contains(words[0]), windows.contains(words[1]) else { throw fail("unknown session or window") }
                step = .expectCurrent(session: words[0], window: words[1])
            default:
                throw fail("unknown directive \(keyword)")
            }
            if step.isSetup, sawClient { throw fail("setup must come before the first client") }
            if case .control = step { sawClient = true }
            if case .tty = step { sawClient = true }
            steps.append(step)
            lines.append(number)
        }
        guard let name else { throw ScenarioError(line: 0, message: "empty scenario") }
        guard steps.contains(where: \.isAction) else { throw ScenarioError(line: 0, message: "no action steps") }
        return ScenarioScript(name: name, versions: versions, steps: steps, lines: lines)
    }

    static func split(_ line: String) -> (keyword: String, rest: String) {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (line, "") }
        return (String(line[..<space]), line[space...].trimmingCharacters(in: .whitespaces))
    }
}

/// When the differential lane performed and read each action step, in
/// seconds from the first action.
public struct StepTiming: Codable, Equatable, Sendable {
    public var start: Double
    public var read: Double

    public init(start: Double, read: Double) {
        self.start = start
        self.read = read
    }
}

public struct ScenarioStepRecord: Codable, Equatable, Sendable {
    public var index: Int
    public var start: Double
    public var read: Double
    /// Raw lines each control client received during the step.
    public var lines: [String: [String]]
}

public struct ScenarioTranscript: Codable, Equatable, Sendable {
    public var scenario: String
    public var version: String
    /// `{NAME}` substitutions: session and window ids, and `pane:WINDOW`.
    public var ids: [String: String]
    public var steps: [ScenarioStepRecord]
    /// Model expectations that did not hold.
    public var failures: [String]
    /// Input the model does not implement; such a run proves nothing.
    public var unsupported: [String]
}

public enum ScenarioRunner {
    /// The pause after every action before its output is read, matching the
    /// differential runner's default.
    public static let nominalSettle = 0.3

    /// Runs a script on a fresh model. Without a timeline the steps use the
    /// nominal timing (each action is read `settle` seconds after it starts,
    /// `advance` adds its seconds); with a timeline recorded on real tmux,
    /// each action happens at its recorded start and is read at its recorded
    /// read time.
    public static func run(_ script: ScenarioScript, version: TmuxVersion, timeline: [Int: StepTiming]? = nil, settle: Double = nominalSettle) -> ScenarioTranscript {
        let model = TmuxServerModel(version: version)
        var ids: [String: String] = [:]
        var sessions: [String: SessionHandle] = [:]
        var windows: [String: WindowHandle] = [:]
        var clients: [String: ClientHandle] = [:]
        var controls: [String] = []
        var records: [ScenarioStepRecord] = []
        var failures: [String] = []
        var lastLines: [String: [String]] = [:]
        var origin: Int64?
        var clock = 0.0

        func substitute(_ text: String) -> String {
            var result = text
            for (key, value) in ids {
                result = result.replacingOccurrences(of: "{\(key)}", with: value)
            }
            return result
        }

        for (index, step) in script.steps.enumerated() {
            let line = script.lines[index]
            if step.isAction {
                let timing = timeline?[index] ?? StepTiming(start: clock, read: clock + (stepSeconds(step)) + settle)
                if origin == nil { origin = model.now }
                let startTime = origin! + Int64((timing.start * 1_000_000).rounded())
                if startTime > model.now { model.advance(to: startTime) }
                switch step {
                case .control(let client, let session, let flags):
                    clients[client] = model.connect(control: client, session: sessions[session]!, flags: flags)
                    controls.append(client)
                case .tty(let client, let session, let size, let flags):
                    clients[client] = model.attachTTY(client, session: sessions[session]!, size: size, flags: flags)
                case .send(let client, let commandLine):
                    _ = model.send(clients[client]!, substitute(commandLine))
                case .key(let client):
                    model.typeKey(clients[client]!)
                case .resize(let client, let size):
                    model.resizeTTY(clients[client]!, to: size)
                case .detach(let client):
                    model.lose(clients[client]!)
                case .advance:
                    break
                default:
                    break
                }
                let readTime = origin! + Int64((timing.read * 1_000_000).rounded())
                if readTime > model.now { model.advance(to: readTime) }
                var lines: [String: [String]] = [:]
                for client in controls {
                    lines[client] = model.takeAll(clients[client]!)
                }
                records.append(ScenarioStepRecord(index: index, start: timing.start, read: timing.read, lines: lines))
                lastLines = lines
                clock = timing.read
                continue
            }
            switch step {
            case .session(let name, let size, let window):
                let created = model.newSession(name, size: size, windowName: window)
                sessions[name] = created.session
                windows[window] = created.window
                ids[name] = created.session.description
                ids[window] = created.window.description
                ids["pane:\(window)"] = "%\(model.paneID(created.window))"
            case .window(let session, let label):
                let created = model.newWindow(in: sessions[session]!, name: label)
                windows[label] = created
                ids[label] = created.description
                ids["pane:\(label)"] = "%\(model.paneID(created))"
            case .group(let name, let target):
                let created = model.newGroupedSession(name, groupedWith: sessions[target]!)
                sessions[name] = created
                ids[name] = created.description
            case .expect(let client, let text, let present):
                let expected = substitute(text)
                let received = normalized(lastLines[client] ?? [])
                if received.contains(where: { matches(expected, $0) }) != present {
                    failures.append("line \(line): \(client) \(present ? "did not receive" : "received") `\(expected)`; got \(received)")
                }
            case .expectSize(let window, let size):
                let actual = model.windowSize(windows[window]!)
                if actual != size { failures.append("line \(line): \(window) is \(actual), expected \(size)") }
            case .expectLatest(let window, let latest):
                let actual = model.latest(windows[window]!)
                let expected: LatestClient
                if latest == "none" {
                    expected = .none
                } else if latest.hasPrefix("dangling:") {
                    expected = .dangling(String(latest.dropFirst("dangling:".count)))
                } else {
                    expected = .client(latest)
                }
                if actual != expected { failures.append("line \(line): latest of \(window) is \(actual), expected \(expected)") }
            case .expectCurrent(let session, let window):
                let actual = model.currentWindow(sessions[session]!)
                if actual != windows[window]! {
                    failures.append("line \(line): \(session) shows \(actual), expected \(window) (\(windows[window]!))")
                }
            default:
                break
            }
        }
        return ScenarioTranscript(
            scenario: script.name,
            version: version.rawValue,
            ids: ids,
            steps: records,
            failures: failures,
            unsupported: model.unsupported
        )
    }

    /// `*` matches any run of characters; everything else is literal.
    static func matches(_ pattern: String, _ line: String) -> Bool {
        guard pattern.contains("*") else { return pattern == line }
        let parts = pattern.components(separatedBy: "*")
        var rest = Substring(line)
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for part in parts.dropFirst().dropLast() {
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        let last = parts.last!
        return parts.count == 1 ? rest.isEmpty : rest.hasSuffix(last)
    }

    static func stepSeconds(_ step: ScenarioStep) -> Double {
        if case .advance(let seconds) = step { return seconds }
        return 0
    }

    /// Guard lines without time and number: `%begin 1700000000 12 1` → `%begin 1`.
    public static func normalized(_ lines: [String]) -> [String] {
        lines.map { line in
            let parts = line.split(separator: " ")
            if parts.count == 4, ["%begin", "%end", "%error"].contains(String(parts[0])) {
                return "\(parts[0]) \(parts[3])"
            }
            return line
        }
    }
}

extension TmuxServerModel {
    /// Every line the client received that has not been returned yet,
    /// including lines `send` already returned (the scenario runner reads
    /// streams the way the differential runner does).
    func takeAll(_ handle: ClientHandle) -> [String] {
        guard let client = anyClient(handle) else { return [] }
        let start = client.scenarioMark
        client.scenarioMark = client.output.count
        return client.output[start...].map(\.text)
    }

    /// The window's single pane.
    public func paneID(_ window: WindowHandle) -> Int {
        windowState(window.id).paneID
    }
}
