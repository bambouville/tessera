import Foundation
import TesseraDomainCore

/// {"type":"remoteLoopback","scheme":"http","port":8000,"pathAndQuery":"/x?y#z"}.
/// pathAndQuery includes the fragment, so the eventual browser can navigate
/// anchors. Fragments are excluded from tab/cache identity separately.
public enum ArtifactsLinkClass: Codable, Equatable, Sendable {
    case remoteLoopback(scheme: String, port: UInt16, pathAndQuery: String)
    case refused
    case external
    case unsupported

    private struct Wire: Codable {
        var type: String
        var scheme: String?
        var port: UInt16?
        var pathAndQuery: String?
    }

    public init(from decoder: Decoder) throws {
        let w = try Wire(from: decoder)
        switch w.type {
        case "refused": self = .refused
        case "external": self = .external
        case "unsupported": self = .unsupported
        case "remoteLoopback":
            guard let scheme = w.scheme, let port = w.port, let path = w.pathAndQuery,
                  ["http", "https"].contains(scheme), port > 0 else {
                throw ArtifactsCoding.invalid(decoder, "invalid loopback link")
            }
            self = .remoteLoopback(scheme: scheme, port: port, pathAndQuery: path)
        default: throw ArtifactsCoding.invalid(decoder, "unknown link type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        let w: Wire
        switch self {
        case let .remoteLoopback(scheme, port, path):
            w = Wire(type: "remoteLoopback", scheme: scheme, port: port, pathAndQuery: path)
        case .refused: w = Wire(type: "refused")
        case .external: w = Wire(type: "external")
        case .unsupported: w = Wire(type: "unsupported")
        }
        try w.encode(to: encoder)
    }
}

public enum ArtifactsLinkClassifier {
    public static func classify(_ urlString: String) -> ArtifactsLinkClass {
        guard let url = ArtifactsHTTPURL.parse(urlString) else {
            guard let host = ArtifactsHTTPURL.hostForClassification(urlString) else { return .unsupported }
            return isLinkLoopback(host) ? .refused : .external
        }
        return isLinkLoopback(url.host)
            ? .remoteLoopback(scheme: url.scheme, port: url.port, pathAndQuery: url.path)
            : .external
    }

    /// Rule targets are SSH destinations, which never get browser IDNA mapping.
    static func isRemoteLoopback(_ host: String) -> Bool {
        guard host.unicodeScalars.allSatisfy(\.isASCII), let host = canonicalHost(host) else { return false }
        return isCanonicalLoopback(host)
    }

    /// Browsers resolve every *.localhost name to loopback (RFC 6761), so a
    /// terminal link to one means the remote host, never this device.
    private static func isLinkLoopback(_ host: String) -> Bool {
        isCanonicalLoopback(host) || host.hasSuffix(".localhost")
    }

    private static func isCanonicalLoopback(_ host: String) -> Bool {
        if ["localhost", "0.0.0.0", "::", "::1"].contains(host) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIWholeNumber) && UInt8($0) != nil }) {
            return UInt8(octets[0]) == 127
        }
        if let words = ArtifactsHTTPURL.ipv6Words(host) {
            if words.dropLast().allSatisfy({ $0 == 0 }), words.last == 0 || words.last == 1 { return true }
            // IPv4-compatible and IPv4-mapped forms carry an IPv4 address
            // in their final 32 bits, in either dotted or hexadecimal form.
            if words.prefix(5).allSatisfy({ $0 == 0 }), words[5] == 0 || words[5] == 0xffff {
                return (words[6] == 0 && words[7] == 0) || words[6] >> 8 == 127
            }
        }
        return false
    }

    /// WHATWG's IPv4 number forms are browser addresses, not DNS names.
    /// A numeric final label commits to IPv4 parsing; failures are invalid.
    static func canonicalHost(_ input: String) -> String? {
        var host = mappedHost(input)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") { return ArtifactsHTTPURL.validIPv6(host) ? host : nil }
        if host.hasSuffix(".") { host.removeLast() }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = parts.last, !last.isEmpty else { return host }
        guard last.allSatisfy(\.isASCIIWholeNumber) || last.hasPrefix("0x") else { return host }
        guard parts.count <= 4 else { return nil }
        let numbers = parts.compactMap(ipv4Number)
        guard numbers.count == parts.count, numbers.dropLast().allSatisfy({ $0 <= 255 }),
              let final = numbers.last, final < (UInt64(1) << (8 * (5 - numbers.count))) else { return nil }
        var address = final
        for (index, number) in numbers.dropLast().enumerated() { address += number << (8 * (3 - index)) }
        return [24, 16, 8, 0].map { String((address >> $0) & 255) }.joined(separator: ".")
    }

    /// Map compatibility spellings and IDNA dot separators before either
    /// parser validates the hostname. Strip ignorables before normalization
    /// so they cannot block composition, and after it for mapped scalars.
    static func mappedHost(_ input: String) -> String {
        let scalars = input.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }
        let normalized = String(String.UnicodeScalarView(scalars)).precomposedStringWithCompatibilityMapping.lowercased()
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }))
            .replacingOccurrences(of: "\u{3002}", with: ".")
            .replacingOccurrences(of: "\u{ff0e}", with: ".")
            .replacingOccurrences(of: "\u{ff61}", with: ".")
    }

    private static func ipv4Number(_ input: Substring) -> UInt64? {
        guard !input.isEmpty else { return nil }
        var digits = input
        let radix: Int
        if digits.hasPrefix("0x") { radix = 16; digits = digits.dropFirst(2) }
        else if digits.count >= 2, digits.hasPrefix("0") { radix = 8; digits = digits.dropFirst() }
        else { radix = 10 }
        if digits.isEmpty { return 0 }
        guard digits.allSatisfy({ character in
            if radix == 16 { return character.isASCIIHexDigit }
            return character >= "0" && character <= (radix == 8 ? "7" : "9")
        }) else { return nil }
        return UInt64(digits, radix: radix)
    }
}

