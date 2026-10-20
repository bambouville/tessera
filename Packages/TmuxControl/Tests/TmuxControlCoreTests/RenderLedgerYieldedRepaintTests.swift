import XCTest
@testable import TmuxControlCore

/// P7/P8: while a peer holds the grid its relayouts cost this device no
/// capture, a take-back repaints the visible rows first (metadata and capture
/// in one round trip), and the history deepening waits until the authority
/// stops naming the peer.
final class RenderLedgerYieldedRepaintTests: XCTestCase {
    private let surface = SurfaceId.live
    private static let peer = TmuxGridAuthoritySnapshot.peer(
        deviceID: "PEER-DEVICE-9999",
        displayName: "iPhone",
        generation: 3
    )

    // MARK: - P7

    func test_peerRelayoutWhileIdleCapturesNothingUntilTheNextRefreshRebuilds() throws {
        var ledger = paintedLedger(columns: 80)
        let prior = try XCTUnwrap(ledger.owner(for: surface))

        for columns in [70, 60, 80, 50] {
            let effects = relayout(&ledger, columns: columns, authority: Self.peer)
            XCTAssertEqual(commands(effects), [], "a peer's relayout to \(columns) must not capture")
        }
        XCTAssertNil(ledger.pendingStage(for: surface))
        XCTAssertEqual(ledger.owner(for: surface), prior)

        // The claim's in-place repaint is upgraded to a rebuild of the
        // visible rows under a fresh owner: the surface missed a relayout.
        let repaint = ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 7),
            snapshot: snapshot(columns: 50, authority: Self.peer)
        )
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewport)
        XCTAssertEqual(commands(repaint), [
            RenderCommands.renderedPaneMetadata(target: WindowId(1)),
        ])
    }

    func test_peerRelayoutKeepsAnUnansweredRefreshAndReasksAnAnsweredOne() throws {
        var ledger = paintedLedger(columns: 80)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        _ = ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .deep, reason: "authority-reclaim", correlation: 9),
            snapshot: peerState
        )

        // tmux writes `%layout-change` only after applying the resize, so a
        // refresh with nothing answered yet already runs against it.
        XCTAssertEqual(commands(relayout(&ledger, columns: 70, authority: Self.peer)), [])
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
        XCTAssertEqual(ledger.pendingReason(for: surface), "authority-reclaim")

        // Its metadata answered against the old grid: re-ask at visible rows,
        // keeping the correlation the platform waits on.
        let answered = reply(&ledger, snapshot: peerState, lines: [metadata(pane: 1)])
        XCTAssertEqual(commands(answered), [RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000)])
        let reasked = relayout(&ledger, columns: 60, authority: Self.peer)
        XCTAssertFalse(reasked.contains { effect in
            if case .refreshFailed = effect { return true }
            return false
        }, "the re-ask must keep the claim's correlation: \(reasked)")
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewport)
        XCTAssertEqual(ledger.pendingReason(for: surface), "layout-change-yielded")
        // A visible refresh waits for the outstanding deep capture to drain.
        let waitToken = try XCTUnwrap(reasked.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.last, "\(reasked)")

        // The stale deep capture is dropped; the new visible pair completes
        // the correlated refresh without a deep chain while the peer holds.
        let peer60 = snapshot(columns: 60, authority: Self.peer)
        _ = reply(&ledger, snapshot: peer60, lines: ["stale deep"])
        XCTAssertEqual(
            commands(ledger.reduce(.timerFired(token: waitToken), snapshot: peer60)),
            [RenderCommands.renderedPaneMetadata(target: WindowId(1))]
        )
        XCTAssertEqual(
            commands(reply(&ledger, snapshot: peer60, lines: [metadata(pane: 1)])),
            [RenderCommands.viewport(target: WindowId(1))]
        )
        let finished = try finishCapture(&ledger, snapshot: peer60, columns: 60)
        XCTAssertTrue(finished.contains { effect in
            if case .refreshCompleted(_, _, _, 9) = effect { return true }
            return false
        }, "\(finished)")
        XCTAssertEqual(commands(finished), [], "deepening waits for the peer to go")
    }

    /// The take-back's in-place repaint still on the wire when a peer
    /// relayout lands keeps its commands but rebuilds: the surface's history
    /// was laid out for the old grid.
    func test_peerRelayoutTurnsAnUnansweredInPlaceRefreshIntoARebuild() throws {
        var ledger = paintedLedger(columns: 80, pipelines: true)
        let prior = try XCTUnwrap(ledger.owner(for: surface))
        _ = ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 5),
            snapshot: snapshot(columns: 80, authority: Self.peer)
        )
        XCTAssertEqual(commands(relayout(&ledger, columns: 70, authority: Self.peer)), [])
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewport)

        let peer70 = snapshot(columns: 70, authority: Self.peer)
        XCTAssertEqual(commands(reply(&ledger, snapshot: peer70, lines: [metadata(pane: 1)])), [])
        let finished = try finishCapture(&ledger, snapshot: peer70, columns: 70)
        XCTAssertEqual(feedSources(finished), [.viewportRepaint])
        let rebuilt = try XCTUnwrap(ledger.owner(for: surface))
        XCTAssertNotEqual(rebuilt.epoch, prior.epoch)
        XCTAssertTrue(finished.contains(.bindSurface(surface, owner: rebuilt)))
        XCTAssertEqual(commands(finished), [], "deepening waits for the peer to go")
        XCTAssertEqual(
            commands(ledger.noteAuthority(snapshot: snapshot(columns: 70, authority: .mine(generation: 6)))),
            [RenderCommands.renderedPaneMetadata(target: WindowId(1))]
        )
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
    }

    func test_ownerRelayoutStillRebuildsDeep() {
        var ledger = paintedLedger(columns: 80)
        let effects = relayout(&ledger, columns: 70, authority: .mine(generation: 1))
        XCTAssertEqual(commands(effects), [RenderCommands.renderedPaneMetadata(target: WindowId(1))])
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
        XCTAssertEqual(ledger.pendingReason(for: surface), "layout-change")
    }

    func test_owedRelayoutIsRebuiltVisibleFirstOnceThePeerIsGone() throws {
        var ledger = paintedLedger(columns: 80)
        _ = relayout(&ledger, columns: 70, authority: Self.peer)
        XCTAssertEqual(ledger.noteAuthority(snapshot: snapshot(columns: 70, authority: Self.peer)), [])

        let mine = snapshot(columns: 70, authority: .mine(generation: 4))
        let released = ledger.noteAuthority(snapshot: mine)
        XCTAssertEqual(commands(released), [RenderCommands.renderedPaneMetadata(target: WindowId(1))])
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewport)
        XCTAssertEqual(ledger.pendingReason(for: surface), "authority-released")
        XCTAssertEqual(ledger.noteAuthority(snapshot: mine), [], "released once")

        XCTAssertEqual(
            commands(reply(&ledger, snapshot: mine, lines: [metadata(pane: 1)])),
            [RenderCommands.viewport(target: WindowId(1))]
        )
        let visible = try finishCapture(&ledger, snapshot: mine, columns: 70)
        XCTAssertEqual(feedSources(visible), [.viewportRepaint])
        XCTAssertEqual(commands(visible), [RenderCommands.renderedPaneMetadata(target: WindowId(1))])
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep, "then the history")
    }

    // MARK: - P8

    func test_visibleRefreshWhileThePeerHoldsDefersItsDeepening() throws {
        var ledger = paintedLedger(columns: 80)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        _ = ledger.reduce(
            .refreshRequested(surface, stage: .viewport, reason: "authority-claim"),
            snapshot: peerState
        )
        _ = reply(&ledger, snapshot: peerState, lines: [metadata(pane: 1)])
        let visible = try finishCapture(&ledger, snapshot: peerState, columns: 80)
        XCTAssertEqual(feedSources(visible), [.viewportRepaint])
        XCTAssertEqual(commands(visible), [], "no 2,000-row capture while the peer holds the grid")
        XCTAssertNil(ledger.pendingStage(for: surface))

        // Any reduce that no longer names the peer releases it; the claim's
        // settlement goes through `noteAuthority`.
        let mine = snapshot(columns: 80, authority: .mine(generation: 4))
        let released = ledger.noteAuthority(snapshot: mine)
        XCTAssertEqual(commands(released), [RenderCommands.renderedPaneMetadata(target: WindowId(1))])
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
        XCTAssertEqual(ledger.pendingReason(for: surface), "authority-released-deep")
        XCTAssertEqual(
            commands(reply(&ledger, snapshot: mine, lines: [metadata(pane: 1)])),
            [RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000)]
        )
    }

    func test_deferredDeepeningIsReleasedByTheNextWireEventToo() throws {
        var ledger = paintedLedger(columns: 80)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        _ = ledger.reduce(.refreshRequested(surface, stage: .viewport, reason: "window-switch"), snapshot: peerState)
        _ = reply(&ledger, snapshot: peerState, lines: [metadata(pane: 1)])
        _ = try finishCapture(&ledger, snapshot: peerState, columns: 80)

        let unknown = snapshot(columns: 80, authority: .unknown)
        let released = ledger.reduce(.message(.output(paneId: PaneId(1), data: Array("x".utf8))), snapshot: unknown)
        XCTAssertTrue(released.contains(.sendCommand(RenderCommands.renderedPaneMetadata(target: WindowId(1)))))
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
    }

    func test_takeBackRefreshSendsMetadataAndCaptureTogether() throws {
        var ledger = paintedLedger(columns: 80, pipelines: true)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        let started = ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 5),
            snapshot: peerState
        )
        XCTAssertEqual(commands(started), [
            RenderCommands.renderedPaneMetadata(target: WindowId(1)),
            RenderCommands.viewport(target: WindowId(1)),
        ])
        XCTAssertEqual(
            commands(reply(&ledger, snapshot: peerState, lines: [metadata(pane: 1)])),
            [],
            "the capture is already on the wire"
        )
        let finished = try finishCapture(&ledger, snapshot: peerState, columns: 80)
        XCTAssertEqual(feedSources(finished).count, 1)
        XCTAssertTrue(finished.contains { effect in
            if case .refreshCompleted(_, _, _, 5) = effect { return true }
            return false
        })
    }

    func test_anyRefreshWhileThePeerHoldsIsPipelined() {
        var ledger = paintedLedger(columns: 80, pipelines: true)
        let started = ledger.reduce(
            .refreshRequested(surface, stage: .viewport, reason: "app-foreground"),
            snapshot: snapshot(columns: 80, authority: Self.peer)
        )
        XCTAssertEqual(commands(started), [
            RenderCommands.renderedPaneMetadata(target: WindowId(1)),
            RenderCommands.viewport(target: WindowId(1)),
        ])
    }

    func test_ownerRefreshKeepsItsTwoStepSequence() {
        var ledger = paintedLedger(columns: 80, pipelines: true)
        let started = ledger.reduce(
            .refreshRequested(surface, stage: .viewport, reason: "window-switch"),
            snapshot: snapshot(columns: 80, authority: .mine(generation: 1))
        )
        XCTAssertEqual(commands(started), [RenderCommands.renderedPaneMetadata(target: WindowId(1))])
    }

    func test_defaultConfigurationNeverPipelines() {
        XCTAssertFalse(TmuxRenderLedger.Configuration().pipelinesVisibleCapture)
        var ledger = paintedLedger(columns: 80)
        let started = ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 5),
            snapshot: snapshot(columns: 80, authority: Self.peer)
        )
        XCTAssertEqual(commands(started), [RenderCommands.renderedPaneMetadata(target: WindowId(1))])
    }

    /// The claim's repaint is ordered behind its own fence on purpose; it
    /// must not wait for that fence's reply before going out.
    func test_correlatedTakeBackRefreshQueuesBehindThePlatformsFence() {
        var pipelined = paintedLedger(columns: 80, pipelines: true)
        _ = pipelined.enqueuePlatformCommand("select-window")
        let behindFence = pipelined.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 5),
            snapshot: snapshot(columns: 80, authority: Self.peer)
        )
        XCTAssertEqual(commands(behindFence).count, 2, "\(behindFence)")

        var legacy = paintedLedger(columns: 80)
        _ = legacy.enqueuePlatformCommand("select-window")
        let waiting = legacy.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 5),
            snapshot: snapshot(columns: 80, authority: Self.peer)
        )
        XCTAssertEqual(commands(waiting), [])
        XCTAssertTrue(waiting.contains { effect in
            if case .armTimer = effect { return true }
            return false
        })
    }

    /// A size change between the pipelined pair and the surface state
    /// re-runs the refresh: it must send a new capture with the new
    /// metadata, not wait for the first one again.
    /// Both halves of a pipelined pair fail together (a vanished target),
    /// but that is one failed refresh: it costs one retry, and with a
    /// single retry allowed the take-back is retried rather than given up.
    func test_aFailedPipelinedPairChargesTheRetryBudgetOnce() throws {
        var ledger = paintedLedger(columns: 80, pipelines: true, viewportRetries: 1)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        let pair = [RenderCommands.renderedPaneMetadata(target: WindowId(1)), RenderCommands.viewport(target: WindowId(1))]
        XCTAssertEqual(commands(ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 4),
            snapshot: peerState
        )), pair)

        let failed = reply(&ledger, snapshot: peerState, lines: ["no such pane"], success: false)
            + reply(&ledger, snapshot: peerState, lines: ["no such pane"], success: false)
        XCTAssertFalse(failed.contains { effect in
            if case .refreshFailed = effect { return true }
            return false
        }, "one failed refresh must not exhaust a one-retry budget: \(failed)")
        let retries = failed.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }
        XCTAssertEqual(retries.count, 1, "\(failed)")
        XCTAssertEqual(failed.filter { effect in
            if case .diagnostic(let text) = effect { return text.contains("refresh-retry") }
            return false
        }.count, 1)

        XCTAssertEqual(commands(ledger.reduce(.timerFired(token: try XCTUnwrap(retries.first)), snapshot: peerState)), pair)
    }

    /// A reply to an aborted refresh is not painted, even a successful one.
    func test_theSurvivingHalfOfAnAbortedPairIsNotPainted() throws {
        var ledger = paintedLedger(columns: 80, pipelines: true)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        _ = ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 4),
            snapshot: peerState
        )
        _ = reply(&ledger, snapshot: peerState, lines: ["garbled"], success: false)
        let capture = reply(&ledger, snapshot: peerState, lines: ["visible rows"])
        XCTAssertNil(resolveRequest(capture), "\(capture)")
        XCTAssertEqual(commands(capture), [])
    }

    /// A peer relayout that reaches a refresh waiting on its retry turns
    /// it into a rebuild, and the retry is that rebuild: never the in-place
    /// scrub first asked for, against a grid that has since changed.
    func test_aRetryArmedBeforeAPeerRelayoutRebuilds() throws {
        var ledger = paintedLedger(columns: 80, pipelines: true)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        _ = ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 4),
            snapshot: peerState
        )
        let failed = reply(&ledger, snapshot: peerState, lines: ["no such pane"], success: false)
        let retry = try XCTUnwrap(failed.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.first, "\(failed)")
        _ = reply(&ledger, snapshot: peerState, lines: ["visible rows"])
        XCTAssertEqual(commands(relayout(&ledger, columns: 70, authority: Self.peer)), [])

        let peer70 = snapshot(columns: 70, authority: Self.peer)
        XCTAssertEqual(commands(ledger.reduce(.timerFired(token: retry), snapshot: peer70)), [
            RenderCommands.renderedPaneMetadata(target: WindowId(1)),
            RenderCommands.viewport(target: WindowId(1)),
        ])
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewport, "a rebuild, not an in-place scrub")
    }

    func test_sizeResyncOfAPipelinedRefreshSendsANewPair() throws {
        var ledger = paintedLedger(columns: 80, pipelines: true)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        _ = ledger.reduce(
            .correlatedRefreshRequested(surface, stage: .viewportOnly, reason: "authority-claim", correlation: 5),
            snapshot: peerState
        )
        _ = reply(&ledger, snapshot: peerState, lines: [metadata(pane: 1)])
        let waiting = reply(&ledger, snapshot: peerState, lines: ["visible"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        _ = ledger.reduce(.clientSize(columns: 81, rows: 24), snapshot: peerState)
        let resynced = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: peerState
        )
        let sent = commands(resynced)
        XCTAssertEqual(Array(sent.suffix(2)), [
            RenderCommands.renderedPaneMetadata(target: WindowId(1)),
            RenderCommands.viewport(target: WindowId(1)),
        ], "\(resynced)")
    }

    /// A pipelined refresh whose size resync runs after the peer let go is no
    /// longer pipelined: its capture must follow the new metadata reply, not
    /// wait for a pair that was never sent.
    func test_sizeResyncAfterThePeerLeftCapturesBehindItsMetadata() throws {
        var ledger = paintedLedger(columns: 80, pipelines: true)
        let peerState = snapshot(columns: 80, authority: Self.peer)
        let pair = ledger.reduce(
            .refreshRequested(surface, stage: .viewportOnly, reason: "manual"),
            snapshot: peerState
        )
        XCTAssertEqual(commands(pair).count, 2, "\(pair)")
        _ = reply(&ledger, snapshot: peerState, lines: [metadata(pane: 1)])
        let waiting = reply(&ledger, snapshot: peerState, lines: ["visible"])
        let request = try XCTUnwrap(resolveRequest(waiting))
        let mine = snapshot(columns: 80, authority: .mine(generation: 4))
        let advertised = commands(ledger.reduce(.clientSize(columns: 81, rows: 24), snapshot: mine))
        let resynced = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 24),
            snapshot: mine
        )
        XCTAssertEqual(commands(resynced), [RenderCommands.renderedPaneMetadata(target: WindowId(1))], "\(resynced)")
        for _ in advertised {
            _ = reply(&ledger, snapshot: mine, lines: [])
        }
        let capture = reply(&ledger, snapshot: mine, lines: [metadata(pane: 1)])
        XCTAssertEqual(commands(capture).last, RenderCommands.viewport(target: WindowId(1)), "\(capture)")
    }

    func test_transportBoundaryForgetsYieldDebt() throws {
        var ledger = paintedLedger(columns: 80)
        _ = relayout(&ledger, columns: 70, authority: Self.peer)
        let state = snapshot(columns: 70, authority: Self.peer)
        _ = ledger.reduce(.transportLost, snapshot: state)
        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        // The attach's own deep repaint pays everything; settlement adds none.
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let deepCaptured = reply(&ledger, snapshot: state, lines: ["deep"])
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
        let mine = snapshot(columns: 70, authority: .mine(generation: 2))
        XCTAssertEqual(commands(ledger.noteAuthority(snapshot: mine)), [])
        // Nor is a later in-place refresh rebuilt for a relayout the new
        // connection's first fill already covered.
        let request = try XCTUnwrap(resolveRequest(deepCaptured), "\(deepCaptured)")
        _ = ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: 70, rows: 24),
            snapshot: mine
        )
        XCTAssertNil(ledger.pendingStage(for: surface))
        XCTAssertEqual(commands(ledger.noteAuthority(snapshot: mine)), [])
        _ = ledger.reduce(.refreshRequested(surface, stage: .viewportOnly, reason: "manual"), snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewportOnly)
    }

    // MARK: - Grid panes

    /// A relayout deep-rebuilds every pane of a grid. A grid pane that
    /// skipped one while yielded is rebuilt at visible rows instead, so that
    /// rebuild must deepen afterwards too, or the pane is left without its
    /// history for good: an ordinary grid-pane refresh never deepens.
    func test_gridPaneRebuiltForARelayoutMissedWhileYieldedDeepensAfterwards() throws {
        var ledger = paintedGridLedger()
        for first in [30, 40] {
            let effects = relayoutGrid(&ledger, firstWidth: first, authority: Self.peer)
            XCTAssertEqual(commands(effects), [], "a peer's relayout must not capture")
        }
        let mine = gridSnapshot(firstWidth: 40, authority: .mine(generation: 4))
        _ = ledger.noteAuthority(snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport)
        XCTAssertEqual(ledger.pendingStage(for: paneTwo), .viewport)

        let completed = try finishGridCapture(&ledger, surfaceID: paneOne, pane: 1, snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .deep, "\(completed)")
        XCTAssertEqual(commands(completed).last, RenderCommands.renderedPaneMetadata(target: PaneId(1)))
    }

    /// The take-back's own repaint pays the debt while the peer still holds
    /// the grid; its deepening waits for the release like a single surface's.
    func test_gridPaneDeepeningAfterATakeBackWaitsForTheRelease() throws {
        var ledger = paintedGridLedger()
        _ = relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)
        let peerState = gridSnapshot(firstWidth: 30, authority: Self.peer)
        _ = ledger.reduce(
            .correlatedRefreshRequested(paneOne, stage: .viewportOnly, reason: "authority-claim", correlation: 7),
            snapshot: peerState
        )
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport)
        let completed = try finishGridCapture(&ledger, surfaceID: paneOne, pane: 1, snapshot: peerState)
        XCTAssertNil(ledger.pendingStage(for: paneOne), "no deepening while the peer holds: \(completed)")

        let released = ledger.noteAuthority(snapshot: gridSnapshot(firstWidth: 30, authority: .mine(generation: 7)))
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .deep, "\(released)")
        XCTAssertEqual(ledger.pendingReason(for: paneOne), "authority-released-deep")
        XCTAssertEqual(ledger.pendingStage(for: paneTwo), .viewport, "the other pane is rebuilt too")
    }

    /// A refresh that replaces an unfinished payment inherits the debt: the
    /// relayout it was rebuilding for is still unpainted.
    func test_aRefreshReplacingAnUnfinishedRebuildStillRebuildsAndDeepens() throws {
        var ledger = paintedGridLedger()
        _ = relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)
        let mine = gridSnapshot(firstWidth: 30, authority: .mine(generation: 4))
        _ = ledger.reduce(.refreshRequested(paneOne, stage: .viewportOnly, reason: "manual"), snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport)
        let replacement = ledger.reduce(
            .refreshRequested(paneOne, stage: .viewportOnly, reason: "manual-again"),
            snapshot: mine
        )
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport, "never an in-place scrub")

        // The replaced refresh's metadata is answered and dropped; the
        // replacement then leaves its queue wait.
        _ = reply(&ledger, snapshot: mine, lines: [metadata(pane: 1)])
        let waitToken = try XCTUnwrap(replacement.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.last, "\(replacement)")
        XCTAssertEqual(
            commands(ledger.reduce(.timerFired(token: waitToken), snapshot: mine)),
            [RenderCommands.renderedPaneMetadata(target: PaneId(1))]
        )
        let completed = try finishGridCapture(&ledger, surfaceID: paneOne, pane: 1, snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .deep, "\(completed)")
    }

    /// A grid pane whose answered refresh is re-asked after a peer relayout
    /// pays that relayout with the re-ask, so the re-ask deepens too.
    func test_gridPaneReaskedAfterAPeerRelayoutDeepensOnceThePeerIsGone() throws {
        var ledger = paintedGridLedger()
        let peerState = gridSnapshot(firstWidth: 40, authority: Self.peer)
        _ = ledger.reduce(
            .correlatedRefreshRequested(paneOne, stage: .viewportOnly, reason: "authority-claim", correlation: 9),
            snapshot: peerState
        )
        _ = reply(&ledger, snapshot: peerState, lines: [metadata(pane: 1)])
        let reasked = relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)
        XCTAssertEqual(ledger.pendingReason(for: paneOne), "layout-change-yielded", "\(reasked)")
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport)

        // The answered refresh's capture is stale; the re-ask leaves its wait.
        let peer30 = gridSnapshot(firstWidth: 30, authority: Self.peer)
        _ = reply(&ledger, snapshot: peer30, lines: ["stale rows"])
        let waitToken = try XCTUnwrap(reasked.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.last, "\(reasked)")
        let mine = gridSnapshot(firstWidth: 30, authority: .mine(generation: 9))
        _ = ledger.reduce(.timerFired(token: waitToken), snapshot: mine)
        let completed = try finishGridCapture(&ledger, surfaceID: paneOne, pane: 1, snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .deep, "\(completed)")
    }

    /// An unanswered grid-pane refresh already runs against the peer's new
    /// geometry; it becomes the rebuild, and deepens afterwards.
    func test_gridPaneRefreshUnansweredAtAPeerRelayoutDeepensAfterwards() throws {
        var ledger = paintedGridLedger()
        let peerState = gridSnapshot(firstWidth: 40, authority: Self.peer)
        _ = ledger.reduce(.refreshRequested(paneOne, stage: .viewportOnly, reason: "manual"), snapshot: peerState)
        XCTAssertEqual(commands(relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)), [])
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport)
        let mine = gridSnapshot(firstWidth: 30, authority: .mine(generation: 4))
        let completed = try finishGridCapture(&ledger, surfaceID: paneOne, pane: 1, snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .deep, "\(completed)")
    }

    /// A rebuild restarted by its own metadata still pays the relayout.
    func test_aRestartedGridRebuildStillDeepens() throws {
        var ledger = paintedGridLedger()
        _ = relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)
        let mine = gridSnapshot(firstWidth: 30, authority: .mine(generation: 4))
        _ = ledger.reduce(.refreshRequested(paneOne, stage: .viewportOnly, reason: "manual"), snapshot: mine)
        // The fixed pane surface is answered for another pane: restart.
        let restarted = reply(&ledger, snapshot: mine, lines: [metadata(pane: 2)])
        XCTAssertEqual(commands(restarted), [RenderCommands.renderedPaneMetadata(target: PaneId(1))], "\(restarted)")
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport)
        let completed = try finishGridCapture(&ledger, surfaceID: paneOne, pane: 1, snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .deep, "\(completed)")
    }

    /// An ordinary visible refresh of a grid pane stays at visible rows.
    func test_ordinaryGridPaneRefreshDoesNotDeepen() throws {
        var ledger = paintedGridLedger()
        let state = gridSnapshot(firstWidth: 40, authority: .mine(generation: 2))
        _ = ledger.reduce(.refreshRequested(paneOne, stage: .viewport, reason: "manual"), snapshot: state)
        let completed = try finishGridCapture(&ledger, surfaceID: paneOne, pane: 1, snapshot: state)
        XCTAssertNil(ledger.pendingStage(for: paneOne), "\(completed)")
        XCTAssertEqual(commands(completed), [])
    }

    // MARK: - A rebuild is never dropped into an in-place scrub

    /// A relayout no peer holds asks for a deep rebuild under a fresh owner.
    /// A same-identity refresh that replaces it before it painted (the
    /// foreground refresh of a take-back that resized the window) must still
    /// rebuild: the surface holds rows wrapped for the old grid.
    func test_aForegroundRefreshReplacingAnOwnerRelayoutRebuildStillRebuildsAndDeepens() throws {
        var ledger = paintedLedger(columns: 80)
        let prior = try XCTUnwrap(ledger.owner(for: surface))
        let state = snapshot(columns: 70, authority: .unknown)
        XCTAssertEqual(
            commands(relayout(&ledger, columns: 70, authority: .unknown)),
            [RenderCommands.renderedPaneMetadata(target: WindowId(1))]
        )
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)

        let foreground = ledger.reduce(.appForeground, snapshot: state)
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewport, "never an in-place scrub")

        // The replaced rebuild's metadata answers and is dropped; the
        // foreground refresh then leaves its queue wait.
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let waitToken = try XCTUnwrap(foreground.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.last, "\(foreground)")
        XCTAssertEqual(
            commands(ledger.reduce(.timerFired(token: waitToken), snapshot: state)),
            [RenderCommands.renderedPaneMetadata(target: WindowId(1))]
        )
        XCTAssertEqual(
            commands(reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])),
            [RenderCommands.viewport(target: WindowId(1))]
        )
        let visible = try finishCapture(&ledger, snapshot: state, columns: 70)
        XCTAssertEqual(feedSources(visible), [.viewportRepaint])
        XCTAssertNotEqual(ledger.owner(for: surface)?.epoch, prior.epoch)
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep, "then the history")
    }

    /// The grid form: a relayout deep-rebuilds every pane, so a pane whose
    /// rebuild a visible refresh replaced must be deepened afterwards (an
    /// ordinary grid-pane refresh never deepens).
    func test_aGridRelayoutRebuildReplacedAtVisibleRowsStillDeepensEachPane() {
        var ledger = paintedGridLedger()
        let state = gridSnapshot(firstWidth: 30, authority: .unknown)
        var wire = GridWire()
        wire.absorb(relayoutGrid(&ledger, firstWidth: 30, authority: .unknown))
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .deep)
        XCTAssertEqual(ledger.pendingStage(for: paneTwo), .deep)

        wire.absorb(ledger.reduce(.appForeground, snapshot: state))
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport)
        XCTAssertEqual(ledger.pendingStage(for: paneTwo), .viewport)
        drain(&ledger, &wire, snapshot: state, history: 50)
        XCTAssertEqual(
            Set(wire.deepCaptures),
            [RenderCommands.deepPrimary(target: PaneId(1), depth: 2_000),
             RenderCommands.deepPrimary(target: PaneId(2), depth: 2_000)],
            "\(wire.sent)"
        )
    }

    /// The app going inactive (a Control Center pull is enough) drops the
    /// refresh paying a relayout. The debt survives it: nothing is captured
    /// while inactive, and the same-identity foreground refresh rebuilds and
    /// deepens instead of scrubbing in place.
    func test_aRebuildDroppedByTheAppGoingInactiveIsPaidByTheForeground() throws {
        var ledger = paintedLedger(columns: 80)
        _ = relayout(&ledger, columns: 70, authority: Self.peer)
        let mine = snapshot(columns: 70, authority: .mine(generation: 4))
        _ = ledger.noteAuthority(snapshot: mine)
        XCTAssertEqual(ledger.pendingReason(for: surface), "authority-released")

        let background = ledger.reduce(.appBackground, snapshot: mine)
        XCTAssertEqual(commands(background), [], "nothing is captured while inactive")
        XCTAssertNil(ledger.pendingStage(for: surface))
        XCTAssertEqual(commands(ledger.noteAuthority(snapshot: mine)), [], "not even on a release")

        let foreground = ledger.reduce(.appForeground, snapshot: mine)
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewport, "a rebuild, never an in-place scrub")
        // The dropped refresh's metadata still answers first.
        _ = reply(&ledger, snapshot: mine, lines: [metadata(pane: 1)])
        let waitToken = try XCTUnwrap(foreground.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.last, "\(foreground)")
        _ = ledger.reduce(.timerFired(token: waitToken), snapshot: mine)
        _ = reply(&ledger, snapshot: mine, lines: [metadata(pane: 1)])
        let visible = try finishCapture(&ledger, snapshot: mine, columns: 70)
        XCTAssertEqual(feedSources(visible), [.viewportRepaint])
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep, "then the history")
    }

    /// An owner's relayout rebuild (a fresh owner, nothing painted yet)
    /// dropped by inactivity is rebuilt by the foreground refresh too.
    func test_anOwnerRelayoutRebuildDroppedByTheAppGoingInactiveIsRebuiltOnForeground() throws {
        var ledger = paintedLedger(columns: 80)
        let prior = try XCTUnwrap(ledger.owner(for: surface))
        let state = snapshot(columns: 70, authority: .unknown)
        _ = relayout(&ledger, columns: 70, authority: .unknown)
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
        XCTAssertEqual(commands(ledger.reduce(.appBackground, snapshot: state)), [])
        XCTAssertNil(ledger.pendingStage(for: surface))

        let foreground = ledger.reduce(.appForeground, snapshot: state)
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewport, "a rebuild, never an in-place scrub")
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let waitToken = try XCTUnwrap(foreground.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.last, "\(foreground)")
        _ = ledger.reduce(.timerFired(token: waitToken), snapshot: state)
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let visible = try finishCapture(&ledger, snapshot: state, columns: 70)
        XCTAssertEqual(feedSources(visible), [.viewportRepaint])
        XCTAssertNotEqual(ledger.owner(for: surface)?.epoch, prior.epoch)
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
    }

    /// A rebuild's deepening, asked for once its visible rows painted and
    /// dropped by inactivity before it ran, runs after the foreground
    /// refresh: those rows were already rebuilt, so that refresh stays in
    /// place, but the history is still owed.
    func test_aDeepeningDroppedByTheAppGoingInactiveRunsAfterTheForegroundRefresh() throws {
        var ledger = paintedLedger(columns: 80)
        let state = snapshot(columns: 80, authority: .mine(generation: 2))
        _ = ledger.reduce(.refreshRequested(surface, stage: .viewport, reason: "window-switch"), snapshot: state)
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        _ = try finishCapture(&ledger, snapshot: state, columns: 80)
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep)
        XCTAssertEqual(ledger.pendingReason(for: surface), "window-switch-deep")

        XCTAssertEqual(commands(ledger.reduce(.appBackground, snapshot: state)), [])
        XCTAssertNil(ledger.pendingStage(for: surface))
        let foreground = ledger.reduce(.appForeground, snapshot: state)
        XCTAssertEqual(ledger.pendingStage(for: surface), .viewportOnly)
        // The dropped deepening's metadata answers first, then the
        // foreground refresh leaves its wait and paints in place.
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let waitToken = try XCTUnwrap(foreground.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, _) = effect else { return nil }
            return token
        }.last, "\(foreground)")
        _ = ledger.reduce(.timerFired(token: waitToken), snapshot: state)
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let visible = try finishCapture(&ledger, snapshot: state, columns: 80)
        XCTAssertEqual(feedSources(visible), [.viewportRefresh])
        XCTAssertEqual(ledger.pendingStage(for: surface), .deep, "the dropped deepening runs: \(visible)")
    }

    /// The grid form, where only the debt can deepen the pane.
    func test_aGridRebuildDroppedByTheAppGoingInactiveStillDeepensOnForeground() {
        var ledger = paintedGridLedger()
        _ = relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)
        let mine = gridSnapshot(firstWidth: 30, authority: .mine(generation: 4))
        var wire = GridWire()
        wire.absorb(ledger.noteAuthority(snapshot: mine))
        XCTAssertEqual(ledger.pendingStage(for: paneOne), .viewport)
        wire.absorb(ledger.reduce(.appBackground, snapshot: mine))
        XCTAssertNil(ledger.pendingStage(for: paneOne))
        wire.absorb(ledger.reduce(.appForeground, snapshot: mine))
        drain(&ledger, &wire, snapshot: mine, history: 50)
        XCTAssertTrue(
            wire.deepCaptures.contains(RenderCommands.deepPrimary(target: PaneId(1), depth: 2_000)),
            "\(wire.sent)"
        )
        XCTAssertTrue(
            wire.deepCaptures.contains(RenderCommands.deepPrimary(target: PaneId(2), depth: 2_000)),
            "\(wire.sent)"
        )
    }

    /// A grid pane's rebuild paying a relayout debt overflows its
    /// post-capture output and resyncs. The new cut is still that rebuild,
    /// so the pane deepens afterwards, as after a restart or a retry.
    func test_aPostCaptureOutputResyncOfAGridRebuildStillDeepens() throws {
        var ledger = paintedGridLedger(configuration: .init(maximumForegroundOutputBytes: 8))
        _ = relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)
        let mine = gridSnapshot(firstWidth: 30, authority: .mine(generation: 4))
        var wire = GridWire()
        wire.absorb(ledger.noteAuthority(snapshot: mine))
        XCTAssertEqual(wire.outstanding, [RenderCommands.renderedPaneMetadata(target: PaneId(1))])

        wire.outstanding.removeFirst()
        wire.absorb(reply(&ledger, snapshot: mine, lines: [metadata(pane: 1)]))
        XCTAssertEqual(wire.outstanding, [RenderCommands.viewport(target: PaneId(1))])
        wire.outstanding.removeFirst()
        let captured = reply(&ledger, snapshot: mine, lines: ["pane 1 rows"])
        let request = try XCTUnwrap(resolveRequest(captured, surfaceID: paneOne), "\(captured)")
        // More output than the cut may retain arrives before the platform
        // answers its surface state.
        wire.absorb(ledger.reduce(
            .message(.output(paneId: PaneId(1), data: Array(repeating: 0x61, count: 16))),
            snapshot: mine
        ))
        let resync = ledger.reduce(
            .surfaceState(paneOne, request: request, altScreen: false, mouseMode: .off, columns: 30, rows: 24),
            snapshot: mine
        )
        XCTAssertTrue(resync.contains(.diagnostic("render-ledger post-capture-output-resync surface=\(paneOne)")), "\(resync)")
        wire.absorb(resync)
        drain(&ledger, &wire, snapshot: mine, history: 50)
        XCTAssertTrue(
            wire.deepCaptures.contains(RenderCommands.deepPrimary(target: PaneId(1), depth: 2_000)),
            "\(wire.sent)"
        )
    }

    // MARK: - Grid panes painted deep

    /// The review's path (a): a split window painted deep, a peer relayout,
    /// then this device's take-back. The claim repaints both panes at
    /// visible rows under fresh owners (the platform clears their
    /// scrollback), so both must be deepened again once the claim settles:
    /// the control is a single surface, which always was.
    func test_gridTakeBackAfterAPeerRelayoutRecapturesEachPanesHistory() throws {
        var ledger = TmuxRenderLedger()
        var wire = GridWire()
        paintGridDeep(&ledger, &wire, history: 30)
        XCTAssertEqual(scrollUp(&ledger, paneOne, gridSnapshot(firstWidth: 40, authority: .unknown)), [],
                       "precondition: the first fill holds the whole history")

        _ = relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)
        let peerState = gridSnapshot(firstWidth: 30, authority: Self.peer)
        wire.reset()
        for (surfaceID, correlation) in [(paneOne, UInt64(7)), (paneTwo, 8)] {
            wire.absorb(ledger.reduce(
                .correlatedRefreshRequested(surfaceID, stage: .viewportOnly, reason: "authority-claim", correlation: correlation),
                snapshot: peerState
            ))
        }
        drain(&ledger, &wire, snapshot: peerState, history: 30)
        XCTAssertEqual(wire.deepCaptures, [], "no history capture while the peer holds the grid")
        XCTAssertEqual(wire.bound, [paneOne, paneTwo], "both panes rebuilt under fresh owners")

        let mine = gridSnapshot(firstWidth: 30, authority: .mine(generation: 7))
        wire.reset()
        wire.absorb(ledger.noteAuthority(snapshot: mine))
        drain(&ledger, &wire, snapshot: mine, history: 30)
        XCTAssertEqual(wire.deepCaptures, [
            RenderCommands.deepPrimary(target: PaneId(1), depth: 2_000),
            RenderCommands.deepPrimary(target: PaneId(2), depth: 2_000),
        ])
        XCTAssertEqual(wire.settledHistory, [paneOne, paneTwo])
        XCTAssertNil(ledger.pendingStage(for: paneOne))
        XCTAssertNil(ledger.pendingStage(for: paneTwo))
    }

    /// The review's path (b): no claim at all. The peer's stamp goes away
    /// and the next wire event, under a snapshot that no longer names it,
    /// pays the relayout debt: visible rebuild, then each pane's history.
    func test_gridPeerLeavingAfterARelayoutRecapturesEachPanesHistory() throws {
        var ledger = TmuxRenderLedger()
        var wire = GridWire()
        paintGridDeep(&ledger, &wire, history: 30)
        _ = relayoutGrid(&ledger, firstWidth: 30, authority: Self.peer)

        let prior = [ledger.owner(for: paneOne), ledger.owner(for: paneTwo)]
        let unveiled = gridSnapshot(firstWidth: 30, authority: .unknown)
        wire.reset()
        wire.absorb(ledger.reduce(
            .message(.windowRenamed(windowId: WindowId(1), name: "grid")),
            snapshot: unveiled
        ))
        drain(&ledger, &wire, snapshot: unveiled, history: 30)
        XCTAssertEqual(Set(wire.bound), [paneOne, paneTwo])
        XCTAssertNotEqual(ledger.owner(for: paneOne), prior[0], "rebuilt under a fresh owner")
        XCTAssertNotEqual(ledger.owner(for: paneTwo), prior[1], "rebuilt under a fresh owner")
        XCTAssertEqual(wire.deepCaptures, [
            RenderCommands.deepPrimary(target: PaneId(1), depth: 2_000),
            RenderCommands.deepPrimary(target: PaneId(2), depth: 2_000),
        ])
        XCTAssertEqual(wire.settledHistory, [paneOne, paneTwo])
    }

    /// A pane rebound at visible rows has lost its scrollback on the
    /// platform, so the credit of its earlier deep capture must not answer a
    /// reader's scroll-up with "nothing older": the reader gets a capture.
    func test_gridPaneReboundAtVisibleRowsCanDeepenAgain() throws {
        var ledger = TmuxRenderLedger()
        var wire = GridWire()
        paintGridDeep(&ledger, &wire, history: 30)
        let state = gridSnapshot(firstWidth: 40, authority: .mine(generation: 2))
        XCTAssertEqual(scrollUp(&ledger, paneOne, state), [], "credited with the whole history")

        wire.reset()
        wire.absorb(ledger.reduce(.refreshRequested(paneOne, stage: .viewport, reason: "manual"), snapshot: state))
        drain(&ledger, &wire, snapshot: state, history: 30)
        XCTAssertEqual(wire.bound, [paneOne])
        XCTAssertEqual(wire.deepCaptures, [], "an ordinary grid refresh stays at visible rows")

        XCTAssertEqual(scrollUp(&ledger, paneOne, state), [RenderCommands.renderedPaneMetadata(target: PaneId(1))])
        wire.reset()
        drain(&ledger, &wire, snapshot: state, history: 30, alreadySent: [RenderCommands.renderedPaneMetadata(target: PaneId(1))])
        XCTAssertEqual(wire.deepCaptures, [RenderCommands.deepPrimary(target: PaneId(1), depth: 10_000)])
        XCTAssertEqual(scrollUp(&ledger, paneOne, state), [], "and is credited again")
    }

    /// An in-place repaint keeps its owner and the platform keeps its
    /// scrollback, so the credit stands.
    func test_gridPaneRepaintedInPlaceKeepsItsCredit() throws {
        var ledger = TmuxRenderLedger()
        var wire = GridWire()
        paintGridDeep(&ledger, &wire, history: 30)
        let state = gridSnapshot(firstWidth: 40, authority: .mine(generation: 2))
        wire.reset()
        wire.absorb(ledger.reduce(.refreshRequested(paneOne, stage: .viewportOnly, reason: "manual"), snapshot: state))
        drain(&ledger, &wire, snapshot: state, history: 30)
        XCTAssertEqual(wire.bound, [])
        XCTAssertEqual(scrollUp(&ledger, paneOne, state), [])
    }

    // MARK: - Fixture

    private let paneOne = SurfaceId("pane-1")
    private let paneTwo = SurfaceId("pane-2")

    private func gridSnapshot(firstWidth: Int, authority: TmuxGridAuthoritySnapshot) -> TmuxSnapshot {
        let first = CellRect(width: firstWidth, height: 24, x: 0, y: 0)
        let second = CellRect(width: 79 - firstWidth, height: 24, x: firstWidth + 1, y: 0)
        let layout = WindowLayout(root: .split(
            axis: .horizontal,
            rect: CellRect(width: 80, height: 24, x: 0, y: 0),
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
                layout: layout,
                visibleLayout: layout
            )],
            authority: authority
        )
    }

    /// Two mounted grid panes, each painted by a visible refresh that, as an
    /// ordinary grid-pane refresh, does not deepen.
    private func paintedGridLedger(
        configuration: TmuxRenderLedger.Configuration = .init()
    ) -> TmuxRenderLedger {
        var ledger = TmuxRenderLedger(configuration: configuration)
        let state = gridSnapshot(firstWidth: 40, authority: .unknown)
        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        _ = ledger.reduce(.surfacesDeclared([
            .init(surfaceID: paneOne, presentation: .grid, windowID: WindowId(1), paneID: PaneId(1)),
            .init(surfaceID: paneTwo, presentation: .grid, windowID: WindowId(1), paneID: PaneId(2)),
        ]), snapshot: state)
        for (surfaceID, pane) in [(paneOne, 1), (paneTwo, 2)] {
            _ = ledger.reduce(.refreshRequested(surfaceID, stage: .viewport, reason: "mount"), snapshot: state)
            _ = try? finishGridCapture(&ledger, surfaceID: surfaceID, pane: pane, snapshot: state)
            XCTAssertNotNil(ledger.owner(for: surfaceID))
            XCTAssertNil(ledger.pendingStage(for: surfaceID))
        }
        return ledger
    }

    private func relayoutGrid(
        _ ledger: inout TmuxRenderLedger,
        firstWidth: Int,
        authority: TmuxGridAuthoritySnapshot
    ) -> [RenderEffect] {
        let layout = "80x24,0,0{\(firstWidth)x24,0,0,1,\(79 - firstWidth)x24,\(firstWidth + 1),0,2}"
        return ledger.reduce(.message(.layoutChange(
            windowId: WindowId(1),
            layout: layout,
            visibleLayout: layout,
            rawFlags: "*"
        )), snapshot: gridSnapshot(firstWidth: firstWidth, authority: authority))
    }

    /// Answer a grid pane's pending visible refresh: its metadata, its
    /// capture, then its surface state.
    private func finishGridCapture(
        _ ledger: inout TmuxRenderLedger,
        surfaceID: SurfaceId,
        pane: Int,
        snapshot: TmuxSnapshot
    ) throws -> [RenderEffect] {
        _ = reply(&ledger, snapshot: snapshot, lines: [metadata(pane: pane)])
        let waiting = reply(&ledger, snapshot: snapshot, lines: ["pane \(pane) rows"])
        let request = try XCTUnwrap(resolveRequest(waiting, surfaceID: surfaceID), "\(waiting)")
        let width = snapshot.windows.first?.panes.first { $0.id == PaneId(pane) }?.contentRect?.width ?? 40
        return ledger.reduce(
            .surfaceState(surfaceID, request: request, altScreen: false, mouseMode: .off, columns: width, rows: 24),
            snapshot: snapshot
        )
    }

    /// A minimal tmux for grid tests: replies to the ledger's commands in
    /// FIFO order (metadata for a pane query, rows for a capture, an empty
    /// success otherwise), answers surface-state requests at the pane's
    /// width, and fires queue-wait timers once nothing is outstanding.
    private struct GridWire {
        var outstanding: [String] = []
        var timers: [UInt64] = []
        var sent: [String] = []
        var effects: [RenderEffect] = []

        mutating func reset() {
            sent.removeAll()
            effects.removeAll()
        }

        mutating func absorb(_ new: [RenderEffect]) {
            effects.append(contentsOf: new)
            for effect in new {
                switch effect {
                case .sendCommand(let command):
                    outstanding.append(command)
                    sent.append(command)
                case .armTimer(let token, _):
                    timers.append(token)
                case .cancelTimer(let token):
                    timers.removeAll { $0 == token }
                default:
                    break
                }
            }
        }

        var deepCaptures: [String] {
            sent.filter { $0.hasPrefix("capture-pane") && $0.contains(" -S ") }
        }

        var bound: [SurfaceId] {
            effects.compactMap { effect in
                guard case .bindSurface(let surfaceID, _) = effect else { return nil }
                return surfaceID
            }
        }

        var settledHistory: [SurfaceId] {
            effects.compactMap { effect in
                guard case .inlineHistorySettled(let surfaceID, _, _, _, _) = effect else { return nil }
                return surfaceID
            }
        }
    }

    private func drain(
        _ ledger: inout TmuxRenderLedger,
        _ wire: inout GridWire,
        snapshot: TmuxSnapshot,
        history: Int,
        alreadySent: [String] = []
    ) {
        wire.outstanding.append(contentsOf: alreadySent)
        wire.sent.append(contentsOf: alreadySent)
        for _ in 0..<64 {
            var produced: [RenderEffect]
            if !wire.outstanding.isEmpty {
                let command = wire.outstanding.removeFirst()
                var lines: [String] = []
                if command.hasPrefix("display-message -p -t %"),
                   let pane = Int(command.dropFirst("display-message -p -t %".count).prefix { $0.isNumber }) {
                    lines = [metadata(pane: pane, history: history)]
                } else if command.hasPrefix("capture-pane") {
                    lines = ["rows"]
                }
                produced = reply(&ledger, snapshot: snapshot, lines: lines)
            } else if !wire.timers.isEmpty {
                produced = ledger.reduce(.timerFired(token: wire.timers.removeFirst()), snapshot: snapshot)
            } else {
                return
            }
            wire.absorb(produced)
            for effect in produced {
                guard case .resolveSurfaceState(let surfaceID, let request) = effect else { continue }
                let pane = surfaceID == paneOne ? PaneId(1) : PaneId(2)
                let width = snapshot.windows.first?.panes.first { $0.id == pane }?.contentRect?.width ?? 40
                wire.absorb(ledger.reduce(
                    .surfaceState(surfaceID, request: request, altScreen: false, mouseMode: .off, columns: width, rows: 24),
                    snapshot: snapshot
                ))
            }
        }
        XCTFail("the ledger never went quiet: \(wire.outstanding) \(wire.timers)")
    }

    /// Both grid panes mounted and painted by a deep first fill.
    private func paintGridDeep(_ ledger: inout TmuxRenderLedger, _ wire: inout GridWire, history: Int) {
        let state = gridSnapshot(firstWidth: 40, authority: .unknown)
        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        _ = ledger.reduce(.surfacesDeclared([
            .init(surfaceID: paneOne, presentation: .grid, windowID: WindowId(1), paneID: PaneId(1)),
            .init(surfaceID: paneTwo, presentation: .grid, windowID: WindowId(1), paneID: PaneId(2)),
        ]), snapshot: state)
        for surfaceID in [paneOne, paneTwo] {
            wire.absorb(ledger.reduce(.refreshRequested(surfaceID, stage: .deep, reason: "mount"), snapshot: state))
            drain(&ledger, &wire, snapshot: state, history: history)
        }
        XCTAssertEqual(wire.deepCaptures.count, 2, "\(wire.sent)")
        XCTAssertNotNil(ledger.owner(for: paneOne))
        XCTAssertNotNil(ledger.owner(for: paneTwo))
    }

    /// A reader's scroll-up on a grid pane: the commands it costs, or none
    /// when the ledger answers from the pane's credit.
    private func scrollUp(
        _ ledger: inout TmuxRenderLedger,
        _ surfaceID: SurfaceId,
        _ snapshot: TmuxSnapshot
    ) -> [String] {
        commands(ledger.reduce(.scrollbackRequested(surfaceID, pointsY: 40, isInertial: false), snapshot: snapshot))
    }

    private func snapshot(columns: Int, authority: TmuxGridAuthoritySnapshot) -> TmuxSnapshot {
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
            authority: authority
        )
    }

    /// An attached inline ledger whose live surface holds a deep first fill.
    private func paintedLedger(columns: Int, pipelines: Bool = false, viewportRetries: Int = 8) -> TmuxRenderLedger {
        var ledger = TmuxRenderLedger(configuration: .init(
            maximumViewportRetryAttempts: viewportRetries,
            pipelinesVisibleCapture: pipelines
        ))
        let state = snapshot(columns: columns, authority: .unknown)
        _ = ledger.reduce(.surfacesDeclared([.init(surfaceID: surface, presentation: .single)]), snapshot: state)
        _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
        _ = reply(&ledger, snapshot: state, lines: [metadata(pane: 1)])
        let waiting = reply(&ledger, snapshot: state, lines: ["first fill"])
        if let request = resolveRequest(waiting) {
            _ = ledger.reduce(
                .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: columns, rows: 24),
                snapshot: state
            )
        }
        XCTAssertNotNil(ledger.owner(for: surface))
        XCTAssertNil(ledger.pendingStage(for: surface))
        return ledger
    }

    private func relayout(
        _ ledger: inout TmuxRenderLedger,
        columns: Int,
        authority: TmuxGridAuthoritySnapshot
    ) -> [RenderEffect] {
        ledger.reduce(.message(.layoutChange(
            windowId: WindowId(1),
            layout: "\(columns)x24,0,0,1",
            visibleLayout: "\(columns)x24,0,0,1",
            rawFlags: "*"
        )), snapshot: snapshot(columns: columns, authority: authority))
    }

    /// Answer the capture of a pending visible refresh, then its surface state.
    private func finishCapture(
        _ ledger: inout TmuxRenderLedger,
        snapshot: TmuxSnapshot,
        columns: Int
    ) throws -> [RenderEffect] {
        let waiting = reply(&ledger, snapshot: snapshot, lines: ["visible rows"])
        let request = try XCTUnwrap(resolveRequest(waiting), "\(waiting)")
        return ledger.reduce(
            .surfaceState(surface, request: request, altScreen: false, mouseMode: .off, columns: columns, rows: 24),
            snapshot: snapshot
        )
    }

    private func metadata(pane: Int, history: Int = 0) -> String {
        [
            "%\(pane)", "0", "0", "pane", "window", "host", "0",
            "\(history)", "0", "23", "1", "0", "0", "0", "1", "0", "0", "0", "0", "0", "0", "0",
        ].joined(separator: "\t")
    }

    private func reply(
        _ ledger: inout TmuxRenderLedger,
        snapshot: TmuxSnapshot,
        lines: [String],
        success: Bool = true
    ) -> [RenderEffect] {
        let frame = TmuxCommandGuard(time: 1, commandNumber: 1, flags: 1)
        return ledger.reduce(.correlation(.frameCompleted(.init(
            status: success ? .success : .error,
            begin: frame,
            end: frame,
            effectiveFlags: 1,
            guardMatches: true,
            lines: lines
        ))), snapshot: snapshot)
    }

    private func commands(_ effects: [RenderEffect]) -> [String] {
        effects.compactMap { effect in
            guard case .sendCommand(let command) = effect else { return nil }
            return command
        }
    }

    private func feedSources(_ effects: [RenderEffect]) -> [RenderFeedSource] {
        effects.compactMap { effect in
            guard case .feed(_, _, _, let source) = effect else { return nil }
            return source
        }
    }

    private func resolveRequest(_ effects: [RenderEffect], surfaceID: SurfaceId? = nil) -> UInt64? {
        for effect in effects {
            if case .resolveSurfaceState(let id, let request) = effect, id == (surfaceID ?? surface) { return request }
        }
        return nil
    }
}
