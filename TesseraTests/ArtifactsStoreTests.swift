import Foundation
import Observation
import os
import PortForwarding
import SwiftUI
import TesseraArtifactsCore
import UIKit
import XCTest
@testable import Tessera

@MainActor
final class ArtifactsStoreTests: XCTestCase {
    func testForegroundRetryRestoresUnavailableManifestAndResumesPersistenceAndFollowing() async throws {
        try await assertUnavailableRestore(unavailableManifest: true)
    }

    func testProtectedDataAvailabilityRetriesUnavailableBlobAfterSessionsAreUpdated() async throws {
        try await assertUnavailableRestore(unavailableManifest: false)
    }

    func testFencedClosePreservesTheCacheSharedWithARestoredPinnedTab() async throws {
        for unavailableManifest in [true, false] {
            try await assertFencedClose(sharesPersistedKey: true, unavailableManifest: unavailableManifest)
        }
    }

    func testFencedCloseImmediatelyCollectsANewOrphanEvenWithinTheBudget() async throws {
        for unavailableManifest in [true, false] {
            try await assertFencedClose(sharesPersistedKey: false, unavailableManifest: unavailableManifest)
        }
    }

    private func assertFencedClose(sharesPersistedKey: Bool, unavailableManifest: Bool) async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        let blocked = OSAllocatedUnfairLock(initialState: true)
        let file = ArtifactsStateFile(directory: root, blobRead: { _ in
            if !unavailableManifest, blocked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
        }, readState: { url in
            if unavailableManifest, blocked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        let loader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory)
        try ArtifactsStateFile.prepareDirectory(root)
        let source = root.appendingPathComponent("source.md")
        let bytes = Data("offline copy".utf8)
        try bytes.write(to: source)
        var document = artifactTestTab(path: "/docs/pinned.md", hostID: bridge.hostID)
        document.hostLabel = "host"
        document.pinned = true
        let adopted = try loader.adopt(source, for: document)
        document.cache = .init(fetchedAt: 1, remoteMTime: nil, size: adopted.size)
        let change = ArtifactTab(id: "change", hostID: bridge.hostID.uuidString, hostLabel: "host",
                                 target: .change(path: "/edit", diff: "+kept", summary: "edit"),
                                 title: "edit", openedAt: 1, viewedAt: 1)
        let saved = ArtifactsState(tabs: [change, document], selectedID: document.id)
        let seed = ArtifactsStateFile(directory: root)
        seed.schedule(saved)
        seed.flush()
        let manifest = try Data(contentsOf: seed.stateURL)
        let store = ArtifactsStore(stateFile: file, loader: loader, bridgeProvider: { [bridge] })
        XCTAssertTrue(file.isLoadUnavailable)
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        let path = sharesPersistedKey ? document.target.path : "/docs/temporary.md"
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: path),
                                                            origin: .files, stagedLocalURL: source)))
        let temporary = try XCTUnwrap(store.tab(id))
        let temporaryURL = try XCTUnwrap(loader.cachedURL(for: temporary))
        XCTAssertEqual(ArtifactsCachePolicy.cacheKey(temporary) == ArtifactsCachePolicy.cacheKey(document), sharesPersistedKey)
        store.close(id)
        await store.waitForCacheEviction()
        store.flush()
        XCTAssertEqual(FileManager.default.fileExists(atPath: temporaryURL.path), sharesPersistedKey,
                       "only a key that predates the fence must defer its close")
        XCTAssertEqual(try Data(contentsOf: seed.stateURL), manifest)

        blocked.withLock { $0 = false }
        store.setApplicationForeground(true)
        await store.waitForCacheEviction()
        XCTAssertFalse(file.isLoadUnavailable)
        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(FileManager.default.fileExists(atPath: temporaryURL.path), sharesPersistedKey,
                       "recovery must use restored references even when all bytes fit within the budget")
        guard case let .document(restoredURL, _, _, _) = store.content(for: document.id) else {
            return XCTFail("the restored pin must keep its offline copy")
        }
        XCTAssertEqual(try Data(contentsOf: restoredURL), bytes)
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertTrue(bridge.downloads.isEmpty)
    }

    func testFencedOpenAndCloseKeepsTheBudgetAndRemovesOnlyNewKeys() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        let file = ArtifactsStateFile(directory: root, readState: { _ in throw CocoaError(.fileReadNoPermission) })
        let loader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory)
        try ArtifactsStateFile.prepareDirectory(root)
        let source = root.appendingPathComponent("source.txt")
        let bytes = Data(repeating: 1, count: 64)
        try bytes.write(to: source)
        let old = artifactTestTab(path: "/old.txt", hostID: bridge.hostID)
        let oldURL = try loader.adopt(source, for: old).localURL
        let oldKey = ArtifactsCachePolicy.cacheKey(old)
        let store = ArtifactsStore(stateFile: file, loader: loader, cacheBudgetBytes: 256, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        XCTAssertTrue(file.isLoadUnavailable)
        var created: Set<String> = []
        for index in 0..<12 {
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
                target: .file(path: "/new-\(index).txt"), origin: .files, stagedLocalURL: source)))
            let tab = try XCTUnwrap(store.tab(id))
            created.insert(ArtifactsCachePolicy.cacheKey(tab))
            await store.waitForCacheEviction()
            let before = ArtifactContentLoader.cacheSizes(in: file.cacheDirectory)
            XCTAssertLessThanOrEqual(before.values.reduce(0, +), 256)
            store.close(id)
            XCTAssertNil(loader.cachedURL(for: tab), "a new key is removed synchronously on close")
            await store.waitForCacheEviction()
            let after = ArtifactContentLoader.cacheSizes(in: file.cacheDirectory)
            XCTAssertTrue(Set(before.keys).subtracting(after.keys).isSubset(of: created))
            XCTAssertEqual(after, [oldKey: 64])
            XCTAssertEqual(try Data(contentsOf: oldURL), bytes)
        }
        XCTAssertEqual(created.count, 12, "exercise more distinct entries than four fit in the budget")
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertTrue(bridge.downloads.isEmpty)
    }

    func testFencedEvictionUsesOldestFirstAndKeepsOldPinnedAndSelectedKeys() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let file = ArtifactsStateFile(directory: root, readState: { _ in throw CocoaError(.fileReadNoPermission) })
        let walks = OSAllocatedUnfairLock(initialState: 0)
        let loader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory, walkCache: { directory in
            XCTAssertFalse(Thread.isMainThread)
            walks.withLock { $0 += 1 }
            return ArtifactContentLoader.cacheSizes(in: directory)
        })
        try ArtifactsStateFile.prepareDirectory(root)
        let source = root.appendingPathComponent("source.txt")
        try Data(repeating: 1, count: 64).write(to: source)
        let old = artifactTestTab(path: "/old.txt", hostID: hostID)
        _ = try loader.adopt(source, for: old)
        var time: Int64 = 0
        let store = ArtifactsStore(stateFile: file, loader: loader, cacheBudgetBytes: 256, now: { time += 1; return time })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "host")])
        var tabs: [ArtifactTab] = []
        for index in 0..<4 {
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: hostID,
                target: .file(path: "/new-\(index).txt"), origin: .files, stagedLocalURL: source)))
            if index == 0 { store.setPinned(id, true) }
            tabs.append(try XCTUnwrap(store.tab(id)))
        }
        await store.waitForCacheEviction()
        XCTAssertGreaterThan(walks.withLock { $0 }, 0)
        XCTAssertNotNil(loader.cachedURL(for: old), "the unknown persisted references always protect old keys")
        XCTAssertNotNil(loader.cachedURL(for: tabs[0]), "pin")
        XCTAssertNil(loader.cachedURL(for: tabs[1]), "oldest unprotected new key")
        XCTAssertNotNil(loader.cachedURL(for: tabs[2]), "newer unprotected new key")
        XCTAssertNotNil(loader.cachedURL(for: tabs[3]), "selection")
        XCTAssertEqual(ArtifactContentLoader.cacheSizes(in: file.cacheDirectory).values.reduce(0, +), 256)
    }

    func testFencedEvictionProtectsANewKeyWhileItsDownloadIsInFlight() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        bridge.files["/loading.txt"] = Data("accepted".utf8)
        let file = ArtifactsStateFile(directory: root, readState: { _ in throw CocoaError(.fileReadNoPermission) })
        let loader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory)
        let store = ArtifactsStore(stateFile: file, loader: loader, cacheBudgetBytes: 0, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let loading = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .file(path: "/loading.txt"), origin: .terminalSelection)))
        await artifactEventually { await gate.pendingCount == 1 }
        let tab = try XCTUnwrap(store.tab(loading))
        let directory = loader.localURL(for: tab).deletingLastPathComponent()
        let source = root.appendingPathComponent("source.txt")
        try Data("selected".utf8).write(to: source)
        _ = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .file(path: "/selected.txt"), origin: .files, stagedLocalURL: source)))
        await store.waitForCacheEviction()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "eviction must retain the destination of an unselected live download")
        store.setPinned(loading, true)
        await gate.tick()
        await store.waitForLoad(loading)
        await store.waitForCacheEviction()
        XCTAssertEqual(try Data(contentsOf: loader.localURL(for: tab)), Data("accepted".utf8))
        XCTAssertEqual(bridge.downloads, ["/loading.txt"])
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testAFileTabOpensFilesOnlyWhenTheUserRefreshes() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        bridge.allowsConnect = true
        bridge.files["/notes.md"] = Data("fresh".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   filesBridge: { _ in bridge }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID, ssh: true)])
        let file = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .file(path: "/notes.md"), origin: .terminalSelection)))
        let page = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .page(scheme: "http", port: 5173, path: "/"), origin: .terminalLink)))
        store.noteVisible(file)
        store.refresh(file)
        XCTAssertEqual(store.filesReconnect(for: file), .available)
        XCTAssertNil(store.filesReconnect(for: page))
        XCTAssertTrue(store.canRefreshOrReconnect(file))
        XCTAssertEqual(bridge.connectCalls, 0, "opening, showing or refreshing a tab must not connect Files")

        store.connectFiles(file)
        XCTAssertEqual(store.filesReconnect(for: file), .connecting)
        XCTAssertFalse(store.canRefreshOrReconnect(file))
        await artifactEventually { bridge.downloads == ["/notes.md"] }
        XCTAssertNil(store.filesReconnect(for: file))
        XCTAssertEqual(bridge.connectCalls, 1)
    }

    /// A mosh session forwards nothing, so a page on a mosh host offers its
    /// Files connection as a file tab does, and only a tap connects it. An
    /// SSH session to the host forwards the page itself and offers nothing.
    func testAMoshPageOffersTheFilesConnectionOnlyWhileNoSSHConnectionCanForwardIt() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        bridge.allowsConnect = true
        let mosh = artifactStoreLiveSession(hostID: bridge.hostID)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   filesBridge: { _ in bridge }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([mosh])
        let page = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .page(scheme: "http", port: 5173, path: "/"), origin: .terminalLink)))
        store.noteVisible(page)
        if case .unavailable(.noForwarding) = store.content(for: page) { } else { XCTFail("mosh alone has no page connection") }
        XCTAssertEqual(store.filesReconnect(for: page), .available)
        XCTAssertTrue(store.canRefreshOrReconnect(page))
        XCTAssertEqual(bridge.connectCalls, 0, "showing the page must not connect Files")

        store.connectFiles(page)
        XCTAssertEqual(store.filesReconnect(for: page), .connecting)
        await artifactEventually { store.filesReconnect(for: page) == nil }
        XCTAssertEqual(bridge.connectCalls, 1)

        bridge.state = .idle
        let ssh = artifactStoreLiveSession(hostID: bridge.hostID, ssh: true)
        store.updateSessions([mosh, ssh])
        XCTAssertNil(store.filesReconnect(for: page), "the SSH session is the page's connection")
        XCTAssertEqual(bridge.connectCalls, 1)
        // The badge follows the host, as its header does, before any forward.
        XCTAssertEqual(store.presentation(for: page).state, .live)
        if case .forwardedPage = store.content(for: page) { } else {
            XCTAssertFalse(store.presentation(for: page).canRefresh, "only a forwarded page has a load to refresh")
        }
        store.noteVisible(nil)
    }

    func testAFailedFilesReconnectSaysWhyAndRetriesOnTheNextTap() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        bridge.allowsConnect = true
        bridge.connectError = .authenticationFailed("denied")
        bridge.files["/notes.md"] = Data("fresh".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   filesBridge: { _ in bridge }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID, ssh: true)])
        let file = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .file(path: "/notes.md"), origin: .terminalSelection)))
        store.noteVisible(file)

        store.connectFiles(file)
        await artifactEventually { store.filesReconnect(for: file) != .connecting }
        guard case .failed? = store.filesReconnect(for: file) else {
            return XCTFail("a failed connect must offer a retry, got \(String(describing: store.filesReconnect(for: file)))")
        }
        XCTAssertTrue(store.canRefreshOrReconnect(file))
        XCTAssertTrue(bridge.downloads.isEmpty)

        bridge.connectError = nil
        store.connectFiles(file)
        await artifactEventually { bridge.downloads == ["/notes.md"] }
        XCTAssertEqual(bridge.connectCalls, 2)
    }

    func testFencedOldKeyIsNeverReplacedRemovedOrCleanedEvenOverBudget() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let blocked = OSAllocatedUnfairLock(initialState: true)
        let file = ArtifactsStateFile(directory: root, readState: { url in
            if blocked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        try ArtifactsStateFile.prepareDirectory(root)
        let source = root.appendingPathComponent("source.txt")
        let bytes = Data(repeating: 1, count: 64)
        try bytes.write(to: source)
        var old = artifactTestTab(path: "/old.txt", hostID: bridge.hostID)
        old.hostLabel = "host"
        old.pinned = true
        let seedLoader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory)
        let oldURL = try seedLoader.adopt(source, for: old).localURL
        let legacy = oldURL.deletingLastPathComponent().appendingPathComponent(".partial-\(UUID().uuidString)")
        try Data([2]).write(to: legacy)
        let seed = ArtifactsStateFile(directory: root)
        let saved = ArtifactsState(tabs: [old], selectedID: old.id)
        seed.schedule(saved)
        seed.flush()
        let loader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory)
        let store = ArtifactsStore(stateFile: file, loader: loader, cacheBudgetBytes: 32, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        try Data("replacement".utf8).write(to: source)
        for _ in 0..<10 {
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
                target: .file(path: old.target.path), origin: .files, stagedLocalURL: source)))
            store.refresh(id)
            await store.waitForLoad(id)
            store.close(id)
        }
        let temporary = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .file(path: "/new.txt"), origin: .files, stagedLocalURL: source)))
        await store.waitForCacheEviction()
        XCTAssertEqual(try Data(contentsOf: oldURL), bytes)
        XCTAssertEqual(try Data(contentsOf: legacy), Data([2]), "even legacy cleanup must wait for the old key's references")
        store.close(temporary)
        await store.waitForCacheEviction()
        XCTAssertEqual(try Data(contentsOf: oldURL), bytes)
        XCTAssertTrue(bridge.downloads.isEmpty)
        blocked.withLock { $0 = false }
        store.setApplicationForeground(true)
        await store.waitForCacheEviction()
        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(try Data(contentsOf: oldURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "ordinary cleanup resumes after recovery")
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testRecoveryKeepsANewFencedCacheReferencedByARestoredTabWithinBudget() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        var document = artifactTestTab(path: "/docs/restored.md", hostID: hostID)
        document.hostLabel = "host"
        let change = ArtifactTab(id: "change", hostID: hostID.uuidString, hostLabel: "host",
                                 target: .change(path: "/edit", diff: "+kept", summary: "edit"),
                                 title: "edit", openedAt: 1, viewedAt: 1)
        let saved = ArtifactsState(tabs: [document, change], selectedID: change.id)
        let seed = ArtifactsStateFile(directory: root)
        seed.schedule(saved)
        seed.flush()
        let blocked = OSAllocatedUnfairLock(initialState: true)
        let file = ArtifactsStateFile(directory: root, readState: { url in
            if blocked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        let loader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory)
        XCTAssertNil(loader.cachedURL(for: document), "the persisted tab had no offline copy before the fence")
        let source = root.appendingPathComponent("source.md")
        let bytes = Data("created while fenced".utf8)
        try bytes.write(to: source)
        let store = ArtifactsStore(stateFile: file, loader: loader, cacheBudgetBytes: 256)
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "host")])
        let temporary = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: hostID,
            target: .file(path: document.target.path), origin: .files, stagedLocalURL: source)))
        XCTAssertNotEqual(temporary, document.id)
        await store.waitForCacheEviction()
        blocked.withLock { $0 = false }
        store.setApplicationForeground(true)
        await store.waitForCacheEviction()
        XCTAssertEqual(store.state, saved)
        guard case let .document(url, _, _, _) = store.content(for: document.id) else { return XCTFail("the restored tab should read the new copy") }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(loader.cachedURL(for: document), "within-budget restored references win over temporary-tab cleanup")
    }

    func testFencedImageStagingRefreshAndAdoptionPreservePersistedLegacySidecars() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let blocked = OSAllocatedUnfairLock(initialState: true)
        let file = ArtifactsStateFile(directory: root, readState: { url in
            if blocked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        let loader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory)
        try ArtifactsStateFile.prepareDirectory(root)
        let source = root.appendingPathComponent("source.md")
        let bytes = Data("![photo](photo.png)".utf8)
        try bytes.write(to: source)
        var document = artifactTestTab(path: "/docs/pinned.md", hostID: bridge.hostID)
        document.hostLabel = "host"
        document.pinned = true
        let adopted = try loader.adopt(source, for: document)
        document.cache = .init(fetchedAt: 1, remoteMTime: nil, size: adopted.size)
        let thumbnail = adopted.localURL.deletingLastPathComponent().appendingPathComponent("image-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: thumbnail)
        let manifestURL = MarkdownImageStaging.manifestURL(for: adopted.localURL)
        let manifest = try JSONEncoder().encode(["photo.png": thumbnail.lastPathComponent])
        try manifest.write(to: manifestURL)
        let seed = ArtifactsStateFile(directory: root)
        let saved = ArtifactsState(tabs: [document], selectedID: document.id)
        seed.schedule(saved)
        seed.flush()
        bridge.files[document.target.path] = Data("new document".utf8)
        let store = ArtifactsStore(stateFile: file, loader: loader, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .file(path: document.target.path), origin: .terminalSelection)))
        guard case let .document(_, _, _, prepare) = store.content(for: id) else { return XCTFail("missing cached document") }
        try await XCTUnwrap(prepare)()
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path), "staging must not sweep a fenced cache's images")
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
        store.refresh(id)
        await store.waitForLoad(id)
        try Data("replacement".utf8).write(to: source)
        XCTAssertEqual(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .file(path: document.target.path), origin: .files, stagedLocalURL: source)), id)
        await store.waitForLoad(id)
        XCTAssertTrue(bridge.downloads.isEmpty, "replacement can also sweep legacy images, so defer it until references are known")
        XCTAssertEqual(try Data(contentsOf: adopted.localURL), bytes)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
        store.close(id)
        blocked.withLock { $0 = false }
        store.setApplicationForeground(true)
        await store.waitForCacheEviction()
        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(MarkdownImageStaging.images(for: adopted.localURL)["photo.png"], thumbnail)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testRecoveryReconcilesTheLatestHostDirectoryBeforePublishingAndPersisting() async throws {
        for removeAll in [false, true] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let hostA = UUID()
            let hostB = UUID()
            var a = artifactTestTab(path: "/docs/a.md", hostID: hostA)
            a.hostLabel = "old A"
            let b = ArtifactTab(id: "B", hostID: hostB.uuidString, hostLabel: "old B",
                                target: .change(path: "/edit", diff: "+B contents", summary: "edit"),
                                title: "edit", openedAt: 1, viewedAt: 1)
            let saved = ArtifactsState(tabs: [a, b], selectedID: b.id)
            let seed = ArtifactsStateFile(directory: root)
            seed.schedule(saved)
            seed.flush()
            let normal = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root))
            XCTAssertEqual(normal.state, saved, "before the first directory arrives, empty hosts means not loaded")
            await normal.waitForCacheEviction()
            let blocked = OSAllocatedUnfairLock(initialState: true)
            let file = ArtifactsStateFile(directory: root, blobRead: { _ in
                if blocked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            })
            let store = ArtifactsStore(stateFile: file)
            XCTAssertTrue(file.isLoadUnavailable)
            store.syncHosts(removeAll ? [] : [ArtifactsHostDirectoryEntry(id: hostA, label: "current A")])
            blocked.withLock { $0 = false }
            store.setApplicationForeground(true)
            XCTAssertFalse(file.isLoadUnavailable)
            XCTAssertNil(store.tab(b.id))
            XCTAssertEqual(store.state.tabs.count, removeAll ? 0 : 1)
            if !removeAll { XCTAssertEqual(store.tab(a.id)?.hostLabel, "current A") }
            store.flush()
            let persisted = ArtifactsStateFile(directory: root).load()
            XCTAssertEqual(persisted, store.state)
            XCTAssertFalse(persisted.tabs.contains { $0.hostID == hostB.uuidString })
            let manifest = try String(contentsOf: seed.stateURL, encoding: .utf8)
            XCTAssertFalse(manifest.contains(hostB.uuidString))
            XCTAssertFalse(manifest.contains("old A"))
            await store.waitForCacheEviction()
        }
    }

    private func assertUnavailableRestore(unavailableManifest: Bool) async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let blocked = OSAllocatedUnfairLock(initialState: true)
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let walks = OSAllocatedUnfairLock(initialState: 0)
        let file = ArtifactsStateFile(directory: root, write: { data, url in
            writes.withLock { $0 += 1 }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }, blobRead: { _ in
            if !unavailableManifest, blocked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
        }, readState: { url in
            reads.withLock { $0 += 1 }
            if unavailableManifest, blocked.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        let loader = ArtifactContentLoader(cacheDirectory: file.cacheDirectory, walkCache: { directory in
            walks.withLock { $0 += 1 }
            return ArtifactContentLoader.cacheSizes(in: directory)
        })
        try ArtifactsStateFile.prepareDirectory(root)
        let source = root.appendingPathComponent("staged.md")
        try Data("cached".utf8).write(to: source)
        var document = artifactTestTab(path: "/docs/readme.md", hostID: bridge.hostID)
        document.hostLabel = "host"
        let adopted = try loader.adopt(source, for: document)
        document.cache = .init(fetchedAt: 1, remoteMTime: 1_000, size: adopted.size)
        let change = ArtifactTab(id: "change", hostID: bridge.hostID.uuidString, hostLabel: "host",
                                 target: .change(path: "/edit", diff: "+kept\n", summary: "edit"),
                                 title: "edit", openedAt: 1, viewedAt: 1)
        let saved = ArtifactsState(tabs: [change, document], selectedID: document.id, filter: .docs)
        let seed = ArtifactsStateFile(directory: root)
        seed.schedule(saved)
        seed.flush()
        let originalManifest = try Data(contentsOf: seed.stateURL)
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let store = ArtifactsStore(stateFile: file, loader: loader, follower: follower,
                                   cacheBudgetBytes: 0, bridgeProvider: { [bridge] })
        XCTAssertTrue(store.state.tabs.isEmpty)
        XCTAssertTrue(file.isLoadUnavailable)
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let temporary = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .change(path: "/temporary", diff: "+temporary", summary: "edit"), origin: .agentEdit)))
        store.noteVisible(temporary)
        store.flush()
        await store.waitForCacheEviction()
        XCTAssertEqual(writes.withLock { $0 }, 0)
        XCTAssertEqual(walks.withLock { $0 }, 0, "cache protection is unknown until the restore succeeds")
        XCTAssertEqual(reads.withLock { $0 }, 1, "no polling retries")
        XCTAssertEqual(try Data(contentsOf: seed.stateURL), originalManifest)
        XCTAssertEqual(try Data(contentsOf: adopted.localURL), Data("cached".utf8))
        XCTAssertNil(follower.tabID)

        store.setApplicationForeground(true)
        XCTAssertTrue(file.isLoadUnavailable, "a failed foreground retry must keep the fence")
        XCTAssertEqual(reads.withLock { $0 }, 2)
        store.flush()
        XCTAssertEqual(writes.withLock { $0 }, 0)

        blocked.withLock { $0 = false }
        if unavailableManifest {
            store.setApplicationForeground(false)
            store.setApplicationForeground(true)
        } else {
            NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            await artifactEventually { !file.isLoadUnavailable }
        }
        XCTAssertFalse(file.isLoadUnavailable)
        XCTAssertEqual(store.state, saved)
        XCTAssertEqual(store.selectedTab?.id, document.id)
        XCTAssertEqual(follower.tabID, document.id)
        XCTAssertEqual(reads.withLock { $0 }, 3)
        await store.waitForCacheEviction()
        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.localURL.path), "restored selection must protect its cached bytes")
        store.flush()
        XCTAssertEqual(writes.withLock { $0 }, 0, "fenced temporary snapshots are superseded by the restore")
        store.setFilter(.changes)
        store.flush()
        XCTAssertGreaterThan(writes.withLock { $0 }, 0)
        XCTAssertEqual(ArtifactsStateFile(directory: root).load(), store.state)
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertTrue(bridge.downloads.isEmpty)
        store.noteVisible(nil)
    }

    func testForwardURLUsesActualLocalPortAndPreservesExplicitSchemeAndLocation() throws {
        let tab = ArtifactTab(id: "page", hostID: "host", hostLabel: "host",
                              target: .page(scheme: "https", port: 3000, path: "/reports/a%20b?q=one%20two#section"),
                              title: ":3000", openedAt: 1, viewedAt: 1)
        let url = try XCTUnwrap(ArtifactPageForwarder.url(for: tab, localPort: 49152))
        XCTAssertEqual(url.absoluteString, "https://127.0.0.1:49152/reports/a%20b?q=one%20two#section")
        XCTAssertNil(ArtifactPageForwarder.url(for: tab, localPort: 0))
    }

    func testOpenDedupeSelectionCloseAndUnknownHostUseReducerPolicy() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        var time: Int64 = 10
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), now: { time }, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        let first = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/./guide.md"), origin: .files)))
        time = 20
        XCTAssertEqual(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/guide.md"), origin: .terminalSelection)), first)
        XCTAssertEqual(store.state.tabs.count, 1)
        XCTAssertEqual(store.tab(first)?.viewedAt, 20)
        XCTAssertNil(store.open(ArtifactOpenRequest(hostID: UUID(), target: .file(path: "/unknown"), origin: .files)))
        XCTAssertNil(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .change(path: "", diff: "+new", summary: "edit"), origin: .agentEdit)))

        let change = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .change(path: "/srv/guide.md", diff: "+new", summary: "edit"), origin: .agentEdit)))
        XCTAssertEqual(store.selectedTab?.id, change)
        store.select(first)
        store.setPinned(first, true)
        store.setFilter(.docs)
        XCTAssertEqual(store.selectedTab?.id, first)
        XCTAssertEqual(store.tab(first)?.pinned, true)
        XCTAssertEqual(store.overview(query: "guide").groups.first?.tabIDs, [first])
        store.close(first)
        XCTAssertEqual(store.selectedTab?.id, change)
        if case let .change(path, diff) = store.content(for: change) {
            XCTAssertEqual(path, "/srv/guide.md")
            XCTAssertEqual(diff, "+new")
        } else { XCTFail("a change is an offline snapshot") }
        store.closeAll(hostID: bridge.hostID.uuidString)
        XCTAssertTrue(store.state.tabs.isEmpty)
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertTrue(bridge.downloads.isEmpty)
    }

    func testStoreFlushRoundTripsAndHostRelabelRemovalDeletesCache() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("staged.md")
        try Data("offline copy".utf8).write(to: source)
        let hostID = UUID()
        let file = ArtifactsStateFile(directory: root)
        let store = ArtifactsStore(stateFile: file)
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "before")])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: hostID, target: .file(path: "/srv/notes.md"), origin: .files, stagedLocalURL: source)))
        store.setPinned(id, true)
        store.flush()
        XCTAssertEqual(file.load(), store.state)
        let restored = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root))
        XCTAssertEqual(restored.state, store.state)
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "after")])
        XCTAssertEqual(store.tab(id)?.hostLabel, "after")
        let localURL: URL
        if case let .document(url, _, _, prepareImages) = store.content(for: id) {
            localURL = url
            XCTAssertNil(prepareImages)
        } else { return XCTFail("offline staged copy should be readable") }
        XCTAssertEqual(store.presentation(for: id).state, .cached)
        store.syncHosts([])
        XCTAssertNil(store.tab(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the caller retains its staged file")
        store.flush()
        XCTAssertEqual(file.load(), ArtifactsState())
    }

    func testOfflineWithAndWithoutCacheNeverConnects() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .dropped
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/uncached.md"), origin: .files)))
        store.refresh(id)
        store.noteVisible(id)
        if case .unavailable(.offline) = store.content(for: id) { } else { XCTFail("no bytes and no bridge is offline") }
        XCTAssertEqual(store.presentation(for: id).canRefresh, false)
        XCTAssertFalse(store.isLive(hostID: bridge.hostID.uuidString))
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertTrue(bridge.listings.isEmpty)
    }

    func testFollowPollsOnlyVisibleFileAndStopsHiddenBackgroundAndOffline() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let bridge = ArtifactTestBridge()
        bridge.files = ["/a/first.md": Data("first".utf8), "/b/second.md": Data("second".utf8)]
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let a = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/a/first.md"), origin: .files)))
        let b = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/b/second.md"), origin: .files)))
        await artifactEventually { store.tab(a)?.cache != nil && store.tab(b)?.cache != nil }
        store.select(a)
        store.noteVisible(a)
        await artifactEventually { await clock.pendingCount == 1 }
        let durations = await clock.durations
        XCTAssertEqual(durations, [3_000_000_000])
        let oldToken: Int
        if case let .document(_, _, token, _) = store.content(for: a) { oldToken = token }
        else { return XCTFail("first file should be loaded") }
        bridge.attributePaths.removeAll()
        bridge.modified = Date(timeIntervalSince1970: 2)
        bridge.files["/a/first.md"] = Data("new first".utf8)
        await clock.tick()
        await artifactEventually { store.tab(a)?.cache?.remoteMTime == 2_000 }
        XCTAssertFalse(bridge.attributePaths.contains("/b/second.md"))
        XCTAssertFalse(store.tab(a)?.unseenChange ?? true)
        if case let .document(url, _, token, _) = store.content(for: a) {
            XCTAssertGreaterThan(token, oldToken)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new first")
        } else { XCTFail("follow should replace the visible document") }

        store.noteVisible(nil)
        await artifactEventually { await clock.pendingCount == 0 }
        let hiddenCount = bridge.attributePaths.count
        await clock.tick()
        XCTAssertEqual(bridge.attributePaths.count, hiddenCount)
        store.noteVisible(a)
        await artifactEventually { await clock.pendingCount == 1 }
        store.setApplicationForeground(false)
        XCTAssertNil(follower.tabID)
        await artifactEventually { await clock.pendingCount == 0 }
        await clock.tick()
        XCTAssertEqual(bridge.attributePaths.count, hiddenCount)
        store.setApplicationForeground(true)
        await artifactEventually { await clock.pendingCount == 1 }
        bridge.state = .dropped
        await artifactEventually { follower.tabID == nil }
        await clock.tick()
        XCTAssertEqual(bridge.attributePaths.count, hiddenCount)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    /// A visible tab navigated to another file keeps being followed, on
    /// that file: following restarts so no stat of the old one lands on it.
    func testFollowingRestartsOnTheFileANavigatedTabNowShows() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let bridge = ArtifactTestBridge()
        bridge.files = ["/a/first.md": Data("first".utf8), "/c/third.md": Data("third".utf8)]
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let a = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/a/first.md"), origin: .files)))
        await artifactEventually { store.tab(a)?.cache != nil }
        store.noteVisible(a)
        await artifactEventually { await clock.pendingCount == 1 }

        let outcome = await store.quickOpen("host:/c/third.md", currentHostID: bridge.hostID.uuidString, placement: .navigate(tabID: a))
        XCTAssertEqual(outcome, .opened(tabID: a))
        await artifactEventually { store.tab(a)?.cache != nil }
        await artifactEventually { await clock.pendingCount == 1 }
        XCTAssertEqual(follower.tabID, a)
        bridge.attributePaths.removeAll()
        await clock.tick()
        await artifactEventually { !bridge.attributePaths.isEmpty }
        XCTAssertEqual(Set(bridge.attributePaths), ["/c/third.md"])
    }

    func testAgentEditMarksMatchingBackgroundFileAndRefreshesVisibleFile() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files = ["/a/first.md": Data("first".utf8), "/b/second.md": Data("second".utf8)]
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let a = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/a/first.md"), origin: .files)))
        let b = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/b/second.md"), origin: .files)))
        await artifactEventually { store.tab(a)?.cache != nil && store.tab(b)?.cache != nil }
        store.select(a)
        store.noteVisible(a)
        store.agentEditObserved(hostID: bridge.hostID, absolutePath: "/b/./second.md")
        XCTAssertEqual(store.tab(b)?.unseenChange, true)
        XCTAssertEqual(store.tab(a)?.unseenChange, false)
        let previousDownloads = bridge.downloads.count
        bridge.files["/a/first.md"] = Data("edited".utf8)
        store.agentEditObserved(hostID: bridge.hostID, absolutePath: "/a/first.md")
        await artifactEventually { bridge.downloads.count > previousDownloads && store.tab(a)?.cache?.isStale == false }
        XCTAssertEqual(store.tab(a)?.unseenChange, false)
        store.agentEditObserved(hostID: bridge.hostID, absolutePath: "relative.md")
        XCTAssertEqual(bridge.connectCalls, 0)
        store.noteVisible(nil)
    }

    func testHTMLServesLiveAndFallsBackToCachedSourceOffline() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/index.html"] = Data("<h1>built</h1>".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/index.html"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        if case let .servedPage(url, registration) = store.content(for: id) {
            XCTAssertEqual(url.scheme, "tessera-artifact")
            XCTAssertEqual(url.host, id.lowercased())
            XCTAssertEqual(url.lastPathComponent, "index.html")
            XCTAssertEqual(registration.scheme, "tessera-artifact")
        } else { XCTFail("live HTML should use the scheme reader") }
        bridge.state = .dropped
        if case let .document(url, _, _, prepareImages) = store.content(for: id) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "<h1>built</h1>")
            XCTAssertNil(prepareImages)
        } else { XCTFail("offline HTML should be readable as cached source") }
        XCTAssertEqual(store.presentation(for: id).state, .cached)
    }

    func testStartupReapsAbandonedPartialAndEvictsItsDirectory() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ArtifactsStateFile(directory: root)
        let directory = file.cacheDirectory.appendingPathComponent("orphan")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("interrupted".utf8).write(to: directory.appendingPathComponent(".partial-\(UUID().uuidString)"))
        try Data("old".utf8).write(to: directory.appendingPathComponent("old.txt"))
        let store = ArtifactsStore(stateFile: file, cacheBudgetBytes: 0)
        await store.waitForCacheEviction()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPinnedPartialNamedDocumentAndImagesSurviveOfflineRestart() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        try Data("![photo](photo.png)".utf8).write(to: source)
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/.partial-report.md"),
                                                            origin: .files, stagedLocalURL: source)))
        store.setPinned(id, true)
        store.flush()
        await store.waitForCacheEviction()
        guard case let .document(document, _, _, _) = store.content(for: id) else { return XCTFail("missing adopted document") }
        let thumbnail = document.deletingLastPathComponent().appendingPathComponent("image-\(UUID().uuidString).png")
        let manifest = MarkdownImageStaging.manifestURL(for: document)
        try Data([1, 2, 3]).write(to: thumbnail)
        try JSONEncoder().encode(["photo.png": thumbnail.lastPathComponent]).write(to: manifest)

        let restarted = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), cacheBudgetBytes: 0, bridgeProvider: { [bridge] })
        await restarted.waitForCacheEviction()
        XCTAssertEqual(restarted.tab(id)?.pinned, true)
        guard case let .document(restored, _, _, prepareImages) = restarted.content(for: id) else { return XCTFail("offline document was deleted") }
        XCTAssertEqual(try Data(contentsOf: restored), Data("![photo](photo.png)".utf8))
        XCTAssertEqual(MarkdownImageStaging.images(for: restored), ["photo.png": thumbnail])
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertEqual(try Data(contentsOf: thumbnail), Data([1, 2, 3]))
        XCTAssertNil(prepareImages)
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertTrue(bridge.downloads.isEmpty)
    }

    func testFollowerReusesImagesAndExplicitRefreshRedownloadsWithUnchangedStat() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let path = "/docs/readme.md"
        bridge.files[path] = Data("![photo](photo.png)".utf8)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        var first = renderer.pngData { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        var replacement = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let bytes = max(first.count, replacement.count)
        first.append(Data(repeating: 0, count: bytes - first.count))
        replacement.append(Data(repeating: 0, count: bytes - replacement.count))
        bridge.files["/docs/photo.png"] = first
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: path), origin: .terminalSelection)))
        await artifactEventually { store.tab(id)?.cache != nil }
        guard case let .document(document, _, firstToken, initialPreparation) = store.content(for: id) else { return XCTFail("missing document") }
        try await XCTUnwrap(initialPreparation)()
        let original = MarkdownImageStaging.images(for: document)
        let thumbnail = try XCTUnwrap(original["photo.png"])
        let oldBytes = try Data(contentsOf: thumbnail)
        bridge.downloads.removeAll()
        bridge.files["/docs/photo.png"] = replacement
        bridge.files[path] = Data("![photo](photo.png)\nnew prose".utf8)
        store.noteVisible(id)
        await artifactEventually { await clock.pendingCount == 1 }
        await clock.tick()
        await artifactEventually {
            if case let .document(_, _, token, _) = store.content(for: id) { return token > firstToken }
            return false
        }
        store.noteVisible(nil)
        guard case let .document(_, _, followerToken, followerPreparation) = store.content(for: id) else { return XCTFail("missing follower document") }
        try await XCTUnwrap(followerPreparation)()
        XCTAssertEqual(bridge.downloads, [path], "the follower must not download unchanged image stats")
        XCTAssertEqual(MarkdownImageStaging.images(for: document), original)

        bridge.downloads.removeAll()
        store.refresh(id)
        await artifactEventually {
            if case let .document(_, _, token, _) = store.content(for: id) { return token > followerToken }
            return false
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path), "keep the previous thumbnail until staging completes")
        guard case let .document(_, _, _, explicitPreparation) = store.content(for: id) else { return XCTFail("missing explicit refresh") }
        try await XCTUnwrap(explicitPreparation)()
        XCTAssertEqual(bridge.downloads, [path, "/docs/photo.png"])
        let refreshed = try XCTUnwrap(MarkdownImageStaging.images(for: document)["photo.png"])
        XCTAssertNotEqual(try Data(contentsOf: refreshed), oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
        bridge.downloads.removeAll()
        try await XCTUnwrap(explicitPreparation)()
        XCTAssertTrue(bridge.downloads.isEmpty, "one accepted explicit refresh must only force one staging")
        XCTAssertEqual(bridge.modified, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(bridge.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    func testAgentEditSupersedingAnExplicitRefreshBeforeDocumentAcceptanceStillForcesImagesOnce() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let path = "/docs/readme.md"
        bridge.files[path] = Data("![photo](photo.png)".utf8)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        var first = renderer.pngData { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        var replacement = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let bytes = max(first.count, replacement.count)
        first.append(Data(repeating: 0, count: bytes - first.count))
        replacement.append(Data(repeating: 0, count: bytes - replacement.count))
        bridge.files["/docs/photo.png"] = first
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: path), origin: .terminalSelection)))
        await artifactEventually { store.tab(id)?.cache != nil }
        store.noteVisible(id)
        guard case let .document(document, _, token, initial) = store.content(for: id) else { return XCTFail("missing document") }
        try await XCTUnwrap(initial)()
        let thumbnail = try XCTUnwrap(MarkdownImageStaging.images(for: document)["photo.png"])
        let oldBytes = try Data(contentsOf: thumbnail)
        bridge.files["/docs/photo.png"] = replacement
        bridge.downloads.removeAll()
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        store.refresh(id)
        await artifactEventually { await gate.pendingCount == 1 }
        bridge.downloadGate = nil
        store.agentEditObserved(hostID: bridge.hostID, absolutePath: path)
        await artifactEventually {
            if case let .document(_, _, current, _) = store.content(for: id) { return current > token }
            return false
        }
        await artifactEventually { await gate.pendingCount == 0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
        guard case let .document(_, _, _, prepare) = store.content(for: id) else { return XCTFail("missing replacement load") }
        try await XCTUnwrap(prepare)()
        XCTAssertEqual(bridge.downloads, [path, path, "/docs/photo.png"], "a replacement load must inherit explicit image refresh intent")
        let refreshed = try XCTUnwrap(MarkdownImageStaging.images(for: document)["photo.png"])
        XCTAssertNotEqual(try Data(contentsOf: refreshed), oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
        bridge.downloads.removeAll()
        try await XCTUnwrap(prepare)()
        XCTAssertTrue(bridge.downloads.isEmpty, "successful staging consumes the intent exactly once")
        XCTAssertEqual(bridge.modified, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(bridge.connectCalls, 0)
        store.noteVisible(nil)
        await store.waitForCacheEviction()
    }

    /// A forced image that keeps failing must not redownload every image on
    /// each revisit over the same connection; the next connection retries.
    func testPendingImageRefreshWaitsForTheNextConnectionInsteadOfRedownloadingOnRevisits() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactImageFailureTestBridge()
        let path = "/docs/readme.md"
        let imagePath = "/docs/photo.png"
        let healthyPath = "/docs/healthy.png"
        bridge.base.files[path] = Data("![photo](photo.png) ![healthy](healthy.png)".utf8)
        bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        bridge.base.files[healthyPath] = UIGraphicsImageRenderer(size: CGSize(width: 5, height: 5)).pngData { _ in }
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        let sessions = [artifactStoreLiveSession(hostID: bridge.base.hostID)]
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
        store.updateSessions(sessions)
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
            target: .file(path: path), origin: .terminalSelection)))
        await store.waitForLoad(id)
        guard case let .document(document, _, token, initial) = store.content(for: id) else { return XCTFail("missing document") }
        try await XCTUnwrap(initial)()
        let original = MarkdownImageStaging.images(for: document)
        XCTAssertNotNil(original["photo.png"])
        XCTAssertNotNil(original["healthy.png"])
        bridge.downloadAttempts.removeAll()
        bridge.downloadErrors[imagePath] = FileBridgeError.network("interrupted")
        store.refresh(id)
        await store.waitForLoad(id)
        guard case let .document(_, _, refreshedToken, prepare) = store.content(for: id) else { return XCTFail("missing refreshed document") }
        XCTAssertGreaterThan(refreshedToken, token)
        try await XCTUnwrap(prepare)()
        XCTAssertEqual(bridge.downloadAttempts, [path, imagePath, healthyPath])
        XCTAssertEqual(MarkdownImageStaging.images(for: document)["photo.png"], original["photo.png"],
                       "a network error leaves the image refresh pending")
        let generation = store.imageGeneration(for: id)

        for _ in 1...10 {
            store.select(id)
            await store.waitForLoad(id)
            guard case let .document(_, _, currentToken, remount) = store.content(for: id) else { return XCTFail("missing cached document") }
            XCTAssertEqual(currentToken, refreshedToken)
            try await XCTUnwrap(remount)()
        }
        XCTAssertEqual(store.imageGeneration(for: id), generation, "a revisit is not a new opportunity")
        XCTAssertEqual(bridge.downloadAttempts, [path, imagePath, healthyPath], "revisits on the same connection do no remote work")

        bridge.downloadErrors.removeAll()
        bridge.base.state = .dropped
        store.updateSessions(sessions)
        bridge.base.state = .connected
        store.updateSessions(sessions)
        store.select(id)
        await store.waitForLoad(id)
        XCTAssertEqual(store.imageGeneration(for: id), generation + 1)
        guard case let .document(_, _, retryToken, retry) = store.content(for: id) else { return XCTFail("missing retry") }
        XCTAssertEqual(retryToken, refreshedToken)
        try await XCTUnwrap(retry)()
        XCTAssertEqual(bridge.downloadAttempts.filter { $0 == path }.count, 1, "the document refresh was already accepted")
        XCTAssertEqual(bridge.downloadAttempts.filter { $0 == imagePath }.count, 2, "the next connection still forces the image despite matching stat")
        XCTAssertNotEqual(MarkdownImageStaging.images(for: document)["photo.png"], original["photo.png"])
        bridge.downloadAttempts.removeAll()
        try await XCTUnwrap(retry)()
        XCTAssertTrue(bridge.downloadAttempts.isEmpty, "successful staging consumes the image intent")
        XCTAssertEqual(bridge.base.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    func testMountedMarkdownRetriesPendingImagesOncePerReconnectAndForegroundWithoutDocumentFetch() async throws {
        for definitiveFailure in [false, true] {
            try await assertMountedMarkdownImageRetry(definitiveFailure: definitiveFailure)
        }
    }

    /// The deferred observer can miss every disconnected state of an in-place
    /// reconnect. Its connection generation still gives pending images one retry.
    func testMountedMarkdownRetriesOnceWhenTheSameBridgeAdvancesItsConnectionGeneration() async throws {
        for explicitReconcile in [false, true] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactConnectionTestBridge()
            let path = "/docs/readme.md"
            let imagePath = "/docs/photo.png"
            bridge.base.files[path] = Data("![photo](photo.png)".utf8)
            bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
            let clock = ArtifactTestClock()
            let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
            defer { store.noteVisible(nil) }
            let sessions = [artifactStoreLiveSession(hostID: bridge.base.hostID)]
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
            store.updateSessions(sessions)
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
                target: .file(path: path), origin: .terminalSelection)))
            await store.waitForLoad(id)
            store.noteVisible(id)
            guard case let .document(_, _, token, initial) = store.content(for: id) else { return XCTFail("missing document") }
            bridge.base.failAfterWrite = true
            bridge.base.downloads.removeAll()
            bridge.base.attributePaths.removeAll()
            try await XCTUnwrap(initial)()
            let generation = store.imageGeneration(for: id)
            XCTAssertEqual(generation, 0, "the first noted connection does not spend an unattempted staging")
            XCTAssertEqual(bridge.base.downloads, [imagePath])
            XCTAssertEqual(bridge.base.attributePaths, [imagePath])

            bridge.connectionGeneration += 1
            XCTAssertEqual(bridge.state, .connected, "no intermediate disconnected state is ever observed")
            if explicitReconcile { store.updateSessions(sessions) }
            await artifactEventually { store.imageGeneration(for: id) == generation + 1 }
            XCTAssertEqual(store.imageGeneration(for: id), generation + 1)
            XCTAssertEqual(bridge.base.downloads, [imagePath], "offering the retry does no remote work")
            guard case let .document(_, _, retryToken, retry) = store.content(for: id) else { return XCTFail("missing retry") }
            XCTAssertEqual(retryToken, token, "a new connection retries images without fetching the document")
            try await XCTUnwrap(retry)()

            for _ in 0..<10 {
                store.updateSessions(sessions)
                guard case let .document(_, _, currentToken, remount) = store.content(for: id) else { return XCTFail("missing document") }
                XCTAssertEqual(currentToken, token)
                try await XCTUnwrap(remount)()
            }
            XCTAssertEqual(store.imageGeneration(for: id), generation + 1, "one opportunity, even when its retry also falls short")
            XCTAssertEqual(bridge.base.downloads, [imagePath, imagePath], "exactly one new staging run")
            XCTAssertEqual(bridge.base.attributePaths, [imagePath, imagePath], "remounts and duplicate reconciles do not restat images")
            XCTAssertEqual(bridge.base.connectCalls, 0)
            await store.waitForCacheEviction()
        }
    }

    func testPendingImagesDoNotRetryForStableConnectionNotifications() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactConnectionTestBridge()
        let otherHost = ArtifactConnectionTestBridge()
        let path = "/docs/readme.md"
        let imagePath = "/docs/photo.png"
        bridge.base.files[path] = Data("![photo](photo.png)".utf8)
        bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower,
                                   bridgeProvider: { [bridge, otherHost] })
        defer { store.noteVisible(nil) }
        let sessions = [bridge, otherHost].map { artifactStoreLiveSession(hostID: $0.base.hostID) }
        store.syncHosts([bridge, otherHost].map { ArtifactsHostDirectoryEntry(id: $0.base.hostID, label: "host") })
        store.updateSessions(sessions)
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
            target: .file(path: path), origin: .terminalSelection)))
        await store.waitForLoad(id)
        store.noteVisible(id)
        guard case let .document(_, _, token, initial) = store.content(for: id) else { return XCTFail("missing document") }
        bridge.base.failAfterWrite = true
        try await XCTUnwrap(initial)()
        let generation = store.imageGeneration(for: id)
        bridge.base.downloads.removeAll()
        bridge.base.attributePaths.removeAll()

        for notification in 0..<10 {
            bridge.base.state = .connected
            store.updateSessions(sessions)
            bridge.base.homeDirectory = "/home/test/\(notification)"
            store.updateSessions(sessions)
            bridge.base.artifactForwarding = PortForwarderManager()
            store.updateSessions(sessions)
            otherHost.connectionGeneration += 1
            store.updateSessions(sessions)
            guard case let .document(_, _, currentToken, remount) = store.content(for: id) else { return XCTFail("missing document") }
            XCTAssertEqual(currentToken, token)
            try await XCTUnwrap(remount)()
        }
        XCTAssertEqual(store.imageGeneration(for: id), generation, "a stable connection never begins a new image opportunity")
        XCTAssertTrue(bridge.base.downloads.isEmpty, "notifications do not restage images or fetch the document")
        XCTAssertTrue(bridge.base.attributePaths.isEmpty, "the deterministic follower never ticks; notifications do no remote stats")
        XCTAssertTrue(otherHost.base.downloads.isEmpty)
        XCTAssertEqual(bridge.base.connectCalls + otherHost.base.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    private func assertMountedMarkdownImageRetry(definitiveFailure: Bool) async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactImageFailureTestBridge()
        let path = "/docs/readme.md"
        let imagePath = "/docs/photo.png"
        bridge.base.files[path] = Data("![photo](photo.png)".utf8)
        bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
        defer { store.noteVisible(nil) }
        let hosts = [ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")]
        let sessions = [artifactStoreLiveSession(hostID: bridge.base.hostID)]
        store.syncHosts(hosts)
        store.updateSessions(sessions)
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
            target: .file(path: path), origin: .terminalSelection)))
        await store.waitForLoad(id)
        store.noteVisible(id)
        guard case let .document(document, title, _, initial) = store.content(for: id) else { return XCTFail("missing document") }
        try await XCTUnwrap(initial)()
        bridge.downloadErrors[imagePath] = FileBridgeError.network("interrupted")
        store.refresh(id)
        await store.waitForLoad(id)
        guard case let .document(_, _, token, prepare) = store.content(for: id) else { return XCTFail("missing refreshed document") }
        try await XCTUnwrap(prepare)()
        let generation = store.imageGeneration(for: id)
        let identity = ArtifactDocumentView(localURL: document, title: title, prepareImages: prepare,
                                            reloadToken: token).markdownPresenter.markdownTaskIdentity
        bridge.downloadAttempts.removeAll()

        for _ in 0..<10 {
            _ = store.content(for: id)
            store.select(id)
            store.noteVisible(id)
            store.updateSessions(sessions)
        }
        XCTAssertEqual(store.imageGeneration(for: id), generation, "rendering and duplicate live notifications are not retry opportunities")
        XCTAssertTrue(bridge.downloadAttempts.isEmpty)

        bridge.base.state = .dropped
        store.updateSessions(sessions)
        store.select(id)
        store.refresh(id)
        store.setApplicationForeground(false)
        store.setApplicationForeground(true)
        XCTAssertEqual(store.imageGeneration(for: id), generation, "offline foregrounding must not advance images")
        XCTAssertTrue(bridge.downloadAttempts.isEmpty)
        XCTAssertEqual(bridge.base.connectCalls, 0)
        guard case let .document(_, _, offlineToken, offlinePreparation) = store.content(for: id) else { return XCTFail("keep the mounted document offline") }
        XCTAssertEqual(offlineToken, token)
        XCTAssertNil(offlinePreparation)

        bridge.base.state = .connected
        store.updateSessions(sessions)
        XCTAssertEqual(store.imageGeneration(for: id), generation + 1)
        guard case let .document(_, _, liveToken, retry) = store.content(for: id) else { return XCTFail("missing retry content") }
        XCTAssertEqual(liveToken, token, "image retries never change document identity")
        let retriedIdentity = ArtifactDocumentView(localURL: document, title: title, prepareImages: retry,
                                                   reloadToken: liveToken).markdownPresenter.markdownTaskIdentity
        XCTAssertNotEqual(retriedIdentity, identity, "the mounted Markdown task must see the retry")
        XCTAssertEqual(retriedIdentity.fileURL, identity.fileURL)
        store.select(id)
        store.noteVisible(id)
        store.updateSessions(sessions)
        store.setApplicationForeground(true)
        XCTAssertEqual(store.imageGeneration(for: id), generation + 1)
        XCTAssertTrue(bridge.downloadAttempts.isEmpty, "scheduling an image retry must not fetch the document")
        try await XCTUnwrap(retry)()
        XCTAssertEqual(bridge.downloadAttempts, [imagePath])

        store.setApplicationForeground(false)
        store.setApplicationForeground(true)
        store.setApplicationForeground(true)
        XCTAssertEqual(store.imageGeneration(for: id), generation + 2, "one retry for a live foreground transition")
        guard case let .document(_, _, foregroundToken, foregroundRetry) = store.content(for: id) else { return XCTFail("missing foreground retry") }
        XCTAssertEqual(foregroundToken, token)
        bridge.downloadErrors.removeAll()
        if definitiveFailure { bridge.downloadErrors[imagePath] = FileBridgeError.remoteStatus(code: 3, message: "permission denied") }
        try await XCTUnwrap(foregroundRetry)()
        XCTAssertEqual(bridge.downloadAttempts, [imagePath, imagePath])
        let completedIdentity = ArtifactDocumentView(localURL: document, title: title, prepareImages: foregroundRetry,
                                                     reloadToken: foregroundToken).markdownPresenter.markdownTaskIdentity
        bridge.downloadAttempts.removeAll()
        bridge.base.state = .dropped
        store.updateSessions(sessions)
        guard case let .document(_, _, _, offlineImages) = store.content(for: id) else { return XCTFail("missing offline document") }
        XCTAssertEqual(ArtifactDocumentView(localURL: document, title: title, prepareImages: offlineImages,
                                            reloadToken: token).markdownPresenter.markdownTaskIdentity, completedIdentity)
        try await XCTUnwrap(offlineImages)()
        XCTAssertTrue(bridge.downloadAttempts.isEmpty)
        bridge.base.state = .connected
        store.updateSessions(sessions)
        store.setApplicationForeground(false)
        store.setApplicationForeground(true)
        XCTAssertEqual(store.imageGeneration(for: id), generation + 2, "completed images do not restage on later lifecycle events")
        guard case let .document(_, _, _, completedImages) = store.content(for: id) else { return XCTFail("missing completed document") }
        XCTAssertEqual(ArtifactDocumentView(localURL: document, title: title, prepareImages: completedImages,
                                            reloadToken: token).markdownPresenter.markdownTaskIdentity, completedIdentity)
        XCTAssertTrue(bridge.downloadAttempts.isEmpty)
        XCTAssertEqual(bridge.base.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    /// A Files open forces its fetch, so its pending images belong to the
    /// loader rather than to a Refresh; a terminal open's staging is never
    /// forced. Either way a document left on screen retries a transiently
    /// failed image once per new connection, without fetching the document.
    func testMountedMarkdownRetriesTransientImageFailuresWithoutARefresh() async throws {
        for origin in [ArtifactOpenOrigin.files, .terminalSelection] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactImageFailureTestBridge()
            let path = "/docs/readme.md"
            let imagePath = "/docs/photo.png"
            bridge.base.files[path] = Data("![photo](photo.png)".utf8)
            bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
            bridge.downloadErrors[imagePath] = FileBridgeError.network("interrupted")
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
            let sessions = [artifactStoreLiveSession(hostID: bridge.base.hostID)]
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
            store.updateSessions(sessions)
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
                target: .file(path: path), origin: origin)))
            await store.waitForLoad(id)
            store.noteVisible(id)
            guard case let .document(document, _, token, initial) = store.content(for: id) else {
                return XCTFail("missing document for \(origin)")
            }
            try await XCTUnwrap(initial)()
            XCTAssertNil(MarkdownImageStaging.images(for: document)["photo.png"])
            let generation = store.imageGeneration(for: id)
            for _ in 0..<3 {
                store.select(id)
                store.noteVisible(id)
                store.updateSessions(sessions)
            }
            XCTAssertEqual(store.imageGeneration(for: id), generation, "the connection that failed is spent (\(origin))")

            bridge.base.state = .dropped
            store.updateSessions(sessions)
            bridge.base.state = .connected
            store.updateSessions(sessions)
            store.updateSessions(sessions)
            XCTAssertEqual(store.imageGeneration(for: id), generation + 1, "one retry per new connection (\(origin))")
            guard case let .document(_, _, liveToken, retry) = store.content(for: id) else {
                return XCTFail("missing retry for \(origin)")
            }
            XCTAssertEqual(liveToken, token)
            bridge.downloadErrors.removeAll()
            bridge.downloadAttempts.removeAll()
            try await XCTUnwrap(retry)()
            XCTAssertEqual(bridge.downloadAttempts, [imagePath], "a retry fetches the image only (\(origin))")
            XCTAssertNotNil(MarkdownImageStaging.images(for: document)["photo.png"])

            bridge.base.state = .dropped
            store.updateSessions(sessions)
            bridge.base.state = .connected
            store.updateSessions(sessions)
            store.setApplicationForeground(false)
            store.setApplicationForeground(true)
            XCTAssertEqual(store.imageGeneration(for: id), generation + 1, "completed images stay put (\(origin))")
            XCTAssertEqual(bridge.base.connectCalls, 0)
            store.noteVisible(nil)
            await store.waitForCacheEviction()
        }
    }

    /// Staging that a dropped connection cuts off, or that finds none, waits
    /// for the next connection rather than for the document to be reopened.
    func testMarkdownStagingCutOffByADroppedConnectionRetriesOnReconnect() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactImageFailureTestBridge()
        let path = "/docs/readme.md"
        let imagePath = "/docs/photo.png"
        bridge.base.files[path] = Data("![photo](photo.png)".utf8)
        bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        defer { store.noteVisible(nil) }
        let sessions = [artifactStoreLiveSession(hostID: bridge.base.hostID)]
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
        store.updateSessions(sessions)
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
            target: .file(path: path), origin: .terminalSelection)))
        await store.waitForLoad(id)
        store.noteVisible(id)
        guard case let .document(document, _, _, initial) = store.content(for: id) else { return XCTFail("missing document") }
        let generation = store.imageGeneration(for: id)
        bridge.base.state = .dropped
        store.updateSessions(sessions)
        bridge.downloadAttempts.removeAll()
        try await XCTUnwrap(initial)()
        XCTAssertTrue(bridge.downloadAttempts.isEmpty, "nothing stages without a connection")
        XCTAssertEqual(store.imageGeneration(for: id), generation)

        bridge.base.state = .connected
        store.updateSessions(sessions)
        XCTAssertEqual(store.imageGeneration(for: id), generation + 1)
        guard case let .document(_, _, _, retry) = store.content(for: id) else { return XCTFail("missing retry") }
        try await XCTUnwrap(retry)()
        XCTAssertEqual(bridge.downloadAttempts, [imagePath])
        XCTAssertNotNil(MarkdownImageStaging.images(for: document)["photo.png"])
        bridge.base.state = .dropped
        store.updateSessions(sessions)
        bridge.base.state = .connected
        store.updateSessions(sessions)
        XCTAssertEqual(store.imageGeneration(for: id), generation + 1)
        XCTAssertEqual(bridge.base.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    /// A staging that fails only after its connection was replaced, or after
    /// the app left the foreground, spends the opportunity it started on. The
    /// newer one still retries the shown document once.
    func testLateImageFailureSpendsOnlyTheOpportunityItStartedOn() async throws {
        for interruption in ["reconnect", "background"] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactImageFailureTestBridge()
            let path = "/docs/readme.md"
            let imagePath = "/docs/photo.png"
            bridge.base.files[path] = Data("![photo](photo.png)".utf8)
            bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
            let sessions = [artifactStoreLiveSession(hostID: bridge.base.hostID)]
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
            store.updateSessions(sessions)
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
                target: .file(path: path), origin: .terminalSelection)))
            await store.waitForLoad(id)
            store.noteVisible(id)
            guard case let .document(document, _, token, initial) = store.content(for: id) else {
                return XCTFail("missing document (\(interruption))")
            }
            let generation = store.imageGeneration(for: id)
            let gate = ArtifactTestClock()
            bridge.base.downloadGate = gate
            bridge.base.failAfterWrite = true
            let staging = Task { @MainActor in try? await XCTUnwrap(initial)() }
            await artifactEventually { await gate.pendingCount == 1 }
            if interruption == "reconnect" {
                bridge.base.state = .dropped
                store.updateSessions(sessions)
                bridge.base.state = .connected
                store.updateSessions(sessions)
            } else {
                store.setApplicationForeground(false)
            }
            XCTAssertEqual(store.imageGeneration(for: id), generation, "nothing has fallen short yet (\(interruption))")
            await gate.tick()
            await staging.value
            if interruption == "background" {
                XCTAssertEqual(store.imageGeneration(for: id), generation, "a background failure waits (\(interruption))")
                store.setApplicationForeground(true)
            }
            XCTAssertEqual(store.imageGeneration(for: id), generation + 1,
                           "the newer opportunity is not spent by the older failure (\(interruption))")
            store.updateSessions(sessions)
            store.select(id)
            XCTAssertEqual(store.imageGeneration(for: id), generation + 1, "one retry (\(interruption))")
            bridge.base.downloadGate = nil
            bridge.base.failAfterWrite = false
            bridge.downloadAttempts.removeAll()
            guard case let .document(_, _, retryToken, retry) = store.content(for: id) else {
                return XCTFail("missing retry (\(interruption))")
            }
            XCTAssertEqual(retryToken, token)
            try await XCTUnwrap(retry)()
            XCTAssertEqual(bridge.downloadAttempts, [imagePath], "the retry fetches the image only (\(interruption))")
            XCTAssertNotNil(MarkdownImageStaging.images(for: document)["photo.png"])
            XCTAssertEqual(bridge.base.connectCalls, 0)
            store.noteVisible(nil)
            await store.waitForCacheEviction()
        }
    }

    /// A restart forgets which documents fell short. One shown offline has no
    /// staging action; the first connection while it stays on screen gives
    /// it a new staging task, so its missing images arrive without a remount.
    func testUnfinishedMarkdownShownOfflineAfterARestartStagesOnTheFirstConnection() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactImageFailureTestBridge()
        let path = "/docs/readme.md"
        let imagePath = "/docs/photo.png"
        bridge.base.files[path] = Data("![photo](photo.png)".utf8)
        bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        bridge.downloadErrors[imagePath] = FileBridgeError.network("interrupted")
        let hosts = [ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")]
        let sessions = [artifactStoreLiveSession(hostID: bridge.base.hostID)]
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts(hosts)
        store.updateSessions(sessions)
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
            target: .file(path: path), origin: .terminalSelection)))
        await store.waitForLoad(id)
        guard case let .document(_, _, _, initial) = store.content(for: id) else { return XCTFail("missing document") }
        try await XCTUnwrap(initial)()
        store.flush()
        await store.waitForCacheEviction()

        bridge.base.state = .dropped
        bridge.downloadErrors.removeAll()
        bridge.downloadAttempts.removeAll()
        let restarted = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        defer { restarted.noteVisible(nil) }
        restarted.syncHosts(hosts)
        restarted.updateSessions(sessions)
        restarted.select(id)
        restarted.noteVisible(id)
        guard case let .document(document, title, token, offline) = restarted.content(for: id) else {
            return XCTFail("the cached document should be readable offline")
        }
        XCTAssertNil(offline, "nothing stages without a connection")
        XCTAssertNil(MarkdownImageStaging.images(for: document)["photo.png"])
        let offlineIdentity = ArtifactDocumentView(localURL: document, title: title, prepareImages: offline,
                                                   reloadToken: token).markdownPresenter.markdownTaskIdentity

        bridge.base.state = .connected
        restarted.updateSessions(sessions)
        await restarted.waitForLoad(id)
        guard case let .document(liveDocument, _, liveToken, live) = restarted.content(for: id) else {
            return XCTFail("missing live document")
        }
        XCTAssertEqual(liveDocument, document)
        XCTAssertEqual(liveToken, token, "the cached document is not fetched again")
        let liveIdentity = ArtifactDocumentView(localURL: document, title: title, prepareImages: live,
                                                reloadToken: liveToken).markdownPresenter.markdownTaskIdentity
        XCTAssertNotEqual(liveIdentity, offlineIdentity, "the mounted Markdown task must stage on the first connection")
        XCTAssertEqual(liveIdentity.fileURL, offlineIdentity.fileURL)
        try await XCTUnwrap(live)()
        XCTAssertEqual(bridge.downloadAttempts, [imagePath])
        XCTAssertNotNil(MarkdownImageStaging.images(for: document)["photo.png"])
        XCTAssertEqual(bridge.base.connectCalls, 0)
        await restarted.waitForCacheEviction()
    }

    func testFreshMarkdownWithoutPendingImagesDoesNotAdvanceOnReconnectOrForeground() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/docs/readme.md"] = Data("fresh text".utf8)
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
        defer { store.noteVisible(nil) }
        let sessions = [artifactStoreLiveSession(hostID: bridge.hostID)]
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions(sessions)
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID,
            target: .file(path: "/docs/readme.md"), origin: .terminalSelection)))
        await store.waitForLoad(id)
        store.noteVisible(id)
        bridge.downloads.removeAll()
        let generation = store.imageGeneration(for: id)
        for _ in 0..<3 {
            bridge.state = .dropped
            store.updateSessions(sessions)
            store.refresh(id)
            XCTAssertEqual(store.imageGeneration(for: id), generation)
            bridge.state = .connected
            store.updateSessions(sessions)
            store.setApplicationForeground(false)
            store.setApplicationForeground(true)
            XCTAssertEqual(store.imageGeneration(for: id), generation)
        }
        XCTAssertTrue(bridge.downloads.isEmpty)
        XCTAssertEqual(bridge.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    func testPermissionDeniedCompletesImageRefreshAndStopsForcingOtherImages() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactImageFailureTestBridge()
        let path = "/docs/readme.md"
        let goodPath = "/docs/good.png"
        let deniedPath = "/docs/denied.png"
        bridge.base.files[path] = Data("![good](good.png) ![denied](denied.png)".utf8)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        bridge.base.files[goodPath] = image
        bridge.base.files[deniedPath] = image
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.base.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
            target: .file(path: path), origin: .terminalSelection)))
        await store.waitForLoad(id)
        guard case let .document(document, _, _, initial) = store.content(for: id) else { return XCTFail("missing document") }
        try await XCTUnwrap(initial)()
        let deniedThumbnail = try XCTUnwrap(MarkdownImageStaging.images(for: document)["denied.png"])
        bridge.downloadAttempts.removeAll()
        bridge.downloadErrors[deniedPath] = FileBridgeError.remoteStatus(code: 3, message: "permission denied")
        store.refresh(id)
        await store.waitForLoad(id)
        guard case let .document(_, _, _, prepare) = store.content(for: id) else { return XCTFail("missing refreshed document") }
        try await XCTUnwrap(prepare)()
        XCTAssertEqual(bridge.downloadAttempts, [path, goodPath, deniedPath])
        XCTAssertNil(MarkdownImageStaging.images(for: document)["denied.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedThumbnail.path))
        let goodThumbnail = try XCTUnwrap(MarkdownImageStaging.images(for: document)["good.png"])
        bridge.downloadAttempts.removeAll()
        store.select(id)
        await store.waitForLoad(id)
        try await XCTUnwrap(prepare)()
        XCTAssertEqual(bridge.downloadAttempts, [deniedPath], "a definitive failure consumes the refresh, so the healthy image is reused")
        XCTAssertEqual(MarkdownImageStaging.images(for: document)["good.png"], goodThumbnail)
        XCTAssertEqual(bridge.base.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    func testRefreshCancelledBeforeItsDocumentFetchStillForcesTheNextLoad() async throws {
        for suffix in ["md", "txt"] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactImageFailureTestBridge()
            let path = "/docs/readme.\(suffix)"
            let imagePath = "/docs/photo.png"
            bridge.base.files[path] = Data("![photo](photo.png)".utf8)
            bridge.base.files[imagePath] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
            store.updateSessions([artifactStoreLiveSession(hostID: bridge.base.hostID)])
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.base.hostID,
                target: .file(path: path), origin: .terminalSelection)))
            await store.waitForLoad(id)
            guard case let .document(_, _, token, initial) = store.content(for: id) else { return XCTFail("missing document") }
            try await initial?()
            bridge.downloadAttempts.removeAll()
            store.refresh(id)
            store.setApplicationForeground(false)
            XCTAssertTrue(bridge.downloadAttempts.isEmpty, "the refresh is cancelled before its task starts")
            store.setApplicationForeground(true)
            store.select(id)
            await store.waitForLoad(id)
            XCTAssertEqual(bridge.downloadAttempts.filter { $0 == path }.count, 1)
            guard case let .document(_, _, currentToken, prepare) = store.content(for: id) else { return XCTFail("missing accepted refresh") }
            XCTAssertGreaterThan(currentToken, token)
            try await prepare?()
            XCTAssertEqual(bridge.downloadAttempts.filter { $0 == imagePath }.count, suffix == "md" ? 1 : 0)
            bridge.downloadAttempts.removeAll()
            store.select(id)
            await store.waitForLoad(id)
            try await prepare?()
            XCTAssertTrue(bridge.downloadAttempts.isEmpty, "both intents are consumed only by their own completed work")
            XCTAssertEqual(bridge.base.connectCalls, 0)
            await store.waitForCacheEviction()
        }
    }

    func testFreshHTMLSharesOneAcceptedRootDownloadAndKeepsItsHandler() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        bridge.files["/srv/index.html"] = Data("<h1>accepted</h1>".utf8)
        bridge.files["/srv/style.css"] = Data("body{}".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/index.html"), origin: .files)))
        guard case let .servedPage(url, registration) = store.content(for: id),
              let handler = registration.handler as? ArtifactSchemeHandler else { return XCTFail("missing handler") }
        let page = Task { await handler.response(for: URLRequest(url: url)) }
        defer { page.cancel() }
        await artifactEventually { await gate.pendingCount >= 1 }
        // Let a pre-fetch scheme request run while the shared download waits.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(bridge.downloads, ["/srv/index.html"])
        bridge.downloadGate = nil
        await gate.tick()
        let response = await page.value
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data, Data("<h1>accepted</h1>".utf8))
        guard case let .servedPage(_, accepted) = store.content(for: id) else { return XCTFail("missing accepted handler") }
        XCTAssertTrue(accepted.handler === handler)
        bridge.files["/srv/index.html"] = Data("<h1>unaccepted</h1>".utf8)
        let repeated = await handler.response(for: URLRequest(url: url))
        XCTAssertEqual(repeated.data, response.data, "root reads must serve accepted bytes until refresh")
        let stylesheet = try XCTUnwrap(URL(string: "style.css", relativeTo: url)?.absoluteURL)
        let resource = await handler.response(for: URLRequest(url: stylesheet))
        XCTAssertEqual(resource.statusCode, 200)
        XCTAssertEqual(bridge.downloads, ["/srv/index.html", "/srv/style.css"])
        XCTAssertEqual(bridge.realPaths, ["/srv/style.css", "/srv"])

        store.refresh(id)
        await artifactEventually { store.tab(id)?.cache?.size == Int64(bridge.files["/srv/index.html"]!.count) }
        guard case let .servedPage(refreshedURL, refreshed) = store.content(for: id),
              let refreshedHandler = refreshed.handler as? ArtifactSchemeHandler else { return XCTFail("missing refreshed handler") }
        XCTAssertFalse(refreshed.handler === handler, "a real refresh reloads the web model")
        let refreshedPage = await refreshedHandler.response(for: URLRequest(url: refreshedURL))
        XCTAssertEqual(refreshedPage.data, Data("<h1>unaccepted</h1>".utf8))
        XCTAssertEqual(bridge.downloads.filter { $0 == "/srv/index.html" }.count, 2)
        XCTAssertEqual(bridge.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    func testSuccessfulRefreshMakesOneBackgroundCacheWalk() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let walks = OSAllocatedUnfairLock(initialState: 0)
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"), walkCache: { directory in
            XCTAssertFalse(Thread.isMainThread)
            walks.withLock { $0 += 1 }
            return ArtifactContentLoader.cacheSizes(in: directory)
        })
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/report.txt"] = Data("first".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), loader: loader, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        await store.waitForCacheEviction()
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/report.txt"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        await store.waitForCacheEviction()
        let before = walks.withLock { $0 }
        bridge.modified = Date(timeIntervalSince1970: 2)
        bridge.files["/srv/report.txt"] = Data("refreshed".utf8)
        store.refresh(id)
        await artifactEventually { store.tab(id)?.cache?.remoteMTime == 2_000 }
        await store.waitForCacheEviction()
        XCTAssertEqual(walks.withLock { $0 } - before, 1)
        XCTAssertEqual(bridge.downloads, ["/srv/report.txt", "/srv/report.txt"])
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testHTMLRefreshAfterAFailedFirstLoadReplacesTheErrorPage() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/index.html"] = Data("<h1>recovered</h1>".utf8)
        bridge.failAfterWrite = true
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/index.html"), origin: .files)))
        guard case let .servedPage(url, registration) = store.content(for: id),
              let handler = registration.handler as? ArtifactSchemeHandler else { return XCTFail("missing initial handler") }
        let failed = await handler.response(for: URLRequest(url: url))
        XCTAssertEqual(failed.statusCode, 503)
        XCTAssertNil(store.tab(id)?.cache)
        bridge.failAfterWrite = false
        store.refresh(id)
        await artifactEventually { store.tab(id)?.cache != nil }
        guard case let .servedPage(recoveredURL, recovered) = store.content(for: id),
              let recoveredHandler = recovered.handler as? ArtifactSchemeHandler else { return XCTFail("missing recovered handler") }
        XCTAssertFalse(recovered.handler === handler, "refresh must replace an already displayed error, even without a cache")
        let response = await recoveredHandler.response(for: URLRequest(url: recoveredURL))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data, Data("<h1>recovered</h1>".utf8))
        XCTAssertEqual(bridge.downloads, ["/srv/index.html", "/srv/index.html"])
        XCTAssertEqual(bridge.connectCalls, 0)
        await store.waitForCacheEviction()
    }

    func testAgentEditCancelsAnOlderBackgroundFetchWithoutClearingItsUnseenMark() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/notes.md"] = Data("before edit".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/notes.md"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        store.refresh(id)
        await artifactEventually { await gate.pendingCount == 1 }
        bridge.files["/srv/notes.md"] = Data("after edit".utf8)
        store.agentEditObserved(hostID: bridge.hostID, absolutePath: "/srv/notes.md")
        await gate.tick()
        await artifactEventually { await gate.pendingCount == 0 }
        XCTAssertEqual(store.tab(id)?.unseenChange, true)
        if case let .document(url, _, _, _) = store.content(for: id) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "before edit")
        } else { XCTFail("the last complete copy should remain") }
        bridge.downloadGate = nil
        store.noteVisible(id)
        await artifactEventually { store.tab(id)?.cache?.isStale == false }
        if case let .document(url, _, _, _) = store.content(for: id) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after edit")
        } else { XCTFail("the visible file should refetch") }
        store.noteVisible(nil)
    }

    func testQuickOpenResolvesFilesDirectoriesAndOfflineWithoutConnecting() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/home/test/readme.md"] = Data("hello".utf8)
        bridge.directories.insert("/home/test/docs")
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let outcome = await store.quickOpen("host:~/readme.md", currentHostID: nil, placement: .newTab)
        guard case let .opened(id) = outcome else { return XCTFail("file should open") }
        XCTAssertEqual(store.tab(id)?.target.path, "/home/test/readme.md")
        let directory = await store.quickOpen("host:~/docs", currentHostID: nil, placement: .newTab)
        XCTAssertEqual(directory, .directory(hostID: bridge.hostID.uuidString, path: "/home/test/docs"))
        bridge.state = .idle
        let offline = await store.quickOpen("host:/uncached", currentHostID: nil, placement: .newTab)
        guard case .failed = offline else { return XCTFail("offline path lookup must fail") }
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testQuickOpenSuggestionsUseLivePortsAndRememberClosedTabs() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.execOutput = "TESSERA_ARTIFACTS_PORTS:ss\nLISTEN 0 128 127.0.0.1:5173 0.0.0.0:* users:((\"node\",pid=1,fd=2))"
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        _ = store.quickOpenSuggestions(":5", currentHostID: bridge.hostID.uuidString)
        await artifactEventually {
            store.quickOpenSuggestions(":5", currentHostID: bridge.hostID.uuidString).contains { $0.kind == .listeningPort }
        }
        XCTAssertEqual(bridge.execCalls, 1)
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/recent.md"), origin: .quickOpen)))
        store.close(id)
        XCTAssertTrue(store.quickOpenSuggestions("recent", currentHostID: bridge.hostID.uuidString).contains { $0.kind == .recent })
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testEmptyQuickOpenOffersRunningForwardsAndOpensTheirPageThroughThePageTabPath() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let live = artifactStoreLiveSession(hostID: hostID, ssh: true)
        guard case let .ssh(session) = live.session else { return XCTFail("expected SSH") }
        let manager = session.portForwarderManager
        let vite = PortForwardRule.localForward(localPort: 15173, remotePort: 5173, label: "vite")
        let stopped = PortForwardRule.localForward(localPort: 13000, remotePort: 3000)
        let forwarder = PortForwarder(rule: vite)
        forwarder.harnessForceState(.listening)
        manager.harnessInsert(forwarder)
        manager.harnessInsert(PortForwarder(rule: stopped))
        let pages = ArtifactPageForwarder()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), pageForwarder: pages, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox", rules: [vite, stopped])])
        store.updateSessions([live])
        let forwards = store.quickOpenSuggestions("", currentHostID: nil).filter { $0.kind == .activeForward }
        XCTAssertEqual(forwards, [ArtifactsSuggestion(kind: .activeForward, title: "localhost:5173", subtitle: "devbox · vite",
                                                      intent: .page(hostID: hostID.uuidString, scheme: "http", port: 5173, path: "/"))])
        XCTAssertEqual(store.quickOpenSuggestions("vite", currentHostID: nil).first?.kind, .activeForward)
        XCTAssertFalse(store.quickOpenSuggestions("plan", currentHostID: nil).contains { $0.kind == .activeForward })

        let submission = try XCTUnwrap(ArtifactsBrowserPresentation.suggestionInput(forwards[0], input: "", currentHostID: nil))
        let outcome = await store.quickOpen(submission.input, currentHostID: submission.hostID, placement: .newTab)
        guard case let .opened(id) = outcome else { return XCTFail("the forward's page should open as a tab") }
        let tab = try XCTUnwrap(store.tab(id))
        XCTAssertEqual(tab.target, .page(scheme: "http", port: 5173, path: "/"))
        XCTAssertFalse(store.quickOpenSuggestions("", currentHostID: nil).contains { $0.kind == .activeForward },
                       "its open tab now stands for the forward")
        // A harness manager has no SSH client to start the load, so open the
        // tab's page directly: the page path's plan borrows the running rule.
        let source = ArtifactSSHSource(sessionID: live.id, hostID: hostID.uuidString, manager: manager)
        pages.harnessInsert(artifactStorePageTab(hostID: hostID), source: source, forwarder: forwarder, ephemeral: false)
        try await pages.open(tab, rules: [vite, stopped], sources: [source])
        if case let .forwardedPage(url, label, ephemeral)? = pages.content(for: tab) {
            XCTAssertEqual(url.absoluteString, "http://127.0.0.1:15173/")
            XCTAssertEqual(label, "vite")
            XCTAssertFalse(ephemeral)
        } else { XCTFail("the page must reuse the running forward") }
        XCTAssertEqual(live.session.terminalSession.state, .idle)
    }

    func testQuickOpenOffersNoForwardWhenNoneIsListeningInALiveSession() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let ssh = artifactStoreLiveSession(hostID: hostID, ssh: true)
        let mosh = artifactStoreLiveSession(hostID: hostID, ssh: false)
        guard case let .ssh(sshSession) = ssh.session, case let .mosh(moshSession) = mosh.session else { return XCTFail("expected both transports") }
        let rule = PortForwardRule.localForward(localPort: 15173, remotePort: 5173)
        let forwarder = PortForwarder(rule: rule)
        forwarder.harnessForceState(.listening)
        sshSession.portForwarderManager.harnessInsert(forwarder)
        // The page path cannot borrow a mosh side channel's forward yet.
        let moshForwarder = PortForwarder(rule: rule)
        moshForwarder.harnessForceState(.listening)
        moshSession.portForwarderManager.harnessInsert(moshForwarder)
        var states: [UUID: SessionState] = [ssh.id: .disconnected, mosh.id: .connected]
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), sessionState: { states[$0.id] ?? .disconnected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox", rules: [rule])])
        store.updateSessions([ssh, mosh])
        func forwards() -> [ArtifactsSuggestion] {
            ["", ":5173", "devbox"].flatMap { store.quickOpenSuggestions($0, currentHostID: hostID.uuidString) }
                .filter { $0.kind == .activeForward }
        }
        XCTAssertEqual(forwards(), [], "an ended session's listener is not active")
        states[ssh.id] = .connected
        store.updateSessions([ssh, mosh])
        XCTAssertEqual(forwards().count, 3, "the fixture must offer the forward once it is live")
        for state: PortForwarder.State in [.idle, .error(reason: "bind failed")] {
            forwarder.harnessForceState(state)
            XCTAssertEqual(forwards(), [], "\(state)")
        }
        store.updateSessions([])
        XCTAssertEqual(forwards(), [])
        XCTAssertEqual(ssh.session.terminalSession.state, .idle)
        XCTAssertEqual(mosh.session.terminalSession.state, .idle)
    }

    /// Leaving the Artifacts tab tears the browser down (iPad) or makes it
    /// reappear (iPhone). Either way it must come back to what the user left.
    func testBrowserComesBackToTheOverviewOrTabTheUserLeftAfterItsViewIsRebuilt() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        var time: Int64 = 1_000
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), now: { time += 1; return time })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox")])
        let notes = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: hostID, target: .file(path: "/notes.md"), origin: .quickOpen)))
        let page = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: hostID, target: .page(scheme: "http", port: 5173, path: "/"),
                                                                origin: .quickOpen)))
        let lock = AppLockController(requiresOwnerAuthentication: { false }, locksWhenBackgrounded: { false }, autoLockMinutes: { 0 })

        var window = try mountBrowser(store, lock: lock)
        waitForBrowser { store.visibleTabID == page }
        XCTAssertEqual(store.visibleTabID, page, "a browser built at launch shows the selected tab")
        store.showsBrowserOverview = true // back to the overview
        settleBrowser()
        XCTAssertNil(store.visibleTabID)
        unmountBrowser(window)
        window = try mountBrowser(store, lock: lock)
        settleBrowser()
        XCTAssertNil(store.visibleTabID, "the rebuilt browser shows the overview the user left")
        XCTAssertEqual(store.state.selectedID, page)

        // The Duo context showing the selected tab only marks it viewed.
        let context = ArtifactVisibilitySession()
        context.update(page, store: store)
        context.release()
        settleBrowser()
        XCTAssertNil(store.visibleTabID, "a tab shown elsewhere must not reopen in the browser")
        XCTAssertTrue(store.showsBrowserOverview)

        store.select(notes)
        waitForBrowser { store.visibleTabID == notes }
        XCTAssertEqual(store.visibleTabID, notes, "an explicit select reveals its tab")
        // Leave once the push has landed. Torn down within its first frames
        // (14 of 100 runs), SwiftUI reports the navigation request updating
        // twice in one frame.
        settleBrowser()
        unmountBrowser(window)
        XCTAssertNil(store.visibleTabID)
        window = try mountBrowser(store, lock: lock)
        waitForBrowser { store.visibleTabID == notes }
        XCTAssertEqual(store.visibleTabID, notes, "the rebuilt browser shows the tab the user left")
        unmountBrowser(window)
    }

    /// The route outlives the view in the store, which also serves iPad's
    /// regular browser. Only an open or select leaves the overview.
    func testBrowserOverviewRouteIsHeldByTheStoreAndOnlyAnOpenOrSelectRevealsATab() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        var time: Int64 = 1_000
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), now: { time += 1; return time })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox")])
        let pageRequest = ArtifactOpenRequest(hostID: hostID, target: .page(scheme: "http", port: 5173, path: "/"), origin: .terminalLink)
        let notes = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: hostID, target: .file(path: "/notes.md"), origin: .quickOpen)))
        let page = try XCTUnwrap(store.open(pageRequest))
        XCTAssertFalse(store.showsBrowserOverview)
        XCTAssertEqual(ArtifactsBrowserView.phonePath(store), [page])
        XCTAssertFalse(ArtifactsBrowserView.showsOverview(store))

        store.showsBrowserOverview = true
        let viewedAt = store.selectedTab?.viewedAt
        store.noteVisible(page)
        store.noteVisible(nil)
        XCTAssertNotEqual(store.selectedTab?.viewedAt, viewedAt, "the fixture must mark the tab viewed")
        XCTAssertTrue(store.showsBrowserOverview)
        store.close(notes)
        XCTAssertTrue(store.showsBrowserOverview, "closing a background tab keeps the overview")
        XCTAssertEqual(ArtifactsBrowserView.phonePath(store), [])
        XCTAssertTrue(ArtifactsBrowserView.showsOverview(store))
        XCTAssertEqual(store.state.selectedID, page, "the overview keeps the selection for the next reveal")

        store.select(page)
        XCTAssertFalse(store.showsBrowserOverview, "selecting the selected tab again reveals it")
        store.showsBrowserOverview = true
        XCTAssertEqual(store.open(pageRequest), page)
        XCTAssertFalse(store.showsBrowserOverview, "reopening its page from a terminal reveals the tab")
        XCTAssertEqual(ArtifactsBrowserView.phonePath(store), [page])
        XCTAssertFalse(ArtifactsBrowserView.showsOverview(store))
    }

    private func mountBrowser(_ store: ArtifactsStore, lock: AppLockController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: ArtifactsBrowserView(store: store).environment(lock))
        window.makeKeyAndVisible()
        settleBrowser()
        return window
    }

    private func unmountBrowser(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        settleBrowser()
    }

    private func settleBrowser() {
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    private func waitForBrowser(_ condition: () -> Bool) {
        for _ in 0..<100 where !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    func testQuickOpenCwdChangesInvalidateOnceAndCachedSubmissionUsesCurrentCwdForBothTransports() async throws {
        for ssh in [true, false] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactTestBridge()
            bridge.files["/a/report.md"] = Data("old cwd".utf8)
            bridge.files["/b/report.md"] = Data("current cwd".utf8)
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] }, sessionState: { _ in .connected })
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "dev")])
            let live = artifactStoreLiveSession(hostID: bridge.hostID, ssh: ssh)
            live.session.terminalSession.remoteWorkingDirectory = "/a"
            store.updateSessions([live])
            let snapshot = ArtifactsQuickOpenSuggestionSnapshot()
            let input = "dev:report.md"
            let hostID = bridge.hostID.uuidString
            var evaluations = 0
            func update() {
                snapshot.update(.init(input: input, currentHostID: hostID, storeID: ObjectIdentifier(store), revision: snapshot.revision)) {
                    evaluations += 1
                    return store.quickOpenSuggestions(input, currentHostID: hostID)
                }
            }
            for _ in 0..<46 { update(); _ = snapshot.suggestions }
            XCTAssertEqual(evaluations, 1)
            let cached = try XCTUnwrap(snapshot.suggestions.first { $0.kind == .hostPrefix })
            XCTAssertEqual(cached.intent, .file(hostID: hostID, path: "/a/report.md"))
            let revision = snapshot.revision
            let unchanged = store.state
            live.session.terminalSession.remoteWorkingDirectory = "/b"
            await artifactEventually { snapshot.revision > revision }
            XCTAssertEqual(store.state, unchanged, "cwd alone must invalidate the suggestions")
            for _ in 0..<46 { update(); _ = snapshot.suggestions }
            XCTAssertEqual(evaluations, 2)
            XCTAssertEqual(snapshot.suggestions.first?.intent, .file(hostID: hostID, path: "/b/report.md"))
            snapshot.stopObserving()
            // A row retained from the old snapshot still resolves at submit.
            let submission = try XCTUnwrap(ArtifactsBrowserPresentation.suggestionInput(cached, input: input, currentHostID: hostID))
            let outcome = await store.quickOpen(submission.input, currentHostID: submission.hostID, placement: .newTab)
            guard case let .opened(id) = outcome else { return XCTFail("current cwd file should open") }
            XCTAssertEqual(store.tab(id)?.target.path, "/b/report.md")
            XCTAssertEqual(bridge.realPaths, ["/b/report.md"])
            await artifactEventually { store.tab(id)?.cache != nil }
            XCTAssertEqual(bridge.connectCalls, 0)
            XCTAssertEqual(bridge.execCalls, 0)
            XCTAssertTrue(bridge.listings.isEmpty)
            XCTAssertEqual(live.session.terminalSession.state, .idle)
            await store.waitForCacheEviction()
            store.setApplicationForeground(false)
        }
    }

    func testMoshHostBorrowsOnlyItsConnectedFilesBridgesWithoutConnecting() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.artifactForwarding = PortForwarderManager()
        let otherRoute = ArtifactTestBridge(hostID: bridge.hostID, jumpPath: ["test@bastion.invalid:22"])
        otherRoute.artifactForwarding = PortForwarderManager()
        let otherHost = ArtifactTestBridge()
        otherHost.artifactForwarding = PortForwarderManager()
        let host = Host(id: bridge.hostID, name: "mosh host", address: "unused.invalid", user: "test", transport: .mosh)
        let session = MoshSession(host: host)
        let live = LiveSession(session: .mosh(session), hostName: host.name, persistedHostID: host.id,
                               hostKey: "mosh:test@unused.invalid:22", launchMode: .customCommand)
        // Describe a live mosh session without opening its transport.
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root),
                                   bridgeProvider: { [otherHost, otherRoute, bridge] }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: host.id, label: host.name)])
        store.updateSessions([live])
        let sources = store.sshSources.filter { $0.hostID == host.id.uuidString }
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.allSatisfy(\.isFileBridge))
        let source = try XCTUnwrap(sources.first { $0.manager === bridge.artifactForwarding })
        XCTAssertEqual(source.sessionID, ArtifactSSHSource.bridgeSessionID(for: bridge.key))
        XCTAssertEqual(store.sshSources.first { $0.manager === bridge.artifactForwarding }?.sessionID, source.sessionID)
        XCTAssertNotEqual(source.sessionID, live.id)
        XCTAssertEqual(Set(sources.map(\.sessionID)).count, 2, "separate routes must not share a source identity")
        XCTAssertEqual(session.state, .idle, "the test must never start mosh")
        XCTAssertEqual(bridge.connectCalls + otherRoute.connectCalls + otherHost.connectCalls, 0)
    }

    func testMoshWithoutConnectedFilesForwardingStaysUnavailableAndNeverConnects() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.artifactForwarding = PortForwarderManager()
        let host = Host(id: bridge.hostID, name: "mosh host", address: "unused.invalid", user: "test", transport: .mosh)
        let session = MoshSession(host: host)
        let live = LiveSession(session: .mosh(session), hostName: host.name, persistedHostID: host.id,
                               hostKey: "mosh:test@unused.invalid:22", launchMode: .customCommand)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root),
                                   bridgeProvider: { [bridge] }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: host.id, label: host.name)])
        for state: FileBridgeState in [.idle, .connecting, .dropped, .failed("closed")] {
            bridge.state = state
            store.updateSessions([live])
            XCTAssertTrue(store.sshSources.isEmpty, "a retained manager does not make a disconnected bridge live")
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(
                hostID: host.id, target: .page(scheme: "http", port: 5173, path: "/"),
                origin: .terminalLink, sessionID: live.id
            )))
            store.refresh(id)
            store.noteVisible(id)
            store.select(id)
            if case .unavailable(.noForwarding) = store.content(for: id) { }
            else { XCTFail("live mosh without connected Files must report no forwarding") }
            XCTAssertEqual(bridge.connectCalls, 0)
            XCTAssertTrue(bridge.listings.isEmpty)
            XCTAssertEqual(bridge.execCalls, 0)
        }
        let outcome = await store.quickOpen(":8080", currentHostID: host.id.uuidString, placement: .newTab)
        guard case let .opened(id) = outcome else { return XCTFail("offline pages still open as unavailable tabs") }
        if case .unavailable(.noForwarding) = store.content(for: id) { }
        else { XCTFail("Quick Open must not connect Files for mosh") }
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(bridge.connectCalls, 0)
        store.noteVisible(nil)
    }

    func testMoshWithNoBridgeOrWithANonForwardingBridgeNeverConnects() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let host = Host(id: bridge.hostID, name: "mosh host", address: "unused.invalid", user: "test", transport: .mosh)
        let live = LiveSession(session: .mosh(MoshSession(host: host)), hostName: host.name, persistedHostID: host.id,
                               hostKey: "mosh:test@unused.invalid:22", launchMode: .customCommand)
        var bridges: [any FileBridging] = []
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root),
                                   bridgeProvider: { bridges }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: host.id, label: host.name)])
        for includeBridge in [false, true] {
            bridges = includeBridge ? [bridge] : []
            store.updateSessions([live])
            XCTAssertTrue(store.sshSources.isEmpty)
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(
                hostID: host.id, target: .page(scheme: "http", port: 5173, path: "/"), origin: .terminalLink
            )))
            if case .unavailable(.noForwarding) = store.content(for: id) { }
            else { XCTFail("mosh needs an already-connected forwarding source") }
        }
        XCTAssertNil(bridge.artifactForwarding)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testFilesSourceDisappearsOnDisconnectWithoutReconnectAndAllSessionsGoneIsOffline() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.artifactForwarding = PortForwarderManager()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let sourceID = try XCTUnwrap(store.sshSources.first?.sessionID)
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .page(scheme: "http", port: 5173, path: "/"), origin: .terminalLink
        )))
        store.noteVisible(id)
        bridge.state = .dropped
        await artifactEventually {
            if case .unavailable(.offline) = store.content(for: id) { return true }
            return false
        }
        XCTAssertTrue(store.sshSources.isEmpty)
        store.refresh(id)
        XCTAssertEqual(bridge.connectCalls, 0)

        // Only an explicit external reconnect can make the source reappear.
        bridge.state = .connected
        XCTAssertEqual(store.sshSources.first?.sessionID, sourceID)
        bridge.state = .idle
        store.noteVisible(nil)
    }

    func testRealSSHSourcesWinOverFilesAndSessionHintChoosesItsOwnSSH() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.artifactForwarding = PortForwarderManager()
        let host = Host(id: bridge.hostID, name: "host", address: "unused.invalid", user: "test")
        let first = LiveSession(session: .ssh(SSHSession(host: host)), hostName: host.name, persistedHostID: host.id,
                                hostKey: "ssh:test@unused.invalid:22", launchMode: .customCommand)
        let second = LiveSession(session: .ssh(SSHSession(host: host)), hostName: host.name, persistedHostID: host.id,
                                 hostKey: "ssh:test@unused.invalid:22", launchMode: .customCommand)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root),
                                   bridgeProvider: { [bridge] }, sessionState: { _ in .connected })
        store.updateSessions([second, first])
        let sources = store.sshSources
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources.map(\.isFileBridge), [false, false, true])
        XCTAssertEqual(ArtifactPageForwarder.orderedSources(sources, sessionHint: second.id.uuidString).first?.sessionID, second.id)
        let fileSource = try XCTUnwrap(sources.last)
        XCTAssertFalse(try XCTUnwrap(ArtifactPageForwarder.orderedSources(sources, sessionHint: fileSource.sessionID.uuidString).first).isFileBridge)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testFilesSourceIdentityIncludesManagedHostAndFullRoute() {
        let hostID = UUID()
        let key = FileBridgeKey(hostID: hostID, user: "test", address: "unused.invalid", port: 22)
        let same = FileBridgeKey(hostID: hostID, user: "test", address: "unused.invalid", port: 22)
        let otherHost = FileBridgeKey(hostID: UUID(), user: "test", address: "unused.invalid", port: 22)
        let otherRoute = FileBridgeKey(hostID: hostID, user: "test", address: "unused.invalid", port: 22, jumpPath: ["test@bastion.invalid:22"])
        let id = ArtifactSSHSource.bridgeSessionID(for: key)
        XCTAssertEqual(id, ArtifactSSHSource.bridgeSessionID(for: same))
        XCTAssertNotEqual(id, ArtifactSSHSource.bridgeSessionID(for: otherHost))
        XCTAssertNotEqual(id, ArtifactSSHSource.bridgeSessionID(for: otherRoute))
    }

    func testFilesBorrowedLeaseCannotBeKeptAsARule() throws {
        let pages = ArtifactPageForwarder()
        let manager = PortForwarderManager()
        let tab = artifactStorePageTab(hostID: UUID())
        let rule = PortForwardRule.localForward(localPort: 8080, remoteHost: "127.0.0.1", remotePort: 3000)
        let forwarder = PortForwarder(rule: rule)
        forwarder.harnessForceState(.listening)
        let source = ArtifactSSHSource(sessionID: UUID(), hostID: tab.hostID, manager: manager, isFileBridge: true)
        pages.harnessInsert(tab, source: source, forwarder: forwarder, ephemeral: true)
        XCTAssertFalse(pages.canKeepAsRule(tab.id))
        XCTAssertNil(pages.ruleToKeep(tab.id, title: "page"))
        pages.kept(tab.id, rule: rule)
        if case let .forwardedPage(_, _, ephemeral)? = pages.content(for: tab) { XCTAssertTrue(ephemeral) }
        else { XCTFail("a rejected keep must leave the tab's ephemeral lease intact") }

        let sshTab = artifactStorePageTab(hostID: UUID())
        let sshSource = ArtifactSSHSource(sessionID: UUID(), hostID: sshTab.hostID, manager: manager)
        pages.harnessInsert(sshTab, source: sshSource, forwarder: forwarder, ephemeral: true)
        XCTAssertTrue(pages.canKeepAsRule(sshTab.id))
        XCTAssertEqual(pages.ruleToKeep(sshTab.id, title: "page")?.label, "page")
    }

    func testFilesSourcesRequireAHostSessionThatHasNotEnded() {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.artifactForwarding = PortForwarderManager()
        var connectionState: SessionState = .idle
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   sessionState: { _ in connectionState })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        XCTAssertFalse(store.isLive(hostID: bridge.hostID.uuidString), "a retained bridge alone is not a source")
        for ssh in [false, true] {
            let live = artifactStoreLiveSession(hostID: bridge.hostID, ssh: ssh)
            let states: [(SessionState, Bool)] = [
                (.idle, true), (.connecting, true), (.connected, true),
                (.failed("ended"), false), (.disconnected, false)
            ]
            for (state, usable) in states {
                connectionState = state
                store.updateSessions([live])
                XCTAssertEqual(store.sshSources.contains(where: \.isFileBridge), usable)
                XCTAssertEqual(store.quickOpenHosts.first?.home, usable ? bridge.homeDirectory : nil)
                XCTAssertEqual(store.isLive(hostID: bridge.hostID.uuidString), usable)
            }
        }
        store.updateSessions([])
        XCTAssertTrue(store.sshSources.isEmpty)
        XCTAssertNil(store.quickOpenHosts.first?.home)
        XCTAssertEqual(bridge.state, .connected)
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertTrue(bridge.listings.isEmpty)
    }

    func testFilesLeaseAndFollowerRetireWhenLastSessionEnds() async throws {
        try await assertFilesLeaseAndFollowerRetireWhenLastSessionEnds(.disconnected)
    }

    func testFilesLeaseAndFollowerRetireWhenLastSessionFails() async throws {
        for lastOwnerSSH in [false, true] {
            try await assertFilesLeaseAndFollowerRetireWhenLastSessionEnds(.failed("transport ended"), lastOwnerSSH: lastOwnerSSH)
        }
    }

    private func assertFilesLeaseAndFollowerRetireWhenLastSessionEnds(_ endedState: SessionState, lastOwnerSSH: Bool = true) async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let manager = PortForwarderManager()
        bridge.artifactForwarding = manager
        bridge.files["/srv/index.html"] = Data("<h1>cached</h1>".utf8)
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let pages = ArtifactPageForwarder()
        let first = artifactStoreLiveSession(hostID: bridge.hostID, ssh: !lastOwnerSSH)
        let last = artifactStoreLiveSession(hostID: bridge.hostID, ssh: lastOwnerSSH)
        var connectionStates: [UUID: SessionState] = [first.id: .connected, last.id: .connected]
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, pageForwarder: pages,
                                   bridgeProvider: { [bridge] }, sessionState: { connectionStates[$0.id] ?? .disconnected })
        defer { store.noteVisible(nil) }
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([first, last])
        let fileID = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .file(path: "/srv/index.html"), origin: .files
        )))
        await artifactEventually { store.tab(fileID)?.cache != nil }
        let pageID = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .page(scheme: "http", port: 3000, path: "/"), origin: .terminalLink
        )))
        let page = try XCTUnwrap(store.tab(pageID))
        let source = try XCTUnwrap(store.sshSources.first(where: \.isFileBridge))
        let forwarder = PortForwarder(rule: .localForward(localPort: 8080, remoteHost: "127.0.0.1", remotePort: 3000))
        forwarder.harnessForceState(.listening)
        manager.harnessInsert(forwarder, ephemeral: true)
        pages.harnessInsert(page, source: source, forwarder: forwarder, ephemeral: true)
        store.select(fileID)
        store.noteVisible(fileID)
        await artifactEventually { await clock.pendingCount == 1 }
        connectionStates[first.id] = endedState
        connectionStates[last.id] = .connecting
        store.updateSessions([first, last])
        XCTAssertEqual(follower.tabID, fileID, "another session on the host still admits the bridge")
        XCTAssertEqual(forwarder.state, .listening)
        if case .forwardedPage = store.content(for: pageID) { } else { XCTFail("the borrowed lease should still be live") }

        connectionStates[last.id] = endedState
        store.updateSessions([first, last])
        XCTAssertTrue(store.sshSources.isEmpty)
        XCTAssertNil(pages.content(for: page), "the Files lease must be dropped even though its bridge is still connected")
        XCTAssertNil(follower.tabID)
        await artifactEventually { forwarder.state == .idle }
        await artifactEventually { await clock.pendingCount == 0 }
        XCTAssertEqual(store.presentation(for: fileID).state, .cached)
        XCTAssertFalse(store.presentation(for: fileID).canRefresh)
        if case let .document(url, _, _, prepareImages) = store.content(for: fileID) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "<h1>cached</h1>")
            XCTAssertNil(prepareImages)
        } else { XCTFail("HTML must fall back to its cached source") }
        if case .unavailable(.offline) = store.content(for: pageID) { } else { XCTFail("the page must become offline") }
        XCTAssertEqual(store.presentation(for: pageID).state, .offline)
        let reads = bridge.listings.count
        let stats = bridge.attributePaths.count
        let downloads = bridge.downloads.count
        let realPaths = bridge.realPaths.count
        store.refresh(fileID)
        store.refresh(pageID)
        store.noteVisible(fileID)
        _ = store.quickOpenSuggestions(":3", currentHostID: bridge.hostID.uuidString)
        await clock.tick()
        let outcome = await store.quickOpen("host:/uncached.md", currentHostID: nil, placement: .newTab)
        guard case .failed = outcome else { return XCTFail("Quick Open cannot use the retained bridge") }
        let uncached = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .file(path: "/uncached.md"), origin: .files
        )))
        if case .unavailable(.offline) = store.content(for: uncached) { } else { XCTFail("new reads must remain offline") }
        XCTAssertEqual(store.presentation(for: uncached).state, .offline)
        XCTAssertNil(follower.tabID)
        XCTAssertEqual(bridge.listings.count, reads)
        XCTAssertEqual(bridge.attributePaths.count, stats)
        XCTAssertEqual(bridge.downloads.count, downloads)
        XCTAssertEqual(bridge.realPaths.count, realPaths)
        XCTAssertEqual(bridge.execCalls, 0)
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertEqual(bridge.state, .connected)
        XCTAssertEqual(first.session.terminalSession.state, .idle)
        XCTAssertEqual(last.session.terminalSession.state, .idle)
        store.updateSessions([])
        XCTAssertTrue(store.sshSources.isEmpty)
    }

    func testFailedLastSessionCancelsInflightFetchAndPreservesCachedBytes() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/notes.md"] = Data("cached".utf8)
        var connectionState: SessionState = .connected
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   sessionState: { _ in connectionState })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        let live = artifactStoreLiveSession(hostID: bridge.hostID)
        store.updateSessions([live])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .file(path: "/srv/notes.md"), origin: .files
        )))
        await artifactEventually { store.tab(id)?.cache != nil }
        let cache = store.tab(id)?.cache
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        bridge.files["/srv/notes.md"] = Data("unpublished".utf8)
        store.refresh(id)
        await artifactEventually { await gate.pendingCount == 1 }

        connectionState = .failed("transport ended")
        store.updateSessions([live])
        await gate.tick()
        await artifactEventually { await gate.pendingCount == 0 }
        await artifactEventually {
            bridge.downloadURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }
        XCTAssertEqual(store.tab(id)?.cache, cache)
        if case let .document(url, _, _, prepareImages) = store.content(for: id) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "cached")
            XCTAssertNil(prepareImages)
        } else { XCTFail("failure must preserve the last complete copy") }
        XCTAssertEqual(store.presentation(for: id).state, .cached)
        XCTAssertFalse(store.presentation(for: id).canRefresh)
        XCTAssertEqual(bridge.downloads.count, 2)
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertEqual(live.session.terminalSession.state, .idle)
    }

    func testReusedLeaseRejectsRuleRetargetDisableRemovalAndReplacement() async throws {
        for edit in ["port", "host", "disabled", "direction", "removed", "replacement"] {
            let pages = ArtifactPageForwarder()
            let manager = PortForwarderManager()
            let tab = artifactStorePageTab(hostID: UUID())
            let source = ArtifactSSHSource(sessionID: UUID(), hostID: tab.hostID, manager: manager)
            var rule = PortForwardRule.localForward(localPort: 8080, remoteHost: "localhost", remotePort: 3000)
            let forwarder = PortForwarder(rule: rule)
            forwarder.harnessForceState(.listening)
            manager.harnessInsert(forwarder)
            pages.harnessInsert(tab, source: source, forwarder: forwarder, ephemeral: false)
            if case .forwardedPage? = pages.content(for: tab) { } else { XCTFail("the initial lease must be reusable") }
            switch edit {
            case "port": rule.target?.port = 4000
            case "host": rule.target?.host = "service.internal"
            case "disabled": rule.enabled = false
            case "direction": rule.direction = .remote
            case "removed": await manager.reconcile(newRules: [])
            case "replacement": manager.harnessInsert(PortForwarder(rule: rule))
            default: XCTFail("unknown edit")
            }
            forwarder.update(rule: rule)
            XCTAssertNil(pages.content(for: tab), edit)
            XCTAssertFalse(pages.canKeepAsRule(tab.id))
        }
    }

    func testOpeningAfterRuleRetargetReplansForTheTabsOriginalPort() async throws {
        let pages = ArtifactPageForwarder()
        let manager = PortForwarderManager()
        let tab = artifactStorePageTab(hostID: UUID())
        let source = ArtifactSSHSource(sessionID: UUID(), hostID: tab.hostID, manager: manager)
        var old = PortForwardRule.localForward(localPort: 8080, remoteHost: "127.0.0.1", remotePort: 3000)
        let forwarder = PortForwarder(rule: old)
        forwarder.harnessForceState(.listening)
        manager.harnessInsert(forwarder)
        pages.harnessInsert(tab, source: source, forwarder: forwarder, ephemeral: false)
        old.target?.port = 4000
        forwarder.update(rule: old)
        let replacement = PortForwardRule.localForward(localPort: 9090, remoteHost: "::1", remotePort: 3000)
        let other = PortForwarder(rule: replacement)
        other.harnessForceState(.listening)
        manager.harnessInsert(other)
        try await pages.open(tab, rules: [old, replacement], sources: [source])
        if case let .forwardedPage(url, _, ephemeral)? = pages.content(for: tab) {
            XCTAssertEqual(url.port, 9090)
            XCTAssertFalse(ephemeral)
        } else { XCTFail("the tab should reuse the rule that still targets 3000") }
    }

    func testSyncHostsRevalidatesReusedRuleBeforeManagerAppliesEdits() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let live = artifactStoreLiveSession(hostID: hostID, ssh: true)
        guard case let .ssh(session) = live.session else { return XCTFail("expected SSH") }
        let manager = session.portForwarderManager
        let pages = ArtifactPageForwarder()
        var rule = PortForwardRule.localForward(localPort: 8080, remoteHost: "127.0.0.1", remotePort: 3000)
        let forwarder = PortForwarder(rule: rule)
        forwarder.harnessForceState(.listening)
        manager.harnessInsert(forwarder)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), pageForwarder: pages, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "host", rules: [rule])])
        store.updateSessions([live])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: hostID, target: .page(scheme: "http", port: 3000, path: "/"), origin: .terminalLink
        )))
        let tab = try XCTUnwrap(store.tab(id))
        let source = ArtifactSSHSource(sessionID: live.id, hostID: hostID.uuidString, manager: manager)
        pages.harnessInsert(tab, source: source, forwarder: forwarder, ephemeral: false)
        if case .forwardedPage = store.content(for: id) { } else { XCTFail("expected reused rule") }
        rule.target?.port = 4000
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "host", rules: [rule])])
        XCTAssertNil(pages.content(for: tab), "saved rules must invalidate the lease before async manager reconciliation")
        if case .forwardedPage = store.content(for: id) { XCTFail("the tab must never silently show port 4000") }
        XCTAssertEqual(forwarder.rule.target?.port, 3000, "the manager has deliberately not applied the edit yet")
    }

    func testEvictionProtectsAnUnselectedInflightDownloadBeforeItsPartialExists() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("staged.md")
        try Data("cached".utf8).write(to: staged)
        let base = ArtifactTestBridge()
        let gate = ArtifactStatTestGate()
        let slow = ArtifactStatTestBridge(base: base, gate: gate)
        let fast = ArtifactTestBridge()
        base.files["/slow.md"] = Data("123456".utf8)
        fast.files["/fast.md"] = Data("abcdef".utf8)
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), loader: loader, cacheBudgetBytes: 8,
                                   bridgeProvider: { [slow, fast] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: base.hostID, label: "slow"), ArtifactsHostDirectoryEntry(id: fast.hostID, label: "fast")])
        store.updateSessions([artifactStoreLiveSession(hostID: base.hostID), artifactStoreLiveSession(hostID: fast.hostID)])
        let a = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: base.hostID, target: .file(path: "/slow.md"), origin: .files, stagedLocalURL: staged)))
        store.refresh(a)
        await artifactEventually { await gate.isWaiting }
        let directory = loader.localURL(for: try XCTUnwrap(store.tab(a))).deletingLastPathComponent()
        let b = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: fast.hostID, target: .file(path: "/fast.md"), origin: .files)))
        await artifactEventually { store.tab(b)?.cache != nil }
        await store.waitForCacheEviction()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "an in-flight key is protected even while stat is suspended")
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: directory.path), ["slow.md"], "there is no partial file to independently protect this directory")
        store.setPinned(a, true)
        await gate.resume()
        await artifactEventually { store.tab(a)?.cache?.remoteMTime == 1_000 }
        if case let .document(url, _, _, _) = store.content(for: a) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "123456")
        } else { XCTFail("the protected download must be able to finish its rename") }
        XCTAssertEqual(base.connectCalls + fast.connectCalls, 0)
    }

    func testUnpinCloseCloseAllAndHostRemovalReenforceTheCacheBudget() async throws {
        for action in ["unpin", "close", "closeAll", "hostRemoved"] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let staged = root.appendingPathComponent("staged.txt")
            try Data("123456".utf8).write(to: staged)
            let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), loader: loader, cacheBudgetBytes: 8)
            let first = ArtifactsHostDirectoryEntry(id: UUID(), label: "first")
            let second = ArtifactsHostDirectoryEntry(id: UUID(), label: "second")
            store.syncHosts([first, second])
            let a = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: first.id, target: .file(path: "/a.txt"), origin: .files, stagedLocalURL: staged)))
            store.setPinned(a, true)
            let b = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: second.id, target: .file(path: "/b.txt"), origin: .files, stagedLocalURL: staged)))
            let aTab = try XCTUnwrap(store.tab(a))
            let bTab = try XCTUnwrap(store.tab(b))
            XCTAssertNotNil(loader.cachedURL(for: aTab))
            let orphan = artifactTestTab(path: "/orphan.txt")
            _ = try loader.adopt(staged, for: orphan)
            switch action {
            case "unpin": store.setPinned(a, false)
            case "close": store.close(a)
            case "closeAll": store.closeAll(hostID: first.id.uuidString)
            case "hostRemoved": store.syncHosts([second])
            default: XCTFail("unknown action")
            }
            await store.waitForCacheEviction()
            XCTAssertNil(loader.cachedURL(for: orphan), action)
            XCTAssertNil(loader.cachedURL(for: aTab), action)
            XCTAssertNotNil(loader.cachedURL(for: bTab), "the selected tab remains protected: \(action)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        }
    }

    func testQuickOpenCancelledDuringStatDoesNotOpenSelectOrPersist() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ArtifactTestBridge()
        base.files["/srv/readme.md"] = Data("hello".utf8)
        let gate = ArtifactStatTestGate()
        let bridge = ArtifactStatTestBridge(base: base, gate: gate)
        let file = ArtifactsStateFile(directory: root)
        let store = ArtifactsStore(stateFile: file, bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: base.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: base.hostID)])
        _ = store.open(ArtifactOpenRequest(hostID: base.hostID, target: .change(path: "/before.md", diff: "+before", summary: "before"), origin: .agentEdit))
        store.flush()
        let before = store.state
        let task = Task { await store.quickOpen("host:/srv/readme.md", currentHostID: nil, placement: .newTab) }
        await artifactEventually { await gate.isWaiting }
        task.cancel()
        await gate.resume()
        let outcome = await task.value
        guard case .failed = outcome else { return XCTFail("a stat reply after cancellation must not open a tab") }
        XCTAssertEqual(store.state, before)
        store.flush()
        XCTAssertEqual(file.load(), before)
        XCTAssertTrue(base.downloads.isEmpty)
        XCTAssertEqual(base.connectCalls, 0)
    }

    func testSuccessfulFollowStatClearsMissingWithUnchangedCachedBytes() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/notes.md"] = Data("cached".utf8)
        let clock = ArtifactTestClock()
        let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
        defer { store.noteVisible(nil) }
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/notes.md"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        store.noteVisible(id)
        await artifactEventually { await clock.pendingCount == 1 }
        bridge.attributeError = .remoteStatus(code: 2, message: "transient missing")
        await clock.tick()
        await artifactEventually {
            if case .unavailable(.missing) = store.content(for: id) { return true }
            return false
        }
        await artifactEventually { await clock.pendingCount == 1 }
        let downloads = bridge.downloads.count
        let stats = bridge.attributePaths.count
        bridge.attributeError = nil
        await clock.tick()
        await artifactEventually {
            let pending = await clock.pendingCount
            return bridge.attributePaths.count > stats && pending == 1
        }
        if case let .document(url, _, _, _) = store.content(for: id) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "cached")
        } else { XCTFail("a successful unchanged stat must clear the stale missing failure") }
        XCTAssertEqual(bridge.downloads.count, downloads, "unchanged cached bytes need no refetch")
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testSuccessfulFollowStatLoadsAfterAnUncachedMissingOrOfflineFailure() async throws {
        for failure: FileBridgeError in [.remoteStatus(code: 2, message: "missing"), .notConnected] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactTestBridge()
            bridge.files["/srv/notes.md"] = Data("returned".utf8)
            bridge.attributeError = failure
            let clock = ArtifactTestClock()
            let follower = ArtifactFollower(sleep: { try await clock.sleep($0) })
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), follower: follower, bridgeProvider: { [bridge] })
            defer { store.noteVisible(nil) }
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
            store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/notes.md"), origin: .files)))
            await artifactEventually {
                if case .unavailable = store.content(for: id) { return !bridge.attributePaths.isEmpty }
                return false
            }
            store.noteVisible(id)
            await artifactEventually { await clock.pendingCount == 1 }
            bridge.attributeError = nil
            await clock.tick()
            await artifactEventually { store.tab(id)?.cache != nil }
            if case let .document(url, _, _, _) = store.content(for: id) {
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "returned")
            } else { XCTFail("an uncached tab must load when the successful stat restores it") }
            XCTAssertEqual(bridge.connectCalls, 0)
        }
    }

    // MARK: - New tabs, in-place navigation, reopen and share

    /// ⌘T then localhost:8001/laptop.html opens beside the localhost:8001 tab,
    /// on that tab's forward; each tab's close leaves the other's page up.
    /// Duo's Quick Open on another host hands its new tab to the full
    /// browser. Matching its target would find the older twin instead.
    func testARequestNamingItsTabRevealsThatTabRatherThanAnOlderTwin() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID(), otherHostID = UUID()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox"),
                         ArtifactsHostDirectoryEntry(id: otherHostID, label: "lab")])
        let request = ArtifactOpenRequest(hostID: hostID, target: .file(path: "/srv/plan.md"), origin: .quickOpen)
        let older = try XCTUnwrap(store.open(request))
        let twin = try XCTUnwrap(store.open(request, placement: .newTab))
        XCTAssertNotEqual(older, twin)
        store.select(older)
        XCTAssertEqual(store.open(request), older, "an automatic open still dedupes")

        var naming = request
        naming.tabID = twin
        XCTAssertEqual(store.open(naming), twin)
        XCTAssertEqual(store.state.selectedID, twin)
        XCTAssertEqual(store.state.tabs.count, 2, "revealing opens nothing")

        naming.tabID = "gone"
        XCTAssertEqual(store.open(naming), older, "a tab that is gone falls back to the target")
        var elsewhere = naming
        elsewhere.tabID = twin
        elsewhere.hostID = otherHostID
        XCTAssertNotEqual(store.open(elsewhere), twin, "a tab is revealed only for its own host")
    }

    func testANewTabOnAnOpenPortSharesItsForwardUntilTheLastTabCloses() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let live = artifactStoreLiveSession(hostID: hostID, ssh: true)
        guard case let .ssh(session) = live.session else { return XCTFail("expected SSH") }
        let manager = session.portForwarderManager
        let pages = ArtifactPageForwarder()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), pageForwarder: pages, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox")])
        store.updateSessions([live])
        let rootID = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: hostID, target: .page(scheme: "http", port: 8001, path: "/"), origin: .terminalLink)))
        let source = ArtifactSSHSource(sessionID: live.id, hostID: hostID.uuidString, manager: manager)
        let forwarder = PortForwarder(rule: .localForward(localPort: 18001, remoteHost: "127.0.0.1", remotePort: 8001))
        forwarder.harnessForceState(.listening)
        manager.harnessInsert(forwarder, ephemeral: true)
        pages.harnessInsert(try XCTUnwrap(store.tab(rootID)), source: source, forwarder: forwarder, ephemeral: true)

        let laptopID = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: hostID, target: .page(scheme: "http", port: 8001, path: "/laptop.html"), origin: .quickOpen), placement: .newTab))
        XCTAssertNotEqual(laptopID, rootID)
        XCTAssertEqual(store.state.tabs.map(\.id), [rootID, laptopID])
        XCTAssertEqual(store.selectedTab?.id, laptopID)
        XCTAssertEqual(store.tab(rootID)?.target, .page(scheme: "http", port: 8001, path: "/"))
        let laptop = try XCTUnwrap(store.tab(laptopID))
        try await pages.open(laptop, rules: [], sources: [source])
        XCTAssertEqual(pages.tabsSharingForward(with: laptopID), [rootID, laptopID], "no second forward for the same port")
        if case let .forwardedPage(url, _, ephemeral) = store.content(for: laptopID) {
            XCTAssertEqual(url.absoluteString, "http://127.0.0.1:18001/laptop.html")
            XCTAssertTrue(ephemeral)
        } else { XCTFail("the new tab shows its own page on the shared forward") }
        let twinID = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: hostID, target: .page(scheme: "http", port: 8001, path: "/"), origin: .quickOpen), placement: .newTab))
        XCTAssertEqual(store.state.tabs.count, 3, "even the identical address opens a new tab")
        try await pages.open(try XCTUnwrap(store.tab(twinID)), rules: [], sources: [source])

        store.close(rootID)
        // A stop would run on a later turn: give it time to before checking.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(forwarder.state, .listening, "closing one tab must not stop the forward the others use")
        if case .forwardedPage = store.content(for: laptopID) { } else { XCTFail("the other tab's page stays up") }
        store.close(twinID)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(forwarder.state, .listening)
        store.close(laptopID)
        await artifactEventually { forwarder.state == .idle }
    }

    /// Two sessions on one host: a new tab without a session hint still
    /// leases the forward another tab holds on that port, from that session.
    func testANewTabSharesAPortsForwardFromWhicheverSessionHoldsIt() async throws {
        let hostID = UUID()
        let first = artifactStoreLiveSession(hostID: hostID, ssh: true)
        let second = artifactStoreLiveSession(hostID: hostID, ssh: true)
        guard case let .ssh(a) = first.session, case let .ssh(b) = second.session else { return XCTFail("expected SSH") }
        let sources = [ArtifactSSHSource(sessionID: first.id, hostID: hostID.uuidString, manager: a.portForwarderManager),
                       ArtifactSSHSource(sessionID: second.id, hostID: hostID.uuidString, manager: b.portForwarderManager)]
        // The forward lives on the session a hint-free open would not pick.
        let preferred = ArtifactPageForwarder.orderedSources(sources, sessionHint: nil)[0]
        let holder = try XCTUnwrap(sources.first { $0.sessionID != preferred.sessionID })
        let pages = ArtifactPageForwarder()
        let forwarder = PortForwarder(rule: .localForward(localPort: 18002, remoteHost: "127.0.0.1", remotePort: 8001))
        forwarder.harnessForceState(.listening)
        holder.manager.harnessInsert(forwarder, ephemeral: true)
        let rootTab = ArtifactTab(id: "root", hostID: hostID.uuidString, hostLabel: "host",
                                  target: .page(scheme: "http", port: 8001, path: "/"), title: ":8001", openedAt: 1, viewedAt: 1)
        pages.harnessInsert(rootTab, source: holder, forwarder: forwarder, ephemeral: true)
        // Both sessions can lend forwards.
        let other = PortForwarder(rule: .localForward(localPort: 19000, remoteHost: "127.0.0.1", remotePort: 9000))
        other.harnessForceState(.listening)
        preferred.manager.harnessInsert(other, ephemeral: true)
        let otherTab = ArtifactTab(id: "other", hostID: hostID.uuidString, hostLabel: "host",
                                   target: .page(scheme: "http", port: 9000, path: "/"), title: ":9000", openedAt: 1, viewedAt: 1)
        pages.harnessInsert(otherTab, source: preferred, forwarder: other, ephemeral: true)

        let laptop = ArtifactTab(id: "laptop", hostID: hostID.uuidString, hostLabel: "host",
                                 target: .page(scheme: "http", port: 8001, path: "/laptop.html"), title: ":8001", openedAt: 2, viewedAt: 2)
        try await pages.open(laptop, rules: [], sources: sources)
        XCTAssertEqual(pages.tabsSharingForward(with: "laptop"), ["root", "laptop"], "no second forward for the port")
    }

    /// An automatic open still focuses what is open: the exact page, or the
    /// port's most recent tab, which navigates there.
    func testAutomaticOpensStillFocusTheOpenTab() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox")])
        let page = ArtifactOpenRequest(hostID: hostID, target: .page(scheme: "http", port: 8001, path: "/"), origin: .terminalLink)
        let first = try XCTUnwrap(store.open(page))
        XCTAssertEqual(store.open(page), first)
        let file = ArtifactOpenRequest(hostID: hostID, target: .file(path: "/srv/a.md"), origin: .files)
        let doc = try XCTUnwrap(store.open(file))
        XCTAssertEqual(store.open(file), doc)
        XCTAssertEqual(store.open(ArtifactOpenRequest(hostID: hostID, target: .file(path: "/srv/a.md"), origin: .terminalSelection)), doc)
        XCTAssertNotEqual(store.open(file, placement: .newTab), doc, "a tab the user asks for is always new")
        XCTAssertEqual(store.state.tabs.count, 3)
    }

    func testAnEditedAddressNavigatesItsTabInPlaceAndKeepsItsForward() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let live = artifactStoreLiveSession(hostID: hostID, ssh: true)
        guard case let .ssh(session) = live.session else { return XCTFail("expected SSH") }
        let manager = session.portForwarderManager
        let pages = ArtifactPageForwarder()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), pageForwarder: pages, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox")])
        store.updateSessions([live])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: hostID, target: .page(scheme: "http", port: 8001, path: "/"), origin: .terminalLink)))
        store.setPinned(id, true)
        let source = ArtifactSSHSource(sessionID: live.id, hostID: hostID.uuidString, manager: manager)
        let forwarder = PortForwarder(rule: .localForward(localPort: 18001, remoteHost: "127.0.0.1", remotePort: 8001))
        forwarder.harnessForceState(.listening)
        manager.harnessInsert(forwarder, ephemeral: true)
        pages.harnessInsert(try XCTUnwrap(store.tab(id)), source: source, forwarder: forwarder, ephemeral: true)

        let outcome = await store.quickOpen("localhost:8001/laptop.html", currentHostID: hostID.uuidString,
                                            placement: .navigate(tabID: id))
        XCTAssertEqual(outcome, .opened(tabID: id))
        XCTAssertEqual(store.state.tabs.count, 1)
        XCTAssertEqual(store.tab(id)?.target, .page(scheme: "http", port: 8001, path: "/laptop.html"))
        XCTAssertEqual(store.tab(id)?.pinned, true)
        XCTAssertEqual(forwarder.state, .listening)
        if case let .forwardedPage(url, _, _) = store.content(for: id) {
            XCTAssertEqual(url.absoluteString, "http://127.0.0.1:18001/laptop.html", "the same forward, the new page")
        } else { XCTFail("the navigated tab keeps its lease") }

        _ = await store.quickOpen(":9000", currentHostID: hostID.uuidString, placement: .navigate(tabID: id))
        XCTAssertEqual(store.tab(id)?.target, .page(scheme: "http", port: 9000, path: "/"))
        await artifactEventually { forwarder.state == .idle }
        XCTAssertNil(pages.content(for: try XCTUnwrap(store.tab(id))), "another port's page leaves the old forward")

        // Return on the address it already has still sends the page there,
        // as it may have followed a link away.
        let sent = store.pageNavigation(for: id)
        _ = await store.quickOpen(":9000", currentHostID: hostID.uuidString, placement: .navigate(tabID: id))
        XCTAssertEqual(store.pageNavigation(for: id), sent + 1)
        XCTAssertEqual(store.state.tabs.count, 1)

        // A tab keeps its host: another host's address opens beside it.
        let otherHost = UUID()
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox"), ArtifactsHostDirectoryEntry(id: otherHost, label: "lab")])
        let beside = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: otherHost, target: .page(scheme: "http", port: 9000, path: "/"), origin: .quickOpen), placement: .navigate(tabID: id)))
        XCTAssertNotEqual(beside, id)
        XCTAssertEqual(store.tab(id)?.hostID, hostID.uuidString)
        XCTAssertEqual(store.tab(beside)?.hostID, otherHost.uuidString)
        XCTAssertEqual(store.selectedTab?.id, beside)
    }

    func testAnEditedFileAddressShowsTheOtherFileInTheSameTab() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/a.md"] = Data("first file".utf8)
        bridge.files["/srv/b.md"] = Data("second file".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/a.md"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        let outcome = await store.quickOpen("host:/srv/b.md", currentHostID: bridge.hostID.uuidString, placement: .navigate(tabID: id))
        XCTAssertEqual(outcome, .opened(tabID: id))
        XCTAssertEqual(store.state.tabs.map(\.id), [id])
        XCTAssertEqual(store.tab(id)?.target, .file(path: "/srv/b.md"))
        await artifactEventually {
            if case let .document(url, _, _, _) = store.content(for: id) {
                return (try? String(contentsOf: url, encoding: .utf8)) == "second file"
            }
            return false
        }

        let change = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .change(path: "/srv/a.md", diff: "+a", summary: "+1"), origin: .agentEdit)))
        let fromChange = await store.quickOpen("host:/srv/a.md", currentHostID: bridge.hostID.uuidString,
                                               placement: .navigate(tabID: change))
        guard case let .opened(opened) = fromChange else { return XCTFail("the address should open") }
        XCTAssertNotEqual(opened, change, "an agent edit's snapshot cannot change, so its address opens beside it")
        XCTAssertEqual(store.tab(change)?.target, .change(path: "/srv/a.md", diff: "+a", summary: "+1"))
        XCTAssertEqual(store.selectedTab?.id, opened)
    }

    func testReopenBringsBackTheLastClosedTabsNewestFirst() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID(), otherID = UUID()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox"), ArtifactsHostDirectoryEntry(id: otherID, label: "api")])
        XCTAssertFalse(store.canReopenClosedTab)
        XCTAssertNil(store.reopenClosedTab())
        let a = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: hostID, target: .file(path: "/a.md"), origin: .files)))
        let b = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: hostID, target: .page(scheme: "http", port: 3000, path: "/x"),
                                                             origin: .terminalLink)))
        let gone = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: otherID, target: .file(path: "/c.md"), origin: .files)))
        store.setPinned(a, true)
        store.close(a)
        store.close(gone)
        store.close(b)
        XCTAssertTrue(store.canReopenClosedTab)
        let reopened = try XCTUnwrap(store.reopenClosedTab())
        XCTAssertNotEqual(reopened, b, "it comes back as a new tab")
        XCTAssertEqual(store.tab(reopened)?.target, .page(scheme: "http", port: 3000, path: "/x"))
        XCTAssertEqual(store.selectedTab?.id, reopened)
        store.syncHosts([ArtifactsHostDirectoryEntry(id: hostID, label: "devbox")])
        let pinned = try XCTUnwrap(store.reopenClosedTab(), "a removed host's tab is skipped")
        XCTAssertEqual(store.tab(pinned)?.target, .file(path: "/a.md"))
        XCTAssertEqual(store.tab(pinned)?.pinned, true)
        XCTAssertFalse(store.canReopenClosedTab)
    }

    func testOnlyAFileWithAWholeCopyOffersItsShare() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/Quarterly Report.pdf"] = Data("%PDF-1.7 whole".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .file(path: "/srv/Quarterly Report.pdf"), origin: .files)))
        await artifactEventually { await gate.pendingCount == 1 }
        XCTAssertEqual(store.shareableFile(for: id), .unavailable(String(localized: "this file is still downloading")),
                       "a download in flight is never shared")
        bridge.downloadGate = nil
        await gate.tick()
        await artifactEventually { store.shareableFile(for: id).isReady }
        guard case let .ready(url) = store.shareableFile(for: id) else { return XCTFail("the cached copy is shareable") }
        XCTAssertEqual(url.lastPathComponent, "Quarterly Report.pdf")
        XCTAssertEqual(try Data(contentsOf: url), Data("%PDF-1.7 whole".utf8))
        let staged = try XCTUnwrap(ArtifactShareStaging.request(for: store.shareableFile(for: id),
                                                                in: root.appendingPathComponent("share", isDirectory: true)))
        XCTAssertEqual(staged.fileURL.lastPathComponent, "Quarterly Report.pdf")

        let page = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .page(scheme: "http", port: 3000, path: "/"),
                                                                origin: .terminalLink)))
        XCTAssertEqual(store.shareableFile(for: page), .none, "a forwarded page shares its link from the tab menu instead")
        let change = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .change(path: "/srv/x.swift", diff: "+x", summary: "+1"), origin: .agentEdit)))
        XCTAssertEqual(store.shareableFile(for: change), .none)
        bridge.state = .idle
        let offline = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/srv/never.md"),
                                                                   origin: .files)))
        XCTAssertEqual(store.shareableFile(for: offline), .unavailable(String(localized: "this file has not been downloaded yet")))
        store.noteVisible(nil)
    }

    func testQuickOpenConnectsFilesThroughAConnectedSessionBeforeOpening() async throws {
        for ssh in [true, false] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactTestBridge()
            bridge.state = .idle
            bridge.allowsConnect = true
            bridge.files["/tmp/x/plan.md"] = Data("plan".utf8)
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                       filesBridge: { _ in bridge }, sessionState: { _ in .connected })
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
            store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID, ssh: ssh)])

            let outcome = await store.quickOpen("/tmp/x/plan.md", currentHostID: bridge.hostID.uuidString, placement: .newTab)
            guard case let .opened(id) = outcome else { return XCTFail("file should open, got \(outcome)") }
            XCTAssertEqual(bridge.connectCalls, 1)
            XCTAssertEqual(bridge.state, .connected)
            XCTAssertEqual(store.tab(id)?.target, .file(path: "/tmp/x/plan.md"))
            XCTAssertEqual(bridge.realPaths, ["/tmp/x/plan.md"])
            await store.waitForLoad(id)
        }
    }

    func testQuickOpenReportsTheFilesConnectionFailure() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        bridge.allowsConnect = true
        let error = FileBridgeError.authenticationFailed("denied")
        bridge.connectError = error
        bridge.files["/tmp/x/plan.md"] = Data("plan".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   filesBridge: { _ in bridge }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID, ssh: true)])

        let outcome = await store.quickOpen("/tmp/x/plan.md", currentHostID: bridge.hostID.uuidString, placement: .newTab)
        XCTAssertEqual(outcome, .failed(error.localizedDescription))
        XCTAssertEqual(bridge.connectCalls, 1)
        XCTAssertTrue(bridge.realPaths.isEmpty)
        XCTAssertTrue(store.state.tabs.isEmpty)
    }

    func testQuickOpenWithoutASessionStaysOfflineAndNeverConnectsFiles() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.state = .idle
        bridge.allowsConnect = true
        bridge.files["/tmp/x/plan.md"] = Data("plan".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   filesBridge: { _ in bridge }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])

        let outcome = await store.quickOpen("/tmp/x/plan.md", currentHostID: bridge.hostID.uuidString, placement: .newTab)
        XCTAssertEqual(outcome, .failed(String(localized: "this host is offline")))
        XCTAssertEqual(bridge.connectCalls, 0)
        XCTAssertTrue(bridge.realPaths.isEmpty)
        XCTAssertTrue(store.state.tabs.isEmpty)
    }

    func testCancellingQuickOpenCancelsItsUnclaimedFilesConnection() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactConnectionTestBridge()
        bridge.base.state = .idle
        let gate = ArtifactStatTestGate()
        let connection = artifactQuickOpenFilesConnection(bridge, gate: gate)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   filesBridge: { _ in bridge }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.base.hostID)])
        let task = Task { await store.quickOpen("/tmp/plan.md", currentHostID: bridge.base.hostID.uuidString, placement: .newTab) }
        await artifactEventually { await gate.isWaiting }

        task.cancel()
        await artifactEventually { connection.state == .idle && connection.harnessConnectWaiterCount == 0 }
        await gate.resume()
        let outcome = await task.value
        if case .opened = outcome { XCTFail("a dismissed entry must not open a tab") }
        XCTAssertEqual(connection.state, .idle, "a late connect reply must not revive the abandoned attempt")
        XCTAssertTrue(store.state.tabs.isEmpty)
        XCTAssertTrue(bridge.base.realPaths.isEmpty)
        await connection.disconnect()
    }

    func testCancellingQuickOpenKeepsAConnectionAnotherConsumerIsWaitingFor() async throws {
        for quickOpenStartsConnection in [true, false] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactConnectionTestBridge()
            bridge.base.state = .idle
            let gate = ArtifactStatTestGate()
            let connection = artifactQuickOpenFilesConnection(bridge, gate: gate)
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                       filesBridge: { _ in bridge }, sessionState: { _ in .connected })
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
            store.updateSessions([artifactStoreLiveSession(hostID: bridge.base.hostID)])
            var consumer: Task<Void, Error>?
            if !quickOpenStartsConnection {
                consumer = Task { try await connection.harnessConnect { await gate.wait() } }
                await artifactEventually { await gate.isWaiting }
            }
            let task = Task { await store.quickOpen("/tmp/plan.md", currentHostID: bridge.base.hostID.uuidString, placement: .newTab) }
            await artifactEventually { connection.harnessConnectWaiterCount == (quickOpenStartsConnection ? 1 : 2) }
            if quickOpenStartsConnection {
                await artifactEventually { await gate.isWaiting }
                consumer = Task { try await connection.harnessConnect { XCTFail("connect must coalesce") } }
                await artifactEventually { connection.harnessConnectWaiterCount == 2 }
            }

            task.cancel()
            await artifactEventually { connection.harnessConnectWaiterCount == 1 }
            XCTAssertEqual(connection.state, .connecting)
            await gate.resume()
            try await consumer?.value
            _ = await task.value
            XCTAssertEqual(connection.state, .connected)
            XCTAssertTrue(store.state.tabs.isEmpty)
            XCTAssertTrue(bridge.base.realPaths.isEmpty)
            await connection.disconnect()
        }
    }

    func testCancelledQuickOpenCompletionKeepsAVisibleFilesPanelConnection() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactConnectionTestBridge()
        bridge.base.state = .idle
        let gate = ArtifactStatTestGate()
        let connection = artifactQuickOpenFilesConnection(bridge, gate: gate)
        connection.suppressIdleTeardown = true
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   filesBridge: { _ in bridge }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.base.hostID)])
        let task = Task { await store.quickOpen("/tmp/plan.md", currentHostID: bridge.base.hostID.uuidString, placement: .newTab) }
        await artifactEventually { await gate.isWaiting }

        task.cancel()
        await artifactEventually { connection.harnessConnectWaiterCount == 0 }
        XCTAssertEqual(connection.state, .connecting)
        await gate.resume()
        _ = await task.value
        XCTAssertEqual(connection.state, .connected)
        XCTAssertTrue(store.state.tabs.isEmpty)
        await connection.disconnect()
    }

    func testCancelledQuickOpenIgnoresWaitersFromAnOlderConnectionAttempt() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactConnectionTestBridge()
        bridge.base.state = .idle
        let oldGate = ArtifactStatTestGate()
        let gate = ArtifactStatTestGate()
        let connection = artifactQuickOpenFilesConnection(bridge, gate: gate)
        let oldConsumer = Task { try await connection.harnessConnect { await oldGate.wait() } }
        await artifactEventually { await oldGate.isWaiting }
        await connection.disconnect()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   filesBridge: { _ in bridge }, sessionState: { _ in .connected })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.base.hostID)])
        let task = Task { await store.quickOpen("/tmp/plan.md", currentHostID: bridge.base.hostID.uuidString, placement: .newTab) }
        await artifactEventually { await gate.isWaiting }
        XCTAssertEqual(connection.harnessConnectWaiterCount, 2)

        task.cancel()
        await artifactEventually { connection.state == .idle && connection.harnessConnectWaiterCount == 1 }
        await gate.resume()
        _ = await task.value
        XCTAssertEqual(connection.state, .idle, "an obsolete waiter cannot keep the newer abandoned socket alive")
        await oldGate.resume()
        if case .success = await oldConsumer.result { XCTFail("the disconnected attempt must fail") }
        XCTAssertEqual(connection.state, .idle)
        XCTAssertTrue(store.state.tabs.isEmpty)
        await connection.disconnect()
    }

    func testCancelledQuickOpenKeepsAPageReservationThenReleasesAnUnusedCandidate() async throws {
        for usesFiles in [true, false] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactConnectionTestBridge()
            bridge.base.state = .idle
            let gate = ArtifactStatTestGate()
            let connection = artifactQuickOpenFilesConnection(bridge, gate: gate)
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                       filesBridge: { _ in bridge }, sessionState: { _ in .connected })
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.base.hostID, label: "host")])
            store.updateSessions([artifactStoreLiveSession(hostID: bridge.base.hostID)])
            let task = Task { await store.quickOpen("/tmp/plan.md", currentHostID: bridge.base.hostID.uuidString, placement: .newTab) }
            await artifactEventually { await gate.isWaiting }
            let reservation = try XCTUnwrap(connection.reserveArtifactConnection())

            task.cancel()
            await artifactEventually { connection.harnessConnectWaiterCount == 1 }
            XCTAssertEqual(connection.state, .connecting, "a queued page still needs its candidate")
            await gate.resume()
            _ = await task.value
            XCTAssertEqual(connection.state, .connected, "binding a listener must keep its Files candidate")
            if usesFiles {
                let manager = PortForwarderManager()
                let forwarder = PortForwarder(rule: .localForward(localPort: 5173, remotePort: 5173))
                forwarder.harnessForceState(.listening)
                manager.harnessInsert(forwarder, ephemeral: true)
                await connection.harnessExpireIdleTimer(forwarding: manager)
            }
            await connection.releaseArtifactConnection(reservation)
            XCTAssertEqual(connection.state, usesFiles ? .connected : .idle,
                           "forward selection must release a candidate it did not use")
            XCTAssertTrue(store.state.tabs.isEmpty)
            await connection.disconnect()
        }
    }
}

