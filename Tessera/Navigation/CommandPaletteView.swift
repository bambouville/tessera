import SwiftUI
import UIKit
import TmuxControl

/// Quick-switch palette overlay. Top-anchored modal with a search
/// input + active-sessions list. Arrow keys + Enter + Esc.
///
/// Renders only when `palette.isOpen` — the caller is expected to
/// mount this in a `.overlay` and gate visibility on that flag.
struct CommandPaletteView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Bindable var palette: CommandPalette

    /// Called with the chosen session or agent when the user commits. The
    /// caller is responsible for actually switching to it (the palette
    /// is intentionally agnostic about the navigation model so it
    /// stays testable without SwiftUI bindings).
    let onCommit: (CommandPaletteCommit) -> Void
    let onTmuxClose: (CommandPaletteTmuxClose) -> Void
    let onTmuxMutation: (CommandPaletteTmuxMutation) -> Void

    init(
        palette: CommandPalette,
        onTmuxClose: @escaping (CommandPaletteTmuxClose) -> Void = { _ in },
        onTmuxMutation: @escaping (CommandPaletteTmuxMutation) -> Void = { _ in },
        onCommit: @escaping (CommandPaletteCommit) -> Void
    ) {
        self.palette = palette
        self.onTmuxClose = onTmuxClose
        self.onTmuxMutation = onTmuxMutation
        self.onCommit = onCommit
    }

    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ProgramStatusCenter.self) private var programStatusCenter
    @Environment(AgentCenterV2Coordinator.self) private var agentCenterV2
    @FocusState private var queryFocused: Bool
    @State private var pendingRename: CommandPaletteTmuxWindow?
    @State private var renameText = ""
    @State private var windowDrag = TmuxWindowDragState()
    private var draggingWindowID: WindowId? { windowDrag.isDragging ? windowDrag.id : nil }
    @State private var windowRowFrames: [WindowId: CGRect] = [:]
    @State private var resultsViewportFrame: CGRect = .zero
    @State private var edgeScrollDirection = 0
    @State private var edgeScrollTarget: WindowId?
    @State private var edgeScrollTask: Task<Void, Never>?
    @State private var pendingDropRevealWindowID: WindowId?
    @State private var dropRevealWindowID: WindowId?
    @State private var dropRevealToken = 0

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    var body: some View {
        ZStack(alignment: .top) {
            scrim
            paletteCard
                .padding(.top, isPhone ? 54 : 72)
                .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea()
        .onAppear {
            // First-show focus. The focus-token onChange below can't
            // fire on initial mount (no prior value to compare), so this
            // covers the common "⌘K from a cold palette" case. Mirrors
            // FindBar's onAppear focus.
            queryFocused = true
        }
        .onChange(of: palette.focusRequestToken) { _, _ in
            // Re-focus on every open() call so re-pressing ⌘K when the
            // palette is already visible puts the cursor back in the
            // input.
            queryFocused = true
        }
        .onChange(of: palette.query) { _, _ in
            cancelPaletteReorder()
            palette.didChangeQuery()
        }
        .onChange(of: palette.tmuxSnapshotGeneration) { _, _ in
            // `refreshSnapshot` has already installed controller truth. Clear
            // gesture state without writing the stale pre-drag baseline back
            // over an external reorder, rollback, or authoritative refresh.
            cancelPaletteReorder(restoringPreview: false)
            guard let windowID = pendingDropRevealWindowID,
                  palette.tmuxWindows.contains(where: { $0.id == windowID })
            else { return }
            pendingDropRevealWindowID = nil
            dropRevealWindowID = windowID
            if let index = palette.entries.firstIndex(where: {
                $0.id == CommandPaletteEntry.ID.window(windowID)
            }) {
                palette.selectedIndex = index
            }
            dropRevealToken &+= 1
        }
        // Arrow / Enter handled at the container level (not on the
        // TextField) and via the `keys:phases:` form — the same pattern
        // FindBar uses. A focused UITextField otherwise swallows these
        // for cursor movement / native submit, surrendering first
        // responder back to the terminal. Returning `.handled` keeps
        // focus in the palette.
        .onKeyPress(keys: [.upArrow, .downArrow, .return], phases: .down) { keyPress in
            switch keyPress.key {
            case .upArrow:
                palette.selectPrevious()
                return .handled
            case .downArrow:
                palette.selectNext()
                return .handled
            case .return:
                commitCurrent()
                return .handled
            default:
                return .ignored
            }
        }
        .onKeyPress(.escape) {
            palette.close()
            return .handled
        }
        .alert(
            "Rename tmux window",
            isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } }
            )
        ) {
            TextField("Window name", text: $renameText)
                .literalTextInput()
            Button("Cancel", role: .cancel) {
                pendingRename = nil
            }
            Button("Rename") {
                submitRename()
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The name is shared with every client attached to this tmux session.")
        }
    }

    private var scrim: some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { palette.close() }
    }

    private var paletteCard: some View {
        VStack(spacing: 0) {
            inputRow
            Divider().background(T.border)
            if let notice = palette.visibleNotice {
                integrationNotice(notice)
                Divider().background(T.border)
            }
            if let rawError = palette.tmuxWindowOrderError, !rawError.isEmpty {
                let error = NSLocalizedString(rawError, comment: "tmux window ordering failure")
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(verbatim: error)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                .foregroundStyle(T.red)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(T.red.opacity(0.07))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Window order failed: \(error)")
                .accessibilityIdentifier("command-palette-window-order-error")
                Divider().background(T.border)
            }
            resultsList
            Divider().background(T.border)
            footer
        }
        .frame(maxWidth: 560)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(T.borderStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.6), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 24)
    }

    private func integrationNotice(_ notice: CommandPaletteNotice) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(T.amber)

                Text(notice.title)
                    .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(2)

                Spacer(minLength: 8)

                if let actionLabel = notice.actionLabel {
                    Button(actionLabel) {
                        palette.performNoticeAction()
                    }
                    .font(Typography.tesseraMono(size: 10.5, weight: .semibold))
                    .foregroundStyle(T.amber)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(T.amber.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(T.amber.opacity(0.34), lineWidth: 1)
                    )
                    .accessibilityIdentifier("agent-integration-warning-switcher-action")
                }
            }

            // The phone has no warning popover: the notice carries the
            // whole explanation, so it is never cut mid-sentence.
            Text(notice.message)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(T.amber.opacity(0.05))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-integration-warning-switcher-row")
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(T.fgMuted)

            TextField(
                isPhone
                    ? "switch session, window or agent"
                    : "switch session",
                text: $palette.query
            )
            .textFieldStyle(.plain)
            .font(Typography.tesseraMono(size: 14))
            .foregroundStyle(T.fg)
            .literalTextInput()
            .focused($queryFocused)
            .submitLabel(.go)
            // Enter / arrows / esc are handled at the container level
            // (see body) via the `keys:phases:` form so the TextField
            // doesn't swallow them or surrender first responder.

            if !isPhone {
                Text(verbatim: "esc")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(T.border, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultsList: some View {
        let rows = palette.entries
        if rows.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if !palette.homeResults.isEmpty {
                            ForEach(Array(palette.homeResults.enumerated()), id: \.element.id) { offset, entry in
                                Button {
                                    palette.selectedIndex = offset
                                    commitCurrent()
                                } label: {
                                    row(for: entry, isSelected: offset == palette.selectedIndex)
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                            }
                        }
                        if !palette.tmuxResults.isEmpty {
                            sectionHeader(resolved: tmuxSectionTitle)
                        }
                        ForEach(Array(palette.tmuxResults.enumerated()), id: \.element.id) { offset, entry in
                            let index = palette.homeResults.count + offset
                            Button {
                                palette.selectedIndex = index
                                commitCurrent()
                            } label: {
                                tmuxRow(for: entry, isSelected: index == palette.selectedIndex)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                tmuxAccessibilityLabel(
                                    for: entry,
                                    position: offset + 1,
                                    total: palette.tmuxResults.count
                                )
                            )
                            .id(entry.id)
                            .background {
                                if case .window(let window) = entry {
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: TmuxPaletteWindowFramesKey.self,
                                            value: [window.id: geo.frame(in: .global)]
                                        )
                                    }
                                }
                            }
                            .contextMenu {
                                tmuxMenu(for: entry)
                            }
                        }
                        if !palette.results.isEmpty {
                            sectionHeader("sessions")
                        }
                        ForEach(Array(palette.results.enumerated()), id: \.element.id) { index, live in
                            let unifiedIndex = palette.homeResults.count
                                + palette.tmuxResults.count
                                + index
                            Button {
                                palette.selectedIndex = unifiedIndex
                                commitCurrent()
                            } label: {
                                sessionRow(for: live, isSelected: unifiedIndex == palette.selectedIndex)
                            }
                            .buttonStyle(.plain)
                            .id(CommandPaletteEntry.ID.session(live.id))
                        }
                    }
                }
                .accessibilityIdentifier("command-palette-results")
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TmuxPaletteViewportFrameKey.self,
                            value: geo.frame(in: .global)
                        )
                    }
                }
                .frame(maxHeight: 360)
                .onPreferenceChange(TmuxPaletteWindowFramesKey.self) { frames in
                    windowRowFrames = frames
                }
                .onPreferenceChange(TmuxPaletteViewportFrameKey.self) { frame in
                    resultsViewportFrame = frame
                }
                .onChange(of: edgeScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(
                            CommandPaletteEntry.ID.window(target),
                            anchor: edgeScrollDirection < 0 ? .top : .bottom
                        )
                    }
                }
                .onChange(of: dropRevealToken) { _, _ in
                    guard let target = dropRevealWindowID else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(CommandPaletteEntry.ID.window(target), anchor: .center)
                    }
                }
                .onChange(of: palette.selectedIndex) { _, newIndex in
                    guard newIndex >= 0, newIndex < rows.count else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(rows[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        sectionHeader(Text(title))
    }

    /// The tmux section names the attached session, so its title arrives
    /// already resolved.
    private func sectionHeader(resolved title: String) -> some View {
        sectionHeader(Text(verbatim: title))
    }

    private func sectionHeader(_ title: Text) -> some View {
        title
            .font(Typography.kicker)
            .foregroundStyle(T.fgDim)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(palette.sessions.isEmpty
                 && palette.tmuxWindows.isEmpty && !palette.includesHome
                 ? "no active sessions"
                 : "no matches")
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fgMuted)
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
    }

    @ViewBuilder
    private func row(for entry: CommandPaletteEntry, isSelected: Bool) -> some View {
        switch entry {
        case .home:
            homeRow(isSelected: isSelected)
        case .pane(let window, let pane):
            paneRow(window: window, pane: pane, isSelected: isSelected)
        case .session(let live):
            sessionRow(for: live, isSelected: isSelected)
        case .window(let window):
            windowRow(window, isSelected: isSelected)
        }
    }

    @ViewBuilder
    private func tmuxRow(for entry: CommandPaletteEntry, isSelected: Bool) -> some View {
        switch entry {
        case .pane(let window, let pane):
            paneRow(window: window, pane: pane, isSelected: isSelected)
                .accessibilityIdentifier("tmux-pane-\(pane.id.description)")
        case .window(let window):
            windowRow(window, isSelected: isSelected)
                .accessibilityIdentifier("tmux-window-\(window.id.description)")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func tmuxMenu(for entry: CommandPaletteEntry) -> some View {
        switch entry {
        case .pane(let window, let pane):
            tmuxPaneMenu(window: window, pane: pane)
        case .window(let window):
            tmuxWindowMenu(window)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func tmuxWindowMenu(_ window: CommandPaletteTmuxWindow) -> some View {
        Button("Switch to", systemImage: "arrow.right") {
            guard let sessionID = palette.currentSessionID else { return }
            palette.close()
            onCommit(.window(sessionID: sessionID, windowID: window.id))
        }
        Button("Rename", systemImage: "pencil") {
            renameText = window.renameSeed
            pendingRename = window
        }
        .disabled(!palette.allowsTmuxMutation)
        Divider()
        Button("Move Up", systemImage: "arrow.up") {
            moveWindow(window, intent: .previous)
        }
        .disabled(!canMove(window, offset: -1))
        Button("Move Down", systemImage: "arrow.down") {
            moveWindow(window, intent: .next)
        }
        .disabled(!canMove(window, offset: 1))
        Button("Move to Start", systemImage: "arrow.up.to.line") {
            moveWindow(window, intent: .start)
        }
        .disabled(!canMove(window, to: 0))
        Button("Move to End", systemImage: "arrow.down.to.line") {
            moveWindow(window, intent: .end)
        }
        .disabled(!canMove(window, to: palette.tmuxWindows.count - 1))
        Button("Tidy window numbers", systemImage: "number") {
            requestRenumberWindows()
        }
        .disabled(!palette.canTidyTmuxWindows)
        if let pane = window.panes.first, window.panes.count == 1 {
            splitButtons(paneID: pane.id)
        }
        Button(role: .destructive) {
            guard let sessionID = palette.currentSessionID else { return }
            palette.close()
            onTmuxClose(.window(sessionID: sessionID, windowID: window.id))
        } label: {
            Label("Close window", systemImage: "xmark")
        }
        .disabled(!palette.allowsTmuxMutation)
    }

    @ViewBuilder
    private func tmuxPaneMenu(
        window: CommandPaletteTmuxWindow,
        pane: CommandPaletteTmuxPane
    ) -> some View {
        Button("Switch to", systemImage: "arrow.right") {
            guard let sessionID = palette.currentSessionID else { return }
            palette.close()
            onCommit(
                .pane(
                    sessionID: sessionID,
                    windowID: window.id,
                    paneID: pane.id
                )
            )
        }
        splitButtons(paneID: pane.id)
        Button(role: .destructive) {
            guard let sessionID = palette.currentSessionID else { return }
            palette.close()
            onTmuxClose(
                .pane(
                    sessionID: sessionID,
                    windowID: window.id,
                    paneID: pane.id
                )
            )
        } label: {
            Label("Close pane", systemImage: "xmark")
        }
        .disabled(!palette.allowsTmuxMutation)
    }

    @ViewBuilder
    private func splitButtons(paneID: PaneId) -> some View {
        Button("Split left / right", systemImage: "rectangle.split.2x1") {
            requestSplit(paneID: paneID, axis: .horizontal)
        }
        .disabled(!palette.allowsTmuxMutation)
        Button("Split top / bottom", systemImage: "rectangle.split.1x2") {
            requestSplit(paneID: paneID, axis: .vertical)
        }
        .disabled(!palette.allowsTmuxMutation)
    }

    private func requestSplit(paneID: PaneId, axis: PaneSplitAxis) {
        guard let sessionID = palette.currentSessionID else { return }
        palette.close()
        onTmuxMutation(.split(sessionID: sessionID, paneID: paneID, axis: axis))
    }

    private func submitRename() {
        guard let sessionID = palette.currentSessionID,
              let pendingRename
        else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        self.pendingRename = nil
        palette.close()
        onTmuxMutation(
            .rename(sessionID: sessionID, windowID: pendingRename.id, name: name)
        )
    }

    private var tmuxSectionTitle: String {
        guard let id = palette.currentSessionID,
              let session = palette.sessions.first(where: { $0.id == id })
        else { return "windows" }
        return "windows · \(session.hostName)"
    }

    private func tmuxAccessibilityLabel(
        for entry: CommandPaletteEntry,
        position: Int,
        total: Int
    ) -> String {
        // VoiceOver reads these, so the "current" marker is part of a whole
        // localized sentence rather than a suffix glued on afterwards —
        // appending a fragment strands it at the end regardless of where the
        // target language would place it.
        switch entry {
        case .window(let window):
            let isCurrent = palette.activeWindowID == window.id
            let windowPosition = currentPosition(of: window) + 1
            let indexDetail = window.tmuxIndex.flatMap { index in
                index == windowPosition ? nil : String(localized: ", tmux index \(index)")
            } ?? ""
            return isCurrent
                ? String(
                    localized: "tmux window \(windowPosition) of \(palette.tmuxWindows.count), \(window.title), \(window.panes.count) panes\(indexDetail), current",
                    comment: "VoiceOver label for the tmux window the session is on. Pluralized on the pane count."
                )
                : String(
                    localized: "tmux window \(windowPosition) of \(palette.tmuxWindows.count), \(window.title), \(window.panes.count) panes\(indexDetail)",
                    comment: "VoiceOver label for a tmux window row. Pluralized on the pane count."
                )
        case .pane(let window, let pane):
            let isCurrent = palette.activeWindowID == window.id
                && palette.activePaneID == pane.id
            return isCurrent
                ? String(
                    localized: "tmux pane \(position) of \(total), \(pane.title), window \(window.title), current",
                    comment: "VoiceOver label for the tmux pane the session is on"
                )
                : String(
                    localized: "tmux pane \(position) of \(total), \(pane.title), window \(window.title)",
                    comment: "VoiceOver label for a tmux pane row"
                )
        default:
            return String(
                localized: "tmux item \(position) of \(total)",
                comment: "VoiceOver fallback label for a tmux palette row"
            )
        }
    }

    private func homeRow(isSelected: Bool) -> some View {
        paletteNavigationRow(
            systemName: "house",
            title: String(localized: "hosts home"),
            subtitle: String(localized: "back to the tab bar · session keeps running"),
            indented: false,
            isCurrent: false,
            isSelected: isSelected
        )
    }

    private func windowRow(
        _ window: CommandPaletteTmuxWindow,
        isSelected: Bool
    ) -> some View {
        let isCurrent = palette.activeWindowID == window.id
        let status = palette.currentSessionID.flatMap { sessionID in
            programStatusCenter.windowStatus(sessionID: sessionID, windowID: window.id.rawValue, agentCenter: agentCenterV2)
        }
        let cue = palette.currentSessionID.map { sessionID in
            programStatusCenter.windowCue(sessionID: sessionID, windowID: window.id.rawValue, agentCenter: agentCenterV2)
        }
        let paneSummary: String
        if window.panes.count > 1 {
            // A reporting split names its program instead of the hint:
            // "2 panes · cargo working · 42%".
            paneSummary = status == nil
                ? String(localized: "\(window.panes.count) panes · each opens full-screen")
                : String(localized: "\(window.panes.count) panes", comment: "Switcher subtitle of a split tmux window that reports program status. Pluralized on the pane count.")
        } else if let pane = window.panes.first {
            paneSummary = pane.command ?? pane.title
        } else {
            paneSummary = String(localized: "tmux window")
        }
        let splitApp = window.panes.count > 1 ? status?.app : nil
        // The current window is being looked at: only input requests tint it,
        // like its tab.
        let unreadResult = !isCurrent && (cue?.tone == .failed || cue?.tone == .finished)
        return paletteNavigationRow(
            systemName: window.panes.count > 1 ? "rectangle.split.2x1" : "terminal",
            title: window.title,
            subtitle: windowSubtitle(window, paneSummary: paneSummary),
            status: status.map { status in
                (splitApp.map { "\($0) \(status.text)" } ?? status.text,
                 status.tone == .needsInput || !isCurrent ? status.tone : nil)
            },
            titleTone: unreadResult ? cue?.tone : nil,
            agentTone: cue?.hasAgent == true
                ? .some(cue?.tone == .needsInput || unreadResult ? cue?.tone : nil)
                : .none,
            indented: false,
            isCurrent: isCurrent,
            isSelected: isSelected,
            reorderWindow: window
        )
        .accessibilityActions {
            ForEach(TmuxWindowMoveIntent.allCases.filter {
                palette.canReorderTmuxWindows && $0.destination(in: palette.tmuxWindows.map(\.id), moving: window.id) != nil
            }, id: \.self) { intent in
                Button(paletteMoveTitle(intent)) { moveWindow(window, intent: intent) }
            }
        }
        .offset(y: paletteDragOffset(for: window.id))
        .scaleEffect(draggingWindowID == window.id ? 1.02 : 1)
        .shadow(
            color: draggingWindowID == window.id ? Color.black.opacity(0.3) : .clear,
            radius: draggingWindowID == window.id ? 7 : 0,
            y: draggingWindowID == window.id ? 3 : 0
        )
        .zIndex(draggingWindowID == window.id ? 10 : 0)
    }

    private func paneRow(
        window: CommandPaletteTmuxWindow,
        pane: CommandPaletteTmuxPane,
        isSelected: Bool
    ) -> some View {
        let isCurrent = palette.activeWindowID == window.id
            && palette.activePaneID == pane.id
        let status = palette.currentSessionID.flatMap { sessionID in
            programStatusCenter.paneStatus(sessionID: sessionID, paneID: pane.id.rawValue, agentCenter: agentCenterV2)
        }
        return paletteNavigationRow(
            systemName: nil,
            title: pane.title,
            subtitle: "\(pane.id.description) · \(pane.command ?? window.title)",
            status: status.map { ($0.text, $0.tone == .needsInput || !isCurrent ? $0.tone : nil) },
            indented: true,
            isCurrent: isCurrent,
            isSelected: isSelected
        )
    }

    /// Rows name live tmux windows and panes, so both strings arrive already
    /// resolved — the literal cases resolve at their call site.
    /// `status` joins the subtitle in its own tint (dim when nil);
    /// `agentTone` swaps the icon for the agent glyph, tinted like its tab.
    private func paletteNavigationRow(
        systemName: String?,
        title: String,
        subtitle: String,
        status: (text: String, tone: ChromeAttentionTone?)? = nil,
        titleTone: ChromeAttentionTone? = nil,
        agentTone: ChromeAttentionTone?? = nil,
        indented: Bool,
        isCurrent: Bool,
        isSelected: Bool,
        reorderWindow: CommandPaletteTmuxWindow? = nil
    ) -> some View {
        let fullSubtitle = status.map { "\(subtitle) · \($0.text)" } ?? subtitle
        return HStack(spacing: 12) {
            if indented {
                Text(verbatim: "↳")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgDim)
                    .frame(width: 14)
            } else if let agentTone {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(agentTone?.color(T) ?? T.fgMuted)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            } else if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(titleTone?.color(T) ?? T.fg)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: subtitle)
                        .foregroundStyle(T.fgDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let status {
                        Text(verbatim: "·").foregroundStyle(T.fgDim)
                        Text(verbatim: status.text)
                            .foregroundStyle(status.tone?.color(T) ?? T.fgDim)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .font(Typography.tesseraMono(size: 11))
            }

            Spacer(minLength: 0)
            if let reorderWindow, isPhone {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .overlay {
                        TmuxPaletteReorderSurface(
                            enabled: palette.canReorderTmuxWindows,
                            accessibilityIdentifier: "command-palette-window-\(reorderWindow.id.rawValue)-reorder",
                            onPhase: { phase in
                                handleReorderPhase(phase, window: reorderWindow)
                            }
                        )
                    }
            }
            Text(verbatim: isCurrent ? "●" : "↩")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(isCurrent ? T.green : T.accent)
        }
        .padding(.leading, indented ? 26 : 16)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? T.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        // Both halves are already localized where they are produced; this
        // only joins them, so it must not become a translatable key itself.
        .accessibilityLabel(Text(verbatim: "\(title), \(fullSubtitle)"))
        .accessibilityValue(isCurrent ? "current" : "")
        .accessibilityIdentifier(
            reorderWindow.map { "command-palette-window-\($0.id.rawValue)" } ?? ""
        )
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func currentPosition(of window: CommandPaletteTmuxWindow) -> Int {
        palette.tmuxWindows.firstIndex(where: { $0.id == window.id }) ?? window.position
    }

    private func windowSubtitle(_ window: CommandPaletteTmuxWindow, paneSummary: String) -> String {
        let position = currentPosition(of: window) + 1
        guard let index = window.tmuxIndex, index != position else { return paneSummary }
        return "\(paneSummary) · tmux index \(index)"
    }

    private func canMove(_ window: CommandPaletteTmuxWindow, offset: Int) -> Bool {
        canMove(window, to: currentPosition(of: window) + offset)
    }

    private func canMove(_ window: CommandPaletteTmuxWindow, to destination: Int) -> Bool {
        palette.canReorderTmuxWindows
            && destination >= 0
            && destination < palette.tmuxWindows.count
            && destination != currentPosition(of: window)
    }

    private func paletteMoveTitle(_ intent: TmuxWindowMoveIntent) -> String {
        switch intent {
        case .previous: String(localized: "Move Up")
        case .next: String(localized: "Move Down")
        case .start: String(localized: "Move to Start")
        case .end: String(localized: "Move to End")
        }
    }

    private func moveWindow(_ window: CommandPaletteTmuxWindow, intent: TmuxWindowMoveIntent) {
        guard palette.canReorderTmuxWindows,
              intent.destination(in: palette.tmuxWindows.map(\.id), moving: window.id) != nil,
              let sessionID = palette.currentSessionID else { return }
        pendingDropRevealWindowID = window.id
        onTmuxMutation(.moveWindow(sessionID: sessionID, windowID: window.id, move: .relative(intent)))
    }

    private func requestRenumberWindows() {
        guard palette.canTidyTmuxWindows, let sessionID = palette.currentSessionID else { return }
        onTmuxMutation(.renumberWindows(sessionID: sessionID))
    }

    private func handleReorderPhase(_ phase: TmuxPaletteReorderPhase, window: CommandPaletteTmuxWindow) {
        switch phase {
        case .began(let location):
            windowDrag.begin(id: window.id, order: palette.tmuxWindows.map(\.id), pointer: location.y,
                             frameStart: Double(windowRowFrames[window.id]?.minY ?? location.y), enabled: palette.canReorderTmuxWindows)
        case .changed(let location):
            if windowDrag.update(pointer: location.y, midpoints: windowRowFrames.mapValues { $0.midY }, enabled: palette.canReorderTmuxWindows) {
                if let preview = windowDrag.previewOrder { palette.restoreWindowOrder(preview) }
                UISelectionFeedbackGenerator().selectionChanged()
            }
            if windowDrag.isDragging { updatePaletteEdgeAutoScroll(pointerY: location.y) }
        case .ended(let cancelled):
            let baseline = windowDrag.baseline
            let destination = windowDrag.finish(cancelled: cancelled || !palette.canReorderTmuxWindows)
            stopPaletteEdgeAutoScroll()
            palette.restoreWindowOrder(baseline)
            if let destination, let sessionID = palette.currentSessionID {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                pendingDropRevealWindowID = window.id
                onTmuxMutation(.moveWindow(sessionID: sessionID, windowID: window.id, move: .position(destination)))
            }
        }
    }

    private func cancelPaletteReorder(restoringPreview: Bool = true) {
        if restoringPreview { palette.restoreWindowOrder(windowDrag.baseline) }
        windowDrag.cancel()
        stopPaletteEdgeAutoScroll()
    }

    private func paletteDragOffset(for id: WindowId) -> CGFloat {
        guard windowDrag.id == id, let frame = windowRowFrames[id] else { return 0 }
        return windowDrag.offset(currentFrameStart: frame.minY)
    }

    private func updatePaletteEdgeAutoScroll(pointerY: CGFloat) {
        guard !resultsViewportFrame.isEmpty else { return }
        let inset: CGFloat = 34
        let direction = pointerY < resultsViewportFrame.minY + inset
            ? -1
            : (pointerY > resultsViewportFrame.maxY - inset ? 1 : 0)
        guard direction != edgeScrollDirection else { return }
        stopPaletteEdgeAutoScroll()
        edgeScrollDirection = direction
        guard direction != 0 else { return }
        edgeScrollTask = Task { @MainActor in
            while !Task.isCancelled, draggingWindowID != nil {
                let ordered = palette.tmuxWindows.map(\.id)
                let visible = ordered.filter { id in
                    guard let frame = windowRowFrames[id] else { return false }
                    return frame.maxY >= resultsViewportFrame.minY
                        && frame.minY <= resultsViewportFrame.maxY
                }
                let edgeID = direction < 0 ? visible.first : visible.last
                guard let edgeID, let edgeIndex = ordered.firstIndex(of: edgeID) else { break }
                let nextIndex = edgeIndex + direction
                guard ordered.indices.contains(nextIndex) else { break }
                edgeScrollTarget = ordered[nextIndex]
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func stopPaletteEdgeAutoScroll() {
        edgeScrollTask?.cancel()
        edgeScrollTask = nil
        edgeScrollDirection = 0
        edgeScrollTarget = nil
    }

    private func sessionRow(for live: LiveSession, isSelected: Bool) -> some View {
        let title = live.displayLabel(in: palette.sessions)
        let pane = palette.paneTitles[live.id]
        let subtitle = subtitleString(for: live, paneTitle: pane)
        let counts = programStatusCenter.sessionCounts(sessionID: live.id, agentCenter: agentCenterV2)
        let statusSummary = ProgramStatusWords.countSummary(counts, specificKinds: true)

        return HStack(spacing: 12) {
            Circle()
                .fill(T.green)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
                // Working-only sessions get no line; in raw SSH this is the
                // switcher's only status surface.
                if counts.total > 0 {
                    ProgramStatusWords.countText(counts, specificKinds: true, T: T)
                        .font(Typography.tesseraMono(size: 11))
                        .lineLimit(1)
                        .accessibilityIdentifier("command-palette-session-status")
                }
            }

            Spacer(minLength: 0)

            if isSelected {
                Text(verbatim: "↩")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(T.accentSoft, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? T.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(counts.total > 0
            ? Text("session \(title), \(subtitle), \(statusSummary)")
            : Text("session \(title), \(subtitle)"))
    }

    private var commitGlyph: some View {
        Text(verbatim: "↩")
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(T.accentSoft, lineWidth: 1)
            )
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if !isPhone {
                footerHint(symbol: "↑↓", label: "navigate")
                footerHint(symbol: KeyToken.return.rendered(appearance.modifierNotation), label: "switch")
                footerHint(symbol: KeyToken.escape.rendered(appearance.modifierNotation), label: "dismiss")
            }
            Spacer(minLength: 0)
            if palette.isTmuxWindowMutationPending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating tmux window order")
                    .accessibilityIdentifier("command-palette-window-order-pending")
            }
            Text("\(palette.tmuxWindows.count) windows · \(palette.sessions.count) sessions")
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func footerHint(symbol: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: symbol)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgMuted)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(T.inputBgSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(T.border, lineWidth: 1)
                )
            Text(label)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
        }
    }

    private func subtitleString(for live: LiveSession, paneTitle: String?) -> String {
        var parts: [String] = [live.hostKey]
        if let paneTitle, !paneTitle.isEmpty {
            parts.append(paneTitle)
        }
        return parts.joined(separator: " · ")
    }

    private func commitCurrent() {
        if let result = palette.commitResult() {
            palette.close()
            onCommit(result)
        } else {
            palette.close()
        }
    }
}

private enum TmuxPaletteReorderPhase {
    case began(window: CGPoint)
    case changed(window: CGPoint)
    case ended(cancelled: Bool)
}

/// Native long-press arbitration mirrors `DraggableChipBar`: a quick pan is
/// left to the enclosing scroll view, while a held touch owns the reorder.
private struct TmuxPaletteReorderSurface: UIViewRepresentable {
    let enabled: Bool
    let accessibilityIdentifier: String
    let onPhase: (TmuxPaletteReorderPhase) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(surface: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .allowsDirectInteraction
        view.accessibilityLabel = "Reorder tmux window"
        view.accessibilityIdentifier = accessibilityIdentifier
        let press = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        press.minimumPressDuration = 0.28
        press.allowableMovement = 10
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
        view.isUserInteractionEnabled = enabled
        view.accessibilityIdentifier = accessibilityIdentifier
    }

    final class Coordinator: NSObject {
        var surface: TmuxPaletteReorderSurface
        init(surface: TmuxPaletteReorderSurface) { self.surface = surface }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view?.window)
            switch recognizer.state {
            case .began: surface.onPhase(.began(window: location))
            case .changed: surface.onPhase(.changed(window: location))
            case .ended: surface.onPhase(.ended(cancelled: false))
            case .cancelled, .failed: surface.onPhase(.ended(cancelled: true))
            default: break
            }
        }
    }
}

private struct TmuxPaletteWindowFramesKey: PreferenceKey {
    static let defaultValue: [WindowId: CGRect] = [:]
    static func reduce(value: inout [WindowId: CGRect], nextValue: () -> [WindowId: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TmuxPaletteViewportFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
