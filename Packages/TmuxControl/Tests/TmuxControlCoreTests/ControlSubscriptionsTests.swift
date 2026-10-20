import Foundation
import XCTest
@testable import TmuxControlCore

/// tmux 3.2 through 3.6a crash the server when a control client holding a
/// `%*`, `@*` or session subscription outlives its session. These tests pin
/// that every feed is registered per pane or on one window, follows the
/// topology, and never takes one of those targets.
final class ControlSubscriptionsTests: XCTestCase {
    /// @0 split into %1 and %2, @1 holding %3.
    private let windows = [
        "__tessera_windows__\t@0\t0\t%1\taa01,80x24,0,0{40x24,0,0,1,39x24,41,0,2}\taa01,80x24,0,0{40x24,0,0,1,39x24,41,0,2}\t0\tzsh",
        "__tessera_windows__\t@1\t1\t%3\tbb01,80x24,0,0,3\tbb01,80x24,0,0,3\t0\tvim",
    ].joined(separator: "\r\n")
    private let all = TmuxSubscriptionRequests(
        bell: true, paneMetadata: true, windowOrder: true, authority: .ownSession
    )

    func test_nothingIsRegisteredBeforeTheWindowListAnswers() {
        var engine = TmuxRuntimeEngine()
        engine.subscriptionRequests = all
        engine.feedWire("%session-changed $0 work\r\n%window-add @0\r\n%layout-change @0 aa01,80x24,0,0,1 aa01,80x24,0,0,1 *\r\n")
        XCTAssertEqual(engine.takePendingSubscriptionCommands(), [])
    }

    func test_everyFeedIsRegisteredPerPaneAndNeverServerWide() {
        var engine = attached(version: "3.4")
        let commands = engine.takePendingSubscriptionCommands()
        let meta = TmuxPaneMetadataSubscription.format
        let bell = "#{window_bell_flag}"
        XCTAssertEqual(commands, [
            "refresh-client -B 'tessera-authority:@0:#{@tessera_authority}'"
                + " -B 'tessera-window-order:@0:\(TmuxWindowOrderSubscription.format)'",
            "refresh-client -B 'tessera-pane-meta.1:%1:\(meta)' -B 'tessera-bell.1:%1:\(bell)'",
            "refresh-client -B 'tessera-pane-meta.2:%2:\(meta)' -B 'tessera-bell.2:%2:\(bell)'",
            "refresh-client -B 'tessera-pane-meta.3:%3:\(meta)' -B 'tessera-bell.3:%3:\(bell)'",
        ])
        for command in commands {
            XCTAssertFalse(command.contains(":%*:"), command)
            XCTAssertFalse(command.contains(":@*:"), command)
            XCTAssertFalse(command.contains("::"), "an empty target is a session subscription: \(command)")
        }
        XCTAssertEqual(engine.takePendingSubscriptionCommands(), [], "draining is destructive")
    }

    func test_aClosedPaneIsDroppedAndOnlyItsFeedsChange() {
        var engine = attached(version: "3.4")
        _ = engine.takePendingSubscriptionCommands()
        engine.feedWire("%layout-change @0 aa01,80x24,0,0,1 aa01,80x24,0,0,1 *\r\n")
        XCTAssertEqual(
            engine.takePendingSubscriptionCommands(),
            ["refresh-client -B 'tessera-bell.2' -B 'tessera-pane-meta.2'"]
        )
    }

    func test_aSplitRegistersTheNewPane() {
        var engine = attached(version: "3.4")
        _ = engine.takePendingSubscriptionCommands()
        engine.feedWire("%layout-change @1 bb02,80x24,0,0{40x24,0,0,3,39x24,41,0,7} bb02,80x24,0,0{40x24,0,0,3,39x24,41,0,7} *\r\n")
        XCTAssertEqual(engine.takePendingSubscriptionCommands(), [
            "refresh-client -B 'tessera-pane-meta.7:%7:\(TmuxPaneMetadataSubscription.format)'"
                + " -B 'tessera-bell.7:%7:#{window_bell_flag}'",
        ])
    }

