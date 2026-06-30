import XCTest
@testable import Tessera

final class ModifierStateTests: XCTestCase {
    func test_initialArmedIsNone() {
        let state = ModifierState()

        XCTAssertEqual(state.armed, .none)
    }

    func test_tapCtrlArmsCtrl() {
        let state = ModifierState()

        XCTAssertEqual(state.tap(.ctrl), ArmedModifiers(ctrl: true))
        XCTAssertEqual(state.armed, ArmedModifiers(ctrl: true))
    }

    func test_tapCtrlAgainClearsCtrl() {
        let state = ModifierState()

        state.tap(.ctrl)

        XCTAssertEqual(state.tap(.ctrl), .none)
        XCTAssertEqual(state.armed, .none)
    }

    func test_tapCtrlThenAltArmsBoth() {
        let state = ModifierState()

        state.tap(.ctrl)

        XCTAssertEqual(state.tap(.alt), ArmedModifiers(ctrl: true, alt: true))
        XCTAssertEqual(state.armed, ArmedModifiers(ctrl: true, alt: true))
    }

    func test_consumeOneShotReturnsArmedAndResets() {
        let state = ModifierState()
        state.tap(.ctrl)
        state.tap(.shift)

        XCTAssertEqual(state.consume(), ArmedModifiers(ctrl: true, shift: true))
        XCTAssertEqual(state.armed, .none)
    }

    func test_consumeStickyReturnsArmedAndLeavesState() {
        let state = ModifierState()
        state.behavior = .sticky
        state.tap(.alt)

        XCTAssertEqual(state.consume(), ArmedModifiers(alt: true))
        XCTAssertEqual(state.armed, ArmedModifiers(alt: true))
    }

    func test_cancelClearsRegardlessOfMode() {
        let state = ModifierState()
        state.behavior = .sticky
        state.tap(.ctrl)
        state.tap(.alt)
        state.tap(.shift)

        state.cancel()

        XCTAssertEqual(state.armed, .none)
    }
}
