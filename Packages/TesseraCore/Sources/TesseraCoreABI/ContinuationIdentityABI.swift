import Foundation
import TesseraProtocolCore

/// The continuation route identity: one implementation of "which route was
/// this?" for the recovery stores that must recognise a route across process
/// death without persisting a second plaintext copy of it.
///
/// The canonical rendering is one row per hop (jump hops in order, destination
/// last), each field written as `<utf8ByteCount>:<value>` and joined by NUL,
/// rows joined by `\n`, hashed with SHA-256 and encoded base64url unpadded.
/// Neither half of the identity carries the wire transport: the same route is
/// reachable over ssh and over mosh, and the sender and receiver of a
/// continuation choose independently, so a transport-bearing identity would
/// make one route look like two.
/// The length prefix counts UTF-8 **bytes**: the first Android implementation
/// counted UTF-16 code units, and byte counting is the deliberate portable
/// choice — nothing had shipped, and a stale pre-upgrade recovery record that
/// fails to match merely retires early.

/// ```json
/// {"endpoint":{"address":"example.com","hostID":"…","name":"prod",
///              "port":22,"transport":"ssh","user":"deploy"},
///  "via":[{…}]}
/// ```
/// `via` is the jump chain in order and may be omitted for a direct route.
public struct ContinuationRouteABIRequest: Codable, Equatable, Sendable {
    public var endpoint: ContinuationEndpointV1
    public var via: [ContinuationEndpointV1]?

    public init(endpoint: ContinuationEndpointV1, via: [ContinuationEndpointV1]? = nil) {
        self.endpoint = endpoint
        self.via = via
    }
}

/// `{"connectionKey":"…","fingerprint":"…","identity":"…#…"}`
///
/// `identity` is `routeKey#fingerprint` — the transport-free
/// `user@address:port[&via=…]` route key joined to the hop fingerprint — and is
/// what a recovery record stores. `connectionKey` is the WIRE key and keeps its
/// `transport:` prefix, because callers build descriptors from it; it is
/// therefore NOT the prefix of `identity`. The halves are returned separately
/// so a caller can index or display either without re-splitting the string.
public struct ContinuationRouteABIResponse: Codable, Equatable, Sendable {
    public var identity: String
    public var fingerprint: String
    public var connectionKey: String
}

/// Route identity for a typed endpoint plus its jump chain. Returns the byte
/// count under the string contract, or -1 for invalid arguments.
@_cdecl("tessera_continuation_route_identity")
public func tesseraContinuationRouteIdentity(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        ContinuationRouteABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 65_536
    ) else { return -1 }
    let via = request.via ?? []
    let identity = ContinuationRouteIdentity.identity(for: request.endpoint, via: via)
    let fingerprint = ContinuationRouteIdentity.fingerprint(for: request.endpoint, via: via)
    return SharedABI.copyOutJSON(
        ContinuationRouteABIResponse(
            identity: identity,
            fingerprint: fingerprint,
            connectionKey: ContinuationDescriptorV1.connectionKey(
                for: request.endpoint,
                via: via
            )
        ),
        outputBytes,
        outputCapacity
    )
}

/// Route identity derived from a received `ContinuationDescriptorV1`.
///
/// It must agree byte for byte with the origin-side derivation above for the
/// same route — that agreement is the whole point of routing both through one
/// implementation. Takes descriptor JSON and returns the identity string under
/// the string contract, or -1 for invalid arguments.
@_cdecl("tessera_continuation_descriptor_route_identity")
public func tesseraContinuationDescriptorRouteIdentity(
    descriptorBytes: UnsafePointer<UInt8>?,
    descriptorCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let descriptor = SharedABI.decode(
        ContinuationDescriptorV1.self,
        descriptorBytes,
        descriptorCount,
        maximum: 262_144
    ) else { return -1 }
    return SharedABI.copyOut(
        ContinuationRouteIdentity.identity(for: descriptor),
        outputBytes,
        outputCapacity
    )
}
