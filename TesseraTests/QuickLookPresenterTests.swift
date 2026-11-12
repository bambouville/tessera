import Foundation
import Observation
import Testing
import UIKit
@testable import Tessera

struct QuickLookPresenterTests {
    @Test @MainActor func artifactMarkdownTaskIdentityIncludesImagesWithoutChangingDocumentIdentity() async throws {
        let url = URL(fileURLWithPath: "/cache/readme.md")
        var preparations = 0
        let first = ArtifactDocumentView(localURL: url, title: "readme.md",
            prepareImages: ArtifactImagePreparation(generation: 4) { preparations += 1 }, reloadToken: 7)
        let retry = ArtifactDocumentView(localURL: url, title: "readme.md",
            prepareImages: ArtifactImagePreparation(generation: 5) { preparations += 1 }, reloadToken: 7)
        let initialIdentity = first.markdownPresenter.markdownTaskIdentity
        let retryIdentity = retry.markdownPresenter.markdownTaskIdentity
        #expect(first.reloadToken == retry.reloadToken)
        #expect(initialIdentity.fileURL == retryIdentity.fileURL)
        #expect(initialIdentity.imageGeneration == 4)
        #expect(retryIdentity.imageGeneration == 5)
        #expect(initialIdentity != retryIdentity)
        #expect(retryIdentity == retry.markdownPresenter.markdownTaskIdentity)
        #expect(QuickLookPresenter(fileURL: url).markdownTaskIdentity == MarkdownPreviewTaskIdentity(fileURL: url, imageGeneration: 0))
        let offline = ArtifactDocumentView(localURL: url, title: "readme.md", prepareImages: nil, reloadToken: 7)
        let firstLive = ArtifactDocumentView(localURL: url, title: "readme.md",
            prepareImages: ArtifactImagePreparation(generation: 0) {}, reloadToken: 7)
        #expect(offline.markdownPresenter.markdownTaskIdentity != firstLive.markdownPresenter.markdownTaskIdentity,
                "a document shown offline stages once its first live preparation arrives")
        let prepare = try #require(retry.markdownPresenter.prepareImages)
        try await prepare()
        #expect(preparations == 1, "the task's action travels with its generation")
    }

    @Test func imageParsingPreservesProseAndFindsReferencesInNestedBlocks() throws {
        let source = """
        Before ![a **bold** caption][picture] after.

        - ![list](/opt/list.png)

        | Preview |
        | --- |
        | ![table](../table.png) |

        `![code](ignored.png)`

        [picture]: ../images/a%20b.png
        """
        #expect(try MarkdownImageStaging.destinations(source: source) == ["../images/a%20b.png", "/opt/list.png", "../table.png"])
        let document = try MarkdownDocument(source: source, baseURL: URL(fileURLWithPath: "/staging/"))
        let parts = MarkdownInlinePart.split(try #require(document.blocks.first).content)
        #expect(parts.map(\.image) == [nil, "../images/a%20b.png", nil])
        #expect(String(parts[0].content.characters) == "Before ")
        #expect(String(parts[1].content.characters) == "a bold caption")
        #expect(String(parts[2].content.characters) == " after.")
    }

    @Test @MainActor func stagesRemoteImagesWithoutReadingDevicePathsAndSurvivesFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("readme.md")
        try "![one](../image%20one.png) ![two](/opt/two.png) ![again](../image%20one.png) ![missing](missing.png) ![invalid](bad.png) ![large](large.png)".write(to: document, atomically: true, encoding: .utf8)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let bridge = MockFileBridge()
        bridge.downloadContents = [
            "/docs/../image one.png": png, "/opt/two.png": png,
            "/docs/bad.png": Data("not an image".utf8),
            "/docs/large.png": Data(repeating: 0, count: Int(MarkdownImageStaging.maxImageBytes + 1)),
        ]
        try await bridge.connect()
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        let images = MarkdownImageStaging.images(for: document)
        #expect(Set(images.keys) == Set(["../image%20one.png", "/opt/two.png"]))
        #expect(bridge.downloadedPaths == ["/docs/../image one.png", "/opt/two.png", "/docs/missing.png", "/docs/bad.png", "/docs/large.png"])
        for image in images.values {
            #expect(image.deletingLastPathComponent().path == directory.path)
            #expect(UIImage(contentsOfFile: image.path) != nil)
        }
        #expect(try MarkdownPreviewSupport.loadDocument(from: document).images == images)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 4)
    }

    @Test @MainActor func explicitImageRefreshBypassesMatchingSizeAndMtimeButFollowerReuses() async throws {
        let directory = artifactTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("readme.md")
        try "![one](one.png) ![again](/docs/one.png)".write(to: document, atomically: true, encoding: .utf8)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        var first = renderer.pngData { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        var replacement = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let bytes = max(first.count, replacement.count)
        first.append(Data(repeating: 0, count: bytes - first.count))
        replacement.append(Data(repeating: 0, count: bytes - replacement.count))
        let bridge = ArtifactTestBridge()
        bridge.files["/docs/one.png"] = first
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        let original = MarkdownImageStaging.images(for: document)
        let thumbnail = try #require(original["one.png"])
        let oldBytes = try Data(contentsOf: thumbnail)
        let modified = bridge.modified
        bridge.downloads.removeAll()
        bridge.files["/docs/one.png"] = replacement

        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        #expect(bridge.downloads.isEmpty)
        #expect(MarkdownImageStaging.images(for: document) == original)
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge, force: true)
        let refreshed = MarkdownImageStaging.images(for: document)
        #expect(bridge.downloads == ["/docs/one.png"])
        let refreshedThumbnail = try #require(refreshed["one.png"])
        #expect(refreshed["/docs/one.png"] == refreshedThumbnail)
        #expect(try Data(contentsOf: refreshedThumbnail) != oldBytes)
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
        #expect(bridge.modified == modified)

        bridge.state = .idle
        do {
            try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge, force: true)
            Issue.record("offline staging must fail")
        } catch FileBridgeError.notConnected { }
        #expect(bridge.connectCalls == 0)
    }

    @Test @MainActor func failedForcedImageDownloadRetainsThumbnailAndManifestAndReportsIncomplete() async throws {
        let directory = artifactTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("readme.md")
        try "![one](one.png) ![alias](/docs/one.png)".write(to: document, atomically: true, encoding: .utf8)
        let bridge = ArtifactTestBridge()
        bridge.files["/docs/one.png"] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        let original = MarkdownImageStaging.images(for: document)
        let thumbnail = try #require(original["one.png"])
        let bytes = try Data(contentsOf: thumbnail)
        let manifest = MarkdownImageStaging.manifestURL(for: document)
        let originalObject = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
        let originalManifest = try #require(originalObject as? NSDictionary)
        bridge.downloads.removeAll()
        bridge.failAfterWrite = true

        let failed = try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge, force: true)
        #expect(!failed)
        #expect(bridge.downloads == ["/docs/one.png"], "aliases must share the retained entry after a failed attempt")
        #expect(MarkdownImageStaging.images(for: document) == original)
        #expect(try Data(contentsOf: thumbnail) == bytes)
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? NSDictionary) == originalManifest)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)

        bridge.failAfterWrite = false
        let succeeded = try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge, force: true)
        #expect(succeeded)
        #expect(bridge.downloads == ["/docs/one.png", "/docs/one.png"])
        let refreshed = try #require(MarkdownImageStaging.images(for: document)["one.png"])
        #expect(refreshed != thumbnail)
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
        bridge.downloads.removeAll()
        try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        #expect(bridge.downloads.isEmpty)

        bridge.modified = Date(timeIntervalSince1970: 2)
        bridge.failAfterWrite = true
        let unforced = try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
        #expect(!unforced, "a transient miss is reported, so a shown document can retry it")
        #expect(MarkdownImageStaging.images(for: document).isEmpty, "non-forced failure keeps its existing behavior")
        #expect(!FileManager.default.fileExists(atPath: refreshed.path))
        #expect(bridge.connectCalls == 0)
    }

    @Test @MainActor func forcedMissingOrOversizedImageDropsTheOldThumbnailAndCompletesTheRefresh() async throws {
        for missing in [true, false] {
            let directory = artifactTestDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let document = directory.appendingPathComponent("readme.md")
            try "![one](one.png)".write(to: document, atomically: true, encoding: .utf8)
            let bridge = ArtifactTestBridge()
            bridge.files["/docs/one.png"] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
            try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
            let thumbnail = try #require(MarkdownImageStaging.images(for: document)["one.png"])
            if missing { bridge.files["/docs/one.png"] = nil }
            else { bridge.progressBytes = MarkdownImageStaging.maxImageBytes + 1 }
            let completed = try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge, force: true)
            // A definitive answer must not keep the refresh pending, or every
            // later load would re-download the document and all its images.
            #expect(completed)
            #expect(MarkdownImageStaging.images(for: document).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
            #expect(bridge.connectCalls == 0)
        }
    }

    @Test @MainActor func definitiveImageErrorsDropTheOldThumbnailAndCompleteTheRefresh() async throws {
        let errors: [Error] = [
            FileBridgeError.remoteStatus(code: 2, message: "missing"),
            FileBridgeError.remoteStatus(code: 3, message: "permission denied"),
            FileBridgeError.remoteStatus(code: 8, message: "unsupported"),
            FileBridgeError.remoteStatus(code: 10, message: "no such path"),
            CocoaError(.fileReadNoPermission), CocoaError(.fileReadNoSuchFile),
            POSIXError(.EACCES), POSIXError(.EPERM), POSIXError(.ENOENT),
        ]
        for error in errors {
            let directory = artifactTestDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let document = directory.appendingPathComponent("readme.md")
            try "![one](one.png)".write(to: document, atomically: true, encoding: .utf8)
            let bridge = ArtifactImageFailureTestBridge()
            bridge.base.files["/docs/one.png"] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
            try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
            let thumbnail = try #require(MarkdownImageStaging.images(for: document)["one.png"])
            bridge.downloadAttempts.removeAll()
            bridge.downloadErrors["/docs/one.png"] = error
            let completed = try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge, force: true)
            #expect(completed)
            #expect(bridge.downloadAttempts == ["/docs/one.png"])
            #expect(MarkdownImageStaging.images(for: document).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
            #expect(bridge.base.connectCalls == 0)
        }
    }

    @Test @MainActor func transientImageErrorsKeepTheThumbnailAndLeaveTheRefreshPending() async throws {
        let errors: [Error] = [
            FileBridgeError.remoteStatus(code: 4, message: "failure"),
            FileBridgeError.remoteStatus(code: 1, message: "unexpected status"),
            FileBridgeError.network("interrupted"), FileBridgeError.notConnected,
            FileBridgeError.remoteOperationFailed("failure"),
            URLError(.networkConnectionLost), POSIXError(.ECONNRESET), CocoaError(.fileReadUnknown),
            NSError(domain: "test.image.failure", code: 1),
        ]
        for error in errors {
            let directory = artifactTestDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let document = directory.appendingPathComponent("readme.md")
            try "![one](one.png)".write(to: document, atomically: true, encoding: .utf8)
            let bridge = ArtifactImageFailureTestBridge()
            bridge.base.files["/docs/one.png"] = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
            try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge)
            let original = MarkdownImageStaging.images(for: document)
            let thumbnail = try #require(original["one.png"])
            bridge.downloadAttempts.removeAll()
            bridge.downloadErrors["/docs/one.png"] = error
            let completed = try await MarkdownImageStaging.stage(document: document, remotePath: "/docs/readme.md", bridge: bridge, force: true)
            #expect(!completed)
            #expect(bridge.downloadAttempts == ["/docs/one.png"])
            #expect(MarkdownImageStaging.images(for: document) == original)
            #expect(FileManager.default.fileExists(atPath: thumbnail.path))
            #expect(bridge.base.connectCalls == 0)
        }
    }

    @Test func linkedAndAdjacentImagesKeepDestinationsAndLinks() throws {
        let source = "[![linked](/opt/a.png)](https://example.com/details) ![one](same.png)![two](same.png)"
        let document = try MarkdownDocument(source: source, baseURL: nil)
        let parts = MarkdownInlinePart.split(try #require(document.blocks.first).content)
        let images = parts.filter { $0.image != nil }
        #expect(images.map(\.image) == ["/opt/a.png", "same.png", "same.png"])
        #expect(images.first?.content.runs.first?.link == URL(string: "https://example.com/details"))
        #expect(try MarkdownImageStaging.destinations(source: source) == ["/opt/a.png", "same.png"])
    }

    @Test func imagePlaceholdersPreserveAdjacentEmphasisAndCRLines() throws {
        let source = "_before_![one](one.png)_after_\r\r![two](two.png)"
        let document = try MarkdownDocument(source: source, baseURL: nil)
        #expect(try MarkdownImageStaging.destinations(source: source) == ["one.png", "two.png"])
        let first = try #require(document.blocks.first).content
        #expect(String(first.characters) == "beforeoneafter")
        #expect(first.runs.first?.inlinePresentationIntent?.contains(.emphasized) == true)
        #expect(first.runs.last?.inlinePresentationIntent?.contains(.emphasized) == true)
    }

    @Test func presentationModeTogglesBetweenPopupAndFullScreen() {
        #expect(QuickLookPresentationMode.fallback == .popup)
        #expect(QuickLookPresentationMode.popup.toggled == .fullScreen)
        #expect(QuickLookPresentationMode.fullScreen.toggled == .popup)
        #expect(QuickLookPresentationMode.popup.toggleSymbolName
            != QuickLookPresentationMode.fullScreen.toggleSymbolName)
        #expect(QuickLookPresentationMode.popup.toggleLabel == "Enter Full Screen")
        #expect(QuickLookPresentationMode.fullScreen.toggleLabel == "Exit Full Screen")
        // Persisted raw values are a stored preference — renaming a case would
        // silently reset every user's choice.
        #expect(QuickLookPresentationMode.allCases.map(\.rawValue) == ["popup", "fullScreen"])
    }

    @Test func onlyTheContainerMatchingTheModeShowsTheRequest() {
        let request = "preview"
        #expect(QuickLookPresentationRouting.presentedItem(
            request, mode: .popup, container: .popup) == request)
        #expect(QuickLookPresentationRouting.presentedItem(
            request, mode: .popup, container: .fullScreen) == nil)
        #expect(QuickLookPresentationRouting.presentedItem(
            request, mode: .fullScreen, container: .fullScreen) == request)
        #expect(QuickLookPresentationRouting.presentedItem(
            request, mode: .fullScreen, container: .popup) == nil)
    }

    @Test func resizingHandsTheRequestOverInsteadOfCancellingIt() {
        // The outgoing container writes nil as it tears down, after `mode`
        // already names the incoming one; that write must not clear the
        // pending preview or the toggle would dismiss the file.
        #expect(!QuickLookPresentationRouting.clearsRequest(mode: .fullScreen, container: .popup))
        #expect(!QuickLookPresentationRouting.clearsRequest(mode: .popup, container: .fullScreen))
        // A real dismissal comes from the container the mode points at.
        #expect(QuickLookPresentationRouting.clearsRequest(mode: .popup, container: .popup))
        #expect(QuickLookPresentationRouting.clearsRequest(mode: .fullScreen, container: .fullScreen))
    }

    @Test func markdownDetectionUsesTitleAndStagedFilename() {
        let opaqueStagingURL = URL(fileURLWithPath: "/tmp/preview/file")
        #expect(MarkdownPreviewSupport.isMarkdown(
            fileURL: opaqueStagingURL,
            displayTitle: "README.md"
        ))

        let namedStagingURL = URL(fileURLWithPath: "/tmp/preview/Notes.MARKDOWN")
        #expect(MarkdownPreviewSupport.isMarkdown(
            fileURL: namedStagingURL,
            displayTitle: nil
        ))

        #expect(MarkdownPreviewSupport.isMarkdown(
            fileURL: URL(fileURLWithPath: "/tmp/preview/design.qmd"),
            displayTitle: "design.qmd"
        ))

        #expect(!MarkdownPreviewSupport.isMarkdown(
            fileURL: URL(fileURLWithPath: "/tmp/preview/readme.txt"),
            displayTitle: "readme.txt"
        ))
    }

    @Test func markdownDocumentPreservesBlockStructureAndInlineContent() throws {
        let source = """
        # Heading

        A paragraph with **bold** and [a link](guide.md).

        1. First
        2. Second

        > Quoted text

        ```swift
        let answer = 42
        ```

        ---
        """
        let baseURL = URL(fileURLWithPath: "/tmp/docs", isDirectory: true)
        let document = try MarkdownDocument(source: source, baseURL: baseURL)

        #expect(document.blocks.map(\.kind) == [
            .heading(level: 1),
            .paragraph,
            .paragraph,
            .paragraph,
            .paragraph,
            .code(language: "swift"),
            .thematicBreak,
        ])
        #expect(String(document.blocks[0].content.characters) == "Heading")
        #expect(String(document.blocks[1].content.characters).contains("a link"))
        #expect(document.blocks[2].listStyle == .ordered)
        #expect(document.blocks[2].listOrdinal == 1)
        #expect(document.blocks[3].listOrdinal == 2)
        #expect(document.blocks[4].quoteDepth == 1)
        #expect(String(document.blocks[5].content.characters).contains("let answer = 42"))
    }

    /// Table cells carry no paragraph/header/code intent, so before tables
    /// were modelled every cell in a document collapsed into one block whose
    /// text ran together — and that one oversized `Text` then rendered blank.
    @Test func markdownDocumentKeepsTableCellsSeparate() throws {
        let source = """
        # Register

        | Case | Owner | Status |
        | --- | --- | --- |
        | EV-EMP-01 | inbox delivery | open |
        | EV-EQ-01 | resident-side | closed |

        Trailing paragraph.
        """
        let document = try MarkdownDocument(source: source, baseURL: nil)

        #expect(document.blocks.map(\.kind) == [
            .heading(level: 1),
            .table(columns: 3),
            .paragraph,
        ])

        let table = try #require(document.blocks.first { $0.kind == .table(columns: 3) })
        #expect(table.rows.count == 3)
        #expect(table.rows[0].isHeader)
        #expect(!table.rows[1].isHeader)
        #expect(table.rows.allSatisfy { $0.cells.count == 3 })
        #expect(table.rows[0].cells.map { String($0.characters) } == ["Case", "Owner", "Status"])
        #expect(table.rows[1].cells.map { String($0.characters) }
            == ["EV-EMP-01", "inbox delivery", "open"])
        #expect(table.rows[2].cells.map { String($0.characters) }
            == ["EV-EQ-01", "resident-side", "closed"])

        // The regression itself: no block may swallow the whole table.
        #expect(!document.blocks.contains {
            String($0.content.characters).contains("EV-EMP-01inbox delivery")
        })
        #expect(String(document.blocks[2].content.characters) == "Trailing paragraph.")
    }

    /// Two tables in one document must not merge, and inline emphasis inside
    /// a cell must stay in that cell.
    @Test func markdownDocumentSeparatesAdjacentTables() throws {
        let source = """
        | A |
        | --- |
        | **one** |

        Between.

        | B |
        | --- |
        | two |
        """
        let document = try MarkdownDocument(source: source, baseURL: nil)
        let tables = document.blocks.filter {
            if case .table = $0.kind { return true }
            return false
        }
        #expect(tables.count == 2)
        #expect(tables[0].rows.last?.cells.map { String($0.characters) } == ["one"])
        #expect(tables[1].rows.last?.cells.map { String($0.characters) } == ["two"])
    }

    @Test func markdownDocumentPositionsLeadingMiddleAndTrailingEmptyCells() throws {
        let source = """
        | A | B | C |
        | --- | --- | --- |
        | | middle | tail |
        | lead | | tail |
        | lead | middle | |
        """
        let document = try MarkdownDocument(source: source, baseURL: nil)
        let table = try #require(document.blocks.first { $0.kind == .table(columns: 3) })
        let values = table.rows.map { row in
            row.cells.map { String($0.characters) }
        }

        #expect(values == [
            ["A", "B", "C"],
            ["", "middle", "tail"],
            ["lead", "", "tail"],
            ["lead", "middle", ""],
        ])
    }

    @Test func markdownDocumentPreservesAnEntirelyEmptyRowByFoundationIndex() throws {
        let source = """
        | A | B | C |
        | --- | --- | --- |
        | | | |
        | lead | | tail |
        """
        let document = try MarkdownDocument(source: source, baseURL: nil)
        let table = try #require(document.blocks.first { $0.kind == .table(columns: 3) })
        let values = table.rows.map { row in
            row.cells.map { String($0.characters) }
        }

        #expect(values == [
            ["A", "B", "C"],
            ["", "", ""],
            ["lead", "", "tail"],
        ])
    }

    @Test func markdownDocumentAppendsStyledRunsWithinTheirFoundationColumn() throws {
        let source = """
        | A | B | C |
        | --- | --- | --- |
        | **bold** and `code` | | *end* |
        """
        let document = try MarkdownDocument(source: source, baseURL: nil)
        let table = try #require(document.blocks.first { $0.kind == .table(columns: 3) })
        let row = try #require(table.rows.last)

        #expect(row.cells.map { String($0.characters) } == ["bold and code", "", "end"])
        #expect(row.cells[0].runs.count > 1)
        #expect(row.cells[2].runs.count >= 1)
    }

    @Test func loadDocumentReadsTheDownloadedPreviewFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickLookPresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("README.md")
        try "## Downloaded\n\n- one\n- two\n".write(to: url, atomically: true, encoding: .utf8)

        let document = try MarkdownPreviewSupport.loadDocument(from: url)
        #expect(document.blocks.first?.kind == .heading(level: 2))
        #expect(document.blocks.filter { $0.listStyle == .unordered }.count == 2)
    }
}

