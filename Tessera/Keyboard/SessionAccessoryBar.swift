import SwiftUI
import UIKit

/// How far the enclosing session has been translated to clear the docked
/// software keyboard, published by `TerminalKeyboardLayoutModifier`.
///
/// The value is derived from SwiftUI's own animated keyboard inset, so anything
/// laid out against it moves on the keyboard's exact timing curve. Chrome that
/// has to change shape across the transition must read this instead of toggling
/// a notification-driven flag: the keyboard's curve (private raw value 7) has no
/// `Animation` equivalent, and replaying it produces a linear ramp that visibly
/// trails the keyboard.
private struct SoftwareKeyboardLiftKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var softwareKeyboardLift: CGFloat {
        get { self[SoftwareKeyboardLiftKey.self] }
        set { self[SoftwareKeyboardLiftKey.self] = newValue }
    }

    /// How far the docked keyboard reaches into the session, whether the
    /// session lifts above it or resizes to it.
    @Entry var softwareKeyboardOverlap: CGFloat = 0
    /// A docked keyboard reaches into the session. Derived from the same
    /// proposal as the lift, so it flips inside the keyboard's own animation.
    @Entry var softwareKeyboardUp = false
}

/// Live accessory bar that hangs at the bottom of an open session. Replaces
/// the old `inputAccessoryView` model so the bar renders regardless of
/// software-vs-hardware-keyboard state — SwiftUI's automatic keyboard
/// avoidance still slides it above the on-screen keyboard when one comes up.
///
/// Source of truth for visible chips is `appearance.accessoryBarKeys`. Tap
/// behavior:
///   - modifier chip (ctrl/alt/shift) → toggle armed state, no bytes sent
///   - non-modifier chip → encode against current armed state via
///     `AccessoryChipEncoder.encode`, deliver bytes through `onSend`
/// In `oneShot` mode armed clears after each non-modifier tap; in `sticky`
/// it persists until the user taps the modifier again.
///
/// Long-press starts a drag-reorder via `DraggableChipBar`. Other chips
/// slide aside as the drag crosses them. A red trash target appears at the
/// right edge during a drag — releasing on it removes the chip from
/// `appearance.accessoryBarKeys`.
struct SessionAccessoryBar: View {
    let accent: Color
    let modifierState: ModifierState
    let onSend: ([UInt8]) -> Void
    let applicationCursor: () -> Bool
    /// Return true to consume a Page Up / Page Down chip before it is encoded.
    /// Used by the terminal's exact agent-working scroll guard; nil keeps every
    /// ordinary bar and state on the existing byte path.
    var onPageScrollAttempt: ((AccessoryChip) -> Bool)? = nil
    /// Whether a user-defined shortcut applies to *this* session right now —
    /// the same `ShortcutScopeEvaluator` decision the chord path makes.
    ///
    /// A scope is a safety rule, not a convenience: a shortcut scoped to host
    /// `staging` and sending `terraform apply -auto-approve␍` must be as inert
    /// on the bar as it is on a keyboard, or the chip that renders in every
    /// session runs it on prod. The bar cannot filter out-of-scope chips at
    /// render time — `AccessoryBarItem.resolve` looks a chip up by raw ID alone
    /// — so the decision has to arrive from the session.
    ///
    /// Defaults to permissive so previews, harnesses and the settings palette
    /// (none of which have a session to scope against) are unchanged.
    var customShortcutApplies: (CustomShortcut) -> Bool = { _ in true }
    /// The visible session's bar, which may reach past its pane to the docked
    /// keyboard's edges. Hidden sessions keep their bars inside their panes.
    var spansKeyboard = false
    /// An agent in this session waits for an answer. The folded pill marks
    /// its chevron when the swipe pad, which shows the replies, is off.
    var attention = false

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(ShortcutStore.self) private var shortcutStore
    @Environment(\.softwareKeyboardLift) private var keyboardLift
    @Environment(\.softwareKeyboardOverlap) private var keyboardOverlap
    @Environment(\.duoFoldedDeck) private var inFoldedDeck
    @Environment(\.duoDeckPlacement) private var deckPlacement
    @Environment(\.duoDeckWidth) private var deckWidth
    @Environment(\.designTokens) private var T
    /// Springs back when the drag ends or is cancelled: a cancelled drag
    /// never delivers onEnded, and must not leave the bar shifted.
    @GestureState(resetTransaction: Transaction(animation: .snappy(duration: 0.3)))
    private var pillDrag: CGFloat = 0
    @State private var puckSlot: CGRect?
    @State private var softwareKeyboardVisible = true
    @State private var overflow = AccessoryBarOverflow()
    @Environment(\.duoWindowFrame) private var windowFrame
    @Environment(\.duoPaneHidden) private var paneHidden
    /// The bar's own slot, globally: its pane's width.
    @State private var slot: ClosedRange<CGFloat>?
    @State private var spannedFrame: CGRect?

