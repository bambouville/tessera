import Foundation
import Observation
import SwiftUI
import Testing
import TesseraArtifactsCore
@testable import Tessera

struct ArtifactsBrowserPresentationTests {
    @Test @MainActor func railChromeKeepsContentInOneUnconditionalModifierChain() {
        let structure = String(reflecting: ArtifactsRailChrome.Body.self)
        let outerType = structure.split(separator: "<", maxSplits: 1).first
        #expect(outerType?.hasSuffix(".ModifiedContent") == true)
    }

    @Test func glyphsDistinguishServedPagesPortsAndFileViewers() {
        let cases: [(ArtifactsTarget, String)] = [
            (.file(path: "/docs/README.md"), "doc.text"),
            (.file(path: "/docs/notes.txt"), "doc.text"),
            (.file(path: "/dist/index.html"), "doc.richtext"),
            (.page(scheme: "http", port: 5_173, path: "/"), "globe"),
            (.change(path: "/src/main.swift", diff: "+one", summary: "+1"), "plus.forwardslash.minus"),
            (.file(path: "/images/report.png"), "photo"),
            (.file(path: "/reports/export.pdf"), "doc.richtext"),
            (.file(path: "/src/main.swift"), "chevron.left.forwardslash.chevron.right"),
            (.file(path: "/archives/data.bin"), "doc"),
        ]
        for (target, symbol) in cases {
            #expect(ArtifactsBrowserPresentation.kindSymbol(tab(target: target)) == symbol)
        }
    }

    @Test func filterCountsIncludeOtherKindsBeforeApplyingTheSelectedFilter() {
        let state = ArtifactsState(tabs: [
            tab(id: "doc", target: .file(path: "/docs/plan.md")),
            tab(id: "page", target: .page(scheme: "http", port: 3_000, path: "/")),
            tab(id: "file", target: .file(path: "/logs/run.json")),
        ], filter: .docs)
        let overview = ArtifactsOverview.make(state, filter: .docs, query: "")
        #expect(ArtifactsBrowserPresentation.count(.all, in: overview) == 3)
        #expect(ArtifactsBrowserPresentation.count(.docs, in: overview) == 1)
        #expect(ArtifactsBrowserPresentation.count(.pages, in: overview) == 1)
        #expect(ArtifactsBrowserPresentation.count(.changes, in: overview) == 0)
        #expect(ArtifactsBrowserPresentation.count(.files, in: overview) == 1)
    }

    @Test func badgeSeparatesLiveCachedStaleOfflineAndNoBadge() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let plain = tab()
        #expect(ArtifactsBrowserPresentation.badge(presentation(plain, live: true), now: now) == nil)
        let offline = try #require(ArtifactsBrowserPresentation.badge(presentation(plain, live: false), now: now))
        #expect(offline.text == "offline")
        #expect(offline.symbol == "bolt.slash")

        var cached = plain
        cached.cache = .init(fetchedAt: 9_700_000, size: 42)
        let live = try #require(ArtifactsBrowserPresentation.badge(presentation(cached, live: true), now: now))
        #expect(live.text == "live")
        #expect(live.accessibilityLabel != live.text)
        let saved = try #require(ArtifactsBrowserPresentation.badge(presentation(cached, live: false), now: now))
        #expect(saved.text.hasPrefix("cached "))
        #expect(saved.symbol == "clock")

