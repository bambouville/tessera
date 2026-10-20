import Foundation

/// A directory entry as far as prefix completion is concerned.
///
/// The real entry type is per-platform (iOS `RemoteFileEntry`, Android's
/// listing row) and carries size/permissions/timestamps that ranking never
/// looks at — so the shared matcher takes only the two fields it actually
/// reads and hands the caller's own values straight back.
public protocol RemotePathCompletionCandidate {
    /// Last path component, exactly as the host reported it.
    var completionName: String { get }
    /// Directories rank ahead of files at equal name order.
    var completionIsDirectory: Bool { get }
}

extension RemotePathCompletionCandidate {
    /// Shell convention: a leading dot hides the entry until the typed
    /// prefix itself starts with a dot.
    public var completionIsHidden: Bool { completionName.hasPrefix(".") }
}

/// Minimal concrete candidate for tests, the ABI, and any caller that has
/// nothing richer than a name and a kind.
public struct RemotePathCompletionEntry: RemotePathCompletionCandidate, Equatable, Hashable, Sendable {
    public let completionName: String
    public let completionIsDirectory: Bool

    public init(name: String, isDirectory: Bool = false) {
        self.completionName = name
        self.completionIsDirectory = isDirectory
    }
}

/// One grammar for every "the user gave us a path" surface: the files
/// panel's editable path bar, quick-open, and the terminal-selection Quick
/// Look menu (design: docs/mockups/files-panel-improvements/index.html).
///
/// Everything here is pure and synchronous — unit-testable with no
/// connection. Actually *resolving* a path (does it exist, is it a
/// directory?) stays on each platform, because it is a call against that
/// platform's file bridge: iOS lists the parent directory over SFTP,
/// because `FileBridging` deliberately has no stat and the listing is the
/// call the browser already caches.
///
/// A successful parse here only makes a Files action *eligible*. The caller
/// must still canonicalize and stat the result through its authenticated
/// remote file connection before it exposes or downloads anything.
///
/// Android peer: `RemoteSelectionPathResolver` (files module).
public enum RemotePathGrammar {

    /// Longest selection that can plausibly be one path. Anything past this
    /// is a paragraph the user swiped over, not a filename.
    public static let maxSelectionLength = 1024

    // MARK: - Terminal-selection cleanup (§3)

