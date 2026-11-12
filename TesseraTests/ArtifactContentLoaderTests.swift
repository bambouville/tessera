import Foundation
import Observation
import os
import TesseraArtifactsCore
import UIKit
import XCTest
@testable import Tessera

@MainActor
final class ArtifactContentLoaderTests: XCTestCase {
    func testSymlinkUsesTargetStatAndKeepsTheOpenedBasename() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        bridge.files["/versions/report.md"] = Data("bytes".utf8)
        bridge.symlinks["/srv/current.md"] = "/versions/report.md"
        let tab = artifactTestTab(path: "/srv/current.md", hostID: bridge.hostID)
        let loaded = try await loader.fetch(tab, bridge: bridge)
        let observed = try await ArtifactContentLoader.stat(tab.target.path, bridge: bridge)
        XCTAssertEqual(loaded.localURL.lastPathComponent, "current.md")
        XCTAssertEqual(observed.size, UInt64(loaded.size))
        XCTAssertEqual(loaded.size, 5)
        XCTAssertEqual(observed.path, tab.target.path)
        XCTAssertTrue(bridge.listings.isEmpty)
        XCTAssertTrue(bridge.realPaths.isEmpty)
        XCTAssertEqual(bridge.attributePaths, [tab.target.path, tab.target.path])
    }

    func testStatUsesOneAttributesRequestPerPollAndMapsMissingStatus() async throws {
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/report.md"] = Data("bytes".utf8)
        bridge.listError = .network("directory listings must not be used for stat")
        for _ in 0..<3 {
            let entry = try await ArtifactContentLoader.stat("/srv/report.md", bridge: bridge)
            XCTAssertEqual(entry.size, 5)
        }
        XCTAssertEqual(bridge.attributePaths, Array(repeating: "/srv/report.md", count: 3))
        XCTAssertTrue(bridge.listings.isEmpty)
        XCTAssertTrue(bridge.realPaths.isEmpty)
        do { _ = try await ArtifactContentLoader.stat("/srv/missing.md", bridge: bridge); XCTFail("missing stat") }
        catch ArtifactContentLoadError.missing { }
        bridge.state = .idle
        do { _ = try await ArtifactContentLoader.stat("/srv/report.md", bridge: bridge); XCTFail("offline stat") }
        catch FileBridgeError.notConnected { }
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testCacheKeepsBasenameAndAtomicallyReplacesBytes() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/srv/report.md", hostID: bridge.hostID)
        bridge.files[tab.target.path] = Data("first".utf8)
        let first = try await loader.fetch(tab, bridge: bridge)
        XCTAssertEqual(first.localURL.lastPathComponent, "report.md")
        XCTAssertEqual(first.localURL.deletingLastPathComponent().lastPathComponent, ArtifactsCachePolicy.cacheKey(tab))
        XCTAssertEqual(first.remoteMTime, 1_000)
        XCTAssertEqual(first.size, 5)

        bridge.files[tab.target.path] = Data("replacement".utf8)
        let second = try await loader.fetch(tab, bridge: bridge)
        XCTAssertEqual(first.localURL, second.localURL)
        XCTAssertEqual(try Data(contentsOf: first.localURL), Data("replacement".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: first.localURL.deletingLastPathComponent().path).contains { $0.hasPrefix(".partial-") })
        let partials = loader.cacheDirectory.appendingPathComponent(".partials", isDirectory: true)
        XCTAssertTrue(bridge.downloadURLs.allSatisfy { $0.deletingLastPathComponent() == partials })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: partials.path).isEmpty)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testFailedReplacementLeavesPreviousCopyIntact() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/srv/notes.txt", hostID: bridge.hostID)
        bridge.files[tab.target.path] = Data("complete".utf8)
        let file = try await loader.fetch(tab, bridge: bridge)
        bridge.files[tab.target.path] = Data("partial".utf8)
        bridge.failAfterWrite = true
        do { _ = try await loader.fetch(tab, bridge: bridge); XCTFail("download should fail") }
        catch { }
        XCTAssertEqual(try String(contentsOf: file.localURL, encoding: .utf8), "complete")
        let children = try FileManager.default.contentsOfDirectory(atPath: file.localURL.deletingLastPathComponent().path)
        XCTAssertEqual(children, ["notes.txt"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: loader.cacheDirectory.appendingPathComponent(".partials").path).isEmpty)
    }

    func testReplacementRemovesOnlyManifestSidecarsAndNeverTheDocument() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        for name in ["image-report.pdf", "image-document.png", "image-notes.md"] {
            let tab = artifactTestTab(path: "/srv/" + name, hostID: bridge.hostID)
            bridge.files[tab.target.path] = Data("first".utf8)
            let first = try await loader.fetch(tab, bridge: bridge)
            XCTAssertEqual(try Data(contentsOf: first.localURL), Data("first".utf8))
            let directory = first.localURL.deletingLastPathComponent()
            let sidecar = directory.appendingPathComponent("image-\(UUID().uuidString).png")
            let unrelated = directory.appendingPathComponent("image-keep.png")
            try Data([1]).write(to: sidecar)
            try Data([2]).write(to: unrelated)
            let manifest = MarkdownImageStaging.manifestURL(for: first.localURL)
            try JSONEncoder().encode(["photo.png": sidecar.lastPathComponent, "document.png": name]).write(to: manifest)

            bridge.files[tab.target.path] = Data("replacement".utf8)
            let replacement = try await loader.fetch(tab, bridge: bridge)
            XCTAssertEqual(try Data(contentsOf: replacement.localURL), Data("replacement".utf8))
            XCTAssertEqual(loader.cachedURL(for: tab), replacement.localURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
            XCTAssertEqual(try Data(contentsOf: unrelated), Data([2]))
        }
    }

    func testSizeLimitChecksStatAndGrowingUnknownLengthDownload() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/srv/large.pdf", hostID: bridge.hostID)
        bridge.files[tab.target.path] = Data([1])
        bridge.reportedSize = UInt64(ArtifactContentLoader.maximumFileBytes + 1)
        do { _ = try await loader.fetch(tab, bridge: bridge); XCTFail("stat must reject") }
        catch ArtifactContentLoadError.tooLarge(let bytes) { XCTAssertEqual(bytes, ArtifactContentLoader.maximumFileBytes + 1) }
        XCTAssertTrue(bridge.downloads.isEmpty)

        bridge.reportedSize = nil
        bridge.reportsSizes = false
        bridge.progressBytes = ArtifactContentLoader.maximumFileBytes + 1
        do { _ = try await loader.fetch(tab, bridge: bridge); XCTFail("progress must reject") }
        catch ArtifactContentLoadError.tooLarge(let bytes) { XCTAssertEqual(bytes, ArtifactContentLoader.maximumFileBytes + 1) }
        XCTAssertNil(loader.cachedURL(for: tab))
        XCTAssertEqual(bridge.downloads.count, 1)
    }

    func testOfflineFetchNeverConnectsAndKeepsTheCachedCopy() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/srv/file.txt", hostID: bridge.hostID)
        bridge.files[tab.target.path] = Data("cached".utf8)
        let file = try await loader.fetch(tab, bridge: bridge)
        bridge.state = .idle
        do { _ = try await loader.fetch(tab, bridge: bridge); XCTFail("offline must fail") }
        catch FileBridgeError.notConnected { }
        XCTAssertEqual(loader.cachedURL(for: tab), file.localURL)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testEvictionProtectsPinnedAndSelectedEvenOverBudget() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("123456".utf8).write(to: source)
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        var pinned = artifactTestTab(path: "/a.txt", viewedAt: 1)
        pinned.pinned = true
        let selected = artifactTestTab(path: "/b.txt", viewedAt: 2)
        let candidate = artifactTestTab(path: "/c.txt", viewedAt: 3)
        for tab in [pinned, selected, candidate] { _ = try loader.adopt(source, for: tab) }
        await loader.evict(tabs: [pinned, selected, candidate], selectedID: selected.id, budgetBytes: 8)
        XCTAssertNotNil(loader.cachedURL(for: pinned))
        XCTAssertNotNil(loader.cachedURL(for: selected))
        XCTAssertNil(loader.cachedURL(for: candidate))
    }

    func testEvictionUnionsExplicitInFlightKeysWithSelectedKey() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("bytes".utf8).write(to: source)
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let inFlight = artifactTestTab(path: "/loading.txt", viewedAt: 1)
        let selected = artifactTestTab(path: "/selected.txt", viewedAt: 2)
        let candidate = artifactTestTab(path: "/old.txt", viewedAt: 3)
        for tab in [inFlight, selected, candidate] { _ = try loader.adopt(source, for: tab) }
        await loader.evict(tabs: [inFlight, selected, candidate], selectedID: selected.id,
                     protectedKeys: [ArtifactsCachePolicy.cacheKey(inFlight)], budgetBytes: 0)
        XCTAssertNotNil(loader.cachedURL(for: inFlight))
        XCTAssertNotNil(loader.cachedURL(for: selected))
        XCTAssertNil(loader.cachedURL(for: candidate))
    }

    func testEvictionProtectsLiveDownloadWithoutAPartialFilename() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        bridge.files["/srv/loading.txt"] = Data("bytes".utf8)
        let tab = artifactTestTab(path: "/srv/loading.txt", hostID: bridge.hostID)
        let download = Task { try await loader.fetch(tab, bridge: bridge) }
        defer { download.cancel() }
        await artifactEventually { await gate.pendingCount == 1 }
        let directory = loader.localURL(for: tab).deletingLastPathComponent()
        let partial = try XCTUnwrap(bridge.downloadURLs.first)
        XCTAssertEqual(partial.deletingLastPathComponent(), loader.cacheDirectory.appendingPathComponent(".partials", isDirectory: true))
        try FileManager.default.removeItem(at: partial)
        try Data("old".utf8).write(to: loader.localURL(for: tab))
        await loader.evict(tabs: [tab], selectedID: nil, budgetBytes: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try Data("bytes".utf8).write(to: partial)
        await gate.tick()
        let loaded = try await download.value
        XCTAssertEqual(try Data(contentsOf: loaded.localURL), Data("bytes".utf8))
        await loader.evict(tabs: [tab], selectedID: nil, budgetBytes: 0)
        XCTAssertNil(loader.cachedURL(for: tab))
    }

    func testStartupReapsPreviousProcessPartialWithoutReapingALiveDownload() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/srv/report.txt", hostID: bridge.hostID)
        let cache = root.appendingPathComponent("cache")
        let directory = cache.appendingPathComponent(ArtifactsCachePolicy.cacheKey(tab))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let abandoned = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
        try Data("abandoned".utf8).write(to: abandoned)
        let partials = cache.appendingPathComponent(".partials", isDirectory: true)
        try FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
        let abandonedDownload = partials.appendingPathComponent("old-key-\(UUID().uuidString)")
        try Data("abandoned".utf8).write(to: abandonedDownload)
        let loader = ArtifactContentLoader(cacheDirectory: cache)
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        bridge.files[tab.target.path] = Data("accepted".utf8)
        let fetch = Task { try await loader.fetch(tab, bridge: bridge) }
        defer { fetch.cancel() }
        await artifactEventually { await gate.pendingCount == 1 }
        let livePartial = try XCTUnwrap(bridge.downloadURLs.first)
        XCTAssertEqual(livePartial.deletingLastPathComponent(), partials)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedDownload.path))
        await loader.evict(tabs: [tab], selectedID: nil, budgetBytes: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: livePartial.path))
        XCTAssertTrue(ArtifactContentLoader.cacheSizes(in: cache).keys.allSatisfy { $0 != ".partials" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        await gate.tick()
        _ = try await fetch.value
        await loader.evict(tabs: [tab], selectedID: nil, budgetBytes: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testStartupPreservesAcceptedPartialNamesAndTheirSidecars() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.md")
        try Data("cached document".utf8).write(to: source)
        let cache = root.appendingPathComponent("cache")
        let loader = ArtifactContentLoader(cacheDirectory: cache)
        var tabs = [artifactTestTab(path: "/srv/.partial-report.md"), artifactTestTab(path: "/srv/.partial-\(UUID().uuidString)")]
        var sidecars: [URL] = []
        for index in tabs.indices {
            tabs[index].pinned = true
            let document = try loader.adopt(source, for: tabs[index]).localURL
            let image = document.deletingLastPathComponent().appendingPathComponent("image-\(UUID().uuidString).png")
            try Data([1, 2, 3]).write(to: image)
            let manifest = MarkdownImageStaging.manifestURL(for: document)
            try JSONEncoder().encode(["photo.png": image.lastPathComponent]).write(to: manifest)
            sidecars += [manifest, image]
        }

        let restarted = ArtifactContentLoader(cacheDirectory: cache)
        await restarted.evict(tabs: tabs, selectedID: nil, budgetBytes: 0)
        for tab in tabs {
            let document = try XCTUnwrap(restarted.cachedURL(for: tab))
            XCTAssertEqual(try Data(contentsOf: document), Data("cached document".utf8))
            XCTAssertEqual(MarkdownImageStaging.images(for: document).count, 1)
        }
        XCTAssertTrue(sidecars.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testLegacyCleanupOnlyRemovesTheExactGeneratedPattern() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = artifactTestTab(path: "/srv/keep.md")
        let cache = root.appendingPathComponent("cache")
        let directory = cache.appendingPathComponent(ArtifactsCachePolicy.cacheKey(tab))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let abandoned = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
        let retained = [".partial-report.md", ".partial-previous-process", ".partial-\(UUID().uuidString).images.json",
                        ".partial-01234567-89ab-4cde-8f01-23456789abcd"].map { directory.appendingPathComponent($0) }
        for url in retained + [abandoned] { try Data([1]).write(to: url) }
        let loader = ArtifactContentLoader(cacheDirectory: cache)
        await loader.evict(tabs: [tab], selectedID: tab.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(retained.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testEvictionWalksOffMainAndUsesProtectionAtDecisionTime() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("bytes".utf8).write(to: source)
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"), walkCache: { directory in
            XCTAssertFalse(Thread.isMainThread)
            let sizes = ArtifactContentLoader.cacheSizes(in: directory)
            started.withLock { $0 = true }
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return sizes
        })
        var pinned = artifactTestTab(path: "/pinned.txt")
        let selected = artifactTestTab(path: "/selected.txt")
        let removed = artifactTestTab(path: "/removed.txt")
        for tab in [pinned, selected, removed] { _ = try loader.adopt(source, for: tab) }
        var selectedID: String?
        let eviction = Task {
            await loader.evict(budgetBytes: 0) { ([pinned, selected, removed], selectedID, []) }
        }
        defer { release.signal(); eviction.cancel() }
        await artifactEventually { started.withLock { $0 } }
        pinned.pinned = true
        selectedID = selected.id
        release.signal()
        await eviction.value
        XCTAssertNotNil(loader.cachedURL(for: pinned))
        XCTAssertNotNil(loader.cachedURL(for: selected))
        XCTAssertNil(loader.cachedURL(for: removed))
    }

    func testFencedEvictionRechecksEligibleKeysAndRestoredSelectionAfterTheBackgroundWalk() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("bytes".utf8).write(to: source)
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"), walkCache: { directory in
            XCTAssertFalse(Thread.isMainThread)
            let sizes = ArtifactContentLoader.cacheSizes(in: directory)
            started.withLock { $0 = true }
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return sizes
        })
        let old = artifactTestTab(path: "/old.txt")
        let restored = artifactTestTab(path: "/restored.txt")
        let victim = artifactTestTab(path: "/victim.txt")
        for tab in [old, restored, victim] { _ = try loader.adopt(source, for: tab) }
        var eligible = Set([old, restored, victim].map(ArtifactsCachePolicy.cacheKey))
        var selectedID: String?
        let eviction = Task {
            await loader.evict(budgetBytes: 0, evictableKeys: { eligible }) { ([restored, victim], selectedID, []) }
        }
        defer { release.signal(); eviction.cancel() }
        await artifactEventually { started.withLock { $0 } }
        eligible.remove(ArtifactsCachePolicy.cacheKey(old))
        selectedID = restored.id
        release.signal()
        await eviction.value
        XCTAssertNotNil(loader.cachedURL(for: old), "a key outside the current allowlist must survive even without a current tab")
        XCTAssertNotNil(loader.cachedURL(for: restored), "a restored selection is protected at decision time")
        XCTAssertNil(loader.cachedURL(for: victim))
    }

    func testMarkdownRefreshStatsAndReusesImagesByPathSizeAndMtime() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/docs/readme.md", hostID: bridge.hostID)
        let source = "![one](one.png) ![two](two.png)"
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        bridge.files[tab.target.path] = Data(source.utf8)
        bridge.files["/docs/one.png"] = png
        bridge.files["/docs/two.png"] = png
        let file = try await loader.fetch(tab, bridge: bridge)
        try await MarkdownImageStaging.stage(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        let initial = MarkdownImageStaging.images(for: file.localURL)
        XCTAssertEqual(initial.count, 2)
        bridge.downloads.removeAll()
        bridge.attributePaths.removeAll()

        bridge.files[tab.target.path] = Data((source + "\nupdated prose").utf8)
        _ = try await loader.fetch(tab, bridge: bridge)
        try await MarkdownImageStaging.stage(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertEqual(bridge.downloads, [tab.target.path])
        XCTAssertEqual(bridge.attributePaths, [tab.target.path, "/docs/one.png", "/docs/two.png"])
        XCTAssertEqual(MarkdownImageStaging.images(for: file.localURL), initial)

        bridge.downloads.removeAll()
        bridge.files["/docs/two.png"] = png + Data([0])
        bridge.files["/docs/three.png"] = png
        bridge.files[tab.target.path] = Data((source + " ![new](three.png)").utf8)
        _ = try await loader.fetch(tab, bridge: bridge)
        try await MarkdownImageStaging.stage(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertEqual(bridge.downloads, [tab.target.path, "/docs/two.png", "/docs/three.png"])
        let changed = MarkdownImageStaging.images(for: file.localURL)
        XCTAssertEqual(changed["one.png"], initial["one.png"])
        XCTAssertNotEqual(changed["two.png"], initial["two.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(initial["two.png"]).path))

        bridge.downloads.removeAll()
        bridge.modified = Date(timeIntervalSince1970: 2)
        _ = try await loader.fetch(tab, bridge: bridge)
        try await MarkdownImageStaging.stage(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertEqual(bridge.downloads, [tab.target.path, "/docs/one.png", "/docs/two.png", "/docs/three.png"])
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testMarkdownUnknownMetadataOrMissingThumbnailRequiresDownload() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = root.appendingPathComponent("readme.md")
        try Data("![one](one.png)".utf8).write(to: document)
        let bridge = ArtifactTestBridge()
        bridge.files["/docs/one.png"] = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        let thumbnail = try XCTUnwrap(MarkdownImageStaging.images(for: document)["one.png"])
        try FileManager.default.removeItem(at: thumbnail)
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        bridge.reportsSizes = false
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        XCTAssertEqual(bridge.downloads, Array(repeating: "/docs/one.png", count: 4))
        bridge.reportsSizes = true
        bridge.reportsModificationDates = false
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        XCTAssertEqual(bridge.downloads, Array(repeating: "/docs/one.png", count: 6))
        bridge.state = .idle
        do { try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge); XCTFail("offline") }
        catch FileBridgeError.notConnected { }
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testImageRefreshOwnershipSurvivesFailedFetchAndNewerAcceptance() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/docs/readme.md", hostID: bridge.hostID)
        bridge.files[tab.target.path] = Data("![one](one.png)".utf8)
        bridge.files["/docs/one.png"] = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        let file = try await loader.fetch(tab, bridge: bridge)
        try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        let original = MarkdownImageStaging.images(for: file.localURL)

        bridge.failAfterWrite = true
        do { _ = try await loader.fetch(tab, bridge: bridge, force: true); XCTFail("interrupted refresh") }
        catch { }
        bridge.failAfterWrite = false
        bridge.downloads.removeAll()
        try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertTrue(bridge.downloads.isEmpty, "a failed document refresh must not invalidate its images")
        XCTAssertEqual(MarkdownImageStaging.images(for: file.localURL), original)

        _ = try await loader.fetch(tab, bridge: bridge, force: true)
        let gate = ArtifactTestClock()
        bridge.downloadGate = gate
        let preparing = Task { try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge) }
        defer { preparing.cancel() }
        await artifactEventually { await gate.pendingCount == 1 }
        bridge.downloadGate = nil
        _ = try await loader.fetch(tab, bridge: bridge, force: true)
        await gate.tick()
        _ = try await preparing.value
        bridge.downloads.removeAll()
        try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertEqual(bridge.downloads, ["/docs/one.png"], "an older staging completion must not consume a newer refresh")
        bridge.downloads.removeAll()
        try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertTrue(bridge.downloads.isEmpty)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testFailedForcedImageStagingKeepsItsRefreshTokenUntilAllDownloadsComplete() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/docs/readme.md", hostID: bridge.hostID)
        bridge.files[tab.target.path] = Data("![one](one.png)".utf8)
        bridge.files["/docs/one.png"] = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        let file = try await loader.fetch(tab, bridge: bridge)
        try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        let original = MarkdownImageStaging.images(for: file.localURL)
        let thumbnail = try XCTUnwrap(original["one.png"])
        let originalBytes = try Data(contentsOf: thumbnail)
        _ = try await loader.fetch(tab, bridge: bridge, force: true)
        bridge.downloads.removeAll()
        bridge.failAfterWrite = true
        let incomplete = try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertFalse(incomplete)
        XCTAssertEqual(MarkdownImageStaging.images(for: file.localURL), original)
        XCTAssertEqual(try Data(contentsOf: thumbnail), originalBytes)
        XCTAssertEqual(bridge.downloads, ["/docs/one.png"])

        bridge.failAfterWrite = false
        let complete = try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertTrue(complete)
        XCTAssertEqual(bridge.downloads, ["/docs/one.png", "/docs/one.png"], "unchanged image stats must not consume a failed refresh token")
        let refreshed = try XCTUnwrap(MarkdownImageStaging.images(for: file.localURL)["one.png"])
        XCTAssertNotEqual(refreshed, thumbnail)
        bridge.downloads.removeAll()
        try await loader.prepareImages(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertTrue(bridge.downloads.isEmpty, "successful staging must clear the token")
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testReusedMarkdownImagesStillConsumeTheTotalByteBudget() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ArtifactContentLoader(cacheDirectory: root.appendingPathComponent("cache"))
        let bridge = ArtifactTestBridge()
        let tab = artifactTestTab(path: "/docs/readme.md", hostID: bridge.hostID)
        let source = (1...5).map { "![image](\($0).png)" }.joined(separator: " ")
        var png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        png.append(Data(repeating: 0, count: Int(MarkdownImageStaging.maxImageBytes) - png.count))
        bridge.files[tab.target.path] = Data(source.utf8)
        for number in 1...5 { bridge.files["/docs/\(number).png"] = png }
        let file = try await loader.fetch(tab, bridge: bridge)
        try await MarkdownImageStaging.stage(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertEqual(MarkdownImageStaging.images(for: file.localURL).count, 4)
        bridge.downloads.removeAll()
        _ = try await loader.fetch(tab, bridge: bridge)
        try await MarkdownImageStaging.stage(document: file.localURL, remotePath: tab.target.path, bridge: bridge)
        XCTAssertEqual(bridge.downloads, [tab.target.path], "reusing four 8 MiB images must not admit a fifth image")
        XCTAssertEqual(MarkdownImageStaging.images(for: file.localURL).count, 4)
        let original = MarkdownImageStaging.images(for: file.localURL)
        bridge.downloads.removeAll()
        bridge.failAfterWrite = true
        let completed = try await MarkdownImageStaging.stage(document: file.localURL, remotePath: tab.target.path, bridge: bridge, force: true)
        XCTAssertFalse(completed)
        XCTAssertEqual(bridge.downloads, (1...4).map { "/docs/\($0).png" }, "fallback thumbnails must still consume their original byte budget")
        XCTAssertEqual(MarkdownImageStaging.images(for: file.localURL), original)
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    func testReaderMapsMissingAndDeniedAndBoundsResources() async throws {
        let bridge = ArtifactTestBridge()
        let reader = ArtifactFileBridgeReader { bridge }
        do { _ = try await reader.read(absolutePath: "/srv/missing.js", allowedRoot: "/srv", maxBytes: 4); XCTFail("missing") }
        catch ArtifactRemoteReadError.notFound { }
        bridge.files["/srv/denied.js"] = Data([1])
        bridge.attributeError = .remoteStatus(code: 3, message: "denied")
        do { _ = try await reader.read(absolutePath: "/srv/denied.js", allowedRoot: "/srv", maxBytes: 4); XCTFail("denied") }
        catch ArtifactRemoteReadError.forbidden { }
        bridge.attributeError = nil
        bridge.files["/srv/file.js"] = Data("12345".utf8)
        bridge.reportsSizes = false
        do { _ = try await reader.read(absolutePath: "/srv/file.js", allowedRoot: "/srv", maxBytes: 4); XCTFail("oversized") }
        catch ArtifactRemoteReadError.fileTooLarge(let limit) { XCTAssertEqual(limit, 4) }
        bridge.state = .dropped
        do { _ = try await reader.read(absolutePath: "/srv/file.js", allowedRoot: "/srv", maxBytes: 8); XCTFail("offline") }
        catch FileBridgeError.notConnected { }
        XCTAssertEqual(bridge.connectCalls, 0)
    }
}

func artifactTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("artifacts-tests-\(UUID().uuidString)", isDirectory: true)
}

func artifactTestTab(path: String, hostID: UUID = UUID(), viewedAt: Int64 = 1) -> ArtifactTab {
    ArtifactTab(id: UUID().uuidString, hostID: hostID.uuidString, hostLabel: "test host", target: .file(path: path),
                title: (path as NSString).lastPathComponent, openedAt: viewedAt, viewedAt: viewedAt)
}

@MainActor
func artifactEventually(_ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<500 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("condition did not settle", file: file, line: line)
}

@MainActor
@Observable
final class ArtifactTestBridge: FileBridging {
    let hostID: UUID
    let key: FileBridgeKey
    var state: FileBridgeState = .connected
    var homeDirectory: String? = "/home/test"
    var artifactForwarding: PortForwarderManager?
    var suppressIdleTeardown = false
    var files: [String: Data] = [:]
    var symlinks: [String: String] = [:]
    var directories: Set<String> = []
    var modified = Date(timeIntervalSince1970: 1)
    var reportsSizes = true
    var reportsModificationDates = true
    var reportedSize: UInt64?
    var progressBytes: Int64?
    var failAfterWrite = false
    var listError: FileBridgeError?
    var attributeError: FileBridgeError?
    var realPathErrors: [String: FileBridgeError] = [:]
    var downloads: [String] = []
    var downloadURLs: [URL] = []
    var listings: [String] = []
    var attributePaths: [String] = []
    var realPaths: [String] = []
    var connectCalls = 0
    var execOutput = ""
    var execCalls = 0
    @ObservationIgnored var downloadGate: ArtifactTestClock?

    init(hostID: UUID = UUID(), jumpPath: [String] = []) {
        self.hostID = hostID
        key = FileBridgeKey(hostID: hostID, user: "test", address: "unused.invalid", port: 22, jumpPath: jumpPath)
    }

    /// Only a test of the user's explicit Files reconnect lets artifacts connect.
    var allowsConnect = false
    var connectError: FileBridgeError?
    func connect() async throws {
        connectCalls += 1
        guard allowsConnect else { XCTFail("artifacts must never connect a bridge"); throw FileBridgeError.notConnected }
        if let connectError { throw connectError }
        state = .connected
    }
    func disconnect() async { state = .idle }
    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        guard state == .connected else { throw FileBridgeError.notConnected }
        listings.append(path)
        if let listError { throw listError }
        let children = files.filter { ($0.key as NSString).deletingLastPathComponent == path }.map { name, data in
            RemoteFileEntry(name: (name as NSString).lastPathComponent, path: name, kind: .file,
                            size: reportsSizes ? (reportedSize ?? UInt64(data.count)) : nil, modified: modified, permissions: nil)
        }
        let links = symlinks.filter { ($0.key as NSString).deletingLastPathComponent == path }.map { name, target in
            RemoteFileEntry(name: (name as NSString).lastPathComponent, path: name, kind: .symlink,
                            size: UInt64(target.utf8.count), modified: modified, permissions: nil)
        }
        return children + links + directories.filter { ($0 as NSString).deletingLastPathComponent == path }.map {
            RemoteFileEntry(name: ($0 as NSString).lastPathComponent, path: $0, kind: .directory, size: nil, modified: nil, permissions: nil)
        }
    }
    func attributes(_ path: String) async throws -> RemoteFileEntry {
        guard state == .connected else { throw FileBridgeError.notConnected }
        attributePaths.append(path)
        if let attributeError { throw attributeError }
        let resolved = try resolvedPath(path)
        if let data = files[resolved] {
            return RemoteFileEntry(name: (path as NSString).lastPathComponent, path: path, kind: .file,
                                   size: reportsSizes ? (reportedSize ?? UInt64(data.count)) : nil,
                                   modified: reportsModificationDates ? modified : nil, permissions: 0o644)
        }
        if isDirectory(resolved) {
            return RemoteFileEntry(name: path == "/" ? "/" : (path as NSString).lastPathComponent,
                                   path: path, kind: .directory, size: nil, modified: nil, permissions: 0o755)
        }
        throw FileBridgeError.remoteStatus(code: 2, message: "missing")
    }
    func realPath(_ path: String) async throws -> String {
        guard state == .connected else { throw FileBridgeError.notConnected }
        realPaths.append(path)
        if let error = realPathErrors[path] { throw error }
        let resolved = try resolvedPath(path)
        guard files[resolved] != nil || isDirectory(resolved) else { throw FileBridgeError.remoteStatus(code: 2, message: "missing") }
        return resolved
    }
    private func resolvedPath(_ path: String) throws -> String {
        var resolved = path
        for _ in 0..<32 {
            guard let link = symlinks.keys.filter({ resolved == $0 || resolved.hasPrefix($0 + "/") })
                .max(by: { $0.count < $1.count }) else { return resolved }
            resolved = symlinks[link]! + resolved.dropFirst(link.count)
        }
        throw FileBridgeError.remoteStatus(code: 4, message: "symlink loop")
    }
    private func isDirectory(_ path: String) -> Bool {
        let prefix = path == "/" ? "/" : path + "/"
        return path == "/" || directories.contains(path)
            || files.keys.contains(where: { $0.hasPrefix(prefix) })
            || symlinks.keys.contains(where: { $0.hasPrefix(prefix) })
    }
    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        guard state == .connected else { throw FileBridgeError.notConnected }
        downloads.append(remotePath)
        downloadURLs.append(localURL)
        guard let bytes = files[try resolvedPath(remotePath)] else { throw FileBridgeError.remoteStatus(code: 2, message: "missing") }
        try bytes.write(to: localURL)
        progress?(progressBytes ?? Int64(bytes.count), reportsSizes ? Int64(clamping: reportedSize ?? UInt64(bytes.count)) : nil)
        if let downloadGate { try await downloadGate.sleep(0) }
        try Task.checkCancellation()
        if failAfterWrite { throw FileBridgeError.network("interrupted") }
    }
    func createDirectory(_ path: String) async throws { XCTFail("unexpected mutation") }
    func setPermissions(_ permissions: UInt16, at path: String) async throws { XCTFail("unexpected mutation") }
    func rename(from oldPath: String, to newPath: String) async throws { XCTFail("unexpected mutation") }
    func removeFile(_ path: String) async throws { XCTFail("unexpected mutation") }
    func removeDirectory(_ path: String) async throws { XCTFail("unexpected mutation") }
    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws { XCTFail("unexpected upload") }
    func exec(_ command: String, inShell: Bool) async throws -> String {
        guard state == .connected else { throw FileBridgeError.notConnected }
        execCalls += 1
        return execOutput
    }
}

actor ArtifactTestClock {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var pendingCount: Int { waiters.count }
    private(set) var sleepCalls = 0
    private(set) var durations: [UInt64] = []

    func sleep(_ nanoseconds: UInt64) async throws {
        sleepCalls += 1
        durations.append(nanoseconds)
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func tick() {
        let current = waiters
        waiters.removeAll()
        for waiter in current.values { waiter.resume() }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
