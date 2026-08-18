// Tessera/Keyboard/ModifierNotation.swift
// Single authority for how a key chord is written anywhere in the app.
//
// Before this existed there were ten independent render sites, each with the
// glyphs welded into string literals ("⌘⇧E", Text("⌘\(number)"), a legend of
// hard-coded pairs). A user preference over that shape is impossible to keep
// honest, so every one of them now routes through `Chord.rendered(_:)`.
//
// Display only — nothing here reaches the wire. `AccessoryChipEncoder` keys its
// byte sequences off the `AccessoryChip` case, never off a display label, so a
// notation change cannot alter what a chip sends. `ModifierNotationTests`
// asserts that separation.
import Foundation

/// How modifier keys are written. Persisted in
/// `AppearancePreferences.modifierNotation`.
enum ModifierNotation: String, CaseIterable, Identifiable {
    /// `⌘⇧E` — Mac glyphs, concatenated.
    case glyph
    /// `cmd-shift-e` — short lowercase words, hyphen-joined (tmux/emacs house
    /// style, and it sits better with the app's lowercase voice than
    /// `Ctrl+Shift+E` would).
    case words

    var id: String { rawValue }

    /// The picker's two choices. The rendered chord tokens themselves stay
    /// English keyboard notation in every language — `cmd-shift-e` is how
    /// terminals and editors write it everywhere.
    var label: String {
        switch self {
        case .glyph: return String(localized: "glyphs")
        case .words: return String(localized: "words")
        }
    }

    /// Separator between the parts of a chord. Glyph mode concatenates the way
    /// macOS menus do; words mode needs a visible joiner.
    var joiner: String {
        switch self {
        case .glyph: return ""
        case .words: return "-"
        }
    }
}

/// One key in a chord — a modifier, a named key, or a literal character.
enum KeyToken: Equatable, Hashable {
    case command
    case option
    case control
    case shift
    case tab
    case `return`
    case delete
    case escape
    case space
    case left, down, up, right
    /// A literal key: a letter, digit, or punctuation character.
    case character(Character)

    func rendered(_ notation: ModifierNotation) -> String {
        switch self {
        case .command: return notation == .glyph ? "⌘" : "cmd"
        case .option:  return notation == .glyph ? "⌥" : "opt"
        // Control unifies on the Mac glyph rather than the terminal caret —
        // including the ^C / ^J accessory chips, which render through `Chord`
        // as ⌃C / ctrl-c. A bar that writes ⌃ on one chip and ^ on the next is
        // describing the same key two ways.
        case .control: return notation == .glyph ? "⌃" : "ctrl"
        case .shift:   return notation == .glyph ? "⇧" : "shift"
        case .tab:     return notation == .glyph ? "⇥" : "tab"
        case .return:  return notation == .glyph ? "↩" : "ret"
        case .delete:  return notation == .glyph ? "⌫" : "del"
        case .escape:  return "esc"
        case .space:   return "space"
        // Arrows have no word form worth using — "opt-←" beats "opt-left".
        case .left:  return "←"
        case .down:  return "↓"
        case .up:    return "↑"
        case .right: return "→"
        case .character(let c):
            // The hyphen is also the words-mode joiner, so a chord on the minus
            // key would render "cmd--". Nothing shipped binds it, but the
            // recorder can produce one.
            if c == "-" { return notation == .glyph ? "-" : "minus" }
            // Glyph mode uppercases the way macOS menus do (⌘⇧E); words mode
            // keeps the app's lowercase voice (cmd-shift-e).
            return notation == .glyph ? String(c).uppercased() : String(c).lowercased()
        }
    }

    var isModifier: Bool {
        switch self {
        case .command, .option, .control, .shift: return true
        default: return false
        }
    }
}

// MARK: - Codable

