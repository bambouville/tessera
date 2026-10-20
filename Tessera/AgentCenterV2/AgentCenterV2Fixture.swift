#if DEBUG
import Foundation
import SwiftUI
import TesseraCore

/// Connection-free visual fixture. It deliberately uses the public shared
/// snapshot/domain types rather than recreating a v1 card state model.
@MainActor
enum AgentCenterV2Fixture {
    static var ingestionRevisionSplits = 0
    /// Records in the fixture source when its head was split.
    static var ingestionSourceEnd = 0
    static var rejectedPages = 0
    static var chatFollowStage = 0
    static var advanceChatFollow: (() -> Void)?
    enum Scene: String {
        case primary
        case loading
        case compact
        case error
        case sendAnyway
        case integration
        case markdown
        case transcript
        case outgoing
        case history
        case shortHistory
        case discovery
        case streaming
        case ingestionWindow
        case chatFollow
        case detachedWindow
        case coldPage
        /// The waiting thread shows the live prompt card named by
        /// `TESSERA_AGENT_CENTER_V2_HARNESS_PROMPT`.
        case prompt
        /// Threads appear and move between list sections in quick
        /// succession, as a tmux rebuild publishes them.
        case sectionMoves

        static var requested: Self {
            Self(rawValue: ProcessInfo.processInfo.environment[
                "TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"
            ] ?? "") ?? .primary
        }
    }

    enum Appearance: String {
        case system
        case light
        case dark

