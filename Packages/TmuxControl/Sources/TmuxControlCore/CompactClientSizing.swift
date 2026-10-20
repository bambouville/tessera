import Foundation

/// What a compact client does with a layout-only update. Raw values cross the
/// C ABI unchanged.
public enum TmuxCompactReprojection: Int32, Equatable, Sendable {
    /// Keep the current advertisement: it already fits, or the window is a
    /// peer's grid this device must not reclaim by side effect.
    case hold = 0
    /// Advertise the new projection.
    case reproject = 1
    /// The window is this device's canvas and the projection moved again,
    /// but tmux has already resized this layout
    /// `TmuxCompactClientSizing.maximumUnsettledCorrections` times in answer
    /// to corrections without the window settling. tmux is distributing cells
    /// differently from `TmuxLayoutResizeModel`, and following it any further
    /// would be a `refresh-client -C` / `%layout-change` storm that resizes
    /// every other client's panes. Hold the current size; do not repair
    /// toward the projection by another route either.
    case holdCycle = 2
}

/// The little state `TmuxCompactClientSizing.reprojection` keeps between
/// layout updates, opaque to its callers: a platform stores `rawValue` and
/// hands it back unchanged (Android through the C ABI as two 64-bit words).
///
/// It remembers the layout it judged last (its shape, window size and cell
/// sizes) separately from the publication it has answered, and counts
/// consecutive corrections of one layout — the same split tree, focused pane
/// and viewport — that tmux answered with a resize that did not leave the
/// window settled at the advertised size. A changed tree, focus or viewport
/// starts a new count; so do a correction that settles and an edit that moved
/// panes without resizing the window.
public struct TmuxCompactReprojectionMemo: Equatable, Sendable {
    /// Viewport, focused pane and split tree, without sizes.
    var signature: UInt32 = 0
    /// Every cell size of the layout judged last (the window and focus
    /// rectangles when there was no tree).
    var layoutHash: UInt32 = 0
    /// The window of the layout judged last.
    var windowColumns: UInt16 = 0
    var windowRows: UInt16 = 0
    /// The last publication consumed by an eligible correction or reset.
    /// A held peer resize updates the observed layout, but cannot consume an
    /// outstanding publication before our own canvas answers it.
    var advertisedColumns: UInt16 = 0
    var advertisedRows: UInt16 = 0
    var correctionCount: UInt8 = 0
    var hasLayout = false

    public init() {}

    init(signature: UInt32) {
        self.signature = signature
    }

    /// Sizes are kept to 14 bits so the memo packs into two words. tmux
    /// refuses any window or client past 10000 cells, so only a size no tmux
    /// produces compares by its clamped value.
    private static let cellBits: UInt64 = 0x3fff

    static func cells(_ value: Int) -> UInt16 {
        UInt16(min(max(value, 0), Int(cellBits)))
    }

    private static func cells(_ raw: UInt64, shift: UInt64) -> UInt16 {
        UInt16(truncatingIfNeeded: raw >> shift & cellBits)
    }

    public init(rawValue: (UInt64, UInt64)) {
        signature = UInt32(truncatingIfNeeded: rawValue.0 >> 32)
        layoutHash = UInt32(truncatingIfNeeded: rawValue.0)
        windowColumns = Self.cells(rawValue.1, shift: 50)
        windowRows = Self.cells(rawValue.1, shift: 36)
        advertisedColumns = Self.cells(rawValue.1, shift: 22)
        advertisedRows = Self.cells(rawValue.1, shift: 8)
        correctionCount = UInt8(truncatingIfNeeded: rawValue.1 >> 1 & 0x7f)
        hasLayout = rawValue.1 & 1 != 0
    }

    public var rawValue: (UInt64, UInt64) {
        (
            UInt64(signature) << 32 | UInt64(layoutHash),
            UInt64(windowColumns) << 50 | UInt64(windowRows) << 36
                | UInt64(advertisedColumns) << 22 | UInt64(advertisedRows) << 8
                | UInt64(correctionCount) << 1 | (hasLayout ? 1 : 0)
        )
    }

    /// The cycle guard stopped this layout's corrections. It keeps returning
    /// `holdCycle` until the layout settles, is edited, or changes shape,
    /// focus or viewport; a caller that reports the stop reports the
    /// transition into this state, once.
    public var isHoldingCycle: Bool {
        corrections > TmuxCompactClientSizing.maximumUnsettledCorrections
    }

    var corrections: Int {
        get { Int(correctionCount) }
        set { correctionCount = UInt8(min(max(newValue, 0), 0x7f)) }
    }

