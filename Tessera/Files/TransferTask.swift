// Tessera/Files/TransferTask.swift
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation

enum TransferOperation {
    case download(remotePath: String, localURL: URL)
    case upload(localURL: URL, remotePath: String)
    case pasteUpload(localURL: URL, filename: String)
}

private enum TransferQueueExecutionError: LocalizedError {
    case missingHomeDirectory
    case cleanupDeferred(String)

    var errorDescription: String? {
        switch self {
        case .missingHomeDirectory:
            return String(localized: "Home directory is unavailable for paste upload.")
        case .cleanupDeferred(let path):
            return String(localized: "The upload stopped, but cleanup of the temporary remote file will retry on the next connection: \(path)")
        }
    }
}

private struct PendingRemoteUploadCleanup: Codable, Equatable {
    let id: UUID
    let hostID: UUID?
    let user: String
    let address: String
    let port: Int
    let jumpPath: [String]
    let remotePath: String
    /// When present, `remotePath` is a recoverable copy of the previous
    /// destination. A retry restores it if the destination is absent, or
    /// removes it after the replacement is known to be visible.
    let restoreToRemotePath: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        key: FileBridgeKey,
        remotePath: String,
        restoreToRemotePath: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.hostID = key.hostID
        self.user = key.user
        self.address = key.address
        self.port = key.port
        self.jumpPath = key.jumpPath
        self.remotePath = remotePath
        self.restoreToRemotePath = restoreToRemotePath
        self.createdAt = createdAt
    }

    func matches(_ key: FileBridgeKey) -> Bool {
        hostID == key.hostID
            && user == key.user
            && address == key.address
            && port == key.port
            && jumpPath == key.jumpPath
    }
}

@MainActor
private enum RemoteUploadCleanupJournal {
    private static let defaultsKey = "tessera.files.pendingRemoteUploadCleanup.v1"
    private static let maximumRecords = 256
    /// Records owned by transfers in this process. Opportunistic cleanup when
    /// Files opens must never unlink a partial that is still being written.
    private static var activeRecordIDs: Set<UUID> = []

    static func inactiveRecords(for key: FileBridgeKey) -> [PendingRemoteUploadCleanup] {
        load().filter { $0.matches(key) && !activeRecordIDs.contains($0.id) }
    }

    @discardableResult
    static func register(
        key: FileBridgeKey,
        remotePath: String,
        restoreToRemotePath: String? = nil
    ) -> UUID {
        var records = load()
        let record = PendingRemoteUploadCleanup(
            key: key,
            remotePath: remotePath,
            restoreToRemotePath: restoreToRemotePath
        )
        records.append(record)
        if records.count > maximumRecords {
            records.removeFirst(records.count - maximumRecords)
        }
        save(records)
        activeRecordIDs.insert(record.id)
        return record.id
    }

    static func deactivate(_ id: UUID) {
        activeRecordIDs.remove(id)
    }

    static func remove(_ id: UUID) {
        activeRecordIDs.remove(id)
        var records = load()
        records.removeAll { $0.id == id }
        save(records)
    }

