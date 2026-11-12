import XCTest
@testable import TesseraArtifactsCore

final class ArtifactsPersistencePerformanceTests: XCTestCase {
    func testOpenMatchesChangesWithoutHashingBodies() {
        let tabs = (0..<64).map { change("t\($0)", path: "/\($0).swift", diff: String(repeating: "+x\n", count: 100)) }
        let state = ArtifactsState(tabs: tabs, selectedID: "t0")
        let file = ArtifactsDigest.measure { open(state, id: "file", target: .file(path: "/file.md")) }
        XCTAssertEqual(file.calls, 0, "opening a file must not digest any retained change")
        let newPath = ArtifactsDigest.measure { open(state, id: "new", target: .change(path: "/new.swift", diff: "+new", summary: "edit")) }
        XCTAssertEqual(newPath.calls, 0)
        let samePath = ArtifactsDigest.measure { open(state, id: "revision", target: .change(path: "/50.swift", diff: "+new", summary: "edit")) }
        XCTAssertEqual(samePath.calls, 0)
        var otherHost = state
        otherHost.tabs[50].hostID = "other"
        XCTAssertEqual(ArtifactsDigest.measure {
            open(otherHost, id: "revision", target: .change(path: "/50.swift", diff: "+new", summary: "edit"))
        }.calls, 0)
        XCTAssertEqual(ArtifactsDigest.measure {
            ArtifactsReducer.reduce(state, .close(tabID: "t50", nowMillis: 100))
        }.calls, 0)
    }

    func testReopeningTheLastOf64PinnedSamePathRevisionsComputesNoDigests() {
        let state = samePathRevisions()
        let last = state.tabs[63]
        let work = ArtifactsDigest.measure { open(state, id: "ignored", target: last.target) }
        XCTAssertEqual(work.value.state.tabs.map(\.id), state.tabs.map(\.id))
        XCTAssertEqual(work.value.focusedTabID, last.id)
        XCTAssertEqual(work.value.state.tabs.last?.viewedAt, 100)
        XCTAssertEqual(work.value.evictedTabIDs, [])
        XCTAssertEqual(work.calls, 0)
        XCTAssertEqual(work.bytes, 0)
    }

    func testDecodeAndEncodeSamePathRevisionsComputeNoIdentityDigests() throws {
        let state = samePathRevisions()
        let raw = try JSONEncoder().encode(state)
        let decoded = ArtifactsDigest.measure { ArtifactsPersistence.decode(raw) }
        XCTAssertEqual(decoded.value, state)
        XCTAssertEqual(decoded.calls, 0)
        XCTAssertEqual(decoded.bytes, 0)
        let encoded = ArtifactsDigest.measure { ArtifactsPersistence.encode(state) }
        XCTAssertEqual(encoded.calls, 0)
        XCTAssertEqual(encoded.bytes, 0)
        XCTAssertEqual(ArtifactsPersistence.decode(encoded.value), state)
    }

