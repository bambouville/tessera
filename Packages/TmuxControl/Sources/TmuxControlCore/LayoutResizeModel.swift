import Foundation

/// The window-option inputs `layout_resize_check` (layout.c) reads when it
/// decides how far a pane may shrink.
///
/// A client cannot read them cheaply, and tmux's defaults (no pane status
/// line, no scrollbars) leave every pane one cell of minimum, so
/// `TmuxCompactClientSizing` uses `.tmuxDefaults`. The other values exist so
/// the model can be checked against tmux's own rules for them.
struct TmuxLayoutResizeOptions: Equatable, Sendable {
    /// `pane-border-status`: a status line costs the topmost (`top`) or
    /// bottommost (`bottom`) panes one extra row of minimum height.
    enum PaneBorderStatus: Equatable, Sendable {
        case off
        case top
        case bottom
    }

    var paneBorderStatus: PaneBorderStatus = .off
    /// `pane-scrollbars` (3.6+): the scrollbar style's width plus padding when
    /// scrollbars are on, otherwise 0. It raises every pane's minimum width.
    var scrollbarColumns: Int = 0

    static let tmuxDefaults = TmuxLayoutResizeOptions()
}

/// tmux's `layout_resize` (layout.c, identical in 3.2 through 3.6a apart from
/// 3.6's scrollbar minimum), which is what a window resize does to its panes.
///
/// tmux does not keep divider ratios when a window changes size.
/// `layout_resize_adjust` hands the change out one cell at a time, round-robin
/// from the first child, to the children that run along the resize; a shrink
/// skips any child `layout_resize_check` says is already at its minimum. A
/// split running the other way passes the full change to every child. So a
/// 59-column pane of a 200-column window does not become 50 columns when the
/// window becomes 170: it becomes 44, because the 140-column pane beside it
/// only gave up as many cells as it did.
///
/// The model is batched rather than looping cell by cell, but reaches tmux's
/// result exactly. tmux visits every cell once per resize, top-down, so a
/// subtree is still untouched when its share is decided, and its availability
/// can be read from the layout as it was:
/// - a batched change at a split along the resize gives child `i` of `k`
///   `change / k` cells, plus one more for the first `change % k` children
///   when growing; when shrinking, each full pass takes one cell from every
///   child that still has one to give, and the last partial pass takes from
///   the first such children in order;
/// - a child receives its share as single-cell calls. A single-cell grow of
///   a split along the resize reaches only its first child; a single-cell
///   shrink reaches its first child that can still shrink. A split running
///   the other way passes each call to every child, and a pane just changes.
///
/// Availability shrinks by exactly one with each single-cell shrink at every
/// level, which is what makes the greedy and pass-counting forms equal to
/// tmux's loops. `TmuxLayoutResizeReferenceTests` checks the model against a
/// line-by-line port of the C on random trees.
///
/// Cells are kept flat in preorder: a cell's children follow it, and the next
/// sibling starts `span` cells later. Nothing here allocates per cell or per
/// resized cell; a resize costs one pass over the tree.
struct TmuxLayoutResizeModel {
    /// One resize direction. `columns` is tmux's `LAYOUT_LEFTRIGHT` resize,
    /// `rows` its `LAYOUT_TOPBOTTOM` resize.
    enum Dimension: Sendable {
        case columns
        case rows
    }

    private enum Kind: UInt8 {
        case pane
        /// `{…}`: children side by side (`LAYOUT_LEFTRIGHT`).
        case leftRight
        /// `[…]`: children stacked (`LAYOUT_TOPBOTTOM`).
        case topBottom
    }

    private struct Cell {
        var kind: Kind
        var paneId: Int
        var columns: Int
        var rows: Int
        var minimumColumns: Int
        var minimumRows: Int
        /// This cell plus all of its descendants.
        var span: Int
    }

    /// tmux's `WINDOW_MAXIMUM`. `refresh-client -C` and `resize-window` refuse
    /// anything larger, so no projection may ask for more.
    static let windowMaximum = 10_000

    /// `PANE_MINIMUM` (tmux.h): one cell since tmux 2.x.
    private static let paneMinimum = 1

    private var cells: [Cell] = []

    /// Nil for a layout tmux could not have sent: a split without children,
    /// a dimension outside 1...`windowMaximum`, or children whose sizes and
    /// one-cell dividers do not add up to their parent. Callers then fall back
    /// to ratio sizing rather than trust a prediction built on bad geometry.
    init?(_ layout: WindowLayout, options: TmuxLayoutResizeOptions = .tmuxDefaults) {
        guard options.scrollbarColumns >= 0,
              options.scrollbarColumns < Self.windowMaximum
        else { return nil }
        cells.reserveCapacity(8)
        guard append(
            layout.root,
            isTop: true,
            isBottom: true,
            options: options,
            depth: 0
        ) else { return nil }
    }

