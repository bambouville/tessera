// Tessera/Files/FileRowInteraction.swift
// The Files row's tap, context menu, and drag, moved off SwiftUI's
// `.contextMenu` onto UIKit's own `UIContextMenuInteraction`.
//
// Why: SwiftUI's context menu repaints its platter for several frames after
// it presents — measured on the `TESSERA_FILES_HARNESS` rig, every SwiftUI
// arm (custom preview, no preview, no drag, no backstop, and a bare `Text`
// sharing nothing with this panel) settled over 3–8 frames landing at
// +0.84…1.35s after touch-down, which is the single flicker users see just
// after the menu opens. A UIKit interaction on the same rig settled in 2
// frames, and at +0.25s when it carried a hosted SwiftUI preview — early
// enough to fall inside the presentation animation.
//
// The repeated flicker (a menu re-publishing on every panel body pass) was
// fixed separately by the row's `Equatable` short-circuit; this also makes
// that structural, because the menu is now built in the delegate callback at
// presentation time and a row rebuild cannot reach it.

import SwiftUI
import UIKit

/// One entry in the row's context menu.
struct FileRowMenuAction {
    var title: String
    var systemImage: String
    var isDestructive = false
    var handler: () -> Void

    init(
        title: LocalizedStringResource,
        systemImage: String,
        isDestructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = String(localized: title)
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

/// Installs the row's interactions on a transparent view laid over the row.
/// The view takes the touches — the row's SwiftUI content is presentation
/// only — so tap, long press, and drag arbitrate in UIKit the way they do in
/// a `UITableView`, rather than across a SwiftUI/UIKit seam.
struct FileRowInteraction: UIViewRepresentable {
    /// Accessibility identity, carried here because the SwiftUI content is
    /// hidden from accessibility to avoid a duplicate element.
    let identifier: String
    let accessibilityLabel: String
    /// Sections are separated by a divider in the presented menu.
    let sections: [[FileRowMenuAction]]
    let onPrimary: () -> Void
    let onMenuPresence: (Bool) -> Void
    /// `nil` when the row cannot be dragged.
    let dragProvider: (() -> NSItemProvider?)?
    /// Built only when a menu is actually presented; `nil` leaves UIKit to
    /// lift the row itself.
    let makePreview: (() -> AnyView)?
    let previewWidth: CGFloat

    func makeUIView(context: Context) -> RowInteractionView {
        let view = RowInteractionView()
        apply(to: view)
        return view
    }

    func updateUIView(_ view: RowInteractionView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: RowInteractionView) {
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = accessibilityLabel
        view.onPrimary = onPrimary
        view.onMenuPresence = onMenuPresence
        view.dragProvider = dragProvider
        view.makePreview = makePreview
        view.previewWidth = previewWidth
        view.sections = sections
        view.dragEnabled = dragProvider != nil
    }

    final class RowInteractionView: UIView,
                                    UIContextMenuInteractionDelegate,
                                    UIDragInteractionDelegate,
                                    UIGestureRecognizerDelegate {
        var onPrimary: () -> Void = {}
        var onMenuPresence: (Bool) -> Void = { _ in }
        var dragProvider: (() -> NSItemProvider?)?
        var makePreview: (() -> AnyView)?
        var previewWidth: CGFloat = 0
        var sections: [[FileRowMenuAction]] = []

        var dragEnabled: Bool {
            get { dragInteraction.isEnabled }
            set { dragInteraction.isEnabled = newValue }
        }

        private var dragInteraction: UIDragInteraction!

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityTraits = .button

            addInteraction(UIContextMenuInteraction(delegate: self))
            let drag = UIDragInteraction(delegate: self)
            drag.isEnabled = false
            addInteraction(drag)
            dragInteraction = drag

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.delegate = self
            addGestureRecognizer(tap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        @objc private func handleTap() {
            onPrimary()
        }

        override func accessibilityActivate() -> Bool {
            onPrimary()
            return true
        }

        // Let the enclosing scroll view's pan win, so a flick that starts on
        // a row still scrolls the tree.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer
        }

        // MARK: - Context menu

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !sections.isEmpty else { return nil }
            let provider: UIContextMenuContentPreviewProvider? = makePreview == nil
                ? nil
                : { [weak self] in self?.makePreviewController() }
            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: provider,
                actionProvider: { [weak self] _ in self?.makeMenu() }
            )
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            onMenuPresence(true)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            // The backstop has to outlive the dismissal animation, which is
            // the window where UIKit still suppresses glass behind the menu.
            if let animator {
                animator.addCompletion { [weak self] in self?.onMenuPresence(false) }
            } else {
                onMenuPresence(false)
            }
        }

        /// Sizing the hosted preview up front is what keeps the platter from
        /// resizing a frame later — the resize is the flicker.
        private func makePreviewController() -> UIViewController? {
            guard let makePreview else { return nil }
            FilesUIDiagnostics.shared.menuPreviewBuild()
            let host = UIHostingController(rootView: makePreview())
            host.view.backgroundColor = .clear
            let width = previewWidth > 0 ? previewWidth : bounds.width
            let fitted = host.sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)
            )
            host.preferredContentSize = CGSize(width: width, height: fitted.height)
            return host
        }

        private func makeMenu() -> UIMenu {
            FilesUIDiagnostics.shared.menuBuild()
            let groups = sections.map { section -> UIMenuElement in
                let elements = section.map { action -> UIMenuElement in
                    UIAction(
                        title: action.title,
                        image: UIImage(systemName: action.systemImage),
                        attributes: action.isDestructive ? .destructive : []
                    ) { _ in action.handler() }
                }
                return UIMenu(title: "", options: .displayInline, children: elements)
            }
            return UIMenu(title: "", children: groups)
        }

        // MARK: - Drag

        func dragInteraction(
            _ interaction: UIDragInteraction,
            itemsForBeginning session: any UIDragSession
        ) -> [UIDragItem] {
            guard let provider = dragProvider?() else { return [] }
            return [UIDragItem(itemProvider: provider)]
        }
    }
}
