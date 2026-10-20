import XCTest
@testable import TmuxControl

/// A restored control transport can hydrate before its terminal view reports
/// a viewport. Attaching never claims (S2'); a show or tap admitted in that
/// gap must keep its exact intent and generation until the viewport exists,
/// without treating an unsent fence as live work.
@MainActor
final class GridAuthorityDeferredViewportTests: XCTestCase {
    @MainActor
    private final class WireFixture {
        let controller: TmuxController
        let path: TmuxController.ControlPath
        private(set) var writes: [String] = []
        private var outstanding: [String] = []
        private var responseNumber = 2
        private var remoteColumns = 80
        private var remoteRows = 24
        private var repaintGeneration: UInt64?
        private(set) var repaintRequests = 0
        private var authorityValue = ""

        init(path: TmuxController.ControlPath) throws {
            self.path = path
            controller = TmuxController(authorityInitialGeneration: 0, controlPath: path)
            controller.gridAuthorityIdentity = .init(id: "DEFERRED-SELF", displayName: "iPad")
            controller.gridAuthorityAdoptShown()
            controller.feedTerminal = { _ in }
            controller.sendBytes = { [weak self] bytes in
                let commands = String(decoding: bytes, as: UTF8.self)
                    .split(separator: "\n").map(String.init)
                self?.writes.append(contentsOf: commands)
                self?.outstanding.append(contentsOf: commands)
            }
            controller.onGridAuthoritySideChannelRepaintRequired = { [weak self] _, generation in
                self?.repaintRequests += 1
                self?.repaintGeneration = generation
            }
            // Deliberately omit updateClientSize before the real attach frame.
            controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
            controller.ingest(Array(
                "%session-changed $0 deferred-viewport\r\n%begin 0 1 0\r\n%end 0 1 0\r\n".utf8
            ))
            try drain()
            XCTAssertEqual(controller.mode, .tmuxControl)
            XCTAssertEqual(controller.activeWindowId, WindowId(5))
            XCTAssertEqual(controller.windows.first?.layout?.root.rect.width, 80)
            XCTAssertEqual(controller.windows.first?.layout?.root.rect.height, 24)
            XCTAssertFalse(writes.contains { $0.hasPrefix("refresh-client -C ") })
            stamp(generation: 3)
            try drain()
            XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
            clearWrites()
        }

        var geometryReplays: [String] {
            writes.filter { $0.hasPrefix("refresh-client -C ") }
        }

        var authorityWrites: [String] {
            writes.filter { $0.hasPrefix("set-option @tessera_authority ") }
        }

        var geometryMutations: [String] {
            writes.filter {
                $0.hasPrefix("refresh-client -C ")
                    || $0.hasPrefix("resize-window ")
                    || $0.hasPrefix("select-window")
                    || $0.hasPrefix("set-option -w -u ")
                    || $0.hasPrefix("set-option @tessera_authority ")
            }
        }

        func clearWrites() { writes.removeAll() }

        func stamp(generation: Int) {
            authorityValue = "v1 DEFERRED-PEER \(generation) iPhone"
            echoAuthority()
        }

        /// A peer's write the subscription has not reported yet.
        func stampUnreported(generation: Int) {
            authorityValue = "v1 DEFERRED-PEER \(generation) iPhone"
        }

        /// Another client resized the window.
        func resizeRemotely(columns: Int, rows: Int) {
            remoteColumns = columns
            remoteRows = rows
            let value = layoutValue
            controller.ingest(Array("%layout-change @5 \(value) \(value) *\r\n".utf8))
        }

        private func echoAuthority() {
            controller.ingest(Array(
                "%subscription-changed tessera-authority $0 @5 0 %12 : \(authorityValue)\r\n".utf8
            ))
        }

        func publishViewport() {
            controller.updateClientSize(cols: 132, rows: 44)
        }

        func drain() throws {
            var count = 0
            while let command = outstanding.first {
                count += 1
                guard count <= 150 else { throw FixtureError.commandLoop }
                outstanding.removeFirst()
                let changedGeometry = applyRemoteMutation(command)
                let number = responseNumber
                responseNumber += 1
                let body = (["%begin 0 \(number) 1"] + responseLines(command)
                    + ["%end 0 \(number) 1"])
                    .joined(separator: "\r\n") + "\r\n"
                controller.ingest(Array(body.utf8))
                if changedGeometry {
                    let value = layoutValue
                    controller.ingest(Array("%layout-change @5 \(value) \(value) *\r\n".utf8))
                }
                if command.hasPrefix("set-option @tessera_authority '") {
                    authorityValue = String(command.dropFirst("set-option @tessera_authority '".count).dropLast())
                    echoAuthority()
                }
            }
        }

