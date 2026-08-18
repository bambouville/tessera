// Tessera/Settings/ChordRecorder.swift
// Capturing a chord from a live key press, and explaining what happened when
// the press never arrives.
//
// The recorder cannot be built on `UIKeyCommand`: those only fire for chords
// registered in advance, and the whole point here is to observe arbitrary
// presses. It therefore runs on its own first-responder view and reads
// `pressesBegan` directly — gate 4 in docs/keyboard-interception-research.md.
//
// A consequence worth stating: record-time and fire-time use different UIKit
// mechanisms (pressesBegan vs UIKeyCommand). That gap is exactly where the ⌥
// character-remapping trap lives, which is why the capture reports both
// `characters` and `charactersIgnoringModifiers` and validation compares them.
import SwiftUI
import UIKit
import GameController

// MARK: - Hardware keyboard presence

/// Thin wrapper so views can ask without importing GameController.
enum GCKeyboardShim {
    static var isConnected: Bool { GCKeyboard.coalesced != nil }
}

// MARK: - Capture view

/// What a single recording attempt produced.
enum ChordCapture: Equatable {
    /// A key arrived with its modifiers.
    case captured(KeyBinding, produced: String)
    /// Modifiers were held and released without any key arriving. Cannot be
    /// distinguished from "the user tapped ⌘ and let go", so this is a
    /// diagnostic hint rather than a verdict — but it is the only signal the
    /// app gets when iPadOS or the focus engine swallows a chord, and saying
    /// nothing leaves the recorder looking hung.
    case nothingArrived(heldModifiers: Set<KeyToken>)
}

final class ChordCaptureUIView: UIView {
    var onCapture: ((ChordCapture) -> Void)?
    /// Live modifier state, so the well can show ⌘ filling in as it's held.
    var onModifiersChanged: ((Set<KeyToken>) -> Void)?

    private var heldModifiers: Set<KeyToken> = []
    private var modifiersDownAt: Date?
    private var capturedThisPress = false

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }

            if let modifier = Self.modifierToken(for: key.keyCode) {
                heldModifiers.insert(modifier)
                if modifiersDownAt == nil { modifiersDownAt = Date() }
                onModifiersChanged?(heldModifiers)
                continue
            }

            guard let binding = KeyBinding.from(key: key) else { continue }
            capturedThisPress = true
            onCapture?(.captured(binding, produced: key.characters))
        }
        // Never call super: while recording, the keyboard belongs to us and
        // nothing should reach the app's own shortcuts.
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key,
                  let modifier = Self.modifierToken(for: key.keyCode) else { continue }
            heldModifiers.remove(modifier)
            onModifiersChanged?(heldModifiers)
        }

        if heldModifiers.isEmpty {
            let held = modifiersDownAt
            modifiersDownAt = nil
            // A deliberate chord attempt holds the modifier for a moment. A
            // stray brush of ⌘ doesn't, and shouldn't produce an explanation.
            if !capturedThisPress,
               let held, Date().timeIntervalSince(held) > 0.25 {
                onCapture?(.nothingArrived(heldModifiers: []))
            }
            capturedThisPress = false
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldModifiers.removeAll()
        modifiersDownAt = nil
        capturedThisPress = false
        onModifiersChanged?(heldModifiers)
    }

    private static func modifierToken(for keyCode: UIKeyboardHIDUsage) -> KeyToken? {
        switch keyCode {
        case .keyboardLeftGUI, .keyboardRightGUI:         return .command
        case .keyboardLeftShift, .keyboardRightShift:     return .shift
        case .keyboardLeftControl, .keyboardRightControl: return .control
        case .keyboardLeftAlt, .keyboardRightAlt:         return .option
        default: return nil
        }
    }
}

struct ChordCaptureRepresentable: UIViewRepresentable {
    var onCapture: (ChordCapture) -> Void
    var onModifiersChanged: (Set<KeyToken>) -> Void

    func makeUIView(context: Context) -> ChordCaptureUIView {
        let view = ChordCaptureUIView()
        view.onCapture = onCapture
        view.onModifiersChanged = onModifiersChanged
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: ChordCaptureUIView, context: Context) {
        uiView.onCapture = onCapture
        uiView.onModifiersChanged = onModifiersChanged
        if !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        }
    }
}

// MARK: - Recorder sheet

struct ChordRecorderSheet: View {
    let target: ShortcutsEditorView.RecordTarget
    let onSave: (KeyBinding?) -> Void

    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss
    @Environment(ShortcutStore.self) private var store
    @Environment(AppearancePreferences.self) private var appearance

    @State private var state: RecorderState = .listening
    @State private var liveModifiers: Set<KeyToken> = []

