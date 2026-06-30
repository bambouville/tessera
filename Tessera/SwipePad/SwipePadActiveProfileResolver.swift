// Tessera/SwipePad/SwipePadActiveProfileResolver.swift
// Pick the active swipe-pad profile by querying tmux for the foreground
// process name when tmux is available, or by asking a non-tmux
// process-name provider when it is not. Fires once per puck press.
//
// We don't cache. tmux's notification protocol has no signal for "the
// foreground process within this pane just changed" (running `claude` from
// a shell doesn't switch panes), so any persistent cache silently goes
// stale the moment the user launches a new agent. The roundtrip cost
// (~3 ms locally, 30–100 ms remote) is acceptable for always-correct
// detection — gestures fire once per prompt cycle, not in tight bursts.
//
import Foundation
import TmuxControl

public typealias SwipePadProcessNameProvider = @MainActor () async -> [String]
public typealias SwipePadPaneProcessNameProvider = @MainActor (_ panePID: Int) async -> [String]

enum SwipePadDiagnostics {
    static func log(_ message: @autoclosure () -> String) {
        DiagnosticLogStore.appendSwipePad(message())
    }

    static func preview(_ bytes: some Collection<UInt8>, limit: Int = 160) -> String {
        guard !bytes.isEmpty else { return "<empty>" }

        let prefixBytes = Array(bytes.prefix(limit))
        var out = ""
        out.reserveCapacity(prefixBytes.count * 2)

        for byte in prefixBytes {
            switch byte {
            case 0x1B:
                out += "\\e"
            case 0x07:
                out += "\\a"
            case 0x0D:
                out += "\\r"
            case 0x0A:
                out += "\\n"
            case 0x09:
                out += "\\t"
            case 0x20...0x7E:
                out.append(Character(UnicodeScalar(Int(byte))!))
            default:
                out += String(format: "\\x%02X", byte)
            }
        }

        if bytes.count > limit {
            out += "..."
        }
        return out
    }

    static func preview(_ text: String, limit: Int = 500) -> String {
        preview(Array(text.utf8), limit: limit)
    }
}

@MainActor
@Observable
public final class SwipePadActiveProfileResolver {
    /// The most recently resolved profile. Used by the overlay to drive
    /// the at-rest "matched" indicator on the puck, so the user can see
    /// without pressing whether their active agent is recognized. `nil`
    /// until the first resolution completes. Set by every successful
    /// `resolveActiveProfile` call regardless of caller.
    public private(set) var currentProfile: SwipePadProfile?
    private var refreshInFlight = false
    private var refreshPending = false

    public init() {}

