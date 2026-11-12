import Foundation
import Observation
import SwiftUI
import TesseraCore

/// A detail's reading intent, without viewport geometry or UIKit objects.
struct AgentThreadPresentationState: Equatable {
    var followingLatest = true
    var visibleRowID: String?
    /// How far into `visibleRowID` the reader sits, as a fraction of its
    /// height: a long reply reflows across containers, its fraction holds.
    var visibleRowFraction: CGFloat?
    var renderedLowerID: String?
    var renderedUpperID: String?
    var expandedToolEntries: Set<String> = []
    /// Open tool, edit, thinking and summary disclosures, by
    /// `AgentBlockDisclosures.key`.
    var expandedBlocks: Set<String> = []
    var toolRunAnchors: [String: String] = [:]
    var positionedThread: AgentThreadID?
    var windowAtLiveHead: Bool?
    var requestedCursor: String?
    var requestedNewerCursor: String?
    var requestedBridgeCursor: String?
    var historyDemand = ""
    var historyDemandGeneration = 0
    var automaticPages = 0
    var fillPages = 0
    var nextPageAttempt = Date.distantPast
    var pageRetryDelay: TimeInterval = 1
    var bridgeRetryDelay: TimeInterval = 1
}

/// The section owns snapshots; scrolling mutates only the detail's local State.
/// A replacement can appear before the outgoing detail disappears. Sample that
/// detail once at handoff, and fence its later disappearance with the owner ID.
@MainActor @Observable
final class AgentThreadPresentationStore {
    @ObservationIgnored private var states: [AgentThreadID: AgentThreadPresentationState] = [:]
    @ObservationIgnored private var readers: [AgentThreadID: (owner: UUID, snapshot: () -> AgentThreadPresentationState)] = [:]
    @ObservationIgnored private var composerFocus: [AgentThreadID: Bool] = [:]
    @ObservationIgnored private var composers: [AgentThreadID: (owner: UUID, snapshot: () -> Bool)] = [:]
    @ObservationIgnored private var retainedThreadIDs: Set<AgentThreadID>?
    private let isRetained: ((AgentThreadID) -> Bool)?

    init(isRetained: ((AgentThreadID) -> Bool)? = nil) { self.isRetained = isRetained }

    func mountReader(for threadID: AgentThreadID, owner: UUID,
                     snapshot: @escaping () -> AgentThreadPresentationState) -> AgentThreadPresentationState? {
        guard retains(threadID) else { return nil }
        if let previous = readers[threadID] { states[threadID] = previous.snapshot() }
        readers[threadID] = (owner, snapshot)
        return states[threadID]
    }

    func unmountReader(for threadID: AgentThreadID, owner: UUID) {
        guard retains(threadID), let current = readers[threadID], current.owner == owner else { return }
        states[threadID] = current.snapshot()
        readers[threadID] = nil
    }

    func mountComposer(for threadID: AgentThreadID, owner: UUID, snapshot: @escaping () -> Bool) -> Bool {
        guard retains(threadID) else { return false }
        if let previous = composers[threadID] { composerFocus[threadID] = previous.snapshot() }
        composers[threadID] = (owner, snapshot)
        return composerFocus[threadID] == true
    }

    @discardableResult
    func unmountComposer(for threadID: AgentThreadID, owner: UUID) -> Bool {
        // Pruning removed the snapshot provider, but UIKit still needs to
        // clean up its model mount. Only a replacement owner forbids that.
        guard let current = composers[threadID] else { return true }
        guard isCurrentComposer(for: threadID, owner: owner) else { return false }
        composerFocus[threadID] = current.snapshot()
        composers[threadID] = nil
        return true
    }

    func isCurrentComposer(for threadID: AgentThreadID, owner: UUID) -> Bool {
        retains(threadID) && composers[threadID]?.owner == owner
    }

    func prune(retaining threadIDs: Set<AgentThreadID>) {
        retainedThreadIDs = threadIDs
        states = states.filter { threadIDs.contains($0.key) }
        readers = readers.filter { threadIDs.contains($0.key) }
        composerFocus = composerFocus.filter { threadIDs.contains($0.key) }
        composers = composers.filter { threadIDs.contains($0.key) }
    }

    private func retains(_ threadID: AgentThreadID) -> Bool {
        // A child can appear before the root's onChange prunes a newly
        // published thread set. Admission reads the model's current identity;
        // pruning still releases snapshots and fences outgoing owners.
        isRetained?(threadID) ?? (retainedThreadIDs?.contains(threadID) != false)
    }
}

/// Which single-block disclosures a detail has open, keyed by record and
/// block index. One stable object per detail, so the environment carrying it
/// never changes; its set moves through the presentation snapshot.
@MainActor @Observable
final class AgentBlockDisclosures {
    var expanded: Set<String> = []

    static func key(recordID: String, blockIndex: Int) -> String { "\(recordID)#\(blockIndex)" }

    func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(key) },
                set: { open in if open { self.expanded.insert(key) } else { self.expanded.remove(key) } })
    }
}

extension EnvironmentValues {
    @Entry var agentBlockDisclosures: AgentBlockDisclosures? = nil
    @Entry var agentPromptAnswerDrafts: AgentPromptAnswerDrafts? = nil
}

/// Answers typed into a transcript's prompt card, by thread and prompt. The
/// root holds one, so a detail rebuilt for another layout (laptop pose and
/// the narrow stack are separate trees) shows what was typed.
@MainActor @Observable
final class AgentPromptAnswerDrafts {
    struct Key: Hashable {
        let thread: AgentThreadID
        let token: String
    }

    struct Draft: Equatable {
        var isOpen = false
        var text = ""
    }

    private var drafts: [Key: Draft] = [:]

    subscript(key: Key) -> Draft {
        get { drafts[key] ?? Draft() }
        set { drafts[key] = newValue == Draft() ? nil : newValue }
    }

    func prune(retaining threads: Set<AgentThreadID>) {
        let kept = drafts.filter { threads.contains($0.key.thread) }
        if kept.count != drafts.count { drafts = kept }
    }
}
