import Foundation
import Network

/// Cross-version compatibility contract for nearby bootstrap.
///
/// This file is the canonical statement of the invariants every FUTURE wire
/// revision must honor. `docs/nearby-bootstrap-compatibility.md` points here,
/// and `docs/schemas/nearby-bootstrap/` freezes one schema folder per shipped
/// protocol version (pinned by `BootstrapWireSchemaTests`).
///
/// 1. `version` is an integer key, never renamed, always present at the top
///    level of the commitment, the hello, and the manifest root. Receivers
///    probe it leniently (`NearbyVersionProbe`) before any strict or full
///    decode, so a reshaped future message still reports a clean version
///    mismatch instead of a raw decoding error.
/// 2. There is no in-band negotiation. A sender fixes its wire version before
///    its first byte: a future recipient chooses from the origin's TXT `v`
///    list (missing TXT means a legacy v2 build); a future origin chooses
///    from the received commitment's `version`/`supportedVersions`. Both
///    inputs are cleartext and rewritable by an on-path attacker — point 3
///    is what makes the resulting choice tamper-evident.
/// 3. The transcript must bind the version in use (v2 mixes it into
///    `makeTranscript`), and never accept a version outside the local
///    supported set. Binding the chosen version alone CANNOT detect a
///    forced downgrade: if both peers support {v2, v3} and an attacker
///    strips `3` from the TXT `v` list and the commitment's
///    `supportedVersions`, both sides compute a self-consistent v2
///    transcript and the SAS still matches. Therefore the first protocol
///    version that widens `supportedVersions` beyond one entry MUST fold
///    the raw negotiation inputs into its transcript (and hence the SAS):
///    the exact commitment bytes as received on the wire, and — on the
///    side that browsed — the TXT `v` value it acted on. Tampering with
///    either input then desynchronizes the SAS. The frozen v2 transcript
///    ships without this only because v2 accepts exactly v2, so there is
///    no version choice for an attacker to influence.
/// 4. The v2 commitment digest projection is exactly
///    `{version, role, ephemeralPublicKey}`. Any new v2 hello field stays out
///    of it; a future version defines its own projection under a new label.
/// 5. `appVersion` and `supportedVersions` are unauthenticated advisory
///    hints: sanitize before display and never use them as trust,
///    negotiation-integrity, or key-derivation inputs. (Folding their raw
///    encoded bytes into a future transcript per point 3 is not a use of
///    their values — it is exactly the integrity binding that their
///    unauthenticated status requires.)
/// 6. The manifest schema allowlist stays strict for the current version, and
///    the version check runs before the allowlist check.
/// 7. The TXT record is cleartext LAN broadcast: protocol integers only,
///    never the app marketing version.
/// 8. The `TBCH` frame's u8 version bumps only together with the protocol
///    version; `_tessera-bootstrap._tcp` changes only as a deliberate epoch
///    break that makes old and new builds mutually invisible.
/// 9. Every shipped protocol version keeps a frozen schema folder under
///    `docs/schemas/nearby-bootstrap/vN/`. A wire change requires bumping
///    `NearbyBootstrapProtocol.version`, adding `v(N+1)/`, and leaving `vN/`
///    untouched as the record a future downgrade path is written against.
/// 10. Size envelopes are part of the contract because they are enforced
///    before the version probe runs: a future commitment/hello must fit
///    `maximumHandshakeMessageSize` (4096 bytes) on shipped builds, encrypted
///    frames are read with a 65536-byte cap, and the manifest with
///    `BootstrapManifest.maximumEncodedByteCount` plus framing headroom.
public enum NearbyBootstrapProtocol {
    /// End-to-end version of the whole nearby-bootstrap flow: handshake
    /// messages, encrypted-channel framing, and manifest schema bump together.
    public static let version = 2

    /// Ascending versions this build can complete a transfer with. v2 code
    /// accepts exactly v2; a future build widens this only after it implements
    /// an explicit compatibility path for each listed version.
    public static let supportedVersions: [Int] = [2]

    /// Receive cap applied to the length prefix of the cleartext handshake
    /// messages (commitment and hello) BEFORE the version probe can run. A
    /// future version's first messages must fit this envelope on already
    /// shipped builds or the clean version error is unreachable.
    public static let maximumHandshakeMessageSize = 4_096
}

/// Sanitized, advisory-only description of a peer's version claims. The raw
/// values arrive in cleartext from an unauthenticated peer, so free-text is
/// cleaned at construction and list sizes are capped before anything can
/// reach UI or logs.
public struct NearbyPeerVersionInfo: Equatable, Sendable {
    public let version: Int
    public let appVersion: String?
    public let supportedVersions: [Int]?