    /// How the layout being judged differs from the one judged last.
    enum LayoutChange: Equatable {
        /// Nothing judged yet for this shape.
        case first
        /// The same window and cell sizes: an unrelated update, or an
        /// advertisement that never reached tmux.
        case unchanged
        /// The same window size with different cell sizes: someone moved a
        /// divider or resized a pane. tmux's answer to a `refresh-client -C`
        /// always changes the window, so this is never the answer to a
        /// correction.
        case edited
        /// The window changed size. `answering`: this client advertised a
        /// different size since the publication last consumed, so this can be tmux
        /// answering that advertisement. Without one it cannot: the
        /// advertisement was withheld (background, a hidden tab, a peer's
        /// grid, an ownership proof still running) and something else moved
        /// the window.
        case resized(answering: Bool)
    }

    mutating func record(
        window: CellRect?,
        layoutHash hash: UInt32,
        lastClientSize: (columns: Int, rows: Int)?
    ) -> LayoutChange {
        let advertised = (
            columns: Self.cells(lastClientSize?.columns ?? 0),
            rows: Self.cells(lastClientSize?.rows ?? 0)
        )
        guard let window else {
            hasLayout = false
            return .first
        }
        let columns = Self.cells(window.width)
        let rows = Self.cells(window.height)
        let change: LayoutChange
        if !hasLayout {
            change = .first
        } else if columns != windowColumns || rows != windowRows {
            change = .resized(
                answering: advertised.columns != advertisedColumns || advertised.rows != advertisedRows
            )
        } else if hash == layoutHash {
            // Not a layout change at all: keep outstanding publication
            // evidence until an eligible canvas answers it.
            return .unchanged
        } else {
            change = .edited
        }
        hasLayout = true
        windowColumns = columns
        windowRows = rows
        layoutHash = hash
        if change == .first || change == .edited {
            consumePublication(lastClientSize)
        }
        return change
    }

    mutating func consumePublication(_ size: (columns: Int, rows: Int)?) {
        advertisedColumns = Self.cells(size?.columns ?? 0)
        advertisedRows = Self.cells(size?.rows ?? 0)
    }
}

/// Maps a compact device's visible terminal grid onto a complete tmux window.
///
/// A compact client paints only the focused pane. For a split window, the
/// control-client canvas therefore grows so that pane gets the device's own
/// cell grid: roughly two device widths for a side-by-side split, two device
/// heights for a stacked one.
///
/// "Roughly", because tmux does not keep divider ratios when the window
/// resizes (`TmuxLayoutResizeModel`). Scaling the window by the focused pane's
/// share lands the pane off target, and reprojecting from the result never
/// settles once the pane is under about a quarter of the window: real tmux
/// 3.6a took a 30-of-200-column pane on a 50-column phone through
/// 334/97, 173/17, 509/185, 138/1 and then 113 ↔ 1000 columns forever, each
/// step a `%layout-change` for every client. So the advertised size is solved
/// against the layout tree instead: the smallest window that tmux's own
/// resize leaves the focused pane at least the viewport, which is exactly
/// the viewport whenever tmux's minimums allow it. Reprojecting from the
/// layout that advertisement produces returns the same size.
///
/// This type deliberately lives in `TmuxControlCore`: Apple calls it directly
/// and Android reaches it through `TesseraCoreABI`, so the two products cannot
/// drift in their geometry or peer-reclaim decisions.
public enum TmuxCompactClientSizing {
    /// Resizes of one layout, in answer to corrections, that `reprojection`
    /// allows without the window settling. The solver needs none; a split,
    /// close or divider move on this device's canvas needs one; anything
    /// beyond a couple more means tmux is not doing what the model predicts.
    public static let maximumUnsettledCorrections = 3

    /// The compact SSH view observes this key. Equal window and focus
    /// rectangles can still hide a changed split tree or unfocused dividers,
    /// which change how tmux distributes a resize. Observe every pane's cell
    /// rectangle; output and titles are deliberately absent from this key.
    public static func observationKey(
        mode: String,
        windowId: WindowId?,
        focusPaneId: PaneId?,
        layout: WindowLayout?,
        windowRect: CellRect?,
        focusRect: CellRect?
    ) -> String {
        func token(_ rect: CellRect?) -> String {
            guard let rect else { return "nil" }
            return "\(rect.width)x\(rect.height)+\(rect.x)+\(rect.y)"
        }
        var geometry = LayoutHasher()
        if let layout { geometry.mixRects(layout.root) }
        return [
            mode,
            windowId?.description ?? "nil",
            focusPaneId?.description ?? "nil",
            token(windowRect),
            token(focusRect),
            String(reprojectionSignature(viewport: (0, 0), layout: layout, focusPaneId: focusPaneId)),
            String(geometry.value),
        ].joined(separator: ":")
    }

