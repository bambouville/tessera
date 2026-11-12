import Darwin
import Foundation
import TesseraArtifactsCore

enum ArtifactContentLoadError: Error {
    case tooLarge(bytes: Int64)
    case missing
}

struct ArtifactLoadedFile {
    let localURL: URL
    let remoteMTime: Int64?
    let size: Int64
}

@MainActor
final class ArtifactContentLoader {
    nonisolated static let maximumFileBytes: Int64 = 64 * 1024 * 1024
    nonisolated static let cacheBudgetBytes: Int64 = 256 * 1024 * 1024
    let cacheDirectory: URL
    private let walkCache: @Sendable (URL) -> [String: Int64]
    private let abandonedPartials: Task<Partials, Never>
    private var reapedPartials = false
    private var reapedLegacyPartials = false
    private var liveLoads: [UUID: String] = [:]
    private var imageRefreshIDs: [String: UUID] = [:]

    private struct Partials {
        let downloads: [URL]
        let legacy: [URL]
    }

    private var partialsDirectory: URL { cacheDirectory.appendingPathComponent(".partials", isDirectory: true) }

    init(
        cacheDirectory: URL,
        walkCache: @escaping @Sendable (URL) -> [String: Int64] = { ArtifactContentLoader.cacheSizes(in: $0) }
    ) {
        self.cacheDirectory = cacheDirectory
        self.walkCache = walkCache
        abandonedPartials = Task.detached(priority: .utility) { Self.partialFiles(in: cacheDirectory) }
    }

    func localURL(for tab: ArtifactTab) -> URL {
        let basename = (tab.target.path as NSString).lastPathComponent
        return cacheDirectory.appendingPathComponent(ArtifactsCachePolicy.cacheKey(tab), isDirectory: true)
            .appendingPathComponent(basename.isEmpty || basename == "." || basename == ".." ? "artifact" : basename)
    }

