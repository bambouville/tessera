import XCTest
import TesseraDomainCore
@testable import TesseraArtifactsCore

final class TesseraArtifactsCoreTests: XCTestCase {
    func testFilesDeduplicateAndReopenFocusesClearsUnseen() {
        var state = open("a", .file(path: "/work//./a.md/"), now: 1)
        state.tabs[0].unseenChange = true
        state = open("b", .file(path: "/work/b.md"), now: 2, state: state)
        let reduction = reduce(state, .open(request("ignored", .file(path: "/work/a.md")), nowMillis: 20))
        XCTAssertEqual(reduction.state.tabs.count, 2)
        XCTAssertEqual(reduction.focusedTabID, "a")
        XCTAssertEqual(reduction.state.tabs[0].viewedAt, 20)
        XCTAssertFalse(reduction.state.tabs[0].unseenChange)
        XCTAssertEqual(reduction.state.tabs[0].target.path, "/work/a.md")
        let anotherHost = request("other", .file(path: "/work/a.md"), host: "h2")
        XCTAssertEqual(reduce(reduction.state, .open(anotherHost, nowMillis: 21)).state.tabs.count, 3)
    }

    func testPagesDeduplicateBySchemeAndPortAndReturnNavigation() {
        let state = open("a", .page(scheme: "HTTP", port: 5173, path: "/a#old"), now: 1)
        let reduction = reduce(state, .open(request("b", .page(scheme: "http", port: 5173, path: "/b?q#new")), nowMillis: 2))
        XCTAssertEqual(reduction.state.tabs.count, 1)
        XCTAssertEqual(reduction.focusedTabID, "a")
        XCTAssertEqual(reduction.navigatedPath, "/b?q#new")
        XCTAssertEqual(reduction.state.tabs[0].target.path, "/b?q#new")
        XCTAssertEqual(open("c", .page(scheme: "https", port: 5173, path: "/b"), now: 3, state: reduction.state).tabs.count, 2)
    }

    func testNewTabsAreAlwaysNewEvenBesideTheSamePortOrTheIdenticalLocation() {
        var state = open("root", .page(scheme: "http", port: 8001, path: "/"), now: 1)
        let laptop = reduce(state, .open(request("laptop", .page(scheme: "http", port: 8001, path: "/laptop.html"), newTab: true), nowMillis: 2))
        XCTAssertEqual(laptop.state.tabs.map(\.id), ["root", "laptop"])
        XCTAssertEqual(laptop.focusedTabID, "laptop")
        XCTAssertEqual(laptop.navigatedPath, "/laptop.html")
        XCTAssertEqual(laptop.state.tabs[0].target, .page(scheme: "http", port: 8001, path: "/"))
        state = reduce(laptop.state, .open(request("again", .page(scheme: "http", port: 8001, path: "/laptop.html"), newTab: true), nowMillis: 3)).state
        XCTAssertEqual(state.tabs.count, 3)
        state = reduce(state, .open(request("file", .file(path: "/work/a.md"), newTab: true), nowMillis: 4)).state
        state = reduce(state, .open(request("file2", .file(path: "/work/a.md"), newTab: true), nowMillis: 5)).state
        XCTAssertEqual(state.tabs.filter { $0.target == .file(path: "/work/a.md") }.map(\.id), ["file", "file2"])
        // A reused ID still never duplicates a tab.
        XCTAssertEqual(reduce(state, .open(request("file", .file(path: "/b"), newTab: true), nowMillis: 6)).state, state)
    }

    func testAutomaticOpensFocusTheExactLocationThenTheMostRecentPortTab() {
        var state = open("root", .page(scheme: "http", port: 8001, path: "/"), now: 1)
        state = reduce(state, .open(request("laptop", .page(scheme: "http", port: 8001, path: "/laptop.html"), newTab: true), nowMillis: 2)).state
        state = reduce(state, .select(tabID: "root", nowMillis: 3)).state
        let exact = reduce(state, .open(request("ignored", .page(scheme: "http", port: 8001, path: "/laptop.html")), nowMillis: 4))
        XCTAssertEqual(exact.focusedTabID, "laptop")
        XCTAssertEqual(exact.state.tabs.count, 2)
        XCTAssertEqual(exact.navigatedPath, "/laptop.html")
        // Another route on the port navigates the port tab viewed last.
        let other = reduce(exact.state, .open(request("ignored", .page(scheme: "http", port: 8001, path: "/other")), nowMillis: 5))
        XCTAssertEqual(other.focusedTabID, "laptop")
        XCTAssertEqual(other.state.tabs.map(\.target.path), ["/", "/other"])
        XCTAssertEqual(open("ignored", .file(path: "/a"), now: 6, state: open("a", .file(path: "/a"), now: 5)).tabs.count, 1)
    }

    func testNavigateRetargetsAPageOrFileTabInPlaceButNeverAChange() {
        var state = open("page", .page(scheme: "http", port: 8001, path: "/"), now: 1)
        state = reduce(state, .titleLearned(tabID: "page", title: "home", nowMillis: 1)).state
        state = open("doc", .file(path: "/work/a.md"), now: 2, state: state)
        state = reduce(state, .fetched(tabID: "doc", cache: .init(fetchedAt: 2, size: 3), nowMillis: 2)).state
        state = reduce(state, .agentEditObserved(hostID: "h1", path: "/work/a.md", nowMillis: 3)).state
        let page = reduce(state, .navigate(tabID: "page", target: .page(scheme: "http", port: 8002, path: "laptop.html?x#y"),
                                           title: "localhost:8002", nowMillis: 4))
        XCTAssertEqual(page.focusedTabID, "page")
        XCTAssertEqual(page.navigatedPath, "/laptop.html?x#y")
        XCTAssertEqual(page.state.tabs[0].target, .page(scheme: "http", port: 8002, path: "/laptop.html?x#y"))
        XCTAssertEqual(page.state.tabs[0].title, "localhost:8002")
        XCTAssertEqual(page.state.tabs.count, 2)
        let doc = reduce(page.state, .navigate(tabID: "doc", target: .file(path: "/work//b.png"), title: "b.png", nowMillis: 5))
        XCTAssertEqual(doc.state.tabs[1].target, .file(path: "/work/b.png"))
        XCTAssertEqual(doc.state.tabs[1].kind, .files)
        XCTAssertEqual(doc.state.tabs[1].title, "b.png")
        XCTAssertNil(doc.state.tabs[1].cache)
        XCTAssertNil(doc.state.tabs[1].agentEditedAt)
        XCTAssertFalse(doc.state.tabs[1].unseenChange)
        XCTAssertEqual(doc.state.tabs[1].origin, "quickOpen")
        XCTAssertNil(doc.navigatedPath)
        // The same target keeps what the tab knew and reloads a page.
        let same = reduce(doc.state, .navigate(tabID: "page", target: .page(scheme: "http", port: 8002, path: "/laptop.html?x#y"), title: "", nowMillis: 6))
        XCTAssertEqual(same.state.tabs[0].title, "localhost:8002")
        XCTAssertEqual(same.navigatedPath, "/laptop.html?x#y")
        // Changes are snapshots; unknown tabs and invalid targets do nothing.
        var withChange = open("change", .change(path: "/work/a.md", diff: "+a", summary: "s"), now: 7, state: same.state)
        withChange = reduce(withChange, .select(tabID: "doc", nowMillis: 8)).state
        XCTAssertEqual(reduce(withChange, .navigate(tabID: "change", target: .file(path: "/x"), title: "x", nowMillis: 9)).state, withChange)
        XCTAssertEqual(reduce(withChange, .navigate(tabID: "doc", target: .change(path: "/x", diff: "+", summary: ""), title: "x", nowMillis: 9)).state, withChange)
        XCTAssertEqual(reduce(withChange, .navigate(tabID: "missing", target: .file(path: "/x"), title: "x", nowMillis: 9)).state, withChange)
        XCTAssertEqual(reduce(withChange, .navigate(tabID: "doc", target: .file(path: ""), title: "x", nowMillis: 9)).state, withChange)
    }

