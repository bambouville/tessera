import Foundation
import Observation
import TesseraCore

/// Content-free, amortized wall timings for physical-device diagnostics.
/// Async spans include carrier/scheduler waits; they are not CPU measurements.
@MainActor
final class AgentCenterV2PerformanceDiagnostics {
    static let shared = AgentCenterV2PerformanceDiagnostics()
    private var started = Date()
    private var samples: [String: (count: Int, total: Double, max: Double)] = [:]

    func record(_ operation: String, since start: Date) {
        guard DiagnosticLogStore.isVerboseEnabled else { return }
        let milliseconds = max(0, Date().timeIntervalSince(start) * 1_000)
        let previous = samples[operation] ?? (0, 0, 0)
        samples[operation] = (previous.count + 1, previous.total + milliseconds, max(previous.max, milliseconds))
        guard Date().timeIntervalSince(started) >= 10 else { return }
        let detail = samples.keys.sorted().map { name in
            let value = samples[name]!
            return "\(name){count=\(value.count),wallMs=\(Int(value.total)),maxMs=\(Int(value.max))}"
        }.joined(separator: " ")
        DiagnosticLogStore.appendAgentCenter("v2-performance windowMs=\(Int(Date().timeIntervalSince(started) * 1_000)) \(detail)")
        samples.removeAll(keepingCapacity: true)
        started = Date()
    }
}

/// A raw terminal is a real focused surface, not an absent focus value.  Keep
/// that distinction explicit so Dictionary's `nil` removal semantics cannot
/// erase raw SSH/mosh SwipePad evidence.
enum AgentCenterV2SwipePadFocus: Equatable {
    case raw
    case pane(Int)

    init(paneID: Int?) {
        self = paneID.map(Self.pane) ?? .raw
    }

    var paneID: Int? {
        switch self {
        case .raw: nil
        case .pane(let paneID): paneID
        }
    }
}

/// Pure retry predicate used by the lifecycle boundary and focused tests. A
/// cold route remains in the bounded opaque inbox while paused, but it never
/// drives remote rediscovery/inspection while the app is inactive.
enum AgentCenterV2NotificationRetryPolicy {
    static func shouldRun(
        isEnabled: Bool,
        applicationActive: Bool,
        hasPendingRoute: Bool,
        hasSessionSource: Bool
    ) -> Bool {
        isEnabled && applicationActive && hasPendingRoute && hasSessionSource
    }
}

/// A session has at most one generic output refresh and one latest lifecycle
/// event per conversation and agent process. Terminal output can be arbitrarily
/// chatty, but it never needs to schedule more than one subsequent discovery.
struct AgentCenterV2SessionRefreshRequest {
    let paneID: Int?
    let lifecycle: AgentLifecycleEvent?
}

private enum AgentCenterV2LifecycleRefreshScope: Hashable {
    case raw
    case pane(Int)

    init(paneID: Int?) {
        self = paneID.map(Self.pane) ?? .raw
    }

    var paneID: Int? {
        switch self {
        case .raw: nil
        case .pane(let paneID): paneID
        }
    }
}

/// Agents an agent runs in the background (Codex started by Claude) share its
/// pane, so one agent's newer frame must not displace another's still queued.
private struct AgentCenterV2LifecycleRefreshKey: Hashable {
    let scope: AgentCenterV2LifecycleRefreshScope
    let agentPID: Int?
    let provider: String
    let providerSessionID: String
}

struct AgentCenterV2SessionRefreshQueue {
    static let maximumLifecycleScopes = 128
    private var needsGenericRefresh = false
    private var lastDequeuedWasGeneric = false
    private var latestLifecycleByPane: [AgentCenterV2LifecycleRefreshKey: AgentLifecycleEvent] = [:]
    private var lifecyclePaneOrder: [AgentCenterV2LifecycleRefreshKey] = []

    var isEmpty: Bool {
        !needsGenericRefresh && lifecyclePaneOrder.isEmpty
    }

    mutating func enqueue(paneID: Int?, lifecycle: AgentLifecycleEvent?) {
        guard let lifecycle else {
            needsGenericRefresh = true
            return
        }
        let scope = AgentCenterV2LifecycleRefreshKey(
            scope: AgentCenterV2LifecycleRefreshScope(paneID: paneID),
            agentPID: lifecycle.agentPID,
            provider: lifecycle.provider,
            providerSessionID: lifecycle.providerSessionID
        )
        if let previous = latestLifecycleByPane[scope],
           previous.timestampNanoseconds > lifecycle.timestampNanoseconds { return }
        if latestLifecycleByPane[scope] == nil {
            guard lifecyclePaneOrder.count < Self.maximumLifecycleScopes else {
                needsGenericRefresh = true
                return
            }
            lifecyclePaneOrder.append(scope)
        }
        latestLifecycleByPane[scope] = lifecycle
    }

    /// A failed read is older than every arrival already queued, including equal timestamps.
    mutating func requeueIfAbsent(_ request: AgentCenterV2SessionRefreshRequest) {
        if let lifecycle = request.lifecycle {
            let key = AgentCenterV2LifecycleRefreshKey(
                scope: AgentCenterV2LifecycleRefreshScope(paneID: request.paneID),
                agentPID: lifecycle.agentPID,
                provider: lifecycle.provider,
                providerSessionID: lifecycle.providerSessionID
            )
            guard latestLifecycleByPane[key] == nil else { return }
        }
        enqueue(paneID: request.paneID, lifecycle: request.lifecycle)
    }

    mutating func dequeue(allowGeneric: Bool = true) -> AgentCenterV2SessionRefreshRequest? {
        // Alternate when both are queued: continuous output must not starve
        // lifecycle events, nor may a busy agent starve generic discovery.
        if allowGeneric && needsGenericRefresh && (!lastDequeuedWasGeneric || lifecyclePaneOrder.isEmpty) {
            needsGenericRefresh = false
            lastDequeuedWasGeneric = true
            return .init(paneID: nil, lifecycle: nil)
        }
        guard !lifecyclePaneOrder.isEmpty else { return nil }
        let scope = lifecyclePaneOrder.removeFirst()
        guard let lifecycle = latestLifecycleByPane.removeValue(forKey: scope) else {
            return dequeue(allowGeneric: allowGeneric)
        }
        lastDequeuedWasGeneric = false
        return .init(paneID: scope.scope.paneID, lifecycle: lifecycle)
    }
}