    func cachedURL(for tab: ArtifactTab) -> URL? {
        let url = localURL(for: tab)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fetch(_ tab: ArtifactTab, bridge: any FileBridging, force: Bool = false) async throws -> ArtifactLoadedFile {
        guard bridge.state == .connected else { throw FileBridgeError.notConnected }
        let ownership = UUID()
        let key = ArtifactsCachePolicy.cacheKey(tab)
        liveLoads[ownership] = key
        defer { liveLoads[ownership] = nil }
        _ = await reapAbandonedPartials()
        try Task.checkCancellation()
        let entry = try await Self.stat(tab.target.path, bridge: bridge)
        guard entry.kind == .file || entry.kind == .symlink else {
            throw FileBridgeError.remoteOperationFailed(String(localized: "this path is not a regular file"))
        }
        if let size = entry.size, size > UInt64(Self.maximumFileBytes) {
            throw ArtifactContentLoadError.tooLarge(bytes: Int64(clamping: size))
        }
        let destination = localURL(for: tab)
        try prepareCache(destination.deletingLastPathComponent())
        let partial = partialsDirectory.appendingPathComponent("\(key)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await Self.download(tab.target.path, to: partial, bridge: bridge, maxBytes: Self.maximumFileBytes)
        try Task.checkCancellation()
        let size = try Self.size(of: partial)
        try replace(partial, destination: destination)
        if force, tab.target.viewer == .markdown { imageRefreshIDs[key] = UUID() }
        return ArtifactLoadedFile(localURL: destination, remoteMTime: entry.modified.map(Self.milliseconds), size: size)
    }

    @discardableResult
    func prepareImages(document: URL, remotePath: String, bridge: any FileBridging, force: Bool = false) async throws -> Bool {
        let key = document.deletingLastPathComponent().lastPathComponent
        let refreshID = imageRefreshIDs[key]
        let completed = try await MarkdownImageStaging.stage(document: document, remotePath: remotePath,
                                                           bridge: bridge, force: force || refreshID != nil)
        // A newer explicit refresh may have completed during staging.
        if completed, imageRefreshIDs[key] == refreshID { imageRefreshIDs[key] = nil }
        return completed
    }

    /// A caller-owned preview is copied, never moved or removed. Its mtime is
    /// unknown until a live stat; recording nil avoids inventing remote facts.
    func adopt(_ source: URL, for tab: ArtifactTab) throws -> ArtifactLoadedFile {
        let size = try Self.size(of: source)
        guard size <= Self.maximumFileBytes else { throw ArtifactContentLoadError.tooLarge(bytes: size) }
        let destination = localURL(for: tab)
        try prepareCache(destination.deletingLastPathComponent())
        if source.standardizedFileURL != destination.standardizedFileURL {
            let key = destination.deletingLastPathComponent().lastPathComponent
            let partial = partialsDirectory.appendingPathComponent("\(key)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: partial) }
            try FileManager.default.copyItem(at: source, to: partial)
            let copiedSize = try Self.size(of: partial)
            guard copiedSize <= Self.maximumFileBytes else { throw ArtifactContentLoadError.tooLarge(bytes: copiedSize) }
            try replace(partial, destination: destination)
        }
        try ArtifactsStateFile.protect(destination)
        return ArtifactLoadedFile(localURL: destination, remoteMTime: nil, size: try Self.size(of: destination))
    }

    func evict(tabs: [ArtifactTab], selectedID: String?, protectedKeys: Set<String> = [], budgetBytes: Int64 = ArtifactContentLoader.cacheBudgetBytes) async {
        await evict(budgetBytes: budgetBytes) { (tabs, selectedID, protectedKeys) }
    }

    func evict(
        budgetBytes: Int64 = ArtifactContentLoader.cacheBudgetBytes,
        evictableKeys: @MainActor () -> Set<String>? = { nil },
        state: @MainActor () -> (tabs: [ArtifactTab], selectedID: String?, protectedKeys: Set<String>)
    ) async {
        let legacyPartials = await reapAbandonedPartials()
        let allowedKeys = evictableKeys()
        if !reapedLegacyPartials, !legacyPartials.isEmpty {
            // Only eviction has the complete current tab list. A generated
            // legacy filename can also be an accepted document's real name.
            let retained = Set(state().tabs.flatMap { tab -> [String] in
                let document = localURL(for: tab)
                let key = document.deletingLastPathComponent().lastPathComponent
                return [document, MarkdownImageStaging.manifestURL(for: document)].map { key + "/" + $0.lastPathComponent }
            })
            for partial in legacyPartials {
                let key = partial.deletingLastPathComponent().lastPathComponent
                guard allowedKeys?.contains(key) ?? true else { continue }
                let identity = key + "/" + partial.lastPathComponent
                guard !retained.contains(identity) else { continue }
                try? FileManager.default.removeItem(at: partial)
            }
        }
        // Retry cleanup of older keys once their persisted references are
        // available; a fenced pass cannot declare that work complete.
        if allowedKeys == nil { reapedLegacyPartials = true }
        let directory = cacheDirectory
        let walkCache = walkCache
        let sizes = await Task.detached(priority: .utility) { walkCache(directory) }.value
        guard !Task.isCancelled else { return }
        // Selection, pins and ownership may have changed during the walk.
        // Decide and delete together on MainActor, without a suspension.
        let current = state()
        let allowedAtDecision = evictableKeys()
        var protected = current.protectedKeys.union(liveLoads.values)
            .union(current.tabs.filter { $0.id == current.selectedID }.map(ArtifactsCachePolicy.cacheKey))
        if let allowedAtDecision { protected.formUnion(Set(sizes.keys).subtracting(allowedAtDecision)) }
        let byKey = Dictionary(grouping: current.tabs, by: ArtifactsCachePolicy.cacheKey)
        let entries = sizes.map { key, size in
            ArtifactsCacheEntry(key: key, size: size,
                                viewedAt: byKey[key]?.map(\.viewedAt).max() ?? 0,
                                pinned: byKey[key]?.contains(where: \.pinned) ?? false)
        }
        for key in ArtifactsCachePolicy.evictions(entries, budgetBytes: budgetBytes, protectedKeys: protected) {
            removeCache(key: key)
        }
    }

    private func reapAbandonedPartials() async -> [URL] {
        guard !reapedPartials || !reapedLegacyPartials else { return [] }
        let partials = await abandonedPartials.value
        // Fetches cannot create a partial until this finishes. Synchronous
        // adoption has already renamed its partial before yielding MainActor.
        if !reapedPartials {
            for partial in partials.downloads { try? FileManager.default.removeItem(at: partial) }
            reapedPartials = true
        }
        return partials.legacy
    }

    nonisolated static func cacheSizes(in directory: URL) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for entry in cacheDirectories(in: directory) {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
            let files = FileManager.default.enumerator(at: entry, includingPropertiesForKeys: Array(keys))
            var bytes: Int64 = 0
            while let file = files?.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: keys), values.isDirectory != true else { continue }
                let sum = bytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
                bytes = sum.overflow ? Int64.max : sum.partialValue
            }
            sizes[entry.lastPathComponent] = bytes
        }
        return sizes
    }