    func test_sessionFeedsMoveOffAClosedAnchorUnderTheirOwnNames() {
        var engine = attached(version: "3.4")
        _ = engine.takePendingSubscriptionCommands()
        engine.feedWire("%window-close @0\r\n")
        engine.reply("__tessera_windows__\t@1\t1\t%3\tbb01,80x24,0,0,3\tbb01,80x24,0,0,3\t0\tvim")
        XCTAssertEqual(engine.takePendingSubscriptionCommands(), [
            "refresh-client -B 'tessera-bell.1' -B 'tessera-bell.2' -B 'tessera-pane-meta.1' -B 'tessera-pane-meta.2'",
            "refresh-client -B 'tessera-authority:@1:#{@tessera_authority}'"
                + " -B 'tessera-window-order:@1:\(TmuxWindowOrderSubscription.format)'",
        ], "re-registering a name replaces it in tmux, so the anchor moves without a removal")
    }

    /// A pane's subscriptions fall silent while it is dead (`remain-on-exit`)
    /// and a pane anchor would take the session feeds with it; a window's are
    /// read in its active pane whatever that pane's state.
    func test_sessionFeedsRideAWindowThatStaysPutWhileItLives() {
        var engine = TmuxRuntimeEngine()
        engine.subscriptionRequests = all
        engine.feedWire("%session-changed $0 work\r\n")
        engine.reply("__tessera_windows__\t@1\t1\t%3\tbb01,80x24,0,0,3\tbb01,80x24,0,0,3\t0\tvim")
        engine.reply("__tessera_active_window__\t@1\t3.4")
        XCTAssertTrue(engine.takePendingSubscriptionCommands().contains {
            $0.hasPrefix("refresh-client -B 'tessera-authority:@1:")
        })
        engine.feedWire("%window-add @0\r\n%layout-change @0 aa01,80x24,0,0,1 aa01,80x24,0,0,1 *\r\n")
        let commands = engine.takePendingSubscriptionCommands()
        XCTAssertFalse(commands.contains { $0.contains("tessera-authority") }, "\(commands)")
        XCTAssertTrue(commands.contains { $0.contains("tessera-pane-meta.1:%1:") }, "\(commands)")
    }

    func test_windowFeedUpdatesReachTheirConsumers() {
        var engine = attached(version: "3.4")
        _ = engine.takePendingSubscriptionCommands()
        engine.feedWire("%subscription-changed tessera-window-order $0 @0 0 - : 0=@1 1=@0* \r\n")
        XCTAssertEqual(engine.snapshot.windows.map(\.id), [WindowId(1), WindowId(0)])
        let batch = engine.feed(Array("%subscription-changed tessera-authority $0 @0 0 - : v1 PEER 2 Mac\r\n".utf8))
        XCTAssertEqual(batch.authorityStamps, ["v1 PEER 2 Mac"])
        let foreign = engine.feed(Array("%subscription-changed tessera-authority $9 @0 0 - : v1 OTHER 3 Mac\r\n".utf8))
        XCTAssertEqual(foreign.authorityStamps, [], "another session's read is not ours")
    }

    func test_ownerScopeAndScopeChangesReregisterTheAuthorityFeed() {
        var engine = attached(version: "3.4")
        _ = engine.takePendingSubscriptionCommands()
        engine.subscriptionRequests.authority = .owner(SessionId(4))
        XCTAssertEqual(engine.takePendingSubscriptionCommands(), [
            "refresh-client -B 'tessera-authority:@0:#{S:#{?#{==:#{session_id},$4},#{@tessera_authority},}}'",
        ])
        engine.subscriptionRequests.authority = nil
        XCTAssertEqual(engine.takePendingSubscriptionCommands(), ["refresh-client -B 'tessera-authority'"])
    }

    func test_windowOrderWaitsForAVersionThatSupportsIt() {
        var unknown = attached(version: nil)
        XCTAssertFalse(unknown.takePendingSubscriptionCommands().contains { $0.contains("tessera-window-order") })

        var old = attached(version: "3.1c")
        XCTAssertFalse(old.takePendingSubscriptionCommands().contains { $0.contains("tessera-window-order") })
    }

