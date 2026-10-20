import SwiftUI
import TesseraCore
import TmuxControl
import TmuxControlCore

/// The session top bar's attention-chip list: agents and other programs that
/// need input, failed or finished away from the user's view. Each row offers
/// its own pane; an agent's row itself opens its thread in Agent Center, a
/// program's opens its pane. Opening the list acknowledges nothing; visiting
/// the pane does, so the unread model stays honest.
///
/// iPad-width bar only. The compact phone bar has no attention chip; there the
/// switcher's status words and the Sessions badge cover the same jump.
struct AgentAttentionPopover: View {
    /// A tmux window as the top bar's own strip shows it: 1-based position
    /// (the ⌘N number) and name.
    struct WindowLabel: Equatable {
        let position: Int
        let name: String
    }

    /// An agent's merged state: Agent Center's verdict combined with the
    /// status the agent reports itself, plus its reported message.
    struct AgentStatus: Equatable {
        let attention: ProgramStatusAttention
        let message: String?
    }

    private enum Row: Identifiable {
        case agent(AgentAttentionEntry, AgentStatus)
        case program(ProgramAttentionItem)

        var id: String {
            switch self {
            case .agent(let entry, _): "agent|\(entry.threadID)"
            case .program(let item): "program|\(item.id)"
            }
        }

        var attention: ProgramStatusAttention {
            switch self {
            case .agent(_, let status): status.attention
            case .program(let item): item.attention
            }
        }
    }

    let entries: [AgentAttentionEntry]
    let programItems: [ProgramAttentionItem]
    let T: DesignTokens
    /// Resolves a binding's window for the session this bar belongs to. Other
    /// sessions fall back to tmux's window id, as the legacy list did.
    let windowLabel: (AgentTerminalBinding) -> WindowLabel?
    /// Merges an agent's own report into its row; nil hides a stale row (the
    /// agent reports working again since Agent Center saw it finish).
    let agentStatus: (AgentAttentionEntry) -> AgentStatus?
    let onOpenPane: (AgentAttentionEntry) -> Void
    let onReview: (AgentAttentionEntry) -> Void
    let onOpenProgram: (ProgramAttentionItem) -> Void
    let onOpenAgentCenter: (() -> Void)?

    init(
        entries: [AgentAttentionEntry],
        programItems: [ProgramAttentionItem] = [],
        T: DesignTokens,
        windowLabel: @escaping (AgentTerminalBinding) -> WindowLabel?,
        agentStatus: @escaping (AgentAttentionEntry) -> AgentStatus? = { entry in
            AgentStatus(attention: entry.kind == .needsInput ? .needsInput(nil) : .finished, message: nil)
        },
        onOpenPane: @escaping (AgentAttentionEntry) -> Void,
        onReview: @escaping (AgentAttentionEntry) -> Void,
        onOpenProgram: @escaping (ProgramAttentionItem) -> Void = { _ in },
        onOpenAgentCenter: (() -> Void)?
    ) {
        self.entries = entries
        self.programItems = programItems
        self.T = T
        self.windowLabel = windowLabel
        self.agentStatus = agentStatus
        self.onOpenPane = onOpenPane
        self.onReview = onReview
        self.onOpenProgram = onOpenProgram
        self.onOpenAgentCenter = onOpenAgentCenter
    }

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 64
    private static let rowSpacing: CGFloat = 6
    /// Beyond this many rows the list scrolls, so a busy fleet cannot grow the
    /// popover past a landscape iPad's usable height.
    private static let unscrolledRowLimit = 4

