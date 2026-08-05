// Tessera/SwipePad/MacroEncoder.swift
// Encode a swipe-pad macro spec string into raw bytes for the terminal.
//
// Spec language (case-sensitive; whitespace between tokens is stripped):
//   - "↵" or "\r"           → 0x0D
//   - "\n"                  → 0x0A
//   - "\t" or "tab"         → 0x09
//   - "shift-tab"            → ESC [ Z
//   - "esc" or "\e" or "\x1b" → 0x1B
//   - Any other UTF-8 character passes through as its byte representation.
//
// Examples:
//   "1↵"     → [0x31, 0x0D]
//   "y"      → [0x79]
//   "esc"    → [0x1B]
//   "3 ↵"    → [0x33, 0x0D]   (space stripped)
//   ""       → []             (unbound)
import Foundation

public enum MacroEncoder {
    public static func encode(_ spec: String) -> [UInt8] {
        var out: [UInt8] = []
        // Tokenizer walks left-to-right, trying multi-char escapes first
        // before falling through to single-character UTF-8.
        let scalars = Array(spec)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]

            // Whitespace separators (spaces) between tokens — skip but only
            // when we're between tokens; a space mid-literal stays because
            // the literal path below handles it.
            if c == " " {
                i += 1
                continue
            }

            // "↵" arrow glyph
            if c == "↵" {
                out.append(0x0D)
                i += 1
                continue
            }

            // Backslash escape sequences
            if c == "\\", i + 1 < scalars.count {
                let next = scalars[i + 1]
                switch next {
                case "r":
                    out.append(0x0D); i += 2; continue
                case "n":
                    out.append(0x0A); i += 2; continue
                case "t":
                    out.append(0x09); i += 2; continue
                case "e":
                    out.append(0x1B); i += 2; continue
                case "x":
                    // \xNN hex literal (2 hex digits expected)
                    if i + 3 < scalars.count,
                       let hi = scalars[i + 2].hexDigitValue,
                       let lo = scalars[i + 3].hexDigitValue
                    {
                        out.append(UInt8(hi * 16 + lo))
                        i += 4
                        continue
                    }
                    // Malformed — fall through to literal backslash.
                    out.append(0x5C); i += 1; continue
                default:
                    // Unknown escape — emit the literal backslash + next.
                    out.append(0x5C); i += 1; continue
                }
            }

            // Word-tokens "esc", "tab", and "shift-tab" (matched only at token boundaries,
            // i.e. preceded by start/space and followed by end/space/↵/\)
            if matchesWordToken("shift-tab", in: scalars, at: i) {
                out.append(contentsOf: [0x1B, 0x5B, 0x5A]); i += 9; continue
            }
            if matchesWordToken("esc", in: scalars, at: i) {
                out.append(0x1B); i += 3; continue
            }
            if matchesWordToken("tab", in: scalars, at: i) {
                out.append(0x09); i += 3; continue
            }

            // Literal UTF-8 character — write its bytes.
            for byte in String(c).utf8 { out.append(byte) }
            i += 1
        }
        return out
    }

    /// True iff `word` (lowercase) starts at `at` in `scalars` and the
    /// boundary after it is a token separator (end / space / "↵" / "\").
    private static func matchesWordToken(_ word: String, in scalars: [Character], at: Int) -> Bool {
        let wordChars = Array(word)
        let n = wordChars.count
        guard at + n <= scalars.count else { return false }
        for k in 0..<n {
            if scalars[at + k] != wordChars[k] { return false }
        }
        if at + n == scalars.count { return true }
        let after = scalars[at + n]
        return after == " " || after == "↵" || after == "\\"
    }
}
