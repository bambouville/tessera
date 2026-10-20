import Foundation
import Crypto
import NIOSSH
import NIOCore
import TesseraTrustCore

/// Persistent trust store for SSH host keys. Implements TOFU
/// (trust on first use): first connection to a new host prompts;
/// subsequent connections verify silently; key changes block with
/// a warning.
///
/// Storage: JSON file at `Application Support/known_hosts.json`,
/// keyed by resolved `address:port` (not user-facing alias).
/// Fingerprints are `base64(SHA256(wire-format key blob))`,
/// matching OpenSSH's default `FingerprintHash sha256`.
actor KnownHostsStore {
    static let shared = KnownHostsStore()

    struct TrustedRecordSnapshot: Codable, Equatable, Sendable {
        let fingerprint: String
        let keyString: String
        let firstSeen: Date
        let lastSeen: Date
    }

    enum ImportResult: Equatable, Sendable {
        case inserted
        case unchanged
        case conflict
    }

    enum ImportError: Error, Equatable {
        case invalidKey
        case fingerprintMismatch
        case invalidDates
    }

    struct OpenSSHImportSummary: Equatable, Sendable {
        let added: Int
        let replaced: Int
        let unchanged: Int
        let stalePlanConflicts: Int
    }

    /// Days since `lastSeen` after which a known host is reported as
    /// `stale` on the Known Hosts page. 90 days mirrors a common SSH
    /// host-key rotation cadence — long enough that occasional reuse
    /// stays "ok", short enough that genuinely abandoned hosts age out.
    static let staleThresholdDays: Int = 90

    enum HostStatus: String, Sendable {
        case ok
        case stale
        case changed
    }

    struct HostRecord: Codable {
        var fingerprint: String
        var keyString: String       // "ssh-ed25519 AAAA..." for display
        var firstSeen: Date
        var lastSeen: Date
        /// Set whenever `check()` sees a key whose fingerprint differs
        /// from the trusted one; cleared on `trust()` or `remove()`.
        /// Drives the persistent "MISMATCH" badge on the Known Hosts
        /// page even after the user dismisses the verification sheet
        /// without deciding.
        var pendingFingerprint: String? = nil
        var pendingKeyString: String? = nil
        /// Set on `trust()` when overwriting a different prior
        /// fingerprint. Surfaces the "previous fingerprint:" line in
        /// the Known Hosts page detail row.
        var previousFingerprint: String? = nil
        /// Display-only audit note written when the user explicitly trusted a
        /// key that matched a continuation peer's fingerprint. It does not
        /// participate in future validation and is never a shared trust pin.
        var matchedPeerLabel: String? = nil
    }

    /// Read-only display row for the Known Hosts page. Computed at
    /// read time from `HostRecord` so we never persist a stale
    /// status string.
    struct DisplayRow: Identifiable, Sendable, Hashable {
        public let id: String          // endpoint (record key)
        public let host: String        // "address" with default :22 stripped
        public let algorithm: String   // "ed25519" / "rsa" / "ecdsa"
        public let fingerprint: String
        public let previousFingerprint: String?
        public let pendingFingerprint: String?
        public let pendingKeyString: String?
        public let firstSeen: Date
        public let lastSeen: Date
        public let status: HostStatus
        public let matchedPeerLabel: String?
    }

    enum VerificationResult {
        case trusted
        case unknown(fingerprint: String, keyString: String)
        case changed(oldFingerprint: String, newFingerprint: String, keyString: String)
    }

    private var records: [String: HostRecord] = [:]
    private let fileURL: URL
    private let nowProvider: @Sendable () -> Date

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("known_hosts.json")
        self.nowProvider = Date.init
        loadFromDisk()
    }

    /// Test-only initializer: lets tests inject a temporary file URL
    /// and a frozen clock without disturbing the singleton.
    init(fileURL: URL, now: @Sendable @escaping () -> Date) {
        self.fileURL = fileURL
        self.nowProvider = now
        loadFromDisk()
    }

    /// Check whether a host key is trusted.
    ///
    /// Side effects:
    ///  - on `.trusted` with a previously-pending change recorded,
    ///    the pending state is cleared (the host has reverted).
    ///  - on `.changed`, the new fingerprint is stored as the record's
    ///    `pendingFingerprint` so the Known Hosts page can flag the
    ///    mismatch persistently.
    func check(_ key: NIOSSHPublicKey, for endpoint: String) -> VerificationResult {
        let fingerprint = Self.fingerprint(of: key)
        let keyString = String(openSSHPublicKey: key)
        guard let presented = try? Self.sharedKey(
            keyString: keyString,
            fingerprint: fingerprint
        ) else {
            return .changed(
                oldFingerprint: records[endpoint]?.fingerprint ?? "invalid",
                newFingerprint: fingerprint,
                keyString: keyString
            )
        }
        let trusted = records[endpoint].flatMap {
            Self.sharedRecord(endpoint: endpoint, record: $0)
        }

        switch KnownHostTrustPolicy.check(
            endpoint: KnownHostEndpoint(host: endpoint),
            presented: presented,
            trusted: trusted
        ) {
        case .unknown:
            return .unknown(fingerprint: fingerprint, keyString: keyString)
        case .trusted:
            guard var record = records[endpoint] else {
                return .unknown(fingerprint: fingerprint, keyString: keyString)
            }
            if record.pendingFingerprint != nil || record.pendingKeyString != nil {
                record.pendingFingerprint = nil
                record.pendingKeyString = nil
                records[endpoint] = record
                saveToDisk()
            }
            return .trusted
        // `.revertedToPrevious` is unreachable here: this call passes no
        // `previous` key (iOS keeps rotation history for display only, and has
        // never treated "went back to the key you replaced" as anything other
        // than a mismatch). Handling it alongside `.changed` keeps that
        // conservative reading if the parameter is ever wired up.
        case .changed, .revertedToPrevious:
            guard var record = records[endpoint] else {
                return .unknown(fingerprint: fingerprint, keyString: keyString)
            }
            record.pendingFingerprint = fingerprint
            record.pendingKeyString = keyString
            records[endpoint] = record
            saveToDisk()
            return .changed(
                oldFingerprint: record.fingerprint,
                newFingerprint: fingerprint,
                keyString: keyString
            )
        }
    }

    /// Trust a host key (first-time accept or override after change).
    /// On override, the previous fingerprint is preserved on the
    /// record under `previousFingerprint` so the page detail row can
    /// show the rotation history.
    func trust(
        _ key: NIOSSHPublicKey,
        for endpoint: String,
        matchedPeerLabel: String? = nil
    ) {
        let fingerprint = Self.fingerprint(of: key)
        let keyString = String(openSSHPublicKey: key)
        let now = nowProvider()
        let existing = records[endpoint]
        let firstSeen = existing?.firstSeen ?? now
        let priorFingerprint: String? = {
            guard let existing else { return nil }
            // Trusting the same key again preserves whatever rotation
            // history the record already had. Trusting a different key
            // captures the just-replaced fingerprint as "previous".
            return existing.fingerprint == fingerprint
                ? existing.previousFingerprint
                : existing.fingerprint
        }()
        records[endpoint] = HostRecord(
            fingerprint: fingerprint,
            keyString: keyString,
            firstSeen: firstSeen,
            lastSeen: now,
            pendingFingerprint: nil,
            pendingKeyString: nil,
            previousFingerprint: priorFingerprint,
            matchedPeerLabel: matchedPeerLabel
        )
        saveToDisk()
    }

    /// Update the last-seen date for a trusted key.
    func touch(for endpoint: String) {
        records[endpoint]?.lastSeen = nowProvider()
        saveToDisk()
    }

    /// Remove a record entirely. Used by the Known Hosts page
    /// "remove" action.
    func remove(endpoint: String) {
        records.removeValue(forKey: endpoint)
        saveToDisk()
    }

    /// Public comparison material for a continuation descriptor. Callers must
    /// treat this as a hint for explicit TOFU on the peer, never as a pin to
    /// import there.
    func trustedFingerprint(for endpoint: String) -> String? {
        records[endpoint]?.fingerprint
    }

    /// Exact public trust material for an explicitly authorized nearby
    /// bootstrap. Unlike continuation fingerprints, this snapshot is suitable
    /// for importing as a pin because the encrypted bootstrap flow performs a
    /// fresh device-owner authorization before releasing its manifest.
    func trustedRecord(for endpoint: String) -> TrustedRecordSnapshot? {
        records[endpoint].map {
            TrustedRecordSnapshot(
                fingerprint: $0.fingerprint,
                keyString: $0.keyString,
                firstSeen: $0.firstSeen,
                lastSeen: $0.lastSeen
            )
        }
    }

    /// Imports an owner-authorized nearby trust pin without weakening a local
    /// decision. An identical local pin is idempotently skipped; a different
    /// local pin wins and is reported as a conflict rather than overwritten.
    func importTrustedRecord(
        _ snapshot: TrustedRecordSnapshot,
        for endpoint: String,
        fromPeer peerDeviceName: String
    ) throws -> ImportResult {
        guard snapshot.firstSeen <= snapshot.lastSeen else {
            throw ImportError.invalidDates
        }
        let key: NIOSSHPublicKey
        do {
            key = try NIOSSHPublicKey(openSSHPublicKey: snapshot.keyString)
        } catch {
            throw ImportError.invalidKey
        }
        guard Self.fingerprint(of: key) == snapshot.fingerprint else {
            throw ImportError.fingerprintMismatch
        }
        guard let importedKey = try? Self.sharedKey(
            keyString: String(openSSHPublicKey: key),
            fingerprint: snapshot.fingerprint
        ) else { throw ImportError.invalidKey }
        let imported = TrustedHostRecord(
            endpoint: KnownHostEndpoint(host: endpoint),
            key: importedKey,
            trustedAt: snapshot.firstSeen
        )
        let local = records[endpoint].flatMap {
            Self.sharedRecord(endpoint: endpoint, record: $0)
        }

        switch KnownHostTrustPolicy.importRecord(imported, local: local) {
        case .unchanged:
            return .unchanged
        case .conflict:
            guard var existing = records[endpoint] else {
                throw ImportError.invalidKey
            }
            // Keep the local trust decision authoritative, but retain the
            // peer-reported key as a pending mismatch so Known Hosts can show
            // both fingerprints and offer the existing explicit review flow.
            existing.pendingFingerprint = snapshot.fingerprint
            existing.pendingKeyString = String(openSSHPublicKey: key)
            records[endpoint] = existing
            saveToDisk()
            return .conflict
        case .inserted:
            records[endpoint] = HostRecord(
                fingerprint: snapshot.fingerprint,
                keyString: String(openSSHPublicKey: key),
                firstSeen: snapshot.firstSeen,
                lastSeen: snapshot.lastSeen,
                pendingFingerprint: nil,
                pendingKeyString: nil,
                previousFingerprint: nil,
                matchedPeerLabel: "Imported from \(peerDeviceName)"
            )
            saveToDisk()
            return .inserted
        }
    }

    private static func sharedKey(
        keyString: String,
        fingerprint: String
    ) throws -> SSHHostPublicKey {
        let fields = keyString.split(separator: " ", maxSplits: 1).map(String.init)
        guard fields.count == 2, let blob = Data(base64Encoded: fields[1]) else {
            throw ImportError.invalidKey
        }
        return try SSHHostPublicKey(
            algorithm: fields[0],
            blob: blob,
            fingerprint: fingerprint
        )
    }

    private static func sharedRecord(
        endpoint: String,
        record: HostRecord
    ) -> TrustedHostRecord? {
        guard let key = try? sharedKey(
            keyString: record.keyString,
            fingerprint: record.fingerprint
        ) else { return nil }
        return TrustedHostRecord(
            endpoint: KnownHostEndpoint(host: endpoint),
            key: key,
            trustedAt: record.firstSeen
        )
    }

    /// Snapshot of the store as display rows for the Known Hosts
    /// page. Sorted by `lastSeen` descending.
    func list() -> [DisplayRow] {
        let now = nowProvider()
        let staleAfter = now.addingTimeInterval(
            -Double(Self.staleThresholdDays) * 86400
        )
        let rows: [DisplayRow] = records.map { (endpoint, record) in
            let status: HostStatus
            if record.pendingFingerprint != nil {
                status = .changed
            } else if record.lastSeen < staleAfter {
                status = .stale
            } else {
                status = .ok
            }
            return DisplayRow(
                id: endpoint,
                host: Self.endpointHost(endpoint: endpoint),
                algorithm: Self.algorithmName(from: record.keyString),
                fingerprint: record.fingerprint,
                previousFingerprint: record.previousFingerprint,
                pendingFingerprint: record.pendingFingerprint,
                pendingKeyString: record.pendingKeyString,
                firstSeen: record.firstSeen,
                lastSeen: record.lastSeen,
                status: status,
                matchedPeerLabel: record.matchedPeerLabel
            )
        }
        return rows.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Interoperable OpenSSH known_hosts text. Host fingerprints are public;
    /// this export never reads or includes authentication key material.
    func openSSHExportText() -> String {
        OpenSSHKnownHostsCodec.exportText(
            records: records.map { endpoint, record in
                KnownHostsExportRecord(
                    endpointKey: endpoint,
                    keyString: record.keyString
                )
            }
        )
    }

    /// Applies a plan that the user has already reviewed and confirmed. New
    /// pins are added, differing local pins are explicitly replaced while
    /// retaining rotation history, and identical pins remain untouched.
    func applyConfirmedOpenSSHImport(
        _ entries: [KnownHostsOpenSSHImportPlan.Entry]
    ) throws -> OpenSSHImportSummary {
        let now = nowProvider()
        var stagedRecords = records
        var added = 0
        var replaced = 0
        var unchanged = 0
        var stalePlanConflicts = 0

        for entry in entries {
            let actualFingerprint = stagedRecords[entry.endpoint]?.fingerprint
            guard actualFingerprint == entry.expectedPriorFingerprint else {
                stalePlanConflicts += 1
                continue
            }

            switch entry.action {
            case .add:
                stagedRecords[entry.endpoint] = HostRecord(
                    fingerprint: entry.fingerprint,
                    keyString: entry.keyString,
                    firstSeen: now,
                    lastSeen: now,
                    pendingFingerprint: nil,
                    pendingKeyString: nil,
                    previousFingerprint: nil,
                    matchedPeerLabel: nil
                )
                added += 1

            case .replace:
                guard let existing = stagedRecords[entry.endpoint] else {
                    stalePlanConflicts += 1
                    continue
                }
                stagedRecords[entry.endpoint] = HostRecord(
                    fingerprint: entry.fingerprint,
                    keyString: entry.keyString,
                    firstSeen: existing.firstSeen,
                    lastSeen: now,
                    pendingFingerprint: nil,
                    pendingKeyString: nil,
                    previousFingerprint: existing.fingerprint,
                    matchedPeerLabel: nil
                )
                replaced += 1

            case .unchanged:
                unchanged += 1
            }
        }

        if added > 0 || replaced > 0 {
            try writeToDisk(stagedRecords)
            records = stagedRecords
        }
        return OpenSSHImportSummary(
            added: added,
            replaced: replaced,
            unchanged: unchanged,
            stalePlanConflicts: stalePlanConflicts
        )
    }

    // MARK: - Fingerprint

    /// SHA-256 fingerprint of the key's SSH wire format, matching
    /// OpenSSH's `SHA256:...` display.
    ///
    /// Padded base64: this exact string is what `known_hosts.json` has
    /// persisted since the store shipped, and `check()` compares the stored
    /// string against a freshly computed one. Switching to the unpadded form
    /// the rest of the codebase renders would make every already-pinned host
    /// report a key MISMATCH on its next connection, so the divergence is
    /// declared at the call site and the digest itself comes from the one
    /// shared implementation.
    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        // String(openSSHPublicKey:) returns "algo base64data"
        let parts = String(openSSHPublicKey: key).split(separator: " ", maxSplits: 1)
        guard parts.count >= 2, let wireData = Data(base64Encoded: String(parts[1])) else {
            return "unknown"
        }
        return SSHHostPublicKey.sha256Fingerprint(of: wireData, padding: .padded)
    }

    /// Short display form: "SHA256:abc...xyz"
    static func shortFingerprint(of key: NIOSSHPublicKey) -> String {
        let fp = fingerprint(of: key)
        if fp.count > 20 {
            return String(fp.prefix(20)) + "…"
        }
        return fp
    }

    // MARK: - Endpoint helpers

    /// Strip a default `:22` suffix from the stored endpoint key for
    /// display. Non-standard ports are kept verbatim.
    static func endpointHost(endpoint: String) -> String {
        guard let colon = endpoint.lastIndex(of: ":") else { return endpoint }
        let port = endpoint[endpoint.index(after: colon)...]
        return port == "22" ? String(endpoint[..<colon]) : endpoint
    }

    /// Extract a short algorithm label from an OpenSSH key string for
    /// the page's "algo" column. "ssh-ed25519 AAAA..." -> "ed25519".
    static func algorithmName(from keyString: String) -> String {
        let head = keyString.split(separator: " ", maxSplits: 1).first ?? ""
        switch head {
        case "ssh-ed25519": return "ed25519"
        case "ssh-rsa": return "rsa"
        case let s where s.hasPrefix("ecdsa-sha2-"): return "ecdsa"
        default: return String(head)
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: HostRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func saveToDisk() {
        try? writeToDisk(records)
    }

    private func writeToDisk(_ records: [String: HostRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}

struct KnownHostsOpenSSHImportPlan: Equatable, Sendable {
    enum Action: String, Equatable, Sendable {
        case add
        case replace
        case unchanged
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let lineNumber: Int
        let endpoint: String
        let keyString: String
        let fingerprint: String
        let action: Action
        let expectedPriorFingerprint: String?

        var id: String { "\(lineNumber):\(endpoint)" }
    }

    struct Rejection: Identifiable, Equatable, Sendable {
        let lineNumber: Int
        let source: String
        let reason: String

        var id: String { "\(lineNumber):\(source):\(reason)" }
    }

    let entries: [Entry]
    let rejections: [Rejection]
    let warnings: [String]

    var addCount: Int { entries.count { $0.action == .add } }
    var replaceCount: Int { entries.count { $0.action == .replace } }
    var unchangedCount: Int { entries.count { $0.action == .unchanged } }
}

/// iOS adapter over the shared `OpenSSHKnownHostsCodec` in `TesseraTrustCore`.
///
/// Parsing, host-token mapping, deduplication, ambiguity detection and the
/// add/replace/unchanged classification all live in core so Android reaches the
/// same verdicts. Two things stay here:
///
///  * **Key enrichment.** Core validates a key structurally (algorithm token,
///    canonical base64, blob's own algorithm name agreeing). iOS additionally
///    parses it with `NIOSSHPublicKey`, so the review sheet only ever offers
///    keys the SSH stack will actually accept, and pins the stack's canonical
///    rendering rather than whatever spacing the file used.
///  * **Localization.** Core reports a rejection *reason*; the user-facing
///    sentence is rendered here.
enum KnownHostsOpenSSHCodec {
    /// Builds a reviewable plan. Nothing is written until
    /// `applyConfirmedOpenSSHImport` runs over the entries the user confirmed.
    static func importPlan(
        text: String,
        currentRows: [KnownHostsStore.DisplayRow]
    ) -> KnownHostsOpenSSHImportPlan {
        let plan = OpenSSHKnownHostsCodec.importPlan(
            text: text,
            existingFingerprints: Dictionary(
                currentRows.map { ($0.id, $0.fingerprint) },
                uniquingKeysWith: { first, _ in first }
            ),
            validateKey: niosshKeyValidation
        )
        return KnownHostsOpenSSHImportPlan(
            entries: plan.candidates.map { candidate in
                KnownHostsOpenSSHImportPlan.Entry(
                    lineNumber: candidate.lineNumber,
                    endpoint: candidate.endpointKey,
                    keyString: candidate.keyString,
                    fingerprint: candidate.fingerprint,
                    action: KnownHostsOpenSSHImportPlan.Action(candidate.action),
                    expectedPriorFingerprint: candidate.expectedPriorFingerprint
                )
            },
            rejections: plan.rejections.map { rejection in
                KnownHostsOpenSSHImportPlan.Rejection(
                    lineNumber: rejection.lineNumber,
                    source: rejection.source,
                    reason: localizedReason(rejection.reason)
                )
            },
            warnings: plan.warnings.map(localizedWarning)
        )
    }

    static func exportLine(endpoint: String, keyString: String) -> String {
        OpenSSHKnownHostsCodec.exportLine(endpointKey: endpoint, keyString: keyString)
    }

    static func knownHostsHost(fromEndpoint endpoint: String) -> String {
        OpenSSHKnownHostsCodec.knownHostsHostField(fromEndpointKey: endpoint)
    }

    /// iOS key enrichment: a key must parse as an `NIOSSHPublicKey` before it
    /// can be offered as a pin, and the plan carries NIOSSH's canonical
    /// rendering plus the store's (padded) fingerprint form.
    private static let niosshKeyValidation: KnownHostsImportKeyValidator = { keyString in
        guard let key = try? NIOSSHPublicKey(openSSHPublicKey: keyString) else {
            return .rejected
        }
        return .accepted(
            canonicalKeyString: String(openSSHPublicKey: key),
            fingerprint: KnownHostsStore.fingerprint(of: key)
        )
    }

    private static func localizedReason(
        _ reason: KnownHostsImportRejectionReason
    ) -> String {
        switch reason {
        case .missingFields:
            String(localized: "expected host, key type, and public key")
        case .unsupportedMarker:
            String(localized: "OpenSSH marker entries are not supported")
        case .invalidPublicKey:
            String(localized: "invalid or unsupported OpenSSH public key")
        case .emptyHostField:
            String(localized: "empty host field")
        case .hashedHost:
            String(localized: "hashed hosts cannot be mapped to a Tessera endpoint")
        case .wildcardOrNegatedHost:
            String(localized: "wildcard and negated hosts are not supported")
        case .invalidBracketedHostPort:
            String(localized: "invalid bracketed host and port")
        case .invalidHostOrPort:
            String(localized: "invalid host or port")
        // `.unnormalizableHost` cannot arrive here: this store is keyed by the
        // address as the user typed it, so it imports `.verbatim` and never
        // asks the codec to normalize. It shares the wording rather than
        // introducing a string for a branch iOS cannot reach.
        case .invalidHostField, .unnormalizableHost:
            String(localized: "invalid host field")
        case .ambiguousEndpoint:
            String(localized: "ambiguous: multiple different keys were supplied for this endpoint")
        }
    }

    private static func localizedWarning(_ warning: KnownHostsImportWarning) -> String {
        switch warning {
        case let .duplicatePinIgnored(lineNumber, endpointKey):
            "Line \(lineNumber): duplicate pin for \(endpointKey) ignored"
        }
    }
}

private extension KnownHostsOpenSSHImportPlan.Action {
    init(_ action: KnownHostsImportAction) {
        switch action {
        case .add: self = .add
        case .replace: self = .replace
        case .unchanged: self = .unchanged
        }
    }
}