    /// Needs input, then failed, then finished; agents before programs of
    /// the same state, each in its source's order.
    private var allRows: [Row] {
        let agents = entries.compactMap { entry in agentStatus(entry).map { Row.agent(entry, $0) } }
        let rows = agents + programItems.map(Row.program)
        return rows.enumerated().sorted { lhs, rhs in
            let l = lhs.element.attention.tone, r = rhs.element.attention.tone
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    var body: some View {
        let rows = allRows
        VStack(alignment: .leading, spacing: 0) {
            Text("needs attention", comment: "Attention list title, for agents and other programs alike.")
                .font(Typography.tesseraMono(size: 13, weight: .semibold))
                .foregroundStyle(T.fg)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("agent-attention-popover")
                .padding(.bottom, 4)

            Text("visiting a pane marks it checked", comment: "Attention list caption: how a finished or failed row goes away.")
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
                .padding(.bottom, 12)

            if rows.isEmpty {
                Text("all caught up")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .frame(minHeight: 44)
            } else if rows.count > Self.unscrolledRowLimit {
                // Popovers collapse greedy ScrollViews to zero, so the
                // scrolling list is sized explicitly.
                ScrollView { rowStack(rows) }
                    .frame(height: (rowHeight + Self.rowSpacing) * (CGFloat(Self.unscrolledRowLimit) + 0.5))
            } else {
                rowStack(rows)
            }

            if let onOpenAgentCenter {
                Rectangle()
                    .fill(T.border)
                    .frame(height: 0.5)
                    .padding(.top, 10)
                Button(action: onOpenAgentCenter) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                        Text("open agent center")
                            .font(Typography.tesseraMono(size: 11, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(T.fgMuted)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-attention-open-agent-center")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, onOpenAgentCenter == nil ? 14 : 4)
        .frame(width: 380, alignment: .leading)
        .presentationBackground(T.bg.opacity(0.94))
        .presentationCornerRadius(13)
    }

    private func rowStack(_ rows: [Row]) -> some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                switch row {
                case .agent(let entry, let status): agentRow(entry, status: status, index: index)
                case .program(let item): programRow(item, index: index)
                }
            }
        }
    }

    private func icon(_ attention: ProgramStatusAttention) -> String {
        switch attention {
        case .needsInput: "person.crop.circle.badge.exclamationmark"
        case .failed: "xmark.circle"
        case .finished: "checkmark.circle"
        }
    }

    /// The shared row body: icon, title (with the agent glyph), state line,
    /// optional message and location.
    private func rowLabel(
        title: String,
        isAgent: Bool,
        source: String?,
        attention: ProgramStatusAttention,
        message: String?,
        location: String
    ) -> some View {
        let tint = attention.tone.color(T)
        return HStack(spacing: 10) {
            Image(systemName: icon(attention))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(T.fgMuted)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isAgent {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: title)
                        .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                        .foregroundStyle(T.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    if let source, !source.isEmpty {
                        Text(verbatim: source)
                            .foregroundStyle(T.fgMuted)
                    }
                    Text(verbatim: ProgramStatusWords.attention(attention))
                        .foregroundStyle(tint)
                }
                .font(Typography.tesseraMono(size: 10, weight: .medium))
                .lineLimit(1)
                if let message, !message.isEmpty {
                    // Reported prose reads in the system face, like transcripts.
                    Text(verbatim: message)
                        .font(.system(size: 11))
                        .foregroundStyle(T.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Two lines: a named window plus its pane rarely fit
                // beside the open-pane pill, and longer locales less so.
                Text(verbatim: location)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func openPaneButton(label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("open pane", systemImage: "terminal")
                .font(Typography.tesseraMono(size: 10, weight: .medium))
                .foregroundStyle(T.accent)
                .padding(.horizontal, 9)
                .frame(minHeight: 30)
                .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                // Visual pill stays compact; the hit frame is full pitch.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func rowChrome(_ content: some View) -> some View {
        content
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(minHeight: rowHeight)
            .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.border, lineWidth: 0.5))
    }

    private func agentRow(_ entry: AgentAttentionEntry, status: AgentStatus, index: Int) -> some View {
        let location = locationText(entry)
        return rowChrome(HStack(spacing: 8) {
            Button { onReview(entry) } label: {
                rowLabel(
                    title: entry.title,
                    isAgent: true,
                    source: entry.providerName,
                    attention: status.attention,
                    message: status.message,
                    location: location
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                localized: "\(entry.title), agent \(entry.providerName), \(ProgramStatusWords.attention(status.attention)), \(location)",
                comment: "Attention list row for VoiceOver. Arguments: agent title, provider name, state words, location."
            ))
            .accessibilityValue(Text(verbatim: status.message ?? ""))
            .accessibilityHint("Shows this agent in Agent Center")
            .accessibilityIdentifier("agent-attention-row-\(index)")

            if entry.terminalBinding != nil {
                openPaneButton(
                    label: String(
                        localized: "Open \(entry.title) on \(entry.hostDisplayLabel)",
                        comment: "Attention list: go to the terminal pane of an agent. Arguments: agent title, host name."
                    ),
                    identifier: "agent-attention-open-\(index)"
                ) { onOpenPane(entry) }
            } else {
                Text("pane unavailable")
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(T.fgFaint)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("agent-attention-unavailable-\(index)")
            }
        })
    }

    private func programRow(_ item: ProgramAttentionItem, index: Int) -> some View {
        let title = ProgramStatusWords.name(item.entry, windowName: item.location?.windowName)
        let location = programLocationText(item)
        let words = ProgramStatusWords.attention(item.attention)
        return rowChrome(HStack(spacing: 8) {
            Button { onOpenProgram(item) } label: {
                rowLabel(
                    title: title,
                    isAgent: item.hasAgent,
                    source: item.entry.title == nil ? nil : item.entry.app,
                    attention: item.attention,
                    message: item.entry.message,
                    location: location
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                localized: "\(title), \(words), \(location)",
                comment: "Attention list row for a program, for VoiceOver. Arguments: program name, state words, location."
            ))
            .accessibilityValue(Text(verbatim: item.entry.message ?? ""))
            .accessibilityHint("Opens this pane")
            .accessibilityIdentifier("program-attention-row-\(index)")

            openPaneButton(
                label: String(
                    localized: "Open \(title) on \(item.hostLabel)",
                    comment: "Attention list: go to the terminal pane of a program. Arguments: program name, host name."
                ),
                identifier: "program-attention-open-\(index)"
            ) { onOpenProgram(item) }
        })
    }

    /// `host · window 2 “claude” · pane %21`, or `host · raw session`.
    private func programLocationText(_ item: ProgramAttentionItem) -> String {
        let host = item.hostLabel
        guard let pane = item.terminal.paneNumber else {
            return String(
                localized: "\(host) · raw session",
                comment: "Agent location when the session is not running under tmux"
            )
        }
        var parts = host.isEmpty ? [] : [host]
        if let location = item.location {
            parts.append(location.windowName.isEmpty
                ? String(localized: "window \(location.windowPosition)", comment: "Agent location: tmux window number")
                : String(
                    localized: "window \(location.windowPosition) “\(location.windowName)”",
                    comment: "Agent location: tmux window number and its name"
                ))
        }
        let identifier = "%" + String(pane)
        parts.append(String(localized: "pane \(identifier)", comment: "Program or agent location: tmux pane identifier, including its percent prefix."))
        return parts.joined(separator: " · ")
    }

    /// `host · window 2 “claude” · pane %21`, or `host · raw session`. The
    /// window part uses the bar's own strip numbering when the agent is in
    /// this session.
    private func locationText(_ entry: AgentAttentionEntry) -> String {
        let host = entry.hostDisplayLabel
        guard let binding = entry.lastKnownBinding else { return host }
        guard binding.windowID != nil || binding.paneID != nil else {
            return String(
                localized: "\(host) · raw session",
                comment: "Agent location when the session is not running under tmux"
            )
        }
        var parts = host.isEmpty ? [] : [host]
        if let label = windowLabel(binding) {
            parts.append(label.name.isEmpty
                ? String(localized: "window \(label.position)", comment: "Agent location: tmux window number")
                : String(
                    localized: "window \(label.position) “\(label.name)”",
                    comment: "Agent location: tmux window number and its name"
                ))
        } else if let windowID = binding.windowID.flatMap(Int.init) {
            parts.append(String(localized: "window \(windowID)", comment: "Agent location: tmux window number"))
        }
        // `%21` is tmux's own pane identifier syntax, not prose.
        if let paneID = binding.paneID {
            let identifier = "%" + paneID
            parts.append(String(localized: "pane \(identifier)", comment: "Program or agent location: tmux pane identifier, including its percent prefix."))
        }
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
/// Host-free harness for the attention chip (`TESSERA_AGENT_ATTENTION_HARNESS=1`;
/// add `TESSERA_AGENT_ATTENTION_AUTO_OPEN=1` to open the list). It mounts the
/// production iPad top bar over a real V2 coordinator fed by in-memory session
/// sources: a finished agent in this session's tmux window 3, one in a second
/// live raw-mosh session, and one whose session has disconnected. No transport
/// is opened; "open pane" only records what it would focus.
struct AgentAttentionHarnessView: View {
    private static let sessionID = UUID(uuidString: "A77E0000-0000-4000-8000-0000000000A1")!
    private static let rawSessionID = UUID(uuidString: "A77E0000-0000-4000-8000-0000000000A2")!
    private static let droppedSessionID = UUID(uuidString: "A77E0000-0000-4000-8000-0000000000A3")!

    @State private var appearance: AppearancePreferences
    @State private var agentCenterV2: AgentCenterV2Coordinator
    @State private var programStatusCenter = ProgramStatusCenter()
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux: TmuxController
    @State private var commandSession = SessionTopBarHarnessSession()
    @State private var findController = FindController()
    @State private var ready = false
    @State private var result = "none"
    @Environment(BellController.self) private var bellController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init() {
        let appearance = AppearancePreferences()
        appearance.mode = .dark
        appearance.agentCenterEnabled = true
        _appearance = State(initialValue: appearance)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-attention-harness-\(UUID().uuidString)")
        _agentCenterV2 = State(initialValue: AgentCenterV2Coordinator(
            metadata: AppleAgentMetadataRepository(fileURL: directory.appendingPathComponent("metadata.json"))
        ))

        // @1 editor, @2 dashboard (%20/%21), @3 logs (%30 zoomed over %31),
        // hydrated through the controller's own command order.
        let controller = TmuxController(controlPath: .sideChannel)
        let server = TmuxHarnessServer(
            controller: controller,
            windows: [
                .init(
                    id: 1, name: "editor", layout: "595f,80x24,0,0,10",
                    panes: [
                        .init(id: 10, left: 0, top: 0, width: 80, height: 24, command: "zsh", title: "editor"),
                    ]
                ),
                .init(
                    id: 2, name: "dashboard", layout: "bb11,80x24,0,0{40x24,0,0,20,39x24,41,0,21}",
                    panes: [
                        .init(id: 20, left: 0, top: 0, width: 80, height: 24, command: "zsh", title: "dashboard-left"),
                        .init(id: 21, left: 0, top: 0, width: 80, height: 24, active: false, command: "zsh", title: "dashboard-right"),
                    ]
                ),
                .init(
                    id: 3, name: "logs", layout: "fb12,80x24,0,0{40x24,0,0,30,39x24,41,0,31}",
                    visibleLayout: "5960,80x24,0,0,30", zoomed: true,
                    panes: [
                        .init(id: 30, left: 0, top: 0, width: 80, height: 24, command: "zsh", title: "logs-top"),
                        .init(id: 31, left: 0, top: 0, width: 80, height: 24, active: false, command: "zsh", title: "logs-bottom"),
                    ]
                ),
            ],
            activeWindowID: 1,
            version: "3.5a"
        )
        server.attach()
        // `TESSERA_PROGRAM_STATUS_HARNESS=1`: programs report too, beside
        // the agent in %30. "deploy prod" is the title, base64 as on the wire.
        if ProcessInfo.processInfo.environment["TESSERA_PROGRAM_STATUS_HARNESS"] == "1" {
            ProgramStatusHarnessReports.ingest(into: controller, [
                (31, "state=blocked:kind=permission:app=deploy:title=ZGVwbG95IHByb2Q="),
                (20, "state=error:app=cargo"),
                (21, "state=done:app=pytest"),
                (10, "state=working:app=vim:progress=42"),
            ])
        }
        _tmux = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if ready {
                    SessionTopBar(
                        state: .connected,
                        host: Host(name: "mac mini", address: "mac-mini.local", autoTmux: true, launchMode: .autoTmux),
                        sessionID: Self.sessionID,
                        sessionIsActive: true,
                        tmux: tmux,
                        sessionCommands: commandSession.sessionCommands(tmux: tmux),
                        tmuxIsDegraded: false,
                        connectionStatus: .ssh(state: .connected),
                        onToggleSidebar: {},
                        sidebarVisible: false,
                        onBack: {},
                        onDisconnect: {},
                        findController: findController,
                        filesPanelOpen: false,
                        onToggleFiles: {},
                        bellController: bellController,
                        forwarderManager: nil,
                        T: DesignTokens.make(mode: .dark, accent: .blue),
                        onOpenAgentCenter: { result = "agent-center" }
                    )
                    .frame(height: SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: CompactLayout.isPhone(horizontalSizeClass)
                    ))
                }
                Text(verbatim: "attention harness · \(result)")
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.top, 28)
                    .accessibilityLabel(Text(verbatim: "Attention harness result"))
                    .accessibilityValue(result)
                    .accessibilityIdentifier("agent-attention-harness-result")
                Spacer()
            }
            // `TESSERA_AGENT_ATTENTION_AUTO_OPEN=palette`: the iPhone switcher.
            if palette.isOpen {
                CommandPaletteView(palette: palette) { _ in }
                    .zIndex(20)
            }
        }
        .environment(appearance)
        .environment(agentCenterV2)
        .environment(programStatusCenter)
        .environment(registry)
        .environment(palette)
        .statusBarHidden(true)
        .task { await populate() }
    }

    private func populate() async {
        let coordinator = agentCenterV2
        await coordinator.setExperimentEnabled(true)
        await coordinator.setApplicationActive(true)
        coordinator.onOpenExactTerminal = { binding in
            result = "pane session=\(binding.liveSessionID.uuidString.suffix(2)) window=\(binding.windowID ?? "raw") pane=\(binding.paneID ?? "raw")"
        }
        coordinator.onRevealThread = { _ in result = "review" }
        _ = Self.register(coordinator, sessionID: Self.sessionID, host: "mac mini", windowID: 3, paneID: 30)
        _ = Self.register(coordinator, sessionID: Self.rawSessionID, host: "linux box", windowID: nil, paneID: nil)
        let dropped = Self.register(coordinator, sessionID: Self.droppedSessionID, host: "windows", windowID: 1, paneID: 4)
        var attempts = 0
        while coordinator.attentionEntries().filter({ $0.terminalBinding != nil }).count < 3, attempts < 150 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(40))
        }
        coordinator.unregisterSessionSource(sessionID: Self.droppedSessionID, registrationID: dropped)
        programStatusCenter.publish(sessionID: Self.sessionID, hostLabel: "mac mini", tmux: tmux)
        ready = true
    }

    /// Registers one in-memory session whose only agent has just finished.
    private static func register(
        _ coordinator: AgentCenterV2Coordinator,
        sessionID: UUID,
        host: String,
        windowID: Int?,
        paneID: Int?
    ) -> UUID {
        let registrationID = UUID()
        let hostID = UUID()
        let event = AgentLifecycleEvent(
            version: 9, provider: "codex", event: "Stop", state: .idle, reason: "turn-stopped",
            timestampNanoseconds: 100, providerSessionID: "harness-\(host)", turnID: "turn",
            notificationType: "", permissionMode: "", agentPID: 42, transcriptRef: "c2Vzc2lvbg"
        )
        let location = AgentLocation(
            sessionID: sessionID, hostName: host, transportLabel: paneID == nil ? "mosh" : "ssh+tmux",
            tmuxSessionName: paneID == nil ? nil : "harness", windowID: windowID,
            windowName: nil, paneID: paneID
        )
        let target = AgentProbeTarget(
            location: location, processNames: ["codex"], processIDs: [42], visibleText: "completed",
            lifecycleEvent: paneID == nil ? nil : event, bracketedPasteEnabled: false
        )
        let source = AgentSessionSource(
            registrationID: registrationID, sessionID: sessionID,
            discover: { .success([target]) }, observe: { _ in nil },
            inspect: { _ in target }, automaticallyProbeLifecycleIntegration: false,
            send: { _, _ in false }, jump: { _ in }
        )
        coordinator.registerSessionSource(source, hostID: hostID, hostDisplayLabel: host, profiles: { [.builtInCodexCLI] })
        if paneID == nil {
            coordinator.scheduleSessionRefresh(sessionID: sessionID, lifecycle: event)
        }
        return registrationID
    }
}
#endif
