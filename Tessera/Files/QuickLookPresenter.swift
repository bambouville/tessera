// Tessera/Files/QuickLookPresenter.swift
// Remote Files feature - Quick Look and share sheet wrappers.
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation
import ImageIO
import TesseraCore
import QuickLook
import SwiftUI
import UIKit

/// How big a Quick Look preview gets. `popup` keeps the system sheet — a
/// centered form sheet on iPad, a page sheet on iPhone — which is the right
/// glance for an image or a short config file. `fullScreen` hands the whole
/// window to the preview, which is what a long document wants. The choice is
/// persisted, so it carries to the next preview from any entry path.
enum QuickLookPresentationMode: String, CaseIterable {
    case popup
    case fullScreen

    static let storageKey = "tessera.pref.quickLookPresentation"
    static let fallback: QuickLookPresentationMode = .popup

    var toggled: QuickLookPresentationMode {
        self == .popup ? .fullScreen : .popup
    }

    /// The glyph advertises the destination, matching how the system's own
    /// expand/collapse affordances read.
    var toggleSymbolName: String {
        self == .popup
            ? "arrow.up.left.and.arrow.down.right"
            : "arrow.down.right.and.arrow.up.left"
    }

    var toggleLabel: String {
        self == .popup
            ? String(localized: "Enter Full Screen")
            : String(localized: "Exit Full Screen")
    }
}

/// One pending preview request, two possible SwiftUI containers (`.sheet` for
/// `popup`, `.fullScreenCover` for `fullScreen`). Toggling the size while a
/// preview is up must hand the request from one container to the other rather
/// than cancel it, so the outgoing container's `nil` write is ignored — by the
/// time it lands, `mode` already names the incoming container.
enum QuickLookPresentationRouting {
    static func presentedItem<Item>(
        _ item: Item?,
        mode: QuickLookPresentationMode,
        container: QuickLookPresentationMode
    ) -> Item? {
        mode == container ? item : nil
    }

    static func clearsRequest(
        mode: QuickLookPresentationMode,
        container: QuickLookPresentationMode
    ) -> Bool {
        mode == container
    }
}

extension View {
    /// Hosts `item`'s preview at the user's chosen size. Every Quick Look
    /// entry path routes through here so the size toggle inside the preview
    /// means the same thing no matter which surface opened the file.
    func quickLookPreview(item: Binding<FilesPanelController.PreviewRequest?>) -> some View {
        modifier(QuickLookPreviewPresentation(item: item))
    }
}

private struct QuickLookPreviewPresentation: ViewModifier {
    @Binding var item: FilesPanelController.PreviewRequest?

    @AppStorage(QuickLookPresentationMode.storageKey)
    private var mode: QuickLookPresentationMode = QuickLookPresentationMode.fallback

    func body(content: Content) -> some View {
        content
            .sheet(item: container(.popup)) { request in
                preview(request)
            }
            .fullScreenCover(item: container(.fullScreen)) { request in
                preview(request)
            }
    }

    private func container(
        _ container: QuickLookPresentationMode
    ) -> Binding<FilesPanelController.PreviewRequest?> {
        Binding(
            get: {
                QuickLookPresentationRouting.presentedItem(item, mode: mode, container: container)
            },
            set: { newValue in
                guard newValue == nil else { return }
                guard QuickLookPresentationRouting.clearsRequest(
                    mode: mode,
                    container: container
                ) else { return }
                item = nil
            }
        )
    }

