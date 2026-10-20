import Foundation
import XCTest
@testable import TmuxControlCore

/// The geometry evidence an own-stamp read depends on (plan §C.1), ported
/// from Android `TmuxAuthorityPresentationTest`'s geometry cases and the
/// window rules both platforms' grid-authority tests pin.
final class AuthorityGeometryEvidenceTests: XCTestCase {
    private typealias Geometry = TmuxGridAuthorityLifecycleReducer.QueryGeometry
    private typealias Evidence = TmuxAuthorityGeometryEvidence

    private func size(_ columns: Int, _ rows: Int) -> TmuxGridSize { .init(columns: columns, rows: rows) }

    /// An authoritative, hydrated active window `@1`.
    private func evidence(
        window: TmuxGridSize?,
        local: TmuxGridSize?,
        owned: [TmuxGridSize] = [],
        latest: Bool? = nil,
        windowID: Int = 1
    ) -> Evidence {
        Evidence(
            windowListHydrated: true,
            activeWindow: .init(id: windowID, size: window, authoritative: true),
            localSize: local,
            policy: latest.map { .init(windowID: windowID, isLatest: $0) },
            owned: TmuxOwnedSizeHistory(owned)
        )
    }

    func test_geometryEvidenceComparesTheWindowWithLocalAndRecentlyOwnedSizes() {
        let local = size(80, 24)
        let earlier = size(203, 30)
        let newest = size(100, 30)
        let owned = [earlier, newest]
        let foreign = size(90, 40)
        for latest in [true, false, nil] as [Bool?] {
            for final in [true, false] {
                XCTAssertEqual(evidence(window: local, local: local, owned: owned, latest: latest).classify(final: final), .atLocalSize)
                // Any recently owned grid, not only the newest.
                for window in owned {
                    XCTAssertEqual(
                        evidence(window: window, local: local, owned: owned, latest: latest).classify(final: final),
                        .atLastOwnedSize
                    )
                }
            }
        }
        XCTAssertEqual(evidence(window: foreign, local: local, owned: owned, latest: true).classify(final: false), .foreignSize)
        XCTAssertEqual(evidence(window: newest, local: local, latest: true).classify(final: false), .foreignSize)
        // Without a layout or a viewport there is nothing to judge yet.
        XCTAssertNil(evidence(window: nil, local: local, owned: owned, latest: true).classify(final: false))
        XCTAssertNil(evidence(window: local, local: nil, owned: owned, latest: true).classify(final: false))
        XCTAssertEqual(evidence(window: nil, local: local, owned: owned, latest: true).classify(final: true), .unknown)
        XCTAssertEqual(evidence(window: local, local: nil, owned: owned).classify(final: true), .unknown)
    }

    func test_theOwnedHistoryKeepsTheNewestEightDistinctSizesNewestLast() {
        let sizes = (1...10).map { size(100 + $0, 30) }
        var history = TmuxOwnedSizeHistory()
        for entry in sizes { history.record(entry) }
        XCTAssertEqual(history.sizes, Array(sizes.suffix(TmuxOwnedSizeHistory.limit)))
        XCTAssertEqual(history.newest, sizes.last)
        // Recording an entry again moves it to the newest slot without growing.
        var again = history
        again.record(sizes[4])
        XCTAssertEqual(again.sizes, history.sizes.filter { $0 != sizes[4] } + [sizes[4]])
        XCTAssertEqual(again.sizes.count, TmuxOwnedSizeHistory.limit)
        // Recording the newest again changes nothing.
        var same = again
        same.record(sizes[4])
        XCTAssertEqual(same, again)
        same.removeAll()
        XCTAssertTrue(same.sizes.isEmpty)
    }

    func test_aMismatchCountsAsForeignOnlyUnderTheLatestPolicy() {
        let local = size(80, 24)
        let other = size(120, 40)
        // smallest/largest/manual: tmux sized the window by its own rule.
        XCTAssertEqual(evidence(window: other, local: local, latest: false).classify(final: false), .atLocalSize)
        XCTAssertEqual(evidence(window: other, local: local, latest: true).classify(final: false), .foreignSize)
        // Policy not probed yet: hold, and at the bound unknown (M5).
        XCTAssertNil(evidence(window: other, local: local).classify(final: false))
        XCTAssertEqual(evidence(window: other, local: local).classify(final: true), .unknown)
        // A known policy decides at the bound exactly as before it.
        XCTAssertEqual(evidence(window: other, local: local, latest: true).classify(final: true), .foreignSize)
        XCTAssertEqual(evidence(window: other, local: local, latest: false).classify(final: true), .atLocalSize)
    }

    /// The Android gate's W2: a reattach's `list-windows` lands before its
    /// active-window query, and the model's provisional "active" window
    /// (the first one listed) said nothing about what this device renders.
    func test_onlyTheWindowTmuxNamesActiveOnAHydratedListIsJudged() {
        let local = size(203, 30)
        var provisional = evidence(window: size(100, 30), local: local, latest: true)
        provisional.activeWindow?.authoritative = false
        XCTAssertNil(provisional.judgedWindow)
        XCTAssertNil(provisional.classify(final: false), "hold for the authoritative window")
        XCTAssertEqual(provisional.classify(final: true), .unknown)

        var hydrating = evidence(window: size(100, 30), local: local, latest: true)
        hydrating.windowListHydrated = false
        XCTAssertNil(hydrating.classify(final: false))

        let named = evidence(window: size(100, 30), local: local, latest: true)
        XCTAssertEqual(named.classify(final: false), .foreignSize)
    }

    func test_aPolicyCountsOnlyForTheWindowItWasProbedFor() {
        var evidence = evidence(window: size(120, 40), local: size(80, 24), windowID: 2)
        evidence.policy = .init(windowID: 1, isLatest: true)
        XCTAssertNil(evidence.policy(for: 2))
        XCTAssertNil(evidence.classify(final: false))
        evidence.policy = .init(windowID: 2, isLatest: true)
        XCTAssertEqual(evidence.classify(final: false), .foreignSize)
    }

    func test_policyRepliesParseTheFirstNonEmptyLine() {
        XCTAssertTrue(Evidence.WindowSizePolicy(windowID: 1, rawReply: "").isLatest, "tmux's default")
        XCTAssertTrue(Evidence.WindowSizePolicy(windowID: 1, rawReply: "\n  latest \n").isLatest)
        XCTAssertFalse(Evidence.WindowSizePolicy(windowID: 1, rawReply: "smallest").isLatest)
        XCTAssertFalse(Evidence.WindowSizePolicy(windowID: 1, rawReply: "\nmanual\nlatest").isLatest)
    }

    func test_judgedWindowMatchesLocalSizeNeedsBoth() {
        XCTAssertTrue(evidence(window: size(80, 24), local: size(80, 24)).judgedWindowMatchesLocalSize)
        XCTAssertFalse(evidence(window: size(80, 30), local: size(80, 24)).judgedWindowMatchesLocalSize)
        XCTAssertFalse(evidence(window: nil, local: size(80, 24)).judgedWindowMatchesLocalSize)
        XCTAssertFalse(evidence(window: size(80, 24), local: nil).judgedWindowMatchesLocalSize)
    }
}
