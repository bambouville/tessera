import SwiftUI
import TesseraArtifactsCore
import TesseraCore

enum AgentRailPolicy {
    enum Screen: Equatable { case board, thread, candidate }
    enum Priority: Equatable { case automatic, high }
    enum Item: String, CaseIterable {
        case switcher, context, stop, fork
        case newAgent = "new-agent"

        var title: LocalizedStringKey {
            switch self {
            case .switcher: return "switcher"
            case .newAgent: return "new agent"
            case .context: return "context"
            case .stop: return "stop"
            case .fork: return "fork thread"
            }
        }

        var systemImage: String {
            switch self {
            case .switcher: return "chevron.down"
            case .newAgent: return "plus"
            case .context: return "book"
            case .stop: return "stop.fill"
            case .fork: return "arrow.triangle.branch"
            }
        }

        var priority: Priority {
            switch self {
            case .switcher, .context, .stop: return .high
            case .newAgent, .fork: return .automatic
            }
        }
    }

    struct Entry: Equatable {
        let item: Item
        let isEnabled: Bool
        var priority: Priority { item.priority }
    }

    enum ArtifactDestination: Equatable {
        case context(reveal: Bool)
        case inherited
    }

    static func artifactDestination(
        requestHostID: UUID, threadHostID: UUID, hasWorkspace: Bool, isContextShown: Bool, isSwapped: Bool
    ) -> ArtifactDestination {
        guard hasWorkspace, requestHostID == threadHostID else { return .inherited }
        return .context(reveal: !isContextShown && !isSwapped)
    }

    static func usesTwoColumns(width: CGFloat, includesNavigationSidebar: Bool, railMode: Bool) -> Bool {
        !railMode && width >= (includesNavigationSidebar ? 920 : 620)
    }

    static func items(
        screen: Screen, hasSwitcher: Bool,
        hasContext: Bool = false, status: TesseraAgentCore.AgentStatus = .unavailable,
        canInterrupt: Bool = false, supportsFork: Bool = false, canFork: Bool = false
    ) -> [Entry] {
        var result = [Entry(item: .switcher, isEnabled: hasSwitcher)]
        switch screen {
        case .board:
            // As everywhere in Agent Center: with nothing to launch in, the
            // tap says what launching needs instead of the ＋ vanishing.
            result.append(Entry(item: .newAgent, isEnabled: true))
        case .thread:
            // Only two panes have room for the context.
            if hasContext { result.append(Entry(item: .context, isEnabled: true)) }
            if status == .working && canInterrupt {
                result.append(Entry(item: .stop, isEnabled: true))
            }
            if supportsFork { result.append(Entry(item: .fork, isEnabled: canFork)) }
        case .candidate:
            break
        }
        return result
    }

    static func savedHostID(for threadID: AgentThreadID, savedHostIDs: Set<UUID>) -> UUID? {
        savedHostIDs.contains(threadID.hostID) ? threadID.hostID : nil
    }

    static func threadItems(
        _ thread: AgentThreadSnapshot, hasSwitcher: Bool, hasContext: Bool, hasForkTarget: Bool
    ) -> [Entry] {
        items(
            screen: .thread, hasSwitcher: hasSwitcher, hasContext: hasContext, status: thread.summary.status,
            canInterrupt: thread.summary.availability.actions && thread.binding?.capabilities.contains(.interrupt) == true,
            supportsFork: AgentProviderRegistry.builtIn.manifest(for: thread.summary.id.providerID)?.actions.contains(.fork) == true,
            canFork: thread.summary.availability.fork && thread.summary.availability.actions
                && thread.binding?.hasCurrentTmuxTarget == true && hasForkTarget
        )
    }

    /// The connected session whose credentials open the thread's host's
    /// Files: the agent's own first, else any to that host.
    static func filesSessionID(
        binding: AgentTerminalBinding?, hostID: UUID?, connected: [(id: UUID, hostID: UUID?)]
    ) -> UUID? {
        guard let hostID else { return nil }
        let onHost = connected.filter { $0.hostID == hostID }.map(\.id)
        if let own = binding?.liveSessionID, onHost.contains(own) { return own }
        return onHost.first
    }