    private enum RecorderState: Equatable {
        case listening
        case ok(KeyBinding)
        case conflict(KeyBinding, ShortcutAction)
        case rejected(KeyBinding?, BindingRejection)
        case nothingArrived
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("record shortcut")
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                Text(verbatim: targetName)
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.fgDim)
            }

            well
                .frame(maxWidth: .infinity)
                .frame(minHeight: 150)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("cancel") { dismiss() }
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgDim)
                    .buttonStyle(.plain)

                if case .ok(let binding) = state {
                    primaryButton("save", tint: T.accent) {
                        onSave(binding)
                        dismiss()
                    }
                } else if case .conflict(let binding, _) = state {
                    primaryButton("record again", tint: T.fgMuted) { reset() }
                    primaryButton("take it", tint: T.red) {
                        onSave(binding)
                        dismiss()
                    }
                } else if state != .listening {
                    primaryButton("record again", tint: T.fgMuted) { reset() }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 340)
        .background(T.presentationBg)
        .background(
            ChordCaptureRepresentable(
                onCapture: handle,
                onModifiersChanged: { liveModifiers = $0 }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
        )
        .presentationDetents([.height(300)])
    }

    private var targetName: String {
        switch target {
        case .action(let action): return action.title
        case .custom(let id):
            return store.customShortcuts.first(where: { $0.id == id })?.name ?? "custom shortcut"
        }
    }

    @ViewBuilder
    private var well: some View {
        VStack(spacing: 10) {
            switch state {
            case .listening:
                HStack(spacing: 6) {
                    if liveModifiers.isEmpty {
                        bigCap("⌘", ghost: true)
                        bigCap("?", ghost: true)
                    } else {
                        ForEach(Chord(liveModifiers).tokens, id: \.self) { token in
                            bigCap(token.rendered(appearance.modifierNotation))
                        }
                        bigCap("?", ghost: true)
                    }
                }
                message("press the keys you want.\nthey won't reach the terminal while recording.")

            case .ok(let binding):
                bigChord(binding, tint: T.green)
                message("**free.** nothing else in Tessera uses it, and iPadOS lets it through.")

            case .conflict(let binding, let owner):
                bigChord(binding, tint: T.amber)
                message("**already used by \"\(owner.title)\".**\nsaving takes it — \(owner.title) becomes unbound until you give it another.")

            case .rejected(let binding, let reason):
                if let binding { bigChord(binding, tint: T.red) }
                message("**\(reason.headline).**\n\(reason.detail)")

            case .nothingArrived:
                bigCap("⌘", ghost: true)
                message("**nothing arrived.**\nif you pressed a key with that modifier, iPadOS or the focus engine is keeping it — try a letter or punctuation key with ⌘.")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(wellFill)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    wellStroke,
                    style: StrokeStyle(lineWidth: 1, dash: state == .listening ? [4, 3] : [])
                )
        )
    }

    private var wellFill: Color {
        switch state {
        case .listening:      return T.accentSoft
        case .ok:             return T.green.opacity(0.08)
        case .conflict:       return T.amber.opacity(0.08)
        case .rejected, .nothingArrived: return T.red.opacity(0.07)
        }
    }

    private var wellStroke: Color {
        switch state {
        case .listening:      return T.accent
        case .ok:             return T.green.opacity(0.5)
        case .conflict:       return T.amber.opacity(0.5)
        case .rejected, .nothingArrived: return T.red.opacity(0.5)
        }
    }

    private func bigChord(_ binding: KeyBinding, tint: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(binding.chord.tokens, id: \.self) { token in
                bigCap(token.rendered(appearance.modifierNotation), tint: tint)
            }
        }
    }

    private func bigCap(_ text: String, ghost: Bool = false, tint: Color? = nil) -> some View {
        Text(verbatim: text)
            .font(Typography.tesseraMono(size: 15, weight: .medium))
            .foregroundStyle(ghost ? T.fgFaint : (tint ?? T.fg))
            .frame(minWidth: 38, minHeight: 38)
            .padding(.horizontal, 6)
            .background(ghost ? Color.clear : T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        ghost ? T.borderStrong : (tint ?? T.borderStrong),
                        style: StrokeStyle(lineWidth: 1, dash: ghost ? [3, 2] : [])
                    )
            )
    }

    /// `LocalizedStringKey` keeps the `**bold**` rendering the old
    /// `.init(markdown)` gave, and puts every literal in the catalog.
    private func message(_ markdown: LocalizedStringKey) -> some View {
        Text(markdown)
            .font(Typography.tesseraMono(size: 11))
            .foregroundStyle(T.fgMuted)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: 300)
    }

    private func primaryButton(_ title: LocalizedStringKey, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(tint)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func reset() {
        state = .listening
        liveModifiers = []
    }

    private func handle(_ capture: ChordCapture) {
        switch capture {
        case .nothingArrived:
            // Only meaningful while still waiting — not after a verdict.
            if state == .listening { state = .nothingArrived }

        case .captured(let binding, let produced):
            // The action being rebound must not conflict with itself.
            var existing = store.allBindings
            if case .action(let action) = target { existing.removeValue(forKey: action) }

            switch binding.validate(producedCharacters: produced, existing: existing) {
            case .ok:
                // A custom shortcut can also collide with another custom one;
                // the built-in table above doesn't cover that.
                if let clash = store.customShortcut(matching: binding),
                   case .custom(let editingID) = target, clash.id != editingID {
                    state = .rejected(binding, .reservedBySystem(String(
                        localized: "\"\(clash.name)\" already uses this chord.",
                        comment: "Chord conflict; the argument is another custom shortcut's name"
                    )))
                } else if let clash = store.customShortcut(matching: binding),
                          case .action = target {
                    state = .rejected(binding, .reservedBySystem(String(
                        localized: "\"\(clash.name)\" already uses this chord.",
                        comment: "Chord conflict; the argument is another custom shortcut's name"
                    )))
                } else {
                    state = .ok(binding)
                }
            case .conflict(let owner):
                state = .conflict(binding, owner)
            case .rejected(let reason):
                state = .rejected(binding, reason)
            }
        }
    }
}
