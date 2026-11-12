import Foundation

enum DuoPaneArrangement: Equatable, Sendable {
    case single, sideBySide, stacked
}

struct DuoPaneRequest: Equatable {
    var container: CGSize
    var fold: DuoFold?
    var contextHidden: Bool
    var fullScreen: Bool
    var swapped: Bool
    var mainTakesInput: Bool
    var mainIdealWidth: CGFloat
    /// The main is a session whose folded deck leaves a desk below the
    /// hinge, and `desk` is the part of it free (held while typing).
    var mainHasDesk = false
    var desk: CGRect?
    /// The open display's context in the approved design: 867 − 524.
    var minimumContextWidth: CGFloat = 343
    var minimumMainWidth: CGFloat = 400
}

struct DuoPaneLayout: Equatable {
    var arrangement: DuoPaneArrangement
    var mainSlot: CGRect
    var contextSlot: CGRect?
}

enum DuoPaneGeometry {
    static func layout(_ request: DuoPaneRequest) -> DuoPaneLayout {
        let size = CGSize(width: max(0, request.container.width), height: max(0, request.container.height))
        let whole = CGRect(origin: .zero, size: size)
        var result = DuoPaneLayout(arrangement: .single, mainSlot: whole, contextSlot: nil)

        if let fold = request.fold, fold.splitsSideBySide,
           fold.frame.minX >= minimumFoldSide, size.width - fold.frame.maxX >= minimumFoldSide {
            let leading = min(size.width, max(0, fold.frame.minX))
            let trailing = min(size.width, max(leading, fold.frame.maxX))
            result = DuoPaneLayout(
                arrangement: .sideBySide,
                mainSlot: CGRect(x: 0, y: 0, width: leading, height: size.height),
                contextSlot: CGRect(x: trailing, y: 0, width: size.width - trailing, height: size.height)
            )
        } else if let split = deckSplit(container: size, fold: request.fold) {
            // The keyboard shortens the container while the user types, but
            // the desk holds still: what lies there waits under the keyboard
            // where it was instead of collapsing and jumping on every toggle.
            let reach = CGSize(width: size.width, height: max(size.height, request.desk?.maxY ?? 0))
            let below = deckSplit(container: reach, fold: request.fold)?.deck ?? split.deck
            if !request.mainTakesInput {
                // A session traded onto the desk keeps the whole desk half.
                result = DuoPaneLayout(
                    arrangement: .stacked, mainSlot: split.content,
                    contextSlot: request.mainHasDesk ? below : split.deck
                )
            } else if request.mainHasDesk {
                // The session keeps the whole screen and lays out its own
                // deck; the context takes the desk it leaves.
                let desk = request.desk.map { $0.intersection(below) }.flatMap { $0.isEmpty ? nil : $0 }
                result = DuoPaneLayout(arrangement: .stacked, mainSlot: whole, contextSlot: desk)
            }
        } else if size.width >= request.minimumMainWidth + request.minimumContextWidth {
            // Main gets its 80 columns when they fit beside the context;
            // at larger fonts it gets what the context leaves.
            let mainWidth = min(max(0, request.mainIdealWidth), size.width - request.minimumContextWidth)
            result = DuoPaneLayout(
                arrangement: .sideBySide,
                mainSlot: CGRect(x: 0, y: 0, width: mainWidth, height: size.height),
                contextSlot: CGRect(x: mainWidth, y: 0, width: size.width - mainWidth, height: size.height)
            )
        }

        // Keep the natural arrangement so the book restores a hidden pane.
        if request.contextHidden || request.fullScreen {
            result.mainSlot = whole
            result.contextSlot = nil
        }
        return result
    }

    /// A side-by-side fold divides a container only with room for a pane on
    /// each side. As the Duo closes or turns between book and laptop, the
    /// division last reported can belong to the other display or orientation
    /// for a moment: measured, the book's hinge at x 455.5 in the closing
    /// outer display's 594 pt, leaving 98.5 pt. A pane in that sliver still
    /// counts as on screen, and a terminal there resizes the remote to a
    /// dozen columns. The book's own panes are 371.5 pt or more.
    static let minimumFoldSide: CGFloat = 200

    /// A hinge runs from edge to edge, so a fold that does not span the
    /// container's width (the laptop's 669 pt in the book's 951) is not this
    /// container's.
    static func deckSplit(container: CGSize, fold: DuoFold?) -> (content: CGRect, deck: CGRect)? {
        guard let fold, !fold.splitsSideBySide,
              fold.frame.minX <= 0.5, fold.frame.maxX >= container.width - 0.5 else { return nil }
        let width = max(0, container.width)
        let height = max(0, container.height)
        let top = min(height, max(0, fold.frame.minY))
        let bottom = min(height, max(top, fold.frame.maxY))
        return (
            CGRect(x: 0, y: 0, width: width, height: top),
            CGRect(x: 0, y: bottom, width: width, height: height - bottom)
        )
    }

    static func mainIdealWidth(columns: Int, cellWidth: CGFloat, horizontalPadding: CGFloat) -> CGFloat {
        CGFloat(max(0, columns)) * max(0, cellWidth) + max(0, horizontalPadding)
    }
}