    /// Background refresh — fire a resolution and update `currentProfile`
    /// without anyone waiting for the result. Concurrent refreshes are
    /// coalesced so output-triggered pulses and polling cannot stack
    /// side-channel process probes.
    public func refresh(
        tmux: TmuxController,
        store: SwipePadProfileStore,
        processNameProvider: SwipePadProcessNameProvider? = nil,
        paneProcessNameProvider: SwipePadPaneProcessNameProvider? = nil
    ) {
        guard !refreshInFlight else {
            refreshPending = true
            SwipePadDiagnostics.log("refresh-coalesced reason=in-flight")
            return
        }

        refreshInFlight = true
        resolveActiveProfile(
            tmux: tmux,
            store: store,
            processNameProvider: processNameProvider,
            paneProcessNameProvider: paneProcessNameProvider
        ) { [weak self, tmux, store, processNameProvider, paneProcessNameProvider] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshInFlight = false

                guard self.refreshPending else { return }
                self.refreshPending = false
                SwipePadDiagnostics.log("refresh-coalesced action=run-pending")
                self.refresh(
                    tmux: tmux,
                    store: store,
                    processNameProvider: processNameProvider,
                    paneProcessNameProvider: paneProcessNameProvider
                )
            }
        }
    }

    /// Resolve the active profile. Always fires a tmux query unless the
    /// session isn't in -CC mode. Non-tmux sessions can provide an async
    /// process-name source; sessions without either source return fallback.
    /// Completion is invoked on the main actor. Also updates
    /// `currentProfile` so the rest-state indicator stays in sync with
    /// whatever the radial just saw.
    public func resolveActiveProfile(
        tmux: TmuxController,
        store: SwipePadProfileStore,
        processNameProvider: SwipePadProcessNameProvider? = nil,
        paneProcessNameProvider: SwipePadPaneProcessNameProvider? = nil,
        completion: @escaping (SwipePadProfile) -> Void
    ) {
        let candidates = store.profiles
        let fallback = candidates.first(where: { $0.id == SwipePadProfile.fallbackID })
            ?? SwipePadProfile.fallback

        SwipePadDiagnostics.log(
            "resolve begin tmux.mode=\(tmux.mode) activeWindowPresent=\(tmux.activeWindowId != nil) activePanePresent=\(tmux.activePaneId != nil) candidateCount=\(candidates.count) customMatcherCount=\(candidates.filter { !$0.matchProcess.isEmpty }.count)"
        )

        guard tmux.mode == .tmuxControl else {
            guard let processNameProvider else {
                SwipePadDiagnostics.log("resolve fallback reason=no-tmux-no-provider")
                currentProfile = fallback
                completion(fallback)
                return
            }

            SwipePadDiagnostics.log("resolve provider-query source=plain-ssh")
            Task { @MainActor in
                let processNames = await processNameProvider()
                let resolved = Self.resolve(
                    candidates: candidates,
                    fallback: fallback,
                    processNames: processNames
                )
                SwipePadDiagnostics.log(
                    "resolve complete source=plain-ssh candidateCount=\(processNames.count) matched=\(resolved.id != fallback.id)"
                )
                currentProfile = resolved
                completion(resolved)
            }
            return
        }

        let command = Self.tmuxProcessQuery(activePaneId: tmux.activePaneId)
        if tmux.activePaneId == nil {
            SwipePadDiagnostics.log(
                "tmux-query warning=missing-active-pane using-client-scoped-command activeWindow=\(String(describing: tmux.activeWindowId))"
            )
        }
        SwipePadDiagnostics.log(
            "tmux-query activePanePresent=\(tmux.activePaneId != nil) commandCategory=process-query"
        )

        tmux.sendControlCommand(command) { [weak self] result in
            Task { @MainActor in
                let parsed = Self.parseTmuxResult(result)
                var processNames = parsed.processNames
                var resolved = Self.resolve(
                    candidates: candidates,
                    fallback: fallback,
                    processNames: processNames
                )
                if resolved.id == fallback.id,
                   let panePID = parsed.panePID,
                   let paneProcessNameProvider {
                    SwipePadDiagnostics.log(
                        "tmux-pane-ps begin panePID=\(panePID) existingCandidateCount=\(processNames.count)"
                    )
                    let paneNames = await paneProcessNameProvider(panePID)
                    SwipePadDiagnostics.log(
                        "tmux-pane-ps result panePID=\(panePID) candidateCount=\(paneNames.count)"
                    )
                    processNames.append(contentsOf: paneNames)
                    resolved = Self.resolve(
                        candidates: candidates,
                        fallback: fallback,
                        processNames: processNames
                    )
                }
                SwipePadDiagnostics.log(
                    "resolve complete source=tmux candidateCount=\(processNames.count) matched=\(resolved.id != fallback.id) panePIDPresent=\(parsed.panePID != nil)"
                )
                self?.currentProfile = resolved
                completion(resolved)
            }
        }
    }

    private struct TmuxProcessResult {
        var processNames: [String]
        var panePID: Int?
    }

    /// Parse tmux command response into direct process-name candidates and
    /// optional pane PID for a scoped `ps` fallback.
    private static func parseTmuxResult(
        _ result: Result<[String], TmuxController.CommandError>
    ) -> TmuxProcessResult {
        switch result {
        case .success(let lines):
            let payload = lines.first(where: { !$0.isEmpty }) ?? ""
            SwipePadDiagnostics.log(
                "tmux-response lines=\(lines.count) payloadBytes=\(payload.utf8.count)"
            )
            let parsed = parseTmuxProcessPayload(payload)
            if parsed.commandName.isEmpty {
                SwipePadDiagnostics.log("tmux-response empty-command")
                return TmuxProcessResult(processNames: [], panePID: parsed.panePID)
            }
            return TmuxProcessResult(
                processNames: [parsed.commandName],
                panePID: parsed.panePID
            )
        case .failure(let error):
            SwipePadDiagnostics.log("tmux-response failure error='\(error)'")
            return TmuxProcessResult(processNames: [], panePID: nil)
        }
    }

    nonisolated static func tmuxProcessQuery(activePaneId: PaneId?) -> String {
        if let activePaneId {
            return "display-message -p -t \(activePaneId.description) 'cmd=#{pane_current_command}|pid=#{pane_pid}'"
        }
        return "display-message -p 'cmd=#{pane_current_command}|pid=#{pane_pid}'"
    }

    nonisolated static func parseTmuxProcessPayload(_ payload: String) -> (commandName: String, panePID: Int?) {
        var commandName = ""
        var panePID: Int?
        for field in payload.split(separator: "|", omittingEmptySubsequences: false) {
            if field.hasPrefix("cmd=") {
                commandName = String(field.dropFirst(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            } else if field.hasPrefix("pid=") {
                panePID = Int(field.dropFirst(4))
            }
        }
        if commandName.isEmpty, !payload.contains("|") {
            commandName = payload
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        return (commandName, panePID)
    }

    /// Match a profile against a (lowercased, trimmed) process name. Two
    /// matcher forms — see `SwipePadProfile.matchProcess` docs.
    nonisolated static func matches(profile: SwipePadProfile, processName: String) -> Bool {
        let spec = profile.matchProcess
        guard !spec.isEmpty else { return false }

        let normalizedProcessName = processName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedProcessName.isEmpty else { return false }

        if spec.hasPrefix("regex:") {
            let pattern = String(spec.dropFirst(6))
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                SwipePadDiagnostics.log("match-check invalid-regex")
                return false
            }
            let range = NSRange(normalizedProcessName.startIndex..., in: normalizedProcessName)
            return regex.firstMatch(in: normalizedProcessName, range: range) != nil
        }
        return spec.lowercased() == normalizedProcessName
    }

    nonisolated static func resolve(
        candidates: [SwipePadProfile],
        fallback: SwipePadProfile,
        processNames: [String]
    ) -> SwipePadProfile {
        for raw in processNames {
            let processName = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !processName.isEmpty else { continue }

            if let match = candidates.first(where: { matches(profile: $0, processName: processName) }) {
                return match
            }
        }

        return fallback
    }
}

enum SwipePadPlainSSHProcessProbe {
    /// Side-channel process snapshot used when the terminal is plain SSH
    /// passthrough rather than tmux control mode. `exit 0` is load-bearing:
    /// unsupported `ps` options should produce an empty snapshot, not a
    /// thrown `CommandFailed` that tears through gesture handling.
    ///
    /// The final awk/tail/cut cap is also load-bearing. On busy hosts, a
    /// full per-user `ps -ww` snapshot can exceed Citadel's response cap
    /// before the app gets a chance to parse it.
    ///
    /// `$PPID` of this exec-channel shell is the SSH server-side process for
    /// the current connection. Filtering to descendants of that process keeps
    /// codex/claude runs in other SSH sessions from holding this puck in a
    /// stale matched state after the local session returns to the shell.
    static let outputLineLimit = 64
    static let outputColumnLimit = 1_000
    static let maximumExpectedOutputBytes = outputLineLimit * (outputColumnLimit + 1)

    static var command: String { makeCommand(rootPID: nil) }

    static func makeCommand(rootPID: Int?) -> String {
        let rootAssignment: String
        if let rootPID, rootPID > 0 {
            rootAssignment = "r=\(rootPID); "
        } else {
            rootAssignment = "r=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' '); "
        }

        return rootAssignment
        + "u=$(id -un 2>/dev/null || whoami 2>/dev/null || printf ''); "
        + "{ "
        + "if [ -n \"$u\" ]; then "
        + "ps -ww -u \"$u\" -o pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null || "
        + "ps -u \"$u\" -o pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null || "
        + "ps -ww -axo pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null || "
        + "ps -axo pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null; "
        + "else "
        + "ps -ww -axo pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null || "
        + "ps -axo pid= -o ppid= -o stat= -o tty= -o comm= -o args= 2>/dev/null; "
        + "fi; } | awk '$4 != \"?\" && $4 != \"??\" && $4 != \"-\" { print }' "
        + "| awk -v root=\"$r\" '"
        + "$1 ~ /^[0-9]+$/ { parent[$1]=$2; tty[$1]=$4; line[$1]=$0 } "
        + "function attached(t) { return t != \"?\" && t != \"??\" && t != \"-\" } "
        + "function inside(pid, depth) { "
        + "for (depth=0; pid != \"\" && pid != \"0\" && depth < 64; depth++) { "
        + "if (pid == root) return 1; pid = parent[pid] "
        + "} return 0 "
        + "} "
        + "END { for (pid in line) if (attached(tty[pid]) && root != \"\" && inside(pid)) print line[pid] }"
        + "' "
        + "| tail -n \(outputLineLimit) | cut -c 1-\(outputColumnLimit); exit 0"
    }

    static func processNames(from psOutput: String) -> [String] {
        let lines = psOutput.split(whereSeparator: \.isNewline)
        let records = lines
            .compactMap(parseRecord)
            .filter { !$0.hasDetachedTTY }

        let foregroundRecords = records.filter(\.isForeground)
        let activeRecords = foregroundRecords.isEmpty ? records : foregroundRecords

        var seen = Set<String>()
        var result: [String] = []

        for record in activeRecords.sorted(by: compareRecords) {
            for name in candidateNames(for: record) {
                guard seen.insert(name).inserted else { continue }
                result.append(name)
            }
        }

        SwipePadDiagnostics.log(
            "ps-parse lines=\(lines.count) attachedRecords=\(records.count) foregroundRecords=\(foregroundRecords.count) activeRecords=\(activeRecords.count) candidateCount=\(result.count)"
        )
        return result
    }

    private static func parseRecord(_ line: Substring) -> ProcessRecord? {
        let fields = line.split(
            maxSplits: 5,
            omittingEmptySubsequences: true
        ) { char in
            char == " " || char == "\t"
        }

        guard fields.count >= 5,
              let pid = Int(fields[0]),
              let ppid = Int(fields[1])
        else { return nil }

        return ProcessRecord(
            pid: pid,
            ppid: ppid,
            stat: String(fields[2]),
            tty: String(fields[3]),
            comm: String(fields[4]),
            args: fields.count >= 6 ? String(fields[5]) : ""
        )
    }

    private static func compareRecords(_ lhs: ProcessRecord, _ rhs: ProcessRecord) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.pid > rhs.pid
    }

    private static func candidateNames(for record: ProcessRecord) -> [String] {
        SwipePadProcessNameExtractor.candidateNames(
            comm: record.comm,
            args: record.args
        )
    }

    private struct ProcessRecord: Equatable {
        let pid: Int
        let ppid: Int
        let stat: String
        let tty: String
        let comm: String
        let args: String

        var isForeground: Bool {
            stat.contains("+")
        }

        var hasDetachedTTY: Bool {
            tty == "?" || tty == "??" || tty == "-"
        }

        var score: Int {
            (isForeground ? 1000 : 0) + pid
        }
    }
}

