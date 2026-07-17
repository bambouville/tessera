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
}
