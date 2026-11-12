import XCTest
@testable import TesseraArtifactsCore

/// What duplicate tabs need beyond the reducer's own new-tab and navigate
/// rules (TesseraArtifactsCoreTests): they survive a save, a tab showing a
/// file another tab holds starts from that copy's metadata, and a navigated
/// tab keeps its place.
final class ArtifactsBrowserTabsTests: XCTestCase {
    func testDuplicateTabsSurviveASaveWithTheirSelectionAndPins() throws {
        var state = open("root", .page(scheme: "http", port: 8001, path: "/"), now: 1)
        state = reduce(state, .open(request("laptop", .page(scheme: "http", port: 8001, path: "/laptop.html"), newTab: true),
                                    nowMillis: 2)).state
        state = reduce(state, .open(request("twin", .page(scheme: "http", port: 8001, path: "/laptop.html"), newTab: true),
                                    nowMillis: 3)).state
        state = open("doc", .file(path: "/a.md"), now: 4, state: state)
        state = reduce(state, .open(request("doc2", .file(path: "/a.md"), newTab: true), nowMillis: 5)).state
        state = reduce(state, .pin(tabID: "doc", pinned: true, nowMillis: 6)).state
        state = reduce(state, .select(tabID: "twin", nowMillis: 7)).state

        let restored = ArtifactsPersistence.decode(ArtifactsPersistence.encode(state))
        XCTAssertEqual(restored.tabs.map(\.id), ["root", "laptop", "twin", "doc", "doc2"])
        XCTAssertEqual(restored.selectedID, "twin")
        XCTAssertEqual(restored.tabs.filter(\.pinned).map(\.id), ["doc"])
        XCTAssertEqual(restored, state)
    }

    func testAChangeSnapshotIsStillKeptOnceThroughASave() throws {
        let edit = ArtifactTab(id: "a", hostID: "h1", hostLabel: "dev", target: .change(path: "/a.swift", diff: "+a", summary: "s"),
                               title: "a.swift", origin: "agent", openedAt: 1, viewedAt: 1)
        var copy = edit
        copy.id = "b"
        let raw = try JSONEncoder().encode(ArtifactsState(tabs: [edit, copy], selectedID: "a"))
        XCTAssertEqual(ArtifactsPersistence.decode(raw).tabs.map(\.id), ["a"])
    }

    func testATabComingToAFileAnotherTabHoldsStartsFromItsCachedCopy() {
        var state = open("doc", .file(path: "/a.md"), now: 1)
        state = reduce(state, .fetched(tabID: "doc", cache: .init(fetchedAt: 2, remoteMTime: 20, size: 10), nowMillis: 2)).state
        let twin = reduce(state, .open(request("twin", .file(path: "/a.md"), newTab: true), nowMillis: 3)).state
        XCTAssertEqual(twin.tabs[1].cache, .init(fetchedAt: 2, remoteMTime: 20, size: 10),
                       "the copy's baseline, so a host edit still marks it stale")
        let moved = reduce(twin, .remoteStatObserved(tabID: "twin", remoteMTime: 30, size: 10, visible: true, nowMillis: 4)).state
        XCTAssertEqual(moved.tabs[1].cache?.isStale, true)

        state = open("other", .file(path: "/b.md"), now: 5, state: state)
        let navigated = reduce(state, .navigate(tabID: "other", target: .file(path: "/a.md"), title: "a.md", nowMillis: 6)).state
        XCTAssertEqual(navigated.tabs[1].cache?.size, 10)
        XCTAssertNil(reduce(state, .open(request("elsewhere", .file(path: "/a.md"), host: "h2", newTab: true), nowMillis: 7))
            .state.tabs.last?.cache, "another host's file is another file")
        XCTAssertNil(reduce(state, .navigate(tabID: "other", target: .file(path: "/c.md"), title: "c.md", nowMillis: 8))
            .state.tabs[1].cache)
    }

    func testANavigatedTabKeepsItsPlaceItsPinAndItsHost() {
        var state = open("doc", .file(path: "/notes.md"), now: 1)
        state = open("page", .page(scheme: "http", port: 8001, path: "/"), now: 2, state: state)
        state = reduce(state, .pin(tabID: "doc", pinned: true, nowMillis: 3)).state
        let moved = reduce(state, .navigate(tabID: "doc", target: .page(scheme: "https", port: 8443, path: "/"), title: "x",
                                            nowMillis: 4)).state
        XCTAssertEqual(moved.tabs.map(\.id), ["doc", "page"])
        XCTAssertTrue(moved.tabs[0].pinned)
        XCTAssertEqual(moved.tabs[0].hostID, "h1")
        XCTAssertEqual(moved.tabs[0].openedAt, 1)
        XCTAssertEqual(moved.tabs[0].kind, .pages, "a document's tab can go to a page, as a browser's can")
        XCTAssertTrue(ArtifactsReducer.canNavigateInPlace(moved.tabs[0]))
        let edit = open("edit", .change(path: "/a.swift", diff: "+a", summary: "edit"), now: 5)
        XCTAssertFalse(ArtifactsReducer.canNavigateInPlace(edit.tabs[0]))
    }

    func testNavigateCarriesItsTargetAndTitleOnTheWire() throws {
        let json = Data(#"{"type":"navigate","nowMillis":3,"tabID":"t","target":{"type":"file","path":"/a"},"title":"a"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ArtifactsAction.self, from: json),
                       .navigate(tabID: "t", target: .file(path: "/a"), title: "a", nowMillis: 3))
        let missingTarget = Data(#"{"type":"navigate","nowMillis":3,"tabID":"t","title":"a"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ArtifactsAction.self, from: missingTarget))
    }

    private func request(_ id: String, _ target: ArtifactsTarget, host: String = "h1", newTab: Bool = false) -> ArtifactsOpenRequest {
        .init(id: id, hostID: host, hostLabel: "dev", target: target, title: target.path, newTab: newTab)
    }

    private func reduce(_ state: ArtifactsState, _ action: ArtifactsAction) -> ArtifactsReduction {
        ArtifactsReducer.reduce(state, action)
    }

    private func open(_ id: String, _ target: ArtifactsTarget, now: Int64, state: ArtifactsState = .init()) -> ArtifactsState {
        reduce(state, .open(request(id, target), nowMillis: now)).state
    }
}