        static var requested: Self {
            Self(rawValue: ProcessInfo.processInfo.environment[
                "TESSERA_AGENT_CENTER_V2_HARNESS_APPEARANCE"
            ] ?? "") ?? .system
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum FixtureDynamicType: String {
        case standard
        case accessibility3

        static var requested: Self {
            Self(rawValue: ProcessInfo.processInfo.environment[
                "TESSERA_AGENT_CENTER_V2_HARNESS_DYNAMIC_TYPE"
            ] ?? "") ?? .standard
        }

        var size: DynamicTypeSize {
            switch self {
            case .standard: .large
            case .accessibility3: .accessibility3
            }
        }
    }

    /// Live prompt cards as Core publishes them from real terminal screens.
    enum PromptVariant: String {
        case question, typed, multiSelect, review, text, deferred, permission

        static var requested: Self {
            Self(rawValue: ProcessInfo.processInfo.environment["TESSERA_AGENT_CENTER_V2_HARNESS_PROMPT"] ?? "") ?? .question
        }

        var prompt: AgentActionPrompt {
            let token = AgentActionToken("fixture-live-\(rawValue)")!
            let database: [TesseraCore.AgentPromptOption] = [
                .init(id: "1", label: "Postgres (Recommended)", isDefault: true, detail: "Mature, transactional, already deployed."),
                .init(id: "2", label: "SQLite", detail: "Embedded file, zero operations."),
                .init(id: "3", label: "DynamoDB", detail: "Managed key-value store."),
                .init(id: "4", label: "Type something.", role: .freeform, acceptsText: true),
                .init(id: "5", label: "Chat about this", role: .chat),
            ]
            switch self {
            case .question, .typed:
                return .init(title: "Database", options: database, token: token, kind: .question,
                             question: "Which database should the service use for the new ledger?",
                             controls: [.init(kind: .cancel, label: "Cancel")],
                             entry: self == .typed ? .init(optionID: "4", text: "CockroachDB, with a read replica") : nil,
                             acceptsText: true, isBlocking: true)
            case .multiSelect:
                return .init(title: "Features", options: [
                    .init(id: "1", label: "Search", detail: "Full-text search.", isChecked: true),
                    .init(id: "2", label: "Export", isDefault: true, detail: "CSV export.", isChecked: false),
                    .init(id: "3", label: "Sharing", detail: "Share links.", isChecked: true),
                    .init(id: "4", label: "Type something", role: .freeform, isChecked: false),
                    .init(id: "5", label: "Chat about this", role: .chat),
                ], token: token, kind: .multiSelect, question: "Which features should ship first?",
                   progress: "☒ Database ☐ Features ☐ PR ✔ Submit",
                   controls: [.init(kind: .next, label: "Next"), .init(kind: .cancel, label: "Cancel")], isBlocking: true)
            case .review:
                return .init(title: "Review your answers",
                             detail: "● Which database should the service use?\n  → Postgres\n● Which features should ship first?\n  → Search, Sharing",
                             options: [.init(id: "1", label: "Submit answers", isDefault: true), .init(id: "2", label: "Cancel")],
                             token: token, kind: .review, question: "Ready to submit your answers?",
                             progress: "☒ Database ☒ Features ☒ PR ✔ Submit", isBlocking: true)
            case .text:
                return .init(title: "Question", options: [], token: token, kind: .textEntry,
                             question: "Describe the rollout window you prefer.", progress: "2 of 2",
                             controls: [.init(kind: .skip, label: "Skip")], entry: .init(optionID: nil, text: ""),
                             acceptsText: true, isBlocking: false)
            case .deferred:
                return .init(title: "Questions waiting", options: [], token: token, kind: .deferred,
                             question: "2 questions", controls: [.init(kind: .open, label: "Answer")],
                             isBlocking: false, pendingCount: 2)
            case .permission:
                return .init(title: "Permission requested", detail: "cwd: ~/work\n$ python3 hello.py", options: [
                    .init(id: "1", label: "Approve once", isDefault: true),
                    .init(id: "2", label: "Approve for this session"),
                    .init(id: "3", label: "Reject"),
                    .init(id: "4", label: "Reject with feedback"),
                ], token: token, kind: .permission, question: "Run this command?", isBlocking: true)
            }
        }
    }

    /// Replays the list publishes of a tmux rebuild recorded on a live host:
    /// rows arrive idle under "recent", then move to working, needs you and
    /// finished, a few hundred milliseconds apart. The pinned lazy list once
    /// kept drawing such rows as they first appeared there, and they took no
    /// taps.
    private static func playSectionMoves(into model: AgentCenterV2PresentationModel) async {
        let host = UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!
        let availability = AgentAvailability(content: true, status: true, actions: false, spawn: false, fork: false, search: false)
        func row(_ session: String, _ provider: AgentProviderID, _ title: String, _ status: TesseraCore.AgentStatus,
                 _ attention: TesseraCore.AgentAttention = .none, preview: String? = nil) -> AgentThreadSummary {
            AgentThreadSummary(id: AgentThreadID(hostID: host, providerID: provider, providerSessionID: session)!,
                title: title, providerName: provider == .claude ? "Claude Code" : "Codex",
                projectBasename: preview == nil ? nil : "atlas", hostDisplayLabel: "devbox",
                status: status, attention: attention, lastActivity: .now, preview: preview, availability: availability)
        }
        let migrate = "Migrate signing tokens", pricing = "Pricing page copy", scripts = "Document npm scripts"
        let steps: [[AgentThreadSummary]] = [
            [row("moves-a", .claude, "Claude Code", .idle)],
            [row("moves-b", .claude, "Claude Code", .idle), row("moves-a", .claude, "Claude Code", .idle)],
            [row("moves-a", .claude, "Claude Code", .working), row("moves-b", .claude, "Claude Code", .idle)],
            [row("moves-b", .claude, "Claude Code", .working), row("moves-a", .claude, "Claude Code", .working)],
            [row("moves-b", .claude, "Claude Code", .working), row("moves-a", .claude, migrate, .working, preview: "Running the dry run")],
            [row("moves-a", .claude, migrate, .working, preview: "Running the dry run"), row("moves-b", .claude, "Claude Code", .working)],
            [row("moves-a", .claude, migrate, .waitingForInput, .needsYou, preview: "Allow npm run migrate?"),
             row("moves-b", .claude, "Claude Code", .working)],
            [row("moves-a", .claude, migrate, .waitingForInput, .needsYou, preview: "Allow npm run migrate?"),
             row("moves-b", .claude, "Claude Code", .working), row("moves-c", .codex, "Codex", .idle)],
            [row("moves-a", .claude, migrate, .waitingForInput, .needsYou, preview: "Allow npm run migrate?"),
             row("moves-b", .claude, "Claude Code", .working), row("moves-c", .codex, "Add a scripts section", .idle, preview: "Add a scripts section")],
            [row("moves-a", .claude, migrate, .waitingForInput, .needsYou, preview: "Allow npm run migrate?"),
             row("moves-c", .codex, "Add a scripts section", .working, preview: "Add a scripts section"), row("moves-b", .claude, "Claude Code", .working)],
            [row("moves-a", .claude, migrate, .waitingForInput, .needsYou, preview: "Allow npm run migrate?"),
             row("moves-c", .codex, "Add a scripts section", .working, preview: "Add a scripts section"),
             row("moves-b", .claude, pricing, .finished, .unreadCompletion, preview: "Send a screenshot?")],
            [row("moves-a", .claude, migrate, .waitingForInput, .needsYou, preview: "Allow npm run migrate?"),
             row("moves-c", .codex, scripts, .working, preview: "Reading package.json"),
             row("moves-b", .claude, pricing, .finished, .unreadCompletion, preview: "Send a screenshot?")],
            [row("moves-a", .claude, migrate, .waitingForInput, .needsYou, preview: "Allow npm run migrate?"),
             row("moves-c", .codex, scripts, .finished, .unreadCompletion, preview: "README already lists them"),
             row("moves-b", .claude, pricing, .finished, .unreadCompletion, preview: "Send a screenshot?")],
        ]
        for (index, threads) in steps.enumerated() {
            try? await Task.sleep(for: .milliseconds(index == 0 ? 600 : 250))
            model.apply(list: .init(threads: threads))
        }
        NSLog("TESSERA_AGENT_SECTION_MOVES done steps=%d", steps.count)
    }

    static func makeModel(scene: Scene = .requested) -> AgentCenterV2PresentationModel {
        let model = AgentCenterV2PresentationModel()
        if scene == .coldPage {
            let driver = AgentColdPageFixture(model: model)
            model.onAction = { [driver] _ in _ = driver }
            Task { await driver.start() }
            return model
        }
        if scene == .ingestionWindow || scene == .chatFollow || scene == .detachedWindow {
            let driver = AgentIngestionWindowFixture(model: model, chatFollow: scene == .chatFollow,
                initiallyDetached: scene == .detachedWindow)
            model.onAction = { action in driver.handle(action) }
            advanceChatFollow = { [weak driver] in driver?.advanceChat() }
            Task { await driver.start() }
            return model
        }
        if scene == .sectionMoves {
            Task { await playSectionMoves(into: model) }
            return model
        }
        let host = UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!
        let claude = AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "claude-thread-visual")!
        let codex = AgentThreadID(hostID: host, providerID: .codex, providerSessionID: "codex-thread-visual")!
        let availability = AgentAvailability(content: true, status: true, actions: true, spawn: true, fork: true, search: true)
        let waiting = AgentThreadSummary(
            id: claude, title: "files panel flicker", providerName: "claude", model: "opus", projectBasename: "tessera", branch: "fix/files-flicker", hostDisplayLabel: "ubuntu-prod", permissionMode: .plan, status: .waitingForInput, attention: .needsYou, lastActivitySequence: 42, lastActivity: .now, preview: "permission requested · swift build", cost: .init(totalCost: 1.24, durationSeconds: 342, linesAdded: 142, linesRemoved: 31), context: .init(percentUsed: 62), queuedMessageCount: 1, availability: availability
        )
        let working = AgentThreadSummary(
            id: codex, title: "review scroll transport", providerName: "codex", model: "gpt-5", projectBasename: "tessera", branch: "feat/scroll", hostDisplayLabel: "mac-mini", permissionMode: .auto, status: .working, attention: .none, lastActivitySequence: 40, lastActivity: .now.addingTimeInterval(-36), preview: "running focused integration tests", cost: .init(totalCost: 0.61, durationSeconds: 128), context: .init(percentUsed: 38), availability: availability
        )
        let finished = AgentThreadSummary(
            id: AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "finished-thread-visual")!, title: "publish release notes", providerName: "claude", model: "sonnet", projectBasename: "tessera", branch: "release/notes", hostDisplayLabel: "ubuntu-prod", permissionMode: .defaultMode, status: .finished, attention: .unreadCompletion, lastActivitySequence: 38, lastActivity: .now.addingTimeInterval(-92), preview: "completed release notes", cost: .init(totalCost: 0.24, durationSeconds: 84, linesAdded: 18, linesRemoved: 3), context: .init(percentUsed: 18), availability: availability
        )
        let recent = AgentThreadSummary(
            id: AgentThreadID(hostID: host, providerID: .codex, providerSessionID: "recent-thread-visual")!, title: "audit host profiles", providerName: "codex", model: "gpt-5", projectBasename: "tessera", branch: "main", hostDisplayLabel: "mac-mini", permissionMode: .readOnly, status: .idle, attention: .none, lastActivitySequence: 36, lastActivity: .now.addingTimeInterval(-360), preview: "waiting for a new task", cost: .init(totalCost: 0.08, durationSeconds: 41), context: .init(percentUsed: 9), availability: availability
        )
        let binding = AgentTerminalBinding(
            liveSessionID: UUID(uuidString: "A11CE000-0000-4000-8000-000000000002")!,
            carrierGeneration: 3,
            incarnation: AgentIncarnationToken("fixture-1")!,
            transport: .sshTmux,
            tmuxSession: "dev",
            windowID: "2",
            paneID: "%10",
            agentPID: 1234,
            capabilities: scene == .compact
                ? [.observe, .send, .interrupt, .tmux]
                : [.observe, .send, .interrupt, .promptAnswer, .tmux]
        )
        let prompt = AgentActionPrompt(
            title: "permission requested",
            detail: "Bash   swift build",
            options: [
                .init(id: "1", label: "yes", isDefault: true),
                .init(id: "2", label: "always"),
                .init(id: "3", label: "no"),
            ],
            token: AgentActionToken("fixture-prompt")!
        )
        let candidate = AgentTerminalCandidate(
            id: AgentSourceCandidateID(
                hostID: host,
                providerID: .claude,
                sourceIdentity: "fixture-unproven-live-agent"
            )!,
            providerName: "claude",
            title: "unproven live terminal",
            hostDisplayLabel: "ubuntu-prod",
            fallback: .init(
                status: .waitingForInput,
                location: "dev · pane %11",
                integrationAvailable: false,
                liveTail: "permission requested; open the terminal to verify",
                prompt: prompt,
                binding: binding
            )
        )
        model.apply(list: .init(
            threads: [waiting, working, finished, recent],
            candidates: [candidate],
            unavailableHostIDs: [UUID(uuidString: "A11CE000-0000-4000-8000-000000000003")!]
        ))
        model.apply(thread: .init(
            summary: waiting,
            messages: [
                .init(recordID: "u1", role: .user, displayTime: .now.addingTimeInterval(-300), blocks: [.text("Investigate the files panel flicker and make a plan.")]),
                .init(recordID: "a1", role: .assistant, displayTime: .now.addingTimeInterval(-210), blocks: [
                    .text("I found a context-menu backdrop transition that needs an opaque backstop."),
                    .thinking("Checking the existing context menu ownership and the screenshot fixture timeline."),
                    .toolCall(name: "Read", preview: "Tessera/Files/FilesPanelView.swift"),
                    .edit(path: "Tessera/Files/FilesPanelView.swift", diff: "+ opaque backstop\n- delayed backdrop"),
                    .workflowTasks([
                        .init(id: "1", title: "capture a reproducer", owner: "main", state: .completed),
                        .init(id: "2", title: "verify context-menu timing", owner: "explorer", state: .working),
                    ]),
                    .subagentGroup([.init(id: "explorer", type: "Explore", summary: "examining iOS menu timing", status: .working)]),
                    .actionPrompt(scene == .prompt ? PromptVariant.requested.prompt : prompt),
                ]),
            ],
            activity: [
                .init(id: "1", sequence: 40, kind: .tool, title: "Read", detail: "FilesPanelView.swift", displayTime: .now.addingTimeInterval(-210)),
                .init(id: "2", sequence: 41, kind: .permission, title: "permission requested", detail: "swift build", displayTime: .now),
            ],
            changes: .init(authoritativeTotals: waiting.cost, edits: [.init(id: "e1", path: "Tessera/Files/FilesPanelView.swift", additions: 12, deletions: 4, diff: "+ backstop = true")]),
            lineage: nil,
            cursor: "fixture-cursor",
            hasMore: true,
            binding: binding
        ))
        model.apply(thread: .init(summary: working, messages: [.init(recordID: "w1", role: .assistant, displayTime: .now, blocks: [.thinking("Running the four transport verification lanes.")])], cursor: nil, hasMore: false, binding: binding))
        if scene == .markdown {
            var markdownSummary = waiting
            markdownSummary.title = "Markdown rendering"
            markdownSummary.status = .idle
            markdownSummary.attention = .none
            model.apply(thread: .init(summary: markdownSummary, messages: [
                .init(recordID: "markdown-1", role: .assistant, displayTime: .now, blocks: [.text(AgentMarkdownDocument.verificationSample)])
            ], cursor: nil, hasMore: false, binding: binding))
            model.select(claude)
        }
        if scene == .prompt {
            model.select(claude)
            model.pendingNarrowThreadNavigation = claude
        }
        if scene == .transcript,
           let encoded = ProcessInfo.processInfo.environment["TESSERA_AGENT_TRANSCRIPT_FIXTURE_B64"],
           encoded.utf8.count <= 262_144, let data = Data(base64Encoded: encoded) {
            struct Fixture: Decodable { let thread: AgentThreadSnapshot }
            if let fixture = try? JSONDecoder().decode(Fixture.self, from: data) {
                model.apply(list: .init(threads: [fixture.thread.summary]))
                model.apply(thread: fixture.thread)
                model.select(fixture.thread.summary.id)
            }
        }
        model.launchTargets = [
            .init(id: binding.liveSessionID, title: "ubuntu-prod", detail: "dev · 4 windows", providerIDs: [.claude, .codex], recentDirectories: ["~/tessera", "~/api-gateway"], windows: [.init(id: "2", title: "dev", paneIDs: ["%10", "%11"])]),
        ]
        if scene == .loading {
            model.searchQuery = "files"
            model.isSearching = true
        }
        if scene == .error {
            model.capabilityNotice = "The transcript source changed. Open Terminal to continue safely."
        }
        if scene == .integration {
            model.integrationNotice = .init(
                sessionID: binding.liveSessionID,
                state: .resolved(
                    installation: .current,
                    target: AgentCurrentIntegrationTarget(
                        location: AgentLocation(
                            sessionID: binding.liveSessionID,
                            hostName: "ubuntu-prod",
                            transportLabel: "ssh+tmux",
                            tmuxSessionName: "dev",
                            windowID: 2,
                            windowName: "dev",
                            paneID: 10
                        ),
                        foreground: .shell,
                        processIDs: [1234],
                        shellIntegrationActive: false,
                        agentIntegrationActive: false
                    )
                )
            )
        }
        if scene == .outgoing {
            var summary = working
            summary.title = "Compact composer"
            model.apply(list: .init(threads: [summary]))
            model.apply(thread: .init(summary: summary, messages: [
                .init(recordID: "compact-reply", role: .assistant, displayTime: nil, blocks: [.text("Ready for the next instruction.")])
            ], cursor: nil, hasMore: false, binding: binding, outgoingMessages: [
                .init(id: UUID(), text: "Please check the next result.", status: .awaitingReceipt)
            ]))
            model.select(codex)
            model.pendingNarrowThreadNavigation = codex
        }
        if scene == .history || scene == .shortHistory {
            model.apply(list: .init(threads: [working]))
            let first = scene == .shortHistory ? 88 : 60
            model.apply(thread: .init(summary: working,
                messages: historyMessages(first..<(scene == .history ? 180 : 90)), cursor: String(first), hasMore: true, binding: binding))
            model.select(codex)
            model.pendingNarrowThreadNavigation = codex
        }
        if scene == .streaming {
            model.apply(list: .init(threads: [working]))
            model.apply(thread: .init(summary: working, messages: historyMessages(0..<180),
                cursor: "0", hasMore: false, binding: binding))
            model.select(codex)
            model.pendingNarrowThreadNavigation = codex
            Task { @MainActor [weak model] in
                for pass in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let model else { return }
                    // A legacy projector replaces its bounded newest page on
                    // append, removing a reader's previously loaded anchor.
                    let end = 181 + pass
                    let first = pass < 12 ? 0 : end - 30
                    model.apply(thread: .init(summary: working,
                        messages: historyMessages(first..<end), cursor: String(first),
                        hasMore: false, binding: binding))
                }
            }
        }
        var historyAttempts = 0
        model.onAction = { [weak model] action in
            if case .requestOlderPage(let threadID) = action,
               scene == .history || scene == .shortHistory,
               let model, let current = model.selectedThread,
               let cursor = current.cursor, let first = Int(cursor), first > 0,
               !model.loadingTranscriptThreads.contains(threadID) {
                model.loadingTranscriptThreads.insert(threadID)
                historyAttempts += 1
                let failFirst = scene == .shortHistory && historyAttempts == 1
                Task { @MainActor [weak model] in
                    // Leave enough time for XCUI's gesture-idle wait and
                    // identity-based anchor lookup before releasing the page.
                    try? await Task.sleep(for: .seconds(scene == .history ? 12 : 2))
                    guard let model else { return }
                    defer { model.loadingTranscriptThreads.remove(threadID) }
                    if failFirst { return }
                    let next = max(0, first - 30)
                    model.apply(thread: .init(summary: current.summary,
                        messages: historyMessages(next..<first) + current.messages,
                        cursor: String(next), hasMore: next > 0, binding: current.binding))
                }
            }
            if case .answer(_, let token, let goal) = action {
                // The fixture records each answer instead of writing to a terminal.
                NSLog("TESSERA_AGENT_PROMPT_ANSWER token=%@ goal=%@", token.rawValue, String(describing: goal))
            }
            if case .send(let request) = action {
                let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("agent-composer-action-capture.txt")
                try? (request.queueWhenWorking ? "queueing" : "sending").write(to: marker, atomically: true, encoding: .utf8)
                NSLog("TESSERA_AGENT_COMPOSER_SEND queue=%@", request.queueWhenWorking ? "true" : "false")
                Task { @MainActor [weak model] in
                    try? await Task.sleep(for: .seconds(4))
                    if model?.draftBinding(for: request.threadID) == request.text { model?.setDraft("", for: request.threadID) }
                    model?.finishSend(request)
                }
            }
        }
        if scene == .sendAnyway, let thread = model.selectedThread {
            let text = "Please check the next result."
            model.pendingNarrowThreadNavigation = thread.summary.id
            model.setDraft(text, for: thread.summary.id)
            let fixtureAction = model.onAction
            var refused: AgentCenterV2PresentationModel.ComposerSend?
            model.onAction = { if case .send(let request) = $0 { refused = request } }
            model.sendDraft(for: thread)
            model.onAction = fixtureAction
            if let refused {
                model.finishSend(refused)
                model.reportNotSent(.inputNotReady, reason: "composer-unrecognized", providerName: "Claude", draft: .restored)
                model.offerSendAnyway(for: refused, refusal: .init(error: .inputNotReady,
                    reason: "composer-unrecognized", attempts: 12, shape: nil), draft: .restored)
            }
        }
        return model
    }

    private static func historyMessages(_ range: Range<Int>) -> [AgentMessage] {
        range.map { index in
            .init(recordID: "history-\(index)", role: .assistant, displayTime: nil,
                  blocks: [.text("History message \(index)\nA stable reading position while earlier messages arrive.")])
        }
    }
}

