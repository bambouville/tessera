import XCTest
@testable import TmuxControlCore

final class RenderCommandQueueTests: XCTestCase {
    func testListSuccessKeepsOneSlotAndBlocksLaterPurposes() throws {
        var queue = RenderCommandQueue()
        let list = try XCTUnwrap(queue.enqueuePlatformList(["display -p a", "display -p b", "display -p c"]))
        let single = queue.enqueuePlatform("display -p d")
        _ = queue.enqueueLedger("probe", token: 41)
        XCTAssertEqual(list.command, "display -p a ; display -p b ; display -p c")
        XCTAssertEqual(queue.pendingCount, 3)
        for line in ["a", "b"] {
            XCTAssertNil(queue.consume(completed(lines: [line])))
            XCTAssertEqual(queue.pendingCount, 3)
            XCTAssertEqual(queue.headCommand, list.command)
            XCTAssertNil(queue.nextLedgerToken)
        }
        let parts = ["a", "b", "c"].map { RenderCommandResult(success: true, lines: [$0]) }
        XCTAssertEqual(queue.consume(completed(lines: ["c"])),
                       .platform(tag: list.tag, result: .init(success: true, lines: ["a", "b", "c"], parts: parts)))
        XCTAssertEqual(queue.consume(completed(lines: ["d"])),
                       .platform(tag: single.tag, result: .init(success: true, lines: ["d"])))
        XCTAssertEqual(queue.nextLedgerToken, 41)
        XCTAssertEqual(queue.consume(completed(lines: [])), .ledger(token: 41, result: .init(success: true, lines: [])))
        XCTAssertTrue(queue.isEmpty)
    }

    func testListErrorAtEveryPositionClosesWithoutConsumingLaterReplies() throws {
        for errorIndex in 0..<3 {
            var queue = RenderCommandQueue()
            let list = try XCTUnwrap(queue.enqueuePlatformList(["one", "two", "three"]))
            let later = queue.enqueuePlatform("later")
            var parts: [RenderCommandResult] = []
            for index in 0..<errorIndex {
                let lines = ["part-\(index)", "more-\(index)"]
                parts.append(.init(success: true, lines: lines))
                XCTAssertNil(queue.consume(completed(lines: lines)))
            }
            parts.append(.init(success: false, lines: ["error"]))
            XCTAssertEqual(queue.consume(completed(status: .error, lines: ["error"])),
                           .platform(tag: list.tag, result: .init(success: false, lines: parts.flatMap(\.lines), parts: parts)))
            XCTAssertEqual(queue.pendingCount, 1)
            XCTAssertEqual(queue.consume(completed(lines: ["later"])),
                           .platform(tag: later.tag, result: .init(success: true, lines: ["later"])))
            XCTAssertTrue(queue.isEmpty)
        }
    }

    func testListParseErrorIsOnePartAndReleasesTheSlot() throws {
        var queue = RenderCommandQueue()
        let list = try XCTUnwrap(queue.enqueuePlatformList(["display -p a", "unknown-command", "display -p b"]))
        _ = queue.enqueueLedger("later", token: 9)
        let lines = ["parse error: unknown command: unknown-command"]
        XCTAssertEqual(queue.consume(completed(status: .error, lines: lines)),
                       .platform(tag: list.tag, result: .init(success: false, lines: lines,
                           parts: [.init(success: false, lines: lines)])))
        XCTAssertEqual(queue.nextLedgerToken, 9)
        XCTAssertEqual(queue.consume(completed(lines: ["later"])),
                       .ledger(token: 9, result: .init(success: true, lines: ["later"])))
    }

