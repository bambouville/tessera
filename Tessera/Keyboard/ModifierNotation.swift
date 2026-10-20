// Tessera/Keyboard/ModifierNotation.swift
// Apple spellings over the shared chord-notation authority in
// `TesseraInputCore/KeyChordNotation.swift`.
//
// The rendering rules — the vocabulary, Apple's canonical ⌃⌥⇧⌘ order, the
// minus-key/joiner collision, the compact range form — all live in the core
// type so the Android bar writes chords the same way. What stays here is the
// part that needs a bundle: the Settings picker's localized labels.
//
// Display only — nothing here reaches the wire. `AccessoryChipEncoder` keys its
// byte sequences off the `AccessoryChip` case (through
// `AccessoryKeyCatalog.encode(id:)`), never off a display label, so a notation
// change cannot alter what a chip sends. `ModifierNotationTests` asserts that
// separation.
import Foundation
import TesseraInputCore

/// How modifier keys are written. Persisted in
/// `AppearancePreferences.modifierNotation`.
typealias ModifierNotation = KeyChordNotation

/// One key in a chord — a modifier, a named key, or a literal character.
typealias KeyToken = KeyChordToken

/// A renderable key chord.
typealias Chord = KeyChord

/// Two chords shown as one entry ("previous / next").
typealias ChordPair = KeyChordPair

/// An inclusive digit run: `⌘1 – ⌘9` / `cmd-1–9`.
typealias ChordRange = KeyChordRange

/// Anything a shortcut list can show in its key column.
typealias ChordDisplay = KeyChordDisplay

extension ModifierNotation {
    /// The picker's two choices. The rendered chord tokens themselves stay
    /// English keyboard notation in every language — `cmd-shift-e` is how
    /// terminals and editors write it everywhere.
    var label: String {
        switch self {
        case .glyph: return String(localized: "glyphs")
        case .words: return String(localized: "words")
        }
    }
}
