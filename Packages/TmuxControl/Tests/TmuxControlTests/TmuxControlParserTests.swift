import XCTest
@testable import TmuxControl

final class TmuxControlParserTests: XCTestCase {

    // MARK: - Window lifecycle

    func test_windowAdd_isParsed() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%window-add @7\n".utf8))
        XCTAssertEqual(msgs, [.windowAdd(windowId: WindowId(7))])
    }

    func test_windowClose_isParsed() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%window-close @3\n".utf8))
        XCTAssertEqual(msgs, [.windowClose(windowId: WindowId(3))])
    }

    func test_windowRenamed_preservesNameWithSpaces() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%window-renamed @1 my great window\n".utf8))
        XCTAssertEqual(
            msgs,
            [.windowRenamed(windowId: WindowId(1), name: "my great window")]
        )
    }

    func test_windowPaneChanged_isParsed() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%window-pane-changed @2 %5\n".utf8))
        XCTAssertEqual(
            msgs,
            [.windowPaneChanged(windowId: WindowId(2), activePaneId: PaneId(5))]
        )
    }

    func test_layoutChange_fourFields_isParsed() {
        // Verbatim shape from a live tmux 3.6a split-window -h.
        var parser = TmuxControlParser()
        let wire = "%layout-change @0 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} 8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1} *\n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(
            msgs,
            [.layoutChange(
                windowId: WindowId(0),
                layout: "8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}",
                visibleLayout: "8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}",
                rawFlags: "*"
            )]
        )
    }

    func test_layoutChange_zoomed_carriesZFlagAndCollapsedVisible() {
        var parser = TmuxControlParser()
        let wire = "%layout-change @0 d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]} b25f,80x24,0,0,2 *Z\n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(
            msgs,
            [.layoutChange(
                windowId: WindowId(0),
                layout: "d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}",
                visibleLayout: "b25f,80x24,0,0,2",
                rawFlags: "*Z"
            )]
        )
    }

    func test_layoutChange_legacyTwoToken_isParsed() {
        // Older/short shapes (layout only) still decode, with nil trailers.
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%layout-change @1 d13a,80x24,0,0,1\n".utf8))
        XCTAssertEqual(
            msgs,
            [.layoutChange(
                windowId: WindowId(1),
                layout: "d13a,80x24,0,0,1",
                visibleLayout: nil,
                rawFlags: nil
            )]
        )
    }

    func test_layoutChange_emptyFlagsTrailingSpace_decodeToNilFlags() {
        // Empty raw_flags arrive as a trailing space → no flags token.
        var parser = TmuxControlParser()
        let wire = "%layout-change @2 b25d,80x24,0,0,0 b25d,80x24,0,0,0 \n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(
            msgs,
            [.layoutChange(
                windowId: WindowId(2),
                layout: "b25d,80x24,0,0,0",
                visibleLayout: "b25d,80x24,0,0,0",
                rawFlags: nil
            )]
        )
    }

    // MARK: - Session lifecycle

    func test_sessionChanged_isParsed() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%session-changed $2 work\n".utf8))
        XCTAssertEqual(
            msgs,
            [.sessionChanged(sessionId: SessionId(2), name: "work")]
        )
    }

    func test_sessionsChanged_noArgs() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%sessions-changed\n".utf8))
        XCTAssertEqual(msgs, [.sessionsChanged])
    }

    func test_subscriptionChanged_isParsed() {
        var parser = TmuxControlParser()
        let wire = "%subscription-changed tessera-pane-meta $0 @2 1 %7 : @2\\t%7\\t1\\thtop\\tCodex Title\\tzsh\\thost\n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .subscriptionChanged(
                name: "tessera-pane-meta",
                sessionId: SessionId(0),
                windowId: WindowId(2),
                windowIndex: 1,
                paneId: PaneId(7),
                value: "@2\\t%7\\t1\\thtop\\tCodex Title\\tzsh\\thost"
            ),
        ])
    }

    func test_subscriptionChanged_ignoresFutureFieldsBeforeValue() {
        var parser = TmuxControlParser()
        let wire = "%subscription-changed tessera-pane-meta $0 @2 1 %7 future fields : title\n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .subscriptionChanged(
                name: "tessera-pane-meta",
                sessionId: SessionId(0),
                windowId: WindowId(2),
                windowIndex: 1,
                paneId: PaneId(7),
                value: "title"
            ),
        ])
    }

    // MARK: - Output decoding

    func test_output_plainAscii() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%output %1 hello world\n".utf8))
        XCTAssertEqual(
            msgs,
            [.output(paneId: PaneId(1), data: Array("hello world".utf8))]
        )
    }

    func test_output_decodesOctalEscapes() {
        var parser = TmuxControlParser()
        // \012 = LF, \040 = space, \\ tmux encoding is \134
        let wire = "%output %3 line1\\012line2\n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs.count, 1)
        guard case .output(let pane, let data) = msgs[0] else {
            return XCTFail("expected output")
        }
        XCTAssertEqual(pane, PaneId(3))
        XCTAssertEqual(data, Array("line1\nline2".utf8))
    }

    func test_output_decodesBackslash() {
        var parser = TmuxControlParser()
        let wire = "%output %1 path\\134to\\134file\n"
        let msgs = parser.feed(Array(wire.utf8))
        guard case .output(_, let data) = msgs.first else {
            return XCTFail("expected output")
        }
        XCTAssertEqual(data, Array("path\\to\\file".utf8))
    }

    func test_output_decodesEscapeChar() {
        var parser = TmuxControlParser()
        // ESC is \033 in octal
        let wire = "%output %1 \\033[31mred\\033[0m\n"
        let msgs = parser.feed(Array(wire.utf8))
        guard case .output(_, let data) = msgs.first else {
            return XCTFail("expected output")
        }
        XCTAssertEqual(data, [0x1B, 0x5B, 0x33, 0x31, 0x6D, // ESC [ 3 1 m
                              0x72, 0x65, 0x64,             // r e d
                              0x1B, 0x5B, 0x30, 0x6D])      // ESC [ 0 m
    }

    func test_output_preservesHighBytes() {
        var parser = TmuxControlParser()
        // UTF-8 continuation bytes like 0xe2 0x9c 0x93 (✓) are NOT escaped.
        let check: [UInt8] = [0xE2, 0x9C, 0x93]
        var wire: [UInt8] = Array("%output %1 ".utf8)
        wire.append(contentsOf: check)
        wire.append(0x0A)
        let msgs = parser.feed(wire)
        guard case .output(_, let data) = msgs.first else {
            return XCTFail("expected output")
        }
        XCTAssertEqual(data, check)
    }

    func test_output_withBellEmitsBellAndPreservesBytes() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%output %0 hello\u{07}world\n".utf8))
        XCTAssertEqual(msgs, [
            .bell(paneID: 0),
            .output(paneId: PaneId(0), data: Array("hello\u{07}world".utf8)),
        ])
    }

    func test_output_withMultipleBellsEmitsOneBellPerChunk() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%output %0 \u{07}\u{07}\u{07}\n".utf8))
        XCTAssertEqual(msgs, [
            .bell(paneID: 0),
            .output(paneId: PaneId(0), data: [0x07, 0x07, 0x07]),
        ])
    }

    func test_output_oscTitleTerminatorDoesNotEmitBell() {
        var parser = TmuxControlParser()
        let payload = "\u{1B}]0;Semantic Title\u{07}"
        let msgs = parser.feed(Array("%output %0 \(payload)\n".utf8))
        XCTAssertEqual(msgs, [
            .output(paneId: PaneId(0), data: Array(payload.utf8)),
        ])
    }

    func test_output_splitOscTitleTerminatorDoesNotEmitBell() {
        var parser = TmuxControlParser()
        let firstPayload = "\u{1B}]0;Semantic"
        let secondPayload = " Title\u{07}"

        let first = parser.feed(Array("%output %0 \(firstPayload)\n".utf8))
        let second = parser.feed(Array("%output %0 \(secondPayload)\n".utf8))

        XCTAssertEqual(first, [
            .output(paneId: PaneId(0), data: Array(firstPayload.utf8)),
        ])
        XCTAssertEqual(second, [
            .output(paneId: PaneId(0), data: Array(secondPayload.utf8)),
        ])
    }

    func test_output_separateBellChunksEachEmitBell() {
        var parser = TmuxControlParser()
        let first = parser.feed(Array("%output %0 a\u{07}\n".utf8))
        let second = parser.feed(Array("%output %0 b\u{07}\n".utf8))
        let msgs = first + second
        XCTAssertEqual(
            msgs.filter {
                if case .bell = $0 { return true }
                return false
            }.count,
            2
        )
    }

    func test_output_dcsBytesSplitAcrossFeedsDoNotEmitBell() {
        var parser = TmuxControlParser()
        let first = parser.feed(Array("%output %0 ".utf8) + [0x1B, 0x50, 0x31])
        let second = parser.feed([0x30, 0x30, 0x30, 0x70] + Array("payload\n".utf8))
        let dcsEnter: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]

        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [
            .output(paneId: PaneId(0), data: dcsEnter + Array("payload".utf8)),
        ])
    }

    func test_extendedOutput_decodesOctalEscapes() {
        var parser = TmuxControlParser()
        let wire = "%extended-output %3 17 : line1\\012line2\\040done\n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .extendedOutput(
                paneId: PaneId(3),
                ageMs: 17,
                data: Array("line1\nline2 done".utf8)
            ),
        ])
    }

    func test_extendedOutput_withBellEmitsBellAndPreservesBytes() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%extended-output %2 5 : hello\u{07}world\n".utf8))
        XCTAssertEqual(msgs, [
            .bell(paneID: 2),
            .extendedOutput(paneId: PaneId(2), ageMs: 5, data: Array("hello\u{07}world".utf8)),
        ])
    }

    func test_extendedOutput_skipsUnknownFieldsBeforePayload() {
        var parser = TmuxControlParser()
        let wire = "%extended-output %4 29 future tokens ignored : payload\n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .extendedOutput(paneId: PaneId(4), ageMs: 29, data: Array("payload".utf8)),
        ])
    }

    func test_extendedOutput_withoutPayloadSeparatorIsUnknown() {
        var parser = TmuxControlParser()
        let wire = "%extended-output %4 29 payload\n"
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [.unknown("%extended-output %4 29 payload")])
    }

    // MARK: - Command response framing

    func test_commandResponse_capturesOutputLinesBetweenBeginAndEnd() {
        var parser = TmuxControlParser()
        let wire = """
        %begin 1234 5 0
        line one
        line two
        %end 1234 5 0

        """
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 1234, commandNumber: 5, flags: 0),
            .commandOutputLine("line one"),
            .commandOutputLine("line two"),
            .end(time: 1234, commandNumber: 5, flags: 0),
        ])
    }

    func test_commandResponse_errorEndsResponseWithError() {
        var parser = TmuxControlParser()
        let wire = """
        %begin 1 2 0
        something broke
        %error 1 2 0

        """
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 1, commandNumber: 2, flags: 0),
            .commandOutputLine("something broke"),
            .error(time: 1, commandNumber: 2, flags: 0),
        ])
    }

    func test_commandResponse_allowsControlLikeOutputLinesWithoutMisparse() {
        // A command output line that happens to start with "%" must not be
        // mistaken for a control notification.
        var parser = TmuxControlParser()
        let wire = """
        %begin 1 1 0
        %foo looks like a control line but isn't
        %end 1 1 0

        """
        let msgs = parser.feed(Array(wire.utf8))
        // NOTE: lines inside %begin that happen to start with '%' that
        // aren't %end/%error are treated as output lines. The parser
        // only exits on a matching %end/%error command number.
        XCTAssertEqual(msgs, [
            .begin(time: 1, commandNumber: 1, flags: 0),
            .commandOutputLine("%foo looks like a control line but isn't"),
            .end(time: 1, commandNumber: 1, flags: 0),
        ])
    }

    func test_commandResponse_nonMatchingEndNumberStaysInFrame() {
        var parser = TmuxControlParser()
        let wire = """
        %begin 100 7 1
        %end 999 45 1
        %end 101 7 1

        """
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 100, commandNumber: 7, flags: 1),
            .commandOutputLine("%end 999 45 1"),
            .end(time: 101, commandNumber: 7, flags: 1),
        ])
    }

    func test_commandResponse_nonMatchingErrorNumberStaysInFrame() {
        var parser = TmuxControlParser()
        let wire = """
        %begin 100 7 1
        %error 999 45 1
        %end 101 7 1

        """
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 100, commandNumber: 7, flags: 1),
            .commandOutputLine("%error 999 45 1"),
            .end(time: 101, commandNumber: 7, flags: 1),
        ])
    }

    func test_commandResponse_notificationShapedBodyLinesRemainCommandOutput() {
        var parser = TmuxControlParser()
        let wire = """
        %begin 1234 5 0
        %output %5 hello
        %session-window-changed $0 @2
        %end 1234 5 0

        """
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 1234, commandNumber: 5, flags: 0),
            .commandOutputLine("%output %5 hello"),
            .commandOutputLine("%session-window-changed $0 @2"),
            .end(time: 1234, commandNumber: 5, flags: 0),
        ])
    }

    func test_commandResponse_extendedOutputShapedBodyLineRemainsCommandOutput() {
        var parser = TmuxControlParser()
        let wire = """
        %begin 1234 5 0
        %extended-output %5 12 : hello
        %end 1234 5 0

        """
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 1234, commandNumber: 5, flags: 0),
            .commandOutputLine("%extended-output %5 12 : hello"),
            .end(time: 1234, commandNumber: 5, flags: 0),
        ])
    }

    func test_commandResponse_windowNotificationShapedBodyLineRemainsCommandOutput() {
        var parser = TmuxControlParser()
        let wire = """
        %begin 1 1 0
        %window-add @5
        %end 1 1 0

        """
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 1, commandNumber: 1, flags: 0),
            .commandOutputLine("%window-add @5"),
            .end(time: 1, commandNumber: 1, flags: 0),
        ])
    }

    func test_commandResponse_bareBeginAndEndRoundTrips() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%begin\n%end\n".utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 0, commandNumber: 0, flags: 0),
            .end(time: 0, commandNumber: 0, flags: 0),
        ])
    }

    // MARK: - Flow control

    func test_pauseContinue_areParsed() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%pause %7\n%continue %7\n".utf8))
        XCTAssertEqual(msgs, [
            .pause(paneId: PaneId(7)),
            .continue(paneId: PaneId(7)),
        ])
    }

    // MARK: - Exit

    func test_exit_withReason() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%exit server exited\n".utf8))
        XCTAssertEqual(msgs, [.exit(reason: "server exited")])
    }

    func test_exit_withoutReason() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%exit\n".utf8))
        XCTAssertEqual(msgs, [.exit(reason: nil)])
    }

    // MARK: - Incremental feeding

    func test_incrementalFeed_holdsPartialLineAcrossCalls() {
        var parser = TmuxControlParser()
        let first = parser.feed(Array("%window-".utf8))
        XCTAssertEqual(first, [])
        let second = parser.feed(Array("add @9\n".utf8))
        XCTAssertEqual(second, [.windowAdd(windowId: WindowId(9))])
    }

    func test_incrementalFeed_multipleMessagesInOneChunk() {
        var parser = TmuxControlParser()
        let chunk = "%window-add @1\n%window-add @2\n%sessions-changed\n"
        let msgs = parser.feed(Array(chunk.utf8))
        XCTAssertEqual(msgs, [
            .windowAdd(windowId: WindowId(1)),
            .windowAdd(windowId: WindowId(2)),
            .sessionsChanged,
        ])
    }

    func test_incrementalFeed_handlesCRLFLineEndings() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%window-add @4\r\n".utf8))
        XCTAssertEqual(msgs, [.windowAdd(windowId: WindowId(4))])
    }

    func test_incrementalFeed_handlesUTF8BoundarySplit() {
        // Split a 3-byte UTF-8 sequence (✓ = E2 9C 93) across two feeds
        // to make sure byte buffering doesn't corrupt it. Since we keep
        // output as raw bytes, this must pass through cleanly even if
        // bytes arrive split mid-character.
        var parser = TmuxControlParser()
        let first = parser.feed(Array("%output %1 ".utf8) + [0xE2, 0x9C])
        XCTAssertEqual(first, [])
        let second = parser.feed([0x93, 0x0A])
        guard case .output(_, let data) = second.first else {
            return XCTFail("expected output after second feed")
        }
        XCTAssertEqual(data, [0xE2, 0x9C, 0x93])
    }

    // MARK: - Unknown messages

    func test_unknownMessage_roundTrips() {
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array("%xyz-unknown foo bar\n".utf8))
        XCTAssertEqual(msgs, [.unknown("%xyz-unknown foo bar")])
    }

    // MARK: - Reset

    func test_reset_clearsBufferAndResponseState() {
        var parser = TmuxControlParser()
        _ = parser.feed(Array("%begin 1 1 0\nhalf-line".utf8))
        parser.reset()
        // After reset, feeding a fresh control message works normally.
        let msgs = parser.feed(Array("%window-add @5\n".utf8))
        XCTAssertEqual(msgs, [.windowAdd(windowId: WindowId(5))])
    }

    func test_reset_midFrameClearsOpenFrameCommandNumber() {
        var parser = TmuxControlParser()
        _ = parser.feed(Array("%begin 999 45 1\npoisoned".utf8))
        parser.reset()

        let wire = """
        %begin 1 2 1
        body
        %end 1 2 1

        """
        let msgs = parser.feed(Array(wire.utf8))
        XCTAssertEqual(msgs, [
            .begin(time: 1, commandNumber: 2, flags: 1),
            .commandOutputLine("body"),
            .end(time: 1, commandNumber: 2, flags: 1),
        ])
    }

    // MARK: - End-to-end fixture

    func test_realWorldTranscript() {
        // Synthetic but plausible transcript: attach triggers a series
        // of window-add notifications and some %output frames.
        let transcript = """
        %sessions-changed
        %session-changed $1 work
        %window-add @1
        %window-add @2
        %window-renamed @1 editor
        %window-pane-changed @1 %1
        %output %1 $ \\033[32mhello\\033[0m\\012
        %output %1 $
        %begin 1700000000 0 0
        1 editor
        2 (unnamed)
        %end 1700000000 0 0

        """
        var parser = TmuxControlParser()
        let msgs = parser.feed(Array(transcript.utf8))

        XCTAssertEqual(msgs.count, 12)
        XCTAssertEqual(msgs[0], .sessionsChanged)
        XCTAssertEqual(msgs[1], .sessionChanged(sessionId: SessionId(1), name: "work"))
        XCTAssertEqual(msgs[2], .windowAdd(windowId: WindowId(1)))
        XCTAssertEqual(msgs[3], .windowAdd(windowId: WindowId(2)))
        XCTAssertEqual(msgs[4], .windowRenamed(windowId: WindowId(1), name: "editor"))
        XCTAssertEqual(
            msgs[5],
            .windowPaneChanged(windowId: WindowId(1), activePaneId: PaneId(1))
        )

        // msgs[6] is the colored output line
        guard case .output(let p6, let d6) = msgs[6] else {
            return XCTFail("expected output at msgs[6]")
        }
        XCTAssertEqual(p6, PaneId(1))
        XCTAssertEqual(
            d6,
            Array("$ ".utf8) + [0x1B, 0x5B, 0x33, 0x32, 0x6D]
                + Array("hello".utf8) + [0x1B, 0x5B, 0x30, 0x6D, 0x0A]
        )

        // msgs[7] is the bare prompt character (no trailing space)
        guard case .output(let p7, let d7) = msgs[7] else {
            return XCTFail("expected output at msgs[7]")
        }
        XCTAssertEqual(p7, PaneId(1))
        XCTAssertEqual(d7, Array("$".utf8))

        XCTAssertEqual(msgs[8], .begin(time: 1700000000, commandNumber: 0, flags: 0))
        XCTAssertEqual(msgs[9], .commandOutputLine("1 editor"))
        XCTAssertEqual(msgs[10], .commandOutputLine("2 (unnamed)"))
        XCTAssertEqual(msgs[11], .end(time: 1700000000, commandNumber: 0, flags: 0))
    }
}
