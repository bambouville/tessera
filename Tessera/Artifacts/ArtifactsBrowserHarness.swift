#if DEBUG
import Foundation
import Observation
import SwiftUI
import TesseraArtifactsCore

/// TESSERA_ARTIFACTS_BROWSER_HARNESS=1, optionally with
/// TESSERA_ARTIFACTS_BROWSER_SCENE=live|cached|stale|offline|diff|served|
/// forwarded|laptop|laptop-overview|file|loading|missing|too-large|
/// no-forwarding|failed|empty|quick-open|switcher|links. The default is the grouped
/// overview. `laptop` opens web-2's localhost:8001 page, whose fake handler
/// serves any path; `laptop-overview` selects it but starts on the overview.
/// TESSERA_ARTIFACTS_BROWSER_FOLD=laptop lays a compact browser out as a
/// partially folded Duo would, with the fold at the middle of its height:
/// with no tab shown (the default, `empty` or `laptop-overview`), the title
/// and its open field stand above the fold.
@MainActor
struct ArtifactsBrowserHarnessView: View {
    @State private var store: ArtifactsBrowserPreviewStore
    private let scene: String

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TESSERA_ARTIFACTS_BROWSER_HARNESS"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-artifacts-browser-harness")
    }

    init() {
        let scene = ProcessInfo.processInfo.environment["TESSERA_ARTIFACTS_BROWSER_SCENE"] ?? "overview"
        self.scene = scene
        _store = State(initialValue: ArtifactsBrowserPreviewStore(scene: scene))
    }

    var body: some View {
        // A container, as ArtifactsRootView is: the identifier the app puts
        // on the harness must not replace its controls' own identifiers.
        content.accessibilityElement(children: .contain)
            .environment(\.openArtifact, OpenArtifactAction { [store] in store.open($0) })
    }

    @ViewBuilder
    private var content: some View {
        if ProcessInfo.processInfo.environment["TESSERA_ARTIFACTS_BROWSER_FOLD"] == "laptop" {
            GeometryReader { proxy in
                let fold = DuoFold(frame: CGRect(x: 0, y: proxy.size.height / 2 - 8, width: proxy.size.width, height: 16),
                                   splitsSideBySide: false)
                ArtifactsBrowserView(store: store, startsInQuickOpen: scene == "quick-open", startsInSwitcher: scene == "switcher",
                                     foldOverride: fold)
            }
        } else {
            ArtifactsBrowserView(store: store, startsInQuickOpen: scene == "quick-open", startsInSwitcher: scene == "switcher")
        }
    }
}

/// Uses the real reducer and overview/parser policy, local document copies,
/// and an in-memory SFTP reader. It never constructs a bridge or listener.
@MainActor @Observable
final class ArtifactsBrowserPreviewStore: ArtifactsBrowserStore {
    private(set) var state = ArtifactsState()
    private(set) var visibleTabID: String?
    var showsBrowserOverview = false
    private var contents: [String: ArtifactContent] = [:]
    private var registrations: [String: ArtifactWebSchemeRegistration] = [:]
    /// Served HTML's own file, as a cached root would be.
    private var servedFiles: [String: URL] = [:]
    private var closedTabs = PreviewClosedTabs()
    private var pageNavigations: [String: Int] = [:]
    /// Each refresh that reached the store, oldest first.
    private(set) var refreshedTabIDs: [String] = []

    func pageNavigation(for tabID: String) -> Int { pageNavigations[tabID] ?? 0 }

    private struct PreviewClosedTabs {
        struct Entry {
            let tab: ArtifactTab
            let content: ArtifactContent?
            let registration: ArtifactWebSchemeRegistration?
            let servedFile: URL?
        }
        private(set) var tabs: [Entry] = []
        mutating func push(_ entry: Entry) {
            tabs.append(entry)
            if tabs.count > ArtifactClosedTabStack.capacity { tabs.removeFirst() }
        }
        mutating func pop() -> Entry? { tabs.popLast() }
    }
    private let liveHostIDs: Set<String> = ["fixture-api", "fixture-build", "fixture-web"]

