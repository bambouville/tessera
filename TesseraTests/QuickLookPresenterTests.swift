import Foundation
import Testing
@testable import Tessera

struct QuickLookPresenterTests {
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
