import Foundation
import XCTest
@testable import TmuxControlCore

/// §6.9 show/hide edges for one slot, ported from both platforms' trackers:
/// Android `SessionShowEdgeTrackerTest` and the iOS tracker half of
/// `SessionShowEdgeTrackerTests`. Adapter-only concerns stay on their
/// platform: Android's start-epoch filter and excursion counter, the
/// explicit-open request count, and iOS slot registration.
///
/// Deliberate changes from Android (plan §C.3): every show waits the 0.35 s
/// settle, an explicit open lapses after 3 s, and a missed hide is emitted
/// as its own edge before the return's settled show (no `foldedHide`).
final class ShowEdgeTrackerTests: XCTestCase {
    private typealias Edge = TmuxShowEdgeTracker.Edge

    private func show(_ at: Int64) -> Edge { .show(source: .show, stepAt: at) }
    private func explicitOpen(_ at: Int64) -> Edge { .show(source: .explicitOpen, stepAt: at) }

    /// Displayed at `at`, shown once the settle ran.
    private func shownTracker(at: Int64 = 0) -> TmuxShowEdgeTracker {
        var tracker = TmuxShowEdgeTracker()
        XCTAssertEqual(tracker.displayed(true, now: at), [])
        XCTAssertEqual(tracker.tick(now: at + 350), [show(at + 350)])
        return tracker
    }

    // MARK: Android SessionShowEdgeTrackerTest

    func test_firstDisplayIsAShowAndRepeatsAreNot() {
        var tracker = TmuxShowEdgeTracker()
        XCTAssertFalse(tracker.isShown, "every slot starts not shown")
        XCTAssertEqual(tracker.displayed(true, now: 0), [], "a show waits for routing to settle")
        XCTAssertEqual(tracker.nextDeadline, 350)
        XCTAssertEqual(tracker.tick(now: 349), [])
        XCTAssertEqual(tracker.tick(now: 350), [show(350)])
        XCTAssertEqual(tracker.displayed(true, now: 400), [])
        XCTAssertTrue(tracker.isShown)
        XCTAssertNil(tracker.nextDeadline)
    }

    func test_aNonPresentedTabNeverShows() {
        var tracker = TmuxShowEdgeTracker()
        XCTAssertEqual(tracker.displayed(false, now: 0), [])
        XCTAssertEqual(tracker.tick(now: 60_000), [])
        XCTAssertEqual(tracker.displayed(false, now: 70_000), [])
        XCTAssertNil(tracker.nextDeadline)
        XCTAssertFalse(tracker.isShown)
    }

