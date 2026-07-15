import SwiftUI

struct AgentCenterPage: View {
    @Bindable var center: AgentCenter

    @Environment(\.designTokens) private var T
    @State private var focusedAgentID: AgentInstanceID?
    @State private var messages: [AgentInstanceID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if center.agents.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("no agents detected")
                                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                                    .foregroundStyle(T.fgMuted)
                                Text("Agent Center watches Claude Code, Codex, and matching custom profiles across active sessions.")
                                    .font(Typography.tesseraMono(size: 11))
                                    .foregroundStyle(T.fgDim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 24)
                        } else {
                            group(.waitingForInput, label: "needs input")
                            group(.justFinished, label: "just finished")
                            group(.working, label: "working")
                            group(.idle, label: "idle")
                            group(.unavailable, label: "status unavailable")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .onChange(of: focusedAgentID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            footer
        }
        .padding(.horizontal, 40)
        .background(T.panelBg)
        .onAppear {
            center.setAgentCenterSurfaceVisible(true)
            center.markAllAttentionsRead(reason: "agent-center-opened")
            if focusedAgentID == nil { focusedAgentID = center.sortedAgents.first?.id }
        }
        .onDisappear {
            center.setAgentCenterSurfaceVisible(false)
        }
        .onChange(of: center.agents.map(\.id)) { _, ids in
            if let focusedAgentID, ids.contains(focusedAgentID) { return }
            focusedAgentID = center.sortedAgents.first?.id
        }
        .background(keyboardShortcuts)
        .accessibilityIdentifier("agent-center-page")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("agents")
                    .font(Typography.tesseraMono(size: 20, weight: .medium))
                    .foregroundStyle(T.fg)

                Spacer(minLength: 12)

                Text(summary)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            }

            Text("view and answer every agent across your sessions — tmux windows, panes, and raw connections")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .padding(.bottom, 16)

            Rectangle().fill(T.border).frame(height: 1)
        }
        .padding(.top, 28)
    }

    @ViewBuilder
    private func group(_ status: AgentStatus, label: String) -> some View {
        let agents = center.sortedAgents.filter { $0.status == status }
        if !agents.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(label) · \(agents.count)")
                        .font(Typography.tesseraMono(size: 11))
                        .tracking(0.4)
                        .foregroundStyle(groupColor(status))
                    Rectangle().fill(T.border).frame(height: 1)
                }

                ForEach(agents) { agent in
                    AgentCard(
                        agent: agent,
                        isFocused: focusedAgentID == agent.id,
                        message: messageBinding(for: agent.id),
                        onFocus: { focusedAgentID = agent.id },
                        onAnswer: { center.answer(agentID: agent.id, optionID: $0) },
                        onSend: {
                            let text = messages[agent.id, default: ""]
                            _ = center.sendMessage(agentID: agent.id, text: text) { verified in
                                guard verified,
                                      messages[agent.id, default: ""] == text
                                else { return }
                                messages[agent.id] = ""
                            }
                        },
                        onInterrupt: { center.interrupt(agentID: agent.id) },
                        integrationState: center.lifecycleIntegrationState(agentID: agent.id),
                        onRetryLifecycleIntegrationProbe: {
                            center.retryLifecycleIntegrationProbe(agentID: agent.id)
                        },
                        canInstallLifecycleIntegration: center.canInstallLifecycleIntegration(agentID: agent.id),
                        onInstallLifecycleIntegration: {
                            center.installLifecycleIntegration(agentID: agent.id)
                        },
                        onOpen: { center.jump(agentID: agent.id) }
                    )
                    .id(agent.id)
                }
            }
        }
    }

    private func groupColor(_ status: AgentStatus) -> Color {
        switch status {
        case .waitingForInput: T.amber
        case .justFinished: T.green
        case .working, .idle, .unavailable: T.fgMuted
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("answers re-check the live prompt · sends verify submission")
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
            Spacer(minLength: 8)
            hint("⇥", "next card")
            hint("1–9", "answer")
            hint("⌘↩", "open")
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(T.border).frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(T.inputBgSoft)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(T.border, lineWidth: 1))
            Text(label)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
        }
    }

    private var summary: String {
        let sessionCount = Set(center.agents.map { $0.id.sessionID }).count
        let hostCount = Set(center.agents.map { $0.location.hostName }).count
        return "\(center.agents.count) agents · \(sessionCount) sessions · \(hostCount) hosts"
    }

    private func messageBinding(for id: AgentInstanceID) -> Binding<String> {
        Binding(
            get: { messages[id, default: ""] },
            set: { messages[id] = $0 }
        )
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        Button("Next agent", action: focusNext)
            .keyboardShortcut(.tab, modifiers: [])
            .hidden()
        ForEach(1...9, id: \.self) { number in
            Button("Answer \(number)") { answerFocused(number) }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
                .hidden()
        }
        Button("Open focused agent") {
            guard let focusedAgentID else { return }
            center.jump(agentID: focusedAgentID)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .hidden()
    }

    private func focusNext() {
        let rows = center.sortedAgents
        guard !rows.isEmpty else { focusedAgentID = nil; return }
        guard let focusedAgentID,
              let index = rows.firstIndex(where: { $0.id == focusedAgentID })
        else { self.focusedAgentID = rows[0].id; return }
        self.focusedAgentID = rows[(index + 1) % rows.count].id
    }

    private func answerFocused(_ number: Int) {
        guard let focusedAgentID,
              let agent = center.agents.first(where: { $0.id == focusedAgentID }),
              agent.prompt?.options.contains(where: { $0.id == number }) == true
        else { return }
        center.answer(agentID: focusedAgentID, optionID: number)
    }

}