    @ViewBuilder
    private func preview(_ request: FilesPanelController.PreviewRequest) -> some View {
        // Bracket the presentation in the log. The terminal keeps ingesting
        // and rendering behind a preview, and it resizes when the modal takes
        // the safe area — a reported repaint artifact after closing a preview
        // has to be read against those two facts, which need this marker to
        // line up with the `size-changed` and `terminal-output-burst` lines.
        let presenter = QuickLookPresenter(fileURL: request.localURL, displayTitle: request.title, prepareImages: request.prepareImages)
            .onAppear {
                let surface: FilesUIDiagnostics.Surface = MarkdownPreviewSupport.isMarkdown(
                    fileURL: request.localURL, displayTitle: request.title
                ) ? .markdownPreview : .quickLook
                FilesUIDiagnostics.shared.previewPresentationChanged(surface: surface)
                FilesUIDiagnostics.shared.timeline(
                    "preview-present", detail: "mode=\(mode.rawValue) as=\(surface.rawValue)"
                )
            }
            .onDisappear {
                FilesUIDiagnostics.shared.previewPresentationChanged(surface: nil)
                FilesUIDiagnostics.shared.timeline(
                    "preview-dismiss", detail: "mode=\(mode.rawValue)"
                )
            }
        switch mode {
        case .popup:
            // The sheet supplies its own inset chrome, so the preview fills it.
            presenter.ignoresSafeArea()
        case .fullScreen:
            // A full-screen modal gets a zero top safe-area inset on iPad, so
            // a visible status bar would sit on top of the preview's nav bar.
            // Hiding it matches the rest of the in-session chrome (ContentView
            // and SessionView hide it too) and keeps the reading surface clean.
            presenter
                .statusBarHidden(true)
        }
    }
}

struct QuickLookPresenter: View {
    let fileURL: URL
    let displayTitle: String?
    let onDismiss: (() -> Void)?
    let prepareImages: (@MainActor () async throws -> Void)?

    @AppStorage(QuickLookPresentationMode.storageKey)
    private var mode: QuickLookPresentationMode = QuickLookPresentationMode.fallback

    @Environment(\.dismiss) private var dismiss

    init(fileURL: URL, displayTitle: String? = nil, prepareImages: (@MainActor () async throws -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.displayTitle = displayTitle
        self.onDismiss = onDismiss
        self.prepareImages = prepareImages
    }

    private var presentsMarkdown: Bool {
        MarkdownPreviewSupport.isMarkdown(fileURL: fileURL, displayTitle: displayTitle)
    }

    @ViewBuilder
    var body: some View {
        if presentsMarkdown {
            MarkdownPreview(
                prepareImages: prepareImages,
                fileURL: fileURL,
                displayTitle: displayTitle,
                mode: mode,
                onToggleMode: toggleMode
            ) {
                finish()
            }
        } else {
            QuickLookController(
                fileURL: fileURL,
                displayTitle: displayTitle,
                mode: mode,
                onToggleMode: toggleMode
            ) {
                finish()
            }
        }
    }

    private func toggleMode() {
        mode = mode.toggled
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
            baseURL: fileURL.deletingLastPathComponent(),
            images: MarkdownImageStaging.images(for: fileURL)
        )
    }
}

/// Toggling the preview size tears the whole presentation down and rebuilds it
/// in the other container, which would otherwise re-parse the document and
/// flash the spinner mid-transition. One entry is enough: it only has to
/// survive that hand-off.
@MainActor
private enum MarkdownDocumentCache {
    private static var entry: (url: URL, modified: Date?, document: MarkdownDocument)?

    static func document(for fileURL: URL) -> MarkdownDocument? {
        guard let entry, entry.url == fileURL, entry.modified == modificationDate(of: fileURL) else {
            return nil
        }
        return entry.document
    }

    static func store(_ document: MarkdownDocument, for fileURL: URL) {
        entry = (fileURL, modificationDate(of: fileURL), document)
    }

    private static func modificationDate(of fileURL: URL) -> Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// Private sidecar entries contain generated filenames only. Remote paths
/// never become local destinations, including absolute paths and ../ links.
enum MarkdownImageStaging {
    static let maxImageBytes: Int64 = 8 * 1024 * 1024
    static let maxTotalBytes: Int64 = 32 * 1024 * 1024
    static let maxImages = 32

    static func manifestURL(for document: URL) -> URL {
        document.appendingPathExtension("images.json")
    }

    static func destinations(source: String) throws -> [String] {
        var seen = Set<String>()
        return MarkdownImagePlaceholders(source).references.compactMap { reference in
            guard let destination = URL(string: reference.destination)?.relativeString,
                  MarkdownLocalImage.path(destination) != nil,
                  seen.insert(destination).inserted else { return nil }
            return destination
        }
    }

