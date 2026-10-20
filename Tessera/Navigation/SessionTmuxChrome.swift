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

enum MoshTcpControlStatus: Equatable {
    case connected
    case retrying
    case disconnected
}

enum SessionConnectionStatus: Equatable {
    case ssh(state: SessionState)
    case mosh(
        sessionState: SessionState,
        transportState: MoshTransportState,
        tcpControl: MoshTcpControlStatus?
    )

    var dotColor: SwiftUI.Color {
        switch self {
        case .ssh(let state):
            return Self.dotColor(for: state)
        case .mosh(let sessionState, let transportState, let tcpControl):
            switch sessionState {
            case .connected:
                switch transportState {
                case .connected:
                    break
                case .connecting, .idle:
                    return SwiftUI.Color.yellow.opacity(0.9)
                case .disconnected:
                    return SwiftUI.Color.red
                }
                guard let tcpControl else {
                    return SwiftUI.Color.green
                }
                return tcpControl == .connected
                    ? SwiftUI.Color.green
                    : SwiftUI.Color.yellow.opacity(0.9)
            case .connecting:
                return SwiftUI.Color.yellow.opacity(0.9)
            case .idle:
                return SwiftUI.Color.gray
            case .disconnected, .failed:
                return SwiftUI.Color.red
            }
        }
    }

    /// One whole sentence per transport rather than a `"<label>: <state>"`
    /// template — the state word inflects with the label in several
    /// languages, and the punctuation itself differs (CJK uses a full-width
    /// colon).
    var lines: [String] {
        switch self {
        case .ssh(let state):
            return [Self.isConnected(state)
                ? String(localized: "ssh: connected")
                : String(localized: "ssh: disconnected")]
        case .mosh(let sessionState, let transportState, let tcpControl):
            let moshConnected = Self.isConnected(sessionState) && transportState == .connected
            var lines = [moshConnected
                ? String(localized: "mosh: connected")
                : String(localized: "mosh: disconnected")]
            if let tcpControl {
                lines.append(Self.controlLine(for: tcpControl, sessionState: sessionState))
            }
            return lines
        }
    }

    private static func controlLine(
        for tcpControl: MoshTcpControlStatus,
        sessionState: SessionState
    ) -> String {
        guard isConnected(sessionState) else {
            return String(localized: "tcp control: disconnected")
        }
        switch tcpControl {
        case .connected:    return String(localized: "tcp control: connected")
        case .retrying:     return String(localized: "tcp control: retrying")
        case .disconnected: return String(localized: "tcp control: disconnected")
        }
    }

    private static func isConnected(_ state: SessionState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private static func dotColor(for state: SessionState) -> SwiftUI.Color {
        switch state {
        case .idle:
            return .gray
        case .connecting:
            return .yellow
        case .connected:
            return .green
        case .disconnected, .failed:
            return .red
        }
    }

}

/// 600 ms accent stroke fade — attached to a tmux tab pill the moment its
/// window emits BEL. Self-animates from `0.85 → 0` opacity once on appear;
/// re-mounted via `.id(bellController.lastBellAt)` so back-to-back bells
/// retrigger cleanly.
struct BellGlowOverlay: View {
    let color: SwiftUI.Color
    @State private var opacity: Double = 0.85

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(color, lineWidth: 2)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) { opacity = 0 }
            }
    }
}

extension TesseraTmuxShortcut {
    var logDescription: String {
        switch self {
        case .newWindow:
            return "newWindow"
        case .killCurrentWindow:
            return "killCurrentWindow"
        case .previousWindow:
            return "previousWindow"
        case .nextWindow:
            return "nextWindow"
        case .moveWindowLeft: return "moveWindowLeft"
        case .moveWindowRight: return "moveWindowRight"
        case .selectWindow(let position):
            return "selectWindow(\(position))"
        case .splitPaneHorizontal:
            return "splitPaneHorizontal"
        case .splitPaneVertical:
            return "splitPaneVertical"
        case .cyclePaneNext:
            return "cyclePaneNext"
        case .cyclePanePrevious:
            return "cyclePanePrevious"
        case .zoomPane:
            return "zoomPane"
        }
    }
}

/// Always-visible top chrome bar that lives in the corner-inset area
/// above the terminal content (§3.5 R3.5.2).
///
/// The bar has two layouts driven by the tmux controller's mode:
///
/// **Passthrough (no tmux)** — single-row status line:
///
///     ● user@127.0.0.1:22  connecting…                   back
///
/// **tmux control mode** — iTerm2-style tab strip:
///
///     ● tmux  [editor]  logs  zsh                          back
///
/// The active tab is highlighted; inactive tabs are dimmed. Tab
/// labels default to the `@N` window id until tmux sends a
/// `%window-renamed` notification with a real name. Commit B makes
/// the tabs visual-only; commit C (§3.2) will make taps trigger
/// `select-window -t :N` and bind ⌘1-9.
///
/// Text is inset horizontally by `horizontalInset` (the display
/// corner radius) so characters clear the rounded corners. The
/// background extends edge-to-edge because it's solid black and
/// matches the safe-area fill behind the terminal — no visual seam
/// at the corners.
struct PendingTmuxWindowClose {
    let window: TmuxController.WindowInfo
    let controlConnectionGeneration: UInt64
}

/// The ⌘digit a tmux tab advertises. Dispatch (`.selectWindow(position:)`)
/// sends ⌘1…⌘8 to their position and ⌘9 to the final window, browser-style.
/// A window's own digit wins, so the third of three windows reads ⌘3 even
/// though ⌘9 reaches it too; past the eighth, only the final window has one.
enum TmuxWindowShortcutHint {
    static func digit(forPosition position: Int, windowCount: Int) -> Int? {
        guard position >= 1, position <= windowCount else { return nil }
        if position <= 8 { return position }
        return position == windowCount ? 9 : nil
    }
}

/// Browser-style close affordance for a tmux tab. The circle stays visible at
/// rest so the X reads as a button, brightens under the iPad pointer, and
/// compresses into a stronger fill while touch or pointer input is held down.
struct TmuxTabCloseButton: View {
    let name: String
    let windowID: Int
    let isActive: Bool
    let isAvailable: Bool
    let accessibilityHint: LocalizedStringKey
    let scale: CGFloat
    let T: DesignTokens
    /// The V2 root owns navigation; terminal chrome only requests it.
    var onOpenAgentCenter: (() -> Void)? = nil
    /// Accessibility-identifier namespace. The overflow window list renders a
    /// second close affordance for every window while it's open; namespacing
    /// keeps those from colliding with the strip's identifiers in UI queries.
    var idNamespace: String = "tmux-window"
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: max(7.5, 8.5 * scale), weight: .semibold))
                .frame(
                    width: max(15, 16 * scale),
                    height: max(15, 16 * scale)
                )
        }
        .buttonStyle(
            TmuxTabCloseButtonStyle(
                isActive: isActive,
                isAvailable: isAvailable,
                isHovered: isHovered,
                scale: scale,
                T: T
            )
        )
        .disabled(!isAvailable)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Close \(name) tmux window")
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("\(idNamespace)-\(windowID)-close")
    }
}

struct TmuxTabCloseButtonStyle: ButtonStyle {
    let isActive: Bool
    let isAvailable: Bool
    let isHovered: Bool
    let scale: CGFloat
    let T: DesignTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground(isPressed: configuration.isPressed))
            .background {
                Circle()
                    .fill(background(isPressed: configuration.isPressed))
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        border(isPressed: configuration.isPressed),
                        lineWidth: max(0.8, scale)
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .frame(width: max(28, 28 * scale), height: 24 * scale)
            // Absorb the label's old trailing gap, then give this destructive
            // control its own full target so UIKit never expands it across
            // the neighboring window-select surface.
            .padding(.leading, 7 * scale)
            .frame(minWidth: 44, minHeight: max(44, 32 * scale))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func foreground(isPressed: Bool) -> SwiftUI.Color {
        guard isAvailable else { return T.fgFaint.opacity(0.45) }
        if isPressed || isHovered { return T.fg }
        return isActive ? T.fgMuted : T.fgDim
    }

    private func background(isPressed: Bool) -> SwiftUI.Color {
        guard isAvailable else { return SwiftUI.Color.clear }
        if isPressed { return T.fg.opacity(T.isLight ? 0.16 : 0.24) }
        if isHovered { return T.fg.opacity(T.isLight ? 0.09 : 0.14) }
        return T.fg.opacity(T.isLight ? 0.04 : 0.06)
    }

    private func border(isPressed: Bool) -> SwiftUI.Color {
        guard isAvailable else { return T.fgFaint.opacity(0.4) }
        if isPressed { return T.fg }
        if isHovered { return T.fgMuted }
        return isActive ? T.fgDim : T.fgFaint
    }
}

struct SessionTopBar: View {
    private enum PendingContinuityAction {
        case continueSession
        case setUpAndContinue
    }

    let state: SessionState
    let host: Host
    let sessionID: UUID
    let sessionIsActive: Bool
    let tmux: TmuxController
    let sessionCommands: AppleSessionCommandFacade
    let tmuxIsDegraded: Bool
    let connectionStatus: SessionConnectionStatus
    let onToggleSidebar: () -> Void
    let sidebarVisible: Bool
    let onBack: () -> Void
    let onDisconnect: () -> Void
    /// Find-in-scrollback controller. Backs the trailing `⌕` button:
    /// tap toggles `findController.isOpen`, which makes the parent
    /// session view render the `FindBar` strip just below this top
    /// bar. The button lights up `accentSoft` while the bar is open
    /// to mirror the active-tab highlight.
    let findController: FindController
    /// Remote Files panel toggle — the trailing `folder` glyph between
    /// find and the forwarding chip. Accent-tinted while the panel is
    /// open, mirroring the find button's toggled treatment.
    let filesPanelOpen: Bool
    var fileTransferAttention: BackgroundTransferAttention = .none
    let onToggleFiles: () -> Void
    /// Drives the per-tab bell glow + badge dot. `bellingWindows` set
    /// on `tmux` accumulates inactive-window bells; `BellController`
    /// publishes `lastBellAt` for transient glow animations.
    let bellController: BellController
    /// Live PortForwarderManager for this session. SSH sessions pass it
    /// in so the `⇄ N` chip can render between the find button and the
    /// home button. Mosh sessions pass nil — forwarding is SSH-only.
    /// The chip auto-hides when the manager has zero forwarders, so a
    /// session with no rules looks identical to before.
    let forwarderManager: PortForwarderManager?
    /// Chrome tokens derived from the active TerminalTheme so the top bar
    /// matches the canvas color the user picked. Built once per render by
    /// the parent SessionView (see `themeChromeTokens` there); semantic
    /// state colors (green/amber/red) stay fixed across themes.
    let T: DesignTokens
    /// Opens the dedicated Agent Center v2 surface. Harnesses that exercise
    /// only terminal chrome can omit it.
    var onOpenAgentCenter: (() -> Void)? = nil
    /// Optional because a session without a publishable continuation
    /// descriptor has no cross-device action. When present it occupies its
    /// own bar pitch immediately before the trailing control.
    var continuityActions: SessionContinuityActions? = nil
    /// Raised immediately before the bar asks tmux for a pane-layout change.
    /// Mosh paints every pane into one shared terminal and draws the chrome
    /// as an overlay, so it masks the top row across the change — the same
    /// thing the ⌘D path does. SSH mounts real pane views and needs nothing,
    /// so it leaves this nil.
    var onTmuxPaneMutation: (() -> Void)? = nil
    @State private var statusBreakdownVisible = false
    @State private var continuityPopoverVisible = false
    @State private var attentionPopoverVisible = false
    @State private var integrationPopoverVisible = false
    /// `integrationWarningDue`, once it has held for the shared presentation
    /// delay. Every warning surface reads this, never the raw decision.
    @State private var integrationWarningPresented = false
    @State private var integrationConfirmationVisible = false
    @State private var pendingIntegrationAction: AgentIntegrationFixAction?
    @State private var pendingContinuityAction: PendingContinuityAction?
    @State private var programStatusCoverSource = UUID()
    @State private var pendingWindowClose: PendingTmuxWindowClose?
    /// Close confirmation staged by the window-list popover, held until the
    /// popover's content reports `onDisappear` (dismissal actually complete)
    /// before it becomes `pendingWindowClose`.
    @State private var stagedWindowListClose: PendingTmuxWindowClose?
    @State private var stagedWindowListRename: TmuxController.WindowInfo?
    /// Overflow window-list popover, anchored on the `chevron.down` button
    /// that appears when the tab strip overflows. The list provides a direct
    /// pick and vertical reorder alongside the strip's horizontal gestures.
    @State private var windowListVisible = false
    /// Tab-strip content frame in the scroll view's coordinate space.
    /// Width feeds the overflow check; minX/maxX drive the edge-fade
    /// hints while the strip is scrolled away from either end.
    @State private var tabStripContentFrame = CGRect.zero
    /// Visible width of the tab strip's scroll viewport.
    @State private var tabStripVisibleWidth: CGFloat = 0
    /// Whether the strip currently overflows (chevron visible). Held as
    /// state, not derived, because the check needs hysteresis — see
    /// `updateTabStripOverflow()`.
    @State private var tabStripOverflows = false
    @State private var tabDrag = TmuxWindowDragState()
    private var previewWindowOrder: [WindowId]? { tabDrag.previewOrder }
    private var draggingWindowID: WindowId? { tabDrag.isDragging ? tabDrag.id : nil }
    @State private var tabWindowFrames: [WindowId: CGRect] = [:]
    @State private var tabStripViewportFrame = CGRect.zero
    @State private var reorderScrollTarget: WindowId?
    @State private var reorderScrollToken = 0
    @State private var edgeAutoscrollDirection = 0
    @State private var edgeAutoscrollTask: Task<Void, Never>?
    @State private var tmuxMenuBackstopOn = false
    @State private var presentedTmuxMenuCount = 0
    @State private var tmuxMenuBackstopReleaseTask: Task<Void, Never>?
    @State private var pendingWindowRename: TmuxController.WindowInfo?
    @State private var windowRenameText = ""
    @State private var windowOrderErrorMessage: String?
    @State private var windowOrderErrorTask: Task<Void, Never>?

    /// Live appearance prefs — read for `topBarHeight`, which drives the
    /// `scale` multiplier applied to every icon, pill, dot, and font
    /// inside the bar. Flows down from SessionView/MoshSessionView's
    /// environment automatically; SessionTopBar isn't constructed
    /// outside those views.
    @Environment(AppearancePreferences.self) private var appearance
    @Environment(AgentCenterV2Coordinator.self) private var agentCenterV2
    @Environment(ProgramStatusCenter.self) private var programStatusCenter
    @Environment(AppPhase.self) private var appPhase
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isPhone: Bool {
        CompactLayout.isPhone(horizontalSizeClass)
    }

    /// Multiplier applied to every numeric literal inside the bar.
    /// 32pt is the v2 design baseline — at that height every element
    /// renders at its intrinsic size; smaller picks make icons/text
    /// shrink proportionally, larger picks grow them. Capped at 0.6
    /// to keep ⌘N hints legible at the slider's 26pt floor.
    private var scale: CGFloat {
        max(0.6, CGFloat(appearance.topBarHeight) / CGFloat(AppearancePreferences.defaultTopBarHeight))
    }

    /// Horizontal inset of the floating pill from the screen edges. Small
    /// enough to clear the iPad's display corner radius (a point this far in
    /// from the corner is inside the visible rounded screen) while still
    /// reading as a floating element with bg gutter on either side.
    static let floatSideInset: CGFloat = 10
    /// Gap above the pill, between the top safe area and the pill.
    static let floatTopInset: CGFloat = 8
    /// Gap below the pill before the find bar / terminal begins.
    static let floatBottomInset: CGFloat = 8

    /// Total vertical space the floating bar reserves in the session VStack:
    /// the pill itself plus its top and bottom gaps. The session views key
    /// their `.frame(height:)` and the banner / swipe-pad top offsets off
    /// this so everything tracks the user's `topBarHeight` slider together.
    static func reservedHeight(pillHeight: Double, compact: Bool) -> CGFloat {
        let visualHeight: CGFloat = compact ? 44 : CGFloat(pillHeight)
        let interactionHeight = max(44, visualHeight)
        return max(visualHeight + floatTopInset + floatBottomInset, interactionHeight)
    }

    private var visualBarHeight: CGFloat {
        isPhone ? 44 : CGFloat(appearance.topBarHeight)
    }

    private var interactionBarHeight: CGFloat {
        max(44, visualBarHeight)
    }

    private var verticalBarInset: CGFloat {
        max(0, (Self.reservedHeight(
            pillHeight: appearance.topBarHeight,
            compact: isPhone
        ) - interactionBarHeight) / 2)
    }

