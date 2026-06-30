import SwiftUI
import SwiftData
import Combine

private struct RestoreStateEvent {
    let liveSessionID: UUID
    let persistedHostID: UUID?
    let transport: String
    let state: SessionState
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
    @Environment(AppLockController.self) private var appLockController
    @Environment(OnboardingController.self) private var onboarding
    @Environment(AppPhase.self) private var appPhase

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

    /// Switcher: shared observable mirror of `activeSessions` plus
    /// per-session last-touched timestamps. Read by the command
    /// palette via the environment.
    @State private var sessionRegistry = SessionRegistry()
    @State private var commandPalette = CommandPalette()

    private let sessionRestoreStore = SessionRestoreStore()

    private var sidebarVisible: Bool { columnVisibility != .detailOnly }

    var body: some View {
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
        .overlay {
            if commandPalette.isOpen {
                CommandPaletteView(palette: commandPalette) { id in
                    selectSession(id)
                }
                .transition(.opacity)
                .zIndex(50)
            }
        }
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
            logRestoreDiag(
                "active-sessions-changed count=\(activeSessions.count) sessions=\(activeSessionSummary())"
            )
            persistRestoreSnapshots()
        }
        .onChange(of: selectedItem) { _, newValue in
            if case .session(let id) = newValue {
                sessionRegistry.markTouched(id)
            }
            logRestoreDiag(
                "selected-changed selected=\(sidebarItemDescription(newValue)) active=\(appPhase.isActive)"
            )
            persistRestoreSnapshots()
        }
        .onChange(of: appLockController.isLocked) { _, isLocked in
            logRestoreDiag("app-lock-changed locked=\(isLocked)")
            if !isLocked {
                if !attemptForegroundRestoreIfNeeded(reason: "unlock") {
                    attemptStartupRestoreIfReady()
                }
            }
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
            logRestoreDiag(
                "app-phase-changed active=\(isActive) didEvaluateStartupRestore=\(didEvaluateStartupRestore) activeCount=\(activeSessions.count) inactivePreserved=\(hasInactivePreservedRestoreSnapshots)"
            )
            guard didEvaluateStartupRestore || !isActive else {
                logRestoreDiag("app-phase-skip reason=startup-restore-not-evaluated")
                return
            }
            if isActive,
               attemptForegroundRestoreIfNeeded(reason: "foreground") {
                return
            }
            persistRestoreSnapshots()
        }
        .onAppear {
            logRestoreDiag(
                "content-appear locked=\(appLockController.isLocked) active=\(appPhase.isActive) activeCount=\(activeSessions.count) didEvaluateStartupRestore=\(didEvaluateStartupRestore)"
            )
            sessionRegistry.syncActiveSessions(activeSessions)
            if case .session(let id) = selectedItem {
                sessionRegistry.markTouched(id)
            }
            attemptStartupRestoreIfReady()
            maybeBeginOnboarding()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(item: $hostKeyRequest) { request in
            HostKeyVerificationView(
                request: request,
                onTrust: {
                    request.continuation.resume(returning: true)
                    hostKeyRequest = nil
                },
                onReject: {
                    request.continuation.resume(returning: false)
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
        .onReceive(hostKeyVerificationPublisher) { request in
            // If a previous request is still pending (two sessions
            // connecting simultaneously), reject it so its continuation
            // doesn't leak. Only one prompt at a time.
            if let previous = hostKeyRequest {
                previous.continuation.resume(returning: false)
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
            persistRestoreSnapshots()
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
                        onOpenSettings: openSettings
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
                        onOpenSettings: openSettings
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
                                onConnect: { persistedHost, password in
                                    connect(to: persistedHost, password: password)
                                },
                                onCancel: { dismissEditor(host: host, deleteIfDraft: true) },
                                onDelete: { dismissEditor(host: host, deleteIfDraft: false, force: true) }
                            )
                        } else {
                            landing
                        }
                    case .keys:
                        KeysPageView()
                    case .knownHosts:
                        KnownHostsPageView()
                    case .tunnels:
                        TunnelsPageView { persistedHost in
                            selectedItem = .host(persistedHost.id)
                        }
                    case .settings:
                        SettingsPageView()
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
                continue
            }

            let sourceIDs = resolved.sourceSnapshotIDs.map(shortID).joined(separator: ",")
            logRestoreDiag(
                "restore-session-opened live=\(shortID(live.id)) snapshot=\(shortID(resolved.snapshot.liveSessionID)) host=\(shortID(live.persistedHostID)) sources=\(sourceIDs) preserveIDs=\(preserveSnapshotLiveIDs)"
            )
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

    private func connect(to persistedHost: PersistedHost, password: String = "") {
        _ = connectSavedHost(persistedHost, password: password, select: true)
    }

    @discardableResult
    private func connectSavedHost(
        _ persistedHost: PersistedHost,
        password: String = "",
        liveSessionID: UUID = UUID(),
        createdAt: Date = Date(),
        select: Bool
    ) -> LiveSession? {
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

        let hostDTO = Host(from: persistedHost, transientPassword: password)
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
        return appearance.requireBiometricForKeyUse
            || (key?.requiresBiometric ?? false)
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
            lastTouched: sessionRegistry.lastTouched
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

#Preview {
    ContentView()
        // Build through the shared factory so even the preview container goes
        // through the migration plan — every container in the repo now has a
        // single source of truth for schema + plan.
        .modelContainer(try! TesseraModelContainer.make(inMemory: true))
}
