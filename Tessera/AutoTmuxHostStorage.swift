import CryptoKit
import Foundation
import Observation
import os
import TmuxControl
import TmuxControlCore
import TesseraProtocolCore

/// Device-local, non-secret history for truthful host recency and key-use UI.
///
/// This deliberately stays outside SwiftData. Adding a column to the current
/// model graph would cross PersistedHost's `[String]` migration hazard on
/// iOS 26, while connection history is runtime metadata that should describe
/// this device rather than travel through Nearby Setup.
@MainActor
@Observable
final class ConnectionActivityStore {
    static let shared = ConnectionActivityStore()
    nonisolated static let defaultStorageKey = "tessera.connectionActivity.v1"

    private struct Document: Codable {
        var version = 1
        var hostLastConnectedAt: [String: Date] = [:]
        var keyLastUsedAt: [String: Date] = [:]
    }

    private(set) var hostLastConnectedAt: [String: Date]
    private(set) var keyLastUsedAt: [String: Date]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = ConnectionActivityStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        let document = Self.load(defaults: defaults, storageKey: storageKey)
        hostLastConnectedAt = document.hostLastConnectedAt
        keyLastUsedAt = document.keyLastUsedAt
    }

    func lastConnectedAt(for hostID: UUID) -> Date? {
        hostLastConnectedAt[hostID.uuidString]
    }

    func lastUsedAt(for keyID: UUID) -> Date? {
        keyLastUsedAt[keyID.uuidString]
    }

    func recordHostConnection(_ hostID: UUID, at date: Date = Date()) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        let key = hostID.uuidString
        guard hostLastConnectedAt[key].map({ date > $0 }) ?? true else { return }
        hostLastConnectedAt[key] = date
        save()
    }

    func recordKeyUse(_ keyID: UUID, at date: Date = Date()) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        let key = keyID.uuidString
        guard keyLastUsedAt[key].map({ date > $0 }) ?? true else { return }
        keyLastUsedAt[key] = date
        save()
    }

    func removeHost(_ hostID: UUID) {
        guard hostLastConnectedAt.removeValue(forKey: hostID.uuidString) != nil else { return }
        save()
    }

    func removeKey(_ keyID: UUID) {
        guard keyLastUsedAt.removeValue(forKey: keyID.uuidString) != nil else { return }
        save()
    }

    private func save() {
        let document = Document(
            hostLastConnectedAt: hostLastConnectedAt,
            keyLastUsedAt: keyLastUsedAt
        )
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(defaults: UserDefaults, storageKey: String) -> Document {
        guard let data = defaults.data(forKey: storageKey),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1 else {
            return Document()
        }
        return Document(
            hostLastConnectedAt: document.hostLastConnectedAt.filter {
                $0.value.timeIntervalSinceReferenceDate.isFinite
            },
            keyLastUsedAt: document.keyLastUsedAt.filter {
                $0.value.timeIntervalSinceReferenceDate.isFinite
            }
        )
    }
}

enum RecentHostOrdering {
    static func sortedIDs(
        hostIDs: [UUID],
        sortOrder: [UUID: Int],
        lastConnectedAt: [UUID: Date],
        limit: Int
    ) -> [UUID] {
        hostIDs
            .filter { lastConnectedAt[$0] != nil }
            .sorted { lhs, rhs in
                let lhsDate = lastConnectedAt[lhs] ?? .distantPast
                let rhsDate = lastConnectedAt[rhs] ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                let lhsOrder = sortOrder[lhs] ?? .max
                let rhsOrder = sortOrder[rhs] ?? .max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.uuidString < rhs.uuidString
            }
            .prefix(max(0, limit))
            .map(\.self)
    }
}

enum ConnectionActivityAttribution {
    static func newlyReadyHostIDs(
        oldReadyIDs: Set<UUID>,
        newReadyIDs: Set<UUID>,
        connectedSessionIDs: Set<UUID>,
        sessions: [LiveSession]
    ) -> Set<UUID> {
        let newlyReady = newReadyIDs
            .subtracting(oldReadyIDs)
            .intersection(connectedSessionIDs)
        return Set(sessions.compactMap { session in
            guard newlyReady.contains(session.id) else { return nil }
            return session.persistedHostID
        })
    }
}

/// Per-host runtime data we want to remember across connects, separate
/// from the user-edited `Host` config.
///
/// The struct exists as its own type so runtime discoveries can survive
/// session teardown without being folded into the user-edited host config.
struct HostRuntimeState: Codable, Equatable {
    /// The name passed to `tmux -CC attach -t <name>` /
    /// `tmux -CC new -s <name>` on the most recent successful
    /// auto-attach. Set the first time we observe `tmux.mode` flip
    /// to `.tmuxControl` for this host so subsequent connects can
    /// resume the same server-side session.
    var tmuxSessionName: String?

    /// `true` after the auto-tmux sentinel proves that tmux is unavailable.
    /// A later successful control-mode entry resets this to `false`.
    var tmuxUnavailable: Bool?

