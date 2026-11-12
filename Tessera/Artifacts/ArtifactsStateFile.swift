import CryptoKit
import Dispatch
import Foundation
import TesseraArtifactsCore

/// Device-local browser state. Bootstrap and continuity serialize explicit
/// models, so this directory is never part of either transfer.
@MainActor
final class ArtifactsStateFile {
    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var cacheDirectory: URL { directory.appendingPathComponent("cache", isDirectory: true) }
    private(set) var isLoadUnavailable = false

    private let sleep: @Sendable (UInt64) async throws -> Void
    private let writer: ArtifactsStateFileWriter
    private var generation: UInt64 = 0
    private var pending: ArtifactsStateSnapshot?
    private var saveTask: Task<Void, Never>?

    init(
        directory: URL = ArtifactsStateFile.defaultDirectory,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        encode: @escaping @Sendable (ArtifactsState) -> ArtifactsPersistenceFiles = { ArtifactsPersistence.split($0) },
        write: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        },
        blobRead: @escaping @Sendable (URL) throws -> Void = { _ in },
        readState: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        blobStat: @escaping @Sendable (URL) throws -> (isRegularFile: Bool, size: Int) = { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return ((attributes[.type] as? FileAttributeType) == .typeRegular,
                    (attributes[.size] as? NSNumber)?.intValue ?? -1)
        }
    ) {
        self.directory = directory
        self.sleep = sleep
        self.writer = ArtifactsStateFileWriter(directory: directory, encode: encode, write: write,
                                              blobRead: blobRead, readState: readState, blobStat: blobStat)
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("artifacts", isDirectory: true)
    }

    func load() -> ArtifactsState {
        let restored = writer.load()
        if isLoadUnavailable, restored != nil {
            // Recovery replaces the temporary in-memory state. A snapshot
            // scheduled while fenced must not overwrite that restore later.
            saveTask?.cancel()
            saveTask = nil
            pending = nil
        }
        isLoadUnavailable = restored == nil
        return restored ?? ArtifactsState()
    }

    func schedule(_ state: ArtifactsState) {
        generation += 1
        pending = ArtifactsStateSnapshot(state: state, generation: generation)
        saveTask?.cancel()
        let sleep = self.sleep
        saveTask = Task { @MainActor [weak self] in
            do { try await sleep(500_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self?.writePending()
        }
    }

    /// Synchronous so scenePhase's background edge finishes the write before
    /// returning. Keep pending state after an I/O failure for the next flush.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let pending else { return }
        if writer.flush(pending) { self.pending = nil }
    }

    private func writePending() {
        guard let snapshot = pending else { return }
        writer.enqueue(snapshot) { [weak self] succeeded in
            Task { @MainActor [weak self] in
                guard succeeded, self?.pending?.generation == snapshot.generation else { return }
                self?.pending = nil
            }
        }
    }

    nonisolated static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try protect(url)
    }

    nonisolated static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }
}

private struct ArtifactsStateSnapshot: Sendable {
    var state: ArtifactsState
    var generation: UInt64
}

/// All encoding, blob validation, writes and collection share one executor.
/// Even synchronous flush dispatches asynchronously and waits: queue.sync may
/// execute its block on the calling main thread.
private final class ArtifactsStateFileWriter: @unchecked Sendable {
    private let directory: URL
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var changesDirectory: URL { directory.appendingPathComponent("changes", isDirectory: true) }
    private let encode: @Sendable (ArtifactsState) -> ArtifactsPersistenceFiles
    private let write: @Sendable (Data, URL) throws -> Void
    private let blobRead: @Sendable (URL) throws -> Void
    private let readState: @Sendable (URL) throws -> Data
    private let blobStat: @Sendable (URL) throws -> (isRegularFile: Bool, size: Int)
    private let queue = DispatchQueue(label: "com.bambouville.tessera.artifacts.persistence", qos: .utility)
    private var savedGeneration: UInt64 = 0
    private var verifiedDigests: Set<String> = []
    private var loadUnavailable = false

    init(directory: URL, encode: @escaping @Sendable (ArtifactsState) -> ArtifactsPersistenceFiles,
         write: @escaping @Sendable (Data, URL) throws -> Void,
         blobRead: @escaping @Sendable (URL) throws -> Void,
         readState: @escaping @Sendable (URL) throws -> Data,
         blobStat: @escaping @Sendable (URL) throws -> (isRegularFile: Bool, size: Int)) {
        self.directory = directory
        self.encode = encode
        self.write = write
        self.blobRead = blobRead
        self.readState = readState
        self.blobStat = blobStat
    }

