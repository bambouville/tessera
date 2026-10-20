import UIKit
import XCTest
@testable import TmuxControl
@testable import Tessera

/// The S2′ show rule (§6.9), through iOS's lifecycle and delivery adapter.
/// The former pure-tracker scenarios now drive the coordinator and record
/// edges at real registration boundaries, including multi-slot routing.
@MainActor
final class SessionShowEdgeTrackerTests: XCTestCase {
    private enum Edge: Equatable {
        case show(UUID, TmuxGridAuthorityLifecycleReducer.ShowSource)
        case hide(UUID)
    }

    @MainActor
    private final class RecordingTarget: SessionShowTarget {
        let slot: UUID
        let record: (Edge) -> Void
        var adoptions = 0
        var gridAuthorityPendingIntentSource: TmuxGridAuthorityLifecycleReducer.IntentSource? { nil }
        var gridAuthorityIntentElapsed: TimeInterval? { nil }
        var gridAuthorityChannelIsLive: Bool { false }

        init(slot: UUID, record: @escaping (Edge) -> Void) {
            self.slot = slot
            self.record = record
        }
        func gridAuthorityShown(
            source: TmuxGridAuthorityLifecycleReducer.ShowSource,
            intentElapsed: TimeInterval
        ) { record(.show(slot, source)) }
        func gridAuthorityHidden() { record(.hide(slot)) }
        func gridAuthorityAdoptShown() { adoptions += 1 }
        func setGridAuthorityIntentClockPaused(_ paused: Bool) {}
        func noteGridAuthorityUserStep() {}
    }

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private var now: TimeInterval = 0
    private var recorded: [Edge] = []
    private var targets: [UUID: RecordingTarget] = [:]

    private func makeTarget(for slot: UUID) -> RecordingTarget {
        let target = RecordingTarget(slot: slot) { [unowned self] in self.recorded.append($0) }
        targets[slot] = target
        return target
    }

    private func makeCoordinator() -> SessionShowCoordinator {
        let coordinator = SessionShowCoordinator(
            appForeground: true,
            locked: false,
            clock: { [unowned self] in self.now },
            log: { _ in }
        )
        for slot in [a, b, c] { coordinator.register(makeTarget(for: slot), for: slot) }
        recorded = [] // Registration starts every mounted background tab hidden.
        return coordinator
    }

    private func record(at seconds: TimeInterval, _ action: () -> Void) -> [Edge] {
        now = seconds
        recorded = []
        action()
        return recorded
    }

    private func tick(_ coordinator: SessionShowCoordinator, at seconds: TimeInterval) -> [Edge] {
        record(at: seconds) { coordinator.tickForTesting() }
    }

    /// Selects `slot` and lets the show settle.
    private func shown(_ slot: UUID) -> SessionShowCoordinator {
        let coordinator = makeCoordinator()
        XCTAssertEqual(record(at: 0) { coordinator.setSelectedSlot(slot) }, [])
        XCTAssertEqual(tick(coordinator, at: 0.35), [.show(slot, .show)])
        return coordinator
    }