    func testOpenRequestNewTabIsOptionalOnTheWireAndOmittedWhenFalse() throws {
        let legacy = #"{"id":"a","hostID":"h","hostLabel":"dev","target":{"type":"file","path":"/a"},"title":"a","origin":"files"}"#
        XCTAssertFalse(try JSONDecoder().decode(ArtifactsOpenRequest.self, from: Data(legacy.utf8)).newTab)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = String(decoding: try encoder.encode(request("a", .file(path: "/a"))), as: UTF8.self)
        XCTAssertFalse(plain.contains("newTab"))
        let explicit = request("a", .file(path: "/a"), newTab: true)
        XCTAssertTrue(String(decoding: try encoder.encode(explicit), as: UTF8.self).contains(#""newTab":true"#))
        XCTAssertEqual(try JSONDecoder().decode(ArtifactsOpenRequest.self, from: encoder.encode(explicit)), explicit)
    }

    func testChangesDeduplicateByNormalizedPathAndDiffBytes() {
        let state = open("a", .change(path: "/work//./a.swift", diff: "+a", summary: "first"), now: 1)
        let duplicate = open("b", .change(path: "/work/a.swift/", diff: "+a", summary: "renamed summary"), now: 2, state: state)
        XCTAssertEqual(duplicate.tabs.count, 1)
        XCTAssertEqual(duplicate.selectedID, "a")
        XCTAssertEqual(open("c", .change(path: "/work/a.swift", diff: "+b", summary: "new"), now: 3, state: duplicate).tabs.count, 2)
    }

    func testChangeOpenKeepsDistinctDiffsWithSharedCappedPrefixAcrossRestore() {
        let prefix = String(repeating: "+café\n", count: ArtifactsPersistence.maximumDiffBytes / 7 + 1)
        let first = ArtifactsTarget.change(path: "/work//a.swift", diff: prefix + "+first\n", summary: "first")
        let second = ArtifactsTarget.change(path: "/work/a.swift", diff: prefix + "+second\n", summary: "second")
        let state = open("first", first, now: 1)
        guard case let .change(_, diff, _) = state.tabs[0].target else { return XCTFail() }
        XCTAssertLessThanOrEqual(diff.utf8.count, ArtifactsPersistence.maximumDiffBytes)
        XCTAssertTrue(diff.hasSuffix("\\ diff truncated; sha256: \(ArtifactsDigest.hex(prefix + "+first\n"))\n"))
        let reopened = open("second", second, now: 2, state: state)
        XCTAssertEqual(reopened.tabs.map(\.id), ["first", "second"])
        XCTAssertEqual(reopened.selectedID, "second")
        XCTAssertNotEqual(reopened.tabs.first?.target.identity, reopened.tabs.last?.target.identity)
        let restored = ArtifactsPersistence.decode(ArtifactsPersistence.encode(reopened))
        XCTAssertEqual(restored, reopened)
        XCTAssertEqual(restored.tabs.map { $0.target.identity }, reopened.tabs.map { $0.target.identity })
        let duplicate = open("ignored", first, now: 3, state: restored)
        XCTAssertEqual(duplicate.tabs.map(\.id), ["first", "second"])
        XCTAssertEqual(duplicate.selectedID, "first")
        XCTAssertEqual(open("third", .change(path: "/work/a.swift", diff: prefix + "+third\n", summary: "third"),
                            now: 4, state: duplicate).tabs.map(\.id), ["first", "second", "third"])
    }

    func testChangeCapIsIdempotentAndKeepsOnlyWholeUTF8LinesWithinByteBound() {
        let limit = ArtifactsPersistence.maximumDiffBytes
        let markerSize = "\\ diff truncated; sha256: \(String(repeating: "0", count: 64))\n".utf8.count
        let exactPrefix = "+" + String(repeating: "x", count: limit - markerSize - 2) + "\n"
        let cases: [(String, String)] = [
            (exactPrefix + String(repeating: "+tail\n", count: 100), exactPrefix),
            ("+kept\n" + String(repeating: "é", count: limit / 2 + 1), "+kept\n"),
            (String(repeating: "é", count: limit / 2 + 1), ""),
            (String(repeating: "+é📄\r\n", count: limit / 9 + 1),
             String(repeating: "+é📄\r\n", count: (limit - markerSize) / 9)),
        ]
        for (source, prefix) in cases {
            let target = ArtifactsTarget.change(path: "/a", diff: source, summary: "edit")
            let capped = ArtifactsPersistence.capped(target)
            guard case let .change(path, diff, summary) = capped else { return XCTFail() }
            XCTAssertEqual(path, "/a")
            XCTAssertEqual(summary, "edit")
            XCTAssertEqual(diff, prefix + "\\ diff truncated; sha256: \(ArtifactsDigest.hex(source))\n")
            XCTAssertLessThanOrEqual(diff.utf8.count, limit)
            XCTAssertFalse(diff.contains("�"))
            XCTAssertEqual(ArtifactsPersistence.capped(capped), capped)
            if prefix == exactPrefix { XCTAssertEqual(diff.utf8.count, limit) }
        }
        for source in ["", "+é\n", String(repeating: "x", count: limit)] {
            let target = ArtifactsTarget.change(path: "/a", diff: source, summary: "edit")
            XCTAssertEqual(ArtifactsPersistence.capped(target), target)
        }
    }

    func testUnicodeFilenameIdentityAndPersistenceAreByteExact() throws {
        let composed = "/w/caf\u{E9}.md"
        let decomposed = "/w/cafe\u{301}.md"
        for isChange in [false, true] {
            let first: ArtifactsTarget = isChange ? .change(path: composed, diff: "+x", summary: "edit") : .file(path: composed)
            let second: ArtifactsTarget = isChange ? .change(path: decomposed, diff: "+x", summary: "edit") : .file(path: decomposed)
            XCTAssertNotEqual(first, second)
            XCTAssertNotEqual(first.identity, second.identity)
            XCTAssertTrue(first.identityGroup.utf8.allSatisfy { $0 < 128 })
            let state = open("second", second, now: 2, state: open("first", first, now: 1))
            XCTAssertEqual(state.tabs.map(\.id), ["first", "second"])
            XCTAssertEqual(state.selectedID, "second")
            let raw = ArtifactsState(tabs: [
                .init(id: "first", hostID: "h1", hostLabel: "dev", target: first, title: "first", openedAt: 1, viewedAt: 1),
                .init(id: "second", hostID: "h1", hostLabel: "dev", target: second, title: "second", openedAt: 2, viewedAt: 2),
            ], selectedID: "second")
            let restored = ArtifactsPersistence.decode(try JSONEncoder().encode(raw))
            XCTAssertEqual(restored.tabs.map(\.id), ["first", "second"])
            XCTAssertEqual(restored.tabs.map { Array($0.target.path.utf8) }, [Array(composed.utf8), Array(decomposed.utf8)])
            XCTAssertEqual(restored.selectedID, "second")
            XCTAssertEqual(ArtifactsPersistence.decode(ArtifactsPersistence.encode(raw)), restored)
        }
        XCTAssertNotEqual(ArtifactsTarget.file(path: composed).identity, ArtifactsTarget.file(path: "/w/caf%C3%A9.md").identity)
        XCTAssertNotEqual(ArtifactsTarget.file(path: "/w/a|b").identity, ArtifactsTarget.file(path: "/w/a%7Cb").identity)
        let edited = reduce(open("decomposed", .file(path: decomposed), now: 1),
                            .agentEditObserved(hostID: "h1", path: composed, nowMillis: 3)).state
        XCTAssertNil(edited.tabs[0].agentEditedAt)
        XCTAssertFalse(edited.tabs[0].unseenChange)
        XCTAssertEqual(reduce(edited, .agentEditObserved(hostID: "h1", path: "/w//./cafe\u{301}.md", nowMillis: 4)).state.tabs[0].agentEditedAt, 4)
    }

    func testCloseFallbackPrefersSameHostThenGlobalThenNil() {
        var state = open("a", .file(path: "/a"), now: 1)
        state = reduce(state, .open(request("b", .file(path: "/b"), host: "h2"), nowMillis: 20)).state
        state = open("c", .file(path: "/c"), now: 3, state: state)
        state = reduce(state, .close(tabID: "c", nowMillis: 30)).state
        XCTAssertEqual(state.selectedID, "a")
        XCTAssertEqual(state.tabs.first(where: { $0.id == "a" })?.viewedAt, 30)
        state = reduce(state, .close(tabID: "a", nowMillis: 31)).state
        XCTAssertEqual(state.selectedID, "b")
        state = reduce(state, .close(tabID: "b", nowMillis: 32)).state
        XCTAssertNil(state.selectedID)
    }

    func testCapEvictsLRUProtectingPinnedAndSelection() {
        var state = open("pinned", .file(path: "/p"), now: 1, state: .init(tabCap: 3))
        state = reduce(state, .pin(tabID: "pinned", pinned: true, nowMillis: 1)).state
        state = open("old", .file(path: "/old"), now: 2, state: state)
        state = open("recent", .file(path: "/recent"), now: 3, state: state)
        let result = reduce(state, .open(request("selected", .file(path: "/new")), nowMillis: 4))
        XCTAssertEqual(result.evictedTabIDs, ["old"])
        XCTAssertEqual(result.state.tabs.map(\.id), ["pinned", "recent", "selected"])
        var protected = result.state
        protected.tabCap = 1
        protected.tabs[1].pinned = true
        let soft = reduce(protected, .setFilter(.docs, nowMillis: 5))
        XCTAssertEqual(soft.state.tabs.count, 3)
        XCTAssertEqual(soft.evictedTabIDs, [])
    }

    func testStatSelectedVisibleBackgroundAndFetchBaseline() {
        var state = open("a", .file(path: "/a.md"), now: 1)
        let cache = ArtifactsCacheMetadata(fetchedAt: 1, remoteMTime: 100, size: 10)
        state = reduce(state, .fetched(tabID: "a", cache: cache, nowMillis: 2)).state
        state = reduce(state, .remoteStatObserved(tabID: "a", remoteMTime: 101, size: 10, visible: true, nowMillis: 3)).state
        XCTAssertTrue(state.tabs[0].cache!.isStale)
        XCTAssertFalse(state.tabs[0].unseenChange)
        state = open("b", .file(path: "/b.md"), now: 4, state: state)
        state = reduce(state, .remoteStatObserved(tabID: "a", remoteMTime: nil, size: 11, visible: true, nowMillis: 5)).state
        XCTAssertTrue(state.tabs[0].unseenChange)
        XCTAssertEqual(state.tabs[0].cache?.remoteMTime, 100)
        state = reduce(state, .fetched(tabID: "a", cache: .init(fetchedAt: 0, remoteMTime: 101, size: 11), nowMillis: 6)).state
        XCTAssertEqual(state.tabs[0].cache?.fetchedAt, 6)
        XCTAssertFalse(state.tabs[0].unseenChange)
        XCTAssertFalse(state.tabs[0].cache!.isStale)
        state = reduce(state, .select(tabID: "a", nowMillis: 7)).state
        state = reduce(state, .remoteStatObserved(tabID: "a", remoteMTime: 102, size: nil, visible: false, nowMillis: 8)).state
        XCTAssertTrue(state.tabs[0].unseenChange)
    }

    func testAgentEditMatchesFilePathsOnlyOnHostAndHostMutations() {
        var state = open("a", .file(path: "/work/a.md"), now: 1)
        state = reduce(state, .open(request("other", .file(path: "/work/a.md"), host: "h2"), nowMillis: 2)).state
        state = open("diff", .change(path: "/work/a.md", diff: "+x", summary: "edit"), now: 3, state: state)
        state = reduce(state, .agentEditObserved(hostID: "h1", path: "/work//./a.md/", nowMillis: 10)).state
        XCTAssertEqual(state.tabs.map(\.agentEditedAt), [10, nil, nil])
        XCTAssertEqual(state.tabs.map(\.unseenChange), [true, false, false])
        state = reduce(state, .hostRelabelled(hostID: "h1", label: "new label", nowMillis: 11)).state
        XCTAssertEqual(state.tabs.map(\.hostLabel), ["new label", "dev", "new label"])
        state = reduce(state, .hostRemoved(hostID: "h1", nowMillis: 12)).state
        XCTAssertEqual(state.tabs.map(\.id), ["other"])
        XCTAssertEqual(state.selectedID, "other")
        XCTAssertEqual(reduce(state, .closeAll(hostID: "h2", nowMillis: 13)).state.tabs, [])
    }

    func testFilterTitleAndActionWireRoundTrips() throws {
        var state = open("a", .file(path: "/a"), now: 1)
        state = reduce(state, .titleLearned(tabID: "a", title: "learned", nowMillis: 2)).state
        state = reduce(state, .setFilter(.files, nowMillis: 3)).state
        XCTAssertEqual(state.tabs[0].title, "learned")
        XCTAssertEqual(state.filter, .files)
        let actions: [ArtifactsAction] = [
            .open(request("a", .file(path: "/a")), nowMillis: 1), .select(tabID: "a", nowMillis: 1),
            .close(tabID: "a", nowMillis: 1), .closeAll(hostID: "h", nowMillis: 1),
            .pin(tabID: "a", pinned: false, nowMillis: 1), .setFilter(.all, nowMillis: 1),
            .titleLearned(tabID: "a", title: "A", nowMillis: 1),
            .fetched(tabID: "a", cache: .init(fetchedAt: 1, size: 0), nowMillis: 1),
            .remoteStatObserved(tabID: "a", remoteMTime: nil, size: 1, visible: false, nowMillis: 1),
            .agentEditObserved(hostID: "h", path: "/a", nowMillis: 1),
            .hostRemoved(hostID: "h", nowMillis: 1), .hostRelabelled(hostID: "h", label: "H", nowMillis: 1),
            .open(request("a", .page(scheme: "http", port: 1, path: "/"), newTab: true), nowMillis: 1),
            .navigate(tabID: "a", target: .page(scheme: "https", port: 2, path: "/x"), title: "x", nowMillis: 1),
        ]
        for action in actions {
            XCTAssertEqual(try JSONDecoder().decode(ArtifactsAction.self, from: JSONEncoder().encode(action)), action)
        }
    }

    func testOverviewGroupsRecentHostsFiltersAndFoldsDiacritics() {
        var state = open("a", .file(path: "/work/résumé.md"), now: 1)
        state.tabs[0].title = "Résumé"
        state = reduce(state, .open(request("b", .file(path: "/shot.png"), host: "h2"), nowMillis: 3)).state
        state = open("c", .page(scheme: "http", port: 8000, path: "/"), now: 2, state: state)
        let all = ArtifactsOverview.make(state, filter: .all, query: "")
        XCTAssertEqual(all.groups.map(\.hostID), ["h2", "h1"])
        XCTAssertEqual(all.groups[1].tabIDs, ["c", "a"])
        XCTAssertEqual(all.totalCount, 3)
        XCTAssertEqual(all.countsByKind, ["docs": 1, "pages": 1, "changes": 0, "files": 1])
        XCTAssertEqual(ArtifactsOverview.make(state, filter: .docs, query: "RESUME").groups[0].tabIDs, ["a"])
        XCTAssertEqual(ArtifactsOverview.make(state, filter: .pages, query: "resume").groups, [])
        state.tabs[1].hostLabel = "Café"
        XCTAssertEqual(ArtifactsOverview.make(state, filter: .all, query: "cafe").groups[0].hostID, "h2")
    }

    func testKindAndViewerSuperset() {
        for ext in ["md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "mdtext", "mdtxt", "rmd", "qmd", "mdx"] {
            XCTAssertEqual(ArtifactsKind.for(path: "/x.\(ext.uppercased())"), .docs)
            XCTAssertEqual(ArtifactsViewer.for(path: "x.\(ext)"), .markdown)
        }
        for ext in ["txt", "rst", "adoc", "org"] { XCTAssertEqual(ArtifactsKind.for(path: "x.\(ext)"), .docs) }
        let cases: [(String, ArtifactsKind, ArtifactsViewer)] = [
            ("x.html", .pages, .html), ("x.htm", .pages, .html), ("x.png", .files, .image),
            ("x.pdf", .files, .pdf), ("x.swift", .files, .text), ("x.patch", .files, .diff), ("x.bin", .files, .other),
        ]
        for (path, kind, viewer) in cases {
            XCTAssertEqual(ArtifactsKind.for(path: path), kind)
            XCTAssertEqual(ArtifactsViewer.for(path: path), viewer)
        }
        XCTAssertEqual(ArtifactsViewer.for(path: "unknown", mimeHint: "TEXT/HTML; charset=utf-8"), .html)
        XCTAssertEqual(ArtifactsViewer.for(path: "unknown", mimeHint: "application/json"), .text)
        XCTAssertEqual(ArtifactsTarget.page(scheme: "http", port: 80, path: "/").viewer, .web)
    }

    func testQuickOpenContractTable() {
        let context = ArtifactsQuickOpenContext(hosts: [
            .init(id: "h1", label: "dev", home: "/home/me"), .init(id: "h2", label: "build", home: "/Users/build"),
        ], currentHostID: "h1", cwd: "/work/project")
        let cases: [(String, ArtifactsQuickOpenIntent)] = [
            ("DEV:/tmp/a.md", .file(hostID: "h1", path: "/tmp/a.md")),
            ("build:docs/", .directory(hostID: "h2", path: "/Users/build/docs")),
            ("~/x", .file(hostID: "h1", path: "/home/me/x")),
            ("~", .directory(hostID: "h1", path: "/home/me")),
            ("/abs", .file(hostID: "h1", path: "/abs")),
            ("/abs/", .directory(hostID: "h1", path: "/abs")),
            ("/", .directory(hostID: "h1", path: "/")),
            ("./docs/../a.md", .file(hostID: "h1", path: "/work/project/docs/../a.md")),
            ("a.md", .file(hostID: "h1", path: "/work/project/a.md")),
            (":5173", .page(hostID: "h1", scheme: "http", port: 5173, path: "/")),
            ("localhost:5173/x", .page(hostID: "h1", scheme: "http", port: 5173, path: "/x")),
            ("127.0.0.1:8080", .page(hostID: "h1", scheme: "http", port: 8080, path: "/")),
            ("[::1]:3000", .page(hostID: "h1", scheme: "http", port: 3000, path: "/")),
            ("http://localhost:8080/a?b#c", .page(hostID: "h1", scheme: "http", port: 8080, path: "/a?b#c")),
            ("https://localhost/", .page(hostID: "h1", scheme: "https", port: 443, path: "/")),
            ("[::]:8000/", .page(hostID: "h1", scheme: "http", port: 8000, path: "/")),
            ("unknown:/a", .invalid(reason: .unknownHost)), (":65536", .invalid(reason: .invalidPort)),
            ("~someone/a", .invalid(reason: .invalidInput)), ("", .invalid(reason: .emptyInput)),
            ("http://example.com/", .invalid(reason: .unsupportedURL)),
            ("?restore plan", .search(text: "restore plan")), ("restore plan", .search(text: "restore plan")),
        ]
        for (input, expected) in cases { XCTAssertEqual(ArtifactsQuickOpen.parse(input, context: context), expected, input) }
        var noHome = context
        noHome.hosts[0].home = nil
        XCTAssertEqual(ArtifactsQuickOpen.parse("~/docs/", context: noHome), .directory(hostID: "h1", path: "~/docs"))
        XCTAssertEqual(ArtifactsQuickOpen.parse("~/x", context: noHome), .file(hostID: "h1", path: "~/x"))
        noHome.cwd = nil
        XCTAssertEqual(ArtifactsQuickOpen.parse("x.md", context: noHome), .invalid(reason: .missingCwd))
        noHome.hosts.append(.init(id: "duplicate", label: "DEV"))
        XCTAssertEqual(ArtifactsQuickOpen.parse("dev:/x", context: noHome), .invalid(reason: .ambiguousHost))
    }

    func testQuickOpenSuggestionsRankingAndLimits() {
        let state = open("a", .file(path: "/plan.md"), now: 1)
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "dev")], currentHostID: "h1", cwd: "/",
                                              listeningPorts: [.init(port: 5173, bindAddress: "*", process: "node")])
        let recents = [ArtifactsRecent(title: "plan-old.md", subtitle: "dev", intent: .file(hostID: "h1", path: "/plan-old.md"), viewedAt: 0)]
        let result = ArtifactsQuickOpen.suggestions("plan", state: state, context: context, recents: recents, limit: 10)
        XCTAssertEqual(result.map(\.kind), [.openTab, .recent])
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("dev:/plan.md", state: state, context: context, recents: recents).first?.kind, .hostPrefix)
        XCTAssertEqual(ArtifactsQuickOpen.suggestions(":51", state: state, context: context, recents: recents).first?.kind, .listeningPort)
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("localhost", state: state, context: context, recents: recents).count, 1)
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("", state: state, context: context, recents: recents, limit: 1).count, 1)
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("", state: state, context: context, recents: recents, limit: 0), [])
    }

    func testQuickOpenPreservesSymlinkParentComponentsForEveryAnchor() {
        let context = ArtifactsQuickOpenContext(hosts: [
            .init(id: "h1", label: "dev", home: "/home/me/link/.."),
            .init(id: "h2", label: "build", home: "/srv/link/.."),
        ], currentHostID: "h1", cwd: "/work/link/..")
        let cases: [(String, ArtifactsQuickOpenIntent)] = [
            ("/work/link/../a.md", .file(hostID: "h1", path: "/work/link/../a.md")),
            ("./docs//../a.md", .file(hostID: "h1", path: "/work/link/../docs/../a.md")),
            ("../", .directory(hostID: "h1", path: "/work/link/../..")),
            ("~/docs/../a.md", .file(hostID: "h1", path: "/home/me/link/../docs/../a.md")),
            ("build:docs/../a.md", .file(hostID: "h2", path: "/srv/link/../docs/../a.md")),
        ]
        for (input, expected) in cases { XCTAssertEqual(ArtifactsQuickOpen.parse(input, context: context), expected, input) }
    }

    func testQuickOpenBracketedRouteFoldersArePathsAndIPv6AuthoritiesArePages() {
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "dev")], currentHostID: "h1", cwd: "/work")
        for path in ["[slug]/page.tsx", "[...slug]/+page.svelte", "[[slug]]/", "[::1]/page.tsx", "[slug]:3000/page.tsx"] {
            let expected: ArtifactsQuickOpenIntent = path.hasSuffix("/")
                ? .directory(hostID: "h1", path: "/work/" + String(path.dropLast()))
                : .file(hostID: "h1", path: "/work/" + path)
            XCTAssertEqual(ArtifactsQuickOpen.parse(path, context: context), expected, path)
        }
        XCTAssertEqual(ArtifactsQuickOpen.parse("[::1]:3000/x?q#z", context: context),
                       .page(hostID: "h1", scheme: "http", port: 3000, path: "/x?q#z"))
        XCTAssertEqual(ArtifactsQuickOpen.parse("[::1]:65536/x", context: context), .invalid(reason: .invalidPort))
        for tail in ["/\u{0301}x", "?\u{0301}q", "#\u{0301}z"] {
            let path = tail.unicodeScalars.first == "/" ? tail : "/" + tail
            XCTAssertEqual(ArtifactsQuickOpen.parse("[::1]:3000" + tail, context: context),
                           .page(hostID: "h1", scheme: "http", port: 3000, path: path), tail)
        }
    }

    func testExplicitSearchSuggestionsUseParsedTextAndKeepByteDistinctPaths() {
        let state = open("plan", .file(path: "/plan.md"), now: 1)
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "dev")], currentHostID: "h1", cwd: "/")
        let recents = [ArtifactsRecent(title: "plan-old.md", subtitle: "dev", intent: .file(hostID: "h1", path: "/plan-old.md"), viewedAt: 0)]
        let result = ArtifactsQuickOpen.suggestions(" ?  plan ", state: state, context: context, recents: recents)
        XCTAssertEqual(result.map(\.kind), [.openTab, .recent])
        let paths = ["/w/caf\u{E9}.md", "/w/cafe\u{301}.md"]
        let unicode = paths.map { ArtifactsRecent(title: "café", subtitle: "dev", intent: .file(hostID: "h1", path: $0), viewedAt: 0) }
        XCTAssertNotEqual(unicode[0].intent, unicode[1].intent)
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("?cafe", state: .init(), context: context, recents: unicode).count, 2)
    }

    func testSuggestionsRetainDistinctSnapshotsAndNavigateExistingPort() {
        var state = open("file", .file(path: "/a.md"), now: 1)
        state = open("edit1", .change(path: "/a.md", diff: "+a", summary: "first"), now: 2, state: state)
        state = open("edit2", .change(path: "/a.md", diff: "+b", summary: "second"), now: 3, state: state)
        state = open("page", .page(scheme: "http", port: 5173, path: "/old"), now: 4, state: state)
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "dev")], currentHostID: "h1", cwd: "/",
                                              listeningPorts: [.init(port: 5173, bindAddress: "*")])
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("a.md", state: state, context: context, recents: []).map(\.tabID),
                       ["edit2", "edit1", "file"])
        let pages = ArtifactsQuickOpen.suggestions(":5173/new?q#z", state: state, context: context, recents: [])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.kind, .openTab)
        XCTAssertEqual(pages.first?.intent, .page(hostID: "h1", scheme: "http", port: 5173, path: "/new?q#z"))
    }

    func testEmptyQuickOpenOffersEveryRunningWebForwardAheadOfTabs() {
        let id: (Int) -> UUID = { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
        let vite = PortForwardRule.localForward(id: id(1), localPort: 15173, remotePort: 5173, label: "vite")
        let tls = PortForwardRule.localForward(id: id(2), localPort: 8443, remoteHost: "127.0.0.1", remotePort: 8443)
        var disabled = PortForwardRule.localForward(id: id(3), localPort: 9000, remotePort: 9000)
        disabled.enabled = false
        let excluded: [ArtifactsActiveForward] = [
            .init(hostID: "h1", rule: .localForward(id: id(4), localPort: 15432, remotePort: 5432)),
            .init(hostID: "h1", rule: .localForward(id: id(5), localPort: 13000, remoteHost: "db.internal", remotePort: 3000)),
            .init(hostID: "h1", rule: .init(id: id(6), direction: .dynamic, bind: .init(host: "127.0.0.1", port: 1080))),
            .init(hostID: "h1", rule: .init(id: id(7), direction: .remote, bind: .init(host: "127.0.0.1", port: 7000),
                                           target: .init(host: "localhost", port: 7000))),
            .init(hostID: "h1", rule: disabled),
            .init(hostID: "gone", rule: .localForward(id: id(8), localPort: 4000, remotePort: 4000)),
        ]
        let state = open("plan", .file(path: "/plan.md"), now: 1)
        let recents = [ArtifactsRecent(title: "old page", subtitle: "dev", intent: .page(hostID: "h1", scheme: "http", port: 5173, path: "/"),
                                       viewedAt: 0)]
        var context = ArtifactsQuickOpenContext(hosts: [.init(id: "h2", label: "build"), .init(id: "h1", label: "dev")],
                                                currentHostID: "h1", cwd: "/",
                                                activeForwards: [.init(hostID: "h2", rule: tls)] + excluded + [.init(hostID: "h1", rule: vite)])
        let suggestions = ArtifactsQuickOpen.suggestions("", state: state, context: context, recents: recents)
        XCTAssertEqual(suggestions.map(\.kind), [.activeForward, .activeForward, .openTab])
        XCTAssertEqual(suggestions[0], .init(kind: .activeForward, title: "localhost:5173", subtitle: "dev · vite",
                                             intent: .page(hostID: "h1", scheme: "http", port: 5173, path: "/")))
        XCTAssertEqual(suggestions[1], .init(kind: .activeForward, title: "localhost:8443", subtitle: "build",
                                             intent: .page(hostID: "h2", scheme: "https", port: 8443, path: "/")))
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("", state: state, context: context, recents: recents, limit: 1).map(\.kind),
                       [.activeForward])

        // Typed input filters forwards by port, host and rule label, and a
        // typed route on the forward's own port is kept.
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("vite", state: state, context: context, recents: []).map(\.title), ["localhost:5173"])
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("build", state: state, context: context, recents: []).map(\.title), ["localhost:8443"])
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("plan", state: state, context: context, recents: []).map(\.kind), [.openTab])
        XCTAssertEqual(ArtifactsQuickOpen.suggestions(":5173/app?q#z", state: state, context: context, recents: []).first?.intent,
                       .page(hostID: "h1", scheme: "http", port: 5173, path: "/app?q#z"))
        context.listeningPorts = [.init(port: 5173, bindAddress: "127.0.0.1", process: "node")]
        XCTAssertEqual(ArtifactsQuickOpen.suggestions(":51", state: state, context: context, recents: []).map(\.kind), [.activeForward],
                       "the probed port is the same page as the forward")

        // A forward already open as a tab is that tab.
        let opened = open("vite", .page(scheme: "http", port: 5173, path: "/docs"), now: 2, state: state)
        let withTab = ArtifactsQuickOpen.suggestions("", state: opened, context: context, recents: [])
        XCTAssertEqual(withTab.map(\.kind), [.activeForward, .openTab, .openTab])
        XCTAssertEqual(withTab.first?.title, "localhost:8443")
    }

    func testATypedPortListsTheHostsPortsBeforeTabsThatWouldFillTheLimit() {
        var state = ArtifactsState()
        for index in 0..<8 { state = open("file\(index)", .file(path: "/notes/\(index).md"), now: Int64(index), state: state) }
        state = open("page", .page(scheme: "http", port: 35757, path: "/"), now: 9, state: state)
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "dev")], currentHostID: "h1", cwd: "/", listeningPorts: [
            .init(port: 35757, bindAddress: "127.0.0.1", process: "python3"),
            .init(port: 8080, bindAddress: "*", process: "node"),
            .init(port: 22, bindAddress: "*", process: "sshd"),
        ])
        for input in [":", "localhost"] {
            let suggestions = ArtifactsQuickOpen.suggestions(input, state: state, context: context, recents: [])
            XCTAssertEqual(suggestions.prefix(2).map(\.title), ["localhost:22", "localhost:8080"], input)
            XCTAssertEqual(suggestions.map(\.tabID), [nil, nil, "page"], input)
            XCTAssertEqual(suggestions.map(\.kind), [.listeningPort, .listeningPort, .openTab], input)
        }
        XCTAssertEqual(ArtifactsQuickOpen.suggestions(":357", state: state, context: context, recents: []).map(\.tabID), ["page"],
                       "a port open as a tab is that tab")
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("notes", state: state, context: context, recents: []).count, 8,
                       "other input still matches every tab")
    }

    /// Only a port's own spelling asks for ports. A file named after the
    /// host, or a host labelled after it, still finds its tabs.
    func testANameThatStartsWithLocalhostIsNotAPort() {
        var state = open("conf", .file(path: "/etc/localhost.conf"), now: 1)
        state = reduce(state, .open(.init(id: "remote", hostID: "h2", hostLabel: "localhost-dev", target: .file(path: "/srv/app.log"),
                                          title: "/srv/app.log", newTab: false), nowMillis: 2)).state
        state = open("page", .page(scheme: "http", port: 35757, path: "/"), now: 3, state: state)
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "dev"), .init(id: "h2", label: "localhost-dev")],
                                              currentHostID: "h1", cwd: "/etc",
                                              listeningPorts: [.init(port: 8080, bindAddress: "*", process: "node")])
        for (input, tab) in [("localhost.conf", "conf"), ("localhost-dev:/srv/app", "remote")] {
            let suggestions = ArtifactsQuickOpen.suggestions(input, state: state, context: context, recents: [])
            XCTAssertEqual(suggestions.filter { $0.kind == .openTab }.map(\.tabID), [tab], input)
            XCTAssertFalse(suggestions.contains { $0.kind == .listeningPort }, input)
        }
        for input in ["localhost", "LOCALHOST:80", "localhost:"] {
            let suggestions = ArtifactsQuickOpen.suggestions(input, state: state, context: context, recents: [])
            XCTAssertEqual(suggestions.first?.title, "localhost:8080", input)
            XCTAssertFalse(suggestions.contains { $0.tabID == "conf" }, "\(input): a typed port matches pages only")
        }
    }

    func testQuickOpenWithoutRunningForwardsIsUnchanged() {
        var state = open("plan", .file(path: "/plan.md"), now: 1)
        state = open("page", .page(scheme: "http", port: 3000, path: "/"), now: 2, state: state)
        let recents = [ArtifactsRecent(title: "notes.md", subtitle: "dev", intent: .file(hostID: "h1", path: "/notes.md"), viewedAt: 0)]
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "dev")], currentHostID: "h1", cwd: "/",
                                              listeningPorts: [.init(port: 5173, bindAddress: "*", process: "node")])
        for input in ["", "plan", ":5", "dev:/plan.md"] {
            let suggestions = ArtifactsQuickOpen.suggestions(input, state: state, context: context, recents: recents)
            XCTAssertFalse(suggestions.isEmpty, input)
            XCTAssertFalse(suggestions.contains { $0.kind == .activeForward }, input)
        }
        XCTAssertEqual(ArtifactsQuickOpen.suggestions("", state: state, context: context, recents: recents).map(\.kind),
                       [.openTab, .openTab, .recent])
        let data = Data(#"{"hosts":[],"listeningPorts":[]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ArtifactsQuickOpenContext.self, from: data).activeForwards, [])
    }

    func testLinkClassifierTable() {
        let cases: [(String, ArtifactsLinkClass)] = [
            ("http://0.0.0.0:8000/", .remoteLoopback(scheme: "http", port: 8000, pathAndQuery: "/")),
            ("https://localhost/", .remoteLoopback(scheme: "https", port: 443, pathAndQuery: "/")),
            ("http://127.0.0.2:3000/x?y#z", .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: "/x?y#z")),
            ("http://127.255.2.9", .remoteLoopback(scheme: "http", port: 80, pathAndQuery: "/")),
            ("http://[::1]:3000/a", .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: "/a")),
            ("http://[::]:8000/", .remoteLoopback(scheme: "http", port: 8000, pathAndQuery: "/")),
            ("http://[0:0:0:0:0:0:0:1]/", .remoteLoopback(scheme: "http", port: 80, pathAndQuery: "/")),
            ("http://app.localhost:3000/x", .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: "/x")),
            ("http://A.B.LOCALHOST./", .remoteLoopback(scheme: "http", port: 80, pathAndQuery: "/")),
            ("http://a..localhost/", .remoteLoopback(scheme: "http", port: 80, pathAndQuery: "/")),
            ("http://.localhost/", .remoteLoopback(scheme: "http", port: 80, pathAndQuery: "/")),
            ("http://local\u{00ad}host:3000/", .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: "/")),
            ("http://local%C2%ADhost:3000/", .refused),
            ("http:////127.0.0.1:3000/", .refused), ("http:localhost:3000/", .refused),
            ("http:\\\\localhost/", .refused), ("https:/\\app.localhost/", .refused),
            ("http:example.com", .external), ("http:///example.com/", .external),
            ("http:\\\\example.com/", .external), ("https:/\\example.com/", .external),
            ("http://user@app.localhost/", .refused), ("http://app.localhost.example.com/", .external),
            ("http://applocalhost/", .external),
            ("http://\u{2603}.localhost:3000/", .refused), ("http://%E2%98%83.localhost:3000/", .refused),
            ("http://viewer@\u{2603}.localhost./", .refused), ("http:////\u{2603}.localhost/", .refused),
            ("http://\u{2603}.example/", .unsupported), ("http://\u{2603}localhost/", .unsupported),
            ("http://user@localhost:80/", .refused), ("http://viewer@127.0.0.1:3000/", .refused),
            ("https://user:pass@example.com/", .external),
            ("https://example.com/a", .external), ("http://localhost.example.com/", .external),
            ("http://128.0.0.1/", .external), ("https://[2001:db8::1]/", .external),
            ("file:///tmp/a", .unsupported), ("javascript:alert(1)", .unsupported),
            ("http://localhost:0/", .refused), ("http://localhost:65536/", .refused),
            ("http://localhost:/", .refused), ("http://127.0.0.1:bad/", .refused),
            ("http://[:::1]/", .unsupported), ("http://%6cocalhost/", .refused),
            ("http://localhost\\@evil.com/", .refused),
            ("https://user:pass@[::ffff:127.0.0.2]:3000/x", .refused),
            ("http://[::7fff:ffff]:65536/", .refused),
            ("http://%31%32%37%2e0%2e0%2e1:3000/", .refused),
            ("http://%5b::ffff:7f00:1%5d:3000/", .refused),
            ("http://localhost:%33%30%30%30/", .refused),
            ("http://local\thost:3000/", .refused), ("http://localhost:3000/has space", .refused),
            ("http://localhost:3000/has\u{200b}space", .refused),
            ("http://viewer@example.com:bad/", .external), ("http://%65xample.com/", .external),
            ("http://user@127.0.0.1.example/", .external),
            ("http://localhost@remote.example/", .external),
            ("http://viewer%zz@127.0.0.1:3000/", .refused),
            ("http://127.0.0.1:bad%zz/", .refused),
            ("http://[::ffff:127.0.0.1]:bad%zz/", .refused),
            ("ftp://viewer@127.0.0.1:3000/", .unsupported),
            ("file://[::ffff:127.0.0.1]/", .unsupported),
            ("ftp:localhost:3000/", .unsupported), ("file:localhost/", .unsupported),
            ("javascript:localhost", .unsupported), ("mailto:localhost", .unsupported),
            (" \t\r\nhttp://localhost:3000/ \t\r\n", .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: "/")),
            (" \t\r\nhttp:localhost:3000/ \t\r\n", .refused),
            ("h\tt\rt\np:local\thost:3000/", .refused),
            ("http:example.\tcom/", .external), ("http:local host:3000/", .unsupported),
        ]
        for (url, expected) in cases { XCTAssertEqual(ArtifactsLinkClassifier.classify(url), expected, url) }
    }

    func testLinkClassifierRefusesSpecialSchemeAuthoritySpellings() {
        for prefix in ["http:", "http:/", "http:\\", "http:///", "http:////", "HTTP:/\\//", "https:/\\"] {
            for host in ["localhost", "localhost.", "app.localhost", "a..localhost.", "127.0.0.1", "0.0.0.0",
                         "[::1]", "[::]", "[::ffff:127.0.0.1]"] {
                for authority in [host + ":3000", "viewer@" + host + ":3000", host + ":bad"] {
                    let url = prefix + authority + "/x?q#z"
                    XCTAssertNil(ArtifactsHTTPURL.parse(url), url)
                    XCTAssertEqual(ArtifactsLinkClassifier.classify(url), .refused, url)
                }
            }
            for host in ["example.com", "localhost.example", "128.0.0.1", "[2001:db8::1]"] {
                let url = prefix + "viewer@" + host + ":3000/x?q#z"
                XCTAssertNil(ArtifactsHTTPURL.parse(url), url)
                XCTAssertEqual(ArtifactsLinkClassifier.classify(url), .external, url)
            }
        }
    }

    func testLinkClassifierScansAuthorityDelimitersAsUnicodeScalars() {
        for mark in ["\u{034f}", "\u{fe0f}", "\u{0301}"] {
            for tail in ["/\(mark)x?q#z", "?\(mark)q#z", "#\(mark)z"] {
                let path = tail.unicodeScalars.first == "/" ? tail : "/" + tail
                XCTAssertEqual(ArtifactsLinkClassifier.classify("http://localhost:3000\(tail)"),
                               .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: path), tail)
                XCTAssertEqual(ArtifactsLinkClassifier.classify("http://viewer@localhost:3000\(tail)"), .refused, tail)
                XCTAssertEqual(ArtifactsLinkClassifier.classify("http://example.com:3000\(tail)"), .external, tail)
            }
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://localhost\\\(mark)@example.com/"), .refused, mark)
            let backslashPath = "http://localhost:3000/\\\(mark)x"
            XCTAssertNil(ArtifactsHTTPURL.parse(backslashPath), backslashPath)
            XCTAssertEqual(ArtifactsLinkClassifier.classify(backslashPath), .refused, backslashPath)
        }
        for ignored in ["\u{034f}", "\u{fe0f}"] {
            for prefix in ["http:", "http:/", "http:////", "http:/\\"] {
                XCTAssertEqual(ArtifactsLinkClassifier.classify("\(prefix)\(ignored)localhost:3000/"), .refused, prefix)
                XCTAssertEqual(ArtifactsLinkClassifier.classify("\(prefix)viewer@\(ignored)localhost:3000/"), .refused, prefix)
                XCTAssertEqual(ArtifactsLinkClassifier.classify("\(prefix)\(ignored)example.com:3000/"), .external, prefix)
            }
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://viewer@\(ignored)localhost:3000/"), .refused, ignored)
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://localhost@\(ignored)example.com:3000/"), .external, ignored)
        }
    }

    func testLinkClassifierRefusesBrowserTrimmedControlBoundaries() {
        for control in ["\u{0000}", "\u{0001}", "\u{0008}", "\u{001b}", "\u{001f}"] {
            for link in ["http://localhost:3000/", "https:/\\viewer@[::1]:3000/"] {
                let url = control + " \t\r\n" + link + " \t\r\n" + control
                XCTAssertNil(ArtifactsHTTPURL.parse(url), url.debugDescription)
                XCTAssertEqual(ArtifactsLinkClassifier.classify(url), .refused, url.debugDescription)
            }
            XCTAssertEqual(ArtifactsLinkClassifier.classify(control + "http:example.com/" + control), .external)
            XCTAssertEqual(ArtifactsLinkClassifier.classify(control + "ftp:localhost/" + control), .unsupported)
        }
    }

    func testRefusedLinkWireRoundTripHasOnlyItsType() throws {
        let data = Data(#"{"type":"refused"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ArtifactsLinkClass.self, from: data), .refused)
        XCTAssertEqual(try JSONEncoder().encode(ArtifactsLinkClass.refused), data)
    }

    func testForwardPlannerSamePortCollisionPrivilegedAndReuse() throws {
        guard case let .ephemeral(free) = ArtifactsForwardPlanner.plan(remotePort: 5173, hostRules: []) else { return XCTFail() }
        XCTAssertEqual(free.bind, .init(host: "127.0.0.1", port: 5173))
        XCTAssertEqual(free.target, .init(host: "localhost", port: 5173))
        XCTAssertFalse(free.autoStart)
        XCTAssertTrue(ArtifactsForwardPlanner.isValidEphemeral(free))
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let taken = PortForwardRule.localForward(id: id, localPort: 5173, remoteHost: "database", remotePort: 9000)
        guard case let .ephemeral(collided) = ArtifactsForwardPlanner.plan(remotePort: 5173, hostRules: [taken]),
              case let .ephemeral(low) = ArtifactsForwardPlanner.plan(remotePort: 80, hostRules: []) else { return XCTFail() }
        XCTAssertEqual(collided.bind.port, 0)
        XCTAssertEqual(low.bind.port, 0)
        XCTAssertTrue(ArtifactsForwardPlanner.isValidEphemeral(low))
        let existing = PortForwardRule.localForward(id: id, localPort: 18080, remotePort: 8080)
        guard case let .reuse(ruleID, target) = ArtifactsForwardPlanner.plan(remotePort: 8080, hostRules: [existing]) else { return XCTFail() }
        XCTAssertEqual(ruleID, id)
        XCTAssertEqual(target.url, "http://127.0.0.1:18080/")
        let persistent = ArtifactsForwardPlanner.keepAsRule(free, label: "dev app", ruleID: id)
        XCTAssertEqual(persistent.id, id)
        XCTAssertEqual(persistent.label, "dev app")
        XCTAssertTrue(persistent.autoStart)
        XCTAssertEqual(persistent.target, free.target)
        XCTAssertEqual(persistent.target?.host, "localhost")
        XCTAssertNil(PortForwardRuleValidator.validate(persistent))
        XCTAssertNotNil(PortForwardRuleValidator.validate(ArtifactsForwardPlanner.keepAsRule(low, label: "low", ruleID: id)))
    }

    func testForwardReuseAcceptsAllLoopbackSpellingsButRequiresEnabledMatchingRule() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        for host in ["localhost", "127.0.0.1", "127.20.30.40", "::1", "[::1]", "::ffff:127.0.0.1",
                     "[::ffff:7f00:1]", "::127.0.0.1", "[::7fff:ffff]", "::ffff:0.0.0.0"] {
            let rule = PortForwardRule.localForward(id: id, localPort: 18080, remoteHost: host, remotePort: 8080)
            guard case let .reuse(ruleID, _) = ArtifactsForwardPlanner.plan(remotePort: 8080, hostRules: [rule]) else {
                XCTFail("did not reuse \(host)"); continue
            }
            XCTAssertEqual(ruleID, id)
            var disabled = rule
            disabled.enabled = false
            guard case .ephemeral = ArtifactsForwardPlanner.plan(remotePort: 8080, hostRules: [disabled]),
                  case .ephemeral = ArtifactsForwardPlanner.plan(remotePort: 8081, hostRules: [rule]) else {
                XCTFail("reused disabled or wrong-port rule for \(host)"); continue
            }
        }
    }

    func testLinkClassifierCanonicalizesBrowserIPv4NumbersWithoutDNS() {
        for host in ["2130706433", "0177.0.0.1", "0x7f.1", "127.1", "localhost.", "127.0.0.1.",
                     "127.0.1", "0x7f000001", "017700000001", "127.0xffffff", "0x7f.0xff.0377.255", "2130706432", "0x0"] {
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://\(host):3000/x?q#z"),
                           .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: "/x?q#z"), host)
        }
        for host in ["4294967296", "256.0.0.1", "127.256.1", "127.16777216", "127.0.65536", "127.0.0.256",
                     "127.0.0.09", "127..1", "1.2.3.4.5", "0x100000000", "0xFFFFFFFFFFFFFFFFFFFFFFFF", "0xGG",
                     "999999999999999999999999999999999999", "example.123"] {
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://\(host):3000/"), .unsupported, host)
        }
        for host in ["0x80000000", "1.2.65535", "4294967295", "127.0.0.1.example", "localhost.example.com", "123.example", "localhost.."] {
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://\(host):3000/"), .external, host)
        }
    }

    func testLinkClassifierMapsUnicodeLoopbackHostsLikeBrowsers() {
        var hosts = [
            "ｌｏｃａｌｈｏｓｔ", "ＬＯＣＡＬＨＯＳＴ", "ａｐｐ.ｌｏｃａｌｈｏｓｔ", "Ａ.Ｂ.ＬＯＣＡＬＨＯＳＴ．",
            "ⓛⓞⓒⓐⓛⓗⓞⓢⓣ", "ℓocalhost", "１２７.０.０.１", "１２７.２５５.２.９", "０.０.０.０",
            "２１３０７０６４３３", "０１７７.０.０.１", "０ｘ７ｆ.１", "１２７.１", "０Ｘ７Ｆ０００００１", "¹²⁷.⁰.⁰.¹",
        ]
        for dot in ["\u{3002}", "\u{ff0e}", "\u{ff61}"] {
            hosts += ["app\(dot)localhost", "ａｐｐ\(dot)ｌｏｃａｌｈｏｓｔ", "localhost\(dot)", "127\(dot)0\(dot)0\(dot)1"]
        }
        for ignored in ["\u{00ad}", "\u{200b}", "\u{feff}", "\u{034f}"] {
            hosts += ["local\(ignored)host", "\(ignored)localhost", "127.0.\(ignored)0.1", "0.0.\(ignored)0.0",
                      "app.local\(ignored)host", "localhost.\(ignored)", "127.0.0.1\(ignored)."]
        }
        for host in hosts {
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://\(host):3000/ｘ?q=１２７#é"),
                           .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: "/ｘ?q=１２７#é"), host)
        }
    }

    func testLinkClassifierRefusesUnicodeLoopbackWhenStrictParsingFails() {
        var urls = [
            "http://ｖｉｅｗｅｒ@ｌｏｃａｌｈｏｓｔ:3000/", "http://viewer@１２７.０.０.１:3000/",
            "http://viewer@ａｐｐ。ｌｏｃａｌｈｏｓｔ:3000/", "http://viewer@２１３０７０６４３３:3000/",
            "http://ｌｏｃａｌｈｏｓｔ:0/", "http://１２７｡０｡０｡１:bad/", "http://ｌｏｃａｌｈｏｓｔ:3000/has space",
            "http://%EF%BD%8C%EF%BD%8F%EF%BD%83%EF%BD%81%EF%BD%8C%EF%BD%88%EF%BD%8F%EF%BD%93%EF%BD%94:3000/",
        ]
        for (ignored, encoded) in [("\u{00ad}", "%C2%AD"), ("\u{200b}", "%E2%80%8B"),
                                   ("\u{feff}", "%EF%BB%BF"), ("\u{034f}", "%CD%8F")] {
            for host in ["local\(ignored)host", "127.0.\(ignored)0.1", "app.local\(ignored)host."] {
                urls += ["http://viewer@\(host):3000/", "http://viewer%zz@\(host):3000/",
                         "http://\(host):0/", "http://\(host):bad/", "http://\(host):\(ignored)3000/",
                         "http:////\(host):3000/"]
            }
            urls += ["http://local\(encoded)host:3000/", "http://127.0.\(encoded)0.1:3000/",
                     "http://viewer@local\(encoded)host.:3000/", "http:local\(encoded)host:3000/"]
        }
        for url in urls {
            XCTAssertNil(ArtifactsHTTPURL.parse(url), url)
            XCTAssertEqual(ArtifactsLinkClassifier.classify(url), .refused, url)
        }
    }

    func testLinkClassifierKeepsRemoteUnicodeHostsExternal() {
        var urls = [
            "https://bücher.example/", "https://ＢÜＣＨＥＲ。example/", "http://viewer@bücher.example/",
            "http://ｌｏｃａｌｈｏｓｔ.example:3000/", "http://１２７.０.０.１.example:3000/",
            "https://e\u{034f}\u{0301}xample.com/",
        ]
        for (ignored, encoded) in [("\u{00ad}", "%C2%AD"), ("\u{200b}", "%E2%80%8B"),
                                   ("\u{feff}", "%EF%BB%BF"), ("\u{034f}", "%CD%8F")] {
            for host in ["exa\(ignored)mple.com", "local\(ignored)host.example", "128.0.\(ignored)0.1"] {
                urls += ["http://\(host):3000/", "http://viewer@\(host):3000/", "http:////\(host):3000/"]
            }
            urls += ["http://exa\(encoded)mple.com:3000/", "http://localhost@exa\(encoded)mple.com:3000/"]
        }
        for url in urls {
            XCTAssertEqual(ArtifactsLinkClassifier.classify(url), .external, url)
        }
    }

    func testHostMappingRemovesIgnorablesBeforeCompatibilityComposition() {
        XCTAssertEqual(Array(ArtifactsLinkClassifier.mappedHost("e\u{034f}\u{0301}xample").utf8), Array("éxample".utf8))
        XCTAssertEqual(Array(ArtifactsLinkClassifier.mappedHost("Ｅ\u{034f}\u{0301}xample").utf8), Array("éxample".utf8))
    }

    func testLinkClassifierKeepsInvalidUnicodeIPv6Unsupported() {
        for ignored in ["\u{00ad}", "\u{200b}", "\u{feff}", "\u{034f}"] {
            for url in ["http://[::\(ignored)1]:3000/", "http:////[::\(ignored)1]:3000/"] {
                XCTAssertNil(ArtifactsHTTPURL.parse(url), url)
                XCTAssertEqual(ArtifactsLinkClassifier.classify(url), .unsupported, url)
            }
        }
    }

    func testLinkClassifierCanonicalizesIPv4EmbeddedInIPv6WithoutDNS() {
        for host in ["::ffff:127.0.0.1", "::ffff:127.255.255.255", "::ffff:7f00:1", "::FFFF:7fff:ffff",
                     "0:0:0:0:0:ffff:7f14:1", "::127.0.0.1", "::127.255.1.2", "::7f00:1",
                     "0:0:0:0:0:0:7fff:ffff", "::ffff:0.0.0.0", "::ffff:0:0", "::0.0.0.0"] {
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://[\(host)]:3000/x?q#z"),
                           .remoteLoopback(scheme: "http", port: 3000, pathAndQuery: "/x?q#z"), host)
            XCTAssertTrue(ArtifactsLinkClassifier.isRemoteLoopback(host), host)
            XCTAssertTrue(ArtifactsLinkClassifier.isRemoteLoopback("[\(host)]"), host)
        }
        for host in ["::ffff:126.255.255.255", "::ffff:8000:1", "::128.0.0.1", "::8000:1",
                     "2001:db8::7f00:1", "2001:db8::127.0.0.1", "::fffe:7f00:1", "1::ffff:7f00:1"] {
            XCTAssertEqual(ArtifactsLinkClassifier.classify("https://[\(host)]/"), .external, host)
            XCTAssertFalse(ArtifactsLinkClassifier.isRemoteLoopback(host), host)
        }
        // A rule's target reaches sshd as written, without browser mapping.
        for host in ["local\u{00ad}host", "ｌｏｃａｌｈｏｓｔ", "１２７.０.０.１", "app\u{3002}localhost", "127.0.\u{200b}0.1"] {
            XCTAssertFalse(ArtifactsLinkClassifier.isRemoteLoopback(host), host)
        }
        for host in ["::ffff:127.0.0.256", "::ffff:127.0.1", "::ffff:127.00.0.1", "1::2:", ":1::2",
                     "0:0:0:0:0:0:0:0:1", "0:0:0:0:0:0:0::1", "1::2::3", "::ffff:7f000:1"] {
            XCTAssertEqual(ArtifactsLinkClassifier.classify("http://[\(host)]:3000/"), .unsupported, host)
            XCTAssertFalse(ArtifactsLinkClassifier.isRemoteLoopback(host), host)
        }
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "dev")], currentHostID: "h1", cwd: "/")
        for input in ["http://[::ffff:127.0.0.1]:3000/x", "[::ffff:7f00:1]:3000/x", "[::127.0.0.1]:3000/x"] {
            XCTAssertEqual(ArtifactsQuickOpen.parse(input, context: context), .page(hostID: "h1", scheme: "http", port: 3000, path: "/x"))
        }
    }

    func testCacheGoldenKeysAndFragmentNormalization() {
        let tab = open("a", .file(path: "/work//./a.md/"), now: 1).tabs[0]
        XCTAssertEqual(ArtifactsCachePolicy.cacheKey(tab), "4ff55b7ab0798970181029584209307390b258f33c4795c031e90add72a3c18f")
        var unicode = tab
        unicode.hostID = "host-α"
        unicode.target = .file(path: "/tmp/é.png")
        unicode.kind = .files
        XCTAssertEqual(ArtifactsCachePolicy.cacheKey(unicode), "89fd5d9b988cce7860b71117351fa848afb7275a8c4f2dfaf017847275658a47")
        var page = open("p", .page(scheme: "http", port: 5173, path: "/x?y#z"), now: 1).tabs[0]
        XCTAssertEqual(ArtifactsCachePolicy.cacheKey(page), "22d9c1bacc4abdc75394b929b95b5fdbb66dd88f1517c73f3e55869b4e6d2b8d")
        let key = ArtifactsCachePolicy.cacheKey(page)
        page.target = .page(scheme: "http", port: 5173, path: "/x?y#other")
        XCTAssertEqual(ArtifactsCachePolicy.cacheKey(page), key)
        XCTAssertEqual(ArtifactsDigest.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testCacheEvictionOrderAndProtectedFootprint() {
        let entries: [ArtifactsCacheEntry] = [
            .init(key: "p", size: 100, viewedAt: 0, pinned: true), .init(key: "s", size: 100, viewedAt: 0),
            .init(key: "b", size: 40, viewedAt: 1), .init(key: "a", size: 40, viewedAt: 1),
            .init(key: "c", size: 20, viewedAt: 2),
        ]
        XCTAssertEqual(ArtifactsCachePolicy.evictions(entries, budgetBytes: 240, protectedKeys: ["s"]), ["a", "b"])
        XCTAssertEqual(ArtifactsCachePolicy.evictions(entries, budgetBytes: 0, protectedKeys: ["s"]), ["a", "b", "c"])
        XCTAssertEqual(ArtifactsCachePolicy.evictions(entries, budgetBytes: 300, protectedKeys: []), [])
        let duplicated = [ArtifactsCacheEntry(key: "a", size: 10, viewedAt: 1), .init(key: "a", size: 10, viewedAt: 1, pinned: true)]
        XCTAssertEqual(ArtifactsCachePolicy.evictions(duplicated, budgetBytes: 0, protectedKeys: []), [])
    }

    func testCachePresentationMatrixNeverOffersOfflineRefresh() {
        var tab = open("a", .file(path: "/a.md"), now: 1).tabs[0]
        for connected in [false, true] {
            XCTAssertEqual(ArtifactsCachePolicy.presentation(tab, liveConnection: connected, nowMillis: 10).state,
                           connected ? .none : .offline)
        }
        for stale in [false, true] {
            tab.cache = .init(fetchedAt: 5, remoteMTime: 1, size: 10, isStale: stale)
            for connected in [false, true] {
                let result = ArtifactsCachePolicy.presentation(tab, liveConnection: connected, nowMillis: 10)
                XCTAssertEqual(result.state, stale ? .stale : (connected ? .live : .cached))
                XCTAssertEqual(result.canRefresh, connected)
                XCTAssertEqual(result.fetchedAt, 5)
            }
        }
        for target: ArtifactsTarget in [.file(path: "/a"), .page(scheme: "http", port: 80, path: "/"), .change(path: "/a", diff: "+x", summary: "edit")] {
            tab.target = target
            XCTAssertFalse(ArtifactsCachePolicy.presentation(tab, liveConnection: false, nowMillis: 10).canRefresh)
        }
    }

    func testPersistenceDropsMalformedTabsIgnoresFutureFieldsAndIsByteStable() throws {
        let valid = open("a", .file(path: "/a.md"), now: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ArtifactsPersistence.encode(valid)) as? [String: Any])
        var tabs = try XCTUnwrap(object["tabs"] as? [[String: Any]])
        tabs[0]["futureField"] = ["value": 1]
        object["tabs"] = [tabs[0], ["id": "bad"], "not a tab", NSNull()]
        object["futureField"] = true
        let decoded = ArtifactsPersistence.decode(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.tabs, valid.tabs)
        let encoded = ArtifactsPersistence.encode(decoded)
        XCTAssertEqual(ArtifactsPersistence.encode(ArtifactsPersistence.decode(encoded)), encoded)
        XCTAssertEqual(ArtifactsPersistence.decode(Data("not json".utf8)), .init())
        XCTAssertEqual(ArtifactsPersistence.decode(Data("{\"version\":2,\"tabs\":[]}".utf8)), .init())
    }

    func testPersistenceClampsTabsAndDiffAtUTF8Boundary() {
        var state = ArtifactsState(tabCap: 100)
        for i in 0..<100 {
            state.tabs.append(.init(id: "t\(i)", hostID: "h1", hostLabel: "dev", target: .file(path: "/\(i).md"),
                                    title: "\(i)", openedAt: Int64(i), viewedAt: Int64(i)))
        }
        state.selectedID = "t0"
        let decoded = ArtifactsPersistence.decode(ArtifactsPersistence.encode(state))
        XCTAssertEqual(decoded.tabs.count, 64)
        XCTAssertTrue(decoded.tabs.contains(where: { $0.id == "t0" }))
        let diff = String(repeating: "é", count: 140_000) + "tail"
        let change = open("change", .change(path: "/a", diff: diff, summary: "big"), now: 1)
        let restored = ArtifactsPersistence.decode(ArtifactsPersistence.encode(change))
        guard case let .change(_, capped, _) = restored.tabs[0].target else { return XCTFail() }
        XCTAssertLessThanOrEqual(capped.utf8.count, 256 * 1024)
        XCTAssertFalse(capped.contains("�"))
    }

    private func request(_ id: String, _ target: ArtifactsTarget, host: String = "h1", newTab: Bool = false) -> ArtifactsOpenRequest {
        .init(id: id, hostID: host, hostLabel: "dev", target: target, title: target.path, newTab: newTab)
    }

    private func reduce(_ state: ArtifactsState, _ action: ArtifactsAction) -> ArtifactsReduction {
        ArtifactsReducer.reduce(state, action)
    }

    private func open(_ id: String, _ target: ArtifactsTarget, now: Int64, state: ArtifactsState = .init()) -> ArtifactsState {
        reduce(state, .open(request(id, target), nowMillis: now)).state
    }
}
