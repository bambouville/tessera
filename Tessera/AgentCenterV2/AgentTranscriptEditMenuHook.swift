// Tessera/AgentCenterV2/AgentTranscriptEditMenuHook.swift
//
// Adds the transcript's selection items to the system edit menu.
//
// SwiftUI's selectable `Text` has no public API for edit-menu items (checked
// against the iOS 27.1 SDK interfaces). Its menu still asks the responder
// chain to build a `.context` menu, and that chain ends at the `UIWindow`.
// `UIWindow` inherits `UIResponder.buildMenu(with:)` without implementing
// it, so this ADDS a `UIWindow` implementation — it never replaces one.
// The addition contributes items only when the first responder sits inside
// an Agent Center transcript marked by `AgentTranscriptSelectionScope`, and
// always calls the inherited implementation. Every other menu in the app
// (terminal, text fields, the composer, Files, artifacts) passes through
// untouched after two cheap checks.
//
// Rejected alternatives, measured on iOS 27: hosting the transcript in a
// `UIHostingController` subclass (breaks state/preference tracking across
// the boundary), an `NSPrincipalClass` application subclass (SwiftUI
// installs its own), and `UIMenuController.menuItems` (SwiftUI's menu
// ignores them).

import ObjectiveC
import UIKit

@MainActor
enum AgentTranscriptEditMenuHook {
    enum InstallDecision: Equatable {
        case install
        /// `UIWindow` (or `UIView`) already implements the selector: leave
        /// it alone and keep the feature off.
        case refuse
    }

    /// Install only where `UIWindow` would otherwise inherit the responder
    /// implementation; an existing implementation is never replaced.
    nonisolated static func installDecision(windowHasOwnImplementation: Bool) -> InstallDecision {
        windowHasOwnImplementation ? .refuse : .install
    }

    private(set) static var isInstalled = false
    private static var attempted = false

    /// Idempotent; the first transcript marker to reach a window calls it.
    static func installIfNeeded() {
        guard !attempted else { return }
        attempted = true
        let selector = #selector(UIResponder.buildMenu(with:))
        guard let inherited = class_getInstanceMethod(UIResponder.self, selector),
              let superclass = class_getSuperclass(UIWindow.self) else {
            NSLog("[AgentSelection] buildMenu(with:) not found; transcript menu items off")
            return
        }
        let own = class_getInstanceMethod(UIWindow.self, selector)
        guard installDecision(windowHasOwnImplementation: own != inherited) == .install else {
            NSLog("[AgentSelection] UIWindow implements buildMenu(with:); transcript menu items off")
            return
        }
        typealias BuildMenu = @convention(c) (AnyObject, Selector, UIMenuBuilder) -> Void
        let block: @convention(block) (AnyObject, UIMenuBuilder) -> Void = { receiver, builder in
            if let window = receiver as? UIWindow {
                MainActor.assumeIsolated { contribute(to: builder, in: window) }
            }
            // Whatever the superclass implements now (resolved per call, so a
            // later override up the chain is still honoured).
            let next = unsafeBitCast(class_getMethodImplementation(superclass, selector), to: BuildMenu.self)
            next(receiver, selector, builder)
        }
        isInstalled = class_addMethod(
            UIWindow.self, selector, imp_implementationWithBlock(block), method_getTypeEncoding(inherited))
        if !isInstalled { NSLog("[AgentSelection] could not add buildMenu(with:) to UIWindow") }
    }

    /// Runs for every menu the window builds, so both bail-outs come first.
    private static func contribute(to builder: UIMenuBuilder, in window: UIWindow) {
        guard builder.system == .context, AgentTranscriptSelectionRegistry.hasTranscripts else { return }
        guard let responder = UIResponder.agentSelectionFirstResponder() as? UIView,
              responder.window === window,
              let context = AgentTranscriptSelectionRegistry.context(enclosing: responder),
              let text = selectedText(of: responder) else { return }
        let items = AgentTranscriptSelectionPolicy.items(for: text, thread: context.thread())
        #if DEBUG
        // Transcript text stays out of the system log, even in DEBUG.
        NSLog("TESSERA_AGENT_SELECTION menu items=%@ selectionLength=%ld",
              items.map(\.rawValue).joined(separator: ","), text.count)
        #endif
        guard !items.isEmpty else { return }
        // No identifiers: a duplicate identifier in one menu is fatal, and
        // UIKit generates unique ones.
        let actions = items.map { item in
            UIAction(title: item.title) { [weak context] _ in context?.perform(item, text) }
        }
        builder.insertChild(UIMenu(options: .displayInline, children: actions), atStartOfMenu: .standardEdit)
    }

    /// The selected text of a read-only text selection. Editable text keeps
    /// its own menu even inside a transcript.
    static func selectedText(of responder: UIResponder) -> String? {
        guard let input = responder as? UITextInput, !(responder is UITextField) else { return nil }
        if let textView = responder as? UITextView, textView.isEditable { return nil }
        guard let range = input.selectedTextRange, !range.isEmpty,
              let text = input.text(in: range), !text.isEmpty else { return nil }
        return text
    }
}

extension UIResponder {
    private static weak var agentSelectionCaptured: UIResponder?

    /// The key window's first responder: an action sent to no target lands
    /// on it first, and every responder answers this one.
    @MainActor
    static func agentSelectionFirstResponder() -> UIResponder? {
        agentSelectionCaptured = nil
        defer { agentSelectionCaptured = nil }
        UIApplication.shared.sendAction(
            #selector(agentSelectionCaptureFirstResponder), to: nil, from: nil, for: nil)
        return agentSelectionCaptured
    }

    @objc private func agentSelectionCaptureFirstResponder() {
        UIResponder.agentSelectionCaptured = self
    }
}
