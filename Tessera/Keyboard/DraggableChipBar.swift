import SwiftUI
import UIKit

/// Shared drag-reorder component for both the settings-page preview bar and
/// the live session bar.
///
/// SwiftUI's built-in `.draggable` + `.dropDestination` was tried first but
/// went through iOS's inter-process drag-and-drop pipeline — wrong tool for
/// in-place reorder: it shows a green "+" copy indicator on the drag preview
/// and isTargeted callbacks fire inconsistently. This component drives the
/// drag entirely in-process via a native long-press recognizer, tracks each
/// chip's frame via a PreferenceKey, and live-reorders the bound array as the
/// floating chip's center crosses other chips' centers. SwiftUI then animates
/// the displaced chips into their new positions ("pop to make space" effect
/// on iOS home screen). The native recognizer deliberately leaves quick pans
/// to an enclosing horizontal ScrollView.
///
/// Tap fires `onTap`. Long-press → drag → release commits whatever order
/// was last produced. Dropping on the trash target (only rendered when
/// `trashEnabled`) removes the chip from `keys`.
struct DraggableChipBar<Chip: View>: View {
    @Binding var keys: [String]
    let trashEnabled: Bool
    let trashColor: Color
    let onTap: (AccessoryBarItem) -> Void
    /// Turns a stored raw ID into a bar item. Custom shortcuts live in
    /// `ShortcutStore`, which this view deliberately does not reach into —
    /// the settings editor and the live bar resolve from different sources.
    var resolve: (String) -> AccessoryBarItem? = { AccessoryChip(rawValue: $0).map(AccessoryBarItem.chip) }
    var accessibilityValue: (AccessoryBarItem) -> String? = { _ in nil }
    /// Builder for one chip view. `lifted` is true while this chip is the
    /// one being dragged — call site can highlight or scale to distinguish.
    /// `pressed` is true while a finger rests on it, from touch-down on.
    let chipView: (AccessoryBarItem, _ lifted: Bool, _ pressed: Bool) -> Chip

    @State private var draggingRaw: String?
    @State private var pressedRaw: String?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragStartLocation: CGPoint = .zero
    @State private var dragStartWindowLocation: CGPoint = .zero
    /// Frame of the dragged chip at the moment the drag started, in the
    /// "bar" coordinate space. The floating preview is rendered at
    /// `startFrame.origin + dragTranslation`.
    @State private var dragStartFrame: CGRect = .zero
    @State private var hoveringTrash = false
    @State private var chipFrames: [String: CGRect] = [:]
    @State private var trashFrame: CGRect = .zero

    private static var coordSpace: String { "draggableChipBar" }

