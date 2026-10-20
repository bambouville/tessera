import Foundation

/// What the user asked should happen to their sessions on the next launch.
///
/// Both platforms had their own copy of this enum and of the compact-width
/// coercion below, spelled identically. One copy is the point.
public enum ForegroundRestorePolicy: String, Equatable, Sendable, CaseIterable, Codable {
    case ask
    case always
    case never
}

public enum ForegroundRestorePresentation {
    /// Compact navigation has no multi-session chooser, so `ask` behaves as
    /// `always` while the phone shell is presented — without disturbing the
    /// stored preference, which is a cross-device setting the tablet still honours.
    public static func effectivePolicy(
        stored: ForegroundRestorePolicy,
        usesCompactShell: Bool
    ) -> ForegroundRestorePolicy {
        usesCompactShell && stored == .ask ? .always : stored
    }
}

/// One stored snapshot, reduced to what the cold-start decision needs.
public struct ForegroundRestoreStartupCandidate: Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let hostID: UUID

    public init(sessionID: UUID, hostID: UUID) {
        self.sessionID = sessionID
        self.hostID = hostID
    }
}

/// The sessions a launch should bring back, in the stored document's order.
public struct ForegroundRestoreStartupPlan: Equatable, Sendable {
    public let sessionIDs: [UUID]
    public let selectedSessionID: UUID?
    /// Entries this device cannot restore. Surfaced, not silently dropped: the
    /// prompt tells the user how many were left behind.
    public let skippedCount: Int

    public init(sessionIDs: [UUID], selectedSessionID: UUID?, skippedCount: Int) {
        self.sessionIDs = sessionIDs
        self.selectedSessionID = selectedSessionID
        self.skippedCount = skippedCount
    }
}

public enum ForegroundRestoreStartupAction: Equatable, Sendable {
    /// Not yet. Ask again when the facts change; do NOT spend the one
    /// cold-start pass on this.
    case wait(Reason)
    /// Nothing to do, and the pass is spent.
    case skip(Reason)
    /// Reopen these now.
    case restore(ForegroundRestoreStartupPlan)
    /// Offer these and wait for an answer.
    case offer(ForegroundRestoreStartupPlan)

    public enum Reason: String, Equatable, Sendable, CaseIterable, Codable {
        /// The host list has not arrived. Acting now reads every snapshot as
        /// naming a host this device no longer has.
        case hostsNotLoaded
        /// The host list arrived empty while the document names hosts. On
        /// Android that is what a Room emission predating a recent write looks
        /// like, so it is a `wait`, not a verdict — bounded by the caller.
        case hostListEmpty
        case policyNever
        case noDocument
        case nothingRestorable
    }
}

public enum ForegroundRestoreStartup {
    /// What a cold start should do, given everything it can see.
    ///
    /// The guard order is the whole content of this function, and it is where
    /// the 2026-09-11 Android defect lived: `hostsLoaded` and an empty host
    /// list were treated as the same fact as "these hosts are gone", so a
    /// launch that raced Room's first emission spent its one pass, cleared the
    /// document, and restored nothing — silently. The wake window had refused
    /// to tick before the host list loaded since it was written; the cold-start
    /// path, which is a second implementation of the same idea, never did.
    ///
    /// `liveHostIDs` are hosts already on screen. They are excluded rather than
    /// aborting the whole plan: giving up whenever any tab existed meant any
    /// launch that opened a host first — a share target, a direct-share
    /// shortcut, an agent notification — took restore with it.
    public static func action(
        candidates: [ForegroundRestoreStartupCandidate],
        hasDocument: Bool,
        hostsLoaded: Bool,
        availableHostIDs: Set<UUID>,
        liveHostIDs: Set<UUID>,
        selectedSessionID: UUID?,
        policy: ForegroundRestorePolicy
    ) -> ForegroundRestoreStartupAction {
        guard hostsLoaded else { return .wait(.hostsNotLoaded) }
        guard hasDocument, !candidates.isEmpty else { return .skip(.noDocument) }
        // Checked before the policy: turning restore off should not be the
        // thing that decides a question the caller cannot yet answer.
        if availableHostIDs.isEmpty { return .wait(.hostListEmpty) }
        guard policy != .never else { return .skip(.policyNever) }

        let restorable = candidates.filter {
            availableHostIDs.contains($0.hostID) && !liveHostIDs.contains($0.hostID)
        }
        guard !restorable.isEmpty else { return .skip(.nothingRestorable) }

        let sessionIDs = restorable.map(\.sessionID)
        let plan = ForegroundRestoreStartupPlan(
            sessionIDs: sessionIDs,
            selectedSessionID: selectedSessionID.flatMap { sessionIDs.contains($0) ? $0 : nil },
            skippedCount: candidates.count - restorable.count
        )
        return policy == .ask ? .offer(plan) : .restore(plan)
    }
}
