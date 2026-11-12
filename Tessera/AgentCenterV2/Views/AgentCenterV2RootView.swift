import SwiftUI
import SwiftData
import UIKit
import TesseraCore

/// Native V2 shell. The caller supplies the existing Tessera sidebar so this
/// feature does not recreate session/host navigation.
struct AgentCenterV2RootView<Sidebar: View>: View {
    @Bindable var model: AgentCenterV2PresentationModel
    @State private var compactPath: [AgentCenterV2NavigationRoute] = []
    @State private var isNarrowComposition = false
    @State private var railThreadStates = AgentRailThreadStateStore()
    @State private var railPageHolder = AgentRailPageHolder()
    @State private var threadPresentationStates: AgentThreadPresentationStore
    /// The settled fold while it is a laptop pose: see `AgentAnswerDeckPolicy.layout`.
    @State private var laptopFold: DuoFold?
    /// Waiting rows' folded answers, shared by every layout's list.
    @State private var answerFolds = AgentRowAnswerFolds()
    /// Typed prompt answers, which outlive the detail across layouts.
    @State private var promptAnswerDrafts = AgentPromptAnswerDrafts()
    @Environment(\.duoRailMode) private var duoRailMode
    #if DEBUG
    @Environment(\.agentCenterLaptopFoldOverride) private var laptopFoldOverride
    #endif
    private let sidebar: Sidebar
    private let includesNavigationSidebar: Bool
    private let onNarrowComposition: (Bool) -> Void

    init(
        model: AgentCenterV2PresentationModel,
        includesNavigationSidebar: Bool = true,
        onNarrowComposition: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder sidebar: () -> Sidebar
    ) {
        self.model = model
        _threadPresentationStates = State(initialValue: AgentThreadPresentationStore(isRetained: { [weak model] id in
            guard let model else { return false }
            return model.threadSnapshots[id] != nil || model.listSnapshot.threads.contains { $0.id == id }
        }))
        self.includesNavigationSidebar = includesNavigationSidebar
        self.onNarrowComposition = onNarrowComposition
        self.sidebar = sidebar()
    }

    private var fileAttachmentPickerRequest: Binding<AgentCenterV2PresentationModel.AttachmentPickerRequest?> {
        Binding(
            get: { model.attachmentPickerRequest?.source == .file ? model.attachmentPickerRequest : nil },
            set: { request in
                // A picker UIKit refused to show reports nothing; cancel it.
                if request == nil, model.attachmentPickerRequest?.source == .file {
                    model.attachmentPickerDidDismiss()
                }
            }
        )
    }

    private var photoAttachmentPickerRequest: Binding<AgentCenterV2PresentationModel.AttachmentPickerRequest?> {
        Binding(
            get: { model.attachmentPickerRequest?.source == .photo ? model.attachmentPickerRequest : nil },
            set: { request in
                if request == nil, model.attachmentPickerRequest?.source == .photo {
                    model.attachmentPickerRequest = nil
                }
            }
        )
    }

