import Foundation
import Observation
import SwiftUI
import TmuxControl
import TmuxControlCore

/// Where one tmux pane sits, for labels and routing. Raw SSH has none.
struct ProgramStatusPaneLocation: Equatable, Sendable {
    let windowID: Int
    /// 1-based position in the tab strip, the "window 2" users see.
    let windowPosition: Int
    let windowName: String
}

/// One live session's reported program status (OSC 7501), as the chrome
/// presents it. The records themselves live in the session's
/// `TmuxController`; this is its published projection.
struct ProgramStatusSessionState: Equatable {
    let hostLabel: String
    let snapshot: ProgramStatusSnapshot
    /// tmux pane number → its window. Empty for raw SSH.
    let locations: [Int: ProgramStatusPaneLocation]
}

/// The tone a cue, count or row takes. Precedence is needs input > failed >
/// finished, the same order the rows are listed in.
enum ChromeAttentionTone: Int, Comparable, Sendable {
    case needsInput = 0
    case failed = 1
    case finished = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    func color(_ T: DesignTokens) -> Color {
        switch self {
        case .needsInput: T.amber
        case .failed: T.red
        case .finished: T.green
        }
    }
}

extension ProgramStatusAttention {
    var tone: ChromeAttentionTone {
        switch self {
        case .needsInput: .needsInput
        case .failed: .failed
        case .finished: .finished
        }
    }
}

extension ProgramStatusTerminalKey {
    /// tmux pane number, nil for the raw terminal.
    var paneNumber: Int? {
        if case .pane(let pane) = self { return pane.rawValue }
        return nil
    }
}

extension ProgramStatusTerminalSnapshot {
    /// The program is reporting live work: a non-historical working or
    /// blocked record.
    var isLive: Bool {
        entries.contains { !$0.isHistorical && ($0.state == .working || $0.state == .blocked) }
    }
}

/// A pane hosting a verified agent shows one cue, not two: Agent Center's
/// verdict merged with the agent's own report. Native status owns live
/// state, so while the agent reports working or blocked a late fallback
/// completion is stale and shows nothing; otherwise the higher-precedence
/// verdict wins.
enum ChromeAttentionMerge {
    static func attention(
        agentNeedsInput: Bool,
        agentUnreadCompletion: Bool,
        program: ProgramStatusTerminalSnapshot?
    ) -> ProgramStatusAttention? {
        let native = program?.attention
        if program?.isLive == true { return native }
        let agent: ProgramStatusAttention? = agentNeedsInput
            ? .needsInput(nil)
            : (agentUnreadCompletion ? .finished : nil)
        // Native first: of equal tones, its blocked kind is the specific one.
        return [native, agent].compactMap { $0 }.min { $0.tone < $1.tone }
    }
}

/// Counts behind the chip, the iPhone Sessions badge and session rows.
struct ChromeAttentionCounts: Equatable {
    var needsInput = 0
    var failed = 0
    var finished = 0
    /// The blocked kinds counted in `needsInput`; nil stands for "no kind".
    private(set) var needsInputKinds: Set<ProgramStatusBlockedKind?> = []

    init(needsInput: Int = 0, failed: Int = 0, finished: Int = 0) {
        self.needsInput = needsInput
        self.failed = failed
        self.finished = finished
        if needsInput > 0 { needsInputKinds = [nil] }
    }

    var total: Int { needsInput + failed + finished }

    /// Specific words apply only when every waiting record agrees.
    var uniformNeedsInputKind: ProgramStatusBlockedKind? {
        needsInputKinds.count == 1 ? needsInputKinds.first ?? nil : nil
    }

    mutating func add(_ attention: ProgramStatusAttention?, _ delta: Int = 1) {
        switch attention {
        case .needsInput(let kind)?:
            needsInput += delta
            if delta > 0 { needsInputKinds.insert(kind) }
        case .failed?: failed += delta
        case .finished?: finished += delta
        case nil: break
        }
    }

    /// Tint: amber if anything waits, else red if anything failed, else green.
    var tone: ChromeAttentionTone? {
        if needsInput > 0 { return .needsInput }
        if failed > 0 { return .failed }
        if finished > 0 { return .finished }
        return nil
    }
}

/// One terminal's merged cue within a session.
struct ChromeTerminalAttention {
    let windowID: Int?
    let paneID: Int?
    /// A verified agent runs here (Agent Center on): the sparkles glyph.
    let hasAgent: Bool
    let attention: ProgramStatusAttention?
    /// The terminal's own records, when it reports any.
    let program: ProgramStatusTerminalSnapshot?
}

