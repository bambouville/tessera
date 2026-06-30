import Foundation
import TmuxControl

/// Per-host runtime data we want to remember across connects, separate
/// from the user-edited `Host` config.
///
/// Today this is just the tmux session name we last attached to or
/// created. The struct exists as its own type so we can grow it
/// (last-known geometry, last connection timestamp, MOTD hash, …)
/// without churning the persistence key shape later.
struct HostRuntimeState: Codable, Equatable {
    /// The name passed to `tmux -CC attach -t <name>` /
    /// `tmux -CC new -s <name>` on the most recent successful
    /// auto-attach. Set the first time we observe `tmux.mode` flip
    /// to `.tmuxControl` for this host so subsequent connects can
    /// resume the same server-side session.
    var tmuxSessionName: String?
}

/// Tiny UserDefaults wrapper for `HostRuntimeState`. Keyed by
/// `user@address:port` rather than `Host.id` because the in-memory
/// `Host.id` is a fresh UUID each launch (we don't persist hosts
/// yet — see §6 of the requirements doc).
///
/// Password and private-key filename are deliberately NOT in the key:
/// rotating credentials shouldn't lose the saved tmux session.
enum HostRuntimeStateStore {
    private static let defaults = UserDefaults.standard
    private static let keyPrefix = "tessera.host.runtime."

    /// Stable identity for a host record. Anything that uniquely
    /// identifies "the same place I was logging into last time"
    /// goes here.
    static func key(for host: Host) -> String {
        "\(host.user)@\(host.address):\(host.port)"
    }

    static func load(for host: Host) -> HostRuntimeState {
        let dictKey = keyPrefix + key(for: host)
        guard let data = defaults.data(forKey: dictKey),
              let state = try? JSONDecoder().decode(HostRuntimeState.self, from: data)
        else { return HostRuntimeState() }
        return state
    }

    static func save(_ state: HostRuntimeState, for host: Host) {
        let dictKey = keyPrefix + key(for: host)
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: dictKey)
        }
    }

    /// Resolve the tmux session name to use for this host on the
    /// next auto-attach.
    ///
    /// Lookup order:
    ///   1. Persisted `tmuxSessionName` from a previous connect.
    ///   2. Deterministic SHA-256 derivation from the host key.
    ///
    /// The deterministic fallback is what makes "wipe app data,
    /// reconnect to the same host" idempotent — the freshly-installed
    /// app computes the same name and resumes the existing
    /// server-side session instead of stranding it.
    static func sessionName(for host: Host) -> String {
        if let saved = load(for: host).tmuxSessionName, !saved.isEmpty {
            return saved
        }
        return AutoTmuxScript.defaultSessionName(forHostKey: key(for: host))
    }

    /// Persist the resolved session name as soon as we observe a
    /// successful tmux mode entry. Idempotent: writes only if the
    /// stored value differs from the candidate, so the common case
    /// (resume) is a single load + comparison + early return.
    static func recordSessionUsed(_ name: String, for host: Host) {
        var state = load(for: host)
        if state.tmuxSessionName != name {
            state.tmuxSessionName = name
            save(state, for: host)
        }
    }
}
