import Observation
import SwiftUI
import UIKit

/// What a browser chord does. ⌘1–⌘9 carry their digit.
enum ArtifactsBrowserCommand: Hashable {
    case newTab, editAddress, reload, back, forward, closeTab, reopenTab, previousTab, nextTab
    case selectTab(Int)
    case overview, find, shareFile

    init?(_ action: ShortcutAction, digit: Int? = nil) {
        switch action {
        case .browserNewTab: self = .newTab
        case .browserEditAddress: self = .editAddress
        case .browserReload: self = .reload
        case .browserBack: self = .back
        case .browserForward: self = .forward
        case .browserCloseTab: self = .closeTab
        case .browserReopenTab: self = .reopenTab
        case .browserPreviousTab: self = .previousTab
        case .browserNextTab: self = .nextTab
        case .browserSelectTab:
            guard let digit, (1...9).contains(digit) else { return nil }
            self = .selectTab(digit)
        case .browserTabOverview: self = .overview
        case .browserFind: self = .find
        case .browserShareFile: self = .shareFile
        default: return nil
        }
    }

    var action: ShortcutAction {
        switch self {
        case .newTab: return .browserNewTab
        case .editAddress: return .browserEditAddress
        case .reload: return .browserReload
        case .back: return .browserBack
        case .forward: return .browserForward
        case .closeTab: return .browserCloseTab
        case .reopenTab: return .browserReopenTab
        case .previousTab: return .browserPreviousTab
        case .nextTab: return .browserNextTab
        case .selectTab: return .browserSelectTab
        case .overview: return .browserTabOverview
        case .find: return .browserFind
        case .shareFile: return .browserShareFile
        }
    }
}

/// The focused browser's handlers. Its hidden buttons and the terminal's
/// relayed key commands both arrive here.
@MainActor
final class ArtifactsShortcutRelay {
    private(set) var available: Set<ArtifactsBrowserCommand> = []
    private var perform: (ArtifactsBrowserCommand) -> Void = { _ in }

    func attach(available: Set<ArtifactsBrowserCommand>, perform: @escaping (ArtifactsBrowserCommand) -> Void) {
        self.available = available
        self.perform = perform
    }

    private var mounts = 0

    /// A scope backing this relay appeared.
    func mounted(available: Set<ArtifactsBrowserCommand>, perform: @escaping (ArtifactsBrowserCommand) -> Void) {
        mounts += 1
        attach(available: available, perform: perform)
    }

    /// A scope backing this relay left. The handler captures the view whose
    /// `@State` holds this relay, so the last one to leave breaks that loop.
    /// A replacement can appear before its predecessor leaves, so this
    /// counts rather than dropping the handler at the first exit.
    func unmounted() {
        mounts = max(mounts - 1, 0)
        guard mounts == 0 else { return }
        available = []
        perform = { _ in }
    }

    @discardableResult
    func fire(_ command: ArtifactsBrowserCommand) -> Bool {
        guard available.contains(command) else { return false }
        perform(command)
        return true
    }
}

/// Which browser surface holds the keyboard in each window. The artifacts
/// page claims it while it is on screen; a Duo context pane claims it when
/// the user touches it and gives it back at a touch anywhere else.
///
/// A focused terminal keeps its chords, so ⌘T opens a tmux window there. A
/// terminal that is first responder beside a claiming pane relays the
/// browser's chords instead (`TesseraTerminalContainer.keyCommands`).
@MainActor @Observable
final class ArtifactsKeyboardFocus {
    static let shared = ArtifactsKeyboardFocus()

    private struct Claim {
        let id: UUID
        weak var anchor: UIView?
        weak var relay: ArtifactsShortcutRelay?
    }

    private var claims: [Claim] = []

    func claim(_ id: UUID, anchor: UIView, relay: ArtifactsShortcutRelay) {
        if claims.last?.id == id, claims.last?.anchor === anchor, claims.last?.relay === relay { return }
        claims.removeAll { $0.id == id || $0.anchor == nil || $0.relay == nil }
        claims.append(Claim(id: id, anchor: anchor, relay: relay))
    }

