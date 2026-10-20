import UIKit
import SwiftTerm
import TmuxControl

enum TerminalCellMetrics {
    static func cellSize(font: UIFont, scale: CGFloat) -> CGSize {
        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let cellH = ceil(ascent + descent + leading)
        let cellW = "W".size(withAttributes: [.font: font]).width
        let safeScale = scale > 0 ? scale : 1
        let w = ceil(cellW * safeScale) / safeScale
        let h = ceil(cellH * safeScale) / safeScale
        return CGSize(width: max(1, w), height: max(1, h))
    }

    static func cellSize(for view: TerminalView) -> CGSize {
        cellSize(font: view.font, scale: view.contentScaleFactor)
    }

    // Half a cell of width keeps SwiftTerm's truncation stable after pixel
    // snapping; clip top-leading to the grid. Heights are integral points and
    // stay exact to preserve SwiftTerm's scrollback bottom anchoring.
    static func surfaceSize(for gridSize: CGSize, cellSize: CGSize) -> CGSize {
        CGSize(
            width: gridSize.width + cellSize.width / 2,
            height: gridSize.height
        )
    }
}

/// Maps the phone's visible terminal cells onto the tmux client canvas.
///
/// A compact client paints only the focused pane. For a split window, the
/// client canvas therefore has to grow so that pane gets the same cell grid as
/// an unsplit phone terminal: roughly two phone widths for a side-by-side
/// split, two phone heights for a stacked one. The size is solved against
/// tmux's own window resize of the layout tree (`TmuxCompactClientSizing`), so
/// one advertisement lands the pane on the phone grid and the layout it
/// produces projects to the same size. A later iPad client can still replace
/// this canvas with its own larger physical size through the normal
/// refresh-client path.
enum CompactTmuxClientSizing {
    static func viewportCells(
        for viewport: CGSize,
        cellSize: CGSize
    ) -> (cols: Int, rows: Int)? {
        guard cellSize.width > 0,
              cellSize.height > 0,
              viewport.width >= cellSize.width,
              viewport.height >= cellSize.height
        else { return nil }

        return (
            cols: max(1, Int(viewport.width / cellSize.width)),
            rows: max(1, Int(viewport.height / cellSize.height))
        )
    }

    /// `layout` and `focusPaneId` select the solver; without them the
    /// rectangles are scaled by ratio.
    static func clientSize(
        for viewport: (cols: Int, rows: Int),
        layout: WindowLayout?,
        focusPaneId: PaneId?,
        windowRect: CellRect?,
        focusRect: CellRect?
    ) -> (cols: Int, rows: Int) {
        let size = TmuxCompactClientSizing.clientSize(
            viewport: (viewport.cols, viewport.rows),
            layout: layout,
            focusPaneId: focusPaneId,
            windowRect: windowRect,
            focusRect: focusRect
        )
        return (size.columns, size.rows)
    }

    /// Whether a layout-only update may resize this compact client again.
    ///
    /// tmux broadcasts `%layout-change` to every control client. Once a larger
    /// iPad publishes its grid, the still-connected phone must not interpret
    /// that peer geometry as a local split edit and reclaim sizing authority.
    /// A phone may reproject while its last advertised canvas still owns the
    /// layout (allowing split/collapse/divider changes), or once during initial
    /// hydration when only its unprojected physical viewport is cached. `memo`
    /// is the session's correction count, which stops a resize cycle if tmux
    /// ever distributes cells differently from the shared model; a stop is
    /// reported to the session transport's own diagnostics category.
    static func shouldReprojectLayout(
        viewport: (cols: Int, rows: Int),
        lastClientSize: (cols: Int, rows: Int)?,
        layout: WindowLayout?,
        focusPaneId: PaneId?,
        windowRect: CellRect?,
        focusRect: CellRect?,
        memo: inout TmuxCompactReprojectionMemo,
        diagnostics: DiagnosticLogCategory
    ) -> Bool {
        let before = memo
        let decision = TmuxCompactClientSizing.reprojection(
            viewport: (viewport.cols, viewport.rows),
            lastClientSize: lastClientSize.map { ($0.cols, $0.rows) },
            layout: layout,
            focusPaneId: focusPaneId,
            windowRect: windowRect,
            focusRect: focusRect,
            memo: &memo
        )
        // Reported once per stopped cycle, on the judgement that stopped it,
        // never per layout update.
        if decision == .holdCycle, !before.isHoldingCycle {
            DiagnosticLogStore.append(
                diagnostics,
                "tmux-compact-resize-cycle-held viewport=\(viewport.cols)x\(viewport.rows) "
                    + "last=\(lastClientSize.map { "\($0.cols)x\($0.rows)" } ?? "nil") "
                    + "window=\(windowRect.map { "\($0.width)x\($0.height)" } ?? "nil") "
                    + "focus=\(focusRect.map { "\($0.width)x\($0.height)" } ?? "nil")"
            )
        }
        return decision == .reproject
    }

    /// Whether a measured frame advertises its projection. A new cell grid
    /// (rotation, the keyboard, a font change) is this device's own resize
    /// and always does. A frame that keeps the grid (a sub-cell resize, an
    /// animation step) is no new viewport: advertising from it would re-push
    /// the projection of whatever layout is current, a peer's grid or a held
    /// cycle included, so it is judged as a layout update instead.
    static func shouldAdvertiseMeasuredViewport(
        _ viewport: (cols: Int, rows: Int),
        previousViewport: (cols: Int, rows: Int)?,
        lastClientSize: (cols: Int, rows: Int)?,
        layout: WindowLayout?,
        focusPaneId: PaneId?,
        windowRect: CellRect?,
        focusRect: CellRect?,
        memo: inout TmuxCompactReprojectionMemo,
        diagnostics: DiagnosticLogCategory
    ) -> Bool {
        guard let previousViewport,
              previousViewport.cols == viewport.cols,
              previousViewport.rows == viewport.rows
        else { return true }
        return shouldReprojectLayout(
            viewport: viewport,
            lastClientSize: lastClientSize,
            layout: layout,
            focusPaneId: focusPaneId,
            windowRect: windowRect,
            focusRect: focusRect,
            memo: &memo,
            diagnostics: diagnostics
        )
    }
}