    /// The pill outline. Corner radius scales with the bar so the rounding
    /// stays proportional across the 26–44pt height range (≈13pt at the 32pt
    /// baseline, mirroring the mockup's 13/34 ratio). Always < half the pill
    /// height, so it's a rounded rect, never an unintended capsule.
    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isPhone ? 16 : 13 * scale, style: .continuous)
    }

    /// "on iPhone" chip shown while another device holds the shared grid —
    /// keeps the takeover visible in the chrome even though the veil owns
    /// the terminal area. iPad-width bar only; the compact phone bar has no
    /// room and the veil itself is the signal there.
    /// The glyph follows the same known-device rule as the label; branching it
    /// on the raw stamp put an iPad glyph next to "on another device".
    private func continuedElsewhereChip(peerName: String) -> some View {
        let label: String
        switch GridAuthorityDeviceIdentity.peerKind(peerName) {
        case .anotherOfOwnClass(let name):
            label = String(
                localized: "on another \(name)",
                comment: "Chip: the shared grid is held by a second device of the same kind, e.g. 'on another iPhone'"
            )
        case .named(let name):
            label = String(
                localized: "on \(name)",
                comment: "Chip: the shared grid is held by another device, e.g. 'on iPhone'"
            )
        case .unknownDevice:
            // Neutral like the veil's "continued elsewhere": the stamp-less
            // fallback raises the chip before the holder's stamp names it.
            label = String(
                localized: "elsewhere",
                comment: "Chip: the shared grid is held by a device not identified yet, or one this platform cannot name"
            )
        }
        return HStack(spacing: 5 * scale) {
            Image(systemName: GridAuthorityDeviceIdentity.knownDeviceNames.contains(peerName)
                ? (peerName == "iPhone" ? "iphone" : "ipad.landscape")
                : "display")
                .font(.system(size: 10 * scale, weight: .medium))
            Text(label)
                .font(Typography.tesseraMonoFixed(size: 10.5 * scale, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(T.fgMuted)
        .padding(.horizontal, 9 * scale)
        .frame(height: 22 * scale)
        .overlay {
            Capsule().stroke(T.borderStrong, lineWidth: 0.5)
        }
        .padding(.horizontal, 4 * scale)
    }

    private var styledBar: some View {
        Group {
            if isPhone {
                compactBarCore
            } else {
                // Spacing 0 — every child owns half of each 8pt-scaled gap
                // (chrome buttons via their full-pitch hit frames, pills via
                // 4pt-scaled padding) so glyph centers stay put while the
                // hit frames meet edge-to-edge.
                HStack(spacing: 0) {
            // Sidebar toggle — replaces the system NavigationSplitView
            // toggle that would otherwise float above us and waste the
            // entire top strip. A three-bar `line.3.horizontal` "menu"
            // glyph (the widely-recognized show-sidebar affordance); the
            // accent tint (via isToggled) reinforces the open state. The
            // sidebar floats over the terminal, so toggling never resizes
            // the grid — collapse it again from here or the in-panel ‹.
            chromeIconButton(
                systemName: "line.3.horizontal",
                isToggled: sidebarVisible,
                action: onToggleSidebar
            )

            // Leading region swaps between "connection status" (no
            // tmux) and "tmux tab strip" (tmux active). The home
            // button sits on the trailing edge of both layouts so the
            // bar reads symmetrically.
            if (tmux.mode == .tmuxControl || tmuxIsDegraded) && !tmux.windows.isEmpty {
                tabStrip
            } else {
                passthroughStatus
                Spacer(minLength: 8)
            }

            if let peerName = tmux.gridAuthority.peerDisplayName {
                continuedElsewhereChip(peerName: peerName)
            }

            // Find-in-scrollback toggle. Slot between the (tmux-only)
            // window controls and the trailing `house` so the home button
            // stays anchored at the far edge regardless of which
            // layout the bar is in.
            chromeIconButton(
                systemName: "magnifyingglass",
                isToggled: findController.isOpen,
                action: {
                    if findController.isOpen {
                        findController.close()
                    } else {
                        findController.open()
                    }
                }
            )
            .disabled(tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)

            // Remote Files panel toggle (⌘⇧E). Sits with the other
            // trailing utilities so the home button stays anchored.
            filesButton

            // Port forwarding indicator. Hides when the session has no
            // forwarders defined; otherwise shows `⇄ N` with the running
            // listener count, its glyph green while something answers
            // behind a tunnel, and opens a popover sheet on tap.
            if let forwarderManager {
                ForwardingStatusChip(
                    manager: forwarderManager,
                    scale: scale,
                    T: T,
                    monitorsServices: sessionIsActive && appPhase.isActive
                )
            }

            if sessionIsActive,
               appPhase.isActive,
               programStatusCenter.counts(agentCenter: agentCenterV2).total > 0 {
                agentAttentionButton
            }

            if integrationWarningVisible {
                agentIntegrationWarningButton
            }

            if let continuityActions {
                continuityButton(actions: continuityActions)
            }

            // Home — returns to the host landing. Mirrors the leading
            // sidebar toggle's icon-button style for visual symmetry,
            // replacing the v1 `back` text label which carried no
            // affordance hint.
            chromeIconButton(systemName: "house", action: onBack)
                .accessibilityLabel("Hosts home")
                .accessibilityIdentifier("session-home")

                }
            }
        }
        // Inner content inset (mockup uses 8px); the floating pill's own
        // side margin handles clearing the display corners, so this stays
        // small instead of the full corner-radius inset the edge-to-edge
        // bar needed. Halved because the edge buttons' full-pitch hit
        // frames carry the other half — the visual inset is unchanged.
        .padding(.horizontal, isPhone ? 5 : 4 * scale)
        .frame(maxWidth: .infinity)
        .frame(height: interactionBarHeight)
        // The bar is fixed-height chrome, so its text caps Dynamic Type
        // growth per label via chromeBarTextCap() rather than a cap on this
        // container — several bar buttons present sheets/popovers, and
        // presented content inherits the attachment view's environment, so a
        // container-level cap would wrongly limit full modal content too.
        // Same floating material + tint + solid fill as the sidebar, so all
        // chrome reads as one Liquid Glass layer and tracks `chromeMaterial`
        // together. Clipped to a fully-rounded pill (all four corners) rather
        // than an edge-to-edge rectangle — the bar floats over the canvas with
        // a bg gutter around it, matching the sidebar-rework mockup.
        .background {
            pillShape
                .fill(T.isLight ? Color(rgbInt: 0xF2F2F7) : .black)
                .opacity(tmuxMenuBackstopOn ? 1 : 0)
                .frame(height: visualBarHeight)
                .animation(
                    tmuxMenuBackstopOn ? .easeIn(duration: 0.08) : .easeOut(duration: 0.5),
                    value: tmuxMenuBackstopOn
                )
        }
        .background {
            Color.clear
                .frame(height: visualBarHeight)
                .floatingGlass(
                    appearance.chromeMaterial,
                    tint: T.sidebarBg,
                    solidFill: T.isLight
                        ? SwiftUI.Color(rgbInt: 0xF2F2F7)
                        : SwiftUI.Color(rgbInt: 0x1C1C1E),
                    in: pillShape
                )
        }
        // Full hairline ring around the pill (was a bottom-only divider on the
        // square bar). `strokeBorder` insets the stroke so it isn't clipped by
        // the pill's own corner-clip.
        .overlay(pillShape.strokeBorder(T.border, lineWidth: 0.5).frame(height: visualBarHeight))
        .overlay(alignment: .bottom) {
            if let windowOrderErrorMessage {
                Text(verbatim: windowOrderErrorMessage)
                    .font(Typography.tesseraMono(size: 11, weight: .medium))
                    .foregroundStyle(T.red)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(T.presentationBg)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(T.red.opacity(0.45), lineWidth: 1)
                    )
                    .offset(y: 48)
                    .accessibilityLabel("Window order failed: \(windowOrderErrorMessage)")
                    .accessibilityIdentifier("tmux-window-order-error")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, verticalBarInset)
        .padding(.horizontal, Self.floatSideInset)
    }

    var body: some View {
        styledBar
        // iPadOS reserves the top edge for moving the app window. While the
        // tmux strip is present, let its native hold/scroll recognizers see
        // the first gesture there; the system gesture remains available via
        // the platform's normal deferred-edge behavior.
        .defersSystemGestures(
            on: !isPhone
                && (tmux.mode == .tmuxControl || tmuxIsDegraded)
                && !tmux.windows.isEmpty
                ? .top
                : []
        )
        .onChange(of: compactTmuxPaletteSyncKey, initial: true) { _, snapshot in
            sessionRegistry.setTmuxPaletteSnapshot(snapshot, for: sessionID)
            refreshOpenCompactPalette()
        }
        .onChange(of: commandPalette.focusRequestToken) { _, _ in
            // Terminal-responder shortcuts also open the shared palette.
            // The active chrome supplies their session-owned tmux snapshot.
            guard sessionIsActive else { return }
            refreshOpenCompactPalette(adoptSession: true)
        }
        .task(id: integrationWarningDue) { await settleIntegrationWarning() }
        .onChange(of: compactIntegrationNotice) { _, notice in
            guard isPhone,
                  commandPalette.isOpen,
                  commandPalette.currentSessionID == sessionID
            else { return }
            commandPalette.refreshNotice(notice)
        }
        .onChange(of: tmux.gridAuthority.isPeer) { _, yielded in
            guard yielded else { return }
            findController.close()
            windowListVisible = false
            stagedWindowListClose = nil
            stagedWindowListRename = nil
            pendingWindowClose = nil
            pendingWindowRename = nil
            cancelWindowReorder()
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["TESSERA_IPHONE_SESSION_HARNESS_MODE"] == "integration-popover" {
                integrationPopoverVisible = true
            }
            if ProcessInfo.processInfo.environment["TESSERA_AGENT_ATTENTION_HARNESS"] == "1" {
                switch ProcessInfo.processInfo.environment["TESSERA_AGENT_ATTENTION_AUTO_OPEN"] {
                case "1": attentionPopoverVisible = true
                case "status": statusBreakdownVisible = true
                case "palette": openCompactSwitcher()
                default: break
                }
            }
            if ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_LIST_HARNESS"] == "1",
               ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_LIST_AUTO_OPEN"] == "1" {
                windowListVisible = true
            }
            if ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_CLOSE_HARNESS"] == "1",
               ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_CLOSE_AUTO_CONFIRM"] == "1",
               let window = tmux.windows.first(where: { $0.paneCount > 1 }) {
                pendingWindowClose = PendingTmuxWindowClose(
                    window: window,
                    controlConnectionGeneration: tmux.controlConnectionGeneration
                )
            }
            #endif
        }
        .onChange(of: integrationConfirmationVisible || pendingWindowRename != nil || pendingWindowClose != nil, initial: true) { _, obscured in
            programStatusCenter.setSessionObscured(obscured, sessionID: sessionID, source: programStatusCoverSource)
        }
        .onDisappear {
            programStatusCenter.setSessionObscured(false, sessionID: sessionID, source: programStatusCoverSource)
        }
        .alert(Text(integrationConfirmationTitle), isPresented: $integrationConfirmationVisible) {
            Button("Cancel", role: .cancel) {
                pendingIntegrationAction = nil
            }
            Button(String(localized: integrationConfirmationLabel)) {
                let requestedAction = pendingIntegrationAction
                pendingIntegrationAction = nil
                guard let currentIntegrationState,
                      currentIntegrationState.supports(requestedAction),
                      let requestedAction
                else { return }
                agentCenterV2.fixIntegration(sessionID: sessionID, requestedAction: requestedAction)
                // The popover shows repair progress on the regular bar; the
                // compact bar has no anchor, and a stale flag would present
                // it unprompted after a later resize.
                if !isPhone { integrationPopoverVisible = true }
            }
        } message: {
            Text(integrationConfirmationMessage)
        }
        .alert(
            "Rename tmux window",
            isPresented: Binding(
                get: { pendingWindowRename != nil },
                set: { if !$0 { pendingWindowRename = nil } }
            )
        ) {
            TextField("Window name", text: $windowRenameText)
                .literalTextInput()
            Button("Cancel", role: .cancel) { pendingWindowRename = nil }
            Button("Rename") { submitWindowRename() }
                .disabled(windowRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The name is shared with every client attached to this tmux session.")
        }
        .alert(
            "Close tmux window?",
            isPresented: Binding(
                get: { pendingWindowClose != nil },
                set: { if !$0 { pendingWindowClose = nil } }
            ),
            presenting: pendingWindowClose
        ) { request in
            Button(closeConfirmationActionLabel(for: request.window), role: .destructive) {
                pendingWindowClose = nil
                guard request.controlConnectionGeneration == tmux.controlConnectionGeneration,
                      tmux.isWindowListHydrated,
                      tmux.windows.contains(where: { $0.id == request.window.id })
                else { return }
                dispatchSessionCommand(.closeTmuxWindow(request.window.id.description))
            }
            Button("Cancel", role: .cancel) {
                pendingWindowClose = nil
            }
        } message: { request in
            Text(closeConfirmationMessage(for: request.window))
        }
        .onChange(of: tmux.controlConnectionGeneration) {
            pendingWindowClose = nil
            cancelWindowReorder()
        }
        .onChange(of: tmux.windowOrderError) { _, error in
            guard let error, !error.isEmpty else { return }
            windowOrderErrorTask?.cancel()
            withAnimation(.easeOut(duration: 0.18)) {
                windowOrderErrorMessage = NSLocalizedString(error, comment: "tmux window ordering failure")
            }
            windowOrderErrorTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.18)) {
                    windowOrderErrorMessage = nil
                }
            }
        }
        // The popover auto-dismisses when its chevron anchor leaves the
        // hierarchy (enough windows closed that the strip fits again);
        // keep the state in sync so the chevron isn't born re-toggled.
        .onChange(of: tabStripOverflows) { _, overflows in
            if !overflows { windowListVisible = false }
        }
        .onChange(of: sessionRegistry.tmuxCloseRequest?.token) { _, _ in
            handleCompactTmuxCloseRequest()
        }
        .onChange(of: sessionRegistry.tmuxMutationRequest?.token) { _, _ in
            handleCompactTmuxMutationRequest()
        }
        .onChange(of: tmux.windows.map(\.id)) { _, windowIDs in
            if let previewWindowOrder, previewWindowOrder != windowIDs {
                cancelWindowReorder()
            }
            guard let pendingWindowClose,
                  !windowIDs.contains(pendingWindowClose.window.id)
            else { return }
            self.pendingWindowClose = nil
        }
    }

    private func handleCompactTmuxCloseRequest() {
        guard let request = sessionRegistry.tmuxCloseRequest,
              tmux.mode == .tmuxControl,
              !tmuxIsDegraded,
              tmux.isWindowListHydrated
        else { return }

        switch request.action {
        case .pane(let requestedSessionID, let windowID, let paneID):
            guard requestedSessionID == sessionID,
                  let window = tmux.windows.first(where: { $0.id == windowID }),
                  window.paneCount > 1,
                  window.panes.contains(where: { $0.id == paneID })
            else { return }
            dispatchSessionCommand(.closeTmuxPane(paneID.description))

        case .window(let requestedSessionID, let windowID):
            guard requestedSessionID == sessionID,
                  let window = tmux.windows.first(where: { $0.id == windowID })
            else { return }
            if window.paneCount > 1 || tmux.isWindowLayoutPending(windowID) {
                pendingWindowClose = PendingTmuxWindowClose(
                    window: window,
                    controlConnectionGeneration: tmux.controlConnectionGeneration
                )
            } else {
                dispatchSessionCommand(.closeTmuxWindow(windowID.description))
            }
        }
    }

    private func handleCompactTmuxMutationRequest() {
        guard let request = sessionRegistry.tmuxMutationRequest,
              tmux.mode == .tmuxControl,
              !tmuxIsDegraded
        else { return }
        switch request.action {
        case .split(let requestedSessionID, let paneID, let axis):
            guard requestedSessionID == sessionID else { return }
            dispatchSessionCommand(.splitTmuxPane(
                paneID.description,
                axis: axis == .horizontal ? .horizontal : .vertical,
                before: false
            ))
        case .rename(let requestedSessionID, let windowID, let name):
            guard requestedSessionID == sessionID else { return }
            dispatchSessionCommand(.renameTmuxWindow(windowID.description, name: name))
        case .moveWindow(let requestedSessionID, let windowID, let move):
            guard requestedSessionID == sessionID else { return }
            dispatchSessionCommand(.moveTmuxWindow(windowID.description, move: move))
        case .renumberWindows(let requestedSessionID):
            guard requestedSessionID == sessionID else { return }
            dispatchSessionCommand(.renumberTmuxWindows)
        }
    }

    private var compactBarCore: some View {
        compactBarContent
    }

    private var compactBarContent: some View {
        // Spacing 0 — each icon button's 40pt full-pitch hit frame carries
        // 1pt of the old 2pt gap on each side, so glyph centers stay put
        // while the hit frames meet edge-to-edge.
        HStack(spacing: 0) {
            compactIconButton(
                systemName: "chevron.left",
                label: "Back — session keeps running",
                action: onBack
            )

            Button(action: openCompactSwitcher) {
                HStack(spacing: 6) {
                    // The phone bar has no room for a separate warning
                    // control; the dot carries it and the switcher it opens
                    // presents the notice and its action.
                    AttentionStatusDot(
                        color: statusDotColor,
                        attention: compactIntegrationNotice != nil,
                        attentionColor: T.amber
                    )
                    Text(host.name.isEmpty ? host.address : host.name)
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .foregroundStyle(T.fg)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(T.fgMuted)
                }
                .chromeBarTextCap()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .frame(minWidth: 44, maxWidth: .infinity)
            .buttonStyle(.plain)
            .accessibilityLabel(compactSwitcherAccessibilityLabel)
            .accessibilityIdentifier("compact-session-switcher")

            if (tmux.mode == .tmuxControl || tmuxIsDegraded),
               !tmux.windows.isEmpty {
                compactIconButton(
                    systemName: "plus",
                    label: "New tmux window",
                    action: { dispatchSessionCommand(.createTmuxWindow) }
                )
                .disabled(tmuxIsDegraded || tmux.gridAuthority.isPeer)
                .opacity((tmuxIsDegraded || tmux.gridAuthority.isPeer) ? 0.45 : 1)
                .accessibilityHint(
                    tmuxIsDegraded ? "Unavailable while tmux sync is offline" : ""
                )
                .accessibilityIdentifier("tmux-new-window")
            }

            compactIconButton(
                systemName: "magnifyingglass",
                label: "Find in terminal",
                isToggled: findController.isOpen
            ) {
                findController.isOpen ? findController.close() : findController.open()
            }
            .disabled(tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
            compactFilesButton
            CompactForwardingStatusButton(
                manager: forwarderManager,
                T: T,
                monitorsServices: sessionIsActive && appPhase.isActive
            )
            if let continuityActions {
                compactContinuityButton(actions: continuityActions)
            }
            compactIconButton(
                systemName: "xmark",
                label: "Disconnect",
                tint: T.red,
                action: onDisconnect
            )
            .accessibilityIdentifier("session-disconnect")
        }
    }

    private func compactIconButton(
        systemName: String,
        label: LocalizedStringKey,
        isToggled: Bool = false,
        tint: SwiftUI.Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            compactIconLabel(
                systemName: systemName,
                isToggled: isToggled,
                tint: tint
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func compactContinuityButton(
        actions: SessionContinuityActions
    ) -> some View {
        Button {
            continuityPopoverVisible.toggle()
        } label: {
            compactIconLabel(
                systemName: "rectangle.on.rectangle.angled",
                isToggled: continuityPopoverVisible
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue on another device")
        .accessibilityIdentifier("session-continuity-menu")
        .popover(
            isPresented: $continuityPopoverVisible,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            continuityPopover(actions: actions)
        }
    }

    private func compactIconLabel(
        systemName: String,
        isToggled: Bool = false,
        tint: SwiftUI.Color? = nil
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint ?? (isToggled ? T.accent : T.fgMuted))
            .frame(width: 38, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isToggled ? T.accentSoft : SwiftUI.Color.clear)
            )
            // 38pt visual box inside the bar's full 40pt button pitch. The
            // bar owns every pitch, so the system cannot assign a tap to an
            // unrelated floating control.
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
    }

    private var filesButton: some View {
        ZStack(alignment: .topTrailing) {
            chromeIconButton(
                systemName: "folder",
                isToggled: filesPanelOpen,
                action: onToggleFiles
            )
            fileTransferAttentionGlyph(size: 9)
                .offset(x: -2 * scale, y: 1 * scale)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(filesAccessibilityLabel)
    }

    private var compactFilesButton: some View {
        ZStack(alignment: .topTrailing) {
            compactIconButton(
                systemName: "folder",
                label: "Files",
                isToggled: filesPanelOpen,
                action: onToggleFiles
            )
            fileTransferAttentionGlyph(size: 10)
                .offset(x: -2, y: 5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(filesAccessibilityLabel)
    }

    @ViewBuilder
    private func fileTransferAttentionGlyph(size: CGFloat) -> some View {
        switch fileTransferAttention {
        case .none:
            EmptyView()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(T.presentationBg, T.green)
                .accessibilityHidden(true)
        case .failure:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(T.presentationBg, T.red)
                .accessibilityHidden(true)
        }
    }

    private var filesAccessibilityLabel: LocalizedStringKey {
        switch fileTransferAttention {
        case .none: "Files"
        case .success: "Files, background upload complete"
        case .failure: "Files, background upload failed"
        }
    }

    private func openCompactSwitcher() {
        let sync = compactTmuxPaletteSyncKey
        let activeTitle = sync.activeWindowID.flatMap { activeID in
            sync.windows.first(where: { $0.id == activeID })?.title
        }
        commandPalette.open(
            sessions: sessionRegistry.activeSessions,
            paneTitles: activeTitle.map { [sessionID: $0] } ?? [:],
            lastTouched: sessionRegistry.lastTouched,
            tmuxWindows: sync.windows,
            currentSessionID: sessionID,
            activeWindowID: tmux.activeWindowId,
            activePaneID: tmux.activePaneId,
            includesHome: true,
            allowsTmuxMutation: sync.allowsMutation,
            canReorderTmuxWindows: sync.canReorder,
            canTidyTmuxWindows: sync.canTidy,
            isTmuxWindowMutationPending: sync.isPending,
            tmuxWindowOrderError: sync.error,
            notice: compactIntegrationNotice,
            onNoticeAction: handleCompactIntegrationNotice
        )
    }

    private var compactTmuxPaletteSyncKey: CommandPaletteTmuxSnapshot {
        CommandPaletteTmuxSnapshot(tmux: tmux, isDegraded: tmuxIsDegraded) { paneID in
            agentCenterV2.paneAgentProvider(sessionID: sessionID, paneID: paneID.rawValue)
        }
    }

    private func refreshOpenCompactPalette(adoptSession: Bool = false) {
        guard commandPalette.isOpen,
              commandPalette.currentSessionID == sessionID || adoptSession
        else { return }
        let sync = compactTmuxPaletteSyncKey
        let activeTitle = sync.activeWindowID.flatMap { activeID in
            sync.windows.first(where: { $0.id == activeID })?.title
        }
        commandPalette.refreshSnapshot(
            sessions: sessionRegistry.activeSessions,
            paneTitles: activeTitle.map { [sessionID: $0] } ?? [:],
            lastTouched: sessionRegistry.lastTouched,
            tmuxWindows: sync.windows,
            currentSessionID: sessionID,
            activeWindowID: sync.activeWindowID,
            activePaneID: sync.activePaneID,
            allowsTmuxMutation: sync.allowsMutation,
            canReorderTmuxWindows: sync.canReorder,
            canTidyTmuxWindows: sync.canTidy,
            isTmuxWindowMutationPending: sync.isPending,
            tmuxWindowOrderError: sync.error
        )
    }

    private var compactSwitcherAccessibilityLabel: String {
        guard let notice = compactIntegrationNotice else {
            return String(localized: "Switch session, window, or pane")
        }
        return String(
            localized: "Switch session, window, or pane. \(notice.title)",
            comment: "VoiceOver label for the compact switcher. The argument is an agent-integration notice."
        )
    }

    private var compactIntegrationNotice: CommandPaletteNotice? {
        guard integrationWarningVisible, let currentIntegrationState else { return nil }
        return CommandPaletteNotice(
            title: String(localized: currentIntegrationState.title),
            message: String(localized: currentIntegrationState.message),
            actionLabel: currentIntegrationState.actionLabel.map { String(localized: $0) }
        )
    }

    private func handleCompactIntegrationNotice() {
        // The notice only offers a button for an actionable state and is
        // refreshed while open, so a missing action has nothing to confirm.
        guard let action = currentIntegrationState?.action else { return }
        pendingIntegrationAction = action
        integrationConfirmationVisible = true
    }

    private func closeConfirmationActionLabel(
        for window: TmuxController.WindowInfo
    ) -> String {
        window.paneCount > 1
            ? String(
                localized: "Close all \(window.paneCount) panes",
                comment: "Destructive confirm button when the tmux window holds several panes"
            )
            : String(localized: "Close window", comment: "Destructive confirm button for a single-pane tmux window")
    }

    private func closeConfirmationMessage(
        for window: TmuxController.WindowInfo
    ) -> String {
        guard window.paneCount > 1 else {
            // Reachable only while the window's details query is in flight:
            // the pane count is still a guess (link-window/move-window can
            // add an already-split window), so the close fails closed with
            // a generic confirmation instead of a promptless kill.
            return String(
                localized: "“\(window.name)” is still syncing its pane layout. Closing this window will close every pane it contains.",
                comment: "Close confirmation while the pane count is still unknown."
            )
        }
        return String(
            localized: "“\(window.name)” contains \(window.paneCount) panes. Closing this window will close every pane in it.",
            comment: "Close confirmation. Pluralized on the pane count."
        )
    }

    /// A warning decision applies to this terminal right now. Probes and
    /// foreground changes pass through warning states on the way to ready, so
    /// chrome shows one only after it holds (`settleIntegrationWarning`).
    private var integrationWarningDue: Bool {
        appearance.agentCenterEnabled
            && state == .connected
            && currentIntegrationState?.showsWarning == true
    }

    /// Surfaces also re-check the raw decision, so a disconnect or a cleared
    /// warning hides them in the same frame rather than after the task runs.
    private var integrationWarningVisible: Bool {
        integrationWarningPresented && integrationWarningDue
    }

    private func settleIntegrationWarning() async {
        guard integrationWarningDue else {
            // A popover left armed would reopen with the next warning.
            if integrationWarningPresented { integrationPopoverVisible = false }
            integrationWarningPresented = false
            return
        }
        guard !integrationWarningPresented else { return }
        let delay = AgentIntegrationCheckPolicy.warningPresentationDelayMilliseconds
        do { try await Task.sleep(for: .milliseconds(Int(delay))) } catch { return }
        integrationWarningPresented = integrationWarningDue
    }

    private var currentIntegrationState: AgentIntegrationWarningState? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TESSERA_IPHONE_SESSION_HARNESS_MODE"]?.hasPrefix("integration") == true {
            return .resolved(
                installation: .current,
                target: AgentCurrentIntegrationTarget(
                    location: AgentLocation(
                        sessionID: sessionID,
                        hostName: host.name,
                        transportLabel: host.transport == .mosh ? "mosh" : "ssh",
                        tmuxSessionName: nil,
                        windowID: nil,
                        windowName: nil,
                        paneID: nil
                    ),
                    foreground: .shell,
                    processIDs: [42],
                    shellIntegrationActive: false,
                    agentIntegrationActive: false
                )
            )
        }
        #endif
        return agentCenterV2.integrationState(sessionID: sessionID)
    }

    private var agentIntegrationWarningButton: some View {
        Button {
            integrationPopoverVisible = true
        } label: {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(T.amber)
                .frame(width: 28 * scale, height: 24 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .fill(T.amber.opacity(0.12))
                )
                .frame(width: 44, height: 44)
                .padding(.horizontal, 4 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentIntegrationState?.title ?? "Agent integration")
        .accessibilityHint("Shows the safe action for this terminal")
        .accessibilityIdentifier("agent-integration-warning")
        .popover(isPresented: $integrationPopoverVisible, arrowEdge: .top) {
            if let currentIntegrationState {
                SessionAgentIntegrationWarningPopover(
                    state: currentIntegrationState,
                    T: T,
                    onFix: {
                        pendingIntegrationAction = currentIntegrationState.action
                        integrationPopoverVisible = false
                        integrationConfirmationVisible = true
                    },
                    onSecondaryFix: {
                        pendingIntegrationAction = currentIntegrationState.secondaryAction
                        integrationPopoverVisible = false
                        integrationConfirmationVisible = true
                    }
                )
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var integrationConfirmationTitle: LocalizedStringResource {
        switch pendingIntegrationAction {
        case .installAndApply: "Install and enable integration?"
        case .installOnly: "Install agent integration?"
        case .apply: "Enable integration here?"
        case .persistAndApply: "Enable integration automatically?"
        case .check: "Check agent integration?"
        case .retry: "Retry integration check?"
        case nil: "Agent integration"
        }
    }

    private var integrationConfirmationMessage: LocalizedStringResource {
        switch pendingIntegrationAction {
        case .installAndApply:
            "Writes Tessera hook files and provider shims, then loads them when this exact terminal is at an empty bash or zsh prompt. It never types into a running agent or another program."
        case .installOnly:
            "Writes Tessera hook files and provider shims without typing into the running foreground program. Helper updates take effect immediately. Relaunch is only needed if the agent has not loaded its lifecycle hooks."
        case .apply:
            "Types one guarded source command so agents launched here report precise status. Continue only at an empty bash or zsh prompt."
        case .persistAndApply:
            "Adds one guarded activation line to this exact shell's startup file, then loads it here. Continue only at an empty bash or zsh prompt."
        case .check, .retry:
            "Runs a read-only host check to verify the integration state for this terminal."
        case nil:
            ""
        }
    }

    private var integrationConfirmationLabel: LocalizedStringResource {
        switch pendingIntegrationAction {
        case .installAndApply: "Install and enable"
        case .installOnly: "Install"
        case .apply: "Enable here"
        case .persistAndApply: "Enable automatically"
        case .check: "Check"
        case .retry: "Retry"
        case nil: "Continue"
        }
    }

    private var agentAttentionButton: some View {
        let counts = programStatusCenter.counts(agentCenter: agentCenterV2)
        let tint = (counts.tone ?? .finished).color(T)
        let agents = agentCenterV2.attentionBadgeCounts
        let summary = ProgramStatusWords.countSummary(counts)

        // The chip lists what needs the user so each can be reached in its
        // own pane; Agent Center stays one row away in the list's footer.
        return Button { attentionPopoverVisible = true } label: {
            HStack(spacing: 5 * scale) {
                // Sparkles while an agent is counted; otherwise the terminal
                // symbol "open pane" uses.
                Image(systemName: agents.waiting + agents.finished > 0 ? "sparkles" : "terminal")
                    .font(.system(size: 10 * scale, weight: .semibold))
                Text(verbatim: summary)
                    .font(Typography.tesseraMono(size: 10 * scale, weight: .medium))
                    .lineLimit(1)
            }
            .chromeBarTextCap()
            .foregroundStyle(tint)
            .padding(.horizontal, 8 * scale)
            .frame(height: 24 * scale)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.36), lineWidth: 1))
            // Bar spacing is 0 — own half of each 8pt-scaled gap inside
            // the hit frame so the capsule keeps its position.
            .padding(.horizontal, 4 * scale)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
        .accessibilityHint("Shows what needs attention")
        .accessibilityIdentifier("agent-attention-summary")
        .popover(isPresented: $attentionPopoverVisible, arrowEdge: .top) {
            AgentAttentionPopover(
                entries: agentCenterV2.attentionEntries(),
                programItems: programStatusCenter.programItems(agentCenter: agentCenterV2),
                T: T,
                windowLabel: attentionWindowLabel,
                agentStatus: attentionAgentStatus,
                onOpenPane: { entry in
                    attentionPopoverVisible = false
                    openAttentionPane(entry.threadID)
                },
                onReview: { entry in
                    attentionPopoverVisible = false
                    agentCenterV2.reviewAttentionThread(entry.threadID)
                },
                onOpenProgram: { item in
                    attentionPopoverVisible = false
                    programStatusCenter.open(item)
                },
                onOpenAgentCenter: appearance.agentCenterEnabled ? onOpenAgentCenter.map { open in
                    {
                        attentionPopoverVisible = false
                        open()
                    }
                } : nil
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    /// An agent row's state with the agent's own report merged in, exactly
    /// as its tab shows it.
    private func attentionAgentStatus(_ entry: AgentAttentionEntry) -> AgentAttentionPopover.AgentStatus? {
        let needsInput = entry.kind == .needsInput
        guard let binding = entry.terminalBinding else {
            return .init(attention: needsInput ? .needsInput(nil) : .finished, message: nil)
        }
        let key: ProgramStatusTerminalKey = binding.paneID.flatMap(Int.init).map { .pane(PaneId($0)) } ?? .raw
        let program = programStatusCenter.terminal(sessionID: binding.liveSessionID, key: key)
        guard let attention = ChromeAttentionMerge.attention(
            agentNeedsInput: needsInput,
            agentUnreadCompletion: !needsInput,
            program: program
        ) else { return nil }
        let native = program?.attention == attention ? program?.primaryEntry?.message : nil
        return .init(attention: attention, message: native)
    }

    /// Focuses the agent's exact pane (switching to its session when that is
    /// already live). A pane that can no longer be proven — closed, moved, or
    /// on a dropped connection — lands on the thread in Agent Center instead,
    /// where the reason is shown. No connection is ever started from here.
    private func openAttentionPane(_ threadID: AgentThreadID) {
        let coordinator = agentCenterV2
        Task { @MainActor in
            let revealed = await coordinator.revealAttentionTerminal(threadID: threadID)
            if !revealed { coordinator.reviewAttentionThread(threadID) }
        }
    }

    /// The strip's own numbering for a window of this session; nil for an
    /// agent in another session.
    private func attentionWindowLabel(_ binding: AgentTerminalBinding) -> AgentAttentionPopover.WindowLabel? {
        guard binding.liveSessionID == sessionID,
              let rawWindowID = binding.windowID,
              let index = tmux.windows.firstIndex(where: { String($0.id.rawValue) == rawWindowID })
        else { return nil }
        return .init(position: index + 1, name: tmux.windows[index].name)
    }

    /// Shared icon-button style for the bar's leading sidebar toggle
    /// and trailing home / find buttons. 28×24pt visual box at the
    /// 32pt baseline; both the symbol and frame scale with `scale`
    /// so the icons stay proportional when the bar grows or shrinks.
    /// `isToggled: true` lights up `accentSoft` so on-state buttons
    /// (e.g. the find toggle while the bar is open) read like the
    /// active tmux tab.
    private func chromeIconButton(
        systemName: String,
        isToggled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            chromeIconLabel(systemName: systemName, isToggled: isToggled)
        }
        .buttonStyle(.plain)
    }

    private func continuityButton(
        actions: SessionContinuityActions
    ) -> some View {
        chromeIconButton(
            systemName: "rectangle.on.rectangle.angled",
            isToggled: continuityPopoverVisible
        ) {
            continuityPopoverVisible.toggle()
        }
        .accessibilityLabel("Continue on another device")
        .accessibilityIdentifier("session-continuity-menu")
        .popover(
            isPresented: $continuityPopoverVisible,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            continuityPopover(actions: actions)
        }
    }

    private func continuityPopover(
        actions: SessionContinuityActions
    ) -> some View {
        ContinuityActionPopover(
            T: T,
            onContinue: {
                stageContinuityAction(.continueSession)
            },
            onSetUpAndContinue: {
                stageContinuityAction(.setUpAndContinue)
            }
        )
        .presentationCompactAdaptation(.popover)
        // Starting pairing removes this bar affordance from ContentView.
        // Wait until its popover has fully dismissed so the anchor never
        // disappears halfway through the system's dismissal animation.
        .onDisappear {
            performPendingContinuityAction(using: actions)
        }
    }

    private func stageContinuityAction(_ action: PendingContinuityAction) {
        pendingContinuityAction = action
        continuityPopoverVisible = false
    }

    private func performPendingContinuityAction(
        using actions: SessionContinuityActions
    ) {
        let action = pendingContinuityAction
        pendingContinuityAction = nil
        switch action {
        case .continueSession:
            actions.continueSession()
        case .setUpAndContinue:
            actions.setUpAndContinue()
        case nil:
            break
        }
    }

    private func chromeIconLabel(
        systemName: String,
        isToggled: Bool = false
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14 * scale, weight: .medium))
            .foregroundStyle(isToggled ? T.accent : T.fgMuted)
            .frame(width: 28 * scale, height: 24 * scale)
            .background(
                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                    .fill(isToggled ? T.accentSoft : SwiftUI.Color.clear)
            )
            // 28×24 visual box inside a full-pitch hit frame: the scaled bar
            // cannot fit 44pt frames without moving glyphs, so adjacent
            // controls share full-pitch hit frames that meet but never overlap.
            .frame(width: 36 * scale)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    // MARK: - Passthrough layout

    @ViewBuilder
    private var passthroughStatus: some View {
        hostStatusButton {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7 * scale, height: 7 * scale)

                // Text(verbatim:) — interpolating the Int directly localizes
                // it (port 2222 renders as "2,222").
                Text(verbatim: "\(host.user)@\(host.address):\(host.port)")
                    .font(Typography.tesseraMono(size: 13 * scale, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detailText {
                    Text(detailText)
                        .font(Typography.tesseraMono(size: 12 * scale))
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                }
            }
            .chromeBarTextCap()
            // Bar spacing is 0 — own half of each 8pt-scaled gap inside
            // the hit frame so the text keeps its position.
            .padding(.horizontal, 4 * scale)
            .contentShape(Rectangle())
        }
    }

    // MARK: - tmux tab strip layout

    @ViewBuilder
    private var tabStrip: some View {
        let windows = displayedTmuxWindows
        // Compact host pill on the leading edge — status dot, host
        // identity, then a small-caps "tmux" tag separated by a thin
        // dot. The tag carries the same "you're in tmux mode" signal
        // the old "name · tmux" string did, but visually distinct
        // typography keeps the host name readable on its own.
        hostStatusButton {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7 * scale, height: 7 * scale)
                Text(host.name.isEmpty ? host.address : host.name)
                    .font(Typography.tesseraMono(size: 12 * scale, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Text(verbatim: "·")
                    .font(Typography.tesseraMono(size: 11 * scale))
                    .foregroundStyle(T.fgDim)
                Text("tmux")
                    .font(Typography.tesseraSans(size: 10 * scale, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(tmuxIsDegraded ? T.amber : T.fgMuted)
                if tmuxIsDegraded {
                    Text("sync offline")
                        .font(Typography.tesseraMono(size: 11 * scale, weight: .semibold))
                        .foregroundStyle(T.amber)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(
                            Capsule()
                                .fill(T.amber.opacity(0.10))
                        )
                }
            }
            .chromeBarTextCap()
            // Bar spacing is 0 — own half of each 8pt-scaled gap inside
            // the hit frame so the pill keeps its position.
            .padding(.horizontal, 4 * scale)
            .contentShape(Rectangle())
        }

        // Horizontal scroll so a dozen tmux windows can coexist with a
        // narrow viewport; the typical case (1-4 windows) fits
        // comfortably without any scroll indicators appearing. The reader
        // keeps the active tab revealed on every switch (tap, ⌘1-9,
        // palette, or the overflow list) — a selection alone never used
        // to scroll the strip, leaving the active tab clipped offscreen.
        ScrollViewReader { tabStripProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6 * scale) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        tabButton(
                            number: index + 1,
                            window: window,
                            isActive: window.id == tmux.activeWindowId,
                            isDegraded: tmuxIsDegraded
                        )
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TmuxTabWindowFramesKey.self,
                                    value: [window.id: geo.frame(in: .global)]
                                )
                            }
                        }
                    }
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: windows.map(\.id))
                .onGeometryChange(for: CGRect.self) { geo in
                    geo.frame(in: .scrollView)
                } action: { frame in
                    tabStripContentFrame = frame
                    updateTabStripOverflow()
                }
            }
            .onPreferenceChange(TmuxTabWindowFramesKey.self) { tabWindowFrames = $0 }
            // Alpha-fade the clipped edge(s) instead of a hard cut. The
            // mask is fully opaque when the strip fits (or is at an end),
            // so the common 1-4 window case renders pixel-identical.
            .mask(tabStripFadeMask)
            .onChange(of: tmux.activeWindowId) { _, windowID in
                guard let windowID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    tabStripProxy.scrollTo(windowID, anchor: nil)
                }
            }
            .onChange(of: reorderScrollToken) { _, _ in
                let windowID = reorderScrollTarget
                guard let windowID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    tabStripProxy.scrollTo(windowID, anchor: nil)
                }
            }
            .onAppear {
                // Defer a turn — at onAppear the strip hasn't laid out yet,
                // so an immediate scrollTo is a no-op.
                guard let windowID = tmux.activeWindowId else { return }
                Task { @MainActor in
                    await Task.yield()
                    tabStripProxy.scrollTo(windowID, anchor: nil)
                }
            }
        }
        .allowsHitTesting(!tmux.gridAuthority.isPeer)
        .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.width
        } action: { width in
            tabStripVisibleWidth = width
            updateTabStripOverflow()
        }
        .onGeometryChange(for: CGRect.self) { geo in
            geo.frame(in: .global)
        } action: { tabStripViewportFrame = $0 }
        // Bar spacing is 0 — keep the strip's 8pt-scaled gaps to the host
        // pill and the `+` button (which carry 4 inside their hit frames).
        .padding(.horizontal, 4 * scale)

        // Overflow chevron — only when the strip genuinely overflows, so
        // the bar is unchanged until tabs no longer fit. Opens a window
        // list touch users can pick from and reorder vertically.
        if tabStripOverflows {
            chromeIconButton(
                systemName: "chevron.down",
                isToggled: windowListVisible,
                action: { windowListVisible.toggle() }
            )
            .disabled(tmux.gridAuthority.isPeer)
            .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
            .accessibilityLabel("Show all windows")
            .accessibilityIdentifier("tmux-tab-overflow")
            .popover(
                isPresented: $windowListVisible,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                TmuxWindowListPopover(
                    tmux: tmux,
                    sessionID: sessionID,
                    isDegraded: tmuxIsDegraded,
                    T: T,
                    onSelect: { position in
                        windowListVisible = false
                        selectWindow(atPosition: position)
                    },
                    onClose: { window in
                        requestWindowClose(window, fromWindowList: true)
                    },
                    onRename: { window in
                        stagedWindowListRename = window
                        windowListVisible = false
                    },
                    onSplit: { window, option in
                        windowListVisible = false
                        performSplit(option, window: window)
                    },
                    onMenuTouch: tmuxMenuTouchChanged,
                    onMenuPresence: tmuxMenuPresenceChanged,
                    dispatchSessionCommand: dispatchSessionCommand,
                    onNewWindow: {
                        windowListVisible = false
                        dispatchSessionCommand(.createTmuxWindow)
                    }
                )
                .presentationCompactAdaptation(.popover)
                // Fires when the popover has fully left the screen — the
                // reliable point to present a close confirmation staged by
                // the list without racing the dismiss transition.
                .onDisappear {
                    presentStagedWindowListClose()
                    presentStagedWindowListRename()
                }
            }
        }

        // New-window button. Lives inside the tabStrip branch on
        // purpose so it only appears when tmux -CC is actively
        // managing windows — there's no equivalent action in
        // passthrough mode (a raw shell has no concept of "another
        // window"). Same effect as ⌘T. Shares the rounded-square
        // chrome-icon style with the toggle / find / home buttons so
        // the bar reads as one consistent set (matching the mockup,
        // where new-window is a plain `+` icon, not a ringed circle).
        chromeIconButton(
            systemName: "plus",
            action: { dispatchSessionCommand(.createTmuxWindow) }
        )
            .disabled(tmuxIsDegraded || tmux.gridAuthority.isPeer)
            .opacity((tmuxIsDegraded || tmux.gridAuthority.isPeer) ? 0.45 : 1)
            .accessibilityLabel("New tmux window")
            .accessibilityHint(
                tmuxIsDegraded ? "Unavailable while tmux sync is offline" : ""
            )
            .accessibilityIdentifier("tmux-new-window")
    }

    /// A single tmux-window tab. Tapping its label switches through the same
    /// path ⌘1-9 takes (`selectWindow(atPosition:)`); its X targets the window
    /// id directly, so closing an inactive tab never selects it first.
    private func tabButton(
        number: Int,
        window: TmuxController.WindowInfo,
        isActive: Bool,
        isDegraded: Bool
    ) -> some View {
        let name = window.name
        let windowID = window.id.rawValue
        let hasPendingBell = appearance.bellVisualEnabled
            && !isActive
            && tmux.bellingWindows.contains(windowID)
        let glowing = appearance.bellVisualEnabled
            && bellController.shouldGlow(forWindowID: windowID, sessionID: host.id)
        // Agents and programs reporting OSC 7501 share one cue: the window's
        // highest-precedence pane. The active window is already being looked
        // at, so only input requests show there.
        let cue = programStatusCenter.windowCue(
            sessionID: sessionID,
            windowID: windowID,
            agentCenter: agentCenterV2
        )
        let hasAgent = cue.hasAgent
        let agentNeedsInput = cue.tone == .needsInput
        let agentHasUnreadFinished = !isActive && (cue.tone == .finished || cue.tone == .failed)
        let resultTint = cue.tone == .failed ? T.red : T.green
        let closeIsAvailable = !isDegraded
            && tmux.mode == .tmuxControl
            && tmux.isWindowListHydrated
            && !tmux.gridAuthority.isPeer
        // Confirmation contract: closing a window prompts when it would take
        // 2+ panes with it — and, transiently, while the `%window-add`
        // details query is still in flight, because until that reply lands
        // the pane count is a guess (`link-window`/`move-window` can add a
        // window that is already split). Once the query answers, an unknown
        // layout means genuinely single-pane and the close is immediate —
        // never a permanent "still loading" prompt.
        let closeNeedsConfirmation = window.paneCount > 1
            || tmux.isWindowLayoutPending(window.id)

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                    if hasAgent {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9 * scale, weight: .semibold))
                            .foregroundStyle(
                                agentNeedsInput ? T.amber
                                    : (agentHasUnreadFinished ? resultTint : T.fgMuted)
                            )
                            .shadow(
                                color: agentNeedsInput ? T.amber.opacity(0.55)
                                    : (agentHasUnreadFinished ? resultTint.opacity(0.5) : .clear),
                                radius: 3 * scale
                            )
                            .accessibilityLabel(
                                agentNeedsInput ? "agent needs input"
                                    : (agentHasUnreadFinished
                                        ? (cue.tone == .failed ? "agent failed" : "agent just finished")
                                        : "agent active")
                            )
                    }
                    Text(verbatim: name)
                        .font(Typography.tesseraMono(size: 12 * scale, weight: isActive ? .medium : .regular))
                        .foregroundStyle(
                            agentHasUnreadFinished && !isDegraded
                                ? resultTint
                                : (isActive
                                ? (isDegraded ? T.amber : T.fg)
                                : (isDegraded ? T.fgDim : T.fgMuted))
                        )
                        .lineLimit(1)
                    if let shortcutNumber = TmuxWindowShortcutHint.digit(
                        forPosition: number,
                        windowCount: displayedTmuxWindows.count
                    ) {
                        Text(Chord([.command], .character(Character("\(shortcutNumber)")))
                                .rendered(appearance.modifierNotation))
                            .font(Typography.tesseraMono(size: 10.5 * scale))
                            .foregroundStyle(
                                isActive
                                    ? (isDegraded ? T.amber : T.accent)
                                    : T.fgFaint
                            )
                    }
            }
            .chromeBarTextCap()
            .padding(.leading, 11 * scale)
            // No trailing padding: the 7pt-scaled gap before the X belongs
            // to the close button's hit frame.
            .frame(minWidth: 44)
            .frame(height: 24 * scale)
            .frame(height: max(44, 32 * scale))
            .contentShape(Rectangle())
            .overlay {
                TmuxWindowInteractionSurface(
                    enabled: !isDegraded && !tmux.gridAuthority.isPeer,
                    accessibilityLabel: tabAccessibilityLabel(
                        window: window,
                        position: number,
                        status: tabStatusWords(tone: cue.tone, isActive: isActive)
                    ),
                    menuSections: tabMenuSections(window: window, position: number),
                    moveActions: tabMoveAccessibilityActions(window: window, position: number),
                    onTap: { selectWindow(atPosition: number) },
                    onTouchActive: tmuxMenuTouchChanged,
                    onMenuPresence: tmuxMenuPresenceChanged,
                    onReorder: { phase in handleTabReorder(phase, window: window) }
                )
            }
            .accessibilityHint(
                isDegraded
                    ? LocalizedStringKey("Unavailable while tmux sync is offline")
                    : ""
            )
            .accessibilityIdentifier("tmux-window-\(windowID)-tab")

            TmuxTabCloseButton(
                name: name,
                windowID: windowID,
                isActive: isActive,
                isAvailable: closeIsAvailable,
                accessibilityHint: closeIsAvailable
                    ? (closeNeedsConfirmation
                        ? "Asks before closing every pane in this window"
                        : "Closes this window")
                    : (isDegraded
                        ? "Unavailable while tmux sync is offline"
                        : "Unavailable while tmux window details are syncing"),
                scale: scale,
                T: T
            ) {
                requestWindowClose(window)
            }
        }
        .frame(height: 24 * scale)
        .opacity(tmux.gridAuthority.isPeer ? 0.45 : 1)
        .background(
            // Capsule-rounded tab (radius = half the height), matching the
            // mockup's fully-rounded pills, rather than the prior 6pt nubs.
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(
                    tabBackground(
                        isActive: isActive,
                        isDegraded: isDegraded,
                        unreadResultTint: agentHasUnreadFinished ? resultTint : nil
                    )
                )
        )
        .overlay {
            if glowing {
                BellGlowOverlay(color: T.accent)
                    .id(bellController.lastBellAt)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if agentNeedsInput || agentHasUnreadFinished {
                Rectangle()
                    .fill(agentNeedsInput ? T.amber : resultTint)
                    .frame(height: max(1, 1.2 * scale))
                    .shadow(
                        color: (agentNeedsInput ? T.amber : resultTint).opacity(0.7),
                        radius: 3 * scale
                    )
                    .padding(.horizontal, 5 * scale)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hasPendingBell {
                Circle()
                    .fill(T.accent)
                    .frame(width: 5 * scale, height: 5 * scale)
                    .padding(EdgeInsets(top: 2 * scale, leading: 0, bottom: 0, trailing: 3 * scale))
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        // Keep the row and scroll-view content at least 44pt tall so the
        // native interaction surface is not clipped by the visual pill.
        .frame(height: max(44, 32 * scale))
        .offset(x: tabDragOffset(for: window.id))
        .scaleEffect(draggingWindowID == window.id ? 1.04 : 1)
        .shadow(
            color: draggingWindowID == window.id ? Color.black.opacity(0.35) : .clear,
            radius: draggingWindowID == window.id ? 8 : 0,
            y: draggingWindowID == window.id ? 3 : 0
        )
        .zIndex(draggingWindowID == window.id ? 10 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: hasPendingBell)
    }

    private var displayedTmuxWindows: [TmuxController.WindowInfo] {
        guard let previewWindowOrder else { return tmux.windows }
        let byID = Dictionary(uniqueKeysWithValues: tmux.windows.map { ($0.id, $0) })
        guard Set(previewWindowOrder) == Set(byID.keys) else { return tmux.windows }
        return previewWindowOrder.compactMap { byID[$0] }
    }

    /// The tab's merged cue in words, for VoiceOver; the active tab shows
    /// only input requests, like its visual cue.
    private func tabStatusWords(tone: ChromeAttentionTone?, isActive: Bool) -> String? {
        switch tone {
        case .needsInput?: ProgramStatusWords.attention(.needsInput(nil))
        case .failed? where !isActive: ProgramStatusWords.attention(.failed)
        case .finished? where !isActive: ProgramStatusWords.attention(.finished)
        default: nil
        }
    }

    private func tabAccessibilityLabel(
        window: TmuxController.WindowInfo,
        position: Int,
        status: String? = nil
    ) -> String {
        guard let index = window.index, index != position else {
            guard let status else { return String(localized: "\(window.name), window \(position)") }
            return String(
                localized: "\(window.name), window \(position), \(status)",
                comment: "tmux tab for VoiceOver. Arguments: window name, position, attention words."
            )
        }
        guard let status else { return String(localized: "\(window.name), window \(position), tmux index \(index)") }
        return String(
            localized: "\(window.name), window \(position), tmux index \(index), \(status)",
            comment: "tmux tab for VoiceOver. Arguments: window name, position, tmux index, attention words."
        )
    }

    private func tabMenuSections(
        window: TmuxController.WindowInfo,
        position: Int
    ) -> [TmuxWindowMenuSection] {
        return [
            tmuxSplitMenuSection(window: window, tmux: tmux, enabled: splitIsAvailable) { option in
                performSplit(option, window: window)
            },
            TmuxWindowMenuSection(actions: [
                TmuxWindowMenuAction(title: String(localized: "Rename"), systemImage: "pencil") {
                    windowRenameText = window.windowName ?? ""
                    pendingWindowRename = window
                }
            ]),
            tmuxMoveMenuSection(windowID: window.id, tmux: tmux, horizontal: true, dispatch: dispatchSessionCommand),
            TmuxWindowMenuSection(actions: [
                TmuxWindowMenuAction(title: String(localized: "Close Window"), systemImage: "xmark", destructive: true, disabled: !windowCloseIsAvailable) {
                    requestWindowClose(window)
                }
            ])
        ]
    }

    /// Splits mutate the shared grid, so they answer to the same gates Move
    /// and Close already do: not while tmux sync is degraded, and not while
    /// another device owns the grid.
    private var splitIsAvailable: Bool {
        !tmuxIsDegraded
            && tmux.mode == .tmuxControl
            && tmux.isWindowListHydrated
            && !tmux.gridAuthority.isPeer
    }

    /// Split the window the menu was opened on, then bring it forward.
    ///
    /// Both halves ride the same `SessionCommand` queue, so the selection
    /// cannot overtake the split that makes it worth looking at. Selecting is
    /// what makes the result visible at all: a split into a background window
    /// is otherwise a silent no-op on screen, and tmux has already made the
    /// new pane that window's active one, so the selection lands on it.
    ///
    /// Both steps name ids, never strip positions. A menu can stay open while
    /// a host script adds a window or another device reorders, and a position
    /// captured when the menu was built would by then select a different tab
    /// than the one that was split — the same reason the tab's X targets a
    /// window id directly.
    private func performSplit(
        _ option: TmuxPaneSplitOption,
        window: TmuxController.WindowInfo
    ) {
        guard let paneID = tmuxSplitTargetPane(window.id, in: tmux) else { return }
        onTmuxPaneMutation?()
        dispatchSessionCommand(.splitTmuxPane(
            paneID.description,
            axis: option.axis == .horizontal ? .horizontal : .vertical,
            before: option.before
        ))
        guard window.id != tmux.activeWindowId else { return }
        dispatchSessionCommand(.selectTmuxWindow(window.id.description))
    }

    private func tabMoveAccessibilityActions(
        window: TmuxController.WindowInfo,
        position: Int
    ) -> [TmuxWindowAccessibilityAction] {
        tmuxMoveAccessibilityActions(windowID: window.id, tmux: tmux, horizontal: true, dispatch: dispatchSessionCommand) + tmuxSplitAccessibilityActions(
            window: window,
            tmux: tmux,
            enabled: splitIsAvailable
        ) { option in
            performSplit(option, window: window)
        }
    }

    private func handleTabReorder(_ phase: TmuxWindowReorderPhase, window: TmuxController.WindowInfo) {
        switch phase {
        case .began(let location):
            tabDrag.begin(id: window.id, order: tmux.windows.map(\.id), pointer: location.x,
                          frameStart: Double(tabWindowFrames[window.id]?.minX ?? location.x), enabled: tmux.canReorderWindows)
        case .changed(let location):
            if tabDrag.update(pointer: location.x, midpoints: tabWindowFrames.mapValues { $0.midX }, enabled: tmux.canReorderWindows) {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            guard tabDrag.isDragging else { return }
            if location.x < tabStripViewportFrame.minX + 44 { startEdgeAutoscroll(direction: -1) }
            else if location.x > tabStripViewportFrame.maxX - 44 { startEdgeAutoscroll(direction: 1) }
            else { stopEdgeAutoscroll() }
        case .ended(let cancelled):
            let destination = tabDrag.finish(cancelled: cancelled || !tmux.canReorderWindows)
            cancelWindowReorder()
            if let destination {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dispatchSessionCommand(.moveTmuxWindow(window.id.description, move: .position(destination)))
                Task { @MainActor in
                    await Task.yield()
                    reorderScrollTarget = window.id
                    reorderScrollToken &+= 1
                }
            }
        }
    }

    private func cancelWindowReorder() {
        tabDrag.cancel()
        stopEdgeAutoscroll()
    }

    private func tabDragOffset(for id: WindowId) -> CGFloat {
        guard tabDrag.id == id, let frame = tabWindowFrames[id] else { return 0 }
        return tabDrag.offset(currentFrameStart: frame.minX)
    }

    private func startEdgeAutoscroll(direction: Int) {
        guard direction != 0 else { stopEdgeAutoscroll(); return }
        if edgeAutoscrollDirection == direction, edgeAutoscrollTask != nil { return }
        stopEdgeAutoscroll()
        edgeAutoscrollDirection = direction
        edgeAutoscrollTask = Task { @MainActor in
            while !Task.isCancelled, edgeAutoscrollDirection == direction {
                guard let draggingWindowID,
                      let current = displayedTmuxWindows.firstIndex(where: { $0.id == draggingWindowID })
                else { break }
                let next = min(max(0, current + direction), displayedTmuxWindows.count - 1)
                reorderScrollTarget = displayedTmuxWindows[next].id
                reorderScrollToken &+= 1
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func stopEdgeAutoscroll() {
        edgeAutoscrollDirection = 0
        edgeAutoscrollTask?.cancel()
        edgeAutoscrollTask = nil
        reorderScrollTarget = nil
    }

    private func submitWindowRename() {
        guard let window = pendingWindowRename else { return }
        let name = windowRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        pendingWindowRename = nil
        dispatchSessionCommand(.renameTmuxWindow(window.id.description, name: name))
    }

    private func tmuxMenuTouchChanged(_ active: Bool) {
        tmuxMenuBackstopReleaseTask?.cancel()
        if active {
            tmuxMenuBackstopOn = true
        } else if presentedTmuxMenuCount == 0 {
            tmuxMenuBackstopReleaseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, presentedTmuxMenuCount == 0 else { return }
                tmuxMenuBackstopOn = false
            }
        }
    }

    private func tmuxMenuPresenceChanged(_ present: Bool) {
        presentedTmuxMenuCount = max(0, presentedTmuxMenuCount + (present ? 1 : -1))
        tmuxMenuBackstopReleaseTask?.cancel()
        if present {
            tmuxMenuBackstopOn = true
            cancelWindowReorder()
        } else if presentedTmuxMenuCount == 0 {
            tmuxMenuBackstopReleaseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                tmuxMenuBackstopOn = false
            }
        }
    }

    // MARK: - Tab-strip overflow

    /// True while the strip is scrolled away from its leading edge — the
    /// leading fade hint is showing.
    private var canScrollTabStripLeft: Bool {
        tabStripContentFrame.minX < -2
    }

    /// True while more tabs remain past the trailing edge.
    private var canScrollTabStripRight: Bool {
        tabStripContentFrame.maxX > tabStripVisibleWidth + 2
    }

    /// Re-derives `tabStripOverflows` from the latest measurements, with
    /// hysteresis: the chevron's appearance costs the strip its own 36pt
    /// pitch, so a plain `content > visible` check would flap right at the
    /// boundary (chevron appears → strip shrinks → still overflows; user
    /// closes one tab → fits → chevron hides → strip regrows → overflows
    /// again). Once visible, the chevron hides only when the content would
    /// fit with that pitch reclaimed.
    private func updateTabStripOverflow() {
        let epsilon: CGFloat = 2
        let chevronPitch = 36 * scale
        let content = tabStripContentFrame.width
        if tabStripOverflows {
            if content <= tabStripVisibleWidth + chevronPitch - epsilon {
                tabStripOverflows = false
            }
        } else if content > tabStripVisibleWidth + epsilon {
            tabStripOverflows = true
        }
    }

    /// Mask for the strip's scroll view: solid everywhere except a short
    /// alpha ramp at an edge that has clipped tabs behind it. Replaces the
    /// hard clip as the "there's more" hint without adding any chrome.
    private var tabStripFadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [canScrollTabStripLeft ? .clear : .black, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14 * scale)
            SwiftUI.Color.black
            LinearGradient(
                colors: [.black, canScrollTabStripRight ? .clear : .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 14 * scale)
        }
        .animation(.easeOut(duration: 0.15), value: canScrollTabStripLeft)
        .animation(.easeOut(duration: 0.15), value: canScrollTabStripRight)
    }

    /// Close availability mirrors `TmuxTabCloseButton`'s enabled state: no
    /// destructive sends while sync is degraded or the window list hasn't
    /// hydrated (a kill against a stale list could target the wrong window).
    private var windowCloseIsAvailable: Bool {
        !tmuxIsDegraded && tmux.mode == .tmuxControl && tmux.isWindowListHydrated
    }

    /// Shared close entry for the strip's X and the overflow list's X.
    /// Decides on live controller state re-read at tap time (the passed-in
    /// `window` is a render-captured snapshot that can be a frame stale).
    /// Confirmation goes through the `pendingWindowClose` alert for
    /// multi-pane windows AND for windows whose pane count is still a guess
    /// because the `%window-add` details query hasn't answered — an
    /// already-split `link-window`/`move-window` window must not be killed
    /// promptless during that round trip. When the request comes from the
    /// window-list popover, the alert is staged and presented only after
    /// the popover has actually left the screen (its content's
    /// `onDisappear`): a fixed one-turn yield doesn't outlast the dismiss
    /// transition, during which UIKit can drop the presentation.
    private func requestWindowClose(
        _ window: TmuxController.WindowInfo,
        fromWindowList: Bool = false
    ) {
        guard windowCloseIsAvailable else { return }
        let live = tmux.windows.first(where: { $0.id == window.id }) ?? window
        guard live.paneCount > 1 || tmux.isWindowLayoutPending(live.id) else {
            dispatchSessionCommand(.closeTmuxWindow(live.id.description))
            return
        }
        let pending = PendingTmuxWindowClose(
            window: live,
            controlConnectionGeneration: tmux.controlConnectionGeneration
        )
        if fromWindowList {
            stagedWindowListClose = pending
            windowListVisible = false
        } else {
            pendingWindowClose = pending
        }
    }

    /// Presents a close confirmation staged by the window-list popover once
    /// the popover has fully dismissed. Re-validates against live controller
    /// state at presentation time so a window that vanished mid-dismiss
    /// (remote close, reconnect) doesn't resurrect as a ghost alert.
    private func presentStagedWindowListClose() {
        guard let staged = stagedWindowListClose else { return }
        stagedWindowListClose = nil
        guard staged.controlConnectionGeneration == tmux.controlConnectionGeneration,
              tmux.isWindowListHydrated,
              tmux.windows.contains(where: { $0.id == staged.window.id })
        else { return }
        pendingWindowClose = staged
    }

    private func presentStagedWindowListRename() {
        guard let staged = stagedWindowListRename else { return }
        stagedWindowListRename = nil
        guard tmux.isWindowListHydrated,
              let live = tmux.windows.first(where: { $0.id == staged.id })
        else { return }
        windowRenameText = live.windowName ?? ""
        pendingWindowRename = live
    }

    private func dispatchSessionCommand(_ command: SessionCommand) {
        _ = sessionCommands.dispatch(command)
    }

    private func selectWindow(atPosition position: Int) {
        guard let windowID = tmux.snapshot.windowID(atPosition: position) else { return }
        dispatchSessionCommand(.selectTmuxWindow(windowID.description))
    }

    /// Active-tab fill: theme accent (via `accentSoft`) in normal
    /// operation, semantic amber when tmux sync is degraded so the
    /// warning state remains unambiguous regardless of which theme
    /// the user picked. Inactive tabs are transparent.
    private func tabBackground(
        isActive: Bool,
        isDegraded: Bool,
        unreadResultTint: SwiftUI.Color?
    ) -> SwiftUI.Color {
        if let unreadResultTint, !isDegraded { return unreadResultTint.opacity(0.14) }
        guard isActive else { return SwiftUI.Color.clear }
        return isDegraded ? T.amber.opacity(0.16) : T.accentSoft
    }

    private func hostStatusButton<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: { statusBreakdownVisible = true }) {
            content()
                // Stand the hit frame up to the bar height like the other bar
                // controls — a natural-height pill is a sub-44 pt target next
                // to full-pitch neighbors (iPadOS 26 mis-assigns such taps).
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: $statusBreakdownVisible,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            ConnectionStatusBreakdownView(
                status: connectionStatus,
                programs: (sessionID: sessionID, T: T, onOpen: { key in
                    statusBreakdownVisible = false
                    programStatusCenter.openTerminal(sessionID: sessionID, key: key)
                })
            )
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Connection status")
    }

    private var statusDotColor: SwiftUI.Color {
        switch connectionStatus {
        case .ssh(let state):
            return dotColor(for: state)
        case .mosh(let sessionState, let transportState, let tcpControl):
            switch sessionState {
            case .connected:
                switch transportState {
                case .connected:
                    break
                case .connecting, .idle:
                    return T.amber.opacity(0.9)
                case .disconnected:
                    return T.red
                }
                guard let tcpControl else {
                    return T.green
                }
                return tcpControl == .connected
                    ? T.green
                    : T.amber.opacity(0.9)
            case .connecting:
                return T.amber.opacity(0.9)
            case .idle:
                return T.fgDim
            case .disconnected, .failed:
                return T.red
            }
        }
    }

    private func dotColor(for state: SessionState) -> SwiftUI.Color {
        switch state {
        case .idle: return T.fgDim
        case .connecting: return T.amber
        case .connected: return T.green
        case .disconnected, .failed: return T.red
        }
    }

    /// Extra text after the host label describing the session state.
    /// Nil when connected — the green dot alone conveys that and
    /// the space is more valuable than the redundant word "connected".
    private var detailText: LocalizedStringResource? {
        if tmuxIsDegraded, state == .connected {
            return "tmux sync offline"
        }
        switch state {
        case .idle:               return "idle"
        case .connecting:         return "connecting…"
        case .connected:          return nil
        case .disconnected:       return "disconnected"
        // The full reason + recovery actions live in the launch overlay's
        // error state now; the top bar just keeps a short red marker.
        case .failed:             return "failed"
        }
    }

    private var detailColor: SwiftUI.Color {
        if tmuxIsDegraded, state == .connected {
            return T.amber
        }
        switch state {
        case .failed: return T.red
        default:      return T.fgMuted
        }
    }
}

struct SessionAgentIntegrationWarningPopover: View {
    let state: AgentIntegrationWarningState
    let T: DesignTokens
    let onFix: () -> Void
    let onSecondaryFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(T.amber)
                Text(state.title)
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(T.fg)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(state.message)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            if state.isRepairing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("working…")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                }
            } else {
                if let label = state.actionLabel, state.action != nil {
                    actionButton(label, primary: true, action: onFix)
                        .accessibilityIdentifier("agent-integration-fix")
                }
                if let label = state.secondaryActionLabel, state.secondaryAction != nil {
                    actionButton(label, primary: false, action: onSecondaryFix)
                        .accessibilityIdentifier("agent-integration-persist")
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(T.panelBg)
    }

    private func actionButton(
        _ title: LocalizedStringResource,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(primary ? T.accent : T.fgMuted)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(primary ? T.accentSoft : T.inputBgSoft)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(primary ? T.accent.opacity(0.35) : T.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Cross-device actions presented from the terminal bar's continuity button.
/// This deliberately uses a regular popover instead of `Menu`: iPadOS removes
/// the bar's glass/backdrop while a system menu is active, making the entire
/// terminal bar appear to vanish.
struct ContinuityActionPopover: View {
    let T: DesignTokens
    let onContinue: () -> Void
    let onSetUpAndContinue: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            actionRow(
                "continue on another device",
                systemName: "rectangle.on.rectangle.angled",
                identifier: "session-continuity-continue",
                action: onContinue
            )
            actionRow(
                "set up and continue",
                systemName: "iphone.and.arrow.forward",
                identifier: "session-continuity-setup",
                action: onSetUpAndContinue
            )
        }
        .padding(6)
        .frame(width: 268)
        .presentationBackground(T.bg.opacity(0.94))
        .presentationCornerRadius(13)
    }

    private func actionRow(
        _ title: LocalizedStringKey,
        systemName: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 20)
                Text(title)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .foregroundStyle(T.fg)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(T.inputBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(T.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
func tmuxMoveOptions(horizontal: Bool) -> [(TmuxWindowMoveIntent, String, String)] {
    [
        (.previous, horizontal ? String(localized: "Move Left") : String(localized: "Move Up"), horizontal ? "arrow.left" : "arrow.up"),
        (.next, horizontal ? String(localized: "Move Right") : String(localized: "Move Down"), horizontal ? "arrow.right" : "arrow.down"),
        (.start, String(localized: "Move to Start"), horizontal ? "arrow.left.to.line" : "arrow.up.to.line"),
        (.end, String(localized: "Move to End"), horizontal ? "arrow.right.to.line" : "arrow.down.to.line")
    ]
}

@MainActor
func tmuxMoveMenuSection(windowID: WindowId, tmux: TmuxController, horizontal: Bool,
                                 dispatch: @escaping (SessionCommand) -> Void) -> TmuxWindowMenuSection {
    let order = tmux.windows.map(\.id)
    var actions = tmuxMoveOptions(horizontal: horizontal).map { intent, title, icon in
        TmuxWindowMenuAction(title: title, systemImage: icon,
                             disabled: !tmux.canReorderWindows || intent.destination(in: order, moving: windowID) == nil) {
            dispatch(.moveTmuxWindow(windowID.description, move: .relative(intent)))
        }
    }
    actions.append(TmuxWindowMenuAction(title: String(localized: "Tidy window numbers"), systemImage: "number", disabled: !tmux.canTidyWindows) {
        dispatch(.renumberTmuxWindows)
    })
    return TmuxWindowMenuSection(actions: actions)
}

@MainActor
func tmuxMoveAccessibilityActions(windowID: WindowId, tmux: TmuxController, horizontal: Bool,
                                          dispatch: @escaping (SessionCommand) -> Void) -> [TmuxWindowAccessibilityAction] {
    guard tmux.canReorderWindows else { return [] }
    return tmuxMoveOptions(horizontal: horizontal).compactMap { intent, title, _ in
        guard intent.destination(in: tmux.windows.map(\.id), moving: windowID) != nil else { return nil }
        return TmuxWindowAccessibilityAction(name: title) {
            dispatch(.moveTmuxWindow(windowID.description, move: .relative(intent)))
        }
    }
}

struct TmuxWindowMenuAction {
    let title: String
    let systemImage: String
    var destructive = false
    var disabled = false
    let handler: () -> Void
}

/// One inline group in a window's context menu.
///
/// `isPalette` renders the group as a single glyph-only row under `title`,
/// the way the system's own window-tiling menu presents its placements. The
/// splits need it: as four full-height rows they would nearly double a menu
/// that already carries Rename, five Move entries and Close, and the labels
/// would be saying what each glyph already shows.
struct TmuxWindowMenuSection {
    var title: String?
    var isPalette: Bool
    var actions: [TmuxWindowMenuAction]

    init(
        title: String? = nil,
        isPalette: Bool = false,
        actions: [TmuxWindowMenuAction]
    ) {
        self.title = title
        self.isPalette = isPalette
        self.actions = actions
    }
}

/// One pane placement, in the order the palette shows them.
///
/// The glyph is the result, not a decoration: the filled half of
/// `rectangle.*half.filled` is the pane about to be created, the hollow half
/// the one it splits from.
///
/// `leadinghalf` / `trailinghalf` would auto-mirror; these do not. Untested
/// either way, because Tessera ships no RTL locale — and the neighbouring
/// Move rows already disagree, since `arrow.left` / `arrow.right` do mirror.
/// If an RTL locale is ever added, decide the whole menu at once rather than
/// reading this as a settled choice.
struct TmuxPaneSplitOption {
    let title: String
    let systemImage: String
    let axis: PaneSplitAxis
    let before: Bool

    static let all: [TmuxPaneSplitOption] = [
        TmuxPaneSplitOption(
            title: String(localized: "Split Right"),
            systemImage: "rectangle.righthalf.filled",
            axis: .horizontal,
            before: false
        ),
        TmuxPaneSplitOption(
            title: String(localized: "Split Left"),
            systemImage: "rectangle.lefthalf.filled",
            axis: .horizontal,
            before: true
        ),
        TmuxPaneSplitOption(
            title: String(localized: "Split Down"),
            systemImage: "rectangle.bottomhalf.filled",
            axis: .vertical,
            before: false
        ),
        TmuxPaneSplitOption(
            title: String(localized: "Split Up"),
            systemImage: "rectangle.tophalf.filled",
            axis: .vertical,
            before: true
        ),
    ]
}

/// The pane a split from this window's menu targets: the window's own active
/// pane, and only once the layout proving it exists has arrived.
///
/// The pane a split should target, resolved against live controller state
/// rather than the `WindowInfo` the menu was built from.
///
/// A context menu can stay open indefinitely, and `splitPane` accepts any
/// pane it can find in *any* window — tmux resolves a bare `%id` against
/// whichever window holds it now. So a pane that moved windows while the menu
/// was up would split a window the user never touched. Re-reading the window
/// by id at tap time keeps the split inside the tab that was pressed.
///
/// `splitPane` also drops a command whose target it cannot find, so a window
/// whose panes have not hydrated must disable the action rather than offer
/// one that silently does nothing.
@MainActor
func tmuxSplitTargetPane(
    _ windowID: WindowId,
    in tmux: TmuxController
) -> PaneId? {
    guard let window = tmux.windows.first(where: { $0.id == windowID }),
          let paneID = window.activePaneId,
          window.panes.contains(where: { $0.id == paneID })
    else { return nil }
    return paneID
}

/// The split palette, shared by the tab strip and the overflow window list so
/// one window cannot offer two different menus depending on where it was
/// opened from.
/// The splits as VoiceOver/Switch Control actions.
///
/// A context menu is the palette's only pointer affordance, and Full Keyboard
/// Access has no chord for Split Left or Split Up at all — ⌘D and ⌘⇧D can
/// only append. Without these, two of the four placements would be reachable
/// by long-press alone.
@MainActor
func tmuxSplitAccessibilityActions(
    window: TmuxController.WindowInfo,
    tmux: TmuxController,
    enabled: Bool,
    perform: @escaping (TmuxPaneSplitOption) -> Void
) -> [TmuxWindowAccessibilityAction] {
    guard enabled, tmuxSplitTargetPane(window.id, in: tmux) != nil else { return [] }
    return TmuxPaneSplitOption.all.map { option in
        TmuxWindowAccessibilityAction(name: option.title) { perform(option) }
    }
}

@MainActor
func tmuxSplitMenuSection(
    window: TmuxController.WindowInfo,
    tmux: TmuxController,
    enabled: Bool,
    perform: @escaping (TmuxPaneSplitOption) -> Void
) -> TmuxWindowMenuSection {
    let available = enabled && tmuxSplitTargetPane(window.id, in: tmux) != nil
    return TmuxWindowMenuSection(
        title: String(localized: "New pane"),
        isPalette: true,
        actions: TmuxPaneSplitOption.all.map { option in
            TmuxWindowMenuAction(
                title: option.title,
                systemImage: option.systemImage,
                disabled: !available
            ) {
                perform(option)
            }
        }
    )
}

struct TmuxWindowAccessibilityAction {
    let name: String
    let handler: () -> Void
}

enum TmuxWindowReorderPhase {
    case began(window: CGPoint)
    case changed(window: CGPoint)
    case ended(cancelled: Bool)
}

func tmuxWindowReorderHarnessLog(_ message: @autoclosure () -> String) {
#if DEBUG
    guard ProcessInfo.processInfo.environment[
        "TESSERA_TMUX_WINDOW_REORDER_HARNESS"
    ] == "1" else { return }
    NSLog("[tmux-window-reorder] %@", message())
#endif
}

/// A deterministic held-drag recognizer for a scroll-view child. Staying
/// within `allowableMovement` until the timer fires claims the touch; moving
/// farther first fails immediately so the enclosing scroll view pans normally.
/// UIKit's context-menu recognizer observes simultaneously and presents only
/// if the claimed touch remains stationary.
final class TmuxWindowHeldDragRecognizer: UIGestureRecognizer {
    var minimumPressDuration: TimeInterval = 0.22
    var allowableMovement: CGFloat = 10

    private var origin = CGPoint.zero
    private var holdWorkItem: DispatchWorkItem?
    private var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible,
              trackedTouch == nil,
              touches.count == 1,
              let touch = touches.first
        else {
            rejectAdditionalTouch()
            return
        }
        trackedTouch = touch
        origin = touch.location(in: view?.window)
        let frame = view.map { $0.convert($0.bounds, to: nil) } ?? .zero
        tmuxWindowReorderHarnessLog(
            "touch-began x=\(Int(origin.x)) y=\(Int(origin.y)) "
                + "frame=\(NSCoder.string(for: frame))"
        )
        holdWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .possible else { return }
            tmuxWindowReorderHarnessLog("hold-timer-began")
            self.state = .began
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumPressDuration, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let trackedTouch,
              let touch = touches.first(where: { $0 === trackedTouch })
        else { return }
        let location = touch.location(in: view?.window)
        let distance = hypot(location.x - origin.x, location.y - origin.y)
        switch state {
        case .possible where distance > allowableMovement:
            tmuxWindowReorderHarnessLog("touch-prehold-fail distance=\(Int(distance))")
            holdWorkItem?.cancel()
            state = .failed
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let trackedTouch,
              touches.contains(where: { $0 === trackedTouch })
        else { return }
        holdWorkItem?.cancel()
        switch state {
        case .began, .changed: state = .ended
        case .possible: state = .failed
        default: break
        }
        tmuxWindowReorderHarnessLog("touch-ended state=\(state.rawValue)")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let trackedTouch,
              touches.contains(where: { $0 === trackedTouch })
        else { return }
        holdWorkItem?.cancel()
        state = state == .began || state == .changed ? .cancelled : .failed
        tmuxWindowReorderHarnessLog("touch-cancelled state=\(state.rawValue)")
    }

    private func rejectAdditionalTouch() {
        holdWorkItem?.cancel()
        switch state {
        case .began, .changed: state = .cancelled
        case .possible: state = .failed
        default: break
        }
        tmuxWindowReorderHarnessLog("touch-additional-rejected state=\(state.rawValue)")
    }

    override func reset() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        trackedTouch = nil
        origin = .zero
        super.reset()
    }
}

/// One native interaction surface arbitrates tap, long-press reorder, context
/// menu and trackpad secondary click. Quick pans stay with the strip's scroll
/// view; no SwiftUI drag/drop session is created.
struct TmuxWindowInteractionSurface: UIViewRepresentable {
    let enabled: Bool
    let accessibilityLabel: String
    let menuSections: [TmuxWindowMenuSection]
    let moveActions: [TmuxWindowAccessibilityAction]
    let onTap: () -> Void
    let onTouchActive: (Bool) -> Void
    let onMenuPresence: (Bool) -> Void
    let onReorder: (TmuxWindowReorderPhase) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(surface: self) }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.coordinator = context.coordinator
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))

        let press = TmuxWindowHeldDragRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        // Match the proven DraggableChipBar hold: a deliberate touch claims
        // movement promptly, while a quick swipe fails to the scroll view.
        press.minimumPressDuration = 0.22
        press.allowableMovement = 10
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)
        view.holdRecognizer = press

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.require(toFail: press)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        context.coordinator.surface = self
        view.isUserInteractionEnabled = enabled
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityCustomActions = moveActions.map { action in
            UIAccessibilityCustomAction(name: action.name) { _ in
                action.handler()
                return true
            }
        }
    }

    final class TouchView: UIView {
        weak var coordinator: Coordinator?
        weak var holdRecognizer: TmuxWindowHeldDragRecognizer?
        weak var configuredScrollPan: UIPanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureScrollArbitration()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            configureScrollArbitration()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The representable can join its SwiftUI scroll hierarchy after
            // didMoveToSuperview. Retrying here installs the relationship as
            // soon as the enclosing UIScrollView exists.
            configureScrollArbitration()
        }

        private func configureScrollArbitration() {
            guard let holdRecognizer else { return }
            var candidate = superview
            var foundNearestScrollView = false
            while let current = candidate {
                if !foundNearestScrollView, let scrollView = current as? UIScrollView {
                    foundNearestScrollView = true
                    let pan = scrollView.panGestureRecognizer
                    if configuredScrollPan !== pan {
                        pan.require(toFail: holdRecognizer)
                        configuredScrollPan = pan
                        tmuxWindowReorderHarnessLog(
                            "scroll-pan-requires-hold view=\(NSCoder.string(for: convert(bounds, to: nil)))"
                        )
                    }
                }
                candidate = current.superview
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator?.surface.onTouchActive(true)
            super.touchesBegan(touches, with: event)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator?.surface.onTouchActive(false)
            super.touchesEnded(touches, with: event)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator?.surface.onTouchActive(false)
            super.touchesCancelled(touches, with: event)
        }
        override func accessibilityActivate() -> Bool {
            coordinator?.surface.onTap()
            return true
        }
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
        var surface: TmuxWindowInteractionSurface
        private var pressOrigin = CGPoint.zero
        private var dragClaimed = false
        private var pressObserved = false
        init(surface: TmuxWindowInteractionSurface) { self.surface = surface }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            surface.onTap()
        }

        @objc func handleLongPress(_ recognizer: UIGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view?.window)
            tmuxWindowReorderHarnessLog(
                "recognizer state=\(recognizer.state.rawValue) x=\(Int(location.x)) y=\(Int(location.y)) "
                    + "distance=\(Int(hypot(location.x - pressOrigin.x, location.y - pressOrigin.y))) "
                    + "claimed=\(dragClaimed)"
            )
            switch recognizer.state {
            case .began:
                pressOrigin = location
                dragClaimed = false
                pressObserved = true
                // Begin observing after the hold, before movement. The owner
                // captures topology and geometry here but does not lift the
                // row until the explicit movement threshold is crossed.
                surface.onReorder(.began(window: location))
            case .changed:
                if !dragClaimed, hypot(location.x - pressOrigin.x, location.y - pressOrigin.y) > 8 {
                    dragClaimed = true
                    tmuxWindowReorderHarnessLog("claim")
                }
                if dragClaimed { surface.onReorder(.changed(window: location)) }
            case .ended:
                // UIKit may coalesce a short fast drag into began -> ended.
                // Preserve the same threshold and deliver its final location
                // so a recognized hold still produces a deterministic drop.
                if !dragClaimed,
                   hypot(location.x - pressOrigin.x, location.y - pressOrigin.y) > 8 {
                    dragClaimed = true
                    tmuxWindowReorderHarnessLog("claim-at-end")
                    surface.onReorder(.changed(window: location))
                }
                if pressObserved { surface.onReorder(.ended(cancelled: false)) }
                tmuxWindowReorderHarnessLog("end claimed=\(dragClaimed)")
                dragClaimed = false
                pressObserved = false
            case .cancelled, .failed:
                if pressObserved { surface.onReorder(.ended(cancelled: true)) }
                tmuxWindowReorderHarnessLog(
                    "cancel state=\(recognizer.state.rawValue) claimed=\(dragClaimed)"
                )
                dragClaimed = false
                pressObserved = false
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let frame = gestureRecognizer.view.map { $0.convert($0.bounds, to: nil) } ?? .zero
            tmuxWindowReorderHarnessLog(
                "should-begin recognizer=\(String(describing: type(of: gestureRecognizer))) "
                    + "state=\(gestureRecognizer.state.rawValue) frame=\(NSCoder.string(for: frame))"
            )
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // UIKit's private context-menu recognizers are not guaranteed to
            // live on this exact view; in a popover they may be installed on
            // an ancestor. Allow those recognizers to observe beside us so
            // their attachment choice cannot cancel the reorder hold before
            // `.began`. The enclosing scroll view's pan is the one exception:
            // a quick pan must win before our timer, while a recognized hold
            // must own movement without scrolling the strip/list underneath.
            let scrollPan = Self.enclosingScrollView(from: gestureRecognizer.view)?.panGestureRecognizer
            let simultaneous = otherGestureRecognizer !== scrollPan
            tmuxWindowReorderHarnessLog(
                "simultaneous other=\(String(describing: type(of: otherGestureRecognizer))) "
                    + "view=\(String(describing: type(of: otherGestureRecognizer.view))) "
                    + "allowed=\(simultaneous)"
            )
            return simultaneous
        }

        private static func enclosingScrollView(from view: UIView?) -> UIScrollView? {
            var candidate = view?.superview
            while let current = candidate {
                if let scrollView = current as? UIScrollView { return scrollView }
                candidate = current.superview
            }
            return nil
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !dragClaimed,
                  surface.menuSections.contains(where: { !$0.actions.isEmpty })
            else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let groups = surface.menuSections.map { section -> UIMenu in
                    var options: UIMenu.Options = [.displayInline]
                    if section.isPalette { options.insert(.displayAsPalette) }
                    let menu = UIMenu(
                        title: section.title ?? "",
                        options: options,
                        children: section.actions.map { action in
                            var attributes: UIMenuElement.Attributes = []
                            if action.destructive { attributes.insert(.destructive) }
                            if action.disabled { attributes.insert(.disabled) }
                            return UIAction(
                                title: action.title,
                                image: UIImage(systemName: action.systemImage),
                                attributes: attributes
                            ) { _ in action.handler() }
                        }
                    )
                    // `.small` is what drops the titles and leaves the glyph
                    // alone; a palette at the default element size still
                    // reserves room for every label.
                    if section.isPalette { menu.preferredElementSize = .small }
                    return menu
                }
                return UIMenu(children: groups)
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            tmuxWindowReorderHarnessLog("menu-will-display claimed=\(dragClaimed)")
            surface.onReorder(.ended(cancelled: true))
            dragClaimed = false
            pressObserved = false
            surface.onMenuPresence(true)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            if let animator {
                animator.addCompletion { [weak self] in self?.surface.onMenuPresence(false) }
            } else {
                surface.onMenuPresence(false)
            }
        }
    }
}