enum SwipePadProcessNameExtractor {
    static func candidateNames(comm: String, args: String) -> [String] {
        var names: [String] = []
        if let comm = normalizedProcessName(comm, allowLeadingDash: true) {
            names.append(comm)
        }
        for (index, token) in argumentTokens(args).enumerated() {
            if let name = normalizedProcessName(
                token,
                allowLeadingDash: index == 0
            ) {
                names.append(name)
            }
        }
        return deduplicated(names)
    }

    static func processNames(fromCommandLine commandLine: String) -> [String] {
        let names = argumentTokens(commandLine).compactMap {
            normalizedProcessName($0, allowLeadingDash: false)
        }
        return deduplicated(names)
    }

    private static func deduplicated(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    private static func argumentTokens(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for char in trimmed {
            if escaping {
                current.append(char)
                escaping = false
                continue
            }
            if char == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                continue
            }
            if char == " " || char == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }
            current.append(char)
        }
        if escaping { current.append("\\") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func normalizedProcessName(
        _ raw: String,
        allowLeadingDash: Bool = false
    ) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("-") {
            guard allowLeadingDash else { return nil }
            value.removeFirst()
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !value.isEmpty else { return nil }
        guard !value.hasPrefix("-") else { return nil }
        guard !(value.hasPrefix("[") && value.hasSuffix("]")) else { return nil }

        let basename = value.split(separator: "/").last.map(String.init) ?? value
        let normalized = basename
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty,
              normalized != "command",
              normalized != "comm"
        else { return nil }

        return normalized
    }
}

@MainActor
@Observable
final class SwipePadShellIntegrationTracker {
    private(set) var processNames: [String] = []
    private(set) var diagnosticSummary = "no shell-integration events"
    private var parser = OSCParser()

