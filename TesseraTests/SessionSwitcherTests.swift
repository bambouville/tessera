import XCTest
@testable import Tessera

final class SessionSwitcherTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    func test_emptyOrder_isNil() {
        XCTAssertNil(SessionSwitcher.step(order: [], from: a, direction: .next))
        XCTAssertNil(SessionSwitcher.step(order: [], from: nil, direction: .previous))
    }

    func test_singleSession_alreadyCurrent_isNil() {
        XCTAssertNil(SessionSwitcher.step(order: [a], from: a, direction: .next))
        XCTAssertNil(SessionSwitcher.step(order: [a], from: a, direction: .previous))
    }

    func test_currentNil_nextLandsOnFirst_previousOnLast() {
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: nil, direction: .next), a)
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: nil, direction: .previous), c)
    }

    func test_currentNotInOrder_nextLandsOnFirst_previousOnLast() {
        let stale = UUID()
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: stale, direction: .next), a)
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: stale, direction: .previous), c)
    }

    func test_next_movesToFollowingNeighbour() {
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: a, direction: .next), b)
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: b, direction: .next), c)
    }

    func test_previous_movesToPrecedingNeighbour() {
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: c, direction: .previous), b)
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: b, direction: .previous), a)
    }

    func test_next_wrapsFromLastToFirst() {
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: c, direction: .next), a)
    }

    func test_previous_wrapsFromFirstToLast() {
        XCTAssertEqual(SessionSwitcher.step(order: [a, b, c], from: a, direction: .previous), c)
    }

    func test_twoSessions_bothDirectionsFlipToOther() {
        XCTAssertEqual(SessionSwitcher.step(order: [a, b], from: a, direction: .next), b)
        XCTAssertEqual(SessionSwitcher.step(order: [a, b], from: a, direction: .previous), b)
        XCTAssertEqual(SessionSwitcher.step(order: [a, b], from: b, direction: .next), a)
        XCTAssertEqual(SessionSwitcher.step(order: [a, b], from: b, direction: .previous), a)
    }
}
