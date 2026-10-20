/// Printable evidence for a device log.
///
/// A control-mode reply that fails to parse is only diagnosable from its
/// bytes: whether the separators are tabs, spaces, or gone, whether the body
/// is the row that was asked for or someone else's reply. Diagnostic sinks on
/// both platforms strip control characters, so the evidence is escaped before
/// it leaves the core, and bounded so a capture body cannot rotate the log.
public enum TmuxWireEvidence {
    /// `text` with separators and control bytes escaped, cut at `limit`
    /// characters with a trailing ellipsis.
    public static func snippet(_ text: String, limit: Int) -> String {
        var out = ""
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit {
                out += "…"
                break
            }
            count += 1
            switch scalar {
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            case "\u{1b}": out += "\\e"
            case "\\": out += "\\\\"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\x" + (hex.count < 2 ? "0" + hex : hex)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