    /// The bar floats over the terminal, so it takes the terminal theme's
    /// polarity rather than the app's: light ink on dark themes, dark ink on
    /// light ones, with the glass tinted by the theme's canvas.
    private var palette: AccessoryBarPalette {
        AccessoryBarPalette(theme: TerminalTheme.find(id: appearance.terminalThemeID))
    }

    /// Armed and lifted chips wear the user's accent in the variant made for
    /// the bar's polarity. Sessions pass the dark one, which washes out on a
    /// light theme's pale glass. On light glass even the light variant is too
    /// faint for a small label over its own tint, so there the label keeps
    /// the bar's ink and the accent marks the fill and border.
    private var chipAccent: Color {
        guard palette.isLight else { return accent }
        return DesignTokens.make(
            mode: .light,
            accent: appearance.accent,
            customColor: appearance.accent == .custom
                ? Color(rgbInt: appearance.customAccentRGB)
                : nil
        ).accent
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(slots, id: \.self) { slot in
                switch slot {
                case .chips: chipRow
                case .chevron: chevronButton
                case .puck: puckSeat
                case .keyboard: keyboardToggleButton
                }
            }
        }
        .frame(height: Self.chipRowHeight)
        // Same floating material as the sidebar / top bar, driven by the
        // `chromeMaterial` setting so all chrome stays consistent.
        .floatingGlass(
            appearance.chromeMaterial,
            tint: palette.glassTint,
            solidFill: palette.solidFill,
            in: barShape
        )
        .overlay(alignment: .top) {
            if !isPill {
                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 0.5)
            }
        }
        .overlay {
            if isPill {
                barShape.strokeBorder(palette.hairline, lineWidth: 0.5)
            }
        }
        .environment(\.colorScheme, palette.colorScheme)
        .offset(x: isPill ? pillDrag : 0)
        .highPriorityGesture(pillDragGesture, including: isPill ? .all : .subviews)
        .preference(key: SwipePadDockKey.self, value: seatsPuck ? puckSlot : nil)
        // Over a docked keyboard wider than the pane (Duo's rail layouts),
        // the row reaches the keyboard's edges. Negative padding widens what
        // the row is offered and reports the slot's own width back, so the
        // pane's layout and the terminal grid stay as they are.
        // Measured inside the padding, which reports only the slot's width.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { spannedFrame = $0 }
        .padding(.leading, -keyboardSpan.leading)
        .padding(.trailing, -keyboardSpan.trailing)
        .preference(key: KeyboardSpanningBarFrameKey.self, value: keyboardSpan == EdgeInsets() ? nil : spannedFrame)
        // When the software keyboard is gone, the row sits in the iPhone's
        // curved lower viewport. Inset the complete material surface and give
        // it a continuous corner rather than letting a full-width rectangle be
        // clipped by the physical display corners. With the keyboard present,
        // keep the edge-to-edge attachment to the keyboard.
        .padding(.horizontal, collapsedPhoneEdgeInset)
        // The band the session reserves for the bar. Constant across every
        // keyboard state on purpose — a band that changed with the keyboard
        // would resize the terminal grid on every show and hide, which is the
        // one thing the no-resize layout exists to prevent. The bar is a chip
        // row inside that band, never a slab filling it: a material stretched
        // to the full band reads as a fat empty shelf above the keys.
        // Duo's folded deck rests the row on the hinge, so there it reserves no
        // home-indicator strip.
        .frame(height: inFoldedDeck ? Self.chipRowHeight : Self.reservedBandHeight(), alignment: .top)
        // Where the row sits inside the band. Welded to the keyboard's top edge
        // while it is up, resting above the home indicator once it is gone, on
        // the keyboard's own curve. Offsetting DOWN from the band top is what
        // makes this safe: the row can only ever travel within the band the
        // session already reserved, so unlike the negative offset this replaces
        // it can never hang over the live terminal rows above.
        .offset(y: collapsedPhoneSlide)
        .onGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
            let frame = geometry.frame(in: .global)
            return frame.minX...frame.maxX
        } action: { slot = $0 }
        .background { WindowBottomSafeAreaProbe() }
        .onChange(of: appearance.accessoryBarKeys) { _, _ in modifierState.cancel() }
        .onChange(of: appearance.modifierBehavior) { _, _ in
            modifierState.behavior = resolvedModifierBehavior
        }
        .onAppear {
            modifierState.behavior = resolvedModifierBehavior
        }
        // Only the toggle's behavior, label and glyph key off this flag; every
        // animated dimension comes from `keyboardLift` so the bar cannot drift
        // away from the keyboard it is attached to.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            guard isPhone else { return }
            softwareKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            guard isPhone else { return }
            softwareKeyboardVisible = false
            // A bar opened while typing lasts until the keyboard goes: the
            // next one leaves the top half to the terminal and the pill.
            if appearance.duoBarOpenWhileTyping { appearance.duoBarOpenWhileTyping = false }
        }
    }

    private enum BarSlot: Hashable {
        case chips, chevron, puck, keyboard
    }

    /// Duo's laptop pose puts the buttons on the pill's edge, the chevron
    /// between them and the keys. Stable identities let them slide across
    /// when the pill changes edge.
    private var slots: [BarSlot] {
        var slots: [BarSlot] = [.chips]
        if showsChevron { slots.append(.chevron) }
        if seatsPuck { slots.append(.puck) }
        slots.append(.keyboard)
        return buttonEdge == .leading ? slots.reversed() : slots
    }

    /// In laptop pose the swipe pad's puck stops floating and takes a seat
    /// in the bar. The session's overlay still draws and drives it there.
    private var seatsPuck: Bool { deckPlacement != nil && appearance.swipePadEnabled }

    private var puckSeat: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { puckSlot = $0 }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private var isPill: Bool { deckPlacement?.isPill == true }

    /// The chevron folds and opens the bar while typing; below the hinge the
    /// bar is open and has nothing to fold.
    private var showsChevron: Bool {
        guard let deckPlacement else { return false }
        return deckPlacement.bar != .desk
    }

    private var buttonEdge: HorizontalEdge { deckPlacement?.edge ?? .trailing }

    private var outerEdge: Edge.Set { buttonEdge == .leading ? .leading : .trailing }

    private var innerEdge: Edge.Set { buttonEdge == .leading ? .trailing : .leading }

    private var innerAlignment: Alignment { buttonEdge == .leading ? .trailing : .leading }

    private var chipRow: some View {
        @Bindable var appearance = appearance
        return ScrollView(.horizontal, showsIndicators: false) {
            DraggableChipBar(
                keys: $appearance.accessoryBarKeys,
                trashEnabled: true,
                trashColor: Color(red: 1, green: 69/255, blue: 58/255),
                onTap: { item in handleTap(item) },
                resolve: { raw in
                    AccessoryBarItem.resolve(raw) { shortcutStore.customShortcut(withChipRawID: $0) }
                },
                accessibilityValue: { item in
                    if item.isModifier {
                        return armedState(for: item)
                            ? String(localized: "armed")
                            : String(localized: "not armed")
                    }
                    return Self.canFire(item, applies: customShortcutApplies)
                        ? nil
                        : String(localized: "out of scope")
                }
            ) { item, lifted, pressed in
                chipView(item, lifted: lifted, pressed: pressed)
            }
            .padding(.horizontal, isPhone ? 8 : 12)
            .padding(.vertical, 4)
        }
        .onScrollGeometryChange(for: AccessoryBarOverflow.self) { geometry in
            AccessoryBarOverflow(geometry)
        } action: { _, overflow in
            self.overflow = overflow
        }
        // Clipped keys fade into the bar's own surface. A painted
        // gradient can only match one surface colour and read as a dark
        // band on every other one.
        .mask {
            AccessoryBarOverflowMask(overflow: overflow)
                .animation(.easeOut(duration: 0.15), value: overflow)
        }
        // The pill keeps its buttons: the keys fold away into its edge.
        .frame(width: isPill ? 0 : nil)
        .opacity(isPill ? 0 : 1)
        .allowsHitTesting(!isPill)
        .accessibilityHidden(isPill)
    }

    /// Folds the bar to the pill while typing, or opens it on the hinge. The
    /// glyph points where the bar goes: inward to open, at its edge to fold.
    private var chevronButton: some View {
        let pointsBackward = (buttonEdge == .trailing) == isPill
        return Button {
            withAnimation(.snappy(duration: 0.3)) {
                appearance.duoBarOpenWhileTyping.toggle()
            }
        } label: {
            Image(systemName: pointsBackward ? "chevron.backward" : "chevron.forward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.mutedInk)
                .frame(width: 44, height: 44)
                .background(palette.toggleFill)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if isPill && attention && !appearance.swipePadEnabled {
                        Circle()
                            .fill(T.amber)
                            .frame(width: 7, height: 7)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPill ? "Open accessory bar" : "Fold accessory bar")
        .accessibilityValue(isPill && attention ? String(localized: "agent waiting") : "")
        .accessibilityIdentifier("duo-accessory-bar-chevron")
        .padding(outerEdge, 4)
        .padding(innerEdge, isPill ? 4 : 0)
        .padding(.vertical, 4)
        .overlay(alignment: innerAlignment) {
            if !isPill { divider }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.divider)
            .frame(width: 0.5)
            .padding(.vertical, 12)
    }

    /// Dragging the pill past the middle of the deck moves it to that edge.
    /// A tap still reaches its buttons: the drag needs some travel first.
    private var pillDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(DuoFoldedInputSpace.name))
            .updating($pillDrag) { value, drag, _ in
                if isPill { drag = value.translation.width }
            }
            .onEnded { value in
                guard isPill else { return }
                let edge = Self.pillEdge(
                    releasedAt: value.predictedEndLocation.x, deckWidth: deckWidth, current: buttonEdge
                )
                withAnimation(.snappy(duration: 0.3)) {
                    appearance.duoBarEdge = edge == .leading ? "leading" : "trailing"
                }
            }
    }

    static func pillEdge(releasedAt x: CGFloat, deckWidth: CGFloat, current: HorizontalEdge) -> HorizontalEdge {
        guard deckWidth > 0 else { return current }
        return x < deckWidth / 2 ? .leading : .trailing
    }

    /// On iPhone this dismisses the software keyboard while leaving the
    /// accessory bar available above the home indicator. iPad keeps the
    /// existing quick-hide behavior for the always-visible keyboard workflow.
    private var keyboardToggleButton: some View {
        Button {
            if isPhone {
                if softwareKeyboardVisible {
                    if !modifierState.dismissSoftwareKeyboard() {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                } else if !modifierState.showSoftwareKeyboard() {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.becomeFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            } else {
                appearance.showAccessoryBar = false
            }
        } label: {
            keyboardToggleIcon
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.mutedInk)
                .frame(width: 44, height: 44)
                .background(palette.toggleFill)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isPhone
                ? (softwareKeyboardVisible ? "Hide keyboard" : "Show keyboard")
                : "Hide accessory bar"
        )
        .padding(outerEdge, isPhone ? 4 : 12)
        .padding(innerEdge, isPill && !showsChevron ? 4 : 0)
        .padding(.vertical, 4)
        .overlay(alignment: innerAlignment) {
            // Between the keys and the bar's buttons; the chevron draws it when shown.
            if !isPill && !showsChevron { divider }
        }
    }

    @ViewBuilder
    private var keyboardToggleIcon: some View {
        if isPhone && !softwareKeyboardVisible {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "keyboard")
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .padding(2)
                    .background(palette.solidFill)
                    .clipShape(Circle())
                    .offset(x: 3, y: 3)
            }
        } else {
            Image(systemName: "keyboard.chevron.compact.down")
        }
    }

    @ViewBuilder
    private func chipView(_ item: AccessoryBarItem, lifted: Bool, pressed: Bool) -> some View {
        let isArmed = armedState(for: item)
        let highlight = isArmed || lifted
        let isCustom = item.customShortcut != nil
        // Out of scope is dimmed rather than removed. Hiding it would be the
        // better affordance if the bar's contents were stable, but scope can be
        // a *foreground process* — chips would appear and disappear under the
        // user's thumb as the remote's foreground command changes. A dim chip in
        // a fixed position says "not here" without moving its neighbours.
        let outOfScope = !Self.canFire(item, applies: customShortcutApplies)
        chipLabelView(item)
            .foregroundStyle(highlight && !palette.isLight ? chipAccent : palette.ink)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, isPhone ? 0 : 12)
            // A finger on the key deepens its fill, as a keyboard's key does,
            // until it lifts: the tap itself only fires on release.
            .background { if pressed { palette.pressedFill } }
            .background(highlight ? chipAccent.opacity(0.20) : chipBackground(isCustom: isCustom))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(chipBorder(highlight: highlight, isCustom: isCustom), lineWidth: 1)
            )
            .scaleEffect(lifted ? 1.06 : 1)
            .shadow(color: lifted ? Color.black.opacity(0.45) : .clear, radius: 8, x: 0, y: 4)
            .opacity(outOfScope ? 0.35 : 1)
    }

    @ViewBuilder
    private func chipLabelView(_ item: AccessoryBarItem) -> some View {
        switch item.label(appearance.modifierNotation) {
        case .text(let label):
            Text(label)
                .font(Typography.tesseraMono(size: label.count > 2 ? 12 : 14, weight: .medium))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 17, weight: .medium))
        }
    }

    /// A tap that *runs a command* has to look different from a tap that sends
    /// a key — an icon chip no longer says what it does, so the outline is the
    /// only cue left.
    private func chipBackground(isCustom: Bool) -> Color {
        isCustom ? Color(red: 48/255, green: 209/255, blue: 88/255).opacity(0.16)
                 : palette.chipFill
    }

    private func chipBorder(highlight: Bool, isCustom: Bool) -> Color {
        if highlight { return chipAccent }
        return isCustom
            ? Color(red: 48/255, green: 209/255, blue: 88/255).opacity(0.5)
            : Color.clear
    }

    private func armedState(for item: AccessoryBarItem) -> Bool {
        guard case .chip(let chip) = item else { return false }
        switch chip {
        case .ctrl:  return modifierState.armed.ctrl
        case .alt:   return modifierState.armed.alt
        case .shift: return modifierState.armed.shift
        case .cmd:   return modifierState.armed.cmd
        default:     return false
        }
    }

    /// Whether a bar item may fire. Only a custom shortcut can be out of scope;
    /// built-in chips send a key and are unconditional.
    ///
    /// Pure and static so the rule is testable without driving a view — the same
    /// reason `ShortcutScopeEvaluator` is separate from the session.
    static func canFire(
        _ item: AccessoryBarItem,
        applies: (CustomShortcut) -> Bool
    ) -> Bool {
        guard case .custom(let shortcut) = item else { return true }
        return applies(shortcut)
    }

    private func handleTap(_ item: AccessoryBarItem) {
        // Out of scope is out of scope on every trigger. Checked before the
        // switch so a future item kind cannot slip past it.
        guard Self.canFire(item, applies: customShortcutApplies) else { return }
        switch item {
        case .chip(let chip):
            handleChipTap(chip)
        case .custom(let shortcut):
            // Custom chips ignore armed modifiers: their bytes are a literal
            // sequence the user authored, not a key to be modified.
            onSend(shortcut.encoded(applicationCursor: applicationCursor()))
        }
    }

    private func handleChipTap(_ chip: AccessoryChip) {
        if chip.isModifier {
            modifierState.tap(chip)
            return
        }

        modifierState.behavior = resolvedModifierBehavior

        // ⌘ arms Tessera, not the wire. With it held, the next chip runs an app
        // shortcut and sends nothing — an unbound chord is swallowed rather
        // than typed, matching what ⌘ plus an unbound key does on a Mac and
        // keeping a stray character out of a live shell.
        if modifierState.armed.cmd {
            let armed = modifierState.consume()
            if let key = BindingKey.from(chip: chip) {
                AppShortcutDispatcher.dispatch(
                    AppShortcutDispatcher.chord(armed: armed, key: key),
                    store: shortcutStore
                )
            }
            return
        }

        let snapshot = modifierState.consume()
        if (chip == .pgup || chip == .pgdn),
           onPageScrollAttempt?(chip) == true {
            return
        }
        let bytes = AccessoryChipEncoder.encode(
            chip,
            armed: snapshot,
            applicationCursor: applicationCursor()
        )
        onSend(bytes)
    }

    private var resolvedModifierBehavior: ModifierBehavior {
        ModifierBehavior(rawValue: appearance.modifierBehavior) ?? .oneShot
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// The row of chips itself.
    static let chipRowHeight: CGFloat = 52

    /// Vertical band a session reserves at its bottom edge for the bar. Callers
    /// that stack their own chrome above the bar (the swipe pad, pane toasts,
    /// the mosh backdrop bleed) measure from this, not from the chip row, or
    /// they end up floating over the home-indicator strip on a phone.
    static func reservedBandHeight() -> CGFloat {
        chipRowHeight + homeIndicatorReserve()
    }

    /// Strip the phone's home indicator claims at the bottom of the window.
    /// Reported by the window and unaffected by the keyboard (UIKit keeps the
    /// keyboard out of the safe area), so the reserved band stays put while the
    /// keyboard comes and goes.
    static func homeIndicatorReserve() -> CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return 0 }
        return WindowBottomSafeArea.shared.inset
    }

    /// 1 while the bar rests in the phone's curved lower viewport, falling to 0
    /// as the session lifts clear of the home-indicator band. Deriving both
    /// collapsed insets from the lift keeps them on the keyboard's own curve.
    static func collapsedProgress(lift: CGFloat, homeIndicator: CGFloat) -> CGFloat {
        guard homeIndicator > 0 else { return lift > 0 ? 0 : 1 }
        return max(0, min(1, (homeIndicator - lift) / homeIndicator))
    }

    private var collapsedPhoneProgress: CGFloat {
        guard isPhone else { return 0 }
        // On the hinge the row stays a flat, full-width strip in both keyboard states.
        if inFoldedDeck { return 0 }
        return Self.collapsedProgress(
            lift: keyboardLift,
            homeIndicator: Self.homeIndicatorReserve()
        )
    }

    private var collapsedPhoneEdgeInset: CGFloat {
        12 * collapsedPhoneProgress
    }

    /// How far the row reaches past each side of its slot to the window's
    /// edges, which the docked keyboard spans. Keyed to the keyboard's overlap,
    /// so the row widens and narrows on the keyboard's own curve.
    private var keyboardSpan: EdgeInsets {
        guard spansKeyboard, isPhone, keyboardOverlap > 0, !paneHidden,
              let windowFrame, let slot else { return EdgeInsets() }
        return EdgeInsets(
            top: 0, leading: max(0, slot.lowerBound - windowFrame.minX),
            bottom: 0, trailing: max(0, windowFrame.maxX - slot.upperBound)
        )
    }

    /// How far down its reserved band the chip row travels: the full home
    /// indicator reserve while the keyboard is up (row flush against the
    /// keyboard, nothing between them), zero once the keyboard is gone (row
    /// parked at the band top, the reserve left clear below it).
    private var collapsedPhoneSlide: CGFloat {
        guard !inFoldedDeck else { return 0 }
        return Self.homeIndicatorReserve() * (1 - collapsedPhoneProgress)
    }

    /// Rounds off as the bar settles into the phone's curved lower viewport and
    /// squares back up as it re-attaches to the keyboard. Interpolating one
    /// radius keeps the corner on the keyboard's curve; swapping shape types
    /// could only ever cut between two states.
    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isPill ? 16 : 12 * collapsedPhoneProgress, style: .continuous)
    }
}