struct TmuxTabWindowFramesKey: PreferenceKey {
    static let defaultValue: [WindowId: CGRect] = [:]
    static func reduce(value: inout [WindowId: CGRect], nextValue: () -> [WindowId: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The tab-overflow window list. Presented from the strip's `chevron.down`
/// button so touch users can switch (or close) windows directly when the
/// strip has scrolled past the viewport — finger-scrolling the strip fights
/// the iPadOS window-drag region along the top screen edge. Rows mirror the
/// strip's tabs (position number, agent sparkles, name, ⌘N hint, close X)
/// with 40pt pitch for comfortable touch targets. Unscaled: popover content
/// floats outside the bar, so the `topBarHeight` slider doesn't apply.
struct TmuxWindowListPopover: View {
    /// VoiceOver label for one window row.
    ///
    /// Each agent state is a whole sentence rather than a suffix appended to
    /// the window name: the states inflect differently across languages, and
    /// a language that puts the verb last has nowhere to append.
    private func windowRowAccessibilityLabel(
        name: String,
        number: Int,
        tmuxIndex: Int?,
        hasAgent: Bool,
        status: String?
    ) -> String {
        let indexDetail = tmuxIndex.flatMap { index in
            index == number ? nil : String(localized: ", tmux index \(index)")
        } ?? ""
        switch (hasAgent, status) {
        case (false, nil):
            return String(localized: "\(name), window \(number)\(indexDetail)")
        case (false, let status?):
            return String(
                localized: "\(name), window \(number)\(indexDetail), \(status)",
                comment: "Window list row for VoiceOver. Arguments: window name, number, tmux index detail, reported status words."
            )
        case (true, nil):
            return String(localized: "\(name), window \(number)\(indexDetail), agent active")
        case (true, let status?):
            return String(
                localized: "\(name), window \(number)\(indexDetail), agent, \(status)",
                comment: "Window list row for VoiceOver: a detected agent runs here. Arguments: window name, number, tmux index detail, status words."
            )
        }
    }

    @Environment(AppearancePreferences.self) private var appearance
    let tmux: TmuxController
    let sessionID: UUID
    let isDegraded: Bool
    let T: DesignTokens
    /// Selection by strip position (1-based) — the same
    /// `selectWindow(atPosition:)` path tab taps and ⌘1-9 use.
    let onSelect: (Int) -> Void
    let onClose: (TmuxController.WindowInfo) -> Void
    let onRename: (TmuxController.WindowInfo) -> Void
    /// Handed back to the bar rather than run here: the split has to dismiss
    /// this popover and then select the window, and both of those belong to
    /// the bar that presented it.
    let onSplit: (TmuxController.WindowInfo, TmuxPaneSplitOption) -> Void
    let onMenuTouch: (Bool) -> Void
    let onMenuPresence: (Bool) -> Void
    let dispatchSessionCommand: (SessionCommand) -> Void
    let onNewWindow: () -> Void

    @Environment(AgentCenterV2Coordinator.self) private var agentCenterV2
    @Environment(ProgramStatusCenter.self) private var programStatusCenter
    @State private var rowDrag = TmuxWindowDragState()
    private var previewOrder: [WindowId]? { rowDrag.previewOrder }
    private var draggingID: WindowId? { rowDrag.isDragging ? rowDrag.id : nil }
    @State private var rowFrames: [WindowId: CGRect] = [:]
    @State private var viewportFrame: CGRect = .zero
    @State private var edgeScrollDirection = 0
    @State private var edgeScrollTarget: WindowId?
    @State private var edgeScrollTask: Task<Void, Never>?
    @State private var dropRevealTarget: WindowId?
    @State private var dropRevealToken = 0

    private static let rowHeight: CGFloat = 44
    private static let footerHeight: CGFloat = 36
    /// Cap so a pathological window count scrolls instead of growing a
    /// popover taller than a landscape iPad's usable height.
    private static let maxHeight: CGFloat = 420

    var body: some View {
        let windows = displayedWindows
        // Popovers collapse greedy ScrollViews to zero, so size the panel
        // explicitly: rows + divider block + footer + vertical padding.
        let idealHeight = 5 + CGFloat(windows.count) * Self.rowHeight + 9
            + Self.footerHeight + 5
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            row(number: index + 1, window: window)
                                .background {
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: TmuxPopoverWindowFramesKey.self,
                                            value: [window.id: geo.frame(in: .global)]
                                        )
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.top, 5)
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TmuxPopoverViewportFrameKey.self,
                            value: geo.frame(in: .global)
                        )
                    }
                }
                .onPreferenceChange(TmuxPopoverWindowFramesKey.self) { rowFrames = $0 }
                .onPreferenceChange(TmuxPopoverViewportFrameKey.self) { viewportFrame = $0 }
                .onChange(of: edgeScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(target, anchor: edgeScrollDirection < 0 ? .top : .bottom)
                    }
                }
                .onChange(of: dropRevealToken) { _, _ in
                    guard let target = dropRevealTarget else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                .onAppear {
                    // Long lists should open with the active window on
                    // screen, not the top of the list. Deferred a turn so
                    // layout exists for scrollTo to target.
                    guard let windowID = tmux.activeWindowId else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(windowID, anchor: .center)
                    }
                }
            }

            Rectangle()
                .fill(T.border)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            Button(action: onNewWindow) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                    Text("New window")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(T.fgMuted)
                .padding(.horizontal, 15)
                .frame(height: Self.footerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDegraded)
            .opacity(isDegraded ? 0.45 : 1)
            .accessibilityLabel("New tmux window")
            .accessibilityHint(
                isDegraded
                    ? LocalizedStringKey("Unavailable while tmux sync is offline")
                    : ""
            )
            .accessibilityIdentifier("tmux-window-list-new")
            .padding(.bottom, 5)
        }
        .frame(width: 288, height: min(idealHeight, Self.maxHeight))
        .presentationBackground(T.bg.opacity(0.94))
        .presentationCornerRadius(13)
        .onChange(of: tmux.windows.map(\.id)) { _, ids in
            if previewOrder != nil, ids != rowDrag.baseline { cancelReorder() }
        }
        .onChange(of: tmux.canReorderWindows) { _, canReorder in
            if !canReorder { cancelReorder() }
        }
    }

    private func row(number: Int, window: TmuxController.WindowInfo) -> some View {
        let windowID = window.id.rawValue
        let isActive = window.id == tmux.activeWindowId
        // Agents and programs reporting OSC 7501 share one cue: the window's
        // highest-precedence pane. The active window is already being looked
        // at, so only input requests show there.
        let cue = programStatusCenter.windowCue(
            sessionID: sessionID,
            windowID: windowID,
            agentCenter: agentCenterV2
        )
        let hasAgent = cue.hasAgent
        let agentNeedsInput = cue.tone == .needsInput
        let agentHasUnreadFinished = !isActive && (cue.tone == .finished || cue.tone == .failed)
        let resultTint = cue.tone == .failed ? T.red : T.green
        let status = programStatusCenter.windowStatus(sessionID: sessionID, windowID: windowID, agentCenter: agentCenterV2)
        let closeIsAvailable = !isDegraded
            && tmux.mode == .tmuxControl
            && tmux.isWindowListHydrated

        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                    Text(verbatim: "\(number)")
                        .font(Typography.tesseraMono(size: 10.5))
                        .foregroundStyle(T.fgFaint)
                        .frame(width: 16, alignment: .trailing)
                    if hasAgent {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                agentNeedsInput ? T.amber
                                    : (agentHasUnreadFinished ? resultTint : T.fgMuted)
                            )
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(window.name)
                            .font(Typography.tesseraMono(size: 12.5, weight: isActive ? .medium : .regular))
                            .foregroundStyle(
                                agentHasUnreadFinished && !isDegraded
                                    ? resultTint
                                    : (isActive
                                    ? (isDegraded ? T.amber : T.fg)
                                    : (isDegraded ? T.fgDim : T.fgMuted))
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let status {
                            // Attention tints; working, ready and checked
                            // results stay dim, like the rest of the row.
                            Text(verbatim: [status.app, status.text].compactMap { $0 }.joined(separator: " · "))
                                .font(Typography.tesseraMono(size: 10))
                                .foregroundStyle(
                                    isDegraded || (isActive && status.tone != .needsInput)
                                        ? T.fgDim : (status.tone?.color(T) ?? T.fgDim)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if let index = window.index, index != number {
                        Text("tmux \(index)")
                            .font(Typography.tesseraMono(size: 9.5))
                            .foregroundStyle(T.fgDim)
                    }
                    Spacer(minLength: 8)
                    if let shortcutNumber = TmuxWindowShortcutHint.digit(
                        forPosition: number,
                        windowCount: displayedWindows.count
                    ) {
                        Text(Chord([.command], .character(Character("\(shortcutNumber)")))
                                .rendered(appearance.modifierNotation))
                            .font(Typography.tesseraMono(size: 10.5))
                            .foregroundStyle(
                                isActive
                                    ? (isDegraded ? T.amber : T.accent)
                                    : T.fgFaint
                            )
                    }
            }
            .padding(.leading, 10)
            .frame(height: max(44, Self.rowHeight))
            .contentShape(Rectangle())
            .overlay {
                TmuxWindowInteractionSurface(
                    enabled: !isDegraded,
                    accessibilityLabel: windowRowAccessibilityLabel(
                        name: window.name,
                        number: number,
                        tmuxIndex: window.index,
                        hasAgent: hasAgent,
                        status: status?.text
                    ),
                    menuSections: menuSections(window: window, position: number - 1),
                    moveActions: moveAccessibilityActions(window: window, position: number - 1),
                    onTap: { onSelect(number) },
                    onTouchActive: onMenuTouch,
                    onMenuPresence: onMenuPresence,
                    onReorder: { handleReorder($0, window: window) }
                )
            }
            .accessibilityHint(
                isDegraded
                    ? LocalizedStringKey("Unavailable while tmux sync is offline")
                    : ""
            )
            // Explicit label replaces child aggregation, so fold the agent
            // sparkle's state back in — a VoiceOver user scanning the list
            // for the window whose agent needs attention has no other signal.
            .accessibilityLabel(windowRowAccessibilityLabel(
                name: window.name,
                number: number,
                tmuxIndex: window.index,
                hasAgent: hasAgent,
                status: status?.text
            ))
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("tmux-window-list-\(windowID)-row")

            TmuxTabCloseButton(
                name: window.name,
                windowID: windowID,
                isActive: isActive,
                isAvailable: closeIsAvailable,
                accessibilityHint: closeIsAvailable
                    ? (window.paneCount > 1 || tmux.isWindowLayoutPending(window.id)
                        ? "Asks before closing every pane in this window"
                        : "Closes this window")
                    : (isDegraded
                        ? "Unavailable while tmux sync is offline"
                        : "Unavailable while tmux window details are syncing"),
                scale: 1,
                T: T,
                idNamespace: "tmux-window-list"
            ) {
                onClose(window)
            }
            .padding(.trailing, 2)
        }
        .frame(height: Self.rowHeight)
        .offset(y: popoverDragOffset(for: window.id))
        .scaleEffect(draggingID == window.id ? 1.02 : 1)
        .shadow(
            color: draggingID == window.id ? Color.black.opacity(0.3) : .clear,
            radius: draggingID == window.id ? 7 : 0,
            y: draggingID == window.id ? 3 : 0
        )
        .zIndex(draggingID == window.id ? 10 : 0)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    agentHasUnreadFinished && !isDegraded
                        ? resultTint.opacity(0.14)
                        : (isActive
                        ? (isDegraded ? T.amber.opacity(0.16) : T.accentSoft)
                        : SwiftUI.Color.clear)
                )
        )
    }

    private var displayedWindows: [TmuxController.WindowInfo] {
        guard let previewOrder else { return tmux.windows }
        let byID = Dictionary(uniqueKeysWithValues: tmux.windows.map { ($0.id, $0) })
        guard Set(previewOrder) == Set(byID.keys) else { return tmux.windows }
        return previewOrder.compactMap { byID[$0] }
    }

    private func menuSections(
        window: TmuxController.WindowInfo,
        position: Int
    ) -> [TmuxWindowMenuSection] {
        let splitEnabled = !isDegraded
            && tmux.mode == .tmuxControl
            && tmux.isWindowListHydrated
            && !tmux.gridAuthority.isPeer
        return [
            tmuxSplitMenuSection(window: window, tmux: tmux, enabled: splitEnabled) { option in
                onSplit(window, option)
            },
            TmuxWindowMenuSection(actions: [
                TmuxWindowMenuAction(title: String(localized: "Rename"), systemImage: "pencil") { onRename(window) }
            ]),
            tmuxMoveMenuSection(windowID: window.id, tmux: tmux, horizontal: false, dispatch: dispatchSessionCommand),
            TmuxWindowMenuSection(actions: [TmuxWindowMenuAction(
                title: String(localized: "Close Window"),
                systemImage: "xmark",
                destructive: true,
                disabled: isDegraded || !tmux.isWindowListHydrated || tmux.gridAuthority.isPeer
            ) {
                onClose(window)
            }])
        ]
    }

    private func moveAccessibilityActions(
        window: TmuxController.WindowInfo,
        position: Int
    ) -> [TmuxWindowAccessibilityAction] {
        tmuxMoveAccessibilityActions(windowID: window.id, tmux: tmux, horizontal: false, dispatch: dispatchSessionCommand) + tmuxSplitAccessibilityActions(
            window: window,
            tmux: tmux,
            enabled: !isDegraded
                && tmux.mode == .tmuxControl
                && tmux.isWindowListHydrated
                && !tmux.gridAuthority.isPeer
        ) { option in
            onSplit(window, option)
        }
    }

    private func handleReorder(_ phase: TmuxWindowReorderPhase, window: TmuxController.WindowInfo) {
        switch phase {
        case .began(let location):
            rowDrag.begin(id: window.id, order: tmux.windows.map(\.id), pointer: location.y,
                          frameStart: Double(rowFrames[window.id]?.minY ?? location.y), enabled: tmux.canReorderWindows)
        case .changed(let location):
            if rowDrag.update(pointer: location.y, midpoints: rowFrames.mapValues { $0.midY }, enabled: tmux.canReorderWindows) {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            guard rowDrag.isDragging else { return }
            updateEdgeAutoScroll(pointerY: location.y)
        case .ended(let cancelled):
            let destination = rowDrag.finish(cancelled: cancelled || !tmux.canReorderWindows)
            cancelReorder()
            if let destination {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dispatchSessionCommand(.moveTmuxWindow(window.id.description, move: .position(destination)))
                Task { @MainActor in
                    await Task.yield()
                    dropRevealTarget = window.id
                    dropRevealToken &+= 1
                }
            }
        }
    }

    private func cancelReorder() {
        rowDrag.cancel()
        stopEdgeAutoScroll()
    }

    private func popoverDragOffset(for id: WindowId) -> CGFloat {
        guard rowDrag.id == id, let frame = rowFrames[id] else { return 0 }
        return rowDrag.offset(currentFrameStart: frame.minY)
    }

    private func updateEdgeAutoScroll(pointerY: CGFloat) {
        guard !viewportFrame.isEmpty else { return }
        let inset: CGFloat = 34
        let direction = pointerY < viewportFrame.minY + inset
            ? -1
            : (pointerY > viewportFrame.maxY - inset ? 1 : 0)
        guard direction != edgeScrollDirection else { return }
        stopEdgeAutoScroll()
        edgeScrollDirection = direction
        guard direction != 0 else { return }
        edgeScrollTask = Task { @MainActor in
            while !Task.isCancelled, draggingID != nil {
                let ordered = displayedWindows.map(\.id)
                let visible = ordered.filter { id in
                    guard let frame = rowFrames[id] else { return false }
                    return frame.maxY >= viewportFrame.minY
                        && frame.minY <= viewportFrame.maxY
                }
                let edgeID = direction < 0 ? visible.first : visible.last
                guard let edgeID, let edgeIndex = ordered.firstIndex(of: edgeID) else { break }
                let nextIndex = edgeIndex + direction
                guard ordered.indices.contains(nextIndex) else { break }
                edgeScrollTarget = ordered[nextIndex]
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func stopEdgeAutoScroll() {
        edgeScrollTask?.cancel()
        edgeScrollTask = nil
        edgeScrollDirection = 0
        edgeScrollTarget = nil
    }
}

struct TmuxPopoverWindowFramesKey: PreferenceKey {
    static let defaultValue: [WindowId: CGRect] = [:]
    static func reduce(value: inout [WindowId: CGRect], nextValue: () -> [WindowId: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct TmuxPopoverViewportFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

#if DEBUG
@MainActor
final class SessionTopBarHarnessSession: TerminalSession {
    let host = Host(name: "tmux-harness", address: "127.0.0.1")
    var state: SessionState = .connected
    let outputStream = AsyncStream<[UInt8]> { $0.finish() }
    var remoteWorkingDirectory: String?
    var pendingPathInjection: String?

    func connect() { state = .connected }
    func send(_ bytes: [UInt8]) {}
    func resize(cols: Int, rows: Int) {}
    func disconnect() { state = .disconnected }
}

/// Host-free phone fixture for the production SwiftTerm responder path.
/// It keeps the real accessory bar mounted, claims first responder at launch,
/// and exposes keyboard show/hide notifications through accessibility so an
/// iPhone simulator can verify dismissal without opening a user connection.
struct IPhoneKeyboardHarnessView: View {
    @Environment(AppearancePreferences.self) private var appearance
    @State private var terminalBox = TerminalBox(traceLabel: "iphone-keyboard-harness")
    @State private var modifierState = ModifierState()
    @State private var oracle = IPhoneKeyboardHarnessOracle()
    @State private var ownerGrid = CellRect(width: 50, height: 48, x: 0, y: 0)
    @State private var viewportRows = 0
    @State private var viewportLayoutGeneration = -1
    @State private var lastHarnessViewportSize = CGSize.zero
    @State private var findController = FindController()
    @State private var harnessFeedCount = 0
    /// Spelled wire bytes, newest last. Only built when the paste rig is armed.
    @State private var wireTrace: [String] = []
    @State private var harnessOutputFeed = Timer
        .publish(every: 0.4, on: .main, in: .common)
        .autoconnect()

    /// `TESSERA_KEYBOARD_HARNESS_PASTE=1` arms the paste/auto-period rig: a
    /// button that drives the production `paste(_:)` entry point, and the wire
    /// trace that grades what the view sends afterwards. Host-free, so the
    /// never-auto-connect rule holds.
    private var pasteRigArmed: Bool {
        ProcessInfo.processInfo.environment["TESSERA_KEYBOARD_HARNESS_PASTE"] == "1"
    }

    static let pasteRigFixture = "/tmp/tessera-mosh-history-commit.txt"

    var body: some View {
        VStack(spacing: 0) {
            // Same chrome group the sessions mount, for the same reason: the
            // find query field is an input the user reads while typing into it,
            // so it must not ride the keyboard translation off the screen top.
            KeyboardLiftExemptChrome {
                if findController.isOpen {
                    FindBar(
                        controller: findController,
                        horizontalInset: 10,
                        T: DesignTokens.make(mode: .dark, accent: .blue)
                    )
                }
            }
            .zIndex(2)

            TerminalSurfaceBound(
                initialData: Self.fixtureBytes,
                onMade: { view in
                    terminalBox.attach(view)
                    view.isAccessibilityElement = true
                    view.accessibilityIdentifier = "iphone-keyboard-terminal"
                    view.accessibilityLabel = "iPhone terminal"
                },
                onReady: { terminalBox.markRenderReady() },
                onSend: { bytes in
                    // The harness has no transport, so the wire is the record: a
                    // paste-then-type sequence is graded on the bytes the view
                    // decided to send, which is where the UITextInput mirror's
                    // backspaces would show up.
                    IPhoneKeyboardHarnessView.logWire(bytes)
                    if pasteRigArmed {
                        wireTrace.append(contentsOf: IPhoneKeyboardHarnessView.spell(bytes))
                    }
                },
                onResize: { _, _ in },
                onTitle: { _ in },
                onUserActivity: nil,
                onBell: nil,
                mouseReportingImpliesAltScreen: false,
                suppressDirectColorQueryResponses: true,
                softwareModifierState: modifierState,
                tmuxShortcutsEnabled: false,
                onTmuxShortcut: { _ in },
                onFindShortcut: nil,
                onSwitcherShortcut: nil,
                onOpenSettings: nil,
                suppressFirstResponderReclaim: modifierState.suppressesSoftwareKeyboardReclaim,
                onHardwareKey: nil
            )
            .modifier(GeometryNeutralTmuxCanvasModifier(
                windowRect: ownerGrid,
                focusRect: ownerGrid,
                cellSize: harnessCellSize,
                onViewportSize: updateOwnerGrid
            ))
            .terminalKeyboardCaretShift()

            SessionAccessoryBar(
                accent: DesignTokens.make(mode: .dark, accent: .blue).accent,
                modifierState: modifierState,
                onSend: { bytes in
                    IPhoneKeyboardHarnessView.logWire(bytes, source: "accessory")
                    terminalBox.noteOutOfBandInput()
                },
                applicationCursor: { false }
            )
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .bottom)
        .terminalKeyboardLayout(
            resizesTerminal: appearance.resizeTerminalWithKeyboard,
            caretClearance: {
                terminalBox.caretClearance(
                    cellHeight: terminalCaretCellHeight(
                        fontID: appearance.terminalFontID,
                        fontSize: appearance.fontSize
                    ),
                    mouseReportingImpliesAltScreen: false
                )
            }
        )
        .statusBarHidden(true)
        .overlay(alignment: .topLeading) {
            Text(verbatim: "keyboard \(oracle.isVisible ? "visible" : "hidden")")
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.01))
                .accessibilityIdentifier("iphone-keyboard-state")
                .accessibilityValue(oracle.isVisible ? "visible" : "hidden")
        }
        .overlay(alignment: .topTrailing) {
            let measuredRows = viewportLayoutGeneration == oracle.frameGeneration
                ? String(viewportRows)
                : "pending"
            Text(verbatim: "viewport rows \(measuredRows)")
                .foregroundStyle(Color.white.opacity(0.01))
                .accessibilityIdentifier("iphone-terminal-viewport-rows")
                .accessibilityValue(measuredRows)
        }
        .overlay(alignment: .top) {
            Button {
                // Two notifications make the regression independent of the
                // orientation tracker's initial seed. Neither represents an
                // interface rotation in this portrait harness.
                NotificationCenter.default.post(
                    name: UIDevice.orientationDidChangeNotification,
                    object: UIDevice.current
                )
                NotificationCenter.default.post(
                    name: UIDevice.orientationDidChangeNotification,
                    object: UIDevice.current
                )
            } label: {
                Color.clear.frame(width: 44, height: 44)
            }
            .accessibilityLabel("Simulate device orientation noise")
            .accessibilityIdentifier("iphone-keyboard-orientation-noise")
        }
        .overlay(alignment: .bottomLeading) {
            // Outside `terminalKeyboardLayout` on purpose: this is the test's
            // own control, not session chrome, so it must stay tappable
            // regardless of what the translation is doing to the session.
            Button {
                findController.open()
            } label: {
                Color.clear.frame(width: 44, height: 44)
            }
            .accessibilityLabel("Open find")
            .accessibilityIdentifier("iphone-keyboard-open-find")
        }
        // Outside `terminalKeyboardLayout` for the same reason as the control
        // above: the lift translates the session, and a rig control that rides
        // it leaves the screen the moment the keyboard comes up.
        .overlay(alignment: .topLeading) {
            if pasteRigArmed {
                HStack(spacing: 8) {
                    Button("paste") {
                        UIPasteboard.general.string = Self.pasteRigFixture
                        terminalBox.view?.paste(nil)
                    }
                    .accessibilityIdentifier("harness-paste")
                    Button("clear wire") { wireTrace.removeAll() }
                        .accessibilityIdentifier("harness-clear-wire")
                    Text(wireTrace.joined(separator: " "))
                        .accessibilityIdentifier("harness-wire")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black)
                .padding(.top, 56)
            }
        }
        .onReceive(harnessOutputFeed) { _ in
            // Walks the prompt down the screen the way remote output does, so
            // the caret-following half of the keyboard layout can be exercised
            // without a host — and without a touch, which would take the
            // software keyboard down with it.
            guard ProcessInfo.processInfo.environment["TESSERA_KEYBOARD_HARNESS_FEED"] == "1" else { return }
            harnessFeedCount += 1
            terminalBox.view?.feed(text: "harness output line \(harnessFeedCount)\r\n$ ")
        }
        .overlay(alignment: .topLeading) {
            Text(verbatim: "keyboard hides \(oracle.hideCount)")
                .foregroundStyle(Color.white.opacity(0.01))
                .accessibilityIdentifier("iphone-keyboard-hide-count")
                .accessibilityValue(String(oracle.hideCount))
                .offset(y: 24)
        }
        .onAppear {
            // Landscape coverage without Simulator.app automation: macOS
            // refuses Apple events from the agent's shell, so the harness asks
            // its own scene to rotate. Same geometry path the OS drives on a
            // real rotation, so safe areas and the keyboard follow. iPadOS
            // ignores the request for a multitasking-capable app and reports no
            // error; rotate an iPad through the device instead, with
            // VisualCaptureProbe/testSetLandscapeOnly.
            if let orientation = ProcessInfo.processInfo
                .environment["TESSERA_KEYBOARD_HARNESS_ORIENTATION"] {
                let mask: UIInterfaceOrientationMask =
                    orientation == "landscape" ? .landscapeRight : .portrait
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .forEach { scene in
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                            NSLog("[kbprobe] geometry update refused: %@", "\(error)")
                        }
                    }
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .forEach { window in
                        window.rootViewController?
                            .setNeedsUpdateOfSupportedInterfaceOrientations()
                    }
            }
            // `alt` stands in for vim / htop / Claude Code: an alternate-screen
            // app that paints every row, keeps its status line on the last one,
            // and parks the cursor wherever its redraw ended — here deliberately
            // near the top, the case where following the caret would hide the
            // app's bottom rows behind the keyboard. Painted after the grid has
            // settled, because an alternate buffer does not survive a resize.
            if ProcessInfo.processInfo.environment["TESSERA_KEYBOARD_HARNESS_FIXTURE"] == "alt" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let view = terminalBox.view else { return }
                    let rows = view.getTerminal().rows
                    var text = "\u{001B}[?1049h\u{001B}[2J\u{001B}[H"
                    for index in 1..<max(2, rows) {
                        text += "alt screen row \(index) — tessera keyboard fixture\r\n"
                    }
                    text += "STATUS LINE — bottom row must stay visible"
                    text += "\u{001B}[2;1H"
                    view.feed(text: text)
                }
            }
            appearance.mode = .dark
            appearance.fontSize = 13
            appearance.cursorBlink = false
            appearance.showAccessoryBar = true
            appearance.resizeTerminalWithKeyboard = ProcessInfo.processInfo.environment[
                "TESSERA_KEYBOARD_RESIZE_HARNESS"
            ] == "1"
            appearance.accessoryBarKeys = AccessoryChip.defaultBarOrder.map(\.rawValue)
            oracle.start()
        }
        .onDisappear {
            oracle.stop()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard ProcessInfo.processInfo.environment["TESSERA_KEYBOARD_HARNESS_DEBUG"] == "1" else { return }
            guard let view = terminalBox.view else { return }
            let terminal = view.getTerminal()
            let cell = harnessCellSize
            let windowFrame = view.superview?.convert(view.frame, to: nil) ?? .zero
            let window = view.window
            NSLog("[kbprobe] viewFrameInWindow=%@ bounds=%@ contentSize=%@ contentOffset=%.1f rows=%d cols=%d yDisp=%d cellH=%.2f windowH=%.1f safeBottom=%.1f adjInset=%@ behavior=%d",
                  NSCoder.string(for: windowFrame),
                  NSCoder.string(for: view.bounds),
                  NSCoder.string(for: view.contentSize),
                  view.contentOffset.y,
                  terminal.rows,
                  terminal.cols,
                  terminal.buffer.yDisp,
                  cell.height,
                  window?.bounds.height ?? -1,
                  window?.safeAreaInsets.bottom ?? -1,
                  NSCoder.string(for: view.adjustedContentInset),
                  view.contentInsetAdjustmentBehavior.rawValue)
        }
        .onChange(of: oracle.settledGeneration) { _, _ in
            guard lastHarnessViewportSize != .zero else { return }
            updateOwnerGrid(lastHarnessViewportSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            terminalBox.dismissTransientInteractionsIfInterfaceOrientationChanged()
        }
    }

    /// The harness's stand-in for a transport. Every byte the view decides to
    /// send is named here, so a paste-then-type sequence can be graded on the
    /// wire without opening a connection: a `del` in that stream after a paste
    /// is the UITextInput mirror reaching back over text it does not own.
    fileprivate static func spell<S: Sequence<UInt8>>(_ bytes: S) -> [String] {
        bytes.map { byte in
            switch byte {
            case 0x7f: return "del"
            case 0x08: return "bs"
            case 0x1b: return "esc"
            case 0x0d: return "cr"
            case 0x20: return "sp"
            case 0x21...0x7e: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02x", byte)
            }
        }
    }

    fileprivate static func logWire<S: Sequence<UInt8>>(_ bytes: S, source: String = "terminal") {
        let spelled = spell(bytes)
        NSLog(
            "[kbwire] source=%@ n=%d bytes=[%@]",
            source,
            spelled.count,
            spelled.joined(separator: " ")
        )
    }

    private static var fixtureBytes: [UInt8] {
        // `long` stands in for "the user just ran `cat /etc/services`": a full
        // screen of output with scrollback above it and the prompt parked on
        // the last row. That is the state the accessory-bar occlusion and the
        // caret-aware keyboard lift both have to survive.
        if ProcessInfo.processInfo.environment["TESSERA_KEYBOARD_HARNESS_FIXTURE"] == "long" {
            var text = "\u{001B}[2J\u{001B}[H"
            for index in 1...400 {
                text += "services line \(index) — tessera keyboard fixture\r\n"
            }
            text += "$ "
            return Array(text.utf8)
        }
        return Array(
            (
                "\u{001B}[2J\u{001B}[H"
                    + "Tessera iPhone terminal - 13 pt\r\n"
                    + "Readable phone-owned tmux viewport\r\n"
                    + "$ tmux list-windows\r\n"
                    + "0: shell*  1: htop  2: vim\r\n"
                    + "$ _"
            ).utf8
        )
    }

    private var harnessCellSize: CGSize {
        let font = TerminalFontResolver.uiFont(
            id: appearance.terminalFontID,
            size: CGFloat(appearance.fontSize)
        )
        return TerminalCellMetrics.cellSize(font: font, scale: UIScreen.main.scale)
    }

    private func updateOwnerGrid(_ size: CGSize) {
        lastHarnessViewportSize = size
        let cellSize = harnessCellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return }
        let cols = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        let next = CellRect(width: cols, height: rows, x: 0, y: 0)
        ownerGrid = next
        viewportRows = rows
        viewportLayoutGeneration = oracle.frameGeneration
    }
}

@Observable
private final class IPhoneKeyboardHarnessOracle {
    private(set) var isVisible = false
    private(set) var hideCount = 0
    private(set) var frameGeneration = 0
    private(set) var settledGeneration = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.frameGeneration += 1
            },
            center.addObserver(
                forName: UIResponder.keyboardDidShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isVisible = true
                self?.settledGeneration += 1
            },
            center.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isVisible = false
                self?.hideCount += 1
                self?.settledGeneration += 1
            },
        ]
    }

    func stop() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}