/// Hand-written because `character(Character)` blocks synthesis, and because a
/// stable, readable tag is what gets written into a user's stored bindings —
/// a synthesized representation would be an implementation detail we could not
/// safely change later.
extension KeyToken: Codable {
    private enum Tag: String {
        case command, option, control, shift
        case tab, ret, del, esc, space
        case left, down, up, right
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("c:"), let c = raw.dropFirst(2).first {
            self = .character(c)
            return
        }
        switch Tag(rawValue: raw) {
        case .command: self = .command
        case .option:  self = .option
        case .control: self = .control
        case .shift:   self = .shift
        case .tab:     self = .tab
        case .ret:     self = .return
        case .del:     self = .delete
        case .esc:     self = .escape
        case .space:   self = .space
        case .left:    self = .left
        case .down:    self = .down
        case .up:      self = .up
        case .right:   self = .right
        case nil:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown key token \(raw)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw: String
        switch self {
        case .command: raw = Tag.command.rawValue
        case .option:  raw = Tag.option.rawValue
        case .control: raw = Tag.control.rawValue
        case .shift:   raw = Tag.shift.rawValue
        case .tab:     raw = Tag.tab.rawValue
        case .return:  raw = Tag.ret.rawValue
        case .delete:  raw = Tag.del.rawValue
        case .escape:  raw = Tag.esc.rawValue
        case .space:   raw = Tag.space.rawValue
        case .left:    raw = Tag.left.rawValue
        case .down:    raw = Tag.down.rawValue
        case .up:      raw = Tag.up.rawValue
        case .right:   raw = Tag.right.rawValue
        case .character(let c): raw = "c:\(c)"
        }
        try container.encode(raw)
    }
}

/// A renderable key chord. Modifiers are held separately from the base key so
/// the order is canonical no matter how a chord was built or recorded.
struct Chord: Equatable, Hashable {
    /// Apple's canonical order — ⌃⌥⇧⌘. iPadOS renders our `UIKeyCommand`s
    /// this way in the hold-⌘ shortcut HUD, so writing them any other way in
    /// the app disagrees with the OS about the same binding. See
    /// `ModifierNotationTests.testModifierOrderFollowsApplesCanonicalOrder`.
    static let modifierOrder: [KeyToken] = [.control, .option, .shift, .command]

    var modifiers: Set<KeyToken>
    var key: KeyToken?

    init(_ modifiers: Set<KeyToken> = [], _ key: KeyToken? = nil) {
        self.modifiers = modifiers.filter(\.isModifier)
        self.key = key
    }

    /// Convenience for the common letter case: `Chord.cmd("n")`.
    static func cmd(_ c: Character) -> Chord { Chord([.command], .character(c)) }
    static func cmdShift(_ c: Character) -> Chord { Chord([.command, .shift], .character(c)) }

    var tokens: [KeyToken] {
        var out = Self.modifierOrder.filter { modifiers.contains($0) }
        if let key { out.append(key) }
        return out
    }

    func rendered(_ notation: ModifierNotation) -> String {
        tokens.map { $0.rendered(notation) }.joined(separator: notation.joiner)
    }

    var isEmpty: Bool { modifiers.isEmpty && key == nil }
}

/// Two chords shown as one entry ("previous / next"). Keeps the legend and the
/// cheat sheet from having to know how to join them per notation.
struct ChordPair {
    var first: Chord
    var second: Chord

    func rendered(_ notation: ModifierNotation) -> String {
        "\(first.rendered(notation)) / \(second.rendered(notation))"
    }
}

/// Anything a shortcut list can show in its key column. Lets a table hold one
/// homogeneous row type instead of three, and keeps `literal` available for
/// entries that aren't chords at all (`↑↓`, `1–9`).
enum ChordDisplay {
    case one(Chord)
    case pair(ChordPair)
    case range(ChordRange)
    case literal(String)

    func rendered(_ notation: ModifierNotation) -> String {
        switch self {
        case .one(let c):    return c.rendered(notation)
        case .pair(let p):   return p.rendered(notation)
        case .range(let r):  return r.rendered(notation)
        case .literal(let s): return s
        }
    }
}

/// An inclusive digit run: `⌘1 – ⌘9` in glyph mode, `cmd-1–9` in words mode
/// (repeating the modifier for every digit is unreadable once it's a word).
struct ChordRange {
    var modifiers: Set<KeyToken>
    var from: Character
    var to: Character

    /// - Parameter compact: drop the repeated modifier on the high end
    ///   (`⌘1–9`). Used where the run sits in a width-constrained grid; the
    ///   settings legend uses the full form.
    func rendered(_ notation: ModifierNotation, compact: Bool = false) -> String {
        let low = Chord(modifiers, .character(from))
        switch notation {
        case .glyph:
            if compact { return "\(low.rendered(notation))–\(to)" }
            let high = Chord(modifiers, .character(to))
            return "\(low.rendered(notation)) – \(high.rendered(notation))"
        case .words:
            // Repeating a word modifier on both ends is unreadable, so words
            // mode is always compact.
            return "\(low.rendered(notation))–\(to)"
        }
    }
}
