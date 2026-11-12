import SwiftUI
import UIKit

struct DuoWorkspaceState: Equatable {
    var contextHidden = false
    var fullScreen = false
    var swapped = false
    /// Laptop pose with a session: the context and the session traded
    /// places, so the context stands in the upper half, where typing
    /// happens, and the session lies live on the desk below the fold.
    var deskTraded = false

    /// One pane has no room for the context, so the book only shows, and
    /// only acts, beside a second pane.
    mutating func toggleContext(arrangement: DuoPaneArrangement) {
        guard arrangement != .single else { return }
        if fullScreen {
            fullScreen = false
            contextHidden = false
        } else {
            contextHidden.toggle()
        }
    }

    /// The context sits beside the main pane: the rail's book reads as
    /// pressed, and stops when the context hides or either pane fills.
    func showsContextPane(arrangement: DuoPaneArrangement) -> Bool {
        arrangement != .single && !contextHidden && !fullScreen
    }

    mutating func toggleFullScreen() {
        fullScreen.toggle()
        contextHidden = false
    }

    mutating func swap() {
        swapped.toggle()
    }

    /// ⇄ on the laptop desk, or the keyboard rising for the pane down there.
    mutating func tradeDesk() {
        deskTraded.toggle()
    }

    /// On the laptop desk the session stays on top, where the keyboard can't
    /// cover it, and the context shows, until the two trade places. The
    /// rail's swap, full screen and hidden context wait for the rail, which
    /// has the buttons that undo them.
    func laidOut(onTheDesk: Bool) -> DuoWorkspaceState {
        guard onTheDesk else { return self }
        var laidOut = self
        laidOut.swapped = deskTraded
        laidOut.fullScreen = false
        laidOut.contextHidden = false
        return laidOut
    }
}

/// Laptop pose types in the upper half: the keyboard rises from the fold's
/// top over the whole desk, so a field down there would be typed into blind.
enum DuoDeskTradePolicy {
    /// The keyboard rose over the pane on the desk: the first responder's
    /// visible frame is centred in the desk and the keyboard covers that
    /// centre. A Duo's covers the whole desk. A shorter one, like a phone
    /// rig's keyboard or a hardware keyboard's shortcut bar, trades only when
    /// it hides the field. A field elsewhere (the pane on top, a sheet) needs
    /// no trade.
    static func trades(responder: CGRect?, desk: CGRect?, keyboardTop: CGFloat) -> Bool {
        guard let responder, let desk, !responder.isNull, !responder.isEmpty else { return false }
        let centre = CGPoint(x: responder.midX, y: responder.midY)
        return desk.contains(centre) && keyboardTop < centre.y
    }
}

/// The view holding the keyboard, as UIKit sees it.
@MainActor
enum DuoKeyboardResponder {
    /// The key window's first responder, clipped by the scroll views and
    /// other clipping views around it, in window coordinates: a web form's
    /// content view to its web view, a text field to its list. Nil for one
    /// in a presented sheet or alert, which places its own fields.
    static func visibleFrame(in window: UIWindow) -> CGRect? {
        guard let view = firstResponder(in: window), !isPresented(view) else { return nil }
        var frame = view.convert(view.bounds, to: nil)
        var ancestor = view.superview
        while let current = ancestor {
            if current.clipsToBounds { frame = frame.intersection(current.convert(current.bounds, to: nil)) }
            ancestor = current.superview
        }
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func firstResponder(in window: UIWindow) -> UIView? {
        var pending: [UIView] = [window]
        while let view = pending.popLast() {
            if view.isFirstResponder { return view }
            pending.append(contentsOf: view.subviews.filter { !$0.isHidden })
        }
        return nil
    }

    private static func isPresented(_ view: UIView) -> Bool {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controller.presentingViewController != nil }
            responder = current.next
        }
        return false
    }
}

struct DuoWorkspaceActions {
    var arrangement: DuoPaneArrangement
    var isFullScreen: Bool
    var isSwapped: Bool
    var isContextShown: Bool
    var toggleContext: () -> Void
    var toggleFullScreen: () -> Void
    var swap: () -> Void
    /// Whether the pane headers offer full screen; see `offersFullScreen(arrangement:onTheDesk:)`.
    var offersFullScreen = true

    /// One pane has no other to leave, and the laptop desk trades its halves
    /// with ⇄ instead, so neither offers full screen.
    static func offersFullScreen(arrangement: DuoPaneArrangement, onTheDesk: Bool) -> Bool {
        arrangement != .single && !onTheDesk
    }
}

