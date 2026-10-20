import Foundation
import TesseraTrustCore

/// The host-key trust seam: the verdict, endpoint normalization, the SHA-256
/// fingerprint, and the `known_hosts` import plan / export.
///
/// The import call returns a **plan**, never a mutation. A file with one
/// malformed line still yields a full plan describing the good lines and
/// naming the bad one, and the pin store is untouched until the user confirms.
/// A parser that mutated as it went is what left a half-imported store behind
/// on the first bad line — and made "review before you trust" a lie.

// MARK: - Verdict

/// One presented key, in the OpenSSH `"algorithm base64blob"` rendering.
public struct SSHHostPublicKeyABI: Codable, Equatable, Sendable {
    public var keyString: String

    public init(keyString: String) {
        self.keyString = keyString
    }

    /// Parsed with the padding the caller pins with, so a store that has
    /// persisted padded fingerprints since it shipped keeps comparing like
    /// with like.
    func core(padding: SSHHostPublicKey.FingerprintPadding) throws -> SSHHostPublicKey {
        try SSHHostPublicKey.parse(openSSHKeyString: keyString, fingerprintPadding: padding)
    }
}

/// ```json
/// {"comparisonHint":null,
///  "endpoint":{"host":"example.com","port":22},
///  "fingerprintPadding":"unpadded",
///  "presented":{"keyString":"ssh-ed25519 AAAA…"},
///  "previous":{"keyString":"ssh-ed25519 AAAA…"},
///  "trusted":{"key":{"keyString":"ssh-ed25519 AAAA…"},
///             "id":"…","trustedAtSeconds":1756000000}}
/// ```
///
/// `previous` is the key this endpoint was pinned to before the most recent
/// rotation, for a platform that keeps rotation history; supplying it turns a
/// "went back to the old key" event into `revertedToPrevious` instead of a
/// bare `changed`. With `previous` absent the result is byte-identical to the
/// pre-rotation-history behavior — which is what iOS passes today.
public struct KnownHostCheckABIRequest: Codable, Equatable, Sendable {
    public struct TrustedRecord: Codable, Equatable, Sendable {
        public var id: UUID?
        public var key: SSHHostPublicKeyABI
        public var trustedAtSeconds: TimeInterval

        public init(id: UUID? = nil, key: SSHHostPublicKeyABI, trustedAtSeconds: TimeInterval) {
            self.id = id
            self.key = key
            self.trustedAtSeconds = trustedAtSeconds
        }
    }

    public var endpoint: KnownHostEndpoint
    public var presented: SSHHostPublicKeyABI
    public var trusted: TrustedRecord?
    public var previous: SSHHostPublicKeyABI?
    public var comparisonHint: String?
    public var fingerprintPadding: SSHHostPublicKey.FingerprintPadding?

    public init(
        endpoint: KnownHostEndpoint,
        presented: SSHHostPublicKeyABI,
        trusted: TrustedRecord? = nil,
        previous: SSHHostPublicKeyABI? = nil,
        comparisonHint: String? = nil,
        fingerprintPadding: SSHHostPublicKey.FingerprintPadding? = nil
    ) {
        self.endpoint = endpoint
        self.presented = presented
        self.trusted = trusted
        self.previous = previous
        self.comparisonHint = comparisonHint
        self.fingerprintPadding = fingerprintPadding
    }
}

/// ```json
/// {"comparisonHint":null,"presentedFingerprint":"SHA256:…",
///  "trustedFingerprint":"SHA256:…","verdict":"revertedToPrevious"}
/// ```
///
/// `verdict` is `unknown` | `trusted` | `changed` | `revertedToPrevious`.
/// `revertedToPrevious` still blocks and still carries the *currently pinned*
/// key as `trustedFingerprint`, so a caller that does not care about the
/// distinction can treat it exactly like `changed` — but it is a materially
/// different story to tell the user than an unrecognised key, and collapsing
/// the two throws away the one piece of evidence that separates a botched
/// server rollback from an attacker.
public struct KnownHostCheckABIResponse: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case unknown, trusted, changed, revertedToPrevious
    }

    public var verdict: Verdict
    public var presentedFingerprint: String
    public var trustedFingerprint: String?
    public var comparisonHint: String?
}

