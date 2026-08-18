// Tessera/Keyboard/ShortcutAction.swift
// The catalog of app actions a keyboard shortcut can be bound to.
//
// These facts used to live in three places that had to agree by hand: the
// `UIKeyCommand` list in TesseraTerminalView, the availability gates in its
// `canPerformAction`, and a hard-coded legend in KeyboardSettingsView. The
// legend is now a projection of this registry rather than a copy of it, which
// is what makes remapping possible at all.
//
// The doc comments on each case carry the *reason* a default chord is what it
// is. Several are the record of chords that were tried and failed on device —
// deleting them invites re-trying ⌃Tab.
import Foundation

/// When a bound action is live. Mirrors the gates in
/// `TesseraTerminalContainer.canPerformAction`.
enum ShortcutAvailability: Equatable {
    /// Always active while a session holds first responder.
    case always
    /// Only while a tmux session is attached.
    case tmuxAttached
    /// Only once the focused window holds more than one pane.
    case multiplePanes
    /// iPad only — iPhone exposes the action in the bar instead.
    case padOnly
    /// Lives on the host editor, not the terminal.
    case hostEditor
}

enum ShortcutGroup: String, CaseIterable, Identifiable {
    case global, sessions, find, tmux, panes, custom
    var id: String { rawValue }

