// Tessera/Files/RemotePathResolver.swift
//
// One resolver for every "the user gave us a path" surface: the panel's
// editable path bar, quick-open, and the terminal-selection Quick Look
// menu (design: docs/mockups/files-panel-improvements/index.html).
// Everything except `resolve` is pure and synchronous — unit-testable
// with no connection. `resolve` stats by listing the parent directory
// over the bridge, because `FileBridging` deliberately has no stat and
// the listing is the call the browser already caches.

import Foundation

enum RemotePathResolution: Equatable {
    case file(RemoteFileEntry)
    case directory(String)
}

enum RemotePathResolver {

    // MARK: - Terminal-selection cleanup (§3)

    /// Cleans a terminal selection into a path candidate: trims
    /// whitespace, strips one layer of wrapping quotes, then compiler
    /// `:line[:col]` suffixes and dangling sentence punctuation.
    /// nil when the selection can't be one path (empty, multi-word
    /// unless it was quoted, absurd length).
    static func pathCandidate(from selection: String) -> String? {
        var s = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 1024 else { return nil }
        var wasQuoted = false
        for quote in ["'", "\"", "`"] where s.count >= 2 && s.hasPrefix(quote) && s.hasSuffix(quote) {
            s = String(s.dropFirst().dropLast())
            wasQuoted = true
            break
        }
        // Dangling prose punctuation first ("src/App.tsx:23:5:" — clang's
        // token ends in ':'), then the compiler/grep location suffix
        // (path.swift:23 or path.swift:23:5), then punctuation again.
        while let last = s.last, ":,;.".contains(last) { s.removeLast() }
        s.replace(#/:\d+(:\d+)?$/#, with: "")
        while let last = s.last, ":,;.".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // One shell word unless explicitly quoted — interior whitespace
        // in an unquoted selection means prose, not a path.
        if !wasQuoted, s.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return nil }
        if wasQuoted, s.rangeOfCharacter(from: .newlines) != nil { return nil }
        return s
    }

    /// Gate for showing the selection-menu items at all: cheap, local,
    /// and biased against cluttering everyday copy flows. A true here
    /// only unlocks the menu item — the real existence check is the
    /// bridge stat when the action fires.
    static func isPlausiblePath(_ selection: String) -> Bool {
        guard let candidate = pathCandidate(from: selection) else { return false }
        if candidate.hasPrefix("/") || candidate.hasPrefix("~") { return true }
        if candidate.contains("/") { return true }
        // Bare filename: hidden-file form (.env) or an extension-ish tail
        // (README.md). Prose fragments that sneak through just stat-miss.
        if candidate.hasPrefix(".") && candidate.count > 1 { return true }
        return candidate.contains(#/\.[A-Za-z0-9]{1,10}$/#)
    }

    // MARK: - Typed-input expansion (§2 / §4)

    /// Absolute path for user-typed input: trims, expands `~`, resolves
    /// relative input against `cwd`, and lexically normalizes. No
    /// selection heuristics — typed paths may legitimately contain
    /// spaces. nil when the input can't anchor to an absolute path
    /// (relative with no cwd, `~` with no home, empty).
    static func expand(_ typed: String, home: String?, cwd: String?) -> String? {
        var path = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.rangeOfCharacter(from: .newlines) == nil else { return nil }
        if path == "~" {
            guard let home else { return nil }
            path = home
        } else if path.hasPrefix("~/") {
            guard let home else { return nil }
            path = home + path.dropFirst(1)
        } else if path.hasPrefix("~") {
            // "~user/…" — another user's home can't be resolved lexically;
            // treating it as relative would produce a nonsense cwd path.
            return nil
        } else if !path.hasPrefix("/") {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            path = cwd + "/" + path
        }
        return lexicallyNormalized(path)
    }

    /// "/a/./b/../c/" → "/a/c" without touching the filesystem. ".."
    /// never pops past root.
    static func lexicallyNormalized(_ absolute: String) -> String {
        var stack: [Substring] = []
        for part in absolute.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    // MARK: - Resolution over the bridge

    /// Routes an absolute path: file → the entry (for staging/preview),
    /// directory → its path (for navigation). Symlinks route by what
    /// they point at (cheap listing probe). Throws `FileBridgeError`
    /// with a user-facing message on any miss.
    @MainActor
    static func resolve(
        absolute path: String,
        bridge: any FileBridging
    ) async throws -> RemotePathResolution {
        if path == "/" { return .directory("/") }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let siblings = try await bridge.listDirectory(parent.isEmpty ? "/" : parent)
        guard let entry = siblings.first(where: { $0.name == name }) else {
            throw FileBridgeError.remoteOperationFailed("Not found: \(path)")
        }
        switch entry.kind {
        case .directory:
            return .directory(path)
        case .file:
            return .file(entry)
        case .symlink:
            // Directory-ness decides the route; only a listing can tell.
            if (try? await bridge.listDirectory(path)) != nil {
                return .directory(path)
            }
            return .file(entry)
        }
    }

    // MARK: - Completion (§2, shared verbatim by quick-open §4)

    struct CompletionContext: Equatable {
        /// Directory whose entries the prefix filters.
        let parentPath: String
        /// Segment after the last "/" — what the user is mid-typing.
        let prefix: String
    }

    /// Splits typed input into the directory to list and the segment to
    /// prefix-match. nil when the input can't anchor to a directory yet
    /// (relative with no cwd, `~` with no home).
    static func completionContext(
        forTyped typed: String, home: String?, cwd: String?
    ) -> CompletionContext? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.rangeOfCharacter(from: .newlines) == nil else { return nil }
        guard let slash = t.lastIndex(of: "/") else {
            // No slash at all: complete inside the cwd.
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            return CompletionContext(parentPath: lexicallyNormalized(cwd), prefix: t)
        }
        let dirPart = String(t[...slash])
        let prefix = String(t[t.index(after: slash)...])
        guard let parent = expand(dirPart, home: home, cwd: cwd) else { return nil }
        return CompletionContext(parentPath: parent, prefix: prefix)
    }

    /// Pure prefix matcher: case-insensitive, directories first, hidden
    /// entries only once the prefix itself starts with "." (shell
    /// convention). Empty prefix lists the directory head — useful right
    /// after typing a trailing "/".
    static func completions(
        prefix: String,
        in entries: [RemoteFileEntry],
        limit: Int = 6
    ) -> [RemoteFileEntry] {
        let lowered = prefix.lowercased()
        let matches = entries.filter { entry in
            guard prefix.hasPrefix(".") || !entry.isHidden else { return false }
            return lowered.isEmpty || entry.name.lowercased().hasPrefix(lowered)
        }
        let ranked = matches.sorted { a, b in
            let aDir = a.kind == .directory, bDir = b.kind == .directory
            if aDir != bDir { return aDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return Array(ranked.prefix(limit))
    }
}