private struct AgentCard: View {
    let agent: AgentInstance
    let isFocused: Bool
    @Binding var message: String
    let onFocus: () -> Void
    let onAnswer: (Int) -> Void
    let onSend: () -> Void
    let onInterrupt: () -> Void
    let integrationState: AgentLifecycleIntegrationState
    let onRetryLifecycleIntegrationProbe: () -> Void
    let canInstallLifecycleIntegration: Bool
    let onInstallLifecycleIntegration: () -> Void
    let onOpen: () -> Void

    @Environment(\.designTokens) private var T
    @FocusState private var inputFocused: Bool
    @State private var showingIntegrationConfirmation = false
    @State private var showingIntegrationHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let taskSummary = agent.taskSummary, !taskSummary.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("task")
                        .foregroundStyle(T.fgFaint)
                    Text(taskSummary)
                        .foregroundStyle(T.fgMuted)
                        .lineLimit(1)
                }
                .font(Typography.tesseraMono(size: 10))
                .padding(.leading, 36)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("agent-task-\(agent.location.paneID.map(String.init) ?? "raw")")
            }
            if let output = agent.outputTail, !output.isEmpty { tail(output) }
            controls
            if let actionMessage = agent.actionMessage {
                Text(actionMessage)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(agent.actionIsError ? T.red : T.fgDim)
                    .padding(.leading, 36)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(T.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isFocused ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onFocus() }
        .onChange(of: isFocused) { _, focused in
            if focused, agent.status == .working
                || agent.status == .justFinished
                || agent.status == .idle {
                inputFocused = true
            }
        }
        .onAppear {
            if isFocused, agent.status == .working
                || agent.status == .justFinished
                || agent.status == .idle {
                inputFocused = true
            }
        }
        .alert(integrationConfirmationTitle, isPresented: $showingIntegrationConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Help") {
                Task { @MainActor in
                    await Task.yield()
                    showingIntegrationHelp = true
                }
            }
            Button(integrationInstallLabel) { onInstallLifecycleIntegration() }
        } message: {
            Text(RemoteAgentLifecycleIntegrationInstaller.confirmationText)
        }
        .sheet(isPresented: $showingIntegrationHelp) {
            AgentLifecycleIntegrationHelpView()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(agentIconColor)
                .frame(width: 26, height: 26)
                .background(T.inputBgSoft)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.border, lineWidth: 1))

            Text(agent.name)
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(T.fg)

            statusChip

            Text(agent.location.transportLabel)
                .font(Typography.tesseraMono(size: 9))
                .tracking(0.3)
                .foregroundStyle(T.fgFaint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(T.border, lineWidth: 1))

            if let sessionReference = agent.providerSessionReference {
                Text("session \(sessionReference)")
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgFaint)
                    .lineLimit(1)
                    .accessibilityLabel("provider session \(sessionReference)")
                    .accessibilityIdentifier("agent-provider-session-\(agent.location.paneID.map(String.init) ?? "raw")")
            }

            Text(agent.location.addressText)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(duration(at: context.date))
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            }

            Button(action: onOpen) {
                Text("open ↩")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(T.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var statusChip: some View {
        Text(statusLabel)
            .font(Typography.tesseraMono(size: 10))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(statusColor.opacity(0.28), lineWidth: 1))
            .accessibilityIdentifier("agent-status-\(agent.location.paneID.map(String.init) ?? "raw")")
    }

    private func tail(_ text: String) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgMuted)
            .lineLimit(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 11)
            .background(Color.black.opacity(T.isLight ? 0.06 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.sidebarBorder, lineWidth: 1))
            .padding(.leading, 36)
    }

    @ViewBuilder
    private var controls: some View {
        if agent.status == .waitingForInput, let prompt = agent.prompt {
            HStack(spacing: 8) {
                ForEach(prompt.options) { option in
                    Button { onAnswer(option.id) } label: {
                        HStack(spacing: 7) {
                            Text(String(option.id))
                                .font(Typography.tesseraMono(size: 9))
                                .foregroundStyle(option.isDefault ? T.accent : T.fgDim)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(T.border, lineWidth: 1))
                            Text(option.label)
                                .lineLimit(1)
                        }
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(option.isDefault ? T.fg : T.fgMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(option.isDefault ? T.accentSoft : T.inputBgSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(agent.sendInFlight)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 36)
        } else if agent.status == .working {
            HStack(spacing: 8) {
                inputRow(label: "message \(agent.name)…", actionLabel: "↩ queue")
                Button("⎋ interrupt", action: onInterrupt)
                    .agentSecondaryButton(T: T)
                    .disabled(agent.sendInFlight)
            }
            .padding(.leading, 36)
        } else if agent.status == .justFinished || agent.status == .idle {
            inputRow(label: "prompt \(agent.name)…", actionLabel: "↩ send")
                .padding(.leading, 36)
        } else if agent.status == .unavailable, canInstallLifecycleIntegration {
            HStack(spacing: 10) {
                Text(integrationMessage)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
                Spacer(minLength: 8)
                if integrationState == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("checking agent status integration")
                } else if integrationState == .notChecked {
                    Button("check status hook", action: onRetryLifecycleIntegrationProbe)
                        .agentSecondaryButton(T: T)
                } else if integrationState == .checkUnavailable {
                    Button("retry check", action: onRetryLifecycleIntegrationProbe)
                        .agentSecondaryButton(T: T)
                } else if integrationState != .active && integrationState != .installedInactive {
                    Button(integrationInstallLabel) {
                        showingIntegrationConfirmation = true
                    }
                    .agentSecondaryButton(T: T)
                    .disabled(agent.sendInFlight)
                }
            }
            .padding(.leading, 36)
        }
    }

    private var integrationMessage: String {
        switch integrationState {
        case .checking:
            "checking whether precise status support is installed on this host…"
        case .notChecked:
            "check this host before installing precise status support"
        case .checkUnavailable:
            "could not check status-hook installation on this host"
        case .notInstalled:
            "agent found; working/idle is unavailable until its lifecycle hook is installed"
        case .installedInactive:
            "status hook installed but inactive here — review Codex /hooks or relaunch the agent"
        case .active:
            "provider lifecycle hook active; waiting for its next state transition"
        case .outdated(let version):
            version.map { "status hook v\($0) is outdated; update to v\(RemoteAgentLifecycleIntegrationInstaller.integrationVersion)" }
                ?? "status hook is outdated; update it for precise state"
        }
    }

    private var integrationInstallLabel: String {
        if case .outdated = integrationState { return "update status hook" }
        return "install status hook"
    }

    private var integrationConfirmationTitle: String {
        if case .outdated = integrationState { return "Update agent status hook?" }
        return "Install agent status hook?"
    }

    private func inputRow(label: String, actionLabel: String) -> some View {
        HStack(spacing: 8) {
            TextField(label, text: $message)
                .textFieldStyle(.plain)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fg)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(T.inputBgSoft)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.border, lineWidth: 1))
                .focused($inputFocused)
                .onSubmit(onSend)
                .disabled(agent.sendInFlight)

            Button(actionLabel, action: onSend)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.accentSoft, lineWidth: 1))
                .buttonStyle(.plain)
                .disabled(agent.sendInFlight || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var borderColor: Color {
        if agent.status == .waitingForInput { return T.amber.opacity(0.3) }
        if agent.status == .justFinished { return T.green.opacity(0.34) }
        if isFocused { return T.accent.opacity(0.45) }
        return T.border
    }

    private var agentIconColor: Color {
        switch agent.status {
        case .waitingForInput: T.amber
        case .justFinished: T.green
        case .working, .idle, .unavailable: T.fgMuted
        }
    }

    private var statusLabel: String {
        switch agent.status {
        case .waitingForInput: return "waiting for input"
        case .justFinished: return "just finished"
        case .working: return "working"
        case .idle: return "idle at prompt"
        case .unavailable: return "status unavailable"
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case .waitingForInput: return T.amber
        case .justFinished: return T.green
        case .working: return T.green
        case .idle, .unavailable: return T.fgDim
        }
    }

    private func duration(at now: Date) -> String {
        let seconds: Int
        let prefix: String
        switch agent.status {
        case .waitingForInput:
            seconds = max(0, Int(now.timeIntervalSince(agent.statusChangedAt)))
            prefix = "blocked"
        case .working:
            seconds = max(0, Int(now.timeIntervalSince(agent.detectedAt)))
            prefix = "running"
        case .justFinished:
            seconds = max(0, Int(now.timeIntervalSince(agent.finishedAt ?? agent.statusChangedAt)))
            prefix = "finished"
        case .idle:
            seconds = max(0, Int(now.timeIntervalSince(agent.lastLifecycleEventAt ?? agent.statusChangedAt)))
            prefix = "last event"
        case .unavailable:
            seconds = max(0, Int(now.timeIntervalSince(agent.lastOutputAt ?? agent.statusChangedAt)))
            prefix = "quiet"
        }
        if seconds < 60 { return "\(prefix) \(seconds)s" }
        if seconds < 3600 { return "\(prefix) \(seconds / 60)m" }
        return "\(prefix) \(seconds / 3600)h"
    }
}

