import Foundation

/// Streaming parser for the tmux control-mode protocol (`tmux -CC`).
///
/// This is a pure-Swift state machine that converts a byte stream into
/// a sequence of typed `TmuxMessage` values. It is:
///
///   - **Incremental**: feed partial buffers; it yields only complete
///     messages and holds any trailing partial line until the next call.
///   - **State-aware**: tracks whether we're inside a `%begin`/`%end`
///     command response, so plain output lines in that window become
///     `.commandOutputLine`.
///   - **Byte-safe**: `%output` payloads are returned as raw `[UInt8]`
///     with octal escapes already decoded. UTF-8 interpretation is a
///     consumer concern.
///   - **Unit-testable without a simulator** — no UIKit, no IO.
///
/// Reference: the upstream tmux source (`control-notify.c`, `control.c`)
/// and the project wiki's Control Mode page.
public struct TmuxControlParser {

    private var buffer: [UInt8] = []
    private var inCommandResponse: Bool = false
    private var openFrameCommandNumber: Int?
    private var outputScanners: [Int: TerminalOutputScanner] = [:]

    public init() {}

    /// Feed a chunk of bytes from the SSH channel. Returns zero or more
    /// complete messages. A trailing partial line is retained for the
    /// next call.
    public mutating func feed(_ chunk: some Sequence<UInt8>) -> [TmuxMessage] {
        buffer.append(contentsOf: chunk)
        return drain()
    }

