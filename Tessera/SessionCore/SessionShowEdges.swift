import Foundation
import SwiftUI
import TmuxControl

/// The object a session view registers so show/hide edges and prompt pauses
/// reach its tmux controller. `TmuxController` is the only production
/// conformer; tests use a recorder.
@MainActor
protocol SessionShowTarget: AnyObject {
    /// `intentElapsed`: how much of the R3 window the user's step already
    /// used before reaching this controller (a carried or late-registered
    /// show). The window runs from the step, not from delivery.
    func gridAuthorityShown(
        source: TmuxGridAuthorityLifecycleReducer.ShowSource,
        intentElapsed: TimeInterval
    )
    func gridAuthorityHidden()
    func gridAuthorityAdoptShown()
    func setGridAuthorityIntentClockPaused(_ paused: Bool)
    func setGridAuthorityPromptState(session: Bool, connect: Bool)
    func noteGridAuthorityUserStep()
    var gridAuthorityPendingIntentSource: TmuxGridAuthorityLifecycleReducer.IntentSource? { get }
    var gridAuthorityIntentElapsed: TimeInterval? { get }
    /// A connect-path prompt (host key, Face ID) belongs to a connecting
    /// session; one whose control channel is live is not waiting on it.
    var gridAuthorityChannelIsLive: Bool { get }
}

extension SessionShowTarget {
    // Older targets already started visible. The shared-session adapter
    // explicitly adopts this existing visibility without a new gesture.
    func gridAuthorityAdoptShown() {}

    // Compatibility for targets that consume the effective pause rather than
    // the shared authority session's two independently tracked prompt scopes.
    func setGridAuthorityPromptState(session: Bool, connect: Bool) {
        setGridAuthorityIntentClockPaused(session || (connect && !gridAuthorityChannelIsLive))
    }
}

extension TmuxController: SessionShowTarget {}

/// Main-actor owner of one core show-edge tracker per live session slot.
/// ContentView feeds it foreground, lock and selection facts plus opens and
/// replacements; session views register their controllers by live session
/// id. Edges reach a controller as soon as it is registered, so a show that
/// lands before the view mounts is delivered when it does.
@MainActor
final class SessionShowCoordinator {
    private final class WeakTarget {
        weak var target: (any SessionShowTarget)?
        init(_ target: any SessionShowTarget) { self.target = target }
    }

    /// A show that has not reached its controller yet. The user's step
    /// happened at `capturedAt` (minus `elapsedAtCapture` already used on a
    /// replaced controller), so its R3 window keeps running meanwhile.
    private struct UndeliveredShow {
        var source: TmuxShowEdgeTracker.ShowSource
        var elapsedAtCapture: TimeInterval
        var capturedAt: TimeInterval
    }

    private var trackers: [UUID: TmuxShowEdgeTracker] = [:]
    private let timing: TmuxShowEdgeTracker.Timing
    private var appForeground: Bool
    private var locked: Bool
    private var selectedSlot: UUID?
    private var targets: [UUID: WeakTarget] = [:]
    /// Shows emitted for a slot whose controller has not registered yet, and
    /// intents carried from a replaced controller to its successor.
    private var undelivered: [UUID: UndeliveredShow] = [:]
    private var challengePresented: Set<UUID> = []
    private var globalPromptActive = false
    private var tickTask: Task<Void, Never>?
    private let clock: () -> TimeInterval
    private let log: (String) -> Void

    /// Seconds on a clock that keeps running while the device sleeps:
    /// `CLOCK_MONOTONIC_RAW` is `mach_continuous_time`, the source of Swift's
    /// `ContinuousClock` (which the controller's intent deadline uses).
    /// `systemUptime` stops during sleep, so a hide debounce that ran out
    /// while the phone slept would otherwise still be pending on wake and
    /// swallow the hide + show. (`CLOCK_MONOTONIC` is a slewed clock with
    /// its own origin on Darwin, not `mach_continuous_time`.)
    static func continuousSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    init(
        appForeground: Bool,
        locked: Bool,
        timing: TmuxShowEdgeTracker.Timing = .init(),
        clock: @escaping () -> TimeInterval = SessionShowCoordinator.continuousSeconds,
        log: @escaping (String) -> Void = { DiagnosticLogStore.appendSSH($0) }
    ) {
        self.appForeground = appForeground
        self.locked = locked
        self.timing = timing
        self.clock = clock
        self.log = log
    }

    deinit { tickTask?.cancel() }