/// One terminal that needs the user, for the chip's list.
struct ProgramAttentionItem: Identifiable, Equatable {
    let sessionID: UUID
    let hostLabel: String
    let terminal: ProgramStatusTerminalKey
    let location: ProgramStatusPaneLocation?
    let attention: ProgramStatusAttention
    let hasAgent: Bool
    /// The record that names the terminal (`primaryEntry`).
    let entry: ProgramStatusEntry

    var id: String { "\(sessionID.uuidString)|\(terminal.paneNumber.map { "%\($0)" } ?? "raw")" }
    var tone: ChromeAttentionTone { attention.tone }
}

/// Every live session's program status, for chrome that spans sessions (the
/// chip, the iPhone Sessions page and badge, the switcher). Presenting a
/// pane acknowledges its unread results, exactly like Agent Center's
/// existing rule: visiting the pane marks it checked; opening a list does not.
@MainActor
@Observable
final class ProgramStatusCenter {
    private(set) var sessions: [UUID: ProgramStatusSessionState] = [:]

    @ObservationIgnored private var acknowledgers: [UUID: (ProgramStatusTerminalKey, UInt64) -> Void] = [:]
    @ObservationIgnored private var presented: [UUID: Set<ProgramStatusTerminalKey>] = [:]
    @ObservationIgnored private var applicationActive = true
    @ObservationIgnored private var applicationObscured = false
    @ObservationIgnored private var obscuredSessions: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var applicationCovers: Set<UUID> = []
    /// Shows a live session and focuses one of its terminals; the app's
    /// navigation owns it. Never starts a connection.
    @ObservationIgnored var onOpenTerminal: ((_ sessionID: UUID, _ windowID: Int?, _ paneID: Int?) -> Void)?

    func publish(
        sessionID: UUID,
        state: ProgramStatusSessionState,
        acknowledge: @escaping (ProgramStatusTerminalKey, UInt64) -> Void
    ) {
        acknowledgers[sessionID] = acknowledge
        let next: ProgramStatusSessionState? = state.snapshot.terminals.isEmpty ? nil : state
        if sessions[sessionID] != next { sessions[sessionID] = next }
        acknowledgePresented(sessionID)
    }

    func remove(sessionID: UUID) {
        if sessions[sessionID] != nil { sessions[sessionID] = nil }
        acknowledgers[sessionID] = nil
        presented[sessionID] = nil
        obscuredSessions[sessionID] = nil
    }

    /// The terminals the user is looking at in this session: the focused tmux
    /// pane (every pane of a mounted grid), or the raw terminal. Empty when
    /// the session is not on screen.
    func setPresented(sessionID: UUID, terminals: Set<ProgramStatusTerminalKey>) {
        let next = terminals.isEmpty ? nil : terminals
        guard presented[sessionID] != next else { return }
        presented[sessionID] = next
        acknowledgePresented(sessionID)
    }

    func setApplicationActive(_ active: Bool) {
        applicationActive = active
        guard active else { return }
        for sessionID in presented.keys { acknowledgePresented(sessionID) }
    }

    func setApplicationObscured(_ obscured: Bool) {
        guard applicationObscured != obscured else { return }
        applicationObscured = obscured
        guard !obscured else { return }
        for sessionID in presented.keys { acknowledgePresented(sessionID) }
    }

    /// A presentation that hides whichever session is on screen, such as a
    /// sheet presented from session chrome. Keyed by presenter like
    /// `setSessionObscured`.
    func setApplicationCovered(_ covered: Bool, source: UUID) {
        let changed = covered ? applicationCovers.insert(source).inserted : applicationCovers.remove(source) != nil
        guard changed, applicationCovers.isEmpty else { return }
        for sessionID in presented.keys { acknowledgePresented(sessionID) }
    }

    /// Independent presenters release only their own cover, so dismissing one
    /// modal cannot check a terminal still covered by another.
    func setSessionObscured(_ obscured: Bool, sessionID: UUID, source: UUID) {
        var sources = obscuredSessions[sessionID] ?? []
        if obscured { sources.insert(source) } else { sources.remove(source) }
        obscuredSessions[sessionID] = sources.isEmpty ? nil : sources
        guard sources.isEmpty else { return }
        acknowledgePresented(sessionID)
    }

