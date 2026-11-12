import SwiftUI

extension EnvironmentValues {
    /// The compact shell is laid out around Duo's vertical rail. Pages read
    /// this instead of re-deriving it from the rail edge and the size class.
    @Entry var duoRailMode: Bool = false
    /// ▾ on the rail: ⌘K's switcher, which only the shell can open (it knows
    /// the live sessions and their tmux windows). Nil outside rail mode.
    @Entry var duoOpenSwitcher: DuoSwitcherAction? = nil
    /// Two panes, beside each other or across the laptop's fold: the
    /// session's Files panel docks in the context pane instead of presenting
    /// the phone's sheet.
    @Entry var duoFilesDocked: Bool = false
    /// Docked, opening Files first turns the context pane to the session's
    /// files and brings it up. Nil where Files is a sheet.
    @Entry var duoShowFilesInContext: DuoPaneAction? = nil
    /// Docked, closing Files turns the context back to its last tab, since
    /// the files slot would only open the panel again. Nil where Files is a
    /// sheet.
    @Entry var duoLeaveFilesInContext: DuoPaneAction? = nil
    /// The other pane is full screen over this one, which stays mounted but
    /// must give up the keyboard.
    @Entry var duoPaneHidden: Bool = false
    /// The session's background picture runs under its panes' headers, which
    /// then frost it instead of covering it.
    @Entry var duoPanesOverPicture: Bool = false
    /// The window's global frame in rail mode, nil elsewhere. The docked
    /// keyboard spans all of it, rail included, so the session's accessory bar
    /// does too while the keyboard is up.
    @Entry var duoWindowFrame: CGRect? = nil
}

/// The selected session's accessory bar, in global coordinates, while it
/// spans a docked keyboard wider than its pane. Duo's workspace draws that
/// pane over the other and keeps the other's content clear of the bar; the
/// rail-mode layer lets the bar draw and take touches over the rail.
struct KeyboardSpanningBarFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// Called like a closure (`openSwitcher()`). Always equal: the shell rebuilds
/// it on every update, and a bare closure would invalidate each reader then.
struct DuoSwitcherAction: Equatable {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) { self.action = action }

    func callAsFunction() { action() }

    static func == (lhs: DuoSwitcherAction, rhs: DuoSwitcherAction) -> Bool { true }
}

/// The shell's action on one session's panes, equal for the same reason.
struct DuoPaneAction: Equatable {
    private let action: (UUID) -> Void

    init(_ action: @escaping (UUID) -> Void) { self.action = action }

    func callAsFunction(_ sessionID: UUID) { action(sessionID) }

    static func == (lhs: DuoPaneAction, rhs: DuoPaneAction) -> Bool { true }
}
