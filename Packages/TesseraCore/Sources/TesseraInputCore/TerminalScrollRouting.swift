import Foundation

/// Where one scroll gesture goes, decided the same way on every platform and
/// every transport.
public enum TerminalScrollRoute: String, Sendable, Equatable, CaseIterable {
    /// Move the local scrollback (on mosh+tmux, the capture-pane overlay).
    case localScrollback
    /// Report mouse-wheel ticks to the remote program.
    case mouseWheel
    /// Translate into arrow-key presses for a full-screen program that has
    /// no mouse mode (`less`, a pager, Vim without `mouse=a`).
    case arrowKeys
}

/// The rule:
///
///   1. primary screen                    → `localScrollback`
///   2. alternate screen + mouse reporting → `mouseWheel`
///   3. alternate screen, no mouse mode    → `arrowKeys`
///
/// The screen decides, never mouse tracking alone. That distinction is what
/// keeps mosh+tmux honest: mosh never relays the alternate screen (its
/// framebuffer has none), so the visible tmux client sits on the primary
/// screen with the server's `mouse on` in force. A wheel report there does
/// not scroll anything — tmux answers with copy-mode and its `[n/m]`
/// indicator — while the local overlay the side channel painted is exactly
/// what the gesture should move.
///
/// `mouseReportingImpliesAltScreen` is the one input a platform supplies from
/// session state rather than from the emulator: true only while the session
/// has no local scrollback to offer (plain mosh, or mosh+tmux before the side
/// channel has produced a pane grid), so that a remote program which asked
/// for the mouse still receives the wheel. iOS has always passed exactly
/// this; Android now passes the same.
public enum TerminalScrollRouting {
    /// Whether the surface counts as the alternate screen for scroll
    /// purposes: the emulator's buffer, or mouse reporting when the session
    /// has declared that it stands in for the alternate screen.
    public static func isAltScreen(
        bufferIsAlternate: Bool,
        mouseReporting: Bool,
        mouseReportingImpliesAltScreen: Bool
    ) -> Bool {
        bufferIsAlternate || (mouseReportingImpliesAltScreen && mouseReporting)
    }

    public static func route(
        bufferIsAlternate: Bool,
        mouseReporting: Bool,
        mouseReportingImpliesAltScreen: Bool
    ) -> TerminalScrollRoute {
        guard isAltScreen(
            bufferIsAlternate: bufferIsAlternate,
            mouseReporting: mouseReporting,
            mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen
        ) else { return .localScrollback }
        return mouseReporting ? .mouseWheel : .arrowKeys
    }
}