    /// Last high-confidence WSL2/Tailscale MTU risk observed over this exact
    /// endpoint. Cached locally so an auto-restored session can explain a
    /// likely stall even when the next SSH handshake never gets far enough to
    /// run the host probe. A later conclusive safe probe clears it.
    var wslTailscaleMTUWarning: WSLTailscaleMTUWarning?
}

/// Tiny UserDefaults wrapper for `HostRuntimeState`. Keyed by
/// `user@address:port` rather than `Host.id` because the in-memory
/// `Host.id` is a fresh UUID each launch (we don't persist hosts
/// yet — see §6 of the requirements doc).
///
/// Password and private-key filename are deliberately NOT in the key:
/// rotating credentials shouldn't lose the saved tmux session.
enum HostRuntimeStateStore {
    private static let defaults = UserDefaults.standard
    private static let keyPrefix = "tessera.host.runtime."

    /// Stable identity for a host record. Anything that uniquely
    /// identifies "the same place I was logging into last time"
    /// goes here.
    static func key(for host: Host) -> String {
        "\(host.user)@\(host.address):\(host.port)"
    }

    static func load(for host: Host) -> HostRuntimeState {
        load(for: host, defaults: defaults)
    }

    static func load(for host: Host, defaults storage: UserDefaults) -> HostRuntimeState {
        let dictKey = keyPrefix + key(for: host)
        guard let data = storage.data(forKey: dictKey),
              let state = try? JSONDecoder().decode(HostRuntimeState.self, from: data)
        else { return HostRuntimeState() }
        return state
    }

    static func save(_ state: HostRuntimeState, for host: Host) {
        save(state, for: host, defaults: defaults)
    }

    static func save(
        _ state: HostRuntimeState,
        for host: Host,
        defaults storage: UserDefaults
    ) {
        let dictKey = keyPrefix + key(for: host)
        if let data = try? JSONEncoder().encode(state) {
            storage.set(data, forKey: dictKey)
        }
    }

    static func isTmuxKnownUnavailable(for host: Host) -> Bool {
        isTmuxKnownUnavailable(for: host, defaults: defaults)
    }

    static func isTmuxKnownUnavailable(
        for host: Host,
        defaults storage: UserDefaults
    ) -> Bool {
        load(for: host, defaults: storage).tmuxUnavailable == true
    }

    static func recordTmuxUnavailable(for host: Host) {
        recordTmuxUnavailable(for: host, defaults: defaults)
    }

    static func recordTmuxUnavailable(
        for host: Host,
        defaults storage: UserDefaults
    ) {
        var state = load(for: host, defaults: storage)
        guard state.tmuxUnavailable != true else { return }
        state.tmuxUnavailable = true
        save(state, for: host, defaults: storage)
    }

    static func recordTmuxAvailable(for host: Host) {
        recordTmuxAvailable(for: host, defaults: defaults)
    }

    static func recordTmuxAvailable(
        for host: Host,
        defaults storage: UserDefaults
    ) {
        var state = load(for: host, defaults: storage)
        guard state.tmuxUnavailable != false else { return }
        state.tmuxUnavailable = false
        save(state, for: host, defaults: storage)
    }

    static func wslTailscaleMTUWarning(for host: Host) -> WSLTailscaleMTUWarning? {
        wslTailscaleMTUWarning(for: host, defaults: defaults)
    }

    static func wslTailscaleMTUWarning(
        for host: Host,
        defaults storage: UserDefaults
    ) -> WSLTailscaleMTUWarning? {
        load(for: host, defaults: storage).wslTailscaleMTUWarning
    }

    /// Persist only conclusive results. An unavailable probe leaves prior
    /// evidence intact so a packet-size failure during the next handshake
    /// cannot erase the warning that would explain it.
    static func recordNetworkPathAssessment(
        _ assessment: NetworkPathAssessment,
        for host: Host
    ) {
        recordNetworkPathAssessment(assessment, for: host, defaults: defaults)
    }

    static func recordNetworkPathAssessment(
        _ assessment: NetworkPathAssessment,
        for host: Host,
        defaults storage: UserDefaults
    ) {
        guard assessment != .unavailable else { return }
        var state = load(for: host, defaults: storage)
        let warning: WSLTailscaleMTUWarning?
        switch assessment {
        case .unavailable:
            return
        case .notAtRisk:
            warning = nil
        case .warning(let value):
            warning = value
        }
        guard state.wslTailscaleMTUWarning != warning else { return }
        state.wslTailscaleMTUWarning = warning
        save(state, for: host, defaults: storage)
    }

