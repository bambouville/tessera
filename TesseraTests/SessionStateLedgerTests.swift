import XCTest
@testable import Tessera

/// Covers which session-state deliveries ContentView acts on. Every body
/// evaluation rebuilds the merged publisher and each live session's
/// `@Published` state replays to it; only a delivery that changes what the
/// handler last saw may persist, publish share targets or restart Handoff.
@MainActor
final class SessionStateLedgerTests: XCTestCase {
    private final class Source {}

    func test_firstDeliveryIsAdmitted() {
        let ledger = SessionStateLedger()
        let source = Source()

        XCTAssertTrue(ledger.admit(liveSessionID: UUID(), state: .connecting, source: source))
    }

    /// The replay this ledger exists for: same session object, same state.
    func test_replayOfTheHandledStateIsRejected() {
        let ledger = SessionStateLedger()
        let id = UUID()
        let source = Source()

        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .connected, source: source))
        for _ in 0..<5 {
            XCTAssertFalse(ledger.admit(liveSessionID: id, state: .connected, source: source))
        }
    }

    func test_aChangedStateIsAdmitted_includingAReturnToAnEarlierOne() {
        let ledger = SessionStateLedger()
        let id = UUID()
        let source = Source()

        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .connected, source: source))
        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .disconnected, source: source))
        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .connected, source: source))
    }

    /// `.failed` carries its reason; a different reason is a different state.
    func test_aDifferentFailureReasonIsAdmitted() {
        let ledger = SessionStateLedger()
        let id = UUID()
        let source = Source()

        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .failed("timed out"), source: source))
        XCTAssertFalse(ledger.admit(liveSessionID: id, state: .failed("timed out"), source: source))
        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .failed("refused"), source: source))
    }

    /// A restore can reuse a snapshot's live session id for a new transport
    /// object; its first delivery must run even when the state matches.
    func test_aNewSessionObjectUnderTheSameIDIsAdmitted() {
        let ledger = SessionStateLedger()
        let id = UUID()
        let old = Source()
        let new = Source()

        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .connected, source: old))
        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .connected, source: new))
        XCTAssertFalse(ledger.admit(liveSessionID: id, state: .connected, source: new))
    }

    /// The ledger holds its sources weakly: a released session leaves no
    /// entry that could match, so whatever reuses the id is admitted.
    func test_aReleasedSourceNoLongerMatches() {
        let ledger = SessionStateLedger()
        let id = UUID()
        weak var released: Source?
        autoreleasepool {
            let source = Source()
            released = source
            XCTAssertTrue(ledger.admit(liveSessionID: id, state: .connected, source: source))
        }
        XCTAssertNil(released, "the ledger must not keep a session object alive")

        XCTAssertTrue(ledger.admit(liveSessionID: id, state: .connected, source: Source()))
    }

    func test_sessionsAreTrackedIndependently() {
        let ledger = SessionStateLedger()
        let a = UUID(), b = UUID()
        let sourceA = Source(), sourceB = Source()

        XCTAssertTrue(ledger.admit(liveSessionID: a, state: .connected, source: sourceA))
        XCTAssertTrue(ledger.admit(liveSessionID: b, state: .connected, source: sourceB))
        XCTAssertFalse(ledger.admit(liveSessionID: a, state: .connected, source: sourceA))
        XCTAssertFalse(ledger.admit(liveSessionID: b, state: .connected, source: sourceB))
    }

    /// Closing a session drops its entry, so reopening under the same id and
    /// object starts over rather than being mistaken for a replay.
    func test_retainForgetsClosedSessions() {
        let ledger = SessionStateLedger()
        let kept = UUID(), closed = UUID()
        let keptSource = Source(), closedSource = Source()
        XCTAssertTrue(ledger.admit(liveSessionID: kept, state: .connected, source: keptSource))
        XCTAssertTrue(ledger.admit(liveSessionID: closed, state: .connected, source: closedSource))

        ledger.retain([kept])

        XCTAssertFalse(ledger.admit(liveSessionID: kept, state: .connected, source: keptSource))
        XCTAssertTrue(ledger.admit(liveSessionID: closed, state: .connected, source: closedSource))
    }
}