    /// The window's size along `dimension`: the root cell's, which is what
    /// `resize_window` leaves the window at.
    func windowSize(_ dimension: Dimension) -> Int {
        size(of: 0, dimension)
    }

    /// Preorder index of the pane's cell, or nil when the layout lacks it.
    func cellIndex(ofPane paneId: PaneId) -> Int? {
        cells.firstIndex { $0.kind == .pane && $0.paneId == paneId.rawValue }
    }

    func size(ofCell index: Int, _ dimension: Dimension) -> Int {
        size(of: index, dimension)
    }

    /// How far `layout_resize_check` lets every cell shrink along
    /// `dimension`, indexed like the cells. `[0]` is the whole window's.
    func availability(_ dimension: Dimension) -> [Int] {
        var result = [Int](repeating: 0, count: cells.count)
        fillAvailability(dimension, into: &result)
        return result
    }

    /// Every cell's size along `dimension` after `layout_resize` asks for
    /// `target`, indexed like the cells. `[0]` is the new window size.
    func resized(_ dimension: Dimension, to target: Int) -> [Int] {
        let available = availability(dimension)
        var sizes = [Int](repeating: 0, count: cells.count)
        resize(dimension, to: target, availability: available, into: &sizes)
        return sizes
    }

    /// `resized(_:to:)` into caller-owned storage, for a search that resizes
    /// the same layout many times. `availability` must be this model's
    /// `availability(dimension)`.
    func resize(
        _ dimension: Dimension,
        to target: Int,
        availability: [Int],
        into sizes: inout [Int]
    ) {
        if sizes.count != cells.count {
            sizes = [Int](repeating: 0, count: cells.count)
        }
        for index in cells.indices {
            sizes[index] = size(of: index, dimension)
        }

        // layout_resize: never shrink past what layout_resize_check allows.
        // When nothing can shrink, a smaller request leaves the layout as it
        // is and a larger one grows it normally.
        let current = sizes[0]
        let limit = availability[0]
        var change = target - current
        if change < 0, change < -limit {
            change = -limit
        }
        if limit == 0 {
            change = target <= current ? 0 : target - current
        }
        guard change != 0 else { return }
        adjust(0, dimension, by: change, availability: availability, sizes: &sizes)
    }

    // MARK: - layout_resize_adjust