    var displayedSlot: UUID? { appForeground && !locked ? selectedSlot : nil }

    /// Round at the boundary so floating-point sums such as 600 + 0.35 +
    /// 0.35 do not turn an exact millisecond deadline into one millisecond
    /// before it. Every core input uses this same sleep-inclusive clock.
    private func nowMillis() -> Int64 {
        Int64((clock() * 1_000).rounded())
    }

    private func ensureTracker(for slot: UUID) {
        if trackers[slot] == nil { trackers[slot] = TmuxShowEdgeTracker(timing: timing) }
    }

    private typealias SlotEdge = (slot: UUID, edge: TmuxShowEdgeTracker.Edge)

    /// Report the old selection as not displayed before the new selection
    /// is displayed. App facts live here; the edge rule lives in the core.
    private func reportDisplayed(now: Int64) -> [SlotEdge] {
        var edges: [SlotEdge] = []
        for displayed in [false, true] {
            for slot in Array(trackers.keys) {
                guard var tracker = trackers[slot],
                      (displayedSlot == slot) == displayed,
                      tracker.displayed != displayed else { continue }
                edges += tracker.displayed(displayed, now: now).map { (slot, $0) }
                trackers[slot] = tracker
            }
        }
        return edges
    }

    private func tickDue(now: Int64) -> [SlotEdge] {
        var edges: [SlotEdge] = []
        for slot in Array(trackers.keys) {
            guard var tracker = trackers[slot],
                  let deadline = tracker.nextDeadline, deadline <= now else { continue }
            edges += tracker.tick(now: now).map { (slot, $0) }
            trackers[slot] = tracker
        }
        return edges
    }

    private func appFactsChanged() {
        let now = nowMillis()
        let edges = reportDisplayed(now: now)
        // A wake behind the lock leaves displayed false, but still owes any
        // hide whose debounce elapsed while the app was asleep.
        apply(edges + tickDue(now: now))
    }

    // MARK: App facts

    #if DEBUG
    /// Transitions of the foreground fact, for the cold-launch UI test.
    private(set) var appForegroundChangesForTesting = 0
    var appFactsForTesting: String {
        "foreground=\(appForeground) locked=\(locked) foregroundChanges=\(appForegroundChangesForTesting)"
    }
    #endif

    func setAppForeground(_ foreground: Bool) {
        guard appForeground != foreground else { return }
        appForeground = foreground
        #if DEBUG
        appForegroundChangesForTesting += 1
        #endif
        log("grid-authority show-edge app-facts foreground=\(foreground) locked=\(locked) reason=foreground")
        appFactsChanged()
    }

    func setLocked(_ locked: Bool) {
        guard self.locked != locked else { return }
        self.locked = locked
        log("grid-authority show-edge app-facts foreground=\(appForeground) locked=\(locked) reason=lock")
        appFactsChanged()
    }

    func setSelectedSlot(_ slot: UUID?) {
        guard selectedSlot != slot else { return }
        selectedSlot = slot
        if let slot { ensureTracker(for: slot) }
        appFactsChanged()
    }

    func explicitOpen(_ slot: UUID) {
        log("grid-authority show-edge explicit-open slot=\(slot.uuidString.prefix(8))")
        ensureTracker(for: slot)
        let now = nowMillis()
        var edges = reportDisplayed(now: now)
        if var tracker = trackers[slot] {
            edges += tracker.explicitOpen(now: now).map { (slot, $0) }
            trackers[slot] = tracker
        }
        apply(edges + tickDue(now: now))
    }