private struct DuoWorkspaceKey: EnvironmentKey {
    static let defaultValue: DuoWorkspaceActions? = nil
}

extension EnvironmentValues {
    @Entry var duoContextPageOwner: DuoContextPageOwner? = nil
    /// A secondary kept mounted, hidden, while its workspace is disabled.
    @Entry var duoContextSuspended = false
    /// The session lies on the laptop's desk, traded below the context: a
    /// plain session with no folded deck, which leaves the keyboard to the
    /// pane on top and takes it back only from a tap on its terminal.
    @Entry var duoSessionOnTheDesk = false

    var duoWorkspace: DuoWorkspaceActions? {
        get { self[DuoWorkspaceKey.self] }
        set { self[DuoWorkspaceKey.self] = newValue }
    }
}

/// Content identity stays in primary/secondary order; only these rectangles
/// exchange places. A hidden child keeps its last visible proposal.
struct DuoWorkspacePlacement: Equatable {
    var primary: CGRect
    var secondary: CGRect
    var primaryVisible: Bool
    var secondaryVisible: Bool

    static func resolve(
        layout: DuoPaneLayout, swapped: Bool,
        lastPrimarySize: CGSize?, lastSecondarySize: CGSize?
    ) -> DuoWorkspacePlacement {
        let primarySlot = swapped ? layout.contextSlot : layout.mainSlot
        let secondarySlot = swapped ? layout.mainSlot : layout.contextSlot
        return DuoWorkspacePlacement(
            primary: primarySlot.map(nonzero) ?? retained(lastPrimarySize, fallback: layout.mainSlot.size),
            secondary: secondarySlot.map(nonzero) ?? retained(lastSecondarySize, fallback: layout.mainSlot.size),
            primaryVisible: primarySlot != nil,
            secondaryVisible: secondarySlot != nil
        )
    }

    private static func nonzero(_ frame: CGRect) -> CGRect {
        CGRect(origin: frame.origin, size: CGSize(width: max(1, frame.width), height: max(1, frame.height)))
    }

    private static func retained(_ size: CGSize?, fallback: CGSize) -> CGRect {
        nonzero(CGRect(origin: .zero, size: size ?? fallback))
    }
}

struct DuoWorkspace<Primary: View, Secondary: View>: View {
    @Environment(\.designTokens) private var T
    @Binding private var state: DuoWorkspaceState
    private let enabledOutsideTheDesk: Bool
    private let primaryTakesInput: Bool
    private let primaryHasDesk: Bool
    private let mainIdealWidth: CGFloat
    private let heldPageOwner: DuoContextPageOwner?
    private let primary: Primary
    private let secondary: Secondary
    @State private var containerFrame: CGRect = .zero
    /// The primary's accessory bar while it spans the keyboard across both
    /// panes, globally.
    @State private var keyboardBar: CGRect?
    @State private var fold: DuoFold?
    /// The primary session's free desk in laptop pose, globally.
    @State private var desk: CGRect?
    @State private var contextPageOwner = DuoContextPageOwner()
    /// Once shown, the secondary stays mounted while a pose turns the
    /// workspace off, so its page and state survive inner-wide ↔ inner-tall.
    @State private var retainsSecondary = false
    /// A software keyboard a field on top took covers the desk. Its window
    /// owns even the strip between the fold and its keys (K-11), so nothing
    /// of the pane lying there, the context or a traded session, shows in
    /// it: that pane waits unseen at its size, as the thread list does (L-10).
    @State private var keyboardCoversDesk = false
    /// Show and hide notifications so far. A show's deferred work yields to
    /// any notification after it, so a show cancelled before that work ran
    /// cannot cover the session once the keyboard has gone.
    @State private var keyboardEvents = DuoKeyboardEventCount()

