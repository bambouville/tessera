import XCTest
@testable import TesseraAgentCore

final class AgentMarkdownTests: XCTestCase {
    func testPlainTextPreservesLiteralPunctuation() {
        let source = "a -- b --- 'c' \"d\""
        XCTAssertEqual(allText(in: AgentMarkdownDocument.parse(source).blocks).joined(), source)
        let command = "npm run migrate:tokens -- --dry-run"
        XCTAssertEqual(allText(in: AgentMarkdownDocument.parse(command).blocks).joined(), command)
    }

    func testImageReferencePassPreservesLiteralPunctuation() {
        let literal = "a -- b --- 'c' \"d\""
        let value = MarkdownImagePlaceholders("\(literal) ![\(literal)][image]\n\n[image]: /tmp/a--b.png")
        XCTAssertEqual(value.references.map(\.alt), [literal])
        XCTAssertEqual(value.references.map(\.destination), ["/tmp/a--b.png"])
        XCTAssertEqual(value.source, "\(literal) \(value.references[0].token)\n\n[image]: /tmp/a--b.png")
    }

    func testHeadingsAndNestedInlineFormatting() {
        let document = AgentMarkdownDocument.parse("# Title\n\n*outer **inner** text*")
        XCTAssertEqual(document.blocks.first?.kind, .heading)
        XCTAssertEqual(document.blocks.first?.level, 1)
        let emphasis = document.blocks.dropFirst().first?.children.first
        XCTAssertEqual(emphasis?.kind, .emphasis)
        XCTAssertTrue(emphasis?.children.contains(where: { $0.kind == .strong }) == true)
    }

    func testOrderedUnorderedAndTaskListsPreserveStructure() {
        let document = AgentMarkdownDocument.parse("3. third\n   - [x] done\n   - [ ] later")
        guard let ordered = document.blocks.first else {
            return XCTFail("missing ordered list")
        }
        XCTAssertEqual(ordered.kind, .orderedList)
        XCTAssertEqual(ordered.start, 3)
        let item = ordered.children.first
        XCTAssertEqual(item?.kind, .listItem)
        let nested = item?.children.first(where: { $0.kind == .unorderedList })
        XCTAssertEqual(nested?.children.map(\.checked), [true, false])
    }

    func testQuotesTablesAndEscapedPipes() {
        let document = AgentMarkdownDocument.parse("> quoted\n\n| Name | Value |\n| :--- | ---: |\n| a\\|b | 2 |")
        XCTAssertEqual(document.blocks.first?.kind, .quote)
        let table = document.blocks.first(where: { $0.kind == .table })
        XCTAssertEqual(table?.children.count, 2)
        let header = table?.children.first
        XCTAssertEqual(header?.children.map(\.level), [1, 1])
        XCTAssertEqual(header?.children.map(\.alignment), ["left", "right"])
        XCTAssertEqual(table?.children.last?.children.first?.children.first?.text, "a|b")
    }

    func testFencedAndUnclosedCodeRemainLiteral() {
        let fenced = AgentMarkdownDocument.parse("```swift\nlet value = **not bold**\n```")
        XCTAssertEqual(fenced.blocks, [.init(kind: .codeBlock, text: "let value = **not bold**", language: "swift")])

        let unclosed = AgentMarkdownDocument.parse("```sh\necho `still code`\n")
        XCTAssertEqual(unclosed.blocks.first?.kind, .codeBlock)
        XCTAssertEqual(unclosed.blocks.first?.text, "echo `still code`")
        XCTAssertEqual(unclosed.blocks.first?.language, "sh")
    }

    func testInlineCodeAndEscapesAreLiteral() {
        let document = AgentMarkdownDocument.parse("Use `a * b` and \\*escaped\\*.")
        let children = document.blocks.first?.children ?? []
        XCTAssertTrue(children.contains(where: { $0.kind == .inlineCode && $0.text == "a * b" }))
        XCTAssertTrue(children.contains(where: { $0.kind == .text && $0.text?.contains("*escaped*") == true }))
    }

    func testLinksAreAllowlistedAndImagesHaveOnlyAltText() {
        let document = AgentMarkdownDocument.parse("[safe](https://example.com) [bad](javascript:alert(1)) ![diagram](https://example.com/image.png)")
        let children = document.blocks.first?.children ?? []
        let links = children.filter { $0.kind == .link }
        XCTAssertEqual(links.map(\.destination), ["https://example.com", nil])
        guard let image = children.first(where: { $0.kind == .image }) else {
            return XCTFail("missing image placeholder")
        }
        XCTAssertNil(image.destination)
        XCTAssertEqual(image.children.first?.text, "diagram")
    }