@MainActor
private func artifactQuickOpenFilesConnection(_ bridge: ArtifactConnectionTestBridge, gate: ArtifactStatTestGate) -> FileBridge {
    let connection = FileBridge(host: Host(id: bridge.base.hostID, address: "unused.invalid", user: "test"),
                                requireBiometric: false, isSecureEnclave: false)
    bridge.connectOperation = { try await connection.harnessConnect { await gate.wait() } }
    return connection
}

@MainActor
private func artifactStoreLiveSession(hostID: UUID, ssh: Bool = false) -> LiveSession {
    let host = Host(id: hostID, name: "host", address: "unused.invalid", user: "test", transport: ssh ? .ssh : .mosh)
    let session: Session = ssh ? .ssh(SSHSession(host: host)) : .mosh(MoshSession(host: host))
    return LiveSession(session: session, hostName: host.name, persistedHostID: hostID,
                       hostKey: "\(ssh ? "ssh" : "mosh"):test@unused.invalid:22", launchMode: .customCommand)
}

private func artifactStorePageTab(hostID: UUID) -> ArtifactTab {
    ArtifactTab(id: UUID().uuidString, hostID: hostID.uuidString, hostLabel: "host", target: .page(scheme: "http", port: 3000, path: "/"),
                title: ":3000", openedAt: 1, viewedAt: 1)
}

