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
    /// The five first-run steps, in order. Copy is lifted verbatim from the
    /// approved mockup (`/tmp/tessera-firstlaunch-mockups/index.html`); the
    /// shortcut chords are verified against `TesseraTerminalView.swift`.
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
            title: "tmux, as tabs",
            body: "Every tmux window is a tab up top. ⌘T opens one, ⌘1–9 jumps, "
                + "⌘⇧[ ] cycle — native -CC, not a passthrough.",
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
            title: "keyboard shortcuts",
            body: "With a Magic Keyboard, these are always a chord away:",
            kind: .illustration(.shortcuts)
        )
    ]
}
