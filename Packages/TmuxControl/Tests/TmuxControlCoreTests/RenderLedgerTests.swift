import CryptoKit
import Foundation
import XCTest
@testable import TmuxControlCore

final class RenderLedgerTests: XCTestCase {
    private let surface = SurfaceId.live

    func test_platformListReplyCarriesPartsWithoutIntermediateDiagnostics() throws {
        var ledger = TmuxRenderLedger()
        let submission = try XCTUnwrap(ledger.enqueuePlatformCommandList(["display -p a", "display -p b"]))
        XCTAssertEqual(ledger.pendingCommandCount, 1)
        XCTAssertEqual(reply(&ledger, snapshot: snapshot(), lines: ["a"]), [])
        XCTAssertEqual(ledger.pendingCommandCount, 1)
        XCTAssertEqual(reply(&ledger, snapshot: snapshot(), lines: ["b"]), [
            .commandReply(tag: submission.tag, success: true, lines: ["a", "b"],
                parts: [.init(success: true, lines: ["a"]), .init(success: true, lines: ["b"])])
        ])
        XCTAssertEqual(ledger.pendingCommandCount, 0)
    }

    func test_fifoProbeDrainsPartialListWithoutAddingMarkerToParts() throws {
        for commandCount in [2, 3] {
            var ledger = TmuxRenderLedger()
            let state = snapshot()
            _ = beginInline(&ledger, snapshot: state)
            let list = try XCTUnwrap(ledger.enqueuePlatformCommandList(Array(repeating: "display -p a", count: commandCount)))
            let resync = reply(&ledger, snapshot: state, lines: ["not metadata"])
            let marker = RenderCommands.fifoSyncMarker(sequence: 1)
            XCTAssertTrue(containsCommand(resync, RenderCommands.fifoSync(marker: marker)))
            XCTAssertEqual(reply(&ledger, snapshot: state, lines: ["a"]), [])
            let later = ledger.enqueuePlatformCommand("display -p later")
            let realigned = reply(&ledger, snapshot: state, lines: [marker])
            XCTAssertTrue(realigned.contains(.commandReply(tag: list.tag, success: false, lines: ["a"],
                parts: [.init(success: true, lines: ["a"])])))
            XCTAssertEqual(ledger.pendingCommandCount, 1)
            XCTAssertEqual(reply(&ledger, snapshot: state, lines: ["later"]),
                           [.commandReply(tag: later.tag, success: true, lines: ["later"])])
        }
    }

    func test_alreadyConsumedFifoProbeDoesNotConsumeLaterPartialList() throws {
        for commandCount in [2, 3] {
            var ledger = TmuxRenderLedger()
            let state = snapshot()
            _ = beginInline(&ledger, snapshot: state)
            let resync = reply(&ledger, snapshot: state, lines: ["not metadata"])
            let marker = RenderCommands.fifoSyncMarker(sequence: 1)
            XCTAssertTrue(containsCommand(resync, RenderCommands.fifoSync(marker: marker)))
            // Transport drift consumes the probe slot before its real reply.
            _ = reply(&ledger, snapshot: state, lines: [])
            let list = try XCTUnwrap(ledger.enqueuePlatformCommandList(Array(repeating: "display -p a", count: commandCount)))
            XCTAssertEqual(reply(&ledger, snapshot: state, lines: ["a"]), [])
            let later = ledger.enqueuePlatformCommand("display -p later")
            let realigned = reply(&ledger, snapshot: state, lines: [marker])
            XCTAssertFalse(realigned.contains { effect in
                if case .commandReply = effect { return true }
                return false
            }, "an already-consumed probe must not swallow a later list")
            XCTAssertEqual(ledger.pendingCommandCount, 2)
            var effects: [RenderEffect] = []
            for _ in 1..<commandCount { effects = reply(&ledger, snapshot: state, lines: ["a"]) }
            XCTAssertEqual(effects, [.commandReply(tag: list.tag, success: true,
                lines: Array(repeating: "a", count: commandCount),
                parts: Array(repeating: .init(success: true, lines: ["a"]), count: commandCount))])
            XCTAssertEqual(reply(&ledger, snapshot: state, lines: ["later"]),
                           [.commandReply(tag: later.tag, success: true, lines: ["later"])])
        }
    }