/// Foreground-only aggregate for lifecycle events that happened away from the
/// current raw pane or tmux window the user is viewing. Opening the list does
/// not acknowledge an event; jumping to its pane does, so the unread model
/// stays honest.
struct AgentAttentionPopover: View {
    @Bindable var center: AgentCenter
    let onOpen: (AgentInstanceID) -> Void

    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("agents need attention")
                .font(Typography.tesseraMono(size: 13, weight: .semibold))
                .foregroundStyle(T.fg)
                .padding(.bottom, 4)
                .accessibilityIdentifier("agent-attention-popover")

            Text("visiting the agent's pane marks it checked")
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
                .padding(.bottom, 12)

            if center.sortedUnreadAttentions.isEmpty {
                Text("all caught up")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(center.sortedUnreadAttentions) { attention in
                        if let agent = center.agentInstance(attention.agentID) {
                            attentionRow(attention, agent: agent)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 390, alignment: .leading)
        .background(T.panelBg)
    }

    private func attentionRow(
        _ attention: AgentAttention,
        agent: AgentInstance
    ) -> some View {
        let tint = attention.kind == .needsInput ? T.amber : T.green

        return HStack(spacing: 10) {
            Image(systemName: attention.kind == .needsInput ? "person.crop.circle.badge.exclamationmark" : "checkmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .foregroundStyle(T.fg)
                    Text(attention.kind == .needsInput ? "needs input" : "finished")
                        .foregroundStyle(tint)
                }
                .font(Typography.tesseraMono(size: 11, weight: .medium))

                Text(agent.location.addressText)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier(
                        "agent-attention-row-\(agent.location.paneID.map(String.init) ?? "raw")"
                    )
            }

            Spacer(minLength: 8)

            Button("open ↩") { onOpen(agent.id) }
                .font(Typography.tesseraMono(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.42), lineWidth: 1))
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(agent.name) on \(agent.location.hostName)")
                .accessibilityIdentifier(
                    "agent-attention-open-\(agent.location.paneID.map(String.init) ?? "raw")"
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(T.inputBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
    }
}

struct AgentLifecycleIntegrationHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var T
    @State private var showsSource = false

    init(initiallyShowsSource: Bool = false) {
        _showsSource = State(initialValue: initiallyShowsSource)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("why this is necessary")
                        .font(Typography.tesseraMono(size: 15, weight: .medium))
                        .foregroundStyle(T.fg)
                        .accessibilityAddTraits(.isHeader)

                    Text("A terminal exposes process presence and pixels, but not whether an agent is computing, idle, or blocked. Claude and Codex keep prompt-looking rows visible while they work, so inferring state from terminal text produces false results. Their lifecycle hook APIs are the authoritative signal.")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgMuted)

                    Text("what installation changes")
                        .font(Typography.tesseraMono(size: 13, weight: .medium))
                        .foregroundStyle(T.fg)
                        .accessibilityAddTraits(.isHeader)

                    VStack(alignment: .leading, spacing: 7) {
                        helpLine("creates or replaces Tessera-owned hook, launcher, readiness, shell-integration, and provider-shim files under ~/.config/tessera")
                        helpLine("atomically merges only Tessera's handlers into the active Codex hooks.json and Claude settings.json, preserving unrelated settings, hooks, formatting-independent meaning, and symlink targets")
                        helpLine("adds one guarded source line to each existing ~/.bashrc and ~/.zshrc; if neither exists, creates ~/.zshrc when $SHELL is zsh, otherwise ~/.bashrc")
                        helpLine("records the exact shells that loaded it under ~/.config/tessera/active-shells")
                        helpLine("prepends optional PATH shims for fast empty-composer detection while resolving the real executable from the live PATH on every launch")
                        helpLine("leaves every Claude/Codex alias and user-defined function unchanged, including added flags, command/env forms, renamed shortcuts, and version-manager PATH changes")
                        helpLine("native provider hooks remain authoritative for launches that bypass the shims, including absolute executable paths, as long as they use the same provider config scope")
                        helpLine("never changes ~/.codex/config.toml and never injects a competing Claude --settings flag")
                        helpLine("sets tmux pane options for shell activation and latest agent state, and writes a private OSC status frame to the owning terminal")
                        helpLine("emits only provider, lifecycle event, state, reason, timestamp, and local process ID — never prompts, responses, source code, credentials, or API traffic")
                    }

                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showsSource.toggle()
                            }
                        } label: {
                            HStack {
                                Text(showsSource ? "show less" : "show more")
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(showsSource ? 90 : 0))
                            }
                            .font(Typography.tesseraMono(size: 11, weight: .medium))
                            .foregroundStyle(T.accent)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-hook-show-more")

                        if showsSource {
                            ScrollView(.vertical) {
                                Text(verbatim: RemoteAgentLifecycleIntegrationInstaller.disclosedSource)
                                    .font(Typography.tesseraMono(size: 9))
                                    .foregroundStyle(T.fgMuted)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(10)
                                    .accessibilityIdentifier("agent-hook-source-text")
                            }
                            .frame(height: 420)
                            .background(T.panelBg)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.border, lineWidth: 1))
                            .padding([.horizontal, .bottom], 10)
                            .accessibilityIdentifier("agent-hook-source")
                            .accessibilityValue(
                                String(RemoteAgentLifecycleIntegrationInstaller.integrationVersion)
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(T.inputBgSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
                }
                .padding(24)
            }
            .background(T.panelBg)
            .navigationTitle("agent status hook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func helpLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("·")
            Text(text)
        }
        .font(Typography.tesseraMono(size: 11))
        .foregroundStyle(T.fgMuted)
    }
}