    private func acknowledgePresented(_ sessionID: UUID) {
        guard applicationActive, !applicationObscured, applicationCovers.isEmpty,
              obscuredSessions[sessionID] == nil,
              let keys = presented[sessionID],
              let state = sessions[sessionID],
              let acknowledge = acknowledgers[sessionID]
        else { return }
        for key in keys {
            if let token = state.snapshot.terminal(key)?.latestUnreadResultToken {
                acknowledge(key, token)
            }
        }
    }

    /// Opens a row's pane, re-proving it against the current records: a
    /// session that ended or a pane that closed since the list was drawn
    /// opens nothing.
    func open(_ item: ProgramAttentionItem) {
        openTerminal(sessionID: item.sessionID, key: item.terminal)
    }

    func openTerminal(sessionID: UUID, key: ProgramStatusTerminalKey) {
        guard let state = sessions[sessionID], state.snapshot.terminal(key) != nil else { return }
        let location = key.paneNumber.flatMap { state.locations[$0] }
        if key.paneNumber != nil, location == nil { return }
        onOpenTerminal?(sessionID, location?.windowID, key.paneNumber)
    }

    // MARK: - Queries

    func terminal(sessionID: UUID, key: ProgramStatusTerminalKey) -> ProgramStatusTerminalSnapshot? {
        sessions[sessionID]?.snapshot.terminal(key)
    }

    func location(sessionID: UUID, key: ProgramStatusTerminalKey) -> ProgramStatusPaneLocation? {
        key.paneNumber.flatMap { sessions[sessionID]?.locations[$0] }
    }

    /// Reporting terminals in one tmux window, in pane order.
    func windowTerminals(sessionID: UUID, windowID: Int) -> [ProgramStatusTerminalSnapshot] {
        guard let state = sessions[sessionID] else { return [] }
        return state.snapshot.terminals.filter { terminal in
            terminal.key.paneNumber.flatMap { state.locations[$0]?.windowID } == windowID
        }
    }

    /// The record a window's status line describes: its most urgent
    /// terminal's primary record, else the first reporting pane's.
    func windowPrimaryEntry(sessionID: UUID, windowID: Int) -> ProgramStatusEntry? {
        let terminals = windowTerminals(sessionID: sessionID, windowID: windowID)
        let urgent = terminals.filter { $0.attention != nil }.min { lhs, rhs in
            lhs.attention!.tone < rhs.attention!.tone
        }
        return (urgent ?? terminals.first)?.primaryEntry
    }

    /// Program rows for the chip's list: every reporting terminal that needs
    /// the user without a fallback attention row already in Agent Center.
    func programItems(agentCenter: AgentCenterV2Coordinator) -> [ProgramAttentionItem] {
        programItems(agentAttention: agentCenter.paneAgentAttention)
    }