/// Deliberately returns a stat reply even after cancellation, like a remote
/// request whose reply has already been queued on the transport.
private actor ArtifactStatTestGate {
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func resume() { waiter?.resume(); waiter = nil }
}

@MainActor
@Observable
private final class ArtifactConnectionTestBridge: FileBridging {
    let base = ArtifactTestBridge()
    @ObservationIgnored var connectOperation: (@MainActor () async throws -> Void)?
    var connectionGeneration = 1
    var key: FileBridgeKey { base.key }
    var state: FileBridgeState { base.state }
    var homeDirectory: String? { base.homeDirectory }
    var artifactForwarding: PortForwarderManager? { base.artifactForwarding }
    var suppressIdleTeardown: Bool {
        get { base.suppressIdleTeardown }
        set { base.suppressIdleTeardown = newValue }
    }

    func connect() async throws {
        if let connectOperation { try await connectOperation() }
        else { try await base.connect() }
    }
    func disconnect() async { await base.disconnect() }
    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] { try await base.listDirectory(path) }
    func attributes(_ path: String) async throws -> RemoteFileEntry { try await base.attributes(path) }
    func realPath(_ path: String) async throws -> String { try await base.realPath(path) }
    func createDirectory(_ path: String) async throws { try await base.createDirectory(path) }
    func setPermissions(_ permissions: UInt16, at path: String) async throws { try await base.setPermissions(permissions, at: path) }
    func rename(from oldPath: String, to newPath: String) async throws { try await base.rename(from: oldPath, to: newPath) }
    func removeFile(_ path: String) async throws { try await base.removeFile(path) }
    func removeDirectory(_ path: String) async throws { try await base.removeDirectory(path) }
    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        try await base.download(remotePath: remotePath, to: localURL, progress: progress)
    }
    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(localURL: localURL, to: remotePath, progress: progress)
    }
    func exec(_ command: String, inShell: Bool) async throws -> String { try await base.exec(command, inShell: inShell) }
}