    /// Reset all state. Use when reattaching or on session loss.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        inCommandResponse = false
        openFrameCommandNumber = nil
        outputScanners.removeAll(keepingCapacity: true)
    }

    // MARK: - Line extraction

    private mutating func drain() -> [TmuxMessage] {
        var out: [TmuxMessage] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineBytes = Array(buffer[..<newlineIndex])
            buffer.removeFirst(newlineIndex + 1)
            if lineBytes.last == 0x0D {
                lineBytes.removeLast() // strip CR from CRLF
            }
            out.append(contentsOf: parseLine(lineBytes))
        }
        return out
    }

    // MARK: - Line dispatch

    private mutating func parseLine(_ line: [UInt8]) -> [TmuxMessage] {
        // Command-response body lines are plain text until the matching
        // %end/%error guard for the open command number. tmux writes these
        // frames contiguously for synchronous commands and does not escape
        // captured pane lines that look like control messages, so prefix-only
        // guards or in-frame notification sniffing let pane content poison
        // frame boundaries or emit spurious notifications.
        if inCommandResponse {
            if startsWith(line, prefix: "%end ") || line == Array("%end".utf8) {
                if let message = parseBeginEnd(line: line, kind: .end),
                   case let .end(_, commandNumber, _) = message,
                   commandNumber == openFrameCommandNumber
                {
                    inCommandResponse = false
                    openFrameCommandNumber = nil
                    return [message]
                }

                let text = String(decoding: line, as: UTF8.self)
                return [.commandOutputLine(text)]
            }
            if startsWith(line, prefix: "%error ") || line == Array("%error".utf8) {
                if let message = parseBeginEnd(line: line, kind: .error),
                   case let .error(_, commandNumber, _) = message,
                   commandNumber == openFrameCommandNumber
                {
                    inCommandResponse = false
                    openFrameCommandNumber = nil
                    return [message]
                }

                let text = String(decoding: line, as: UTF8.self)
                return [.commandOutputLine(text)]
            }
            // Body line — not a control message or notification. Empty body
            // lines are legitimate output and become empty commandOutputLine.
            let text = String(decoding: line, as: UTF8.self)
            return [.commandOutputLine(text)]
        }

        // Outside a command response, empty lines are noise (keepalive,
        // trailing newlines, etc.) — drop silently.
        if line.isEmpty { return [] }

        // Not in a command response — everything of interest starts with %.
        guard line.first == 0x25 /* % */ else {
            // Plain text outside a response is unexpected but not
            // catastrophic. Round-trip as unknown.
            return [.unknown(String(decoding: line, as: UTF8.self))]
        }

        // %output is hot-path and needs byte-level handling to preserve
        // the payload exactly, so handle it before string splitting.
        if startsWith(line, prefix: "%output ") {
            return parseOutput(line: line) ?? []
        }
        if startsWith(line, prefix: "%extended-output ") {
            return parseExtendedOutput(line: line) ?? []
        }

        let text = String(decoding: line, as: UTF8.self)
        return parseControlMessage(text).map { [$0] } ?? []
    }

    // MARK: - Individual parsers

    private enum BeginEndKind { case begin, end, error }

    private mutating func parseBeginEnd(line: [UInt8], kind: BeginEndKind) -> TmuxMessage? {
        let text = String(decoding: line, as: UTF8.self)
        let kindDescription: String
        switch kind {
        case .begin: kindDescription = "begin"
        case .end: kindDescription = "end"
        case .error: kindDescription = "error"
        }
        // Format: "%<tag> <time> <number> <flags>"
        let components = text.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 4 else {
            // Bare tag with no args — rare but tolerate it.
            TmuxDiagnostics.sink?(
                "command-guard-parse-fallback kind=\(kindDescription) reason=missing-fields componentCount=\(components.count) lineBytes=\(line.count) fallbackTime=0 fallbackNumber=0 fallbackFlags=0"
            )
            switch kind {
            case .begin: return .begin(time: 0, commandNumber: 0, flags: 0)
            case .end:   return .end(time: 0, commandNumber: 0, flags: 0)
            case .error: return .error(time: 0, commandNumber: 0, flags: 0)
            }
        }
        let parsedTime = Int(components[1])
        let parsedNumber = Int(components[2])
        let parsedFlags = Int(components[3])
        let time = parsedTime ?? 0
        let number = parsedNumber ?? 0
        let flags = parsedFlags ?? 0
        if parsedTime == nil || parsedNumber == nil || parsedFlags == nil {
            TmuxDiagnostics.sink?(
                "command-guard-parse-fallback kind=\(kindDescription) reason=invalid-integer componentCount=\(components.count) lineBytes=\(line.count) timeValid=\(parsedTime != nil) numberValid=\(parsedNumber != nil) flagsValid=\(parsedFlags != nil) fallbackTime=\(time) fallbackNumber=\(number) fallbackFlags=\(flags)"
            )
        }
        switch kind {
        case .begin: return .begin(time: time, commandNumber: number, flags: flags)
        case .end:   return .end(time: time, commandNumber: number, flags: flags)
        case .error: return .error(time: time, commandNumber: number, flags: flags)
        }
    }

    private mutating func parseOutput(line: [UInt8]) -> [TmuxMessage]? {
        // Format: %output %<pane_id> <escaped_bytes>
        // We need byte-level decoding of the payload.
        let prefixLen = "%output ".utf8.count
        guard line.count > prefixLen else { return [.unknown(String(decoding: line, as: UTF8.self))] }

        var i = prefixLen
        // Expect '%' then digits
        guard i < line.count, line[i] == 0x25 /* % */ else {
            return [.unknown(String(decoding: line, as: UTF8.self))]
        }
        i += 1
        let idStart = i
        while i < line.count, line[i] >= 0x30 && line[i] <= 0x39 {
            i += 1
        }
        guard i > idStart else { return [.unknown(String(decoding: line, as: UTF8.self))] }
        let idBytes = line[idStart..<i]
        guard let paneRaw = Int(String(decoding: idBytes, as: UTF8.self)) else {
            return [.unknown(String(decoding: line, as: UTF8.self))]
        }
        // Expect a space separator
        guard i < line.count, line[i] == 0x20 /* space */ else {
            // No payload at all
            return [.output(paneId: PaneId(paneRaw), data: [])]
        }
        i += 1

        let decoded = decodeOctalEscapes(Array(line[i...]))
        return outputMessages(paneRaw: paneRaw, data: decoded) {
            .output(paneId: PaneId(paneRaw), data: decoded)
        }
    }

    private mutating func parseExtendedOutput(line: [UInt8]) -> [TmuxMessage]? {
        // Format: %extended-output %<pane_id> <age_ms> [future fields] : <escaped_bytes>
        let prefixLen = "%extended-output ".utf8.count
        guard line.count > prefixLen else { return [.unknown(String(decoding: line, as: UTF8.self))] }

        var i = prefixLen
        guard i < line.count, line[i] == 0x25 /* % */ else {
            return [.unknown(String(decoding: line, as: UTF8.self))]
        }
        i += 1
        let idStart = i
        while i < line.count, line[i] >= 0x30 && line[i] <= 0x39 {
            i += 1
        }
        guard i > idStart,
              let paneRaw = Int(String(decoding: line[idStart..<i], as: UTF8.self)),
              i < line.count,
              line[i] == 0x20 /* space */
        else {
            return [.unknown(String(decoding: line, as: UTF8.self))]
        }
        i += 1

        let ageStart = i
        while i < line.count, line[i] >= 0x30 && line[i] <= 0x39 {
            i += 1
        }
        guard i > ageStart,
              let ageMs = Int(String(decoding: line[ageStart..<i], as: UTF8.self))
        else {
            return [.unknown(String(decoding: line, as: UTF8.self))]
        }

        while i < line.count {
            while i < line.count, line[i] == 0x20 /* space */ {
                i += 1
            }
            guard i < line.count else {
                return [.unknown(String(decoding: line, as: UTF8.self))]
            }
            if line[i] == 0x3A /* : */ {
                let tokenEnd = i + 1
                guard tokenEnd == line.count || line[tokenEnd] == 0x20 /* space */ else {
                    return [.unknown(String(decoding: line, as: UTF8.self))]
                }
                i = tokenEnd
                if i < line.count, line[i] == 0x20 /* space */ {
                    i += 1
                }
                let payload = i < line.count ? Array(line[i...]) : []
                let decoded = decodeOctalEscapes(payload)
                return outputMessages(paneRaw: paneRaw, data: decoded) {
                    .extendedOutput(paneId: PaneId(paneRaw), ageMs: ageMs, data: decoded)
                }
            }
            while i < line.count, line[i] != 0x20 /* space */ {
                i += 1
            }
        }

        return [.unknown(String(decoding: line, as: UTF8.self))]
    }

    private mutating func outputMessages(
        paneRaw: Int,
        data decoded: [UInt8],
        outputMessage: () -> TmuxMessage
    ) -> [TmuxMessage] {
        var scanner = outputScanners[paneRaw] ?? TerminalOutputScanner()
        let outputEvents = scanner.feed(decoded)
        outputScanners[paneRaw] = scanner
        var messages: [TmuxMessage] = []
        if outputEvents.audibleBell {
            messages.append(.bell(paneID: paneRaw))
        }
        messages.append(outputMessage())
        return messages
    }

    private mutating func parseControlMessage(_ line: String) -> TmuxMessage? {
        // Split on first space: tag and rest
        let firstSpace = line.firstIndex(of: " ")
        let tag = firstSpace.map { String(line[..<$0]) } ?? line
        let rest = firstSpace.map { String(line[line.index(after: $0)...]) } ?? ""

        switch tag {
        case "%begin":
            inCommandResponse = true
            openFrameCommandNumber = nil
            let message = parseBeginEnd(line: Array(line.utf8), kind: .begin)
            if case let .some(.begin(_, commandNumber, _)) = message {
                openFrameCommandNumber = commandNumber
            }
            return message
        case "%end":
            inCommandResponse = false
            openFrameCommandNumber = nil
            return parseBeginEnd(line: Array(line.utf8), kind: .end)
        case "%error":
            inCommandResponse = false
            openFrameCommandNumber = nil
            return parseBeginEnd(line: Array(line.utf8), kind: .error)

        case "%window-add":
            return parseWindowOnly(rest: rest, wrap: TmuxMessage.windowAdd(windowId:))
        case "%window-close":
            return parseWindowOnly(rest: rest, wrap: TmuxMessage.windowClose(windowId:))
        case "%window-renamed":
            return parseWindowAndName(rest: rest, wrap: TmuxMessage.windowRenamed(windowId:name:))
        case "%window-pane-changed":
            return parseWindowAndPane(rest: rest)
        case "%layout-change":
            return parseLayoutChange(rest: rest)

        case "%unlinked-window-add":
            return parseWindowOnly(rest: rest, wrap: TmuxMessage.unlinkedWindowAdd(windowId:))
        case "%unlinked-window-close":
            return parseWindowOnly(rest: rest, wrap: TmuxMessage.unlinkedWindowClose(windowId:))
        case "%unlinked-window-renamed":
            return parseWindowAndName(rest: rest, wrap: TmuxMessage.unlinkedWindowRenamed(windowId:name:))

        case "%session-changed":
            return parseSessionAndName(rest: rest, wrap: TmuxMessage.sessionChanged(sessionId:name:))
        case "%session-renamed":
            return parseSessionAndName(rest: rest, wrap: TmuxMessage.sessionRenamed(sessionId:name:))
        case "%session-window-changed":
            return parseSessionAndWindow(rest: rest)
        case "%sessions-changed":
            return .sessionsChanged
        case "%client-session-changed":
            return parseClientSessionChanged(rest: rest)
        case "%client-detached":
            return rest.isEmpty ? .clientDetached(client: "") : .clientDetached(client: rest)
        case "%subscription-changed":
            return parseSubscriptionChanged(rest: rest)

        case "%pane-mode-changed":
            return parsePaneOnly(rest: rest, wrap: TmuxMessage.paneModeChanged(paneId:))
        case "%pause":
            return parsePaneOnly(rest: rest, wrap: TmuxMessage.pause(paneId:))
        case "%continue":
            return parsePaneOnly(rest: rest, wrap: { paneId in .continue(paneId: paneId) })

        case "%exit":
            return .exit(reason: rest.isEmpty ? nil : rest)

        default:
            return .unknown(line)
        }
    }

    // MARK: - Field parsers

    private func parseWindowOnly(
        rest: String,
        wrap: (WindowId) -> TmuxMessage
    ) -> TmuxMessage? {
        guard let id = parseWindowId(rest.trimmingCharacters(in: .whitespaces)) else {
            return .unknown("%<window-only> \(rest)")
        }
        return wrap(id)
    }

    private func parseWindowAndName(
        rest: String,
        wrap: (WindowId, String) -> TmuxMessage
    ) -> TmuxMessage? {
        // Format: @<id> <name>  (name may contain spaces)
        guard let space = rest.firstIndex(of: " ") else {
            // No name — tolerate with empty
            if let id = parseWindowId(rest) { return wrap(id, "") }
            return .unknown("%<window+name> \(rest)")
        }
        guard let id = parseWindowId(String(rest[..<space])) else {
            return .unknown("%<window+name> \(rest)")
        }
        let name = String(rest[rest.index(after: space)...])
        return wrap(id, name)
    }

    private func parseWindowAndPane(rest: String) -> TmuxMessage? {
        // Format: @<win> %<pane>
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let win = parseWindowId(String(parts[0])),
              let pane = parsePaneId(String(parts[1]))
        else {
            return .unknown("%window-pane-changed \(rest)")
        }
        return .windowPaneChanged(windowId: win, activePaneId: pane)
    }

    private func parseLayoutChange(rest: String) -> TmuxMessage? {
        // Format: @<win> <layout> <visible_layout> <raw_flags>
        // (verified 4-field against tmux 3.6a). Layout strings never contain
        // spaces, so a plain space split is safe. Tolerate 2/3/4-token shapes:
        // empty flags arrive as a trailing space (no token) and decode to nil.
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first, let win = parseWindowId(String(first)) else {
            return .unknown("%layout-change \(rest)")
        }
        let layout = parts.count >= 2 ? String(parts[1]) : ""
        let visibleLayout = parts.count >= 3 ? String(parts[2]) : nil
        let rawFlags = parts.count >= 4 ? String(parts[3]) : nil
        return .layoutChange(
            windowId: win,
            layout: layout,
            visibleLayout: visibleLayout,
            rawFlags: rawFlags
        )
    }

    private func parseSessionAndName(
        rest: String,
        wrap: (SessionId, String) -> TmuxMessage
    ) -> TmuxMessage? {
        guard let space = rest.firstIndex(of: " ") else {
            if let id = parseSessionId(rest) { return wrap(id, "") }
            return .unknown("%<session+name> \(rest)")
        }
        guard let id = parseSessionId(String(rest[..<space])) else {
            return .unknown("%<session+name> \(rest)")
        }
        let name = String(rest[rest.index(after: space)...])
        return wrap(id, name)
    }

    private func parseSessionAndWindow(rest: String) -> TmuxMessage? {
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let sess = parseSessionId(String(parts[0])),
              let win = parseWindowId(String(parts[1]))
        else {
            return .unknown("%session-window-changed \(rest)")
        }
        return .sessionWindowChanged(sessionId: sess, windowId: win)
    }

    private func parseClientSessionChanged(rest: String) -> TmuxMessage? {
        // Format: <client> $<session> <name>
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let sess = parseSessionId(String(parts[1]))
        else {
            return .unknown("%client-session-changed \(rest)")
        }
        return .clientSessionChanged(
            client: String(parts[0]),
            sessionId: sess,
            name: String(parts[2])
        )
    }

    private func parseSubscriptionChanged(rest: String) -> TmuxMessage? {
        // Format:
        //   <name> $<session> @<window> <window-index> %<pane> ... : <value>
        // Any fields after pane-id and before ":" are reserved for future use.
        let splitRange = rest.range(of: " : ")
            ?? rest.range(of: " :")
        guard let splitRange else {
            return .unknown("%subscription-changed \(rest)")
        }

        let header = String(rest[..<splitRange.lowerBound])
        let value = String(rest[splitRange.upperBound...])
        let fields = header.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 5,
              let sessionId = parseSessionId(String(fields[1])),
              let windowId = parseWindowId(String(fields[2])),
              let windowIndex = Int(fields[3]),
              let paneId = parsePaneId(String(fields[4]))
        else {
            return .unknown("%subscription-changed \(rest)")
        }

        return .subscriptionChanged(
            name: String(fields[0]),
            sessionId: sessionId,
            windowId: windowId,
            windowIndex: windowIndex,
            paneId: paneId,
            value: value
        )
    }

    private func parsePaneOnly(
        rest: String,
        wrap: (PaneId) -> TmuxMessage
    ) -> TmuxMessage? {
        guard let id = parsePaneId(rest.trimmingCharacters(in: .whitespaces)) else {
            return .unknown("%<pane-only> \(rest)")
        }
        return wrap(id)
    }

    // MARK: - ID helpers

    private func parseWindowId(_ s: String) -> WindowId? {
        guard s.hasPrefix("@"), let n = Int(s.dropFirst()) else { return nil }
        return WindowId(n)
    }

    private func parseSessionId(_ s: String) -> SessionId? {
        guard s.hasPrefix("$"), let n = Int(s.dropFirst()) else { return nil }
        return SessionId(n)
    }

    private func parsePaneId(_ s: String) -> PaneId? {
        guard s.hasPrefix("%"), let n = Int(s.dropFirst()) else { return nil }
        return PaneId(n)
    }

    // MARK: - Byte helpers

    private func startsWith(_ bytes: [UInt8], prefix: String) -> Bool {
        let pb = Array(prefix.utf8)
        guard bytes.count >= pb.count else { return false }
        for i in 0..<pb.count where bytes[i] != pb[i] { return false }
        return true
    }

    /// Decode `\DDD` octal escapes into raw bytes. Characters < 32 and `\`
    /// itself are the only ones tmux encodes; everything else passes
    /// through as-is (including UTF-8 continuation bytes).
    internal func decodeOctalEscapes(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let b = input[i]
            if b == 0x5C /* \ */, i + 3 < input.count,
               isOctalDigit(input[i + 1]),
               isOctalDigit(input[i + 2]),
               isOctalDigit(input[i + 3])
            {
                let d0 = Int(input[i + 1] - 0x30)
                let d1 = Int(input[i + 2] - 0x30)
                let d2 = Int(input[i + 3] - 0x30)
                let value = (d0 << 6) | (d1 << 3) | d2
                if value < 256 {
                    out.append(UInt8(value))
                    i += 4
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    private func isOctalDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x37
    }
}
