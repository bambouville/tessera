import SwiftUI
import TesseraCore

struct AgentThreadListView: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let isCompact: Bool
    var onOpenThread: ((AgentThreadID) -> Void)?
    var onOpenCandidate: ((AgentSourceCandidateID) -> Void)?
    @FocusState private var searchFocused: Bool
    @State private var visibleRows = AgentThreadListSection.Visibility()

    @Environment(\.designTokens) private var T

    init(
        model: AgentCenterV2PresentationModel,
        isCompact: Bool,
        onOpenThread: ((AgentThreadID) -> Void)? = nil,
        onOpenCandidate: ((AgentSourceCandidateID) -> Void)? = nil
    ) {
        self.model = model
        self.isCompact = isCompact
        self.onOpenThread = onOpenThread
        self.onOpenCandidate = onOpenCandidate
    }

    private func setRowVisible(_ key: AgentThreadListSection.Row.Key, _ visible: Bool) {
        if let changed = visibleRows.set(key, visible: visible) {
            model.onAction?(.cardVisibility(key.thread, changed))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            if model.listSnapshot.threads.isEmpty && model.listSnapshot.candidates.isEmpty
                && model.searchQuery.isEmpty {
                ContentUnavailableView {
                    Label("no threads", systemImage: "sparkles")
                } description: {
                    Text("Connected hosts with agent transcripts appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        if !model.searchQuery.isEmpty {
                            Section {
                                if model.isSearching {
                                    ProgressView().padding(.horizontal, 16).padding(.vertical, 10)
                                } else if model.searchSnapshot.results.isEmpty {
                                    Text("no transcript matches on connected sources")
                                        .font(Typography.tesseraMono(size: 11))
                                        .foregroundStyle(T.fgDim)
                                        .padding(.horizontal, 16).padding(.vertical, 10)
                                } else {
                                    ForEach(Array(model.searchSnapshot.results.enumerated()), id: \.offset) { _, result in
                                        Button {
                                            model.select(result.threadID)
                                            onOpenThread?(result.threadID)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(model.threadSnapshots[result.threadID]?.summary.title ?? "agent thread")
                                                    .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                                                Text(result.excerpt)
                                                    .font(Typography.tesseraMono(size: 10.5))
                                                    .foregroundStyle(T.fgMuted)
                                                    .lineLimit(3)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: isCompact ? 44 : 36, alignment: .leading)
                                            .padding(.horizontal, 16).padding(.vertical, 6)
                                        }
                                        .accessibilityIdentifier("agent-center-v2-search-result-\(result.threadID.providerID.rawValue)-\(result.recordID)")
                                        .buttonStyle(.plain)
                                    }
                                }
                                if !model.searchSnapshot.unavailableHostIDs.isEmpty {
                                    Text("\(model.searchSnapshot.unavailableHostIDs.count) connected source\(model.searchSnapshot.unavailableHostIDs.count == 1 ? " is" : "s are") unavailable")
                                        .font(Typography.tesseraMono(size: 10))
                                        .foregroundStyle(T.fgDim)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 8)
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Text("transcript matches")
                                        .font(Typography.kicker).foregroundStyle(T.fgDim)
                                    Rectangle().fill(T.border).frame(height: 1)
                                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 5).background(T.panelBg)
                            }
                        }
                        if !model.listSnapshot.candidates.isEmpty {
                            Section {
                                ForEach(model.listSnapshot.candidates) { candidate in
                                    candidateRow(candidate)
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Text("live terminals")
                                        .font(Typography.kicker)
                                        .foregroundStyle(T.fgDim)
                                    Rectangle().fill(T.border).frame(height: 1)
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 5)
                                .background(T.panelBg)
                            }
                        }
                        ForEach(groupedRows) { section in
                            Section {
                                ForEach(section.keyedRows) { row in
                                    threadRow(row.summary)
                                        .onAppear { setRowVisible(row.id, true) }
                                        .onDisappear { setRowVisible(row.id, false) }
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Text(section.title)
                                        .font(Typography.kicker)
                                        .foregroundStyle(section.isUrgent ? T.amber : T.fgDim)
                                    Rectangle().fill(T.border).frame(height: 1)
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 5)
                                .background(T.panelBg)
                            }
                        }
                    }
                    .padding(.bottom, isCompact ? 82 : 12)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(T.panelBg)
        .background {
            // Tier 3 of the title waterfall clips the opening prompt, and how
            // much of it survives is a property of this list, not of the
            // device: the same iPad shows a wide pane in split view and a
            // narrow one beside a thread. Measure the pane that renders the
            // row instead of guessing from screen size.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { reportTitleWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in reportTitleWidth(width) }
            }
        }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, focused in
            if focused { model.keyboardFocus = .search }
            else if model.keyboardFocus == .search { model.keyboardFocus = .none }
        }
        .overlay(alignment: .bottomTrailing) {
            if isCompact {
                Button {
                    model.openLaunch(.spawn)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 52, height: 52)
                        .foregroundStyle(T.fg)
                        .background(T.panelBg, in: Circle())
                        .overlay(Circle().stroke(T.borderStrong, lineWidth: 1))
                }
                .accessibilityIdentifier("agent-center-v2-new-fab")
                .accessibilityLabel("new agent")
                .padding(.trailing, 18)
                .padding(.bottom, 18)
            }
        }
        .overlay(alignment: .topLeading) {
            #if DEBUG
            AgentCenterV2HarnessAccessibilityMarker(identifier: "agent-center-v2-thread-list")
            #endif
        }
    }

    /// A row spends 16pt of padding on each side and starts with a status dot
    /// and its gap; the rest is the title, in a monospaced face whose advance
    /// is a fixed fraction of its point size.
    private static let rowChromeWidth: CGFloat = 47
    private static let titleGlyphWidth: CGFloat = 7.5

    private func reportTitleWidth(_ width: CGFloat) {
        let available = width - Self.rowChromeWidth
        guard available > 0 else { return }
        model.reportTitleCharacterBudget(Int(available / Self.titleGlyphWidth))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("threads")
                .font(isCompact ? Typography.sheetTitle : Typography.pageTitle)
                .foregroundStyle(T.fg)
            Text("\(model.listSnapshot.threads.count + model.listSnapshot.candidates.count)")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
            Spacer()
            Menu {
                Button("attention") { setGrouping(.attention) }
                Button("host") { setGrouping(.host) }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(minWidth: isCompact ? 44 : 36, minHeight: isCompact ? 44 : 36)
            }
            .accessibilityLabel("group threads")
            if !isCompact {
                Button {
                    model.openLaunch(.spawn)
                } label: {
                    Label("new", systemImage: "plus")
                        .font(Typography.tesseraMono(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(minHeight: 36)
                        .foregroundStyle(T.accent)
                        .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.accent.opacity(0.35), lineWidth: 1))
                }
                .accessibilityIdentifier("agent-center-v2-new")
                .accessibilityLabel("new agent")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isCompact ? 12 : 21)
        .padding(.bottom, 9)
    }

    private var searchBar: some View {
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(T.fgDim)
            TextField("search all transcripts", text: $model.searchQuery)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFocused)
                .font(Typography.tesseraMono(size: 11))
                .onSubmit { model.onAction?(.search(model.searchQuery)) }
                .onChange(of: model.searchQuery) { _, query in
                    model.onAction?(.search(query))
                }
            if !model.searchQuery.isEmpty {
                Button("clear") { model.searchQuery = "" }
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
        .accessibilityIdentifier("agent-center-v2-search")
    }

    private func setGrouping(_ grouping: AgentListGrouping) {
        model.grouping = grouping
        model.onAction?(.setGrouping(grouping))
    }

    @ViewBuilder
    private func threadRow(_ summary: AgentThreadSummary) -> some View {
        let isSelected = model.selectedThreadID == summary.id
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.keyboardFocus = .list
                model.select(summary.id)
                onOpenThread?(summary.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        statusDot(for: summary)
                        Text(summary.title)
                            .font(Typography.tesseraMono(size: 12.5, weight: .medium))
                            .foregroundStyle(T.fg)
                            .lineLimit(1)
                        if summary.queuedMessageCount > 0 {
                            Text("\(summary.queuedMessageCount) queued")
                                .font(Typography.tesseraMono(size: 9))
                                .foregroundStyle(T.amber)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(T.amber.opacity(0.14), in: Capsule())
                        }
                        Spacer(minLength: 3)
                        age(summary.lastActivity)
                    }
                    Text(identity(for: summary))
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgMuted)
                        .lineLimit(1)
                        .padding(.leading, 14)
                    if let preview = summary.preview, !preview.isEmpty {
                        Text(preview)
                            .font(Typography.tesseraMono(size: 10))
                            .foregroundStyle(summary.attention == .needsYou ? T.amber : T.fgDim)
                            .lineLimit(1)
                            .padding(.leading, 14)
                    }
                    meter(for: summary)
                        .padding(.leading, 14)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? T.inputBg : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(
                    isSelected && summary.attention == .needsYou ? T.amber.opacity(0.4) : isSelected ? T.borderStrong : .clear,
                    lineWidth: 1
                ))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-center-v2-thread-\(summary.id.providerSessionID)")
            .accessibilityLabel("\(summary.title), \(summary.status.rawValue)")

            if isCompact, AgentCenterV2PresentationModel.rendersInlinePromptOptions(for: summary), let prompt = prompt(for: summary.id) {
                urgentActions(prompt, threadID: summary.id)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 9)
            }
        }
        .padding(.horizontal, 8)
    }

    private func candidateRow(_ candidate: AgentTerminalCandidate) -> some View {
        let selected = model.selectedCandidateID == candidate.id
        return Button {
            model.selectCandidate(candidate.id)
            model.keyboardFocus = .list
            onOpenCandidate?(candidate.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(candidate.fallback.status == .waitingForInput ? T.amber : T.fgFaint)
                        .frame(width: 7, height: 7)
                    Text(candidate.title)
                        .font(Typography.tesseraMono(size: 12.5, weight: .medium))
                        .foregroundStyle(T.fg)
                        .lineLimit(1)
                    Spacer()
                    Text("live")
                        .font(Typography.tesseraMono(size: 9))
                        .foregroundStyle(T.fgDim)
                }
                Text("\(candidate.providerName) · \(candidate.hostDisplayLabel)")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgMuted)
                    .lineLimit(1)
                    .padding(.leading, 14)
                Text(candidate.fallback.status == .waitingForInput
                     ? "needs you · transcript identity unavailable"
                     : "status unavailable · transcript identity unavailable")
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(candidate.fallback.status == .waitingForInput ? T.amber : T.fgFaint)
                    .padding(.leading, 14)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? T.inputBg : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selected ? T.borderStrong : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("agent-center-v2-candidate-\(candidate.id.sourceIdentity)")
    }

    private func urgentActions(_ prompt: AgentActionPrompt, threadID: AgentThreadID) -> some View {
        let canAnswer = model.threadSnapshots[threadID]?.summary.availability.actions == true
            && model.threadSnapshots[threadID]?.binding?.capabilities.contains(.promptAnswer) == true
        return HStack(spacing: 7) {
            if canAnswer {
                ForEach(prompt.options.filter { $0.acceptsText != true }.prefix(3)) { option in
                    Button {
                        model.keyboardFocus = .action
                        model.onAction?(.answer(threadID: threadID, token: prompt.token, goal: .option(option.id)))
                    } label: {
                        Text(option.label)
                            .font(Typography.tesseraMono(size: 10, weight: option.isDefault ? .medium : .regular))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(option.isDefault ? T.fg : T.fgMuted)
                            .background(option.isDefault ? T.accentSoft : T.inputBgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(option.isDefault ? T.accent.opacity(0.35) : T.border, lineWidth: 1))
                    }
                    .accessibilityLabel("answer \(option.label)")
                    .disabled(model.answeringPromptThreads.contains(threadID))
                }
                if let control = prompt.controls?.first(where: { $0.kind == .open }) {
                    Button("Answer") {
                        model.onAction?(.answer(threadID: threadID, token: prompt.token, goal: .control(control.kind)))
                    }
                    .font(Typography.tesseraMono(size: 10.5))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("agent-center-v2-answer-control-open")
                    .disabled(model.answeringPromptThreads.contains(threadID))
                }
                if prompt.options.filter({ $0.acceptsText != true }).count > 3 {
                    Button("more") {
                        model.keyboardFocus = .action
                        model.showPromptOverflow(threadID: threadID, prompt: prompt)
                    }
                        .font(Typography.tesseraMono(size: 10.5))
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(T.fgMuted)
                        .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(model.answeringPromptThreads.contains(threadID))
                }
            } else {
                Button {
                    model.onAction?(.openTerminal(threadID))
                } label: {
                    Label("Open terminal to answer", systemImage: "terminal")
                        .font(Typography.tesseraMono(size: 10.5))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(T.accent)
                        .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.accent.opacity(0.35), lineWidth: 1))
                }
                .accessibilityLabel("open terminal to answer")
            }
        }
    }

    private func prompt(for id: AgentThreadID) -> AgentActionPrompt? {
        guard let snapshot = model.threadSnapshots[id] else { return nil }
        return snapshot.messages.reversed().flatMap(\.blocks).compactMap { block in
            if case .actionPrompt(let prompt) = block { return prompt }
            return nil
        }.first
    }

    private func identity(for summary: AgentThreadSummary) -> String {
        var values = [summary.providerName]
        if let project = summary.projectBasename { values.append(project) }
        if let branch = summary.branch { values.append(branch) }
        if summary.isFork { values.append("fork") }
        return values.joined(separator: " · ")
    }

    @ViewBuilder
    private func meter(for summary: AgentThreadSummary) -> some View {
        HStack(spacing: 7) {
            if let percent = summary.context.percentUsed {
                GeometryReader { proxy in
                    Capsule().fill(T.border)
                        .overlay(alignment: .leading) {
                            Capsule().fill(percent > 60 ? T.amber : T.fgDim)
                                .frame(width: proxy.size.width * max(0, min(percent, 100)) / 100)
                        }
                }
                .frame(width: 86, height: 3)
                Text("\(Int(percent))%")
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgFaint)
            } else if let count = summary.context.compactTokenCount {
                Text("\(count) tokens")
                    .foregroundStyle(T.fgFaint)
            } else if let added = summary.cost.linesAdded, let removed = summary.cost.linesRemoved {
                Text("+\(added)").foregroundStyle(T.green)
                Text("−\(removed)").foregroundStyle(T.red)
            }
        }
        .font(Typography.tesseraMono(size: 9))
        .frame(minHeight: 11)
    }

    private func statusDot(for summary: AgentThreadSummary) -> some View {
        Circle()
            .fill(statusColor(summary))
            .frame(width: 7, height: 7)
            .shadow(color: statusColor(summary).opacity(0.6), radius: summary.status == .working ? 4 : 0)
    }

    private func statusColor(_ summary: AgentThreadSummary) -> Color {
        if summary.attention == .needsYou { return T.amber }
        switch summary.status {
        case .working: return T.green
        case .finished: return T.green
        case .idle, .unavailable: return T.fgFaint
        case .waitingForInput: return T.amber
        }
    }

    @ViewBuilder
    private func age(_ date: Date?) -> some View {
        if let date {
            Text(date, style: .relative)
                .font(Typography.tesseraMono(size: 9))
                .foregroundStyle(T.fgDim)
        }
    }

    private var groupedRows: [AgentThreadListSection] {
        AgentThreadListSection.sections(for: model.listSnapshot.threads, grouping: model.grouping)
    }
}