    static func images(for document: URL) -> [String: URL] {
        guard let data = try? Data(contentsOf: manifestURL(for: document)),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return names.compactMapValues { name in
            guard name == (name as NSString).lastPathComponent, name.hasPrefix("image-"),
                  name.hasSuffix(".png") else { return nil }
            return document.deletingLastPathComponent().appendingPathComponent(name)
        }
    }

    @MainActor
    static func stage(document: URL, remotePath: String, bridge: any FileBridging) async throws {
        if FileManager.default.fileExists(atPath: manifestURL(for: document).path) { return }
        let destinations = try await Task.detached(priority: .userInitiated) {
            try Self.destinations(source: String(contentsOf: document, encoding: .utf8))
        }.value
        var names: [String: String] = [:]
        var paths: [String: String] = [:]
        var remaining = maxTotalBytes
        var remainingPixels = 16 * 1024 * 1024
        var created: [URL] = []
        var completed = false
        defer {
            if !completed { for url in created { try? FileManager.default.removeItem(at: url) } }
        }
        for destination in destinations.prefix(maxImages) {
            try Task.checkCancellation()
            guard remaining > 0, remainingPixels > 0,
                  let path = MarkdownLocalImage.remotePath(destination, documentPath: remotePath) else { continue }
            if let name = paths[path] { names[destination] = name; continue }
            let download = document.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: download) }
            let limit = min(maxImageBytes, remaining)
            // Cancellation bounds downloads even when the remote file grows
            // after stat or does not report a size. This child owns its cancel.
            let task = Task {
                try await bridge.download(remotePath: path, to: download) { count, total in
                    if count > limit || (total ?? 0) > limit {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                try Task.checkCancellation()
            }
            do {
                try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                let name = "image-\(UUID().uuidString).png"
                let target = document.deletingLastPathComponent().appendingPathComponent(name)
                created.append(target)
                let pixelLimit = remainingPixels
                let pixels = await Task.detached(priority: .userInitiated) {
                    thumbnail(from: download, to: target, pixelLimit: pixelLimit)
                }.value
                if pixels > 0 {
                    remainingPixels -= pixels
                    names[destination] = name
                    paths[path] = name
                } else { try? FileManager.default.removeItem(at: target) }
            } catch {
                try Task.checkCancellation()
                // An unavailable image must not prevent reading the document.
            }
            let bytes = (try? download.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            remaining -= Int64(bytes)
        }
        try Task.checkCancellation()
        try JSONEncoder().encode(names).write(to: manifestURL(for: document), options: .atomic)
        completed = true
    }

    /// Decode off the UI thread and bound decoded pixels as well as wire bytes.
    static func thumbnail(from source: URL, to target: URL, pixelLimit: Int) -> Int {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(2048, Int(Double(pixelLimit).squareRoot())),
              ] as CFDictionary),
              let output = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil)
        else { return 0 }
        CGImageDestinationAddImage(output, image, nil)
        return CGImageDestinationFinalize(output) ? image.width * image.height : 0
    }
}

private enum MarkdownImageIdentity: AttributedStringKey {
    typealias Value = String
    static let name = "tessera.markdownImageIdentity"
}

private extension MarkdownImagePlaceholders {
    func restoringImages(in content: AttributedString, referencesByToken: [String: Reference]) -> AttributedString {
        guard !referencesByToken.isEmpty else { return content }
        var result = AttributedString()
        for run in content.runs {
            let text = String(content[run.range].characters)
            var cursor = text.startIndex
            while let start = text.range(of: prefix, range: cursor..<text.endIndex),
                  let end = text.range(of: "END:", range: start.upperBound..<text.endIndex),
                  let reference = referencesByToken[String(text[start.lowerBound..<end.upperBound])] {
                result.append(AttributedString(String(text[cursor..<start.lowerBound]), attributes: run.attributes))
                var image = AttributedString(reference.alt.isEmpty ? "\u{fffc}" : reference.alt, attributes: run.attributes)
                image.imageURL = URL(string: reference.destination)
                image[MarkdownImageIdentity.self] = reference.token
                result.append(image)
                cursor = end.upperBound
            }
            result.append(AttributedString(String(text[cursor...]), attributes: run.attributes))
        }
        return result
    }
}

