import Foundation

/// A cell's grid geometry within a tmux window layout, in character cells.
///
/// `x`/`y` are the top-left offset of the cell inside the window grid;
/// `width`/`height` are its size. tmux reserves a one-cell gutter between
/// siblings for the divider, so for a horizontal split the invariant is
/// `sum(child.width + 1) - 1 == parent.width` and the divider renders in
/// the column at `child.x + child.width`. The same holds vertically.
public struct CellRect: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let x: Int
    public let y: Int

    public init(width: Int, height: Int, x: Int, y: Int) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}

/// How a split node arranges its children.
///
/// tmux's layout grammar uses `{…}` for side-by-side panes (the result of
/// `split-window -h`) and `[…]` for stacked panes (`split-window -v`). Note
/// this is the opposite of iTerm2's chord naming, where ⌘D ("vertical
/// split") produces a side-by-side `{…}` layout.
public enum LayoutAxis: Equatable, Sendable {
    /// `{…}` — children laid out left-to-right.
    case horizontal
    /// `[…]` — children laid out top-to-bottom.
    case vertical
}

/// One node of a parsed tmux window layout tree.
///
/// A leaf carries the pane id that renders in its cell. A split carries the
/// axis and its ordered children. The tree is `indirect` because splits nest
/// arbitrarily (`{a,b[c,d]}`).
public indirect enum LayoutNode: Equatable, Sendable {
    case leaf(paneId: PaneId, rect: CellRect)
    case split(axis: LayoutAxis, rect: CellRect, children: [LayoutNode])

    public var rect: CellRect {
        switch self {
        case let .leaf(_, rect): return rect
        case let .split(_, rect, _): return rect
        }
    }
}

/// A parsed tmux window layout string.
///
/// tmux emits these as the `#{window_layout}` / `#{window_visible_layout}`
/// format variables and in the `%layout-change` notification. The wire form
/// is a 4-hex checksum, a comma, then a recursive cell grammar:
///
///   - leaf:  `SXxSY,X,Y,paneID`         (e.g. `80x24,0,0,0`)
///   - hsplit: `SXxSY,X,Y{cell,cell,…}`  (side-by-side)
///   - vsplit: `SXxSY,X,Y[cell,cell,…]`  (stacked)
///
/// The pane id of a leaf is numeric with no `%` prefix. The checksum is
/// skipped on parse — tmux's own `layout_parse` advances five bytes past it
/// and never validates it, and Tessera never *emits* layouts so never needs
/// to compute one.
///
/// Parsing is total: any malformed input returns `nil`. Callers treat a `nil`
/// layout as "single pane / today's behavior" (fail-open), so a layout-string
/// quirk can never wedge rendering.
public struct WindowLayout: Equatable, Sendable {
    public let root: LayoutNode

    public init(root: LayoutNode) {
        self.root = root
    }

    /// Leaves in depth-first, document (left-to-right / top-to-bottom) order.
    ///
    /// This is the order tmux uses when cycling panes with `select-pane -t :.+`
    /// and the order Tessera's ⌘]/⌘[ pane navigation walks.
    public var leaves: [(paneId: PaneId, rect: CellRect)] {
        var result: [(paneId: PaneId, rect: CellRect)] = []
        Self.collectLeaves(root, into: &result)
        return result
    }

    /// Pane ids in DFS order. A single-pane window yields exactly one.
    public var paneIds: [PaneId] {
        leaves.map(\.paneId)
    }

    /// Number of panes (leaves) in the layout. Always ≥ 1 for a valid tree.
    public var paneCount: Int {
        var count = 0
        Self.countLeaves(root, into: &count)
        return count
    }

    private static func collectLeaves(
        _ node: LayoutNode,
        into result: inout [(paneId: PaneId, rect: CellRect)]
    ) {
        switch node {
        case let .leaf(paneId, rect):
            result.append((paneId: paneId, rect: rect))
        case let .split(_, _, children):
            for child in children {
                collectLeaves(child, into: &result)
            }
        }
    }

    private static func countLeaves(_ node: LayoutNode, into count: inout Int) {
        switch node {
        case .leaf:
            count += 1
        case let .split(_, _, children):
            for child in children {
                countLeaves(child, into: &count)
            }
        }
    }

    // MARK: - Parsing