    let quickOpenHosts: [ArtifactsQuickOpenHost] = [
        .init(id: "fixture-api", label: "api-01", home: "/srv/tessera"),
        .init(id: "fixture-build", label: "build-box", home: "/work/android"),
        .init(id: "fixture-web", label: "web-2", home: "/sites/landing"),
        .init(id: "fixture-staging", label: "staging-db", home: "/srv/staging"),
    ]

    var selectedTab: ArtifactTab? { state.selectedID.flatMap { tab($0) } }
    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    init(scene: String = "overview") {
        seed()
        let tabID: String?
        switch scene {
        case "live", "quick-open", "switcher": tabID = "plan"
        case "cached": tabID = "cached"
        case "stale": tabID = "stale"
        case "offline": tabID = "offline"
        case "diff": tabID = "change"
        case "served": tabID = "report"
        case "forwarded": tabID = "dev-page"
        case "laptop": tabID = "laptop-page"
        case "laptop-overview": tabID = "laptop-page"; showsBrowserOverview = true
        case "file": tabID = "source"
        case "loading", "missing", "too-large", "no-forwarding", "failed": tabID = scene
        case "retry": seedRetryFixtures(); tabID = "failed-page"
        case "links": seedDocumentLinks(); tabID = "links-guide"
        case "empty": state = ArtifactsState(); tabID = nil
        default: tabID = nil
        }
        // Keep the stale/unseen fixture intact until the browser reports it
        // visible. Merely seeding a selected tab is not a user selection.
        state.selectedID = tabID
    }

    func tab(_ id: String) -> ArtifactTab? { state.tabs.first { $0.id == id } }
    func overview(query: String) -> ArtifactsOverview { .make(state, filter: state.filter, query: query) }
    func content(for tabID: String) -> ArtifactContent { contents[tabID] ?? .unavailable(.missing) }
    func isLive(hostID: String) -> Bool { liveHostIDs.contains(hostID) }
    func presentation(for tabID: String) -> ArtifactsCachePresentation {
        guard let tab = tab(tabID) else {
            let missing = ArtifactTab(id: tabID, hostID: "missing", hostLabel: "missing", target: .file(path: "/missing"),
                                      title: "missing", openedAt: now, viewedAt: now)
            return ArtifactsCachePolicy.presentation(missing, liveConnection: false, nowMillis: now)
        }
        var presentation = ArtifactsCachePolicy.presentation(tab, liveConnection: isLive(hostID: tab.hostID), nowMillis: now)
        // As in `ArtifactsStore`, only a forwarded page refreshes.
        if case .page = tab.target {
            if case .forwardedPage? = contents[tabID] {} else { presentation.canRefresh = false }
        }
        return presentation
    }
    func select(_ tabID: String) {
        showsBrowserOverview = false
        apply(.select(tabID: tabID, nowMillis: now))
    }
    func close(_ tabID: String) {
        if let tab = tab(tabID) { closedTabs.push(.init(tab: tab, content: contents[tabID], registration: registrations[tabID],
                                                           servedFile: servedFiles[tabID])) }
        apply(.close(tabID: tabID, nowMillis: now))
    }
    func closeAll(hostID: String) {
        for tab in state.tabs where tab.hostID == hostID {
            closedTabs.push(.init(tab: tab, content: contents[tab.id], registration: registrations[tab.id],
                                  servedFile: servedFiles[tab.id]))
        }
        apply(.closeAll(hostID: hostID, nowMillis: now))
    }
    func setPinned(_ tabID: String, _ pinned: Bool) { apply(.pin(tabID: tabID, pinned: pinned, nowMillis: now)) }
    func setFilter(_ filter: ArtifactsFilter) { apply(.setFilter(filter, nowMillis: now)) }
    func titleLearned(_ tabID: String, _ title: String) {
        guard tab(tabID)?.title != title else { return }
        apply(.titleLearned(tabID: tabID, title: title, nowMillis: now))
    }
    func refresh(_ tabID: String) {
        NSLog("artifacts-harness refresh %@", tabID)
        refreshedTabIDs.append(tabID)
        guard let tab = tab(tabID), isLive(hostID: tab.hostID), let cache = tab.cache else { return }
        apply(.fetched(tabID: tabID, cache: cache, nowMillis: now))
        if case let .some(.document(url, title, token, prepare)) = contents[tabID] {
            contents[tabID] = .document(localURL: url, title: title, reloadToken: token + 1, prepareImages: prepare)
        }
    }
    func noteVisible(_ tabID: String?) {
        visibleTabID = tabID
        if let index = state.tabs.firstIndex(where: { $0.id == tabID }), state.tabs[index].unseenChange {
            state.tabs[index].unseenChange = false
        }
    }
    func canKeepAsRule(_ tabID: String) -> Bool {
        if case let .some(.forwardedPage(_, _, ephemeral)) = contents[tabID] { return ephemeral }
        return false
    }
    func keepAsRule(_ tabID: String) {
        if case let .some(.forwardedPage(url, label, true)) = contents[tabID] {
            contents[tabID] = .forwardedPage(url: url, ruleLabel: label, isEphemeral: false)
        }
    }
    func registration(for tabID: String) -> ArtifactWebSchemeRegistration? { registrations[tabID] }

