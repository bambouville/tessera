import SwiftUI

/// Quick-switch palette overlay. Top-anchored modal with a search
/// input + active-sessions list. Arrow keys + Enter + Esc.
///
/// Renders only when `palette.isOpen` — the caller is expected to
/// mount this in a `.overlay` and gate visibility on that flag.
struct CommandPaletteView: View {
    @Bindable var palette: CommandPalette

    /// Called with the chosen session or agent when the user commits. The
    /// caller is responsible for actually switching to it (the palette
    /// is intentionally agnostic about the navigation model so it
    /// stays testable without SwiftUI bindings).
    let onCommit: (CommandPaletteCommit) -> Void

    @Environment(\.designTokens) private var T
    @FocusState private var queryFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            scrim
            paletteCard
                .padding(.top, 72)
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

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(T.fgMuted)

            TextField(
                "switch session or agent — @ scopes agents",
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

            Text("esc")
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(T.border, lineWidth: 1)
                )
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
                    LazyVStack(spacing: 0) {
                        if !palette.results.isEmpty {
                            sectionHeader("sessions")
                        }
                        ForEach(Array(palette.results.enumerated()), id: \.element.id) { index, live in
                            sessionRow(for: live, isSelected: index == palette.selectedIndex)
                                .id(CommandPaletteEntry.ID.session(live.id))
                                .onTapGesture {
                                    palette.selectedIndex = index
                                    commitCurrent()
                                }
                        }
                        if !palette.agentResults.isEmpty {
                            sectionHeader("agents")
                        }
                        ForEach(Array(palette.agentResults.enumerated()), id: \.element.id) { offset, agent in
                            let index = palette.results.count + offset
                            agentRow(for: agent, isSelected: index == palette.selectedIndex)
                                .id(CommandPaletteEntry.ID.agent(agent.id))
                                .onTapGesture {
                                    palette.selectedIndex = index
                                    commitCurrent()
                                }
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Typography.tesseraMono(size: 9))
            .foregroundStyle(T.fgFaint)
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(palette.sessions.isEmpty && palette.agents.isEmpty
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
        case .session(let live):
            sessionRow(for: live, isSelected: isSelected)
        }
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
                Text(title)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isSelected {
                Text("↩")
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

            Text(agent.location.transportLabel)
                .font(Typography.tesseraMono(size: 9))
                .foregroundStyle(T.fgFaint)

            Text(agent.statusChangedAt, style: .timer)
                .font(Typography.tesseraMono(size: 9))
                .foregroundStyle(T.fgFaint)

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
            "\(agent.name), \(agentStatusLabel(agent.status)), \(agent.location.addressText)"
        )
    }

    private var commitGlyph: some View {
        Text("↩")
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
            footerHint(symbol: "↑↓", label: "navigate")
            footerHint(symbol: "↩",  label: "switch")
            footerHint(symbol: "esc", label: "dismiss")
            Spacer(minLength: 0)
            Text("\(palette.agents.count) agents · \(palette.sessions.count) sessions")
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func footerHint(symbol: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
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
