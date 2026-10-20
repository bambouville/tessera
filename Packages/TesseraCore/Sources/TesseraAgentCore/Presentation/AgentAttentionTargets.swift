import Foundation

/// The kind of attention an agent thread is asking for. The terminal chrome's
/// attention chip, the jump list behind it, and the Agents navigation badges
/// all classify through here, so a count can never disagree with its rows.
public enum AgentAttentionKind: Int, Comparable, Sendable, CaseIterable {
    /// Blocked on the user. Listed first: it is the only kind that stops work.
    case needsInput = 0
    /// Completed away from the user's view and not yet seen.
    case finished = 1

    /// `nil` when the thread needs no attention. A thread that is waiting for
    /// input is never also counted as finished.
    public init?(_ summary: AgentThreadSummary) {
        if summary.attention == .needsYou || summary.status == .waitingForInput {
            self = .needsInput
        } else if summary.attention == .unreadCompletion {
            self = .finished
        } else {
            return nil
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AgentAttentionCounts: Equatable, Sendable {
    public var needsInput: Int
    public var finished: Int

    public init(needsInput: Int = 0, finished: Int = 0) {
        self.needsInput = needsInput
        self.finished = finished
    }

    public init(threads: [AgentThreadSummary]) {
        self.init()
        for thread in threads {
            switch AgentAttentionKind(thread) {
            case .needsInput: needsInput += 1
            case .finished: finished += 1
            case nil: break
            }
        }
    }

    public var total: Int { needsInput + finished }
}

/// Where one attention row can take the user.
public enum AgentAttentionDestination: Equatable, Sendable {
    /// The exact terminal the agent runs in is still live: its tmux pane, or
    /// the single foreground program of a raw SSH/mosh session. Platforms
    /// re-prove this binding against the live terminal before moving focus.
    case terminal(AgentTerminalBinding)
    /// No live terminal proves where the agent is any more: its session is
    /// disconnected, the pane closed, or the thread is known only from
    /// history. The thread can still be reviewed in Agent Center. Nothing may
    /// start a connection to reach it.
    case agentCenter
}

public struct AgentAttentionEntry: Equatable, Sendable, Identifiable {
    public let threadID: AgentThreadID
    public let kind: AgentAttentionKind
    public let title: String
    public let providerName: String
    public let hostDisplayLabel: String
    /// The binding Core last knew, for a location label ("window 3 · pane
    /// %21"). Display only: it may be stale, and only `destination` routes.
    public let lastKnownBinding: AgentTerminalBinding?
    public let destination: AgentAttentionDestination

    public var id: AgentThreadID { threadID }

    public var terminalBinding: AgentTerminalBinding? {
        if case .terminal(let binding) = destination { return binding }
        return nil
    }

    public init(
        threadID: AgentThreadID,
        kind: AgentAttentionKind,
        title: String,
        providerName: String,
        hostDisplayLabel: String,
        lastKnownBinding: AgentTerminalBinding?,
        destination: AgentAttentionDestination
    ) {
        self.threadID = threadID
        self.kind = kind
        self.title = title
        self.providerName = providerName
        self.hostDisplayLabel = hostDisplayLabel
        self.lastKnownBinding = lastKnownBinding
        self.destination = destination
    }
}

/// Builds the attention chip's jump list: every thread that needs input or
/// finished unseen, needs-input first, newest first within a kind, each with
/// the one place a tap can take the user.
///
/// Visiting the agent's terminal is what marks a completion seen; opening the
/// list does not. The platform supplies the two facts Core cannot know: the
/// thread's current binding and whether that binding is still backed by a
/// live, registered terminal route.
public enum AgentAttentionTargets {
    public static func entries(
        threads: [AgentThreadSummary],
        binding: (AgentThreadID) -> AgentTerminalBinding?,
        isLive: (AgentThreadID, AgentTerminalBinding) -> Bool
    ) -> [AgentAttentionEntry] {
        let ranked: [(summary: AgentThreadSummary, kind: AgentAttentionKind)] = threads.compactMap { summary in
            AgentAttentionKind(summary).map { (summary, $0) }
        }
        return ranked.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            let lhsActivity = lhs.summary.lastActivity ?? .distantPast
            let rhsActivity = rhs.summary.lastActivity ?? .distantPast
            if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
            if lhs.summary.lastActivitySequence != rhs.summary.lastActivitySequence {
                return lhs.summary.lastActivitySequence > rhs.summary.lastActivitySequence
            }
            return stableKey(lhs.summary.id) < stableKey(rhs.summary.id)
        }.map { summary, kind in
            let known = binding(summary.id)
            // Opening a pane re-proves the agent's process in it. A binding
            // observed without a process ID can never pass that proof, so it
            // is reviewable only, never offered as a jump that must fail.
            let destination: AgentAttentionDestination = if let known, known.agentPID != nil, isLive(summary.id, known) {
                .terminal(known)
            } else {
                .agentCenter
            }
            return AgentAttentionEntry(
                threadID: summary.id,
                kind: kind,
                title: summary.title,
                providerName: summary.providerName,
                hostDisplayLabel: summary.hostDisplayLabel,
                lastKnownBinding: known,
                destination: destination
            )
        }
    }

    private static func stableKey(_ id: AgentThreadID) -> String {
        "\(id.hostID.uuidString)\u{1F}\(id.providerID.rawValue)\u{1F}\(id.providerSessionID)"
    }
}