    func quickOpenSuggestions(_ input: String, currentHostID: String?) -> [ArtifactsSuggestion] {
        ArtifactsQuickOpen.suggestions(input, state: state, context: context(currentHostID), recents: [
            .init(title: "fixture.sql", subtitle: "build-box", intent: .file(hostID: "fixture-build", path: "/work/android/fixture.sql"),
                  viewedAt: now - 600_000),
        ])
    }

    func quickOpen(_ input: String, currentHostID: String?, placement: ArtifactOpenPlacement) async -> ArtifactQuickOpenOutcome {
        switch ArtifactsQuickOpen.parse(input, context: context(currentHostID)) {
        case let .directory(hostID, path): return .directory(hostID: hostID, path: path)
        case let .file(hostID, path):
            if path == "/srv/tessera/docs" { return .directory(hostID: hostID, path: path) }
            guard let seeded = state.tabs.first(where: { $0.hostID == hostID && $0.target == .file(path: path) }) else {
                return .failed(String(localized: "this path is not in the host-free fixture"))
            }
            let id = place(.init(id: UUID().uuidString, hostID: hostID, hostLabel: seeded.hostLabel,
                                 target: .file(path: path), title: seeded.title, newTab: true), placement: placement)
            contents[id] = contents[seeded.id]
            registrations[id] = registrations[seeded.id]
            servedFiles[id] = servedFiles[seeded.id]
            return .opened(tabID: id)
        case let .page(hostID, scheme, port, path):
            // Any path on a seeded port: one fake scheme handler serves it.
            guard let seeded = state.tabs.first(where: {
                guard $0.hostID == hostID, case let .page(s, p, _) = $0.target else { return false }
                return s == scheme && p == port && registrations[$0.id] != nil
            }), let registration = registrations[seeded.id] else {
                return .failed(String(localized: "this port is not in the host-free fixture"))
            }
            let id = place(.init(id: UUID().uuidString, hostID: hostID, hostLabel: seeded.hostLabel,
                                 target: .page(scheme: scheme, port: port, path: path), title: ":\(port)", newTab: true),
                           placement: placement)
            registrations[id] = registration
            if let handler = registration.handler as? ArtifactSchemeHandler,
               var components = URLComponents(url: handler.pageURL, resolvingAgainstBaseURL: false),
               let remote = URLComponents(string: "\(scheme)://localhost:\(port)\(path)") {
                components.percentEncodedPath = remote.percentEncodedPath
                components.percentEncodedQuery = remote.percentEncodedQuery
                components.percentEncodedFragment = remote.percentEncodedFragment
                if let url = components.url { contents[id] = .forwardedPage(url: url, ruleLabel: seeded.title, isEphemeral: true) }
            }
            return .opened(tabID: id)
        case let .search(text):
            if let id = overview(query: text).groups.first?.tabIDs.first { select(id); return .opened(tabID: id) }
            return .failed(String(localized: "no matching tabs"))
        case .invalid:
            return .failed(String(localized: "enter host:path, an absolute path, ~/file or :5173"))
        }
    }

