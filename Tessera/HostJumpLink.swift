import Foundation
import SwiftData

/// Per-host jump (bastion) association: "connect to `hostID` by first
/// SSH-ing to `jumpHostID` and tunneling a direct-tcpip channel."
///
/// Deliberately a standalone join table keyed by UUID — NOT a new column
/// or `@Relationship` on `PersistedHost`. Either of those would alter
/// `PersistedHost`'s schema, and any schema change to a `@Model` holding a
/// `[String]` property (`tags`) crashes SwiftData's iOS 26 lightweight
/// migration (see the array trap in `TesseraMigration.swift`). Adding a
/// whole new entity leaves the existing tables untouched.
///
/// Multi-hop chains are expressed by recursion: if the bastion host has a
/// `HostJumpLink` of its own, the chain extends outward. Resolution caps
/// depth and detects cycles (`HostJumpChainResolver`).
@Model
final class HostJumpLink {
    @Attribute(.unique) var hostID: UUID
    var jumpHostID: UUID

    init(hostID: UUID, jumpHostID: UUID) {
        self.hostID = hostID
        self.jumpHostID = jumpHostID
    }
}

/// Walks `HostJumpLink` rows into an ordered bastion list for a host.
enum HostJumpChainResolver {
    /// Hard cap on chain length; ssh_config's own ProxyJump nesting rarely
    /// exceeds two or three hops in practice.
    static let maxDepth = 8

    struct Resolution {
        /// Bastion hosts, outermost first (the first entry is the hop the
        /// device dials directly). Empty when the host connects directly.
        var hops: [PersistedHost] = []
        /// True when a link exists but the chain could not be fully
        /// resolved — dangling jump-host UUID, a cycle, or depth overflow.
        /// Connection code must fail closed on this rather than silently
        /// connecting directly (the user configured bastioned routing).
        var isBroken = false
        /// Human-readable reason for `isBroken`, for error surfaces.
        var brokenReason: String?
    }

    static func link(for hostID: UUID, in context: ModelContext) -> HostJumpLink? {
        let descriptor = FetchDescriptor<HostJumpLink>(
            predicate: #Predicate { $0.hostID == hostID }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Throwing variant for resolution: a store-level fetch failure must
    /// surface as a BROKEN chain, never be conflated with "no link
    /// configured" — the latter silently connects direct (fail open).
    private static func fetchLink(
        for hostID: UUID,
        in context: ModelContext
    ) throws -> HostJumpLink? {
        let descriptor = FetchDescriptor<HostJumpLink>(
            predicate: #Predicate { $0.hostID == hostID }
        )
        return try context.fetch(descriptor).first
    }

    /// Resolve the full chain for `persisted`, outermost bastion first.
    static func resolve(
        for persisted: PersistedHost,
        in context: ModelContext
    ) -> Resolution {
        var resolution = Resolution()
        var visited: Set<UUID> = [persisted.id]
        // Innermost-first while walking; reversed at the end.
        var inner: [PersistedHost] = []
        var currentID = persisted.id

        while true {
            let link: HostJumpLink?
            do {
                link = try fetchLink(for: currentID, in: context)
            } catch {
                resolution.isBroken = true
                resolution.brokenReason = "Could not read the jump-host configuration."
                return resolution
            }
            guard let link else { break }
            if inner.count >= maxDepth {
                resolution.isBroken = true
                resolution.brokenReason = "Jump chain exceeds \(maxDepth) hops."
                return resolution
            }
            if visited.contains(link.jumpHostID) {
                resolution.isBroken = true
                resolution.brokenReason = "Jump chain contains a cycle."
                return resolution
            }
            let jumpID = link.jumpHostID
            let descriptor = FetchDescriptor<PersistedHost>(
                predicate: #Predicate { $0.id == jumpID }
            )
            let bastion: PersistedHost?
            do {
                bastion = try context.fetch(descriptor).first
            } catch {
                resolution.isBroken = true
                resolution.brokenReason = "Could not read the jump-host configuration."
                return resolution
            }
            guard let bastion else {
                resolution.isBroken = true
                resolution.brokenReason = "A configured jump host no longer exists."
                return resolution
            }
            visited.insert(bastion.id)
            inner.append(bastion)
            currentID = bastion.id
        }

        resolution.hops = inner.reversed()
        return resolution
    }

    /// Candidate bastions for the host editor: every other saved host that
    /// would not create a cycle if selected as `host`'s jump host. A host
    /// whose own (transitive) chain already passes through `host` is
    /// excluded.
    static func eligibleJumpHosts(
        for hostID: UUID?,
        in context: ModelContext
    ) -> [PersistedHost] {
        let all = (try? context.fetch(FetchDescriptor<PersistedHost>())) ?? []
        guard let hostID else { return all }
        return all.filter { candidate in
            guard candidate.id != hostID,
                  !candidate.address.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else { return false }
            let resolution = resolve(for: candidate, in: context)
            // Do not offer a candidate that is already dangling/cyclic, or
            // whose complete chain would become one hop too deep after the
            // edited host is appended as the destination.
            guard !resolution.isBroken,
                  resolution.hops.count < maxDepth else { return false }
            // Selecting a candidate whose transitive path already reaches the
            // edited host would close a cycle.
            return !resolution.hops.contains { $0.id == hostID }
        }
    }

    /// Create, update, or remove the link for `hostID`.
    static func setJumpHost(
        _ jumpHostID: UUID?,
        for hostID: UUID,
        in context: ModelContext
    ) {
        if let existing = link(for: hostID, in: context) {
            if let jumpHostID {
                existing.jumpHostID = jumpHostID
            } else {
                context.delete(existing)
            }
        } else if let jumpHostID {
            context.insert(HostJumpLink(hostID: hostID, jumpHostID: jumpHostID))
        }
    }

    /// Garbage-collect the deleted host's own outgoing link. Links from
    /// OTHER hosts that pointed *at* the deleted host are deliberately kept:
    /// resolution then reports a broken chain and the connection fails
    /// closed with "a configured jump host no longer exists" — never a
    /// silent fall-through to a direct connection the user routed around.
    static func removeOutgoingLink(
        for hostID: UUID,
        in context: ModelContext
    ) {
        if let existing = link(for: hostID, in: context) {
            context.delete(existing)
        }
    }
}