/// Classifies a presented host key against the local pin. Returns the byte
/// count under the string contract, or -1 for invalid arguments (including an
/// unparseable key).
@_cdecl("tessera_trust_check")
public func tesseraTrustCheck(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        KnownHostCheckABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 262_144
    ) else { return -1 }
    let padding = request.fingerprintPadding ?? .unpadded
    guard let presented = try? request.presented.core(padding: padding) else { return -1 }

    var trustedRecord: TrustedHostRecord?
    if let trusted = request.trusted {
        guard let key = try? trusted.key.core(padding: padding) else { return -1 }
        trustedRecord = TrustedHostRecord(
            id: trusted.id ?? UUID(),
            endpoint: request.endpoint,
            key: key,
            trustedAt: Date(timeIntervalSince1970: trusted.trustedAtSeconds)
        )
    }
    var previousKey: SSHHostPublicKey?
    if let previous = request.previous {
        guard let key = try? previous.core(padding: padding) else { return -1 }
        previousKey = key
    }

    let result = KnownHostTrustPolicy.check(
        endpoint: request.endpoint,
        presented: presented,
        trusted: trustedRecord,
        previous: previousKey,
        comparisonHint: request.comparisonHint
    )
    let response: KnownHostCheckABIResponse
    switch result {
    case let .unknown(presented, hint):
        response = .init(
            verdict: .unknown,
            presentedFingerprint: presented.fingerprint,
            trustedFingerprint: nil,
            comparisonHint: hint
        )
    case let .trusted(record):
        response = .init(
            verdict: .trusted,
            presentedFingerprint: record.key.fingerprint,
            trustedFingerprint: record.key.fingerprint,
            comparisonHint: nil
        )
    case let .changed(change):
        response = .init(
            verdict: .changed,
            presentedFingerprint: change.presented.fingerprint,
            trustedFingerprint: change.trusted.fingerprint,
            comparisonHint: nil
        )
    case let .revertedToPrevious(change):
        response = .init(
            verdict: .revertedToPrevious,
            presentedFingerprint: change.presented.fingerprint,
            trustedFingerprint: change.trusted.fingerprint,
            comparisonHint: nil
        )
    }
    return SharedABI.copyOutJSON(response, outputBytes, outputCapacity)
}

// MARK: - Endpoint normalization

/// ```json
/// {"endpoint":{"host":"example.com","port":2222},"ok":true,
///  "openSSHHostField":"[example.com]:2222","storageKey":"example.com:2222"}
/// ```
/// or `{"error":"portOutOfRange","ok":false}` — `emptyHost` |
/// `hostContainsWhitespace` | `portOutOfRange`.
public struct KnownHostEndpointABIResponse: Codable, Equatable, Sendable {
    public enum Failure: String, Codable, Sendable {
        case emptyHost, hostContainsWhitespace, portOutOfRange
    }

    public var ok: Bool
    public var endpoint: KnownHostEndpoint?
    public var storageKey: String?
    public var openSSHHostField: String?
    public var error: Failure?
}

/// Normalizes free-form host/port input: trim, strip one trailing dot, strip
/// one matched bracket pair, lowercase, reject empty or whitespace-bearing
/// hosts, require a port in 1...65535.
///
/// Only one trailing dot is stripped: `example.com..` is malformed input, not
/// a name with two roots, and silently repairing it would let two spellings
/// collapse onto one pin. This is normalization of *input*; the import codec
/// applies it only when the caller asks for it, because a host token must land
/// on the same storage key the calling store is itself keyed by.
///
/// Returns the byte count under the string contract; a rejected input is a
/// successful call with `ok: false`.
@_cdecl("tessera_trust_normalize_endpoint")
public func tesseraTrustNormalizeEndpoint(
    hostBytes: UnsafePointer<UInt8>?,
    hostCount: Int,
    port: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let host = SharedABI.requiredString(hostBytes, hostCount, maximum: 4_096)
    else { return -1 }
    let response: KnownHostEndpointABIResponse
    do {
        let endpoint = try KnownHostEndpoint.normalized(host: host, port: Int(port))
        response = .init(
            ok: true,
            endpoint: endpoint,
            storageKey: endpoint.storageKey,
            openSSHHostField: endpoint.openSSHHostField,
            error: nil
        )
    } catch let error as KnownHostEndpointError {
        let failure: KnownHostEndpointABIResponse.Failure
        switch error {
        case .emptyHost: failure = .emptyHost
        case .hostContainsWhitespace: failure = .hostContainsWhitespace
        case .portOutOfRange: failure = .portOutOfRange
        }
        response = .init(
            ok: false,
            endpoint: nil,
            storageKey: nil,
            openSSHHostField: nil,
            error: failure
        )
    } catch {
        return -1
    }
    return SharedABI.copyOutJSON(response, outputBytes, outputCapacity)
}

// MARK: - Fingerprint

