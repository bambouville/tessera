// Tessera/Terminal/TerminalBackdropView.swift
// The picture layer under a terminal canvas: theme-bg base, the user's
// picture (fill = aspect-fill crop, fit = letterboxed), and a theme-bg
// scrim at the configured dim. Always opaque, so it can also back the mosh
// pane-scrollback overlay (stacked over live content) without bleed-through.
//
// Mounted at the session root behind both chrome and terminal content;
// terminal views over it render their default background transparent
// (SessionView.applyAppearance) while cells with explicit ANSI backgrounds
// still paint opaque — the iTerm2 model.
import SwiftUI

extension EnvironmentValues {
    /// The global rect one background picture spans when several surfaces
    /// show it side by side: Duo's panes, the strip between them and the
    /// rail. Each backdrop under it paints its aligned crop of that one
    /// image, clipped to its own bleed-extended bounds, rather than fitting
    /// the whole picture to itself. Nil keeps every backdrop self-contained.
    @Entry var terminalBackdropCanvas: CGRect? = nil
}

struct TerminalBackdrop: View {
    let background: ResolvedTerminalBackground
    /// The theme background color — letterbox fill and scrim tint, so
    /// dim → 1 converges on the plain theme canvas.
    let baseColor: Color
    /// Extends only the painted backdrop beyond the local view bounds. The
    /// mosh scrollback overlay uses this to reconstruct the full-session image
    /// crop from inside the inset terminal region without changing pane frames.
    let bleed: EdgeInsets
    @Environment(\.terminalBackdropCanvas) private var canvas

    init(
        background: ResolvedTerminalBackground,
        baseColor: Color,
        bleed: EdgeInsets = EdgeInsets()
    ) {
        self.background = background
        self.baseColor = baseColor
        self.bleed = bleed
    }

    static func contentFrame(in size: CGSize, bleed: EdgeInsets) -> CGRect {
        let top = max(bleed.top, 0)
        let leading = max(bleed.leading, 0)
        let bottom = max(bleed.bottom, 0)
        let trailing = max(bleed.trailing, 0)
        return CGRect(
            x: -leading,
            y: -top,
            width: size.width + leading + trailing,
            height: size.height + top + bottom
        )
    }

    /// The shared canvas in a backdrop's local space, given its global frame.
    static func canvasFrame(_ canvas: CGRect, from frame: CGRect) -> CGRect {
        canvas.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = Self.contentFrame(
                in: geo.size,
                bleed: bleed
            )
            let contentFrame = canvas.map {
                Self.canvasFrame($0, from: geo.frame(in: .global))
            } ?? bounds
            ZStack {
                baseColor
                if let image = TerminalBackgroundImageStore.image(
                    id: background.imageID,
                    blur: background.blur
                ) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(
                            contentMode: background.fillMode == .fill ? .fill : .fit
                        )
                        .frame(width: contentFrame.width, height: contentFrame.height)
                        .clipped()
                }
                baseColor.opacity(background.dim)
            }
            .frame(width: contentFrame.width, height: contentFrame.height)
            .offset(x: contentFrame.minX, y: contentFrame.minY)
            // A no-op without a canvas, where the content is these bounds.
            // With one it keeps the canvas-sized image off neighbouring panes.
            .clipShape(FixedRectShape(rect: bounds))
        }
        .allowsHitTesting(false)
    }
}

/// Clips to a fixed rect in the parent's coordinate space regardless of the
/// proposed bounds — used by the mosh pane-scrollback overlay to show the
/// exact crop of the canvas-spanning backdrop that its pane covers, so the
/// picture doesn't shift when the overlay fades in.
struct FixedRectShape: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}

/// Multi-rect analog of `FixedRectShape` — one canvas-spanning backdrop pass
/// clipped to several fixed rects at once. The mosh pane chrome uses it to
/// mask tmux's native title rows and border gutters with the aligned picture
/// crop instead of opaque theme color.
struct FixedRectsShape: Shape {
    let rects: [CGRect]
    func path(in _: CGRect) -> Path {
        var path = Path()
        for rect in rects { path.addRect(rect) }
        return path
    }
}
