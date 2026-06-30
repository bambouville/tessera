import Foundation
import SwiftTerm
import UIKit

/// Bridges `FindController`'s transport-agnostic search closures to
/// SwiftTerm's `findNext` / `findPrevious` / `clearSearch` API on the
/// active `TerminalView`. Lives in the main target rather than the
/// controller so the controller stays SwiftTerm-free.
///
/// **iOS scroll workaround.** SwiftTerm's `findNext(scrollToResult: true)`
/// calls its own `scrollTo(row:)`, which on iOS ends with
/// `updateScroller()` snapping the underlying `UIScrollView`'s
/// `contentOffset.y` back to the bottom (per
/// `project_swiftterm_scroll_quirks.md` in memory). Result: the match
/// gets selected and the buffer's `yDisp` is updated, but the Metal
/// renderer still draws the bottom of the scrollback because it reads
/// `contentOffset.y` — so the user never sees the highlight.
///
/// We work around it by calling `findNext` with `scrollToResult: false`
/// and computing `contentOffset.y` ourselves from the now-current
/// selection's row. Since SwiftTerm's `selection` property is internal
/// we read the row indirectly: call SwiftTerm's reveal logic ourselves
/// by manually setting `setViewYDisp` on the terminal — except that's
/// also internal. So we do the simplest reliable thing: ask SwiftTerm
/// to do its own scroll (`scrollToResult: true`), then immediately
/// resync `contentOffset.y` to the buffer's `yDisp`. Two-step but
/// reliable across SwiftTerm versions because both halves use only
/// public API.
enum TerminalSearchAdapter {

    static func handlers(for terminalBox: TerminalBox) -> FindController.Handlers {
        FindController.Handlers(
            findNext: { [weak terminalBox] query, options in
                guard let view = terminalBox?.view else { return false }
                let found = view.findNext(
                    query,
                    options: searchOptions(from: options),
                    scrollToResult: true
                )
                if found { syncContentOffsetToBuffer(view) }
                return found
            },
            findPrevious: { [weak terminalBox] query, options in
                guard let view = terminalBox?.view else { return false }
                let found = view.findPrevious(
                    query,
                    options: searchOptions(from: options),
                    scrollToResult: true
                )
                if found { syncContentOffsetToBuffer(view) }
                return found
            },
            clear: { [weak terminalBox] in
                terminalBox?.view?.clearSearch()
            },
            scanCount: { [weak terminalBox] query, options in
                guard let view = terminalBox?.view else { return 0 }
                return countMatches(in: view, query: query, options: options)
            }
        )
    }

    private static func searchOptions(from options: TesseraSearchOptions) -> SearchOptions {
        SearchOptions(
            caseSensitive: options.caseSensitive,
            regex: options.regex,
            wholeWord: options.wholeWord
        )
    }

    /// Count all matches of `query` in the active buffer. We walk the
    /// buffer text via SwiftTerm's public `getBufferAsData(kind:)`
    /// rather than abusing repeated `findNext` calls — calling
    /// `findNext` in a loop for counting would mutate the visible
    /// selection and force a UI repaint per iteration. This way we
    /// never touch SwiftTerm's selection state until the controller
    /// itself navigates to a match.
    ///
    /// Search semantics mirror SwiftTerm's `SearchOptions`:
    ///   * default → case-insensitive substring
    ///   * `caseSensitive` → case-sensitive substring
    ///   * `regex` → `NSRegularExpression`, options reflect case
    ///   * `wholeWord` → adds `\b` boundaries around the term
    ///   * `regex` ∧ `wholeWord` → treats the term as a regex and
    ///     wraps it in `\b…\b`, matching SwiftTerm's behavior.
    private static func countMatches(
        in view: TerminalView,
        query: String,
        options: TesseraSearchOptions
    ) -> Int {
        guard !query.isEmpty else { return 0 }
        let data = view.getTerminal().getBufferAsData(kind: .active)
        guard let haystack = String(data: data, encoding: .utf8), !haystack.isEmpty else {
            return 0
        }

        if options.regex || options.wholeWord {
            let pattern: String = {
                let core = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
                return options.wholeWord ? "\\b\(core)\\b" : core
            }()
            var opts: NSRegularExpression.Options = []
            if !options.caseSensitive { opts.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else {
                return 0
            }
            let range = NSRange(haystack.startIndex..., in: haystack)
            return regex.numberOfMatches(in: haystack, options: [], range: range)
        }

        if options.caseSensitive {
            return countSubstringOccurrences(haystack, query)
        }
        // SwiftTerm's case-insensitive plain search uses
        // `String.range(of:options:)` with `.caseInsensitive`. We
        // mirror it via lowercased() comparison so accents and
        // wide-char folding match exactly without depending on locale.
        return countSubstringOccurrences(haystack.lowercased(), query.lowercased())
    }

    private static func countSubstringOccurrences(_ haystack: String, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let range = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            // Advance past the start of this match so overlapping
            // sequences (e.g. "aaa" containing "aa" twice) match the
            // same way SwiftTerm's findNext walks them — once.
            index = haystack.index(after: range.lowerBound)
        }
        return count
    }

    /// Pull `contentOffset.y` to match `terminal.buffer.yDisp` so the
    /// Metal renderer shows the row SwiftTerm just scrolled to.
    /// Cell height is recovered from `view.bounds.height / terminal.rows`
    /// — the visible viewport is exactly `rows × cellHeight` so this is
    /// the right divisor regardless of font size or top-bar inset.
    private static func syncContentOffsetToBuffer(_ view: TerminalView) {
        let terminal = view.getTerminal()
        let rows = terminal.rows
        guard rows > 0 else { return }
        let visibleHeight = view.bounds.height
        guard visibleHeight > 0 else { return }
        let cellHeight = visibleHeight / CGFloat(rows)
        let yDisp = terminal.buffer.yDisp
        let target = max(0, CGFloat(yDisp) * cellHeight)
        let maxOffset = max(0, view.contentSize.height - visibleHeight)
        view.contentOffset = CGPoint(
            x: view.contentOffset.x,
            y: min(target, maxOffset)
        )
    }
}
