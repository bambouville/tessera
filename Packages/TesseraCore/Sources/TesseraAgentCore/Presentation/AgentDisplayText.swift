import Foundation

/// Display-only filtering. Never use this for routing identities or input bytes.
public enum AgentDisplayText {
    public static func sanitize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            let code = scalar.value
            return !(code < 32 && code != 9 && code != 10) && !(0x7f...0x9f).contains(code)
                && code != 0x061c && code != 0x200e && code != 0x200f
                && !(0x202a...0x202e).contains(code) && !(0x2066...0x2069).contains(code)
                && code != 0xfeff
        }))
    }
}