    /// Unknown raw IDs are dropped rather than rendered as placeholders —
    /// same `compactMap` contract the stored array has always had.
    private var chips: [AccessoryBarItem] {
        keys.compactMap(resolve)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    chipView(chip, false, pressedRaw == chip.rawID)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ChipFramesKey.self,
                                    value: [chip.rawID: geo.frame(in: .named(Self.coordSpace))]
                                )
                            }
                        )
                        // Hide the source while it's being dragged so the
                        // floating overlay is the only visible copy.
                        .opacity(draggingRaw == chip.rawID ? 0 : 1)
                        .overlay {
                            ChipInteractionSurface(
                                onTap: { onTap(chip) },
                                onLongPress: { phase in
                                    handleLongPress(phase, for: chip)
                                },
                                onPress: { down in pressChanged(down, for: chip) }
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(chip.accessibilityLabel)
                        .accessibilityValue(accessibilityValue(chip) ?? "")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onTap(chip) }
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
            if let raw = draggingRaw, let chip = resolve(raw) {
                chipView(chip, true, false)
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
            .frame(width: 44, height: 44)
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

    /// The press shows at once and fades after the finger lifts, so even a
    /// quick tap is seen to land.
    private func pressChanged(_ down: Bool, for chip: AccessoryBarItem) {
        if down {
            pressedRaw = chip.rawID
        } else if pressedRaw == chip.rawID {
            withAnimation(.easeOut(duration: 0.2)) { pressedRaw = nil }
        }
    }

    private func handleLongPress(_ phase: ChipInteractionPhase, for chip: AccessoryBarItem) {
        switch phase {
        case .began(let localLocation, let windowLocation):
            guard draggingRaw == nil else { return }
            dragStartLocation = localLocation
            dragStartWindowLocation = windowLocation
            draggingRaw = chip.rawID
            dragStartFrame = chipFrames[chip.rawID] ?? .zero
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        case .changed(let windowLocation):
            guard draggingRaw == chip.rawID else { return }
            dragTranslation = CGSize(
                width: windowLocation.x - dragStartWindowLocation.x,
                height: windowLocation.y - dragStartWindowLocation.y
            )

            let pointer = CGPoint(
                x: dragStartFrame.minX + dragStartLocation.x + dragTranslation.width,
                y: dragStartFrame.minY + dragStartLocation.y + dragTranslation.height
            )

            if let target = chipUnderPoint(pointer), target != chip.rawID {
                liveReorder(chip.rawID, toBefore: target)
            }

            let nowOverTrash = trashEnabled && trashFrame.contains(pointer)
            if nowOverTrash != hoveringTrash {
                hoveringTrash = nowOverTrash
                if nowOverTrash {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

        case .ended(let cancelled):
            guard draggingRaw == chip.rawID else { return }
            if !cancelled, hoveringTrash, let raw = draggingRaw {
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

private enum ChipInteractionPhase {
    case began(local: CGPoint, window: CGPoint)
    case changed(window: CGPoint)
    case ended(cancelled: Bool)
}

/// UIKit gives a long press inside a UIScrollView the desired native gesture
/// arbitration: a quick pan fails the long press and scrolls, while a held
/// touch recognizes first and owns the subsequent reorder drag.
private struct ChipInteractionSurface: UIViewRepresentable {
    let onTap: () -> Void
    let onLongPress: (ChipInteractionPhase) -> Void
    let onPress: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.22
        longPress.allowableMovement = 10
        view.addGestureRecognizer(longPress)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.require(toFail: longPress)
        view.addGestureRecognizer(tap)

        let press = ChipPressRecognizer()
        press.allowableMovement = longPress.allowableMovement
        press.onPressChange = { [weak coordinator = context.coordinator] down in
            coordinator?.surface.onPress(down)
        }
        view.addGestureRecognizer(press)

        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
    }

    final class Coordinator: NSObject {
        var surface: ChipInteractionSurface

        init(surface: ChipInteractionSurface) {
            self.surface = surface
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            surface.onTap()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            let localLocation = recognizer.location(in: recognizer.view)
            let windowLocation = recognizer.location(in: recognizer.view?.window)
            switch recognizer.state {
            case .began:
                surface.onLongPress(.began(local: localLocation, window: windowLocation))
            case .changed:
                surface.onLongPress(.changed(window: windowLocation))
            case .ended:
                surface.onLongPress(.ended(cancelled: false))
            case .cancelled, .failed:
                surface.onLongPress(.ended(cancelled: true))
            default:
                break
            }
        }
    }
}

/// Follows a finger on a chip from touch-down: the tap only fires on lift,
/// once the long press has failed. It never recognizes, so it takes the
/// touch from neither of them nor from the bar's scroll, and whichever of
/// them recognizes resets it. Moving as far as the long press allows ends it.
private final class ChipPressRecognizer: UIGestureRecognizer {
    var allowableMovement: CGFloat = 10
    var onPressChange: ((Bool) -> Void)?

    private var origin = CGPoint.zero
    private var pressed = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible, !pressed, let touch = touches.first else { return }
        origin = touch.location(in: view?.window)
        pressed = true
        onPressChange?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .possible, let touch = touches.first else { return }
        let location = touch.location(in: view?.window)
        if hypot(location.x - origin.x, location.y - origin.y) > allowableMovement { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if state == .possible { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if state == .possible { state = .failed }
    }

    override func reset() {
        super.reset()
        guard pressed else { return }
        pressed = false
        onPressChange?(false)
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