    private func context(_ hostID: String?) -> ArtifactsQuickOpenContext {
        .init(hosts: quickOpenHosts, currentHostID: hostID,
              cwd: quickOpenHosts.first(where: { $0.id == hostID })?.home,
              listeningPorts: hostID == "fixture-web" ? [.init(port: 5_173, bindAddress: "127.0.0.1", process: "node")]
                  : hostID == "fixture-api" ? [.init(port: 3_000, bindAddress: "127.0.0.1", process: "python3")]
                  : [])
    }

    private func apply(_ action: ArtifactsAction) { state = ArtifactsReducer.reduce(state, action).state }

    /// The real reducer's placement: a new tab, or the edited tab itself
    /// when the address is on its host.
    private func place(_ request: ArtifactsOpenRequest, placement: ArtifactOpenPlacement) -> String {
        showsBrowserOverview = false
        if case let .navigate(tabID) = placement, let tab = tab(tabID), ArtifactsReducer.canNavigateInPlace(tab),
           tab.hostID == request.hostID {
            apply(.navigate(tabID: tabID, target: request.target, title: request.title, nowMillis: now))
            if case .page = request.target { pageNavigations[tabID, default: 0] &+= 1 }
            return tabID
        }
        apply(.open(request, nowMillis: now))
        return request.id
    }

    var canReopenClosedTab: Bool { !closedTabs.tabs.isEmpty }

    @discardableResult
    func reopenClosedTab() -> String? {
        guard let closed = closedTabs.pop() else { return nil }
        let id = UUID().uuidString
        apply(.open(.init(id: id, hostID: closed.tab.hostID, hostLabel: closed.tab.hostLabel, target: closed.tab.target,
                          title: closed.tab.title, origin: closed.tab.origin, newTab: true), nowMillis: now))
        contents[id] = closed.content
        registrations[id] = closed.registration
        servedFiles[id] = closed.servedFile
        showsBrowserOverview = false
        return id
    }

    func shareableFile(for tabID: String) -> ArtifactFileShare {
        guard let tab = tab(tabID), case .file = tab.target else { return .none }
        switch contents[tabID] {
        case let .document(url, _, _, _)?: return .ready(url)
        case .servedPage?: return servedFiles[tabID].map(ArtifactFileShare.ready) ?? .none
        case .loading?: return .unavailable(String(localized: "this file is still downloading"))
        case .unavailable(.tooLarge)?: return .unavailable(String(localized: "this file exceeds the 64 MiB preview limit"))
        default: return .unavailable(String(localized: "this file has not been downloaded yet"))
        }
    }

    /// The app root's open action, as `ArtifactsStore.open(_:)` makes it: an
    /// automatic open, which the real reducer points at a tab already on its
    /// target. Only a host with tabs here can open one.
    func open(_ request: ArtifactOpenRequest) {
        let hostID = request.hostID.uuidString
        guard let label = state.tabs.first(where: { $0.hostID == hostID })?.hostLabel else { return }
        let target: ArtifactsTarget
        let title: String
        switch request.target {
        case let .file(path): target = .file(path: path); title = (path as NSString).lastPathComponent
        case let .page(scheme, port, path):
            guard let port = UInt16(exactly: port) else { return }
            target = .page(scheme: scheme, port: port, path: path); title = ":\(port)"
        case let .change(path, diff, summary):
            target = .change(path: path, diff: diff, summary: summary); title = (path as NSString).lastPathComponent
        }
        showsBrowserOverview = false
        apply(.open(.init(id: UUID().uuidString, hostID: hostID, hostLabel: label, target: target, title: title,
                          origin: request.origin.rawValue), nowMillis: now))
    }