    func testSplitColorSurvivesInitialAndForegroundCaptureCuts() throws {
        for alreadyRendered in [false, true] {
            var ledger = TmuxRenderLedger()
            let state = snapshot()
            if alreadyRendered {
                _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["initial"])
            } else { _ = beginInline(&ledger, snapshot: state) }
            let prefix = Array("\u{1B}[38;2;58;58;".utf8)
            XCTAssertTrue(feeds(in: reduceMessage(&ledger,
                .output(paneId: PaneId(1), data: prefix), snapshot: state)).isEmpty)
            if alreadyRendered {
                _ = ledger.reduce(.appBackground, snapshot: state)
                _ = ledger.reduce(.appForeground, snapshot: state)
            }
            _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
            let capture = reply(&ledger, snapshot: state, lines: ["prompt"])
            let request = try XCTUnwrap(resolveRequest(capture))
            let suffix = Array("58;48;2;0;0;30mX".utf8)
            _ = reduceMessage(&ledger, .output(paneId: PaneId(1), data: suffix), snapshot: state)
            let result = ledger.reduce(.surfaceState(surface, request: request,
                altScreen: false, mouseMode: .off, columns: 80, rows: 24), snapshot: state)
            let live = try XCTUnwrap(feeds(in: result).last)
            XCTAssertEqual(live.source, .paneOutput)
            XCTAssertEqual(ledger.renderBytes(for: live.reference), prefix + suffix)
        }
    }

    func test_fastSwitchDropsLateFirstRefreshReply() {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        _ = beginInline(&ledger, snapshot: first)

        let second = snapshot(window: 2, pane: 2)
        let switchEffects = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: second
        )
        XCTAssertTrue(containsCommand(switchEffects, RenderCommands.renderedPaneMetadata(target: WindowId(2))))

        let late = reply(&ledger, snapshot: second, lines: [metadata(pane: 1)])
        XCTAssertEqual(
            late,
            [.diagnostic("render-ledger stale-reply surface=live generation=1 phase=metadata lines=1")]
        )
        XCTAssertNil(ledger.owner(for: surface))

        let current = reply(&ledger, snapshot: second, lines: [metadata(pane: 2)])
        XCTAssertEqual(current, [.sendCommand(RenderCommands.deepPrimary(target: WindowId(2), depth: 2_000))])
    }

    func test_attachReportsPlatformCommandsItCanNoLongerAnswer() {
        var ledger = TmuxRenderLedger()
        let early = ledger.enqueuePlatformCommand("display-message -p ''")

        let attached = ledger.reduce(.transportAttached(.sideChannel), snapshot: snapshot())
        XCTAssertTrue(
            attached.contains(.diagnostic("render-ledger attach discarded-pending-commands count=1")),
            "an adapter that sends ahead of the transport boundary must hear that the reply is gone"
        )
        XCTAssertEqual(ledger.pendingCommandCount, 0)

        // The reply the server still sends for that command drains nothing,
        // and the log says so: an unattributed client reply is the one sign
        // of a FIFO that has lost its place.
        let orphan = correlation(flags: 1, lines: ["@1"])
        XCTAssertEqual(
            ledger.reduce(.correlation(orphan), snapshot: snapshot()),
            [.diagnostic("render-ledger unmatched-reply status=success number=1 lines=1 head=@1")]
        )
        XCTAssertEqual(ledger.pendingCommandCount, 0)

        // A command admitted after the boundary is answered as usual, and a
        // quiet boundary says nothing.
        let quiet = ledger.reduce(.transportAttached(.sideChannel), snapshot: snapshot())
        XCTAssertFalse(quiet.contains { if case .diagnostic(let line) = $0 { return line.contains("discarded-pending") }; return false })
        let late = ledger.enqueuePlatformCommand("display-message -p ''")
        XCTAssertNotEqual(late.tag, early.tag)
        XCTAssertEqual(
            ledger.reduce(.correlation(correlation(flags: 1, lines: [])), snapshot: snapshot()),
            [.commandReply(tag: late.tag, success: true, lines: [])]
        )
    }

    func test_hookFramesDoNotPopTheSharedCommandFIFO() {
        var ledger = TmuxRenderLedger()
        let submission = ledger.enqueuePlatformCommand("display-message -p '#{session_name}'")

        let hook = correlation(flags: 0, lines: ["hook"])
        XCTAssertEqual(ledger.reduce(.correlation(hook), snapshot: snapshot()), [])
        XCTAssertEqual(ledger.pendingCommandCount, 1)

        let client = correlation(flags: 1, lines: ["work"])
        XCTAssertEqual(
            ledger.reduce(.correlation(client), snapshot: snapshot()),
            [.commandReply(tag: submission.tag, success: true, lines: ["work"])]
        )
        XCTAssertEqual(ledger.pendingCommandCount, 0)
    }

    func test_chattyAttachSuppressesOutputUntilTheInitialWatchdogFailsOpen() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        let attached = beginInline(&ledger, snapshot: state)
        guard case .armTimer(let token, _)? = attached.first else {
            return XCTFail("inline attach must arm an initial-render watchdog")
        }

        let suppressed = reduceMessage(
            &ledger,
            .output(paneId: PaneId(1), data: Array("chatty attach".utf8)),
            snapshot: state
        )
        XCTAssertEqual(suppressed, [])
        XCTAssertFalse(ledger.isInitialRenderReady)

        XCTAssertEqual(
            ledger.reduce(.timerFired(token: token), snapshot: state),
            [
                .diagnostic("render-ledger initial-watchdog-fail-open"),
                .initialRenderReady,
            ]
        )
        XCTAssertTrue(ledger.isInitialRenderReady)

        let recovered = reduceMessage(
            &ledger,
            .output(paneId: PaneId(1), data: Array("live after watchdog".utf8)),
            snapshot: state
        )
        XCTAssertTrue(recovered.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertEqual(feeds(in: recovered).map(\.source), [.paneOutput])
    }

    func test_emptyViewportCaptureNeverBindsOverAnEstablishedSurface() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        let initial = finishInitialInline(&ledger, snapshot: state, captureLines: ["old screen"])
        let owner = try! XCTUnwrap(ledger.owner(for: surface))
        XCTAssertTrue(initial.contains { if case .bindSurface = $0 { return true }; return false })

        _ = ledger.reduce(.appBackground, snapshot: state)
        let foreground = ledger.reduce(.appForeground, snapshot: state)
        XCTAssertTrue(containsCommand(foreground, RenderCommands.renderedPaneMetadata(target: WindowId(1))))
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.viewport(target: WindowId(1)))]
        )

        let empty = reply(&ledger, snapshot: state, lines: [])
        XCTAssertFalse(empty.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertTrue(empty.contains { effect in
            if case .diagnostic(let message) = effect {
                return message.contains("viewport-empty")
            }
            return false
        })
        XCTAssertEqual(ledger.owner(for: surface), owner)
    }

    func test_deepStageScrubUsesFreshViewportPayload() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = ledger.reduce(.clientSize(columns: 80, rows: 2), snapshot: state)
        _ = beginInline(&ledger, snapshot: state)

        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000))]
        )
        let deep = reply(&ledger, snapshot: state, lines: ["history one", "history two", "deep screen"])
        XCTAssertEqual(
            deep,
            [
                .sendCommand(RenderCommands.renderedPaneMetadata(target: WindowId(1))),
                .sendCommand(RenderCommands.viewport(target: WindowId(1))),
            ]
        )
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]), [])
        let request = reply(&ledger, snapshot: state, lines: ["fresh viewport"])
        let surfaceRequest = try XCTUnwrap(resolveRequest(request))
        let finished = ledger.reduce(
            .surfaceState(surface, request: surfaceRequest, altScreen: false, mouseMode: .off, columns: 80, rows: 2),
            snapshot: state
        )

        let feeds = feeds(in: finished)
        XCTAssertEqual(feeds.map(\.source), [.deepRepaint, .repaintScrub])
        let deepBytes = try XCTUnwrap(ledger.renderBytes(for: feeds[0].reference))
        let scrubBytes = try XCTUnwrap(ledger.renderBytes(for: feeds[1].reference))
        XCTAssertTrue(String(decoding: deepBytes, as: UTF8.self).contains("history one"))
        XCTAssertFalse(String(decoding: scrubBytes, as: UTF8.self).contains("history one"))
        XCTAssertTrue(String(decoding: scrubBytes, as: UTF8.self).contains("fresh viewport"))
    }

    func test_correlatedDeepRefreshCompletesAfterItsExactFrameEffects() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["initial"])

        let started = ledger.reduce(
            .correlatedRefreshRequested(
                surface,
                stage: .deep,
                reason: "authority-reclaim",
                correlation: 77
            ),
            snapshot: state
        )
        XCTAssertTrue(containsCommand(started, RenderCommands.renderedPaneMetadata(target: WindowId(1))))
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000))]
        )
        let waiting = reply(&ledger, snapshot: state, lines: ["authoritative"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let completed = ledger.reduce(
            .surfaceState(
                surface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 80,
                rows: 24
            ),
            snapshot: state
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        let feedIndex = try XCTUnwrap(completed.firstIndex {
            if case .feed(let id, let feedOwner, _, .deepRepaint) = $0 {
                return id == surface && feedOwner == owner
            }
            return false
        })
        let completionIndex = try XCTUnwrap(completed.firstIndex {
            if case .refreshCompleted(let id, let completedOwner, .deep, 77) = $0 {
                return id == surface && completedOwner == owner
            }
            return false
        })
        XCTAssertLessThan(feedIndex, completionIndex)
    }

    func test_invalidCorrelatedRefreshProducesATerminalFailure() {
        var ledger = TmuxRenderLedger()
        let effects = ledger.reduce(
            .correlatedRefreshRequested(
                surface,
                stage: .deep,
                reason: "authority-reclaim",
                correlation: 0
            ),
            snapshot: snapshot()
        )

        XCTAssertEqual(effects.last, .refreshFailed(
            surface,
            correlation: 0,
            reason: "invalid-correlation"
        ))
    }

    func test_backgroundTerminatesCorrelatedRefreshExactlyOnce() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["initial"])
        _ = ledger.reduce(
            .correlatedRefreshRequested(
                surface,
                stage: .deep,
                reason: "authority-reclaim",
                correlation: 78
            ),
            snapshot: state
        )

        XCTAssertEqual(
            ledger.reduce(.appBackground, snapshot: state),
            [.refreshFailed(surface, correlation: 78, reason: "app-background")]
        )
        XCTAssertFalse(ledger.reduce(.appBackground, snapshot: state).contains {
            if case .refreshFailed = $0 { return true }
            return false
        })
    }

    func test_layoutRefreshSupersedesCorrelatedRefreshWithFailureBeforeReplacement() {
        var ledger = TmuxRenderLedger()
        let initial = singleLayoutSnapshot(columns: 80)
        _ = finishInitialInline(&ledger, snapshot: initial, captureLines: ["initial"])
        _ = ledger.reduce(
            .correlatedRefreshRequested(
                surface,
                stage: .deep,
                reason: "authority-reclaim",
                correlation: 79
            ),
            snapshot: initial
        )

        let resized = singleLayoutSnapshot(columns: 100)
        let effects = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "100x24,0,0,1",
                visibleLayout: "100x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: resized
        )

        let failureIndex = effects.firstIndex {
            $0 == .refreshFailed(surface, correlation: 79, reason: "superseded")
        }
        let replacementIndex = effects.firstIndex {
            if case .sendCommand(let command) = $0 {
                return command == RenderCommands.renderedPaneMetadata(target: WindowId(1))
            }
            return false
        }
        XCTAssertNotNil(failureIndex)
        XCTAssertNotNil(replacementIndex)
        XCTAssertLessThan(try! XCTUnwrap(failureIndex), try! XCTUnwrap(replacementIndex))
    }

    func test_correlatedRefreshRetryExhaustionProducesOneTerminalFailure() throws {
        var ledger = TmuxRenderLedger(
            configuration: .init(maximumDeepRetryAttempts: 1)
        )
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["initial"])
        _ = ledger.reduce(
            .correlatedRefreshRequested(
                surface,
                stage: .deep,
                reason: "authority-reclaim",
                correlation: 80
            ),
            snapshot: state
        )

        let firstFailure = failedReply(&ledger, snapshot: state, lines: ["capture failed"])
        let retryToken = try XCTUnwrap(firstFailure.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first)
        _ = ledger.reduce(.timerFired(token: retryToken), snapshot: state)
        let exhausted = failedReply(&ledger, snapshot: state, lines: ["capture failed again"])

        XCTAssertTrue(exhausted.contains {
            if case .refreshFailed(let id, 80, let reason) = $0 {
                return id == surface && reason.hasPrefix("retry-exhausted:")
            }
            return false
        })
        XCTAssertFalse(failedReply(&ledger, snapshot: state, lines: []).contains {
            if case .refreshFailed = $0 { return true }
            return false
        })
    }

    func test_correlatedRefreshSizeResyncExhaustionFailsWithoutRepeating() throws {
        var ledger = TmuxRenderLedger(
            configuration: .init(maximumSizeResyncAttempts: 1)
        )
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["initial"])
        _ = ledger.reduce(.clientSize(columns: 80, rows: 24), snapshot: state)
        _ = reply(&ledger, snapshot: state, lines: [])
        _ = reply(&ledger, snapshot: state, lines: [])
        _ = ledger.reduce(
            .correlatedRefreshRequested(
                surface,
                stage: .deep,
                reason: "authority-reclaim",
                correlation: 81
            ),
            snapshot: state
        )
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])

        _ = ledger.reduce(.clientSize(columns: 81, rows: 24), snapshot: state)
        let firstRequest = try XCTUnwrap(resolveRequest(
            reply(&ledger, snapshot: state, lines: ["first capture"])
        ))
        _ = ledger.reduce(
            .surfaceState(
                surface,
                request: firstRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 81,
                rows: 24
            ),
            snapshot: state
        )
        _ = reply(&ledger, snapshot: state, lines: [])
        _ = reply(&ledger, snapshot: state, lines: [])
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])

        _ = ledger.reduce(.clientSize(columns: 82, rows: 24), snapshot: state)
        let finalRequest = try XCTUnwrap(resolveRequest(
            reply(&ledger, snapshot: state, lines: ["second capture"])
        ))
        let exhausted = ledger.reduce(
            .surfaceState(
                surface,
                request: finalRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 82,
                rows: 24
            ),
            snapshot: state
        )

        XCTAssertTrue(exhausted.contains {
            $0 == .refreshFailed(surface, correlation: 81, reason: "size-resync-exhausted")
        })
        XCTAssertTrue(ledger.hasPendingRender)
        XCTAssertFalse(ledger.reduce(
            .surfaceState(
                surface,
                request: finalRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 82,
                rows: 24
            ),
            snapshot: state
        ).contains {
            if case .refreshFailed = $0 { return true }
            return false
        })
    }

    func test_outputAfterCaptureReplyWaitsForAndFollowsAuthoritativeFrame() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = beginInline(&ledger, snapshot: state)
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000))]
        )

        let waiting = reply(&ledger, snapshot: state, lines: ["captured frame"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        XCTAssertEqual(
            reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("after-cut".utf8)),
                snapshot: state
            ),
            [],
            "post-capture output must wait behind the unresolved authoritative frame"
        )

        let finished = ledger.reduce(
            .surfaceState(
                surface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 80,
                rows: 24
            ),
            snapshot: state
        )
        let delivered = feeds(in: finished)
        XCTAssertEqual(delivered.map(\.source), [.deepRepaint, .paneOutput])
        XCTAssertTrue(
            String(decoding: try XCTUnwrap(ledger.renderBytes(for: delivered[0].reference)), as: UTF8.self)
                .contains("captured frame")
        )
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(ledger.renderBytes(for: delivered[1].reference)), as: UTF8.self),
            "after-cut"
        )
    }

    func test_emptyPaneOutputHasNoRenderOrSideChannelStateEffect() throws {
        var inline = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&inline, snapshot: state, captureLines: ["initial"])
        XCTAssertEqual(
            reduceMessage(&inline, .output(paneId: PaneId(1), data: []), snapshot: state),
            []
        )

        var sideChannel = TmuxRenderLedger(
            configuration: .init(moshPageDepth: 2)
        )
        _ = finishSideChannelHistory(
            &sideChannel,
            snapshot: state,
            historySize: 10,
            captureLines: ["history", "live"],
            depth: 2
        )
        XCTAssertEqual(
            reduceMessage(&sideChannel, .output(paneId: PaneId(1), data: []), snapshot: state),
            []
        )
    }

    func test_foregroundSameIdentityRefreshesInPlaceWithoutBindOrHistoryReplay() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["initial"])
        let owner = try XCTUnwrap(ledger.owner(for: surface))

        _ = ledger.reduce(.appBackground, snapshot: state)
        let start = ledger.reduce(.appForeground, snapshot: state)
        XCTAssertTrue(containsCommand(start, RenderCommands.renderedPaneMetadata(target: WindowId(1))))
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.viewport(target: WindowId(1)))]
        )
        let waiting = reply(&ledger, snapshot: state, lines: ["in place"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let effects = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: state
        )

        XCTAssertFalse(effects.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertFalse(containsCommand(effects, RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000)))
        XCTAssertEqual(feeds(in: effects).map(\.source), [.viewportRefresh])
        XCTAssertEqual(ledger.owner(for: surface), owner)
    }

    func test_foregroundIdentityChangeFallsBackToRebuildAndBind() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        _ = finishInitialInline(&ledger, snapshot: first, captureLines: ["first"])
        let firstOwner = try XCTUnwrap(ledger.owner(for: surface))

        _ = ledger.reduce(.appBackground, snapshot: first)
        let second = snapshot(window: 2, pane: 2)
        let start = ledger.reduce(.appForeground, snapshot: second)
        XCTAssertTrue(containsCommand(start, RenderCommands.renderedPaneMetadata(target: WindowId(2))))
        XCTAssertEqual(
            reply(&ledger, snapshot: second, lines: [metadata(pane: 2)]),
            [.sendCommand(RenderCommands.viewport(target: WindowId(2)))]
        )
        let waiting = reply(&ledger, snapshot: second, lines: ["second"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let effects = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: second
        )

        XCTAssertTrue(effects.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertTrue(containsCommand(effects, RenderCommands.renderedPaneMetadata(target: WindowId(2))))
        let viewportFeed = try XCTUnwrap(feeds(in: effects).first)
        XCTAssertNotNil(
            ledger.renderBytes(for: viewportFeed.reference),
            "chaining the deep stage must not evict the viewport feed before the platform consumes it"
        )
        let secondOwner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertNotEqual(secondOwner, firstOwner)
        XCTAssertEqual(secondOwner.windowID, WindowId(2))
        XCTAssertEqual(secondOwner.paneID, PaneId(2))
    }

    func test_displaySwapSaveBindFeedRestoreOrderingAndAltStateSurviveAbortedRetry() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        _ = finishInitialInline(&ledger, snapshot: first, captureLines: ["window one"])
        let priorOwner = try XCTUnwrap(ledger.owner(for: surface))

        let second = snapshot(window: 2, pane: 2, alternateScreen: true)
        XCTAssertTrue(containsCommand(
            reduceMessage(
                &ledger,
                .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
                snapshot: second
            ),
            RenderCommands.renderedPaneMetadata(target: WindowId(2))
        ))

        let aborted = failedReply(&ledger, snapshot: second, lines: ["can't find pane"])
        let retryToken = try XCTUnwrap(aborted.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first)
        XCTAssertFalse(aborted.contains { if case .saveWindowModes = $0 { return true }; return false })
        XCTAssertFalse(aborted.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertEqual(
            ledger.owner(for: surface),
            priorOwner,
            "the aborted transition must retain its from-owner for the eventual display swap"
        )

        XCTAssertTrue(containsCommand(
            ledger.reduce(.timerFired(token: retryToken), snapshot: second),
            RenderCommands.renderedPaneMetadata(target: WindowId(2))
        ))
        XCTAssertEqual(ledger.owner(for: surface), priorOwner)
        XCTAssertEqual(
            reply(&ledger, snapshot: second, lines: [metadata(pane: 2, alt: true)]),
            [.sendCommand(RenderCommands.viewport(target: WindowId(2)))]
        )
        let request = try XCTUnwrap(resolveRequest(reply(&ledger, snapshot: second, lines: ["window two alt viewport"])))
        let completed = ledger.reduce(
            .surfaceState(
                surface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 80,
                rows: 24
            ),
            snapshot: second
        )
        let rebound = try XCTUnwrap(ledger.owner(for: surface))

        let saveIndex = try XCTUnwrap(completed.firstIndex {
            if case .saveWindowModes(let id, let window) = $0 {
                return id == surface && window == WindowId(1)
            }
            return false
        })
        let bindIndex = try XCTUnwrap(completed.firstIndex {
            if case .bindSurface(let id, let owner) = $0 {
                return id == surface && owner == rebound
            }
            return false
        })
        let feedIndex = try XCTUnwrap(completed.firstIndex {
            if case .feed(let id, let owner, _, .viewportRepaint) = $0 {
                return id == surface && owner == rebound
            }
            return false
        })
        let restoreIndex = try XCTUnwrap(completed.firstIndex {
            if case .restoreWindowModes(let id, let window, let paneInAltScreen) = $0 {
                return id == surface && window == WindowId(2) && paneInAltScreen
            }
            return false
        })
        let deepChainIndex = try XCTUnwrap(completed.firstIndex {
            containsCommand([$0], RenderCommands.renderedPaneMetadata(target: WindowId(2)))
        })

        XCTAssertEqual(rebound.windowID, WindowId(2))
        XCTAssertEqual(rebound.paneID, PaneId(2))
        XCTAssertLessThan(saveIndex, bindIndex, "the previous window's modes must be saved before the display transition")
        XCTAssertLessThan(bindIndex, feedIndex, "the adapter observes the display transition before terminal bytes arrive")
        XCTAssertLessThan(feedIndex, restoreIndex, "the target's saved modes restore only after its authoritative frame")
        XCTAssertLessThan(restoreIndex, deepChainIndex, "the follow-up history rebuild starts only after the target restore")
    }

    func test_foregroundGridBarrierWaitsForEveryDeclaredSurfaceToBind() throws {
        let paneOneSurface = SurfaceId("pane-1")
        let paneTwoSurface = SurfaceId("pane-2")
        let state = gridSnapshot()
        var ledger = TmuxRenderLedger()

        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        _ = ledger.reduce(.appBackground, snapshot: state)
        _ = ledger.reduce(.appForeground, snapshot: state)

        _ = ledger.reduce(.surfacesDeclared([
            .init(
                surfaceID: paneOneSurface,
                presentation: .grid,
                windowID: WindowId(1),
                paneID: PaneId(1)
            ),
            .init(
                surfaceID: paneTwoSurface,
                presentation: .grid,
                windowID: WindowId(1),
                paneID: PaneId(2)
            ),
        ]), snapshot: state)
        XCTAssertTrue(containsCommand(
            ledger.reduce(.refreshRequested(paneOneSurface, stage: .deep, reason: "mount"), snapshot: state),
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        XCTAssertTrue(containsCommand(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            RenderCommands.deepPrimary(target: PaneId(1), depth: 2_000)
        ))
        let firstSettle = reply(&ledger, snapshot: state, lines: ["pane one"])
        XCTAssertTrue(containsCommand(firstSettle, RenderCommands.renderedPaneMetadata(target: PaneId(1))))
        XCTAssertTrue(containsCommand(firstSettle, RenderCommands.viewport(target: PaneId(1))))
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]), [])
        let firstWaiting = reply(&ledger, snapshot: state, lines: ["pane one viewport"])
        let firstRequest = try XCTUnwrap(resolveRequest(firstWaiting, surfaceID: paneOneSurface))
        _ = ledger.reduce(
            .surfaceState(
                paneOneSurface,
                request: firstRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 40,
                rows: 24
            ),
            snapshot: state
        )

        XCTAssertTrue(ledger.hasPendingRender, "the foreground barrier must wait for every declared grid surface")
        XCTAssertEqual(
            reduceMessage(&ledger, .output(paneId: PaneId(1), data: Array("held".utf8)), snapshot: state),
            [],
            "output must remain coalesced until every authoritative grid surface is bound"
        )

        XCTAssertTrue(containsCommand(
            ledger.reduce(.refreshRequested(paneTwoSurface, stage: .deep, reason: "mount"), snapshot: state),
            RenderCommands.renderedPaneMetadata(target: PaneId(2))
        ))
        XCTAssertTrue(containsCommand(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 2)]),
            RenderCommands.deepPrimary(target: PaneId(2), depth: 2_000)
        ))
        let secondSettle = reply(&ledger, snapshot: state, lines: ["pane two"])
        XCTAssertTrue(containsCommand(secondSettle, RenderCommands.renderedPaneMetadata(target: PaneId(2))))
        XCTAssertTrue(containsCommand(secondSettle, RenderCommands.viewport(target: PaneId(2))))
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: [metadata(pane: 2)]), [])
        let secondWaiting = reply(&ledger, snapshot: state, lines: ["pane two viewport"])
        let secondRequest = try XCTUnwrap(resolveRequest(secondWaiting, surfaceID: paneTwoSurface))
        let secondFinished = ledger.reduce(
            .surfaceState(
                paneTwoSurface,
                request: secondRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 40,
                rows: 24
            ),
            snapshot: state
        )

        XCTAssertFalse(ledger.hasPendingRender)
        let heldReplay = try XCTUnwrap(secondFinished.compactMap { effect -> RenderBytesRef? in
            guard case .feed(let id, _, let reference, .foregroundReplay) = effect,
                  id == paneOneSurface
            else { return nil }
            return reference
        }.first)
        XCTAssertEqual(String(decoding: try XCTUnwrap(ledger.renderBytes(for: heldReplay)), as: UTF8.self), "held")
        XCTAssertEqual(
            feeds(in: reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("live".utf8)),
                snapshot: state
            )).map(\.source),
            [.paneOutput]
        )
    }

    func test_foregroundGridOverflowAfterOnePaneSettlesRecapturesThatPaneBeforeRelease() throws {
        let paneOneSurface = SurfaceId("pane-1")
        let paneTwoSurface = SurfaceId("pane-2")
        let state = gridSnapshot()
        var ledger = TmuxRenderLedger(configuration: .init(
            maximumForegroundOutputBytes: 4
        ))

        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        _ = ledger.reduce(.appBackground, snapshot: state)
        _ = ledger.reduce(.appForeground, snapshot: state)
        _ = ledger.reduce(.surfacesDeclared([
            .init(
                surfaceID: paneOneSurface,
                presentation: .grid,
                windowID: WindowId(1),
                paneID: PaneId(1)
            ),
            .init(
                surfaceID: paneTwoSurface,
                presentation: .grid,
                windowID: WindowId(1),
                paneID: PaneId(2)
            ),
        ]), snapshot: state)

        _ = ledger.reduce(
            .refreshRequested(paneOneSurface, stage: .deep, reason: "mount"),
            snapshot: state
        )
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        _ = reply(&ledger, snapshot: state, lines: ["pane one deep"])
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let paneOneViewport = reply(
            &ledger,
            snapshot: state,
            lines: ["pane one viewport"]
        )
        let paneOneRequest = try XCTUnwrap(resolveRequest(
            paneOneViewport,
            surfaceID: paneOneSurface
        ))
        _ = ledger.reduce(
            .surfaceState(
                paneOneSurface,
                request: paneOneRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 40,
                rows: 24
            ),
            snapshot: state
        )

        XCTAssertEqual(
            reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("overflow".utf8)),
                snapshot: state
            ),
            []
        )

        _ = ledger.reduce(
            .refreshRequested(paneTwoSurface, stage: .deep, reason: "mount"),
            snapshot: state
        )
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 2)])
        _ = reply(&ledger, snapshot: state, lines: ["pane two deep"])
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 2)])
        let paneTwoViewport = reply(
            &ledger,
            snapshot: state,
            lines: ["pane two viewport"]
        )
        let paneTwoRequest = try XCTUnwrap(resolveRequest(
            paneTwoViewport,
            surfaceID: paneTwoSurface
        ))
        let paneTwoFinished = ledger.reduce(
            .surfaceState(
                paneTwoSurface,
                request: paneTwoRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 40,
                rows: 24
            ),
            snapshot: state
        )

        XCTAssertTrue(containsCommand(
            paneTwoFinished,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        XCTAssertEqual(ledger.pendingStage(for: paneOneSurface), .viewportOnly)
        XCTAssertEqual(ledger.pendingReason(for: paneOneSurface), "app-foreground-overflow")

        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.viewport(target: PaneId(1)))]
        )
        let recoveredViewport = reply(
            &ledger,
            snapshot: state,
            lines: ["pane one recovered"]
        )
        let recoveredRequest = try XCTUnwrap(resolveRequest(
            recoveredViewport,
            surfaceID: paneOneSurface
        ))
        XCTAssertEqual(
            reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("tail".utf8)),
                snapshot: state
            ),
            [],
            "bytes beyond the recapture FIFO cut wait for its authoritative frame"
        )
        let recovered = ledger.reduce(
            .surfaceState(
                paneOneSurface,
                request: recoveredRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 40,
                rows: 24
            ),
            snapshot: state
        )

        XCTAssertEqual(
            feeds(in: recovered).map(\.source),
            [.viewportRefresh, .paneOutput],
            "post-capture output must follow the recaptured viewport instead of disappearing into the saturated coalescer"
        )
        XCTAssertFalse(ledger.hasPendingRender)
        XCTAssertEqual(
            feeds(in: reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("live".utf8)),
                snapshot: state
            )).map(\.source),
            [.paneOutput]
        )
    }

    func test_foregroundGridOverflowRetryExhaustionStopsFailClosed() throws {
        var (ledger, state, paneOneSurface) = makeForegroundGridOverflowRecapture(
            maximumViewportRetryAttempts: 1
        )

        let firstFailure = failedReply(
            &ledger,
            snapshot: state,
            lines: ["capture failed"]
        )
        let retryToken = try XCTUnwrap(firstFailure.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first)
        XCTAssertTrue(containsCommand(
            ledger.reduce(.timerFired(token: retryToken), snapshot: state),
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))

        let exhausted = failedReply(
            &ledger,
            snapshot: state,
            lines: ["capture failed again"]
        )
        XCTAssertTrue(exhausted.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("refresh-gave-up")
        })
        XCTAssertFalse(exhausted.contains { effect in
            if case .sendCommand = effect { return true }
            if case .armTimer = effect { return true }
            return false
        })
        XCTAssertTrue(ledger.hasPendingRender)
        XCTAssertEqual(
            ledger.pendingReason(for: paneOneSurface),
            "app-foreground-overflow"
        )
        let afterExhaustion = failedReply(&ledger, snapshot: state, lines: [])
        XCTAssertFalse(
            afterExhaustion.contains { effect in
                if case .diagnostic = effect { return false }
                return true
            },
            "the terminal failed state must not restart the overflow capture loop"
        )
    }

    func test_foregroundPostCaptureOverflowResyncExhaustionStopsFailClosed() throws {
        var (ledger, state, paneOneSurface) = makeForegroundGridOverflowRecapture(
            maximumViewportRetryAttempts: 1
        )

        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.viewport(target: PaneId(1)))]
        )
        let captured = reply(
            &ledger,
            snapshot: state,
            lines: ["pane one recaptured"]
        )
        let request = try XCTUnwrap(resolveRequest(
            captured,
            surfaceID: paneOneSurface
        ))
        let overflow = reduceMessage(
            &ledger,
            .output(paneId: PaneId(1), data: Array("extra".utf8)),
            snapshot: state
        )
        XCTAssertTrue(overflow.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("post-capture-output-overflow")
        })

        let resync = ledger.reduce(
            .surfaceState(
                paneOneSurface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 40,
                rows: 24
            ),
            snapshot: state
        )
        XCTAssertTrue(containsCommand(
            resync,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        XCTAssertEqual(
            ledger.pendingReason(for: paneOneSurface),
            "post-capture-output-resync"
        )

        let firstFailure = failedReply(&ledger, snapshot: state, lines: ["failed"])
        let retryToken = try XCTUnwrap(firstFailure.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first)
        _ = ledger.reduce(.timerFired(token: retryToken), snapshot: state)
        let exhausted = failedReply(
            &ledger,
            snapshot: state,
            lines: ["failed again"]
        )

        XCTAssertFalse(exhausted.contains { effect in
            if case .sendCommand = effect { return true }
            if case .armTimer = effect { return true }
            return false
        })
        XCTAssertTrue(ledger.hasPendingRender)
        XCTAssertEqual(
            ledger.pendingReason(for: paneOneSurface),
            "post-capture-output-resync"
        )
    }

    func test_foregroundPostCaptureOutputSharesTheSessionWideByteCap() throws {
        let paneOneSurface = SurfaceId("pane-1")
        let paneTwoSurface = SurfaceId("pane-2")
        let state = gridSnapshot()
        var ledger = TmuxRenderLedger(configuration: .init(
            maximumForegroundOutputBytes: 4
        ))

        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        _ = ledger.reduce(.appBackground, snapshot: state)
        _ = ledger.reduce(.appForeground, snapshot: state)
        _ = ledger.reduce(.surfacesDeclared([
            .init(
                surfaceID: paneOneSurface,
                presentation: .grid,
                windowID: WindowId(1),
                paneID: PaneId(1)
            ),
            .init(
                surfaceID: paneTwoSurface,
                presentation: .grid,
                windowID: WindowId(1),
                paneID: PaneId(2)
            ),
        ]), snapshot: state)
        _ = ledger.reduce(
            .refreshRequested(paneOneSurface, stage: .deep, reason: "mount"),
            snapshot: state
        )
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        _ = reply(&ledger, snapshot: state, lines: ["pane one deep"])
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let waiting = reply(
            &ledger,
            snapshot: state,
            lines: ["pane one viewport"]
        )
        XCTAssertNotNil(resolveRequest(waiting, surfaceID: paneOneSurface))

        XCTAssertEqual(
            reduceMessage(
                &ledger,
                .output(paneId: PaneId(2), data: Array("held".utf8)),
                snapshot: state
            ),
            []
        )
        let overflow = reduceMessage(
            &ledger,
            .output(paneId: PaneId(1), data: Array("x".utf8)),
            snapshot: state
        )
        XCTAssertTrue(overflow.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("post-capture-output-overflow")
        })
    }

    func test_inlineReattachToTheSamePaneStartsFreshDeepRebuildUnderANewEpoch() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["before reconnect"])
        let prior = try XCTUnwrap(ledger.owner(for: surface))

        _ = ledger.reduce(.transportLost, snapshot: state)
        let attached = ledger.reduce(.transportAttached(.inline), snapshot: state)

        XCTAssertEqual(
            attached.filter { containsCommand([$0], RenderCommands.renderedPaneMetadata(target: WindowId(1))) }.count,
            1,
            "same-identity reattach is still a continuity break, not an in-place refresh"
        )
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000))]
        )

        let waiting = reply(&ledger, snapshot: state, lines: ["after reconnect"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let finished = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: state
        )
        let rebound = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertNotEqual(rebound.epoch, prior.epoch)
        XCTAssertTrue(finished.contains { effect in
            if case .bindSurface(let id, let owner) = effect { return id == surface && owner == rebound }
            return false
        })
        XCTAssertEqual(feeds(in: finished).map(\.source), [.deepRepaint])
    }

    func test_sideChannelReattachClearsParkedHistoryUnderANewEpochWithoutCapture() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 30,
            captureLines: ["parked history", "live viewport"]
        )
        let prior = try XCTUnwrap(ledger.owner(for: surface))

        _ = ledger.reduce(.transportLost, snapshot: state)
        let attached = ledger.reduce(.transportAttached(.sideChannel), snapshot: state)

        XCTAssertFalse(attached.contains { if case .sendCommand = $0 { return true }; return false })
        let bound = try XCTUnwrap(attached.compactMap { effect -> RenderOwner? in
            guard case .bindSurface(let id, let owner) = effect, id == surface else { return nil }
            return owner
        }.first)
        XCTAssertEqual(bound.windowID, prior.windowID)
        XCTAssertEqual(bound.paneID, prior.paneID)
        XCTAssertNotEqual(bound.epoch, prior.epoch)
        XCTAssertEqual(ledger.owner(for: surface), bound)
    }

    func test_inlineGeometryOnlyLayoutChangeRebuildsUnderFreshOwner() throws {
        var ledger = TmuxRenderLedger()
        let initial = singleLayoutSnapshot(columns: 80)
        _ = finishInitialInline(&ledger, snapshot: initial, captureLines: ["before relayout"])
        let prior = try XCTUnwrap(ledger.owner(for: surface))
        let resized = singleLayoutSnapshot(columns: 100)

        let started = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "100x24,0,0,1",
                visibleLayout: "100x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: resized
        )

        XCTAssertTrue(containsCommand(
            started,
            RenderCommands.renderedPaneMetadata(target: WindowId(1))
        ))
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
        XCTAssertEqual(ledger.pendingReason(for: surface), "layout-change")
        XCTAssertEqual(
            reply(&ledger, snapshot: resized, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000))]
        )
        let deep = reply(&ledger, snapshot: resized, lines: ["after relayout"])
        let request = try XCTUnwrap(resolveRequest(deep))
        let finished = ledger.reduce(
            .surfaceState(
                surface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 100,
                rows: 24
            ),
            snapshot: resized
        )
        let current = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertNotEqual(current.epoch, prior.epoch)
        XCTAssertTrue(finished.contains { effect in
            if case .bindSurface(let id, let owner) = effect {
                return id == surface && owner == current
            }
            return false
        })
        XCTAssertEqual(feeds(in: finished).map(\.source), [.deepRepaint])
    }

    func test_inlineDuplicateLayoutNotificationDoesNotSupersedeForegroundViewportRefresh() throws {
        var ledger = TmuxRenderLedger()
        let state = singleLayoutSnapshot(columns: 80)
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["before background"])
        let owner = try XCTUnwrap(ledger.owner(for: surface))

        _ = ledger.reduce(.appBackground, snapshot: state)
        let foreground = ledger.reduce(.appForeground, snapshot: state)
        XCTAssertTrue(containsCommand(
            foreground,
            RenderCommands.renderedPaneMetadata(target: WindowId(1))
        ))
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewportOnly)

        let duplicate = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "80x24,0,0,1",
                visibleLayout: "80x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: state
        )

        XCTAssertEqual(duplicate, [])
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewportOnly)
        XCTAssertEqual(ledger.pendingReason(for: surface), "app-foreground")
        XCTAssertEqual(ledger.owner(for: surface), owner)
    }

    func test_sideChannelLayoutChangeRebindsRestartsRenderedHistoryAndRequestsFullFrame() throws {
        var ledger = TmuxRenderLedger()
        let initial = gridSnapshot()
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: initial,
            historySize: 30,
            captureLines: ["old wrapped history", "old viewport"]
        )
        let prior = try XCTUnwrap(ledger.owner(for: surface))
        let resized = gridSnapshot(firstWidth: 50, secondWidth: 49, totalWidth: 100)

        let effects = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "100x24,0,0{50x24,0,0,1,49x24,51,0,2}",
                visibleLayout: "100x24,0,0{50x24,0,0,1,49x24,51,0,2}",
                rawFlags: "*"
            ),
            snapshot: resized
        )

        let rebound = try XCTUnwrap(effects.compactMap { effect -> RenderOwner? in
            guard case .bindSurface(let id, let owner) = effect, id == surface else { return nil }
            return owner
        }.last)
        XCTAssertNotEqual(rebound.epoch, prior.epoch)
        XCTAssertEqual(ledger.owner(for: surface), rebound)
        XCTAssertTrue(effects.contains(.requestTransportFullFrame))
        XCTAssertTrue(containsCommand(
            effects,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
    }

    func test_sideChannelDuplicateLayoutPreservesHistoryAndAuthorityFrameReservation() throws {
        var ledger = TmuxRenderLedger()
        let state = gridSnapshot()
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30, captureLines: ["history", "live"])
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        _ = ledger.reduce(.correlatedTransportFullFrameRequested(surface, reason: "authority-reclaim", correlation: 31))

        for _ in 0..<20 {
            XCTAssertEqual(reduceMessage(&ledger, .layoutChange(
                windowId: WindowId(1),
                layout: "80x24,0,0{40x24,0,0,1,39x24,41,0,2}",
                visibleLayout: "80x24,0,0{40x24,0,0,1,39x24,41,0,2}",
                rawFlags: "*"
            ), snapshot: state), [])
        }
        XCTAssertEqual(ledger.owner(for: surface), owner)
        XCTAssertEqual(ledger.reduce(.transportFullFramePresented(surface, owner: owner, correlation: 31)), [])
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: owner)), [
            .diagnostic("render-ledger side-channel-frozen surface=live"),
        ], "duplicate echoes must preserve the revealed page")
        let returned = ledger.reduce(.scrollbackReturnedToTail(surface))
        let tailOwner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertTrue(returned.contains(.requestCorrelatedTransportFullFrame(
            surface, owner: tailOwner, correlation: 31, reason: "authority-reclaim")))
        XCTAssertEqual(ledger.reduce(.transportFullFramePresented(surface, owner: tailOwner, correlation: 31)), [
            .transportFullFrameCompleted(surface, owner: tailOwner, correlation: 31),
        ])
    }

    func test_sideChannelSizeBeforeHydrationEstablishesFirstOwnerWithoutLayoutEcho() throws {
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.surfacesDeclared([.init(surfaceID: surface, presentation: .single)]))
        _ = ledger.reduce(.transportAttached(.sideChannel))
        _ = ledger.reduce(.clientSize(columns: 80, rows: 24))
        XCTAssertNil(ledger.owner(for: surface))
        _ = ledger.reduce(.correlatedTransportFullFrameRequested(surface, reason: "initial-attach", correlation: 31))

        let state = singleLayoutSnapshot(columns: 80)
        let hydrated = ledger.synchronize(snapshot: state)
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertTrue(hydrated.contains(.bindSurface(surface, owner: owner)))
        XCTAssertTrue(hydrated.contains(.requestCorrelatedTransportFullFrame(
            surface, owner: owner, correlation: 31, reason: "initial-attach")))
        XCTAssertEqual(reduceMessage(&ledger, .layoutChange(
            windowId: WindowId(1), layout: "80x24,0,0,1", visibleLayout: "80x24,0,0,1", rawFlags: "*"
        ), snapshot: state), [])
        XCTAssertEqual(ledger.owner(for: surface), owner)
        XCTAssertEqual(ledger.reduce(.transportFullFramePresented(surface, owner: owner, correlation: 31)), [
            .transportFullFrameCompleted(surface, owner: owner, correlation: 31),
        ])
    }

    func test_sideChannelLateSingleSurfaceBindsAlreadyHydratedSizedPainter() throws {
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.clientSize(columns: 80, rows: 24))
        _ = ledger.reduce(.transportAttached(.sideChannel))
        let state = singleLayoutSnapshot(columns: 80)
        XCTAssertEqual(ledger.synchronize(snapshot: state), [])

        let mounted = ledger.reduce(.surfacesDeclared([
            .init(surfaceID: surface, presentation: .single),
        ]))
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(mounted, [.bindSurface(surface, owner: owner)])
        XCTAssertEqual(owner.windowID, WindowId(1))
        XCTAssertEqual(owner.paneID, PaneId(1))
        XCTAssertEqual(reduceMessage(&ledger, .layoutChange(
            windowId: WindowId(1), layout: "80x24,0,0,1", visibleLayout: "80x24,0,0,1", rawFlags: "*"
        ), snapshot: state), [])
        XCTAssertEqual(ledger.owner(for: surface), owner)
    }

    func test_sideChannelHiddenPaneDeepenKeepsPageWithoutMoshPainterActivity() throws {
        var ledger = TmuxRenderLedger(configuration: .init(moshPageDepth: 3, scrollbackLimit: 8))
        let grid = gridSnapshot()
        let window = try XCTUnwrap(grid.windows.first)
        let state = TmuxSnapshot(sessionID: grid.sessionID, sessionName: grid.sessionName,
            activeWindowID: grid.activeWindowID, windows: [.init(
                id: window.id, name: window.name, activePaneID: PaneId(1), panes: window.panes,
                layout: window.layout, visibleLayout: singleLayoutSnapshot(columns: 80).windows.first?.layout,
                isZoomed: true
            )], authority: .unknown)
        let hidden = SurfaceId("overlay-2")
        _ = ledger.reduce(.surfacesDeclared([
            .init(surfaceID: surface, presentation: .single),
            .init(surfaceID: hidden, presentation: .overlay, windowID: WindowId(1), paneID: PaneId(2)),
        ]), snapshot: state)
        _ = ledger.reduce(.transportAttached(.sideChannel), snapshot: state)
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 20,
            captureLines: ["old-a", "old-b", "old-c", "old-live-a", "old-live-b"], depth: 3,
            surfaceID: hidden, paneID: PaneId(2))
        // Pane 2 is outside the zoomed painter. Its output advances history
        // without any SSP frame or control %output arriving at the device.
        let started = ledger.reduce(.scrollbackRequested(hidden, pointsY: 1, isInertial: false))
        XCTAssertTrue(containsCommand(started, RenderCommands.moshHistory(target: PaneId(2), depth: 8)))
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 2, historySize: 22)])
        let waiting = reply(&ledger, snapshot: state, lines: ["older-a", "older-b", "older-c",
            "old-a", "old-b", "old-c", "old-live-a", "old-live-b", "new-live-a", "new-live-b"])
        let request = try XCTUnwrap(resolveRequest(waiting, surfaceID: hidden))
        let finished = ledger.reduce(.surfaceState(hidden, request: request, altScreen: false,
            mouseMode: .off, columns: 80, rows: 24))
        XCTAssertTrue(finished.contains(.diagnostic(
            "render-ledger side-channel-anchored-deepen surface=overlay-2 dropped=2 expected=2 anchor=page")))
        let reference = try XCTUnwrap(feeds(in: finished).first { $0.source == .moshHistory }?.reference)
        let rendered = String(decoding: try XCTUnwrap(ledger.renderBytes(for: reference)), as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            .map(TmuxRenderLedger.SideChannelHistoryAnchor.text(of:)).filter { !$0.isEmpty }
        XCTAssertEqual(rendered, ["older-a", "older-b", "older-c", "old-a", "old-b", "old-c", "old-live-a", "old-live-b"])
    }

    func test_transportActivityRequiresExactCurrentOwnerAndSideChannelProfile() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30, captureLines: ["history", "live"])
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        for stale in [
            RenderOwner(windowID: owner.windowID, paneID: owner.paneID, epoch: owner.epoch + 1),
            RenderOwner(windowID: WindowId(2), paneID: owner.paneID, epoch: owner.epoch),
            RenderOwner(windowID: owner.windowID, paneID: PaneId(2), epoch: owner.epoch),
        ] {
            XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: stale)), [])
        }
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(SurfaceId("unmounted"), owner: owner)), [])
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: owner),
            snapshot: snapshot(window: 2, pane: 2)), [], "an exact owner for a departed window cannot report activity")
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: owner), snapshot: state), [
            .diagnostic("render-ledger side-channel-frozen surface=live"),
        ])
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: owner)), [])

        var inline = TmuxRenderLedger()
        _ = finishInitialInline(&inline, snapshot: state, captureLines: ["inline"])
        let inlineOwner = try XCTUnwrap(inline.owner(for: surface))
        XCTAssertEqual(inline.reduce(.transportOutputObserved(surface, owner: inlineOwner)), [])
        XCTAssertEqual(inline.owner(for: surface), inlineOwner)
    }

    func test_transportActivityFreezesCurrentWindowLiveAndDetachedHistoryOnly() throws {
        var ledger = TmuxRenderLedger()
        let grid = gridSnapshot()
        let state = TmuxSnapshot(sessionID: grid.sessionID, sessionName: grid.sessionName,
            activeWindowID: grid.activeWindowID,
            windows: grid.windows + snapshot(window: 2, pane: 3).windows, authority: .unknown)
        let overlay = SurfaceId("overlay-2")
        let parked = SurfaceId("overlay-3")
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30, captureLines: ["live history", "live"])
        _ = ledger.reduce(.surfacesDeclared([
            .init(surfaceID: surface, presentation: .single),
            .init(surfaceID: overlay, presentation: .overlay, windowID: WindowId(1), paneID: PaneId(2)),
            .init(surfaceID: parked, presentation: .overlay, windowID: WindowId(2), paneID: PaneId(3)),
        ]), snapshot: state)
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30,
            captureLines: ["split history", "split"], surfaceID: overlay, paneID: PaneId(2))
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30,
            captureLines: ["parked history", "parked"], surfaceID: parked, paneID: PaneId(3))
        let source = try XCTUnwrap(ledger.owner(for: surface))
        let parkedOwner = try XCTUnwrap(ledger.owner(for: parked))

        XCTAssertEqual(ledger.reduce(.transportOutputObserved(parked, owner: parkedOwner)), [])
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: source)), [
            .diagnostic("render-ledger side-channel-frozen surface=live"),
            .diagnostic("render-ledger side-channel-frozen surface=overlay-2"),
        ])
        XCTAssertEqual(ledger.owner(for: parked), parkedOwner)
        XCTAssertEqual(reduceMessage(&ledger,
            .output(paneId: PaneId(3), data: Array("legacy parked output".utf8)), snapshot: state), [
            .diagnostic("render-ledger side-channel-frozen surface=overlay-3"),
        ], "activity in the current window must not have frozen the parked reader")
    }

    func test_transportActivityFromSplitReaderFreezesItsWindowWithoutPainter() throws {
        var ledger = TmuxRenderLedger()
        let grid = gridSnapshot()
        let state = TmuxSnapshot(sessionID: grid.sessionID, sessionName: grid.sessionName,
            activeWindowID: grid.activeWindowID,
            windows: grid.windows + snapshot(window: 2, pane: 3).windows, authority: .unknown)
        let reader = SurfaceId("overlay-2")
        let parked = SurfaceId("overlay-3")
        _ = beginSideChannel(&ledger, snapshot: state)
        _ = ledger.reduce(.surfacesDeclared([
            .init(surfaceID: surface, presentation: .single),
            .init(surfaceID: reader, presentation: .overlay, windowID: WindowId(1), paneID: PaneId(2)),
            .init(surfaceID: parked, presentation: .overlay, windowID: WindowId(2), paneID: PaneId(3)),
        ]), snapshot: state)
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30,
            captureLines: ["split history", "split"], surfaceID: reader, paneID: PaneId(2))
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30,
            captureLines: ["parked history", "parked"], surfaceID: parked, paneID: PaneId(3))
        XCTAssertNil(ledger.owner(for: surface), "a split's painter shows several panes and stays unbound")
        let readerOwner = try XCTUnwrap(ledger.owner(for: reader))
        let parkedOwner = try XCTUnwrap(ledger.owner(for: parked))

        let stale = RenderOwner(windowID: readerOwner.windowID, paneID: readerOwner.paneID,
            epoch: readerOwner.epoch + 1)
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(reader, owner: stale)), [])
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(parked, owner: parkedOwner)), [])
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(reader, owner: readerOwner),
            snapshot: snapshot(window: 2, pane: 3)), [], "a reader for a departed window cannot report activity")
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(reader, owner: readerOwner), snapshot: state), [
            .diagnostic("render-ledger side-channel-frozen surface=overlay-2"),
        ])
        XCTAssertEqual(ledger.owner(for: parked), parkedOwner)
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(reader, owner: readerOwner)), [])
    }

    func test_transportActivityDuringPresentationKeepsExactStagedHistoryUntilAck() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30,
            captureLines: ["staged history", "live"], present: false)
        let owner = try XCTUnwrap(ledger.owner(for: surface))

        XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: owner)), [])
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: surface))
        XCTAssertEqual(ledger.owner(for: surface), owner)
        XCTAssertEqual(ledger.reduce(.historyPresented(surface, owner: owner)), [
            .diagnostic("render-ledger side-channel-frozen-after-presentation surface=live"),
        ])
        XCTAssertFalse(ledger.isHistoryPresentationPending(for: surface))
    }

    func test_transportActivityDoesNotStarvePendingHistoryCapture() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 30,
            captureLines: ["old history", "live"])
        _ = ledger.reduce(.scrollbackReturnedToTail(surface))
        let painterOwner = try XCTUnwrap(ledger.owner(for: surface))
        _ = ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false))
        for _ in 0..<20 {
            XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: painterOwner)), [])
        }
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: surface))
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 30)])
        let waiting = reply(&ledger, snapshot: state, lines: ["new history", "live"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let ready = ledger.reduce(.surfaceState(surface, request: request, altScreen: false,
            mouseMode: .off, columns: 80, rows: 24))
        XCTAssertTrue(ready.contains { if case .historyReady = $0 { return true }; return false })
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(ledger.reduce(.historyPresented(surface, owner: owner)), [])
        XCTAssertNotEqual(owner, painterOwner)
        XCTAssertEqual(ledger.reduce(.transportOutputObserved(surface, owner: painterOwner)), [])
    }

    func test_transportActivityRoundTripsWithCanonicalOwnerWireShape() throws {
        let fact = RenderFact.transportOutputObserved(.live,
            owner: .init(windowID: WindowId(1), paneID: PaneId(1), epoch: 7))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(fact)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self),
            "{\"kind\":\"transportOutputObserved\",\"owner\":{\"epoch\":7,\"paneID\":1,\"windowID\":1},\"surfaceID\":\"live\",\"version\":1}")
        XCTAssertEqual(try JSONDecoder().decode(RenderFact.self, from: encoded), fact)
    }

    // MARK: - Authority repaint reservation: characterization before the refactor
    //
    // These pin the ledger's behaviour at the exact seams that the
    // reservation-lifecycle refactor moves. They are deliberately written as
    // characterization, not aspiration: each asserts what the ledger does
    // TODAY, so that the refactor's diff shows every behaviour change instead
    // of hiding one. See the D65/D21/D38/D42 invariants in the authority
    // defect inventory.

    /// TODAY: a side-channel rebind carries no correlated reservation at all.
    /// `invalidateSideChannelHistory(forceBind:)` emits `bindSurface` under a
    /// fresh epoch plus an *uncorrelated* `requestTransportFullFrame`, so an
    /// authority claim's frame is invisible to the ledger and the platform is
    /// left to notice the rebind and re-reserve on its own. That gap is the
    /// mosh+tmux take-back defect (D65): iOS did not notice, and aborted.
    ///
    /// AFTER THE REFACTOR this must change — the rebind should re-reserve the
    /// outstanding correlation against the new owner. Update deliberately.
    func test_sideChannelRebindEmitsUncorrelatedFullFrameRequestToday() throws {
        var ledger = TmuxRenderLedger()
        let initial = gridSnapshot()
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: initial,
            historySize: 30,
            captureLines: ["old wrapped history", "old viewport"]
        )
        let prior = try XCTUnwrap(ledger.owner(for: surface))

        let resized = gridSnapshot(firstWidth: 50, secondWidth: 49, totalWidth: 100)
        let effects = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "100x24,0,0{50x24,0,0,1,49x24,51,0,2}",
                visibleLayout: "100x24,0,0{50x24,0,0,1,49x24,51,0,2}",
                rawFlags: "*"
            ),
            snapshot: resized
        )

        let rebound = try XCTUnwrap(effects.compactMap { effect -> RenderOwner? in
            guard case .bindSurface(let id, let owner) = effect, id == surface else { return nil }
            return owner
        }.last)

        // Same visible target, new epoch — D65's exact shape.
        XCTAssertEqual(rebound.windowID, prior.windowID)
        XCTAssertEqual(rebound.paneID, prior.paneID)
        XCTAssertNotEqual(rebound.epoch, prior.epoch)

        // The full-frame request carries no correlation, so nothing downstream
        // can tell it apart from an ordinary resync.
        XCTAssertTrue(effects.contains(.requestTransportFullFrame))
        XCTAssertFalse(effects.contains { effect in
            if case .refreshCompleted = effect { return true }
            if case .refreshFailed = effect { return true }
            return false
        })
    }

    /// TODAY: the correlated-refresh contract is inline-only, and the ledger
    /// says so out loud — `requestRefresh` guards on `profile == .inline` and
    /// answers anything else with `refreshFailed(reason: "profile-not-inline")`
    /// (RenderLedger.swift:1565). The capture is never even started.
    ///
    /// This is the single gate the reservation refactor has to open, and it is
    /// why routing the authority claim through the existing contract on mosh is
    /// a behaviour change rather than a move. Pinning the refusal here means
    /// opening it cannot happen silently.
    func test_sideChannelCorrelatedRefreshIsRefusedAsNotInlineToday() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 30,
            captureLines: ["history", "viewport"]
        )

        let effects = ledger.reduce(
            .correlatedRefreshRequested(
                surface,
                stage: .deep,
                reason: "authority-reclaim",
                correlation: 4_242
            ),
            snapshot: state
        )

        XCTAssertEqual(
            effects,
            [.refreshFailed(surface, correlation: 4_242, reason: "profile-not-inline")],
            "the side channel refuses the correlation outright and starts no capture"
        )
    }

    // MARK: - Transport full-frame reservations (the refactored contract)

    private func reserveTransportFrame(
        _ ledger: inout TmuxRenderLedger,
        snapshot state: TmuxSnapshot,
        correlation: UInt64 = 900
    ) -> [RenderEffect] {
        ledger.reduce(
            .correlatedTransportFullFrameRequested(
                surface,
                reason: "authority-reclaim",
                correlation: correlation
            ),
            snapshot: state
        )
    }

    /// D65 — the defect this whole contract exists for. A take-back forces
    /// tmux geometry; tmux echoes `%layout-change`; the ledger rebinds the
    /// surface under a fresh epoch for that echo. Same window, same pane —
    /// only the epoch moved — so the reservation must be re-issued against the
    /// replacement owner, NOT failed.
    func test_transportFrameReservationIsReIssuedAcrossSameTargetEpochRebind() throws {
        var ledger = TmuxRenderLedger()
        let initial = gridSnapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: initial, historySize: 30, captureLines: ["history", "viewport"]
        )
        // Explicit take-back retires the reader before requesting its frame.
        _ = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: initial)
        let prior = try XCTUnwrap(ledger.owner(for: surface))

        let reserved = reserveTransportFrame(&ledger, snapshot: initial)
        XCTAssertEqual(reserved, [.requestCorrelatedTransportFullFrame(
            surface, owner: prior, correlation: 900, reason: "authority-reclaim"
        )])

        let resized = gridSnapshot(firstWidth: 50, secondWidth: 49, totalWidth: 100)
        let effects = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "100x24,0,0{50x24,0,0,1,49x24,51,0,2}",
                visibleLayout: "100x24,0,0{50x24,0,0,1,49x24,51,0,2}",
                rawFlags: "*"
            ),
            snapshot: resized
        )

        let rebound = try XCTUnwrap(effects.compactMap { effect -> RenderOwner? in
            guard case .bindSurface(let id, let owner) = effect, id == surface else { return nil }
            return owner
        }.last)
        XCTAssertNotEqual(rebound.epoch, prior.epoch)

        XCTAssertTrue(
            effects.contains(.requestCorrelatedTransportFullFrame(
                surface, owner: rebound, correlation: 900, reason: "authority-reclaim"
            )),
            "the reservation must be re-issued against the replacement owner"
        )
        XCTAssertFalse(
            effects.contains { effect in
                if case .transportFullFrameFailed = effect { return true }
                return false
            },
            "a same-target epoch move must not fail the reservation"
        )
        // And the re-issue must follow its bind, never precede it.
        let bindIndex = try XCTUnwrap(effects.firstIndex {
            if case .bindSurface(surface, _) = $0 { return true }
            return false
        })
        let reissueIndex = try XCTUnwrap(effects.firstIndex {
            if case .requestCorrelatedTransportFullFrame = $0 { return true }
            return false
        })
        XCTAssertLessThan(bindIndex, reissueIndex)
    }

    /// The negative half: a frame forced for a departed pane can never
    /// authorise the surface now on screen.
    func test_transportFrameReservationFailsOnIdentityMove() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot(window: 1, pane: 1)
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 30, captureLines: ["history", "viewport"]
        )
        _ = reserveTransportFrame(&ledger, snapshot: state)

        let moved = snapshot(window: 2, pane: 2)
        let effects = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: moved
        )

        XCTAssertTrue(
            effects.contains(.transportFullFrameFailed(
                surface, correlation: 900, reason: "owner-changed"
            )),
            "got: \(effects)"
        )
    }

    /// Invariant: exactly one terminal outcome per accepted reservation, and a
    /// stale or foreign acknowledgement discharges nothing.
    func test_transportFrameReservationHasExactlyOneTerminalOutcome() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 30, captureLines: ["history", "viewport"]
        )
        _ = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        _ = reserveTransportFrame(&ledger, snapshot: state)

        // Wrong correlation, and right correlation but a foreign owner.
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresented(surface, owner: owner, correlation: 899), snapshot: state),
            []
        )
        let foreign = RenderOwner(windowID: WindowId(9), paneID: PaneId(9), epoch: 99)
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresented(surface, owner: foreign, correlation: 900), snapshot: state),
            []
        )

        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresented(surface, owner: owner, correlation: 900), snapshot: state),
            [.transportFullFrameCompleted(surface, owner: owner, correlation: 900)]
        )
        // Discharged: a repeat says nothing.
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresented(surface, owner: owner, correlation: 900), snapshot: state),
            []
        )
    }

    /// D66 — the initial-attach claim runs ahead of the first bind, and a quiet
    /// session never binds until something prints. A reservation taken with no
    /// bound owner must be held, issued unbound, and adopt the first bind.
    func test_transportFrameReservationSurvivesHavingNoBoundOwnerYet() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = beginSideChannel(&ledger, snapshot: state)
        XCTAssertNil(ledger.owner(for: surface))

        XCTAssertEqual(
            reserveTransportFrame(&ledger, snapshot: state),
            [.requestCorrelatedTransportFullFrame(
                surface, owner: nil, correlation: 900, reason: "authority-reclaim"
            )],
            "an unbound surface must still be able to reserve a frame"
        )

        let effects = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: state
        )
        // Whatever the first bind turns out to be, the reservation adopts it
        // rather than failing.
        XCTAssertFalse(
            effects.contains { effect in
                if case .transportFullFrameFailed = effect { return true }
                return false
            },
            "the first bind must adopt the reservation, not fail it"
        )
    }

    func test_foregroundTransportFrameReservationWaitsForRevealedHistoryToReturnToTail() throws {
        var ledger = TmuxRenderLedger(configuration: .init(moshPageDepth: 2, scrollbackLimit: 10))
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 20,
            captureLines: ["near-tail history", "live one", "live two"], depth: 2
        )
        let heldOwner = try XCTUnwrap(ledger.owner(for: surface))
        let activity = ledger.reduce(.transportOutputObserved(surface, owner: heldOwner), snapshot: state)
        XCTAssertTrue(activity.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("side-channel-frozen")
        })

        let reserved = ledger.reduce(
            .correlatedTransportFullFrameRequested(surface, reason: "authority-foreground", correlation: 901),
            snapshot: state
        )
        XCTAssertFalse(reserved.contains { if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false })
        XCTAssertEqual(ledger.owner(for: surface), heldOwner)
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresented(surface, owner: heldOwner, correlation: 901), snapshot: state),
            [],
            "a reservation that has not issued a frame cannot accept a presentation receipt"
        )
        XCTAssertFalse(ledger.reduce(.transportOutputObserved(surface, owner: heldOwner), snapshot: state).contains {
            if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false
        })

        let returned = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        let tailOwner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertNotEqual(tailOwner, heldOwner)
        XCTAssertTrue(returned.contains(.bindSurface(surface, owner: tailOwner)))
        XCTAssertTrue(returned.contains(.requestTransportFullFrame), "the ordinary tail repaint remains available")
        XCTAssertEqual(returned.filter { if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false }, [
            .requestCorrelatedTransportFullFrame(surface, owner: tailOwner, correlation: 901, reason: "authority-foreground"),
        ])
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresented(surface, owner: heldOwner, correlation: 901), snapshot: state),
            []
        )
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresented(surface, owner: tailOwner, correlation: 901), snapshot: state),
            [.transportFullFrameCompleted(surface, owner: tailOwner, correlation: 901)]
        )
    }

    func test_foregroundTransportFrameReservationRemainsDeferredAcrossHistoryDeepenRebind() throws {
        var ledger = TmuxRenderLedger(configuration: .init(moshPageDepth: 4, scrollbackLimit: 8))
        let state = snapshot()
        let page = ["history one", "history two", "history three", "history four", "live one", "live two"]
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 20, captureLines: page, depth: 4)
        let heldOwner = try XCTUnwrap(ledger.owner(for: surface))
        _ = ledger.reduce(
            .correlatedTransportFullFrameRequested(surface, reason: "authority-foreground", correlation: 902),
            snapshot: state
        )
        let deepen = ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        XCTAssertTrue(containsCommand(deepen, RenderCommands.moshHistory(target: PaneId(1), depth: 8)))
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)])
        let waiting = reply(&ledger, snapshot: state, lines: ["older one", "older two", "older three", "older four"] + page)
        let request = try XCTUnwrap(resolveRequest(waiting))
        let staged = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 2),
            snapshot: state
        )
        let deeperOwner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertNotEqual(deeperOwner, heldOwner)
        XCTAssertTrue(staged.contains(.bindSurface(surface, owner: deeperOwner)))
        XCTAssertTrue(staged.contains(.requestTransportFullFrame), "ordinary history hydration repaint remains available")
        XCTAssertFalse(staged.contains { if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false })
        XCTAssertFalse(staged.contains { if case .transportFullFrameFailed = $0 { return true }; return false })
        XCTAssertFalse(ledger.reduce(.historyPresented(surface, owner: deeperOwner), snapshot: state).contains {
            if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false
        })

        let returned = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        let tailOwner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertTrue(returned.contains(.requestCorrelatedTransportFullFrame(
            surface, owner: tailOwner, correlation: 902, reason: "authority-foreground"
        )))
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresented(surface, owner: tailOwner, correlation: 902), snapshot: state),
            [.transportFullFrameCompleted(surface, owner: tailOwner, correlation: 902)]
        )
    }

    func test_foregroundTransportFrameReservationWaitsForPendingHistoryPresentation() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 30, captureLines: ["history", "viewport"], present: false
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: surface))
        let reserved = ledger.reduce(
            .correlatedTransportFullFrameRequested(surface, reason: "authority-foreground", correlation: 903),
            snapshot: state
        )
        XCTAssertFalse(reserved.contains { if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false })
        XCTAssertFalse(ledger.reduce(.historyPresented(surface, owner: owner), snapshot: state).contains {
            if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false
        })
        let returned = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        let tailOwner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertTrue(returned.contains(.requestCorrelatedTransportFullFrame(
            surface, owner: tailOwner, correlation: 903, reason: "authority-foreground"
        )))
    }

    func test_deferredTransportFrameReservationCanBeSupersededAndCancelledExactlyOnce() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 30, captureLines: ["history", "viewport"]
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        _ = ledger.reduce(
            .correlatedTransportFullFrameRequested(surface, reason: "authority-foreground", correlation: 904),
            snapshot: state
        )
        let replacement = ledger.reduce(
            .correlatedTransportFullFrameRequested(surface, reason: "authority-foreground", correlation: 905),
            snapshot: state
        )
        XCTAssertTrue(replacement.contains(.transportFullFrameFailed(surface, correlation: 904, reason: "superseded")))
        XCTAssertFalse(replacement.contains { if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false })
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresentationFailed(surface, owner: owner, correlation: 905, reason: "cancelled"), snapshot: state),
            [.transportFullFrameFailed(surface, correlation: 905, reason: "cancelled")]
        )
        XCTAssertEqual(
            ledger.reduce(.transportFullFramePresentationFailed(surface, owner: owner, correlation: 905, reason: "cancelled"), snapshot: state),
            []
        )
        XCTAssertFalse(ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state).contains {
            if case .requestCorrelatedTransportFullFrame = $0 { return true }; return false
        })
    }

    func test_deferredTransportFrameReservationIssuesWhenHistoryPresentationFails() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 30, captureLines: ["history", "viewport"], present: false
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(ledger.reduce(
            .correlatedTransportFullFrameRequested(surface, reason: "authority-foreground", correlation: 906),
            snapshot: state
        ), [])
        let failed = ledger.reduce(.historyPresentationFailed(surface, owner: owner), snapshot: state)
        XCTAssertTrue(failed.contains(.requestCorrelatedTransportFullFrame(
            surface, owner: owner, correlation: 906, reason: "authority-foreground"
        )))
        XCTAssertEqual(ledger.reduce(.transportFullFramePresented(surface, owner: owner, correlation: 906), snapshot: state), [
            .transportFullFrameCompleted(surface, owner: owner, correlation: 906),
        ])
    }

    func test_deferredTransportFrameReservationIssuesWhenFailedDeepenRetiresHistory() throws {
        var ledger = TmuxRenderLedger(configuration: .init(moshPageDepth: 2, scrollbackLimit: 10))
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 20, captureLines: ["history", "viewport"], depth: 2
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(ledger.reduce(
            .correlatedTransportFullFrameRequested(surface, reason: "authority-foreground", correlation: 907),
            snapshot: state
        ), [])
        let deepen = ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        XCTAssertTrue(containsCommand(deepen, RenderCommands.moshHistory(target: PaneId(1), depth: 10)))
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)])
        let failed = reply(&ledger, snapshot: state, lines: [])
        XCTAssertTrue(failed.contains(.diagnostic("render-ledger side-channel-skipped surface=live reason=capture-empty")))
        XCTAssertTrue(failed.contains(.requestCorrelatedTransportFullFrame(
            surface, owner: owner, correlation: 907, reason: "authority-foreground"
        )))
        XCTAssertEqual(ledger.reduce(.transportFullFramePresented(surface, owner: owner, correlation: 907), snapshot: state), [
            .transportFullFrameCompleted(surface, owner: owner, correlation: 907),
        ])
    }

    /// Transport teardown is not a surface rebind: the framebuffer behind the
    /// reservation is gone, so it must fail rather than wait forever.
    func test_transportFrameReservationFailsOnTransportLoss() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 30, captureLines: ["history", "viewport"]
        )
        _ = reserveTransportFrame(&ledger, snapshot: state)

        XCTAssertTrue(
            ledger.reduce(.transportLost, snapshot: state).contains(
                .transportFullFrameFailed(surface, correlation: 900, reason: "transport-lost")
            )
        )
    }

    /// The reservation is held per surface, so the platform has to declare the
    /// surface before it can reserve a frame against it. The mosh
    /// initial-attach claim runs ahead of hydration and of the first bind by
    /// design, and it must wait for the declaration rather than be refused:
    /// this refusal is what aborted every launch claim on Android until the
    /// controller learned to defer.
    func test_transportFrameReservationIsRefusedForAnUndeclaredSurface() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = beginSideChannel(&ledger, snapshot: state)

        XCTAssertEqual(
            ledger.reduce(
                .correlatedTransportFullFrameRequested(
                    SurfaceId("never-declared"), reason: "authority-reclaim", correlation: 900
                ),
                snapshot: state
            ),
            [.transportFullFrameFailed(
                SurfaceId("never-declared"), correlation: 900, reason: "unknown-surface"
            )]
        )
    }

    /// A reconnect can attach a replacement transport without a preceding
    /// loss. The framebuffer the reserved frame would have come from belongs to
    /// the transport being replaced, so the reservation ends with it.
    func test_transportFrameReservationFailsWhenAReplacementTransportAttaches() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 30, captureLines: ["history", "viewport"]
        )
        _ = reserveTransportFrame(&ledger, snapshot: state)

        XCTAssertTrue(
            ledger.reduce(.transportAttached(.sideChannel), snapshot: state).contains(
                .transportFullFrameFailed(surface, correlation: 900, reason: "transport-attached")
            )
        )
    }

    /// Compose and SwiftUI redeclare their surfaces whenever the topology
    /// changes, which a claim's own relayout can provoke. Dropping the surface
    /// must end its reservation rather than let it vanish: a claim waiting on a
    /// frame that will never be spoken of again is the stranded veil this whole
    /// contract exists to prevent.
    func test_transportFrameReservationFailsWhenItsSurfaceIsUndeclared() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger, snapshot: state, historySize: 30, captureLines: ["history", "viewport"]
        )
        _ = reserveTransportFrame(&ledger, snapshot: state)

        let effects = ledger.reduce(
            .surfacesDeclared([.init(surfaceID: SurfaceId("other"), presentation: .single)]),
            snapshot: state
        )
        XCTAssertTrue(
            effects.contains(
                .transportFullFrameFailed(surface, correlation: 900, reason: "surface-removed")
            ),
            "an undeclared surface must discharge its reservation"
        )
    }

    /// The inline profile has its own correlated-refresh contract; a transport
    /// reservation there would never be painted.
    func test_transportFrameReservationIsRefusedOnTheInlineProfile() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["initial"])

        XCTAssertEqual(
            reserveTransportFrame(&ledger, snapshot: state),
            [.transportFullFrameFailed(
                surface, correlation: 900, reason: "profile-not-side-channel"
            )]
        )
    }

    func test_renderBytesRemainAvailablePastSixtyFourOutstandingFeedsUntilTaken() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["ready"])

        var firstReference: RenderBytesRef?
        for ordinal in 0..<65 {
            let effects = reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("output-\(ordinal)".utf8)),
                snapshot: state
            )
            let reference = try XCTUnwrap(feeds(in: effects).first?.reference)
            if ordinal == 0 { firstReference = reference }
        }

        let first = try XCTUnwrap(firstReference)
        let retained = try XCTUnwrap(ledger.renderBytes(for: first))
        XCTAssertEqual(String(decoding: retained, as: UTF8.self), "output-0")
    }

    func test_pauseOfRenderedPaneContinuesBeforeItRequestsDeepResync() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["ready"])

        let effects = reduceMessage(&ledger, .pause(paneId: PaneId(1)), snapshot: state)
        XCTAssertEqual(
            effects.compactMap { effect -> String? in
                guard case .sendCommand(let command) = effect else { return nil }
                return command
            },
            [
                RenderCommands.continuePane(PaneId(1)),
                RenderCommands.renderedPaneMetadata(target: WindowId(1)),
            ]
        )
    }

    func test_pauseDuringAnotherPaneSwapWaitsUntilThePausedPaneIsRenderedAgain() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        let second = snapshot(window: 2, pane: 2)
        _ = finishInitialInline(&ledger, snapshot: first, captureLines: ["first"])

        _ = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: second
        )
        XCTAssertEqual(
            reduceMessage(&ledger, .pause(paneId: PaneId(1)), snapshot: second),
            [],
            "a pause from the old pane must stay pending while its replacement is rendering"
        )

        XCTAssertEqual(
            reply(&ledger, snapshot: second, lines: [metadata(pane: 2)]),
            [.sendCommand(RenderCommands.viewport(target: WindowId(2)))]
        )
        let secondViewport = reply(&ledger, snapshot: second, lines: ["second viewport"])
        let secondViewportRequest = try XCTUnwrap(resolveRequest(secondViewport))
        _ = ledger.reduce(
            .surfaceState(surface, request: secondViewportRequest, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: second
        )
        XCTAssertEqual(
            reply(&ledger, snapshot: second, lines: [metadata(pane: 2)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(2), depth: 2_000))]
        )
        let secondDeep = reply(&ledger, snapshot: second, lines: ["second deep"])
        let secondDeepRequest = try XCTUnwrap(resolveRequest(secondDeep))
        _ = ledger.reduce(
            .surfaceState(surface, request: secondDeepRequest, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: second
        )

        _ = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(1)),
            snapshot: first
        )
        XCTAssertEqual(
            reply(&ledger, snapshot: first, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.viewport(target: WindowId(1)))]
        )
        let firstViewport = reply(&ledger, snapshot: first, lines: ["first viewport again"])
        let firstViewportRequest = try XCTUnwrap(resolveRequest(firstViewport))
        let resumed = ledger.reduce(
            .surfaceState(surface, request: firstViewportRequest, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: first
        )

        let feedIndex = try XCTUnwrap(resumed.firstIndex { if case .feed = $0 { return true }; return false })
        let continueIndex = try XCTUnwrap(resumed.firstIndex {
            if case .sendCommand(RenderCommands.continuePane(PaneId(1))) = $0 { return true }
            return false
        })
        XCTAssertLessThan(feedIndex, continueIndex, "the swap must paint the paused pane before resuming it")
    }

    func test_sideChannelFirstWindowOnlyLatchesThenWindowChangeClearsBoundHistory() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        _ = beginSideChannel(&ledger, snapshot: first)
        XCTAssertNil(ledger.owner(for: surface))

        let second = snapshot(window: 2, pane: 2)
        let initialSwitch = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: second
        )
        guard case .bindSurface(let initiallyBound, let switchedOwner)? = initialSwitch.first else {
            return XCTFail("a real second window must clear even before history has been synthesized")
        }
        XCTAssertEqual(initiallyBound, surface)
        XCTAssertEqual(switchedOwner.windowID, WindowId(2))
        XCTAssertEqual(switchedOwner.paneID, PaneId(2))
        XCTAssertFalse(initialSwitch.contains { if case .sendCommand = $0 { return true }; return false })

        var historyLedger = TmuxRenderLedger()
        _ = beginSideChannel(&historyLedger, snapshot: first)
        _ = finishSideChannelHistory(
            &historyLedger,
            snapshot: first,
            historySize: 30,
            captureLines: ["history"]
        )
        let effects = reduceMessage(
            &historyLedger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: second
        )
        guard case .bindSurface(let bound, let owner)? = effects.first else {
            return XCTFail("expected one clear/bind after a synthesized-history switch")
        }
        XCTAssertEqual(bound, surface)
        XCTAssertEqual(owner.windowID, WindowId(2))
        XCTAssertEqual(owner.paneID, PaneId(2))
        XCTAssertFalse(effects.contains { if case .sendCommand = $0 { return true }; return false })
    }

    func test_sideChannelWindowAndPaneChangesClearSynthesizedHistoryWithoutImmediateTransportFrameRequest() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: first,
            historySize: 30,
            captureLines: ["window one history", "window one viewport"]
        )

        let secondWindow = snapshot(window: 2, pane: 2)
        let windowSwitch = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: secondWindow
        )
        assertSideChannelTransitionClearsOnly(
            windowSwitch,
            expectedWindow: WindowId(2),
            expectedPane: PaneId(2)
        )

        _ = finishSideChannelHistory(
            &ledger,
            snapshot: secondWindow,
            historySize: 30,
            captureLines: ["window two history", "window two viewport"]
        )

        let secondPane = snapshot(window: 2, pane: 3)
        let paneSwitch = reduceMessage(
            &ledger,
            .windowPaneChanged(windowId: WindowId(2), activePaneId: PaneId(3)),
            snapshot: secondPane
        )
        assertSideChannelTransitionClearsOnly(
            paneSwitch,
            expectedWindow: WindowId(2),
            expectedPane: PaneId(3)
        )
    }

    func test_sideChannelLateFixedDeclarationStillClearsThePreviousWindow() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: first,
            historySize: 30,
            captureLines: ["window one history", "window one live"]
        )
        _ = ledger.reduce(.surfacesDeclared([.init(
            surfaceID: surface,
            presentation: .single,
            windowID: WindowId(1),
            paneID: PaneId(1)
        )]), snapshot: first)

        let second = snapshot(window: 2, pane: 2)
        let early = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: second
        )
        XCTAssertFalse(early.contains { if case .bindSurface = $0 { return true }; return false })

        let declared = ledger.reduce(.surfacesDeclared([.init(
            surfaceID: surface,
            presentation: .single,
            windowID: WindowId(2),
            paneID: PaneId(2)
        )]), snapshot: second)
        guard case .bindSurface(let id, let owner)? = declared.first else {
            return XCTFail("the updated declaration must retire synthesized history from the prior window")
        }
        XCTAssertEqual(id, surface)
        XCTAssertEqual(owner.windowID, WindowId(2))
        XCTAssertEqual(owner.paneID, PaneId(2))
    }

    func test_sideChannelLateFixedDeclarationClearsEvenBeforeHistoryWasSynthesized() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        XCTAssertEqual(ledger.reduce(.surfacesDeclared([.init(
            surfaceID: surface,
            presentation: .single,
            windowID: WindowId(1),
            paneID: PaneId(1)
        )]), snapshot: first), [])
        XCTAssertEqual(ledger.reduce(.transportAttached(.sideChannel), snapshot: first), [])
        XCTAssertNil(ledger.owner(for: surface))

        let second = snapshot(window: 2, pane: 2)
        let early = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: second
        )
        XCTAssertFalse(early.contains { if case .bindSurface = $0 { return true }; return false })

        let declared = ledger.reduce(.surfacesDeclared([.init(
            surfaceID: surface,
            presentation: .single,
            windowID: WindowId(2),
            paneID: PaneId(2)
        )]), snapshot: second)
        guard case .bindSurface(let id, let owner)? = declared.first else {
            return XCTFail("the surface-local target edge must survive the earlier wire notification")
        }
        XCTAssertEqual(id, surface)
        XCTAssertEqual(owner.windowID, WindowId(2))
        XCTAssertEqual(owner.paneID, PaneId(2))
        XCTAssertFalse(declared.contains { if case .sendCommand = $0 { return true }; return false })
    }

    func test_sanitizedForegroundRepliesStopAtTheRetryBoundAndRemainFailClosed() throws {
        var ledger = TmuxRenderLedger(configuration: .init(maximumViewportRetryAttempts: 1))
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["ready"])
        _ = ledger.reduce(.appBackground, snapshot: state)
        _ = ledger.reduce(.appForeground, snapshot: state)

        let sanitized = metadata(pane: 1).replacingOccurrences(of: "\t", with: "_")
        XCTAssertTrue(ledger.isRefreshInFlight(for: surface))
        XCTAssertFalse(ledger.hasFailedRefresh(for: surface))
        let firstFailure = reply(&ledger, snapshot: state, lines: [sanitized])
        XCTAssertTrue(ledger.isRefreshInFlight(for: surface), "a bounded retry can still paint")
        let retryToken = try XCTUnwrap(firstFailure.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first)
        XCTAssertTrue(containsCommand(
            ledger.reduce(.timerFired(token: retryToken), snapshot: state),
            RenderCommands.renderedPaneMetadata(target: WindowId(1))
        ))

        let exhausted = reply(&ledger, snapshot: state, lines: [sanitized])
        XCTAssertTrue(exhausted.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("refresh-gave-up")
        })
        XCTAssertFalse(exhausted.contains { if case .armTimer = $0 { return true }; return false })
        XCTAssertTrue(ledger.hasPendingRender, "the established stale surface must remain fail-closed")
        XCTAssertFalse(ledger.isRefreshInFlight(for: surface), "a retained cut cannot paint")
        XCTAssertTrue(ledger.hasFailedRefresh(for: surface))
        XCTAssertEqual(
            reduceMessage(&ledger, .output(paneId: PaneId(1), data: Array("must drop".utf8)), snapshot: state),
            []
        )
    }

    func test_sideChannelExhaustedHistoryCompletesRequestWithoutAnotherCapture() {
        var ledger = TmuxRenderLedger(configuration: .init(moshPageDepth: 2, scrollbackLimit: 10))
        let state = snapshot()
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 1,
                                     captureLines: ["old", "live"], depth: 2)
        XCTAssertEqual(ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state), [
            .diagnostic("render-ledger side-channel-request-ignored surface=live reason=exhausted")
        ])
        XCTAssertFalse(ledger.hasPendingRender)
        _ = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        XCTAssertTrue(containsCommand(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state),
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
    }

    func test_sideChannelReentryQueuesMetadataAndHistoryBeforeAnyReply() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 300,
                                     captureLines: ["history", "live"])
        _ = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        let start = ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        let commands = start.compactMap { effect -> String? in
            if case .sendCommand(let command) = effect { return command }
            return nil
        }
        XCTAssertEqual(commands, [
            RenderCommands.renderedPaneMetadata(target: PaneId(1)),
            RenderCommands.moshHistory(target: PaneId(1), depth: 240),
        ])
        XCTAssertEqual(ledger.pendingCommandCount, 2)
        // Invalid metadata must retire the prefetched body, even though it has
        // already left the client. It must not poison the next request's FIFO.
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 2)])
        assertStaleCapture(&ledger, snapshot: state)
        _ = finishSideChannelHistory(&ledger, snapshot: state, historySize: 300,
                                     captureLines: ["fresh history", "live"])
        XCTAssertEqual(ledger.pendingCommandCount, 0)
    }

    func test_sideChannelRefusesAlternateScreenAndZeroCapture() {
        let state = snapshot()

        var alternate = TmuxRenderLedger()
        _ = beginSideChannel(&alternate, snapshot: state)
        let first = alternate.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        XCTAssertTrue(containsCommand(first, RenderCommands.renderedPaneMetadata(target: PaneId(1))))
        let altEffects = reply(&alternate, snapshot: state, lines: [metadata(pane: 1, alt: true)])
        XCTAssertFalse(altEffects.contains { if case .sendCommand = $0 { return true }; return false })
        XCTAssertTrue(altEffects.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("alternate-screen") }
            return false
        })

        assertStaleCapture(&alternate, snapshot: state)
        XCTAssertNil(alternate.owner(for: surface))

        var empty = TmuxRenderLedger()
        _ = beginSideChannel(&empty, snapshot: state)
        _ = empty.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        XCTAssertEqual(
            reply(&empty, snapshot: state, lines: [metadata(pane: 1)]),
            []
        )
        let zero = reply(&empty, snapshot: state, lines: [])
        XCTAssertFalse(zero.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertTrue(zero.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("capture-empty") }
            return false
        })
    }

    func test_sideChannelGridZeroCaptureFailsClosedWithoutBindingThePaneSurface() {
        let state = snapshot()
        let paneSurface = SurfaceId("pane-1")
        var ledger = TmuxRenderLedger()
        XCTAssertEqual(
            ledger.reduce(
                .surfacesDeclared([.init(
                    surfaceID: paneSurface,
                    presentation: .grid,
                    windowID: WindowId(1),
                    paneID: PaneId(1)
                )]),
                snapshot: state
            ),
            []
        )
        _ = ledger.reduce(.transportAttached(.sideChannel), snapshot: state)
        XCTAssertTrue(containsCommand(
            ledger.reduce(.scrollbackRequested(paneSurface, pointsY: 1, isInertial: false), snapshot: state),
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            []
        )
        let failed = reply(&ledger, snapshot: state, lines: [])
        XCTAssertFalse(failed.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertNil(ledger.owner(for: paneSurface))
        XCTAssertTrue(failed.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("capture-empty") }
            return false
        })
    }

    func test_sideChannelEpochInvalidationDropsLateReplyAndFreezeBlocksFetchUntilTail() throws {
        let configuration = TmuxRenderLedger.Configuration(moshPageDepth: 2, scrollbackLimit: 10)
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 20,
            captureLines: ["older", "live"],
            depth: 2
        )
        let before = try XCTUnwrap(ledger.owner(for: surface))

        let next = ledger.reduce(.findOpened(surface), snapshot: state)
        XCTAssertTrue(containsCommand(next, RenderCommands.renderedPaneMetadata(target: PaneId(1))))
        _ = ledger.reduce(.userInput, snapshot: state)
        let after = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertNotEqual(after.epoch, before.epoch)
        let stale = reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)])
        XCTAssertTrue(stale.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("stale-reply") }
            return false
        })

        assertStaleCapture(&ledger, snapshot: state)
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 2,
            captureLines: ["older", "live"],
            depth: 2
        )
        let frozen = reduceMessage(&ledger, .output(paneId: PaneId(1), data: Array("live output".utf8)), snapshot: state)
        XCTAssertTrue(frozen.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("side-channel-frozen") }
            return false
        })
        XCTAssertEqual(ledger.reduce(.findOpened(surface), snapshot: state), [])
        XCTAssertEqual(ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state), [
            .diagnostic("render-ledger side-channel-request-ignored surface=live reason=frozen")
        ])
        let returned = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        guard case .bindSurface(let reboundSurface, let reboundOwner) = returned.first else {
            return XCTFail("returning to the painter tail must clear through a new owner bind")
        }
        XCTAssertEqual(reboundSurface, surface)
        XCTAssertNotEqual(reboundOwner.epoch, before.epoch)
        XCTAssertEqual(returned.last, .requestTransportFullFrame)
        let unfrozen = ledger.reduce(.findOpened(surface), snapshot: state)
        XCTAssertTrue(containsCommand(unfrozen, RenderCommands.renderedPaneMetadata(target: PaneId(1))))
    }

    func test_sideChannelPaneOutputDoesNotStarveInitialHistoryCapture() throws {
        let configuration = TmuxRenderLedger.Configuration(moshPageDepth: 2, scrollbackLimit: 10)
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = snapshot()
        _ = beginSideChannel(&ledger, snapshot: state)

        let started = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: state
        )
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: surface))
        XCTAssertTrue(containsCommand(started, RenderCommands.renderedPaneMetadata(target: PaneId(1))))
        XCTAssertEqual(
            reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("before metadata".utf8)),
                snapshot: state
            ),
            []
        )
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)]),
            []
        )
        XCTAssertEqual(
            reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("before capture".utf8)),
                snapshot: state
            ),
            []
        )

        let waiting = reply(&ledger, snapshot: state, lines: ["history", "live"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let finished = ledger.reduce(
            .surfaceState(
                surface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 80,
                rows: 24
            ),
            snapshot: state
        )

        XCTAssertTrue(finished.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertEqual(feeds(in: finished).map(\.source), [.moshHistory])
        XCTAssertTrue(finished.contains { if case .historyReady = $0 { return true }; return false })
    }

    func test_sideChannelOutputBeforePresentationKeepsTheStagedHistoryUntilExactAck() throws {
        let configuration = TmuxRenderLedger.Configuration(moshPageDepth: 2, scrollbackLimit: 10)
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = snapshot()

        let finished = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 20,
            captureLines: ["staged history", "live"],
            depth: 2,
            present: false
        )
        let owner = try XCTUnwrap(finished.compactMap { effect -> RenderOwner? in
            guard case .historyReady(let surfaceID, let readyOwner, _, _, _) = effect,
                  surfaceID == surface
            else { return nil }
            return readyOwner
        }.first)
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: surface))
        XCTAssertEqual(owner, ledger.owner(for: surface))

        // The bytes are awaiting a platform-owned terminal feed.  Mosh can
        // advance in this interval, but that must not invalidate the staged
        // delivery before the platform says it really presented it.
        let stagedOutput = reduceMessage(
            &ledger,
            .output(paneId: PaneId(1), data: Array("output while staged".utf8)),
            snapshot: state
        )
        XCTAssertEqual(stagedOutput, [])
        XCTAssertEqual(ledger.owner(for: surface), owner)

        let presented = ledger.reduce(.historyPresented(surface, owner: owner), snapshot: state)
        XCTAssertFalse(ledger.isHistoryPresentationPending(for: surface))
        XCTAssertEqual(
            presented,
            [.diagnostic("render-ledger side-channel-frozen-after-presentation surface=live")]
        )
        XCTAssertEqual(ledger.reduce(.findOpened(surface), snapshot: state), [])
    }

    func test_sideChannelOutputAfterExactPresentationFreezesUntilTailReturn() throws {
        let configuration = TmuxRenderLedger.Configuration(moshPageDepth: 2, scrollbackLimit: 10)
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = snapshot()

        let finished = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 20,
            captureLines: ["history", "live"],
            depth: 2,
            present: false
        )
        let owner = try XCTUnwrap(finished.compactMap { effect -> RenderOwner? in
            guard case .historyReady(let surfaceID, let readyOwner, _, _, _) = effect,
                  surfaceID == surface
            else { return nil }
            return readyOwner
        }.first)
        XCTAssertEqual(ledger.reduce(.historyPresented(surface, owner: owner), snapshot: state), [])

        let frozen = reduceMessage(
            &ledger,
            .output(paneId: PaneId(1), data: Array("output after presentation".utf8)),
            snapshot: state
        )
        XCTAssertEqual(
            frozen,
            [.diagnostic("render-ledger side-channel-frozen surface=live")]
        )
        XCTAssertEqual(
            reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("later output while frozen".utf8)),
                snapshot: state
            ),
            [],
            "a frozen side channel must not flood diagnostics for every output notification"
        )
        XCTAssertEqual(ledger.reduce(.findOpened(surface), snapshot: state), [])
        XCTAssertFalse(containsCommand(
            ledger.noteAppliedClientSize(columns: 100, rows: 24),
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))

        let returned = ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        XCTAssertTrue(returned.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertEqual(returned.last, .requestTransportFullFrame)
        XCTAssertTrue(containsCommand(
            ledger.reduce(.findOpened(surface), snapshot: state),
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
    }

    func test_sideChannelStalePresentationAckFailsClosedWithoutRevealingHistory() throws {
        let configuration = TmuxRenderLedger.Configuration(moshPageDepth: 2, scrollbackLimit: 10)
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = snapshot()

        let finished = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 20,
            captureLines: ["history", "live"],
            depth: 2,
            present: false
        )
        let owner = try XCTUnwrap(finished.compactMap { effect -> RenderOwner? in
            guard case .historyReady(let surfaceID, let readyOwner, _, _, _) = effect,
                  surfaceID == surface
            else { return nil }
            return readyOwner
        }.first)
        let staleOwner = RenderOwner(
            windowID: owner.windowID,
            paneID: owner.paneID,
            epoch: owner.epoch + 1
        )

        let stale = ledger.reduce(.historyPresented(surface, owner: staleOwner), snapshot: state)
        XCTAssertEqual(
            stale,
            [.diagnostic("render-ledger history-presented-stale surface=live")]
        )
        XCTAssertEqual(ledger.owner(for: surface), owner)
        XCTAssertEqual(
            reduceMessage(
                &ledger,
                .output(paneId: PaneId(1), data: Array("output after stale ack".utf8)),
                snapshot: state
            ),
            []
        )

        // A stale platform callback must not destroy the valid staged
        // delivery.  The exact owner can still present it, after which the
        // output already observed freezes the revealed history.
        XCTAssertEqual(
            ledger.reduce(.historyPresented(surface, owner: owner), snapshot: state),
            [.diagnostic("render-ledger side-channel-frozen-after-presentation surface=live")]
        )
    }

    func test_sideChannelExactPresentationFailureReleasesStagedLatchButStaleFailureDoesNot() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            moshPageDepth: 2,
            scrollbackLimit: 10
        ))
        let state = snapshot()
        let finished = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 20,
            captureLines: ["history", "live"],
            depth: 2,
            present: false
        )
        let owner = try XCTUnwrap(finished.compactMap { effect -> RenderOwner? in
            guard case .historyReady(let id, let candidate, _, _, _) = effect,
                  id == surface
            else { return nil }
            return candidate
        }.first)
        let stale = RenderOwner(
            windowID: owner.windowID,
            paneID: owner.paneID,
            epoch: owner.epoch + 1
        )

        XCTAssertEqual(
            ledger.reduce(.historyPresentationFailed(surface, owner: stale), snapshot: state),
            [.diagnostic("render-ledger history-presentation-failed-stale surface=live")]
        )
        XCTAssertEqual(ledger.reduce(.findOpened(surface), snapshot: state), [])

        XCTAssertEqual(
            ledger.reduce(.historyPresentationFailed(surface, owner: owner), snapshot: state),
            [.diagnostic("render-ledger history-presentation-failed surface=live")]
        )
        XCTAssertTrue(containsCommand(
            ledger.reduce(.findOpened(surface), snapshot: state),
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
    }

    func test_sideChannelLayoutChangeRestartsInFlightHistoryUnderFreshEpoch() throws {
        let configuration = TmuxRenderLedger.Configuration(
            moshPageDepth: 2,
            scrollbackLimit: 10
        )
        var ledger = TmuxRenderLedger(configuration: configuration)
        let initialState = singleLayoutSnapshot(columns: 79)
        let state = singleLayoutSnapshot(columns: 80)
        _ = beginSideChannel(&ledger, snapshot: initialState)

        let started = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: initialState
        )
        let oldWatchdog = try XCTUnwrap(started.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first)
        XCTAssertTrue(containsCommand(
            started,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))

        let restarted = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "80x24,0,0,1",
                visibleLayout: "80x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: state
        )
        XCTAssertTrue(restarted.contains(.cancelTimer(token: oldWatchdog)))
        let clearedOwner = try XCTUnwrap(restarted.compactMap { effect -> RenderOwner? in
            guard case .bindSurface(let id, let owner) = effect, id == surface else {
                return nil
            }
            return owner
        }.first)
        XCTAssertTrue(restarted.contains { effect in
            guard case .armTimer(let token, _) = effect else { return false }
            return token != oldWatchdog
        })
        XCTAssertTrue(containsCommand(
            restarted,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        XCTAssertTrue(restarted.contains(.requestTransportFullFrame))

        let stale = reply(
            &ledger,
            snapshot: state,
            lines: [metadata(pane: 1, historySize: 20)]
        )
        XCTAssertTrue(stale.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("stale-reply")
        })
        assertStaleCapture(&ledger, snapshot: state)
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)]),
            []
        )
        let waiting = reply(&ledger, snapshot: state, lines: ["history", "live"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let finished = ledger.reduce(
            .surfaceState(
                surface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 80,
                rows: 24
            ),
            snapshot: state
        )
        let ready = finished.compactMap { effect -> RenderOwner? in
            guard case .historyReady(let id, let owner, _, _, _) = effect,
                  id == surface
            else { return nil }
            return owner
        }
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first, ledger.owner(for: surface))
        XCTAssertNotEqual(ready.first?.epoch, clearedOwner.epoch)
    }

    func test_sideChannelClientSizeAndLayoutStormPreservesLatestCaptureIntent() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            moshPageDepth: 2,
            scrollbackLimit: 10
        ))
        let initialState = singleLayoutSnapshot(columns: 80)
        let state = singleLayoutSnapshot(columns: 101)
        _ = beginSideChannel(&ledger, snapshot: initialState)

        let started = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: initialState
        )
        let firstWatchdog = try XCTUnwrap(started.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first)

        let firstSize = ledger.reduce(.clientSize(columns: 100, rows: 24), snapshot: initialState)
        XCTAssertTrue(firstSize.contains(.cancelTimer(token: firstWatchdog)))
        XCTAssertTrue(containsCommand(
            firstSize,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))

        let secondSize = ledger.reduce(.clientSize(columns: 101, rows: 24), snapshot: initialState)
        XCTAssertTrue(containsCommand(
            secondSize,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))

        let latest = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "101x24,0,0,1",
                visibleLayout: "101x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: state
        )
        XCTAssertTrue(containsCommand(
            latest,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))

        // Each superseded generation has both metadata and capture queued.
        // Resize command receipts sit between those pairs.
        for generation in 0..<3 {
            XCTAssertTrue(reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]).contains {
                if case .diagnostic(let message) = $0 { return message.contains("stale-reply") }
                return false
            })
            assertStaleCapture(&ledger, snapshot: state)
            if generation < 2 { XCTAssertEqual(reply(&ledger, snapshot: state, lines: []), []) }
        }
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)]),
            []
        )

        let waiting = reply(&ledger, snapshot: state, lines: ["latest history", "latest live"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let finished = ledger.reduce(
            .surfaceState(
                surface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 101,
                rows: 24
            ),
            snapshot: state
        )
        let readyOwner = try XCTUnwrap(finished.compactMap { effect -> RenderOwner? in
            guard case .historyReady(let id, let owner, _, _, _) = effect, id == surface else {
                return nil
            }
            return owner
        }.first)
        XCTAssertEqual(readyOwner.paneID, PaneId(1))
        XCTAssertEqual(ledger.reduce(.historyPresented(surface, owner: readyOwner), snapshot: state), [])
    }

    func test_sideChannelAppliedClientSizeRestartsAnInFlightCapture() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = beginSideChannel(&ledger, snapshot: state)
        _ = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: state
        )

        let resized = ledger.noteAppliedClientSize(columns: 100, rows: 24)
        XCTAssertTrue(containsCommand(
            resized,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        XCTAssertTrue(reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]).contains {
            if case .diagnostic(let message) = $0 { return message.contains("stale-reply") }
            return false
        })
        assertStaleCapture(&ledger, snapshot: state)
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)]),
            []
        )
    }

    func test_sideChannelUserInputTerminatesIntentBeforeLaterGeometry() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = beginSideChannel(&ledger, snapshot: state)
        _ = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: state
        )

        _ = ledger.reduce(.userInput, snapshot: state)
        let resized = ledger.reduce(.clientSize(columns: 100, rows: 24), snapshot: state)
        XCTAssertFalse(containsCommand(
            resized,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        let relayout = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "100x24,0,0,1",
                visibleLayout: "100x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: state
        )
        XCTAssertFalse(containsCommand(
            relayout,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
    }

    func test_sideChannelLayoutChangeRestartsCapturePhaseAndRejectsOldPayload() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            moshPageDepth: 2,
            scrollbackLimit: 10
        ))
        let initialState = singleLayoutSnapshot(columns: 79)
        let state = singleLayoutSnapshot(columns: 80)
        _ = beginSideChannel(&ledger, snapshot: initialState)
        _ = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: initialState
        )
        XCTAssertEqual(
            reply(&ledger, snapshot: initialState, lines: [metadata(pane: 1, historySize: 20)]),
            []
        )

        let restarted = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "80x24,0,0,1",
                visibleLayout: "80x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: state
        )
        XCTAssertTrue(containsCommand(
            restarted,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))

        let staleCapture = reply(&ledger, snapshot: state, lines: ["old history", "old live"])
        XCTAssertTrue(staleCapture.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("stale-reply")
        })
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)]),
            []
        )
    }

    func test_sideChannelLayoutChangeRestartsAwaitingSurfaceStateAndRejectsOldResolution() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            moshPageDepth: 2,
            scrollbackLimit: 10
        ))
        let initialState = singleLayoutSnapshot(columns: 79)
        let state = singleLayoutSnapshot(columns: 80)
        _ = beginSideChannel(&ledger, snapshot: initialState)
        _ = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: initialState
        )
        _ = reply(&ledger, snapshot: initialState, lines: [metadata(pane: 1, historySize: 20)])
        let oldWaiting = reply(&ledger, snapshot: initialState, lines: ["old history", "old live"])
        let oldRequest = try XCTUnwrap(resolveRequest(oldWaiting))

        let restarted = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "80x24,0,0,1",
                visibleLayout: "80x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: state
        )
        XCTAssertTrue(containsCommand(
            restarted,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        let staleResolution = ledger.reduce(
            .surfaceState(
                surface,
                request: oldRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 80,
                rows: 24
            ),
            snapshot: state
        )
        XCTAssertTrue(staleResolution.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("stale-surface-state")
        })
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)]),
            []
        )
    }

    func test_sideChannelLayoutChangePreservesDeepFindPlacement() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            moshPageDepth: 2,
            scrollbackLimit: 10
        ))
        let initialState = singleLayoutSnapshot(columns: 79)
        let state = singleLayoutSnapshot(columns: 80)
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: initialState,
            historySize: 30,
            captureLines: ["first history", "first live"],
            depth: 2
        )
        let deepening = ledger.reduce(.findOpened(surface), snapshot: initialState)
        XCTAssertTrue(containsCommand(
            deepening,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))

        _ = reduceMessage(
            &ledger,
            .layoutChange(
                windowId: WindowId(1),
                layout: "80x24,0,0,1",
                visibleLayout: "80x24,0,0,1",
                rawFlags: "*"
            ),
            snapshot: state
        )
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 30)])
        assertStaleCapture(&ledger, snapshot: state)
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 30)]),
            []
        )
        let waiting = reply(&ledger, snapshot: state, lines: ["deep history", "deep live"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let finished = ledger.reduce(
            .surfaceState(
                surface,
                request: request,
                altScreen: false,
                mouseMode: .off,
                columns: 80,
                rows: 24
            ),
            snapshot: state
        )
        XCTAssertTrue(finished.contains { effect in
            guard case .historyReady(
                let surfaceID,
                _,
                _,
                _,
                .preserveDistanceFromBottom
            ) = effect else { return false }
            return surfaceID == surface
        })
    }

    func test_sideChannelTruePaneChangeCancelsRatherThanMigratesPendingGesture() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        _ = beginSideChannel(&ledger, snapshot: first)
        let started = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: first
        )
        let watchdog = try XCTUnwrap(started.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first)

        let second = snapshot(window: 1, pane: 2)
        let changed = reduceMessage(
            &ledger,
            .windowPaneChanged(windowId: WindowId(1), activePaneId: PaneId(2)),
            snapshot: second
        )
        XCTAssertTrue(changed.contains(.cancelTimer(token: watchdog)))
        XCTAssertFalse(changed.contains { effect in
            if case .sendCommand = effect { return true }
            return false
        })
        let stale = reply(&ledger, snapshot: second, lines: [metadata(pane: 1, historySize: 20)])
        XCTAssertTrue(stale.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("stale-reply")
        })

        let original = snapshot(window: 1, pane: 1)
        _ = reduceMessage(
            &ledger,
            .windowPaneChanged(windowId: WindowId(1), activePaneId: PaneId(1)),
            snapshot: original
        )
        let resized = ledger.noteAppliedClientSize(columns: 100, rows: 24)
        XCTAssertFalse(containsCommand(
            resized,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
    }

    func test_sideChannelWatchdogReleasesSingleFlightWithoutBindingOrFeeding() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = beginSideChannel(&ledger, snapshot: state)

        let started = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: state
        )
        let token = started.compactMap { effect -> UInt64? in
            if case .armTimer(let token, _) = effect { return token }
            return nil
        }.first
        guard let token else { return XCTFail("side-channel request must arm a watchdog") }
        XCTAssertTrue(containsCommand(started, RenderCommands.renderedPaneMetadata(target: PaneId(1))))

        let timedOut = ledger.reduce(.timerFired(token: token), snapshot: state)
        XCTAssertEqual(timedOut, [.diagnostic("render-ledger side-channel-watchdog surface=live")])
        XCTAssertNil(ledger.owner(for: surface))
        XCTAssertFalse(timedOut.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertFalse(timedOut.contains { if case .feed = $0 { return true }; return false })

        let retried = ledger.reduce(.findOpened(surface), snapshot: state)
        XCTAssertTrue(containsCommand(retried, RenderCommands.renderedPaneMetadata(target: PaneId(1))))
        XCTAssertTrue(reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]).contains {
            if case .diagnostic(let message) = $0 { return message.contains("stale-reply") }
            return false
        })
        assertStaleCapture(&ledger, snapshot: state)
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]), [])
        let waiting = reply(&ledger, snapshot: state, lines: ["retry history", "live"])
        guard let request = resolveRequest(waiting) else { return XCTFail("retry capture was lost") }
        let finished = ledger.reduce(.surfaceState(surface, request: request, altScreen: false,
                                                   mouseMode: .off, columns: 80, rows: 24), snapshot: state)
        XCTAssertEqual(feeds(in: finished).map(\.source), [.moshHistory])
        XCTAssertEqual(ledger.pendingCommandCount, 0)
    }

    func test_sideChannelCreditsCompleteHistoryToTheScrollbackLimit() throws {
        let configuration = TmuxRenderLedger.Configuration(moshPageDepth: 2, scrollbackLimit: 10)
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = snapshot()
        let effects = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 1,
            captureLines: ["only known history", "live"],
            depth: 2
        )
        XCTAssertTrue(effects.contains {
            if case .historyReady(_, _, let depth, let historySize, _) = $0 {
                return depth == 10 && historySize == 1
            }
            return false
        })
        let repaintIndex = try XCTUnwrap(effects.firstIndex(of: .requestTransportFullFrame))
        let historyIndex = try XCTUnwrap(effects.firstIndex {
            if case .historyReady = $0 { return true }
            return false
        })
        XCTAssertLessThan(repaintIndex, historyIndex)
        XCTAssertEqual(ledger.reduce(.findOpened(surface), snapshot: state), [])
    }

    func test_sideChannelDeepenRebindsWithAFreshEpochBeforeReplacingHistory() throws {
        let configuration = TmuxRenderLedger.Configuration(moshPageDepth: 2, scrollbackLimit: 10)
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = snapshot()
        _ = finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 20,
            captureLines: ["initial history", "live"],
            depth: 2
        )
        let prior = try XCTUnwrap(ledger.owner(for: surface))

        let start = ledger.reduce(.findOpened(surface), snapshot: state)
        XCTAssertTrue(containsCommand(start, RenderCommands.renderedPaneMetadata(target: PaneId(1))))
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 20)]),
            []
        )
        let waiting = reply(&ledger, snapshot: state, lines: ["deeper history", "live"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let effects = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: state
        )

        let rebound = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertNotEqual(rebound.epoch, prior.epoch)
        let bindIndex = try XCTUnwrap(effects.firstIndex {
            if case .bindSurface(let id, let owner) = $0 { return id == surface && owner == rebound }
            return false
        })
        let feedIndex = try XCTUnwrap(effects.firstIndex {
            if case .feed(let id, let owner, _, .moshHistory) = $0 { return id == surface && owner == rebound }
            return false
        })
        XCTAssertLessThan(bindIndex, feedIndex)
        XCTAssertTrue(effects.contains {
            if case .historyReady(_, let owner, _, _, .preserveDistanceFromBottom) = $0 { return owner == rebound }
            return false
        })
    }

    func test_sizeEpochResyncIsBoundedAndNeverPaintsAKnownStaleFrame() throws {
        let configuration = TmuxRenderLedger.Configuration(maximumSizeResyncAttempts: 1)
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = snapshot()
        _ = ledger.reduce(.clientSize(columns: 80, rows: 2), snapshot: state)
        _ = beginInline(&ledger, snapshot: state)
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])

        _ = ledger.reduce(.clientSize(columns: 81, rows: 2), snapshot: state)
        let request = try XCTUnwrap(resolveRequest(reply(&ledger, snapshot: state, lines: ["first capture"])))
        let firstResync = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 81, rows: 2),
            snapshot: state
        )
        XCTAssertTrue(firstResync.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("size-resync surface=live attempt=1") }
            return false
        })
        XCTAssertTrue(containsCommand(firstResync, RenderCommands.renderedPaneMetadata(target: WindowId(1))))

        // The two client-size commands were queued before the restarted
        // metadata query. Their replies are FIFO-discarded, then the refresh
        // reply becomes authoritative again.
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: []), [])
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: []), [])
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000))]
        )

        _ = ledger.reduce(.clientSize(columns: 82, rows: 2), snapshot: state)
        let finalRequest = try XCTUnwrap(resolveRequest(reply(&ledger, snapshot: state, lines: ["second capture"])))
        let exhausted = ledger.reduce(
            .surfaceState(surface, request: finalRequest, altScreen: false, mouseMode: .off, columns: 82, rows: 2),
            snapshot: state
        )
        XCTAssertFalse(exhausted.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertTrue(feeds(in: exhausted).isEmpty)
        XCTAssertTrue(exhausted.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("size-resync-gave-up") }
            return false
        })
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
        XCTAssertNil(ledger.owner(for: surface))
    }

    func test_repeatedClientSizeReplaysWithoutInvalidatingTheInFlightCaptureEpoch() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = ledger.reduce(.clientSize(columns: 80, rows: 24), snapshot: state)
        _ = beginInline(&ledger, snapshot: state)

        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000))]
        )
        let replay = ledger.reduce(.clientSize(columns: 80, rows: 24), snapshot: state)
        XCTAssertEqual(
            replay.compactMap { effect -> String? in
                if case .sendCommand(let command) = effect { return command }
                return nil
            },
            ["refresh-client -C 80,24", TmuxClientSizeReplay.latestFenceCommand]
        )

        // The deep capture was already sent, so it completes ahead of the
        // replay's fire-and-forget responses. An unchanged geometry must not
        // make that authoritative frame hit the size-resync path.
        let waiting = reply(&ledger, snapshot: state, lines: ["same-size capture"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let completed = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: state
        )
        XCTAssertTrue(completed.contains { if case .bindSurface = $0 { return true }; return false })
        XCTAssertFalse(completed.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("size-resync") }
            return false
        })
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: []), [])
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: []), [])
    }

    func test_shiftedReplyFifoRealignsOnTheProbeAndTheRetryBinds() throws {
        let live = SurfaceId("live")
        let state = snapshot()
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)

        // A platform command the adapter registered but never wrote: one
        // stranded entry shifts every later reply onto its neighbour, and
        // because empty replies are legal the shift stays silent until a
        // reply has to be parsed.
        _ = ledger.enqueuePlatformCommand("display-message -p '#{client_flags}'")
        let declared = ledger.reduce(.surfacesDeclared([.init(
            surfaceID: live,
            presentation: .single,
            windowID: WindowId(1),
            paneID: PaneId(1)
        )]), snapshot: state)
        _ = ledger.reduce(.refreshRequested(live, stage: .deep, reason: "mount"), snapshot: state)
        XCTAssertEqual(declared, [])
        XCTAssertEqual(ledger.pendingCommandCount, 2, "the stranded entry sits ahead of the metadata query")

        // The metadata row is handed to the stranded platform entry.
        let stolen = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        XCTAssertEqual(
            stolen,
            [.commandReply(tag: 1, success: true, lines: [metadata(pane: 1)])]
        )

        // So the metadata purpose is answered by a reply that was never its
        // own. That is the moment the drift becomes measurable.
        let marker = RenderCommands.fifoSyncMarker(sequence: 1)
        let misattributed = reply(
            &ledger,
            snapshot: state,
            lines: ["attached,focused,control-mode,pause-after=5,UTF-8"]
        )
        XCTAssertTrue(misattributed.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("metadata-unparsed") }
            return false
        })
        XCTAssertTrue(containsCommand(misattributed, RenderCommands.fifoSync(marker: marker)))

        // The probe answers by content, so the queue realigns no matter how
        // far it drifted, and the retry lands on an aligned queue.
        let realigned = reply(&ledger, snapshot: state, lines: [marker])
        XCTAssertTrue(realigned.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("fifo-resynced") }
            return false
        })
        XCTAssertEqual(ledger.pendingCommandCount, 0)

        let retryToken = try XCTUnwrap(armedTimerToken(misattributed))
        let retry = ledger.reduce(.timerFired(token: retryToken), snapshot: state)
        XCTAssertTrue(containsCommand(retry, RenderCommands.renderedPaneMetadata(target: WindowId(1))))
        let answered = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        XCTAssertFalse(answered.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("metadata-unparsed") }
            return false
        })
    }

    func test_probeReplyIsMatchedByContentAndNeverByAMultiLineCapture() throws {
        let live = SurfaceId("live")
        let state = snapshot()
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        _ = ledger.enqueuePlatformCommand("display-message -p '#{client_flags}'")
        _ = ledger.reduce(.surfacesDeclared([.init(
            surfaceID: live,
            presentation: .single,
            windowID: WindowId(1),
            paneID: PaneId(1)
        )]), snapshot: state)
        _ = ledger.reduce(.refreshRequested(live, stage: .deep, reason: "mount"), snapshot: state)
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        _ = reply(&ledger, snapshot: state, lines: ["not a metadata row"])

        let marker = RenderCommands.fifoSyncMarker(sequence: 1)
        // A pane that happens to be displaying the marker must not be able to
        // realign the queue: only a reply that is exactly the marker counts.
        let capture = reply(&ledger, snapshot: state, lines: [marker, "second line"])
        XCTAssertFalse(capture.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("fifo-resynced") }
            return false
        })
    }


    // MARK: - Inline (SSH+tmux) history ladder

    /// The first inline fill asks for `deepHistoryDepth` rows and is credited
    /// with exactly that, because the pane's `history_size` proves older rows
    /// were left behind.
    func test_inlineFirstFillCreditsTheCaptureDepthAndReportsMoreHistory() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        let effects = finishInitialInline(
            &ledger,
            snapshot: state,
            captureLines: ["oldest visible", "prompt"],
            historySize: 7_009
        )
        XCTAssertEqual(feeds(in: effects).map(\.source), [.deepRepaint])
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(
            settlements(in: effects),
            [.init(owner: owner, depth: 2_000, historySize: 7_009, canDeepen: true)]
        )
        guard case .inlineHistorySettled? = effects.last else {
            return XCTFail("the settle is the terminal effect of the capture it describes")
        }
    }

    /// The reader's gesture climbs to the scrollback preference, replaying the
    /// full capture under a new owner epoch so the platform clears first.
    func test_inlineScrollbackRequestDeepensToTheScrollbackLimitAndExhausts() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        let first = finishInitialInline(
            &ledger,
            snapshot: state,
            captureLines: ["prompt"],
            historySize: 7_009
        )
        let firstOwner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(settlements(in: first).map(\.canDeepen), [true])

        let requested = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: state
        )
        XCTAssertEqual(
            requested,
            [.sendCommand(RenderCommands.renderedPaneMetadata(target: WindowId(1)))]
        )

        let deepened = finishInlineDeep(
            &ledger,
            snapshot: state,
            captureLines: ["deep history", "prompt"],
            historySize: 7_009,
            depth: 10_000
        )
        let deepenedOwner = try XCTUnwrap(
            deepened.compactMap { effect -> RenderOwner? in
                guard case .bindSurface(_, let owner) = effect else { return nil }
                return owner
            }.first
        )
        XCTAssertGreaterThan(deepenedOwner.epoch, firstOwner.epoch,
                             "a deepen replaces the transcript, so the bind must clear it first")
        XCTAssertEqual(feeds(in: deepened).map(\.source), [.deepRepaint])
        XCTAssertEqual(
            settlements(in: deepened),
            [.init(owner: deepenedOwner, depth: 10_000, historySize: 7_009, canDeepen: false)]
        )
    }

    /// The deepest rung is answered from ledger state: no capture, no wait.
    func test_inlineExhaustedHistoryAnswersImmediatelyWithoutACapture() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["prompt"], historySize: 7_009)
        _ = ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        _ = finishInlineDeep(
            &ledger,
            snapshot: state,
            captureLines: ["deep history", "prompt"],
            historySize: 7_009,
            depth: 10_000
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))

        let again = ledger.reduce(
            .scrollbackRequested(surface, pointsY: 1, isInertial: false),
            snapshot: state
        )
        XCTAssertEqual(
            again,
            [.inlineHistorySettled(surface, owner: owner, depth: 10_000, historySize: 7_009, canDeepen: false)]
        )
        XCTAssertFalse(ledger.hasPendingRender)
    }

    /// A pane whose whole history fitted in the first fill is exhausted at
    /// once, and is credited with the full ladder depth so a later shallow
    /// repaint of the same pane cannot un-exhaust it.
    func test_inlineSmallHistoryIsExhaustedAtTheFirstFill() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        let effects = finishInitialInline(
            &ledger,
            snapshot: state,
            captureLines: ["prompt"],
            historySize: 300
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(
            settlements(in: effects),
            [.init(owner: owner, depth: 10_000, historySize: 300, canDeepen: false)]
        )
        XCTAssertEqual(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state),
            [.inlineHistorySettled(surface, owner: owner, depth: 10_000, historySize: 300, canDeepen: false)]
        )
    }

    /// Single-flight: a gesture that lands on a busy surface issues nothing,
    /// and the refresh already holding the surface settles it exactly once.
    func test_inlineRequestWhilePendingIsSettledByThePendingRefresh() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = beginInline(&ledger, snapshot: state)

        XCTAssertEqual(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state),
            [.diagnostic("render-ledger inline-history-request-ignored surface=live reason=unowned")],
            "an unowned surface has nothing to tag a settle to"
        )

        let settledAttach = finishInitialInline(
            &ledger,
            snapshot: state,
            captureLines: ["prompt"],
            historySize: 7_009
        )
        XCTAssertEqual(settlements(in: settledAttach).count, 1)

        // Start a refresh, then land the gesture on top of it.
        _ = ledger.reduce(.refreshRequested(surface, stage: .viewportOnly, reason: "probe"), snapshot: state)
        XCTAssertTrue(ledger.hasPendingRender)
        XCTAssertEqual(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state),
            [],
            "single-flight: the pending refresh owns the next terminal outcome"
        )

        let pane = state.windows.first!.activePaneID!.rawValue
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: pane, historySize: 7_009)])
        let waiting = reply(&ledger, snapshot: state, lines: ["prompt"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let completion = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: state
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(
            settlements(in: completion),
            [.init(owner: owner, depth: 2_000, historySize: 7_009, canDeepen: true)],
            "a shallower refresh still answers the latched gesture, exactly once"
        )
    }

    /// A window switch retargets the surface, so the credit from the old pane
    /// is discarded and the chained deep rebuild credits the new one.
    func test_inlineIdentityChangeResetsTheCreditedDepth() throws {
        var ledger = TmuxRenderLedger()
        let first = snapshot(window: 1, pane: 1)
        _ = finishInitialInline(&ledger, snapshot: first, captureLines: ["prompt"], historySize: 300)
        XCTAssertFalse(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: first)
                .contains { if case .sendCommand = $0 { return true }; return false },
            "the small first pane is exhausted"
        )

        let second = snapshot(window: 2, pane: 2)
        let switched = reduceMessage(
            &ledger,
            .sessionWindowChanged(sessionId: SessionId(0), windowId: WindowId(2)),
            snapshot: second
        )
        XCTAssertTrue(containsCommand(switched, RenderCommands.renderedPaneMetadata(target: WindowId(2))))

        // Viewport stage for the new window, then the chained deep rebuild.
        XCTAssertEqual(
            reply(&ledger, snapshot: second, lines: [metadata(pane: 2, historySize: 4_200)]),
            [.sendCommand(RenderCommands.viewport(target: WindowId(2)))]
        )
        let viewportWaiting = reply(&ledger, snapshot: second, lines: ["new pane"])
        let viewportRequest = try XCTUnwrap(resolveRequest(viewportWaiting))
        let viewportCompletion = ledger.reduce(
            .surfaceState(surface, request: viewportRequest, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: second
        )
        XCTAssertTrue(settlements(in: viewportCompletion).isEmpty,
                      "a viewport repaint nobody is waiting on settles nothing")
        XCTAssertTrue(containsCommand(viewportCompletion, RenderCommands.renderedPaneMetadata(target: WindowId(2))))

        let deep = finishInlineDeep(
            &ledger,
            snapshot: second,
            captureLines: ["new pane deep"],
            historySize: 4_200
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(
            settlements(in: deep),
            [.init(owner: owner, depth: 2_000, historySize: 4_200, canDeepen: true)],
            "the new pane starts the ladder again at the first fill"
        )
    }

    /// Opening find deepens exactly as a scroll gesture does.
    func test_inlineFindOpenedDeepensTheSameWayAsAScrollGesture() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["prompt"], historySize: 7_009)

        XCTAssertEqual(
            ledger.reduce(.findOpened(surface), snapshot: state),
            [.sendCommand(RenderCommands.renderedPaneMetadata(target: WindowId(1)))]
        )
        let deepened = finishInlineDeep(
            &ledger,
            snapshot: state,
            captureLines: ["deep history", "prompt"],
            historySize: 7_009,
            depth: 10_000
        )
        XCTAssertEqual(settlements(in: deepened).map(\.depth), [10_000])
        XCTAssertEqual(settlements(in: deepened).map(\.canDeepen), [false])
    }

    /// The reader's own scrollback preference is the ceiling: a smaller limit
    /// shortens both the first fill and the top of the ladder.
    func test_inlineScrollbackLimitBoundsBothRungsOfTheLadder() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        XCTAssertEqual(
            ledger.reduce(.surfacesDeclared([.init(surfaceID: surface, presentation: .single)]), snapshot: state),
            []
        )
        XCTAssertEqual(ledger.reduce(.scrollbackLimit(lines: 1_000), snapshot: state), [])
        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)

        let effects = finishInlineDeep(
            &ledger,
            snapshot: state,
            captureLines: ["prompt"],
            historySize: 7_009,
            depth: 1_000
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(
            settlements(in: effects),
            [.init(owner: owner, depth: 1_000, historySize: 7_009, canDeepen: false)],
            "the full inline depth is the scrollback limit, so the first fill already reached it"
        )
        XCTAssertEqual(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state),
            [.inlineHistorySettled(surface, owner: owner, depth: 1_000, historySize: 7_009, canDeepen: false)],
            "a deepen must never ask for more rows than the reader keeps"
        )
    }

    /// A deep capture that exhausts its retry budget still releases the
    /// reader's gesture; a platform latch has no watchdog of its own.
    /// A reader who opted out of local history entirely gets no ladder: the
    /// first fill is already the full depth, so nothing is ever deepened.
    func test_inlineZeroScrollbackLimitNeverDeepens() throws {
        var ledger = TmuxRenderLedger(configuration: .init(scrollbackLimit: 0))
        let state = snapshot()
        let effects = finishInitialInline(
            &ledger,
            snapshot: state,
            captureLines: ["prompt"],
            historySize: 7_009,
            depth: 0
        )
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertEqual(
            settlements(in: effects),
            [.init(owner: owner, depth: 0, historySize: 7_009, canDeepen: false)]
        )
        XCTAssertEqual(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state),
            [.inlineHistorySettled(surface, owner: owner, depth: 0, historySize: 7_009, canDeepen: false)]
        )
        XCTAssertFalse(ledger.hasPendingRender)
    }

    /// A transport boundary discards the pending deepen without a terminal
    /// outcome of its own; the one-settle promise is kept there too, with the
    /// reset state the boundary leaves behind.
    func test_inlineTransportLostSettlesALatchedDeepen() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["prompt"], historySize: 7_009)
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        _ = ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        XCTAssertTrue(ledger.hasPendingRender)

        let lost = ledger.reduce(.transportLost, snapshot: state)
        XCTAssertEqual(
            settlements(in: lost),
            [.init(owner: owner, depth: 0, historySize: 0, canDeepen: true)]
        )
    }

    func test_inlineTransportReattachSettlesALatchedDeepen() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["prompt"], historySize: 7_009)
        let owner = try XCTUnwrap(ledger.owner(for: surface))
        _ = ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        XCTAssertTrue(ledger.hasPendingRender)

        let attached = ledger.reduce(.transportAttached(.inline), snapshot: state)
        XCTAssertEqual(
            settlements(in: attached),
            [.init(owner: owner, depth: 0, historySize: 0, canDeepen: true)]
        )
    }

    /// A gesture that lands on a surface with no pending refresh but no
    /// latched deepen leaves a transport boundary silent: nothing is owed.
    func test_inlineTransportLostWithoutALatchedDeepenSettlesNothing() throws {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["prompt"], historySize: 7_009)
        XCTAssertEqual(settlements(in: ledger.reduce(.transportLost, snapshot: state)), [])
    }

    func test_inlineDeepGiveUpStillSettlesTheWaitingGesture() throws {
        var ledger = TmuxRenderLedger(configuration: .init(maximumDeepRetryAttempts: 0))
        let state = snapshot()
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["prompt"], historySize: 7_009)
        let owner = try XCTUnwrap(ledger.owner(for: surface))

        XCTAssertEqual(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state),
            [.sendCommand(RenderCommands.renderedPaneMetadata(target: WindowId(1)))]
        )
        XCTAssertEqual(
            reply(&ledger, snapshot: state, lines: [metadata(pane: 1, historySize: 7_009)]),
            [.sendCommand(RenderCommands.deepPrimary(target: WindowId(1), depth: 10_000))]
        )
        let givenUp = reply(&ledger, snapshot: state, lines: [])
        XCTAssertTrue(givenUp.contains { effect in
            guard case .diagnostic(let message) = effect else { return false }
            return message.contains("refresh-gave-up") && message.contains("deep-primary-empty")
        })
        XCTAssertEqual(
            settlements(in: givenUp),
            [.init(owner: owner, depth: 2_000, historySize: 7_009, canDeepen: true)],
            "nothing was captured, so the credit is unchanged and the reader may retry"
        )
        XCTAssertFalse(ledger.hasPendingRender)

        // The retry is admitted, which is what `canDeepen: true` promised.
        XCTAssertEqual(
            ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state),
            [.sendCommand(RenderCommands.renderedPaneMetadata(target: WindowId(1)))]
        )
    }

    /// The mosh side channel keeps its own ladder and never speaks the inline
    /// settling signal, on any of its request paths.
    func test_sideChannelHistoryNeverEmitsTheInlineSettlingSignal() {
        var ledger = TmuxRenderLedger()
        let state = snapshot()
        var observed: [RenderEffect] = []
        observed += finishSideChannelHistory(
            &ledger,
            snapshot: state,
            historySize: 7_009,
            captureLines: ["old", "live"]
        )
        observed += ledger.reduce(.scrollbackRequested(surface, pointsY: 1, isInertial: false), snapshot: state)
        observed += ledger.reduce(.findOpened(surface), snapshot: state)
        observed += ledger.reduce(.scrollbackReturnedToTail(surface), snapshot: state)
        observed += ledger.reduce(.userInput, snapshot: state)
        XCTAssertTrue(
            observed.contains { if case .historyReady = $0 { return true }; return false },
            "the mosh ladder must still stage its history"
        )
        XCTAssertTrue(settlements(in: observed).isEmpty)
    }

    func test_inlineHistorySettledRoundTripsThroughTheSharedWireShape() throws {
        let effect = RenderEffect.inlineHistorySettled(
            surface,
            owner: .init(windowID: WindowId(1), paneID: PaneId(2), epoch: 3),
            depth: 10_000,
            historySize: 7_009,
            canDeepen: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(effect)
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            "{\"canDeepen\":false,\"depth\":10000,\"historySize\":7009,"
                + "\"kind\":\"inlineHistorySettled\",\"owner\":{\"epoch\":3,\"paneID\":2,\"windowID\":1},"
                + "\"surfaceID\":\"live\"}"
        )
        XCTAssertEqual(try JSONDecoder().decode(RenderEffect.self, from: data), effect)
    }

    func test_checkedInRenderLedgerVectorRunsThroughRuntimeAndPinsFeedHashes() throws {
        let vector = try JSONDecoder().decode(RenderLedgerVector.self, from: Data(contentsOf: vectorURL()))
        XCTAssertEqual(vector.version, 1)
        XCTAssertFalse(vector.cases.isEmpty)

        for testCase in vector.cases + vector.abiCases {
            var runtime = TmuxRuntimeEngine()
            var ledger = TmuxRenderLedger()
            var actualEffects: [[String: Any]] = []
            for step in testCase.steps {
                let effects: [RenderEffect]
                switch step.input {
                case .wire(let wire):
                    let batch = runtime.feed(Array(wire.utf8))
                    effects = batch.orderedSteps.flatMap {
                        ledger.reduce($0.event, snapshot: $0.snapshot)
                    }
                case .fact(let fact):
                    effects = ledger.reduce(fact, snapshot: runtime.snapshot)
                case .platformCommand(let command):
                    _ = ledger.enqueuePlatformCommand(command)
                    effects = []
                }
                actualEffects.append(contentsOf: try normalized(effects, ledger: ledger))
            }
            let expected = try testCase.expectedEffects.map(jsonObject)
            XCTAssertEqual(
                canonicalJSON(actualEffects),
                canonicalJSON(expected),
                testCase.name
            )
        }
    }
}

