import SwiftUI
import UIKit
import TesseraCore

struct AgentThreadDetailView: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let isCompact: Bool
    /// The viewer above the fold on a laptop-folded Duo. It draws its own
    /// title row (there is no navigation bar) and leaves its composer to the
    /// laptop layout, which docks it on the hinge.
    var isLaptopViewer = false
    @State private var presentation = AgentThreadPresentationState()
    @State private var presentationThreadID: AgentThreadID?
    @State private var presentationOwner = UUID()
    @State private var positionedPresentation = false
    @State private var restoredAnchorID: String?
    @State private var restoredAnchorFraction: CGFloat?
    @State private var pagingEnabled = true
    @Environment(AgentThreadPresentationStore.self) private var presentationStore: AgentThreadPresentationStore?
    @State private var nearHistoryEdge = false
    @State private var nearNewerEdge = false
    @State private var atNewest = true
    @State private var transcriptSize = CGSize.zero
    // Rendered rows extend before the reader reaches their edge.
    @State private var nearRenderedTop = false
    @State private var nearRenderedBottom = false
    // A rendered edge inside the viewport while more rows are retained.
    @State private var renderedTopVisible = false
    @State private var renderedBottomVisible = false
    // Rendered rows are shorter than the viewport: nothing can be scrolled
    // to ask for history, so older pages load without a pan.
    @State private var underfilled = false
    @State private var anchorKeeper = AgentTranscriptAnchorKeeper()
    @State private var followPulse = AgentFollowPulse()
    /// Counts changes the follow pass has to see, at most one per turn of the
    /// main queue (`AgentFollowPulse`).
    @State private var followGeneration = 0
    /// The row the reader is on when the scroll position names another (a
    /// landing, a move without a pan); it reports its frame for the save.
    @State private var readingFrameRowID: String?
    @State private var blockDisclosures = AgentBlockDisclosures()
    @State private var promptCard: AgentPromptCardFrame?
    /// The prompt whose landing was decided; each lands at most once.
    @State private var decidedPromptToken: AgentActionToken?
    /// Landings asked again after one waited under a finger.
    @State private var promptLandingAttempt = 0
    /// The search match just landed on, marked for a moment.
    @State private var searchHighlightRowID: String?
    @Environment(\.designTokens) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.duoRailMode) private var duoRailMode
    @Environment(\.duoOpenSwitcher) private var openSwitcher
    @Environment(\.duoWorkspace) private var duoWorkspace

    /// Eager layout cost is proportional to rendered content, not retained
    /// history. The shared window may retain thousands of records; revealing
    /// retained rows needs no network round trip. Budgets are estimated
    /// layout cost (see `layoutCost`): a reveal chunk is a few rich Markdown
    /// rows or dozens of collapsed tool runs, so each stays within a frame
    /// or two instead of one long hitch.
    static let renderedCostBudget = debugRowSetting("TESSERA_AGENT_RENDERED_COST") ?? 32_000
    static let renderedCostChunk = debugRowSetting("TESSERA_AGENT_RENDERED_CHUNK_COST") ?? 4_000
    /// Older pages a short transcript may ask for before it fills.
    static let fillPageLimit = 8

    private static func debugRowSetting(_ name: String) -> Int? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[name].flatMap(Int.init).map { max(1, $0) }
        #else
        return nil
        #endif
    }

    var body: some View {
        Group {
            if let thread = model.selectedThreadForDetail {
                if isLaptopViewer {
                    conversation(thread)
                } else {
                    VStack(spacing: 0) {
                        conversation(thread)
                        AgentThreadComposerSlot(model: model, thread: thread, isCompact: isCompact)
                    }
                }
            } else if let candidate = model.selectedCandidate {
                if isLaptopViewer {
                    // Laptop pose has no tab bar: every viewer state keeps
                    // the title's ⌄, the only touch route to another section.
                    VStack(spacing: 0) {
                        laptopSectionTitleRow
                        candidateDetail(candidate)
                    }
                } else {
                    candidateDetail(candidate)
                }
            } else if isLaptopViewer, model.listSnapshot.threads.isEmpty, model.listSnapshot.candidates.isEmpty {
                laptopEmptyState
            } else if isLaptopViewer {
                VStack(spacing: 0) {
                    laptopSectionTitleRow
                    ContentUnavailableView("select a thread", systemImage: "bubble.left.and.bubble.right")
                }
            } else {
                ContentUnavailableView("select a thread", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .background(T.panelBg)
        .onChange(of: model.selectedThreadForDetail?.summary.id, initial: true) { _, _ in
            restorePresentation()
        }
        .onAppear { restorePresentation() }
        .onChange(of: model.latestOpening) { _, opening in
            if let opening, opening == presentationThreadID { openAtLatest(opening) }
        }
        .onDisappear {
            if let presentationThreadID {
                presentationStore?.unmountReader(for: presentationThreadID, owner: presentationOwner)
            }
            presentationThreadID = nil
        }
        .navigationTitle(duoRailMode || isLaptopViewer ? "" : isCompact ? model.selectedThreadForDetail?.summary.title ?? model.selectedCandidate?.title ?? "threads" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(duoRailMode ? .hidden : .automatic, for: .navigationBar)
        .ignoresSafeArea(.container, edges: duoRailMode ? .top : [])
        .toolbar {
            if duoRailMode {
                AgentRailToolbar(
                    items: railItems,
                    onOpenSwitcher: { openSwitcher?() },
                    onToggleContext: { duoWorkspace?.toggleContext() },
                    contextShown: duoWorkspace?.isContextShown == true,
                    onStop: { model.interruptSelectedThread() },
                    onFork: {
                        if let id = model.selectedThreadForDetail?.summary.id { model.openLaunch(.fork(id)) }
                    }
                )
            } else if isCompact, !isLaptopViewer, let thread = model.selectedThreadForDetail {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if thread.summary.status == .working && thread.summary.availability.actions {
                        Button { model.onAction?(.interrupt(thread.summary.id)) } label: { Image(systemName: "stop") }
                            .accessibilityIdentifier("agent-center-v2-interrupt").accessibilityLabel("interrupt")
                    }
                    if thread.summary.availability.fork {
                        Button { model.openLaunch(.fork(thread.summary.id)) } label: { Image(systemName: "arrow.triangle.branch") }
                            .accessibilityIdentifier("agent-center-v2-fork").accessibilityLabel("fork thread")
                    }
                    Button { model.onAction?(.openTerminal(thread.summary.id)) } label: { Image(systemName: "terminal") }
                        .accessibilityIdentifier("agent-center-v2-open-terminal").accessibilityLabel("open terminal")
                }
            }
        }
        .onAppear {
            model.updatePromptKeyboardFocus()
        }
        .overlay(alignment: .topLeading) {
            #if DEBUG
            AgentCenterV2HarnessAccessibilityMarker(identifier: "agent-center-v2-thread-detail")
            #endif
        }
    }

    /// The thread's header, read status and transcript, above its composer.
    private func conversation(_ thread: AgentThreadSnapshot) -> some View {
        VStack(spacing: 0) {
            threadHeader(thread)
            if let status = model.visibleReadStatus(for: thread) {
                HStack {
                    Text(status.message)
                        .font(Typography.tesseraMono(size: 11)).foregroundStyle(T.fgDim)
                        .accessibilityIdentifier("agent-center-v2-read-status")
                    Spacer(minLength: 4)
                    if !status.isProgress {
                        Button("Retry") { model.onAction?(.returnToLatest(thread.summary.id)) }
                            .font(Typography.tesseraMono(size: 11)).foregroundStyle(T.fg)
                            .frame(minHeight: 44)
                            .disabled(model.loadingTranscriptThreads.contains(thread.summary.id))
                            .accessibilityIdentifier("agent-center-v2-read-retry")
                    }
                }
                .padding(.horizontal, isCompact ? 16 : 22)
            }
            if presentationThreadID == thread.summary.id {
                liveConversation(thread)
            } else {
                Color.clear
            }
            returnToLatestFooter(thread)
        }
    }

    /// The laptop viewer's title row: there is no navigation bar above it.
    private func laptopTitleRow(_ thread: AgentThreadSnapshot) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(statusColor(thread.summary))
                .frame(width: 7, height: 7)
                .padding(.trailing, 8)
                .accessibilityHidden(true)
            AgentLaptopTitle(title: Text(thread.summary.title))
            Spacer(minLength: 4)
            if thread.summary.status == .working && thread.summary.availability.actions {
                Button { model.onAction?(.interrupt(thread.summary.id)) } label: {
                    Image(systemName: "stop").frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("agent-center-v2-interrupt")
                .accessibilityLabel("interrupt")
            }
            if thread.summary.availability.fork {
                Button { model.openLaunch(.fork(thread.summary.id)) } label: {
                    Image(systemName: "arrow.triangle.branch").frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("agent-center-v2-fork")
                .accessibilityLabel("fork thread")
            }
            Button { model.onAction?(.openTerminal(thread.summary.id)) } label: {
                Image(systemName: "terminal").frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("agent-center-v2-open-terminal")
            .accessibilityLabel("open terminal")
        }
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(T.fgMuted)
        .padding(.trailing, -10)
    }

    /// The viewer's title row with no thread open: the section's name and ⌄.
    private var laptopSectionTitleRow: some View {
        HStack(spacing: 0) {
            AgentLaptopTitle(title: Text("agents"))
            Spacer(minLength: 4)
        }
        .frame(minHeight: 44)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
    }

    /// No threads yet: the viewer offers a new agent, and the list keeps its
    /// place on the desk, empty, so nothing moves when the first one arrives.
    private var laptopEmptyState: some View {
        VStack(spacing: 0) {
            // New agent sits in the empty state below and on the desk's header.
            laptopSectionTitleRow
            ContentUnavailableView {
                Label("no threads", systemImage: "sparkles")
            } description: {
                Text("Connected hosts with agent transcripts appear here.")
            } actions: {
                Button { model.openLaunch(.spawn) } label: {
                    Label("new agent", systemImage: "plus")
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .foregroundStyle(T.accent)
                        .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.accent.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-center-v2-laptop-empty-new")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusColor(_ summary: AgentThreadSummary) -> Color {
        if summary.attention == .needsYou { return T.amber }
        switch summary.status {
        case .working, .finished: return T.green
        case .waitingForInput: return T.amber
        case .idle, .unavailable: return T.fgFaint
        }
    }

    private static func holdsPrompt(_ item: AgentTranscriptItem, token: AgentActionToken) -> Bool {
        guard case .message(let part) = item else { return false }
        return part.blocks.contains { if case .actionPrompt(let prompt) = $0 { prompt.token == token } else { false } }
    }

    /// A notification opens the newest reply rather than the place the
    /// reader kept (`latestOpening`), as Return to latest does.
    private func openAtLatest(_ threadID: AgentThreadID) {
        presentation.followingLatest = true
        presentation.historyDemand = ""; presentation.automaticPages = 0
        presentation.historyDemandGeneration += 1
        model.finishLatestOpening(threadID)
    }

    private func restorePresentation() {
        let thread = model.selectedThreadForDetail
        guard presentationThreadID != thread?.summary.id else { return }
        if let presentationThreadID {
            presentationStore?.unmountReader(for: presentationThreadID, owner: presentationOwner)
        }
        presentationThreadID = thread?.summary.id
        guard let thread else { return }
        let saved = presentationStore?.mountReader(for: thread.summary.id, owner: presentationOwner,
            snapshot: { [state = $presentation, keeper = anchorKeeper, disclosures = blockDisclosures] in
                var held = keeper.reading(state.wrappedValue)
                held.expandedBlocks = disclosures.expanded
                return held
            })
        presentation = saved ?? AgentThreadPresentationState(followingLatest: thread.ingestionWindow?.atLiveHead != false)
        if model.latestOpening == thread.summary.id { openAtLatest(thread.summary.id) }
        blockDisclosures.expanded = presentation.expandedBlocks
        restoredAnchorID = presentation.followingLatest ? nil : presentation.visibleRowID
        restoredAnchorFraction = presentation.followingLatest ? nil : presentation.visibleRowFraction
        positionedPresentation = false
        // A retained pan is not a new history request. A fresh gesture or an
        // actual page update resumes it, with its old counters and backoff.
        pagingEnabled = saved?.positionedThread != thread.summary.id
        nearHistoryEdge = false; nearNewerEdge = false
        nearRenderedTop = false; nearRenderedBottom = false
        renderedTopVisible = false; renderedBottomVisible = false
        underfilled = false
        atNewest = presentation.followingLatest
        transcriptSize = .zero
        anchorKeeper.reset()
    }

    private var railItems: [AgentRailPolicy.Entry] {
        guard let thread = model.selectedThreadForDetail else {
            return AgentRailPolicy.items(screen: .candidate, hasSwitcher: openSwitcher != nil)
        }
        let hasForkTarget = thread.binding.map { binding in
            model.launchTargets.contains { $0.id == binding.liveSessionID && $0.providerIDs.contains(thread.summary.id.providerID) }
        } == true
        return AgentRailPolicy.threadItems(
            thread, hasSwitcher: openSwitcher != nil,
            hasContext: duoWorkspace.map { $0.arrangement != .single } == true, hasForkTarget: hasForkTarget
        )
    }

    private func candidateDetail(_ candidate: AgentTerminalCandidate) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .foregroundStyle(candidate.fallback.status == .waitingForInput ? T.amber : T.fgMuted)
                    .frame(width: 26, height: 26)
                    .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(Typography.tesseraMono(size: isCompact ? 14 : 15, weight: .medium))
                        .foregroundStyle(T.fg)
                        .lineLimit(1)
                    Text("\(candidate.providerName) · \(candidate.fallback.location)")
                        .font(Typography.tesseraMono(size: 9.5))
                        .foregroundStyle(T.fgMuted)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    model.onAction?(.openCandidateTerminal(candidate.id))
                } label: {
                    Label(isCompact ? "terminal" : "open pane", systemImage: "terminal")
                        .font(Typography.tesseraMono(size: 10))
                        .padding(.horizontal, 8)
                        .frame(minHeight: isCompact ? 44 : 36)
                        .foregroundStyle(T.accent)
                        .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.horizontal, isCompact ? 16 : 22)
            .padding(.vertical, isCompact ? 9 : 16)
            .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("This live agent has no proven provider conversation identity. Transcript history, search, cost, changes, spawn, and fork remain unavailable.")
                        .font(Typography.tesseraMono(size: 10.5))
                        .foregroundStyle(T.fgDim)
                    if let prompt = candidate.fallback.prompt,
                       AgentCenterV2CandidateActionPolicy.canAnswer(candidate.fallback.binding) {
                        Text(prompt.title)
                            .font(Typography.tesseraMono(size: 12, weight: .medium))
                            .foregroundStyle(T.fg)
                        ForEach(prompt.options) { option in
                            Button {
                                model.onAction?(.answerCandidate(
                                    candidateID: candidate.id,
                                    token: prompt.token,
                                    optionID: option.id
                                ))
                            } label: {
                                Text(option.label)
                                    .font(Typography.tesseraMono(size: 11))
                                    .frame(maxWidth: .infinity, minHeight: isCompact ? 44 : 38, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .background(option.isDefault ? T.accentSoft : T.inputBgSoft, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(option.isDefault ? T.accent.opacity(0.35) : T.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    } else if candidate.fallback.prompt != nil {
                        Button {
                            model.onAction?(.openCandidateTerminal(candidate.id))
                        } label: {
                            Label("Open terminal to answer", systemImage: "terminal")
                                .font(Typography.tesseraMono(size: 10.5))
                                .frame(maxWidth: .infinity, minHeight: isCompact ? 44 : 38)
                                .foregroundStyle(T.accent)
                                .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                    if !candidate.fallback.liveTail.isEmpty {
                        Text(candidate.fallback.liveTail)
                            .font(Typography.tesseraMono(size: 10.5))
                            .foregroundStyle(T.fgMuted)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, isCompact ? 16 : 22)
                .padding(.vertical, 14)
            }
        }
    }

    private func threadHeader(_ thread: AgentThreadSnapshot) -> some View {
        VStack(alignment: .leading, spacing: isLaptopViewer ? 2 : 8) {
            if isLaptopViewer {
                laptopTitleRow(thread)
            } else if !isCompact {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(thread.summary.attention == .needsYou ? T.amber : thread.summary.status == .finished ? T.green : T.fgMuted)
                    .frame(width: 26, height: 26)
                    .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border, lineWidth: 1))
                Text(thread.summary.title)
                    .font(Typography.tesseraMono(size: isCompact ? 14 : 15, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if thread.summary.status == .working && thread.summary.availability.actions {
                    Button { model.onAction?(.interrupt(thread.summary.id)) } label: {
                        Image(systemName: "stop").frame(width: 44, height: 44)
                    }
                    .accessibilityIdentifier("agent-center-v2-interrupt")
                    .accessibilityLabel("interrupt")
                }
                if thread.summary.availability.fork {
                    Button { model.openLaunch(.fork(thread.summary.id)) } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .frame(minWidth: isCompact ? 44 : 36, minHeight: isCompact ? 44 : 36)
                    }
                    .accessibilityLabel("fork thread")
                    .accessibilityIdentifier("agent-center-v2-fork")
                }
                Button {
                    model.onAction?(.openTerminal(thread.summary.id))
                } label: {
                    Label(isCompact ? "terminal" : "open pane", systemImage: "terminal")
                        .font(Typography.tesseraMono(size: 10))
                        .padding(.horizontal, 8)
                        .frame(minHeight: isCompact ? 44 : 36)
                        .foregroundStyle(T.accent)
                        .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .accessibilityIdentifier("agent-center-v2-open-terminal")
                .accessibilityLabel("open terminal")
            }
            }
            metadata(thread)
        }
        .padding(.horizontal, isCompact ? 16 : 22)
        .padding(.top, isLaptopViewer ? 0 : 6)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
    }

    @ViewBuilder
    private func metadata(_ thread: AgentThreadSnapshot) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Wrapped at these sizes, the chips stack into a block that leaves
            // the transcript under it next to no room, above a laptop fold
            // none: one line that scrolls sideways keeps every chip readable.
            // Its indicator flashes on appear to show that more chips follow.
            ScrollView(.horizontal) {
                HStack(spacing: 6) { metadataChips(thread) }
            }
            .scrollIndicatorsFlash(onAppear: true)
        } else {
            AgentCenterV2FlowLayout(spacing: 6) { metadataChips(thread) }
        }
    }

    private func metadataChips(_ thread: AgentThreadSnapshot) -> some View {
        Group {
            metaChip("\(thread.summary.providerName)\(thread.summary.model.map { " · \($0)" } ?? "")")
            if thread.summary.permissionMode != .unavailable {
                metaChip(thread.summary.permissionMode.label, tint: modeColor(thread.summary.permissionMode))
            }
            if let project = thread.summary.projectBasename { metaChip(project + (thread.summary.branch.map { " · \($0)" } ?? "")) }
            if let binding = thread.binding {
                metaChip(location(for: binding))
            }
            if let percent = thread.summary.context.percentUsed {
                metaChip("\(Int(percent))% ctx")
            } else if let count = thread.summary.context.compactTokenCount {
                metaChip(String(localized: "\(count) tokens"))
            }
            if let cost = thread.summary.cost.totalCost { metaChip("$\(cost.formatted())") }
            if thread.summary.isFork { metaChip("fork", tint: T.accent) }
        }
    }

    private func metaChip(_ label: String, tint: Color? = nil) -> some View {
        Text(label)
            .font(Typography.tesseraMono(size: 9.5))
            .foregroundStyle(tint ?? T.fgMuted)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((tint ?? T.border).opacity(tint == nil ? 0 : 0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(tint?.opacity(0.35) ?? T.border, lineWidth: 1))
    }

    private func liveConversation(_ thread: AgentThreadSnapshot) -> some View {
        let items = model.transcriptItems(for: thread.messages)
        var usedKeys: Set<String> = []
        let displayItems: [TranscriptDisplayItem] = items.flatMap { item in
            let candidate: String
            if case .toolRun(let run) = item {
                candidate = run.entries.compactMap { presentation.toolRunAnchors[$0.id] }.first ?? item.id
            } else { candidate = item.id }
            let key = usedKeys.insert(candidate).inserted ? candidate : item.id
            let header = TranscriptDisplayItem(id: key, item: item)
            guard case .toolRun(let run) = item,
                  run.entries.contains(where: { presentation.expandedToolEntries.contains($0.id) }) else { return [header] }
            // Each expanded entry owns a top-level lazy key, preserving scroll
            // anchors when older tool activity merges into the run's beginning.
            return [header] + run.entries.map { entry in
                TranscriptDisplayItem(id: "agent-tool-detail:\(entry.id)", item: .message(.init(
                    recordID: entry.recordID, role: entry.role, displayTime: entry.displayTime,
                    blocks: [entry.block], firstBlockIndex: entry.blockIndex
                )))
            }
        }
        let rendered = thread.ingestionWindow == nil ? displayItems.indices : renderedRange(of: displayItems)
        let renderedItems = displayItems[rendered]
        let rendersNewest = rendered.upperBound == displayItems.count
        // A send the transcript already shows is that transcript row; its
        // local bubble would repeat it under the newest reply.
        let outgoing = (thread.outgoingMessages ?? []).filter { $0.status != .observed }
        let tailID = outgoing.last.map { "agent-outgoing:\($0.id)" } ?? thread.messages.last.map { "agent-tail:\($0.recordID)" }
        let canAnswer = thread.summary.availability.actions
            && thread.binding.map(AgentCenterV2CandidateActionPolicy.canAnswer) == true
        let loading = model.loadingTranscriptThreads.contains(thread.summary.id)
        let pagesForward = thread.ingestionWindow == nil && [AgentProviderID.pi, .opencode].contains(thread.summary.id.providerID)
        // Filling a short viewport stops before the window would trim its
        // live head to admit another older page, and waits out a failed
        // read: asking again would clear the failure and its Retry. Rows
        // that collapse into one tool run could otherwise read every page.
        let pagesToFill = underfilled && presentation.fillPages < Self.fillPageLimit && thread.ingestionWindow?.olderPageFits == true
            && model.ingestionReadStatuses[thread.summary.id]?.isProgress != false
            && !model.ingestionCapacityThreads.contains(thread.summary.id)
        anchorKeeper.pinsBottom = presentation.followingLatest && rendersNewest
            && (thread.ingestionWindow?.atLiveHead != false || !outgoing.isEmpty)
        return GeometryReader { viewport in
        let _ = followPulse.note(AgentFollowInputs(content: transcriptSize, viewport: viewport.size,
                                                   landing: positionedPresentation ? nil : atNewest,
                                                   following: presentation.followingLatest,
                                                   atLiveHead: thread.ingestionWindow?.atLiveHead != false, tail: tailID)) {
            followGeneration &+= 1
        }
        ScrollViewReader { proxy in
            ScrollView {
                // The shared window already bounds retained rows. Eager
                // placement avoids SwiftUI lazy-placement feedback while
                // the anchor keeper holds the reader's row across reveals,
                // releases and segment eviction.
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(renderedItems) { row in
                        Group {
                            switch row.item {
                            case .message(let part):
                                AgentMessageView(message: part.message, model: model,
                                                 promptActionsAvailable: canAnswer, isCompact: isCompact,
                                                 artifactHostID: thread.summary.id.hostID,
                                                 artifactSessionID: thread.binding?.liveSessionID,
                                                 firstBlockIndex: part.firstBlockIndex)
                                    .equatable()
                            case .toolRun(let run):
                                AgentToolRunView(run: run,
                                    expanded: run.entries.contains { presentation.expandedToolEntries.contains($0.id) },
                                    onToggle: {
                                        let ids = Set(run.entries.map(\.id))
                                        if run.entries.contains(where: { presentation.expandedToolEntries.contains($0.id) }) {
                                            presentation.expandedToolEntries.subtract(ids)
                                        } else { presentation.expandedToolEntries.formUnion(ids) }
                                    })
                                    .equatable()
                            }
                        }
                            // Keep gutters inside each scroll target. An
                            // outer lazy-stack gutter lets scrollPosition
                            // shift the horizontal offset when anchoring a
                            // prepended row, even in a vertical ScrollView.
                            .padding(.horizontal, isCompact ? 16 : 22)
                            .background {
                                if row.id == presentation.visibleRowID {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: AgentTranscriptAnchorPreference.self,
                                            value: AgentTranscriptAnchorFrame(id: row.id, minY: geometry.frame(in: .named("agent-rows")).minY,
                                                                              height: geometry.size.height,
                                                                              top: geometry.frame(in: .named("agent-row-stack")).minY))
                                    }
                                } else if row.id == readingFrameRowID {
                                    GeometryReader { geometry in
                                        let top = geometry.frame(in: .named("agent-row-stack")).minY
                                        Color.clear.preference(key: AgentTranscriptReadingFramePreference.self,
                                            value: AgentTranscriptAnchorFrame(id: row.id, minY: top, height: geometry.size.height, top: top))
                                    }
                                }
                            }
                            .background {
                                if row.id == searchHighlightRowID {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.inputBgSoft)
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.border, lineWidth: 1))
                                        .padding(.horizontal, isCompact ? 8 : 12).padding(.vertical, -3)
                                        .transition(.opacity)
                                }
                            }
                            .id(row.id)
                    }
                    if rendersNewest, let recordID = thread.messages.last?.recordID {
                        Color.clear.frame(height: 1)
                            .id("agent-tail:\(recordID)")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: AgentTranscriptTailPreference.self,
                                    value: geometry.frame(in: .named("agent-transcript")))
                            })
                    }
                    if rendersNewest, let preview = thread.livePreview {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preview.hasGap ? "live preview · awaiting missing text" : "live preview · syncing transcript")
                                .font(Typography.tesseraMono(size: 9.5)).foregroundStyle(T.fgDim)
                            Text(preview.text).font(Typography.tesseraMono(size: 11.5)).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, isCompact ? 16 : 22)
                        .id("agent-live-preview")
                        .accessibilityIdentifier("agent-center-v2-live-preview")
                    }
                    ForEach(rendersNewest ? outgoing : []) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.text).font(Typography.tesseraMono(size: 11.5)).textSelection(.enabled)
                            Text(outgoingLabel(message.status)).font(Typography.tesseraMono(size: 9.5))
                        }
                        .foregroundStyle(T.fgDim)
                        .padding(10)
                        .frame(maxWidth: isCompact ? 320 : 560, alignment: .leading)
                        .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 9))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("agent-center-v2-outgoing-\(message.status.rawValue)")
                        .padding(.horizontal, isCompact ? 16 : 22)
                        .id("agent-outgoing:\(message.id)")
                    }
                    if pagesForward {
                        AgentTranscriptLoadingGlyph(loading: loading && thread.hasMore)
                            .frame(maxWidth: .infinity).frame(height: 24)
                    }
                    if let window = thread.ingestionWindow, !window.atLiveHead || model.ingestionCapacityThreads.contains(thread.summary.id) {
                        if model.ingestionCapacityThreads.contains(thread.summary.id) {
                            Text("Live updates paused while this history view is retained.")
                                .font(Typography.tesseraMono(size: 11)).foregroundStyle(T.fgDim)
                        }
                    }
                    Color.clear.frame(height: 1).id("agent-conversation-bottom")
                }
                .scrollTargetLayout()
                .padding(.vertical, 8)
                .padding(.top, 24)
                // The transcript bounds' own origin, which a change of the
                // viewport's height does not move.
                .coordinateSpace(name: "agent-row-stack")
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AgentTranscriptBoundsPreference.self,
                        value: .init(thread: thread.summary.id, frame: geometry.frame(in: .named("agent-transcript"))))
                })
                .background {
                    AgentTranscriptScrollProbe(anchorKeeper: anchorKeeper) { direction, began in
                        pagingEnabled = true
                        anchorKeeper.landedRowID = nil
                        if direction == "before" { presentation.followingLatest = false }
                        else if atNewest { presentation.followingLatest = true }
                        if began || direction != presentation.historyDemand || presentation.automaticPages >= 4 {
                            presentation.automaticPages = 0
                            presentation.historyDemandGeneration += 1
                        }
                        presentation.historyDemand = direction
                    }.allowsHitTesting(false)
                    // Selected text here gains the terminal's path actions.
                    AgentTranscriptSelectionScope(model: model, threadID: thread.summary.id)
                }
                // A transcript shorter than the viewport rests on the
                // composer, and grows upward from there.
                .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .bottom)
                // Scroll-invariant row positions: only layout moves them.
                // Measured on the bottom-aligned frame, so a short
                // transcript's rows move up as it grows; the anchor keeper
                // clamps any shift that implies to the scrollable range.
                .coordinateSpace(name: "agent-rows")
            }
            .coordinateSpace(name: "agent-transcript")
            .environment(\.agentBlockDisclosures, blockDisclosures)
            .accessibilityIdentifier("agent-center-v2-transcript")
            // A row written here starts the viewport. Without an anchor
            // SwiftUI scrolls the least amount to it, which leaves a row
            // taller than the viewport, above it, showing its end (a search
            // match on a phone or a narrow Duo pane). The top row is still
            // the one reported.
            .scrollPosition(id: $presentation.visibleRowID, anchor: .top)
            // The scroll position follows only the reader's own scrolling.
            // Visibility follows every move: a landing, VoiceOver, a keyboard.
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                let visible = Set(ids)
                let reading = anchorKeeper.see(renderedItems.compactMap { visible.contains($0.id) ? $0.id : nil },
                                               scrollRow: presentation.visibleRowID)
                if readingFrameRowID != reading { readingFrameRowID = reading }
            }
            .onChange(of: AgentWindowPlacement(thread: thread.summary.id, atLiveHead: thread.ingestionWindow?.atLiveHead),
                      initial: true) { old, new in
                // An initial callback after restoration must not turn a held
                // read into a newly opened detached window. An actual window
                // transition while hidden still follows the existing policy.
                let restored = old == new && presentation.positionedThread == new.thread
                if restored, presentation.windowAtLiveHead == new.atLiveHead { return }
                defer { presentation.windowAtLiveHead = new.atLiveHead }
                // A seek's page is placed by its search landing; one opened
                // later is placed as any window away from the head.
                if thread.ingestionWindow?.transition == .seek, model.searchLanding?.threadID == thread.summary.id {
                    presentation.followingLatest = false
                    return
                }
                let opened = !restored && (old == new || old.thread != new.thread)
                if opened { presentation.renderedLowerID = nil; presentation.renderedUpperID = nil }
                guard new.atLiveHead == false else {
                    // Newer paging reached the head under a following reader.
                    if presentation.followingLatest { presentation.renderedLowerID = nil; presentation.renderedUpperID = nil }
                    return
                }
                if !opened, presentation.followingLatest, let lane = thread.ingestionWindow?.transition, lane == .revisions || lane == .head {
                    // The window left the head under a following reader,
                    // across more rows than Core bridges (`bridgesToHead`).
                    // Take them back to it rather than onto history.
                    model.onAction?(.returnToLatest(thread.summary.id))
                    return
                }
                presentation.followingLatest = false
                anchorKeeper.landedRowID = nil
                guard !displayItems.isEmpty else { return }
                if opened {
                    // A window opened away from the live head starts at its
                    // oldest retained row, as the whole window did before
                    // rendering was bounded.
                    var upper = 0, cost = 0
                    while upper < displayItems.count, cost < Self.renderedCostBudget {
                        cost += Self.layoutCost(displayItems[upper]); upper += 1
                    }
                    pinRenderedRange(displayItems, 0..<upper)
                } else if !rendered.isEmpty {
                    // A reader already here keeps their rows, and newer pages
                    // no longer append to a range that ended at the head.
                    pinRenderedRange(displayItems, rendered)
                }
            }
            // A search result opens at its match once the transcript holds
            // it and no read can move the window off it: the row starts the
            // viewport, marked for a moment, and the reader keeps it while the
            // head rolls. It is placed after this update's other handlers (a
            // new thread's restore, its placement).
            .onChange(of: AgentSearchLandingAttempt(
                landing: model.searchLanding?.threadID == thread.summary.id ? model.searchLanding : nil,
                restored: presentationThreadID == thread.summary.id, loading: loading,
                version: thread.ingestionWindow?.version, rows: displayItems.count), initial: true) { _, attempt in
                guard let landing = attempt.landing, attempt.restored, !attempt.loading,
                      let index = displayItems.firstIndex(where: { Self.holdsRecord($0.item, landing.recordID) }) else { return }
                model.finishSearchLanding(landing)
                let row = displayItems[index].id
                let range = thread.ingestionWindow == nil ? nil : Self.renderedRange(displayItems, around: index)
                Task { @MainActor in
                    guard presentationThreadID == landing.threadID else { return }
                    presentation.followingLatest = false
                    presentation.historyDemand = ""; presentation.automaticPages = 0
                    if let range { pinRenderedRange(displayItems, range) }
                    restoredAnchorID = row; restoredAnchorFraction = 0
                    presentation.visibleRowID = row
                    anchorKeeper.landedRowID = row
                    positionedPresentation = false
                    followGeneration &+= 1
                    guard landing.marked else { return }
                    withAnimation(.easeOut(duration: 0.2)) { searchHighlightRowID = row }
                    do { try await Task.sleep(for: .seconds(2.4)) } catch { return }
                    guard searchHighlightRowID == row else { return }
                    withAnimation(.easeOut(duration: 0.6)) { searchHighlightRowID = nil }
                }
            }
            .stackBoundary()
            .onPreferenceChange(AgentTranscriptTailPreference.self) { bounds in
                // Eager construction is not visibility. Only a tail actually
                // inside the viewport may acknowledge that the latest was read.
                guard let bounds, bounds.maxY >= 0, bounds.minY <= viewport.size.height,
                      thread.ingestionWindow?.atLiveHead != false, thread.ingestionWindow?.hasNewer != true,
                      let recordID = thread.messages.last?.recordID else { return }
                model.onAction?(.newestRecordVisible(threadID: thread.summary.id, recordID: recordID))
                #if DEBUG
                AgentColdPageFixture.visibleTail(thread: thread.summary.id)
                #endif
            }
            // A finish that adds no record, or lands while the tail is already
            // on screen, moves no tail bounds. Read it whenever the live end is
            // in view; an empty transcript is read on selection.
            .onChange(of: positionedPresentation && thread.summary.attention == .unreadCompletion && !loading
                        && (thread.messages.isEmpty || (rendersNewest && atNewest))
                        && thread.ingestionWindow?.atLiveHead != false
                        && thread.ingestionWindow?.hasNewer != true
                        ? thread.attentionEpoch : nil, initial: true) { _, epoch in
                guard let epoch else { return }
                model.onAction?(.completionVisible(threadID: thread.summary.id, attentionEpoch: epoch))
            }
            // A loading row inside scrollTargetLayout becomes the anchor at
            // the top, pinning the reader to new history instead of their
            // message when a page arrives. Keep it outside the row targets.
            .overlay(alignment: .top) {
                AgentTranscriptLoadingGlyph(loading: loading && thread.hasMore && !pagesForward && nearHistoryEdge)
                    .frame(maxWidth: .infinity).frame(height: 24)
                    .allowsHitTesting(false)
            }
            .onChange(of: AgentPresentationPageIdentity(cursor: thread.cursor, after: thread.ingestionWindow?.after,
                version: thread.ingestionWindow?.version)) { _, _ in pagingEnabled = true }
            .onChange(of: items, initial: true) { _, _ in
                var anchors: [String: String] = [:]
                for row in displayItems {
                    if case .toolRun(let run) = row.item {
                        for entry in run.entries { anchors[entry.id] = row.id }
                    }
                }
                presentation.toolRunAnchors = anchors
            }
            // Rows revealed, released or resized above the reader, and window
            // updates that drop older rows, move the reader's row in content
            // space. SwiftUI's scrollPosition does not hold it through a fling
            // (or at all for eager rows); shift the offset in the same update.
            .onPreferenceChange(AgentTranscriptAnchorPreference.self) { anchorKeeper.observe($0) }
            // Measured only: holding that row is the scroll position's frame's job.
            .onPreferenceChange(AgentTranscriptReadingFramePreference.self) { anchorKeeper.readingFrame = $0 }
            .onPreferenceChange(AgentPromptCardPreference.self) { promptCard = $0 }
            .onChange(of: AgentPromptLandingAttempt(landing: AgentPromptLanding.decide(
                promptCard, decided: decidedPromptToken, waiting: thread.summary.status == .waitingForInput,
                following: presentation.followingLatest && rendersNewest, positioned: positionedPresentation,
                viewportHeight: viewport.size.height
            ), attempt: promptLandingAttempt), initial: true) { _, request in
                guard let landing = request.landing else { return }
                if let rowY = landing.rowY {
                    // Under a finger it waits; the finger lifting decides
                    // again, from the layout and reading state then.
                    guard anchorKeeper.land(atRowY: rowY, margin: AgentPromptLanding.margin,
                                            retry: { promptLandingAttempt += 1 }) else { return }
                    presentation.followingLatest = false
                    // The scroll position reports only the reader's own
                    // scrolling, and setting it scrolls a tall row again. The
                    // keeper keeps the card's row, so a rebuilt detail (book
                    // to laptop) returns to it, not to the conversation's top.
                    anchorKeeper.landedRowID = displayItems.last { Self.holdsPrompt($0.item, token: landing.token) }?.id
                }
                decidedPromptToken = landing.token
            }
            // Keyed by thread: another thread laid out to the same frame
            // still re-derives the edge flags a switch reset.
            .onPreferenceChange(AgentTranscriptBoundsPreference.self) { measured in
                guard let bounds = measured?.frame else { return }
                // The bottom of a partial rendered range is not the newest row.
                atNewest = rendersNewest && bounds.maxY <= viewport.size.height + 40 && bounds.maxY >= 0
                transcriptSize = bounds.size
                // Runs every scroll frame: write the shared presentation only on change.
                if positionedPresentation, atNewest && presentation.historyDemand == "after", !presentation.followingLatest {
                    presentation.followingLatest = true
                }
                nearNewerEdge = bounds.maxY <= viewport.size.height * 2 && bounds.maxY >= 0
                if !nearNewerEdge, positionedPresentation, presentation.requestedNewerCursor != nil { presentation.requestedNewerCursor = nil }
                nearHistoryEdge = pagesForward
                    ? bounds.maxY <= viewport.size.height * 2 && bounds.maxY >= 0
                    : bounds.minY >= -viewport.size.height
                nearRenderedTop = bounds.minY >= -viewport.size.height * 3
                nearRenderedBottom = bounds.maxY <= viewport.size.height * 4
                // Resting on an edge counts: VoiceOver, keyboard and
                // status-bar scrolling stop there without overscrolling.
                renderedTopVisible = bounds.minY > -1
                renderedBottomVisible = bounds.maxY < viewport.size.height + 1
                underfilled = bounds.height < viewport.size.height - 1
                if !underfilled, positionedPresentation, presentation.fillPages != 0 { presentation.fillPages = 0 }
                anchorKeeper.bounds = bounds; anchorKeeper.viewportHeight = viewport.size.height
                if !nearHistoryEdge, positionedPresentation, presentation.requestedCursor != nil
                    || presentation.pageRetryDelay != 1 || presentation.nextPageAttempt != .distantPast {
                    presentation.requestedCursor = nil
                    presentation.pageRetryDelay = 1
                    presentation.nextPageAttempt = .distantPast
                }
            }
            .task(id: AgentChatFollowTrigger(thread: thread.summary.id, inputs: followGeneration)) {
                // Follow the actual end after layout, including same-ID text,
                // regrouped tools, pending bubbles, and keyboard resizing.
                await Task.yield()
                guard !Task.isCancelled, model.selectedThreadForDetail?.summary.id == thread.summary.id else { return }
                if !positionedPresentation, !presentation.followingLatest {
                    // Bounds can have been evicted while hidden. The existing
                    // cost-bounded range already falls back around a survivor.
                    let anchor = restoredAnchorID.flatMap { id in displayItems.contains { $0.id == id } ? id : nil }
                        ?? (rendered.isEmpty ? nil : displayItems[rendered.lowerBound].id)
                    if let anchor {
                        presentation.visibleRowID = anchor
                        // A held reader returns to the same place inside a
                        // long reply, not to its first line. The keeper lands
                        // before positioning below lets paging read the edges;
                        // scrollTo lands on a later layout, and a reveal that
                        // reads the unscrolled top in between brings in rows
                        // the reader never neared.
                        let fraction = anchor == restoredAnchorID ? restoredAnchorFraction : nil
                        if !anchorKeeper.scroll(into: anchor, fraction: fraction ?? 0) {
                            proxy.scrollTo(anchor, anchor: .top)
                            // A row not laid out yet, or a survivor of an
                            // eviction: paging waits for the landing, as for
                            // a follower below. A restart lands it again.
                            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                        }
                    }
                    restoredAnchorID = nil
                    restoredAnchorFraction = nil
                }
                if presentation.followingLatest && (model.selectedThreadForDetail?.ingestionWindow?.atLiveHead != false || !outgoing.isEmpty) {
                    // The keeper already follows layout; scrollTo's anchor
                    // sits above the bottom padding and would fight it.
                    // A follower's own fling or bounce at the end settles
                    // first; opening, Return and a reader carried away by
                    // growth land at once.
                    if anchorKeeper.scroll != nil { anchorKeeper.pinBottom(stoppingScroll: !atNewest) }
                    else { proxy.scrollTo("agent-conversation-bottom", anchor: .bottom) }
                    // Paging waits for the opening scroll to land: until then
                    // the edge geometry describes the unscrolled top, which a
                    // slow first layout can leave in place long enough to page.
                    if presentation.positionedThread != thread.summary.id, !atNewest {
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    }
                }
                // A detached window is ready for paging too. Following the
                // live head is not a prerequisite for displaying history.
                presentation.positionedThread = thread.summary.id
                positionedPresentation = true
            }
            .task(id: AgentHistoryLoadTrigger(threadID: thread.summary.id, cursor: thread.cursor,
                                            nearEdge: pagingEnabled && nearHistoryEdge && (thread.ingestionWindow == nil || presentation.historyDemand == "before" || pagesToFill), loading: loading,
                                            positioned: positionedPresentation && presentation.positionedThread == thread.summary.id, demandGeneration: presentation.historyDemandGeneration,
                                            renderedEdge: rendered.lowerBound)) {
                // Retained rows are revealed locally before asking the host.
                guard thread.ingestionWindow == nil || rendered.lowerBound == 0 else { return }
                let demanded = thread.ingestionWindow == nil || (presentation.historyDemand == "before" && presentation.automaticPages < 4)
                guard pagingEnabled, positionedPresentation, presentation.positionedThread == thread.summary.id, nearHistoryEdge, !loading,
                      demanded || pagesToFill, thread.hasMore, let cursor = thread.cursor else { return }
                // An unchanged cursor can mean a transient read failure or
                // an in-flight refresh. Retry without a button or a tight loop.
                if cursor == presentation.requestedCursor {
                    let wait = max(0, presentation.nextPageAttempt.timeIntervalSinceNow)
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    presentation.pageRetryDelay = min(30, presentation.pageRetryDelay * 2)
                } else { presentation.pageRetryDelay = 1 }
                presentation.requestedCursor = cursor
                presentation.nextPageAttempt = .now.addingTimeInterval(presentation.pageRetryDelay)
                // A fill never spends the pages a history gesture is allowed.
                if demanded {
                    presentation.automaticPages += 1
                    model.onAction?(.requestOlderPage(thread.summary.id))
                } else {
                    presentation.fillPages += 1
                    model.onAction?(.fillOlderPage(thread.summary.id))
                }
            }
            .task(id: AgentHistoryLoadTrigger(threadID: thread.summary.id, cursor: thread.ingestionWindow?.after,
                                            nearEdge: pagingEnabled && nearNewerEdge && presentation.historyDemand == "after", loading: loading,
                                            positioned: positionedPresentation && presentation.positionedThread == thread.summary.id, demandGeneration: presentation.historyDemandGeneration,
                                            renderedEdge: rendered.upperBound)) {
                guard pagingEnabled, positionedPresentation, rendersNewest, presentation.positionedThread == thread.summary.id, nearNewerEdge, !loading,
                      presentation.historyDemand == "after", presentation.automaticPages < 4,
                      let window = thread.ingestionWindow, window.hasNewer, !window.atLiveHead,
                      let cursor = window.after else { return }
                if presentation.requestedNewerCursor == cursor {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                presentation.requestedNewerCursor = cursor
                presentation.automaticPages += 1
                model.onAction?(.requestNewerPage(thread.summary.id))
            }
            // A bridged window reads as live: its newest rows are shown but
            // not retained, so nothing revises them. A follower asks for the
            // newer page that retains them, backing off an unchanged cursor.
            .task(id: AgentBridgeTrigger(thread: thread.summary.id, cursor: thread.ingestionWindow?.bridgesToHead == true
                ? thread.ingestionWindow?.after : nil, version: thread.ingestionWindow?.version,
                following: positionedPresentation && pagingEnabled && presentation.followingLatest, loading: loading)) {
                guard pagingEnabled, positionedPresentation, presentation.followingLatest, !loading, let window = thread.ingestionWindow, window.bridgesToHead == true,
                      let cursor = window.after else { return }
                if cursor == presentation.requestedBridgeCursor {
                    do { try await Task.sleep(for: .seconds(presentation.bridgeRetryDelay)) } catch { return }
                    presentation.bridgeRetryDelay = min(30, presentation.bridgeRetryDelay * 2)
                } else { presentation.bridgeRetryDelay = 1 }
                presentation.requestedBridgeCursor = cursor
                model.onAction?(.retainBridgedRows(thread.summary.id))
            }
            .task(id: AgentRenderedRevealTrigger(threadID: thread.summary.id, rendered: rendered, count: displayItems.count,
                                                 older: nearRenderedTop && demands("before"),
                                                 newer: nearRenderedBottom && demands("after"),
                                                 topVisible: renderedTopVisible, bottomVisible: renderedBottomVisible,
                                                 positioned: positionedPresentation && presentation.positionedThread == thread.summary.id)) {
                // A range pinned since this update rendered is not this one,
                // and its own update restarts this task: the fallback below
                // must not pin this one back over it.
                guard positionedPresentation, thread.ingestionWindow != nil, presentation.positionedThread == thread.summary.id,
                      renderedRange(of: displayItems) == rendered else { return }
                // A rebuilt fallback range becomes the range, so it does not
                // follow the reader's row from frame to frame.
                if !rendered.isEmpty, presentation.renderedLowerID != nil || presentation.renderedUpperID != nil {
                    let bounds = renderedBounds(displayItems, rendered)
                    if bounds.lower != presentation.renderedLowerID || bounds.upper != presentation.renderedUpperID { pinRenderedRange(displayItems, rendered) }
                }
                // An exposed edge is repaired first, whatever the direction,
                // and without releasing rows the reader may be heading for.
                let repairTop = renderedTopVisible && rendered.lowerBound > 0
                let repairBottom = renderedBottomVisible && !rendersNewest
                let older = repairTop || !repairBottom && nearRenderedTop && demands("before") && rendered.lowerBound > 0
                // A reader parked above a growing tail keeps a bounded range:
                // head updates add rows the budget releases from the top.
                let overBudget = displayItems[rendered].reduce(0, { $0 + Self.layoutCost($1) }) > Self.renderedCostBudget + Self.renderedCostChunk
                let trimTop = !older && !repairBottom && !nearRenderedTop && rendersNewest && presentation.renderedLowerID != nil && overBudget
                guard older || repairBottom || trimTop || (nearRenderedBottom && demands("after") && !rendersNewest) else { return }
                // Let the previous reveal's layout report its new edge, and
                // reveal only while the reason holds: an edge still exposed,
                // or demand toward one still near. The keeper's shift over
                // rows just revealed can cover the edge in the same frame,
                // and SwiftUI then does not restart this task. A search
                // landing, placed from a task of its own, can pin its range
                // meanwhile: a reveal from this one would leave its match
                // outside the rendered rows.
                await Task.yield()
                guard !Task.isCancelled, renderedRange(of: displayItems) == rendered, trimTop || (older
                        ? renderedTopVisible || nearRenderedTop && demands("before")
                        : renderedBottomVisible || nearRenderedBottom && demands("after")) else { return }
                // A repair releases only once over budget: it serves readers
                // without pans (VoiceOver, keyboard), whose reveals must not
                // grow the range back to the whole window.
                revealRetainedRows(displayItems, rendered: rendered, older: older,
                                   release: overBudget || (!repairTop && !repairBottom))
            }
            .onChange(of: AgentViewportPinTrigger(rowID: presentation.visibleRowID, followingLatest: presentation.followingLatest), initial: true) { _, pin in
                guard thread.ingestionWindow != nil else { return }
                // A live-following reader must not pin the old rolling page.
                // Only an explicit history-reading gesture owns an anchor,
                // and it always names a row: Core reads no anchor as
                // following, which never trades the live head for history.
                let row = pin.followingLatest ? nil : displayItems.first { $0.id == pin.rowID }
                    ?? (rendered.isEmpty ? nil : displayItems[rendered.lowerBound])
                let recordID: String?
                switch row?.item {
                case .message(let part): recordID = part.recordID
                case .toolRun(let run): recordID = run.entries.first?.recordID
                case nil: recordID = nil
                }
                model.onAction?(.viewportAnchor(threadID: thread.summary.id, recordID: recordID))
            }
            .onChange(of: presentation.followingLatest) { _, following in
                if following { anchorKeeper.landedRowID = nil }
                // Only the live head's tail is followed. The bottom of a
                // detached window is history: newer pages reveal in chunks
                // from the reader's rows rather than jumping to their end.
                if following, thread.ingestionWindow?.atLiveHead != false { presentation.renderedLowerID = nil; presentation.renderedUpperID = nil }
                else if following { if !rendered.isEmpty { pinRenderedRange(displayItems, rendered) } }
                // Hold the reader's rows: newer tail rows must not trim the
                // top of the range under a history read.
                else if presentation.renderedLowerID == nil, thread.ingestionWindow != nil, !rendered.isEmpty {
                    presentation.renderedLowerID = displayItems[rendered.lowerBound].id
                }
            }
            // A new send follows the tail. Watch every send, not the drawn
            // bubbles: a send the transcript showed stops drawing one, and
            // that must not pull a reader out of history.
            .onChange(of: thread.outgoingMessages?.last?.id) { previous, next in
                if next != nil && next != previous {
                    presentation.followingLatest = true; presentation.historyDemand = ""; presentation.automaticPages = 0
                }
            }
        }
        }
    }

    /// The body's rendered range, read again from a task to tell whether a
    /// pin changed it since that update.
    private func renderedRange(of items: [TranscriptDisplayItem]) -> Range<Int> {
        Self.renderedRange(items, lowerID: presentation.renderedLowerID, upperID: presentation.renderedUpperID,
                           anchorID: restoredAnchorID ?? presentation.visibleRowID)
    }

    /// A nil upper ID renders through the newest row; both nil is the live
    /// tail. When a bound's row has left the window (eviction, a rolling
    /// head, a collapsed tool run) the budget is rebuilt around the reader's
    /// row, else the surviving bound: a range is never unbounded.
    private static func renderedRange(_ items: [TranscriptDisplayItem], lowerID: String?, upperID: String?,
                                      anchorID: String?) -> Range<Int> {
        func index(_ id: String?) -> Int? { id.flatMap { id in items.firstIndex { $0.id == id } } }
        let lower = index(lowerID), upper = index(upperID).map { $0 + 1 }
        if lowerID == nil || lower != nil, upperID == nil || upper != nil {
            let end = upper ?? items.count
            if let lower { return min(lower, end)..<end }
            var start = end, cost = 0
            while start > 0, cost < renderedCostBudget { start -= 1; cost += layoutCost(items[start]) }
            return start..<end
        }
        guard let center = index(anchorID) ?? lower ?? upper.map({ $0 - 1 }) else {
            return renderedRange(items, lowerID: nil, upperID: nil, anchorID: nil)
        }
        // The reader sees the rows below their top row first.
        var start = center, end = center + 1, cost = layoutCost(items[center])
        while end < items.count, cost < renderedCostBudget / 2 { cost += layoutCost(items[end]); end += 1 }
        while start > 0, cost < renderedCostBudget { start -= 1; cost += layoutCost(items[start]) }
        while end < items.count, cost < renderedCostBudget { cost += layoutCost(items[end]); end += 1 }
        return start..<end
    }

    /// A pan toward older or newer rows. A retained one is not a new
    /// request (`restorePresentation`): it reveals rows only once a gesture
    /// or a page update resumes paging, as it loads pages.
    private func demands(_ direction: String) -> Bool {
        pagingEnabled && presentation.historyDemand == direction
    }

    /// Extends the rendered range by one cost chunk toward older or newer
    /// rows and releases the far side beyond the budget. Rows within half
    /// the budget past the scroll anchor (the top visible row) are never
    /// released, which covers the viewport even for light rows, and nothing
    /// is released before an anchor exists. Cost only estimates height, so
    /// releases also stay within the measured content past the reveal bands.
    /// The anchor keeper holds the visible row in place.
    private func revealRetainedRows(_ items: [TranscriptDisplayItem], rendered: Range<Int>, older: Bool, release: Bool) {
        var lower = rendered.lowerBound, upper = rendered.upperBound, added = 0
        let anchor = presentation.visibleRowID.flatMap { id in items[rendered].firstIndex { $0.id == id } }
        let renderedCost = items[rendered].reduce(0) { $0 + Self.layoutCost($1) }
        if older {
            while lower > 0, added < Self.renderedCostChunk { lower -= 1; added += Self.layoutCost(items[lower]) }
        } else {
            while upper < items.count, added < Self.renderedCostChunk { added += Self.layoutCost(items[upper]); upper += 1 }
        }
        if release, let anchor, let bounds = anchorKeeper.bounds, anchorKeeper.viewportHeight > 0, renderedCost > 0 {
            var total = renderedCost + added
            var keep = anchor, kept = 0
            let pointsPerCost = bounds.height / CGFloat(renderedCost)
            // Releases stop a viewport past the reveal bands (three above,
            // four below the screen), so a release never re-arms a reveal.
            var spare = older ? bounds.maxY - anchorKeeper.viewportHeight * 5 : -bounds.minY - anchorKeeper.viewportHeight * 4
            if older {
                while keep < upper - 1, kept < Self.renderedCostBudget / 2 { kept += Self.layoutCost(items[keep]); keep += 1 }
                while upper - 1 > keep, total > Self.renderedCostBudget {
                    let cost = Self.layoutCost(items[upper - 1])
                    spare -= CGFloat(cost) * pointsPerCost
                    guard spare >= 0 else { break }
                    upper -= 1; total -= cost
                }
            } else {
                while keep > lower, kept < Self.renderedCostBudget / 2 { kept += Self.layoutCost(items[keep]); keep -= 1 }
                while lower < keep, total > Self.renderedCostBudget {
                    let cost = Self.layoutCost(items[lower])
                    spare -= CGFloat(cost) * pointsPerCost
                    guard spare >= 0 else { break }
                    total -= cost; lower += 1
                }
            }
        }
        guard lower < upper else { return }
        pinRenderedRange(items, lower..<upper)
    }

    /// A range around a landed row: half the budget from it down, for
    /// reading on, then rows above it, for scrolling back.
    private static func renderedRange(_ items: [TranscriptDisplayItem], around index: Int) -> Range<Int> {
        var lower = index, upper = index + 1, cost = layoutCost(items[index])
        while upper < items.count, cost < renderedCostBudget / 2 { cost += layoutCost(items[upper]); upper += 1 }
        while lower > 0, cost < renderedCostBudget { lower -= 1; cost += layoutCost(items[lower]) }
        while upper < items.count, cost < renderedCostBudget { cost += layoutCost(items[upper]); upper += 1 }
        return lower..<upper
    }

    private static func holdsRecord(_ item: AgentTranscriptItem, _ recordID: String) -> Bool {
        switch item {
        case .message(let part): part.recordID == recordID
        case .toolRun(let run): run.entries.contains { $0.recordID == recordID }
        }
    }

    /// Through-the-newest (a nil upper ID) exists only at the live head; a
    /// detached window's newer pages are revealed, never appended.
    private func pinRenderedRange(_ items: [TranscriptDisplayItem], _ range: Range<Int>) {
        (presentation.renderedLowerID, presentation.renderedUpperID) = renderedBounds(items, range)
    }

    private func renderedBounds(_ items: [TranscriptDisplayItem], _ range: Range<Int>) -> (lower: String, upper: String?) {
        let throughNewest = range.upperBound == items.count && model.selectedThreadForDetail?.ingestionWindow?.atLiveHead != false
        return (items[range.lowerBound].id, throughNewest ? nil : items[range.upperBound - 1].id)
    }

    /// Estimated eager layout cost of one row: a fixed view cost plus the
    /// text it lays out. A collapsed tool run shows only its summary;
    /// expanded entries are rows of their own.
    private static func layoutCost(_ row: TranscriptDisplayItem) -> Int {
        guard case .message(let part) = row.item else { return 400 }
        return 400 + min(20_000, part.blocks.reduce(0) { total, block in
            switch block {
            case .text(let text), .queuedMessage(let text), .systemEvent(let text): total + text.utf8.count
            // Collapsed cards lay out a label and at most a one-line preview.
            case .thinking, .compactSummary: total + 200
            case .workflow(let title): total + 200 + title.utf8.count
            case .toolCall(let name, let preview, _): total + 200 + name.utf8.count + min(400, preview.utf8.count)
            case .toolResult(let preview, _, _): total + 200 + min(400, preview.utf8.count)
            case .edit(let path, _): total + 200 + (path?.utf8.count ?? 0)
            default: total + 200
            }
        })
    }

    @ViewBuilder
    private func returnToLatestFooter(_ thread: AgentThreadSnapshot) -> some View {
        // Reserve real layout space: a translucent overlay obscures transcript
        // glyphs on compact screens. Keeping this outside the scroll geometry
        // also makes visibility and edge checks use the actual reading viewport.
        // A match still being read can be given up for the newest page.
        let landing = model.searchLanding?.threadID == thread.summary.id && model.loadingTranscriptThreads.contains(thread.summary.id)
        if landing || !presentation.followingLatest || thread.ingestionWindow?.atLiveHead == false || model.ingestionCapacityThreads.contains(thread.summary.id) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    #if DEBUG
                    NSLog("[AgentChat] return-to-latest atHead=%@ loading=%@", String(describing: thread.ingestionWindow?.atLiveHead),
                        String(model.loadingTranscriptThreads.contains(thread.summary.id)))
                    #endif
                    presentation.followingLatest = true
                    presentation.historyDemand = ""; presentation.automaticPages = 0
                    presentation.historyDemandGeneration += 1
                    if landing || thread.ingestionWindow?.atLiveHead == false || model.ingestionCapacityThreads.contains(thread.summary.id) {
                        model.onAction?(.returnToLatest(thread.summary.id))
                    }
                } label: {
                    Text("Return to latest")
                        .font(Typography.tesseraMono(size: 11)).foregroundStyle(T.fg)
                        .frame(minHeight: 44).padding(.horizontal, 14)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(T.panelBg, in: Capsule())
                .overlay(Capsule().stroke(T.border, lineWidth: 1))
                .disabled(!landing && model.loadingTranscriptThreads.contains(thread.summary.id))
                .accessibilityIdentifier("agent-center-v2-return-to-latest")
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(T.panelBg)
        }
    }

    private func outgoingLabel(_ status: AgentOutgoingMessage.Status) -> String {
        switch status {
        case .sending: "sending…"
        case .queueing: "queueing…"
        case .awaitingReceipt: "sent · waiting for transcript…"
        case .observed: "sent · matching transcript observed"
        case .sentUnconfirmed: "sent · transcript receipt unavailable"
        case .unconfirmed: "receipt unconfirmed · check terminal before retrying"
        }
    }

    private func modeColor(_ mode: AgentPermissionMode) -> Color? {
        switch mode {
        case .plan: return T.accent
        case .auto: return T.amber
        case .defaultMode, .readOnly, .unavailable: return nil
        }
    }

    /// tmux's window ID is no window number, so only the pane shows, in
    /// tmux's own `%21` syntax.
    private func location(for binding: AgentTerminalBinding) -> String {
        var values = [binding.transport.rawValue]
        if let pane = binding.paneID { values.append("pane " + (pane.hasPrefix("%") ? pane : "%" + pane)) }
        return values.joined(separator: " · ")
    }

}

