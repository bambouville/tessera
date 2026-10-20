// TesseraTests/RemotePathResolverTests.swift
//
// Pure-function coverage for the shared path resolver behind the
// files-panel improvements (path-bar input, quick open, terminal
// selection Quick Look) plus bridge-backed resolution against
// MockFileBridge. No network, no UI.

import Testing
import Foundation
@testable import Tessera

struct RemotePathResolverTests {

    // MARK: - pathCandidate (selection cleanup)

    @Test func candidateTrimsAndStripsQuotes() {
        #expect(RemotePathResolver.pathCandidate(from: "  '/tmp/a file.png'\n") == "/tmp/a file.png")
        #expect(RemotePathResolver.pathCandidate(from: "\"~/docs/x.md\"") == "~/docs/x.md")
        #expect(RemotePathResolver.pathCandidate(from: "`src/main.rs`") == "src/main.rs")
    }

    @Test func candidateStripsCompilerSuffixAndPunctuation() {
        #expect(RemotePathResolver.pathCandidate(from: "src/App.tsx:23:5") == "src/App.tsx")
        // clang's full token ends in ':' — punctuation strips before AND
        // after the :line:col removal.
        #expect(RemotePathResolver.pathCandidate(from: "src/App.tsx:23:5:") == "src/App.tsx")
        #expect(RemotePathResolver.pathCandidate(from: "main.c:12.") == "main.c")
        #expect(RemotePathResolver.pathCandidate(from: "see docs/readme.md,") == nil) // interior space → prose
        #expect(RemotePathResolver.pathCandidate(from: "docs/readme.md,") == "docs/readme.md")
        #expect(RemotePathResolver.pathCandidate(from: "server.log:") == "server.log")
    }

    @Test func candidateRejectsProseAndEmpty() {
        #expect(RemotePathResolver.pathCandidate(from: "hello world") == nil)
        #expect(RemotePathResolver.pathCandidate(from: "   \n") == nil)
        #expect(RemotePathResolver.pathCandidate(from: String(repeating: "a", count: 2000)) == nil)
    }

    /// The one deliberate iOS-visible change of the shared-core
    /// extraction: a selection carrying ISO control characters (NUL, ESC,
    /// a bare CR) is terminal debris, not a path, and no longer reaches
    /// the Files menu. The rule itself is pinned in
    /// `TesseraDomainCoreTests.RemotePathResolutionTests`.
    @Test func candidateRejectsControlCharacters() {
        #expect(RemotePathResolver.pathCandidate(from: "/tmp/a\u{0}b") == nil)
        #expect(RemotePathResolver.pathCandidate(from: "/tmp/\u{1B}[31mred") == nil)
        #expect(!RemotePathResolver.isPlausiblePath("/tmp/\u{1B}[31mred"))
        // Ordinary selections are untouched — trailing newlines still trim.
        #expect(RemotePathResolver.pathCandidate(from: "/tmp/x\r\n") == "/tmp/x")
    }

    // MARK: - isPlausiblePath (menu gate)

    @Test func plausibilityGate() {
        #expect(RemotePathResolver.isPlausiblePath("/var/log/nginx"))
        #expect(RemotePathResolver.isPlausiblePath("~/projects"))
        #expect(RemotePathResolver.isPlausiblePath("docs/layout-broken.png"))
        #expect(RemotePathResolver.isPlausiblePath(".env"))
        #expect(RemotePathResolver.isPlausiblePath("README.md"))
        #expect(!RemotePathResolver.isPlausiblePath("plain prose sentence"))
        #expect(!RemotePathResolver.isPlausiblePath("noextension"))
    }

    // MARK: - expand (typed input)

