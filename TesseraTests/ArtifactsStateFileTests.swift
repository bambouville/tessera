import Foundation
import Dispatch
import TesseraArtifactsCore
import XCTest
@testable import Tessera

@MainActor
final class ArtifactsStateFileTests: XCTestCase {
    func testUnavailableBlobFencesWritesAndDefersAllInvalidBlobDeletionUntilRecovery() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = changeTab("invalid", diff: "+invalid\n")
        let valid = changeTab("valid", diff: "+valid\n")
        let state = ArtifactsState(tabs: [invalid, valid], selectedID: invalid.id)
        let seed = ArtifactsStateFile(directory: root)
        seed.schedule(state)
        seed.flush()
        let manifest = try Data(contentsOf: seed.stateURL)
        let digests = ArtifactsPersistence.blobDigests(manifest)
        XCTAssertEqual(digests.count, 2)
        // Manifest order follows the digests, not the tabs: find each tab's blob by its content.
        let blobs = digests.map { root.appendingPathComponent("changes/" + $0 + ".diff") }
        let rejectedBlob = try XCTUnwrap(blobs.first { (try? String(contentsOf: $0, encoding: .utf8)) == "+invalid\n" })
        let unavailableBlob = try XCTUnwrap(blobs.first { $0 != rejectedBlob })
        let original = try Data(contentsOf: unavailableBlob)
        let invalidBytes = Data("tampered".utf8)
        try invalidBytes.write(to: rejectedBlob, options: .atomic)
        let trace = ArtifactStateWriteTrace()
        trace.failReadName = unavailableBlob.lastPathComponent
        let file = ArtifactsStateFile(directory: root, encode: {
            trace.encoded(onMain: Thread.isMainThread)
            return ArtifactsPersistence.split($0)
        }, write: { data, url in
            trace.wrote(data.count, to: url)
            try data.write(to: url, options: .atomic)
        }, blobRead: { url in
            if trace.failReadName == url.lastPathComponent { throw CocoaError(.fileReadNoPermission) }
        })
        XCTAssertEqual(file.load(), ArtifactsState())
        XCTAssertTrue(file.isLoadUnavailable)
        file.schedule(ArtifactsState())
        file.flush()
        file.flush()
        XCTAssertTrue(trace.writtenNames.isEmpty)
        XCTAssertTrue(trace.encodedOnMain.isEmpty, "fenced saves must stop before encoding or collection")
        XCTAssertEqual(try Data(contentsOf: seed.stateURL), manifest)
        XCTAssertEqual(try Data(contentsOf: rejectedBlob), invalidBytes, "nothing is deleted during an unavailable restore")
        XCTAssertEqual(try Data(contentsOf: unavailableBlob), original)