    /// Resolved eagerly with `String(localized:)`: the callers uppercase it,
    /// search it, and interpolate it into VoiceOver labels, so it has to be a
    /// `String` — but every literal still sits at an extraction point.
    var title: String {
        switch self {
        case .global:   return String(localized: "global")
        case .sessions: return String(localized: "sessions")
        case .find:     return String(localized: "find in scrollback")
        case .tmux:     return String(localized: "tmux")
        case .panes:    return String(localized: "panes")
        case .custom:   return String(localized: "custom")
        }
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    // global
    case newHost
    case quickSwitchPalette
    case openSettings
    case toggleAgentCenter
    // sessions
    case previousSession
    case nextSession
    case toggleFilesPanel
    case refreshTerminal
    case connect
    // find
    case findOpen
    case findNext
    case findPrevious
    // tmux
    case tmuxNewWindow
    case tmuxCloseWindow
    case tmuxPreviousWindow
    case tmuxNextWindow
    case tmuxSelectWindow
    // panes
    case paneSplitSideBySide
    case paneSplitStacked
    case panePrevious
    case paneNext
    case paneZoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newHost:             return String(localized: "new host")
        case .quickSwitchPalette:  return String(localized: "quick-switch palette")
        case .openSettings:        return String(localized: "settings")
        case .toggleAgentCenter:   return String(localized: "toggle agent center")
        case .previousSession:     return String(localized: "previous session")
        case .nextSession:         return String(localized: "next session")
        case .toggleFilesPanel:    return String(localized: "toggle files panel")
        case .refreshTerminal:     return String(localized: "refresh terminal")
        case .connect:             return String(localized: "connect")
        case .findOpen:            return String(localized: "open find bar")
        case .findNext:            return String(localized: "next match")
        case .findPrevious:        return String(localized: "previous match")
        case .tmuxNewWindow:       return String(localized: "new window")
        case .tmuxCloseWindow:     return String(localized: "close pane / window")
        case .tmuxPreviousWindow:  return String(localized: "previous window")
        case .tmuxNextWindow:      return String(localized: "next window")
        case .tmuxSelectWindow:    return String(localized: "jump to window 1–9")
        case .paneSplitSideBySide: return String(localized: "split side-by-side")
        case .paneSplitStacked:    return String(localized: "split stacked")
        case .panePrevious:        return String(localized: "previous pane")
        case .paneNext:            return String(localized: "next pane")
        case .paneZoom:            return String(localized: "zoom pane")
        }
    }

    var detail: String? {
        switch self {
        case .newHost:            return String(localized: "opens the host editor from anywhere")
        case .quickSwitchPalette: return String(localized: "jump to any session or host")
        case .findNext, .findPrevious: return String(localized: "works with the find bar closed")
        case .refreshTerminal:    return String(localized: "iPad only — the terminal bar no longer carries a refresh button")
        case .connect:            return String(localized: "host editor only")
        case .tmuxCloseWindow:
            return String(localized: "⌘W is claimed by Stage Manager, so the default is ⇧⌘W")
        case .tmuxSelectWindow:
            return String(localized: "a nine-key block sharing one action — remapping changes the modifier, not the digits")
        default: return nil
        }
    }

    var group: ShortcutGroup {
        switch self {
        case .newHost, .quickSwitchPalette, .openSettings, .toggleAgentCenter:
            return .global
        case .previousSession, .nextSession, .toggleFilesPanel, .refreshTerminal, .connect:
            return .sessions
        case .findOpen, .findNext, .findPrevious:
            return .find
        case .tmuxNewWindow, .tmuxCloseWindow, .tmuxPreviousWindow, .tmuxNextWindow, .tmuxSelectWindow:
            return .tmux
        case .paneSplitSideBySide, .paneSplitStacked, .panePrevious, .paneNext, .paneZoom:
            return .panes
        }
    }

    var availability: ShortcutAvailability {
        switch self {
        case .refreshTerminal: return .padOnly
        case .connect:         return .hostEditor
        case .tmuxNewWindow, .tmuxCloseWindow, .tmuxPreviousWindow,
             .tmuxNextWindow, .tmuxSelectWindow, .paneSplitSideBySide, .paneSplitStacked:
            return .tmuxAttached
        case .panePrevious, .paneNext, .paneZoom:
            return .multiplePanes
        default:
            return .always
        }
    }

    /// `⌘1–⌘9` is nine `UIKeyCommand`s sharing one action, so the stored
    /// binding names only the modifier and the editor remaps the block.
    var isDigitBlock: Bool { self == .tmuxSelectWindow }

    /// The shipped chord. Changing one of these changes what "restore defaults"
    /// means, so the reasons live here rather than in a commit message.
    var defaultBinding: KeyBinding {
        switch self {
        case .newHost:            return .cmd("n")
        case .quickSwitchPalette: return .cmd("k")
        case .openSettings:       return KeyBinding([.command], .character(","))
        case .toggleAgentCenter:  return .cmdShift("a")
        // ⌘⇧K/⌘⇧J rather than ⌃Tab or ⌘⌥[: the focus engine eats Tab-family
        // keys, and ⌥ remaps punctuation so a command for "[" never matches.
        case .previousSession:    return .cmdShift("k")
        case .nextSession:        return .cmdShift("j")
        case .toggleFilesPanel:   return .cmdShift("e")
        case .refreshTerminal:    return .cmd("r")
        case .connect:            return KeyBinding([.command], .return)
        case .findOpen:           return .cmd("f")
        case .findNext:           return .cmd("g")
        case .findPrevious:       return .cmdShift("g")
        case .tmuxNewWindow:      return .cmd("t")
        // ⇧⌘W, not ⌘W — Stage Manager closes the scene on ⌘W.
        case .tmuxCloseWindow:    return .cmdShift("w")
        case .tmuxPreviousWindow: return .cmdShift("[")
        case .tmuxNextWindow:     return .cmdShift("]")
        case .tmuxSelectWindow:   return KeyBinding([.command], .character("1"))
        case .paneSplitSideBySide: return .cmd("d")
        case .paneSplitStacked:    return .cmdShift("d")
        // Bare ⌘[/⌘] cycle panes (iTerm2 parity — pane switching is the
        // high-frequency action), which is why session switching moved to
        // ⌘⇧K/⌘⇧J.
        case .panePrevious:        return .cmd("[")
        case .paneNext:            return .cmd("]")
        case .paneZoom:            return KeyBinding([.command, .shift], .return)
        }
    }

    /// Whether the registered `UIKeyCommand` sets
    /// `wantsPriorityOverSystemBehavior`, which promotes it above text input
    /// and focus movement for the first responder.
    ///
    /// These values reproduce the hand-written list this registry replaced,
    /// exactly. They are not a style choice — a chord that needed the flag and
    /// silently lost it becomes a shortcut that stops firing only while the
    /// terminal holds focus, which is the hardest kind of regression to notice.
    /// `ShortcutRegistryTests` pins them against the shipped behavior.
    var wantsPriorityOverSystemBehavior: Bool {
        switch self {
        case .previousSession, .nextSession, .refreshTerminal,
             .toggleAgentCenter, .toggleFilesPanel,
             .paneSplitSideBySide, .paneSplitStacked,
             .panePrevious, .paneNext, .paneZoom:
            return true
        case .newHost, .quickSwitchPalette, .openSettings, .connect,
             .findOpen, .findNext, .findPrevious,
             .tmuxNewWindow, .tmuxCloseWindow, .tmuxPreviousWindow,
             .tmuxNextWindow, .tmuxSelectWindow:
            return false
        }
    }

    /// Actions the terminal container registers. The rest ride SwiftUI
    /// `.keyboardShortcut` on hidden buttons in `ContentView` / the host editor.
    static var terminalActions: [ShortcutAction] {
        allCases.filter { $0 != .newHost && $0 != .connect }
    }

    static func actions(in group: ShortcutGroup) -> [ShortcutAction] {
        allCases.filter { $0.group == group }
    }
}