private extension View {
    func agentSecondaryButton(T: DesignTokens) -> some View {
        self
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(T.border, lineWidth: 1))
            .buttonStyle(.plain)
    }
}

#if DEBUG
struct AgentCenterHarnessView: View {
    @State private var center: AgentCenter
    @Environment(\.designTokens) private var T

    init() {
        let center = AgentCenter(sendVerificationDelayNanoseconds: 1_000_000)
        center.installHarnessAgents(AgentCenterHarnessFixtures.agents)
        if let unavailable = AgentCenterHarnessFixtures.agents.first(where: { $0.status == .unavailable }) {
            center.installHarnessLifecycleIntegrationState(.notInstalled, for: unavailable.id)
        }
        _center = State(initialValue: center)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tessera")
                    .font(Typography.tesseraMono(size: 17, weight: .medium))
                    .foregroundStyle(T.fg)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                Spacer()
                BottomNavigationRow(
                    item: .agents,
                    systemName: "sparkles",
                    label: "agents",
                    badges: AgentSidebarBadgeFactory.make(
                        waitingCount: center.waitingCount,
                        justFinishedCount: center.unreadJustFinishedCount,
                        totalCount: center.agents.count
                    ),
                    isSelected: true,
                    action: {}
                )
                .padding(10)
            }
            .frame(width: 270)
            .background(T.sidebarBg)