private extension RenderLedgerTests {
    func snapshot(window: Int = 1, pane: Int = 1, alternateScreen: Bool = false) -> TmuxSnapshot {
        .init(
            sessionID: SessionId(0),
            sessionName: "work",
            activeWindowID: WindowId(window),
            windows: [
                .init(
                    id: WindowId(window),
                    name: "window-\(window)",
                    activePaneID: PaneId(pane),
                    panes: [.init(id: PaneId(pane), isActive: true, isAlternateScreen: alternateScreen)]
                ),
            ],
            authority: .unknown
        )
    }

    func singleLayoutSnapshot(columns: Int) -> TmuxSnapshot {
        let rect = CellRect(width: columns, height: 24, x: 0, y: 0)
        let layout = WindowLayout(root: .leaf(paneId: PaneId(1), rect: rect))
        return .init(
            sessionID: SessionId(0),
            sessionName: "work",
            activeWindowID: WindowId(1),
            windows: [.init(
                id: WindowId(1),
                name: "single",
                activePaneID: PaneId(1),
                panes: [.init(id: PaneId(1), isActive: true, contentRect: rect)],
                layout: layout,
                visibleLayout: layout
            )],
            authority: .unknown
        )
    }

    func gridSnapshot(
        firstWidth: Int = 40,
        secondWidth: Int = 39,
        totalWidth: Int = 80
    ) -> TmuxSnapshot {
        let first = CellRect(width: firstWidth, height: 24, x: 0, y: 0)
        let second = CellRect(width: secondWidth, height: 24, x: firstWidth + 1, y: 0)
        let layout = WindowLayout(root: .split(
            axis: .horizontal,
            rect: CellRect(width: totalWidth, height: 24, x: 0, y: 0),
            children: [
                .leaf(paneId: PaneId(1), rect: first),
                .leaf(paneId: PaneId(2), rect: second),
            ]
        ))
        return .init(
            sessionID: SessionId(0),
            sessionName: "work",
            activeWindowID: WindowId(1),
            windows: [.init(
                id: WindowId(1),
                name: "grid",
                activePaneID: PaneId(1),
                panes: [
                    .init(id: PaneId(1), isActive: true, contentRect: first),
                    .init(id: PaneId(2), contentRect: second),
                ],
                layout: layout
            )],
            authority: .unknown
        )
    }

