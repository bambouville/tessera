// Tessera/Files/QuickLookPresenter.swift
// Remote Files feature - Quick Look and share sheet wrappers.
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation
import QuickLook
import SwiftUI
import UIKit

struct QuickLookPresenter: UIViewControllerRepresentable {
    let fileURL: URL
    let displayTitle: String?
    let onDismiss: (() -> Void)?

    init(fileURL: URL, displayTitle: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.displayTitle = displayTitle
        self.onDismiss = onDismiss
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, displayTitle: displayTitle, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.update(fileURL: fileURL, displayTitle: displayTitle)
        context.coordinator.onDismiss = onDismiss
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private var item: PreviewItem
        var onDismiss: (() -> Void)?

        init(fileURL: URL, displayTitle: String?, onDismiss: (() -> Void)?) {
            self.item = PreviewItem(url: fileURL, title: displayTitle)
            self.onDismiss = onDismiss
        }

        func update(fileURL: URL, displayTitle: String?) {
            item = PreviewItem(url: fileURL, title: displayTitle)
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            item
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onDismiss?()
        }
    }
}

/// Wraps the system share sheet. Prefer presenting this from SwiftUI with `.sheet`,
/// but keep the popover anchor guard so iPad popover presentation never crashes.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: (() -> Void)?

    init(items: [Any], completion: (() -> Void)? = nil) {
        self.items = items
        self.completion = completion
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        configure(controller)
    }

    private func configure(_ controller: UIActivityViewController) {
        controller.completionWithItemsHandler = { _, _, _, _ in
            completion?()
        }

        guard let popover = controller.popoverPresentationController else {
            return
        }

        controller.loadViewIfNeeded()
        guard let sourceView = controller.view else {
            return
        }

        popover.sourceView = sourceView
        popover.sourceRect = CGRect(
            x: sourceView.bounds.midX,
            y: sourceView.bounds.midY,
            width: 1,
            height: 1
        )
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String?

    init(url: URL, title: String?) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? {
        url
    }

    var previewItemTitle: String? {
        title
    }
}