    func testChangeIdentityUsesExactBodyBytesAndIgnoresSummary() throws {
        let pairs: [(String, String, Bool)] = [
            ("", "", true),
            ("+same\n", "+same\n", true),
            ("+a\n", "+b\n", false),
            ("+a\n", "+aa\n", false),
            ("+\u{0}a\n", "+\u{0}b\n", false),
            ("+caf\u{e9}\n", "+cafe\u{301}\n", false),
            ("+\u{e9}e\u{301}\n", "+e\u{301}\u{e9}\n", false),
        ]
        for (a, b, equal) in pairs {
            let first = change("a", path: "/same.swift", diff: a)
            let samePath = ArtifactsTarget.change(path: "/./same.swift/", diff: b, summary: "renamed")
            let identity = ArtifactsDigest.measure { first.target.identity == samePath.identity }
            XCTAssertEqual(identity.value, equal)
            XCTAssertEqual(identity.calls, 0)
            let reopened = open(ArtifactsState(tabs: [first], selectedID: "a"), id: "b", target: samePath)
            XCTAssertEqual(reopened.state.tabs.map(\.id), equal ? ["a"] : ["a", "b"])
            XCTAssertEqual(reopened.focusedTabID, equal ? "a" : "b")
            var duplicate = change("b", path: "/same.swift", diff: b)
            duplicate.target = samePath
            let raw = try JSONEncoder().encode(ArtifactsState(tabs: [first, duplicate], selectedID: "a"))
            let decoded = ArtifactsDigest.measure { ArtifactsPersistence.decode(raw) }
            XCTAssertEqual(decoded.value.tabs.map(\.id), equal ? ["a"] : ["a", "b"])
            XCTAssertEqual(decoded.calls, 0)
            let differentPath = ArtifactsTarget.change(path: "/same.swift/../file", diff: b, summary: "edit")
            XCTAssertEqual(open(ArtifactsState(tabs: [first]), id: "different-path", target: differentPath).state.tabs.count, 2)
        }
    }