    /// A saved host's ID is a UUID, which the app's open action needs, so the
    /// links scene's host has one. Its guide links to a sibling, its parent's
    /// README, a dev server, an anchor and a script.
    static let linksHostID = "D0C5A11E-0000-4000-8000-00000000D0C5"

    private func seedDocumentLinks() {
        let timestamp = now
        let docs = [
            ("links-guide", "/srv/atlas/docs/guide.md", """
            # Guide

            Start with [setup](setup.md), then the [README](../README.md).

            The [dev server](http://localhost:3000/billing) runs on this host. [Phase 2](#phase-2) is below; [this script](javascript:alert(1)) never runs.

            ## Phase 2

            Ship it.
            """),
            ("links-setup", "/srv/atlas/docs/setup.md", "# Setup\n\nInstall the dependencies, then start the dev server.\n"),
            ("links-readme", "/srv/atlas/README.md", "# Atlas\n\nThe billing service.\n"),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-artifacts-links-" + UUID().uuidString,
                                                                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, (id, path, text)) in docs.enumerated() {
            let title = (path as NSString).lastPathComponent
            state.tabs.append(.init(id: id, hostID: Self.linksHostID, hostLabel: "docs-box", target: .file(path: path), title: title,
                                    origin: "files", openedAt: timestamp, viewedAt: timestamp - Int64(index) * 60_000,
                                    cache: .init(fetchedAt: timestamp, size: Int64(text.utf8.count))))
            let url = directory.appendingPathComponent(id + "-" + title)
            contents[id] = (try? Data(text.utf8).write(to: url, options: .atomic)) == nil
                ? .unavailable(.failed("the fixture could not be written"))
                : .document(localURL: url, title: title, reloadToken: 0, prepareImages: nil)
        }
        state.tabs.append(.init(id: "links-page", hostID: Self.linksHostID, hostLabel: "docs-box",
                                target: .page(scheme: "http", port: 3_000, path: "/"), title: "localhost:3000",
                                origin: "forwarding", openedAt: timestamp, viewedAt: timestamp - 240_000))
        seedPage(id: "links-page", path: "/billing", title: "billing · dev", forwarded: true)
    }

    /// A page whose forward failed on a live host, which only a retry can
    /// reload, and a failed file on a host with no live session.
    private func seedRetryFixtures() {
        let timestamp = now
        state.tabs.append(.init(id: "failed-page", hostID: "fixture-api", hostLabel: "api-01",
                                target: .page(scheme: "http", port: 5_174, path: "/"), title: "localhost:5174",
                                origin: "forwarding", openedAt: timestamp, viewedAt: timestamp))
        contents["failed-page"] = .unavailable(.failed("the forward to port 5174 was refused"))
        state.tabs.append(.init(id: "failed-offline", hostID: "fixture-staging", hostLabel: "staging-db",
                                target: .file(path: "/srv/staging/notes.md"), title: "notes.md",
                                origin: "files", openedAt: timestamp, viewedAt: timestamp))
        contents["failed-offline"] = .unavailable(.failed("permission denied by the host"))
    }