            Rectangle()
                .fill(T.border)
                .frame(width: 1)

            AgentCenterPage(center: center)
        }
    }
}

@MainActor
enum AgentCenterHarnessFixtures {
    static let agents: [AgentInstance] = {
        let now = Date.now
        let sshSession = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let moshSession = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        return [
            make(
                sessionID: sshSession,
                paneID: 7,
                profileID: SwipePadProfile.builtInCodexCLIID,
                name: "Codex",
                host: "devbox",
                transport: "ssh+tmux",
                tmuxSession: "project",
                windowID: 3,
                windowName: "api",
                status: .waitingForInput,
                tail: "› Audit Agent Center reliability\n1. Yes, implement this plan\n2. Yes, clear context and implement\n3. No, stay in Plan mode\nPress enter to confirm or esc to go back",
                prompt: AgentPrompt(
                    signature: "Approve implementation plan",
                    summary: "Approve implementation plan",
                    options: [
                        AgentPromptOption(id: 1, label: "Yes, implement this plan", responseMacro: "1↵", isDefault: true),
                        AgentPromptOption(id: 2, label: "Clear context and implement", responseMacro: "2↵", isDefault: false),
                        AgentPromptOption(id: 3, label: "Stay in Plan mode", responseMacro: "3↵", isDefault: false),
                    ]
                ),
                detectedAt: now.addingTimeInterval(-734),
                statusChangedAt: now.addingTimeInterval(-43),
                lastOutputAt: now.addingTimeInterval(-43)
            ),
            make(
                sessionID: moshSession,
                paneID: 12,
                profileID: SwipePadProfile.builtInCodexCLIID,
                name: "Codex",
                host: "buildbox",
                transport: "mosh+tmux",
                tmuxSession: "release",
                windowID: 5,
                windowName: "tests",
                status: .working,
                tail: "› Validate Agent Center across every transport\n• Running focused integration tests\n• Inspecting transport results\n› Improve documentation in @filename",
                currentInputLine: "› Improve documentation in @filename",
                prompt: nil,
                detectedAt: now.addingTimeInterval(-312),
                statusChangedAt: now.addingTimeInterval(-28),
                lastOutputAt: now.addingTimeInterval(-2)
            ),
            make(
                sessionID: moshSession,
                paneID: 13,
                profileID: SwipePadProfile.builtInClaudeCodeID,
                name: "Claude Code",
                host: "buildbox",
                transport: "mosh+tmux",
                tmuxSession: "release",
                windowID: 6,
                windowName: "review",
                status: .justFinished,
                taskSummary: "Review Agent Center integration",
                tail: "Finished the integration review.\n\n❯ Add follow-up feedback",
                currentInputLine: "❯ Add follow-up feedback",
                prompt: nil,
                detectedAt: now.addingTimeInterval(-420),
                statusChangedAt: now.addingTimeInterval(-34),
                lastOutputAt: now.addingTimeInterval(-34)
            ),
            make(
                sessionID: sshSession,
                paneID: 9,
                profileID: SwipePadProfile.builtInClaudeCodeID,
                name: "Claude Code",
                host: "devbox",
                transport: "ssh+tmux",
                tmuxSession: "project",
                windowID: 4,
                windowName: "docs",
                status: .idle,
                tail: "Updated the architecture notes.\n\n❯ Document lifecycle diagnostics",
                prompt: nil,
                detectedAt: now.addingTimeInterval(-1_802),
                statusChangedAt: now.addingTimeInterval(-121),
                lastOutputAt: now.addingTimeInterval(-121)
            ),
            make(
                sessionID: moshSession,
                paneID: nil,
                profileID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                name: "Future harness",
                host: "staging",
                transport: "mosh",
                tmuxSession: nil,
                windowID: nil,
                windowName: nil,
                status: .unavailable,
                tail: nil,
                prompt: nil,
                detectedAt: now.addingTimeInterval(-90),
                statusChangedAt: now.addingTimeInterval(-90),
                lastOutputAt: nil
            ),
        ]
    }()

