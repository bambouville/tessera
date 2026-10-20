import Foundation

/// The show rule's edge detector for one presentation slot (an iPad/iPhone
/// session tab, an Android host tab), per §6.9 of
/// `docs/reviews/takeover-authority-review-2026-10-05.md` (S2′), identical on
/// both platforms.
///
/// The adapter reports *displayed*: its session is the presented slot, the
/// app is in the foreground and the app lock is not up. What counts as each
/// of those stays per platform (iOS background/foreground edges and
/// selection; Android's start-epoch filter and `isRealBackgroundEdge`).
///
/// - A **show** is displayed going false→true, or an explicit open of the
///   slot (even while it is already displayed). It waits `showSettle` first,
///   so flicking through tabs never claims every session it passes, and an
///   explicit open is evaluated after its routing has landed. A show that
///   leaves the screen before it settles never happened.
/// - A **hide** is displayed going true→false for at least `hideDebounce`.
///   A shorter interval was never hidden: neither the hide nor the show is
///   emitted.
/// - A return after the debounce ran out with no tick to report it (the
///   device slept; the clock keeps running) emits the hide at once, then
///   the show after the normal settle. One rule, so the receiver always sees
///   the hide before that show.
/// - An explicit open waits up to `explicitOpenWindow` for its slot to be
///   displayed, then lapses.
/// - A **transparent interval** (Android: one of Tessera's own excursions,
///   a picker, "Open with", a credential prompt) neither hides nor shows
///   while it lasts. One that outlasts `transparencyCap` became a real
///   background (the user left from the picker): the hide is back-dated to
///   when the interval began and reported at once, and the slot is no
///   longer displayed until the adapter reports it again.
/// - Replacing the session object behind a slot is invisible here: the
///   adapter keeps one tracker per slot and renames it.
///
/// A slot starts not displayed and not shown. All times are milliseconds
/// on one clock that keeps running while the device sleeps; the tracker
/// owns no timer, and the adapter calls `tick` at `nextDeadline`.
///
/// Adapter contract (shared with `TmuxGridAuthoritySession`):
///
/// - **On wake, the tracker first.** Report `displayed(_:now:)` and call
///   `tick(now:)`, and deliver the edges they return to the session, before
///   any session event of the wake (foreground, channel liveness, attach, a
///   read's reply). The hide a sleep owed must drop a pending show before the
///   wake's read can resolve it into a claim behind a lock screen.
/// - **No `displayed(false)` inside a transparent interval.** Between
///   `transparentBegan` and `transparentEnded` the slot counts as displayed;
///   the cap, not a not-displayed report, ends that.
/// - **`displayed(true)` again after the cap.** A cap that ran out leaves the
///   slot not displayed until the adapter reports it, so the return from a
///   long excursion is a show like any other.
public struct TmuxShowEdgeTracker: Equatable, Sendable {
    public typealias ShowSource = TmuxGridAuthorityLifecycleReducer.ShowSource

    public struct Timing: Equatable, Sendable {
        /// A hidden interval shorter than this is transparent.
        public var hideDebounceMillis: Int64
        /// A show waits this long for routing and tab flicks to settle.
        public var showSettleMillis: Int64
        /// How long an explicit open waits for its slot to be displayed.
        public var explicitOpenWindowMillis: Int64
        /// How long a transparent interval stays transparent.
        public var transparencyCapMillis: Int64

        public init(
            hideDebounceMillis: Int64 = 1_500,
            showSettleMillis: Int64 = 350,
            explicitOpenWindowMillis: Int64 = 3_000,
            transparencyCapMillis: Int64 = 60_000
        ) {
            self.hideDebounceMillis = hideDebounceMillis
            self.showSettleMillis = showSettleMillis
            self.explicitOpenWindowMillis = explicitOpenWindowMillis
            self.transparencyCapMillis = transparencyCapMillis
        }
    }

    public enum Edge: Equatable, Sendable {
        case hide
        /// `stepAt` is when the show was emitted: the user's step that the
        /// session's R3 window runs from.
        case show(source: ShowSource, stepAt: Int64)
    }

    private struct PendingShow: Equatable, Sendable {
        var source: ShowSource
        var due: Int64
    }

    public let timing: Timing
    /// Displayed as last reported (and cleared by a transparency that
    /// outlasted its cap).
    public private(set) var displayed = false
    /// The last edge emitted was a show, or a hide is still debouncing.
    public private(set) var shown = false
    /// When a debouncing hide becomes an edge.
    public private(set) var hideDue: Int64?
    /// Until when an explicit open waits for the slot to be displayed.
    public private(set) var explicitOpenUntil: Int64?
    /// Since when a transparent interval is in force.
    public private(set) var transparentSince: Int64?
    private var pendingShow: PendingShow?

