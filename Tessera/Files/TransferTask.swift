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

    var errorDescription: String? {
        switch self {
        case .missingHomeDirectory:
            return "Home directory is unavailable for paste upload."
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
            if Self.isCancellation(error) {
                item.phase = .cancelled
            } else if case .cancelled = item.phase {
                // Preserve an explicit user cancellation over a late error.
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
            try await bridge.upload(
                localURL: localURL,
                to: remotePath,
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
            try await bridge.upload(localURL: localURL, to: remotePath, progress: progress)
            try Task.checkCancellation()
            item.resolvedRemotePath = try await bridge.realPath(remotePath)
        }
    }

    private func finishActiveTransfer(itemID: UUID) {
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