@MainActor
@Observable
final class ArtifactImageFailureTestBridge: FileBridging {
    let base = ArtifactTestBridge()
    var downloadErrors: [String: Error] = [:]
    var downloadAttempts: [String] = []
    var key: FileBridgeKey { base.key }
    var state: FileBridgeState { base.state }
    var homeDirectory: String? { base.homeDirectory }
    var suppressIdleTeardown: Bool {
        get { base.suppressIdleTeardown }
        set { base.suppressIdleTeardown = newValue }
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] { try await base.listDirectory(path) }
    func attributes(_ path: String) async throws -> RemoteFileEntry { try await base.attributes(path) }
    func realPath(_ path: String) async throws -> String { try await base.realPath(path) }
    func createDirectory(_ path: String) async throws { try await base.createDirectory(path) }
    func setPermissions(_ permissions: UInt16, at path: String) async throws { try await base.setPermissions(permissions, at: path) }
    func rename(from oldPath: String, to newPath: String) async throws { try await base.rename(from: oldPath, to: newPath) }
    func removeFile(_ path: String) async throws { try await base.removeFile(path) }
    func removeDirectory(_ path: String) async throws { try await base.removeDirectory(path) }
    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {
        downloadAttempts.append(remotePath)
        if let error = downloadErrors[remotePath] { throw error }
        try await base.download(remotePath: remotePath, to: localURL, progress: progress)
    }
    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {
        try await base.upload(localURL: localURL, to: remotePath, progress: progress)
    }
    func exec(_ command: String, inShell: Bool) async throws -> String { try await base.exec(command, inShell: inShell) }
}
