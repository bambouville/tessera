// Tessera/Keyboard/ShortcutCheatSheetController.swift
// Keep the shortcut card above sheets without taking the terminal's responder.
// Scene-owned, non-key windows also let the privacy cover stay above the card.
import SwiftUI
import UIKit
import GameController
import Observation

@MainActor
@Observable
private final class ShortcutCheatSheetPresentation {
    var appearance: AppearancePreferences
    var store: ShortcutStore
    var tokens: DesignTokens
    var isVisible = false

    init(inputs: ShortcutCheatSheetAnchor.Inputs) {
        appearance = inputs.appearance
        store = inputs.store
        tokens = inputs.tokens
    }

    func update(_ inputs: ShortcutCheatSheetAnchor.Inputs) {
        appearance = inputs.appearance
        store = inputs.store
        tokens = inputs.tokens
    }
}

private struct ShortcutCheatSheetPresentationView: View {
    let presentation: ShortcutCheatSheetPresentation

    var body: some View {
        ShortcutCheatSheetView(
            sections: ShortcutCheatSheet.sections(
                store: presentation.store, notation: presentation.appearance.modifierNotation
            ),
            material: presentation.appearance.chromeMaterial,
            notation: presentation.appearance.modifierNotation,
            isPresented: presentation.isVisible
        )
        .environment(\.designTokens, presentation.tokens)
        .environment(presentation.appearance)
    }
}

private final class ShortcutCheatSheetWindow: UIWindow {
    override var canBecomeKey: Bool { false }
}

/// A visible window's root takes part in status-bar and home-indicator
/// resolution even when it is not key. Tessera hides both on iPad (and the
/// status bar in an iPhone session), so a default root would bring them back
/// for as long as ⌘ is held. Defer to whatever the app window shows.
private final class ShortcutCheatSheetHostingController: UIHostingController<ShortcutCheatSheetPresentationView> {
    weak var sourceWindow: UIWindow?

    private func source(_ child: (UIViewController) -> UIViewController?) -> UIViewController? {
        var top = sourceWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        while let next = top.flatMap(child), next !== top { top = next }
        return top
    }

    override var prefersStatusBarHidden: Bool {
        source(\.childForStatusBarHidden)?.prefersStatusBarHidden ?? true
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        source(\.childForStatusBarStyle)?.preferredStatusBarStyle ?? .default
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        source(\.childForHomeIndicatorAutoHidden)?.prefersHomeIndicatorAutoHidden ?? false
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        source(\.childForScreenEdgesDeferringSystemGestures)?
            .preferredScreenEdgesDeferringSystemGestures ?? []
    }
}

@MainActor
final class ShortcutCheatSheetController {
    static let shared = ShortcutCheatSheetController()

    private struct WeakAnchor {
        weak var value: ShortcutCheatSheetAnchor.Anchor?
    }

    @MainActor
    private final class Overlay {
        weak var anchor: ShortcutCheatSheetAnchor.Anchor?
        weak var sourceWindow: UIWindow?
        let window: ShortcutCheatSheetWindow
        let presentation: ShortcutCheatSheetPresentation
        var dismissal: DispatchWorkItem?

        init(anchor: ShortcutCheatSheetAnchor.Anchor, window: ShortcutCheatSheetWindow,
             presentation: ShortcutCheatSheetPresentation) {
            self.anchor = anchor
            sourceWindow = anchor.window
            self.window = window
            self.presentation = presentation
        }
    }

    private var anchors: [WeakAnchor] = []
    private var overlays: [ObjectIdentifier: Overlay] = [:]
    private var observers: [NSObjectProtocol] = []
    private var keyboardSubscription: HardwareKeyboardSubscription?
    private var suppressionCount = 0
    private var inactiveScenes: Set<ObjectIdentifier> = []
    private var applicationIsActive = UIApplication.shared.applicationState == .active
    private var watchdog: Timer?
    private var hideReason = "command released"

    private lazy var detector = CommandHoldDetector(
        schedule: { delay, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        },
        // Physical state, not just the stream: it catches a modifier pressed
        // while the recorder suppressed events, and a ⌘-down still queued in
        // the hub when the keyboard disconnected.
        isAllowed: { [weak self] in
            self?.eligibleAnchor() != nil && HardwareKeyboardEvents.shared.isOnlyCommandPressed
        },
        onShow: { [weak self] in self?.show(reason: "command held") },
        onHide: { [weak self] in
            guard let self else { return }
            self.hide(reason: self.hideReason)
        }
    )

