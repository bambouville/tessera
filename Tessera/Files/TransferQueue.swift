// Tessera/Files/TransferQueue.swift
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation
import Observation

@MainActor
@Observable
final class TransferQueue: TransferQueueing {
    let bridge: any FileBridging

    /// Items are stored oldest-first. The queue drains in this order, and
    /// the panel can render the newest rows with `items.suffix(...)`.
    private(set) var items: [TransferItem] = []

    @ObservationIgnored var operations: [UUID: TransferOperation] = [:]
    @ObservationIgnored var activeTask: Task<Void, Never>?
    @ObservationIgnored var activeItemID: UUID?
    @ObservationIgnored var reservedPasteFilenames: Set<String> = []
    /// The paste-file reaper runs once per queue lifetime, piggybacked
    /// on the first transfer's bridge connect (see TransferTask).
    @ObservationIgnored var didScheduleReaper = false

    var hasActive: Bool {
        items.contains { $0.phase.isActive }
    }

    init(bridge: any FileBridging) {
        self.bridge = bridge
    }

    @discardableResult
    func enqueueDownload(
        remotePath: String,
        displayName: String,
        to localURL: URL
    ) -> TransferItem {
        let item = TransferItem(
            direction: .download,
            displayName: displayName,
            remotePath: remotePath,
            localURL: localURL
        )
        items.append(item)
        operations[item.id] = .download(remotePath: remotePath, localURL: localURL)
        startDrainIfNeeded()
        return item
    }

    @discardableResult
    func enqueueUpload(
        localURL: URL,
        toDirectory remoteDirectory: String
    ) -> TransferItem {
        let remotePath = Self.remoteJoinedPath(
            directory: remoteDirectory,
            filename: localURL.lastPathComponent
        )
        let item = TransferItem(
            direction: .upload,
            displayName: localURL.lastPathComponent,
            remotePath: remotePath,
            localURL: localURL
        )
        items.append(item)
        operations[item.id] = .upload(localURL: localURL, remotePath: remotePath)
        startDrainIfNeeded()
        return item
    }

    @discardableResult
    func enqueuePasteUpload(localURL: URL) -> TransferItem {
        let filename = makePasteFilename(for: localURL)
        let item = TransferItem(
            direction: .upload,
            displayName: filename,
            remotePath: pasteDirectoryPath(),
            localURL: localURL
        )
        items.append(item)
        operations[item.id] = .pasteUpload(localURL: localURL, filename: filename)
        startDrainIfNeeded()
        return item
    }

    func cancel(_ item: TransferItem) {
        guard items.contains(where: { $0.id == item.id }) else {
            return
        }

        switch item.phase {
        case .queued, .running:
            item.phase = .cancelled
        case .completed, .failed, .cancelled:
            return
        }

        if activeItemID == item.id {
            activeTask?.cancel()
        } else {
            operations.removeValue(forKey: item.id)
            startDrainIfNeeded()
        }
    }

    func clearFinished() {
        let finishedIDs = Set(items.filter { $0.phase.isFinished }.map(\.id))
        guard !finishedIDs.isEmpty else {
            return
        }
        items.removeAll { finishedIDs.contains($0.id) }
        for id in finishedIDs {
            operations.removeValue(forKey: id)
        }
    }
}

private extension TransferPhase {
    var isActive: Bool {
        switch self {
        case .queued, .running:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .running:
            return false
        }
    }
}
