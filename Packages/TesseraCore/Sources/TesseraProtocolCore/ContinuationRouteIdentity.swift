import Crypto
import Foundation

/// One implementation of the continuation route fingerprint, shared by every
/// platform that needs to remember "which route was this?" without persisting
/// a second plaintext copy of the route.
///
/// The recovery stores that hold interrupted continuations must recognise a
/// route across process death, but their contents travel in diagnostics and
/// backups, so they store `routeKey#<fingerprint>` instead of repeating
/// user/address/port for every hop. The fingerprint below hashes a canonical
/// rendering of the full hop list (jump hops in order, destination last).
///
/// Canonical form:
///   routeKey  = `user@address:port` (+ `&via=<uuid>,<uuid>…` when the route
///               has jump hops), i.e. the wire `connectionKey` minus its
///               `transport:` prefix
///   fingerprint = one row per hop, rows joined by `\n`, where
///     fields = [uppercase host UUID, user, address, port]
///     each field rendered as `<utf8ByteCount>:<value>`, fields joined by NUL
///   hashed with SHA-256 and encoded base64url without padding
///   identity  = `routeKey#fingerprint`
///
/// **Why the wire transport is excluded from both halves.** The transport is
/// how a client talks to a host, not which route it is: the same host, the
/// same jump chain and the same tmux rendezvous are reachable over ssh and
/// over mosh, and the two sides of a continuation choose independently. The
/// identity is compared between the route derived from a RECEIVED descriptor
/// (carrying the sender's transport) and the route derived from the
/// RECEIVER's own saved host rows (carrying the receiver's transport), so
/// baking the transport in would make a mosh sender and an ssh receiver look
/// like two different routes and silently lose the continuation. A local
/// recovery record written before this change simply fails to match and
/// retires early — the same allowance the byte-length note below makes.
///
/// `ContinuationDescriptorV1.connectionKey` is unaffected: the wire key keeps
/// its `transport:` prefix, because the receiving side uses it to rebuild a
/// descriptor.
///
/// The length prefix counts UTF-8 BYTES. (The first Android implementation
/// counted UTF-16 code units; byte counting is the deliberate, portable choice
/// — the platforms had not shipped, and a local recovery record that fails to
/// match after upgrade merely retires early.)
public enum ContinuationRouteIdentity {
    /// The transport-free route key: `user@address:port[&via=UUID,…]`.
    public static func routeKey(
        for endpoint: ContinuationEndpointV1,
        via: [ContinuationEndpointV1]
    ) -> String {
        var key = "\(endpoint.user)@\(endpoint.address):\(endpoint.port)"
        if !via.isEmpty {
            key += "&via=" + via.map(\.hostID.uuidString).joined(separator: ",")
        }
        return key
    }

    /// `routeKey#fingerprint` for a typed endpoint + jump chain.
    public static func identity(
        for endpoint: ContinuationEndpointV1,
        via: [ContinuationEndpointV1]
    ) -> String {
        "\(routeKey(for: endpoint, via: via))#\(fingerprint(for: endpoint, via: via))"
    }

    public static func fingerprint(
        for endpoint: ContinuationEndpointV1,
        via: [ContinuationEndpointV1]
    ) -> String {
        fingerprint(hops: (via + [endpoint]).map(fields(for:)))
    }

    /// Identity derived from a received descriptor — must agree byte-for-byte
    /// with the origin-side derivation above for the same route. It is derived
    /// from the descriptor's endpoint and jump chain, NOT from its
    /// `connectionKey`, which still carries the sender's transport prefix.
    public static func identity(for descriptor: ContinuationDescriptorV1) -> String {
        identity(for: descriptor.endpoint, via: descriptor.via)
    }

    static func fields(for endpoint: ContinuationEndpointV1) -> [String] {
        [
            endpoint.hostID.uuidString,
            endpoint.user,
            endpoint.address,
            String(endpoint.port),
        ]
    }

    static func fingerprint(hops: [[String]]) -> String {
        let canonical = hops.map { fields in
            fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{0000}")
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return base64URLUnpadded(Data(digest))
    }

    private static func base64URLUnpadded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