    public init(version: Int, appVersion: String?, supportedVersions: [Int]?) {
        self.version = version
        let cleaned = appVersion.map(Self.sanitizedAppVersion)
        self.appVersion = (cleaned?.isEmpty ?? true) ? nil : cleaned
        self.supportedVersions = supportedVersions.map { Array($0.prefix(8)) }
    }

    private static let allowedAppVersionScalars = CharacterSet(
        charactersIn: "0123456789abcdefghijklmnopqrstuvwxyz"
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ.+-"
    )

    /// Marketing versions are `[0-9A-Za-z.+-]` by construction, so restrict
    /// to that class and cap by scalar count. `String.prefix` would count
    /// grapheme clusters, which are unbounded in bytes — a hostile peer could
    /// pack the whole handshake message budget into a few clusters of
    /// combining marks, and bidi scalars could reorder the failure sentence
    /// this value gets interpolated into.
    private static func sanitizedAppVersion(_ rawValue: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in rawValue.unicodeScalars
        where allowedAppVersionScalars.contains(scalar) {
            scalars.append(scalar)
            if scalars.count == 32 { break }
        }
        return String(scalars)
    }
}

/// Which wire message carried an incompatible version, for distinct error
/// wording between the commitment (first message) and hello legs.
public enum NearbyVersionedMessageKind: String, Equatable, Sendable {
    case commitment
    case hello
}

/// Lenient version-first probe run before every strict or full decode of a
/// versioned wire message. It never throws: `nil` means the payload is not a
/// JSON object carrying an integer `version`, in which case callers fall
/// through to their existing structural errors. Contract: the `version` key
/// name and integer type never change in any future protocol revision.
enum NearbyVersionProbe {
    static func probe(_ data: Data) -> NearbyPeerVersionInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versionNumber = object["version"] as? NSNumber,
              CFGetTypeID(versionNumber) != CFBooleanGetTypeID(),
              let version = versionNumber as? Int
        else { return nil }
        let appVersion = object["appVersion"] as? String
        let supported = (object["supportedVersions"] as? [Any])?.compactMap { $0 as? Int }
        return NearbyPeerVersionInfo(
            version: version,
            appVersion: appVersion,
            supportedVersions: supported
        )
    }
}

/// Pre-connect compatibility verdict for a browsed peer, derived from its
/// Bonjour TXT record. Strictly advisory badge data: the TXT record is
/// unauthenticated cleartext an on-LAN attacker can forge, so it must never
/// gate connection — every peer stays tappable and the handshake's version
/// check remains the authoritative refusal.
public enum NearbyPeerCompatibility: Equatable, Hashable, Sendable {
    case unknown
    case compatible
    case peerRequiresUpdate
    case localRequiresUpdate

    /// Badge-only signal for the peer list; never a connection gate.
    public var indicatesVersionMismatch: Bool {
        switch self {
        case .unknown, .compatible: return false
        case .peerRequiresUpdate, .localRequiresUpdate: return true
        }
    }
}

/// Bonjour TXT contract: a single key `v` holding comma-separated ascending
/// supported protocol versions ("2"). Cleartext on the LAN, so it carries
/// protocol integers only — deliberately never the app marketing version.
struct NearbyCompatibilityAdvertisement: Equatable {
    static let versionKey = "v"
    private static let maximumVersionCount = 8

    let supportedVersions: [Int]

    static var current: NearbyCompatibilityAdvertisement {
        NearbyCompatibilityAdvertisement(
            supportedVersions: NearbyBootstrapProtocol.supportedVersions
        )
    }

    init(supportedVersions: [Int]) {
        self.supportedVersions = supportedVersions.sorted()
    }

    init?(txtRecord: NWTXTRecord) {
        guard case .string(let value)? = txtRecord.getEntry(for: Self.versionKey) else {
            return nil
        }
        let versions = value.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard !versions.isEmpty, versions.count <= Self.maximumVersionCount else {
            return nil
        }
        self.supportedVersions = versions.sorted()
    }

    var txtRecord: NWTXTRecord {
        NWTXTRecord([
            Self.versionKey: supportedVersions.map(String.init).joined(separator: ",")
        ])
    }

    func compatibility(withLocal local: [Int]) -> NearbyPeerCompatibility {
        guard Set(supportedVersions).intersection(local).isEmpty else {
            return .compatible
        }
        guard let peerMax = supportedVersions.max(), let localMax = local.max() else {
            return .unknown
        }
        return peerMax > localMax ? .localRequiresUpdate : .peerRequiresUpdate
    }
}
