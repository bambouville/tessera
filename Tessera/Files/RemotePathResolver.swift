// Tessera/Files/RemotePathResolver.swift
//
// iOS-facing name for the shared path grammar behind every "the user gave
// us a path" surface: the panel's editable path bar, quick-open, and the
// terminal-selection Quick Look menu (design:
// docs/mockups/files-panel-improvements/index.html).
//
// The rules themselves — selection cleanup, the plausibility gate, `~`/cwd
// expansion, lexical normalization and prefix completion — live in
// `TesseraDomainCore.RemotePathGrammar` so Android resolves a typed or
// selected path identically. What stays here is the one part that isn't
// pure: `resolve` stats by listing the parent directory over the bridge,
// because `FileBridging` deliberately has no stat and the listing is the
// call the browser already caches.

import Foundation
import TesseraDomainCore

enum RemotePathResolution: Equatable {
    case file(RemoteFileEntry)
    case directory(String)
}

/// Ranking only ever reads the name and the directory flag; size,
/// permissions and timestamps are none of the matcher's business.
extension RemoteFileEntry: RemotePathCompletionCandidate {
    var completionName: String { name }
    var completionIsDirectory: Bool { kind == .directory }
}

enum RemotePathResolver {

    // MARK: - Pure grammar (delegated)

    /// Cleans a terminal selection into a path candidate. See
    /// `RemotePathGrammar.pathCandidate(from:)` — including the one
    /// deliberate behavior change of the shared-core extraction: a
    /// selection containing ISO control characters is now rejected
    /// outright (terminal debris, never a path).
    static func pathCandidate(from selection: String) -> String? {
        RemotePathGrammar.pathCandidate(from: selection)
    }

    /// Every reading of one selection, best first: the strict token, then
    /// the same token with the whitespace that wrapped it removed. See
    /// `RemotePathGrammar.pathCandidates(from:)`.
    static func pathCandidates(from selection: String) -> [String] {
        RemotePathGrammar.pathCandidates(from: selection)
    }

    /// Gate for showing the selection-menu items at all.
    static func isPlausiblePath(_ selection: String) -> Bool {
        RemotePathGrammar.isPlausiblePath(selection)
    }

    /// Absolute path for user-typed input (trims, expands `~`, anchors
    /// relative input to `cwd`, lexically normalizes).
    static func expand(_ typed: String, home: String?, cwd: String?) -> String? {
        RemotePathGrammar.expand(typed, home: home, cwd: cwd)
    }

    /// "/a/./b/../c/" → "/a/c"; ".." never pops past root.
    static func lexicallyNormalized(_ absolute: String) -> String {
        RemotePathGrammar.lexicallyNormalized(absolute)
    }

    // MARK: - Completion (§2, shared verbatim by quick-open §4)

    typealias CompletionContext = RemotePathGrammar.CompletionContext

    /// Splits typed input into the directory to list and the segment to
    /// prefix-match.
    static func completionContext(
        forTyped typed: String, home: String?, cwd: String?
    ) -> CompletionContext? {
        RemotePathGrammar.completionContext(forTyped: typed, home: home, cwd: cwd)
    }

    /// Pure prefix matcher: case-insensitive, directories first, hidden
    /// entries only once the prefix itself starts with ".".
    static func completions(
        prefix: String,
        in entries: [RemoteFileEntry],
        limit: Int = RemotePathGrammar.defaultCompletionLimit
    ) -> [RemoteFileEntry] {
        RemotePathGrammar.completions(prefix: prefix, in: entries, limit: limit)
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
        case .other:
            throw FileBridgeError.remoteOperationFailed("Unsupported file type: \(path)")
        case .symlink:
            // Directory-ness decides the route; only a listing can tell.
            if (try? await bridge.listDirectory(path)) != nil {
                return .directory(path)
            }
            return .file(entry)
        }
    }

    /// Selection resolution: every reading of the selection is tried
    /// exactly first, and only once all of them miss does the tolerant
    /// pass run. Exact spelling therefore always wins — the fallback can
    /// never shadow a file that is really there.
    @MainActor
    static func resolve(
        anyOf absolutes: [String],
        bridge: any FileBridging
    ) async throws -> RemotePathResolution {
        guard let first = absolutes.first else {
            throw FileBridgeError.remoteOperationFailed("Not found")
        }
        var firstFailure: Error?
        for absolute in absolutes {
            do {
                return try await resolve(absolute: absolute, bridge: bridge)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        for absolute in absolutes {
            if let tolerant = try await resolveIgnoringWhitespace(
                absolute: absolute, bridge: bridge
            ) {
                return tolerant
            }
        }
        throw firstFailure ?? FileBridgeError.remoteOperationFailed("Not found: \(first)")
    }

    /// Whitespace-tolerant pass: matches each path segment against the
    /// directory listing by collapsed spelling, so `review v3.pdf` finds
    /// `reviewv3.pdf` (and the reverse — a name whose own spaces the
    /// terminal wrapped away).
    ///
    /// The leaf is tried on its own first, because a path that only lost
    /// spaces inside its filename needs exactly one listing — the same one
    /// the exact pass already warmed. The full walk only runs when the
    /// parent directory itself failed to list, which is where a name with
    /// spaces sits higher up the path.
    ///
    /// nil is a clean miss (nothing matched); an ambiguous directory
    /// throws rather than guessing which document to open.
    @MainActor
    static func resolveIgnoringWhitespace(
        absolute path: String,
        bridge: any FileBridging
    ) async throws -> RemotePathResolution? {
        let segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }

        let parent = segments.count == 1
            ? "/" : "/" + segments.dropLast().joined(separator: "/")
        if let siblings = try? await bridge.listDirectory(parent),
           let entry = try uniqueEntry(named: segments[segments.count - 1], in: siblings, path: path) {
            return try await route(entry, bridge: bridge)
        }

        // Walk from the root, which is where a *directory* whose own name
        // lost its spaces gets matched. Each step addresses the host's
        // spelling (`entry.path`), never the selection's: the result has to
        // survive a later listing, download or reveal.
        var directory = "/"
        var matched: RemoteFileEntry?
        for segment in segments {
            guard let entries = try? await bridge.listDirectory(directory) else { return nil }
            guard let entry = try uniqueEntry(named: segment, in: entries, path: path) else {
                return nil
            }
            matched = entry
            directory = entry.path
        }
        guard let matched else { return nil }
        return try await route(matched, bridge: bridge)
    }

    /// One entry answering to `name`, or nil when nothing does. Throws
    /// when several entries collapse to the same spelling: opening an
    /// arbitrary one of them would be a silent wrong answer.
    private static func uniqueEntry(
        named name: String,
        in entries: [RemoteFileEntry],
        path: String
    ) throws -> RemoteFileEntry? {
        let matches = RemotePathGrammar.entries(named: name, in: entries)
        if matches.count > 1 {
            throw FileBridgeError.remoteOperationFailed(
                "Several files match \(path) — open it from the Files panel."
            )
        }
        return matches.first
    }

    /// Routes a matched entry the same way `resolve(absolute:)` routes an
    /// exact hit.
    @MainActor
    private static func route(
        _ entry: RemoteFileEntry,
        bridge: any FileBridging
    ) async throws -> RemotePathResolution {
        switch entry.kind {
        case .directory:
            return .directory(entry.path)
        case .file:
            return .file(entry)
        case .other:
            throw FileBridgeError.remoteOperationFailed("Unsupported file type: \(entry.path)")
        case .symlink:
            if (try? await bridge.listDirectory(entry.path)) != nil {
                return .directory(entry.path)
            }
            return .file(entry)
        }
    }
}
