import SwiftUI
import SwiftData
import Combine
import UIKit
#if DEBUG
import CoreFoundation
#endif

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

private struct ContinuationDraft {
    let descriptor: SessionActivityDescriptor
    let rootHostID: UUID
    let insertedHostIDs: Set<UUID>
}

private struct ContinuityFailureBanner: Identifiable, Equatable {
    enum Source {
        case incoming
        case outgoing
    }

    let id = UUID()
    let source: Source
    let message: String

    var title: String {
        switch source {
        case .incoming:
            String(
                localized: "Couldn't continue session",
                comment: "Alert title when taking over a session from another device fails"
            )
        case .outgoing:
            String(
                localized: "Couldn't make session available",
                comment: "Alert title when offering a session to another device fails"
            )
        }
    }
}

/// One saved-host admission prompt: the first over-limit attempt shows the
/// full explainer, later attempts only the compact limit notice (the store's
/// `hasSeenUnlimitedHostsOffer` presentation flag picks the variant).
private struct UnlimitedHostsPromptItem: Identifiable {
    let id = UUID()
    enum Kind { case explainer, limitNotice }
    var kind: Kind
}

/// A nearby-import quota decision awaiting the user's pick. `respond` is the
/// run-once bridge back into the bootstrap admission continuation.
private struct BootstrapQuotaDecisionItem: Identifiable {
    let id = UUID()
    let plan: BootstrapImportPlan
    let remainingFreeSlots: Int
    let respond: (BootstrapAdmissionResponse) -> Void
}

/// Sheet dismissal can race the user's pick (swipe-away vs. an explicit
/// decision); the checked continuation behind a quota decision must resume
/// exactly once.
private final class BootstrapQuotaResponder {
    private var continuation: CheckedContinuation<BootstrapAdmissionResponse, Never>?

    init(_ continuation: CheckedContinuation<BootstrapAdmissionResponse, Never>) {
        self.continuation = continuation
    }