    func test_aRealBackgroundLongerThanTheDebounceHidesThenTheNextStartShows() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 1_000), [])
        XCTAssertEqual(tracker.nextDeadline, 2_500)
        XCTAssertEqual(tracker.tick(now: 2_499), [])
        XCTAssertEqual(tracker.tick(now: 2_500), [.hide])
        XCTAssertFalse(tracker.isShown)
        XCTAssertEqual(tracker.displayed(true, now: 9_000), [])
        XCTAssertEqual(tracker.tick(now: 9_350), [show(9_350)])
    }

    func test_aLongHideWhoseTickNeverRanIsAHideThenASettledShow() {
        // Deep sleep stalls the adapter's timer while the clock keeps
        // running: the hide is never reported by a tick.
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 1_000), [])
        XCTAssertEqual(tracker.displayed(true, now: 601_000), [.hide],
                       "the missed hide first, so a stale intent is dropped before the show")
        XCTAssertEqual(tracker.tick(now: 601_350), [show(601_350)])
        XCTAssertTrue(tracker.isShown)
        XCTAssertNil(tracker.nextDeadline, "nothing left to tick")
        XCTAssertEqual(tracker.displayed(true, now: 601_400), [])
    }

    func test_aLongLockWhoseTickNeverRanIsAShowAtUnlock() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 1_000), [])
        // Back from sleep behind the lock: no tick ran, the hide is reported
        // late, then the unlock is the show.
        XCTAssertEqual(tracker.displayed(false, now: 300_000), [.hide])
        XCTAssertEqual(tracker.displayed(true, now: 305_000), [])
        XCTAssertEqual(tracker.tick(now: 305_350), [show(305_350)])
    }

    func test_aBackgroundShorterThanTheDebounceIsTransparent() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 1_000), [])
        XCTAssertEqual(tracker.displayed(true, now: 2_200), [])
        XCTAssertNil(tracker.nextDeadline)
        XCTAssertEqual(tracker.tick(now: 10_000), [])
        XCTAssertTrue(tracker.isShown)
    }

    func test_aRecreationThatBrieflyComposesUndisplayedIsTransparent() {
        // Android filters the recreation's own stop; the new activity's first
        // composition can still be below STARTED, inside the debounce.
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 1_100), [])
        XCTAssertEqual(tracker.displayed(true, now: 1_400), [])
        XCTAssertEqual(tracker.tick(now: 30_000), [])
        XCTAssertTrue(tracker.isShown)
    }

    func test_aStopThatOutlivesItsExcursionsHidesAfterTheDebounce() {
        // Nested excursions keep the stop transparent until the last ends;
        // the adapter then reports a stop that is still in force.
        var tracker = shownTracker()
        XCTAssertEqual(tracker.transparentBegan(now: 1_000), [])
        XCTAssertEqual(tracker.transparentBegan(now: 5_000), [], "a nested interval keeps the first start")
        XCTAssertEqual(tracker.transparencyDeadline, 61_000)
        XCTAssertEqual(tracker.tick(now: 10_000), [])
        XCTAssertEqual(tracker.transparentEnded(now: 20_000), [])
        XCTAssertEqual(tracker.displayed(false, now: 20_000), [])
        XCTAssertEqual(tracker.tick(now: 21_500), [.hide])
    }

    func test_lockIsAHideAndUnlockIsAShow() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 1_000), [])
        XCTAssertEqual(tracker.displayed(false, now: 1_200), [])
        XCTAssertEqual(tracker.tick(now: 2_500), [.hide])
        XCTAssertEqual(tracker.displayed(false, now: 5_000), [])
        XCTAssertEqual(tracker.displayed(true, now: 8_000), [])
        XCTAssertEqual(tracker.tick(now: 8_350), [show(8_350)])
    }

    func test_aLockShorterThanTheDebounceIsTransparent() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 400), [])
        XCTAssertEqual(tracker.displayed(true, now: 1_000), [])
        XCTAssertEqual(tracker.tick(now: 5_000), [])
    }

    func test_switchingTabsAwayAndBackIsAHideThenAShow() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 400), [])
        XCTAssertEqual(tracker.tick(now: 1_900), [.hide])
        XCTAssertEqual(tracker.displayed(true, now: 4_000), [], "a sidebar selection is an ordinary show")
        XCTAssertEqual(tracker.tick(now: 4_350), [show(4_350)])
    }

    func test_anExplicitOpenIsAShowEvenWhileDisplayed() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.explicitOpen(now: 400), [])
        XCTAssertEqual(tracker.tick(now: 750), [explicitOpen(750)])
        XCTAssertEqual(tracker.tick(now: 5_000), [], "one explicit open, one show")
        XCTAssertEqual(tracker.explicitOpen(now: 6_000), [])
        XCTAssertEqual(tracker.tick(now: 6_350), [explicitOpen(6_350)])
    }

    func test_anExplicitOpenThatPresentsTheTabIsOneEdge() {
        var tracker = TmuxShowEdgeTracker()
        XCTAssertEqual(tracker.explicitOpen(now: 0), [])
        XCTAssertEqual(tracker.displayed(true, now: 0), [])
        XCTAssertEqual(tracker.tick(now: 350), [explicitOpen(350)])
        XCTAssertEqual(tracker.displayed(true, now: 400), [])
        XCTAssertEqual(tracker.tick(now: 5_000), [])
    }

    func test_anExplicitOpenWhileNotDisplayedWaitsForTheDisplay() {
        var tracker = TmuxShowEdgeTracker()
        XCTAssertEqual(tracker.displayed(false, now: 0), [])
        XCTAssertEqual(tracker.explicitOpen(now: 0), [])
        XCTAssertEqual(tracker.displayed(true, now: 50), [])
        XCTAssertEqual(tracker.tick(now: 400), [explicitOpen(400)])
    }

    func test_anExplicitOpenDuringAPendingHideKeepsTheTabShownAndReShows() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.displayed(false, now: 400), [])
        XCTAssertEqual(tracker.explicitOpen(now: 800), [])
        XCTAssertEqual(tracker.displayed(true, now: 800), [])
        XCTAssertTrue(tracker.isShown)
        XCTAssertEqual(tracker.tick(now: 1_150), [explicitOpen(1_150)])
        XCTAssertEqual(tracker.tick(now: 5_000), [])
    }

    func test_aThirtySecondPickerStaysTransparent() {
        var tracker = shownTracker()
        // Far past the 1.5 s hide debounce, well inside the cap.
        XCTAssertEqual(tracker.transparentBegan(now: 1_000), [])
        XCTAssertEqual(tracker.nextDeadline, 61_000)
        XCTAssertEqual(tracker.tick(now: 2_500), [])
        XCTAssertEqual(tracker.transparentEnded(now: 31_000), [])
        XCTAssertNil(tracker.nextDeadline)
        XCTAssertEqual(tracker.displayed(true, now: 31_100), [])
        XCTAssertTrue(tracker.isShown)
    }

    func test_anExcursionThatOutlastsItsBoundHidesAndTheReturnShows() {
        var tracker = shownTracker()
        // "Open with" is up, then the user goes Home from it for 61 s.
        XCTAssertEqual(tracker.transparentBegan(now: 1_000), [])
        XCTAssertEqual(tracker.nextDeadline, 61_000)
        XCTAssertEqual(tracker.tick(now: 60_999), [])
        XCTAssertEqual(tracker.tick(now: 61_000), [.hide], "back-dated to the stop")
        XCTAssertFalse(tracker.isShown)
        XCTAssertFalse(tracker.displayed, "displayed again only once the adapter says so")
        XCTAssertEqual(tracker.transparentEnded(now: 62_000), [])
        XCTAssertEqual(tracker.displayed(true, now: 62_050), [])
        XCTAssertEqual(tracker.tick(now: 62_400), [show(62_400)])
    }

    func test_aShortExcursionStaysTransparentEvenIfItsTickRunsLate() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.transparentBegan(now: 1_000), [])
        // Back from the picker 1 ms inside the bound; the tick then runs late.
        XCTAssertEqual(tracker.transparentEnded(now: 60_999), [])
        XCTAssertNil(tracker.nextDeadline)
        XCTAssertEqual(tracker.tick(now: 61_500), [])
        XCTAssertEqual(tracker.displayed(true, now: 61_600), [])
        XCTAssertTrue(tracker.isShown)

        // Or the return's composition is the first news of the start.
        var other = shownTracker()
        XCTAssertEqual(other.transparentBegan(now: 1_000), [])
        XCTAssertEqual(other.transparentEnded(now: 60_500), [])
        XCTAssertEqual(other.displayed(true, now: 60_500), [])
        XCTAssertEqual(other.tick(now: 120_000), [])
        XCTAssertTrue(other.isShown)
    }

    func test_anExcursionHideTheTickMissedIsDeliveredAtTheReturnAndItsDisplayShows() {
        var tracker = shownTracker()
        XCTAssertEqual(tracker.transparentBegan(now: 1_000), [])
        // Deep sleep: no tick ran. The end delivers the hide it missed.
        XCTAssertEqual(tracker.transparentEnded(now: 300_000), [.hide])
        XCTAssertNil(tracker.nextDeadline)
        XCTAssertEqual(tracker.displayed(true, now: 300_050), [])
        XCTAssertEqual(tracker.tick(now: 300_400), [show(300_400)])
    }

    func test_anExcursionHideIsDeliveredBeforeTheReturnShowWhateverReportsFirst() {
        // Android's `foldedHide`: one rule now, hide then settled show, even
        // when the return's display is the first news of the interval's end.
        var tracker = shownTracker()
        XCTAssertEqual(tracker.transparentBegan(now: 1_000), [])
        XCTAssertEqual(tracker.displayed(true, now: 300_000), [.hide],
                       "the cap ran out while transparent: a real background since 1 s")
        XCTAssertTrue(tracker.displayed, "the report after the cap is the return")
        XCTAssertNil(tracker.transparentSince)
        XCTAssertEqual(tracker.transparentEnded(now: 300_010), [], "already ended by its cap")
        XCTAssertEqual(tracker.tick(now: 300_350), [show(300_350)])
        XCTAssertNil(tracker.nextDeadline)
    }

    func test_aTransparentIntervalWithNothingShownChangesNothing() {
        // Android's "a configuration change is never an excursion" is an
        // adapter filter; here an interval over an unshown slot is inert.
        var tracker = TmuxShowEdgeTracker()
        XCTAssertEqual(tracker.transparentBegan(now: 1_000), [])
        XCTAssertEqual(tracker.tick(now: 61_000), [])
        XCTAssertFalse(tracker.isShown)
        XCTAssertNil(tracker.nextDeadline)
        var shown = shownTracker()
        XCTAssertEqual(shown.tick(now: 60_000), [])
        XCTAssertTrue(shown.isShown)
    }

    // MARK: iOS SessionShowEdgeTrackerTests, through one tracker per slot

    /// The iOS composition: one tracker per slot, displayed = foreground,
    /// unlocked and selected. Edges are collected hides first, as iOS
    /// emitted them.
    private struct Slots {
        enum Slot: String { case a, b, c }
        enum SlotEdge: Equatable, CustomStringConvertible {
            case show(Slot, TmuxShowEdgeTracker.ShowSource)
            case hide(Slot)
            var description: String {
                switch self {
                case .show(let slot, let source): return "show(\(slot), \(source))"
                case .hide(let slot): return "hide(\(slot))"
                }
            }
        }

        var trackers: [Slot: TmuxShowEdgeTracker] = [.a: .init(), .b: .init(), .c: .init()]
        var foreground = true
        var locked = false
        var selected: Slot?

        func displayed(_ slot: Slot) -> Bool { foreground && !locked && selected == slot }

        mutating func reconcile(now seconds: Double, explicitOpen: Slot? = nil) -> [SlotEdge] {
            let now = Int64((seconds * 1_000).rounded())
            var hides: [SlotEdge] = []
            var shows: [SlotEdge] = []
            for slot in [Slot.a, .b, .c] {
                guard var tracker = trackers[slot] else { continue }
                var edges = tracker.displayed(displayed(slot), now: now)
                if explicitOpen == slot { edges += tracker.explicitOpen(now: now) }
                trackers[slot] = tracker
                for edge in edges {
                    switch edge {
                    case .hide: hides.append(.hide(slot))
                    case .show(let source, let stepAt):
                        XCTAssertEqual(stepAt, now)
                        shows.append(.show(slot, source))
                    }
                }
            }
            return hides + shows
        }

        mutating func select(_ slot: Slot?, now: Double) -> [SlotEdge] {
            selected = slot
            return reconcile(now: now)
        }

        mutating func setForeground(_ value: Bool, now: Double) -> [SlotEdge] {
            foreground = value
            return reconcile(now: now)
        }

        mutating func setLocked(_ value: Bool, now: Double) -> [SlotEdge] {
            locked = value
            return reconcile(now: now)
        }

        mutating func open(_ slot: Slot, now: Double) -> [SlotEdge] {
            reconcile(now: now, explicitOpen: slot)
        }

        mutating func tick(now: Double) -> [SlotEdge] { reconcile(now: now) }

        /// Replacing the session object behind a slot keeps the slot's
        /// tracker: the adapter renames it, and nothing is emitted.
        mutating func replace(_ old: Slot, with new: Slot) {
            trackers[new] = trackers.removeValue(forKey: old)
            if selected == old { selected = new }
        }

        mutating func remove(_ slot: Slot) { trackers[slot] = nil }

        var nextDeadline: Int64? { trackers.values.compactMap(\.nextDeadline).min() }
        var shownSlots: Set<Slot> { Set(trackers.filter { $0.value.isShown }.map(\.key)) }
        var slotsAwaitingHide: Set<Slot> { Set(trackers.filter { $0.value.hideDue != nil }.map(\.key)) }
    }

    private func slotsShowing(_ slot: Slots.Slot) -> Slots {
        var slots = Slots()
        XCTAssertEqual(slots.select(slot, now: 0), [])
        XCTAssertEqual(slots.tick(now: 0.35), [.show(slot, .show)])
        return slots
    }

    func test_ios_selectingASessionShowsItAfterTheSettle() {
        var slots = Slots()
        XCTAssertEqual(slots.select(.a, now: 0), [], "a show waits for routing to settle")
        XCTAssertEqual(slots.nextDeadline, 350)
        XCTAssertEqual(slots.tick(now: 0.2), [])
        XCTAssertEqual(slots.tick(now: 0.35), [.show(.a, .show)])
        XCTAssertEqual(slots.tick(now: 5), [], "one show per displayed interval")
    }

    func test_ios_inactiveWithoutBackgroundIsTransparent() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.setForeground(true, now: 3), [])
        XCTAssertNil(slots.nextDeadline)
        XCTAssertEqual(slots.tick(now: 10), [])
    }

    func test_ios_backgroundThenForegroundIsAShow() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.setForeground(false, now: 10), [])
        // Suspended: the debounce tick never ran. The wake emits the hide
        // first, then shows again once settled.
        XCTAssertEqual(slots.setForeground(true, now: 60), [.hide(.a)])
        XCTAssertEqual(slots.tick(now: 60.35), [.show(.a, .show)])
    }

    func test_ios_backgroundHideFiresAfterTheDebounceWhenTheTickRuns() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.setForeground(false, now: 10), [])
        XCTAssertEqual(slots.nextDeadline, 11_500)
        XCTAssertEqual(slots.tick(now: 11.5), [.hide(.a)])
        XCTAssertEqual(slots.setForeground(true, now: 30), [])
        XCTAssertEqual(slots.tick(now: 30.35), [.show(.a, .show)])
    }

    func test_ios_hiddenIntervalShorterThanTheDebounceIsTransparent() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.setForeground(false, now: 10), [])
        XCTAssertEqual(slots.setForeground(true, now: 11), [])
        XCTAssertEqual(slots.tick(now: 20), [], "a sub-1.5 s app switch is neither a hide nor a show")
        XCTAssertEqual(slots.select(nil, now: 30), [])
        XCTAssertEqual(slots.select(.a, now: 31.4), [])
        XCTAssertEqual(slots.tick(now: 40), [], "Agent Center and back within the debounce is transparent")
    }

    func test_ios_lockHidesAndUnlockShows() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.setLocked(true, now: 5), [])
        XCTAssertEqual(slots.tick(now: 6.5), [.hide(.a)])
        XCTAssertEqual(slots.setLocked(false, now: 20), [], "the unlock show settles like any other")
        XCTAssertEqual(slots.tick(now: 20.35), [.show(.a, .show)])
    }

    func test_ios_noShowFiresBehindTheLock() {
        var slots = slotsShowing(.a)
        _ = slots.setForeground(false, now: 10)
        _ = slots.setLocked(true, now: 10.1)
        XCTAssertEqual(slots.setForeground(true, now: 60), [.hide(.a)])
        XCTAssertEqual(slots.tick(now: 61), [], "nothing may claim behind the lock")
        XCTAssertEqual(slots.select(.b, now: 62), [])
        XCTAssertEqual(slots.tick(now: 63), [])
        XCTAssertEqual(slots.setLocked(false, now: 70), [])
        XCTAssertEqual(slots.tick(now: 70.35), [.show(.b, .show)], "the falling edge of the lock is the show")
    }

    func test_ios_sidebarSwitchHidesTheOldSessionAndShowsTheNewOne() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.select(.b, now: 5), [])
        XCTAssertEqual(slots.tick(now: 5.35), [.show(.b, .show)])
        XCTAssertEqual(slots.tick(now: 6.5), [.hide(.a)])
        XCTAssertEqual(slots.slotsAwaitingHide, [])
    }

    func test_ios_flickingThroughTabsShowsOnlyWhereItSettles() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.select(.b, now: 5), [])
        XCTAssertEqual(slots.select(.c, now: 5.1), [])
        XCTAssertEqual(slots.tick(now: 5.45), [.show(.c, .show)])
        XCTAssertEqual(slots.tick(now: 7), [.hide(.a)])
        XCTAssertEqual(slots.tick(now: 30), [], "the tab flicked past never received a show, so it gets no hide")
    }

    func test_ios_hiddenBackgroundTabsNeverReceiveAShow() {
        var slots = slotsShowing(.a)
        for second in 1...10 {
            XCTAssertEqual(slots.tick(now: Double(second)), [])
        }
        XCTAssertEqual(slots.shownSlots, [.a])
    }

    func test_ios_explicitOpenOfTheDisplayedSessionShowsAgain() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.open(.a, now: 10), [])
        XCTAssertEqual(slots.tick(now: 10.35), [.show(.a, .explicitOpen)])
        XCTAssertEqual(slots.tick(now: 20), [], "one explicit open, one show")
    }

    func test_ios_explicitOpenFollowsItsRoutingToTheTargetSession() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.open(.b, now: 10), [], "Handoff receipt lands before the selection")
        XCTAssertEqual(slots.tick(now: 10.35), [], "the session on screen is not the target")
        XCTAssertEqual(slots.select(.b, now: 11), [])
        XCTAssertEqual(slots.tick(now: 11.35), [.show(.b, .explicitOpen)])
    }

    func test_ios_explicitOpenExpiresWhenItsSessionNeverAppears() {
        var slots = slotsShowing(.a)
        _ = slots.open(.b, now: 10)
        XCTAssertEqual(slots.tick(now: 13), [])
        XCTAssertEqual(slots.select(.b, now: 20), [])
        XCTAssertEqual(slots.tick(now: 20.35), [.show(.b, .show)])
    }

    func test_ios_explicitOpenWithinTheDebounceStillShows() {
        var slots = slotsShowing(.a)
        _ = slots.select(nil, now: 10)
        _ = slots.open(.a, now: 10.5)
        XCTAssertEqual(slots.select(.a, now: 10.6), [])
        XCTAssertEqual(slots.tick(now: 10.95), [.show(.a, .explicitOpen)],
                       "a transparent return does not swallow an explicit open")
    }

    func test_ios_replacingTheSessionInTheSameSlotIsTransparent() {
        var slots = slotsShowing(.a)
        slots.trackers[.b] = nil
        slots.replace(.a, with: .b)
        XCTAssertEqual(slots.select(.b, now: 5), [])
        XCTAssertEqual(slots.tick(now: 10), [], "foreground restore and mosh rebuilds are not shows")
        XCTAssertEqual(slots.shownSlots, [.b])
        XCTAssertEqual(slots.setForeground(false, now: 20), [])
        XCTAssertEqual(slots.tick(now: 21.5), [.hide(.b)], "the replacement inherits the shown slot")
    }

    func test_ios_replacementDuringTheHideDebounceCarriesTheDebounce() {
        var slots = slotsShowing(.a)
        _ = slots.setForeground(false, now: 10)
        slots.trackers[.b] = nil
        slots.replace(.a, with: .b)
        XCTAssertEqual(slots.setForeground(true, now: 10.5), [])
        XCTAssertEqual(slots.tick(now: 20), [])
        XCTAssertEqual(slots.shownSlots, [.b])
    }

    func test_ios_closingTheShownSessionEmitsNothing() {
        var slots = slotsShowing(.a)
        slots.remove(.a)
        XCTAssertEqual(slots.select(nil, now: 5), [])
        XCTAssertEqual(slots.tick(now: 10), [])
    }

    /// iOS coordinator L1: the wake reads the one sleep-inclusive clock,
    /// which has run past the debounce, so the wake delivers the hide, then
    /// the show. An uptime clock would make it look like a 0 s interruption.
    func test_ios_wakeAfterASleepPastTheDebounceDeliversHideThenShow() {
        for countsSleep in [true, false] {
            var slots = slotsShowing(.a)
            XCTAssertEqual(slots.setForeground(false, now: 0.35), [])
            let wake = countsSleep ? 600.35 : 0.35
            let edges = slots.setForeground(true, now: wake) + slots.tick(now: wake + 0.35)
            if countsSleep {
                XCTAssertEqual(edges, [.hide(.a), .show(.a, .show)])
            } else {
                XCTAssertEqual(edges, [], "an uptime clock makes a long sleep look transparent")
            }
        }
    }

    func test_ios_backgroundAndLockedForegroundNeverReachTheController() {
        var slots = slotsShowing(.a)
        XCTAssertEqual(slots.setForeground(false, now: 0.35), [])
        XCTAssertEqual(slots.setLocked(true, now: 0.35), [])
        XCTAssertEqual(slots.setForeground(true, now: 30.35), [.hide(.a)])
        XCTAssertEqual(slots.tick(now: 31.35), [])
        XCTAssertEqual(slots.setLocked(false, now: 31.35), [])
        XCTAssertEqual(slots.tick(now: 31.7), [.show(.a, .show)])
    }

    /// The tracker is a value: a no-op input leaves it equal, so adapters
    /// can skip publishing on an unchanged tracker.
    func test_unchangedInputsLeaveTheTrackerEqual() {
        var tracker = shownTracker()
        let before = tracker
        XCTAssertEqual(tracker.displayed(true, now: 1_000), [])
        XCTAssertEqual(tracker.tick(now: 2_000), [])
        XCTAssertEqual(tracker, before)
    }
}

extension TmuxShowEdgeTracker {
    /// When an open transparent interval would turn into a background.
    var transparencyDeadline: Int64? {
        transparentSince.map { $0 + timing.transparencyCapMillis }
    }
}
