import UIKit

enum AccessoryChip: String, CaseIterable, Codable {
    // navigation
    case left, down, up, right, home, end, pgup, pgdn, tab
    // modifiers
    case ctrl, alt, shift
    // simple key-bytes modifiers
    case esc
    case ctrlJ
    // function keys
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    // symbols
    case pipe, tilde, slash, backslash, dollar, lbrace, rbrace, lbracket, rbracket, lt, gt

    var displayLabel: String {
        switch self {
        case .esc:
            "esc"
        case .ctrlJ:
            "^J"
        case .ctrl:
            "^"
        case .alt:
            "⌥"
        case .shift:
            "⇧"
        case .tab:
            "⇥"
        case .left:
            "←"
        case .down:
            "↓"
        case .up:
            "↑"
        case .right:
            "→"
        case .home:
            "home"
        case .end:
            "end"
        case .pgup:
            "pgup"
        case .pgdn:
            "pgdn"
        case .f1:
            "F1"
        case .f2:
            "F2"
        case .f3:
            "F3"
        case .f4:
            "F4"
        case .f5:
            "F5"
        case .f6:
            "F6"
        case .f7:
            "F7"
        case .f8:
            "F8"
        case .f9:
            "F9"
        case .f10:
            "F10"
        case .f11:
            "F11"
        case .f12:
            "F12"
        case .pipe:
            "|"
        case .tilde:
            "~"
        case .slash:
            "/"
        case .backslash:
            "\\"
        case .dollar:
            "$"
        case .lbrace:
            "{"
        case .rbrace:
            "}"
        case .lbracket:
            "["
        case .rbracket:
            "]"
        case .lt:
            "<"
        case .gt:
            ">"
        }
    }

    var isModifier: Bool {
        switch self {
        case .ctrl, .alt, .shift:
            true
        default:
            false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .ctrl: "Control"
        case .alt: "Option"
        case .shift: "Shift"
        case .esc: "Escape"
        case .ctrlJ: "Control-J"
        case .tab: "Tab"
        case .left: "Left arrow"
        case .down: "Down arrow"
        case .up: "Up arrow"
        case .right: "Right arrow"
        case .pgup: "Page up"
        case .pgdn: "Page down"
        default: rawValue
        }
    }

    static var defaultBarOrder: [AccessoryChip] {
        defaultBarOrder(for: UIDevice.current.userInterfaceIdiom)
    }

    static func defaultBarOrder(for idiom: UIUserInterfaceIdiom) -> [AccessoryChip] {
        if idiom == .phone {
            return [.esc, .ctrl, .tab, .left, .right, .down, .up, .alt, .ctrlJ]
        }
        return [.esc, .ctrl, .alt, .tab, .left, .down, .up, .right, .pipe, .tilde]
    }

    static func from(rawIDs: [String]) -> [AccessoryChip] {
        rawIDs.compactMap(AccessoryChip.init(rawValue:))
    }
}