    func enqueue(_ snapshot: ArtifactsStateSnapshot, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { completion(self.save(snapshot)) }
    }

    func flush(_ snapshot: ArtifactsStateSnapshot) -> Bool {
        synchronously { self.save(snapshot) }
    }

    func load() -> ArtifactsState? {
        synchronously {
            let data: Data
            do {
                data = try self.readState(self.stateURL)
            } catch {
                self.loadUnavailable = !Self.isAbsent(error)
                if self.loadUnavailable { return nil }
                self.verifiedDigests.removeAll()
                return ArtifactsState()
            }
            var blobs: [String: String] = [:]
            var rejected: [URL] = []
            for digest in ArtifactsPersistence.blobDigests(data) {
                let url = self.changesDirectory.appendingPathComponent(digest + ".diff")
                do {
                    if let diff = try self.readBlob(url, digest: digest) { blobs[digest] = diff }
                    else { rejected.append(url) }
                } catch {
                    if Self.isAbsent(error) { continue }
                    self.loadUnavailable = true
                    return nil
                }
            }
            // Validate the entire restore before deleting anything: a later
            // blob may be temporarily unreadable (for example before unlock).
            for url in rejected { try? FileManager.default.removeItem(at: url) }
            self.verifiedDigests = Set(blobs.keys)
            self.loadUnavailable = false
            return ArtifactsPersistence.join(data, blobs: blobs)
        }
    }

    private static func isAbsent(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue))
    }

    private func synchronously<T>(_ operation: @escaping () -> T) -> T {
        var result: T?
        let work = DispatchWorkItem { result = operation() }
        queue.async(execute: work)
        work.wait()
        return result!
    }

    private func save(_ snapshot: ArtifactsStateSnapshot) -> Bool {
        guard !loadUnavailable else { return false }
        guard snapshot.generation > savedGeneration else { return true }
        do {
            let files = encode(snapshot.state)
            try ArtifactsStateFile.prepareDirectory(directory)
            if !files.blobs.isEmpty { try ArtifactsStateFile.prepareDirectory(changesDirectory) }
            for digest in files.blobs.keys.sorted() {
                let url = changesDirectory.appendingPathComponent(digest + ".diff")
                if verifiedDigests.contains(digest) {
                    do {
                        let values = try blobStat(url)
                        if values.isRegularFile, values.size == files.blobs[digest]!.utf8.count { continue }
                        if !values.isRegularFile { try FileManager.default.removeItem(at: url) }
                    } catch {
                        if !Self.isAbsent(error) { throw error }
                    }
                    verifiedDigests.remove(digest)
                } else {
                    do {
                        if try readBlob(url, digest: digest) != nil {
                            verifiedDigests.insert(digest)
                            continue
                        }
                    } catch {
                        if !Self.isAbsent(error) { throw error }
                    }
                }
                try write(Data(files.blobs[digest]!.utf8), url)
                try ArtifactsStateFile.protect(url)
                verifiedDigests.insert(digest)
            }
            try write(Data(files.stateJSON.utf8), stateURL)
            try ArtifactsStateFile.protect(stateURL)
            // Collection only follows a successful manifest replacement.
            let referenced = Set(files.blobs.keys)
            verifiedDigests.formIntersection(referenced)
            let existing = (try? FileManager.default.contentsOfDirectory(at: changesDirectory,
                                                                       includingPropertiesForKeys: nil)) ?? []
            for url in existing where url.pathExtension == "diff" {
                let digest = url.deletingPathExtension().lastPathComponent
                if ArtifactsPersistence.isBlobDigest(digest), !referenced.contains(digest) {
                    try FileManager.default.removeItem(at: url)
                    verifiedDigests.remove(digest)
                }
            }
            savedGeneration = snapshot.generation
            return true
        } catch {
            NSLog("Artifacts: state write failed: %@", error.localizedDescription)
            return false
        }
    }

    private func readBlob(_ url: URL, digest: String) throws -> String? {
        let limit = ArtifactsPersistence.maximumDiffBytes
        let values = try blobStat(url)
        guard values.isRegularFile, values.size >= 0, values.size <= limit else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try blobRead(url)
        var data = Data()
        while data.count <= limit {
            guard let bytes = try handle.read(upToCount: limit + 1 - data.count), !bytes.isEmpty else { break }
            data.append(bytes)
        }
        guard data.count <= limit, let diff = String(data: data, encoding: .utf8),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { return nil }
        return diff
    }
}