    func test_selectingASessionShowsItAfterTheSettle() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(record(at: 0) { coordinator.setSelectedSlot(a) }, [], "a show waits for routing to settle")
        XCTAssertEqual(tick(coordinator, at: 0.2), [])
        XCTAssertEqual(tick(coordinator, at: 0.349), [], "the 350 ms settle has not elapsed")
        XCTAssertEqual(tick(coordinator, at: 0.35), [.show(a, .show)])
        XCTAssertEqual(tick(coordinator, at: 5), [], "one show per displayed interval")
    }

    func test_inactiveWithoutBackgroundIsTransparent() {
        // Control Center, alerts and Face ID report no background edge.
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 3) { coordinator.setAppForeground(true) }, [])
        XCTAssertEqual(tick(coordinator, at: 10), [])
    }

    func test_backgroundThenForegroundIsAShow() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 10) { coordinator.setAppForeground(false) }, [])
        // Suspended: the debounce tick never ran. Wake hides before showing.
        XCTAssertEqual(record(at: 60) { coordinator.setAppForeground(true) }, [.hide(a)])
        XCTAssertEqual(tick(coordinator, at: 60.35), [.show(a, .show)])
    }

    func test_backgroundHideFiresAfterTheDebounceWhenTheTickRuns() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 10) { coordinator.setAppForeground(false) }, [])
        XCTAssertEqual(tick(coordinator, at: 11.499), [], "the 1.5 s hide debounce has not elapsed")
        XCTAssertEqual(tick(coordinator, at: 11.5), [.hide(a)])
        XCTAssertEqual(record(at: 30) { coordinator.setAppForeground(true) }, [])
        XCTAssertEqual(tick(coordinator, at: 30.35), [.show(a, .show)])
    }

    func test_hiddenIntervalShorterThanTheDebounceIsTransparent() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 10) { coordinator.setAppForeground(false) }, [])
        XCTAssertEqual(record(at: 11) { coordinator.setAppForeground(true) }, [])
        XCTAssertEqual(tick(coordinator, at: 20), [], "a sub-1.5 s app switch is neither a hide nor a show")
        XCTAssertEqual(record(at: 30) { coordinator.setSelectedSlot(nil) }, [])
        XCTAssertEqual(record(at: 31.4) { coordinator.setSelectedSlot(a) }, [])
        XCTAssertEqual(tick(coordinator, at: 40), [], "Agent Center and back within the debounce is transparent")
    }

    func test_lockHidesAndUnlockShows() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 5) { coordinator.setLocked(true) }, [])
        XCTAssertEqual(tick(coordinator, at: 6.5), [.hide(a)])
        XCTAssertEqual(record(at: 20) { coordinator.setLocked(false) }, [], "the unlock show settles like any other")
        XCTAssertEqual(tick(coordinator, at: 20.35), [.show(a, .show)])
    }

    func test_noShowFiresBehindTheLock() {
        let coordinator = shown(a)
        _ = record(at: 10) { coordinator.setAppForeground(false) }
        _ = record(at: 10.1) { coordinator.setLocked(true) }
        XCTAssertEqual(record(at: 60) { coordinator.setAppForeground(true) }, [.hide(a)])
        XCTAssertEqual(tick(coordinator, at: 61), [], "ContentView stays mounted under the lock; nothing may claim")
        XCTAssertEqual(record(at: 62) { coordinator.setSelectedSlot(b) }, [])
        XCTAssertEqual(tick(coordinator, at: 63), [])
        XCTAssertEqual(record(at: 70) { coordinator.setLocked(false) }, [])
        XCTAssertEqual(tick(coordinator, at: 70.35), [.show(b, .show)], "the falling edge of the lock is the show")
    }

    func test_sidebarSwitchHidesTheOldSessionAndShowsTheNewOne() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 5) { coordinator.setSelectedSlot(b) }, [])
        XCTAssertEqual(tick(coordinator, at: 5.35), [.show(b, .show)])
        XCTAssertEqual(tick(coordinator, at: 6.5), [.hide(a)])
        let oldTarget = makeTarget(for: a)
        XCTAssertEqual(record(at: 7) { coordinator.register(oldTarget, for: a) }, [.hide(a)],
                       "after the debounce, a new controller for the old slot starts hidden")
        XCTAssertEqual(oldTarget.adoptions, 0)
    }

    func test_flickingThroughTabsShowsOnlyWhereItSettles() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 5) { coordinator.setSelectedSlot(b) }, [])
        XCTAssertEqual(record(at: 5.1) { coordinator.setSelectedSlot(c) }, [])
        XCTAssertEqual(tick(coordinator, at: 5.45), [.show(c, .show)])
        XCTAssertEqual(tick(coordinator, at: 7), [.hide(a)])
        XCTAssertEqual(tick(coordinator, at: 30), [], "the tab flicked past never received a show, so it gets no hide")
    }

    func test_hiddenBackgroundTabsNeverReceiveAShow() {
        let coordinator = shown(a)
        // Background tabs stay mounted; only selection displays them.
        for second in 1...10 { XCTAssertEqual(tick(coordinator, at: TimeInterval(second)), []) }
        XCTAssertEqual(coordinator.displayedSlot, a)
        let visibleTarget = makeTarget(for: a)
        XCTAssertEqual(record(at: 11) { coordinator.register(visibleTarget, for: a) }, [])
        XCTAssertEqual(visibleTarget.adoptions, 1, "the displayed slot remains shown")
        for slot in [b, c] { XCTAssertEqual(targets[slot]?.adoptions, 0) }
    }

    func test_explicitOpenOfTheDisplayedSessionShowsAgain() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 10) { coordinator.explicitOpen(a) }, [])
        XCTAssertEqual(tick(coordinator, at: 10.35), [.show(a, .explicitOpen)])
        XCTAssertEqual(tick(coordinator, at: 20), [], "one explicit open, one show")
    }

    func test_explicitOpenFollowsItsRoutingToTheTargetSession() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 10) { coordinator.explicitOpen(b) }, [], "Handoff receipt lands before the selection")
        XCTAssertEqual(tick(coordinator, at: 10.35), [], "the session on screen is not the target")
        XCTAssertEqual(record(at: 11) { coordinator.setSelectedSlot(b) }, [])
        XCTAssertEqual(tick(coordinator, at: 11.35), [.show(b, .explicitOpen)])
    }

    func test_explicitOpenExpiresWhenItsSessionNeverAppears() {
        let coordinator = shown(a)
        _ = record(at: 10) { coordinator.explicitOpen(b) }
        XCTAssertEqual(tick(coordinator, at: 13), [])
        XCTAssertEqual(record(at: 20) { coordinator.setSelectedSlot(b) }, [])
        XCTAssertEqual(tick(coordinator, at: 20.35), [.show(b, .show)])
    }

    func test_explicitOpenWithinTheDebounceStillShows() {
        let coordinator = shown(a)
        _ = record(at: 10) { coordinator.setSelectedSlot(nil) }
        _ = record(at: 10.5) { coordinator.explicitOpen(a) }
        XCTAssertEqual(record(at: 10.6) { coordinator.setSelectedSlot(a) }, [])
        XCTAssertEqual(tick(coordinator, at: 10.95), [.show(a, .explicitOpen)],
                       "a transparent return does not swallow an explicit open")
    }

    func test_replacingTheSessionInTheSameSlotIsTransparent() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 0.35) { coordinator.replaceSlot(a, with: b) }, [.hide(a)],
                       "replacement hides the old controller without emitting a show edge")
        XCTAssertEqual(record(at: 5) { coordinator.setSelectedSlot(b) }, [])
        XCTAssertEqual(tick(coordinator, at: 10), [], "foreground restore and mosh rebuilds are not shows")
        XCTAssertEqual(coordinator.displayedSlot, b)
        XCTAssertEqual(targets[b]?.adoptions, 1, "the replacement inherits the shown slot")
        XCTAssertEqual(record(at: 20) { coordinator.setAppForeground(false) }, [])
        XCTAssertEqual(tick(coordinator, at: 21.5), [.hide(b)], "the replacement inherits the shown slot")
    }

    func test_replacementDuringTheHideDebounceCarriesTheDebounce() {
        let coordinator = shown(a)
        _ = record(at: 10) { coordinator.setAppForeground(false) }
        XCTAssertEqual(record(at: 10) { coordinator.replaceSlot(a, with: b) }, [.hide(a)])
        XCTAssertEqual(record(at: 10.5) { coordinator.setAppForeground(true) }, [])
        XCTAssertEqual(tick(coordinator, at: 20), [])
        XCTAssertEqual(coordinator.displayedSlot, b)
        let visibleTarget = makeTarget(for: b)
        XCTAssertEqual(record(at: 20) { coordinator.register(visibleTarget, for: b) }, [])
        XCTAssertEqual(visibleTarget.adoptions, 1, "a return within the inherited debounce remains shown")
    }

    func test_closingTheShownSessionEmitsNothing() {
        let coordinator = shown(a)
        XCTAssertEqual(record(at: 0.35) { coordinator.removeSlot(a) }, [])
        XCTAssertEqual(record(at: 5) { coordinator.setSelectedSlot(nil) }, [])
        XCTAssertEqual(tick(coordinator, at: 10), [])
    }
}

