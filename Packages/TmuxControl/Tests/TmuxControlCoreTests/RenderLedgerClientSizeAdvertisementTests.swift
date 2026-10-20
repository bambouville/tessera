import XCTest
@testable import TmuxControlCore

/// P6: `refresh-client -C` goes out only when the grid differs from the one
/// this control connection last advertised. An unchanged `-C` recalculates
/// with `now` set and so resizes every window on the server; the inline
/// latest fence alone is the cheap way to re-take `latest`.
final class RenderLedgerClientSizeAdvertisementTests: XCTestCase {
    private let fence = TmuxClientSizeReplay.latestFenceCommand

    func test_unchangedInlineReplaySendsOnlyTheFence() {
        var ledger = attachedLedger(.inline)
        XCTAssertEqual(sizeCommands(&ledger, 100, 30), ["refresh-client -C 100,30", fence])
        XCTAssertEqual(sizeCommands(&ledger, 100, 30), [fence])
        XCTAssertEqual(sizeCommands(&ledger, 100, 30), [fence])
        XCTAssertEqual(sizeCommands(&ledger, 101, 30), ["refresh-client -C 101,30", fence])
        XCTAssertEqual(sizeCommands(&ledger, 100, 30), ["refresh-client -C 100,30", fence])
    }

    func test_unchangedClaimReplayAndSideChannelReplaySendNothing() {
        var claim = attachedLedger(.inline, claim: true)
        XCTAssertEqual(sizeCommands(&claim, 90, 40), ["refresh-client -C 90,40"])
        XCTAssertEqual(sizeCommands(&claim, 90, 40), [], "the claim's own fence follows")

        var side = attachedLedger(.sideChannel)
        XCTAssertEqual(sizeCommands(&side, 90, 40), ["refresh-client -C 90,40"])
        XCTAssertEqual(sizeCommands(&side, 90, 40), [])
    }

    /// Every connection boundary forgets the advertisement: a new control
    /// client starts at tmux's 80x24, and a reset queue lost the reply that
    /// could have withdrawn an in-flight `-C`.
    func test_connectionBoundariesAdvertiseAgain() {
        let boundaries: [(String, (inout TmuxRenderLedger) -> Void)] = [
            ("reattach", { ledger in
                _ = ledger.reduce(.transportLost, snapshot: Self.state)
                _ = ledger.reduce(.transportAttached(.inline), snapshot: Self.state)
            }),
            ("attach-without-loss", { ledger in
                _ = ledger.reduce(.transportAttached(.inline), snapshot: Self.state)
            }),
            ("reset", { ledger in
                _ = ledger.reset()
                _ = ledger.reduce(.transportAttached(.inline), snapshot: Self.state)
            }),
            ("command-queue-reset", { ledger in ledger.resetCommandQueue() }),
            ("session-changed", { ledger in
                _ = ledger.reduce(
                    .message(.sessionChanged(sessionId: SessionId(4), name: "other")),
                    snapshot: Self.state
                )
            }),
        ]
        for (name, boundary) in boundaries {
            var ledger = attachedLedger(.inline)
            XCTAssertEqual(sizeCommands(&ledger, 100, 30).first, "refresh-client -C 100,30", name)
            XCTAssertEqual(sizeCommands(&ledger, 100, 30), [fence], name)
            boundary(&ledger)
            XCTAssertEqual(
                sizeCommands(&ledger, 100, 30),
                ["refresh-client -C 100,30", fence],
                name
            )
        }
    }