    private static func load() -> [PendingRemoteUploadCleanup] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingRemoteUploadCleanup].self, from: data)) ?? []
    }

    private static func save(_ records: [PendingRemoteUploadCleanup]) {
        if records.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

extension TransferQueue {
    func startDrainIfNeeded() {
        guard activeTask == nil else {
            return
        }
        guard let next = items.first(where: { item in
            item.phase == .queued && operations[item.id] != nil
        }) else {
            return
        }

        let itemID = next.id
        activeItemID = itemID
        activeTask = Task { @MainActor [weak self] in
            await self?.runTransfer(itemID: itemID)
        }
    }

    /// Fire-and-forget reap of aged paste files — the "temp ·
    /// auto-cleans after N d" promise in the Upload sheet and Files
    /// settings. Runs on every FRESH bridge dial (`freshConnect`) and
    /// at most once per already-open connection otherwise: the old
    /// once-per-queue-lifetime latch meant a file aging PAST the
    /// threshold mid-run was never collected until the app restarted.
    /// Days from the user pref; 0 (Off) disables.
    func scheduleReaperIfNeeded(freshConnect: Bool) {
        guard freshConnect || !didScheduleReaper else { return }
        didScheduleReaper = true
        let stored = UserDefaults.standard.object(forKey: RemoteFilesConstants.reaperDaysKey) as? Int
        let days = stored ?? RemoteFilesConstants.defaultReaperDays
        Task { await reapStalePasteFiles(olderThanDays: days) }
    }

    func reapStalePasteFiles(olderThanDays days: Int) async {
        guard days > 0 else {
            DiagnosticLogStore.appendApp("paste-reaper skipped: cleanup Off")
            return
        }
        guard let homeDirectory = bridge.homeDirectory else {
            DiagnosticLogStore.appendApp("paste-reaper skipped: no home directory yet")
            return
        }
        let tempDirectory = Self.remoteJoinedPath(
            directory: homeDirectory,
            filename: RemoteFilesConstants.tempDirectory
        )
        let payload = "find \(Self.posixQuoted(tempDirectory)) -maxdepth 1 "
            + "-name \(Self.posixQuoted(RemoteFilesConstants.pastePrefix + "*")) "
            + "-mtime +\(days) -delete 2>/dev/null; exit 0"
        do {
            _ = try await bridge.exec(Self.posixWrapped(payload), inShell: false)
            DiagnosticLogStore.appendApp("paste-reaper ran: \(RemoteFilesConstants.pastePrefix)* older than \(days) d")
        } catch {
            DiagnosticLogStore.appendApp("paste-reaper failed: \(error.localizedDescription)")
        }
    }

    func makePasteFilename(for localURL: URL, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let extensionPart: String
        let pathExtension = localURL.pathExtension
        if pathExtension.isEmpty {
            extensionPart = ""
        } else {
            extensionPart = ".\(pathExtension)"
        }

        let stamp = formatter.string(from: now)
        var candidate: String
        repeat {
            let suffix = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
            candidate = "\(RemoteFilesConstants.pastePrefix)\(stamp)-\(suffix)\(extensionPart)"
        } while reservedPasteFilenames.contains(candidate)

        reservedPasteFilenames.insert(candidate)
        return candidate
    }

    func pasteDirectoryPath() -> String {
        guard let homeDirectory = bridge.homeDirectory else {
            return RemoteFilesConstants.tempDirectory
        }
        return Self.remoteJoinedPath(
            directory: homeDirectory,
            filename: RemoteFilesConstants.tempDirectory
        )
    }

    static func remoteJoinedPath(directory: String, filename: String) -> String {
        guard !directory.isEmpty else {
            return filename
        }
        var directory = directory
        while directory.count > 1 && directory.hasSuffix("/") {
            directory.removeLast()
        }
        if directory == "/" {
            return "/\(filename)"
        }
        return "\(directory)/\(filename)"
    }

    private func runTransfer(itemID: UUID) async {
        guard let item = items.first(where: { $0.id == itemID }),
              let operation = operations[itemID]
        else {
            finishActiveTransfer(itemID: itemID)
            return
        }

        item.phase = .running(fraction: nil)

        let progress: TransferProgressHandler = { [weak self] transferredBytes, totalBytes in
            guard !Task.isCancelled,
                  let self,
                  let currentItem = self.items.first(where: { $0.id == itemID }),
                  case .running = currentItem.phase
            else {
                return
            }
            currentItem.phase = .running(
                fraction: Self.progressFraction(
                    transferredBytes: transferredBytes,
                    totalBytes: totalBytes
                )
            )
        }

        do {
            try Task.checkCancellation()
            let wasConnected = bridge.state == .connected
            try await bridge.connect()
            scheduleReaperIfNeeded(freshConnect: !wasConnected)
            await retryPendingRemoteUploadCleanups()
            try Task.checkCancellation()
            try await execute(operation, for: item, progress: progress)
            try Task.checkCancellation()
            if case .cancelled = item.phase {
                // `cancel(_:)` wins over a bridge that returns after its
                // transfer task was cancelled.
            } else {
                item.phase = .completed
            }
        } catch {
            if let cleanupFailureMessage = item.cleanupFailureMessage {
                item.phase = .failed(cleanupFailureMessage)
            } else if Self.isCancellation(error) || item.cancellationReason != nil {
                item.phase = item.cancellationReason?.failureMessage.map(TransferPhase.failed)
                    ?? .cancelled
            } else {
                item.phase = .failed(Self.message(for: error))
            }
        }

        finishActiveTransfer(itemID: itemID)
    }

    private func execute(
        _ operation: TransferOperation,
        for item: TransferItem,
        progress: @escaping TransferProgressHandler
    ) async throws {
        switch operation {
        case .download(let remotePath, let localURL):
            try await bridge.download(
                remotePath: remotePath,
                to: localURL,
                progress: progress
            )

        case .upload(let localURL, let remotePath):
            try await performStagedUpload(
                localURL: localURL,
                finalRemotePath: remotePath,
                item: item,
                progress: progress
            )
            item.resolvedRemotePath = remotePath

        case .pasteUpload(let localURL, let filename):
            guard let homeDirectory = bridge.homeDirectory else {
                throw TransferQueueExecutionError.missingHomeDirectory
            }
            let tempDirectory = Self.remoteJoinedPath(
                directory: homeDirectory,
                filename: RemoteFilesConstants.tempDirectory
            )
            try Task.checkCancellation()
            try await bridge.exec(
                Self.posixWrapped("mkdir -p \(Self.posixQuoted(tempDirectory))"),
                inShell: false
            )
            try Task.checkCancellation()

            let remotePath = Self.remoteJoinedPath(directory: tempDirectory, filename: filename)
            try await performStagedUpload(
                localURL: localURL,
                finalRemotePath: remotePath,
                item: item,
                progress: progress
            )
            // `homeDirectory` is already canonical and `remotePath` is
            // absolute. Avoid a post-commit network round trip that could be
            // cancelled after the file is already visible remotely.
            item.resolvedRemotePath = remotePath
        }
    }

    private func performStagedUpload(
        localURL: URL,
        finalRemotePath: String,
        item: TransferItem,
        progress: @escaping TransferProgressHandler
    ) async throws {
        let stagingPath = Self.remoteUploadStagingPath(for: finalRemotePath)
        let finalEntryBeforeUpload = try await remoteEntry(at: finalRemotePath)
        switch finalEntryBeforeUpload?.kind {
        case .directory:
            throw FileBridgeError.remoteOperationFailed(
                String(localized: "The upload destination is a directory.")
            )
        case .other:
            throw FileBridgeError.remoteOperationFailed(
                String(localized: "The upload destination isn't a regular file.")
            )
        case .symlink:
            // Preserve the pre-staging behavior: SFTP open/truncate follows
            // the link and updates its target without replacing the link.
            // Deliberately do not realpath/readlink and reconstruct a target:
            // keeping the user-selected path avoids cross-directory target
            // validation and path-swap races. Atomic rename cannot preserve a
            // symlink inode, so this compatibility path alone is in-place.
            try await bridge.upload(
                localURL: localURL,
                to: finalRemotePath,
                progress: progress
            )
            return
        case .file:
            guard finalEntryBeforeUpload?.permissions != nil else {
                throw FileBridgeError.remoteOperationFailed(
                    String(localized: "The upload destination permissions couldn't be verified.")
                )
            }
        case .none:
            break
        }
        let cleanupID = RemoteUploadCleanupJournal.register(
            key: bridge.key,
            remotePath: stagingPath
        )
        do {
            try await bridge.upload(
                localURL: localURL,
                to: stagingPath,
                progress: progress
            )
            if let permissions = finalEntryBeforeUpload?.permissions {
                try await bridge.setPermissions(permissions, at: stagingPath)
            }
            try Task.checkCancellation()
            item.isFinalizingUpload = true
            try await commitStagedUpload(
                stagingPath: stagingPath,
                finalPath: finalRemotePath
            )
            RemoteUploadCleanupJournal.remove(cleanupID)
        } catch {
            do {
                try await Self.removeRemoteStagingFile(stagingPath, using: bridge)
                RemoteUploadCleanupJournal.remove(cleanupID)
            } catch {
                let message = TransferQueueExecutionError.cleanupDeferred(stagingPath)
                    .errorDescription ?? error.localizedDescription
                item.cleanupFailureMessage = message
                RemoteUploadCleanupJournal.deactivate(cleanupID)
                DiagnosticLogStore.appendApp(
                    "upload cleanup deferred path=\(stagingPath) error=\(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    /// SFTP-only commit path. Ordinary uploads worked on ForceCommand
    /// internal-sftp accounts before staged cancellation was added, so commit
    /// and cleanup must not introduce a shell-exec requirement.
    private func commitStagedUpload(
        stagingPath: String,
        finalPath: String
    ) async throws {
        do {
            try await bridge.rename(from: stagingPath, to: finalPath)
        } catch let renameError {
            // An SSH/SFTP reply can be lost after the server applied rename.
            // Reconnect and inspect both names before calling the upload a
            // failure; a missing staging file plus present final file is a
            // committed upload, not a reason to create a duplicate paste file.
            if try await reconcileCommittedRename(
                stagingPath: stagingPath,
                finalPath: finalPath
            ) {
                return
            }
            if try await remoteEntry(at: stagingPath) != nil,
               try await remoteEntry(at: finalPath) != nil {
                try await replaceExistingFile(
                    stagingPath: stagingPath,
                    finalPath: finalPath
                )
                return
            }
            throw renameError
        }
    }

    /// SFTP v3 servers are allowed to reject rename-over-existing. Preserve
    /// the old destination under a unique sibling, move the completed staging
    /// file into place, then remove the backup. The journal makes every
    /// acknowledgement-loss point recoverable on the next connection.
    private func replaceExistingFile(
        stagingPath: String,
        finalPath: String
    ) async throws {
        let backupPath = Self.remoteUploadReplacementBackupPath(for: finalPath)
        let backupID = RemoteUploadCleanupJournal.register(
            key: bridge.key,
            remotePath: backupPath,
            restoreToRemotePath: finalPath
        )
        // Every exit must make a still-journaled backup eligible for recovery.
        // This also covers connection loss while probing an ambiguous rename.
        defer { RemoteUploadCleanupJournal.deactivate(backupID) }

        do {
            do {
                try await bridge.rename(from: finalPath, to: backupPath)
            } catch let moveError {
                let finalExists = try await remoteEntry(at: finalPath) != nil
                let backupExists = try await remoteEntry(at: backupPath) != nil
                guard !finalExists, backupExists else {
                    if !backupExists {
                        RemoteUploadCleanupJournal.remove(backupID)
                    } else {
                        RemoteUploadCleanupJournal.deactivate(backupID)
                    }
                    throw moveError
                }
            }

            do {
                try await bridge.rename(from: stagingPath, to: finalPath)
            } catch let replacementError {
                if try await reconcileCommittedRename(
                    stagingPath: stagingPath,
                    finalPath: finalPath
                ) {
                    await settleReplacementBackup(
                        id: backupID,
                        backupPath: backupPath,
                        finalPath: finalPath
                    )
                    return
                }
                do {
                    try await Self.recoverReplacementBackup(
                        backupPath: backupPath,
                        finalPath: finalPath,
                        using: bridge
                    )
                    RemoteUploadCleanupJournal.remove(backupID)
                } catch {
                    RemoteUploadCleanupJournal.deactivate(backupID)
                    DiagnosticLogStore.appendApp(
                        "upload replacement recovery deferred backup=\(backupPath) final=\(finalPath) error=\(error.localizedDescription)"
                    )
                }
                throw replacementError
            }

            await settleReplacementBackup(
                id: backupID,
                backupPath: backupPath,
                finalPath: finalPath
            )
        } catch {
            throw error
        }
    }

    private func settleReplacementBackup(
        id: UUID,
        backupPath: String,
        finalPath: String
    ) async {
        do {
            try await Self.recoverReplacementBackup(
                backupPath: backupPath,
                finalPath: finalPath,
                using: bridge
            )
            RemoteUploadCleanupJournal.remove(id)
        } catch {
            RemoteUploadCleanupJournal.deactivate(id)
            DiagnosticLogStore.appendApp(
                "upload replacement cleanup deferred backup=\(backupPath) error=\(error.localizedDescription)"
            )
        }
    }

    private func reconcileCommittedRename(
        stagingPath: String,
        finalPath: String
    ) async throws -> Bool {
        if bridge.state != .connected {
            try await bridge.connect()
        }
        let stagingEntry = try await remoteEntry(at: stagingPath)
        let finalEntry = try await remoteEntry(at: finalPath)
        if stagingEntry == nil, finalEntry != nil {
            return true
        }
        // If both names remain, the server rejected replace-in-place. The
        // caller can use the recoverable backup/swap path.
        _ = stagingEntry
        return false
    }

    private func remoteEntry(at path: String) async throws -> RemoteFileEntry? {
        let components = Self.remotePathComponents(path)
        return try await bridge.listDirectory(components.directory)
            .first { $0.name == components.filename }
    }

    private func retryPendingRemoteUploadCleanups() async {
        await Self.retryPendingRemoteUploadCleanups(using: bridge)
    }

    static func retryPendingRemoteUploadCleanups(using bridge: any FileBridging) async {
        for record in RemoteUploadCleanupJournal.inactiveRecords(for: bridge.key) {
            do {
                if let finalPath = record.restoreToRemotePath {
                    try await recoverReplacementBackup(
                        backupPath: record.remotePath,
                        finalPath: finalPath,
                        using: bridge
                    )
                } else {
                    try await removeRemoteStagingFile(record.remotePath, using: bridge)
                }
                RemoteUploadCleanupJournal.remove(record.id)
                DiagnosticLogStore.appendApp(
                    "upload cleanup retry succeeded path=\(record.remotePath)"
                )
            } catch {
                DiagnosticLogStore.appendApp(
                    "upload cleanup retry deferred path=\(record.remotePath) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private static func removeRemoteStagingFile(
        _ path: String,
        using bridge: any FileBridging
    ) async throws {
        // Cleanup must not inherit the cancelled upload task. The production
        // bridge correctly checks Task cancellation; issuing SFTP remove
        // directly from the cancelled catch path would therefore abort before
        // reaching the host and leave the partial behind.
        do {
            try await Task { @MainActor in
                if bridge.state != .connected {
                    try await bridge.connect()
                }
                try await bridge.removeFile(path)
            }.value
        } catch let removalError {
            // SFTP remove is not `rm -f`: a missing path is an error. Confirm
            // absence and clear the journal rather than retrying forever.
            let components = remotePathComponents(path)
            let stillExists = try await Task { @MainActor in
                if bridge.state != .connected {
                    try await bridge.connect()
                }
                return try await bridge.listDirectory(components.directory)
                    .contains { $0.name == components.filename }
            }.value
            if !stillExists { return }
            throw removalError
        }
    }

    private static func recoverReplacementBackup(
        backupPath: String,
        finalPath: String,
        using bridge: any FileBridging
    ) async throws {
        if bridge.state != .connected {
            try await bridge.connect()
        }
        let backupComponents = remotePathComponents(backupPath)
        let finalComponents = remotePathComponents(finalPath)
        let backupExists = try await bridge.listDirectory(backupComponents.directory)
            .contains { $0.name == backupComponents.filename }
        guard backupExists else { return }
        let finalExists = try await bridge.listDirectory(finalComponents.directory)
            .contains { $0.name == finalComponents.filename }
        if finalExists {
            try await removeRemoteStagingFile(backupPath, using: bridge)
            return
        }

        do {
            try await bridge.rename(from: backupPath, to: finalPath)
        } catch let restoreError {
            let backupStillExists = try await bridge.listDirectory(backupComponents.directory)
                .contains { $0.name == backupComponents.filename }
            let finalNowExists = try await bridge.listDirectory(finalComponents.directory)
                .contains { $0.name == finalComponents.filename }
            if !backupStillExists, finalNowExists { return }
            throw restoreError
        }
    }

    private func finishActiveTransfer(itemID: UUID) {
        if let item = items.first(where: { $0.id == itemID }) {
            recordBackgroundOutcomeIfNeeded(for: item)
        }
        operations.removeValue(forKey: itemID)
        if activeItemID == itemID {
            activeItemID = nil
            activeTask = nil
        }
        startDrainIfNeeded()
    }

    private static func progressFraction(
        transferredBytes: Int64,
        totalBytes: Int64?
    ) -> Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }

    private static func remoteUploadStagingPath(for finalPath: String) -> String {
        let components = remotePathComponents(finalPath)
        let directory = components.directory
        let filename = components.filename
        let safeName = filename.isEmpty ? "upload" : filename
        let stagingName = ".\(safeName).tessera-upload-\(UUID().uuidString.lowercased()).partial"
        return remoteJoinedPath(directory: directory.isEmpty ? "/" : directory, filename: stagingName)
    }

    private static func remoteUploadReplacementBackupPath(for finalPath: String) -> String {
        let components = remotePathComponents(finalPath)
        let safeName = components.filename.isEmpty ? "upload" : components.filename
        let backupName = ".\(safeName).tessera-replaced-\(UUID().uuidString.lowercased()).backup"
        return remoteJoinedPath(
            directory: components.directory.isEmpty ? "/" : components.directory,
            filename: backupName
        )
    }

    private static func remotePathComponents(_ path: String) -> (directory: String, filename: String) {
        guard let slash = path.lastIndex(of: "/") else {
            return (".", path)
        }
        let rawDirectory = String(path[..<slash])
        let directory = rawDirectory.isEmpty ? "/" : rawDirectory
        let filename = String(path[path.index(after: slash)...])
        return (directory, filename)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let bridgeError = error as? FileBridgeError, bridgeError == .cancelled {
            return true
        }
        return false
    }

    private static func message(for error: Error) -> String {
        if let bridgeError = error as? FileBridgeError,
           let description = bridgeError.errorDescription {
            return description
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func posixQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func posixWrapped(_ payload: String) -> String {
        "sh -c '" + payload.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
