import XCTest
@testable import TmuxControlCore

final class RuntimeAuthorityProjectionTests: XCTestCase {
    private func stamp(_ raw: String, session: Int = 1) -> [UInt8] {
        Array("%subscription-changed tessera-authority $\(session) @1 0 %10 : \(raw)\n".utf8)
    }

    func testProjectionMovesRevisionOnlyOnChangeAndRefillsSnapshotMemo() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array("%output %10 ready\n".utf8))
        let start = engine.revision
        XCTAssertFalse(engine.projectAuthority(.unknown))
        XCTAssertEqual(engine.revision, start)
        let peer = TmuxGridAuthoritySnapshot.peer(deviceID: "ipad", displayName: "iPad", generation: 7)
        for authority in [peer, .mine(generation: 8), .mine(generation: 9), .unknown] {
            let revision = engine.revision
            XCTAssertTrue(engine.projectAuthority(authority))
            XCTAssertEqual(engine.revision, revision + 1)
            XCTAssertEqual(engine.snapshot.authority, authority)
            XCTAssertTrue(engine.servesSnapshotFromMemo)
            XCTAssertEqual(engine.snapshot, engine.buildSnapshot())
            let snapshot = engine.snapshot
            XCTAssertFalse(engine.projectAuthority(authority))
            XCTAssertEqual(engine.snapshot, snapshot)
            XCTAssertEqual(engine.revision, snapshot.revision)
        }
    }

    func testResetLeavesAuthorityAsTheAdaptersProjection() {
        for keep in [false, true] {
            for authority in [TmuxGridAuthoritySnapshot.mine(generation: 3), .peer(deviceID: "-", displayName: "another", generation: 0)] {
                var engine = TmuxRuntimeEngine()
                engine.projectAuthority(authority)
                engine.reset(keepingSnapshot: keep)
                XCTAssertEqual(engine.snapshot.authority, authority)
                XCTAssertEqual(engine.snapshot, engine.buildSnapshot())
            }
        }
    }

    func testAuthorityStampEdgesKeepArrivalOrderWithoutParsingOrChangingAuthority() {
        var engine = TmuxRuntimeEngine()
        engine.projectAuthority(.mine(generation: 3))
        let revision = engine.revision
        let batch = engine.feed(stamp("v1 ipad 7 iPad") + stamp("  v1 ipad 7 iPad  ") + stamp("broken") + stamp("") + stamp("v1 android 8 Phone"))
        XCTAssertEqual(batch.authorityStamps, ["v1 ipad 7 iPad", "broken", "", "v1 android 8 Phone"])
        XCTAssertEqual(batch.snapshot.authority, .mine(generation: 3))
        XCTAssertEqual(engine.revision, revision)
        XCTAssertEqual(engine.feed([] as [UInt8]).authorityStamps, [])
    }

    /// A read's per-pane fan-out collapses; a later read's value is the
    /// session's to dedupe, since only the session knows when it re-armed.
    func testRawDedupeCollapsesOnlyConsecutiveValuesWithinARead() {
        var engine = TmuxRuntimeEngine()
        XCTAssertEqual(engine.feed(stamp("broken") + stamp(" broken ")).authorityStamps, ["broken"])
        XCTAssertEqual(engine.feed(stamp("broken")).authorityStamps, ["broken"])
        XCTAssertEqual(engine.feed(stamp("other") + stamp("broken") + stamp("broken")).authorityStamps, ["other", "broken"])
        engine.reset(keepingSnapshot: true)
        XCTAssertEqual(engine.feed(stamp("broken")).authorityStamps, ["broken"])
    }

    /// Each kept edge is tagged on the step that carried it, so a consumer
    /// can reduce it at its place in the read; a collapsed repeat and a
    /// foreign session's edge tag nothing.
    func testEachKeptEdgeIsTaggedOnItsOwnStep() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array("%session-changed $1 work\n".utf8))
        let batch = engine.feed(
            stamp("a") + Array("%output %10 x\n".utf8) + stamp("a") + stamp("b", session: 2) + stamp("b")
        )
        XCTAssertEqual(batch.authorityStamps, ["a", "b"])
        XCTAssertEqual(batch.orderedSteps.map(\.authorityStamp), ["a", nil, nil, nil, "b"])
    }

    /// The Android session request is bounded; a value no stamp can need
    /// is replaced by one that classifies identically.
    func testOversizedValuesBecomeTheirCanonicalStampOrNothing() throws {
        let longest = TmuxGridAuthorityStamp(
            identity: .init(id: String(repeating: "d", count: TmuxGridAuthorityStamp.maximumDeviceIDCharacters),
                            displayName: String(repeating: "n", count: TmuxGridAuthorityStamp.maximumDisplayNameCharacters)),
            generation: TmuxGridAuthorityStamp.maximumGeneration
        ).wireValue
        XCTAssertEqual(longest.utf8.count, TmuxGridAuthorityStamp.maximumWireBytes)
        let longName = "v1 ipad 7 " + String(repeating: "N", count: 400)
        let padded = "v1 ipad " + String(repeating: "0", count: 300) + "7 iPad"
        var engine = TmuxRuntimeEngine()
        let batch = engine.feed(stamp(longest) + stamp(longName) + stamp(padded) + stamp(String(repeating: "x", count: 300)))
        XCTAssertEqual(batch.authorityStamps, [
            longest, "v1 ipad 7 " + String(repeating: "N", count: 64), "v1 ipad 7 iPad", "",
        ])
        for (raw, bounded) in zip([longest, longName, padded], batch.authorityStamps) {
            XCTAssertEqual(TmuxGridAuthoritySnapshot.classify(rawValue: bounded, localDeviceID: "self"),
                           TmuxGridAuthoritySnapshot.classify(rawValue: raw, localDeviceID: "self"))
        }
        XCTAssertNil(TmuxGridAuthorityStamp.parse(String(repeating: "x", count: 300)))
    }

    /// The session alone owns dedupe across reads: once it re-arms (here an
    /// identity change), the next read's unchanged stamp still reaches it.
    func testTheSessionSeesAnUnchangedStampAfterItRearms() {
        var engine = TmuxRuntimeEngine()
        var session = TmuxGridAuthoritySession(localDeviceID: "phone")
        func deliver(_ raw: String) {
            for edge in engine.feed(stamp(raw)).authorityStamps { session.reduce(.stampObserved(raw: edge), now: 0) }
        }
        deliver("v1 phone 3 Phone")
        XCTAssertEqual(session.reducer.authority, .mine(generation: 3))
        session.localDeviceID = "tablet"
        session.reduce(.identityChanged, now: 0)
        XCTAssertEqual(session.reducer.authority, .unknown)
        deliver("v1 phone 3 Phone")
        XCTAssertEqual(session.reducer.authority, .peer(deviceID: "phone", displayName: "Phone", generation: 3))
    }

    func testForeignSessionStampsAreFilteredBeforeMemoizing() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array("%session-changed $1 work\n".utf8))
        XCTAssertEqual(engine.feed(stamp("v1 ipad 7 iPad", session: 2)).authorityStamps, [])
        XCTAssertEqual(engine.feed(stamp("v1 ipad 7 iPad")).authorityStamps, ["v1 ipad 7 iPad"])
        // Before session resolution the existing filter fails open.
        var unresolved = TmuxRuntimeEngine()
        XCTAssertEqual(unresolved.feed(stamp("broken", session: 2)).authorityStamps, ["broken"])
    }

    func testOneThousandOutputOnlyFeedsReportNoAuthorityEdgesOrRevisionChange() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(stamp("v1 ipad 7 iPad"))
        let revision = engine.revision
        let output = Array("%output %10 bytes\n".utf8)
        for _ in 0..<1_000 {
            XCTAssertEqual(engine.feed(output).authorityStamps, [])
        }
        XCTAssertEqual(engine.revision, revision)
    }
}
