import XCTest
@testable import TmuxControl

/// Exercises the controller's real notification and command-reply boundary.
/// The remote window keeps its width while a keyboard/status-row transition
/// leaves its height behind the already settled local viewport.
@MainActor
final class WindowHeightRecoveryTests: XCTestCase {
    @MainActor
    private final class WireFixture {
        let controller: TmuxController
        private(set) var writes: [String] = []
        private var outstanding: [String] = []
        private var responseNumber = 2
        private var sessionID = "$0"
        private var repaintGeneration: UInt64?
        private(set) var repaintRequests = 0
        var remoteColumns = 56
        var remoteRows = 48
        var authorityValue = ""
        var controlClientIdentity = "own-control|101|1001"
        var visibleClientIdentity = "own-visible|102|1002"
        var controlClientReply: [String]?
        var visibleClientReply: [String]?
        var serverClientRows = [
            "@5\town-control\t101\t1001",
            "@5\town-visible\t102\t1002",
        ]

        init(authority: Bool = false, columns: Int = 56, rows: Int = 48) throws {
            controller = TmuxController(controlPath: .sideChannel)
            remoteColumns = columns
            remoteRows = rows
            controller.feedTerminal = { _ in }
            controller.sendBytes = { [weak self] bytes in
                let commands = String(decoding: bytes, as: UTF8.self)
                    .split(separator: "\n").map(String.init)
                self?.writes.append(contentsOf: commands)
                self?.outstanding.append(contentsOf: commands)
            }
            if authority {
                // This device already owns the window at its size, so the
                // attach read releases ordinary geometry (S2': attach never
                // claims; it only follows the stamp).
                authorityValue = "v1 HEIGHT-SELF 1 iPad"
                controller.gridAuthorityIdentity = .init(id: "HEIGHT-SELF", displayName: "iPad")
                controller.gridAuthorityAdoptShown()
                controller.onGridAuthoritySideChannelRepaintRequired = { [weak self] _, generation in
                    self?.repaintRequests += 1
                    self?.repaintGeneration = generation
                }
                controller.updateClientSize(cols: columns, rows: rows)
            }
            try attach()
            if authority {
                // The local viewport settles once more after attach (a Split
                // View or font settle: one column and back). For the owner
                // these are ordinary owned replays, which open the same
                // post-replay window the height repair relies on in the app.
                // A same-size pass is not one: it sends nothing (M6).
                controller.updateClientSize(cols: columns - 1, rows: rows)
                layout(rows: rows, columns: columns - 1)
                try drain()
                controller.updateClientSize(cols: columns, rows: rows)
                layout(rows: rows, columns: columns)
            } else {
                controller.updateClientSize(cols: columns, rows: rows)
            }
            try drain()
            try completePendingRepaint()
            if authority { XCTAssertEqual(controller.gridAuthority, .mine) }
            clearWrites()
        }

        var forces: [String] { writes.filter { $0.hasPrefix("resize-window ") } }
        var confirmations: [String] { writes.filter { $0.contains("tessera-window-size") } }
        // Core hydration and platform mutations share the wire FIFO. The
        // platform-only debug command list omits Core hydration requests.
        var pending: [String] { outstanding }

        func clearWrites() { writes.removeAll() }

        func layout(rows: Int, columns: Int? = nil, windowID: Int = 5, paneID: Int = 12) {
            if windowID == 5 {
                remoteRows = rows
                if let columns { remoteColumns = columns }
            }
            let value = "beef,\(columns ?? remoteColumns)x\(rows),0,0,\(paneID)"
            controller.ingest(Array("%layout-change @\(windowID) \(value) \(value) *\r\n".utf8))
        }

