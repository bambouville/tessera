import SwiftUI
import SwiftTerm
import TmuxControl

// MARK: - Layout math

/// Pixel frames for one pane: its chrome header strip and its terminal surface.
/// `headerFrame.height == 0` means "no header" (single-pane / zoomed windows).
struct PaneFrame: Identifiable {
    let paneId: PaneId
    let headerFrame: CGRect
    let surfaceFrame: CGRect

    var id: PaneId { paneId }

    /// The full pane footprint (header + surface) — used for the focus ring.
    var paneBox: CGRect {
        headerFrame.height > 0 ? headerFrame.union(surfaceFrame) : surfaceFrame
    }
}

private let paneFocusRingLineWidth: CGFloat = 1.5

private func paneLayoutBounds(_ frames: [PaneFrame]) -> CGRect {
    frames.reduce(CGRect.null) { partial, frame in
        partial.union(frame.paneBox)
    }
}

private func paneFocusRingRect(
    for frame: PaneFrame,
    layoutBounds: CGRect,
    containerSize: CGSize
) -> CGRect {
    var rect = frame.paneBox
    let epsilon: CGFloat = 0.5

    if abs(rect.minX - layoutBounds.minX) <= epsilon {
        let oldMaxX = rect.maxX
        rect.origin.x = 0
        rect.size.width = oldMaxX
    }
    if abs(rect.maxX - layoutBounds.maxX) <= epsilon {
        rect.size.width = max(0, containerSize.width - rect.minX)
    }
    if abs(rect.minY - layoutBounds.minY) <= epsilon {
        let oldMaxY = rect.maxY
        rect.origin.y = 0
        rect.size.height = oldMaxY
    }
    if abs(rect.maxY - layoutBounds.maxY) <= epsilon {
        rect.size.height = max(0, containerSize.height - rect.minY)
    }

    return rect.insetBy(dx: paneFocusRingLineWidth / 2, dy: paneFocusRingLineWidth / 2)
}

private struct PaneFocusRing: View {
    let rect: CGRect
    let color: SwiftUI.Color