    /// One `layout_resize_adjust(lc, type, change)` call.
    private func adjust(
        _ index: Int,
        _ dimension: Dimension,
        by change: Int,
        availability: [Int],
        sizes: inout [Int]
    ) {
        sizes[index] += change
        let kind = cells[index].kind
        if kind == .pane { return }
        guard runsAlong(kind, dimension) else {
            // A split the other way: every child changes by the whole amount.
            forEachChild(of: index) { child in
                adjust(child, dimension, by: change, availability: availability, sizes: &sizes)
            }
            return
        }

        let count = childCount(of: index)
        if change > 0 {
            // Round-robin from the first child, one cell per visit.
            let each = change / count
            let extra = change % count
            var position = 0
            forEachChild(of: index) { child in
                let share = each + (position < extra ? 1 : 0)
                adjustByCells(child, dimension, sign: 1, count: share, availability: availability, sizes: &sizes)
                position += 1
            }
            return
        }

        // Round-robin shrink: each full pass takes one cell from every child
        // that still has one to give. `passes` is the most complete passes the
        // change pays for; the remainder comes from the first children (in
        // order) that could still give one more.
        let wanted = -change
        var low = 0
        var high = 0
        forEachChild(of: index) { high = max(high, availability[$0]) }
        while low < high {
            let middle = low + (high - low + 1) / 2
            if takenByPasses(middle, under: index, availability: availability) <= wanted {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let passes = low
        var remainder = wanted - takenByPasses(passes, under: index, availability: availability)
        forEachChild(of: index) { child in
            var share = min(availability[child], passes)
            if remainder > 0, availability[child] > passes {
                share += 1
                remainder -= 1
            }
            adjustByCells(child, dimension, sign: -1, count: share, availability: availability, sizes: &sizes)
        }
    }

    /// `count` consecutive `layout_resize_adjust(lc, type, ±1)` calls.
    private func adjustByCells(
        _ index: Int,
        _ dimension: Dimension,
        sign: Int,
        count: Int,
        availability: [Int],
        sizes: inout [Int]
    ) {
        guard count > 0 else { return }
        sizes[index] += sign * count
        let kind = cells[index].kind
        if kind == .pane { return }
        guard runsAlong(kind, dimension) else {
            forEachChild(of: index) { child in
                adjustByCells(child, dimension, sign: sign, count: count, availability: availability, sizes: &sizes)
            }
            return
        }
        if sign > 0 {
            // A one-cell grow stops after the first child it reaches.
            adjustByCells(index + 1, dimension, sign: 1, count: count, availability: availability, sizes: &sizes)
            return
        }
        // A one-cell shrink goes to the first child that can still shrink.
        var remaining = count
        forEachChild(of: index) { child in
            guard remaining > 0 else { return }
            let share = min(availability[child], remaining)
            adjustByCells(child, dimension, sign: -1, count: share, availability: availability, sizes: &sizes)
            remaining -= share
        }
    }

    private func takenByPasses(_ passes: Int, under index: Int, availability: [Int]) -> Int {
        var total = 0
        forEachChild(of: index) { total += min(availability[$0], passes) }
        return total
    }

    // MARK: - layout_resize_check

    /// Children follow their parent in preorder, so walking backwards sees
    /// every child's availability before its parent's.
    private func fillAvailability(_ dimension: Dimension, into result: inout [Int]) {
        var index = cells.count - 1
        while index >= 0 {
            let cell = cells[index]
            switch cell.kind {
            case .pane:
                let minimum = dimension == .columns ? cell.minimumColumns : cell.minimumRows
                result[index] = max(0, size(of: index, dimension) - minimum)
            case .leftRight, .topBottom:
                if runsAlong(cell.kind, dimension) {
                    // Same direction: the children's room adds up.
                    var total = 0
                    forEachChild(of: index) { total += result[$0] }
                    result[index] = total
                } else {
                    // Other direction: every child shrinks together, so the
                    // tightest one decides.
                    var tightest = Int.max
                    forEachChild(of: index) { tightest = min(tightest, result[$0]) }
                    result[index] = tightest
                }
            }
            index -= 1
        }
    }

    // MARK: - Tree storage

    private func size(of index: Int, _ dimension: Dimension) -> Int {
        dimension == .columns ? cells[index].columns : cells[index].rows
    }

    private func runsAlong(_ kind: Kind, _ dimension: Dimension) -> Bool {
        switch (kind, dimension) {
        case (.leftRight, .columns), (.topBottom, .rows): return true
        default: return false
        }
    }

    private func childCount(of index: Int) -> Int {
        var count = 0
        forEachChild(of: index) { _ in count += 1 }
        return count
    }

    private func forEachChild(of index: Int, _ body: (Int) -> Void) {
        let end = index + cells[index].span
        var child = index + 1
        while child < end {
            body(child)
            child += cells[child].span
        }
    }

    /// Appends `node` and its subtree in preorder. `isTop`/`isBottom` are
    /// tmux's `layout_cell_is_top`/`layout_cell_is_bottom`: no stacked
    /// ancestor puts the cell below (above) a sibling.
    private mutating func append(
        _ node: LayoutNode,
        isTop: Bool,
        isBottom: Bool,
        options: TmuxLayoutResizeOptions,
        depth: Int
    ) -> Bool {
        let rect = node.rect
        guard depth <= 256,
              (1...Self.windowMaximum).contains(rect.width),
              (1...Self.windowMaximum).contains(rect.height)
        else { return false }

        switch node {
        case let .leaf(paneId, _):
            let statusRow: Bool
            switch options.paneBorderStatus {
            case .off: statusRow = false
            case .top: statusRow = isTop
            case .bottom: statusRow = isBottom
            }
            cells.append(Cell(
                kind: .pane,
                paneId: paneId.rawValue,
                columns: rect.width,
                rows: rect.height,
                minimumColumns: Self.paneMinimum + options.scrollbarColumns,
                minimumRows: Self.paneMinimum + (statusRow ? 1 : 0),
                span: 1
            ))
            return true

        case let .split(axis, _, children):
            guard !children.isEmpty else { return false }
            let index = cells.count
            cells.append(Cell(
                kind: axis == .horizontal ? .leftRight : .topBottom,
                paneId: -1,
                columns: rect.width,
                rows: rect.height,
                minimumColumns: 0,
                minimumRows: 0,
                span: 1
            ))
            // tmux's invariant: siblings and their one-cell dividers fill the
            // parent along the split, and match it across the split.
            var along = -1
            for (position, child) in children.enumerated() {
                let childRect = child.rect
                switch axis {
                case .horizontal:
                    guard childRect.height == rect.height else { return false }
                    along += childRect.width + 1
                case .vertical:
                    guard childRect.width == rect.width else { return false }
                    along += childRect.height + 1
                }
                let first = position == 0
                let last = position == children.count - 1
                guard append(
                    child,
                    isTop: isTop && (axis == .horizontal || first),
                    isBottom: isBottom && (axis == .horizontal || last),
                    options: options,
                    depth: depth + 1
                ) else { return false }
            }
            guard along == (axis == .horizontal ? rect.width : rect.height) else { return false }
            cells[index].span = cells.count - index
            return true
        }
    }
}