    func testRawHTMLIsLiteralText() {
        let document = AgentMarkdownDocument.parse("<script>alert('x')</script>\n\nhello <b>world</b>")
        let rendered = allText(in: document.blocks).joined()
        XCTAssertTrue(rendered.contains("<script>alert('x')</script>"))
        XCTAssertTrue(rendered.contains("<b>"))
        XCTAssertFalse(document.blocks.contains(where: { $0.kind == .image }))
    }

    func testHugeAndDeepInputsAreBoundedAndReadable() {
        let huge = AgentMarkdownDocument.parse(String(repeating: "x", count: 140_000))
        XCTAssertTrue(huge.truncated)
        XCTAssertFalse(huge.blocks.isEmpty)

        let deep = AgentMarkdownDocument.parse((0..<40).map { String(repeating: "  ", count: $0) + "- depth \($0)" }.joined(separator: "\n"))
        XCTAssertTrue(deep.truncated)
        XCTAssertFalse(deep.blocks.isEmpty)
    }

    func testLocalImagesPreserveReferenceDestinationsAndRemainInert() {
        let document = AgentMarkdownDocument.parse("![relative][plot] ![](/opt/a.png) ![web](https://example.com/a.png)\n\n[plot]: ../images/a%20b.png")
        let images = document.blocks.flatMap(\.children).filter { $0.kind == .image }
        XCTAssertEqual(images.map(\.destination), ["../images/a%20b.png", "/opt/a.png", nil])
        XCTAssertEqual(MarkdownLocalImage.remotePath("../images/a%20b.png", documentPath: "/docs/readme.md"), "/docs/../images/a b.png")
        XCTAssertEqual(MarkdownLocalImage.remotePath("/opt/a.png", documentPath: "/docs/readme.md"), "/opt/a.png")
        XCTAssertEqual(MarkdownLocalImage.remotePath("file:///opt/a%2520b.png", documentPath: "/readme.md"), "/opt/a%20b.png")
        XCTAssertEqual(MarkdownLocalImage.remotePath("images/plot[1].png", documentPath: "/docs/readme.md"), "/docs/images/plot[1].png")
        XCTAssertEqual(MarkdownLocalImage.remotePath("images/100%.png", documentPath: "/docs/readme.md"), "/docs/images/100%.png")
        XCTAssertEqual(MarkdownLocalImage.remotePath("图.png", documentPath: "/readme.md"), "/图.png")
        for destination in ["https://example.com/a", "//example.com/a", "file://host/a", "data:image/png;base64,AA", "a%00.png", "a%0A.png", "", "#fragment"] {
            XCTAssertNil(MarkdownLocalImage.remotePath(destination, documentPath: "/docs/readme.md"), destination)
        }
    }

    func testImagePlaceholdersUseParserRangesAndPreserveSurroundingMarkup() {
        let source = "前 [![linked](a(b).png)](https://example.com) ![ref][x]\n\n`![literal](code.png)`\n\n[x]: /opt/p.png"
        let value = MarkdownImagePlaceholders(source)
        XCTAssertEqual(value.references.map(\.destination), ["a(b).png", "/opt/p.png"])
        XCTAssertEqual(value.references.map(\.alt), ["linked", "ref"])
        XCTAssertEqual(value.source, "前 [\(value.references[0].token)](https://example.com) \(value.references[1].token)\n\n`![literal](code.png)`\n\n[x]: /opt/p.png")
    }

    func testImagePlaceholderRangesHandleCRAndCRLF() {
        for newline in ["\r", "\r\n", "\n"] {
            let value = MarkdownImagePlaceholders("heading\(newline)\(newline)![image](path.png)")
            XCTAssertEqual(value.references.map(\.destination), ["path.png"])
            XCTAssertEqual(value.source, "heading\(newline)\(newline)\(value.references[0].token)")
        }
    }

    private func allText(in nodes: [AgentMarkdownNode]) -> [String] {
        nodes.flatMap { node in
            (node.text.map { [$0] } ?? []) + allText(in: node.children)
        }
    }
}