    var body: some View {
        Rectangle()
            .stroke(color, lineWidth: paneFocusRingLineWidth)
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

private func paneGridFocusRingLines(
    for frame: PaneFrame,
    layoutBounds: CGRect,
    containerSize: CGSize
) -> [CGRect] {
    let box = frame.paneBox
    let lineWidth = paneFocusRingLineWidth
    let epsilon: CGFloat = 0.5

    let touchesLeft = abs(box.minX - layoutBounds.minX) <= epsilon
    let touchesRight = abs(box.maxX - layoutBounds.maxX) <= epsilon
    let touchesTop = abs(box.minY - layoutBounds.minY) <= epsilon
    let touchesBottom = abs(box.maxY - layoutBounds.maxY) <= epsilon

    let minX = touchesLeft ? 0 : max(0, box.minX - lineWidth)
    let maxX = touchesRight ? containerSize.width : min(containerSize.width, box.maxX + lineWidth)
    let minY = touchesTop ? 0 : max(0, box.minY - lineWidth)
    let maxY = touchesBottom ? containerSize.height : min(containerSize.height, box.maxY + lineWidth)

    guard maxX > minX, maxY > minY else { return [] }

    return [
        CGRect(
            x: minX,
            y: touchesTop ? minY : max(0, box.minY - lineWidth),
            width: maxX - minX,
            height: lineWidth
        ),
        CGRect(
            x: minX,
            y: touchesBottom ? maxY - lineWidth : min(containerSize.height - lineWidth, box.maxY),
            width: maxX - minX,
            height: lineWidth
        ),
        CGRect(
            x: touchesLeft ? minX : max(0, box.minX - lineWidth),
            y: minY,
            width: lineWidth,
            height: maxY - minY
        ),
        CGRect(
            x: touchesRight ? maxX - lineWidth : min(containerSize.width - lineWidth, box.maxX),
            y: minY,
            width: lineWidth,
            height: maxY - minY
        ),
    ]
}

private struct PaneGridFocusRing: View {
    let frame: PaneFrame
    let layoutBounds: CGRect
    let containerSize: CGSize
    let color: SwiftUI.Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(paneGridFocusRingLines(
                for: frame,
                layoutBounds: layoutBounds,
                containerSize: containerSize
            ).enumerated()), id: \.offset) { _, line in
                Rectangle()
                    .fill(color)
                    .frame(width: max(0, line.width), height: max(0, line.height))
                    .offset(x: line.minX, y: line.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Pure geometry for laying out a tmux window layout tree into pixel frames.
///
/// The hard constraint (plan risk #2): a pane's terminal **surface** must be an
/// exact integer number of cells — `rect.width × rect.height` — so SwiftTerm's
/// own grid snapping matches the grid tmux laid the pane out to. If the surface
/// were a fractional number of cells, SwiftTerm would compute a different
/// cols/rows than tmux and every live escape would mis-render.
///
/// Per-pane headers are chrome that sits OUTSIDE the surface: each header eats
/// `headerHeight` pixels ABOVE its pane's surface. To keep total height within
/// bounds without shrinking any surface, the caller reserves header rows when
/// it sizes the tmux client (see `PaneGridView.reservedHeaderRows`) — so the
/// surfaces stay exact cell multiples and the headers fill the reserved space.
enum PaneLayoutMath {
    /// The maximum number of leaves crossed by any vertical line through the
    /// layout — i.e. the deepest stack of pane headers in a single column. The
    /// caller reserves this many rows (one header = one cell tall) from the
    /// tmux client size so the tallest column's headers + content still fit.
    static func maxVerticalLeaves(_ node: LayoutNode) -> Int {
        switch node {
        case .leaf:
            return 1
        case let .split(axis, _, children):
            let counts = children.map { maxVerticalLeaves($0) }
            switch axis {
            case .horizontal: // side-by-side {} — a vertical line hits one child
                return counts.max() ?? 1
            case .vertical:   // stacked [] — a vertical line crosses every child
                return counts.reduce(0, +)
            }
        }
    }

    /// Compute pixel frames for every leaf of the layout. `headerHeight == 0`
    /// places surfaces at exact cell offsets (no header chrome). With a header,
    /// each leaf's surface is pushed down by the accumulated header height of
    /// the panes stacked above it in the same column.
    static func frames(root: LayoutNode, cellSize: CGSize, headerHeight: CGFloat) -> [PaneFrame] {
        var frames: [PaneFrame] = []
        var dividers: [CGRect] = []
        _ = walk(root, originX: 0, originY: 0, cellSize: cellSize, headerHeight: headerHeight,
                 dividerThickness: 0, frames: &frames, dividers: &dividers)
        return frames
    }

    /// Hairline divider rects, one per split gutter, each a `thickness`-pt line
    /// centered in its 1-cell gutter and spanning the full extent of the split.
    /// Side-by-side splits yield vertical lines; stacked splits yield horizontal
    /// lines. The view fills these with `chromeTokens.border`. Shares `walk` with
    /// `frames` so the geometry can never drift between the two.
    static func dividers(
        root: LayoutNode,
        cellSize: CGSize,
        headerHeight: CGFloat,
        thickness: CGFloat
    ) -> [CGRect] {
        var frames: [PaneFrame] = []
        var dividers: [CGRect] = []
        _ = walk(root, originX: 0, originY: 0, cellSize: cellSize, headerHeight: headerHeight,
                 dividerThickness: thickness, frames: &frames, dividers: &dividers)
        return dividers
    }

    /// Full one-cell gutters between split panes. Used when a native tmux render
    /// needs its border glyphs masked before Tessera draws its own hairlines.
    static func gutters(root: LayoutNode, cellSize: CGSize, headerHeight: CGFloat) -> [CGRect] {
        var gutters: [CGRect] = []
        _ = walkGutters(
            root,
            originX: 0,
            originY: 0,
            cellSize: cellSize,
            headerHeight: headerHeight,
            gutters: &gutters
        )
        return gutters
    }

    /// The pane frame whose terminal **surface** contains `point` (expressed in
    /// the same top-left pixel space `frames` produces), or `nil` when the point
    /// lands in a divider gutter or the remainder margin.
    ///
    /// Callers that want header-area hit testing should check `paneBox`
    /// instead; this helper intentionally resolves only terminal surface cells,
    /// so a tap in a 1-cell divider gutter returns `nil`.
    static func frame(
        at point: CGPoint,
        root: LayoutNode,
        cellSize: CGSize,
        headerHeight: CGFloat = 0
    ) -> PaneFrame? {
        frames(root: root, cellSize: cellSize, headerHeight: headerHeight)
            .first(where: { $0.surfaceFrame.contains(point) })
    }

    /// The pane id at `point`, or `nil`. Thin wrapper over `frame(at:)`.
    static func pane(
        at point: CGPoint,
        root: LayoutNode,
        cellSize: CGSize,
        headerHeight: CGFloat = 0
    ) -> PaneId? {
        frame(at: point, root: root, cellSize: cellSize, headerHeight: headerHeight)?.paneId
    }

    /// The ✕ close affordance's rect for a pane — a one-cell square anchored at
    /// the pane's top-right corner (matching the SSH header's height×height ✕
    /// button). On mosh this sits over tmux's reserved title row (`pane-border-
    /// status top`) for top-row panes; for nested bottom panes tmux paints the
    /// title on the divider above the cell, so the ✕ sits on the pane's first
    /// content row instead (the accepted nested-stack caveat). The Tessera ✕
    /// overlay draws here and the tap handler hit-tests here — one source so the
    /// glyph and its touch target can never drift.
    static func closeButtonRect(for frame: PaneFrame, cellSize: CGSize) -> CGRect {
        let side = min(cellSize.height, frame.surfaceFrame.width)
        return CGRect(
            x: frame.surfaceFrame.maxX - side,
            y: frame.surfaceFrame.minY,
            width: side,
            height: side
        )
    }

    /// Close button rect matching `PaneHeaderView`: a one-header-cell square at
    /// the leading edge of the header. If a frame has no header, falls back to
    /// the legacy mosh top-right affordance.
    static func headerCloseButtonRect(for frame: PaneFrame, cellSize: CGSize) -> CGRect {
        guard frame.headerFrame.height > 0 else {
            return closeButtonRect(for: frame, cellSize: cellSize)
        }
        let side = min(frame.headerFrame.height, frame.headerFrame.width)
        return CGRect(
            x: frame.headerFrame.minX,
            y: frame.headerFrame.minY,
            width: side,
            height: side
        )
    }

    @discardableResult
    private static func walk(
        _ node: LayoutNode,
        originX: CGFloat,
        originY: CGFloat,
        cellSize: CGSize,
        headerHeight: CGFloat,
        dividerThickness: CGFloat,
        frames: inout [PaneFrame],
        dividers: inout [CGRect]
    ) -> CGSize {
        switch node {
        case let .leaf(paneId, rect):
            let w = CGFloat(rect.width) * cellSize.width
            let h = CGFloat(rect.height) * cellSize.height
            let header = CGRect(x: originX, y: originY, width: w, height: headerHeight)
            let surface = CGRect(x: originX, y: originY + headerHeight, width: w, height: h)
            frames.append(PaneFrame(paneId: paneId, headerFrame: header, surfaceFrame: surface))
            return CGSize(width: w, height: headerHeight + h)

        case let .split(axis, _, children):
            switch axis {
            case .horizontal: // children left-to-right, 1-cell divider gutter
                var x = originX
                var maxH: CGFloat = 0
                var gutterXs: [CGFloat] = []
                for (i, child) in children.enumerated() {
                    if i > 0 { gutterXs.append(x); x += cellSize.width }
                    let size = walk(child, originX: x, originY: originY,
                                    cellSize: cellSize, headerHeight: headerHeight,
                                    dividerThickness: dividerThickness,
                                    frames: &frames, dividers: &dividers)
                    x += size.width
                    maxH = max(maxH, size.height)
                }
                if dividerThickness > 0 {
                    for gx in gutterXs {
                        dividers.append(CGRect(
                            x: gx + (cellSize.width - dividerThickness) / 2,
                            y: originY, width: dividerThickness, height: maxH
                        ))
                    }
                }
                return CGSize(width: x - originX, height: maxH)

            case .vertical: // children top-to-bottom, 1-cell divider gutter
                var y = originY
                var maxW: CGFloat = 0
                var gutterYs: [CGFloat] = []
                for (i, child) in children.enumerated() {
                    if i > 0 { gutterYs.append(y); y += cellSize.height }
                    let size = walk(child, originX: originX, originY: y,
                                    cellSize: cellSize, headerHeight: headerHeight,
                                    dividerThickness: dividerThickness,
                                    frames: &frames, dividers: &dividers)
                    y += size.height
                    maxW = max(maxW, size.width)
                }
                if dividerThickness > 0 {
                    for gy in gutterYs {
                        dividers.append(CGRect(
                            x: originX, y: gy + (cellSize.height - dividerThickness) / 2,
                            width: maxW, height: dividerThickness
                        ))
                    }
                }
                return CGSize(width: maxW, height: y - originY)
            }
        }
    }

    @discardableResult
    private static func walkGutters(
        _ node: LayoutNode,
        originX: CGFloat,
        originY: CGFloat,
        cellSize: CGSize,
        headerHeight: CGFloat,
        gutters: inout [CGRect]
    ) -> CGSize {
        switch node {
        case let .leaf(_, rect):
            return CGSize(
                width: CGFloat(rect.width) * cellSize.width,
                height: headerHeight + CGFloat(rect.height) * cellSize.height
            )

        case let .split(axis, _, children):
            switch axis {
            case .horizontal:
                var x = originX
                var maxH: CGFloat = 0
                var gutterXs: [CGFloat] = []
                for (i, child) in children.enumerated() {
                    if i > 0 {
                        gutterXs.append(x)
                        x += cellSize.width
                    }
                    let size = walkGutters(
                        child,
                        originX: x,
                        originY: originY,
                        cellSize: cellSize,
                        headerHeight: headerHeight,
                        gutters: &gutters
                    )
                    x += size.width
                    maxH = max(maxH, size.height)
                }
                for gx in gutterXs {
                    gutters.append(CGRect(x: gx, y: originY, width: cellSize.width, height: maxH))
                }
                return CGSize(width: x - originX, height: maxH)

            case .vertical:
                var y = originY
                var maxW: CGFloat = 0
                var gutterYs: [CGFloat] = []
                for (i, child) in children.enumerated() {
                    if i > 0 {
                        gutterYs.append(y)
                        y += cellSize.height
                    }
                    let size = walkGutters(
                        child,
                        originX: originX,
                        originY: y,
                        cellSize: cellSize,
                        headerHeight: headerHeight,
                        gutters: &gutters
                    )
                    y += size.height
                    maxW = max(maxW, size.width)
                }
                for gy in gutterYs {
                    gutters.append(CGRect(x: originX, y: gy, width: maxW, height: cellSize.height))
                }
                return CGSize(width: maxW, height: y - originY)
            }
        }
    }
}

// MARK: - Per-pane runtime

/// Render state for one pane in the grid: its own `TerminalBox` (and thus its
/// own SwiftTerm surface), kept stable across re-renders so a pane's content
/// survives layout changes that don't remove it.
@MainActor
final class PaneRuntime {
    let paneId: PaneId
    let box: TerminalBox

    init(paneId: PaneId) {
        self.paneId = paneId
        self.box = TerminalBox(traceLabel: "pane-\(paneId.rawValue)")
    }
}

/// Stable per-pane runtime storage. A reference type held in `@State` so that
/// looking up / creating a runtime during `body` mutates only the class's
/// internal dictionary (not the `@State` value itself), avoiding SwiftUI's
/// "modifying state during view update" hazard.
@MainActor
final class PaneRuntimeStore {
    private var runtimes: [PaneId: PaneRuntime] = [:]

    func runtime(for paneId: PaneId) -> PaneRuntime {
        if let existing = runtimes[paneId] { return existing }
        let created = PaneRuntime(paneId: paneId)
        runtimes[paneId] = created
        return created
    }

    /// Look up an existing runtime without creating one (used off the render
    /// path, e.g. from the `paneDidRefresh` callback for kitty restore).
    func existingRuntime(for paneId: PaneId) -> PaneRuntime? {
        runtimes[paneId]
    }

    /// Drop runtimes for panes that no longer exist, unregistering their sinks
    /// and discarding their kitty snapshots.
    func prune(keeping liveIds: Set<PaneId>, controller: TmuxController, kitty: KittyPaneModeStore) {
        for paneId in runtimes.keys where !liveIds.contains(paneId) {
            controller.setPaneSink(paneId, nil)
            kitty.discard(paneId)
            runtimes.removeValue(forKey: paneId)
        }
    }
}

/// Per-pane analog of `KittyWindowModeStore`: kitty keyboard flags and the 2004
/// bracketed-paste flag are per-window state on the shared terminal, and in a
/// split each pane is its own surface, so the flags become per-PANE state.
/// Snapshot on surface dismantle (window swap / zoom collapse), restore after a
/// per-pane capture-repaint (`paneDidRefresh`) — which rebuilds the screen but
/// not these client-side modes.
@MainActor
final class KittyPaneModeStore {
    private var snapshots: [PaneId: KittyKeyboardModeSnapshot] = [:]
    private var bracketedPaste: [PaneId: Bool] = [:]

    /// Capture a pane's kitty + 2004 state before its surface is torn down.
    func snapshot(_ paneId: PaneId, from terminal: Terminal) {
        let snapshot = terminal.keyboardModeSnapshot()
        if snapshot.isEmpty {
            snapshots.removeValue(forKey: paneId)
        } else {
            snapshots[paneId] = snapshot
        }
        bracketedPaste[paneId] = terminal.bracketedPasteMode
    }

    /// Restore a pane's modes after its surface repaints. The `#{alternate_on}`
    /// staleness guard ports from the window store: kitty flags pushed while in
    /// the alternate screen are dropped if the pane came back on the normal
    /// buffer (read live from the repainted terminal).
    func restore(_ paneId: PaneId, into box: TerminalBox) {
        guard let terminal = box.view?.getTerminal() else { return }
        let paneInAltScreen = terminal.isCurrentBufferAlternate
        if let saved = snapshots[paneId] {
            let restored = paneInAltScreen ? saved : saved.clearingAlternateScreenState()
            snapshots[paneId] = restored
            terminal.restoreKeyboardMode(restored)
        } else {
            terminal.resetKeyboardMode()
        }
        let wanted = bracketedPaste[paneId] ?? false
        box.feed(Array((wanted ? "\u{1B}[?2004h" : "\u{1B}[?2004l").utf8)[...])
    }

    func discard(_ paneId: PaneId) {
        snapshots.removeValue(forKey: paneId)
        bracketedPaste.removeValue(forKey: paneId)
    }
}

// MARK: - Pane header

/// Slim per-pane title bar (iTerm2-style) shown only when a window has >1 pane.
/// Carries the pane's own title and a close ✕. Minimal/flat per the design
/// memories — frosted fill, hairline bottom border, monochrome glyph; the
/// focused pane's header takes a soft accent tint (the only color cue).
struct PaneHeaderView: View {
    let title: String
    let isFocused: Bool
    let height: CGFloat
    let chrome: DesignTokens
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: max(8, height * 0.40), weight: .semibold))
                    .foregroundStyle(isFocused ? chrome.accent : chrome.fgDim)
                    .frame(width: height, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.system(size: max(8, height * 0.52), weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isFocused ? chrome.fg : chrome.fgMuted)

            Spacer(minLength: 0)
        }
        .padding(.trailing, 6)
        .frame(height: height)
        .background(isFocused ? chrome.accentSoft : chrome.panelBg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isFocused ? chrome.accent.opacity(0.5) : chrome.border)
                .frame(height: 1)
        }
    }
}

