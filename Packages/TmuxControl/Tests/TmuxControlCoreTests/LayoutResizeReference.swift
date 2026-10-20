import Foundation
@testable import TmuxControlCore

/// A line-by-line port of tmux's window-resize path (layout.c and resize.c,
/// 3.6a; 3.2–3.4 differ only in lacking the scrollbar minimum), kept
/// deliberately literal so it can be read against the C:
/// `layout_cell_is_top`/`_bottom`, `layout_add_horizontal_border`,
/// `layout_resize_check`, `layout_resize_adjust` (including its
/// `type == LAYOUT_WINDOWPANE` test, which can never be true and is harmless
/// because a pane has no children), `layout_resize` and the clamping and
/// "no smaller than the layout" rules of `resize_window`.
///
/// It loops one cell at a time exactly as tmux does. It is the oracle for
/// `TmuxLayoutResizeModel`, which reaches the same result without the loops,
/// and it is pinned against sequences measured on real tmux 3.6a.
final class TmuxLayoutReference {
    enum CellType {
        case leftRight
        case topBottom
        case windowPane
    }

    final class Cell {
        var type: CellType
        weak var parent: Cell?
        var cells: [Cell] = []
        var sx: Int
        var sy: Int
        var xoff = 0
        var yoff = 0
        let paneId: Int

        init(type: CellType, sx: Int, sy: Int, paneId: Int) {
            self.type = type
            self.sx = sx
            self.sy = sy
            self.paneId = paneId
        }
    }

    /// tmux.h
    static let paneMinimum = 1
    static let windowMinimum = paneMinimum
    static let windowMaximum = 10_000

    let root: Cell
    /// `pane-border-status`
    let status: TmuxLayoutResizeOptions.PaneBorderStatus
    /// `pane-scrollbars` on, and the active pane's scrollbar style width + pad.
    let scrollbarColumns: Int

    /// Set when a shrink loop made a full pass without progress. tmux would
    /// spin forever there; the port stops so a bad test input fails instead
    /// of hanging.
    private(set) var stalled = false

    init(_ layout: WindowLayout, options: TmuxLayoutResizeOptions = .tmuxDefaults) {
        root = Self.build(layout.root, parent: nil)
        status = options.paneBorderStatus
        scrollbarColumns = options.scrollbarColumns
    }

    private static func build(_ node: LayoutNode, parent: Cell?) -> Cell {
        let cell: Cell
        switch node {
        case let .leaf(paneId, rect):
            cell = Cell(type: .windowPane, sx: rect.width, sy: rect.height, paneId: paneId.rawValue)
        case let .split(axis, rect, children):
            cell = Cell(
                type: axis == .horizontal ? .leftRight : .topBottom,
                sx: rect.width,
                sy: rect.height,
                paneId: -1
            )
            cell.cells = children.map { build($0, parent: cell) }
        }
        cell.parent = parent
        return cell
    }

    // MARK: layout.c

    func layout_cell_is_top(_ start: Cell) -> Bool {
        var lc = start
        while lc !== root {
            let next = lc.parent!
            if next.type == .topBottom, lc !== next.cells.first {
                return false
            }
            lc = next
        }
        return true
    }

    func layout_cell_is_bottom(_ start: Cell) -> Bool {
        var lc = start
        while lc !== root {
            let next = lc.parent!
            if next.type == .topBottom, lc !== next.cells.last {
                return false
            }
            lc = next
        }
        return true
    }

    func layout_add_horizontal_border(_ lc: Cell) -> Bool {
        switch status {
        case .top: return layout_cell_is_top(lc)
        case .bottom: return layout_cell_is_bottom(lc)
        case .off: return false
        }
    }

    func layout_resize_check(_ lc: Cell, _ type: CellType) -> Int {
        var available: Int
        var minimum: Int
        if lc.type == .windowPane {
            if type == .leftRight {
                available = lc.sx
                if scrollbarColumns > 0 {
                    minimum = Self.paneMinimum + scrollbarColumns
                } else {
                    minimum = Self.paneMinimum
                }
            } else {
                available = lc.sy
                if layout_add_horizontal_border(lc) {
                    minimum = Self.paneMinimum + 1
                } else {
                    minimum = Self.paneMinimum
                }
            }
            if available > minimum {
                available -= minimum
            } else {
                available = 0
            }
        } else if lc.type == type {
            available = 0
            for lcchild in lc.cells {
                available += layout_resize_check(lcchild, type)
            }
        } else {
            minimum = Int(UInt32.max)
            for lcchild in lc.cells {
                available = layout_resize_check(lcchild, type)
                if available < minimum {
                    minimum = available
                }
            }
            available = minimum
        }
        return available
    }

