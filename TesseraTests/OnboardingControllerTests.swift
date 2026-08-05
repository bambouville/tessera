import XCTest
@testable import Tessera

@MainActor
final class OnboardingControllerTests: XCTestCase {
    func test_spotlightExpansionStaysInsideEveryOverlayEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        for target in [
            CGRect(x: 0, y: 100, width: 80, height: 44),
            CGRect(x: 240, y: 100, width: 80, height: 44),
            CGRect(x: 100, y: 0, width: 80, height: 44),
            CGRect(x: 100, y: 436, width: 80, height: 44),
        ] {
            let hole = OnboardingOverlay.spotlightHole(for: target, in: bounds)
            XCTAssertGreaterThanOrEqual(hole.minX, 2)
            XCTAssertGreaterThanOrEqual(hole.minY, 2)
            XCTAssertLessThanOrEqual(hole.maxX, 318)
            XCTAssertLessThanOrEqual(hole.maxY, 478)
        }
    }


    private func makeController() -> (OnboardingController, AppearancePreferences) {
        let appearance = AppearancePreferences()
        let controller = OnboardingController(appearance: appearance)
        return (controller, appearance)
    }

    // MARK: - beginIfFirstLaunch truth table

    func test_begin_unseenNoHosts_showsWelcome() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: false)
        XCTAssertEqual(controller.phase, .welcome)
    }

    func test_begin_unseenWithHosts_staysInactive() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: true, hasSeen: false)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_begin_seenNoHosts_staysInactive() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: true)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_begin_seenWithHosts_staysInactive() {
        let (controller, _) = makeController()
        controller.beginIfFirstLaunch(hasHosts: true, hasSeen: true)
        XCTAssertEqual(controller.phase, .inactive)
    }

    func test_begin_isIdempotent_doesNotResetActiveTour() {
        let (controller, _) = makeController()
        controller.startTour()
        controller.next()
        XCTAssertEqual(controller.phase, .touring(1))
        // A re-entrant onAppear must not yank an in-progress tour back to welcome.
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: false)
        XCTAssertEqual(controller.phase, .touring(1))
    }

    // MARK: - next / back clamping

    func test_startTour_beginsAtFirstStep() {
        let (controller, _) = makeController()
        controller.startTour()
        XCTAssertEqual(controller.phase, .touring(0))
    }

    func test_next_advancesThroughSteps() {
        let (controller, _) = makeController()
        controller.startTour()
        controller.next()
        XCTAssertEqual(controller.phase, .touring(1))
        controller.next()
        XCTAssertEqual(controller.phase, .touring(2))
    }

    func test_next_pastLastStep_finishes() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = false
        controller.startTour()
        for _ in 0..<(controller.steps.count - 1) {
            controller.next()
        }
        XCTAssertEqual(controller.phase, .touring(controller.steps.count - 1))
        // Advancing past the final step ends the tour and records the flag.
        controller.next()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(appearance.hasSeenWelcome)
    }

    func test_back_clampsAtFirstStep() {
        let (controller, _) = makeController()
        controller.startTour()
        controller.back()
        XCTAssertEqual(controller.phase, .touring(0))
    }

    func test_back_steppingDown() {
        let (controller, _) = makeController()
        controller.startTour()
        controller.next()
        controller.next()
        controller.back()
        XCTAssertEqual(controller.phase, .touring(1))
    }

    func test_nextAndBack_onlyApplyWhileTouring() {
        let (controller, _) = makeController()
        // No-ops outside .touring.
        controller.next()
        XCTAssertEqual(controller.phase, .inactive)
        controller.back()
        XCTAssertEqual(controller.phase, .inactive)
    }

    // MARK: - finish / skip flip the flag

    func test_finish_setsHasSeenWelcome() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = false
        controller.startTour()
        controller.finish()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(appearance.hasSeenWelcome)
    }

    func test_skip_setsHasSeenWelcome() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = false
        controller.startTour()
        controller.skip()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(appearance.hasSeenWelcome)
    }

    func test_skipFromWelcome_setsFlagAndDismisses() {
        let (controller, appearance) = makeController()
        appearance.hasSeenWelcome = false
        controller.beginIfFirstLaunch(hasHosts: false, hasSeen: false)
        XCTAssertEqual(controller.phase, .welcome)
        controller.skip()
        XCTAssertEqual(controller.phase, .inactive)
        XCTAssertTrue(appearance.hasSeenWelcome)
    }

    // MARK: - Step list shape

    func test_firstRun_hasNineStepsInOrder() {
        let steps = OnboardingStep.firstRun
        XCTAssertEqual(steps.count, 9)
        XCTAssertEqual(steps[0].kind, .spotlight(.addHost, .below))
        XCTAssertEqual(steps[1].kind, .spotlight(.keysNav, .right))
        XCTAssertEqual(steps[2].kind, .illustration(.mockTerminal))
        XCTAssertEqual(steps[3].kind, .illustration(.agentCenter))
        XCTAssertEqual(steps[4].kind, .illustration(.swipePad))
        XCTAssertEqual(steps[5].kind, .illustration(.filesPanel))
        XCTAssertEqual(steps[6].kind, .illustration(.shareInOut))
        XCTAssertEqual(steps[7].kind, .illustration(.agentImagePaste))
        XCTAssertEqual(steps[8].kind, .illustration(.shortcuts))
        XCTAssertTrue(steps[4].body.contains("swipe toward an option"))
        XCTAssertTrue(steps[4].body.contains("release"))
    }

    func test_compactFirstRun_adaptsDeviceSpecificStepsWithoutChangingSequence() {
        let steps = OnboardingStep.firstRun.map { $0.presentation(compact: true) }

        XCTAssertEqual(steps.count, 9)
        XCTAssertEqual(steps[0].kind, .spotlight(.addHost, .below))
        XCTAssertEqual(steps[1].kind, .illustration(.keySecurity))
        XCTAssertEqual(steps[2].kind, .illustration(.mockTerminal))
        XCTAssertEqual(steps[3].kind, .illustration(.agentCenter))
        XCTAssertEqual(steps[4].kind, .illustration(.swipePad))
        XCTAssertEqual(steps[5].kind, .illustration(.filesPanel))
        XCTAssertEqual(steps[6].kind, .illustration(.shareInOut))
        XCTAssertEqual(steps[7].kind, .illustration(.agentImagePaste))
        XCTAssertEqual(steps[8].kind, .illustration(.phoneControls))
        XCTAssertEqual(steps[5].title, "files from your phone")
        XCTAssertEqual(steps[8].title, "terminal controls")
        XCTAssertFalse(steps[0].body.contains("⌘"))
        XCTAssertFalse(steps[8].body.contains("Magic Keyboard"))
        XCTAssertTrue(steps[2].body.contains("focused pane fits the phone viewport"))
    }

    func test_controllerStepsMatchFirstRun() {
        let (controller, _) = makeController()
        XCTAssertEqual(controller.steps.count, OnboardingStep.firstRun.count)
        XCTAssertEqual(controller.steps.map(\.kind), OnboardingStep.firstRun.map(\.kind))
    }
}
