import SwiftUI
import UIKit
import TesseraCore

struct AgentThreadDetailView: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let isCompact: Bool
    @State private var expandedToolEntries: Set<String> = []
    @State private var visibleRowID: String?
    @State private var nearHistoryEdge = false
    @State private var nearNewerEdge = false
    @State private var requestedNewerCursor: String?
    @State private var requestedBridgeCursor: String?
    @State private var bridgeRetryDelay: TimeInterval = 1
    @State private var historyDemand = ""
    @State private var automaticPages = 0
    @State private var historyDemandGeneration = 0
    @State private var atNewest = true
    // User intent survives content/layout growth. Geometry alone cannot tell
    // whether the reader scrolled away or the latest reply became taller.
    @State private var followingLatest = true
    @State private var transcriptSize = CGSize.zero
    @State private var positionedThread: AgentThreadID?
    @State private var requestedCursor: String?
    @State private var nextPageAttempt = Date.distantPast
    @State private var pageRetryDelay: TimeInterval = 1
    @State private var toolRunAnchors: [String: String] = [:]
    // A windowed transcript lays out only this range of its retained rows.
    // nil bounds follow the newest rows; explicit IDs hold a history read.
    @State private var renderedLowerID: String?
    @State private var renderedUpperID: String?
    // Rendered rows extend before the reader reaches their edge.
    @State private var nearRenderedTop = false
    @State private var nearRenderedBottom = false
    // A rendered edge inside the viewport while more rows are retained.
    @State private var renderedTopVisible = false
    @State private var renderedBottomVisible = false
    // Rendered rows are shorter than the viewport: nothing can be scrolled
    // to ask for history, so older pages load without a pan.
    @State private var underfilled = false
    // Pages asked for to fill a short transcript since it last filled.
    @State private var fillPages = 0
    @State private var anchorKeeper = AgentTranscriptAnchorKeeper()
    @Environment(\.designTokens) private var T

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
                    liveConversation(thread)
                    returnToLatestFooter(thread)
                    if thread.summary.availability.actions,
                       thread.binding?.capabilities.contains(.send) == true {
                        AgentComposerView(model: model, thread: thread, isCompact: isCompact)
                    } else {
                        Text("Terminal actions require a current, PID-proven agent binding.")
                            .font(Typography.tesseraMono(size: 10.5))
                            .foregroundStyle(T.fgDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, isCompact ? 16 : 22)
                            .padding(.vertical, 12)
                            .background(T.panelBg)
                            .overlay(alignment: .top) { Rectangle().fill(T.border).frame(height: 1) }
                    }
                }
            } else if let candidate = model.selectedCandidate {
                candidateDetail(candidate)
            } else {
                ContentUnavailableView("select a thread", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .background(T.panelBg)
        .task(id: model.selectedThreadForDetail?.summary.id) {
            guard let threadID = model.selectedThreadForDetail?.summary.id else { return }
            model.onAction?(.detailVisibility(threadID, true))
            defer { model.onAction?(.detailVisibility(threadID, false)) }
            while !Task.isCancelled {
                model.onAction?(.refreshTranscript(threadID))
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .onChange(of: model.selectedThreadForDetail?.summary.id) { _, _ in
            expandedToolEntries = []
            positionedThread = nil
            requestedCursor = nil
            historyDemand = ""; automaticPages = 0
            nextPageAttempt = .distantPast
            pageRetryDelay = 1
            toolRunAnchors = [:]
            // Rendered bounds reset with the window placement (see
            // `AgentWindowPlacement`), which also knows a detached open.
            nearRenderedTop = false; nearRenderedBottom = false
            renderedTopVisible = false; renderedBottomVisible = false
            underfilled = false; fillPages = 0
            anchorKeeper.reset()
            visibleRowID = nil
            atNewest = true
            // Edge flags describe the previous thread until new bounds land.
            nearHistoryEdge = false; nearNewerEdge = false
            followingLatest = model.selectedThreadForDetail?.ingestionWindow?.atLiveHead != false
            transcriptSize = .zero
        }
        .navigationTitle(isCompact ? model.selectedThreadForDetail?.summary.title ?? model.selectedCandidate?.title ?? "threads" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isCompact, let thread = model.selectedThreadForDetail {
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
        VStack(alignment: .leading, spacing: 8) {
            if !isCompact {
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
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
    }

    private func metadata(_ thread: AgentThreadSnapshot) -> some View {
        AgentCenterV2FlowLayout(spacing: 6) {
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
                candidate = run.entries.compactMap { toolRunAnchors[$0.id] }.first ?? item.id
            } else { candidate = item.id }
            let key = usedKeys.insert(candidate).inserted ? candidate : item.id
            let header = TranscriptDisplayItem(id: key, item: item)
            guard case .toolRun(let run) = item,
                  run.entries.contains(where: { expandedToolEntries.contains($0.id) }) else { return [header] }
            // Each expanded entry owns a top-level lazy key, preserving scroll
            // anchors when older tool activity merges into the run's beginning.
            return [header] + run.entries.map { entry in
                TranscriptDisplayItem(id: "agent-tool-detail:\(entry.id)", item: .message(.init(
                    recordID: entry.recordID, role: entry.role, displayTime: entry.displayTime,
                    blocks: [entry.block], firstBlockIndex: entry.blockIndex
                )))
            }
        }
        let rendered = thread.ingestionWindow == nil ? displayItems.indices :
            Self.renderedRange(displayItems, lowerID: renderedLowerID, upperID: renderedUpperID, anchorID: visibleRowID)
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
        let pagesToFill = underfilled && fillPages < Self.fillPageLimit && thread.ingestionWindow?.olderPageFits == true
            && model.ingestionReadStatuses[thread.summary.id]?.isProgress != false
            && !model.ingestionCapacityThreads.contains(thread.summary.id)
        anchorKeeper.pinsBottom = followingLatest && rendersNewest
            && (thread.ingestionWindow?.atLiveHead != false || !outgoing.isEmpty)
        return GeometryReader { viewport in
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
                                                 promptActionsAvailable: canAnswer, isCompact: isCompact)
                                    .equatable()
                            case .toolRun(let run):
                                AgentToolRunView(run: run,
                                    expanded: run.entries.contains { expandedToolEntries.contains($0.id) },
                                    onToggle: {
                                        let ids = Set(run.entries.map(\.id))
                                        if run.entries.contains(where: { expandedToolEntries.contains($0.id) }) {
                                            expandedToolEntries.subtract(ids)
                                        } else { expandedToolEntries.formUnion(ids) }
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
                                if row.id == visibleRowID {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: AgentTranscriptAnchorPreference.self,
                                            value: AgentTranscriptAnchorFrame(id: row.id, minY: geometry.frame(in: .named("agent-rows")).minY))
                                    }
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
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AgentTranscriptBoundsPreference.self,
                        value: .init(thread: thread.summary.id, frame: geometry.frame(in: .named("agent-transcript"))))
                })
                .background(AgentTranscriptScrollProbe(anchorKeeper: anchorKeeper) { direction, began in
                    if direction == "before" { followingLatest = false }
                    else if atNewest { followingLatest = true }
                    if began || direction != historyDemand || automaticPages >= 4 {
                        automaticPages = 0
                        historyDemandGeneration += 1
                    }
                    historyDemand = direction
                }.allowsHitTesting(false))
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
            .accessibilityIdentifier("agent-center-v2-transcript")
            .scrollPosition(id: $visibleRowID)
            .onChange(of: AgentWindowPlacement(thread: thread.summary.id, atLiveHead: thread.ingestionWindow?.atLiveHead),
                      initial: true) { old, new in
                let opened = old == new || old.thread != new.thread
                if opened { renderedLowerID = nil; renderedUpperID = nil }
                guard new.atLiveHead == false else {
                    // Newer paging reached the head under a following reader.
                    if followingLatest { renderedLowerID = nil; renderedUpperID = nil }
                    return
                }
                if !opened, followingLatest, let lane = thread.ingestionWindow?.transition, lane == .revisions || lane == .head {
                    // The window left the head under a following reader,
                    // across more rows than Core bridges (`bridgesToHead`).
                    // Take them back to it rather than onto history.
                    model.onAction?(.returnToLatest(thread.summary.id))
                    return
                }
                followingLatest = false
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
            .onChange(of: thread.summary.attention == .unreadCompletion && !loading
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
            .onChange(of: items, initial: true) { _, _ in
                var anchors: [String: String] = [:]
                for row in displayItems {
                    if case .toolRun(let run) = row.item {
                        for entry in run.entries { anchors[entry.id] = row.id }
                    }
                }
                toolRunAnchors = anchors
            }
            // Rows revealed, released or resized above the reader, and window
            // updates that drop older rows, move the reader's row in content
            // space. SwiftUI's scrollPosition does not hold it through a fling
            // (or at all for eager rows); shift the offset in the same update.
            .onPreferenceChange(AgentTranscriptAnchorPreference.self) { anchorKeeper.observe($0) }
            // Keyed by thread: another thread laid out to the same frame
            // still re-derives the edge flags a switch reset.
            .onPreferenceChange(AgentTranscriptBoundsPreference.self) { measured in
                guard let bounds = measured?.frame else { return }
                // The bottom of a partial rendered range is not the newest row.
                atNewest = rendersNewest && bounds.maxY <= viewport.size.height + 40 && bounds.maxY >= 0
                transcriptSize = bounds.size
                if atNewest && historyDemand == "after" { followingLatest = true }
                nearNewerEdge = bounds.maxY <= viewport.size.height * 2 && bounds.maxY >= 0
                if !nearNewerEdge { requestedNewerCursor = nil }
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
                if !underfilled { fillPages = 0 }
                anchorKeeper.bounds = bounds; anchorKeeper.viewportHeight = viewport.size.height
                if !nearHistoryEdge {
                    requestedCursor = nil
                    pageRetryDelay = 1
                    nextPageAttempt = .distantPast
                }
            }
            .task(id: AgentChatFollowTrigger(thread: thread.summary.id, content: transcriptSize,
                viewport: viewport.size, following: followingLatest, atLiveHead: thread.ingestionWindow?.atLiveHead != false,
                tail: tailID, landing: positionedThread == thread.summary.id ? nil : atNewest)) {
                // Follow the actual end after layout, including same-ID text,
                // regrouped tools, pending bubbles, and keyboard resizing.
                await Task.yield()
                guard !Task.isCancelled, model.selectedThreadForDetail?.summary.id == thread.summary.id else { return }
                if followingLatest && (model.selectedThreadForDetail?.ingestionWindow?.atLiveHead != false || !outgoing.isEmpty) {
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
                    if positionedThread != thread.summary.id, !atNewest {
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    }
                }
                // A detached window is ready for paging too. Following the
                // live head is not a prerequisite for displaying history.
                positionedThread = thread.summary.id
            }
            .task(id: AgentHistoryLoadTrigger(threadID: thread.summary.id, cursor: thread.cursor,
                                            nearEdge: nearHistoryEdge && (thread.ingestionWindow == nil || historyDemand == "before" || pagesToFill), loading: loading,
                                            positioned: positionedThread == thread.summary.id, demandGeneration: historyDemandGeneration,
                                            renderedEdge: rendered.lowerBound)) {
                // Retained rows are revealed locally before asking the host.
                guard thread.ingestionWindow == nil || rendered.lowerBound == 0 else { return }
                let demanded = thread.ingestionWindow == nil || (historyDemand == "before" && automaticPages < 4)
                guard positionedThread == thread.summary.id, nearHistoryEdge, !loading,
                      demanded || pagesToFill, thread.hasMore, let cursor = thread.cursor else { return }
                // An unchanged cursor can mean a transient read failure or
                // an in-flight refresh. Retry without a button or a tight loop.
                if cursor == requestedCursor {
                    let wait = max(0, nextPageAttempt.timeIntervalSinceNow)
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    pageRetryDelay = min(30, pageRetryDelay * 2)
                } else { pageRetryDelay = 1 }
                requestedCursor = cursor
                nextPageAttempt = .now.addingTimeInterval(pageRetryDelay)
                // A fill never spends the pages a history gesture is allowed.
                if demanded {
                    automaticPages += 1
                    model.onAction?(.requestOlderPage(thread.summary.id))
                } else {
                    fillPages += 1
                    model.onAction?(.fillOlderPage(thread.summary.id))
                }
            }
            .task(id: AgentHistoryLoadTrigger(threadID: thread.summary.id, cursor: thread.ingestionWindow?.after,
                                            nearEdge: nearNewerEdge && historyDemand == "after", loading: loading,
                                            positioned: positionedThread == thread.summary.id, demandGeneration: historyDemandGeneration,
                                            renderedEdge: rendered.upperBound)) {
                guard rendersNewest, positionedThread == thread.summary.id, nearNewerEdge, !loading,
                      historyDemand == "after", automaticPages < 4,
                      let window = thread.ingestionWindow, window.hasNewer, !window.atLiveHead,
                      let cursor = window.after else { return }
                if requestedNewerCursor == cursor {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                requestedNewerCursor = cursor
                automaticPages += 1
                model.onAction?(.requestNewerPage(thread.summary.id))
            }
            // A bridged window reads as live: its newest rows are shown but
            // not retained, so nothing revises them. A follower asks for the
            // newer page that retains them, backing off an unchanged cursor.
            .task(id: AgentBridgeTrigger(thread: thread.summary.id, cursor: thread.ingestionWindow?.bridgesToHead == true
                ? thread.ingestionWindow?.after : nil, version: thread.ingestionWindow?.version, following: followingLatest, loading: loading)) {
                guard followingLatest, !loading, let window = thread.ingestionWindow, window.bridgesToHead == true,
                      let cursor = window.after else { return }
                if cursor == requestedBridgeCursor {
                    do { try await Task.sleep(for: .seconds(bridgeRetryDelay)) } catch { return }
                    bridgeRetryDelay = min(30, bridgeRetryDelay * 2)
                } else { bridgeRetryDelay = 1 }
                requestedBridgeCursor = cursor
                model.onAction?(.retainBridgedRows(thread.summary.id))
            }
            .task(id: AgentRenderedRevealTrigger(threadID: thread.summary.id, rendered: rendered, count: displayItems.count,
                                                 older: nearRenderedTop && historyDemand == "before",
                                                 newer: nearRenderedBottom && historyDemand == "after",
                                                 topVisible: renderedTopVisible, bottomVisible: renderedBottomVisible,
                                                 positioned: positionedThread == thread.summary.id)) {
                guard thread.ingestionWindow != nil, positionedThread == thread.summary.id else { return }
                // A rebuilt fallback range becomes the range, so it does not
                // follow the reader's row from frame to frame.
                if !rendered.isEmpty, renderedLowerID != nil || renderedUpperID != nil {
                    let bounds = renderedBounds(displayItems, rendered)
                    if bounds.lower != renderedLowerID || bounds.upper != renderedUpperID { pinRenderedRange(displayItems, rendered) }
                }
                // An exposed edge is repaired first, whatever the direction,
                // and without releasing rows the reader may be heading for.
                let repairTop = renderedTopVisible && rendered.lowerBound > 0
                let repairBottom = renderedBottomVisible && !rendersNewest
                let older = repairTop || !repairBottom && nearRenderedTop && historyDemand == "before" && rendered.lowerBound > 0
                // A reader parked above a growing tail keeps a bounded range:
                // head updates add rows the budget releases from the top.
                let overBudget = displayItems[rendered].reduce(0, { $0 + Self.layoutCost($1) }) > Self.renderedCostBudget + Self.renderedCostChunk
                let trimTop = !older && !repairBottom && !nearRenderedTop && rendersNewest && renderedLowerID != nil && overBudget
                guard older || repairBottom || trimTop || (nearRenderedBottom && historyDemand == "after" && !rendersNewest) else { return }
                // Let the previous reveal's layout report its new edge.
                await Task.yield()
                guard !Task.isCancelled,
                      trimTop || (older ? nearRenderedTop || renderedTopVisible : nearRenderedBottom || renderedBottomVisible) else { return }
                // A repair releases only once over budget: it serves readers
                // without pans (VoiceOver, keyboard), whose reveals must not
                // grow the range back to the whole window.
                revealRetainedRows(displayItems, rendered: rendered, older: older,
                                   release: overBudget || (!repairTop && !repairBottom))
            }
            .onChange(of: AgentViewportPinTrigger(rowID: visibleRowID, followingLatest: followingLatest), initial: true) { _, pin in
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
            .onChange(of: followingLatest) { _, following in
                // Only the live head's tail is followed. The bottom of a
                // detached window is history: newer pages reveal in chunks
                // from the reader's rows rather than jumping to their end.
                if following, thread.ingestionWindow?.atLiveHead != false { renderedLowerID = nil; renderedUpperID = nil }
                else if following { if !rendered.isEmpty { pinRenderedRange(displayItems, rendered) } }
                // Hold the reader's rows: newer tail rows must not trim the
                // top of the range under a history read.
                else if renderedLowerID == nil, thread.ingestionWindow != nil, !rendered.isEmpty {
                    renderedLowerID = displayItems[rendered.lowerBound].id
                }
            }
            // A new send follows the tail. Watch every send, not the drawn
            // bubbles: a send the transcript showed stops drawing one, and
            // that must not pull a reader out of history.
            .onChange(of: thread.outgoingMessages?.last?.id) { previous, next in
                if next != nil && next != previous {
                    followingLatest = true; historyDemand = ""; automaticPages = 0
                }
            }
        }
        }
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

    /// Extends the rendered range by one cost chunk toward older or newer
    /// rows and releases the far side beyond the budget. Rows within half
    /// the budget past the scroll anchor (the top visible row) are never
    /// released, which covers the viewport even for light rows, and nothing
    /// is released before an anchor exists. Cost only estimates height, so
    /// releases also stay within the measured content past the reveal bands.
    /// The anchor keeper holds the visible row in place.
    private func revealRetainedRows(_ items: [TranscriptDisplayItem], rendered: Range<Int>, older: Bool, release: Bool) {
        var lower = rendered.lowerBound, upper = rendered.upperBound, added = 0
        let anchor = visibleRowID.flatMap { id in items[rendered].firstIndex { $0.id == id } }
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

    /// Through-the-newest (a nil upper ID) exists only at the live head; a
    /// detached window's newer pages are revealed, never appended.
    private func pinRenderedRange(_ items: [TranscriptDisplayItem], _ range: Range<Int>) {
        (renderedLowerID, renderedUpperID) = renderedBounds(items, range)
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
            case .toolCall(let name, let preview): total + 200 + name.utf8.count + min(400, preview.utf8.count)
            case .toolResult(let preview, _): total + 200 + min(400, preview.utf8.count)
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
        if !followingLatest || thread.ingestionWindow?.atLiveHead == false || model.ingestionCapacityThreads.contains(thread.summary.id) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    #if DEBUG
                    NSLog("[AgentChat] return-to-latest atHead=%@ loading=%@", String(describing: thread.ingestionWindow?.atLiveHead),
                        String(model.loadingTranscriptThreads.contains(thread.summary.id)))
                    #endif
                    followingLatest = true
                    historyDemand = ""; automaticPages = 0
                    historyDemandGeneration += 1
                    if thread.ingestionWindow?.atLiveHead == false || model.ingestionCapacityThreads.contains(thread.summary.id) {
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
                .disabled(model.loadingTranscriptThreads.contains(thread.summary.id))
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

    private func location(for binding: AgentTerminalBinding) -> String {
        var values = [binding.transport.rawValue]
        if let window = binding.windowID { values.append("window \(window)") }
        if let pane = binding.paneID { values.append("pane \(pane)") }
        return values.joined(separator: " · ")
    }

}

private struct AgentViewportPinTrigger: Equatable {
    let rowID: String?
    let followingLatest: Bool
}

private struct AgentChatFollowTrigger: Equatable {
    let thread: AgentThreadID
    let content: CGSize
    let viewport: CGSize
    let following: Bool
    let atLiveHead: Bool
    let tail: String?
    /// Watched only until the thread is positioned: later scrolls without a
    /// pan (VoiceOver, keyboard) must not re-run the follow.
    let landing: Bool?
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
    let minY: CGFloat
}

private struct AgentTranscriptAnchorPreference: PreferenceKey {
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

    func reset() { last = nil; bounds = nil }

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
        // Only the animated setter ends a fling; assignment would let it
        // carry on from the new offset.
        if scroll.isDecelerating { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false) }
        else { scroll.contentOffset = CGPoint(x: scroll.contentOffset.x, y: bottom) }
    }

    private func pinWhenSettled() {
        guard pendingPin == nil else { return }
        let link = CADisplayLink(target: AgentTranscriptPinTick(self), selector: #selector(AgentTranscriptPinTick.tick(_:)))
        link.add(to: .main, forMode: .common)
        pendingPin = link
    }

    fileprivate func settledTick() {
        guard let scroll, pinsBottom else { pendingPin?.invalidate(); pendingPin = nil; return }
        guard !scroll.isTracking, !scroll.isDecelerating else { return }
        pendingPin?.invalidate(); pendingPin = nil
        pinBottom()
    }

    private static func maximumOffset(_ scroll: UIScrollView) -> CGFloat {
        let inset = scroll.adjustedContentInset
        return max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
    }

    func observe(_ frame: AgentTranscriptAnchorFrame?) {
        defer { last = frame }
        guard let frame, let last, frame.id == last.id, frame.minY != last.minY, let scroll else { return }
        // Layout moved the same row. A new row ID is the reader scrolling
        // (VoiceOver, the status bar, a keyboard): never pull that back.
        if pinsBottom { pinBottom(); return }
        var offset = scroll.contentOffset
        // Held in range: a viewport growing over short content moves the
        // row by more than there is left to scroll.
        offset.y = min(Self.maximumOffset(scroll), max(-scroll.adjustedContentInset.top, offset.y + frame.minY - last.minY))
        scroll.contentOffset = offset
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
