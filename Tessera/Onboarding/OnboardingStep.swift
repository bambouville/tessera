import Foundation

/// Where a spotlight step's callout sits relative to its target. Mirrors the
/// `place` field in the approved mockup's `render()`.
enum OnboardingPlacement: Equatable {
    case below
    case right
}

/// Self-contained illustration cards. None reference a real on-screen
/// element — they're freestanding diagrams drawn by `OnboardingOverlay`.
enum OnboardingIllustration: Equatable {
    /// Device-neutral key choices: recoverable Ed25519 versus a device-bound
    /// P-256 key, with owner-presence protection shown as an explicit choice.
    case keySecurity
    /// A static mock tmux terminal: window tab strip + a few output lines. No
    /// live session exists on first launch, so this is an illustration only.
    case mockTerminal
    /// A compact Agent Center overview with agents in different sessions and
    /// distinct working / needs-input states.
    case agentCenter
    /// The Swipe Pad's real center-puck radial, including a traced drag from
    /// the center toward one live prompt option.
    case swipePad
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
    /// The iPhone software-keyboard accessory bar and its sticky modifier
    /// controls. This replaces the Magic Keyboard cheat sheet on compact
    /// devices, where a hardware keyboard cannot be assumed.
    case phoneControls
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
    let compactTitle: String?
    let compactBody: String?
    let compactKind: OnboardingStepKind?

    init(
        title: String,
        body: String,
        kind: OnboardingStepKind,
        compactTitle: String? = nil,
        compactBody: String? = nil,
        compactKind: OnboardingStepKind? = nil
    ) {
        self.title = title
        self.body = body
        self.kind = kind
        self.compactTitle = compactTitle
        self.compactBody = compactBody
        self.compactKind = compactKind
    }

    func presentation(compact: Bool) -> OnboardingStep {
        guard compact else { return self }
        return OnboardingStep(
            title: compactTitle ?? title,
            body: compactBody ?? body,
            kind: compactKind ?? kind
        )
    }
}

extension OnboardingStep {
    /// The nine first-run steps, in order. The original feature set came from the
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
            kind: .spotlight(.addHost, .below),
            compactBody: "Start here. Name it, enter an address, choose an SSH key, "
                + "then connect.",
            compactKind: .spotlight(.addHost, .below)
        ),
        OnboardingStep(
            title: "keys, protected your way",
            body: "Create recoverable Ed25519 keys or device-bound P-256 keys. "
                + "Biometrics or passcode are optional, and Tessera can install "
                + "the public key for you.",
            kind: .spotlight(.keysNav, .right),
            compactKind: .illustration(.keySecurity)
        ),
        OnboardingStep(
            title: "tmux windows & panes",
            body: "In tmux sessions, every window is a tab up top — ⌘T opens one, "
                + "⌘1–9 jumps, and ⌘D splits a pane. Native control mode, not "
                + "a passthrough.",
            kind: .illustration(.mockTerminal),
            compactBody: "Open and switch tmux windows from the top bar. Split panes "
                + "stay intact while the focused pane fits the phone viewport."
        ),
        OnboardingStep(
            title: "agent center",
            body: "Follow Claude Code and Codex across every session. See who "
                + "needs input, answer a prompt, or jump straight to the right terminal.",
            kind: .illustration(.agentCenter)
        ),
        OnboardingStep(
            title: "swipe pad",
            body: "Touch the center puck, then swipe toward an option and release "
                + "to send it. The layout follows live prompts; double-tap the "
                + "center for dictation.",
            kind: .illustration(.swipePad)
        ),
        OnboardingStep(
            title: "files, beside your shell",
            body: "A folder glyph up top — or ⌘⇧E — slides out a panel that "
                + "tracks your shell's directory. Browse, download, and Quick "
                + "Look files on the host, over SSH and mosh alike.",
            kind: .illustration(.filesPanel),
            compactTitle: "files from your phone",
            compactBody: "Open Files from the terminal top bar to browse, download, "
                + "and Quick Look remote files. SSH, tmux, and mosh sessions share "
                + "the same file tools."
        ),
        OnboardingStep(
            title: "share, in and out",
            body: "Drag or share a remote file out to Files, Mail, or Photos. "
                + "Share a file into Tessera from any app and it lands on the "
                + "host — the native iOS share sheet, both directions.",
            kind: .illustration(.shareInOut),
            compactBody: "Send a remote file to another app, or share a local file "
                + "into Tessera and choose its host. The native iOS share sheet "
                + "works in both directions."
        ),
        OnboardingStep(
            title: "paste a screenshot",
            body: "Share an image in, or drop one on the terminal — Tessera "
                + "uploads it and types the path. Claude Code and Codex pick it "
                + "up automatically, just like dragging a file in on the desktop.",
            kind: .illustration(.agentImagePaste),
            compactBody: "Share an image into Tessera and choose an active session. "
                + "Tessera uploads it, types the path, and Claude Code or Codex "
                + "attaches it automatically."
        ),
        OnboardingStep(
            title: "keyboard shortcuts",
            body: "With a Magic Keyboard, global and context-aware actions stay a "
                + "chord away:",
            kind: .illustration(.shortcuts),
            compactTitle: "terminal controls",
            compactBody: "The keyboard bar keeps Escape, arrows, Tab, Control, and "
                + "other shell keys within reach. Tap a modifier once for the next "
                + "key, or twice to lock it.",
            compactKind: .illustration(.phoneControls)
        )
    ]
}