    /// Hard caps that keep parsing total and fail-open against pathological
    /// input. The layout token arrives straight off the wire (a torn or
    /// hostile `%layout-change` / `list-windows` frame applies no length or
    /// nesting bound upstream), and the parser is mutually recursive — without
    /// these, a frame of ~150 KB of `{` overflows the stack and SIGSEGVs the
    /// app. Real tmux layouts are a few hundred bytes and nest a handful of
    /// levels deep, so both caps are orders of magnitude above anything
    /// legitimate; exceeding either returns `nil` (→ single-pane fast path).
    private static let maxByteLength = 32_768
    private static let maxDepth = 256

    /// Parse a tmux layout string (with its leading checksum) into a tree.
    /// Returns `nil` for any malformed input — callers fail open to the
    /// single-pane path.
    public static func parse(_ string: String) -> WindowLayout? {
        let bytes = Array(string.utf8)
        guard bytes.count <= maxByteLength else { return nil }
        // Skip the "%04x," checksum prefix. tmux always writes exactly four
        // hex digits then a comma; locate the first comma defensively and
        // require the prefix to be non-empty hex so a stray body line can't
        // parse as a layout.
        guard let comma = bytes.firstIndex(of: 0x2C /* , */), comma > 0 else {
            return nil
        }
        for index in 0..<comma where !isHexDigit(bytes[index]) {
            return nil
        }

        var scanner = Scanner(bytes: bytes, index: comma + 1)
        guard let root = parseCell(&scanner, depth: 0), scanner.isAtEnd else {
            return nil
        }
        return WindowLayout(root: root)
    }

    /// Parse a single cell: `SXxSY,X,Y` followed by `{…}`, `[…]`, or `,paneID`.
    /// `depth` bounds nesting so a deeply-nested string returns nil rather than
    /// overflowing the stack.
    private static func parseCell(_ scanner: inout Scanner, depth: Int) -> LayoutNode? {
        guard depth <= maxDepth else { return nil }
        guard let width = scanner.readInt(),
              scanner.consume(0x78 /* x */),
              let height = scanner.readInt(),
              scanner.consume(0x2C /* , */),
              let x = scanner.readInt(),
              scanner.consume(0x2C /* , */),
              let y = scanner.readInt()
        else { return nil }

        let rect = CellRect(width: width, height: height, x: x, y: y)

        switch scanner.peek() {
        case 0x7B /* { */:
            scanner.advance()
            guard let children = parseChildren(&scanner, close: 0x7D /* } */, depth: depth + 1) else {
                return nil
            }
            return .split(axis: .horizontal, rect: rect, children: children)
        case 0x5B /* [ */:
            scanner.advance()
            guard let children = parseChildren(&scanner, close: 0x5D /* ] */, depth: depth + 1) else {
                return nil
            }
            return .split(axis: .vertical, rect: rect, children: children)
        case 0x2C /* , */:
            // A `,N` immediately after `SXxSY,X,Y` (with no `{`/`[`) is always
            // this cell's pane id — sibling separators only appear *after* a
            // complete cell, handled by parseChildren. The pane id is never
            // followed by `x`, which is what disambiguates it from a sibling's
            // width in a flat comma tokenizer.
            scanner.advance()
            guard let paneId = scanner.readInt() else { return nil }
            return .leaf(paneId: PaneId(paneId), rect: rect)
        default:
            // A cell must be a split or a leaf; anything else is malformed.
            return nil
        }
    }

    /// Parse comma-separated child cells until the matching close bracket.
    /// A split with zero children is malformed (tmux never emits one).
    private static func parseChildren(_ scanner: inout Scanner, close: UInt8, depth: Int) -> [LayoutNode]? {
        guard depth <= maxDepth else { return nil }
        var children: [LayoutNode] = []
        while true {
            guard let child = parseCell(&scanner, depth: depth) else { return nil }
            children.append(child)
            switch scanner.peek() {
            case 0x2C /* , */:
                scanner.advance()
                continue
            case close:
                scanner.advance()
                return children.count >= 1 ? children : nil
            default:
                return nil
            }
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)   // 0-9
            || (byte >= 0x61 && byte <= 0x66) // a-f
            || (byte >= 0x41 && byte <= 0x46) // A-F
    }

    /// Minimal forward-only byte cursor for the layout grammar.
    private struct Scanner {
        let bytes: [UInt8]
        var index: Int

        var isAtEnd: Bool { index >= bytes.count }

        func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        mutating func advance() {
            index += 1
        }

        /// If the next byte equals `byte`, consume it and return true.
        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        /// Read one or more decimal digits as an `Int`. Returns nil if the
        /// cursor is not on a digit.
        mutating func readInt() -> Int? {
            let start = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                index += 1
            }
            guard index > start else { return nil }
            return Int(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }
}