        trace.failReadName = nil
        let restored = file.load()
        XCTAssertFalse(file.isLoadUnavailable)
        XCTAssertEqual(restored.tabs, [valid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedBlob.path))
        file.flush()
        XCTAssertEqual(try Data(contentsOf: seed.stateURL), manifest, "the temporary empty snapshot must not overwrite recovery")
        file.schedule(restored)
        file.flush()
        XCTAssertEqual(ArtifactsStateFile(directory: root).load(), restored)
    }

    func testUnavailableManifestPreservesManifestAndBlobsAndKeepsSavesFenced() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ArtifactsState(tabs: [changeTab("change", diff: "+kept\n")], selectedID: "change")
        let seed = ArtifactsStateFile(directory: root)
        seed.schedule(state)
        seed.flush()
        let manifest = try Data(contentsOf: seed.stateURL)
        let digest = try XCTUnwrap(ArtifactsPersistence.blobDigests(manifest).first)
        let blob = root.appendingPathComponent("changes/" + digest + ".diff")
        let original = try Data(contentsOf: blob)
        let trace = ArtifactStateWriteTrace()
        trace.failReadName = "state.json"
        let file = ArtifactsStateFile(directory: root, write: { data, url in
            trace.wrote(data.count, to: url)
            try data.write(to: url, options: .atomic)
        }, readState: { url in
            if trace.failReadName == url.lastPathComponent { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        XCTAssertEqual(file.load(), ArtifactsState())
        XCTAssertTrue(file.isLoadUnavailable)
        file.schedule(ArtifactsState())
        file.flush()
        XCTAssertTrue(trace.writtenNames.isEmpty)
        XCTAssertEqual(try Data(contentsOf: seed.stateURL), manifest)
        XCTAssertEqual(try Data(contentsOf: blob), original)
        trace.failReadName = nil
        XCTAssertEqual(file.load(), state)
        XCTAssertFalse(file.isLoadUnavailable)
        file.flush()
        XCTAssertEqual(try Data(contentsOf: seed.stateURL), manifest)
    }

    func testVerifiedBlobDeletedTruncatedOrReplacedByDirectoryIsRepairedWithOneStatAndNoRead() throws {
        for damage in ["deleted", "truncated", "directory"] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let first = changeTab("first", diff: "+good é\n")
            let second = changeTab("second", diff: "+retained\n")
            let state = ArtifactsState(tabs: [first, second], selectedID: second.id)
            let digest = try XCTUnwrap(ArtifactsPersistence.split(ArtifactsState(tabs: [first])).blobs.keys.first)
            let blob = root.appendingPathComponent("changes/" + digest + ".diff")
            let expected = Data("+good é\n".utf8)
            let trace = ArtifactStateWriteTrace()
            let file = ArtifactsStateFile(directory: root, write: { data, url in
                if url.lastPathComponent == "state.json" {
                    XCTAssertEqual(try Data(contentsOf: blob), expected, "repair must precede manifest publication")
                }
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                trace.wrote(data.count, to: url)
            }, blobRead: { trace.readBlob($0, onMain: Thread.isMainThread) }, blobStat: { url in
                trace.statted(url, onMain: Thread.isMainThread)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return ((attributes[.type] as? FileAttributeType) == .typeRegular,
                        (attributes[.size] as? NSNumber)?.intValue ?? -1)
            })
            file.schedule(state)
            file.flush()
            if damage == "truncated" { try Data("+g".utf8).write(to: blob, options: .atomic) }
            else {
                try FileManager.default.removeItem(at: blob)
                if damage == "directory" { try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: false) }
            }
            trace.resetIO()
            file.schedule(state)
            file.flush()
            XCTAssertEqual(trace.writtenNames, [digest + ".diff", "state.json"], damage)
            XCTAssertEqual(trace.blobReads, 0, damage)
            XCTAssertEqual(trace.statNames.sorted(), ArtifactsPersistence.split(state).blobs.keys.map { $0 + ".diff" }.sorted())
            XCTAssertEqual(trace.statOnMain, [false, false], "one off-main stat per retained blob")
            XCTAssertEqual(try Data(contentsOf: blob), expected)
            XCTAssertEqual(ArtifactsStateFile(directory: root).load(), state)
        }
    }

    func testCollectionForgetsVerificationEvenWhenTheUnreferencedBlobAlreadyVanished() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = ArtifactStateWriteTrace()
        let file = ArtifactsStateFile(directory: root, blobRead: { trace.readBlob($0, onMain: Thread.isMainThread) })
        let state = ArtifactsState(tabs: [changeTab("change", diff: "+good\n")], selectedID: "change")
        file.schedule(state)
        file.flush()
        let digest = try XCTUnwrap(ArtifactsPersistence.split(state).blobs.keys.first)
        let blob = root.appendingPathComponent("changes/" + digest + ".diff")
        try FileManager.default.removeItem(at: blob)
        file.schedule(ArtifactsState())
        file.flush()
        try Data("+evil\n".utf8).write(to: blob, options: .atomic)
        file.schedule(state)
        file.flush()
        XCTAssertEqual(trace.blobReads, 1, "an unreferenced digest must lose trust even if GC never sees its file")
        XCTAssertEqual(ArtifactsStateFile(directory: root).load(), state)
    }

    func testNonregularBlobIsInvalidRatherThanUnavailableAndAbsenceDoesNotFence() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ArtifactsStateFile(directory: root)
        XCTAssertEqual(file.load(), ArtifactsState())
        XCTAssertFalse(file.isLoadUnavailable)
        let state = ArtifactsState(tabs: [changeTab("change", diff: "+good\n")])
        file.schedule(state)
        file.flush()
        let digest = try XCTUnwrap(ArtifactsPersistence.split(state).blobs.keys.first)
        let blob = root.appendingPathComponent("changes/" + digest + ".diff")
        try FileManager.default.removeItem(at: blob)
        try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: false)
        XCTAssertTrue(file.load().tabs.isEmpty)
        XCTAssertFalse(file.isLoadUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertTrue(file.load().tabs.isEmpty)
        XCTAssertFalse(file.isLoadUnavailable, "an absent referenced blob keeps today's drop-only behavior")
    }

    func testMetadataRefreshWritesNoDiffBytesAndANewSnapshotWritesItsBlobOnce() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = ArtifactStateWriteTrace()
        let file = ArtifactsStateFile(directory: root, encode: {
            trace.encoded(onMain: Thread.isMainThread)
            return ArtifactsPersistence.split($0)
        }, write: { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            trace.wrote(data.count, to: url)
        })
        let change = changeTab("change", diff: String(repeating: "x", count: 256 * 1024))
        let document = artifactTestTab(path: "/report.md")
        var state = ArtifactsState(tabs: [change, document], selectedID: document.id)
        file.schedule(state)
        file.flush()
        XCTAssertEqual(trace.blobWrites, 1)
        XCTAssertEqual(trace.blobBytes, 256 * 1024)
        let written = trace.blobBytes
        for now: Int64 in 1...3 {
            state = ArtifactsReducer.reduce(state, .fetched(tabID: document.id,
                cache: .init(fetchedAt: now, size: now), nowMillis: now)).state
            file.schedule(state)
            file.flush()
        }
        XCTAssertEqual(trace.blobWrites, 1)
        XCTAssertEqual(trace.blobBytes - written, 0, "follower metadata must write no diff bytes")
        XCTAssertEqual(trace.stateWrites, 4)
        XCTAssertFalse(trace.encodedOnMain.contains(true), "synchronous flush must also encode off Main")
        XCTAssertEqual(file.load(), state)
        let manifest = try Data(contentsOf: file.stateURL)
        XCTAssertLessThan(manifest.count, 2048)
        XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains("\"diff\":"))
    }

    func testLegacyInlineStateMigratesAndUnreferencedBlobsAreCollected() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ArtifactsStateFile(directory: root)
        let state = ArtifactsState(tabs: [changeTab("a", diff: "+legacy\n"), changeTab("b", diff: "+b\n")], selectedID: "b")
        try ArtifactsStateFile.prepareDirectory(root)
        try ArtifactsPersistence.encode(state).write(to: file.stateURL, options: .atomic)
        XCTAssertEqual(file.load(), state)
        file.schedule(file.load())
        file.flush()
        let manifest = try Data(contentsOf: file.stateURL)
        let digests = ArtifactsPersistence.blobDigests(manifest)
        XCTAssertEqual(digests.count, 2)
        let changes = root.appendingPathComponent("changes", isDirectory: true)
        XCTAssertEqual(try changes.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        for digest in digests {
            let blob = changes.appendingPathComponent(digest + ".diff")
            XCTAssertEqual(try blob.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
        file.schedule(ArtifactsState(tabs: [state.tabs[1]], selectedID: "b"))
        file.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: changes.path).count, 1)
        file.schedule(ArtifactsState())
        file.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: changes.path), [])
    }

    func testMissingTamperedOversizedAndInvalidUTF8BlobsDropOnlyTheirTab() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ArtifactsStateFile(directory: root)
        let a = changeTab("a", diff: "+a\n")
        let b = changeTab("b", diff: "+b\n")
        let document = artifactTestTab(path: "/report.md")
        let state = ArtifactsState(tabs: [a, b, document], selectedID: "b")
        file.schedule(state)
        file.flush()
        let files = ArtifactsPersistence.split(ArtifactsState(tabs: [a]))
        let digest = try XCTUnwrap(files.blobs.keys.first)
        let blob = root.appendingPathComponent("changes/" + digest + ".diff")
        let original = try Data(contentsOf: blob)
        for replacement: Data? in [nil, Data("+tampered\n".utf8), Data(repeating: 120, count: 256 * 1024 + 1), Data([0xff])] {
            if let replacement { try replacement.write(to: blob, options: .atomic) }
            else { try FileManager.default.removeItem(at: blob) }
            XCTAssertEqual(file.load(), ArtifactsState(tabs: [b, document], selectedID: "b"))
            try original.write(to: blob, options: .atomic)
        }
    }

    func testRejectedBlobIsRemovedAndReopeningThenSavingRepairsTheTab() throws {
        for replacement: Data? in [nil, Data("+go".utf8), Data("+evil\n".utf8),
                                  Data(repeating: 120, count: 256 * 1024 + 1), Data([0xff])] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = ArtifactsStateFile(directory: root)
            let change = changeTab("change", diff: "+good\n")
            let document = artifactTestTab(path: "/report.md")
            let state = ArtifactsState(tabs: [change, document], selectedID: document.id)
            file.schedule(state)
            file.flush()
            let digest = try XCTUnwrap(ArtifactsPersistence.split(state).blobs.keys.first)
            let blob = root.appendingPathComponent("changes/" + digest + ".diff")
            if let replacement { try replacement.write(to: blob, options: .atomic) }
            else { try FileManager.default.removeItem(at: blob) }
            let loaded = file.load()
            XCTAssertEqual(loaded.tabs, [document])
            XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path), "rejected blobs must lose both their file and verification")
            let reopened = ArtifactsReducer.reduce(loaded, .open(.init(
                id: "reopened", hostID: change.hostID, hostLabel: change.hostLabel,
                target: change.target, title: change.title
            ), nowMillis: 2)).state
            file.schedule(reopened)
            file.flush()
            XCTAssertEqual(ArtifactsStateFile(directory: root).load(), reopened)
            XCTAssertEqual(try Data(contentsOf: blob), Data("+good\n".utf8))
        }
    }

    func testUnverifiedCorruptBlobIsReplacedBeforePublishingTheManifest() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let change = changeTab("change", diff: "+good\n")
        let state = ArtifactsState(tabs: [change], selectedID: change.id)
        let digest = try XCTUnwrap(ArtifactsPersistence.split(state).blobs.keys.first)
        let changes = root.appendingPathComponent("changes", isDirectory: true)
        try ArtifactsStateFile.prepareDirectory(changes)
        let blob = changes.appendingPathComponent(digest + ".diff")
        try Data("+evil\n".utf8).write(to: blob, options: .atomic)
        let trace = ArtifactStateWriteTrace()
        let file = ArtifactsStateFile(directory: root, write: { data, url in
            if url.lastPathComponent == "state.json" {
                XCTAssertEqual(try Data(contentsOf: blob), Data("+good\n".utf8), "repair must precede manifest publication")
            }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            trace.wrote(data.count, to: url)
        }, blobRead: { trace.readBlob($0, onMain: Thread.isMainThread) })
        file.schedule(state)
        file.flush()
        XCTAssertEqual(trace.writtenNames, [digest + ".diff", "state.json"])
        XCTAssertEqual(trace.blobReads, 1)
        XCTAssertEqual(trace.readOnMain, [false])
        XCTAssertEqual(ArtifactsStateFile(directory: root).load(), state)
    }

    func testWrittenBlobIsNeverReadByLaterSaves() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = ArtifactStateWriteTrace()
        let file = ArtifactsStateFile(directory: root, write: { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            trace.wrote(data.count, to: url)
        }, blobRead: { trace.readBlob($0, onMain: Thread.isMainThread) })
        var state = ArtifactsState(tabs: [changeTab("change", diff: "+good\n")], selectedID: "change")
        for now: Int64 in 1...4 {
            state.tabs[0].viewedAt = now
            file.schedule(state)
            file.flush()
        }
        XCTAssertEqual(trace.blobReads, 0)
        XCTAssertEqual(trace.blobWrites, 1)
        XCTAssertEqual(trace.stateWrites, 4)
        XCTAssertEqual(ArtifactsStateFile(directory: root).load(), state)
    }

    func testValidPreexistingBlobIsReadOnceAtLoadOrSaveThenTrusted() throws {
        for loadFirst in [false, true] {
            let root = artifactTestDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var state = ArtifactsState(tabs: [changeTab("change", diff: "+good\n")], selectedID: "change")
            let previous = ArtifactsStateFile(directory: root)
            previous.schedule(state)
            previous.flush()
            let trace = ArtifactStateWriteTrace()
            let file = ArtifactsStateFile(directory: root, write: { data, url in
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                trace.wrote(data.count, to: url)
            }, blobRead: { trace.readBlob($0, onMain: Thread.isMainThread) })
            if loadFirst {
                XCTAssertEqual(file.load(), state)
                XCTAssertEqual(trace.blobReads, 1)
            }
            for now: Int64 in 2...4 {
                state.tabs[0].viewedAt = now
                file.schedule(state)
                file.flush()
                XCTAssertEqual(trace.blobReads, 1, "trust must survive metadata-only saves")
            }
            XCTAssertEqual(trace.blobWrites, 0)
            XCTAssertEqual(trace.stateWrites, 3)
            XCTAssertEqual(trace.readOnMain, [false])
            XCTAssertEqual(ArtifactsStateFile(directory: root).load(), state)
        }
    }

    func testCollectionForgetsVerificationBeforeTheSameBlobIsReintroduced() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = ArtifactStateWriteTrace()
        let file = ArtifactsStateFile(directory: root, blobRead: { trace.readBlob($0, onMain: Thread.isMainThread) })
        let state = ArtifactsState(tabs: [changeTab("change", diff: "+good\n")], selectedID: "change")
        file.schedule(state)
        file.flush()
        let digest = try XCTUnwrap(ArtifactsPersistence.split(state).blobs.keys.first)
        let blob = root.appendingPathComponent("changes/" + digest + ".diff")
        file.schedule(ArtifactsState())
        file.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        try Data("+evil\n".utf8).write(to: blob, options: .atomic)
        file.schedule(state)
        file.flush()
        XCTAssertEqual(trace.blobReads, 1)
        XCTAssertEqual(ArtifactsStateFile(directory: root).load(), state)
    }

    func testFailedBlobRepairPreservesTheManifestAndRetriesThePendingSnapshot() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = ArtifactsState(tabs: [artifactTestTab(path: "/previous.md")])
        let seed = ArtifactsStateFile(directory: root)
        seed.schedule(previous)
        seed.flush()
        let newest = ArtifactsState(tabs: [changeTab("change", diff: "+good\n")], selectedID: "change")
        let digest = try XCTUnwrap(ArtifactsPersistence.split(newest).blobs.keys.first)
        let changes = root.appendingPathComponent("changes", isDirectory: true)
        try ArtifactsStateFile.prepareDirectory(changes)
        let blob = changes.appendingPathComponent(digest + ".diff")
        try Data("+evil\n".utf8).write(to: blob, options: .atomic)
        let trace = ArtifactStateWriteTrace()
        trace.failBlob = true
        let file = ArtifactsStateFile(directory: root, write: { data, url in
            if url.pathExtension == "diff", trace.failBlob { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            trace.wrote(data.count, to: url)
        })
        file.schedule(newest)
        file.flush()
        XCTAssertEqual(ArtifactsStateFile(directory: root).load(), previous)
        XCTAssertEqual(trace.stateWrites, 0)
        trace.failBlob = false
        file.flush()
        XCTAssertEqual(trace.writtenNames, [digest + ".diff", "state.json"])
        XCTAssertEqual(ArtifactsStateFile(directory: root).load(), newest)
    }

    func testBackgroundDebounceAndRapidScheduleFlushCannotPublishAnOlderSnapshotLast() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ArtifactTestClock()
        let entered = expectation(description: "background encoding entered")
        let release = DispatchSemaphore(value: 0)
        let trace = ArtifactStateWriteTrace()
        let file = ArtifactsStateFile(directory: root, sleep: { try await clock.sleep($0) }, encode: { state in
            trace.encoded(onMain: Thread.isMainThread)
            if state.filter == .docs {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return ArtifactsPersistence.split(state)
        }, write: { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            trace.wrote(data.count, to: url)
        })
        file.schedule(ArtifactsState(filter: .docs))
        await artifactEventually { await clock.pendingCount == 1 }
        await clock.tick()
        await fulfillment(of: [entered], timeout: 5)
        file.schedule(ArtifactsState(filter: .files))
        file.schedule(ArtifactsState(filter: .pages))
        DispatchQueue.global(qos: .utility).async { release.signal() }
        file.flush()
        XCTAssertEqual(file.load().filter, .pages)
        await clock.tick()
        await Task.yield()
        XCTAssertEqual(file.load().filter, .pages)
        XCTAssertEqual(trace.stateWrites, 2)
        XCTAssertEqual(trace.encodedOnMain, [false, false])
    }

    func testFailedManifestWriteKeepsPreviousBlobsAndPendingSnapshotForRetry() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = ArtifactStateWriteTrace()
        let file = ArtifactsStateFile(directory: root, write: { data, url in
            if url.lastPathComponent == "state.json", trace.failManifest { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        })
        let first = ArtifactsState(tabs: [changeTab("first", diff: "+first\n")])
        file.schedule(first)
        file.flush()
        trace.failManifest = true
        let newest = ArtifactsState(tabs: [changeTab("newest", diff: "+newest\n")])
        file.schedule(newest)
        file.flush()
        XCTAssertEqual(file.load(), first)
        trace.failManifest = false
        file.flush()
        XCTAssertEqual(file.load(), newest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("changes").path).count, 1)
    }

    private func changeTab(_ id: String, diff: String) -> ArtifactTab {
        .init(id: id, hostID: "host", hostLabel: "dev", target: .change(path: "/" + id, diff: diff, summary: "edit"),
              title: id, openedAt: 1, viewedAt: 1)
    }

    func testCorruptOrAbsentFileIsAnEmptyState() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ArtifactsStateFile(directory: root)
        XCTAssertEqual(file.load(), ArtifactsState())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.stateURL)
        XCTAssertEqual(file.load(), ArtifactsState())
    }

    func testDebounceWritesOnlyTheNewestSnapshotAndFlushIsImmediate() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ArtifactTestClock()
        let file = ArtifactsStateFile(directory: root, sleep: { try await clock.sleep($0) })
        let a = artifactTestTab(path: "/a.md")
        let first = ArtifactsState(tabs: [a], selectedID: a.id)
        file.schedule(first)
        await artifactEventually { await clock.pendingCount == 1 }
        let durations = await clock.durations
        XCTAssertEqual(durations, [500_000_000])
        let b = artifactTestTab(path: "/b.md")
        let latest = ArtifactsState(tabs: [a, b], selectedID: b.id, filter: .docs)
        file.schedule(latest)
        await artifactEventually {
            let calls = await clock.sleepCalls
            let pending = await clock.pendingCount
            return calls >= 2 && pending == 1
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.stateURL.path))
        await clock.tick()
        await artifactEventually { file.load() == latest }

        file.schedule(first)
        file.flush()
        XCTAssertEqual(file.load(), first)
        await clock.tick()
        XCTAssertEqual(file.load(), first)
    }

    func testProtectionAndBackupExclusionSurviveAtomicReplacement() throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ArtifactsStateFile(directory: root)
        file.schedule(ArtifactsState())
        file.flush()
        let tab = artifactTestTab(path: "/report.md")
        file.schedule(ArtifactsState(tabs: [tab], selectedID: tab.id))
        file.flush()
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try file.stateURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.stateURL.path)
        let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? (attributes[.protectionKey] as? String)
        guard let protection else { throw XCTSkip("this test filesystem does not expose iOS file protection") }
        XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    }
}