    /// `pageOwner` comes from above a view that a pose rebuilds; otherwise
    /// the page lives as long as this workspace. A primary that `hasDesk`
    /// (a session) also turns the workspace on in laptop pose, where the
    /// context takes the desk its folded deck leaves free.
    init(
        state: Binding<DuoWorkspaceState>, isEnabled: Bool, primaryTakesInput: Bool, mainIdealWidth: CGFloat,
        primaryHasDesk: Bool = false, pageOwner: DuoContextPageOwner? = nil,
        @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary
    ) {
        self._state = state
        self.enabledOutsideTheDesk = isEnabled
        self.primaryTakesInput = primaryTakesInput
        self.primaryHasDesk = primaryHasDesk
        self.mainIdealWidth = mainIdealWidth
        self.heldPageOwner = pageOwner
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        DuoWorkspaceLayout(
            isEnabled: isEnabled, retainsSecondary: retainsSecondary, state: laidOutState, fold: fold,
            primaryTakesInput: primaryTakesInput, mainIdealWidth: mainIdealWidth,
            primaryHasDesk: primaryHasDesk, desk: localDesk
        ) {
            // Panes jump to their new slots: an animated frame drags a live
            // terminal's content across its old size before it reflows.
            // Only a pane appearing or leaving fades.
            ZStack { primary }
                .animation(Self.fade) { $0.opacity(primaryShown ? 1 : 0) }
                .allowsHitTesting(primaryShown)
                .accessibilityHidden(!primaryShown)
                .environment(\.duoPaneHidden, !primaryVisible)
                .environment(\.duoWorkspace, isEnabled ? actions(isPrimary: true) : nil)
                .environment(\.duoSessionOnTheDesk, sessionOnTheDesk)
                // Its bar runs on over the other pane.
                .zIndex(keyboardBar == nil ? 0 : 1)
            ZStack {
                if isEnabled || retainsSecondary { secondary }
            }
            // On the desk the context waits under the keyboard at its size,
            // its page neither squeezed nor reflowed by every keyboard.
            .ignoresSafeArea(.keyboard, edges: onTheDesk && !sessionOnTheDesk ? .bottom : [])
            // The bar above the keyboard covers this pane's bottom as the
            // keyboard covers what is under it.
            .safeAreaPadding(.bottom, keyboardBarOverlap)
            .animation(Self.fade) { $0.opacity(secondaryShown ? 1 : 0) }
            .allowsHitTesting(secondaryShown)
            .disabled(!secondaryVisible)
            .accessibilityHidden(!secondaryShown)
            .environment(\.duoWorkspace, isEnabled ? actions(isPrimary: false) : nil)
            .environment(\.duoContextPageOwner, heldPageOwner ?? contextPageOwner)
            .environment(\.duoContextSuspended, !isEnabled)
        }
        // Traded, the context is above the keyboard and the session under
        // it: neither moves or resizes while the user types.
        .ignoresSafeArea(.keyboard, edges: sessionOnTheDesk ? .bottom : [])
        .overlay(alignment: .topLeading) {
            if isEnabled, layout.arrangement == .sideBySide, layout.contextSlot != nil, fold == nil {
                Rectangle()
                    .fill(T.border)
                    .frame(width: 0.5, height: keyboardBar.map { max(0, $0.minY - containerFrame.minY) } ?? containerSize.height)
                    .offset(x: layout.mainSlot.maxX - 0.25)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { containerFrame = $0 }
        .onPreferenceChange(KeyboardSpanningBarFrameKey.self) { keyboardBar = $0 }
        .onPreferenceChange(DuoDeskAreaKey.self) { next in
            // A session on the desk publishes none. Keep the one it left, so
            // the context lands back there when they trade back.
            guard next != nil || !sessionOnTheDesk else { return }
            if desk != next?.area { desk = next?.area }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            keyboardEvents.value &+= 1
            guard onTheDesk, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let event = keyboardEvents.value
            // Let the focus change that raised the keyboard settle, and keep
            // the trade out of the keyboard's animation.
            DispatchQueue.main.async {
                guard keyboardEvents.value == event else { return }
                tradeIfTheDeskTookTheKeyboard(frame)
                coverTheDeskIfTheKeyboardDoes(frame)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardEvents.value &+= 1
            if keyboardCoversDesk { keyboardCoversDesk = false }
        }
        .onChange(of: onTheDesk) { _, desk in
            // Folding back to the laptop puts the session on top again. A
            // trade keeps the cover: the keyboard still lies over the desk.
            if !desk, keyboardCoversDesk { keyboardCoversDesk = false }
            if !desk, state.deskTraded { state.deskTraded = false }
        }
        .onDuoFoldChange { next in
            guard fold != next else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { fold = next }
        }
        .onChange(of: isEnabled, initial: true) { _, enabled in
            if enabled, !retainsSecondary { retainsSecondary = true }
        }
        .onChange(of: logSnapshot, initial: true) { _, snapshot in
            guard snapshot.isEnabled, containerSize.width > 0, containerSize.height > 0 else { return }
            NSLog(
                "duo-pane arrangement=%@ main=%@ context=%@ fold=%@",
                String(describing: snapshot.layout.arrangement),
                describe(snapshot.layout.mainSlot),
                snapshot.layout.contextSlot.map(describe) ?? "none",
                snapshot.fold.map { String(describing: $0.frame) } ?? "none"
            )
        }
    }

    private static var fade: Animation { .easeOut(duration: 0.15) }

    private var isEnabled: Bool {
        enabledOutsideTheDesk || (primaryHasDesk && fold?.splitsSideBySide == false)
    }

    /// Laptop pose with a session: the context takes the desk below its bar.
    private var onTheDesk: Bool {
        primaryHasDesk && primaryTakesInput && fold?.splitsSideBySide == false
    }

    private var laidOutState: DuoWorkspaceState { state.laidOut(onTheDesk: onTheDesk) }

    /// The session traded the upper half for the desk.
    private var sessionOnTheDesk: Bool { onTheDesk && laidOutState.swapped }

    /// A field on the desk took the keyboard: whichever pane lies there, the
    /// context's page or form or the session's terminal, trades up. Focus
    /// stays where it is, and the pane trading down never reclaims it, so
    /// one keyboard trades once.
    private func tradeIfTheDeskTookTheKeyboard(_ keyboardFrame: CGRect) {
        guard onTheDesk, let deskPane = layout.contextSlot,
              let window = DuoKeyboardResponder.keyWindow else { return }
        let keyboard = window.windowScene.map { window.convert(keyboardFrame, from: $0.screen.coordinateSpace) }
            ?? keyboardFrame
        let origin = containerFrame.origin
        guard DuoDeskTradePolicy.trades(
            responder: DuoKeyboardResponder.visibleFrame(in: window),
            desk: deskPane.offsetBy(dx: origin.x, dy: origin.y),
            keyboardTop: keyboard.minY
        ) else { return }
        NSLog("duo-desk trade session-on-desk=%d", state.deskTraded ? 0 : 1)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { state.tradeDesk() }
    }

    /// The iPhone rig's shorter keyboard leaves the desk's top in view, so
    /// only a keyboard reaching the desk's top hides the pane there.
    private func coverTheDeskIfTheKeyboardDoes(_ keyboardFrame: CGRect) {
        var covered = false
        if onTheDesk, let deskPane = layout.contextSlot, let window = DuoKeyboardResponder.keyWindow {
            let keyboard = window.windowScene.map { window.convert(keyboardFrame, from: $0.screen.coordinateSpace) }
                ?? keyboardFrame
            covered = keyboard.height > 0 && keyboard.minY <= containerFrame.minY + deskPane.minY + 0.5
        }
        if keyboardCoversDesk != covered { keyboardCoversDesk = covered }
    }

    /// ⇄ brings the session back up: a field in the context, about to lie
    /// under the keyboard, lets the keyboard go first, and the session may
    /// take it as it would after any other field.
    private func releaseUpperFieldBeforeTradingBack() {
        guard let window = DuoKeyboardResponder.keyWindow,
              let responder = DuoKeyboardResponder.visibleFrame(in: window) else { return }
        let upper = layout.mainSlot.offsetBy(dx: containerFrame.minX, dy: containerFrame.minY)
        if upper.contains(CGPoint(x: responder.midX, y: responder.midY)) { window.endEditing(true) }
    }

    private var localDesk: CGRect? {
        desk.map { $0.offsetBy(dx: -containerFrame.minX, dy: -containerFrame.minY) }
    }

    private var containerSize: CGSize { containerFrame.size }

    private var keyboardBarOverlap: CGFloat {
        keyboardBar.map { max(0, containerFrame.maxY - $0.minY) } ?? 0
    }

    private var layout: DuoPaneLayout {
        DuoPaneGeometry.layout(DuoPaneRequest(
            container: containerSize, fold: isEnabled ? fold : nil,
            contextHidden: laidOutState.contextHidden, fullScreen: laidOutState.fullScreen, swapped: laidOutState.swapped,
            mainTakesInput: primaryTakesInput && !laidOutState.swapped, mainIdealWidth: mainIdealWidth,
            mainHasDesk: primaryHasDesk, desk: localDesk
        ))
    }

    private var primaryVisible: Bool { !isEnabled || !laidOutState.swapped || layout.contextSlot != nil }
    /// Visible and not waiting under the keyboard on the desk. The pane keeps
    /// its slot and size either way.
    private var primaryShown: Bool { primaryVisible && !(keyboardCoversDesk && sessionOnTheDesk) }
    private var secondaryVisible: Bool { isEnabled && (laidOutState.swapped || layout.contextSlot != nil) }
    private var secondaryShown: Bool { secondaryVisible && !(keyboardCoversDesk && onTheDesk && !sessionOnTheDesk) }

    private func actions(isPrimary: Bool) -> DuoWorkspaceActions {
        let onTheDesk = onTheDesk
        return DuoWorkspaceActions(
            arrangement: layout.arrangement, isFullScreen: laidOutState.fullScreen, isSwapped: laidOutState.swapped,
            isContextShown: layout.contextSlot != nil,
            toggleContext: { state.toggleContext(arrangement: layout.arrangement) },
            toggleFullScreen: {
                if !state.fullScreen, state.swapped == isPrimary { state.swap() }
                state.toggleFullScreen()
            },
            // The desk trades its halves and leaves the rail's swap alone.
            swap: {
                guard onTheDesk else { state.swap(); return }
                if state.deskTraded { releaseUpperFieldBeforeTradingBack() }
                state.tradeDesk()
            },
            offersFullScreen: DuoWorkspaceActions.offersFullScreen(arrangement: layout.arrangement, onTheDesk: onTheDesk)
        )
    }

    private struct LogSnapshot: Equatable {
        var layout: DuoPaneLayout
        var fold: DuoFold?
        var swapped: Bool
        var isEnabled: Bool
    }

    private var logSnapshot: LogSnapshot {
        LogSnapshot(layout: layout, fold: fold, swapped: laidOutState.swapped, isEnabled: isEnabled)
    }

    private func describe(_ frame: CGRect) -> String {
        String(format: "%.1f×%.1f", Double(frame.width), Double(frame.height))
    }
}

/// Counted outside SwiftUI's dependency tracking: a keyboard notification
/// alone must not rebuild the workspace.
private final class DuoKeyboardEventCount {
    var value = 0
}

private struct DuoWorkspaceLayout: Layout {
    var isEnabled: Bool
    var retainsSecondary = false
    var state: DuoWorkspaceState
    var fold: DuoFold?
    var primaryTakesInput: Bool
    var mainIdealWidth: CGFloat
    var primaryHasDesk = false
    var desk: CGRect?

    struct Cache {
        var primarySize: CGSize?
        var secondarySize: CGSize?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    // Keep the last sizes across child updates, including an empty secondary
    // becoming mounted. SwiftUI's default updateCache would discard them.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let safe = ProposedViewSize(
            width: proposal.width.map { $0 > 0 ? $0 : (cache.primarySize?.width ?? 1) },
            height: proposal.height.map { $0 > 0 ? $0 : (cache.primarySize?.height ?? 1) }
        )
        if !isEnabled { return subviews[0].sizeThatFits(safe) }
        // Do not probe the terminal at full width before placing it in its
        // pane: even a sizing probe can become a remote viewport update.
        return CGSize(
            width: safe.width.flatMap { $0.isFinite ? $0 : nil } ?? cache.primarySize?.width ?? max(1, mainIdealWidth),
            height: safe.height.flatMap { $0.isFinite ? $0 : nil } ?? cache.primarySize?.height ?? 1
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        let layout: DuoPaneLayout
        if isEnabled {
            layout = DuoPaneGeometry.layout(DuoPaneRequest(
                container: bounds.size, fold: fold, contextHidden: state.contextHidden,
                fullScreen: state.fullScreen, swapped: state.swapped,
                mainTakesInput: primaryTakesInput && !state.swapped, mainIdealWidth: mainIdealWidth,
                mainHasDesk: primaryHasDesk, desk: desk
            ))
        } else {
            layout = DuoPaneLayout(
                arrangement: .single, mainSlot: CGRect(origin: .zero, size: bounds.size), contextSlot: nil
            )
        }
        let placement = DuoWorkspacePlacement.resolve(
            layout: layout, swapped: isEnabled && state.swapped,
            lastPrimarySize: cache.primarySize, lastSecondarySize: cache.secondarySize
        )
        if placement.primaryVisible { cache.primarySize = placement.primary.size }
        if placement.secondaryVisible { cache.secondarySize = placement.secondary.size }
        subviews[0].place(
            at: CGPoint(x: bounds.minX + placement.primary.minX, y: bounds.minY + placement.primary.minY),
            anchor: .topLeading, proposal: ProposedViewSize(placement.primary.size)
        )
        // A retained secondary keeps its last visible size, never zero.
        let secondary = isEnabled || retainsSecondary ? placement.secondary : .zero
        subviews[1].place(
            at: CGPoint(x: bounds.minX + secondary.minX, y: bounds.minY + secondary.minY),
            anchor: .topLeading, proposal: ProposedViewSize(secondary.size)
        )
    }
}