/// DEBUG stand-in for the tmux server behind host-free harnesses. It answers
/// each command by expanding the command's own format against fixture windows/panes.
/// Positional replies broke when c8b95e525 changed the attach-init batch.
@MainActor
final class TmuxHarnessServer {
    struct Pane {
        let id: Int
        var left = 0
        var top = 0
        let width: Int
        let height: Int
        var active = true
        var command = ""
        let title: String
    }

    struct Window {
        let id: Int
        let name: String
        let layout: String
        let visibleLayout: String
        let zoomed: Bool
        let panes: [Pane]

        init(
            id: Int,
            name: String,
            layout: String,
            visibleLayout: String? = nil,
            zoomed: Bool = false,
            panes: [Pane]
        ) {
            self.id = id
            self.name = name
            self.layout = layout
            self.visibleLayout = visibleLayout ?? layout
            self.zoomed = zoomed
            self.panes = panes
        }
    }

    enum Answer {
        case reply(body: String = "", then: String = "")
        case unanswered(then: String = "")
    }

    var windows: [Window]
    var answerOverride: ((String) -> Answer?)?
    private let activeWindowID: Int
    private let version: String
    private weak var controller: TmuxController?
    private var responseNumber = 1
    private var pendingCommands: [String] = []
    private var isDraining = false
    private var drainScheduled = false
    private var commandGeneration = 0