/// `"SHA256:" + base64(SHA-256(blob))` of an SSH wire-format public key blob.
///
/// `padded == 0` is the canonical cross-platform form (OpenSSH's own display,
/// and what Android renders). `padded == 1` exists for one caller: iOS's
/// `KnownHostsStore` has persisted padded fingerprints since it shipped and
/// compares the stored string against a freshly computed one, so switching it
/// silently would report a key MISMATCH on every already-pinned host.
///
/// Returns the byte count under the string contract, or -1 for invalid
/// arguments.
@_cdecl("tessera_trust_sha256_fingerprint")
public func tesseraTrustSHA256Fingerprint(
    blobBytes: UnsafePointer<UInt8>?,
    blobCount: Int,
    padded: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let blob = SharedABI.requiredData(
        blobBytes,
        blobCount,
        maximum: SSHHostPublicKey.maximumBlobBytes
    ) else { return -1 }
    return SharedABI.copyOut(
        SSHHostPublicKey.sha256Fingerprint(of: blob, padding: padded == 0 ? .unpadded : .padded),
        outputBytes,
        outputCapacity
    )
}

// MARK: - known_hosts import plan

/// ```json
/// {"endpointNormalization":"normalized",
///  "existingFingerprints":{"example.com:22":"SHA256:…"},
///  "fingerprintPadding":"unpadded",
///  "text":"example.com ssh-ed25519 AAAA…\n"}
/// ```
///
/// `endpointNormalization` is `verbatim` (the default when the field is
/// absent, and the codec's original behavior) or `normalized`. It picks the
/// ONE key space the plan is computed in: candidate keys, the
/// `existingFingerprints` lookup, ambiguity detection and duplicate warnings
/// all use it. A caller whose pin store is keyed by the address as the user
/// typed it wants `verbatim`; a caller whose store is keyed in the normalized
/// space (trim, one trailing dot, one bracket pair, lowercase) wants
/// `normalized` and MUST supply `existingFingerprints` keys in that same
/// space — mixing the two makes the plan lie about what applying it will do.
public struct KnownHostsImportPlanABIRequest: Codable, Equatable, Sendable {
    public var text: String
    public var existingFingerprints: [String: String]
    public var fingerprintPadding: SSHHostPublicKey.FingerprintPadding?
    public var endpointNormalization: OpenSSHKnownHostsCodec.EndpointNormalization?

    public init(
        text: String,
        existingFingerprints: [String: String],
        fingerprintPadding: SSHHostPublicKey.FingerprintPadding? = nil,
        endpointNormalization: OpenSSHKnownHostsCodec.EndpointNormalization? = nil
    ) {
        self.text = text
        self.existingFingerprints = existingFingerprints
        self.fingerprintPadding = fingerprintPadding
        self.endpointNormalization = endpointNormalization
    }
}

/// The reviewable plan.
///
/// ```json
/// {"addCount":2,"candidates":[…],"isNoOp":false,"rejections":[…],
///  "replaceCount":0,"unchangedCount":1,"warnings":[…]}
/// ```
///
/// A candidate's `expectedPriorFingerprint` is the fingerprint the store held
/// when the plan was built, and apply-time must re-check it: a plan the user
/// reviewed is a proposal about a past state, and the store can have moved
/// underneath it. Applying an entry whose expectation no longer holds would
/// silently overwrite a decision the user never saw.
public struct KnownHostsImportPlanABIResponse: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public var lineNumber: Int
        public var endpointKey: String
        public var host: String
        public var port: Int
        public var keyString: String
        public var fingerprint: String
        public var action: KnownHostsImportAction
        public var expectedPriorFingerprint: String?
    }

    /// `reason` is one of `missingFields`, `unsupportedMarker`,
    /// `invalidPublicKey`, `emptyHostField`, `hashedHost`,
    /// `wildcardOrNegatedHost`, `invalidBracketedHostPort`,
    /// `invalidHostOrPort`, `invalidHostField`, `ambiguousEndpoint`,
    /// `unnormalizableHost`.
    /// `marker` carries the offending token for `unsupportedMarker`.
    public struct Rejection: Codable, Equatable, Sendable {
        public var lineNumber: Int
        public var source: String
        public var reason: String
        public var marker: String?
    }

    public struct Warning: Codable, Equatable, Sendable {
        public var kind: String
        public var lineNumber: Int
        public var endpointKey: String
    }

    public var candidates: [Candidate]
    public var rejections: [Rejection]
    public var warnings: [Warning]
    public var addCount: Int
    public var replaceCount: Int
    public var unchangedCount: Int
    public var isNoOp: Bool
}

private func rejectionReasonName(
    _ reason: KnownHostsImportRejectionReason
) -> (name: String, marker: String?) {
    switch reason {
    case .missingFields: return ("missingFields", nil)
    case let .unsupportedMarker(marker): return ("unsupportedMarker", marker)
    case .invalidPublicKey: return ("invalidPublicKey", nil)
    case .emptyHostField: return ("emptyHostField", nil)
    case .hashedHost: return ("hashedHost", nil)
    case .wildcardOrNegatedHost: return ("wildcardOrNegatedHost", nil)
    case .invalidBracketedHostPort: return ("invalidBracketedHostPort", nil)
    case .invalidHostOrPort: return ("invalidHostOrPort", nil)
    case .invalidHostField: return ("invalidHostField", nil)
    case .ambiguousEndpoint: return ("ambiguousEndpoint", nil)
    case .unnormalizableHost: return ("unnormalizableHost", nil)
    }
}

