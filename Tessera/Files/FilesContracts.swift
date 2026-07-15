// Tessera/Files/FilesContracts.swift
//
// Frozen contracts for the Remote Files feature. Implementation packets
// (FileBridge, TransferQueue, panel UI, upload sheet) code against these
// types in parallel — do not change a signature here without coordinating
// across all packets. Design reference: docs/mockups/remote-files/index.html.

import Foundation
import Observation

// MARK: - Bridge identity

/// Identifies one file bridge per managed host + remote route. Deliberately
/// transport-free (unlike `PersistedHost.connectionKey`): SSH and mosh
/// sessions for the same saved host and route share a single bridge, because
/// file operations always run over the bridge's own SSH connection, never the
/// terminal transport. Separately managed host records never share.
struct FileBridgeKey: Hashable, Sendable, CustomStringConvertible {
    /// Saved-host identity. Two independently managed hosts may intentionally
    /// use the same user/private endpoint behind different networks; they must
    /// never share an SFTP connection or transfer queue. `nil` is reserved for
    /// test/mock keys constructed without a Host DTO.
    let hostID: UUID?
    let user: String
    let address: String
    let port: Int
    /// Jump-chain identity, outermost first (`user@address:port` per hop).
    /// With jump hosts an address is resolved inside the innermost
    /// bastion's network namespace — the same `user@address:port` behind
    /// two different chains names two different machines, so chain-blind
    /// sharing would hand one host's live SFTP connection to the other.
    let jumpPath: [String]

    init(
        hostID: UUID? = nil,
        user: String,
        address: String,
        port: Int,
        jumpPath: [String] = []
    ) {
        self.hostID = hostID
        self.user = user
        self.address = address
        self.port = port
        self.jumpPath = jumpPath
    }

    init(host: Host) {
        self.init(
            hostID: host.id,
            user: host.user,
            address: host.address,
            port: host.port,
            jumpPath: host.jumpChain.map { "\($0.user)@\($0.address):\($0.port)" }
        )
    }

    var description: String {
        let base = "\(user)@\(address):\(port)"
        return jumpPath.isEmpty ? base : "\(jumpPath.joined(separator: "→"))→\(base)"
    }
}

// MARK: - Directory entries

/// One remote directory entry, mapped from SFTP NameEntry + attributes.
struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case file
        case directory
        /// Symlink as reported by the server. Resolution (does it point at
        /// a directory?) is deferred to navigation time via `realPath`.
        case symlink
    }

    /// Last path component.
    let name: String
    /// Absolute remote path, no trailing slash (except root "/").
    let path: String
    let kind: Kind
    /// nil for directories or when the server omits size.
    let size: UInt64?
    let modified: Date?
    /// POSIX permission bits (low 12 bits of st_mode), when provided.
    let permissions: UInt16?

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
}

// MARK: - Bridge state / errors

enum FileBridgeState: Equatable, Sendable {
    /// Never connected (bridge is lazy — nothing opens without a user gesture).
    case idle
    case connecting
    case connected
    /// Was connected, connection lost. Retryable via `connect()`.
    case dropped
    /// Connect attempt failed. Associated value is a user-facing message.
    case failed(String)
}

enum FileBridgeError: Error, Equatable {
    case notConnected
    /// Unknown/changed host key and the bridge never prompts — the user
    /// must open a terminal session to this host first to establish trust.
    case hostKeyNeedsTerminalTrust
    case authenticationFailed(String)
    case network(String)
    /// SFTP subsystem missing/refused on the server.
    case sftpUnavailable(String)
    /// Remote operation failed (permissions, missing path, non-empty dir…).
    case remoteOperationFailed(String)
    case cancelled
}

extension FileBridgeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the host."
        case .hostKeyNeedsTerminalTrust:
            return "This host's key isn't trusted yet. Open a terminal session to it first to review the key, then retry."
        case .authenticationFailed(let detail):
            return "Authentication failed: \(detail)"
        case .network(let detail):
            return "Network error: \(detail)"
        case .sftpUnavailable(let detail):
            return "SFTP is unavailable on this host: \(detail)"
        case .remoteOperationFailed(let detail):
            return detail
        case .cancelled:
            return "Cancelled."
        }
    }
}

