import Combine
import Foundation
import Observation
import PortForwarding
import TesseraArtifactsCore
import UIKit

enum ArtifactContent {
    case loading
    case document(localURL: URL, title: String, reloadToken: Int,
                  prepareImages: ArtifactImagePreparation?)
    case servedPage(url: URL, registration: ArtifactWebSchemeRegistration)
    case forwardedPage(url: URL, ruleLabel: String, isEphemeral: Bool)
    case change(path: String, diff: String)
    case unavailable(ArtifactUnavailable)
}

struct ArtifactImagePreparation {
    let generation: Int
    let prepare: @MainActor () async throws -> Void

    @MainActor
    func callAsFunction() async throws { try await prepare() }
}

enum ArtifactUnavailable: Equatable {
    case offline
    case noForwarding
    case tooLarge(bytes: Int64)
    case missing
    case failed(String)
}

enum ArtifactQuickOpenOutcome: Equatable {
    case opened(tabID: String)
    case directory(hostID: String, path: String)
    case failed(String)
}

struct ArtifactsHostDirectoryEntry: Equatable {
    let id: UUID
    let label: String
    var rules: [PortForwardRule] = []
}

@MainActor
@Observable
final class ArtifactsStore {
    private struct ImageConnectionIdentity: Equatable {
        let bridgeID: ObjectIdentifier
        let generation: Int
    }

    private struct ImageAttempt: Equatable {
        let reloadToken: Int
        let generation: Int
        let epoch: Int
    }

    private(set) var state: ArtifactsState

    @ObservationIgnored private let stateFile: ArtifactsStateFile
    @ObservationIgnored private let loader: ArtifactContentLoader
    @ObservationIgnored private let follower: ArtifactFollower
    @ObservationIgnored private let cacheBudgetBytes: Int64
    @ObservationIgnored private let now: () -> Int64
    @ObservationIgnored private var bridgeProvider: @MainActor () -> [any FileBridging]
    @ObservationIgnored private let sessionState: @MainActor (LiveSession) -> SessionState
    @ObservationIgnored private var sessions: [LiveSession] = []
    /// The bridge a session's own Files panel would open, shared per host.
    @ObservationIgnored private var filesBridge: @MainActor (LiveSession) -> (any FileBridging)?
    private var connectingFiles: Set<String> = []
    private var filesConnectFailures: [String: String] = [:]
    @ObservationIgnored private var subscriptions: [AnyCancellable] = []
    @ObservationIgnored private var protectedDataSubscription: AnyCancellable?
    @ObservationIgnored private var keepRule: ((UUID, PortForwardRule) throws -> Void)?
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadIDs: [String: UUID] = [:]
    @ObservationIgnored private var documentRefreshIDs: [String: UUID] = [:]
    @ObservationIgnored private var imageRefreshIDs: [String: UUID] = [:]
    /// Each host connection, and each return to the foreground while one is
    /// up, is one opportunity to stage a host's images. Epochs only increase.
    @ObservationIgnored private var imageEpochs: [String: Int] = [:]
    @ObservationIgnored private var imageEpochClock = 0
    @ObservationIgnored private var imageEpochBridgeIDs: [String: ImageConnectionIdentity] = [:]
    /// The newest opportunity a tab's images were staged for or offered.
    @ObservationIgnored private var imageSpentEpochs: [String: Int] = [:]
    /// The last staging that fell short. Remounting the same document and
    /// generation on that connection does no remote work.
    @ObservationIgnored private var imageShortfalls: [String: ImageAttempt] = [:]
    /// Markdown tabs whose last staging fell short: a transient failure, a
    /// dropped connection or none at all. The next connection retries once.
    @ObservationIgnored private var imageRetryIDs: Set<String> = []
    /// Markdown tabs whose current document finished staging in this process.
    @ObservationIgnored private var imagesStagedIDs: Set<String> = []
    @ObservationIgnored private var fencedCacheKeys: Set<String> = []
    @ObservationIgnored private var deferredCacheRemovals: [String: ArtifactTab] = [:]
    @ObservationIgnored private var evictionTask: Task<Void, Never>?
    @ObservationIgnored private var evictionPending = false
    @ObservationIgnored private var portProbeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var portProbeIDs: [String: UUID] = [:]
    @ObservationIgnored private var portProbeDates: [String: Int64] = [:]
    @ObservationIgnored private var hostDirectoryLoaded = false
    private var hosts: [String: ArtifactsHostDirectoryEntry] = [:]
    private var listeningPorts: [String: [ArtifactsListeningPort]] = [:]
    private var recents: [ArtifactsRecent] = []
    private var sourceRevision = 0
    private var loadingIDs: Set<String> = []
    private var failures: [String: ArtifactUnavailable] = [:]
    private var reloadTokens: [String: Int] = [:]
    /// Address submissions that sent a page tab somewhere (`pageNavigation`).
    private var pageNavigations: [String: Int] = [:]
    private var imageGenerations: [String: Int] = [:]
    private var servedPages: [String: ArtifactSchemeHandler] = [:]
    private var servedBridgeIDs: [String: ObjectIdentifier] = [:]
    private let pages: ArtifactPageForwarder
    /// Closed tabs for ⌘⇧T, newest last. In memory for the process only.
    @ObservationIgnored private var closedTabs = ArtifactClosedTabStack()
    private(set) var visibleTabID: String?
    @ObservationIgnored private var overviewIDs: Set<UUID> = []
    @ObservationIgnored private var overviewSweepTask: Task<Void, Never>?
    @ObservationIgnored private var overviewSweepBridges: [String: (bridge: any FileBridging, generation: Int)] = [:]
    /// Attempt order keeps a busy or failing file from starving older tabs.
    @ObservationIgnored private var overviewPollOrder: [String: UInt64] = [:]
    @ObservationIgnored private var overviewPollSequence: UInt64 = 0
    @ObservationIgnored private let overviewSleep: @Sendable (UInt64) async throws -> Void
    /// The browser's overview-or-tab route, held in memory for the process.
    /// The tab itself is the persisted selection. Opening or selecting a tab
    /// shows it again; a tab merely becoming visible does not.
    var showsBrowserOverview = false
    private var isForeground = true