    init(controller: TmuxController, windows: [Window], activeWindowID: Int, version: String = "") {
        self.controller = controller
        self.windows = windows
        self.activeWindowID = activeWindowID
        self.version = version
        controller.sendBytes = { [self] bytes in
            let commands = String(decoding: bytes, as: UTF8.self)
                .split(whereSeparator: { $0.isNewline })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !commands.isEmpty else { return }
            pendingCommands.append(contentsOf: commands)
            commandGeneration += 1
            guard !isDraining, !drainScheduled else { return }
            drainScheduled = true
            DispatchQueue.main.async { [self] in
                drainScheduled = false
                drain()
            }
        }
    }

    func attach(sessionChanged: Bool = false) {
        controller?.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        if sessionChanged {
            controller?.ingest(Array("%session-changed $0 tmux-lab\r\n".utf8))
        }
        controller?.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !pendingCommands.isEmpty {
            let command = pendingCommands.removeFirst()
            let answer = answerOverride?(command) ?? defaultAnswer(for: command)
            let frame: String
            switch answer {
            case .reply(let body, let notifications):
                responseNumber += 1
                frame = "%begin 0 \(responseNumber) 1\r\n"
                    + body
                    + "%end 0 \(responseNumber) 1\r\n"
                    + notifications
            case .unanswered(let notifications):
                frame = notifications
            }
            if !frame.isEmpty {
                controller?.ingest(Array(frame.utf8))
            }
        }
    }

