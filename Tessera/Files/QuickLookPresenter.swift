// Tessera/Files/QuickLookPresenter.swift
// Remote Files feature - Quick Look and share sheet wrappers.
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation
import QuickLook
import SwiftUI
import UIKit

struct QuickLookPresenter: View {
    let fileURL: URL
    let displayTitle: String?
    let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(fileURL: URL, displayTitle: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.displayTitle = displayTitle
        self.onDismiss = onDismiss
    }

    private var presentsMarkdown: Bool {
        MarkdownPreviewSupport.isMarkdown(fileURL: fileURL, displayTitle: displayTitle)
    }

    @ViewBuilder
    var body: some View {
        if presentsMarkdown {
            MarkdownPreview(fileURL: fileURL, displayTitle: displayTitle) {
                finish()
            }
        } else {
            QuickLookController(fileURL: fileURL, displayTitle: displayTitle) {
                finish()
            }
        }
    }

    private func finish() {
        onDismiss?()
        dismiss()
    }
}

/// Routing and parsing live beside the presenter so every Quick Look entry
/// path gets the same behavior: panel row tap, row menu, Quick Open, and the
/// terminal-selection action (with either the panel or session hosting the
/// sheet). Staged preview URLs retain the remote filename, while
/// `displayTitle` is also checked so callers remain correct if staging changes.
enum MarkdownPreviewSupport {
    private static let extensions: Set<String> = [
        "md", "markdown", "mdown", "mkdn", "mkd", "mdwn",
        "mdtext", "mdtxt", "rmd", "qmd",
    ]

    static func isMarkdown(fileURL: URL, displayTitle: String?) -> Bool {
        [displayTitle, fileURL.lastPathComponent]
            .compactMap { $0 }
            .map { ($0 as NSString).pathExtension.lowercased() }
            .contains { extensions.contains($0) }
    }

    static func loadDocument(from fileURL: URL) throws -> MarkdownDocument {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        return try MarkdownDocument(
            source: source,
            baseURL: fileURL.deletingLastPathComponent()
        )
    }
}

/// A small semantic model over Foundation's CommonMark parser. Rendering
/// blocks ourselves preserves headings, lists, quotes, and fenced code; a
/// single `Text(AttributedString)` would retain inline emphasis but flatten
/// most block structure and spacing.
struct MarkdownDocument: Sendable {
    struct Block: Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
            case paragraph
            case heading(level: Int)
            case code(language: String?)
            case thematicBreak
        }

        enum ListStyle: Equatable, Sendable {
            case ordered
            case unordered
        }

        let id: Int
        let kind: Kind
        let listStyle: ListStyle?
        let listOrdinal: Int?
        let listDepth: Int
        let quoteDepth: Int
        var content: AttributedString
    }

    let blocks: [Block]

    init(source: String, baseURL: URL?) throws {
        let parsed = try AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full),
            baseURL: baseURL
        )

        var blocks: [Block] = []
        for run in parsed.runs {
            let descriptor = Self.descriptor(for: run.presentationIntent)
            var content = AttributedString(parsed[run.range])
            content.presentationIntent = nil

            if blocks.last?.id == descriptor.id {
                blocks[blocks.count - 1].content.append(content)
            } else {
                blocks.append(Block(
                    id: descriptor.id,
                    kind: descriptor.kind,
                    listStyle: descriptor.listStyle,
                    listOrdinal: descriptor.listOrdinal,
                    listDepth: descriptor.listDepth,
                    quoteDepth: descriptor.quoteDepth,
                    content: content
                ))
            }
        }
        self.blocks = blocks
    }

    private struct BlockDescriptor {
        var id = 0
        var kind: Block.Kind = .paragraph
        var listStyle: Block.ListStyle?
        var listOrdinal: Int?
        var listDepth = 0
        var quoteDepth = 0
        var foundLeafBlock = false
    }

    private static func descriptor(for intent: PresentationIntent?) -> BlockDescriptor {
        guard let intent else { return BlockDescriptor() }
        var descriptor = BlockDescriptor()

        // Components are innermost first. The first paragraph/header/code
        // component identifies the rendered block; later components describe
        // its list/quote ancestry.
        for component in intent.components {
            switch component.kind {
            case .paragraph where !descriptor.foundLeafBlock:
                descriptor.id = component.identity
                descriptor.kind = .paragraph
                descriptor.foundLeafBlock = true
            case .header(let level) where !descriptor.foundLeafBlock:
                descriptor.id = component.identity
                descriptor.kind = .heading(level: level)
                descriptor.foundLeafBlock = true
            case .codeBlock(let language) where !descriptor.foundLeafBlock:
                descriptor.id = component.identity
                descriptor.kind = .code(language: language)
                descriptor.foundLeafBlock = true
            case .thematicBreak where !descriptor.foundLeafBlock:
                descriptor.id = component.identity
                descriptor.kind = .thematicBreak
                descriptor.foundLeafBlock = true
            case .listItem(let ordinal):
                if descriptor.listOrdinal == nil {
                    descriptor.listOrdinal = ordinal
                }
            case .orderedList:
                descriptor.listDepth += 1
                if descriptor.listStyle == nil { descriptor.listStyle = .ordered }
            case .unorderedList:
                descriptor.listDepth += 1
                if descriptor.listStyle == nil { descriptor.listStyle = .unordered }
            case .blockQuote:
                descriptor.quoteDepth += 1
            default:
                break
            }
        }
        return descriptor
    }
}

