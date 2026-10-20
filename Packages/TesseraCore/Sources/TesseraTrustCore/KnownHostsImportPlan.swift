import Foundation

/// What applying one reviewed `known_hosts` candidate would do to the local
/// pin store.
public enum KnownHostsImportAction: String, Codable, Equatable, Sendable {
    /// No pin exists for this endpoint yet.
    case add
    /// A pin exists and differs; applying rotates it, keeping the prior
    /// fingerprint as rotation history.
    case replace
    /// A pin exists with the same key; applying is a no-op.
    case unchanged
}

/// Why one `known_hosts` line — or one host token inside a comma-separated
/// host list on that line — cannot become a pin.
///
/// This is an enum, not a sentence: the platforms localize it. iOS renders the
/// English strings the Known Hosts import sheet has always shown.
public enum KnownHostsImportRejectionReason: Equatable, Sendable {
    /// Fewer than three whitespace-separated fields (host, key type, key).
    case missingFields
    /// An `@cert-authority` / `@revoked` (or any other `@`) marker line.
    ///
    /// Tessera's pin repository stores exact host pins. Reinterpreting a CA
    /// delegation or a revocation record as an ordinary pin would either widen
    /// trust to everything the CA signs or, worse, *grant* trust to a key the
    /// file exists to revoke. Payload is the marker token as written.
    case unsupportedMarker(String)
    /// The `"algorithm base64"` pair is not a public key this build accepts.
    case invalidPublicKey
    /// An empty token inside a comma-separated host list (`a,,b`).
    case emptyHostField
    /// A hashed host (`|1|salt|hash`). One-way by construction, so it cannot be
    /// mapped back onto a Tessera endpoint key.
    case hashedHost
    /// A pattern (`*`, `?`) or negation (`!host`). Tessera pins exact
    /// endpoints; a pattern pin would silently cover hosts the user never saw.
    case wildcardOrNegatedHost
    /// A `[host]:port` token whose brackets or separator are malformed.
    case invalidBracketedHostPort
    /// A `[host]:port` token with an empty host or a port outside `1...65535`.
    case invalidHostOrPort
    /// Defensive catch-all for a host token that failed to map for a reason the
    /// parser did not classify. Unreachable today — `parseEndpoint` only throws
    /// classified reasons — and kept so an unclassified failure surfaces as a
    /// rejected line rather than a silently dropped one.
    case invalidHostField
    /// Two or more lines supplied *different* keys for the same endpoint. Every
    /// contributing line is rejected: guessing which one the user meant is how
    /// a pin store silently accepts an attacker's key.
    case ambiguousEndpoint
    /// The host token parsed, but endpoint normalization rejected it — only
    /// reachable under `OpenSSHKnownHostsCodec.EndpointNormalization.normalized`.
    ///
    /// A token can survive `parseEndpoint` and still have no normalized form:
    /// `.` is a non-empty, unhashed, unpatterned token whose only character is
    /// the root label normalization strips, leaving nothing. Rejecting it names
    /// the offending token; silently keeping the unnormalized spelling would
    /// put one candidate in a different key space from every other, which is
    /// exactly the bug this mode exists to close.
    case unnormalizableHost
}

/// Non-fatal notes about a plan. Structured so platforms can localize.
public enum KnownHostsImportWarning: Equatable, Sendable {
    /// The same endpoint appeared more than once with the *same* key; only the
    /// first occurrence becomes a candidate.
    case duplicatePinIgnored(lineNumber: Int, endpointKey: String)
}

/// One endpoint the user could pin, with the action applying it would take.
public struct KnownHostsImportCandidate: Equatable, Sendable, Identifiable {
    /// 1-based line in the source text this candidate came from.
    public let lineNumber: Int
    public let endpoint: KnownHostEndpoint
    /// `endpoint.storageKey` — the key the local pin store is indexed by.
    public let endpointKey: String
    /// Canonical `"algorithm base64"` rendering of the key.
    public let keyString: String
    public let fingerprint: String
    public let action: KnownHostsImportAction
    /// Fingerprint the store held when the plan was built, or nil if the
    /// endpoint was unpinned. Apply-time must re-check this: a plan the user
    /// reviewed is a *proposal about a past state*, and the store can have
    /// moved underneath it (a background connection accepting a rotation, a
    /// second import). Applying an entry whose expectation no longer holds
    /// would silently overwrite a decision the user never saw.
    public let expectedPriorFingerprint: String?