        func addFittingBackgroundWindow() throws {
            controller.ingest(Array("%window-add @6\r\n".utf8))
            try drain()
            XCTAssertEqual(controller.activeWindowId, WindowId(5))
            XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(6) })?.layout?.root.rect.height, 48)
        }

        func stamp(_ value: String) {
            authorityValue = value
            controller.ingest(Array("%subscription-changed tessera-authority \(sessionID) @5 0 %12 : \(value)\r\n".utf8))
        }

        func attach() throws {
            beginAttach()
            try drain()
            layout(rows: remoteRows)
            try drain()
            XCTAssertEqual(controller.mode, .tmuxControl)
            XCTAssertEqual(controller.activeWindowId, WindowId(5))
            XCTAssertEqual(controller.windows.first?.layout?.root.rect.height, remoteRows)
        }

        func beginAttach() {
            sessionID = "$0"
            controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
            controller.ingest(Array("%session-changed $0 height-test\r\n%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        }

        func beginAttachBeforeSessionChanged() {
            sessionID = "$545"
            controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
            // The same incoming chunk completes attach before it identifies
            // the new session. The first query therefore captured nil.
            controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n%session-changed $545 resumed\r\n".utf8))
        }

        func reply(_ lines: [String] = [], success: Bool = true) {
            XCTAssertFalse(outstanding.isEmpty, "fixture reply has no sent command")
            let command = outstanding.isEmpty ? nil : outstanding.removeFirst()
            let number = responseNumber
            responseNumber += 1
            let status = success ? "%end" : "%error"
            let body = (["%begin 0 \(number) 1"] + lines + ["\(status) 0 \(number) 1"])
                .joined(separator: "\r\n") + "\r\n"
            controller.ingest(Array(body.utf8))
            if success, let command, command.hasPrefix("set-option @tessera_authority '") {
                let value = String(command.dropFirst("set-option @tessera_authority '".count).dropLast())
                stamp(value) // subscription echo follows the successful server write
            }
        }

        func resetTransport() {
            controller.reset()
            outstanding.removeAll()
        }

        func drain() throws {
            var count = 0
            while let command = pending.first {
                count += 1
                guard count <= 100 else {
                    XCTFail("fixture command loop: \(pending)")
                    throw FixtureError.commandLoop
                }
                reply(startupReply(command))
            }
        }

        /// Leave the exact post-unset query at the head of the real FIFO.
        func reachConfirmation() throws {
            var count = 0
            while let command = pending.first, !command.contains("tessera-window-size") {
                count += 1
                guard count <= 100 else { throw FixtureError.commandLoop }
                reply(startupReply(command))
            }
            let command = try XCTUnwrap(pending.first, "no post-unset confirmation query was sent")
            XCTAssertTrue(command.contains("tessera-window-size"), command)
        }

        func confirm(_ line: String) throws {
            try reachConfirmation()
            reply([line])
        }

        func reachAuthorityQuery() throws {
            var count = 0
            while let command = pending.first, !command.hasPrefix("show-options -qv @tessera_authority") {
                count += 1
                guard count <= 100 else { throw FixtureError.commandLoop }
                reply(startupReply(command))
            }
            let command = try XCTUnwrap(pending.first, "no fresh authority query was sent")
            XCTAssertTrue(command.hasPrefix("show-options -qv @tessera_authority"), command)
        }

        /// Admit passive recovery through the real authority/client proof replies,
        /// stopping before any remote geometry mutation acknowledges.
        func reachFirstForce() throws {
            var count = 0
            while let command = pending.first, !command.hasPrefix("resize-window ") {
                count += 1
                guard count <= 100 else { throw FixtureError.commandLoop }
                reply(startupReply(command))
            }
            let command = try XCTUnwrap(pending.first, "passive recovery never sent its first force")
            XCTAssertTrue(command.hasPrefix("resize-window "), command)
        }

        func completePendingRepaint() throws {
            if let generation = repaintGeneration {
                repaintGeneration = nil
                controller.completeGridAuthoritySideChannelRepaint(generation: generation)
                try drain()
            }
        }

        private func startupReply(_ command: String) -> [String] {
            let value = "beef,\(remoteColumns)x\(remoteRows),0,0,12"
            if command.hasPrefix("set-option @tessera_authority '") {
                authorityValue = String(command.dropFirst("set-option @tessera_authority '".count).dropLast())
                return []
            }
            if command.hasPrefix("show-options -qv @tessera_authority") { return [authorityValue] }
            if command.hasPrefix("show-options "), command.contains("@tessera-visible-HEIGHT-SELF") {
                return visibleClientReply ?? [visibleClientIdentity]
            }
            if command.hasPrefix("display-message "), command.contains("#{client_name}|#{client_pid}|#{client_created}") {
                return controlClientReply ?? [controlClientIdentity]
            }
            if command.hasPrefix("list-clients "), command.contains("#{window_id}") { return serverClientRows }
            if command.hasPrefix("list-windows ") {
                if command.contains("__tessera_windows__") {
                    return ["__tessera_windows__\t@5\t0\t%12\t\(value)\t\(value)\t0\teditor"]
                }
                return ["@5\t0\t\(value)\t\(value)\t0\teditor"]
            }
            if command.hasPrefix("list-panes ") {
                if command.contains("__tessera_panes__") {
                    return ["__tessera_panes__\t@5\t%12\t1\t0\t0\t\(remoteColumns)\t\(remoteRows)\tpane\t/tmp\thost"]
                }
                return ["@5\t%12\t1\t0\t0\t\(remoteColumns)\t\(remoteRows)\tzsh\tpane\thost"]
            }
            if command.contains("__tessera_active_window__") {
                return ["__tessera_active_window__\t@5\t3.4"]
            }
            if command.contains("__tessera_window_details__") {
                if command.contains("-t @6 ") {
                    let backgroundValue = "beef,56x48,0,0,13"
                    return ["__tessera_window_details__\t@6\t1\t%13\t\(backgroundValue)\t\(backgroundValue)\t0\tpeer"]
                }
                return ["__tessera_window_details__\t@5\t0\t%12\t\(value)\t\(value)\t0\teditor"]
            }
            if command.contains("tessera-window-size") {
                return ["tessera-window-size\t@5\t\(remoteColumns)\t\(remoteRows)"]
            }
            if command.hasPrefix("show-options ") && command.hasSuffix(" window-size") { return ["latest"] }
            return []
        }

        private enum FixtureError: Error { case commandLoop }
    }

    func test_matchingGridThenTwoRowDriftRepairsFromLayoutWithoutAnotherViewport() throws {
        let wire = try WireFixture(authority: true)
        wire.layout(rows: 46)
        try wire.reachFirstForce()

        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"])
        guard !wire.forces.isEmpty else { return }
        XCTAssertTrue(wire.confirmations.isEmpty, "the query must wait for all three mutations to acknowledge")
        wire.reply() // resize-window
        XCTAssertTrue(wire.confirmations.isEmpty, "resize acknowledgement alone precedes unset recalculation")
        wire.reply() // targetless latest fence
        XCTAssertTrue(wire.confirmations.isEmpty, "the fence alone precedes policy restore")
        wire.reply() // unset window-size
        XCTAssertEqual(wire.confirmations, [
            "display-message -p -t @5 'tessera-window-size\t#{window_id}\t#{window_width}\t#{window_height}'",
        ])
        let force = try XCTUnwrap(wire.writes.firstIndex(of: "resize-window -x 56 -y 48 -t @5"))
        let unset = try XCTUnwrap(wire.writes.firstIndex(of: "set-option -w -u -t @5 window-size"))
        let confirmation = try XCTUnwrap(wire.writes.firstIndex { $0.contains("tessera-window-size") })
        let fence = try XCTUnwrap(wire.writes.firstIndex(of: "select-window"))
        XCTAssertLessThan(force, fence)
        XCTAssertLessThan(fence, unset)
        XCTAssertLessThan(unset, confirmation)
    }

    func test_repeatedHeightMismatchWaitsForTheExistingConfirmation() throws {
        let wire = try WireFixture(authority: true)
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        wire.layout(rows: 46)
        wire.layout(rows: 46)

        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"])
        try wire.reachConfirmation()
        XCTAssertEqual(wire.confirmations.count, 1)
    }

    func test_transientMatchingLayoutDoesNotRearmBeforePostUnsetConfirmation() throws {
        let wire = try WireFixture(authority: true)
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        wire.layout(rows: 48) // resize-window's temporary result
        wire.layout(rows: 46) // unsetting window-size recalculated it again
        XCTAssertEqual(wire.forces.count, 1)

        try wire.confirm("tessera-window-size\t@5\t56\t46")
        wire.layout(rows: 46)
        XCTAssertEqual(wire.forces.count, 1, "a transient notification is not final geometry proof")
    }

    func test_freshExactConfirmationAllowsALaterHeightDriftToRepair() throws {
        let wire = try WireFixture(authority: true)
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        wire.layout(rows: 48)
        try wire.confirm("tessera-window-size\t@5\t56\t48")
        wire.clearWrites()
        wire.layout(rows: 46)
        try wire.reachFirstForce()

        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"])
        try wire.reachConfirmation()
        XCTAssertEqual(wire.confirmations.count, 1)
    }

    func test_invalidConfirmationLeavesTheAttemptLatched() throws {
        for line in [
            "", "tessera-window-size\t@5\t56\t46", "tessera-window-size\t@6\t56\t48",
            "tessera-window-size\t@5\t57\t48", "tessera-window-size\t@5\t56\tbad",
            "other-tag\t@5\t56\t48", "tessera-window-size\t@5\t56\t48\textra",
        ] {
            let wire = try WireFixture(authority: true)
            wire.layout(rows: 46)
            try wire.reachFirstForce()
            try wire.confirm(line)
            wire.layout(rows: 48)
            wire.layout(rows: 46)
            XCTAssertEqual(wire.forces.count, 1, "invalid confirmation must not rearm: \(line)")
        }
    }

    func test_peerAuthorityForbidsOrdinaryHeightRepair() throws {
        let wire = try WireFixture(authority: true)
        wire.stamp("v1 HEIGHT-PEER 3 Android")
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "Android"))
        wire.clearWrites()
        wire.layout(rows: 46)
        XCTAssertTrue(wire.forces.isEmpty)
    }

    func test_backgroundForbidsOrdinaryHeightRepair() throws {
        let wire = try WireFixture(authority: true)
        wire.controller.prepareForAppInactivity()
        wire.layout(rows: 46)
        XCTAssertTrue(wire.forces.isEmpty)
        XCTAssertEqual(wire.controller.windows.first?.layout?.root.rect.height, 46)
    }

    func test_backgroundLinkedWindowDriftDoesNotForceItsPeersGeometry() throws {
        let wire = try WireFixture(authority: true)
        try wire.addFittingBackgroundWindow()
        wire.clearWrites()
        wire.layout(rows: 46, windowID: 6, paneID: 13)

        XCTAssertEqual(wire.controller.activeWindowId, WindowId(5))
        XCTAssertEqual(wire.controller.windows.first(where: { $0.id == WindowId(5) })?.layout?.root.rect.height, 48)
        XCTAssertEqual(wire.controller.windows.first(where: { $0.id == WindowId(6) })?.layout?.root.rect.height, 46)
        XCTAssertTrue(wire.forces.isEmpty, "a background window's peer geometry does not authorize a local repair")
    }

    func test_pendingAndFailedAuthorityQueriesForbidOrdinaryHeightRepair() throws {
        let wire = try WireFixture(authority: true)
        wire.controller.prepareForAppInactivity()
        wire.controller.refreshActiveWindowOnForeground()
        wire.clearWrites()
        wire.layout(rows: 46)
        XCTAssertTrue(wire.forces.isEmpty, "an outstanding authority read does not authorize resizing")
        try wire.reachAuthorityQuery()
        wire.reply(success: false)
        wire.layout(rows: 46)
        XCTAssertTrue(wire.forces.isEmpty, "a failed authority read must stay fail-closed")

        // Our stamp over a 56x46 grid this device never pushed: a stamp-less
        // client sized it (S2'), so the read yields rather than repairing.
        wire.controller.prepareForAppInactivity()
        wire.controller.refreshActiveWindowOnForeground()
        try wire.reachAuthorityQuery()
        wire.authorityValue = "v1 HEIGHT-SELF 10 iPad"
        wire.reply([wire.authorityValue])
        try wire.drain()
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "another device"))
        XCTAssertTrue(wire.forces.isEmpty)
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("refresh-client -C ") })

        // A show takes it back; ordinary repair resumes once the claim settles.
        wire.controller.gridAuthorityShown()
        try wire.reachConfirmation() // fresh read, then the claim's fence
        wire.layout(rows: 48) // the forced window converges before its confirmation
        try wire.drain()
        try wire.completePendingRepaint()
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        wire.clearWrites()
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"],
                       "a settled show claim must restore ordinary repair")
    }

    func test_foregroundReadOverAnEarlierOwnedTransientReplaysInsteadOfYielding() throws {
        let wire = try WireFixture(authority: true)
        // A keyboard animation pushed 56x46, then settled back at 56x48, but
        // the side-channel window froze at the transient (no layout follows).
        wire.controller.updateClientSize(cols: 56, rows: 46)
        try wire.drain()
        wire.layout(rows: 46)
        try wire.drain()
        wire.controller.updateClientSize(cols: 56, rows: 48)
        try wire.drain()
        XCTAssertEqual(wire.controller.windows.first?.layout?.root.rect.height, 46)

        wire.controller.prepareForAppInactivity()
        wire.controller.refreshActiveWindowOnForeground()
        wire.clearWrites()
        try wire.reachAuthorityQuery()
        wire.reply([wire.authorityValue])
        try wire.drain()

        XCTAssertEqual(wire.controller.gridAuthority, .mine,
                       "a grid this device pushed is ours, not a stamp-less client's")
        XCTAssertFalse(wire.controller.gridAuthorityGeometryHeldForTesting,
                       "our stamp over an earlier owned grid releases the local grid")
        // P6: this connection already advertised 56x48. An identical `-C`
        // would only rerun tmux's last size calculation (same stored client
        // sizes, same latest client), so the owned replay sends none.
        XCTAssertFalse(wire.writes.contains("refresh-client -C 56,48"), "\(wire.writes)")
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") },
                       "an owned-geometry replay never rewrites the stamp")
        wire.controller.updateClientSize(cols: 56, rows: 47)
        XCTAssertTrue(wire.writes.contains("refresh-client -C 56,47"),
                      "ordinary owner geometry flows again: \(wire.writes)")
    }

    func test_successfulTakeBackAfterFailedQueryRestoresOrdinaryResize() throws {
        let wire = try WireFixture(authority: true)
        wire.stamp("v1 HEIGHT-PEER 3 Android")
        try wire.drain()
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "Android"))
        wire.controller.prepareForAppInactivity()
        wire.controller.refreshActiveWindowOnForeground()
        try wire.reachAuthorityQuery()
        wire.reply(success: false)

        XCTAssertTrue(wire.controller.reclaimGridAuthority())
        wire.layout(rows: 48)
        try wire.drain()
        try wire.completePendingRepaint()
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        wire.clearWrites()
        wire.controller.updateClientSize(cols: 56, rows: 49)

        XCTAssertTrue(wire.writes.contains("refresh-client -C 56,49"),
                      "a successful user take-back must restore ordinary viewport resizing")
        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 49 -t @5"])
    }

    func test_reconnectAuthorityReplyWhileInactiveIsAppliedButGeometryWaitsForWake() throws {
        let wire = try WireFixture(authority: true)
        wire.resetTransport()
        wire.beginAttach()
        try wire.reachAuthorityQuery()
        wire.controller.prepareForAppInactivity()
        // UIKit's real background notification is distinct from the render
        // gate used by transparent inactive excursions.
        wire.controller.gridAuthorityBackgrounded()
        wire.clearWrites()
        wire.authorityValue = "v1 HEIGHT-SELF 10 iPad"
        wire.reply([wire.authorityValue])
        try wire.drain()

        // The reply is processed while inactive (the stamp is truth), but no
        // geometry leaves the device until it is active again.
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        XCTAssertTrue(wire.forces.isEmpty)
        XCTAssertFalse(wire.writes.contains(where: { $0.hasPrefix("refresh-client -C ") }),
                       "an off-screen reconnect read never sizes the window")
        XCTAssertFalse(wire.writes.contains(where: { $0.hasPrefix("set-option @tessera_authority ") }))

        wire.controller.refreshActiveWindowOnForeground()
        try wire.reachAuthorityQuery()
        wire.reply([wire.authorityValue])
        try wire.drain()
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        wire.clearWrites()
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"])
    }

    func test_oldAttemptConfirmationCannotClearANewerRequestedHeight() throws {
        let wire = try WireFixture(authority: true)
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        try wire.reachConfirmation() // query A is genuinely in flight
        wire.controller.updateClientSize(cols: 56, rows: 49)
        XCTAssertEqual(wire.forces.count, 2)

        try wire.confirm("tessera-window-size\t@5\t56\t48") // older request's exact reply
        wire.layout(rows: 49)
        wire.layout(rows: 46)
        XCTAssertEqual(wire.forces.count, 2, "old confirmation must not clear the newer attempt")

        try wire.confirm("tessera-window-size\t@5\t56\t49")
        wire.clearWrites()
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 49 -t @5"])
    }

    func test_transportResetRetiresPartialConfirmationBeforeSameGeometryReuse() throws {
        let wire = try WireFixture(authority: true)
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        try wire.reachConfirmation()
        // A reply began on the lost SSH side channel. Reset must retire its
        // parser frame and callback before a new attachment's repair exists.
        // The canceled transport never delivers its remaining bytes.
        wire.controller.ingest(Array("%begin 0 991 1\r\ntessera-window-size\t@5\t56\t48\r\n".utf8))
        wire.resetTransport()
        wire.remoteRows = 48
        try wire.attach()
        wire.clearWrites()
        wire.controller.updateClientSize(cols: 56, rows: 48)
        try wire.drain()
        try wire.completePendingRepaint()
        wire.clearWrites()
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        XCTAssertEqual(wire.forces.count, 1)
        try wire.reachConfirmation()
        wire.layout(rows: 48)
        wire.layout(rows: 46)
        XCTAssertEqual(wire.forces.count, 1, "retired confirmation state must not rearm current geometry")
        try wire.confirm("tessera-window-size\t@5\t56\t48")
        wire.clearWrites()
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"],
                       "the actual current response must still complete the pending query")
    }

    func test_failedMutationDoesNotSendAConfirmationOrRearm() throws {
        for failedIndex in 0...2 {
            let wire = try WireFixture(authority: true)
            wire.layout(rows: 46)
            try wire.reachFirstForce()
            XCTAssertEqual(wire.forces.count, 1)
            guard !wire.forces.isEmpty else { return }
            wire.reply(success: failedIndex != 0)
            wire.reply(success: failedIndex != 1)
            wire.reply(success: failedIndex != 2)
            XCTAssertTrue(wire.confirmations.isEmpty,
                          "geometry cannot be confirmed after a failed mutation")
            wire.layout(rows: 48)
            wire.layout(rows: 46)
            XCTAssertEqual(wire.forces.count, 1, "a failed attempt must not loop on notifications")
        }
    }

    func test_failedConfirmationKeepsTheAttemptLatched() throws {
        let wire = try WireFixture(authority: true)
        wire.layout(rows: 46)
        try wire.reachFirstForce()
        try wire.reachConfirmation()
        wire.reply(success: false)
        wire.layout(rows: 48)
        wire.layout(rows: 46)
        XCTAssertEqual(wire.forces.count, 1, "failed confirmation cannot rearm window resizing")
    }

    func test_claimFenceWaitsForPostUnsetConfirmationBeforeRepaint() throws {
        let wire = try WireFixture(authority: true)
        wire.stamp("v1 HEIGHT-PEER 3 Android")
        try wire.drain()
        wire.layout(rows: 46)
        wire.clearWrites()
        let previousRepaints = wire.repaintRequests

        XCTAssertTrue(wire.controller.reclaimGridAuthority())
        wire.layout(rows: 48) // temporary manual size before unset recalculates
        try wire.reachConfirmation() // all three mutation ACKs and the claim fence ACK landed

        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"])
        XCTAssertEqual(wire.repaintRequests, previousRepaints,
                       "matching layout and the no-op fence cannot replace the separate size proof")
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") })
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "Android"))

        wire.reply(["tessera-window-size\t@5\t56\t48"])
        try wire.drain()
        XCTAssertEqual(wire.repaintRequests, previousRepaints + 1,
                       "exact final geometry releases the one authoritative repaint")
        try wire.completePendingRepaint()
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
    }

    func test_postUnsetMismatchCannotRepaintOrCommitDespiteTransientMatchingLayout() throws {
        let wire = try WireFixture(authority: true)
        wire.stamp("v1 HEIGHT-PEER 3 Android")
        try wire.drain()
        wire.layout(rows: 46)
        wire.clearWrites()
        let previousRepaints = wire.repaintRequests

        XCTAssertTrue(wire.controller.reclaimGridAuthority())
        wire.layout(rows: 48)
        try wire.reachConfirmation()
        wire.remoteRows = 46 // the server's post-unset size differs from its temporary layout
        wire.reply(["tessera-window-size\t@5\t56\t46"])
        try wire.drain()
        try wire.completePendingRepaint()

        XCTAssertEqual(wire.repaintRequests, previousRepaints)
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "Android"),
                       "a locally shaped framebuffer cannot prove remote tmux geometry")
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") })
        wire.layout(rows: 46)
        wire.layout(rows: 46)
        try wire.drain()
        // The settle probe proved the window landed at a size the claim
        // never advertised: one re-fence (a second force at the target),
        // whose probe found it lost again, ends the claim (§6.10 rule 4).
        XCTAssertEqual(wire.forces, Array(repeating: "resize-window -x 56 -y 48 -t @5", count: 2),
                       "an unconfirmed claim forces once more at most")
        XCTAssertNil(wire.controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(wire.controller.gridAuthorityPresentation, .veiled(peerName: "Android"))
    }

    func test_malformedClaimConfirmationCannotRepaintOrCommit() throws {
        let wire = try WireFixture(authority: true)
        wire.stamp("v1 HEIGHT-PEER 3 Android")
        try wire.drain()
        wire.layout(rows: 46)
        wire.clearWrites()
        let previousRepaints = wire.repaintRequests

        XCTAssertTrue(wire.controller.reclaimGridAuthority())
        wire.layout(rows: 48)
        // The force's own post-unset read, then the claim's settle probe
        // (§6.10 rule 5): neither proves anything about another window.
        try wire.confirm("tessera-window-size\t@6\t56\t48")
        XCTAssertEqual(wire.repaintRequests, previousRepaints)
        try wire.confirm("tessera-window-size\t@6\t56\t48")
        try wire.drain()
        try wire.completePendingRepaint()

        XCTAssertEqual(wire.repaintRequests, previousRepaints)
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "Android"))
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") })
    }

    func test_geometryChangedDuringRepaintCannotCommitMineFromACachedMatchingLayout() throws {
        let wire = try WireFixture(authority: true)
        wire.stamp("v1 HEIGHT-PEER 3 Android")
        try wire.drain()
        wire.layout(rows: 46)
        wire.clearWrites()
        let previousRepaints = wire.repaintRequests

        XCTAssertTrue(wire.controller.reclaimGridAuthority())
        wire.layout(rows: 48)
        try wire.confirm("tessera-window-size\t@5\t56\t48")
        try wire.drain()
        XCTAssertEqual(wire.repaintRequests, previousRepaints + 1)
        XCTAssertEqual(wire.controller.windows.first?.layout?.root.rect.height, 48)

        // The visible Mosh frame is locally 56x48, but a competing resize has
        // reached tmux before its notification reaches this control channel.
        wire.remoteRows = 46
        try wire.completePendingRepaint()

        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "Android"))
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") },
                       "the final paint receipt needs fresh remote geometry before committing ownership")
    }

    func test_passiveHeightRepairWaitsForFreshAuthorityAndExactOwnClients() throws {
        let wire = try WireFixture(authority: true)
        let previousRepaints = wire.repaintRequests
        wire.layout(rows: 46)

        XCTAssertTrue(wire.forces.isEmpty, "the cached Mine stamp cannot authorize passive geometry")
        try wire.reachAuthorityQuery()
        XCTAssertTrue(wire.forces.isEmpty)
        wire.reply([wire.authorityValue])
        XCTAssertTrue(wire.forces.isEmpty, "fresh Mine still needs physical-window client proof")
        try wire.reachFirstForce()

        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"])
        XCTAssertTrue(wire.writes.contains {
            $0.hasPrefix("list-clients -F ") && $0.contains("#{window_id}\t#{client_name}\t#{client_pid}\t#{client_created}")
        }, "the proof must include clients from linked sessions")
        XCTAssertEqual(wire.repaintRequests, previousRepaints, "passive maintenance is not a competing authority claim")
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") })
    }

    func test_foreignPhysicalWindowClientBlocksRepairBeforeItsStampCommits() throws {
        let wire = try WireFixture(authority: true)
        // The peer has already changed geometry, but its fresh repaint has not
        // committed a new authority stamp. The server still honestly reports ours.
        wire.serverClientRows.append("@5\tpeer-visible\t201\t2001")
        wire.layout(rows: 20)
        try wire.drain()

        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        XCTAssertTrue(wire.forces.isEmpty, "fresh old Mine cannot defeat a peer's pending claim")
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("refresh-client -C ") })
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") })
    }

    func test_sameWidthTwoRowForeignClaimCannotBeMistakenForOwnedDrift() throws {
        let wire = try WireFixture(authority: true)
        wire.serverClientRows.append("@5\tpeer-control\t202\t2002")
        wire.layout(rows: 46) // same 56 columns: width heuristics cannot distinguish the peer
        try wire.drain()
        XCTAssertTrue(wire.forces.isEmpty)
        let admittedQueries = wire.writes.filter { $0.hasPrefix("show-options -qv @tessera_authority") }.count
        XCTAssertEqual(admittedQueries, 1)

        for _ in 0..<3 {
            wire.layout(rows: 46)
            try wire.drain()
        }
        XCTAssertEqual(wire.writes.filter { $0.hasPrefix("show-options -qv @tessera_authority") }.count, admittedQueries,
                       "a denied identical context is latched instead of growing the query FIFO")
        XCTAssertTrue(wire.forces.isEmpty)
    }

    func test_physicalWindowProofIncludesPeerInAnotherLinkedSessionGroup() throws {
        let wire = try WireFixture(authority: true)
        wire.serverClientRows.append("@5\tlinked-group-peer\t203\t2003")
        wire.layout(rows: 46)
        try wire.drain()

        let query = try XCTUnwrap(wire.writes.first { $0.hasPrefix("list-clients ") })
        XCTAssertTrue(query.hasPrefix("list-clients -F "), query)
        XCTAssertFalse(query.contains(" -t "), "session scoping would omit a linked physical-window peer")
        XCTAssertTrue(wire.forces.isEmpty)
    }

    func test_clientsOnOtherPhysicalWindowsDoNotBlockOwnedWindowRepair() throws {
        let wire = try WireFixture(authority: true)
        wire.serverClientRows.append("@6\tother-window-peer\t204\t2004")
        wire.layout(rows: 46)
        try wire.reachFirstForce()

        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 48 -t @5"])
        XCTAssertFalse(wire.forces.contains { $0.hasSuffix("-t @6") })
    }

    func test_unknownOrMalformedPhysicalWindowProofCannotAuthorizeRepair() throws {
        for rows in [
            [],
            ["@5\town-control\t101\t1001"],
            ["@5\town-control\t101\t1001", "@5\town-visible\t0\t1002"],
            ["@5\town-control\t101\t1001", "@5\town-visible\t102\tbad"],
            ["@5\town-control\t101\t1001", "@5\town-visible\t102\t1002\textra"],
            ["@5\town-control\t101\t1001", "5\town-visible\t102\t1002"],
            ["@5\town-control\t101\t1001", "@5\tunknown-client\t205\t2005"],
        ] {
            let wire = try WireFixture(authority: true)
            wire.serverClientRows = rows
            wire.layout(rows: 46)
            try wire.drain()
            XCTAssertTrue(wire.forces.isEmpty, "proof must be positive and exact: \(rows)")
        }
        let aliased = try WireFixture(authority: true)
        aliased.visibleClientIdentity = aliased.controlClientIdentity
        aliased.layout(rows: 46)
        try aliased.drain()
        XCTAssertTrue(aliased.forces.isEmpty, "one tuple cannot prove two distinct Mosh clients")
    }

    func test_freshForeignOrChangedOwnAuthorityCannotAdmitAnOlderDriftContext() throws {
        for value in ["v1 HEIGHT-PEER 7 Android", "v1 HEIGHT-SELF 999 iPad", "malformed", ""] {
            let wire = try WireFixture(authority: true)
            wire.authorityValue = value // no subscription has reached this controller yet
            wire.layout(rows: 46)
            try wire.drain()
            XCTAssertTrue(wire.forces.isEmpty, "a changed fresh election cannot authorize old Mine: \(value)")
            XCTAssertFalse(wire.writes.contains { $0.hasPrefix("refresh-client -C ") })
        }
    }

    func test_multilineOwnClientIdentityRepliesCannotAuthorizePassiveRepair() throws {
        for controlHasExtraLine in [true, false] {
            let wire = try WireFixture(authority: true)
            if controlHasExtraLine {
                wire.controlClientReply = [wire.controlClientIdentity, "unexpected-second-client"]
            } else {
                wire.visibleClientReply = [wire.visibleClientIdentity, "unexpected-second-client"]
            }
            wire.layout(rows: 46)
            try wire.drain()
            XCTAssertTrue(wire.forces.isEmpty,
                          "a valid first tuple does not make a malformed identity reply positive proof")
        }
    }

    func test_nilIdentityDefersPassiveRepairButKeepsExplicitViewportReplay() throws {
        let wire = try WireFixture()
        wire.layout(rows: 46)
        try wire.drain()
        XCTAssertTrue(wire.forces.isEmpty, "passive recovery needs positive device identity proof")
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("show-options -qv @tessera_authority") })

        wire.controller.updateClientSize(cols: 56, rows: 49)
        XCTAssertTrue(wire.writes.contains("refresh-client -C 56,49"))
        XCTAssertEqual(wire.forces, ["resize-window -x 56 -y 49 -t @5"],
                       "an explicit local viewport replay retains its non-authority behavior")
    }

    func test_reconnectQueryCapturedBeforeSessionAssignmentRequeriesAndSettlesCurrentGrid() throws {
        let wire = try WireFixture(authority: true, columns: 50, rows: 20)
        wire.resetTransport()
        wire.remoteColumns = 80
        wire.remoteRows = 24
        wire.beginAttachBeforeSessionChanged()
        try wire.reachAuthorityQuery()
        wire.clearWrites()
        wire.reply(["v1 HEIGHT-SELF 10 iPad"])

        XCTAssertTrue(wire.forces.isEmpty, "the authority reply captured for nil session is stale")
        try wire.reachAuthorityQuery()
        wire.authorityValue = "v1 HEIGHT-SELF 11 iPad"
        wire.reply([wire.authorityValue])
        // The read waits for geometry evidence; the window then reports our
        // own grid, so the read resolves as "ours at our size".
        wire.layout(rows: 20, columns: 50)
        try wire.drain()
        try wire.completePendingRepaint()

        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        XCTAssertEqual(wire.controller.windows.first?.layout?.root.rect.width, 50)
        XCTAssertEqual(wire.controller.windows.first?.layout?.root.rect.height, 20)
        XCTAssertEqual(wire.writes.filter { $0.hasPrefix("refresh-client -C ") }, ["refresh-client -C 50,20"],
                       "C9: reattach advertises this connection's size once, without claiming")
        XCTAssertFalse(wire.writes.contains("select-window"), "a bare advertisement never transfers latest")
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") })
        wire.clearWrites()
        wire.layout(rows: 18, columns: 50)
        try wire.reachFirstForce()
        XCTAssertEqual(wire.forces, ["resize-window -x 50 -y 20 -t @5"],
                       "the retired session query must not leave admission permanently withheld")
    }

    func test_reconnectSessionAssignmentRejectsOldOwnReplyThenYieldsToCurrentPeer() throws {
        let wire = try WireFixture(authority: true, columns: 50, rows: 20)
        wire.resetTransport()
        wire.remoteColumns = 80
        wire.remoteRows = 24
        wire.beginAttachBeforeSessionChanged()
        try wire.reachAuthorityQuery()
        wire.clearWrites()
        wire.reply(["v1 HEIGHT-SELF 10 iPad"])
        try wire.reachAuthorityQuery()
        wire.reply(["v1 HEIGHT-PEER 7 Android"])
        try wire.drain()

        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "Android"))
        XCTAssertTrue(wire.forces.isEmpty)
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("refresh-client -C ") })
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("set-option @tessera_authority ") })
    }
}
