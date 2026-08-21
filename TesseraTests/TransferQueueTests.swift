import XCTest
import Observation
@testable import Tessera

final class TransferQueueTests: XCTestCase {
    @MainActor
    func test_downloadLifecycleReportsProgressAndWritesFile() async throws {
        let bridge = ProgressHoldingBridge()
        let queue = TransferQueue(bridge: bridge)
        let destination = try temporaryURL(filename: "download.txt")

        let item = queue.enqueueDownload(
            remotePath: "/home/mock/readme.txt",
            displayName: "readme.txt",
            to: destination
        )

        XCTAssertEqual(item.phase, .queued)
        await assertEventually { item.phase == .running(fraction: nil) }
        await assertEventually {
            if case .running(let fraction) = item.phase {
                return fraction == 1
            }
            return false
        }
        await assertEventually { item.phase == .completed }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "contents\n")
    }

    @MainActor
    func test_uploadSetsResolvedRemotePath() async throws {
        let bridge = RecordingUploadBridge()
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "notes.txt", contents: "hello")

        let item = queue.enqueueUpload(
            localURL: localURL,
            toDirectory: "/home/mock/projects/dashboard"
        )

        await assertEventually { item.phase == .completed }
        XCTAssertEqual(
            item.resolvedRemotePath,
            "/home/mock/projects/dashboard/notes.txt"
        )
        let uploadedPath = try XCTUnwrap(bridge.uploadedPaths.first)
        XCTAssertTrue(uploadedPath.hasPrefix("/home/mock/projects/dashboard/.notes.txt.tessera-upload-"))
        XCTAssertTrue(uploadedPath.hasSuffix(".partial"))
        XCTAssertFalse(bridge.uploadedPaths.contains(item.resolvedRemotePath ?? ""))
        XCTAssertTrue(bridge.renamedPaths.contains {
            $0.from == uploadedPath && $0.to == "/home/mock/projects/dashboard/notes.txt"
        })
        XCTAssertFalse(bridge.executedCommands.contains {
            $0.contains("mv ") || $0.contains("rm ")
        }, "upload commit and cancellation cleanup must stay on SFTP")
    }

    @MainActor
    func test_pasteUploadGeneratesDistinctNamesUnderTempDirectory() async throws {
        let bridge = RecordingUploadBridge()
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "clip.txt", contents: "paste")

        let first = queue.enqueuePasteUpload(localURL: localURL)
        let second = queue.enqueuePasteUpload(localURL: localURL)

        await assertEventually { first.phase == .completed && second.phase == .completed }

        let firstPath = try XCTUnwrap(first.resolvedRemotePath)
        let secondPath = try XCTUnwrap(second.resolvedRemotePath)
        XCTAssertTrue(firstPath.hasPrefix("/home/mock/.cache/tessera/"))
        XCTAssertTrue(secondPath.hasPrefix("/home/mock/.cache/tessera/"))
        XCTAssertNotEqual(firstPath, secondPath)

        let pattern = #"^paste-\d{8}-\d{6}-[0-9a-f]{4}(\.txt)?$"#
        let firstName = (firstPath as NSString).lastPathComponent
        let secondName = (secondPath as NSString).lastPathComponent
        XCTAssertNotNil(firstName.range(of: pattern, options: .regularExpression))
        XCTAssertNotNil(secondName.range(of: pattern, options: .regularExpression))
    }

    @MainActor
    func test_cancelQueuedItemMarksCancelledAndNeverRuns() async throws {
        let bridge = MockFileBridge()
        bridge.latencyNanos = 150_000_000
        let queue = TransferQueue(bridge: bridge)
        let firstURL = try temporaryURL(filename: "first.txt")
        let secondURL = try temporaryURL(filename: "second.txt")

        let first = queue.enqueueDownload(
            remotePath: "/home/mock/first.txt",
            displayName: "first.txt",
            to: firstURL
        )
        let second = queue.enqueueDownload(
            remotePath: "/home/mock/second.txt",
            displayName: "second.txt",
            to: secondURL
        )

        await assertEventually { first.phase.isRunning }
        queue.cancel(second)

        XCTAssertEqual(second.phase, .cancelled)
        await assertEventually { first.phase == .completed }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(second.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @MainActor
    func test_cancelMidFlightMarksCancelled() async throws {
        let bridge = MockFileBridge()
        bridge.latencyNanos = 150_000_000
        let queue = TransferQueue(bridge: bridge)
        let destination = try temporaryURL(filename: "cancelled.txt")

        let item = queue.enqueueDownload(
            remotePath: "/home/mock/cancelled.txt",
            displayName: "cancelled.txt",
            to: destination
        )

        await assertEventually { item.phase.isRunning }
        queue.cancel(item)

        if case .cancelling = item.phase {
            // Expected: the UI remains in a cancelling state until remote
            // partial-file cleanup completes.
        } else {
            XCTFail("Expected cancelling phase, got \(item.phase)")
        }
        await assertEventually { item.phase == .cancelled }
    }

    @MainActor
    func test_cancelUploadRemovesRemoteStagingFileBeforeFinishing() async throws {
        let bridge = RecordingUploadBridge(uploadDelayNanos: 5_000_000_000)
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "large.mov", contents: "video")
        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { !bridge.uploadedPaths.isEmpty }
        let stagingPath = try XCTUnwrap(bridge.uploadedPaths.first)
        queue.cancel(item)

        await assertEventually { item.phase == .cancelled }
        XCTAssertTrue(bridge.removedPaths.contains(stagingPath))
        XCTAssertFalse(bridge.renamedPaths.contains {
            $0.to == "/home/mock/uploads/large.mov"
        })
    }

    @MainActor
    func test_cancelRejectedAfterRemoteCommitBoundaryPreservesCompletion() async throws {
        let bridge = RecordingUploadBridge(uploadDelayNanos: 120_000_000)
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "commit.mov", contents: "video")
        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { item.phase.isRunning }
        item.isFinalizingUpload = true
        XCTAssertFalse(queue.cancel(item), "commit-boundary cancellation must be rejected")
        item.isFinalizingUpload = false

        await assertEventually { item.phase == .completed }
    }

    @MainActor
    func test_lostRenameAcknowledgementReconcilesAsCommitted() async throws {
        let bridge = RecordingUploadBridge(loseFirstRenameAcknowledgementAfterCommit: true)
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "reconciled.mov", contents: "video")
        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { item.phase == .completed }
        XCTAssertEqual(item.resolvedRemotePath, "/home/mock/uploads/reconciled.mov")
        XCTAssertTrue(bridge.remoteFiles.contains("/home/mock/uploads/reconciled.mov"))
        XCTAssertFalse(bridge.remoteFiles.contains { $0.contains(".partial") })
    }

    @MainActor
    func test_opportunisticCleanupNeverDeletesActiveUploadPartial() async throws {
        let bridge = RecordingUploadBridge(uploadDelayNanos: 5_000_000_000)
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "monitored.mov", contents: "video")
        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { !bridge.uploadedPaths.isEmpty }
        let stagingPath = try XCTUnwrap(bridge.uploadedPaths.first)
        await TransferQueue.retryPendingRemoteUploadCleanups(using: bridge)
        XCTAssertFalse(bridge.removedPaths.contains(stagingPath))

        queue.cancel(item)
        await assertEventually { item.phase == .cancelled }
        XCTAssertTrue(bridge.removedPaths.contains(stagingPath))
    }

    @MainActor
    func test_existingDestinationIsNeverDeletedBeforeRename() async throws {
        let finalPath = "/home/mock/uploads/existing.txt"
        let bridge = RecordingUploadBridge(remoteFiles: [finalPath])
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "existing.txt", contents: "replacement")
        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { item.phase == .completed }
        XCTAssertFalse(bridge.removedPaths.contains(finalPath))
        XCTAssertTrue(bridge.remoteFiles.contains(finalPath))
    }

    @MainActor
    func test_existingPrivateDestinationPreservesPermissions() async throws {
        let finalPath = "/home/mock/uploads/private.txt"
        let bridge = RecordingUploadBridge(remoteEntries: [
            finalPath: remoteEntry(path: finalPath, kind: .file, permissions: 0o600),
        ])
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "private.txt", contents: "replacement")

        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { item.phase == .completed }
        XCTAssertEqual(bridge.remoteEntries[finalPath]?.permissions, 0o600)
        XCTAssertTrue(bridge.permissionChanges.contains { $0.permissions == 0o600 })
        XCTAssertEqual(bridge.remoteContents[finalPath], "replacement")
        XCTAssertFalse(bridge.remoteFiles.contains { $0.contains(".partial") })
    }

    @MainActor
    func test_existingExecutableDestinationPreservesExecutableBits() async throws {
        let finalPath = "/home/mock/uploads/deploy.sh"
        let bridge = RecordingUploadBridge(remoteEntries: [
            finalPath: remoteEntry(path: finalPath, kind: .file, permissions: 0o751),
        ])
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "deploy.sh", contents: "#!/bin/sh\n")

        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { item.phase == .completed }
        XCTAssertEqual(bridge.remoteEntries[finalPath]?.permissions, 0o751)
        XCTAssertEqual(bridge.remoteContents[finalPath], "#!/bin/sh\n")
    }

    @MainActor
    func test_existingSymlinkUpdatesTargetWithoutReplacingLink() async throws {
        let finalPath = "/home/mock/uploads/current.txt"
        let targetPath = "/home/mock/releases/actual.txt"
        let bridge = RecordingUploadBridge(
            remoteEntries: [
                finalPath: remoteEntry(path: finalPath, kind: .symlink, permissions: 0o777),
                targetPath: remoteEntry(path: targetPath, kind: .file, permissions: 0o600),
            ],
            remoteContents: [targetPath: "old"],
            symlinkTargets: [finalPath: targetPath]
        )
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "current.txt", contents: "new")

        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { item.phase == .completed }
        XCTAssertEqual(bridge.remoteEntries[finalPath]?.kind, .symlink)
        XCTAssertEqual(bridge.remoteContents[targetPath], "new")
        XCTAssertEqual(bridge.uploadedPaths, [finalPath])
        XCTAssertTrue(bridge.renamedPaths.isEmpty)
        XCTAssertFalse(bridge.remoteFiles.contains { $0.contains(".partial") })
    }

    @MainActor
    func test_unsupportedDestinationTypeFailsBeforeUpload() async throws {
        let finalPath = "/home/mock/uploads/events"
        let bridge = RecordingUploadBridge(remoteEntries: [
            finalPath: remoteEntry(path: finalPath, kind: .other, permissions: 0o600),
        ])
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "events", contents: "payload")

        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually {
            if case .failed = item.phase { return true }
            return false
        }
        XCTAssertTrue(bridge.uploadedPaths.isEmpty)
        XCTAssertEqual(bridge.remoteEntries[finalPath]?.kind, .other)
    }

    @MainActor
    func test_existingRegularDestinationWithoutPermissionsFailsBeforeUpload() async throws {
        let finalPath = "/home/mock/uploads/unknown-mode.txt"
        let bridge = RecordingUploadBridge(remoteEntries: [
            finalPath: remoteEntry(path: finalPath, kind: .file, permissions: nil),
        ])
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "unknown-mode.txt", contents: "replacement")

        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually {
            if case .failed = item.phase { return true }
            return false
        }
        XCTAssertTrue(bridge.uploadedPaths.isEmpty)
        XCTAssertEqual(bridge.remoteContents[finalPath], nil)
        guard case .failed(let message) = item.phase else {
            return XCTFail("expected a metadata failure")
        }
        XCTAssertEqual(
            message,
            String(localized: "The upload destination permissions couldn't be verified.")
        )
    }

    @MainActor
    func test_existingDestinationUsesRecoverableSwapWhenServerRejectsOverwriteRename() async throws {
        let finalPath = "/home/mock/uploads/existing.txt"
        let bridge = RecordingUploadBridge(
            remoteFiles: [finalPath],
            rejectRenameOverExisting: true
        )
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "existing.txt", contents: "replacement")
        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")

        await assertEventually { item.phase == .completed }
        XCTAssertTrue(bridge.remoteFiles.contains(finalPath))
        XCTAssertFalse(bridge.remoteFiles.contains { $0.contains(".partial") || $0.contains(".backup") })
        XCTAssertFalse(bridge.removedPaths.contains(finalPath))
        XCTAssertTrue(bridge.renamedPaths.contains { $0.from == finalPath && $0.to.contains(".backup") })
    }

    @MainActor
    func test_uploadCompletionDeliveryNeverSilentlyLosesRequestedPath() {
        var injected: String?
        var copied: String?

        let terminalOutcome = UploadCompletionDelivery.deliver(
            path: "/remote/one",
            delivery: .foreground(pastePath: true),
            injectIntoTerminal: { injected = $0; return true },
            copyToClipboard: { copied = $0 }
        )
        XCTAssertEqual(terminalOutcome, .terminal)
        XCTAssertEqual(injected, "/remote/one")
        XCTAssertNil(copied)

        injected = nil
        let fallbackOutcome = UploadCompletionDelivery.deliver(
            path: "/remote/two",
            delivery: .foreground(pastePath: true),
            injectIntoTerminal: { _ in false },
            copyToClipboard: { copied = $0 }
        )
        XCTAssertEqual(fallbackOutcome, .clipboardFallback)
        XCTAssertNil(injected)
        XCTAssertEqual(copied, "/remote/two")

        copied = nil
        let backgroundOutcome = UploadCompletionDelivery.deliver(
            path: "/remote/three",
            delivery: .background(copyPath: true),
            injectIntoTerminal: { _ in false },
            copyToClipboard: { copied = $0 }
        )
        XCTAssertEqual(backgroundOutcome, .clipboard)
        XCTAssertEqual(copied, "/remote/three")
    }

    @MainActor
    func test_backgroundUploadCompletionRaisesAndAcknowledgesFilesAttention() async throws {
        let bridge = RecordingUploadBridge(uploadDelayNanos: 80_000_000)
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "background.zip", contents: "archive")
        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")
        queue.markContinuedInBackground(item)

        await assertEventually { item.phase == .completed }
        XCTAssertEqual(queue.backgroundAttention, .success)

        queue.acknowledgeBackgroundAttention()
        XCTAssertEqual(queue.backgroundAttention, .none)
    }

    @MainActor
    func test_backgroundExpirationFailsUploadAndRaisesFailureAttention() async throws {
        let bridge = RecordingUploadBridge(uploadDelayNanos: 5_000_000_000)
        let queue = TransferQueue(bridge: bridge)
        let localURL = try temporaryURL(filename: "expired.zip", contents: "archive")
        let item = queue.enqueueUpload(localURL: localURL, toDirectory: "/home/mock/uploads")
        queue.markContinuedInBackground(item)

        await assertEventually { item.phase.isRunning }
        queue.cancel(item, reason: .backgroundTimeExpired)

        await assertEventually {
            if case .failed = item.phase { return true }
            return false
        }
        XCTAssertEqual(queue.backgroundAttention, .failure)
        if case .failed(let message) = item.phase {
            XCTAssertTrue(message.contains("background time expired"))
        }
    }

    @MainActor
    func test_connectFailureMarksItemFailed() async throws {
        let bridge = ConnectFailingBridge()
        let queue = TransferQueue(bridge: bridge)
        let destination = try temporaryURL(filename: "failed.txt")

        let item = queue.enqueueDownload(
            remotePath: "/home/mock/failed.txt",
            displayName: "failed.txt",
            to: destination
        )

        await assertEventually {
            if case .failed = item.phase {
                return true
            }
            return false
        }
        if case .failed(let message) = item.phase {
            XCTAssertEqual(message, "Authentication failed: denied")
        } else {
            XCTFail("Expected failed phase, got \(item.phase)")
        }
    }

    @MainActor
    func test_clearFinishedRemovesOnlyFinishedItemsAndHasActiveTracksQueue() async throws {
        let bridge = MockFileBridge()
        let queue = TransferQueue(bridge: bridge)
        let completedURL = try temporaryURL(filename: "completed.txt")

        let completed = queue.enqueueDownload(
            remotePath: "/home/mock/completed.txt",
            displayName: "completed.txt",
            to: completedURL
        )
        await assertEventually { completed.phase == .completed }
        XCTAssertFalse(queue.hasActive)

        bridge.latencyNanos = 150_000_000
        let running = queue.enqueueDownload(
            remotePath: "/home/mock/running.txt",
            displayName: "running.txt",
            to: try temporaryURL(filename: "running.txt")
        )
        let queued = queue.enqueueDownload(
            remotePath: "/home/mock/queued.txt",
            displayName: "queued.txt",
            to: try temporaryURL(filename: "queued.txt")
        )
        let cancelled = queue.enqueueDownload(
            remotePath: "/home/mock/cancelled.txt",
            displayName: "cancelled.txt",
            to: try temporaryURL(filename: "clear-cancelled.txt")
        )

        await assertEventually { running.phase.isRunning }
        queue.cancel(cancelled)
        XCTAssertTrue(queue.hasActive)

        queue.clearFinished()

        XCTAssertEqual(queue.items.map(\.id), [running.id, queued.id])
        XCTAssertTrue(queue.hasActive)

        await assertEventually(timeout: 1.5) {
            running.phase == .completed && queued.phase == .completed
        }
        XCTAssertFalse(queue.hasActive)

        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }

    @MainActor
    func test_fifoStartsSecondOnlyAfterFirstFinishes() async throws {
        let bridge = MockFileBridge()
        bridge.latencyNanos = 150_000_000
        let queue = TransferQueue(bridge: bridge)
        let firstURL = try temporaryURL(filename: "fifo-first.txt")
        let secondURL = try temporaryURL(filename: "fifo-second.txt")

        let first = queue.enqueueDownload(
            remotePath: "/home/mock/fifo-first.txt",
            displayName: "fifo-first.txt",
            to: firstURL
        )
        let second = queue.enqueueDownload(
            remotePath: "/home/mock/fifo-second.txt",
            displayName: "fifo-second.txt",
            to: secondURL
        )

        await assertEventually { first.phase.isRunning }
        XCTAssertEqual(second.phase, .queued)
        await assertEventually { first.phase == .completed }
        await assertEventually { second.phase.isRunning || second.phase == .completed }
        await assertEventually { second.phase == .completed }
    }

    private func temporaryURL(
        filename: String,
        contents: String? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent(filename)
        if let contents {
            try contents.data(using: .utf8)?.write(to: url)
        }
        return url
    }

    private func remoteEntry(
        path: String,
        kind: RemoteFileEntry.Kind,
        permissions: UInt16?
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: kind,
            size: 1,
            modified: nil,
            permissions: permissions
        )
    }

    @MainActor
    private func assertEventually(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let satisfied = await waitUntil(timeout: timeout, condition: condition)
        XCTAssertTrue(satisfied, file: file, line: line)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private extension TransferPhase {
    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

@MainActor
@Observable
private final class ConnectFailingBridge: FileBridging {
    let key = FileBridgeKey(user: "mock", address: "mock.local", port: 22)
    private(set) var state: FileBridgeState = .idle
    let homeDirectory: String? = "/home/mock"
    var suppressIdleTeardown = false

    func connect() async throws {
        state = .failed("denied")
        throw FileBridgeError.authenticationFailed("denied")
    }

    func disconnect() async {
        state = .idle
    }

    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        throw FileBridgeError.notConnected
    }

    func realPath(_ path: String) async throws -> String {
        throw FileBridgeError.notConnected
    }

    func createDirectory(_ path: String) async throws {
        throw FileBridgeError.notConnected
    }

    func setPermissions(_ permissions: UInt16, at path: String) async throws {
        throw FileBridgeError.notConnected
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        throw FileBridgeError.notConnected
    }

    func removeFile(_ path: String) async throws {
        throw FileBridgeError.notConnected
    }

    func removeDirectory(_ path: String) async throws {
        throw FileBridgeError.notConnected
    }

    func download(
        remotePath: String,
        to localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        throw FileBridgeError.notConnected
    }

    func upload(
        localURL: URL,
        to remotePath: String,
        progress: TransferProgressHandler?
    ) async throws {
        throw FileBridgeError.notConnected
    }

    @discardableResult
    func exec(_ command: String, inShell: Bool) async throws -> String {
        throw FileBridgeError.notConnected
    }
}

@MainActor
@Observable
private final class ProgressHoldingBridge: FileBridging {
    let key = FileBridgeKey(user: "mock", address: "mock.local", port: 22)
    private(set) var state: FileBridgeState = .idle
    let homeDirectory: String? = "/home/mock"
    var suppressIdleTeardown = false

    func connect() async throws {
        try await Task.sleep(nanoseconds: 40_000_000)
        state = .connected
    }

    func disconnect() async {
        state = .idle
    }

    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        throw FileBridgeError.remoteOperationFailed("unused")
    }

    func realPath(_ path: String) async throws -> String {
        path
    }

    func createDirectory(_ path: String) async throws {}

    func setPermissions(_ permissions: UInt16, at path: String) async throws {}

    func rename(from oldPath: String, to newPath: String) async throws {}

    func removeFile(_ path: String) async throws {}

    func removeDirectory(_ path: String) async throws {}

    func download(
        remotePath: String,
        to localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        guard state == .connected else {
            throw FileBridgeError.notConnected
        }
        progress?(0, 100)
        try await Task.sleep(nanoseconds: 40_000_000)
        try Data("contents\n".utf8).write(to: localURL)
        progress?(100, 100)
        try await Task.sleep(nanoseconds: 40_000_000)
    }

    func upload(
        localURL: URL,
        to remotePath: String,
        progress: TransferProgressHandler?
    ) async throws {
        guard state == .connected else {
            throw FileBridgeError.notConnected
        }
        progress?(0, 1)
        progress?(1, 1)
    }

    @discardableResult
    func exec(_ command: String, inShell: Bool) async throws -> String {
        ""
    }
}