    /// The client size that gives the focused pane `viewport`.
    ///
    /// With a `layout` that contains `focusPaneId`, the size is solved against
    /// tmux's resize of that tree. Without one (before hydration, or a layout
    /// that did not parse) it falls back to scaling `windowRect` by the
    /// focused pane's share, `clientSize(viewport:windowRect:focusRect:)`.
    public static func clientSize(
        viewport: (columns: Int, rows: Int),
        layout: WindowLayout?,
        focusPaneId: PaneId?,
        windowRect: CellRect?,
        focusRect: CellRect?
    ) -> (columns: Int, rows: Int) {
        if let layout,
           let focusPaneId,
           let model = TmuxLayoutResizeModel(layout),
           let focus = model.cellIndex(ofPane: focusPaneId) {
            return (
                columns: solvedDimension(model, .columns, focus: focus, viewport: viewport.columns),
                rows: solvedDimension(model, .rows, focus: focus, viewport: viewport.rows)
            )
        }
        return clientSize(viewport: viewport, windowRect: windowRect, focusRect: focusRect)
    }

    /// Ratio fallback: the window scaled by the focused pane's share. Only
    /// right when tmux keeps the ratios, which it does not; used when no
    /// layout tree is known.
    public static func clientSize(
        viewport: (columns: Int, rows: Int),
        windowRect: CellRect?,
        focusRect: CellRect?
    ) -> (columns: Int, rows: Int) {
        guard let windowRect,
              let focusRect,
              windowRect.width > 0,
              windowRect.height > 0,
              focusRect.width > 0,
              focusRect.height > 0
        else { return viewport }

        return (
            columns: projectedDimension(
                viewport: viewport.columns,
                window: windowRect.width,
                focus: focusRect.width
            ),
            rows: projectedDimension(
                viewport: viewport.rows,
                window: windowRect.height,
                focus: focusRect.height
            )
        )
    }