    func afterReplies(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { [self] in
            guard pendingCommands.isEmpty, !isDraining, !drainScheduled else {
                afterReplies(body)
                return
            }
            // Allow deferred subscription writes another main-actor turn.
            let generation = commandGeneration
            DispatchQueue.main.async { [self] in
                guard pendingCommands.isEmpty, !isDraining, !drainScheduled,
                      commandGeneration == generation else {
                    afterReplies(body)
                    return
                }
                body()
            }
        }
    }

    func reorderWindows(for command: String) -> Bool {
        if command.hasPrefix("move-window -d "),
           let source = Self.windowID(after: "-s", in: command),
           let target = Self.windowID(after: "-t", in: command),
           let sourceIndex = windows.firstIndex(where: { $0.id == source }) {
            let window = windows.remove(at: sourceIndex)
            if let targetIndex = windows.firstIndex(where: { $0.id == target }) {
                windows.insert(window, at: command.contains(" -b ") ? targetIndex : targetIndex + 1)
            }
            return true
        }
        if command.hasPrefix("swap-window -d "),
           let source = Self.windowID(after: "-s", in: command),
           let target = Self.windowID(after: "-t", in: command),
           let sourceIndex = windows.firstIndex(where: { $0.id == source }),
           let targetIndex = windows.firstIndex(where: { $0.id == target }) {
            windows.swapAt(sourceIndex, targetIndex)
            return true
        }
        return false
    }