    var body: some View {
        let detailTaskID = model.threadDetailVisible ? model.selectedThreadForDetail?.summary.id : nil
        GeometryReader { proxy in
            let fold = shownLaptopFold(in: proxy)
            // ContentView owns the app's existing session sidebar and makes
            // its stable, full-shell collapse decision before this view sees
            // its inset width. The embedded V2 surface therefore needs only
            // 300pt for the list plus a useful detail minimum; the standalone
            // fixture retains the full mockup's sidebar + list + detail gate.
            let layout = AgentAnswerDeckPolicy.layout(
                width: proxy.size.width, includesNavigationSidebar: includesNavigationSidebar, railMode: duoRailMode,
                laptop: fold != nil
            )
            Group {
            if layout == .laptop, let fold {
                AgentCenterV2LaptopView(model: model, fold: fold, answerFolds: $answerFolds)
            } else if layout == .twoColumns {
                HStack(spacing: 0) {
                    if includesNavigationSidebar {
                        sidebar
                            .frame(width: 240)
                        Divider()
                    }
                    AgentThreadListView(
                        model: model, isCompact: false, answerFolds: $answerFolds,
                        shownBesideThreadID: AgentAnswerDeckPolicy.threadShownBeside(
                            layout: layout, shown: model.selectedThreadForDetail?.summary.id)
                    )
                    .frame(width: 300)
                    Divider()
                    AgentThreadDetailView(model: model, isCompact: false)
                }
            } else {
                AgentCenterV2NarrowRootView(
                    model: model, path: $compactPath, railThreadStates: $railThreadStates,
                    answerFolds: $answerFolds, pageHolder: railPageHolder
                )
            }
            }
            .onAppear { apply(layout) }
            .onChange(of: layout) { previous, next in
                // Leaving laptop pose for the narrow stack keeps reading: the
                // thread open above fills the screen, the list behind ‹.
                if previous == .laptop, next == .narrow {
                    if let id = model.selectedThreadForDetail?.summary.id {
                        compactPath = [.thread(id)]
                    } else if let id = model.selectedCandidateID {
                        compactPath = [.candidate(id)]
                    }
                }
                apply(next)
            }
            .onChange(of: compactPath) { _, path in
                model.setThreadDetailVisible(AgentAnswerDeckPolicy.detailVisible(layout: layout, pushed: !path.isEmpty))
            }
        }
        .stackBoundary()
        .onDuoFoldChange { fold in
            let laptop = AgentAnswerDeckPolicy.isLaptop(fold) ? fold : nil
            if laptopFold != laptop { laptopFold = laptop }
        }
        .environment(threadPresentationStates)
        .environment(\.agentPromptAnswerDrafts, promptAnswerDrafts)
        .onChange(of: pushedRouteID, initial: true) { _, id in railPageHolder.pushes(id) }
        .onChange(of: retainedThreadIDs, initial: true) { _, ids in
            pruneRailThreadStates()
            threadPresentationStates.prune(retaining: ids)
            answerFolds.prune(retaining: ids)
            promptAnswerDrafts.prune(retaining: ids)
        }
        .onChange(of: model.succession) { _, _ in
            pruneRailThreadStates()
        }
        // The section owns visibility and polling as well as presentation
        // snapshots. Rearranging its detail must not cancel a pending read or
        // restart the three-second refresh cadence. The task acts on the ID it
        // was started for: reading the model here would let the first render's
        // nil task claim a later thread, and its cancellation then reports the
        // detail hidden.
        .task(id: detailTaskID) { [detailTaskID] in
            guard let threadID = detailTaskID else { return }
            model.onAction?(.detailVisibility(threadID, true))
            defer { model.onAction?(.detailVisibility(threadID, false)) }
            while !Task.isCancelled {
                model.onAction?(.refreshTranscript(threadID))
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .onDisappear { model.setThreadDetailVisible(false) }
        .background {
            let threadID = model.selectedThreadForDetail?.summary.id ?? model.selectedThreadID ?? pushedRouteID
            AgentRailPageReconciler(
                holder: railPageHolder, routeID: pushedRouteID, threadID: threadID,
                selection: threadID.map { railThreadStates[$0, inheriting: model.succession].selection }
                    ?? .extra("files")
            )
            .equatable()
        }
        .sheet(item: $model.launchMode) { mode in
            AgentLaunchSheet(model: model, mode: mode, isCompact: isNarrowComposition)
        }
        .sheet(item: $model.promptOverflow) { overflow in
            AgentPromptOverflowSheet(model: model, overflow: overflow)
        }
        // UIKit presents the file picker: hosted in a sheet on a Mac it
        // dismissed the sheet before reporting, and the dismissal cancelled
        // the attachment.
        .systemDocumentPicker(
            item: fileAttachmentPickerRequest,
            contentTypes: [.item],
            allowsMultipleSelection: true,
            asCopy: false
        ) { request, urls in
            model.completeAttachments(request, urls: urls)
            model.attachmentPickerDidDismiss()
        }
        .sheet(item: photoAttachmentPickerRequest, onDismiss: { model.attachmentPickerDidDismiss() }) { request in
            AgentAttachmentPhotoPicker(request: request,
                onStartLoading: { cancel in model.beginLoadingAttachmentPhotos(request, onCancel: cancel) },
                onCompletion: { result in
                    switch result {
                    case .success(let urls): model.completeAttachments(request, urls: urls)
                    case .failure(let error):
                        model.failPhotoAttachments(request, error: error)
                    }
                })
            .overlay {
                if model.loadingAttachmentPhotos {
                    VStack(spacing: 12) {
                        ProgressView()
                        Button("Cancel", role: .cancel) { model.cancelLoadingAttachmentPhotos() }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("agent-center-v2-cancel-photo-load")
                    }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .alert(
            "Agent Center",
            isPresented: Binding(
                get: { model.capabilityNotice != nil },
                set: { if !$0 { model.capabilityNotice = nil } }
            )
        ) {
            if model.sendAnywayCandidate != nil {
                Button("Send anyway") { model.sendAnyway() }
                    .accessibilityIdentifier("agent-center-send-anyway")
            }
            Button("OK", role: .cancel) { model.capabilityNotice = nil }
        } message: {
            Text(model.capabilityNotice ?? "")
        }
        .background(AgentCenterV2KeyboardCommands(model: model))
        .overlay(alignment: .topLeading) {
            #if DEBUG
            // Keep the production-shell navigation contract on a distinct
            // inert element. Applying the identifier to this root container
            // would overwrite the identifiers of every descendant control.
            Text("agent center")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("agent-center-page")
            #endif
        }
    }

    private func apply(_ layout: AgentCenterLayout) {
        model.setThreadDetailVisible(AgentAnswerDeckPolicy.detailVisible(layout: layout, pushed: !compactPath.isEmpty))
        // Laptop pose stacks one column at a time, as the narrow stack does.
        isNarrowComposition = layout != .twoColumns
        onNarrowComposition(layout != .twoColumns)
    }

    /// The laptop fold in this view's space: the settled pose, or the
    /// host-free harness's stand-in, which has no hinge to report one.
    private func shownLaptopFold(in proxy: GeometryProxy) -> DuoFold? {
        #if DEBUG
        if let laptopFoldOverride {
            let origin = proxy.frame(in: .global).origin
            return DuoFold(frame: laptopFoldOverride.offsetBy(dx: -origin.x, dy: -origin.y), splitsSideBySide: false)
        }
        #endif
        return laptopFold
    }

    private var retainedThreadIDs: Set<AgentThreadID> {
        Set(model.threadSnapshots.keys).union(model.listSnapshot.threads.map(\.id))
    }

    private func pruneRailThreadStates() {
        let succession = model.succession
        railThreadStates.prune(retaining: retainedThreadIDs, inheriting: succession)
        model.didMigrateSuccession(succession)
    }

    /// The narrow stack's thread route, kept while two columns replace it.
    private var pushedRouteID: AgentThreadID? {
        guard case .thread(let routeID) = compactPath.last else { return nil }
        return routeID
    }
}

private struct AgentPromptOverflowSheet: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let overflow: AgentCenterV2PresentationModel.PromptOverflow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var T

    var body: some View {
        NavigationStack {
            List(AgentAnswerDeckPolicy.overflowOptions(overflow.prompt)) { option in
                Button(option.label) {
                    model.keyboardFocus = .action
                    model.onAction?(.answer(threadID: overflow.threadID, token: overflow.prompt.token, goal: .option(option.id)))
                    dismiss()
                }
                .frame(minHeight: 44)
                .disabled(model.answeringPromptThreads.contains(overflow.threadID))
            }
            .navigationTitle(overflow.prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } } }
        }
        .laptopSheetDetents([.medium, .large])
        .tint(T.accent)
    }
}

/// Commands avoid the known `⌘W`, `⌃Tab`, and `⌘`-arrow collisions. Bare
/// prompt digits are mounted only while this surface owns the command scope.
private struct AgentCenterV2KeyboardCommands: View {
    @Bindable var model: AgentCenterV2PresentationModel

    var body: some View {
        Group {
            command("search agent threads", key: "f", modifiers: [.command]) {
                model.requestSearchFocus()
            }
            command("new agent", key: "n", modifiers: [.command]) {
                model.openLaunch(.spawn)
            }
            if model.allowsListNavigationShortcuts {
                command("previous agent thread", key: .upArrow, modifiers: []) {
                    model.selectAdjacentThread(offset: -1)
                }
                command("next agent thread", key: .downArrow, modifiers: []) {
                    model.selectAdjacentThread(offset: 1)
                }
            }
            if model.allowsPromptDigitShortcuts {
                command("answer default agent prompt", key: "1", modifiers: []) {
                    model.answerPromptOption(0)
                }
                command("answer agent prompt option 2", key: "2", modifiers: []) { model.answerPromptOption(1) }
                command("answer agent prompt option 3", key: "3", modifiers: []) { model.answerPromptOption(2) }
                command("answer agent prompt option 4", key: "4", modifiers: []) { model.answerPromptOption(3) }
                command("answer agent prompt option 5", key: "5", modifiers: []) { model.answerPromptOption(4) }
                command("answer agent prompt option 6", key: "6", modifiers: []) { model.answerPromptOption(5) }
                command("answer agent prompt option 7", key: "7", modifiers: []) { model.answerPromptOption(6) }
                command("answer agent prompt option 8", key: "8", modifiers: []) { model.answerPromptOption(7) }
                command("answer agent prompt option 9", key: "9", modifiers: []) { model.answerPromptOption(8) }
            }
            // The composer's text view owns ⌘Return and ⌃Return (send) while
            // it is focused; Return and ⇧Return stay newlines there.
            if model.keyboardFocus != .composer && model.keyboardFocus != .promptAnswer {
                command("open exact agent terminal", key: .return, modifiers: [.command]) {
                    if let id = model.selectedThreadID {
                        model.onAction?(.openTerminal(id))
                    } else if let id = model.selectedCandidateID {
                        model.onAction?(.openCandidateTerminal(id))
                    }
                }
            }
            if model.threadDetailVisible && (model.keyboardFocus == .composer || model.keyboardFocus == .action) {
                command("interrupt agent", key: .escape, modifiers: []) {
                    model.interruptSelectedThread()
                }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func command(
        _ title: String,
        key: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
    }
}

private struct AgentCenterV2NarrowRootView: View {
    @Bindable var model: AgentCenterV2PresentationModel
    @Binding var path: [AgentCenterV2NavigationRoute]
    @Binding var railThreadStates: AgentRailThreadStateStore
    @Binding var answerFolds: AgentRowAnswerFolds
    let pageHolder: AgentRailPageHolder
    @Environment(\.duoRailMode) private var duoRailMode
    @Environment(\.duoOpenSwitcher) private var openSwitcher

    var body: some View {
        NavigationStack(path: $path) {
            // One screen at a time: no thread is open beside the list.
            AgentThreadListView(
                model: model,
                isCompact: true,
                answerFolds: $answerFolds,
                onOpenThread: { id in path = [.thread(id)] },
                onOpenCandidate: { id in path = [.candidate(id)] }
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(duoRailMode ? .inline : .automatic)
            .toolbarBackgroundVisibility(duoRailMode ? .hidden : .automatic, for: .navigationBar)
            .ignoresSafeArea(.container, edges: duoRailMode ? .top : [])
            .toolbar {
                if duoRailMode {
                    AgentRailToolbar(
                        items: AgentRailPolicy.items(screen: .board, hasSwitcher: openSwitcher != nil),
                        onOpenSwitcher: { openSwitcher?() },
                        onNewAgent: { model.openLaunch(.spawn) }
                    )
                }
            }
            .navigationDestination(for: AgentCenterV2NavigationRoute.self) { route in
                switch route {
                case .thread(let routeID):
                    // Core can replace a conversation in the same pane while
                    // the stack stays pushed. State follows the shown identity.
                    let threadID = model.selectedThreadForDetail?.summary.id ?? model.selectedThreadID ?? routeID
                    // Closed and open flat have no desk: the rail's book puts
                    // the thread's context beside it or in a sheet. Laptop
                    // pose lays Agent Center out without this stack.
                    DuoWorkspace(
                        state: workspaceState(for: threadID), isEnabled: duoRailMode,
                        primaryTakesInput: true, mainIdealWidth: 524, primaryHasDesk: true,
                        pageOwner: pageHolder.owner(for: routeID)
                    ) {
                        AgentThreadArtifactScope(threadID: threadID, selection: contextSelection(for: threadID)) {
                            AgentThreadDetailView(model: model, isCompact: true)
                        }
                    } secondary: {
                        AgentThreadArtifactScope(threadID: threadID, selection: contextSelection(for: threadID)) {
                            AgentThreadDuoContextView(
                                model: model, threadID: threadID, selection: contextSelection(for: threadID)
                            )
                        }
                    }
                    .ignoresSafeArea(.container, edges: duoRailMode ? .top : [])
                case .candidate:
                    AgentThreadDetailView(model: model, isCompact: true)
                }
            }
        }
        .onAppear { openPendingNotificationThreadIfNeeded() }
        .onChange(of: model.pendingNarrowThreadNavigation) { _, _ in
            openPendingNotificationThreadIfNeeded()
        }
        // An open conversation is a task as a session is: its ■ stays on
        // the rail rather than in ⋯.
        .duoRailPrefersActions(duoRailMode && showsThread)
    }

    private var showsThread: Bool {
        if case .thread? = path.last { return true }
        return false
    }

    private func workspaceState(for id: AgentThreadID) -> Binding<DuoWorkspaceState> {
        Binding(get: { railThreadStates[id, inheriting: model.succession].workspace },
                set: { railThreadStates[id, inheriting: model.succession].workspace = $0 })
    }

    private func contextSelection(for id: AgentThreadID) -> Binding<DuoContextSelection> {
        Binding(get: { railThreadStates[id, inheriting: model.succession].selection },
                set: { railThreadStates[id, inheriting: model.succession].selection = $0 })
    }

    private func openPendingNotificationThreadIfNeeded() {
        guard let threadID = model.pendingNarrowThreadNavigation else { return }
        path = [.thread(threadID)]
        model.consumeNarrowThreadNavigation(threadID)
    }
}

/// Reads artifact changes independently of transcript publishes. Its value
/// inputs compare only route, shown thread and selection; ownership changes
/// wake it even when invalidation preceded the outgoing pane's disappearance.
struct AgentRailPageReconciler: View, Equatable {
    let holder: AgentRailPageHolder
    let routeID: AgentThreadID?
    let threadID: AgentThreadID?
    let selection: DuoContextSelection
    @Environment(ArtifactsStore.self) private var artifacts: ArtifactsStore?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.holder === rhs.holder && lhs.routeID == rhs.routeID
            && lhs.threadID == rhs.threadID && lhs.selection == rhs.selection
    }

    private struct Page: Equatable {
        let identity: BrowserPageIdentity
        let currentIdentity: BrowserPageIdentity?
        let selectedTabID: String?
    }

    private var page: Page? {
        guard let artifacts, let routeID else { return nil }
        let owner = holder.owner(for: routeID)
        guard !owner.isOwned, let identity = owner.pageSession.session?.identity else { return nil }
        let tabs = DuoContextPolicy.orderedTabs(hostID: threadID?.hostID, tabs: artifacts.state.tabs)
        // Files always exists. Treat a chosen terminal conservatively as an
        // extra even if its live binding disappeared while there was no pane.
        let resolved = DuoContextPolicy.resolvedSelection(
            selection, tabs: tabs, extraIDs: ["files", "terminal"], fallbackExtraID: "files"
        )
        let selectedTabID: String?
        if case let .tab(id) = resolved { selectedTabID = id }
        else { selectedTabID = nil }
        return Page(identity: identity,
                    currentIdentity: owner.pageSession.pageIdentity(for: artifacts.tab(identity.tabID), store: artifacts),
                    selectedTabID: selectedTabID)
    }

    var body: some View {
        Color.clear
            .onChange(of: page, initial: true) { _, page in
                guard let page, let artifacts, let routeID else { return }
                holder.reconcile(routeID: routeID, selectedTabID: page.selectedTabID, store: artifacts)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct AgentThreadArtifactScope<Content: View>: View {
    let threadID: AgentThreadID
    @Binding var selection: DuoContextSelection
    @ViewBuilder var content: () -> Content
    @Environment(ArtifactsStore.self) private var artifacts: ArtifactsStore?
    @Environment(\.openArtifact) private var inheritedOpen
    @Environment(\.duoWorkspace) private var workspace

    var body: some View {
        content().environment(\.openArtifact, OpenArtifactAction { request in
            // The laptop desk has no toggle to reveal its context: with no
            // desk to show it on (a tall draft), the browser opens the tab.
            let hasWorkspace = workspace.map {
                $0.arrangement != .single && ($0.arrangement != .stacked || $0.isContextShown)
            } == true
            let destination = AgentRailPolicy.artifactDestination(
                requestHostID: request.hostID, threadHostID: threadID.hostID,
                hasWorkspace: hasWorkspace,
                isContextShown: workspace?.isContextShown == true, isSwapped: workspace?.isSwapped == true
            )
            guard case let .context(reveal) = destination, let tabID = artifacts?.open(request) else {
                inheritedOpen?(request)
                return
            }
            selection = .tab(tabID)
            if reveal { workspace?.toggleContext() }
        })
    }
}

struct AgentThreadDuoContextView: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let threadID: AgentThreadID
    @Binding var selection: DuoContextSelection
    @Query private var hosts: [PersistedHost]
    @Environment(SessionRegistry.self) private var sessions: SessionRegistry?
    @Environment(FileBridgeRegistry.self) private var fileBridges

    var body: some View {
        let hostID = AgentRailPolicy.savedHostID(for: threadID, savedHostIDs: Set(hosts.map(\.id)))
        let thread = model.selectedThreadForDetail?.summary.id == threadID ? model.selectedThreadForDetail : nil
        let directory = thread.flatMap { workingDirectory(for: $0, hostID: hostID) }
        DuoContextPane(
            hostID: hostID, extras: extras(thread: thread, hostID: hostID, directory: directory),
            fallbackExtraID: "files", selection: $selection
        )
    }

    private func workingDirectory(for thread: AgentThreadSnapshot, hostID: UUID?) -> String? {
        AgentRailPolicy.threadWorkingDirectory(
            thread, hostID: hostID, sessions: sessions, known: model.threadFilesDirectories)
    }

    private func extras(thread: AgentThreadSnapshot?, hostID: UUID?, directory: String?) -> [DuoContextExtra] {
        let markedPaths = AgentRailPolicy.markedPaths(in: thread?.messages ?? [], directory: directory)
        let connected = (sessions?.activeSessions ?? []).filter { $0.session.terminalSession.state == .connected }
        let filesSession = AgentRailPolicy.filesSessionID(
            binding: thread?.binding, hostID: hostID, connected: connected.map { ($0.id, $0.persistedHostID) }
        ).flatMap { id in connected.first { $0.id == id } }
        var result = [DuoContextExtra(id: "files", title: "files", systemImage: "folder", content: {
            if let hostID {
                return AnyView(DuoFilesContext(hostID: hostID, directory: directory, markedPaths: markedPaths,
                                               onOpenFiles: filesSession.map { live in { connectFiles(through: live) } }))
            }
            return AnyView(ContentUnavailableView("files offline", systemImage: "folder"))
        })]
        let liveSessionIDs = Set(connected.map(\.id))
        if AgentRailPolicy.hasTerminalExtra(binding: thread?.binding, liveSessionIDs: liveSessionIDs) {
            result.append(DuoContextExtra(id: "terminal", title: "terminal", systemImage: "terminal", content: {
                AnyView(Button {
                    model.onAction?(.openTerminal(threadID))
                } label: {
                    Label("open terminal", systemImage: "terminal")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("duo-agent-context-terminal"))
            }))
        }
        return result
    }

    /// The listing never connects by itself; a tap opens the host's Files
    /// with the session's credential snapshot, as the session's panel does.
    private func connectFiles(through live: LiveSession) {
        let bridge: FileBridge
        switch live.session {
        case .ssh(let session):
            bridge = fileBridges.bridge(for: session.host, requireBiometric: session.requireBiometric,
                                        isSecureEnclave: session.isSecureEnclave)
        case .mosh(let session):
            bridge = fileBridges.bridge(for: session.host, requireBiometric: session.requireBiometric,
                                        isSecureEnclave: session.isSecureEnclave)
        }
        // A failure lands in the bridge's state, which the listing shows.
        Task { try? await bridge.connect() }
    }
}

#if DEBUG
extension EnvironmentValues {
    /// A laptop fold, in global coordinates, for the host-free harness
    /// (`TESSERA_AGENT_CENTER_V2_HARNESS_LAPTOP`): no simulator can pose a
    /// Duo hinge from a script.
    @Entry var agentCenterLaptopFoldOverride: CGRect? = nil
}
#endif

private enum AgentCenterV2NavigationRoute: Hashable {
    case thread(AgentThreadID)
    case candidate(AgentSourceCandidateID)
}