    func feed(_ bytes: ArraySlice<UInt8>) {
        for payload in parser.feed(bytes) {
            handle(payload)
        }
    }

    private func handle(_ payload: String) {
        if payload.hasPrefix("633;") {
            diagnosticSummary = "last OSC 633 bytes=\(payload.utf8.count)"
            SwipePadDiagnostics.log("shell-osc family=633 bytes=\(payload.utf8.count)")
            handleVSCode(payload)
        } else if payload.hasPrefix("133;") {
            diagnosticSummary = "last OSC 133 bytes=\(payload.utf8.count)"
            SwipePadDiagnostics.log("shell-osc family=133 bytes=\(payload.utf8.count)")
            handleFinalTerm(payload)
        } else if payload.hasPrefix("1337;") {
            diagnosticSummary = "last OSC 1337 bytes=\(payload.utf8.count)"
            SwipePadDiagnostics.log("shell-osc family=1337 bytes=\(payload.utf8.count)")
            handleITermExtension(payload)
        } else if payload.hasPrefix("0;") || payload.hasPrefix("1;") || payload.hasPrefix("2;") || payload.hasPrefix("7;") {
            diagnosticSummary = "last non-command OSC bytes=\(payload.utf8.count)"
            SwipePadDiagnostics.log("shell-osc ignored bytes=\(payload.utf8.count)")
        }
    }

