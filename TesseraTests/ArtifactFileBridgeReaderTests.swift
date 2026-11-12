import Foundation
import os
import XCTest
@testable import Tessera

@MainActor
final class ArtifactFileBridgeReaderTests: XCTestCase {
    func testAcceptedRootUsesBoundedBackgroundLocalReadWithoutRemoteCalls() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = root.appendingPathComponent("index.html")
        try Data("accepted".utf8).write(to: snapshot)
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/index.html"] = Data("unaccepted".utf8)
        let reader = ArtifactFileBridgeReader(cachedRoot: { snapshot }, readLocalFile: { url, limit in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(limit, 64)
            return try Data(contentsOf: url)
        }) { bridge }
        let bytes = try await reader.read(absolutePath: "/srv/index.html", allowedRoot: nil, maxBytes: 64)
        XCTAssertEqual(bytes, Data("accepted".utf8))
        XCTAssertTrue(bridge.downloads.isEmpty)
        XCTAssertTrue(bridge.realPaths.isEmpty)
        XCTAssertTrue(bridge.attributePaths.isEmpty)
        let bounded = ArtifactFileBridgeReader(cachedRoot: { snapshot }) { bridge }
        do { _ = try await bounded.read(absolutePath: "/srv/index.html", allowedRoot: nil, maxBytes: 4); XCTFail("oversized cache") }
        catch ArtifactRemoteReadError.fileTooLarge(let limit) { XCTAssertEqual(limit, 4) }
        bridge.state = .idle
        do { _ = try await reader.read(absolutePath: "/srv/index.html", allowedRoot: nil, maxBytes: 64); XCTFail("offline") }
        catch FileBridgeError.notConnected { }
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testCachedRootNeverBypassesSubresourceContainment() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/private/secret.txt"] = Data("secret".utf8)
        bridge.directories.insert("/srv/site")
        bridge.symlinks["/srv/site/secret.txt"] = "/private/secret.txt"
        let reader = ArtifactFileBridgeReader(cachedRoot: { XCTFail("a subresource cannot use the cached root"); throw ArtifactRemoteReadError.notFound }) { bridge }
        do { _ = try await reader.read(absolutePath: "/srv/site/secret.txt", allowedRoot: "/srv/site", maxBytes: 64); XCTFail("escaped") }
        catch ArtifactRemoteReadError.forbidden { }
        XCTAssertTrue(bridge.downloads.isEmpty)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testSymlinkEscapesAndSiblingPrefixAreForbiddenBeforeDownload() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/home/u/.ssh/id_ed25519"] = Data("secret".utf8)
        bridge.files["/srv/site-other/key"] = Data("secret".utf8)
        bridge.symlinks["/srv/site/private"] = "/home/u/.ssh"
        bridge.symlinks["/srv/site/neighbor"] = "/srv/site-other"
        let reader = ArtifactFileBridgeReader { bridge }
        for path in ["/srv/site/private/id_ed25519", "/srv/site/neighbor/key"] {
            do { _ = try await reader.read(absolutePath: path, allowedRoot: "/srv/site", maxBytes: 64); XCTFail("escaped root") }
            catch ArtifactRemoteReadError.forbidden { }
        }
        XCTAssertTrue(bridge.downloads.isEmpty)
        XCTAssertTrue(bridge.attributePaths.isEmpty)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testCanonicalRootAndRequestAreUsedForStatAndDownload() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/releases/v1/assets/app.js"] = Data("script".utf8)
        bridge.symlinks["/srv/site"] = "/releases/v1"
        bridge.symlinks["/releases/v1/main.js"] = "/releases/v1/assets/app.js"
        let reader = ArtifactFileBridgeReader { bridge }
        let bytes = try await reader.read(absolutePath: "/srv/site/main.js", allowedRoot: "/srv/site", maxBytes: 64)
        XCTAssertEqual(bytes, Data("script".utf8))
        XCTAssertEqual(bridge.realPaths, ["/srv/site/main.js", "/srv/site"])
        XCTAssertEqual(bridge.attributePaths, ["/releases/v1/assets/app.js"])
        XCTAssertEqual(bridge.downloads, ["/releases/v1/assets/app.js"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(bridge.downloadURLs.first).deletingLastPathComponent().path))
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testCanonicalContainmentComparesRemoteUTF8Bytes() async throws {
        let bridge = ArtifactTestBridge()
        bridge.directories.insert("/srv/e\u{301}")
        bridge.files["/srv/é/app.js"] = Data("outside".utf8)
        let reader = ArtifactFileBridgeReader { bridge }
        do { _ = try await reader.read(absolutePath: "/srv/é/app.js", allowedRoot: "/srv/e\u{301}", maxBytes: 64); XCTFail("different remote directory") }
        catch ArtifactRemoteReadError.forbidden { }
        XCTAssertTrue(bridge.downloads.isEmpty)
    }