    public init(timing: Timing = .init()) {
        self.timing = timing
    }

    /// Whether the slot counts as shown from its session's point of view: a
    /// show was emitted and no hide has been (a debouncing hide still
    /// counts as shown).
    public var isShown: Bool { shown || hideDue != nil }

    /// A show is settling.
    public var showPending: Bool { pendingShow != nil }

    /// The earliest instant at which `tick` has work to do.
    public var nextDeadline: Int64? {
        var deadline = hideDue
        func consider(_ candidate: Int64?) {
            guard let candidate else { return }
            deadline = deadline.map { min($0, candidate) } ?? candidate
        }
        consider(pendingShow?.due)
        consider(explicitOpenUntil)
        consider(transparentSince.map { $0.clampedAdding(timing.transparencyCapMillis) })
        return deadline
    }

    public mutating func displayed(_ displayed: Bool, now: Int64) -> [Edge] {
        // A transparency that ran out before this report was a background
        // first; this report is then the return.
        expireTransparency(now: now)
        self.displayed = displayed
        return reconcile(now: now)
    }

    /// An explicit open that targets this slot (Handoff/QR receipt, Agent
    /// Center's open-terminal, a notification route, reopening a saved host
    /// that already has a live session). Shows even if already displayed.
    public mutating func explicitOpen(now: Int64) -> [Edge] {
        explicitOpenUntil = now.clampedAdding(timing.explicitOpenWindowMillis)
        return reconcile(now: now)
    }

    /// A transparent interval began. A nested one keeps the earliest start.
    public mutating func transparentBegan(now: Int64) -> [Edge] {
        if transparentSince == nil { transparentSince = now }
        return reconcile(now: now)
    }

    /// The transparent interval ended. Within the cap it changed nothing;
    /// past it (no tick ran to notice, as in deep sleep) its hide is
    /// reported now, and the slot waits for a fresh displayed report.
    public mutating func transparentEnded(now: Int64) -> [Edge] {
        if let since = transparentSince {
            transparentSince = nil
            if now.clampedSubtracting(since) >= timing.transparencyCapMillis { becomeBackground(since: since) }
        }
        return reconcile(now: now)
    }

    public mutating func tick(now: Int64) -> [Edge] {
        reconcile(now: now)
    }

    /// A transparent interval that outlasted its cap was a real background
    /// from its start.
    private mutating func becomeBackground(since: Int64) {
        displayed = false
        if shown {
            shown = false
            let due = since.clampedAdding(timing.hideDebounceMillis)
            hideDue = hideDue.map { min($0, due) } ?? due
        }
    }

    private mutating func expireTransparency(now: Int64) {
        guard let since = transparentSince, now.clampedSubtracting(since) >= timing.transparencyCapMillis else { return }
        transparentSince = nil
        becomeBackground(since: since)
    }

    private mutating func reconcile(now: Int64) -> [Edge] {
        expireTransparency(now: now)
        if let until = explicitOpenUntil, until <= now { explicitOpenUntil = nil }

        var edges: [Edge] = []
        // A hide whose debounce ran out (possibly while the device slept) is
        // emitted first: a slot that comes back after the debounce shows
        // again, and its session always sees the hide before that show.
        if let due = hideDue, due <= now {
            hideDue = nil
            edges.append(.hide)
        }
        // A shown slot that is no longer displayed starts its debounce.
        if shown, !displayed {
            shown = false
            hideDue = now.clampedAdding(timing.hideDebounceMillis)
        }
        // A settling show for a slot that left the screen never happened.
        if pendingShow != nil, !displayed { pendingShow = nil }

        if displayed {
            if hideDue != nil {
                // Back within the debounce: it was never hidden.
                hideDue = nil
                shown = true
            }
            let wantsExplicitOpen = explicitOpenUntil != nil
            if pendingShow != nil {
                if wantsExplicitOpen { pendingShow?.source = .explicitOpen }
            } else if !shown || wantsExplicitOpen {
                // A new show, or an explicit open of the slot already on
                // screen (which shows again).
                pendingShow = PendingShow(
                    source: wantsExplicitOpen ? .explicitOpen : .show,
                    due: now.clampedAdding(timing.showSettleMillis)
                )
            }
            if let pending = pendingShow, pending.due <= now {
                pendingShow = nil
                shown = true
                explicitOpenUntil = nil
                edges.append(.show(source: pending.source, stepAt: now))
            }
        }
        return edges
    }
}
