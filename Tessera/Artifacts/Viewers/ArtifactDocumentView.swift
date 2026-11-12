import Foundation
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Requests a content-only MarkdownPreview with fresh reads for each view
/// identity, rather than the modal navigation stack and document cache.
private struct ArtifactDocumentEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var artifactDocumentEmbedded: Bool {
        get { self[ArtifactDocumentEmbeddedKey.self] }
        set { self[ArtifactDocumentEmbeddedKey.self] = newValue }
    }
}

/// The caller owns the cached file and its image sidecars. Nothing here
/// connects a remote host, presents a modal, or removes the caller's files.
@MainActor
struct ArtifactDocumentView: View {
    let localURL: URL
    let title: String
    let prepareImages: ArtifactImagePreparation?
    let reloadToken: AnyHashable

    init(
        localURL: URL,
        title: String,
        prepareImages: ArtifactImagePreparation? = nil,
        reloadToken: AnyHashable = 0
    ) {
        self.localURL = localURL
        self.title = title
        self.prepareImages = prepareImages
        self.reloadToken = reloadToken
    }

    @ViewBuilder
    var body: some View {
        if !localURL.isFileURL {
            ContentUnavailableView("this document is not cached", systemImage: "doc.text")
        } else if MarkdownPreviewSupport.isMarkdown(fileURL: localURL, displayTitle: title)
                    || fileExtension == "mdx" {
            // QuickLookPresenter is the module-visible entry point to the
            // private MarkdownPreview. It already stages optional images
            // after showing text and uses MarkdownPreviewSupport to parse.
            markdownPresenter
                .environment(\.artifactDocumentEmbedded, true)
                .toolbar(.hidden, for: .navigationBar)
                .id(ArtifactDocumentIdentity(url: localURL, title: title, reloadToken: reloadToken))
        } else if isText {
            ArtifactTextDocument(localURL: localURL, title: title, reloadToken: reloadToken)
        } else {
            ArtifactQuickLookDocument(localURL: localURL, title: title, reloadToken: reloadToken)
        }
        // Both UIKit scrollers and Markdown's List receive the parent's safe
        // area, including the software keyboard. There is no nested sheet or
        // full-screen presentation on either compact or regular layouts.
    }

    /// A document shown offline has no preparation; the first live one is a
    /// new staging task, not the same one.
    var markdownPresenter: QuickLookPresenter {
        QuickLookPresenter(fileURL: localURL, displayTitle: title,
                           prepareImages: prepareImages?.prepare, imageGeneration: prepareImages?.generation ?? -1)
    }

    private var fileExtension: String {
        let namedExtension = (title as NSString).pathExtension.lowercased()
        return namedExtension.isEmpty ? localURL.pathExtension.lowercased() : namedExtension
    }

    private var isText: Bool {
        if let type = UTType(filenameExtension: fileExtension) {
            if type.conforms(to: .image) || type.conforms(to: .pdf) { return false }
            if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { return true }
        }
        let sourceExtensions: Set<String> = [
            "txt", "text", "log", "csv", "tsv", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "cfg", "conf",
            "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "kt", "kts", "java", "js", "jsx", "mjs", "cjs", "ts", "tsx",
            "py", "pyi", "rb", "go", "rs", "sh", "bash", "zsh", "fish", "sql", "xml", "css", "scss", "sass", "less",
            "html", "htm", "vue", "svelte", "gradle", "properties", "env", "gitignore", "gitattributes", "editorconfig",
            "rst", "adoc", "org", "patch", "diff", "ipynb", "lock", "strings", "xcconfig", "cmake", "r", "lua",
        ]
        if sourceExtensions.contains(fileExtension) { return true }
        let name = title.lowercased()
        return ["makefile", "dockerfile", "containerfile", "license", "copying", "readme", ".env", ".gitignore", ".editorconfig"].contains(name)
    }
}

private struct ArtifactDocumentIdentity: Hashable {
    let url: URL
    let title: String
    let reloadToken: AnyHashable
}

@MainActor
private struct ArtifactTextDocument: View {
    let localURL: URL
    let title: String
    let reloadToken: AnyHashable
    @Environment(\.designTokens) private var T
    @State private var text: String?
    @State private var failure: String?

    var body: some View {
        Group {
            if let text {
                ArtifactReadOnlyTextView(text: text)
            } else if let failure {
                ContentUnavailableView("unable to read this file", systemImage: "doc.text", description: Text(verbatim: failure))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(T.panelBg)
        .task(id: ArtifactDocumentIdentity(url: localURL, title: title, reloadToken: reloadToken)) {
            text = nil
            failure = nil
            let url = localURL
            let task = Task.detached(priority: .userInitiated) { try Self.loadText(from: url) }
            do {
                let loaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                text = loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }

    nonisolated private static func loadText(from url: URL) throws -> String {
        let limit = 16 * 1024 * 1024
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try Task.checkCancellation()
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ArtifactRemoteReadError.fileTooLarge(maxBytes: limit) }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}

@MainActor
private struct ArtifactReadOnlyTextView: UIViewRepresentable {
    let text: String
    @Environment(\.designTokens) private var T

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(name: "JetBrainsMono-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.keyboardDismissMode = .interactive
        view.text = text
        view.textColor = UIColor(T.fgMuted)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        uiView.textColor = UIColor(T.fgMuted)
    }
}

/// QLPreviewController is a real child, without a navigation controller's
/// Done/size buttons. Reload only when the URL/title/token changes, because
/// restarting Quick Look on every SwiftUI update can leave it blank.
@MainActor
private struct ArtifactQuickLookDocument: UIViewControllerRepresentable {
    let localURL: URL
    let title: String
    let reloadToken: AnyHashable

    func makeCoordinator() -> Coordinator {
        Coordinator(identity: ArtifactDocumentIdentity(url: localURL, title: title, reloadToken: reloadToken))
    }

    func makeUIViewController(context: Context) -> ArtifactQuickLookContainer {
        let container = ArtifactQuickLookContainer()
        container.previewController.dataSource = context.coordinator
        container.previewController.delegate = context.coordinator
        return container
    }

    func updateUIViewController(_ controller: ArtifactQuickLookContainer, context: Context) {
        let identity = ArtifactDocumentIdentity(url: localURL, title: title, reloadToken: reloadToken)
        guard context.coordinator.update(identity) else { return }
        controller.previewController.reloadData()
        controller.previewController.refreshCurrentPreviewItem()
    }

    static func dismantleUIViewController(_ controller: ArtifactQuickLookContainer, coordinator: Coordinator) {
        controller.previewController.dataSource = nil
        controller.previewController.delegate = nil
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
        private var identity: ArtifactDocumentIdentity
        private var item: Item

        init(identity: ArtifactDocumentIdentity) {
            self.identity = identity
            self.item = Item(url: identity.url, title: identity.title)
        }

        func update(_ identity: ArtifactDocumentIdentity) -> Bool {
            guard self.identity != identity else { return false }
            self.identity = identity
            item = Item(url: identity.url, title: identity.title)
            return true
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
    }

    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, title: String) {
            previewItemURL = url
            previewItemTitle = title
        }
    }
}

@MainActor
private final class ArtifactQuickLookContainer: UIViewController {
    let previewController = QLPreviewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(previewController)
        previewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewController.view)
        NSLayoutConstraint.activate([
            previewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            previewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        previewController.didMove(toParent: self)
    }
}