    func release(_ id: UUID) {
        guard claims.contains(where: { $0.id == id }) else { return }
        claims.removeAll { $0.id == id }
    }

    func holds(_ id: UUID) -> Bool { claims.contains { $0.id == id } }

    /// The browser that takes its chords in `window`: the latest claim.
    func relay(in window: UIWindow?) -> ArtifactsShortcutRelay? {
        guard let window else { return nil }
        return claims.last { $0.anchor?.window === window && $0.relay != nil }?.relay
    }

    #if DEBUG
    func releaseAllForTesting() { claims.removeAll() }
    #endif
}

/// Key commands a terminal relays to a claiming browser beside it.
enum ArtifactsBrowserKeyCommands {
    struct Chord: Hashable {
        let input: String
        let flags: Int

        init(_ command: UIKeyCommand) {
            input = (command.input ?? "").lowercased()
            flags = command.modifierFlags.rawValue
        }
    }

    @MainActor
    static func make(selector: Selector, binding: (ShortcutAction) -> KeyBinding?) -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        for action in ShortcutAction.browserActions {
            guard let binding = binding(action) else { continue }
            let inputs = action.isDigitBlock ? (1...9).map { "\($0)" } : [binding.key.keyCommandInput]
            for input in inputs {
                let command = UIKeyCommand(
                    title: action.title, image: nil, action: selector, input: input,
                    modifierFlags: binding.modifierFlags, propertyList: action.rawValue
                )
                command.wantsPriorityOverSystemBehavior = action.wantsPriorityOverSystemBehavior
                commands.append(command)
            }
        }
        return commands
    }

    /// The command a relayed key command stands for.
    static func command(for sender: UIKeyCommand) -> ArtifactsBrowserCommand? {
        guard let raw = sender.propertyList as? String, let action = ShortcutAction(rawValue: raw) else { return nil }
        return ArtifactsBrowserCommand(action, digit: sender.input.flatMap { Int($0) })
    }
}

/// The browser's chords, from the user's keymap, as hidden buttons. A
/// browser mounts them only while it holds the keyboard, so they never
/// answer for a terminal that does.
@MainActor
struct ArtifactsBrowserShortcutButtons: View {
    @Environment(ShortcutStore.self) private var shortcutStore: ShortcutStore?
    let isActive: Bool
    let relay: ArtifactsShortcutRelay
    let available: Set<ArtifactsBrowserCommand>
    let perform: (ArtifactsBrowserCommand) -> Void

