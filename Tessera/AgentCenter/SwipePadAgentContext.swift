// Tessera/AgentCenter/SwipePadAgentContext.swift
// Equality-gated projection of the focused pane's hook-proven agent.
import Foundation
import Observation

/// Immutable snapshot of the one agent instance under the focused terminal
/// surface. `prompt` inherits `AgentInstance`'s invariant: non-nil only while
/// `status == .waitingForInput` and the menu has been corroborated as visibly
/// on screen, so a non-nil prompt means the options are answerable right now.
struct SwipePadAgentSnapshot: Equatable, Sendable {
    let agentID: AgentInstanceID
    let profileID: UUID
    let profileName: String
    let status: AgentStatus
    let prompt: AgentPrompt?
    let statusChangedAt: Date
    /// When this agent instance was first detected — a new detection in the
    /// same pane is a different incarnation.
    let detectedAt: Date
    /// Provider-owned conversation identifier, when the lifecycle events
    /// carry one. Distinguishes a replaced agent run in the same pane.
    let providerSessionID: String?
    /// PID from the newest accepted lifecycle event. Distinguishes a
    /// same-pane process replacement even within one provider session id.
    let agentPID: Int?

    /// Fire-guard identity of the exact answerable state. Beyond WHICH
    /// surface (session/pane), it pins the agent *incarnation* (detection
    /// epoch, provider session, PID) and the *state epoch*
    /// (`statusChangedAt`), so a same-pane process replacement or an
    /// A→B→A status flip between press and release can never compare
    /// equal and authorize a macro against a state the user did not see.
    /// `statusChangedAt` is stable across same-state lifecycle chatter
    /// (only `lastLifecycleEventAt` advances there), so the epoch does not
    /// cause false refusals mid-turn.
    var fireGuardKey: String {
        let pane: String = agentID.paneID.map(String.init) ?? "raw"
        let pid: String = agentPID.map(String.init) ?? "-"
        let detected = detectedAt.timeIntervalSinceReferenceDate
        let changed = statusChangedAt.timeIntervalSinceReferenceDate
        let session = providerSessionID ?? "-"
        let signature = prompt?.signature ?? ""
        return "\(agentID.sessionID.uuidString)|\(pane)|\(detected)|\(session)|\(pid)|\(status.rawValue)|\(changed)|\(signature)"
    }
}

/// SwipePad's window onto the Agent Center engine. One instance per live
/// session view; the pad observes only `snapshot`, never `agents`, so agent
/// churn in other sessions cannot invalidate a puck. A nil snapshot means no
/// hook-proven agent owns the focused pane and the pad stays in its legacy
/// resolver mode.
@MainActor @Observable
final class SwipePadAgentContext {
    private(set) var snapshot: SwipePadAgentSnapshot?

    /// Equality-gated single mutation point: identical recomputes never
    /// invalidate observers, which is what keeps AgentCenter's per-change
    /// republish loop cheap enough to run unconditionally.
    func publish(_ new: SwipePadAgentSnapshot?) {
        guard snapshot != new else { return }
        snapshot = new
    }
}