    @Test func expandHandlesTildeAbsoluteAndRelative() {
        let home = "/home/qi"
        let cwd = "/home/qi/projects"
        #expect(RemotePathResolver.expand("~", home: home, cwd: cwd) == "/home/qi")
        #expect(RemotePathResolver.expand("~/x/y", home: home, cwd: cwd) == "/home/qi/x/y")
        #expect(RemotePathResolver.expand("/etc/hosts", home: nil, cwd: nil) == "/etc/hosts")
        #expect(RemotePathResolver.expand("build/out.log", home: home, cwd: cwd)
                == "/home/qi/projects/build/out.log")
        // Relative with no cwd can't anchor.
        #expect(RemotePathResolver.expand("build/out.log", home: home, cwd: nil) == nil)
        // ~ with no home can't anchor.
        #expect(RemotePathResolver.expand("~/x", home: nil, cwd: cwd) == nil)
        // ~user is not lexically resolvable — nil, never cwd-relative.
        #expect(RemotePathResolver.expand("~bob/x", home: home, cwd: cwd) == nil)
        // Typed paths may contain spaces (unlike selections).
        #expect(RemotePathResolver.expand("/data/My Files", home: nil, cwd: nil) == "/data/My Files")
    }

    @Test func lexicalNormalization() {
        #expect(RemotePathResolver.lexicallyNormalized("/a/./b/../c/") == "/a/c")
        #expect(RemotePathResolver.lexicallyNormalized("/../..") == "/")
        #expect(RemotePathResolver.expand("../sibling", home: nil, cwd: "/home/qi/projects")
                == "/home/qi/sibling")
    }

    // MARK: - completionContext + completions

    @Test func completionContextSplitsSegments() {
        let ctx = RemotePathResolver.completionContext(
            forTyped: "/var/log/ngin", home: nil, cwd: nil)
        #expect(ctx == RemotePathResolver.CompletionContext(parentPath: "/var/log", prefix: "ngin"))

        let trailing = RemotePathResolver.completionContext(
            forTyped: "/var/log/", home: nil, cwd: nil)
        #expect(trailing == RemotePathResolver.CompletionContext(parentPath: "/var/log", prefix: ""))

        let bare = RemotePathResolver.completionContext(
            forTyped: "ngi", home: nil, cwd: "/var/log")
        #expect(bare == RemotePathResolver.CompletionContext(parentPath: "/var/log", prefix: "ngi"))

        #expect(RemotePathResolver.completionContext(forTyped: "ngi", home: nil, cwd: nil) == nil)

        let tilde = RemotePathResolver.completionContext(
            forTyped: "~/pro", home: "/home/qi", cwd: nil)
        #expect(tilde == RemotePathResolver.CompletionContext(parentPath: "/home/qi", prefix: "pro"))
    }

    @Test func completionsMatchDirsFirstHiddenGated() {
        func entry(_ name: String, dir: Bool = false) -> RemoteFileEntry {
            RemoteFileEntry(name: name, path: "/p/\(name)", kind: dir ? .directory : .file,
                            size: nil, modified: nil, permissions: nil)
        }
        let entries = [
            entry("nginx-install.log"),
            entry("nginx", dir: true),
            entry("nginx-agent", dir: true),
            entry(".nginx-secret"),
            entry("apache", dir: true),
        ]
        let matches = RemotePathResolver.completions(prefix: "ngin", in: entries)
        #expect(matches.map(\.name) == ["nginx", "nginx-agent", "nginx-install.log"])

        // Hidden entries only surface when the prefix says dot.
        let hidden = RemotePathResolver.completions(prefix: ".ngi", in: entries)
        #expect(hidden.map(\.name) == [".nginx-secret"])

        // Empty prefix lists the directory head, hidden still gated.
        let all = RemotePathResolver.completions(prefix: "", in: entries)
        #expect(all.map(\.name) == ["apache", "nginx", "nginx-agent", "nginx-install.log"])

        // Case-insensitive.
        let upper = RemotePathResolver.completions(prefix: "NGINX", in: entries)
        #expect(upper.map(\.name) == ["nginx", "nginx-agent", "nginx-install.log"])

        // Limit.
        let limited = RemotePathResolver.completions(prefix: "", in: entries, limit: 2)
        #expect(limited.count == 2)
    }

    // MARK: - resolve over MockFileBridge

    @Test @MainActor func resolveRoutesFilesAndDirectories() async throws {
        let bridge = MockFileBridge()
        try await bridge.connect()
        let home = "/home/mock"

        let dir = try await RemotePathResolver.resolve(
            absolute: "\(home)/projects/dashboard", bridge: bridge)
        #expect(dir == .directory("\(home)/projects/dashboard"))

        let file = try await RemotePathResolver.resolve(
            absolute: "\(home)/projects/dashboard/README.md", bridge: bridge)
        guard case .file(let entry) = file else {
            Issue.record("expected file resolution")
            return
        }
        #expect(entry.name == "README.md")

        let root = try await RemotePathResolver.resolve(absolute: "/", bridge: bridge)
        #expect(root == .directory("/"))

        await #expect(throws: FileBridgeError.self) {
            _ = try await RemotePathResolver.resolve(
                absolute: "\(home)/projects/dashboard/missing.txt", bridge: bridge)
        }
    }

    // MARK: - Whitespace-tolerant selection resolution

    /// Tree for the wrapped-path cases: a leaf whose name has no spaces, a
    /// leaf whose name does, and a *directory* whose name does.
    @MainActor
    private func wrappedTreeBridge() async throws -> MockFileBridge {
        func file(_ dir: String, _ name: String) -> RemoteFileEntry {
            RemoteFileEntry(name: name, path: "\(dir)/\(name)", kind: .file,
                            size: 1024, modified: Date(), permissions: 0o644)
        }
        func dir(_ parent: String, _ name: String) -> RemoteFileEntry {
            RemoteFileEntry(name: name, path: "\(parent)/\(name)", kind: .directory,
                            size: nil, modified: Date(), permissions: 0o755)
        }
        let home = "/home/mock"
        let docs = "\(home)/docs"
        let design = "\(home)/Design Files"
        let bridge = MockFileBridge(tree: [
            "/": [dir("", "home")],
            "/home": [dir("/home", "mock")],
            home: [dir(home, "docs"), dir(home, "Design Files")],
            docs: [file(docs, "reviewv3.pdf"), file(docs, "Q3 notes.md"), dir(docs, "old")],
            design: [file(design, "logo.png")],
            "\(docs)/old": [],
        ])
        try await bridge.connect()
        return bridge
    }

    /// The reported case: an agent printed the path, the TUI wrapped it, and
    /// the selection arrives as two indented fragments.
    @Test @MainActor func selectionResolvesAfterWrappingCollapsesTheName() async throws {
        let bridge = try await wrappedTreeBridge()
        let candidates = RemotePathResolver.pathCandidates(from: "docs/review\n    v3.pdf")
        let absolutes = candidates.compactMap {
            RemotePathResolver.expand($0, home: bridge.homeDirectory, cwd: "/home/mock")
        }
        #expect(absolutes == ["/home/mock/docs/reviewv3.pdf"])

        guard case .file(let entry) = try await RemotePathResolver.resolve(
            anyOf: absolutes, bridge: bridge) else {
            Issue.record("expected the wrapped path to resolve to a file")
            return
        }
        #expect(entry.path == "/home/mock/docs/reviewv3.pdf")
    }

    /// The other direction: the *file* is the one with spaces, and the
    /// selection lost them to the wrap.
    @Test @MainActor func selectionResolvesToANameThatKeptItsSpaces() async throws {
        let bridge = try await wrappedTreeBridge()
        guard case .file(let entry) = try await RemotePathResolver.resolve(
            anyOf: ["/home/mock/docs/Q3notes.md"], bridge: bridge) else {
            Issue.record("expected a whitespace-tolerant file hit")
            return
        }
        #expect(entry.name == "Q3 notes.md")
        #expect(entry.path == "/home/mock/docs/Q3 notes.md")
    }

    /// A directory name lost its space, so the parent listing itself misses
    /// and the walk has to match segment by segment.
    @Test @MainActor func selectionWalksDirectoriesThatLostTheirSpaces() async throws {
        let bridge = try await wrappedTreeBridge()
        guard case .file(let entry) = try await RemotePathResolver.resolve(
            anyOf: ["/home/mock/DesignFiles/logo.png"], bridge: bridge) else {
            Issue.record("expected the walk to find the spaced directory")
            return
        }
        #expect(entry.path == "/home/mock/Design Files/logo.png")

        // Directories route as directories, not files.
        let directory = try await RemotePathResolver.resolve(
            anyOf: ["/home/mock/DesignFiles"], bridge: bridge)
        #expect(directory == .directory("/home/mock/Design Files"))
    }

    /// Exact spelling is always tried first, so the tolerant pass can never
    /// shadow a file that is really there.
    @Test @MainActor func exactHitWinsOverTheCollapsedReading() async throws {
        let bridge = try await wrappedTreeBridge()
        bridge.tree["/home/mock/docs"]?.append(RemoteFileEntry(
            name: "review v3.pdf", path: "/home/mock/docs/review v3.pdf", kind: .file,
            size: 2048, modified: Date(), permissions: 0o644))

        // Quoted selection: strict "review v3.pdf" first, collapsed second.
        let candidates = RemotePathResolver.pathCandidates(from: "'docs/review v3.pdf'")
        let absolutes = candidates.compactMap {
            RemotePathResolver.expand($0, home: bridge.homeDirectory, cwd: "/home/mock")
        }
        #expect(absolutes == ["/home/mock/docs/review v3.pdf", "/home/mock/docs/reviewv3.pdf"])
        guard case .file(let entry) = try await RemotePathResolver.resolve(
            anyOf: absolutes, bridge: bridge) else {
            Issue.record("expected the exact name to win")
            return
        }
        #expect(entry.name == "review v3.pdf")
    }

    /// Two names that collapse alike and no exact hit: refuse rather than
    /// open an arbitrary document.
    @Test @MainActor func ambiguousCollapsedNamesRefuseToGuess() async throws {
        let bridge = try await wrappedTreeBridge()
        bridge.tree["/home/mock/docs"]?.append(RemoteFileEntry(
            name: "review v3.pdf", path: "/home/mock/docs/review v3.pdf", kind: .file,
            size: 2048, modified: Date(), permissions: 0o644))

        await #expect(throws: FileBridgeError.self) {
            _ = try await RemotePathResolver.resolve(
                anyOf: ["/home/mock/docs/re viewv3.pdf"], bridge: bridge)
        }
    }

    /// A miss is still a miss — the fallback adds tolerance, not invention.
    @Test @MainActor func unresolvableSelectionStillThrows() async throws {
        let bridge = try await wrappedTreeBridge()
        await #expect(throws: FileBridgeError.self) {
            _ = try await RemotePathResolver.resolve(
                anyOf: ["/home/mock/docs/nothinghere.pdf"], bridge: bridge)
        }
        await #expect(throws: FileBridgeError.self) {
            _ = try await RemotePathResolver.resolve(anyOf: [], bridge: bridge)
        }
    }
}
