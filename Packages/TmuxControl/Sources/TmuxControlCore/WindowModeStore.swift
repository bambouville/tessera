/// The keyboard-mode action a terminal adapter performs when a tmux window
/// becomes visible.
///
/// `reset` is deliberate rather than an absent action: a shared terminal may
/// retain modes from its passthrough prologue or the previously rendered
/// window, and an incoming window with no saved keyboard mode must clear them.
public enum WindowKeyboardModeRestoreDecision<KeyboardMode> {
    case reset
    case restore(KeyboardMode)
}

/// The complete terminal-mode decision for a window restore.
///
/// Bracketed paste is retained separately because the tmux versions Tessera
/// supports do not report it in rendered-pane metadata. The platform applies
/// it after the repaint, which never changes mode 2004.
public struct WindowModeRestore<KeyboardMode> {
    public let keyboardMode: WindowKeyboardModeRestoreDecision<KeyboardMode>
    public let bracketedPasteEnabled: Bool

    public init(
        keyboardMode: WindowKeyboardModeRestoreDecision<KeyboardMode>,
        bracketedPasteEnabled: Bool
    ) {
        self.keyboardMode = keyboardMode
        self.bracketedPasteEnabled = bracketedPasteEnabled
    }
}

/// Portable per-tmux-window terminal-mode bookkeeping.
///
/// A terminal adapter supplies its opaque keyboard-mode snapshot when saving
/// and receives an equally opaque value when restoring. This keeps SwiftTerm
/// and Android terminal types out of the shared core while preserving the
/// existing inline tmux semantics.
///
/// The alternate-screen guard is intentional. tmux drops `%output` for
/// non-visible windows, so an app's kitty-mode pop can be missed while its
/// window is off-screen. Kitty-aware TUIs use those flags in the alternate
/// screen; if tmux later reports the pane on its normal screen, the adapter's
/// `clearingAlternateScreenState` transform discards the stale portion before
/// restoring it. The transformed snapshot is retained, so a later restore
/// cannot revive the discarded alternate-screen state.
///
/// Window ids are not reused within one tmux server epoch. Entries are
/// therefore intentionally retained until the enclosing session is discarded.
public struct WindowModeStore<KeyboardMode> {
    private var keyboardModes: [WindowId: KeyboardMode] = [:]
    private var bracketedPasteModes: [WindowId: Bool] = [:]

    public init() {}

    /// Saves one window's current terminal-local state before its surface is
    /// reused. Pass `nil` for an empty keyboard snapshot; this removes any
    /// previously retained keyboard state while preserving the 2004 value.
    public mutating func save(
        keyboardMode: KeyboardMode?,
        bracketedPasteEnabled: Bool,
        for windowID: WindowId
    ) {
        if let keyboardMode {
            keyboardModes[windowID] = keyboardMode
        } else {
            keyboardModes.removeValue(forKey: windowID)
        }
        bracketedPasteModes[windowID] = bracketedPasteEnabled
    }

    /// Decides which keyboard mode and bracketed-paste state the incoming
    /// window needs after its repaint.
    ///
    /// The transform is owned by the terminal adapter because the keyboard
    /// snapshot is intentionally opaque to this portable target. It is called
    /// only for a saved mode whose pane is no longer in the alternate screen.
    @discardableResult
    public mutating func restore(
        for windowID: WindowId,
        paneInAltScreen: Bool,
        clearingAlternateScreenState: (KeyboardMode) -> KeyboardMode
    ) -> WindowModeRestore<KeyboardMode> {
        let bracketedPasteEnabled = bracketedPasteModes[windowID] ?? false
        guard let saved = keyboardModes[windowID] else {
            return .init(keyboardMode: .reset, bracketedPasteEnabled: bracketedPasteEnabled)
        }

        let restored = paneInAltScreen
            ? saved
            : clearingAlternateScreenState(saved)
        keyboardModes[windowID] = restored
        return .init(
            keyboardMode: .restore(restored),
            bracketedPasteEnabled: bracketedPasteEnabled
        )
    }

    /// Returns `nil` until a window has been saved. This preserves the
    /// existing distinction used by off-screen command-paste routing between
    /// an unknown window and one known to have 2004 disabled.
    public func bracketedPasteEnabled(for windowID: WindowId) -> Bool? {
        bracketedPasteModes[windowID]
    }
}