    func programItems(
        agentAttention: (UUID, Int?) -> (needsInput: Bool, unreadCompletion: Bool)?
    ) -> [ProgramAttentionItem] {
        var items: [ProgramAttentionItem] = []
        for (sessionID, state) in sessions {
            for terminal in state.snapshot.terminals {
                let agent = agentAttention(sessionID, terminal.key.paneNumber)
                guard agent?.needsInput != true, agent?.unreadCompletion != true,
                      let attention = terminal.attention,
                      let entry = terminal.primaryEntry
                else { continue }
                items.append(ProgramAttentionItem(
                    sessionID: sessionID,
                    hostLabel: state.hostLabel,
                    terminal: terminal.key,
                    location: terminal.key.paneNumber.flatMap { state.locations[$0] },
                    attention: attention,
                    hasAgent: agent != nil,
                    entry: entry
                ))
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.tone != rhs.tone { return lhs.tone < rhs.tone }
            if lhs.hostLabel != rhs.hostLabel { return lhs.hostLabel < rhs.hostLabel }
            return (lhs.location?.windowPosition ?? 0) < (rhs.location?.windowPosition ?? 0)
        }
    }

    /// Records of one session for the host pill's details, attention first.
    func detailEntries(sessionID: UUID) -> [(entry: ProgramStatusEntry, location: ProgramStatusPaneLocation?)] {
        guard let state = sessions[sessionID] else { return [] }
        let rows = state.snapshot.terminals.flatMap { terminal in
            terminal.entries.map { entry in
                (entry: entry, location: terminal.key.paneNumber.flatMap { state.locations[$0] })
            }
        }
        return rows.sorted { lhs, rhs in
            let l = lhs.entry.attention?.tone.rawValue ?? 3
            let r = rhs.entry.attention?.tone.rawValue ?? 3
            if l != r { return l < r }
            return (lhs.location?.windowPosition ?? 0) < (rhs.location?.windowPosition ?? 0)
        }
    }

    // MARK: - Merged with Agent Center

    /// One merged cue per terminal of a session: every reporting program and
    /// every terminal with a verified agent, merged where they coincide.
    func mergedTerminals(sessionID: UUID, agentCenter: AgentCenterV2Coordinator) -> [ChromeTerminalAttention] {
        let state = sessions[sessionID]
        var agents: [Int?: (windowID: Int?, needsInput: Bool, unreadCompletion: Bool)] = [:]
        for agent in agentCenter.boundAgentTerminals(sessionID: sessionID) {
            agents[agent.paneID] = (agent.windowID, agent.needsInput, agent.unreadCompletion)
        }
        var result: [ChromeTerminalAttention] = []
        for terminal in state?.snapshot.terminals ?? [] {
            let pane = terminal.key.paneNumber
            let windowID = pane.flatMap { state?.locations[$0]?.windowID }
            if let agent = agents.removeValue(forKey: pane) {
                result.append(ChromeTerminalAttention(
                    windowID: windowID ?? agent.windowID,
                    paneID: pane,
                    hasAgent: true,
                    attention: ChromeAttentionMerge.attention(
                        agentNeedsInput: agent.needsInput,
                        agentUnreadCompletion: agent.unreadCompletion,
                        program: terminal
                    ),
                    program: terminal
                ))
            } else {
                result.append(ChromeTerminalAttention(
                    windowID: windowID, paneID: pane, hasAgent: false,
                    attention: terminal.attention, program: terminal
                ))
            }
        }
        for (pane, agent) in agents {
            result.append(ChromeTerminalAttention(
                windowID: agent.windowID,
                paneID: pane,
                hasAgent: true,
                attention: ChromeAttentionMerge.attention(
                    agentNeedsInput: agent.needsInput,
                    agentUnreadCompletion: agent.unreadCompletion,
                    program: nil
                ),
                program: nil
            ))
        }
        return result
    }

    /// A tmux tab's cue: the highest-precedence pane, and whether any pane
    /// hosts a verified agent (the sparkles glyph).
    func windowCue(
        sessionID: UUID,
        windowID: Int,
        agentCenter: AgentCenterV2Coordinator
    ) -> (hasAgent: Bool, tone: ChromeAttentionTone?) {
        let terminals = mergedTerminals(sessionID: sessionID, agentCenter: agentCenter)
            .filter { $0.windowID == windowID }
        return (terminals.contains(where: \.hasAgent), terminals.compactMap { $0.attention?.tone }.min())
    }

    /// A window's words for compact rows: its most urgent terminal, else
    /// the first one reporting anything.
    func windowStatus(sessionID: UUID, windowID: Int, agentCenter: AgentCenterV2Coordinator) -> ChromeStatusWords? {
        let terminals = mergedTerminals(sessionID: sessionID, agentCenter: agentCenter)
            .filter { $0.windowID == windowID }
        let urgent = terminals.filter { $0.attention != nil }.min { $0.attention!.tone < $1.attention!.tone }
        return (urgent ?? terminals.first { $0.program != nil }).flatMap(ChromeStatusWords.init)
    }

    func paneStatus(sessionID: UUID, paneID: Int, agentCenter: AgentCenterV2Coordinator) -> ChromeStatusWords? {
        mergedTerminals(sessionID: sessionID, agentCenter: agentCenter)
            .first { $0.paneID == paneID }
            .flatMap(ChromeStatusWords.init)
    }

    /// One session's merged attention, for session rows and the switcher.
    func sessionCounts(sessionID: UUID, agentCenter: AgentCenterV2Coordinator) -> ChromeAttentionCounts {
        var counts = ChromeAttentionCounts()
        for terminal in mergedTerminals(sessionID: sessionID, agentCenter: agentCenter) {
            counts.add(terminal.attention)
        }
        return counts
    }

    /// Chip and badge counts: Agent Center's live agents, adjusted where an
    /// agent also reports its own status, plus every other reporting program.
    func counts(agentCenter: AgentCenterV2Coordinator) -> ChromeAttentionCounts {
        let agents = agentCenter.attentionBadgeCounts
        var counts = ChromeAttentionCounts(needsInput: agents.waiting, failed: 0, finished: agents.finished)
        for (sessionID, state) in sessions {
            for terminal in state.snapshot.terminals {
                let pane = terminal.key.paneNumber
                guard let agent = agentCenter.paneAgentAttention(sessionID: sessionID, paneID: pane) else {
                    counts.add(terminal.attention)
                    continue
                }
                let before: ProgramStatusAttention? = agent.needsInput
                    ? .needsInput(nil)
                    : (agent.unreadCompletion ? .finished : nil)
                let merged = ChromeAttentionMerge.attention(
                    agentNeedsInput: agent.needsInput,
                    agentUnreadCompletion: agent.unreadCompletion,
                    program: terminal
                )
                guard before?.tone != merged?.tone else { continue }
                counts.add(before, -1)
                counts.add(merged)
            }
        }
        // Agent Center counts with Core's classifier; never show a negative
        // where the two disagree for a moment.
        counts.needsInput = max(0, counts.needsInput)
        counts.finished = max(0, counts.finished)
        return counts
    }
}

// MARK: - Words

/// A terminal's status for compact rows (the switcher): merged attention
/// words when it needs the user, else what its program reports: working with
/// progress, ready, a checked result, or status unavailable.
struct ChromeStatusWords: Equatable {
    let app: String?
    /// `needs approval`, `working · 42%`.
    let text: String
    /// Attention tints; nil reads dim.
    let tone: ChromeAttentionTone?

