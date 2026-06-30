import SwiftUI

/// State + dispatch glue for the §3.2 / §R4.6 find-in-scrollback feature.
///
/// The controller owns nothing transport-specific — it just tracks the
/// open/closed state, the live query, the three search options, and a
/// few callback closures the session view installs at attach time. The
/// actual search work runs against SwiftTerm via those closures so this
/// class stays SwiftTerm-free (and trivially unit-testable).
///
/// Lifecycle: one `FindController` per `SessionView` / `MoshSessionView`
/// instance. The bar is hidden until `open()` flips `isOpen` true; the
/// input gets first-responder focus via `@FocusState` in `FindBar`.
/// Closing clears the SwiftTerm selection so leftover match
/// highlighting doesn't bleed back into normal scrollback browsing.
@Observable
@MainActor
final class FindController {

    /// Bound dispatch closures the session view installs in its `.task`.
    /// `findNext` / `findPrevious` return `true` if a match was reached;
    /// `scanCount` returns the total number of matches in the buffer
    /// for the live "N of M" display. Closures are `@MainActor` because
    /// they reach into the live `TerminalView` (UIKit).
    struct Handlers {
        var findNext: @MainActor (_ query: String, _ options: TesseraSearchOptions) -> Bool
        var findPrevious: @MainActor (_ query: String, _ options: TesseraSearchOptions) -> Bool
        var clear: @MainActor () -> Void
        var scanCount: @MainActor (_ query: String, _ options: TesseraSearchOptions) -> Int
    }

    var isOpen: Bool = false
    var query: String = ""
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
    var regex: Bool = false

    /// Total matches found for the live `query`/options. Refreshed
    /// every time the user changes the query, toggles an option, or
    /// reopens the bar. Used by the bar's "N of M" counter and to
    /// decide whether to render the "no matches" hint.
    var matchCount: Int = 0

    /// 1-based index of the currently-highlighted match. 0 when there
    /// are no matches or before the first scan completes. Wraps via
    /// modulo on next/previous (matches SwiftTerm's wrap-around find
    /// semantics).
    var currentMatchIndex: Int = 0

    /// Bumps every time the bar should grab focus (each `open()` call,
    /// every ⌘F press). The view binds an `.onChange(of:)` to this so
    /// re-pressing ⌘F while the bar is already open re-focuses the
    /// input — `isOpen` alone wouldn't fire a change event in that
    /// case.
    var focusRequestToken: Int = 0

    /// Installed by the session view once the SwiftTerm view is ready.
    /// Calls before the closures are set are silent no-ops so the
    /// keyboard shortcut can fire on a freshly-opened session without
    /// crashing if the user hits ⌘G before any text exists.
    var handlers: Handlers?

    var options: TesseraSearchOptions {
        TesseraSearchOptions(
            caseSensitive: caseSensitive,
            wholeWord: wholeWord,
            regex: regex
        )
    }

    func open() {
        isOpen = true
        focusRequestToken &+= 1
    }

    /// Close the bar and clear SwiftTerm's selection so the previously
    /// highlighted match doesn't linger when the user goes back to
    /// browsing scrollback.
    func close() {
        isOpen = false
        matchCount = 0
        currentMatchIndex = 0
        handlers?.clear()
    }

    func next() {
        guard !query.isEmpty, let handlers, matchCount > 0 else { return }
        let found = handlers.findNext(query, options)
        if found {
            currentMatchIndex = (currentMatchIndex % matchCount) + 1
        }
    }

    func previous() {
        guard !query.isEmpty, let handlers, matchCount > 0 else { return }
        let found = handlers.findPrevious(query, options)
        if found {
            // 1-based modular decrement: 1 → matchCount, 2 → 1, …
            currentMatchIndex = ((currentMatchIndex - 2 + matchCount) % matchCount) + 1
        }
    }

    /// Re-run search and re-count when the user types into the input
    /// or toggles an option. Both happen in one place so the counter
    /// (`matchCount`) and SwiftTerm's selection always agree.
    func updateSearch() {
        guard let handlers else { return }
        if query.isEmpty {
            handlers.clear()
            matchCount = 0
            currentMatchIndex = 0
            return
        }
        let count = handlers.scanCount(query, options)
        matchCount = count
        if count == 0 {
            handlers.clear()
            currentMatchIndex = 0
            return
        }
        // SwiftTerm's `findNext` from a no-selection state lands on
        // the first match in scrollback order, so calling it once
        // after the scan synchronizes both the visible highlight and
        // our own index. Selection set by `scanCount` is left in
        // place; we just nudge to the first hit explicitly.
        let found = handlers.findNext(query, options)
        currentMatchIndex = found ? 1 : 0
    }
}

/// Tessera-flavored mirror of `SwiftTerm.SearchOptions`. Decoupled
/// from SwiftTerm so the controller stays free of that import.
struct TesseraSearchOptions: Equatable, Sendable {
    var caseSensitive: Bool
    var wholeWord: Bool
    var regex: Bool
}
