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
    @FocusState private var queryFocused: Bool
    @State private var pendingRename: CommandPaletteTmuxWindow?
    @State private var renameText = ""

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
            palette.didChangeQuery()
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

            Text(notice.message)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
                .lineLimit(3)
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
                    : "switch session or agent — @ scopes agents",
                text: $palette.query
            )
            .textFieldStyle(.plain)
            .font(Typography.tesseraMono(size: 14))
            .foregroundStyle(T.fg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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
                        if !palette.agentResults.isEmpty {
                            sectionHeader("agents")
                        }
                        ForEach(Array(palette.agentResults.enumerated()), id: \.element.id) { offset, agent in
                            let index = palette.homeResults.count
                                + palette.tmuxResults.count
                                + palette.results.count
                                + offset
                            Button {
                                palette.selectedIndex = index
                                commitCurrent()
                            } label: {
                                agentRow(for: agent, isSelected: index == palette.selectedIndex)
                            }
                            .buttonStyle(.plain)
                            .id(CommandPaletteEntry.ID.agent(agent.id))
                        }
                    }
                }
                .frame(maxHeight: 360)
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
            Text(palette.sessions.isEmpty && palette.agents.isEmpty
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
        case .agent(let agent):
            agentRow(for: agent, isSelected: isSelected)
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
            renameText = window.title
            pendingRename = window
        }
        .disabled(!palette.allowsTmuxMutation)
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
            return isCurrent
                ? String(
                    localized: "tmux window \(position) of \(total), \(window.title), \(window.panes.count) panes, current",
                    comment: "VoiceOver label for the tmux window the session is on. Pluralized on the pane count."
                )
                : String(
                    localized: "tmux window \(position) of \(total), \(window.title), \(window.panes.count) panes",
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
        let paneSummary: String
        if window.panes.count > 1 {
            paneSummary = String(localized: "\(window.panes.count) panes · each opens full-screen")
        } else if let pane = window.panes.first {
            paneSummary = pane.command ?? pane.title
        } else {
            paneSummary = String(localized: "tmux window")
        }
        return paletteNavigationRow(
            systemName: window.panes.count > 1 ? "rectangle.split.2x1" : "terminal",
            title: window.title,
            subtitle: paneSummary,
            indented: false,
            isCurrent: palette.activeWindowID == window.id,
            isSelected: isSelected
        )
    }

    private func paneRow(
        window: CommandPaletteTmuxWindow,
        pane: CommandPaletteTmuxPane,
        isSelected: Bool
    ) -> some View {
        paletteNavigationRow(
            systemName: nil,
            title: pane.title,
            subtitle: "\(pane.id.description) · \(pane.command ?? window.title)",
            indented: true,
            isCurrent: palette.activeWindowID == window.id
                && palette.activePaneID == pane.id,
            isSelected: isSelected
        )
    }

    /// Rows name live tmux windows and panes, so both strings arrive already
    /// resolved — the literal cases resolve at their call site.
    private func paletteNavigationRow(
        systemName: String?,
        title: String,
        subtitle: String,
        indented: Bool,
        isCurrent: Bool,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 12) {
            if indented {
                Text(verbatim: "↳")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgDim)
                    .frame(width: 14)
            } else if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
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
        .accessibilityLabel(Text(verbatim: "\(title), \(subtitle)"))
        .accessibilityValue(isCurrent ? "current" : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func sessionRow(for live: LiveSession, isSelected: Bool) -> some View {
        let title = live.displayLabel(in: palette.sessions)
        let pane = palette.paneTitles[live.id]
        let subtitle = subtitleString(for: live, paneTitle: pane)

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
        .accessibilityLabel("session \(title), \(subtitle)")
    }

    private func agentRow(for agent: AgentInstance, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(agent.status == .waitingForInput ? T.amber : T.fgMuted)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(agent.name)
                        .font(Typography.tesseraMono(size: 13))
                        .foregroundStyle(T.fg)
                        .lineLimit(1)
                    Text(agentStatusLabel(agent.status))
                        .font(Typography.tesseraMono(size: 9))
                        .foregroundStyle(agent.status == .waitingForInput ? T.amber : T.fgDim)
                }
                Text(agent.location.addressText)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let context = agent.prompt?.summary ?? agent.outputTail,
                   !context.isEmpty {
                    Text(context.replacingOccurrences(of: "\n", with: " "))
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgFaint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if !isPhone {
                Text(agent.location.transportLabel)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgFaint)

                Text(agent.statusChangedAt, style: .timer)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgFaint)
            }

            if isSelected {
                commitGlyph
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? T.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(verbatim: "\(agent.name), \(agentStatusLabel(agent.status)), \(agent.location.addressText)")
        )
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

    private func agentStatusLabel(_ status: AgentStatus) -> String {
        switch status {
        case .waitingForInput: return "needs input"
        case .justFinished: return "just finished"
        case .working: return "working"
        case .idle: return "idle"
        case .unavailable: return "status unavailable"
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if !isPhone {
                footerHint(symbol: "↑↓", label: "navigate")
                footerHint(symbol: KeyToken.return.rendered(appearance.modifierNotation), label: "switch")
                footerHint(symbol: KeyToken.escape.rendered(appearance.modifierNotation), label: "dismiss")
            }
            Spacer(minLength: 0)
            Text("\(palette.tmuxWindows.count) windows · \(palette.agents.count) agents · \(palette.sessions.count) sessions")
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

#if DEBUG
struct AgentPaletteHarnessView: View {
    @State private var palette: CommandPalette

    init() {
        let palette = CommandPalette()
        let alphaHost = Host(
            name: "production",
            address: "10.0.0.8",
            port: 22,
            user: "deploy"
        )
        let betaHost = Host(
            name: "database",
            address: "10.0.0.9",
            port: 22,
            user: "admin"
        )
        let sessions = [
            LiveSession(
                session: .ssh(SSHSession(host: alphaHost)),
                hostName: alphaHost.name,
                hostKey: "ssh:deploy@10.0.0.8:22",
                launchMode: .autoTmux
            ),
            LiveSession(
                session: .ssh(SSHSession(host: betaHost)),
                hostName: betaHost.name,
                hostKey: "ssh:admin@10.0.0.9:22",
                launchMode: .customCommand
            ),
        ]
        palette.open(
            sessions: sessions,
            agents: AgentCenterHarnessFixtures.agents
        )
        _palette = State(initialValue: palette)
    }

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                CommandPaletteView(palette: palette) { _ in }
            }
    }
}
#endif