/// Builds — and only builds — the import plan for a `known_hosts` file.
///
/// The request's `endpointNormalization` names the key space; absent it is
/// `verbatim`, which is byte-identical to this call's original behavior. A
/// caller must pass the mode that matches how its own pin store is keyed, and
/// hand `existingFingerprints` keys in that same space: a plan keyed
/// differently from the store misclassifies an existing pin as an `add` the
/// store then refuses, and cannot see that two spellings of one host are one
/// endpoint.
///
/// Key validation here is Core's structural check (algorithm token, canonical
/// base64, and the algorithm name inside the blob agreeing with the token).
/// Deep per-algorithm parsing stays a platform enrichment applied to the plan;
/// iOS runs `NIOSSHPublicKey` over the same strings before the preview.
///
/// Returns the byte count under the string contract, or -1 for invalid
/// arguments.
@_cdecl("tessera_trust_known_hosts_import_plan")
public func tesseraTrustKnownHostsImportPlan(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        KnownHostsImportPlanABIRequest.self,
        requestBytes,
        requestCount
    ) else { return -1 }
    let padding = request.fingerprintPadding ?? .unpadded
    let plan = OpenSSHKnownHostsCodec.importPlan(
        text: request.text,
        existingFingerprints: request.existingFingerprints,
        endpointNormalization: request.endpointNormalization ?? .verbatim,
        validateKey: { keyString in
            guard let key = try? SSHHostPublicKey.parse(
                openSSHKeyString: keyString,
                fingerprintPadding: padding
            ) else { return .rejected }
            return .accepted(
                canonicalKeyString: key.openSSHKeyString,
                fingerprint: key.fingerprint
            )
        }
    )
    return SharedABI.copyOutJSON(
        KnownHostsImportPlanABIResponse(
            candidates: plan.candidates.map { candidate in
                .init(
                    lineNumber: candidate.lineNumber,
                    endpointKey: candidate.endpointKey,
                    host: candidate.endpoint.host,
                    port: Int(candidate.endpoint.port),
                    keyString: candidate.keyString,
                    fingerprint: candidate.fingerprint,
                    action: candidate.action,
                    expectedPriorFingerprint: candidate.expectedPriorFingerprint
                )
            },
            rejections: plan.rejections.map { rejection in
                let classified = rejectionReasonName(rejection.reason)
                return .init(
                    lineNumber: rejection.lineNumber,
                    source: rejection.source,
                    reason: classified.name,
                    marker: classified.marker
                )
            },
            warnings: plan.warnings.map { warning in
                switch warning {
                case let .duplicatePinIgnored(lineNumber, endpointKey):
                    return .init(
                        kind: "duplicatePinIgnored",
                        lineNumber: lineNumber,
                        endpointKey: endpointKey
                    )
                }
            },
            addCount: plan.addCount,
            replaceCount: plan.replaceCount,
            unchangedCount: plan.unchangedCount,
            isNoOp: plan.isNoOp
        ),
        outputBytes,
        outputCapacity
    )
}

/// `[{"endpointKey":"example.com:22","keyString":"ssh-ed25519 AAAA…"}]`
public struct KnownHostsExportRecordABI: Codable, Equatable, Sendable {
    public var endpointKey: String
    public var keyString: String

    public init(endpointKey: String, keyString: String) {
        self.endpointKey = endpointKey
        self.keyString = keyString
    }
}

/// Renders stored pins as `known_hosts` text.
///
/// Lines are sorted so the output is stable across runs (the store is a
/// dictionary) and diffable. A pin at the default port writes a bare host, not
/// `[host]:22`, because that is what `ssh(1)` writes — otherwise a user's real
/// `known_hosts` and ours would disagree about the same host.
///
/// Returns the byte count under the string contract, or -1 for invalid
/// arguments. An empty record list yields 0 bytes, which is the correct empty
/// file.
@_cdecl("tessera_trust_known_hosts_export")
public func tesseraTrustKnownHostsExport(
    recordsBytes: UnsafePointer<UInt8>?,
    recordsCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let records = SharedABI.decode(
        [KnownHostsExportRecordABI].self,
        recordsBytes,
        recordsCount
    ) else { return -1 }
    return SharedABI.copyOut(
        OpenSSHKnownHostsCodec.exportText(
            records: records.map {
                KnownHostsExportRecord(endpointKey: $0.endpointKey, keyString: $0.keyString)
            }
        ),
        outputBytes,
        outputCapacity
    )
}