    func testTruncatedMarkersKeepSamePrefixRevisionsDistinctWithoutIdentityDigests() throws {
        let prefix = String(repeating: "+x\n", count: ArtifactsPersistence.maximumDiffBytes / 3 + 1)
        let first = ArtifactsPersistence.capped(.change(path: "/same.swift", diff: prefix + "+a\n", summary: "first"))
        let second = ArtifactsPersistence.capped(.change(path: "/same.swift", diff: prefix + "+b\n", summary: "second"))
        let state = open(ArtifactsState(), id: "a", target: first).state
        let revision = ArtifactsDigest.measure { open(state, id: "b", target: second) }
        XCTAssertEqual(revision.value.state.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(revision.calls, 0)
        let reopened = ArtifactsDigest.measure { open(revision.value.state, id: "ignored", target: first) }
        XCTAssertEqual(reopened.value.focusedTabID, "a")
        XCTAssertEqual(reopened.value.state.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(reopened.calls, 0)
        var raw = reopened.value.state
        var duplicate = raw.tabs[0]
        duplicate.id = "duplicate"
        raw.tabs.append(duplicate)
        let data = try JSONEncoder().encode(raw)
        let restored = ArtifactsDigest.measure { ArtifactsPersistence.decode(data) }
        XCTAssertEqual(restored.value, reopened.value.state)
        XCTAssertEqual(restored.calls, 0)
    }

    func testDecodeAndEncodeDoNotHashChangesAtDistinctPaths() throws {
        let state = ArtifactsState(tabs: (0..<16).map { change("t\($0)", path: "/\($0).swift") }, selectedID: "t0")
        let raw = try JSONEncoder().encode(state)
        let decoded = ArtifactsDigest.measure { ArtifactsPersistence.decode(raw) }
        XCTAssertEqual(decoded.value, state)
        XCTAssertEqual(decoded.calls, 0)
        let encoded = ArtifactsDigest.measure { ArtifactsPersistence.encode(state) }
        XCTAssertEqual(encoded.calls, 0, "encoding must apply bounds directly without decoding the result")
        XCTAssertEqual(ArtifactsPersistence.encode(ArtifactsPersistence.decode(encoded.value)), encoded.value)
    }

    func testUnmatchedObservationsReuseTheInputTabStorageWithoutHashing() {
        let state = ArtifactsState(tabs: (0..<64).map { change("t\($0)", path: "/\($0).swift") })
        let address = state.tabs.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        for action: ArtifactsAction in [
            .agentEditObserved(hostID: "h1", path: "/missing.swift", nowMillis: 1),
            .remoteStatObserved(tabID: "missing", remoteMTime: 1, size: 1, visible: true, nowMillis: 1),
        ] {
            let result = ArtifactsDigest.measure { ArtifactsReducer.reduce(state, action) }
            XCTAssertEqual(result.value.state, state)
            XCTAssertEqual(result.calls, 0)
            XCTAssertEqual(result.value.state.tabs.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }, address)
        }
    }

    func testOpeningBeyondFourMiBEvictsOnlyOldestUnprotectedChanges() {
        let diff = String(repeating: "x", count: 256 * 1024)
        var tabs = (0..<16).map { change("t\($0)", path: "/\($0).swift", diff: diff, viewed: Int64($0)) }
        tabs[0].pinned = true
        tabs.insert(ArtifactTab(id: "file", hostID: "h1", hostLabel: "dev", target: .file(path: "/a.md"),
                                title: "a", openedAt: -1, viewedAt: -1), at: 0)
        let result = open(ArtifactsState(tabs: tabs, selectedID: "t1"), id: "new", target: .change(path: "/new", diff: diff, summary: "edit"))
        XCTAssertEqual(result.evictedTabIDs, ["t1"])
        XCTAssertEqual(result.state.selectedID, "new")
        XCTAssertTrue(result.state.tabs.contains { $0.id == "file" })
        XCTAssertTrue(result.state.tabs.contains { $0.id == "t0" })
        XCTAssertEqual(retainedBytes(result.state), 4 * 1024 * 1024)
    }

    func testDecodeEnforcesTotalDiffBudgetAndProtectsSelectionAndPins() throws {
        let diff = String(repeating: "é", count: 128 * 1024)
        var tabs = (0..<18).map { change("t\($0)", path: "/\($0).swift", diff: diff, viewed: Int64($0)) }
        tabs[0].pinned = true
        let restored = ArtifactsPersistence.decode(try JSONEncoder().encode(ArtifactsState(tabs: tabs, selectedID: "t1")))
        XCTAssertEqual(restored.tabs.map(\.id), ["t0", "t1"] + (4..<18).map { "t\($0)" })
        XCTAssertEqual(retainedBytes(restored), 4 * 1024 * 1024)
    }

    func testSplitKeepsBodiesOutOfTheManifestAndLegacyStatesMigrate() throws {
        let diff = String(repeating: "+café\n", count: 20_000)
        let state = ArtifactsState(tabs: [change("a", path: "/a", diff: diff), change("b", path: "/b", diff: diff)], selectedID: "b")
        let legacy = ArtifactsPersistence.encode(state)
        XCTAssertEqual(ArtifactsPersistence.decode(legacy), state)
        let files = ArtifactsPersistence.split(ArtifactsPersistence.decode(legacy))
        XCTAssertEqual(files.blobs, [ArtifactsDigest.hex(diff): diff])
        XCTAssertLessThan(files.stateJSON.utf8.count, 1024)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(files.stateJSON.utf8)) as? [String: Any])
        for tab in try XCTUnwrap(object["tabs"] as? [[String: Any]]) {
            let target = try XCTUnwrap(tab["target"] as? [String: Any])
            XCTAssertNil(target["diff"])
            XCTAssertEqual(target["diffDigest"] as? String, ArtifactsDigest.hex(diff))
        }
        XCTAssertEqual(ArtifactsPersistence.blobDigests(Data(files.stateJSON.utf8)), Array(files.blobs.keys))
        XCTAssertEqual(ArtifactsPersistence.join(Data(files.stateJSON.utf8), blobs: files.blobs), state)
        XCTAssertEqual(ArtifactsPersistence.encode(ArtifactsPersistence.join(Data(files.stateJSON.utf8), blobs: files.blobs)), legacy)
    }

    func testMissingTamperedAndOversizedBlobsDropOnlyTheirTabs() throws {
        let a = change("a", path: "/a", diff: "+a\n")
        let b = change("b", path: "/b", diff: "+b\n")
        let file = ArtifactTab(id: "file", hostID: "h1", hostLabel: "dev", target: .file(path: "/a.md"),
                               title: "file", openedAt: 1, viewedAt: 1)
        let files = ArtifactsPersistence.split(ArtifactsState(tabs: [a, b, file], selectedID: "a"))
        let digest = ArtifactsDigest.hex("+a\n")
        for replacement: String? in [nil, "+tampered\n", String(repeating: "x", count: ArtifactsPersistence.maximumDiffBytes + 1)] {
            var blobs = files.blobs
            blobs[digest] = replacement
            let state = ArtifactsPersistence.join(Data(files.stateJSON.utf8), blobs: blobs)
            XCTAssertEqual(state.tabs, [b, file])
            XCTAssertNil(state.selectedID)
        }
        // Reject an over-cap body even when the claimed digest is correct.
        let oversized = String(repeating: "x", count: ArtifactsPersistence.maximumDiffBytes + 1)
        let largeDigest = ArtifactsDigest.hex(oversized)
        let manifest = files.stateJSON.replacingOccurrences(of: digest, with: largeDigest)
        var blobs = files.blobs
        blobs[largeDigest] = oversized
        XCTAssertEqual(ArtifactsPersistence.join(Data(manifest.utf8), blobs: blobs).tabs, [b, file])
    }

    func testJoinVerifiesASharedBlobOnlyOnceIncludingTamperedBodies() throws {
        let state = ArtifactsState(tabs: (0..<16).map { change("t\($0)", path: "/\($0)", diff: "+shared\n") })
        let files = ArtifactsPersistence.split(state)
        let data = Data(files.stateJSON.utf8)
        let valid = ArtifactsDigest.measure { ArtifactsPersistence.join(data, blobs: files.blobs) }
        XCTAssertEqual(valid.value, state)
        XCTAssertEqual(valid.calls, 1)
        let digest = try XCTUnwrap(files.blobs.keys.first)
        let invalid = ArtifactsDigest.measure { ArtifactsPersistence.join(data, blobs: [digest: "+tampered\n"]) }
        XCTAssertTrue(invalid.value.tabs.isEmpty)
        XCTAssertEqual(invalid.calls, 1)
    }

    func testBlobReferencesRecoverAroundMalformedTabsAndRejectUnsafeNames() throws {
        let files = ArtifactsPersistence.split(ArtifactsState(tabs: [change("a", path: "/a")]))
        let digest = try XCTUnwrap(files.blobs.keys.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(files.stateJSON.utf8)) as? [String: Any])
        var tabs = try XCTUnwrap(object["tabs"] as? [Any])
        tabs.insert(NSNull(), at: 0)
        tabs.append(["target": ["type": "change", "diffDigest": "../../state.json"]])
        tabs.append(["target": ["type": "change", "diffDigest": digest.uppercased()]])
        object["tabs"] = tabs
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(ArtifactsPersistence.blobDigests(data), [digest])
        XCTAssertEqual(ArtifactsPersistence.join(data, blobs: files.blobs).tabs.map(\.id), ["a"])
        XCTAssertEqual(ArtifactsPersistence.blobDigests(Data(#"{"version":2,"tabs":[]}"#.utf8)), [])
    }

    func testDecodeDeduplicatesIdenticalSamePathBodiesWithoutHashing() throws {
        let tabs = [change("a", path: "/a"), change("b", path: "/a"), change("c", path: "/a")]
        let data = try JSONEncoder().encode(ArtifactsState(tabs: tabs))
        let work = ArtifactsDigest.measure { ArtifactsPersistence.decode(data) }
        XCTAssertEqual(work.value.tabs.map(\.id), ["a"])
        XCTAssertEqual(work.calls, 0)
    }

    func testManifestRoundTripPreservesAllMetadataAndCanonicalInlineBytes() throws {
        var change = change("change", path: "/café.swift", diff: "\u{0}+📄\n")
        change.sessionHint = "session"
        change.cache = .init(fetchedAt: 9_007_199_254_740_993, remoteMTime: -1, size: 42, isStale: true)
        change.pinned = true
        change.unseenChange = true
        change.agentEditedAt = 100
        let page = ArtifactTab(id: "page", hostID: "h1", hostLabel: "dev", target: .page(scheme: "https", port: 8443, path: "/x?q#f"),
                               title: "page", openedAt: -1, viewedAt: 99)
        let state = ArtifactsState(tabs: [change, page], selectedID: "change", filter: .changes, tabCap: 4)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(ArtifactsPersistence.encode(state), try encoder.encode(state))
        let files = ArtifactsPersistence.split(state)
        XCTAssertEqual(ArtifactsPersistence.join(Data(files.stateJSON.utf8), blobs: files.blobs), state)
    }

    func testCorruptManifestCannotRequestUnboundedBlobReadsAndKeepsTheSelection() throws {
        let tabs = (0..<100).map { change("t\($0)", path: "/\($0)", viewed: Int64($0)) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ArtifactsState(tabs: tabs, selectedID: "t0"))) as? [String: Any])
        var raw = try XCTUnwrap(object["tabs"] as? [[String: Any]])
        let digests = (0..<100).map { ArtifactsDigest.hex(String($0)) }
        for i in raw.indices {
            var target = try XCTUnwrap(raw[i]["target"] as? [String: Any])
            target["diff"] = nil
            target["diffDigest"] = digests[i]
            raw[i]["target"] = target
        }
        object["tabs"] = raw
        let references = ArtifactsPersistence.blobDigests(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(references.count, ArtifactsPersistence.maximumPersistedTabs)
        XCTAssertTrue(references.contains(digests[0]))
    }

    func testDiffBudgetKeepsProtectedChangesAndReportsTabCapBeforeDiffEvictions() {
        XCTAssertEqual(ArtifactsState.maximumRetainedDiffBytes, 4 * 1024 * 1024)
        let diff = String(repeating: "x", count: ArtifactsPersistence.maximumDiffBytes)
        var tabs = (0..<17).map { change("t\($0)", path: "/\($0)", diff: diff, viewed: Int64($0)) }
        for i in tabs.indices { tabs[i].pinned = true }
        let protected = ArtifactsState(tabs: tabs, selectedID: "t1")
        XCTAssertEqual(ArtifactsPersistence.decode(ArtifactsPersistence.encode(protected)), protected)
        tabs[0].pinned = false
        let state = ArtifactsState(tabs: tabs, selectedID: "t1", tabCap: 17)
        let result = open(state, id: "file", target: .file(path: "/file.md"))
        XCTAssertEqual(result.evictedTabIDs, ["t0"])
        XCTAssertEqual(retainedBytes(result.state), ArtifactsState.maximumRetainedDiffBytes)
        XCTAssertEqual(result.state.selectedID, "file")
    }

    private func change(_ id: String, path: String, diff: String = "+x\n", viewed: Int64 = 1) -> ArtifactTab {
        .init(id: id, hostID: "h1", hostLabel: "dev", target: .change(path: path, diff: diff, summary: "edit"),
              title: id, openedAt: viewed, viewedAt: viewed)
    }

    private func samePathRevisions() -> ArtifactsState {
        let body = String(repeating: "x", count: ArtifactsPersistence.maximumDiffBytes - 2)
        let tabs = (0..<64).map { i -> ArtifactTab in
            var tab = change("t\(i)", path: "/same.swift", diff: String(format: "%02d", i) + body, viewed: Int64(i))
            tab.pinned = true
            return tab
        }
        return ArtifactsState(tabs: tabs, selectedID: "t0")
    }

    private func open(_ state: ArtifactsState, id: String, target: ArtifactsTarget) -> ArtifactsReduction {
        ArtifactsReducer.reduce(state, .open(.init(id: id, hostID: "h1", hostLabel: "dev", target: target, title: id), nowMillis: 100))
    }

    private func retainedBytes(_ state: ArtifactsState) -> Int {
        state.tabs.reduce(0) { total, tab in
            if case let .change(_, diff, _) = tab.target { return total + diff.utf8.count }
            return total
        }
    }
}