    /// Carries the slot (and any unresolved show) from a replaced session
    /// object to its successor without emitting an edge.
    ///
    /// Only a show or an explicit open is carried, with the part of its R3
    /// window it has left. A tap is not: it was bound to the veil of a
    /// connection that no longer exists, and turning it into a show would
    /// claim a session the user only tapped once. The replaced controller
    /// gets a hide, so its intent cannot resolve on a late reply either.
    ///
    /// A successor that registered before the replacement (a foreground
    /// restore reusing a live duplicate) was registered hidden, as an
    /// off-screen tab. Renaming the shown slot onto it adopts that visibility;
    /// without adoption it would stay hidden on screen. A settled replacement
    /// is transparent (R5), so only an unresolved show carries its gesture.
    func replaceSlot(_ old: UUID, with new: UUID) {
        guard old != new else { return }
        let newTarget = targets[new]?.target
        // The displayed slot's state wins over a successor that already
        // registered as an off-screen tab. Renaming emits no core edge. An
        // explicit open the successor was still waiting for stays its own:
        // it is re-armed below on the renamed tracker.
        let now = nowMillis()
        var successorOpenPending = false
        if let tracker = trackers.removeValue(forKey: old) {
            if let until = trackers[new]?.explicitOpenUntil, until > now, tracker.explicitOpenUntil == nil {
                successorOpenPending = true
            }
            trackers[new] = tracker
        }
        if selectedSlot == old { selectedSlot = new }
        let oldTarget = targets[old]?.target
        if let carried = undelivered.removeValue(forKey: old) {
            undelivered[new] = carried
        } else if let oldTarget,
                  let source = oldTarget.gridAuthorityPendingIntentSource,
                  source != .tap {
            undelivered[new] = UndeliveredShow(
                source: source == .explicitOpen ? .explicitOpen : .show,
                elapsedAtCapture: oldTarget.gridAuthorityIntentElapsed ?? 0,
                capturedAt: clock()
            )
        }
        oldTarget?.gridAuthorityHidden()
        if challengePresented.remove(old) != nil {
            challengePresented.insert(new)
            updatePause(new)
        }
        log("grid-authority show-edge replace old=\(old.uuidString.prefix(8)) new=\(new.uuidString.prefix(8)) carried=\(undelivered[new]?.source.rawValue ?? "none") registered=\(newTarget != nil)")
        // Replacement adopts the currently shown selection; an off-screen
        // slot whose hide is debouncing only counts as shown at registration.
        if undelivered[new] == nil,
           trackers[new]?.shown == true,
           let newTarget,
           newTarget !== oldTarget {
            log("grid-authority show-edge adopt slot=\(new.uuidString.prefix(8)) reason=replaced-onto-registered")
            newTarget.gridAuthorityAdoptShown()
        }
        deliverUndelivered(to: new)
        // Re-armed from now (the core keeps no way to restore its original
        // expiry): the open shows once it settles, as it would have on its
        // own slot, rather than lapsing unseen behind the rename.
        if successorOpenPending, var tracker = trackers[new] {
            let edges = tracker.explicitOpen(now: now).map { (new, $0) }
            trackers[new] = tracker
            apply(edges)
        } else {
            scheduleTick()
        }
    }

    func removeSlot(_ slot: UUID) {
        trackers[slot] = nil
        undelivered[slot] = nil
        challengePresented.remove(slot)
        scheduleTick()
    }

    // MARK: Prompts (R3 intent clock)

    /// A user step that keeps the session's pending show alive (Retry): its
    /// R3 window restarts, delivered or not.
    func noteUserStep(for slot: UUID) {
        if var pending = undelivered[slot] {
            pending.elapsedAtCapture = 0
            pending.capturedAt = clock()
            undelivered[slot] = pending
        }
        targets[slot]?.target?.noteGridAuthorityUserStep()
    }

    /// A connect-path prompt the user is answering (host key, Face ID). The
    /// user's step is still in progress, so no connecting session's intent
    /// may expire under it. A session whose channel is already live is not
    /// waiting on that prompt and keeps its clock.
    func setGlobalPromptActive(_ active: Bool) {
        guard globalPromptActive != active else { return }
        globalPromptActive = active
        for slot in targets.keys { updatePause(slot) }
    }

    /// A per-session password/OTP challenge.
    func setChallengePresented(_ presented: Bool, for slot: UUID) {
        if presented { challengePresented.insert(slot) } else { challengePresented.remove(slot) }
        updatePause(slot)
    }

    // MARK: Registration

    func register(_ target: any SessionShowTarget, for slot: UUID) {
        ensureTracker(for: slot)
        let isNewTarget = targets[slot]?.target !== target
        if isNewTarget {
            targets[slot] = WeakTarget(target)
        }
        updatePause(slot)
        if isNewTarget,
           undelivered[slot] == nil,
           trackers[slot]?.isShown != true {
            // Not on screen (a restored background tab, or a displayed slot
            // whose show is still settling): the controller starts hidden,
            // so a peer is not drawn as a veil before its show decides.
            log("grid-authority show-edge register-hidden slot=\(slot.uuidString.prefix(8))")
            target.gridAuthorityHidden()
        }
        if isNewTarget, undelivered[slot] == nil,
           trackers[slot]?.isShown == true {
            target.gridAuthorityAdoptShown()
        }
        deliverUndelivered(to: slot)
    }

