import Foundation
import Crypto
import NIOSSH
import NIOCore

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

        guard var record = records[endpoint] else {
            return .unknown(fingerprint: fingerprint, keyString: keyString)
        }

        if Self.unpadded(record.fingerprint) == fingerprint {
            var dirty = false
            if record.fingerprint != fingerprint {
                // Migrate a record stored with base64 padding.
                record.fingerprint = fingerprint
                dirty = true
            }
            if record.pendingFingerprint != nil || record.pendingKeyString != nil {
                record.pendingFingerprint = nil
                record.pendingKeyString = nil
                dirty = true
            }
            if dirty {
                records[endpoint] = record
                saveToDisk()
            }
            return .trusted
        }

        record.pendingFingerprint = fingerprint
        record.pendingKeyString = keyString
        records[endpoint] = record
        saveToDisk()

        return .changed(
            oldFingerprint: Self.unpadded(record.fingerprint),
            newFingerprint: fingerprint,
            keyString: keyString
        )
    }

    /// Trust a host key (first-time accept or override after change).
    /// On override, the previous fingerprint is preserved on the
    /// record under `previousFingerprint` so the page detail row can
    /// show the rotation history.
    func trust(_ key: NIOSSHPublicKey, for endpoint: String) {
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
            return Self.unpadded(existing.fingerprint) == fingerprint
                ? existing.previousFingerprint
                : Self.unpadded(existing.fingerprint)
        }()
        records[endpoint] = HostRecord(
            fingerprint: fingerprint,
            keyString: keyString,
            firstSeen: firstSeen,
            lastSeen: now,
            pendingFingerprint: nil,
            pendingKeyString: nil,
            previousFingerprint: priorFingerprint
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
                fingerprint: Self.unpadded(record.fingerprint),
                previousFingerprint: record.previousFingerprint.map(Self.unpadded),
                pendingFingerprint: record.pendingFingerprint.map(Self.unpadded),
                pendingKeyString: record.pendingKeyString,
                firstSeen: record.firstSeen,
                lastSeen: record.lastSeen,
                status: status
            )
        }
        return rows.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Fingerprint

    /// SHA-256 fingerprint of the key's SSH wire format, matching
    /// OpenSSH's `SHA256:...` display.
    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        // String(openSSHPublicKey:) returns "algo base64data"
        let parts = String(openSSHPublicKey: key).split(separator: " ", maxSplits: 1)
        guard parts.count >= 2, let wireData = Data(base64Encoded: String(parts[1])) else {
            return "unknown"
        }
        let hash = SHA256.hash(data: wireData)
        return "SHA256:" + Data(hash).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Strips base64 padding from a stored fingerprint. Records written
    /// before the padding fix carry a trailing "=" that OpenSSH never
    /// prints; comparisons must treat both forms as the same key.
    static func unpadded(_ fingerprint: String) -> String {
        fingerprint.trimmingCharacters(in: CharacterSet(charactersIn: "="))
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