    func layout_resize_adjust(_ lc: Cell, _ type: CellType, _ initialChange: Int) {
        var change = initialChange

        if type == .leftRight {
            lc.sx += change
        } else {
            lc.sy += change
        }

        if type == .windowPane {
            return
        }

        if lc.type != type {
            for lcchild in lc.cells {
                layout_resize_adjust(lcchild, type, change)
            }
            return
        }

        while change != 0 {
            var progressed = false
            for lcchild in lc.cells {
                if change == 0 {
                    break
                }
                if change > 0 {
                    layout_resize_adjust(lcchild, type, 1)
                    change -= 1
                    progressed = true
                    continue
                }
                if layout_resize_check(lcchild, type) > 0 {
                    layout_resize_adjust(lcchild, type, -1)
                    change += 1
                    progressed = true
                }
            }
            if !progressed {
                stalled = true
                return
            }
        }
    }

    func layout_resize(_ sx: Int, _ sy: Int) {
        let lc = root

        var xchange = sx - lc.sx
        let xlimit = layout_resize_check(lc, .leftRight)
        if xchange < 0, xchange < -xlimit {
            xchange = -xlimit
        }
        if xlimit == 0 {
            if sx <= lc.sx {
                xchange = 0
            } else {
                xchange = sx - lc.sx
            }
        }
        if xchange != 0 {
            layout_resize_adjust(lc, .leftRight, xchange)
        }

        var ychange = sy - lc.sy
        let ylimit = layout_resize_check(lc, .topBottom)
        if ychange < 0, ychange < -ylimit {
            ychange = -ylimit
        }
        if ylimit == 0 {
            if sy <= lc.sy {
                ychange = 0
            } else {
                ychange = sy - lc.sy
            }
        }
        if ychange != 0 {
            layout_resize_adjust(lc, .topBottom, ychange)
        }

        layout_fix_offsets()
    }

    func layout_fix_offsets() {
        root.xoff = 0
        root.yoff = 0
        layout_fix_offsets1(root)
    }

    private func layout_fix_offsets1(_ lc: Cell) {
        if lc.type == .leftRight {
            var xoff = lc.xoff
            for lcchild in lc.cells {
                lcchild.xoff = xoff
                lcchild.yoff = lc.yoff
                if lcchild.type != .windowPane {
                    layout_fix_offsets1(lcchild)
                }
                xoff += lcchild.sx + 1
            }
        } else {
            var yoff = lc.yoff
            for lcchild in lc.cells {
                lcchild.xoff = lc.xoff
                lcchild.yoff = yoff
                if lcchild.type != .windowPane {
                    layout_fix_offsets1(lcchild)
                }
                yoff += lcchild.sy + 1
            }
        }
    }

    // MARK: resize.c

    /// `resize_window`'s size handling: clamp the request, resize the layout,
    /// and leave the window no smaller than the layout. Returns the window
    /// size. (A zoomed window is unzoomed around this; callers model zoom by
    /// passing the visible single-pane layout.)
    @discardableResult
    func resize_window(_ requestedX: Int, _ requestedY: Int) -> (sx: Int, sy: Int) {
        var sx = requestedX
        var sy = requestedY
        if sx < Self.windowMinimum { sx = Self.windowMinimum }
        if sx > Self.windowMaximum { sx = Self.windowMaximum }
        if sy < Self.windowMinimum { sy = Self.windowMinimum }
        if sy > Self.windowMaximum { sy = Self.windowMaximum }

        layout_resize(sx, sy)

        if sx < root.sx { sx = root.sx }
        if sy < root.sy { sy = root.sy }
        return (sx, sy)
    }

    // MARK: Inspection

    /// The current tree as tmux would dump it (`#{window_layout}`).
    var layout: WindowLayout {
        WindowLayout(root: node(root))
    }

    private func node(_ lc: Cell) -> LayoutNode {
        let rect = CellRect(width: lc.sx, height: lc.sy, x: lc.xoff, y: lc.yoff)
        switch lc.type {
        case .windowPane:
            return .leaf(paneId: PaneId(lc.paneId), rect: rect)
        case .leftRight:
            return .split(axis: .horizontal, rect: rect, children: lc.cells.map(node))
        case .topBottom:
            return .split(axis: .vertical, rect: rect, children: lc.cells.map(node))
        }
    }

    /// Every cell's size in preorder, the order `TmuxLayoutResizeModel` uses.
    func preorderSizes() -> [(sx: Int, sy: Int)] {
        var result: [(sx: Int, sy: Int)] = []
        func visit(_ lc: Cell) {
            result.append((lc.sx, lc.sy))
            lc.cells.forEach(visit)
        }
        visit(root)
        return result
    }

    /// Convenience: a fresh copy of `layout` resized as tmux would.
    static func resized(
        _ layout: WindowLayout,
        toColumns columns: Int,
        rows: Int,
        options: TmuxLayoutResizeOptions = .tmuxDefaults
    ) -> WindowLayout {
        let reference = TmuxLayoutReference(layout, options: options)
        reference.resize_window(columns, rows)
        precondition(!reference.stalled, "tmux would spin on this layout")
        return reference.layout
    }
}

/// Deterministic SplitMix64, so a failing random case reproduces exactly.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random tmux layouts that satisfy tmux's invariants: siblings plus their
/// one-cell dividers fill the parent along a split and match it across.
/// Sizes are drawn so some panes sit exactly at their minimum.
enum RandomTmuxLayouts {
    indirect enum Shape {
        case pane
        case split(horizontal: Bool, children: [Shape])
    }

