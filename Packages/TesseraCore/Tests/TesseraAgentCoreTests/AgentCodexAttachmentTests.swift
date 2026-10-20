import XCTest
@testable import TesseraAgentCore

final class AgentCodexAttachmentTests: XCTestCase {
    private func quoted(_ path: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try! encoder.encode(path), as: UTF8.self)
    }
    private func paste(_ value: String) -> String { "\u{1b}[200~" + value + "\u{1b}[201~" }

    func testImagesHaveIndependentPasteEventsAndProseKeepsItsExactBytes() throws {
        let first = "/tmp/a 'quoted' screenshot.png"
        let second = "/tmp/écran \\ $b.JPG"
        let text = "Compare these\n" + quoted(first) + "\n" + quoted(second) + "\nThanks"
        let plan = try XCTUnwrap(AgentTextInsertion.codexImages(provider: "codex", text: text))
        XCTAssertEqual(plan.paths, [first, second])
        XCTAssertEqual(plan.submittedText, "Compare these\n[Image #1] \n[Image #2] \nThanks")
        let actual = try XCTUnwrap(AgentTextInsertion.bytes(provider: "codex", text: text, bracketedPasteEnabled: false))
        let expected = paste("Compare these\n") + paste("'/tmp/a '\\''quoted'\\'' screenshot.png'") + paste("\n") + paste("'/tmp/écran \\ $b.JPG'") + paste("\n") + paste("Thanks")
        XCTAssertEqual(String(decoding: actual, as: UTF8.self), expected)
        XCTAssertEqual(AgentTextInsertion.bytes(provider: "codex", text: text, bracketedPasteEnabled: true), actual)
    }

    func testNonImagesAndOtherProvidersRetainTheirExistingInsertion() throws {
        for text in ["Describe \"/tmp/a.png\"", quoted("/tmp/a.pdf"), quoted("/tmp/a.heic"), quoted("relative.png"), "\"/tmp/a.png", "'/tmp/a.png'", "prose\nnot a path.png"] {
            XCTAssertNil(AgentTextInsertion.codexImages(provider: "codex", text: text))
            XCTAssertEqual(AgentTextInsertion.bytes(provider: "codex", text: text, bracketedPasteEnabled: false), Data(paste(text).utf8))
        }
        XCTAssertNil(AgentTextInsertion.codexImages(provider: "claude", text: quoted("/tmp/a.png")))
        XCTAssertEqual(AgentTextInsertion.bytes(provider: "claude", text: quoted("/tmp/a.png"), bracketedPasteEnabled: false), Data(paste(quoted("/tmp/a.png")).utf8))
    }

    func testWindowsImagePasteUsesActualBackslashesAfterJSONDecoding() throws {
        for path in [#"C:\Users\Alice\a screenshot.png"#, #"\\server\share\shot.png"#] {
            let bytes = try XCTUnwrap(AgentTextInsertion.bytes(provider: "codex", text: quoted(path), bracketedPasteEnabled: false))
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), paste("\"" + path + "\""))
        }
    }

    func testLongProseStaysExpandedAndOverlongImagePasteFailsClosed() throws {
        let prose = String(repeating: "é", count: 1_200)
        let bytes = try XCTUnwrap(AgentTextInsertion.bytes(provider: "codex", text: prose + "\n" + quoted("/tmp/a.png"), bracketedPasteEnabled: false))
        let events = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{1b}[200~").dropFirst().map { String($0.dropLast(6)) }
        XCTAssertEqual(events.dropLast().joined(), prose + "\n")
        XCTAssertTrue(events.dropLast().allSatisfy { $0.count <= 256 })
        XCTAssertEqual(events.last, "'/tmp/a.png'")
        XCTAssertNil(AgentTextInsertion.bytes(provider: "codex", text: quoted("/tmp/" + String(repeating: "a", count: 1_000) + ".png"), bracketedPasteEnabled: false))
    }

    func testAttachmentGuardRequiresCompleteTransformedDraft() {
        let text = "Inspect /tmp/a.png and call it [Image #1]\n" + quoted("/tmp/a.png")
        func assess(_ rows: [String]) -> AgentComposerEvidence.Safety {
            AgentComposerEvidence.safety(provider: "codex", visibleText: rows.joined(separator: "\n") + "\n\ngpt-5.4 default · /tmp",
                cursorRow: rows.count - 1, cursorVisible: true, requireEmpty: false, queueWhenWorking: true, text: text)
        }
        XCTAssertEqual(assess(["› Inspect /tmp/a.png and call it [Image #1]", "  [Image #1] "]), .readyTab)
        XCTAssertEqual(assess(["› [Image #1]"]), .unavailable)
        XCTAssertEqual(assess(["› Inspect /tmp/a.png and call it [Image #1]", "  \"/tmp/a.png\""]), .unavailable)
        XCTAssertEqual(assess(["› Inspect /tmp/a.png and call it [Image #1]", "  [Image #2]"]), .unavailable)
        XCTAssertEqual(assess(["› Inspect /tmp/a.png and call it [Image #1]", "  [Image #1] extra"]), .unavailable)
    }

    func testReceiptNeedsImageContentExactPathAndExactProse() {
        let text = "Describe\n" + quoted("/tmp/a.png")
        let blocks: [AgentBlock] = [.text("<image name=[Image #1] path=\"/tmp/a.png\">"), .attachment(name: "Image", mediaType: "image"), .text("</image>"), .text("Describe\n[Image #1]")]
        XCTAssertTrue(AgentTextInsertion.matchesReceipt(provider: "codex", text: text, blocks: blocks))
        var oldProjector = blocks; oldProjector[1] = .unknown(type: "input_image")
        XCTAssertFalse(AgentTextInsertion.matchesReceipt(provider: "codex", text: text, blocks: oldProjector))
        for replacement in [AgentBlock.text("image content omitted because it could not be processed"), .unknown(type: "input_text")] {
            var wrong = blocks; wrong[1] = replacement
            XCTAssertFalse(AgentTextInsertion.matchesReceipt(provider: "codex", text: text, blocks: wrong))
        }
        XCTAssertFalse(AgentTextInsertion.matchesReceipt(provider: "codex", text: text, blocks: [.text("Describe\n[Image #1]")]))
        XCTAssertFalse(AgentTextInsertion.matchesReceipt(provider: "codex", text: text.replacingOccurrences(of: "a.png", with: "b.png"), blocks: blocks))
        XCTAssertFalse(AgentTextInsertion.matchesReceipt(provider: "codex", text: text.replacingOccurrences(of: "Describe", with: "Different"), blocks: blocks))
    }

    func testCanonicalImageReceiptSettlesOutgoingAcrossAppend() async throws {
        let core = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "image-receipt")!
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1, incarnation: AgentIncarnationToken("image")!,
            transport: .sshTmux, tmuxSession: "test", windowID: "@1", paneID: "%1", agentPID: 42, capabilities: [.observe, .send, .tmux])
        await core.register(.init(id: id, providerName: "Codex", availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: binding)
        let boundary = AgentProjectionPage(sourceIdentity: "codex-images1:1:2:0:1", records: [], cursor: nil, hasMore: false, summary: .object(["receiptByteOffset": .string("0")]))!
        _ = await core.apply(page: boundary, to: id)
        let text = "Describe\n" + quoted("/tmp/a.png")
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding,
            textRequest: AgentTextSendRequest(threadID: id, binding: binding, text: text, queueWhenWorking: false)!)
        try await core.armOutgoing(lease, freshPage: boundary)
        try await core.markOutgoingDispatched(lease)
        await core.releaseLease(lease, result: .verified)
        let blocks: [AgentJSONValue] = [
            .object(["type": .string("text"), "text": .string("<image name=[Image #1] path=\"/tmp/a.png\">")]),
            .object(["type": .string("attachment"), "name": .string("Image"), "mediaType": .string("image")]),
            .object(["type": .string("text"), "text": .string("</image>")]),
            .object(["type": .string("text"), "text": .string("Describe\n[Image #1]")])
        ]
        let record = AgentProjectionRecord(sequence: 0, recordID: "image", record: .object(["type": .string("message"), "provider": .string("codex"), "role": .string("user"), "blocks": .array(blocks)]), sourceOffset: 0, sourceHash: String(repeating: "a", count: 64))!
        _ = await core.apply(page: AgentProjectionPage(sourceIdentity: "codex-images1:1:2:1000:2", records: [record], cursor: nil, hasMore: false)!, to: id)
        let snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.outgoingMessages?.count, 0)
        XCTAssertEqual(snapshot?.messages.count, 1)
    }
}