    /// Resolve the tmux session name to use for this host on the
    /// next auto-attach.
    ///
    /// Lookup order:
    ///   1. Persisted `tmuxSessionName` from a previous connect.
    ///   2. Deterministic SHA-256 derivation from the host key.
    ///
    /// The deterministic fallback is what makes "wipe app data,
    /// reconnect to the same host" idempotent — the freshly-installed
    /// app computes the same name and resumes the existing
    /// server-side session instead of stranding it.
    static func sessionName(for host: Host) -> String {
        if let saved = load(for: host).tmuxSessionName, !saved.isEmpty {
            return saved
        }
        return AutomaticTmuxTarget.sessionName(forHostKey: key(for: host))
    }

    /// Persist the resolved session name as soon as we observe a
    /// successful tmux mode entry. Idempotent: writes only if the
    /// stored value differs from the candidate, so the common case
    /// (resume) is a single load + comparison + early return.
    static func recordSessionUsed(_ name: String, for host: Host) {
        var state = load(for: host)
        if state.tmuxSessionName != name || state.tmuxUnavailable != false {
            state.tmuxSessionName = name
            state.tmuxUnavailable = false
            save(state, for: host)
        }
    }
}

/// The grids each tmux session's controller owned under this device's
/// stamps, kept across a process death (§6.9) so a relaunch whose stamp
/// still stands is not veiled as another device. One small file, read off
/// main before the first attach needs it and rewritten off main after every
/// change, since a process can die at any moment; a burst of changes (a
/// live resize owning grid after grid) writes once. Keyed by a hash of the
/// host's runtime key and the stamp's tmux
/// session, so no host or session name is stored; each session keeps the
/// newest `TmuxOwnedGeometryRecord.restoreLimit` generations, and the file
/// the `sessionLimit` sessions kept most recently.
@MainActor
final class TmuxOwnedGeometryFileStore {
    static let shared = TmuxOwnedGeometryFileStore()
    static let sessionLimit = 64

    private struct Entry: Codable, Equatable, Sendable {
        var key: String
        var records: [TmuxOwnedGeometryRecord]
    }

    private let url: URL
    private let writeQueue = DispatchQueue(label: "com.bambouville.tessera.tmux-owned-geometry", qos: .utility)
    /// Least recently kept first; nil until the file is read.
    private var entries: [Entry]?
    private var preloading = false
    /// The newest entries not yet written. The write queue takes them, so
    /// keeps that land before it runs ride the one write already queued.
    private let pendingWrite = OSAllocatedUnfairLock<[Entry]?>(initialState: nil)

    init(url: URL = TmuxOwnedGeometryFileStore.defaultURL) {
        self.url = url
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tmux-owned-geometry.json", isDirectory: false)
    }

    func store(for host: Host) -> TmuxController.OwnedGeometryStore {
        let hostKey = HostRuntimeStateStore.key(for: host)
        preload()
        return .init(
            records: { [self] session in records(forKey: Self.key(hostKey: hostKey, session: session)) },
            keep: { [self] record, session in keep(record, forKey: Self.key(hostKey: hostKey, session: session)) }
        )
    }

    func records(forKey key: String) -> [TmuxOwnedGeometryRecord] {
        loadedEntries().first { $0.key == key }?.records ?? []
    }

    func keep(_ record: TmuxOwnedGeometryRecord, forKey key: String) {
        var entries = loadedEntries()
        let earlier = entries.firstIndex { $0.key == key }.map { entries.remove(at: $0).records } ?? []
        entries.append(Entry(key: key, records: TmuxOwnedGeometryRecord.keeping(record, in: earlier)))
        if entries.count > Self.sessionLimit {
            entries.removeFirst(entries.count - Self.sessionLimit)
        }
        self.entries = entries
        let kept = entries
        let queued = pendingWrite.withLock { pending in
            defer { pending = kept }
            return pending != nil
        }
        guard !queued else { return }
        let url = self.url, pendingWrite = self.pendingWrite
        writeQueue.async {
            let snapshot = pendingWrite.withLock { pending in
                defer { pending = nil }
                return pending
            }
            guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
            Self.write(data, to: url)
        }
    }

    /// Waits for the writes already queued; tests read the file after it.
    func flushForTesting() {
        writeQueue.sync {}
    }

    nonisolated static func key(hostKey: String, session: String) -> String {
        SHA256.hash(data: Data("\(hostKey)\u{0}\(session)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func loadedEntries() -> [Entry] {
        if let entries { return entries }
        let read = Self.read(url)
        entries = read
        return read
    }

    /// Reads the file on the write queue, ahead of the writes this process
    /// queues later; a read on main that got there first wins.
    private func preload() {
        guard entries == nil, !preloading else { return }
        preloading = true
        let url = self.url
        writeQueue.async {
            let read = Self.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.preloading = false
                    if self.entries == nil { self.entries = read }
                }
            }
        }
    }

    /// A missing or unreadable file keeps nothing: the relaunch reads as it
    /// did before records were kept.
    private nonisolated static func read(_ url: URL) -> [Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    private nonisolated static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = url
            try url.setResourceValues(values)
        } catch {
            DiagnosticLogStore.append(.tmux, "owned-geometry write failed type=\(type(of: error))")
        }
    }
}