/// A thread's composer, or why it has none. Below the transcript in the
/// stack and in two columns; on the hinge in laptop pose, where sending also
/// puts the keyboard away so the composer docks and the list comes back.
struct AgentThreadComposerSlot: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let thread: AgentThreadSnapshot
    let isCompact: Bool
    @Environment(\.duoDeckPlacement) private var deckPlacement
    @Environment(\.designTokens) private var T

    var body: some View {
        Group {
            if thread.summary.availability.actions,
               thread.binding?.capabilities.contains(.send) == true {
                AgentComposerView(model: model, thread: thread, isCompact: isCompact)
            } else {
                Text("Replies need this agent running in a connected terminal.")
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.fgDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, isCompact ? 16 : 22)
                    .padding(.vertical, 12)
                    .background(T.panelBg)
                    .overlay(alignment: .top) { Rectangle().fill(T.border).frame(height: 1) }
            }
        }
        .onChange(of: model.pendingSends[thread.summary.id] != nil) { _, sending in
            if sending, deckPlacement?.keyboardUp == true { AgentComposerView.hideKeyboard() }
        }
    }
}

/// A laptop screen's title. With the shell's switcher (the sections and the
/// screen's own entries) it gains ⌄ and opens it; without one it is a label.
struct AgentLaptopTitle: View {
    let title: Text
    @Environment(\.duoOpenSwitcher) private var openSwitcher
    @Environment(\.designTokens) private var T