    /// What a layout-only update does to this compact client's advertisement.
    ///
    /// tmux broadcasts layout changes to every control client. Once a larger
    /// peer publishes its grid, a still-connected phone must not interpret
    /// that peer geometry as a local split edit and reclaim sizing authority.
    /// A phone may reproject while its last advertised canvas still owns the
    /// layout, or once during hydration when only its physical viewport is
    /// cached. `memo` bounds the corrections of one layout (see
    /// `TmuxCompactReprojection.holdCycle`); pass the same storage back on
    /// every call for one tmux client.
    ///
    /// Judging the same inputs again returns the same decision and leaves
    /// `memo` as it was, so a caller may judge on every runtime event.
    /// `lastClientSize` is the size this client last advertised to tmux, not
    /// one it meant to: a correction counts only when a window resize follows
    /// a change of it, so an advertisement that never reached tmux is never
    /// counted, however many layouts arrive while it waits.
    public static func reprojection(
        viewport: (columns: Int, rows: Int),
        lastClientSize: (columns: Int, rows: Int)?,
        layout: WindowLayout?,
        focusPaneId: PaneId?,
        windowRect: CellRect?,
        focusRect: CellRect?,
        memo: inout TmuxCompactReprojectionMemo
    ) -> TmuxCompactReprojection {
        let projected = clientSize(
            viewport: viewport,
            layout: layout,
            focusPaneId: focusPaneId,
            windowRect: windowRect,
            focusRect: focusRect
        )
        let window = layout?.root.rect ?? windowRect
        let signature = reprojectionSignature(
            viewport: viewport,
            layout: layout,
            focusPaneId: focusPaneId
        )
        if memo.signature != signature {
            memo = TmuxCompactReprojectionMemo(signature: signature)
        }
        let change = memo.record(
            window: window,
            layoutHash: layoutSizeHash(layout: layout, windowRect: windowRect, focusRect: focusRect),
            lastClientSize: lastClientSize
        )
        if change == .edited {
            // A divider move or pane resize at an unchanged window size, by
            // this device or another client: never tmux answering a
            // correction, so the count starts over, and a held cycle with it.
            // Whatever is judged below, including an edit seen while this
            // device's last advertisement is still in flight (a window a few
            // cells off reads as a peer's until it lands), so one edit buys
            // at most `maximumUnsettledCorrections` more advertisements.
            memo.corrections = 0
        }

        guard let lastClientSize else { return .reproject }
        guard projected.columns != lastClientSize.columns
                || projected.rows != lastClientSize.rows
        else {
            // Settled only once the window really is at the advertisement. A
            // layout that arrives before tmux applied it (an older size, or an
            // unrelated snapshot change) also projects to it, and must not
            // wipe the count of a cycle that is still running.
            if let window,
               window.width == lastClientSize.columns,
               window.height == lastClientSize.rows {
                memo.corrections = 0
                memo.consumePublication(lastClientSize)
            }
            return .hold
        }

        // The window already sits at this device's projected grid while tmux
        // still records a different advertised size for this client — the
        // leftover of a replay tmux refused because another client held
        // `latest` at the time (an `ignore-size` attach, a keystroke on a
        // laptop client). Re-advertise: it cannot move a window that is
        // already at this size, and without it the next `latest` transfer back
        // to this client snaps the window to the stale grid — a landscape
        // window on a portrait phone.
        if let window,
           window.width == projected.columns,
           window.height == projected.rows {
            return .reproject
        }

        if lastClientSize.columns == viewport.columns,
           lastClientSize.rows == viewport.rows {
            return .reproject
        }

        // tmux status/pane-border chrome can make the window root one or two
        // cells smaller than the advertised client while it is still ours.
        guard let window,
              abs(window.width - lastClientSize.columns) <= 2,
              abs(window.height - lastClientSize.rows) <= 2
        else { return .hold }

        // Our canvas, and the projection moved.
        switch change {
        case .edited:
            // Counted from zero above: a new arrangement to fit.
            return .reproject
        case .unchanged, .resized(answering: false):
            // The layout judged last, again, or a window this client's
            // advertisements did not move: neither a new correction nor a
            // reason to stop holding. A caller whose advertisement did not
            // reach tmux (withheld, or waiting for an ownership proof) gets
            // the same answer until one does and tmux answers it.
            return memo.isHoldingCycle ? .holdCycle : .reproject
        case .first, .resized(answering: true):
            // Held peer layouts above never reach this consumption point.
            // Keep the publication independent of the latest observation so
            // interleaving peers cannot erase every answer to our corrections.
            memo.consumePublication(lastClientSize)
            // tmux resized this layout (or there is nothing to compare with):
            // a split, close or divider move earlier, or tmux missing the
            // model's prediction for the last correction.
            guard memo.corrections < maximumUnsettledCorrections else {
                // One step past the limit marks the hold, so a caller that
                // reports `isHoldingCycle` turning on reports each stop once.
                memo.corrections = maximumUnsettledCorrections + 1
                return .holdCycle
            }
            memo.corrections += 1
            return .reproject
        }
    }

    // MARK: - Solving against tmux's resize

    /// The smallest window size along `dimension` that tmux's resize leaves
    /// the focused cell at least `viewport` long.
    ///
    /// A focused cell already at `viewport` keeps the window as it is: a
    /// shrink can come entirely out of the cells before it (tmux starts every
    /// round-robin pass at the first child), so "smallest" alone would keep
    /// trimming a settled window one step at a time.
    ///
    /// Otherwise the focused cell's size is non-decreasing in the requested
    /// window size and moves by at most one per cell of it (each extra cell
    /// reaches one pane), so a binary search finds the first size at which it
    /// reaches `viewport`, and there it is `viewport` exactly. tmux then
    /// leaves the window at that size, and the next projection keeps it.
    /// Below the layout's minimum the floor is as close as tmux allows, and
    /// the next projection keeps that too.
    ///
    /// When no window reaches `viewport`, the window stays as it is. That is
    /// the case for every pane after the first of a split nested in one of
    /// the same direction, which tmux makes itself: closing a pane promotes
    /// its last sibling split into the grandparent without merging the two
    /// (`layout_destroy_cell`), so `{A,[B,{C,D}]}` loses B and becomes
    /// `{A,{C,D}}`. A grow reaches the nested split one cell at a time, and a
    /// one-cell grow goes to its first child only, so C takes every cell and
    /// D keeps its width at any window size. Growing toward `viewport` would
    /// only reach `windowMaximum` with D unchanged and every other pane
    /// thousands of cells wide. The pane is shown smaller than the device
    /// instead, as it is.
    ///
    /// Shrinking has no such limit, but a nested split's one-cell shrinks
    /// take from its first child until that child is at its minimum, so
    /// bringing an oversized D down to `viewport` leaves C one cell wide.
    /// That is kept: a narrower window cannot give D the viewport any other
    /// way, the compact device paints only D, and a focused pane wider than
    /// the device is the overflow this canvas exists to prevent. C comes back
    /// first when a larger client resizes the window, because the grow goes
    /// to it.
    private static func solvedDimension(
        _ model: TmuxLayoutResizeModel,
        _ dimension: TmuxLayoutResizeModel.Dimension,
        focus: Int,
        viewport: Int
    ) -> Int {
        let target = max(1, viewport)
        let window = model.windowSize(dimension)
        guard model.size(ofCell: focus, dimension) != target else { return window }

        let availability = model.availability(dimension)
        var sizes: [Int] = []
        func focusSize(atWindow size: Int) -> Int {
            model.resize(dimension, to: size, availability: availability, into: &sizes)
            return sizes[focus]
        }

        var tooSmall = window - availability[0]
        var largeEnough = TmuxLayoutResizeModel.windowMaximum
        guard focusSize(atWindow: largeEnough) >= target else { return window }
        if focusSize(atWindow: tooSmall) >= target { return tooSmall }
        while largeEnough - tooSmall > 1 {
            let middle = tooSmall + (largeEnough - tooSmall) / 2
            if focusSize(atWindow: middle) >= target {
                largeEnough = middle
            } else {
                tooSmall = middle
            }
        }
        return largeEnough
    }