        cached.cache?.isStale = true
        let stale = try #require(ArtifactsBrowserPresentation.badge(presentation(cached, live: false), now: now))
        #expect(stale.text == "stale")
        #expect(stale.symbol != offline.symbol)
        #expect(stale.accessibilityLabel != stale.text)
    }

    @Test func cachedBadgeClampsFutureTimestampsAndShowsRelativeAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        var current = tab()
        current.cache = .init(fetchedAt: 10_000_000, size: 42)
        var future = current
        future.cache?.fetchedAt = 10_600_000
        var earlier = current
        earlier.cache?.fetchedAt = 9_400_000
        let currentBadge = ArtifactsBrowserPresentation.badge(presentation(current, live: false), now: now)
        #expect(currentBadge == ArtifactsBrowserPresentation.badge(presentation(future, live: false), now: now))
        #expect(currentBadge != ArtifactsBrowserPresentation.badge(presentation(earlier, live: false), now: now))
    }

    @Test func pageAddressUsesRemotePortAndCurrentNavigationPath() {
        let page = tab(target: .page(scheme: "http", port: 5_173, path: "/initial?x=1#top"))
        #expect(ArtifactsBrowserPresentation.location(page) == ":5173/initial?x=1#top")
        #expect(ArtifactsBrowserPresentation.location(page, webURL: URL(string: "http://127.0.0.1:60912/new%20page?q=a%2Fb#details"))
                == ":5173/new%20page?q=a%2Fb#details")
        #expect(ArtifactsBrowserPresentation.copyValue(page) == "http://localhost:5173/initial?x=1#top")
        #expect(ArtifactsBrowserPresentation.copyValue(page, webURL: URL(string: "http://127.0.0.1:60912/new?q=1#part"))
                == "http://localhost:5173/new?q=1#part")
        #expect(ArtifactsBrowserPresentation.shareValue(page) == "api-01: http://localhost:5173/initial?x=1#top")
        let file = tab(target: .file(path: "/docs/a b.md"))
        #expect(ArtifactsBrowserPresentation.copyValue(file) == "/docs/a b.md")
        #expect(ArtifactsBrowserPresentation.shareValue(file) == "api-01:/docs/a b.md")
    }

    @Test func provenanceNamesTheOriginWithoutLeakingSessionIDsOrUnknownOrigins() {
        var file = tab()
        file.origin = "files"
        file.sessionHint = "A3642CC6-13F5-4C74-8DAE-A8FE079F0AE6"
        #expect(ArtifactsBrowserPresentation.openedFrom(file) == "opened from Files")
        file.sessionHint = nil
        #expect(ArtifactsBrowserPresentation.openedFrom(file) == "opened from Files")
        file.origin = "aFutureSource"
        #expect(ArtifactsBrowserPresentation.openedFrom(file) == nil)
    }

    @Test func keyboardTraversalFollowsTheRenderedSuggestionGroups() {
        let values: [ArtifactsSuggestion] = [
            suggestion(.recent, title: "recent"), suggestion(.openTab, title: "first tab"),
            suggestion(.listeningPort, title: "port"), suggestion(.hostPrefix, title: "host"),
            suggestion(.openTab, title: "second tab"), suggestion(.activeForward, title: "forward"),
        ]
        let grouped = ArtifactsBrowserPresentation.groupedSuggestions(values)
        #expect(grouped.map(\.title) == ["host", "forward", "first tab", "second tab", "port", "recent"])
        #expect(ArtifactsBrowserPresentation.suggestionHeading(grouped[1].kind) == "active tunnels")
        #expect(ArtifactsBrowserPresentation.suggestionHeading(grouped[2].kind) == "open tabs")
        #expect(ArtifactsBrowserPresentation.suggestionHeading(grouped[4].kind) == "listening ports")
    }

    @Test @MainActor func quickOpenRendersAndKeyboardReadsReuseOneSearchPerInput() {
        let source = QuickOpenSuggestionTestSource()
        let snapshot = ArtifactsQuickOpenSuggestionSnapshot()
        func update(_ input: String, hostID: String? = "host") {
            let key = ArtifactsQuickOpenSuggestionKey(input: input, currentHostID: hostID,
                storeID: ObjectIdentifier(source), revision: snapshot.revision)
            snapshot.update(key) { source.suggestions(input, hostID: hostID) }
        }

        for (offset, input) in ["", "?r", "?re", "?resume"].enumerated() {
            update(input)
            let expected = snapshot.suggestions
            for _ in 0..<46 {
                update(input)
                let values = snapshot.suggestions
                let indices = ArtifactsBrowserPresentation.suggestionKinds.flatMap { kind in
                    values.indices.filter { values[$0].kind == kind }
                }
                #expect(indices.map { values[$0] } == expected)
                #expect(ArtifactsBrowserPresentation.nextSuggestionIndex(current: nil, count: values.count, offset: 1) == 0)
            }
            #expect(source.calls == offset + 1)
        }
        update("?resume", hostID: nil)
        #expect(source.calls == 5)
        snapshot.stopObserving()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func quickOpenObservesPortAndRecentChangesEvenWhenTabsDoNotChange() async {
        let source = QuickOpenSuggestionTestSource()
        let snapshot = ArtifactsQuickOpenSuggestionSnapshot()
        func update(_ input: String) {
            let key = ArtifactsQuickOpenSuggestionKey(input: input, currentHostID: "host",
                storeID: ObjectIdentifier(source), revision: snapshot.revision)
            snapshot.update(key) { source.suggestions(input, hostID: "host") }
        }
        update(":5")
        #expect(source.calls == 1)
        #expect(snapshot.suggestions.isEmpty)
        let originalTabs = source.state.tabs
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = snapshot.revision } onChange: { continuation.resume() }
            source.ports = [.init(port: 5_173, bindAddress: "127.0.0.1", process: "node")]
        }
        update(":5")
        #expect(source.calls == 2)
        #expect(snapshot.suggestions.map(\.title) == ["localhost:5173"])
        #expect(source.state.tabs == originalTabs)

        update("?recent")
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = snapshot.revision } onChange: { continuation.resume() }
            source.recents = [.init(title: "recent", subtitle: "host", intent: .file(hostID: "host", path: "/recent"), viewedAt: 1)]
        }
        update("?recent")
        #expect(source.calls == 4)
        #expect(snapshot.suggestions.map(\.kind) == [.recent])
        snapshot.stopObserving()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func quickOpenStoreUpdateReevaluatesOnceAndIgnoresRetiredObservations() async {
        let source = QuickOpenSuggestionTestSource()
        let snapshot = ArtifactsQuickOpenSuggestionSnapshot()
        func update() {
            snapshot.update(.init(input: "?resume", currentHostID: "host", storeID: ObjectIdentifier(source),
                                  revision: snapshot.revision)) { source.suggestions("?resume", hostID: "host") }
        }
        update()
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = snapshot.revision } onChange: { continuation.resume() }
            source.state.tabs[0].title = "renamed"
            source.state.tabs[1].viewedAt = 100
        }
        for _ in 0..<46 { update() }
        #expect(source.calls == 2)
        #expect(snapshot.suggestions.first?.tabID == "tab-1")
        #expect(!snapshot.suggestions.contains { $0.tabID == "tab-0" })

        source.state.tabs[1].title = "another rename"
        snapshot.stopObserving()
        let revision = snapshot.revision
        // The new observation also provides an actor turn for a queued old
        // invalidation; only this observation may increment the revision.
        update()
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = snapshot.revision } onChange: { continuation.resume() }
            source.recents = [.init(title: "resume recent", subtitle: "host",
                intent: .file(hostID: "host", path: "/recent"), viewedAt: 1)]
        }
        #expect(snapshot.revision == revision + 1)
        update()
        #expect(source.calls == 4)
        snapshot.stopObserving()
    }

    @Test func arrowsStartAtTheCorrectEndWrapAndHandleAnEmptyList() {
        #expect(ArtifactsBrowserPresentation.nextSuggestionIndex(current: nil, count: 4, offset: 1) == 0)
        #expect(ArtifactsBrowserPresentation.nextSuggestionIndex(current: nil, count: 4, offset: -1) == 3)
        #expect(ArtifactsBrowserPresentation.nextSuggestionIndex(current: 0, count: 4, offset: -1) == 3)
        #expect(ArtifactsBrowserPresentation.nextSuggestionIndex(current: 3, count: 4, offset: 1) == 0)
        #expect(ArtifactsBrowserPresentation.nextSuggestionIndex(current: 9, count: 2, offset: 1) == 0)
        #expect(ArtifactsBrowserPresentation.nextSuggestionIndex(current: 0, count: 0, offset: 1) == nil)
    }

    @Test func changeSuggestionsSelectTheSnapshotAndPagePathsStillNavigate() {
        let change = tab(target: .change(path: "/src/main.swift", diff: "+snapshot", summary: "+1"))
        let snapshot = ArtifactsSuggestion(kind: .openTab, title: "edit", subtitle: "",
                                          intent: .file(hostID: "host", path: "/src/main.swift"), tabID: "tab")
        #expect(ArtifactsBrowserPresentation.canSelectSuggestion(snapshot, tab: change))
        let page = tab(target: .page(scheme: "http", port: 5_173, path: "/"))
        var link = ArtifactsSuggestion(kind: .openTab, title: "page", subtitle: "",
                                      intent: .page(hostID: "host", scheme: "http", port: 5_173, path: "/"), tabID: "tab")
        #expect(ArtifactsBrowserPresentation.canSelectSuggestion(link, tab: page))
        link.intent = .page(hostID: "host", scheme: "http", port: 5_173, path: "/new?q=1#part")
        #expect(!ArtifactsBrowserPresentation.canSelectSuggestion(link, tab: page))
        link.intent = .page(hostID: "another-host", scheme: "http", port: 5_173, path: "/")
        #expect(!ArtifactsBrowserPresentation.canSelectSuggestion(link, tab: page))
    }

    @Test func suggestionsPreserveHostDirectoryAndPageSuffixes() throws {
        let directory = try #require(ArtifactsBrowserPresentation.suggestionInput(.directory(hostID: "host", path: "/docs")))
        #expect(directory.input == "/docs/")
        #expect(directory.hostID == "host")
        let page = try #require(ArtifactsBrowserPresentation.suggestionInput(
            .page(hostID: "other", scheme: "https", port: 8_443, path: "/app?q=a%2Fb#x")))
        #expect(page.input == "https://localhost:8443/app?q=a%2Fb#x")
        #expect(page.hostID == "other")
        #expect(ArtifactsBrowserPresentation.suggestionInput(.invalid(reason: .missingHost)) == nil)
    }

    @Test func hostPrefixSubmissionKeepsTheTypedRequestForCurrentCwdResolution() throws {
        let cached = ArtifactsSuggestion(kind: .hostPrefix, title: "dev:report.md", subtitle: "dev",
            intent: .file(hostID: "host", path: "/a/report.md"))
        let submission = try #require(ArtifactsBrowserPresentation.suggestionInput(
            cached, input: "dev:report.md", currentHostID: "host"))
        #expect(submission.input == "dev:report.md")
        #expect(submission.hostID == "host")
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "host", label: "dev")], currentHostID: "host", cwd: "/b")
        #expect(ArtifactsQuickOpen.parse(submission.input, context: context) == .file(hostID: "host", path: "/b/report.md"))

        var recent = cached
        recent.kind = .recent
        let recentSubmission = try #require(ArtifactsBrowserPresentation.suggestionInput(
            recent, input: "?report", currentHostID: "elsewhere"))
        #expect(recentSubmission.input == "/a/report.md")
        #expect(recentSubmission.hostID == "host")
    }

    @Test func adjacentTabsFollowTheStripAndWrapAfterTheLastTab() {
        let tabs = [tab(id: "a"), tab(id: "b"), tab(id: "c")]
        #expect(ArtifactsBrowserPresentation.adjacentTabID(tabs: tabs, selectedID: "a", offset: -1) == "c")
        #expect(ArtifactsBrowserPresentation.adjacentTabID(tabs: tabs, selectedID: "c", offset: 1) == "a")
        #expect(ArtifactsBrowserPresentation.adjacentTabID(tabs: tabs, selectedID: "a", offset: 1) == "b")
        #expect(ArtifactsBrowserPresentation.adjacentTabID(tabs: tabs, selectedID: "closed", offset: 1) == "a")
        #expect(ArtifactsBrowserPresentation.adjacentTabID(tabs: [], selectedID: nil, offset: 1) == nil)
    }

    /// With or without a tab on top: with none, the title and its open
    /// field stand above the fold, and the overview still lies on the desk.
    @Test func theFoldSplitsTheBrowserFromTheOverviewOnlyInLaptopPose() {
        let laptop = DuoFold(frame: CGRect(x: 0, y: 455, width: 669, height: 40), splitsSideBySide: false)
        let book = DuoFold(frame: CGRect(x: 455, y: 0, width: 40, height: 669), splitsSideBySide: true)
        #expect(ArtifactsBrowserPresentation.splitsAtTheFold(laptop, railMode: false))
        #expect(!ArtifactsBrowserPresentation.splitsAtTheFold(laptop, railMode: true))
        #expect(!ArtifactsBrowserPresentation.splitsAtTheFold(book, railMode: false))
        #expect(!ArtifactsBrowserPresentation.splitsAtTheFold(nil, railMode: false))
    }

    /// No sheet crosses the hinge: laptop pose types a new tab in place and
    /// has its overview on the desk, where a phone opens sheets for both.
    @Test func laptopPoseTypesANewTabAboveTheFoldInsteadOfInASheet() {
        #expect(ArtifactsBrowserPresentation.presentsSheets(compact: true, splitsAtTheFold: false))
        #expect(!ArtifactsBrowserPresentation.presentsSheets(compact: true, splitsAtTheFold: true))
        #expect(!ArtifactsBrowserPresentation.presentsSheets(compact: false, splitsAtTheFold: false),
                "wider layouts type in the toolbar")

        #expect(ArtifactsBrowserPresentation.tabBarShowsEdit(.navigate(tabID: "a"), tabID: "a", splitsAtTheFold: false))
        #expect(ArtifactsBrowserPresentation.tabBarShowsEdit(.navigate(tabID: "a"), tabID: "a", splitsAtTheFold: true))
        #expect(!ArtifactsBrowserPresentation.tabBarShowsEdit(.navigate(tabID: "b"), tabID: "a", splitsAtTheFold: true),
                "another tab's address is not this bar's")
        #expect(!ArtifactsBrowserPresentation.tabBarShowsEdit(.newTab, tabID: "a", splitsAtTheFold: false),
                "a phone's new tab types in its sheet")
        #expect(ArtifactsBrowserPresentation.tabBarShowsEdit(.newTab, tabID: "a", splitsAtTheFold: true),
                "laptop pose types a new tab in the bar of the tab on top")
    }

    /// The tab ends at the fold's top, where the keyboard begins, and the
    /// overview starts at its bottom; neither crosses the hinge.
    @Test @MainActor func theFoldLayoutStandsTheTabUpAndLaysTheOverviewOnTheDesk() throws {
        let fold = DuoFold(frame: CGRect(x: 0, y: 455, width: 669, height: 40), splitsSideBySide: false)
        let tab = FoldProbe(), desk = FoldProbe()
        let controller = UIHostingController(rootView: ArtifactsFoldLayout(fold: fold) {
            FoldSurface(probe: tab)
            FoldSurface(probe: desk)
        }.ignoresSafeArea())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
        let tabView = try #require(tab.view), deskView = try #require(desk.view)
        #expect(tabView.convert(tabView.bounds, to: controller.view) == CGRect(x: 0, y: 0, width: 669, height: 455))
        #expect(deskView.convert(deskView.bounds, to: controller.view) == CGRect(x: 0, y: 495, width: 669, height: 456))
    }

    private func tab(id: String = "tab", target: ArtifactsTarget = .file(path: "/docs/README.md")) -> ArtifactTab {
        .init(id: id, hostID: "host", hostLabel: "api-01", target: target, title: "README.md", openedAt: 1, viewedAt: 1)
    }

    private func presentation(_ tab: ArtifactTab, live: Bool) -> ArtifactsCachePresentation {
        ArtifactsCachePolicy.presentation(tab, liveConnection: live, nowMillis: 10_000_000)
    }

    private func suggestion(_ kind: ArtifactsSuggestionKind, title: String) -> ArtifactsSuggestion {
        .init(kind: kind, title: title, subtitle: "", intent: .file(hostID: "host", path: "/docs/" + title))
    }
}

private final class FoldProbe {
    weak var view: UIView?
}

private struct FoldSurface: UIViewRepresentable {
    let probe: FoldProbe
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        probe.view = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor @Observable
private final class QuickOpenSuggestionTestSource {
    var state = ArtifactsState(tabs: (0..<64).map { index in
        ArtifactTab(id: "tab-\(index)", hostID: "host", hostLabel: "api-01",
            target: .file(path: "/docs/" + String(repeating: "x", count: 1_024) + "/\(index).md"),
            title: "Résumé \(index)", openedAt: Int64(index), viewedAt: Int64(index))
    })
    var ports: [ArtifactsListeningPort] = []
    var recents: [ArtifactsRecent] = []
    @ObservationIgnored var calls = 0

    func suggestions(_ input: String, hostID: String?) -> [ArtifactsSuggestion] {
        calls += 1
        return ArtifactsQuickOpen.suggestions(input, state: state,
            context: .init(hosts: [.init(id: "host", label: "api-01", home: "/docs")],
                           currentHostID: hostID, cwd: "/docs", listeningPorts: ports), recents: recents)
    }
}
