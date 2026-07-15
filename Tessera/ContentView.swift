import SwiftUI
import SwiftData
import Combine

private struct RestoreStateEvent {
    let liveSessionID: UUID
    let persistedHostID: UUID?
    let transport: String
    let state: SessionState
}

private struct ShareExtensionUploadTargetsDocument: Codable {
    var version = 1
    var updatedAt: Date
    var targets: [ShareExtensionUploadTarget]
}

private struct ShareExtensionUploadTarget: Codable {
    var id: UUID
    var label: String
    var isConnected: Bool
    var isConnecting: Bool
    var isActiveSession: Bool
    var isFailed: Bool
    var sessionCwd: String?

    init(candidate: UploadHostCandidate) {
        id = candidate.id
        label = candidate.label
        isConnected = candidate.isConnected
        isConnecting = candidate.isConnecting
        isActiveSession = candidate.isActiveSession
        isFailed = candidate.isFailed
        sessionCwd = candidate.sessionCwd
    }
}

private struct ShareInboxMetadata: Codable {
    var version: Int
    var targetHostID: UUID?
}

private struct ShareInboxQueuedFile {
    let itemID: String
    let inboxURL: URL
    let hostID: UUID?
    let fileURL: URL
}

private struct ActiveShareQueueUpload {
    let itemID: String
    let inboxURL: URL
    let hostID: UUID
    let sourceFileURL: URL
}

