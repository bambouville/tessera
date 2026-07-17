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
        let bridge = MockFileBridge()
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
    }

    @MainActor
    func test_pasteUploadGeneratesDistinctNamesUnderTempDirectory() async throws {
        let bridge = MockFileBridge()
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

        XCTAssertEqual(item.phase, .cancelled)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.phase, .cancelled)
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