/// The bottom safe-area inset of the accessory bar's window, mirrored for
/// SwiftUI bodies.
///
/// A body must not read `UIWindow.safeAreaInsets` itself. On iOS 27 the getter
/// can make UIKit ask the root hosting controller for its status-bar and
/// home-indicator preferences, which SwiftUI combines over the whole view tree,
/// including the body that is asking. Read from the bar's body at launch, that
/// formed an AttributeGraph cycle, after which SwiftUI never updated the bar
/// again: its keyboard toggle and keyboard-following insets froze.
/// `WindowBottomSafeAreaProbe` refreshes the mirror from UIKit callbacks
/// instead, a run-loop turn later so that no SwiftUI update is in progress.
@MainActor @Observable
final class WindowBottomSafeArea {
    static let shared = WindowBottomSafeArea()

    private(set) var inset: CGFloat = 0

    func refresh(from window: UIWindow?) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            let inset = window.safeAreaInsets.bottom
            if self.inset != inset { self.inset = inset }
        }
    }
}

/// Feeds `WindowBottomSafeArea` from the window hosting it: once on arrival,
/// then whenever rotation or a new safe area lays it out again. The app root
/// carries one so the mirror is seeded before a session first lays out; the
/// bar carries its own for hosts without that root, such as previews.
struct WindowBottomSafeAreaProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            WindowBottomSafeArea.shared.refresh(from: window)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            WindowBottomSafeArea.shared.refresh(from: window)
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            WindowBottomSafeArea.shared.refresh(from: window)
        }
    }
}