/// Parse authority explicitly: URLComponents' host bracket representation
/// differs across Foundation implementations. No userinfo, backslashes,
/// percent-encoded host or unbracketed IPv6 is accepted.
struct ArtifactsHTTPURL {
    var scheme: String
    var host: String
    var port: UInt16
    var path: String

    static func parse(_ input: String) -> ArtifactsHTTPURL? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = input.unicodeScalars
        guard !RemotePathGrammar.containsControlCharacter(input),
              !scalars.contains("\\"),
              let separator = scalars.firstIndex(of: ":") else { return nil }
        let scheme = String(scalars[..<separator]).lowercased()
        guard ["http", "https"].contains(scheme) else { return nil }
        let afterScheme = scalars[scalars.index(after: separator)...]
        guard afterScheme.starts(with: "//".unicodeScalars) else { return nil }
        // URL delimiters are scalars even when a following mark joins their
        // grapheme cluster. Keep those marks in the host or navigation text.
        let rest = afterScheme.dropFirst(2)
        let end = rest.firstIndex(where: { "/?#".unicodeScalars.contains($0) }) ?? rest.endIndex
        let authority = rest[..<end]
        guard !authority.isEmpty, !authority.contains("@"), !authority.contains("%") else { return nil }
        let host: String
        let portString: String?
        if authority.first == "[" {
            guard let bracket = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<bracket]).lowercased()
            guard validIPv6(host) else { return nil }
            let suffix = String(authority[authority.index(after: bracket)...])
            guard suffix.isEmpty || suffix.hasPrefix(":") else { return nil }
            portString = suffix.isEmpty ? nil : String(suffix.dropFirst())
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = ArtifactsLinkClassifier.mappedHost(String(parts[0]))
            guard !host.isEmpty, host.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0)
            }) else { return nil }
            portString = parts.count == 2 ? String(parts[1]) : nil
        }
        let port: UInt16
        if let portString {
            guard !portString.isEmpty, portString.allSatisfy(\.isASCIIWholeNumber),
                  let parsed = UInt16(portString), parsed > 0 else { return nil }
            port = parsed
        } else { port = scheme == "https" ? 443 : 80 }
        let tail = String(rest[end...])
        // U+200B counts as Foundation whitespace but is IDNA-ignored in a
        // hostname. Check navigation whitespace separately after host mapping.
        guard tail.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard let canonicalHost = ArtifactsLinkClassifier.canonicalHost(host) else { return nil }
        return .init(scheme: scheme, host: canonicalHost, port: port, path: rest[end...].first == "/" ? tail : "/" + tail)
    }

    /// Recognize the destination even when strict page parsing refuses the
    /// URL. Such local URLs must never fall through to the device browser.
    static func hostForClassification(_ input: String) -> String? {
        let boundaryWhitespace = CharacterSet(charactersIn: "\u{0000}"..."\u{0020}").union(.whitespacesAndNewlines)
        let input = input.trimmingCharacters(in: boundaryWhitespace)
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let scalars = input.unicodeScalars
        guard let separator = scalars.firstIndex(of: ":"),
              ["http", "https"].contains(String(scalars[..<separator]).lowercased()) else { return nil }
        // Special schemes ignore any leading run of slash or backslash.
        // This is destination detection only; strict page parsing stays strict.
        let rest = scalars[scalars.index(after: separator)...].drop { $0 == "/" || $0 == "\\" }
        let authority = rest.prefix { !"/?#\\".unicodeScalars.contains($0) }
        let destination = authority.split(separator: "@", omittingEmptySubsequences: false).last.map { String($0) } ?? ""
        let decoded = (destination.removingPercentEncoding ?? destination).unicodeScalars
        let hostAndPort = decoded.split(separator: "@", omittingEmptySubsequences: false).last ?? decoded[...]
        let host: String
        if hostAndPort.first == "[" {
            guard let bracket = hostAndPort.firstIndex(of: "]") else { return nil }
            host = String(hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<bracket])
            guard validIPv6(host.lowercased()) else { return nil }
        } else if hostAndPort.filter({ $0 == ":" }).count > 1 {
            host = String(hostAndPort)
            guard validIPv6(host.lowercased()) else { return nil }
        } else {
            host = ArtifactsLinkClassifier.mappedHost(String(hostAndPort.prefix { $0 != ":" }))
            // Browsers turn other IDN labels into punycode, so a name under
            // localhost stays local even when this allowlist cannot spell it.
            let local = host.hasSuffix(".localhost") || host.hasSuffix(".localhost.")
            guard !host.isEmpty, local || host.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0)
            }) else { return nil }
        }
        return ArtifactsLinkClassifier.canonicalHost(host)
    }

    static func validIPv6(_ host: String) -> Bool {
        ipv6Words(host) != nil
    }

    static func ipv6Words(_ host: String) -> [UInt16]? {
        guard host.contains(":"), !host.contains(":::") else { return nil }
        var source = host
        if source.contains(".") {
            guard let colon = source.lastIndex(of: ":") else { return nil }
            let octets = source[source.index(after: colon)...].split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4,
                  octets.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0")
                      && $0.allSatisfy(\.isASCIIWholeNumber) && UInt8($0) != nil }) else { return nil }
            let values = octets.compactMap { UInt16($0) }
            source = String(source[...colon]) + String(values[0] << 8 | values[1], radix: 16)
                + ":" + String(values[2] << 8 | values[3], radix: 16)
        }
        guard source.allSatisfy({ $0 == ":" || $0.isASCIIHexDigit }) else { return nil }
        func words(_ half: String) -> [UInt16]? {
            if half.isEmpty { return [] }
            let groups = half.split(separator: ":", omittingEmptySubsequences: false)
            guard groups.allSatisfy({ !$0.isEmpty && $0.count <= 4 }) else { return nil }
            let values = groups.compactMap { UInt16($0, radix: 16) }
            return values.count == groups.count ? values : nil
        }
        let halves = source.components(separatedBy: "::")
        guard halves.count <= 2, let head = words(halves[0]) else { return nil }
        if halves.count == 1 { return head.count == 8 ? head : nil }
        guard let tail = words(halves[1]), head.count + tail.count < 8 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }
}

private extension Character {
    var isASCIIWholeNumber: Bool { self >= "0" && self <= "9" }
    var isASCIIHexDigit: Bool { isASCIIWholeNumber || (self >= "a" && self <= "f") || (self >= "A" && self <= "F") }
}