    static func windowID(after flag: String, in command: String) -> Int? {
        let fields = command.split(separator: " ")
        guard let flagIndex = fields.firstIndex(of: Substring(flag)), flagIndex + 1 < fields.count else {
            return nil
        }
        let target = fields[flagIndex + 1]
        guard let marker = target.lastIndex(of: "@") else { return nil }
        return Int(target[target.index(after: marker)...])
    }

    private func defaultAnswer(for command: String) -> Answer {
        guard let firstQuote = command.firstIndex(of: "'"),
              let lastQuote = command.lastIndex(of: "'"),
              firstQuote < lastQuote
        else { return .reply() }
        let format = String(command[command.index(after: firstQuote)..<lastQuote])
        if command.hasPrefix("list-windows ") {
            return .reply(body: windows.map { row(format, window: $0) }.joined())
        }
        if command.hasPrefix("list-panes -s ") {
            return .reply(body: windows.map { window in
                window.panes.map { row(format, window: window, pane: $0) }.joined()
            }.joined())
        }
        if command.hasPrefix("display-message -p ") {
            let windowID = command.hasPrefix("display-message -p -t ")
                ? Self.windowID(after: "-t", in: command)
                : activeWindowID
            guard let window = windows.first(where: { $0.id == windowID }) else { return .reply() }
            return .reply(body: row(format, window: window))
        }
        return .reply()
    }

    private func row(_ format: String, window: Window, pane: Pane? = nil) -> String {
        let activePane = window.panes.first(where: { $0.active })
        var variables = [
            "window_id": "@\(window.id)",
            "window_index": "\((windows.firstIndex(where: { $0.id == window.id }) ?? 0) + 1)",
            "window_layout": window.layout,
            "window_visible_layout": window.visibleLayout,
            "window_zoomed_flag": window.zoomed ? "1" : "0",
            "window_name": window.name,
            "window_active": window.id == activeWindowID ? "1" : "0",
            "pane_id": activePane.map { "%\($0.id)" } ?? "",
            "session_id": "$0",
            "session_name": "tmux-lab",
            "version": version,
            "host": "host",
        ]
        if let pane {
            variables["pane_id"] = "%\(pane.id)"
            variables["pane_active"] = pane.active ? "1" : "0"
            variables["pane_left"] = String(pane.left)
            variables["pane_top"] = String(pane.top)
            variables["pane_width"] = String(pane.width)
            variables["pane_height"] = String(pane.height)
            variables["pane_current_command"] = pane.command
            variables["pane_title"] = pane.title
        }
        var remaining = format[...]
        var result = ""
        while let start = remaining.range(of: "#{"),
              let end = remaining[start.upperBound...].firstIndex(of: "}") {
            result += remaining[..<start.lowerBound]
            let expression = String(remaining[start.upperBound..<end])
            if expression.hasPrefix("s/"), let colon = expression.lastIndex(of: ":") {
                let name = String(expression[expression.index(after: colon)...])
                result += (variables[name] ?? "").replacingOccurrences(of: "\t", with: " ")
            } else {
                result += variables[expression] ?? ""
            }
            remaining = remaining[remaining.index(after: end)...]
        }
        return result + remaining + "\r\n"
    }
}

/// Host-free compact-session fixture. It mounts the production phone chrome,
/// two-level tmux switcher, modifier bar, and SwipePad without opening any
/// transport. `TESSERA_IPHONE_SESSION_HARNESS_MODE=palette` opens the switcher
/// at launch for deterministic screenshots.
struct IPhoneCompanionHarnessView: View {
    private let sessionID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!

