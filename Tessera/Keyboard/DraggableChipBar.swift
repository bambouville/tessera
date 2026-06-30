import SwiftUI
import UIKit

/// Shared drag-reorder component for both the settings-page preview bar and
/// the live session bar.
///
/// SwiftUI's built-in `.draggable` + `.dropDestination` was tried first but
/// went through iOS's inter-process drag-and-drop pipeline — wrong tool for
/// in-place reorder: it shows a green "+" copy indicator on the drag preview
/// and isTargeted callbacks fire inconsistently. This component drives the
/// drag entirely in-process via a `LongPressGesture` sequenced before a
/// `DragGesture`, tracks each chip's frame via a PreferenceKey, and live-
/// reorders the bound array as the floating chip's center crosses other
/// chips' centers. SwiftUI then animates the displaced chips into their new
/// positions ("pop to make space" effect on iOS home screen).
///
/// Tap fires `onTap`. Long-press → drag → release commits whatever order
/// was last produced. Dropping on the trash target (only rendered when
/// `trashEnabled`) removes the chip from `keys`.
struct DraggableChipBar<Chip: View>: View {
    @Binding var keys: [String]
    let trashEnabled: Bool
    let trashColor: Color
    let onTap: (AccessoryChip) -> Void
    /// Builder for one chip view. `lifted` is true while this chip is the
    /// one being dragged — call site can highlight or scale to distinguish.
    let chipView: (AccessoryChip, _ lifted: Bool) -> Chip

    @State private var draggingRaw: String?
    @State private var dragTranslation: CGSize = .zero
    /// Frame of the dragged chip at the moment the drag started, in the
    /// "bar" coordinate space. The floating preview is rendered at
    /// `startFrame.origin + dragTranslation`.
    @State private var dragStartFrame: CGRect = .zero
    @State private var hoveringTrash = false
    @State private var chipFrames: [String: CGRect] = [:]
    @State private var trashFrame: CGRect = .zero

    private static var coordSpace: String { "draggableChipBar" }

    private var chips: [AccessoryChip] {
        AccessoryChip.from(rawIDs: keys)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.rawValue) { chip in
                    chipView(chip, false)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ChipFramesKey.self,
                                    value: [chip.rawValue: geo.frame(in: .named(Self.coordSpace))]
                                )
                            }
                        )
                        // Hide the source while it's being dragged so the
                        // floating overlay is the only visible copy.
                        .opacity(draggingRaw == chip.rawValue ? 0 : 1)
                        .onTapGesture {
                            // Quick tap stays a tap; long-press wins the
                            // gesture only after `minimumDuration` elapses.
                            onTap(chip)
                        }
                        .gesture(dragGesture(for: chip))
                }

                // Trash sits at the end of the HStack so its layout frame is
                // tracked by GeometryReader correctly. (`.offset` is a
                // render-time transform and would NOT shift the logical
                // frame, breaking hit-testing.)
                if draggingRaw != nil && trashEnabled {
                    trashTarget
                }
            }

            // Floating preview of the dragged chip, anchored to the start
            // frame and translated by the cumulative drag. Stays under the
            // user's finger even as the chip's array slot moves underneath.
            if let raw = draggingRaw, let chip = AccessoryChip(rawValue: raw) {
                chipView(chip, true)
                    .offset(
                        x: dragStartFrame.minX + dragTranslation.width,
                        y: dragStartFrame.minY + dragTranslation.height
                    )
                    .allowsHitTesting(false)
                    .transition(.identity)
            }
        }
        .coordinateSpace(name: Self.coordSpace)
        .onPreferenceChange(ChipFramesKey.self) { chipFrames = $0 }
        .onPreferenceChange(TrashFrameKey.self) { trashFrame = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: keys)
        .animation(.easeInOut(duration: 0.15), value: draggingRaw)
    }

    private var trashTarget: some View {
        Image(systemName: "xmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 36)
            .background(trashColor)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .scaleEffect(hoveringTrash ? 1.18 : 1.0)
            .shadow(color: hoveringTrash ? trashColor.opacity(0.6) : .clear, radius: 8)
            .padding(.leading, 8)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TrashFrameKey.self,
                        value: geo.frame(in: .named(Self.coordSpace))
                    )
                }
            )
            .transition(.scale.combined(with: .opacity))
            .animation(.easeInOut(duration: 0.15), value: hoveringTrash)
    }

    private func dragGesture(for chip: AccessoryChip) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22)
            .sequenced(before: DragGesture(coordinateSpace: .named(Self.coordSpace)))
            .onChanged { value in
                guard case let .second(_, drag?) = value else { return }

                if draggingRaw == nil {
                    draggingRaw = chip.rawValue
                    dragStartFrame = chipFrames[chip.rawValue] ?? .zero
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }

                dragTranslation = drag.translation

                let pointer = drag.location

                if let target = chipUnderPoint(pointer), target != chip.rawValue {
                    liveReorder(chip.rawValue, toBefore: target)
                }

                let nowOverTrash = trashEnabled && trashFrame.contains(pointer)
                if nowOverTrash != hoveringTrash {
                    hoveringTrash = nowOverTrash
                    if nowOverTrash {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
            .onEnded { _ in
                if hoveringTrash, let raw = draggingRaw {
                    keys.removeAll { $0 == raw }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    draggingRaw = nil
                    dragTranslation = .zero
                    hoveringTrash = false
                }
            }
    }

    private func chipUnderPoint(_ point: CGPoint) -> String? {
        chipFrames.first { $0.value.contains(point) }?.key
    }

    private func liveReorder(_ raw: String, toBefore target: String) {
        var newKeys = keys
        guard let from = newKeys.firstIndex(of: raw),
              let to = newKeys.firstIndex(of: target),
              from != to else { return }
        newKeys.remove(at: from)
        newKeys.insert(raw, at: min(to, newKeys.count))
        keys = newKeys
    }
}

private struct ChipFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

private struct TrashFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