    /// OpenBSD's tmux reports its OS release as the version. Only window
    /// order waits for a version known to support it; the other feeds were
    /// never version-gated.
    func test_anUnreadableVersionKeepsEveryOtherFeed() {
        var engine = TmuxRuntimeEngine()
        engine.subscriptionRequests = all
        engine.feedWire("%session-changed $0 work\r\n")
        engine.reply(windows)
        let beforeVersion = engine.takePendingSubscriptionCommands()
        engine.reply("__tessera_active_window__\t@0\topenbsd-7.5")
        XCTAssertEqual(engine.takePendingSubscriptionCommands(), [], "an unreadable version removes nothing")
        XCTAssertEqual(beforeVersion.count, 4)
        XCTAssertTrue(beforeVersion.contains { $0.contains("tessera-authority:@0:") })
        XCTAssertFalse(beforeVersion.contains { $0.contains("tessera-window-order") })
    }

    func test_aNewConnectionRegistersEverythingAgainAfterItsOwnWindowList() {
        var engine = attached(version: "3.4")
        _ = engine.takePendingSubscriptionCommands()
        engine.reset(keepingSnapshot: true)
        XCTAssertEqual(engine.takePendingSubscriptionCommands(), [], "the kept panes are the last connection's")
        engine.feedWire("%session-changed $0 work\r\n")
        engine.reply(windows)
        XCTAssertEqual(engine.takePendingSubscriptionCommands().count, 4, "requests survive the reset")
    }

    func test_perPaneUpdatesReachTheirConsumers() {
        var engine = attached(version: "3.4")
        let value = ["@1", "%3", "1", "0", "0", "80", "24", "vim", "notes", "vim", "host", "/tmp", "", "0", "0", "0"]
            .joined(separator: "\t")
        engine.feedWire("%subscription-changed tessera-pane-meta.3 $0 @1 1 %3 : \(value)\r\n")
        XCTAssertEqual(engine.snapshot.windows.first { $0.id == WindowId(1) }?.activePaneTitle, "notes")

        engine.feedWire("%subscription-changed tessera-bell.3 $0 @1 1 %3 : 0\r\n")
        let batch = engine.feed(Array("%subscription-changed tessera-bell.3 $0 @1 1 %3 : 1\r\n".utf8))
        XCTAssertEqual(batch.bells.map(\.windowID), [WindowId(1)], "the first value is the baseline; the rise rings")
    }

    func test_aBoundedDrainHandsOutTheRestInOrderBeforeLaterChanges() {
        var engine = attached(version: "3.4")
        let all = engine.takePendingSubscriptionCommands()
        engine.reset()
        engine.feedWire("%session-changed $0 work\r\n")
        engine.reply(windows)
        engine.reply("__tessera_active_window__\t@0\t3.4")
        XCTAssertEqual(engine.takePendingSubscriptionCommands(maximumBytes: 1), [all[0]], "one command at least")
        engine.subscriptionRequests.bell = false
        let rest = engine.takePendingSubscriptionCommands()
        XCTAssertEqual(Array(rest.prefix(3)), Array(all.dropFirst()), "queued commands go first")
        XCTAssertEqual(rest.dropFirst(3).first, "refresh-client -B 'tessera-bell.1' -B 'tessera-bell.2' -B 'tessera-bell.3'")
        XCTAssertEqual(engine.takePendingSubscriptionCommands(maximumBytes: 1), [])
    }

    func test_feedNamesMatchOnlyTheirOwnPerPaneForm() {
        let feed = TmuxBellSubscription.name
        XCTAssertTrue(TmuxControlSubscriptions.name("tessera-bell", isFeed: feed))
        XCTAssertTrue(TmuxControlSubscriptions.name("tessera-bell.12", isFeed: feed))
        for other in ["tessera-bell.", "tessera-bell.1a", "tessera-bellx", "tessera-bell-1", "tessera-bel", "x.tessera-bell"] {
            XCTAssertFalse(TmuxControlSubscriptions.name(other, isFeed: feed), other)
        }
    }

    private func attached(version: String?) -> TmuxRuntimeEngine {
        var engine = TmuxRuntimeEngine()
        engine.subscriptionRequests = all
        engine.feedWire("%session-changed $0 work\r\n")
        engine.reply(windows)
        if let version {
            engine.reply("__tessera_active_window__\t@0\t\(version)")
        }
        return engine
    }
}

private extension TmuxRuntimeEngine {
    mutating func feedWire(_ text: String) { _ = feed(Array(text.utf8)) }

    mutating func reply(_ lines: String) {
        feedWire("%begin 1 1 1\r\n\(lines)\r\n%end 1 1 1\r\n")
    }
}