    private func seed() {
        let timestamp = now
        func add(_ id: String, host: String = "fixture-api", label: String = "api-01", target: ArtifactsTarget,
                 title: String, cache: ArtifactsCacheMetadata? = nil, unseen: Bool = false,
                 origin: String = "files", session: String? = nil) {
            state.tabs.append(.init(id: id, hostID: host, hostLabel: label, target: target, title: title,
                                    origin: origin, sessionHint: session, openedAt: timestamp - 3_600_000,
                                    viewedAt: timestamp - Int64(state.tabs.count) * 60_000,
                                    cache: cache, unseenChange: unseen))
        }
        add("plan", target: .file(path: "/srv/tessera/docs/PLAN.md"), title: "PLAN.md",
            cache: .init(fetchedAt: timestamp - 60_000, size: 1_200), session: "6F1D2C3B-4A59-4E8F-9B7A-1C2D3E4F5A6B")
        add("cached", host: "fixture-staging", label: "staging-db", target: .file(path: "/srv/staging/session-restore.md"),
            title: "session-restore.md", cache: .init(fetchedAt: timestamp - 720_000, size: 900))
        add("stale", target: .file(path: "/srv/tessera/docs/mosh-scrollback.md"), title: "mosh-scrollback.md",
            cache: .init(fetchedAt: timestamp - 300_000, size: 900, isStale: true), unseen: true,
            origin: "agentEdit", session: "0B9E7C42-5D31-4F6A-8E2B-7A1C9D3E5F04")
        add("offline", host: "fixture-staging", label: "staging-db", target: .file(path: "/srv/staging/README.md"), title: "README.md")
        let diff = "--- a/SessionRestoreCoordinator.swift\n+++ b/SessionRestoreCoordinator.swift\n@@ -41,3 +41,4 @@\n private let lockClock: AppLockClock\n-private var deadline: Date? { lockClock.deadline }\n+private let restoreClock: RestoreClock\n+private var deadline: Date? { restoreClock.deadline }\n \n"
        add("change", target: .change(path: "/srv/tessera/SessionRestoreCoordinator.swift", diff: diff, summary: "+2 −1"),
            title: "SessionRestoreCoordinator.swift", origin: "agentEdit", session: "6F1D2C3B-4A59-4E8F-9B7A-1C2D3E4F5A6B")
        contents["change"] = .change(path: "/srv/tessera/SessionRestoreCoordinator.swift", diff: diff)
        add("report", host: "fixture-build", label: "build-box", target: .file(path: "/reports/index.html"), title: "Test Summary")
        add("dev-page", host: "fixture-web", label: "web-2", target: .page(scheme: "http", port: 5_173, path: "/"),
            title: "landing · dev", origin: "terminalLink", session: "C4A8E1F2-3B6D-4E9A-A7C5-2D8F0B1E6A93")
        add("laptop-page", host: "fixture-web", label: "web-2", target: .page(scheme: "http", port: 8_001, path: "/"),
            title: "localhost:8001", origin: "terminalLink", session: "C4A8E1F2-3B6D-4E9A-A7C5-2D8F0B1E6A93")
        add("source", host: "fixture-build", label: "build-box", target: .file(path: "/work/android/fixture.sql"), title: "fixture.sql",
            cache: .init(fetchedAt: timestamp - 180_000, size: 500))
        add("loading", host: "fixture-build", label: "build-box", target: .file(path: "/work/android/loading.md"), title: "loading.md")
        contents["loading"] = .loading
        add("too-large", target: .file(path: "/srv/tessera/archive.zip"), title: "archive.zip")
        contents["too-large"] = .unavailable(.tooLarge(bytes: 200_000_000))
        add("missing", target: .file(path: "/srv/tessera/removed.md"), title: "removed.md")
        contents["missing"] = .unavailable(.missing)
        add("no-forwarding", target: .page(scheme: "http", port: 3_000, path: "/"), title: "localhost:3000", origin: "forwarding")
        contents["no-forwarding"] = .unavailable(.noForwarding)
        add("failed", target: .file(path: "/srv/tessera/private.txt"), title: "private.txt")
        contents["failed"] = .unavailable(.failed("permission denied by the host"))
        contents["offline"] = .unavailable(.offline)
        state.tabs[0].pinned = true

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-artifacts-preview-" + UUID().uuidString,
                                                                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let docs = [
                "plan": "# Session restore — plan\n\nthree phases, each independently testable\n\n## Phase 1 — verdict cache\n\nPersist the last verdict per session, then replay on wake.\n\n## Phase 2 — wake window\n\nRestore gets its own clock, `RestoreClock`, seeded when the app goes to the background.\n\n## Phase 3 — teardown\n\nRelease the transports marked stale, oldest first.\n",
                "cached": "# Session restore\n\nThis document is cached on this device. Its host has no live session.\n\n## Charged window\n\nA saved tab stays available after its session ends.\n",
                "stale": "# Mosh scrollback\n\nThe host has a newer version of this copy.\n\n## Side channel\n\nHistory comes from `capture-pane`, stitched above the live screen.\n",
                "source": "-- fixture for restore tests\nCREATE TABLE sessions (\n  id TEXT PRIMARY KEY,\n  host TEXT NOT NULL,\n  verdict TEXT\n);\n",
            ]
            for (id, text) in docs {
                let title = tab(id)?.title ?? id
                let url = directory.appendingPathComponent(title)
                try Data(text.utf8).write(to: url, options: .atomic)
                contents[id] = .document(localURL: url, title: title, reloadToken: 0, prepareImages: nil)
            }
        } catch {
            for id in ["plan", "cached", "stale", "source"] { contents[id] = .unavailable(.failed(error.localizedDescription)) }
        }
        seedPage(id: "report", path: "/reports/index.html", title: "Test Summary", forwarded: false)
        seedPage(id: "dev-page", path: "/dev/index.html", title: "landing · dev", forwarded: true)
        seedPage(id: "laptop-page", path: "/index.html", title: "localhost:8001", forwarded: true)
        let report = directory.appendingPathComponent("index.html")
        if (try? Data("<!doctype html><title>Test Summary</title>".utf8).write(to: report, options: .atomic)) != nil {
            servedFiles["report"] = report
        }
    }

    private func seedPage(id: String, path: String, title: String, forwarded: Bool) {
        do {
            let reader = ArtifactsPreviewReader(title: title)
            let handler = try ArtifactSchemeHandler(tabID: id, pagePath: path, reader: reader)
            let registration = ArtifactWebSchemeRegistration(scheme: ArtifactSchemeHandler.scheme, handler: handler)
            registrations[id] = registration
            // The forwarded-content branch uses the fake scheme too. No
            // loopback socket is opened by the fixture's WKWebView.
            contents[id] = forwarded ? .forwardedPage(url: handler.pageURL, ruleLabel: title, isEphemeral: true)
                : .servedPage(url: handler.pageURL, registration: registration)
        } catch { contents[id] = .unavailable(.failed(error.localizedDescription)) }
    }
}