/// App-scoped Apple integration point for Agent Center V2.
///
/// The portable `AgentCenterRuntime` remains the sole reducer. This object
/// only mirrors its snapshots into SwiftUI and routes semantic requests into
/// carrier-fenced adapters installed by the owning session. Until a session
/// installs one of those adapters, actions explicitly report unavailable;
/// they never infer a terminal from a host address, title, or v1 card.
@MainActor
@Observable
final class AgentCenterV2Coordinator {
    @ObservationIgnored let runtime: AgentCenterRuntime
    @ObservationIgnored let bridge: AppleAgentCenterRuntimeBridge
    @ObservationIgnored let metadata: AppleAgentMetadataRepository
    @ObservationIgnored let notifications: AppleAgentNotificationAdapter
    @ObservationIgnored let notificationRouter: AppleAgentNotificationRouter
    @ObservationIgnored private var speech: AppleAgentSpeechToDraftAdapter?
    @ObservationIgnored private var attachments: AgentComposerAttachments?
    @ObservationIgnored var onUploadAttachment: ((AgentTerminalBinding, URL) async throws -> String)?
    @ObservationIgnored var terminalAdapters: [AgentThreadID: AppleAgentTerminalAdapter] = [:]
    @ObservationIgnored private var launchPort: (any AgentLaunchPort)?
    @ObservationIgnored var sessionRoutes: [UUID: AppleAgentSessionRoute] = [:] {
        didSet { refreshPaneAgentProviders() }
    }
    /// Read-only inventory/search carrier for a connected session before it
    /// has a live agent binding. Never used by terminal mutations.
    @ObservationIgnored var sessionReadCarriers: [UUID: AgentTerminalBinding] = [:]
    @ObservationIgnored var ingestionHosts: [AppleAgentIngestionHostKey: AppleAgentIngestionHost] = [:]
    @ObservationIgnored var ingestionScopes: [AppleAgentIngestionHostKey: String] = [:]
    @ObservationIgnored var ingestionVisibleCards = Set<AgentThreadID>()
    /// List instances showing each card. A layout change can mount the new
    /// list's rows before the old list's rows disappear.
    @ObservationIgnored var ingestionVisibleCardCounts: [AgentThreadID: Int] = [:]
    @ObservationIgnored var ingestionOpenDetails = Set<AgentThreadID>()
    @ObservationIgnored var threadRoutes: [AgentThreadID: AppleAgentThreadRoute] = [:] {
        didSet { refreshPaneAgentProviders() }
    }
    @ObservationIgnored var candidateRoutes: [AgentSourceCandidateID: AppleAgentThreadRoute] = [:]
    @ObservationIgnored var sessionRefreshTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var sessionRefreshTaskIDs: [UUID: UUID] = [:]
    @ObservationIgnored var sessionRefreshQueues: [UUID: AgentCenterV2SessionRefreshQueue] = [:]
    @ObservationIgnored var sessionRefreshInFlight = Set<UUID>()
    @ObservationIgnored var sessionLivenessRequested = Set<UUID>()
    @ObservationIgnored var sessionDiscoveryAfter: [UUID: Date] = [:]
    @ObservationIgnored var projectionTasks: [AgentThreadID: Task<Void, Never>] = [:]
    @ObservationIgnored var livePromptWatchTasks: [AgentThreadID: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var livePromptLifecycleSequences: [AgentThreadID: UInt64] = [:]
    @ObservationIgnored var livePromptFrameTimes: [AgentThreadID: ContinuousClock.Instant] = [:]
    /// Optional initial history never owns the foreground read/Send gate.
    @ObservationIgnored var initialPrefetchTasks: [AgentThreadID: Task<Void, Never>] = [:]
    @ObservationIgnored var initialPrefetchTaskIDs: [AgentThreadID: UUID] = [:]
    @ObservationIgnored var ingestionReadRetryTasks: [AgentThreadID: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var ingestionReadFailureCounts: [AgentThreadID: Int] = [:]
    @ObservationIgnored var ingestionManualReadThreads = Set<AgentThreadID>()
    @ObservationIgnored var ingestionRetryPageRequests: [AgentThreadID: (cursor: String?, direction: String)] = [:]
    @ObservationIgnored var pendingProjectionRefreshes: Set<AgentThreadID> = []
    @ObservationIgnored var pendingHistoryRequests: Set<AgentThreadID> = []
    /// Fill requests that waited for the initial prefetch to finish.
    @ObservationIgnored var pendingFillRequests: Set<AgentThreadID> = []
    @ObservationIgnored var pendingLatestRequests: Set<AgentThreadID> = []
    /// Receipt reads share the thread's native window with history. The lease
    /// token prevents cleanup from a retired action releasing a new owner's gate.
    @ObservationIgnored var outgoingReceiptLeases: [AgentThreadID: UUID] = [:]
    @ObservationIgnored var performanceDiagnostics = AgentCenterV2PerformanceDiagnostics.shared
    @ObservationIgnored private var launchTargetsRefreshing = false
    @ObservationIgnored private var invalidatedAttentionThreads: Set<AgentThreadID> = []
    private struct CompletionKeys: Equatable { var unread: String?; var acknowledged: String? }
    /// The completion identities last written per thread, so publishing
    /// writes the metadata document only when Core's read state moves.
    @ObservationIgnored private var persistedCompletionKeys: [AgentThreadID: CompletionKeys] = [:]
    /// Threads to re-check on the next publish besides the ones it changed:
    /// every thread after enabling, and any whose write failed.
    @ObservationIgnored private var completionSweepPending = true
    @ObservationIgnored private var completionRetries: Set<AgentThreadID> = []
    @ObservationIgnored private var launchTargetsRefreshAfter = Date.distantPast
    @ObservationIgnored var projectionTaskIDs: [AgentThreadID: UUID] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored var projectionRoutes: [AgentThreadID: AppleAgentProjectionRoute] = [:]
    @ObservationIgnored var initialProjectionRoutes: [AgentThreadID: AppleAgentProjectionRoute] = [:]
    @ObservationIgnored var historicalRoutes: [AgentThreadID: AppleAgentProjectionRoute] = [:]
    @ObservationIgnored var inventoryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var inventoryTaskIDs: [String: UUID] = [:]
    @ObservationIgnored var inventoryRetryAfter: [String: Date] = [:]
    @ObservationIgnored var inventoryRetryTasks: [UUID: Task<Void, Never>] = [:]
    /// Tier-C live gates are scoped to the authenticated session that proved
    /// them. The core registry is the union needed to normalize accepted
    /// pages; presentation and mutations still consult the per-session set so
    /// one conforming host cannot bless a drifting adapter on another host.
    @ObservationIgnored var sessionConformingProviders: [UUID: Set<AgentProviderID>] = [:]
    @ObservationIgnored var lifecycleScanners: [AgentInstanceID: AgentLifecycleOSCScanner] = [:]
    /// The last lifecycle frame each pane delivered. tmux re-announces a
    /// pane's option with every metadata change (a spinner in the pane
    /// title), and a repeat must not buy another all-pane discovery.
    @ObservationIgnored var lastLifecycleDeliveries: [AgentInstanceID: (event: AgentLifecycleEvent, admittedAt: Date)] = [:]
    /// Each session's last occupancy reconcile outcome, logged on change.
    @ObservationIgnored var occupancyDiagnosticOutcomes: [UUID: String] = [:]
    /// Each session pane's last logged lifecycle frame admission.
    @ObservationIgnored var lifecycleDiagnosticOutcomes: [String: String] = [:]
    /// Each live-prompt watch's last logged pass outcome and exit.
    @ObservationIgnored var livePromptWatchOutcomes: [AgentThreadID: (pass: String?, exit: String?)] = [:]
    /// Agent PIDs a fresh process read found outside their pane's
    /// foreground, until their expiry. Children an agent runs in the
    /// background share its tmux pane option; while a proven agent holds the
    /// pane their frames start no pass.
    @ObservationIgnored var foreignLifecyclePIDs: [AgentInstanceID: [Int: Date]] = [:]
    /// Pane holders a retired connection proved, by host and tmux pane. A
    /// foreground restore replaces the connection; while background agents
    /// write the pane option, its replacement has only these to re-prove.
    @ObservationIgnored var retiredPaneHolders: [AppleAgentRetiredPaneHolder.Key: AppleAgentRetiredPaneHolder] = [:]
    /// The terminal-only evidence used by SwipePad and the optional scroll
    /// lock.  This is deliberately a V2 projection: it is derived from the
    /// exact current binding and fresh prompt observation, never from a
    /// transcript block or the retired card reducer.
    @ObservationIgnored private var swipePadContexts: [UUID: SwipePadAgentContext] = [:]
    @ObservationIgnored private var swipePadFocusedLocations: [UUID: AgentCenterV2SwipePadFocus] = [:]
    @ObservationIgnored var candidateActionIDs: Set<AgentSourceCandidateID> = []
    /// Ephemeral, source-attested directory -> exact binding anchors. These
    /// never enter metadata and are revalidated again before launch.
    @ObservationIgnored var validatedLaunchDirectories: [UUID: [String: AgentTerminalBinding]] = [:]
    @ObservationIgnored var pendingNotificationRoutes: [AppleAgentNotificationRoute] = []
    @ObservationIgnored private var notificationRetryTask: Task<Void, Never>?
    @ObservationIgnored private var notificationRetryGeneration: UInt64 = 0
    @ObservationIgnored private var restoredSelection: AgentThreadID?
    @ObservationIgnored var nextCarrierGeneration: UInt64 = 0
    @ObservationIgnored var lifecycleArrivalGeneration: UInt64 = 0
    /// Observed: session chrome reads it through `integrationState(sessionID:)`
    /// and must re-render when a check settles, even on a quiet terminal.
    /// Writers skip identical values so rechecks do not repaint every bar.
    var integrationStates: [UUID: AgentIntegrationWarningState] = [:]
    @ObservationIgnored var integrationInstallations: [String: AgentLifecycleHostInstallation] = [:]
    @ObservationIgnored var integrationInstallationDates: [String: Date] = [:]
    @ObservationIgnored var integrationFailureCounts: [UUID: Int] = [:]
    @ObservationIgnored var integrationRefreshNotBefore: [UUID: Date] = [:]
    @ObservationIgnored var integrationActivityDeadlines: [UUID: Date] = [:]
    @ObservationIgnored var integrationRetryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var integrationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var integrationActivityTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingIntegrationActivityRegistrations: [UUID: UUID] = [:]
    @ObservationIgnored var integrationGenerations: [UUID: UInt64] = [:]

    let presentation: AgentCenterV2PresentationModel
    private(set) var isEnabled = false
    private(set) var hasSurfaceDemand = false
    private(set) var applicationActive = true
    private(set) var notificationsEnabled = false
    @ObservationIgnored private var enablementGeneration: UInt64 = 0
    @ObservationIgnored var searchGeneration: UInt64 = 0
    @ObservationIgnored var onOpenExactTerminal: ((AgentTerminalBinding) -> Void)?
    /// ContentView owns the app-level shell selection. This callback lets an
    /// opaque cold-start route reveal V2 only after it has a fresh binding.
    @ObservationIgnored var onNotificationThreadSelected: ((AgentThreadID) -> Void)?
    /// Reveals V2 on a thread the user chose from terminal chrome (the
    /// attention chip). ContentView owns the shell selection.
    @ObservationIgnored var onRevealThread: ((AgentThreadID) -> Void)?

    init(
        runtime: AgentCenterRuntime = .init(),
        metadata: AppleAgentMetadataRepository = .init(),
        notifications: AppleAgentNotificationAdapter? = nil
    ) {
        self.runtime = runtime
        self.bridge = AppleAgentCenterRuntimeBridge(runtime: runtime)
        self.metadata = metadata
        self.notifications = notifications ?? AppleAgentNotificationAdapter()
        self.notificationRouter = AppleAgentNotificationRouter()
        self.presentation = AgentCenterV2PresentationModel()
        self.attachments = AgentComposerAttachments(
            model: presentation,
            targetFor: { [weak self] thread in
                guard let self, self.isEnabled, self.onUploadAttachment != nil,
                      let binding = thread.binding,
                      let route = self.threadRoutes[thread.summary.id], route.binding == binding,
                      self.isLiveRouteCurrent(binding, registrationID: route.registrationID) else { return nil }
                return .init(threadID: thread.summary.id, binding: binding,
                             registrationID: route.registrationID, generation: self.enablementGeneration)
            },
            isCurrent: { [weak self] target in
                guard let self else { return false }
                return self.enablementGeneration == target.generation &&
                    self.threadRoutes[target.threadID]?.binding == target.binding &&
                    self.isLiveRouteCurrent(target.binding, registrationID: target.registrationID)
            },
            upload: { [weak self] binding, url in
                guard let upload = self?.onUploadAttachment else { throw CancellationError() }
                return try await upload(binding, url)
            }
        )
        presentation.onAction = { [weak self] action in
            Task { @MainActor [weak self] in
                await self?.perform(action)
            }
        }
        notificationRouter.onRoute = { [weak self] route in
            Task { @MainActor [weak self] in
                self?.enqueueNotificationRoute(route)
            }
        }
    }

    /// Transcript retention tier for this device; Core owns the tier table.
    static var deviceContentBudget: AgentContentBudget {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["TESSERA_AGENT_CONTENT_TIER"] {
        case "compact": return .compact
        case "standard": return .standard
        case "large": return .large
        default: break
        }
        #endif
        return .forDevice(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    func configureSpeech(controller: SpeechDictationController) {
        guard speech == nil else { return }
        speech = AppleAgentSpeechToDraftAdapter(controller: controller)
    }

    /// Enables the runtime only after metadata has been loaded. Disable is a
    /// privacy boundary: runtime content, terminal routes, drafts, durable
    /// metadata, and V2 notifications are all discarded together.
    func setExperimentEnabled(_ enabled: Bool) async {
        // A disabled cold launch still crosses the cleanup boundary: the core
        // runtime is enabled by default for portable use, while this Apple
        // experiment is intentionally opt-in.
        guard enabled != isEnabled || !enabled else { return }
        enablementGeneration &+= 1
        let generation = enablementGeneration
        isEnabled = enabled
        refreshPaneAgentProviders()
        if !enabled { attachments?.cancelAll(); closeIngestionHosts() }
        refreshLiveAttentionCounts()
        if enabled {
            let savedMetadata = await metadata.allMetadata()
            let savedView = await metadata.viewMetadata()
            guard generation == enablementGeneration, isEnabled else { return }
            await runtime.configure(metadata: savedMetadata)
            await runtime.configure(budget: Self.deviceContentBudget)
            await bridge.setGrouping(savedView.grouping)
            await bridge.setFilter(.init(providerIDs: savedView.providerIDs))
            presentation.grouping = savedView.grouping
            presentation.showSystemEvents = savedView.showSystemEvents
            restoredSelection = savedView.lastSelectedThreadID
            guard generation == enablementGeneration, isEnabled else { return }
            await runtime.setEnabled(true)
            guard generation == enablementGeneration, isEnabled else { return }
            for sessionID in sessionRoutes.keys {
                scheduleSessionRefresh(sessionID: sessionID)
                scheduleIntegrationRefresh(sessionID: sessionID)
                startInventory(sessionID: sessionID)
            }
            await synchronizePresentation()
            if let route = notificationRouter.consume() { enqueueNotificationRoute(route) }
            return
        }

        await runtime.setEnabled(false)
        guard generation == enablementGeneration, !isEnabled else { return }
        terminalAdapters.removeAll()
        sessionRefreshTasks.values.forEach { $0.cancel() }
        cancelInitialPrefetches()
        cancelNativeReadRetries()
        ingestionReadFailureCounts.removeAll()
        ingestionManualReadThreads.removeAll()
        projectionTasks.values.forEach { $0.cancel() }
        livePromptWatchTasks.values.forEach { $0.task.cancel() }
        livePromptWatchTasks.removeAll()
        livePromptWatchOutcomes.removeAll()
        livePromptLifecycleSequences.removeAll()
        livePromptFrameTimes.removeAll()
        searchTask?.cancel()
        sessionRefreshTasks.removeAll()
        sessionRefreshTaskIDs.removeAll()
        sessionRefreshQueues.removeAll()
        sessionRefreshInFlight.removeAll()
        sessionLivenessRequested.removeAll()
        sessionDiscoveryAfter.removeAll()
        projectionTasks.removeAll()
        if !presentation.loadingTranscriptThreads.isEmpty { presentation.loadingTranscriptThreads.removeAll() }
        projectionTaskIDs.removeAll()
        pendingProjectionRefreshes.removeAll()
        pendingHistoryRequests.removeAll()
        pendingFillRequests.removeAll()
        pendingLatestRequests.removeAll()
        outgoingReceiptLeases.removeAll()
        searchTask = nil
        projectionRoutes.removeAll()
        initialProjectionRoutes.removeAll()
        inventoryTasks.values.forEach { $0.cancel() }
        inventoryTasks.removeAll()
        inventoryTaskIDs.removeAll()
        inventoryRetryAfter.removeAll()
        cancelInventoryRetries()
        sessionConformingProviders.removeAll()
        await configureRegistryForLiveGates()
        historicalRoutes.removeAll()
        ingestionScopes.removeAll()
        sessionReadCarriers.removeAll()
        threadRoutes.removeAll()
        candidateRoutes.removeAll()
        candidateActionIDs.removeAll()
        validatedLaunchDirectories.removeAll()
        pendingNotificationRoutes.removeAll()
        pauseNotificationRouteRetry()
        lifecycleScanners.removeAll()
        lastLifecycleDeliveries.removeAll()
        foreignLifecyclePIDs.removeAll()
        retiredPaneHolders.removeAll()
        integrationTasks.values.forEach { $0.cancel() }
        integrationActivityTasks.values.forEach { $0.cancel() }
        integrationTasks.removeAll()
        integrationActivityTasks.removeAll()
        pendingIntegrationActivityRegistrations.removeAll()
        if !integrationStates.isEmpty { integrationStates.removeAll() }
        integrationInstallations.removeAll()
        integrationInstallationDates.removeAll()
        integrationFailureCounts.removeAll()
        integrationRefreshNotBefore.removeAll()
        integrationActivityDeadlines.removeAll()
        integrationRetryTasks.values.forEach { $0.cancel() }
        integrationRetryTasks.removeAll()
        integrationGenerations = integrationGenerations.mapValues { $0 &+ 1 }
        swipePadContexts.values.forEach { $0.publish(nil) }
        swipePadContexts.removeAll()
        swipePadFocusedLocations.removeAll()
        launchPort = nil
        speech?.cancel()
        // The cleanup below deletes the document these mirror.
        persistedCompletionKeys.removeAll()
        completionRetries.removeAll()
        completionSweepPending = true
        await AppleAgentExperimentDisableCleanup(
            metadata: metadata,
            notifications: notifications
        ).perform()
        guard generation == enablementGeneration, !isEnabled else { return }
        await bridge.reloadSnapshotsAfterDisable()
        guard generation == enablementGeneration, !isEnabled else { return }
        presentation.clearForExperimentDisable()
        if !boundThreadAttention.isEmpty { boundThreadAttention.removeAll() }
        await synchronizePresentation()
    }

    /// Session-owned code calls this after it has established a canonical core
    /// thread identity and an exact binding. No address or terminal title is
    /// accepted as a substitute identity.
    func register(
        summary: AgentThreadSummary,
        binding: AgentTerminalBinding?,
        terminal: AppleAgentTerminalAdapter? = nil
    ) async {
        guard isEnabled else { return }
        if let terminal { terminalAdapters[summary.id] = terminal }
        await bridge.register(summary, binding: binding)
        await synchronizePresentation()
    }

    func updateHostDisplayLabels(_ labels: [UUID: String]) async {
        await bridge.updateHostDisplayLabels(labels)
        await synchronizePresentation()
    }

    func replaceBinding(
        _ binding: AgentTerminalBinding?,
        terminal: AppleAgentTerminalAdapter?,
        for threadID: AgentThreadID
    ) async {
        guard isEnabled else { return }
        if bridge.threadSnapshots[threadID]?.binding != binding { cancelLivePromptWatch(threadID) }
        if let terminal {
            terminalAdapters[threadID] = terminal
        } else {
            terminalAdapters.removeValue(forKey: threadID)
        }
        await bridge.replaceBinding(binding, for: threadID)
        await synchronizePresentation()
    }

    func apply(page: AgentProjectionPage, to threadID: AgentThreadID, refreshLaunchSuggestions: Bool = true) async -> AgentProjectionApplyResult {
        guard isEnabled else { return .resyncRequired }
        let result = await bridge.apply(page: page, to: threadID)
        if result.accepted { clearNativeReadFailure(threadID) }
        let evicted = await runtime.takeIngestionEvictions()
        for id in evicted { await bridge.refresh(id, refreshList: false) }
        if !evicted.isEmpty { scheduleNativeInterests() }
        if DiagnosticLogStore.isVerboseEnabled {
            let snapshot = bridge.threadSnapshots[threadID]
            DiagnosticLogStore.appendAgentCenter("v2-page provider=\(threadID.providerID.rawValue) result=\(result) older=\(page.from != nil) incoming=\(page.records.count) messages=\(snapshot?.messages.count ?? 0) continued=\(page.summary?.objectValue?["continuedFrom"] != nil) hasMore=\(snapshot?.hasMore ?? false)")
        }
        await synchronizePresentation(refreshLaunchSuggestions: refreshLaunchSuggestions)
        return result
    }

    func installLaunchPort(_ port: any AgentLaunchPort) {
        launchPort = port
    }

    func removeRoutes(for threadID: AgentThreadID) {
        terminalAdapters.removeValue(forKey: threadID)
        cancelLivePromptWatch(threadID)
    }

    /// Notification payloads contain only opaque route tokens. Resolution is
    /// performed against protected metadata, then the live runtime is asked
    /// to select the canonical thread ID; no notification ever carries a
    /// terminal address, transcript locator, or provider session string.
    func receiveNotification(userInfo: [AnyHashable: Any]) {
        notificationRouter.receive(userInfo: userInfo)
    }

    func consumeColdStartNotifications() async {
        for route in AppleAgentNotificationInbox.shared.consumeAll() {
            enqueueNotificationRoute(route)
        }
    }

    func scheduleAttention(
        for threadID: AgentThreadID,
        sceneAllowsDelivery: Bool,
        presentation notificationPresentation: AppleAgentNotificationPresentation = .init()
    ) async {
        defer {
            AgentAttentionBackgroundKeepAlive.shared.notificationProcessingFinished(
                reason: "agent-v2-schedule-finished"
            )
        }
        guard isEnabled,
              let token = try? await metadata.routeToken(for: threadID),
              let event = await runtime.attentionEvent(for: threadID, routeToken: token),
              // Discovery re-schedules on every pass and each frame bumps the
              // generation; the same attention alerts once and keeps the
              // delivered notification's fence.
              notifications.needsAlert(event)
        else { return }
        // Commit the generation fence before the OS can present the opaque
        // token. A delivered notification must never outlive its durable
        // validity record across a process restart.
        do {
            invalidatedAttentionThreads.remove(threadID)
            try await metadata.saveNotificationGeneration(
                event.deliveryGeneration,
                for: threadID
            )
        } catch {
            return
        }
        _ = await notifications.schedule(
            event,
            presentation: notificationPresentation,
            sceneAllowsDelivery: sceneAllowsDelivery
        )
    }

    func configureNotificationDelivery(enabled: Bool, applicationActive: Bool) async {
        notificationsEnabled = enabled
        self.applicationActive = applicationActive
        if !enabled || applicationActive {
            notifications.withdraw(routeTokens: await metadata.allRouteTokens())
        }
    }

    func scheduleAttentionIfNeeded(for threadID: AgentThreadID) async {
        guard notificationsEnabled, !applicationActive else { return }
        await scheduleAttention(for: threadID, sceneAllowsDelivery: true)
    }

    /// Lifecycle discovery is the authoritative signal that a previously
    /// notified thread no longer needs attention. Advance the protected
    /// generation before removing the OS notification so a stale delivered
    /// tap cannot revive it after a cold restart.
    func invalidateAttentionIfPresent(for threadID: AgentThreadID) async {
        guard invalidatedAttentionThreads.insert(threadID).inserted else { return }
        guard let record = await metadata.metadata(for: threadID),
              let rawToken = record.routeToken,
              let generation = await metadata.notificationGeneration(for: threadID)
        else { return }
        let token = AgentRouteToken(rawValue: rawToken)
        notifications.withdraw(routeTokens: [token])
        do { try await metadata.saveNotificationGeneration(generation &+ 1, for: threadID) }
        catch { invalidatedAttentionThreads.remove(threadID) }
    }

    private func perform(_ action: AgentCenterV2PresentationModel.Action) async {
        defer {
            if case .send(let request) = action { presentation.finishSend(request) }
        }
        guard isEnabled else {
            presentation.reportUnavailable("Agent Center is disabled in Experimental Settings.")
            return
        }
        switch action {
        case .answer, .interrupt, .openTerminal,
             .openCandidateTerminal, .answerCandidate, .beginDictation, .launch:
            presentation.invalidateSendAnyway()
        default: break
        }
        switch action {
        case .cardVisibility(let thread, let visible):
            // Unclamped, so the count commutes: each action runs in its own task.
            let count = ingestionVisibleCardCounts[thread, default: 0] + (visible ? 1 : -1)
            ingestionVisibleCardCounts[thread] = count == 0 ? nil : count
            if count > 0 { ingestionVisibleCards.insert(thread) } else { ingestionVisibleCards.remove(thread) }
            if count == 0, !ingestionOpenDetails.contains(thread), presentation.selectedThreadID != thread {
                ingestionReadRetryTasks.removeValue(forKey: thread)?.task.cancel()
            }
            scheduleNativeInterests()
        case .detailVisibility(let thread, let visible):
            if visible { ingestionOpenDetails.insert(thread) } else { ingestionOpenDetails.remove(thread) }
            if visible { startLivePromptWatch(thread) }
            if !visible {
                cancelInitialPrefetch(thread)
                ingestionReadRetryTasks.removeValue(forKey: thread)?.task.cancel()
            }
            scheduleNativeInterests()
        case .select(let threadID):
            cancelInitialPrefetches(except: threadID)
            clearNativeReadFailure(threadID)
            await bridge.select(threadID: threadID)
            projectHistoricalIfNeeded(threadID)
            await persistViewMetadata(lastSelectedThreadID: threadID)
            publishIntegrationNotice(
                preferredSessionID: presentation.threadSnapshots[threadID]?.binding?.liveSessionID,
                allowFallback: false
            )

        case .selectCandidate(let candidateID):
            cancelInitialPrefetches()
            await bridge.select(threadID: nil)
            let sessionID = presentation.listSnapshot.candidates
                .first(where: { $0.id == candidateID })?
                .fallback.binding.liveSessionID
            publishIntegrationNotice(preferredSessionID: sessionID, allowFallback: false)

        case .search(let query):
            scheduleSearch(query: query)

        case .setGrouping(let grouping):
            await bridge.setGrouping(grouping)
            await persistViewMetadata(grouping: grouping)
            await synchronizePresentation()

        case .setShowSystemEvents(let showSystemEvents):
            await persistViewMetadata(showSystemEvents: showSystemEvents)

        case .setTitleCharacterBudget(let characters):
            await bridge.setTitleCharacterBudget(characters)
            await synchronizePresentation()

        case .answer(let threadID, let token, let goal):
            await answer(threadID: threadID, token: token, goal: goal)

        case .send(let request):
            cancelInitialPrefetch(request.threadID)
            guard presentation.pendingSends[request.threadID] == request.id,
                  presentation.threadSnapshots[request.threadID]?.binding == request.binding else {
                presentation.reportActionError(.staleBinding)
                return
            }
            if request.composerVerification == .userOverride,
               (presentation.selectedThreadID != request.threadID
                || presentation.draftBinding(for: request.threadID) != request.draftToReplace) {
                presentation.reportUnavailable("The draft changed before sending. Review it and send again.")
                return
            }
            await send(request)

        case .interrupt(let threadID):
            await interrupt(threadID: threadID)

        case .openTerminal(let threadID):
            await openTerminal(threadID: threadID)

        case .openCandidateTerminal(let candidateID):
            await openCandidateTerminal(candidateID)

        case .answerCandidate(let candidateID, let token, let optionID):
            await answerCandidate(candidateID, token: token, optionID: optionID)

        case .beginDictation(let threadID):
            await beginDictation(for: threadID)

        case .requestOlderPage(let threadID):
            requestOlderPage(threadID)
        case .fillOlderPage(let threadID):
            requestOlderPage(threadID, fill: true)
        case .requestNewerPage(let threadID):
            requestNewerPage(threadID)
        case .retainBridgedRows(let threadID):
            requestNewerPage(threadID, bridge: true)
        case .returnToLatest(let threadID):
            requestNewerPage(threadID, latest: true)
        case .viewportAnchor(let threadID, let recordID):
            await runtime.setIngestionViewportAnchor(recordID, for: threadID)
        case .refreshTranscript(let threadID):
            refreshVisibleTranscript(threadID)

        case .newestRecordVisible(let threadID, let recordID):
            await acknowledgeVisibleNewest(threadID: threadID, recordID: recordID)

        case .completionVisible(let threadID, let attentionEpoch):
            await acknowledgeVisibleCompletion(threadID: threadID, attentionEpoch: attentionEpoch)

        case .launch(let intent):
            await launch(intent)

        case .fixIntegration(let sessionID, let action):
            fixIntegration(sessionID: sessionID, requestedAction: action)
        }
    }

    /// Projection reads are surface-scoped. Lifecycle discovery deliberately
    /// remains active in the background so finite attention work can still be
    /// scheduled, but transcript/search channels are cancelled immediately.
    func setApplicationActive(_ active: Bool) async {
        applicationActive = active
        guard isEnabled else { return }
        if active {
            inventoryRetryAfter.removeAll()
            notifications.withdraw(routeTokens: await metadata.allRouteTokens())
            guard applicationActive, isEnabled else { return }
            for sessionID in sessionRoutes.keys { scheduleIntegrationRefresh(sessionID: sessionID) }
            // An agent may have exited while the app was away. Sweep its
            // processes now; a full pass would also re-check focused panes.
            for sessionID in sessionRoutes.keys where threadRoutes.values.contains(where: {
                $0.binding.liveSessionID == sessionID && $0.binding.agentPID != nil
            }) {
                scheduleLivenessSweep(sessionID: sessionID)
            }
            if hasSurfaceDemand {
                for sessionID in sessionRoutes.keys {
                    // Same reason as `setSurfaceDemand`: a backgrounded app
                    // kept discovering on the unattended floor, and coming back
                    // to a visible surface is the moment that floor stops
                    // applying.
                    sessionDiscoveryAfter.removeValue(forKey: sessionID)
                    scheduleSessionRefresh(sessionID: sessionID)
                    startInventory(sessionID: sessionID)
                }
            }
            for snapshot in presentation.threadSnapshots.values where snapshot.summary.livePromptWatch == true {
                startLivePromptWatch(snapshot.summary.id)
            }
            for threadID in ingestionOpenDetails { startLivePromptWatch(threadID) }
            if !pendingNotificationRoutes.isEmpty { startNotificationRouteRetry() }
            return
        }
        pauseIntegrationChecks()
        cancelInitialPrefetches()
        cancelNativeReadRetries()
        closeIngestionHosts()
        cancelInventoryRetries()
        inventoryTasks.values.forEach { $0.cancel() }
        inventoryTasks.removeAll()
        inventoryTaskIDs.removeAll()
        projectionTasks.values.forEach { $0.cancel() }
        projectionTasks.removeAll()
        livePromptWatchTasks.values.forEach { $0.task.cancel() }
        livePromptWatchTasks.removeAll()
        if !presentation.loadingTranscriptThreads.isEmpty { presentation.loadingTranscriptThreads.removeAll() }
        projectionTaskIDs.removeAll()
        pendingProjectionRefreshes.removeAll()
        pendingHistoryRequests.removeAll()
        pendingFillRequests.removeAll()
        pendingLatestRequests.removeAll()
        outgoingReceiptLeases.removeAll()
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        presentation.isSearching = false
        pauseNotificationRouteRetry()
    }

    func setSurfaceDemand(_ demanded: Bool) {
        guard demanded != hasSurfaceDemand else { return }
        DiagnosticLogStore.appendAgentCenter("latency-agent-v3 surfaceDemand=\(demanded) enabled=\(isEnabled)")
        hasSurfaceDemand = demanded
        if demanded {
            for threadID in ingestionOpenDetails { startLivePromptWatch(threadID) }
            inventoryRetryAfter.removeAll()
            for sessionID in sessionRoutes.keys {
                // A closed surface discovers on a sixty-second floor. Opening
                // one must not inherit the remainder of that wait: drop each
                // session's cooldown and ask once, or the list the user just
                // opened can be a minute out of date before it refreshes.
                sessionDiscoveryAfter.removeValue(forKey: sessionID)
                scheduleSessionRefresh(sessionID: sessionID)
                startInventory(sessionID: sessionID)
            }
        } else {
            cancelInitialPrefetches()
            cancelNativeReadRetries()
            closeIngestionHosts()
            cancelInventoryRetries()
            inventoryTasks.values.forEach { $0.cancel() }
            inventoryTasks.removeAll()
            inventoryTaskIDs.removeAll()
            projectionTasks.values.forEach { $0.cancel() }
            projectionTasks.removeAll()
            if !presentation.loadingTranscriptThreads.isEmpty { presentation.loadingTranscriptThreads.removeAll() }
            projectionTaskIDs.removeAll()
            pendingProjectionRefreshes.removeAll()
            pendingHistoryRequests.removeAll()
            pendingFillRequests.removeAll()
            pendingLatestRequests.removeAll()
            outgoingReceiptLeases.removeAll()
            searchTask?.cancel()
            searchTask = nil
            searchGeneration &+= 1
        }
    }

    /// One shared post-await proof for terminal mutations and launch. The
    /// route maps are cleared at the experimental-off boundary, so this also
    /// makes an in-flight operation fail closed after disable.
    func isLiveRouteCurrent(
        _ binding: AgentTerminalBinding,
        registrationID: UUID
    ) -> Bool {
        isEnabled
            && sessionRoutes[binding.liveSessionID]?.source.registrationID == registrationID
            && threadRoutes.values.contains { route in
                route.registrationID == registrationID && route.binding == binding
            }
    }

    func isSessionRegistrationCurrent(_ sessionID: UUID, registrationID: UUID) -> Bool {
        isEnabled && sessionRoutes[sessionID]?.source.registrationID == registrationID
    }

    func isSessionReadCarrierCurrent(
        _ binding: AgentTerminalBinding,
        registrationID: UUID
    ) -> Bool {
        isEnabled
            && applicationActive
            && hasSurfaceDemand
            && sessionRoutes[binding.liveSessionID]?.source.registrationID == registrationID
            && sessionReadCarriers[binding.liveSessionID] == binding
    }

    /// A session-owned terminal asks for this once and keeps the reference for
    /// its lifetime. The published value is equality-gated by the context, so
    /// output chatter in another pane cannot repaint this SwipePad.
    func swipePadContext(sessionID: UUID) -> SwipePadAgentContext {
        if let existing = swipePadContexts[sessionID] { return existing }
        let context = SwipePadAgentContext()
        context.onAnswer = { [weak self] displayed, option in
            guard let self, self.isEnabled, self.applicationActive,
                  self.swipePadContexts[sessionID]?.snapshot == displayed,
                  let prompt = displayed.prompt,
                  prompt.options.contains(option),
                  let snapshot = self.presentation.threadSnapshots.values.first(where: {
                      $0.binding?.liveSessionID == sessionID &&
                      $0.binding?.paneID == displayed.agentID.paneID.map(String.init) &&
                      $0.summary.id.providerSessionID == displayed.providerSessionID
                  }),
                  let action = self.latestPrompt(in: snapshot),
                  action.token.rawValue == prompt.signature
            else { return }
            await self.answer(threadID: snapshot.summary.id, token: action.token, goal: .option(String(option.id)))
        }
        swipePadContexts[sessionID] = context
        return context
    }

    func setSwipePadFocus(sessionID: UUID, paneID: Int?) {
        swipePadFocusedLocations[sessionID] = .init(paneID: paneID)
        publishSwipePadEvidence(for: sessionID)
    }

    func clearSwipePadFocus(sessionID: UUID) {
        swipePadFocusedLocations.removeValue(forKey: sessionID)
        swipePadContexts[sessionID]?.publish(nil)
    }

    /// The scroll gate is intentionally a small platform policy over V2
    /// evidence, not a second lifecycle reducer. A pane can only be blocked
    /// when the currently focused, hook-proven process is still working.
    func scrollPrevention(
        sessionID: UUID,
        paneID: Int?,
        claudeCodeEnabled: Bool,
        codexEnabled: Bool
    ) -> AgentScrollPrevention? {
        guard isEnabled,
              swipePadFocusedLocations[sessionID] == .init(paneID: paneID),
              let snapshot = swipePadContexts[sessionID]?.snapshot,
              snapshot.status == .working,
              snapshot.agentID.paneID == paneID
        else { return nil }
        let enabled = snapshot.profileID == SwipePadProfile.builtInClaudeCodeID
            ? claudeCodeEnabled
            : snapshot.profileID == SwipePadProfile.builtInCodexCLIID
                ? codexEnabled
                : false
        guard enabled else { return nil }
        return AgentScrollPrevention(agentID: snapshot.agentID, agentName: snapshot.profileName)
    }

    /// Lightweight presentation evidence for existing host/session chrome.
    /// It exposes no transcript content and keeps the list's canonical core
    /// thread identity separate from terminal routing details.
    func sessionAttention(sessionID: UUID, windowID: Int? = nil) -> (hasAgent: Bool, needsInput: Bool, unreadCompletion: Bool, total: Int) {
        guard isEnabled else { return (false, false, false, 0) }
        let threads = boundThreadAttention.values.filter { thread in
            thread.sessionID == sessionID && (windowID == nil || thread.windowID == windowID.map(String.init))
        }
        return (
            !threads.isEmpty,
            threads.contains(where: \.needsInput),
            threads.contains(where: \.unreadCompletion),
            threads.count
        )
    }

    /// The verified agent bound to one terminal, for merging with the
    /// program status that agent reports itself (OSC 7501). `paneID` is nil
    /// for a raw SSH or mosh terminal.
    func paneAgentAttention(sessionID: UUID, paneID: Int?) -> (needsInput: Bool, unreadCompletion: Bool)? {
        guard isEnabled else { return nil }
        let pane = paneID.map(String.init)
        let threads = boundThreadAttention.values.filter { $0.sessionID == sessionID && $0.paneID == pane }
        guard !threads.isEmpty else { return nil }
        return (threads.contains(where: \.needsInput), threads.contains(where: \.unreadCompletion))
    }

    private struct PaneAgentKey: Hashable {
        let sessionID: UUID
        let paneID: String
    }

    /// Chrome observes only provider changes, not transcript publications.
    private var paneAgentProviders: [PaneAgentKey: AgentProviderID] = [:]

    /// Provider identity for a pane with a current registered thread route.
    func paneAgentProvider(sessionID: UUID, paneID: Int) -> String? {
        paneAgentProviders[.init(sessionID: sessionID, paneID: String(paneID))]?.rawValue
    }

    private func refreshPaneAgentProviders() {
        var providers: [PaneAgentKey: AgentProviderID] = [:]
        var ambiguous = Set<PaneAgentKey>()
        if isEnabled {
            for (threadID, route) in threadRoutes {
                let binding = route.binding
                guard let paneID = binding.paneID,
                      presentation.threadSnapshots[threadID]?.binding == binding,
                      isSessionRegistrationCurrent(binding.liveSessionID, registrationID: route.registrationID)
                else { continue }
                let key = PaneAgentKey(sessionID: binding.liveSessionID, paneID: paneID)
                if let previous = providers[key], previous != threadID.providerID { ambiguous.insert(key) }
                providers[key] = threadID.providerID
            }
        }
        for key in ambiguous { providers[key] = nil }
        if paneAgentProviders != providers { paneAgentProviders = providers }
    }

    /// Every terminal of one session with a verified agent, one entry per
    /// pane (nil pane: the raw terminal), for chrome that merges agents with
    /// program status per terminal.
    func boundAgentTerminals(sessionID: UUID) -> [(windowID: Int?, paneID: Int?, needsInput: Bool, unreadCompletion: Bool)] {
        guard isEnabled else { return [] }
        var byPane: [String?: (windowID: Int?, needsInput: Bool, unreadCompletion: Bool)] = [:]
        for thread in boundThreadAttention.values where thread.sessionID == sessionID {
            let previous = byPane[thread.paneID]
            byPane[thread.paneID] = (
                previous?.windowID ?? thread.windowID.flatMap(Int.init),
                (previous?.needsInput ?? false) || thread.needsInput,
                (previous?.unreadCompletion ?? false) || thread.unreadCompletion
            )
        }
        return byPane.map { pane, value in
            (value.windowID, pane.flatMap(Int.init), value.needsInput, value.unreadCompletion)
        }
    }

    /// A bound thread's chrome state, kept per publish from the snapshots
    /// that changed. Chrome observes this rather than every snapshot, so a
    /// transcript publish neither redraws it nor scans inventoried threads.
    private struct BoundThreadAttention: Equatable {
        let sessionID: UUID
        let windowID: String?
        let paneID: String?
        let needsInput: Bool
        let unreadCompletion: Bool
    }
    private var boundThreadAttention: [AgentThreadID: BoundThreadAttention] = [:]

    private func refreshBoundThreadAttention(_ changed: [AgentThreadSnapshot]) {
        guard isEnabled else {
            if !boundThreadAttention.isEmpty { boundThreadAttention.removeAll() }
            return
        }
        for snapshot in changed {
            let attention = snapshot.binding.map { binding in
                BoundThreadAttention(sessionID: binding.liveSessionID, windowID: binding.windowID,
                    paneID: binding.paneID,
                    needsInput: snapshot.summary.attention == .needsYou || snapshot.summary.status == .waitingForInput,
                    unreadCompletion: snapshot.summary.attention == .unreadCompletion)
            }
            if boundThreadAttention[snapshot.summary.id] != attention { boundThreadAttention[snapshot.summary.id] = attention }
        }
        // Changes never report a removed thread (Core migrates identities);
        // the index holds bound threads only, so checking each is cheap.
        let removed = boundThreadAttention.keys.filter { bridge.threadSnapshots[$0] == nil }
        for threadID in removed { boundThreadAttention[threadID] = nil }
    }

    var attentionBadgeCounts: (waiting: Int, finished: Int, working: Int, total: Int) {
        guard isEnabled else { return (0, 0, 0, 0) }
        let counts = liveAttentionCounts
        return (counts.waiting, counts.finished, counts.working, counts.total)
    }

    struct LiveAttentionCounts: Equatable {
        var waiting = 0
        var finished = 0
        var working = 0
        var total = 0
    }

    /// Badges, the attention chip and the background keep-alive count every
    /// live agent. The Agent Center list is the wrong source: its search and
    /// provider filter persist after the user leaves it. Equality-gated, so
    /// chrome observing it redraws only when a count moves.
    private(set) var liveAttentionCounts = LiveAttentionCounts()

    /// Every live thread, unfiltered: the list's rows plus any registered live
    /// route the list's filter hides. Empty while Agent Center is disabled.
    private func liveThreadSummaries() -> [AgentThreadSummary] {
        guard isEnabled else { return [] }
        var seen = Set<AgentThreadID>()
        var summaries = presentation.listSnapshot.threads.filter { seen.insert($0.id).inserted }
        for threadID in threadRoutes.keys where seen.insert(threadID).inserted {
            if let summary = presentation.threadSnapshots[threadID]?.summary { summaries.append(summary) }
        }
        return summaries
    }

    private func refreshLiveAttentionCounts() {
        let summaries = liveThreadSummaries()
        // Core's classifier, so the chip's count matches its jump list.
        let attention = AgentAttentionCounts(threads: summaries)
        let counts = LiveAttentionCounts(
            waiting: attention.needsInput,
            finished: attention.finished,
            working: summaries.count { $0.status == .working },
            total: summaries.count
        )
        if liveAttentionCounts != counts { liveAttentionCounts = counts }
    }

    /// Rows behind the terminal chrome's attention chip. A row targets its
    /// terminal only while the exact binding is still backed by a registered
    /// live route; otherwise it can only be reviewed in Agent Center.
    func attentionEntries() -> [AgentAttentionEntry] {
        AgentAttentionTargets.entries(
            threads: liveThreadSummaries(),
            binding: { presentation.threadSnapshots[$0]?.binding },
            isLive: { threadID, binding in
                guard terminalAdapters[threadID] != nil,
                      let route = threadRoutes[threadID],
                      route.binding == binding
                else { return false }
                return isLiveRouteCurrent(binding, registrationID: route.registrationID)
            }
        )
    }

    /// The attention chip's "open pane": the same exact-binding path as Agent
    /// Center's open pane, which re-proves the agent's process in that pane
    /// before focusing it and only selects an already-live session. Returns
    /// false without moving focus when the pane can no longer be proven.
    func revealAttentionTerminal(threadID: AgentThreadID) async -> Bool {
        guard isEnabled else { return false }
        let binding = presentation.threadSnapshots[threadID]?.binding
        let opened = await openTerminal(threadID: threadID)
        DiagnosticLogStore.appendAgentCenter(
            "attention-jump provider=\(threadID.providerID.rawValue) transport=\(binding?.transport.rawValue ?? "none") result=\(opened ? "revealed" : "unavailable")"
        )
        // Visiting the pane is what marks a completion seen. A pane that
        // already had focus reports no focus change, so re-check it now.
        if opened, let binding { publishSwipePadEvidence(for: binding.liveSessionID) }
        return opened
    }

    /// Shows one attention thread in Agent Center: the chip row's own tap, and
    /// the fallback when its terminal is gone. Never starts a connection.
    func reviewAttentionThread(_ threadID: AgentThreadID) {
        guard isEnabled else { return }
        presentation.select(threadID)
        presentation.requestNarrowThreadNavigation(threadID)
        onRevealThread?(threadID)
    }

    func publishSwipePadEvidence(for sessionID: UUID) {
        guard let focus = swipePadFocusedLocations[sessionID] else {
            swipePadContexts[sessionID]?.publish(nil)
            return
        }
        let focusedPaneID = focus.paneID
        let match = presentation.threadSnapshots.values.first { snapshot in
            snapshot.binding?.liveSessionID == sessionID
                && snapshot.binding?.paneID == focusedPaneID.map(String.init)
        }
        guard let snapshot = match,
              let binding = snapshot.binding,
              let route = threadRoutes[snapshot.summary.id],
              route.binding == binding
        else {
            swipePadContexts[sessionID]?.publish(nil)
            return
        }
        if applicationActive, snapshot.summary.attention == .unreadCompletion {
            Task { @MainActor [weak self] in
                guard let self, self.applicationActive,
                      self.swipePadFocusedLocations[sessionID] == .init(paneID: focusedPaneID),
                      await self.runtime.acknowledgeTerminal(threadID: snapshot.summary.id,
                        binding: binding, observedGeneration: snapshot.deliveryGeneration) else { return }
                await self.invalidateAttentionIfPresent(for: snapshot.summary.id)
                if let recordID = snapshot.messages.last?.recordID {
                    var durable = await self.metadata.metadata(for: snapshot.summary.id) ?? AgentThreadMetadata(threadID: snapshot.summary.id)
                    durable.lastReadRecordID = recordID
                    try? await self.metadata.save(durable)
                }
                await self.bridge.refresh(snapshot.summary.id)
                await self.synchronizePresentation()
                self.publishSwipePadEvidence(for: sessionID)
            }
        }
        let profileName = route.profile.name
        let legacyStatus: AgentStatus = switch snapshot.summary.status {
        case .idle: .idle
        case .working: .working
        case .waitingForInput: .waitingForInput
        case .finished: .justFinished
        case .unavailable: .unavailable
        }
        let prompt = snapshot.messages.reversed().flatMap(\.blocks).compactMap { block -> AgentPrompt? in
            guard case .actionPrompt(let action) = block else { return nil }
            let options = action.options.enumerated().compactMap { index, option -> AgentPromptOption? in
                let ordinal = index + 1
                return AgentPromptOption(
                    id: ordinal,
                    label: option.label,
                    responseMacro: option.id,
                    isDefault: option.isDefault
                )
            }
            guard !options.isEmpty else { return nil }
            return AgentPrompt(signature: action.token.rawValue, summary: action.title, options: options)
        }.first
        swipePadContext(sessionID: sessionID).publish(
            SwipePadAgentSnapshot(
                agentID: AgentInstanceID(sessionID: sessionID, paneID: focusedPaneID),
                profileID: route.profile.id,
                profileName: profileName,
                status: legacyStatus,
                prompt: legacyStatus == .waitingForInput ? prompt : nil,
                statusChangedAt: snapshot.summary.lastActivity ?? .now,
                detectedAt: snapshot.summary.lastActivity ?? .now,
                providerSessionID: snapshot.summary.id.providerSessionID,
                agentPID: binding.agentPID
            )
        )
    }

    /// Transcript blocks are private, reconstructible cache data. Evict them
    /// at the OS memory-warning boundary while retaining durable metadata and
    /// live bindings.
    func handleMemoryWarning() async {
        guard isEnabled else { return }
        cancelInitialPrefetches()
        cancelNativeReadRetries()
        closeIngestionHosts()
        projectionTasks.values.forEach { $0.cancel() }
        projectionTasks.removeAll()
        if !presentation.loadingTranscriptThreads.isEmpty { presentation.loadingTranscriptThreads.removeAll() }
        projectionTaskIDs.removeAll()
        pendingProjectionRefreshes.removeAll()
        pendingHistoryRequests.removeAll()
        pendingFillRequests.removeAll()
        pendingLatestRequests.removeAll()
        outgoingReceiptLeases.removeAll()
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        await runtime.memoryWarning()
        _ = await runtime.takeIngestionEvictions()
        presentation.discardTranscriptLayoutCache()
        for id in bridge.threadSnapshots.keys {
            await bridge.refresh(id, refreshList: false)
        }
        await synchronizePresentation()
    }

    private enum NotificationRouteResult { case routed, retry, discard }

    private func enqueueNotificationRoute(_ route: AppleAgentNotificationRoute) {
        pendingNotificationRoutes.removeAll { $0.token == route.token && $0.generation <= route.generation }
        pendingNotificationRoutes.append(route)
        if pendingNotificationRoutes.count > 8 {
            pendingNotificationRoutes.removeFirst(pendingNotificationRoutes.count - 8)
        }
        guard isEnabled else { return }
        for sessionID in sessionRoutes.keys { scheduleSessionRefresh(sessionID: sessionID) }
        startNotificationRouteRetry()
    }

    func resolvePendingNotificationRoutes() async {
        guard isEnabled, applicationActive, !pendingNotificationRoutes.isEmpty else { return }
        var retained: [AppleAgentNotificationRoute] = []
        for route in pendingNotificationRoutes {
            switch await routeNotification(route) {
            case .routed, .discard: break
            case .retry: retained.append(route)
            }
        }
        pendingNotificationRoutes = retained
    }

    func startNotificationRouteRetry() {
        guard notificationRetryTask == nil,
              AgentCenterV2NotificationRetryPolicy.shouldRun(
                  isEnabled: isEnabled,
                  applicationActive: applicationActive,
                  hasPendingRoute: !pendingNotificationRoutes.isEmpty,
                  hasSessionSource: !sessionRoutes.isEmpty
              )
        else { return }
        notificationRetryGeneration &+= 1
        let generation = notificationRetryGeneration
        notificationRetryTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.notificationRetryGeneration == generation {
                    self.notificationRetryTask = nil
                }
            }
            // Do not discard a cold-start token merely because session restore
            // or remote discovery takes longer than an arbitrary retry window.
            // The queue is bounded and opaque; a later registered owner wakes
            // the loop, and disable clears it at the privacy boundary.
            while true {
                guard !Task.isCancelled,
                      let self,
                      AgentCenterV2NotificationRetryPolicy.shouldRun(
                          isEnabled: self.isEnabled,
                          applicationActive: self.applicationActive,
                          hasPendingRoute: !self.pendingNotificationRoutes.isEmpty,
                          hasSessionSource: !self.sessionRoutes.isEmpty
                      )
                else { return }
                await self.resolvePendingNotificationRoutes()
                guard !self.pendingNotificationRoutes.isEmpty else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pauseNotificationRouteRetry() {
        notificationRetryGeneration &+= 1
        notificationRetryTask?.cancel()
        notificationRetryTask = nil
    }

    private func routeNotification(_ route: AppleAgentNotificationRoute) async -> NotificationRouteResult {
        guard isEnabled, applicationActive, !Task.isCancelled else { return .retry }
        guard let threadID = await metadata.resolve(route.token) else { return .discard }
        // Runtime delivery counters are intentionally volatile. A process
        // restart rebuilds them from fresh lifecycle frames, so the durable
        // opaque-token fence is the sole cold-start generation authority.
        guard await metadata.notificationGeneration(for: threadID) == route.generation else {
            return .discard
        }
        guard let binding = presentation.threadSnapshots[threadID]?.binding else {
            // A cold tap may arrive before the session owner has rediscovered
            // the canonical thread. Keep only the opaque token and ask every
            // already-owned carrier to refresh; never infer a route from
            // persisted metadata.
            for sessionID in sessionRoutes.keys { scheduleSessionRefresh(sessionID: sessionID) }
            return .retry
        }
        scheduleSessionRefresh(sessionID: binding.liveSessionID)
        try? await Task.sleep(for: .milliseconds(120))
        guard applicationActive, !Task.isCancelled else { return .retry }
        guard presentation.threadSnapshots[threadID]?.binding == binding,
              let route = threadRoutes[threadID],
              route.binding == binding,
              sessionRoutes[binding.liveSessionID]?.source.registrationID == route.registrationID
        else { return .retry }
        guard await currentBindingIsProven(threadID: threadID, binding: binding) else {
            return .retry
        }
        presentation.requestNarrowThreadNavigation(threadID)
        await bridge.select(threadID: threadID)
        await synchronizePresentation()
        onNotificationThreadSelected?(threadID)
        return .routed
    }

    private func acknowledgeVisibleNewest(threadID: AgentThreadID, recordID: String) async {
        guard presentation.selectedThreadID == threadID,
              presentation.threadSnapshots[threadID]?.messages.last?.recordID == recordID,
              // The tail reports visibility on every scroll frame.
              await runtime.needsAcknowledgement(threadID: threadID, visibleRecordID: recordID)
        else { return }
        let pendingEvent: AgentAttentionEvent? = if let token = try? await metadata.routeToken(for: threadID) {
            await runtime.attentionEvent(for: threadID, routeToken: token)
        } else {
            nil
        }
        await bridge.acknowledge(threadID: threadID, visibleRecordID: recordID)
        var durable = await metadata.metadata(for: threadID) ?? AgentThreadMetadata(threadID: threadID)
        durable.lastReadRecordID = recordID
        try? await metadata.save(durable)
        if let pendingEvent {
            notifications.invalidate(pendingEvent)
            try? await metadata.saveNotificationGeneration(
                pendingEvent.deliveryGeneration &+ 1,
                for: threadID
            )
        }
        await synchronizePresentation()
    }

    /// A finish is read once the reader sees the thread's live end, whether or
    /// not it produced a record. Core fences the read to the epoch on screen.
    private func acknowledgeVisibleCompletion(threadID: AgentThreadID, attentionEpoch: UInt64) async {
        guard presentation.selectedThreadID == threadID,
              await bridge.acknowledgeCompletion(threadID: threadID, observedEpoch: attentionEpoch)
        else { return }
        await invalidateAttentionIfPresent(for: threadID)
        await synchronizePresentation()
    }

    private func answer(threadID: AgentThreadID, token: AgentActionToken, goal: AgentPromptAnswerGoal) async {
        guard !presentation.answeringPromptThreads.contains(threadID) else { return }
        presentation.answeringPromptThreads.insert(threadID)
        defer { presentation.answeringPromptThreads.remove(threadID) }
        guard let snapshot = presentation.threadSnapshots[threadID],
              let binding = snapshot.binding,
              binding.capabilities.contains(.promptAnswer),
              let terminal = terminalAdapters[threadID],
              let prompt = latestPrompt(in: snapshot), prompt.token == token
        else {
            presentation.reportUnavailable("This prompt is no longer available on its original terminal.")
            return
        }
        do {
            let observation = try await terminal.observe(binding: binding)
            let optionID: String
            switch goal.kind {
            case .option: optionID = goal.optionID ?? ""
            case .text: optionID = prompt.options.first(where: { $0.acceptsText == true })?.id ?? "text"
            case .control: optionID = goal.control?.rawValue ?? ""
            }
            guard let signature = observation.prompt?.signature,
                  token == AgentPromptGrammar.actionToken(for: signature),
                  goal.isValid,
                  let request = AgentPromptAnswerRequest(
                    threadID: threadID,
                    binding: binding,
                    actionToken: token,
                    expectedSignature: signature,
                    optionID: optionID,
                    text: goal.text,
                    control: goal.control
                  )
            else {
                presentation.reportActionError(.stalePrompt)
                return
            }
            handle(await bridge.answer(request, observation: observation, terminal: terminal), promptAnswer: true)
        } catch {
            presentation.reportActionError((error as? AgentActionError) ?? .unavailable, promptAnswer: true)
        }
    }

    private func send(_ composer: AgentCenterV2PresentationModel.ComposerSend) async {
        let threadID = composer.threadID, text = composer.text
        guard presentation.threadSnapshots[threadID]?.conversationEnded != true else {
            presentation.reportConversationEnded()
            return
        }
        guard let binding = presentation.threadSnapshots[threadID]?.binding,
              binding.capabilities.contains(.send),
              let terminal = terminalAdapters[threadID],
              let request = AgentTextSendRequest(
                threadID: threadID,
                binding: binding,
                text: text,
                queueWhenWorking: composer.queueWhenWorking,
                composerVerification: composer.composerVerification
              )
        else {
            presentation.reportUnavailable("Sending is unavailable because this terminal is no longer live.")
            return
        }
        var notSent: (refusal: AppleAgentSendNotWritten, draft: AgentCenterV2PresentationModel.NotSentDraft)?
        // Disabling purges drafts; a refusal that lands afterwards must not
        // put the message back.
        let generation = enablementGeneration
        var clearedDraft = false
        let result = await bridge.submit(request, terminal: terminal, requestedAt: composer.requestedAt, prepareReceipt: { [self] lease in
            try await prepareOutgoingReceipt(lease)
        }, onAccepted: { [self] in
            if presentation.draftBinding(for: threadID) == composer.draftToReplace {
                presentation.setDraft(composer.replacementDraft, for: threadID)
                clearedDraft = true
            }
            // Publish the optimistic bubble before sending, but don't wait for
            // unrelated remote launch-directory suggestions on every session.
            await synchronizePresentation(refreshLaunchSuggestions: false)
        }, onNotSent: { [self] refusal in
            guard isEnabled, generation == enablementGeneration else { return }
            // Nothing was typed, so hand the text back. Anything typed or
            // attached during the readiness wait stays below it.
            notSent = (refusal, presentation.returnUnsentText(text, for: threadID, boxWasCleared: clearedDraft))
            await synchronizePresentation(refreshLaunchSuggestions: false)
        })
        guard isEnabled, generation == enablementGeneration else { return }
        if let notSent {
            let providerName: String? = switch threadID.providerID {
            case .claude: "Claude"
            case .codex: "Codex"
            default: nil
            }
            presentation.reportNotSent(notSent.refusal.error, reason: notSent.refusal.reason, providerName: providerName, draft: notSent.draft)
            presentation.offerSendAnyway(for: composer, refusal: notSent.refusal, draft: notSent.draft)
        } else if case .failure(.unavailable) = result,
                  await runtime.snapshot(for: threadID)?.conversationEnded == true {
            presentation.reportConversationEnded()
        } else {
            handle(result)
        }
    }

    private func interrupt(threadID: AgentThreadID) async {
        guard let binding = presentation.threadSnapshots[threadID]?.binding,
              binding.capabilities.contains(.interrupt),
              let terminal = terminalAdapters[threadID]
        else {
            presentation.reportUnavailable("Interrupt is unavailable because this terminal is no longer live.")
            return
        }
        handle(await bridge.interrupt(threadID: threadID, binding: binding, terminal: terminal))
    }

    @discardableResult
    private func openTerminal(threadID: AgentThreadID) async -> Bool {
        guard let binding = presentation.threadSnapshots[threadID]?.binding,
              let terminal = terminalAdapters[threadID]
        else {
            presentation.reportUnavailable("The original terminal is unavailable.")
            return false
        }
        do {
            try await terminal.openTerminal(binding: binding)
            onOpenExactTerminal?(binding)
            return true
        } catch {
            presentation.reportActionError((error as? AgentActionError) ?? .unavailable)
            return false
        }
    }

    private func beginDictation(for threadID: AgentThreadID) async {
        guard let speech else {
            presentation.reportUnavailable("Dictation is unavailable in this app context.")
            return
        }
        switch await speech.begin(for: threadID, applyDraft: { [weak self] id, text in
            self?.presentation.setDraft(text, for: id)
        }) {
        case .listening: break
        case .unavailable: presentation.reportUnavailable("On-device dictation is unavailable.")
        case .busy: presentation.reportUnavailable("Dictation is already in use.")
        }
    }

    private func launch(_ intent: AgentLaunchIntent) async {
        let matchingBindings = presentation.threadSnapshots.values.compactMap(\.binding).filter {
            $0.liveSessionID == intent.liveSessionID
                && $0.hasCurrentTmuxTarget
                && $0.capabilities.contains(.send)
        }
        let binding: AgentTerminalBinding?
        switch intent.placement {
        case .newWindow:
            binding = matchingBindings.first
        case .split(let windowID, let paneID, _):
            binding = matchingBindings.first {
                $0.windowID == windowID && (paneID == nil || $0.paneID == paneID)
            }
        }
        guard let binding,
              let session = sessionRoutes[intent.liveSessionID],
              session.source.supportsTmuxLaunch(),
              threadRoutes.values.contains(where: {
                  $0.registrationID == session.source.registrationID && $0.binding == binding
              })
        else {
            presentation.reportUnavailable("Launching requires a live tmux session route.")
            return
        }
        let registrationID = session.source.registrationID
        guard isLiveRouteCurrent(binding, registrationID: registrationID) else {
            presentation.reportActionError(.staleBinding)
            return
        }
        guard let directoryAnchor = validatedLaunchDirectories[intent.liveSessionID]?[intent.workingDirectory.value],
              let directoryRoute = threadRoutes.values.first(where: {
                  $0.registrationID == session.source.registrationID && $0.binding == directoryAnchor
              }),
              let directorySource = session.source.validatedRemoteDirectories,
              let freshDirectoryTarget = await session.source.inspect(directoryRoute.location),
              isLiveRouteCurrent(binding, registrationID: registrationID),
              isLiveRouteCurrent(directoryAnchor, registrationID: registrationID),
              target(freshDirectoryTarget, stillMatches: directoryRoute.profile, binding: directoryAnchor),
              (await directorySource(directoryAnchor)).contains(intent.workingDirectory.value)
        else {
            presentation.reportUnavailable("Choose a current directory from a live tmux pane before launching.")
            return
        }
        guard isLiveRouteCurrent(binding, registrationID: registrationID) else {
            presentation.reportActionError(.staleBinding)
            return
        }
        if case .fork(let source, _) = intent.kind {
            guard let sourceSnapshot = presentation.threadSnapshots[source.threadID],
                  let sourceBinding = sourceSnapshot.binding,
                  sourceBinding.liveSessionID == intent.liveSessionID,
                  sourceBinding.hasCurrentTmuxTarget,
                  sourceBinding.capabilities.contains(.send),
                  source.threadID.providerID == intent.providerID,
                  AgentProviderRegistry.builtIn.manifest(for: intent.providerID)?.actions.contains(.fork) == true
            else {
                presentation.reportUnavailable("Forking requires the original provider and live tmux target.")
                return
            }
        }
        let validator = AgentLaunchValidator(registry: .builtIn)
        switch validator.plan(intent, binding: binding) {
        case .failure(let error):
            presentation.reportActionError(error)
        case .success(let plan):
            do {
                let existingIDs = Set(presentation.listSnapshot.threads.map(\.id))
                let receipt: AgentLaunchReceipt
                guard isLiveRouteCurrent(binding, registrationID: registrationID) else {
                    throw AgentActionError.staleBinding
                }
                if let launchAgent = session.source.launchAgent {
                    receipt = try await launchAgent(plan)
                } else if let launchPort {
                    receipt = try await launchPort.execute(plan)
                } else {
                    throw AgentActionError.unavailable
                }
                guard receipt.verifies(plan) else {
                    throw AgentActionError.verificationFailed
                }
                guard isLiveRouteCurrent(binding, registrationID: registrationID) else {
                    throw AgentActionError.staleBinding
                }
                guard let child = await awaitLaunchedThread(
                    intent: intent,
                    receipt: receipt,
                    excluding: existingIDs,
                    registrationID: registrationID
                ) else {
                    presentation.reportUnavailable(
                        "The tmux placement was created, but no lifecycle-bound agent appeared. Check the new pane."
                    )
                    return
                }
                let placement: String = switch intent.placement {
                case .newWindow: "tmux window"
                case .split(_, _, let axis): axis == .right ? "tmux split right" : "tmux split down"
                }
                let parent: AgentThreadID?
                let sourceTurn: String?
                let sourceRecord: String?
                switch intent.kind {
                case .spawn:
                    parent = nil
                    sourceTurn = nil
                    sourceRecord = nil
                case .fork(let source, _):
                    parent = source.threadID
                    sourceTurn = source.turnID
                    sourceRecord = source.recordID
                }
                let lineage = AgentThreadLineage(
                    parentThreadID: parent,
                    sourceTurnID: sourceTurn,
                    sourceRecordID: sourceRecord,
                    creationReceipt: .init(
                        receiptID: receipt.value,
                        createdAt: .now,
                        placement: placement
                    )
                )
                // The acknowledged tmux child remains usable even if the
                // optional local lineage write fails. Select it first, then
                // surface a truthful metadata warning without recasting a
                // successful launch as an unavailable action.
                presentation.launchMode = nil
                guard isEnabled,
                      sessionRoutes[intent.liveSessionID]?.source.registrationID == registrationID
                else { return }
                presentation.select(child)
                await synchronizePresentation()
                do {
                    try await metadata.saveLineage(lineage, for: child)
                    await runtime.setLineage(lineage, for: child)
                    if let parent {
                        var parentLineage = await metadata.lineage(for: parent) ?? .init()
                        if !parentLineage.childThreadIDs.contains(child) {
                            parentLineage.childThreadIDs.append(child)
                        }
                        try await metadata.saveLineage(parentLineage, for: parent)
                        await runtime.setLineage(parentLineage, for: parent)
                    }
                } catch {
                    presentation.reportUnavailable(
                        "The agent launched successfully, but Tessera could not save its local lineage."
                    )
                }
                await synchronizePresentation()
            } catch let error as AgentActionError {
                presentation.reportActionError(error)
            } catch {
                presentation.reportActionError(.unavailable)
            }
        }
    }

    private func awaitLaunchedThread(
        intent: AgentLaunchIntent,
        receipt: AgentLaunchReceipt,
        excluding existingIDs: Set<AgentThreadID>,
        registrationID: UUID
    ) async -> AgentThreadID? {
        // A launch is not attributed from timing or title. The acknowledged
        // receipt must identify the exact tmux pane/window; the child must
        // then independently arrive through lifecycle with the requested
        // provider and its canonical provider-session identity before it can
        // inherit local lineage.
        guard let receiptPaneID = receipt.paneID.map(Self.normalizedPaneID),
              let receiptWindowID = receipt.windowID.map(Self.normalizedWindowID)
        else { return nil }
        for _ in 0..<80 {
            guard isEnabled,
                  sessionRoutes[intent.liveSessionID]?.source.registrationID == registrationID,
                  !Task.isCancelled
            else { return nil }
            scheduleSessionRefresh(sessionID: intent.liveSessionID)
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return nil }
            guard isEnabled,
                  sessionRoutes[intent.liveSessionID]?.source.registrationID == registrationID,
                  !Task.isCancelled
            else { return nil }
            await synchronizePresentation()
            if let child = presentation.listSnapshot.threads.first(where: { summary in
                !existingIDs.contains(summary.id)
                    && summary.id.providerID == intent.providerID
                    && presentation.threadSnapshots[summary.id]?.binding?.liveSessionID == intent.liveSessionID
                    && presentation.threadSnapshots[summary.id]?.binding?.paneID == receiptPaneID
                    && presentation.threadSnapshots[summary.id]?.binding?.windowID == receiptWindowID
            })?.id {
                return child
            }
        }
        return nil
    }

    private static func normalizedPaneID(_ value: String) -> String {
        value.hasPrefix("%") ? String(value.dropFirst()) : value
    }

    private static func normalizedWindowID(_ value: String) -> String {
        value.hasPrefix("@") ? String(value.dropFirst()) : value
    }

    private func handle(_ result: Result<Void, AgentActionError>, promptAnswer: Bool = false) {
        if case .failure(let error) = result { presentation.reportActionError(error, promptAnswer: promptAnswer) }
    }

    /// Re-runs the current query when a connected source finishes inventory.
    /// Kept coordinator-owned so the projector cannot mutate search state
    /// without the active-surface and generation checks below.
    func scheduleSearch(query: String) {
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        presentation.isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.searchGeneration == generation {
                    self.searchTask = nil
                    self.presentation.isSearching = false
                }
            }
            await self.bridge.setFilter(.init(query: query))
            await self.bridge.search(query: query)
            guard !Task.isCancelled,
                  self.isEnabled,
                  self.applicationActive,
                  self.searchGeneration == generation,
                  self.hasSurfaceDemand
            else { return }
            await self.searchConnectedSources(query: query, generation: generation)
            guard !Task.isCancelled, self.searchGeneration == generation else { return }
            await self.synchronizePresentation()
        }
    }

    private func latestPrompt(in snapshot: AgentThreadSnapshot) -> AgentActionPrompt? {
        snapshot.messages.reversed().flatMap(\.blocks).compactMap { block in
            if case .actionPrompt(let prompt) = block { return prompt }
            return nil
        }.first
    }

    func synchronizePresentation(refreshLaunchSuggestions: Bool = true) async {
        let started = Date()
        defer { performanceDiagnostics.record("publish", since: started) }
        await bridge.refreshList()
        let applyStarted = Date()
        let changed = bridge.takePresentationChanges()
        let removals = bridge.takePresentationRemovals()
        presentation.apply(list: bridge.listSnapshot, changed: changed, removed: removals.removed,
                           successors: removals.successors)
        for snapshot in bridge.threadSnapshots.values where snapshot.summary.livePromptWatch == true {
            startLivePromptWatch(snapshot.summary.id)
        }
        for threadID in ingestionOpenDetails where isDisplayingThread(threadID) { startLivePromptWatch(threadID) }
        if presentation.searchSnapshot != bridge.searchSnapshot { presentation.searchSnapshot = bridge.searchSnapshot }
        refreshBoundThreadAttention(changed)
        refreshPaneAgentProviders()
        performanceDiagnostics.record("publishSync", since: applyStarted)
        if let restoredSelection,
           bridge.listSnapshot.threads.contains(where: { $0.id == restoredSelection }) {
            presentation.selectedThreadID = restoredSelection
            await bridge.select(threadID: restoredSelection)
            self.restoredSelection = nil
        }
        refreshLiveAttentionCounts()
        await persistCompletionReads(changed)
        if refreshLaunchSuggestions { await refreshLaunchTargets() }
    }

    /// Persists Core's content-free completion identities, so a relaunch
    /// neither resurrects a finish already read nor loses one still unread.
    /// Only snapshots that changed can carry new keys, so a publish checks
    /// those (plus pending retries) rather than every stored session.
    private func persistCompletionReads(_ changed: [AgentThreadSnapshot]) async {
        guard isEnabled else { completionSweepPending = true; return }
        var threadIDs = completionRetries
        completionRetries.removeAll()
        if completionSweepPending {
            completionSweepPending = false
            threadIDs.formUnion(bridge.threadSnapshots.keys)
        } else {
            threadIDs.formUnion(changed.map(\.summary.id))
        }
        for threadID in threadIDs {
            // Read at write time: an overlapping publish may already have
            // persisted newer keys while this loop was suspended.
            guard isEnabled, let snapshot = bridge.threadSnapshots[threadID] else { continue }
            let keys = CompletionKeys(unread: snapshot.unreadCompletionKey, acknowledged: snapshot.acknowledgedCompletionKey)
            guard persistedCompletionKeys[threadID] != keys else { continue }
            persistedCompletionKeys[threadID] = keys
            do { try await metadata.saveCompletion(unread: keys.unread, acknowledged: keys.acknowledged, for: threadID) }
            catch {
                if persistedCompletionKeys[threadID] == keys { persistedCompletionKeys[threadID] = nil }
                completionRetries.insert(threadID)
            }
        }
    }

    private func persistViewMetadata(
        grouping: AgentListGrouping? = nil,
        lastSelectedThreadID: AgentThreadID? = nil,
        showSystemEvents: Bool? = nil
    ) async {
        let existing = await metadata.viewMetadata()
        let view = AppleAgentViewMetadata(
            grouping: grouping ?? existing.grouping,
            providerIDs: existing.providerIDs,
            lastSelectedThreadID: lastSelectedThreadID ?? presentation.selectedThreadID,
            showSystemEvents: showSystemEvents ?? existing.showSystemEvents
        )
        try? await metadata.saveViewMetadata(view)
    }

    private func refreshLaunchTargets() async {
        // Output discoveries can complete many times per second. These
        // read-only directory probes are launch suggestions, not authority:
        // launch revalidates its exact binding/path independently.
        guard !launchTargetsRefreshing, Date() >= launchTargetsRefreshAfter else { return }
        let started = Date()
        launchTargetsRefreshing = true
        defer {
            launchTargetsRefreshing = false
            launchTargetsRefreshAfter = Date().addingTimeInterval(2)
            performanceDiagnostics.record("launchDirectories", since: started)
        }
        var targets: [AgentCenterV2PresentationModel.LaunchTarget] = []
        var directoryAnchors: [UUID: [String: AgentTerminalBinding]] = [:]
        for session in sessionRoutes.values {
            guard session.source.launchAgent != nil,
                  session.source.supportsTmuxLaunch(),
                  let directorySource = session.source.validatedRemoteDirectories
            else { continue }
            let routes = threadRoutes.values.filter {
                $0.registrationID == session.source.registrationID
                    && $0.binding.hasCurrentTmuxTarget
                    && $0.binding.capabilities.contains(.send)
            }.sorted { lhs, rhs in
                let lhsWindow = lhs.binding.windowID ?? ""
                let rhsWindow = rhs.binding.windowID ?? ""
                if lhsWindow != rhsWindow { return lhsWindow < rhsWindow }
                return (lhs.binding.paneID ?? "") < (rhs.binding.paneID ?? "")
            }
            guard !routes.isEmpty else { continue }

            var directories: [String: AgentTerminalBinding] = [:]
            for route in routes {
                let discovered = await directorySource(route.binding)
                // The source may have been replaced while its control request
                // was in flight. Keep no directory from a stale owner.
                guard sessionRoutes[session.source.sessionID]?.source.registrationID == session.source.registrationID else {
                    break
                }
                for directory in discovered where AgentRemotePath(directory) != nil {
                    if directories[directory] == nil { directories[directory] = route.binding }
                }
            }
            guard !directories.isEmpty else { continue }
            directoryAnchors[session.source.sessionID] = directories
            let windows = Dictionary(grouping: routes, by: { $0.binding.windowID ?? "" })
                .filter { !$0.key.isEmpty }
                .map { windowID, windowRoutes in
                    AgentCenterV2PresentationModel.LaunchTarget.Window(
                        id: windowID,
                        title: windowRoutes.first?.location.windowName ?? "window \(windowID)",
                        paneIDs: windowRoutes.compactMap(\.binding.paneID)
                    )
                }
                .sorted { $0.id < $1.id }
            let summary = presentation.threadSnapshots.values.first {
                $0.binding?.liveSessionID == session.source.sessionID
            }?.summary
            let providers = AgentProviderRegistry.builtIn.allManifests
                .filter { $0.actions.contains(.spawn) || $0.actions.contains(.fork) }
                .map(\.id)
            targets.append(AgentCenterV2PresentationModel.LaunchTarget(
                id: session.source.sessionID,
                title: summary?.hostDisplayLabel ?? "connected tmux session",
                detail: routes.first?.location.transportLabel ?? "tmux",
                providerIDs: providers,
                recentDirectories: directories.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                windows: windows
            ))
        }
        validatedLaunchDirectories = directoryAnchors
        let sorted = targets.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        if presentation.launchTargets != sorted { presentation.launchTargets = sorted }
    }
}