    static func make(
        sessionID: UUID,
        paneID: Int?,
        profileID: UUID,
        name: String,
        host: String,
        transport: String,
        tmuxSession: String?,
        windowID: Int?,
        windowName: String?,
        status: AgentStatus,
        taskSummary explicitTaskSummary: String? = nil,
        tail: String?,
        currentInputLine: String? = nil,
        prompt: AgentPrompt?,
        detectedAt: Date,
        statusChangedAt: Date,
        lastOutputAt: Date?
    ) -> AgentInstance {
        AgentInstance(
            id: AgentInstanceID(sessionID: sessionID, paneID: paneID),
            profileID: profileID,
            name: name,
            providerSessionID: "\(profileID == SwipePadProfile.builtInCodexCLIID ? "codex" : "claude")-\(paneID ?? 0)-preview",
            location: AgentLocation(
                sessionID: sessionID,
                hostName: host,
                transportLabel: transport,
                tmuxSessionName: tmuxSession,
                windowID: windowID,
                windowName: windowName,
                paneID: paneID
            ),
            status: status,
            taskSummary: explicitTaskSummary ?? tail.flatMap {
                AgentTerminalText.taskSummary(
                    $0,
                    excludingCurrentInputLine: currentInputLine
                )
            },
            outputTail: tail,
            prompt: prompt,
            detectedAt: detectedAt,
            statusChangedAt: statusChangedAt,
            finishedAt: status == .justFinished ? statusChangedAt : nil,
            lastLifecycleEventAt: statusChangedAt,
            lastOutputAt: lastOutputAt,
            outputSequence: 1,
            bracketedPasteEnabled: true,
            sendInFlight: false,
            actionMessage: nil,
            actionIsError: false
        )
    }
}
#endif