        func finishRepaint() throws {
            if path == .sideChannel {
                let generation = try XCTUnwrap(repaintGeneration, "claim never requested its transport repaint")
                repaintGeneration = nil
                XCTAssertTrue(controller.gridAuthority.isPeer, "the repaint must precede ownership")
                controller.completeGridAuthoritySideChannelRepaint(generation: generation)
                try drain()
            }
        }

        func awaitInlineRepaint() async throws {
            guard path == .inline else { return }
            // A layout capture can precede the select fence. Foreground's
            // replacement waits on the production 20ms queue-poll timer;
            // let that real task run and answer only commands it transmits.
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while controller.gridAuthority.isPeer, ContinuousClock.now < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
                try drain()
            }
        }

        private var layoutValue: String {
            "beef,\(remoteColumns)x\(remoteRows),0,0,12"
        }

        /// Mutate the backend only for actual transmitted, successfully ACKed
        /// commands. Subsequent layout/query replies use that backend state.
        private func applyRemoteMutation(_ command: String) -> Bool {
            let previous = (remoteColumns, remoteRows)
            let fields = command.split(separator: " ").map(String.init)
            if path == .inline, command.hasPrefix("refresh-client -C "),
               let size = fields.last?.split(separator: ","), size.count == 2,
               let columns = Int(size[0]), let rows = Int(size[1]) {
                remoteColumns = columns
                remoteRows = rows
            }
            if command.hasPrefix("resize-window "),
               let x = fields.firstIndex(of: "-x"), x + 1 < fields.count,
               let y = fields.firstIndex(of: "-y"), y + 1 < fields.count,
               let columns = Int(fields[x + 1]), let rows = Int(fields[y + 1]) {
                remoteColumns = columns
                remoteRows = rows
            }
            return previous.0 != remoteColumns || previous.1 != remoteRows
        }

        private func responseLines(_ command: String) -> [String] {
            let value = layoutValue
            if command.hasPrefix("list-windows ") {
                if command.contains("__tessera_windows__") {
                    return ["__tessera_windows__\t@5\t0\t%12\t\(value)\t\(value)\t0\tfixture"]
                }
                return ["@5\t0\t\(value)\t\(value)\t0\tfixture"]
            }
            if command.hasPrefix("list-panes ") {
                let prefix = command.contains("__tessera_panes__") ? "__tessera_panes__\t" : ""
                return ["\(prefix)@5\t%12\t1\t0\t0\t\(remoteColumns)\t\(remoteRows)\tzsh\tpane\thost"]
            }
            if command.contains("__tessera_active_window__") {
                return ["__tessera_active_window__\t@5\t3.4"]
            }
            if command.contains("__tessera_window_details__") {
                return ["__tessera_window_details__\t@5\t0\t%12\t\(value)\t\(value)\t0\tfixture"]
            }
            if command.contains("tessera-window-size") {
                return ["tessera-window-size\t@5\t\(remoteColumns)\t\(remoteRows)"]
            }
            if command.hasPrefix("show-options -qv @tessera_authority") { return [authorityValue] }
            if command.hasPrefix("show-options "), command.contains("@tessera-visible-DEFERRED-SELF") {
                return ["own-visible|102|1002"]
            }
            if command.hasPrefix("show-options "), command.hasSuffix(" window-size") { return ["latest"] }
            if command.hasPrefix("display-message "), command.contains("#{client_name}|#{client_pid}|#{client_created}") {
                return ["own-control|101|1001"]
            }
            if command.hasPrefix("display-message "), command.contains("#{cursor_x}") {
                return [[
                    "%12", "0", "0", "pane", "fixture", "host", "0", "0", "0", String(remoteRows - 1),
                    "1", "0", "0", "0", "1", "0", "0", "0", "0", "0", "0", "0",
                    String(remoteColumns), String(remoteRows),
                ].joined(separator: "\t")]
            }
            if command.hasPrefix("display-message "), command.contains("#{pane_left}") {
                return [["%12", "0", "0", String(remoteColumns), String(remoteRows),
                         "zsh", "pane", "fixture", "host"].joined(separator: "\t")]
            }
            if command.hasPrefix("list-clients ") {
                if command.contains("#{window_id}") {
                    return ["@5\town-control\t101\t1001", "@5\town-visible\t102\t1002", "@5\tpeer\t103\t1003"]
                }
                return ["own-control|101|1001", "own-visible|102|1002", "peer|103|1003"]
            }
            if command.hasPrefix("display-message "), command.contains("#{window_id}") { return ["@5"] }
            if command.hasPrefix("capture-pane ") { return ["fixture visible row"] }
            return []
        }