/// Top-level navigation: NavigationSplitView with a sidebar
/// session/host switcher and a detail pane that shows either a
/// host edit form or a live terminal session.
///
/// Multi-session: all active sessions render in a ZStack in the
/// detail pane. Only the selected session is visible; the others
/// are hidden but alive (TerminalView + SSHSession preserved).
/// The sidebar's "Active" section lets the user switch between them.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(HostTerminalBackgroundStore.self) private var hostBackgrounds
    @Environment(AppLockController.self) private var appLockController
    @Environment(OnboardingController.self) private var onboarding
    @Environment(AppPhase.self) private var appPhase
    @Environment(SwipePadProfileStore.self) private var swipePadStore
    @Environment(BellController.self) private var bellController

    @State private var activeSessions: [LiveSession] = []
    @State private var selectedItem: SidebarItem?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var restorePrompt: SessionRestorePrompt?
    @State private var restoreAlwaysReopen = false
    @State private var didEvaluateStartupRestore = false
    @State private var hasInactivePreservedRestoreSnapshots = false
    @State private var foregroundRestoreGraceTask: Task<Void, Never>?

    /// Host key verification request from any connecting session.
    @State private var hostKeyRequest: HostKeyVerificationRequest?

    /// Share-in ("Copy to Tessera"): staged incoming file driving the
    /// Upload sheet. Requests always park first and present only when
    /// no sibling sheet (host-key prompt, restore prompt) is up and the
    /// app is unlocked — two sheets set in one transaction means one
    /// silently never presents.
    @State private var uploadRequest: UploadRequest?
    @State private var pendingUploadRequest: UploadRequest?
    /// Share-in transfers can fail with no panel/strip on screen (the
    /// sheet is long dismissed) — this alert is their only surface.
    @State private var uploadFailureMessage: String?
    /// Live host rows for the presented Upload sheet. A share often
    /// foregrounds (or relaunches) the app while sessions are still
    /// auto-reconnecting — a snapshot taken at presentation would call
    /// every host disconnected, so rows refresh on session-state
    /// events for as long as the sheet is up.
    @State private var uploadSheetModel = UploadSheetModel()
    /// Hosts with an on-demand cwd discovery running (dedup guard).
    @State private var cwdResolutionsInFlight: Set<UUID> = []
    /// Source inbox item for the currently presented upload sheet when
    /// it came from the screenshot/share extension's per-host queue.
    @State private var activeShareQueueUpload: ActiveShareQueueUpload?

    /// Switcher: shared observable mirror of `activeSessions` plus
    /// per-session last-touched timestamps. Read by the command
    /// palette via the environment.
    @State private var sessionRegistry = SessionRegistry()
    @State private var commandPalette = CommandPalette()
    // Production starts inert. `onAppear` applies the persisted experimental
    // preference before any registered session source is allowed to discover.
    @State private var agentCenter = AgentCenter(isEnabled: false)
    @State private var agentCenterReturnItem: SidebarItem?

    /// One FileBridge (dedicated SSH + SFTP) per remote endpoint, shared
    /// across all sessions to that host regardless of transport. Bridges
    /// are created lazily by the session views' Files panels; nothing
    /// connects until the user opens a panel.
    @State private var fileBridges = FileBridgeRegistry()

    private let sessionRestoreStore = SessionRestoreStore()
    private let shareInboxAppGroupID = "group.com.bambouville.TesseraApp"
    private let shareInboxFolderName = "ShareInbox"
    private let shareInboxTargetsFileName = "upload-targets.json"
    private let shareInboxMetadataFileName = "metadata.json"
    private let shareInboxConsumedDefaultsKey = "ShareInbox.ConsumedIDs"
    private let shareInboxConsumedLimit = 200

    private var sidebarVisible: Bool { columnVisibility != .detailOnly }

    private var contentShell: some View {
        ZStack(alignment: .leading) {
            // Detail fills the full frame on every page. The sidebar floats
            // ABOVE it (HIG "extend content beneath the sidebar"), so toggling
            // the sidebar never resizes the detail — the terminal grid is
            // unchanged → no SIGWINCH, no reflow (the clunk fix). Content stays
            // put on every page; a page's leading strip simply sits under the
            // glass while the sidebar is open.
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Scrim over the live terminal while the floating sidebar is open.
            // The terminal stays full-width beneath the glass, so without this
            // a tap on the visible terminal would type/click into the session
            // instead of dismissing the nav. The scrim makes the area read as
            // inactive (dimmed, no input passes through) and a tap anywhere
            // outside the sidebar collapses it. Session-only: browse pages push
            // their content aside rather than floating the sidebar over it.
            if sidebarVisible && isSessionSelected {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapseSidebar() }
                    .transition(.opacity)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("hide sidebar")
                    .zIndex(1)
            }

            if sidebarVisible {
                SessionSidebar(
                    activeSessions: $activeSessions,
                    selectedItem: $selectedItem,
                    onDisconnectSession: dismiss,
                    onNewHost: createAndEditNewHost,
                    onCollapse: collapseSidebar
                )
                .transition(.move(edge: .leading))
                .zIndex(2)
            }
        }
        // Reveal affordance for browse pages when the sidebar is hidden (the
        // terminal carries its own `line.3.horizontal` toggle in the top bar).
        // The non-terminal content is top-inset so its title clears this button.
        .overlay(alignment: .topLeading) {
            if !sidebarVisible && !isSessionSelected {
                sidebarRevealButton
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .background(T.bg)
        .animation(.easeInOut(duration: 0.24), value: sidebarVisible)
        .background(
            Button("New Host", action: createAndEditNewHost)
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .background(
            // Global ⌘K — works even when the focused view doesn't
            // forward keyCommands (host editor, settings, landing).
            // Inside a session SwiftTerm grabs first responder, so
            // `TesseraTerminalContainer` registers its own UIKeyCommand
            // for "k" too; both routes funnel through `openPalette`.
            Button("Open Switcher", action: openPalette)
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .background {
            if appearance.agentCenterEnabled {
                Button("Toggle Agent Center", action: toggleAgentCenter)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
        }
        .background(
            // Global ⌘, — the platform-standard "open Settings" chord.
            // Covers the landing page, host editor, and other browse
            // pages where no terminal holds first responder. Inside a
            // session SwiftTerm grabs first responder, so
            // `TesseraTerminalContainer` registers its own UIKeyCommand
            // for "," too; both routes funnel through `openSettings`.
            Button("Open Settings", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .environment(sessionRegistry)
        .environment(commandPalette)
        .environment(agentCenter)
        .environment(fileBridges)
        .overlay {
            if commandPalette.isOpen {
                CommandPaletteView(
                    palette: commandPalette,
                    onCommit: handleCommandPaletteCommit
                )
                .transition(.opacity)
                .zIndex(50)
            }
        }
    }

    private var agentAwareContent: some View {
        contentShell
        // First-launch walkthrough. Mounted last so it floats above the sidebar
        // (zIndex 2) and the command palette (zIndex 50). `overlayPreferenceValue`
        // resolves the onboarding anchors published by the landing CTA and the
        // sidebar keys row — both descendants of this ZStack — so the overlay can
        // spotlight elements that live in different subtrees.
        .overlayPreferenceValue(OnboardingAnchorKey.self) { anchors in
            GeometryReader { proxy in
                OnboardingOverlay(
                    controller: onboarding,
                    anchors: anchors,
                    geometry: proxy
                )
            }
            .ignoresSafeArea()
        }
        .onChange(of: activeSessions.map(\.id)) { _, _ in
            sessionRegistry.syncActiveSessions(activeSessions)
            refreshCommandPaletteSnapshot()
            logRestoreDiag(
                "active-sessions-changed count=\(activeSessions.count) sessions=\(activeSessionSummary())"
            )
            persistRestoreSnapshots()
            refreshUploadCandidatesIfPresented()
            publishShareExtensionTargets(reason: "active-sessions")
            presentQueuedShareForSelectedHostIfClear(reason: "active-sessions")
        }
        .onChange(of: selectedItem) { oldValue, newValue in
            if newValue == .agents, oldValue != .agents {
                agentCenterReturnItem = oldValue
            }
            if case .session(let id) = newValue {
                sessionRegistry.markTouched(id)
            }
            logRestoreDiag(
                "selected-changed selected=\(sidebarItemDescription(newValue)) active=\(appPhase.isActive)"
            )
            persistRestoreSnapshots()
            publishShareExtensionTargets(reason: "selected")
            presentQueuedShareForSelectedHostIfClear(reason: "selected")
            updateAgentSurfaceDemand()
        }
        .onChange(of: commandPalette.isOpen) { _, _ in
            updateAgentSurfaceDemand()
        }
        .onChange(of: agentCenter.activityRevision) { _, _ in
            refreshCommandPaletteSnapshot()
        }
        .onChange(of: agentCenter.workingCount) { _, _ in
            updateAgentAttentionBackgroundKeepAlive(reason: "agent-activity")
        }
        .onChange(of: appearance.agentCenterEnabled) { _, enabled in
            if !enabled, selectedItem == .agents {
                toggleAgentCenter()
            }
            agentCenter.setEnabled(enabled)
            if !enabled {
                bellController.cancelAgentNotifications()
            }
            updateAgentAttentionBackgroundKeepAlive(reason: "agent-center-setting")
            refreshCommandPaletteSnapshot()
            updateAgentSurfaceDemand()
            if enabled {
                handlePendingAgentNotification()
            }
        }
        .onChange(of: appearance.agentCenterNotificationsEnabled) { _, enabled in
            if !enabled { bellController.cancelAgentNotifications() }
            updateAgentAttentionBackgroundKeepAlive(reason: "notification-setting")
        }
        .onChange(of: swipePadStore.profiles) { _, profiles in
            agentCenter.syncProfiles(profiles)
            agentCenter.refreshAll()
        }
    }

    var body: some View {
        agentAwareContent
        .onChange(of: appLockController.isLocked) { _, isLocked in
            logRestoreDiag("app-lock-changed locked=\(isLocked)")
            if !isLocked {
                if !attemptForegroundRestoreIfNeeded(reason: "unlock") {
                    attemptStartupRestoreIfReady()
                }
                // After the restore attempt: it may have set
                // restorePrompt in this same transaction, in which case
                // the parked share-in stays parked until that sheet
                // clears (its onChange re-attempts).
                presentParkedUploadIfClear()
                scheduleShareInboxSweep(reason: "unlock")
                presentQueuedShareForSelectedHostIfClear(reason: "unlock")
            }
        }
        .onChange(of: appearance.requireBiometricForKeyUse) { _, _ in
            SSHAuthenticationPolicyStore.shared.observeGlobalKeyRequirement(
                appearance.requireBiometricForKeyUse
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ModelContext.didSave)
                .filter { notification in
                    guard let context = notification.object as? ModelContext else {
                        return false
                    }
                    return context === modelContext
                }
        ) { _ in
            // Re-read only active saved-host signatures. The authority compares
            // them before invalidating, so unrelated SwiftData saves are cheap
            // and do not break a valid 30-second same-policy grant.
            SSHAuthenticationPolicyStore.shared.refreshCurrentPolicies()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .map { _ in
                    UserDefaults.standard.bool(
                        forKey: "tessera.pref.requireBiometricForKeyUse"
                    )
                }
                .removeDuplicates()
                .receive(on: RunLoop.main)
        ) { capturedValue in
            SSHAuthenticationPolicyStore.shared.observeGlobalKeyRequirement(
                capturedValue
            )
        }
        .onChange(of: onboarding.phase) { _, newPhase in
            // A spotlight step needs its target on screen. The replay path
            // starts from Settings (or a live session), so drop back to the
            // home host list and reveal the sidebar — that surfaces both the
            // add-host affordance (step ①) and the sidebar keys row (step ②).
            guard case .touring(let index) = newPhase,
                  index >= 0, index < onboarding.steps.count,
                  case .spotlight = onboarding.steps[index].kind
            else { return }
            selectedItem = nil
            columnVisibility = .automatic
        }
        .onChange(of: appPhase.isActive) { _, isActive in
            agentCenter.setApplicationActive(isActive)
            if isActive {
                // Foreground attention is represented by the exact-pane-aware
                // top-bar chip. Withdraw stale background banners while
                // preserving the independent unread attention records.
                bellController.cancelAgentNotifications()
            }
            logRestoreDiag(
                "app-phase-changed active=\(isActive) didEvaluateStartupRestore=\(didEvaluateStartupRestore) activeCount=\(activeSessions.count) inactivePreserved=\(hasInactivePreservedRestoreSnapshots)"
            )
            guard didEvaluateStartupRestore || !isActive else {
                logRestoreDiag("app-phase-skip reason=startup-restore-not-evaluated")
                return
            }
            if isActive,
               attemptForegroundRestoreIfNeeded(reason: "foreground") {
                publishShareExtensionTargets(reason: "foreground")
                scheduleShareInboxSweep(reason: "foreground")
                presentQueuedShareForSelectedHostIfClear(reason: "foreground")
                return
            }
            if isActive {
                publishShareExtensionTargets(reason: "foreground")
                scheduleShareInboxSweep(reason: "foreground")
                presentQueuedShareForSelectedHostIfClear(reason: "foreground")
            }
            persistRestoreSnapshots()
        }
        .onChange(of: appPhase.state) { _, state in
            updateAgentAttentionBackgroundKeepAlive(
                reason: "app-phase-\(state.rawValue)"
            )
        }
        .onAppear {
            configureCurrentSSHAuthenticationPolicy()
            logRestoreDiag(
                "content-appear locked=\(appLockController.isLocked) active=\(appPhase.isActive) activeCount=\(activeSessions.count) didEvaluateStartupRestore=\(didEvaluateStartupRestore)"
            )
            sessionRegistry.syncActiveSessions(activeSessions)
            agentCenter.setEnabled(appearance.agentCenterEnabled)
            agentCenter.setApplicationActive(appPhase.isActive)
            updateAgentAttentionBackgroundKeepAlive(reason: "content-appear")
            if !appearance.agentCenterEnabled {
                bellController.cancelAgentNotifications()
            }
            agentCenter.syncProfiles(swipePadStore.profiles)
            agentCenter.onJumpToSession = { id in selectSession(id) }
            agentCenter.onAttention = { attention, agent in
                bellController.agentAttention(attention, agent: agent)
            }
            agentCenter.onAttentionAcknowledged = { agentID in
                bellController.cancelAgentNotification(for: agentID)
            }
            AgentNotificationRouter.shared.onRoute = { route in
                guard appearance.agentCenterEnabled else { return }
                agentCenter.jump(agentID: route)
            }
            updateAgentSurfaceDemand()
            handlePendingAgentNotification()
            if case .session(let id) = selectedItem {
                sessionRegistry.markTouched(id)
            }
            attemptStartupRestoreIfReady()
            publishShareExtensionTargets(reason: "appear")
            scheduleShareInboxSweep(reason: "appear")
            presentQueuedShareForSelectedHostIfClear(reason: "appear")
            maybeBeginOnboarding()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(item: $hostKeyRequest) { request in
            HostKeyVerificationView(
                request: request,
                onTrust: {
                    request.accept()
                    hostKeyRequest = nil
                },
                onReject: {
                    request.reject()
                    hostKeyRequest = nil
                }
            )
            .interactiveDismissDisabled()
        }
        .sheet(item: $restorePrompt) { prompt in
            SessionRestoreSheet(
                prompt: prompt,
                alwaysReopen: $restoreAlwaysReopen,
                onReopen: { reopenPreviousConnections(prompt) },
                onNotNow: { skipPreviousConnections() }
            )
        }
        .sheet(item: $uploadRequest) { request in
            UploadSheetView(
                request: request,
                model: uploadSheetModel,
                onUpload: { candidate, destination, pastePath in
                    let queuedUpload = activeShareQueueUpload
                    performUpload(
                        request: request,
                        candidate: candidate,
                        destination: destination,
                        pastePath: pastePath
                    )
                    uploadRequest = nil
                    if let queuedUpload {
                        finishQueuedShareUpload(queuedUpload, reason: "uploaded")
                    }
                },
                onCancel: {
                    let queuedUpload = activeShareQueueUpload
                    uploadRequest = nil
                    if let queuedUpload {
                        finishQueuedShareUpload(queuedUpload, reason: "cancelled")
                    }
                },
                onResolveCwd: { candidate in
                    resolveSessionCwdIfNeeded(for: candidate.id)
                }
            )
        }
        .onOpenURL { url in
            handleIncomingOpenURL(url)
        }
        .onChange(of: restorePrompt == nil) { _, _ in
            presentParkedUploadIfClear()
            presentQueuedShareForSelectedHostIfClear(reason: "restore-cleared")
        }
        .onChange(of: hostKeyRequest == nil) { _, _ in
            presentParkedUploadIfClear()
            presentQueuedShareForSelectedHostIfClear(reason: "hostkey-cleared")
        }
        .alert(
            "upload failed",
            isPresented: Binding(
                get: { uploadFailureMessage != nil },
                set: { if !$0 { uploadFailureMessage = nil } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(uploadFailureMessage ?? "")
        }
        .onReceive(hostKeyVerificationPublisher) { request in
            if request.isResolved {
                return
            }
            if hostKeyRequest?.id == request.id {
                return
            }
            if let current = hostKeyRequest,
               current.isSameChallenge(as: request) {
                current.coalesce(request)
                DiagnosticLogStore.appendSSH(
                    "hostkey prompt coalesced duplicate endpoint=\(request.endpoint) keyType=\(request.keyType)"
                )
                return
            }
            // If a previous request is still pending (two sessions
            // connecting simultaneously), reject it so its continuation
            // doesn't leak. Only one prompt at a time.
            if let previous = hostKeyRequest {
                previous.reject()
            }
            hostKeyRequest = request
        }
        .onReceive(detectedOSHintPublisher) { detection in
            persistDetectedOSHint(detection.osHint, forHostID: detection.hostID)
        }
        .onReceive(sessionStatePublisher) { event in
            logRestoreDiag(
                "session-state live=\(shortID(event.liveSessionID)) host=\(shortID(event.persistedHostID)) transport=\(event.transport) state=\(stateDescription(event.state)) active=\(appPhase.isActive)"
            )
            if event.transport == "mosh", case .failed = event.state {
                attemptMoshJumpFallback(liveSessionID: event.liveSessionID)
            }
            persistRestoreSnapshots()
            refreshUploadCandidatesIfPresented()
            publishShareExtensionTargets(reason: "session-state")
            presentQueuedShareForSelectedHostIfClear(reason: "session-state")
        }
        .onReceive(remoteCwdPublisher) { _ in
            refreshUploadCandidatesIfPresented()
            publishShareExtensionTargets(reason: "remote-cwd")
            presentQueuedShareForSelectedHostIfClear(reason: "remote-cwd")
        }
    }

    /// Merges `pendingHostKeyVerification` from all active SSH sessions
    /// into a single publisher so the sheet triggers for any session.
    /// Mosh sessions don't expose a host key verification channel
    /// directly over UDP; their SSH bootstrap step feeds the same
    /// request channel.
    private var hostKeyVerificationPublisher: some Publisher<HostKeyVerificationRequest, Never> {
        Publishers.MergeMany(
            activeSessions.compactMap { live -> AnyPublisher<HostKeyVerificationRequest, Never>? in
                switch live.session {
                case .ssh(let session):
                    return session.$pendingHostKeyVerification
                        .compactMap { $0 }
                        .eraseToAnyPublisher()
                case .mosh(let session):
                    return session.$pendingHostKeyVerification
                        .compactMap { $0 }
                        .eraseToAnyPublisher()
                }
            }
        )
    }

    /// Merges OS detections from active sessions (SSH side-channel probe
    /// for SSH transport; mosh-bootstrap probe for mosh transport) and
    /// carries the persisted host id so the writeback can target SwiftData.
    private var detectedOSHintPublisher: some Publisher<(hostID: UUID, osHint: String), Never> {
        Publishers.MergeMany(
            activeSessions.map { live -> AnyPublisher<(hostID: UUID, osHint: String), Never> in
                let hostID: UUID
                let publisher: AnyPublisher<String?, Never>
                switch live.session {
                case .ssh(let session):
                    hostID = session.host.id
                    publisher = session.$detectedOSHint.eraseToAnyPublisher()
                case .mosh(let session):
                    hostID = session.host.id
                    publisher = session.$detectedOSHint.eraseToAnyPublisher()
                }
                return publisher
                    .compactMap { detected -> (hostID: UUID, osHint: String)? in
                        guard let detected else { return nil }
                        return (hostID: hostID, osHint: detected)
                    }
                    .eraseToAnyPublisher()
            }
        )
    }

    /// Fires when any live session's cwd mirror updates (tmux pane
    /// metadata, OSC 7, poller, on-demand resolve) — keeps the Upload
    /// sheet's "session cwd" row live. dropFirst skips the @Published
    /// replay on every resubscription.
    private var remoteCwdPublisher: AnyPublisher<Void, Never> {
        guard !activeSessions.isEmpty else {
            return Empty().eraseToAnyPublisher()
        }
        return Publishers.MergeMany(
            activeSessions.map { live -> AnyPublisher<Void, Never> in
                switch live.session {
                case .ssh(let session):
                    return session.$remoteWorkingDirectory
                        .dropFirst().map { _ in () }.eraseToAnyPublisher()
                case .mosh(let session):
                    return session.$remoteWorkingDirectory
                        .dropFirst().map { _ in () }.eraseToAnyPublisher()
                }
            }
        ).eraseToAnyPublisher()
    }

    private var sessionStatePublisher: AnyPublisher<RestoreStateEvent, Never> {
        guard !activeSessions.isEmpty else {
            return Empty().eraseToAnyPublisher()
        }

        return Publishers.MergeMany(
            activeSessions.map { live -> AnyPublisher<RestoreStateEvent, Never> in
                switch live.session {
                case .ssh(let session):
                    return session.$state
                        .map {
                            RestoreStateEvent(
                                liveSessionID: live.id,
                                persistedHostID: live.persistedHostID,
                                transport: "ssh",
                                state: $0
                            )
                        }
                        .eraseToAnyPublisher()
                case .mosh(let session):
                    return session.$state
                        .map {
                            RestoreStateEvent(
                                liveSessionID: live.id,
                                persistedHostID: live.persistedHostID,
                                transport: "mosh",
                                state: $0
                            )
                        }
                        .eraseToAnyPublisher()
                }
            }
        )
        .eraseToAnyPublisher()
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack {
            // All active sessions live here simultaneously.
            // Only the selected one is visible; others stay alive
            // but hidden so their TerminalView state is preserved.
            ForEach(activeSessions) { live in
                let isSelected = selectedItem == .session(live.id)
                // Branch on transport: each case wires a concrete
                // session view that owns its `@StateObject` of the
                // matching type. Existentials of `ObservableObject`
                // don't compose with SwiftUI property wrappers, so
                // the enum is the seam between the value-level
                // `Session` and the reference-level view binding.
                switch live.session {
                case .ssh(let sshSession):
                    SessionView(
                        session: sshSession,
                        liveSessionID: live.id,
                        isActive: isSelected,
                        onToggleSidebar: {
                            withAnimation {
                                columnVisibility = columnVisibility == .detailOnly
                                    ? .automatic : .detailOnly
                            }
                        },
                        sidebarVisible: sidebarVisible,
                        onBack: {
                            selectedItem = nil
                            columnVisibility = .automatic
                        },
                        onEditHost: {
                            activeSessions.removeAll { $0.id == live.id }
                            selectedItem = .host(sshSession.host.id)
                            columnVisibility = .automatic
                        },
                        onRetry: {
                            let hostID = sshSession.host.id
                            activeSessions.removeAll { $0.id == live.id }
                            if let persisted = fetchHost(hostID) {
                                connect(to: persisted)
                            }
                        },
                        onSessionEnded: {
                            let wasSelected = selectedItem == .session(live.id)
                            activeSessions.removeAll { $0.id == live.id }
                            if wasSelected {
                                selectedItem = nil
                                columnVisibility = .automatic
                            }
                        },
                        onSelectSession: { id in
                            selectSession(id)
                        },
                        onOpenSettings: openSettings,
                        onOpenAgentCenter: appearance.agentCenterEnabled
                            ? toggleAgentCenter : nil
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .ignoresSafeArea(.container, edges: .bottom)
                case .mosh(let moshSession):
                    MoshSessionView(
                        session: moshSession,
                        liveSessionID: live.id,
                        isActive: isSelected,
                        onToggleSidebar: {
                            withAnimation {
                                columnVisibility = columnVisibility == .detailOnly
                                    ? .automatic : .detailOnly
                            }
                        },
                        sidebarVisible: sidebarVisible,
                        onBack: {
                            selectedItem = nil
                            columnVisibility = .automatic
                        },
                        onEditHost: {
                            activeSessions.removeAll { $0.id == live.id }
                            selectedItem = .host(moshSession.host.id)
                            columnVisibility = .automatic
                        },
                        onRetry: {
                            let hostID = moshSession.host.id
                            activeSessions.removeAll { $0.id == live.id }
                            if let persisted = fetchHost(hostID) {
                                connect(to: persisted)
                            }
                        },
                        onSessionEnded: {
                            let wasSelected = selectedItem == .session(live.id)
                            activeSessions.removeAll { $0.id == live.id }
                            if wasSelected {
                                selectedItem = nil
                                columnVisibility = .automatic
                            }
                        },
                        onSelectSession: { id in
                            selectSession(id)
                        },
                        onOpenSettings: openSettings,
                        onOpenAgentCenter: appearance.agentCenterEnabled
                            ? toggleAgentCenter : nil
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }

            // Host detail / placeholder shown when no session is selected.
            if !isSessionSelected  {
                Group {
                    switch selectedItem {
                    case .host(let hostID):
                        if let host = fetchHost(hostID) {
                            HostDetailView(
                                host: host,
                                onConnect: { persistedHost, password, jumpPasswords in
                                    connect(
                                        to: persistedHost,
                                        password: password,
                                        jumpPasswords: jumpPasswords
                                    )
                                },
                                onCancel: { dismissEditor(host: host, deleteIfDraft: true) },
                                onDelete: { dismissEditor(host: host, deleteIfDraft: false, force: true) }
                            )
                        } else {
                            landing
                        }
                    case .keys:
                        KeysPageView()
                    case .agents:
                        if appearance.agentCenterEnabled {
                            AgentCenterPage(center: agentCenter)
                        } else {
                            landing
                        }
                    case .knownHosts:
                        KnownHostsPageView()
                    case .tunnels:
                        TunnelsPageView { persistedHost in
                            selectedItem = .host(persistedHost.id)
                        }
                    case .settings:
                        SettingsPageView(
                            onUploadDiagnosticLog: uploadDiagnosticLog
                        )
                    default:
                        landing
                    }
                }
                // Push-aside: when the nav column is shown, browse pages sit
                // beside it (leading inset == sidebar width). When hidden, they
                // go full-width but take a top inset so their title clears the
                // floating reveal button. Cheap to relayout here — no terminal
                // grid to reflow, which is why float (no-inset) is session-only.
                .padding(.leading, sidebarVisible ? SessionSidebar.width : 0)
                .padding(.top, sidebarVisible ? 0 : 50)
            }
        }
    }

    private var isSessionSelected: Bool {
        if case .session = selectedItem { return true }
        return false
    }

    /// Hides the sidebar (backs the in-panel `‹` button).
    private func collapseSidebar() {
        withAnimation(.easeInOut(duration: 0.24)) {
            columnVisibility = .detailOnly
        }
    }

    /// Shows the sidebar (backs the browse-page reveal button).
    private func revealSidebar() {
        withAnimation(.easeInOut(duration: 0.24)) {
            columnVisibility = .automatic
        }
    }

    /// Floating glass "show sidebar" control for browse pages when the sidebar
    /// is hidden. Same `line.3.horizontal` glyph as the terminal top-bar toggle.
    private var sidebarRevealButton: some View {
        Button(action: revealSidebar) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(T.fgMuted)
                .frame(width: 34, height: 34)
                .floatingGlass(
                    appearance.chromeMaterial,
                    tint: T.sidebarBg,
                    solidFill: T.isLight ? Color(rgbInt: 0xF2F2F7) : Color(rgbInt: 0x1C1C1E),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(T.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("show sidebar")
        .padding(.leading, 14)
        .padding(.top, 14)
    }


    private var landing: some View {
        HostsLandingView(
            onConnect: { host in connect(to: host) },
            onEdit: { host in selectedItem = .host(host.id) },
            onNewHost: createAndEditNewHost,
            onQuickConnect: handleQuickConnect,
            onOpenKeys: { selectedItem = .keys },
            activeHostKeys: Set(activeSessions.map { $0.hostKey })
        )
    }

    /// Returns to the landing page from the host editor. With `force: true`
    /// the host is always deleted (the trash button). With `deleteIfDraft: true`
    /// the host is deleted only if it's still empty (a never-filled-in ⌘N
    /// draft) so cancel doesn't leave litter in the host list.
    private func dismissEditor(host: PersistedHost, deleteIfDraft: Bool, force: Bool = false) {
        let isDraft = host.name.trimmingCharacters(in: .whitespaces).isEmpty
            && host.address.trimmingCharacters(in: .whitespaces).isEmpty
        if force || (deleteIfDraft && isDraft) {
            hostBackgrounds.removeOverride(for: host.id)
            // GC only this host's outgoing jump link. Links pointing AT
            // this host stay: dependents must fail closed ("jump host no
            // longer exists"), never silently connect direct.
            HostJumpChainResolver.removeOutgoingLink(for: host.id, in: modelContext)
            modelContext.delete(host)
            try? modelContext.save()
        }
        selectedItem = nil
    }

    private func fetchHost(_ id: UUID) -> PersistedHost? {
        let descriptor = FetchDescriptor<PersistedHost>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Installs the one live SwiftData-backed resolver used by every new SSH
    /// leg, including Mosh side channels, Files, and key/shell installers.
    /// The fallback contributes only an ephemeral password entered for this
    /// session; endpoint, identity, key metadata, and global policy are fetched
    /// again immediately before authentication.
    private func configureCurrentSSHAuthenticationPolicy() {
        let context = modelContext
        let preferences = appearance
        SSHAuthenticationPolicyStore.shared.configureCurrentPolicyProvider {
            hostID, fallback in
            let hostDescriptor = FetchDescriptor<PersistedHost>(
                predicate: #Predicate { $0.id == hostID }
            )
            guard let persisted = try? context.fetch(hostDescriptor).first else {
                return nil
            }

            let storedKey: StoredKey?
            if case .key(let keyID) = persisted.identity?.credentialMode {
                let keyDescriptor = FetchDescriptor<StoredKey>(
                    predicate: #Predicate { $0.id == keyID }
                )
                storedKey = try? context.fetch(keyDescriptor).first
            } else {
                storedKey = nil
            }

            let requiresOwnerPresence: Bool
            let preferredOwnerPresence: Bool
            if case .key = persisted.identity?.credentialMode {
                requiresOwnerPresence = requiresOwnerPresenceForKeyUse(
                    key: storedKey,
                    globalPreference: preferences.requireBiometricForKeyUse
                )
                preferredOwnerPresence = preferences.requireBiometricForKeyUse
                    && (storedKey?.requiresBiometric ?? false)
            } else {
                requiresOwnerPresence = false
                preferredOwnerPresence = false
            }

            let transientPassword: String
            let transientRevision: HostPasswordCredentialRevision?
            if case .ephemeral = fallback.passwordCredentialRevision,
               !fallback.password.isEmpty {
                transientPassword = fallback.password
                transientRevision = fallback.passwordCredentialRevision
            } else {
                transientPassword = ""
                transientRevision = nil
            }

            let transientJumpPasswords: [UUID: HostTransientPasswordCredential] = Dictionary(
                uniqueKeysWithValues: fallback.jumpChain.compactMap { hop in
                    guard !hop.password.isEmpty,
                          case .ephemeral = hop.passwordCredentialRevision else {
                        return nil as (UUID, HostTransientPasswordCredential)?
                    }
                    return (
                        hop.id,
                        HostTransientPasswordCredential(
                            password: hop.password,
                            revision: hop.passwordCredentialRevision
                        )
                    )
                }
            )

            return SSHConnectionPolicyDraft(
                host: Host(
                    from: persisted,
                    transientPassword: transientPassword,
                    transientPasswordCredentialRevision: transientRevision,
                    transientJumpPasswords: transientJumpPasswords
                ),
                requireBiometric: requiresOwnerPresence,
                isSecureEnclave: storedKey?.isSecureEnclave ?? false,
                keyAlgorithm: storedKey?.algorithm,
                ownerPresencePreference: preferredOwnerPresence
            )
        }
        SSHAuthenticationPolicyStore.shared.registerPersistedHosts(
            fetchHosts().map(\.id)
        )
        SSHAuthenticationPolicyStore.shared.observeGlobalKeyRequirement(
            appearance.requireBiometricForKeyUse
        )
        SSHAuthenticationPolicyStore.shared.observePasswordCredentialRevision(
            KeychainHelper.passwordCredentialRevision
        )
    }

    // MARK: - Share-in (Upload sheet)

    private func handleIncomingOpenURL(_ url: URL) {
        if handleShareExtensionURL(url) {
            return
        }
        handleIncomingShareURL(url)
    }

    private func handleShareExtensionURL(_ url: URL) -> Bool {
        guard url.scheme == "tessera", url.host == "share-inbox" else {
            return false
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard
            let itemID = components?.queryItems?.first(where: { $0.name == "id" })?.value,
            UUID(uuidString: itemID) != nil
        else {
            DiagnosticLogStore.appendApp("share-extension open ignored reason=invalid-id")
            return true
        }
        DiagnosticLogStore.appendApp("share-extension open received id=\(String(itemID.prefix(8)))")
        scheduleShareInboxSweep(reason: "open-url")
        presentQueuedShareForSelectedHostIfClear(reason: "open-url")
        return true
    }

    private func scheduleShareInboxSweep(reason: String) {
        processPendingShareInboxItems(reason: reason)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            processPendingShareInboxItems(reason: "\(reason)-delayed")
        }
    }

    private func processPendingShareInboxItems(reason: String) {
        guard !appLockController.isLocked else { return }
        guard let rootURL = shareInboxRootURL() else { return }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }

        do {
            for directory in try shareInboxDirectories(rootURL: rootURL) {
                if isShareInboxConsumed(directory.lastPathComponent) {
                    cleanupShareInboxDirectory(directory, reason: "\(reason)-already-consumed")
                    continue
                }
                if shareInboxFiles(in: directory).isEmpty {
                    markShareInboxConsumed(directory.lastPathComponent)
                    cleanupShareInboxDirectory(directory, reason: "\(reason)-empty")
                    continue
                }
                if readShareInboxMetadata(in: directory)?.targetHostID == nil {
                    markShareInboxConsumed(directory.lastPathComponent)
                    cleanupShareInboxDirectory(directory, reason: "\(reason)-untargeted")
                }
            }
            presentQueuedShareForSelectedHostIfClear(reason: reason)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            DiagnosticLogStore.appendApp("share-extension sweep failed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    private func shareInboxRootURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: shareInboxAppGroupID)?
            .appendingPathComponent(shareInboxFolderName, isDirectory: true)
    }

    private func shareInboxTargetsURL() -> URL? {
        shareInboxRootURL()?
            .appendingPathComponent(shareInboxTargetsFileName, isDirectory: false)
    }

    private func publishShareExtensionTargets(reason: String) {
        publishShareExtensionTargets(candidates: uploadHostCandidates(), reason: reason)
    }

    private func publishShareExtensionTargets(
        candidates: [UploadHostCandidate],
        reason: String
    ) {
        guard let targetsURL = shareInboxTargetsURL() else { return }
        do {
            try FileManager.default.createDirectory(
                at: targetsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let document = ShareExtensionUploadTargetsDocument(
                updatedAt: Date(),
                targets: candidates.map(ShareExtensionUploadTarget.init(candidate:))
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: targetsURL, options: .atomic)
            DiagnosticLogStore.appendApp(
                "share-extension targets published reason=\(reason) count=\(document.targets.count)"
            )
        } catch {
            DiagnosticLogStore.appendApp(
                "share-extension targets publish failed reason=\(reason) error=\(error.localizedDescription)"
            )
        }
    }

    private var shareInboxDefaults: UserDefaults {
        UserDefaults(suiteName: shareInboxAppGroupID) ?? .standard
    }

    private func isShareInboxConsumed(_ itemID: String) -> Bool {
        shareInboxDefaults.stringArray(forKey: shareInboxConsumedDefaultsKey)?
            .contains(itemID) == true
    }

    private func markShareInboxConsumed(_ itemID: String) {
        var consumed = shareInboxDefaults.stringArray(forKey: shareInboxConsumedDefaultsKey) ?? []
        consumed.removeAll { $0 == itemID }
        consumed.append(itemID)
        if consumed.count > shareInboxConsumedLimit {
            consumed = Array(consumed.suffix(shareInboxConsumedLimit))
        }
        shareInboxDefaults.set(consumed, forKey: shareInboxConsumedDefaultsKey)
    }

    private func cleanupShareInboxDirectory(_ inboxURL: URL, reason: String) {
        do {
            try FileManager.default.removeItem(at: inboxURL)
            DiagnosticLogStore.appendApp(
                "share-extension inbox cleanup ok reason=\(reason) id=\(inboxURL.lastPathComponent)"
            )
        } catch CocoaError.fileNoSuchFile {
            return
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            DiagnosticLogStore.appendApp(
                "share-extension inbox cleanup failed reason=\(reason) id=\(inboxURL.lastPathComponent) error=\(error.localizedDescription)"
            )
        }
    }

    private func presentQueuedShareForSelectedHostIfClear(reason: String) {
        guard !appLockController.isLocked,
              pendingUploadRequest == nil,
              uploadRequest == nil,
              restorePrompt == nil,
              hostKeyRequest == nil,
              activeShareQueueUpload == nil,
              let hostID = selectedShareQueueHostID(),
              let queued = nextQueuedShareFile(for: hostID)
        else { return }

        let candidates = uploadHostCandidates()
        guard let candidate = candidates.first(where: { $0.id == hostID }) else {
            DiagnosticLogStore.appendApp(
                "share-extension queue skipped reason=\(reason) host=\(String(hostID.uuidString.prefix(8))) missing-candidate=true"
            )
            return
        }

        do {
            activeShareQueueUpload = ActiveShareQueueUpload(
                itemID: queued.itemID,
                inboxURL: queued.inboxURL,
                hostID: hostID,
                sourceFileURL: queued.fileURL
            )
            uploadSheetModel.candidates = [candidate]
            uploadRequest = try makeUploadRequest(
                from: queued.fileURL,
                displayName: queued.fileURL.lastPathComponent,
                sourceHint: "Share"
            )
            DiagnosticLogStore.appendApp(
                "share-extension queue presenting reason=\(reason) host=\(String(hostID.uuidString.prefix(8))) file=\(queued.fileURL.lastPathComponent)"
            )
        } catch {
            activeShareQueueUpload = nil
            uploadFailureMessage = "\(queued.fileURL.lastPathComponent): \(error.localizedDescription)"
            DiagnosticLogStore.appendApp(
                "share-extension queue staging failed reason=\(reason) host=\(String(hostID.uuidString.prefix(8))) error=\(error.localizedDescription)"
            )
        }
    }

    private func selectedShareQueueHostID() -> UUID? {
        switch selectedItem {
        case .session(let id):
            return activeSessions.first(where: { $0.id == id })?.persistedHostID
        case .host(let id):
            return id
        default:
            return nil
        }
    }

    private func nextQueuedShareFile(for hostID: UUID) -> ShareInboxQueuedFile? {
        guard let rootURL = shareInboxRootURL(),
              FileManager.default.fileExists(atPath: rootURL.path)
        else { return nil }

        do {
            for inboxURL in try shareInboxDirectories(rootURL: rootURL) {
                let itemID = inboxURL.lastPathComponent
                if isShareInboxConsumed(itemID) {
                    cleanupShareInboxDirectory(inboxURL, reason: "queue-already-consumed")
                    continue
                }
                let metadata = readShareInboxMetadata(in: inboxURL)
                guard metadata?.targetHostID == hostID else { continue }
                let files = shareInboxFiles(in: inboxURL)
                guard let fileURL = files.first else {
                    markShareInboxConsumed(itemID)
                    cleanupShareInboxDirectory(inboxURL, reason: "queue-empty")
                    continue
                }
                return ShareInboxQueuedFile(
                    itemID: itemID,
                    inboxURL: inboxURL,
                    hostID: metadata?.targetHostID,
                    fileURL: fileURL
                )
            }
        } catch {
            DiagnosticLogStore.appendApp(
                "share-extension queue scan failed host=\(String(hostID.uuidString.prefix(8))) error=\(error.localizedDescription)"
            )
        }
        return nil
    }

    private func finishQueuedShareUpload(
        _ queued: ActiveShareQueueUpload,
        reason: String
    ) {
        activeShareQueueUpload = nil
        do {
            try FileManager.default.removeItem(at: queued.sourceFileURL)
            DiagnosticLogStore.appendApp(
                "share-extension queue file consumed reason=\(reason) host=\(String(queued.hostID.uuidString.prefix(8))) file=\(queued.sourceFileURL.lastPathComponent)"
            )
        } catch CocoaError.fileNoSuchFile {
            DiagnosticLogStore.appendApp(
                "share-extension queue file already missing reason=\(reason) file=\(queued.sourceFileURL.lastPathComponent)"
            )
        } catch CocoaError.fileReadNoSuchFile {
            DiagnosticLogStore.appendApp(
                "share-extension queue file already missing reason=\(reason) file=\(queued.sourceFileURL.lastPathComponent)"
            )
        } catch {
            DiagnosticLogStore.appendApp(
                "share-extension queue file cleanup failed reason=\(reason) file=\(queued.sourceFileURL.lastPathComponent) error=\(error.localizedDescription)"
            )
        }

        if shareInboxFiles(in: queued.inboxURL).isEmpty {
            markShareInboxConsumed(queued.itemID)
            cleanupShareInboxDirectory(queued.inboxURL, reason: "queue-\(reason)")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            presentQueuedShareForSelectedHostIfClear(reason: "queue-\(reason)-next")
        }
    }

    private func shareInboxDirectories(rootURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .contentModificationDateKey,
                .creationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == true
        }
        .sorted { lhs, rhs in
            shareInboxSortDate(lhs) < shareInboxSortDate(rhs)
        }
    }

    private func shareInboxFiles(in inboxURL: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: inboxURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey,
                    .creationDateKey
                ],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true) == false
                    && url.lastPathComponent != shareInboxMetadataFileName
            }
            .sorted { lhs, rhs in
                shareInboxSortDate(lhs) < shareInboxSortDate(rhs)
            }
        } catch {
            return []
        }
    }

    private func readShareInboxMetadata(in inboxURL: URL) -> ShareInboxMetadata? {
        let metadataURL = inboxURL
            .appendingPathComponent(shareInboxMetadataFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        do {
            return try JSONDecoder().decode(ShareInboxMetadata.self, from: data)
        } catch {
            DiagnosticLogStore.appendApp(
                "share-extension metadata ignored id=\(inboxURL.lastPathComponent) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private func shareInboxSortDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .creationDateKey
        ])
        return values?.contentModificationDate
            ?? values?.creationDate
            ?? .distantPast
    }

    /// "Copy to Tessera" entry point. The provided URL is only readable
    /// inside this callback (security scope), so stage a copy first;
    /// the sheet presents against the staged file. Never auto-connects:
    /// the bridge dials only when the user taps Upload.
    private func handleIncomingShareURL(_ url: URL) {
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        stageUploadRequest(
            from: url,
            displayName: url.lastPathComponent,
            sourceHint: nil,
            failureContext: "share-in",
            cleanupURL: nil
        )
    }

    private func uploadDiagnosticLog() {
        guard !DiagnosticLogStore.info().isEmpty else { return }
        stageUploadRequest(
            from: DiagnosticLogStore.logFileURL,
            displayName: "tessera-diagnostics.log",
            sourceHint: "Diagnostics",
            failureContext: "diagnostics-upload",
            cleanupURL: nil
        )
    }

    @discardableResult
    private func stageUploadRequest(
        from url: URL,
        displayName: String,
        sourceHint: String?,
        failureContext: String,
        cleanupURL: URL?
    ) -> Bool {
        do {
            pendingUploadRequest = try makeUploadRequest(
                from: url,
                displayName: displayName,
                sourceHint: sourceHint
            )
            if let cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
            presentParkedUploadIfClear()
            return true
        } catch {
            let message = error.localizedDescription
            DiagnosticLogStore.appendApp("\(failureContext) staging failed: \(message)")
            uploadFailureMessage = "\(displayName): \(message)"
            return false
        }
    }

    private func makeUploadRequest(
        from url: URL,
        displayName: String,
        sourceHint: String?
    ) throws -> UploadRequest {
        let staged = try FilesPanelController.stageLocalCopy(of: url)
        let size = (try? FileManager.default
            .attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?
            .uint64Value
        return UploadRequest(
            stagedURL: staged,
            displayName: displayName,
            fileSize: size,
            sourceHint: sourceHint
        )
    }

    /// Single gate for presenting a parked share-in request: only when
    /// unlocked and no sibling sheet is up. Re-attempted whenever the
    /// lock, the restore prompt, or the host-key prompt clears.
    private func presentParkedUploadIfClear() {
        guard let parked = pendingUploadRequest,
              uploadRequest == nil,
              restorePrompt == nil,
              hostKeyRequest == nil,
              !appLockController.isLocked else { return }
        pendingUploadRequest = nil
        uploadSheetModel.candidates = uploadHostCandidates()
        uploadRequest = parked
    }

    private func refreshUploadCandidatesIfPresented() {
        guard uploadRequest != nil else { return }
        // Change-guarded: the cwd/state publishers replay on
        // resubscription; writing an equal array would re-render (and
        // resubscribe) for nothing.
        let fresh = uploadCandidatesForPresentedSheet()
        if fresh != uploadSheetModel.candidates {
            uploadSheetModel.candidates = fresh
            DiagnosticLogStore.appendApp(
                "upload-sheet candidates refreshed: "
                + fresh.map { "\($0.label):\($0.isConnected ? "up" : $0.isConnecting ? "conn" : $0.isFailed ? "fail" : "down")" }
                    .joined(separator: " ")
            )
        }
    }

    private func uploadCandidatesForPresentedSheet() -> [UploadHostCandidate] {
        let candidates = uploadHostCandidates()
        guard let hostID = activeShareQueueUpload?.hostID else {
            return candidates
        }
        return candidates.filter { $0.id == hostID }
    }

    /// On-demand cwd for the Upload sheet's selected host. The mirror
    /// (session.remoteWorkingDirectory) is only fed organically by tmux
    /// pane metadata, OSC 7, or the panel's poller — on plain SSH/mosh
    /// with no panel ever opened it's empty at share time. This runs
    /// ONE discovery exec over the host's bridge (same machinery as the
    /// panel's poller; the user's share/selection is the gesture that
    /// permits the bridge connect — no terminal session is opened).
    private func resolveSessionCwdIfNeeded(for candidateID: UUID) {
        guard let live = activeSessions.first(where: {
            $0.persistedHostID == candidateID
                && $0.session.terminalSession.state == .connected
        }) else {
            DiagnosticLogStore.appendApp(
                "upload-cwd resolve skipped host=\(String(candidateID.uuidString.prefix(8))) reason=no-connected-session"
            )
            return
        }
        let terminal = live.session.terminalSession
        if terminal.remoteWorkingDirectory != nil {
            // Mirror already knows (e.g. it filled after the sheet
            // presented) — just get the row updated.
            DiagnosticLogStore.appendApp("upload-cwd resolve mirror-already-set")
            refreshUploadCandidatesIfPresented()
            return
        }
        guard !cwdResolutionsInFlight.contains(candidateID) else {
            DiagnosticLogStore.appendApp("upload-cwd resolve already-in-flight")
            return
        }
        let discovery: RemoteCwdPoller.ShellDiscovery
        if live.launchMode != .customCommand {
            // tmux launch modes: NEVER guess with the shell heuristic —
            // the host can run several tmux sessions and it confidently
            // answers with another session's window. Ask tmux itself
            // for OUR named session's active pane: session-scoped, and
            // independent of the -CC side channel, which is
            // deliberately DOWN for backgrounded sessions (007c674
            // steady state), so pane metadata can't answer here.
            guard let name = MoshBootstrap.resolvedTmuxSessionName(
                for: terminal.host) else {
                DiagnosticLogStore.appendApp(
                    "upload-cwd resolve skipped reason=tmux-mode-without-session-name"
                )
                return
            }
            discovery = .tmuxSession(name: name)
        } else if case .mosh(let s) = live.session, let pid = s.remoteServerPID {
            // The PID anchor beats the heuristic when the bootstrap
            // banner delivered one.
            discovery = .moshServerChild(serverPID: pid)
        } else {
            discovery = .newestLoginShell
        }
        // Credential-reuse rule as in performUpload: the live session's
        // snapshot, never a rebuilt DTO.
        let bridge: FileBridge
        switch live.session {
        case .ssh(let s):
            bridge = fileBridges.bridge(
                for: s.host, requireBiometric: s.requireBiometric,
                isSecureEnclave: s.isSecureEnclave)
        case .mosh(let s):
            bridge = fileBridges.bridge(
                for: s.host, requireBiometric: s.requireBiometric,
                isSecureEnclave: s.isSecureEnclave)
        }
        cwdResolutionsInFlight.insert(candidateID)
        DiagnosticLogStore.appendApp(
            "upload-cwd resolve mode=\(live.launchMode.rawValue) discovery=\(String(describing: discovery))"
        )
        Task {
            defer { cwdResolutionsInFlight.remove(candidateID) }
            do {
                try await bridge.connect()
                let output = try await bridge.exec(
                    RemoteCwdPoller.discoveryCommand(for: discovery),
                    inShell: false
                )
                let path = RemoteCwdPoller.reportedPath(in: output)
                DiagnosticLogStore.appendApp(
                    "upload-cwd resolve result=\(path == nil ? "missing" : "present") rawBytes=\(output.utf8.count)"
                )
                // Don't stomp a value that arrived organically (pane
                // metadata / OSC 7) while the probe was in flight.
                if terminal.remoteWorkingDirectory == nil, let path {
                    terminal.remoteWorkingDirectory = path
                }
            } catch {
                DiagnosticLogStore.appendApp(
                    "upload-cwd resolve failed error=\(error.localizedDescription)"
                )
                // cwd row simply stays disabled; temp still works.
            }
            refreshUploadCandidatesIfPresented()
        }
    }

    /// Host rows for the Upload sheet. Persisted hosts only — a
    /// quick-connect session's credentials died with its DTO, so the
    /// bridge couldn't be rebuilt for it.
    private func uploadHostCandidates() -> [UploadHostCandidate] {
        let selectedSessionID: UUID? = {
            if case .session(let id) = selectedItem { return id }
            return nil
        }()
        return fetchHosts().map { host in
            let sessions = activeSessions.filter { $0.persistedHostID == host.id }
            let connected = sessions.filter {
                $0.session.terminalSession.state == .connected
            }
            let connecting = sessions.contains {
                switch $0.session.terminalSession.state {
                case .idle, .connecting: return true
                default: return false
                }
            }
            let failed = sessions.contains {
                if case .failed = $0.session.terminalSession.state { return true }
                return false
            }
            let cwdSource = connected.first { $0.id == selectedSessionID }
                ?? connected.max { $0.createdAt < $1.createdAt }
            return UploadHostCandidate(
                id: host.id,
                label: "\(host.user)@\(host.name.isEmpty ? host.address : host.name)",
                isConnected: !connected.isEmpty,
                isConnecting: connected.isEmpty && connecting,
                isActiveSession: connected.contains { $0.id == selectedSessionID },
                isFailed: connected.isEmpty && !connecting && failed,
                sessionCwd: cwdSource?.session.terminalSession.remoteWorkingDirectory
            )
        }
    }

    private func performUpload(
        request: UploadRequest,
        candidate: UploadHostCandidate,
        destination: UploadDestination,
        pastePath: Bool
    ) {
        let bridge: FileBridge
        if let live = activeSessions.first(where: { $0.persistedHostID == candidate.id }) {
            // A live session exists: reuse ITS credential snapshot. The
            // rebuilt-DTO path below would carry an empty transient
            // password, and the registry refreshes the cached (shared!)
            // bridge's credentials on every hit — rebuilding here would
            // stomp the working password the session typed at connect.
            switch live.session {
            case .ssh(let s):
                bridge = fileBridges.bridge(
                    for: s.host,
                    requireBiometric: s.requireBiometric,
                    isSecureEnclave: s.isSecureEnclave
                )
            case .mosh(let s):
                bridge = fileBridges.bridge(
                    for: s.host,
                    requireBiometric: s.requireBiometric,
                    isSecureEnclave: s.isSecureEnclave
                )
            }
        } else {
            guard let persistedHost = fetchHost(candidate.id) else { return }
            let storedKey = configuredStoredKey(for: persistedHost)
            bridge = fileBridges.bridge(
                for: Host(from: persistedHost),
                requireBiometric: requiresBiometricForKeyUse(
                    on: persistedHost, storedKey: storedKey),
                isSecureEnclave: storedKey?.isSecureEnclave ?? false
            )
        }
        let queue = fileBridges.transferQueue(for: bridge)
        let item: TransferItem
        switch destination {
        case .sessionCwd(let directory):
            item = queue.enqueueUpload(localURL: request.stagedURL, toDirectory: directory)
        case .temp:
            item = queue.enqueuePasteUpload(localURL: request.stagedURL)
        }
        // The sheet is gone by the time the transfer resolves and there
        // may be no open panel (no transfer strip) for this host — a
        // failure MUST surface here or it's silent.
        let displayName = request.displayName
        let hostID = candidate.id
        Task {
            await item.awaitFinished()
            switch item.phase {
            case .failed(let message):
                uploadFailureMessage = "\(displayName): \(message)"
            case .completed:
                // Paste path: hand the resolved path to the host's live
                // session; the session view types it (quoted, no Enter).
                // Target resolved NOW, not at submit — a session that
                // was still auto-reconnecting when the user tapped
                // Upload is usually connected by the time the transfer
                // lands.
                if pastePath, let path = item.resolvedRemotePath {
                    uploadTargetSession(for: hostID)?.pendingPathInjection = path
                }
            default:
                break
            }
        }
    }

    /// The session whose terminal receives a paste-path injection: the
    /// selected one when it belongs to this host, else the newest —
    /// CONNECTED sessions only (failed/connecting ones linger in
    /// activeSessions and would swallow the path).
    private func uploadTargetSession(for hostID: UUID) -> (any TerminalSession)? {
        let sessions = activeSessions.filter {
            $0.persistedHostID == hostID
                && $0.session.terminalSession.state == .connected
        }
        if case .session(let id) = selectedItem,
           let selected = sessions.first(where: { $0.id == id }) {
            return selected.session.terminalSession
        }
        return sessions.max { $0.createdAt < $1.createdAt }?.session.terminalSession
    }

    private func fetchHosts() -> [PersistedHost] {
        let descriptor = FetchDescriptor<PersistedHost>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func persistDetectedOSHint(_ detected: String, forHostID hostID: UUID) {
        guard !HostOSDetectionState.isManuallySet(hostID: hostID),
              let host = fetchHost(hostID),
              host.osHint != detected
        else { return }
        host.osHint = detected
        try? modelContext.save()
    }

    private func createAndEditNewHost() {
        var descriptor = FetchDescriptor<PersistedHost>(
            sortBy: [SortDescriptor(\.sortOrder, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let maxSortOrder = (try? modelContext.fetch(descriptor))?
            .first?.sortOrder ?? 0

        let newHost = PersistedHost(
            name: "",
            address: "",
            port: 22,
            autoTmux: true,
            sortOrder: maxSortOrder + 1,
            identity: nil
        )
        modelContext.insert(newHost)
        try? modelContext.save()
        selectedItem = .host(newHost.id)
    }

    /// Auto-runs the first-launch walkthrough exactly once. Gated so it never
    /// interrupts a session restore: only fires from a clean landing state
    /// (no active sessions, nothing selected). The controller itself enforces
    /// the `hasSeenWelcome` + zero-hosts conditions, so this is safe to call on
    /// every appearance.
    private func maybeBeginOnboarding() {
        guard activeSessions.isEmpty, selectedItem == nil else { return }
        #if DEBUG
        if let rawStep = ProcessInfo.processInfo.environment["TESSERA_FORCE_TOUR_STEP"],
           let step = Int(rawStep),
           onboarding.steps.indices.contains(step) {
            onboarding.phase = .touring(step)
            return
        }
        #endif
        onboarding.beginIfFirstLaunch(
            hasHosts: !fetchHosts().isEmpty,
            hasSeen: appearance.hasSeenWelcome
        )
    }

    private func attemptStartupRestoreIfReady() {
        logRestoreDiag(
            "startup-restore-check didEvaluate=\(didEvaluateStartupRestore) locked=\(appLockController.isLocked) activeCount=\(activeSessions.count) policy=\(appearance.sessionRestorePolicy.rawValue)"
        )
        guard !didEvaluateStartupRestore else {
            logRestoreDiag("startup-restore-skip reason=already-evaluated")
            return
        }
        guard !appLockController.isLocked else {
            logRestoreDiag("startup-restore-skip reason=locked")
            return
        }
        didEvaluateStartupRestore = true

        // If this process survived and still has sessions, this is an
        // ordinary foreground transition, not a fresh launch restore.
        guard activeSessions.isEmpty else {
            logRestoreDiag(
                "startup-restore-skip reason=active-sessions-present count=\(activeSessions.count) sessions=\(activeSessionSummary())"
            )
            return
        }

        guard appearance.sessionRestorePolicy != .never else {
            logRestoreDiag("startup-restore-clear reason=policy-never")
            sessionRestoreStore.clear()
            return
        }

        guard let document = sessionRestoreStore.load() else {
            logRestoreDiag("startup-restore-skip reason=no-document")
            return
        }
        logRestoreDiag(
            "startup-restore-loaded savedAt=\(document.savedAt.timeIntervalSince1970) sessions=\(document.sessions.count) selected=\(shortID(document.selectedSessionID))"
        )
        let plan = restorePlan(for: document)
        logRestoreDiag(
            "startup-restore-plan restorable=\(plan.sessions.count) skipped=\(plan.skippedCount) selected=\(shortID(plan.selectedSnapshotID))"
        )
        guard plan.hasRestorableSessions else {
            logRestoreDiag("startup-restore-clear reason=no-restorable-sessions")
            sessionRestoreStore.clear()
            return
        }

        switch appearance.sessionRestorePolicy {
        case .always:
            logRestoreDiag("startup-restore-action restore-immediately")
            restorePreviousConnections(from: document)
        case .ask:
            logRestoreDiag(
                "startup-restore-action prompt restorable=\(plan.sessions.count) skipped=\(plan.skippedCount)"
            )
            restoreAlwaysReopen = false
            restorePrompt = SessionRestorePrompt(
                document: document,
                hostNames: plan.sessions.map(\.displayName),
                skippedCount: plan.skippedCount,
                preserveSnapshotLiveIDs: true
            )
        case .never:
            logRestoreDiag("startup-restore-clear reason=policy-never-switch")
            sessionRestoreStore.clear()
        }
    }

    private func restorePlan(for document: SessionRestoreDocument) -> SessionRestorePlan {
        SessionRestoreResolver.resolve(
            document,
            hosts: fetchHosts(),
            isCredentialRestorable: isHostCredentialRestorable
        )
    }

    private func reopenPreviousConnections(_ prompt: SessionRestorePrompt) {
        logRestoreDiag(
            "restore-prompt-reopen alwaysReopen=\(restoreAlwaysReopen) storedSessions=\(prompt.document.sessions.count)"
        )
        if restoreAlwaysReopen {
            appearance.sessionRestorePolicy = .always
        }
        restorePrompt = nil
        restorePreviousConnections(
            from: prompt.document,
            preserveSnapshotLiveIDs: prompt.preserveSnapshotLiveIDs
        )
    }

    private func skipPreviousConnections() {
        logRestoreDiag("restore-prompt-not-now clear-store")
        restorePrompt = nil
        restoreAlwaysReopen = false
        cancelForegroundRestoreGrace(reason: "skip-restore")
        hasInactivePreservedRestoreSnapshots = false
        sessionRestoreStore.clear()
    }

    private func restorePreviousConnections(
        from document: SessionRestoreDocument,
        preserveSnapshotLiveIDs: Bool = true,
        selectFallback: Bool = true
    ) {
        cancelForegroundRestoreGrace(reason: "restore-begin")
        hasInactivePreservedRestoreSnapshots = false
        let plan = restorePlan(for: document)
        logRestoreDiag(
            "restore-begin stored=\(document.sessions.count) restorable=\(plan.sessions.count) skipped=\(plan.skippedCount) selected=\(shortID(plan.selectedSnapshotID)) preserveIDs=\(preserveSnapshotLiveIDs) selectFallback=\(selectFallback)"
        )
        guard plan.hasRestorableSessions else {
            logRestoreDiag("restore-clear reason=no-restorable-at-restore-time")
            sessionRestoreStore.clear()
            return
        }

        var restoredIDsBySnapshotID: [UUID: UUID] = [:]
        var firstRestoredID: UUID?

        for resolved in plan.sessions {
            let snapshotIDs = Set(resolved.sourceSnapshotIDs)
            let counterparts = activeSessions.filter { snapshotIDs.contains($0.id) }
            let corpses = counterparts.filter { !isReusableLiveSession($0) }

            // A foreground "missing" snapshot can still have its DEAD
            // live session on screen (.failed/.disconnected is what
            // made it missing). This restore is that session's
            // replacement, so drop the corpse first — appending
            // alongside it stacks a duplicate per foreground wake,
            // and the persisted document snowballs them (one mosh
            // host reached 4 copies, all bootstrapping at once).
            // Mirrors the failed-overlay retry gesture.
            let selectionWasCorpse = corpses.contains { selectedItem == .session($0.id) }
            if !corpses.isEmpty {
                let corpseIDs = Set(corpses.map(\.id))
                activeSessions.removeAll { corpseIDs.contains($0.id) }
                corpses.forEach { $0.session.terminalSession.disconnect() }
                logRestoreDiag(
                    "restore-replace corpses=\(corpses.map { shortID($0.id) }.joined(separator: ",")) snapshot=\(shortID(resolved.snapshot.liveSessionID))"
                )
            }

            // Idempotency: a still-viable live counterpart means there
            // is nothing left to restore for this snapshot. Re-entrant
            // foreground triggers (grace, persist, repeated scene-phase
            // flips) land here instead of stacking another duplicate.
            if let alive = counterparts.first(where: { isReusableLiveSession($0) }) {
                logRestoreDiag(
                    "restore-session-reuse live=\(shortID(alive.id)) snapshot=\(shortID(resolved.snapshot.liveSessionID))"
                )
                if selectionWasCorpse {
                    selectSession(alive.id)
                }
                if firstRestoredID == nil {
                    firstRestoredID = alive.id
                }
                for sourceID in resolved.sourceSnapshotIDs {
                    restoredIDsBySnapshotID[sourceID] = alive.id
                }
                continue
            }

            let liveSessionID = preserveSnapshotLiveIDs
                ? resolved.snapshot.liveSessionID
                : UUID()
            guard let host = fetchHost(resolved.host.id),
                  isHostCredentialRestorable(host),
                  let live = connectSavedHost(
                    host,
                    liveSessionID: liveSessionID,
                    createdAt: resolved.snapshot.createdAt,
                    select: false
                  )
            else {
                logRestoreDiag(
                    "restore-session-skip snapshot=\(shortID(resolved.snapshot.liveSessionID)) host=\(shortID(resolved.snapshot.persistedHostID)) reason=host-missing-or-ineligible-or-connect-failed"
                )
                if selectionWasCorpse {
                    selectedItem = nil
                    columnVisibility = .automatic
                }
                continue
            }

            let sourceIDs = resolved.sourceSnapshotIDs.map(shortID).joined(separator: ",")
            logRestoreDiag(
                "restore-session-opened live=\(shortID(live.id)) snapshot=\(shortID(resolved.snapshot.liveSessionID)) host=\(shortID(live.persistedHostID)) sources=\(sourceIDs) preserveIDs=\(preserveSnapshotLiveIDs)"
            )
            if selectionWasCorpse {
                selectSession(live.id)
            }
            if firstRestoredID == nil {
                firstRestoredID = live.id
            }
            for sourceID in resolved.sourceSnapshotIDs {
                restoredIDsBySnapshotID[sourceID] = live.id
            }
        }

        if let selectedSnapshotID = plan.selectedSnapshotID,
           let selectedLiveID = restoredIDsBySnapshotID[selectedSnapshotID] {
            logRestoreDiag(
                "restore-select selectedSnapshot=\(shortID(selectedSnapshotID)) live=\(shortID(selectedLiveID))"
            )
            selectSession(selectedLiveID)
        } else if let firstRestoredID {
            if selectFallback {
                logRestoreDiag("restore-select fallbackFirst live=\(shortID(firstRestoredID))")
                selectSession(firstRestoredID)
            } else {
                logRestoreDiag("restore-select preserve-current firstRestored=\(shortID(firstRestoredID))")
            }
        } else {
            logRestoreDiag("restore-clear reason=no-opened-sessions")
            sessionRestoreStore.clear()
        }

        persistRestoreSnapshots()
    }

    @discardableResult
    private func attemptForegroundRestoreIfNeeded(reason: String) -> Bool {
        guard appPhase.isActive,
              didEvaluateStartupRestore,
              hasInactivePreservedRestoreSnapshots
        else { return false }

        guard appearance.sessionRestorePolicy != .never else {
            logRestoreDiag("foreground-restore-clear reason=policy-never trigger=\(reason)")
            cancelForegroundRestoreGrace(reason: "policy-never")
            hasInactivePreservedRestoreSnapshots = false
            sessionRestoreStore.clear()
            return true
        }

        guard let document = sessionRestoreStore.load() else {
            logRestoreDiag("foreground-restore-skip reason=no-document trigger=\(reason)")
            cancelForegroundRestoreGrace(reason: "no-document")
            hasInactivePreservedRestoreSnapshots = false
            return false
        }

        if !activeSessions.isEmpty {
            let missingDocument = foregroundMissingRestoreDocument(from: document)
            guard let missingDocument else {
                logRestoreDiag(
                    "foreground-restore-preserve reason=active-sessions-present trigger=\(reason) count=\(activeSessions.count) sessions=\(activeSessionSummary())"
                )
                scheduleForegroundRestoreGrace(reason: reason)
                return true
            }

            guard !appLockController.isLocked else {
                logRestoreDiag(
                    "foreground-restore-preserve reason=locked-with-missing trigger=\(reason) missing=\(missingDocument.sessions.count) activeCount=\(activeSessions.count)"
                )
                scheduleForegroundRestoreGrace(reason: reason)
                return true
            }

            logRestoreDiag(
                "foreground-restore-partial trigger=\(reason) stored=\(document.sessions.count) missing=\(missingDocument.sessions.count) activeCount=\(activeSessions.count)"
            )
            return restoreForegroundDocument(
                missingDocument,
                reason: "\(reason)-partial",
                selectFallback: document.selectedSessionID.flatMap { selected in
                    missingDocument.sessions.contains { $0.liveSessionID == selected }
                } ?? false
            )
        }

        let plan = restorePlan(for: document)
        logRestoreDiag(
            "foreground-restore-plan trigger=\(reason) stored=\(document.sessions.count) restorable=\(plan.sessions.count) skipped=\(plan.skippedCount) selected=\(shortID(plan.selectedSnapshotID)) locked=\(appLockController.isLocked) policy=\(appearance.sessionRestorePolicy.rawValue)"
        )

        guard plan.hasRestorableSessions else {
            logRestoreDiag("foreground-restore-clear reason=no-restorable-sessions trigger=\(reason)")
            cancelForegroundRestoreGrace(reason: "no-restorable")
            hasInactivePreservedRestoreSnapshots = false
            sessionRestoreStore.clear()
            return true
        }

        guard !appLockController.isLocked else {
            logRestoreDiag("foreground-restore-preserve reason=locked trigger=\(reason)")
            return true
        }

        guard restorePrompt == nil else {
            logRestoreDiag("foreground-restore-preserve reason=prompt-present trigger=\(reason)")
            return true
        }

        switch appearance.sessionRestorePolicy {
        case .always:
            logRestoreDiag("foreground-restore-action restore-immediately trigger=\(reason)")
            restoreForegroundDocument(document, reason: reason)
        case .ask:
            logRestoreDiag(
                "foreground-restore-action prompt trigger=\(reason) restorable=\(plan.sessions.count) skipped=\(plan.skippedCount)"
            )
            restoreAlwaysReopen = false
            restorePrompt = SessionRestorePrompt(
                document: document,
                hostNames: plan.sessions.map(\.displayName),
                skippedCount: plan.skippedCount,
                preserveSnapshotLiveIDs: false
            )
        case .never:
            logRestoreDiag("foreground-restore-clear reason=policy-never-switch trigger=\(reason)")
            cancelForegroundRestoreGrace(reason: "policy-never-switch")
            hasInactivePreservedRestoreSnapshots = false
            sessionRestoreStore.clear()
        }

        return true
    }

    @discardableResult
    private func restoreForegroundDocument(
        _ document: SessionRestoreDocument,
        reason: String,
        selectFallback: Bool = true
    ) -> Bool {
        let plan = restorePlan(for: document)
        guard plan.hasRestorableSessions else {
            logRestoreDiag(
                "foreground-restore-clear reason=no-restorable-in-document trigger=\(reason) sessions=\(document.sessions.count)"
            )
            cancelForegroundRestoreGrace(reason: "no-restorable-in-document")
            hasInactivePreservedRestoreSnapshots = false
            sessionRestoreStore.clear()
            return true
        }

        switch appearance.sessionRestorePolicy {
        case .always:
            logRestoreDiag(
                "foreground-restore-action restore-immediately trigger=\(reason) sessions=\(document.sessions.count)"
            )
            restorePreviousConnections(
                from: document,
                preserveSnapshotLiveIDs: false,
                selectFallback: selectFallback
            )
        case .ask:
            logRestoreDiag(
                "foreground-restore-action prompt trigger=\(reason) restorable=\(plan.sessions.count) skipped=\(plan.skippedCount)"
            )
            restoreAlwaysReopen = false
            restorePrompt = SessionRestorePrompt(
                document: document,
                hostNames: plan.sessions.map(\.displayName),
                skippedCount: plan.skippedCount,
                preserveSnapshotLiveIDs: false
            )
        case .never:
            logRestoreDiag("foreground-restore-clear reason=policy-never-action trigger=\(reason)")
            cancelForegroundRestoreGrace(reason: "policy-never-action")
            hasInactivePreservedRestoreSnapshots = false
            sessionRestoreStore.clear()
        }

        return true
    }

    private func foregroundMissingRestoreDocument(
        from document: SessionRestoreDocument
    ) -> SessionRestoreDocument? {
        let activeByID = Dictionary(
            uniqueKeysWithValues: activeSessions.map { ($0.id, $0) }
        )
        let missing = document.sessions.filter { snapshot in
            guard let live = activeByID[snapshot.liveSessionID],
                  live.persistedHostID == snapshot.persistedHostID
            else {
                return true
            }

            switch live.session.terminalSession.state {
            case .idle, .connecting, .connected:
                return false
            case .disconnected, .failed:
                return true
            }
        }

        guard !missing.isEmpty else { return nil }

        let selected = document.selectedSessionID.flatMap { selected in
            missing.contains { $0.liveSessionID == selected } ? selected : nil
        }
        return SessionRestoreDocument(
            savedAt: document.savedAt,
            sessions: missing,
            selectedSessionID: selected
        )
    }

    private func scheduleForegroundRestoreGrace(reason: String) {
        guard foregroundRestoreGraceTask == nil else { return }

        logRestoreDiag(
            "foreground-restore-grace-start reason=\(reason) activeCount=\(activeSessions.count)"
        )
        foregroundRestoreGraceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            foregroundRestoreGraceTask = nil
            finishForegroundRestoreGrace(reason: reason)
        }
    }

    private func cancelForegroundRestoreGrace(reason: String) {
        guard let task = foregroundRestoreGraceTask else { return }

        task.cancel()
        foregroundRestoreGraceTask = nil
        logRestoreDiag("foreground-restore-grace-cancel reason=\(reason)")
    }

    private func finishForegroundRestoreGrace(reason: String) {
        guard appPhase.isActive,
              hasInactivePreservedRestoreSnapshots
        else { return }

        guard let document = sessionRestoreStore.load() else {
            logRestoreDiag("foreground-restore-grace-clear reason=no-document trigger=\(reason)")
            hasInactivePreservedRestoreSnapshots = false
            return
        }

        if let missingDocument = foregroundMissingRestoreDocument(from: document) {
            guard !appLockController.isLocked else {
                logRestoreDiag(
                    "foreground-restore-grace-preserve reason=locked trigger=\(reason) missing=\(missingDocument.sessions.count)"
                )
                scheduleForegroundRestoreGrace(reason: "\(reason)-locked")
                return
            }

            logRestoreDiag(
                "foreground-restore-grace-restore trigger=\(reason) missing=\(missingDocument.sessions.count)"
            )
            restoreForegroundDocument(
                missingDocument,
                reason: "\(reason)-grace",
                selectFallback: document.selectedSessionID.flatMap { selected in
                    missingDocument.sessions.contains { $0.liveSessionID == selected }
                } ?? false
            )
            return
        }

        logRestoreDiag(
            "foreground-restore-grace-finished reason=\(reason) activeCount=\(activeSessions.count) sessions=\(activeSessionSummary())"
        )
        hasInactivePreservedRestoreSnapshots = false
        persistRestoreSnapshots()
    }

    private func persistRestoreSnapshots() {
        guard appearance.sessionRestorePolicy != .never else {
            logRestoreDiag("persist-clear reason=policy-never")
            hasInactivePreservedRestoreSnapshots = false
            sessionRestoreStore.clear()
            return
        }

        let isActive = appPhase.isActive
        if isActive,
           hasInactivePreservedRestoreSnapshots,
           attemptForegroundRestoreIfNeeded(reason: "persist") {
            return
        }

        let previousDocument = isActive ? nil : sessionRestoreStore.load()
        var skippedNoHostMarker = 0
        var skippedMissingHost = 0
        var skippedCredential = 0
        var skippedState = 0
        var preservedInactiveFailure = 0
        let hostsByID = Dictionary(
            uniqueKeysWithValues: fetchHosts().map { ($0.id, $0) }
        )

        let currentSnapshots = activeSessions.compactMap { live -> SessionRestoreSnapshot? in
            guard let hostID = live.persistedHostID else {
                skippedNoHostMarker += 1
                logRestoreDiag(
                    "persist-skip live=\(shortID(live.id)) reason=no-persisted-host-marker state=\(stateDescription(live.session.terminalSession.state))"
                )
                return nil
            }
            guard let host = hostsByID[hostID] else {
                skippedMissingHost += 1
                logRestoreDiag(
                    "persist-skip live=\(shortID(live.id)) host=\(shortID(hostID)) reason=missing-host"
                )
                return nil
            }
            guard isHostCredentialRestorable(host) else {
                skippedCredential += 1
                logRestoreDiag(
                    "persist-skip live=\(shortID(live.id)) host=\(shortID(hostID)) reason=credential-ineligible mode=\(credentialModeDescription(host))"
                )
                return nil
            }

            switch live.session.terminalSession.state {
            case .idle, .connecting, .connected:
                break
            case .disconnected, .failed:
                guard !isActive else {
                    skippedState += 1
                    logRestoreDiag(
                        "persist-skip live=\(shortID(live.id)) host=\(shortID(hostID)) reason=foreground-terminal-state state=\(stateDescription(live.session.terminalSession.state))"
                    )
                    return nil
                }
                preservedInactiveFailure += 1
            }

            logRestoreDiag(
                "persist-include live=\(shortID(live.id)) host=\(shortID(hostID)) state=\(stateDescription(live.session.terminalSession.state)) active=\(isActive)"
            )
            return SessionRestoreSnapshot(
                liveSessionID: live.id,
                persistedHostID: hostID,
                displayName: live.hostName,
                createdAt: live.createdAt
            )
        }

        let snapshots: [SessionRestoreSnapshot]
        if isActive {
            snapshots = currentSnapshots
        } else {
            var snapshotsByID: [UUID: SessionRestoreSnapshot] = [:]
            var orderedIDs: [UUID] = []

            for snapshot in previousDocument?.sessions ?? [] {
                snapshotsByID[snapshot.liveSessionID] = snapshot
                orderedIDs.append(snapshot.liveSessionID)
            }

            for snapshot in currentSnapshots {
                if snapshotsByID[snapshot.liveSessionID] == nil {
                    orderedIDs.append(snapshot.liveSessionID)
                }
                snapshotsByID[snapshot.liveSessionID] = snapshot
            }

            snapshots = orderedIDs.compactMap { snapshotsByID[$0] }
        }

        let selectedSessionID: UUID?
        if case .session(let id) = selectedItem,
           snapshots.contains(where: { $0.liveSessionID == id }) {
            selectedSessionID = id
        } else if !isActive {
            selectedSessionID = previousDocument?.selectedSessionID
        } else {
            selectedSessionID = nil
        }

        sessionRestoreStore.save(
            sessions: snapshots,
            selectedSessionID: selectedSessionID
        )
        hasInactivePreservedRestoreSnapshots = !isActive && !snapshots.isEmpty
        logRestoreDiag(
            "persist-finished active=\(isActive) activeCount=\(activeSessions.count) previous=\(previousDocument?.sessions.count ?? 0) current=\(currentSnapshots.count) final=\(snapshots.count) selected=\(shortID(selectedSessionID)) savedAction=\(snapshots.isEmpty ? "clear-empty" : "save") skippedNoMarker=\(skippedNoHostMarker) skippedMissingHost=\(skippedMissingHost) skippedCredential=\(skippedCredential) skippedState=\(skippedState) preservedInactiveFailure=\(preservedInactiveFailure) inactivePreserved=\(hasInactivePreservedRestoreSnapshots)"
        )
    }

    private func isHostCredentialRestorable(_ host: PersistedHost) -> Bool {
        SessionRestoreEligibility.isRestorable(
            host: host,
            storedKey: { fetchStoredKey($0) }
        )
    }

    private func handleQuickConnect(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let userAndHost = trimmed.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard userAndHost.count == 2 else { return }

        let user = String(userAndHost[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hostAndPort = userAndHost[1].split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !user.isEmpty, !hostAndPort.isEmpty else { return }

        let address = String(hostAndPort[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }

        let port: Int
        if hostAndPort.count == 2 {
            let portString = String(hostAndPort[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedPort = Int(portString),
                  (1...65535).contains(parsedPort) else { return }
            port = parsedPort
        } else {
            port = 22
        }

        let hostDTO = Host(
            name: address,
            address: address,
            port: port,
            user: user
        )
        let session: Session
        let requireBiometric = appearance.requireBiometricForKeyUse
        switch hostDTO.transport {
        case .ssh:
            session = .ssh(SSHSession(
                host: hostDTO,
                requireBiometric: requireBiometric
            ))
        case .mosh:
            session = .mosh(MoshSession(
                host: hostDTO,
                requireBiometric: requireBiometric
            ))
        }
        let live = LiveSession(
            session: session,
            hostName: hostDTO.name.isEmpty ? hostDTO.address : hostDTO.name,
            hostKey: "\(hostDTO.transport.rawValue):\(hostDTO.user)@\(hostDTO.address):\(hostDTO.port)",
            launchMode: hostDTO.launchMode,
            pinnedSessionName: hostDTO.tmuxSessionName?
                .trimmingCharacters(in: .whitespaces)
        )
        activeSessions.append(live)
        selectedItem = .session(live.id)
        columnVisibility = .detailOnly
    }

    private func connect(
        to persistedHost: PersistedHost,
        password: String = "",
        jumpPasswords: [UUID: String] = [:]
    ) {
        _ = connectSavedHost(
            persistedHost,
            password: password,
            jumpPasswords: jumpPasswords,
            select: true
        )
    }

    /// Rebuild a mosh session as plain SSH after its driver never made UDP
    /// contact through a jump chain (the bastioned-topology common case —
    /// `MoshSession.recommendsSSHFallback`). Same launch mode and host
    /// snapshot, fresh LiveSession id so SessionView restarts its connect
    /// task; selection follows.
    private func attemptMoshJumpFallback(liveSessionID: UUID) {
        guard let index = activeSessions.firstIndex(where: { $0.id == liveSessionID }),
              case .mosh(let moshSession) = activeSessions[index].session,
              moshSession.recommendsSSHFallback else { return }

        let old = activeSessions[index]
        var fallbackHost = moshSession.host
        fallbackHost.transport = .ssh
        let sshSession = SSHSession(
            host: fallbackHost,
            requireBiometric: moshSession.requireBiometric,
            isSecureEnclave: moshSession.isSecureEnclave
        )
        // hostKey is deliberately kept: it is the logical endpoint identity
        // used for singleton-tmux reuse and the landing tile's active badge,
        // both of which compare against the persisted host's (still mosh)
        // connectionKey. Only the running transport changed.
        let replacement = LiveSession(
            session: .ssh(sshSession),
            hostName: old.hostName,
            persistedHostID: old.persistedHostID,
            hostKey: old.hostKey,
            launchMode: old.launchMode,
            pinnedSessionName: old.pinnedSessionName,
            createdAt: old.createdAt
        )
        activeSessions[index] = replacement
        if selectedItem == .session(old.id) {
            selectedItem = .session(replacement.id)
        }
        logRestoreDiag(
            "mosh-jump-fallback live=\(shortID(old.id)) replacement=\(shortID(replacement.id)) host=\(shortID(old.persistedHostID))"
        )
    }

    @discardableResult
    private func connectSavedHost(
        _ persistedHost: PersistedHost,
        password: String = "",
        jumpPasswords: [UUID: String] = [:],
        liveSessionID: UUID = UUID(),
        createdAt: Date = Date(),
        select: Bool
    ) -> LiveSession? {
        SSHAuthenticationPolicyStore.shared.registerPersistedHost(persistedHost.id)
        let hostKey = persistedHost.connectionKey
        let mode = persistedHost.launchMode

        // Singleton tmux: if an auto-tmux session (default OR pinned-
        // with-the-same-name) to this host is already active, just
        // switch to it instead of connecting again. A different pinned
        // name or a custom command always spawns a fresh session.
        if mode == .autoTmux,
           let existing = activeSessions.first(where: {
               $0.hostKey == hostKey && $0.launchMode == .autoTmux
               && isReusableLiveSession($0)
           }) {
            if select {
                selectedItem = .session(existing.id)
                columnVisibility = .detailOnly
            }
            return existing
        }
        if mode == .pinnedTmux {
            let pinned = persistedHost.tmuxSessionName?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !pinned.isEmpty,
               let existing = activeSessions.first(where: {
                   $0.hostKey == hostKey
                   && $0.launchMode == .pinnedTmux
                   && $0.pinnedSessionName == pinned
                   && isReusableLiveSession($0)
               }) {
                if select {
                    selectedItem = .session(existing.id)
                    columnVisibility = .detailOnly
                }
                return existing
            }
        }

        let transientJumpPasswords = jumpPasswords.mapValues {
            HostTransientPasswordCredential(password: $0, revision: nil)
        }
        let hostDTO = Host(
            from: persistedHost,
            transientPassword: password,
            transientJumpPasswords: transientJumpPasswords
        )
        let session: Session
        let storedKey = configuredStoredKey(for: persistedHost)
        let requireBiometric = requiresBiometricForKeyUse(
            on: persistedHost,
            storedKey: storedKey
        )
        let isSecureEnclave = storedKey?.isSecureEnclave ?? false
        switch hostDTO.transport {
        case .ssh:
            session = .ssh(SSHSession(
                host: hostDTO,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave
            ))
        case .mosh:
            session = .mosh(MoshSession(
                host: hostDTO,
                requireBiometric: requireBiometric,
                isSecureEnclave: isSecureEnclave
            ))
        }
        let live = LiveSession(
            id: liveSessionID,
            session: session,
            hostName: persistedHost.name.isEmpty
                ? persistedHost.address
                : persistedHost.name,
            persistedHostID: persistedHost.id,
            hostKey: hostKey,
            launchMode: mode,
            pinnedSessionName: persistedHost.tmuxSessionName?
                .trimmingCharacters(in: .whitespaces),
            createdAt: createdAt
        )
        activeSessions.append(live)
        if select {
            selectedItem = .session(live.id)
            columnVisibility = .detailOnly
        }
        persistRestoreSnapshots()
        return live
    }

    private func isReusableLiveSession(_ live: LiveSession) -> Bool {
        switch live.session.terminalSession.state {
        case .idle, .connecting, .connected:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    private func requiresBiometricForKeyUse(
        on host: PersistedHost,
        storedKey: StoredKey? = nil
    ) -> Bool {
        guard case .key(let keyID) = host.identity?.credentialMode else {
            return false
        }
        let key = storedKey ?? fetchStoredKey(keyID)
        return requiresOwnerPresenceForKeyUse(
            key: key,
            globalPreference: appearance.requireBiometricForKeyUse
        )
    }

    private func configuredStoredKey(for host: PersistedHost) -> StoredKey? {
        guard case .key(let keyID) = host.identity?.credentialMode else {
            return nil
        }
        return fetchStoredKey(keyID)
    }

    private func fetchStoredKey(_ id: UUID) -> StoredKey? {
        let descriptor = FetchDescriptor<StoredKey>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func dismiss(_ live: LiveSession) {
        let wasSelected = selectedItem == .session(live.id)
        activeSessions.removeAll { $0.id == live.id }
        if wasSelected {
            selectedItem = nil
            columnVisibility = .automatic
        }
        live.session.terminalSession.disconnect()
    }

    /// Single switch-to-session entry point shared by the sidebar tap,
    /// the command palette commit, and the MRU cycle commit. Guards
    /// against ids that have since disconnected so an in-flight chord
    /// can't strand the user on the landing page.
    private func selectSession(_ id: UUID) {
        guard activeSessions.contains(where: { $0.id == id }) else { return }
        selectedItem = .session(id)
        columnVisibility = .detailOnly
        sessionRegistry.markTouched(id)
    }

    /// Opens the ⌘K quick-switch palette with a fresh snapshot of the
    /// active session set + last-touched timestamps. Gated by the app
    /// lock so the chord is a no-op while the lock overlay is up.
    private func openPalette() {
        commandPalette.open(
            sessions: activeSessions,
            agents: appearance.agentCenterEnabled ? agentCenter.sortedAgents : [],
            lastTouched: sessionRegistry.lastTouched
        )
    }

    private func refreshCommandPaletteSnapshot() {
        commandPalette.refreshSnapshot(
            sessions: activeSessions,
            agents: appearance.agentCenterEnabled ? agentCenter.sortedAgents : [],
            paneTitles: [:],
            lastTouched: sessionRegistry.lastTouched
        )
    }

    private func handleCommandPaletteCommit(_ result: CommandPaletteCommit) {
        switch result {
        case .agent(let id):
            guard appearance.agentCenterEnabled else { return }
            agentCenter.jump(agentID: id)
        case .session(let id): selectSession(id)
        }
    }

    private func handlePendingAgentNotification() {
        guard appearance.agentCenterEnabled else {
            _ = AgentNotificationRouter.shared.consume()
            return
        }
        guard let route = AgentNotificationRouter.shared.consume() else { return }
        agentCenter.jump(agentID: route)
    }

    private func toggleAgentCenter() {
        guard appearance.agentCenterEnabled || selectedItem == .agents else { return }
        if selectedItem == .agents {
            if case .session(let id) = agentCenterReturnItem,
               !activeSessions.contains(where: { $0.id == id }) {
                selectedItem = nil
                columnVisibility = .automatic
            } else {
                let target = agentCenterReturnItem
                selectedItem = target
                if case .some(.session) = target {
                    columnVisibility = .detailOnly
                } else {
                    columnVisibility = .automatic
                }
            }
        } else {
            agentCenterReturnItem = selectedItem
            selectedItem = .agents
            columnVisibility = .automatic
        }
    }

    private func updateAgentSurfaceDemand() {
        agentCenter.setSurfaceDemand(
            appearance.agentCenterEnabled
                && (selectedItem == .agents || commandPalette.isOpen)
        )
    }

    private func updateAgentAttentionBackgroundKeepAlive(reason: String) {
        AgentAttentionBackgroundKeepAlive.shared.update(
            enabled: appearance.agentCenterEnabled
                && appearance.agentCenterNotificationsEnabled,
            workingCount: agentCenter.workingCount,
            appPhase: appPhase,
            reason: reason
        )
    }

    /// Opens the Settings page from the ⌘, chord (global button when no
    /// session holds first responder; `TesseraTerminalContainer`'s
    /// UIKeyCommand when one does). Leaves any live session alive in the
    /// background — Settings is a browse page, so reveal the sidebar
    /// layout the same way a sidebar tap on Settings would.
    private func openSettings() {
        selectedItem = .settings
        columnVisibility = .automatic
    }

    private func logRestoreDiag(_ message: String) {
        DiagnosticLogStore.appendRestore(message)
    }

    private func activeSessionSummary(limit: Int = 8) -> String {
        guard !activeSessions.isEmpty else { return "[]" }

        let parts = activeSessions.prefix(limit).map { live in
            "live=\(shortID(live.id)),host=\(shortID(live.persistedHostID)),transport=\(transportDescription(live)),state=\(stateDescription(live.session.terminalSession.state)),mode=\(live.launchMode.rawValue)"
        }
        let suffix = activeSessions.count > limit ? ",..." : ""
        return "[" + parts.joined(separator: ";") + suffix + "]"
    }

    private func transportDescription(_ live: LiveSession) -> String {
        switch live.session {
        case .ssh:
            return "ssh"
        case .mosh:
            return "mosh"
        }
    }

    private func stateDescription(_ state: SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .failed:
            return "failed"
        }
    }

    private func sidebarItemDescription(_ item: SidebarItem?) -> String {
        guard let item else { return "nil" }

        switch item {
        case .session(let id):
            return "session:\(shortID(id))"
        case .host(let id):
            return "host:\(shortID(id))"
        case .keys:
            return "keys"
        case .agents:
            return "agents"
        case .knownHosts:
            return "knownHosts"
        case .tunnels:
            return "tunnels"
        case .settings:
            return "settings"
        }
    }

    private func credentialModeDescription(_ host: PersistedHost) -> String {
        guard let identity = host.identity else { return "nil" }

        switch identity.credentialMode {
        case .none:
            return "none"
        case .password:
            return "password"
        case .key:
            return "key"
        case .legacyDevKey:
            return "legacyDevKey"
        }
    }

    private func shortID(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return shortID(id)
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}

private func requiresOwnerPresenceForKeyUse(
    key: StoredKey?,
    globalPreference: Bool,
    metadata: KeySecurityMetadataStore = KeySecurityMetadataStore()
) -> Bool {
    KeyOwnerPresencePolicy.isRequired(
        globalPreference: globalPreference,
        key: key,
        metadata: metadata
    )
}

#Preview {
    ContentView()
        // Build through the shared factory so even the preview container goes
        // through the migration plan — every container in the repo now has a
        // single source of truth for schema + plan.
        .modelContainer(try! TesseraModelContainer.make(inMemory: true))
}
