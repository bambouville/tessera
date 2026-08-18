// Tessera/Keyboard/ShortcutScopeEvaluator.swift
// Decides whether a custom shortcut applies right now.
//
// Pure, so the rules are testable without a live session. The important one is
// the failure direction: an unknown foreground process means a program-scoped
// shortcut does NOT fire. Firing it would be the exact accident the scope
// exists to prevent — an "approve" shortcut that sends `1` into a shell.
import Foundation

enum ShortcutScopeEvaluator {
    /// - Parameters:
    ///   - hostID: the session's host, or nil where there isn't one.
    ///   - processName: the pane's foreground command. Available from tmux pane
    ///     metadata (`pane_current_command`); nil in plain passthrough, where
    ///     the app has no cheap process source.
    static func applies(
        _ scope: ShortcutScope,
        hostID: UUID?,
        processName: String?
    ) -> Bool {
        switch scope {
        case .everywhere:
            return true

        case .hosts(let ids):
            guard let hostID else { return false }
            return ids.contains(hostID)

        case .process(let spec):
            guard let processName, !processName.isEmpty else { return false }
            return SwipePadActiveProfileResolver.matches(spec: spec, processName: processName)
        }
    }
}