    func testExactSymlinkedPageIsAllowedWithoutGrantingItsTargetDirectory() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/private/page.html"] = Data("<html>page</html>".utf8)
        bridge.files["/private/secret.txt"] = Data("secret".utf8)
        bridge.symlinks["/srv/site/index.html"] = "/private/page.html"
        bridge.symlinks["/srv/site/secret.txt"] = "/private/secret.txt"
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/site/index.html",
                                                reader: ArtifactFileBridgeReader { bridge })
        let page = await handler.response(for: URLRequest(url: handler.pageURL))
        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(page.data, Data("<html>page</html>".utf8))
        let secretURL = try XCTUnwrap(URL(string: "secret.txt", relativeTo: handler.pageURL)?.absoluteURL)
        let secret = await handler.response(for: URLRequest(url: secretURL))
        XCTAssertEqual(secret.statusCode, 403)
        XCTAssertEqual(bridge.downloads, ["/private/page.html"])
    }

    func testFailedRealpathOfRootOrRequestIsNotFound() async throws {
        for failingPath in ["/srv/site", "/srv/site/app.js"] {
            let bridge = ArtifactTestBridge()
            bridge.files["/srv/site/app.js"] = Data("script".utf8)
            bridge.realPathErrors[failingPath] = .remoteStatus(code: 3, message: "realpath denied")
            let reader = ArtifactFileBridgeReader { bridge }
            do { _ = try await reader.read(absolutePath: "/srv/site/app.js", allowedRoot: "/srv/site", maxBytes: 64); XCTFail("unresolved path") }
            catch ArtifactRemoteReadError.notFound { }
            XCTAssertTrue(bridge.downloads.isEmpty)
        }
    }

    func testFilesystemRootUsesAComponentBoundary() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/app.js"] = Data("script".utf8)
        let bytes = try await ArtifactFileBridgeReader { bridge }
            .read(absolutePath: "/app.js", allowedRoot: "/", maxBytes: 64)
        XCTAssertEqual(bytes, Data("script".utf8))
    }

    func testLocalReadUsesBackgroundExecutorAndCleansTemporaryFile() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/page.html"] = Data("page".utf8)
        let reader = ArtifactFileBridgeReader(readLocalFile: { url, limit in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(limit, 64)
            return try Data(contentsOf: url)
        }) { bridge }
        let data = try await reader.read(absolutePath: "/srv/page.html", allowedRoot: "/srv", maxBytes: 64)
        XCTAssertEqual(data, Data("page".utf8))
        let directory = try XCTUnwrap(bridge.downloadURLs.first).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancellationDuringLocalReadWaitsForWorkerAndCleansTemporaryFile() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/page.html"] = Data("page".utf8)
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let observedCancellation = OSAllocatedUnfairLock(initialState: false)
        let reader = ArtifactFileBridgeReader(readLocalFile: { url, _ in
            XCTAssertFalse(Thread.isMainThread)
            started.withLock { $0 = true }
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            observedCancellation.withLock { $0 = Task.isCancelled }
            return try Data(contentsOf: url)
        }) { bridge }
        let task = Task { try await reader.read(absolutePath: "/srv/page.html", allowedRoot: "/srv", maxBytes: 64) }
        defer { release.signal(); task.cancel() }
        await artifactEventually { started.withLock { $0 } }
        task.cancel()
        let directory = try XCTUnwrap(bridge.downloadURLs.first).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        release.signal()
        do { _ = try await task.value; XCTFail("cancelled read must not return bytes") }
        catch is CancellationError { }
        XCTAssertTrue(observedCancellation.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFailedLocalReadCleansTemporaryFile() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/page.html"] = Data("page".utf8)
        let reader = ArtifactFileBridgeReader(readLocalFile: { _, _ in throw CocoaError(.fileReadUnknown) }) { bridge }
        do { _ = try await reader.read(absolutePath: "/srv/page.html", allowedRoot: "/srv", maxBytes: 64); XCTFail("read should fail") }
        catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadUnknown) }
        let directory = try XCTUnwrap(bridge.downloadURLs.first).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancelledDownloadCleansTemporaryFileAndNeverReadsIt() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/page.html"] = Data("page".utf8)
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        let reader = ArtifactFileBridgeReader(readLocalFile: { _, _ in XCTFail("cancelled download must not be read"); return Data() }) { bridge }
        let task = Task { try await reader.read(absolutePath: "/srv/page.html", allowedRoot: "/srv", maxBytes: 64) }
        defer { task.cancel() }
        await artifactEventually { await gate.pendingCount == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled download must not return bytes") }
        catch is CancellationError { }
        let directory = try XCTUnwrap(bridge.downloadURLs.first).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(bridge.connectCalls, 0)
    }
}
