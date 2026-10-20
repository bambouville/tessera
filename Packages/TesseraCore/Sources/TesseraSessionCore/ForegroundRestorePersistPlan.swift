import Foundation

/// Where a written entry's content comes from.
///
/// The core decides the order and which copy wins; the platform owns the
/// snapshot records themselves, because they carry display names, launch modes
/// and tmux targets that mean nothing here.
public enum ForegroundRestorePersistSource: String, Equatable, Sendable, CaseIterable, Codable {
    case current
    case cohort
    case stored
}

public struct ForegroundRestorePersistEntry: Equatable, Sendable {
    public let sessionID: UUID
    public let source: ForegroundRestorePersistSource

    public init(sessionID: UUID, source: ForegroundRestorePersistSource) {
        self.sessionID = sessionID
        self.source = source
    }
}

/// What a write contains, given the mode `ForegroundRestoreCohort.persistMode`
/// chose.
///
/// Choosing the mode was already shared; what the mode *does* was not. iOS left
/// this algorithm inline in `ContentView`, pinned only by a comment and named
/// as a debt in the review that shipped it, and Android ported it separately.
/// Two implementations of one rule is the shape every restore regression in
/// this feature has taken.
public enum ForegroundRestorePersistPlan {
    public static func entries(
        mode: ForegroundRestoreCohort.PersistMode,
        currentSessionIDs: [UUID],
        cohortSessionIDs: [UUID],
        storedSessionIDs: [UUID],
        maxSnapshots: Int
    ) -> [ForegroundRestorePersistEntry] {
        let planned: [ForegroundRestorePersistEntry]
        switch mode {
        case .liveOnly:
            // Mirrors the tab list, and so deletes everything it cannot see.
            // Only safe when nothing is at risk.
            planned = currentSessionIDs.map { .init(sessionID: $0, source: .current) }
        case .keepCohort:
            // The window is open. An entry awaiting its verdict keeps its
            // snapshot even once its tab is gone, so a write landing mid-window
            // cannot delete what is about to be restored.
            let live = Set(currentSessionIDs)
            planned = currentSessionIDs.map { ForegroundRestorePersistEntry(sessionID: $0, source: .current) }
                + cohortSessionIDs.filter { !live.contains($0) }
                    .map { ForegroundRestorePersistEntry(sessionID: $0, source: .cohort) }
        case .mergeWithStored:
            // Current wins per session; stored order leads, so the arrangement
            // the user had before the wake survives a merge.
            var order: [UUID] = []
            var seen: Set<UUID> = []
            for id in storedSessionIDs where seen.insert(id).inserted { order.append(id) }
            for id in currentSessionIDs where seen.insert(id).inserted { order.append(id) }
            let live = Set(currentSessionIDs)
            planned = order.map {
                .init(sessionID: $0, source: live.contains($0) ? .current : .stored)
            }
        }
        return maxSnapshots > 0 ? Array(planned.prefix(maxSnapshots)) : planned
    }

    /// The selection to write alongside `entries`.
    ///
    /// `preferred` is what is on screen now, and wins whenever it is actually
    /// in the document. It is absent in exactly the two cases that matter:
    /// mid-wake, when the session the user was last looking at is reconnecting
    /// and momentarily has no tab, and behind a lock screen, where nothing is
    /// presented at all. Writing nothing there is how a restore lands the user
    /// on the host list instead of the session they left.
    public static func selection(
        mode: ForegroundRestoreCohort.PersistMode,
        preferred: UUID?,
        writtenSessionIDs: [UUID],
        storedSelection: UUID?
    ) -> UUID? {
        let written = Set(writtenSessionIDs)
        if let preferred, written.contains(preferred) { return preferred }
        // A live-only write is the one state in which nothing is at risk, so
        // resurrecting a stored selection there would outlive its session.
        guard mode != .liveOnly else { return nil }
        return storedSelection.flatMap { written.contains($0) ? $0 : nil }
    }
}