/// Exercises the production reducer and actual detail scrolling without any
/// host connection. No provider files, hooks, actions, or SSH are involved.
@MainActor
private final class AgentIngestionWindowFixture {
    private weak var model: AgentCenterV2PresentationModel?
    private let runtime = AgentCenterRuntime()
    private let thread: AgentThreadID
    private var count = AgentIngestionWindowFixture.transcript.map { max(1, $0.records.count - 60) }
        ?? Int(ProcessInfo.processInfo.environment["TESSERA_AGENT_WINDOW_FIXTURE_RECORDS"] ?? "").map { min(20_000, max(200, $0)) } ?? 1_200
    private var busy = false
    private var pendingLatest = false
    private var updates: Task<Void, Never>?
    private var churn: Task<Void, Never>?
    private var readProgress: Task<Void, Never>?
    private var retainedSegments: [String: AgentIngestionSegment] = [:]
    private var didSplit = false
    private let chatFollow: Bool
    private let initiallyDetached: Bool
    private var preparingDetached: Bool
    private var grewTail = false

    init(model: AgentCenterV2PresentationModel, chatFollow: Bool = false, initiallyDetached: Bool = false) {
        self.model = model; self.chatFollow = chatFollow; self.initiallyDetached = initiallyDetached
        thread = AgentThreadID(hostID: UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!,
            providerID: initiallyDetached ? .pi : Self.transcript?.provider ?? .claude, providerSessionID: "bounded-window-fixture")!
        preparingDetached = initiallyDetached
    }