@MainActor
@Observable
private final class RecordingUploadBridge: FileBridging {
    let key = FileBridgeKey(user: "recording", address: "recording.local", port: 22)
    private(set) var state: FileBridgeState = .idle
    let homeDirectory: String? = "/home/mock"
    var suppressIdleTeardown = false
    let uploadDelayNanos: UInt64
    private(set) var uploadedPaths: [String] = []
    private(set) var executedCommands: [String] = []
    private(set) var renamedPaths: [(from: String, to: String)] = []
    private(set) var removedPaths: [String] = []
    private(set) var permissionChanges: [(path: String, permissions: UInt16)] = []
    private(set) var remoteEntries: [String: RemoteFileEntry]
    private(set) var remoteContents: [String: String]
    private let symlinkTargets: [String: String]
    private var loseFirstRenameAcknowledgementAfterCommit: Bool
    private let rejectRenameOverExisting: Bool

    init(
        uploadDelayNanos: UInt64 = 0,
        remoteFiles: Set<String> = [],
        remoteEntries: [String: RemoteFileEntry] = [:],
        remoteContents: [String: String] = [:],
        symlinkTargets: [String: String] = [:],
        loseFirstRenameAcknowledgementAfterCommit: Bool = false,
        rejectRenameOverExisting: Bool = false
    ) {
        self.uploadDelayNanos = uploadDelayNanos
        var entries = remoteEntries
        for path in remoteFiles where entries[path] == nil {
            entries[path] = Self.entry(path: path, kind: .file, permissions: 0o600)
        }
        self.remoteEntries = entries
        self.remoteContents = remoteContents
        self.symlinkTargets = symlinkTargets
        self.loseFirstRenameAcknowledgementAfterCommit = loseFirstRenameAcknowledgementAfterCommit
        self.rejectRenameOverExisting = rejectRenameOverExisting
    }

