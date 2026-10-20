import Foundation

/// How a compact device must lay out and transform one tmux window so the
/// focused pane fills the physical viewport.
public struct TmuxCanvasProjection: Equatable, Sendable {
    /// Size the terminal content is laid out at, in points. This is the whole
    /// window, not the focused pane: a split window must keep rendering every
    /// pane, or the transports that paint the window natively (mosh) would be
    /// asked to wrap their output into a pane-sized grid.
    public let contentWidth: Double
    public let contentHeight: Double
    /// Uniform scale, applied with a top-leading anchor.
    public let scale: Double
    /// Translation applied after scaling, in points. Centres the focused pane
    /// in the viewport and pans the rest of the window off-screen.
    public let offsetX: Double
    public let offsetY: Double

    public init(
        contentWidth: Double,
        contentHeight: Double,
        scale: Double,
        offsetX: Double,
        offsetY: Double
    ) {
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

/// Presentation-only geometry for a compact tmux canvas, shared by every
/// platform's renderer.
///
/// tmux keeps owning the window's cell grid; this only decides how that grid
/// is framed on a small screen. Pairing it with `TmuxCompactClientSizing` —
/// which grows the *advertised* client by the focused pane's share of the
/// split — makes the focused pane land at roughly the device's own grid, so
/// the scale stays near 1 and text keeps its configured size.
public enum TmuxCompactCanvas {
    /// Nil when any input is degenerate; the caller then renders the terminal
    /// at its natural size with no transform.
    public static func projection(
        window: CellRect,
        focus: CellRect,
        cellWidth: Double,
        cellHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> TmuxCanvasProjection? {
        guard window.width > 0, window.height > 0,
              focus.width > 0, focus.height > 0,
              cellWidth > 0, cellHeight > 0,
              viewportWidth > 0, viewportHeight > 0
        else { return nil }

        let fullWidth = Double(window.width) * cellWidth
        let fullHeight = Double(window.height) * cellHeight
        let focusWidth = Double(focus.width) * cellWidth
        let focusHeight = Double(focus.height) * cellHeight
        let scale = min(viewportWidth / focusWidth, viewportHeight / focusHeight)
        let focusOriginX = Double(focus.x - window.x) * cellWidth
        let focusOriginY = Double(focus.y - window.y) * cellHeight

        return TmuxCanvasProjection(
            contentWidth: fullWidth,
            contentHeight: fullHeight,
            scale: scale,
            offsetX: (viewportWidth - focusWidth * scale) / 2 - focusOriginX * scale,
            offsetY: (viewportHeight - focusHeight * scale) / 2 - focusOriginY * scale
        )
    }
}