    var body: some View {
        let _ = relay.attach(available: available, perform: perform)
        if isActive {
            ZStack {
                ForEach(ShortcutAction.browserActions.filter { !$0.isDigitBlock }, id: \.self) { action in
                    if let command = ArtifactsBrowserCommand(action) {
                        Button(action.title) { relay.fire(command) }
                            .storedKeyboardShortcut(action, in: shortcutStore)
                            .disabled(!available.contains(command))
                    }
                }
                if let modifiers = StoredShortcut.binding(.browserSelectTab, in: shortcutStore)?.modifiers {
                    ForEach(1...9, id: \.self) { digit in
                        Button(digit == 9 ? String(localized: "last tab") : String(localized: "tab \(digit)")) {
                            relay.fire(.selectTab(digit))
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: EventModifiers(modifiers))
                        .disabled(!available.contains(.selectTab(digit)))
                    }
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A browser surface's chords and its claim on the keyboard, mounted as the
/// background of the whole surface. The anchor fills that background, so a
/// touch anywhere on the surface counts as a touch inside it.
@MainActor
struct ArtifactsBrowserKeyboardScope: View {
    let focusID: UUID
    let relay: ArtifactsShortcutRelay
    /// The page: while it shows. A Duo pane: while it is on screen, then
    /// a touch inside claims.
    let watches: Bool
    var claimsWhileActive = true
    /// Keeps a touch-made claim but ignores touches, as while the surface's
    /// own sheet is up.
    var pausesTouches = false
    let holdsKeyboard: Bool
    let available: Set<ArtifactsBrowserCommand>
    let perform: (ArtifactsBrowserCommand) -> Void

    var body: some View {
        ZStack {
            ArtifactsKeyboardFocusAnchor(id: focusID, relay: relay, isActive: watches, claimsWhileActive: claimsWhileActive,
                                         pausesTouches: pausesTouches)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ArtifactsBrowserShortcutButtons(isActive: holdsKeyboard, relay: relay, available: available, perform: perform)
        }
        .onAppear { relay.mounted(available: available, perform: perform) }
        .onDisappear { relay.unmounted() }
    }
}

/// Holds a browser's claim on the keyboard. `claimsWhileActive` claims for
/// as long as `isActive`, as the artifacts page does; otherwise a touch
/// inside claims and a touch outside gives it back, as a Duo pane does.
struct ArtifactsKeyboardFocusAnchor: UIViewRepresentable {
    let id: UUID
    let relay: ArtifactsShortcutRelay
    let isActive: Bool
    var claimsWhileActive = true
    var pausesTouches = false

    func makeUIView(context: Context) -> ArtifactsKeyboardFocusAnchorView {
        let view = ArtifactsKeyboardFocusAnchorView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ArtifactsKeyboardFocusAnchorView, context: Context) {
        view.configure(id: id, relay: relay, isActive: isActive, claimsWhileActive: claimsWhileActive,
                       pausesTouches: pausesTouches)
    }

    static func dismantleUIView(_ view: ArtifactsKeyboardFocusAnchorView, coordinator: ()) {
        view.tearDown()
    }
}

final class ArtifactsKeyboardFocusAnchorView: UIView, UIGestureRecognizerDelegate {
    private var id: UUID?
    private weak var relay: ArtifactsShortcutRelay?
    private var isActive = false
    private var claimsWhileActive = true
    private var pausesTouches = false
    private var recognizer: UIGestureRecognizer?

    func configure(id: UUID, relay: ArtifactsShortcutRelay, isActive: Bool, claimsWhileActive: Bool,
                   pausesTouches: Bool = false) {
        if let old = self.id, old != id { ArtifactsKeyboardFocus.shared.release(old) }
        self.id = id
        self.relay = relay
        self.isActive = isActive
        self.claimsWhileActive = claimsWhileActive
        self.pausesTouches = pausesTouches
        update()
    }

    func tearDown() {
        removeRecognizer()
        if let id { ArtifactsKeyboardFocus.shared.release(id) }
        isActive = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        update()
    }

    private func update() {
        guard let id else { return }
        if claimsWhileActive {
            removeRecognizer()
            if isActive, window != nil, let relay { ArtifactsKeyboardFocus.shared.claim(id, anchor: self, relay: relay) }
            else { ArtifactsKeyboardFocus.shared.release(id) }
            return
        }
        guard isActive, let window else {
            removeRecognizer()
            ArtifactsKeyboardFocus.shared.release(id)
            return
        }
        if recognizer?.view !== window {
            removeRecognizer()
            let observer = UITapGestureRecognizer()
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            observer.delegate = self
            window.addGestureRecognizer(observer)
            recognizer = observer
        }
    }

    private func removeRecognizer() {
        recognizer?.view?.removeGestureRecognizer(recognizer!)
        recognizer = nil
    }

    /// Watches every touch in the window and takes none of them.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let id, isActive, !pausesTouches, window != nil else { return false }
        let inside = bounds.contains(touch.location(in: self)) && !isHidden && alpha > 0
        if inside, let relay { ArtifactsKeyboardFocus.shared.claim(id, anchor: self, relay: relay) }
        else if !inside { ArtifactsKeyboardFocus.shared.release(id) }
        return false
    }
}