    func makeForegroundGridOverflowRecapture(
        maximumViewportRetryAttempts: Int
    ) -> (TmuxRenderLedger, TmuxSnapshot, SurfaceId) {
        let paneOneSurface = SurfaceId("pane-1")
        let paneTwoSurface = SurfaceId("pane-2")
        let state = gridSnapshot()
        var ledger = TmuxRenderLedger(configuration: .init(
            maximumViewportRetryAttempts: maximumViewportRetryAttempts,
            maximumForegroundOutputBytes: 4
        ))

        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        _ = ledger.reduce(.appBackground, snapshot: state)
        _ = ledger.reduce(.appForeground, snapshot: state)
        _ = ledger.reduce(.surfacesDeclared([
            .init(
                surfaceID: paneOneSurface,
                presentation: .grid,
                windowID: WindowId(1),
                paneID: PaneId(1)
            ),
            .init(
                surfaceID: paneTwoSurface,
                presentation: .grid,
                windowID: WindowId(1),
                paneID: PaneId(2)
            ),
        ]), snapshot: state)

        _ = ledger.reduce(
            .refreshRequested(paneOneSurface, stage: .deep, reason: "mount"),
            snapshot: state
        )
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        _ = reply(&ledger, snapshot: state, lines: ["pane one deep"])
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let paneOneViewport = reply(
            &ledger,
            snapshot: state,
            lines: ["pane one viewport"]
        )
        let paneOneRequest = try! XCTUnwrap(resolveRequest(
            paneOneViewport,
            surfaceID: paneOneSurface
        ))
        _ = ledger.reduce(
            .surfaceState(
                paneOneSurface,
                request: paneOneRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 40,
                rows: 24
            ),
            snapshot: state
        )
        _ = reduceMessage(
            &ledger,
            .output(paneId: PaneId(1), data: Array("overflow".utf8)),
            snapshot: state
        )

        _ = ledger.reduce(
            .refreshRequested(paneTwoSurface, stage: .deep, reason: "mount"),
            snapshot: state
        )
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 2)])
        _ = reply(&ledger, snapshot: state, lines: ["pane two deep"])
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 2)])
        let paneTwoViewport = reply(
            &ledger,
            snapshot: state,
            lines: ["pane two viewport"]
        )
        let paneTwoRequest = try! XCTUnwrap(resolveRequest(
            paneTwoViewport,
            surfaceID: paneTwoSurface
        ))
        let effects = ledger.reduce(
            .surfaceState(
                paneTwoSurface,
                request: paneTwoRequest,
                altScreen: false,
                mouseMode: .off,
                columns: 40,
                rows: 24
            ),
            snapshot: state
        )
        XCTAssertTrue(containsCommand(
            effects,
            RenderCommands.renderedPaneMetadata(target: PaneId(1))
        ))
        XCTAssertEqual(
            ledger.pendingReason(for: paneOneSurface),
            "app-foreground-overflow"
        )
        return (ledger, state, paneOneSurface)
    }

    func metadata(pane: Int, alt: Bool = false, historySize: Int = 0) -> String {
        [
            "%\(pane)", "0", "0", "pane", "window", "host", alt ? "1" : "0",
            "\(historySize)", "0", "23", "1", "0", "0", "0", "1", "0", "0", "0", "0", "0", "0", "0",
        ].joined(separator: "\t")
    }

    func assertSideChannelTransitionClearsOnly(
        _ effects: [RenderEffect],
        expectedWindow: WindowId,
        expectedPane: PaneId,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(effects.count, 1, "a side-channel identity transition must only clear", file: file, line: line)
        guard case .bindSurface(surface, let owner)? = effects.first else {
            return XCTFail("a side-channel identity transition must bind the cleared live surface", file: file, line: line)
        }
        XCTAssertEqual(owner.windowID, expectedWindow, file: file, line: line)
        XCTAssertEqual(owner.paneID, expectedPane, file: file, line: line)
        XCTAssertFalse(
            effects.contains(.requestTransportFullFrame),
            "the post-history mosh viewport re-sync must not run at side-channel bind time",
            file: file,
            line: line
        )
        XCTAssertFalse(effects.contains { if case .sendCommand = $0 { return true }; return false }, file: file, line: line)
        XCTAssertFalse(effects.contains { if case .feed = $0 { return true }; return false }, file: file, line: line)
    }

    @discardableResult
    func beginInline(_ ledger: inout TmuxRenderLedger, snapshot: TmuxSnapshot) -> [RenderEffect] {
        XCTAssertEqual(
            ledger.reduce(.surfacesDeclared([.init(surfaceID: surface, presentation: .single)]), snapshot: snapshot),
            []
        )
        let effects = ledger.reduce(.transportAttached(.inline), snapshot: snapshot)
        XCTAssertTrue(containsCommand(effects, RenderCommands.renderedPaneMetadata(target: snapshot.activeWindowID!)))
        return effects
    }

    @discardableResult
    func finishInitialInline(
        _ ledger: inout TmuxRenderLedger,
        snapshot: TmuxSnapshot,
        captureLines: [String],
        historySize: Int = 0,
        depth: Int = 2_000
    ) -> [RenderEffect] {
        _ = beginInline(&ledger, snapshot: snapshot)
        return finishInlineDeep(
            &ledger,
            snapshot: snapshot,
            captureLines: captureLines,
            historySize: historySize,
            depth: depth
        )
    }

    /// Answer an inline `.deep` refresh that has already issued its metadata
    /// query: metadata row, capture reply, then the platform's surface state.
    @discardableResult
    func finishInlineDeep(
        _ ledger: inout TmuxRenderLedger,
        snapshot: TmuxSnapshot,
        captureLines: [String],
        historySize: Int = 0,
        depth: Int = 2_000,
        rows: Int = 24
    ) -> [RenderEffect] {
        let pane = snapshot.windows.first!.activePaneID!.rawValue
        XCTAssertEqual(
            reply(&ledger, snapshot: snapshot, lines: [metadata(pane: pane, historySize: historySize)]),
            [.sendCommand(RenderCommands.deepPrimary(target: snapshot.activeWindowID!, depth: depth))]
        )
        let waiting = reply(&ledger, snapshot: snapshot, lines: captureLines)
        let request = try! XCTUnwrap(resolveRequest(waiting))
        return ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: rows),
            snapshot: snapshot
        )
    }

    struct InlineHistorySettlement: Equatable {
        var owner: RenderOwner
        var depth: Int
        var historySize: Int
        var canDeepen: Bool
    }

    func settlements(in effects: [RenderEffect]) -> [InlineHistorySettlement] {
        effects.compactMap { effect in
            guard case .inlineHistorySettled(_, let owner, let depth, let historySize, let canDeepen) = effect
            else { return nil }
            return .init(owner: owner, depth: depth, historySize: historySize, canDeepen: canDeepen)
        }
    }

    @discardableResult
    func beginSideChannel(_ ledger: inout TmuxRenderLedger, snapshot: TmuxSnapshot) -> [RenderEffect] {
        XCTAssertEqual(
            ledger.reduce(.surfacesDeclared([.init(surfaceID: surface, presentation: .single)]), snapshot: snapshot),
            []
        )
        let effects = ledger.reduce(.transportAttached(.sideChannel), snapshot: snapshot)
        XCTAssertTrue(effects.isEmpty)
        return effects
    }

    @discardableResult
    func finishSideChannelHistory(
        _ ledger: inout TmuxRenderLedger,
        snapshot: TmuxSnapshot,
        historySize: Int,
        captureLines: [String],
        depth: Int = 240,
        present: Bool = true,
        surfaceID: SurfaceId = .live,
        paneID: PaneId? = nil
    ) -> [RenderEffect] {
        if ledger.profile == nil { _ = beginSideChannel(&ledger, snapshot: snapshot) }
        let start = ledger.reduce(.scrollbackRequested(surfaceID, pointsY: 1, isInertial: false), snapshot: snapshot)
        let pane = paneID?.rawValue ?? snapshot.windows.first!.activePaneID!.rawValue
        XCTAssertTrue(containsCommand(start, RenderCommands.renderedPaneMetadata(target: PaneId(pane))))
        XCTAssertTrue(containsCommand(start, RenderCommands.moshHistory(target: PaneId(pane), depth: depth)))
        XCTAssertEqual(
            reply(&ledger, snapshot: snapshot, lines: [metadata(pane: pane, historySize: historySize)]),
            []
        )
        let waiting = reply(&ledger, snapshot: snapshot, lines: captureLines)
        let request = try! XCTUnwrap(resolveRequest(waiting, surfaceID: surfaceID))
        let effects = ledger.reduce(
            .surfaceState(surfaceID, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: snapshot
        )
        if present,
           let owner = effects.compactMap({ effect -> RenderOwner? in
               guard case .historyReady(let readySurface, let owner, _, _, _) = effect,
                     readySurface == surfaceID
               else { return nil }
               return owner
           }).first {
            XCTAssertEqual(
                ledger.reduce(.historyPresented(surfaceID, owner: owner), snapshot: snapshot),
                []
            )
        }
        return effects
    }

    func assertStaleCapture(_ ledger: inout TmuxRenderLedger, snapshot: TmuxSnapshot) {
        let effects = reply(&ledger, snapshot: snapshot, lines: ["superseded history"])
        XCTAssertTrue(effects.contains {
            if case .diagnostic(let message) = $0 {
                return message.contains("stale-reply") && message.contains("moshCapture")
            }
            return false
        })
        XCTAssertFalse(effects.contains { if case .feed = $0 { return true }; return false })
    }

    func reply(
        _ ledger: inout TmuxRenderLedger,
        snapshot: TmuxSnapshot,
        lines: [String],
        flags: Int = 1
    ) -> [RenderEffect] {
        ledger.reduce(.correlation(correlation(flags: flags, lines: lines)), snapshot: snapshot)
    }

    func failedReply(
        _ ledger: inout TmuxRenderLedger,
        snapshot: TmuxSnapshot,
        lines: [String],
        flags: Int = 1
    ) -> [RenderEffect] {
        let guardFrame = TmuxCommandGuard(time: 1, commandNumber: 1, flags: flags)
        return ledger.reduce(.correlation(.frameCompleted(.init(
            status: .error,
            begin: guardFrame,
            end: guardFrame,
            effectiveFlags: flags,
            guardMatches: true,
            lines: lines
        ))), snapshot: snapshot)
    }

    func correlation(flags: Int, lines: [String]) -> TmuxCorrelationEvent {
        let guardFrame = TmuxCommandGuard(time: 1, commandNumber: 1, flags: flags)
        return .frameCompleted(.init(
            status: .success,
            begin: guardFrame,
            end: guardFrame,
            effectiveFlags: flags,
            guardMatches: true,
            lines: lines
        ))
    }

    func reduceMessage(
        _ ledger: inout TmuxRenderLedger,
        _ message: TmuxMessage,
        snapshot: TmuxSnapshot
    ) -> [RenderEffect] {
        ledger.reduce(.message(message), snapshot: snapshot)
    }

    func armedTimerToken(_ effects: [RenderEffect]) -> UInt64? {
        effects.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.last
    }

    func containsCommand(_ effects: [RenderEffect], _ expected: String) -> Bool {
        effects.contains { if case .sendCommand(expected) = $0 { return true }; return false }
    }

    func resolveRequest(_ effects: [RenderEffect]) -> UInt64? {
        resolveRequest(effects, surfaceID: surface)
    }

    func resolveRequest(_ effects: [RenderEffect], surfaceID: SurfaceId) -> UInt64? {
        for effect in effects {
            if case .resolveSurfaceState(let id, let request) = effect, id == surfaceID { return request }
        }
        return nil
    }

    func feeds(in effects: [RenderEffect]) -> [(reference: RenderBytesRef, source: RenderFeedSource)] {
        effects.compactMap { effect in
            guard case .feed(_, _, let reference, let source) = effect else { return nil }
            return (reference, source)
        }
    }

    func normalized(_ effects: [RenderEffect], ledger: TmuxRenderLedger) throws -> [[String: Any]] {
        try effects.map { effect in
            var object = try jsonObject(JSONEncoder().encode(effect))
            if let ref = (object["bytesRef"] as? [String: Any])?["id"] as? NSNumber {
                let bytes = try XCTUnwrap(ledger.renderBytes(for: RenderBytesRef(ref.uint64Value)))
                object.removeValue(forKey: "bytesRef")
                object["bytes"] = [
                    "length": bytes.count,
                    "sha256": SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(),
                ]
            }
            return object
        }
    }

    func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func canonicalJSON(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func vectorURL() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("ProtocolVectors/tmux/render-ledger-v1.json")
    }
}

