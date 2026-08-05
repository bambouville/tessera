import SwiftUI

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

    @Environment(AppearancePreferences.self) private var appearance
    @State private var softwareKeyboardVisible = true

    var body: some View {
        @Bindable var appearance = appearance

        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                DraggableChipBar(
                    keys: $appearance.accessoryBarKeys,
                    trashEnabled: true,
                    trashColor: Color(red: 1, green: 69/255, blue: 58/255),
                    onTap: { chip in handleTap(chip) },
                    accessibilityValue: { chip in
                        chip.isModifier
                            ? (armedState(for: chip) ? "armed" : "not armed")
                            : nil
                    }
                ) { chip, lifted in
                    chipView(chip, lifted: lifted)
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
        .frame(height: 52)
        // Same floating material as the sidebar / top bar, driven by the
        // `chromeMaterial` setting so all chrome stays consistent.
        .floatingGlass(
            appearance.chromeMaterial,
            tint: .clear,
            solidFill: Color(red: 28/255, green: 28/255, blue: 30/255),
            in: Rectangle()
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
        .onChange(of: appearance.accessoryBarKeys) { _, _ in modifierState.cancel() }
        .onChange(of: appearance.modifierBehavior) { _, _ in
            modifierState.behavior = resolvedModifierBehavior
        }
        .onAppear {
            modifierState.behavior = resolvedModifierBehavior
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            guard isPhone else { return }
            softwareKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
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

    private func chipView(_ chip: AccessoryChip, lifted: Bool) -> some View {
        let isArmed = armedState(for: chip)
        let label = chip.displayLabel
        let highlight = isArmed || lifted
        return Text(label)
            .font(Typography.tesseraMono(size: label.count > 2 ? 12 : 14, weight: .medium))
            .foregroundStyle(highlight ? accent : Color.white)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, isPhone ? 0 : 12)
            .background(highlight ? accent.opacity(0.20) : Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(highlight ? accent : Color.clear, lineWidth: 1)
            )
            .scaleEffect(lifted ? 1.06 : 1)
            .shadow(color: lifted ? Color.black.opacity(0.45) : .clear, radius: 8, x: 0, y: 4)
    }

    private func armedState(for chip: AccessoryChip) -> Bool {
        switch chip {
        case .ctrl:  return modifierState.armed.ctrl
        case .alt:   return modifierState.armed.alt
        case .shift: return modifierState.armed.shift
        default:     return false
        }
    }

    private func handleTap(_ chip: AccessoryChip) {
        if chip.isModifier {
            modifierState.tap(chip)
            return
        }

        modifierState.behavior = resolvedModifierBehavior
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