        private enum FixtureError: Error { case commandLoop }
    }

    func test_inlineShowBeforeViewportStartsOneClaimOnTheLateViewport() async throws {
        try await exerciseShowBeforeViewport(path: .inline)
    }

    func test_sideChannelShowBeforeViewportStartsOneClaimOnTheLateViewport() async throws {
        try await exerciseShowBeforeViewport(path: .sideChannel)
    }

    private func exerciseShowBeforeViewport(path: TmuxController.ControlPath) async throws {
        let wire = try WireFixture(path: path)
        defer { wire.controller.reset() }
        wire.controller.gridAuthorityShown()
        XCTAssertTrue(wire.writes.contains("show-options -qv @tessera_authority"),
                      "a show always sends its own fresh read")
        try wire.drain()
        XCTAssertTrue(wire.geometryMutations.isEmpty, "no viewport means no geometry can be sent")
        XCTAssertEqual(wire.controller.gridAuthorityPresentation, .resuming(awaitingConnection: false),
                       "a show over a peer resumes; it never flashes the veil")
        wire.publishViewport()
        XCTAssertEqual(wire.geometryReplays, ["refresh-client -C 132,44"],
                       "the show's claim was admitted before geometry and still owns this intent")
        guard !wire.geometryReplays.isEmpty else { return }
        let firstWrites = wire.writes
        for _ in 0..<8 { _ = wire.controller.reclaimGridAuthority() }
        XCTAssertEqual(wire.writes, firstWrites, "taps during the show's claim keep one admitted wire claim")
        try wire.drain()
        try wire.finishRepaint()
        try await wire.awaitInlineRepaint()
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        XCTAssertFalse(wire.controller.gridAuthorityReclaimInFlight)
        XCTAssertEqual(wire.controller.gridAuthorityPresentation, .none)
        XCTAssertEqual(wire.geometryReplays, ["refresh-client -C 132,44"])
        XCTAssertEqual(wire.authorityWrites.count, 1, "deferred admission must not invent a retry")
        XCTAssertTrue(wire.authorityWrites.first?.contains("DEFERRED-SELF") == true)
        if path == .sideChannel { XCTAssertEqual(wire.repaintRequests, 1) }
    }

    func test_inlineLateViewportWithoutAShowStaysYielded() throws {
        try exerciseLateViewportWithoutShow(path: .inline)
    }

    func test_sideChannelLateViewportWithoutAShowStaysYielded() throws {
        try exerciseLateViewportWithoutShow(path: .sideChannel)
    }

    private func exerciseLateViewportWithoutShow(path: TmuxController.ControlPath) throws {
        let wire = try WireFixture(path: path)
        defer { wire.controller.reset() }
        wire.publishViewport()
        try wire.drain()
        XCTAssertTrue(wire.geometryMutations.isEmpty,
                      "a measured viewport is not a show: a yielded device sends no geometry")
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertEqual(wire.controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertEqual(wire.repaintRequests, 0)
    }

    func test_inlineTakeBackAfterLateViewportCompletesItsRealWireClaim() async throws {
        try await exerciseTakeBackAfterLateViewport(path: .inline)
    }

    func test_sideChannelTakeBackAfterLateViewportCompletesItsRealWireClaim() async throws {
        try await exerciseTakeBackAfterLateViewport(path: .sideChannel)
    }

    /// This is the recorded user order. It also runs against the pre-coalescing
    /// public API: an already reported viewport must leave take-back actionable.
    private func exerciseTakeBackAfterLateViewport(path: TmuxController.ControlPath) async throws {
        let wire = try WireFixture(path: path)
        defer { wire.controller.reset() }
        wire.publishViewport()
        XCTAssertTrue(wire.controller.reclaimGridAuthority())
        XCTAssertEqual(wire.geometryReplays, ["refresh-client -C 132,44"],
                       "a visible claim must have a real admitted wire chain once its viewport exists")
        guard !wire.geometryReplays.isEmpty else { return }
        try wire.drain()
        try wire.finishRepaint()
        try await wire.awaitInlineRepaint()
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        XCTAssertFalse(wire.controller.gridAuthorityReclaimInFlight)
        XCTAssertEqual(wire.authorityWrites.count, 1)
    }

    /// A passive maintenance read sees the stamp as a subscription edge
    /// would, and the session reduces it as one: a peer's write that the
    /// subscription has not reported yet is that peer's verdict at once, not
    /// a window to prove ours and force back.
    func test_aPassiveReadHandsAPeersStampToTheSession() async throws {
        let wire = try WireFixture(path: .sideChannel)
        defer { wire.controller.reset() }
        wire.publishViewport()
        XCTAssertTrue(wire.controller.reclaimGridAuthority())
        try wire.drain()
        try wire.finishRepaint()
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        wire.clearWrites()
        wire.stampUnreported(generation: 9)
        wire.resizeRemotely(columns: 100, rows: 30)
        try wire.drain()
        XCTAssertTrue(wire.writes.contains("show-options -qv @tessera_authority"), "no passive read: \(wire.writes)")
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertFalse(wire.writes.contains { $0.hasPrefix("list-clients ") || $0.hasPrefix("resize-window ") },
                       "\(wire.writes)")
    }

    func test_inlineTapBeforeViewportReplaysAfterItsDeadlineAndSettles() async throws {
        try await exerciseTapBeforeViewportPastItsDeadline(path: .inline)
    }

    func test_sideChannelTapBeforeViewportReplaysAfterItsDeadlineAndSettles() async throws {
        try await exerciseTapBeforeViewportPastItsDeadline(path: .sideChannel)
    }

    /// The original unmeasured claim stalls at the presentation deadline.
    /// C6 replays its tap while the surface is paintable and the same peer
    /// still holds the grid; its late measurement admits that new generation.
    private func exerciseTapBeforeViewportPastItsDeadline(path: TmuxController.ControlPath) async throws {
        let wire = try WireFixture(path: path)
        defer { wire.controller.reset() }
        XCTAssertTrue(wire.controller.reclaimGridAuthority())
        let first = try XCTUnwrap(wire.controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertTrue(wire.controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(wire.geometryMutations.isEmpty, "no viewport means no geometry can be sent")
        try await Task.sleep(nanoseconds: 3_250_000_000)
        let second = try XCTUnwrap(wire.controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertGreaterThan(second.generation, first.generation, "the first stalled generation ended")
        XCTAssertEqual(second.reason, .userTakeBack)
        XCTAssertEqual(wire.controller.gridAuthoritySessionForTesting.replay.count, 1)
        XCTAssertTrue(wire.controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(wire.controller.gridAuthority.isPeer)
        XCTAssertTrue(wire.geometryMutations.isEmpty, "replay still waits for a measurement")
        XCTAssertTrue(wire.authorityWrites.isEmpty, "replay cannot stamp before paint")

        wire.publishViewport()
        XCTAssertEqual(wire.geometryReplays, ["refresh-client -C 132,44"])
        try wire.drain()
        try wire.finishRepaint()
        try await wire.awaitInlineRepaint()
        XCTAssertEqual(wire.controller.gridAuthority, .mine)
        XCTAssertFalse(wire.controller.gridAuthorityReclaimInFlight)
        XCTAssertEqual(wire.controller.gridAuthorityPresentation, .none)
        XCTAssertEqual(wire.authorityWrites.count, 1, "\(wire.authorityWrites)")
        XCTAssertTrue(wire.authorityWrites.first?.contains("DEFERRED-SELF") == true)
    }

    func test_inlineContestedShowClaimDoesNotResumeOnALateViewport() throws {
        try exerciseContestedClaim(path: .inline)
    }

    func test_sideChannelContestedShowClaimDoesNotResumeOnALateViewport() throws {
        try exerciseContestedClaim(path: .sideChannel)
    }

    private func exerciseContestedClaim(path: TmuxController.ControlPath) throws {
        let wire = try WireFixture(path: path)
        defer { wire.controller.reset() }
        wire.controller.gridAuthorityShown()
        try wire.drain() // the read finds iPhone g3; the claim waits for a viewport
        wire.stamp(generation: 4)
        try wire.drain()
        wire.clearWrites()
        wire.publishViewport()
        try wire.drain()
        XCTAssertTrue(wire.geometryMutations.isEmpty,
                      "a newer foreign stamp aborted the deferred show claim")
        XCTAssertEqual(wire.controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertFalse(wire.controller.gridAuthorityReclaimInFlight)
        XCTAssertEqual(wire.controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertEqual(wire.repaintRequests, 0)
    }
}