// MARK: - Bridge protocol

/// Bytes-transferred progress callback. `totalBytes` is nil when the remote
/// size is unknown. Always invoked on the main actor.
typealias TransferProgressHandler = @MainActor @Sendable (_ transferredBytes: Int64, _ totalBytes: Int64?) -> Void

/// One dedicated SSH connection + SFTP subsystem per remote endpoint,
/// independent of any terminal session's transport. Lazy: created by the
/// registry, connected on first use, torn down after idle timeout or when
/// the last session to the host closes.
@MainActor
protocol FileBridging: AnyObject, Observable {
    var key: FileBridgeKey { get }
    var state: FileBridgeState { get }
    /// Absolute remote $HOME, resolved on connect via SFTP realpath(".").
    var homeDirectory: String? { get }

    /// While true the bridge skips its idle-timeout teardown (set by the
    /// panel while it is open — a visible panel is ongoing use, and an
    /// idle disconnect under it strands the user on a dead listing).
    var suppressIdleTeardown: Bool { get set }

    /// Idempotent: returns immediately when already connected; coalesces
    /// concurrent callers while connecting. Never presents host-key UI —
    /// unknown/changed keys throw `.hostKeyNeedsTerminalTrust`.
    func connect() async throws
    func disconnect() async

    // Directory / metadata. All throw FileBridgeError.
    func listDirectory(_ path: String) async throws -> [RemoteFileEntry]
    func realPath(_ path: String) async throws -> String
    func createDirectory(_ path: String) async throws
    func rename(from oldPath: String, to newPath: String) async throws
    func removeFile(_ path: String) async throws
    /// Non-recursive; a non-empty directory throws `.remoteOperationFailed`.
    func removeDirectory(_ path: String) async throws

    // Transfers: chunked, honor Task cancellation, report progress on main.
    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws
    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws

    /// One-off remote command over this bridge's SSH connection (exec
    /// channel, merged streams). `inShell: true` wraps in `$SHELL -c`
    /// (sources dotfiles — use for rc-file work); `false` is a bare exec
    /// request (use for probes).
    @discardableResult
    func exec(_ command: String, inShell: Bool) async throws -> String
}

// MARK: - Transfer queue

enum TransferDirection: Sendable { case download, upload }

enum TransferPhase: Equatable, Sendable {
    case queued
    /// `fraction` is nil while indeterminate (unknown total).
    case running(fraction: Double?)
    case completed
    case failed(String)
    case cancelled
}

/// UI-facing record of one transfer. Owned and mutated by the queue on the
/// main actor; the panel's transfer strip observes it.
@MainActor
@Observable
final class TransferItem: Identifiable {
    nonisolated let id = UUID()
    let direction: TransferDirection
    let displayName: String
    /// Destination (upload) or source (download) remote path. For paste
    /// uploads this starts as the *directory* and `resolvedRemotePath`
    /// carries the final absolute file path once known.
    let remotePath: String
    let localURL: URL?
    var phase: TransferPhase = .queued
    /// Set on completion of paste/regular uploads: the absolute remote path
    /// of the uploaded file (tilde-free, suitable for terminal injection).
    var resolvedRemotePath: String?

    init(direction: TransferDirection, displayName: String, remotePath: String, localURL: URL?) {
        self.direction = direction
        self.displayName = displayName
        self.remotePath = remotePath
        self.localURL = localURL
    }
}

@MainActor
protocol TransferQueueing: AnyObject, Observable {
    var items: [TransferItem] { get }
    var hasActive: Bool { get }