    init?(_ terminal: ChromeTerminalAttention) {
        let entry = terminal.program?.primaryEntry
        app = entry?.app
        if let attention = terminal.attention {
            tone = attention.tone
            if let entry, entry.attention == attention {
                text = Self.words(entry)
            } else {
                text = ProgramStatusWords.attention(attention)
            }
        } else if let entry {
            tone = nil
            text = Self.words(entry)
        } else {
            return nil
        }
    }

    private static func words(_ entry: ProgramStatusEntry) -> String {
        [ProgramStatusWords.state(entry), ProgramStatusWords.progress(entry)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The one attention vocabulary for agents and other programs (UX-14):
/// lowercase, noun-free, as the app writes it.
enum ProgramStatusWords {
    static func blocked(_ kind: ProgramStatusBlockedKind?) -> String {
        switch kind {
        case .permission?: String(localized: "needs approval", comment: "Program status: a program waits for the user to approve an action.")
        case .question?: String(localized: "needs an answer", comment: "Program status: a program asked the user a question.")
        case .auth?: String(localized: "sign-in needed", comment: "Program status: a program waits for the user to sign in.")
        case nil: String(localized: "needs input", comment: "Program status: a program waits for the user.")
        }
    }

    static func attention(_ attention: ProgramStatusAttention) -> String {
        switch attention {
        case .needsInput(let kind): blocked(kind)
        case .failed: String(localized: "failed", comment: "Program status: a program reported that its work failed.")
        case .finished: String(localized: "finished", comment: "Program status: a program reported that its work finished.")
        }
    }

    /// State words for any record, attention or not.
    static func state(_ entry: ProgramStatusEntry) -> String {
        if entry.isHistorical {
            return String(localized: "status unavailable", comment: "Program status: the last report can no longer be confirmed (connection lost or output missed).")
        }
        switch entry.state {
        case .idle: return String(localized: "ready", comment: "Program status: a program reported that it is idle.")
        case .working: return String(localized: "working", comment: "Program status: a program reported that it is working.")
        case .blocked: return blocked(entry.kind)
        case .done: return attention(.finished)
        case .error: return attention(.failed)
        }
    }

    /// Reported progress, as a locale-formatted percentage.
    static func progress(_ entry: ProgramStatusEntry) -> String? {
        guard !entry.isHistorical, let progress = entry.progress else { return nil }
        return (Double(progress) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// The record's name: its title, then its app, then the window, then
    /// "program".
    static func name(_ entry: ProgramStatusEntry, windowName: String?) -> String {
        if let title = entry.title, !title.isEmpty { return title }
        if let app = entry.app, !app.isEmpty { return app }
        if let windowName, !windowName.isEmpty { return windowName }
        return String(localized: "program", comment: "Program status: name of a reporting program that gave none.")
    }

    /// `cargo · working · 42%`: app (when reported), state, progress.
    static func line(_ entry: ProgramStatusEntry) -> String {
        var parts: [String] = []
        if let app = entry.app, !app.isEmpty { parts.append(app) }
        parts.append(state(entry))
        if let progress = progress(entry) { parts.append(progress) }
        return parts.joined(separator: " · ")
    }

    /// Per-state parts of a count, each to be tinted on its own:
    /// `2 need input`, `1 failed`, `1 finished`. Specific blocked words
    /// apply when `specificKinds` and every waiting record agrees.
    static func countParts(_ counts: ChromeAttentionCounts, specificKinds: Bool) -> [(text: String, tone: ChromeAttentionTone)] {
        var parts: [(text: String, tone: ChromeAttentionTone)] = []
        if counts.needsInput > 0 {
            let n = counts.needsInput
            let text: String = switch specificKinds ? counts.uniformNeedsInputKind : nil {
            case .permission?: String(localized: "\(n) need approval", comment: "Attention count. Pluralized on the number of programs waiting for approval.")
            case .question?: String(localized: "\(n) need an answer", comment: "Attention count. Pluralized on the number of programs that asked a question.")
            case .auth?: String(localized: "\(n) need sign-in", comment: "Attention count. Pluralized on the number of programs waiting for sign-in.")
            case nil: String(localized: "\(n) need input", comment: "Attention count. Pluralized on the number of programs or agents waiting for input.")
            }
            parts.append((text, .needsInput))
        }
        if counts.failed > 0 {
            parts.append((String(localized: "\(counts.failed) failed", comment: "Attention count. Pluralized on the number of programs whose work failed."), .failed))
        }
        if counts.finished > 0 {
            parts.append((String(localized: "\(counts.finished) finished", comment: "Attention count. Pluralized on the number of programs or agents that finished."), .finished))
        }
        return parts
    }

    static func countSummary(_ counts: ChromeAttentionCounts, specificKinds: Bool = false) -> String {
        countParts(counts, specificKinds: specificKinds).map(\.text).joined(separator: " · ")
    }

    /// The parts as one Text, each tinted by its state.
    static func countText(_ counts: ChromeAttentionCounts, specificKinds: Bool, T: DesignTokens) -> Text {
        var text = Text(verbatim: "")
        for (index, part) in countParts(counts, specificKinds: specificKinds).enumerated() {
            if index > 0 { text = text + Text(verbatim: " · ").foregroundColor(T.fgDim) }
            text = text + Text(verbatim: part.text).foregroundColor(part.tone.color(T))
        }
        return text
    }
}

// MARK: - Session wiring

extension ProgramStatusCenter {
    /// Publishes one session controller's records with its tab-strip
    /// locations. Called on every record or window change; equality-gated.
    func publish(sessionID: UUID, hostLabel: String, tmux: TmuxController) {
        let snapshot = tmux.programStatus
        var locations: [Int: ProgramStatusPaneLocation] = [:]
        if !snapshot.terminals.isEmpty {
            for (index, window) in tmux.windows.enumerated() {
                let location = ProgramStatusPaneLocation(
                    windowID: window.id.rawValue,
                    windowPosition: index + 1,
                    windowName: window.name
                )
                for pane in window.panes { locations[pane.id.rawValue] = location }
                if let active = window.activePaneId { locations[active.rawValue] = location }
            }
        }
        publish(
            sessionID: sessionID,
            state: ProgramStatusSessionState(hostLabel: hostLabel, snapshot: snapshot, locations: locations),
            acknowledge: { [weak tmux] key, token in
                tmux?.acknowledgeProgramStatus(terminal: key, through: token)
            }
        )
    }

    /// What the session shows: every pane of a mounted grid, else the
    /// focused pane; the raw terminal outside tmux. Nothing while hidden.
    static func presentedTerminals(
        isActive: Bool,
        isObscured: Bool = false,
        tmux: TmuxController,
        gridWindow: TmuxController.WindowInfo?
    ) -> Set<ProgramStatusTerminalKey> {
        guard isActive, !isObscured else { return [] }
        guard tmux.mode == .tmuxControl else { return [.raw] }
        if let gridWindow, !gridWindow.panes.isEmpty {
            return Set(gridWindow.panes.map { .pane($0.id) })
        }
        let pane = tmux.controlPath == .inline ? tmux.renderedPaneId : tmux.activePaneId
        return pane.map { [.pane($0)] } ?? []
    }
}

private struct ProgramStatusObscuredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var programStatusObscured: Bool {
        get { self[ProgramStatusObscuredKey.self] }
        set { self[ProgramStatusObscuredKey.self] = newValue }
    }
}

/// Publishes one live session's program status to the app-wide center and
/// reports which of its terminals are on screen. One modifier per session
/// view keeps the bridge out of their long modifier chains.
struct ProgramStatusSessionBridge: ViewModifier {
    let sessionID: UUID
    let hostLabel: String
    let tmux: TmuxController
    let enabled: Bool
    let presented: Set<ProgramStatusTerminalKey>
    @Environment(ProgramStatusCenter.self) private var center
    @Environment(\.programStatusObscured) private var applicationObscured

    private var visibleTerminals: Set<ProgramStatusTerminalKey> { applicationObscured ? [] : presented }

    private func publish() {
        center.setPresented(sessionID: sessionID, terminals: visibleTerminals)
        center.setApplicationObscured(applicationObscured)
        center.publish(sessionID: sessionID, hostLabel: hostLabel, tmux: tmux)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                tmux.programStatusEnabled = enabled
                publish()
            }
            .onChange(of: enabled) { _, isEnabled in
                tmux.programStatusEnabled = isEnabled
            }
            .onChange(of: tmux.programStatus) { _, _ in
                publish()
            }
            .onChange(of: tmux.windows) { _, _ in
                guard !tmux.programStatus.terminals.isEmpty else { return }
                publish()
            }
            .onChange(of: visibleTerminals) { _, terminals in
                center.setPresented(sessionID: sessionID, terminals: terminals)
            }
            .onDisappear {
                center.remove(sessionID: sessionID)
            }
    }
}

/// The host pill's "programs" section (UX-13): every record in the session,
/// working, ready, checked and historical included, with its full message.
/// The always-reachable detail surface; opening it acknowledges nothing.
struct ProgramStatusDetailsList: View {
    let sessionID: UUID
    let T: DesignTokens
    let onOpen: (ProgramStatusTerminalKey) -> Void
    @Environment(ProgramStatusCenter.self) private var center

    var body: some View {
        let rows = center.detailEntries(sessionID: sessionID)
        if !rows.isEmpty {
            let content = VStack(alignment: .leading, spacing: 8) {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 0.5)
                Text("programs", comment: "Connection popover section listing what programs in this session report (OSC 7501).")
                    .font(Typography.tesseraMono(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    detailRow(row.entry, location: row.location, index: index)
                }
            }
            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView { content }
                    .frame(height: 360)
            }
            .frame(maxHeight: 360)
            .accessibilityIdentifier("program-status-details")
        }
    }

    private func detailRow(_ entry: ProgramStatusEntry, location: ProgramStatusPaneLocation?, index: Int) -> some View {
        let name = ProgramStatusWords.name(entry, windowName: location?.windowName)
        let tint = entry.attention?.tone.color(T) ?? Color.white.opacity(0.5)
        let place = placeText(entry, location: location)
        let canOpen = !entry.isHistorical && (entry.terminal.paneNumber == nil || location != nil)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.idPath.isEmpty ? name : name + " · " + entry.idPath.joined(separator: "/"))
                    .font(Typography.tesseraMono(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(entry.isHistorical ? 0.5 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: ProgramStatusWords.line(entry))
                    .font(Typography.tesseraMono(size: 10, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if let message = entry.message, !message.isEmpty {
                    Text(verbatim: message)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(entry.isHistorical ? 0.45 : 0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: place)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if canOpen {
                Button { onOpen(entry.terminal) } label: {
                    Label("open pane", systemImage: "terminal")
                        .font(Typography.tesseraMono(size: 10, weight: .medium))
                        .foregroundStyle(T.accent)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 28)
                        .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(
                    localized: "Open \(name), \(place)",
                    comment: "Programs list: go to the pane of a reporting program. Arguments: program name, location."
                ))
                .accessibilityIdentifier("program-status-open-\(index)")
            } else {
                Text("pane unavailable")
                    .font(Typography.tesseraMono(size: 9.5))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minHeight: 28)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func placeText(_ entry: ProgramStatusEntry, location: ProgramStatusPaneLocation?) -> String {
        guard let pane = entry.terminal.paneNumber else {
            return String(localized: "raw session", comment: "Program location: the session does not run tmux.")
        }
        var parts: [String] = []
        if let location {
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
}
