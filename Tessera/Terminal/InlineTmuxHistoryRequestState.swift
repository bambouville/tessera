import CoreGraphics
import TmuxControl
import TmuxControlCore

/// The platform half of the inline (SSH+tmux) history ladder.
///
/// Every stateful decision about how deep an inline surface's local
/// scrollback may go lives in `TmuxControlCore`'s render ledger: the credited
/// depth, exhaustion, single-flight capture and the settling signal
/// (`RenderEffect.inlineHistorySettled`). A platform keeps exactly two facts
/// per surface — `canDeepen` from the last settle and whether a gesture's
/// request is still unanswered — plus the reader's placement at the moment it
/// asked, because the deepen rebinds the surface under a new owner epoch and
/// that bind empties the local transcript before the full capture replays
/// into it.
///
/// The only gesture rule is the shared, stateless
/// `TmuxInlineHistoryGate.shouldRequest`; this type deliberately holds no
/// threshold of its own.
struct InlineTmuxHistoryRequestState: Equatable {

    /// Where the reader sat when it asked for more history.
    ///
    /// Only the distance from the bottom survives a deepen: the replacement
    /// page is longer, so the absolute offset means nothing once it lands.
    struct ScrollAnchor: Equatable {
        var offsetY: CGFloat
        var maxOffsetY: CGFloat

        init(offsetY: CGFloat, maxOffsetY: CGFloat) {
            let clampedMax = max(0, maxOffsetY)
            self.maxOffsetY = clampedMax
            self.offsetY = min(max(0, offsetY), clampedMax)
        }

        /// Rows of content between the reader and the live tail.
        var distanceFromBottom: CGFloat { max(0, maxOffsetY - offsetY) }

        /// Distance-from-bottom preservation — the same arithmetic the mosh
        /// `.preserveDistanceFromBottom` placement branch uses.
        func restoredOffsetY(newMaxOffsetY: CGFloat) -> CGFloat {
            let newMax = max(0, newMaxOffsetY)
            return min(max(0, newMax - distanceFromBottom), newMax)
        }
    }

    /// One inline surface's record. A surface that has never settled reports
    /// `canDeepen == true`: the ledger answers an unnecessary request with a
    /// settle rather than a capture, so an optimistic first ask is free.
    struct Record: Equatable {
        var canDeepen: Bool = true
        var requestInFlight: Bool = false
        /// Credited depth from the last settle (lines of history the ledger
        /// considers captured for this surface).
        var depth: Int = 0
        /// tmux `history_size` for the owning pane at the last settle.
        var historySize: Int = 0
        /// Placement recorded when the in-flight request was submitted.
        var anchor: ScrollAnchor?
        /// The surface changed identity (window/pane) while the request was
        /// in flight. The settle that answers it belongs to another pane's
        /// transcript, so the reader stays on that pane's tail instead of
        /// being carried to a distance measured against the old one.
        var placementInvalidated: Bool = false
    }

    /// What one `inlineHistorySettled` meant for a surface.
    struct Settlement: Equatable {
        /// True when this settle answered a gesture the platform submitted.
        /// The ledger guarantees exactly one settle per request, including
        /// the ignored, exhausted and aborted cases, so this is also the
        /// signal that the latch has been released.
        var answeredRequest: Bool
        /// The placement recorded with that request, when one survived.
        var anchor: ScrollAnchor?
        /// The reader's distance from the tail should be restored. False
        /// when the settle answers a request but the surface has since moved
        /// to another window/pane: the rebind snapshot and the anchor both
        /// describe a transcript that no longer exists.
        var placesReader: Bool
        /// The record as it stands after the settle.
        var record: Record
    }

    /// Surface id for an inline grid pane.
    ///
    /// The ledger owns the spelling. A fact addressed to any other string
    /// names a surface the ledger has never declared, so the request is
    /// dropped and the gate never settles.
    static func paneSurfaceID(_ paneID: PaneId) -> SurfaceId {
        TmuxController.inlinePaneSurfaceID(paneID)
    }

    /// Inverse of `paneSurfaceID`; nil for `.live` and anything else.
    static func paneID(in surfaceID: SurfaceId) -> PaneId? {
        TmuxController.paneIDEncoded(in: surfaceID)
    }

    private var records: [SurfaceId: Record] = [:]

    init() {}

    /// A surface with no record yet reads as the permissive default.
    subscript(surfaceID: SurfaceId) -> Record {
        records[surfaceID] ?? Record()
    }

    var trackedSurfaceCount: Int { records.count }

    /// Latch the single-flight request and remember where the reader was.
    mutating func requestSubmitted(
        _ surfaceID: SurfaceId,
        offsetY: CGFloat,
        maxOffsetY: CGFloat
    ) {
        var record = self[surfaceID]
        record.requestInFlight = true
        record.anchor = ScrollAnchor(offsetY: offsetY, maxOffsetY: maxOffsetY)
        records[surfaceID] = record
    }

    /// Consume one `inlineHistorySettled`. Clears the in-flight latch whether
    /// or not the ledger captured anything.
    @discardableResult
    mutating func settled(
        _ surfaceID: SurfaceId,
        depth: Int,
        historySize: Int,
        canDeepen: Bool
    ) -> Settlement {
        var record = self[surfaceID]
        let answeredRequest = record.requestInFlight
        let placesReader = answeredRequest && !record.placementInvalidated
        let anchor = record.anchor
        record.requestInFlight = false
        record.placementInvalidated = false
        record.anchor = nil
        record.depth = depth
        record.historySize = historySize
        record.canDeepen = canDeepen
        records[surfaceID] = record
        return Settlement(
            answeredRequest: answeredRequest,
            anchor: placesReader ? anchor : nil,
            placesReader: placesReader,
            record: record
        )
    }

    /// The surface bound a new owner.
    ///
    /// A deepen itself rebinds under a new epoch with the same window/pane,
    /// so only a genuine identity change invalidates the ladder. The in-flight
    /// latch is deliberately kept either way — the ledger still owes exactly
    /// one settle for the submitted request, and dropping the latch here would
    /// let a second gesture fire against the same capture. The recorded
    /// placement does not survive an identity change: it described another
    /// pane's transcript.
    mutating func surfaceRebound(_ surfaceID: SurfaceId, identityChanged: Bool) {
        guard identityChanged else { return }
        var record = self[surfaceID]
        record.canDeepen = true
        record.depth = 0
        record.historySize = 0
        record.anchor = nil
        record.placementInvalidated = record.requestInFlight
        records[surfaceID] = record
    }

    /// Where a surface's reader belongs once a deepened page has grown the
    /// local transcript to `newMaxOffsetY`. Nil when nothing was recorded.
    func restoredOffsetY(_ surfaceID: SurfaceId, newMaxOffsetY: CGFloat) -> CGFloat? {
        self[surfaceID].anchor?.restoredOffsetY(newMaxOffsetY: newMaxOffsetY)
    }

    mutating func reset(_ surfaceID: SurfaceId) {
        records.removeValue(forKey: surfaceID)
    }

    /// Transport loss, tmux exit, or any other event that invalidates every
    /// surface's ladder at once.
    mutating func reset() {
        records.removeAll()
    }
}
