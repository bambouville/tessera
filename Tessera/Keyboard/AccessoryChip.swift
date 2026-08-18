import UIKit

enum AccessoryChip: String, CaseIterable, Codable {
    // navigation
    case left, down, up, right, home, end, pgup, pgdn, tab
    // modifiers
    case ctrl, alt, shift
    /// Command. Unlike the other three this sends nothing to the remote — no
    /// terminal encoding carries ⌘ — it arms Tessera's own shortcuts so the
    /// next key runs an app action. See `AppShortcutDispatcher`.
    case cmd
    // simple key-bytes modifiers
    case esc
    case ctrlC, ctrlJ
    // function keys
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    // symbols
    case pipe, tilde, slash, backslash, dollar, lbrace, rbrace, lbracket, rbracket, lt, gt

    /// Label for the chip under the user's notation preference.
    ///
    /// Six chips move: the four bare modifiers (ctrl, alt, shift, tab) and the
    /// two control shortcuts. The control shortcuts were briefly left as caret
    /// notation on the argument that `^C` is what the shell *echoes* — but a
    /// bar whose control chip reads ⌃ next to a chip reading ^C is telling the
    /// user two things about the same key, so they follow the setting too.
    /// They render through `Chord`, so ⌃C / ctrl-c match the rest of the app
    /// exactly rather than being spelled a second way here.
    func displayLabel(_ notation: ModifierNotation) -> String {
        switch self {
        case .ctrl:  return KeyToken.control.rendered(notation)
        case .cmd:   return KeyToken.command.rendered(notation)
        case .alt:   return KeyToken.option.rendered(notation)
        case .shift: return KeyToken.shift.rendered(notation)
        case .tab:   return KeyToken.tab.rendered(notation)
        case .ctrlC: return Chord([.control], .character("c")).rendered(notation)
        case .ctrlJ: return Chord([.control], .character("j")).rendered(notation)
        default:     return displayLabel
        }
    }

    /// Notation-independent label. Prefer `displayLabel(_:)` at UI call sites;
    /// this stays for the fixed labels and for tests.
    var displayLabel: String {
        switch self {
        case .esc:
            "esc"
        case .ctrlJ:
            "⌃J"
        case .ctrlC:
            "⌃C"
        // Control unifies on the Mac glyph rather than the terminal caret, so
        // one app has one notation. See docs/keyboard-interception-research.md.
        case .ctrl:
            "⌃"
        case .cmd:
            "⌘"
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
        case .ctrl, .alt, .shift, .cmd:
            true
        default:
            false
        }
    }

    /// VoiceOver reads the key by name, so these follow each language's own
    /// keyboard vocabulary. Chips without a spoken name fall back to the
    /// literal sequence they send.
    var accessibilityLabel: String {
        switch self {
        case .ctrl: String(localized: "Control")
        case .cmd: String(localized: "Command")
        case .alt: String(localized: "Option")
        case .shift: String(localized: "Shift")
        case .esc: String(localized: "Escape")
        case .ctrlJ: String(localized: "Control-J")
        case .ctrlC: String(localized: "Control-C")
        case .tab: String(localized: "Tab")
        case .left: String(localized: "Left arrow")
        case .down: String(localized: "Down arrow")
        case .up: String(localized: "Up arrow")
        case .right: String(localized: "Right arrow")
        case .pgup: String(localized: "Page up")
        case .pgdn: String(localized: "Page down")
        case .home: String(localized: "Home")
        case .end: String(localized: "End")
        case .pipe: String(localized: "Vertical bar")
        case .tilde: String(localized: "Tilde")
        case .slash: String(localized: "Slash")
        case .backslash: String(localized: "Backslash")
        case .dollar: String(localized: "Dollar sign")
        case .lbrace: String(localized: "Left brace")
        case .rbrace: String(localized: "Right brace")
        case .lbracket: String(localized: "Left bracket")
        case .rbracket: String(localized: "Right bracket")
        case .lt: String(localized: "Less-than sign")
        case .gt: String(localized: "Greater-than sign")
        // Function keys are printed the same on every keyboard.
        default: rawValue
        }
    }

    static var defaultBarOrder: [AccessoryChip] {
        defaultBarOrder(for: UIDevice.current.userInterfaceIdiom)
    }

    /// ⌘ is deliberately absent from both defaults even though it sits with the
    /// other modifiers in the palette. It is the one modifier chip that sends
    /// nothing to the remote — it arms Tessera's own shortcuts — so shipping it
    /// next to ⌃/⌥ by default would put two different kinds of key on one row
    /// of chips with nothing to tell them apart. Users who want app chords
    /// without a hardware keyboard add it from Settings → Keyboard.
    static func defaultBarOrder(for idiom: UIUserInterfaceIdiom) -> [AccessoryChip] {
        if idiom == .phone {
            return [.esc, .ctrl, .tab, .left, .right, .down, .up, .alt, .ctrlC, .ctrlJ]
        }
        return [.esc, .ctrl, .alt, .tab, .left, .down, .up, .right, .pipe, .tilde]
    }

    static func from(rawIDs: [String]) -> [AccessoryChip] {
        rawIDs.compactMap(AccessoryChip.init(rawValue:))
    }
}