    static func hasTerminalExtra(binding: AgentTerminalBinding?, liveSessionIDs: Set<UUID>) -> Bool {
        guard let binding else { return false }
        return binding.capabilities.contains(.observe) && liveSessionIDs.contains(binding.liveSessionID)
    }

    /// The session mirror describes its active pane only. Never use that cwd
    /// for an agent in another pane, or fall back to a host's launch directory.
    static func workingDirectory(
        binding: AgentTerminalBinding, activeWindowID: String?, activePaneID: String?, directory: String?
    ) -> String? {
        guard let directory, directory.hasPrefix("/"), !directory.contains("\0") else { return nil }
        switch binding.transport {
        case .sshTmux, .moshTmux:
            guard binding.hasCurrentTmuxTarget,
                  let pane = binding.paneID, let activePaneID,
                  tmuxID(pane) == tmuxID(activePaneID) else { return nil }
            if let window = binding.windowID {
                guard let activeWindowID, tmuxID(window) == tmuxID(activeWindowID) else { return nil }
            }
        case .ssh, .mosh:
            break
        }
        return directory
    }

    /// The bound pane's directory for a thread on `hostID`, when the app
    /// knows it: the launch probe's pane path first, else the session
    /// mirror's cwd when it describes that pane. Shared by the Duo files
    /// context and the transcript selection menu's relative paths.
    @MainActor
    static func threadWorkingDirectory(
        _ thread: AgentThreadSnapshot,
        hostID: UUID?,
        sessions: SessionRegistry?,
        known: [AgentThreadID: AgentCenterV2PresentationModel.ThreadFilesDirectory]
    ) -> String? {
        guard let hostID, let binding = thread.binding,
              let live = sessions?.session(for: binding.liveSessionID), live.persistedHostID == hostID,
              live.session.terminalSession.state == .connected else { return nil }
        if let known = known[thread.summary.id], known.binding == binding {
            return known.path
        }
        let pane = sessions?.tmuxPaletteSnapshots[binding.liveSessionID]
        return workingDirectory(
            binding: binding, activeWindowID: pane?.activeWindowID?.description,
            activePaneID: pane?.activePaneID?.description, directory: live.session.terminalSession.remoteWorkingDirectory
        )
    }

