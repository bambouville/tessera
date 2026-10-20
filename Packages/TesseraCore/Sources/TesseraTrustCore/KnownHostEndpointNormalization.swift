import Foundation

/// Errors raised while turning free-form host/port input into a
/// `KnownHostEndpoint`.
public enum KnownHostEndpointError: Error, Equatable, Sendable {
    case emptyHost
    case hostContainsWhitespace
    case portOutOfRange
}

extension KnownHostEndpoint {
    /// Stable storage key for a pinned endpoint: `"host:port"`.
    ///
    /// iOS `KnownHostsStore` keys its `known_hosts.json` records by this exact
    /// string (built as `"\(address):\(port)"` at connection time), and the
    /// Known Hosts page uses it as a row identity. It is deliberately NOT the
    /// OpenSSH rendered form — see `openSSHHostField` for that.
    public var storageKey: String { "\(host):\(port)" }

    /// Shared input normalization for a host/port pair.
    ///
    /// Android's `AndroidKnownHostsRepository.normalizeEndpoint` is canonical
    /// for the *host string*: trim surrounding whitespace, drop one trailing
    /// dot (the FQDN root label — `example.com.` and `example.com` are the same
    /// name), lowercase (DNS names are case-insensitive), reject empty or
    /// whitespace-bearing hosts, and require a port in `1...65535`.
    ///
    /// Only one trailing dot is stripped: `example.com..` is malformed input,
    /// not a name with two roots, and silently repairing it would let two
    /// different spellings collapse onto one pin.
    ///
    /// One matched pair of surrounding brackets is also removed, so an IPv6
    /// literal is stored bare (`::1`, not `[::1]`). Bracketing is a *rendering*
    /// convention that `openSSHHostField` reapplies where it is needed —
    /// keeping it in the stored host would produce `[[::1]]:2222` on export and
    /// would make `[::1]` and `::1` two different pins for one machine.
    ///
    /// Note for adopters: this is normalization of *input*, and which stores
    /// want it depends on how they key themselves. A store keyed by the address
    /// as the user typed it (iOS `KnownHostsStore`) must NOT have its imported
    /// host tokens rewritten, or an import lands on a second, shadow key for a
    /// host it already pins; a store that is itself keyed in this normalized
    /// space (Android's Room table) must have them rewritten, or its import
    /// plan is computed in a different key space from the store it writes to.
    /// `OpenSSHKnownHostsCodec.importPlan` takes an
    /// `EndpointNormalization` to say which, and defaults to `.verbatim`.
    public static func normalized(host: String, port: Int) throws -> KnownHostEndpoint {
        guard (1...65535).contains(port) else {
            throw KnownHostEndpointError.portOutOfRange
        }
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedHost.hasSuffix(".") {
            normalizedHost.removeLast()
        }
        if normalizedHost.count >= 2,
           normalizedHost.hasPrefix("["),
           normalizedHost.hasSuffix("]") {
            normalizedHost = String(normalizedHost.dropFirst().dropLast())
        }
        normalizedHost = normalizedHost.lowercased()
        guard !normalizedHost.isEmpty else {
            throw KnownHostEndpointError.emptyHost
        }
        guard normalizedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw KnownHostEndpointError.hostContainsWhitespace
        }
        return KnownHostEndpoint(host: normalizedHost, port: UInt16(port))
    }
}