    public var id: String { "\(lineNumber):\(endpointKey)" }

    public init(
        lineNumber: Int,
        endpoint: KnownHostEndpoint,
        keyString: String,
        fingerprint: String,
        action: KnownHostsImportAction,
        expectedPriorFingerprint: String?
    ) {
        self.lineNumber = lineNumber
        self.endpoint = endpoint
        self.endpointKey = endpoint.storageKey
        self.keyString = keyString
        self.fingerprint = fingerprint
        self.action = action
        self.expectedPriorFingerprint = expectedPriorFingerprint
    }
}

/// One line, or one host token, that did not survive parsing.
public struct KnownHostsImportRejection: Equatable, Sendable {
    /// 1-based line in the source text.
    public let lineNumber: Int
    /// The exact text blamed — the whole line for line-level failures, the
    /// single offending token for host-list failures.
    public let source: String
    public let reason: KnownHostsImportRejectionReason

    public init(lineNumber: Int, source: String, reason: KnownHostsImportRejectionReason) {
        self.lineNumber = lineNumber
        self.source = source
        self.reason = reason
    }
}

/// The complete, reviewable result of parsing a `known_hosts` file.
///
/// The plan is **built first and applied only on confirmation**. Nothing here
/// touches a pin store: a file with one malformed line still yields a full plan
/// describing the good lines and naming the bad one, and the store is untouched
/// until the user confirms. Parsing that mutated as it went would leave a half
/// -imported store behind on the first bad line — and would make "review before
/// you trust" a lie.
public struct KnownHostsImportPlan: Equatable, Sendable {
    public let candidates: [KnownHostsImportCandidate]
    public let rejections: [KnownHostsImportRejection]
    public let warnings: [KnownHostsImportWarning]

    public init(
        candidates: [KnownHostsImportCandidate],
        rejections: [KnownHostsImportRejection],
        warnings: [KnownHostsImportWarning]
    ) {
        self.candidates = candidates
        self.rejections = rejections
        self.warnings = warnings
    }

    public var addCount: Int { candidates.count { $0.action == .add } }
    public var replaceCount: Int { candidates.count { $0.action == .replace } }
    public var unchangedCount: Int { candidates.count { $0.action == .unchanged } }
    /// True when confirming the plan would change nothing.
    public var isNoOp: Bool { addCount + replaceCount == 0 }
}

/// Outcome of validating one `"algorithm base64"` key string.
public enum KnownHostsImportKeyValidation: Equatable, Sendable {
    /// Accepted, with the canonical rendering the plan should carry. Platforms
    /// that re-serialize the key through their SSH stack return that stack's
    /// canonical string here, so the pin stores exactly what it verified.
    case accepted(canonicalKeyString: String, fingerprint: String)
    case rejected
}

/// Injection point for platform key enrichment. Core supplies a structural
/// default (`OpenSSHKnownHostsCodec.structuralKeyValidation`); iOS supplies a
/// `NIOSSHPublicKey`-backed one so the import preview only ever shows keys the
/// SSH stack itself will accept.
public typealias KnownHostsImportKeyValidator =
    @Sendable (String) -> KnownHostsImportKeyValidation

/// One record to render into `known_hosts` text.
public struct KnownHostsExportRecord: Equatable, Sendable {
    /// Storage key (`"host:port"`).
    public let endpointKey: String
    /// Canonical `"algorithm base64"` rendering of the pinned key.
    public let keyString: String

    public init(endpointKey: String, keyString: String) {
        self.endpointKey = endpointKey
        self.keyString = keyString
    }
}
