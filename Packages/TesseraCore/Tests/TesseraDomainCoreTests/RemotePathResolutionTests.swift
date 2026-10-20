import Foundation
import XCTest
@testable import TesseraDomainCore

/// Shared-core coverage for the path grammar behind the files panel's path
/// bar, quick open and the terminal-selection menu.
///
/// Cases come from three places and are labelled as such: the iOS
/// `RemotePathResolverTests` (canonical semantics), Android's
/// `RemoteSelectionPathResolverTest` (the peer this now feeds), and one
/// named test per hard-won rule so a future edit has to argue with a name.
final class RemotePathResolutionTests: XCTestCase {

    // MARK: - pathCandidate: selection cleanup

    func testCandidateTrimsAndStripsQuotes() {
        XCTAssertEqual(
            RemotePathGrammar.pathCandidate(from: "  '/tmp/a file.png'\n"),
            "/tmp/a file.png"
        )
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "\"~/docs/x.md\""), "~/docs/x.md")
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "`src/main.rs`"), "src/main.rs")
        // Android's peer case, same answer.
        XCTAssertEqual(
            RemotePathGrammar.pathCandidate(from: "  '/tmp/a file.png'  "),
            "/tmp/a file.png"
        )
    }

    /// Hard-won rule: exactly ONE quote layer comes off. A doubly quoted
    /// selection keeps its inner quotes, because the inner pair is part of
    /// the filename as far as we can tell.
    func testOnlyOneQuoteLayerIsStripped() {
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "\"'/tmp/x'\""), "'/tmp/x'")
        // Mismatched wrappers are not a layer at all.
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "'/tmp/x\""), "'/tmp/x\"")
    }

    /// Hard-won rule: clang prints `file:line:col:` — punctuation strips
    /// before AND after the `:line[:col]` removal, or the trailing colon
    /// hides the suffix from the regex.
    func testCompilerLocationSuffixStripsWithSurroundingPunctuation() {
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "src/App.tsx:23:5"), "src/App.tsx")
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "src/App.tsx:23:5:"), "src/App.tsx")
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "main.c:12."), "main.c")
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "docs/readme.md,"), "docs/readme.md")
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "server.log:"), "server.log")
        // Android's peer case, same answer.
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "src/App.kt:23:5:"), "src/App.kt")
    }

    func testCandidateRejectsProseAndEmpty() {
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "hello world"))
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "   \n"))
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "see docs/readme.md,"))
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "/tmp/a\nrm -rf /"))
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: String(repeating: "a", count: 2000)))
        // Boundary: 1024 is fine, 1025 is not.
        XCTAssertNotNil(
            RemotePathGrammar.pathCandidate(from: "/" + String(repeating: "a", count: 1023))
        )
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: String(repeating: "a", count: 1025)))
    }

    /// The ONE deliberate iOS-visible change of the shared-core extraction:
    /// Android's ISO-control rejection is now canonical. A selection
    /// carrying NUL, ESC or a bare CR is terminal debris (or an escape
    /// injection attempt), never a path worth offering in a menu.
    func testControlCharactersAreRejectedHardening() {
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "/tmp/a\u{0}b"))
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "/tmp/\u{1B}[31mred"))
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "'/tmp/a\u{7}bell'"))
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "/tmp/a\u{9F}b"))
        // CRLF is a single Character with two scalars — the scan is per
        // scalar so it cannot hide inside a grapheme cluster.
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "/tmp/a\r\nb"))
        XCTAssertFalse(RemotePathGrammar.containsControlCharacter("/tmp/perfectly ordinary"))
        // Trailing whitespace/newlines are trimmed BEFORE the scan, so an
        // ordinary copied line still parses.
        XCTAssertEqual(RemotePathGrammar.pathCandidate(from: "/tmp/x\r\n"), "/tmp/x")
    }

    // MARK: - isPlausiblePath: menu gate

    func testPlausibilityGateAvoidsOrdinaryCopyText() {
        XCTAssertTrue(RemotePathGrammar.isPlausiblePath("/var/log/nginx"))
        XCTAssertTrue(RemotePathGrammar.isPlausiblePath("~/projects"))
        XCTAssertTrue(RemotePathGrammar.isPlausiblePath("docs/layout-broken.png"))
        XCTAssertTrue(RemotePathGrammar.isPlausiblePath(".env"))
        XCTAssertTrue(RemotePathGrammar.isPlausiblePath("README.md"))
        XCTAssertFalse(RemotePathGrammar.isPlausiblePath("plain prose sentence"))
        XCTAssertFalse(RemotePathGrammar.isPlausiblePath("noextension"))
        // A lone "." is not a hidden file.
        XCTAssertFalse(RemotePathGrammar.isPlausiblePath("."))
    }

    // MARK: - expand: typed input

    func testExpandHandlesTildeAbsoluteAndRelative() {
        let home = "/home/qi"
        let cwd = "/home/qi/projects"
        XCTAssertEqual(RemotePathGrammar.expand("~", home: home, cwd: cwd), "/home/qi")
        XCTAssertEqual(RemotePathGrammar.expand("~/x/y", home: home, cwd: cwd), "/home/qi/x/y")
        XCTAssertEqual(RemotePathGrammar.expand("/etc/hosts", home: nil, cwd: nil), "/etc/hosts")
        XCTAssertEqual(
            RemotePathGrammar.expand("build/out.log", home: home, cwd: cwd),
            "/home/qi/projects/build/out.log"
        )
        // Relative with no cwd can't anchor.
        XCTAssertNil(RemotePathGrammar.expand("build/out.log", home: home, cwd: nil))
        // ~ with no home can't anchor.
        XCTAssertNil(RemotePathGrammar.expand("~/x", home: nil, cwd: cwd))
        // ~user is not lexically resolvable — nil, never cwd-relative.
        XCTAssertNil(RemotePathGrammar.expand("~bob/x", home: home, cwd: cwd))
        // Typed paths may contain spaces (unlike selections).
        XCTAssertEqual(
            RemotePathGrammar.expand("/data/My Files", home: nil, cwd: nil),
            "/data/My Files"
        )
    }

    /// Android's `RemoteSelectionPathResolverTest` expansion cases, verbatim.
    func testExpandMatchesAndroidPeerCases() {
        XCTAssertEqual(
            RemotePathGrammar.expand("build/out.log", home: "/home/dev", cwd: "/home/dev/projects"),
            "/home/dev/projects/build/out.log"
        )
        XCTAssertEqual(
            RemotePathGrammar.expand("~/a/./b/../c", home: "/home/dev", cwd: nil),
            "/home/dev/a/c"
        )
        XCTAssertEqual(
            RemotePathGrammar.expand("../sibling", home: nil, cwd: "/home/dev/projects"),
            "/home/dev/sibling"
        )
        XCTAssertNil(RemotePathGrammar.expand("relative", home: "/home/dev", cwd: nil))
        XCTAssertNil(RemotePathGrammar.expand("~other/file", home: "/home/dev", cwd: "/tmp"))
    }

    /// Documented divergence, not an oversight: Android's `expand` also
    /// rejects control characters, iOS's never has, and iOS semantics are
    /// canonical outside the one hardening above. It is unreachable in
    /// practice — the selection path always runs `pathCandidate` first
    /// (which now rejects them) and a path bar cannot type a NUL.
    func testExpandKeepsIOSControlCharacterBehaviour() {
        XCTAssertEqual(RemotePathGrammar.expand("/tmp/a\u{0}b", home: nil, cwd: nil), "/tmp/a\u{0}b")
        XCTAssertNil(RemotePathGrammar.pathCandidate(from: "/tmp/a\u{0}b"))
    }

    /// Trailing slashes on home/cwd would otherwise double up; the lexical
    /// normalizer collapses them, which is why the expander doesn't trim.
    func testExpandToleratesTrailingSlashAnchors() {
        XCTAssertEqual(RemotePathGrammar.expand("~/x", home: "/home/qi/", cwd: nil), "/home/qi/x")
        XCTAssertEqual(RemotePathGrammar.expand("~/x", home: "/", cwd: nil), "/x")
        XCTAssertEqual(RemotePathGrammar.expand("x", home: nil, cwd: "/tmp/"), "/tmp/x")
    }

    // MARK: - lexicallyNormalized

    /// Hard-won rule: ".." never pops past root. A selection of `../../..`
    /// resolves to "/" and not to something above it.
    func testNormalizationStopsAtRoot() {
        XCTAssertEqual(RemotePathGrammar.lexicallyNormalized("/a/./b/../c/"), "/a/c")
        XCTAssertEqual(RemotePathGrammar.lexicallyNormalized("/../.."), "/")
        XCTAssertEqual(RemotePathGrammar.lexicallyNormalized("/"), "/")
        XCTAssertEqual(RemotePathGrammar.lexicallyNormalized("/a//b"), "/a/b")
        XCTAssertEqual(
            RemotePathGrammar.expand("../sibling", home: nil, cwd: "/home/qi/projects"),
            "/home/qi/sibling"
        )
        XCTAssertEqual(RemotePathGrammar.expand("../../../..", home: nil, cwd: "/a/b"), "/")
    }

    // MARK: - completionContext + completions

    func testCompletionContextSplitsSegments() {
        XCTAssertEqual(
            RemotePathGrammar.completionContext(forTyped: "/var/log/ngin", home: nil, cwd: nil),
            RemotePathGrammar.CompletionContext(parentPath: "/var/log", prefix: "ngin")
        )
        XCTAssertEqual(
            RemotePathGrammar.completionContext(forTyped: "/var/log/", home: nil, cwd: nil),
            RemotePathGrammar.CompletionContext(parentPath: "/var/log", prefix: "")
        )
        XCTAssertEqual(
            RemotePathGrammar.completionContext(forTyped: "ngi", home: nil, cwd: "/var/log"),
            RemotePathGrammar.CompletionContext(parentPath: "/var/log", prefix: "ngi")
        )
        XCTAssertNil(RemotePathGrammar.completionContext(forTyped: "ngi", home: nil, cwd: nil))
        XCTAssertEqual(
            RemotePathGrammar.completionContext(forTyped: "~/pro", home: "/home/qi", cwd: nil),
            RemotePathGrammar.CompletionContext(parentPath: "/home/qi", prefix: "pro")
        )
    }

    func testCompletionsRankDirsFirstAndGateHiddenEntries() {
        let entries = [
            RemotePathCompletionEntry(name: "nginx-install.log"),
            RemotePathCompletionEntry(name: "nginx", isDirectory: true),
            RemotePathCompletionEntry(name: "nginx-agent", isDirectory: true),
            RemotePathCompletionEntry(name: ".nginx-secret"),
            RemotePathCompletionEntry(name: "apache", isDirectory: true),
        ]
        func names(_ result: [RemotePathCompletionEntry]) -> [String] {
            result.map(\.completionName)
        }

        XCTAssertEqual(
            names(RemotePathGrammar.completions(prefix: "ngin", in: entries)),
            ["nginx", "nginx-agent", "nginx-install.log"]
        )
        // Hidden entries only surface when the prefix says dot.
        XCTAssertEqual(
            names(RemotePathGrammar.completions(prefix: ".ngi", in: entries)),
            [".nginx-secret"]
        )
        // Empty prefix lists the directory head, hidden still gated.
        XCTAssertEqual(
            names(RemotePathGrammar.completions(prefix: "", in: entries)),
            ["apache", "nginx", "nginx-agent", "nginx-install.log"]
        )
        // Case-insensitive.
        XCTAssertEqual(
            names(RemotePathGrammar.completions(prefix: "NGINX", in: entries)),
            ["nginx", "nginx-agent", "nginx-install.log"]
        )
        XCTAssertEqual(RemotePathGrammar.completions(prefix: "", in: entries, limit: 2).count, 2)
        XCTAssertEqual(RemotePathGrammar.defaultCompletionLimit, 6)
    }

    // MARK: - Wrapped selections (agent TUI output)

    /// The shape this exists for: an agent printed a path, the TUI wrapped
    /// it, and the next row arrived indented.
    func testCollapsedCandidateRejoinsAWrappedPath() {
        XCTAssertEqual(
            RemotePathGrammar.collapsedPathCandidate(from: "/home/qi/docs/review\n    v3.pdf"),
            "/home/qi/docs/reviewv3.pdf"
        )
        XCTAssertEqual(
            RemotePathGrammar.collapsedPathCandidate(from: "docs/rev\n\tiew-v3.pdf"),
            "docs/review-v3.pdf"
        )
        // Tail cleanup survives the rejoin.
        XCTAssertEqual(
            RemotePathGrammar.collapsedPathCandidate(from: "src/App\n  .tsx:23:5,"),
            "src/App.tsx"
        )
    }

    /// The collapsed reading is a *second* reading, never a replacement:
    /// nothing to collapse means nothing to add.
    func testCollapsedCandidateIsNilWithoutInteriorWhitespace() {
        XCTAssertNil(RemotePathGrammar.collapsedPathCandidate(from: "  /tmp/x  "))
        XCTAssertEqual(RemotePathGrammar.pathCandidates(from: "  /tmp/x  "), ["/tmp/x"])
    }

    func testCandidatesOrderStrictBeforeCollapsed() {
        // Quoted: the exact name is tried first, the rejoin second.
        XCTAssertEqual(
            RemotePathGrammar.pathCandidates(from: "'/tmp/a file.png'"),
            ["/tmp/a file.png", "/tmp/afile.png"]
        )
        // Unquoted with interior whitespace: only the rejoin survives.
        XCTAssertEqual(
            RemotePathGrammar.pathCandidates(from: "docs/review v3.pdf"),
            ["docs/reviewv3.pdf"]
        )
        // Candidates are readings, not verdicts: prose still collapses to a
        // token, and the plausibility gate is what keeps it out of the menu.
        XCTAssertEqual(RemotePathGrammar.pathCandidates(from: "hello world"), ["helloworld"])
        XCTAssertFalse(RemotePathGrammar.isPlausiblePath("hello world"))
    }

    /// A paragraph the user swiped over is not a wrapped path, however many
    /// slashes it happens to contain.
    func testCollapsedCandidateCapsFragmentCount() {
        let wrapped = "/home/qi/projects/tessera/docs\n  /reviews\n  /release\n  -v0.3.4.md"
        XCTAssertEqual(
            RemotePathGrammar.collapsedPathCandidate(from: wrapped),
            "/home/qi/projects/tessera/docs/reviews/release-v0.3.4.md"
        )
        let prose = (1...(RemotePathGrammar.maxCollapsedFragments + 1))
            .map { "word\($0)/x" }
            .joined(separator: " ")
        XCTAssertNil(RemotePathGrammar.collapsedPathCandidate(from: prose))
    }

    /// Line breaks and tabs wrapped the path; ESC, NUL and BEL are still
    /// terminal debris.
    func testCollapsedCandidateStillRejectsRealControlCharacters() {
        XCTAssertNil(RemotePathGrammar.collapsedPathCandidate(from: "/tmp/a\u{1B}[31m b.png"))
        XCTAssertNil(RemotePathGrammar.collapsedPathCandidate(from: "/tmp/a\u{0}b c.png"))
        XCTAssertNil(RemotePathGrammar.collapsedPathCandidate(from: "'/tmp/a\u{7}bell x'"))
        XCTAssertFalse(RemotePathGrammar.isPlausiblePath("/tmp/\u{1B}[31mred file.png"))
    }

    /// The menu gate has to open for a wrapped path, or the fallback never
    /// gets a chance to run.
    func testPlausibleGateAcceptsWrappedPathsAndStillRejectsProse() {
        XCTAssertTrue(RemotePathGrammar.isPlausiblePath("/home/qi/docs/review\n    v3.pdf"))
        XCTAssertTrue(RemotePathGrammar.isPlausiblePath("review\n v3.pdf"))
        XCTAssertFalse(RemotePathGrammar.isPlausiblePath("plain prose sentence"))
        XCTAssertFalse(RemotePathGrammar.isPlausiblePath("two words"))
    }

    // MARK: - Whitespace-tolerant name matching

    func testCollapsingWhitespaceIgnoresEveryBreakAPathCanTake() {
        XCTAssertEqual(RemotePathGrammar.collapsingWhitespace("review v3.pdf"), "reviewv3.pdf")
        XCTAssertEqual(RemotePathGrammar.collapsingWhitespace("a\t b\u{A0}c\r\n"), "abc")
        XCTAssertEqual(RemotePathGrammar.collapsingWhitespace("reviewv3.pdf"), "reviewv3.pdf")
    }

    /// The user's case, both directions: the selection lost the spaces the
    /// name has, or the name never had the spaces the selection shows.
    func testEntriesNamedMatchesAcrossSpaces() {
        let entries = [
            RemotePathCompletionEntry(name: "reviewv3.pdf"),
            RemotePathCompletionEntry(name: "notes.md"),
            RemotePathCompletionEntry(name: "Screen Shot 2026.png"),
        ]
        XCTAssertEqual(
            RemotePathGrammar.entries(named: "review v3.pdf", in: entries).map(\.completionName),
            ["reviewv3.pdf"]
        )
        XCTAssertEqual(
            RemotePathGrammar.entries(named: "ScreenShot2026.png", in: entries).map(\.completionName),
            ["Screen Shot 2026.png"]
        )
        XCTAssertEqual(RemotePathGrammar.entries(named: "missing.txt", in: entries), [])
    }

    /// An exact spelling always wins, even when a looser sibling exists —
    /// the fallback can never shadow a file that is really there.
    func testEntriesNamedPrefersExactSpellingOverCollapsedTwin() {
        let entries = [
            RemotePathCompletionEntry(name: "reviewv3.pdf"),
            RemotePathCompletionEntry(name: "review v3.pdf"),
        ]
        XCTAssertEqual(
            RemotePathGrammar.entries(named: "review v3.pdf", in: entries).map(\.completionName),
            ["review v3.pdf"]
        )
        // No exact hit: both twins come back so the caller can refuse rather
        // than open an arbitrary one.
        XCTAssertEqual(
            RemotePathGrammar.entries(named: "REVIEWv3.pdf", in: entries).count, 0
        )
        XCTAssertEqual(
            RemotePathGrammar.entries(named: "r eviewv3.pdf", in: entries).count, 2
        )
    }
}
