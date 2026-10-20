import Foundation

// Live planner driver: runs Core's grammar and answer planner against a real
// TUI in a private tmux server, writing each planned step as hex keys (the
// app's transport). Usage:
//   driver <provider> <socket> <target> observe
//   driver <provider> <socket> <target> [--expect <observed-token>] option <id> | text <value> | control <kind>

@main
struct PromptDriver {
static func run(_ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch {
        fputs("failed to run \(args.first ?? "command"): \(error)\n", stderr)
        exit(5)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fputs("command failed (\(process.terminationStatus)): \(args.joined(separator: " "))\n", stderr)
        exit(5)
    }
    return String(decoding: data, as: UTF8.self)
}

static func main() {
var argv = CommandLine.arguments
guard argv.count >= 5, let provider = AgentProviderID(rawValue: argv[1]) else { exit(64) }
let socket = argv[2], target = argv[3]
var expectedToken: String?
if argv.count >= 7 && argv[4] == "--expect" {
    expectedToken = argv[5]
    argv.removeSubrange(4...5)
}

func capture() -> (text: String, cursor: String?) {
    // Settled: two identical captures 80 ms apart. Both apps capture a tmux
    // pane with its SGR (`-e -N`, for composer DIM evidence) and send the
    // cursor row's cells, at most 2 KiB of whole characters.
    var previous = ""
    for _ in 0..<20 {
        let text = run(["tmux", "-S", socket, "capture-pane", "-p", "-e", "-N", "-t", target])
        if text == previous { break }
        previous = text
        usleep(80_000)
    }
    let rows = previous.components(separatedBy: "\n")
    let cursorY = Int(run(["tmux", "-S", socket, "display", "-p", "-t", target, "#{cursor_y}"])
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    let cursor = rows.indices.contains(cursorY) ? rows[cursorY] : nil
    // Bottom whole rows within 16 KiB, as both platforms send.
    var bytes = 0
    let cells = cursor.map(AgentPromptGrammar.withoutEscapes).map { row in
        String(row.prefix { bytes += $0.utf8.count; return bytes <= 2_048 })
    }
    return (AgentPromptGrammar.promptText(fromCapture: previous), cells)
}

func observe() -> AgentPromptObservationResult? {
    let screen = capture()
    guard let request = AgentPromptObservationRequest(providerID: provider, visibleText: screen.text,
                                                      currentCursorLine: screen.cursor) else { return nil }
    return AgentPromptGrammar.observe(request)
}

func describe(_ o: AgentPromptObservationResult?) -> String {
    guard let o else { return "no prompt" }
    let options = o.options.map { "\($0.id)\($0.isDefault ? "*" : "")\($0.isChecked == true ? "☑" : "")=\($0.label)" }.joined(separator: " | ")
    return "kind=\(o.kind) blocking=\(o.isBlocking) q=\(o.question ?? "-") options=[\(options)] controls=\(o.controls.map { $0.kind.rawValue }) entry=\(o.entry.map { "\($0.optionID ?? "nil"):\($0.text)" } ?? "-") focus=\(o.textFocus.map { "\($0)" } ?? "-") pending=\(o.pendingCount.map(String.init) ?? "-") token=\(AgentPromptGrammar.actionToken(for: o.signature).rawValue)"
}

let initial = observe()
print("observed:", describe(initial))
if let expectedToken,
   initial.map({ AgentPromptGrammar.actionToken(for: $0.signature).rawValue }) != expectedToken {
    print("refused stalePrompt: expected token \(expectedToken)")
    exit(2)
}
guard argv.count > 5, let first = initial else { exit(argv[4] == "observe" ? 0 : 3) }
let goal: AgentPromptAnswerGoal
switch argv[4] {
case "option": goal = .option(argv[5])
case "text": goal = .text(argv[5])
case "control":
    guard let kind = AgentPromptControlKind(rawValue: argv[5]) else { exit(64) }
    goal = .control(kind)
default: exit(64)
}
var history: [AgentPromptAnswerPhase] = [], anchor: AgentPromptAnswerAnchor?
var observation: AgentPromptObservationResult? = first
for iteration in 0...AgentPromptAnswerPlanner.maximumSteps {
    if iteration > 0 { observation = observe() }
    let plan = AgentPromptAnswerPlanner.next(provider: provider, goal: goal, expectedSignature: first.signature,
                                             anchor: anchor, observation: observation, history: history)
    anchor = plan.anchor
    let step = plan.step
    switch step.action {
    case .done:
        print("done after \(history)")
        print("final:", describe(observe()))
        exit(0)
    case .refuse:
        print("refused \(step.refusal!.rawValue) after \(history); screen:", describe(observation))
        exit(2)
    case .wait:
        history.append(.wait)
        print("wait")
    case .send:
        let bytes = step.bytes!
        let hex = bytes.utf8.map { String(format: "%02x", $0) }
        _ = run(["tmux", "-S", socket, "send-keys", "-t", target, "-H"] + hex)
        history.append(step.phase!)
        print("send \(step.phase!.rawValue) hex=\(hex.joined()) \(bytes.debugDescription)")
    }
    usleep(UInt32(AgentPromptAnswerPlanner.settleDelayMilliseconds) * 1_000)
}
print("exhausted")
exit(4)
}
}