    func testHookAndServerFramesInsideListDoNotCountAsParts() throws {
        var queue = RenderCommandQueue()
        let list = try XCTUnwrap(queue.enqueuePlatformList(["one", "two"]))
        XCTAssertNil(queue.consume(completed(flags: 0, lines: ["hook-before"])))
        XCTAssertNil(queue.consume(completed(lines: ["one"])))
        XCTAssertNil(queue.consume(completed(status: .error, flags: 0, lines: ["hook-error"])))
        XCTAssertNil(queue.consume(completed(flags: 2, lines: ["server"])))
        XCTAssertNil(queue.consume(.frameStarted(current: .init(time: 1, commandNumber: 3, flags: 1),
                                                discarded: nil, discardedLineCount: 0)))
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.consume(completed(lines: ["two"])),
                       .platform(tag: list.tag, result: .init(success: true, lines: ["one", "two"],
                           parts: [.init(success: true, lines: ["one"]), .init(success: true, lines: ["two"])])))
    }

    func testDrainThroughPartialListKeepsReceivedPartsAndLaterEntries() throws {
        var queue = RenderCommandQueue()
        let list = try XCTUnwrap(queue.enqueuePlatformList(["one", "two", "three"]))
        _ = queue.enqueueLedger("probe", token: 11)
        let later = queue.enqueuePlatform("later")
        XCTAssertNil(queue.consume(completed(lines: ["one"])))
        XCTAssertNil(queue.drainThrough(ledgerToken: 99))
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertEqual(queue.drainThrough(ledgerToken: 11), [
            .platform(tag: list.tag, result: .init(success: false, lines: ["one"],
                parts: [.init(success: true, lines: ["one"])])),
            .ledger(token: 11, result: .init(success: false, lines: []))
        ])
        XCTAssertEqual(queue.headCommand, "later")
        XCTAssertEqual(queue.consume(completed(lines: ["later"])),
                       .platform(tag: later.tag, result: .init(success: true, lines: ["later"])))
    }

    func testCancelUnwrittenSuffixIncludingListPreservesPartialHead() throws {
        var queue = RenderCommandQueue()
        let head = try XCTUnwrap(queue.enqueuePlatformList(["one", "two"]))
        XCTAssertNil(queue.consume(completed(lines: ["one"])))
        _ = queue.enqueueLedger("probe", token: 12)
        let list = try XCTUnwrap(queue.enqueuePlatformList(["unwritten-one", "unwritten-two"]))
        let single = queue.enqueuePlatform("unwritten-single")
        XCTAssertFalse(queue.cancelUnwrittenPlatformSuffix(tags: [list.tag]))
        XCTAssertFalse(queue.cancelUnwrittenPlatformSuffix(tags: [head.tag, list.tag, single.tag]))
        XCTAssertEqual(queue.pendingCount, 4)
        XCTAssertTrue(queue.cancelUnwrittenPlatformSuffix(tags: [list.tag, single.tag]))
        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertEqual(queue.consume(completed(lines: ["two"])),
                       .platform(tag: head.tag, result: .init(success: true, lines: ["one", "two"],
                           parts: [.init(success: true, lines: ["one"]), .init(success: true, lines: ["two"])])))
        XCTAssertEqual(queue.nextLedgerToken, 12)
    }

    func testListValidationRejectsWithoutAllocatingTagsOrSlots() {
        var queue = RenderCommandQueue()
        let rejected: [[String]] = [[], [""], ["one", ""], ["one;two"], ["one\ntwo"], ["one\rtwo"], ["one\0two"], ["one", "two;three"]]
        for commands in rejected {
            XCTAssertNil(queue.enqueuePlatformList(commands), "\(commands)")
            XCTAssertEqual(queue.pendingCount, 0)
            XCTAssertNil(queue.headCommand)
        }
        XCTAssertEqual(queue.enqueuePlatform("valid").tag, 1)
    }

    func testSingleElementListMatchesSingleCommandIncludingErrors() throws {
        for status in [TmuxCommandFrameStatus.success, .error] {
            var single = RenderCommandQueue()
            var list = RenderCommandQueue()
            XCTAssertEqual(single.enqueuePlatform("display -p a"), list.enqueuePlatformList(["display -p a"]))
            let event = completed(status: status, lines: ["a"])
            XCTAssertEqual(single.consume(event), list.consume(event))
            XCTAssertTrue(list.isEmpty)
        }
    }

    func testResetDropsPartialListAndKeepsTagSequence() throws {
        var queue = RenderCommandQueue()
        _ = try XCTUnwrap(queue.enqueuePlatformList(["one", "two"]))
        XCTAssertNil(queue.consume(completed(lines: ["one"])))
        queue.reset()
        XCTAssertNil(queue.headCommand)
        XCTAssertNil(queue.nextLedgerToken)
        let next = queue.enqueuePlatform("new")
        XCTAssertEqual(next.tag, 2)
        XCTAssertEqual(queue.consume(completed(lines: ["new"])),
                       .platform(tag: next.tag, result: .init(success: true, lines: ["new"])))
    }

    func testUnwrittenRollbackRemovesOnlyExactPlatformSuffix() {
        var queue = RenderCommandQueue()
        let written = queue.enqueuePlatform("written")
        let first = queue.enqueuePlatform("unwritten-one")
        let second = queue.enqueuePlatform("unwritten-two")
        XCTAssertFalse(queue.cancelUnwrittenPlatformSuffix(tags: [first.tag]))
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertTrue(queue.cancelUnwrittenPlatformSuffix(tags: [first.tag, second.tag]))
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.consume(completed(lines: ["reply"])), .platform(tag: written.tag, result: .init(success: true, lines: ["reply"])))
    }

    func testPlatformAndLedgerPurposesDrainInSendOrder() {
        var queue = RenderCommandQueue()
        let platform = queue.enqueuePlatform("query-one")
        _ = queue.enqueueLedger("query-two", token: 41)

        XCTAssertEqual(platform.tag, 1)
        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertEqual(
            queue.consume(completed(lines: ["one"])),
            .platform(tag: 1, result: .init(success: true, lines: ["one"]))
        )
        XCTAssertEqual(
            queue.consume(completed(status: .error, lines: ["bad"])),
            .ledger(token: 41, result: .init(success: false, lines: ["bad"]))
        )
        XCTAssertTrue(queue.isEmpty)
    }

    func testServerFrameNeverPopsTheFIFO() {
        var queue = RenderCommandQueue()
        _ = queue.enqueuePlatform("query")

        XCTAssertNil(queue.consume(completed(flags: 0, lines: ["hook"])))
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertNotNil(queue.consume(completed(lines: ["reply"])))
    }

    func testParsedMalformedOpeningGuardDeliversExactlyOneTaggedReply() {
        var parser = TmuxControlParser()
        var correlator = TmuxCommandResponseCorrelator()
        var queue = RenderCommandQueue()
        let ticket = queue.enqueuePlatform("query")
        var replies = 0
        for message in parser.feed(Array("%begin 10 4 broken\nbody\n%end 10 4 1\n".utf8)) {
            guard let event = correlator.consume(message), let reply = queue.consume(event) else { continue }
            replies += 1
            XCTAssertEqual(reply, .platform(tag: ticket.tag, result: .init(success: true, lines: ["body"])))
        }
        XCTAssertEqual(replies, 1)
        XCTAssertTrue(queue.isEmpty)
    }

    func testClassificationUsesTheOpeningGuard() {
        var queue = RenderCommandQueue()
        _ = queue.enqueueLedger("query", token: 7)
        let begin = TmuxCommandGuard(time: 1, commandNumber: 2, flags: 1)
        let mismatchedEnd = TmuxCommandGuard(time: 9, commandNumber: 9, flags: 0)
        let frame = TmuxCommandFrame(
            status: .success,
            begin: begin,
            end: mismatchedEnd,
            effectiveFlags: begin.flags,
            guardMatches: false,
            lines: ["body"]
        )

        XCTAssertEqual(
            queue.consume(.frameCompleted(frame)),
            .ledger(token: 7, result: .init(success: true, lines: ["body"]))
        )
    }

    func testResetInvalidatesOutstandingPurposesWithoutReusingTags() {
        var queue = RenderCommandQueue()
        XCTAssertEqual(queue.enqueuePlatform("old").tag, 1)
        queue.reset()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.enqueuePlatform("new").tag, 2)
    }

    private func completed(
        status: TmuxCommandFrameStatus = .success,
        flags: Int = 1,
        lines: [String]
    ) -> TmuxCorrelationEvent {
        let guardValue = TmuxCommandGuard(time: 1, commandNumber: 2, flags: flags)
        return .frameCompleted(.init(
            status: status,
            begin: guardValue,
            end: guardValue,
            effectiveFlags: flags,
            guardMatches: true,
            lines: lines
        ))
    }
}