/// Colours of the session accessory bar, keyed to the terminal theme it
/// floats over. The dark values are the bar's original palette.
struct AccessoryBarPalette: Equatable {
    let isLight: Bool
    let glassTint: Color

    init(theme: TerminalTheme) {
        isLight = theme.isLight
        // The theme's own glass wash (`chromeTokens().sidebarBg`), so the bar
        // carries the canvas's hue like the session's top bar.
        glassTint = theme.bg.opacity(theme.isLight ? 0.55 : 0.35)
    }

    var colorScheme: ColorScheme { isLight ? .light : .dark }
    var ink: Color { isLight ? Color(white: 0.11) : .white }
    var mutedInk: Color { isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.65) }
    var chipFill: Color { isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.12) }
    /// Laid over a pressed key's fill, armed or not.
    var pressedFill: Color { isLight ? Color.black.opacity(0.14) : Color.white.opacity(0.22) }
    var toggleFill: Color { isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08) }
    var hairline: Color { isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.08) }
    var divider: Color { isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.06) }
    var solidFill: Color {
        isLight ? Color(red: 242/255, green: 242/255, blue: 247/255)
                : Color(red: 28/255, green: 28/255, blue: 30/255)
    }
}

/// Which edges of the chip row have keys scrolled out of view.
struct AccessoryBarOverflow: Equatable {
    var leading = false
    var trailing = false

    init() {}

    init(_ geometry: ScrollGeometry) {
        leading = geometry.visibleRect.minX > 1
        trailing = geometry.visibleRect.maxX < geometry.contentSize.width - 1
    }
}

/// Fades the chip row out at an edge that hides more keys.
struct AccessoryBarOverflowMask: View {
    let overflow: AccessoryBarOverflow

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: overflow.leading ? 22 : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: overflow.trailing ? 22 : 0)
        }
    }
}

/// Subtle trailing cue that makes horizontally clipped accessory keys discoverable.
struct AccessoryBarOverflowFade: View {
    let background: Color

    var body: some View {
        LinearGradient(
            colors: [background.opacity(0), background.opacity(0.9)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 22)
        .allowsHitTesting(false)
    }
}