    func respond(_ response: BootstrapAdmissionResponse) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: response)
    }
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.designTokens) private var T
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(HostTerminalBackgroundStore.self) private var hostBackgrounds
    @Environment(ConnectionActivityStore.self) private var connectionActivity
    @Environment(AppLockController.self) private var appLockController
    @Environment(OnboardingController.self) private var onboarding
    @Environment(AppPhase.self) private var appPhase
    @Environment(SwipePadProfileStore.self) private var swipePadStore
    @Environment(BellController.self) private var bellController
    @Environment(ActivityBroadcaster.self) private var activityBroadcaster
    @Environment(ContinuationCoordinator.self) private var continuationCoordinator
    @Environment(BootstrapCoordinator.self) private var bootstrapCoordinator
    @Environment(EnrollmentCoordinator.self) private var enrollmentCoordinator
    @Environment(HostAccessStore.self) private var hostAccessStore
    /// Optional so a view mounted outside `RootView` (previews, harnesses) falls
    /// back to the shipped chords instead of trapping on a missing store.
    @Environment(ShortcutStore.self) private var shortcutStore: ShortcutStore?

    @State private var activeSessions: [LiveSession] = []
    @State private var selectedItem: SidebarItem?
    /// Whether the session/host sidebar is expanded. Stored as a plain Bool:
    /// the shell is a custom ZStack, not a NavigationSplitView, and comparing
    /// `NavigationSplitViewVisibility.automatic` against `.detailOnly` is
    /// orientation-dependent on iPadOS 26 (equal in portrait, distinct in
    /// landscape), which made the portrait reveal button a no-op.
    @State private var sidebarVisible = true
    @State private var restorePrompt: SessionRestorePrompt?
    @State private var restoreAlwaysReopen = false
    @State private var didEvaluateStartupRestore = false
    #if DEBUG
    @State private var onboardingMatrixTask: Task<Void, Never>?
    #endif
    @State private var hasInactivePreservedRestoreSnapshots = false
    @State private var foregroundRestoreTickTask: Task<Void, Never>?
    /// Sessions believed alive when the app last went inactive, each awaiting a
    /// verdict at the next foreground. Entries only ever leave — restored,
    /// confirmed alive, or claimed by the user. Nothing is added while the
    /// window is open, so a replacement that fails cannot re-enter as a fresh
    /// candidate and loop.
    @State private var foregroundRestoreCohort: [SessionRestoreSnapshot] = []
    @State private var foregroundRestoreWindowOpenedAt: Date?
    /// The window's own clock, charged the way the SSH handshake budget is —
    /// in clamped steps, and only while no handshake prompt is up. Kept apart
    /// from `foregroundRestoreWindowOpenedAt`, which stays wall time and is
    /// only asked whether a window exists.
    @State private var foregroundRestoreChargedSeconds: TimeInterval = 0
    @State private var foregroundRestoreLastChargeAt: Date?
    /// Restoring writes snapshots, and writing re-evaluates. Without this the
    /// two would recurse through each other once per cohort entry.
    @State private var foregroundRestoreEvaluating = false

    /// Host key verification request from any connecting session.
    @State private var hostKeyRequest: HostKeyVerificationRequest?

    /// Share-in ("Copy to Tessera"): staged incoming file driving the
    /// Upload sheet. Requests always park first and present only when
    /// no sibling sheet (host-key prompt, restore prompt) is up and the
    /// app is unlocked — two sheets set in one transaction means one
    /// silently never presents.
    @State private var uploadRequest: UploadRequest?
    @State private var pendingUploadRequests: [UploadRequest] = []
    /// Share-in transfers can fail with no panel/strip on screen (the
    /// sheet is long dismissed) — this alert is their only surface.
    @State private var uploadFailureMessage: String?
    @State private var uploadCompletionMessage: String?
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

    /// Unlimited Hosts purchase prompt (explainer / compact notice) and the
    /// nearby-import quota decision. Both follow the upload sheet's parking
    /// discipline: park while any sibling sheet (host-key, restore, upload,
    /// each other) or the app lock is up, then re-present from the same
    /// onChange chains.
    @State private var unlimitedHostsPrompt: UnlimitedHostsPromptItem?
    @State private var pendingUnlimitedHostsPrompt: UnlimitedHostsPromptItem?
    @State private var bootstrapQuotaDecision: BootstrapQuotaDecisionItem?
    @State private var pendingBootstrapQuotaDecision: BootstrapQuotaDecisionItem?
    /// The single in-flight entitlement wait behind a manual add. Later taps
    /// coalesce onto it instead of spawning parallel retry chains.
    @State private var admissionWaitTask: Task<Void, Never>?
    /// Content-specific cancellation paired with the store's run-once resume
    /// token. Handoff uses this to release ContinuationCoordinator.active when
    /// an offer is declined; manual New Host has no cancellation work.
    @State private var pendingAdmissionCancellation: (() -> Void)?
    @State private var pendingApprovalWasDismissed = false
    @State private var hostAdmissionFailureMessage: String?

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
    @State private var compactPresentation = CompactNavigationPresentation()
    @State private var continuationOverlay: ContinuationOverlayPresentation?
    @State private var continuationLiveSessionID: UUID?
    @State private var continuationCompletionTask: Task<Void, Never>?
    @State private var continuityBroadcastTask: Task<Void, Never>?
    @State private var continuationDraft: ContinuationDraft?
    @State private var continuityFailureBanner: ContinuityFailureBanner?
    @State private var continuityFailureDismissTask: Task<Void, Never>?
    @State private var keysPagePresentation = KeysPagePresentationState()

    private let sessionRestoreStore = SessionRestoreStore()
    private let shareInboxAppGroupID = "group.com.bambouville.TesseraApp"
    private let shareInboxFolderName = "ShareInbox"
    private let shareInboxTargetsFileName = "upload-targets.json"
    private let shareInboxMetadataFileName = "metadata.json"
    private let shareInboxConsumedDefaultsKey = "ShareInbox.ConsumedIDs"
    private let shareInboxConsumedLimit = 200

    #if DEBUG
    /// Test-only fixture seam for production-shell transition coverage. The
    /// companion harness intercepts socket startup so supplied sessions remain
    /// inert while the real ContentView changes shells.
    init(
        debugInitialSessions: [LiveSession] = [],
        debugInitialSelectedItem: SidebarItem? = nil
    ) {
        _activeSessions = State(initialValue: debugInitialSessions)
        _selectedItem = State(initialValue: debugInitialSelectedItem)
    }
    #endif

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }
    /// Compact has no multi-session restore chooser. A legacy/default `.ask`
    /// preference therefore means reopen on phone until the user explicitly
    /// chooses the phone's restore-on-launch toggle; the stored preference is
    /// left untouched so opening the same app on iPad still honors "ask".
    private var effectiveSessionRestorePolicy: SessionRestorePolicy {
        SessionRestorePresentationPolicy.effective(
            stored: appearance.sessionRestorePolicy,
            usesCompactShell: isPhone
        )
    }

    private var contentShell: some View {
        ZStack(alignment: .leading) {
            // One detail tree survives the regular/compact shell boundary.
            // SessionView and MoshSessionView own live terminal/tmux state and
            // output-consumer tasks; remounting them on a width change can reset
            // that state or reconnect a failed/disconnected transport. Keep it
            // first: inserting the compact root ahead of this subtree changes
            // its variadic child identity even though detailContent itself is
            // unconditional.
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isPhone {
                        T.presentationBg.ignoresSafeArea()
                    }
                }
                .opacity(!isPhone || isCompactOverlaySelected ? 1 : 0)
                .allowsHitTesting(!isPhone || isCompactOverlaySelected)
                .accessibilityHidden(isPhone && !isCompactOverlaySelected)
                .zIndex(isPhone ? 10 : 0)

            if isPhone {
                compactNavigationShell
            }

            if !isPhone && sidebarVisible && isSessionSelected {
                // The regular terminal remains full-width beneath the floating
                // sidebar. This scrim prevents input from reaching it while the
                // sidebar is open and collapses navigation when tapped.
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapseSidebar() }
                    .transition(.opacity)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("hide sidebar")
                    .zIndex(1)
            }

            if !isPhone && sidebarVisible {
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
        // Reveal affordance for regular browse pages when the sidebar is hidden.
        .overlay(alignment: .topLeading) {
            if !isPhone && !sidebarVisible && !isSessionSelected {
                sidebarRevealButton
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(.container, edges: isPhone ? [] : .horizontal)
        .background(T.bg)
        .animation(.easeInOut(duration: 0.18), value: isCompactOverlaySelected)
        .animation(.easeInOut(duration: 0.24), value: sidebarVisible)
        // The four chords below come from the user's keymap, not from literals:
        // these hidden buttons are the *only* registration for ⌘N (the terminal
        // container has no selector for it), so a literal here means the editor
        // records a rebind that never takes effect and an unbind that releases
        // nothing. See `storedKeyboardShortcut(_:in:)`.
        .background(
            Button("New Host", action: createAndEditNewHost)
                .storedKeyboardShortcut(.newHost, in: shortcutStore)
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
                .storedKeyboardShortcut(.quickSwitchPalette, in: shortcutStore)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .background {
            if appearance.agentCenterEnabled {
                Button("Toggle Agent Center", action: toggleAgentCenter)
                    .storedKeyboardShortcut(.toggleAgentCenter, in: shortcutStore)
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
                .storedKeyboardShortcut(.openSettings, in: shortcutStore)
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
                    onTmuxClose: sessionRegistry.requestTmuxClose,
                    onTmuxMutation: sessionRegistry.requestTmuxMutation,
                    onCommit: handleCommandPaletteCommit
                )
                .transition(.opacity)
                .zIndex(50)
            }
        }
    }

    private var compactNavigationShell: some View {
        TabView(selection: $compactPresentation.tab) {
            landing
                .tag(CompactRootTab.hosts)
                .tabItem {
                    Label("hosts", systemImage: "server.rack")
                }

            CompactSessionsPage(
                activeSessions: activeSessions,
                selectedView: $compactPresentation.sessionsView,
                agentCenter: agentCenter,
                agentCenterEnabled: appearance.agentCenterEnabled,
                onSelectSession: selectSession,
                onDisconnectSession: dismiss
            )
            .tag(CompactRootTab.sessions)
            .tabItem {
                Label("sessions", systemImage: "rectangle.stack.fill")
            }
            .badge(compactSessionBadge)

            VStack(spacing: 0) {
                CompactViewSelector(
                    leadingTitle: "keys",
                    trailingTitle: "known hosts",
                    selection: Binding(
                        get: { compactPresentation.keysView == .keys },
                        set: {
                            compactPresentation.keysView = $0 ? .keys : .knownHosts
                        }
                    )
                )

                switch compactPresentation.keysView {
                case .keys:
                    KeysPageView(presentation: keysPagePresentation)
                case .knownHosts:
                    KnownHostsPageView()
                }
            }
            .tag(CompactRootTab.keys)
            .tabItem {
                Label("keys", systemImage: "key.fill")
            }

            SettingsPageView(
                onUploadDiagnosticLog: uploadDiagnosticLog
            )
            .tag(CompactRootTab.settings)
            .tabItem {
                Label("settings", systemImage: "gearshape.fill")
            }
        }
        .tint(T.accent)
        .background(T.bg)
        .onChange(of: compactPresentation.tab) { _, tab in
            guard !isCompactOverlaySelected else { return }
            switch tab {
            case .hosts:
                selectedItem = nil
            case .sessions:
                if compactPresentation.sessionsView == .agents {
                    selectedItem = .agents
                } else if selectedItem != .agents {
                    selectedItem = nil
                }
            case .keys:
                selectedItem = compactPresentation.keysView == .keys ? .keys : .knownHosts
            case .settings:
                selectedItem = .settings
            }
            updateAgentSurfaceDemand()
        }
        .onChange(of: compactPresentation.sessionsView) { _, view in
            switch view {
            case .sessions:
                if selectedItem == .agents {
                    selectedItem = nil
                }
            case .agents:
                selectedItem = .agents
            }
            updateAgentSurfaceDemand()
        }
    }

    private var isCompactOverlaySelected: Bool {
        switch selectedItem {
        case .session, .host:
            return true
        default:
            return false
        }
    }

    private var compactSessionBadge: Int {
        agentCenter.waitingCount + agentCenter.unreadJustFinishedCount
    }

    /// Keep the compact shell ready for the authoritative regular route before
    /// it is mounted, then run the same reconciliation again at the actual
    /// width boundary as a safety net for restore/lifecycle updates.
    private func reconcileCompactPresentation(with selection: SidebarItem?) {
        compactPresentation.reconcile(with: selection)
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
                    geometry: proxy,
                    compact: isPhone
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
            // A nil selection means the regular Hosts destination, but in the
            // compact shell it also represents the Sessions root. Preserve a
            // compact tab the user just chose; regular navigation and the
            // actual regular -> compact boundary remain authoritative.
            if !isPhone || newValue != nil {
                reconcileCompactPresentation(with: newValue)
            }
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
        .onChange(of: isPhone, initial: true) { _, usesCompactShell in
            guard usesCompactShell else { return }
            reconcileCompactPresentation(with: selectedItem)
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
        .onChange(of: appearance.agentScrollLockClaudeCodeEnabled) { _, _ in
            syncAgentScrollLock()
        }
        .onChange(of: appearance.agentScrollLockCodexEnabled) { _, _ in
            syncAgentScrollLock()
        }
        .onChange(of: swipePadStore.profiles) { _, profiles in
            agentCenter.syncProfiles(profiles)
            agentCenter.refreshAll()
        }
    }

    private var presentedContent: some View {
        agentAwareContent
        .background {
            continuationLifecycleObserver
            hostAccessAdmissionPresenter
            hostAdmissionFailurePresenter
        }
        .overlay {
            if let continuationOverlay {
                ContinuationOverlayView(
                    presentation: continuationOverlay,
                    onDismiss: {
                        continuationCompletionTask?.cancel()
                        continuationCompletionTask = nil
                        self.continuationOverlay = nil
                        continuationLiveSessionID = nil
                        continuationCoordinator.finishActive()
                    }
                )
                .zIndex(100)
            }
        }
        .overlay {
            bootstrapFlowOverlay
        }
        .overlay {
            if enrollmentCoordinator.phase.isPresented {
                EnrollmentApprovalView(coordinator: enrollmentCoordinator)
                    .zIndex(120)
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = continuityFailureBanner {
                Button {
                    continuityFailureDismissTask?.cancel()
                    continuityFailureBanner = nil
                } label: {
                    // Styled like the app's other transient banners
                    // (PaneCommandToast, sync-offline capsule): mono type on
                    // DesignTokens surfaces, amber accent for the failure.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title)
                            .font(Typography.tesseraMono(size: 13, weight: .medium))
                            .foregroundStyle(T.fg)
                        Text(banner.message)
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgMuted)
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(T.panelBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(T.amber.opacity(0.55), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(140)
            }
        }
    }

    /// Keep continuation observation out of `body`'s already-large generic
    /// modifier expression. This zero-sized view is mounted with the content
    /// and owns only the two observable inputs that advance the continuation
    /// state machine.
    private var continuationLifecycleObserver: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: continuationCoordinator.ready) { _, pending in
                guard let pending else { return }
                handleIncomingContinuation(pending)
            }
            .onChange(of: sessionRegistry.renderReadyIDs) { oldReadyIDs, readyIDs in
                for hostID in ConnectionActivityAttribution.newlyReadyHostIDs(
                    oldReadyIDs: oldReadyIDs,
                    newReadyIDs: readyIDs,
                    connectedSessionIDs: Set(activeSessions.compactMap { session in
                        session.session.terminalSession.state == .connected ? session.id : nil
                    }),
                    sessions: activeSessions
                ) where fetchHost(hostID) != nil {
                    connectionActivity.recordHostConnection(hostID)
                }
                guard let continuationLiveSessionID,
                      readyIDs.contains(continuationLiveSessionID)
                else { return }
                finishContinuationAfterRenderReady()
            }
    }

    /// The unlimited-hosts purchase prompt, nearby-import quota decision, and
    /// their observation chains live outside `body`'s already-large generic
    /// modifier expression (same discipline as `continuationLifecycleObserver`)
    /// — mounted as a zero-sized background presenter on `presentedContent`.
    private var hostAccessAdmissionPresenter: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .sheet(item: $unlimitedHostsPrompt, onDismiss: {
                // A notice → explainer swap replaces the item without a real
                // dismissal; only a genuine dismiss (item now nil) records the
                // presentation flag and drops the deferred add. After a
                // completed purchase the store's run-once token owns the resume,
                // so it must survive.
                guard unlimitedHostsPrompt == nil else { return }
                if hostAccessStore.accessState == .free {
                    hostAccessStore.hasSeenUnlimitedHostsOffer = true
                }
                if case .unlimited = hostAccessStore.accessState {
                    finishPendingAdmissionBookkeeping()
                    return
                }
                if hostAccessStore.purchasePending {
                    // Ask to Buy may be approved after the sheet closes. Keep
                    // the exact user action until approval or a completed
                    // foreground rescan proves the request is no longer pending.
                    pendingApprovalWasDismissed = true
                    return
                }
                cancelPendingAdmission()
            }) { item in
                switch item.kind {
                case .explainer:
                    UnlimitedHostsSheet()
                case .limitNotice:
                    HostLimitNoticeSheet(
                        onViewOffer: {
                            unlimitedHostsPrompt = UnlimitedHostsPromptItem(kind: .explainer)
                        },
                        onCancel: {
                            unlimitedHostsPrompt = nil
                        }
                    )
                }
            }
            .sheet(item: $bootstrapQuotaDecision) { item in
                BootstrapQuotaDecisionSheet(
                    plan: item.plan,
                    remainingFreeSlots: item.remainingFreeSlots,
                    showsOfferInitially: !hostAccessStore.hasSeenUnlimitedHostsOffer,
                    onDecision: { decision in
                        bootstrapQuotaDecision = nil
                        item.respond(decision)
                    }
                )
                .onDisappear {
                    // Swipe-away (or any dismissal without a pick) cancels the
                    // import; the responder is run-once, so an explicit decision
                    // above always wins.
                    item.respond(.cancel)
                }
            }
            .onChange(of: uploadRequest == nil) { _, _ in
                presentParkedUnlimitedHostsPromptIfClear()
                presentParkedBootstrapQuotaDecisionIfClear()
            }
            .onChange(of: appLockController.isLocked) { _, _ in
                presentParkedUnlimitedHostsPromptIfClear()
                presentParkedBootstrapQuotaDecisionIfClear()
            }
            // The two admission sheets also park behind EACH OTHER, so each
            // one's dismissal is itself a re-presentation trigger. Without
            // these two observers a dismissed explainer strands a parked
            // quota decision — and its nearby-transfer continuation, plus
            // the origin waiting on the acceptance frame — forever.
            .onChange(of: unlimitedHostsPrompt == nil) { _, _ in
                presentParkedBootstrapQuotaDecisionIfClear()
            }
            .onChange(of: bootstrapQuotaDecision == nil) { _, _ in
                presentParkedUnlimitedHostsPromptIfClear()
            }
            .onChange(of: hostAccessStore.accessState) { _, newState in
                // A purchase/restore completing dismisses the add-triggered
                // prompt; the store's deferred token then resumes the original
                // add exactly once. No success banner or toast.
                guard case .unlimited = newState else { return }
                pendingUnlimitedHostsPrompt = nil
                unlimitedHostsPrompt = nil
                finishPendingAdmissionBookkeeping()
                // A parked quota decision must not present just to
                // auto-resolve: a PRESENTED quota sheet answers .proceedFull
                // from its own accessState observer, so resolve the parked
                // one the same way, in place.
                if let parked = pendingBootstrapQuotaDecision {
                    pendingBootstrapQuotaDecision = nil
                    parked.respond(.proceedFull)
                }
            }
            .onChange(of: hostAccessStore.purchasePending) { wasPending, isPending in
                guard wasPending,
                      !isPending,
                      pendingApprovalWasDismissed,
                      hostAccessStore.accessState != .unlimited(.purchasedIAP),
                      hostAccessStore.accessState != .unlimited(.legacyPaid)
                else { return }
                cancelPendingAdmission()
            }
            .onChange(of: bootstrapCoordinator.isPresented) { _, isPresented in
                // The nearby flow can be cancelled (e.g. app lock) with a quota
                // decision still open or parked; answer `cancel` so the import
                // continuation never outlives its flow.
                guard !isPresented else { return }
                if let item = bootstrapQuotaDecision {
                    bootstrapQuotaDecision = nil
                    item.respond(.cancel)
                }
                if let parked = pendingBootstrapQuotaDecision {
                    pendingBootstrapQuotaDecision = nil
                    parked.respond(.cancel)
                }
            }
    }

    /// Keep persistence-error presentation out of `body`'s already-large
    /// generic modifier expression.
    private var hostAdmissionFailurePresenter: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .alert(
                "couldn't save host",
                isPresented: Binding(
                    get: { hostAdmissionFailureMessage != nil },
                    set: { if !$0 { hostAdmissionFailureMessage = nil } }
                )
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(hostAdmissionFailureMessage ?? "")
            }
    }

    var body: some View {
        presentedContent
        .onAppear {
            recoverAbandonedContinuationDraftIfNeeded()
            #if DEBUG
            prepareContinuityHarnessSavedHostIfNeeded()
            prepareContinuityLiveHarnessSavedHostIfNeeded()
            presentContinuityHostKeyHarnessIfNeeded()
            #endif
            prepareBootstrapFlow()
        }
        .onChange(of: selectedItem) { _, selection in
            abandonContinuationDraftIfNeeded(afterSelecting: selection)
            refreshContinuityBroadcast(reason: "selection")
        }
        .onChange(of: appearance.handoffSessionsEnabled) { _, _ in
            refreshContinuityBroadcast(reason: "preference")
        }
        .onChange(of: continuationCoordinator.lastFailure, initial: true) { _, failure in
            guard let failure else { return }
            continuationCoordinator.clearLastFailure()
            presentContinuityFailure(failure, source: .incoming)
        }
        .onChange(of: activityBroadcaster.lastFailure, initial: true) { _, failure in
            guard let failure else { return }
            activityBroadcaster.clearLastFailure()
            presentContinuityFailure(failure, source: .outgoing)
        }
        .onChange(of: bootstrapCoordinator.isPresented) { wasPresented, isPresented in
            if isPresented {
                onboarding.phase = .inactive
            }
            if wasPresented && !isPresented {
                // Nearby setup is the first-open choice. Keep the legacy tour
                // replayable from Settings without stacking a second welcome.
                appearance.hasSeenWelcome = true
            }
        }
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
            } else {
                continuityBroadcastTask?.cancel()
            }
            refreshContinuityBroadcast(reason: isLocked ? "lock" : "unlock")
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
            sidebarVisible = true
            if isPhone {
                compactPresentation.tab = .hosts
            }
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
            if !isActive {
                // The window belongs to one wake. Carrying it across the
                // background edge would leave the next foreground reusing a
                // stale cohort against an `openedAt` from the previous visit —
                // so the alive floor reads as long spent, entries retire on the
                // first pass, and wake 2 gets no detection window at all. The
                // background-edge persist re-arms the latch; the next
                // foreground seeds a fresh window from the document it wrote.
                cancelForegroundRestoreTick(reason: "background")
                foregroundRestoreCohort = []
                foregroundRestoreWindowOpenedAt = nil
                foregroundRestoreChargedSeconds = 0
                foregroundRestoreLastChargeAt = nil
            }
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
            refreshContinuityBroadcast(reason: isActive ? "foreground" : "background")
            persistRestoreSnapshots()
        }
        .onChange(of: appPhase.state) { _, state in
            updateAgentAttentionBackgroundKeepAlive(
                reason: "app-phase-\(state.rawValue)"
            )
        }
        .onAppear {
            if isPhone,
               UserDefaults.standard.object(
                   forKey: "tessera.pref.swipePadEnabled"
               ) == nil {
                // The puck is core phone input, but remains opt-in on iPad.
                // Persist the device-local default once so Settings reflects
                // the actual session UI and an explicit later "off" sticks.
                appearance.swipePadEnabled = true
            }
            configureCurrentSSHAuthenticationPolicy()
            logRestoreDiag(
                "content-appear locked=\(appLockController.isLocked) active=\(appPhase.isActive) activeCount=\(activeSessions.count) didEvaluateStartupRestore=\(didEvaluateStartupRestore)"
            )
            sessionRegistry.syncActiveSessions(activeSessions)
            agentCenter.setEnabled(appearance.agentCenterEnabled)
            syncAgentScrollLock()
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
            if !bootstrapCoordinator.isPresented {
                maybeBeginOnboarding()
            }
            refreshContinuityBroadcast(reason: "appear")
        }
        .statusBarHidden(isPhone ? isSessionSelected : true)
        .persistentSystemOverlays(isPhone ? .automatic : .hidden)
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
            .interactiveDismissDisabled()
        }
        .sheet(item: $uploadRequest) { request in
            uploadSheetContent(request)
        }
        .onOpenURL { url in
            handleIncomingOpenURL(url)
        }
        .onChange(of: restorePrompt == nil) { _, _ in
            presentParkedUploadIfClear()
            presentParkedUnlimitedHostsPromptIfClear()
            presentParkedBootstrapQuotaDecisionIfClear()
            presentQueuedShareForSelectedHostIfClear(reason: "restore-cleared")
        }
        .onChange(of: hostKeyRequest == nil) { _, _ in
            presentParkedUploadIfClear()
            presentParkedUnlimitedHostsPromptIfClear()
            presentParkedBootstrapQuotaDecisionIfClear()
            presentQueuedShareForSelectedHostIfClear(reason: "hostkey-cleared")
        }
        .alert(
            uploadCompletionMessage == nil
                ? String(localized: "upload failed")
                : String(localized: "upload complete"),
            isPresented: Binding(
                get: { uploadFailureMessage != nil || uploadCompletionMessage != nil },
                set: {
                    if !$0 {
                        uploadFailureMessage = nil
                        uploadCompletionMessage = nil
                    }
                }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(uploadCompletionMessage ?? uploadFailureMessage ?? "")
        }
        .onReceive(hostKeyVerificationPublisher) { request in
            guard let request else {
                // A session rejects its request before publishing nil. Clear
                // only that resolved global presentation; initial nil values
                // from unrelated sessions must not dismiss a live prompt.
                if hostKeyRequest?.isResolved == true {
                    hostKeyRequest = nil
                }
                return
            }
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
            updateContinuationOverlay(for: event)
            if case .session(event.liveSessionID) = selectedItem {
                refreshContinuityBroadcast(reason: "session-state")
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

    private func uploadSheetContent(_ request: UploadRequest) -> some View {
        UploadSheetView(
            request: request,
            model: uploadSheetModel,
            onUpload: { candidate, destination, pastePath in
                startUpload(
                    request: request,
                    candidate: candidate,
                    destination: destination,
                    pastePath: pastePath
                )
            },
            onContinueInBackground: continueUploadInBackground,
            onCancel: { cancelUploadSheet(request) },
            onResolveCwd: { candidate in
                resolveSessionCwdIfNeeded(for: candidate.id)
            }
        )
    }

    private func continueUploadInBackground(_ execution: UploadExecution) -> Bool {
        let copyPath: Bool
        if case .foreground(let pastePath) = execution.delivery {
            copyPath = pastePath
        } else {
            copyPath = false
        }
        guard BackgroundUploadCoordinator.shared.continueUpload(execution) else {
            return false
        }
        execution.delivery = .background(copyPath: copyPath)
        execution.queue.markContinuedInBackground(execution.item)

        let queuedUpload = activeShareQueueUpload
        uploadRequest = nil
        scheduleParkedUploadAfterDismissal()
        if let queuedUpload {
            finishQueuedShareUpload(queuedUpload, reason: "backgrounded")
        }
        return true
    }

    private func cancelUploadSheet(_ request: UploadRequest) {
        let queuedUpload = activeShareQueueUpload
        discardStagedUpload(request)
        uploadRequest = nil
        scheduleParkedUploadAfterDismissal()
        if let queuedUpload {
            finishQueuedShareUpload(queuedUpload, reason: "cancelled")
        }
    }

    private func presentContinuityFailure(
        _ message: String,
        source: ContinuityFailureBanner.Source
    ) {
        continuityFailureDismissTask?.cancel()
        let banner = ContinuityFailureBanner(source: source, message: message)
        withAnimation(.easeOut(duration: 0.2)) {
            continuityFailureBanner = banner
        }
        continuityFailureDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, continuityFailureBanner?.id == banner.id else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                continuityFailureBanner = nil
            }
        }
    }

    @ViewBuilder
    private var bootstrapFlowOverlay: some View {
        if bootstrapCoordinator.isPresented {
            BootstrapFlowView(
                coordinator: bootstrapCoordinator,
                onConfigureHost: configureBootstrapHost
            )
            .zIndex(110)
        }
    }

    private func prepareBootstrapFlow() {
        bootstrapCoordinator.configure(
            modelContext: modelContext,
            appearance: appearance,
            admissionHandler: { plan in
                await admitBootstrapImport(plan)
            },
            finalAdmissionValidator: { newRowCount in
                guard let existingHostCount = savedHostCountForAdmission() else {
                    return false
                }
                return SavedHostAdmissionPolicy.decision(
                    existingHostCount: existingHostCount,
                    newRowCount: newRowCount,
                    access: hostAccessStore.accessState
                ) == .allow
            }
        )
        #if DEBUG
        // The visual regression harness intentionally asks for one exact
        // legacy-tour state at a time. First-open Nearby Setup normally owns
        // this presentation boundary, but letting it cover the forced state
        // makes every capture after step one identical and leaves the tour
        // untestable. This hook is DEBUG-only and does not change production
        // first-open ordering.
        if ProcessInfo.processInfo.environment["TESSERA_ONBOARDING_MATRIX_AUTOPLAY"] == "1"
            || ProcessInfo.processInfo.environment["TESSERA_FORCE_TOUR_STEP"] != nil
            || ProcessInfo.processInfo.environment["TESSERA_FORCE_TOUR_WELCOME"] == "1" {
            return
        }
        #endif
        let descriptor = FetchDescriptor<PersistedHost>()
        let hasHosts = ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
        bootstrapCoordinator.beginIfFirstOpen(hasHosts: hasHosts)
    }

    /// Nearby setup persists real saved-host rows, so the accepted batch
    /// preflights through the same admission policy as a manual add before
    /// any mutation. The coordinator may invoke the handler off-main; the
    /// store, the model context, and the quota sheet are all MainActor.
    ///
    /// The quota sheet suspends user-paced while a concurrent Handoff prefill
    /// can still insert rows, so the decision re-validates against the live
    /// host count after every resume — admission-time math alone could
    /// over-persist beyond the free limit.
    @MainActor
    private func admitBootstrapImport(
        _ plan: BootstrapImportPlan
    ) async -> BootstrapAdmissionResponse {
        var response: BootstrapAdmissionResponse = .proceedFull
        while true {
            // Do not make a new-device customer tap Restore before importing
            // multiple hosts. This fresh, silent StoreKit entitlement scan is
            // performed at the exact persistence gate and reconstructs a prior
            // non-consumable purchase even if the app-start scan is still late.
            let access = await hostAccessStore.accessStateForPersistenceAdmission()
            let newRowCount: Int
            switch response {
            case .proceedFull: newRowCount = plan.newHostIDs.count
            case .restrictTo(let ids): newRowCount = ids.count
            case .cancel: return .cancel
            }
            guard let existingHostCount = savedHostCountForAdmission() else {
                return .cancel
            }
            switch SavedHostAdmissionPolicy.decision(
                existingHostCount: existingHostCount,
                newRowCount: newRowCount,
                access: access
            ) {
            case .allow:
                return response
            case .checkingEntitlement:
                // The fresh automatic scan could not establish ownership.
                // Rows must never persist while entitlement truth is unknown;
                // the importer maps .cancel to a CancellationError that
                // unwinds both peers cleanly without offering a duplicate buy.
                return .cancel
            case .requiresPurchase:
                response = await withCheckedContinuation { continuation in
                    presentBootstrapQuotaDecision(
                        plan: plan,
                        remainingFreeSlots: max(
                            0,
                            SavedHostAdmissionPolicy.freeHostLimit - existingHostCount
                        ),
                        respond: BootstrapQuotaResponder(continuation).respond
                    )
                }
            }
        }
    }

    private func configureBootstrapHost(_ item: BootstrapCredentialChecklistItem) {
        bootstrapCoordinator.finish()
        compactPresentation.tab = .hosts
        selectedItem = .host(item.id)
    }

    private func continuationEnrollmentAction(
        for host: PersistedHost
    ) -> (() -> Void)? {
        guard let draft = continuationDraft,
              draft.rootHostID == host.id,
              let activity = continuationCoordinator.enrollmentActivity,
              activity.supportsContinuationStreams
        else { return nil }
        return {
            enrollmentCoordinator.onRequesterEnrollmentCompleted = { completedHost in
                guard continuationDraft?.rootHostID == completedHost.id else {
                    return
                }
                // The original Authorize tap is the user action that starts
                // this connection. It is deliberately delayed until the
                // requester has persisted its identity/ledger and the origin
                // has returned the final durable-record acknowledgement.
                continuationDraft = nil
                ContinuationDraftRecoveryStore().clear()
                continuationCoordinator.finishActive()
                enrollmentCoordinator.onRequesterEnrollmentCompleted = nil
                connect(
                    to: completedHost,
                    continuationDescriptor: draft.descriptor
                )
            }
            enrollmentCoordinator.requestAuthorization(
                through: activity,
                for: host,
                authorizationHostID: draft.descriptor.hostID,
                peerDeviceName: String(localized: "your other device"),
                in: modelContext,
                defaultKeyUseOwnerAuthentication: appearance.requireBiometricForKeyUse
            )
        }
    }

    /// Merges `pendingHostKeyVerification` from all active SSH sessions
    /// into a single publisher so the sheet triggers for any session.
    /// Mosh sessions don't expose a host key verification channel
    /// directly over UDP; their SSH bootstrap step feeds the same
    /// request channel.
    private var hostKeyVerificationPublisher: some Publisher<HostKeyVerificationRequest?, Never> {
        Publishers.MergeMany(
            activeSessions.compactMap { live -> AnyPublisher<HostKeyVerificationRequest?, Never>? in
                switch live.session {
                case .ssh(let session):
                    return session.$pendingHostKeyVerification
                        .eraseToAnyPublisher()
                case .mosh(let session):
                    return session.$pendingHostKeyVerification
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
                        reconnectingElsewhere: foregroundRestoreCohort.count(
                            where: { $0.liveSessionID != live.id }
                        ),
                        onUserClosedSession: {
                            retireForegroundRestoreCohortEntry(
                                live.id,
                                reason: "user-closed"
                            )
                        },
                        onToggleSidebar: {
                            withAnimation {
                                sidebarVisible.toggle()
                            }
                        },
                        sidebarVisible: sidebarVisible,
                        onBack: {
                            selectedItem = nil
                            sidebarVisible = true
                        },
                        // Both recovery actions are also reachable from the
                        // stall notice, which fires while the connect is still
                        // running rather than after it failed — so dropping the
                        // tab is not enough. An un-disconnected connect keeps
                        // its own task alive and completes invisibly, holding a
                        // remote shell (and, on the tmux path, a second control
                        // client alongside the retry's replacement). Retire
                        // first, so the state change the disconnect publishes
                        // is not read as a cohort death.
                        onEditHost: {
                            retireForegroundRestoreCohortEntry(live.id, reason: "edit-host")
                            activeSessions.removeAll { $0.id == live.id }
                            sshSession.disconnect()
                            selectedItem = .host(sshSession.host.id)
                            sidebarVisible = true
                        },
                        onRetry: {
                            retireForegroundRestoreCohortEntry(live.id, reason: "retry")
                            let hostID = sshSession.host.id
                            activeSessions.removeAll { $0.id == live.id }
                            sshSession.disconnect()
                            if let persisted = fetchHost(hostID) {
                                connect(to: persisted)
                            }
                        },
                        onSessionEnded: {
                            let wasSelected = selectedItem == .session(live.id)
                            activeSessions.removeAll { $0.id == live.id }
                            if wasSelected {
                                selectedItem = nil
                                sidebarVisible = true
                            }
                        },
                        onSelectSession: { id in
                            selectSession(id)
                        },
                        onOpenSettings: openSettings,
                        onOpenAgentCenter: appearance.agentCenterEnabled
                            ? toggleAgentCenter : nil,
                        onEffectiveLaunchModeChanged: { mode in
                            updateEffectiveLaunchMode(for: live.id, to: mode)
                        }
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .ignoresSafeArea(.container, edges: .bottom)
                case .mosh(let moshSession):
                    MoshSessionView(
                        session: moshSession,
                        liveSessionID: live.id,
                        isActive: isSelected,
                        reconnectingElsewhere: foregroundRestoreCohort.count(
                            where: { $0.liveSessionID != live.id }
                        ),
                        onUserClosedSession: {
                            retireForegroundRestoreCohortEntry(
                                live.id,
                                reason: "user-closed"
                            )
                        },
                        onToggleSidebar: {
                            withAnimation {
                                sidebarVisible.toggle()
                            }
                        },
                        sidebarVisible: sidebarVisible,
                        onBack: {
                            selectedItem = nil
                            sidebarVisible = true
                        },
                        // Same teardown rule as the SSH branch, and the stakes
                        // are higher here: an orphaned bootstrap that completes
                        // has already spawned a `mosh-server` on the host, and
                        // nothing left on screen can reach it.
                        onEditHost: {
                            retireForegroundRestoreCohortEntry(live.id, reason: "edit-host")
                            activeSessions.removeAll { $0.id == live.id }
                            moshSession.disconnect()
                            selectedItem = .host(moshSession.host.id)
                            sidebarVisible = true
                        },
                        onRetry: {
                            retireForegroundRestoreCohortEntry(live.id, reason: "retry")
                            let hostID = moshSession.host.id
                            activeSessions.removeAll { $0.id == live.id }
                            moshSession.disconnect()
                            if let persisted = fetchHost(hostID) {
                                connect(to: persisted)
                            }
                        },
                        onSessionEnded: {
                            let wasSelected = selectedItem == .session(live.id)
                            activeSessions.removeAll { $0.id == live.id }
                            if wasSelected {
                                selectedItem = nil
                                sidebarVisible = true
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
                    .accessibilityHidden(!isSelected)
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }

            // Host editor identity is independent of the responsive shell.
            // Keeping it at one structural position preserves the staged draft,
            // validation, focus, and transient credential boundary while the
            // iPad crosses compact/regular width classes.
            if !isSessionSelected {
                Group {
                    switch selectedItem {
                    case .host(let hostID):
                        if let host = fetchHost(hostID) {
                            hostEditor(host)
                                .id(host.id)
                        } else if isPhone {
                            Color.clear
                        } else {
                            landing
                        }
                    case .keys:
                        if isPhone {
                            Color.clear
                        } else {
                            KeysPageView(presentation: keysPagePresentation)
                        }
                    case .agents:
                        if !isPhone && appearance.agentCenterEnabled {
                            AgentCenterPage(center: agentCenter)
                        } else if isPhone {
                            Color.clear
                        } else {
                            landing
                        }
                    case .knownHosts:
                        if isPhone { Color.clear } else { KnownHostsPageView() }
                    case .tunnels:
                        if isPhone {
                            Color.clear
                        } else {
                            TunnelsPageView { persistedHost in
                                selectedItem = .host(persistedHost.id)
                            }
                        }
                    case .settings:
                        if isPhone {
                            Color.clear
                        } else {
                            SettingsPageView(onUploadDiagnosticLog: uploadDiagnosticLog)
                        }
                    default:
                        if isPhone { Color.clear } else { landing }
                    }
                }
                .padding(.leading, !isPhone && sidebarVisible ? SessionSidebar.width : 0)
                .padding(.top, !isPhone && !sidebarVisible ? 50 : 0)
            }
        }
    }

    private func hostEditor(_ host: PersistedHost) -> some View {
        HostDetailView(
            host: host,
            onConnect: { persistedHost, password, jumpPasswords in
                let continuation = continuationDraft?.rootHostID == persistedHost.id
                    ? continuationDraft?.descriptor : nil
                if continuation != nil {
                    continuationDraft = nil
                    ContinuationDraftRecoveryStore().clear()
                    enrollmentCoordinator.onRequesterEnrollmentCompleted = nil
                    continuationCoordinator.finishActive()
                }
                connect(
                    to: persistedHost,
                    password: password,
                    jumpPasswords: jumpPasswords,
                    continuationDescriptor: continuation
                )
            },
            onCancel: {
                if continuationDraft?.rootHostID == host.id {
                    cancelContinuationDraft()
                } else {
                    dismissEditor(host: host, deleteIfDraft: true)
                }
            },
            onSave: {
                try? modelContext.save()
                if let draft = continuationDraft, draft.rootHostID == host.id {
                    continuationDraft = nil
                    ContinuationDraftRecoveryStore().clear()
                    enrollmentCoordinator.onRequesterEnrollmentCompleted = nil
                    connect(to: host, continuationDescriptor: draft.descriptor)
                    continuationCoordinator.finishActive()
                } else {
                    selectedItem = nil
                }
            },
            onDelete: { dismissEditor(host: host, deleteIfDraft: false, force: true) },
            continuationSourceLabel: continuationDraft?.rootHostID == host.id
                ? String(localized: "your other device") : nil,
            continuationAction: continuationDraft?.rootHostID == host.id
                ? continuationDraft?.descriptor.continuationAction : nil,
            continuationTmuxSessionName: continuationDraft?.rootHostID == host.id
                ? continuationDraft?.descriptor.tmuxSessionName : nil,
            compactPrimaryTitle: continuationDraft?.rootHostID == host.id
                ? "add & connect" : "save",
            onAuthorizeFromPeer: continuationEnrollmentAction(for: host)
        )
    }

    private var isSessionSelected: Bool {
        if case .session = selectedItem { return true }
        return false
    }

    /// Hides the sidebar (backs the in-panel `‹` button).
    private func collapseSidebar() {
        withAnimation(.easeInOut(duration: 0.24)) {
            sidebarVisible = false
        }
    }

    /// Shows the sidebar (backs the browse-page reveal button).
    private func revealSidebar() {
        withAnimation(.easeInOut(duration: 0.24)) {
            sidebarVisible = true
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
            onConnect: { host in
                if hostRouteHasUsableCredentials(host) {
                    connect(to: host)
                } else {
                    selectedItem = .host(host.id)
                    sidebarVisible = false
                }
            },
            onEdit: { host in selectedItem = .host(host.id) },
            onDelete: { host in
                dismissEditor(host: host, deleteIfDraft: false, force: true)
            },
            onNewHost: createAndEditNewHost,
            onQuickConnect: handleQuickConnect,
            onOpenKeys: {
                if isPhone {
                    compactPresentation.tab = .keys
                    compactPresentation.keysView = .keys
                }
                selectedItem = .keys
            },
            activeHostKeys: Set(activeSessions.map { $0.hostKey }),
            activeHostTmuxUsage: HostCardRuntimeBadges.activeTmuxUsage(in: activeSessions)
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
            connectionActivity.removeHost(host.id)
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

            var currentHost = Host(
                    from: persisted,
                    transientPassword: transientPassword,
                    transientPasswordCredentialRevision: transientRevision,
                    transientJumpPasswords: transientJumpPasswords
                )
            // Preserve only the public, per-attempt informed-TOFU context when
            // refreshing the authoritative persisted host. Credentials and
            // endpoints still come exclusively from SwiftData/Keychain.
            currentHost.continuationHostKeyFingerprints =
                fallback.continuationHostKeyFingerprints
            currentHost.continuationPeerLabel = fallback.continuationPeerLabel

            return SSHConnectionPolicyDraft(
                host: currentHost,
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
              pendingUploadRequests.isEmpty,
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
            pendingUploadRequests.append(try makeUploadRequest(
                from: url,
                displayName: displayName,
                sourceHint: sourceHint
            ))
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
        guard let parked = pendingUploadRequests.first,
              uploadRequest == nil,
              restorePrompt == nil,
              hostKeyRequest == nil,
              !appLockController.isLocked else { return }
        pendingUploadRequests.removeFirst()
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
        if live.effectiveLaunchMode != .customCommand {
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
            "upload-cwd resolve mode=\(live.effectiveLaunchMode.rawValue) discovery=\(String(describing: discovery))"
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

    @discardableResult
    private func startUpload(
        request: UploadRequest,
        candidate: UploadHostCandidate,
        destination: UploadDestination,
        pastePath: Bool
    ) -> UploadExecution? {
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
            guard let persistedHost = fetchHost(candidate.id) else {
                uploadFailureMessage = String(localized: "The selected host is no longer available.")
                return nil
            }
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
        let execution = UploadExecution(
            item: item,
            queue: queue,
            hostID: candidate.id,
            displayName: request.displayName,
            stagedURL: request.stagedURL,
            pastePath: pastePath
        )
        let queuedUpload = activeShareQueueUpload
        Task {
            await item.awaitFinished()
            switch item.phase {
            case .failed(let message):
                switch execution.delivery {
                case .foreground:
                    // The sheet stays up and renders the failure beside
                    // the file, with a retry action that reuses the staged
                    // local copy.
                    break
                case .background:
                    discardStagedUpload(request)
                case .none:
                    uploadFailureMessage = "\(request.displayName): \(message)"
                    discardStagedUpload(request)
                    dismissUploadExecution(request: request, queuedUpload: queuedUpload, reason: "cancelled")
                }
            case .completed:
                if let path = item.resolvedRemotePath {
                    let outcome = UploadCompletionDelivery.deliver(
                        path: path,
                        delivery: execution.delivery,
                        injectIntoTerminal: { path in
                            guard let target = uploadTargetSession(for: candidate.id) else {
                                return false
                            }
                            // Do not overwrite a path already waiting for a
                            // connecting terminal. The delivery policy copies
                            // this later completion to the clipboard instead.
                            guard target.pendingPathInjection == nil else {
                                return false
                            }
                            // A connecting session retains this injection until
                            // its connected state arrives.
                            target.pendingPathInjection = path
                            return true
                        },
                        copyToClipboard: { UIPasteboard.general.string = $0 }
                    )
                    if outcome == .clipboardFallback {
                        uploadCompletionMessage = String(localized: "The terminal is no longer available, so the remote path was copied to the clipboard.")
                    }
                }
                discardStagedUpload(request)
                if case .foreground = execution.delivery {
                    dismissUploadExecution(request: request, queuedUpload: queuedUpload, reason: "uploaded")
                }
            case .cancelled:
                discardStagedUpload(request)
                if case .none = execution.delivery {
                    dismissUploadExecution(request: request, queuedUpload: queuedUpload, reason: "cancelled")
                }
            case .queued, .running, .cancelling:
                assertionFailure("awaitFinished returned before the upload reached a terminal phase")
            }
        }
        return execution
    }

    private func dismissUploadExecution(
        request: UploadRequest,
        queuedUpload: ActiveShareQueueUpload?,
        reason: String
    ) {
        if uploadRequest?.id == request.id {
            uploadRequest = nil
            scheduleParkedUploadAfterDismissal()
        }
        if let queuedUpload, activeShareQueueUpload?.itemID == queuedUpload.itemID {
            finishQueuedShareUpload(queuedUpload, reason: reason)
        }
    }

    private func discardStagedUpload(_ request: UploadRequest) {
        do {
            try FileManager.default.removeItem(at: request.stagedURL)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return
        } catch {
            DiagnosticLogStore.appendApp(
                "share upload staging cleanup failed file=\(request.displayName) error=\(error.localizedDescription)"
            )
        }
    }

    /// Direct document-open and extension-queue arrivals share a single
    /// presentation slot. If another document arrived while this sheet was
    /// transferring, wait for UIKit's dismissal transition before promoting
    /// the parked request; setting a replacement item in the same transaction
    /// can leave the second sheet silently unpresented.
    private func scheduleParkedUploadAfterDismissal() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            presentParkedUploadIfClear()
            presentQueuedShareForSelectedHostIfClear(reason: "upload-dismissed")
        }
    }

    /// The session whose terminal receives a paste-path injection: the
    /// selected one when it belongs to this host, else the newest —
    /// Connected or actively connecting sessions. SessionView retains a
    /// pending injection across connecting→connected, so a fast upload cannot
    /// outrun restore and silently swallow the promised path.
    private func uploadTargetSession(for hostID: UUID) -> (any TerminalSession)? {
        let sessions = activeSessions.filter {
            $0.persistedHostID == hostID
                && ($0.session.terminalSession.state == .connected
                    || $0.session.terminalSession.state == .connecting)
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
        requestSavedHostAdmission(newRowCount: 1, resume: insertAndEditNewHost)
    }

    private func insertAndEditNewHost() {
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

    /// Single admission funnel for every saved-host creation path (manual
    /// add, ⌘N, sidebar, Handoff prefill). The policy decides from the live
    /// persisted-host count and the store's access state before any row is
    /// staged or inserted; an entitled or under-limit caller resumes inline,
    /// so those paths stay byte-identical to a direct call. A completed
    /// purchase resumes the original action once via the store's deferred
    /// token — the resumed editor is the only confirmation.
    ///
    /// Coalescing rule: the purchase path admits ONE pending request at a
    /// time. While a prompt is open or parked, a second over-limit request
    /// (⌘N works under a sheet; a concurrent Handoff) must not replace the
    /// deferred token or the presented item — that would silently drop the
    /// first requester. The user resolves the open prompt, then retries the
    /// second action.
    @discardableResult
    private func requestSavedHostAdmission(
        newRowCount: Int,
        resume: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) -> Bool {
        guard let existingHostCount = savedHostCountForAdmission() else {
            return false
        }
        switch SavedHostAdmissionPolicy.decision(
            existingHostCount: existingHostCount,
            newRowCount: newRowCount,
            access: hostAccessStore.accessState
        ) {
        case .allow:
            resume()
            return true
        case .checkingEntitlement, .requiresPurchase:
            // Reconstruct StoreKit ownership at the exact gate before showing
            // purchase UI. This is silent (`Transaction.currentEntitlements`,
            // never AppStore.sync) and covers a prior IAP on a newly installed
            // device even if the app-start scan has not landed yet. Later taps
            // coalesce onto this one admission task.
            guard admissionWaitTask == nil,
                  unlimitedHostsPrompt == nil,
                  pendingUnlimitedHostsPrompt == nil,
                  !pendingApprovalWasDismissed else { return false }
            admissionWaitTask = Task { @MainActor in
                defer { admissionWaitTask = nil }
                let refreshedAccess = await hostAccessStore.accessStateForPersistenceAdmission()
                guard let refreshedHostCount = savedHostCountForAdmission() else {
                    onCancel?()
                    return
                }
                switch SavedHostAdmissionPolicy.decision(
                    existingHostCount: refreshedHostCount,
                    newRowCount: newRowCount,
                    access: refreshedAccess
                ) {
                case .allow:
                    resume()
                case .checkingEntitlement:
                    // Verification is still unavailable. Keep the exact action
                    // behind the neutral explainer, whose error/retry state does
                    // not claim that this customer is free.
                    registerPendingAdmission(resume: resume, onCancel: onCancel)
                    presentUnlimitedHostsPrompt(kind: .explainer)
                case .requiresPurchase:
                    registerPendingAdmission(resume: resume, onCancel: onCancel)
                    presentUnlimitedHostsPrompt(
                        kind: hostAccessStore.hasSeenUnlimitedHostsOffer
                            ? .limitNotice
                            : .explainer
                    )
                }
            }
            return true
        }
    }

    private func registerPendingAdmission(
        resume: @escaping () -> Void,
        onCancel: (() -> Void)?
    ) {
        hostAccessStore.setDeferredPostPurchaseAction(resume)
        pendingAdmissionCancellation = onCancel
        pendingApprovalWasDismissed = false
    }

    private func cancelPendingAdmission() {
        hostAccessStore.clearDeferredPostPurchaseAction()
        let cancellation = pendingAdmissionCancellation
        pendingAdmissionCancellation = nil
        pendingApprovalWasDismissed = false
        cancellation?()
    }

    private func finishPendingAdmissionBookkeeping() {
        pendingAdmissionCancellation = nil
        pendingApprovalWasDismissed = false
    }

    private func savedHostCountForAdmission() -> Int? {
        do {
            return try modelContext.fetchCount(FetchDescriptor<PersistedHost>())
        } catch {
            hostAdmissionFailureMessage = String(
                localized: "tessera could not read saved hosts. nothing was changed; try again.",
                comment: "Saved-host count could not be read, so admission was blocked"
            )
            DiagnosticLogStore.appendApp(
                "host admission result=blocked reason=swiftdata-count error='\(error.localizedDescription)'"
            )
            return nil
        }
    }

    /// Parks the prompt when a sibling sheet or the app lock is up — two
    /// sheets set in one transaction means one silently never presents.
    private func presentUnlimitedHostsPrompt(kind: UnlimitedHostsPromptItem.Kind) {
        let item = UnlimitedHostsPromptItem(kind: kind)
        guard hostKeyRequest == nil,
              restorePrompt == nil,
              uploadRequest == nil,
              bootstrapQuotaDecision == nil,
              !appLockController.isLocked else {
            pendingUnlimitedHostsPrompt = item
            return
        }
        unlimitedHostsPrompt = item
        recordExplainerPresentationIfNeeded(item)
    }

    private func presentParkedUnlimitedHostsPromptIfClear() {
        guard let parked = pendingUnlimitedHostsPrompt,
              unlimitedHostsPrompt == nil,
              hostKeyRequest == nil,
              restorePrompt == nil,
              uploadRequest == nil,
              bootstrapQuotaDecision == nil,
              !appLockController.isLocked else { return }
        pendingUnlimitedHostsPrompt = nil
        unlimitedHostsPrompt = parked
        recordExplainerPresentationIfNeeded(parked)
    }

    /// Records the one auto-explainer at presentation, not just dismissal —
    /// if the app is killed while the first explainer is up, a
    /// dismissal-only write would auto-present it a second time on the next
    /// over-limit attempt. The sheet's onDismiss write stays as backstop.
    private func recordExplainerPresentationIfNeeded(_ item: UnlimitedHostsPromptItem) {
        guard item.kind == .explainer,
              hostAccessStore.accessState == .free else { return }
        hostAccessStore.hasSeenUnlimitedHostsOffer = true
    }

    private func presentBootstrapQuotaDecision(
        plan: BootstrapImportPlan,
        remainingFreeSlots: Int,
        respond: @escaping (BootstrapAdmissionResponse) -> Void
    ) {
        let item = BootstrapQuotaDecisionItem(
            plan: plan,
            remainingFreeSlots: remainingFreeSlots,
            respond: respond
        )
        guard hostKeyRequest == nil,
              restorePrompt == nil,
              uploadRequest == nil,
              unlimitedHostsPrompt == nil,
              !appLockController.isLocked else {
            pendingBootstrapQuotaDecision = item
            return
        }
        bootstrapQuotaDecision = item
    }

    private func presentParkedBootstrapQuotaDecisionIfClear() {
        guard let parked = pendingBootstrapQuotaDecision,
              bootstrapQuotaDecision == nil,
              hostKeyRequest == nil,
              restorePrompt == nil,
              uploadRequest == nil,
              unlimitedHostsPrompt == nil,
              !appLockController.isLocked else { return }
        pendingBootstrapQuotaDecision = nil
        bootstrapQuotaDecision = parked
    }

    /// Auto-runs the first-launch walkthrough exactly once. Gated so it never
    /// interrupts a session restore: only fires from a clean landing state
    /// (no active sessions, nothing selected). The controller itself enforces
    /// the `hasSeenWelcome` + zero-hosts conditions, so this is safe to call on
    /// every appearance.
    private func maybeBeginOnboarding() {
        guard activeSessions.isEmpty, selectedItem == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["TESSERA_ONBOARDING_MATRIX_AUTOPLAY"] == "1" {
            beginOnboardingMatrixSequenceIfNeeded()
            return
        }
        if ProcessInfo.processInfo.environment["TESSERA_FORCE_TOUR_WELCOME"] == "1" {
            onboarding.phase = .welcome
            return
        }
        if let rawStep = ProcessInfo.processInfo.environment["TESSERA_FORCE_TOUR_STEP"],
           let step = Int(rawStep),
           onboarding.steps.indices.contains(step) {
            onboarding.phase = .touring(step)
            return
        }
        #endif
        // `presentedContent` mounts before this outer view's onAppear. Start
        // the authoritative first-open flow here as well so the legacy iPad
        // tour cannot arm underneath it due to SwiftUI modifier ordering.
        prepareBootstrapFlow()
        guard !bootstrapCoordinator.isPresented else {
            onboarding.phase = .inactive
            return
        }
        onboarding.beginIfFirstLaunch(
            hasHosts: !fetchHosts().isEmpty,
            hasSeen: appearance.hasSeenWelcome
        )
    }

    #if DEBUG
    /// Drives stable visual states without relaunching between every screenshot.
    /// The exhaustive matrix runner watches the marker in this disposable app
    /// container, waits for SwiftUI to settle, then captures with simctl.
    private func beginOnboardingMatrixSequenceIfNeeded() {
        guard onboardingMatrixTask == nil else { return }
        let states: [(String, OnboardingPhase)] = [
            ("welcome", .welcome),
            ("step-1", .touring(0)),
            ("step-2", .touring(1)),
            ("step-3", .touring(2)),
            ("step-4", .touring(3)),
            ("step-5", .touring(4)),
            ("step-6", .touring(5)),
            ("step-7", .touring(6)),
            ("step-8", .touring(7)),
            ("step-9", .touring(8)),
        ]
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-onboarding-matrix-state.txt")

        onboardingMatrixTask = Task { @MainActor in
            for (name, phase) in states {
                guard !Task.isCancelled else { return }
                onboarding.phase = phase
                try? name.write(to: markerURL, atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }
    #endif

    private func attemptStartupRestoreIfReady() {
        logRestoreDiag(
            "startup-restore-check didEvaluate=\(didEvaluateStartupRestore) locked=\(appLockController.isLocked) activeCount=\(activeSessions.count) policy=\(effectiveSessionRestorePolicy.rawValue)"
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

        guard effectiveSessionRestorePolicy != .never else {
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

        switch effectiveSessionRestorePolicy {
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
        // The answer IS the verdict for these entries. Leaving them in the
        // cohort would keep them `.dead` forever — the replacement carries a
        // new liveSessionID and can never match again — so the next tick would
        // re-raise this same sheet and a second tap would duplicate the tab.
        // Retire while the prompt is still up (same order as the "not now"
        // path): a sheet answered after the deadline would otherwise close the
        // window through the backstop arm and log a drop that never happened.
        retireForegroundRestoreCohortEntries(
            prompt.document.sessions.map(\.liveSessionID),
            reason: "prompt-reopen"
        )
        restorePrompt = nil
        restorePreviousConnections(
            from: prompt.document,
            preserveSnapshotLiveIDs: prompt.preserveSnapshotLiveIDs
        )
    }

    private func skipPreviousConnections() {
        logRestoreDiag("restore-prompt-not-now clear-store")
        retireForegroundRestoreCohortEntries(
            restorePrompt?.document.sessions.map(\.liveSessionID) ?? [],
            reason: "prompt-not-now"
        )
        restorePrompt = nil
        restoreAlwaysReopen = false
        closeForegroundRestoreWindow(reason: "skip-restore")
        sessionRestoreStore.clear()
    }

    private func restorePreviousConnections(
        from document: SessionRestoreDocument,
        preserveSnapshotLiveIDs: Bool = true,
        selectFallback: Bool = true
    ) {
        // Restoring writes snapshots, and the write re-evaluates the cohort.
        // The guard has to live here rather than only in
        // `attemptForegroundRestoreIfNeeded`, because `reopenPreviousConnections`
        // reaches this directly: without it the nested evaluation sees the
        // session being restored as still dead (its replacement carries a new
        // liveSessionID) and restores it a second time.
        let wasEvaluating = foregroundRestoreEvaluating
        foregroundRestoreEvaluating = true
        defer { foregroundRestoreEvaluating = wasEvaluating }

        // Deliberately does NOT close the restore window. Restoring one entry
        // used to clear the latch outright, which stranded every transport that
        // reported after it; the cohort decides when the window is done.
        if foregroundRestoreCohort.isEmpty {
            closeForegroundRestoreWindow(reason: "restore-begin")
        }
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
                    effectiveLaunchModeOverride: resolved.snapshot.effectiveLaunchMode,
                    select: false
                  )
            else {
                logRestoreDiag(
                    "restore-session-skip snapshot=\(shortID(resolved.snapshot.liveSessionID)) host=\(shortID(resolved.snapshot.persistedHostID)) reason=host-missing-or-ineligible-or-connect-failed"
                )
                if selectionWasCorpse {
                    selectedItem = nil
                    sidebarVisible = true
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

    /// Longest a restore window may stay open. Bounds every way a cohort
    /// entry can fail to reach a verdict — a wedged `.connecting`, a transport
    /// that never reports, a host the user never answers a prompt for.
    /// Derived, not chosen: a session wedged in `.connecting` reaches a verdict
    /// only when the SSH handshake budget fires, so a backstop shorter than that
    /// budget would retire it unresolved and drop its snapshot.
    private static let foregroundRestoreWindowMaxSeconds: TimeInterval =
        SSHSession.handshakeBudgetSeconds + 20

    /// Exposed so a test can assert the ordering constraint above rather than
    /// leaving it to a comment that can drift.
    static var foregroundRestoreWindowMaxSecondsForTesting: TimeInterval {
        foregroundRestoreWindowMaxSeconds
    }
    /// Earliest a still-connected entry may be believed. `activeSessions` lags
    /// a session's published state: in the 2026-08-17 repro two SSH transports
    /// died 4ms apart and the summary logged one millisecond later still
    /// printed both as connected. Plain SSH has no reachability signal to
    /// confirm against, so this floor stands in for one. It delays only the
    /// closing of the window — dead entries are restored the moment they are
    /// seen, so reconnection is not held back by it.
    private static let foregroundRestoreAliveFloorSeconds: TimeInterval = 5
    private static let foregroundRestoreTickNanoseconds: UInt64 = 500_000_000
    /// Longest step the window's clock may charge at once. Mirrors the SSH
    /// handshake watchdog's own clamp: a larger gap means the process was
    /// suspended, and a suspension is not time spent waiting on this wake.
    private static let foregroundRestoreMaxChargeSeconds: TimeInterval = 2

    @discardableResult
    private func attemptForegroundRestoreIfNeeded(reason: String) -> Bool {
        guard appPhase.isActive,
              didEvaluateStartupRestore,
              hasInactivePreservedRestoreSnapshots
        else { return false }
        guard !foregroundRestoreEvaluating else { return true }
        let wasEvaluating = foregroundRestoreEvaluating
        foregroundRestoreEvaluating = true
        defer { foregroundRestoreEvaluating = wasEvaluating }

        guard effectiveSessionRestorePolicy != .never else {
            logRestoreDiag("foreground-restore-clear reason=policy-never trigger=\(reason)")
            closeForegroundRestoreWindow(reason: "policy-never")
            sessionRestoreStore.clear()
            return true
        }

        guard let document = sessionRestoreStore.load() else {
            logRestoreDiag("foreground-restore-skip reason=no-document trigger=\(reason)")
            closeForegroundRestoreWindow(reason: "no-document")
            return false
        }

        // Seeded after the lock guard on purpose: charge passes park here, so
        // the window's clock cannot run behind a lock screen — and the persist
        // path treats latched-but-unopened as merge-protected, so the stored
        // document survives every write that lands before the unlock.
        guard !appLockController.isLocked else {
            logRestoreDiag(
                "foreground-restore-preserve reason=locked trigger=\(reason) cohort=\(foregroundRestoreCohort.count)"
            )
            scheduleForegroundRestoreTick(reason: "locked")
            return true
        }

        if foregroundRestoreWindowOpenedAt == nil {
            // Seed from the document written at the background edge, not from
            // `activeSessions`. The stored set is exactly the sessions whose
            // snapshots are at risk, and it does not lag.
            let openedAt = Date()
            foregroundRestoreWindowOpenedAt = openedAt
            foregroundRestoreChargedSeconds = 0
            foregroundRestoreLastChargeAt = openedAt
            foregroundRestoreCohort = document.sessions
            logRestoreDiag(
                "foreground-restore-window-open trigger=\(reason) cohort=\(foregroundRestoreCohort.count)"
            )
        }

        // Advance the window's clock before anything reads it, so both the
        // alive floor and the backstop below see this pass's time.
        chargeForegroundRestoreWindow()

        if activeSessions.isEmpty, foregroundRestoreCohort.count == document.sessions.count {
            // Nothing survived the wake. Restore the document whole rather
            // than entry-by-entry so the stored selection is honoured.
            logRestoreDiag(
                "foreground-restore-action restore-all trigger=\(reason) sessions=\(document.sessions.count)"
            )
            // Only `.always` acts now. Under `.ask` the entries keep their
            // cohort places — and therefore their snapshots — until the user
            // answers, or the write that follows would clear the store while
            // the unanswered sheet holds the only copy.
            if effectiveSessionRestorePolicy == .always {
                foregroundRestoreCohort = []
            }
            restoreForegroundDocument(document, reason: reason)
            // Falls through to settle/arm rather than returning: under `.ask`
            // this leaves a prompt up with an empty cohort, and an early return
            // would park the window open with no timer and no event to re-drive
            // it — after which the next foreground persist wipes the document.
            if closeForegroundRestoreWindowIfSettled(reason: "\(reason)-restore-all") {
                return true
            }
            scheduleForegroundRestoreTick(reason: reason)
            return true
        }

        let evaluation = ForegroundRestoreCohort.evaluate(
            cohort: foregroundRestoreCohort,
            live: foregroundRestoreLiveSessions(),
            elapsedSinceWindowOpened: foregroundRestoreElapsed(),
            aliveFloorSeconds: Self.foregroundRestoreAliveFloorSeconds,
            retiresDeadImmediately: effectiveSessionRestorePolicy == .always
        )
        let dead = evaluation.dead
        let retired = evaluation.retiredIDs

        if !retired.isEmpty {
            // Retire before restoring. An entry that has been acted on can
            // never be reconsidered, which is what stops a replacement that
            // fails from re-entering the cohort and looping.
            let retiredIDs = Set(retired)
            foregroundRestoreCohort.removeAll { retiredIDs.contains($0.liveSessionID) }
        }

        if !dead.isEmpty {
            logRestoreDiag(
                "foreground-restore-cohort-restore trigger=\(reason) dead=\(dead.count) remaining=\(foregroundRestoreCohort.count)"
            )
            let selected = document.selectedSessionID.flatMap { selected in
                dead.contains { $0.liveSessionID == selected } ? selected : nil
            }
            restoreForegroundDocument(
                SessionRestoreDocument(
                    savedAt: document.savedAt,
                    sessions: dead,
                    selectedSessionID: selected
                ),
                reason: "\(reason)-cohort",
                selectFallback: selected != nil,
                isCompleteDocument: false
            )
        }

        if closeForegroundRestoreWindowIfSettled(reason: reason) {
            return true
        }

        scheduleForegroundRestoreTick(reason: reason)
        return true
    }

    /// Lift the live-session facts a verdict depends on out of `LiveSession`,
    /// so the decision itself stays pure and testable.
    private func foregroundRestoreLiveSessions() -> [ForegroundRestoreLiveSession] {
        activeSessions.map { live in
            let transportConfirmed: Bool?
            if case .mosh(let mosh) = live.session {
                transportConfirmed = mosh.transportState == .connected
            } else {
                // SSH reports no reachability separate from `state`.
                transportConfirmed = nil
            }
            return ForegroundRestoreLiveSession(
                liveSessionID: live.id,
                persistedHostID: live.persistedHostID,
                state: live.session.terminalSession.state,
                transportConfirmed: transportConfirmed
            )
        }
    }

    /// Charge the window's clock for the time since the last pass.
    ///
    /// The lock guard in `attemptForegroundRestoreIfNeeded` returns before
    /// this, so a re-lock mid-window costs the window at most one clamped
    /// step however long the user stays away — deliberate, and the same shape
    /// as the handshake watchdog's treatment of a suspended process.
    private func chargeForegroundRestoreWindow() {
        guard foregroundRestoreWindowOpenedAt != nil else { return }

        let now = Date()
        foregroundRestoreChargedSeconds += ForegroundRestoreCohort.chargeDelta(
            now: now,
            lastChargeAt: foregroundRestoreLastChargeAt,
            isPrompting: SSHHandshakePromptGate.isPrompting,
            maxTick: Self.foregroundRestoreMaxChargeSeconds
        )
        foregroundRestoreLastChargeAt = now
    }

    private func foregroundRestoreElapsed() -> TimeInterval {
        guard foregroundRestoreWindowOpenedAt != nil else { return 0 }
        return foregroundRestoreChargedSeconds
    }

    /// Drop an entry because the user took ownership of that session — closed
    /// it, opened its host editor, or hit retry. Without this the window would
    /// reopen a session the user deliberately dismissed.
    private func retireForegroundRestoreCohortEntries(
        _ liveSessionIDs: [UUID],
        reason: String
    ) {
        guard !liveSessionIDs.isEmpty else { return }

        let ids = Set(liveSessionIDs)
        let before = foregroundRestoreCohort.count
        foregroundRestoreCohort.removeAll { ids.contains($0.liveSessionID) }
        guard foregroundRestoreCohort.count != before else { return }

        logRestoreDiag(
            "foreground-restore-cohort-retire count=\(before - foregroundRestoreCohort.count) reason=\(reason) remaining=\(foregroundRestoreCohort.count)"
        )
        closeForegroundRestoreWindowIfSettled(reason: "retire-\(reason)")
    }

    private func retireForegroundRestoreCohortEntry(
        _ liveSessionID: UUID,
        reason: String
    ) {
        guard foregroundRestoreCohort.contains(where: { $0.liveSessionID == liveSessionID })
        else { return }

        foregroundRestoreCohort.removeAll { $0.liveSessionID == liveSessionID }
        logRestoreDiag(
            "foreground-restore-cohort-retire live=\(shortID(liveSessionID)) reason=\(reason) remaining=\(foregroundRestoreCohort.count)"
        )
        closeForegroundRestoreWindowIfSettled(reason: "retire-\(reason)")
    }

    @discardableResult
    private func closeForegroundRestoreWindowIfSettled(reason: String) -> Bool {
        guard let openedAt = foregroundRestoreWindowOpenedAt else {
            closeForegroundRestoreWindow(reason: "\(reason)-unopened")
            return true
        }

        let elapsed = foregroundRestoreElapsed()
        let wallElapsed = Date().timeIntervalSince(openedAt)
        switch ForegroundRestoreCohort.windowClosure(
            remainingCohortCount: foregroundRestoreCohort.count,
            elapsedSinceWindowOpened: elapsed,
            maxWindowSeconds: Self.foregroundRestoreWindowMaxSeconds,
            hasUnansweredPrompt: restorePrompt != nil
        ) {
        case .open:
            return false
        case .backstop:
            logRestoreDiag(
                "foreground-restore-window-backstop reason=\(reason) unresolved=\(foregroundRestoreCohort.count) elapsedMs=\(Int(elapsed * 1000)) wallMs=\(Int(wallElapsed * 1000))"
            )
            closeForegroundRestoreWindow(reason: "backstop")
            return true
        case .settled:
            logRestoreDiag(
                "foreground-restore-window-settled reason=\(reason) elapsedMs=\(Int(elapsed * 1000)) wallMs=\(Int(wallElapsed * 1000)) activeCount=\(activeSessions.count)"
            )
            closeForegroundRestoreWindow(reason: "settled")
            persistRestoreSnapshots()
            return true
        }
    }

    private func closeForegroundRestoreWindow(reason: String) {
        cancelForegroundRestoreTick(reason: reason)
        foregroundRestoreCohort = []
        foregroundRestoreWindowOpenedAt = nil
        foregroundRestoreChargedSeconds = 0
        foregroundRestoreLastChargeAt = nil
        hasInactivePreservedRestoreSnapshots = false
    }

    /// Re-evaluate on a tick as well as on session events. Some verdicts —
    /// the alive floor, the backstop — turn on elapsed time alone and would
    /// otherwise wait on an unrelated event to notice. `reason` documents the
    /// arming site in call order; the tick itself logs under "tick".
    private func scheduleForegroundRestoreTick(reason _: String) {
        guard foregroundRestoreTickTask == nil else { return }

        foregroundRestoreTickTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: ContentView.foregroundRestoreTickNanoseconds
            )
            guard !Task.isCancelled else { return }
            foregroundRestoreTickTask = nil
            guard appPhase.isActive, hasInactivePreservedRestoreSnapshots else { return }
            attemptForegroundRestoreIfNeeded(reason: "tick")
        }
    }

    private func cancelForegroundRestoreTick(reason: String) {
        guard let task = foregroundRestoreTickTask else { return }

        task.cancel()
        foregroundRestoreTickTask = nil
        logRestoreDiag("foreground-restore-tick-cancel reason=\(reason)")
    }

    @discardableResult
    private func restoreForegroundDocument(
        _ document: SessionRestoreDocument,
        reason: String,
        selectFallback: Bool = true,
        isCompleteDocument: Bool = true
    ) -> Bool {
        let plan = restorePlan(for: document)
        guard plan.hasRestorableSessions else {
            logRestoreDiag(
                "foreground-restore-clear reason=no-restorable-in-document trigger=\(reason) sessions=\(document.sessions.count) complete=\(isCompleteDocument)"
            )
            if isCompleteDocument {
                closeForegroundRestoreWindow(reason: "no-restorable-in-document")
                sessionRestoreStore.clear()
            }
            // A subset (one cohort pass) proving unrestorable — a deleted host,
            // revoked credentials — says nothing about the other entries. Their
            // snapshots stay, and the window closes on its own terms.
            return true
        }

        switch effectiveSessionRestorePolicy {
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
            if let presented = restorePrompt {
                // A prompt on screen owns a snapshot set the user has not
                // answered yet, and answering it acts only on that set — so a
                // session that died after the sheet was raised would be left
                // out. Absorb a strictly larger set in place (same identity, so
                // the sheet updates rather than re-presents, and the user's
                // toggle survives); leave it alone otherwise.
                let presentedIDs = Set(presented.document.sessions.map(\.liveSessionID))
                let proposedIDs = Set(document.sessions.map(\.liveSessionID))
                guard proposedIDs.isStrictSuperset(of: presentedIDs) else {
                    logRestoreDiag(
                        "foreground-restore-preserve reason=prompt-present trigger=\(reason) presented=\(presentedIDs.count) proposed=\(proposedIDs.count)"
                    )
                    return true
                }

                logRestoreDiag(
                    "foreground-restore-action prompt-extend trigger=\(reason) presented=\(presentedIDs.count) proposed=\(proposedIDs.count)"
                )
                restorePrompt = SessionRestorePrompt(
                    id: presented.id,
                    document: document,
                    hostNames: plan.sessions.map(\.displayName),
                    skippedCount: plan.skippedCount,
                    preserveSnapshotLiveIDs: false
                )
                return true
            }
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
            closeForegroundRestoreWindow(reason: "policy-never-action")
            sessionRestoreStore.clear()
        }

        return true
    }

    private func persistRestoreSnapshots() {
        guard effectiveSessionRestorePolicy != .never else {
            logRestoreDiag("persist-clear reason=policy-never")
            hasInactivePreservedRestoreSnapshots = false
            sessionRestoreStore.clear()
            return
        }

        let isActive = appPhase.isActive
        let persistMode = ForegroundRestoreCohort.persistMode(
            isActive: isActive,
            hasPreservedSnapshots: hasInactivePreservedRestoreSnapshots,
            isWindowOpen: foregroundRestoreWindowOpenedAt != nil,
            hasCohortEntries: !foregroundRestoreCohort.isEmpty
        )
        let previousDocument = persistMode == .mergeWithStored
            ? sessionRestoreStore.load()
            : nil
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
                createdAt: live.createdAt,
                effectiveLaunchMode: live.effectiveLaunchMode
            )
        }

        let snapshots: [SessionRestoreSnapshot]
        switch persistMode {
        case .liveOnly:
            snapshots = currentSnapshots
        case .keepCohort:
            // The window is open. An entry awaiting its verdict keeps its
            // snapshot even once its tab is gone, so a write landing
            // mid-window cannot delete what is about to be restored.
            let liveIDs = Set(currentSnapshots.map(\.liveSessionID))
            snapshots = currentSnapshots + foregroundRestoreCohort.filter {
                !liveIDs.contains($0.liveSessionID)
            }
        case .mergeWithStored:
            // Whatever the store already holds outlives this write: the
            // terminal-state skip above drops a dead session from
            // `currentSnapshots` while the app is active, and behind an app
            // lock that dead session is exactly the one the wake owes the
            // user. Current wins per id; stored order leads so the pre-wake
            // arrangement survives.
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
        } else if persistMode == .mergeWithStored {
            selectedSessionID = previousDocument?.selectedSessionID
        } else if persistMode == .keepCohort {
            // The window is open, so the session the user was last looking at
            // may be mid-reconnect and momentarily absent from `activeSessions`.
            // Writing nil here would leave them on the host list after the wake.
            selectedSessionID = sessionRestoreStore.load()?.selectedSessionID
        } else {
            selectedSessionID = nil
        }

        sessionRestoreStore.save(
            sessions: snapshots,
            selectedSessionID: selectedSessionID
        )
        if !isActive {
            hasInactivePreservedRestoreSnapshots = !snapshots.isEmpty
        }
        logRestoreDiag(
            "persist-finished active=\(isActive) mode=\(persistMode) activeCount=\(activeSessions.count) previous=\(previousDocument?.sessions.count ?? 0) current=\(currentSnapshots.count) final=\(snapshots.count) selected=\(shortID(selectedSessionID)) savedAction=\(snapshots.isEmpty ? "clear-empty" : "save") skippedNoMarker=\(skippedNoHostMarker) skippedMissingHost=\(skippedMissingHost) skippedCredential=\(skippedCredential) skippedState=\(skippedState) preservedInactiveFailure=\(preservedInactiveFailure) inactivePreserved=\(hasInactivePreservedRestoreSnapshots) cohort=\(foregroundRestoreCohort.count)"
        )

        if isActive, hasInactivePreservedRestoreSnapshots {
            attemptForegroundRestoreIfNeeded(reason: "persist")
        }
    }

    private func isHostCredentialRestorable(_ host: PersistedHost) -> Bool {
        SessionRestoreEligibility.isRestorable(
            host: host,
            storedKey: { fetchStoredKey($0) }
        )
    }

    private func hostRouteHasUsableCredentials(_ host: PersistedHost) -> Bool {
        let resolution = HostJumpChainResolver.resolve(for: host, in: modelContext)
        guard !resolution.isBroken else { return false }
        return (resolution.hops + [host]).allSatisfy(isHostCredentialRestorable)
    }

    // MARK: - Sync & continuity

    private func refreshContinuityBroadcast(reason: String) {
        continuityBroadcastTask?.cancel()

        guard appearance.handoffSessionsEnabled,
              !appLockController.isLocked,
              appPhase.isActive,
              case .session(let selectedID) = selectedItem,
              let live = activeSessions.first(where: { $0.id == selectedID }),
              live.session.terminalSession.state == .connected,
              let persistedID = live.persistedHostID,
              fetchHost(persistedID) != nil
        else {
            activityBroadcaster.onContinuationStreams = nil
            activityBroadcaster.publish(nil)
            return
        }

        let host: Host
        switch live.session {
        case .ssh(let session): host = session.host
        case .mosh(let session): host = session.host
        }
        var broadcastHost = host
        broadcastHost.launchMode = live.effectiveLaunchMode
        broadcastHost.autoTmux = live.effectiveLaunchMode != .customCommand
        if live.effectiveLaunchMode == .customCommand {
            broadcastHost.tmuxSessionName = nil
        }
        let resolvedTmuxName: String?
        switch live.effectiveLaunchMode {
        case .autoTmux:
            resolvedTmuxName = HostRuntimeStateStore.sessionName(for: host)
        case .pinnedTmux:
            resolvedTmuxName = live.pinnedSessionName ?? host.tmuxSessionName
        case .customCommand:
            resolvedTmuxName = nil
        }
        let route = host.jumpChain + [host]
        if host.storedKeyID != nil || host.privateKeyFilename != nil {
            activityBroadcaster.onContinuationStreams = { [enrollmentCoordinator] input, output in
                enrollmentCoordinator.acceptOriginStreams(
                    input: input,
                    output: output,
                    focusedHost: host
                )
            }
        } else {
            // S6 deliberately omits peer enrollment when the origin has only
            // password access. The password path remains locally self-serve.
            activityBroadcaster.onContinuationStreams = nil
        }

        continuityBroadcastTask = Task { @MainActor in
            var fingerprints: [UUID: String] = [:]
            var routeEndpoints: [String] = []
            for routeHost in route {
                if Task.isCancelled { return }
                routeEndpoints.append("\(routeHost.address):\(routeHost.port)")
                let trustEndpoint = sshHostKeyEndpoint(routeEndpoints: routeEndpoints)
                if let fingerprint = await KnownHostsStore.shared.trustedFingerprint(
                    for: trustEndpoint
                ) {
                    fingerprints[routeHost.id] = fingerprint
                }
            }
            guard !Task.isCancelled,
                  selectedItem == .session(selectedID),
                  activeSessions.first(where: { $0.id == selectedID })?
                    .session.terminalSession.state == .connected
            else { return }

            do {
                let descriptor = try SessionActivityDescriptor(
                    host: broadcastHost,
                    resolvedTmuxSessionName: resolvedTmuxName,
                    hostKeyFingerprint: fingerprints[host.id],
                    viaHostKeyFingerprints: fingerprints
                )
                activityBroadcaster.publish(descriptor)
                DiagnosticLogStore.appendApp(
                    "continuity broadcast refresh reason=\(reason) result=ready"
                )
            } catch {
                activityBroadcaster.reportFailure(error.localizedDescription)
                DiagnosticLogStore.appendApp(
                    "continuity broadcast refresh reason=\(reason) result=invalid error='\(error.localizedDescription)'"
                )
            }
        }
    }

    private func handleIncomingContinuation(_ pending: PendingContinuation) {
        guard !appLockController.isLocked else { return }
        continuationCompletionTask?.cancel()
        continuationCompletionTask = nil
        let descriptor = pending.descriptor
        continuationOverlay = ContinuationOverlayPresentation(
            descriptor: descriptor,
            phase: .resolving
        )

        let candidates = fetchHosts().map { persisted in
            ContinuationHostCandidate(
                host: Host(from: persisted),
                connectionKey: persisted.connectionKey
            )
        }
        let resolution = ContinuationResolver.resolve(
            descriptor,
            among: candidates
        )

        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["TESSERA_CONTINUITY_HARNESS"],
           let scenario = ContinuityDebugHarnessScenario.make(value: value),
           scenario.pausesAfterResolution {
            let resolvedAs: String
            switch resolution {
            case .fastPath:
                resolvedAs = "exact saved-host match"
            case .endpointMatch:
                resolvedAs = "endpoint saved-host match"
            case .prefill:
                resolvedAs = "unexpected prefill"
            }
            continuationCoordinator.consume(pending.id)
            continuationOverlay?.phase = .failed(
                "Harness resolved an \(resolvedAs) and stopped before connecting."
            )
            return
        }
        #endif

        switch resolution {
        case .fastPath(let host), .endpointMatch(let host):
            guard let persisted = fetchHost(host.id) else {
                continuationOverlay?.phase = .failed(
                    String(localized: "The matching saved host disappeared before the continuation could start.")
                )
                continuationCoordinator.consume(pending.id)
                return
            }
            continuationCoordinator.consume(pending.id)
            guard hostRouteHasUsableCredentials(persisted) else {
                continuationOverlay = nil
                continuationDraft = ContinuationDraft(
                    descriptor: descriptor,
                    rootHostID: persisted.id,
                    insertedHostIDs: []
                )
                selectedItem = .host(persisted.id)
                sidebarVisible = false
                return
            }
            continuationOverlay?.phase = .connecting
            guard let live = connectSavedHost(
                persisted,
                continuationDescriptor: descriptor,
                select: true
            ) else {
                continuationOverlay?.phase = .failed(
                    String(localized: "Tessera could not create the requested session.")
                )
                return
            }
            continuationLiveSessionID = live.id
            if sessionRegistry.isRenderReady(live.id) {
                finishContinuationAfterRenderReady()
            }

        case .prefill:
            continuationCoordinator.consume(pending.id)
            continuationOverlay = nil
            beginContinuationPrefill(descriptor)
        }
    }

    private func updateContinuationOverlay(for event: RestoreStateEvent) {
        guard continuationLiveSessionID == event.liveSessionID else { return }
        // `sessionStatePublisher` is rebuilt on every body evaluation and
        // `@Published` replays the current state to each new subscriber, so
        // the same `.connected` event re-arrives after any state mutation.
        // Once the overlay reached `.attached`, such a replay must be a
        // no-op: downgrading to `.connecting` and re-finishing would cancel
        // and restart the dismissal task on every re-render, keeping the
        // overlay on screen forever.
        switch event.state {
        case .idle, .connecting:
            if continuationOverlay?.phase != .attached {
                continuationOverlay?.phase = .connecting
            }
        case .connected:
            guard continuationOverlay?.phase != .attached else { return }
            // SSH/mosh transport readiness precedes the user-visible launch
            // boundary for every mode. In particular, tmux still has to
            // hydrate and paint its first pane. SessionRegistry owns that
            // shared render-ready signal, so the blocking overlay stays up.
            continuationOverlay?.phase = .connecting
            if sessionRegistry.isRenderReady(event.liveSessionID) {
                finishContinuationAfterRenderReady()
            }
        case .disconnected:
            continuationOverlay?.phase = .failed(
                String(localized: "The remote session disconnected before it was ready.")
            )
        case .failed:
            continuationOverlay?.phase = .failed(
                String(localized: "Authentication or transport setup failed. Review this device's credential and try again.")
            )
        }
    }

    /// Swap the blocking connect card for the non-interactive S2/S3 toast only
    /// after the terminal surface underneath is genuinely usable. The toast
    /// then gets out of the way without requiring a second user action.
    private func finishContinuationAfterRenderReady() {
        guard let liveID = continuationLiveSessionID,
              sessionRegistry.isRenderReady(liveID),
              let overlay = continuationOverlay,
              overlay.phase != .attached
        else { return }

        DiagnosticLogStore.appendApp("continuity overlay phase=attached")
        continuationOverlay?.phase = .attached
        continuationCompletionTask?.cancel()
        let overlayID = overlay.id
        continuationCompletionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled,
                  continuationOverlay?.id == overlayID,
                  continuationOverlay?.phase == .attached
            else { return }
            DiagnosticLogStore.appendApp("continuity overlay phase=dismissed")
            continuationOverlay = nil
            continuationLiveSessionID = nil
            continuationCompletionTask = nil
            continuationCoordinator.finishActive()
        }
    }

    private func beginContinuationPrefill(_ descriptor: SessionActivityDescriptor) {
        if let conflict = continuationRouteConflict(for: descriptor) {
            continuationOverlay = ContinuationOverlayPresentation(
                descriptor: descriptor,
                phase: .failed(conflict)
            )
            DiagnosticLogStore.appendApp(
                "continuity prefill result=rejected-route-conflict error='\(conflict)'"
            )
            return
        }

        let plannedInsertedIDs = ContinuationInsertionPlanner.plannedInsertedHostIDs(
            for: descriptor
        ) { id in
            fetchHost(id) != nil
        }
        guard let existingHostCount = savedHostCountForAdmission() else {
            continuationCoordinator.finishActive()
            return
        }

        // A Handoff that would persist new saved-host rows funnels through
        // the same admission policy as a manual add, before anything is
        // staged or inserted. The resume re-enters this function whole, so
        // the conflict preflight and the quota both re-evaluate against
        // current state; a declined purchase leaves zero mutation.
        switch SavedHostAdmissionPolicy.decision(
            existingHostCount: existingHostCount,
            newRowCount: plannedInsertedIDs.count,
            access: hostAccessStore.accessState
        ) {
        case .allow:
            stageContinuationPrefill(descriptor, plannedInsertedIDs: plannedInsertedIDs)
        case .checkingEntitlement, .requiresPurchase:
            // The coordinator owns entitlement-readiness, the deferred token,
            // and the prompt; its resume re-enters this function rather than
            // the insert, so nothing can stage a row before the decision.
            let accepted = requestSavedHostAdmission(
                newRowCount: plannedInsertedIDs.count,
                resume: { self.beginContinuationPrefill(descriptor) },
                onCancel: { self.continuationCoordinator.finishActive() }
            )
            if !accepted {
                continuationCoordinator.finishActive()
                presentContinuityFailure(
                    String(localized: "Finish the current host setup, then try Handoff again."),
                    source: .incoming
                )
            }
        }
    }

    private func stageContinuationPrefill(
        _ descriptor: SessionActivityDescriptor,
        plannedInsertedIDs: Set<UUID>
    ) {
        var insertedIDs = Set<UUID>()
        ContinuationDraftRecoveryStore().stage(hostIDs: plannedInsertedIDs)

        func persistedHost(for endpoint: SessionActivityEndpoint) -> PersistedHost {
            if let existing = fetchHost(endpoint.hostID) {
                return existing
            }
            let host = PersistedHost(
                id: endpoint.hostID,
                name: endpoint.name,
                address: endpoint.address,
                port: endpoint.port,
                autoTmux: false,
                transport: endpoint.transport,
                launchMode: .customCommand,
                sortOrder: fetchHosts().count
            )
            host.user = endpoint.user
            modelContext.insert(host)
            insertedIDs.insert(host.id)
            return host
        }

        let viaHosts = descriptor.via.map(persistedHost(for:))
        let root = PersistedHost(
            id: descriptor.hostID,
            name: descriptor.name,
            address: descriptor.address,
            port: descriptor.port,
            autoTmux: descriptor.launchMode != .customCommand,
            transport: descriptor.transport,
            launchMode: descriptor.launchMode,
            tmuxSessionName: descriptor.launchMode == .pinnedTmux
                ? descriptor.tmuxSessionName : nil,
            sortOrder: fetchHosts().count
        )
        root.user = descriptor.user
        modelContext.insert(root)
        insertedIDs.insert(root.id)

        if !viaHosts.isEmpty {
            for index in 1..<viaHosts.count {
                // Existing route hosts passed the preflight below and must
                // remain byte-for-byte local configuration. Only a host
                // inserted for this draft is allowed to acquire a link.
                if insertedIDs.contains(viaHosts[index].id) {
                    HostJumpChainResolver.setJumpHost(
                        viaHosts[index - 1].id,
                        for: viaHosts[index].id,
                        in: modelContext
                    )
                }
            }
            HostJumpChainResolver.setJumpHost(
                viaHosts.last?.id,
                for: root.id,
                in: modelContext
            )
        }

        continuationDraft = ContinuationDraft(
            descriptor: descriptor,
            rootHostID: root.id,
            insertedHostIDs: insertedIDs
        )
        selectedItem = .host(root.id)
        sidebarVisible = false
    }

    #if DEBUG
    /// Seeds only public host metadata for the simulator resolver oracle. The
    /// matching flow is stopped before connection creation, so this helper
    /// never stores or invents credentials and never initiates a connection.
    private func prepareContinuityHarnessSavedHostIfNeeded() {
        guard let value = ProcessInfo.processInfo.environment["TESSERA_CONTINUITY_HARNESS"],
              let scenario = ContinuityDebugHarnessScenario.make(value: value)
        else { return }

        let savedID: UUID
        switch scenario.savedHostSeed {
        case .none:
            return
        case .exact(let id), .endpoint(let id):
            savedID = id
        }
        guard fetchHost(savedID) == nil else { return }

        let endpoint = scenario.descriptor.endpoint
        let host = PersistedHost(
            id: savedID,
            name: endpoint.name,
            address: endpoint.address,
            port: endpoint.port,
            autoTmux: scenario.descriptor.launchMode != .customCommand,
            transport: endpoint.transport,
            launchMode: scenario.descriptor.launchMode,
            tmuxSessionName: scenario.descriptor.tmuxSessionName,
            sortOrder: fetchHosts().count
        )
        host.user = endpoint.user
        modelContext.insert(host)
        try? modelContext.save()
    }

    /// Seeds the saved host + password credential for the live continuation
    /// harness so the injected descriptor takes the production fast path.
    private func prepareContinuityLiveHarnessSavedHostIfNeeded() {
        guard let cfg = ContinuityLiveHarnessConfiguration.load() else { return }
        guard fetchHost(ContinuityLiveHarnessConfiguration.hostID) == nil else {
            NSLog("[ContinuityLiveHarness] saved host already present")
            return
        }
        let identity = Identity(
            name: "Live Harness",
            user: cfg.user,
            credentialMode: .password
        )
        modelContext.insert(identity)
        do {
            try KeychainHelper.setPassword(cfg.password, forIdentityID: identity.id)
        } catch {
            NSLog("[ContinuityLiveHarness] keychain seed failed: \(error)")
            return
        }
        let host = PersistedHost(
            id: ContinuityLiveHarnessConfiguration.hostID,
            name: cfg.name,
            address: cfg.address,
            port: cfg.port,
            autoTmux: cfg.launchMode != .customCommand,
            transport: cfg.transport,
            launchMode: cfg.launchMode,
            tmuxSessionName: cfg.tmuxSessionName,
            sortOrder: fetchHosts().count,
            identity: identity
        )
        host.user = cfg.user
        modelContext.insert(host)
        try? modelContext.save()
        NSLog("[ContinuityLiveHarness] seeded host id=\(host.id)")
    }

    /// Presents the real informed-TOFU sheet with a continuation fingerprint,
    /// but no SSH session. The test must choose a safe terminal action so the
    /// continuation backing the request is always resumed.
    private func presentContinuityHostKeyHarnessIfNeeded() {
        guard hostKeyRequest == nil,
              let mode = ProcessInfo.processInfo.environment[
                "TESSERA_CONTINUITY_HOSTKEY_HARNESS"
              ],
              mode == "match" || mode == "mismatch"
        else { return }

        let actual = "SHA256:continuity-harness-actual"
        let challenge = HostKeyVerificationChallenge(
            endpoint: "continuity-harness.invalid:22",
            fingerprint: actual,
            keyType: "ssh-ed25519",
            isChanged: false,
            oldFingerprint: nil,
            peerFingerprint: mode == "match"
                ? actual
                : "SHA256:continuity-harness-other-device",
            peerLabel: "iPad"
        )
        Task { @MainActor in
            _ = await withCheckedContinuation { continuation in
                hostKeyRequest = HostKeyVerificationRequest(
                    challenge: challenge,
                    continuation: continuation
                )
            }
        }
    }
    #endif

    /// A Handoff descriptor may reference a bastion that already exists on
    /// this device. Reusing it is safe only when both its endpoint and its
    /// complete outward route already match. The prefill is never allowed to
    /// rewrite saved routing as a side effect of merely opening an activity.
    private func continuationRouteConflict(
        for descriptor: SessionActivityDescriptor
    ) -> String? {
        let existingVia = Dictionary(uniqueKeysWithValues: descriptor.via.compactMap {
            endpoint -> (UUID, ContinuationSavedRouteEndpoint)? in
            guard let existing = fetchHost(endpoint.hostID) else { return nil }
            return (
                endpoint.hostID,
                ContinuationSavedRouteEndpoint(
                    endpoint: SessionActivityEndpoint(
                        hostID: existing.id,
                        name: existing.name,
                        user: existing.effectiveUser,
                        address: existing.address,
                        port: existing.port,
                        transport: existing.transport
                    ),
                    jumpHostID: HostJumpChainResolver.link(
                        for: existing.id,
                        in: modelContext
                    )?.jumpHostID
                )
            )
        })
        let conflict = ContinuationRouteReusePolicy.conflict(
            for: descriptor,
            destinationIdentifierExists: fetchHost(descriptor.hostID) != nil,
            savedVia: existingVia
        )

        switch conflict {
        case .destinationIdentifierAlreadyExists:
            return String(localized: "A saved host already uses this continuation identifier but does not match its endpoint. Review that host before reconnecting.")
        case .endpointDiffers(let hostID):
            guard let existing = fetchHost(hostID) else { return String(localized: "A saved jump host has different connection details. Tessera did not change it.") }
            let existingLabel = existing.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? existing.address : existing.name
            return String(localized: "The saved jump host \(existingLabel) has different connection details. Tessera did not change it.")
        case .routeDiffers(let hostID):
            guard let existing = fetchHost(hostID) else { return String(localized: "A saved jump route differs from the other device. Tessera did not reroute it.") }
            let existingLabel = existing.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? existing.address : existing.name
            return String(localized: "The saved jump route for \(existingLabel) differs from the other device. Tessera did not reroute it.")
        case nil:
            return nil
        }
    }

    private func cancelContinuationDraft(resetNavigation: Bool = true) {
        guard let draft = continuationDraft else { return }
        for hostID in draft.insertedHostIDs {
            HostJumpChainResolver.removeOutgoingLink(
                for: hostID,
                in: modelContext
            )
        }
        for hostID in draft.insertedHostIDs {
            if let host = fetchHost(hostID) {
                modelContext.delete(host)
            }
        }
        try? modelContext.save()
        continuationDraft = nil
        ContinuationDraftRecoveryStore().clear()
        enrollmentCoordinator.onRequesterEnrollmentCompleted = nil
        continuationCoordinator.cancel()
        if resetNavigation {
            selectedItem = nil
            sidebarVisible = true
        }
    }

    /// A continuation prefill uses staged SwiftData rows because the shared
    /// host editor is model-backed. Leaving that editor is an explicit abandon
    /// boundary: delete every staged row immediately and release the active
    /// continuation so another Handoff can be accepted without relaunching.
    private func abandonContinuationDraftIfNeeded(afterSelecting selection: SidebarItem?) {
        guard let draft = continuationDraft,
              selection != .host(draft.rootHostID)
        else { return }
        cancelContinuationDraft(resetNavigation: false)
    }

    private func recoverAbandonedContinuationDraftIfNeeded() {
        guard continuationDraft == nil,
              continuationCoordinator.active == nil,
              let recovery = ContinuationDraftRecoveryStore().load()
        else { return }

        let hostIDs = Set(recovery.hostIDs)
        for hostID in hostIDs {
            HostJumpChainResolver.removeOutgoingLink(
                for: hostID,
                in: modelContext
            )
        }
        for host in fetchHosts() where hostIDs.contains(host.id) {
            modelContext.delete(host)
        }

        if let identities = try? modelContext.fetch(FetchDescriptor<Identity>()) {
            let identityIDs = Set(recovery.identityIDs)
            for identity in identities where identityIDs.contains(identity.id) {
                try? KeychainHelper.deletePassword(forIdentityID: identity.id)
                modelContext.delete(identity)
            }
        }
        try? modelContext.save()
        ContinuationDraftRecoveryStore().clear()
        DiagnosticLogStore.appendApp(
            "continuity prefill recovered abandonedHosts=\(hostIDs.count) abandonedIdentities=\(recovery.identityIDs.count)"
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
        sidebarVisible = false
    }

    private func connect(
        to persistedHost: PersistedHost,
        password: String = "",
        jumpPasswords: [UUID: String] = [:],
        continuationDescriptor: SessionActivityDescriptor? = nil
    ) {
        _ = connectSavedHost(
            persistedHost,
            password: password,
            jumpPasswords: jumpPasswords,
            continuationDescriptor: continuationDescriptor,
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
            effectiveLaunchMode: old.effectiveLaunchMode,
            pinnedSessionName: old.pinnedSessionName,
            createdAt: old.createdAt
        )
        activeSessions[index] = replacement
        if selectedItem == .session(old.id) {
            selectedItem = .session(replacement.id)
        }
        // The fallback IS this session's recovery, and the replacement carries a
        // new liveSessionID the cohort entry can never match again. Left in, the
        // entry would read `.dead` forever and be restored alongside the
        // fallback — two tabs for one host.
        retireForegroundRestoreCohortEntry(old.id, reason: "mosh-jump-fallback")
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
        continuationDescriptor: SessionActivityDescriptor? = nil,
        effectiveLaunchModeOverride: HostLaunchMode? = nil,
        select: Bool
    ) -> LiveSession? {
        SSHAuthenticationPolicyStore.shared.registerPersistedHost(persistedHost.id)
        let hostKey = persistedHost.connectionKey
        let mode = effectiveLaunchModeOverride
            ?? continuationDescriptor?.launchMode
            ?? persistedHost.launchMode
        let continuationTmuxName = continuationDescriptor?.tmuxSessionName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Singleton tmux: if an auto-tmux session (default OR pinned-
        // with-the-same-name) to this host is already active, just
        // switch to it instead of connecting again. A different pinned
        // name or a custom command always spawns a fresh session.
        if mode == .autoTmux,
           let existing = activeSessions.first(where: {
               $0.hostKey == hostKey
               && $0.launchMode == .autoTmux
               && isReusableLiveSession($0)
               && ContinuationTmuxReusePolicy.mayReuseAutoTmuxSession(
                    requestedSessionName: continuationTmuxName,
                    activeSessionName: $0.pinnedSessionName
               )
           }) {
            if select {
                selectedItem = .session(existing.id)
                sidebarVisible = false
            }
            return existing
        }
        if mode == .pinnedTmux {
            let pinned = (continuationTmuxName ?? persistedHost.tmuxSessionName)?
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
                    sidebarVisible = false
                }
                return existing
            }
        }

        let transientJumpPasswords = jumpPasswords.mapValues {
            HostTransientPasswordCredential(password: $0, revision: nil)
        }
        var hostDTO = Host(
            from: persistedHost,
            transientPassword: password,
            transientJumpPasswords: transientJumpPasswords
        )
        hostDTO.launchMode = mode
        hostDTO.autoTmux = mode != .customCommand
        if let continuationDescriptor {
            hostDTO.launchMode = continuationDescriptor.launchMode
            hostDTO.autoTmux = continuationDescriptor.launchMode != .customCommand
            switch continuationDescriptor.launchMode {
            case .autoTmux:
                if let continuationTmuxName, !continuationTmuxName.isEmpty {
                    HostRuntimeStateStore.recordSessionUsed(
                        continuationTmuxName,
                        for: hostDTO
                    )
                }
                hostDTO.tmuxSessionName = nil
            case .pinnedTmux:
                hostDTO.tmuxSessionName = continuationTmuxName
            case .customCommand:
                hostDTO.tmuxSessionName = nil
            }
            hostDTO.continuationHostKeyFingerprints = ContinuationTrustHintMapper.hints(
                from: continuationDescriptor,
                for: hostDTO
            )
            hostDTO.continuationPeerLabel = String(localized: "your other device")
        }
        // Nearby bootstrap fingerprints are absent by default. When the sender
        // opts into trusted host keys, exact non-conflicting records are
        // imported and the same fingerprints remain available as comparison
        // hints if a local conflict was preserved. Feed any such hint through
        // the Handoff verification UI; an activity descriptor wins if both
        // exist because it describes the exact session just selected.
        let bootstrapTrustHints = BootstrapTrustHintStore()
        for routeHost in hostDTO.jumpChain + [hostDTO]
        where hostDTO.continuationHostKeyFingerprints[routeHost.id] == nil {
            guard let hint = bootstrapTrustHints.hint(for: routeHost.id) else {
                continue
            }
            hostDTO.continuationHostKeyFingerprints[routeHost.id] = hint.fingerprint
            if hostDTO.continuationPeerLabel == nil {
                hostDTO.continuationPeerLabel = hint.peerDeviceName
            }
        }
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
        let liveTmuxSessionName: String?
        switch mode {
        case .autoTmux:
            liveTmuxSessionName = continuationTmuxName
                ?? HostRuntimeStateStore.sessionName(for: hostDTO)
        case .pinnedTmux:
            liveTmuxSessionName = continuationTmuxName
                ?? persistedHost.tmuxSessionName
        case .customCommand:
            liveTmuxSessionName = nil
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
            effectiveLaunchMode: mode,
            pinnedSessionName: liveTmuxSessionName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: createdAt
        )
        activeSessions.append(live)
        if select {
            selectedItem = .session(live.id)
            sidebarVisible = false
        }
        persistRestoreSnapshots()
        return live
    }

    private func updateEffectiveLaunchMode(
        for liveSessionID: UUID,
        to mode: HostLaunchMode
    ) {
        guard let index = activeSessions.firstIndex(where: { $0.id == liveSessionID }),
              activeSessions[index].effectiveLaunchMode != mode
        else { return }
        activeSessions[index].effectiveLaunchMode = mode
        persistRestoreSnapshots()
        refreshContinuityBroadcast(reason: "effective-launch-mode")
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
        // An explicit close is the user taking ownership of this session; the
        // restore window must not reopen it.
        retireForegroundRestoreCohortEntry(live.id, reason: "dismissed")
        let wasSelected = selectedItem == .session(live.id)
        activeSessions.removeAll { $0.id == live.id }
        if wasSelected {
            selectedItem = nil
            sidebarVisible = true
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
        sidebarVisible = false
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
        case .home:
            selectedItem = nil
            sidebarVisible = true
            if isPhone { compactPresentation.tab = .hosts }
        case .pane(let sessionID, let windowID, let paneID):
            selectSession(sessionID)
            sessionRegistry.requestTmuxFocus(
                sessionID: sessionID,
                windowID: windowID,
                paneID: paneID
            )
        case .session(let id): selectSession(id)
        case .window(let sessionID, let windowID):
            selectSession(sessionID)
            sessionRegistry.requestTmuxFocus(
                sessionID: sessionID,
                windowID: windowID
            )
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
        if isPhone {
            selectedItem = .agents
            compactPresentation.sessionsView = .agents
            compactPresentation.tab = .sessions
            return
        }
        if selectedItem == .agents {
            if case .session(let id) = agentCenterReturnItem,
               !activeSessions.contains(where: { $0.id == id }) {
                selectedItem = nil
                sidebarVisible = true
            } else {
                let target = agentCenterReturnItem
                selectedItem = target
                if case .some(.session) = target {
                    sidebarVisible = false
                } else {
                    sidebarVisible = true
                }
            }
        } else {
            agentCenterReturnItem = selectedItem
            selectedItem = .agents
            sidebarVisible = true
        }
    }

    private func syncAgentScrollLock() {
        agentCenter.setScrollLock(
            claudeCode: appearance.agentScrollLockClaudeCodeEnabled,
            codex: appearance.agentScrollLockCodexEnabled
        )
    }

    private func updateAgentSurfaceDemand() {
        let compactAgentListVisible = isPhone
            && compactPresentation.tab == .sessions
            && compactPresentation.sessionsView == .agents
        agentCenter.setSurfaceDemand(
            appearance.agentCenterEnabled
                && (compactAgentListVisible
                    || (!isPhone && selectedItem == .agents)
                    || commandPalette.isOpen)
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
        if isPhone {
            compactPresentation.tab = .settings
        }
        sidebarVisible = true
    }

    private func logRestoreDiag(_ message: String) {
        DiagnosticLogStore.appendRestore(message)
    }

    private func activeSessionSummary(limit: Int = 8) -> String {
        guard !activeSessions.isEmpty else { return "[]" }

        let parts = activeSessions.prefix(limit).map { live in
            "live=\(shortID(live.id)),host=\(shortID(live.persistedHostID)),transport=\(transportDescription(live)),state=\(stateDescription(live.session.terminalSession.state)),mode=\(live.effectiveLaunchMode.rawValue)"
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

enum CompactRootTab: Hashable {
    case hosts
    case sessions
    case keys
    case settings
}

enum CompactSessionsView: Equatable {
    case sessions
    case agents
}

enum CompactKeysView: Equatable {
    case keys
    case knownHosts
}

struct CompactNavigationPresentation: Equatable {
    var tab: CompactRootTab = .hosts
    var sessionsView: CompactSessionsView = .sessions
    var keysView: CompactKeysView = .keys

    mutating func reconcile(with selection: SidebarItem?) {
        switch selection {
        case nil, .host:
            tab = .hosts
        case .session:
            tab = .sessions
            sessionsView = .sessions
        case .agents:
            tab = .sessions
            sessionsView = .agents
        case .keys:
            tab = .keys
            keysView = .keys
        case .knownHosts:
            tab = .keys
            keysView = .knownHosts
        case .settings:
            tab = .settings
        case .tunnels:
            // Compact intentionally has no Tunnels destination. Show Hosts but
            // leave the authoritative `.tunnels` selection untouched so a
            // compact -> regular round trip restores the iPad-only page.
            tab = .hosts
        }
    }
}

private struct CompactSessionsPage: View {
    let activeSessions: [LiveSession]
    @Binding var selectedView: CompactSessionsView
    @Bindable var agentCenter: AgentCenter
    let agentCenterEnabled: Bool
    let onSelectSession: (UUID) -> Void
    let onDisconnectSession: (LiveSession) -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(spacing: 0) {
            Text("sessions")
                .font(Typography.pageTitle)
                .foregroundStyle(T.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

            if agentCenterEnabled {
                CompactViewSelector(
                    leadingTitle: "sessions",
                    trailingTitle: "agents",
                    selection: Binding(
                        get: { selectedView == .sessions },
                        set: { selectedView = $0 ? .sessions : .agents }
                    )
                )
            }

            switch selectedView {
            case .sessions:
                sessionList
            case .agents:
                if agentCenterEnabled {
                    AgentCenterPage(center: agentCenter)
                } else {
                    sessionList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(T.bg.ignoresSafeArea())
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Text("active · \(activeSessions.count)")
                    .font(Typography.tesseraMono(size: 11))
                    .tracking(0.4)
                    .foregroundStyle(T.fgMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                if activeSessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(T.fgDim)

                        Text("no active sessions")
                            .font(Typography.tesseraMono(size: 13))
                            .foregroundStyle(T.fgMuted)

                        Text("connect from Hosts; leaving a terminal keeps it running here")
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgDim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    ForEach(activeSessions) { live in
                        CompactSessionRow(
                            live: live,
                            allSessions: activeSessions,
                            action: { onSelectSession(live.id) },
                            onDisconnect: { onDisconnectSession(live) }
                        )
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
    }
}

private struct CompactSessionRow: View {
    let live: LiveSession
    let allSessions: [LiveSession]
    let action: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        switch live.session {
        case .ssh(let session):
            CompactSessionRowBody(
                session: session,
                live: live,
                allSessions: allSessions,
                transport: "ssh",
                action: action,
                onDisconnect: onDisconnect
            )
        case .mosh(let session):
            CompactSessionRowBody(
                session: session,
                live: live,
                allSessions: allSessions,
                transport: "mosh",
                action: action,
                onDisconnect: onDisconnect
            )
        }
    }
}

private struct CompactSessionRowBody<S: ObservableObject & TerminalSession>: View {
    @ObservedObject var session: S
    let live: LiveSession
    let allSessions: [LiveSession]
    let transport: String
    let action: () -> Void
    let onDisconnect: () -> Void

    @State private var confirmingDisconnect = false
    @Environment(\.designTokens) private var T
    @Environment(SessionRegistry.self) private var registry

    var body: some View {
        let rawState = session.state
        let state: SessionState = (rawState == .connected && !registry.isRenderReady(live.id))
            ? .connecting
            : rawState

        // spacing 0: the disconnect button's 44 pt hit frame supplies the gap.
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 11) {
                    StatusDot(
                        color: statusColor(state),
                        pulse: state == .connecting || state == .connected,
                        size: 7
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(live.displayLabel(in: allSessions))
                            .font(Typography.tesseraMono(size: 13, weight: .medium))
                            .foregroundStyle(T.fg)
                            .lineLimit(1)

                        Text(verbatim: "\(transportLabel) · \(stateLabel(state))")
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgMuted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(T.fgDim)
                }
                .frame(minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                confirmingDisconnect = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(T.red)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(T.red.opacity(0.14)))
                    .overlay(Circle().stroke(T.red.opacity(0.35), lineWidth: 0.5))
                    // trailing 4: where the old 38 pt frame centered the circle.
                    .padding(.trailing, 4)
                    // 30 pt visual circle inside a 44 pt-wide, row-height hit
                    // frame. Must not shrink below 44 pt: iPadOS 26 expands
                    // sub-44 pt targets itself and mis-assigns taps between
                    // adjacent controls (the row's open button would fire).
                    .frame(width: 44, height: 54, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("disconnect \(live.displayLabel(in: allSessions))")
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
        .confirmationDialog(
            "Disconnect \(live.displayLabel(in: allSessions))?",
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive, action: onDisconnect)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var transportLabel: String {
        live.autoTmux ? "\(transport)+tmux" : transport
    }

    private func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .idle: return String(localized: "idle")
        case .connecting: return String(localized: "connecting…")
        case .connected: return String(localized: "connected")
        case .disconnected: return String(localized: "disconnected")
        case .failed: return String(localized: "failed")
        }
    }

    private func statusColor(_ state: SessionState) -> Color {
        switch state {
        case .idle: return T.fgDim
        case .connecting: return T.amber
        case .connected: return T.green
        case .disconnected, .failed: return T.red
        }
    }
}

private struct CompactViewSelector: View {
    let leadingTitle: LocalizedStringKey
    let trailingTitle: LocalizedStringKey
    @Binding var selection: Bool

    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(spacing: 3) {
            segment(leadingTitle, selected: selection) {
                selection = true
            }
            segment(trailingTitle, selected: !selection) {
                selection = false
            }
        }
        .padding(3)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    private func segment(
        _ title: LocalizedStringKey,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.tesseraMono(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? T.accent : T.fgMuted)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
                .background(selected ? T.accentSoft : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "selected" : "not selected")
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

#if DEBUG
private let compactNavigationCompactNotification =
    "com.bambouville.TesseraApp.tests.compact-navigation.compact"
private let compactNavigationRegularNotification =
    "com.bambouville.TesseraApp.tests.compact-navigation.regular"

private final class CompactNavigationHarnessWidthController: ObservableObject {
    @Published var usesCompactWidth: Bool

    init(startsCompact: Bool) {
        usesCompactWidth = startsCompact
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            compactNavigationWidthNotificationCallback,
            compactNavigationCompactNotification as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            observer,
            compactNavigationWidthNotificationCallback,
            compactNavigationRegularNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil
        )
    }

    fileprivate func receive(_ notificationName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if notificationName == compactNavigationCompactNotification {
                usesCompactWidth = true
            } else if notificationName == compactNavigationRegularNotification {
                usesCompactWidth = false
            }
        }
    }
}

private let compactNavigationWidthNotificationCallback: CFNotificationCallback = {
    _, observer, name, _, _ in
    guard let observer, let name else { return }
    let controller = Unmanaged<CompactNavigationHarnessWidthController>
        .fromOpaque(observer)
        .takeUnretainedValue()
    controller.receive(name.rawValue as String)
}

/// Host-free wrapper that changes the size-class environment around one
/// retained production ContentView instance. XCUITest still selects routes
/// through the real sidebar and compact controls; a Darwin test signal stands
/// in for an iPad window resize that XCTest cannot drive deterministically.
struct CompactNavigationTransitionHarnessView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var widthController: CompactNavigationHarnessWidthController
    @StateObject private var fixtureSSHSession: SSHSession
    private let fixtureSession: LiveSession
    private let startsWithSession: Bool

    init() {
        let startsCompact = ProcessInfo.processInfo.environment[
            "TESSERA_COMPACT_NAVIGATION_INITIAL_SIZE"
        ] == "compact"
        _widthController = StateObject(
            wrappedValue: CompactNavigationHarnessWidthController(
                startsCompact: startsCompact
            )
        )
        startsWithSession = ProcessInfo.processInfo.environment[
            "TESSERA_COMPACT_NAVIGATION_INITIAL_ROUTE"
        ] == "session"

        let host = Host(
            name: "navigation fixture session",
            address: "192.0.2.20",
            port: 22,
            user: "fixture"
        )
        let sshSession = SSHSession(host: host)
        _fixtureSSHSession = StateObject(wrappedValue: sshSession)
        fixtureSession = LiveSession(
            session: .ssh(sshSession),
            hostName: host.name,
            hostKey: "ssh:fixture@192.0.2.20:22",
            launchMode: .customCommand
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(widthController.usesCompactWidth ? "compact" : "regular")
                    .accessibilityIdentifier("compact-navigation-harness-size")

                Text(String(fixtureSSHSession.compactNavigationHarnessSessionTaskStartCount))
                    .accessibilityIdentifier(
                        "compact-navigation-session-task-start-count"
                    )

                Text(String(fixtureSSHSession.compactNavigationHarnessConnectCallCount))
                    .accessibilityIdentifier("compact-navigation-connect-call-count")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ContentView(
                debugInitialSessions: [fixtureSession],
                debugInitialSelectedItem: startsWithSession
                    ? .session(fixtureSession.id)
                    : nil
            )
                .environment(
                    \.horizontalSizeClass,
                    widthController.usesCompactWidth ? .compact : .regular
                )
        }
        .task { seedFixtureHostIfNeeded() }
    }

    private func seedFixtureHostIfNeeded() {
        let fixtureID = UUID(uuidString: "C011CA7E-0000-4000-8000-000000000001")!
        let descriptor = FetchDescriptor<PersistedHost>(
            predicate: #Predicate { $0.id == fixtureID }
        )
        guard (try? modelContext.fetchCount(descriptor)) == 0 else { return }
        let fixture = PersistedHost(
            id: fixtureID,
            name: "navigation fixture host",
            address: "192.0.2.10"
        )
        fixture.user = "fixture"
        modelContext.insert(fixture)
        try? modelContext.save()
    }
}
#endif