private struct MarkdownPreview: View {
    private enum LoadState {
        case loading
        case loaded(MarkdownDocument)
        case failed(String)
    }

    let fileURL: URL
    let displayTitle: String?
    let onDone: () -> Void

    @State private var loadState: LoadState = .loading

    private var title: String {
        displayTitle ?? fileURL.lastPathComponent
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share \(title)")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .task(id: fileURL) {
            loadState = .loading
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try MarkdownPreviewSupport.loadDocument(from: fileURL)
                }.value
                try Task.checkCancellation()
                loadState = .loaded(document)
            } catch is CancellationError {
                return
            } catch {
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView("Rendering Markdown…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Unable to Render Markdown",
                systemImage: "doc.text",
                description: Text(message)
            )
        case .loaded(let document):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(document.blocks) { block in
                        MarkdownBlockView(block: block)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Color(uiColor: .systemBackground))
            .textSelection(.enabled)
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block

    var body: some View {
        Group {
            if block.quoteDepth > 0 {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.secondary.opacity(0.45))
                        .frame(width: 3)
                    blockBody
                }
                .padding(.leading, CGFloat(block.quoteDepth - 1) * 14)
                .foregroundStyle(.secondary)
            } else {
                blockBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var blockBody: some View {
        switch block.kind {
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        case .code:
            ScrollView(.horizontal) {
                Text(block.content)
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        case .heading(let level):
            textWithOptionalListMarker
                .font(headingFont(level: level))
                .fontWeight(level <= 2 ? .bold : .semibold)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph:
            textWithOptionalListMarker
                .font(.body)
        }
    }

    @ViewBuilder
    private var textWithOptionalListMarker: some View {
        if let style = block.listStyle {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(listMarker(style))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(block.content)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 20)
        } else {
            Text(block.content)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listMarker(_ style: MarkdownDocument.Block.ListStyle) -> String {
        switch style {
        case .ordered:
            return "\(block.listOrdinal ?? 1)."
        case .unordered:
            return "•"
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title
        case 3: return .title2
        case 4: return .title3
        default: return .headline
        }
    }
}

private struct QuickLookController: UIViewControllerRepresentable {
    let fileURL: URL
    let displayTitle: String?
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL, displayTitle: displayTitle, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        previewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.dismissPreview)
        )

        return UINavigationController(rootViewController: previewController)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.update(fileURL: fileURL, displayTitle: displayTitle)
        context.coordinator.onDismiss = onDismiss
        (controller.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private var item: PreviewItem
        var onDismiss: () -> Void
        private var hasDismissed = false

        init(fileURL: URL, displayTitle: String?, onDismiss: @escaping () -> Void) {
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
            dismissPreview()
        }

        @objc func dismissPreview() {
            guard !hasDismissed else { return }
            hasDismissed = true
            onDismiss()
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