/// Mosh-only pane chrome, drawn over the single shared terminal that the remote
/// tmux client paints all panes into. tmux still reserves the per-pane title row
/// (`pane-border-status top`) so pane content geometry is stable; Tessera masks
/// that native row/gutters and draws the same header, dividers, and active ring
/// used by the SSH pane grid.
///
/// Crucially **non-interactive** (`allowsHitTesting(false)`): tap-to-focus and
/// close are resolved by the shared terminal's UIKit recognizer, checking the
/// same `PaneFrame`s and `PaneLayoutMath.headerCloseButtonRect`. Routing through
/// one recognizer avoids SwiftUI-button-vs-UIKit-gesture double-fire.
struct MoshPaneChromeOverlay: View {
    let root: LayoutNode
    let frames: [PaneFrame]
    let titles: [PaneId: String]
    let cellSize: CGSize
    let activePaneId: PaneId?
    let chrome: DesignTokens
    let backgroundColor: SwiftUI.Color

    private let dividerThickness: CGFloat = 1

    var body: some View {
        let gutters = PaneLayoutMath.gutters(root: root, cellSize: cellSize, headerHeight: 0)
        let dividers = PaneLayoutMath.dividers(
            root: root,
            cellSize: cellSize,
            headerHeight: 0,
            thickness: dividerThickness
        )
        let layoutBounds = paneLayoutBounds(frames)

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(gutters, id: \.self) { gutter in
                    Rectangle()
                        .fill(backgroundColor)
                        .frame(width: gutter.width, height: gutter.height)
                        .offset(x: gutter.minX, y: gutter.minY)
                }

                ForEach(dividers, id: \.self) { line in
                    Rectangle()
                        .fill(chrome.border)
                        .frame(width: line.width, height: line.height)
                        .offset(x: line.minX, y: line.minY)
                }

                ForEach(frames) { frame in
                    let isFocused = frame.paneId == activePaneId

                    if frame.headerFrame.height > 0 {
                        Rectangle()
                            .fill(backgroundColor)
                            .frame(width: frame.headerFrame.width, height: frame.headerFrame.height)
                            .offset(x: frame.headerFrame.minX, y: frame.headerFrame.minY)

                        PaneHeaderView(
                            title: titles[frame.paneId] ?? frame.paneId.description,
                            isFocused: isFocused,
                            height: frame.headerFrame.height,
                            chrome: chrome,
                            onClose: {}
                        )
                        .frame(width: frame.headerFrame.width, height: frame.headerFrame.height)
                        .offset(x: frame.headerFrame.minX, y: frame.headerFrame.minY)
                    }

                    if isFocused, frames.count > 1 {
                        PaneFocusRing(
                            rect: paneFocusRingRect(
                                for: frame,
                                layoutBounds: layoutBounds,
                                containerSize: geo.size
                            ),
                            color: chrome.accent.opacity(0.9)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Grid

/// The multi-pane grid for a tmux window with more than one pane. Lays out one
/// `TerminalSurfaceBound` per layout leaf at absolute cell-multiple frames, each
/// fed by its own per-pane sink from the controller, each topped by its own slim
/// header. Single-pane windows never mount this — they keep the shared-terminal
/// fast path.
///
/// Server-authoritative: every pane is (re)built from `capture-pane` on mount
/// via `tmux.refreshPane`, so mounting/unmounting is always safe.
struct PaneGridView: View {
    let window: TmuxController.WindowInfo
    let tmux: TmuxController
    let cellSize: CGSize
    let chrome: DesignTokens
    let backgroundColor: SwiftUI.Color
    let tmuxShortcutsEnabled: Bool
    let onTmuxShortcut: (TesseraTmuxShortcut) -> Void
    let onFindShortcut: ((TesseraFindShortcut) -> Void)?
    let onSwitcherShortcut: ((TesseraSwitcherShortcut) -> Void)?
    let onOpenSettings: (() -> Void)?
    let onUserActivity: (() -> Void)?
    let suppressFindReclaim: Bool

    /// Per-pane kitty/2004 mode store, owned by the session so it survives
    /// window switches (panes restore their modes on swap-in repaint).
    let kittyPaneModes: KittyPaneModeStore
    /// Rebind the find bar to the focused pane's terminal box (find is scoped
    /// to the focused pane). Called whenever focus moves.
    let onFocusedBoxChanged: (TerminalBox) -> Void
    /// The focused pane just repainted — re-run any open find against it.
    let onFocusedPaneRefreshed: () -> Void
    /// A visible pane rang its bell — ring with that pane's own title.
    let onPaneBell: (_ paneTitle: String?) -> Void

    /// Per-pane runtimes, persisted across re-renders (reset when the active
    /// window changes via `.id(window.id)` on this view).
    @State private var store = PaneRuntimeStore()
    @State private var lastGridSize: CGSize? = nil
    @State private var lastPushedSize: (cols: Int, rows: Int)? = nil

    /// The layout actually painted: the collapsed single leaf while zoomed,
    /// otherwise the full layout.
    private var renderLayout: WindowLayout? {
        window.isZoomed ? (window.visibleLayout ?? window.layout) : window.layout
    }

    /// One header per pane, exactly one cell tall, so the reserved-row math
    /// stays exact. Headers only appear when more than one pane is visible.
    private var headerHeight: CGFloat {
        showsHeaders ? cellSize.height : 0
    }

    private var showsHeaders: Bool {
        (renderLayout?.paneCount ?? 1) > 1
    }

    /// Rows reserved from the tmux client size for the deepest stack of pane
    /// headers (so surfaces stay exact cell multiples and still fit on screen).
    private var reservedHeaderRows: Int {
        guard showsHeaders, let root = renderLayout?.root else { return 0 }
        return PaneLayoutMath.maxVerticalLeaves(root)
    }

    private var paneFrames: [PaneFrame] {
        guard let root = renderLayout?.root else { return [] }
        return PaneLayoutMath.frames(root: root, cellSize: cellSize, headerHeight: headerHeight)
    }

    /// Hairline thickness for the gutter dividers (1pt, matching the app's other
    /// hairline borders). Kept off the cell math so surfaces stay exact.
    private let dividerThickness: CGFloat = 1

    /// Hairline lines drawn in the 1-cell gutters between split panes. Only when
    /// more than one pane is visible (single/zoomed windows have no gutters).
    private var paneDividers: [CGRect] {
        guard showsHeaders, let root = renderLayout?.root else { return [] }
        return PaneLayoutMath.dividers(
            root: root, cellSize: cellSize, headerHeight: headerHeight, thickness: dividerThickness
        )
    }

    var body: some View {
        GeometryReader { geo in
            let frames = paneFrames
            let layoutBounds = paneLayoutBounds(frames)

            ZStack(alignment: .topLeading) {
                backgroundColor

                // Hairline dividers in the 1-cell gutters between split panes.
                // Drawn under the panes/headers (they only fill gutter gaps, so
                // they never underlap a surface) and under the focus ring.
                ForEach(paneDividers, id: \.self) { line in
                    Rectangle()
                        .fill(chrome.border)
                        .frame(width: line.width, height: line.height)
                        .offset(x: line.minX, y: line.minY)
                        .allowsHitTesting(false)
                }

                // Each pane emits up to three top-leading-anchored siblings,
                // positioned by `.offset` (render-only, so it doesn't disturb
                // the layout the way an explicit position would): the surface,
                // its header strip above it, and the focus ring around both.
                ForEach(frames) { frame in
                    let isFocused = (frame.paneId == window.activePaneId)

                    paneSurface(paneId: frame.paneId, isFocused: isFocused)
                        .frame(width: frame.surfaceFrame.width, height: frame.surfaceFrame.height)
                        .offset(x: frame.surfaceFrame.minX, y: frame.surfaceFrame.minY)

                    if frame.headerFrame.height > 0 {
                        PaneHeaderView(
                            title: paneTitle(frame.paneId),
                            isFocused: isFocused,
                            height: frame.headerFrame.height,
                            chrome: chrome,
                            onClose: {
                                onUserActivity?()
                                tmux.killPane(frame.paneId)
                            }
                        )
                        .frame(width: frame.headerFrame.width, height: frame.headerFrame.height)
                        .offset(x: frame.headerFrame.minX, y: frame.headerFrame.minY)
                    }

                    if isFocused, frames.count > 1 {
                        PaneGridFocusRing(
                            frame: frame,
                            layoutBounds: layoutBounds,
                            containerSize: geo.size,
                            color: chrome.accent.opacity(0.9)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                installPaneRefreshHook()
                pushGridSize(geo.size)
            }
            .onChange(of: geo.size) { _, newSize in pushGridSize(newSize) }
            .onChange(of: reservedHeaderRows) { _, _ in
                if let size = lastGridSize { pushGridSize(size) }
            }
            .onChange(of: pruneKey) { _, _ in pruneRuntimes() }
            .onChange(of: window.activePaneId) { _, activeId in
                if let activeId, let runtime = store.existingRuntime(for: activeId) {
                    onFocusedBoxChanged(runtime.box)
                }
            }
        }
    }

    // MARK: - Pane surface

    @ViewBuilder
    private func paneSurface(paneId: PaneId, isFocused: Bool) -> some View {
        let runtime = store.runtime(for: paneId)

        ZStack {
            TerminalSurfaceBound(
                initialData: [],
                onMade: { view in runtime.box.attach(view) },
                onReady: {
                    runtime.box.markRenderReady()
                    // Register this pane's sink and rebuild it from capture.
                    // The sink intentionally does NOT feed the SwipePad shell-
                    // integration tracker: in grid mode (always -CC) the magic-
                    // puck resolves the focused process via a pane-scoped tmux
                    // `display-message` query, never shellIntegration's OSC
                    // markers, so feeding it per-pane output would be dead work
                    // (and feeding ALL panes would interleave its parsing). It
                    // is fed only on the shared single-pane / passthrough path.
                    tmux.setPaneSink(paneId) { [box = runtime.box] slice in
                        box.feed(slice)
                    }
                    tmux.refreshPane(paneId: paneId, deep: isFocused)
                    if isFocused { onFocusedBoxChanged(runtime.box) }
                },
                onSend: { bytes in
                    onUserActivity?()
                    tmux.sendInput(Array(bytes), toPane: paneId)
                },
                onResize: { _, _ in
                    // Grid mode is size-authoritative via pushGridSize; per-pane
                    // SwiftTerm sizeChanged callbacks are inert here.
                },
                onTitle: { _ in },
                onUserActivity: onUserActivity,
                onBell: { [paneId] in onPaneBell(paneTitle(paneId)) },
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                tmuxShortcutsEnabled: tmuxShortcutsEnabled,
                onTmuxShortcut: onTmuxShortcut,
                onFindShortcut: onFindShortcut,
                onSwitcherShortcut: onSwitcherShortcut,
                onOpenSettings: onOpenSettings,
                // Structural single-claimant: only the focused pane reclaims
                // first responder (and not while the find bar holds it).
                suppressFirstResponderReclaim: !isFocused || suppressFindReclaim,
                onHardwareKey: nil,
                // Bare ⌘[/⌘] cycle panes only while a grid is mounted.
                paneCycleEnabled: true
            )

            // Tap-to-focus on an unfocused pane: select-pane only, no click
            // forwarding into the in-pane TUI (iTerm2 behavior).
            if !isFocused {
                SwiftUI.Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onUserActivity?()
                        tmux.selectPane(paneId)
                    }
            }
        }
        // Deep-on-first-focus: a pane mounted as a background sibling gets a
        // shallow refresh; when it becomes the active pane, pull its full
        // scrollback so scroll/find never hit an empty buffer.
        .onChange(of: window.activePaneId) { _, activeId in
            if activeId == paneId {
                tmux.refreshPane(paneId: paneId, deep: true)
            }
        }
        .onDisappear {
            // Snapshot kitty/2004 before the surface is torn down (window swap,
            // zoom collapse) so it restores on the next swap-in repaint.
            if let terminal = runtime.box.view?.getTerminal() {
                kittyPaneModes.snapshot(paneId, from: terminal)
            }
            tmux.setPaneSink(paneId, nil)
        }
    }

    // MARK: - Titles

    /// The label shown in a pane's header. Mirrors the tab's `displayName`
    /// policy, per pane: prefer an app-SET (non-default) `pane_title` — tmux's
    /// `pane_title` defaults to the hostname, which is useless as a label — and
    /// otherwise fall back to the pane's foreground command (`pane_current_command`,
    /// the per-pane analog of the window name that the tab shows: "htop", "vim",
    /// "zsh"). Window name / pane id are last-ditch fallbacks.
    private func paneTitle(_ paneId: PaneId) -> String {
        let pane = window.panes.first(where: { $0.id == paneId })
        if let pane, !pane.titleIsDefault,
           let title = nonEmpty(pane.title) {
            return title
        }
        if let command = nonEmpty(pane?.currentCommand) {
            return command
        }
        if let name = nonEmpty(window.windowName) {
            return name
        }
        return paneId.description
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - paneDidRefresh hook

    /// On every per-pane capture-repaint: restore that pane's kitty/2004 modes
    /// and, if it's the focused pane, re-run any open find against it.
    ///
    /// Installed on appear and deliberately NOT cleared on disappear: a window
    /// switch recreates this view via `.id(window.id)`, and onAppear(new) /
    /// onDisappear(old) ordering is unspecified — clearing on disappear could
    /// nil out the hook the incoming grid just installed. The incoming grid's
    /// onAppear overwrites it instead. `tmux` is captured weakly so the hook
    /// (stored on `tmux`) doesn't retain it; the single-pane path never fires
    /// `refreshPane`, so a stale hook is inert until the next grid overwrites it.
    private func installPaneRefreshHook() {
        tmux.paneDidRefresh = { [weak tmux, store, kittyPaneModes, onFocusedPaneRefreshed] paneId in
            guard let tmux else { return }
            // Gate the ENTIRE hook on this grid owning a runtime for the pane.
            // The closure captures THIS grid's `store`, which can only reach
            // this grid's boxes — so a stale hook (fired in the unspecified
            // gap between an outgoing grid's onDisappear and the incoming
            // grid's onAppear-overwrite, or under pane-id reuse) can never
            // touch another window's panes; it simply no-ops here. This also
            // keeps the find re-search scoped to a pane this grid renders.
            guard let runtime = store.existingRuntime(for: paneId) else { return }
            kittyPaneModes.restore(paneId, into: runtime.box)
            if paneId == tmux.activePaneId {
                onFocusedPaneRefreshed()
            }
        }
    }

    // MARK: - Runtime lifecycle

    /// A value that changes whenever the FULL pane set changes, so we can prune
    /// runtimes for panes that no longer exist (killed).
    private var pruneKey: String {
        (window.layout?.paneIds ?? []).map(\.description).joined(separator: ",")
    }

    private func pruneRuntimes() {
        store.prune(
            keeping: Set(window.layout?.paneIds ?? []),
            controller: tmux,
            kitty: kittyPaneModes
        )
    }

    // MARK: - Size authority

    private func pushGridSize(_ size: CGSize) {
        guard cellSize.width > 0, cellSize.height > 0 else { return }
        // Ignore SwiftUI's pre-layout zero/sub-cell passes — pushing 1×1 would
        // make tmux reflow every pane to a single cell and the refreshPane
        // captures would paint that tiny layout until a real size arrives.
        guard size.width >= cellSize.width, size.height >= cellSize.height else { return }
        lastGridSize = size
        let cols = max(1, Int(size.width / cellSize.width))
        // Reserve rows for the deepest header stack so per-pane surfaces stay
        // exact cell multiples (parity) and the grid still fits the bounds.
        let rows = max(1, Int(size.height / cellSize.height) - reservedHeaderRows)
        if let last = lastPushedSize, last.cols == cols, last.rows == rows { return }
        lastPushedSize = (cols, rows)
        tmux.updateClientSize(cols: cols, rows: rows)
    }
}

/// Small transient toast for a failed pane operation (e.g. tmux refusing a
/// split because a pane would be too small).
struct PaneCommandToast: View {
    let message: String
    let T: DesignTokens

    var body: some View {
        Text(message)
            .font(.system(.footnote, design: .monospaced, weight: .medium))
            .foregroundStyle(T.fg)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(T.panelBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(T.amber.opacity(0.55), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)
    }
}