@MainActor
@Observable
private final class ArtifactStatTestBridge: FileBridging {
    let base: ArtifactTestBridge
    let gate: ArtifactStatTestGate
    var key: FileBridgeKey { base.key }
    var state: FileBridgeState { base.state }
    var homeDirectory: String? { base.homeDirectory }
    var suppressIdleTeardown: Bool {
        get { base.suppressIdleTeardown }
        set { base.suppressIdleTeardown = newValue }
    }

    init(base: ArtifactTestBridge, gate: ArtifactStatTestGate) { self.base = base; self.gate = gate }
    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        try await base.listDirectory(path)
    }
    func attributes(_ path: String) async throws -> RemoteFileEntry {
        let entry = try await base.attributes(path)
        await gate.wait()
        return entry
    }
    func realPath(_ path: String) async throws -> String { try await base.realPath(path) }
    func createDirectory(_ path: String) async throws { try await base.createDirectory(path) }
    func setPermissions(_ permissions: UInt16, at path: String) async throws { try await base.setPermissions(permissions, at: path) }
    func rename(from oldPath: String, to newPath: String) async throws { try await base.rename(from: oldPath, to: newPath) }
    func removeFile(_ path: String) async throws { try await base.removeFile(path) }
    func removeDirectory(_ path: String) async throws { try await base.removeDirectory(path) }
    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        try await base.download(remotePath: remotePath, to: localURL, progress: progress)
    }
    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(localURL: localURL, to: remotePath, progress: progress)
    }
    func exec(_ command: String, inShell: Bool) async throws -> String { try await base.exec(command, inShell: inShell) }
}