struct MarkdownInlinePart: Identifiable {
    let id: Int
    var content: AttributedString
    let image: String?

    static func split(_ content: AttributedString) -> [Self] {
        var parts: [Self] = []
        var previousImageIdentity: String?
        for run in content.runs {
            let image = run.imageURL?.relativeString
            let text = AttributedString(content[run.range])
            let identity = run[MarkdownImageIdentity.self]
            if parts.last?.image == image, previousImageIdentity == identity, !parts.isEmpty {
                parts[parts.count - 1].content.append(text)
            } else {
                parts.append(Self(id: parts.count, content: text, image: image))
            }
            previousImageIdentity = identity
        }
        return parts
    }
}

private struct MarkdownInlineView: View {
    let content: AttributedString
    let images: [String: URL]

    var body: some View {
        if !content.runs.contains(where: { $0.imageURL != nil }) {
            Text(content)
        } else {
            imageContent
        }
    }

    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownInlinePart.split(content)) { part in
                if let destination = part.image {
                    if let link = part.content.runs.first?.link {
                        Link(destination: link) {
                            MarkdownStagedImage(url: images[destination], alt: String(part.content.characters))
                        }
                    } else {
                        MarkdownStagedImage(url: images[destination], alt: String(part.content.characters))
                    }
                } else {
                    Text(part.content)
                }
            }
        }
    }
}

private enum MarkdownDecodedImages {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static let lock = NSLock()

    static func load(_ url: URL) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

private struct MarkdownStagedImage: View {
    let url: URL?
    let alt: String
    @State private var image: UIImage?

    private var label: String { alt.replacingOccurrences(of: "\u{fffc}", with: "") }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(Text(verbatim: label))
            } else {
                Label { Text(verbatim: label) } icon: { Image(systemName: "photo") }
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached(priority: .userInitiated) { MarkdownDecodedImages.load(url) }.value
        }
    }
}

/// A small semantic model over Foundation's CommonMark parser. Rendering
/// blocks ourselves preserves headings, lists, quotes, and fenced code; a
/// single `Text(AttributedString)` would retain inline emphasis but flatten
/// most block structure and spacing.
struct MarkdownDocument: Sendable {
    /// One row of a GFM table. Cells stay separate values: folding them into
    /// a single string is what produced run-on text, and folding a whole
    /// table into one `Text` is what made it vanish (a very long attributed
    /// string lays out to the right height and then draws nothing).
    struct TableRow: Identifiable, Sendable {
        let id: Int
        let isHeader: Bool
        var cells: [AttributedString]
    }