    static func shape(panes: Int, using rng: inout SplitMix64, depth: Int = 0) -> Shape {
        guard panes > 1 else { return .pane }
        let horizontal = Bool.random(using: &rng)
        let parts = depth < 3 ? Int.random(in: 2...min(panes, 3), using: &rng) : 2
        var counts = [Int](repeating: 1, count: parts)
        for _ in 0..<(panes - parts) {
            counts[Int.random(in: 0..<parts, using: &rng)] += 1
        }
        let children = counts.map { count -> Shape in
            var child = shape(panes: count, using: &rng, depth: depth + 1)
            // A split nested in one of the same direction is ordinary tmux
            // state: closing a pane promotes its last sibling split into the
            // grandparent without merging the two (`layout_destroy_cell`), so
            // `{A,[B,{C,D}]}` minus B is `{A,{C,D}}`; `join-pane`,
            // `move-pane` and restored layouts make them too. Keep most of
            // them, and turn a quarter the other way for variety.
            if case let .split(childHorizontal, grandchildren) = child,
               childHorizontal == horizontal,
               Int.random(in: 0..<4, using: &rng) == 0 {
                child = .split(horizontal: !horizontal, children: grandchildren)
            }
            return child
        }
        return .split(horizontal: horizontal, children: children)
    }

    static func minimumSize(_ shape: Shape) -> (columns: Int, rows: Int) {
        switch shape {
        case .pane:
            return (1, 1)
        case let .split(horizontal, children):
            let sizes = children.map(minimumSize)
            if horizontal {
                return (
                    sizes.reduce(-1) { $0 + $1.columns + 1 },
                    sizes.map(\.rows).max() ?? 1
                )
            }
            return (
                sizes.map(\.columns).max() ?? 1,
                sizes.reduce(-1) { $0 + $1.rows + 1 }
            )
        }
    }

    static func layout(
        _ shape: Shape,
        columns: Int,
        rows: Int,
        using rng: inout SplitMix64
    ) -> WindowLayout {
        var nextPane = Int.random(in: 0..<40, using: &rng)
        let root = node(shape, columns: columns, rows: rows, x: 0, y: 0, nextPane: &nextPane, using: &rng)
        return WindowLayout(root: root)
    }

    private static func node(
        _ shape: Shape,
        columns: Int,
        rows: Int,
        x: Int,
        y: Int,
        nextPane: inout Int,
        using rng: inout SplitMix64
    ) -> LayoutNode {
        let rect = CellRect(width: columns, height: rows, x: x, y: y)
        switch shape {
        case .pane:
            defer { nextPane += Int.random(in: 1...3, using: &rng) }
            return .leaf(paneId: PaneId(nextPane), rect: rect)
        case let .split(horizontal, children):
            let minimums = children.map { minimumSize($0) }
            let total = horizontal ? columns : rows
            var lengths = minimums.map { horizontal ? $0.columns : $0.rows }
            var slack = total - (lengths.reduce(0, +) + children.count - 1)
            // Uneven: hand slack out in random lumps, sometimes leaving a
            // child at its minimum.
            while slack > 0 {
                let child = Int.random(in: 0..<children.count, using: &rng)
                let lump = Int.random(in: 1...max(1, slack), using: &rng)
                lengths[child] += lump
                slack -= lump
            }
            var offset = horizontal ? x : y
            var nodes: [LayoutNode] = []
            for (index, child) in children.enumerated() {
                let childColumns = horizontal ? lengths[index] : columns
                let childRows = horizontal ? rows : lengths[index]
                nodes.append(node(
                    child,
                    columns: childColumns,
                    rows: childRows,
                    x: horizontal ? offset : x,
                    y: horizontal ? y : offset,
                    nextPane: &nextPane,
                    using: &rng
                ))
                offset += lengths[index] + 1
            }
            return .split(axis: horizontal ? .horizontal : .vertical, rect: rect, children: nodes)
        }
    }

    /// A random tree of `panes` panes at a random size no smaller than its
    /// minimum, sometimes exactly at it.
    static func random(panes: Int, maximumSide: Int, using rng: inout SplitMix64) -> WindowLayout {
        let shape = shape(panes: panes, using: &rng)
        let minimum = minimumSize(shape)
        let atMinimum = Int.random(in: 0..<8, using: &rng) == 0
        let columns = atMinimum
            ? minimum.columns
            : Int.random(in: minimum.columns...max(minimum.columns, maximumSide), using: &rng)
        let rows = atMinimum
            ? minimum.rows
            : Int.random(in: minimum.rows...max(minimum.rows, maximumSide / 3), using: &rng)
        return layout(shape, columns: columns, rows: rows, using: &rng)
    }
}

extension WindowLayout {
    func rect(ofPane paneId: PaneId) -> CellRect? {
        leaves.first { $0.paneId == paneId }?.rect
    }
}