extension ArtifactsStoreTests {
    func testOverviewSweepMarksHiddenCachedFileWithoutStattingVisibleTab() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files = ["/hidden.txt": Data("hidden".utf8), "/visible.txt": Data("visible".utf8)]
        let clock = ArtifactTestClock()
        let followClock = ArtifactTestClock()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root),
                                   follower: ArtifactFollower(sleep: { try await followClock.sleep($0) }),
                                   bridgeProvider: { [bridge] }, overviewSleep: { try await clock.sleep($0) })
        let owner = UUID()
        defer { store.noteOverviewVisible(owner, false); store.noteVisible(nil) }
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let hidden = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/hidden.txt"), origin: .files)))
        let visible = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/visible.txt"), origin: .files)))
        await artifactEventually { store.tab(hidden)?.cache != nil && store.tab(visible)?.cache != nil }
        store.noteVisible(visible)
        bridge.attributePaths.removeAll()
        let downloads = bridge.downloads.count
        bridge.modified = Date(timeIntervalSince1970: 2)

        store.noteOverviewVisible(owner, true)
        await artifactEventually { store.tab(hidden)?.unseenChange == true }
        XCTAssertEqual(bridge.attributePaths, ["/hidden.txt"])
        XCTAssertEqual(store.tab(hidden)?.cache?.isStale, true)
        XCTAssertEqual(store.tab(visible)?.unseenChange, false)
        XCTAssertEqual(bridge.downloads.count, downloads)
        XCTAssertEqual(bridge.connectCalls, 0)
        store.select(hidden)
        store.noteVisible(hidden)
        XCTAssertEqual(store.tab(hidden)?.unseenChange, false)
    }

    func testOverviewSweepDoesNotStatWithoutAVisibleOverview() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/hidden.txt"] = Data("saved".utf8)
        let clock = ArtifactTestClock()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   overviewSleep: { try await clock.sleep($0) })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/hidden.txt"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        bridge.attributePaths.removeAll()
        bridge.modified = Date(timeIntervalSince1970: 2)
        await clock.tick()
        await Task.yield()
        let sleeps = await clock.sleepCalls
        XCTAssertEqual(sleeps, 0)
        XCTAssertTrue(bridge.attributePaths.isEmpty)
        XCTAssertEqual(store.tab(id)?.unseenChange, false)
    }

    func testOverviewSweepRequiresALiveSessionAndConnectedBridge() async throws {
        for noSession in [true, false] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let bridge = ArtifactTestBridge()
            bridge.files["/hidden.txt"] = Data("saved".utf8)
            let clock = ArtifactTestClock()
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                       overviewSleep: { try await clock.sleep($0) })
            let live = artifactStoreLiveSession(hostID: bridge.hostID)
            store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
            store.updateSessions([live])
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/hidden.txt"), origin: .files)))
            await artifactEventually { store.tab(id)?.cache != nil }
            if noSession { store.updateSessions([]) }
            else { bridge.state = .dropped; store.updateSessions([live]) }
            bridge.attributePaths.removeAll()
            let owner = UUID()
            store.noteOverviewVisible(owner, true)
            await clock.tick()
            await Task.yield()
            XCTAssertTrue(bridge.attributePaths.isEmpty)
            XCTAssertEqual(bridge.connectCalls, 0)
            XCTAssertEqual(store.tab(id)?.unseenChange, false)
            let sleeps = await clock.sleepCalls
            XCTAssertEqual(sleeps, 0)
            store.noteOverviewVisible(owner, false)
        }
    }

    func testHidingOverviewStopsItsPeriodicSweep() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/hidden.txt"] = Data("saved".utf8)
        let clock = ArtifactTestClock()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   overviewSleep: { try await clock.sleep($0) })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/hidden.txt"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        bridge.attributePaths.removeAll()
        let owner = UUID()
        defer { store.noteOverviewVisible(owner, false) }
        store.noteOverviewVisible(owner, true)
        store.noteOverviewVisible(owner, true)
        await artifactEventually { await clock.pendingCount == 1 }
        XCTAssertEqual(bridge.attributePaths, ["/hidden.txt"])
        let durations = await clock.durations
        XCTAssertEqual(durations, [15_000_000_000])
        await clock.tick()
        await artifactEventually {
            let pending = await clock.pendingCount
            return bridge.attributePaths.count == 2 && pending == 1
        }

        store.noteOverviewVisible(owner, false)
        await artifactEventually { await clock.pendingCount == 0 }
        await clock.tick()
        await Task.yield()
        XCTAssertEqual(bridge.attributePaths.count, 2)
    }

    func testOverviewSweepKeepsRunningUntilBothOverviewsDisappear() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/hidden.txt"] = Data("saved".utf8)
        let clock = ArtifactTestClock()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   overviewSleep: { try await clock.sleep($0) })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/hidden.txt"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        bridge.attributePaths.removeAll()
        let desk = UUID(), sheet = UUID()
        defer { store.noteOverviewVisible(desk, false); store.noteOverviewVisible(sheet, false) }
        store.noteOverviewVisible(desk, true)
        store.noteOverviewVisible(sheet, true)
        await artifactEventually { await clock.pendingCount == 1 }
        store.noteOverviewVisible(sheet, false)
        let previous = bridge.attributePaths.count
        await clock.tick()
        await artifactEventually {
            let pending = await clock.pendingCount
            return bridge.attributePaths.count == previous + 1 && pending == 1
        }
        store.noteOverviewVisible(desk, false)
        await artifactEventually { await clock.pendingCount == 0 }
    }

    func testLockUnregistersBothOverviewsAndForegroundWaitsForUnlock() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/hidden.txt"] = Data("saved".utf8)
        let clock = ArtifactTestClock()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   overviewSleep: { try await clock.sleep($0) })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/hidden.txt"), origin: .files)))
        await artifactEventually { store.tab(id)?.cache != nil }
        bridge.attributePaths.removeAll()
        let desk = UUID(), sheet = UUID()
        defer { store.noteOverviewVisible(desk, false); store.noteOverviewVisible(sheet, false) }
        store.noteOverviewVisible(desk, true)
        store.noteOverviewVisible(sheet, true)
        await artifactEventually { await clock.pendingCount == 1 }

        // Both mounted owners stop registering while the lock covers them.
        store.noteOverviewVisible(desk, false)
        store.noteOverviewVisible(sheet, false)
        await artifactEventually { await clock.pendingCount == 0 }
        let beforeLock = bridge.attributePaths
        let sleepsBeforeLock = await clock.sleepCalls
        store.setApplicationForeground(false)
        store.setApplicationForeground(true)
        await clock.tick()
        await Task.yield()
        XCTAssertEqual(bridge.attributePaths, beforeLock)
        let sleepsWhileLocked = await clock.sleepCalls
        XCTAssertEqual(sleepsWhileLocked, sleepsBeforeLock)

        store.noteOverviewVisible(desk, true)
        await artifactEventually { await clock.pendingCount == 1 }
        XCTAssertEqual(bridge.attributePaths.count, beforeLock.count + 1)
    }

    func testOverviewSweepVisitsAllFortyFilesBeforeRepeating() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let paths = (0..<40).map { "/file-\($0).txt" }
        bridge.files = Dictionary(uniqueKeysWithValues: paths.map { ($0, Data("saved".utf8)) })
        let clock = ArtifactTestClock()
        var now: Int64 = 0
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), now: { now += 1; return now },
                                   bridgeProvider: { [bridge] }, overviewSleep: { try await clock.sleep($0) })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        for path in paths {
            _ = store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: path), origin: .files))
        }
        await artifactEventually { store.state.tabs.count == 40 && store.state.tabs.allSatisfy { $0.cache != nil } }
        bridge.attributePaths.removeAll()
        let owner = UUID()
        defer { store.noteOverviewVisible(owner, false) }
        store.noteOverviewVisible(owner, true)
        for sweep in 1...3 {
            if sweep > 1 { await clock.tick() }
            await artifactEventually {
                let pending = await clock.pendingCount
                return bridge.attributePaths.count == sweep * 16 && pending == 1
            }
        }
        XCTAssertEqual(Array(bridge.attributePaths.prefix(40)), Array(paths.reversed()))
        XCTAssertEqual(Set(bridge.attributePaths.prefix(40)), Set(paths))
        XCTAssertEqual(Array(bridge.attributePaths.suffix(8)), Array(paths.reversed().prefix(8)))
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testOverviewSweepLimitsStatsToSixteenRecentCachedFiles() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let paths = (0..<18).map { "/file-\($0).txt" }
        bridge.files = Dictionary(uniqueKeysWithValues: paths.map { ($0, Data("saved".utf8)) })
        let clock = ArtifactTestClock()
        var now: Int64 = 0
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), now: { now += 1; return now },
                                   bridgeProvider: { [bridge] }, overviewSleep: { try await clock.sleep($0) })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: bridge.hostID)])
        for path in paths {
            _ = store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: path), origin: .files))
        }
        await artifactEventually { store.state.tabs.allSatisfy { $0.cache != nil } }
        let uncached = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .file(path: "/uncached.txt"), origin: .terminalSelection)))
        _ = store.open(ArtifactOpenRequest(hostID: bridge.hostID, target: .change(path: "/change.txt", diff: "+saved", summary: "edit"), origin: .agentEdit))
        await artifactEventually {
            if case .unavailable(.missing) = store.content(for: uncached) { return true }
            return false
        }
        bridge.attributePaths.removeAll()
        let owner = UUID()
        defer { store.noteOverviewVisible(owner, false) }
        store.noteOverviewVisible(owner, true)
        await artifactEventually { await clock.pendingCount == 1 }
        XCTAssertEqual(bridge.attributePaths, Array(paths.reversed().prefix(16)))
    }

    func testOverviewSweepDiscardsInFlightStatsAfterHidingBackgroundOrDisconnect() async throws {
        for stop in ["hidden", "background", "disconnect"] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let staged = root.appendingPathComponent("saved.txt")
            try Data("saved".utf8).write(to: staged)
            let base = ArtifactTestBridge()
            base.files["/hidden.txt"] = Data("saved".utf8)
            let gate = ArtifactStatTestGate()
            let bridge = ArtifactStatTestBridge(base: base, gate: gate)
            let clock = ArtifactTestClock()
            let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                       overviewSleep: { try await clock.sleep($0) })
            store.syncHosts([ArtifactsHostDirectoryEntry(id: base.hostID, label: "host")])
            store.updateSessions([artifactStoreLiveSession(hostID: base.hostID)])
            let id = try XCTUnwrap(store.open(ArtifactOpenRequest(hostID: base.hostID, target: .file(path: "/hidden.txt"), origin: .files, stagedLocalURL: staged)))
            let owner = UUID()
            store.noteOverviewVisible(owner, true)
            await artifactEventually { await gate.isWaiting }
            switch stop {
            case "hidden": store.noteOverviewVisible(owner, false)
            case "background": store.setApplicationForeground(false)
            default: base.state = .dropped; store.updateSessions([])
            }
            await gate.resume()
            await artifactEventually { await clock.sleepCalls == 1 }
            XCTAssertEqual(store.tab(id)?.unseenChange, false, stop)
            XCTAssertEqual(base.attributePaths, ["/hidden.txt"], stop)
            XCTAssertEqual(base.connectCalls, 0, stop)
            store.noteOverviewVisible(owner, false)
        }
    }

    func testOverviewSweepDiscardsStatAfterCachedCopyIsReplaced() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("saved.txt")
        try Data("saved".utf8).write(to: staged)
        let base = ArtifactTestBridge()
        base.files["/hidden.txt"] = Data("saved".utf8)
        let gate = ArtifactStatTestGate()
        let bridge = ArtifactStatTestBridge(base: base, gate: gate)
        let clock = ArtifactTestClock()
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] },
                                   overviewSleep: { try await clock.sleep($0) })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: base.hostID, label: "host")])
        store.updateSessions([artifactStoreLiveSession(hostID: base.hostID)])
        let request = ArtifactOpenRequest(hostID: base.hostID, target: .file(path: "/hidden.txt"), origin: .files, stagedLocalURL: staged)
        let id = try XCTUnwrap(store.open(request))
        let originalCache = store.tab(id)?.cache
        let owner = UUID()
        defer { store.noteOverviewVisible(owner, false) }
        store.noteOverviewVisible(owner, true)
        await artifactEventually { await gate.isWaiting }
        try Data("new saved copy".utf8).write(to: staged)
        XCTAssertEqual(store.open(request), id)
        XCTAssertNotEqual(store.tab(id)?.cache, originalCache)
        await gate.resume()
        await artifactEventually { await clock.pendingCount == 1 }
        XCTAssertEqual(store.tab(id)?.unseenChange, false)
        XCTAssertEqual(store.tab(id)?.cache?.isStale, false)
    }
}
