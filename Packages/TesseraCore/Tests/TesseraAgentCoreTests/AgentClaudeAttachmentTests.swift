import XCTest
@testable import TesseraAgentCore

final class AgentClaudeAttachmentTests: XCTestCase {
    private func quoted(_ path: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try! encoder.encode(path), as: UTF8.self)
    }
    private func paste(_ value: String) -> String { "\u{1b}[200~" + value + "\u{1b}[201~" }
    private let footer = "\n──────────────────────────────\n⏵⏵ bypass permissions on · shift+tab to cycle"

    func testImagesKeepExactJSONQuotingAndIndependentPasteEvents() throws {
        let first = quoted("/tmp/a 'quoted' screenshot.png"), second = quoted("/tmp/écran \\ $b.JPG")
        for text in [first, "Reply with one word: ok\n" + first, first + "\n" + second + "\nReply with one word: ok"] {
            let bytes = try XCTUnwrap(AgentTextInsertion.bytes(provider: "claude", text: text, bracketedPasteEnabled: false))
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), text.components(separatedBy: "\n").enumerated().map { index, line in
                if line == first || line == second { return paste(line) + (index + 1 < text.components(separatedBy: "\n").count ? paste("\n") : "") }
                return paste(line + (index + 1 < text.components(separatedBy: "\n").count ? "\n" : ""))
            }.joined())
            XCTAssertEqual(AgentTextInsertion.bytes(provider: "claude", text: text, bracketedPasteEnabled: true), bytes)
        }
        // Preserve the draft's JSON escape spelling instead of re-encoding it.
        let escaped = #""\/tmp\/a.png""#
        XCTAssertEqual(AgentTextInsertion.bytes(provider: "claude", text: escaped, bracketedPasteEnabled: false), Data(paste(escaped).utf8))
    }

    func testLongProseAndSafetyLimitsRetainExistingPolicy() throws {
        let prose = String(repeating: "é", count: 1_200)
        let bytes = try XCTUnwrap(AgentTextInsertion.bytes(provider: "claude", text: prose + "\n" + quoted("/tmp/a.png"), bracketedPasteEnabled: false))
        let events = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{1b}[200~").dropFirst().map { String($0.dropLast(6)) }
        XCTAssertEqual(events.dropLast().joined(), prose + "\n")
        XCTAssertTrue(events.dropLast().allSatisfy { $0.utf8.count <= 259 })
        XCTAssertEqual(events.last, quoted("/tmp/a.png"))
        XCTAssertNil(AgentTextInsertion.bytes(provider: "claude", text: quoted("/tmp/" + String(repeating: "a", count: 1_000) + ".png"), bracketedPasteEnabled: false))
        for text in ["Describe \"/tmp/a.png\"", quoted("relative.png"), quoted("/tmp/a.pdf"), quoted("/tmp/a.heic"), quoted("/tmp/bad\n.png")] {
            XCTAssertNil(AgentTextInsertion.images(provider: "claude", text: text))
        }
        for text in ["bad\u{1b}" + quoted("/tmp/a.png"), String(repeating: "a", count: 32_768) + quoted("/tmp/a.png")] {
            XCTAssertNil(AgentTextInsertion.bytes(provider: "claude", text: text, bracketedPasteEnabled: false))
            XCTAssertNil(AgentTextInsertion.images(provider: "claude", text: text))
        }
    }

    func testCapturedComposersRequireEveryRenderedMarkerAndKeepPresence() {
        for (text, rows) in [
            (quoted("/tmp/a.png"), ["❯ [Image #1]"]),
            ("Reply with one word: ok\n" + quoted("/tmp/a.png"), ["❯ Reply with one word: ok", "  [Image #3]"]),
            (quoted("/tmp/a.png") + "\n" + quoted("/tmp/b.png") + "\nReply with one word: ok", ["❯ [Image #4]", "  [Image #5]", "  Reply with one word: ok"]),
            ("Keep [Image #99] literal\n" + quoted("/tmp/a.png"), ["❯ Keep [Image #99] literal", "  [Image #42]"]),
            ("A long line that wraps\n" + quoted("/tmp/a.png"), ["❯ A long line", "  that wraps", "  [Image #17]"]),
        ] {
            let visible = rows.joined(separator: "\n") + footer
            XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: visible, cursorRow: rows.count - 1,
                cursorVisible: true, requireEmpty: false, queueWhenWorking: false, text: text), .readyReturn)
            XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: visible, cursorLine: rows.last,
                text: text, cursorRow: rows.count - 1), .present)
            XCTAssertEqual(AgentComposerEvidence.submissionKey(provider: "claude", visibleText: visible, cursorLine: rows.last,
                text: text, queueWhenWorking: false, cursorRow: rows.count - 1), .return)
        }
    }

    func testIncompleteAndChangedImageDraftsCannotAuthorizeReturnOrProveDeparture() {
        let text = quoted("/tmp/a.png") + "\n" + quoted("/tmp/b.png") + "\nReply with one word: ok"
        for rows in [
            ["❯ [Image #4]"],
            ["❯ [Image #4]", "  [Image #6]", "  Reply with one word: ok"],
            ["❯ [Image #4]", "  [Image #4]", "  Reply with one word: ok"],
            ["❯ [Image #5]", "  [Image #4]", "  Reply with one word: ok"],
            ["❯ [Image #4]", "  [Image #5]", "  Different prose"],
            ["❯ [Image #4]", "  [Image #5]", "  Reply with one word: ok extra"],
            ["❯ \"/tmp/a.png\"", "  \"/tmp/b.png\"", "  Reply with one word: ok"],
        ] {
            let visible = rows.joined(separator: "\n") + footer
            XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: visible, cursorRow: rows.count - 1,
                cursorVisible: true, requireEmpty: false, queueWhenWorking: false, text: text), .unavailable)
            XCTAssertNotEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: visible, cursorLine: rows.last,
                text: text, cursorRow: rows.count - 1), .absent)
        }
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: "❯ \u{1b}[2mTry a suggestion\u{1b}[0m" + footer,
            cursorRow: 0, cursorColumn: 2, cursorVisible: true, requireEmpty: false, queueWhenWorking: false, text: text), .unavailable)
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: "❯ " + footer, cursorLine: "❯ ", text: text, cursorRow: 0), .absent)
    }

    func testExhaustedImageWaitFallbackRequiresTheEntireLiteralDraft() {
        let text = "Keep [Image #99] literal\n" + quoted("/tmp/a.png") + "\n" + quoted("/tmp/b.png") + "\nReply exactly"
        for (body, literalExpected, normalExpected) in [
            (text, true, false),
            (text.replacingOccurrences(of: quoted("/tmp/a.png"), with: "[Image #4]"), false, false),
            (text.replacingOccurrences(of: quoted("/tmp/b.png"), with: "[Image #5]"), false, false),
            ("Keep [Image #99] literal\n[Image #4]\n[Image #5]\nReply exactly", false, true),
            (text + " extra", false, false),
            (text.replacingOccurrences(of: "Reply exactly", with: "Reply  exactly"), false, false),
        ] {
            let rows = body.components(separatedBy: "\n").enumerated().map { ($0.offset == 0 ? "❯ " : "  ") + $0.element }
            for literalOnly in [false, true] {
                XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: rows.joined(separator: "\n") + footer,
                    cursorRow: rows.count - 1, cursorVisible: true, requireEmpty: false, queueWhenWorking: false,
                    text: text, literalImagePathsOnly: literalOnly),
                    (literalOnly ? literalExpected : normalExpected) ? .readyReturn : .unavailable, body)
            }
        }
    }

    func testRunningTurnFooterStillProvesDepartureAfterReturn() {
        // Claude Code 2.1.302 half a second after Return: the turn runs, the
        // echoed marker stays in the transcript and the composer is empty.
        let text = quoted("/tmp/bug4e2e/red.png")
        let rule = String(repeating: "─", count: 40)
        let rows = ["❯ [Image #2]", "✽ Nebulizing… (running UserPromptSubmit hooks… 1/2 · 0s)",
                    "  ⎿  Tip: Name your conversations with /rename to find them easily in /resume later",
                    rule, "❯ ", rule, "  ⏸ manual mode on · esc to interrupt"]
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: rows.joined(separator: "\n"),
            cursorLine: "❯ ", text: text, cursorRow: 4), .absent)
        var held = rows; held[4] = "❯ [Image #2]"
        XCTAssertEqual(AgentComposerEvidence.presence(provider: "claude", visibleText: held.joined(separator: "\n"),
            cursorLine: held[4], text: text, cursorRow: 4), .present)
    }

    func testReceiptNeedsExactProseConsecutiveGlobalIDsAndImageBlocks() {
        let text = quoted("/tmp/a.png") + "\n" + quoted("/tmp/b.png") + "\nReply with one word: ok"
        let rendered = "[Image #4]\n[Image #5]\nReply with one word: ok"
        let image = AgentBlock.attachment(name: "Image", mediaType: "image")
        func matches(_ blocks: [AgentBlock]) -> Bool { AgentTextInsertion.matchesReceipt(provider: "claude", text: text, blocks: blocks) }
        XCTAssertTrue(matches([.text(rendered), image, image]))
        for padding in ["\n", " ", " \n"] {
            XCTAssertTrue(matches([.text(padding + rendered + padding), image, image]))
            XCTAssertTrue(AgentTextInsertion.matchesReceipt(provider: "claude", text: padding + text + padding,
                blocks: [.text(rendered), image, image]))
        }
        XCTAssertFalse(matches([.text(rendered.replacingOccurrences(of: "one word", with: "one  word")), image, image]))
        for blocks: [AgentBlock] in [
            [.text(rendered)], [.text(rendered), image], [.text(rendered), image, image, image],
            [image, .text(rendered), image], [.text(rendered), .text(""), image, image],
            [.text(rendered), .attachment(name: "Wrong", mediaType: "image"), image],
            [.text(rendered.replacingOccurrences(of: "#5", with: "#6")), image, image],
            [.text(rendered.replacingOccurrences(of: "#5", with: "#4")), image, image],
            [.text(rendered.replacingOccurrences(of: "#4", with: "#6")), image, image],
            [.text(rendered.replacingOccurrences(of: "Reply", with: "Different")), image, image],
            [.text("[Image: source: /tmp/a.png]"), image, image],
        ] { XCTAssertFalse(matches(blocks), "\(blocks)") }
    }

    func testMetaImageSourceRecordsCannotBecomeReceipts() {
        let record = AgentProjectionRecord(sequence: 0, recordID: "meta", record: .object([
            "type": .string("message"), "role": .string("user"), "isMeta": .bool(true),
            "blocks": .array([.object(["type": .string("text"), "text": .string("[Image: source: /tmp/a.png]")])])
        ]))!
        XCTAssertNil(AgentTranscriptNormalizer().normalize(providerID: .claude, record: record).message)
    }

    func testClaudeImageReceiptAcceptsLiteralPathAfterSendAnywayButCodexStillRequiresImages() {
        for text in [quoted("/tmp/a.png"), "Describe\n" + quoted("/tmp/a.png")] {
            XCTAssertTrue(AgentTextInsertion.matchesReceipt(provider: "claude", text: text, blocks: [.text("\n" + text + "\n")]))
            let rendered = text.replacingOccurrences(of: quoted("/tmp/a.png"), with: "[Image #42]")
            XCTAssertTrue(AgentTextInsertion.matchesReceipt(provider: "claude", text: text,
                blocks: [.text(rendered), .attachment(name: "Image", mediaType: "image")]))
            XCTAssertFalse(AgentTextInsertion.matchesReceipt(provider: "codex", text: text, blocks: [.text(text)]))
            XCTAssertFalse(AgentTextInsertion.matchesReceipt(provider: "codex", text: text, blocks: [.text(rendered)]))
        }
    }

    private func unavailableFixture() async -> (AgentCenterRuntime, AgentThreadID, AgentTerminalBinding) {
        let core = AgentCenterRuntime()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "unavailable-image-receipts")!
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1, incarnation: AgentIncarnationToken("image")!,
            transport: .sshTmux, tmuxSession: "test", windowID: "@1", paneID: "%1", agentPID: 42, capabilities: [.observe, .send, .tmux])
        await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: true,
            spawn: false, fork: false, search: true)), binding: binding)
        return (core, id, binding)
    }

    private func unavailablePage(_ request: String, from: String?, records: [AgentProjectionRecord]) -> AgentProjectionPage {
        .init(sourceIdentity: "claude-chain:e1", from: from, records: records, cursor: nil, hasMore: false,
            ingestion: .init(epoch: "e1", requestID: request, operation: from == nil ? .bootstrap : .updates,
                liveCursor: request, sourceEnd: 1_000))!
    }

    private func unavailableReceipt(_ sequence: UInt64, id: String, image: Bool = true, physical: Bool = true) -> AgentProjectionRecord {
        var blocks: [AgentJSONValue] = [.object(["type": .string("text"), "text": .string(image ? "Describe\n[Image #42]" : "Describe")])]
        if image { blocks.append(.object(["type": .string("attachment"), "name": .string("Image"), "mediaType": .string("image")])) }
        return .init(sequence: sequence, recordID: id, record: .object([
            "type": .string("message"), "provider": .string("claude"), "role": .string("user"), "blocks": .array(blocks)
        ]), receiptSourceIdentity: physical ? "jsonl:1:2" : nil, receiptSourceOffset: physical ? 100 : nil)!
    }

    private func dispatchUnavailable(_ core: AgentCenterRuntime, id: AgentThreadID, binding: AgentTerminalBinding,
                                     image: Bool = true) async throws -> AgentActionLease {
        let text = "Describe" + (image ? "\n" + quoted("/tmp/a.png") : "")
        let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding,
            textRequest: AgentTextSendRequest(threadID: id, binding: binding, text: text, queueWhenWorking: false)!)
        try await core.armOutgoing(lease, frontier: .unavailable(for: lease))
        try await core.markOutgoingDispatched(lease)
        return lease
    }

    private func acceptUnavailable(_ core: AgentCenterRuntime, id: AgentThreadID, page: AgentProjectionPage,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        let result = await core.apply(page: page, to: id)
        XCTAssertTrue(result.accepted, "page rejected: \(result)", file: file, line: line)
    }

    func testUnavailableFrontierImageReceiptDuringDepartureIsObservedAndClaimed() async throws {
        for emptyReader in [false, true] {
            for physical in [false, true] {
                let (core, id, binding) = await unavailableFixture()
                let seed = unavailableReceipt(0, id: "seed", image: false)
                await acceptUnavailable(core, id: id, page: unavailablePage("boot", from: nil, records: emptyReader ? [] : [seed]))
                let first = try await dispatchUnavailable(core, id: id, binding: binding)
                let receipt = unavailableReceipt(1, id: "early", physical: physical)
                await acceptUnavailable(core, id: id, page: unavailablePage("early", from: "boot", records: [receipt]))
                await core.releaseLease(first, result: .verified)
                let acknowledged = await core.snapshot(for: id)
                XCTAssertEqual(acknowledged?.outgoingMessages?.first(where: { $0.id == first.token })?.status, .observed)

                let second = try await dispatchUnavailable(core, id: id, binding: binding)
                await core.releaseLease(second, result: .verified)
                // A physical receipt may get a new ID; an opaque record keeps
                // its ID when the same reader bootstraps again. Neither replay
                // may let the second send reuse the first send's claim.
                await acceptUnavailable(core, id: id, page: unavailablePage("replay", from: physical ? "early" : nil,
                    records: [unavailableReceipt(10, id: physical ? "replayed" : "early", physical: physical)]))
                let replayed = await core.snapshot(for: id)
                XCTAssertEqual(replayed?.outgoingMessages?.first(where: { $0.id == first.token })?.status, .observed)
                XCTAssertEqual(replayed?.outgoingMessages?.first(where: { $0.id == second.token })?.status, .sentUnconfirmed)
            }
        }
    }

    func testIdenticalUnavailableFrontierImageSendsKeepTheirOwnReceipts() async throws {
        for physical in [false, true] {
            let (core, id, binding) = await unavailableFixture()
            await acceptUnavailable(core, id: id, page: unavailablePage("boot", from: nil,
                records: [unavailableReceipt(0, id: "seed", image: false)]))
            let first = try await dispatchUnavailable(core, id: id, binding: binding)
            let firstReceipt = AgentProjectionRecord(sequence: 1, recordID: "first", record: unavailableReceipt(1, id: "first").record,
                receiptSourceIdentity: physical ? "jsonl:1:2" : nil, receiptSourceOffset: physical ? 0 : nil)!
            await acceptUnavailable(core, id: id, page: unavailablePage("first", from: "boot", records: [firstReceipt]))
            await core.releaseLease(first, result: .verified)
            let second = try await dispatchUnavailable(core, id: id, binding: binding)
            let secondReceipt = unavailableReceipt(2, id: "second", physical: physical)
            await acceptUnavailable(core, id: id, page: unavailablePage("early", from: "first", records: [secondReceipt]))
            await core.releaseLease(second, result: .verified)
            let acknowledged = await core.snapshot(for: id)
            XCTAssertEqual(acknowledged?.outgoingMessages?.first(where: { $0.id == first.token })?.status, .observed)
            XCTAssertEqual(acknowledged?.outgoingMessages?.first(where: { $0.id == second.token })?.status, .observed)

            await acceptUnavailable(core, id: id, page: unavailablePage("replay", from: "early", records: [secondReceipt]))
            let settled = await core.snapshot(for: id)
            XCTAssertEqual(settled?.outgoingMessages?.count, 2)
            XCTAssertEqual(settled?.outgoingMessages?.filter { $0.status != .observed }, [])
        }
    }

    func testUnavailableFrontierNonImageReceiptBeforeAcknowledgmentStaysFenced() async throws {
        let (core, id, binding) = await unavailableFixture()
        await acceptUnavailable(core, id: id, page: unavailablePage("boot", from: nil, records: []))
        let lease = try await dispatchUnavailable(core, id: id, binding: binding, image: false)
        let early = unavailableReceipt(0, id: "early", image: false)
        await acceptUnavailable(core, id: id, page: unavailablePage("early", from: "boot", records: [early]))
        await core.releaseLease(lease, result: .verified)
        await acceptUnavailable(core, id: id, page: unavailablePage("replay", from: "early", records: [early]))
        let fenced = await core.snapshot(for: id)
        XCTAssertEqual(fenced?.outgoingMessages?.first?.status, .sentUnconfirmed)
        let later = AgentProjectionRecord(sequence: 1, recordID: "later", record: early.record,
            receiptSourceIdentity: "jsonl:1:2", receiptSourceOffset: 200)!
        await acceptUnavailable(core, id: id, page: unavailablePage("later", from: "replay", records: [later]))
        let settled = await core.snapshot(for: id)
        XCTAssertEqual(settled?.outgoingMessages?.first?.status, .observed)
    }

    func testReceiptArrivingDuringDepartureVerificationSettlesWithoutWeakeningTheFence() async throws {
        for scenario in ["image", "missing-image", "different-prose", "meta"] {
            let core = AgentCenterRuntime()
            let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "early-image-receipt")!
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1, incarnation: AgentIncarnationToken("image")!,
                transport: .sshTmux, tmuxSession: "test", windowID: "@1", paneID: "%1", agentPID: 42, capabilities: [.observe, .send, .tmux])
            await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: true,
                spawn: false, fork: false, search: true)), binding: binding)
            _ = await core.apply(page: AgentProjectionPage(sourceIdentity: "1:2:0:1", records: [], cursor: nil, hasMore: false)!, to: id)
            let text = "Describe\n" + quoted("/tmp/a.png")
            let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding,
                textRequest: AgentTextSendRequest(threadID: id, binding: binding, text: text, queueWhenWorking: false)!)
            try await core.armOutgoing(lease, frontier: AgentOutgoingFrontier(actionID: lease.token, serviceEpoch: "epoch", provider: .claude,
                providerSessionID: id.providerSessionID, sourceIdentity: "jsonl:1:2", sourceEnd: 0, consistency: .observedPrefix)!)
            try await core.markOutgoingDispatched(lease)
            var blocks: [AgentJSONValue] = [.object(["type": .string("text"),
                "text": .string((scenario == "different-prose" ? "Different" : "Describe") + "\n[Image #42]")])]
            if scenario != "missing-image" {
                blocks.append(.object(["type": .string("attachment"), "name": .string("Image"), "mediaType": .string("image")]))
            }
            let record = AgentProjectionRecord(sequence: 0, recordID: "early", record: .object(["type": .string("message"),
                "provider": .string("claude"), "role": .string("user"), "isMeta": .bool(scenario == "meta"), "blocks": .array(blocks)]),
                receiptSourceIdentity: "jsonl:1:2", receiptSourceOffset: 0)!
            let page = AgentProjectionPage(sourceIdentity: "1:2:1000:2", records: [record], cursor: nil, hasMore: false)!
            _ = await core.apply(page: page, to: id)
            let before = await core.snapshot(for: id)
            XCTAssertEqual(before?.outgoingMessages?.first?.status, .sending)
            await core.releaseLease(lease, result: .verified)
            let acknowledged = await core.snapshot(for: id)
            XCTAssertEqual(acknowledged?.outgoingMessages?.first?.status, scenario == "image" ? .observed : .awaitingReceipt)
            _ = await core.apply(page: AgentProjectionPage(sourceIdentity: "1:2:1000:3", records: [record], cursor: nil, hasMore: false)!, to: id)
            let after = await core.snapshot(for: id)
            XCTAssertEqual(after?.outgoingMessages?.first?.status, scenario == "image" ? .observed : .awaitingReceipt)
            if scenario == "image" {
                XCTAssertEqual(after?.messages.count, 1)
                XCTAssertEqual(after?.outgoingMessages?.filter { $0.status != .observed }, [])
            }
        }
    }

    func testIdenticalImageSendsKeepTheirOwnReceiptsAfterEarlyVerificationAndReaderReplay() async throws {
        for replay in [false, true] {
            let core = AgentCenterRuntime()
            let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "identical-image-receipts")!
            let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1, incarnation: AgentIncarnationToken("image")!,
                transport: .sshTmux, tmuxSession: "test", windowID: "@1", paneID: "%1", agentPID: 42, capabilities: [.observe, .send, .tmux])
            await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: true,
                spawn: false, fork: false, search: true)), binding: binding)
            func page(_ request: String, from: String?, records: [AgentProjectionRecord], epoch: String = "e1") -> AgentProjectionPage {
                .init(sourceIdentity: "claude-chain:\(epoch)", from: from, records: records, cursor: nil, hasMore: false,
                    ingestion: .init(epoch: epoch, requestID: request, operation: from == nil ? .bootstrap : .updates,
                        liveCursor: request, sourceEnd: 1_000))!
            }
            func receipt(_ sequence: UInt64, offset: UInt64, marker: Int) -> AgentProjectionRecord {
                .init(sequence: sequence, recordID: "image-\(sequence)", record: .object([
                    "type": .string("message"), "provider": .string("claude"), "role": .string("user"), "blocks": .array([
                        .object(["type": .string("text"), "text": .string("Describe\n[Image #\(marker)]")]),
                        .object(["type": .string("attachment"), "name": .string("Image"), "mediaType": .string("image")])
                    ])]), receiptSourceIdentity: "jsonl:1:2", receiptSourceOffset: offset)!
            }
            let text = "Describe\n" + quoted("/tmp/a.png")
            func dispatch(end: UInt64) async throws -> AgentActionLease {
                let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding,
                    textRequest: AgentTextSendRequest(threadID: id, binding: binding, text: text, queueWhenWorking: false)!)
                try await core.armOutgoing(lease, frontier: AgentOutgoingFrontier(actionID: lease.token, serviceEpoch: "epoch", provider: .claude,
                    providerSessionID: id.providerSessionID, sourceIdentity: "jsonl:1:2", sourceEnd: end, consistency: .observedPrefix)!)
                try await core.markOutgoingDispatched(lease)
                return lease
            }
            let boot = await core.apply(page: page("boot", from: nil, records: []), to: id)
            XCTAssertTrue(boot.accepted)
            let first = try await dispatch(end: 0)
            let firstRecord = receipt(0, offset: 0, marker: 42)
            let early = await core.apply(page: page("early", from: "boot", records: [firstRecord]), to: id)
            XCTAssertTrue(early.accepted)
            await core.releaseLease(first, result: .verified)
            let afterFirst = await core.snapshot(for: id)
            XCTAssertEqual(afterFirst?.outgoingMessages?.first(where: { $0.id == first.token })?.status, .observed)

            if replay {
                // Empty restarted reader and overlapping EOF observations make
                // the physical claim, rather than a sequence/offset fence,
                // responsible for excluding the first receipt from send #2.
                let restart = await core.apply(page: page("restart", from: nil, records: [], epoch: "e2"), to: id)
                XCTAssertTrue(restart.accepted)
            }
            let second = try await dispatch(end: replay ? 0 : 100)
            await core.releaseLease(second, result: .verified)
            let beforeSecondReceipt = await core.snapshot(for: id)
            XCTAssertEqual(beforeSecondReceipt?.outgoingMessages?.first(where: { $0.id == first.token })?.status, .observed)
            XCTAssertEqual(beforeSecondReceipt?.outgoingMessages?.first(where: { $0.id == second.token })?.status, .awaitingReceipt)
            if replay {
                let replayed = await core.apply(page: page("replayed", from: "restart", records: [receipt(10, offset: 0, marker: 42)], epoch: "e2"), to: id)
                XCTAssertTrue(replayed.accepted)
                let afterReplay = await core.snapshot(for: id)
                XCTAssertEqual(afterReplay?.outgoingMessages?.first(where: { $0.id == first.token })?.status, .observed)
                XCTAssertEqual(afterReplay?.outgoingMessages?.first(where: { $0.id == second.token })?.status, .awaitingReceipt,
                    "send #1's physical receipt must not settle send #2, even under a new reader sequence")
            }
            let secondRecord = receipt(replay ? 11 : 1, offset: 100, marker: 43)
            let final = await core.apply(page: page("second", from: replay ? "replayed" : "early", records: [secondRecord], epoch: replay ? "e2" : "e1"), to: id)
            XCTAssertTrue(final.accepted)
            let afterSecond = await core.snapshot(for: id)
            XCTAssertEqual(afterSecond?.outgoingMessages?.count, 2)
            XCTAssertEqual(afterSecond?.outgoingMessages?.first(where: { $0.id == first.token })?.status, .observed)
            XCTAssertEqual(afterSecond?.outgoingMessages?.first(where: { $0.id == second.token })?.status, .observed,
                "send #2's receipt must settle send #2, not be stolen by send #1")
            XCTAssertEqual(afterSecond?.outgoingMessages?.filter { $0.status != .observed }, [])
        }
    }

    func testImageReceiptSettlesBothRuntimeReceiptPathsAndFailedVerificationSettlesUnconfirmed() async throws {
        for frontier in [false, true] {
            for verified in [false, true] {
                let core = AgentCenterRuntime()
                let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "image-receipt")!
                let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1, incarnation: AgentIncarnationToken("image")!,
                    transport: .sshTmux, tmuxSession: "test", windowID: "@1", paneID: "%1", agentPID: 42, capabilities: [.observe, .send, .tmux])
                await core.register(.init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: true,
                    spawn: false, fork: false, search: true)), binding: binding)
                let boundary = AgentProjectionPage(sourceIdentity: "1:2:0:1", records: [], cursor: nil, hasMore: false,
                    summary: .object(["receiptByteOffset": .string("0")]))!
                _ = await core.apply(page: boundary, to: id)
                let text = "Describe\n" + quoted("/tmp/a.png")
                let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding,
                    textRequest: AgentTextSendRequest(threadID: id, binding: binding, text: text, queueWhenWorking: false)!)
                if frontier {
                    try await core.armOutgoing(lease, frontier: AgentOutgoingFrontier(actionID: lease.token, serviceEpoch: "epoch",
                        provider: .claude, providerSessionID: id.providerSessionID, sourceIdentity: "jsonl:1:2", sourceEnd: 0, consistency: .observedPrefix)!)
                } else {
                    try await core.armOutgoing(lease, freshPage: boundary)
                }
                try await core.markOutgoingDispatched(lease)
                await core.releaseLease(lease, result: verified ? .verified : .failed)
                let released = await core.snapshot(for: id)
                XCTAssertEqual(released?.outgoingMessages?.first?.status, verified ? .awaitingReceipt : .unconfirmed)
                guard verified else { continue }
                let meta = AgentProjectionRecord(sequence: 0, recordID: "meta", record: .object([
                    "type": .string("message"), "role": .string("user"), "isMeta": .bool(true),
                    "blocks": .array([.object(["type": .string("text"), "text": .string("[Image: source: /tmp/a.png]")])])
                ]), sourceOffset: 0, sourceHash: String(repeating: "a", count: 64), receiptSourceIdentity: "jsonl:1:2", receiptSourceOffset: 0)!
                _ = await core.apply(page: AgentProjectionPage(sourceIdentity: "1:2:1000:2", records: [meta], cursor: nil, hasMore: false)!, to: id)
                let afterMeta = await core.snapshot(for: id)
                XCTAssertEqual(afterMeta?.outgoingMessages?.count, 1)
                let blocks: [AgentJSONValue] = [
                    .object(["type": .string("text"), "text": .string("Describe\n[Image #42]")]),
                    .object(["type": .string("attachment"), "name": .string("Image"), "mediaType": .string("image")])
                ]
                let record = AgentProjectionRecord(sequence: 1, recordID: "image", record: .object(["type": .string("message"),
                    "provider": .string("claude"), "role": .string("user"), "blocks": .array(blocks)]), sourceOffset: 100,
                    sourceHash: String(repeating: "b", count: 64), receiptSourceIdentity: "jsonl:1:2", receiptSourceOffset: 100)!
                _ = await core.apply(page: AgentProjectionPage(sourceIdentity: "1:2:2000:3", records: [meta, record], cursor: nil, hasMore: false)!, to: id)
                let snapshot = await core.snapshot(for: id)
                XCTAssertEqual(snapshot?.outgoingMessages?.count, frontier ? 1 : 0)
                if frontier { XCTAssertEqual(snapshot?.outgoingMessages?.first?.status, .observed) }
                XCTAssertEqual(snapshot?.messages.count, 1)
            }
        }
    }
}
