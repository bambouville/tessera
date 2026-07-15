import Foundation

/// Where a spotlight step's callout sits relative to its target. Mirrors the
/// `place` field in the approved mockup's `render()`.
enum OnboardingPlacement: Equatable {
    case below
    case right
}

/// The three self-contained illustration cards. None reference a real on-screen
/// element — they're freestanding diagrams drawn by `OnboardingOverlay`.
enum OnboardingIllustration: Equatable {
    /// A static mock tmux terminal: window tab strip + a few output lines. No
    /// live session exists on first launch, so this is an illustration only.
    case mockTerminal
    /// A simulated Claude Code permission prompt with the swipe-pad puck and its
    /// radial petals overlaid, so approve / deny / always map onto the prompt's
    /// 1. Yes / 2. Yes don't ask / 3. No options.
    case claudeCodePromptWithPuck
    /// A two-column keyboard-shortcut cheat grid.
    case shortcuts
    /// The Remote Files panel carved out beside a mock terminal: the panel
    /// breadcrumb follows the terminal's cwd (link glyph in accent), with a few
    /// file rows and an in-flight download.
    case filesPanel
    /// The native iOS share sheet, both directions: a remote file exported OUT to
    /// Files / Mail / Messages, and a photo shared IN so it lands on the host.
    case shareInOut
    /// The "paste a screenshot" gesture: a share/drop pill, upload, and the agent
    /// composer showing the `[Image #1]` token Claude Code / Codex render.
    case agentImagePaste
}

/// A spotlight step points at a real element; an illustration step draws a card.
enum OnboardingStepKind: Equatable {
    case spotlight(OnboardingTarget, OnboardingPlacement)
    case illustration(OnboardingIllustration)
}

/// One coach-mark in the passive walkthrough. Pure value type — the controller
/// holds the ordered list, the overlay renders one at a time.
struct OnboardingStep {
    let title: String
    let body: String
    let kind: OnboardingStepKind
}

extension OnboardingStep {
    /// The eight first-run steps, in order. The original five came from the
    /// approved mockup (`/tmp/tessera-firstlaunch-mockups/index.html`, since
    /// gone — the in-code copy IS the record); the three Remote Files cards
    /// (files panel / share / paste a screenshot) came from the approved mockup
    /// `docs/mockups/onboarding-files/index.html`. Shortcut chords are verified
    /// against `TesseraTerminalView.swift` (⌘⇧E → Files panel).
    static let firstRun: [OnboardingStep] = [
        OnboardingStep(
            title: "add your first host",
            body: "Start here. Name it, drop in an address, pick an SSH key, "
                + "then connect. ⌘N works from anywhere.",
            kind: .spotlight(.addHost, .below)
        ),
        OnboardingStep(
            title: "keys, secured by your iPad",
            body: "Generate SSH keys backed by the Secure Enclave, unlocked with "
                + "Face ID. Tessera can even install the public key on your "
                + "server for you.",
            kind: .spotlight(.keysNav, .right)
        ),
        OnboardingStep(
            title: "tmux windows & panes",
            body: "Every tmux window is a tab up top — ⌘T opens one, ⌘1–9 jumps. "
                + "Split a window into panes with ⌘D. Native -CC, not a "
                + "passthrough.",
            kind: .illustration(.mockTerminal)
        ),
        OnboardingStep(
            title: "swipe pad",
            body: "Flick the floating puck to approve / deny Claude Code "
                + "prompts, double-tap to dictate. Auto-detects the app; "
                + "fully customizable.",
            kind: .illustration(.claudeCodePromptWithPuck)
        ),
        OnboardingStep(
            title: "files, beside your shell",
            body: "A folder glyph up top — or ⌘⇧E — slides out a panel that "
                + "tracks your shell's directory. Browse, download, and Quick "
                + "Look files on the host, over SSH and mosh alike.",
            kind: .illustration(.filesPanel)
        ),
        OnboardingStep(
            title: "share, in and out",
            body: "Drag or share a remote file out to Files, Mail, or Photos. "
                + "Share a file into Tessera from any app and it lands on the "
                + "host — the native iOS share sheet, both directions.",
            kind: .illustration(.shareInOut)
        ),
        OnboardingStep(
            title: "paste a screenshot",
            body: "Share an image in, or drop one on the terminal — Tessera "
                + "uploads it and types the path. Claude Code and Codex pick it "
                + "up automatically, just like dragging a file in on the desktop.",
            kind: .illustration(.agentImagePaste)
        ),
        OnboardingStep(
            title: "keyboard shortcuts",
            body: "With a Magic Keyboard, these are always a chord away:",
            kind: .illustration(.shortcuts)
        )
    ]
}