/// One list section. Its identity is its category (or host), never its
/// position, and its rows are keyed by section as well as thread. A pinned
/// lazy stack that saw a thread's id move from one section to another kept
/// drawing the row it first built there: stale content that took no taps.
struct AgentThreadListSection: Identifiable {
    struct Row: Identifiable {
        struct Key: Hashable {
            let section: String
            let thread: AgentThreadID
        }

        let id: Key
        let summary: AgentThreadSummary
    }

    let title: String
    let rows: [AgentThreadSummary]
    let isUrgent: Bool
    var id: String { title }

    var keyedRows: [Row] {
        rows.map { Row(id: .init(section: id, thread: $0.id), summary: $0) }
    }

    /// A section move shows a thread under its new key before or after it
    /// hides the old one, in no fixed order. A card is visible while any of
    /// its keys is.
    struct Visibility {
        private(set) var keys = Set<Row.Key>()

        /// The thread's new visibility when this key changes it, else nil.
        mutating func set(_ key: Row.Key, visible: Bool) -> Bool? {
            let wasVisible = keys.contains { $0.thread == key.thread }
            if visible { keys.insert(key) } else { keys.remove(key) }
            let isVisible = keys.contains { $0.thread == key.thread }
            return isVisible == wasVisible ? nil : isVisible
        }
    }

    /// Attention grouping puts each thread in exactly one section, the first
    /// that applies: needs you, working, finished, recent.
    static func sections(for rows: [AgentThreadSummary], grouping: AgentListGrouping) -> [AgentThreadListSection] {
        switch grouping {
        case .attention:
            let needsYou = rows.filter { $0.attention == .needsYou }
            let working = rows.filter { $0.attention != .needsYou && $0.status == .working }
            let finished = rows.filter { $0.attention == .unreadCompletion && $0.status != .working }
            let recent = rows.filter { $0.attention == .none && $0.status != .working }
            return [
                AgentThreadListSection(title: "needs you", rows: needsYou, isUrgent: true),
                AgentThreadListSection(title: "working", rows: working, isUrgent: false),
                AgentThreadListSection(title: "finished", rows: finished, isUrgent: false),
                AgentThreadListSection(title: "recent", rows: recent, isUrgent: false),
            ].filter { !$0.rows.isEmpty }
        case .host:
            return Dictionary(grouping: rows, by: \.hostDisplayLabel)
                .sorted { $0.key < $1.key }
                .map { AgentThreadListSection(title: $0.key, rows: $0.value, isUrgent: false) }
        }
    }
}