    func advanceChat() {
        guard chatFollow, !busy else { return }
        AgentCenterV2Fixture.chatFollowStage += 1
        if AgentCenterV2Fixture.chatFollowStage >= 3 { count += 3 }
        Task { await load(.head) }
    }

    func start() async {
        // Existing fixtures exercise the legacy four-page window. `device`
        // negotiates like a current host with this device's retention tier.
        if ProcessInfo.processInfo.environment["TESSERA_AGENT_WINDOW_FIXTURE_CAPACITY"] == "device" {
            await runtime.configure(budget: AgentCenterV2Coordinator.deviceContentBudget)
            await runtime.setIngestionHostSegments(AgentIngestionWindowCapacity.maximumSegments, for: thread.hostID)
        }
        let candidate = AgentSourceCandidateID(hostID: thread.hostID, providerID: thread.providerID, sourceIdentity: "window-fixture")!
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("window-fixture")!, transport: .ssh, capabilities: [.observe])
        await runtime.registerCandidate(candidate, fallback: .init(status: .idle, location: "Synthetic host",
            integrationAvailable: true, liveTail: "", prompt: nil, binding: binding))
        await runtime.promoteCandidate(candidate, to: .init(id: thread, title: "Bounded history · 1,200 records",
            titleProvenance: .native, providerName: initiallyDetached ? "Pi" : "Claude", hostDisplayLabel: "Synthetic host", status: .idle,
            availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false)))
        if !initiallyDetached { model?.apply(list: await runtime.listSnapshot()) }
        if chatFollow { try? await Task.sleep(for: .seconds(1)) }
        await load(.bootstrap)
        if initiallyDetached {
            // Four backward pages evict the original head from the bounded
            // viewport. One page alone is historical but still atLiveHead.
            for _ in 0..<4 { await load(.before) }
            preparingDetached = false
            if let snapshot = await runtime.snapshot(for: thread) { model?.apply(thread: snapshot) }
            model?.apply(list: await runtime.listSnapshot())
        }
        // After the reader is selected: a sibling's first publish would
        // otherwise take an empty selection.
        await startSiblingChurn()
        startReadProgressPulses()
    }

    /// A working agent's file grows between refreshes, and the host reports
    /// "preparing" while it re-validates the grown file, so most refreshes
    /// pass through progress before their read lands. Pulses that status on
    /// the reader's thread as field sessions do.
    private func startReadProgressPulses() {
        guard let hertz = Double(ProcessInfo.processInfo.environment["TESSERA_AGENT_WINDOW_FIXTURE_READ_PROGRESS_HZ"] ?? ""), hertz > 0,
              let preparing = try? AgentIngestionReadStatus.decode(.object(["v": .number(1), "state": .string("preparing"),
                  "domain": .string("source"), "recovery": .string("continue"), "code": .string("readPending")]))
        else { return }
        NSLog("TESSERA_WINDOW_FIXTURE readProgressHz=%.1f", hertz)
        readProgress = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1 / hertz / 2)) } catch { return }
                guard let self, let model = self.model else { return }
                if model.ingestionReadStatuses[self.thread] == nil { model.ingestionReadStatuses[self.thread] = preparing }
                else { model.ingestionReadStatuses.removeValue(forKey: self.thread) }
            }
        }
    }

    func handle(_ action: AgentCenterV2PresentationModel.Action) {
        switch action {
        case .requestOlderPage: Task { await load(.before) }
        case .fillOlderPage:
            Task {
                guard await runtime.snapshot(for: thread)?.ingestionWindow?.olderPageFits == true else { return }
                await load(.before)
            }
        case .requestNewerPage, .retainBridgedRows: Task { await load(.after) }
        case .returnToLatest: Task { await load(.bootstrap) }
        case .viewportAnchor(_, let record): Task { await runtime.setIngestionViewportAnchor(record, for: thread) }
        case .newestRecordVisible where chatFollow && !grewTail:
            grewTail = true
            updates = Task {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                AgentCenterV2Fixture.chatFollowStage = 1
                await load(.head)
            }
        case .detailVisibility(_, let visible):
            if chatFollow { break }
            updates?.cancel(); updates = nil
            if visible {
                updates = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        guard let self, self.model != nil else { return }
                        if !self.busy {
                            self.count = min(self.count + 3, Self.transcript?.records.count ?? .max); await self.load(.head)
                            await self.exerciseRevisionSplit()
                            if Self.splitsHead { await self.exerciseHeadSplit() }
                        }
                    }
                }
            }
        default: break
        }
    }

    /// Field sessions publish several times a second while other agents work
    /// (discovery, lifecycle, list reads), each applying the list and the
    /// changed snapshots as `AgentCenterV2Coordinator.synchronizePresentation`
    /// does. Reproduces that load under a scrolling reader; optionally the
    /// reader's own thread is working too.
    private func startSiblingChurn() async {
        let environment = ProcessInfo.processInfo.environment
        guard let hertz = Double(environment["TESSERA_AGENT_WINDOW_FIXTURE_CHURN_HZ"] ?? ""), hertz > 0 else { return }
        let churnSelected = environment["TESSERA_AGENT_WINDOW_FIXTURE_CHURN_SELECTED"] == "1"
        let availability = AgentAvailability(content: true, status: true, actions: false, spawn: false, fork: false, search: false)
        var siblings: [AgentThreadSummary] = (0..<4).map { index in
            AgentThreadSummary(id: AgentThreadID(hostID: thread.hostID, providerID: .claude, providerSessionID: "churn-\(index)")!,
                title: "Sibling agent \(index)", titleProvenance: .native, providerName: "Claude", hostDisplayLabel: "Synthetic host",
                status: .working, lastActivity: .now, preview: "Starting", availability: availability)
        }
        // Listed like the reader: the list shows live routes only.
        for sibling in siblings {
            let candidate = AgentSourceCandidateID(hostID: thread.hostID, providerID: .claude,
                sourceIdentity: "window-fixture-\(sibling.id.providerSessionID)")!
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
                incarnation: AgentIncarnationToken("window-fixture")!, transport: .ssh, capabilities: [.observe])
            await runtime.registerCandidate(candidate, fallback: .init(status: .working, location: "Synthetic host",
                integrationAvailable: true, liveTail: "", prompt: nil, binding: binding))
            await runtime.promoteCandidate(candidate, to: sibling)
        }
        for sibling in siblings {
            if let snapshot = await runtime.snapshot(for: sibling.id) { model?.apply(thread: snapshot) }
        }
        NSLog("TESSERA_WINDOW_FIXTURE churnHz=%.1f selected=%d", hertz, churnSelected ? 1 : 0)
        churn = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1 / hertz)) } catch { return }
                guard let self, let model = self.model else { return }
                tick += 1
                let index = tick % siblings.count
                siblings[index].preview = "Step \(tick): reading files and running tools"
                siblings[index].lastActivity = .now
                siblings[index].lastActivitySequence += 1
                await self.runtime.register(siblings[index])
                let sibling = await self.runtime.snapshot(for: siblings[index].id)
                // Page loads replace the reader's snapshot independently of
                // this loop. Publish it only if none landed while this tick
                // was suspended, so a stale copy never reverts a page.
                let seen = model.threadSnapshots[self.thread]
                var reader: AgentThreadSnapshot?
                if churnSelected, var own = seen?.summary {
                    own.lastActivity = .now
                    own.status = .working
                    await self.runtime.register(own)
                    reader = await self.runtime.snapshot(for: self.thread)
                }
                let list = await self.runtime.listSnapshot()
                let started = Date()
                model.apply(list: list)
                if let sibling { model.apply(thread: sibling) }
                if let reader, model.threadSnapshots[self.thread] == seen { model.apply(thread: reader) }
                AgentCenterV2PerformanceDiagnostics.shared.record("publishSync", since: started)
            }
        }
    }

    private func load(_ lane: AgentIngestionWindowTransaction.Lane) async {
        guard let model else { return }
        if busy {
            if lane == .bootstrap { pendingLatest = true }
            return
        }
        busy = true
        if lane != .head { model.loadingTranscriptThreads.insert(thread) }
        defer { finishRead(); model.loadingTranscriptThreads.remove(thread) }
        do {
            // A slow newer read leaves the split's bridge on screen long
            // enough to observe (see exerciseHeadSplit).
            if lane == .after, Self.splitsHead { try await Task.sleep(for: .seconds(5)) }
            // Mirror the production endpoint: a capacity refusal retries a
            // smaller history page before the read is reported as failed.
            var limit = 100
            while true {
            let current = await runtime.ingestionWindowSnapshot(for: thread)
            let before = current?.before.flatMap { Int($0.dropFirst(7)) } ?? count
            let after = current?.after.flatMap { Int($0.dropFirst(7)) } ?? count
            let end = lane == .before ? before : lane == .after ? min(count, after + limit) : count
            let start = lane == .after ? after : max(0, end - limit)
            guard start < end else { return }
            let records: [AgentProjectionRecord] = (start..<end).map { index in
                if let transcript = Self.transcript { return transcript.records[index] }
                let tail = chatFollow && index == count - 1
                // Whitespace-only prose projects to no message at all.
                let hidden = Self.sparse > 0 && index % Self.sparse != 0
                let tool = index % 8 >= 3 && !tail && Self.sparse == 0
                let text = hidden ? " " : tail ? "Chat tail \(index)\n" + (AgentCenterV2Fixture.chatFollowStage == 0 ? "Initial reply." :
                    (1...(AgentCenterV2Fixture.chatFollowStage == 1 ? 80 : 120)).map { "Streaming line \($0) in the same record." }.joined(separator: "\n")) + "\nEnd of latest reply."
                    : Self.richContent ? Self.richText(index)
                    : "History record \(index)\nScroll through older and newer ranges while the live head advances independently."
                let block: AgentJSONValue = tool
                    ? .object(["type": .string("tool_result"), "preview": .string(Self.richContent ? Self.richToolPreview(index)
                        : "Synthetic output \(index)\nA bounded, expandable tool result.")])
                    : .object(["type": .string("text"), "text": .string(text)])
                return .init(sequence: UInt64(index), recordID: "fixture-record-\(index)",
                    record: .object(["type": .string("message"), "role": .string(tool ? "tool" : "assistant"),
                                     // Keep a stable, repeated disclosure near
                                     // each page tail as live updates advance;
                                     // a single fixed row can leave the phone
                                     // viewport before the assertion runs.
                                     "truncated": .bool(index % 8 == 0), "blocks": .array([block])]),
                    revision: chatFollow ? UInt64(AgentCenterV2Fixture.chatFollowStage + 1) : 1)!
            }
            let version: UInt64 = lane == .bootstrap ? 1 : (current?.version ?? 0) + 1
            let transaction = try AgentIngestionWindowTransaction(lane: lane, version: version, segmentID: UUID().uuidString,
                before: "offset_\(start)", after: "offset_\(end)", hasOlder: start > 0, hasNewer: end < count)
            let history = lane == .before || lane == .after
            let range = AgentIngestionRange(epoch: "fixture", requestID: UUID().uuidString,
                operation: lane == .bootstrap ? .bootstrap : history ? .history : .updates,
                liveCursor: history ? nil : "live_\(count)", sourceEnd: history ? nil : UInt64(count), window: transaction)!
            let from = lane == .before ? current?.before : lane == .after ? current?.after : lane == .head ? current?.liveCursor : nil
            // Real transcript records can exceed the page byte bound at 100
            // records; the host cuts such pages short, and so does replay.
            guard let page = AgentProjectionPage(sourceIdentity: "fixture-source", from: from, records: records,
                cursor: (history || lane == .bootstrap) && start > 0 ? transaction.before : nil,
                hasMore: (history || lane == .bootstrap) && start > 0, ingestion: range) else {
                if limit > 1 { limit /= 2; continue }
                throw AgentIngestionError.capacityExceeded
            }
            let result = await runtime.apply(page: page, to: thread)
            if result == .capacityExceeded, history, limit > 1 { limit /= 2; continue }
            guard result.accepted else { throw AgentIngestionError.capacityExceeded }
            retainedSegments[transaction.segmentID!] = try transaction.segment(source: "fixture-source", records: records)
            if let committed = await runtime.ingestionWindowSnapshot(for: thread) {
                let ids = Set(committed.viewportSegmentIDs + (committed.headSegmentID.map { [$0] } ?? []))
                retainedSegments = retainedSegments.filter { ids.contains($0.key) }
            }
            if !preparingDetached {
                if let snapshot = await runtime.snapshot(for: thread) { model.apply(thread: snapshot) }
                model.apply(list: await runtime.listSnapshot())
            }
            let segmentCount = await runtime.ingestionWindowSnapshot(for: thread)?.viewportSegmentIDs.count ?? 0
            NSLog("TESSERA_WINDOW_FIXTURE lane=%@ version=%llu start=%ld end=%ld segments=%ld messages=%ld limit=%ld",
                  lane.rawValue, version, start, end, segmentCount, model.threadSnapshots[thread]?.messages.count ?? 0, limit)
            break
            }
        } catch {
            AgentCenterV2Fixture.rejectedPages += 1
            model.reportUnavailable("Fixture page rejected: \(error)")
        }
    }

    /// Device transcripts carry kilobytes of markdown per record, not one
    /// line. Rich pages stay under the 262,144-byte page limit while making
    /// byte budgets, eviction and rich-text layout cost reproducible.
    private static let richContent = ProcessInfo.processInfo.environment["TESSERA_AGENT_WINDOW_FIXTURE_RICH"] == "1"
    /// Only every Nth record is visible, so a page adds a row or two and the
    /// transcript is shorter than the viewport.
    private static let sparse = Int(ProcessInfo.processInfo.environment["TESSERA_AGENT_WINDOW_FIXTURE_SPARSE"] ?? "") ?? 0
    /// Once the rolled head is kept beside history, a revision splits it so
    /// that its last part no longer holds the viewport's newest record.
    private static let splitsHead = ProcessInfo.processInfo.environment["TESSERA_AGENT_WINDOW_FIXTURE_SPLIT_HEAD"] == "1"

    /// A host-normalized transcript (`{"provider", "records": [{sequence,
    /// recordID, record, revision}]}`) replayed through the same window.
    /// Sequences are rewritten to record offsets, like the host's order.
    private static let transcript: (provider: AgentProviderID, records: [AgentProjectionRecord])? = {
        struct File: Decodable {
            struct Entry: Decodable { let recordID: String; let record: AgentJSONValue; let revision: UInt64? }
            let provider: String
            let records: [Entry]
        }
        guard let path = ProcessInfo.processInfo.environment["TESSERA_AGENT_WINDOW_FIXTURE_TRANSCRIPT"],
              let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(File.self, from: data), !file.records.isEmpty else { return nil }
        let records = file.records.enumerated().map { index, entry in
            AgentProjectionRecord(sequence: UInt64(index), recordID: entry.recordID, record: entry.record, revision: entry.revision ?? 1)
                ?? AgentProjectionRecord(sequence: UInt64(index), recordID: entry.recordID, record: .object([
                    "type": .string("message"), "role": .string("system"),
                    "blocks": .array([.object(["type": .string("text"), "text": .string("Unreplayable record")])])]))!
        }
        NSLog("TESSERA_WINDOW_FIXTURE transcript=%@ records=%ld", file.provider, records.count)
        return (AgentProviderID(rawValue: file.provider) ?? .claude, records)
    }()

    private static func richText(_ index: Int) -> String {
        let sentence = "The allocation lane measured throughput per handling slot and compared the repaired engine against merged main on the same three seeds, so the difference is attributable to the repair rather than to seed noise."
        var parts = ["**History record \(index).** " + sentence + " " + sentence,
                     "- Exporter bid book for record \(index) keeps `bouquet_repair_wave/REPORT.md` bound to its validation file.\n" +
                     "- Hiring queue stays zero-sum; the second handler arrives on day \(100 + index % 230).\n" +
                     "- Retail floor walks toward target in five percent steps over a seven-day window.",
                     sentence + " " + sentence + " " + sentence]
        if index % 4 == 1 {
            parts.append("| Metric | Repairs alone | Repairs + bouquets |\n| --- | ---: | ---: |\n" +
                (0..<8).map { "| Metric \($0) of \(index) | \(Double(index % 97) / 10 - 4.5)% | \(Double((index + $0) % 89) / 10 - 4.4)% |" }
                    .joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func richToolPreview(_ index: Int) -> String {
        "{\"command\":\"sed -n \(index),\(index + 40)p engine/src/sim/kernel/emergence/operators/staffing.cpp; echo; rg -n 'handler' docs/food_repair_trials\"}\n" +
            (0..<12).map { "\(index + $0): staffing.cpp  offer=32.00g/day  queue=\($0 % 5)  slot=handling  result=unchanged" }.joined(separator: "\n")
    }

    private func finishRead() {
        busy = false
        if pendingLatest {
            pendingLatest = false
            Task { await load(.bootstrap) }
        }
    }

    /// Codex and OpenCode revisions can grow the head past the page limit.
    /// The host then keeps only its last part, which the viewport a follower
    /// kept beside the rolled head no longer reaches. The part starts midway
    /// through the rows after the viewport, which leave the retained window.
    private func exerciseHeadSplit() async {
        guard !busy, !didSplit, let model else { return }
        busy = true; defer { finishRead() }
        guard let current = await runtime.ingestionWindowSnapshot(for: thread), current.atLiveHead,
              let headID = current.headSegmentID, current.viewportSegmentIDs.last != headID,
              let head = retainedSegments[headID], let last = current.viewportSegmentIDs.last.flatMap({ retainedSegments[$0] })?.records.last,
              let newer = head.records.firstIndex(where: { $0.sequence > last.sequence }), newer > 0,
              head.records.count - newer >= 2, let first = head.records.first else { return }
        let offset = newer + (head.records.count - newer) / 2
        do {
            let boundary = "offset_\(head.records[offset].sequence)"
            let parts = try [
                AgentIngestionPartition(original: headID, id: UUID().uuidString, before: head.before, after: boundary,
                    offset: 0, count: offset, hasOlder: head.hasOlder, hasNewer: true),
                AgentIngestionPartition(original: headID, id: UUID().uuidString, before: boundary, after: head.after,
                    offset: offset, count: head.records.count - offset, hasOlder: true, hasNewer: head.hasNewer)]
            let patch = AgentProjectionRecord(sequence: first.sequence, recordID: first.recordID, record: first.record,
                sourceOffset: first.sourceOffset, revision: first.revision + 1)!
            let transaction = try AgentIngestionWindowTransaction(lane: .revisions, version: current.version + 1, partitions: parts)
            let range = AgentIngestionRange(epoch: "fixture", requestID: UUID().uuidString, operation: .updates,
                liveCursor: current.liveCursor, sourceEnd: UInt64(count), window: transaction)!
            let page = AgentProjectionPage(sourceIdentity: "fixture-source", from: current.liveCursor, records: [patch], cursor: nil,
                hasMore: false, ingestion: range)!
            guard await runtime.apply(page: page, to: thread).accepted else { throw AgentIngestionError.capacityExceeded }
            // Counted with the split snapshot, never before it is shown.
            if let snapshot = await runtime.snapshot(for: thread) { model.apply(thread: snapshot) }
            AgentCenterV2Fixture.ingestionSourceEnd = count
            AgentCenterV2Fixture.ingestionRevisionSplits += 1
            model.apply(list: await runtime.listSnapshot()); didSplit = true
            NSLog("TESSERA_WINDOW_FIXTURE lane=revisions head partitionCount=%d", parts.count)
        } catch { model.reportUnavailable("Fixture split rejected: \(error)") }
    }

    private func exerciseRevisionSplit() async {
        guard !busy, !didSplit, let model else { return }
        busy = true; defer { finishRead() }
        guard let current = await runtime.ingestionWindowSnapshot(for: thread),
              !current.atLiveHead, let id = current.viewportSegmentIDs.first, let segment = retainedSegments[id],
              let first = segment.records.first, first.sequence < 600, segment.records.count > 1 else { return }
        do {
            let middle = segment.records.count / 2
            let parts = try [
                AgentIngestionPartition(original: id, id: UUID().uuidString, before: segment.before,
                    after: "offset_\(segment.records[middle].sequence)", offset: 0, count: middle, hasOlder: segment.hasOlder, hasNewer: true),
                AgentIngestionPartition(original: id, id: UUID().uuidString, before: "offset_\(segment.records[middle].sequence)",
                    after: segment.after, offset: middle, count: segment.records.count - middle, hasOlder: true, hasNewer: segment.hasNewer)]
            let patch = AgentProjectionRecord(sequence: first.sequence, recordID: first.recordID, record: first.record,
                sourceOffset: first.sourceOffset, revision: first.revision + 1)!
            let transaction = try AgentIngestionWindowTransaction(lane: .revisions, version: current.version + 1, partitions: parts)
            let range = AgentIngestionRange(epoch: "fixture", requestID: UUID().uuidString, operation: .updates,
                liveCursor: current.liveCursor, sourceEnd: UInt64(count), window: transaction)!
            let page = AgentProjectionPage(sourceIdentity: "fixture-source", from: current.liveCursor, records: [patch], cursor: nil,
                hasMore: false, ingestion: range)!
            guard await runtime.apply(page: page, to: thread).accepted else { throw AgentIngestionError.capacityExceeded }
            AgentCenterV2Fixture.ingestionRevisionSplits += 1
            if let snapshot = await runtime.snapshot(for: thread) { model.apply(thread: snapshot) }
            model.apply(list: await runtime.listSnapshot()); didSplit = true
            NSLog("TESSERA_WINDOW_FIXTURE lane=revisions partitionCount=%d", parts.count)
        } catch { model.reportUnavailable("Fixture split rejected: \(error)") }
    }
}

@MainActor
private final class AgentCenterV2FixtureOwner: ObservableObject {
    let model = AgentCenterV2Fixture.makeModel()
}

struct AgentCenterV2FixtureView: View {
    // StateObject's autoclosure runs once for the mounted view identity. An
    // eager State initializer also started orphan drivers on discarded View
    // values, creating duplicate connections and background fixture tasks.
    @StateObject private var fixture = AgentCenterV2FixtureOwner()
    private var model: AgentCenterV2PresentationModel { fixture.model }
    @State private var keyboardFrame = CGRect.zero
    @State private var attachments: AgentComposerAttachments?
    @Environment(\.designTokens) private var T

    private var isCompact: Bool { AgentCenterV2Fixture.Scene.requested == .compact }

    private var fixtureState: String {
        let focus: String
        switch model.keyboardFocus {
        case .none: focus = "none"
        case .list: focus = "list"
        case .search: focus = "search"
        case .composer: focus = "composer"
        case .promptAnswer: focus = "promptAnswer"
        case .action: focus = "action"
        }
        let window = model.selectedThread?.ingestionWindow
        return "scene=\(AgentCenterV2Fixture.Scene.requested.rawValue);appearance=\(AgentCenterV2Fixture.Appearance.requested.rawValue);dynamicType=\(AgentCenterV2Fixture.FixtureDynamicType.requested.rawValue);focus=\(focus);cursor=\(model.selectedThread?.cursor ?? "none");historyLoading=\(!model.loadingTranscriptThreads.isEmpty);windowSegments=\(window?.viewportSegmentIDs.count ?? 0);atLiveHead=\(window?.atLiveHead ?? true);windowVersion=\(window?.version ?? 0);revisionSplits=\(AgentCenterV2Fixture.ingestionRevisionSplits);sourceEnd=\(AgentCenterV2Fixture.ingestionSourceEnd);bridged=\(window?.bridgesToHead == true);tail=\(model.selectedThread?.messages.last?.recordID ?? "none");messages=\(model.selectedThread?.messages.count ?? 0);rejected=\(AgentCenterV2Fixture.rejectedPages);selected=\(model.selectedThreadID?.providerSessionID ?? "none")"
    }

    private func exerciseDiscovery() async {
        guard AgentCenterV2Fixture.Scene.requested == .discovery,
              let snapshot = model.selectedThread, let binding = snapshot.binding else { return }
        let core = AgentCenterRuntime()
        let ids = [AgentProviderID.claude, .codex].map {
            AgentSourceCandidateID(hostID: snapshot.summary.id.hostID, providerID: $0, sourceIdentity: "discovery-\($0.rawValue)")!
        }
        for pass in 0..<100 {
            guard !Task.isCancelled else { return }
            for id in pass.isMultiple(of: 2) ? ids : Array(ids.reversed()) {
                await core.registerCandidate(id, fallback: .init(status: .unavailable, location: "Windows · pane 1",
                    integrationAvailable: false, liveTail: "Ready", prompt: nil, binding: binding),
                    title: id.providerID == .claude ? "Claude stable row" : "Codex stable row", lastActivity: .now)
                model.apply(list: await core.listSnapshot())
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    var body: some View {
        AgentCenterV2RootView(model: model) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tessera").font(Typography.sheetTitle)
                Text("sessions").font(Typography.kicker).foregroundStyle(T.fgDim)
                Label("ubuntu-prod · dev", systemImage: "circle.fill").foregroundStyle(T.fgMuted)
                Label("mac-mini · build", systemImage: "circle.fill").foregroundStyle(T.fgMuted)
                Spacer()
                Label("agents", systemImage: "sparkles").foregroundStyle(T.accent)
            }
            .font(Typography.tesseraMono(size: 11))
            .padding(16)
            .background(T.sidebarBg)
        }
        .frame(width: isCompact ? 390 : nil, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .preferredColorScheme(AgentCenterV2Fixture.Appearance.requested.colorScheme)
        .dynamicTypeSize(AgentCenterV2Fixture.FixtureDynamicType.requested.size)
        .task { await exerciseDiscovery() }
        .onAppear {
            guard attachments == nil else { return }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? "Tessera native attachment fixture\n".write(to: docs.appendingPathComponent("tessera-attachment-fixture.txt"), atomically: true, encoding: .utf8)
            let registration = UUID()
            attachments = AgentComposerAttachments(model: model, targetFor: { thread in
                guard let binding = thread.binding else { return nil }
                return .init(threadID: thread.summary.id, binding: binding, registrationID: registration, generation: 1)
            }, isCurrent: { [weak model] target in
                model?.threadSnapshots[target.threadID]?.binding == target.binding
            }, upload: { _, url in
                _ = try Data(contentsOf: url)
                try? "uploading".write(to: docs.appendingPathComponent("agent-composer-action-capture.txt"), atomically: true, encoding: .utf8)
                try await Task.sleep(for: .seconds(4))
                return "/fixture/private-upload/\(url.lastPathComponent)"
            })
        }
        .onDisappear { attachments?.cancelAll() }
        .onChange(of: model.attachmentPickerRequest?.id) { _, requestID in
            if requestID != nil {
                let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("agent-composer-action-capture.txt")
                try? "picker".write(to: marker, atomically: true, encoding: .utf8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardFrame = frame
            NSLog("TESSERA_AGENT_KEYBOARD frame=%@", NSCoder.string(for: frame))
            if frame.height > 100 {
                // The external runner captures this owned simulator with
                // simctl after the native keyboard has finished presenting.
                let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("agent-composer-keyboard-ready.txt")
                try? NSCoder.string(for: frame).write(to: marker, atomically: true, encoding: .utf8)
            }
        }
        .overlay(alignment: .topTrailing) {
            AgentCenterV2HarnessAccessibilityMarker(identifier: "agent-center-v2-keyboard",
                value: "minY=\(keyboardFrame.minY);height=\(keyboardFrame.height)")
        }
        .overlay(alignment: .bottomLeading) {
            if AgentCenterV2Fixture.Scene.requested == .chatFollow {
                Button("Advance fixture") { AgentCenterV2Fixture.advanceChatFollow?() }
                    .padding(8).accessibilityIdentifier("agent-chat-advance")
            }
        }
        .overlay(alignment: .topLeading) {
            AgentCenterV2HarnessAccessibilityMarker(
                identifier: "agent-center-v2-fixture",
                value: fixtureState
            )
        }
    }
}

/// A distinct harness-only accessibility element. Applying identifiers to a
/// SwiftUI container propagates them to descendants and masks the identifiers
/// on real controls, so capture state uses an inert overlay instead.
struct AgentCenterV2HarnessAccessibilityMarker: View {
    let identifier: String
    var value: String? = nil

    var body: some View {
        if ProcessInfo.processInfo.environment["TESSERA_AGENT_CENTER_V2_HARNESS"] == "1" {
            Text(identifier)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(value ?? identifier)
                .accessibilityIdentifier(value.map { "\(identifier)|\($0)" } ?? identifier)
        }
    }
}
#endif