    @discardableResult
    func enqueueDownload(remotePath: String, displayName: String, to localURL: URL) -> TransferItem
    @discardableResult
    func enqueueUpload(localURL: URL, toDirectory remoteDirectory: String) -> TransferItem
    /// Upload into the temp paste directory (`RemoteFilesConstants.tempDirectory`
    /// under $HOME), creating it if needed with a collision-safe generated
    /// name. On completion `item.resolvedRemotePath` holds the absolute path.
    @discardableResult
    func enqueuePasteUpload(localURL: URL) -> TransferItem
    func cancel(_ item: TransferItem)
    /// Drop finished (completed/failed/cancelled) items from `items`.
    func clearFinished()
    /// Reap aged paste files in the host temp dir ("auto-cleans after
    /// N d"). Callers pass freshConnect=true when they just dialed the
    /// bridge; otherwise it runs at most once per connection.
    func scheduleReaperIfNeeded(freshConnect: Bool)
}

// MARK: - Constants & preferences keys

enum RemoteFilesConstants {
    /// Temp/paste directory, relative to the remote $HOME.
    static let tempDirectory = ".cache/tessera"
    /// Filename prefix for paste uploads; the reaper only ever deletes
    /// files matching this prefix inside `tempDirectory`.
    static let pastePrefix = "paste-"

    /// UserDefaults: Int, days before paste files are reaped on bridge
    /// connect. 0 disables the reaper.
    static let reaperDaysKey = "tessera.files.reaperDays"
    static let defaultReaperDays = 7
    /// UserDefaults: "cwd" | "temp" — default Upload-sheet destination.
    static let defaultDestinationKey = "tessera.files.defaultDestination"
    /// UserDefaults, per-host: last Upload-sheet destination choice.
    static func lastDestinationKey(hostID: UUID) -> String {
        "tessera.files.lastDest.\(hostID.uuidString)"
    }
}

// MARK: - Mock bridge (UI development / previews / tests)

/// In-memory bridge with a canned tree. Drives the panel UI before the real
/// FileBridge lands and stays useful for previews and unit tests.
@MainActor
@Observable
final class MockFileBridge: FileBridging {
    let key: FileBridgeKey
    private(set) var state: FileBridgeState = .idle
    private(set) var homeDirectory: String? = "/home/mock"
    var suppressIdleTeardown = false

    /// path -> entries. Directories must appear both as an entry in their
    /// parent's list and as a key here (empty array = empty directory).
    var tree: [String: [RemoteFileEntry]]
    /// Artificial latency for exercising loading states.
    var latencyNanos: UInt64 = 0

    init(key: FileBridgeKey = FileBridgeKey(user: "mock", address: "mock.local", port: 22),
         tree: [String: [RemoteFileEntry]]? = nil) {
        self.key = key
        self.tree = tree ?? Self.defaultTree
    }

    func connect() async throws {
        if state == .connected { return }
        state = .connecting
        if latencyNanos > 0 { try? await Task.sleep(nanoseconds: latencyNanos) }
        state = .connected
    }