private final class ArtifactStateWriteTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [(URL, Int)] = []
    private var encodings: [Bool] = []
    private var reads: [(URL, Bool)] = []
    private var stats: [(URL, Bool)] = []
    private var fail = false
    private var failRepair = false
    private var unavailableReadName: String?

    func encoded(onMain: Bool) { lock.lock(); defer { lock.unlock() }; encodings.append(onMain) }
    func wrote(_ count: Int, to url: URL) { lock.lock(); defer { lock.unlock() }; writes.append((url, count)) }
    func readBlob(_ url: URL, onMain: Bool) { lock.lock(); defer { lock.unlock() }; reads.append((url, onMain)) }
    func statted(_ url: URL, onMain: Bool) { lock.lock(); defer { lock.unlock() }; stats.append((url, onMain)) }
    func resetIO() { lock.lock(); defer { lock.unlock() }; writes.removeAll(); reads.removeAll(); stats.removeAll() }
    var encodedOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return encodings }
    var writtenNames: [String] { lock.lock(); defer { lock.unlock() }; return writes.map { $0.0.lastPathComponent } }
    var blobReads: Int { lock.lock(); defer { lock.unlock() }; return reads.count }
    var readOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return reads.map { $0.1 } }
    var statOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return stats.map { $0.1 } }
    var statNames: [String] { lock.lock(); defer { lock.unlock() }; return stats.map { $0.0.lastPathComponent } }
    var blobWrites: Int { lock.lock(); defer { lock.unlock() }; return writes.filter { $0.0.pathExtension == "diff" }.count }
    var blobBytes: Int { lock.lock(); defer { lock.unlock() }; return writes.filter { $0.0.pathExtension == "diff" }.reduce(0) { $0 + $1.1 } }
    var stateWrites: Int { lock.lock(); defer { lock.unlock() }; return writes.filter { $0.0.lastPathComponent == "state.json" }.count }
    var failManifest: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fail }
        set { lock.lock(); defer { lock.unlock() }; fail = newValue }
    }
    var failBlob: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failRepair }
        set { lock.lock(); defer { lock.unlock() }; failRepair = newValue }
    }
    var failReadName: String? {
        get { lock.lock(); defer { lock.unlock() }; return unavailableReadName }
        set { lock.lock(); defer { lock.unlock() }; unavailableReadName = newValue }
    }
}