    func unregister(_ target: any SessionShowTarget, for slot: UUID) {
        guard targets[slot]?.target === target else { return }
        targets[slot] = nil
    }

    // MARK: Delivery

    private func apply(_ edges: [SlotEdge]) {
        // Independent trackers may settle and hide in the same late tick.
        // Preserve each tracker's edge order, with all hides before shows.
        let hides = edges.filter {
            if case .hide = $0.edge { return true }
            return false
        }
        let shows = edges.filter {
            if case .show = $0.edge { return true }
            return false
        }
        for (slot, edge) in hides + shows {
            switch edge {
            case .hide:
                undelivered[slot] = nil
                log("grid-authority show-edge hide slot=\(slot.uuidString.prefix(8))")
                targets[slot]?.target?.gridAuthorityHidden()
            case .show(let source, let stepAt):
                log("grid-authority show-edge show slot=\(slot.uuidString.prefix(8)) source=\(source.rawValue) registered=\(targets[slot]?.target != nil)")
                let pending = UndeliveredShow(
                    source: source,
                    elapsedAtCapture: 0,
                    capturedAt: TimeInterval(stepAt) / 1_000
                )
                if let target = targets[slot]?.target {
                    undelivered[slot] = nil
                    target.gridAuthorityShown(source: source, intentElapsed: elapsed(pending, for: slot))
                } else {
                    undelivered[slot] = pending
                }
            }
        }
        // A slot back on screen within its debounce was never hidden: a show
        // held while its controller registered off screen is now delivered.
        if let displayed = displayedSlot { deliverUndelivered(to: displayed) }
        scheduleTick()
    }

    private func deliverUndelivered(to slot: UUID) {
        // Shown, not merely debouncing: a slot waiting out its hide is off
        // screen (behind the lock, or past a missed deadline), and a show
        // delivered there could claim the grid for a session nobody sees.
        // Its hide clears the held show; a return within the debounce
        // delivers it.
        guard let pending = undelivered[slot],
              trackers[slot]?.shown == true,
              let target = targets[slot]?.target
        else { return }
        undelivered[slot] = nil
        // A prompt on screen pauses the clock, and answering it restarts the
        // full window; otherwise the window kept running since the step.
        let elapsed = elapsed(pending, for: slot)
        log("grid-authority show-edge deliver slot=\(slot.uuidString.prefix(8)) source=\(pending.source.rawValue) elapsed=\(String(format: "%.2f", elapsed))")
        target.gridAuthorityShown(source: pending.source, intentElapsed: elapsed)
    }

    private func elapsed(_ pending: UndeliveredShow, for slot: UUID) -> TimeInterval {
        isPaused(slot) ? 0 : pending.elapsedAtCapture + max(0, clock() - pending.capturedAt)
    }

    private func isPaused(_ slot: UUID) -> Bool {
        if challengePresented.contains(slot) { return true }
        guard globalPromptActive else { return false }
        return targets[slot]?.target?.gridAuthorityChannelIsLive != true
    }

    private func updatePause(_ slot: UUID) {
        targets[slot]?.target?.setGridAuthorityPromptState(
            session: challengePresented.contains(slot), connect: globalPromptActive
        )
    }

    private func scheduleTick() {
        tickTask?.cancel()
        tickTask = nil
        guard let deadline = trackers.values.compactMap(\.nextDeadline).min() else { return }
        let delay = max(0, TimeInterval(deadline) / 1_000 - clock())
        tickTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.tickTask = nil
            self.apply(self.tickDue(now: self.nowMillis()))
        }
    }

    #if DEBUG
    /// Deterministic seam for unit tests that drive the clock by hand.
    func tickForTesting() {
        apply(tickDue(now: nowMillis()))
    }
    #endif
}

extension Notification.Name {
    /// `SSHHandshakePromptGate` went between idle and prompting (a host-key
    /// decision or a Face ID sheet in the connect path).
    static let tesseraHandshakePromptChanged = Notification.Name(
        "Tessera.HandshakePromptChanged"
    )
}

private struct SessionShowCoordinatorKey: EnvironmentKey {
    static let defaultValue: SessionShowCoordinator? = nil
}

extension EnvironmentValues {
    /// Nil outside `ContentView` (previews, harnesses): no show edges.
    var sessionShowCoordinator: SessionShowCoordinator? {
        get { self[SessionShowCoordinatorKey.self] }
        set { self[SessionShowCoordinatorKey.self] = newValue }
    }
}
