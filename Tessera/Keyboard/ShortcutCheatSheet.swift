// Tessera/Keyboard/ShortcutCheatSheet.swift
// Project the effective keymap into a stable, display-only list. Sharing the
// registry and store avoids a second legend that drifts after remapping.
import Foundation
import TesseraInputCore

struct ShortcutCheatSheetSection: Identifiable, Equatable {
    let id: String
    let title: String
    let note: String?
    let rows: [ShortcutCheatSheetRow]
}

struct ShortcutCheatSheetRow: Identifiable, Equatable {
    let id: String
    let title: String
    let chord: String
}

enum ShortcutCheatSheet {
    @MainActor
    static func sections(store: ShortcutStore?, notation: ModifierNotation) -> [ShortcutCheatSheetSection] {
        var sections: [ShortcutCheatSheetSection] = []
        for group in ShortcutGroup.allCases where group != .custom {
            let rows = ShortcutAction.allCases.compactMap { action -> ShortcutCheatSheetRow? in
                guard action.group == group,
                      let binding = StoredShortcut.binding(action, in: store) else { return nil }
                let chord = action.isDigitBlock
                    ? KeyChordRange(modifiers: binding.modifiers, from: "1", to: "9")
                        .rendered(notation, compact: true)
                    : binding.rendered(notation)
                return ShortcutCheatSheetRow(id: action.id, title: action.title, chord: chord)
            }
            guard !rows.isEmpty else { continue }
            let note: String?
            switch group {
            case .tmux: note = String(localized: "— live only while a tmux session is attached")
            case .panes: note = String(localized: "— live once a window holds more than one pane")
            case .artifacts: note = String(localized: "— live while the artifacts browser has focus")
            default: note = nil
            }
            sections.append(ShortcutCheatSheetSection(
                id: group.id, title: group.title, note: note, rows: rows
            ))
        }
        let customs = (store?.customShortcuts ?? []).compactMap { shortcut -> ShortcutCheatSheetRow? in
            guard let binding = shortcut.binding else { return nil }
            return ShortcutCheatSheetRow(
                id: "custom:\(shortcut.id.uuidString)",
                title: shortcut.name.isEmpty ? String(localized: "untitled") : shortcut.name,
                chord: binding.rendered(notation)
            )
        }
        if !customs.isEmpty {
            sections.append(ShortcutCheatSheetSection(
                id: ShortcutGroup.custom.id, title: ShortcutGroup.custom.title, note: nil, rows: customs
            ))
        }
        return sections
    }
}