private struct ArtifactsPreviewReader: ArtifactRemoteReader {
    let title: String

    func read(absolutePath: String, allowedRoot: String?, maxBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        let next = absolutePath.hasSuffix("next.html")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(title)</title>
        <style>body{font:14px ui-monospace,monospace;line-height:1.7;margin:0;padding:28px;color:CanvasText;background:Canvas}
        h1{font-size:28px;font-weight:500}small{color:GrayText}a{color:inherit}td,th{text-align:left;padding:12px;border-bottom:1px solid GrayText}
        table{border-collapse:collapse;width:100%}</style></head><body>
        <small>\(next ? "details" : "host-free preview")</small><h1>\(title)</h1><p>\(absolutePath)</p>
        <p>248 tests · 0 failures · 12.41 seconds</p><table><tr><th>package</th><th>tests</th></tr>
        <tr><td>session</td><td>85</td></tr><tr><td>terminal</td><td>64</td></tr><tr><td>files</td><td>58</td></tr></table>
        <p><a href="\(next ? "index.html" : "next.html")">\(next ? "back to summary" : "view details")</a></p>
        <p><label>filter <input placeholder="keyboard safe area"></label></p>
        </body></html>
        """
        let data = Data(html.utf8)
        guard data.count <= maxBytes else { throw ArtifactRemoteReadError.fileTooLarge(maxBytes: maxBytes) }
        return data
    }
}
#endif