    init(
        stateFile: ArtifactsStateFile? = nil,
        loader: ArtifactContentLoader? = nil,
        follower: ArtifactFollower? = nil,
        pageForwarder: ArtifactPageForwarder? = nil,
        cacheBudgetBytes: Int64 = ArtifactContentLoader.cacheBudgetBytes,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        bridgeProvider: @escaping @MainActor () -> [any FileBridging] = { [] },
        filesBridge: @escaping @MainActor (LiveSession) -> (any FileBridging)? = { _ in nil },
        sessionState: @escaping @MainActor (LiveSession) -> SessionState = { $0.session.terminalSession.state },
        overviewSleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        let file = stateFile ?? ArtifactsStateFile()
        self.stateFile = file
        self.loader = loader ?? ArtifactContentLoader(cacheDirectory: file.cacheDirectory)
        self.follower = follower ?? ArtifactFollower()
        self.pages = pageForwarder ?? ArtifactPageForwarder()
        self.cacheBudgetBytes = cacheBudgetBytes
        self.now = now
        self.bridgeProvider = bridgeProvider
        self.filesBridge = filesBridge
        self.sessionState = sessionState
        self.overviewSleep = overviewSleep
        state = ArtifactsState()
        restorePersistedState()
        if file.isLoadUnavailable {
            protectedDataSubscription = NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.retryUnavailableState() }
        }
        observeConnections()
    }

    var selectedTab: ArtifactTab? { state.selectedID.flatMap(tab) }
    func tab(_ id: String) -> ArtifactTab? { state.tabs.first { $0.id == id } }
    func imageGeneration(for tabID: String) -> Int { imageGenerations[tabID, default: 0] }

    func overview(query: String) -> ArtifactsOverview {
        ArtifactsOverview.make(state, filter: state.filter, query: query)
    }

    func content(for tabID: String) -> ArtifactContent {
        _ = sourceRevision
        guard let tab = tab(tabID) else { return .unavailable(.missing) }
        switch tab.target {
        case let .change(path, diff, _): return .change(path: path, diff: diff)
        case .page:
            if let content = pages.content(for: tab) { return content }
            if loadingIDs.contains(tabID) { return .loading }
            if let failure = failures[tabID] { return .unavailable(failure) }
            return .unavailable(isLive(hostID: tab.hostID) || hasLiveMosh(hostID: tab.hostID) ? .noForwarding : .offline)
        case .file:
            let bridge = connectedBridge(hostID: tab.hostID)
            if bridge != nil, let failure = failures[tabID] {
                switch failure {
                case .tooLarge, .missing: return .unavailable(failure)
                default: break
                }
            }
            if bridge != nil, tab.target.viewer == .html, let handler = servedPages[tabID] {
                return .servedPage(url: handler.pageURL, registration: ArtifactWebSchemeRegistration(scheme: ArtifactSchemeHandler.scheme, handler: handler))
            }
            if let localURL = loader.cachedURL(for: tab) {
                var prepareImages: ArtifactImagePreparation?
                // Keep a staged or issued document's preparation while offline
                // too, so its reconnect does not stage it again. A document
                // first shown offline gets its first live preparation then.
                if tab.target.viewer == .markdown,
                   bridge != nil || imageGenerations[tabID] != nil || imagesStagedIDs.contains(tabID) {
                    let generation = imageGeneration(for: tabID)
                    prepareImages = ArtifactImagePreparation(generation: generation) { [weak self] in
                        guard let self, !self.stateFile.isLoadUnavailable, self.tab(tab.id) != nil else { return }
                        guard let bridge = self.connectedBridge(hostID: tab.hostID) else {
                            if !self.imagesStagedIDs.contains(tab.id) { self.imageRetryIDs.insert(tab.id) }
                            return
                        }
                        let refreshID = self.imageRefreshIDs[tab.id]
                        let reloadToken = self.reloadTokens[tab.id, default: 0]
                        let attempt = ImageAttempt(reloadToken: reloadToken, generation: generation,
                                                   epoch: self.imageEpochs[tab.hostID, default: 0])
                        // A remount is not a retry: forced downloads that fell
                        // short wait for the next connection or foreground.
                        guard self.imageShortfalls[tab.id] != attempt else { return }
                        let completed: Bool
                        do {
                            completed = try await self.loader.prepareImages(
                                document: localURL, remotePath: tab.target.path, bridge: bridge, force: refreshID != nil
                            )
                        } catch {
                            if !Task.isCancelled, self.reloadTokens[tab.id, default: 0] == reloadToken {
                                self.imagesFellShort(tab.id, attempt: attempt)
                            }
                            throw error
                        }
                        if self.reloadTokens[tab.id, default: 0] == reloadToken {
                            if completed {
                                self.imageRetryIDs.remove(tab.id)
                                self.imageShortfalls[tab.id] = nil
                                self.imagesStagedIDs.insert(tab.id)
                            } else {
                                self.imagesFellShort(tab.id, attempt: attempt)
                            }
                        }
                        // A staging of the previous document or an older
                        // refresh cannot consume the current refresh intent.
                        if completed, self.imageRefreshIDs[tab.id] == refreshID,
                           self.documentRefreshIDs[tab.id] == nil,
                           self.reloadTokens[tab.id, default: 0] == reloadToken, self.loadTasks[tab.id] == nil {
                            self.imageRefreshIDs[tab.id] = nil
                        }
                        // Newly staged sidecars inherit the directory's file
                        // protection and are individually excluded from backup.
                        let sidecars = (try? FileManager.default.contentsOfDirectory(at: localURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
                        for url in sidecars { try? ArtifactsStateFile.protect(url) }
                    }
                }
                return .document(localURL: localURL, title: tab.title, reloadToken: reloadTokens[tabID, default: 0], prepareImages: prepareImages)
            }
            if loadingIDs.contains(tabID) { return .loading }
            return .unavailable(bridge == nil ? .offline : (failures[tabID] ?? .offline))
        }
    }

    func presentation(for tabID: String) -> ArtifactsCachePresentation {
        _ = sourceRevision
        guard var tab = tab(tabID) else {
            return ArtifactsCachePolicy.presentation(
                ArtifactTab(id: tabID, hostID: "", hostLabel: "", target: .file(path: "/"), title: "", openedAt: 0, viewedAt: 0),
                liveConnection: false, nowMillis: now()
            )
        }
        let live: Bool
        switch tab.target {
        case .file:
            if loader.cachedURL(for: tab) == nil { tab.cache = nil }
            live = connectedBridge(hostID: tab.hostID) != nil
        case .page:
            // The badge says whether a session reaches the host, as the
            // host's header does; only a forwarded page has a load to refresh.
            var presentation = ArtifactsCachePolicy.presentation(tab, liveConnection: isLive(hostID: tab.hostID), nowMillis: now())
            if case .forwardedPage? = pages.content(for: tab) {} else { presentation.canRefresh = false }
            return presentation
        case .change: live = false
        }
        return ArtifactsCachePolicy.presentation(tab, liveConnection: live, nowMillis: now())
    }

    func isLive(hostID: String) -> Bool {
        _ = sourceRevision
        return connectedBridge(hostID: hostID) != nil || sshSources.contains { $0.hostID == hostID }
    }

    /// An automatic open: Files, a terminal path or link, an agent edit. It
    /// focuses the target's open tab, as it always has.
    @discardableResult
    func open(_ request: ArtifactOpenRequest) -> String? {
        open(request, placement: nil)
    }

    /// `placement` is where a tab the user asked for goes: always a new tab,
    /// or the tab whose address they edited. Nil is an automatic open.
    @discardableResult
    func open(_ request: ArtifactOpenRequest, placement: ArtifactOpenPlacement?) -> String? {
        let hostID = request.hostID.uuidString
        if placement == nil, let tabID = request.tabID, tab(tabID)?.hostID == hostID {
            select(tabID)
            return tabID
        }
        guard let host = hosts[hostID] else {
            NSLog("Artifacts: ignored open for unknown host %@", hostID)
            return nil
        }
        let target: ArtifactsTarget
        let title: String
        switch request.target {
        case let .file(path):
            guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
            target = .file(path: path)
            title = (path as NSString).lastPathComponent
        case let .page(scheme, port, path):
            guard let port = UInt16(exactly: port), port > 0, ["http", "https"].contains(scheme.lowercased()) else { return nil }
            target = .page(scheme: scheme.lowercased(), port: port, path: path)
            title = ":\(port)"
        case let .change(path, diff, summary):
            guard !path.isEmpty, !path.contains("\0") else { return nil }
            target = .change(path: path, diff: diff, summary: summary)
            title = (path as NSString).lastPathComponent
        }
        let core = ArtifactsOpenRequest(
            id: UUID().uuidString, hostID: hostID, hostLabel: host.label, target: target,
            title: title, origin: request.origin.rawValue, sessionHint: request.sessionID?.uuidString,
            newTab: placement != nil
        )
        switch placement {
        case let .navigate(tabID)?:
            guard let current = tab(tabID) else { return nil }
            if ArtifactsReducer.canNavigateInPlace(current), current.hostID == hostID {
                reduce(.navigate(tabID: tabID, target: target, title: title, nowMillis: now()))
                guard state.selectedID == tabID else { return nil }
                if case .page = target { pageNavigations[tabID, default: 0] &+= 1 }
            } else {
                // A tab keeps its host, and an agent edit's snapshot stays:
                // the address opens beside it.
                reduce(.open(core, nowMillis: now()))
            }
        case .newTab?, nil:
            reduce(.open(core, nowMillis: now()))
        }
        guard let tab = selectedTab else { return nil }
        showsBrowserOverview = false
        if case .file = tab.target, let staged = request.stagedLocalURL, !isCacheRestorationFenced(tab) {
            do {
                fetched(tab.id, file: try loader.adopt(staged, for: tab))
                evictCache()
            }
            catch { failures[tab.id] = unavailable(error) }
        }
        load(tab.id, force: request.stagedLocalURL == nil && request.origin == .files)
        return tab.id
    }

    func select(_ tabID: String) {
        guard tab(tabID) != nil else { return }
        showsBrowserOverview = false
        reduce(.select(tabID: tabID, nowMillis: now()))
        load(tabID)
    }

    func close(_ tabID: String) {
        if let tab = tab(tabID) {
            remember(tab)
            closedTabs.push(tab)
        }
        reduce(.close(tabID: tabID, nowMillis: now()))
        if let selected = state.selectedID { load(selected) }
    }

    func closeAll(hostID: String) {
        // Oldest first, so ⌘⇧T brings back the most recently viewed one first.
        for tab in state.tabs.filter({ $0.hostID == hostID }).sorted(by: { $0.viewedAt < $1.viewedAt }) {
            remember(tab)
            closedTabs.push(tab)
        }
        reduce(.closeAll(hostID: hostID, nowMillis: now()))
        if let selected = state.selectedID { load(selected) }
    }

    var canReopenClosedTab: Bool { closedTabs.contains { hosts[$0.hostID] != nil } }

    /// ⌘⇧T: the last closed tab comes back as a new tab, selected. Its cached
    /// copy, if eviction has not reached it, is shared by target.
    @discardableResult
    func reopenClosedTab() -> String? {
        while let closed = closedTabs.pop() {
            guard let host = hosts[closed.hostID] else { continue }
            let id = UUID().uuidString
            reduce(.open(ArtifactsOpenRequest(
                id: id, hostID: closed.hostID, hostLabel: host.label, target: closed.target, title: closed.title,
                origin: closed.origin, sessionHint: closed.sessionHint, newTab: true
            ), nowMillis: now()))
            guard tab(id) != nil else { continue }
            if closed.pinned { reduce(.pin(tabID: id, pinned: true, nowMillis: now())) }
            showsBrowserOverview = false
            load(id)
            return id
        }
        return nil
    }

    /// The file a tab shows, as the share sheet takes it: a complete cached
    /// copy with its own name, never a download still in progress.
    func pageNavigation(for tabID: String) -> Int { pageNavigations[tabID] ?? 0 }

    func shareableFile(for tabID: String) -> ArtifactFileShare {
        _ = sourceRevision
        // A finished download bumps the tab's token; read it so a share
        // control waiting on the copy enables when it lands.
        _ = reloadTokens[tabID]
        guard let tab = tab(tabID), case .file = tab.target else { return .none }
        // The loader only ever renames a complete download into place, so a
        // cached copy is never a partial one.
        if let url = loader.cachedURL(for: tab) { return .ready(url) }
        if loadingIDs.contains(tabID) { return .unavailable(String(localized: "this file is still downloading")) }
        if case .tooLarge? = failures[tabID] {
            return .unavailable(String(localized: "this file exceeds the 64 MiB preview limit"))
        }
        return .unavailable(String(localized: "this file has not been downloaded yet"))
    }

    func setPinned(_ tabID: String, _ pinned: Bool) { reduce(.pin(tabID: tabID, pinned: pinned, nowMillis: now())) }
    func setFilter(_ filter: ArtifactsFilter) { reduce(.setFilter(filter, nowMillis: now())) }

    func refresh(_ tabID: String) {
        guard let tab = tab(tabID), isLive(hostID: tab.hostID) else { return }
        if case .file = tab.target { documentRefreshIDs[tabID] = UUID() }
        if tab.target.viewer == .markdown {
            imageRefreshIDs[tabID] = UUID()
            if connectedBridge(hostID: tab.hostID) != nil { imageSpentEpochs[tabID] = imageEpochs[tab.hostID, default: 0] }
        }
        load(tabID, force: true)
    }

    func filesReconnect(for tabID: String) -> ArtifactFilesReconnect? {
        _ = sourceRevision
        guard let tab = tab(tabID), connectedBridge(hostID: tab.hostID) == nil,
              filesSession(hostID: tab.hostID) != nil else { return nil }
        switch tab.target {
        case .file: break
        // A mosh session carries no forward; its Files connection can.
        case .page:
            guard hasLiveMosh(hostID: tab.hostID), !sshSources.contains(where: { $0.hostID == tab.hostID }) else { return nil }
        case .change: return nil
        }
        if connectingFiles.contains(tabID) { return .connecting }
        return filesConnectFailures[tabID].map(ArtifactFilesReconnect.failed) ?? .available
    }

    func connectFiles(_ tabID: String) {
        guard let reconnect = filesReconnect(for: tabID), reconnect != .connecting,
              let tab = tab(tabID), let live = filesSession(hostID: tab.hostID), let bridge = filesBridge(live) else { return }
        connectingFiles.insert(tabID)
        filesConnectFailures[tabID] = nil
        Task { [weak self] in
            do {
                try await bridge.connect()
                self?.connectingFiles.remove(tabID)
                self?.refresh(tabID)
            } catch {
                self?.connectingFiles.remove(tabID)
                if let self { self.filesConnectFailures[tabID] = self.message(for: error) }
            }
        }
    }

    /// A terminal session connected to the host, whose credentials a Files
    /// connection reuses.
    private func filesSession(hostID: String) -> LiveSession? {
        sessions.first { $0.persistedHostID?.uuidString == hostID && sessionState($0) == .connected }
    }

    func noteVisible(_ tabID: String?) {
        visibleTabID = tabID.flatMap { tab($0)?.id }
        if let tabID = visibleTabID {
            if state.selectedID == tabID { reduce(.select(tabID: tabID, nowMillis: now())) }
            load(tabID)
        }
        updateFollow()
        updateOverviewSweep()
    }

    /// An overview owns a token so a sheet cannot stop the desk's sweep.
    func noteOverviewVisible(_ id: UUID, _ visible: Bool) {
        if visible {
            guard overviewIDs.insert(id).inserted else { return }
            overviewSweepTask?.cancel()
        } else {
            guard overviewIDs.remove(id) != nil else { return }
        }
        updateOverviewSweep()
    }

    func titleLearned(_ tabID: String, _ title: String) {
        reduce(.titleLearned(tabID: tabID, title: title, nowMillis: now()))
    }

    func canKeepAsRule(_ tabID: String) -> Bool { keepRule != nil && pages.canKeepAsRule(tabID) }

    func keepAsRule(_ tabID: String) {
        guard let tab = tab(tabID), let host = hosts[tab.hostID], let keepRule,
              let rule = pages.ruleToKeep(tabID, title: tab.title),
              PortForwardRuleValidator.validate(rule, against: host.rules) == nil else { return }
        do {
            try keepRule(host.id, rule)
            pages.kept(tabID, rule: rule)
            hosts[tab.hostID]?.rules.append(rule)
        } catch { NSLog("Artifacts: keep rule failed: %@", error.localizedDescription) }
    }

    var quickOpenHosts: [ArtifactsQuickOpenHost] {
        _ = sourceRevision
        return hosts.values.sorted {
            $0.label == $1.label ? $0.id.uuidString < $1.id.uuidString : $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }.map { host in
            ArtifactsQuickOpenHost(id: host.id.uuidString, label: host.label, home: connectedBridge(hostID: host.id.uuidString)?.homeDirectory)
        }
    }

    func quickOpenSuggestions(_ input: String, currentHostID: String?) -> [ArtifactsSuggestion] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix(":"), let currentHostID { probePortsIfNeeded(currentHostID) }
        else if text.hasPrefix("localhost"), let currentHostID { probePortsIfNeeded(currentHostID) }
        return ArtifactsQuickOpen.suggestions(input, state: state, context: quickOpenContext(currentHostID), recents: recents)
    }

    func quickOpen(_ input: String, currentHostID: String?, placement: ArtifactOpenPlacement) async -> ArtifactQuickOpenOutcome {
        switch ArtifactsQuickOpen.parse(input, context: quickOpenContext(currentHostID)) {
        case let .page(hostID, scheme, port, path):
            guard let host = hosts[hostID], let id = open(ArtifactOpenRequest(hostID: host.id, target: .page(scheme: scheme, port: Int(port), path: path), origin: .quickOpen), placement: placement) else {
                return .failed(String(localized: "this host is unavailable"))
            }
            return .opened(tabID: id)
        case let .file(hostID, path), let .directory(hostID, path):
            guard let host = hosts[hostID] else { return .failed(String(localized: "this host is unavailable")) }
            var bridge = connectedBridge(hostID: hostID)
            if bridge == nil, let live = filesSession(hostID: hostID), let files = filesBridge(live) {
                do {
                    try Task.checkCancellation()
                    try await files.connect()
                    try Task.checkCancellation()
                    // Whichever bridge now serves the host resolves the path.
                    guard let connected = connectedBridge(hostID: hostID) else { throw FileBridgeError.notConnected }
                    bridge = connected
                } catch { return .failed(message(for: error)) }
            }
            guard let bridge else {
                // An open tab's cached copy also works offline. Its cache is
                // keyed by target, so the new or navigated tab shows it too.
                if let existing = state.tabs.first(where: { $0.hostID == hostID && $0.target == ArtifactsTarget.file(path: path).normalized }),
                   loader.cachedURL(for: existing) != nil,
                   let id = open(ArtifactOpenRequest(hostID: host.id, target: .file(path: existing.target.path), origin: .quickOpen),
                                 placement: placement) {
                    if let cache = existing.cache { reduce(.fetched(tabID: id, cache: cache, nowMillis: cache.fetchedAt)) }
                    return .opened(tabID: id)
                }
                return .failed(String(localized: "this host is offline"))
            }
            do {
                let expanded: String
                if path == "~" || path.hasPrefix("~/") {
                    guard let home = bridge.homeDirectory else { return .failed(String(localized: "the host home directory is unavailable")) }
                    expanded = home + (path == "~" ? "" : String(path.dropFirst()))
                } else { expanded = path }
                let resolved = try await bridge.realPath(expanded)
                try Task.checkCancellation()
                guard connectedBridge(hostID: hostID) === bridge else { throw FileBridgeError.notConnected }
                let entry = try await ArtifactContentLoader.stat(resolved, bridge: bridge)
                try Task.checkCancellation()
                guard connectedBridge(hostID: hostID) === bridge else { throw FileBridgeError.notConnected }
                guard hosts[hostID] != nil else { return .failed(String(localized: "this host is unavailable")) }
                if entry.kind == .directory { return .directory(hostID: hostID, path: resolved) }
                guard entry.kind == .file || entry.kind == .symlink else { return .failed(String(localized: "this path is not a regular file")) }
                guard let id = open(ArtifactOpenRequest(hostID: host.id, target: .file(path: resolved), origin: .quickOpen),
                                    placement: placement) else {
                    return .failed(String(localized: "this file could not be opened"))
                }
                return .opened(tabID: id)
            } catch { return .failed(message(for: error)) }
        case .search:
            return .failed(String(localized: "enter a file path or a localhost port"))
        case .invalid:
            return .failed(String(localized: "enter a host and path, or a localhost port"))
        }
    }

    /// Additive app-root inputs; the browser's interface above stays fixed.
    func configure(bridges: FileBridgeRegistry, sessions: [LiveSession], keepRule: @escaping (UUID, PortForwardRule) throws -> Void) {
        bridgeProvider = { Array(bridges.bridges.values) }
        filesBridge = { [weak bridges] live in
            switch live.session {
            case let .ssh(session):
                bridges?.bridge(for: session.host, requireBiometric: session.requireBiometric, isSecureEnclave: session.isSecureEnclave)
            case let .mosh(session):
                bridges?.bridge(for: session.host, requireBiometric: session.requireBiometric, isSecureEnclave: session.isSecureEnclave)
            }
        }
        self.keepRule = keepRule
        updateSessions(sessions)
    }

    func updateSessions(_ sessions: [LiveSession]) {
        self.sessions = sessions
        subscriptions.removeAll()
        for live in sessions {
            switch live.session {
            case let .ssh(session):
                session.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.connectionsChanged() }.store(in: &subscriptions)
                session.$remoteWorkingDirectory.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sourceRevision &+= 1 }.store(in: &subscriptions)
            case let .mosh(session):
                session.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.connectionsChanged() }.store(in: &subscriptions)
                session.$remoteWorkingDirectory.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sourceRevision &+= 1 }.store(in: &subscriptions)
            }
        }
        connectionsChanged()
    }

    func syncHosts(_ directory: [ArtifactsHostDirectoryEntry]) {
        let next = Dictionary(directory.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { _, b in b })
        let known = Set(hosts.keys).union(state.tabs.map(\.hostID))
        for removed in known.subtracting(next.keys) {
            portProbeTasks.removeValue(forKey: removed)?.cancel()
            portProbeIDs[removed] = nil
            portProbeDates[removed] = nil
            listeningPorts[removed] = nil
            imageEpochs[removed] = nil
            imageEpochBridgeIDs[removed] = nil
        }
        hosts = next
        hostDirectoryLoaded = true
        closedTabs.retain { next[$0.hostID] != nil }
        let reconciled = reconcilingHosts(in: state)
        if reconciled != state {
            let removedTabs = reconciled.tabs.count < state.tabs.count
            publishState(reconciled)
            stateFile.schedule(state)
            if removedTabs { evictCache() }
        }
        recents.removeAll { recent in
            switch recent.intent {
            case let .file(id, _), let .directory(id, _), let .page(id, _, _, _): return next[id] == nil
            case .search, .invalid: return true
            }
        }
        pages.reconcile(sources: sshSources, rulesByHost: hosts.mapValues(\.rules))
        if let selected = state.selectedID { load(selected) }
    }

    private func reconcilingHosts(in restored: ArtifactsState) -> ArtifactsState {
        var reconciled = restored
        for removed in Set(restored.tabs.map(\.hostID)).subtracting(hosts.keys) {
            reconciled = ArtifactsReducer.reduce(reconciled, .hostRemoved(hostID: removed, nowMillis: now())).state
        }
        for (id, host) in hosts where reconciled.tabs.contains(where: { $0.hostID == id && $0.hostLabel != host.label }) {
            reconciled = ArtifactsReducer.reduce(reconciled, .hostRelabelled(hostID: id, label: host.label, nowMillis: now())).state
        }
        return reconciled
    }

    func setApplicationForeground(_ foreground: Bool) {
        let returned = foreground && !isForeground
        isForeground = foreground
        if returned { noteImageOpportunities(foreground: true) }
        if !foreground {
            for id in Array(loadTasks.keys) { cancelLoad(id) }
            for task in portProbeTasks.values { task.cancel() }
            portProbeTasks.removeAll()
            portProbeIDs.removeAll()
            flush()
        } else {
            retryUnavailableState()
            if let visibleTabID { load(visibleTabID) }
        }
        updateFollow()
        updateOverviewSweep()
    }

    private func restorePersistedState() {
        let restored = stateFile.load()
        guard !stateFile.isLoadUnavailable else { return }
        let reconciled = hostDirectoryLoaded ? reconcilingHosts(in: restored) : restored
        if reconciled != restored {
            let retained = Set(reconciled.tabs.map(\.id))
            for tab in restored.tabs where !retained.contains(tab.id) { deferCacheRemoval(tab) }
        }
        fencedCacheKeys.removeAll()
        publishState(reconciled)
        if reconciled != restored { stateFile.schedule(state) }
        protectedDataSubscription = nil
        evictCache()
    }

    private func retryUnavailableState() {
        guard stateFile.isLoadUnavailable else { return }
        restorePersistedState()
        if isForeground, let visibleTabID { load(visibleTabID) }
    }

    func flush() { stateFile.flush() }

    func waitForCacheEviction() async { await evictionTask?.value }

    func waitForLoad(_ tabID: String) async { await loadTasks[tabID]?.value }

    func agentEditObserved(hostID: UUID, absolutePath: String) {
        guard absolutePath.hasPrefix("/"), hosts[hostID.uuidString] != nil else { return }
        reduce(.agentEditObserved(hostID: hostID.uuidString, path: absolutePath, nowMillis: now()))
        let editedTarget = ArtifactsTarget.file(path: absolutePath).normalized
        for tab in state.tabs where tab.hostID == hostID.uuidString && tab.target == editedTarget {
            // A pre-edit fetch must not clear the new unseen mark when it
            // completes. Only the visible file immediately starts a new read.
            cancelLoad(tab.id)
            if tab.id == visibleTabID {
                reduce(.select(tabID: tab.id, nowMillis: now()))
                load(tab.id)
            }
        }
    }

    var sshSources: [ArtifactSSHSource] {
        let terminalSources: [ArtifactSSHSource] = sessions.compactMap { live in
            guard let id = live.persistedHostID, case let .ssh(session) = live.session, sessionState(live) == .connected else { return nil }
            return ArtifactSSHSource(sessionID: live.id, hostID: id.uuidString, manager: session.portForwarderManager)
        }
        let fileSources: [ArtifactSSHSource] = bridgeProvider().compactMap { bridge in
            guard let hostID = bridge.key.hostID, hasLiveSession(hostID: hostID.uuidString), bridge.state == .connected,
                  let manager = bridge.artifactForwarding else { return nil }
            return ArtifactSSHSource(sessionID: ArtifactSSHSource.bridgeSessionID(for: bridge.key),
                                     hostID: hostID.uuidString, manager: manager, isFileBridge: true)
        }
        return ArtifactPageForwarder.orderedSources(terminalSources + fileSources, sessionHint: nil)
    }

    private func connectedBridge(hostID: String) -> (any FileBridging)? {
        guard hasLiveSession(hostID: hostID) else { return nil }
        return bridgeProvider().first { $0.key.hostID?.uuidString == hostID && $0.state == .connected }
    }

    private func hasLiveSession(hostID: String) -> Bool {
        sessions.contains { live in
            guard live.persistedHostID?.uuidString == hostID else { return false }
            switch sessionState(live) {
            case .idle, .connecting, .connected: return true
            case .disconnected, .failed: return false
            }
        }
    }

    private func hasLiveMosh(hostID: String) -> Bool {
        sessions.contains { live in
            guard live.persistedHostID?.uuidString == hostID, case .mosh = live.session else { return false }
            return sessionState(live) == .connected
        }
    }

    private func quickOpenContext(_ hostID: String?) -> ArtifactsQuickOpenContext {
        let cwd = sessions.first { $0.persistedHostID?.uuidString == hostID && sessionState($0) == .connected }?.session.terminalSession.remoteWorkingDirectory
        return ArtifactsQuickOpenContext(hosts: quickOpenHosts, currentHostID: hostID, cwd: cwd,
                                        listeningPorts: hostID.flatMap { listeningPorts[$0] } ?? [],
                                        activeForwards: activeForwards)
    }

    /// Saved rules listening now in a source a page tab can borrow them
    /// from, read from the managers' state. Reading never connects.
    private var activeForwards: [ArtifactsActiveForward] {
        sshSources.flatMap { source in
            source.manager.forwarders.values.compactMap { forwarder -> ArtifactsActiveForward? in
                switch forwarder.state {
                case .listening, .active: return ArtifactsActiveForward(hostID: source.hostID, rule: forwarder.rule)
                case .idle, .error: return nil
                }
            }
        }
    }

    private func remember(_ tab: ArtifactTab) {
        let intent: ArtifactsQuickOpenIntent
        switch tab.target {
        case let .file(path): intent = .file(hostID: tab.hostID, path: path)
        case let .page(scheme, port, path): intent = .page(hostID: tab.hostID, scheme: scheme, port: port, path: path)
        case .change: return
        }
        recents.removeAll { $0.intent == intent }
        recents.insert(ArtifactsRecent(title: tab.title, subtitle: "\(tab.hostLabel) · \(tab.target.path)", intent: intent, viewedAt: now()), at: 0)
        recents = Array(recents.prefix(16))
    }

    private func probePortsIfNeeded(_ hostID: String) {
        guard isForeground, hosts[hostID] != nil, let bridge = connectedBridge(hostID: hostID),
              portProbeTasks[hostID] == nil, portProbeDates[hostID].map({ now() - $0 >= 10_000 }) ?? true else { return }
        // This is demand from an open Quick Open field, never a background
        // poll. The shared command has a one-second remote watchdog.
        portProbeDates[hostID] = now()
        let id = UUID()
        portProbeIDs[hostID] = id
        portProbeTasks[hostID] = Task { @MainActor [weak self] in
            defer {
                if self?.portProbeIDs[hostID] == id {
                    self?.portProbeTasks[hostID] = nil
                    self?.portProbeIDs[hostID] = nil
                }
            }
            do {
                let output = try await bridge.exec(ArtifactsListeningPorts.probeCommand, inShell: false)
                try Task.checkCancellation()
                guard let self, self.hosts[hostID] != nil, self.connectedBridge(hostID: hostID) === bridge else { return }
                self.listeningPorts[hostID] = ArtifactsListeningPorts.parse(output, sshPort: UInt16(exactly: bridge.key.port))
            } catch { }
        }
    }

    private func reduce(_ action: ArtifactsAction) {
        let result = ArtifactsReducer.reduce(state, action)
        guard result.state != state else { return }
        publishState(result.state)
        stateFile.schedule(state)
        switch action {
        case .pin(_, false, _), .close, .closeAll, .hostRemoved: evictCache()
        default: break
        }
    }

    private func publishState(_ restored: ArtifactsState) {
        let previous = state
        state = restored
        let current = Dictionary(state.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for tab in previous.tabs {
            // A tab navigated in place keeps its ID and drops what belonged to
            // its old target. Another path on the same port keeps the lease.
            let next = current[tab.id]
            guard next == nil || next?.hostID != tab.hostID || next?.target != tab.target else { continue }
            let keepsLease = next.map { Self.sharesForward(tab, $0) } ?? false
            cancelLoad(tab.id)
            // A stat of the old file must not land on the new one; following
            // restarts below for whatever the tab shows now.
            if next != nil, follower.tabID == tab.id { follower.stop() }
            if !keepsLease { pages.close(tab.id) }
            servedPages[tab.id] = nil
            servedBridgeIDs[tab.id] = nil
            failures[tab.id] = nil
            overviewPollOrder[tab.id] = nil
            if next == nil {
                reloadTokens[tab.id] = nil
                pageNavigations[tab.id] = nil
            } else { reloadTokens[tab.id, default: 0] &+= 1 }
            imageGenerations[tab.id] = nil
            documentRefreshIDs[tab.id] = nil
            imageRefreshIDs[tab.id] = nil
            imageSpentEpochs[tab.id] = nil
            imageShortfalls[tab.id] = nil
            imageRetryIDs.remove(tab.id)
            imagesStagedIDs.remove(tab.id)
            if !state.tabs.contains(where: { ArtifactsCachePolicy.cacheKey($0) == ArtifactsCachePolicy.cacheKey(tab) }) {
                let key = ArtifactsCachePolicy.cacheKey(tab)
                if isCacheRestorationFenced(tab) { deferCacheRemoval(tab) }
                else {
                    loader.removeCache(for: tab)
                    fencedCacheKeys.remove(key)
                }
            }
        }
        if visibleTabID != nil, state.selectedID != previous.selectedID { visibleTabID = state.selectedID }
        updateFollow()
        updateOverviewSweep()
    }

    /// The same host's remote port: one forward serves both pages.
    static func sharesForward(_ lhs: ArtifactTab, _ rhs: ArtifactTab) -> Bool {
        guard lhs.hostID == rhs.hostID, case let .page(_, p, _) = lhs.target, case let .page(_, q, _) = rhs.target else { return false }
        return p == q
    }

    private func reserveLoadConnections(_ tab: ArtifactTab) -> [(bridge: FileBridge, id: UUID)] {
        guard hasLiveSession(hostID: tab.hostID) else { return [] }
        switch tab.target {
        case .change: return []
        case .file:
            guard let bridge = connectedBridge(hostID: tab.hostID) as? FileBridge,
                  let id = bridge.reserveArtifactConnection() else { return [] }
            return [(bridge, id)]
        case .page: break
        }
        return bridgeProvider().compactMap { candidate in
            guard candidate.key.hostID?.uuidString == tab.hostID, candidate.state == .connected,
                  let bridge = candidate as? FileBridge, bridge.artifactForwarding?.canStartEphemeral == true,
                  let id = bridge.reserveArtifactConnection() else { return nil }
            return (bridge, id)
        }
    }

    private func load(_ tabID: String, force: Bool = false) {
        guard isForeground, let tab = tab(tabID), hosts[tab.hostID] != nil else { return }
        if !force, loadTasks[tabID] != nil { return }
        let forceFetch = force || documentRefreshIDs[tabID] != nil
        switch tab.target {
        case .change: return
        case .file:
            guard let bridge = connectedBridge(hostID: tab.hostID) else { return }
            // Replacing a document can sweep legacy image sidecars. Until
            // restoration succeeds, the existing key may belong to a pin.
            guard !isCacheRestorationFenced(tab) else {
                prepareHTML(tab, bridge: bridge)
                return
            }
            if !forceFetch, tab.cache?.isStale != true, loader.cachedURL(for: tab) != nil {
                offerImageRetry(tab)
                prepareHTML(tab, bridge: bridge)
                return
            }
        case .page:
            guard sshSources.contains(where: { $0.hostID == tab.hostID && $0.manager.canStartEphemeral }) else {
                failures[tabID] = isLive(hostID: tab.hostID) || hasLiveMosh(hostID: tab.hostID) ? .noForwarding : .offline
                return
            }
            if !force, case .forwardedPage? = pages.content(for: tab) { return }
        }
        cancelLoad(tabID)
        let reloadHTML = tab.target.viewer == .html && servedPages[tabID] != nil
        let id = UUID()
        loadIDs[tabID] = id
        loadingIDs.insert(tabID)
        failures[tabID] = nil
        if let bridge = connectedBridge(hostID: tab.hostID) { prepareHTML(tab, bridge: bridge) }
        let connectionReservations = reserveLoadConnections(tab)
        loadTasks[tabID] = Task { @MainActor [weak self] in
            var reservations = connectionReservations
            defer {
                if !reservations.isEmpty {
                    Task { @MainActor [reservations] in
                        for reservation in reservations { await reservation.bridge.releaseArtifactConnection(reservation.id) }
                    }
                }
            }
            guard let self else { return }
            defer {
                if self.loadIDs[tabID] == id {
                    self.loadTasks[tabID] = nil
                    self.loadIDs[tabID] = nil
                    self.loadingIDs.remove(tabID)
                    self.evictCache()
                }
            }
            do {
                switch tab.target {
                case .file:
                    reservations += self.reserveLoadConnections(tab)
                    guard let bridge = self.connectedBridge(hostID: tab.hostID) else { throw FileBridgeError.notConnected }
                    let file = try await self.loader.fetch(tab, bridge: bridge, force: forceFetch)
                    try Task.checkCancellation()
                    guard self.tab(tabID) != nil, self.loadIDs[tabID] == id else { return }
                    self.fetched(tabID, file: file)
                    self.prepareHTML(tab, bridge: bridge, replace: reloadHTML)
                case .page:
                    // A bridge may have reconnected while this load was queued.
                    reservations += self.reserveLoadConnections(tab)
                    try await self.pages.open(tab, rules: self.hosts[tab.hostID]?.rules ?? [], sources: self.sshSources)
                    self.pages.reconcile(sources: self.sshSources, rulesByHost: self.hosts.mapValues(\.rules))
                    if self.tab(tabID) == nil { self.pages.close(tabID) }
                case .change: break
                }
            } catch {
                guard !Task.isCancelled, self.loadIDs[tabID] == id else { return }
                self.failures[tabID] = self.unavailable(error)
            }
        }
    }

    private func fetched(_ tabID: String, file: ArtifactLoadedFile) {
        documentRefreshIDs[tabID] = nil
        imagesStagedIDs.remove(tabID)
        imageShortfalls[tabID] = nil
        failures[tabID] = nil
        reloadTokens[tabID, default: 0] &+= 1
        if let tab = tab(tabID), connectedBridge(hostID: tab.hostID) != nil {
            imageSpentEpochs[tabID] = imageEpochs[tab.hostID, default: 0]
        }
        reduce(.fetched(tabID: tabID, cache: ArtifactsCacheMetadata(fetchedAt: now(), remoteMTime: file.remoteMTime, size: file.size), nowMillis: now()))
        sourceRevision &+= 1
    }

    /// A staging that fell short spends only the opportunity it started on.
    /// One that came meanwhile, a reconnect or a foreground, retries once.
    private func imagesFellShort(_ tabID: String, attempt: ImageAttempt) {
        imageRetryIDs.insert(tabID)
        imageShortfalls[tabID] = attempt
        if imageSpentEpochs[tabID].map({ $0 < attempt.epoch }) ?? true { imageSpentEpochs[tabID] = attempt.epoch }
        if let tab = tab(tabID) { offerImageRetry(tab) }
    }

    /// Unfinished images get one new generation per opportunity, which
    /// restarts a mounted document's staging.
    private func offerImageRetry(_ tab: ArtifactTab) {
        guard isForeground, tab.target.viewer == .markdown,
              imageRefreshIDs[tab.id] != nil || imageRetryIDs.contains(tab.id),
              connectedBridge(hostID: tab.hostID) != nil else { return }
        let epoch = imageEpochs[tab.hostID, default: 0]
        guard imageSpentEpochs[tab.id] != epoch else { return }
        imageSpentEpochs[tab.id] = epoch
        imageGenerations[tab.id, default: 0] &+= 1
    }

    /// A host's connection that appeared or changed, or a return to the
    /// foreground while it is up, begins a new image opportunity.
    private func noteImageOpportunities(foreground: Bool) {
        let hostIDs = Set(bridgeProvider().compactMap { $0.key.hostID?.uuidString })
        for hostID in hostIDs.union(imageEpochBridgeIDs.keys) {
            let bridgeID = connectedBridge(hostID: hostID).map {
                ImageConnectionIdentity(bridgeID: ObjectIdentifier($0), generation: $0.connectionGeneration)
            }
            if let bridgeID, foreground || imageEpochBridgeIDs[hostID] != bridgeID {
                imageEpochClock &+= 1
                imageEpochs[hostID] = imageEpochClock
            }
            imageEpochBridgeIDs[hostID] = bridgeID
        }
    }

    private func evictCache() {
        if stateFile.isLoadUnavailable, fencedCacheKeys.isEmpty { return }
        if !stateFile.isLoadUnavailable, !deferredCacheRemovals.isEmpty {
            // Deferred closes still collect orphans when the cache fits its
            // budget. Restored references always take precedence.
            let retained = Set(state.tabs.map(ArtifactsCachePolicy.cacheKey))
            for (key, tab) in deferredCacheRemovals where !retained.contains(key) { loader.removeCache(for: tab) }
            deferredCacheRemovals.removeAll()
        }
        evictionPending = true
        guard evictionTask == nil else { return }
        evictionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.evictionTask = nil }
            while self.evictionPending {
                self.evictionPending = false
                await self.loader.evict(budgetBytes: self.cacheBudgetBytes, evictableKeys: {
                    self.stateFile.isLoadUnavailable ? self.fencedCacheKeys : nil
                }) {
                    let protected = Set(self.loadTasks.keys.compactMap { self.tab($0) }.map(ArtifactsCachePolicy.cacheKey))
                    return (self.state.tabs, self.state.selectedID, protected)
                }
            }
        }
    }

    private func deferCacheRemoval(_ tab: ArtifactTab) {
        guard case .file = tab.target else { return }
        deferredCacheRemovals[ArtifactsCachePolicy.cacheKey(tab)] = tab
    }

    private func isCacheRestorationFenced(_ tab: ArtifactTab) -> Bool {
        guard stateFile.isLoadUnavailable else { return false }
        let key = ArtifactsCachePolicy.cacheKey(tab)
        // Only a proven-absent key can be created, replaced or removed
        // before we know the persisted tabs. I/O errors keep the fence.
        if fencedCacheKeys.contains(key) { return false }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: loader.localURL(for: tab).deletingLastPathComponent().path)
            return true
        } catch {
            let error = error as NSError
            let absent = (error.domain == NSCocoaErrorDomain &&
                          [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue))
            if absent { fencedCacheKeys.insert(key) }
            return !absent
        }
    }

    private func cancelLoad(_ id: String) {
        loadTasks.removeValue(forKey: id)?.cancel()
        loadIDs[id] = nil
        loadingIDs.remove(id)
    }

    private func prepareHTML(_ tab: ArtifactTab, bridge: any FileBridging, replace: Bool = false) {
        guard tab.target.viewer == .html else { return }
        let bridgeID = ObjectIdentifier(bridge)
        guard replace || servedPages[tab.id] == nil || servedBridgeIDs[tab.id] != bridgeID else { return }
        do {
            let hostID = tab.hostID
            let reader = ArtifactFileBridgeReader(cachedRoot: { [weak self] in
                guard let self else { throw FileBridgeError.notConnected }
                // A scheme request can arrive before the initial load has
                // finished. Wait for acceptance rather than reading it again.
                while let task = self.loadTasks[tab.id] {
                    await task.value
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
                guard let current = self.tab(tab.id) else { throw ArtifactRemoteReadError.notFound }
                if let failure = self.failures[tab.id] {
                    switch failure {
                    case .missing: throw ArtifactRemoteReadError.notFound
                    case .tooLarge: throw ArtifactRemoteReadError.fileTooLarge(maxBytes: Int(ArtifactContentLoader.maximumFileBytes))
                    default: break
                    }
                }
                guard let url = self.loader.cachedURL(for: current) else {
                    if case let .failed(message)? = self.failures[tab.id] { throw FileBridgeError.remoteOperationFailed(message) }
                    throw FileBridgeError.notConnected
                }
                return url
            }) { [weak self] in self?.connectedBridge(hostID: hostID) }
            servedPages[tab.id] = try ArtifactSchemeHandler(tabID: tab.id, pagePath: tab.target.path, reader: reader, maxBytes: Int(ArtifactContentLoader.maximumFileBytes))
            servedBridgeIDs[tab.id] = bridgeID
        } catch { failures[tab.id] = unavailable(error) }
    }

    private func connectionsChanged() {
        sourceRevision &+= 1
        noteImageOpportunities(foreground: false)
        let sources = sshSources
        pages.reconcile(sources: sources, rulesByHost: hosts.mapValues(\.rules))
        for hostID in Array(listeningPorts.keys) where connectedBridge(hostID: hostID) == nil {
            listeningPorts[hostID] = nil
        }
        for hostID in Array(portProbeTasks.keys) where connectedBridge(hostID: hostID) == nil {
            portProbeTasks.removeValue(forKey: hostID)?.cancel()
            portProbeIDs[hostID] = nil
            portProbeDates[hostID] = nil
        }
        for tab in state.tabs {
            if case .file = tab.target, connectedBridge(hostID: tab.hostID) == nil {
                cancelLoad(tab.id)
                servedPages[tab.id] = nil
                servedBridgeIDs[tab.id] = nil
            }
            if case .page = tab.target, !sources.contains(where: { $0.hostID == tab.hostID }) {
                cancelLoad(tab.id)
                failures[tab.id] = isLive(hostID: tab.hostID) || hasLiveMosh(hostID: tab.hostID) ? .noForwarding : .offline
            }
        }
        if let visibleTabID { load(visibleTabID) }
        updateFollow()
        updateOverviewSweep()
        observeConnections()
    }

    private func observeConnections() {
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            for bridge in bridgeProvider() { _ = bridge.state; _ = bridge.connectionGeneration; _ = bridge.homeDirectory }
            for source in sshSources {
                _ = source.manager.canStartEphemeral
                for forwarder in source.manager.forwarders.values { _ = forwarder.rule }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.connectionsChanged()
            }
        }
    }

    private func updateFollow() {
        let id = visibleTabID.flatMap { id -> String? in
            guard isForeground, let tab = tab(id), case .file = tab.target,
                  connectedBridge(hostID: tab.hostID) != nil else { return nil }
            return id
        }
        follower.follow(id) { [weak self] id in await self?.poll(id) ?? false }
    }

    private func poll(_ tabID: String) async -> Bool {
        guard isForeground, visibleTabID == tabID, let tab = tab(tabID), case .file = tab.target,
              let bridge = connectedBridge(hostID: tab.hostID) else { return false }
        guard loadTasks[tabID] == nil else { return true }
        // Navigated in place while the stat ran: drop what it found.
        let retargeted = { [weak self] () -> Bool in
            guard let current = self?.tab(tabID) else { return true }
            return current.hostID != tab.hostID || current.target != tab.target
        }
        do {
            let entry = try await ArtifactContentLoader.stat(tab.target.path, bridge: bridge)
            try Task.checkCancellation()
            guard !retargeted() else { return false }
            guard isForeground, visibleTabID == tabID, connectedBridge(hostID: tab.hostID) === bridge else { return false }
            if failures[tabID] == .missing || failures[tabID] == .offline { failures[tabID] = nil }
            let mtime = entry.modified.map(ArtifactContentLoader.milliseconds)
            let size = entry.size.map { Int64(clamping: $0) }
            reduce(.remoteStatObserved(tabID: tabID, remoteMTime: mtime, size: size, visible: true, nowMillis: now()))
            if self.tab(tabID)?.cache?.isStale == true || loader.cachedURL(for: tab) == nil { load(tabID) }
        } catch {
            if retargeted() { return false }
            if !Task.isCancelled { failures[tabID] = unavailable(error) }
        }
        return !Task.isCancelled && isForeground && visibleTabID == tabID && connectedBridge(hostID: tab.hostID) === bridge
    }

    private func canSweepOverviewTab(_ tab: ArtifactTab) -> Bool {
        guard tab.id != visibleTabID, tab.cache != nil, case .file = tab.target else { return false }
        return connectedBridge(hostID: tab.hostID) != nil
    }

    private func updateOverviewSweep() {
        let dropped = overviewSweepBridges.contains { hostID, connection in
            connectedBridge(hostID: hostID) !== connection.bridge || connection.bridge.connectionGeneration != connection.generation
        }
        guard isForeground, !overviewIDs.isEmpty, state.tabs.contains(where: canSweepOverviewTab), !dropped else {
            overviewSweepTask?.cancel()
            return
        }
        guard overviewSweepTask == nil else { return }
        let sleep = overviewSleep
        overviewSweepTask = Task { @MainActor [weak self] in
            defer {
                self?.overviewSweepTask = nil
                self?.overviewSweepBridges.removeAll()
                self?.updateOverviewSweep()
            }
            while !Task.isCancelled, self != nil {
                await self?.sweepOverviewFiles()
                do { try await sleep(15_000_000_000) } catch { break }
            }
        }
    }

    private func sweepOverviewFiles() async {
        let tabs = state.tabs.filter(canSweepOverviewTab).sorted {
            let left = overviewPollOrder[$0.id, default: 0], right = overviewPollOrder[$1.id, default: 0]
            if left != right { return left < right }
            if $0.viewedAt != $1.viewedAt { return $0.viewedAt > $1.viewedAt }
            return $0.id < $1.id
        }.prefix(16)
        overviewSweepBridges.removeAll()
        for tab in tabs {
            if let bridge = connectedBridge(hostID: tab.hostID) {
                overviewSweepBridges[tab.hostID] = (bridge, bridge.connectionGeneration)
            }
        }
        for tab in tabs {
            guard !Task.isCancelled, isForeground, !overviewIDs.isEmpty else { return }
            guard let current = self.tab(tab.id), current.hostID == tab.hostID, current.target == tab.target,
                  canSweepOverviewTab(current), let connection = overviewSweepBridges[tab.hostID] else { continue }
            guard connectedBridge(hostID: tab.hostID) === connection.bridge,
                  connection.bridge.connectionGeneration == connection.generation else { return }
            overviewPollSequence += 1
            overviewPollOrder[tab.id] = overviewPollSequence
            let cache = current.cache
            do {
                let entry = try await ArtifactContentLoader.stat(tab.target.path, bridge: connection.bridge)
                try Task.checkCancellation()
                guard isForeground, !overviewIDs.isEmpty,
                      connectedBridge(hostID: tab.hostID) === connection.bridge,
                      connection.bridge.connectionGeneration == connection.generation else { return }
                guard let current = self.tab(tab.id), current.hostID == tab.hostID, current.target == tab.target,
                      current.id != visibleTabID, current.cache == cache else { continue }
                reduce(.remoteStatObserved(tabID: tab.id, remoteMTime: entry.modified.map(ArtifactContentLoader.milliseconds),
                                           size: entry.size.map { Int64(clamping: $0) }, visible: false, nowMillis: now()))
            } catch { }
        }
    }

    private func unavailable(_ error: Error) -> ArtifactUnavailable {
        switch error {
        case let ArtifactContentLoadError.tooLarge(bytes): return .tooLarge(bytes: bytes)
        case ArtifactContentLoadError.missing, ArtifactRemoteReadError.notFound: return .missing
        case FileBridgeError.remoteStatus(let code, _) where code == 2: return .missing
        case FileBridgeError.notConnected: return .offline
        case ArtifactPageForwardError.noSSHSession: return .noForwarding
        case ArtifactPageForwardError.ruleNotRunning: return .failed(String(localized: "this host's forwarding rule is not running"))
        case PortListenerError.bindFailed(let reason): return .failed(reason)
        case PortListenerError.portInUse(let port): return .failed(String(localized: "local port \(String(port)) is already in use"))
        case PortListenerError.cancelled: return .offline
        default: return .failed(error.localizedDescription)
        }
    }

    private func message(for error: Error) -> String {
        switch unavailable(error) {
        case .offline: return String(localized: "this host is offline")
        case .missing: return String(localized: "this path was not found")
        case .tooLarge: return String(localized: "this file exceeds the 64 MiB preview limit")
        case let .failed(message): return message
        case .noForwarding: return String(localized: "pages on mosh hosts open while Files or an ssh session is connected")
        }
    }
}