    @State private var appearance: AppearancePreferences
    @State private var agentCenterV2 = AgentCenterV2Coordinator()
    @State private var programStatusCenter = ProgramStatusCenter()
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux: TmuxController
    @State private var commandSession = SessionTopBarHarnessSession()
    @State private var findController = FindController()
    @State private var modifierState = ModifierState()
    @State private var continuityActionResult = "none"
    @Environment(BellController.self) private var bellController
    @Environment(SwipePadProfileStore.self) private var swipePadStore
    @Environment(SpeechDictationController.self) private var dictationController

    init() {
        let orderingHarness = ProcessInfo.processInfo.environment[
            "TESSERA_TMUX_WINDOW_REORDER_HARNESS"
        ] == "1"
        let appearance = AppearancePreferences()
        appearance.mode = .dark
        appearance.showAccessoryBar = true
        appearance.swipePadEnabled = true
        appearance.swipePadCorner = "bottomRight"
        appearance.swipePadSize = "standard"
        appearance.modifierBehavior = "oneShot"
        appearance.agentCenterEnabled = true
        appearance.accessoryBarKeys = AccessoryChip.defaultBarOrder.map(\.rawValue)
        _appearance = State(initialValue: appearance)

        let controller = TmuxController(
            controlPath: .sideChannel,
            clientSizePolicy: .preserveServerGeometry
        )
        let server = TmuxHarnessServer(controller: controller, windows: [
            .init(
                id: 1, name: "dev",
                layout: "8205,160x48,0,0{80x48,0,0,20,79x48,81,0,21}",
                panes: [
                    .init(id: 20, width: 80, height: 48, active: false, title: "nvim"),
                    .init(id: 21, left: 81, width: 79, height: 48, title: "zsh"),
                ]
            ),
            .init(id: 2, name: "htop", layout: "b25d,160x48,0,0,30", panes: [
                .init(id: 30, width: 160, height: 48, title: "htop"),
            ]),
            .init(id: 3, name: "logs", layout: "b25d,160x48,0,0,40", panes: [
                .init(id: 40, width: 160, height: 48, title: "logs"),
            ]),
        ], activeWindowID: 1)
        if orderingHarness {
            server.answerOverride = { [weak server] command in
                if command.hasPrefix(TmuxSessionGroupQuery.command) {
                    return .reply(body: "$0\t\t@1\r\n")
                }
                if server?.reorderWindows(for: command) == true {
                    return .reply()
                }
                return nil
            }
        }
        server.attach(sessionChanged: orderingHarness)
        if orderingHarness {
            server.afterReplies { [weak controller] in
                controller?.ingest(Array("%session-changed $0 tmux-lab\r\n".utf8))
            }
        }
        _tmux = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                SessionTopBar(
                    state: .connected,
                    host: Host(
                        name: "zeus",
                        address: "zeus.local",
                        transport: .mosh,
                        autoTmux: true,
                        launchMode: .autoTmux
                    ),
                    sessionID: sessionID,
                    sessionIsActive: false,
                    tmux: tmux,
                    sessionCommands: commandSession.sessionCommands(tmux: tmux),
                    tmuxIsDegraded: false,
                    connectionStatus: .mosh(
                        sessionState: .connected,
                        transportState: .connected,
                        tcpControl: .connected
                    ),
                    onToggleSidebar: {},
                    sidebarVisible: false,
                    onBack: {},
                    onDisconnect: {},
                    findController: findController,
                    filesPanelOpen: false,
                    onToggleFiles: {},
                    bellController: bellController,
                    forwarderManager: nil,
                    T: chrome,
                    continuityActions: ProcessInfo.processInfo.environment[
                        "TESSERA_IPHONE_SESSION_HARNESS_MODE"
                    ] == "continuity"
                        ? SessionContinuityActions(
                            continueSession: {
                                continuityActionResult = "continue"
                            },
                            setUpAndContinue: {
                                continuityActionResult = "set-up"
                            }
                        )
                        : nil
                )
                .frame(
                    height: SessionTopBar.reservedHeight(
                        pillHeight: appearance.topBarHeight,
                        compact: true
                    )
                )

                fakeTerminal

                SessionAccessoryBar(
                    accent: chrome.accent,
                    modifierState: modifierState,
                    onSend: { _ in },
                    applicationCursor: { false }
                )
            }

            SwipePadOverlay(
                onSend: { _ in },
                tmux: tmux,
                profileStore: swipePadStore,
                dictationController: dictationController
            )
            .padding(.top, SessionTopBar.reservedHeight(
                pillHeight: appearance.topBarHeight,
                compact: true
            ))
            .padding(.horizontal, 10)
            .padding(.bottom, 52)
            .zIndex(5)

            if palette.isOpen {
                CommandPaletteView(
                    palette: palette,
                    onTmuxClose: registry.requestTmuxClose,
                    onTmuxMutation: handleHarnessMutation
                ) { _ in }
                    .zIndex(20)
            }
        }
        .environment(appearance)
        .environment(agentCenterV2)
        .environment(programStatusCenter)
        .environment(registry)
        .environment(palette)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .overlay(alignment: .bottomTrailing) {
            VStack {
                Text(verbatim: continuityActionResult)
                    .accessibilityLabel("Continuity action result")
                    .accessibilityValue(continuityActionResult)
                    .accessibilityIdentifier("continuity-action-result")
                if ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_REORDER_HARNESS"] == "1" {
                    Text(verbatim: tmux.windows.map(\.id.description).joined(separator: ","))
                        .accessibilityLabel("Tmux window order")
                        .accessibilityValue(tmux.windows.map(\.id.description).joined(separator: ","))
                        .accessibilityIdentifier("tmux-window-order-value")
                    Text(verbatim: tmux.activeWindowId?.description ?? "none")
                        .accessibilityLabel("Active tmux window")
                        .accessibilityValue(tmux.activeWindowId?.description ?? "none")
                        .accessibilityIdentifier("tmux-window-active-value")
                }
            }
            .font(Typography.tesseraMono(size: 1))
            .foregroundStyle(Color.white.opacity(0.01))
        }
        .onAppear {
            let mode = ProcessInfo.processInfo.environment[
                "TESSERA_IPHONE_SESSION_HARNESS_MODE"
            ]
            if mode == "palette"
                || ProcessInfo.processInfo.environment["TESSERA_TMUX_WINDOW_REORDER_HARNESS"] == "1" {
                openPalette()
            } else if mode == "ctrl" {
                modifierState.tap(.ctrl)
            } else if mode == "find" {
                findController.open()
            }
        }
    }

    private var chrome: DesignTokens {
        TerminalTheme.find(id: appearance.terminalThemeID)
            .chromeTokens(applying: appearance)
    }

    private var fakeTerminal: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "pane %21 · zsh · full-screen local view")
                    .foregroundStyle(chrome.accent)
                Text(verbatim: "$ git status --short")
                Text(verbatim: " M Tessera/SessionView.swift")
                Text(verbatim: "$ swift test")
                Text(verbatim: "Building for debugging…")
                Text(verbatim: "Test Suite 'TmuxControlTests' passed")
                    .foregroundStyle(chrome.green)
                Spacer()
                Text(verbatim: "zeus ~/projects/tessera $ _")
            }
            .font(Typography.tesseraMono(size: 12))
            .foregroundStyle(Color.white.opacity(0.84))
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
        }
        .background(Color.black)
        .accessibilityIdentifier("iphone-session-harness")
    }

    private func openPalette() {
        let windows = tmux.windows.enumerated().map { position, window in
            CommandPaletteTmuxWindow(
                id: window.id,
                title: window.displayName,
                renameSeed: window.windowName,
                position: position,
                tmuxIndex: window.index,
                panes: window.panes.map {
                    CommandPaletteTmuxPane(
                        id: $0.id,
                        title: $0.currentCommand ?? window.displayName,
                        command: $0.currentCommand
                    )
                }
            )
        }
        palette.open(
            sessions: [],
            tmuxWindows: windows,
            currentSessionID: sessionID,
            activeWindowID: tmux.activeWindowId,
            activePaneID: tmux.activePaneId,
            includesHome: true,
            canReorderTmuxWindows: tmux.canReorderWindows,
            canTidyTmuxWindows: tmux.canTidyWindows
        )
    }

    private func handleHarnessMutation(_ mutation: CommandPaletteTmuxMutation) {
        switch mutation {
        case .moveWindow(let targetSessionID, let windowID, let move):
            guard targetSessionID == sessionID else { return }
            _ = commandSession.sessionCommands(tmux: tmux).dispatch(.moveTmuxWindow(windowID.description, move: move))
        case .renumberWindows(let targetSessionID):
            guard targetSessionID == sessionID else { return }
            _ = commandSession.sessionCommands(tmux: tmux).dispatch(.renumberTmuxWindows)
        case .split, .rename:
            registry.requestTmuxMutation(mutation)
        }
    }
}

/// close branch without initiating a connection. It includes a single-pane
/// window, a split window, and a zoomed split window (whose visible layout is
/// one pane while its full layout still contains two).
struct TmuxWindowCloseHarnessView: View {
    private let sessionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    @State private var appearance: AppearancePreferences
    @State private var agentCenterV2 = AgentCenterV2Coordinator()
    @State private var programStatusCenter = ProgramStatusCenter()
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux: TmuxController
    @State private var commandSession = SessionTopBarHarnessSession()
    @State private var findController = FindController()
    @Environment(BellController.self) private var bellController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init() {
        let appearance = AppearancePreferences()
        appearance.agentCenterEnabled = false
        _appearance = State(initialValue: appearance)

        let controller = TmuxController(controlPath: .sideChannel)
        let server = TmuxHarnessServer(controller: controller, windows: [
            .init(id: 1, name: "editor", layout: "b25d,80x24,0,0,10", panes: [
                .init(id: 10, width: 80, height: 24, title: "editor"),
            ]),
            .init(
                id: 2, name: "dashboard",
                layout: "8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21}",
                panes: [
                    .init(id: 20, width: 40, height: 24, title: "dashboard-left"),
                    .init(id: 21, left: 41, width: 39, height: 24, active: false, title: "dashboard-right"),
                ]
            ),
            .init(
                id: 3, name: "logs",
                layout: "9205,80x24,0,0{40x24,0,0,30,39x24,41,0,31}",
                visibleLayout: "b25d,80x24,0,0,30", zoomed: true,
                panes: [
                    .init(id: 30, width: 40, height: 24, title: "logs-top"),
                    .init(id: 31, left: 41, width: 39, height: 24, active: false, title: "logs-bottom"),
                ]
            ),
        ], activeWindowID: 2)
        server.answerOverride = { [weak server] command in
            // The fresh window's details stay empty so it remains un-hydrated
            // until a full window-list refresh describes it.
            if command == TmuxRuntimeHydrationQuery.windowDetailsCommand(windowID: WindowId(4)) {
                return .reply()
            }
            guard command.hasPrefix("kill-window -t @"),
                  let windowID = TmuxHarnessServer.windowID(after: "-t", in: command)
            else { return nil }
            server?.windows.removeAll { $0.id == windowID }
            return .reply(then: "%unlinked-window-close @\(windowID)\r\n")
        }
        server.attach()
        server.afterReplies { [weak controller, weak server] in
            // A freshly-created window: bare %window-add, no layout. It joins
            // the server's windows so a later order refresh keeps it.
            server?.windows.append(.init(id: 4, name: "scratch", layout: "d960,80x24,0,0,40", panes: [
                .init(id: 40, width: 80, height: 24, title: "scratch"),
            ]))
            controller?.ingest(Array(
                "%window-add @4\r\n%window-renamed @4 scratch\r\n".utf8
            ))
        }
        _tmux = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                SessionTopBar(
                    state: .connected,
                    host: Host(
                        name: "tmux-lab",
                        address: "tmux-lab.local",
                        autoTmux: true,
                        launchMode: .autoTmux
                    ),
                    sessionID: sessionID,
                    sessionIsActive: false,
                    tmux: tmux,
                    sessionCommands: commandSession.sessionCommands(tmux: tmux),
                    tmuxIsDegraded: false,
                    connectionStatus: .ssh(state: .connected),
                    onToggleSidebar: {},
                    sidebarVisible: false,
                    onBack: {},
                    onDisconnect: {},
                    findController: findController,
                    filesPanelOpen: false,
                    onToggleFiles: {},
                    bellController: bellController,
                    forwarderManager: nil,
                    T: DesignTokens.make(mode: .dark, accent: .blue)
                )
                .frame(height: SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: CompactLayout.isPhone(horizontalSizeClass)
                ))

                Text(verbatim: "Single pane · split panes · zoomed split")
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.top, 28)
                    .accessibilityIdentifier("tmux-window-close-harness")
                Spacer()
            }
        }
        .environment(appearance)
        .environment(agentCenterV2)
        .environment(programStatusCenter)
        .environment(registry)
        .environment(palette)
        // This host-free fixture uses the production-height tab strip as its
        // entire top chrome. Keep iPadOS's system status text out of that
        // 28pt capture surface; production sessions set the same policy in
        // their session views.
        .statusBarHidden(true)
    }
}

/// UITest harness for the tab-overflow window list: enough hydrated
/// windows that the strip genuinely overflows (so the chevron and its
/// popover exist), one already-split window near the active one, and a
/// freshly-added window whose `%window-add` details query is never
/// answered — its pane count stays a guess, pinning the fail-closed
/// close confirmation for the layout-pending gap. `kill-window` sends
/// are answered ONLY with the `%unlinked-window-close` notification (no
/// `%begin`/`%end` reply), which keeps that details query owed for the
/// whole test.
struct TmuxWindowListHarnessView: View {
    private let sessionID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    @State private var appearance: AppearancePreferences
    @State private var agentCenterV2 = AgentCenterV2Coordinator()
    @State private var programStatusCenter = ProgramStatusCenter()
    @State private var registry = SessionRegistry()
    @State private var palette = CommandPalette()
    @State private var tmux: TmuxController
    @State private var commandSession = SessionTopBarHarnessSession()
    @State private var findController = FindController()
    @Environment(BellController.self) private var bellController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init() {
        let orderingHarness = ProcessInfo.processInfo.environment[
            "TESSERA_TMUX_WINDOW_REORDER_HARNESS"
        ] == "1"
        let appearance = AppearancePreferences()
        appearance.agentCenterEnabled = false
        _appearance = State(initialValue: appearance)

        let controller = TmuxController(controlPath: .sideChannel)
        let windows: [TmuxHarnessServer.Window] = (1...15).map { id in
            if id == 14 {
                return .init(
                    id: 14, name: "dashboard",
                    layout: "8205,80x24,0,0{40x24,0,0,140,39x24,41,0,141}",
                    panes: [
                        .init(id: 140, width: 40, height: 24, title: "dash-left"),
                        .init(id: 141, left: 41, width: 39, height: 24, active: false, title: "dash-right"),
                    ]
                )
            }
            return .init(id: id, name: "w\(id)", layout: "b25d,80x24,0,0,\(id * 10)", panes: [
                .init(id: id * 10, width: 80, height: 24, title: "w\(id)"),
            ])
        }
        // Active window @15: the popover auto-centers it, keeping the rows
        // the tests tap (@13/@14/@16) on screen in the 420pt panel.
        let server = TmuxHarnessServer(controller: controller, windows: windows, activeWindowID: 15)
        var detailsPending = false
        server.answerOverride = { [weak server] command in
            if orderingHarness {
                if command.hasPrefix(TmuxSessionGroupQuery.command) {
                    return .reply(body: "$0\t\t@15\r\n")
                }
                if server?.reorderWindows(for: command) == true {
                    return .reply()
                }
            } else if command.hasPrefix("display-message -p -t @16 "),
                      command.contains("__tessera_window_details__") {
                detailsPending = true
                return .unanswered()
            }
            if command.hasPrefix("kill-window -t @"),
               let windowID = TmuxHarnessServer.windowID(after: "-t", in: command) {
                server?.windows.removeAll { $0.id == windowID }
                let notification = "%unlinked-window-close @\(windowID)\r\n"
                return detailsPending ? .unanswered(then: notification) : .reply(then: notification)
            }
            return detailsPending ? .unanswered() : nil
        }
        server.attach(sessionChanged: orderingHarness)
        server.afterReplies { [weak controller, weak server] in
            guard let controller, let server else { return }
            if orderingHarness {
                controller.ingest(Array("%session-changed $0 tmux-lab\r\n".utf8))
                let orderValue = server.windows.enumerated().map { position, window in
                    "\(position + 1)=@\(window.id)\(window.id == 15 ? "*" : "")"
                }.joined(separator: " ")
                // A real tmux server publishes this session-scoped subscription
                // after registration; it is the live authority for order/index changes.
                controller.ingest(Array((
                    "%subscription-changed tessera-window-order $0 - - - : "
                        + orderValue
                        + "\r\n"
                ).utf8))
            } else {
                controller.ingest(Array(
                    "%window-add @16\r\n%window-renamed @16 fresh\r\n".utf8
                ))
            }
            if ProcessInfo.processInfo.environment["TESSERA_PROGRAM_STATUS_HARNESS"] == "1" {
                ProgramStatusHarnessReports.ingest(into: controller, [
                    (130, "state=blocked:kind=question:app=deploy"),
                    (140, "state=error:app=cargo"),
                    (141, "state=working:app=pytest:progress=42"),
                    (150, "state=done:app=make"),
                    (120, "state=idle:app=htop"),
                ])
            }
        }
        _tmux = State(initialValue: controller)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                SessionTopBar(
                    state: .connected,
                    host: Host(
                        name: "tmux-lab",
                        address: "tmux-lab.local",
                        autoTmux: true,
                        launchMode: .autoTmux
                    ),
                    sessionID: sessionID,
                    sessionIsActive: false,
                    tmux: tmux,
                    sessionCommands: commandSession.sessionCommands(tmux: tmux),
                    tmuxIsDegraded: false,
                    connectionStatus: .ssh(state: .connected),
                    onToggleSidebar: {},
                    sidebarVisible: false,
                    onBack: {},
                    onDisconnect: {},
                    findController: findController,
                    filesPanelOpen: false,
                    onToggleFiles: {},
                    bellController: bellController,
                    forwarderManager: nil,
                    T: DesignTokens.make(mode: .dark, accent: .blue)
                )
                .frame(height: SessionTopBar.reservedHeight(
                    pillHeight: appearance.topBarHeight,
                    compact: CompactLayout.isPhone(horizontalSizeClass)
                ))

                Text(verbatim: "Overflowing strip · window list popover")
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.top, 28)
                    .accessibilityIdentifier("tmux-window-list-harness")
                Text(verbatim: tmux.windows.map(\.id.description).joined(separator: ","))
                    .font(.system(size: 1))
                    .foregroundStyle(Color.white.opacity(0.01))
                    .accessibilityLabel("Tmux window order")
                    .accessibilityValue(tmux.windows.map(\.id.description).joined(separator: ","))
                    .accessibilityIdentifier("tmux-window-order-value")
                Text(verbatim: tmux.activeWindowId?.description ?? "none")
                    .font(.system(size: 1))
                    .foregroundStyle(Color.white.opacity(0.01))
                    .accessibilityLabel("Active tmux window")
                    .accessibilityValue(tmux.activeWindowId?.description ?? "none")
                    .accessibilityIdentifier("tmux-window-active-value")
                Text(verbatim: tmux.windows.map {
                    "\($0.id.description):\($0.index.map(String.init) ?? "nil")"
                }.joined(separator: ","))
                    .font(.system(size: 1))
                    .foregroundStyle(Color.white.opacity(0.01))
                    .accessibilityLabel("Tmux window indexes")
                    .accessibilityValue(tmux.windows.map {
                        "\($0.id.description):\($0.index.map(String.init) ?? "nil")"
                    }.joined(separator: ","))
                    .accessibilityIdentifier("tmux-window-index-value")
                Spacer()
            }
        }
        .environment(appearance)
        .environment(agentCenterV2)
        .environment(programStatusCenter)
        .environment(registry)
        .environment(palette)
        .statusBarHidden(true)
        .task {
            guard ProcessInfo.processInfo.environment["TESSERA_PROGRAM_STATUS_HARNESS"] == "1" else { return }
            programStatusCenter.publish(sessionID: sessionID, hostLabel: "tmux-lab", tmux: tmux)
        }
    }
}

/// DEBUG harness input: OSC 7501 reports delivered as tmux `%output`, which
/// octal-escapes control bytes, so they take the production control path.
enum ProgramStatusHarnessReports {
    @MainActor
    static func ingest(into controller: TmuxController, _ reports: [(pane: Int, body: String)]) {
        controller.programStatusEnabled = true
        for report in reports {
            controller.ingest(Array("%output %\(report.pane) \\033]7501;\(report.body)\\007\r\n".utf8))
        }
    }
}
#endif