private struct RenderLedgerVector: Decodable {
    let version: Int
    let cases: [Case]
    let abiCases: [Case]

    struct Case: Decodable {
        let name: String
        let steps: [Step]
        let expectedEffects: [Data]
    }

    struct Step: Decodable {
        let input: Input
    }

    enum Input: Decodable {
        case wire(String)
        case fact(RenderFact)
        case platformCommand(String)

        private enum CodingKeys: String, CodingKey { case kind, wire, fact, command }
        private enum Kind: String, Decodable { case wire, fact, platformCommand }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .wire: self = .wire(try container.decode(String.self, forKey: .wire))
            case .fact: self = .fact(try container.decode(RenderFact.self, forKey: .fact))
            case .platformCommand:
                self = .platformCommand(try container.decode(String.self, forKey: .command))
            }
        }
    }
}

private extension RenderLedgerVector.Case {
    enum CodingKeys: String, CodingKey { case name, steps, expectedEffects }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        steps = try container.decode([RenderLedgerVector.Step].self, forKey: .steps)
        let rawEffects = try container.decode([JSONValue].self, forKey: .expectedEffects)
        expectedEffects = try rawEffects.map { value in
            try JSONSerialization.data(withJSONObject: value.foundationObject, options: [.sortedKeys])
        }
    }
}

