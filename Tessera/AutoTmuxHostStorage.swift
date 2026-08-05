import Foundation
import TmuxControl

/// Per-host runtime data we want to remember across connects, separate
/// from the user-edited `Host` config.
///
/// The struct exists as its own type so runtime discoveries can survive
/// session teardown without being folded into the user-edited host config.
struct HostRuntimeState: Codable, Equatable {
    /// The name passed to `tmux -CC attach -t <name>` /
    /// `tmux -CC new -s <name>` on the most recent successful
    /// auto-attach. Set the first time we observe `tmux.mode` flip
    /// to `.tmuxControl` for this host so subsequent connects can
    /// resume the same server-side session.
    var tmuxSessionName: String?

    /// `true` after the auto-tmux sentinel proves that tmux is unavailable.
    /// A later successful control-mode entry resets this to `false`.
    var tmuxUnavailable: Bool?

    /// Last high-confidence WSL2/Tailscale MTU risk observed over this exact
    /// endpoint. Cached locally so an auto-restored session can explain a
    /// likely stall even when the next SSH handshake never gets far enough to
    /// run the host probe. A later conclusive safe probe clears it.
    var wslTailscaleMTUWarning: WSLTailscaleMTUWarning?
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
        load(for: host, defaults: defaults)
    }

    static func load(for host: Host, defaults storage: UserDefaults) -> HostRuntimeState {
        let dictKey = keyPrefix + key(for: host)
        guard let data = storage.data(forKey: dictKey),
              let state = try? JSONDecoder().decode(HostRuntimeState.self, from: data)
        else { return HostRuntimeState() }
        return state
    }

    static func save(_ state: HostRuntimeState, for host: Host) {
        save(state, for: host, defaults: defaults)
    }

    static func save(
        _ state: HostRuntimeState,
        for host: Host,
        defaults storage: UserDefaults
    ) {
        let dictKey = keyPrefix + key(for: host)
        if let data = try? JSONEncoder().encode(state) {
            storage.set(data, forKey: dictKey)
        }
    }

    static func isTmuxKnownUnavailable(for host: Host) -> Bool {
        isTmuxKnownUnavailable(for: host, defaults: defaults)
    }

    static func isTmuxKnownUnavailable(
        for host: Host,
        defaults storage: UserDefaults
    ) -> Bool {
        load(for: host, defaults: storage).tmuxUnavailable == true
    }

    static func recordTmuxUnavailable(for host: Host) {
        recordTmuxUnavailable(for: host, defaults: defaults)
    }

    static func recordTmuxUnavailable(
        for host: Host,
        defaults storage: UserDefaults
    ) {
        var state = load(for: host, defaults: storage)
        guard state.tmuxUnavailable != true else { return }
        state.tmuxUnavailable = true
        save(state, for: host, defaults: storage)
    }

    static func recordTmuxAvailable(for host: Host) {
        recordTmuxAvailable(for: host, defaults: defaults)
    }

    static func recordTmuxAvailable(
        for host: Host,
        defaults storage: UserDefaults
    ) {
        var state = load(for: host, defaults: storage)
        guard state.tmuxUnavailable != false else { return }
        state.tmuxUnavailable = false
        save(state, for: host, defaults: storage)
    }

    static func wslTailscaleMTUWarning(for host: Host) -> WSLTailscaleMTUWarning? {
        wslTailscaleMTUWarning(for: host, defaults: defaults)
    }

    static func wslTailscaleMTUWarning(
        for host: Host,
        defaults storage: UserDefaults
    ) -> WSLTailscaleMTUWarning? {
        load(for: host, defaults: storage).wslTailscaleMTUWarning
    }

    /// Persist only conclusive results. An unavailable probe leaves prior
    /// evidence intact so a packet-size failure during the next handshake
    /// cannot erase the warning that would explain it.
    static func recordNetworkPathAssessment(
        _ assessment: NetworkPathAssessment,
        for host: Host
    ) {
        recordNetworkPathAssessment(assessment, for: host, defaults: defaults)
    }

    static func recordNetworkPathAssessment(
        _ assessment: NetworkPathAssessment,
        for host: Host,
        defaults storage: UserDefaults
    ) {
        guard assessment != .unavailable else { return }
        var state = load(for: host, defaults: storage)
        let warning: WSLTailscaleMTUWarning?
        switch assessment {
        case .unavailable:
            return
        case .notAtRisk:
            warning = nil
        case .warning(let value):
            warning = value
        }
        guard state.wslTailscaleMTUWarning != warning else { return }
        state.wslTailscaleMTUWarning = warning
        save(state, for: host, defaults: storage)
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
        if state.tmuxSessionName != name || state.tmuxUnavailable != false {
            state.tmuxSessionName = name
            state.tmuxUnavailable = false
            save(state, for: host)
        }
    }
}
