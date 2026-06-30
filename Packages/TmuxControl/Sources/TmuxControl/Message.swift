import Foundation

/// A single decoded tmux control-mode message.
///
/// Covers the v1 scope from §3.2 of the requirements doc. Messages we
/// don't yet understand become `.unknown` — unknown messages are safe
/// to ignore but should be logged during development.
public enum TmuxMessage: Equatable, Sendable {

    // --- Command response framing ---

    /// `%begin <time> <number> <flags>` — start of a command response.
    case begin(time: Int, commandNumber: Int, flags: Int)

    /// `%end <time> <number> <flags>` — successful command response end.
    case end(time: Int, commandNumber: Int, flags: Int)

    /// `%error <time> <number> <flags>` — failed command response end.
    case error(time: Int, commandNumber: Int, flags: Int)

    /// One line of output between `%begin` and `%end`. The parser emits
    /// these in order so callers can reassemble captured command output.
    case commandOutputLine(String)

    // --- Async pane output ---

    /// `%output %<pane> <bytes>` — asynchronous pane output.
    /// `data` is already octal-decoded: it contains the actual raw bytes
    /// the pane emitted, NOT the escaped wire form.
    case output(paneId: PaneId, data: [UInt8])
    case extendedOutput(paneId: PaneId, ageMs: Int, data: [UInt8])

    case bell(paneID: Int)

    // --- Window lifecycle ---

    case windowAdd(windowId: WindowId)
    case windowClose(windowId: WindowId)
    case windowRenamed(windowId: WindowId, name: String)
    case windowPaneChanged(windowId: WindowId, activePaneId: PaneId)

    /// `%layout-change @w <layout> <visible_layout> <raw_flags>` — verified
    /// 4-field shape against tmux 3.6a. `visibleLayout` differs from `layout`
    /// only while a pane is zoomed (it collapses to the zoomed leaf). `rawFlags`
    /// is `window_raw_flags`, e.g. `*` (current window) or `*Z` (zoomed); empty
    /// flags arrive as a trailing space and decode to `nil`. The trailing
    /// fields are optional so 2/3-token historical shapes still parse.
    case layoutChange(
        windowId: WindowId,
        layout: String,
        visibleLayout: String?,
        rawFlags: String?
    )

    case unlinkedWindowAdd(windowId: WindowId)
    case unlinkedWindowClose(windowId: WindowId)
    case unlinkedWindowRenamed(windowId: WindowId, name: String)

    // --- Session lifecycle ---

    case sessionChanged(sessionId: SessionId, name: String)
    case sessionRenamed(sessionId: SessionId, name: String)
    case sessionWindowChanged(sessionId: SessionId, windowId: WindowId)
    case sessionsChanged
    case clientSessionChanged(client: String, sessionId: SessionId, name: String)
    case clientDetached(client: String)
    case subscriptionChanged(
        name: String,
        sessionId: SessionId,
        windowId: WindowId,
        windowIndex: Int,
        paneId: PaneId,
        value: String
    )

    // --- Pane lifecycle ---

    case paneModeChanged(paneId: PaneId)

    // --- Flow control ---

    case pause(paneId: PaneId)
    case `continue`(paneId: PaneId)

    // --- Connection ---

    /// `%exit [reason]` — the control-mode session is ending.
    case exit(reason: String?)

    // --- Escape hatches ---

    /// A `%…` line we don't have a typed case for yet. Payload is the
    /// full raw line (including the leading `%`).
    case unknown(String)
}