    static func markedPaths(in messages: [AgentMessage], directory: String? = nil) -> Set<String> {
        var paths = Set<String>()
        for message in messages {
            for case let .edit(path?, _) in message.blocks {
                guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !path.contains("\0") else { continue }
                if path.hasPrefix("/") {
                    paths.insert((path as NSString).standardizingPath)
                } else if !path.hasPrefix("~"), let directory, directory.hasPrefix("/"), !directory.contains("\0") {
                    paths.insert(((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath)
                }
            }
        }
        return paths
    }

    private static func tmuxID(_ value: String) -> String {
        value.hasPrefix("%") || value.hasPrefix("@") ? String(value.dropFirst()) : value
    }
}

/// Owned by the section, rather than a pushed destination. A pop or another
/// thread's selection preserves both the pane controls and the chosen context.
struct AgentRailThreadStateStore {
    static let maximumThreads = 256
    static let maximumRecords = 2 * maximumThreads

    struct State: Equatable {
        var workspace = DuoWorkspaceState()
        var selection: DuoContextSelection = .extra("files")
    }

    private var states: [AgentThreadSuccession.Source: State] = [:]
    private var currentSources: [AgentThreadID: AgentThreadSuccession.Source] = [:]
    private var retainedThreadIDs: Set<AgentThreadID>?
    private var successionID: UUID?
    private var migratedSequence: UInt64 = 0

    var recordCount: Int { states.count }

    subscript(threadID: AgentThreadID, inheriting succession: AgentThreadSuccession? = nil) -> State {
        get { inheritedState(for: threadID, succession: succession) ?? State() }
        set {
            if let succession {
                guard successionID == nil || successionID == succession.id,
                      succession.sequence >= migratedSequence else { return }
            }
            // An outgoing destination can finish dismissing after Core drops
            // its thread. Its last binding write must not resurrect the state.
            guard succession?.removedThreadIDs.contains(threadID) != true,
                  retainedThreadIDs?.contains(threadID) != false
                    || succession?.pendingThreadIDs.contains(threadID) == true
                    || succession?.sources[threadID] != nil else { return }
            if let succession { successionID = succession.id }
            let source = succession?.source(for: threadID) ?? currentSources[threadID]
                ?? AgentThreadSuccession.Source(threadID: threadID, sequence: 0)
            states[source] = newValue
            currentSources[threadID] = source
            enforceLimit(keeping: source)
        }
    }

    mutating func prune(retaining threadIDs: Set<AgentThreadID>, inheriting succession: AgentThreadSuccession? = nil) {
        if let succession, let successionID, succession.id != successionID { self = Self() }
        // A successor can be selected before its first snapshot or list row.
        // Copy before filtering so that first render and its writes agree.
        let retained = Set(threadIDs.union(succession?.pendingThreadIDs ?? [])
            .subtracting(succession?.removedThreadIDs ?? [])
            .sorted(by: AgentThreadSuccession.ordered).prefix(Self.maximumThreads))
        var migrated: [AgentThreadSuccession.Source: State] = [:]
        var sources: [AgentThreadID: AgentThreadSuccession.Source] = [:]
        for id in retained {
            if let state = inheritedState(for: id, succession: succession) {
                let source = succession?.source(for: id) ?? currentSources[id]
                    ?? AgentThreadSuccession.Source(threadID: id, sequence: 0)
                migrated[source] = state
                sources[id] = source
                if let succession {
                    // The model discards the consumed graph after this call.
                    // Keep its new baseline as well as the pre-ACK source.
                    migrated[.init(threadID: id, sequence: succession.sequence)] = state
                }
            }
        }
        retainedThreadIDs = retained
        states = migrated
        currentSources = sources
        if let succession {
            successionID = succession.id
            migratedSequence = succession.sequence
        }
    }

    private func inheritedState(for threadID: AgentThreadID, succession: AgentThreadSuccession?) -> State? {
        guard let succession else { return currentSources[threadID].flatMap { states[$0] } }
        guard successionID == nil || successionID == succession.id,
              !succession.removedThreadIDs.contains(threadID) else { return nil }
        var visited = Set<AgentThreadSuccession.Source>()
        return inheritedState(from: succession.source(for: threadID), succession: succession, visited: &visited)
    }

    private func inheritedState(from source: AgentThreadSuccession.Source, succession: AgentThreadSuccession,
                                visited: inout Set<AgentThreadSuccession.Source>) -> State? {
        if let state = states[source] { return state }
        guard visited.insert(source).inserted, let replacement = succession.replacements[source] else { return nil }
        if let own = inheritedState(from: replacement.own, succession: succession, visited: &visited) { return own }
        if let followed = replacement.followed {
            return inheritedState(from: followed, succession: succession, visited: &visited) ?? State()
        }
        for predecessor in replacement.predecessors {
            if let state = inheritedState(from: predecessor, succession: succession, visited: &visited) { return state }
        }
        return nil
    }

    private mutating func enforceLimit(keeping source: AgentThreadSuccession.Source) {
        if currentSources.count > Self.maximumThreads {
            let victim = currentSources.keys.filter { $0 != source.threadID }.sorted(by: AgentThreadSuccession.ordered)[0]
            currentSources.removeValue(forKey: victim)
        }
        if states.count > Self.maximumRecords {
            let victim = states.keys.filter { $0 != source }.sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return AgentThreadSuccession.ordered($0.threadID, $1.threadID)
            }[0]
            states.removeValue(forKey: victim)
        }
    }
}

/// Agent Center replaces its pushed thread when a pose turns two columns
/// on, and rebuilds it when they turn off. The section holds each route's
/// docked page meanwhile, for as long as the stack would push that route.
@MainActor
final class AgentRailPageHolder {
    private var owners: [AgentThreadID: DuoContextPageOwner] = [:]
    private var routeID: AgentThreadID?