private indirect enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    var foundationObject: Any {
        switch self {
        case .object(let value): return value.mapValues(\.foundationObject)
        case .array(let value): return value.map(\.foundationObject)
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}


extension RenderLedgerTests {
    func test_review610_ordinaryCaptureExhaustionIsTerminalWithoutRetainingAPendingRefresh() {
        var ledger = TmuxRenderLedger(configuration: .init(maximumViewportRetryAttempts: 0))
        let state = snapshot()
        XCTAssertFalse(ledger.hasFailedRefresh(for: surface), "a surface awaiting mount has not failed")
        _ = finishInitialInline(&ledger, snapshot: state, captureLines: ["ready"])
        _ = ledger.reduce(.refreshRequested(surface, stage: .viewportOnly, reason: "ordinary"), snapshot: state)
        XCTAssertTrue(ledger.isRefreshInFlight(for: surface))
        _ = reply(&ledger, snapshot: state, lines: ["invalid metadata"])
        XCTAssertFalse(ledger.hasPendingRender)
        XCTAssertFalse(ledger.isRefreshInFlight(for: surface))
        XCTAssertTrue(ledger.hasFailedRefresh(for: surface), "ordinary captures can fail without retaining a cut")

        _ = ledger.reduce(.refreshRequested(surface, stage: .viewportOnly, reason: "later-repaint"), snapshot: state)
        XCTAssertTrue(ledger.isRefreshInFlight(for: surface))
        XCTAssertFalse(ledger.hasFailedRefresh(for: surface), "a later repaint supersedes the failure")
    }
}
