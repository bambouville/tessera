import Foundation

/// Main-actor bridge access satisfies the reader's Sendable boundary without
/// lending the bridge to a background executor. It never creates or connects it.
struct ArtifactFileBridgeReader: ArtifactRemoteReader {
    private let bridge: @MainActor @Sendable () -> (any FileBridging)?
    private let cachedRoot: (@MainActor @Sendable () async throws -> URL)?
    private let readLocalFile: @Sendable (URL, Int) throws -> Data

    init(
        cachedRoot: (@MainActor @Sendable () async throws -> URL)? = nil,
        readLocalFile: @escaping @Sendable (URL, Int) throws -> Data = { try Self.readFile($0, $1) },
        bridge: @escaping @MainActor @Sendable () -> (any FileBridging)?
    ) {
        self.bridge = bridge
        self.cachedRoot = cachedRoot
        self.readLocalFile = readLocalFile
    }

    func read(absolutePath: String, allowedRoot: String?, maxBytes: Int) async throws -> Data {
        try await readOnMain(absolutePath: absolutePath, allowedRoot: allowedRoot, maxBytes: maxBytes)
    }

    @MainActor
    private func readOnMain(absolutePath: String, allowedRoot: String?, maxBytes: Int) async throws -> Data {
        guard maxBytes > 0, maxBytes < Int.max else { throw ArtifactRemoteReadError.fileTooLarge(maxBytes: maxBytes) }
        try Task.checkCancellation()
        guard let bridge = bridge(), bridge.state == .connected else { throw FileBridgeError.notConnected }
        // Only the handler's exact root document has a nil allowedRoot. Its
        // accepted cache snapshot shares the loader's single bounded fetch.
        if allowedRoot == nil, let cachedRoot {
            let url = try await cachedRoot()
            try Task.checkCancellation()
            guard self.bridge() === bridge, bridge.state == .connected else { throw FileBridgeError.notConnected }
            return try await readLocal(url, maxBytes: maxBytes)
        }
        let canonicalPath = try await Self.realPath(absolutePath, bridge: bridge)
        if let allowedRoot {
            let root = try await Self.realPath(allowedRoot, bridge: bridge)
            let prefix = root == "/" ? "/" : root + "/"
            guard canonicalPath.utf8.elementsEqual(root.utf8) || canonicalPath.utf8.starts(with: prefix.utf8) else {
                throw ArtifactRemoteReadError.forbidden
            }
        }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-\(UUID().uuidString)")
        try ArtifactsStateFile.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("resource")
        do {
            let entry = try await ArtifactContentLoader.stat(canonicalPath, bridge: bridge)
            guard entry.kind == .file || entry.kind == .symlink else { throw ArtifactRemoteReadError.forbidden }
            if let size = entry.size, size > UInt64(maxBytes) {
                throw ArtifactRemoteReadError.fileTooLarge(maxBytes: maxBytes)
            }
            try await ArtifactContentLoader.download(
                canonicalPath, to: destination, bridge: bridge, maxBytes: Int64(maxBytes)
            )
            try Task.checkCancellation()
            return try await readLocal(destination, maxBytes: maxBytes)
        } catch ArtifactContentLoadError.tooLarge {
            throw ArtifactRemoteReadError.fileTooLarge(maxBytes: maxBytes)
        } catch ArtifactContentLoadError.missing {
            throw ArtifactRemoteReadError.notFound
        } catch FileBridgeError.remoteStatus(let code, _) where code == 2 {
            throw ArtifactRemoteReadError.notFound
        } catch FileBridgeError.remoteStatus(let code, _) where code == 3 {
            throw ArtifactRemoteReadError.forbidden
        }
    }

    private func readLocal(_ url: URL, maxBytes: Int) async throws -> Data {
        let readLocalFile = readLocalFile
        let read = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try readLocalFile(url, maxBytes)
            guard data.count <= maxBytes else { throw ArtifactRemoteReadError.fileTooLarge(maxBytes: maxBytes) }
            try Task.checkCancellation()
            return data
        }
        return try await withTaskCancellationHandler {
            let data = try await read.value
            try Task.checkCancellation()
            return data
        } onCancel: { read.cancel() }
    }

    @MainActor
    private static func realPath(_ path: String, bridge: any FileBridging) async throws -> String {
        do {
            var resolved = try await bridge.realPath(path)
            try Task.checkCancellation()
            guard resolved.hasPrefix("/"), !resolved.contains("\0") else { throw ArtifactRemoteReadError.notFound }
            while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
            return resolved
        } catch is CancellationError {
            throw CancellationError()
        } catch FileBridgeError.cancelled {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw ArtifactRemoteReadError.notFound
        }
    }

    private static func readFile(_ url: URL, _ maxBytes: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: maxBytes + 1) ?? Data()
    }
}
