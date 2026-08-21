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

    @Environment(AppearancePreferences.self) private var appearance
    @Environment(ShortcutStore.self) private var shortcutStore
    @Environment(\.softwareKeyboardLift) private var keyboardLift
    @State private var softwareKeyboardVisible = true

    var body: some View {
        @Bindable var appearance = appearance

        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
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
                ) { item, lifted in
                    chipView(item, lifted: lifted)
                }
                .padding(.horizontal, isPhone ? 8 : 12)
                .padding(.vertical, 4)
            }
            .overlay(alignment: .trailing) {
                AccessoryBarOverflowFade(
                    background: Color(red: 28/255, green: 28/255, blue: 30/255)
                )
            }
            .clipped()

            keyboardToggleButton
        }
        .frame(height: Self.chipRowHeight)
        // Same floating material as the sidebar / top bar, driven by the
        // `chromeMaterial` setting so all chrome stays consistent.
        .floatingGlass(
            appearance.chromeMaterial,
            tint: .clear,
            solidFill: Color(red: 28/255, green: 28/255, blue: 30/255),
            in: barShape
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
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
        .frame(height: Self.reservedBandHeight(), alignment: .top)
        // Where the row sits inside the band. Welded to the keyboard's top edge
        // while it is up, resting above the home indicator once it is gone, on
        // the keyboard's own curve. Offsetting DOWN from the band top is what
        // makes this safe: the row can only ever travel within the band the
        // session already reserved, so unlike the negative offset this replaces
        // it can never hang over the live terminal rows above.
        .offset(y: collapsedPhoneSlide)
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
        }
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
                .foregroundStyle(Color.white.opacity(0.65))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isPhone
                ? (softwareKeyboardVisible ? "Hide keyboard" : "Show keyboard")
                : "Hide accessory bar"
        )
        .padding(.trailing, isPhone ? 4 : 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 0.5)
                .padding(.vertical, 12)
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
                    .background(Color(red: 28/255, green: 28/255, blue: 30/255))
                    .clipShape(Circle())
                    .offset(x: 3, y: 3)
            }
        } else {
            Image(systemName: "keyboard.chevron.compact.down")
        }
    }

    @ViewBuilder
    private func chipView(_ item: AccessoryBarItem, lifted: Bool) -> some View {
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
            .foregroundStyle(highlight ? accent : Color.white)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, isPhone ? 0 : 12)
            .background(highlight ? accent.opacity(0.20) : chipBackground(isCustom: isCustom))
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
                 : Color.white.opacity(0.12)
    }

    private func chipBorder(highlight: Bool, isCustom: Bool) -> Color {
        if highlight { return accent }
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
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
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
        return Self.collapsedProgress(
            lift: keyboardLift,
            homeIndicator: keyWindow?.safeAreaInsets.bottom ?? 0
        )
    }

    private var collapsedPhoneEdgeInset: CGFloat {
        12 * collapsedPhoneProgress
    }

    /// How far down its reserved band the chip row travels: the full home
    /// indicator reserve while the keyboard is up (row flush against the
    /// keyboard, nothing between them), zero once the keyboard is gone (row
    /// parked at the band top, the reserve left clear below it).
    private var collapsedPhoneSlide: CGFloat {
        Self.homeIndicatorReserve() * (1 - collapsedPhoneProgress)
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Rounds off as the bar settles into the phone's curved lower viewport and
    /// squares back up as it re-attaches to the keyboard. Interpolating one
    /// radius keeps the corner on the keyboard's curve; swapping shape types
    /// could only ever cut between two states.
    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12 * collapsedPhoneProgress, style: .continuous)
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
