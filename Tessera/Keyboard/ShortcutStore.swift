// Tessera/Keyboard/ShortcutStore.swift
// Persistence for keymap overrides and custom shortcuts.
//
// Storage is a JSON delta in UserDefaults, merged over `ShortcutAction`'s
// defaults on load — the model `SwipePadProfileStore` already uses. Deliberately
// NOT SwiftData: adding a column to a `@Model` that owns a `[String]` crashes
// iOS 26 lightweight migration, and `PersistedHost` is one of those.
//
// Only *changed* actions are written. An empty override map is a user who never
// opened the editor, so "restore all defaults" is a delete rather than a
// rewrite, and a future default chord change reaches everyone who hasn't
// deliberately moved that binding.
import Foundation
import Observation

@MainActor
@Observable
final class ShortcutStore {
    static let overridesKey = "tessera.pref.shortcutOverrides"
    static let customKey = "tessera.pref.customShortcuts"

    /// Actions the user has moved. A present-but-nil value means "deliberately
    /// unbound", which is different from "never touched".
    private(set) var overrides: [ShortcutAction: KeyBinding?] = [:]
    private(set) var customShortcuts: [CustomShortcut] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reading

    /// The effective binding for an action, or nil if deliberately unbound.
    func binding(for action: ShortcutAction) -> KeyBinding? {
        if let override = overrides[action] { return override }
        return action.defaultBinding
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action] != nil
    }

    /// Every live binding, for conflict detection. Custom shortcuts are
    /// included by intent: a chord can only belong to one thing.
    var allBindings: [ShortcutAction: KeyBinding] {
        var out: [ShortcutAction: KeyBinding] = [:]
        for action in ShortcutAction.allCases {
            if let binding = binding(for: action) { out[action] = binding }
        }
        return out
    }

    func customShortcut(withChipRawID raw: String) -> CustomShortcut? {
        guard let id = CustomShortcut.id(fromChipRawID: raw) else { return nil }
        return customShortcuts.first { $0.id == id }
    }

    func customShortcut(matching binding: KeyBinding) -> CustomShortcut? {
        customShortcuts.first { $0.binding == binding }
    }

    var changedCount: Int { overrides.count }

    // MARK: - Writing

    func setBinding(_ binding: KeyBinding?, for action: ShortcutAction) {
        if binding == action.defaultBinding {
            // Back to the shipped chord — stop storing it, so a future default
            // change still reaches this user.
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = binding
        }
        persistOverrides()
    }

    func resetToDefault(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action)
        persistOverrides()
    }

    func restoreAllDefaults() {
        overrides.removeAll()
        defaults.removeObject(forKey: Self.overridesKey)
    }

    func upsert(_ shortcut: CustomShortcut) {
        if let index = customShortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            customShortcuts[index] = shortcut
        } else {
            customShortcuts.append(shortcut)
        }
        persistCustom()
    }

    func delete(_ shortcut: CustomShortcut) {
        customShortcuts.removeAll { $0.id == shortcut.id }
        persistCustom()
    }

    // MARK: - Persistence

    /// Overrides are keyed by `ShortcutAction.rawValue`; an explicit unbind is
    /// stored as a null so it round-trips distinctly from "absent".
    private struct StoredOverride: Codable {
        var action: String
        var binding: KeyBinding?
    }

    private func persistOverrides() {
        let rows = overrides.map { StoredOverride(action: $0.key.rawValue, binding: $0.value) }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        defaults.set(data, forKey: Self.overridesKey)
    }

    private func persistCustom() {
        guard let data = try? JSONEncoder().encode(customShortcuts) else { return }
        defaults.set(data, forKey: Self.customKey)
    }

    private func load() {
        if let data = defaults.data(forKey: Self.overridesKey),
           let rows = try? JSONDecoder().decode([StoredOverride].self, from: data) {
            for row in rows {
                // Unknown action names are dropped rather than failing the
                // whole decode, so a rolled-back build keeps the rest.
                guard let action = ShortcutAction(rawValue: row.action) else { continue }
                overrides[action] = row.binding
            }
        }
        if let data = defaults.data(forKey: Self.customKey),
           let stored = try? JSONDecoder().decode([CustomShortcut].self, from: data) {
            customShortcuts = stored
        }
    }
}