    struct Block: Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
            case paragraph
            case heading(level: Int)
            case code(language: String?)
            case thematicBreak
            case table(columns: Int)
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
        /// Populated only for `.table`.
        var rows: [TableRow] = []
    }

    let blocks: [Block]
    var images: [String: URL] = [:]

    init(source: String, baseURL: URL?, images: [String: URL] = [:]) throws {
        self.images = images
        let placeholders = MarkdownImagePlaceholders(source)
        let imageReferences = Dictionary(uniqueKeysWithValues: placeholders.references.map { ($0.token, $0) })
        let parsed = try AttributedString(
            markdown: placeholders.source,
            options: .init(interpretedSyntax: .full),
            baseURL: baseURL
        )

        var blocks: [Block] = []
        var table: TableAccumulator?

        for run in parsed.runs {
            let intent = run.presentationIntent
            var content = placeholders.restoringImages(in: AttributedString(parsed[run.range]), referencesByToken: imageReferences)
            content.presentationIntent = nil

            // Table cells carry only table/tableRow/tableCell components —
            // no paragraph, header, or code leaf — so the block descriptor
            // below cannot identify them and every cell in the document
            // would land in one block.
            if let cell = Self.tableCell(for: intent) {
                if table?.id != cell.tableID {
                    if let finished = table { blocks.append(finished.block) }
                    table = TableAccumulator(id: cell.tableID, columns: cell.columnCount)
                }
                table?.append(content, cell: cell)
                continue
            }
            if let finished = table {
                blocks.append(finished.block)
                table = nil
            }

            let descriptor = Self.descriptor(for: intent)
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
        if let finished = table { blocks.append(finished.block) }
        self.blocks = blocks
    }

    /// Where one run sits inside a table.
    private struct TableCellPosition {
        var tableID: Int
        var columnCount: Int
        /// Zero-based row index reported by Foundation (`tableHeaderRow` is
        /// row 0; `tableRow(n)` preserves gaps for entirely empty rows).
        var rowIndex: Int
        var isHeader: Bool
        /// Zero-based column index reported by Foundation's tableCell intent.
        var columnIndex: Int
    }

    /// Collects the runs of one table. Foundation omits presentation runs for
    /// empty cells, so arrival order is not a column position. Runs are placed
    /// by the tableCell column index; multiple styled runs at that same index
    /// append into one cell.
    private struct TableAccumulator {
        private struct Row {
            let isHeader: Bool
            var cellsByColumn: [Int: AttributedString] = [:]
        }

        let id: Int
        let columns: Int
        private var rowsByIndex: [Int: Row] = [:]

        init(id: Int, columns: Int) {
            self.id = id
            self.columns = columns
        }

        mutating func append(_ content: AttributedString, cell: TableCellPosition) {
            var row = rowsByIndex[cell.rowIndex] ?? Row(isHeader: cell.isHeader)
            if row.cellsByColumn[cell.columnIndex] != nil {
                row.cellsByColumn[cell.columnIndex]?.append(content)
            } else {
                row.cellsByColumn[cell.columnIndex] = content
            }
            rowsByIndex[cell.rowIndex] = row
        }

        var block: Block {
            let highestObservedColumn = rowsByIndex.values
                .compactMap { $0.cellsByColumn.keys.max() }
                .max()
                .map { $0 + 1 } ?? 0
            let width = max(columns, highestObservedColumn)
            let highestObservedRow = rowsByIndex.keys.max() ?? -1
            let rowIndices = highestObservedRow >= 0 ? Array(0...highestObservedRow) : []
            let positioned = rowIndices.map { rowIndex in
                let row = rowsByIndex[rowIndex]
                return TableRow(
                    id: rowIndex,
                    isHeader: row?.isHeader ?? (rowIndex == 0),
                    cells: (0..<width).map {
                        row?.cellsByColumn[$0] ?? AttributedString()
                    }
                )
            }
            return Block(
                id: id,
                kind: .table(columns: width),
                listStyle: nil,
                listOrdinal: nil,
                listDepth: 0,
                quoteDepth: 0,
                content: AttributedString(),
                rows: positioned
            )
        }
    }

    private static func tableCell(for intent: PresentationIntent?) -> TableCellPosition? {
        guard let intent else { return nil }
        var position: TableCellPosition?
        var columnIndex: Int?

        for component in intent.components {
            switch component.kind {
            case .tableCell(let index):
                if columnIndex == nil { columnIndex = index }
            case .tableHeaderRow:
                if position == nil, let columnIndex {
                    position = TableCellPosition(
                        tableID: 0, columnCount: 0,
                        rowIndex: 0, isHeader: true, columnIndex: columnIndex
                    )
                }
            case .tableRow(let index):
                if position == nil, let columnIndex {
                    position = TableCellPosition(
                        tableID: 0, columnCount: 0,
                        rowIndex: index, isHeader: false, columnIndex: columnIndex
                    )
                }
            case .table(let columns):
                guard position != nil else { return nil }
                position?.tableID = component.identity
                position?.columnCount = columns.count
                return position
            default:
                continue
            }
        }
        return nil
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
        // Any intent we do not model still gets its own identity, so an
        // unrecognised block can never merge its text into its neighbour.
        descriptor.id = intent.components.first?.identity ?? 0

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

/// DEBUG seams for the Markdown scroll bisect. Each pins one suspected
/// per-block cost off, so a run can attribute the frame drops.
enum MarkdownRenderSeams {
    #if DEBUG
    static let textSelectionDisabled =
        ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_TEXT_SELECTION"] == "0"
    static let codeScrollDisabled =
        ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_CODE_SCROLL"] == "0"
    static let fixedSizeDisabled =
        ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_FIXED_SIZE"] == "0"
    static let usesList =
        ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_LIST"] == "1"
    /// Replaces every block with a trivial one-line view. The container,
    /// the document, and the realization cadence stay identical, so what
    /// remains of the per-block cost belongs to the container, not to us.
    static let stubBlocks =
        ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_STUB"] == "1"
    /// Drops the two things that wrap the document and re-measure whenever
    /// its content size changes: the navigation chrome, and the diagnostics
    /// probe stretched across the whole scroll content.
    static let lean =
        ProcessInfo.processInfo.environment["TESSERA_MARKDOWN_LEAN"] == "1"
    #else
    static let textSelectionDisabled = false
    static let codeScrollDisabled = false
    static let fixedSizeDisabled = false
    static let usesList = false
    static let stubBlocks = false
    static let lean = false
    #endif
}

private struct MarkdownPreview: View {
    private enum LoadState {
        case loading
        case loaded(MarkdownDocument)
        case failed(String)
    }

    let prepareImages: (@MainActor () async throws -> Void)?
    let fileURL: URL
    let displayTitle: String?
    let mode: QuickLookPresentationMode
    let onToggleMode: () -> Void
    let onDone: () -> Void

    @State private var loadState: LoadState = .loading
    @State private var shareVisible = false

    private var title: String {
        displayTitle ?? fileURL.lastPathComponent
    }

    var body: some View {
        if MarkdownRenderSeams.lean {
            content.task(id: fileURL) { await load() }
        } else {
            chrome
        }
    }

    private var chrome: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onToggleMode) {
                            Image(systemName: mode.toggleSymbolName)
                        }
                        .accessibilityLabel(mode.toggleLabel)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            shareVisible = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share \(title)")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        // Anchored over the trailing bar buttons from outside the stack:
        // toolbar items and the stack's content are rebuilt as the share
        // state and the document load change, and a popover left on a
        // rebuilt view points at nothing.
        .overlay(alignment: .topTrailing) {
            Color.clear
                .frame(width: 88, height: 44)
                .allowsHitTesting(false)
                .systemShareSheet(isPresented: $shareVisible) { [fileURL] }
        }
        .task(id: fileURL) { await load() }
    }

    private func load() async {
        do {
            var document: MarkdownDocument
            if let cached = MarkdownDocumentCache.document(for: fileURL) {
                document = cached
            } else {
                document = try await Task.detached(priority: .userInitiated) {
                    try MarkdownPreviewSupport.loadDocument(from: fileURL)
                }.value
            }
            try Task.checkCancellation()
            loadState = .loaded(document)
            MarkdownDocumentCache.store(document, for: fileURL)
            // Text is already readable. SwiftUI cancels this task when the
            // preview closes; a size toggle reuses the completed private cache.
            if let prepareImages {
                try? await prepareImages()
                try Task.checkCancellation()
                document.images = MarkdownImageStaging.images(for: fileURL)
                loadState = .loaded(document)
                MarkdownDocumentCache.store(document, for: fileURL)
            }
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
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
            let _ = FilesUIDiagnostics.shared.noteMarkdown(blockCount: document.blocks.count)
            if MarkdownRenderSeams.usesList {
                listBody(document)
            } else {
                stackBody(document)
            }
        }
    }

    private func stackBody(_ document: MarkdownDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(document.blocks) { block in
                    MarkdownBlockView(block: block, images: document.images)
                }
            }
            .modifier(MarkdownScrollProbeAttachment())
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Color(uiColor: .systemBackground))
        .modifier(MarkdownTextSelection())
    }

    /// `List` is backed by a reusing collection view, so realizing a block
    /// re-lays out that block instead of every block already on screen.
    private func listBody(_ document: MarkdownDocument) -> some View {
        List(document.blocks) { block in
            MarkdownBlockView(block: block, images: document.images)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(FilesScrollProbe(surface: .markdownPreview))
        .background(Color(uiColor: .systemBackground))
        .modifier(MarkdownTextSelection())
    }
}

