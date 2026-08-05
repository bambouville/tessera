import XCTest
@testable import TmuxControl

/// Continuity-takeover grid authority: stamp writes, subscription-driven
/// yield/reclaim transitions, the yielded size gate, and the stamp-less
/// layout fallback.
@MainActor
final class GridAuthorityTests: XCTestCase {
    private final class ByteSink {
        var bytes: [UInt8] = []

        func append(_ newBytes: [UInt8]) {
            bytes.append(contentsOf: newBytes)
        }

        func clear() {
            bytes.removeAll(keepingCapacity: true)
        }

        var string: String { String(decoding: bytes, as: UTF8.self) }
    }

    private static let selfID = "SELF-DEVICE-1234"
    private static let peerValue = "v1 PEER-DEVICE-9999 3 iPhone"
    private func selfValue(gen: Int = 1) -> String {
        "v1 \(Self.selfID) \(gen) iPad"
    }

    private func makeController(
        path: TmuxController.ControlPath = .sideChannel,
        policy: TmuxController.ClientSizePolicy = .resizeTmux,
        identity: TmuxController.GridAuthorityIdentity? =
            .init(id: "SELF-DEVICE-1234", displayName: "iPad"),
        localCols: Int = 92,
        localRows: Int = 38
    ) -> (controller: TmuxController, sent: ByteSink) {
        let sent = ByteSink()
        let controller = TmuxController(
            controlPath: path,
            clientSizePolicy: policy
        )
        controller.feedTerminal = { _ in }
        controller.sendBytes = { sent.append($0) }
        controller.gridAuthorityIdentity = identity
        controller.updateClientSize(cols: localCols, rows: localRows)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array(
            "%session-changed $0 dev\r\n%window-add @0\r\n".utf8
        ))
        sent.clear()
        return (controller, sent)
    }

    private func deliverStamp(_ controller: TmuxController, value: String) {
        controller.ingest(Array(
            "%subscription-changed tessera-authority $0 @0 0 %0 : \(value)\r\n".utf8
        ))
    }

    // MARK: - Token / value hygiene

    func test_sanitizedTokenReplacesUnsafeCharacters() {
        XCTAssertEqual(
            TmuxController.sanitizedAuthorityToken("Dev's iPad (2) `x`"),
            "Dev-s-iPad--2---x-"
        )
        XCTAssertEqual(TmuxController.sanitizedAuthorityToken(""), "-")
        XCTAssertEqual(
            TmuxController.sanitizedAuthorityToken("ABC-123_ok.v2"),
            "ABC-123_ok.v2"
        )
    }

    // MARK: - Yield on foreign stamp

    func test_foreignStampYields() {
        let (controller, _) = makeController()
        XCTAssertEqual(controller.gridAuthority, .unknown)
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertEqual(
            controller.gridAuthority,
            .peer(displayName: "iPhone")
        )
    }

    func test_ownStampEchoConfirmsMine() {
        let (controller, _) = makeController()
        deliverStamp(controller, value: selfValue())
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_duplicatePerPaneDeliveriesAreIdempotent() {
        let (controller, _) = makeController()
        deliverStamp(controller, value: Self.peerValue)
        deliverStamp(controller, value: Self.peerValue)
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertEqual(
            controller.gridAuthority,
            .peer(displayName: "iPhone")
        )
    }

    func test_garbledStampIsIgnored() {
        let (controller, _) = makeController()
        deliverStamp(controller, value: "v0 nonsense")
        XCTAssertEqual(controller.gridAuthority, .unknown)
    }

    // MARK: - Yielded size gate

    func test_yieldedSizeChangeDoesNotStealGrid() {
        let (controller, sent) = makeController()
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()
        controller.updateClientSize(cols: 47, rows: 20)
        XCTAssertFalse(
            sent.string.contains("refresh-client -C"),
            "yielded client must not replay size: \(sent.string)"
        )
        XCTAssertFalse(sent.string.contains("resize-window"))
        XCTAssertFalse(sent.string.contains(TmuxController.gridAuthorityOption))
    }

    // MARK: - Reclaim

    func test_reclaimCompletesAfterFenceAndGeometryNotStampEcho() {
        let (controller, sent) = makeController()
        deliverStamp(controller, value: Self.peerValue)
        // Size churn while yielded stays latched locally…
        controller.updateClientSize(cols: 47, rows: 20)
        sent.clear()
        controller.reclaimGridAuthority()
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        let wire = sent.string
        XCTAssertTrue(
            wire.contains("set-option \(TmuxController.gridAuthorityOption) 'v1 \(Self.selfID)"),
            "reclaim must write the stamp: \(wire)"
        )
        // …and the reclaim replays the latest latched size, not the
        // pre-yield one.
        XCTAssertTrue(wire.contains("refresh-client -C 47,20"), wire)
        // The stamp write precedes the size replay so peers veil before
        // the first foreign-sized frame.
        let stampIndex = wire.range(of: "set-option \(TmuxController.gridAuthorityOption)")!.lowerBound
        let sizeIndex = wire.range(of: "refresh-client -C")!.lowerBound
        XCTAssertLessThan(stampIndex, sizeIndex)

        // Our own stamp echo is advisory — it must NOT lift the veil,
        // because the stamp and tmux's sizing-client state can disagree.
        deliverStamp(controller, value: selfValue())
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(controller.gridAuthority.isPeer)

        // A layout event that still shows the peer's grid does not settle…
        let stale = "beef,105x31,0,0,0"
        controller.ingest(Array("%layout-change @0 \(stale) \(stale) *\r\n".utf8))
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)

        // …and even matching geometry cannot lift the veil before the
        // replay/fence commands have landed.
        let settled = "beef,47x20,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        XCTAssertTrue(controller.gridAuthority.isPeer)

        ackAllPending(controller)
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        // Re-observe the settled layout after installing the side-channel
        // delivery acknowledgement.
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        controller.completeGridAuthoritySideChannelRepaint(
            generation: try! XCTUnwrap(repaintGeneration)
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
    }

    private func ackAllPending(_ controller: TmuxController, frames: Int = 15) {
        for number in 500..<(500 + frames) {
            controller.ingest(Array(
                "%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8
            ))
        }
    }

    func test_inlineReclaimUsesSelectWindowFenceNotResizeWindow() {
        let (controller, sent) = makeController(path: .inline)
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()
        controller.reclaimGridAuthority()
        // The fence is ack-sequenced: select-window is only built (from the
        // then-fresh current window) after the server processed the size
        // replay — so it appears on the wire only once acks flow.
        XCTAssertFalse(sent.string.contains("select-window"), sent.string)
        ackAllPending(controller)
        let wire = sent.string
        // tmux-native latest-client transfer: no-op select of the current
        // window; the side-channel resize-window force must never leak
        // onto the inline path (it can snap back and churn repaints).
        XCTAssertTrue(wire.contains("select-window -t @0"), wire)
        XCTAssertFalse(wire.contains("resize-window"), wire)
        XCTAssertFalse(wire.contains("set-option -w -u"), wire)
    }

    func test_repeatedTakeBackGestureDoesNotQueueDuplicateClaim() {
        let (controller, sent) = makeController(path: .inline)
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()

        controller.reclaimGridAuthority()
        let firstWire = sent.string
        controller.reclaimGridAuthority()

        XCTAssertEqual(sent.string, firstWire)
        XCTAssertEqual(
            firstWire.components(separatedBy: "refresh-client -C").count - 1,
            1
        )
    }

    func test_timedOutPendingClaimCanStillReplayLateHydratedSize() {
        let (controller, sent) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        controller.reclaimGridAuthority()
        controller.expireGridAuthorityReclaimPresentationForTesting()
        sent.clear()

        controller.updateClientSize(cols: 47, rows: 20)

        XCTAssertTrue(sent.string.contains("refresh-client -C 47,20"), sent.string)
        XCTAssertTrue(
            sent.string.contains(TmuxController.gridAuthorityOption),
            "a late pending claim must remain an authorized fenced replay"
        )
    }

    func test_sizeChangeDuringPendingClaimRefencesAfterNewestReplay() {
        let (controller, sent) = makeController(path: .sideChannel)
        ackAllPending(controller)
        sent.clear()
        deliverStamp(controller, value: Self.peerValue)
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }

        controller.reclaimGridAuthority()
        controller.updateClientSize(cols: 47, rows: 20)

        let wire = sent.string
        XCTAssertEqual(
            wire.components(separatedBy: "show-options -wA -v -t @0 window-size").count - 1,
            2,
            wire
        )
        let latestReplay = try! XCTUnwrap(
            wire.range(of: "refresh-client -C 47,20", options: .backwards)
        )
        let latestPolicy = try! XCTUnwrap(
            wire.range(
                of: "show-options -wA -v -t @0 window-size",
                options: .backwards
            )
        )
        XCTAssertLessThan(latestReplay.lowerBound, latestPolicy.lowerBound)

        let settled = "beef,47x20,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(settled) \(settled) *\r\n".utf8
        ))
        var responseIndex = 0
        while responseIndex < sent.string.split(separator: "\n").count,
              repaintGeneration == nil,
              responseIndex < 100 {
            let commands = sent.string.split(separator: "\n").map(String.init)
            let body = commands[responseIndex].contains("window-size")
                ? "smallest\r\n"
                : ""
            controller.ingest(Array(
                ("%begin 0 \(820 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(820 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        controller.completeGridAuthoritySideChannelRepaint(
            generation: try! XCTUnwrap(repaintGeneration)
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_retriedSideChannelClaimIgnoresOlderFence() {
        let (controller, sent) = makeController(path: .sideChannel)
        ackAllPending(controller)
        let layout = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()

        controller.reclaimGridAuthority()
        // Model a retry after the first claim's UI timeout, before its command
        // replies arrive. Calling the shared primitive directly avoids making
        // this deterministic test sleep for the three-second presentation timer.
        controller.claimActiveViewport(reason: "test-retry")

        // Side-channel claim A queues stamp, refresh, resize, unset, policy,
        // fence. Its sixth response is stale after claim B replaced the
        // generation.
        for number in 800..<806 {
            controller.ingest(Array(
                "%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8
            ))
        }
        XCTAssertTrue(
            controller.gridAuthority.isPeer,
            "an old fence must not authorize its replacement claim"
        )

        for number in 806..<812 {
            controller.ingest(Array(
                "%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8
            ))
        }
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_inlineReclaimKeepsAuthorityVeilUntilRepaintCompletes() {
        let (controller, sent) = makeController(path: .inline)
        deliverStamp(controller, value: Self.peerValue)
        controller.updateClientSize(cols: 47, rows: 20)
        sent.clear()

        controller.reclaimGridAuthority()
        ackAllPending(controller)
        let settled = "beef,47x20,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(settled) \(settled) *\r\n".utf8
        ))

        XCTAssertTrue(
            controller.gridAuthority.isPeer,
            "inline authority must stay yielded until capture output reaches its sink"
        )
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(
            sent.string.contains("display-message -p -t @0"),
            "settled geometry must start an authoritative capture: \(sent.string)"
        )
    }

    func test_compactSplitReclaimWaitsOnlyForMountedActivePane() {
        let (controller, _) = makeController(
            path: .inline,
            localCols: 100,
            localRows: 30
        )
        let peerLayout = "beef,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
        controller.ingest(Array(
            "%layout-change @0 \(peerLayout) \(peerLayout) *\r\n".utf8
        ))
        controller.ingest(Array("%window-pane-changed @0 %0\r\n".utf8))
        controller.setGridAuthorityUsesCompactSinglePaneGrid(true)
        deliverStamp(controller, value: Self.peerValue)

        controller.reclaimGridAuthority()
        ackAllPending(controller)
        let settled = "cafe,100x30,0,0{50x30,0,0,0,49x30,51,0,1}"
        controller.ingest(Array(
            "%layout-change @0 \(settled) \(settled) *\r\n".utf8
        ))

        XCTAssertEqual(
            controller.gridAuthorityRepaintPaneTargetsForTesting,
            Set([PaneId(0)]),
            "compact iPhone mounts only the active pane; hidden remote panes cannot gate the veil"
        )
        XCTAssertTrue(controller.gridAuthority.isPeer)
    }

    func test_windowCommandsSuppressedWhileYielded() {
        let (controller, sent) = makeController()
        controller.ingest(Array("%window-pane-changed @0 %6\r\n".utf8))
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()
        controller.selectWindow(atPosition: 1)
        controller.newWindow()
        controller.nextWindow()
        controller.previousWindow()
        controller.killCurrentWindow()
        controller.renameWindow(WindowId(0), to: "peer must keep this name")
        controller.selectPane(PaneId(6))
        controller.sendInput([0x61])
        controller.sendInput([0x62], toPane: PaneId(6))
        controller.resyncRenderedWindowAfterGridCollapse(cols: 92, rows: 38)
        XCTAssertEqual(
            sent.string, "",
            "user mutations from a yielded client must not reach tmux: \(sent.string)"
        )

        // The gate remains closed while a reclaim is pending. Internal claim
        // fencing uses the raw control queue and does not need user mutation
        // APIs to become temporarily unsafe.
        controller.reclaimGridAuthority()
        sent.clear()
        controller.newWindow()
        controller.renameWindow(WindowId(0), to: "still blocked")
        controller.selectPane(PaneId(6))
        controller.sendInput([0x63], toPane: PaneId(6))
        XCTAssertEqual(sent.string, "")
    }

    func test_acknowledgedPaneInputFailsClosedWhileYielded() async {
        let (controller, sent) = makeController()
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()

        let bytesAccepted = await controller.sendInputAcknowledged(
            [0x61],
            toPane: PaneId(6)
        )
        let keyAccepted = await controller.sendKeyAcknowledged(
            .enter,
            toPane: PaneId(6)
        )

        XCTAssertFalse(bytesAccepted)
        XCTAssertFalse(keyAccepted)
        XCTAssertEqual(sent.string, "")
    }

    func test_sameGridReclaimSettlesWithoutRedundantSideChannelRepaint() {
        let (controller, _) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        let layout = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        var repaintRequests: [Bool] = []
        controller.onGridAuthoritySideChannelRepaintRequired = { changed, _ in
            repaintRequests.append(changed)
        }

        controller.reclaimGridAuthority()
        ackAllPending(controller)

        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertTrue(repaintRequests.isEmpty)
    }

    func test_manualRefreshRequestsRepaintEvenWhenGridAlreadyMatches() {
        let (controller, _) = makeController(path: .sideChannel)
        deliverStamp(controller, value: selfValue())
        let layout = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        var repaintRequests: [Bool] = []
        controller.onGridAuthoritySideChannelRepaintRequired = { changed, _ in
            repaintRequests.append(changed)
        }

        controller.claimActiveViewport(
            reason: "test-refresh",
            repaintEvenIfSame: true
        )
        ackAllPending(controller)

        XCTAssertEqual(repaintRequests, [false])
    }

    func test_autoReclaimToastWaitsForGeometryAndRepaint() {
        let (controller, sent) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        var events: [String] = []
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            events.append("repaint")
            repaintGeneration = generation
        }
        controller.onGridAuthorityAutoReclaimed = { name in
            events.append("toast:\(name ?? "nil")")
        }

        // Drain the fixture's `%window-add` details query so the next command
        // response belongs to the peer-count request below.
        ackAllPending(controller)
        sent.clear()
        controller.ingest(Array("%client-detached /dev/ttys-peer\r\n".utf8))
        XCTAssertTrue(
            sent.string.contains(
                "display-message -p '#{client_name}|#{client_pid}|#{client_created}'"
            ),
            sent.string
        )
        controller.ingest(Array(
            ("%begin 0 600 1\r\n"
                + "/dev/ttys-control|111|1700000001\r\n"
                + "%end 0 600 1\r\n").utf8
        ))
        let visibleOption = TmuxController.gridAuthorityVisibleClientOption(
            identityID: Self.selfID
        )
        XCTAssertTrue(sent.string.contains("show-options -qv -t $0 \(visibleOption)"), sent.string)
        controller.ingest(Array(
            ("%begin 0 601 1\r\n"
                + "/dev/ttys-visible|222|1700000002\r\n"
                + "%end 0 601 1\r\n").utf8
        ))
        XCTAssertTrue(sent.string.contains("list-clients -t $0"), sent.string)
        controller.ingest(Array(
            ("%begin 0 602 1\r\n"
                + "/dev/ttys-control|111|1700000001\r\n"
                + "/dev/ttys-visible|222|1700000002\r\n"
                + "%end 0 602 1\r\n").utf8
        ))
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(events.isEmpty, "auto-reclaim announced before settlement")
        ackAllPending(controller)

        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(settled) \(settled) *\r\n".utf8
        ))

        XCTAssertEqual(events, ["repaint"])
        XCTAssertTrue(controller.gridAuthority.isPeer)
        controller.completeGridAuthoritySideChannelRepaint(
            generation: try! XCTUnwrap(repaintGeneration)
        )
        XCTAssertEqual(events, ["repaint", "toast:iPhone"])
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_sideChannelAutoReclaimFailsClosedWhenPeerSurvivesLocalVisibleDetach() {
        let (controller, sent) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        ackAllPending(controller)
        sent.clear()

        controller.ingest(Array("%client-detached /dev/ttys-visible\r\n".utf8))
        controller.ingest(Array(
            "%begin 0 610 1\r\n/dev/ttys-control|111|1700000001\r\n%end 0 610 1\r\n".utf8
        ))
        controller.ingest(Array(
            "%begin 0 611 1\r\n/dev/ttys-visible|222|1700000002\r\n%end 0 611 1\r\n".utf8
        ))
        controller.ingest(Array(
            ("%begin 0 612 1\r\n"
                + "/dev/ttys-control|111|1700000001\r\n"
                // The PTY name was reused, but PID/creation prove this is
                // not our departed visible client.
                + "/dev/ttys-visible|999|1700000999\r\n"
                + "%end 0 612 1\r\n").utf8
        ))

        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        XCTAssertFalse(sent.string.contains("refresh-client -C"), sent.string)
    }

    func test_sideChannelRepaintRejectsStaleGeneration() {
        let (controller, _) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        controller.updateClientSize(cols: 47, rows: 20)
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }

        controller.reclaimGridAuthority()
        ackAllPending(controller)
        let settled = "beef,47x20,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(settled) \(settled) *\r\n".utf8
        ))

        let generation = try! XCTUnwrap(repaintGeneration)
        controller.completeGridAuthoritySideChannelRepaint(
            generation: generation &+ 1
        )
        XCTAssertTrue(controller.gridAuthority.isPeer)

        controller.completeGridAuthoritySideChannelRepaint(
            generation: generation
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_nonLatestPolicyProbeCompletesOnlyAfterClaimFence() {
        let (controller, sent) = makeController(path: .sideChannel)
        ackAllPending(controller)
        sent.clear()

        // The effective policy changes after attach. Reclaim must probe the
        // current window again instead of trusting hydration-time state; the
        // deliberately mismatched geometry can never satisfy `latest`.
        deliverStamp(controller, value: Self.peerValue)
        controller.updateClientSize(cols: 47, rows: 20)
        let stale = "beef,105x31,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(stale) \(stale) *\r\n".utf8
        ))
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        controller.reclaimGridAuthority()
        XCTAssertTrue(controller.gridAuthority.isPeer)

        // Drive every queued tmux response in FIFO order, giving only the
        // window-size probe a non-latest body. Commands appended by callbacks
        // are included as the wire grows.
        var responseIndex = 0
        while responseIndex < sent.string.split(separator: "\n").count,
              responseIndex < 100 {
            let commands = sent.string.split(separator: "\n").map(String.init)
            let body = commands[responseIndex].contains(
                "show-options -wA -v -t @0 window-size"
            )
                ? "smallest\r\n"
                : ""
            let number = 700 + responseIndex
            controller.ingest(Array(
                ("%begin 0 \(number) 1\r\n" + body + "%end 0 \(number) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        let generation = try! XCTUnwrap(repaintGeneration)
        XCTAssertTrue(
            controller.gridAuthority.isPeer,
            "the veil stays up until the exact side-channel repaint is consumed"
        )
        controller.completeGridAuthoritySideChannelRepaint(
            generation: generation
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_claimReprobesPolicyWhenCurrentWindowMoves() {
        let (controller, sent) = makeController(path: .sideChannel)
        controller.ingest(Array("%window-add @1\r\n%window-renamed @1 logs\r\n".utf8))
        let oldGrid = "beef,105x31,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(oldGrid) \(oldGrid) *\r\n".utf8
        ))
        controller.ingest(Array(
            "%layout-change @1 \(oldGrid) \(oldGrid) *\r\n".utf8
        ))
        ackAllPending(controller)
        deliverStamp(controller, value: Self.peerValue)
        controller.updateClientSize(cols: 47, rows: 20)
        sent.clear()

        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        controller.reclaimGridAuthority()
        XCTAssertTrue(
            sent.string.contains("show-options -wA -v -t @0 window-size"),
            sent.string
        )

        // The peer moves the shared session before the first target's probe
        // or fence responds. The replacement sequence must target @1 and make
        // every @0 callback stale within this same claim generation.
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        XCTAssertTrue(
            sent.string.contains("show-options -wA -v -t @1 window-size"),
            sent.string
        )

        var responseIndex = 0
        while responseIndex < sent.string.split(separator: "\n").count,
              responseIndex < 100 {
            let commands = sent.string.split(separator: "\n").map(String.init)
            let body = commands[responseIndex].contains(
                "show-options -wA -v -t @1 window-size"
            ) ? "smallest\r\n" : ""
            controller.ingest(Array(
                ("%begin 0 \(900 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(900 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        let generation = try! XCTUnwrap(repaintGeneration)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        controller.completeGridAuthoritySideChannelRepaint(generation: generation)
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_sideChannelRefenceForcesPreviouslyUnknownCurrentWindow() {
        let (controller, sent) = makeController(path: .sideChannel)
        let oldGrid = "beef,105x31,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(oldGrid) \(oldGrid) *\r\n".utf8
        ))
        ackAllPending(controller)
        deliverStamp(controller, value: Self.peerValue)
        controller.updateClientSize(cols: 47, rows: 20)
        sent.clear()

        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        controller.reclaimGridAuthority()
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))

        XCTAssertTrue(
            sent.string.contains("resize-window -x 47 -y 20 -t @1"),
            "the new current window must be included in the replacement force: \(sent.string)"
        )
        XCTAssertTrue(
            sent.string.contains("show-options -wA -v -t @1 window-size"),
            sent.string
        )

        let settled = "beef,47x20,0,0,0"
        controller.ingest(Array(
            "%layout-change @1 \(settled) \(settled) *\r\n".utf8
        ))
        var responseIndex = 0
        while responseIndex < sent.string.split(separator: "\n").count,
              repaintGeneration == nil,
              responseIndex < 200 {
            let commands = sent.string.split(separator: "\n").map(String.init)
            let body = commands[responseIndex].contains("window-size")
                ? "latest\r\n"
                : ""
            controller.ingest(Array(
                ("%begin 0 \(1_000 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(1_000 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        controller.completeGridAuthoritySideChannelRepaint(
            generation: try! XCTUnwrap(repaintGeneration)
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_sideChannelWindowMoveInvalidatesRepaintAlreadyInFlight() {
        let (controller, sent) = makeController(path: .sideChannel)
        controller.ingest(Array(
            ("%window-add @1\r\n%window-renamed @1 one\r\n"
                + "%window-add @2\r\n%window-renamed @2 two\r\n"
                + "%window-add @3\r\n%window-renamed @3 three\r\n").utf8
        ))
        let oldGrid = "beef,105x31,0,0,0"
        for window in 0...3 {
            controller.ingest(Array(
                "%layout-change @\(window) \(oldGrid) \(oldGrid) *\r\n".utf8
            ))
        }
        ackAllPending(controller)
        deliverStamp(controller, value: Self.peerValue)
        controller.updateClientSize(cols: 47, rows: 20)
        sent.clear()

        var repaintGenerations: [UInt64] = []
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGenerations.append(generation)
        }
        controller.reclaimGridAuthority()

        var responseIndex = 0
        while responseIndex < sent.string.split(separator: "\n").count,
              repaintGenerations.isEmpty,
              responseIndex < 100 {
            let commands = sent.string.split(separator: "\n").map(String.init)
            let body = commands[responseIndex].contains("window-size")
                ? "smallest\r\n"
                : ""
            controller.ingest(Array(
                ("%begin 0 \(950 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(950 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }
        let staleGeneration = try! XCTUnwrap(repaintGenerations.first)

        // More moves than the old retry cap, while the first repaint is
        // already in flight. The final target must still get a fresh fence.
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @3\r\n".utf8))
        XCTAssertTrue(
            sent.string.contains("show-options -wA -v -t @3 window-size"),
            sent.string
        )
        controller.completeGridAuthoritySideChannelRepaint(
            generation: staleGeneration
        )
        XCTAssertTrue(
            controller.gridAuthority.isPeer,
            "the previous window's frame must not lift the veil"
        )

        while responseIndex < sent.string.split(separator: "\n").count,
              repaintGenerations.count < 2,
              responseIndex < 150 {
            let commands = sent.string.split(separator: "\n").map(String.init)
            let body = commands[responseIndex].contains("window-size")
                ? "smallest\r\n"
                : ""
            controller.ingest(Array(
                ("%begin 0 \(950 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(950 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        let currentGeneration = try! XCTUnwrap(repaintGenerations.last)
        XCTAssertNotEqual(currentGeneration, staleGeneration)
        controller.completeGridAuthoritySideChannelRepaint(
            generation: currentGeneration
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_sideChannelReclaimKeepsDirectWindowForce() {
        let (controller, sent) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()
        controller.reclaimGridAuthority()
        let wire = sent.string
        XCTAssertTrue(wire.contains("resize-window -x 92 -y 38 -t @0"), wire)
        XCTAssertFalse(wire.contains("select-window"), wire)
        let unset = try! XCTUnwrap(
            wire.range(of: "set-option -w -u -t @0 window-size")
        )
        let policy = try! XCTUnwrap(
            wire.range(of: "show-options -wA -v -t @0 window-size")
        )
        XCTAssertLessThan(
            unset.lowerBound,
            policy.lowerBound,
            "policy must be sampled after resize-window's manual override is unset"
        )
    }

    func test_contestedReclaimFoldsBackToYielded() {
        let (controller, _) = makeController()
        deliverStamp(controller, value: Self.peerValue)
        controller.reclaimGridAuthority()
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        // A different foreign write lands after ours (T4): fold back.
        deliverStamp(controller, value: "v1 PEER-DEVICE-9999 4 iPhone")
        XCTAssertEqual(
            controller.gridAuthority,
            .peer(displayName: "iPhone")
        )
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        // The contest also disarms the pending claim: a late matching
        // layout event must NOT complete against the peer's grid.
        let layout = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        XCTAssertTrue(controller.gridAuthority.isPeer)
    }

    func test_reconnectRederivesInsteadOfStealing() {
        let (controller, sent) = makeController(path: .sideChannel)
        // First attach: handshake %end (server-originated, flags bit0 clear)
        // starts hydration — this fresh controller claims blindly.
        controller.ingest(Array("%begin 100 1 0\r\n%end 100 1 0\r\n".utf8))
        XCTAssertTrue(
            sent.string.contains("refresh-client -C 92,38"),
            "first attach claims: \(sent.string)"
        )
        XCTAssertTrue(sent.string.contains(TmuxController.gridAuthorityOption))

        // Drop with authority .mine-ish (NOT yielded) — the exact shape of
        // the seize bug: a takeover can happen during any gap.
        controller.sideChannelDisconnected()
        sent.clear()

        // Reconnect: DCS prologue + session + handshake %end.
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))
        // Re-derive must come FIRST, and no blind size claim with it.
        XCTAssertTrue(
            sent.string.contains("show-options -qv \(TmuxController.gridAuthorityOption)"),
            sent.string
        )
        XCTAssertFalse(
            sent.string.contains("refresh-client -C"),
            "reconnect must not steal before re-deriving: \(sent.string)"
        )

        // The stamp answer says the iPhone took over during our gap → yield.
        controller.ingest(Array(
            "%begin 0 201 1\r\n\(Self.peerValue)\r\n%end 0 201 1\r\n".utf8
        ))
        XCTAssertEqual(
            controller.gridAuthority,
            .peer(displayName: "iPhone")
        )
        XCTAssertFalse(
            sent.string.contains("refresh-client -C"),
            "yielded reconnect must never replay size: \(sent.string)"
        )
    }

    func test_yieldedSideChannelReconnectWithEmptyStampUsesFencedReclaim() {
        assertYieldedSideChannelReconnectSettles(rederivedStamp: "")
    }

    func test_yieldedSideChannelReconnectWithOwnStampUsesFencedReclaim() {
        assertYieldedSideChannelReconnectSettles(rederivedStamp: selfValue())
    }

    private func assertYieldedSideChannelReconnectSettles(
        rederivedStamp: String
    ) {
        let (controller, sent) = makeController(path: .sideChannel)
        controller.ingest(Array("%begin 100 1 0\r\n%end 100 1 0\r\n".utf8))
        ackAllPending(controller)
        deliverStamp(controller, value: Self.peerValue)
        controller.sideChannelDisconnected()
        sent.clear()

        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))

        let body = rederivedStamp.isEmpty ? "" : "\(rederivedStamp)\r\n"
        controller.ingest(Array(
            ("%begin 0 201 1\r\n" + body + "%end 0 201 1\r\n").utf8
        ))
        // This fixture's empty first hydration cleared its active-window
        // model. The real reconnect's current-window notification (or active
        // hydration reply) supplies the target and must resume the deferred
        // fenced claim without dropping the preserved veil.
        controller.ingest(Array("%session-window-changed $0 @0\r\n".utf8))

        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(sent.string.contains("refresh-client -C 92,38"), sent.string)
        XCTAssertTrue(
            sent.string.contains("show-options -wA -v -t @0 window-size"),
            sent.string
        )

        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(settled) \(settled) *\r\n".utf8
        ))
        ackAllPending(controller, frames: 40)
        controller.completeGridAuthoritySideChannelRepaint(
            generation: try! XCTUnwrap(repaintGeneration)
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_reconnectOwnEchoAfterInterveningPeerReentersFencedClaim() {
        let (controller, sent) = makeController(path: .sideChannel)
        controller.ingest(Array("%begin 100 1 0\r\n%end 100 1 0\r\n".utf8))
        controller.sideChannelDisconnected()
        sent.clear()

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))

        // Re-derive sees our old stamp and appends a fresh reconnect claim.
        controller.ingest(Array(
            "%begin 0 201 1\r\n\(selfValue())\r\n%end 0 201 1\r\n".utf8
        ))
        // The already-queued subscription can still report a peer write
        // before the fresh reconnect stamp's exact echo reaches us.
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        deliverStamp(controller, value: selfValue(gen: 2))

        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertTrue(
            sent.string.contains("authority-reconnect-ordering") == false,
            "diagnostic labels must not leak onto the tmux wire"
        )
        XCTAssertTrue(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption) 'v1 \(Self.selfID) 3 iPad'"),
            sent.string
        )
    }

    func test_reconnectIgnoresGeometryFallbackUntilStampRederives() {
        let (controller, sent) = makeController(path: .sideChannel)
        controller.ingest(Array("%begin 100 1 0\r\n%end 100 1 0\r\n".utf8))
        controller.sideChannelDisconnected()
        sent.clear()

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))

        let stale = "beef,105x31,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(stale) \(stale) *\r\n".utf8
        ))
        XCTAssertEqual(
            controller.gridAuthority,
            .unknown,
            "stale reconnect geometry must wait for the authoritative stamp query"
        )

        controller.ingest(Array(
            "%begin 0 201 1\r\n\(selfValue())\r\n%end 0 201 1\r\n".utf8
        ))
        XCTAssertTrue(sent.string.contains("refresh-client -C 92,38"), sent.string)
    }

    func test_sessionSwitchDropsPriorSessionAuthorityAndRederives() {
        let (controller, sent) = makeController(path: .sideChannel)
        controller.ingest(Array("%begin 100 1 0\r\n%end 100 1 0\r\n".utf8))
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        sent.clear()

        controller.ingest(Array("%session-changed $1 other\r\n".utf8))

        XCTAssertEqual(controller.gridAuthority, .unknown)
        XCTAssertTrue(
            sent.string.contains("show-options -qv \(TmuxController.gridAuthorityOption)"),
            sent.string
        )
        XCTAssertFalse(
            sent.string.contains("refresh-client -C"),
            "a session switch must re-derive before claiming: \(sent.string)"
        )
    }

    func test_reclaimWithoutPeerIsANoOp() {
        let (controller, sent) = makeController()
        controller.reclaimGridAuthority()
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        XCTAssertFalse(sent.string.contains(TmuxController.gridAuthorityOption))
    }

    // MARK: - Stamp-less fallback (bare tmux attach)

    func test_foreignLayoutSizeFallsBackToGenericPeer() {
        let (controller, _) = makeController()
        // No self-replay ran in this fixture (handshake %end never arrived),
        // so the suppression window is inactive.
        controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
        let layout = "beef,120x40,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        XCTAssertEqual(
            controller.gridAuthority,
            .peer(displayName: "another device")
        )
    }

    func test_policyProbeRechecksLayoutThatArrivedWhilePolicyWasUnknown() {
        let (controller, sent) = makeController()
        controller.ingest(Array("%window-add @1\r\n%window-renamed @1 logs\r\n".utf8))
        ackAllPending(controller)
        sent.clear()

        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        XCTAssertTrue(
            sent.string.contains("show-options -wA -v -t @1 window-size"),
            sent.string
        )
        let foreign = "beef,120x40,0,0,0"
        controller.ingest(Array(
            "%layout-change @1 \(foreign) \(foreign) *\r\n".utf8
        ))
        XCTAssertFalse(controller.gridAuthority.isPeer)

        controller.ingest(Array(
            "%begin 0 860 1\r\nlatest\r\n%end 0 860 1\r\n".utf8
        ))
        XCTAssertEqual(
            controller.gridAuthority,
            .peer(displayName: "another device")
        )
    }

    func test_matchingLayoutSizeDoesNotTrigger() {
        let (controller, _) = makeController()
        let layout = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        XCTAssertEqual(controller.gridAuthority, .unknown)
    }

    // MARK: - Participation gating

    func test_observerPolicyDoesNotParticipate() {
        let (controller, sent) = makeController(
            policy: .preserveServerGeometry
        )
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertEqual(controller.gridAuthority, .unknown)
        controller.reclaimGridAuthority()
        XCTAssertFalse(sent.string.contains(TmuxController.gridAuthorityOption))
    }

    func test_nilIdentityDoesNotParticipate() {
        let (controller, _) = makeController(identity: nil)
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertEqual(controller.gridAuthority, .unknown)
    }

    // MARK: - Foreign-session stamps are filtered

    func test_foreignSessionStampIsDropped() {
        let (controller, _) = makeController()
        controller.ingest(Array(
            "%subscription-changed tessera-authority $7 @9 0 %9 : \(Self.peerValue)\r\n".utf8
        ))
        XCTAssertEqual(controller.gridAuthority, .unknown)
    }

    // MARK: - Reset latches the reconnect re-derive

    func test_sideChannelDisconnectWhileYieldedPreservesFailClosedAuthority() {
        let (controller, _) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        controller.sideChannelDisconnected()
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
    }

    func test_fullSideChannelResetWhileYieldedAlsoPreservesFailClosedAuthority() {
        let (controller, _) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)

        controller.reset()

        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
    }
}
