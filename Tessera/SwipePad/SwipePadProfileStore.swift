// Tessera/SwipePad/SwipePadProfileStore.swift
// Persisted store of swipe-pad profiles. Built-in defaults are always present;
// user edits are stored as a delta in UserDefaults (JSON) and merged on load.
//
// Storage shape: a single `tessera.swipePad.profiles` key holding the full
// `[SwipePadProfile]` as JSON. On load, we replace built-ins by ID where the
// stored array supplies them, and append any non-built-in (user-created)
// profiles in their stored order. `fallback` is always present and always
// last. Retired built-ins (see SwipePadProfile.retiredBuiltInIDs) are filtered
// out so deprecating a default doesn't leave a ghost user profile behind.
import SwiftUI
import Observation

@MainActor
@Observable
public final class SwipePadProfileStore {
    public private(set) var profiles: [SwipePadProfile]

    private static let defaultsKey = "tessera.swipePad.profiles"

    public init() {
        self.profiles = Self.load()
    }

    /// Replace an existing profile (matched by `id`) or append if new.
    /// `fallback` is always kept last after any mutation.
    public func upsert(_ profile: SwipePadProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        normalize()
        persist()
    }

    /// Remove a profile by ID. Built-ins (including `fallback`) cannot
    /// be removed — calls for those are silent no-ops. To revert a built-in
    /// to its factory bindings, use `resetBuiltInToDefault`.
    public func remove(profileWithID id: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        if profiles[idx].isBuiltIn { return }
        profiles.remove(at: idx)
        persist()
    }

    /// Restore one of the built-in profiles to its factory bindings.
    /// Useful after the user has overridden a default and wants to start over.
    public func resetBuiltInToDefault(id: UUID) {
        guard let factory = SwipePadProfile.allBuiltIns.first(where: { $0.id == id }) else { return }
        upsert(factory)
    }

    // MARK: - persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            DiagnosticLogStore.appendSwipePad("profile-store persist failed error='\(error)'")
        }
    }

    private static func load() -> [SwipePadProfile] {
        let defaults = SwipePadProfile.allBuiltIns
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return defaults
        }
        do {
            let stored = try JSONDecoder().decode([SwipePadProfile].self, from: data)
            return merge(defaults: defaults, stored: stored)
        } catch {
            DiagnosticLogStore.appendSwipePad("profile-store load failed error='\(error)'")
            return defaults
        }
    }

    /// Merge stored profiles on top of the code-defined defaults.
    ///
    /// For **built-in** profiles (matched by stable ID): `name`,
    /// `matchProcess`, and `isBuiltIn` always come from the current code
    /// definition — that way improvements to the match expression flow to
    /// existing installs on the next launch. Only `bindings` are picked up
    /// from storage, so user edits to which keys a direction fires survive.
    ///
    /// For **user-created** profiles (IDs not in the defaults): everything
    /// comes from storage, in stored order.
    ///
    /// Retired built-in IDs (`SwipePadProfile.retiredBuiltInIDs`, e.g. the
    /// old aider profile) are dropped so removing a default doesn't leave
    /// a ghost user profile behind. `fallback` is always present and last.
    private static func merge(defaults: [SwipePadProfile], stored: [SwipePadProfile]) -> [SwipePadProfile] {
        let retired = SwipePadProfile.retiredBuiltInIDs
        let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        var out: [SwipePadProfile] = []
        var seen = Set<UUID>()
        for d in defaults where d.id != SwipePadProfile.fallbackID {
            if let user = storedByID[d.id] {
                // Take the default's name + matchProcess + isBuiltIn;
                // overlay the user's stored bindings on top.
                var merged = d
                merged.bindings = user.bindings
                out.append(merged)
            } else {
                out.append(d)
            }
            seen.insert(d.id)
        }
        for s in stored where !seen.contains(s.id)
            && s.id != SwipePadProfile.fallbackID
            && !retired.contains(s.id) {
            var copy = s
            copy.isBuiltIn = false
            out.append(copy)
        }
        // Fallback always last. Same code-vs-storage policy as other built-ins.
        if let storedFallback = storedByID[SwipePadProfile.fallbackID] {
            var merged = SwipePadProfile.fallback
            merged.bindings = storedFallback.bindings
            out.append(merged)
        } else {
            out.append(SwipePadProfile.fallback)
        }
        return out
    }

    /// Keep `fallback` last; built-ins keep their canonical isBuiltIn flag.
    private func normalize() {
        if let idx = profiles.firstIndex(where: { $0.id == SwipePadProfile.fallbackID }),
           idx != profiles.count - 1 {
            let fallback = profiles.remove(at: idx)
            profiles.append(fallback)
        }
    }
}