    func test_aRejectedRefreshIsAdvertisedAgain() {
        var ledger = attachedLedger(.inline)
        XCTAssertEqual(sizeCommands(&ledger, 100, 30), ["refresh-client -C 100,30", fence])
        let rejected = complete(&ledger, success: false)
        XCTAssertTrue(rejected.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("client-size-rejected") }
            return false
        })
        _ = complete(&ledger, success: true) // the fence
        XCTAssertEqual(sizeCommands(&ledger, 100, 30), ["refresh-client -C 100,30", fence])
    }

    /// Only the newest advertisement is withdrawn: a rejected older size must
    /// not make the ledger resend a younger one tmux accepted.
    func test_aRejectedOlderRefreshKeepsTheYoungerAdvertisement() {
        var ledger = attachedLedger(.inline)
        _ = sizeCommands(&ledger, 100, 30)
        _ = sizeCommands(&ledger, 101, 30)
        _ = complete(&ledger, success: false) // -C 100,30
        _ = complete(&ledger, success: true) // fence
        _ = complete(&ledger, success: true) // -C 101,30
        _ = complete(&ledger, success: true) // fence
        XCTAssertEqual(sizeCommands(&ledger, 101, 30), [fence])
    }

    /// A platform transaction that sent its own `-C` (iOS's reverse-attach
    /// cede) reports the acknowledged grid, but that acknowledgement is no
    /// proof the window follows it (the cede changes `ignore-size`): the
    /// next replay at that grid, a claim's included, sends its `-C` again.
    func test_platformAppliedSizeIsNotTrustedAsAdvertised() {
        var ledger = attachedLedger(.inline)
        _ = ledger.noteAppliedClientSize(columns: 120, rows: 40)
        XCTAssertEqual(sizeCommands(&ledger, 120, 40), ["refresh-client -C 120,40", fence])
        _ = complete(&ledger, success: true) // -C 120,40
        _ = complete(&ledger, success: true) // fence
        XCTAssertEqual(sizeCommands(&ledger, 120, 40), [fence], "the ledger's own replay is trusted")

        // A cede after an advertisement of the same grid withdraws it.
        _ = complete(&ledger, success: true) // fence
        _ = ledger.noteAppliedClientSize(columns: 120, rows: 40)
        XCTAssertEqual(sizeCommands(&ledger, 120, 40), ["refresh-client -C 120,40", fence])

        var claiming = attachedLedger(.inline, claim: true)
        XCTAssertEqual(sizeCommands(&claiming, 120, 40), ["refresh-client -C 120,40"])
        _ = complete(&claiming, success: true)
        _ = claiming.noteAppliedClientSize(columns: 120, rows: 40)
        XCTAssertEqual(sizeCommands(&claiming, 120, 40), ["refresh-client -C 120,40"], "the claim re-sends its -C")
    }

    /// Android keeps today's behaviour until its adapter opts in.
    func test_defaultConfigurationStillSendsEveryRefresh() {
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.transportAttached(.inline), snapshot: Self.state)
        XCTAssertFalse(TmuxRenderLedger.Configuration().suppressesUnchangedClientSizeReplay)
        for _ in 0..<3 {
            XCTAssertEqual(sizeCommands(&ledger, 100, 30), ["refresh-client -C 100,30", fence])
        }
    }

    // MARK: - Fixture

    private static let state = TmuxSnapshot(
        sessionID: SessionId(0),
        sessionName: "work",
        activeWindowID: WindowId(1),
        windows: [.init(
            id: WindowId(1),
            name: "window-1",
            activePaneID: PaneId(1),
            panes: [.init(id: PaneId(1), isActive: true)]
        )],
        authority: .unknown
    )

    private func attachedLedger(_ profile: RenderProfile, claim: Bool = false) -> TmuxRenderLedger {
        var ledger = TmuxRenderLedger(configuration: .init(
            inlineClientSizeReplayBelongsToClaim: claim,
            suppressesUnchangedClientSizeReplay: true
        ))
        _ = ledger.reduce(.transportAttached(profile), snapshot: Self.state)
        return ledger
    }

    private func sizeCommands(_ ledger: inout TmuxRenderLedger, _ columns: Int, _ rows: Int) -> [String] {
        ledger.reduce(.clientSize(columns: columns, rows: rows), snapshot: Self.state)
            .compactMap { effect in
                guard case .sendCommand(let command) = effect else { return nil }
                return command
            }
    }

    private func complete(_ ledger: inout TmuxRenderLedger, success: Bool) -> [RenderEffect] {
        let frame = TmuxCommandGuard(time: 1, commandNumber: 1, flags: 1)
        return ledger.reduce(.correlation(.frameCompleted(.init(
            status: success ? .success : .error,
            begin: frame,
            end: frame,
            effectiveFlags: 1,
            guardMatches: true,
            lines: []
        ))), snapshot: Self.state)
    }
}
