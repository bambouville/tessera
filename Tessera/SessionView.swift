import SwiftUI
import SwiftTerm
import ScrollDispatcher
import TesseraCore
import TesseraInputCore
import TmuxControl
import TmuxControlCore
import PortForwarding
import UIKit
import GameController

var integrationScrollHarnessSuppressesFirstResponder: Bool {
#if DEBUG
    ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_HARNESS"] == "1"
        && ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_KEEP_KEYBOARD"] != "1"
        && UIDevice.current.userInterfaceIdiom != .phone
#else
    false
#endif
}

/// DEBUG live-scroll harness: the mosh surface never applies a mouse mode.
/// The fixture's tmux and mosh hand a pane's mouse mode to the visible client;
/// some hosts' sessions show none, which is the state pane metadata routes
/// taps and pans around.
var integrationScrollHarnessDropsClientMouseModes: Bool {
#if DEBUG
    ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_HARNESS"] == "1"
        && ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_DROP_CLIENT_MOUSE"] == "1"
#else
    false
#endif
}

extension TmuxSnapshot {
    func windowID(atPosition position: Int) -> WindowId? {
        guard position >= 1, position <= windows.count else { return nil }
        return windows[position - 1].id
    }

    func adjacentWindowID(offset: Int) -> WindowId? {
        guard !windows.isEmpty,
              let activeWindowID,
              let activeIndex = windows.firstIndex(where: { $0.id == activeWindowID })
        else { return nil }
        let count = windows.count
        return windows[(activeIndex + offset + count) % count].id
    }
}

/// Chooses the physical mosh history destination. The side-channel ledger
/// still sees the same active pane on either device; only an iPad grid owns a
/// second terminal that can render detached pane history.
enum MoshHistorySurfacePolicy {
    static func usesDetachedOverlay(
        isPhone: Bool,
        windowRendersAsPaneGrid: Bool
    ) -> Bool {
        !isPhone && windowRendersAsPaneGrid
    }

    static func historyCoversFocusedPane(
        liveHistoryRevealed: Bool,
        overlayContentReady: Bool,
        readyOverlay: (windowID: WindowId, paneID: PaneId)?,
        windowID: WindowId?,
        focusedPaneID: PaneId?
    ) -> Bool {
        if liveHistoryRevealed { return true }
        guard overlayContentReady else { return false }
        // Without the reader's place, keep the focused pane's input blocked.
        guard let readyOverlay, let windowID, readyOverlay.windowID == windowID,
              let focusedPaneID
        else { return true }
        return readyOverlay.paneID == focusedPaneID
    }

    static func overlaySurfaceID(_ paneID: PaneId) -> SurfaceId {
        SurfaceId("overlay:\(paneID.description)")
    }

    static func inputSurfaceID(focusedPaneID: PaneId?, usesDetachedOverlay: Bool) -> SurfaceId? {
        if usesDetachedOverlay { return focusedPaneID.map(overlaySurfaceID) }
        return .live
    }

    static func declarations(
        windowID: WindowId,
        paneIDs: [PaneId],
        activePaneID: PaneId?,
        overlay: (windowID: WindowId, paneID: PaneId)?,
        usesDetachedOverlay: Bool
    ) -> [SurfaceDeclaration] {
        // Keep the painter unpinned so real window changes still bind it.
        var declarations = [SurfaceDeclaration(surfaceID: .live, presentation: .single)]
        guard usesDetachedOverlay else { return declarations }
        var overlayPaneIDs = activePaneID.map { [$0] } ?? []
        if let overlay,
           overlay.windowID == windowID,
           paneIDs.contains(overlay.paneID),
           !overlayPaneIDs.contains(overlay.paneID) {
            overlayPaneIDs.append(overlay.paneID)
        }
        declarations += overlayPaneIDs.map { paneID in
            SurfaceDeclaration(
                surfaceID: overlaySurfaceID(paneID),
                presentation: .overlay,
                windowID: windowID,
                paneID: paneID
            )
        }
        return declarations
    }
}

/// The caret's clear space inside its own terminal surface, in points.
///
/// Both distances are read in the surface's own coordinate space, so they hold
/// whatever the keyboard layout is doing to the session around it — the caret
/// and the surface always translate together.
struct TerminalCaretClearance {
    /// Surface top edge → top of the caret's row.
    let above: CGFloat
    /// Bottom of the caret's row → surface bottom edge.
    let below: CGFloat
}

/// Decides how much of a docked keyboard's overlap the terminal layer may
/// ignore, given where the caret sits inside its surface.
///
/// Pure so the rule can be tested without a keyboard, a window, or a session:
/// everything it needs is three numbers.
enum TerminalKeyboardCaretPolicy {
    /// Minimum-movement rule, the same one a text view applies to its caret.
    /// The hold only shrinks when the caret would otherwise be swallowed by the
    /// keyboard or the accessory bar, only grows when the caret would otherwise
    /// be pushed up behind the top chrome, and stays put in between so ordinary
    /// cursor motion inside the visible band moves nothing.
    ///
    /// - Parameters:
    ///   - previous: hold currently in force, or nil for a keyboard that is
    ///     only now coming up — which starts from the caret where it stands.
    ///   - clearance: the caret's clear space inside its surface.
    ///   - overlap: docked-keyboard overlap with the window.
    static func hold(
        previous: CGFloat?,
        clearance: TerminalCaretClearance,
        overlap: CGFloat
    ) -> CGFloat {
        // Hold at most the space that actually exists below the caret: holding
        // more would leave the caret under the accessory bar.
        let ceiling = max(0, clearance.below)
        // Hold at least enough that the translation cannot lift the caret past
        // the top of the terminal, where the session chrome sits. The bottom
        // constraint wins when the two disagree — a caret behind an opaque
        // keyboard is lost, a caret under the top bar is merely dimmed.
        let floor = min(ceiling, max(0, overlap - max(0, clearance.above)))
        guard let previous else { return ceiling }
        return min(max(previous, floor), ceiling)
    }
}

extension TerminalBox {
    /// Where the caret sits inside this surface right now, or nil when there is
    /// no surface to ask (not yet mounted, torn down, or zero-sized).
    ///
    /// Derived from the scroll geometry rather than SwiftTerm's caret view: the
    /// caret view is internal to the package, while `contentSize` /
    /// `contentOffset` are the same numbers the scrollback path already writes,
    /// so a scrolled-back surface reports the caret where it is actually drawn
    /// (below the fold) instead of where the live screen would put it.
    ///
    /// `mouseReportingImpliesAltScreen` is the same flag the surface hands its
    /// scroll dispatcher: true only where there is no local scrollback to
    /// offer (plain mosh before a tmux control channel supplies history).
    func caretClearance(
        cellHeight: CGFloat,
        mouseReportingImpliesAltScreen: Bool
    ) -> TerminalCaretClearance? {
        guard cellHeight > 0, let view, view.bounds.height > 0 else { return nil }
        let terminal = view.getTerminal()
        let rows = terminal.rows
        guard rows > 0 else { return nil }
        // A full-screen app paints every row and keeps what matters — status
        // line, command line, prompt box — at the BOTTOM, and it parks the
        // cursor wherever its own redraw left it. Following that cursor would
        // drag the bottom of vim, htop or Claude Code behind the keyboard, so
        // such a surface keeps the whole translation it has always had. Which
        // surfaces count is the scroll route's call — the same shared rule
        // that decides whether a swipe stays local: the alternate screen, or
        // mouse reporting standing in for it where there is no local
        // scrollback. Mouse reporting on a primary screen that still scrolls
        // locally — the mosh+tmux visible client under tmux's `mouse on` — is
        // a shell prompt like any other and follows the caret; treating it as
        // full-screen pushed that prompt off the top of the screen.
        guard !TerminalScrollRouting.isAltScreen(
            bufferIsAlternate: terminal.isCurrentBufferAlternate,
            mouseReporting: terminal.mouseMode != .off,
            mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen
        ) else {
            return nil
        }
        // SwiftTerm keeps `contentSize` at an exact multiple of the cell height:
        // scrollback plus the live screen for the normal buffer, exactly the
        // screen for the alternate one.
        let lines = max(rows, Int((view.contentSize.height / cellHeight).rounded()))
        let caretTopInContent = CGFloat(lines - rows + terminal.getCursorLocation().y) * cellHeight
        let caretTop = caretTopInContent - view.contentOffset.y
        return TerminalCaretClearance(
            above: caretTop,
            below: view.bounds.height - (caretTop + cellHeight)
        )
    }
}

/// Cell height for the live terminal font — the same metric the pane grid lays
/// panes out on, so a row measured here lands on SwiftTerm's own grid.
func terminalCaretCellHeight(fontID: String, fontSize: Double) -> CGFloat {
    TerminalCellMetrics.cellSize(
        font: TerminalFontResolver.uiFont(id: fontID, size: CGFloat(fontSize)),
        scale: UIScreen.main.scale
    ).height
}

/// Keeps SwiftTerm's grid geometry stable while the software keyboard moves.
///
/// SwiftUI normally proposes a shorter height when the keyboard appears, which
/// immediately reflows SwiftTerm and propagates a transport resize. In the
/// default mode we retain the full window-bottom height and translate the whole
/// composed session by the docked keyboard's overlap, so SSH, SSH+tmux, mosh,
/// and mosh+tmux keep one shared row count throughout the animation.
///
/// The lift is read straight off the height SwiftUI proposes rather than
/// replayed from `UIKeyboardWillChangeFrameNotification`. SwiftUI already
/// applies its keyboard safe-area change inside the system's own animation
/// transaction, so every geometry value derived from the proposal interpolates
/// on the keyboard's exact curve. Rebuilding that curve is not possible:
/// `UIResponder.keyboardAnimationCurveUserInfoKey` reports the private curve 7,
/// and `UICubicTimingParameters(animationCurve:)` answers identity control
/// points for it — replaying that yields a linear ramp that trails the keyboard
/// by ~190pt mid-transition and lands ~60ms late (measured on iOS 26).
///
/// The GeometryReader ignores the container's bottom safe area so the resting
/// proposal already reaches the window bottom; what remains of the shrink is
/// exactly the docked-keyboard overlap. Floating/undocked keyboards do not
/// inset the bottom edge and therefore do not move the session.
///
/// The session translation is deliberately NOT the terminal's translation. The
/// bar has to stay welded to the keyboard's top edge, so the session still
/// moves by the whole overlap; the terminal layer is then pushed back down by
/// the part of that translation the caret does not need (`caretHold`, published
/// as `terminalKeyboardCaretShift`). A prompt sitting near row 0 on a fresh
/// session therefore does not move at all — the keyboard covers rows that were
/// blank anyway — while a prompt at the last row still rides the full overlap
/// exactly as before.
private struct TerminalKeyboardLayoutModifier: ViewModifier {
    let resizesTerminal: Bool
    /// Where the caret sits inside the terminal surface, sampled on demand.
    /// `nil` means "no surface can answer" (a mounted pane grid, a session
    /// being torn down) and keeps the pre-caret behavior: move by the full
    /// overlap.
    let caretClearance: () -> TerminalCaretClearance?

    /// Clear space held below the caret — how much of the keyboard overlap the
    /// terminal layer is allowed to ignore. Sampled from the caret, never from
    /// the animation, so everything rendered from it still interpolates on
    /// SwiftUI's keyboard curve. `nil` means "nothing sampled for this keyboard
    /// yet"; the body then reads the caret inline so the very first lifted
    /// layout is already right, instead of depending on whether the keyboard
    /// notification beat SwiftUI's inset change to the run loop.
    @State private var caretHold: CGFloat?
    /// Docked-keyboard overlap as the keyboard notifications report it. Only
    /// the sampling math reads this; every rendered dimension still comes from
    /// the proposal.
    @State private var reportedOverlap: CGFloat = 0
    @State private var caretSampler = Timer
        .publish(every: 0.15, on: .main, in: .common)
        .autoconnect()

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let proposedSize = proxy.size
            let globalFrame = proxy.frame(in: .global)
            let retainedHeight = fullHeight(
                proposedHeight: proposedSize.height,
                globalMinY: globalFrame.minY
            )
            let lift = resizesTerminal
                ? 0
                : max(0, retainedHeight - proposedSize.height)
            let contentHeight = resizesTerminal
                ? proposedSize.height
                : retainedHeight
            let hold = caretHold ?? caretClearance()?.below ?? 0
            let caretShift = min(max(0, hold), lift)

            content
                .environment(\.softwareKeyboardLift, lift)
                .environment(\.terminalKeyboardCaretShift, caretShift)
                .frame(
                    width: proposedSize.width,
                    height: contentHeight,
                    alignment: .top
                )
                // `position` top-aligns a fixed-height child even when the
                // GeometryReader itself receives the shorter keyboard proposal.
                .position(
                    x: proposedSize.width / 2,
                    y: contentHeight / 2
                )
                .offset(y: -lift)
        }
        // Keeps the resting proposal at the window bottom (the session roots
        // deliberately ignore this inset) while still receiving `.keyboard`.
        .ignoresSafeArea(.container, edges: .bottom)
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification
            )
        ) { note in
            noteKeyboardFrame(note)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )
        ) { _ in
            reportedOverlap = 0
            caretHold = nil
        }
        .onReceive(caretSampler) { _ in
            // The caret moves under the remote's control, not the user's: a
            // prompt walks down the screen as output arrives and jumps back to
            // row 0 on `clear`. Re-reading it while the keyboard is up is what
            // keeps it in view across both.
            guard !resizesTerminal, reportedOverlap > 0 else { return }
            updateCaretHold(reset: false)
        }
    }

    /// Overlap of the *docked* keyboard with the window, as the notification
    /// reports it. Mirrors what the proposal-derived lift above measures, so
    /// the sampling math and the rendering agree on when a keyboard counts.
    private func noteKeyboardFrame(_ note: Notification) {
        guard !resizesTerminal else { return }
        guard let window = keyWindow,
              let endFrame = note.userInfo?[
                UIResponder.keyboardFrameEndUserInfoKey
              ] as? CGRect
        else { return }
        let inWindow = window.convert(endFrame, from: nil)
        // Floating / undocked keyboards do not inset the bottom edge, so they
        // move nothing and need no caret work.
        let docked = inWindow.maxY >= window.bounds.maxY - 1
        let overlap = docked
            ? max(0, window.bounds.maxY - max(inWindow.minY, 0))
            : 0
        let wasHidden = reportedOverlap <= 0
        reportedOverlap = overlap
        guard overlap > 0 else {
            caretHold = nil
            return
        }
        // A keyboard on its way up starts from wherever the caret already is:
        // hold everything below it, i.e. move the terminal the least it can.
        updateCaretHold(reset: wasHidden)
    }

    private func updateCaretHold(reset: Bool) {
        guard let clearance = caretClearance() else {
            // Nothing to ask: hold nothing, i.e. move by the full overlap,
            // which is what this layout did before it learned about carets.
            if caretHold != 0 { caretHold = 0 }
            return
        }
        let next = TerminalKeyboardCaretPolicy.hold(
            previous: reset ? nil : caretHold,
            clearance: clearance,
            overlap: reportedOverlap
        )
        guard caretHold == nil || abs(next - (caretHold ?? 0)) > 0.5 else { return }
        caretHold = next
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })
    }

    private func fullHeight(
        proposedHeight: CGFloat,
        globalMinY: CGFloat
    ) -> CGFloat {
        guard let window = keyWindow else { return proposedHeight }
        // Session roots deliberately ignore the container's bottom safe area,
        // so the window bottom is the stable lower edge in every keyboard state.
        return max(proposedHeight, window.bounds.maxY - globalMinY)
    }
}

/// Pushes the terminal layer back down by the slice of the session's keyboard
/// translation the caret does not need, and clips it to the region the chrome
/// leaves free. Without the clip the rows the translation was hiding would draw
/// straight through the accessory bar's material.
private struct TerminalKeyboardCaretShift: ViewModifier {
    @Environment(\.terminalKeyboardCaretShift) private var caretShift

    func body(content: Content) -> some View {
        content
            .offset(y: caretShift)
            // `offset` leaves the layout frame alone, so this clips to the
            // terminal's own region — the shifted-down rows land behind the
            // accessory bar instead of through it.
            .clipped()
    }
}

private struct TerminalKeyboardCaretShiftKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far the terminal layer is pushed back down inside a session that has
    /// been translated to clear the docked software keyboard. Zero whenever the
    /// caret needs the whole translation (the classic prompt-at-the-last-row
    /// case) and equal to the translation when it needs none of it.
    var terminalKeyboardCaretShift: CGFloat {
        get { self[TerminalKeyboardCaretShiftKey.self] }
        set { self[TerminalKeyboardCaretShiftKey.self] = newValue }
    }
}

extension View {
    func terminalKeyboardLayout(
        resizesTerminal: Bool,
        caretClearance: @escaping () -> TerminalCaretClearance?
    ) -> some View {
        modifier(TerminalKeyboardLayoutModifier(
            resizesTerminal: resizesTerminal,
            caretClearance: caretClearance
        ))
    }

    /// Applied to the terminal layer of a session (the surface plus whatever
    /// overlays share its canvas).
    func terminalKeyboardCaretShift() -> some View {
        modifier(TerminalKeyboardCaretShift())
    }
}

/// Keeps the session's top chrome — top bar and find bar — in the window's
/// coordinate space while `TerminalKeyboardLayoutModifier` translates the
/// composed session up behind the docked software keyboard.
///
/// The whole-session translation is deliberate *for the terminal*: it holds one
/// row count across the keyboard animation instead of reflowing SwiftTerm and
/// pushing a SIGWINCH into whatever is running remotely. Losing the top bar off
/// the top of the screen came along for the ride, and for the terminal itself
/// that was an acceptable trade — the user is looking at the rows near the
/// prompt, not at the chrome.
///
/// Find is the case the trade does not cover. `FindBar` focuses a `TextField` —
/// that focus is what raises the software keyboard in the first place — so
/// without this the user types a query, and reads a match counter, in a field
/// sitting ~336 pt above the top of the screen.
///
/// `offset` rather than a frame or padding change, for the same reason the
/// accessory bar uses one: the terminal's layout must not move, or the grid
/// reflows and the translation has bought nothing. The lift it cancels is read
/// off SwiftUI's own animated keyboard inset, so the chrome holds still through
/// the transition instead of chasing the keyboard on a rebuilt curve.
///
/// Cost, stated: with the keyboard up the chrome covers the topmost ~2 rows of
/// the visible terminal region (4 with the find bar open) rather than sliding
/// away from them. That is the same band of the screen chrome always occupies.
struct KeyboardLiftExemptChrome<Content: View>: View {
    private let content: Content
    @Environment(\.softwareKeyboardLift) private var keyboardLift

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// Its own `VStack` so the group stays one vertical strip: a bare
    /// `ViewBuilder` tuple lifted out of the enclosing stack would lay the top
    /// bar and the find bar on top of each other.
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .offset(y: keyboardLift)
    }
}

/// Reference box for diagnostics counters. Deliberately NOT observable:
/// these bump on every scroll event when diagnostics are enabled, and as
/// `@State var` they invalidated the entire session view body per event —
/// a CA commit per pointer event, which on an idle-refresh (24Hz) panel
/// blocks the main thread to the panel rate and starves event delivery,
/// display links, and MainActor ingest for the whole gesture.
private final class ScrollDiagnosticCounters {
    var sequence = 0
    var gateLogCount = 0
    /// Alt-screen proxy deltas arrive per display frame (~120Hz); a log
    /// per event would wipe the ~900-line diagnostics ring in seconds.
    var altProxyEventCount = 0
}

/// Reference holder for the inline (SSH+tmux) history ladder's platform
/// record. Scroll frames arrive per display frame; keeping the bookkeeping
/// off `@State`'s value storage means a gesture never invalidates the
/// SwiftUI body. The policy itself stays in the pure, unit-tested
/// `InlineTmuxHistoryRequestState`.
private final class InlineTmuxHistoryRequestStore {
    var state = InlineTmuxHistoryRequestState()

    /// Previous committed offset per surface, so a native (finger) scroll
    /// frame can tell "moving up" from "moving down". The custom
    /// trackpad/wheel recognizer reports its own direction instead.
    private var lastScrollOffsets: [SurfaceId: CGFloat] = [:]

    /// Grid panes mount their SwiftTerm surfaces inside `PaneGridView`, which
    /// owns their runtimes. It hands each pane's box over as it becomes a
    /// ledger surface and takes it back when the surface is undeclared. Weak
    /// so a missed retirement can never outlive the grid's own storage.
    private var paneBoxes: [PaneId: WeakTerminalBox] = [:]

    final class WeakTerminalBox {
        weak var box: TerminalBox?
        init(_ box: TerminalBox) { self.box = box }
    }

    func lastScrollOffsetY(for surfaceID: SurfaceId) -> CGFloat {
        lastScrollOffsets[surfaceID] ?? 0
    }

    func setLastScrollOffsetY(_ offsetY: CGFloat, for surfaceID: SurfaceId) {
        lastScrollOffsets[surfaceID] = offsetY
    }

    func registerPaneBox(_ box: TerminalBox, for paneID: PaneId) {
        paneBoxes[paneID] = WeakTerminalBox(box)
    }

    func paneBox(for surfaceID: SurfaceId) -> TerminalBox? {
        guard let paneID = Self.paneID(in: surfaceID) else { return nil }
        return paneBoxes[paneID]?.box
    }

    /// Forget everything recorded for one grid pane whose surface is gone.
    func retirePane(_ paneID: PaneId) {
        paneBoxes.removeValue(forKey: paneID)
        let surfaceID = Self.paneSurfaceID(paneID)
        lastScrollOffsets.removeValue(forKey: surfaceID)
        state.reset(surfaceID)
    }

    /// A topology or transport boundary (grid mount/unmount, window switch,
    /// tmux exit, disconnect): nothing credited on either side of it
    /// describes the other. The pane box registry is owned by the grid's own
    /// ready/retire callbacks and is deliberately left alone — SwiftUI does
    /// not order a parent's `onChange` against a child's `onReady`, and the
    /// references are weak, so a stale entry can neither leak nor outlive
    /// the grid that mounted it.
    func resetRecords() {
        state.reset()
        lastScrollOffsets.removeAll()
    }

    static func paneSurfaceID(_ paneID: PaneId) -> SurfaceId {
        InlineTmuxHistoryRequestState.paneSurfaceID(paneID)
    }

    static func paneID(in surfaceID: SurfaceId) -> PaneId? {
        InlineTmuxHistoryRequestState.paneID(in: surfaceID)
    }
}

/// Hosts a `TerminalSurface` bound to an `SSHSession`. The terminal view
/// is created once and retained; session output bytes are pumped into
/// it via the session's `outputStream`.
///
/// v1 layout (§3.5 R3.5.2): a `SessionTopBar` occupies the top
/// corner-inset area and is always visible — space the terminal
/// content can't use anyway because of the iPad's rounded display
/// corners. Below it, the terminal content area fills to the bottom edge
/// while keeping the horizontal inset needed for the rounded corners. When
/// tmux -CC lands (§3.2), the same top bar morphs into an iTerm2-style tab
/// strip without changing the outer layout.
struct SessionContinuityActions {
    let continueSession: () -> Void
    let setUpAndContinue: () -> Void
}

struct SessionView: View {
    @StateObject var session: SSHSession
    /// Identifier of the owning `LiveSession` so the MRU cycle can
    /// exclude "the session we're already in" when seeding its walk
    /// snapshot. Bound from the `ForEach` in `ContentView`.
    var liveSessionID: UUID
    /// Whether this session is the foreground (visible) session.
    /// Hidden sessions suppress resize propagation to avoid sending
    /// SIGWINCH to background TUIs when the sidebar toggles or the
    /// device rotates.
    var isActive: Bool
    /// Other sessions still awaiting a verdict in the same restore window.
    var reconnectingElsewhere: Int = 0
    /// The user closed this session on purpose. Distinct from
    /// `onSessionEnded`, which also fires for a transport death and a clean
    /// remote exit — the restore window must reopen those and must not reopen
    /// this.
    var onUserClosedSession: () -> Void = {}
    /// Toggles the sidebar visibility from within the session.
    var onToggleSidebar: () -> Void
    /// Whether the sidebar is currently shown — drives the top-bar
    /// toggle's accent tint so the button reflects its on/off state.
    var sidebarVisible: Bool
    /// Called when the user taps "back" — hides the session without
    /// disconnecting so it stays alive for switching back to.
    var onBack: () -> Void
    /// Called from the connection-failed overlay's "edit host" button.
    /// The parent removes this session and opens the host editor.
    var onEditHost: () -> Void
    /// Called from the connection-failed overlay's "retry" button. The
    /// parent removes this session and reconnects with the same host.
    var onRetry: () -> Void
    /// Called when the SSH session terminates (clean exit or error).
    /// The parent should remove this session from its active list.
    var onSessionEnded: () -> Void
    /// Called when the ⌃Tab MRU cycle commits to a session OR when the
    /// command palette commits. The parent translates the id into a
    /// `selectedItem = .session(id)` update.
    var onSelectSession: (UUID) -> Void
    /// Called when ⌘, fires inside the session. The parent opens the
    /// Settings page (`selectedItem = .settings`).
    var onOpenSettings: () -> Void
    /// Called when ⌘⇧A fires inside SwiftTerm.
    var onOpenAgentCenter: (() -> Void)?
    /// Cross-device actions for the focused session. The terminal bar owns
    /// their hit target so continuity never floats over another control.
    var continuityActions: SessionContinuityActions? = nil
    /// Reports auto-tmux degrading to the already-connected plain shell.
    var onEffectiveLaunchModeChanged: (HostLaunchMode) -> Void = { _ in }

    /// Terminal view reference captured via `onMade` so we can feed it
    /// from the session's output stream.
    @State private var terminalBox = TerminalBox(traceLabel: "ssh")
    @State private var renderDropSummary = RenderDropSummaryReporter()
    @State private var tmuxTerminalQueryResponder = TerminalOSCColorQueryResponder()
    @State private var kittyWindowModes = KittyWindowModeStore()
    /// Per-pane kitty/2004 modes for the multi-pane grid (analog of
    /// `kittyWindowModes` for the single-pane path). Held here so pane modes
    /// survive window switches and grid mount/unmount.
    @State private var kittyPaneModes = KittyPaneModeStore()
    @State private var modifierState = ModifierState()

    /// §3.2 tmux -CC router. In passthrough mode it's a transparent
    /// pipe between the SSH session and SwiftTerm; as soon as tmux's
    /// `ESC P 1 0 0 0 p` prologue appears in the output stream the
    /// controller swaps modes, parses control-mode messages, and
    /// wraps typed keystrokes in `send-keys` commands.
    @State private var tmux = TmuxController(
        clientSizePolicy: .resizeTmux,
        separatorProbeEnabled: true
    )
    /// Inline (SSH+tmux) history ladder bookkeeping: `canDeepen` from the last
    /// `inlineHistorySettled`, the single-flight latch, and the reader's
    /// distance from the tail when it asked. Every other part of the policy
    /// (depth, exhaustion, settling) belongs to the shared render ledger.
    @State private var inlineHistory = InlineTmuxHistoryRequestStore()
    @State private var shellIntegration = SwipePadShellIntegrationTracker()
    @State private var swipePadOutputActivityToken = 0
    @State private var swipePadOutputActivityTask: Task<Void, Never>?
    @State private var swipePadSessionIsActive = false
    @State private var agentSourceRegistrationID: UUID?
    /// Presentation state arrives through the portable SessionEvent contract.
    /// The concrete ObservableObject remains only the Apple transport adapter.
    @State private var sharedSessionState: SharedSessionState = .idle
    @State private var sharedTmuxSnapshot: TmuxSnapshot?
    @State private var sharedChallenge: SessionChallenge?
    @State private var sharedRemoteWorkingDirectory: String?
    private var presentationSessionState: SessionState {
        legacySessionState(from: sharedSessionState)
    }
    /// The takeover veil and every input gate read the controller's one
    /// Equatable presentation (S3′): it changes in the same render pass as
    /// the top-bar chip and carries no generation, so equal writes never
    /// re-render the session.
    private var gridAuthorityPresentation: TmuxController.GridAuthorityPresentation {
        tmux.gridAuthorityPresentation
    }
    private var effectiveGridAuthorityPeerName: String? {
        gridAuthorityPresentation.peerName
    }
    /// The veil is up: another device holds the grid, or a take-back is
    /// presenting over it.
    private var sessionIsControlledElsewhere: Bool {
        gridAuthorityPresentation.showsVeil
    }
    /// The veil is on screen (P9's drawing gate keys off this, not off
    /// `sessionIsControlledElsewhere`): the launch overlay and a connection
    /// that is not `.connected` outrank it.
    private var veilIsDrawn: Bool {
        ContinuedElsewherePresentationPolicy.veilIsDrawn(
            veilUp: sessionIsControlledElsewhere,
            launchOverlayShown: showsLaunchOverlay,
            connected: presentationSessionState == .connected
        )
    }
    /// Input waits for authority: veiled, reclaiming, or resuming over a
    /// live channel. A show waiting for a channel that is down still types
    /// through the transport unless a peer was the last-known holder (M7).
    /// A plain read of one stored, observed property: O(1) per keystroke.
    private var terminalInputGatedByAuthority: Bool {
        !tmux.gridAuthorityAllowsInput
    }

    /// Set to `true` once we've sent the auto-tmux shell snippet for
    /// this connect, so we don't re-send it on every state churn.
    /// Reset would only matter if the same `SessionView` instance
    /// reconnected. Inline command-channel recovery now deliberately reopens
    /// the PTY in place, so that path resets this latch before relaunching tmux.
    @State private var sentAutoTmuxCommand = false
    @State private var inlineTmuxPTYRecoveryInProgress = false

    /// Banner state for "tmux not available on this host". Set when
    /// the auto-tmux script's failure path's sentinel byte sequence
    /// shows up in the SSH output stream. Dismissable.
    @State private var noTmuxBannerVisible = false
    @State private var noTmuxBannerReason: TmuxLaunchDegradeReason = .unavailable
    @State private var noTmuxScanner = AutoTmuxSentinelScanner()
    @State private var dismissedWSLTailscaleMTUWarning = false

    /// Number of pre-control-mode output chunks already traced into the
    /// diagnostics log. Bounded so a stuck launch records the remote's
    /// first words without flooding the ring buffer.
    @State private var launchChunkTraceCount = 0

    /// Watchdog that refuses to let a tmux launch hang forever. Armed when
    /// the launch command goes out, cancelled the moment control mode
    /// engages (or the session ends).
    @State private var tmuxLaunchWatchdog: Task<Void, Never>?

    /// Second-stage watchdog for the window the first one cannot see: the
    /// DCS arrived (control mode engaged, launch watchdog disarmed) but
    /// attach hydration never reported the initial render. Observed in the
    /// field on a host whose tmux mangles capture metadata: every
    /// authoritative repaint fails and a quiet re-attached pane emits no
    /// `%output` to latch, so `tmux.isInitialRenderReady` never fires and
    /// the overlay used to sit until the stall notice. Armed on control-mode
    /// entry, cancelled by readiness or session end.
    @State private var tmuxHydrationWatchdog: Task<Void, Never>?

    /// When the launch command was written, so the trace can report how
    /// long each milestone took rather than making the reader subtract
    /// timestamps.
    @State private var autoTmuxSentAt: Date?

    /// The launch one-liner as sent. Used to recognise the host echoing it
    /// back in the output trace; never written to the log itself.
    @State private var lastAutoTmuxCommand: String?

    /// Full terminal-area loading shield shown from connect-start until
    /// the session is ready: `.connected` for `.customCommand`; first
    /// tmux pane render for `.autoTmux` / `.pinnedTmux`. Replaces the
    /// v1 tmux-only overlay (commit 6a01abc) with a unified visual.
    /// Defaults to `true` so the overlay is up immediately when the
    /// view appears; dismissed by the mode-specific signal handlers
    /// below (see `.onChange(of: presentationSessionState)` and
    /// `.onChange(of: tmux.isInitialRenderReady)`).
    @State private var launchOverlayVisible = true

    /// Last terminal size reported by the TerminalView. Cached so
    /// we can replay it when foregrounded after being hidden.
    @State private var lastTerminalSize: (cols: Int, rows: Int)?
    /// Physical phone viewport, separate from the authoritative tmux canvas.
    /// Hidden compact sessions keep this current without resizing their remote
    /// TUI; the selected session replays it when it becomes active.
    @State private var lastCompactViewportSize: (cols: Int, rows: Int)?
    /// Expanded canvas last requested for this viewport, including geometry
    /// withheld by the controller. Deduplicate requests here; reprojection
    /// uses the controller's successfully published geometry instead.
    @State private var lastCompactRequestedClientSize: (cols: Int, rows: Int)?
    /// Corrections of one compact layout that have not settled yet; the
    /// shared sizing stops a resize cycle with it.
    @State private var compactReprojectionMemo = TmuxCompactReprojectionMemo()

    /// Cached tmux session name we resolved for this host on first
    /// access. Computed lazily and held as state so the view body
    /// doesn't recompute the SHA-256 derivation on every render.
    @State private var resolvedTmuxSessionName: String?
    @State private var currentTerminalTitle: String? = nil

    /// Transient toast for a failed pane operation (e.g. "pane too small").
    @State private var paneCommandToast: String? = nil
    @State private var paneCommandToastTask: Task<Void, Never>? = nil
    @State private var agentScrollNotice = AgentScrollPreventionNoticeController()

    /// §R4.6 find-in-scrollback. The bar is hidden until the user
    /// taps the `⌕` button in the top bar or hits ⌘F. Owns search
    /// query / options state and the dispatch closures into the
    /// SwiftTerm view (installed below in `.task`).
    @State private var findController = FindController()

    /// Remote Files panel. Per-session, mirrors the find controller's
    /// scoping; the FileBridge attaches lazily on first open via the
    /// app-wide FileBridgeRegistry (never-auto-connect: nothing dials
    /// until the user opens the panel).
    @State private var filesPanel = FilesPanelController()
    /// True once OSC 7 has delivered outside tmux this session — the
    /// only state that proves the signal is live in passthrough. The
    /// terminal's `hostCurrentDirectory` alone can't prove it: that
    /// property never clears, and pane bytes riding the tmux control
    /// channel can latch a value the plain shell will never refresh.
    @State private var osc7DeliveredInPassthrough = false
    @AppStorage(DiagnosticLogStore.scrollDiagnosticsDefaultsKey)
    private var scrollDiagnosticsEnabled = false
    @State private var scrollDiagnostics = ScrollDiagnosticCounters()

    /// Live AppearancePreferences read so chrome bg + top-bar tokens follow
    /// the user's terminal theme choice — see `themeChromeTokens` below.
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AppLockController.self) private var appLockController
    @Environment(\.sessionShowCoordinator) private var showEdges
    @Environment(\.terminalInputAllowed) private var inheritedTerminalInputAllowed
    @Environment(BellController.self) private var bellController
    @Environment(TunnelsRegistry.self) private var tunnelsRegistry
    @Environment(SwipePadProfileStore.self) private var swipePadStore
    @Environment(SpeechDictationController.self) private var dictationController
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(AgentCenterV2Coordinator.self) private var agentCenterV2
    @Environment(AppPhase.self) private var appPhase
    @Environment(FileBridgeRegistry.self) private var fileBridges
    @Environment(HostTerminalBackgroundStore.self) private var hostBackgrounds
    @Environment(\.designTokens) private var appDesignTokens
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var activeTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    private var themeChromeTokens: DesignTokens {
        activeTheme.chromeTokens(applying: appearance)
    }

    /// The iPad inspector visually belongs to the terminal, but the compact
    /// presentation is a system sheet above the app shell. Matching that
    /// sheet to the app appearance keeps light mode from pairing a light
    /// presentation surface with terminal-theme white text.
    private var filesPanelTokens: DesignTokens {
        isPhone ? appDesignTokens : themeChromeTokens
    }

    /// Background picture for this session's canvas (host override → global),
    /// nil for the classic solid theme color.
    private var resolvedTerminalBackground: ResolvedTerminalBackground? {
        ResolvedTerminalBackground.resolve(
            hostID: session.host.id,
            appearance: appearance,
            hostStore: hostBackgrounds
        )
    }

    /// The tmux window tmux currently considers active, if known.
    private var activeWindow: TmuxController.WindowInfo? {
        guard let id = tmux.activeWindowId else { return nil }
        return tmux.windows.first(where: { $0.id == id })
    }

    /// Foreground command of the focused tmux pane, for program-scoped custom
    /// shortcuts. nil in passthrough: there is no cheap process source without
    /// tmux, and `ShortcutScopeEvaluator` deliberately fails closed rather than
    /// firing a scoped shortcut into an unknown shell.
    private var activePaneCurrentCommand: String? {
        guard tmux.mode != .passthrough, let paneID = tmux.activePaneId else { return nil }
        for window in tmux.windows {
            if let pane = window.panes.first(where: { $0.id == paneID }) {
                return pane.currentCommand
            }
        }
        return nil
    }

    /// Whether a user-defined shortcut applies to this session right now.
    /// Extracted from the call site so the enclosing view body stays inside
    /// the type checker's budget.
    private func shouldFire(_ shortcut: CustomShortcut) -> Bool {
        ShortcutScopeEvaluator.applies(
            shortcut.scope,
            hostID: session.host.id,
            processName: activePaneCurrentCommand
        )
    }

    /// The active window iff it must render as a multi-pane grid. `nil` keeps
    /// the shared single-pane terminal (today's fast path).
    private var activeGridWindow: TmuxController.WindowInfo? {
        guard let window = activeWindow, window.rendersAsPaneGrid else { return nil }
        return window
    }

    private var compactTmuxLayout: WindowLayout? {
        guard let window = activeWindow else { return nil }
        return window.isZoomed
            ? (window.visibleLayout ?? window.layout)
            : window.layout
    }

    private var compactTmuxWindowRect: CellRect? {
        guard isPhone, tmux.mode == .tmuxControl else { return nil }
        return compactTmuxLayout?.root.rect
            ?? activeWindow?.panes.first?.contentRect
    }

    private var compactTmuxFocusRect: CellRect? {
        guard let window = activeWindow,
              let paneID = window.activePaneId ?? tmux.activePaneId
        else { return compactTmuxWindowRect }
        return compactTmuxLayout?.leaves.first(where: { $0.paneId == paneID })?.rect
            ?? window.panes.first(where: { $0.id == paneID })?.contentRect
            ?? compactTmuxWindowRect
    }

    /// The tree the compact canvas is solved against, under the same
    /// conditions as `compactTmuxWindowRect`.
    private var compactTmuxSizingLayout: WindowLayout? {
        guard isPhone, tmux.mode == .tmuxControl else { return nil }
        return compactTmuxLayout
    }

    private var compactTmuxFocusPaneID: PaneId? {
        guard let window = activeWindow else { return nil }
        return window.activePaneId ?? tmux.activePaneId
    }

    private var compactTmuxSizingKey: String {
        TmuxCompactClientSizing.observationKey(
            mode: String(describing: tmux.mode),
            windowId: tmux.activeWindowId,
            focusPaneId: compactTmuxFocusPaneID,
            layout: compactTmuxSizingLayout,
            windowRect: compactTmuxWindowRect,
            focusRect: compactTmuxFocusRect
        )
    }

    /// A single-pane tmux window still keeps its remote grid on phone. Split
    /// windows use `PaneGridView.compactSinglePane` instead.
    private var compactSingleWindowRect: CellRect? {
        guard isPhone,
              tmux.mode == .tmuxControl,
              activeGridWindow == nil
        else { return nil }
        return compactTmuxWindowRect
    }

    /// Bottom inset for chrome that stacks above the accessory bar. Measured
    /// from the bar's reserved band, so the swipe pad clears the phone's
    /// home-indicator strip as well as the chip row.
    private var swipePadBottomInset: CGFloat {
        appearance.showAccessoryBar
            ? SessionAccessoryBar.reservedBandHeight()
            : max(Self.cornerInset - 8, 4)
    }

    private var paneToastBottomInset: CGFloat {
        appearance.showAccessoryBar
            ? SessionAccessoryBar.reservedBandHeight() + 12
            : 24
    }

    /// Character-cell size for the live terminal font, used to lay out pane
    /// frames as exact cell multiples (matches SwiftTerm's own grid snapping).
    private var terminalCellSize: CGSize {
        let size = CGFloat(appearance.fontSize)
        let font = TerminalFontResolver.uiFont(id: appearance.terminalFontID, size: size)
        return TerminalCellMetrics.cellSize(font: font, scale: UIScreen.main.scale)
    }

    private func updateCompactInlineViewport(_ size: CGSize) {
        guard isPhone,
              let viewport = CompactTmuxClientSizing.viewportCells(
                for: size,
                cellSize: terminalCellSize
              )
        else { return }
        let previousViewport = lastCompactViewportSize
        lastCompactViewportSize = viewport
        guard isActive, appPhase.isActive,
              CompactTmuxClientSizing.shouldAdvertiseMeasuredViewport(
                viewport,
                previousViewport: previousViewport,
                lastClientSize: tmux.lastPublishedClientSize.map { ($0.columns, $0.rows) },
                layout: compactTmuxSizingLayout,
                focusPaneId: compactTmuxFocusPaneID,
                windowRect: compactTmuxWindowRect,
                focusRect: compactTmuxFocusRect,
                memo: &compactReprojectionMemo,
                diagnostics: .ssh
              )
        else { return }
        pushCompactInlineViewport(viewport)
    }

    /// A layout-driven reprojection: advertises only when the shared
    /// decision allows it (the peer rules and the cycle guard).
    private func reprojectCompactInlineLayout(_ viewport: (cols: Int, rows: Int)) {
        guard CompactTmuxClientSizing.shouldReprojectLayout(
            viewport: viewport,
            lastClientSize: tmux.lastPublishedClientSize.map { ($0.columns, $0.rows) },
            layout: compactTmuxSizingLayout,
            focusPaneId: compactTmuxFocusPaneID,
            windowRect: compactTmuxWindowRect,
            focusRect: compactTmuxFocusRect,
            memo: &compactReprojectionMemo,
            diagnostics: .ssh
        ) else { return }
        pushCompactInlineViewport(viewport)
    }

    private func pushCompactInlineViewport(
        _ viewport: (cols: Int, rows: Int),
        force: Bool = false
    ) {
        let client = CompactTmuxClientSizing.clientSize(
            for: viewport,
            layout: compactTmuxSizingLayout,
            focusPaneId: compactTmuxFocusPaneID,
            windowRect: compactTmuxWindowRect,
            focusRect: compactTmuxFocusRect
        )
        // A forced replay (activation, foreground, refresh) is a fresh start:
        // a layout update cannot cause one, so it cannot feed a cycle.
        if force {
            compactReprojectionMemo = TmuxCompactReprojectionMemo()
        }
        if !force,
           let lastCompactRequestedClientSize,
           lastCompactRequestedClientSize.cols == client.cols,
           lastCompactRequestedClientSize.rows == client.rows {
            return
        }
        lastCompactRequestedClientSize = client
        session.sessionCommands(tmux: tmux).resize(columns: client.cols, rows: client.rows)
    }

    /// Repaint the visible SSH terminal and ask inline tmux for a fresh
    /// authoritative capture when -CC is active. Replaying the current size
    /// also gives plain SSH/TUI sessions the same redraw signal without
    /// tearing down the live connection.
    private func forceRefreshTerminal() {
        guard isActive, appPhase.isActive, presentationSessionState == .connected else { return }
        appLockController.notifyUserActivity()
        terminalBox.forceRedraw()

        if isPhone, let viewport = lastCompactViewportSize {
            pushCompactInlineViewport(viewport, force: true)
        } else if activeGridWindow == nil, let size = lastTerminalSize {
            // A mounted pane grid owns a smaller, header-reserved tmux size.
            // Replaying the hidden shared terminal's full height here would
            // overwrite that authority without a grid-layout change to heal it.
            session.sessionCommands(tmux: tmux).resize(columns: size.cols, rows: size.rows)
        }
        // D9: a repaint of what this device may render, never a claim. A
        // participating controller repaints only while it is not yielded
        // (no stamp, no latest fence); control moves only on a show or a
        // veil gesture. Starting a second capture here could race it.
        _ = session.sessionCommands(tmux: tmux).dispatch(.claimTmuxGridAuthority(
            reason: .forceRefresh,
            repaintEvenIfSame: true
        ))
    }

    /// Take back the shared tmux grid from the device that continued this
    /// session. The controller restamps authority and replays our size; the
    /// veil lifts only after geometry confirmation and any required repaint.
    private func takeBackContinuedSession() {
        // D8: a hidden session's veil stays mounted and a locked app keeps
        // ContentView mounted; neither may reclaim the grid.
        guard ContinuedElsewhereKeyPolicy.admitsGesture(
            sessionIsActive: isActive,
            appIsLocked: appLockController.isLocked
        ) else { return }
        appLockController.notifyUserActivity()
        // Idempotence lives in the shared reducer: a tap during a visible
        // claim is a no-op, and a tap while the control channel is down
        // becomes an intent that claims after the next attach (R4).
        _ = session.sessionCommands(tmux: tmux).dispatch(
            .reclaimTmuxGridAuthority(reason: .user)
        )
    }

    /// Cancels a show or tap that is waiting for the connection, as its R3
    /// expiry would. Not a hide: the session stays displayed, so a peer
    /// that holds the grid is drawn as the tappable veil.
    private func cancelPendingGridAuthorityIntent() {
        appLockController.notifyUserActivity()
        tmux.cancelGridAuthorityIntent()
    }

    /// Registers this session's controller for show/hide edges (S2′) and
    /// mirrors its password/OTP prompt into the intent clock pause.
    private func registerGridAuthorityShowTarget() {
        showEdges?.register(tmux, for: liveSessionID)
        showEdges?.setChallengePresented(sharedChallenge != nil, for: liveSessionID)
    }

    /// `.unknown` is a transport gap, not evidence that this session stopped
    /// being controlled elsewhere. Preserve the sidebar's last-known glyph
    /// across reconnect/background teardown; `.mine` or session removal is
    /// the authoritative clear.
    private func mirrorGridAuthorityInRegistry() {
        switch tmux.gridAuthority {
        case .peer(let displayName):
            sessionRegistry.setGridAuthorityPeerName(displayName, for: liveSessionID)
        case .mine:
            sessionRegistry.setGridAuthorityPeerName(nil, for: liveSessionID)
        case .unknown:
            break
        }
    }

    private func handleCompactTmuxFocusRequest() {
        sessionRegistry.handleTmuxFocusRequest(
            sessionID: liveSessionID, carrier: session, tmux: tmux,
            commands: session.sessionCommands(tmux: tmux), isShown: isActive)
    }

    private var showsLaunchOverlay: Bool { launchOverlayVisible }

    /// One line shape for the whole launch path, so a user's diagnostics
    /// file can be read as a single timeline.
    ///
    /// The session id is the third token on purpose: `DiagnosticLogStore`
    /// rate-limits by the first four tokens with digits masked, so tagging
    /// each session gives every launch attempt its own budget instead of
    /// letting one reconnect-happy minute suppress the next attempt's
    /// evidence.
    ///
    /// `nameHash=` is appended here rather than written at call sites so every
    /// launch line — past and future — carries it and no new site can forget:
    /// `sid=` is per *view*, so it cannot link a reconnect to the attempt before
    /// it, and the hashed tmux session name is the only stable identity in play.
    /// It goes at the *end* of the line, not beside `sid=`, because the
    /// rate-limit signature is the first four tokens: keeping the detail's
    /// leading token (`stage=probe`, `reason=…`) inside the signature preserves
    /// one bucket per launch stage. Never rename it to `name=` or `session=` —
    /// the sanitizer redacts both, and a redacted correlator is no correlator.
    private func logLaunch(_ event: String, _ detail: String) {
        let nameHash = resolvedTmuxSessionName.map(AutoTmuxScript.sessionNameDigest) ?? "none"
        DiagnosticLogStore.appendSSH(
            "launch \(event) sid=\(liveSessionID.uuidString.prefix(8)) \(detail) nameHash=\(nameHash)"
        )
    }

    /// Send the configured shell/tmux launch exactly once for the current PTY
    /// generation. Shared by the initial SSH connection and the narrow
    /// transport replacement used after a poisoned tmux command stream.
    private func sendConfiguredLaunchIfNeeded() {
        guard presentationSessionState == .connected, !sentAutoTmuxCommand else { return }
        let prologue = HostLaunchPrologue.multilineStdin(
            envVars: session.host.envVars,
            startupSnippet: session.host.startupSnippet
        ) ?? ""
        switch session.host.launchMode {
        case .autoTmux, .pinnedTmux:
            sentAutoTmuxCommand = true
            tmux.suppressPassthroughOutputUntilControlMode = true
            noTmuxScanner.reset()
            let resolvedFrom = resolvedTmuxSessionName == nil ? "store" : "state"
            let name = resolvedTmuxSessionName
                ?? HostRuntimeStateStore.sessionName(for: session.host)
            resolvedTmuxSessionName = name
            let cmd = prologue + AutoTmuxScript.command(sessionName: name)
            autoTmuxSentAt = Date()
            lastAutoTmuxCommand = cmd
            logLaunch(
                "auto-tmux-send",
                "bytes=\(cmd.utf8.count) prologueBytes=\(prologue.utf8.count) resolvedFrom=\(resolvedFrom)"
            )
            session.sessionCommands.sendInput(Array(cmd.utf8))
            armTmuxLaunchWatchdog(sessionName: name, command: cmd)
        case .customCommand:
            let raw = session.host.launchCommand ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                sentAutoTmuxCommand = true
                var cmd = prologue + raw
                if !cmd.hasSuffix("\n") { cmd += "\n" }
                session.sessionCommands.sendInput(Array(cmd.utf8))
            } else if !prologue.isEmpty {
                sentAutoTmuxCommand = true
                session.sessionCommands.sendInput(Array(prologue.utf8))
            }
        }
    }

    private func beginInlineTmuxPTYRecovery(recovery: Int) {
        guard !inlineTmuxPTYRecoveryInProgress else { return }
        guard session.requestInteractivePTYRecovery(
            reason: "tmux-command-queue-\(recovery)"
        ) else {
            logLaunch(
                "command-queue-recovery",
                "result=pty-request-rejected recovery=\(recovery)"
            )
            return
        }
        inlineTmuxPTYRecoveryInProgress = true
        launchOverlayVisible = true
        terminalBox.dismissTransientInteractions()
        tmuxLaunchWatchdog?.cancel()
        tmuxLaunchWatchdog = nil
        tmuxHydrationWatchdog?.cancel()
        tmuxHydrationWatchdog = nil
        logLaunch(
            "command-queue-recovery",
            "result=transport-reconnect-requested recovery=\(recovery) ptyGeneration=\(session.interactivePTYGeneration)"
        )
    }

    private func relaunchAfterInlineTmuxPTYRecovery(generation: Int) {
        guard inlineTmuxPTYRecoveryInProgress else { return }
        tmux.reset()
        noTmuxScanner.reset()
        noTmuxBannerVisible = false
        launchChunkTraceCount = 0
        sentAutoTmuxCommand = false
        inlineTmuxPTYRecoveryInProgress = false
        logLaunch(
            "command-queue-recovery",
            "result=transport-reconnected ptyGeneration=\(generation)"
        )
        sendConfiguredLaunchIfNeeded()
    }

    /// Milliseconds since the launch command went out, for trace lines.
    private var sinceAutoTmuxSend: String {
        guard let autoTmuxSentAt else { return "n/a" }
        return String(Int(Date().timeIntervalSince(autoTmuxSentAt) * 1_000))
    }

    /// How long a tmux launch may stay silent before we show the shell.
    /// The first stage is generous enough for a cold `tmux` server start
    /// over a slow link; the second covers a re-sent command.
    private static let tmuxLaunchProbeDelay: Duration = .seconds(8)
    private static let tmuxLaunchGiveUpDelay: Duration = .seconds(8)

    /// Hand the terminal back to the user when tmux is not going to take
    /// over. Stops suppressing passthrough output (so whatever the remote
    /// actually said becomes visible), drops the launch shield, and marks
    /// the live session as a plain shell so the sidebar and restore
    /// snapshots stop advertising tmux.
    private func degradeTmuxLaunchToPlainShell(reason: TmuxLaunchDegradeReason) {
        tmuxLaunchWatchdog?.cancel()
        tmuxLaunchWatchdog = nil
        tmuxHydrationWatchdog?.cancel()
        tmuxHydrationWatchdog = nil
        guard !noTmuxBannerVisible, tmux.mode != .tmuxControl else { return }
        logLaunch(
            "degrade",
            "reason=\(reason.diagnosticName) mode=\(session.host.launchMode.rawValue) overlay=\(launchOverlayVisible) sinceSendMs=\(sinceAutoTmuxSend) chunks=\(launchChunkTraceCount)"
        )
        launchOverlayVisible = false
        tmux.suppressPassthroughOutputUntilControlMode = false
        noTmuxScanner.reset()
        noTmuxBannerReason = reason
        noTmuxBannerVisible = true
        onEffectiveLaunchModeChanged(.customCommand)
    }

    /// Arm the launch watchdog after writing the tmux one-liner.
    ///
    /// Stage 1 (`tmuxLaunchProbeDelay`): still no DCS. Ask the host over a
    /// side channel whether the session exists. If it does, tmux is simply
    /// slow — keep waiting rather than typing into a live client. If it
    /// doesn't, the command never ran (a login shell that was still
    /// starting when the bytes arrived and dropped them, a dotfile that
    /// took over the terminal first), so re-send it now that the shell is
    /// certainly reading.
    ///
    /// Stage 2 (`tmuxLaunchGiveUpDelay`): still nothing — stop hiding the
    /// terminal and let the user see the host's own error text.
    private func armTmuxLaunchWatchdog(sessionName: String, command: String) {
        tmuxLaunchWatchdog?.cancel()
        tmuxLaunchWatchdog = Task { @MainActor in
            try? await Task.sleep(for: Self.tmuxLaunchProbeDelay)
            guard !Task.isCancelled, tmux.mode == .passthrough else { return }
            guard case .connected = presentationSessionState else { return }

            let exists = await remoteTmuxSessionExists(named: sessionName)
            logLaunch(
                "watchdog",
                "stage=probe remoteSessionExists=\(exists.map(String.init) ?? "unknown") sinceSendMs=\(sinceAutoTmuxSend) chunks=\(launchChunkTraceCount)"
            )
            guard !Task.isCancelled, tmux.mode == .passthrough else { return }

            if exists == false {
                logLaunch(
                    "auto-tmux-resend",
                    "bytes=\(command.utf8.count)"
                )
                session.sessionCommands.sendInput(Array(command.utf8))
            }

            try? await Task.sleep(for: Self.tmuxLaunchGiveUpDelay)
            guard !Task.isCancelled, tmux.mode == .passthrough else { return }
            guard case .connected = presentationSessionState else { return }
            degradeTmuxLaunchToPlainShell(reason: .noHandshake)
        }
    }

    /// How long attach hydration may stay silent after the DCS before the
    /// app intervenes. Nudge + reveal total 10s — deliberately inside the
    /// overlay's 12s stall notice, so automatic recovery runs before the
    /// user is offered abandon-ship actions.
    private static let tmuxHydrationNudgeDelay: Duration = .seconds(5)
    private static let tmuxHydrationRevealDelay: Duration = .seconds(5)

    /// Arm the hydration watchdog on control-mode entry.
    ///
    /// Stage 1 (`tmuxHydrationNudgeDelay`): control mode is up but no
    /// initial render — re-run the authoritative refresh with a fresh retry
    /// budget and allow the first `%output` to latch ungated
    /// (`forceInitialRenderRecovery`).
    ///
    /// Stage 2 (`tmuxHydrationRevealDelay` later): still nothing — the
    /// attach is live underneath, so reveal the terminal rather than degrade:
    /// drop the overlay and raise the hydration banner. The user's first
    /// keystroke produces `%output`, which the ungated latch paints.
    /// Metadata refreshes are deferred while the app is inactive, so the
    /// reveal waits for an active app before judging silence.
    private func armTmuxHydrationWatchdog() {
        tmuxHydrationWatchdog?.cancel()
        guard launchOverlayVisible else { return }
        tmuxHydrationWatchdog = Task { @MainActor in
            try? await Task.sleep(for: Self.tmuxHydrationNudgeDelay)
            guard !Task.isCancelled, launchOverlayVisible,
                  tmux.mode == .tmuxControl, !tmux.isInitialRenderReady
            else { return }
            guard case .connected = presentationSessionState else { return }
            logLaunch(
                "hydration",
                "stage=nudge sinceSendMs=\(sinceAutoTmuxSend)"
            )
            tmux.forceInitialRenderRecovery(reason: "launch-hydration-nudge")

            try? await Task.sleep(for: Self.tmuxHydrationRevealDelay)
            while !appPhase.isActive, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, launchOverlayVisible,
                  tmux.mode == .tmuxControl, !tmux.isInitialRenderReady
            else { return }
            guard case .connected = presentationSessionState else { return }
            logLaunch(
                "hydration",
                "stage=reveal sinceSendMs=\(sinceAutoTmuxSend)"
            )
            launchOverlayVisible = false
            noTmuxBannerReason = .hydrationStalled
            noTmuxBannerVisible = true
        }
    }

    /// `true` / `false` when the host answered, `nil` when the probe could
    /// not run (transport error, or a login shell that never returns).
    /// Runs without a login shell so a host whose dotfiles start tmux
    /// can't hijack the probe channel.
    private func remoteTmuxSessionExists(named name: String) async -> Bool? {
        let marker = "TESSERA_TMUX_PROBE"
        let command = "tmux has-session -t \(name) 2>/dev/null "
            + "&& printf '\(marker)=yes\\n' || printf '\(marker)=no\\n'"
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { @MainActor in
                do {
                    let output = try await session.executeConnectedCommand(
                        command,
                        inShell: false
                    )
                    if output.contains("\(marker)=yes") { return true }
                    if output.contains("\(marker)=no") { return false }
                    logLaunch(
                        "watchdog",
                        "stage=probe-unparsed bytes=\(output.utf8.count)"
                    )
                    return nil
                } catch {
                    logLaunch(
                        "watchdog",
                        "stage=probe-failed errorType=\(String(describing: type(of: error)))"
                    )
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Printable, bounded rendering of a raw output chunk for the launch
    /// trace. Control bytes become `\xNN` so the log stays single-line.
    static func launchTracePreview(_ chunk: [UInt8], limit: Int = 160) -> String {
        var out = ""
        for byte in chunk.prefix(limit) {
            switch byte {
            case 0x20...0x26, 0x28...0x5B, 0x5D...0x7E:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "\\x%02x", byte)
            }
        }
        if chunk.count > limit { out += "…" }
        return out
    }

    /// Caption shown by the launch overlay. Phases map 1:1 to
    /// observable transitions in `presentationSessionState` + `tmux.mode` +
    /// `tmux.isInitialRenderReady`; no aspirational steps. Plain SSH
    /// (`.customCommand`) only ever sees `.connecting` because the
    /// overlay dismisses on first `.connected`.
    private var launchPhase: SessionLaunchPhase {
        if presentationSessionState != .connected { return .connecting }
        if tmux.mode != .tmuxControl   { return .startingTmux }
        return .attachingPane
    }

    /// Sub-line shown below the phase caption. The tmux session name
    /// for tmux modes; nil (collapses to whitespace) for plain shell.
    private var launchSubtitle: String? {
        switch session.host.launchMode {
        case .autoTmux, .pinnedTmux: return resolvedTmuxSessionName
        case .customCommand:         return nil
        }
    }

    /// Non-nil when the connect attempt failed; flips the launch overlay
    /// into its error state (the overlay no longer dismisses on `.failed`).
    private var launchFailureReason: String? {
        if case .failed(let reason) = presentationSessionState { return reason }
        return nil
    }

    /// ⌘⇧E / top-bar toggle. First open attaches the shared per-host
    /// bridge (same auth flags the terminal connected with, so trust
    /// and biometric gating behave identically) and seeds the cwd from
    /// whichever source is live.
    private func toggleFilesPanel() {
        terminalBox.dismissTransientInteractions()
        if filesPanel.isOpen {
            withAnimation(.easeInOut(duration: 0.2)) { filesPanel.close() }
            return
        }
        configureFilesPanelIfNeeded()
        if tmux.mode == .tmuxControl {
            filesPanel.terminalReportedDirectory(tmux.activePaneCurrentPath)
        } else if let dir = terminalBox.view?.getTerminal().hostCurrentDirectory {
            filesPanel.terminalReportedDirectory(dir)
        }
        filesPanel.transfers?.acknowledgeBackgroundAttention()
        withAnimation(.easeInOut(duration: 0.2)) { filesPanel.open() }
    }

    private var fileTransferAttention: BackgroundTransferAttention {
        fileBridges.existingTransferQueue(for: FileBridgeKey(host: session.host))?
            .backgroundAttention ?? .none
    }

    private var compactFilesBinding: Binding<Bool> {
        Binding(
            get: { isPhone && filesPanel.isOpen },
            set: { if !$0 { filesPanel.close() } }
        )
    }

    /// Bridge/handler wiring shared by the panel toggle and the §3
    /// selection actions (which may run with the panel closed).
    private func configureFilesPanelIfNeeded() {
        if filesPanel.bridge == nil {
            let bridge = fileBridges.bridge(
                for: session.host,
                requireBiometric: session.requireBiometric,
                isSecureEnclave: session.isSecureEnclave
            )
            filesPanel.attach(bridge: bridge)
            filesPanel.configureFileActions(
                transfers: fileBridges.transferQueue(for: bridge),
                hostFolderName: session.host.name
            )
        }
        if filesPanel.onInstallShellIntegration == nil {
            let host = session.host
            let requireBiometric = session.requireBiometric
            let isSecureEnclave = session.isSecureEnclave
            filesPanel.onInstallShellIntegration = { [filesPanel] in
                filesPanel.infoMessage = String(localized: "Installing shell integration…")
                Task { @MainActor in
                    do {
                        let report = try await RemoteShellIntegrationInstaller.install(
                            on: host,
                            requireBiometric: requireBiometric,
                            isSecureEnclave: isSecureEnclave
                        )
                        filesPanel.infoMessage = String(
                            localized: "Installed (\(report.rcFilesUpdated.joined(separator: ", "))). Takes effect on the next shell login — run exec $SHELL or reconnect.",
                            comment: "Shell integration installed; the argument lists the startup files that were edited"
                        )
                    } catch {
                        filesPanel.infoMessage = nil
                        filesPanel.lastError = error.localizedDescription
                    }
                }
            }
        }
        if filesPanel.onSendPathToTerminal == nil {
            // Same route as consumePendingPathInjection: quoted absolute
            // path, no trailing Enter. Overlay guard per the accessory-bar
            // convention — during tmux startup the stdin belongs to the
            // -CC bootstrap.
            filesPanel.onSendPathToTerminal = { path in
                guard presentationSessionState == .connected, !showsLaunchOverlay else { return }
                if typingAwaitsOwnAuthority {
                    Task { @MainActor in
                        await awaitOwnAuthorityTransition()
                        guard presentationSessionState == .connected, !showsLaunchOverlay else {
                            copyUndeliveredPathToClipboard(path, refusedByAuthority: false)
                            return
                        }
                        typeRemotePath(path)
                    }
                } else {
                    typeRemotePath(path)
                }
            }
        }
    }

    /// §3 selection menu: resolve the selected text over the file
    /// bridge — file → Quick Look (works with the panel closed),
    /// directory → the panel opens there. Misses land on the same
    /// toast the terminal drop target uses.
    private func handleSelectionPathAction(
        _ action: TesseraTerminalSelectionPathAction, text: String
    ) {
        guard presentationSessionState == .connected, !showsLaunchOverlay else { return }
        appLockController.notifyUserActivity()
        configureFilesPanelIfNeeded()
        let cwd: String? = tmux.mode == .tmuxControl
            ? tmux.activePaneCurrentPath
            : terminalBox.view?.getTerminal().hostCurrentDirectory
        filesPanel.openTerminalPath(
            text,
            cwd: cwd,
            intent: action == .quickLook ? .quickLook : .reveal
        ) { message in
            terminalDropFailure = message
        }
    }

    /// Failed terminal drops surface here (the drop modifier's toast) —
    /// the panel and its error banner may be CLOSED during a drop.
    @State private var terminalDropFailure: String?

    /// Drop-on-terminal: upload to temp over the host's bridge, then
    /// type the quoted resolved path. Trailing space per the desktop
    /// drag-into-terminal convention — it also keeps multi-file drops
    /// from concatenating into one shell word.
    private func handleTerminalDrop(_ providers: [NSItemProvider]) -> Bool {
        guard presentationSessionState == .connected,
              !showsLaunchOverlay,
              !terminalInputGatedByAuthority
        else { return false }
        let bridge = fileBridges.bridge(
            for: session.host,
            requireBiometric: session.requireBiometric,
            isSecureEnclave: session.isSecureEnclave
        )
        let queue = fileBridges.transferQueue(for: bridge)
        return FilesPanelController.handleTerminalDrop(
            providers,
            queue: queue,
            inject: { path in
                await awaitOwnAuthorityTransition()
                // The upload outlived the connection: keep the path.
                guard presentationSessionState == .connected, !showsLaunchOverlay else {
                    copyUndeliveredPathToClipboard(path, refusedByAuthority: false)
                    return
                }
                typeRemotePath(path, suffix: " ")
            },
            reportFailure: { message in
                terminalDropFailure = message
                DiagnosticLogStore.appendApp("terminal-drop failed: \(message)")
            }
        )
    }

    /// Identity for the cwd-poll task; see RemoteCwdPoller.taskKey.
    private var sshCwdPollKey: String {
        RemoteCwdPoller.taskKey(
            panelOpen: filesPanel.isOpen,
            sessionActive: isActive,
            tmuxAttached: tmux.mode == .tmuxControl
        )
    }

    /// Upload sheet's "paste path": type the quoted absolute path into
    /// this session's terminal (no trailing Enter). The facade routes it
    /// per transport — stdin in passthrough, send-keys to the active pane
    /// under -CC. Every edge calls this, so it reads the slot itself: an
    /// edge that fires after another consumed the path finds none. Our
    /// own resume or take-back leaves it pending until typing opens.
    private func consumePendingPathInjection() {
        guard let path = session.pendingPathInjection,
              presentationSessionState == .connected,
              !typingAwaitsOwnAuthority
        else { return }
        session.pendingPathInjection = nil
        typeRemotePath(path)
    }

    /// Types an uploaded or dropped path (S5′). A path is typing: it goes
    /// as acknowledged `sendInput`, gated, routed and queued like a key,
    /// and a path the gate refuses or the backend drops goes to the
    /// clipboard with a message instead of vanishing.
    private func typeRemotePath(_ path: String, suffix: String = "") {
        let bytes = Array((FilesPanelController.shellQuoted(path) + suffix).utf8)
        terminalBox.noteOutOfBandInput()
        session.sessionCommands(tmux: tmux).sendInputAcknowledged(bytes) { delivery in
            switch delivery {
            case .sent: break
            case .refused: copyUndeliveredPathToClipboard(path, refusedByAuthority: true)
            case .dropped: copyUndeliveredPathToClipboard(path, refusedByAuthority: false)
            }
        }
    }

    /// Whether typing waits on our own resume or take-back, which ends in
    /// typing or a veil within moments.
    private var typingAwaitsOwnAuthority: Bool {
        guard let refusal = session.sessionCommands(tmux: tmux)
            .authorityRefusal(for: .sendInput(Data()))
        else { return false }
        return refusal != .yielded
    }

    /// Lets a path that arrives during our own resume or take-back wait
    /// for it (at most 10 s), in order: keys are refused meanwhile.
    private func awaitOwnAuthorityTransition() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while typingAwaitsOwnAuthority, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func copyUndeliveredPathToClipboard(_ path: String, refusedByAuthority: Bool) {
        UIPasteboard.general.string = path
        terminalDropFailure = refusedByAuthority
            ? String(localized: "The uploaded path was copied to the clipboard because this session is being controlled from another device.")
            : String(localized: "The terminal is no longer available, so the remote path was copied to the clipboard.")
    }

    private func preservePendingPathAfterConnectionFailure() {
        guard let path = session.pendingPathInjection else { return }
        session.pendingPathInjection = nil
        UIPasteboard.general.string = path
        terminalDropFailure = String(localized: "The uploaded path was copied to the clipboard because the terminal did not connect.")
    }

    /// Plain-SSH follow fallback: OSC 7 stays primary (instant,
    /// per-shell exact — the loop stands down while the terminal has a
    /// live value), the poller covers hosts without shell integration
    /// by following the user's newest tty-attached shell. The install
    /// CTA still exists but now only surfaces when BOTH signals fail
    /// (followState == .unavailable).
    private func runSSHCwdPoll() async {
        guard filesPanel.isOpen, isActive, tmux.mode != .tmuxControl else { return }
        await RemoteCwdPoller.run(
            panel: filesPanel,
            discovery: .newestLoginShell,
            oscSignal: {
                // Gate on a passthrough delivery: see
                // osc7DeliveredInPassthrough for why presence of
                // hostCurrentDirectory alone can't prove liveness.
                osc7DeliveredInPassthrough
                    ? terminalBox.view?.getTerminal().hostCurrentDirectory
                    : nil
            }
        )
    }

    private var sessionDecoratedChrome: some View {
        ZStack(alignment: .top) {
            // §3.5 R3.5.4: background extends edge-to-edge under the
            // rounded corners and home-indicator area. Pinned to the
            // active TerminalTheme's bg so the page-edge gutters blend
            // seamlessly with the SwiftTerm canvas.
            activeTheme.bg.ignoresSafeArea()

            if let background = resolvedTerminalBackground, !showsLaunchOverlay {
                TerminalBackdrop(background: background, baseColor: activeTheme.bg)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Top bar + find bar stay in the window's coordinate space while
                // the keyboard lifts the rest of the session — the find query
                // field is an input the user has to read while typing into it.
                KeyboardLiftExemptChrome {
                    SessionTopBar(
                        state: presentationSessionState,
                        host: session.host,
                        sessionID: liveSessionID,
                        sessionIsActive: isActive,
                        tmux: tmux,
                        sessionCommands: session.sessionCommands(tmux: tmux),
                        tmuxIsDegraded: false,
                        connectionStatus: .ssh(state: presentationSessionState),
                        onToggleSidebar: onToggleSidebar,
                        sidebarVisible: sidebarVisible,
                        onBack: {
                            terminalBox.dismissTransientInteractions()
                            onBack()
                        },
                        onDisconnect: {
                            terminalBox.dismissTransientInteractions()
                            onUserClosedSession()
                            session.sessionCommands.disconnect()
                        },
                        findController: findController,
                        filesPanelOpen: filesPanel.isOpen,
                        fileTransferAttention: fileTransferAttention,
                        onToggleFiles: toggleFilesPanel,
                        bellController: bellController,
                        forwarderManager: session.portForwarderManager,
                        T: themeChromeTokens,
                        onOpenAgentCenter: onOpenAgentCenter,
                        continuityActions: continuityActions
                    )
                    .frame(height: SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: isPhone
                    ))

                    if findController.isOpen {
                        FindBar(
                            controller: findController,
                            horizontalInset: isPhone ? 10 : Self.cornerInset,
                            T: themeChromeTokens
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                // Carries the top bar's former zIndex: the chrome group draws
                // above the terminal, which it now overlaps while lifted.
                .zIndex(2)

                // Terminal content. Horizontal inset clears the bottom
                // rounded corners (iPadOS's safeAreaInsets has no
                // horizontal component on iPad, so we have to inset
                // manually). The top is already pushed down by the
                // VStack placement below the top bar; the bottom should
                // run edge-to-edge so the terminal uses all rows.
                ZStack {
                    TerminalSurfaceBound(
                        initialData: [],
                        onMade: { view in terminalBox.attach(view) },
                        onReady: { terminalBox.markRenderReady() },
                        onSend: { bytes in
                            guard !showsLaunchOverlay, !terminalInputGatedByAuthority else {
                                // Refused bytes never reach the PTY: drop the UIKit input
                                // mirror so later edits cannot delete what it believes was typed.
                                terminalBox.noteOutOfBandInput()
                                return
                            }
                            session.sessionCommands(tmux: tmux).sendInput(Array(bytes))
                        },
                        onResize: { cols, rows in
                            lastTerminalSize = (cols, rows)
                            // Only propagate resize to the remote when this
                            // session is the foreground tab. Background
                            // sessions must not send SIGWINCH — it would
                            // reflow vim/less/htop while the user isn't
                            // looking, and the "new" size might reflect the
                            // sidebar being open, not the actual terminal
                            // viewport the user will see when they switch.
                            guard isActive else { return }
                            // While a multi-pane grid is mounted IT is the size
                            // authority (it pushes a header-reserved row count via
                            // refresh-client -C). The shared terminal's frame is
                            // unchanged behind the grid, so its sizeChanged would
                            // push the FULL row count and fight the grid's reserved
                            // size — leaving tmux at the wrong height. Suppress the
                            // push here; the grid owns it, and collapse re-pushes
                            // the full size below.
                            guard activeGridWindow == nil else { return }
                            // The compact canvas is framed at the authoritative
                            // server grid, so this inner callback reports server
                            // cells rather than the phone's physical viewport.
                            // Its outer GeometryReader is the sole compact size
                            // authority; feeding this value back can erase the
                            // smaller-phone baseline before an iPad cede.
                            guard !(isPhone && tmux.mode == .tmuxControl) else { return }
                            session.sessionCommands(tmux: tmux).resize(
                                columns: cols,
                                rows: rows
                            )
                        },
                        onTitle: { title in
                            // §3.2 C3: OSC 0/1/2 title sequences from the
                            // active pane update the tab label. tmux treats
                            // these as pane_title (no %window-renamed), so
                            // the terminal renderer is the only source.
                            tmux.updateActiveWindowName(title)
                            currentTerminalTitle = title
                        },
                        onUserActivity: {
                            appLockController.notifyUserActivity()
                        },
                        onBell: {
                            bellController.ring(
                                source: .session(session.host.id),
                                isOriginOnScreen: true,
                                hostDisplayName: session.host.name,
                                paneTitle: currentTerminalTitle
                            )
                        },
                        // Trackpad/wheel/inertia frames: the coordinator reports
                        // the PROPOSED offset before clamping, so a negative
                        // value is the gesture genuinely crossing the oldest
                        // local row. Only scroll-up frames reach this hook.
                        onPrimaryScrollbackUnderflow: { view, pointsY, proposedOffsetY, maxOffsetY in
                            noteInlineTmuxScrollUp(
                                surfaceID: .live,
                                view: view,
                                proposedOffsetY: proposedOffsetY,
                                maxOffsetY: maxOffsetY,
                                pointsY: pointsY,
                                isInertial: false
                            )
                        },
                        agentScrollBlockingActive:
                            agentScrollPrevention(paneID: activeAgentScrollPaneID) != nil,
                        onAgentScrollBlocked: {
                            presentAgentScrollPrevention(paneID: activeAgentScrollPaneID)
                        },
                        mouseReportingImpliesAltScreen: false,
                        suppressDirectColorQueryResponses: true,
                        softwareModifierState: modifierState,
                        tmuxShortcutsEnabled: true,
                        onTmuxShortcut: handleTmuxShortcut,
                        onFindShortcut: { shortcut in
                            appLockController.notifyUserActivity()
                            switch shortcut {
                            case .open:     findController.open()
                            case .next:     findController.next()
                            case .previous: findController.previous()
                            }
                        },
                        onSwitcherShortcut: { shortcut in
                            appLockController.notifyUserActivity()
                            handleSwitcherShortcut(shortcut)
                        },
                        onOpenSettings: {
                            appLockController.notifyUserActivity()
                            onOpenSettings()
                        },
                        onOpenAgentCenter: onOpenAgentCenter.map { action in
                            {
                                appLockController.notifyUserActivity()
                                action()
                            }
                        },
                        // The shared terminal yields first responder to the
                        // grid's focused pane while a multi-pane window is up.
                        // `!isActive` is load-bearing: background (non-selected,
                        // opacity-0) sessions stay MOUNTED, and without this gate
                        // their terminal reclaims first responder on any
                        // re-render — stealing focus from whatever IS on screen
                        // (e.g. a TextField in the host editor). Only the
                        // foreground session may hold the keyboard.
                        suppressFirstResponderReclaim: integrationScrollHarnessSuppressesFirstResponder
                            || !isActive
                            || findController.isOpen
                            || commandPalette.isOpen
                            || filesPanel.textEntryActive
                            || modifierState.suppressesSoftwareKeyboardReclaim
                            || sessionIsControlledElsewhere
                            || activeGridWindow != nil,
                        forceResignFirstResponder: sessionIsControlledElsewhere,
                        onHardwareKey: nil,
                        // Committed moves that land while a finger is down
                        // or a glide runs (output under the reader).
                        onTerminalScrolled: { view in
                            handleInlineTerminalScrolled(surfaceID: .live, view: view)
                        },
                        // Finger drags move SwiftTerm's own scroll view, which
                        // never reaches the underflow hook above, so the
                        // inline history gate is evaluated from each frame.
                        onNativeScrollFrame: { view, previousOffsetY in
                            handleInlineNativeScrollFrame(
                                surfaceID: .live,
                                view: view,
                                previousOffsetY: previousOffsetY
                            )
                        },
                        scrollRetentionID: [
                            "ssh",
                            tmux.activeWindowId?.description ?? "nil",
                            tmux.activePaneId?.description ?? "nil",
                            activeGridWindow?.id.description ?? "nil",
                        ].joined(separator: ":"),
                        onScrollDiagnostic: { message in
                            recordScrollDiagnostic(message)
                        },
                        onHostDirectory: { dir in
                            // OSC 7 owns the cwd only while no tmux is
                            // attached; under tmux the pane-metadata
                            // subscription is the per-pane source of truth.
                            guard tmux.mode == .passthrough else { return }
                            if dir != nil { osc7DeliveredInPassthrough = true }
                            filesPanel.terminalReportedDirectory(dir)
                        },
                        onFilesShortcut: {
                            appLockController.notifyUserActivity()
                            toggleFilesPanel()
                        },
                        onCustomShortcut: { shortcut in
                            guard !showsLaunchOverlay, !terminalInputGatedByAuthority else {
                                // Refused bytes never reach the PTY: drop the UIKit input
                                // mirror so later edits cannot delete what it believes was typed.
                                terminalBox.noteOutOfBandInput()
                                return
                            }
                            guard shouldFire(shortcut) else { return }
                            appLockController.notifyUserActivity()
                            let cursor = terminalBox.view?.getTerminal().applicationCursor ?? false
                            session.sessionCommands(tmux: tmux).sendInput(
                                shortcut.encoded(applicationCursor: cursor)
                            )
                        },
                        onSelectionPathAction: { action, text in
                            handleSelectionPathAction(action, text: text)
                        },
                        terminalBackground: resolvedTerminalBackground
                    )
                    .modifier(GeometryNeutralTmuxCanvasModifier(
                        windowRect: compactSingleWindowRect,
                        focusRect: compactSingleWindowRect,
                        cellSize: terminalCellSize,
                        onViewportSize: updateCompactInlineViewport
                    ))
                    .allowsHitTesting(!showsLaunchOverlay && activeGridWindow == nil)
                    // With a background picture the grid canvas is transparent
                    // (it no longer paints an opaque fill over this inert
                    // surface), so hide the shared surface outright while a
                    // grid is mounted or its stale text bleeds through.
                    .opacity(
                        showsLaunchOverlay
                            || (activeGridWindow != nil && resolvedTerminalBackground != nil)
                            ? 0 : 1
                    )
                    .animation(
                        // Sequential dissolve: snap the terminal to
                        // invisible while the overlay reappears; on
                        // dismiss, wait for the overlay's own removal
                        // transition (0.25 s) to finish before fading
                        // the terminal back in over 0.3 s. The user
                        // sees overlay-out → terminal-in, not a
                        // crossfade.
                        showsLaunchOverlay
                            ? .linear(duration: 0)
                            : .easeInOut(duration: 0.30).delay(0.25),
                        value: showsLaunchOverlay
                    )

                    // Multi-pane grid overlays the shared terminal (which goes
                    // inert — its panes' %output routes to per-pane sinks).
                    if let gridWindow = activeGridWindow, !showsLaunchOverlay {
                        PaneGridView(
                            window: gridWindow,
                            tmux: tmux,
                            renderDropSummary: renderDropSummary,
                            sessionCommands: session.sessionCommands(tmux: tmux),
                            cellSize: terminalCellSize,
                            chrome: themeChromeTokens,
                            backgroundColor: activeTheme.bg,
                            terminalBackground: resolvedTerminalBackground,
                            tmuxShortcutsEnabled: true,
                            onTmuxShortcut: handleTmuxShortcut,
                            onFindShortcut: { shortcut in
                                appLockController.notifyUserActivity()
                                switch shortcut {
                                case .open:     findController.open()
                                case .next:     findController.next()
                                case .previous: findController.previous()
                                }
                            },
                            onSwitcherShortcut: { shortcut in
                                appLockController.notifyUserActivity()
                                handleSwitcherShortcut(shortcut)
                            },
                            onOpenSettings: {
                                appLockController.notifyUserActivity()
                                onOpenSettings()
                            },
                            onOpenAgentCenter: onOpenAgentCenter.map { action in
                                {
                                    appLockController.notifyUserActivity()
                                    action()
                                }
                            },
                            onSelectionPathAction: { action, text in
                                handleSelectionPathAction(action, text: text)
                            },
                            onUserActivity: { appLockController.notifyUserActivity() },
                            agentScrollPreventionForPane: { paneID in
                                agentScrollPrevention(paneID: paneID.rawValue)
                            },
                            onAgentScrollBlocked: { paneID in
                                presentAgentScrollPrevention(paneID: paneID.rawValue)
                            },
                            // `!isActive` so a backgrounded grid's focused pane
                            // doesn't reclaim first responder from the foreground
                            // (e.g. the host editor) — same rule as the shared
                            // surface above.
                            suppressFindReclaim: integrationScrollHarnessSuppressesFirstResponder
                                || !isActive
                                || findController.isOpen
                                || commandPalette.isOpen
                                || filesPanel.textEntryActive
                                || modifierState.suppressesSoftwareKeyboardReclaim
                                || sessionIsControlledElsewhere,
                            inputSuppressed: terminalInputGatedByAuthority,
                            // Same rule as the single pane: only the veil
                            // resigns focus; `.resuming` gates sends only.
                            forceResignFirstResponder: sessionIsControlledElsewhere,
                            compactSinglePane: isPhone,
                            modifierState: modifierState,
                            kittyPaneModes: kittyPaneModes,
                            onFocusedBoxChanged: { box in
                                // Find is scoped to the focused pane: rebind
                                // its search handlers and re-run any open query.
                                findController.handlers = TerminalSearchAdapter.handlers(for: box)
                                if findController.isOpen { findController.updateSearch() }
                            },
                            onFocusedPaneRefreshed: {
                                if findController.isOpen { findController.updateSearch() }
                            },
                            onPaneBell: { paneTitle in
                                bellController.ring(
                                    source: .session(session.host.id),
                                    isOriginOnScreen: true,
                                    hostDisplayName: session.host.name,
                                    paneTitle: paneTitle
                                )
                            },
                            onScrollDiagnostic: { paneId, message in
                                recordScrollDiagnostic("surface=pane:\(paneId.description) \(message)")
                            },
                            // Inline history ladder for the grid's own
                            // `pane:<id>` render surfaces. Identical policy to
                            // the shared `.live` surface; the grid only lends
                            // this view its per-pane boxes and scroll frames.
                            onPaneSurfaceReady: { paneId, box in
                                inlineHistory.registerPaneBox(box, for: paneId)
                            },
                            onPaneSurfaceRetired: { paneId in
                                inlineHistory.retirePane(paneId)
                            },
                            onPaneSurfaceRebound: { paneId, identityChanged in
                                inlineHistory.state.surfaceRebound(
                                    Self.inlinePaneSurfaceID(paneId),
                                    identityChanged: identityChanged
                                )
                            },
                            onPaneScrolled: { paneId, view in
                                handleInlineTerminalScrolled(
                                    surfaceID: Self.inlinePaneSurfaceID(paneId),
                                    view: view
                                )
                            },
                            onPaneNativeScrollFrame: { paneId, view, previousOffsetY in
                                handleInlineNativeScrollFrame(
                                    surfaceID: Self.inlinePaneSurfaceID(paneId),
                                    view: view,
                                    previousOffsetY: previousOffsetY
                                )
                            },
                            onPanePrimaryScrollbackUnderflow: { paneId, view, pointsY, proposedOffsetY, maxOffsetY in
                                noteInlineTmuxScrollUp(
                                    surfaceID: Self.inlinePaneSurfaceID(paneId),
                                    view: view,
                                    proposedOffsetY: proposedOffsetY,
                                    maxOffsetY: maxOffsetY,
                                    pointsY: pointsY,
                                    isInertial: false
                                )
                            }
                        )
                        .id(gridWindow.id)
                    }

                    if showsLaunchOverlay {
                        SessionLaunchOverlay(
                            T: themeChromeTokens,
                            phase: launchPhase,
                            subtitle: launchSubtitle,
                            wslTailscaleMTUWarning: session.wslTailscaleMTUWarning,
                            failureReason: launchFailureReason,
                            onEditHost: onEditHost,
                            onRetry: onRetry,
                            onBack: {
                                // The stall notice puts this button up while
                                // the connect is still running, so leaving has
                                // to tear it down: the run task holds the
                                // session alive and would finish unseen.
                                onUserClosedSession()
                                onSessionEnded()
                                session.sessionCommands.disconnect()
                            },
                            reconnectingElsewhere: reconnectingElsewhere
                        )
                        .transition(.opacity)
                        .zIndex(1)
                    }

                    // Continuity takeover veil: another device holds the grid.
                    // Connection loss and session end outrank it — both are
                    // covered because the veil requires `.connected` and the
                    // launch overlay's failure state wins via the gate above.
                    if let peerName = effectiveGridAuthorityPeerName, veilIsDrawn {
                        ContinuedElsewhereOverlay(
                            T: themeChromeTokens,
                            peerDisplayName: peerName,
                            isReclaiming: gridAuthorityPresentation.isReclaiming,
                            awaitingConnection: gridAuthorityPresentation.isAwaitingConnection,
                            // Focus only the displayed, unlocked veil: hidden
                            // tabs keep theirs mounted at opacity 0, and the
                            // app lock covers a still-mounted ContentView.
                            capturesKeys: ContinuedElsewhereKeyPolicy.admitsGesture(
                                sessionIsActive: isActive,
                                appIsLocked: appLockController.isLocked
                            ),
                            animatesMotion: ContinuedElsewherePresentationPolicy.breathes(
                                displayed: ContinuedElsewhereKeyPolicy.admitsGesture(
                                    sessionIsActive: isActive,
                                    appIsLocked: appLockController.isLocked
                                ),
                                appIsActive: appPhase.isActive
                            ),
                            onTakeBack: takeBackContinuedSession,
                            onCancel: cancelPendingGridAuthorityIntent,
                            // ⌘⇧J / ⌘⇧K keep working while yielded: switching
                            // sessions changes what is on screen here, never
                            // what the peer's terminal receives. Only the
                            // foreground session registers them — a background
                            // session stays mounted (opacity 0) and its veil
                            // would otherwise claim the same chords and step
                            // from the wrong place in the list.
                            onSwitcherShortcut: isActive
                                ? { shortcut in
                                    appLockController.notifyUserActivity()
                                    handleSwitcherShortcut(shortcut)
                                }
                                : nil
                        )
                        .transition(.opacity)
                        .zIndex(2)
                    }

                    // A show resolving: the terminal stays visible (no veil
                    // flash on resume); only input waits for the read.
                    if gridAuthorityPresentation.isResuming,
                       !showsLaunchOverlay {
                        GridAuthorityResumingIndicator(
                            T: themeChromeTokens,
                            awaitingConnection: gridAuthorityPresentation.isAwaitingConnection,
                            onCancel: cancelPendingGridAuthorityIntent
                        )
                        .transition(.opacity)
                        .zIndex(3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(
                    .easeInOut(duration: ContinuedElsewherePresentationPolicy.veilFadeDuration),
                    value: sessionIsControlledElsewhere
                )
                // Drop a file onto the terminal → upload to the host's
                // temp dir, then type the quoted path (mockup §4). The
                // open panel's own drop zone sits on top and wins over
                // its strip.
                .modifier(TerminalFileDropTarget(
                    T: themeChromeTokens,
                    failureMessage: $terminalDropFailure,
                    handle: handleTerminalDrop
                ))
                // §3 terminal Quick Look with the panel closed: the
                // panel hosts presentedPreview only while open, so this
                // fallback presents it otherwise. The binding nils itself
                // while the panel is open — exactly one host at a time by
                // construction. Size (sheet vs full screen) is the user's
                // persisted choice, applied identically on both hosts.
                .quickLookPreview(item: Binding(
                    get: { filesPanel.isOpen ? nil : filesPanel.presentedPreview },
                    set: { filesPanel.presentedPreview = $0 }
                ))
                .sheet(isPresented: compactFilesBinding) {
                    FilesPanelView(
                        controller: filesPanel,
                        T: filesPanelTokens,
                        sessionIsActive: isActive,
                        // The compact card sits over its own app-themed sheet,
                        // not directly over the terminal canvas.
                        terminalBackground: nil
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(filesPanelTokens.presentationBg)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
                // Remote Files panel floats as an overlay over the
                // terminal — no trailing padding, so the terminal keeps
                // its full width and toggling the panel never resizes it
                // (no sizeChanged → no SIGWINCH / refresh-client reflow).
                // A transparent tap-catcher behind the card dismisses the
                // panel when the user taps the terminal, like the sidebar.
                .overlay(alignment: .trailing) {
                    if filesPanel.isOpen, !isPhone {
                        ZStack(alignment: .trailing) {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) { filesPanel.close() }
                                }
                            FilesPanelView(
                                controller: filesPanel,
                                T: themeChromeTokens,
                                sessionIsActive: isActive,
                                terminalBackground: resolvedTerminalBackground
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, isPhone ? 4 : Self.cornerInset)
                .terminalKeyboardCaretShift()

                if appearance.showAccessoryBar {
                    SessionAccessoryBar(
                        accent: appearance.tokens(systemColorScheme: .dark).accent,
                        modifierState: modifierState,
                        onSend: { bytes in
                            guard !showsLaunchOverlay, !terminalInputGatedByAuthority else {
                                // Refused bytes never reach the PTY: drop the UIKit input
                                // mirror so later edits cannot delete what it believes was typed.
                                terminalBox.noteOutOfBandInput()
                                return
                            }
                            appLockController.notifyUserActivity()
                            session.sessionCommands(tmux: tmux).sendInput(bytes)
                            terminalBox.noteOutOfBandInput()
                        },
                        applicationCursor: { [terminalBox] in
                            terminalBox.view?.getTerminal().applicationCursor ?? false
                        },
                        onPageScrollAttempt: { _ in
                            guard agentScrollPrevention(
                                paneID: activeAgentScrollPaneID
                            ) != nil else { return false }
                            presentAgentScrollPrevention(
                                paneID: activeAgentScrollPaneID
                            )
                            return true
                        },
                        customShortcutApplies: shouldFire
                    )
                    .allowsHitTesting(!sessionIsControlledElsewhere)
                    .opacity(sessionIsControlledElsewhere ? 0.45 : 1)
                }
            }

            // Non-blocking host warnings sit below the top bar. The MTU card
            // lives inside the launch overlay while it is visible, then moves
            // here if the connection recovers.
            if noTmuxBannerVisible
                || (!showsLaunchOverlay
                    && !dismissedWSLTailscaleMTUWarning
                    && session.wslTailscaleMTUWarning != nil)
            {
                VStack(spacing: 8) {
                    if noTmuxBannerVisible {
                        NoTmuxBanner(
                            reason: noTmuxBannerReason,
                            onDismiss: { noTmuxBannerVisible = false }
                        )
                    }
                    if !showsLaunchOverlay,
                       !dismissedWSLTailscaleMTUWarning,
                       let warning = session.wslTailscaleMTUWarning {
                        WSLTailscaleMTUWarningView(
                            warning: warning,
                            T: themeChromeTokens,
                            onDismiss: { dismissedWSLTailscaleMTUWarning = true }
                        )
                    }
                }
                    .padding(.top, SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: isPhone
                    ))
                    .padding(.horizontal, Self.cornerInset + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }

            if let prevention = agentScrollNotice.prevention {
                AgentScrollPreventionNotice(
                    agentName: prevention.agentName,
                    T: themeChromeTokens
                )
                .padding(.top,
                    SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: isPhone
                    )
                    + (findController.isOpen ? 44 : 8)
                    + (noTmuxBannerVisible ? 58 : 0)
                )
                .padding(.horizontal, isPhone ? 12 : Self.cornerInset + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(7)
            }

            SwipePadOverlay(
                onSend: { bytes in
                    guard !showsLaunchOverlay, !terminalInputGatedByAuthority else {
                        // Refused bytes never reach the PTY: drop the UIKit input
                        // mirror so later edits cannot delete what it believes was typed.
                        terminalBox.noteOutOfBandInput()
                        return
                    }
                    appLockController.notifyUserActivity()
                    session.sessionCommands(tmux: tmux).sendInput(bytes)
                    terminalBox.noteOutOfBandInput()
                },
                tmux: tmux,
                outputActivityToken: swipePadOutputActivityToken,
                processNameProvider: {
                    let names = shellIntegration.processNames
                    if !names.isEmpty {
                        SwipePadDiagnostics.log(
                            "provider ssh source=shell-integration candidateCount=\(names.count)"
                        )
                        return names
                    }

                    SwipePadDiagnostics.log(
                        "provider ssh source=plain-ssh reason=shell-integration-empty"
                    )
                    let probeNames = await session.detectForegroundProcessNames()
                    SwipePadDiagnostics.log("provider ssh source=plain-ssh candidateCount=\(probeNames.count)")
                    return probeNames
                },
                paneProcessNameProvider: { paneID, panePID in
                    let names = await session.detectForegroundProcessNames(rootPID: panePID)
                    SwipePadDiagnostics.log(
                        "provider ssh source=tmux-pane-ps panePID=\(panePID) candidateCount=\(names.count)"
                    )
                    return names
                },
                agentContext: agentCenterV2.swipePadContext(sessionID: liveSessionID),
                sessionIsActive: swipePadSessionIsActive,
                onShowMore: onOpenAgentCenter,
                profileStore: swipePadStore,
                dictationController: dictationController
            )
            .padding(.top, SessionTopBar.reservedHeight(
                pillHeight: appearance.topBarHeight,
                compact: isPhone
            ))
            .padding(.horizontal, isPhone ? 10 : Self.cornerInset)
            .padding(.bottom, swipePadBottomInset)
            // The puck is terminal input chrome. Move the entire sibling
            // below the terminal layer while yielded so the takeover veil
            // visually owns the full canvas, and disable hit testing as a
            // second line behind the controller's input gate.
            .allowsHitTesting(!sessionIsControlledElsewhere)
            .zIndex(sessionIsControlledElsewhere ? -1 : 5)

            if let toast = paneCommandToast {
                PaneCommandToast(message: toast, T: themeChromeTokens)
                    .padding(.bottom, paneToastBottomInset)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: noTmuxBannerVisible)
        .animation(.easeInOut(duration: 0.25), value: showsLaunchOverlay)
        .animation(.easeInOut(duration: 0.2), value: paneCommandToast)
        .animation(.easeInOut(duration: 0.18), value: agentScrollNotice.prevention)
        .ignoresSafeArea(.container, edges: .bottom)
        .terminalKeyboardLayout(
            resizesTerminal: appearance.resizeTerminalWithKeyboard,
            caretClearance: {
                // A mounted pane grid owns the caret; the shared surface behind
                // it is inert and its cursor is stale, so let the whole
                // translation stand rather than aim at the wrong row. Find is
                // the same call for a different reason: it scrolls the surface
                // to a *match*, which has nothing to do with where the caret
                // is, so the whole grid has to clear the keyboard.
                guard activeGridWindow == nil, !findController.isOpen else { return nil }
                return terminalBox.caretClearance(
                    cellHeight: terminalCaretCellHeight(
                        fontID: appearance.terminalFontID,
                        fontSize: appearance.fontSize
                    ),
                    mouseReportingImpliesAltScreen: false
                )
            }
        )
        .onChange(of: activeGridWindow?.id) { oldValue, newValue in
            reconcileAgentScrollNotice()
            // `.live` is undeclared while a grid is mounted, and each grid
            // window declares its own `pane:<n>` surfaces. Nothing credited
            // on either side of that boundary describes the other.
            inlineHistory.resetRecords()
            if oldValue == nil, newValue != nil {
                // 1→N boundary: the shared terminal is being torn off the hot
                // path OUTSIDE displayWillSwap (no window swap occurs). Without
                // this synthetic snapshot, splitting while a kitty-flags TUI
                // (e.g. Codex) holds the shared terminal would lose its CSI-u
                // keyboard mode. Snapshot under the pane it was rendering so
                // that pane's grid surface restores it on its capture-repaint.
                if let paneId = tmux.renderedPaneId ?? tmux.activePaneId,
                   let terminal = terminalBox.view?.getTerminal() {
                    kittyPaneModes.snapshot(paneId, from: terminal)
                }
            } else if oldValue != nil, newValue == nil {
                // N→1: the grid collapsed back to the shared terminal. The grid
                // had pushed a header-reserved (shorter) row count; the shared
                // terminal's frame is unchanged so its sizeChanged won't fire to
                // correct it. Re-assert the full size AND repaint atomically in
                // the controller (one consistent capture + clientRows, newest
                // generation) so the survivor isn't left cursor-offset or blank
                // by a racing reserved-size refresh. (Also covers switching from
                // a grid window to a single-pane window.)
                if isActive, !isPhone, let size = lastTerminalSize {
                    session.sessionCommands.resize(columns: size.cols, rows: size.rows)
                    tmux.resyncRenderedWindowAfterGridCollapse(cols: size.cols, rows: size.rows)
                }
                // Rebind find to the shared terminal (it was scoped to a now-gone
                // pane surface).
                findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
                if findController.isOpen { findController.updateSearch() }
            }
        }
        .onChange(of: tmux.activePaneCurrentPath) { _, path in
            // tmux modes: the pane-metadata subscription pushes the active
            // pane's cwd (updates on cd AND on pane/window focus change).
            guard tmux.mode == .tmuxControl else { return }
            filesPanel.terminalReportedDirectory(path)
        }
        .onChange(of: findController.focusRequestToken) { _, _ in
            // Search has to cover the whole pane, not just the first inline
            // fill. Mirrors the mosh side channel's find-deepen request.
            requestInlineFindHistory(reason: "find-open")
        }
        .onChange(of: findController.query) { _, newQuery in
            guard !newQuery.isEmpty else { return }
            requestInlineFindHistory(reason: "find-query")
        }
        .onChange(of: tmux.mode) { _, newMode in
            terminalBox.setAcceptsPainterFeeds(newMode == .passthrough)
            updateSwipePadAgentFocus()
            if newMode != .tmuxControl {
                // tmux detached/exited, or the transport was lost: no surface
                // record survives it.
                inlineHistory.resetRecords()
            }
            // tmux detached/exited (reset() flips mode before the pane
            // paths clear, so the watcher above never delivers nil).
            // Fall back to OSC 7 when the shell reports it; nil flips
            // the panel to its no-signal state instead of leaving the
            // last tmux pane path stuck as "following".
            guard newMode == .passthrough else { return }
            filesPanel.terminalReportedDirectory(
                terminalBox.view?.getTerminal().hostCurrentDirectory
            )
        }
        .onChange(of: sessionRegistry.tmuxFocusRequest?.token, initial: true) { _, _ in
            handleCompactTmuxFocusRequest()
        }
        .onChange(of: tmux.gridAuthority) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: tmux.mode) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: tmux.controlConnectionGeneration) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: ObjectIdentifier(session)) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: tmux.windows) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: tmux.isWindowListHydrated) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: isActive) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: liveSessionID) { oldID, _ in sessionRegistry.cancelTmuxFocus(sessionID: oldID) }
        .onDisappear { sessionRegistry.cancelTmuxFocus(sessionID: liveSessionID) }
        .statusBarHidden(true)
        .persistentSystemOverlays(isPhone ? .automatic : .hidden)
        .modifier(ProgramStatusSessionBridge(
            sessionID: liveSessionID,
            hostLabel: session.host.name.isEmpty ? session.host.address : session.host.name,
            tmux: tmux,
            enabled: appearance.programStatusEnabled,
            presented: ProgramStatusCenter.presentedTerminals(
                isActive: isActive,
                isObscured: showsLaunchOverlay || veilIsDrawn || (isPhone && filesPanel.isOpen)
                    || filesPanel.presentedPreview != nil || filesPanel.presentedShare != nil
                    || filesPanel.showingUploadPicker,
                tmux: tmux,
                gridWindow: isPhone ? nil : activeGridWindow
            )
        ))
        .onAppear {
            swipePadSessionIsActive = isActive
            updateSwipePadAgentFocus()
            tunnelsRegistry.register(host: session.host.id, manager: session.portForwarderManager)
            #if DEBUG
            LiveScrollInitialRenderProbe.observe(
                sessionID: liveSessionID,
                isReady: tmux.isInitialRenderReady
            )
            if integrationScrollHarnessSuppressesFirstResponder {
                LiveScrollForegroundProbe.registerSendAction {
                    session.sessionCommands(tmux: tmux).sendInput(
                        Array((LiveScrollForegroundProbe.marker + "\r").utf8)
                    )
                }
            }
            #endif
        }
        .onDisappear {
            terminalBox.dismissTransientInteractions()
            #if DEBUG
            if integrationScrollHarnessSuppressesFirstResponder {
                LiveScrollForegroundProbe.unregisterSendAction()
            }
            #endif
            tunnelsRegistry.unregister(host: session.host.id, manager: session.portForwarderManager)
            if let agentSourceRegistrationID {
                agentCenterV2.unregisterSessionSource(
                    sessionID: liveSessionID,
                    registrationID: agentSourceRegistrationID
                )
                self.agentSourceRegistrationID = nil
            }
            swipePadOutputActivityTask?.cancel()
            swipePadOutputActivityTask = nil
        }
    }

    private var sessionDecoratedConnection: some View {
        sessionDecoratedChrome
        .task {
            // This is submitted before the controller sees transport attach,
            // so its first single or grid bind uses the user's real cap.
            tmux.submitRenderFact(.scrollbackLimit(lines: appearance.scrollbackLines))
            #if DEBUG
            session.noteCompactNavigationHarnessSessionTaskStart()
            #endif
            // Mirror every cwd report onto the session object so
            // transport-agnostic consumers (Upload sheet) can read it.
            filesPanel.onTerminalDirectoryChanged = { [weak session] dir in
                // Change-guarded: the poller re-reports the same path
                // every tick and the mirror is @Published now.
                if session?.remoteWorkingDirectory != dir {
                    session?.remoteWorkingDirectory = dir
                }
            }
            // Connect the tmux controller's upstream/downstream hooks
            // before connecting the session. `feedTerminal` paints the
            // SwiftTerm view; `sendBytes` pushes to the SSH channel.
            tmux.feedTerminalWithContext = { [terminalBox, shellIntegration] slice, feedContext in
                let renderOwner = TerminalRenderOwner(feedContext: feedContext)
                guard feedContext.source == .passthrough || renderOwner != nil else {
                    // Every tmux feed must carry its exact continuity owner.
                    // Failing closed is preferable to accepting an untagged
                    // repaint into a surface still bound to another pane.
                    DiagnosticLogStore.appendTmux(
                        "render_surface dropped_unowned_tmux_feed source=\(feedContext.source.rawValue) bytes=\(slice.count)"
                    )
                    return
                }
                terminalBox.setAcceptsPainterFeeds(feedContext.source == .passthrough)
                // A cold attach can legally render from the first live %output
                // before an authoritative capture completes. It has no prior
                // terminal owner, so establish one immediately before that
                // first byte. Later owner changes are bound only by the
                // authoritative display-swap callback below.
                if let renderOwner, terminalBox.boundOwner == nil {
                    // A first owner is a fresh ladder: nothing has been
                    // credited for this pane yet.
                    inlineHistory.state.surfaceRebound(.live, identityChanged: true)
                    terminalBox.bind(
                        owner: renderOwner,
                        restoringScrollbackLimit: appearance.scrollbackLines
                    )
                }
                #if DEBUG
                if integrationScrollHarnessSuppressesFirstResponder {
                    LiveScrollForegroundProbe.observeRenderedFeed(
                        slice,
                        source: feedContext.source,
                        reason: feedContext.reason
                    )
                }
                #endif
                let recordsScrollDiagnostics = shouldRecordScrollDiagnostics
                let before = recordsScrollDiagnostics
                    ? terminalScrollPosition(for: terminalBox.view)
                    : nil
                let performanceContext = TerminalPerformanceFeedContext(feedContext)
                terminalBox.feedTerminalOutput(
                    slice,
                    context: performanceContext,
                    shellIntegration: shellIntegration,
                    owner: renderOwner
                )
                if recordsScrollDiagnostics,
                   let view = terminalBox.view,
                   shouldLogTerminalFeedScroll(before: before, after: terminalScrollPosition(for: view)) {
                    recordScrollDiagnostic(
                        "terminal-feed bytes=\(slice.count) before=\(describeScrollPosition(before)) after=\(describeScrollPosition(for: view))"
                    )
                }
                scheduleSwipePadOutputActivityRefresh(reason: "terminal-output")
            }
            // Raw controller output is already encoded tmux control traffic.
            // Terminate it at the transport primitive to avoid re-entering
            // logical SessionCommand input and encoding it a second time.
            tmux.sendBytes = { [session] bytes in session.send(bytes) }
            tmux.sendBytesAdmitting = { [session] bytes in
                session.sendAdmitting(bytes)
            }
            tmux.commandWriteDiagnostic = { [session] sequence, correlation in
                session.noteCommandWriteDiagnostic(sequence: sequence, correlation: correlation)
            }
            tmux.onCommandQueueTransportRecoveryRequired = { recovery in
                beginInlineTmuxPTYRecovery(recovery: recovery)
            }
            tmux.terminalResponseForOutput = { [tmuxTerminalQueryResponder, appearance] paneId, slice in
                let theme = TerminalTheme.find(id: appearance.terminalThemeID)
                let responses = tmuxTerminalQueryResponder.responses(
                    for: slice,
                    streamID: paneId.description,
                    defaultForegroundRGB: theme.fgRGB,
                    defaultBackgroundRGB: theme.bgRGB
                )
                return responses.isEmpty ? nil : responses
            }
            // `/copy` in Codex (and any `tmux load-buffer -w` or copy-mode
            // yank) reaches a control-mode client only as
            // `%paste-buffer-changed`: tmux forwards OSC 52 to real ttys
            // alone. Mirror the buffer onto the device clipboard, as iTerm2
            // does for its -CC integration.
            tmux.onPasteBufferChanged = { _, text in
                UIPasteboard.general.string = text
            }
            tmux.renderSaveWindowModes = { [kittyWindowModes, terminalBox] surfaceID, windowID in
                guard surfaceID == .live, let terminal = terminalBox.view?.getTerminal() else { return }
                kittyWindowModes.save(windowID: windowID, terminal: terminal)
            }
            tmux.renderRestoreWindowModes = { [kittyWindowModes, terminalBox] surfaceID, windowID, paneInAltScreen in
                guard surfaceID == .live, let terminal = terminalBox.view?.getTerminal() else { return }
                kittyWindowModes.restore(
                    windowID: windowID,
                    paneInAltScreen: paneInAltScreen,
                    terminal: terminal,
                    terminalBox: terminalBox
                )
            }
            // Inline (SSH+tmux) history ladder. Every `.deep` repaint settles,
            // and so does every ignored/exhausted/aborted `scrollbackRequested`
            // — a gesture therefore never waits forever for its answer.
            tmux.renderInlineHistorySettled = { surfaceID, owner, depth, historySize, canDeepen in
                applyInlineHistorySettled(
                    surfaceID: surfaceID,
                    owner: owner,
                    depth: depth,
                    historySize: historySize,
                    canDeepen: canDeepen
                )
            }
            tmux.displayWillSwapWithContext = { [terminalBox, appearance] from, feedContext, paneInAltScreen in
                guard let owner = TerminalRenderOwner(feedContext: feedContext),
                      let to = feedContext.windowId
                else {
                    DiagnosticLogStore.appendTmux(
                        "render_surface dropped_unowned_swap source=\(feedContext.source.rawValue)"
                    )
                    return
                }
                recordScrollDiagnostic(
                    "tmux-display-will-swap from=\(from?.description ?? "nil") to=\(to.description) paneAlt=\(paneInAltScreen) before=\(describeScrollPosition(for: terminalBox.view))"
                )
                if let terminal = terminalBox.view?.getTerminal() {
                    // Width-mismatch repro: SwiftTerm's actual grid size at swap.
                    // Compare against `repaint-width clientCols`/`captureMaxCols`
                    // in the tmux log — a half-width gray box means one of these
                    // three disagrees.
                    DiagnosticLogStore.appendTmux(
                        "swap-terminal-size to=\(to.description) swiftTermCols=\(terminal.cols) swiftTermRows=\(terminal.rows)"
                    )
                }
                // A deepen rebinds the SAME window/pane under a new owner
                // epoch, so only a real identity change invalidates this
                // surface's credited depth. The in-flight latch survives
                // either way: the ledger still owes exactly one settle.
                let previousOwner = terminalBox.boundOwner
                inlineHistory.state.surfaceRebound(
                    .live,
                    identityChanged: previousOwner?.windowId != owner.windowId
                        || previousOwner?.paneId != owner.paneId
                )
                terminalBox.bind(
                    owner: owner,
                    restoringScrollbackLimit: appearance.scrollbackLines
                )
                recordScrollDiagnostic(
                    "tmux-display-will-swap-clear to=\(to.description) after=\(describeScrollPosition(for: terminalBox.view))"
                )
            }
            tmux.terminalIsInAltScreen = { [terminalBox] in
                terminalBox.view?.getTerminal().isCurrentBufferAlternate ?? false
            }
            tmux.displayDidSwap = { [terminalBox, findController] windowId in
                recordScrollDiagnostic(
                    "tmux-display-did-swap window=\(windowId.description) after=\(describeScrollPosition(for: terminalBox.view))"
                )
                if findController.isOpen {
                    findController.updateSearch()
                }
            }
            tmux.displayDidRefresh = { [findController] _ in
                if findController.isOpen {
                    findController.updateSearch()
                }
            }
            tmux.onBell = { windowID, isActiveWindow, windowName in
                guard !isActiveWindow else { return }
                let bc = bellController
                let sid = session.host.id
                let hname = session.host.name
                Task { @MainActor in
                    bc.ring(
                        source: .tmuxWindow(sessionID: sid, windowID: windowID),
                        isOriginOnScreen: false,
                        hostDisplayName: hname,
                        paneTitle: windowName
                    )
                }
            }
            tmux.onCommandError = { message in
                showPaneCommandError(message)
            }
            tmux.gridAuthorityIdentity = GridAuthorityDeviceIdentity.current()
            _ = session.sessionCommands(tmux: tmux).dispatch(
                .setTmuxGridPresentation(isPhone ? .singlePane : .paneGrid)
            )
            mirrorGridAuthorityInRegistry()
            registerGridAuthorityShowTarget()

            findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)

            // Resolve the per-host tmux session name once and stash
            // it in @State so the body and the onChange callbacks
            // share a consistent value (the helper does a SHA-256
            // hash on the fallback path, cheap but worth caching).
            //
            // R6.7: `.pinnedTmux` mode uses the user-supplied name when
            // it passes the shell-safety check; otherwise we fall back
            // to the SHA default rather than corrupting the shell
            // one-liner, since `AutoTmuxScript.command` does not escape.
            // `.customCommand` skips the whole resolution — no tmux
            // command is going to be sent.
            if resolvedTmuxSessionName == nil {
                resolvedTmuxSessionName = MoshBootstrap.resolvedTmuxSessionName(
                    for: session.host
                )
            }

            let agentSource = AgentSessionSourceFactory.make(
                sessionID: liveSessionID,
                hostName: session.host.name.isEmpty ? session.host.address : session.host.name,
                baseTransportLabel: "ssh",
                tmux: tmux,
                terminalBox: terminalBox,
                tmuxSessionName: { resolvedTmuxSessionName },
                profiles: { swipePadStore.profiles },
                rawProcessProvider: {
                    return await session.detectForegroundProcessSnapshotIfAvailable()
                },
                rawProcessProofProvider: { expectedPID in
                    await session.detectForegroundProcessSnapshotIfAvailable(expectedPID: expectedPID)
                },
                paneProcessProvider: { panePID, expectedPID in
                    await session.detectForegroundProcessSnapshotIfAvailable(rootPID: panePID, expectedPID: expectedPID)
                },
                bracketedPasteProvider: { location in
                    if let paneID = location.paneID,
                       let enabled = kittyPaneModes.bracketedPasteEnabled(for: PaneId(paneID)) {
                        return enabled
                    }
                    if let windowID = location.windowID {
                        return kittyWindowModes.bracketedPasteEnabled(for: WindowId(windowID))
                    }
                    return nil
                },
                lifecycleIntegrationCacheKey: session.host.sshConnectionRouteIdentity,
                automaticallyProbeLifecycleIntegration: true,
                probeLifecycleIntegration: {
                    try await RemoteAgentLifecycleIntegrationInstaller.probe(
                        execute: {
                            try await session.executeAgentIntegrationProbeCommand($0)
                        },
                        diagnostic: { detail in
                            DiagnosticLogStore.appendAgentCenter(
                                "host-diagnostic sid=\(liveSessionID.uuidString.prefix(8)) transport=ssh \(detail)"
                            )
                        }
                    )
                },
                installLifecycleIntegration: {
                    try await RemoteAgentLifecycleIntegrationInstaller.installNativeAndLifecycle {
                        try await session.executeAgentInstallationCommand($0)
                    }
                },
                probeShellIntegration: { processIDs, allowInheritedEnvironment in
                    do {
                        let output = try await session.executeAgentIntegrationProbeCommand(
                            RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                                processIDs: processIDs,
                                allowInheritedEnvironment: allowInheritedEnvironment
                            )
                        )
                        let parsed = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(
                            output
                        )
                        let shellDiagnostic = RemoteAgentLifecycleIntegrationInstaller
                            .parseShellDiagnostic(output)?
                            .replacingOccurrences(of: " ", with: ",") ?? "missing"
                        DiagnosticLogStore.appendAgentCenter(
                            "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=ssh processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=\(parsed.map(String.init) ?? "invalid-output") diagnostic=\(shellDiagnostic)"
                        )
                        return parsed
                    } catch {
                        DiagnosticLogStore.appendAgentCenter(
                            "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=ssh processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=transport-failed failureType=\(String(describing: type(of: error)))"
                        )
                        return nil
                    }
                },
                sessionCommands: session.sessionCommands(tmux: tmux),
                rawSend: { bytes in session.sessionCommands.sendInput(bytes) },
                projectorExecAvailability: { binding, isCurrent in
                    session.agentProjectorExecAvailability(
                        binding: binding,
                        isBindingCurrent: isCurrent
                    )
                }
            )
            agentSourceRegistrationID = agentSource.registrationID
            agentCenterV2.registerSessionSource(
                agentSource,
                hostID: session.host.id,
                hostDisplayLabel: session.host.name.isEmpty ? session.host.address : session.host.name,
                profiles: { swipePadStore.profiles }
            )
            let sourceRegistrationID = agentSource.registrationID
            tmux.paneOutputObserver = { paneID, data in
                agentCenterV2.noteOutput(
                    sessionID: liveSessionID,
                    paneID: paneID.rawValue,
                    registrationID: sourceRegistrationID,
                    data: data
                )
            }
            tmux.paneAgentStateObserver = { paneID, json in
                agentCenterV2.noteLifecyclePayload(
                    sessionID: liveSessionID,
                    paneID: paneID.rawValue,
                    registrationID: sourceRegistrationID,
                    json: json
                )
            }
            tmux.inputObserver = nil

            let sessionCommands = session.sessionCommands(tmux: tmux)
            let eventDiagnostics = SessionLatencyDiagnostics.queue(host: session.host.id, stage: "publication-to-terminal-consumer")
            terminalBox.bindLatencyDiagnostics(host: session.host.id)
            DiagnosticLogStore.appendSSH("latency-surface-v3 host=\(session.host.id.uuidString.prefix(8)) active=\(isActive) transport=ssh")
            let sessionEvents = sessionCommands.events(diagnostics: eventDiagnostics)
            sessionCommands.connect()
            let eventIterator = sessionEvents.mainActorDelivery(diagnostics: eventDiagnostics).makeAsyncIterator()
            while let event = await eventIterator.next() {
                switch event {
                case .stateChanged(_, let state):
                    sharedSessionState = state
                    if case .connecting = state {} else { sharedChallenge = nil }
                    continue
                case .tmuxSnapshotChanged(_, let snapshot):
                    sharedTmuxSnapshot = snapshot
                    continue
                case .gridAuthorityChanged:
                    // The controller's presentation is the only authority
                    // state the views read (S3′).
                    continue
                case .challenge(_, let challenge):
                    sharedChallenge = challenge
                    continue
                case .remoteWorkingDirectoryChanged(_, let path):
                    sharedRemoteWorkingDirectory = path
                    continue
                case .terminalBytes:
                    break
                case .forwardingStateChanged, .recoverableWarning, .failure,
                     .diagnostics, .commandCompleted, .destroyed:
                    continue
                }
                guard case .terminalBytes(_, let bytes, _) = event else { continue }
                let chunk = Array(bytes)
                // Launch-path forensics: while the overlay is still up and we
                // haven't reached control mode, record what the remote sent so
                // a stuck "starting tmux" can be diagnosed from a user's log.
                if launchOverlayVisible,
                   tmux.mode == .passthrough,
                   launchChunkTraceCount < 16 {
                    launchChunkTraceCount += 1
                    let n = launchChunkTraceCount
                    let shape = AutoTmuxLaunchDiagnostics.classify(
                        chunk: chunk,
                        launchCommand: lastAutoTmuxCommand
                    )
                    logLaunch(
                        "passthrough-chunk",
                        "n=\(n) bytes=\(chunk.count) sent=\(sentAutoTmuxCommand) sinceSendMs=\(sinceAutoTmuxSend) \(shape.logDescription)"
                    )
                }
                // Process the chunk FIRST so any DCS in it has already
                // flipped tmux.mode → .tmuxControl by the time we check.
                // This stops the auto-tmux failure scanner from racing
                // with a successful tmux launch when both the sentinel
                // *and* the DCS land in the same SSH chunk.
                if let startedAt = terminalBox.performanceDiagnostics.beginIngress(
                    byteCount: chunk.count
                ) {
                    if await tmux.ingestCooperatively(chunk) { eventIterator.consumerDidYield() }
                    terminalBox.performanceDiagnostics.endIngress(startedAt: startedAt)
                } else {
                    if await tmux.ingestCooperatively(chunk) { eventIterator.consumerDidYield() }
                }
                if tmux.mode == .passthrough, !chunk.isEmpty {
                    agentCenterV2.noteOutput(
                        sessionID: liveSessionID,
                        paneID: nil,
                        registrationID: sourceRegistrationID,
                        data: chunk[...]
                    )
                }

                // Auto-tmux failure detection: the shell snippet we
                // sent over stdin prints AutoTmuxScript's sentinel
                // bytes when `tmux` isn't on the remote host's PATH.
                // Gated on:
                //   - banner not already shown (idempotent)
                //   - the host opted into auto-tmux
                //   - we're STILL in passthrough mode (tmux didn't
                //     just take over via DCS in this same chunk)
                // The last gate is what makes the happy path quiet:
                // a successful auto-tmux command both echoes the
                // command (octal-escaped sentinel that doesn't match
                // the needle anyway) and flips us to tmuxControl, so
                // by the time we check, the scanner is disabled.
                // R6.8: only scan for the sentinel when we actually
                // sent an auto-tmux command. `.customCommand` mode
                // replaces the one-liner entirely, so the sentinel
                // can't legitimately appear.
                if !noTmuxBannerVisible
                    && sentAutoTmuxCommand
                    && session.host.launchMode != .customCommand
                    && tmux.mode == .passthrough,
                   let failure = noTmuxScanner.feedForFailure(chunk)
                {
                    switch failure {
                    case .unavailable:
                        // Only "tmux is not installed" is a durable fact about
                        // the host. A failed server start is usually transient
                        // (bad config, full disk) and must not poison the
                        // host list's tmux badge.
                        HostRuntimeStateStore.recordTmuxUnavailable(for: session.host)
                        degradeTmuxLaunchToPlainShell(reason: .unavailable)
                    case .startFailed:
                        degradeTmuxLaunchToPlainShell(reason: .startFailed)
                    case .nested:
                        degradeTmuxLaunchToPlainShell(reason: .nested)
                    }
                }
            }
        }
        .onChange(of: sharedSessionState) { _, sharedState in
            let newState = legacySessionState(from: sharedState)
            if newState == .connected {
                consumePendingPathInjection()
            }
            logLaunch(
                "state-change",
                // `newState.diagnosticName`, never `String(describing:)` — see
                // `SessionState.diagnosticName` for what the payload leaks.
                "to=\(newState.diagnosticName) mode=\(session.host.launchMode.rawValue) sent=\(sentAutoTmuxCommand) tmuxMode=\(String(describing: tmux.mode)) overlay=\(launchOverlayVisible)"
            )
            // Clean disconnect (e.g. Ctrl+D) returns to the host list
            // without an error banner. .failed stays put so the user
            // can read the reason before tapping back.
            if newState != .connected {
                // A lost transport clears every inline history record: the
                // ledger's surfaces go with it, and a reconnect re-credits
                // depth from its own first `.deep` fill.
                inlineHistory.resetRecords()
            }
            if newState == .disconnected {
                preservePendingPathAfterConnectionFailure()
                tmuxLaunchWatchdog?.cancel()
                tmuxLaunchWatchdog = nil
                tmuxHydrationWatchdog?.cancel()
                tmuxHydrationWatchdog = nil
                launchOverlayVisible = false
                tmux.suppressPassthroughOutputUntilControlMode = false
                noTmuxScanner.reset()
                onSessionEnded()
            }
            if case .failed = newState {
                preservePendingPathAfterConnectionFailure()
                tmuxLaunchWatchdog?.cancel()
                tmuxLaunchWatchdog = nil
                tmuxHydrationWatchdog?.cancel()
                tmuxHydrationWatchdog = nil
                // Keep the launch overlay UP to host the error state +
                // recovery actions (edit host / retry / back), rather than
                // dismissing to a dead shell with a red top-bar string.
                tmux.suppressPassthroughOutputUntilControlMode = false
                noTmuxScanner.reset()
            }

            // First time we hit `.connected`, dispatch on launchMode:
            //   - `.autoTmux` / `.pinnedTmux`: build and send the
            //     auto-tmux shell snippet with the resolved session name.
            //   - `.customCommand`: send the user's command verbatim
            //     (adding a trailing newline if missing) and skip the
            //     tmux path.
            // Plain SSH (`.customCommand`) is ready as soon as the
            // handshake completes — drop the overlay here so the
            // terminal can fade in. Tmux modes wait on `tmux.isInitialRenderReady`
            // (handled further down in `.onChange(of: tmux.isInitialRenderReady)`).
            if case .connected = newState, session.host.launchMode == .customCommand {
                launchOverlayVisible = false
            }

            if case .connected = newState { sendConfiguredLaunchIfNeeded() }
        }
    }

    /// Keep the PTY-generation observer behind its own opaque result boundary.
    /// `sessionDecoratedLifecycle` is already a very large modifier graph and
    /// adding this observer directly makes Swift's type checker solve the full
    /// connection + lifecycle chain as one expression.
    private var sessionDecoratedPTYRecovery: some View {
        sessionDecoratedConnection
        .onChange(of: session.interactivePTYGeneration) { oldGeneration, newGeneration in
            guard newGeneration > oldGeneration else { return }
            relaunchAfterInlineTmuxPTYRecovery(generation: newGeneration)
        }
    }

    /// Keep render-preference propagation outside the large lifecycle modifier
    /// graph. Besides giving the ledger its real scrollback cap before a bind,
    /// this is a needed opaque type-checker boundary for this view.
    private var sessionDecoratedRenderPreferences: some View {
        sessionDecoratedPTYRecovery
        .task(id: liveSessionID) {
            renderDropSummary.register(terminalBox)
            tmux.renderDropSummaryBoundary = { [renderDropSummary] boundary in
                renderDropSummary.record(boundary: boundary)
            }
            defer {
                renderDropSummary.record(boundary: "view-disappear")
                renderDropSummary.unregister(terminalBox)
                tmux.renderDropSummaryBoundary = nil
            }
            await renderDropSummary.runPeriodic()
        }
        .onChange(of: appearance.scrollbackLines) { _, lines in
            // The inline ledger owns grid/single surface binding. Keep its
            // rebuild cap synchronized with the app preference instead of
            // letting a later grid capture silently use the default limit.
            tmux.submitRenderFact(.scrollbackLimit(lines: lines))
        }
    }

    /// Grid-authority edges for input: a split of the chain below, which
    /// is otherwise past the type-checker's budget.
    private var sessionAuthorityInput: some View {
        sessionDecoratedRenderPreferences
        .onChange(of: tmux.gridAuthority) { _, _ in
            mirrorGridAuthorityInRegistry()
            // A path held through a resume that found a peer goes to the clipboard.
            consumePendingPathInjection()
        }
        .onChange(of: tmux.gridAuthorityPresentation) { _, _ in
            // A cancelled take-back changes neither the peer nor the input
            // gate, only why typing waits: a held path goes to the clipboard.
            consumePendingPathInjection()
        }
        .onChange(of: tmux.gridAuthorityAllowsInput) { _, allows in
            if allows {
                consumePendingPathInjection()
            } else {
                // Typing the gate now drops at apply time already sits in the
                // UIKit input mirror; later edits must not delete it remotely.
                terminalBox.noteOutOfBandInput()
            }
        }
    }

    private var sessionDecoratedLifecycle: some View {
        sessionAuthorityInput
        .onChange(of: sharedChallenge != nil) { _, presented in
            // A password/OTP prompt is the user's step in progress: the
            // pending show or tap must not expire under it (R3).
            showEdges?.setChallengePresented(presented, for: liveSessionID)
        }
        .onDisappear {
            showEdges?.unregister(tmux, for: liveSessionID)
        }
        .onChange(of: isPhone) { _, compact in
            _ = session.sessionCommands(tmux: tmux).dispatch(
                .setTmuxGridPresentation(compact ? .singlePane : .paneGrid)
            )
        }
        .onChange(of: isActive) { _, nowActive in
            DiagnosticLogStore.appendSSH("latency-surface-v3 host=\(session.host.id.uuidString.prefix(8)) active=\(nowActive) transport=ssh")
            swipePadSessionIsActive = nowActive
            updateSwipePadAgentFocus()
            if !nowActive {
                agentScrollNotice.dismiss()
                terminalBox.dismissTransientInteractions()
                filesPanel.close()
            } else {
                reconcileAgentScrollNotice()
            }
            // Visibility first: an active edge starts the controller's
            // authority re-read, which then decides what the replayed size
            // may do (M6). Sizing before it would stamp and fence `latest`
            // from a device that has not looked yet.
            if nowActive {
                if appPhase.isActive {
                    _ = session.sessionCommands(tmux: tmux).dispatch(
                        .setApplicationVisibility(.active)
                    )
                } else {
                    _ = session.sessionCommands(tmux: tmux).dispatch(
                        .setApplicationVisibility(.background)
                    )
                }
            }
            // When this session becomes the selected tab, replay the last known
            // terminal size so the remote gets an accurate SIGWINCH. The size
            // may have changed while we were hidden (sidebar toggle, rotation).
            if nowActive {
                if isPhone, let viewport = lastCompactViewportSize {
                    pushCompactInlineViewport(viewport, force: true)
                } else if let size = lastTerminalSize {
                    session.sessionCommands(tmux: tmux).resize(
                        columns: size.cols,
                        rows: size.rows
                    )
                }
            }
            // Returning to a session whose open panel lost its bridge
            // (idle teardown or drop while backgrounded): reconnect and
            // refresh the listing — the panel being open is standing
            // user intent, not a new connection decision.
            if nowActive, filesPanel.isOpen,
               let bridge = filesPanel.bridge,
               bridge.state != .connected, bridge.state != .connecting {
                filesPanel.open()
            }
        }
        .task(id: sshCwdPollKey) {
            await runSSHCwdPoll()
        }
        .onChange(of: session.pendingPathInjection) { _, _ in
            consumePendingPathInjection()
        }
        .onChange(of: appPhase.isActive) { _, nowForeground in
            // App background→foreground is a SEPARATE signal from `isActive`
            // (which is just "selected tab"). SwiftUI's `\.scenePhase` doesn't
            // reliably reach this nested view, but `AppPhase.isActive` — set
            // from the app-root scenePhase observer — does. On resume nothing
            // else re-renders the visible window, so stale content left on the
            // shared terminal (the cross-window gray-box bleed) persists until
            // the user interacts. Mark the app active first (a fresh
            // capture-repaint that clears (ED 2) and repaints from tmux's
            // grid, plus the authority re-read), then replay the size: the
            // read decides whether that size may reach tmux, so it must be in
            // flight before the replay (M6). The viewport retry/backoff rides
            // out the empty-metadata window while the control channel
            // recovers. Close the output gate at the inactive edge too: SSH
            // can resume and deliver queued TUI redraws during the
            // inactive→active transition, before this capture starts.
            guard isActive else { return }
            guard nowForeground else {
                terminalBox.dismissTransientInteractions()
                _ = session.sessionCommands(tmux: tmux).dispatch(
                    .setApplicationVisibility(.background)
                )
                return
            }
            _ = session.sessionCommands(tmux: tmux).dispatch(
                .setApplicationVisibility(.active)
            )
            if isPhone, let viewport = lastCompactViewportSize {
                pushCompactInlineViewport(viewport, force: true)
            } else if let size = lastTerminalSize {
                session.sessionCommands(tmux: tmux).resize(
                    columns: size.cols,
                    rows: size.rows
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tesseraForceRefreshTerminal)) { _ in
            forceRefreshTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            terminalBox.dismissTransientInteractionsIfInterfaceOrientationChanged()
        }
        .onChange(of: tmux.mode) { _, newMode in
            recordScrollDiagnostic(
                "tmux-mode-changed mode=\(newMode) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            // Control mode can finish attaching after the app has already
            // become inactive. Re-arm the controller here as well as on the
            // app-phase edge so its first `%output` cannot race the foreground
            // viewport repair.
            if case .tmuxControl = newMode, !appPhase.isActive {
                _ = session.sessionCommands(tmux: tmux).dispatch(
                    .setApplicationVisibility(.background)
                )
            }
            if case .tmuxControl = newMode,
               isPhone,
               isActive,
               appPhase.isActive,
               let viewport = lastCompactViewportSize {
                pushCompactInlineViewport(viewport, force: true)
            }
            // Successful control mode supersedes a prior "tmux unavailable"
            // discovery. Auto mode also remembers the resolved rendezvous name.
            if case .tmuxControl = newMode {
                // The handshake landed — disarm the watchdog and retract a
                // banner a slow launch may already have raised. Logged so a
                // report can separate "the DCS never arrived" from "the DCS
                // arrived and hydration stalled afterwards".
                logLaunch(
                    "control-mode",
                    "sinceSendMs=\(sinceAutoTmuxSend) chunks=\(launchChunkTraceCount) overlay=\(launchOverlayVisible)"
                )
                tmuxLaunchWatchdog?.cancel()
                tmuxLaunchWatchdog = nil
                // The DCS is not the finish line: hand the wait over to the
                // hydration watchdog so a stalled attach cannot strand the
                // overlay in the gap the launch watchdog just vacated.
                armTmuxHydrationWatchdog()
                if noTmuxBannerVisible, noTmuxBannerReason != .unavailable {
                    noTmuxBannerVisible = false
                }
                if session.host.launchMode == .autoTmux,
                   let name = resolvedTmuxSessionName {
                    HostRuntimeStateStore.recordSessionUsed(name, for: session.host)
                } else {
                    HostRuntimeStateStore.recordTmuxAvailable(for: session.host)
                }
            }
        }
        .onChange(of: tmux.isInitialRenderReady) { _, isReady in
            #if DEBUG
            LiveScrollInitialRenderProbe.observe(
                sessionID: liveSessionID,
                isReady: isReady
            )
            #endif
            recordScrollDiagnostic(
                "tmux-initial-render-ready ready=\(isReady) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            if isReady {
                logLaunch(
                    "ready",
                    "sinceSendMs=\(sinceAutoTmuxSend) chunks=\(launchChunkTraceCount)"
                )
                tmuxHydrationWatchdog?.cancel()
                tmuxHydrationWatchdog = nil
                launchOverlayVisible = false
                noTmuxScanner.reset()
                // A late render (the user's keystroke woke the latch) makes
                // the hydration banner stale — retract it.
                if noTmuxBannerVisible, noTmuxBannerReason == .hydrationStalled {
                    noTmuxBannerVisible = false
                }
            }
        }
        .onChange(of: scrollDiagnosticsEnabled) { _, enabled in
            if enabled {
                recordScrollDiagnostic(
                    "scroll-diagnostics-enabled position=\(describeScrollPosition(for: terminalBox.view))"
                )
            }
        }
        .onChange(of: launchOverlayVisible) { _, visible in
            // The sidebar row can't observe this view's local overlay
            // state, so mirror "launch complete" into the shared registry
            // the moment the shield drops. Until then the row holds itself
            // in the connecting state (amber, pulsing) even though the
            // transport already reports `.connected`. Stays false for the
            // session's lifetime (the overlay never re-shows in place).
            if !visible {
                sessionRegistry.markRenderReady(liveSessionID)
            }
        }
        .onChange(of: tmux.lastPublishedClientSize) { _, _ in
            guard isPhone, isActive, appPhase.isActive,
                  let viewport = lastCompactViewportSize
            else { return }
            reprojectCompactInlineLayout(viewport)
        }
        .onChange(of: compactTmuxSizingKey) { _, _ in
            guard isPhone,
                  isActive,
                  appPhase.isActive,
                  let viewport = lastCompactViewportSize
            else { return }
            reprojectCompactInlineLayout(viewport)
        }
        .onChange(of: tmux.activePaneId) { _, newPaneId in
            updateSwipePadAgentFocus()
            reconcileAgentScrollNotice()
            // Magic-puck pane-awareness. The SwipePad resolver scopes its
            // `pane_current_command`/`pane_pid` query to `tmux.activePaneId`,
            // but it only re-runs on terminal output or the 1–5 s background
            // poll. A pane focus change (⌘[/⌘], tap-to-focus, or a `select-pane`
            // echo) can carry no new output, so without this the puck keeps
            // showing the previously-focused pane's process-adaptive shortcuts.
            // Bump the activity token directly (not the debounced output
            // refresh) so the re-poll fires immediately even during the output
            // cooldown window. `activePaneId` is already the new pane when this
            // fires, so the next resolver query is correctly scoped.
            //
            // Only re-poll when focus lands on a REAL pane. `activePaneId` also
            // transitions to nil on teardown / reset / a window invalidated
            // mid-hydration; bumping there fires a wasted client-scoped query
            // (or a send against a torn-down channel) and can burst during the
            // nil↔value reconnect dance — there is no pane to scope to, so skip.
            guard swipePadSessionIsActive, newPaneId != nil else { return }
            swipePadOutputActivityToken &+= 1
            SwipePadDiagnostics.log(
                "output-activity session=ssh reason='pane-focus' token=\(swipePadOutputActivityToken)"
            )
        }
        .onChange(of: agentCenterV2.presentation.listSnapshot) { _, _ in
            reconcileAgentScrollNotice()
        }
    }

    var body: some View {
        sessionDecoratedLifecycle
            .environment(\.terminalInputAllowed, authorityGatedTerminalInputAllowed)
            .environment(\.terminalKeyboardHandoff, commandPalette.keyboardHandoff)
            // P9: nothing under the veil draws once it has faded in
            // (output is still consumed).
            .modifier(ContinuedElsewhereDrawingGate(veiled: veilIsDrawn))
    }

    /// The inherited lock gate plus the grid-authority gate: no keyboard
    /// focus is (re)claimed while authority is resolving, yielded or being
    /// taken back. Evaluated live, O(1), on every check.
    private var authorityGatedTerminalInputAllowed: () -> Bool {
        let inherited = inheritedTerminalInputAllowed
        return { [tmux] in inherited() && tmux.gridAuthorityAllowsInput }
    }

    /// Dispatch a tmux keyboard shortcut to a control command. Shared by the
    /// single-pane terminal and every pane surface in the grid (so chords work
    /// whichever pane is focused). Silent no-op in passthrough mode (the
    /// controller gates internally).
    private func handleTmuxShortcut(_ shortcut: TesseraTmuxShortcut) {
        appLockController.notifyUserActivity()
        let commands = session.sessionCommands(tmux: tmux)
        switch shortcut {
        case .newWindow:
            _ = commands.dispatch(.createTmuxWindow)
        case .killCurrentWindow:
            // Contextual: kill the focused PANE when the window is split,
            // else kill the whole window (the shipped ⌘⇧W behavior).
            if (activeWindow?.paneCount ?? 1) > 1, let paneID = tmux.activePaneId {
                _ = commands.dispatch(.closeTmuxPane(paneID.description))
            } else if let windowID = tmux.activeWindowId {
                _ = commands.dispatch(.closeTmuxWindow(windowID.description))
            }
        case .previousWindow:
            guard let windowID = tmux.snapshot.adjacentWindowID(offset: -1) else { return }
            _ = commands.dispatch(.selectTmuxWindow(windowID.description))
        case .nextWindow:
            guard let windowID = tmux.snapshot.adjacentWindowID(offset: 1) else { return }
            _ = commands.dispatch(.selectTmuxWindow(windowID.description))
        case .moveWindowLeft, .moveWindowRight:
            guard let windowID = tmux.activeWindowId else { return }
            _ = commands.dispatch(.moveTmuxWindow(windowID.description, move: .relative(
                { if case .moveWindowLeft = shortcut { return .previous }; return .next }()
            )))
        case .selectWindow(let position):
            let windowID = position == 9
                ? tmux.snapshot.windows.last?.id
                : tmux.snapshot.windowID(atPosition: position)
            guard let windowID else { return }
            _ = commands.dispatch(.selectTmuxWindow(windowID.description))
        case .splitPaneHorizontal:
            if let paneID = tmux.activePaneId {
                _ = commands.dispatch(.splitTmuxPane(paneID.description, axis: .horizontal, before: false))
            }
        case .splitPaneVertical:
            if let paneID = tmux.activePaneId {
                _ = commands.dispatch(.splitTmuxPane(paneID.description, axis: .vertical, before: false))
            }
        case .cyclePaneNext:
            _ = commands.dispatch(.cycleTmuxPane(forward: true))
        case .cyclePanePrevious:
            _ = commands.dispatch(.cycleTmuxPane(forward: false))
        case .zoomPane:
            if let paneID = tmux.activePaneId, let activeWindow {
                _ = commands.dispatch(.setTmuxPaneZoomed(
                    paneID.description,
                    zoomed: !activeWindow.isZoomed
                ))
            }
        }
    }

    /// Show a transient toast for a failed pane operation (tmux `%error`,
    /// e.g. "create pane failed: pane too small"). Auto-dismisses after 2.5 s.
    private func showPaneCommandError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paneCommandToastTask?.cancel()
        paneCommandToast = trimmed
        paneCommandToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            paneCommandToast = nil
            paneCommandToastTask = nil
        }
    }

    /// Translate the SwiftTerm container's switcher-shortcut events into
    /// palette and MRU-cycle controller calls. The actual selection
    /// change goes back to `ContentView` via `onSelectSession`.
    private func handleSwitcherShortcut(_ shortcut: TesseraSwitcherShortcut) {
        switch shortcut {
        case .openPalette:
            commandPalette.open(
                sessions: sessionRegistry.activeSessions,
                lastTouched: sessionRegistry.lastTouched
            )
        case .cyclePrevious, .cycleNext:
            // Immediate switch to the neighbouring session in sidebar
            // order, wrapping at both ends. No HUD or settle timer — the
            // terminal content changing is the feedback, and this reuses
            // the same `onSelectSession` path the palette commits through.
            let direction: SessionSwitchDirection =
                shortcut == .cyclePrevious ? .previous : .next
            if let target = SessionSwitcher.step(
                order: sessionRegistry.activeSessions.map(\.id),
                from: liveSessionID,
                direction: direction
            ) {
                onSelectSession(target)
            }
        }
    }

    private var activeAgentScrollPaneID: Int? {
        tmux.mode == .tmuxControl ? tmux.activePaneId?.rawValue : nil
    }

    private func agentScrollPrevention(paneID: Int?) -> AgentScrollPrevention? {
        agentCenterV2.scrollPrevention(
            sessionID: liveSessionID,
            paneID: paneID,
            claudeCodeEnabled: appearance.agentScrollLockClaudeCodeEnabled,
            codexEnabled: appearance.agentScrollLockCodexEnabled
        )
    }

    private func presentAgentScrollPrevention(paneID: Int?) {
        guard isActive, let prevention = agentScrollPrevention(paneID: paneID) else {
            return
        }
        appLockController.notifyUserActivity()
        agentScrollNotice.show(prevention)
        let paneLabel = paneID.map(String.init) ?? "raw"
        let provider = prevention.agentName == "Codex" ? "codex" : "claude"
        DiagnosticLogStore.appendAgentCenter(
            "scroll-blocked sid=\(String(liveSessionID.uuidString.prefix(8))) pane=\(paneLabel) provider=\(provider)"
        )
    }

    private func reconcileAgentScrollNotice() {
        guard let shown = agentScrollNotice.prevention else { return }
        let current = agentScrollPrevention(paneID: shown.agentID.paneID)
        if current != shown || !isActive || !agentScrollSurfaceIsVisible(shown.agentID) {
            agentScrollNotice.dismiss()
        }
    }

    private func agentScrollSurfaceIsVisible(_ id: AgentInstanceID) -> Bool {
        guard id.sessionID == liveSessionID else { return false }
        guard tmux.mode == .tmuxControl else { return id.paneID == nil }
        if let window = activeGridWindow {
            return window.panes.contains { $0.id.rawValue == id.paneID }
        }
        return id.paneID == tmux.activePaneId?.rawValue
    }

    /// Report the terminal surface the user is looking at to Agent Center's
    /// SwipePad projection: the focused tmux pane, or a nil pane for a raw
    /// screen. Equality-gated on the other side, so calling on every focus
    /// signal is free.
    private func updateSwipePadAgentFocus() {
        guard isActive else {
            agentCenterV2.clearSwipePadFocus(sessionID: liveSessionID)
            return
        }
        if tmux.mode == .tmuxControl {
            if let paneID = tmux.activePaneId {
                agentCenterV2.setSwipePadFocus(sessionID: liveSessionID, paneID: paneID.rawValue)
            } else {
                // No active pane (window teardown / mid-hydration): clear
                // rather than keep the departed pane's focus — a stale
                // fireable snapshot could route a macro into whatever pane
                // tmux has foreground, and mosh sends have no pane guard.
                agentCenterV2.clearSwipePadFocus(sessionID: liveSessionID)
            }
        } else {
            agentCenterV2.setSwipePadFocus(sessionID: liveSessionID, paneID: nil)
        }
    }

    private func scheduleSwipePadOutputActivityRefresh(reason: String) {
        guard swipePadSessionIsActive else { return }
        guard swipePadOutputActivityTask == nil else { return }

        swipePadOutputActivityTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            swipePadOutputActivityToken &+= 1
            SwipePadDiagnostics.log(
                "output-activity session=ssh reason='\(reason)' token=\(swipePadOutputActivityToken)"
            )

            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            swipePadOutputActivityTask = nil
        }
    }

    // MARK: - Inline (SSH+tmux) history ladder

    /// The inline render ledger is running for this session at all: tmux
    /// control mode over the SSH channel itself, on a live transport.
    private var inlineHistoryLadderIsActive: Bool {
        tmux.mode == .tmuxControl
            && tmux.controlPath == .inline
            && presentationSessionState == .connected
    }

    /// A grid pane is a render-ledger surface in its own right; the spelling
    /// has to match `TmuxController.inlinePaneSurfaceID` exactly or every
    /// fact would address a surface that does not exist.
    private static func inlinePaneSurfaceID(_ paneID: PaneId) -> SurfaceId {
        InlineTmuxHistoryRequestStore.paneSurfaceID(paneID)
    }

    /// The `TerminalBox` painting an inline surface, or nil when this view
    /// does not own one for it.
    private func inlineHistoryBox(for surfaceID: SurfaceId) -> TerminalBox? {
        if surfaceID == .live {
            // The shared surface is declared only while no grid is mounted.
            return activeGridWindow == nil ? terminalBox : nil
        }
        guard activeGridWindow != nil else { return nil }
        return inlineHistory.paneBox(for: surfaceID)
    }

    /// Committed moves on an inline surface: output, and the write at the end
    /// of a wheel/trackpad delta.
    ///
    /// Only a move that lands while a finger is down or a glide runs counts.
    /// The custom trackpad/wheel recognizer reports direction itself and goes
    /// through `onPrimaryScrollbackUnderflow`; UIScrollView's own finger frames
    /// go through `handleInlineNativeScrollFrame`.
    private func handleInlineTerminalScrolled(
        surfaceID: SurfaceId,
        view: TerminalView
    ) {
        guard inlineHistoryBox(for: surfaceID)?.view === view else { return }
        let offsetY = view.contentOffset.y
        let previousOffsetY = inlineHistory.lastScrollOffsetY(for: surfaceID)
        inlineHistory.setLastScrollOffsetY(offsetY, for: surfaceID)
        // Half a point of slop: a programmatic placement and a rebind's
        // trivial tail both report `scrolled` without a reader moving.
        guard offsetY < previousOffsetY - 0.5 else { return }
        // Only a live gesture is a history request. A shorter replacement
        // page, a trim, or a placement write also moves the offset upward,
        // and none of those is a reader asking for more.
        guard view.isTracking || view.isDragging || view.isDecelerating else { return }
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        noteInlineTmuxScrollUp(
            surfaceID: surfaceID,
            view: view,
            proposedOffsetY: offsetY,
            maxOffsetY: maxOffsetY,
            pointsY: Double(previousOffsetY - offsetY),
            isInertial: view.isDecelerating
        )
    }

    /// A reader's finger frame on an inline surface: UIScrollView's pan or the
    /// deceleration after it.
    ///
    /// SwiftTerm never reports these through `scrolled`, so before this hook a
    /// touch reader stopped at the attach capture's depth while the trackpad
    /// deepened. The frame carries its own previous offset, so a slow drag of
    /// less than a point per frame still reads as upward. With bounces on, a
    /// pull past the oldest row reports a negative offset: the crossing.
    private func handleInlineNativeScrollFrame(
        surfaceID: SurfaceId,
        view: TerminalView,
        previousOffsetY: CGFloat
    ) {
        guard inlineHistoryBox(for: surfaceID)?.view === view else { return }
        let offsetY = view.contentOffset.y
        inlineHistory.setLastScrollOffsetY(offsetY, for: surfaceID)
        guard offsetY < previousOffsetY else { return }
        noteInlineTmuxScrollUp(
            surfaceID: surfaceID,
            view: view,
            proposedOffsetY: offsetY,
            maxOffsetY: max(0, view.contentSize.height - view.bounds.height),
            pointsY: Double(previousOffsetY - offsetY),
            isInertial: view.isDecelerating
        )
    }

    /// One scroll-up frame on an inline surface (`.live`, or a grid pane).
    ///
    /// The only gesture rule is `TmuxInlineHistoryGate.shouldRequest`, which
    /// iOS and Android both evaluate with the same three geometry facts.
    /// Depth, exhaustion and single-flight capture stay in the ledger.
    private func noteInlineTmuxScrollUp(
        surfaceID: SurfaceId,
        view: TerminalView,
        proposedOffsetY: CGFloat,
        maxOffsetY: CGFloat,
        pointsY: Double,
        isInertial: Bool
    ) {
        guard inlineHistoryLadderIsActive,
              let box = inlineHistoryBox(for: surfaceID),
              box.view === view,
              // The ledger answers a request on an unowned surface with a
              // diagnostic, not a settle. Latching one here would strand the
              // gate forever, so never ask before this surface has an owner.
              box.boundOwner != nil,
              // A bind's clear empties the buffer and reports a trivial tail.
              // That is not a reader approaching the oldest row.
              !box.isRebinding,
              !box.isAwaitingContentAfterRebind
        else { return }
        let terminal = view.getTerminal()
        // The alternate screen has no local scrollback to deepen; those
        // gestures belong to the remote TUI.
        guard !terminal.isCurrentBufferAlternate else { return }

        let record = inlineHistory.state[surfaceID]
        let rowHeight = max(1, TerminalCellMetrics.cellSize(for: view).height)
        let clampedMaxOffsetY = max(0, maxOffsetY)
        let offsetY = min(max(0, view.contentOffset.y), clampedMaxOffsetY)
        let rowsAboveOldest = Int((offsetY / rowHeight).rounded(.down))
        guard TmuxInlineHistoryGate.shouldRequest(
            canDeepen: record.canDeepen,
            requestInFlight: record.requestInFlight,
            rowsAboveOldest: rowsAboveOldest,
            viewportRows: terminal.rows,
            crossedOldestRow: proposedOffsetY < 0
        ) else { return }

        inlineHistory.state.requestSubmitted(
            surfaceID,
            offsetY: offsetY,
            maxOffsetY: clampedMaxOffsetY
        )
        tmux.submitRenderFact(.scrollbackRequested(
            surfaceID,
            pointsY: pointsY,
            isInertial: isInertial
        ))
        recordScrollDiagnostic(
            "render-ledger inline-history-request surface=\(surfaceID.description) rowsAbove=\(rowsAboveOldest) viewportRows=\(terminal.rows) crossed=\(proposedOffsetY < 0) off=\(Self.format(offsetY))/\(Self.format(clampedMaxOffsetY))"
        )
    }

    /// Opening find (or typing a new query) must search the whole pane, not
    /// only the depth the attach fill happened to capture. Find is scoped to
    /// the focused surface, so that is the one deepened.
    private func requestInlineFindHistory(reason: String) {
        guard inlineHistoryLadderIsActive,
              findController.isOpen,
              session.host.launchMode != .customCommand
        else { return }
        let surfaceID: SurfaceId
        if activeGridWindow != nil {
            guard let paneID = tmux.activePaneId else { return }
            surfaceID = Self.inlinePaneSurfaceID(paneID)
        } else {
            surfaceID = .live
        }
        guard let box = inlineHistoryBox(for: surfaceID),
              // Same rule as the scroll gate: an unowned surface gets a
              // diagnostic instead of a settle, so it must not be latched.
              box.boundOwner != nil
        else { return }
        let record = inlineHistory.state[surfaceID]
        guard record.canDeepen, !record.requestInFlight else { return }

        let view = box.view
        let maxOffsetY = view.map { max(0, $0.contentSize.height - $0.bounds.height) } ?? 0
        let offsetY = view.map { min(max(0, $0.contentOffset.y), maxOffsetY) } ?? 0
        inlineHistory.state.requestSubmitted(
            surfaceID,
            offsetY: offsetY,
            maxOffsetY: maxOffsetY
        )
        tmux.submitRenderFact(.findOpened(surfaceID))
        recordScrollDiagnostic(
            "render-ledger inline-find-request reason=\(reason) surface=\(surfaceID.description)"
        )
    }

    /// One `inlineHistorySettled`. Updates the record, and — when it answers a
    /// gesture — puts the reader back where it was before the deepen's rebind
    /// cleared the local transcript.
    private func applyInlineHistorySettled(
        surfaceID: SurfaceId,
        owner: RenderOwner,
        depth: Int,
        historySize: Int,
        canDeepen: Bool
    ) {
        let settlement = inlineHistory.state.settled(
            surfaceID,
            depth: depth,
            historySize: historySize,
            canDeepen: canDeepen
        )
        recordScrollDiagnostic(
            "render-ledger inline-history-settled surface=\(surfaceID.description) depth=\(depth) size=\(historySize) canDeepen=\(canDeepen) requested=\(settlement.answeredRequest)"
        )
        MoshDiagnostics.log(
            "render-ledger inline-history-settled surface=\(surfaceID.description) depth=\(depth) size=\(historySize) canDeepen=\(canDeepen)"
        )
        // A settle with no pending gesture only updates the record; the reader
        // never moved, so neither should the view.
        guard settlement.answeredRequest else { return }
        guard let box = inlineHistoryBox(for: surfaceID),
              let terminalOwner = Self.inlineRenderOwner(owner),
              box.boundOwner == terminalOwner
        else { return }

        // The bind that preceded the deep feed already emptied the buffer, so
        // the box's pre-clear snapshot — not the view — is the authority on
        // the reader's distance from the tail. The recorded anchor covers the
        // ignored/exhausted settle, where no rebind happened at all.
        let reboundSnapshot = box.takeScrollPositionBeforeRebind(for: terminalOwner)
        // The surface moved to another window/pane while the request was in
        // flight: this settle describes that pane, and both the snapshot
        // (taken at its bind) and the anchor measure the old transcript. The
        // reader stays on the new pane's tail, as after any window switch.
        guard settlement.placesReader else {
            recordScrollDiagnostic(
                "render-ledger inline-history-placement-dropped surface=\(surfaceID.description) reason=identity-changed"
            )
            return
        }
        let anchor = reboundSnapshot.map {
            InlineTmuxHistoryRequestState.ScrollAnchor(
                offsetY: $0.offsetY,
                maxOffsetY: $0.maxOffsetY
            )
        } ?? settlement.anchor
        guard let anchor else { return }
        placeInlineHistoryReader(
            surfaceID: surfaceID,
            owner: terminalOwner,
            anchor: anchor,
            awaitsGrowth: reboundSnapshot != nil,
            attemptsRemaining: 8
        )
    }

    /// `TmuxControlCore.RenderOwner` → the surface boundary's owner. Mirrors
    /// `MoshRenderLedgerSurfaceAdapter.terminalRenderOwner`.
    private static func inlineRenderOwner(_ owner: RenderOwner) -> TerminalRenderOwner? {
        guard let windowID = owner.windowID, let paneID = owner.paneID else { return nil }
        return TerminalRenderOwner(windowId: windowID, paneId: paneID, epoch: owner.epoch)
    }

    /// Restore the reader's distance from the tail once the deepened page has
    /// grown SwiftTerm's content.
    ///
    /// The feed is synchronous but its content size lands on a later layout
    /// pass, so the placement is re-applied until the transcript is actually
    /// longer than it was — or the reader takes over with a gesture.
    private func placeInlineHistoryReader(
        surfaceID: SurfaceId,
        owner: TerminalRenderOwner,
        anchor: InlineTmuxHistoryRequestState.ScrollAnchor,
        awaitsGrowth: Bool,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.async {
            guard let box = inlineHistoryBox(for: surfaceID) else { return }
            // The box is shared across owners. A window switch or a later
            // deepen that rebinds it while this placement is still converging
            // makes the anchor meaningless, so the placement fails closed
            // rather than scrolling whatever pane the box now shows — the
            // same check the mosh presentation path repeats on every retry.
            guard box.boundOwner == owner else {
                recordScrollDiagnostic(
                    "render-ledger inline-history-placement-dropped surface=\(surfaceID.description) reason=owner-changed"
                )
                return
            }
            guard let view = box.view,
                  box.isReadyForOwnedPresentation,
                  !box.isAwaitingContentAfterRebind
            else {
                retryInlineHistoryPlacement(
                    surfaceID: surfaceID,
                    owner: owner,
                    anchor: anchor,
                    awaitsGrowth: awaitsGrowth,
                    attemptsRemaining: attemptsRemaining - 1
                )
                return
            }
            let newMaxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            let targetY = anchor.restoredOffsetY(newMaxOffsetY: newMaxOffsetY)
            // A replacement page arrives with the view sitting on the cleared
            // buffer's trivial tail; a live glide over that must not fight
            // the write.
            if view.isDragging || view.isDecelerating {
                view.setContentOffset(view.contentOffset, animated: false)
            }
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: targetY)
            inlineHistory.setLastScrollOffsetY(targetY, for: surfaceID)
            recordScrollDiagnostic(
                "render-ledger inline-history-placed surface=\(surfaceID.description) target=\(Self.format(targetY)) max=\(Self.format(newMaxOffsetY)) was=\(Self.format(anchor.offsetY))/\(Self.format(anchor.maxOffsetY))"
            )
            if findController.isOpen { findController.updateSearch() }
            // Content can still be growing; keep converging on the same
            // distance from the tail until it stops or the reader intervenes.
            guard awaitsGrowth,
                  newMaxOffsetY <= anchor.maxOffsetY,
                  !view.isTracking,
                  !view.isDragging
            else { return }
            retryInlineHistoryPlacement(
                surfaceID: surfaceID,
                owner: owner,
                anchor: anchor,
                awaitsGrowth: awaitsGrowth,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func retryInlineHistoryPlacement(
        surfaceID: SurfaceId,
        owner: TerminalRenderOwner,
        anchor: InlineTmuxHistoryRequestState.ScrollAnchor,
        awaitsGrowth: Bool,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
            placeInlineHistoryReader(
                surfaceID: surfaceID,
                owner: owner,
                anchor: anchor,
                awaitsGrowth: awaitsGrowth,
                attemptsRemaining: attemptsRemaining
            )
        }
    }

    private var shouldRecordScrollDiagnostics: Bool {
        scrollDiagnosticsEnabled || DiagnosticLogStore.isScrollDiagnosticsEnabled
    }

    private func recordScrollDiagnostic(_ message: String) {
        guard shouldRecordScrollDiagnostics else { return }
        scrollDiagnostics.sequence += 1
        let context = [
            "ssh",
            "seq=\(scrollDiagnostics.sequence)",
            "mode=\(tmux.mode)",
            "window=\(tmux.activeWindowId?.description ?? "nil")",
            "pane=\(tmux.activePaneId?.description ?? "nil")",
            "grid=\(activeGridWindow?.id.description ?? "nil")",
        ].joined(separator: " ")
        let line = "\(context) \(message)"
        DiagnosticLogStore.appendScroll(line)
    }

    private func terminalScrollPosition(for view: TerminalView?) -> TerminalScrollPosition? {
        guard let view else { return nil }
        let terminal = view.getTerminal()
        return TerminalScrollPosition(
            offsetY: view.contentOffset.y,
            maxOffsetY: max(0, view.contentSize.height - view.bounds.height),
            contentHeight: view.contentSize.height,
            boundsHeight: view.bounds.height,
            isAltScreen: terminal.isCurrentBufferAlternate,
            mouseMode: String(describing: terminal.mouseMode)
        )
    }

    private func describeScrollPosition(for view: TerminalView?) -> String {
        describeScrollPosition(terminalScrollPosition(for: view))
    }

    private func describeScrollPosition(_ position: TerminalScrollPosition?) -> String {
        guard let position else { return "nil" }
        return "off=\(Self.format(position.offsetY))/\(Self.format(position.maxOffsetY)) content=\(Self.format(position.contentHeight)) bounds=\(Self.format(position.boundsHeight)) bottom=\(position.isAtBottom) alt=\(position.isAltScreen) mouse=\(position.mouseMode)"
    }

    private func shouldLogTerminalFeedScroll(
        before: TerminalScrollPosition?,
        after: TerminalScrollPosition?
    ) -> Bool {
        guard let after else { return false }
        guard let before else { return !after.isAtBottom }
        return !before.isAtBottom
            || !after.isAtBottom
            || abs(before.offsetY - after.offsetY) > 0.5
            || abs(before.maxOffsetY - after.maxOffsetY) > 0.5
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    /// Inset needed to keep terminal glyphs clear of the physical
    /// display corner radius. Uses the private `_displayCornerRadius`
    /// KVC key when available (stable across iOS versions); falls back
    /// to 24pt which covers current iPad Pro / iPad Air / iPad mini
    /// corner sizes.
    static let cornerInset: CGFloat = {
        if let value = UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat,
           value > 0 {
            return value
        }
        return 24
    }()

}

private struct TerminalScrollPosition {
    let offsetY: CGFloat
    let maxOffsetY: CGFloat
    let contentHeight: CGFloat
    let boundsHeight: CGFloat
    let isAltScreen: Bool
    let mouseMode: String

    var isAtBottom: Bool {
        maxOffsetY - offsetY <= 1.0
    }
}

/// Renders the current tmux cell grid inside a compact local viewport while a
/// resize is in flight. `focusRect` may be one pane within the full window; the
/// pane is cropped and fitted to the phone until tmux reports the new grid.
struct GeometryNeutralTmuxCanvasModifier: ViewModifier {
    let windowRect: CellRect?
    let focusRect: CellRect?
    let cellSize: CGSize
    var onViewportSize: ((CGSize) -> Void)? = nil

    private var canvasRects: (window: CellRect, focus: CellRect)? {
        guard let windowRect,
              let focusRect,
              windowRect.width > 0,
              windowRect.height > 0,
              focusRect.width > 0,
              focusRect.height > 0,
              cellSize.width > 0,
              cellSize.height > 0
        else { return nil }
        return (windowRect, focusRect)
    }

    /// The projected canvas and the plain viewport share one structure, so
    /// tmux metadata arriving (or a window briefly losing its layout) never
    /// remounts `content`. A remounted mosh terminal stays blank: mosh does
    /// not resend a screen that has not changed.
    @ViewBuilder
    func body(content: Content) -> some View {
        if canvasRects != nil || onViewportSize != nil {
            GeometryReader { geo in
                // Shared with Android: the frame/scale/pan math is portable, so
                // both renderers put the focused pane in the same place.
                let projection = canvasRects.flatMap { rects in
                    TmuxCompactCanvas.projection(
                        window: rects.window,
                        focus: rects.focus,
                        cellWidth: cellSize.width,
                        cellHeight: cellSize.height,
                        viewportWidth: geo.size.width,
                        viewportHeight: geo.size.height
                    )
                }
                let gridSize = CGSize(
                    width: CGFloat(projection?.contentWidth ?? geo.size.width),
                    height: CGFloat(projection?.contentHeight ?? geo.size.height)
                )
                let surfaceSize = projection == nil ? gridSize : TerminalCellMetrics.surfaceSize(
                    for: gridSize,
                    cellSize: cellSize
                )

                ZStack(alignment: .topLeading) {
                    content
                        .frame(
                            width: surfaceSize.width,
                            height: surfaceSize.height,
                            alignment: .topLeading
                        )
                        .frame(width: gridSize.width, height: gridSize.height, alignment: .topLeading)
                        .clipped()
                        .contentShape(Rectangle())
                        .scaleEffect(CGFloat(projection?.scale ?? 1), anchor: .topLeading)
                        .offset(
                            x: CGFloat(projection?.offsetX ?? 0),
                            y: CGFloat(projection?.offsetY ?? 0)
                        )
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.height,
                    alignment: .topLeading
                )
                .clipped()
                .onAppear {
                    onViewportSize?(geo.size)
                }
                .onChange(of: geo.size) { _, newSize in
                    onViewportSize?(newSize)
                }
            }
        } else {
            content
        }
    }
}

/// Mosh transport variant of `SessionView`.
///
/// The main mosh UDP session owns terminal rendering end-to-end.
/// tmux metadata and control commands travel on a separate SSH exec
/// channel running `tmux -CC attach -t <session>`, which feeds only the
/// `TmuxController`.
struct MoshSessionView: View {
    @StateObject var session: MoshSession
    var liveSessionID: UUID
    var isActive: Bool
    /// Other sessions still awaiting a verdict in the same restore window.
    var reconnectingElsewhere: Int = 0
    /// The user closed this session on purpose. Distinct from
    /// `onSessionEnded`, which also fires for a transport death and a clean
    /// remote exit — the restore window must reopen those and must not reopen
    /// this.
    var onUserClosedSession: () -> Void = {}
    var onToggleSidebar: () -> Void
    var sidebarVisible: Bool
    var onBack: () -> Void
    /// Connection-failed overlay → open the host editor.
    var onEditHost: () -> Void
    /// Connection-failed overlay → reconnect with the same host.
    var onRetry: () -> Void
    var onSessionEnded: () -> Void
    var onSelectSession: (UUID) -> Void
    /// Called when ⌘, fires inside the session. The parent opens the
    /// Settings page (`selectedItem = .settings`).
    var onOpenSettings: () -> Void
    /// Called when ⌘⇧A fires inside SwiftTerm.
    var onOpenAgentCenter: (() -> Void)?
    /// Same in-bar continuity affordance as SSH; transport mechanics do not
    /// get their own presentation path.
    var continuityActions: SessionContinuityActions? = nil

    @State private var announcedMoshOutage: TimeInterval?

    @State private var terminalBox = TerminalBox(
        traceLabel: "mosh",
        dropsClientMouseModes: integrationScrollHarnessDropsClientMouseModes
    )
    @State private var renderDropSummary = RenderDropSummaryReporter()
    /// Remote Files panel — same per-session scoping as the SSH view.
    /// The bridge is a plain SSH connection independent of the mosh
    /// transport, shared per-host via FileBridgeRegistry.
    @State private var filesPanel = FilesPanelController()
    @State private var tmux = TmuxController(
        controlPath: .sideChannel,
        clientSizePolicy: .resizeTmux,
        separatorProbeEnabled: true
    )
    @State private var tmuxTerminalQueryResponder = TerminalOSCColorQueryResponder()
    @State private var kittyWindowModes = KittyWindowModeStore()
    @State private var modifierState = ModifierState()
    @State private var shellIntegration = SwipePadShellIntegrationTracker()
    @State private var swipePadSidecarProbeGate = SwipePadSidecarProbeGate()
    @State private var swipePadOutputActivityToken = 0
    @State private var swipePadOutputActivityTask: Task<Void, Never>?
    @State private var swipePadSessionIsActive = false
    @State private var agentSourceRegistrationID: UUID?
    /// Same portable presentation stream as the SSH path; transport-specific
    /// objects below are adapters for UDP/side-channel mechanics only.
    @State private var sharedSessionState: SharedSessionState = .idle
    @State private var sharedTmuxSnapshot: TmuxSnapshot?
    @State private var sharedChallenge: SessionChallenge?
    @State private var sharedRemoteWorkingDirectory: String?
    private var presentationSessionState: SessionState {
        legacySessionState(from: sharedSessionState)
    }
    /// The takeover veil and every input gate read the controller's one
    /// Equatable presentation (S3′), the same as the inline SSH path: it changes in the same render pass as
    /// the top-bar chip and carries no generation, so equal writes never
    /// re-render the session.
    private var gridAuthorityPresentation: TmuxController.GridAuthorityPresentation {
        tmux.gridAuthorityPresentation
    }
    private var effectiveGridAuthorityPeerName: String? {
        gridAuthorityPresentation.peerName
    }
    /// The veil is up: another device holds the grid, or a take-back is
    /// presenting over it.
    private var sessionIsControlledElsewhere: Bool {
        gridAuthorityPresentation.showsVeil
    }
    /// The veil is on screen (P9's drawing gate keys off this, not off
    /// `sessionIsControlledElsewhere`): the launch overlay and a connection
    /// that is not `.connected` outrank it.
    private var veilIsDrawn: Bool {
        ContinuedElsewherePresentationPolicy.veilIsDrawn(
            veilUp: sessionIsControlledElsewhere,
            launchOverlayShown: showsLaunchOverlay,
            connected: presentationSessionState == .connected
        )
    }
    /// Input waits for authority: veiled, reclaiming, or resuming over a
    /// live channel. A show waiting for a channel that is down still types
    /// through the transport unless a peer was the last-known holder (M7).
    /// A plain read of one stored, observed property: O(1) per keystroke.
    private var terminalInputGatedByAuthority: Bool {
        !tmux.gridAuthorityAllowsInput
    }
    @State private var tmuxControlBox = TmuxControlChannelBox()
    @State private var tmuxControlTask: Task<Void, Never>?
    @State private var tmuxControlGeneration = 0
    @State private var tmuxSideChannelState: MoshSideChannelState = .idle
    @State private var tmuxShortcutToastVisible = false
    @State private var tmuxShortcutToastTask: Task<Void, Never>?
    @State private var agentScrollNotice = AgentScrollPreventionNoticeController()
    @State private var lastTerminalSize: (cols: Int, rows: Int)?
    @State private var lastCompactViewportSize: (cols: Int, rows: Int)?
    @State private var lastCompactRequestedClientSize: (cols: Int, rows: Int)?
    @State private var compactReprojectionMemo = TmuxCompactReprojectionMemo()
    @State private var resolvedTmuxSessionName: String?
    @State private var currentTerminalTitle: String? = nil
    @State private var lastMoshPaneChromeSnapshot: MoshPaneChromeSnapshot?
    @State private var moshPaneChromeTopMaskActive = false
    @State private var moshPaneChromeTopMaskGeneration = 0
    @State private var moshPaneChromeCollapseMaskedPaneIds: Set<PaneId> = []
    @State private var moshPaneScrollbackOverlay: MoshPaneScrollbackOverlayRuntime?
    /// Most recently dismissed overlay runtime, kept MOUNTED (opacity 0,
    /// routing-inactive — every guard reads `moshPaneScrollbackOverlay`
    /// only). Creating the overlay's SwiftTerm view costs ~140ms of
    /// main-thread block (Metal pipeline + mount) — measured as the
    /// "first scroll is laggy" hitch, re-paid on every scroll-up after a
    /// return-to-bottom or keystroke dismissal. Parking the runtime here
    /// keeps the view alive so `ensureMoshPaneScrollbackOverlay` can
    /// promote it back for the same pane at zero mount cost.
    @State private var moshDormantScrollbackOverlay: MoshPaneScrollbackOverlayRuntime?
    /// The overlay instance whose first capture has been fed — only then is
    /// the overlay surface mounted. Before that the overlay would render as
    /// an opaque theme-background rectangle over the live pane (a black
    /// flash for the whole capture-pane round trip). `TerminalBox` buffers
    /// the feed until the surface attaches, and the pending-placement hook
    /// (`onReady`) anchors the offset post-mount, so mounting late is safe.
    @State private var moshOverlayContentReadyId: UUID?
    /// Shared by the product view and the live transport gate. It owns the
    /// exact bind -> held feed -> historyReady handoff while this view remains
    /// responsible for SwiftUI presentation and native scroll placement.
    @State private var moshRenderLedgerAdapter = MoshRenderLedgerSurfaceAdapter()
    /// Presentation latch for the single (including iPhone compact) surface.
    /// The reducer owns freeze state; this merely notices when the reader has
    /// visibly returned to the mosh-painted live tail.
    @State private var moshLiveHistoryRevealed = false
    /// A single/iPhone history feed awaiting physical UIScrollView placement.
    /// The shared ledger remains in its staged state until this exact owner is
    /// positioned on the next main-queue turn.
    @State private var pendingMoshLiveHistoryPresentation: MoshLiveHistoryPresentation?
    @State private var moshPaneInteractionProbeInFlight:
        [PaneId: (id: UUID, connectionGeneration: UInt64)] = [:]
    @State private var pendingMoshInteractionProbeScrollPointsByPane: [PaneId: Double] = [:]
    @State private var moshSplitAltScreenScrollDispatcher =
        Self.makeMoshSplitAltScreenScrollDispatcher()
    /// §R4.6 find-in-scrollback. See SessionView for details — same
    /// shape, just bound to the mosh transport's terminal box.
    @State private var findController = FindController()
    @AppStorage(DiagnosticLogStore.scrollDiagnosticsDefaultsKey)
    private var scrollDiagnosticsEnabled = false
    @State private var scrollDiagnostics = ScrollDiagnosticCounters()

    /// Unified launch-loading shield (same visual as SSH side). Defaults
    /// to `true` so the overlay covers `.connecting` (mosh bootstrap +
    /// UDP handshake). Dismissed by `.onChange(of: presentationSessionState)` for
    /// `.customCommand` and by the combined tmux-mode / first-output
    /// signal below for `.autoTmux` / `.pinnedTmux`.
    @State private var launchOverlayVisible = true
    @State private var dismissedWSLTailscaleMTUWarning = false

    /// A side-channel authority claim explicitly requests the full mosh frame
    /// before lifting its veil. Retain the exact layout whose ordinary observer
    /// repaint may be suppressed; a fence that lands after that observer ran
    /// must not make a later, unrelated split/collapse consume a stale Bool.
    @State private var authorityMoshRepaintLayoutToSuppress: WindowLayout?
    /// The adapter holds the authority veil until the exact owner-tagged frame
    /// has crossed the ordinary output stream and finished rendering.
    @State private var authorityMoshRepaintRequestID: UInt64?
    /// Flipped true on the first non-empty terminal-bytes event arriving via
    /// `sessionCommands.events`. Combined with `tmux.mode == .tmuxControl`
    /// to guarantee the terminal we fade in has content (side-channel
    /// control mode sets `isInitialRenderReady` immediately on DCS, so
    /// we can't rely on that alone here).
    @State private var hasReceivedFirstOutput = false

    /// Bounds the overlay's wait for the side-channel `-CC` attach. The
    /// visible mosh client runs a plain `tmux new -A`, so once the main
    /// stream is painting, the terminal underneath is fully usable — only
    /// window management rides the side channel. If that channel hasn't
    /// attached within the budget (auth mismatch on the second SSH leg,
    /// MaxSessions, a flaky path), reveal the working terminal and let the
    /// reconnect loop keep trying behind it instead of spinning the shield.
    @State private var moshControlAttachWatchdog: Task<Void, Never>?

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AppLockController.self) private var appLockController
    @Environment(\.sessionShowCoordinator) private var showEdges
    @Environment(\.terminalInputAllowed) private var inheritedTerminalInputAllowed
    @Environment(BellController.self) private var bellController
    @Environment(TunnelsRegistry.self) private var tunnelsRegistry
    @Environment(SwipePadProfileStore.self) private var swipePadStore
    @Environment(SpeechDictationController.self) private var dictationController
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(AgentCenterV2Coordinator.self) private var agentCenterV2
    @Environment(AppPhase.self) private var appPhase
    @Environment(FileBridgeRegistry.self) private var fileBridges
    @Environment(HostTerminalBackgroundStore.self) private var hostBackgrounds
    @Environment(\.designTokens) private var appDesignTokens
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var activeTheme: TerminalTheme {
        TerminalTheme.find(id: appearance.terminalThemeID)
    }

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    /// Bottom inset for chrome that stacks above the accessory bar. Measured
    /// from the bar's reserved band, so the swipe pad clears the phone's
    /// home-indicator strip as well as the chip row.
    private var swipePadBottomInset: CGFloat {
        appearance.showAccessoryBar
            ? SessionAccessoryBar.reservedBandHeight()
            : max(SessionView.cornerInset - 8, 4)
    }

    private var filesPanelTokens: DesignTokens {
        isPhone
            ? appDesignTokens
            : activeTheme.chromeTokens(applying: appearance)
    }

    /// Background picture for this session's canvas (host override → global),
    /// nil for the classic solid theme color.
    private var resolvedTerminalBackground: ResolvedTerminalBackground? {
        ResolvedTerminalBackground.resolve(
            hostID: session.host.id,
            appearance: appearance,
            hostStore: hostBackgrounds
        )
    }

    private static let moshScrollbackTopThreshold: CGFloat = 24
    private static let moshPaneChromeTopMaskDuration: TimeInterval = 0.35

    private var showsLaunchOverlay: Bool { launchOverlayVisible }

    /// Phase for the launch overlay caption. Mosh paths:
    ///   - `.connecting` while bootstrap SSH / UDP handshake runs.
    ///   - `.attachingTmuxChannel` once UDP is up but the side-channel
    ///     SSH hasn't yet flipped tmux into `.tmuxControl`.
    ///   - `.attachingPane` once tmux is in control mode but mosh
    ///     hasn't streamed pane bytes yet.
    /// `.customCommand` only ever sees `.connecting` (dismisses on
    /// first `.connected`).
    private var launchPhase: SessionLaunchPhase {
        if presentationSessionState != .connected { return .connecting }
        switch session.host.launchMode {
        case .customCommand:
            return .connecting
        case .autoTmux, .pinnedTmux:
            if tmux.mode == .tmuxControl { return .attachingPane }
            return .attachingTmuxChannel
        }
    }

    private var launchSubtitle: String? {
        switch session.host.launchMode {
        case .autoTmux, .pinnedTmux: return resolvedTmuxSessionName
        case .customCommand:         return nil
        }
    }

    /// Non-nil when the connect attempt failed; flips the launch overlay
    /// into its error state (the overlay no longer dismisses on `.failed`).
    private var launchFailureReason: String? {
        if case .failed(let reason) = presentationSessionState { return reason }
        return nil
    }

    /// ⌘⇧E / top-bar toggle — mosh variant. The bridge is plain SSH to
    /// the same endpoint (mosh's UDP transport can't carry SFTP), with
    /// the same auth flags this session connected with.
    private func toggleFilesPanel() {
        terminalBox.dismissTransientInteractions()
        if filesPanel.isOpen {
            withAnimation(.easeInOut(duration: 0.2)) { filesPanel.close() }
            return
        }
        configureFilesPanelIfNeeded()
        if tmux.mode == .tmuxControl {
            filesPanel.terminalReportedDirectory(tmux.activePaneCurrentPath)
        } else if let dir = terminalBox.view?.getTerminal().hostCurrentDirectory {
            filesPanel.terminalReportedDirectory(dir)
        }
        filesPanel.transfers?.acknowledgeBackgroundAttention()
        withAnimation(.easeInOut(duration: 0.2)) { filesPanel.open() }
    }

    private var fileTransferAttention: BackgroundTransferAttention {
        fileBridges.existingTransferQueue(for: FileBridgeKey(host: session.host))?
            .backgroundAttention ?? .none
    }

    private var compactMoshFilesBinding: Binding<Bool> {
        Binding(
            get: { isPhone && filesPanel.isOpen },
            set: { if !$0 { filesPanel.close() } }
        )
    }

    /// Bridge/handler wiring shared by the panel toggle and the §3
    /// selection actions (which may run with the panel closed).
    private func configureFilesPanelIfNeeded() {
        if filesPanel.bridge == nil {
            let bridge = fileBridges.bridge(
                for: session.host,
                requireBiometric: session.requireBiometric,
                isSecureEnclave: session.isSecureEnclave
            )
            filesPanel.attach(bridge: bridge)
            filesPanel.configureFileActions(
                transfers: fileBridges.transferQueue(for: bridge),
                hostFolderName: session.host.name
            )
        }
        // Plain-mosh cwd comes from the bridge poller (below), not from
        // OSC 7 — a stock mosh-server drops OSC 7 server-side before it
        // ever reaches the state sync, so the shell-integration CTA
        // would be a dead end. Offer it only when polling is impossible
        // (no server PID captured from the bootstrap banner).
        if filesPanel.onInstallShellIntegration == nil, session.remoteServerPID == nil {
            let host = session.host
            let requireBiometric = session.requireBiometric
            let isSecureEnclave = session.isSecureEnclave
            filesPanel.onInstallShellIntegration = { [filesPanel] in
                filesPanel.infoMessage = String(localized: "Installing shell integration…")
                Task { @MainActor in
                    do {
                        let report = try await RemoteShellIntegrationInstaller.install(
                            on: host,
                            requireBiometric: requireBiometric,
                            isSecureEnclave: isSecureEnclave
                        )
                        filesPanel.infoMessage = String(
                            localized: "Installed (\(report.rcFilesUpdated.joined(separator: ", "))). Takes effect on the next shell login — run exec $SHELL or reconnect.",
                            comment: "Shell integration installed; the argument lists the startup files that were edited"
                        )
                    } catch {
                        filesPanel.infoMessage = nil
                        filesPanel.lastError = error.localizedDescription
                    }
                }
            }
        }
        if filesPanel.onSendPathToTerminal == nil {
            // Same route as this view's consumePendingPathInjection: the
            // mosh transport, as keys go. Overlay guard per the
            // accessory-bar convention — during tmux startup the transport
            // belongs to the -CC bootstrap.
            filesPanel.onSendPathToTerminal = { path in
                guard presentationSessionState == .connected, !showsLaunchOverlay else { return }
                if typingAwaitsOwnAuthority {
                    Task { @MainActor in
                        await awaitOwnAuthorityTransition()
                        guard presentationSessionState == .connected, !showsLaunchOverlay else {
                            copyUndeliveredPathToClipboard(path, refusedByAuthority: false)
                            return
                        }
                        typeRemotePath(path)
                    }
                } else {
                    typeRemotePath(path)
                }
            }
        }
    }

    /// §3 selection menu, mosh variant: identical routing — the bridge
    /// is transport-independent, and cwd falls back to the panel's
    /// poller-fed signal inside openTerminalPath.
    private func handleSelectionPathAction(
        _ action: TesseraTerminalSelectionPathAction, text: String
    ) {
        guard presentationSessionState == .connected, !showsLaunchOverlay else { return }
        appLockController.notifyUserActivity()
        configureFilesPanelIfNeeded()
        let cwd: String? = tmux.mode == .tmuxControl
            ? tmux.activePaneCurrentPath
            : terminalBox.view?.getTerminal().hostCurrentDirectory
        filesPanel.openTerminalPath(
            text,
            cwd: cwd,
            intent: action == .quickLook ? .quickLook : .reveal
        ) { message in
            terminalDropFailure = message
        }
    }

    /// Failed terminal drops surface here (the drop modifier's toast) —
    /// the panel and its error banner may be CLOSED during a drop.
    @State private var terminalDropFailure: String?

    /// Drop-on-terminal, mosh variant: same temp-upload + quoted-path
    /// injection, routed like consumePendingPathInjection (the mosh
    /// transport, as keys go).
    private func handleTerminalDrop(_ providers: [NSItemProvider]) -> Bool {
        guard presentationSessionState == .connected,
              !showsLaunchOverlay,
              !terminalInputGatedByAuthority
        else { return false }
        let bridge = fileBridges.bridge(
            for: session.host,
            requireBiometric: session.requireBiometric,
            isSecureEnclave: session.isSecureEnclave
        )
        let queue = fileBridges.transferQueue(for: bridge)
        return FilesPanelController.handleTerminalDrop(
            providers,
            queue: queue,
            inject: { path in
                await awaitOwnAuthorityTransition()
                // The upload outlived the connection: keep the path.
                guard presentationSessionState == .connected, !showsLaunchOverlay else {
                    copyUndeliveredPathToClipboard(path, refusedByAuthority: false)
                    return
                }
                typeRemotePath(path, suffix: " ")
            },
            reportFailure: { message in
                terminalDropFailure = message
                DiagnosticLogStore.appendApp("terminal-drop failed: \(message)")
            }
        )
    }

    /// Identity for the cwd-poll task; see RemoteCwdPoller.taskKey.
    private var moshCwdPollKey: String {
        RemoteCwdPoller.taskKey(
            panelOpen: filesPanel.isOpen,
            sessionActive: isActive,
            tmuxAttached: tmux.mode == .tmuxControl,
            serverPID: session.remoteServerPID
        )
    }

    /// Plain-mosh follow: poll the shell's cwd over the bridge — it's
    /// the mosh-server's child and the bootstrap banner gave us the
    /// server PID. No oscSignal probe here: a stock remote mosh-server
    /// drops OSC 7, and `hostCurrentDirectory` can hold a stale value
    /// that rode the tmux control channel, so non-nil wouldn't mean
    /// live. Under tmux the pane subscription owns cwd and this task
    /// idles out via its id.
    private func runMoshCwdPoll() async {
        guard filesPanel.isOpen, isActive, tmux.mode != .tmuxControl,
              let serverPID = session.remoteServerPID else { return }
        await RemoteCwdPoller.run(
            panel: filesPanel,
            discovery: .moshServerChild(serverPID: serverPID)
        )
    }

    /// The bootstrap banner can deliver the PID after the panel was
    /// first opened; the poller takes over then, so drop the install
    /// CTA latched during the no-PID window — it's a dead end against
    /// a stock mosh-server (drops OSC 7).
    private func handleRemoteServerPIDChange(_ pid: Int?) {
        if pid != nil { filesPanel.onInstallShellIntegration = nil }
    }

    /// Upload sheet's "paste path" — mosh variant. The facade types it
    /// over the mosh transport in every mode, as it does keys (the PTY's
    /// tmux forwards to the active pane in the attached modes); this
    /// view's tmux `sendBytes` rides the side-channel SSH, nil on plain
    /// mosh and backgrounded mosh+tmux. Every edge calls this, so it reads
    /// the slot itself: an edge that fires after another consumed the path
    /// finds none. Our own resume or take-back leaves it pending until
    /// typing opens.
    private func consumePendingPathInjection() {
        guard let path = session.pendingPathInjection,
              presentationSessionState == .connected,
              !typingAwaitsOwnAuthority
        else { return }
        session.pendingPathInjection = nil
        typeRemotePath(path)
    }

    /// Types an uploaded or dropped path (S5′). A path is typing: it goes
    /// as acknowledged `sendInput`, gated, routed and queued like a key,
    /// and a path the gate refuses or the backend drops goes to the
    /// clipboard with a message instead of vanishing.
    private func typeRemotePath(_ path: String, suffix: String = "") {
        let bytes = Array((FilesPanelController.shellQuoted(path) + suffix).utf8)
        terminalBox.noteOutOfBandInput()
        session.sessionCommands(tmux: tmux).sendInputAcknowledged(bytes) { delivery in
            switch delivery {
            case .sent: break
            case .refused: copyUndeliveredPathToClipboard(path, refusedByAuthority: true)
            case .dropped: copyUndeliveredPathToClipboard(path, refusedByAuthority: false)
            }
        }
    }

    /// Whether typing waits on our own resume or take-back, which ends in
    /// typing or a veil within moments.
    private var typingAwaitsOwnAuthority: Bool {
        guard let refusal = session.sessionCommands(tmux: tmux)
            .authorityRefusal(for: .sendInput(Data()))
        else { return false }
        return refusal != .yielded
    }

    /// Lets a path that arrives during our own resume or take-back wait
    /// for it (at most 10 s), in order: keys are refused meanwhile.
    private func awaitOwnAuthorityTransition() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while typingAwaitsOwnAuthority, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func copyUndeliveredPathToClipboard(_ path: String, refusedByAuthority: Bool) {
        UIPasteboard.general.string = path
        terminalDropFailure = refusedByAuthority
            ? String(localized: "The uploaded path was copied to the clipboard because this session is being controlled from another device.")
            : String(localized: "The terminal is no longer available, so the remote path was copied to the clipboard.")
    }

    private func preservePendingPathAfterConnectionFailure() {
        guard let path = session.pendingPathInjection else { return }
        session.pendingPathInjection = nil
        UIPasteboard.general.string = path
        terminalDropFailure = String(localized: "The uploaded path was copied to the clipboard because the terminal did not connect.")
    }

    // Body is split in two: the stack + the bulk of its modifiers here,
    // the trailing lifecycle modifiers in `body` — one expression blew
    // past the type-checker's budget (same wall FilesPanelView hit).
    private var moshSessionTopBar: some View {
        AnyView(SessionTopBar(
            state: presentationSessionState,
            host: session.host,
            sessionID: liveSessionID,
            sessionIsActive: isActive,
            tmux: tmux,
            sessionCommands: session.sessionCommands(tmux: tmux),
            tmuxIsDegraded: isTmuxDegraded,
            connectionStatus: .mosh(
                sessionState: presentationSessionState,
                transportState: session.transportState,
                tcpControl: moshTcpControlStatus
            ),
            onToggleSidebar: onToggleSidebar,
            sidebarVisible: sidebarVisible,
            onBack: {
                terminalBox.dismissTransientInteractions()
                stopTmuxControlChannel()
                onBack()
            },
            onDisconnect: {
                terminalBox.dismissTransientInteractions()
                onUserClosedSession()
                session.sessionCommands.disconnect()
            },
            findController: findController,
            filesPanelOpen: filesPanel.isOpen,
            fileTransferAttention: fileTransferAttention,
            onToggleFiles: toggleFilesPanel,
            bellController: bellController,
            forwarderManager: session.portForwarderManager,
            T: activeTheme.chromeTokens(applying: appearance),
            onOpenAgentCenter: onOpenAgentCenter,
            continuityActions: continuityActions,
            onTmuxPaneMutation: showMoshPaneChromeTopMask
        )
        .frame(height: SessionTopBar.reservedHeight(
            pillHeight: appearance.topBarHeight,
            compact: isPhone
        ))
        .zIndex(2))
    }

    private var needsNativeMoshOutageBanner: Bool {
        guard tmux.mode == .tmuxControl else { return false }
        return isPhone || moshLiveHistoryRevealed
            || moshOverlayContentReadyId != nil
            || (moshActiveWindow.map { $0.panes.count > 1 && !$0.isZoomed } ?? false)
    }

    private var moshOutageBanner: some View {
        Group {
            if needsNativeMoshOutageBanner, !showsLaunchOverlay,
               let timing = session.outageTiming {
                Text(timing.kind == .contact
                     ? LocalizedStringKey("last contact \(timing.seconds) s ago")
                     : LocalizedStringKey("last reply \(timing.seconds) s ago"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(activeTheme.chromeTokens(applying: appearance).fg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(activeTheme.chromeTokens(applying: appearance).border)
                            .frame(height: 0.5)
                    }
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: needsNativeMoshOutageBanner && isActive && appPhase.isActive
            && !appLockController.isLocked && !showsLaunchOverlay
            ? session.outageTiming?.startedAt : nil, initial: true) { _, startedAt in
            guard let startedAt else {
                if session.outageTiming == nil { announcedMoshOutage = nil }
                return
            }
            guard announcedMoshOutage != startedAt else { return }
            announcedMoshOutage = startedAt
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Mosh connection interrupted. Reconnecting."))
        }
    }

    private var moshDecoratedLayerStack: some View {
        ZStack(alignment: .top) {
            activeTheme.bg.ignoresSafeArea()

            if let background = resolvedTerminalBackground, !showsLaunchOverlay {
                TerminalBackdrop(background: background, baseColor: activeTheme.bg)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // See `KeyboardLiftExemptChrome`: the find query field has to
                // stay readable while the software keyboard lifts the session.
                KeyboardLiftExemptChrome {
                    moshSessionTopBar

                    VStack(spacing: 0) {
                        if findController.isOpen {
                            FindBar(
                                controller: findController,
                                horizontalInset: isPhone ? 10 : SessionView.cornerInset,
                                T: activeTheme.chromeTokens(applying: appearance)
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        moshOutageBanner
                            .alignmentGuide(.bottom) { $0[.top] }
                    }
                }
                // Carries `moshSessionTopBar`'s own zIndex out to this level:
                // the chrome group draws above the terminal it now overlaps.
                .zIndex(2)

                ZStack {
                    moshTerminalSurface
                    .modifier(GeometryNeutralTmuxCanvasModifier(
                        windowRect: compactMoshWindowRect,
                        focusRect: compactMoshFocusRect,
                        cellSize: compactMoshCellSize,
                        onViewportSize: updateCompactMoshViewport
                    ))
                    .allowsHitTesting(!showsLaunchOverlay)
                    .opacity(showsLaunchOverlay ? 0 : 1)
                    .animation(
                        // Sequential dissolve — overlay fades out first
                        // (0.25 s), then terminal fades in (0.3 s).
                        showsLaunchOverlay
                            ? .linear(duration: 0)
                            : .easeInOut(duration: 0.30).delay(0.25),
                        value: showsLaunchOverlay
                    )

                    if !isPhone, !showsLaunchOverlay {
                        // Keep both cached UIKit views mounted under stable IDs.
                        // Retaining only the runtime would recreate SwiftTerm
                        // when SwiftUI swaps the active subtree back in.
                        ForEach([moshPaneScrollbackOverlay, moshDormantScrollbackOverlay].compactMap { $0 }, id: \.id) { overlay in
                            if let frame = moshPaneScrollbackFrame(for: overlay.paneId) {
                                MoshPaneScrollbackOverlay(
                                    runtime: overlay,
                                    paneFrame: frame.surfaceFrame,
                                    terminalBackground: resolvedTerminalBackground,
                                    backdropBaseColor: activeTheme.bg,
                                    backdropBleed: moshOverlayBackdropBleed,
                                    onReady: {
                                        applyPendingMoshPaneScrollbackOverlayOffset()
                                        restorePendingMoshWindowModesAfterHistory(
                                            surfaceID: moshOverlaySurfaceID(overlay.paneId)
                                        )
                                    },
                                    onTerminalScrolled: handleMoshPaneScrollbackOverlayScrolled,
                                    onScrollDiagnostic: { message in
                                        recordMoshScrollDiagnostic(message)
                                    },
                                    agentScrollBlockingActive:
                                        agentScrollPrevention(paneID: overlay.paneId.rawValue) != nil,
                                    onAgentScrollBlocked: {
                                        presentAgentScrollPrevention(paneID: overlay.paneId.rawValue)
                                    }
                                )
                                .id(overlay.id)
                                // Invisible until its first capture has been fed: the
                                // surface must MOUNT immediately (feeding a not-yet-
                                // laid-out terminal wraps the capture at the interim
                                // tiny column count, and SwiftTerm doesn't reflow on
                                // resize), but painting it black over the live pane
                                // for the whole capture round trip reads as a black
                                // flash — so it mounts hidden and appears with content.
                                .opacity(overlay.id == moshOverlayContentReadyId ? 1 : 0)
                                // Only a REVEALED overlay may take (scroll-only) hits —
                                // a hidden/parked one must never intercept anything.
                                // Once visible, trackpad pans land on the overlay's own
                                // scroll view and scroll natively; clicks fall through
                                // via the container's scroll-only hitTest.
                                .allowsHitTesting(overlay.id == moshOverlayContentReadyId)
                                .modifier(GeometryNeutralTmuxCanvasModifier(
                                    windowRect: compactMoshWindowRect,
                                    focusRect: compactMoshFocusRect,
                                    cellSize: compactMoshCellSize
                                ))
                            }
                        }
                    }

                    // Alt-screen pans get a local scroll surface to move from
                    // event 1 (htop scroll feel — see the proxy view's doc).
                    // Mutually exclusive with a revealed scrollback overlay:
                    // an alt-screen pane never reveals one (capture skips
                    // alt-screen), and the proxy unmounts the moment the
                    // cached pane state says primary.
                    if !showsLaunchOverlay,
                       agentScrollPrevention(paneID: activeAgentScrollPaneID) == nil,
                       let proxyTarget = moshAltScreenScrollProxyTarget {
                        MoshAltScreenScrollProxy(onScrollDelta: { delta in
                            handleMoshAltScreenProxyScroll(
                                paneId: proxyTarget.paneId,
                                pointsY: delta
                            )
                        })
                        .frame(
                            width: proxyTarget.frame.width,
                            height: proxyTarget.frame.height
                        )
                        .offset(x: proxyTarget.frame.minX, y: proxyTarget.frame.minY)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .modifier(GeometryNeutralTmuxCanvasModifier(
                            windowRect: compactMoshWindowRect,
                            focusRect: compactMoshFocusRect,
                            cellSize: compactMoshCellSize
                        ))
                    }

                    // Mosh paints split pane contents natively in the shared
                    // terminal, but Tessera owns the pane chrome so SSH and
                    // mosh splits look and tap the same.
                    if !isPhone,
                       !showsLaunchOverlay,
                       let snapshot = moshPaneChromeSnapshot(),
                       let cellSize = moshCellSize {
                        let frames = moshPaneChromeFrames(
                            for: snapshot,
                            cellSize: cellSize
                        )
                        MoshPaneChromeOverlay(
                            root: snapshot.layout.root,
                            frames: frames,
                            titles: moshPaneChromeTitles(
                                for: frames,
                                snapshot: snapshot
                            ),
                            cellSize: cellSize,
                            activePaneId: snapshot.activePaneId,
                            chrome: activeTheme.chromeTokens(applying: appearance),
                            backgroundColor: activeTheme.bg,
                            terminalBackground: resolvedTerminalBackground,
                            backdropBleed: moshOverlayBackdropBleed
                        )
                    }

                    if !isPhone,
                       !showsLaunchOverlay,
                       let cellSize = moshCellSize,
                       shouldShowMoshPaneChromeTopMask
                        || !moshPaneChromeCollapseMaskFrames(cellSize: cellSize).isEmpty {
                        let collapseFrames = moshPaneChromeCollapseMaskFrames(cellSize: cellSize)
                        GeometryReader { geo in
                            let topMaskRects: [CGRect] = shouldShowMoshPaneChromeTopMask
                                ? [CGRect(
                                    x: 0,
                                    y: 0,
                                    width: geo.size.width,
                                    height: ceil(cellSize.height) + 1
                                )]
                                : []
                            moshChromeTransitionMask(rects: topMaskRects + collapseFrames)
                        }
                        .allowsHitTesting(false)
                    }

                    if showsLaunchOverlay {
                        SessionLaunchOverlay(
                            T: activeTheme.chromeTokens(applying: appearance),
                            phase: launchPhase,
                            subtitle: launchSubtitle,
                            wslTailscaleMTUWarning: session.wslTailscaleMTUWarning,
                            failureReason: launchFailureReason,
                            onEditHost: onEditHost,
                            onRetry: onRetry,
                            onBack: {
                                // The stall notice puts this button up while
                                // the bootstrap is still running, so leaving
                                // has to tear it down: a bootstrap left to
                                // finish has already spawned a `mosh-server`
                                // on the host with nothing left to reach it.
                                onUserClosedSession()
                                onSessionEnded()
                                session.sessionCommands.disconnect()
                            },
                            reconnectingElsewhere: reconnectingElsewhere
                        )
                        .transition(.opacity)
                        .zIndex(1)
                    }

                    // Continuity takeover veil: another device holds the grid.
                    // Requires `.connected`, so mosh transport loss falls back
                    // to the existing reconnect presentation.
                    if let peerName = effectiveGridAuthorityPeerName, veilIsDrawn {
                        ContinuedElsewhereOverlay(
                            T: activeTheme.chromeTokens(applying: appearance),
                            peerDisplayName: peerName,
                            isReclaiming: gridAuthorityPresentation.isReclaiming,
                            awaitingConnection: gridAuthorityPresentation.isAwaitingConnection,
                            // Focus only the displayed, unlocked veil: hidden
                            // tabs keep theirs mounted at opacity 0, and the
                            // app lock covers a still-mounted ContentView.
                            capturesKeys: ContinuedElsewhereKeyPolicy.admitsGesture(
                                sessionIsActive: isActive,
                                appIsLocked: appLockController.isLocked
                            ),
                            animatesMotion: ContinuedElsewherePresentationPolicy.breathes(
                                displayed: ContinuedElsewhereKeyPolicy.admitsGesture(
                                    sessionIsActive: isActive,
                                    appIsLocked: appLockController.isLocked
                                ),
                                appIsActive: appPhase.isActive
                            ),
                            onTakeBack: takeBackContinuedSession,
                            onCancel: cancelPendingGridAuthorityIntent,
                            // ⌘⇧J / ⌘⇧K keep working while yielded: switching
                            // sessions changes what is on screen here, never
                            // what the peer's terminal receives. Only the
                            // foreground session registers them — a background
                            // session stays mounted (opacity 0) and its veil
                            // would otherwise claim the same chords and step
                            // from the wrong place in the list.
                            onSwitcherShortcut: isActive
                                ? { shortcut in
                                    appLockController.notifyUserActivity()
                                    handleSwitcherShortcut(shortcut)
                                }
                                : nil
                        )
                        .transition(.opacity)
                        .zIndex(2)
                    }

                    // A show resolving: the terminal stays visible (no veil
                    // flash on resume); only input waits for the read.
                    if gridAuthorityPresentation.isResuming,
                       !showsLaunchOverlay {
                        GridAuthorityResumingIndicator(
                            T: activeTheme.chromeTokens(applying: appearance),
                            awaitingConnection: gridAuthorityPresentation.isAwaitingConnection,
                            onCancel: cancelPendingGridAuthorityIntent
                        )
                        .transition(.opacity)
                        .zIndex(3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(
                    .easeInOut(duration: ContinuedElsewherePresentationPolicy.veilFadeDuration),
                    value: sessionIsControlledElsewhere
                )
                // Drop a file onto the terminal → upload to the host's
                // temp dir, then type the quoted path (mockup §4).
                .modifier(TerminalFileDropTarget(
                    T: activeTheme.chromeTokens(applying: appearance),
                    failureMessage: $terminalDropFailure,
                    handle: handleTerminalDrop
                ))
                // §3 terminal Quick Look with the panel closed: the
                // panel hosts presentedPreview only while open, so this
                // fallback presents it otherwise. The binding nils itself
                // while the panel is open — exactly one host at a time by
                // construction. Size (sheet vs full screen) is the user's
                // persisted choice, applied identically on both hosts.
                .quickLookPreview(item: Binding(
                    get: { filesPanel.isOpen ? nil : filesPanel.presentedPreview },
                    set: { filesPanel.presentedPreview = $0 }
                ))
                .sheet(isPresented: compactMoshFilesBinding) {
                    FilesPanelView(
                        controller: filesPanel,
                        T: filesPanelTokens,
                        sessionIsActive: isActive,
                        terminalBackground: nil
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(filesPanelTokens.presentationBg)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
                // Remote Files panel floats as an overlay over the
                // terminal — same as the SSH view. No trailing padding,
                // so the terminal keeps full width and toggling never
                // triggers a mosh SSP / tmux refresh-client resize. A
                // transparent tap-catcher behind the card dismisses the
                // panel when the user taps the terminal, like the sidebar.
                .overlay(alignment: .trailing) {
                    if filesPanel.isOpen, !isPhone {
                        ZStack(alignment: .trailing) {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) { filesPanel.close() }
                                }
                            FilesPanelView(
                                controller: filesPanel,
                                T: activeTheme.chromeTokens(applying: appearance),
                                sessionIsActive: isActive,
                                terminalBackground: resolvedTerminalBackground
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, isPhone ? 4 : SessionView.cornerInset)
                .terminalKeyboardCaretShift()

                if appearance.showAccessoryBar {
                    SessionAccessoryBar(
                        accent: appearance.tokens(systemColorScheme: .dark).accent,
                        modifierState: modifierState,
                        onSend: { bytes in
                            guard !showsLaunchOverlay, !terminalInputGatedByAuthority else {
                                // Refused bytes never reach the PTY: drop the UIKit input
                                // mirror so later edits cannot delete what it believes was typed.
                                terminalBox.noteOutOfBandInput()
                                return
                            }
                            appLockController.notifyUserActivity()
                            invalidateMoshScrollbackForTerminalInput(reason: "accessory-input")
                            session.sessionCommands.sendInput(bytes)
                            terminalBox.noteOutOfBandInput()
                        },
                        applicationCursor: { [terminalBox] in
                            terminalBox.view?.getTerminal().applicationCursor ?? false
                        },
                        onPageScrollAttempt: { _ in
                            guard agentScrollPrevention(
                                paneID: activeAgentScrollPaneID
                            ) != nil else { return false }
                            presentAgentScrollPrevention(
                                paneID: activeAgentScrollPaneID
                            )
                            return true
                        },
                        customShortcutApplies: shouldFire
                    )
                    .allowsHitTesting(!sessionIsControlledElsewhere)
                    .opacity(sessionIsControlledElsewhere ? 0.45 : 1)
                }
            }

            if !showsLaunchOverlay,
               !dismissedWSLTailscaleMTUWarning,
               let warning = session.wslTailscaleMTUWarning {
                WSLTailscaleMTUWarningView(
                    warning: warning,
                    T: activeTheme.chromeTokens(applying: appearance),
                    onDismiss: { dismissedWSLTailscaleMTUWarning = true }
                )
                .padding(.top, SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: isPhone
                ))
                .padding(.horizontal, SessionView.cornerInset + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(3)
            }

            if tmuxShortcutToastVisible {
                MoshTmuxShortcutBlockedToast()
                    .padding(.top, appearance.topBarHeight + 44)
                    .padding(.leading, SessionView.cornerInset + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                    .zIndex(4)
            }

            if let prevention = agentScrollNotice.prevention {
                AgentScrollPreventionNotice(
                    agentName: prevention.agentName,
                    T: activeTheme.chromeTokens(applying: appearance)
                )
                .padding(.top,
                    SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: isPhone
                    ) + (findController.isOpen ? 44 : 8)
                )
                .padding(.horizontal, isPhone ? 12 : SessionView.cornerInset + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(7)
            }

            SwipePadOverlay(
                onSend: { bytes in
                    guard !showsLaunchOverlay, !terminalInputGatedByAuthority else {
                        // Refused bytes never reach the PTY: drop the UIKit input
                        // mirror so later edits cannot delete what it believes was typed.
                        terminalBox.noteOutOfBandInput()
                        return
                    }
                    appLockController.notifyUserActivity()
                    invalidateMoshScrollbackForTerminalInput(reason: "swipepad-input")
                    session.sessionCommands.sendInput(bytes)
                    terminalBox.noteOutOfBandInput()
                },
                tmux: tmux,
                outputActivityToken: swipePadOutputActivityToken,
                processNameProvider: {
                    let names = shellIntegration.processNames
                    if !names.isEmpty {
                        swipePadSidecarProbeGate.reset()
                        SwipePadDiagnostics.log(
                            "provider mosh source=shell-integration candidateCount=\(names.count)"
                        )
                        return names
                    }

                    // Plain mosh's terminal channel can carry neither the
                    // lifecycle OSC nor shell-integration OSC — the mosh
                    // server's emulator consumes unknown OSC sequences
                    // before they reach the client (the fork forwards only
                    // clipboard/cwd/title). Without this side-channel probe
                    // the pad can never match an agent on plain mosh (live
                    // E2E: both providers stuck on the generic puck). Same
                    // FileBridge probe Agent Center's discovery uses,
                    // scoped to the mosh server's process tree.
                    guard let serverPID = session.remoteServerPID else {
                        SwipePadDiagnostics.log(
                            "provider mosh source=ssh-sidecar skipped reason=no-server-pid"
                        )
                        return []
                    }
                    let identity = "\(session.host.id.uuidString):\(serverPID)"
                    return await swipePadSidecarProbeGate.probe(
                        identity: identity
                    ) {
                        let bridge = fileBridges.bridge(
                            for: session.host,
                            requireBiometric: session.requireBiometric,
                            isSecureEnclave: session.isSecureEnclave
                        )
                        do {
                            try await bridge.connect()
                            let output = try await bridge.exec(
                                SwipePadPlainSSHProcessProbe.makeCommand(rootPID: serverPID),
                                inShell: false
                            )
                            let probeNames = SwipePadPlainSSHProcessProbe.processNames(from: output)
                            SwipePadDiagnostics.log(
                                "provider mosh source=ssh-sidecar candidateCount=\(probeNames.count)"
                            )
                            return .success(probeNames)
                        } catch {
                            return .failure(type: String(describing: type(of: error)))
                        }
                    }
                },
                paneProcessNameProvider: { paneID, panePID in
                    guard let channel = tmuxControlBox.channel else {
                        SwipePadDiagnostics.log(
                            "provider mosh source=tmux-pane-ps skipped reason=no-channel panePID=\(panePID)"
                        )
                        return []
                    }
                    let names = await channel.detectForegroundProcessNames(rootPID: panePID)
                    SwipePadDiagnostics.log(
                        "provider mosh source=tmux-pane-ps panePID=\(panePID) candidateCount=\(names.count)"
                    )
                    return names
                },
                agentContext: agentCenterV2.swipePadContext(sessionID: liveSessionID),
                sessionIsActive: swipePadSessionIsActive,
                onShowMore: onOpenAgentCenter,
                profileStore: swipePadStore,
                dictationController: dictationController
            )
            .padding(.top, SessionTopBar.reservedHeight(
                pillHeight: appearance.topBarHeight,
                compact: isPhone
            ))
            .padding(.horizontal, isPhone ? 10 : SessionView.cornerInset)
            .padding(.bottom, swipePadBottomInset)
            .allowsHitTesting(!sessionIsControlledElsewhere)
            .zIndex(sessionIsControlledElsewhere ? -1 : 5)
        }
    }

    private var moshDecoratedChrome: some View {
        moshDecoratedLayerStack
        .animation(.easeInOut(duration: 0.2), value: tmuxSideChannelState)
        .animation(.easeInOut(duration: 0.15), value: tmuxShortcutToastVisible)
        .animation(.easeInOut(duration: 0.18), value: agentScrollNotice.prevention)
        .animation(.easeInOut(duration: 0.25), value: showsLaunchOverlay)
        .onChange(of: tmux.activePaneCurrentPath) { _, path in
            // tmux modes: the pane-metadata subscription pushes the active
            // pane's cwd (updates on cd AND on pane/window focus change).
            guard tmux.mode == .tmuxControl else { return }
            filesPanel.terminalReportedDirectory(path)
        }
        .onChange(of: tmux.mode) { _, newMode in
            updateSwipePadAgentFocus()
            // tmux detached/exited (reset() flips mode before the pane
            // paths clear, so the watcher above never delivers nil).
            // Fall back to OSC 7 when the shell reports it; nil flips
            // the panel to its no-signal state instead of leaving the
            // last tmux pane path stuck as "following".
            guard newMode == .passthrough else { return }
            // Backgrounding also lands here (the side channel is torn
            // down for non-selected tabs) — that's a channel-lifecycle
            // artifact, not a cwd-signal change; reporting nil would
            // wipe session.remoteWorkingDirectory and the Upload sheet
            // would claim "no session cwd" for a live background host.
            guard isActive else { return }
            filesPanel.terminalReportedDirectory(
                terminalBox.view?.getTerminal().hostCurrentDirectory
            )
        }
        .onChange(of: sessionRegistry.tmuxFocusRequest?.token, initial: true) { _, _ in
            handleCompactTmuxFocusRequest()
        }
        .onChange(of: tmux.gridAuthority) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: tmux.mode) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: tmux.controlConnectionGeneration) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: ObjectIdentifier(session)) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: tmux.windows) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: tmux.isWindowListHydrated) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: isActive) { _, _ in handleCompactTmuxFocusRequest() }
        .onChange(of: liveSessionID) { oldID, _ in sessionRegistry.cancelTmuxFocus(sessionID: oldID) }
        .onDisappear { sessionRegistry.cancelTmuxFocus(sessionID: liveSessionID) }
        .ignoresSafeArea(.container, edges: .bottom)
        .terminalKeyboardLayout(
            resizesTerminal: appearance.resizeTerminalWithKeyboard,
            caretClearance: {
                // mosh paints every pane into this one surface, so its caret is
                // the caret in all layouts — no grid case to exclude. Find
                // still is one: it scrolls to a match rather than to the caret,
                // so the whole grid has to clear the keyboard.
                guard !findController.isOpen else { return nil }
                return terminalBox.caretClearance(
                    cellHeight: terminalCaretCellHeight(
                        fontID: appearance.terminalFontID,
                        fontSize: appearance.fontSize
                    ),
                    mouseReportingImpliesAltScreen: tmux.mode != .tmuxControl
                )
            }
        )
        .statusBarHidden(true)
        .persistentSystemOverlays(isPhone ? .automatic : .hidden)
        .modifier(ProgramStatusSessionBridge(
            sessionID: liveSessionID,
            hostLabel: session.host.name.isEmpty ? session.host.address : session.host.name,
            tmux: tmux,
            enabled: appearance.programStatusEnabled,
            // The mosh display is tmux's own rendering; only the focused
            // pane is proven on screen, as for Agent Center's scroll lock.
            presented: ProgramStatusCenter.presentedTerminals(
                isActive: isActive,
                isObscured: showsLaunchOverlay || veilIsDrawn || (isPhone && filesPanel.isOpen)
                    || filesPanel.presentedPreview != nil || filesPanel.presentedShare != nil
                    || filesPanel.showingUploadPicker,
                tmux: tmux,
                gridWindow: nil
            )
        ))
        .onAppear {
            swipePadSessionIsActive = isActive
            updateSwipePadAgentFocus()
            tunnelsRegistry.register(host: session.host.id, manager: session.portForwarderManager)
        }
        .onDisappear {
            terminalBox.dismissTransientInteractions()
            tunnelsRegistry.unregister(host: session.host.id, manager: session.portForwarderManager)
            if let agentSourceRegistrationID {
                agentCenterV2.unregisterSessionSource(
                    sessionID: liveSessionID,
                    registrationID: agentSourceRegistrationID
                )
                self.agentSourceRegistrationID = nil
            }
            swipePadOutputActivityTask?.cancel()
            swipePadOutputActivityTask = nil
        }
    }

    private var moshDecoratedConnectionTask: some View {
        moshDecoratedChrome
        .task {
            MoshDiagnostics.log(
                "mosh view task start transport=\(session.host.transport.rawValue) launchMode=\(session.host.launchMode.rawValue) port=\(session.host.port)"
            )
            // Mirror every cwd report onto the session object so
            // transport-agnostic consumers (Upload sheet) can read it.
            filesPanel.onTerminalDirectoryChanged = { [weak session] dir in
                // Change-guarded: the poller re-reports the same path
                // every tick and the mirror is @Published now.
                if session?.remoteWorkingDirectory != dir {
                    session?.remoteWorkingDirectory = dir
                }
            }
            tmux.sendBytes = { [tmuxControlBox] bytes in
                tmuxControlBox.channel?.send(bytes)
            }
            tmux.sendBytesAdmitting = { [tmuxControlBox] bytes in
                tmuxControlBox.channel?.sendAdmitting(bytes) ?? false
            }
            tmux.commandWriteDiagnostic = { [tmuxControlBox] sequence, correlation in
                tmuxControlBox.channel?.noteCommandWriteDiagnostic(sequence: sequence, correlation: correlation)
            }
            installMoshRenderLedgerAdapter()
            tmux.onCommandQueueTransportRecoveryRequired = {
                [tmuxControlBox] recovery in
                MoshDiagnostics.log(
                    "mosh tmux sidechannel command queue recovery requested count=\(recovery)"
                )
                // Ending this one side channel feeds the existing reconnect
                // loop; the primary mosh SSP session remains interactive.
                tmuxControlBox.channel?.disconnect()
            }
            tmux.onServerGeometryCeded = { [weak session] cols, rows in
                session?.preserveRemoteTmuxSizeAfterCede(cols: cols, rows: rows)
            }
            tmux.gridAuthorityIdentity = GridAuthorityDeviceIdentity.current()
            _ = session.sessionCommands(tmux: tmux).dispatch(
                .setTmuxGridPresentation(isPhone ? .singlePane : .paneGrid)
            )
            mirrorGridAuthorityInRegistry()
            registerGridAuthorityShowTarget()
            tmux.onGridAuthoritySideChannelRepaintPreparing = {
                retireVisibleMoshHistoryForAuthoritativeRepaint()
            }
            tmux.onGridAuthoritySideChannelRepaintRequired = {
                geometryChanged,
                claimGeneration in
                authorityMoshRepaintLayoutToSuppress = geometryChanged
                    ? moshRenderLayout
                    : nil
                var scheduledRequestID: UInt64?
                moshRenderLedgerAdapter.requestOwnedTransportFullFrame(
                    retargetsAcrossSurfaceRebind: true,
                    onScheduled: { requestID in
                        scheduledRequestID = requestID
                        authorityMoshRepaintRequestID = requestID
                    },
                    completion: { acceptedDeliveryID in
                        // A request retired before it was ever scheduled
                        // carries no id to match on, and swallowing it left
                        // the claim in `awaitingRepaint` with nothing able to
                        // settle it. The controller's own generation guards
                        // make a stale report a no-op, so report it.
                        if let requestID = scheduledRequestID {
                            guard requestID == authorityMoshRepaintRequestID
                            else { return }
                            authorityMoshRepaintRequestID = nil
                        }
                        // Initial attach also owns a reservation. Its exact
                        // frame receipt must settle it even without a takeover
                        // veil, or every later history bind replays this claim.
                        if acceptedDeliveryID != nil {
                            _ = session.sessionCommands(tmux: tmux).dispatch(
                                .completeTmuxGridAuthorityRepaint(generation: claimGeneration)
                            )
                        } else {
                            tmux.failGridAuthoritySideChannelRepaint(
                                generation: claimGeneration
                            )
                        }
                    }
                )
            }
            tmux.terminalResponseForOutput = { [tmuxTerminalQueryResponder, appearance] paneId, slice in
                let theme = TerminalTheme.find(id: appearance.terminalThemeID)
                let responses = tmuxTerminalQueryResponder.responses(
                    for: slice,
                    streamID: paneId.description,
                    defaultForegroundRGB: theme.fgRGB,
                    defaultBackgroundRGB: theme.bgRGB
                )
                return responses.isEmpty ? nil : responses
            }
            // `/copy` in Codex (and any `tmux load-buffer -w` or copy-mode
            // yank) reaches a control-mode client only as
            // `%paste-buffer-changed`: tmux forwards OSC 52 to real ttys
            // alone. Mirror the buffer onto the device clipboard, as iTerm2
            // does for its -CC integration.
            tmux.onPasteBufferChanged = { _, text in
                UIPasteboard.general.string = text
            }
            tmux.onBell = { windowID, isActiveWindow, windowName in
                guard !isActiveWindow else { return }
                let bc = bellController
                let sid = session.host.id
                let hname = session.host.name
                Task { @MainActor in
                    bc.ring(
                        source: .tmuxWindow(sessionID: sid, windowID: windowID),
                        isOriginOnScreen: false,
                        hostDisplayName: hname,
                        paneTitle: windowName
                    )
                }
            }
            tmux.paneDidOutput = { paneId in
                if paneId == tmux.activePaneId {
                    // The reducer receives the parser event itself; this is
                    // strictly the visible-reader freeze choreography.
                    invalidateMoshScrollbackForActivePaneOutput()
                }
            }
            findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)

            if resolvedTmuxSessionName == nil {
                resolvedTmuxSessionName = MoshBootstrap.resolvedTmuxSessionName(
                    for: session.host
                )
            }

            // Both paths use the live session's owned, renewable read carrier.
            // Probe failure never falls through to an unrelated Files connection.
            let probeAgentIntegrationOnOwnedCarrier: @MainActor () async throws -> AgentLifecycleHostInstallation? = {
                if tmux.mode == .tmuxControl {
                    guard let channel = tmuxControlBox.channel else { return nil }
                    return try await RemoteAgentLifecycleIntegrationInstaller.probe(
                        execute: { try await channel.executeAgentIntegrationProbeCommand($0) },
                        diagnostic: { detail in
                            DiagnosticLogStore.appendAgentCenter(
                                "host-diagnostic sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-tmux \(detail)"
                            )
                        }
                    )
                }
                guard session.canInspectAgentIntegration else { return nil }
                return try await RemoteAgentLifecycleIntegrationInstaller.probe(
                    execute: { try await session.executeAgentIntegrationProbeCommand($0) },
                    diagnostic: { detail in
                        DiagnosticLogStore.appendAgentCenter(
                            "host-diagnostic sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh \(detail)"
                        )
                    }
                )
            }

            let agentSource = AgentSessionSourceFactory.make(
                sessionID: liveSessionID,
                hostName: session.host.name.isEmpty ? session.host.address : session.host.name,
                baseTransportLabel: "mosh",
                tmux: tmux,
                terminalBox: terminalBox,
                tmuxSessionName: { resolvedTmuxSessionName },
                profiles: { swipePadStore.profiles },
                rawProcessProvider: {
                    guard let serverPID = session.remoteServerPID else { return nil }
                    return await session.detectForegroundProcessSnapshotIfAvailable(
                        rootPID: serverPID
                    )
                },
                rawProcessProofProvider: { expectedPID in
                    guard let serverPID = session.remoteServerPID else { return nil }
                    return await session.detectForegroundProcessSnapshotIfAvailable(rootPID: serverPID, expectedPID: expectedPID)
                },
                paneProcessProvider: { panePID, expectedPID in
                    guard let channel = tmuxControlBox.channel else { return nil }
                    return await channel.detectForegroundProcessSnapshotIfAvailable(rootPID: panePID, expectedPID: expectedPID)
                },
                lifecycleIntegrationCacheKey: session.host.sshConnectionRouteIdentity,
                probeLifecycleIntegrationOnCurrentCarrier: probeAgentIntegrationOnOwnedCarrier,
                probeLifecycleIntegration: {
                    guard let installation = try await probeAgentIntegrationOnOwnedCarrier() else {
                        throw AppleAgentPlatformError.streamingExecUnavailable
                    }
                    return installation
                },
                installLifecycleIntegration: {
                    if let channel = tmuxControlBox.channel {
                        return try await RemoteAgentLifecycleIntegrationInstaller.installNativeAndLifecycle {
                            try await channel.executeAgentInstallationCommand($0)
                        }
                    }
                    let bridge = fileBridges.bridge(
                        for: session.host,
                        requireBiometric: session.requireBiometric,
                        isSecureEnclave: session.isSecureEnclave
                    )
                    try await RemoteAgentLifecycleIntegrationInstaller.install(using: bridge)
                },
                automaticallyInspectCurrentIntegration: {
                    tmux.mode == .tmuxControl ? tmuxControlBox.channel != nil : session.canInspectAgentIntegration
                },
                probeShellIntegration: { processIDs, allowInheritedEnvironment in
                    let command = RemoteAgentLifecycleIntegrationInstaller.makeShellStatusCommand(
                        processIDs: processIDs,
                        allowInheritedEnvironment: allowInheritedEnvironment
                    )
                    if tmux.mode == .tmuxControl {
                        guard let channel = tmuxControlBox.channel else {
                            DiagnosticLogStore.appendAgentCenter(
                                "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-tmux processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=side-channel-missing"
                            )
                            return nil
                        }
                        do {
                            let output = try await channel.executeAgentIntegrationProbeCommand(command)
                            let parsed = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(
                                output
                            )
                            let shellDiagnostic = RemoteAgentLifecycleIntegrationInstaller
                                .parseShellDiagnostic(output)?
                                .replacingOccurrences(of: " ", with: ",") ?? "missing"
                            DiagnosticLogStore.appendAgentCenter(
                                "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-tmux processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=\(parsed.map(String.init) ?? "invalid-output") diagnostic=\(shellDiagnostic)"
                            )
                            return parsed
                        } catch {
                            DiagnosticLogStore.appendAgentCenter(
                                "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-tmux processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=transport-failed failureType=\(String(describing: type(of: error)))"
                            )
                            return nil
                        }
                    }
                    do {
                        let output = try await session.executeAgentIntegrationProbeCommand(command)
                        let parsed = RemoteAgentLifecycleIntegrationInstaller.parseShellStatus(output)
                        let shellDiagnostic = RemoteAgentLifecycleIntegrationInstaller
                            .parseShellDiagnostic(output)?
                            .replacingOccurrences(of: " ", with: ",") ?? "missing"
                        DiagnosticLogStore.appendAgentCenter(
                            "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-ssh-sidecar processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=\(parsed.map(String.init) ?? "invalid-output") diagnostic=\(shellDiagnostic)"
                        )
                        return parsed
                    } catch {
                        DiagnosticLogStore.appendAgentCenter(
                            "shell-probe sid=\(liveSessionID.uuidString.prefix(8)) transport=mosh-ssh-sidecar processCount=\(processIDs.count) inheritedFallback=\(allowInheritedEnvironment) result=transport-failed failureType=\(String(describing: type(of: error)))"
                        )
                        return nil
                    }
                },
                sessionCommands: session.sessionCommands(tmux: tmux),
                rawSend: { bytes in session.sessionCommands.sendInput(bytes) },
                projectorExecAvailability: { binding, isCurrent in
                    AppleAgentLiveRouteFactory.execAvailability(
                        binding: binding,
                        moshSession: session,
                        moshControlChannel: tmuxControlBox.channel,
                        isBindingCurrent: isCurrent
                    )
                }
            )
            agentSourceRegistrationID = agentSource.registrationID
            agentCenterV2.registerSessionSource(
                agentSource,
                hostID: session.host.id,
                hostDisplayLabel: session.host.name.isEmpty ? session.host.address : session.host.name,
                profiles: { swipePadStore.profiles }
            )
            let sourceRegistrationID = agentSource.registrationID
            tmux.paneOutputObserver = { paneID, data in
                agentCenterV2.noteOutput(
                    sessionID: liveSessionID,
                    paneID: paneID.rawValue,
                    registrationID: sourceRegistrationID,
                    data: data
                )
            }
            tmux.paneAgentStateObserver = { paneID, json in
                agentCenterV2.noteLifecyclePayload(
                    sessionID: liveSessionID,
                    paneID: paneID.rawValue,
                    registrationID: sourceRegistrationID,
                    json: json
                )
            }
            tmux.inputObserver = nil

            var outputChunkCount = 0
            let sessionCommands = session.sessionCommands(tmux: tmux)
            let eventDiagnostics = SessionLatencyDiagnostics.queue(host: session.host.id, stage: "mosh-publication-to-terminal-consumer")
            terminalBox.bindLatencyDiagnostics(host: session.host.id)
            DiagnosticLogStore.appendSSH("latency-surface-v3 host=\(session.host.id.uuidString.prefix(8)) active=\(isActive) transport=mosh")
            let sessionEvents = sessionCommands.events(diagnostics: eventDiagnostics)
            sessionCommands.connect()
            let eventIterator = sessionEvents.mainActorDelivery(diagnostics: eventDiagnostics).makeAsyncIterator()
            while let event = await eventIterator.next() {
                switch event {
                case .stateChanged(_, let state):
                    sharedSessionState = state
                    if case .connecting = state {} else { sharedChallenge = nil }
                    continue
                case .tmuxSnapshotChanged(_, let snapshot):
                    sharedTmuxSnapshot = snapshot
                    continue
                case .gridAuthorityChanged:
                    // The controller's presentation is the only authority
                    // state the views read (S3′).
                    continue
                case .challenge(_, let challenge):
                    sharedChallenge = challenge
                    continue
                case .remoteWorkingDirectoryChanged(_, let path):
                    sharedRemoteWorkingDirectory = path
                    continue
                case .terminalBytes:
                    break
                case .forwardingStateChanged, .recoverableWarning, .failure,
                     .diagnostics, .commandCompleted, .destroyed:
                    continue
                }
                guard case .terminalBytes(_, let bytes, let receipt) = event else { continue }
                let chunk = Array(bytes)
                outputChunkCount += 1
                if outputChunkCount <= 12 || outputChunkCount == 25 || outputChunkCount == 50 {
                    MoshDiagnostics.log(
                        "mosh view output chunk#\(outputChunkCount) bytes=\(chunk.count)"
                    )
                }
                moshRenderLedgerAdapter.noteTransportOutputActivity(
                    deliveryID: receipt?.deliveryID,
                    repaintRequestID: receipt?.repaintRequestID,
                    byteCount: chunk.count,
                    readerSurfaceID: moshPaneScrollbackOverlay.map { moshOverlaySurfaceID($0.paneId) }
                )
                let outputLease = moshRenderLedgerAdapter.makeTransportOutputLease(
                    deliveryID: receipt?.deliveryID,
                    repaintRequestID: receipt?.repaintRequestID
                )
                let acceptsOutput = outputLease.acceptsNextSlice()
                let before = terminalScrollPosition(for: terminalBox.view)
                let ingressStartedAt = acceptsOutput
                    ? terminalBox.performanceDiagnostics.beginIngress(byteCount: chunk.count)
                    : nil
                let renderedFully: Bool
                if acceptsOutput {
                    renderedFully = await terminalBox.feedTerminalOutputCooperatively(
                        chunk[...],
                        context: .moshLive(originalByteCount: chunk.count),
                        shellIntegration: shellIntegration,
                        owner: outputLease.owner,
                        acceptsNextSlice: outputLease.acceptsNextSlice,
                        onYield: { eventIterator.consumerDidYield() }
                    )
                } else {
                    renderedFully = false
                    let requestDescription = receipt.flatMap(\.repaintRequestID).map { String($0) } ?? "nil"
                    let deliveryDescription = receipt.map { String($0.deliveryID) } ?? "nil"
                    // A rejection is rare and always worth its full painter
                    // state: owner, admission, handoff request/target/receipt,
                    // pending fences, and the recent painter events.
                    MoshDiagnostics.log(
                        "mosh view rejected transport frame request=\(requestDescription) delivery=\(deliveryDescription) adapter={\(moshRenderLedgerAdapter.painterStateForTesting)}"
                    )
                }
                if acceptsOutput && !renderedFully {
                    MoshDiagnostics.log("mosh view transport frame lease revoked during cooperative feed")
                }
                if let deliveryID = receipt?.deliveryID {
                    moshRenderLedgerAdapter.noteTransportOutputResult(
                        deliveryID: deliveryID,
                        repaintRequestID: receipt?.repaintRequestID,
                        renderedFully: renderedFully
                    )
                }
                if renderedFully, tmux.mode == .passthrough, !chunk.isEmpty {
                    agentCenterV2.noteOutput(
                        sessionID: liveSessionID,
                        paneID: nil,
                        registrationID: sourceRegistrationID,
                        data: chunk[...]
                    )
                }
                if renderedFully,
                   shouldRecordScrollDiagnostics,
                   let view = terminalBox.view,
                   shouldLogTerminalFeedScroll(before: before, after: terminalScrollPosition(for: view)) {
                    recordMoshScrollDiagnostic(
                        "surface=shared terminal-feed bytes=\(chunk.count) before=\(describeScrollPosition(before)) after=\(describeScrollPosition(for: view))"
                    )
                }
                scheduleSwipePadOutputActivityRefresh(reason: "mosh-output")
                if let ingressStartedAt {
                    terminalBox.performanceDiagnostics.endIngress(startedAt: ingressStartedAt)
                }

                // First non-empty chunk → the terminal has content to
                // show. Combined with `tmux.mode == .tmuxControl` (in
                // the tmux dismissal branch below) this guarantees the
                // surface we fade in is non-blank.
                if renderedFully && !chunk.isEmpty && !hasReceivedFirstOutput {
                    hasReceivedFirstOutput = true
                    maybeDismissLaunchOverlay(reason: "first-output")
                }
            }
            MoshDiagnostics.log("mosh view output stream ended")
        }
        .onChange(of: sharedSessionState) { _, sharedState in
            let newState = legacySessionState(from: sharedState)
            if newState == .connected {
                consumePendingPathInjection()
            }
            MoshDiagnostics.log(
                "mosh view state=\(MoshDiagnostics.stateDescription(newState))"
            )
            if newState == .disconnected {
                preservePendingPathAfterConnectionFailure()
                launchOverlayVisible = false
                stopTmuxControlChannel(primarySessionEnded: true)
                onSessionEnded()
            }

            if case .failed = newState {
                preservePendingPathAfterConnectionFailure()
                // Keep the overlay up to host the error state + recovery
                // actions (edit host / retry / back).
                stopTmuxControlChannel(primarySessionEnded: true)
                if session.recommendsReconnectAfterServerLoss {
                    // The overlay went away when the session first painted.
                    // A lost server ends it for good; unless ContentView
                    // rebuilds the session (which replaces this view), bring
                    // the reason and Retry back over the frozen screen.
                    launchOverlayVisible = true
                }
            }

            if case .connected = newState,
               shouldMaintainTmuxControlChannel,
               let sessionName = resolvedTmuxSessionName {
                startTmuxControlChannel(sessionName: sessionName)
            }

            // Plain mosh (`.customCommand`) has no further handshake
            // past `.connected`; dismiss as soon as we've got bytes.
            // Tmux modes wait for both `.connected + first output +
            // tmux control mode` (see `.onChange(of: tmux.mode)` below
            // and `maybeDismissLaunchOverlay`).
            maybeDismissLaunchOverlay(reason: "state=\(MoshDiagnostics.stateDescription(newState))")
        }
    }

    private var moshDecoratedTransport: some View {
        moshDecoratedConnectionTask
        .onChange(of: launchOverlayVisible) { _, visible in
            // Mirror "launch complete" into the shared registry so the
            // sidebar row can drop its connecting appearance — it can't
            // observe this view's local overlay state directly. See the
            // matching handler in the SSH `SessionView`.
            if !visible {
                sessionRegistry.markRenderReady(liveSessionID)
            }
        }
        .onChange(of: session.transportState) { _, newState in
            recordMoshScrollDiagnostic(
                "transport-state-changed state=\(newState.logDescription) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            MoshDiagnostics.log(
                "mosh view transport state=\(newState.logDescription)"
            )
            if newState != .connected {
                deactivateMoshScrollbackCapture(reason: "transport-\(newState.logDescription)")
            }
        }
        .onChange(of: tmux.activeWindowId) { _, newValue in
            reconcileAgentScrollNotice()
            recordMoshScrollDiagnostic(
                "tmux-window-changed window=\(newValue?.description ?? "nil") position=\(describeScrollPosition(for: terminalBox.view))"
            )
            guard let newValue else { return }
            _ = newValue
            resetMoshScrollbackCapture(clearLocal: false, reason: "window-change")
            declareMoshRenderSurfaces(reason: "window-change")
            requestMoshFindHistory(reason: "window-change")
        }
        .onChange(of: tmux.activePaneId) { oldPaneId, newPaneId in
            updateSwipePadAgentFocus()
            reconcileAgentScrollNotice()
            recordMoshScrollDiagnostic(
                "tmux-pane-changed old=\(oldPaneId?.description ?? "nil") new=\(newPaneId?.description ?? "nil") position=\(describeScrollPosition(for: terminalBox.view))"
            )
            rememberCurrentMoshPaneChromeSnapshot()
            if oldPaneId != newPaneId {
                if oldPaneId != nil {
                    let hadOverlay = moshPaneScrollbackOverlay != nil
                    resetMoshScrollbackCapture(clearLocal: !hadOverlay, reason: "pane-change")
                }
                declareMoshRenderSurfaces(reason: "pane-change")
                if newPaneId != nil { requestMoshFindHistory(reason: "pane-change") }
                if newPaneId != nil {
                    // Warm the alt-screen/mouse cache for the incoming pane
                    // so its first scroll routes semantically right away
                    // instead of parking points behind an interaction-probe
                    // round trip (felt as "first htop scroll does nothing").
                    tmux.queryActivePaneInteractionState { _ in }
                }
            }
            if newPaneId != nil,
               isPhone,
               isActive,
               appPhase.isActive,
               let viewport = lastCompactViewportSize {
                reprojectCompactMoshLayout(viewport)
            }
            // Magic-puck pane-awareness on the mosh path. The side-channel -CC
            // client tracks `activePaneId` from `%window-pane-changed`, and the
            // SwipePad resolver scopes its `pane_current_command`/`pane_pid`
            // query to it. A pane focus change (prefix keys / ⌘[] dispatched via
            // the side channel) carries no terminal output here — mosh paints
            // the split natively — so re-poll immediately so the puck follows
            // the focused pane. Bump directly to bypass the output cooldown.
            // Skip nil transitions (teardown / reset / reconnect): no pane to
            // scope to, and the side channel may already be torn down.
            guard swipePadSessionIsActive, newPaneId != nil else { return }
            swipePadOutputActivityToken &+= 1
            SwipePadDiagnostics.log(
                "output-activity session=mosh reason='pane-focus' token=\(swipePadOutputActivityToken)"
            )
        }
    }

    /// Grid-authority edges for input: a split of the chain below, which
    /// is otherwise past the type-checker's budget.
    private var moshAuthorityInput: some View {
        moshDecoratedTransport
        .onChange(of: tmux.gridAuthority) { _, _ in
            mirrorGridAuthorityInRegistry()
            // A path held through a resume that found a peer goes to the clipboard.
            consumePendingPathInjection()
        }
        .onChange(of: tmux.gridAuthorityPresentation) { _, _ in
            // A cancelled take-back changes neither the peer nor the input
            // gate, only why typing waits: a held path goes to the clipboard.
            consumePendingPathInjection()
        }
        .onChange(of: tmux.gridAuthorityAllowsInput) { _, allows in
            if allows {
                consumePendingPathInjection()
            } else {
                // Typing the gate now drops at apply time already sits in the
                // UIKit input mirror; later edits must not delete it remotely.
                terminalBox.noteOutOfBandInput()
            }
        }
    }

    private var moshDecoratedCore: some View {
        moshAuthorityInput
        .onChange(of: sharedChallenge != nil) { _, presented in
            // A password/OTP prompt is the user's step in progress: the
            // pending show or tap must not expire under it (R3).
            showEdges?.setChallengePresented(presented, for: liveSessionID)
        }
        .onDisappear {
            showEdges?.unregister(tmux, for: liveSessionID)
        }
        .onChange(of: isPhone) { _, compact in
            _ = session.sessionCommands(tmux: tmux).dispatch(
                .setTmuxGridPresentation(compact ? .singlePane : .paneGrid)
            )
            // Crossing the presentation boundary retires a visible iPad
            // reader before the topology switches. A phone must never leave
            // a detached overlay mounted above its sole live painter.
            resetMoshScrollbackCapture(
                clearLocal: false,
                reason: "compact-presentation-change"
            )
            declareMoshRenderSurfaces(reason: "compact-presentation-change")
        }
        .onChange(of: moshRenderLayout) { oldLayout, newLayout in
            guard oldLayout != newLayout else { return }
            if (newLayout?.paneCount ?? 1) > 1 {
                moshPaneChromeTopMaskActive = false
                moshPaneChromeCollapseMaskedPaneIds.removeAll()
                rememberCurrentMoshPaneChromeSnapshot()
            } else if (oldLayout?.paneCount ?? 1) > 1,
                      (newLayout?.paneCount ?? 1) <= 1 {
                showMoshPaneChromeCollapseMaskIfNeeded()
            }
            resetMoshScrollbackCapture(clearLocal: false, reason: "layout-change")
            // A tmux-side geometry change redraws the window into the
            // mosh-server PTY as a diff against tmux's own client model —
            // cells the local terminal shows differently (buffered attach
            // replay, restored continuity snapshot) but that tmux and mosh
            // both believe are current never get repainted, leaving stale
            // fragments on screen. One full frame from the mosh client's
            // framebuffer model resynchronizes the terminal; SSP diffs stay
            // consistent from there. (Same-size resumes never trigger the
            // resize path that would otherwise heal this as a side effect.)
            let suppressAuthorityDuplicate = authorityMoshRepaintLayoutToSuppress
                .map { $0 == newLayout } ?? false
            authorityMoshRepaintLayoutToSuppress = nil
            if !suppressAuthorityDuplicate {
                moshRenderLedgerAdapter.requestOwnedTransportFullFrame(
                    onScheduled: { _ in },
                    completion: { _ in }
                )
            }
            declareMoshRenderSurfaces(reason: "layout-change")
            requestMoshFindHistory(reason: "layout-change")
            if isPhone,
               isActive,
               appPhase.isActive,
               let viewport = lastCompactViewportSize {
                reprojectCompactMoshLayout(viewport)
            }
        }
        .onChange(of: findController.focusRequestToken) { _, _ in
            requestMoshFindHistory(reason: "find-open")
        }
        .onChange(of: findController.query) { _, newQuery in
            guard !newQuery.isEmpty else { return }
            requestMoshFindHistory(reason: "find-query")
        }
        .onChange(of: findController.isOpen) { _, isOpen in
            if !isOpen {
                moshPaneScrollbackOverlay?.box.view?.clearSearch()
            }
        }
        .onChange(of: isActive) { _, nowActive in
            DiagnosticLogStore.appendSSH("latency-surface-v3 host=\(session.host.id.uuidString.prefix(8)) active=\(nowActive) transport=mosh")
            recordMoshScrollDiagnostic(
                "active-changed active=\(nowActive) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            swipePadSessionIsActive = nowActive
            updateSwipePadAgentFocus()
            if !nowActive {
                agentScrollNotice.dismiss()
                terminalBox.dismissTransientInteractions()
                filesPanel.close()
            } else {
                reconcileAgentScrollNotice()
            }
            // Visibility first, so the controller's authority re-read is in
            // flight before the replayed size reaches it (M6).
            setMoshTmuxApplicationVisibility(isActive: nowActive && appPhase.isActive)
            if nowActive {
                if isPhone,
                   tmux.mode == .tmuxControl,
                   let viewport = lastCompactViewportSize {
                    pushCompactMoshViewport(viewport, force: true)
                } else if let size = lastTerminalSize {
                    session.sessionCommands(tmux: tmux).resize(
                        columns: size.cols,
                        rows: size.rows
                    )
                    tmuxControlBox.channel?.resize(cols: size.cols, rows: size.rows)
                }
            }
            if shouldMaintainTmuxControlChannel {
                if let sessionName = resolvedTmuxSessionName {
                    startTmuxControlChannel(sessionName: sessionName)
                }
            } else {
                stopTmuxControlChannel()
            }
            // Same recovery as the SSH view: an open panel whose bridge
            // idled out or dropped while this session was backgrounded
            // reconnects on return.
            if nowActive, filesPanel.isOpen,
               let bridge = filesPanel.bridge,
               bridge.state != .connected, bridge.state != .connecting {
                filesPanel.open()
            }
        }
        .onChange(of: appPhase.isActive) { _, nowForeground in
            guard isActive else { return }
            if !nowForeground {
                terminalBox.dismissTransientInteractions()
                setMoshTmuxApplicationVisibility(isActive: false)
                return
            }
            setMoshTmuxApplicationVisibility(isActive: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tesseraForceRefreshTerminal)) { _ in
            forceRefreshTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            terminalBox.dismissTransientInteractionsIfInterfaceOrientationChanged()
        }
        .onChange(of: agentCenterV2.presentation.listSnapshot) { _, _ in
            reconcileAgentScrollNotice()
        }
    }

    var body: some View {
        moshDecoratedCore
        .environment(\.terminalInputAllowed, authorityGatedTerminalInputAllowed)
        .environment(\.terminalKeyboardHandoff, commandPalette.keyboardHandoff)
        // P9: nothing under the veil draws once it has faded in (output is
        // still consumed).
        .modifier(ContinuedElsewhereDrawingGate(veiled: veilIsDrawn))
        .onAppear {
            #if DEBUG
            LiveScrollInitialRenderProbe.observe(
                sessionID: liveSessionID,
                isReady: tmux.isInitialRenderReady
            )
            #endif
        }
        .task(id: liveSessionID) {
            renderDropSummary.register(terminalBox)
            tmux.renderDropSummaryBoundary = { [renderDropSummary] boundary in
                renderDropSummary.record(boundary: boundary)
            }
            defer {
                renderDropSummary.record(boundary: "view-disappear")
                renderDropSummary.unregister(terminalBox)
                tmux.renderDropSummaryBoundary = nil
            }
            await renderDropSummary.runPeriodic()
        }
        .task(id: moshCwdPollKey) {
            await runMoshCwdPoll()
        }
        .onChange(of: session.remoteServerPID) { _, pid in
            handleRemoteServerPIDChange(pid)
        }
        .onChange(of: session.pendingPathInjection) { _, _ in
            consumePendingPathInjection()
        }
        .onChange(of: scrollDiagnosticsEnabled) { _, enabled in
            if enabled {
                recordMoshScrollDiagnostic(
                    "scroll-diagnostics-enabled position=\(describeScrollPosition(for: terminalBox.view))"
                )
            }
        }
        .onChange(of: appearance.scrollbackLines) { _, lines in
            guard tmux.mode == .tmuxControl else { return }
            tmux.submitRenderFact(.scrollbackLimit(lines: lines))
        }
        .onChange(of: tmux.mode) { _, newMode in
            recordMoshScrollDiagnostic(
                "tmux-mode-changed mode=\(newMode) position=\(describeScrollPosition(for: terminalBox.view))"
            )
            if case .tmuxControl = newMode {
                if session.host.launchMode == .autoTmux,
                   let name = resolvedTmuxSessionName {
                    HostRuntimeStateStore.recordSessionUsed(name, for: session.host)
                } else {
                    HostRuntimeStateStore.recordTmuxAvailable(for: session.host)
                }
            }
            // Tmux side-channel just engaged — the other half of the
            // tmux-mode dismissal pair (first-output is checked in the
            // bytes-receive loop above).
            maybeDismissLaunchOverlay(reason: "tmux.mode")
            if case .tmuxControl = newMode {
                // The side channel can become control-backed after SwiftUI
                // delivered the inactive edge. Keep using the shared command
                // facade: it preserves the controller's liveness bookkeeping
                // and submits the matching app-background fact to the render
                // ledger rather than mutating a terminal surface directly.
                if !appPhase.isActive {
                    setMoshTmuxApplicationVisibility(isActive: false)
                }
                if isPhone,
                   isActive,
                   appPhase.isActive,
                   let viewport = lastCompactViewportSize {
                    pushCompactMoshViewport(viewport, force: true)
                }
                declareMoshRenderSurfaces(reason: "tmux-mode")
                requestMoshFindHistory(reason: "tmux-mode")
            }
        }
        .onChange(of: tmux.lastPublishedClientSize) { _, _ in
            guard isPhone, isActive, appPhase.isActive,
                  tmux.mode == .tmuxControl,
                  let viewport = lastCompactViewportSize
            else { return }
            reprojectCompactMoshLayout(viewport)
        }
        .onChange(of: tmux.isInitialRenderReady) { _, isReady in
            #if DEBUG
            LiveScrollInitialRenderProbe.observe(
                sessionID: liveSessionID,
                isReady: isReady
            )
            #endif
        }
        .onDisappear {
            stopTmuxControlChannel()
            moshControlAttachWatchdog?.cancel()
            moshControlAttachWatchdog = nil
            swipePadOutputActivityTask?.cancel()
            swipePadOutputActivityTask = nil
        }
    }

    /// App visibility has controller-level liveness work in addition to the
    /// render-ledger fact, so Mosh must go through the shared facade instead
    /// of submitting a fact directly to an individual terminal surface.
    private func setMoshTmuxApplicationVisibility(isActive: Bool) {
        _ = session.sessionCommands(tmux: tmux).dispatch(
            .setApplicationVisibility(isActive ? .active : .background)
        )
    }

    /// Combined-signal dismissal for the launch overlay. Caller fires
    /// from every input that could have advanced the readiness state
    /// (presentationSessionState change, tmux.mode change, first output chunk);
    /// this method decides per launchMode whether we're now ready.
    ///
    ///   - `.customCommand`: ready when `.connected && hasReceivedFirstOutput`.
    ///   - tmux modes: ready when `.connected && hasReceivedFirstOutput
    ///     && tmux.mode == .tmuxControl`. We don't use
    ///     `tmux.isInitialRenderReady` because for side-channel control
    ///     it's set immediately on DCS — but the main mosh stream may
    ///     not have streamed any bytes yet, so we'd dismiss to an
    ///     empty terminal.
    private func maybeDismissLaunchOverlay(reason: String) {
        guard launchOverlayVisible else { return }
        guard presentationSessionState == .connected else { return }
        let ready: Bool
        switch session.host.launchMode {
        case .customCommand:
            ready = hasReceivedFirstOutput
        case .autoTmux, .pinnedTmux:
            ready = hasReceivedFirstOutput && tmux.mode == .tmuxControl
        }
        if ready {
            MoshDiagnostics.log("mosh launch overlay dismissed reason=\(reason)")
            moshControlAttachWatchdog?.cancel()
            moshControlAttachWatchdog = nil
            launchOverlayVisible = false
        } else if hasReceivedFirstOutput, session.host.launchMode != .customCommand {
            // The mosh stream is live and only the side-channel attach is
            // missing — bound that wait.
            armMoshControlAttachWatchdog()
        }
    }

    /// How long the overlay may wait on the side-channel attach once the
    /// main mosh stream is already painting. Inside the overlay's 12s stall
    /// notice so the automatic reveal wins over abandon-ship actions.
    private static let moshControlAttachRevealDelay: Duration = .seconds(10)

    private func armMoshControlAttachWatchdog() {
        guard moshControlAttachWatchdog == nil else { return }
        moshControlAttachWatchdog = Task { @MainActor in
            try? await Task.sleep(for: Self.moshControlAttachRevealDelay)
            guard !Task.isCancelled else { return }
            revealMoshLaunchOverlay(reason: "control-attach-timeout")
        }
    }

    /// Drop the launch shield onto the already-working plain-tmux terminal
    /// while the side channel keeps reconnecting behind it. Also the exit
    /// for a reconnect loop that ends `.degraded` with the overlay still up.
    private func revealMoshLaunchOverlay(reason: String) {
        moshControlAttachWatchdog?.cancel()
        moshControlAttachWatchdog = nil
        guard launchOverlayVisible, presentationSessionState == .connected,
              tmux.mode != .tmuxControl, hasReceivedFirstOutput
        else { return }
        MoshDiagnostics.log(
            "mosh launch overlay degraded-reveal reason=\(reason) sideChannel=\(tmuxSideChannelState.logDescription)"
        )
        launchOverlayVisible = false
    }

    /// The side channel lives as long as the session does — NOT as long as
    /// the user is looking at it.
    ///
    /// `isActive` means "this is the selected tab", not "this session is
    /// alive"; the SSH view's own comment says so. But for mosh this is the
    /// session's ONLY control connection: tmux window/pane metadata,
    /// capture-pane scrollback synthesis, and the host's port forwarding all
    /// ride it. Gating it on `isActive` meant switching to another tab logged
    /// the mosh session's TCP control as disconnected, stopped its forwarded
    /// ports mid-use, and made switching back pay a fresh SSH connect, a tmux
    /// re-attach and a render-ledger epoch change — one to two seconds, on
    /// every switch.
    ///
    /// Neither sibling ever did this. SSH+tmux carries `-CC` on its primary
    /// connection and keeps it through a switch, and the Android twin cancels
    /// its side channel only in `teardownTransport` / `clearMoshAttemptTransport`
    /// — when the transport itself goes. Not paying for a hidden session is
    /// the renderer's job (inactive sessions already stop rasterizing), not
    /// the transport's.
    private var shouldMaintainTmuxControlChannel: Bool {
        MoshSideChannelLifetime.shouldMaintain(
            launchMode: session.host.launchMode,
            isConnected: presentationSessionState == .connected
        )
    }

    private var isTmuxDegraded: Bool {
        presentationSessionState == .connected && tmuxSideChannelState.isControlUnavailable
    }

    private var moshTcpControlStatus: MoshTcpControlStatus? {
        session.host.launchMode == .customCommand
            ? nil
            : tmuxSideChannelState.tcpControlStatus
    }

    /// Mirror of `SessionView.handleSwitcherShortcut` — see the SSH path
    /// for the same code shape. Kept in the mosh struct because the
    /// closure body needs access to this view's `liveSessionID` /
    /// environment objects.
    private func handleSwitcherShortcut(_ shortcut: TesseraSwitcherShortcut) {
        switch shortcut {
        case .openPalette:
            commandPalette.open(
                sessions: sessionRegistry.activeSessions,
                lastTouched: sessionRegistry.lastTouched
            )
        case .cyclePrevious, .cycleNext:
            // Immediate switch to the neighbouring session in sidebar
            // order, wrapping at both ends. No HUD or settle timer — the
            // terminal content changing is the feedback, and this reuses
            // the same `onSelectSession` path the palette commits through.
            let direction: SessionSwitchDirection =
                shortcut == .cyclePrevious ? .previous : .next
            if let target = SessionSwitcher.step(
                order: sessionRegistry.activeSessions.map(\.id),
                from: liveSessionID,
                direction: direction
            ) {
                onSelectSession(target)
            }
        }
    }

    private var activeAgentScrollPaneID: Int? {
        tmux.mode == .tmuxControl ? tmux.activePaneId?.rawValue : nil
    }

    private func agentScrollPrevention(paneID: Int?) -> AgentScrollPrevention? {
        agentCenterV2.scrollPrevention(
            sessionID: liveSessionID,
            paneID: paneID,
            claudeCodeEnabled: appearance.agentScrollLockClaudeCodeEnabled,
            codexEnabled: appearance.agentScrollLockCodexEnabled
        )
    }

    private func presentAgentScrollPrevention(paneID: Int?) {
        guard isActive, let prevention = agentScrollPrevention(paneID: paneID) else {
            return
        }
        appLockController.notifyUserActivity()
        agentScrollNotice.show(prevention)
        let paneLabel = paneID.map(String.init) ?? "raw"
        let provider = prevention.agentName == "Codex" ? "codex" : "claude"
        DiagnosticLogStore.appendAgentCenter(
            "scroll-blocked sid=\(String(liveSessionID.uuidString.prefix(8))) pane=\(paneLabel) provider=\(provider)"
        )
    }

    private func reconcileAgentScrollNotice() {
        guard let shown = agentScrollNotice.prevention else { return }
        let current = agentScrollPrevention(paneID: shown.agentID.paneID)
        if current != shown || !isActive || !agentScrollSurfaceIsVisible(shown.agentID) {
            agentScrollNotice.dismiss()
        }
    }

    private func agentScrollSurfaceIsVisible(_ id: AgentInstanceID) -> Bool {
        guard id.sessionID == liveSessionID else { return false }
        guard tmux.mode == .tmuxControl else { return id.paneID == nil }
        return id.paneID == tmux.activePaneId?.rawValue
    }

    /// Report the terminal surface the user is looking at to Agent Center's
    /// SwipePad projection: the focused tmux pane, or a nil pane for a raw
    /// screen. Equality-gated on the other side, so calling on every focus
    /// signal is free.
    private func updateSwipePadAgentFocus() {
        guard isActive else {
            agentCenterV2.clearSwipePadFocus(sessionID: liveSessionID)
            return
        }
        if tmux.mode == .tmuxControl {
            if let paneID = tmux.activePaneId {
                agentCenterV2.setSwipePadFocus(sessionID: liveSessionID, paneID: paneID.rawValue)
            } else {
                // No active pane (window teardown / mid-hydration): clear
                // rather than keep the departed pane's focus — a stale
                // fireable snapshot could route a macro into whatever pane
                // tmux has foreground, and mosh sends have no pane guard.
                agentCenterV2.clearSwipePadFocus(sessionID: liveSessionID)
            }
        } else {
            agentCenterV2.setSwipePadFocus(sessionID: liveSessionID, paneID: nil)
        }
    }

    private func scheduleSwipePadOutputActivityRefresh(reason: String) {
        guard swipePadSessionIsActive else { return }
        guard swipePadOutputActivityTask == nil else { return }

        swipePadOutputActivityTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            swipePadOutputActivityToken &+= 1
            SwipePadDiagnostics.log(
                "output-activity session=mosh reason='\(reason)' token=\(swipePadOutputActivityToken)"
            )

            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            swipePadOutputActivityTask = nil
        }
    }

    private var shouldRecordScrollDiagnostics: Bool {
        scrollDiagnosticsEnabled || DiagnosticLogStore.isScrollDiagnosticsEnabled
    }

    private func recordMoshScrollDiagnostic(_ message: String) {
        guard shouldRecordScrollDiagnostics else { return }
        scrollDiagnostics.sequence += 1
        let context = [
            "mosh",
            "seq=\(scrollDiagnostics.sequence)",
            "state=\(MoshDiagnostics.stateDescription(presentationSessionState))",
            "transport=\(session.transportState.logDescription)",
            "mode=\(tmux.mode)",
            "window=\(tmux.activeWindowId?.description ?? "nil")",
            "pane=\(tmux.activePaneId?.description ?? "nil")",
        ].joined(separator: " ")
        DiagnosticLogStore.appendScroll("\(context) \(message)")
    }

    private func terminalScrollPosition(for view: TerminalView?) -> TerminalScrollPosition? {
        guard let view else { return nil }
        let terminal = view.getTerminal()
        return TerminalScrollPosition(
            offsetY: view.contentOffset.y,
            maxOffsetY: max(0, view.contentSize.height - view.bounds.height),
            contentHeight: view.contentSize.height,
            boundsHeight: view.bounds.height,
            isAltScreen: terminal.isCurrentBufferAlternate,
            mouseMode: String(describing: terminal.mouseMode)
        )
    }

    private func describeScrollPosition(for view: TerminalView?) -> String {
        describeScrollPosition(terminalScrollPosition(for: view))
    }

    private func describeScrollPosition(_ position: TerminalScrollPosition?) -> String {
        guard let position else { return "nil" }
        return "off=\(Self.format(position.offsetY))/\(Self.format(position.maxOffsetY)) content=\(Self.format(position.contentHeight)) bounds=\(Self.format(position.boundsHeight)) bottom=\(position.isAtBottom) alt=\(position.isAltScreen) mouse=\(position.mouseMode)"
    }

    private func shouldLogTerminalFeedScroll(
        before: TerminalScrollPosition?,
        after: TerminalScrollPosition?
    ) -> Bool {
        guard let after else { return false }
        guard let before else { return !after.isAtBottom }
        return !before.isAtBottom
            || !after.isAtBottom
            || abs(before.offsetY - after.offsetY) > 0.5
            || abs(before.maxOffsetY - after.maxOffsetY) > 0.5
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func startTmuxControlChannel(sessionName: String) {
        guard tmuxControlTask == nil else { return }
        rememberMoshPaneChromeSnapshot()
        tmux.gridAuthorityOwnerSessionName = sessionName
        tmuxControlGeneration += 1
        let generation = tmuxControlGeneration
        MoshDiagnostics.log(
            "mosh tmux sidechannel reconnect loop start generation=\(generation) session=\(sessionName) state=\(MoshDiagnostics.stateDescription(presentationSessionState))"
        )
        resetMoshScrollbackCapture(clearLocal: false, reason: "sidechannel-start")
        // The primary mosh painter is still alive. Keep surface declarations
        // and prior owners so entering the replacement side channel emits a
        // fresh-epoch bind (the only authority allowed to clear the painter).
        tmux.sideChannelDisconnected()
        tmuxSideChannelState = .connecting(attempt: 1)

        tmuxControlTask?.cancel()
        tmuxControlTask = Task { @MainActor in
            await runTmuxControlReconnectLoop(
                sessionName: sessionName,
                generation: generation
            )
        }
    }

    private func runTmuxControlReconnectLoop(
        sessionName: String,
        generation: Int
    ) async {
        var reconnectAttempt = 0
        var lastReason: String?

        while !Task.isCancelled && tmuxControlGeneration == generation {
            guard shouldMaintainTmuxControlChannel else {
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop stop generation=\(generation) session=\(sessionName) active=\(isActive) overlay=\(launchOverlayVisible) state=\(MoshDiagnostics.stateDescription(presentationSessionState))"
                )
                break
            }

            if reconnectAttempt > 0 || lastReason != nil {
                tmuxSideChannelState = .reconnecting(
                    lastError: lastReason,
                    retryAttempt: max(reconnectAttempt, 1),
                    nextRetryDelay: nil
                )
            } else {
                tmuxSideChannelState = .connecting(attempt: 1)
            }

            let channel = TmuxControlChannel(
                host: session.host,
                requireBiometric: session.requireBiometric,
                isSecureEnclave: session.isSecureEnclave,
                sessionName: sessionName,
                initialSize: lastTerminalSize,
                preserveTmuxGeometry: session.preserveTmuxGeometry,
                preservedServerSize: session.preservedRemoteTmuxSize,
                portForwarderManager: session.portForwarderManager,
                portForwardRules: session.host.portForwardRules
            )
            tmuxControlBox.channel = channel
            MoshDiagnostics.log(
                "mosh tmux sidechannel reconnect attempt start generation=\(generation) sessionNameLength=\(sessionName.count) attempt=\(max(reconnectAttempt, 1)) state=\(tmuxSideChannelState.logDescription)"
            )
            let retryWakeGeneration = ConnectivityRetryWake.shared.generation
            channel.connect()
            var sawOutput = false
            var sawControlMode = false
            var chunkCount = 0
            for await chunk in channel.outputStream.mainActorDelivery(diagnostics: channel.outputQueueDiagnostics) {
                chunkCount += 1
                if chunkCount <= 4 {
                    MoshDiagnostics.log(
                        "mosh tmux sidechannel view chunk#\(chunkCount) bytes=\(chunk.count)"
                    )
                }
                if !sawOutput {
                    sawOutput = true
                }
                let previousMode = tmux.mode
                let previousWindow = tmux.activeWindowId
                let previousPane = tmux.activePaneId
                tmux.ingest(chunk)
                if previousMode != tmux.mode
                    || previousWindow != tmux.activeWindowId
                    || previousPane != tmux.activePaneId {
                    SwipePadDiagnostics.log(
                        "mosh-sidechannel tmux-state mode \(previousMode)->\(tmux.mode) window \(String(describing: previousWindow))->\(String(describing: tmux.activeWindowId)) pane \(String(describing: previousPane))->\(String(describing: tmux.activePaneId))"
                    )
                }
                if !sawControlMode, case .tmuxControl = tmux.mode {
                    sawControlMode = true
                    reconnectAttempt = 0
                    lastReason = nil
                    if tmuxControlBox.channel === channel {
                        tmuxSideChannelState = .connected
                    }
                    MoshDiagnostics.log(
                        "mosh tmux sidechannel reconnect control-mode-entered generation=\(generation) session=\(sessionName)"
                    )
                    MoshDiagnostics.log(
                        "mosh tmux sidechannel reconnect state=connected generation=\(generation) session=\(sessionName)"
                    )
                }
            }
            MoshDiagnostics.log(
                "mosh tmux sidechannel reconnect stream ended generation=\(generation) session=\(sessionName) sawOutput=\(sawOutput) sawControlMode=\(sawControlMode) chunks=\(chunkCount) sessionState=\(MoshDiagnostics.stateDescription(presentationSessionState)) reason=\(channel.terminationReason?.logDescription ?? "unknown")"
            )

            if tmuxControlBox.channel === channel {
                tmuxControlBox.channel = nil
                // Drain BEFORE the exit guards below: pending command
                // completions die with this stream. Breaking out on
                // cancel / generation-swap / degraded without draining
                // left them queued forever — a scrollback fetch stayed
                // "in-flight" and blocked every refetch on that pane,
                // and a later stream's replies dequeued against the
                // wrong commands (FIFO misalignment).
                tmux.sideChannelDisconnected()
            }

            guard !Task.isCancelled && tmuxControlGeneration == generation else { break }
            guard shouldMaintainTmuxControlChannel else { break }

            reconnectAttempt += 1
            let delay = Self.tmuxReconnectDelay(for: reconnectAttempt)
            lastReason = channel.terminationReason?.userFacingDescription
                ?? "control connection closed"
            tmuxSideChannelState = .reconnecting(
                lastError: lastReason,
                retryAttempt: reconnectAttempt,
                nextRetryDelay: delay
            )
            MoshDiagnostics.log(
                "mosh tmux sidechannel reconnect scheduled generation=\(generation) session=\(sessionName) attempt=\(reconnectAttempt) backoff=\(Self.formatDelay(delay)) reason=\(lastReason ?? "unknown") sawOutput=\(sawOutput) sawControlMode=\(sawControlMode)"
            )

            // A path change or a return to the foreground since this attempt
            // started ends the wait: the backoff otherwise outlives the cause,
            // and a timer frozen by suspension resumes where it stopped.
            let wake = await ConnectivityRetryWake.shared.sleep(
                seconds: delay,
                unlessSignalledSince: retryWakeGeneration
            )
            guard wake != .cancelled, !Task.isCancelled else { break }
            if wake == .signalled {
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect woke early generation=\(generation) attempt=\(reconnectAttempt)"
                )
            }
        }

        if tmuxControlGeneration == generation {
            tmuxControlTask = nil
            tmuxControlBox.channel = nil
            if Task.isCancelled {
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop cancelled generation=\(generation) session=\(sessionName)"
                )
            } else if presentationSessionState == .connected && isActive {
                tmuxSideChannelState = .degraded(lastError: lastReason)
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop ended degraded generation=\(generation) session=\(sessionName) reason=\(lastReason ?? "unknown")"
                )
                // The loop gave up while the launch shield could still be
                // waiting on control mode — reveal the working terminal
                // rather than leaving the spinner to the stall notice.
                revealMoshLaunchOverlay(reason: "sidechannel-degraded")
            } else {
                tmuxSideChannelState = .idle
                tmux.sideChannelDisconnected()
                MoshDiagnostics.log(
                    "mosh tmux sidechannel reconnect loop ended idle generation=\(generation) session=\(sessionName)"
                )
            }
        }
    }

    private func stopTmuxControlChannel(primarySessionEnded: Bool = false) {
        rememberMoshPaneChromeSnapshot()
        if tmuxControlBox.channel != nil || tmuxControlTask != nil {
            MoshDiagnostics.log(
                "mosh tmux sidechannel view stop state=\(MoshDiagnostics.stateDescription(presentationSessionState))"
            )
        }
        tmuxControlGeneration += 1
        tmuxControlTask?.cancel()
        tmuxControlTask = nil
        tmuxControlBox.channel?.disconnect()
        tmuxControlBox.channel = nil
        tmuxShortcutToastTask?.cancel()
        tmuxShortcutToastTask = nil
        tmuxShortcutToastVisible = false
        tmuxSideChannelState = .idle
        deactivateMoshScrollbackCapture(reason: "sidechannel-stop")
        if primarySessionEnded {
            // Only the primary terminal dying invalidates the physical mosh
            // painter and all retained side-channel identity.
            tmux.reset()
        } else {
            // A temporary background/navigation/control-channel gap keeps the
            // ledger declarations and owners. Reattach allocates a new epoch
            // and binds it before any fresh capture can feed the same pane.
            tmux.sideChannelDisconnected()
        }
    }

    private func handleTmuxShortcut(_ shortcut: TesseraTmuxShortcut) {
        if shouldBlockTmuxShortcut {
            showTmuxShortcutBlockedToast(shortcut: shortcut)
            return
        }

        invalidateMoshScrollbackForTerminalInput(reason: "tmux-shortcut")
        let commands = session.sessionCommands(tmux: tmux)
        switch shortcut {
        case .newWindow:
            _ = commands.dispatch(.createTmuxWindow)
        case .killCurrentWindow:
            // Contextual kill: pane when split, else window. Mosh dispatches
            // pane commands over the side channel like the others.
            if (moshActiveWindow?.paneCount ?? 1) > 1 {
                guard let paneID = tmux.activePaneId else { return }
                _ = commands.dispatch(.closeTmuxPane(paneID.description))
            } else if let windowID = tmux.activeWindowId {
                _ = commands.dispatch(.closeTmuxWindow(windowID.description))
            }
        case .previousWindow:
            guard let windowID = tmux.snapshot.adjacentWindowID(offset: -1) else { return }
            _ = commands.dispatch(.selectTmuxWindow(windowID.description))
        case .nextWindow:
            guard let windowID = tmux.snapshot.adjacentWindowID(offset: 1) else { return }
            _ = commands.dispatch(.selectTmuxWindow(windowID.description))
        case .moveWindowLeft, .moveWindowRight:
            guard let windowID = tmux.activeWindowId else { return }
            _ = commands.dispatch(.moveTmuxWindow(windowID.description, move: .relative(
                { if case .moveWindowLeft = shortcut { return .previous }; return .next }()
            )))
        case .selectWindow(let position):
            let windowID = position == 9
                ? tmux.snapshot.windows.last?.id
                : tmux.snapshot.windowID(atPosition: position)
            guard let windowID else { return }
            _ = commands.dispatch(.selectTmuxWindow(windowID.description))
        case .splitPaneHorizontal:
            showMoshPaneChromeTopMask()
            guard let paneID = tmux.activePaneId else { return }
            _ = commands.dispatch(.splitTmuxPane(paneID.description, axis: .horizontal, before: false))
        case .splitPaneVertical:
            showMoshPaneChromeTopMask()
            guard let paneID = tmux.activePaneId else { return }
            _ = commands.dispatch(.splitTmuxPane(paneID.description, axis: .vertical, before: false))
        case .cyclePaneNext:
            _ = commands.dispatch(.cycleTmuxPane(forward: true))
        case .cyclePanePrevious:
            _ = commands.dispatch(.cycleTmuxPane(forward: false))
        case .zoomPane:
            guard let paneID = tmux.activePaneId else { return }
            _ = commands.dispatch(.setTmuxPaneZoomed(
                paneID.description,
                zoomed: !(moshActiveWindow?.isZoomed ?? false)
            ))
        }
    }

    private var moshActiveWindow: TmuxController.WindowInfo? {
        guard let id = tmux.activeWindowId else { return nil }
        return tmux.windows.first(where: { $0.id == id })
    }

    /// Foreground command of the focused tmux pane, for program-scoped custom
    /// shortcuts. nil in passthrough: there is no cheap process source without
    /// tmux, and `ShortcutScopeEvaluator` deliberately fails closed rather than
    /// firing a scoped shortcut into an unknown shell.
    private var activePaneCurrentCommand: String? {
        guard tmux.mode != .passthrough, let paneID = tmux.activePaneId else { return nil }
        for window in tmux.windows {
            if let pane = window.panes.first(where: { $0.id == paneID }) {
                return pane.currentCommand
            }
        }
        return nil
    }

    /// Whether a user-defined shortcut applies to this session right now.
    /// Extracted from the call site so the enclosing view body stays inside
    /// the type checker's budget.
    private func shouldFire(_ shortcut: CustomShortcut) -> Bool {
        ShortcutScopeEvaluator.applies(
            shortcut.scope,
            hostID: session.host.id,
            processName: activePaneCurrentCommand
        )
    }

    private var compactMoshLayout: WindowLayout? {
        guard let window = moshActiveWindow else { return nil }
        return window.isZoomed
            ? (window.visibleLayout ?? window.layout)
            : window.layout
    }

    private var compactMoshWindowRect: CellRect? {
        guard isPhone, tmux.mode == .tmuxControl else { return nil }
        return compactMoshLayout?.root.rect
            ?? moshActiveWindow?.panes.first?.contentRect
    }

    private var compactMoshFocusRect: CellRect? {
        guard let window = moshActiveWindow,
              let paneID = window.activePaneId ?? tmux.activePaneId
        else { return compactMoshWindowRect }
        return compactMoshLayout?.leaves.first(where: { $0.paneId == paneID })?.rect
            ?? window.panes.first(where: { $0.id == paneID })?.contentRect
            ?? compactMoshWindowRect
    }

    /// The tree the compact canvas is solved against, under the same
    /// conditions as `compactMoshWindowRect`.
    private var compactMoshSizingLayout: WindowLayout? {
        guard isPhone, tmux.mode == .tmuxControl else { return nil }
        return compactMoshLayout
    }

    private var compactMoshFocusPaneID: PaneId? {
        guard let window = moshActiveWindow else { return nil }
        return window.activePaneId ?? tmux.activePaneId
    }

    private var compactMoshCellSize: CGSize {
        if let moshCellSize { return moshCellSize }
        let font = TerminalFontResolver.uiFont(
            id: appearance.terminalFontID,
            size: CGFloat(appearance.fontSize)
        )
        return TerminalCellMetrics.cellSize(font: font, scale: UIScreen.main.scale)
    }

    private func updateCompactMoshViewport(_ size: CGSize) {
        guard isPhone,
              let viewport = CompactTmuxClientSizing.viewportCells(
                for: size,
                cellSize: compactMoshCellSize
              )
        else { return }
        let previousViewport = lastCompactViewportSize
        lastCompactViewportSize = viewport
        guard isActive, appPhase.isActive,
              CompactTmuxClientSizing.shouldAdvertiseMeasuredViewport(
                viewport,
                previousViewport: previousViewport,
                lastClientSize: tmux.lastPublishedClientSize.map { ($0.columns, $0.rows) },
                layout: compactMoshSizingLayout,
                focusPaneId: compactMoshFocusPaneID,
                windowRect: compactMoshWindowRect,
                focusRect: compactMoshFocusRect,
                memo: &compactReprojectionMemo,
                diagnostics: .mosh
              )
        else { return }
        pushCompactMoshViewport(viewport)
    }

    /// A layout-driven reprojection: advertises only when the shared
    /// decision allows it (the peer rules and the cycle guard).
    private func reprojectCompactMoshLayout(_ viewport: (cols: Int, rows: Int)) {
        guard CompactTmuxClientSizing.shouldReprojectLayout(
            viewport: viewport,
            lastClientSize: tmux.lastPublishedClientSize.map { ($0.columns, $0.rows) },
            layout: compactMoshSizingLayout,
            focusPaneId: compactMoshFocusPaneID,
            windowRect: compactMoshWindowRect,
            focusRect: compactMoshFocusRect,
            memo: &compactReprojectionMemo,
            diagnostics: .mosh
        ) else { return }
        pushCompactMoshViewport(viewport)
    }

    private func pushCompactMoshViewport(
        _ viewport: (cols: Int, rows: Int),
        force: Bool = false
    ) {
        let client = CompactTmuxClientSizing.clientSize(
            for: viewport,
            layout: compactMoshSizingLayout,
            focusPaneId: compactMoshFocusPaneID,
            windowRect: compactMoshWindowRect,
            focusRect: compactMoshFocusRect
        )
        // A forced replay (activation, foreground, refresh) is a fresh start:
        // a layout update cannot cause one, so it cannot feed a cycle.
        if force {
            compactReprojectionMemo = TmuxCompactReprojectionMemo()
        }
        if !force,
           let lastCompactRequestedClientSize,
           lastCompactRequestedClientSize.cols == client.cols,
           lastCompactRequestedClientSize.rows == client.rows {
            return
        }
        if let previous = lastTerminalSize,
           previous.cols != client.cols || previous.rows != client.rows {
            resetMoshScrollbackCapture(clearLocal: true, reason: "compact-viewport-resize")
        }
        lastCompactRequestedClientSize = client
        lastTerminalSize = client
        session.sessionCommands(tmux: tmux).resize(columns: client.cols, rows: client.rows)
        tmuxControlBox.channel?.resize(cols: client.cols, rows: client.rows)
    }

    /// Repaint the visible mosh terminal from its framebuffer model. Mosh's
    /// full-frame emission is the authoritative refresh for both plain mosh
    /// and mosh+tmux; replaying the current size first also preserves the
    /// compact viewport geometry used by the side channel.
    private func forceRefreshTerminal() {
        guard isActive, appPhase.isActive, presentationSessionState == .connected else { return }
        appLockController.notifyUserActivity()
        terminalBox.forceRedraw()

        if isPhone, let viewport = lastCompactViewportSize {
            pushCompactMoshViewport(viewport, force: true)
        } else if let size = lastTerminalSize {
            session.sessionCommands(tmux: tmux).resize(columns: size.cols, rows: size.rows)
            tmuxControlBox.channel?.resize(cols: size.cols, rows: size.rows)
        }
        if tmux.mode == .tmuxControl {
            // D9: a mosh framebuffer repaint while this device may render,
            // nothing while yielded; never a claim (no stamp, no window
            // force). Control moves only on a show or a veil gesture.
            _ = session.sessionCommands(tmux: tmux).dispatch(.claimTmuxGridAuthority(
                reason: .forceRefresh,
                repaintEvenIfSame: true
            ))
        } else {
            // Plain mosh has no tmux claim callback to request the frame.
            session.forceFullRepaint()
        }
    }

    private func retireVisibleMoshHistoryForAuthoritativeRepaint() {
        let hadLiveHistory = moshLiveHistoryRevealed || pendingMoshLiveHistoryPresentation != nil
        cancelPendingMoshLiveHistoryPresentation(reason: "authority-repaint")
        if hadLiveHistory || moshLiveHistoryRevealed {
            moshLiveHistoryRevealed = false
            tmux.submitRenderFact(.scrollbackReturnedToTail(.live))
        }
        if moshPaneScrollbackOverlay != nil {
            dismissMoshPaneScrollbackOverlay(
                clearDepth: false,
                reason: "authority-repaint",
                returnedToTail: true
            )
        }
    }

    /// Take back the shared tmux grid from the device that continued this
    /// session. The controller restamps authority and replays our size over
    /// the side channel; the resulting `%layout-change` already drives the
    /// mosh full-repaint resync, and a same-grid reclaim needs neither.
    private func takeBackContinuedSession() {
        // D8: a hidden session's veil stays mounted and a locked app keeps
        // ContentView mounted; neither may reclaim the grid.
        guard ContinuedElsewhereKeyPolicy.admitsGesture(
            sessionIsActive: isActive,
            appIsLocked: appLockController.isLocked
        ) else { return }
        appLockController.notifyUserActivity()
        // Idempotence lives in the shared reducer: a tap during a visible
        // claim is a no-op, and a tap while the control channel is down
        // becomes an intent that claims after the next attach (R4).
        _ = session.sessionCommands(tmux: tmux).dispatch(
            .reclaimTmuxGridAuthority(reason: .user)
        )
    }

    /// Cancels a show or tap that is waiting for the connection, as its R3
    /// expiry would. Not a hide: the session stays displayed, so a peer
    /// that holds the grid is drawn as the tappable veil.
    private func cancelPendingGridAuthorityIntent() {
        appLockController.notifyUserActivity()
        tmux.cancelGridAuthorityIntent()
    }

    /// Registers this session's controller for show/hide edges (S2′) and
    /// mirrors its password/OTP prompt into the intent clock pause.
    private func registerGridAuthorityShowTarget() {
        showEdges?.register(tmux, for: liveSessionID)
        showEdges?.setChallengePresented(sharedChallenge != nil, for: liveSessionID)
    }

    /// The inherited lock gate plus the grid-authority gate (same as the
    /// inline SSH path). Mosh's own input layer checks the same
    /// presentation before any byte reaches the UDP stream.
    private var authorityGatedTerminalInputAllowed: () -> Bool {
        let inherited = inheritedTerminalInputAllowed
        return { [tmux] in inherited() && tmux.gridAuthorityAllowsInput }
    }

    /// Keep the sidebar's last-known continuation marker through a mosh
    /// side-channel reconnect. `.unknown` only means the observer is between
    /// control connections; `.mine` or removal of the live session clears it.
    private func mirrorGridAuthorityInRegistry() {
        switch tmux.gridAuthority {
        case .peer(let displayName):
            sessionRegistry.setGridAuthorityPeerName(displayName, for: liveSessionID)
        case .mine:
            sessionRegistry.setGridAuthorityPeerName(nil, for: liveSessionID)
        case .unknown:
            break
        }
    }

    private func handleCompactTmuxFocusRequest() {
        sessionRegistry.handleTmuxFocusRequest(
            sessionID: liveSessionID, carrier: session, tmux: tmux,
            commands: session.sessionCommands(tmux: tmux), isShown: isActive)
    }

    /// Whether the mosh active window has a real multi-pane layout — gates the
    /// bare ⌘[/⌘] pane-cycle and ⌘⇧Return zoom chords on the mosh shared
    /// surface (the chord-only focus story; mosh paints splits natively).
    /// Extracted from the `TerminalSurfaceBound` call site so the SwiftUI body
    /// type-checks (an inline optional-chain there blows the complexity budget).
    private var moshPaneCycleEnabled: Bool {
        moshActiveWindow?.rendersAsPaneGrid ?? false
    }

    /// Whether the active pane's program asked for the mouse. The mode
    /// reaches this surface only through the visible tmux client, and can be
    /// missing there (a user's session showed none while Claude Code's pane
    /// asked for the mouse), so clicks would otherwise never reach it. Never
    /// while revealed history is on screen: its taps fall through to the
    /// live surface, and must not drive a program hidden beneath it.
    private var moshActivePaneReportsMouse: Bool {
        guard tmux.mode == .tmuxControl,
              !moshRemoteHistoryRevealed,
              let window = moshActiveWindow,
              let paneID = window.activePaneId ?? tmux.activePaneId
        else { return false }
        return window.panes.first(where: { $0.id == paneID })?.isMouseReporting == true
    }

    /// mosh relays only the visible screen, so the local scroll view holds
    /// none of the pane's tmux history. Finger pans therefore take the
    /// trackpad's route in every state: the primary-scroll hook fetches and
    /// deepens tmux history, scrolls what it revealed, returns it to the tail,
    /// and forwards a full-screen pane's scroll to its program. The native
    /// pan would only move the empty local scroll view.
    private var moshTouchPansTakePointerRoute: Bool {
        tmux.mode == .tmuxControl && session.host.launchMode != .customCommand
    }

    /// Fetched tmux history covers the focused pane: the detached overlay of
    /// a split, or the live surface itself on compact layouts. Input must not
    /// reach the program hidden beneath it. A reader of another pane leaves
    /// the focused pane's clicks alone.
    private var moshRemoteHistoryRevealed: Bool {
        MoshHistorySurfacePolicy.historyCoversFocusedPane(
            liveHistoryRevealed: moshLiveHistoryRevealed,
            overlayContentReady: moshOverlayContentReadyId != nil,
            readyOverlay: moshPaneScrollbackOverlay.flatMap { overlay in
                overlay.id == moshOverlayContentReadyId ? (overlay.windowId, overlay.paneId) : nil
            },
            windowID: moshActiveWindow?.id,
            focusedPaneID: moshActiveWindow?.activePaneId ?? tmux.activePaneId
        )
    }

    private func moshPrimaryTouchScrollIsLocal(paneID: PaneId?) -> Bool? {
        // History revealed on this surface scrolls locally, even under a
        // pane that went full-screen while it was read.
        if moshLiveHistoryRevealed { return true }
        guard tmux.mode == .tmuxControl,
              let window = moshActiveWindow,
              let paneID = paneID ?? window.activePaneId ?? tmux.activePaneId
        else { return nil }
        if let overlay = moshPaneScrollbackOverlay,
           overlay.windowId == window.id,
           overlay.paneId == paneID,
           moshOverlayContentReadyId == overlay.id {
            return true
        }
        guard let alternate = window.panes.first(where: { $0.id == paneID })?.isAlternateScreen
        else { return nil }
        return !alternate
    }

    private func moshPaneChromeSnapshot() -> MoshPaneChromeSnapshot? {
        if let current = currentMoshPaneChromeSnapshot() {
            return current
        }
        if case .tmuxControl = tmux.mode,
           moshActiveWindow != nil {
            return nil
        }
        return lastMoshPaneChromeSnapshot
    }

    private var shouldShowMoshPaneChromeTopMask: Bool {
        moshPaneChromeTopMaskActive
            && currentMoshPaneChromeSnapshot() == nil
            && moshActiveWindow != nil
    }

    private func moshPaneChromeCollapseMaskFrames(cellSize: CGSize) -> [CGRect] {
        guard moshPaneChromeTopMaskActive,
              !moshPaneChromeCollapseMaskedPaneIds.isEmpty,
              let snapshot = lastMoshPaneChromeSnapshot,
              snapshot.windowId == moshActiveWindow?.id
        else { return [] }

        return moshPaneChromeFrames(for: snapshot, cellSize: cellSize)
            .filter { moshPaneChromeCollapseMaskedPaneIds.contains($0.paneId) }
            .map(\.paneBox)
    }

    private func currentMoshPaneChromeSnapshot() -> MoshPaneChromeSnapshot? {
        guard let window = moshActiveWindow,
              window.rendersAsPaneGrid,
              let layout = moshRenderLayout,
              layout.paneCount > 1
        else { return nil }

        return MoshPaneChromeSnapshot(
            windowId: window.id,
            layout: layout,
            activePaneId: window.activePaneId,
            panes: window.panes,
            windowName: window.windowName
        )
    }

    private func rememberCurrentMoshPaneChromeSnapshot() {
        if let snapshot = currentMoshPaneChromeSnapshot() {
            lastMoshPaneChromeSnapshot = snapshot
        }
    }

    private func rememberMoshPaneChromeSnapshot() {
        if let snapshot = currentMoshPaneChromeSnapshot() {
            lastMoshPaneChromeSnapshot = snapshot
            return
        }
        if case .tmuxControl = tmux.mode,
           moshActiveWindow != nil {
            lastMoshPaneChromeSnapshot = nil
        }
    }

    private func showMoshPaneChromeCollapseMaskIfNeeded() {
        guard let snapshot = lastMoshPaneChromeSnapshot,
              let window = moshActiveWindow,
              snapshot.windowId == window.id,
              !window.isZoomed,
              window.paneCount <= 1
        else { return }

        let oldPaneIds = Set(snapshot.layout.paneIds)
        let newPaneIds = Set(window.layout?.paneIds ?? [])
        moshPaneChromeCollapseMaskedPaneIds = oldPaneIds.subtracting(newPaneIds)
        showMoshPaneChromeTopMask()
    }

    private func showMoshPaneChromeTopMask() {
        moshPaneChromeTopMaskGeneration += 1
        let generation = moshPaneChromeTopMaskGeneration
        moshPaneChromeTopMaskActive = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.moshPaneChromeTopMaskDuration
        ) {
            guard moshPaneChromeTopMaskGeneration == generation else { return }
            moshPaneChromeTopMaskActive = false
            moshPaneChromeCollapseMaskedPaneIds.removeAll()
            if currentMoshPaneChromeSnapshot() == nil,
               case .tmuxControl = tmux.mode,
               moshActiveWindow != nil {
                lastMoshPaneChromeSnapshot = nil
            }
        }
    }

    private func moshPaneChromeFrames(
        for snapshot: MoshPaneChromeSnapshot,
        cellSize: CGSize
    ) -> [PaneFrame] {
        snapshot.layout.leaves.compactMap { leaf in
            let contentRect = moshPaneChromeContentRect(
                paneId: leaf.paneId,
                leafRect: leaf.rect,
                panes: snapshot.panes
            )
            guard contentRect.width > 0, contentRect.height > 0 else { return nil }

            let headerRect = CellRect(
                width: contentRect.width,
                height: 1,
                x: contentRect.x,
                y: max(0, contentRect.y - 1)
            )
            return PaneFrame(
                paneId: leaf.paneId,
                headerFrame: moshPixelFrame(for: headerRect, cellSize: cellSize),
                surfaceFrame: moshPixelFrame(for: contentRect, cellSize: cellSize)
            )
        }
    }

    private func moshPaneChromeContentRect(
        paneId: PaneId,
        leafRect: CellRect,
        panes: [TmuxController.PaneInfo]
    ) -> CellRect {
        panes.first(where: { $0.id == paneId })?.contentRect ?? leafRect
    }

    private func moshPixelFrame(for rect: CellRect, cellSize: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) * cellSize.width,
            y: CGFloat(rect.y) * cellSize.height,
            width: CGFloat(rect.width) * cellSize.width,
            height: CGFloat(rect.height) * cellSize.height
        )
    }

    private func moshPaneChromeTitles(
        for frames: [PaneFrame],
        snapshot: MoshPaneChromeSnapshot
    ) -> [PaneId: String] {
        Dictionary(
            uniqueKeysWithValues: frames.map {
                ($0.paneId, moshPaneTitle($0.paneId, snapshot: snapshot))
            }
        )
    }

    private func moshPaneTitle(
        _ paneId: PaneId,
        snapshot: MoshPaneChromeSnapshot
    ) -> String {
        let pane = snapshot.panes.first(where: { $0.id == paneId })
        if let pane,
           !pane.titleIsDefault,
           let title = moshNonEmpty(pane.title) {
            return title
        }
        if let command = moshNonEmpty(pane?.currentCommand) {
            return command
        }
        if let name = moshNonEmpty(snapshot.windowName) {
            return name
        }
        return paneId.description
    }

    private func moshNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func moshPaneScrollbackFrame(for paneId: PaneId) -> PaneFrame? {
        guard let cellSize = moshCellSize
        else { return nil }

        if let rect = moshPaneScrollbackContentRect(for: paneId) {
            let surface = moshPixelFrame(for: rect, cellSize: cellSize)
            return PaneFrame(
                paneId: paneId,
                headerFrame: CGRect(x: surface.minX, y: surface.minY, width: surface.width, height: 0),
                surfaceFrame: surface
            )
        }

        guard let root = moshRenderLayout?.root else { return nil }
        return PaneLayoutMath.frames(root: root, cellSize: cellSize, headerHeight: 0)
            .first(where: { $0.paneId == paneId })
    }

    private func moshPaneScrollbackContentRect(for paneId: PaneId) -> CellRect? {
        let leafRect = moshRenderLayout?.leaves.first(where: { $0.paneId == paneId })?.rect
        if let window = moshActiveWindow,
           let rect = window.panes.first(where: { $0.id == paneId })?.contentRect {
            if window.rendersAsPaneGrid,
               let leafRect,
               rect == leafRect {
                return moshPaneContentRectByExcludingTitleRow(from: rect)
            }
            return rect
        }

        guard let window = moshActiveWindow,
              window.rendersAsPaneGrid,
              let leafRect
        else { return nil }

        // Fallback for the brief gap before pane metadata hydration catches up:
        // with `pane-border-status top`, `window_layout` still includes the
        // title row, while `pane_top`/`pane_height` exclude it.
        return moshPaneContentRectByExcludingTitleRow(from: leafRect)
    }

    private func moshPaneContentRectByExcludingTitleRow(from rect: CellRect) -> CellRect {
        guard rect.height > 1 else { return rect }
        return CellRect(
            width: rect.width,
            height: rect.height - 1,
            x: rect.x,
            y: rect.y + 1
        )
    }

    private func moshPaneScrollbackRows(for paneId: PaneId) -> Int? {
        guard let frame = moshPaneScrollbackFrame(for: paneId),
              let cellSize = moshCellSize,
              cellSize.height > 0
        else { return nil }
        return max(1, Int((frame.surfaceFrame.height / cellSize.height).rounded()))
    }

    private func ensureMoshPaneScrollbackOverlay(
        paneId: PaneId,
        windowId: WindowId
    ) -> MoshPaneScrollbackOverlayRuntime {
        if let overlay = moshPaneScrollbackOverlay,
           overlay.paneId == paneId,
           overlay.windowId == windowId {
            // NO find-handler rebind here: this early path runs on EVERY
            // scroll event while the overlay is up, and `handlers` lives on
            // an @Observable — a per-event observable write from the scroll
            // hot path is invalidation/observation churn for zero benefit
            // (the handlers were bound at creation and haven't changed).
            return overlay
        }

        // Publish the reader before a caller can request its history.
        defer { declareMoshRenderSurfaces(reason: "gesture-pane") }
        // Take the requested parked view out of the slot before dismissal
        // parks the outgoing reader there (and unregisters its predecessor).
        let reusable = moshDormantScrollbackOverlay.flatMap { dormant in
            dormant.paneId == paneId && dormant.windowId == windowId ? dormant : nil
        }
        if reusable != nil { moshDormantScrollbackOverlay = nil }
        dismissMoshPaneScrollbackOverlay(clearDepth: true, reason: "replace", returnedToTail: true)

        if let dormant = reusable {
            // Same pane re-entering scrollback: promote the parked runtime
            // — its SwiftTerm view is still mounted (or remounts itself if
            // its frame vanished meanwhile; TerminalBox buffers feeds until
            // attach), so this skips the ~140ms view-creation block.
            dormant.pendingScrollPlacement = nil
            dormant.pendingScrollDirection = 0
            dormant.pendingDeferredHistory = nil
            dormant.pendingPresentationHistory = nil
            dormant.freezeAfterDeferredPresentation = false
            dormant.sawNativeScroll = false
            dormant.contentFrozen = false
            dormant.clearDesiredScrollOffset()
            dormant.stopNativeScrollMotion()
            moshPaneScrollbackOverlay = dormant
            // Find remains on the live mosh surface until a matching
            // `historyReady` actually reveals this terminal. In particular an
            // alternate-screen or watchdog-rejected capture must not redirect
            // an open find bar to an empty opacity-zero overlay.
            MoshDiagnostics.log(
                "mosh scrollback overlay promote pane=\(paneId.description) window=\(windowId.description) viewAttached=\(dormant.box.view != nil)"
            )
            return dormant
        }

        let overlay = MoshPaneScrollbackOverlayRuntime(
            paneId: paneId,
            windowId: windowId,
            renderDropSummary: renderDropSummary
        )
        moshPaneScrollbackOverlay = overlay
        MoshDiagnostics.log(
            "mosh scrollback overlay create pane=\(paneId.description) window=\(windowId.description)"
        )
        return overlay
    }

    private func dismissMoshPaneScrollbackOverlay(
        clearDepth: Bool,
        reason: String,
        returnedToTail: Bool = false
    ) {
        guard let overlay = moshPaneScrollbackOverlay else { return }
        if let history = overlay.pendingDeferredHistory ?? overlay.pendingPresentationHistory {
            failMoshHistoryPresentation(
                surfaceID: moshOverlaySurfaceID(overlay.paneId),
                history: history,
                reason: "overlay-dismissed-\(reason)"
            )
        }
        overlay.box.view?.clearSearch()
        _ = clearDepth // retained for source-compatible presentation call sites.
        moshPaneScrollbackOverlay = nil
        // Park rather than drop: the runtime's mounted SwiftTerm view is
        // the expensive part (~140ms). Stale content is safe — the
        // opacity gate keys on moshOverlayContentReadyId, so a promoted
        // overlay stays invisible until its next ledger history effect.
        overlay.pendingScrollDirection = 0
        overlay.pendingDeferredHistory = nil
        overlay.pendingPresentationHistory = nil
        overlay.freezeAfterDeferredPresentation = false
        overlay.sawNativeScroll = false
        // A frozen snapshot never survives a park: the next reveal waits for
        // the ledger's authoritative history effect.
        overlay.contentFrozen = false
        // A dismissal can land mid-fling; the parked view stays mounted,
        // so without this its deceleration keeps running invisibly —
        // moving the parked offset, deferring history application, and making
        // a promoted-but-hidden overlay look "natively active" to the
        // fetch-reply deferral (which would strand the capture).
        overlay.stopNativeScrollMotion()
        if let previous = moshDormantScrollbackOverlay, previous !== overlay {
            renderDropSummary.unregister(previous.box)
        }
        moshDormantScrollbackOverlay = overlay
        moshOverlayContentReadyId = nil
        findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
        if findController.isOpen {
            findController.updateSearch()
        }
        if returnedToTail {
            tmux.submitRenderFact(.scrollbackReturnedToTail(
                moshOverlaySurfaceID(overlay.paneId)
            ))
        }
        MoshDiagnostics.log(
            "mosh scrollback overlay dismiss reason=\(reason) pane=\(overlay.paneId.description) clearDepth=\(clearDepth)"
        )
    }

    private func applyPendingMoshPaneScrollbackOverlayOffset() {
        guard let overlay = moshPaneScrollbackOverlay,
              overlay.pendingScrollPlacement != nil
        else { return }
        applyPendingMoshPaneScrollbackOverlayOffset(
            revision: overlay.pendingScrollPlacementRevision,
            attemptsRemaining: 5
        )
    }

    private func applyPendingMoshPaneScrollbackOverlayOffset(
        revision: Int,
        attemptsRemaining: Int
    ) {
        DispatchQueue.main.async {
            guard let overlay = moshPaneScrollbackOverlay,
                  overlay.pendingScrollPlacementRevision == revision,
                  overlay.box.isReadyForOwnedPresentation,
                  let view = overlay.box.view
            else { return }
            if var placement = overlay.pendingScrollPlacement {
                let latePoints = moshRenderLedgerAdapter.takePendingScrollPoints(
                    surfaceID: moshOverlaySurfaceID(overlay.paneId)) * 3
                if latePoints != 0 {
                    switch placement {
                    case .top: placement = .absolute(-latePoints)
                    case .bottomMinus(let points): placement = .bottomMinus(points + latePoints)
                    case .absolute(let y): placement = .absolute(y - latePoints)
                    }
                    overlay.pendingScrollPlacement = placement
                }
                let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
                if placement.requiresScrollableContent,
                   maxOffsetY <= Self.moshScrollbackTopThreshold {
                    if attemptsRemaining > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
                            guard let currentOverlay = moshPaneScrollbackOverlay,
                                  currentOverlay === overlay,
                                  currentOverlay.pendingScrollPlacementRevision == revision
                            else { return }
                            applyPendingMoshPaneScrollbackOverlayOffset(
                                revision: revision,
                                attemptsRemaining: attemptsRemaining - 1
                            )
                        }
                    } else {
                        MoshDiagnostics.log(
                            "mosh scrollback overlay offset waiting pane=\(overlay.paneId.description) placement=\(placement.logDescription) contentHeight=\(String(format: "%.1f", view.contentSize.height)) boundsHeight=\(String(format: "%.1f", view.bounds.height))"
                        )
                        if let history = overlay.pendingPresentationHistory {
                            overlay.pendingPresentationHistory = nil
                            overlay.pendingScrollPlacement = nil
                            overlay.pendingScrollPlacementRevision += 1
                            if moshOverlayContentReadyId == overlay.id {
                                moshOverlayContentReadyId = nil
                            }
                            findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
                            if findController.isOpen { findController.updateSearch() }
                            failMoshHistoryPresentation(
                                surfaceID: moshOverlaySurfaceID(overlay.paneId),
                                history: history,
                                reason: "offset-placement-timeout"
                            )
                        }
                    }
                    return
                }

                let targetY: CGFloat
                switch placement {
                case .top:
                    targetY = 0
                case .bottomMinus(let points):
                    targetY = max(0, maxOffsetY - points)
                case .absolute(let y):
                    targetY = y
                }
                let offsetY = overlay.applyDesiredScrollOffset(targetY, in: view)
                moshOverlayContentReadyId = overlay.id
                MoshDiagnostics.log(
                    "mosh scrollback overlay offset applied pane=\(overlay.paneId.description) placement=\(placement.logDescription) targetY=\(String(format: "%.1f", targetY)) offsetY=\(String(format: "%.1f", offsetY)) maxOffset=\(String(format: "%.1f", maxOffsetY)) contentHeight=\(String(format: "%.1f", view.contentSize.height)) boundsHeight=\(String(format: "%.1f", view.bounds.height))"
                )
                recordMoshScrollDiagnostic(
                    "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) offset-applied placement=\(placement.logDescription) targetY=\(Self.format(targetY)) offsetY=\(Self.format(offsetY)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
                )
                if attemptsRemaining > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
                        guard let currentOverlay = moshPaneScrollbackOverlay,
                              currentOverlay === overlay,
                              currentOverlay.pendingScrollPlacementRevision == revision
                        else { return }
                        applyPendingMoshPaneScrollbackOverlayOffset(
                            revision: revision,
                            attemptsRemaining: attemptsRemaining - 1
                        )
                    }
                } else {
                    overlay.pendingScrollPlacement = nil
                    // The opacity gate has now revealed this exact overlay and
                    // every bounded layout correction has physically applied.
                    // Only this final UI turn may acknowledge the staged owner
                    // or redirect Find to the detached terminal.
                    if let history = overlay.pendingPresentationHistory {
                        overlay.pendingPresentationHistory = nil
                        acknowledgeMoshHistoryPresented(
                            surfaceID: moshOverlaySurfaceID(overlay.paneId),
                            history: history
                        )
                    }
                    let reversedToTail = overlay.pendingScrollDirection < 0
                        && offsetY >= maxOffsetY
                    overlay.pendingScrollDirection = 0
                    if reversedToTail {
                        dismissMoshPaneScrollbackOverlay(clearDepth: true,
                            reason: "pending-reverse-to-tail", returnedToTail: true)
                        return
                    }
                    if overlay.freezeAfterDeferredPresentation {
                        overlay.freezeAfterDeferredPresentation = false
                        overlay.contentFrozen = true
                        recordMoshScrollDiagnostic(
                            "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) content-frozen reason=output-before-presentation"
                        )
                    }
                }
            }
            if findController.isOpen,
               overlay.pendingPresentationHistory == nil,
               moshOverlayContentReadyId == overlay.id {
                findController.handlers = TerminalSearchAdapter.handlers(for: overlay.box)
                findController.updateSearch()
            }
        }
    }

    private func handleMoshPaneScrollbackOverlayScrolled(_ view: TerminalView) {
        guard let overlay = moshPaneScrollbackOverlay,
              overlay.box.view === view
        else { return }
        if view.isTracking || view.isDragging || view.isDecelerating {
            // A native pan/deceleration owns contentOffset. The desired-
            // offset anchor exists to counter feed-induced snaps — fighting
            // a live finger with it would stutter, so it FOLLOWS the native
            // offset instead. Boundary work (bottom dismissal, deferred
            // deep-history feed) waits for the settle poll: UIScrollView
            // exposes no end-of-scroll hook here (SwiftTerm owns the
            // delegate), and the last didScroll of a gesture still reports
            // an active state.
            if view.isTracking || view.isDragging,
               overlay.pendingDeferredHistory == nil,
               overlay.pendingScrollPlacement != nil {
                // A real pan takes over from a just-applied capture anchor:
                // bump the revision so the 35ms re-anchor retry chain dies
                // instead of fighting the finger (same rule the bridge path
                // applies in scrollMoshPaneScrollbackOverlay). Never while a
                // capture is in flight or parked — that placement is the
                // capture's anchor, and killing it would make the eventual
                // apply snap to the fed tail instead of rebasing to .top.
                overlay.pendingScrollPlacement = nil
                overlay.pendingScrollPlacementRevision += 1
            }
            overlay.sawNativeScroll = true
            overlay.desiredScrollOffsetY = view.contentOffset.y
            armMoshOverlayNativeSettleCheck(for: overlay)
            return
        }
        overlay.restoreDesiredScrollOffset(in: view) { detail in
            recordMoshScrollDiagnostic(
                "surface=overlay window=\(overlay.windowId.description) \(detail)"
            )
        }
        resolveMoshOverlayNativeBoundary(overlay: overlay, view: view)
    }

    /// 10Hz poll bridging the gap between the last active didScroll and
    /// actual settle (pan end with no momentum, or deceleration running
    /// out) — both end without a settled scroll callback.
    private func armMoshOverlayNativeSettleCheck(for overlay: MoshPaneScrollbackOverlayRuntime) {
        guard !overlay.nativeSettleCheckArmed else { return }
        overlay.nativeSettleCheckArmed = true
        scheduleMoshOverlayNativeSettleCheck(overlay, attempt: 0)
    }

    private func scheduleMoshOverlayNativeSettleCheck(
        _ overlay: MoshPaneScrollbackOverlayRuntime,
        attempt: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard moshPaneScrollbackOverlay === overlay,
                  let view = overlay.box.view
            else {
                overlay.nativeSettleCheckArmed = false
                return
            }
            if view.isTracking || view.isDragging || view.isDecelerating {
                // 60s cap: a wedged UIScrollView state must not poll forever.
                guard attempt < 600 else {
                    overlay.nativeSettleCheckArmed = false
                    return
                }
                scheduleMoshOverlayNativeSettleCheck(overlay, attempt: attempt + 1)
                return
            }
            overlay.nativeSettleCheckArmed = false
            overlay.desiredScrollOffsetY = view.contentOffset.y
            resolveMoshOverlayNativeBoundary(overlay: overlay, view: view)
        }
    }

    /// Settled-state boundary decisions for the native scroll path.
    private func resolveMoshOverlayNativeBoundary(
        overlay: MoshPaneScrollbackOverlayRuntime,
        view: TerminalView
    ) {
        guard moshOverlayContentReadyId == overlay.id else { return }

        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        let settledOffsetY = overlay.desiredScrollOffsetY ?? view.contentOffset.y
        let atLiveTail = maxOffsetY > 0
            && settledOffsetY >= maxOffsetY

        if let history = overlay.pendingDeferredHistory {
            overlay.pendingDeferredHistory = nil
            if !atLiveTail {
                // The apply anchors by distance-from-bottom, so it is
                // position-preserving wherever the gesture settled. Only a
                // settle AT the live tail drops it: the reader is leaving
                // scrollback, and feeding thousands of lines just to
                // dismiss would be waste. FALL THROUGH there — with
                // bounces off there is no further didScroll to re-run the
                // bottom dismissal.
                applyMoshOverlayHistory(
                    history,
                    to: overlay,
                    surfaceID: moshOverlaySurfaceID(overlay.paneId)
                )
                return
            }
            overlay.pendingScrollPlacement = nil
            overlay.pendingScrollPlacementRevision += 1
            failMoshHistoryPresentation(
                surfaceID: moshOverlaySurfaceID(overlay.paneId),
                history: history,
                reason: "deferred-at-live-tail"
            )
            MoshDiagnostics.log(
                "mosh scrollback overlay deferred capture dropped reason=at-live-tail pane=\(overlay.paneId.description)"
            )
        }

        // A fetch's post-landing anchor hasn't applied yet — the offset is
        // transiently at the fed tail, not where the user is.
        guard overlay.pendingScrollPlacement == nil else { return }

        if atLiveTail {
            // Bottom dismissal only after genuine native motion: bridge
            // writes also arrive settled, and a gentle reveal-scroll still
            // inside the bottom threshold must not dismiss its own overlay
            // (the bridge path has its own direction-aware bottom check).
            guard overlay.sawNativeScroll else { return }
            recordMoshScrollDiagnostic(
                "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) native-bottom-dismiss offset=\(Self.format(view.contentOffset.y)) max=\(Self.format(maxOffsetY))"
            )
            dismissMoshPaneScrollbackOverlay(
                clearDepth: true,
                reason: "native-bottom",
                returnedToTail: true
            )
            return
        }
        if settledOffsetY <= Self.moshScrollbackTopThreshold {
            requestMoshHistory(
                surfaceID: moshOverlaySurfaceID(overlay.paneId),
                pointsY: 0,
                isInertial: false,
                reason: "native-top"
            )
        }
    }

    private func resetMoshScrollbackCapture(clearLocal: Bool, reason: String) {
        // The ledger owns capture identity, history depth, flight state and
        // watchdogs. This is deliberately presentation-only: terminate any
        // mounted reader and forget byte batches that have not yet acquired a
        // `historyReady` placement. Topology facts below make the ledger bind
        // (and clear) the appropriate actual surface.
        moshRenderLedgerAdapter.reset()
        resetMoshScrollbackPresentation(reason: reason)
        // Surface ownership is the only clear authority. In particular, do
        // not let a local resize/pane-reset clear the mosh painter before the
        // ledger decides whether this continuity change requires a new owner.
        // Plain mosh is ledger-idle and its local transcript is the record;
        // side-channel mosh receives the matching bind effect when it has
        // synthesized history to discard.
        _ = clearLocal
        MoshDiagnostics.log("mosh scrollback reset reason=\(reason) delegated-to-render-ledger")
    }

    private func deactivateMoshScrollbackCapture(reason: String) {
        moshRenderLedgerAdapter.deactivate()
        resetMoshScrollbackPresentation(reason: reason)
        MoshDiagnostics.log("mosh scrollback deactivated reason=\(reason)")
    }

    private func resetMoshScrollbackPresentation(reason: String) {
        cancelPendingMoshLiveHistoryPresentation(reason: "reset-\(reason)")
        moshLiveHistoryRevealed = false
        if moshPaneScrollbackOverlay != nil {
            dismissMoshPaneScrollbackOverlay(clearDepth: false, reason: reason)
        }
        moshPaneInteractionProbeInFlight.removeAll(keepingCapacity: true)
        pendingMoshInteractionProbeScrollPointsByPane.removeAll(keepingCapacity: true)
        moshSplitAltScreenScrollDispatcher = Self.makeMoshSplitAltScreenScrollDispatcher()
        scrollDiagnostics.gateLogCount = 0
        findController.handlers = TerminalSearchAdapter.handlers(for: terminalBox)
    }

    /// Output policy itself lives in the side-channel ledger. The view only
    /// preserves iTerm-style presentation: a visible reader remains in place
    /// as a frozen snapshot until the reader returns to the live tail.
    private func invalidateMoshScrollbackForActivePaneOutput() {
        if let overlay = moshPaneScrollbackOverlay,
           moshOverlayContentReadyId == overlay.id {
            if overlay.pendingDeferredHistory != nil ||
                overlay.pendingPresentationHistory != nil {
                // The reducer has staged, but not yet presented, a replacement
                // capture. Preserve it through native-scroll settling and
                // physical top-row placement, then apply the freeze only
                // after its exact presentation acknowledgement.
                overlay.freezeAfterDeferredPresentation = true
                return
            }
            let alreadyFrozen = overlay.contentFrozen
            overlay.contentFrozen = true
            if !alreadyFrozen {
                MoshDiagnostics.log(
                    "mosh scrollback overlay frozen reason=active-pane-output pane=\(overlay.paneId.description)"
                )
                recordMoshScrollDiagnostic(
                    "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) content-frozen reason=active-pane-output"
                )
            }
            return
        }
    }

    private func invalidateMoshScrollbackForTerminalInput(reason: String) {
        if usesDetachedMoshHistoryOverlay() {
            // Input belongs to the focused pane. A reader of another pane
            // retains its capture, pending placement, and native offset.
            guard let surfaceID = MoshHistorySurfacePolicy.inputSurfaceID(
                focusedPaneID: moshActiveWindow?.activePaneId ?? tmux.activePaneId,
                usesDetachedOverlay: true
            ) else { return }
            let readingInputPane = moshPaneScrollbackOverlay.map {
                moshOverlaySurfaceID($0.paneId) == surfaceID
            } == true
            if readingInputPane {
                dismissMoshPaneScrollbackOverlay(clearDepth: false, reason: reason)
            }
            moshRenderLedgerAdapter.clearHistoryRequest(surfaceID: surfaceID)
            if readingInputPane || tmux.isHistoryPresentationPending(for: surfaceID) {
                tmux.submitRenderFact(.scrollbackReturnedToTail(surfaceID))
            }
            return
        }
        // The semantic boundary belongs to the shared reducer. Keep the
        // overlay choreography local: an active reader is parked before the
        // ledger's bind effect clears the now-stale synthesize-history surface.
        if moshPaneScrollbackOverlay != nil {
            dismissMoshPaneScrollbackOverlay(clearDepth: false, reason: reason)
        }
        moshRenderLedgerAdapter.reset()
        cancelPendingMoshLiveHistoryPresentation(reason: "terminal-input-\(reason)")
        moshLiveHistoryRevealed = false
        tmux.submitRenderFact(.userInput)
    }

    // MARK: - Side-channel render-ledger presentation adapter

    /// The controller owns the side-channel state machine. This view owns only
    /// the physical SwiftTerm destinations: the whole-window mosh painter, or
    /// a pane history overlay on an iPad grid.
    private func usesDetachedMoshHistoryOverlay(
        window: TmuxController.WindowInfo? = nil
    ) -> Bool {
        MoshHistorySurfacePolicy.usesDetachedOverlay(
            isPhone: isPhone,
            windowRendersAsPaneGrid: (window ?? moshActiveWindow)?.rendersAsPaneGrid == true
        )
    }

    private func moshHistorySurfaceID(
        paneID: PaneId? = nil,
        window: TmuxController.WindowInfo? = nil
    ) -> SurfaceId {
        let window = window ?? moshActiveWindow
        guard let paneID = paneID ?? window?.activePaneId ?? tmux.activePaneId,
              usesDetachedMoshHistoryOverlay(window: window)
        else { return .live }
        return moshOverlaySurfaceID(paneID)
    }

    private func moshOverlaySurfaceID(_ paneID: PaneId) -> SurfaceId {
        MoshHistorySurfacePolicy.overlaySurfaceID(paneID)
    }

    private func moshRenderSurfaceDeclarations() -> [SurfaceDeclaration] {
        guard let window = moshActiveWindow else { return [] }

        return MoshHistorySurfacePolicy.declarations(
            windowID: window.id,
            paneIDs: window.panes.map(\.id),
            activePaneID: window.activePaneId ?? tmux.activePaneId,
            overlay: moshPaneScrollbackOverlay.map { ($0.windowId, $0.paneId) },
            usesDetachedOverlay: usesDetachedMoshHistoryOverlay(window: window)
        )
    }

    /// Topology is a fact, not an instruction to capture. The ledger decides
    /// whether an owner epoch must move and whether an existing reader survives
    /// the change.
    private func declareMoshRenderSurfaces(reason: String) {
        guard tmux.mode == .tmuxControl else { return }
        let declarations = moshRenderSurfaceDeclarations()
        guard !declarations.isEmpty else { return }
        tmux.declareRenderSurfaces(declarations)
        tmux.submitRenderFact(.scrollbackLimit(lines: appearance.scrollbackLines))
        recordMoshScrollDiagnostic(
            "render-ledger declare reason=\(reason) surfaces=\(declarations.map { $0.surfaceID.description }.joined(separator: ","))"
        )
    }

    /// Ensure the presentation destination exists before a fact can cause a
    /// side-channel capture. The hidden overlay mounts opacity-zero, so a
    /// queued feed is safe even if SwiftUI has not attached its terminal yet.
    private func prepareMoshHistorySurface() -> SurfaceId? {
        guard let window = moshActiveWindow else { return nil }
        let readerPaneID = moshPaneScrollbackOverlay.flatMap { overlay -> PaneId? in
            guard overlay.windowId == window.id,
                  window.panes.contains(where: { $0.id == overlay.paneId })
            else { return nil }
            return overlay.paneId
        }
        guard let paneID = readerPaneID ?? window.activePaneId ?? tmux.activePaneId
        else { return nil }
        if usesDetachedMoshHistoryOverlay(window: window) {
            guard moshPaneScrollbackFrame(for: paneID) != nil else { return nil }
            _ = ensureMoshPaneScrollbackOverlay(paneId: paneID, windowId: window.id)
        }
        declareMoshRenderSurfaces(reason: "history-request")
        return moshHistorySurfaceID(paneID: paneID, window: window)
    }

    private func requestMoshHistory(
        surfaceID: SurfaceId,
        pointsY: Double,
        isInertial: Bool,
        reason: String
    ) {
        // A single source-of-truth reducer owns page/parity depth and its
        // watchdog. The only local datum is how far the originating gesture
        // should move a newly revealed surface away from its live tail.
        // Points kept from a request the ledger has since ended without a
        // page (its watchdog, a frozen page's lost anchor) belong to no one.
        if !tmux.isHistoryPresentationPending(for: surfaceID) {
            moshRenderLedgerAdapter.clearHistoryRequest(surfaceID: surfaceID)
        }
        moshRenderLedgerAdapter.noteHistoryRequest(
            surfaceID: surfaceID,
            pointsY: pointsY,
            isInertial: isInertial
        )
        tmux.submitRenderFact(.scrollbackRequested(
            surfaceID,
            pointsY: pointsY,
            isInertial: isInertial
        ))
        if !tmux.isHistoryPresentationPending(for: surfaceID) {
            moshRenderLedgerAdapter.clearHistoryRequest(surfaceID: surfaceID)
        }
        recordMoshScrollDiagnostic(
            "render-ledger scrollback-request reason=\(reason) surface=\(surfaceID.description) points=\(Self.format(CGFloat(pointsY))) inertial=\(isInertial)"
        )
    }

    private func requestMoshFindHistory(reason: String) {
        guard findController.isOpen,
              session.host.launchMode != .customCommand,
              presentationSessionState == .connected,
              tmux.mode == .tmuxControl,
              let surfaceID = prepareMoshHistorySurface()
        else { return }
        moshRenderLedgerAdapter.clearHistoryRequest(surfaceID: surfaceID)
        tmux.submitRenderFact(.findOpened(surfaceID))
        recordMoshScrollDiagnostic(
            "render-ledger find-request reason=\(reason) surface=\(surfaceID.description)"
        )
    }

    private func moshRenderBox(for surfaceID: SurfaceId) -> TerminalBox? {
        if surfaceID == .live { return terminalBox }
        if let overlay = moshPaneScrollbackOverlay,
           moshOverlaySurfaceID(overlay.paneId) == surfaceID {
            return overlay.box
        }
        if let dormant = moshDormantScrollbackOverlay,
           moshOverlaySurfaceID(dormant.paneId) == surfaceID {
            return dormant.box
        }
        return nil
    }

    /// Bind the controller's effect hooks exactly once per view lifetime. The
    /// controller retains ordering/timers/FIFO and resolves byte references;
    /// this adapter deliberately has no capture command or policy state.
    private func installMoshRenderLedgerAdapter() {
        moshRenderLedgerAdapter.install(
            on: tmux,
            scrollbackLimit: { appearance.scrollbackLines },
            boxForSurface: { surfaceID in moshRenderBox(for: surfaceID) },
            fallbackSurfaceState: { surfaceID in
                guard let paneID = moshPaneID(for: surfaceID),
                      let rect = moshPaneScrollbackContentRect(for: paneID)
                else { return nil }
                // The side-channel metadata is authoritative for alternate
                // screen state. A detached renderer starts from primary.
                return (
                    altScreen: false,
                    mouseMode: .off,
                    columns: max(1, rect.width),
                    rows: max(1, rect.height)
                )
            },
            onHistoryReady: { surfaceID, history in
                applyMoshRenderHistoryReady(surfaceID: surfaceID, history: history)
            },
            onHistoryDropped: { surfaceID, owner, reason in
                failMoshHistoryPresentation(
                    surfaceID: surfaceID,
                    owner: owner,
                    reason: reason
                )
                recordMoshScrollDiagnostic(
                    "render-ledger history-ready-dropped surface=\(surfaceID.description) reason=\(reason)"
                )
            },
            onRequestTransportFullFrame: { [weak session] onScheduled, completion in
                guard let session else {
                    completion(nil)
                    return
                }
                session.forceFullRepaint(
                    requiringFreshRemoteState: tmux.gridAuthorityRepaintRequiresFreshRemoteState,
                    onScheduled: onScheduled,
                    completion: completion
                )
            },
            onCancelTransportFullFrame: { [weak session] requestID in
                session?.cancelFullRepaint(requestID: requestID)
            },
            onRetireAllTransportFullFrames: { [weak session] in
                session?.retireOutstandingFullRepaints() ?? 0
            },
            currentTransportOutputDeliveryID: { [weak session] in
                session?.latestOutputDeliveryID ?? 0
            },
            onSaveWindowModes: { [kittyWindowModes, terminalBox] surfaceID, windowID in
                guard surfaceID == .live,
                      let terminal = terminalBox.view?.getTerminal()
                else { return }
                kittyWindowModes.save(windowID: windowID, terminal: terminal)
            }
        )
    }

    private func moshPaneID(for surfaceID: SurfaceId) -> PaneId? {
        guard surfaceID != .live else { return nil }
        let prefix = "overlay:%"
        guard surfaceID.rawValue.hasPrefix(prefix),
              let rawValue = Int(surfaceID.rawValue.dropFirst(prefix.count))
        else { return nil }
        return PaneId(rawValue)
    }

    private func applyMoshRenderHistoryReady(
        surfaceID: SurfaceId,
        history: MoshLedgerHistory
    ) {
        if surfaceID == .live {
            applyMoshLiveHistory(history, surfaceID: surfaceID)
            return
        }
        guard let overlay = moshPaneScrollbackOverlay,
              moshOverlaySurfaceID(overlay.paneId) == surfaceID
        else {
            moshRenderLedgerAdapter.discardWindowModeRestore(surfaceID: surfaceID)
            failMoshHistoryPresentation(
                surfaceID: surfaceID,
                history: history,
                reason: "overlay-mismatch"
            )
            recordMoshScrollDiagnostic(
                "render-ledger history-ready-dropped surface=\(surfaceID.description) reason=overlay-mismatch"
            )
            return
        }
        if moshOverlayContentReadyId == overlay.id,
           let view = overlay.box.view,
           view.isTracking || view.isDragging || view.isDecelerating {
            overlay.pendingDeferredHistory = history
            armMoshOverlayNativeSettleCheck(for: overlay)
            return
        }
        applyMoshOverlayHistory(history, to: overlay, surfaceID: surfaceID)
    }

    private func applyMoshLiveHistory(_ history: MoshLedgerHistory, surfaceID: SurfaceId) {
        guard terminalBox.boundOwner == history.owner else {
            // Keep this through the seam instead of silently losing a stale
            // `historyReady`: it increments the same diagnostics counter as
            // any other foreign feed and never mutates the live painter.
            terminalBox.feed(owner: history.owner, history.bytes[...])
            moshRenderLedgerAdapter.discardWindowModeRestore(surfaceID: surfaceID)
            failMoshHistoryPresentation(
                surfaceID: surfaceID,
                history: history,
                reason: "foreign-owner"
            )
            recordMoshScrollDiagnostic(
                "render-ledger history-ready-dropped surface=\(surfaceID.description) reason=foreign-owner"
            )
            return
        }
        if let pending = pendingMoshLiveHistoryPresentation {
            pendingMoshLiveHistoryPresentation = nil
            failMoshHistoryPresentation(
                surfaceID: surfaceID,
                history: pending.history,
                reason: "live-presentation-superseded"
            )
        }
        let view = terminalBox.view
        // The ledger binds a fresh owner before it feeds a replacement page,
        // and that bind already emptied the buffer. The reader's distance
        // from the tail therefore comes from the box's pre-clear snapshot;
        // sampling the view here would place every deepen back at the tail.
        let positionBeforeRebind = terminalBox.takeScrollPositionBeforeRebind(for: history.owner)
        let oldMaxOffsetY = positionBeforeRebind?.maxOffsetY
            ?? view.map { max(0, $0.contentSize.height - $0.bounds.height) }
            ?? 0
        let oldOffsetY = positionBeforeRebind?.offsetY
            ?? view.map { min(max(0, $0.contentOffset.y), oldMaxOffsetY) }
            ?? 0
        let presentation = MoshLiveHistoryPresentation(
            history: history,
            oldMaxOffsetY: oldMaxOffsetY,
            oldOffsetY: oldOffsetY
        )
        // Replacing one synthesized history page rebuilds SwiftTerm's rows
        // incrementally. Its scroll delegate can therefore observe a transient
        // 0...one-row content range during the feed. Do not let the previous
        // page's reveal latch classify that internal rebuild as a genuine
        // user return to the live tail: doing so advances the render owner
        // while this exact history payload is still awaiting placement.
        moshLiveHistoryRevealed = false
        pendingMoshLiveHistoryPresentation = presentation
        terminalBox.setAcceptsPainterFeeds(false)
        terminalBox.feed(owner: history.owner, history.bytes[...])
        restorePendingMoshWindowModesAfterHistory(surfaceID: surfaceID)
        applyPendingMoshLiveHistoryPresentation(
            id: presentation.id,
            surfaceID: surfaceID,
            attemptsRemaining: 30
        )
        recordMoshScrollDiagnostic(
            "render-ledger history-applied surface=\(surfaceID.description) depth=\(history.depth) size=\(history.historySize) bytes=\(history.bytes.count)"
        )
    }

    private func applyPendingMoshLiveHistoryPresentation(
        id: UUID,
        surfaceID: SurfaceId,
        attemptsRemaining: Int
    ) {
        DispatchQueue.main.async {
            guard let presentation = pendingMoshLiveHistoryPresentation,
                  presentation.id == id
            else { return }
            guard terminalBox.boundOwner == presentation.history.owner else {
                pendingMoshLiveHistoryPresentation = nil
                failMoshHistoryPresentation(
                    surfaceID: surfaceID,
                    history: presentation.history,
                    reason: "live-owner-changed-before-placement"
                )
                return
            }
            guard terminalBox.isReadyForOwnedPresentation,
                  let view = terminalBox.view
            else {
                if attemptsRemaining > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
                        applyPendingMoshLiveHistoryPresentation(
                            id: id,
                            surfaceID: surfaceID,
                            attemptsRemaining: attemptsRemaining - 1
                        )
                    }
                } else {
                    pendingMoshLiveHistoryPresentation = nil
                    failMoshHistoryPresentation(
                        surfaceID: surfaceID,
                        history: presentation.history,
                        reason: "live-view-placement-timeout"
                    )
                }
                return
            }
            restorePendingMoshWindowModesAfterHistory(surfaceID: surfaceID)
            let scrollPoints = presentation.history.scrollPoints
                + moshRenderLedgerAdapter.takePendingScrollPoints(surfaceID: surfaceID)
            let newMaxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            let targetY: CGFloat
            switch presentation.history.placement {
            case .preserveDistanceFromBottom:
                targetY = max(
                    0,
                    newMaxOffsetY -
                        (presentation.oldMaxOffsetY - presentation.oldOffsetY) -
                        scrollPoints * 3
                )
            case .bottom:
                targetY = max(
                    0,
                    newMaxOffsetY - scrollPoints * 3
                )
            }
            view.contentOffset = CGPoint(
                x: view.contentOffset.x,
                y: min(max(0, targetY), newMaxOffsetY)
            )
            recordMoshScrollDiagnostic(
                "render-ledger history-placed surface=\(surfaceID.description) points=\(Self.format(CGFloat(scrollPoints))) oldOffset=\(Self.format(presentation.oldOffsetY))/\(Self.format(presentation.oldMaxOffsetY)) placeY=\(Self.format(targetY)) offset=\(Self.format(view.contentOffset.y))/\(Self.format(newMaxOffsetY))"
            )
            pendingMoshLiveHistoryPresentation = nil
            moshLiveHistoryRevealed = true
            acknowledgeMoshHistoryPresented(
                surfaceID: surfaceID,
                history: presentation.history
            )
            // SwiftTerm reports the programmatic placement synchronously while
            // the presentation is still pending, so that delegate callback is
            // intentionally ignored. Re-evaluate after acknowledgement to
            // release the history reader when a reverse gesture placed this
            // replacement page at the live tail. Without this explicit pass,
            // painter ingress can remain closed until an unrelated scroll.
            handleMoshLiveTerminalScrolled(view)
            if findController.isOpen { findController.updateSearch() }
        }
    }

    private func cancelPendingMoshLiveHistoryPresentation(reason: String) {
        guard let presentation = pendingMoshLiveHistoryPresentation else { return }
        pendingMoshLiveHistoryPresentation = nil
        failMoshHistoryPresentation(
            surfaceID: .live,
            history: presentation.history,
            reason: reason
        )
    }

    private func applyMoshOverlayHistory(
        _ history: MoshLedgerHistory,
        to overlay: MoshPaneScrollbackOverlayRuntime,
        surfaceID: SurfaceId
    ) {
        guard overlay.box.boundOwner == history.owner else {
            overlay.box.feed(owner: history.owner, history.bytes[...])
            moshRenderLedgerAdapter.discardWindowModeRestore(surfaceID: surfaceID)
            failMoshHistoryPresentation(
                surfaceID: surfaceID,
                history: history,
                reason: "foreign-owner"
            )
            recordMoshScrollDiagnostic(
                "render-ledger history-ready-dropped surface=\(surfaceID.description) reason=foreign-owner"
            )
            return
        }
        let positionBeforeRebind = overlay.box.takeScrollPositionBeforeRebind(for: history.owner)
        if history.placement == .preserveDistanceFromBottom,
           moshOverlayContentReadyId == overlay.id,
           let view = overlay.box.view {
            let oldMaxOffsetY = positionBeforeRebind?.maxOffsetY
                ?? max(0, view.contentSize.height - view.bounds.height)
            let oldOffsetY = positionBeforeRebind?.offsetY
                ?? min(max(0, overlay.desiredScrollOffsetY ?? view.contentOffset.y), oldMaxOffsetY)
            overlay.setPendingScrollPlacement(.bottomMinus(oldMaxOffsetY - oldOffsetY + history.scrollPoints * 3))
        } else {
            overlay.setPendingScrollPlacement(.bottomMinus(history.scrollPoints * 3))
        }
        overlay.pendingDeferredHistory = nil
        overlay.pendingPresentationHistory = history
        overlay.stopNativeScrollMotion()
        overlay.clearDesiredScrollOffset()
        overlay.box.feed(owner: history.owner, history.bytes[...])
        restorePendingMoshWindowModesAfterHistory(surfaceID: surfaceID)
        applyPendingMoshPaneScrollbackOverlayOffset()
        recordMoshScrollDiagnostic(
            "render-ledger history-applied surface=\(surfaceID.description) depth=\(history.depth) size=\(history.historySize) bytes=\(history.bytes.count)"
        )
    }

    private func acknowledgeMoshHistoryPresented(
        surfaceID: SurfaceId,
        history: MoshLedgerHistory
    ) {
        guard moshRenderBox(for: surfaceID)?.boundOwner == history.owner else {
            failMoshHistoryPresentation(
                surfaceID: surfaceID,
                history: history,
                reason: "owner-changed-after-feed"
            )
            recordMoshScrollDiagnostic(
                "render-ledger history-presented-dropped surface=\(surfaceID.description) reason=owner-changed-after-feed"
            )
            return
        }
        moshRenderLedgerAdapter.clearHistoryRequest(surfaceID: surfaceID)
        tmux.submitRenderFact(.historyPresented(
            surfaceID,
            owner: RenderOwner(
                windowID: history.owner.windowId,
                paneID: history.owner.paneId,
                epoch: history.owner.epoch
            )
        ))
    }

    private func failMoshHistoryPresentation(
        surfaceID: SurfaceId,
        history: MoshLedgerHistory,
        reason: String
    ) {
        failMoshHistoryPresentation(
            surfaceID: surfaceID,
            owner: history.owner,
            reason: reason
        )
    }

    private func failMoshHistoryPresentation(
        surfaceID: SurfaceId,
        owner: TerminalRenderOwner,
        reason: String
    ) {
        if surfaceID == .live {
            moshLiveHistoryRevealed = false
            terminalBox.setAcceptsPainterFeeds(true)
        }
        tmux.submitRenderFact(.historyPresentationFailed(
            surfaceID,
            owner: RenderOwner(
                windowID: owner.windowId,
                paneID: owner.paneId,
                epoch: owner.epoch
            )
        ))
        recordMoshScrollDiagnostic(
            "render-ledger history-presentation-failed surface=\(surfaceID.description) reason=\(reason)"
        )
    }

    /// The controller emits restore immediately after the feed effect. Mosh
    /// history feeds are intentionally held until `historyReady`, so replay
    /// window modes only after the same `TerminalBox` received that feed.
    /// A just-mounted overlay retries from its `onReady` callback.
    private func restorePendingMoshWindowModesAfterHistory(surfaceID: SurfaceId) {
        guard let restore = moshRenderLedgerAdapter.windowModeRestore(surfaceID: surfaceID),
              let box = moshRenderBox(for: surfaceID),
              box.isReadyForOwnedPresentation,
              let terminal = box.view?.getTerminal()
        else { return }
        moshRenderLedgerAdapter.discardWindowModeRestore(surfaceID: surfaceID)
        kittyWindowModes.restore(
            windowID: restore.windowID,
            paneInAltScreen: restore.paneInAltScreen,
            terminal: terminal,
            terminalBox: box
        )
        // Window-mode replay is still part of the feed phase. Find must not
        // observe this surface until the placement/reveal phase has completed
        // and the exact staged owner has been acknowledged.
    }

    private func isAutomaticTerminalColorResponse(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard !bytes.isEmpty else { return false }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.hasPrefix("\u{1B}]10;rgb:")
            || text.hasPrefix("\u{1B}]11;rgb:")
            || text.hasPrefix("\u{9D}10;rgb:")
            || text.hasPrefix("\u{9D}11;rgb:")
    }

    private func logMoshScrollbackGate(_ message: @autoclosure () -> String) {
        guard scrollDiagnostics.gateLogCount < 24 else { return }
        scrollDiagnostics.gateLogCount += 1
        MoshDiagnostics.log("mosh scrollback gate \(message())")
    }

    private func moshScrollPaneAtLocation(view: TerminalView, point: CGPoint) -> PaneId? {
        guard let window = moshActiveWindow else { return nil }
        let fallback = window.activePaneId ?? tmux.activePaneId
        guard usesDetachedMoshHistoryOverlay(window: window) else { return nil }
        let panes = window.panes.compactMap { pane -> (PaneId, CellRect)? in
            guard let rect = moshPaneScrollbackContentRect(for: pane.id) else { return nil }
            return (pane.id, rect)
        }
        return PaneLayoutMath.scrollPane(
            at: point, contentOffset: view.contentOffset,
            cellSize: TerminalCellMetrics.cellSize(for: view), panes: panes,
            fallback: fallback
        )
    }

    private func handleMoshPrimaryScrollbackDelta(
        view: TerminalView,
        pointsY: Double,
        proposedOffsetY: CGFloat,
        maxOffsetY: CGFloat,
        isInertial: Bool,
        gesturePaneID: PaneId?
    ) -> TerminalPrimaryScrollConsumption {
        guard let window = moshActiveWindow else {
            return handleMoshLiveHistoryScroll(view: view, pointsY: pointsY,
                proposedOffsetY: proposedOffsetY, maxOffsetY: maxOffsetY,
                isInertial: isInertial)
        }
        guard pointsY != 0 else { return .consumedCancelInertia }
        guard session.host.launchMode != .customCommand,
              presentationSessionState == .connected,
              tmux.mode == .tmuxControl
        else {
            return .consumedCancelInertia
        }
        guard terminalBox.view === view else { return .consumedCancelInertia }

        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return .notConsumed }

        // A pane the gesture resolved but the layout no longer lists falls
        // back to the focused one. A compact window whose panes are not yet
        // hydrated still reaches the live history path below; a grid needs
        // the pane's frame.
        let gesturePane = gesturePaneID.flatMap { id in window.panes.contains { $0.id == id } ? id : nil }
        guard let paneId = gesturePane ?? window.activePaneId ?? tmux.activePaneId
        else {
            logMoshScrollbackGate("overlay-skip reason=no-pane-frame")
            return .consumedCancelInertia
        }

        if agentScrollPrevention(paneID: paneId.rawValue) != nil {
            presentAgentScrollPrevention(paneID: paneId.rawValue)
            return .consumedCancelInertia
        }

        if let pane = window.panes.first(where: { $0.id == paneId }),
           pane.isAlternateScreen == true,
           // A reader of revealed history (a pane can go full-screen
           // mid-read) scrolls it back down first: the split's overlay, or
           // this surface on compact layouts. Finger pans over the overlay
           // land here, not on its scroll view. Only the tail belongs to
           // the program.
           !moshLiveHistoryRevealed,
           !(moshPaneScrollbackOverlay.map {
               $0.paneId == paneId && $0.windowId == window.id && $0.id == moshOverlayContentReadyId
           } ?? false),
           usesDetachedMoshHistoryOverlay(window: window)
               || view.contentOffset.y >= maxOffsetY - 1 {
            // Semantic forward — never from a synthetic glide frame: the
            // remote TUI would keep receiving motion after the fingers
            // left the trackpad.
            guard !isInertial else { return .consumedCancelInertia }
            forwardMoshPaneAltScreenScroll(
                view: view,
                paneId: paneId,
                pointsY: pointsY,
                mouseReporting: pane.isMouseReporting == true,
                useSgrMouse: pane.isSgrMouse == true,
                reason: "cached-alt-screen"
            )
            return .consumedCancelInertia
        }

        // A compact split still needs the cached alt-screen semantic-forward
        // path above, but primary history belongs to the native live painter.
        // Route it through the shared live-history handler without
        // constructing or touching an overlay runtime.
        guard usesDetachedMoshHistoryOverlay(window: window) else {
            return handleMoshLiveHistoryScroll(view: view, pointsY: pointsY,
                proposedOffsetY: proposedOffsetY, maxOffsetY: maxOffsetY,
                isInertial: isInertial)
        }
        guard moshPaneScrollbackFrame(for: paneId) != nil else {
            logMoshScrollbackGate("overlay-skip reason=no-pane-frame")
            return .consumedCancelInertia
        }

        if let overlay = moshPaneScrollbackOverlay,
           overlay.paneId == paneId, overlay.windowId == window.id,
           overlay.pendingScrollPlacement != nil || overlay.pendingDeferredHistory != nil
            || tmux.isHistoryPresentationPending(for: moshOverlaySurfaceID(paneId)) {
            overlay.pendingScrollDirection = pointsY
            moshRenderLedgerAdapter.noteHistoryRequest(surfaceID: moshOverlaySurfaceID(paneId),
                pointsY: pointsY, isInertial: isInertial)
            return .consumedLocalScroll
        }

        guard pointsY > 0 else {
            if let overlay = moshPaneScrollbackOverlay,
               overlay.paneId == paneId,
               overlay.windowId == window.id {
                // Same passivity rule as scroll-up: a glide never scrolls
                // through a capture's in-flight/anchor window (a parked
                // deferred history batch counts — its settle apply is imminent).
                if isInertial,
                   overlay.pendingScrollPlacement != nil
                    || overlay.pendingDeferredHistory != nil {
                    return .consumedCancelInertia
                }
                scrollMoshPaneScrollbackOverlay(
                    overlay,
                    pointsY: pointsY,
                    isInertial: isInertial
                )
                // If this reached the live bottom the overlay was just
                // dismissed — the next glide frame finds no overlay and
                // stops there. Local motion either way.
                return .consumedLocalScroll
            }
            // No overlay: at the live screen already. The interaction
            // probe can end in a semantic alt-screen forward, so glide
            // frames must not fire it (or scroll further down).
            guard !isInertial else { return .consumedCancelInertia }
            logMoshScrollbackGate(
                "overlay-skip reason=no-overlay-scroll-down-probe pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY))"
            )
            probeMoshPaneInteractionForAltScreenScroll(
                view: view,
                paneId: paneId,
                pointsY: pointsY,
                reason: "no-overlay-scroll-down"
            )
            return .consumedCancelInertia
        }

        // A glide may deepen existing history, but cannot create a new
        // overlay after a lifecycle change has dismissed its reader.
        if isInertial {
            guard let overlay = moshPaneScrollbackOverlay,
                  overlay.paneId == paneId, overlay.windowId == window.id
            else { return .consumedCancelInertia }
        }

        let overlay = ensureMoshPaneScrollbackOverlay(paneId: paneId, windowId: window.id)
        let hasPresentedHistory = moshOverlayContentReadyId == overlay.id
        let beforeY = overlay.desiredScrollOffsetY ?? overlay.box.view?.contentOffset.y ?? 0
        let scrollState = scrollMoshPaneScrollbackOverlay(overlay, pointsY: pointsY, isInertial: isInertial)
        if isInertial, scrollState == nil { return .consumedCancelInertia }
        let overlayOffsetY = scrollState?.offsetY
            ?? overlay.desiredScrollOffsetY
            ?? overlay.box.view?.contentOffset.y
            ?? 0
        let overlayMaxOffsetY = scrollState?.maxOffsetY
            ?? overlay.box.view.map { max(0, $0.contentSize.height - $0.bounds.height) }
            ?? maxOffsetY
        let isAtTop = moshOverlayContentReadyId != overlay.id
            || overlayOffsetY <= Self.moshScrollbackTopThreshold
            || overlayMaxOffsetY <= Self.moshScrollbackTopThreshold
        guard isAtTop else {
            return .consumedLocalScroll
        }
        requestMoshHistory(
            surfaceID: moshHistorySurfaceID(paneID: paneId, window: window),
            // Offset already committed above belongs to the pre-bind snapshot.
            // Only its unapplied remainder should move the replacement page.
            pointsY: pointsY - (hasPresentedHistory ? Double((beforeY - overlayOffsetY) / 3) : 0),
            isInertial: isInertial,
            reason: "overlay-scroll"
        )
        return tmux.isHistoryPresentationPending(for: moshOverlaySurfaceID(paneId))
            || abs(beforeY - overlayOffsetY) > 0.1
            ? .consumedLocalScroll : .consumedCancelInertia
    }

    private func probeMoshPaneInteractionForAltScreenScroll(
        view: TerminalView,
        paneId: PaneId,
        pointsY: Double,
        reason: String
    ) {
        guard pointsY != 0 else { return }
        let connectionGeneration = tmux.controlConnectionGeneration
        guard moshPaneInteractionProbeInFlight[paneId]?.connectionGeneration != connectionGeneration else {
            pendingMoshInteractionProbeScrollPointsByPane[paneId, default: 0] += pointsY
            logMoshScrollbackGate(
                "overlay-skip reason=interaction-probe-in-flight pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY))"
            )
            return
        }

        let probeID = UUID()
        moshPaneInteractionProbeInFlight[paneId] = (probeID, connectionGeneration)
        pendingMoshInteractionProbeScrollPointsByPane.removeValue(forKey: paneId)
        MoshDiagnostics.log(
            "mosh scrollback interaction probe begin reason=\(reason) pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY))"
        )
        let windowID = moshActiveWindow?.id
        tmux.sendControlCommand(
            "display-message -p -t \(paneId.description) '#{alternate_on}|#{mouse_any_flag}|#{mouse_sgr_flag}'"
        ) { result in
            // A retired callback must not drain a replacement probe's points.
            guard moshPaneInteractionProbeInFlight[paneId]?.id == probeID else { return }
            moshPaneInteractionProbeInFlight.removeValue(forKey: paneId)
            let pendingPoints =
                pendingMoshInteractionProbeScrollPointsByPane.removeValue(forKey: paneId) ?? 0
            guard tmux.controlConnectionGeneration == connectionGeneration else { return }
            let totalPoints = pointsY + pendingPoints
            guard case .success(let lines) = result,
                  let line = lines.first,
                  line.split(separator: "|").count == 3,
                  moshActiveWindow?.id == windowID,
                  moshActiveWindow?.panes.contains(where: { $0.id == paneId }) == true
            else {
                MoshDiagnostics.log(
                    "mosh scrollback interaction probe skipped pane=\(paneId.description) reason=no-state pointsY=\(String(format: "%.2f", totalPoints))"
                )
                return
            }

            let flags = line.split(separator: "|")
            guard flags[0] == "1" else {
                MoshDiagnostics.log(
                    "mosh scrollback interaction probe primary pane=\(paneId.description) pointsY=\(String(format: "%.2f", totalPoints))"
                )
                return
            }

            // The gesture may have lost permission while the remote query
            // was in flight. Do not deliver its queued input into a new view,
            // a disconnected session, or a newly protected agent surface.
            guard terminalBox.view === view,
                  presentationSessionState == .connected,
                  tmux.mode == .tmuxControl,
                  !terminalInputGatedByAuthority,
                  agentScrollPrevention(paneID: paneId.rawValue) == nil
            else { return }

            forwardMoshPaneAltScreenScroll(
                view: view,
                paneId: paneId,
                pointsY: totalPoints,
                mouseReporting: flags[1] == "1",
                useSgrMouse: flags[2] == "1",
                reason: "interaction-probe"
            )
        }
    }

    /// Shared config for the split-grid alt-screen dispatcher (initial
    /// @State value + capture-state reset must stay identical). The
    /// thresholds are tuned for the scroll PROXY's smooth 120Hz delta
    /// stream — the old 1pt/3pt values compensated for throttled 24-40ms
    /// bridge events and would flood the pty (up to ~960 arrow keys/s)
    /// now that deltas arrive per display frame.
    private static func makeMoshSplitAltScreenScrollDispatcher() -> ScrollDispatcher {
        ScrollDispatcher(config: .init(
            pointsPerArrowKey: 8,
            mouseWheelThresholdPoints: 6,
            maxEventsPerFlush: 8
        ))
    }

    /// Where (and whether) the alt-screen scroll proxy mounts: over the
    /// active pane of a mosh+tmux grid whose cached interaction state says
    /// alt-screen. The proxy gives a trackpad pan a local UIScrollView to
    /// move from event 1 — without it iPadOS throttles the whole update
    /// cycle during the pan (round-7 finding) and semantic forwards run at
    /// ~1 wheel notch per 350ms. Cache-miss panes (state not yet probed)
    /// keep riding the bridge path until pane metadata mounts the proxy
    /// for the next gesture.
    private var moshAltScreenScrollProxyTarget: (paneId: PaneId, frame: CGRect)? {
        guard session.host.launchMode != .customCommand,
              presentationSessionState == .connected,
              tmux.mode == .tmuxControl,
              // Never mount over REVEALED scrollback: a pane can flip to
              // alt-screen while the reader sits in a frozen snapshot
              // (output opened less/vim mid-read). The proxy on top would
              // swallow every scroll, starve the overlay's bottom
              // dismissal, and silently drive the hidden TUI — the reader
              // scrolls out of the snapshot first, then the proxy mounts.
              moshOverlayContentReadyId == nil,
              let window = moshActiveWindow,
              window.rendersAsPaneGrid,
              let paneId = window.activePaneId ?? tmux.activePaneId,
              let pane = window.panes.first(where: { $0.id == paneId }),
              pane.isAlternateScreen == true,
              let frame = moshPaneScrollbackFrame(for: paneId)
        else { return nil }
        return (paneId, frame.surfaceFrame)
    }

    /// Tracked motion from the alt-screen scroll proxy → semantic forward.
    /// Same encoder as the bridge path (wheel or arrows via the split
    /// dispatcher); the proxy only forwards while fingers are on the pad,
    /// so the no-motion-after-release policy holds without an isInertial
    /// check here.
    private func handleMoshAltScreenProxyScroll(paneId: PaneId, pointsY: Double) {
        // The proxy normally unmounts as soon as the lifecycle gate turns on.
        // Revalidate here as well so a delta already queued by UIKit at that
        // transition cannot leak a wheel/arrow event into the remote TUI.
        if agentScrollPrevention(paneID: paneId.rawValue) != nil {
            presentAgentScrollPrevention(paneID: paneId.rawValue)
            return
        }
        guard session.host.launchMode != .customCommand,
              presentationSessionState == .connected,
              tmux.mode == .tmuxControl,
              let window = moshActiveWindow,
              let pane = window.panes.first(where: { $0.id == paneId }),
              pane.isAlternateScreen == true,
              let view = terminalBox.view
        else { return }
        forwardMoshPaneAltScreenScroll(
            view: view,
            paneId: paneId,
            pointsY: pointsY,
            mouseReporting: pane.isMouseReporting == true,
            useSgrMouse: pane.isSgrMouse == true,
            reason: "alt-proxy"
        )
    }

    private func forwardMoshPaneAltScreenScroll(
        view: TerminalView,
        paneId: PaneId,
        pointsY: Double,
        mouseReporting: Bool,
        useSgrMouse: Bool,
        reason: String
    ) {
        guard pointsY != 0 else { return }
        let target = moshPaneAltScreenScrollTarget(paneId: paneId, in: view)
        let state = ScrollDispatcher.TerminalState(
            isAltScreen: true,
            mouseReporting: mouseReporting ? .vt200OrLater : .off
        )
        var dispatcher = moshSplitAltScreenScrollDispatcher
        let actions = dispatcher.handle(
            event: .init(
                deltaY: pointsY,
                cursorColumn: target.column,
                cursorRow: target.row,
                phase: .changed
            ),
            terminal: state
        )
        moshSplitAltScreenScrollDispatcher = dispatcher
        var forwardedCount = 0
        let terminal = view.getTerminal()
        for action in actions {
            switch action {
            case .scrollbackDelta:
                break
            case .mouseWheel(let buttonFlags, let cursorColumn, let cursorRow, let repeatCount):
                forwardedCount += repeatCount
                for _ in 0..<repeatCount {
                    if useSgrMouse {
                        sendMoshSgrMouseEvent(
                            buttonFlags: buttonFlags,
                            column: cursorColumn,
                            row: cursorRow
                        )
                    } else {
                        terminal.sendEvent(
                            buttonFlags: buttonFlags,
                            x: max(0, cursorColumn - 1),
                            y: max(0, cursorRow - 1)
                        )
                    }
                }
            case .writeBytes(let bytes):
                forwardedCount += bytes.count / 3
                terminalBox.noteOutOfBandInput()
                _ = session.sessionCommands(tmux: tmux).dispatch(.sendTmuxPaneInput(
                    data: Data(bytes), paneID: paneId.description, receipt: nil
                ))
            }
        }
        let shouldLog: Bool
        if reason == "alt-proxy" {
            // Proxy deltas arrive per display frame — sample the log so a
            // scroll session doesn't wipe the diagnostics ring buffer.
            scrollDiagnostics.altProxyEventCount += 1
            shouldLog = forwardedCount > 0
                && scrollDiagnostics.altProxyEventCount % 30 == 1
        } else {
            shouldLog = true
        }
        if shouldLog {
            MoshDiagnostics.log(
                "mosh scrollback forward alt-screen scroll reason=\(reason) pane=\(paneId.description) pointsY=\(String(format: "%.2f", pointsY)) mouse=\(mouseReporting) sgr=\(useSgrMouse) forwarded=\(forwardedCount) column=\(target.column) row=\(target.row)"
            )
        }
    }

    private func moshPaneAltScreenScrollTarget(
        paneId: PaneId,
        in view: TerminalView
    ) -> (column: Int, row: Int) {
        let terminal = view.getTerminal()
        guard let rect = moshPaneScrollbackContentRect(for: paneId) else {
            return (
                column: max(1, (terminal.cols + 1) / 2),
                row: max(1, (terminal.rows + 1) / 2)
            )
        }
        let column = rect.x + max(0, rect.width / 2) + 1
        let row = rect.y + max(0, rect.height / 2) + 1
        return (
            column: max(1, min(terminal.cols, column)),
            row: max(1, min(terminal.rows, row))
        )
    }

    private func sendMoshSgrMouseEvent(buttonFlags: Int, column: Int, row: Int) {
        let sequence = "\u{1B}[<\(buttonFlags);\(column);\(row)M"
        session.sessionCommands.sendInput(Array(sequence.utf8))
    }

    @discardableResult
    private func scrollMoshPaneScrollbackOverlay(
        _ overlay: MoshPaneScrollbackOverlayRuntime,
        pointsY: Double,
        isInertial: Bool = false
    ) -> (offsetY: CGFloat, maxOffsetY: CGFloat)? {
        guard let view = overlay.box.view else { return nil }
        if view.isTracking || view.isDragging || view.isDecelerating {
            // A native pan/deceleration owns this view's contentOffset —
            // bridge and glide writers yield rather than fight it (an
            // inertial caller reads the nil as "didn't move" and cancels).
            return nil
        }
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        // Only a REAL gesture may override a pending post-capture placement.
        // A glide synthesizes frames straight through the capture landing —
        // if those cleared the placement, the offset rebase would silently
        // skip and the view would teleport to the fed tail instead of the
        // .top/.bottomMinus anchor.
        if maxOffsetY > 0, overlay.pendingScrollPlacement != nil, !isInertial {
            overlay.pendingScrollPlacement = nil
            overlay.pendingScrollPlacementRevision += 1
        }
        let currentY = overlay.desiredScrollOffsetY ?? view.contentOffset.y
        let newY = currentY - CGFloat(pointsY) * 3
        let offsetY = overlay.applyDesiredScrollOffset(newY, in: view)
        recordMoshScrollDiagnostic(
            "surface=overlay window=\(overlay.windowId.description) pane=\(overlay.paneId.description) primary-write points=\(String(format: "%.1f", pointsY)) before=\(Self.format(currentY)) proposed=\(Self.format(newY)) after=\(Self.format(offsetY)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
        )

        if pointsY < 0,
           offsetY >= maxOffsetY {
            dismissMoshPaneScrollbackOverlay(
                clearDepth: true,
                reason: "bottom",
                returnedToTail: true
            )
        }

        return (offsetY, maxOffsetY)
    }

    private func handleMoshLiveHistoryScroll(
        view: TerminalView,
        pointsY: Double,
        proposedOffsetY: CGFloat,
        maxOffsetY: CGFloat,
        isInertial: Bool
    ) -> TerminalPrimaryScrollConsumption {
        guard pointsY != 0 else { return .notConsumed }
        guard session.host.launchMode != .customCommand else {
            logMoshScrollbackGate("skip reason=custom-command")
            return .notConsumed
        }
        guard presentationSessionState == .connected else {
            logMoshScrollbackGate("skip reason=session-not-connected state=\(MoshDiagnostics.stateDescription(presentationSessionState))")
            return .notConsumed
        }
        guard tmux.mode == .tmuxControl else {
            logMoshScrollbackGate("skip reason=tmux-not-ready mode=\(tmux.mode)")
            return .notConsumed
        }
        guard let paneId = tmux.activePaneId else {
            logMoshScrollbackGate("skip reason=no-active-pane")
            return .notConsumed
        }
        guard !usesDetachedMoshHistoryOverlay() else {
            logMoshScrollbackGate("skip reason=detached-pane-overlay")
            return .notConsumed
        }
        guard terminalBox.view === view else {
            logMoshScrollbackGate("skip reason=view-mismatch")
            return .notConsumed
        }

        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else {
            logMoshScrollbackGate("skip reason=alt-screen pane=\(paneId.description)")
            return .notConsumed
        }
        // A tmux visible client enables mouse reporting for its own bindings
        // even at a shell prompt. The pane metadata checked by the caller,
        // and again by the history ledger, decides whether a TUI owns input.

        // History stays pending until the matching owner has been fed AND
        // placed. Neither its empty rebind buffer nor its transient tail is a
        // real scroll boundary. Keep the same gesture/glide alive, without
        // writing an offset that would race the page's placement.
        if tmux.isHistoryPresentationPending(for: .live) {
            moshRenderLedgerAdapter.noteHistoryRequest(surfaceID: .live,
                pointsY: pointsY, isInertial: isInertial)
            return .consumedLocalScroll
        }
        if pointsY < 0, !isInertial, !moshLiveHistoryRevealed,
           view.contentOffset.y >= maxOffsetY {
            // Mosh's visible framebuffer need not repeat terminal mode flags
            // after a history repaint. At the live bottom, a downward gesture
            // may therefore be the first input to a newly opened TUI. Use the
            // same pane-state probe as detached history, in both directions.
            probeMoshPaneInteractionForAltScreenScroll(
                view: view, paneId: paneId, pointsY: pointsY,
                reason: "live-tail-scroll-down")
            return .consumedCancelInertia
        }
        guard pointsY > 0, proposedOffsetY <= Self.moshScrollbackTopThreshold else {
            return .notConsumed
        }
        guard !terminalBox.isAwaitingContentAfterRebind else { return .notConsumed }
        requestMoshHistory(surfaceID: .live, pointsY: pointsY,
            isInertial: isInertial, reason: "primary-underflow")
        return tmux.isHistoryPresentationPending(for: .live)
            ? .consumedLocalScroll : .notConsumed
    }

    /// The compact/iPhone presentation uses `.live` rather than a detached
    /// overlay. Its native SwiftTerm scroll view is therefore the local signal
    /// that an output-frozen history reader reached the mosh-painted tail.
    private func handleMoshLiveTerminalScrolled(_ view: TerminalView) {
        guard terminalBox.view === view else { return }
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        guard MoshLiveHistoryTailReleasePolicy.shouldRelease(
            isHistoryRevealed: moshLiveHistoryRevealed,
            hasPendingPresentation: pendingMoshLiveHistoryPresentation != nil
                || tmux.isHistoryPresentationPending(for: .live),
            isRebinding: terminalBox.isRebinding,
            isAwaitingContent: terminalBox.isAwaitingContentAfterRebind,
            offsetY: view.contentOffset.y,
            maxOffsetY: maxOffsetY
        ) else { return }
        // Sampled first: the fact below rebinds, and so clears, the view.
        let offsetY = view.contentOffset.y
        moshLiveHistoryRevealed = false
        tmux.submitRenderFact(.scrollbackReturnedToTail(.live))
        recordMoshScrollDiagnostic(
            "render-ledger live-returned-tail offset=\(Self.format(offsetY)) max=\(Self.format(maxOffsetY))"
        )
    }

    /// The mosh shared terminal surface. Extracted from `body` as a concrete
    /// `TerminalSurfaceBound` (not `some View`) so the SwiftUI body stays under
    /// the type-checker's complexity budget — the full inline call plus its many
    /// closures tips "unable to type-check this expression in reasonable time".
    private var moshTerminalSurface: TerminalSurfaceBound {
        TerminalSurfaceBound(
            initialData: [],
            onMade: { view in terminalBox.attach(view) },
            onReady: {
                terminalBox.markRenderReady()
                if let pending = pendingMoshLiveHistoryPresentation {
                    applyPendingMoshLiveHistoryPresentation(
                        id: pending.id,
                        surfaceID: .live,
                        attemptsRemaining: 30
                    )
                }
                restorePendingMoshWindowModesAfterHistory(surfaceID: .live)
            },
            onSend: { bytes in
                guard !showsLaunchOverlay, !terminalInputGatedByAuthority else {
                    // Refused bytes never reach the PTY: drop the UIKit input
                    // mirror so later edits cannot delete what it believes was typed.
                    terminalBox.noteOutOfBandInput()
                    return
                }
                if !isAutomaticTerminalColorResponse(bytes) {
                    invalidateMoshScrollbackForTerminalInput(reason: "terminal-input")
                }
                let input = Array(bytes)
                session.sessionCommands.sendInput(input)
            },
            onResize: { cols, rows in
                // Once the compact tmux canvas is active this inner SwiftTerm
                // surface is intentionally framed at the full server grid.
                // Only the outer viewport callback represents phone geometry.
                guard !(isPhone && tmux.mode == .tmuxControl) else { return }
                if let previous = lastTerminalSize,
                   previous.cols != cols || previous.rows != rows {
                    resetMoshScrollbackCapture(clearLocal: true, reason: "resize")
                }
                lastTerminalSize = (cols, rows)
                guard isActive else { return }
                session.sessionCommands(tmux: tmux).resize(columns: cols, rows: rows)
                tmuxControlBox.channel?.resize(cols: cols, rows: rows)
            },
            onTitle: { title in
                tmux.updateActiveWindowName(title)
                currentTerminalTitle = title
            },
            onUserActivity: {
                appLockController.notifyUserActivity()
            },
            onBell: {
                bellController.ring(
                    source: .session(session.host.id),
                    isOriginOnScreen: true,
                    hostDisplayName: session.host.name,
                    paneTitle: currentTerminalTitle
                )
            },
            onPrimaryScrollbackDelta: handleMoshPrimaryScrollbackDelta,
            primaryScrollPaneAtLocation: moshScrollPaneAtLocation,
            primaryTouchScrollIsLocalForPane: { moshPrimaryTouchScrollIsLocal(paneID: $0) },
            remotePaneReportsMouse: { moshActivePaneReportsMouse },
            touchPansTakePointerRoute: { moshTouchPansTakePointerRoute },
            remoteHistoryRevealed: { moshRemoteHistoryRevealed },
            agentScrollBlockingActive:
                !sessionIsControlledElsewhere
                    && !usesDetachedMoshHistoryOverlay()
                    && agentScrollPrevention(paneID: activeAgentScrollPaneID) != nil,
            onAgentScrollBlocked: {
                presentAgentScrollPrevention(paneID: activeAgentScrollPaneID)
            },
            mouseReportingImpliesAltScreen: tmux.mode != .tmuxControl,
            suppressDirectColorQueryResponses: false,
            softwareModifierState: modifierState,
            tmuxShortcutsEnabled: true,
            onTmuxShortcut: { shortcut in
                appLockController.notifyUserActivity()
                handleTmuxShortcut(shortcut)
            },
            onFindShortcut: { shortcut in
                appLockController.notifyUserActivity()
                switch shortcut {
                case .open:     findController.open()
                case .next:     findController.next()
                case .previous: findController.previous()
                }
            },
            onSwitcherShortcut: { shortcut in
                appLockController.notifyUserActivity()
                handleSwitcherShortcut(shortcut)
            },
            onOpenSettings: {
                appLockController.notifyUserActivity()
                onOpenSettings()
            },
            onOpenAgentCenter: onOpenAgentCenter.map { action in
                {
                    appLockController.notifyUserActivity()
                    action()
                }
            },
            // `!isActive`: a backgrounded (mounted, opacity-0) mosh session must
            // not reclaim first responder from the foreground (e.g. host editor).
            suppressFirstResponderReclaim: integrationScrollHarnessSuppressesFirstResponder
                || !isActive
                || findController.isOpen
                || commandPalette.isOpen
                || filesPanel.textEntryActive
                || modifierState.suppressesSoftwareKeyboardReclaim
                || sessionIsControlledElsewhere,
            forceResignFirstResponder: sessionIsControlledElsewhere,
            onHardwareKey: { key in
                // While authority is unresolved or yielded, a page key is
                // never bytes into the PTY the peer is using (the GCKeyboard
                // passthrough can fire before the veil's focus grab lands),
                // and never a take-back either: D8 admits only a tap,
                // Return or a printable key.
                if terminalInputGatedByAuthority {
                    terminalBox.noteOutOfBandInput()
                    return
                }
                let bytes = key.escapeSequence
                MoshDiagnostics.log(
                    "mosh hardware key type=\(String(describing: key)) bytes=\(bytes.count)"
                )
                invalidateMoshScrollbackForTerminalInput(reason: "hardware-key")
                session.sessionCommands.sendInput(bytes)
            },
            onTerminalScrolled: handleMoshLiveTerminalScrolled,
            scrollRetentionID: [
                "mosh",
                "shared",
                tmux.activeWindowId?.description ?? "nil",
                tmux.activePaneId?.description ?? "nil",
            ].joined(separator: ":"),
            onScrollDiagnostic: { message in
                recordMoshScrollDiagnostic("surface=shared \(message)")
            },
            onHostDirectory: { dir in
                // Plain mosh: OSC 7 arrives via the fork's framebuffer
                // cwd sync (mirrors OSC 52). Under tmux the pane
                // subscription owns cwd instead.
                guard tmux.mode == .passthrough else { return }
                filesPanel.terminalReportedDirectory(dir)
            },
            onFilesShortcut: {
                appLockController.notifyUserActivity()
                toggleFilesPanel()
            },
            onCustomShortcut: { shortcut in
                guard !showsLaunchOverlay, !terminalInputGatedByAuthority else {
                    // Refused bytes never reach the PTY: drop the UIKit input
                    // mirror so later edits cannot delete what it believes was typed.
                    terminalBox.noteOutOfBandInput()
                    return
                }
                guard shouldFire(shortcut) else { return }
                appLockController.notifyUserActivity()
                let cursor = terminalBox.view?.getTerminal().applicationCursor ?? false
                let bytes = shortcut.encoded(applicationCursor: cursor)
                invalidateMoshScrollbackForTerminalInput(reason: "custom-shortcut")
                session.sessionCommands.sendInput(bytes)
            },
            onSelectionPathAction: { action, text in
                handleSelectionPathAction(action, text: text)
            },
            // Mosh paints the split natively in the single shared surface (no
            // grid mounts), so there is no per-pane surface to carry this flag —
            // wire it here off the side-channel active window's pane count. With
            // >1 pane the bare ⌘[/⌘] pane-cycle and ⌘⇧Return zoom chords go live
            // (dispatched over the side channel via handleTmuxShortcut, behind
            // the degraded gate); with a single pane they no-op and the session
            // switcher keeps ⌘[/⌘]. ⌘D split stays available either way (gated on
            // tmuxShortcutsEnabled, not this flag).
            paneCycleEnabled: moshPaneCycleEnabled,
            // Tap-to-focus: when the active window is split, a tap on the shared
            // surface selects the pane under the finger over the side channel
            // (the remote tmux paints the panes; we only move focus). Gated on
            // the same multi-pane predicate so single-pane mosh keeps SwiftTerm's
            // tap/selection behaviour untouched.
            onPaneFocusTap: handleMoshPaneFocusTap,
            paneFocusTapEnabled: moshPaneCycleEnabled,
            terminalBackground: resolvedTerminalBackground
        )
    }

    private var shouldBlockTmuxShortcut: Bool {
        session.host.launchMode != .customCommand
            && presentationSessionState == .connected
            && tmuxSideChannelState.blocksTmuxCommands
    }

    private func showTmuxShortcutBlockedToast(shortcut: TesseraTmuxShortcut) {
        presentTmuxBlockedToast(logReason: "shortcut=\(shortcut.logDescription)")
    }

    /// Shared "side channel is reconnecting / degraded" toast, used by both the
    /// blocked chords and tap-to-focus when `shouldBlockTmuxShortcut` is true.
    private func presentTmuxBlockedToast(logReason: String) {
        MoshDiagnostics.log(
            "mosh tmux command blocked \(logReason) state=\(tmuxSideChannelState.logDescription)"
        )
        tmuxShortcutToastTask?.cancel()
        tmuxShortcutToastVisible = true
        tmuxShortcutToastTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            tmuxShortcutToastVisible = false
            tmuxShortcutToastTask = nil
        }
    }

    /// Maps a tap on the mosh shared surface to a pane and selects it over the
    /// side channel — iTerm2 behaviour: focus only, never a click into the
    /// in-pane TUI. The remote tmux client paints the split into the UDP
    /// terminal, so there is no per-pane surface to route through; the layout
    /// tracked on the render-inert side channel drives the hit test. Returns
    /// `true` when the tap is consumed (hit a non-focused pane, or showed the
    /// degraded toast); a tap on the focused pane, a divider gutter, or a
    /// single-pane window returns `false` and the caller does nothing.
    ///
    /// A `select-pane` only moves `activePaneId`, never `activeWindowId`, so it
    /// cannot trip the mosh window-change scrollback clear (pinned controller
    /// test). Our own echo is suppressed in the controller like the SSH path.
    private func handleMoshPaneFocusTap(at point: CGPoint, cellSize: CGSize) -> Bool {
        guard let snapshot = moshPaneChromeSnapshot() else { return false }

        let frames = moshPaneChromeFrames(for: snapshot, cellSize: cellSize)
        guard let hit = frames.first(where: { $0.paneBox.contains(point) }) else { return false }

        // Header close affordance — only when actually split (frames.count > 1,
        // so a zoomed single-leaf render shows none). Checked BEFORE focus so
        // tapping a pane's x closes it without also dispatching select-pane to a
        // pane that's about to die.
        if frames.count > 1,
           PaneLayoutMath.headerCloseButtonRect(for: hit, cellSize: cellSize).contains(point) {
            if shouldBlockTmuxShortcut {
                presentTmuxBlockedToast(logReason: "paneClose pane=\(hit.paneId.description)")
                return true
            }
            appLockController.notifyUserActivity()
            _ = session.sessionCommands(tmux: tmux).dispatch(
                .closeTmuxPane(hit.paneId.description)
            )
            return true
        }

        // Tapping the already-focused pane is a no-op: no redundant select-pane,
        // and crucially no click forwarded into a mouse-aware app in that pane.
        guard hit.paneId != snapshot.activePaneId else { return false }

        if shouldBlockTmuxShortcut {
            presentTmuxBlockedToast(logReason: "paneFocusTap pane=\(hit.paneId.description)")
            return true
        }

        appLockController.notifyUserActivity()
        modifierState.showSoftwareKeyboard()
        _ = session.sessionCommands(tmux: tmux).dispatch(
            .selectTmuxPane(hit.paneId.description)
        )
        return true
    }

    /// The layout tmux is actually painting on the shared surface: the single
    /// zoomed leaf while zoomed, else the full split layout. Drives both the ✕
    /// overlay and the tap hit-test so chrome and touch targets match the pixels.
    /// Mirrors `PaneGridView.renderLayout`.
    private var moshRenderLayout: WindowLayout? {
        guard let window = moshActiveWindow else { return nil }
        return window.isZoomed ? (window.visibleLayout ?? window.layout) : window.layout
    }

    /// Cell size of the mosh shared terminal — used to position the ✕ overlay and
    /// hit-test taps. Reads the live terminal font via the same `TerminalCellMetrics`
    /// helper the SSH grid uses, so the overlay and the UIKit tap recognizer's
    /// `cellDimensions(for:)` agree to the pixel.
    private var moshCellSize: CGSize? {
        terminalBox.view.map { TerminalCellMetrics.cellSize(for: $0) }
    }

    /// Transient cover for tmux's native pane-title rows during split /
    /// collapse transitions (the chrome overlay unmounts before tmux repaints
    /// the reclaimed rows). With a background picture it paints the aligned
    /// backdrop crop so the mask is invisible against the session backdrop;
    /// otherwise the plain theme color, as before.
    @ViewBuilder
    private func moshChromeTransitionMask(rects: [CGRect]) -> some View {
        if let background = resolvedTerminalBackground {
            TerminalBackdrop(
                background: background,
                baseColor: activeTheme.bg,
                bleed: moshOverlayBackdropBleed
            )
            .clipShape(FixedRectsShape(rects: rects))
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.self) { rect in
                    Rectangle()
                        .fill(activeTheme.bg)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The scrollback overlay is mounted in the inset terminal coordinate
    /// space, while the session backdrop now spans the whole screen. Expanding
    /// its duplicate by the surrounding chrome reconstructs the same image
    /// dimensions and origin before the pane clip is applied.
    private var moshOverlayBackdropBleed: EdgeInsets {
        let topBar = SessionTopBar.reservedHeight(
            pillHeight: appearance.topBarHeight,
            compact: isPhone
        )
        let findBar = findController.isOpen ? CGFloat(appearance.topBarHeight + 4) : 0
        return EdgeInsets(
            top: topBar + findBar,
            leading: SessionView.cornerInset,
            bottom: appearance.showAccessoryBar ? SessionAccessoryBar.reservedBandHeight() : 0,
            trailing: SessionView.cornerInset
        )
    }

    private static func tmuxReconnectDelay(for attempt: Int) -> TimeInterval {
        let shift = min(max(attempt - 1, 0), 4)
        let uncapped = 1 << shift
        return TimeInterval(min(uncapped, 15))
    }

    private static func formatDelay(_ delay: TimeInterval) -> String {
        if delay.rounded() == delay {
            return "\(Int(delay))s"
        }
        return String(format: "%.1fs", delay)
    }
}

/// Invisible UIScrollView mounted over an alt-screen pane in a mosh+tmux
/// grid. Same principle as the scrollback overlay's native path (M1/M2):
/// during a trackpad pan iPadOS throttles the whole UIKit update cycle
/// unless something is presenting, so a pan that only produces semantic
/// forwards runs at coalesced 24-40ms events. Giving the pan its own
/// scroll view to move from event 1 keeps the cycle hot; the offset
/// motion is forwarded semantically (wheel/arrow encoding upstream) and
/// the offset itself is recentered so the surface never hits an edge
/// (Apple StreetScroller pattern — safe mid-pan because pan tracking is
/// delta-based).
///
/// Policy mirrors the bridge path: only TRACKED motion forwards — the
/// remote TUI must never keep receiving motion after the fingers left
/// the trackpad, so deceleration is killed at release. Non-scroll hits
/// pass through to the live pane beneath (clicks/taps keep working).
final class MoshAltScreenScrollProxyView: UIScrollView, UIScrollViewDelegate {
    var onScrollDelta: ((Double) -> Void)?

    private var lastOffsetY: CGFloat = 0
    private var isAdjustingOffset = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        // Recentering keeps both edges unreachable, so bounce physics
        // never engage; disabling them is belt-and-braces against an
        // edge-pin swallowing didScroll (the M2 lesson).
        bounces = false
        alwaysBounceVertical = false
        panGestureRecognizer.allowedScrollTypesMask = .all
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Scroll-only delivery, same rule as the scrollback overlay's
    /// container: clicks, taps, and finger touches fall through to the
    /// live shared surface (htop clicks must keep landing). `nil` events
    /// pass through — conservative direction.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type != .scroll { return nil }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let targetHeight = max(bounds.height * 8, 4000)
        if abs(contentSize.height - targetHeight) > 0.5
            || abs(contentSize.width - bounds.width) > 0.5 {
            contentSize = CGSize(width: bounds.width, height: targetHeight)
            recenter()
        } else {
            recenterIfNeeded()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjustingOffset else { return }
        let delta = Double(lastOffsetY - contentOffset.y)
        lastOffsetY = contentOffset.y
        // Deltas only while fingers are on the pad: deceleration (or any
        // programmatic motion) must not turn into semantic forwards.
        guard isTracking || isDragging, delta != 0 else { return }
        onScrollDelta?(delta)
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        if decelerate {
            // Kill momentum at release — a same-offset set ends it — so
            // the proxy never sits in a ghost isDecelerating state.
            setContentOffset(contentOffset, animated: false)
        }
        recenterIfNeeded(force: true)
    }

    private func recenterIfNeeded(force: Bool = false) {
        let centerY = max(0, (contentSize.height - bounds.height) / 2)
        let distance = abs(contentOffset.y - centerY)
        guard force ? distance > 0.5 : distance > bounds.height * 2 else { return }
        recenter()
    }

    private func recenter() {
        let centerY = max(0, (contentSize.height - bounds.height) / 2)
        isAdjustingOffset = true
        contentOffset = CGPoint(x: contentOffset.x, y: centerY)
        lastOffsetY = centerY
        isAdjustingOffset = false
    }
}

private struct MoshAltScreenScrollProxy: UIViewRepresentable {
    let onScrollDelta: (Double) -> Void

    func makeUIView(context: Context) -> MoshAltScreenScrollProxyView {
        let view = MoshAltScreenScrollProxyView(frame: .zero)
        view.onScrollDelta = onScrollDelta
        return view
    }

    func updateUIView(_ uiView: MoshAltScreenScrollProxyView, context: Context) {
        uiView.onScrollDelta = onScrollDelta
    }
}

private struct MoshPaneScrollbackOverlay: View {
    let runtime: MoshPaneScrollbackOverlayRuntime
    let paneFrame: CGRect
    /// Background picture treatment, mirrored from the shared surface. The
    /// overlay stacks OVER live content, so it can't simply be transparent —
    /// it mounts its own opaque copy of the backdrop, clipped to the exact
    /// crop of the canvas-spanning one its pane covers (no shift on reveal),
    /// and its terminal goes transparent over that.
    let terminalBackground: ResolvedTerminalBackground?
    let backdropBaseColor: SwiftUI.Color
    let backdropBleed: EdgeInsets
    let onReady: () -> Void
    let onTerminalScrolled: (TerminalView) -> Void
    let onScrollDiagnostic: (String) -> Void
    let agentScrollBlockingActive: Bool
    let onAgentScrollBlocked: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let terminalBackground {
                TerminalBackdrop(
                    background: terminalBackground,
                    baseColor: backdropBaseColor,
                    bleed: backdropBleed
                )
                .clipShape(FixedRectShape(rect: paneFrame))
            }

            TerminalSurfaceBound(
                initialData: [],
                onMade: { view in runtime.box.attach(view) },
                onReady: {
                    runtime.box.markRenderReady()
                    onReady()
                },
                onSend: { _ in },
                onResize: { _, _ in },
                onTitle: { _ in },
                onUserActivity: nil,
                onBell: nil,
                agentScrollBlockingActive: agentScrollBlockingActive,
                onAgentScrollBlocked: onAgentScrollBlocked,
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in },
                onFindShortcut: nil,
                onSwitcherShortcut: nil,
                onOpenSettings: nil,
                suppressFirstResponderReclaim: true,
                onHardwareKey: nil,
                onTerminalScrolled: onTerminalScrolled,
                scrollRetentionID: [
                    "mosh-overlay",
                    runtime.windowId.description,
                    runtime.paneId.description,
                ].joined(separator: ":"),
                onScrollDiagnostic: { message in
                    onScrollDiagnostic(
                        "surface=overlay window=\(runtime.windowId.description) pane=\(runtime.paneId.description) \(message)"
                    )
                },
                nativeScrollSurface: true,
                terminalBackground: terminalBackground
            )
            .frame(width: paneFrame.width, height: paneFrame.height)
            .clipped()
            .offset(x: paneFrame.minX, y: paneFrame.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Hit-testability is decided at the mount site (revealed overlays
        // take scroll hits natively; hidden/parked ones take none) — the
        // container's scroll-only hitTest handles click pass-through.
    }
}

/// Reference box so we can capture the UIKit `TerminalView` out of
/// SwiftUI's value-type world and feed bytes into it from async code.
struct TerminalPerformanceFeedContext {
    let source: String
    let pane: String?
    let window: String?
    let generation: Int?
    let captureRows: Int?
    let reason: String?
    let originalByteCount: Int?

    init(_ context: TmuxController.TerminalFeedContext) {
        source = context.source.rawValue
        pane = context.paneId?.description
        window = context.windowId?.description
        generation = context.generation
        captureRows = context.captureRows
        reason = context.reason
        originalByteCount = context.originalByteCount
    }

    static func moshLive(originalByteCount: Int) -> TerminalPerformanceFeedContext {
        TerminalPerformanceFeedContext(
            source: "mosh-live",
            originalByteCount: originalByteCount
        )
    }

    private init(source: String, originalByteCount: Int) {
        self.source = source
        pane = nil
        window = nil
        generation = nil
        captureRows = nil
        reason = nil
        self.originalByteCount = originalByteCount
    }
}

private struct TerminalPerformanceFeedToken {
    let startedAt: CFTimeInterval
    let source: String
    let byteCount: Int
}

/// Verbose-only, burst-aggregated terminal timing. There is no payload
/// capture and no permanent sampler: one display link exists only while an
/// output burst is active, then one bounded summary is written after idle.
@MainActor
private final class TerminalPerformanceDiagnostics: NSObject {
    var sampleRenderedState: (() -> Void)?
    private struct SourceStats {
        var chunks = 0
        var bytes = 0
        var maxFeedMs: Double = 0
        var slowestFeedBytes = 0
        var maxOriginalBytes = 0
        var maxCaptureRows: Int?
    }

    private struct ActiveIngress {
        let byteCount: Int
        var burstGeneration: Int?
    }

    private struct Burst {
        let generation: Int
        let startedAt: CFTimeInterval
        var lastActivityAt: CFTimeInterval
        var lastFrameAt: CFTimeInterval
        var ingressChunks = 0
        var ingressBytes = 0
        var ingressMs: Double = 0
        var maxIngressMs: Double = 0
        var feedChunks = 0
        var feedBytes = 0
        var shellMs: Double = 0
        var rendererMs: Double = 0
        var feedMs: Double = 0
        var maxFeedMs: Double = 0
        var slowestFeedBytes = 0
        var maxOriginalBytes = 0
        var frameTicks = 0
        var maxFrameGapMs: Double = 0
        var frameGapsOver50ms = 0
        var maxMainQueueDelayMs: Double = 0
        var sources: [String: SourceStats] = [:]
        var lastPane: String?
        var lastWindow: String?
        var lastGeneration: Int?
        var maxCaptureRows: Int?
        var lastReason: String?
    }

    private static let idleFlushSeconds: CFTimeInterval = 0.5
    private static let maximumBurstSeconds: CFTimeInterval = 10
    private static let slowIngressOnlyMs: Double = 50
    private static let slowIngressLogInterval: CFTimeInterval = 60

    private let surface: String
    private var diagnosticHost = "unbound"
    func bindHost(_ id: UUID) { diagnosticHost = String(id.uuidString.prefix(8)) }
    private var cachedEnabled = false
    private var nextDefaultsCheckAt: CFTimeInterval = 0
    private var nextGeneration = 0
    private var burst: Burst?
    private var flushTask: Task<Void, Never>?
    private var expectedFlushAt: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var activeIngress: ActiveIngress?
    private var nextSlowIngressLogAt: CFTimeInterval = 0

    init(surface: String) {
        self.surface = surface
        super.init()
    }

    func beginIngress(byteCount: Int) -> CFTimeInterval? {
        let now = CACurrentMediaTime()
        guard diagnosticsEnabled(at: now) else { return nil }
        activeIngress = ActiveIngress(
            byteCount: byteCount,
            burstGeneration: nil
        )
        return now
    }

    func endIngress(startedAt: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let elapsedMs = max(0, now - startedAt) * 1_000
        let ingress = activeIngress
        activeIngress = nil

        if let generation = ingress?.burstGeneration,
           var burst,
           burst.generation == generation {
            burst.ingressMs += elapsedMs
            burst.maxIngressMs = max(burst.maxIngressMs, elapsedMs)
            burst.lastActivityAt = now
            self.burst = burst
            return
        }

        // Control-only ingress is normally sub-millisecond and carries no
        // renderer signal. Keep it out of burst/frame diagnostics entirely;
        // emit one content-free line only when parsing itself is visibly slow.
        if elapsedMs >= Self.slowIngressOnlyMs,
           now >= nextSlowIngressLogAt,
           DiagnosticLogStore.isVerboseEnabled {
            nextSlowIngressLogAt = now + Self.slowIngressLogInterval
            DiagnosticLogStore.appendTerminalPerformance(
                "terminal-ingress-slow surface=\(surface) bytes=\(ingress?.byteCount ?? 0) elapsedMs=\(format(elapsedMs))"
            )
        }
    }

    func beginFeed(
        context: TerminalPerformanceFeedContext,
        byteCount: Int
    ) -> TerminalPerformanceFeedToken? {
        let now = CACurrentMediaTime()
        guard diagnosticsEnabled(at: now) else { return nil }
        ensureBurst(at: now)
        guard var burst else { return nil }

        if var ingress = activeIngress,
           ingress.burstGeneration == nil {
            ingress.burstGeneration = burst.generation
            activeIngress = ingress
            burst.ingressChunks += 1
            burst.ingressBytes += ingress.byteCount
        }

        burst.feedChunks += 1
        burst.feedBytes += byteCount
        burst.maxOriginalBytes = max(
            burst.maxOriginalBytes,
            context.originalByteCount ?? byteCount
        )
        burst.lastActivityAt = now
        var source = burst.sources[context.source] ?? SourceStats()
        source.chunks += 1
        source.bytes += byteCount
        source.maxOriginalBytes = max(
            source.maxOriginalBytes,
            context.originalByteCount ?? byteCount
        )
        if let rows = context.captureRows {
            source.maxCaptureRows = max(source.maxCaptureRows ?? 0, rows)
            burst.maxCaptureRows = max(burst.maxCaptureRows ?? 0, rows)
        }
        burst.sources[context.source] = source
        burst.lastPane = context.pane ?? burst.lastPane
        burst.lastWindow = context.window ?? burst.lastWindow
        burst.lastGeneration = context.generation ?? burst.lastGeneration
        burst.lastReason = context.reason ?? burst.lastReason
        self.burst = burst

        return TerminalPerformanceFeedToken(
            startedAt: now,
            source: context.source,
            byteCount: byteCount
        )
    }

    func endFeed(
        _ token: TerminalPerformanceFeedToken,
        shellMs: Double,
        rendererMs: Double
    ) {
        guard var burst else { return }
        let now = CACurrentMediaTime()
        let feedMs = max(0, now - token.startedAt) * 1_000
        burst.shellMs += max(0, shellMs)
        burst.rendererMs += max(0, rendererMs)
        burst.feedMs += feedMs
        if feedMs > burst.maxFeedMs {
            burst.maxFeedMs = feedMs
            burst.slowestFeedBytes = token.byteCount
        }
        burst.lastActivityAt = now
        if var source = burst.sources[token.source] {
            if feedMs > source.maxFeedMs {
                source.maxFeedMs = feedMs
                source.slowestFeedBytes = token.byteCount
            }
            burst.sources[token.source] = source
        }
        self.burst = burst
    }

    private func diagnosticsEnabled(at now: CFTimeInterval) -> Bool {
        if now >= nextDefaultsCheckAt {
            cachedEnabled = DiagnosticLogStore.isVerboseEnabled
            nextDefaultsCheckAt = now + 1
            if !cachedEnabled {
                discardBurst()
            }
        }
        return cachedEnabled
    }

    private func ensureBurst(at now: CFTimeInterval) {
        guard burst == nil else { return }
        nextGeneration &+= 1
        let generation = nextGeneration
        burst = Burst(
            generation: generation,
            startedAt: now,
            lastActivityAt: now,
            lastFrameAt: now
        )
        startDisplayLink()
        scheduleFlush(generation: generation, after: Self.idleFlushSeconds)

        // One sentinel per burst captures a fully synchronous first feed (or a
        // backlog of already-ready MainActor work) without a recurring timer.
        Task { @MainActor [weak self] in
            guard let self, var current = self.burst,
                  current.generation == generation else { return }
            current.maxMainQueueDelayMs = max(
                current.maxMainQueueDelayMs,
                max(0, CACurrentMediaTime() - now) * 1_000
            )
            self.burst = current
        }
    }

    private func scheduleFlush(generation: Int, after delay: CFTimeInterval) {
        flushTask?.cancel()
        let boundedDelay = max(0.01, delay)
        expectedFlushAt = CACurrentMediaTime() + boundedDelay
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(boundedDelay))
            guard !Task.isCancelled else { return }
            self?.flushIfReady(generation: generation)
        }
    }

    private func flushIfReady(generation: Int) {
        flushTask = nil
        guard var current = burst, current.generation == generation else { return }
        let now = CACurrentMediaTime()

        // Cooperative renderer delivery can span several main-run-loop turns.
        // Keep its one aggregate open until the owning ingress completes.
        if activeIngress?.burstGeneration == generation {
            scheduleFlush(generation: generation, after: Self.idleFlushSeconds)
            return
        }

        if let expectedFlushAt {
            current.maxMainQueueDelayMs = max(
                current.maxMainQueueDelayMs,
                max(0, now - expectedFlushAt) * 1_000
            )
            burst = current
        }

        let idleSeconds = now - current.lastActivityAt
        let wallSeconds = now - current.startedAt
        guard idleSeconds >= Self.idleFlushSeconds
                || wallSeconds >= Self.maximumBurstSeconds else {
            let untilIdle = Self.idleFlushSeconds - idleSeconds
            let untilMaximum = Self.maximumBurstSeconds - wallSeconds
            scheduleFlush(
                generation: generation,
                after: min(untilIdle, untilMaximum)
            )
            return
        }

        displayLink?.invalidate()
        displayLink = nil
        burst = nil
        expectedFlushAt = nil

        guard DiagnosticLogStore.isVerboseEnabled else { return }
        sampleRenderedState?()
        let outsideFeedMs = max(0, current.ingressMs - current.feedMs)
        DiagnosticLogStore.appendSSH("latency-render-v3 host=\(diagnosticHost) surface=\(surface) ingressMs=\(format(current.ingressMs)) outsideFeedMs=\(format(outsideFeedMs)) shellMs=\(format(current.shellMs)) rendererMs=\(format(current.rendererMs)) maxFeedMs=\(format(current.maxFeedMs)) frames=\(current.frameTicks) maxFrameGapMs=\(format(current.maxFrameGapMs)) frameGapsOver50ms=\(current.frameGapsOver50ms) mainQueueDelayMs=\(format(current.maxMainQueueDelayMs))")
        let sourceSummary = current.sources.keys.sorted().compactMap { key -> String? in
            guard let source = current.sources[key] else { return nil }
            let rows = source.maxCaptureRows.map { ",rows=\($0)" } ?? ""
            return "\(key){chunks=\(source.chunks),bytes=\(source.bytes),maxOriginalBytes=\(source.maxOriginalBytes),maxFeedMs=\(format(source.maxFeedMs)),slowestFeedBytes=\(source.slowestFeedBytes)\(rows)}"
        }.joined(separator: ";")

        DiagnosticLogStore.appendTerminalPerformance(
            "terminal-output-burst surface=\(surface) wallMs=\(format(wallSeconds * 1_000)) ingressChunks=\(current.ingressChunks) ingressBytes=\(current.ingressBytes) ingressMs=\(format(current.ingressMs)) maxIngressMs=\(format(current.maxIngressMs)) outsideFeedMs=\(format(outsideFeedMs)) feedChunks=\(current.feedChunks) feedBytes=\(current.feedBytes) maxOriginalBytes=\(current.maxOriginalBytes) shellMs=\(format(current.shellMs)) rendererMs=\(format(current.rendererMs)) maxFeedMs=\(format(current.maxFeedMs)) slowestFeedBytes=\(current.slowestFeedBytes) frameTicks=\(current.frameTicks) maxFrameGapMs=\(format(current.maxFrameGapMs)) frameGapsOver50ms=\(current.frameGapsOver50ms) mainQueueDelayMs=\(format(current.maxMainQueueDelayMs)) sources='\(sourceSummary)' pane=\(current.lastPane ?? "nil") window=\(current.lastWindow ?? "nil") generation=\(current.lastGeneration.map(String.init) ?? "nil") maxCaptureRows=\(current.maxCaptureRows.map(String.init) ?? "nil") reason=\(current.lastReason ?? "none")"
        )
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        guard var burst else { return }
        let gapMs = max(0, link.timestamp - burst.lastFrameAt) * 1_000
        burst.frameTicks += 1
        burst.maxFrameGapMs = max(burst.maxFrameGapMs, gapMs)
        if gapMs >= 50 {
            burst.frameGapsOver50ms += 1
        }
        burst.lastFrameAt = link.timestamp
        self.burst = burst
    }

    private func discardBurst() {
        flushTask?.cancel()
        flushTask = nil
        displayLink?.invalidate()
        displayLink = nil
        expectedFlushAt = nil
        burst = nil
        activeIngress = nil
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Identity of the tmux buffer currently allowed to populate one terminal
/// surface. This app-local projection preserves the shared-core
/// `RenderOwner` identity at the SwiftTerm boundary.
///
/// An epoch distinguishes continuity breaks that return to the same tmux
/// window and pane. A late repaint from before a reconnect must therefore be
/// rejected just like a repaint from another window.
struct TerminalRenderOwner: Hashable, Sendable, CustomStringConvertible {
    let windowId: WindowId
    let paneId: PaneId
    let epoch: UInt64

    init(windowId: WindowId, paneId: PaneId, epoch: UInt64) {
        self.windowId = windowId
        self.paneId = paneId
        self.epoch = epoch
    }

    /// `stateGeneration` is the controller's stale-callback fence. Surface
    /// ownership instead uses the stable epoch that changes only when the
    /// controller asks this boundary to bind and clear.
    init?(feedContext: TmuxController.TerminalFeedContext) {
        guard feedContext.source != .passthrough,
              let windowId = feedContext.windowId,
              let paneId = feedContext.paneId,
              let epoch = feedContext.renderOwnerEpoch
        else { return nil }
        self.init(
            windowId: windowId,
            paneId: paneId,
            epoch: epoch
        )
    }

    var description: String {
        "window=\(windowId.description) pane=\(paneId.description) epoch=\(epoch)"
    }
}

/// The platform boundary which makes it impossible to mix rows from two tmux
/// buffers in one SwiftTerm terminal. Ledger-owned content always enters
/// through the owner-tagged feed; only an explicitly admitted transport
/// painter may use an untagged feed.
@MainActor
protocol TerminalRenderSurface: AnyObject {
    var boundOwner: TerminalRenderOwner? { get }
    var droppedForeignFeeds: Int { get }
    var surfaceState: TerminalRenderSurfaceState? { get }

    /// Binding a new owner drops any not-yet-rendered bytes and empties only
    /// scrollback; the grid and visible viewport stay intact.
    func bind(owner: TerminalRenderOwner, restoringScrollbackLimit: Int)

    /// A nil owner denotes the surface's transport painter and is accepted
    /// only when that surface has explicitly opened its painter ingress (plain
    /// SSH/mosh and the mosh SSP live surface). Foreign or disallowed untagged
    /// feeds are never queued.
    @discardableResult
    func feed(owner: TerminalRenderOwner?, _ bytes: ArraySlice<UInt8>) -> Bool

    /// A seam-owned resize path keeps state queries and direct geometry tests
    /// at the same boundary as owner checks. SwiftUI still drives normal view
    /// layout; this is for explicit surface consumers.
    func resize(columns: Int, rows: Int)
}

/// Snapshot of the terminal state the ledger needs when it is about to apply
/// an authoritative frame. It intentionally contains no transcript data.
struct TerminalRenderSurfaceState: Equatable {
    let altScreen: Bool
    let mouseMode: RenderMouseMode
    let columns: Int
    let rows: Int
}

@MainActor
final class TerminalBox: TerminalRenderSurface {
    private var latencyHost: UUID?
    func bindLatencyDiagnostics(host: UUID) {
        latencyHost = host
        performanceDiagnostics.bindHost(host)
        (view as? TesseraResponderAwareTerminalView)?.bindLatencyDiagnostics(host: host)
    }

    /// Bytes reached the terminal by a route SwiftTerm's UITextInput mirror
    /// does not model — the Files panel typing a path, an accessory-bar key, a
    /// swipe-pad macro or dictation result. That mirror only records the run of
    /// characters the view itself typed at the end of the line, yet the input
    /// system phrases its edits against it and SwiftTerm turns those offsets
    /// into backspaces bound for the remote. The double-space auto-period is
    /// the one that bites: it deletes the character the mirror calls a space,
    /// which after an injection is the last character of the injected text.
    /// Tell the view its record no longer describes the line.
    ///
    /// Android already draws this line in the same place —
    /// `TerminalSurface.sendInput`/`pasteVerbatim` call `resetImeLineContext()`
    /// for exactly these routes.
    func noteOutOfBandInput() {
        view?.discardTextInputMirror()
    }

    private static let mouseModeSets = ["1000", "1002", "1003", "1006"].map { Array("\u{1B}[?\($0)h".utf8) }

    /// Mode sets arrive whole from mosh frames and tmux repaints.
    private static func removingMouseModeSets(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        scan: while index < bytes.endIndex {
            if bytes[index] == 0x1B {
                for set in mouseModeSets where bytes[index...].starts(with: set) {
                    index += set.count
                    continue scan
                }
            }
            result.append(bytes[index])
            index += 1
        }
        return result[...]
    }

    fileprivate let renderDiagnosticID = UUID()
    private let traceLabel: String
    private var acceptsPainterFeeds: Bool
    /// See `integrationScrollHarnessDropsClientMouseModes`.
    private let dropsClientMouseModes: Bool
    fileprivate let performanceDiagnostics: TerminalPerformanceDiagnostics
    weak var view: TerminalView?
    private var pendingBytes: [UInt8] = []
    private var isRenderReady = false
    private var bufferedChunkCount = 0
    private var directChunkCount = 0
    private var contrastFilter = TerminalOutputContrastFilter()
    private var lastInterfaceOrientation: UIInterfaceOrientation?

    /// Owner state belongs at the final shared-SwiftTerm ingress rather than
    /// the tmux controller. This protects its owner-aware render path from a
    /// late asynchronous repaint before it reaches the deferred byte buffer.
    private(set) var boundOwner: TerminalRenderOwner?
    private(set) var droppedForeignFeeds = 0

    /// The reader's placement just before the most recent `bind` cleared
    /// scrollback. A replacement history page (a deepen) must keep the
    /// distance the reader had from the live tail, but by the time its
    /// `historyReady` arrives the buffer is already empty and the view can no
    /// longer answer that question. Consumed once by the next presentation.
    struct ScrollPositionBeforeRebind: Equatable {
        let offsetY: CGFloat
        let maxOffsetY: CGFloat
    }

    private var scrollPositionBeforeRebind: (owner: TerminalRenderOwner, position: ScrollPositionBeforeRebind)?

    /// Hands over the pre-clear placement recorded by the bind that installed
    /// `owner`, or nil when the last bind belonged to someone else: a snapshot
    /// must never travel from one owner's clear to another owner's page.
    func takeScrollPositionBeforeRebind(for owner: TerminalRenderOwner) -> ScrollPositionBeforeRebind? {
        guard let snapshot = scrollPositionBeforeRebind, snapshot.owner == owner else { return nil }
        scrollPositionBeforeRebind = nil
        return snapshot.position
    }

    /// True only while `bind` clears scrollback for a new owner. The clear
    /// empties the SwiftTerm buffer, which lands its content offset on the
    /// (now trivial) tail and reports `scrolled` synchronously. That callback
    /// is a consequence of the rebind, not a reader returning to the live
    /// tail, so tail-release policy must ignore it: otherwise a deepen bind
    /// discards the very history page it is about to present.
    private(set) var isRebinding = false

    /// True from a `bind` until the bound owner (or an admitted painter feed)
    /// puts the first bytes into the emptied buffer. The ledger binds a
    /// replacement page's owner before that page feeds, and on mosh+tmux the
    /// two are separate effect batches: for a few tens of milliseconds the
    /// buffer is empty and its scroll view sits at a trivial tail. A gesture
    /// frame, a layout pass, or any other `scrolled` callback in that window
    /// must not read as the reader returning to the live tail, or the page
    /// that is about to arrive is dropped as foreign and the reader snaps
    /// back to the tail.
    private(set) var isAwaitingContentAfterRebind = false

    init(traceLabel: String, acceptsPainterFeeds: Bool = true, dropsClientMouseModes: Bool = false) {
        self.traceLabel = traceLabel
        self.acceptsPainterFeeds = acceptsPainterFeeds
        self.dropsClientMouseModes = dropsClientMouseModes
        performanceDiagnostics = TerminalPerformanceDiagnostics(surface: traceLabel)
        performanceDiagnostics.sampleRenderedState = { [weak self] in self?.sampleBackgroundCells() }
    }

    /// Sample only color attributes after a completed ingress burst, never
    /// characters. A fragmented buffer background versus a uniform buffer
    /// with fragmented pixels separates terminal-state from Metal damage.
    private func sampleBackgroundCells() {
        guard let view else { return }
        let terminal = view.getTerminal()
        func colorID(_ color: Attribute.Color) -> String {
            switch color {
            case .defaultColor: return "defaultFG"
            case .defaultInvertedColor: return "defaultBG"
            case .ansi256(let code): return "a\(code)"
            case .trueColor(let red, let green, let blue): return "rgb\(red)-\(green)-\(blue)"
            }
        }
        for row in max(0, terminal.rows - 4)..<terminal.rows {
            var previous: Attribute.Color?
            var runs = 0
            var colors: [String: Int] = [:]
            for column in 0..<min(terminal.cols, 512) {
                guard let cell = terminal.getCharData(col: column, row: row) else { continue }
                let color = cell.attribute.style.contains(.inverse) ? cell.attribute.fg : cell.attribute.bg
                if color != previous { runs += 1; previous = color }
                colors[colorID(color), default: 0] += 1
            }
            let histogram = colors.keys.sorted().prefix(8).map { "\($0):\(colors[$0]!)" }.joined(separator: ",")
            DiagnosticLogStore.appendTerminalPerformance(
                "terminal-background-cells surface=\(traceLabel) cols=\(terminal.cols) rows=\(terminal.rows) row=\(row) yDisp=\(terminal.buffer.yDisp) colorRuns=\(runs) colors=\(colors.count) histogram=\(histogram)"
            )
        }
    }

    /// Plain SSH/mosh have a transport painter; inline tmux does not. The SSH
    /// surface changes role when the control-mode prologue is detected, so the
    /// seam must be able to close (and later reopen) its untagged ingress.
    func setAcceptsPainterFeeds(_ acceptsPainterFeeds: Bool) {
        self.acceptsPainterFeeds = acceptsPainterFeeds
    }

    var painterFeedsAdmitted: Bool { acceptsPainterFeeds }

    /// Owned history is presentable only after an attached SwiftTerm surface
    /// has flushed every byte accepted during its pre-ready interval.
    var isReadyForOwnedPresentation: Bool {
        isRenderReady && view != nil && pendingBytes.isEmpty
    }

    var surfaceState: TerminalRenderSurfaceState? {
        guard let terminal = view?.getTerminal() else { return nil }
        return TerminalRenderSurfaceState(
            altScreen: terminal.isCurrentBufferAlternate,
            mouseMode: terminal.mouseMode == .off ? .off : .tracking,
            columns: terminal.cols,
            rows: terminal.rows
        )
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        (view as? TesseraResponderAwareTerminalView)?.cancelPendingLayoutResize()
        view?.resize(cols: columns, rows: rows)
    }

    func dismissTransientInteractions() {
        view?.selectNone()
        if let terminal = view as? TesseraResponderAwareTerminalView {
            terminal.resignFirstResponderForTransition()
        } else {
            view?.resignFirstResponder()
        }
        // Other sessions stay mounted in this same window. Their cleanup can
        // arrive after the newly selected terminal (or an editor) takes focus.
        // Ending editing on the window would resign that unrelated responder,
        // leaving hardware input without a destination until another update.
        UIMenuController.shared.hideMenu()
    }

    /// `UIDevice.orientationDidChangeNotification` also reports physical
    /// posture changes such as portrait -> face-up -> portrait even when the
    /// window remains portrait. Dismissing the terminal for those notifications
    /// makes the phone keyboard hide, then `TerminalSurfaceBound` immediately
    /// reclaims first responder on the next SwiftUI update. Only a real
    /// interface-orientation transition should invalidate transient UI.
    func dismissTransientInteractionsIfInterfaceOrientationChanged() {
        guard let current = view?.window?.windowScene?.interfaceOrientation else {
            return
        }
        defer { lastInterfaceOrientation = current }
        guard let previous = lastInterfaceOrientation,
              previous != current
        else { return }
        dismissTransientInteractions()
    }

    func attach(_ view: TerminalView) {
        if self.view !== view {
            isRenderReady = false
            lastInterfaceOrientation = nil
        }
        self.view = view
        if let latencyHost {
            (view as? TesseraResponderAwareTerminalView)?.bindLatencyDiagnostics(host: latencyHost)
        }
        MoshDiagnostics.log(
            "\(traceLabel) terminal attach ready=\(isRenderReady) pendingBytes=\(pendingBytes.count)"
        )
        flushPendingBytesIfPossible()
    }

    func markRenderReady() {
        isRenderReady = true
        MoshDiagnostics.log(
            "\(traceLabel) terminal render ready pendingBytes=\(pendingBytes.count)"
        )
        flushPendingBytesIfPossible()
    }

    private func flushPendingBytesIfPossible() {
        guard isRenderReady, let view, !pendingBytes.isEmpty else { return }
        MoshDiagnostics.log(
            "\(traceLabel) terminal flush pending bytes=\(pendingBytes.count)"
        )
        let filtered = filteredBytes(pendingBytes[...], for: view)
        if !filtered.isEmpty {
            (view as? TesseraResponderAwareTerminalView)?.noteLatencyFeed()
            view.feed(byteArray: filtered[...])
        }
        pendingBytes.removeAll(keepingCapacity: true)
    }

    /// Shared shell-observer + renderer feed path. Keeping the timing wrapper
    /// here ensures every transport reports identical per-slice metrics.
    fileprivate func feedTerminalOutput(
        _ bytes: ArraySlice<UInt8>,
        context: TerminalPerformanceFeedContext,
        shellIntegration: SwipePadShellIntegrationTracker,
        owner: TerminalRenderOwner? = nil
    ) {
        // Do not let a foreign render update shell-integration state either:
        // it is a streaming parser and accepting a partial foreign escape
        // sequence would leave the next rightful pane with corrupted state.
        if let owner, boundOwner != owner {
            feed(owner: owner, bytes)
            return
        }
        if owner == nil, !acceptsPainterFeeds {
            feed(owner: nil, bytes)
            return
        }
        if let token = performanceDiagnostics.beginFeed(
            context: context,
            byteCount: bytes.count
        ) {
            let shellStartedAt = CACurrentMediaTime()
            shellIntegration.feed(bytes)
            let rendererStartedAt = CACurrentMediaTime()
            if let owner {
                feed(owner: owner, bytes)
            } else {
                feed(bytes)
            }
            let finishedAt = CACurrentMediaTime()
            performanceDiagnostics.endFeed(
                token,
                shellMs: (rendererStartedAt - shellStartedAt) * 1_000,
                rendererMs: (finishedAt - rendererStartedAt) * 1_000
            )
        } else {
            shellIntegration.feed(bytes)
            if let owner {
                feed(owner: owner, bytes)
            } else {
                feed(bytes)
            }
        }
    }

    /// Plain mosh output bypasses TmuxController, so apply the same cooperative
    /// renderer budget at this shared terminal boundary. SwiftTerm and the
    /// shell/contrast parsers are streaming parsers and preserve state across
    /// arbitrary byte boundaries.
    func feedTerminalOutputCooperatively(
        _ bytes: ArraySlice<UInt8>,
        context: TerminalPerformanceFeedContext,
        shellIntegration: SwipePadShellIntegrationTracker,
        owner: TerminalRenderOwner? = nil,
        acceptsNextSlice: @MainActor () -> Bool = { true },
        onYield: @MainActor () -> Void = {}
    ) async -> Bool {
        guard !bytes.isEmpty else { return true }
        let maximumChunkBytes = 1024
        let turnBudget: Duration = .milliseconds(4)
        let clock = ContinuousClock()
        var turnStartedAt = clock.now
        var offset = bytes.startIndex
        var renderedMultipleSlices = false

        while offset < bytes.endIndex {
            guard acceptsNextSlice() else { return false }
            let end = bytes.index(
                offset,
                offsetBy: min(maximumChunkBytes, bytes.distance(from: offset, to: bytes.endIndex))
            )
            feedTerminalOutput(
                bytes[offset..<end],
                context: context,
                shellIntegration: shellIntegration,
                owner: owner
            )
            renderedMultipleSlices = renderedMultipleSlices || end < bytes.endIndex
            offset = end
            if turnStartedAt.duration(to: clock.now) >= turnBudget {
                await Task.yield()
                onYield()
                turnStartedAt = clock.now
                renderedMultipleSlices = false
            }
        }

        if renderedMultipleSlices {
            await Task.yield()
            onYield()
        }
        return true
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        feed(owner: nil, bytes)
    }

    /// Binds the SwiftTerm buffer to an authoritative tmux owner. Rebinding is
    /// the only operation which discards already-buffered bytes: otherwise a
    /// chunk accepted for the previous owner could render after the new owner
    /// has been installed but before its UIKit view becomes ready.
    func bind(owner: TerminalRenderOwner, restoringScrollbackLimit limit: Int) {
        guard boundOwner != owner else { return }

        let previousOwner = boundOwner
        let discardedPendingByteCount = pendingBytes.count
        boundOwner = owner
        pendingBytes.removeAll(keepingCapacity: true)
        contrastFilter = TerminalOutputContrastFilter()
        // Log before the clear: SwiftTerm reports `scrolled` synchronously
        // from it, and that callback can re-enter with a newer bind. Logging
        // afterwards would print the nested bind ahead of this one.
        MoshDiagnostics.log(
            "render_surface bind surface=\(traceLabel) owner=\(owner) previous=\(previousOwner?.description ?? "nil") discarded_pending_bytes=\(discardedPendingByteCount)"
        )
        if isAwaitingContentAfterRebind, let carried = scrollPositionBeforeRebind {
            // The previous bind emptied the buffer and nothing has filled it
            // since, so the view only knows the trivial tail. The reader's
            // real distance is the one recorded before that clear; it now
            // belongs to whichever owner finally presents a page.
            scrollPositionBeforeRebind = (owner: owner, position: carried.position)
        } else if let view {
            let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            scrollPositionBeforeRebind = (
                owner: owner,
                position: ScrollPositionBeforeRebind(
                    offsetY: min(max(0, view.contentOffset.y), maxOffsetY),
                    maxOffsetY: maxOffsetY
                )
            )
        } else {
            scrollPositionBeforeRebind = nil
        }
        isAwaitingContentAfterRebind = true
        let wasRebinding = isRebinding
        isRebinding = true
        defer { isRebinding = wasRebinding }
        clearScrollback(restoringLimit: limit)
    }

    /// Strict feed path for the render ledger and all tmux repaint callers.
    /// Foreign chunks are discarded synchronously, before they can
    /// reach either SwiftTerm or the deferred pre-attach byte buffer.
    @discardableResult
    func feed(owner: TerminalRenderOwner?, _ bytes: ArraySlice<UInt8>) -> Bool {
        // The bound owner's page has arrived even when it carries no bytes
        // (a zero-range capture): the buffer now reflects that owner, and a
        // tail observed from here on is a real one.
        if let owner, boundOwner == owner {
            isAwaitingContentAfterRebind = false
        }
        guard !bytes.isEmpty else { return false }

        guard let owner else {
            guard acceptsPainterFeeds else {
                recordDroppedForeignFeed(owner: nil, byteCount: bytes.count)
                return false
            }
            isAwaitingContentAfterRebind = false
            feedUnchecked(bytes)
            return true
        }

        guard boundOwner == owner else {
            recordDroppedForeignFeed(owner: owner, byteCount: bytes.count)
            return false
        }
        feedUnchecked(bytes)
        return true
    }

    private func feedUnchecked(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        if isRenderReady, let view {
            directChunkCount += 1
            if directChunkCount <= 12 || directChunkCount == 25 || directChunkCount == 50 {
                MoshDiagnostics.log(
                    "\(traceLabel) terminal direct feed chunk#\(directChunkCount) bytes=\(bytes.count)"
                )
            }
            let filtered = filteredBytes(bytes, for: view)
            if !filtered.isEmpty {
                (view as? TesseraResponderAwareTerminalView)?.noteLatencyFeed()
                view.feed(byteArray: filtered[...])
            }
        } else {
            bufferedChunkCount += 1
            if bufferedChunkCount <= 12 {
                MoshDiagnostics.log(
                    "\(traceLabel) terminal buffer chunk#\(bufferedChunkCount) bytes=\(bytes.count)"
                )
            }
            pendingBytes.append(contentsOf: bytes)
        }
    }

    private func recordDroppedForeignFeed(
        owner: TerminalRenderOwner?,
        byteCount: Int
    ) {
        droppedForeignFeeds += 1
        MoshDiagnostics.log(
            "render_surface dropped_foreign surface=\(traceLabel) owner=\(owner?.description ?? "painter") bound=\(boundOwner?.description ?? "nil") bytes=\(byteCount) dropped_foreign=\(droppedForeignFeeds)"
        )
    }

    /// Contentoffset-correct scrollback wipe via the changeScrollback
    /// 0 → limit toggle, which keeps the visible viewport rows intact.
    /// The toggle is kept for swap + mosh symmetry; `[3J` is fixed in the
    /// fork as of d34c15f (it now resyncs the scroll view), so remote
    /// clears are safe too.
    /// Main-actor only: all feeds are main-actor; if that ever changes this
    /// becomes a data race on SwiftTerm's CircularList.
    func clearScrollback(restoringLimit limit: Int) {
        guard let view else { return }
        view.changeScrollback(0)
        view.changeScrollback(max(limit, 0))
    }

    /// Repaint the current SwiftTerm viewport from its existing terminal
    /// model. This is the local half of the user-facing force refresh; the
    /// session owner separately asks tmux or mosh for authoritative output.
    func forceRedraw() {
        guard let view else { return }
        let terminal = view.getTerminal()
        guard terminal.rows > 0 else { return }
        terminal.refresh(startRow: 0, endRow: terminal.rows - 1)
        // `Terminal.refresh` only records SwiftTerm's dirty-row range. A
        // layout pass can resubmit cached Metal buffers without consuming that
        // range, and does not redraw the CoreGraphics fallback at unchanged
        // bounds. An empty feed drives SwiftTerm's normal display scheduler,
        // which maps the dirty rows into `metalDirtyRange` (or invalidates the
        // CoreGraphics canvas) without changing the terminal model.
        view.feed(text: "")
        MoshDiagnostics.log(
            "\(traceLabel) terminal force redraw rows=\(terminal.rows) offset=\(String(format: "%.1f", view.contentOffset.y))"
        )
    }

    private func filteredBytes(
        _ bytes: ArraySlice<UInt8>,
        for view: TerminalView
    ) -> ArraySlice<UInt8> {
        let container = view.superview as? TesseraTerminalContainer
        return contrastFilter.process(
            dropsClientMouseModes ? Self.removingMouseModeSets(bytes) : bytes,
            defaultBackgroundRGB: container?.terminalDefaultBackgroundRGB ?? 0x000000,
            defaultForegroundRGB: container?.terminalDefaultForegroundRGB ?? 0xD4D4D4,
            minimumContrast: container?.terminalMinimumContrast ?? 0.30
        )
    }
}

/// Session-scoped aggregate for the final render-surface admission seam.
/// Individual surfaces log each refusal immediately; this reporter also makes
/// a monotonic total (including zero) visible in the standard diagnostics at
/// lifecycle boundaries and on a quiet-session cadence.
@MainActor
final class RenderDropSummaryReporter {
    private final class Entry {
        weak var surface: TerminalBox?
        var observedDrops: Int

        init(surface: TerminalBox, observedDrops: Int = 0) {
            self.surface = surface
            self.observedDrops = observedDrops
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var droppedForeignFeeds = 0
    private let sink: (String) -> Void

    init(sink: @escaping (String) -> Void = { DiagnosticLogStore.appendTmux($0) }) {
        self.sink = sink
    }

    func register(_ surface: TerminalBox) {
        let entry: Entry
        if let existing = entries[surface.renderDiagnosticID] {
            existing.surface = surface
            entry = existing
        } else {
            entry = Entry(surface: surface)
            entries[surface.renderDiagnosticID] = entry
        }
        observe(surface, entry: entry)
    }

    func unregister(_ surface: TerminalBox) {
        guard let entry = entries[surface.renderDiagnosticID] else { return }
        observe(surface, entry: entry)
        if entry.surface === surface {
            entry.surface = nil
        }
    }

    func record(boundary: String) {
        for entry in entries.values {
            if let surface = entry.surface {
                observe(surface, entry: entry)
            }
        }
        sink(
            "render_ledger_summary boundary=\(boundary) dropped_foreign=\(droppedForeignFeeds)"
        )
    }

    func runPeriodic() async {
        record(boundary: "periodic-start")
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            record(boundary: "periodic")
        }
    }

    private func observe(_ surface: TerminalBox, entry: Entry) {
        let current = surface.droppedForeignFeeds
        if current > entry.observedDrops {
            droppedForeignFeeds += current - entry.observedDrops
            entry.observedDrops = current
        }
    }
}

/// Per-tmux-window kitty keyboard mode bookkeeping for the inline `-CC`
/// path, where every tmux window shares one SwiftTerm `Terminal`.
///
/// A kitty-aware TUI (Codex, newer vims) pushes keyboard-enhancement
/// flags that live on the shared terminal, so without this store the
/// flags leak into every other window: SwiftTerm keeps encoding keys as
/// `CSI … u` and the next window's shell echoes the escape tail as
/// garbage (shift+= became `1:43;2u`). On each display swap the
/// outgoing window's keyboard mode is snapshotted and the incoming
/// window's is restored (or cleared when it has none saved).
///
/// `paneInAltScreen` is tmux's `#{alternate_on}` for the incoming pane
/// and guards against stale restores: `%output` from non-active windows
/// is dropped, so a kitty pop emitted while the window was off-screen
/// is never seen by SwiftTerm. Apps push kitty flags from the alternate
/// screen in practice, so "pane no longer in the alt screen" means the
/// saved alt-screen flags are dead and must not be restored. An app
/// that pushes flags in the *normal* buffer and pops while off-screen
/// would still restore stale — accepted; that shape does not occur in
/// real TUIs and the failure degrades to today's behavior.
///
/// Window ids are not reused within a tmux server epoch, so entries for
/// closed windows are harmless and are not pruned.
@MainActor
final class KittyWindowModeStore {
    private var store = WindowModeStore<KittyKeyboardModeSnapshot>()

    func displayWillSwap(
        from: WindowId?,
        to: WindowId,
        paneInAltScreen: Bool,
        terminal: Terminal
    ) {
        if let from {
            let snapshot = terminal.keyboardModeSnapshot()
            store.save(
                keyboardMode: snapshot.isEmpty ? nil : snapshot,
                bracketedPasteEnabled: terminal.bracketedPasteMode,
                for: from
            )
        }
        let restore = store.restore(
            for: to,
            paneInAltScreen: paneInAltScreen,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )
        switch restore.keyboardMode {
        case .reset:
            terminal.resetKeyboardMode()
        case .restore(let snapshot):
            terminal.restoreKeyboardMode(snapshot)
        }
    }

    /// Called after the repaint because the repaint epilogue never touches
    /// 2004. tmux's `bracket_paste_flag` is not available until post-3.6a,
    /// so Tessera keeps 2004 client-side while older tmux servers are
    /// supported. Remove this once the tmux floor can report the flag.
    func displayDidSwap(to windowId: WindowId, terminalBox: TerminalBox) {
        let wanted = store.bracketedPasteEnabled(for: windowId) ?? false
        let bytes = Array((wanted ? "\u{1B}[?2004h" : "\u{1B}[?2004l").utf8)
        terminalBox.feed(owner: terminalBox.boundOwner, bytes[...])
    }

    /// Ledger effect form of the first half of `displayWillSwap`: a history
    /// surface may save its current window without immediately restoring a
    /// different one.
    func save(windowID: WindowId, terminal: Terminal) {
        let snapshot = terminal.keyboardModeSnapshot()
        store.save(
            keyboardMode: snapshot.isEmpty ? nil : snapshot,
            bracketedPasteEnabled: terminal.bracketedPasteMode,
            for: windowID
        )
        // The next bind may target a different tmux owner. Clear the shared
        // terminal's kitty state before it is emptied; `restore` replays the
        // incoming window's guarded snapshot after the authoritative feed.
        terminal.resetKeyboardMode()
    }

    /// Ledger effect form of restore + post-feed bracketed-paste replay.
    func restore(
        windowID: WindowId,
        paneInAltScreen: Bool,
        terminal: Terminal,
        terminalBox: TerminalBox
    ) {
        let restore = store.restore(
            for: windowID,
            paneInAltScreen: paneInAltScreen,
            clearingAlternateScreenState: { $0.clearingAlternateScreenState() }
        )
        switch restore.keyboardMode {
        case .reset:
            terminal.resetKeyboardMode()
        case .restore(let snapshot):
            terminal.restoreKeyboardMode(snapshot)
        }
        displayDidSwap(to: windowID, terminalBox: terminalBox)
    }

    func bracketedPasteEnabled(for windowId: WindowId) -> Bool? {
        store.bracketedPasteEnabled(for: windowId)
    }
}

@MainActor
private final class TmuxControlChannelBox {
    var channel: TmuxControlChannel?
}

@MainActor
private final class MoshPaneScrollbackOverlayRuntime {
    let id = UUID()
    let paneId: PaneId
    let windowId: WindowId
    let box: TerminalBox
    var pendingScrollPlacement: MoshPaneScrollbackPlacement?
    var pendingScrollPlacementRevision = 0
    var pendingScrollDirection: Double = 0
    var desiredScrollOffsetY: CGFloat?
    /// A ledger history batch that arrived during native scroll. Deferring
    /// only the surface application (not reducer state) preserves the reader's
    /// finger position while the controller keeps its single-flight invariant.
    var pendingDeferredHistory: MoshLedgerHistory?
    /// Bytes crossed the owner seam, but their scroll placement has not yet
    /// been applied to the mounted SwiftTerm overlay.
    var pendingPresentationHistory: MoshLedgerHistory?
    /// Output crossed the control FIFO after a replacement capture was staged
    /// but while native scrolling deferred its feed. The replacement remains
    /// deliverable exactly once, then becomes the frozen reader snapshot.
    var freezeAfterDeferredPresentation = false
    /// True once a native pan/deceleration has moved this overlay since
    /// its reveal. Gates the settle-time bottom dismissal: bridge writes
    /// also arrive "settled" (they come from a gesture on the SHARED
    /// surface), and without this gate a gentle reveal-scroll that stays
    /// within the bottom threshold would dismiss its own overlay.
    var sawNativeScroll = false
    /// Latched when active-pane output arrives while this overlay is
    /// REVEALED: the reader stays in scrollback (iTerm2 behavior) instead
    /// of being kicked to the live tail, but the content is now a frozen
    /// snapshot — any capture fetched from here on includes the new
    /// output, so applying one would shift the distance-from-bottom
    /// anchor and teleport the reader. Blocks every fetch/deepen/seed
    /// until the overlay dismisses (bottom return re-syncs to live).
    var contentFrozen = false
    /// One-shot latch for the native settle poll (see
    /// `armMoshOverlayNativeSettleCheck`).
    var nativeSettleCheckArmed = false

    private var restoredScrollOffsetLogCount = 0

    init(
        paneId: PaneId,
        windowId: WindowId,
        renderDropSummary: RenderDropSummaryReporter
    ) {
        self.paneId = paneId
        self.windowId = windowId
        // A detached history view has no transport painter: all of its bytes
        // must come from the ledger under the exact pane owner.
        self.box = TerminalBox(
            traceLabel: "mosh-overlay-\(paneId.rawValue)",
            acceptsPainterFeeds: false
        )
        renderDropSummary.register(self.box)
    }

    func setPendingScrollPlacement(_ placement: MoshPaneScrollbackPlacement) {
        pendingScrollPlacement = placement
        pendingScrollPlacementRevision += 1
    }

    @discardableResult
    func applyDesiredScrollOffset(_ targetY: CGFloat, in view: TerminalView) -> CGFloat {
        let offsetY = clampedScrollOffsetY(targetY, in: view)
        desiredScrollOffsetY = offsetY
        if abs(view.contentOffset.y - offsetY) > 0.5 {
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: offsetY)
        }
        return offsetY
    }

    func restoreDesiredScrollOffset(
        in view: TerminalView,
        onScrollDiagnostic: ((String) -> Void)? = nil
    ) {
        guard let desiredScrollOffsetY else { return }
        let offsetY = clampedScrollOffsetY(desiredScrollOffsetY, in: view)
        self.desiredScrollOffsetY = offsetY
        guard abs(view.contentOffset.y - offsetY) > 0.5 else { return }
        if restoredScrollOffsetLogCount < 12 {
            restoredScrollOffsetLogCount += 1
            let detail = "scroll-offset-restore pane=\(paneId.description) from=\(String(format: "%.1f", view.contentOffset.y)) to=\(String(format: "%.1f", offsetY)) contentHeight=\(String(format: "%.1f", view.contentSize.height)) boundsHeight=\(String(format: "%.1f", view.bounds.height))"
            MoshDiagnostics.log("mosh scrollback overlay \(detail)")
            onScrollDiagnostic?(detail)
        }
        view.contentOffset = CGPoint(x: view.contentOffset.x, y: offsetY)
    }

    func clearDesiredScrollOffset() {
        desiredScrollOffsetY = nil
    }

    /// Halt any in-flight native deceleration on the runtime's view (a
    /// same-offset setContentOffset ends UIScrollView momentum). A hidden
    /// view must never remain "natively active": its ghost motion would
    /// keep moving the parked offset and trip every isDecelerating check.
    func stopNativeScrollMotion() {
        guard let view = box.view,
              view.isDragging || view.isDecelerating
        else { return }
        view.setContentOffset(view.contentOffset, animated: false)
    }

    private func clampedScrollOffsetY(_ y: CGFloat, in view: TerminalView) -> CGFloat {
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        return min(max(0, y), maxOffsetY)
    }
}

struct MoshLedgerHistory {
    let owner: TerminalRenderOwner
    let bytes: [UInt8]
    let depth: Int
    let historySize: Int
    let placement: RenderHistoryPlacement
    let scrollPoints: Double
}

private struct MoshLiveHistoryPresentation {
    let id = UUID()
    let history: MoshLedgerHistory
    let oldMaxOffsetY: CGFloat
    let oldOffsetY: CGFloat
}

enum MoshLiveHistoryTailReleasePolicy {
    static func shouldRelease(
        isHistoryRevealed: Bool,
        hasPendingPresentation: Bool,
        isRebinding: Bool,
        isAwaitingContent: Bool,
        offsetY: CGFloat,
        maxOffsetY: CGFloat
    ) -> Bool {
        // A rebind clears the buffer before its replacement history feeds;
        // the offset it reports is the empty buffer's tail, not the reader's.
        // That stays true for every scroll callback until the new owner's
        // bytes arrive, not only for the synchronous one inside the clear.
        guard isHistoryRevealed, !hasPendingPresentation, !isRebinding, !isAwaitingContent
        else { return false }
        // Once placement is acknowledged, a zero-range capture is already at
        // its only possible live-tail position. Treat it as returned to tail;
        // the pending-presentation guard above still rejects the transient
        // zero range observed while SwiftTerm is rebuilding its rows.
        // Only release at the actual bottom. Reusing the paging proximity
        // threshold here discards a newly revealed page during a slow drag
        // whose first movement is just a few points above the tail.
        return maxOffsetY <= 0 || offsetY >= maxOffsetY
    }
}

struct MoshWindowModeRestore {
    let windowID: WindowId
    let paneInAltScreen: Bool
}

/// Production adapter for the side-channel render ledger. It is deliberately
/// presentation-neutral: both `MoshSessionView` and the live transport gate
/// use this exact object for bind, byte holding, owner validation, surface
/// state resolution, and the ordered `historyReady` handoff.
@MainActor
final class MoshRenderLedgerSurfaceAdapter {
    struct TransportOutputLease {
        /// A correlated forced frame is fed as an owned render. Natural Mosh
        /// output remains unowned and must pass the painter-admission seam.
        let owner: TerminalRenderOwner?
        let acceptsNextSlice: @MainActor () -> Bool
    }

    typealias SurfaceState = (
        altScreen: Bool,
        mouseMode: RenderMouseMode,
        columns: Int,
        rows: Int
    )

    private struct PendingHistory {
        let owner: TerminalRenderOwner
        let bytes: [UInt8]
        var repaintFenceID: UInt64?
    }

    private enum RepaintDeliveryTarget {
        case awaitingDriver
        case output(UInt64)
    }

    private struct RepaintFence {
        let id: UInt64
        let surfaceID: SurfaceId
        let owner: TerminalRenderOwner
        let painterOwner: TerminalRenderOwner?
        var transportRequestID: UInt64?
        var deliveryTarget: RepaintDeliveryTarget
        var acceptedDeliveryID: UInt64?
        var history: MoshLedgerHistory?
        var retryAttempt = 0
    }

    /// A side-channel bind can run ahead of Mosh's independently delivered
    /// SSP diff. Keep the replacement surface closed until one post-bind
    /// natural output has crossed the driver queue, then snapshot that newer
    /// framebuffer with one exact, owner-tagged repaint.
    private struct PainterHandoff {
        var owner: TerminalRenderOwner
        let naturalOutputFloor: UInt64
        var deferredFenceIDs: [UInt64] = []
        var causalBoundaryObserved: Bool
        var retryAttempt = 0
        var requestInFlight = false
        var requestID: UInt64?
        var deliveryTarget: UInt64?
        var observedDeliveryID: UInt64?
        var observedRenderedFully: Bool?
        var deliveryLeaseIssued = false
    }

    private struct DeferredOwnedRepaint {
        let owner: TerminalRenderOwner
        /// Survives a same-window/pane epoch rebind instead of reporting a
        /// failed frame. Only a caller whose request is a fence for something
        /// else (the grid-authority veil) needs this; a request that the next
        /// notification would simply re-issue stays retirable.
        let retargetable: Bool
        let onScheduled: @MainActor (UInt64) -> Void
        let completion: @MainActor (UInt64?) -> Void
    }

    private struct OwnedRepaintReceipt {
        let owner: TerminalRenderOwner
        let retargetable: Bool
        let onScheduled: @MainActor (UInt64) -> Void
        let completion: @MainActor (UInt64?) -> Void
        var deliveryTarget: UInt64?
        var observedDeliveryID: UInt64?
        var observedRenderedFully: Bool?
    }

    private var pendingHistoryBySurface: [SurfaceId: PendingHistory] = [:]
    private var pendingScrollPointsBySurface: [SurfaceId: Double] = [:]
    private var pendingWindowModeRestores: [SurfaceId: MoshWindowModeRestore] = [:]
    private var unfencedHistoryCandidate: (SurfaceId, TerminalRenderOwner)?
    private var repaintFences: [RepaintFence] = []
    private var nextRepaintFenceID: UInt64 = 0
    private var painterHandoff: PainterHandoff?
    private var painterRetryTask: Task<Void, Never>?
    private var painterReceiptWatchdogTask: Task<Void, Never>?
    private var historyRepaintRetryTasks: [UInt64: Task<Void, Never>] = [:]
    private var historyRepaintReceiptWatchdogs: [UInt64: Task<Void, Never>] = [:]
    private var deferredOwnedRepaints: [DeferredOwnedRepaint] = []
    private var ownedRepaintsByRequestID: [UInt64: OwnedRepaintReceipt] = [:]
    private var retiredTransportRequestIDs: Set<UInt64> = []
    private var retiredTransportRequestIDUpperBound: UInt64 = 0
    private var historyReadyHandler: (@MainActor (SurfaceId, MoshLedgerHistory) -> Void)?
    private var surfaceHandler: (@MainActor (SurfaceId) -> TerminalBox?)?
    private var requestTransportFullFrame: (@MainActor (
        _ onScheduled: @escaping @MainActor (UInt64) -> Void,
        _ completion: @escaping @MainActor (UInt64?) -> Void
    ) -> Void)?
    private var cancelTransportFullFrame: (@MainActor (UInt64) -> Void)?
    private var retireAllTransportFullFrames: (@MainActor () -> UInt64)?
    private var currentTransportOutputDeliveryID: (@MainActor () -> UInt64)?
    private var painterEventsForTesting: [String] = []
    private weak var activityController: TmuxController?

    /// Production contract is four seconds. Tests shorten only this adapter-
    /// local clock; the shared ledger never owns transport receipt timing.
    var repaintReceiptTimeoutNanoseconds: UInt64 = 4_000_000_000

    var retiredTransportRequestTombstoneCountForTesting: Int {
        retiredTransportRequestIDs.count
    }

    var painterStateForTesting: String {
        let liveOwner = surfaceHandler?(.live)?.boundOwner
        let handoffDescription = painterHandoff.map(Self.handoffDescription) ?? "nil"
        let liveOwnerDescription = liveOwner.map(Self.ownerDescription) ?? "nil"
        let events = painterEventsForTesting.joined(separator: " | ")
        return "live=\(liveOwnerDescription) "
            + "admitted=\(surfaceHandler?(.live)?.painterFeedsAdmitted ?? false) "
            + "handoff={\(handoffDescription)} pendingFences=\(repaintFences.count) "
            + "retiredThrough=\(retiredTransportRequestIDUpperBound) "
            + "events=[\(events)]"
    }

    private static func ownerDescription(_ owner: TerminalRenderOwner) -> String {
        "\(owner.windowId.description)/\(owner.paneId.description)/e\(owner.epoch)"
    }

    /// `TerminalBox.bind` clears scrollback through SwiftTerm, which reports
    /// `scrolled` synchronously. On mosh+tmux that callback can report
    /// returned-to-tail, and the ledger answers with a fresh-epoch bind while
    /// the outer bind is still on the stack. The nested bind has already
    /// installed the painter handoff for the owner the box now holds, so the
    /// outer frame must not install its stale owner on top: that leaves the
    /// painter closed behind a retry which can never match the bound owner.
    private func bindStillOwnsLivePainter(
        _ box: TerminalBox,
        owner: TerminalRenderOwner
    ) -> Bool {
        guard let boundOwner = box.boundOwner, boundOwner != owner else { return true }
        let event = "bind-superseded \(Self.ownerDescription(owner)) by "
            + "\(Self.ownerDescription(boundOwner))"
        recordPainterEvent(event)
        MoshDiagnostics.log("mosh view \(event)")
        return false
    }

    private static func hasSamePainterIdentity(
        _ lhs: TerminalRenderOwner,
        _ rhs: TerminalRenderOwner
    ) -> Bool {
        lhs.windowId == rhs.windowId && lhs.paneId == rhs.paneId
    }

    private static func optionalDescription<T>(_ value: T?) -> String {
        value.map { String(describing: $0) } ?? "nil"
    }

    private static func handoffDescription(_ handoff: PainterHandoff) -> String {
        let request = optionalDescription(handoff.requestID)
        let target = optionalDescription(handoff.deliveryTarget)
        let observedDelivery = optionalDescription(handoff.observedDeliveryID)
        let observedResult = optionalDescription(handoff.observedRenderedFully)
        return [
            "owner=\(ownerDescription(handoff.owner))",
            "floor=\(handoff.naturalOutputFloor)",
            "causal=\(handoff.causalBoundaryObserved)",
            "retry=\(handoff.retryAttempt)",
            "inFlight=\(handoff.requestInFlight)",
            "request=\(request)",
            // Not `target=`: the diagnostics redactor blanks that key.
            "deliveryTarget=\(target)",
            "observed=\(observedDelivery)/\(observedResult)",
            "lease=\(handoff.deliveryLeaseIssued)",
            "fences=\(handoff.deferredFenceIDs)",
        ].joined(separator: " ")
    }

    private func recordPainterEvent(_ event: String) {
        painterEventsForTesting.append(event)
        if painterEventsForTesting.count > 40 {
            painterEventsForTesting.removeFirst(painterEventsForTesting.count - 40)
        }
    }

    func reset() {
        painterRetryTask?.cancel()
        painterRetryTask = nil
        painterReceiptWatchdogTask?.cancel()
        painterReceiptWatchdogTask = nil
        cancelHistoryRepaintTasks()
        let handoffOwner = painterHandoff.flatMap { handoff in
            surfaceHandler?(.live)?.boundOwner == handoff.owner ? handoff.owner : nil
        }
        retireTransportRequestsThroughCurrent()
        if let requestID = painterHandoff?.requestID {
            rememberRetiredTransportRequestID(requestID)
            cancelTransportFullFrame?(requestID)
        }
        repaintFences.forEach(retireTransportRequest)
        retireOwnedRepaints()
        pendingHistoryBySurface.removeAll(keepingCapacity: true)
        pendingScrollPointsBySurface.removeAll(keepingCapacity: true)
        pendingWindowModeRestores.removeAll(keepingCapacity: true)
        unfencedHistoryCandidate = nil
        repaintFences.removeAll(keepingCapacity: true)
        painterHandoff = handoffOwner.map {
            PainterHandoff(
                owner: $0,
                naturalOutputFloor: currentTransportOutputDeliveryID?() ?? 0,
                causalBoundaryObserved: true
            )
        }
        surfaceHandler?(.live)?.setAcceptsPainterFeeds(handoffOwner == nil)
        if let handoffOwner {
            schedulePainterRepaint(for: handoffOwner, retryAttempt: 0)
        }
    }

    /// Terminal lifecycle boundary for transport loss or view disappearance.
    /// Unlike a presentation reset, teardown must not keep a closed painter
    /// behind an endlessly rearmed forced-frame request.
    func deactivate() {
        painterRetryTask?.cancel()
        painterRetryTask = nil
        painterReceiptWatchdogTask?.cancel()
        painterReceiptWatchdogTask = nil
        cancelHistoryRepaintTasks()
        retireTransportRequestsThroughCurrent()
        repaintFences.forEach(retireTransportRequest)
        retireOwnedRepaints()
        if let requestID = painterHandoff?.requestID {
            rememberRetiredTransportRequestID(requestID)
            cancelTransportFullFrame?(requestID)
        }
        pendingHistoryBySurface.removeAll(keepingCapacity: true)
        pendingScrollPointsBySurface.removeAll(keepingCapacity: true)
        pendingWindowModeRestores.removeAll(keepingCapacity: true)
        unfencedHistoryCandidate = nil
        repaintFences.removeAll(keepingCapacity: true)
        painterHandoff = nil
        surfaceHandler?(.live)?.setAcceptsPainterFeeds(true)
    }

    /// Records the exact fate of one receipt-bearing Mosh delivery. A larger
    /// unrelated delivery must never release an older history fence, and a
    /// frame rejected (or revoked between cooperative slices) is not evidence
    /// that the terminal contains the framebuffer the driver promised.
    func noteTransportOutputResult(
        deliveryID: UInt64,
        repaintRequestID: UInt64?,
        renderedFully: Bool
    ) {
        guard deliveryID > 0, let repaintRequestID else { return }

        if var handoff = painterHandoff,
           handoff.requestID == repaintRequestID {
            if handoff.observedDeliveryID == nil {
                handoff.observedDeliveryID = deliveryID
                handoff.observedRenderedFully = renderedFully
            }
            painterHandoff = handoff
            recordPainterEvent(
                "receipt r\(repaintRequestID) d\(deliveryID) full=\(renderedFully)"
            )
        }

        if var owned = ownedRepaintsByRequestID[repaintRequestID],
           owned.observedDeliveryID == nil {
            owned.observedDeliveryID = deliveryID
            owned.observedRenderedFully = renderedFully
            ownedRepaintsByRequestID[repaintRequestID] = owned
        }

        if renderedFully {
            let liveOwner = surfaceHandler?(.live)?.boundOwner
            for index in repaintFences.indices
            where repaintFences[index].transportRequestID == repaintRequestID
                    && repaintFences[index].painterOwner == liveOwner {
                repaintFences[index].acceptedDeliveryID = deliveryID
            }
        } else if painterHandoff?.requestID != repaintRequestID {
            let expectedTarget = repaintFences.compactMap { fence -> UInt64? in
                guard fence.transportRequestID == repaintRequestID,
                      case .output(let target) = fence.deliveryTarget,
                      target == deliveryID
                else { return nil }
                return target
            }.first
            if let expectedTarget {
                let rearmed = rearmHistoryRepaintRequest(
                    requestID: repaintRequestID,
                    expectedOutputTarget: expectedTarget
                )
                scheduleHistoryRepaintRetry(rearmed)
            }
        }

        finishPainterHandoffIfReady()
        finishOwnedRepaintIfReady(requestID: repaintRequestID)
        drainRepaintFences()
    }

    /// Mosh owns the screen. Its natural output also supplies the history
    /// activity signal, so the metadata-only SSH control client never has to
    /// receive a second copy of every pane's terminal bytes.
    ///
    /// The painter binds only for its own history request, and a split's
    /// painter shows several panes, so it stays unbound there. The presented
    /// pane reader's owner then vouches for the window instead.
    func noteTransportOutputActivity(
        deliveryID: UInt64?,
        repaintRequestID: UInt64?,
        byteCount: Int,
        readerSurfaceID: SurfaceId? = nil
    ) {
        guard byteCount > 0, repaintRequestID == nil else { return }
        let surfaceID: SurfaceId
        let owner: TerminalRenderOwner
        if let liveOwner = surfaceHandler?(.live)?.boundOwner {
            if let handoff = painterHandoff {
                guard handoff.owner == liveOwner,
                      handoff.causalBoundaryObserved,
                      let deliveryID, deliveryID > handoff.naturalOutputFloor
                else { return }
            }
            (surfaceID, owner) = (.live, liveOwner)
        } else if let readerSurfaceID,
                  let readerOwner = surfaceHandler?(readerSurfaceID)?.boundOwner {
            (surfaceID, owner) = (readerSurfaceID, readerOwner)
        } else {
            return
        }
        activityController?.submitRenderFact(.transportOutputObserved(
            surfaceID,
            owner: RenderOwner(
                windowID: owner.windowId,
                paneID: owner.paneId,
                epoch: owner.epoch
            )
        ))
    }

    /// Rejects a forced frame whose correlated history owner was retired.
    /// MoshSession also suppresses these at source; this final seam covers an
    /// event already yielded before the cancellation reached that source.
    func acceptsTransportOutput(
        deliveryID: UInt64? = nil,
        repaintRequestID: UInt64?
    ) -> Bool {
        makeTransportOutputLease(
            deliveryID: deliveryID,
            repaintRequestID: repaintRequestID
        ).acceptsNextSlice()
    }

    /// Captures the live owner at the start of one transport chunk and checks
    /// it again before every cooperative renderer slice. A bind between
    /// yields therefore revokes the rest of the old chunk instead of letting
    /// its suffix enter the replacement owner's buffer.
    func makeTransportOutputLease(
        deliveryID: UInt64? = nil,
        repaintRequestID: UInt64?
    ) -> TransportOutputLease {
        let expectedOwner = surfaceHandler?(.live)?.boundOwner
        let feedOwner = repaintRequestID.flatMap { requestID in
            acceptsOwnedTransportRepaint(
                requestID: requestID,
                expectedOwner: expectedOwner
            ) ? expectedOwner : nil
        }
        if feedOwner != nil,
           let repaintRequestID,
           var handoff = painterHandoff,
           handoff.requestID == repaintRequestID,
           handoff.owner == expectedOwner {
            handoff.deliveryLeaseIssued = true
            painterHandoff = handoff
        }
        return TransportOutputLease(owner: feedOwner) { [weak self] in
            guard let self,
                  self.surfaceHandler?(.live)?.boundOwner == expectedOwner
            else { return false }
            return self.acceptsTransportOutput(
                deliveryID: deliveryID,
                repaintRequestID: repaintRequestID,
                expectedOwner: expectedOwner
            )
        }
    }

    private func acceptsTransportOutput(
        deliveryID: UInt64?,
        repaintRequestID: UInt64?,
        expectedOwner: TerminalRenderOwner?
    ) -> Bool {
        guard surfaceHandler?(.live)?.boundOwner == expectedOwner else { return false }
        guard let repaintRequestID else {
            if var handoff = painterHandoff, handoff.owner == expectedOwner {
                guard let deliveryID,
                      deliveryID > handoff.naturalOutputFloor
                else {
                    recordPainterEvent(
                        "natural-reject d\(Self.optionalDescription(deliveryID)) "
                            + "floor=\(handoff.naturalOutputFloor)"
                    )
                    return false
                }
                handoff.causalBoundaryObserved = true
                painterHandoff = handoff
                recordPainterEvent("natural-boundary d\(deliveryID)")
                beginCausalPainterRepaintIfNeeded()
                return false
            }
            return surfaceHandler?(.live)?.painterFeedsAdmitted == true
        }
        if repaintRequestID <= retiredTransportRequestIDUpperBound ||
            retiredTransportRequestIDs.contains(repaintRequestID) {
            return false
        }
        if let handoff = painterHandoff {
            return handoff.owner == expectedOwner
                && handoff.requestID == repaintRequestID
        }
        if acceptsOwnedTransportRepaint(
            requestID: repaintRequestID,
            expectedOwner: expectedOwner
        ) {
            return true
        }
        return surfaceHandler?(.live)?.painterFeedsAdmitted == true
    }

    private func acceptsOwnedTransportRepaint(
        requestID: UInt64,
        expectedOwner: TerminalRenderOwner?
    ) -> Bool {
        if let handoff = painterHandoff,
           handoff.requestID == requestID {
            return handoff.owner == expectedOwner
        }
        if let owned = ownedRepaintsByRequestID[requestID] {
            return owned.owner == expectedOwner
        }
        return repaintFences.contains { fence in
            fence.transportRequestID == requestID
                && fence.painterOwner == expectedOwner
        }
    }

    /// Schedules a full frame whose bytes must cross the terminal seam as the
    /// currently bound live owner. Authority reclaims use this path so their
    /// frame cannot bypass an active painter handoff or arrive as an unowned
    /// painter feed. Completion fires only after the driver's exact target was
    /// fully rendered by the still-bound owner; nil is a terminal/stale result.
    func requestOwnedTransportFullFrame(
        retargetsAcrossSurfaceRebind: Bool = false,
        onScheduled: @escaping @MainActor (UInt64) -> Void,
        completion: @escaping @MainActor (UInt64?) -> Void
    ) {
        guard let owner = surfaceHandler?(.live)?.boundOwner else {
            completion(nil)
            return
        }
        let repaint = DeferredOwnedRepaint(
            owner: owner,
            retargetable: retargetsAcrossSurfaceRebind,
            onScheduled: onScheduled,
            completion: completion
        )
        if painterHandoff != nil || !ownedRepaintsByRequestID.isEmpty {
            deferredOwnedRepaints.append(repaint)
            return
        }
        startOwnedRepaint(repaint)
    }

    func noteHistoryRequest(surfaceID: SurfaceId, pointsY: Double, isInertial: Bool) {
        if pointsY != 0 {
            pendingScrollPointsBySurface[surfaceID, default: 0] += pointsY
        }
    }

    func clearHistoryRequest(surfaceID: SurfaceId) {
        pendingScrollPointsBySurface.removeValue(forKey: surfaceID)
    }

    func takePendingScrollPoints(surfaceID: SurfaceId) -> Double {
        pendingScrollPointsBySurface.removeValue(forKey: surfaceID) ?? 0
    }

    func windowModeRestore(surfaceID: SurfaceId) -> MoshWindowModeRestore? {
        pendingWindowModeRestores[surfaceID]
    }

    func discardWindowModeRestore(surfaceID: SurfaceId) {
        pendingWindowModeRestores.removeValue(forKey: surfaceID)
    }

    func install(
        on controller: TmuxController,
        scrollbackLimit: @escaping @MainActor () -> Int,
        boxForSurface: @escaping @MainActor (SurfaceId) -> TerminalBox?,
        fallbackSurfaceState: @escaping @MainActor (SurfaceId) -> SurfaceState?,
        onHistoryReady: @escaping @MainActor (SurfaceId, MoshLedgerHistory) -> Void,
        onHistoryDropped: @escaping @MainActor (SurfaceId, TerminalRenderOwner, String) -> Void,
        onRequestTransportFullFrame: @escaping @MainActor (
            _ onScheduled: @escaping @MainActor (UInt64) -> Void,
            _ completion: @escaping @MainActor (UInt64?) -> Void
        ) -> Void,
        onCancelTransportFullFrame: @escaping @MainActor (UInt64) -> Void,
        onRetireAllTransportFullFrames: @escaping @MainActor () -> UInt64,
        currentTransportOutputDeliveryID: @escaping @MainActor () -> UInt64,
        onSaveWindowModes: @escaping @MainActor (SurfaceId, WindowId) -> Void
    ) {
        activityController = controller
        historyReadyHandler = onHistoryReady
        surfaceHandler = boxForSurface
        requestTransportFullFrame = onRequestTransportFullFrame
        cancelTransportFullFrame = onCancelTransportFullFrame
        retireAllTransportFullFrames = onRetireAllTransportFullFrames
        self.currentTransportOutputDeliveryID = currentTransportOutputDeliveryID
        retireTransportRequestsThroughCurrent()
        controller.renderBindSurface = { [weak self] surfaceID, owner in
            guard let self,
                  let terminalOwner = Self.terminalRenderOwner(owner)
            else { return }
            let box = boxForSurface(surfaceID)
            let previousOwner = box?.boundOwner
            let ownerChanged = previousOwner != terminalOwner
            let preservesSameIdentityScrollIntent = ownerChanged
                && previousOwner.map {
                    Self.hasSamePainterIdentity($0, terminalOwner)
                } == true
            // A surface's first bind has no earlier owner whose gesture could
            // leak into it: the points pending now belong to the request
            // that caused it. A gesture that ends before the capture lands
            // would otherwise place that first page at the live tail.
            let preservedScrollPoints = preservesSameIdentityScrollIntent
                ? self.pendingScrollIntentPoints(for: surfaceID, owner: previousOwner)
                : previousOwner == nil ? self.pendingScrollPointsBySurface[surfaceID] : nil
            let liveOwner = self.surfaceHandler?(.live)?.boundOwner
            let handoffIsFenceFree = self.repaintFences.isEmpty
                && self.painterHandoff?.deferredFenceIDs.isEmpty == true
                && self.painterHandoff?.deliveryLeaseIssued == false
            let transfersFenceFreePainterHandoff = surfaceID == .live
                && ownerChanged
                && previousOwner?.windowId == terminalOwner.windowId
                && previousOwner?.paneId == terminalOwner.paneId
                && handoffIsFenceFree
                && self.painterHandoff?.owner == previousOwner
            // A reader of any pane in the live painter's window leaves that
            // painter alone: split views read unfocused panes too.
            let preservesCurrentLiveWorkForOverlay = surfaceID != .live
                && ownerChanged
                && liveOwner.map { $0.windowId == terminalOwner.windowId } == true
            if ownerChanged {
                if !transfersFenceFreePainterHandoff,
                   !preservesCurrentLiveWorkForOverlay {
                    self.retireTransportRequestsThroughCurrent()
                }
                // Scroll placement is owner-scoped just like captured history.
                // This must cover detached overlay surfaces as well as the
                // live painter, otherwise a rebound overlay can inherit the
                // previous pane's pending gesture.
                let painterIdentityChanged = previousOwner.map {
                    !Self.hasSamePainterIdentity($0, terminalOwner)
                } ?? false
                if painterIdentityChanged {
                    self.pendingScrollPointsBySurface.removeValue(forKey: surfaceID)
                }
            }
            self.retireHistory(for: surfaceID, unlessOwnedBy: terminalOwner)
            guard let box else { return }
            if surfaceID == .live, ownerChanged {
                if transfersFenceFreePainterHandoff,
                   var handoff = self.painterHandoff {
                    // A layout notification can advance only the ledger epoch
                    // after a pane-selection handoff has already consumed its
                    // one natural Mosh boundary. Preserve that exact full-frame
                    // request across the local clear: cancelling and asking SSP
                    // for an adjacent duplicate may yield no bytes at all. This
                    // is intentionally limited to the same window/pane and to a
                    // handoff with no history fence; true identity changes and
                    // synthesized readers still retire every older request.
                    self.painterRetryTask?.cancel()
                    self.painterRetryTask = nil
                    self.retireOwnedRepaints(retargetingTo: terminalOwner)
                    box.setAcceptsPainterFeeds(false)
                    box.bind(owner: terminalOwner, restoringScrollbackLimit: scrollbackLimit())
                    guard self.bindStillOwnsLivePainter(box, owner: terminalOwner) else { return }
                    handoff.owner = terminalOwner
                    self.painterHandoff = handoff
                    let previousDescription = previousOwner.map(Self.ownerDescription) ?? "nil"
                    self.recordPainterEvent(
                        "bind-transfer \(previousDescription) -> "
                            + "\(Self.ownerDescription(terminalOwner)) "
                            + "request=\(Self.optionalDescription(handoff.requestID))"
                    )
                    if handoff.causalBoundaryObserved, !handoff.requestInFlight {
                        self.schedulePainterRepaint(
                            for: terminalOwner,
                            retryAttempt: handoff.retryAttempt
                        )
                    }
                    return
                }
                self.retirePainterWorkForLiveOwnerChange(
                    preservingScrollIntent: preservedScrollPoints.map {
                        (surfaceID: surfaceID, points: $0)
                    },
                    retargetingOwnedRepaintsTo: terminalOwner
                )
                box.setAcceptsPainterFeeds(false)
                box.bind(owner: terminalOwner, restoringScrollbackLimit: scrollbackLimit())
                guard self.bindStillOwnsLivePainter(box, owner: terminalOwner) else { return }
                let identityChanged = previousOwner.map {
                    $0.windowId != terminalOwner.windowId || $0.paneId != terminalOwner.paneId
                } ?? false
                self.painterHandoff = PainterHandoff(
                    owner: terminalOwner,
                    naturalOutputFloor: currentTransportOutputDeliveryID(),
                    causalBoundaryObserved: !identityChanged
                )
                let previousDescription = previousOwner.map(Self.ownerDescription) ?? "nil"
                self.recordPainterEvent(
                    "bind \(previousDescription) -> "
                        + "\(Self.ownerDescription(terminalOwner)) identity=\(identityChanged) "
                        + "floor=\(self.painterHandoff?.naturalOutputFloor ?? 0)"
                )
                if !identityChanged {
                    self.schedulePainterRepaint(for: terminalOwner, retryAttempt: 0)
                }
                return
            }
            box.bind(owner: terminalOwner, restoringScrollbackLimit: scrollbackLimit())
        }
        controller.renderFeedSurface = { [weak self] surfaceID, owner, bytes, source in
            guard let self,
                  let terminalOwner = Self.terminalRenderOwner(owner)
            else { return false }
            if source == .moshHistory {
                // `historyReady` follows in the same effect transaction and
                // supplies the native placement. Do not let the raw feed snap
                // an actively dragged reader before that boundary.
                pendingHistoryBySurface[surfaceID] = PendingHistory(
                    owner: terminalOwner,
                    bytes: Array(bytes),
                    repaintFenceID: nil
                )
                unfencedHistoryCandidate = (surfaceID, terminalOwner)
                return true
            } else {
                guard let box = boxForSurface(surfaceID) else { return false }
                return box.feed(owner: terminalOwner, bytes)
            }
        }
        controller.renderSurfaceState = { surfaceID in
            if let state = boxForSurface(surfaceID)?.surfaceState {
                return (
                    altScreen: state.altScreen,
                    mouseMode: state.mouseMode,
                    columns: state.columns,
                    rows: state.rows
                )
            }
            return fallbackSurfaceState(surfaceID)
        }
        controller.renderHistoryReady = { [weak self] surfaceID, owner, depth, historySize, placement in
            guard let self,
                  let terminalOwner = Self.terminalRenderOwner(owner)
            else { return }
            guard let pending = pendingHistoryBySurface.removeValue(forKey: surfaceID) else {
                self.discardWindowModeRestore(surfaceID: surfaceID)
                onHistoryDropped(surfaceID, terminalOwner, "missing-bytes-or-owner")
                return
            }
            if unfencedHistoryCandidate?.0 == surfaceID {
                unfencedHistoryCandidate = nil
            }
            guard pending.owner == terminalOwner, !pending.bytes.isEmpty else {
                if let fenceID = pending.repaintFenceID {
                    self.cancelRepaintFence(fenceID)
                }
                self.discardWindowModeRestore(surfaceID: surfaceID)
                onHistoryDropped(surfaceID, terminalOwner, "missing-bytes-or-owner")
                return
            }
            guard let fenceID = pending.repaintFenceID,
                  let fenceIndex = repaintFences.firstIndex(where: {
                      $0.id == fenceID
                          && $0.surfaceID == surfaceID
                          && $0.owner == terminalOwner
                  })
            else {
                if let fenceID = pending.repaintFenceID {
                    self.cancelRepaintFence(fenceID)
                }
                self.discardWindowModeRestore(surfaceID: surfaceID)
                onHistoryDropped(surfaceID, terminalOwner, "missing-repaint-fence")
                return
            }
            let scrollPoints = pendingScrollPointsBySurface.removeValue(forKey: surfaceID) ?? 0
            repaintFences[fenceIndex].history = MoshLedgerHistory(
                owner: terminalOwner,
                bytes: pending.bytes,
                depth: depth,
                historySize: historySize,
                placement: placement,
                scrollPoints: scrollPoints
            )
            self.drainRepaintFences()
        }
        controller.requestTransportFullFrame = { [weak self] in
            guard let self else {
                onRequestTransportFullFrame({ _ in }, { _ in })
                return
            }

            // Generic layout/tail repaint effects have no history payload and
            // must not steal the next capture's fence. Only the immediately
            // preceding, still-unfenced moshHistory feed establishes this
            // request as the ordered predecessor of historyReady.
            let fenceID: UInt64?
            if let candidate = self.unfencedHistoryCandidate,
               var pending = self.pendingHistoryBySurface[candidate.0],
               pending.owner == candidate.1,
               pending.repaintFenceID == nil {
                fenceID = self.beginRepaintFence(
                    surfaceID: candidate.0,
                    owner: candidate.1
                )
                pending.repaintFenceID = fenceID
                self.pendingHistoryBySurface[candidate.0] = pending
            } else {
                fenceID = nil
            }
            self.unfencedHistoryCandidate = nil
            self.requestRepaint(fenceIDs: fenceID.map { [$0] } ?? [])
        }
        controller.renderSaveWindowModes = onSaveWindowModes
        controller.renderRestoreWindowModes = { [weak self] surfaceID, windowID, paneInAltScreen in
            self?.pendingWindowModeRestores[surfaceID] = MoshWindowModeRestore(
                windowID: windowID,
                paneInAltScreen: paneInAltScreen
            )
        }
    }

    private static func terminalRenderOwner(_ owner: RenderOwner) -> TerminalRenderOwner? {
        guard let windowID = owner.windowID, let paneID = owner.paneID else { return nil }
        return TerminalRenderOwner(windowId: windowID, paneId: paneID, epoch: owner.epoch)
    }

    private func requestRepaint(fenceIDs: [UInt64]) {
        if var handoff = painterHandoff {
            for fenceID in fenceIDs where !handoff.deferredFenceIDs.contains(fenceID) {
                handoff.deferredFenceIDs.append(fenceID)
            }
            painterHandoff = handoff

            // The handoff frame is already the authoritative full image for
            // the currently bound painter. A history capture that lands while
            // it is unresolved must join that exact request; asking Mosh for a
            // second immediately-adjacent force can validly produce no bytes
            // and strand historyReady forever. Empty layout/tail repaints are
            // likewise satisfied by the in-flight full frame.
            guard handoff.requestInFlight, let requestID = handoff.requestID else { return }
            attachPainterHandoffFences(
                fenceIDs,
                requestID: requestID,
                owner: handoff.owner,
                deliveryTarget: handoff.deliveryTarget,
                observedDeliveryID: handoff.observedDeliveryID,
                observedRenderedFully: handoff.observedRenderedFully
            )
            return
        }
        startTransportRepaint(fenceIDs: fenceIDs, handoffOwner: nil)
    }

    /// After a window/pane identity change, the first natural chunk is
    /// deliberately not rendered. Its arrival proves Mosh observed the new
    /// remote painter state. Initial/same-pane epoch binds use the driver's
    /// serial queue directly and are scheduled by
    /// `schedulePainterRepaint` so a quiescent pane cannot deadlock.
    private func beginCausalPainterRepaintIfNeeded() {
        guard var handoff = painterHandoff,
              handoff.causalBoundaryObserved,
              !handoff.requestInFlight
        else { return }
        handoff.requestInFlight = true
        let fenceIDs = handoff.deferredFenceIDs
        painterHandoff = handoff
        recordPainterEvent("repaint-start owner=\(Self.ownerDescription(handoff.owner))")
        startTransportRepaint(fenceIDs: fenceIDs, handoffOwner: handoff.owner)
    }

    private func schedulePainterRepaint(
        for owner: TerminalRenderOwner,
        retryAttempt: Int
    ) {
        painterRetryTask?.cancel()
        painterRetryTask = Task { @MainActor [weak self] in
            // Let the rest of the ledger effect batch run first. A following
            // history repaint can then attach its fence to this single frame.
            await Task.yield()
            let retryDelaysNanos: [UInt64] = [0, 50_000_000, 200_000_000, 1_000_000_000]
            let delay = retryDelaysNanos[min(retryAttempt, retryDelaysNanos.count - 1)]
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled,
                  let self,
                  let handoff = self.painterHandoff,
                  handoff.owner == owner,
                  handoff.retryAttempt == retryAttempt,
                  handoff.causalBoundaryObserved,
                  !handoff.requestInFlight,
                  self.surfaceHandler?(.live)?.boundOwner == owner
            else { return }
            self.painterRetryTask = nil
            self.beginCausalPainterRepaintIfNeeded()
        }
    }

    private func startOwnedRepaint(_ repaint: DeferredOwnedRepaint) {
        guard painterHandoff == nil,
              ownedRepaintsByRequestID.isEmpty,
              surfaceHandler?(.live)?.boundOwner == repaint.owner,
              let requestTransportFullFrame
        else {
            repaint.completion(nil)
            startNextDeferredOwnedRepaintIfPossible()
            return
        }

        var scheduledRequestID: UInt64?
        var completedBeforeSchedule = false
        requestTransportFullFrame(
            { [weak self] requestID in
                if completedBeforeSchedule {
                    self?.rememberRetiredTransportRequestID(requestID)
                    self?.cancelTransportFullFrame?(requestID)
                    return
                }
                scheduledRequestID = requestID
                guard let self,
                      self.painterHandoff == nil,
                      self.ownedRepaintsByRequestID.isEmpty,
                      self.surfaceHandler?(.live)?.boundOwner == repaint.owner
                else {
                    self?.rememberRetiredTransportRequestID(requestID)
                    self?.cancelTransportFullFrame?(requestID)
                    repaint.completion(nil)
                    self?.startNextDeferredOwnedRepaintIfPossible()
                    return
                }
                self.ownedRepaintsByRequestID[requestID] = OwnedRepaintReceipt(
                    owner: repaint.owner,
                    retargetable: repaint.retargetable,
                    onScheduled: repaint.onScheduled,
                    completion: repaint.completion,
                    deliveryTarget: nil,
                    observedDeliveryID: nil,
                    observedRenderedFully: nil
                )
                repaint.onScheduled(requestID)
            },
            { [weak self] outputTarget in
                guard let self else { return }
                guard let requestID = scheduledRequestID else {
                    completedBeforeSchedule = true
                    repaint.completion(nil)
                    self.startNextDeferredOwnedRepaintIfPossible()
                    return
                }
                guard
                      var receipt = self.ownedRepaintsByRequestID[requestID]
                else { return }
                guard let outputTarget, outputTarget > 0 else {
                    self.failOwnedRepaint(requestID: requestID)
                    return
                }
                receipt.deliveryTarget = outputTarget
                self.ownedRepaintsByRequestID[requestID] = receipt
                self.finishOwnedRepaintIfReady(requestID: requestID)
            }
        )
    }

    private func finishOwnedRepaintIfReady(requestID: UInt64) {
        guard let receipt = ownedRepaintsByRequestID[requestID],
              let target = receipt.deliveryTarget,
              receipt.observedDeliveryID == target,
              let renderedFully = receipt.observedRenderedFully
        else { return }

        ownedRepaintsByRequestID.removeValue(forKey: requestID)
        let accepted = renderedFully
            && surfaceHandler?(.live)?.boundOwner == receipt.owner
        if !accepted {
            rememberRetiredTransportRequestID(requestID)
            cancelTransportFullFrame?(requestID)
        }
        receipt.completion(accepted ? target : nil)
        startNextDeferredOwnedRepaintIfPossible()
    }

    private func failOwnedRepaint(requestID: UInt64) {
        guard let receipt = ownedRepaintsByRequestID.removeValue(forKey: requestID) else { return }
        rememberRetiredTransportRequestID(requestID)
        cancelTransportFullFrame?(requestID)
        receipt.completion(nil)
        startNextDeferredOwnedRepaintIfPossible()
    }

    private func startNextDeferredOwnedRepaintIfPossible() {
        guard painterHandoff == nil, ownedRepaintsByRequestID.isEmpty else { return }
        while !deferredOwnedRepaints.isEmpty {
            let next = deferredOwnedRepaints.removeFirst()
            guard surfaceHandler?(.live)?.boundOwner == next.owner else {
                next.completion(nil)
                continue
            }
            startOwnedRepaint(next)
            return
        }
    }

    /// Retire every outstanding owned full frame.
    ///
    /// `retargetingTo` carries the owner the live surface is about to bind.
    /// A grid-authority reclaim forces tmux geometry, and that force re-lays
    /// the window out, so tmux echoes `%layout-change` while the claim's own
    /// frame is still outstanding; the side-channel ledger rebinds this
    /// surface under a fresh epoch for it. Reporting that as a failed repaint
    /// is what made every mosh+tmux take-back abort its own claim
    /// (`claimAborted(adapterFailure)`) and leave the veil up. The visible
    /// target is the same window and pane — only the epoch moved — so
    /// re-reserve those requests against the new owner and let the
    /// replacement painter handoff carry them. A genuine window/pane switch,
    /// a presentation reset, and transport teardown all still retire.
    private func retireOwnedRepaints(
        retargetingTo newOwner: TerminalRenderOwner? = nil
    ) {
        let active = ownedRepaintsByRequestID
        ownedRepaintsByRequestID.removeAll(keepingCapacity: true)
        let deferred = deferredOwnedRepaints
        deferredOwnedRepaints.removeAll(keepingCapacity: true)
        var retargeted: [DeferredOwnedRepaint] = []
        // A frame already forced for the previous epoch is rejected by the
        // replacement owner, so every retarget asks again under a new request.
        for (requestID, receipt) in active.sorted(by: { $0.key < $1.key }) {
            rememberRetiredTransportRequestID(requestID)
            cancelTransportFullFrame?(requestID)
            if receipt.retargetable,
               let newOwner,
               Self.hasSamePainterIdentity(receipt.owner, newOwner) {
                retargeted.append(DeferredOwnedRepaint(
                    owner: newOwner,
                    retargetable: true,
                    onScheduled: receipt.onScheduled,
                    completion: receipt.completion
                ))
            } else {
                receipt.completion(nil)
            }
        }
        for repaint in deferred {
            if repaint.retargetable,
               let newOwner,
               Self.hasSamePainterIdentity(repaint.owner, newOwner) {
                retargeted.append(DeferredOwnedRepaint(
                    owner: newOwner,
                    retargetable: true,
                    onScheduled: repaint.onScheduled,
                    completion: repaint.completion
                ))
            } else {
                repaint.completion(nil)
            }
        }
        deferredOwnedRepaints = retargeted
        if let newOwner, !retargeted.isEmpty {
            recordPainterEvent(
                "owned-retarget count=\(retargeted.count) "
                    + "owner=\(Self.ownerDescription(newOwner))"
            )
        }
    }

    private func startTransportRepaint(
        fenceIDs: [UInt64],
        handoffOwner: TerminalRenderOwner?
    ) {
        guard let requestTransportFullFrame else {
            if let handoffOwner {
                rearmPainterHandoff(owner: handoffOwner)
            } else {
                scheduleHistoryRepaintRetry(
                    advanceHistoryRepaintAttempts(fenceIDs)
                )
            }
            return
        }
        var scheduledRequestID: UInt64?
        requestTransportFullFrame(
            { [weak self] requestID in
                scheduledRequestID = requestID
                guard let self else { return }
                if let handoffOwner {
                    guard var handoff = self.painterHandoff,
                          Self.hasSamePainterIdentity(handoff.owner, handoffOwner),
                          handoff.requestInFlight,
                          handoff.requestID == nil
                    else {
                        self.rememberRetiredTransportRequestID(requestID)
                        self.cancelTransportFullFrame?(requestID)
                        return
                    }
                    handoff.requestID = requestID
                    let joinedFenceIDs = handoff.deferredFenceIDs
                    self.painterHandoff = handoff
                    self.recordPainterEvent("repaint-scheduled r\(requestID)")
                    self.attachPainterHandoffFences(
                        joinedFenceIDs,
                        requestID: requestID,
                        owner: handoff.owner,
                        deliveryTarget: handoff.deliveryTarget,
                        observedDeliveryID: handoff.observedDeliveryID,
                        observedRenderedFully: handoff.observedRenderedFully
                    )
                } else {
                    fenceIDs.forEach { self.attachTransportRequest(requestID, to: $0) }
                }
            },
            { [weak self] outputTarget in
                guard let self else { return }
                if let handoffOwner {
                    guard let requestID = scheduledRequestID else {
                        if let currentOwner = self.painterHandoff?.owner,
                           Self.hasSamePainterIdentity(currentOwner, handoffOwner) {
                            self.rearmPainterHandoff(owner: currentOwner)
                        }
                        return
                    }
                    self.resolvePainterHandoff(
                        owner: handoffOwner,
                        requestID: requestID,
                        outputTarget: outputTarget
                    )
                } else {
                    guard let requestID = scheduledRequestID else {
                        self.scheduleHistoryRepaintRetry(
                            self.advanceHistoryRepaintAttempts(fenceIDs)
                        )
                        return
                    }
                    guard let outputTarget, outputTarget > 0 else {
                        let rearmed = self.rearmHistoryRepaintRequest(
                            requestID: requestID,
                            expectedOutputTarget: nil
                        )
                        self.scheduleHistoryRepaintRetry(rearmed)
                        return
                    }
                    fenceIDs.forEach {
                        self.resolveRepaintFence($0, outputTarget: outputTarget)
                    }
                    self.armHistoryRepaintReceiptWatchdog(
                        requestID: requestID,
                        outputTarget: outputTarget
                    )
                }
            }
        )
    }

    private func resolvePainterHandoff(
        owner: TerminalRenderOwner,
        requestID: UInt64,
        outputTarget: UInt64?
    ) {
        guard var handoff = painterHandoff,
              Self.hasSamePainterIdentity(handoff.owner, owner),
              handoff.requestInFlight,
              handoff.requestID == requestID
        else { return }
        guard let outputTarget, outputTarget > 0 else {
            recordPainterEvent("repaint-complete r\(requestID) deliveryTarget=nil")
            rearmPainterHandoff(owner: handoff.owner)
            return
        }
        let joinedFenceIDs = handoff.deferredFenceIDs
        handoff.deliveryTarget = outputTarget
        painterHandoff = handoff
        recordPainterEvent("repaint-complete r\(requestID) deliveryTarget=\(outputTarget)")
        joinedFenceIDs.forEach { resolveRepaintFence($0, outputTarget: outputTarget) }
        armPainterReceiptWatchdog(
            owner: handoff.owner,
            requestID: requestID,
            outputTarget: outputTarget
        )
        finishPainterHandoffIfReady()
    }

    private func finishPainterHandoffIfReady() {
        guard let handoff = painterHandoff,
              handoff.requestInFlight,
              let target = handoff.deliveryTarget,
              handoff.observedDeliveryID == target,
              let renderedFully = handoff.observedRenderedFully
        else { return }
        guard renderedFully,
              surfaceHandler?(.live)?.boundOwner == handoff.owner
        else {
            rearmPainterHandoff(owner: handoff.owner)
            return
        }

        painterHandoff = nil
        painterRetryTask?.cancel()
        painterRetryTask = nil
        painterReceiptWatchdogTask?.cancel()
        painterReceiptWatchdogTask = nil
        surfaceHandler?(.live)?.setAcceptsPainterFeeds(true)
        recordPainterEvent(
            "handoff-finished owner=\(Self.ownerDescription(handoff.owner)) deliveryTarget=\(target)"
        )
        drainRepaintFences()
        startNextDeferredOwnedRepaintIfPossible()
    }

    private func rearmPainterHandoff(owner: TerminalRenderOwner) {
        guard let prior = painterHandoff, prior.owner == owner else { return }
        painterReceiptWatchdogTask?.cancel()
        painterReceiptWatchdogTask = nil
        recordPainterEvent(
            "handoff-rearm owner=\(Self.ownerDescription(owner)) "
                + "request=\(Self.optionalDescription(prior.requestID)) "
                + "attempt=\(prior.retryAttempt + 1)"
        )
        if let requestID = prior.requestID {
            // Handoff requests are serialized: once this one fails, every
            // earlier request is also terminal. Collapse them into the
            // high-water mark instead of growing an unbounded tombstone set
            // during a long connected-but-quiescent retry loop.
            retiredTransportRequestIDUpperBound = max(
                retiredTransportRequestIDUpperBound,
                requestID
            )
            retiredTransportRequestIDs = retiredTransportRequestIDs.filter {
                $0 > retiredTransportRequestIDUpperBound
            }
            cancelTransportFullFrame?(requestID)
            for index in repaintFences.indices
            where repaintFences[index].transportRequestID == requestID {
                repaintFences[index].transportRequestID = nil
                repaintFences[index].deliveryTarget = .awaitingDriver
                repaintFences[index].acceptedDeliveryID = nil
            }
        }
        painterHandoff = PainterHandoff(
            owner: owner,
            naturalOutputFloor: prior.naturalOutputFloor,
            deferredFenceIDs: prior.deferredFenceIDs,
            causalBoundaryObserved: true,
            retryAttempt: prior.retryAttempt + 1
        )
        surfaceHandler?(.live)?.setAcceptsPainterFeeds(false)
        schedulePainterRepaint(for: owner, retryAttempt: prior.retryAttempt + 1)
    }

    private func pendingScrollIntentPoints(
        for surfaceID: SurfaceId,
        owner: TerminalRenderOwner?
    ) -> Double? {
        let late = pendingScrollPointsBySurface[surfaceID]
        let staged = repaintFences.reversed().first(where: { fence in
            fence.surfaceID == surfaceID
                && (owner.map { fence.owner == $0 } ?? true)
                && fence.history != nil
        })?.history?.scrollPoints
        guard late != nil || staged != nil else { return nil }
        return (late ?? 0) + (staged ?? 0)
    }

    private func retirePainterWorkForLiveOwnerChange(
        preservingScrollIntent: (surfaceID: SurfaceId, points: Double)? = nil,
        retargetingOwnedRepaintsTo newOwner: TerminalRenderOwner? = nil
    ) {
        painterRetryTask?.cancel()
        painterRetryTask = nil
        painterReceiptWatchdogTask?.cancel()
        painterReceiptWatchdogTask = nil
        cancelHistoryRepaintTasks()
        retireTransportRequestsThroughCurrent()
        repaintFences.forEach(retireTransportRequest)
        retireOwnedRepaints(retargetingTo: newOwner)
        if let requestID = painterHandoff?.requestID {
            rememberRetiredTransportRequestID(requestID)
            cancelTransportFullFrame?(requestID)
        }
        pendingHistoryBySurface.removeAll(keepingCapacity: true)
        pendingScrollPointsBySurface.removeAll(keepingCapacity: true)
        if let preservingScrollIntent {
            pendingScrollPointsBySurface[preservingScrollIntent.surfaceID]
                = preservingScrollIntent.points
        }
        pendingWindowModeRestores.removeAll(keepingCapacity: true)
        unfencedHistoryCandidate = nil
        repaintFences.removeAll(keepingCapacity: true)
        painterHandoff = nil
    }

    private func beginRepaintFence(
        surfaceID: SurfaceId,
        owner: TerminalRenderOwner
    ) -> UInt64 {
        nextRepaintFenceID &+= 1
        if nextRepaintFenceID == 0 { nextRepaintFenceID = 1 }
        repaintFences.append(RepaintFence(
            id: nextRepaintFenceID,
            surfaceID: surfaceID,
            owner: owner,
            painterOwner: surfaceHandler?(.live)?.boundOwner,
            transportRequestID: nil,
            deliveryTarget: .awaitingDriver,
            acceptedDeliveryID: nil,
            history: nil
        ))
        return nextRepaintFenceID
    }

    private func attachTransportRequest(_ requestID: UInt64, to fenceID: UInt64) {
        guard let index = repaintFences.firstIndex(where: { $0.id == fenceID }) else {
            rememberRetiredTransportRequestID(requestID)
            cancelTransportFullFrame?(requestID)
            return
        }
        historyRepaintRetryTasks.removeValue(forKey: fenceID)?.cancel()
        repaintFences[index].transportRequestID = requestID
    }

    private func attachPainterHandoffFences(
        _ fenceIDs: [UInt64],
        requestID: UInt64,
        owner: TerminalRenderOwner,
        deliveryTarget: UInt64?,
        observedDeliveryID: UInt64?,
        observedRenderedFully: Bool?
    ) {
        for fenceID in fenceIDs {
            guard let index = repaintFences.firstIndex(where: { $0.id == fenceID }) else {
                // A detached overlay can retire its own history while the
                // shared live-painter handoff is still useful. Missing one
                // joined fence must not cancel that owner-authoritative frame.
                continue
            }
            historyRepaintRetryTasks.removeValue(forKey: fenceID)?.cancel()
            repaintFences[index].transportRequestID = requestID
            if observedRenderedFully == true,
               repaintFences[index].painterOwner == owner {
                repaintFences[index].acceptedDeliveryID = observedDeliveryID
            }
            if let deliveryTarget {
                resolveRepaintFence(fenceID, outputTarget: deliveryTarget)
            }
        }
    }

    private func resolveRepaintFence(_ id: UInt64, outputTarget: UInt64?) {
        guard let index = repaintFences.firstIndex(where: { $0.id == id }) else {
            // Reset or a newer ownership declaration retired this request.
            return
        }
        guard case .awaitingDriver = repaintFences[index].deliveryTarget else { return }
        guard let outputTarget, outputTarget > 0 else { return }
        repaintFences[index].deliveryTarget = .output(outputTarget)
        drainRepaintFences()
    }

    private func advanceHistoryRepaintAttempts(_ fenceIDs: [UInt64]) -> [UInt64] {
        var advanced: [UInt64] = []
        for id in fenceIDs {
            guard let index = repaintFences.firstIndex(where: {
                $0.id == id && $0.transportRequestID == nil
            }) else { continue }
            repaintFences[index].retryAttempt += 1
            advanced.append(id)
        }
        return advanced
    }

    /// Retire one exact failed/expired driver request while preserving its
    /// already captured history. The retry asks only for a fresh Mosh frame;
    /// it never sends a second `capture-pane` command.
    private func rearmHistoryRepaintRequest(
        requestID: UInt64,
        expectedOutputTarget: UInt64?
    ) -> [UInt64] {
        let matching = repaintFences.indices.filter { index in
            let fence = repaintFences[index]
            guard fence.transportRequestID == requestID else { return false }
            switch (fence.deliveryTarget, expectedOutputTarget) {
            case (.awaitingDriver, nil):
                return true
            case (.output(let actual), .some(let expected)):
                return actual == expected
            default:
                return false
            }
        }
        guard !matching.isEmpty else { return [] }
        historyRepaintReceiptWatchdogs.removeValue(forKey: requestID)?.cancel()
        rememberRetiredTransportRequestID(requestID)
        cancelTransportFullFrame?(requestID)
        var ids: [UInt64] = []
        for index in matching {
            repaintFences[index].transportRequestID = nil
            repaintFences[index].deliveryTarget = .awaitingDriver
            repaintFences[index].acceptedDeliveryID = nil
            repaintFences[index].retryAttempt += 1
            ids.append(repaintFences[index].id)
        }
        recordPainterEvent(
            "history-repaint-rearm r\(requestID) target="
                + "\(Self.optionalDescription(expectedOutputTarget)) fences=\(ids)"
        )
        return ids
    }

    private func scheduleHistoryRepaintRetry(_ fenceIDs: [UInt64]) {
        for id in fenceIDs {
            historyRepaintRetryTasks.removeValue(forKey: id)?.cancel()
            guard let fence = repaintFences.first(where: {
                $0.id == id && $0.transportRequestID == nil
            }) else { continue }
            let delays: [UInt64] = [50_000_000, 200_000_000, 1_000_000_000]
            let delay = delays[min(max(0, fence.retryAttempt - 1), delays.count - 1)]
            historyRepaintRetryTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled,
                      let self,
                      self.repaintFences.contains(where: {
                          $0.id == id && $0.transportRequestID == nil
                      })
                else { return }
                self.historyRepaintRetryTasks.removeValue(forKey: id)
                self.startTransportRepaint(fenceIDs: [id], handoffOwner: nil)
            }
        }
    }

    private func armHistoryRepaintReceiptWatchdog(
        requestID: UInt64,
        outputTarget: UInt64
    ) {
        guard repaintFences.contains(where: {
            guard $0.transportRequestID == requestID,
                  case .output(let target) = $0.deliveryTarget
            else { return false }
            return target == outputTarget
        }) else { return }
        historyRepaintReceiptWatchdogs.removeValue(forKey: requestID)?.cancel()
        let timeout = repaintReceiptTimeoutNanoseconds
        historyRepaintReceiptWatchdogs[requestID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled, let self else { return }
            self.historyRepaintReceiptWatchdogs.removeValue(forKey: requestID)
            let rearmed = self.rearmHistoryRepaintRequest(
                requestID: requestID,
                expectedOutputTarget: outputTarget
            )
            self.scheduleHistoryRepaintRetry(rearmed)
        }
    }

    private func armPainterReceiptWatchdog(
        owner: TerminalRenderOwner,
        requestID: UInt64,
        outputTarget: UInt64
    ) {
        painterReceiptWatchdogTask?.cancel()
        let timeout = repaintReceiptTimeoutNanoseconds
        painterReceiptWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled,
                  let self,
                  let handoff = self.painterHandoff,
                  handoff.owner == owner,
                  handoff.requestID == requestID,
                  handoff.deliveryTarget == outputTarget
            else { return }
            self.painterReceiptWatchdogTask = nil
            self.rearmPainterHandoff(owner: owner)
        }
    }

    private func cancelHistoryRepaintTasks() {
        historyRepaintRetryTasks.values.forEach { $0.cancel() }
        historyRepaintRetryTasks.removeAll(keepingCapacity: true)
        historyRepaintReceiptWatchdogs.values.forEach { $0.cancel() }
        historyRepaintReceiptWatchdogs.removeAll(keepingCapacity: true)
    }

    private func cancelRepaintFence(_ id: UInt64) {
        let retiring = repaintFences.filter { $0.id == id }
        historyRepaintRetryTasks.removeValue(forKey: id)?.cancel()
        repaintFences.removeAll(where: { $0.id == id })
        detachRetiredFenceIDs([id])
        retiring.forEach(retireTransportRequestIfUnreferenced)
        retiring.compactMap(\.transportRequestID).forEach(cancelHistoryReceiptWatchdogIfUnreferenced)
        drainRepaintFences()
    }

    private func cancelHistoryReceiptWatchdogIfUnreferenced(_ requestID: UInt64) {
        guard !repaintFences.contains(where: { $0.transportRequestID == requestID }) else { return }
        historyRepaintReceiptWatchdogs.removeValue(forKey: requestID)?.cancel()
    }

    /// A history fence can share the live painter's owner-authoritative full
    /// frame. Retiring that reader must detach only the fence; cancelling the
    /// shared request would suppress its tagged bytes at the Mosh session
    /// boundary and leave the live surface closed forever. Generic requests
    /// still retire as soon as their final fence disappears.
    private func retireTransportRequestIfUnreferenced(_ fence: RepaintFence) {
        guard let requestID = fence.transportRequestID else { return }
        guard painterHandoff?.requestID != requestID,
              ownedRepaintsByRequestID[requestID] == nil,
              !repaintFences.contains(where: { $0.transportRequestID == requestID })
        else { return }
        retireTransportRequest(fence)
    }

    private func retireTransportRequest(_ fence: RepaintFence) {
        guard let requestID = fence.transportRequestID else { return }
        rememberRetiredTransportRequestID(requestID)
        cancelTransportFullFrame?(requestID)
    }

    private func detachRetiredFenceIDs(_ ids: Set<UInt64>) {
        guard var handoff = painterHandoff else { return }
        handoff.deferredFenceIDs.removeAll(where: ids.contains)
        painterHandoff = handoff
    }

    private func rememberRetiredTransportRequestID(_ requestID: UInt64) {
        guard requestID > retiredTransportRequestIDUpperBound else { return }
        retiredTransportRequestIDs.insert(requestID)
    }

    private func retireTransportRequestsThroughCurrent() {
        guard let upperBound = retireAllTransportFullFrames?() else { return }
        retiredTransportRequestIDUpperBound = max(
            retiredTransportRequestIDUpperBound,
            upperBound
        )
        retiredTransportRequestIDs = retiredTransportRequestIDs.filter {
            $0 > retiredTransportRequestIDUpperBound
        }
    }

    private func retireHistory(
        for surfaceID: SurfaceId,
        unlessOwnedBy owner: TerminalRenderOwner
    ) {
        if let pending = pendingHistoryBySurface[surfaceID], pending.owner != owner {
            pendingHistoryBySurface.removeValue(forKey: surfaceID)
            if let fenceID = pending.repaintFenceID {
                cancelRepaintFence(fenceID)
            }
        }
        if let candidate = unfencedHistoryCandidate,
           candidate.0 == surfaceID,
           candidate.1 != owner {
            unfencedHistoryCandidate = nil
        }
        let retiring = repaintFences.filter {
            $0.surfaceID == surfaceID && $0.owner != owner
        }
        let retiringIDs = Set(retiring.map(\.id))
        for id in retiringIDs {
            historyRepaintRetryTasks.removeValue(forKey: id)?.cancel()
        }
        repaintFences.removeAll(where: { retiringIDs.contains($0.id) })
        detachRetiredFenceIDs(retiringIDs)
        retiring.forEach(retireTransportRequestIfUnreferenced)
        retiring.compactMap(\.transportRequestID).forEach(cancelHistoryReceiptWatchdogIfUnreferenced)
        pendingWindowModeRestores.removeValue(forKey: surfaceID)
        drainRepaintFences()
    }

    private func drainRepaintFences() {
        while let first = repaintFences.first,
              let history = first.history {
            switch first.deliveryTarget {
            case .awaitingDriver:
                return
            case .output(let target) where first.acceptedDeliveryID != target:
                return
            case .output:
                repaintFences.removeFirst()
                historyRepaintRetryTasks.removeValue(forKey: first.id)?.cancel()
                if let requestID = first.transportRequestID {
                    cancelHistoryReceiptWatchdogIfUnreferenced(requestID)
                }
                if first.surfaceID == .live,
                   let box = surfaceHandler?(first.surfaceID),
                   box.boundOwner == history.owner {
                    box.setAcceptsPainterFeeds(false)
                }
                historyReadyHandler?(first.surfaceID, history)
            }
        }
    }
}

private enum MoshPaneScrollbackPlacement {
    case top
    case bottomMinus(CGFloat)
    case absolute(CGFloat)

    var requiresScrollableContent: Bool {
        switch self {
        case .top:
            return false
        case .bottomMinus:
            return true
        case .absolute(let y):
            return y > 0
        }
    }

    var logDescription: String {
        switch self {
        case .top:
            return "top"
        case .bottomMinus(let points):
            return "bottom-minus-\(String(format: "%.1f", points))"
        case .absolute(let y):
            return "absolute-\(String(format: "%.1f", y))"
        }
    }
}

private struct MoshPaneChromeSnapshot {
    let windowId: WindowId
    let layout: WindowLayout
    let activePaneId: PaneId?
    let panes: [TmuxController.PaneInfo]
    let windowName: String?
}

private enum MoshSideChannelState: Equatable {
    case idle
    case connecting(attempt: Int)
    case connected
    case reconnecting(lastError: String?, retryAttempt: Int, nextRetryDelay: TimeInterval?)
    case degraded(lastError: String?)
    case failed(lastError: String?)

    var isControlUnavailable: Bool {
        switch self {
        case .reconnecting, .degraded, .failed:
            return true
        case .idle, .connecting, .connected:
            return false
        }
    }

    var showsPersistentWarning: Bool {
        switch self {
        case .reconnecting, .degraded, .failed:
            return true
        case .idle, .connecting, .connected:
            return false
        }
    }

    var tcpControlStatus: MoshTcpControlStatus {
        switch self {
        case .connected:
            return .connected
        case .connecting, .reconnecting:
            return .retrying
        case .idle, .degraded, .failed:
            return .disconnected
        }
    }

    var blocksTmuxCommands: Bool {
        switch self {
        case .reconnecting, .degraded, .failed:
            return true
        case .idle, .connecting, .connected:
            return false
        }
    }

    var compactLabel: String {
        switch self {
        case .reconnecting:
            return "tmux reconnecting"
        case .failed:
            return "tmux failed"
        case .degraded:
            return "tmux offline"
        case .idle:
            return "tmux idle"
        case .connecting:
            return "tmux connecting"
        case .connected:
            return "tmux connected"
        }
    }

    var controlStateText: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .degraded:
            return "degraded"
        case .failed:
            return "failed"
        }
    }

    var lastErrorText: String? {
        switch self {
        case .reconnecting(let lastError, _, _),
             .degraded(let lastError),
             .failed(let lastError):
            return lastError
        case .idle, .connecting, .connected:
            return nil
        }
    }

    var retryText: String? {
        switch self {
        case .connecting(let attempt):
            return "attempt \(attempt)"
        case .reconnecting(_, let retryAttempt, let nextRetryDelay):
            if let nextRetryDelay {
                return "attempt \(retryAttempt), next in \(Self.formatDelay(nextRetryDelay))"
            }
            return "attempt \(retryAttempt)"
        case .idle, .connected, .degraded, .failed:
            return nil
        }
    }

    var logDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting(let attempt):
            return "connecting(attempt=\(attempt))"
        case .connected:
            return "connected"
        case .reconnecting(let lastError, let retryAttempt, let nextRetryDelay):
            return "reconnecting(attempt=\(retryAttempt),backoff=\(nextRetryDelay.map(Self.formatDelay) ?? "active"),error=\(lastError ?? "nil"))"
        case .degraded(let lastError):
            return "degraded(error=\(lastError ?? "nil"))"
        case .failed(let lastError):
            return "failed(error=\(lastError ?? "nil"))"
        }
    }

    private static func formatDelay(_ delay: TimeInterval) -> String {
        if delay.rounded() == delay {
            return "\(Int(delay))s"
        }
        return String(format: "%.1fs", delay)
    }
}



/// Variant of `TerminalSurface` that exposes a `onMade` hook so the
/// parent can grab the `TerminalView` after construction, and an
/// `onSend` callback so keystrokes flow out to the session.
///
/// The view returned is a `TesseraTerminalContainer`: a UIView that
/// hosts a SwiftTerm `TerminalView` as its only subview and claims
/// tmux shortcuts via `UIKeyCommand` through its position in the
/// responder chain. See `TesseraTerminalView.swift` for the ⌘T / ⌘⇧W
/// / ⌘1-9 / ⌘⇧[ / ⌘⇧] bindings and why ⌘⇧W (not ⌘W).
/// What an `onPrimaryScrollbackDelta` host did with a primary-screen scroll
/// delta. The distinction between "local visual scroll" and "semantic /
/// dropped" is what gates the coordinator's inertia glide — a fling must
/// never keep emitting wheel/arrow events into a remote app after the
/// fingers leave the trackpad.
enum TerminalPrimaryScrollConsumption {
    /// Not handled — the coordinator falls through to the direct
    /// `contentOffset` write on its own view.
    case notConsumed
    /// Consumed as local visual scrolling (or a scrollback fetch is in
    /// flight that will extend it); inertia may start or continue.
    case consumedLocalScroll
    /// Consumed semantically (forwarded to the remote app) or dropped;
    /// inertia must not start, and an active glide stops here.
    case consumedCancelInertia
}

@MainActor
final class TerminalKeyboardHandoff {
    let issuedAt: TimeInterval

    // Cover the palette fade and a pane mounted after a window switch, then
    // expire so a later, unrelated text field keeps its first responder.
    static let validityDuration: TimeInterval = 1.0

    private(set) var isSpent = false
    private var editingObservers: [NSObjectProtocol] = []

    var isLive: Bool {
        !isSpent && ProcessInfo.processInfo.systemUptime - issuedAt <= Self.validityDuration
    }

    init(issuedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.issuedAt = issuedAt
        guard isLive else { spend(); return }

        // The palette field is already editing. A new editing session means
        // another input has taken ownership and must revoke this handoff.
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            editingObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.spend() }
            })
        }
        let remaining = Self.validityDuration - (ProcessInfo.processInfo.systemUptime - issuedAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining)) { [weak self] in
            self?.spend()
        }
    }

    func spend() {
        isSpent = true
        for observer in editingObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        editingObservers.removeAll()
    }

    deinit {
        for observer in editingObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private struct TerminalKeyboardHandoffKey: EnvironmentKey {
    static let defaultValue: TerminalKeyboardHandoff? = nil
}

private struct TerminalDrawingEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct TerminalInputAllowedKey: EnvironmentKey {
    static let defaultValue: () -> Bool = { true }
}

extension EnvironmentValues {
    var terminalKeyboardHandoff: TerminalKeyboardHandoff? {
        get { self[TerminalKeyboardHandoffKey.self] }
        set { self[TerminalKeyboardHandoffKey.self] = newValue }
    }

    /// A live permission check: lock state can change between scheduling a
    /// reclaim and executing it, before SwiftUI propagates another update.
    var terminalInputAllowed: () -> Bool {
        get { self[TerminalInputAllowedKey.self] }
        set { self[TerminalInputAllowedKey.self] = newValue }
    }
    /// Session presentation only; never gates transport/emulator consumption.
    /// Every terminal descendant (including tmux panes and mosh overlays)
    /// inherits the same policy on iPhone and iPad.
    var terminalDrawingEnabled: Bool {
        get { self[TerminalDrawingEnabledKey.self] }
        set { self[TerminalDrawingEnabledKey.self] = newValue }
    }
}

struct TerminalSurfaceBound: UIViewRepresentable {
    @Environment(\.terminalDrawingEnabled) private var terminalDrawingEnabled
    @Environment(\.terminalInputAllowed) private var terminalInputAllowed
    @Environment(\.terminalKeyboardHandoff) private var terminalKeyboardHandoff
    let initialData: [UInt8]
    let onMade: (TerminalView) -> Void
    let onReady: () -> Void
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void
    let onTitle: (String) -> Void
    let onUserActivity: (() -> Void)?
    var focusOnlyTap: (() -> Void)? = nil
    let onBell: (() -> Void)?
    /// Primary-screen scroll delta hook (mosh shared surface). Params:
    /// view, raw pointsY, proposed offsetY (after multiplier), max offsetY,
    /// isInertial (true when the delta is a synthetic post-release glide
    /// frame rather than a live gesture event), gesture-start pane ID.
    var onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat, Bool, PaneId?) -> TerminalPrimaryScrollConsumption)? = nil
    var primaryScrollPaneAtLocation: ((TerminalView, CGPoint) -> PaneId?)? = nil
    var onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)? = nil
    /// Pane metadata can distinguish a primary shell from the mouse-enabled
    /// tmux wrapper around it. Nil falls back to the local terminal state.
    var primaryTouchScrollIsLocal: (() -> Bool?)? = nil
    var primaryTouchScrollIsLocalForPane: ((PaneId?) -> Bool?)? = nil
    /// mosh+tmux: the active pane's program asked for the mouse, whether or
    /// not the visible tmux client shows it.
    var remotePaneReportsMouse: (() -> Bool)? = nil
    /// mosh+tmux: the scroll view holds none of the tmux history, so finger
    /// pans take the pointer's route through `onPrimaryScrollbackDelta`.
    var touchPansTakePointerRoute: (() -> Bool)? = nil
    /// mosh+tmux: fetched history covers the live program, so taps there
    /// must not click it.
    var remoteHistoryRevealed: (() -> Bool)? = nil
    /// Fires with `true` when a trackpad pan begins (or a glide keeps the
    /// surface moving after release) and `false` once both have ended.
    /// The mosh host uses it to keep heavyweight off-gesture work (hidden
    /// overlay mounts, history application) from landing mid-scroll.
    var onScrollGestureActivity: ((Bool) -> Void)? = nil
    /// True only for an exact hook-proven `.working` agent on this surface.
    /// The coordinator consumes touch, trackpad, and wheel pans before either
    /// local scrollback or remote TUI semantics can move; the container covers
    /// hardware Page Up / Page Down through the responder chain.
    var agentScrollBlockingActive: Bool = false
    var onAgentScrollBlocked: (() -> Void)? = nil
    let mouseReportingImpliesAltScreen: Bool
    let suppressDirectColorQueryResponses: Bool
    var softwareModifierState: ModifierState? = nil
    let tmuxShortcutsEnabled: Bool
    let onTmuxShortcut: (TesseraTmuxShortcut) -> Void
    let onFindShortcut: ((TesseraFindShortcut) -> Void)?
    let onSwitcherShortcut: ((TesseraSwitcherShortcut) -> Void)?
    let onOpenSettings: (() -> Void)?
    /// ⌘⇧A — toggle Agent Center while SwiftTerm owns first responder.
    var onOpenAgentCenter: (() -> Void)? = nil
    /// When true, `updateUIView` skips its "reclaim first responder"
    /// pass so the find bar's `TextField` can hold focus. Without
    /// this gate the terminal yanks first responder back on every
    /// SwiftUI re-render and the user sees the input cursor blink
    /// briefly in the bar then jump back to the terminal.
    let suppressFirstResponderReclaim: Bool
    /// Actively resign an already-held first responder (and with it the
    /// software keyboard). The reclaim-suppression flag above only prevents
    /// GRABBING focus — a continued-elsewhere veil must also strip focus the
    /// terminal already holds, or software-keyboard keystrokes keep flowing
    /// into the shared PTY underneath the blur.
    var forceResignFirstResponder: Bool = false
    let onHardwareKey: ((TesseraTerminalHardwareKey) -> Void)?
    /// SwiftTerm's `scrolled` (output and `changeScrollback`), plus the
    /// coordinator's own wheel/trackpad writes. UIScrollView's native pan and
    /// deceleration never arrive here.
    var onTerminalScrolled: ((TerminalView) -> Void)? = nil
    /// A reader's finger frames on a non-native surface: UIScrollView's own
    /// pan and the deceleration after it, with the offset before the frame.
    var onNativeScrollFrame: ((TerminalView, CGFloat) -> Void)? = nil
    var scrollRetentionID: String? = nil
    var onScrollDiagnostic: ((String) -> Void)? = nil
    /// OSC 7 cwd reports (SwiftTerm's `hostCurrentDirectoryUpdate`).
    /// Wired only on the shared single-pane surfaces — under tmux the
    /// pane-metadata subscription is the cwd source, not OSC 7.
    var onHostDirectory: ((String?) -> Void)? = nil
    /// ⌘⇧E — toggle the Remote Files panel. Registered on the container
    /// alongside the find/switcher chords.
    var onFilesShortcut: (() -> Void)? = nil
    /// Invoked when a user-defined shortcut's chord fires; the session encodes
    /// its tokens and writes them to the remote, exactly as a bar chip does.
    var onCustomShortcut: ((CustomShortcut) -> Void)? = nil
    /// §3 selection-menu path actions ("Quick Look" / "Reveal in
    /// Files") — raw selected text in, resolution happens in the owner.
    var onSelectionPathAction: ((TesseraTerminalSelectionPathAction, String) -> Void)? = nil

    /// True when this surface is a pane in a mounted multi-pane grid. Enables
    /// the bare ⌘[/⌘] pane-cycle and ⌘⇧Return zoom chords (the shared
    /// single-pane terminal leaves this false, so those chords no-op there and
    /// the session switcher rides ⌘⇧K/⌘⇧J instead). Defaulted so existing
    /// single-pane call sites are unchanged.
    var paneCycleEnabled: Bool = false

    /// Mosh tap-to-focus. On the mosh path the remote tmux client paints all
    /// panes into the single shared terminal natively (no Tessera grid mounts),
    /// so a tap can't be routed by a per-pane SwiftUI overlay the way the SSH
    /// grid does it. Instead, when the active window is split, a tap on this
    /// shared surface maps to the pane under the finger and selects it over the
    /// side channel. The closure receives the tap point (in the terminal view's
    /// coordinate space) and the measured cell size, and returns `true` when it
    /// consumed the tap (hit a non-focused pane); `false` falls through to
    /// nothing (single-pane / gutter / already-focused). Defaulted `nil` so the
    /// SSH single-pane and grid surfaces are unaffected.
    var onPaneFocusTap: ((CGPoint, CGSize) -> Bool)? = nil

    /// True while the mosh shared surface paints a multi-pane layout — enables
    /// the dedicated focus-tap recognizer (separate from the SGR mouse-tap) so a
    /// tap selects a pane even with terminal mouse reporting off (the common
    /// all-shells case). Paired with `onPaneFocusTap`; both default off for
    /// other surfaces (SSH single-pane, SSH grid panes).
    var paneFocusTapEnabled: Bool = false

    /// Native-scroll surface (the mosh pane-scrollback overlay only): leave
    /// UIScrollView's built-in pan in charge of trackpad/wheel scrolls
    /// instead of installing the custom scroll recognizer. The pan moving
    /// this view's own contentOffset from the first event is the structural
    /// condition that keeps iPadOS from throttling the gesture — the same
    /// reason SSH panes never lag. Also flips the container into
    /// scroll-only hit-testing so clicks/taps fall through to the live
    /// surface underneath. Default false: SSH surfaces and the shared mosh
    /// surface keep the custom recognizer path unchanged.
    var nativeScrollSurface: Bool = false

    /// Non-nil while a background picture backs this surface's canvas: the
    /// terminal renders its *default* background transparent (view +
    /// container go clear) so the TerminalBackdrop mounted behind it shows
    /// through; cells with explicit ANSI backgrounds still paint opaque.
    /// nil (the default) keeps today's opaque theme-color canvas. Only the
    /// on/off state matters here — dim/fill live on the backdrop itself.
    var terminalBackground: ResolvedTerminalBackground? = nil

    /// Live AppearancePreferences read so updateUIView can re-apply terminal
    /// settings (font size, cursor, scrollback) when the user changes them.
    @Environment(AppearancePreferences.self) private var appearance

    /// User keymap overrides and custom shortcuts. `keyCommands` is rebuilt on
    /// every responder query, so an edit in Settings applies to the next
    /// keystroke without re-mounting the terminal.
    @Environment(ShortcutStore.self) private var shortcutStore

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onReady: onReady,
            onSend: onSend,
            onResize: onResize,
            onTitle: onTitle,
            onUserActivity: onUserActivity,
            onBell: onBell,
            onPrimaryScrollbackDelta: onPrimaryScrollbackDelta,
            onPrimaryScrollbackUnderflow: onPrimaryScrollbackUnderflow,
            agentScrollBlockingActive: agentScrollBlockingActive,
            onAgentScrollBlocked: onAgentScrollBlocked,
            mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen,
            suppressDirectColorQueryResponses: suppressDirectColorQueryResponses,
            softwareModifierState: softwareModifierState,
            onHardwareKey: onHardwareKey,
            onTerminalScrolled: onTerminalScrolled,
            scrollRetentionID: scrollRetentionID,
            onScrollDiagnostic: onScrollDiagnostic
        )
    }

    func makeUIView(context: Context) -> TesseraTerminalContainer {
        let container = TesseraTerminalContainer(frame: .zero)
        context.coordinator.onNativeScrollFrame = onNativeScrollFrame
        context.coordinator.primaryScrollPaneAtLocation = primaryScrollPaneAtLocation
        context.coordinator.primaryTouchScrollIsLocal = primaryTouchScrollIsLocal
        context.coordinator.primaryTouchScrollIsLocalForPane = primaryTouchScrollIsLocalForPane
        context.coordinator.remotePaneReportsMouse = remotePaneReportsMouse
        context.coordinator.touchPansTakePointerRoute = touchPansTakePointerRoute
        context.coordinator.remoteHistoryRevealed = remoteHistoryRevealed
        container.terminalView.setSessionDrawingEnabled(terminalDrawingEnabled)
        container.onTmuxShortcut = onTmuxShortcut
        container.tmuxShortcutsEnabled = tmuxShortcutsEnabled
        container.multiPaneActive = paneCycleEnabled
        container.onFindShortcut = onFindShortcut
        container.onSwitcherShortcut = onSwitcherShortcut
        container.onOpenSettings = onOpenSettings
        container.onOpenAgentCenter = onOpenAgentCenter
        container.agentScrollBlockingActive = agentScrollBlockingActive
        container.onAgentScrollBlocked = onAgentScrollBlocked
        container.onFilesShortcut = onFilesShortcut
        container.onSelectionPathAction = onSelectionPathAction
        container.shortcutStore = shortcutStore
        container.onCustomShortcut = onCustomShortcut
        context.coordinator.shortcutStore = shortcutStore
        context.coordinator.naturalTextEditingEnabled = appearance.naturalTextEditingEnabled
        context.coordinator.smoothScrollingEnabled = appearance.smoothScrollingEnabled
        context.coordinator.smoothScrollingSpeed = appearance.smoothScrollingSpeed
        context.coordinator.inputAllowed = terminalInputAllowed
        context.coordinator.keyboardHandoff = terminalKeyboardHandoff
        context.coordinator.noteFocusSuppression(suppressFirstResponderReclaim)
        context.coordinator.onHostDirectory = onHostDirectory

        let view = container.terminalView
        view.agentScrollBlockingActive = agentScrollBlockingActive
        view.onAgentScrollBlocked = onAgentScrollBlocked
        view.terminalDelegate = context.coordinator
        context.coordinator.bindKeyboardFocus(to: view)
        // SwiftTerm ships a default inputAccessoryView with esc/ctrl/arrows.
        // Tessera now renders its own bar as a SwiftUI sibling at the bottom
        // of the session (§14.8 — visible regardless of hardware-keyboard
        // state), so suppress SwiftTerm's bar to avoid a duplicate strip.
        view.inputAccessoryView = nil

        // SwiftTerm's TerminalView is a UIScrollView; iOS scrolls the topmost
        // scrollsToTop-enabled scroll view to the top when the status-bar frame
        // region is tapped. We run fullscreen with the status bar hidden, but
        // the tap region persists — so a tap just below the floating top bar
        // would yank the whole scrollback to row 0. Disable it.
        view.scrollsToTop = false

        applyAppearance(to: view, container: container)
        if !initialData.isEmpty { view.feed(byteArray: initialData[...]) }
        context.coordinator.terminalView = view
        context.coordinator.container = container
        context.coordinator.installHardwareKeyPassthroughIfNeeded()
        context.coordinator.observeHardwareKeyboard()
        onMade(view)

        // This recognizer is dormant in every ordinary terminal state. When an
        // exact hook-proven agent starts working it becomes the prerequisite
        // for both Tessera's semantic pan and UIScrollView's native pan, so it
        // consumes the gesture before either local history or a remote TUI can
        // move. It stays on the terminal view (rather than a SwiftUI overlay)
        // so selection, links, clicks, and all non-scroll input remain intact.
        let agentScrollBlockGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleAgentBlockedScroll(_:))
        )
        agentScrollBlockGesture.allowedScrollTypesMask = .all
        agentScrollBlockGesture.delegate = context.coordinator
        agentScrollBlockGesture.isEnabled = agentScrollBlockingActive
        view.addGestureRecognizer(agentScrollBlockGesture)
        view.agentScrollBlockGesture = agentScrollBlockGesture
        context.coordinator.agentScrollBlockGesture = agentScrollBlockGesture
        view.panGestureRecognizer.require(toFail: agentScrollBlockGesture)

        var scrollGesture: UIPanGestureRecognizer?
        if nativeScrollSurface {
            // Native path: no custom recognizer, no cleared scroll mask —
            // UIScrollView's own pan scrolls the view with native physics
            // and deceleration. bounces=false so bottom-reach parks exactly
            // at the live tail (the host's scrolled handler dismisses
            // there) instead of rubber-banding past it.
            view.bounces = false
            container.passthroughNonScrollHits = true
            // With bounces off, a pan that pins contentOffset at an edge
            // stops producing didScroll callbacks — and the host's
            // history-deepening trigger only evaluates from those. The
            // built-in pan keeps tracking while pinned, so pump the
            // scrolled handler from it: rubbing upward at the top still
            // kicks off the one-shot deepen to full history depth.
            view.panGestureRecognizer.addTarget(
                context.coordinator,
                action: #selector(Coordinator.handleNativeScrollSurfacePan(_:))
            )
        } else {
            // The semantic dispatcher covers indirect input, mouse-enabled or
            // alternate-screen vertical finger pans, and every mosh+tmux
            // finger pan. Other primary touches remain on UIScrollView's
            // native scrollback path.
            let gesture = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleSemanticScroll(_:))
            )
            gesture.allowedScrollTypesMask = .continuous
            gesture.delegate = context.coordinator
            gesture.require(toFail: agentScrollBlockGesture)
            view.addGestureRecognizer(gesture)
            context.coordinator.semanticScrollGesture = gesture
            view.semanticScrollGesture = gesture
            scrollGesture = gesture
            // Primary mouse-enabled touches also use the semantic owner. A
            // native pan must not write the same offset after history lands.
            view.panGestureRecognizer.require(toFail: gesture)

            // A continuous flick can consist of only began/ended callbacks.
            // Separate masks identify the input source without guessing from
            // callback count; wheel notches must never acquire momentum.
            let wheel = UIPanGestureRecognizer(target: context.coordinator,
                action: #selector(Coordinator.handleSemanticScroll(_:)))
            wheel.allowedScrollTypesMask = .discrete
            wheel.allowedTouchTypes = []
            wheel.delegate = context.coordinator
            wheel.require(toFail: agentScrollBlockGesture)
            view.addGestureRecognizer(wheel)
            context.coordinator.discreteScrollGesture = wheel
            view.discreteScrollGesture = wheel

            // UIScrollView (SwiftTerm's TerminalView superclass) has its own
            // built-in panGestureRecognizer that also responds to scroll-type
            // events. When both fire simultaneously, UIScrollView applies its
            // momentum/deceleration model to contentOffset while our handler
            // sets contentOffset directly — the two compete and produce visible
            // stuttering on fast scrolling. Clearing the built-in pan's scroll
            // mask makes it ignore trackpad/wheel events entirely, leaving
            // scroll handling exclusively to our gesture.
            view.panGestureRecognizer.allowedScrollTypesMask = []

            // With the scroll mask cleared, the built-in pan fires for finger
            // drags only. Piggyback on it so a touch landing mid-glide cancels
            // our inertia instead of fighting UIScrollView's native physics.
            view.panGestureRecognizer.addTarget(
                context.coordinator,
                action: #selector(Coordinator.handleNativeTouchPan(_:))
            )
            // Only surfaces with a consumer pay for it: SSH sessions (tmux may
            // attach after this view is made) and the harness.
            if onNativeScrollFrame != nil {
                context.coordinator.observeNativeScrollFrames(of: view)
            }
        }

        // Mouse click gesture for TUI apps (htop, vim, etc.) that
        // enable terminal mouse reporting. SwiftTerm's built-in
        // singleTap has a require(toFail: doubleTap) delay and
        // conflicts with UIScrollView touch handling, making it
        // unreliable on iPadOS. Our gesture fires immediately and
        // uses exact font-metric cell dimensions (matching
        // SwiftTerm's internal computeFontDimensions) to map tap
        // coordinates to the correct grid position.
        let mouseTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMouseTap(_:))
        )
        mouseTap.delegate = context.coordinator
        context.coordinator.mouseTapGesture = mouseTap
        context.coordinator.onPaneFocusTap = onPaneFocusTap
        context.coordinator.paneFocusTapEnabled = paneFocusTapEnabled
        // Prevent phantom clicks at the end of scroll gestures: the tap
        // must not fire if a scroll gesture is in progress or just ended.
        // (Native-scroll surfaces have no custom scroll gesture — and no
        // touch hit-testing either, so their tap recognizers are inert.)
        if let scrollGesture {
            mouseTap.require(toFail: scrollGesture)
        }
        view.addGestureRecognizer(mouseTap)
        // Make SwiftTerm's own singleTap require ours to fail first,
        // so only one fires per tap.
        for existing in view.gestureRecognizers ?? [] {
            if let tap = existing as? UITapGestureRecognizer,
               tap.numberOfTapsRequired == 1,
               tap !== mouseTap {
                tap.require(toFail: mouseTap)
            }
        }

        // Mosh tap-to-focus: a dedicated single-tap recognizer that selects the
        // pane under the finger when the active mosh window is split and mouse
        // reporting is off (`shouldReceive` gates on `paneFocusTapEnabled`).
        // Kept SEPARATE from `mouseTap` on purpose: it carries no
        // `require(toFail:)` against SwiftTerm's singleTap/doubleTap, so it never
        // suppresses link-open / selection-clear / context-menu in split panes
        // and never delays the SGR-click path. It only requires the scroll
        // gesture to fail (no phantom focus change at the end of a scroll).
        let paneFocusTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePaneFocusTap(_:))
        )
        paneFocusTap.delegate = context.coordinator
        if let scrollGesture {
            paneFocusTap.require(toFail: scrollGesture)
        }
        context.coordinator.paneFocusTapGesture = paneFocusTap
        view.addGestureRecognizer(paneFocusTap)

        // Deferred to the next runloop tick because becomeFirstResponder
        // only works once the view is attached to a window. SwiftUI can
        // still be hosting a surface mounted into an existing hierarchy when
        // this runs, so bindKeyboardFocus retries on window attachment. The
        // terminal view is the first responder; the container participates
        // in the responder chain automatically as its superview.
        //
        // Gated on the suppress flag: in a pane grid every pane surface mounts,
        // but only the focused pane (suppress == false) may claim first
        // responder — otherwise the last-mounted pane wins and keystrokes
        // misroute (the structural single-claimant invariant).
        if !suppressFirstResponderReclaim {
            DispatchQueue.main.async {
                guard context.coordinator.permitsFirstResponderReclaim else { return }
                context.coordinator.reclaimFirstResponder(on: view)
            }
        }
        view.focusOnlyTap = focusOnlyTap
        return container
    }

    func updateUIView(_ container: TesseraTerminalContainer, context: Context) {
        container.terminalView.setSessionDrawingEnabled(terminalDrawingEnabled)
        // Re-assign in case SwiftUI recreates the closure on state
        // change — the container outlives individual updateUIView calls
        // but the captured closure might point at stale state.
        container.onTmuxShortcut = onTmuxShortcut
        container.tmuxShortcutsEnabled = tmuxShortcutsEnabled
        container.multiPaneActive = paneCycleEnabled
        container.onFindShortcut = onFindShortcut
        container.onSwitcherShortcut = onSwitcherShortcut
        container.onOpenSettings = onOpenSettings
        container.onOpenAgentCenter = onOpenAgentCenter
        container.agentScrollBlockingActive = agentScrollBlockingActive
        container.onAgentScrollBlocked = onAgentScrollBlocked
        container.terminalView.focusOnlyTap = focusOnlyTap
        container.terminalView.agentScrollBlockingActive = agentScrollBlockingActive
        container.terminalView.onAgentScrollBlocked = onAgentScrollBlocked
        container.onFilesShortcut = onFilesShortcut
        container.onSelectionPathAction = onSelectionPathAction
        container.shortcutStore = shortcutStore
        container.onCustomShortcut = onCustomShortcut
        context.coordinator.onHostDirectory = onHostDirectory
        context.coordinator.onUserActivity = onUserActivity
        context.coordinator.onPrimaryScrollbackDelta = onPrimaryScrollbackDelta
        context.coordinator.onPrimaryScrollbackUnderflow = onPrimaryScrollbackUnderflow
        context.coordinator.primaryScrollPaneAtLocation = primaryScrollPaneAtLocation
        context.coordinator.primaryTouchScrollIsLocal = primaryTouchScrollIsLocal
        context.coordinator.primaryTouchScrollIsLocalForPane = primaryTouchScrollIsLocalForPane
        context.coordinator.remotePaneReportsMouse = remotePaneReportsMouse
        context.coordinator.touchPansTakePointerRoute = touchPansTakePointerRoute
        context.coordinator.remoteHistoryRevealed = remoteHistoryRevealed
        context.coordinator.onScrollGestureActivity = onScrollGestureActivity
        context.coordinator.onAgentScrollBlocked = onAgentScrollBlocked
        context.coordinator.setAgentScrollBlockingActive(agentScrollBlockingActive)
        context.coordinator.onTerminalScrolled = onTerminalScrolled
        context.coordinator.onNativeScrollFrame = onNativeScrollFrame
        context.coordinator.setScrollRetentionID(scrollRetentionID)
        context.coordinator.onScrollDiagnostic = onScrollDiagnostic
        context.coordinator.mouseReportingImpliesAltScreen = mouseReportingImpliesAltScreen
        context.coordinator.suppressDirectColorQueryResponses = suppressDirectColorQueryResponses
        context.coordinator.softwareModifierState = softwareModifierState
        context.coordinator.shortcutStore = shortcutStore
        context.coordinator.naturalTextEditingEnabled = appearance.naturalTextEditingEnabled
        context.coordinator.smoothScrollingEnabled = appearance.smoothScrollingEnabled
        context.coordinator.smoothScrollingSpeed = appearance.smoothScrollingSpeed
        context.coordinator.inputAllowed = terminalInputAllowed
        context.coordinator.keyboardHandoff = terminalKeyboardHandoff
        context.coordinator.noteFocusSuppression(suppressFirstResponderReclaim)
        // Re-bind the mosh tap-to-focus closure + gate every update so the hit
        // test reads the current active window's layout, not a stale capture.
        context.coordinator.onPaneFocusTap = onPaneFocusTap
        context.coordinator.paneFocusTapEnabled = paneFocusTapEnabled
        let terminalView = container.terminalView
        context.coordinator.bindKeyboardFocus(to: terminalView)

        applyAppearance(to: container.terminalView, container: container)

        // If focus drifted away (e.g., a modal briefly took first
        // responder), reclaim it on the next SwiftUI update pass —
        // unless the find bar is open and intentionally holding focus
        // for its own input. Without this gate the terminal grabs
        // first responder back from the find input on every SwiftUI
        // re-render, so typing into the find bar loses focus mid-key.
        let view = container.terminalView
        if forceResignFirstResponder, view.isFirstResponder {
            _ = view.resignFirstResponderForTransition()
        }
        if !view.isFirstResponder {
            if !suppressFirstResponderReclaim {
                DispatchQueue.main.async {
                    guard context.coordinator.permitsFirstResponderReclaim else { return }
                    context.coordinator.reclaimFirstResponder(on: view)
                    context.coordinator.installHardwareKeyPassthroughIfNeeded()
                }
            }
        } else {
            context.coordinator.installHardwareKeyPassthroughIfNeeded()
        }
    }

    /// Apply the user's font size, cursor style+blink, scrollback, and
    /// terminal theme to the SwiftTerm view. Idempotent — safe to call from
    /// both makeUIView and updateUIView. Setting `view.font` triggers a font-
    /// set rebuild + reflow, so we only touch it when the size actually
    /// changed; theme installation is also gated on a cache stored on the
    /// container, since `installColors` schedules a full canvas repaint.
    private func applyAppearance(
        to view: TerminalView,
        container: TesseraTerminalContainer
    ) {
        // Family and size are one decision here: both rebuild the font set and
        // reflow the grid, so they go through the same guarded assignment
        // rather than a second path that could reorder against it. The applied
        // id is cached because `view.font` reports the resolved face, which for
        // the system option is not a name we can compare an id against.
        let desiredSize = CGFloat(appearance.fontSize)
        let desiredFontID = appearance.terminalFontID
        if abs(view.font.pointSize - desiredSize) > 0.5
            || container.appliedTerminalFontID != desiredFontID {
            view.font = TerminalFontResolver.uiFont(id: desiredFontID, size: desiredSize)
            container.appliedTerminalFontID = desiredFontID
        }

        view.getTerminal().setCursorStyle(swiftTermCursorStyle(
            style: appearance.cursorStyle,
            blink: appearance.cursorBlink
        ))

        // §R4.5 scrollback. SwiftTerm's iOS `changeScrollback` refreshes and
        // runs `updateScroller()`, which snaps the UIScrollView to bottom even
        // when the value is unchanged. Cache the applied value here so ordinary
        // SwiftUI updates from busy sessions do not break local scrollback.
        if container.appliedScrollbackLines != appearance.scrollbackLines {
            view.changeScrollback(appearance.scrollbackLines)
            container.appliedScrollbackLines = appearance.scrollbackLines
        }

        let theme = TerminalTheme.find(id: appearance.terminalThemeID)
        container.terminalDefaultBackgroundRGB = theme.bgRGB
        container.terminalDefaultForegroundRGB = theme.fgRGB
        container.terminalMinimumContrast = 0.30
        // Transparent-canvas mode while a background picture is mounted
        // behind this surface. `nativeBackgroundColor` keeps the theme's RGB
        // (OSC 10/11 reports and contrast math read the RGB components) but
        // drops alpha to 0, which makes both the full-canvas fill and every
        // default-background cell run transparent; explicit ANSI backgrounds
        // are unaffected. Dim/fill changes stay on the SwiftUI backdrop, so
        // they don't force a canvas repaint here.
        let wantsTransparentCanvas = terminalBackground != nil
        if container.appliedThemeID != theme.id
            || container.appliedTransparentCanvas != wantsTransparentCanvas {
            view.installColors(theme.ansi.map(swiftTermColor(rgb:)))
            let bg = uiColor(rgb: theme.bgRGB)
            let fg = uiColor(rgb: theme.fgRGB)
            view.nativeForegroundColor = fg
            if wantsTransparentCanvas {
                view.nativeBackgroundColor = bg.withAlphaComponent(0)
                view.isOpaque = false
                view.backgroundColor = .clear
                container.isOpaque = false
                container.backgroundColor = .clear
            } else {
                view.nativeBackgroundColor = bg
                view.isOpaque = true
                view.backgroundColor = bg
                container.isOpaque = true
                container.backgroundColor = bg
            }
            container.appliedThemeID = theme.id
            container.appliedTransparentCanvas = wantsTransparentCanvas
        }
    }


    private func swiftTermCursorStyle(
        style: CursorStyleOption,
        blink: Bool
    ) -> CursorStyle {
        switch (style, blink) {
        case (.block,     true):  return .blinkBlock
        case (.block,     false): return .steadyBlock
        case (.bar,       true):  return .blinkBar
        case (.bar,       false): return .steadyBar
        case (.underline, true):  return .blinkUnderline
        case (.underline, false): return .steadyUnderline
        }
    }

    /// SwiftTerm.Color uses 16-bit channels (0..65535). 257 = 65535/255 maps
    /// 8-bit values directly without rounding loss.
    private func swiftTermColor(rgb: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red:   UInt16((rgb >> 16) & 0xFF) * 257,
            green: UInt16((rgb >>  8) & 0xFF) * 257,
            blue:  UInt16( rgb        & 0xFF) * 257
        )
    }

    private func uiColor(rgb: Int) -> UIColor {
        UIColor(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >>  8) & 0xFF) / 255,
            blue:  CGFloat( rgb        & 0xFF) / 255,
            alpha: 1
        )
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let onReady: () -> Void
        let onSend: (ArraySlice<UInt8>) -> Void
        let onResize: (Int, Int) -> Void
        let onTitle: (String) -> Void
        var onUserActivity: (() -> Void)?
        let onBell: (() -> Void)?
        var onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat, Bool, PaneId?) -> TerminalPrimaryScrollConsumption)?
        var onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)?
        var onScrollGestureActivity: ((Bool) -> Void)?
        var agentScrollBlockingActive: Bool
        var onAgentScrollBlocked: (() -> Void)?
        var mouseReportingImpliesAltScreen: Bool
        var suppressDirectColorQueryResponses: Bool
        var softwareModifierState: ModifierState?
        /// Needed to resolve an on-screen ⌘ chord against the user's keymap.
        var shortcutStore: ShortcutStore?
        let onHardwareKey: ((TesseraTerminalHardwareKey) -> Void)?
        var onTerminalScrolled: ((TerminalView) -> Void)?
        var onNativeScrollFrame: ((TerminalView, CGFloat) -> Void)?
        private var nativeScrollFrameObservation: NSKeyValueObservation?
        private var scrollRetentionID: String?
        var onScrollDiagnostic: ((String) -> Void)?
        /// OSC 7 forwarding — assigned by `makeUIView`/`updateUIView`
        /// (a `var` like `onPaneFocusTap`, so the memberwise-ish
        /// Coordinator init stays untouched).
        var onHostDirectory: ((String?) -> Void)?
        private var didReportReady = false
        private var scrollDiagnosticEventCount = 0
        private var desiredScrollOffsetY: CGFloat?
        private var scrollRestoreLogCount = 0

        /// §3.1 scroll dispatcher — three-state machine that decides
        /// whether a trackpad scroll turns into a scrollback adjustment,
        /// a terminal mouse wheel event, or a velocity-integrated arrow-key
        /// press. All the policy is in the dispatcher; this coordinator
        /// just feeds it events and routes its outputs.
        ///
        /// Thresholds tuned to match iTerm2 / Terminal.app default feel
        /// on macOS. A Magic Mouse wheel delivers ~3pt per notch via
        /// `UIPanGestureRecognizer` with `allowedScrollTypesMask = .all`,
        /// and the system-default scroll velocity is 3 lines per notch.
        /// So 1pt = 1 line = 1 arrow key:
        ///
        ///   - `pointsPerArrowKey = 1`          → 3pt notch → 3 arrow keys
        ///   - `mouseWheelThresholdPoints = 3`  → 3pt notch → 1 wheel
        ///     tick (vim interprets each tick as 3 lines by default, so
        ///     the visible result is still 3 lines per notch)
        ///
        /// The arrow-key and mouse-wheel modes therefore scroll at the
        /// same visible rate even though the encoding is different. The
        /// per-flush cap keeps a fast continuous fling from flooding the
        /// pty when deltas stack (a 30pt trackpad fling emits up to 8
        /// arrow keys per event, not 30).
        var scrollDispatcher = ScrollDispatcher(config: .init(
            pointsPerArrowKey: 1,
            mouseWheelThresholdPoints: 3,
            maxEventsPerFlush: 8
        ))

        // MARK: Scroll inertia (§3.1 smooth scrolling)
        //
        // Post-release glide for primary-screen scrollback only. Velocity
        // is tracked from live gesture deltas (raw points, pre-multiplier);
        // on release a CADisplayLink synthesizes per-frame deltas that flow
        // through the SAME `applyPrimaryScrollbackDelta` routing as gesture
        // events — so mosh overlay scrolling, history requests, and offset
        // retention behave identically during a glide. Alt-screen and
        // mouse-forwarding modes never glide: wheel ticks and arrow keys
        // stay discrete-semantic (the fingers-off stream would desync the
        // remote app's view).

        /// Toggled from AppearancePreferences.smoothScrollingEnabled via
        /// make/updateUIView. Turning it off mid-glide stops the glide.
        var smoothScrollingEnabled = true {
            didSet {
                if !smoothScrollingEnabled {
                    cancelScrollInertia(reason: "setting-off")
                }
            }
        }
        /// Glide-strength multiplier applied to the tracked release
        /// velocity (AppearancePreferences.smoothScrollingSpeed). Takes
        /// effect on the next fling; an active glide keeps its velocity.
        var smoothScrollingSpeed: Double = 0.5

        /// Mirror of `suppressFirstResponderReclaim`, tracked so focus
        /// transitions cancel a running glide. In a pane grid the user's
        /// focus tap lands on a SwiftUI overlay of the *other* pane — no
        /// gesture ever reaches this coordinator — but the flag flips for
        /// both panes on the next update pass. Without this, a glide keeps
        /// running (and keeps advancing the remembered scroll offset that
        /// deep-refresh restore re-asserts) on a pane the user has visibly
        /// left, which reads as the pane scrolling by itself.
        private var lastFocusSuppression: Bool?
        var inputAllowed: () -> Bool = { true }
        var keyboardHandoff: TerminalKeyboardHandoff?

        var permitsFirstResponderReclaim: Bool {
            eligibleForAutomaticKeyboardFocus
                && pendingKeyboardDismissal == nil
                && softwareModifierState?.suppressesSoftwareKeyboardReclaim != true
                && (!hasOtherTextResponder || keyboardHandoff?.isLive == true)
        }

        func reclaimFirstResponder(on view: TerminalView) {
            let handoff = keyboardHandoff?.isLive == true ? keyboardHandoff : nil
            if view.becomeFirstResponder() {
                handoff?.spend()
            }
        }

        private var eligibleForAutomaticKeyboardFocus: Bool {
            lastFocusSuppression == false && keyboardContextIsActive
        }

        private var keyboardContextIsActive: Bool {
            guard inputAllowed(),
                  UIApplication.shared.applicationState == .active,
                  let view = terminalView as? TesseraResponderAwareTerminalView,
                  view.sessionDrawingEnabled, !view.isHidden,
                  let window = view.window, window.isKeyWindow,
                  window.windowScene?.activationState == .foregroundActive else { return false }
            return true
        }

        private var hasOtherTextResponder: Bool {
            guard let view = terminalView, let window = view.window else { return false }
            func containsInput(_ candidate: UIView) -> Bool {
                guard !candidate.isHidden else { return false }
                if candidate !== view, candidate.isFirstResponder, candidate is UITextInput { return true }
                return candidate.subviews.contains(where: containsInput)
            }
            return containsInput(window)
        }

        private var softwareKeyboardVisible = false
        // Input can move to a newly mounted pane without another willShow.
        // Weak window keys preserve that presentation fact without keeping
        // scenes alive or sharing keyboard state between separate windows.
        private static let keyboardVisibilityByWindow = NSMapTable<UIWindow, NSNumber>(
            keyOptions: .weakMemory, valueOptions: .strongMemory)
        private var windowHasSoftwareKeyboard: Bool {
            guard let window = terminalView?.window else { return false }
            return Self.keyboardVisibilityByWindow.object(forKey: window)?.boolValue == true
                || window.keyboardLayoutGuide.layoutFrame.height > window.safeAreaInsets.bottom
        }
        private var keyboardDismissalGeneration = 0
        private var pendingKeyboardDismissal: Int?
        private var keyboardResigningForTransition = false
        private var expectsTransitionKeyboardHide = false

        private func cancelPendingKeyboardDismissal() {
            keyboardDismissalGeneration += 1
            pendingKeyboardDismissal = nil
        }

        private func settleKeyboardDismissal(_ generation: Int, keyboardWasHidden: Bool = false) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingKeyboardDismissal == generation else { return }
                // A UITextField takes ownership only after resign returns.
                // Let that transfer settle before interpreting system Hide.
                if self.keyboardContextIsActive, !self.hasOtherTextResponder,
                   keyboardWasHidden || self.terminalView?.isFirstResponder == false {
                    self.softwareModifierState?.noteSoftwareKeyboardDismissed()
                    let view = self.terminalView as? TesseraResponderAwareTerminalView
                    view?.noteKeyboardDiagnostic("software-keyboard-dismissed")
                }
                self.pendingKeyboardDismissal = nil
            }
        }

        func bindKeyboardFocus(to view: TesseraResponderAwareTerminalView) {
            if view.isFirstResponder, windowHasSoftwareKeyboard { softwareKeyboardVisible = true }
            // The deferred make/update reclaim can run before SwiftUI attaches
            // a newly mounted pane, and no further update is guaranteed while
            // a palette handoff is live. Retry under the same gate once the
            // view reaches a window.
            view.onDidMoveToWindow = { [weak self, weak view] in
                DispatchQueue.main.async {
                    guard let self, let view, !view.isFirstResponder,
                          self.permitsFirstResponderReclaim else { return }
                    self.reclaimFirstResponder(on: view)
                    self.installHardwareKeyPassthroughIfNeeded()
                }
            }
            view.allowsFirstResponderRequest = { [weak self] fromTerminalTap in
                guard let self else { return false }
                if fromTerminalTap {
                    // Commit intent before entering UIKit: reentrant focus
                    // requests in this same transaction must see the request,
                    // just as they do for the accessory's explicit Show action.
                    self.cancelPendingKeyboardDismissal()
                    self.softwareModifierState?.requestSoftwareKeyboardOnTerminalTap()
                    return true
                }
                // UIKit can ask an old responder to reactivate while another
                // text field opens. Only a recognized terminal tap (including
                // SwiftTerm's own tap handler) may override dismissed intent.
                return self.pendingKeyboardDismissal == nil
                    && self.softwareModifierState?.suppressesSoftwareKeyboardReclaim != true
            }
            view.onBecameFirstResponder = { [weak self, weak view] in
                guard let self else { return }
                self.cancelPendingKeyboardDismissal()
                if self.windowHasSoftwareKeyboard { self.softwareKeyboardVisible = true }
                self.softwareModifierState?.noteSoftwareKeyboardRequested(
                    resign: { [weak view] in
                        guard let view, view.isFirstResponder else { return false }
                        return view.resignFirstResponder()
                    },
                    become: { [weak self, weak view] in
                        self?.cancelPendingKeyboardDismissal()
                        guard let self, let view, self.inputAllowed(),
                              view.sessionDrawingEnabled, !view.isHidden,
                              view.window?.isKeyWindow == true else { return false }
                        return view.becomeFirstResponder()
                    }
                )
            }
            view.onWillResignFirstResponder = { [weak self] forTransition in
                guard let self else { return }
                self.keyboardResigningForTransition = forTransition
                if forTransition && self.softwareKeyboardVisible {
                    self.expectsTransitionKeyboardHide = true
                }
                self.cancelPendingKeyboardDismissal()
                // Seed from the window for surfaces mounted while another pane
                // already owned the keyboard (no new willShow is guaranteed).
                guard !forTransition, self.keyboardContextIsActive,
                      self.softwareKeyboardVisible || self.windowHasSoftwareKeyboard,
                      self.softwareModifierState?.suppressesSoftwareKeyboardReclaim == false else { return }
                // Synchronous reservation closes the race with already queued
                // SwiftUI reclaim work while UIKit is still resigning focus.
                self.pendingKeyboardDismissal = self.keyboardDismissalGeneration
            }
            view.onDidResignFirstResponder = { [weak self] accepted in
                guard let self else { return }
                self.keyboardResigningForTransition = false
                guard let generation = self.pendingKeyboardDismissal else { return }
                guard accepted else { self.cancelPendingKeyboardDismissal(); return }
                self.settleKeyboardDismissal(generation)
            }
        }

        /// Suspension dismisses terminal input without necessarily causing a
        /// subsequent SwiftUI update. Restore it explicitly on wake/reconnect,
        /// using the latest pane/modal/keyboard-dismissal policy. Never replace
        /// an input that the user is already editing elsewhere in the window.
        private func restoreKeyboardFocusAfterActivation() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.permitsFirstResponderReclaim,
                      let view = self.terminalView
                else {
                    (self.terminalView as? TesseraResponderAwareTerminalView)?.noteKeyboardDiagnostic(
                        "activation-skipped suppressed=\(self.lastFocusSuppression == true) dismissed=\(self.softwareModifierState?.suppressesSoftwareKeyboardReclaim == true) pending=\(self.pendingKeyboardDismissal != nil) app=\(UIApplication.shared.applicationState.rawValue) scene=\(self.terminalView?.window?.windowScene?.activationState.rawValue ?? -1)"
                    )
                    return
                }
                if !view.isFirstResponder {
                    (view as? TesseraResponderAwareTerminalView)?.noteKeyboardDiagnostic("activation-reclaim")
                    self.reclaimFirstResponder(on: view)
                }
                self.installHardwareKeyPassthroughIfNeeded()
            }
        }

        func noteFocusSuppression(_ suppressed: Bool) {
            guard lastFocusSuppression != suppressed else { return }
            let isTransition = lastFocusSuppression != nil
            lastFocusSuppression = suppressed
            if suppressed { cancelPendingKeyboardDismissal() }
            if isTransition {
                cancelScrollInertia(reason: "focus-change")
            }
        }
        private var scrollVelocityTracker = ScrollVelocityTracker()
        private var scrollInertia: ScrollInertiaDecay?
        private var inertiaDisplayLink: CADisplayLink?
        private var inertiaLastTargetTimestamp: CFTimeInterval = 0
        private var inertiaTickCount = 0
        /// True while the most recent nonzero primary-screen delta produced
        /// local visual scrolling (vs. semantic forwarding / bound clamp).
        /// Gates whether release may start a glide.
        private var lastPrimaryScrollWasLocal = false

        // Per-gesture cost probe (diagnostics only): UIKit coalesces scroll
        // events when the main thread can't drain them — visible as large
        // inter-event gaps with proportionally large deltas. Handler time
        // vs. gap time tells whether the stall is inside this handler or
        // elsewhere (SwiftUI invalidation, rendering, transport work).
        private var gestureCostEvents = 0
        private var gestureCostTotalMs: Double = 0
        private var gestureCostMaxMs: Double = 0
        private var gestureGapMaxMs: Double = 0
        private var gestureLastEventAt: CFTimeInterval = 0

        // Scroll-activity latch feeding `onScrollGestureActivity`: active
        // while a trackpad pan is tracking OR a synthetic glide is still
        // running. Kept out of any observable store — it flips at gesture
        // boundaries only and must not trigger SwiftUI invalidation.
        private var panGestureActive = false
        private var scrollActivityLatched = false

        private func updateScrollActivity() {
            let active = panGestureActive || inertiaDisplayLink != nil
            guard active != scrollActivityLatched else { return }
            scrollActivityLatched = active
            onScrollGestureActivity?(active)
        }

        // Display link held for the duration of an active pan gesture.
        // It is the drain driver for the commit-free event path: gesture
        // events only queue points, and this link applies them once per
        // frame (`drainPendingGestureScroll`). The tick counters feed the
        // gesture-cost diagnostic — frames≈events with ~8ms gaps is the
        // warm regime, frames≈0 means the OS throttled the update cycle
        // for the whole gesture (the cold regime that delayed history
        // application used to exacerbate).
        private var gestureFrameLink: CADisplayLink?
        private var gestureFrameTicks = 0
        private var gestureFrameLastTimestamp: CFTimeInterval = 0
        private var gestureFrameGapMaxMs: Double = 0
        private var gestureFrameDurationMs: Double = 0

        /// Local scrollback points accumulated from gesture events and
        /// applied on gesture display-link ticks (or gesture end),
        /// never per event. Round-3 device logs showed the regime this
        /// avoids: on a cold (idle-refresh) screen, per-event work that
        /// commits blocks the main thread to the panel's 24Hz — event
        /// delivery, MainActor ingest, and display links all starve
        /// until the fingers lift. With events commit-free, the thread
        /// stays available, ingest keeps rendering mid-gesture, and the
        /// pipeline self-ramps to 120Hz (observed in the same logs once
        /// anything was presenting). Semantic actions (wheel forwards,
        /// arrow-key bytes) stay per-event — they don't commit locally.
        private var pendingGestureScrollPoints: Double = 0
        private var gestureUsesLocalTouchGain = false
        var primaryScrollPaneAtLocation: ((TerminalView, CGPoint) -> PaneId?)?
        private var primaryScrollTarget = TmuxScrollGestureTarget()
        var primaryTouchScrollIsLocal: (() -> Bool?)?
        var primaryTouchScrollIsLocalForPane: ((PaneId?) -> Bool?)?
        var remotePaneReportsMouse: (() -> Bool)?
        var touchPansTakePointerRoute: (() -> Bool)?
        var remoteHistoryRevealed: (() -> Bool)?
        private var lastGestureDrainAt: CFTimeInterval = 0

        /// Weak ref so the scroll handler can read terminal state
        /// (`isCurrentBufferAlternate`, `mouseMode`) and call scroll
        /// methods (`scrollUp`/`scrollDown`) without creating a retain
        /// cycle with the coordinator.
        weak var terminalView: TerminalView?

        /// Mouse-click tap gesture, stored so the delegate can
        /// distinguish it from other recognizers.
        weak var mouseTapGesture: UITapGestureRecognizer?

        /// Our trackpad scroll pan, stored so the inertia tick's
        /// concurrent-pan poll can exclude it.
        weak var semanticScrollGesture: UIPanGestureRecognizer?
        weak var discreteScrollGesture: UIPanGestureRecognizer?

        /// Dormant unless an exact hook-proven agent is `.working`. Stored so
        /// SwiftUI updates can enable/disable it without rebuilding the surface.
        weak var agentScrollBlockGesture: UIPanGestureRecognizer?
        private var agentScrollBlockNotified = false
        /// A finger pan the blocker let pass (horizontal-dominant) that
        /// began on the semantic route while an agent works.
        private var semanticTouchBlockedByAgent = false

        /// Mosh tap-to-focus gesture (split windows only) — a separate
        /// recognizer from `mouseTapGesture`, stored so the delegate can gate it.
        weak var paneFocusTapGesture: UITapGestureRecognizer?

        /// Mosh tap-to-focus: maps a tap → pane and selects it over the side
        /// channel. Set by `TerminalSurfaceBound.update`; nil on every other
        /// surface. `paneFocusTapEnabled` mirrors "the active mosh window is
        /// split" so the focus-tap recognizer fires even with mouse reporting off.
        var onPaneFocusTap: ((CGPoint, CGSize) -> Bool)?
        var paneFocusTapEnabled: Bool = false


        /// Container weak ref kept for the hardware-key-passthrough wiring
        /// to find a stable reference point.
        weak var container: TesseraTerminalContainer?

        private var resizeCoalescer = TerminalResizeCoalescer()

        private var keyboardConnectObserver: NSObjectProtocol?
        private var resignActiveObserver: NSObjectProtocol?
        private var becomeActiveObserver: NSObjectProtocol?
        private var keyboardShowObserver: NSObjectProtocol?
        private var keyboardHideObserver: NSObjectProtocol?
        private var keyboardDidHideObserver: NSObjectProtocol?
        private weak var hardwareKeyboard: GCKeyboard?
        var naturalTextEditingEnabled = true
        private var pendingInputBytes: [UInt8] = []

        init(
            onReady: @escaping () -> Void,
            onSend: @escaping (ArraySlice<UInt8>) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            onTitle: @escaping (String) -> Void,
            onUserActivity: (() -> Void)?,
            onBell: (() -> Void)?,
            onPrimaryScrollbackDelta: ((TerminalView, Double, CGFloat, CGFloat, Bool, PaneId?) -> TerminalPrimaryScrollConsumption)?,
            onPrimaryScrollbackUnderflow: ((TerminalView, Double, CGFloat, CGFloat) -> Void)?,
            agentScrollBlockingActive: Bool,
            onAgentScrollBlocked: (() -> Void)?,
            mouseReportingImpliesAltScreen: Bool,
            suppressDirectColorQueryResponses: Bool,
            softwareModifierState: ModifierState?,
            onHardwareKey: ((TesseraTerminalHardwareKey) -> Void)?,
            onTerminalScrolled: ((TerminalView) -> Void)?,
            scrollRetentionID: String?,
            onScrollDiagnostic: ((String) -> Void)?
        ) {
            self.onReady = onReady
            self.onSend = onSend
            self.onResize = onResize
            self.onTitle = onTitle
            self.onUserActivity = onUserActivity
            self.onBell = onBell
            self.onPrimaryScrollbackDelta = onPrimaryScrollbackDelta
            self.onPrimaryScrollbackUnderflow = onPrimaryScrollbackUnderflow
            self.agentScrollBlockingActive = agentScrollBlockingActive
            self.onAgentScrollBlocked = onAgentScrollBlocked
            self.mouseReportingImpliesAltScreen = mouseReportingImpliesAltScreen
            self.suppressDirectColorQueryResponses = suppressDirectColorQueryResponses
            self.softwareModifierState = softwareModifierState
            self.onHardwareKey = onHardwareKey
            self.onTerminalScrolled = onTerminalScrolled
            self.scrollRetentionID = scrollRetentionID
            self.onScrollDiagnostic = onScrollDiagnostic
            super.init()

            // Visibility is shared by responders in a window. Record it even
            // while another pane/text field owns input, but classify dismissal
            // only for this visible, active terminal's own resignation.
            keyboardShowObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                (self.terminalView as? TesseraResponderAwareTerminalView)?.noteKeyboardDiagnostic("keyboard-will-show frame=\(String(describing: frame))")
                let safeBottom = self.terminalView?.window?.safeAreaInsets.bottom ?? 0
                self.softwareKeyboardVisible = frame.map { $0.height > safeBottom } ?? true
                if let window = self.terminalView?.window, window.isKeyWindow {
                    Self.keyboardVisibilityByWindow.setObject(NSNumber(value: self.softwareKeyboardVisible), forKey: window)
                }
                // Rotation, input-mode changes and responder transfers can
                // hide then immediately re-show the same keyboard. A later
                // show supersedes that provisional dismissal, never user intent.
                self.cancelPendingKeyboardDismissal()
                self.expectsTransitionKeyboardHide = false
            }
            keyboardHideObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let wasVisible = self.softwareKeyboardVisible
                (self.terminalView as? TesseraResponderAwareTerminalView)?.noteKeyboardDiagnostic("keyboard-will-hide visible=\(wasVisible) transition=\(self.expectsTransitionKeyboardHide)")
                self.softwareKeyboardVisible = false
                if let window = self.terminalView?.window {
                    Self.keyboardVisibilityByWindow.removeObject(forKey: window)
                }
                let forTransition = self.expectsTransitionKeyboardHide
                self.expectsTransitionKeyboardHide = false
                guard wasVisible, self.terminalView?.isFirstResponder == true,
                      !forTransition, !self.keyboardResigningForTransition, self.keyboardContextIsActive,
                      self.softwareModifierState?.suppressesSoftwareKeyboardReclaim == false else { return }
                self.cancelPendingKeyboardDismissal()
                self.pendingKeyboardDismissal = self.keyboardDismissalGeneration
                self.settleKeyboardDismissal(self.keyboardDismissalGeneration, keyboardWasHidden: true)
            }
            keyboardDidHideObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.keyboardContextIsActive,
                          self.softwareModifierState?.suppressesSoftwareKeyboardReclaim == true,
                          self.terminalView?.isFirstResponder == true else { return }
                    // Native Hide can retain first responder. Release it only
                    // after UIKit finishes retracting input, not in the middle
                    // of its presentation transition.
                    (self.terminalView as? TesseraResponderAwareTerminalView)?.resignFirstResponderForTransition()
                }
            }

            // A glide must not survive suspension: CADisplayLink freezes
            // while suspended but stays valid, so without this an hours-old
            // fling would visibly resume on foreground — and the link's
            // target retention would keep a dismantled surface's
            // coordinator alive until its first foreground tick.
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelPendingKeyboardDismissal()
                self?.cancelScrollInertia(reason: "app-inactive")
            }
            becomeActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.restoreKeyboardFocusAfterActivation()
            }
        }

        deinit {
            if let obs = keyboardShowObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = keyboardHideObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = keyboardDidHideObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = keyboardConnectObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = resignActiveObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = becomeActiveObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func setScrollRetentionID(_ id: String?) {
            guard scrollRetentionID != id else { return }
            scrollRetentionID = id
            // Pane/window switch on the shared mosh surface — a glide from
            // the previous pane must not carry into the new one.
            cancelScrollInertia(reason: "identity-change")
            clearDesiredScrollOffset(reason: "identity-change", view: terminalView)
        }

        func setAgentScrollBlockingActive(_ active: Bool) {
            guard agentScrollBlockingActive != active else { return }
            agentScrollBlockingActive = active
            agentScrollBlockGesture?.isEnabled = active
            guard active else {
                agentScrollBlockNotified = false
                return
            }

            // Stop every continuation of an already-started scroll at the
            // lifecycle transition. Future physical gestures are consumed by
            // the blocker recognizer; these resets cover native deceleration,
            // semantic-frame backlog, and Tessera's synthetic inertia.
            cancelScrollInertia(reason: "agent-working")
            pendingGestureScrollPoints = 0
            scrollVelocityTracker.reset()
            lastPrimaryScrollWasLocal = false
            for gesture in [semanticScrollGesture, discreteScrollGesture].compactMap({ $0 }) where gesture.state != .possible {
                gesture.isEnabled = false
                gesture.isEnabled = true
            }
            if let view = terminalView {
                if view.panGestureRecognizer.state != .possible {
                    view.panGestureRecognizer.isEnabled = false
                    view.panGestureRecognizer.isEnabled = true
                }
                view.setContentOffset(view.contentOffset, animated: false)
            }
        }

        // MARK: - Hardware keyboard / accessory bar (§3.5 R3.5.3)

        /// Subscribe to GCKeyboard connect/disconnect so the hardware-key
        /// passthrough re-binds when a Magic Keyboard is plugged in mid-
        /// session. The accessory bar itself is now a SwiftUI sibling and
        /// no longer cares about hardware keyboard presence.
        func observeHardwareKeyboard() {
            keyboardConnectObserver = NotificationCenter.default.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelPendingKeyboardDismissal()
                // Attachment can itself retract software input. A subsequent
                // willShow clears this exemption, so manually shown input can
                // still be deliberately dismissed with hardware attached.
                self?.expectsTransitionKeyboardHide = self?.softwareKeyboardVisible == true
                self?.installHardwareKeyPassthroughIfNeeded()
                self?.restoreKeyboardFocusAfterActivation()
            }
            installHardwareKeyPassthroughIfNeeded()
        }

        /// SwiftTerm's PageUp/PageDown handling can consume hardware keys as
        /// local scrollback when its local terminal state says "normal buffer".
        /// In mosh, that state can lag the remote TUI, so use GCKeyboard to
        /// catch raw PageUp/PageDown events and send VT sequences ourselves
        /// only when SwiftTerm would not already send them.
        func installHardwareKeyPassthroughIfNeeded() {
            guard onHardwareKey != nil,
                  let keyboard = GCKeyboard.coalesced,
                  let input = keyboard.keyboardInput
            else { return }

            if hardwareKeyboard === keyboard {
                return
            }

            hardwareKeyboard = keyboard
            input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
                DispatchQueue.main.async {
                    self?.handleHardwareKeyCode(keyCode, pressed: pressed)
                }
            }
        }

        private func handleHardwareKeyCode(_ keyCode: GCKeyCode, pressed: Bool) {
            guard pressed,
                  let key = terminalHardwareKey(for: keyCode),
                  let view = terminalView,
                  view.isFirstResponder,
                  let onHardwareKey
            else { return }

            if agentScrollBlockingActive {
                onUserActivity?()
                onAgentScrollBlocked?()
                emitScrollDiagnostic(
                    "agent-scroll-blocked input=hardware-\(String(describing: key))"
                )
                return
            }

            let terminal = view.getTerminal()
            if terminal.applicationCursor || terminal.isCurrentBufferAlternate {
                MoshDiagnostics.log(
                    "mosh hardware key \(String(describing: key)) left to SwiftTerm appCursor=\(terminal.applicationCursor) alt=\(terminal.isCurrentBufferAlternate)"
                )
                return
            }

            MoshDiagnostics.log(
                "mosh hardware key \(String(describing: key)) via GCKeyboard appCursor=\(terminal.applicationCursor) alt=\(terminal.isCurrentBufferAlternate)"
            )
            onUserActivity?()
            onHardwareKey(key)
        }

        private func terminalHardwareKey(for keyCode: GCKeyCode) -> TesseraTerminalHardwareKey? {
            switch keyCode {
            case .pageUp:
                return .pageUp
            case .pageDown:
                return .pageDown
            default:
                return nil
            }
        }

        private var hardwareCommandKeyActive: Bool {
            guard let input = hardwareKeyboard?.keyboardInput ?? GCKeyboard.coalesced?.keyboardInput else {
                return false
            }
            return input.button(forKeyCode: .leftGUI)?.isPressed == true
                || input.button(forKeyCode: .rightGUI)?.isPressed == true
        }

        // MARK: - TerminalViewDelegate

        func scrollbackTrimmed(source: TerminalView, points: Double) {
            if let desiredScrollOffsetY {
                self.desiredScrollOffsetY = max(0, desiredScrollOffsetY - CGFloat(points))
            }
        }

        func scrolled(source: TerminalView, position: Double) {
            restoreDesiredScrollOffsetIfNeeded(in: source, position: position)
            onTerminalScrolled?(source)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            onTitle(title)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Reflow rebases every offset; a glide across it would land
            // somewhere meaningless.
            cancelScrollInertia(reason: "resize")
            emitScrollDiagnostic(
                "size-changed cols=\(newCols) rows=\(newRows) bounds=\(Self.format(source.bounds.height)) content=\(Self.format(source.contentSize.height))"
            )
            if !didReportReady, newCols > 0, newRows > 0 {
                didReportReady = true
                onReady()
            }
            deliverSizeChange(cols: newCols, rows: newRows)
        }

        /// The terminal view settles layout before changing its emulator grid.
        /// Publish that committed size immediately so local and remote geometry
        /// cannot diverge for another debounce window. Keep duplicate reports
        /// (for example font/layout callbacks) off the wire.
        private func deliverSizeChange(cols: Int, rows: Int) {
            let size = TerminalResizeCoalescer.Size(cols: cols, rows: rows)
            switch resizeCoalescer.note(size) {
            case .drop:
                emitScrollDiagnostic("resize-coalesced cols=\(cols) rows=\(rows)")
            case .send, .wait:
                _ = resizeCoalescer.settle(size)
                emitScrollDiagnostic("resize-sent cols=\(cols) rows=\(rows) why=committed-layout")
                onResize(cols, rows)
            }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            onHostDirectory?(directory)
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onUserActivity?()
            let colorResponse = TerminalOSCColorResponseRewriter.rewriteColorQueryResponse(
                data,
                defaultForegroundRGB: container?.terminalDefaultForegroundRGB ?? 0xD4D4D4,
                defaultBackgroundRGB: container?.terminalDefaultBackgroundRGB ?? 0x000000
            )
            if colorResponse.isColorQueryResponse {
                if !pendingInputBytes.isEmpty {
                    onSend(pendingInputBytes[...])
                    pendingInputBytes.removeAll(keepingCapacity: true)
                }
                if suppressDirectColorQueryResponses {
                    return
                }
                onSend(colorResponse.bytes[...])
                return
            }

            // Real user input (keys, forwarded mouse) while gliding: stop
            // the glide — terminals snap attention back to the live cursor
            // on input, and mosh invalidates its capture overlay. Color
            // query responses returned above; other terminal auto-replies
            // (CPR, DA, DSR, window reports, DCS) carry no user intent and
            // must not kill a glide just because remote output queried us.
            if !Self.isTerminalAutoReply(data) {
                cancelScrollInertia(reason: "user-input")
                // Typing also snaps the viewport to the live prompt (the
                // iTerm2/Terminal convention) and drops the retained scroll
                // offset — otherwise the offset-restore machinery pins the
                // view off-bottom while the command's output streams and
                // the prompt ends up hidden below the fold. Forwarded SGR
                // mouse reports are pointer events, not typing — a click
                // must not yank the viewport.
                if !Self.isMouseReport(data) {
                    snapToBottomForUserInput()
                }
            }

            let normalized = TerminalInputNormalizer.normalizeInput(
                data,
                pending: &pendingInputBytes,
                naturalTextEditingEnabled: naturalTextEditingEnabled,
                commandKeyActive: hardwareCommandKeyActive
            )
            if !normalized.isEmpty {
                // ⌘ armed on the accessory bar makes the next typed key an app
                // shortcut rather than terminal input — the only way to reach
                // ⌘K / ⌘⇧E on a device with no hardware keyboard. Checked
                // before the wire-modifier path because ⌘ has no encoding.
                if !Self.isTerminalAutoReply(data),
                   !Self.isMouseReport(data),
                   let softwareModifierState,
                   softwareModifierState.armed.cmd,
                   let store = shortcutStore,
                   softwareModifierState.consumeCommandChord(normalized, store: store) {
                    return
                }
                let outgoing: [UInt8]
                if !Self.isTerminalAutoReply(data),
                   !Self.isMouseReport(data),
                   let softwareModifierState,
                   softwareModifierState.armed.isAny {
                    outgoing = softwareModifierState
                        .encodeSoftwareKeyboardPayload(normalized)
                } else {
                    outgoing = normalized
                }
                onSend(outgoing[...])
            }
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) { onBell?() }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        // MARK: - Trackpad scroll handling (§3.1)

        private func emitScrollDiagnostic(_ message: String) {
            onScrollDiagnostic?(message)
        }

        private func rememberDesiredScrollOffset(_ offsetY: CGFloat, maxOffsetY: CGFloat) {
            if maxOffsetY - offsetY <= 1.0 {
                clearDesiredScrollOffset(reason: "bottom", view: terminalView)
                return
            }
            desiredScrollOffsetY = min(max(0, offsetY), maxOffsetY)
        }

        private func clearDesiredScrollOffset(reason: String, view: TerminalView?) {
            guard desiredScrollOffsetY != nil else { return }
            let position = view.map { scrollOffsetDescription(for: $0) } ?? "nil"
            emitScrollDiagnostic("scroll-retention-clear reason=\(reason) position=\(position)")
            desiredScrollOffsetY = nil
        }

        private func restoreDesiredScrollOffsetIfNeeded(in view: TerminalView, position: Double) {
            guard let desiredScrollOffsetY else { return }
            let terminal = view.getTerminal()
            if terminal.isCurrentBufferAlternate {
                clearDesiredScrollOffset(reason: "alt-screen", view: view)
                return
            }

            let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            let offsetY = min(max(0, desiredScrollOffsetY), maxOffsetY)
            if maxOffsetY - offsetY <= 1.0 {
                clearDesiredScrollOffset(reason: "bottom", view: view)
                return
            }
            self.desiredScrollOffsetY = offsetY
            guard abs(view.contentOffset.y - offsetY) > 0.5 else { return }

            if scrollRestoreLogCount < 40 {
                scrollRestoreLogCount += 1
                emitScrollDiagnostic(
                    "scroll-offset-restore from=\(Self.format(view.contentOffset.y)) to=\(Self.format(offsetY)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height)) position=\(String(format: "%.3f", position))"
                )
            }
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: offsetY)
        }

        private func scrollOffsetDescription(for view: TerminalView) -> String {
            "off=\(Self.format(view.contentOffset.y))/\(Self.format(max(0, view.contentSize.height - view.bounds.height))) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
        }

        private static func format(_ value: CGFloat) -> String {
            String(format: "%.1f", Double(value))
        }

        private static func actionDescription(_ actions: [ScrollDispatcher.Action]) -> String {
            guard !actions.isEmpty else { return "none" }
            return actions.map { action in
                switch action {
                case .scrollbackDelta(let pointsY):
                    return "scrollback(\(String(format: "%.1f", pointsY)))"
                case .mouseWheel(let buttonFlags, _, _, let repeatCount):
                    return "wheel(button=\(buttonFlags),count=\(repeatCount))"
                case .writeBytes(let bytes):
                    return "writeBytes(\(bytes.count))"
                }
            }.joined(separator: "+")
        }

        @objc func handleSemanticScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = terminalView else { return }
            let handlerStart = CACurrentMediaTime()
            if recognizer.state == .began {
                primaryScrollTarget.begin(paneID: primaryScrollPaneAtGestureStart(recognizer, in: view))
                gestureCostEvents = 0
                gestureCostTotalMs = 0
                gestureCostMaxMs = 0
                gestureGapMaxMs = 0
                panGestureActive = true
                updateScrollActivity()
                startGestureFrameDrainLink()
            } else if gestureLastEventAt > 0 {
                gestureGapMaxMs = max(
                    gestureGapMaxMs, (handlerStart - gestureLastEventAt) * 1000
                )
            }
            gestureLastEventAt = handlerStart
            defer {
                let elapsedMs = (CACurrentMediaTime() - handlerStart) * 1000
                gestureCostEvents += 1
                gestureCostTotalMs += elapsedMs
                gestureCostMaxMs = max(gestureCostMaxMs, elapsedMs)
                if recognizer.state == .ended || recognizer.state == .cancelled {
                    if gestureCostEvents > 1 {
                        emitScrollDiagnostic(
                            "gesture-cost events=\(gestureCostEvents) handlerAvgMs=\(String(format: "%.2f", gestureCostTotalMs / Double(gestureCostEvents))) handlerMaxMs=\(String(format: "%.2f", gestureCostMaxMs)) gapMaxMs=\(String(format: "%.1f", gestureGapMaxMs)) frames=\(gestureFrameTicks) frameGapMaxMs=\(String(format: "%.1f", gestureFrameGapMaxMs)) frameMs=\(String(format: "%.1f", gestureFrameDurationMs))"
                        )
                        gestureLastEventAt = 0
                    }
                    stopGestureFrameDrainLink()
                    // Runs after the body, so a glide launched at .ended
                    // keeps the activity latch up until the glide stops.
                    panGestureActive = false
                    updateScrollActivity()
                }
            }
            // The blocker takes vertical-dominant finger pans only, but a
            // diagonal one still has a vertical component that this route
            // (mosh+tmux, primary shells) would turn into history motion.
            // Block it the way the trackpad's is blocked.
            if recognizer.state == .began {
                semanticTouchBlockedByAgent = agentScrollBlockingActive && recognizer.numberOfTouches > 0
                if semanticTouchBlockedByAgent {
                    onUserActivity?()
                    onAgentScrollBlocked?()
                    emitScrollDiagnostic("agent-scroll-blocked input=touch-diagonal")
                }
            }
            if semanticTouchBlockedByAgent {
                recognizer.setTranslation(.zero, in: view)
                if recognizer.state != .began, recognizer.state != .changed {
                    semanticTouchBlockedByAgent = false
                }
                return
            }
            onUserActivity?()
            scrollDiagnosticEventCount += 1
            let diagnosticEvent = scrollDiagnosticEventCount

            let translation = recognizer.translation(in: view)
            // Reset to zero so the next callback delivers an incremental
            // delta rather than cumulative-from-gesture-start.
            recognizer.setTranslation(.zero, in: view)

            let terminal = view.getTerminal()
            let mouseMode = terminal.mouseMode
            let isAltScreen = TerminalScrollRouting.isAltScreen(
                bufferIsAlternate: terminal.isCurrentBufferAlternate,
                mouseReporting: mouseMode != .off,
                mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen
            )
            let mouseReporting: ScrollDispatcher.MouseReporting =
                (mouseMode != .off) ? .vt200OrLater : .off
            let state = ScrollDispatcher.TerminalState(
                isAltScreen: terminal.isCurrentBufferAlternate,
                mouseReporting: mouseReporting,
                mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen
            )

            let phase: ScrollDispatcher.ScrollEvent.Phase
            switch recognizer.state {
            case .began: phase = .began
            case .changed: phase = .changed
            case .ended: phase = .ended
            case .cancelled, .failed: phase = .cancelled
            default: phase = .changed
            }

            // A fresh physical gesture always takes over from a glide.
            switch phase {
            case .began:
                gestureUsesLocalTouchGain = recognizer.numberOfTouches > 0
                    && isPrimaryTouchLocal(in: view, paneID: primaryScrollTarget.paneID)
                emitScrollDiagnostic("scroll-source kind=\(recognizer.numberOfTouches > 0 ? "touch" : recognizer === discreteScrollGesture ? "wheel" : "continuous")")
                cancelScrollInertia(reason: "new-gesture")
                scrollVelocityTracker.reset()
                lastPrimaryScrollWasLocal = false
                pendingGestureScrollPoints = 0
                lastGestureDrainAt = handlerStart
            case .changed:
                if inertiaDisplayLink != nil {
                    cancelScrollInertia(reason: "new-gesture")
                }
                scrollVelocityTracker.record(
                    deltaY: Double(translation.y),
                    timestamp: CACurrentMediaTime()
                )
            case .cancelled:
                scrollVelocityTracker.reset()
                lastPrimaryScrollWasLocal = false
                // Another recognizer took the touches — applying the
                // queued remainder would fight it over contentOffset.
                pendingGestureScrollPoints = 0
            case .ended:
                break
            }

            // For wheel events, use center of terminal. Unlike clicks,
            // wheel scroll position rarely matters to apps, and keeping
            // the synthetic event near the middle avoids edge-triggered
            // UI behavior in TUIs.
            let cols = terminal.cols
            let rows = terminal.rows
            let col = max(1, (cols + 1) / 2)
            let row = max(1, (rows + 1) / 2)

            let event = ScrollDispatcher.ScrollEvent(
                deltaY: Double(translation.y),
                cursorColumn: col,
                cursorRow: row,
                phase: phase
            )

            let actions = scrollDispatcher.handle(event: event, terminal: state)
            if actions.isEmpty {
                emitScrollDiagnostic(
                    "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=none before=\(scrollOffsetDescription(for: view))"
                )
            }

            for action in actions {
                switch action {
                case .scrollbackDelta(let pointsY):
                    // Shared history placement applies the pointer's 3x gain.
                    // Finger content must instead track the finger 1:1.
                    pendingGestureScrollPoints += gestureUsesLocalTouchGain ? pointsY / 3 : pointsY
                    emitScrollDiagnostic(
                        "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) queued pending=\(String(format: "%.1f", pendingGestureScrollPoints))"
                    )
                    // Safety valve: if display-link ticks aren't coming
                    // (the starved regime this coalescing is meant to
                    // break out of), don't hold scroll output hostage —
                    // apply inline at ≥20Hz so the worst case matches
                    // the old per-event behavior, not a frozen screen.
                    if handlerStart - lastGestureDrainAt > 0.05 {
                        drainPendingGestureScroll(reason: "stall-fallback")
                    }
                case .mouseWheel(let buttonFlags, let cursorColumn, let cursorRow, let repeatCount):
                    lastPrimaryScrollWasLocal = false
                    clearDesiredScrollOffset(reason: "mouse-wheel", view: view)
                    let x = max(0, cursorColumn - 1)
                    let y = max(0, cursorRow - 1)
                    for _ in 0..<repeatCount {
                        terminal.sendEvent(buttonFlags: buttonFlags, x: x, y: y)
                    }
                    emitScrollDiagnostic(
                        "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) mouse-wheel button=\(buttonFlags) count=\(repeatCount) at=\(cursorColumn),\(cursorRow) position=\(scrollOffsetDescription(for: view))"
                    )
                case .writeBytes(let bytes):
                    lastPrimaryScrollWasLocal = false
                    clearDesiredScrollOffset(reason: "write-bytes", view: view)
                    onSend(ArraySlice(bytes))
                    emitScrollDiagnostic(
                        "event=\(diagnosticEvent) phase=\(phase) delta=\(Self.format(translation.y)) termAlt=\(terminal.isCurrentBufferAlternate) stateAlt=\(isAltScreen) mouse=\(mouseMode) actions=\(Self.actionDescription(actions)) write-bytes count=\(bytes.count) position=\(scrollOffsetDescription(for: view))"
                    )
                }
            }

            if phase == .ended {
                drainPendingGestureScroll(reason: "gesture-end")
                if recognizer === semanticScrollGesture {
                    maybeStartScrollInertia(view: view, isAltScreen: isAltScreen,
                        reportedVelocity: Double(recognizer.velocity(in: view).y)
                            / (gestureUsesLocalTouchGain ? 3 : 1))
                }
                scrollVelocityTracker.reset()
            }
        }

        /// Apply the scrollback points queued since the last display
        /// frame. Runs on gesture display-link ticks and at gesture end
        /// — the only two places local scroll output is committed.
        private func drainPendingGestureScroll(reason: String) {
            lastGestureDrainAt = CACurrentMediaTime()
            let points = pendingGestureScrollPoints
            guard points != 0, let view = terminalView else { return }
            pendingGestureScrollPoints = 0
            let localScroll = applyPrimaryScrollbackDelta(
                view: view,
                pointsY: points,
                isInertial: false,
                diagnosticPrefix: "gesture-frame-drain reason=\(reason)"
            )
            if abs(points) > 0.01 {
                lastPrimaryScrollWasLocal = localScroll
            }
        }

        // MARK: - Primary scrollback application (shared gesture + inertia)

        /// Apply one primary-screen scrollback delta — from a live gesture
        /// event or a synthetic inertia frame. Returns true when the delta
        /// produced (or a pending fetch will produce) local visual
        /// scrolling, i.e. inertia may start or continue; false on semantic
        /// consumption or a hard bound.
        @discardableResult
        func applyPrimaryScrollbackDelta(
            view: TerminalView,
            pointsY: Double,
            isInertial: Bool,
            diagnosticPrefix: String
        ) -> Bool {
            // SwiftTerm's `TerminalView` is a UIScrollView subclass on iOS
            // and the Metal renderer reads `contentOffset.y` (not `yDisp`)
            // to decide which rows to draw. Its public `scrollUp(lines:)`
            // API ends by calling `updateScroller`, which snaps
            // contentOffset back to the bottom — so that API is broken for
            // scrollback. Instead we write `contentOffset.y` directly.
            //
            // Note SwiftTerm on iOS scrolls in continuous pixel units, not
            // line-snapped like iTerm2 on macOS — you can briefly see half
            // a row at the top of the view mid-scroll. Line-snap would
            // require intercepting Metal's `firstRow` computation and is
            // out of scope.
            //
            // 3× multiplier: a raw 1:1 pass-through ended up too slow on
            // iPad (Safari-style natural scroll feels brisker than a mouse
            // wheel on a desktop by reflex). Each 3pt wheel notch now moves
            // 9pt of content, five events per click ≈ 45pt ≈ 3 lines —
            // matching iTerm2 default feel.
            let beforeY = view.contentOffset.y
            let newY = beforeY - CGFloat(pointsY) * 3
            let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            let consumption = onPrimaryScrollbackDelta?(view, pointsY, newY, maxOffsetY, isInertial, primaryScrollTarget.paneID)
                ?? .notConsumed
            switch consumption {
            case .consumedLocalScroll, .consumedCancelInertia:
                clearDesiredScrollOffset(reason: "primary-consumed", view: view)
                if !diagnosticPrefix.isEmpty {
                    emitScrollDiagnostic(
                        "\(diagnosticPrefix) primary-consumed local=\(consumption == .consumedLocalScroll) points=\(String(format: "%.1f", pointsY)) before=\(Self.format(beforeY)) proposed=\(Self.format(newY)) after=\(Self.format(view.contentOffset.y)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
                    )
                }
                return consumption == .consumedLocalScroll
            case .notConsumed:
                break
            }
            let targetY = min(max(0, newY), maxOffsetY)
            view.contentOffset = CGPoint(
                x: view.contentOffset.x,
                y: targetY
            )
            rememberDesiredScrollOffset(targetY, maxOffsetY: maxOffsetY)
            if !diagnosticPrefix.isEmpty {
                emitScrollDiagnostic(
                    "\(diagnosticPrefix) primary-write points=\(String(format: "%.1f", pointsY)) before=\(Self.format(beforeY)) proposed=\(Self.format(newY)) after=\(Self.format(view.contentOffset.y)) max=\(Self.format(maxOffsetY)) content=\(Self.format(view.contentSize.height)) bounds=\(Self.format(view.bounds.height))"
                )
            }
            if pointsY > 0 {
                onPrimaryScrollbackUnderflow?(
                    view,
                    pointsY,
                    newY,
                    maxOffsetY
                )
            }
            // Direct contentOffset writes do not reliably invoke
            // TerminalViewDelegate.scrolled. Notify the host after the shared
            // retention state has been updated so semantic consumers (notably
            // a mosh history reader returning to its live tail) observe the
            // exact same committed position as native UIScrollView motion.
            onTerminalScrolled?(view)
            // A clamped proposal hit the actual loaded boundary. Semantic
            // history consumers return earlier while a replacement page is
            // pending, so its temporary empty range cannot stop the glide.
            return abs(targetY - newY) < 0.5
        }

        // MARK: - Scroll inertia driver

        private func maybeStartScrollInertia(view: TerminalView, isAltScreen: Bool, reportedVelocity: Double) {
            guard smoothScrollingEnabled,
                  !isAltScreen,
                  lastPrimaryScrollWasLocal,
                  let velocity = scrollVelocityTracker.releaseVelocity(at: CACurrentMediaTime(), reportedVelocity: reportedVelocity, knownContinuousInput: true)
            else { return }
            // Scale by the user's glide-speed preference. At the slow end
            // a soft flick can land under the decay's stop threshold —
            // nothing worth animating, skip the launch entirely.
            let inertia = ScrollInertiaDecay(velocity: velocity * (gestureUsesLocalTouchGain ? 1 : smoothScrollingSpeed))
            guard !inertia.isFinished else { return }
            scrollInertia = inertia
            inertiaTickCount = 0
            inertiaLastTargetTimestamp = 0
            if inertiaDisplayLink == nil {
                let link = CADisplayLink(
                    target: self,
                    selector: #selector(handleInertiaTick(_:))
                )
                // Glide at the panel's native cadence on ProMotion iPads.
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60, maximum: 120, preferred: 120
                )
                link.add(to: .main, forMode: .common)
                inertiaDisplayLink = link
            }
            updateScrollActivity()
            emitScrollDiagnostic(
                "inertia-start velocity=\(String(format: "%.1f", velocity))"
            )
        }

        @objc private func handleInertiaTick(_ link: CADisplayLink) {
            guard var inertia = scrollInertia,
                  let view = terminalView,
                  view.window != nil
            else {
                cancelScrollInertia(reason: "view-detached")
                return
            }

            // A TUI can take the terminal to the alt screen mid-glide
            // (delayed `less` startup, mosh repaint) — re-check the same
            // predicate the dispatcher used and stop before emitting any
            // motion the remote app would see as stale.
            let terminal = view.getTerminal()
            let isAltScreen = TerminalScrollRouting.isAltScreen(
                bufferIsAlternate: terminal.isCurrentBufferAlternate,
                mouseReporting: terminal.mouseMode != .off,
                mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen
            )
            guard !isAltScreen else {
                cancelScrollInertia(reason: "alt-screen")
                return
            }

            // A different pan actively tracking touches — SwiftTerm's
            // selection pan claims finger drags while a selection is
            // active, so the built-in-pan target-action never fires for
            // them. Poll here so the glide yields before the two writers
            // fight over contentOffset (selection autoscroll vs our tick).
            if view.gestureRecognizers?.contains(where: { recognizer in
                recognizer is UIPanGestureRecognizer
                    && recognizer !== semanticScrollGesture
                    && recognizer !== discreteScrollGesture
                    && (recognizer.state == .began || recognizer.state == .changed)
            }) == true {
                cancelScrollInertia(reason: "concurrent-pan")
                return
            }

            // Frame delta from the previous tick's target. Clamped so a
            // main-thread hitch doesn't turn into a teleport.
            let dt: CFTimeInterval
            if inertiaLastTargetTimestamp == 0 {
                dt = link.targetTimestamp - link.timestamp
            } else {
                dt = min(link.targetTimestamp - inertiaLastTargetTimestamp, 0.1)
            }
            inertiaLastTargetTimestamp = link.targetTimestamp

            let delta = inertia.step(dt: dt)
            scrollInertia = inertia
            inertiaTickCount += 1
            guard delta != 0 else {
                cancelScrollInertia(reason: "decayed")
                return
            }

            let tick = inertiaTickCount
            let localScroll = applyPrimaryScrollbackDelta(
                view: view,
                pointsY: delta,
                isInertial: true,
                // Sampled: a 2s glide at 120Hz would otherwise flood the
                // diagnostics ring buffer.
                diagnosticPrefix: tick % 15 == 0
                    ? "inertia tick=\(tick) v=\(String(format: "%.1f", inertia.velocity))"
                    : ""
            )
            if !localScroll {
                cancelScrollInertia(reason: "bound-or-consumed")
            } else if inertia.isFinished {
                cancelScrollInertia(reason: "decayed")
            }
        }

        func cancelScrollInertia(reason: String) {
            guard scrollInertia != nil || inertiaDisplayLink != nil else { return }
            inertiaDisplayLink?.invalidate()
            inertiaDisplayLink = nil
            scrollInertia = nil
            updateScrollActivity()
            emitScrollDiagnostic(
                "inertia-stop reason=\(reason) ticks=\(inertiaTickCount)"
            )
        }

        // MARK: - Gesture frame-drain display link

        private func startGestureFrameDrainLink() {
            stopGestureFrameDrainLink()
            gestureFrameTicks = 0
            gestureFrameLastTimestamp = 0
            gestureFrameGapMaxMs = 0
            gestureFrameDurationMs = 0
            let link = CADisplayLink(
                target: self,
                selector: #selector(handleGestureFrameTick(_:))
            )
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60, maximum: 120, preferred: 120
            )
            link.add(to: .main, forMode: .common)
            gestureFrameLink = link
        }

        @objc private func handleGestureFrameTick(_ link: CADisplayLink) {
            guard let view = terminalView, view.window != nil else {
                // Recognizer died with its view mid-gesture — no .ended
                // will come to stop us, and the link retains self. Release
                // the activity latch too: nothing else will, and a stuck
                // latch would defer overlay history application indefinitely.
                stopGestureFrameDrainLink()
                panGestureActive = false
                updateScrollActivity()
                return
            }
            gestureFrameTicks += 1
            gestureFrameDurationMs = (link.targetTimestamp - link.timestamp) * 1000
            if gestureFrameLastTimestamp > 0 {
                gestureFrameGapMaxMs = max(
                    gestureFrameGapMaxMs,
                    (link.timestamp - gestureFrameLastTimestamp) * 1000
                )
            }
            gestureFrameLastTimestamp = link.timestamp
            drainPendingGestureScroll(reason: "frame")
        }

        private func stopGestureFrameDrainLink() {
            gestureFrameLink?.invalidate()
            gestureFrameLink = nil
        }

        /// SGR mouse reports (`ESC [ < … M/m`) — pointer events forwarded to
        /// the remote app, distinct from typed input for scroll purposes.
        static func isMouseReport(_ data: ArraySlice<UInt8>) -> Bool {
            let bytes = Array(data.prefix(3))
            return bytes.count == 3
                && bytes[0] == 0x1B
                && bytes[1] == UInt8(ascii: "[")
                && bytes[2] == UInt8(ascii: "<")
        }

        /// Snap the viewport to the live prompt on typed input, clearing the
        /// retained scroll offset so the restore machinery doesn't pull the
        /// view back up. Alt screen has no local scroll position to snap.
        private func snapToBottomForUserInput() {
            guard let view = terminalView else { return }
            guard !view.getTerminal().isCurrentBufferAlternate else { return }
            clearDesiredScrollOffset(reason: "user-input", view: view)
            let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
            if view.contentOffset.y < maxOffsetY - 0.5 {
                view.contentOffset = CGPoint(x: view.contentOffset.x, y: maxOffsetY)
            }
        }

        /// Terminal-originated auto-replies (cursor-position reports,
        /// device attributes, DSR, DECRQM, window reports, DCS replies for
        /// DECRQSS/XTGETTCAP) route through the same `send` delegate as
        /// keystrokes but carry no user intent. Conservative shape match —
        /// anything unrecognized counts as user input. Known ambiguity:
        /// modified F3 encodes as `CSI 1;2R`, colliding with CPR by design
        /// of the protocol; treating it as a reply merely skips one glide
        /// cancel.
        static func isTerminalAutoReply(_ data: ArraySlice<UInt8>) -> Bool {
            let bytes = Array(data)
            guard bytes.count >= 3, bytes[0] == 0x1B else { return false }
            // DCS replies (ESC P … ST) — user keys never produce DCS.
            if bytes[1] == UInt8(ascii: "P") { return true }
            // CSI replies: ESC [ (optional ? or >) digits/; (optional $)
            // ending in a report-only final byte. Keystrokes either have
            // no parameter digits (arrows: ESC[A) or end in ~ (nav keys).
            guard bytes[1] == UInt8(ascii: "[") else { return false }
            var i = 2
            if bytes[i] == UInt8(ascii: "?") || bytes[i] == UInt8(ascii: ">") {
                i += 1
            }
            var digitCount = 0
            while i < bytes.count,
                  (0x30...0x39).contains(bytes[i])
                    || bytes[i] == UInt8(ascii: ";")
                    || bytes[i] == UInt8(ascii: "$") {
                if (0x30...0x39).contains(bytes[i]) { digitCount += 1 }
                i += 1
            }
            guard digitCount > 0, i == bytes.count - 1 else { return false }
            switch bytes[i] {
            case UInt8(ascii: "R"),  // CPR (cursor position report)
                 UInt8(ascii: "c"),  // DA1/DA2
                 UInt8(ascii: "n"),  // DSR
                 UInt8(ascii: "t"),  // window size/state reports
                 UInt8(ascii: "y"):  // DECRQM ($y)
                return true
            default:
                return false
            }
        }

        /// Consumes one physical scroll gesture while a hook-proven agent is
        /// working. Notify once at gesture start (with a changed-state fallback
        /// for discrete wheels that skip `.began`) so a fast trackpad stream
        /// never invalidates SwiftUI on every event.
        @objc func handleAgentBlockedScroll(_ recognizer: UIPanGestureRecognizer) {
            guard agentScrollBlockingActive else { return }
            switch recognizer.state {
            case .began:
                agentScrollBlockNotified = true
                onUserActivity?()
                onAgentScrollBlocked?()
                emitScrollDiagnostic("agent-scroll-blocked input=gesture")
            case .changed:
                // Some discrete pointer devices enter at `.changed`; the
                // fallback still emits exactly one notice for that gesture.
                if !agentScrollBlockNotified {
                    agentScrollBlockNotified = true
                    onUserActivity?()
                    onAgentScrollBlocked?()
                    emitScrollDiagnostic("agent-scroll-blocked input=gesture")
                }
                let translation = recognizer.translation(in: terminalView)
                if abs(translation.y) > 0.01 {
                    recognizer.setTranslation(.zero, in: terminalView)
                }
            case .ended, .cancelled, .failed:
                agentScrollBlockNotified = false
            default:
                break
            }
        }

        /// Target added to SwiftTerm's built-in touch pan (its scroll-type
        /// mask is cleared, so this fires for finger drags only). A finger
        /// landing mid-glide must hand control to the native scroll view
        /// physics instead of fighting the display link.
        /// Native-scroll surfaces only. Mirrors pan activity into the
        /// host's scrolled handler so edge-pinned pans (no didScroll when
        /// bounces=false clamps the offset) still drive top-reach fetches
        /// and bottom dismissal, and gesture end resolves boundaries
        /// faster than the 100ms settle poll alone.
        @objc func handleNativeScrollSurfacePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = terminalView else { return }
            switch recognizer.state {
            case .changed:
                onTerminalScrolled?(view)
            case .ended, .cancelled:
                // After the current runloop turn, so isTracking/isDragging
                // have cleared and any deceleration has been committed.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let view = self.terminalView else { return }
                    self.onTerminalScrolled?(view)
                }
            default:
                break
            }
        }

        @objc func handleNativeTouchPan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began {
                cancelScrollInertia(reason: "touch-pan")
            }
        }

        /// Reports a reader's finger frames to `onNativeScrollFrame`.
        ///
        /// SwiftTerm's `scrolled` delegate fires for output only, and
        /// TerminalView is its own scroll-view delegate, so without this the
        /// inline history gate never saw a finger pan: touch readers stopped at
        /// the attach capture's 2000 rows while the trackpad deepened. KVO
        /// carries UIScrollView's pan and deceleration frames, old offset
        /// included, so a slow drag still reads as upward. Writes made while
        /// no finger is down or no glide is running (output, placement, the
        /// trackpad owner's own glide) are not a reader's gesture. Output that
        /// trims rows under a resting finger still reads as upward; like
        /// Android's draw listener, the gate then at most prefetches for a
        /// reader already near the oldest row.
        func observeNativeScrollFrames(of view: TerminalView) {
            nativeScrollFrameObservation = view.observe(
                \.contentOffset,
                options: [.old, .new]
            ) { [weak self] view, change in
                guard let oldY = change.oldValue?.y,
                      let newY = change.newValue?.y,
                      oldY != newY
                else { return }
                MainActor.assumeIsolated {
                    guard view.isTracking || view.isDragging || view.isDecelerating else { return }
                    self?.onNativeScrollFrame?(view, oldY)
                }
            }
        }

        // MARK: - Mouse click for TUI apps (§3.2 C3)

        /// Compute cell dimensions using the same formula as
        /// SwiftTerm's internal `computeFontDimensions`. This
        /// gives pixel-exact coordinates matching the Metal
        /// renderer's glyph grid.
        private func cellDimensions(
            for view: TerminalView
        ) -> (w: CGFloat, h: CGFloat) {
            let font = view.font
            let ctFont = font as CTFont
            let ascent = CTFontGetAscent(ctFont)
            let descent = CTFontGetDescent(ctFont)
            let leading = CTFontGetLeading(ctFont)
            let cellH = ceil(ascent + descent + leading)
            let cellW = "W".size(
                withAttributes: [.font: font]
            ).width
            // Snap to pixel grid (same as SwiftTerm).
            let scale = view.contentScaleFactor
            let w = ceil(cellW * scale) / scale
            let h = ceil(cellH * scale) / scale
            return (max(1, w), max(1, h))
        }

        /// mosh+tmux: the active pane's program asked for the mouse, which
        /// this surface's own mode does not show. Only at the live tail: a
        /// tap on local history the reader has scrolled back to would land on
        /// the program's unrelated rows.
        private func remotePaneTakesClicks(in view: TerminalView) -> Bool {
            guard view.getTerminal().mouseMode == .off,
                  remotePaneReportsMouse?() == true
            else { return false }
            return isAtLiveTail(view)
        }

        private func isAtLiveTail(_ view: TerminalView) -> Bool {
            view.contentSize.height - view.bounds.height - view.contentOffset.y <= 1.0
        }

        @objc func handleMouseTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = terminalView else { return }
            onUserActivity?()

            if handlePaneFocusTapIfNeeded(in: view, at: recognizer.location(in: view)) {
                return
            }

            let terminal = view.getTerminal()
            let remotePaneClick = remotePaneTakesClicks(in: view)
            guard terminal.mouseMode != .off || remotePaneClick else { return }

            // This recognizer prevents SwiftTerm's singleTap from running, so
            // it must also perform singleTap's focus-only first tap. Otherwise
            // a TUI keeps accepting clicks after focus loss while every key is
            // dropped. Pane selection above retains priority over local focus.
            if !view.isFirstResponder {
                _ = view.becomeFirstResponder()
                return
            }
            // Revealed history passes taps through to this surface. With
            // tmux `mouse on` the client reports the mouse, but the program
            // under the tapped cell is hidden behind that history.
            if remoteHistoryRevealed?() == true { return }

            // Screen coordinates: the recognizer reports scroll-view content
            // coordinates, which include any scrollback above the screen
            // (the mosh primary buffer keeps some). Without this, every click
            // clamps to the bottom row.
            var pt = recognizer.location(in: view)
            pt.x -= view.contentOffset.x
            pt.y -= view.contentOffset.y
            let (cellW, cellH) = cellDimensions(for: view)

            // 0-indexed grid position, clamped.
            let col = max(0, min(terminal.cols - 1, Int(pt.x / cellW)))
            let row = max(0, min(terminal.rows - 1, Int(pt.y / cellH)))

            if remotePaneClick {
                // mosh+tmux: this surface has no mouse protocol, so SwiftTerm
                // would not encode one. tmux parses SGR from any client,
                // forwards the click to the pane under that cell while its
                // `mouse` option is off, and re-encodes it in the pane's own
                // mode.
                onSend(ArraySlice(Array("\u{1B}[<0;\(col + 1);\(row + 1)M\u{1B}[<0;\(col + 1);\(row + 1)m".utf8)))
                return
            }

            // Use SwiftTerm's own sendEvent which handles protocol
            // encoding (SGR/X10/etc.) and sends through the delegate
            // chain → our send callback → tmux sendInput.
            // buttonFlags: 0 = left press, 3 = left release.
            terminal.sendEvent(buttonFlags: 0, x: col, y: row)
            terminal.sendEvent(buttonFlags: 3, x: col, y: row)
        }

        private func handlePaneFocusTapIfNeeded(
            in view: TerminalView,
            at point: CGPoint
        ) -> Bool {
            guard paneFocusTapEnabled,
                  let onPaneFocusTap
            else { return false }

            var pt = point
            pt.x -= view.contentOffset.x
            pt.y -= view.contentOffset.y
            let (cellW, cellH) = cellDimensions(for: view)
            return onPaneFocusTap(pt, CGSize(width: cellW, height: cellH))
        }

        /// Mosh tap-to-focus (split windows only). This recognizer covers the
        /// mouse-reporting-off case. When mouse reporting is on, `handleMouseTap`
        /// performs the same non-active-pane focus check before forwarding the
        /// click into the active TUI.
        @objc func handlePaneFocusTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = terminalView else { return }
            onUserActivity?()
            _ = handlePaneFocusTapIfNeeded(in: view, at: recognizer.location(in: view))
        }

        // MARK: - UIGestureRecognizerDelegate

        private func primaryScrollPaneAtGestureStart(
            _ pan: UIPanGestureRecognizer,
            in view: TerminalView
        ) -> PaneId? {
            var point = pan.location(in: view)
            if pan.numberOfTouches > 0 {
                let translation = pan.translation(in: view)
                point.x -= translation.x
                point.y -= translation.y
            }
            return primaryScrollPaneAtLocation?(view, point)
        }

        private func isPrimaryTouchLocal(in view: TerminalView, paneID: PaneId?) -> Bool {
            if let local = primaryTouchScrollIsLocalForPane?(paneID) { return local }
            if let local = primaryTouchScrollIsLocal?() { return local }
            let terminal = view.getTerminal()
            return !TerminalScrollRouting.isAltScreen(
                bufferIsAlternate: terminal.isCurrentBufferAlternate,
                mouseReporting: terminal.mouseMode != .off,
                mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === agentScrollBlockGesture {
                guard agentScrollBlockingActive,
                      let pan = gestureRecognizer as? UIPanGestureRecognizer,
                      let view = terminalView
                else { return false }
                let velocity = pan.velocity(in: view)
                if pan.numberOfTouches == 0 {
                    // Scroll-type events may be diagonal. Block every event
                    // with a vertical component; otherwise its Y delta can
                    // still move history even when X is dominant.
                    return abs(velocity.y) > 0.01
                }
                return abs(velocity.y) >= abs(velocity.x)
            }

            guard gestureRecognizer === semanticScrollGesture,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  pan.numberOfTouches > 0,
                  let view = terminalView
            else { return true }

            // A primary tmux shell must never receive a mouse drag, including
            // diagonal pans with a larger horizontal than vertical component.
            if isPrimaryTouchLocal(in: view, paneID: primaryScrollPaneAtGestureStart(pan, in: view)) {
                return true
            }

            // Direct-touch scrolling is deliberately vertical-only. If the
            // TUI uses a horizontal drag affordance, fail here so SwiftTerm's
            // mouse-reporting pan can receive it instead.
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) >= abs(velocity.x)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive event: UIEvent
        ) -> Bool {
            if gestureRecognizer === agentScrollBlockGesture {
                guard agentScrollBlockingActive else { return false }
                if event.type == .scroll { return true }
                guard event.type == .touches,
                      let touches = event.allTouches,
                      !touches.isEmpty,
                      touches.allSatisfy({ $0.type == .direct })
                else { return false }
                return true
            }
            if gestureRecognizer === mouseTapGesture {
                // Only recognize when mouse mode is active (SGR click forward).
                guard let tv = terminalView else { return false }
                return tv.getTerminal().mouseMode != .off || remotePaneTakesClicks(in: tv)
            }
            if gestureRecognizer === paneFocusTapGesture {
                // Mosh tap-to-focus without terminal mouse reporting. With
                // mouse reporting on, `handleMouseTap` first selects a
                // non-active pane, then only forwards clicks that land in the
                // already-active pane.
                guard let tv = terminalView else { return false }
                return paneFocusTapEnabled && tv.getTerminal().mouseMode == .off
                    && !remotePaneTakesClicks(in: tv)
            }
            guard gestureRecognizer === semanticScrollGesture else {
                return true
            }

            // Indirect scrolling always uses the shared dispatcher. Direct
            // pans also use it when mouse reporting could otherwise let
            // SwiftTerm forward the touch as a remote mouse drag.
            if event.type == .scroll { return true }
            guard event.type == .touches,
                  let touches = event.allTouches,
                  !touches.isEmpty,
                  touches.allSatisfy({ $0.type == .direct }),
                  let view = terminalView,
                  !view.selectionActive
            else { return false }

            // mosh+tmux: the pane's history lives in tmux, not in this scroll
            // view, and mosh never relays the alternate screen. The host
            // fetches history, or forwards to a full-screen pane, exactly as
            // for a trackpad.
            if touchPansTakePointerRoute?() == true { return true }

            let terminal = view.getTerminal()
            // Keep mouse-enabled direct pans with the semantic owner even
            // when tmux's mouse flag belongs to a primary shell. Otherwise
            // SwiftTerm's mouse-drag recognizer can enter tmux copy mode.
            return terminal.mouseMode != .off || TerminalScrollRouting.isAltScreen(
                bufferIsAlternate: terminal.isCurrentBufferAlternate,
                mouseReporting: terminal.mouseMode != .off,
                mouseReportingImpliesAltScreen: mouseReportingImpliesAltScreen
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Coexist peacefully with SwiftTerm's internal recognizers.
            // Primary-screen touches never enter our pan. Alternate-screen
            // vertical pans win explicitly over SwiftTerm's mouse-drag pan,
            // while the native UIScrollView may recognize simultaneously
            // without moving (alternate screens have no local scroll range).
            true
        }
    }
}

/// Debounced presentation state shared by SSH, mosh, and the host-free scroll
/// harness. Repeated gestures extend the same default two-second notice instead of
/// stacking banners; the blocker identity allows callers to dismiss stale UI
/// immediately when that exact agent stops working.
@MainActor
@Observable
final class AgentScrollPreventionNoticeController {
    private(set) var prevention: AgentScrollPrevention?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private let dismissDelay: Duration

    init(dismissDelay: Duration = .seconds(2)) {
        self.dismissDelay = dismissDelay
    }

    func show(_ prevention: AgentScrollPrevention) {
        dismissTask?.cancel()
        self.prevention = prevention
        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.dismissDelay)
            } catch {
                return
            }
            guard self.prevention == prevention else { return }
            self.prevention = nil
            self.dismissTask = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        prevention = nil
    }
}

/// Top-of-terminal in-app notice shown only after a blocked physical scroll
/// attempt. The provider name makes the source of the behavior explicit so a
/// user does not interpret the terminal staying at the live tail as a Tessera
/// scrolling failure.
struct AgentScrollPreventionNotice: View {
    let agentName: String
    let T: DesignTokens

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(T.amber)

            Text("\(agentName) is working — scrolling is temporarily disabled")
                .font(Typography.tesseraMono(size: 12, weight: .medium))
                .foregroundStyle(T.fg)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(T.panelBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(T.amber.opacity(0.55), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent-scroll-prevention-notice")
        .accessibilityLabel("\(agentName) is working. Scrolling is temporarily disabled.")
    }
}

/// Slim banner shown when the auto-tmux script's "tmux not available"
/// sentinel is detected on the SSH output stream. Sits below the
/// session top bar; dismissable via the trailing X.
/// Why an auto-tmux / pinned-tmux launch fell back to the plain shell.
/// Each case maps to a distinct remote condition so the banner tells the
/// user something actionable instead of a generic failure.
enum TmuxLaunchDegradeReason: Equatable {
    /// `tmux` is not installed on the host.
    case unavailable
    /// tmux is installed but the session could not be created — the
    /// server refused to start.
    case startFailed
    /// The launch command produced no tmux handshake at all within the
    /// watchdog window (a login shell that never ran it, a tmux that
    /// never finished starting, a host that swallowed the command).
    case noHandshake
    /// The host's login dotfiles already started tmux, so the terminal is
    /// inside a client that control mode cannot nest into.
    case nested
    /// tmux attached in control mode but never delivered the first render
    /// (capture metadata failing, quiet pane with no output to latch). The
    /// session is live — this reveals it instead of degrading it, so the
    /// wording asks for a keystroke rather than announcing a plain shell.
    case hydrationStalled

    var bannerText: LocalizedStringResource {
        switch self {
        case .unavailable:
            return "tmux not available on remote host — multi-window features disabled"
        case .startFailed:
            return "tmux could not start a session on this host — showing the plain shell"
        case .noHandshake:
            return "tmux never started — showing the plain shell (the terminal below has the details)"
        case .nested:
            return "this host starts its own tmux at login — showing that session as a plain terminal"
        case .hydrationStalled:
            return "tmux is attached but the screen has not painted — press any key to wake it"
        }
    }

    var diagnosticName: String {
        switch self {
        case .unavailable: return "unavailable"
        case .startFailed: return "start-failed"
        case .noHandshake: return "no-handshake"
        case .nested: return "nested"
        case .hydrationStalled: return "hydration-stalled"
        }
    }
}

private struct NoTmuxBanner: View {
    var reason: TmuxLaunchDegradeReason = .unavailable
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.yellow.opacity(0.85))

            Text(reason.bannerText)
                .font(Typography.tesseraMono(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 540)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SwiftUI.Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SwiftUI.Color.yellow.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}

private struct MoshTmuxShortcutBlockedToast: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow.opacity(0.95))

            Text("tmux control reconnecting - shortcut not sent")
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SwiftUI.Color.black.opacity(0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SwiftUI.Color.yellow.opacity(0.35), lineWidth: 0.5)
                )
        )
    }
}

struct ConnectionStatusBreakdownView: View {
    let status: SessionConnectionStatus
    /// Appends the session's reported program status, when it has any.
    var programs: (sessionID: UUID, T: DesignTokens, onOpen: (ProgramStatusTerminalKey) -> Void)?
    @Environment(ProgramStatusCenter.self) private var programStatusCenter

    var body: some View {
        let programCount = programs.map { programStatusCenter.detailEntries(sessionID: $0.sessionID).count } ?? 0
        let content = VStack(alignment: .leading, spacing: 7) {
            ForEach(status.lines, id: \.self) { line in
                Text(line)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            if let programs {
                ProgramStatusDetailsList(sessionID: programs.sessionID, T: programs.T, onOpen: programs.onOpen)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        return Group {
            if programCount > 5 {
                // Many records scroll rather than outgrow the screen. Popovers
                // collapse greedy ScrollViews, so the height is explicit.
                ScrollView { content }
                    .frame(width: 340, height: 480)
            } else if programCount > 0 {
                content.frame(width: 340, alignment: .leading)
            } else {
                content
            }
        }
        .frame(minWidth: 210, alignment: .leading)
        .background(SwiftUI.Color.black.opacity(0.94))
        .presentationBackground(SwiftUI.Color.black.opacity(0.94))
        .presentationCornerRadius(8)
    }
}

#if DEBUG
/// Host-free reproduction of focus + layout notifications sharing one read.
/// Uses the production controller, grid, terminal surfaces and command facade.
struct SplitBatchHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var controller = TmuxController()
    @State private var session = SessionTopBarHarnessSession()
    @State private var box = TerminalBox(traceLabel: "split-batch-shared")
    @State private var drops = RenderDropSummaryReporter()
    @State private var modifiers = ModifierState()
    @State private var kitty = KittyPaneModeStore()
    @State private var phase = "initial"
    @State private var sequence = 100
    @State private var started = false

    private let single = "b25d,120x36,0,0,5"
    private let split = "8205,120x36,0,0{60x36,0,0,5,59x36,61,0,6}"
    private var window: TmuxController.WindowInfo? {
        controller.windows.first { $0.id == controller.activeWindowId }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(phase) | panes=\(window?.layout?.paneCount ?? 0) | focus=\(controller.activePaneId?.description ?? "nil")")
                .accessibilityIdentifier("split-batch-status")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white).frame(height: 28)
            ZStack {
                TerminalSurfaceBound(
                    initialData: [], onMade: { box.attach($0); box.markRenderReady() },
                    onReady: {}, onSend: { _ in }, onResize: { _, _ in }, onTitle: { _ in },
                    onUserActivity: nil, onBell: nil, mouseReportingImpliesAltScreen: false,
                    suppressDirectColorQueryResponses: true, tmuxShortcutsEnabled: false,
                    onTmuxShortcut: { _ in }, onFindShortcut: nil, onSwitcherShortcut: nil,
                    onOpenSettings: nil, suppressFirstResponderReclaim: true, onHardwareKey: nil
                )
                if let window, window.rendersAsPaneGrid {
                    PaneGridView(
                        window: window, tmux: controller, renderDropSummary: drops,
                        sessionCommands: session.sessionCommands(tmux: controller),
                        cellSize: TerminalCellMetrics.cellSize(
                            font: TerminalFontResolver.uiFont(id: appearance.terminalFontID, size: CGFloat(appearance.fontSize)),
                            scale: UIScreen.main.scale),
                        chrome: DesignTokens.make(mode: .dark, accent: .blue), backgroundColor: .black,
                        terminalBackground: nil, tmuxShortcutsEnabled: false, onTmuxShortcut: { _ in },
                        onFindShortcut: nil, onSwitcherShortcut: nil, onOpenSettings: nil,
                        onOpenAgentCenter: nil, onSelectionPathAction: nil, onUserActivity: nil,
                        agentScrollPreventionForPane: { _ in nil }, onAgentScrollBlocked: { _ in },
                        suppressFindReclaim: true, inputSuppressed: false, forceResignFirstResponder: false,
                        compactSinglePane: CompactLayout.isPhone(sizeClass), modifierState: modifiers,
                        kittyPaneModes: kitty, onFocusedBoxChanged: { _ in }, onFocusedPaneRefreshed: {},
                        onPaneBell: { _ in }, onScrollDiagnostic: { _, _ in }
                    ).id(window.id)
                }
            }
        }
        .background(Color.black).preferredColorScheme(.dark)
        .onAppear {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                .requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
        }
        .task {
            guard !started else { return }; started = true
            appearance.cursorBlink = false
            try? await Task.sleep(for: .milliseconds(500))
            controller.feedTerminal = { box.feed($0) }
            controller.sendBytes = { bytes in
                let command = String(decoding: bytes, as: UTF8.self)
                // Enqueue replies: never reenter the production parser from a send.
                DispatchQueue.main.async {
                    for line in command.split(separator: "\n") { reply(to: String(line)) }
                }
            }
            controller.ingest([0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
            frame([], flags: 0)
            try? await Task.sleep(for: .seconds(1))
            controller.ingest(Array("%session-changed $0 split-lab\r\n%window-add @1\r\n%window-add @2\r\n".utf8))
            try? await Task.sleep(for: .milliseconds(300))
            controller.ingest(Array("%window-pane-changed @1 %5\r\n%session-window-changed $0 @1\r\n%layout-change @1 \(single) \(single) *\r\n".utf8))
            try? await Task.sleep(for: .seconds(1))
            box.feed(Array("\u{1b}[2J\u{1b}[HORIGINAL PANE %5\r\nSplit must preserve this pane beside NEW PANE %6.".utf8)[...])
            phase = "before split"
            try? await Task.sleep(for: .seconds(3))
            let messages = ["%window-pane-changed @1 %6\r\n", "%layout-change @1 \(split) \(split) *\r\n"]
            let chunks = ProcessInfo.processInfo.environment["TESSERA_SPLIT_BATCH_SEPARATE"] == "1" ? messages : [messages.joined()]
            for chunk in chunks { _ = await controller.ingestCooperatively(Array(chunk.utf8)) }
            phase = "after split"
            logPhase()
            try? await Task.sleep(for: .seconds(4))
            controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
            try? await Task.sleep(for: .seconds(1))
            controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
            phase = "returned to split"
            logPhase()
        }
    }

    private func logPhase() {
        NSLog("[SplitBatchHarness] phase=%@ panes=%d focus=%@", phase, window?.layout?.paneCount ?? 0, controller.activePaneId?.description ?? "nil")
    }

    private func frame(_ lines: [String], flags: Int = 1) {
        sequence += 1
        controller.ingest(Array((["%begin 0 \(sequence) \(flags)"] + lines + ["%end 0 \(sequence) \(flags)", ""]).joined(separator: "\r\n").utf8))
    }

    private func reply(to command: String) {
        NSLog("[SplitBatchHarness] command=%@", command)
        let pane = command.contains("-t @2") ? "%9" : command.contains("-t %6") ? "%6" : command.contains("-t %5") ? "%5" : (controller.activePaneId?.description ?? "%5")
        if command.hasPrefix("capture-pane") {
            let label = pane == "%5" ? "ORIGINAL PANE %5" : "NEW PANE %6"
            frame((0..<36).map { "\(label) row \($0 + 1)" })
        } else if command.hasPrefix("display-message"), command.contains("pane_id") {
            frame(["\(pane)\t0\t0\t\(pane)\tshell\thost\t0"])
        } else {
            frame([])
        }
    }
}
#endif