    func disconnect() async { state = .idle }

    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        guard state == .connected else { throw FileBridgeError.notConnected }
        if latencyNanos > 0 { try? await Task.sleep(nanoseconds: latencyNanos) }
        guard let entries = tree[Self.normalize(path)] else {
            throw FileBridgeError.remoteOperationFailed("No such directory: \(path)")
        }
        return entries
    }

    func realPath(_ path: String) async throws -> String {
        guard state == .connected else { throw FileBridgeError.notConnected }
        if path == "." || path == "~" { return homeDirectory ?? "/" }
        return Self.normalize(path)
    }

    func createDirectory(_ path: String) async throws {
        guard state == .connected else { throw FileBridgeError.notConnected }
        let p = Self.normalize(path)
        let parent = (p as NSString).deletingLastPathComponent
        guard tree[parent] != nil else {
            throw FileBridgeError.remoteOperationFailed("No such directory: \(parent)")
        }
        tree[p] = []
        tree[parent]?.append(RemoteFileEntry(
            name: (p as NSString).lastPathComponent, path: p, kind: .directory,
            size: nil, modified: Date(), permissions: 0o755))
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        guard state == .connected else { throw FileBridgeError.notConnected }
        let old = Self.normalize(oldPath), new = Self.normalize(newPath)
        let parent = (old as NSString).deletingLastPathComponent
        guard var siblings = tree[parent],
              let idx = siblings.firstIndex(where: { $0.path == old }) else {
            throw FileBridgeError.remoteOperationFailed("No such file: \(oldPath)")
        }
        let e = siblings[idx]
        siblings[idx] = RemoteFileEntry(
            name: (new as NSString).lastPathComponent, path: new, kind: e.kind,
            size: e.size, modified: e.modified, permissions: e.permissions)
        tree[parent] = siblings
        if let sub = tree.removeValue(forKey: old) { tree[new] = sub }
    }

    func removeFile(_ path: String) async throws {
        guard state == .connected else { throw FileBridgeError.notConnected }
        let p = Self.normalize(path)
        let parent = (p as NSString).deletingLastPathComponent
        tree[parent]?.removeAll { $0.path == p }
    }

    func removeDirectory(_ path: String) async throws {
        guard state == .connected else { throw FileBridgeError.notConnected }
        let p = Self.normalize(path)
        guard let contents = tree[p] else {
            throw FileBridgeError.remoteOperationFailed("No such directory: \(path)")
        }
        guard contents.isEmpty else {
            throw FileBridgeError.remoteOperationFailed("Directory not empty: \(path)")
        }
        tree.removeValue(forKey: p)
        let parent = (p as NSString).deletingLastPathComponent
        tree[parent]?.removeAll { $0.path == p }
    }

    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        guard state == .connected else { throw FileBridgeError.notConnected }
        progress?(0, 100)
        if latencyNanos > 0 { try? await Task.sleep(nanoseconds: latencyNanos) }
        try Data("mock contents of \(remotePath)\n".utf8).write(to: localURL)
        progress?(100, 100)
    }

    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
        guard state == .connected else { throw FileBridgeError.notConnected }
        let size = (try? Data(contentsOf: localURL).count).map(Int64.init) ?? 0
        progress?(0, size)
        if latencyNanos > 0 { try? await Task.sleep(nanoseconds: latencyNanos) }
        let p = Self.normalize(remotePath)
        let parent = (p as NSString).deletingLastPathComponent
        tree[parent]?.append(RemoteFileEntry(
            name: (p as NSString).lastPathComponent, path: p, kind: .file,
            size: UInt64(size), modified: Date(), permissions: 0o644))
        progress?(size, size)
    }

    @discardableResult
    func exec(_ command: String, inShell: Bool) async throws -> String {
        guard state == .connected else { throw FileBridgeError.notConnected }
        return ""
    }

    private static func normalize(_ path: String) -> String {
        if path == "/" { return path }
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static var defaultTree: [String: [RemoteFileEntry]] {
        func file(_ dir: String, _ name: String, _ size: UInt64) -> RemoteFileEntry {
            RemoteFileEntry(name: name, path: "\(dir)/\(name)", kind: .file,
                            size: size, modified: Date(), permissions: 0o644)
        }
        func dir(_ parent: String, _ name: String) -> RemoteFileEntry {
            RemoteFileEntry(name: name, path: "\(parent)/\(name)", kind: .directory,
                            size: nil, modified: Date(), permissions: 0o755)
        }
        let home = "/home/mock"
        let proj = "\(home)/projects/dashboard"
        return [
            home: [dir(home, "projects"), file(home, ".zshrc", 512)],
            "\(home)/projects": [dir("\(home)/projects", "dashboard")],
            proj: [
                dir(proj, "node_modules"),
                dir(proj, "public"),
                dir(proj, "src"),
                file(proj, "README.md", 2_355),
                file(proj, "screenshot.png", 2_411_724),
                file(proj, "package.json", 1_126),
                file(proj, "server.log", 18_874_368),
                file(proj, ".env", 312),
            ],
            "\(proj)/node_modules": [],
            "\(proj)/public": [file("\(proj)/public", "favicon.ico", 4_286)],
            "\(proj)/src": [
                file("\(proj)/src", "App.tsx", 4_198),
                file("\(proj)/src", "Chart.tsx", 10_034),
                dir("\(proj)/src", "components"),
            ],
            "\(proj)/src/components": [file("\(proj)/src/components", "Legend.tsx", 1_820)],
        ]
    }
}