    /// Cleans a terminal selection into a path candidate: trims
    /// whitespace, strips one layer of wrapping quotes, then compiler
    /// `:line[:col]` suffixes and dangling sentence punctuation.
    /// nil when the selection can't be one path (empty, multi-word
    /// unless it was quoted, absurd length, control characters).
    ///
    /// Control-character rejection is the one rule adopted from Android
    /// rather than inherited from iOS: a selection carrying ESC, NUL or a
    /// stray CR is terminal debris (or an escape-sequence injection
    /// attempt), never a path worth offering in a menu. Selections without
    /// control characters — every real one — behave exactly as before.
    public static func pathCandidate(from selection: String) -> String? {
        var s = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= maxSelectionLength else { return nil }
        guard !containsControlCharacter(s) else { return nil }
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

    /// Most whitespace-separated fragments a selection may have and still
    /// read as one wrapped path. A path broken across a few terminal rows
    /// (or an agent's indented continuation lines) produces a handful; a
    /// paragraph the user swiped over produces many, and must not grow the
    /// selection menu.
    public static let maxCollapsedFragments = 8

    /// The second reading of a selection: the same token with *all*
    /// whitespace removed.
    ///
    /// Coding agents print paths inside wrapped, indented TUI output, so a
    /// path the user selects often arrives broken by a newline plus the
    /// next row's indentation — `docs/review\n    v3.pdf`. The strict
    /// reading rejects that (interior whitespace means prose), which is
    /// right for the *first* attempt and wrong as the last word. Collapsing
    /// rejoins the fragments so resolution gets a second, tolerant try.
    ///
    /// nil when there is nothing to collapse (no interior whitespace — the
    /// strict reading already covers it), when the selection carries a
    /// non-whitespace control character (terminal debris), or when it has
    /// too many fragments to be one wrapped path.
    public static func collapsedPathCandidate(from selection: String) -> String? {
        guard !containsNonWhitespaceControlCharacter(selection) else { return nil }
        var s = trimmingCollapsibleWhitespace(selection)
        guard !s.isEmpty, s.count <= maxSelectionLength else { return nil }
        for quote in ["'", "\"", "`"] where s.count >= 2 && s.hasPrefix(quote) && s.hasSuffix(quote) {
            s = trimmingCollapsibleWhitespace(String(s.dropFirst().dropLast()))
            break
        }
        let fragments = s.split(whereSeparator: isCollapsibleWhitespace)
        guard fragments.count > 1, fragments.count <= maxCollapsedFragments else { return nil }
        var collapsed = fragments.joined()
        // Same tail cleanup as the strict reading: prose punctuation, then
        // the compiler/grep `:line[:col]` suffix, then punctuation again.
        while let last = collapsed.last, ":,;.".contains(last) { collapsed.removeLast() }
        collapsed.replace(#/:\d+(:\d+)?$/#, with: "")
        while let last = collapsed.last, ":,;.".contains(last) { collapsed.removeLast() }
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Every reading of one selection, best first: the strict token, then
    /// the whitespace-collapsed rejoin. Resolution walks this in order, so
    /// an exact hit always wins over a tolerant one.
    public static func pathCandidates(from selection: String) -> [String] {
        var candidates: [String] = []
        if let strict = pathCandidate(from: selection) { candidates.append(strict) }
        if let collapsed = collapsedPathCandidate(from: selection),
           !candidates.contains(collapsed) {
            candidates.append(collapsed)
        }
        return candidates
    }

    /// Gate for showing the selection-menu items at all: cheap, local,
    /// and biased against cluttering everyday copy flows. A true here
    /// only unlocks the menu item — the real existence check is the
    /// bridge stat when the action fires. Both readings count, so a path
    /// that wrapped across rows still offers the menu.
    public static func isPlausiblePath(_ selection: String) -> Bool {
        pathCandidates(from: selection).contains(where: looksLikePath)
    }

    private static func looksLikePath(_ candidate: String) -> Bool {
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
    public static func expand(_ typed: String, home: String?, cwd: String?) -> String? {
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
    public static func lexicallyNormalized(_ absolute: String) -> String {
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

    // MARK: - Completion (§2, shared verbatim by quick-open §4)

    public struct CompletionContext: Equatable, Hashable, Sendable {
        /// Directory whose entries the prefix filters.
        public let parentPath: String
        /// Segment after the last "/" — what the user is mid-typing.
        public let prefix: String

        public init(parentPath: String, prefix: String) {
            self.parentPath = parentPath
            self.prefix = prefix
        }
    }

    /// Default number of suggestions a path bar shows.
    public static let defaultCompletionLimit = 6

    /// Splits typed input into the directory to list and the segment to
    /// prefix-match. nil when the input can't anchor to a directory yet
    /// (relative with no cwd, `~` with no home).
    public static func completionContext(
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
    public static func completions<Candidate: RemotePathCompletionCandidate>(
        prefix: String,
        in entries: [Candidate],
        limit: Int = defaultCompletionLimit
    ) -> [Candidate] {
        let lowered = prefix.lowercased()
        let matches = entries.filter { entry in
            guard prefix.hasPrefix(".") || !entry.completionIsHidden else { return false }
            return lowered.isEmpty || entry.completionName.lowercased().hasPrefix(lowered)
        }
        let ranked = matches.sorted { a, b in
            let aDir = a.completionIsDirectory, bDir = b.completionIsDirectory
            if aDir != bDir { return aDir }
            return a.completionName.localizedCaseInsensitiveCompare(b.completionName)
                == .orderedAscending
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Whitespace-tolerant name matching (§3 fallback)

    /// The whitespace a wrapped path can be broken by, spelled out rather
    /// than taken from `CharacterSet.whitespacesAndNewlines` so Swift and
    /// Kotlin agree character for character (Java's `isWhitespace` excludes
    /// U+0085 and U+00A0; Foundation's set includes both).
    ///
    /// Scalar-wise, like `containsControlCharacter`, because Swift folds
    /// CRLF into one `Character` that matches neither "\r" nor "\n" — a
    /// per-`Character` test would carry a wrapped line break straight
    /// through the collapse.
    public static func isCollapsibleWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\t", "\n", "\r", "\u{0B}", "\u{0C}", "\u{A0}": true
        default: false
        }
    }

    /// A grapheme cluster counts as whitespace only when every scalar in it
    /// does — which is what makes the CRLF cluster one separator.
    public static func isCollapsibleWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(isCollapsibleWhitespace)
    }

    /// `String.trimmingCharacters(in: .whitespacesAndNewlines)` restricted
    /// to the same set, so the two platforms trim identically.
    public static func trimmingCollapsibleWhitespace(_ value: String) -> String {
        var slice = Substring(value)
        while let first = slice.first, isCollapsibleWhitespace(first) { slice.removeFirst() }
        while let last = slice.last, isCollapsibleWhitespace(last) { slice.removeLast() }
        return String(slice)
    }

    /// The name with every collapsible whitespace character removed —
    /// `"review v3.pdf"` and `"reviewv3.pdf"` share one collapsed form, which
    /// is exactly what makes them match in the fallback.
    public static func collapsingWhitespace(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !isCollapsibleWhitespace($0) }))
    }

    /// Directory entries that answer to `name`, exact spelling first.
    ///
    /// An exact hit short-circuits to a single result, so a directory
    /// holding both `review v3.pdf` and `reviewv3.pdf` still resolves the
    /// one that was actually named. Otherwise every entry whose name
    /// collapses to the same spelling comes back, and the caller decides
    /// what to do with an ambiguous set (Tessera refuses rather than guess
    /// which document to open).
    public static func entries<Candidate: RemotePathCompletionCandidate>(
        named name: String,
        in entries: [Candidate]
    ) -> [Candidate] {
        if let exact = entries.first(where: { $0.completionName == name }) { return [exact] }
        let target = collapsingWhitespace(name)
        guard !target.isEmpty else { return [] }
        return entries.filter { collapsingWhitespace($0.completionName) == target }
    }

    // MARK: - Shared predicates

    /// Foundation-only stand-in for Kotlin's `Char.isISOControl`: the C0
    /// (U+0000–U+001F) and C1 (U+007F–U+009F) control ranges, tested per
    /// Unicode scalar so a CRLF grapheme cluster can't slip through as one
    /// "non-control" Character.
    public static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (scalar.value >= 0x7F && scalar.value <= 0x9F)
        }
    }

    /// The same debris test for the collapsed reading, which has to let the
    /// line breaks and tabs that wrapped the path through: ESC, NUL and BEL
    /// still disqualify a selection, `\n` and `\t` no longer do.
    public static func containsNonWhitespaceControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            guard scalar.value <= 0x1F || (scalar.value >= 0x7F && scalar.value <= 0x9F) else {
                return false
            }
            return !isCollapsibleWhitespace(scalar)
        }
    }
}