    /// FNV-1a over what makes two layout updates "the same layout" for the
    /// correction count: the viewport, the focused pane and the tree's shape.
    /// Sizes are left out, because they are exactly what a correction
    /// changes.
    private static func reprojectionSignature(
        viewport: (columns: Int, rows: Int),
        layout: WindowLayout?,
        focusPaneId: PaneId?
    ) -> UInt32 {
        var hasher = LayoutHasher()
        hasher.mix(viewport.columns)
        hasher.mix(viewport.rows)
        hasher.mix(focusPaneId?.rawValue ?? -1)
        if let layout {
            hasher.mixShape(layout.root)
        } else {
            hasher.mix(3)
        }
        return hasher.value
    }

    /// FNV-1a over every cell size of `layout`, or over the window and focus
    /// rectangles when there is no tree: what moves when a pane is resized.
    private static func layoutSizeHash(
        layout: WindowLayout?,
        windowRect: CellRect?,
        focusRect: CellRect?
    ) -> UInt32 {
        var hasher = LayoutHasher()
        if let layout {
            hasher.mixSizes(layout.root)
        } else {
            hasher.mix(windowRect?.width ?? -1)
            hasher.mix(windowRect?.height ?? -1)
            hasher.mix(focusRect?.width ?? -1)
            hasher.mix(focusRect?.height ?? -1)
        }
        return hasher.value
    }

    private struct LayoutHasher {
        private(set) var value: UInt32 = 0x811c_9dc5

        mutating func mix(_ value: Int) {
            var word = UInt32(truncatingIfNeeded: value)
            for _ in 0..<4 {
                self.value = (self.value ^ (word & 0xff)) &* 0x0100_0193
                word >>= 8
            }
        }

        mutating func mixShape(_ node: LayoutNode) {
            switch node {
            case let .leaf(paneId, _):
                mix(0)
                mix(paneId.rawValue)
            case let .split(axis, _, children):
                mix(axis == .horizontal ? 1 : 2)
                mix(children.count)
                for child in children { mixShape(child) }
            }
        }

        mutating func mixSizes(_ node: LayoutNode) {
            mix(node.rect.width)
            mix(node.rect.height)
            if case let .split(_, _, children) = node {
                for child in children { mixSizes(child) }
            }
        }

        mutating func mixRects(_ node: LayoutNode) {
            mix(node.rect.x)
            mix(node.rect.y)
            mix(node.rect.width)
            mix(node.rect.height)
            if case let .split(_, _, children) = node {
                for child in children { mixRects(child) }
            }
        }
    }

    private static func projectedDimension(
        viewport: Int,
        window: Int,
        focus: Int
    ) -> Int {
        let safeViewport = max(1, viewport)
        let numerator = Int64(safeViewport) * Int64(max(1, window))
        let denominator = Int64(max(1, focus))
        let projected = (numerator + denominator - 1) / denominator
        // tmux refuses `refresh-client -C` beyond WINDOW_MAXIMUM ("size too
        // small or too big"), so a larger projection would never apply.
        return min(
            TmuxLayoutResizeModel.windowMaximum,
            max(safeViewport, Int(projected))
        )
    }
}
