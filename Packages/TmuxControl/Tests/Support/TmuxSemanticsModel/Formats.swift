import Foundation

// A subset of format.c: `#{name}` (options first, format.c:3573-3587, then
// the variables below), `#{?cond,a,b}` (format.c:4627-4673), `#{==:a,b}`,
// `#{!=:a,b}`, `#{m:pattern,string}`, `#{S:fmt}` (format_loop_sessions,
// format.c:4019-4050) and `##`/`#,` escapes. Unknown names expand to "".

struct FormatContext {
    var client: ClientState?
    var session: SessionState?
    var winlinkIndex: Int?
    var window: WindowState?
}

extension TmuxServerModel {
    /// format_defaults (format.c:5054-5093): a missing session comes from the
    /// client, a missing winlink from the session's current window, the pane
    /// is the window's active pane.
    func formatContext(client: ClientState?, session: SessionState?, winlinkIndex: Int?, window: WindowState?) -> FormatContext {
        let resolvedSession = session ?? client.flatMap { self.session(of: $0) }
        var index = winlinkIndex
        var resolvedWindow = window
        if resolvedWindow == nil, let resolvedSession {
            index = resolvedSession.currentIndex
            resolvedWindow = resolvedSession.currentWindowID.map { windowState($0) }
        }
        if index == nil, let resolvedWindow, let resolvedSession {
            index = resolvedSession.sortedIndexes.first { resolvedSession.winlinks[$0] == resolvedWindow.id }
        }
        return FormatContext(client: client, session: resolvedSession, winlinkIndex: index, window: resolvedWindow)
    }