    private init() {
        keyboardSubscription = HardwareKeyboardEvents.shared.subscribe { [weak self] keyCode, pressed in
            self?.keyChanged(keyCode, pressed: pressed)
        }
        observe(UIApplication.willResignActiveNotification) { controller, _ in
            controller.applicationIsActive = false
            controller.reset(reason: "application inactive", immediately: true)
        }
        observe(UIScene.willDeactivateNotification) { controller, note in
            if let scene = note.object as? UIWindowScene {
                controller.inactiveScenes.insert(ObjectIdentifier(scene))
            }
            controller.reset(reason: "scene inactive", immediately: true)
        }
        observe(.GCKeyboardDidDisconnect) { controller, _ in
            controller.reset(reason: "keyboard disconnected", immediately: true)
        }
        observe(UIApplication.didBecomeActiveNotification) { controller, _ in
            controller.applicationIsActive = true
            controller.schedulePinnedPreview()
        }
        observe(UIScene.didActivateNotification) { controller, note in
            if let scene = note.object as? UIWindowScene {
                controller.inactiveScenes.remove(ObjectIdentifier(scene))
            }
            controller.schedulePinnedPreview()
        }
        observe(UIWindow.didBecomeKeyNotification) { controller, _ in
            controller.schedulePinnedPreview()
        }
    }

    func beginSuppression() {
        suppressionCount += 1
        reset(reason: "chord recording", immediately: true)
    }

    func endSuppression() {
        guard suppressionCount > 0 else { return }
        suppressionCount -= 1
        schedulePinnedPreview()
    }

    fileprivate func anchorDidMove(_ anchor: ShortcutCheatSheetAnchor.Anchor) {
        // Detachment must destroy the old scene's window even if a hide
        // animation was still waiting for its completion callback.
        let stale = overlays.filter {
            $0.value.anchor === anchor
                && ($0.value.window.windowScene !== anchor.window?.windowScene
                    || $0.value.sourceWindow !== anchor.window)
        }
        if !stale.isEmpty {
            reset(reason: "anchor detached", immediately: true)
        }
        anchors.removeAll { $0.value == nil || $0.value === anchor }
        if anchor.window != nil { anchors.append(WeakAnchor(value: anchor)) }
        if eligibleAnchor() == nil { reset(reason: "no eligible scene", immediately: true) }
        schedulePinnedPreview()
    }

    fileprivate func removeAnchor(_ anchor: ShortcutCheatSheetAnchor.Anchor) {
        if overlays.values.contains(where: { $0.anchor === anchor }) {
            reset(reason: "anchor removed", immediately: true)
        }
        anchors.removeAll { $0.value == nil || $0.value === anchor }
        if eligibleAnchor() == nil { reset(reason: "no eligible scene", immediately: true) }
    }

