import Foundation
import SwiftData

/// Which transport to use when opening a connection for a host.
public enum HostTransport: String, CaseIterable, Codable, Sendable {
    case ssh
    case mosh

    var label: String { rawValue }

    var editorDescription: String {
        switch self {
        case .ssh:
            return "single SSH connection; tmux tabs stay on the main session."
        case .mosh:
            return "mosh terminal over UDP; tmux tabs use a second SSH side channel."
        }
    }
}

/// Post-connect launch behavior for a host. Three mutually-exclusive
/// modes, chosen by the user in the host editor:
///
///   - `.autoTmux` — attach to (or create) a per-host tmux session
///     with the SHA-derived `tessera-XXXXXXXX` name.
///   - `.pinnedTmux` — attach to (or create) a tmux session using
///     the user-specified `tmuxSessionName` (e.g. `dev`, `prod`).
///   - `.customCommand` — send `launchCommand` verbatim to stdin on
///     connect; auto-tmux is bypassed entirely.
public enum HostLaunchMode: String, CaseIterable, Codable, Sendable {
    case autoTmux
    case pinnedTmux
    case customCommand
}

@Model
final class PersistedHost {
    @Attribute(.unique) var id: UUID
    var name: String
    var address: String
    var port: Int
    /// Legacy "is this any form of auto-tmux" flag. Kept in sync with
    /// `launchMode` (true for `.autoTmux`/`.pinnedTmux`, false for
    /// `.customCommand`) so existing singleton-session and display
    /// logic keeps working without a sweeping rename.
    var autoTmux: Bool
    /// Raw storage for `transport`. Use the `transport` accessor
    /// rather than touching this directly.
    ///
    /// Literal default (`"ssh"`) is load-bearing — SwiftData's
    /// lightweight migration requires a property-level default for
    /// new mandatory attributes, and Swift-level `init` defaults do
    /// NOT count. Without this, existing stores fail to migrate with
    /// `NSCocoaErrorDomain 134110 "missing attribute values on
    /// mandatory destination attribute"` and the app launches with an
    /// empty container.
    var transportRaw: String = "ssh"
    /// Raw storage for `launchMode`. Use the `launchMode` accessor
    /// rather than touching this directly.
    ///
    /// Literal default (`"autoTmux"`) is load-bearing — SwiftData's
    /// lightweight migration requires a property-level default for
    /// new mandatory attributes, and Swift-level `init` defaults do
    /// NOT count. Without this, existing stores fail to migrate with
    /// `NSCocoaErrorDomain 134110 "missing attribute values on
    /// mandatory destination attribute"` and the app launches with an
    /// empty container.
    var launchModeRaw: String = "autoTmux"
    /// User-specified tmux session name for `.pinnedTmux` mode.
    /// Ignored in other modes.
    var tmuxSessionName: String?
    /// User-specified post-connect shell command for `.customCommand`
    /// mode. Ignored in other modes.
    var launchCommand: String?
    /// Host tag list. Powers M2 hosts-landing tag pills and host-editor
    /// advanced tab. Literal property-level default is load-bearing for
    /// SwiftData lightweight migration — see transportRaw above for the
    /// rationale.
    var tags: [String] = []
    /// Short OS hint for the M2 hosts-landing OSBadge. Common values:
    /// "macos", "ubuntu", "debian", "alpine", "linux", "raspbian".
    /// Falls through to a generic badge for unknown values.
    var osHint: String = "linux"
    /// Free-form user notes shown in the M2 host-editor advanced tab.
    var notes: String = ""
    /// Newline-delimited `KEY=VALUE` pairs prepended to the launch command
    /// at connect time as `export KEY='VALUE'` lines. Lines failing the
    /// `[A-Za-z_][A-Za-z0-9_]*` key regex are skipped silently.
    var envVars: String = ""
    var startupSnippet: String = ""
    /// Codable-encoded `[PortForwardRule]` from the `PortForwarding` package.
    /// Stored as a single `Data?` blob (not as a `[PortForwardRule]` array) to
    /// sidestep the SwiftData iOS 26 array-migration bug — adding any new
    /// column to a @Model with an array-of-Codable property crashes lightweight
    /// migration. Literal default is load-bearing for SwiftData migration —
    /// see `transportRaw` above for the rationale.
    var portForwardRulesData: Data? = nil
    /// Per-host SSH login user. Stored on the host (not on
    /// `Identity`) so two hosts using the same key can have
    /// different users. Literal default is load-bearing for
    /// SwiftData lightweight migration — see `transportRaw` above
    /// for the rationale.
    var user: String = ""
    var sortOrder: Int

    @Relationship(inverse: \Identity.hosts)
    var identity: Identity?

    /// Typed accessor for `transportRaw`. Corrupt or unknown values
    /// fall back to `.ssh` (safe default and migration default).
    var transport: HostTransport {
        get { HostTransport(rawValue: transportRaw) ?? .ssh }
        set { transportRaw = newValue.rawValue }
    }

    /// Resolved login user. Reads the per-host `user` field; falls
    /// back to whatever was set on the linked Identity for any host
    /// migrated from the legacy user-on-Identity model.
    var effectiveUser: String {
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return identity?.user ?? ""
    }

    /// Transport-scoped key used for active-session reuse and
    /// duplicate labeling. SSH and mosh sessions to the same endpoint
    /// must stay distinct now that transport is user-selectable, and a
    /// jump-chained host must stay distinct from a direct host at the
    /// same endpoint (behind a bastion the address names a different
    /// machine). The complete resolved hop-ID path disambiguates nested
    /// routes and changes whenever any transitive jump link is edited.
    var connectionKey: String {
        let base = "\(transport.rawValue):\(effectiveUser)@\(address):\(port)"
        guard let context = modelContext else {
            return base
        }
        let resolution = HostJumpChainResolver.resolve(for: self, in: context)
        if resolution.isBroken {
            // A broken route must never reuse a still-live session created
            // through its formerly valid topology. Include the immediate
            // dangling/cyclic link when readable to keep the key deterministic.
            let linkID = HostJumpChainResolver.link(for: id, in: context)?
                .jumpHostID.uuidString ?? "unknown"
            return "\(base)&via=broken:\(linkID)"
        }
        guard !resolution.hops.isEmpty else { return base }
        let path = resolution.hops.map { $0.id.uuidString }.joined(separator: ",")
        return "\(base)&via=\(path)"
    }

    /// Typed accessor for `launchModeRaw`. Corrupt or unknown values
    /// fall back to `.autoTmux` (safe default — all hosts start there).
    var launchMode: HostLaunchMode {
        get { HostLaunchMode(rawValue: launchModeRaw) ?? .autoTmux }
        set {
            launchModeRaw = newValue.rawValue
            autoTmux = (newValue != .customCommand)
        }
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        address: String = "",
        port: Int = 22,
        autoTmux: Bool = true,
        transport: HostTransport = .ssh,
        launchMode: HostLaunchMode = .autoTmux,
        tmuxSessionName: String? = nil,
        launchCommand: String? = nil,
        sortOrder: Int = 0,
        identity: Identity? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.autoTmux = autoTmux
        self.transportRaw = transport.rawValue
        self.launchModeRaw = launchMode.rawValue
        self.tmuxSessionName = tmuxSessionName
        self.launchCommand = launchCommand
        self.sortOrder = sortOrder
        self.identity = identity
    }
}
