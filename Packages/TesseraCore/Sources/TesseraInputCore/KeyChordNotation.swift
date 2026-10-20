// Packages/TesseraCore/Sources/TesseraInputCore/KeyChordNotation.swift
// Single authority for how a key chord is written anywhere in the app.
//
// Before this existed there were ten independent render sites, each with the
// glyphs welded into string literals ("⌘⇧E", Text("⌘\(number)"), a legend of
// hard-coded pairs). A user preference over that shape is impossible to keep
// honest, so every one of them now routes through `KeyChord.rendered(_:)`.
//
// Display only — nothing here reaches the wire. `AccessoryKeyCatalog` keys its
// byte sequences off the catalog ID, never off a display label, so a notation
// change cannot alter what a chip sends. `KeyChordNotationTests` (core) and
// `ModifierNotationTests` (Apple) both assert that separation.
//
// Apple spellings, kept as typealiases in `Tessera/Keyboard/ModifierNotation.swift`:
// `ModifierNotation`, `KeyToken`, `Chord`, `ChordPair`, `ChordDisplay`,
// `ChordRange`. The localized picker labels stay on the platform side because
// they need a bundle; everything here is pure text.

/// How modifier keys are written. Persisted on Apple platforms in
/// `AppearancePreferences.modifierNotation`.
public enum KeyChordNotation: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    /// `⌘⇧E` — Mac glyphs, concatenated.
    case glyph
    /// `cmd-shift-e` — short lowercase words, hyphen-joined (tmux/emacs house
    /// style, and it sits better with the app's lowercase voice than
    /// `Ctrl+Shift+E` would).
    case words

    public var id: String { rawValue }

    /// Separator between the parts of a chord. Glyph mode concatenates the way
    /// macOS menus do; words mode needs a visible joiner.
    public var joiner: String {
        switch self {
        case .glyph: return ""
        case .words: return "-"
        }
    }
}

/// One key in a chord — a modifier, a named key, or a literal character.
public enum KeyChordToken: Equatable, Hashable, Sendable {
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

    public func rendered(_ notation: KeyChordNotation) -> String {
        switch self {
        case .command: return notation == .glyph ? "⌘" : "cmd"
        case .option:  return notation == .glyph ? "⌥" : "opt"
        // Control unifies on the Mac glyph rather than the terminal caret —
        // including the ^C / ^J accessory chips, which render through
        // `KeyChord` as ⌃C / ctrl-c. A bar that writes ⌃ on one chip and ^ on
        // the next is describing the same key two ways.
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

    public var isModifier: Bool {
        switch self {
        case .command, .option, .control, .shift: return true
        default: return false
        }
    }

    /// The wire-modifier this token stands for, if any. Command is deliberately
    /// absent from the terminal side of `TerminalModifiers`, but it is still
    /// representable so app-shortcut adapters can round-trip a full chord.
    public var terminalModifier: TerminalModifier? {
        switch self {
        case .command: return .command
        case .option:  return .alternate
        case .control: return .control
        case .shift:   return .shift
        default:       return nil
        }
    }
}

// MARK: - Codable

/// Hand-written because `character(Character)` blocks synthesis, and because a
/// stable, readable tag is what gets written into a user's stored bindings —
/// a synthesized representation would be an implementation detail we could not
/// safely change later.
extension KeyChordToken: Codable {
    private enum Tag: String {
        case command, option, control, shift
        case tab, ret, del, esc, space
        case left, down, up, right
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
public struct KeyChord: Equatable, Hashable, Sendable {
    /// Apple's canonical order — ⌃⌥⇧⌘. iPadOS renders our `UIKeyCommand`s
    /// this way in the hold-⌘ shortcut HUD, so writing them any other way in
    /// the app disagrees with the OS about the same binding. See
    /// `ModifierNotationTests.testModifierOrderFollowsApplesCanonicalOrder`.
    public static let modifierOrder: [KeyChordToken] = [.control, .option, .shift, .command]

    public var modifiers: Set<KeyChordToken>
    public var key: KeyChordToken?

    public init(_ modifiers: Set<KeyChordToken> = [], _ key: KeyChordToken? = nil) {
        self.modifiers = modifiers.filter(\.isModifier)
        self.key = key
    }

    /// Convenience for the common letter case: `KeyChord.cmd("n")`.
    public static func cmd(_ c: Character) -> KeyChord { KeyChord([.command], .character(c)) }
    public static func cmdShift(_ c: Character) -> KeyChord {
        KeyChord([.command, .shift], .character(c))
    }

    public var tokens: [KeyChordToken] {
        var out = Self.modifierOrder.filter { modifiers.contains($0) }
        if let key { out.append(key) }
        return out
    }

    public func rendered(_ notation: KeyChordNotation) -> String {
        tokens.map { $0.rendered(notation) }.joined(separator: notation.joiner)
    }

    public var isEmpty: Bool { modifiers.isEmpty && key == nil }
}

/// Two chords shown as one entry ("previous / next"). Keeps the legend and the
/// cheat sheet from having to know how to join them per notation.
public struct KeyChordPair: Equatable, Hashable, Sendable {
    public var first: KeyChord
    public var second: KeyChord

    public init(first: KeyChord, second: KeyChord) {
        self.first = first
        self.second = second
    }

    public func rendered(_ notation: KeyChordNotation) -> String {
        "\(first.rendered(notation)) / \(second.rendered(notation))"
    }
}

/// An inclusive digit run: `⌘1 – ⌘9` in glyph mode, `cmd-1–9` in words mode
/// (repeating the modifier for every digit is unreadable once it's a word).
public struct KeyChordRange: Equatable, Hashable, Sendable {
    public var modifiers: Set<KeyChordToken>
    public var from: Character
    public var to: Character

    public init(modifiers: Set<KeyChordToken>, from: Character, to: Character) {
        self.modifiers = modifiers
        self.from = from
        self.to = to
    }

    /// - Parameter compact: drop the repeated modifier on the high end
    ///   (`⌘1–9`). Used where the run sits in a width-constrained grid; the
    ///   settings legend uses the full form.
    public func rendered(_ notation: KeyChordNotation, compact: Bool = false) -> String {
        let low = KeyChord(modifiers, .character(from))
        switch notation {
        case .glyph:
            if compact { return "\(low.rendered(notation))–\(to)" }
            let high = KeyChord(modifiers, .character(to))
            return "\(low.rendered(notation)) – \(high.rendered(notation))"
        case .words:
            // Repeating a word modifier on both ends is unreadable, so words
            // mode is always compact.
            return "\(low.rendered(notation))–\(to)"
        }
    }
}

/// Anything a shortcut list can show in its key column. Lets a table hold one
/// homogeneous row type instead of three, and keeps `literal` available for
/// entries that aren't chords at all (`↑↓`, `1–9`).
public enum KeyChordDisplay: Equatable, Hashable, Sendable {
    case one(KeyChord)
    case pair(KeyChordPair)
    case range(KeyChordRange)
    case literal(String)

    public func rendered(_ notation: KeyChordNotation) -> String {
        switch self {
        case .one(let c):     return c.rendered(notation)
        case .pair(let p):    return p.rendered(notation)
        case .range(let r):   return r.rendered(notation)
        case .literal(let s): return s
        }
    }
}