    private func handleVSCode(_ payload: String) {
        if payload == "633;D" || payload.hasPrefix("633;D;") {
            clear(source: "OSC 633 D")
            return
        }

        let prefix = "633;E;"
        guard payload.hasPrefix(prefix) else { return }
        let rest = String(payload.dropFirst(prefix.count))
        let encodedCommand = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let commandLine = Self.decodeVSCodeCommandLine(encodedCommand)
        SwipePadDiagnostics.log("shell-vscode commandLineBytes=\(commandLine.utf8.count)")
        update(commandLine: commandLine, source: "OSC 633 E")
    }

    private func handleFinalTerm(_ payload: String) {
        if payload == "133;D" || payload.hasPrefix("133;D;") {
            clear(source: "OSC 133 D")
            return
        }

        guard payload == "133;C" || payload.hasPrefix("133;C;") else { return }
        for field in payload.split(separator: ";", omittingEmptySubsequences: false).dropFirst(2) {
            let prefix = "cmdline_url="
            guard field.hasPrefix(prefix) else { continue }
            let encoded = String(field.dropFirst(prefix.count))
            let commandLine = encoded.removingPercentEncoding ?? encoded
            SwipePadDiagnostics.log("shell-finalterm commandLineBytes=\(commandLine.utf8.count)")
            update(
                commandLine: commandLine,
                source: "OSC 133 C"
            )
            return
        }
    }

