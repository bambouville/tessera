// Tessera/Keyboard/AccessoryBarItem.swift
// What can sit on the accessory bar: a built-in key, or one of the user's own
// shortcuts.
//
// `AppearancePreferences.accessoryBarKeys` stays `[String]`. A custom entry is
// stored as "custom:<uuid>", which `AccessoryChip.init(rawValue:)` fails to
// decode — and because the bar decodes through `compactMap`, a build that
// predates custom chips drops the entry and keeps the rest of the bar rather
// than losing the whole array. Forward and backward compatible without a
// migration; `CustomShortcutTests` pins it.
import SwiftUI

enum AccessoryBarItem: Equatable, Identifiable {
    case chip(AccessoryChip)
    case custom(CustomShortcut)

    var id: String { rawID }

    var rawID: String {
        switch self {
        case .chip(let chip):     return chip.rawValue
        case .custom(let custom): return custom.chipRawID
        }
    }

    /// Modifier chips arm state instead of sending bytes. No custom shortcut
    /// can be a modifier, so this is false for every user entry.
    var isModifier: Bool {
        switch self {
        case .chip(let chip): return chip.isModifier
        case .custom:         return false
        }
    }

    /// An icon chip carries no readable text, so a custom shortcut's *name*
    /// becomes its VoiceOver label. That is why the name field is required.
    var accessibilityLabel: String {
        switch self {
        case .chip(let chip):     return chip.accessibilityLabel
        case .custom(let custom): return custom.name
        }
    }

    var customShortcut: CustomShortcut? {
        if case .custom(let custom) = self { return custom }
        return nil
    }

    /// Resolves a stored raw ID against the built-in catalog first, then the
    /// user's shortcuts. Unknown IDs return nil and are dropped by the caller's
    /// `compactMap`.
    static func resolve(_ raw: String, customLookup: (String) -> CustomShortcut?) -> AccessoryBarItem? {
        if let chip = AccessoryChip(rawValue: raw) { return .chip(chip) }
        if let custom = customLookup(raw) { return .custom(custom) }
        return nil
    }
}

/// How a bar item draws. Built-ins are always text; custom chips choose.
enum AccessoryBarItemLabel: Equatable {
    case text(String)
    /// SF Symbol name — monochrome, tints with the theme, which is what keeps
    /// the bar reading as chrome rather than a sticker sheet.
    case symbol(String)

    /// Longer labels get a smaller face so a six-character word still fits the
    /// 44pt chip.
    var isLong: Bool {
        if case .text(let s) = self { return s.count > 2 }
        return false
    }
}

extension AccessoryBarItem {
    func label(_ notation: ModifierNotation) -> AccessoryBarItemLabel {
        switch self {
        case .chip(let chip):
            return .text(chip.displayLabel(notation))
        case .custom(let custom):
            switch custom.chipLabel {
            case .symbol(let name):  return .symbol(name)
            case .text(let text):    return .text(text)
            case .character(let c):  return .text(c)
            case .none:
                // A chord-only shortcut that somehow reached the bar still
                // needs something to draw.
                return .text(String(custom.name.prefix(6)))
            }
        }
    }
}
