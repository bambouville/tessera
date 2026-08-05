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
}

/// Maps the phone's visible terminal cells onto the tmux client canvas.
///
/// A compact client paints only the focused pane. For a split window, the
/// client canvas therefore has to grow by that pane's share of the saved tmux
/// layout: a 50/50 side-by-side split advertises two phone widths, while a
/// stacked split advertises two phone heights. tmux keeps the layout tree and
/// divider ratios intact, but gives the focused pane the same cell grid as an
/// unsplit phone terminal. A later iPad client can still replace this canvas
/// with its own larger physical size through the normal refresh-client path.
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

    static func clientSize(
        for viewport: (cols: Int, rows: Int),
        windowRect: CellRect?,
        focusRect: CellRect?
    ) -> (cols: Int, rows: Int) {
        guard let windowRect,
              let focusRect,
              windowRect.width > 0,
              windowRect.height > 0,
              focusRect.width > 0,
              focusRect.height > 0
        else { return viewport }

        return (
            cols: projectedDimension(
                viewport: viewport.cols,
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

    /// Whether a layout-only update may resize this compact client again.
    ///
    /// tmux broadcasts `%layout-change` to every control client. Once a larger
    /// iPad publishes its grid, the still-connected phone must not interpret
    /// that peer geometry as a local split edit and reclaim sizing authority.
    /// A phone may reproject while its last advertised canvas still owns the
    /// layout (allowing split/collapse/divider changes), or once during initial
    /// hydration when only its unprojected physical viewport is cached.
    static func shouldReprojectLayout(
        viewport: (cols: Int, rows: Int),
        lastClientSize: (cols: Int, rows: Int)?,
        windowRect: CellRect?,
        focusRect: CellRect?
    ) -> Bool {
        let projected = clientSize(
            for: viewport,
            windowRect: windowRect,
            focusRect: focusRect
        )
        guard let lastClientSize else { return true }
        guard projected.cols != lastClientSize.cols
                || projected.rows != lastClientSize.rows
        else { return false }

        if lastClientSize.cols == viewport.cols,
           lastClientSize.rows == viewport.rows {
            return true
        }

        guard let windowRect else { return false }
        // tmux status/pane-border chrome can make the window root one or two
        // cells smaller than the advertised client while it is still ours.
        return abs(windowRect.width - lastClientSize.cols) <= 2
            && abs(windowRect.height - lastClientSize.rows) <= 2
    }

    private static func projectedDimension(
        viewport: Int,
        window: Int,
        focus: Int
    ) -> Int {
        let safeViewport = max(1, viewport)
        let numerator = safeViewport * max(1, window)
        let denominator = max(1, focus)
        return max(safeViewport, (numerator + denominator - 1) / denominator)
    }
}