    func expandFormat(_ format: String, _ context: FormatContext) -> String {
        var result = ""
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            let next = format.index(after: index)
            guard character == "#", next < format.endIndex else {
                result.append(character)
                index = next
                continue
            }
            let marker = format[next]
            if marker == "#" || marker == "," || marker == "}" {
                result.append(marker)
                index = format.index(after: next)
            } else if marker == "{", let close = matchingBrace(format, open: next) {
                let body = String(format[format.index(after: next)..<close])
                result += expandBlock(body, context)
                index = format.index(after: close)
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }

    /// The index of the `}` closing the `{` at `open`, counting nested `#{`.
    func matchingBrace(_ text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "#", text.index(after: index) < text.endIndex {
                let next = text[text.index(after: index)]
                if next == "{" {
                    depth += 1
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                if next == "#" || next == "," || next == "}" {
                    index = text.index(index, offsetBy: 2)
                    continue
                }
            }
            if character == "{", index == open { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Splits at top-level commas (format_skip semantics: `#{...}` nests,
    /// `#,` escapes).
    func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "#", next < text.endIndex {
                let marker = text[next]
                if marker == "{" { depth += 1 }
                current.append(character)
                current.append(marker)
                index = text.index(after: next)
                continue
            }
            if character == "}", depth > 0 { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = next
        }
        parts.append(current)
        return parts
    }

    func expandBlock(_ body: String, _ context: FormatContext) -> String {
        if body.hasPrefix("?") {
            let parts = splitTopLevel(String(body.dropFirst()))
            guard parts.count >= 2 else { return "" }
            let condition = parts[0]
            var found = lookupVariable(condition, context)
            if found == nil {
                let expanded = expandFormat(condition, context)
                found = expanded == condition ? "" : expanded
            }
            let chosen = formatTrue(found) ? parts[1] : (parts.count > 2 ? parts[2] : "")
            return expandFormat(chosen, context)
        }
        for (prefix, compare) in [("==:", { (a: String, b: String) in a == b }), ("!=:", { (a: String, b: String) in a != b })] {
            if body.hasPrefix(prefix) {
                let parts = splitTopLevel(String(body.dropFirst(prefix.count)))
                guard parts.count == 2 else { return "" }
                return compare(expandFormat(parts[0], context), expandFormat(parts[1], context)) ? "1" : "0"
            }
        }
        if body.hasPrefix("m:") {
            let parts = splitTopLevel(String(body.dropFirst(2)))
            guard parts.count == 2 else { return "" }
            return globMatch(expandFormat(parts[0], context), expandFormat(parts[1], context)) ? "1" : "0"
        }
        if body.hasPrefix("S:") {
            let inner = String(body.dropFirst(2))
            return sessionsInOrder.map { session in
                expandFormat(inner, formatContext(client: context.client, session: session, winlinkIndex: nil, window: nil))
            }.joined()
        }
        return lookupVariable(body, context) ?? ""
    }

    /// format_true (format.c:3782-3787).
    func formatTrue(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value != "0"
    }

    /// fnmatch(3) with no flags, as `#{m:...}` and option patterns use it:
    /// `*`, `?`, `[...]` classes with ranges and `!`/`^` negation, and `\\`
    /// escapes, matching the whole string.
    func globMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var memo: [Int: Bool] = [:]
        func classEnd(_ start: Int) -> Int? {
            var i = start + 1
            if i < p.count, p[i] == "!" || p[i] == "^" { i += 1 }
            if i < p.count, p[i] == "]" { i += 1 }
            while i < p.count, p[i] != "]" { i += 1 }
            return i < p.count ? i : nil
        }
        func classMatches(_ start: Int, _ end: Int, _ c: Character) -> Bool {
            var i = start + 1
            var negate = false
            if p[i] == "!" || p[i] == "^" { negate = true; i += 1 }
            var matched = false
            var first = true
            while i < end {
                if !first, p[i] == "]" { break }
                first = false
                let low = p[i]
                if i + 2 < end, p[i + 1] == "-" {
                    if let lo = low.unicodeScalars.first?.value, let hi = p[i + 2].unicodeScalars.first?.value,
                       let cv = c.unicodeScalars.first?.value, lo <= cv, cv <= hi {
                        matched = true
                    }
                    i += 3
                } else {
                    if low == c { matched = true }
                    i += 1
                }
            }
            return matched != negate
        }
        func match(_ i: Int, _ j: Int) -> Bool {
            let key = i * (t.count + 1) + j
            if let cached = memo[key] { return cached }
            let result: Bool
            if i == p.count {
                result = j == t.count
            } else if p[i] == "*" {
                result = match(i + 1, j) || (j < t.count && match(i, j + 1))
            } else if j == t.count {
                result = false
            } else if p[i] == "?" {
                result = match(i + 1, j + 1)
            } else if p[i] == "[", let end = classEnd(i) {
                result = classMatches(i, end, t[j]) && match(end + 1, j + 1)
            } else if p[i] == "\\", i + 1 < p.count {
                result = p[i + 1] == t[j] && match(i + 2, j + 1)
            } else {
                result = p[i] == t[j] && match(i + 1, j + 1)
            }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }

    /// format_find (format.c:3559-...): options first, then the variable table.
    func lookupVariable(_ name: String, _ context: FormatContext) -> String? {
        if let value = formatOption(name, session: context.session, window: context.window) {
            // options_to_string(o, idx, 1) (format.c:3584): numeric, so a
            // flag is 1 or 0 (options.c:151-155); choices stay symbolic.
            if let entry = optionEntry(name), case .flag = entry.kind {
                return value == "on" ? "1" : "0"
            }
            return value
        }
        let client = context.client, session = context.session, window = context.window
        switch name {
        case "session_id": return session.map { "$\($0.id)" }
        case "session_name": return session?.name
        case "session_group": return session.map { $0.groupName ?? "" }
        case "session_grouped": return session.map { $0.groupName == nil ? "0" : "1" }
        case "session_attached": return session.map { "\(attachedCount($0))" }
        case "session_activity": return session.map { "\(formatTime($0.activityTime))" }
        case "window_id": return window.map { "@\($0.id)" }
        case "window_index": return context.winlinkIndex.map(String.init)
        case "window_name": return window?.name
        case "window_width": return window.map { "\($0.size.columns)" }
        case "window_height": return window.map { "\($0.size.rows)" }
        case "window_zoomed_flag": return window.map { _ in "0" }
        case "window_layout", "window_visible_layout": return window.map { layoutString($0) }
        case "window_raw_flags":
            guard let session, let index = context.winlinkIndex, let window else { return nil }
            return rawFlags(session: session, index: index, window: window)
        case "pane_id": return window.map { "%\($0.paneID)" }
        case "pane_width": return window.map { "\($0.size.columns)" }
        case "pane_height": return window.map { "\($0.size.rows)" }
        case "client_name": return client?.name
        case "client_pid": return client.map { "\($0.pid)" }
        case "client_created": return client.map { "\(formatTime($0.creationTime))" }
        case "client_activity": return client.map { "\(formatTime($0.activityTime))" }
        case "client_session": return client.flatMap { self.session(of: $0)?.name }
        case "client_width": return client.map { "\($0.tty.columns)" }
        case "client_height": return client.map { "\($0.tty.rows)" }
        case "client_flags": return client.map { clientFlagsString($0) }
        case "client_control_mode": return client.map { $0.isControl ? "1" : "0" }
        case "client_termname": return client?.termName
        case "client_uid", "uid": return "0"
        default: return nil
        }
    }

    /// window_printable_flags (window.c:868-894) without alerts or marks.
    func rawFlags(session: SessionState, index: Int, window: WindowState) -> String {
        var flags = ""
        if index == session.currentIndex { flags += "*" }
        if session.lastWindows.first == index { flags += "-" }
        return flags
    }

    /// layout_dump for a single-pane window: `%04hx,WxH,0,0,PANE` with
    /// layout_checksum (layout-custom.c; not in the verified source subset).
    func layoutString(_ window: WindowState) -> String {
        let body = "\(window.size.columns)x\(window.size.rows),0,0,\(window.paneID)"
        var checksum: UInt16 = 0
        for byte in body.utf8 {
            checksum = (checksum >> 1) &+ ((checksum & 1) << 15)
            checksum = checksum &+ UInt16(byte)
        }
        return String(format: "%04x", checksum) + "," + body
    }
}