    var body: some View {
        let label = title
            .font(Typography.tesseraMono(size: 14, weight: .medium))
            .foregroundStyle(T.fg)
            .lineLimit(1)
        if let openSwitcher {
            Button { openSwitcher() } label: {
                HStack(spacing: 6) {
                    label
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(T.fgMuted)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-center-v2-laptop-title")
        } else {
            label
                .frame(minHeight: 44)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct AgentPresentationPageIdentity: Equatable {
    let cursor: String?
    let after: String?
    let version: UInt64?
}

private struct AgentSearchLandingAttempt: Equatable {
    let landing: AgentCenterV2PresentationModel.SearchLanding?
    let restored: Bool
    let loading: Bool
    let version: UInt64?
    let rows: Int
}

private struct AgentViewportPinTrigger: Equatable {
    let rowID: String?
    let followingLatest: Bool
}

private struct AgentChatFollowTrigger: Equatable {
    let thread: AgentThreadID
    /// `AgentFollowInputs` changes, collapsed per frame.
    let inputs: Int
}

/// What the follow pass reads: the transcript's layout and the follow state.
private struct AgentFollowInputs: Equatable {
    let content: CGSize
    let viewport: CGSize
    /// Watched only until the thread is positioned: later scrolls without a
    /// pan (VoiceOver, keyboard) must not re-run the follow.
    let landing: Bool?
    let following: Bool
    let atLiveHead: Bool
    let tail: String?
}

/// The follow task's id may change only once per frame, and one frame can
/// change its inputs several times: a detail opened in a navigation stack lays
/// out under a large-title bar, then again under its inline one, and the
/// positioning the follow pass ends with lands a prompt card, which stops
/// following. Every change reaches the task as one bump on the next turn of
/// the main queue; the task reads the current state when it runs.
private final class AgentFollowPulse {
    private var inputs: AgentFollowInputs?
    private var pending = false

    func note(_ next: AgentFollowInputs, bump: @escaping () -> Void) {
        guard next != inputs else { return }
        inputs = next
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            bump()
        }
    }
}

private struct AgentBridgeTrigger: Equatable {
    let thread: AgentThreadID
    let cursor: String?
    let version: UInt64?
    let following: Bool
    let loading: Bool
}

private struct AgentHistoryLoadTrigger: Equatable {
    let threadID: AgentThreadID
    let cursor: String?
    let nearEdge: Bool
    let loading: Bool
    let positioned: Bool
    let demandGeneration: Int
    let renderedEdge: Int
}

/// Which thread is open and whether its window is at the live head.
private struct AgentWindowPlacement: Equatable {
    let thread: AgentThreadID
    let atLiveHead: Bool?
}

private struct AgentRenderedRevealTrigger: Equatable {
    let threadID: AgentThreadID
    let rendered: Range<Int>
    let count: Int
    let older: Bool
    let newer: Bool
    let topVisible: Bool
    let bottomVisible: Bool
    let positioned: Bool
}

private struct AgentTranscriptAnchorFrame: Equatable {
    let id: String
    /// In the bottom-aligned agent-rows frame, where the keeper holds it.
    let minY: CGFloat
    /// Changes only with layout, so scrolling sends no new preference.
    var height: CGFloat = 0
    /// From the row stack's origin, the origin of the keeper's `bounds`. In
    /// agent-rows a short transcript's rows sit lower by the viewport's
    /// spare height.
    let top: CGFloat
}

private struct AgentTranscriptAnchorPreference: PreferenceKey {
    static let defaultValue: AgentTranscriptAnchorFrame? = nil
    static func reduce(value: inout AgentTranscriptAnchorFrame?, nextValue: () -> AgentTranscriptAnchorFrame?) {
        value = value ?? nextValue()
    }
}

/// The frame of the row `AgentTranscriptAnchorKeeper.see` says the reader
/// is on, when that is not the scroll position's row. Measured from the row
/// stack's origin, the transcript bounds' own: in the bottom-aligned
/// `agent-rows` space a short transcript's rows move with the viewport's
/// height, which a container can change twice in one frame.
private struct AgentTranscriptReadingFramePreference: PreferenceKey {
    static let defaultValue: AgentTranscriptAnchorFrame? = nil
    static func reduce(value: inout AgentTranscriptAnchorFrame?, nextValue: () -> AgentTranscriptAnchorFrame?) {
        value = value ?? nextValue()
    }
}

/// Keeps the reader's top visible row at the same screen position when
/// layout above it changes. The row reports its content-space position,
/// which scrolling never changes, so any movement is layout above it.
/// A reader following the live tail is held at the bottom instead.
private final class AgentTranscriptAnchorKeeper {
    private(set) weak var scroll: UIScrollView?
    private var last: AgentTranscriptAnchorFrame?
    private var observations: [NSKeyValueObservation] = []
    /// Latest row-stack frame in viewport coordinates and viewport height.
    /// Plain storage: reveals read them without invalidating the view.
    var bounds: CGRect?
    var viewportHeight: CGFloat = 0
    /// Following the live tail. Content growth, rows released above and
    /// viewport resizes re-pin the bottom from the scroll view's own size
    /// observers, in the layout pass that changed them. A scroll requested
    /// after the next update drew at least one frame at the stale offset.
    var pinsBottom = false

    /// A pin skipped under a finger or fling, retried once it settles.
    private var pendingPin: CADisplayLink?
    /// A landing skipped under a finger, asked again once it lifts.
    private var landingRetry: (() -> Void)?

    /// The row a prompt landing put the reader on, until they scroll, return
    /// to the latest or the window moves them into history.
    var landedRowID: String?
    /// The rendered rows on screen, top first. Plain storage, like `bounds`.
    private var visibleRowIDs: [String] = []
    /// The scroll position's row once it was on screen. A row it names that
    /// never was is a restore still on its way, not a reader gone elsewhere.
    private var shownRowID: String?
    /// The frame of the row `see` named, measured like `last`.
    var readingFrame: AgentTranscriptAnchorFrame?

    func reset() {
        last = nil; bounds = nil; landingRetry = nil; landedRowID = nil
        visibleRowIDs = []; shownRowID = nil; readingFrame = nil
    }

    /// Takes the rendered rows on screen and returns the row the reader is
    /// on when the scroll position names another, which must then report
    /// its frame (`readingFrame`) for `reading` to save how far into it
    /// they are.
    func see(_ rows: [String], scrollRow: String?) -> String? {
        visibleRowIDs = rows
        if let scrollRow, rows.contains(scrollRow) { shownRowID = scrollRow }
        let reader = readerRowID(scrollRow: scrollRow)
        return reader == scrollRow ? nil : reader
    }

    /// The scroll position names the row the reader last panned to, even
    /// from before Return to latest. A landing, VoiceOver or a keyboard
    /// moved them since without it: the rows on screen say where they are.
    /// None yet (no layout, no height) keeps it.
    private func readerRowID(scrollRow: String?) -> String? {
        let shown = visibleRowIDs
        if let landedRowID, shown.isEmpty || shown.contains(landedRowID) { return landedRowID }
        if let top = shown.first, scrollRow.map({ $0 == shownRowID && !onScreen($0, shown: shown) }) ?? true { return top }
        return scrollRow
    }

    func attach(_ found: UIScrollView?) {
        guard found !== scroll else { return }
        scroll = found; observations = []
        guard let found else { return }
        observations = [
            found.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                if change.oldValue != change.newValue { self?.pinBottom() }
            },
            // Bounds also carry the offset; only a size change re-pins.
            found.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                if change.oldValue?.size != change.newValue?.size { self?.pinBottom() }
            },
        ]
        pinBottom()
    }

    /// Never moves content under the reader's finger. A fling finishes
    /// first unless the reader asked for the end (`stoppingScroll`): a
    /// thread switch or Return to latest.
    func pinBottom(stoppingScroll: Bool = false) {
        guard pinsBottom, let scroll else { return }
        if scroll.isTracking || (scroll.isDecelerating && !stoppingScroll) { pinWhenSettled(); return }
        let bottom = Self.maximumOffset(scroll)
        guard abs(scroll.contentOffset.y - bottom) > 0.5 else { return }
        move(scroll, to: bottom, endingFling: true)
    }

    /// Moves the viewport, and `bounds` with it: until layout reports again,
    /// a landing converts with the frame at the new offset. Only the
    /// animated setter ends a fling; assignment lets one carry on from the
    /// new offset.
    private func move(_ scroll: UIScrollView, to y: CGFloat, endingFling: Bool = false) {
        bounds = bounds?.offsetBy(dx: 0, dy: scroll.contentOffset.y - y)
        let offset = CGPoint(x: scroll.contentOffset.x, y: y)
        if endingFling, scroll.isDecelerating { scroll.setContentOffset(offset, animated: false) }
        else { scroll.contentOffset = offset }
    }

    private func pinWhenSettled() {
        guard pendingPin == nil else { return }
        let link = CADisplayLink(target: AgentTranscriptPinTick(self), selector: #selector(AgentTranscriptPinTick.tick(_:)))
        link.add(to: .main, forMode: .common)
        pendingPin = link
    }

    fileprivate func settledTick() {
        guard let scroll, pinsBottom || landingRetry != nil else { pendingPin?.invalidate(); pendingPin = nil; return }
        guard !scroll.isTracking, !scroll.isDecelerating else { return }
        pendingPin?.invalidate(); pendingPin = nil
        if let retry = landingRetry {
            // A landing decided again moves the reader itself; if it no
            // longer lands, the pin it held back still applies.
            landingRetry = nil
            retry()
            DispatchQueue.main.async { [weak self] in self?.pinBottom() }
            return
        }
        pinBottom()
    }

    private static func maximumOffset(_ scroll: UIScrollView) -> CGFloat {
        let inset = scroll.adjustedContentInset
        return max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
    }

    /// The reading state with how far into its top row the reader sits.
    func reading(_ presentation: AgentThreadPresentationState) -> AgentThreadPresentationState {
        var held = presentation
        held.visibleRowFraction = nil
        if !held.followingLatest { held.visibleRowID = readerRowID(scrollRow: held.visibleRowID) }
        guard !held.followingLatest, let id = held.visibleRowID,
              let frame = [last, readingFrame].lazy.compactMap({ $0 }).first(where: { $0.id == id }),
              frame.height > 0, let bounds else { return held }
        // `bounds` is the row stack in viewport space, so this is the row's
        // top below the viewport's: negative once the reader is inside it.
        let rowTop = bounds.minY + frame.top
        held.visibleRowFraction = min(1, max(0, -rowTop / frame.height))
        return held
    }

    /// The scroll position's row reports its frame on every layout, so its
    /// own frame says whether it is on screen; visibility can trail a frame.
    private func onScreen(_ id: String, shown: [String]) -> Bool {
        guard let last, last.id == id, let bounds else { return shown.contains(id) }
        let rowTop = bounds.minY + last.top
        return rowTop + last.height > 0 && rowTop < viewportHeight
    }

    /// Puts the viewport top `margin` above a row-stack position and stops
    /// following. Never under the reader's finger: then `retry` runs once
    /// the finger lifts and any fling ends.
    func land(atRowY y: CGFloat, margin: CGFloat, retry: @escaping () -> Void = {}) -> Bool {
        guard let scroll, let bounds else { return false }
        guard !scroll.isTracking else {
            landingRetry = retry
            pinWhenSettled()
            return false
        }
        landingRetry = nil
        pinsBottom = false
        pendingPin?.invalidate(); pendingPin = nil
        let top = scroll.contentOffset.y + bounds.minY + y - margin
        move(scroll, to: min(Self.maximumOffset(scroll), max(-scroll.adjustedContentInset.top, top)), endingFling: true)
        return true
    }

    /// Puts the viewport top `fraction` of the way into a laid-out row, in
    /// the row's current height, at once. False leaves the landing to
    /// `scrollTo`.
    func scroll(into id: String, fraction: CGFloat) -> Bool {
        guard let scroll, let last, last.id == id, last.height > 0, let bounds else { return false }
        let rowTop = scroll.contentOffset.y + bounds.minY + last.top
        move(scroll, to: min(Self.maximumOffset(scroll), max(-scroll.adjustedContentInset.top, rowTop + fraction * last.height)))
        return true
    }

    func observe(_ frame: AgentTranscriptAnchorFrame?) {
        defer { last = frame }
        guard let frame, let last, frame.id == last.id, frame.minY != last.minY, let scroll else { return }
        // Layout moved the same row. A new row ID is the reader scrolling
        // (VoiceOver, the status bar, a keyboard): never pull that back.
        if pinsBottom { pinBottom(); return }
        // Held in range: a viewport growing over short content moves the
        // row by more than there is left to scroll.
        move(scroll, to: min(Self.maximumOffset(scroll),
                             max(-scroll.adjustedContentInset.top, scroll.contentOffset.y + frame.minY - last.minY)))
    }
}

/// Breaks the display link's strong reference to its target.
private final class AgentTranscriptPinTick: NSObject {
    private weak var keeper: AgentTranscriptAnchorKeeper?
    init(_ keeper: AgentTranscriptAnchorKeeper) { self.keeper = keeper }
    @objc func tick(_ link: CADisplayLink) {
        guard let keeper else { link.invalidate(); return }
        keeper.settledTick()
    }
}

private struct AgentTranscriptBounds: Equatable {
    let thread: AgentThreadID
    let frame: CGRect
}

private struct AgentTranscriptBoundsPreference: PreferenceKey {
    static let defaultValue: AgentTranscriptBounds? = nil
    static func reduce(value: inout AgentTranscriptBounds?, nextValue: () -> AgentTranscriptBounds?) {
        if let next = nextValue() { value = next }
    }
}

/// A prompt card's frame in the row stack's scroll-invariant space.
struct AgentPromptCardFrame: Equatable {
    let token: AgentActionToken
    let frame: CGRect
}

/// The newest (lowest) card wins: older prompts stay in the transcript.
struct AgentPromptCardPreference: PreferenceKey {
    static let defaultValue: AgentPromptCardFrame? = nil
    static func reduce(value: inout AgentPromptCardFrame?, nextValue: () -> AgentPromptCardFrame?) {
        guard let next = nextValue() else { return }
        if value.map({ next.frame.minY >= $0.frame.minY }) ?? true { value = next }
    }
}

/// Pinned to the bottom, a question taller than the transcript keeps its
/// title and first answers above the viewport: the laptop's upper half has
/// about 240 pt for it. Such a question lands once at its own top instead.
/// A card that fits is decided too, so a keyboard shrinking the viewport
/// later never pulls a typing reader up to it.
/// A landing with how often one that waited under a finger was asked again,
/// so the finger lifting decides it anew even when nothing else changed.
private struct AgentPromptLandingAttempt: Equatable {
    let landing: AgentPromptLanding?
    let attempt: Int
}

struct AgentPromptLanding: Equatable {
    static let margin: CGFloat = 8

    let token: AgentActionToken
    /// The row-stack position to land at; nil when the card fits.
    let rowY: CGFloat?

    static func decide(
        _ card: AgentPromptCardFrame?, decided: AgentActionToken?, waiting: Bool, following: Bool,
        positioned: Bool, viewportHeight: CGFloat
    ) -> AgentPromptLanding? {
        guard waiting, following, positioned, let card, card.token != decided,
              card.frame.height > 0, viewportHeight > 0 else { return nil }
        let lands = card.frame.height > viewportHeight - 2 * margin
        return AgentPromptLanding(token: card.token, rowY: lands ? card.frame.minY : nil)
    }
}

private struct AgentTranscriptTailPreference: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

/// The same translation contract is used by UIKit for direct and indirect
/// scrolling. Accumulate sub-threshold movement; a new gesture rearms paging.
struct AgentTranscriptPanDemand {
    private var lastTranslation: CGFloat = 0
    private var emitted = false
    mutating func update(state: UIGestureRecognizer.State, translation: CGFloat) -> (direction: String, began: Bool)? {
        if state == .began { lastTranslation = 0; emitted = false }
        guard state == .began || state == .changed else {
            lastTranslation = 0; emitted = false; return nil
        }
        let delta = translation - lastTranslation
        guard abs(delta) > 2 else { return nil }
        let value = (delta < 0 ? "after" : "before", !emitted)
        lastTranslation = translation; emitted = true
        return value
    }
}

/// Observes the native scroll pan, which already accepts touch, trackpad and
/// discrete wheel input. No competing recognizer or delegate replacement. The
/// display link is diagnostic-only; normal history demand is event-driven.
private struct AgentTranscriptScrollProbe: UIViewRepresentable {
    var anchorKeeper: AgentTranscriptAnchorKeeper
    var onDemand: (String, Bool) -> Void
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView(); view.onDemand = onDemand; view.anchorKeeper = anchorKeeper; return view
    }
    func updateUIView(_ view: ProbeView, context: Context) {
        view.onDemand = onDemand; view.anchorKeeper = anchorKeeper; view.configure()
    }
    static func dismantleUIView(_ view: ProbeView, coordinator: ()) { view.detach() }

    final class ProbeView: UIView {
        private var link: CADisplayLink?
        private weak var scroll: UIScrollView?
        private var lastTick: CFTimeInterval?
        private var started: CFTimeInterval = 0
        private var ticks = 0
        private var maximumGap: Double = 0
        private var gapsOver50 = 0
        private var gapsOver34 = 0
        var onDemand: ((String, Bool) -> Void)?
        private var demand = AgentTranscriptPanDemand()
        weak var anchorKeeper: AgentTranscriptAnchorKeeper?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            configure()
        }

        func detach() {
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
            scroll = nil; link?.invalidate(); link = nil; lastTick = nil
            demand = AgentTranscriptPanDemand()
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            if let value = demand.update(state: recognizer.state, translation: recognizer.translation(in: scroll).y) {
                onDemand?(value.direction, value.began)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configure()
        }

        func configure() {
            guard window != nil else { detach(); return }
            var ancestor = superview
            var found: UIScrollView?
            while let view = ancestor {
                if let candidate = view as? UIScrollView { found = candidate; break }
                ancestor = view.superview
            }
            if found !== scroll {
                detach(); scroll = found
                scroll?.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
            }
            anchorKeeper?.attach(found)
            guard window != nil, DiagnosticLogStore.isVerboseEnabled else {
                link?.invalidate(); link = nil; lastTick = nil
                return
            }
            guard link == nil else { return }
            let target = Target()
            target.owner = self
            let displayLink = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        }

        fileprivate func tick(_ link: CADisplayLink) {
            guard DiagnosticLogStore.isVerboseEnabled else {
                configure()
                return
            }
            guard let scroll else { return }
            let now = link.timestamp
            let active = scroll.isTracking || scroll.isDragging || scroll.isDecelerating
            if let previous = lastTick {
                let gap = (now - previous) * 1_000
                maximumGap = max(maximumGap, gap)
                if gap > 50 { gapsOver50 += 1 }
                if gap > 34 { gapsOver34 += 1 }
                ticks += 1
                if !active {
                    DiagnosticLogStore.appendAgentCenter("v2-scroll frames=\(ticks) durationMs=\(Int((now - started) * 1_000)) maxFrameGapMs=\(Int(maximumGap)) gapsOver50ms=\(gapsOver50)")
                    #if DEBUG
                    // The diagnostic store is rate limited; benchmarks read every gesture.
                    NSLog("TESSERA_V2_SCROLL frames=%ld durationMs=%ld maxFrameGapMs=%ld gapsOver50ms=%ld gapsOver34ms=%ld",
                          ticks, Int((now - started) * 1_000), Int(maximumGap), gapsOver50, gapsOver34)
                    #endif
                    lastTick = nil
                    return
                }
            } else if active {
                started = now; ticks = 0; maximumGap = 0; gapsOver50 = 0; gapsOver34 = 0
            }
            if active { lastTick = now }
        }
    }

    private final class Target: NSObject {
        weak var owner: ProbeView?
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
}

private struct AgentTranscriptLoadingGlyph: View {
    let loading: Bool
    @State private var visible = false

    var body: some View {
        ProgressView().controlSize(.small).opacity(visible ? 1 : 0)
            .accessibilityLabel("loading messages")
            .accessibilityHidden(!visible)
            .task(id: loading) {
                visible = false
                guard loading else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                visible = true
            }
    }
}

private struct TranscriptDisplayItem: Identifiable {
    let id: String
    let item: AgentTranscriptItem
}

private extension AgentPermissionMode {
    var label: String {
        switch self {
        case .defaultMode: return "default mode"
        case .plan: return "plan mode"
        case .auto: return "auto mode"
        case .readOnly: return "read only"
        case .unavailable: return "mode unavailable"
        }
    }
}

struct AgentCenterV2FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var point = CGPoint.zero
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if point.x + size.width > width, point.x > 0 { point.x = 0; point.y += rowHeight + spacing; rowHeight = 0 }
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? point.x, height: point.y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if point.x + size.width > bounds.maxX, point.x > bounds.minX { point.x = bounds.minX; point.y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