    private func handleITermExtension(_ payload: String) {
        let prefix = "1337;SetUserVar="
        guard payload.hasPrefix(prefix) else { return }
        let rest = String(payload.dropFirst(prefix.count))
        guard let separator = rest.firstIndex(of: "=") else { return }

        let key = String(rest[..<separator])
        guard Self.isProgramUserVar(key) else { return }

        let encodedValue = String(rest[rest.index(after: separator)...])
        guard let data = Data(base64Encoded: encodedValue) else { return }
        let commandLine = String(decoding: data, as: UTF8.self)
        SwipePadDiagnostics.log("shell-uservar key=\(key) commandLineBytes=\(commandLine.utf8.count)")
        update(
            commandLine: commandLine,
            source: "OSC 1337 \(key)"
        )
    }

    private func update(commandLine: String, source: String) {
        let names = SwipePadProcessNameExtractor.processNames(fromCommandLine: commandLine)
        if names.isEmpty {
            clear(source: source)
            return
        }
        processNames = names
        diagnosticSummary = "\(source) commandLineBytes=\(commandLine.utf8.count) candidateCount=\(names.count)"
        SwipePadDiagnostics.log("shell-update source='\(source)' candidateCount=\(names.count)")
    }

    private func clear(source: String) {
        let hadProcessNames = !processNames.isEmpty
        processNames = []
        diagnosticSummary = "\(source) cleared"
        if hadProcessNames {
            SwipePadDiagnostics.log("shell-clear source='\(source)'")
        } else {
            SwipePadDiagnostics.log("shell-clear source='\(source)' already-empty")
        }
    }

    private static func isProgramUserVar(_ key: String) -> Bool {
        switch key.uppercased() {
        case "WEZTERM_PROG", "WAKTERM_PROG", "TESSERA_PROG":
            return true
        default:
            return false
        }
    }

    private static func decodeVSCodeCommandLine(_ raw: String) -> String {
        let bytes = Array(raw.utf8)
        var decoded: [UInt8] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x5C else {
                decoded.append(byte)
                index += 1
                continue
            }

            if index + 1 < bytes.count, bytes[index + 1] == 0x5C {
                decoded.append(0x5C)
                index += 2
                continue
            }

            if index + 3 < bytes.count,
               bytes[index + 1] == 0x78,
               let high = hexValue(bytes[index + 2]),
               let low = hexValue(bytes[index + 3]) {
                decoded.append((high << 4) | low)
                index += 4
                continue
            }

            decoded.append(byte)
            index += 1
        }

        return String(decoding: decoded, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private struct OSCParser {
        private enum State {
            case ground
            case escape
            case osc
            case oscEscape
        }

        private var state: State = .ground
        private var buffer: [UInt8] = []
        private let maxPayloadLength = 16 * 1024

        mutating func feed(_ bytes: ArraySlice<UInt8>) -> [String] {
            var payloads: [String] = []

            for byte in bytes {
                switch state {
                case .ground:
                    if byte == 0x1B { state = .escape }
                case .escape:
                    if byte == 0x5D {
                        buffer.removeAll(keepingCapacity: true)
                        state = .osc
                    } else {
                        state = byte == 0x1B ? .escape : .ground
                    }
                case .osc:
                    if byte == 0x07 {
                        payloads.append(String(decoding: buffer, as: UTF8.self))
                        buffer.removeAll(keepingCapacity: true)
                        state = .ground
                    } else if byte == 0x1B {
                        state = .oscEscape
                    } else {
                        append(byte)
                    }
                case .oscEscape:
                    if byte == 0x5C {
                        payloads.append(String(decoding: buffer, as: UTF8.self))
                        buffer.removeAll(keepingCapacity: true)
                        state = .ground
                    } else {
                        append(0x1B)
                        append(byte)
                        state = .osc
                    }
                }
            }

            return payloads
        }

        private mutating func append(_ byte: UInt8) {
            guard buffer.count < maxPayloadLength else {
                buffer.removeAll(keepingCapacity: true)
                state = .ground
                return
            }
            buffer.append(byte)
        }
    }
}
