import UIKit
import SwiftTerm

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
