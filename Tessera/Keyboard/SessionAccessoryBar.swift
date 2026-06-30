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
    let onSend: ([UInt8]) -> Void
    let applicationCursor: () -> Bool

    @Environment(AppearancePreferences.self) private var appearance

    @State private var armed = ArmedModifiers.none

    var body: some View {
        @Bindable var appearance = appearance

        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                DraggableChipBar(
                    keys: $appearance.accessoryBarKeys,
                    trashEnabled: true,
                    trashColor: Color(red: 1, green: 69/255, blue: 58/255),
                    onTap: { chip in handleTap(chip) }
                ) { chip, lifted in
                    chipView(chip, lifted: lifted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            hideButton
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
        .onChange(of: appearance.accessoryBarKeys) { _, _ in armed = .none }
    }

    /// Quick "hide bar" affordance pinned to the right edge — saves a trip
    /// into Settings → keyboard. To bring the bar back, the user toggles
    /// "show accessory bar" in settings.
    private var hideButton: some View {
        Button {
            appearance.showAccessoryBar = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.65))
                .frame(width: 44, height: 36)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 0.5)
                .padding(.vertical, 12)
        }
    }

    private func chipView(_ chip: AccessoryChip, lifted: Bool) -> some View {
        let isArmed = armedState(for: chip)
        let label = chip.displayLabel
        let highlight = isArmed || lifted
        return Text(label)
            .font(Typography.tesseraMono(size: label.count > 2 ? 12 : 14, weight: .medium))
            .foregroundStyle(highlight ? accent : Color.white)
            .frame(minWidth: 40, minHeight: 36)
            .padding(.horizontal, 12)
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
        case .ctrl:  return armed.ctrl
        case .alt:   return armed.alt
        case .shift: return armed.shift
        default:     return false
        }
    }

    private func handleTap(_ chip: AccessoryChip) {
        if chip.isModifier {
            switch chip {
            case .ctrl:  armed.ctrl.toggle()
            case .alt:   armed.alt.toggle()
            case .shift: armed.shift.toggle()
            default:     break
            }
            return
        }

        let snapshot = armed
        let bytes = AccessoryChipEncoder.encode(
            chip,
            armed: snapshot,
            applicationCursor: applicationCursor()
        )
        onSend(bytes)

        if appearance.modifierBehavior == "oneShot" {
            armed = .none
        }
    }
}