@MainActor
final class SessionShowCoordinatorTests: XCTestCase {
    @MainActor
    private final class RecordingTarget: SessionShowTarget {
        var events: [String] = []
        var onEvent: ((String) -> Void)?
        var shownElapsed: [TimeInterval] = []
        var paused = false
        var userSteps = 0
        var adoptions = 0
        var gridAuthorityPendingIntentSource: TmuxGridAuthorityLifecycleReducer.IntentSource?
        var gridAuthorityIntentElapsed: TimeInterval?
        var gridAuthorityChannelIsLive = false

        func gridAuthorityShown(
            source: TmuxGridAuthorityLifecycleReducer.ShowSource,
            intentElapsed: TimeInterval
        ) {
            events.append("show:\(source.rawValue)")
            onEvent?("show:\(source.rawValue)")
            shownElapsed.append(intentElapsed)
        }
        func gridAuthorityHidden() {
            events.append("hide")
            onEvent?("hide")
        }
        func gridAuthorityAdoptShown() { adoptions += 1 }
        func setGridAuthorityIntentClockPaused(_ paused: Bool) { self.paused = paused }
        func noteGridAuthorityUserStep() { userSteps += 1 }
    }

    private var now: TimeInterval = 0

    private func makeCoordinator() -> SessionShowCoordinator {
        SessionShowCoordinator(
            appForeground: true,
            locked: false,
            clock: { [unowned self] in self.now },
            log: { _ in }
        )
    }

    private func advance(_ seconds: TimeInterval, _ coordinator: SessionShowCoordinator) {
        now += seconds
        coordinator.tickForTesting()
    }

