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
    /// Only while the artifacts browser has keyboard focus: its page is on
    /// screen, or the user last touched a Duo context pane showing it.
    case artifactsBrowser
}

/// Where a chord is live. Two actions conflict only when their scopes can
/// be live at once: the browser's ⌘T and tmux's ⌘T never are, because a
/// focused terminal keeps its chords and a focused browser takes them.
enum ShortcutSurface: Equatable {
    /// Everywhere, including over the terminal and the browser.
    case app
    case terminal
    case browser
    case hostEditor

    func overlaps(_ other: ShortcutSurface) -> Bool {
        self == other || self == .app || other == .app
    }
}

enum ShortcutGroup: String, CaseIterable, Identifiable {
    case global, sessions, find, tmux, panes, artifacts, custom
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
        case .artifacts: return String(localized: "artifacts browser")
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
    case toggleArtifacts
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
    case tmuxMoveWindowLeft
    case tmuxMoveWindowRight
    // panes
    case paneSplitSideBySide
    case paneSplitStacked
    case panePrevious
    case paneNext
    case paneZoom
    // artifacts browser: live while it has keyboard focus, where they take
    // the same chords from the terminal (see `ShortcutSurface`).
    case browserNewTab
    case browserEditAddress
    case browserReload
    case browserBack
    case browserForward
    case browserCloseTab
    case browserReopenTab
    case browserPreviousTab
    case browserNextTab
    case browserSelectTab
    case browserTabOverview
    case browserFind
    case browserShareFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newHost:             return String(localized: "new host")
        case .quickSwitchPalette:  return String(localized: "quick-switch palette")
        case .openSettings:        return String(localized: "settings")
        case .toggleAgentCenter:   return String(localized: "toggle agent center")
        case .toggleArtifacts:     return String(localized: "toggle artifacts")
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
        case .tmuxSelectWindow:    return String(localized: "jump to window 1–8 / last")
        case .tmuxMoveWindowLeft:  return String(localized: "move window left")
        case .tmuxMoveWindowRight: return String(localized: "move window right")
        case .paneSplitSideBySide: return String(localized: "split side-by-side")
        case .paneSplitStacked:    return String(localized: "split stacked")
        case .panePrevious:        return String(localized: "previous pane")
        case .paneNext:            return String(localized: "next pane")
        case .paneZoom:            return String(localized: "zoom pane")
        case .browserNewTab:       return String(localized: "new tab")
        case .browserEditAddress:  return String(localized: "edit address")
        case .browserReload:       return String(localized: "reload")
        case .browserBack:         return String(localized: "back")
        case .browserForward:      return String(localized: "forward")
        case .browserCloseTab:     return String(localized: "close tab")
        case .browserReopenTab:    return String(localized: "reopen closed tab")
        case .browserPreviousTab:  return String(localized: "previous tab")
        case .browserNextTab:      return String(localized: "next tab")
        case .browserSelectTab:    return String(localized: "jump to tab 1–8 / last")
        case .browserTabOverview:  return String(localized: "tab overview")
        case .browserFind:         return String(localized: "find in page")
        case .browserShareFile:    return String(localized: "share file")
        }
    }

    var detail: String? {
        switch self {
        case .newHost:            return String(localized: "opens the host editor from anywhere")
        case .quickSwitchPalette: return String(localized: "jump to any session or host")
        case .toggleArtifacts:    return String(localized: "every tab from every session; again goes back to where you were")
        case .findNext, .findPrevious: return String(localized: "works with the find bar closed")
        case .refreshTerminal:    return String(localized: "iPad only — the terminal bar no longer carries a refresh button")
        case .connect:            return String(localized: "host editor only")
        case .tmuxCloseWindow:
            return String(localized: "⌘W is claimed by Stage Manager, so the default is ⇧⌘W")
        case .tmuxSelectWindow, .browserSelectTab:
            return String(localized: "a nine-key block sharing one action — remapping changes the modifier, not the digits")
        case .browserCloseTab:
            return String(localized: "⌘W is claimed by Stage Manager, so the default is ⇧⌘W")
        case .browserFind:
            return String(localized: "web pages only")
        case .browserShareFile:
            return String(localized: "files with a complete downloaded copy")
        default: return nil
        }
    }

    var group: ShortcutGroup {
        switch self {
        case .newHost, .quickSwitchPalette, .openSettings, .toggleAgentCenter, .toggleArtifacts:
            return .global
        case .previousSession, .nextSession, .toggleFilesPanel, .refreshTerminal, .connect:
            return .sessions
        case .findOpen, .findNext, .findPrevious:
            return .find
        case .tmuxNewWindow, .tmuxCloseWindow, .tmuxPreviousWindow, .tmuxNextWindow, .tmuxSelectWindow, .tmuxMoveWindowLeft, .tmuxMoveWindowRight:
            return .tmux
        case .paneSplitSideBySide, .paneSplitStacked, .panePrevious, .paneNext, .paneZoom:
            return .panes
        case .browserNewTab, .browserEditAddress, .browserReload, .browserBack, .browserForward,
             .browserCloseTab, .browserReopenTab, .browserPreviousTab, .browserNextTab,
             .browserSelectTab, .browserTabOverview, .browserFind, .browserShareFile:
            return .artifacts
        }
    }

    var surface: ShortcutSurface {
        switch group {
        case .global: return .app
        case .artifacts: return .browser
        case .sessions, .find, .tmux, .panes, .custom: return availability == .hostEditor ? .hostEditor : .terminal
        }
    }

    var availability: ShortcutAvailability {
        switch self {
        case .refreshTerminal: return .padOnly
        case .connect:         return .hostEditor
        case .tmuxNewWindow, .tmuxCloseWindow, .tmuxPreviousWindow,
             .tmuxNextWindow, .tmuxSelectWindow, .tmuxMoveWindowLeft, .tmuxMoveWindowRight, .paneSplitSideBySide, .paneSplitStacked:
            return .tmuxAttached
        case .panePrevious, .paneNext, .paneZoom:
            return .multiplePanes
        case _ where group == .artifacts:
            return .artifactsBrowser
        default:
            return .always
        }
    }

    /// `⌘1–⌘9` is nine `UIKeyCommand`s sharing one action, so the stored
    /// binding names only the modifier and the editor remaps the block.
    var isDigitBlock: Bool { self == .tmuxSelectWindow || self == .browserSelectTab }

    /// The shipped chord. Changing one of these changes what "restore defaults"
    /// means, so the reasons live here rather than in a commit message.
    var defaultBinding: KeyBinding? {
        switch self {
        case .newHost:            return .cmd("n")
        case .quickSwitchPalette: return .cmd("k")
        case .openSettings:       return KeyBinding([.command], .character(","))
        case .toggleAgentCenter:  return .cmdShift("a")
        case .toggleArtifacts:    return .cmdShift("b")
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
        // Assignable without claiming an unverified iPadOS system chord.
        case .tmuxMoveWindowLeft, .tmuxMoveWindowRight: return nil
        case .paneSplitSideBySide: return .cmd("d")
        case .paneSplitStacked:    return .cmdShift("d")
        // Bare ⌘[/⌘] cycle panes (iTerm2 parity — pane switching is the
        // high-frequency action), which is why session switching moved to
        // ⌘⇧K/⌘⇧J.
        case .panePrevious:        return .cmd("[")
        case .paneNext:            return .cmd("]")
        case .paneZoom:            return KeyBinding([.command, .shift], .return)
        // The browser's chords are Safari's, on a focused browser only. ⇧⌘W
        // closes a tab for the same Stage Manager reason as tmux's, and
        // ⇧⌘[ / ⇧⌘] step tabs because ⌃Tab never reaches the app.
        case .browserNewTab:       return .cmd("t")
        case .browserEditAddress:  return .cmd("l")
        case .browserReload:       return .cmd("r")
        case .browserBack:         return .cmd("[")
        case .browserForward:      return .cmd("]")
        case .browserCloseTab:     return .cmdShift("w")
        case .browserReopenTab:    return .cmdShift("t")
        case .browserPreviousTab:  return .cmdShift("[")
        case .browserNextTab:      return .cmdShift("]")
        case .browserSelectTab:    return KeyBinding([.command], .character("1"))
        case .browserTabOverview:  return .cmdShift("\\")
        case .browserFind:         return .cmd("f")
        case .browserShareFile:    return .cmdShift("s")
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
             .toggleAgentCenter, .toggleArtifacts, .toggleFilesPanel,
             .paneSplitSideBySide, .paneSplitStacked,
             .panePrevious, .paneNext, .paneZoom:
            return true
        // Registered on the terminal only while a Duo context pane holds the
        // browser's focus, where they must beat SwiftTerm's text input.
        case .browserNewTab, .browserEditAddress, .browserReload, .browserBack, .browserForward,
             .browserCloseTab, .browserReopenTab, .browserPreviousTab, .browserNextTab,
             .browserSelectTab, .browserTabOverview, .browserFind, .browserShareFile:
            return true
        case .newHost, .quickSwitchPalette, .openSettings, .connect,
             .findOpen, .findNext, .findPrevious,
             .tmuxNewWindow, .tmuxCloseWindow, .tmuxPreviousWindow,
             .tmuxNextWindow, .tmuxSelectWindow, .tmuxMoveWindowLeft, .tmuxMoveWindowRight:
            return false
        }
    }

    /// Actions the terminal container registers. The rest ride SwiftUI
    /// `.keyboardShortcut` on hidden buttons in `ContentView` / the host editor,
    /// and the browser's on hidden buttons in the browser (see
    /// `ArtifactsBrowserShortcuts`), which the terminal relays only while a
    /// Duo context pane holds the browser's focus.
    static var terminalActions: [ShortcutAction] {
        allCases.filter { $0 != .newHost && $0 != .connect && $0.group != .artifacts }
    }

    static var browserActions: [ShortcutAction] { actions(in: .artifacts) }

    static func actions(in group: ShortcutGroup) -> [ShortcutAction] {
        allCases.filter { $0.group == group }
    }
}