    fileprivate func inputsDidChange(_ anchor: ShortcutCheatSheetAnchor.Anchor) {
        for overlay in overlays.values where overlay.anchor === anchor {
            guard isEligible(anchor), let inputs = anchor.inputs else {
                reset(reason: "feature disabled or app locked", immediately: true)
                return
            }
            overlay.presentation.update(inputs)
            applyStyle(inputs.appearance.mode, to: overlay.window)
        }
        if eligibleAnchor() == nil { reset(reason: "feature disabled or app locked", immediately: true) }
        schedulePinnedPreview()
    }

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (ShortcutCheatSheetController, Notification) -> Void
    ) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, note)
            }
        })
    }

    private func keyChanged(_ keyCode: GCKeyCode, pressed: Bool) {
        guard !isPinnedPreview, suppressionCount == 0, applicationIsActive else { return }
        let key: CommandHoldDetector.Key
        switch keyCode {
        case .leftGUI: key = .leftCommand
        case .rightGUI: key = .rightCommand
        default: key = .other(Int(keyCode.rawValue))
        }
        let isCommand = key == .leftCommand || key == .rightCommand
        if isCommand, pressed {
            detector.forgetKeys { remembered in
                guard case .other(let raw) = remembered else { return true }
                return HardwareKeyboardEvents.shared.isPressed(GCKeyCode(rawValue: CFIndex(raw)))
            }
        }
        hideReason = isCommand ? "command released" : "hold spoiled"
        detector.keyChanged(key, pressed: pressed)
    }

    private func isEligible(_ anchor: ShortcutCheatSheetAnchor.Anchor) -> Bool {
        guard applicationIsActive, suppressionCount == 0,
              anchor.inputs?.isEnabled == true,
              let window = anchor.window, !window.isHidden,
              let scene = window.windowScene,
              scene.activationState == .foregroundActive,
              !inactiveScenes.contains(ObjectIdentifier(scene)) else { return false }
        return true
    }

    private func eligibleAnchor() -> ShortcutCheatSheetAnchor.Anchor? {
        let eligible = anchors.compactMap(\.value).filter(isEligible)
        return eligible.first(where: { $0.window?.isKeyWindow == true }) ?? eligible.first
    }

    private func show(reason: String) {
        guard let anchor = eligibleAnchor(), let scene = anchor.window?.windowScene,
              let inputs = anchor.inputs else { return }
        let sceneID = ObjectIdentifier(scene)
        let overlay: Overlay
        if let existing = overlays[sceneID] {
            overlay = existing
            overlay.dismissal?.cancel()
            overlay.dismissal = nil
            overlay.anchor = anchor
            overlay.sourceWindow = anchor.window
            overlay.presentation.update(inputs)
        } else {
            let presentation = ShortcutCheatSheetPresentation(inputs: inputs)
            let window = ShortcutCheatSheetWindow(windowScene: scene)
            window.backgroundColor = .clear
            window.isUserInteractionEnabled = false
            window.windowLevel = .alert - 1
            let hosting = ShortcutCheatSheetHostingController(
                rootView: ShortcutCheatSheetPresentationView(presentation: presentation)
            )
            hosting.sourceWindow = anchor.window
            hosting.view.backgroundColor = .clear
            window.rootViewController = hosting
            overlay = Overlay(anchor: anchor, window: window, presentation: presentation)
            overlays[sceneID] = overlay
        }
        // A hold belongs to one scene, even if several RootViews are mounted.
        for (id, other) in overlays where id != sceneID { tearDown(other, sceneID: id) }
        applyStyle(inputs.appearance.mode, to: overlay.window)
        overlay.window.isHidden = false
        overlay.window.layoutIfNeeded()
        DispatchQueue.main.async { [weak self, weak overlay] in
            guard let self, let overlay, self.overlays[sceneID] === overlay,
                  overlay.dismissal == nil, let owner = overlay.anchor, self.isEligible(owner) else { return }
            overlay.presentation.isVisible = true
        }
        startWatchdog()
        #if DEBUG
        NSLog("[cheat-sheet] show: \(reason)")
        #endif
    }

    private func hide(reason: String, immediately: Bool = false) {
        watchdog?.invalidate()
        watchdog = nil
        for (sceneID, overlay) in overlays {
            if immediately {
                tearDown(overlay, sceneID: sceneID)
            } else if overlay.dismissal == nil {
                overlay.presentation.isVisible = false
                let item = DispatchWorkItem { [weak self, weak overlay] in
                    MainActor.assumeIsolated {
                        guard let self, let overlay, self.overlays[sceneID] === overlay else { return }
                        self.tearDown(overlay, sceneID: sceneID)
                    }
                }
                overlay.dismissal = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
            } else {
                continue
            }
            #if DEBUG
            NSLog("[cheat-sheet] hide: \(reason)")
            #endif
        }
    }

    private func tearDown(_ overlay: Overlay, sceneID: ObjectIdentifier) {
        overlay.dismissal?.cancel()
        overlay.window.isHidden = true
        overlay.window.rootViewController = nil
        overlays.removeValue(forKey: sceneID)
    }

    private func reset(reason: String, immediately: Bool = false) {
        hideReason = reason
        detector.reset()
        hide(reason: reason, immediately: immediately)
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        guard !isPinnedPreview else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !HardwareKeyboardEvents.shared.isCommandPressed {
                    self.reset(reason: "command key-up lost")
                }
            }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyStyle(_ mode: AppearanceModeOption, to window: UIWindow) {
        switch mode {
        case .dark: window.overrideUserInterfaceStyle = .dark
        case .light: window.overrideUserInterfaceStyle = .light
        case .system: window.overrideUserInterfaceStyle = .unspecified
        }
    }

    private var isPinnedPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["TESSERA_SHORTCUT_CHEAT_SHEET_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

    private func schedulePinnedPreview() {
        #if DEBUG
        guard isPinnedPreview else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let anchor = self.eligibleAnchor(),
                  !self.overlays.values.contains(where: { $0.anchor === anchor && $0.dismissal == nil }) else { return }
            self.show(reason: "debug preview")
        }
        #endif
    }
}

struct ShortcutCheatSheetAnchor: UIViewRepresentable {
    struct Inputs {
        let appearance: AppearancePreferences
        let store: ShortcutStore
        let tokens: DesignTokens
        let isEnabled: Bool
    }

    let appearance: AppearancePreferences
    let shortcutStore: ShortcutStore
    let tokens: DesignTokens
    let isEnabled: Bool

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ uiView: Anchor, context: Context) {
        uiView.inputs = Inputs(appearance: appearance, store: shortcutStore, tokens: tokens, isEnabled: isEnabled)
        ShortcutCheatSheetController.shared.inputsDidChange(uiView)
    }

    static func dismantleUIView(_ uiView: Anchor, coordinator: ()) {
        ShortcutCheatSheetController.shared.removeAnchor(uiView)
    }

    final class Anchor: UIView {
        fileprivate var inputs: Inputs?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            ShortcutCheatSheetController.shared.anchorDidMove(self)
        }
    }
}