    func test_oldHideAndNewShowDeadlinesRunConcurrently() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget()
        let newTarget = RecordingTarget()
        var events: [String] = []
        oldTarget.onEvent = { events.append("old:\($0)") }
        newTarget.onEvent = { events.append("new:\($0)") }
        coordinator.register(oldTarget, for: old)
        coordinator.register(newTarget, for: new)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)
        events = []

        coordinator.setSelectedSlot(new)
        now = 0.699
        coordinator.tickForTesting()
        XCTAssertEqual(events, [])
        now = 0.7
        coordinator.tickForTesting()
        XCTAssertEqual(events, ["new:show:show"], "the new show does not wait for the old hide")
        now = 1.849
        coordinator.tickForTesting()
        XCTAssertEqual(events, ["new:show:show"])
        now = 1.85
        coordinator.tickForTesting()
        XCTAssertEqual(events, ["new:show:show", "old:hide"], "the old hide keeps its independent deadline")
    }

    func test_lateTickBatchDeliversAllHidesBeforeShows() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget()
        let newTarget = RecordingTarget()
        var events: [String] = []
        oldTarget.onEvent = { events.append("old:\($0)") }
        newTarget.onEvent = { events.append("new:\($0)") }
        coordinator.register(oldTarget, for: old)
        coordinator.register(newTarget, for: new)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)
        events = []

        coordinator.setSelectedSlot(new)
        // No task ran at the settle. Both deadlines are due in this batch.
        advance(1.5, coordinator)
        XCTAssertEqual(events, ["old:hide", "new:show:show"])
        XCTAssertEqual(newTarget.shownElapsed, [0], "the step is the emission, not the missed settle deadline")
    }

    func test_replacementKeepsTheSuccessorsPendingExplicitOpen() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget()
        let newTarget = RecordingTarget()
        coordinator.register(oldTarget, for: old)
        coordinator.register(newTarget, for: new)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)
        coordinator.explicitOpen(new) // The successor's own off-screen tracker has a pending open.
        coordinator.setChallengePresented(true, for: old)

        coordinator.replaceSlot(old, with: new)
        XCTAssertEqual(coordinator.displayedSlot, new)
        XCTAssertEqual(newTarget.events, ["hide"], "renaming emits no edge of its own")
        XCTAssertEqual(newTarget.adoptions, 1, "the old tracker was already shown")
        XCTAssertTrue(newTarget.paused, "the old slot's challenge pause follows the rename")
        XCTAssertEqual(oldTarget.events, ["hide", "show:show", "hide"])
        advance(0.35, coordinator)
        XCTAssertEqual(newTarget.events, ["hide", "show:explicitOpen"], "the successor's open survives the rename")
        XCTAssertEqual(newTarget.shownElapsed, [0], "the carried challenge pauses its clock")
        advance(5, coordinator)
        XCTAssertEqual(newTarget.events, ["hide", "show:explicitOpen"])
        coordinator.setChallengePresented(false, for: new)
        XCTAssertFalse(newTarget.paused)
        coordinator.setAppForeground(false)
        advance(1.5, coordinator)
        XCTAssertEqual(newTarget.events, ["hide", "show:explicitOpen", "hide"], "the inherited shown state owns the next hide")
    }

    func test_replacementDoesNotReviveASuccessorsLapsedOpen() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget() // Targets are held weakly.
        let newTarget = RecordingTarget()
        coordinator.register(oldTarget, for: old)
        coordinator.register(newTarget, for: new)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)
        coordinator.explicitOpen(new)
        advance(3, coordinator)
        coordinator.replaceSlot(old, with: new)
        advance(0.35, coordinator)
        XCTAssertEqual(newTarget.events, ["hide"], "an open that lapsed off screen stays lapsed")
        XCTAssertEqual(newTarget.adoptions, 1)
    }

    func test_replacementDuringHideDebounceDoesNotAdoptAnOffscreenSuccessor() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget()
        let newTarget = RecordingTarget()
        coordinator.register(oldTarget, for: old)
        coordinator.register(newTarget, for: new)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)
        coordinator.setAppForeground(false)
        now += 0.5

        coordinator.replaceSlot(old, with: new)
        XCTAssertEqual(newTarget.adoptions, 0, "replacement only adopts the currently shown selection")
        XCTAssertEqual(newTarget.events, ["hide"])
        XCTAssertEqual(oldTarget.events, ["hide", "show:show", "hide"])
        now = 1.849
        coordinator.tickForTesting()
        XCTAssertEqual(newTarget.events, ["hide"])
        now = 1.85
        coordinator.tickForTesting()
        XCTAssertEqual(newTarget.events, ["hide", "hide"], "replacement preserves the old hide deadline")
        XCTAssertEqual(newTarget.adoptions, 0)
    }

    func test_replacementDuringHideDebounceDefersACarriedShow() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget()
        let newTarget = RecordingTarget()
        coordinator.register(oldTarget, for: old)
        coordinator.register(newTarget, for: new)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)
        oldTarget.gridAuthorityPendingIntentSource = .show
        oldTarget.gridAuthorityIntentElapsed = 1
        coordinator.setAppForeground(false)
        now += 0.5

        coordinator.replaceSlot(old, with: new)
        XCTAssertEqual(newTarget.events, ["hide"], "replacement does not deliver a carried show off screen")
        XCTAssertEqual(newTarget.adoptions, 0)
        now += 0.1
        coordinator.setAppForeground(true)
        coordinator.register(newTarget, for: new)
        XCTAssertEqual(newTarget.events, ["hide", "show:show"], "the unresolved show survives until delivery")
        XCTAssertEqual(newTarget.shownElapsed.first ?? -1, 1.1, accuracy: 1e-9)
        advance(5, coordinator)
        XCTAssertEqual(newTarget.events, ["hide", "show:show"], "the inherited debounce was cancelled")
    }

    func test_explicitOpenBeforeAnyRegistrationOrSelectionWaitsForItsSlot() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        coordinator.explicitOpen(slot)
        advance(1, coordinator)
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        now += 2
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.events, ["show:explicitOpen"])
        XCTAssertEqual(target.shownElapsed, [2], "the open created a tracker before the view or selection existed")
        advance(5, coordinator)
        XCTAssertEqual(target.events, ["show:explicitOpen"], "one open emits one show")
    }

    func test_showElapsedStartsAtTheCoreStepBeforeDelivery() {
        for registered in [true, false] {
            now = 0
            let coordinator = SessionShowCoordinator(
                appForeground: true,
                locked: false,
                clock: { [unowned self] in self.now },
                log: { [unowned self] line in
                    // Delivery runs later on the same injected clock.
                    if line.hasPrefix("grid-authority show-edge show slot=") { self.now += 2 }
                }
            )
            let slot = UUID()
            let target = RecordingTarget()
            if registered { coordinator.register(target, for: slot) }
            coordinator.setSelectedSlot(slot)
            advance(0.35, coordinator)
            if !registered {
                now += 3
                coordinator.register(target, for: slot)
            }
            XCTAssertEqual(target.shownElapsed.count, 1)
            XCTAssertEqual(target.shownElapsed.first ?? -1, registered ? 2 : 5, accuracy: 1e-9,
                           "stepAt must survive both immediate and deferred delivery")
        }
    }

    func test_pausedUndeliveredShowUsesZeroElapsedOnRegistration() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        now += 20
        coordinator.setChallengePresented(true, for: slot)
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertTrue(target.paused)
        XCTAssertEqual(target.events, ["show:show"])
        XCTAssertEqual(target.shownElapsed, [0], "a prompt pauses the carried step's clock")
    }

    func test_registrationDuringHideDebounceHoldsAnUndeliveredShowUntilTheHide() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        coordinator.setAppForeground(false)
        now += 0.5
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.events, [], "a slot waiting out its hide is off screen")
        XCTAssertEqual(target.adoptions, 0)
        advance(1, coordinator)
        XCTAssertEqual(target.events, ["hide"], "the hide clears the held show")
        coordinator.setAppForeground(true)
        advance(0.35, coordinator)
        XCTAssertEqual(target.events, ["hide", "show:show"])
        XCTAssertEqual(target.shownElapsed.count, 1)
        XCTAssertEqual(target.shownElapsed.first ?? -1, 0, accuracy: 0.001)
    }

    func test_aReturnWithinTheDebounceDeliversAShowHeldAtRegistration() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        coordinator.setAppForeground(false)
        now += 0.5
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.events, [])
        coordinator.setAppForeground(true)
        XCTAssertEqual(target.events, ["show:show"], "never hidden, so the held show is delivered")
        XCTAssertEqual(target.shownElapsed.count, 1)
        XCTAssertEqual(target.shownElapsed.first ?? -1, 0.5, accuracy: 0.001, "its clock ran from the show's step")
        advance(2, coordinator)
        XCTAssertEqual(target.events, ["show:show"])
    }

    func test_aShowHeldBehindTheLockIsNeverDeliveredPastAMissedHide() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        now = 1
        coordinator.setLocked(true)
        now = 2.6 // The hide was due at 2.5; its tick has not run.
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.events, [], "no show reaches a controller behind the lock")
        XCTAssertEqual(target.adoptions, 0)
        coordinator.tickForTesting()
        XCTAssertEqual(target.events, ["hide"])
        coordinator.setLocked(false)
        advance(0.35, coordinator)
        XCTAssertEqual(target.events, ["hide", "show:show"])
    }

    func test_registrationDuringHideDebounceAdoptsShownVisibility() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        let oldTarget = RecordingTarget()
        coordinator.register(oldTarget, for: slot)
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        coordinator.unregister(oldTarget, for: slot)
        coordinator.setAppForeground(false)
        now += 0.5
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.events, [], "a debouncing slot is still shown to its controller")
        XCTAssertEqual(target.adoptions, 1)
        advance(1, coordinator)
        XCTAssertEqual(target.events, ["hide"])
    }

    func test_showReachesTheRegisteredController() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.events, ["hide"], "registered before it is displayed: hidden")
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        XCTAssertEqual(target.events, ["hide", "show:show"])
    }

    func test_showBeforeTheViewMountsIsDeliveredOnRegistration() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        now += 3
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.events, ["show:show"])
        XCTAssertEqual(target.shownElapsed, [3], "the R3 window runs from the show, not the mount")
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.events, ["show:show"], "re-registration is not another show")
    }

    func test_replacementCarriesAnUnresolvedShowWithItsRemainingWindow() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget()
        coordinator.register(oldTarget, for: old)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)
        oldTarget.gridAuthorityPendingIntentSource = .show
        oldTarget.gridAuthorityIntentElapsed = 5

        coordinator.replaceSlot(old, with: new)
        XCTAssertEqual(oldTarget.events, ["hide", "show:show", "hide"],
                       "the replaced controller's intent cannot resolve on a late reply")
        coordinator.setSelectedSlot(new)
        now += 2
        let newTarget = RecordingTarget()
        coordinator.register(newTarget, for: new)
        XCTAssertEqual(newTarget.events, ["show:show"],
                       "the user's step waits for the replacement's first read")
        XCTAssertEqual(newTarget.shownElapsed, [7], "the carried show keeps only what is left of its window")
        advance(5, coordinator)
        XCTAssertEqual(oldTarget.events, ["hide", "show:show", "hide"])
        XCTAssertEqual(newTarget.events, ["show:show"])
    }

    /// A tap is bound to a veil of the connection being replaced; carrying
    /// it as a show would claim a session the user only tapped once (M4).
    func test_replacementDropsAPendingTap() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget()
        coordinator.register(oldTarget, for: old)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)
        oldTarget.gridAuthorityPendingIntentSource = .tap

        coordinator.replaceSlot(old, with: new)
        coordinator.setSelectedSlot(new)
        let newTarget = RecordingTarget()
        coordinator.register(newTarget, for: new)
        advance(5, coordinator)
        XCTAssertEqual(newTarget.events, [], "a tap is not carried as a show")
        XCTAssertEqual(oldTarget.events, ["hide", "show:show", "hide"])
    }

    /// M2: a controller registered for a session that is not on screen
    /// starts hidden, so a peer is not drawn as a veil before its show.
    func test_registeringAnUndisplayedSessionStartsItHidden() {
        let coordinator = makeCoordinator()
        let displayed = UUID()
        let background = UUID()
        coordinator.setSelectedSlot(displayed)
        advance(0.35, coordinator)
        let displayedTarget = RecordingTarget()
        coordinator.register(displayedTarget, for: displayed)
        XCTAssertEqual(displayedTarget.events, ["show:show"], "the shown session is not hidden first")

        let backgroundTarget = RecordingTarget()
        coordinator.register(backgroundTarget, for: background)
        XCTAssertEqual(backgroundTarget.events, ["hide"])
        coordinator.register(backgroundTarget, for: background)
        XCTAssertEqual(backgroundTarget.events, ["hide"], "re-registration is not another hide")
        coordinator.setSelectedSlot(background)
        advance(0.35, coordinator)
        XCTAssertEqual(backgroundTarget.events, ["hide", "show:show"])
    }

    func test_replacementWithoutAPendingIntentIsTransparent() {
        let coordinator = makeCoordinator()
        let old = UUID()
        let new = UUID()
        let oldTarget = RecordingTarget()
        coordinator.register(oldTarget, for: old)
        coordinator.setSelectedSlot(old)
        advance(0.35, coordinator)

        coordinator.replaceSlot(old, with: new)
        coordinator.setSelectedSlot(new)
        let newTarget = RecordingTarget()
        coordinator.register(newTarget, for: new)
        advance(5, coordinator)
        XCTAssertEqual(newTarget.events, [], "restoring a session object is not a show")
    }

    /// L3: a connect prompt pauses only sessions still connecting.
    func test_connectPromptsPauseOnlySessionsWithoutALiveChannel() {
        let coordinator = makeCoordinator()
        let connecting = UUID()
        let live = UUID()
        let connectingTarget = RecordingTarget()
        let liveTarget = RecordingTarget()
        liveTarget.gridAuthorityChannelIsLive = true
        coordinator.register(connectingTarget, for: connecting)
        coordinator.register(liveTarget, for: live)
        coordinator.setGlobalPromptActive(true)
        XCTAssertTrue(connectingTarget.paused)
        XCTAssertFalse(liveTarget.paused, "a live session is not waiting on another session's host key")
        coordinator.setGlobalPromptActive(false)
        XCTAssertFalse(connectingTarget.paused)
    }

    /// L3: Retry is a user step; it restarts the window of the show it
    /// leads to, delivered or not.
    func test_retryRestartsTheShowWindow() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        now += 15
        coordinator.noteUserStep(for: slot)
        now += 1
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        XCTAssertEqual(target.shownElapsed.count, 1)
        XCTAssertEqual(target.shownElapsed.first ?? -1, 1, accuracy: 1e-9)
        coordinator.noteUserStep(for: slot)
        XCTAssertEqual(target.userSteps, 1)
    }

    /// L1: every edge reads the one injected clock, so what the device's
    /// sleep does to that clock decides the wake. A clock that counts sleep
    /// (production: `mach_continuous_time`) has run past the hide debounce, so
    /// the wake delivers the hide, then the show. An uptime clock stops
    /// while asleep; the same wake would look like a 0 s interruption and
    /// swallow both edges, leaving a peer that took over meanwhile unread
    /// by any show.
    func test_wakeAfterASleepPastTheDebounceDeliversHideThenShow() {
        for countsSleep in [true, false] {
            now = 0
            let coordinator = makeCoordinator()
            let slot = UUID()
            let target = RecordingTarget()
            coordinator.register(target, for: slot)
            coordinator.setSelectedSlot(slot)
            advance(0.35, coordinator)
            coordinator.setAppForeground(false)
            // Asleep for ten minutes: no tick ran. Only a clock that counts
            // sleep moved.
            if countsSleep { now += 600 }
            coordinator.setAppForeground(true)
            advance(0.35, coordinator)
            if countsSleep {
                XCTAssertEqual(target.events, ["hide", "show:show", "hide", "show:show"])
            } else {
                XCTAssertEqual(target.events, ["hide", "show:show"],
                               "an uptime clock makes a long sleep look transparent")
            }
        }
    }

    /// The production clock is the kernel's sleep-inclusive counter. Read
    /// through a different API (`mach_continuous_time` and its timebase), not
    /// the formula under test; it differs from uptime by the time the host
    /// has slept since boot.
    func test_defaultClockIsTheSleepInclusiveContinuousCounter() {
        var timebase = mach_timebase_info_data_t()
        XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
        let continuous = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        let uptime = ProcessInfo.processInfo.systemUptime
        let reading = SessionShowCoordinator.continuousSeconds()
        XCTAssertEqual(reading, continuous, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(reading + 0.05, uptime, "a sleep-inclusive clock never trails uptime")
    }

    /// A foreground restore that reuses a live duplicate renames the shown
    /// slot onto a controller that registered earlier, hidden, as an
    /// off-screen tab. The replaced controller's show had already resolved,
    /// so the successor adopts the slot's visibility (lifting its hide and
    /// re-reading) without a gesture of its own: a replacement never claims
    /// (§6.9 R5). An unresolved show is carried instead (below).
    func test_replacingOntoARegisteredSuccessorAdoptsItsVisibility() {
        let coordinator = makeCoordinator()
        let corpse = UUID()
        let alive = UUID()
        let corpseTarget = RecordingTarget()
        let aliveTarget = RecordingTarget()
        coordinator.register(corpseTarget, for: corpse)
        coordinator.register(aliveTarget, for: alive)
        coordinator.setSelectedSlot(corpse)
        advance(0.35, coordinator)
        XCTAssertEqual(aliveTarget.events, ["hide"])

        coordinator.replaceSlot(corpse, with: alive)
        XCTAssertEqual(aliveTarget.events, ["hide"], "a settled replacement is not a show")
        XCTAssertEqual(aliveTarget.adoptions, 1)
        XCTAssertEqual(corpseTarget.events, ["hide", "show:show", "hide"])
        coordinator.setSelectedSlot(alive)
        advance(5, coordinator)
        XCTAssertEqual(aliveTarget.events, ["hide"], "selecting the replaced slot is no show either")
        XCTAssertEqual(aliveTarget.adoptions, 1)
    }

    /// The replaced controller's show was still unresolved (its channel died
    /// before the read answered): the gesture carries, as a show.
    func test_replacingOntoARegisteredSuccessorCarriesAnUnresolvedShow() {
        let coordinator = makeCoordinator()
        let corpse = UUID()
        let alive = UUID()
        let corpseTarget = RecordingTarget()
        let aliveTarget = RecordingTarget()
        coordinator.register(corpseTarget, for: corpse)
        coordinator.register(aliveTarget, for: alive)
        coordinator.setSelectedSlot(corpse)
        advance(0.35, coordinator)
        corpseTarget.gridAuthorityPendingIntentSource = .show
        corpseTarget.gridAuthorityIntentElapsed = 1

        coordinator.replaceSlot(corpse, with: alive)
        XCTAssertEqual(aliveTarget.events, ["hide", "show:show"])
        XCTAssertEqual(aliveTarget.shownElapsed, [1])
        XCTAssertEqual(aliveTarget.adoptions, 0, "the carried show decides; no adoption besides")
    }

    /// A carried show reaches a registered successor once, with its window.
    func test_replacingOntoARegisteredSuccessorDeliversACarriedShowOnce() {
        let coordinator = makeCoordinator()
        let corpse = UUID()
        let alive = UUID()
        let corpseTarget = RecordingTarget()
        let aliveTarget = RecordingTarget()
        coordinator.register(corpseTarget, for: corpse)
        coordinator.register(aliveTarget, for: alive)
        coordinator.setSelectedSlot(corpse)
        advance(0.35, coordinator)
        corpseTarget.gridAuthorityPendingIntentSource = .explicitOpen
        corpseTarget.gridAuthorityIntentElapsed = 4

        coordinator.replaceSlot(corpse, with: alive)
        XCTAssertEqual(aliveTarget.events, ["hide", "show:explicitOpen"])
        XCTAssertEqual(aliveTarget.shownElapsed, [4])
    }

    /// The same restore against a real controller and its hidden flag: the
    /// successor was registered hidden over a peer (`.resuming`, no veil).
    /// After the rename it must be displayed again, so cancelling the show's
    /// pending read leaves the peer's tappable veil, not a stuck resume.
    func test_replacingOntoARegisteredControllerLiftsItsHide() {
        let coordinator = makeCoordinator()
        let corpse = UUID()
        let alive = UUID()
        let corpseTarget = RecordingTarget()
        coordinator.register(corpseTarget, for: corpse)
        let controller = yieldedController()
        coordinator.register(controller, for: alive)
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false),
                       "registered off screen: hidden, the peer is not drawn")
        coordinator.setSelectedSlot(corpse)
        advance(0.35, coordinator)

        coordinator.replaceSlot(corpse, with: alive)
        XCTAssertNil(controller.gridAuthorityPendingIntentSource, "a settled replacement is not a show (R5)")
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "Mac"),
                       "displayed: the peer is the tappable veil")
    }

    private func yieldedController() -> TmuxController {
        let tmux = TmuxController(controlPath: .sideChannel)
        tmux.feedTerminal = { _ in }
        tmux.sendBytes = { _ in }
        tmux.gridAuthorityIdentity = .init(id: "SELF", displayName: "iPad")
        tmux.updateClientSize(cols: 166, rows: 54)
        var entry = [UInt8](arrayLiteral: 0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70)
        entry.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        tmux.ingest(entry)
        for number in 2...8 {
            tmux.ingest(Array("%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8))
        }
        tmux.ingest(Array("%window-add @1\r\n".utf8))
        tmux.ingest(Array("%window-pane-changed @1 %5\r\n".utf8))
        tmux.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        // A controller starts hidden until a show or an adoption says it is
        // on screen; this one stands for a tab that was displayed.
        tmux.gridAuthorityAdoptShown()
        tmux.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : v1 PEER 1 Mac\r\n".utf8))
        XCTAssertEqual(tmux.gridAuthorityPresentation, .veiled(peerName: "Mac"))
        return tmux
    }

    func test_promptsPauseTheIntentClock() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        let other = UUID()
        let target = RecordingTarget()
        let otherTarget = RecordingTarget()
        coordinator.register(target, for: slot)
        coordinator.register(otherTarget, for: other)

        coordinator.setGlobalPromptActive(true)
        XCTAssertTrue(target.paused)
        XCTAssertTrue(otherTarget.paused)
        coordinator.setChallengePresented(true, for: slot)
        coordinator.setGlobalPromptActive(false)
        XCTAssertTrue(target.paused, "the session's own password prompt is still open")
        XCTAssertFalse(otherTarget.paused)
        coordinator.setChallengePresented(false, for: slot)
        XCTAssertFalse(target.paused)
    }

    func test_backgroundAndLockedForegroundNeverReachTheController() {
        let coordinator = makeCoordinator()
        let slot = UUID()
        let target = RecordingTarget()
        coordinator.register(target, for: slot)
        coordinator.setSelectedSlot(slot)
        advance(0.35, coordinator)
        coordinator.setAppForeground(false)
        coordinator.setLocked(true)
        now += 30
        coordinator.setAppForeground(true)
        advance(1, coordinator)
        XCTAssertEqual(target.events, ["hide", "show:show", "hide"])
        coordinator.setLocked(false)
        advance(0.35, coordinator)
        XCTAssertEqual(target.events, ["hide", "show:show", "hide", "show:show"])
    }
}

/// A restored session builds its controller while a cold launch still reads
/// `applicationState` as background, and no willEnterForeground follows:
/// becoming active must end that background, or the launch show only leaves
/// an intent for a foreground read that never comes.
@MainActor
final class TmuxControllerLaunchForegroundTests: XCTestCase {
    func testBecomingActiveEndsABackgroundTheLaunchReported() async {
        let controller = TmuxController(authorityInitialGeneration: 0, controlPath: .sideChannel)
        controller.gridAuthorityBackgrounded()
        XCTAssertTrue(controller.gridAuthoritySessionForTesting.inBackground)

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where controller.gridAuthoritySessionForTesting.inBackground {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(
            controller.gridAuthoritySessionForTesting.inBackground,
            "becoming active is a foreground even without willEnterForeground"
        )
    }
}