    /// Core can replace the shown conversation under a route. The route, and
    /// with it the page owner, stays.
    func owner(for routeID: AgentThreadID) -> DuoContextPageOwner {
        if let owner = owners[routeID] { return owner }
        let owner = DuoContextPageOwner(keepsPage: { [weak self] in self?.routeID == routeID })
        owners[routeID] = owner
        return owner
    }

    /// An outgoing route's pane may still be animating; its page ends when
    /// the pane goes.
    func pushes(_ routeID: AgentThreadID?) {
        guard self.routeID != routeID else { return }
        self.routeID = routeID
        for (id, owner) in owners where id != routeID { owner.endIfUnowned() }
        owners = owners.filter { $0.key == routeID || $0.value.isOwned }
    }

    /// A mounted pane reconciles its own page. While the pose removes it,
    /// keep only the page that the same route would display on its return.
    func reconcile(routeID: AgentThreadID, selectedTabID: String?, store: any ArtifactsBrowserStore) {
        guard self.routeID == routeID, let owner = owners[routeID], !owner.isOwned,
              let identity = owner.pageSession.session?.identity else { return }
        if selectedTabID != identity.tabID
            || owner.pageSession.pageIdentity(for: store.tab(identity.tabID), store: store) != identity {
            owner.endIfUnowned()
        }
    }
}

struct AgentRailToolbar: ToolbarContent {
    let items: [AgentRailPolicy.Entry]
    var onOpenSwitcher: () -> Void
    var onNewAgent: () -> Void = {}
    var onToggleContext: () -> Void = {}
    /// The context is beside the thread, so the book reads as pressed.
    var contextShown = false
    var onStop: () -> Void = {}
    var onFork: () -> Void = {}

    var body: some ToolbarContent {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            prioritizedActions
        } else {
            standardActions
        }
        #else
        standardActions
        #endif

        if let entry = entry(.newAgent) {
            ToolbarItem(placement: .primaryAction) { button(entry) }
        }
        if let entry = entry(.fork) {
            ToolbarItem(placement: .secondaryAction) { button(entry) }
        }
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    @ToolbarContentBuilder
    private var prioritizedActions: some ToolbarContent {
        if let entry = entry(.switcher) {
            ToolbarItem(placement: .primaryAction) { button(entry) }
                .visibilityPriority(.high)
        }
        if let entry = entry(.context) {
            ToolbarItem(placement: .primaryAction) { button(entry) }
                .visibilityPriority(.high)
        }
        if let entry = entry(.stop) {
            ToolbarItem(placement: .primaryAction) { button(entry) }
                .visibilityPriority(.high)
        }
    }
    #endif

    @ToolbarContentBuilder
    private var standardActions: some ToolbarContent {
        if let entry = entry(.switcher) {
            ToolbarItem(placement: .primaryAction) { button(entry) }
        }
        if let entry = entry(.context) {
            ToolbarItem(placement: .primaryAction) { button(entry) }
        }
        if let entry = entry(.stop) {
            ToolbarItem(placement: .primaryAction) { button(entry) }
        }
    }

    private func entry(_ item: AgentRailPolicy.Item) -> AgentRailPolicy.Entry? {
        items.first { $0.item == item }
    }

    @ViewBuilder
    private func button(_ entry: AgentRailPolicy.Entry) -> some View {
        if entry.item == .context {
            RailContextToggle(isOn: contextShown) { perform(.context) }
                .disabled(!entry.isEnabled)
                .accessibilityIdentifier("duo-agent-rail-\(entry.item.rawValue)")
        } else {
            Button(entry.item.title, systemImage: entry.item.systemImage) { perform(entry.item) }
                .disabled(!entry.isEnabled)
                .accessibilityIdentifier("duo-agent-rail-\(entry.item.rawValue)")
        }
    }

    func perform(_ item: AgentRailPolicy.Item) {
        guard entry(item)?.isEnabled == true else { return }
        switch item {
        case .switcher: onOpenSwitcher()
        case .newAgent: onNewAgent()
        case .context: onToggleContext()
        case .stop: onStop()
        case .fork: onFork()
        }
    }
}