    nonisolated private static func partialFiles(in directory: URL) -> Partials {
        let downloads = (try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent(".partials", isDirectory: true), includingPropertiesForKeys: nil
        )) ?? []
        let legacy = cacheDirectories(in: directory).flatMap { entry in
            ((try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                .filter { file in
                    let name = file.lastPathComponent
                    guard name.hasPrefix(".partial-"), let id = UUID(uuidString: String(name.dropFirst(9))) else { return false }
                    guard name == ".partial-\(id.uuidString)",
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                    return values.isRegularFile == true && values.isSymbolicLink != true
                }
        }
        return Partials(downloads: downloads, legacy: legacy)
    }

    nonisolated private static func cacheDirectories(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []).filter {
            guard let values = try? $0.resourceValues(forKeys: keys) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    func removeCache(for tab: ArtifactTab) { removeCache(key: ArtifactsCachePolicy.cacheKey(tab)) }

    private func removeCache(key: String) {
        // Keys come from the shared hash or our own directory enumeration.
        guard key == (key as NSString).lastPathComponent, !key.hasPrefix(".") else { return }
        imageRefreshIDs[key] = nil
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(key, isDirectory: true))
    }

    static func stat(_ path: String, bridge: any FileBridging) async throws -> RemoteFileEntry {
        guard bridge.state == .connected else { throw FileBridgeError.notConnected }
        do {
            return try await bridge.attributes(path)
        } catch FileBridgeError.remoteStatus(let code, _) where code == 2 {
            throw ArtifactContentLoadError.missing
        }
    }

    /// Progress cancellation bounds an unknown or growing file as well as a
    /// known size. The child owns cancellation, just like Markdown staging.
    static func download(_ path: String, to url: URL, bridge: any FileBridging, maxBytes: Int64) async throws {
        guard bridge.state == .connected else { throw FileBridgeError.notConnected }
        var oversized: Int64?
        let task = Task { @MainActor in
            try await bridge.download(remotePath: path, to: url) { count, total in
                if count > maxBytes || (total ?? 0) > maxBytes {
                    oversized = max(count, total ?? 0)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            try Task.checkCancellation()
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if let oversized { throw ArtifactContentLoadError.tooLarge(bytes: oversized) }
            throw error
        }
        if let oversized { throw ArtifactContentLoadError.tooLarge(bytes: oversized) }
        try Task.checkCancellation()
        let bytes = try size(of: url)
        guard bytes <= maxBytes else { throw ArtifactContentLoadError.tooLarge(bytes: bytes) }
    }

    nonisolated static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func prepareCache(_ directory: URL) throws {
        try ArtifactsStateFile.prepareDirectory(cacheDirectory.deletingLastPathComponent())
        try ArtifactsStateFile.prepareDirectory(cacheDirectory)
        try ArtifactsStateFile.prepareDirectory(partialsDirectory)
        try ArtifactsStateFile.prepareDirectory(directory)
    }

    private func replace(_ partial: URL, destination: URL) throws {
        try ArtifactsStateFile.protect(partial)
        // Same-volume rename is atomic and leaves the old copy intact on
        // failure. No reader can observe a partly downloaded replacement.
        guard Darwin.rename(partial.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        MarkdownImageStaging.documentReplaced(at: destination)
    }
}
