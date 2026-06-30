// Tessera/SwipePad/SwipePadProfile.swift
// Profile model for the swipe pad feature (experimental).
//
// A profile binds 4 cardinal directions (left / right / up / down) to byte
// sequences that are sent to the terminal when the user releases the radial
// gesture on that direction. Profiles are app-scoped — the active one is
// chosen by matching `matchProcess` against the detected foreground process
// name (tmux `#{pane_current_command}` when available, plain-SSH `ps`
// snapshots otherwise).
//
// `bindings[.down]` is conventionally absent (or `macro == ""`) for the
// built-in defaults — the down petal stays hidden until the user adds one.
import Foundation

public enum SwipeDirection: String, Codable, CaseIterable, Hashable {
    case left, right, up, down
}

/// A single direction's macro. An empty `macro` is treated as "unbound" — the
/// corresponding petal is hidden in the radial.
public struct SwipePadBinding: Codable, Equatable, Hashable {
    public var macro: String

    public init(macro: String) {
        self.macro = macro
    }

    public var isBound: Bool { !macro.isEmpty }
}

public struct SwipePadProfile: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    /// Foreground process-name matcher. Two forms:
    ///   - **Literal** (default): exact match, case-insensitive.
    ///     Example: `"codex"` matches a pane running `codex`.
    ///   - **Regex**: prefix the pattern with `"regex:"`. The rest is
    ///     compiled as a case-insensitive `NSRegularExpression` and
    ///     matched against the process name.
    ///     Example: `"regex:^\\d+\\.\\d+\\.\\d+$"` catches Claude Code,
    ///     which sets `process.title` to its semver at runtime — the
    ///     literal command name changes every release.
    /// `""` means "matches anything" — used only by the catch-all
    /// fallback profile, which the resolver always ranks last.
    public var matchProcess: String
    public var bindings: [SwipeDirection: SwipePadBinding]
    public var isBuiltIn: Bool

    public init(
        id: UUID,
        name: String,
        matchProcess: String,
        bindings: [SwipeDirection: SwipePadBinding],
        isBuiltIn: Bool
    ) {
        self.id = id
        self.name = name
        self.matchProcess = matchProcess
        self.bindings = bindings
        self.isBuiltIn = isBuiltIn
    }

    public func binding(for direction: SwipeDirection) -> SwipePadBinding {
        bindings[direction] ?? SwipePadBinding(macro: "")
    }

    public var visibleDirections: [SwipeDirection] {
        SwipeDirection.allCases.filter { binding(for: $0).isBound }
    }
}

// MARK: - Built-in defaults

public extension SwipePadProfile {
    /// Stable IDs so user edits survive across launches.
    static let builtInClaudeCodeID = UUID(uuidString: "B17710C0-0000-0000-0000-000000000001")!
    static let builtInCodexCLIID   = UUID(uuidString: "B17710C0-0000-0000-0000-000000000002")!
    static let fallbackID          = UUID(uuidString: "B17710C0-0000-0000-0000-0000000000FA")!

    /// Built-in IDs that used to ship but were removed in later releases.
    /// `SwipePadProfileStore.merge` filters these out of the stored JSON so
    /// they don't reappear as ghost user profiles after a code update.
    static let retiredBuiltInIDs: Set<UUID> = [
        UUID(uuidString: "B17710C0-0000-0000-0000-000000000003")!,  // aider, retired 2026-05-16
    ]

    /// → 1↵ (approve), ← 2↵ (deny), ↑ 3↵ (always allow this session).
    /// Match expression catches both the semver-style `process.title` Claude
    /// Code sets at runtime (e.g. `2.1.143`) and npm wrapper argv names
    /// (`claude`, `claude-code`) that show up in plain-SSH `ps` snapshots.
    static var builtInClaudeCode: SwipePadProfile {
        SwipePadProfile(
            id: builtInClaudeCodeID,
            name: "claude code",
            matchProcess: "regex:^(\\d+\\.\\d+\\.\\d+|claude(?:-code)?)$",
            bindings: [
                .right: SwipePadBinding(macro: "1↵"),
                .left:  SwipePadBinding(macro: "2↵"),
                .up:    SwipePadBinding(macro: "3↵"),
            ],
            isBuiltIn: true
        )
    }

    /// → y (approve), ← esc (deny), ↑ p (always allow per-command pattern).
    /// Codex uses single-key shortcuts without a trailing Enter.
    /// Match expression is a prefix regex — Codex ships as a Rust binary
    /// whose pane_current_command on macOS shows up as `codex-aarch64-a`
    /// (truncated to 16 chars by the kernel) or `codex-x86_64-a`; the
    /// prefix `^codex` covers all platform-suffixed variants and the bare
    /// `codex` symlink if a user invokes it that way.
    static var builtInCodexCLI: SwipePadProfile {
        SwipePadProfile(
            id: builtInCodexCLIID,
            name: "codex cli",
            matchProcess: "regex:^codex",
            bindings: [
                .right: SwipePadBinding(macro: "y"),
                .left:  SwipePadBinding(macro: "esc"),
                .up:    SwipePadBinding(macro: "p"),
            ],
            isBuiltIn: true
        )
    }

    /// Always-on catch-all profile — used whenever no agent profile above
    /// matches the detected process. Bindings are empty by default
    /// (the radial shows no petals); dictation via double-tap still works.
    /// Users can bind any direction to a custom macro for their shell.
    static var fallback: SwipePadProfile {
        SwipePadProfile(
            id: fallbackID,
            name: "fallback",
            matchProcess: "",
            bindings: [:],
            isBuiltIn: true
        )
    }

    static var allBuiltIns: [SwipePadProfile] {
        [builtInClaudeCode, builtInCodexCLI, fallback]
    }
}