/// The probe only needs to sit inside the scroll view to find it. Stretched
/// across the content as a background it is resized on every realization,
/// which is exactly the work being measured — so it rides in a corner at
/// zero size instead.
private struct MarkdownScrollProbeAttachment: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if MarkdownRenderSeams.lean {
            content.overlay(alignment: .topLeading) {
                FilesScrollProbe(surface: .markdownPreview)
                    .frame(width: 1, height: 1)
            }
        } else {
            content.background(FilesScrollProbe(surface: .markdownPreview))
        }
    }
}

private struct MarkdownTextSelection: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if MarkdownRenderSeams.textSelectionDisabled {
            content
        } else {
            content.textSelection(.enabled)
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block
    let images: [String: URL]

    /// The frame sampler charges a slow frame to the shapes it realized, so
    /// the block has to say which shape it is.
    private var diagnosticKind: FilesUIDiagnostics.MarkdownBlockKind {
        switch block.kind {
        case .paragraph: return .paragraph
        case .heading: return .heading
        case .code: return .code
        case .table: return .table
        case .thematicBreak: return .rule
        }
    }

    var body: some View {
        FilesUIDiagnostics.shared.measureBlockBody(kind: diagnosticKind) {
            blockContent
        }
    }

    @ViewBuilder
    private var blockContent: some View {
        if MarkdownRenderSeams.stubBlocks {
            Text(verbatim: "block")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            realContent
        }
    }

    private var realContent: some View {
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
        case .table(let columns):
            table(columns: columns)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        case .code:
            if MarkdownRenderSeams.codeScrollDisabled {
                Text(block.content)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView(.horizontal) {
                    Text(block.content)
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                }
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
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

    /// Tables scroll horizontally rather than wrap: a register with six
    /// columns is unreadable once the columns are squeezed into the sheet's
    /// width, and the code-block path already established the pattern.
    private func table(columns _: Int) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 7) {
                ForEach(block.rows) { row in
                    GridRow {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            MarkdownInlineView(content: cell, images: images)
                                .frame(maxWidth: cell.runs.contains(where: { $0.imageURL != nil }) ? 320 : nil, alignment: .leading)
                                .font(row.isHeader ? .body.weight(.semibold) : .body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if row.isHeader {
                        // A view outside a GridRow spans the whole grid.
                        Divider()
                    }
                }
            }
            .padding(.vertical, 2)
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
                wrappingText(block.content)
            }
            .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 20)
        } else {
            wrappingText(block.content)
        }
    }

    @ViewBuilder
    private func wrappingText(_ content: AttributedString) -> some View {
        if MarkdownRenderSeams.fixedSizeDisabled {
            MarkdownInlineView(content: content, images: images)
        } else {
            MarkdownInlineView(content: content, images: images)
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
    let mode: QuickLookPresentationMode
    let onToggleMode: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            fileURL: fileURL,
            displayTitle: displayTitle,
            onToggleMode: onToggleMode,
            onDismiss: onDismiss
        )
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let previewController = QLPreviewController()
        FilesUIDiagnostics.shared.timeline("quicklook-present")
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        // QuickLook draws its own chrome, so the size toggle rides the nav bar
        // opposite Done — the same spot the Markdown path uses.
        previewController.navigationItem.leftBarButtonItem = context.coordinator.toggleItem(mode: mode)
        previewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.dismissPreview)
        )

        let navigationController = UINavigationController(rootViewController: previewController)
        // QuickLook owns its scroll view (a web view, PDF view, or image
        // scroller depending on the file), so the probe rides the nav root —
        // recognizers fire along the hit-test chain, so any pan inside the
        // preview still reports.
        FilesUIDiagnostics.shared.attachProbe(to: navigationController.view, surface: .quickLook)
        return navigationController
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        // Runs on every SwiftUI update of everything around the sheet. A high
        // count during a preview scroll means the session behind it is still
        // redrawing into the same main thread QuickLook needs.
        FilesUIDiagnostics.shared.quickLookUpdate()
        FilesUIDiagnostics.shared.attachProbe(to: controller.view, surface: .quickLook)
        let itemChanged = context.coordinator.update(fileURL: fileURL, displayTitle: displayTitle)
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onToggleMode = onToggleMode
        guard let previewController = controller.viewControllers.first as? QLPreviewController else {
            return
        }
        let toggle = context.coordinator.toggleItem(mode: mode)
        if previewController.navigationItem.leftBarButtonItem !== toggle {
            previewController.navigationItem.leftBarButtonItem = toggle
        }
        // Only reload for a genuinely new file. SwiftUI re-runs this on every
        // surrounding update — the session redraws constantly — and each
        // reloadData() restarts QuickLook's async render, which left the
        // preview permanently blank.
        if itemChanged {
            previewController.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private var item: PreviewItem
        private var existingToggleItem: UIBarButtonItem?
        var onToggleMode: () -> Void
        var onDismiss: () -> Void
        private var hasDismissed = false

        init(
            fileURL: URL,
            displayTitle: String?,
            onToggleMode: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.item = PreviewItem(url: fileURL, title: displayTitle)
            self.onToggleMode = onToggleMode
            self.onDismiss = onDismiss
        }

        /// The bar item is created once and only restyled afterwards. Handing
        /// the navigation item a *new* UIBarButtonItem on every SwiftUI update
        /// cancels whatever touch is being tracked on the old one, which
        /// silently swallowed taps while the panel re-rendered.
        func toggleItem(mode: QuickLookPresentationMode) -> UIBarButtonItem {
            let item = existingToggleItem ?? UIBarButtonItem(
                image: nil,
                style: .plain,
                target: self,
                action: #selector(togglePresentationMode)
            )
            item.image = UIImage(systemName: mode.toggleSymbolName)
            item.accessibilityLabel = mode.toggleLabel
            existingToggleItem = item
            return item
        }

        @objc func togglePresentationMode() {
            onToggleMode()
        }

        /// Returns true when the previewed file actually changed, so callers
        /// can reload QuickLook only then.
        @discardableResult
        func update(fileURL: URL, displayTitle: String?) -> Bool {
            guard item.url != fileURL || item.title != displayTitle else { return false }
            item = PreviewItem(url: fileURL, title: displayTitle)
            return true
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

#if DEBUG
/// Host-free fixture that exercises the same download/staging/renderer path.
@MainActor
enum MarkdownImagePreviewFixture {
    static let source = """
    # Local images

    Relative path:

    ![Relative image][plot]

    Absolute path:

    [![Absolute image](/opt/red.png)](https://example.com/details)

    | In a table |
    | --- |
    | ![Table image](<images/my plot.png>) |

    ![Missing image](missing.png)

    [plot]: ../images/blue%20plot.png
    """

    static func image(color: UIColor, label: String) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 300, height: 48)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 48))
            (label as NSString).draw(at: CGPoint(x: 14, y: 12), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.white,
            ])
        }
    }

    static func stage() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("images.md")
        try source.write(to: document, atomically: true, encoding: .utf8)
        let bridge = MockFileBridge()
        bridge.downloadContents = [
            "/docs/../images/blue plot.png": image(color: .systemBlue, label: "RELATIVE IMAGE"),
            "/opt/red.png": image(color: .systemRed, label: "ABSOLUTE IMAGE"),
            "/docs/images/my plot.png": image(color: .systemGreen, label: "TABLE IMAGE"),
        ]
        try await bridge.connect()
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        precondition(MarkdownImageStaging.images(for: document).count == 3)
        return document
    }
}
#endif