    var remoteFiles: Set<String> { Set(remoteEntries.keys) }

    func connect() async throws { state = .connected }
    func disconnect() async { state = .idle }
    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        remoteEntries.values.compactMap { entry in
            let remotePath = entry.path
            guard (remotePath as NSString).deletingLastPathComponent == path else { return nil }
            return entry
        }
    }
    func realPath(_ path: String) async throws -> String { path }
    func createDirectory(_ path: String) async throws {}
    func setPermissions(_ permissions: UInt16, at path: String) async throws {
        guard let entry = remoteEntries[path] else {
            throw FileBridgeError.remoteOperationFailed("missing")
        }
        permissionChanges.append((path, permissions))
        remoteEntries[path] = Self.entry(
            path: path,
            kind: entry.kind,
            permissions: permissions
        )
    }
    func rename(from oldPath: String, to newPath: String) async throws {
        try Task.checkCancellation()
        renamedPaths.append((oldPath, newPath))
        if rejectRenameOverExisting, remoteEntries[newPath] != nil {
            throw FileBridgeError.remoteOperationFailed("destination exists")
        }
        let entry = remoteEntries.removeValue(forKey: oldPath)
        if let entry {
            remoteEntries[newPath] = Self.entry(
                path: newPath,
                kind: entry.kind,
                permissions: entry.permissions
            )
        }
        if let contents = remoteContents.removeValue(forKey: oldPath) {
            remoteContents[newPath] = contents
        }
        if loseFirstRenameAcknowledgementAfterCommit {
            loseFirstRenameAcknowledgementAfterCommit = false
            throw FileBridgeError.network("lost rename reply")
        }
    }
    func removeFile(_ path: String) async throws {
        try Task.checkCancellation()
        removedPaths.append(path)
        remoteEntries.removeValue(forKey: path)
        remoteContents.removeValue(forKey: path)
    }
    func removeDirectory(_ path: String) async throws {}

    func download(
        remotePath: String,
        to localURL: URL,
        progress: TransferProgressHandler?
    ) async throws {
        throw FileBridgeError.remoteOperationFailed("unused")
    }

    func upload(
        localURL: URL,
        to remotePath: String,
        progress: TransferProgressHandler?
    ) async throws {
        uploadedPaths.append(remotePath)
        let contents = (try? String(contentsOf: localURL, encoding: .utf8)) ?? ""
        if let target = symlinkTargets[remotePath] {
            remoteContents[target] = contents
        } else {
            remoteEntries[remotePath] = Self.entry(
                path: remotePath,
                kind: .file,
                permissions: 0o644
            )
            remoteContents[remotePath] = contents
        }
        progress?(0, 100)
        if uploadDelayNanos > 0 {
            try await Task.sleep(nanoseconds: uploadDelayNanos)
        }
        try Task.checkCancellation()
        progress?(100, 100)
    }

    private static func entry(
        path: String,
        kind: RemoteFileEntry.Kind,
        permissions: UInt16?
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: (path as NSString).lastPathComponent,
            path: path,
            kind: kind,
            size: 1,
            modified: nil,
            permissions: permissions
        )
    }

    @discardableResult
    func exec(_ command: String, inShell: Bool) async throws -> String {
        try Task.checkCancellation()
        executedCommands.append(command)
        return ""
    }
}
