import XCTest
@testable import TmuxControl

/// Continuity-takeover grid authority: stamp writes, subscription-driven
/// yield transitions, the show rule (control moves only on a show edge or a
/// veil gesture), the geometry hold until authority is known, the yielded
/// size gate, and the stamp-less layout fallback.
@MainActor
final class GridAuthorityTests: XCTestCase {
    private struct FixtureGrid: Equatable {
        let columns: Int
        let rows: Int
    }

    @MainActor
    private final class RemoteGridFixture {
        var grids: [WindowId: FixtureGrid] = [:]
        var observed: [WindowId: FixtureGrid] = [:]
        var layouts: [WindowId: WindowLayout] = [:]
        var activeWindowID: WindowId?
        /// The `@tessera_authority` value tmux holds: the body of an explicit
        /// `show-options -qv @tessera_authority` read.
        var authorityStamp = ""
        var ownerScopeReply = ["$42 group"]
        var ownScopeReply = ["$0 group"]
        /// The owner session was killed: an owner read's loop finds nothing.
        var ownerKilled = false
        /// The windows' effective `window-size` option (empty = `latest`).
        var windowSizePolicy = ""
        /// The size this client last advertised with `refresh-client -C`.
        var clientSize: FixtureGrid?
        /// False while another client keeps `latest` (a laptop typing): our
        /// fence then resizes nothing.
        var fenceTakesLatest = true
        var foreignClientWindows: Set<WindowId> = []
        private var ownLatestWindows = Set<WindowId>()
        private var manualWindows = Set<WindowId>()
        private var beforeManual: [WindowId: FixtureGrid] = [:]

        /// Every byte the controller writes passes here first, so the
        /// fixture knows the client size tmux holds for it.
        func noteSent(_ bytes: [UInt8]) {
            for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: " ").map(String.init)
                guard fields.first == "refresh-client", let flag = fields.firstIndex(of: "-C"),
                      flag + 1 < fields.count
                else { continue }
                let size = fields[flag + 1].split(separator: ",").compactMap { Int($0) }
                if size.count == 2 { clientSize = FixtureGrid(columns: size[0], rows: size[1]) }
            }
        }

        func observe(_ controller: TmuxController) {
            activeWindowID = controller.activeWindowId ?? activeWindowID
            for window in controller.windows {
                guard let rect = window.layout?.root.rect else { continue }
                let grid = FixtureGrid(columns: rect.width, rows: rect.height)
                if observed[window.id] != grid {
                    grids[window.id] = grid
                    // A foreign layout is a peer taking latest. The next
                    // successful targetless fence must transfer it back.
                    if clientSize != grid { ownLatestWindows.remove(window.id) }
                }
                observed[window.id] = grid
                layouts[window.id] = window.layout
            }
        }

        func acknowledge(_ command: String?) -> [String] {
            guard let command else { return [] }
            if command.contains("#{session_id} #{session_group}") {
                return command.contains("-t ") ? ownerScopeReply : ownScopeReply
            }
            if command.hasPrefix("show-options -qv"), command.hasSuffix(TmuxController.gridAuthorityOption) {
                return authorityStamp.isEmpty ? [] : [authorityStamp]
            }
            if command.contains("#{session_id}|#{\(TmuxController.gridAuthorityOption)}"),
               let start = command.range(of: "#{session_id},")?.upperBound,
               let end = command[start...].firstIndex(of: "}") {
                return ownerKilled ? [""] : ["\(command[start..<end])|\(authorityStamp)"]
            }
            if command.hasPrefix("display-message "), command.contains("#{client_name}|#{client_pid}|#{client_created}") {
                return ["own-control|101|1001"]
            }
            if command.hasPrefix("show-options "), command.contains("@tessera-visible-") {
                return ["own-visible|102|1002"]
            }
            if command.hasPrefix("list-clients "), let windowID = activeWindowID {
                return ["\(windowID)\town-control\t101\t1001", "\(windowID)\town-visible\t102\t1002"] +
                    foreignClientWindows.map { "\($0)\tlaptop\t201\t2001" }
            }
            if command.hasPrefix("list-windows ") {
                return grids.keys.sorted { $0.rawValue < $1.rawValue }.map { windowID in
                    let layout = layoutString(windowID)
                    let prefix = command.contains("__tessera_windows__") ? "__tessera_windows__\t" : ""
                    let activePane = command.contains("__tessera_windows__") ? "%\(paneNumber(windowID))\t" : ""
                    return "\(prefix)\(windowID)\t\(windowID.rawValue)\t\(activePane)\(layout)\t\(layout)\t0\tfixture"
                }
            }
            if command.hasPrefix("list-panes ") {
                return grids.keys.sorted { $0.rawValue < $1.rawValue }.flatMap { windowID -> [String] in
                    guard let grid = grids[windowID] else { return [] }
                    let prefix = command.contains("__tessera_panes__") ? "__tessera_panes__\t" : ""
                    return ["\(prefix)\(windowID)\t%\(paneNumber(windowID))\t1\t0\t0\t\(grid.columns)\t\(grid.rows)\tzsh\tpane\thost"]
                }
            }
            if command.contains("__tessera_active_window__"), let windowID = activeWindowID ?? grids.keys.first {
                return ["__tessera_active_window__\t\(windowID)\t3.4"]
            }
            if command.hasPrefix("show-options -wA -v -t "), command.hasSuffix(" window-size") {
                return windowSizePolicy.isEmpty ? [] : [windowSizePolicy]
            }
            let fields = command.split(separator: " ").map(String.init)
            // tmux under `window-size latest`: the fence makes this client
            // the latest, so the current window takes its advertised size.
            // The notification reaches the controller only when a test
            // delivers it.
            if fields == [TmuxClientSizeReplay.latestFenceCommand], let windowID = activeWindowID {
                if fenceTakesLatest { ownLatestWindows.insert(windowID) }
                // cmd_select_window_exec sets latest, but resize-window's
                // manual override still governs until cmd_set_option_exec
                // unsets it. This mirrors the source-traced model's D2 rule.
                if fenceTakesLatest, !manualWindows.contains(windowID),
                   windowSizePolicy.isEmpty || windowSizePolicy == "latest", let size = clientSize {
                    grids[windowID] = size
                }
                return []
            }
            guard let targetIndex = fields.firstIndex(of: "-t"), targetIndex + 1 < fields.count,
                  fields[targetIndex + 1].first == "@",
                  let windowNumber = Int(fields[targetIndex + 1].dropFirst())
            else { return [] }
            let windowID = WindowId(windowNumber)
            if command.contains("__tessera_window_details__"), grids[windowID] != nil {
                let layout = layoutString(windowID)
                return ["__tessera_window_details__\t\(windowID)\t\(windowID.rawValue)\t%\(paneNumber(windowID))\t\(layout)\t\(layout)\t0\tfixture"]
            }
            if fields.first == "resize-window",
               let columnsIndex = fields.firstIndex(of: "-x"), columnsIndex + 1 < fields.count,
               let rowsIndex = fields.firstIndex(of: "-y"), rowsIndex + 1 < fields.count,
               let columns = Int(fields[columnsIndex + 1]), let rows = Int(fields[rowsIndex + 1]) {
                // A successful remote mutation changes the fixture backend.
                // Its layout notification may reach the controller later.
                beforeManual[windowID] = grids[windowID]
                manualWindows.insert(windowID)
                grids[windowID] = FixtureGrid(columns: columns, rows: rows)
            }
            if fields.first == "set-option", fields.contains("-u"), fields.last == "window-size" {
                manualWindows.remove(windowID)
                if windowSizePolicy.isEmpty || windowSizePolicy == "latest" {
                    // Unset recalculates from latest, never from the temporary
                    // manual grid. Without the fence this returns to the peer.
                    grids[windowID] = ownLatestWindows.contains(windowID) && fenceTakesLatest
                        ? clientSize : beforeManual[windowID]
                }
                beforeManual.removeValue(forKey: windowID)
            }
            if command.contains("tessera-window-size"), let grid = grids[windowID] {
                return ["tessera-window-size\t\(windowID)\t\(grid.columns)\t\(grid.rows)"]
            }
            return []
        }

        private func paneNumber(_ windowID: WindowId) -> Int {
            layouts[windowID]?.paneIds.first?.rawValue ?? windowID.rawValue
        }

        private func layoutString(_ windowID: WindowId) -> String {
            guard let grid = grids[windowID] else { return "" }
            if let layout = layouts[windowID], layout.root.rect.width == grid.columns,
               layout.root.rect.height == grid.rows {
                return "beef," + cellString(layout.root)
            }
            return "beef,\(grid.columns)x\(grid.rows),0,0,\(paneNumber(windowID))"
        }

        private func cellString(_ node: LayoutNode) -> String {
            let rect = node.rect
            let geometry = "\(rect.width)x\(rect.height),\(rect.x),\(rect.y)"
            switch node {
            case .leaf(let paneID, _): return geometry + ",\(paneID.rawValue)"
            case .split(let axis, _, let children):
                let open = axis == .horizontal ? "{" : "["
                let close = axis == .horizontal ? "}" : "]"
                return geometry + open + children.map(cellString).joined(separator: ",") + close
            }
        }
    }

    private var remoteGridFixtures: [ObjectIdentifier: RemoteGridFixture] = [:]

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
    /// Another client's grid: what the window has when this device attaches
    /// to a session somebody else sized.
    private static let peerGrid = FixtureGrid(columns: 105, rows: 31)
    private static let handshake = "%begin 100 1 0\r\n%end 100 1 0\r\n"
    private static let authorityRead = "show-options -qv \(TmuxController.gridAuthorityOption)"
    private static let ownerRead = TmuxGridAuthority.queryCommand(.owner(SessionId(42)))

    /// The authority feed in `scope`, registered against whichever pane
    /// carries the session feeds.
    private static func containsAuthorityFeed(_ wire: String, _ scope: TmuxGridAuthorityScope) -> Bool {
        let format = NSRegularExpression.escapedPattern(for: TmuxGridAuthority.subscriptionFormat(scope))
        return wire.range(of: "'tessera-authority:@[0-9]+:\(format)'", options: .regularExpression) != nil
    }
    private func selfValue(gen: Int = 1) -> String {
        "v1 \(Self.selfID) \(gen) iPad"
    }

    /// A controller whose control channel attached and whose attach-time
    /// authority read already resolved: `remoteStamp` is what the read
    /// returned (empty = unstamped session) and `remoteGrid` the window's
    /// size at attach. No show edge has happened, so nothing claimed.
    private func makeController(
        path: TmuxController.ControlPath = .sideChannel,
        policy: TmuxController.ClientSizePolicy = .resizeTmux,
        identity: TmuxController.GridAuthorityIdentity? =
            .init(id: "SELF-DEVICE-1234", displayName: "iPad"),
        localCols: Int = 92,
        localRows: Int = 38,
        remoteStamp: String = "",
        remoteGrid: FixtureGrid? = nil,
        attach: Bool = true,
        authorityConfiguration: TmuxGridAuthoritySession.Configuration = .init(),
        authorityNow: (() -> Int64)? = nil,
        ownerName: String? = nil
    ) -> (controller: TmuxController, sent: ByteSink) {
        let sent = ByteSink()
        let controller = TmuxController(authorityInitialGeneration: 0,
            controlPath: path,
            clientSizePolicy: policy,
            authorityConfiguration: authorityConfiguration,
            authorityNow: authorityNow
        )
        let fixture = RemoteGridFixture()
        controller.feedTerminal = { _ in }
        controller.sendBytes = { sent.append($0); fixture.noteSent($0) }
        controller.gridAuthorityOwnerSessionName = ownerName
        controller.gridAuthorityIdentity = identity
        controller.gridAuthorityAdoptShown()
        controller.updateClientSize(cols: localCols, rows: localRows)

        fixture.grids[WindowId(0)] = remoteGrid ?? Self.peerGrid
        fixture.activeWindowID = WindowId(0)
        fixture.authorityStamp = remoteStamp
        remoteGridFixtures[ObjectIdentifier(controller)] = fixture

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array(
            "%session-changed $0 dev\r\n%window-add @0\r\n".utf8
        ))
        if attach {
            controller.ingest(Array(Self.handshake.utf8))
            ackAllPending(controller, frames: 40)
        }
        sent.clear()
        return (controller, sent)
    }

    /// Attached, and the read found this device's own stamp over a window at
    /// the local grid: the steady owner. Ordinary geometry flows.
    private func makeOwnerController(
        path: TmuxController.ControlPath = .sideChannel,
        localCols: Int = 92,
        localRows: Int = 38
    ) -> (controller: TmuxController, sent: ByteSink) {
        let made = makeController(
            path: path,
            localCols: localCols,
            localRows: localRows,
            remoteStamp: selfValue(),
            remoteGrid: FixtureGrid(columns: localCols, rows: localRows)
        )
        XCTAssertEqual(made.controller.gridAuthority, .mine)
        XCTAssertFalse(made.controller.gridAuthorityGeometryHeldForTesting)
        // This fixture represents a steady owner, after attach's size echo.
        made.controller.advanceGridAuthorityClockForTesting(by: TmuxStamplessPeer.replaySuppressionMillis + 1_000)
        return made
    }

    private func fixture(_ controller: TmuxController) -> RemoteGridFixture {
        let identity = ObjectIdentifier(controller)
        let fixture = remoteGridFixtures[identity] ?? RemoteGridFixture()
        remoteGridFixtures[identity] = fixture
        return fixture
    }

    private func deliverStamp(_ controller: TmuxController, value: String) {
        controller.ingest(Array(
            "%subscription-changed tessera-authority $0 @0 0 %0 : \(value)\r\n".utf8
        ))
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func assertNoGeometryOrStamp(
        _ wire: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(wire.contains("refresh-client -C"), "\(message): \(wire)", file: file, line: line)
        XCTAssertFalse(wire.contains("resize-window"), "\(message): \(wire)", file: file, line: line)
        XCTAssertFalse(wire.contains("select-window"), "\(message): \(wire)", file: file, line: line)
        XCTAssertFalse(
            wire.contains("set-option \(TmuxController.gridAuthorityOption)"),
            "\(message): \(wire)",
            file: file,
            line: line
        )
    }

    private func assertNoWindowForce(_ wire: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(wire.contains("resize-window"), wire, file: file, line: line)
        XCTAssertFalse(wire.split(separator: "\n").contains("select-window"), wire, file: file, line: line)
        XCTAssertFalse(wire.contains("set-option -w -u"), wire, file: file, line: line)
    }

    func test_backgroundNewWindowWithForeignClientNeverForcesFromDiscovery() {
        let (controller, sent) = makeOwnerController()
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        fixture(controller).foreignClientWindows.insert(WindowId(1))
        controller.ingest(Array("%window-add @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        XCTAssertEqual(controller.activeWindowId, WindowId(0))
        XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(1) })?.layout?.root.rect.width, 80)
        assertNoWindowForce(sent.string)
    }

    func test_presentingKnownNewWindowRepairsWithoutLayoutNotificationThroughPassiveProof() throws {
        let (controller, sent) = makeOwnerController()
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        sent.clear()
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        assertNoWindowForce(sent.string) // cached Mine and layout are insufficient
        ackAllPending(controller, frames: 80)
        let wire = sent.string
        let authority = try XCTUnwrap(wire.range(of: Self.authorityRead))
        let clients = try XCTUnwrap(wire.range(of: "list-clients -F "))
        let force = try XCTUnwrap(wire.range(of: "resize-window -x 92 -y 38 -t @1"))
        XCTAssertLessThan(authority.lowerBound, clients.lowerBound)
        XCTAssertLessThan(clients.lowerBound, force.lowerBound)
        XCTAssertEqual(count("resize-window", in: wire), 1, wire)
        XCTAssertTrue(wire.contains("set-option -w -u -t @1 window-size"), wire)
        XCTAssertEqual(fixture(controller).grids[WindowId(1)], FixtureGrid(columns: 92, rows: 38))
        sent.clear()
        controller.ingest(Array("%window-add @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        assertNoWindowForce(sent.string)
    }

    func test_secondPresentedNewWindowGetsFreshProofAfterFirstPassiveRepair() {
        let (controller, sent) = makeOwnerController()
        for id in 1...2 {
            fixture(controller).grids[WindowId(id)] = FixtureGrid(columns: 80, rows: 24)
            controller.ingest(Array("%window-add @\(id)\r\n".utf8))
            ackAllPending(controller, frames: 80)
            sent.clear()
            controller.ingest(Array("%session-window-changed $0 @\(id)\r\n".utf8))
            ackAllPending(controller, frames: 80)
            XCTAssertTrue(sent.string.contains("list-clients -F "), sent.string)
            XCTAssertEqual(count("resize-window -x 92 -y 38 -t @\(id)", in: sent.string), 1, sent.string)
        }
    }

    func test_foreignClientOnPresentedNewWindowBlocksPassiveRepair() {
        let (controller, sent) = makeOwnerController()
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        fixture(controller).foreignClientWindows.insert(WindowId(1))
        controller.ingest(Array("%window-add @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        sent.clear()
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        XCTAssertTrue(sent.string.contains("list-clients -F "), sent.string)
        assertNoWindowForce(sent.string)
    }

    func test_presentedNewWindowWaitsForDetailsBeforePassiveProofAndForce() {
        let (controller, sent) = makeOwnerController()
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        controller.ingest(Array("%session-window-changed $0 @1\r\n%window-add @1\r\n".utf8))
        XCTAssertNil(controller.windows.first(where: { $0.id == WindowId(1) })?.layout)
        assertNoWindowForce(sent.string)
        XCTAssertFalse(sent.string.contains("list-clients"), sent.string)
        // A real layout can beat the queued details reply. Keep waiting for
        // that reply even though the model now has geometry.
        controller.ingest(Array("%layout-change @1 beef,80x24,0,0,1 beef,80x24,0,0,1 *\r\n".utf8))
        assertNoWindowForce(sent.string)
        ackAllPending(controller, frames: 80)
        XCTAssertNotNil(controller.windows.first(where: { $0.id == WindowId(1) })?.layout)
        XCTAssertTrue(sent.string.contains("list-clients -F "), sent.string)
        XCTAssertEqual(count("resize-window -x 92 -y 38 -t @1", in: sent.string), 1, sent.string)
    }

    func test_mismatchedPassiveNewWindowConfirmationDoesNotBlockLaterPresentedDriftRepair() {
        // Keep the ordinary echo window open, as after real local size
        // churn, so a failed force does not independently imply a peer.
        let (controller, sent) = makeController(remoteStamp: selfValue(),
            remoteGrid: FixtureGrid(columns: 92, rows: 38))
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        fixture(controller).fenceTakesLatest = false // unset snaps back; confirmation mismatches
        sent.clear()
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        for _ in 0..<80 {
            if controller._debugPendingCommands.first?.contains("tessera-window-size") == true { break }
            ackAllPending(controller, frames: 1)
        }
        XCTAssertTrue(controller._debugPendingCommands.first?.contains("tessera-window-size") == true)
        // A geometry echo invalidates the proof context before the force's
        // mismatching confirmation; its completion must still retire the attempt.
        controller.ingest(Array("%layout-change @1 beef,92x36,0,0,1 beef,92x36,0,0,1 *\r\n".utf8))
        ackAllPending(controller, frames: 80)
        XCTAssertEqual(count("resize-window -x 92 -y 38 -t @1", in: sent.string), 1, sent.string)
        XCTAssertEqual(controller.gridAuthority, .mine)
        fixture(controller).fenceTakesLatest = true
        sent.clear()
        controller.ingest(Array("%layout-change @1 beef,92x37,0,0,1 beef,92x37,0,0,1 *\r\n".utf8))
        ackAllPending(controller, frames: 80)
        XCTAssertTrue(sent.string.contains("list-clients -F "), sent.string)
        XCTAssertEqual(count("resize-window -x 92 -y 38 -t @1", in: sent.string), 1, sent.string)
        XCTAssertEqual(fixture(controller).grids[WindowId(1)], FixtureGrid(columns: 92, rows: 38))
    }

    func test_newWindowAddDoesNotForceAdvertiseOnlyPeerHiddenOrUnresolved() {
        let unstamped = makeController()
        XCTAssertEqual(unstamped.controller.gridAuthorityGeometryHold, .advertiseOnly)
        let peer = makeController(remoteStamp: Self.peerValue)
        let hidden = makeOwnerController()
        hidden.controller.gridAuthorityHidden()
        let inactive = makeOwnerController()
        inactive.controller.prepareForAppInactivity()
        let unresolved = makeController(attach: false)
        for (controller, sent) in [unstamped, peer, hidden, inactive, unresolved] {
            fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
            controller.ingest(Array("%window-add @1\r\n".utf8))
            ackAllPending(controller, frames: 80)
            sent.clear()
            controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
            ackAllPending(controller, frames: 80)
            assertNoWindowForce(sent.string)
        }
    }

    func test_newWindowAddDoesNotJoinAnExistingClaimFence() {
        let (controller, sent) = makeController(remoteStamp: Self.peerValue)
        XCTAssertTrue(controller.reclaimGridAuthority())
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        sent.clear()
        controller.ingest(Array("%window-add @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(1) })?.layout?.root.rect.width, 80)
        XCTAssertFalse(sent.string.contains("resize-window -x 92 -y 38 -t @1"), sent.string)
        XCTAssertFalse(sent.string.contains("set-option -w -u -t @1 window-size"), sent.string)
    }

    func test_newWindowAddOnInlinePathDoesNotForce() {
        let (controller, sent) = makeOwnerController(path: .inline)
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        controller.ingest(Array("%session-window-changed $0 @1\r\n%window-add @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        XCTAssertEqual(controller.windows.first(where: { $0.id == WindowId(1) })?.layout?.root.rect.width, 80)
        assertNoWindowForce(sent.string)
    }

    private func switchDuringPassiveProof(to grid: FixtureGrid) -> (TmuxController, ByteSink) {
        let (controller, sent) = makeOwnerController()
        fixture(controller).grids[WindowId(1)] = grid
        fixture(controller).grids[WindowId(2)] = FixtureGrid(columns: 92, rows: 38)
        controller.ingest(Array("%window-add @1\r\n%window-add @2\r\n".utf8))
        ackAllPending(controller, frames: 80)
        controller.ingest(Array("%session-window-changed $0 @2\r\n".utf8))
        ackAllPending(controller, frames: 80)
        // Discover the outside-sized grid while it is in the background.
        controller.ingest(Array("%layout-change @0 beef,80x24,0,0,0 beef,80x24,0,0,0 *\r\n".utf8))
        ackAllPending(controller, frames: 80)
        controller.ingest(Array("%session-window-changed $0 @0\r\n".utf8))
        for _ in 0..<80 {
            if controller._debugPendingCommands.first == Self.authorityRead { break }
            ackAllPending(controller, frames: 1)
        }
        XCTAssertTrue(controller.gridAuthoritySessionForTesting.ordinaryRecoveryActive)
        XCTAssertEqual(controller._debugPendingCommands.first, Self.authorityRead)
        sent.clear()
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        XCTAssertEqual(controller.gridAuthority, .mine)
        ackAllPending(controller, frames: 100)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
        XCTAssertFalse(controller.gridAuthoritySessionForTesting.ordinaryRecoveryActive)
        return (controller, sent)
    }

    func test_switchDuringPassiveProofToLocalWindowDoesNotVeilOrForce() {
        let (_, sent) = switchDuringPassiveProof(to: FixtureGrid(columns: 92, rows: 38))
        assertNoWindowForce(sent.string)
    }

    func test_switchDuringPassiveProofToForeignWindowProvesAndRepairsNewWindow() {
        let (controller, sent) = switchDuringPassiveProof(to: FixtureGrid(columns: 80, rows: 24))
        XCTAssertTrue(sent.string.contains("list-clients -F "), sent.string)
        XCTAssertEqual(count("resize-window -x 92 -y 38 -t @1", in: sent.string), 1, sent.string)
        XCTAssertFalse(sent.string.contains("resize-window -x 92 -y 38 -t @0"), sent.string)
        XCTAssertEqual(fixture(controller).grids[WindowId(1)], FixtureGrid(columns: 92, rows: 38))
    }

    private func assertPresentedNonLatestNeverForces(_ policy: String) {
        let (controller, sent) = makeOwnerController()
        fixture(controller).windowSizePolicy = policy
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        ackAllPending(controller, frames: 80)
        for _ in 0..<3 {
            sent.clear()
            controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
            ackAllPending(controller, frames: 80)
            assertNoWindowForce(sent.string)
            XCTAssertEqual(controller.gridAuthority, .mine)
            XCTAssertEqual(controller.gridAuthorityPresentation, .none)
            XCTAssertFalse(controller.gridAuthoritySessionForTesting.ordinaryRecoveryActive)
            XCTAssertEqual(fixture(controller).grids[WindowId(1)], FixtureGrid(columns: 80, rows: 24))
            controller.ingest(Array("%session-window-changed $0 @0\r\n".utf8))
            ackAllPending(controller, frames: 80)
        }
    }

    func test_presentedSmallestWindowNeverForcesAcrossRepeatedVisits() {
        assertPresentedNonLatestNeverForces("smallest")
    }

    func test_presentedManualWindowNeverForcesAcrossRepeatedVisits() {
        assertPresentedNonLatestNeverForces("manual")
    }

    func test_presentedRecoveryWaitsForAuthorityReadAndItsHoldBound() {
        let (controller, sent) = makeOwnerController()
        fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 80, rows: 24)
        controller.ingest(Array("%session-window-changed $0 @1\r\n%window-add @1\r\n".utf8))
        XCTAssertTrue(controller.gridAuthoritySessionForTesting.ordinaryRecoveryActive)
        controller.rereadGridAuthorityForTesting()
        XCTAssertNotNil(controller.gridAuthoritySessionForTesting.query.current)
        sent.clear()
        XCTAssertTrue(controller.gridAuthoritySessionForTesting.ordinaryRecoveryActive)
        XCTAssertEqual(controller.gridAuthority, .mine)
        ackAllPending(controller, frames: 80)
        XCTAssertNotNil(controller.gridAuthoritySessionForTesting.query.held)
        XCTAssertTrue(controller.gridAuthoritySessionForTesting.ordinaryRecoveryActive)
        XCTAssertEqual(controller.gridAuthority, .mine)
        assertNoWindowForce(sent.string)
        controller.advanceGridAuthorityClockForTesting(by: 10_001)
        ackAllPending(controller, frames: 100)
        XCTAssertNil(controller.gridAuthoritySessionForTesting.query.held)
        XCTAssertFalse(controller.gridAuthoritySessionForTesting.ordinaryRecoveryActive)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(count("resize-window -x 92 -y 38 -t @1", in: sent.string), 1, sent.string)
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
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertFalse(controller.gridAuthorityAllowsInput)
    }

    func test_ownStampEchoConfirmsMine() {
        let (controller, _) = makeController()
        deliverStamp(controller, value: selfValue())
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
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

    // MARK: - Attach and departure only read (R5)

    /// D3/R5 on both control paths: attaching reads the stamp before any
    /// geometry, withholds keyboard/rotation churn during the read, and never
    /// claims whatever the read returns.
    func test_attachNeverClaimsOrSizesBeforeAuthorityIsKnown() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            for (stamp, expected) in [
                (Self.peerValue, TmuxController.GridAuthorityPresentation.veiled(peerName: "iPhone")),
                ("", .none),
                // Our own stamp over a window someone else sized (a laptop's
                // bare attach): yield to the stamp-less peer, never claim.
                (selfValue(), .veiled(peerName: TmuxStamplessPeer.displayName)),
            ] {
                let (controller, sent) = makeController(path: path, remoteStamp: stamp, attach: false)
                controller.ingest(Array(Self.handshake.utf8))
                XCTAssertTrue(sent.string.contains(Self.authorityRead), "\(path) \(stamp): \(sent.string)")
                controller.updateClientSize(cols: 47, rows: 20)
                assertNoGeometryOrStamp(sent.string, "\(path) attach before the read resolves")

                ackAllPending(controller, frames: 40)
                XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
                XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
                XCTAssertEqual(controller.gridAuthorityPresentation, expected, "\(path) \(stamp)")
                if stamp.isEmpty {
                    // M3: no stamp at all means nobody holds the grid. The
                    // read releases a bare client-size advertisement (so a
                    // fresh or restarted server is not pinned at 80x24),
                    // but still no stamp, latest fence or window force.
                    assertNoClaimGeometryOrStamp(sent.string, "\(path) attach reading '' must not claim")
                    XCTAssertTrue(sent.string.contains("refresh-client -C 47,20"), "\(path): \(sent.string)")
                    XCTAssertFalse(controller.gridAuthorityGeometryHeldForTesting, "\(path): unstamped releases")
                } else {
                    assertNoGeometryOrStamp(sent.string, "\(path) attach reading '\(stamp)' must not claim")
                    XCTAssertTrue(
                        controller.gridAuthorityGeometryHeldForTesting,
                        "\(path): a verdict other than our own window keeps geometry withheld"
                    )
                }
            }
        }
    }

    /// A peer's departure is not an authority event: no presence proof, no
    /// auto-reclaim, no toast. The stamp stays until a show or a gesture.
    func test_peerDepartureNeverReclaims() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeController(path: path, remoteStamp: Self.peerValue)
            XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
            sent.clear()

            controller.ingest(Array("%client-detached /dev/ttys-peer\r\n".utf8))

            XCTAssertEqual(sent.string, "", "\(path): a detach must send nothing")
            XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
            XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
            XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        }
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

    // MARK: - Show edges

    /// R1/R2: a show over a peer's grid claims, but only after its own fresh
    /// read. The presentation is "resuming" (terminal visible), never the veil.
    func test_ownerScopeHoldsReadAndSubscriptionUntilBothResolutionReplies() async {
        let (controller, sent) = makeController(attach: false, ownerName: "owner")
        controller.ingest(Array(Self.handshake.utf8))
        XCTAssertTrue(sent.string.contains("display-message -p -t '=owner:'"), sent.string)
        XCTAssertFalse(sent.string.contains("show-options -qv"), sent.string)
        XCTAssertFalse(sent.string.contains("tessera-authority:"), sent.string)
        ackAllPending(controller, frames: 1)
        XCTAssertFalse(sent.string.contains("show-options -qv"))
        await Task { @MainActor in }.value
        XCTAssertFalse(sent.string.contains("tessera-authority:"), sent.string)
        ackAllPending(controller, frames: 1)
        XCTAssertEqual(count(Self.ownerRead, in: sent.string), 1, sent.string)
        XCTAssertFalse(sent.string.contains("tessera-authority:"), sent.string)
        // Resolution releases the read immediately; feeds wait for the
        // window list's panes and the next main-actor subscription flush.
        ackAllPending(controller, frames: 40)
        await waitForSubscriptionFlush(controller)
        XCTAssertTrue(Self.containsAuthorityFeed(sent.string, .owner(SessionId(42))), sent.string)
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(count(Self.ownerRead, in: sent.string), 1)
    }

    func test_ownerScopeReleasesOnlyCurrentReadAfterShowSupersedesAttach() {
        let (controller, sent) = makeController(remoteStamp: Self.peerValue, attach: false, ownerName: "owner")
        controller.ingest(Array(Self.handshake.utf8))
        controller.gridAuthorityShown()
        XCTAssertFalse(sent.string.contains("show-options -qv"))
        ackAllPending(controller, frames: 2)
        XCTAssertEqual(count(Self.ownerRead, in: sent.string), 1)
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.reason, .show,
                       "the released read must be the show's current read")
    }

    func test_ownerScopeWritesOwnerThenMirrorAndIgnoresMirrorFailure() throws {
        let (controller, sent) = makeController(remoteStamp: Self.peerValue, ownerName: "owner")
        var repaint: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in repaint = generation }
        controller.gridAuthorityShown()
        ackAllPending(controller, frames: 40)
        ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
        ackAllPending(controller, frames: 40)
        controller.completeGridAuthoritySideChannelRepaint(generation: try XCTUnwrap(repaint))
        ackPendingGeometryQuery(controller)
        let stamp = TmuxGridAuthorityStamp(identity: .init(id: Self.selfID, displayName: "iPad"), generation: try XCTUnwrap(repaint))
        let commands = TmuxGridAuthority.writeCommands(stamp, scope: .owner(SessionId(42)))
        XCTAssertTrue(sent.string.contains(commands.joined(separator: "\n")), sent.string)
        ackAllPending(controller, frames: 1)
        XCTAssertEqual(controller.gridAuthority, .mine)
        controller.ingest(Array("%begin 0 990 1\r\nmirror failed\r\n%error 0 990 1\r\n".utf8))
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    /// A grouped view outlives its killed owner, whose read then finds no
    /// owner (`show-options -q -t` would answer an unset stamp). The scope
    /// moves to our own session: subscription, retry and later reads.
    func test_ownerScopeFallsBackToOwnSessionWhenTheOwnerIsKilled() async {
        let (controller, sent) = makeController(remoteStamp: Self.peerValue, ownerName: "owner")
        await waitForSubscriptionFlush(controller)
        ackAllPending(controller, frames: 40)
        sent.clear()
        fixture(controller).ownerKilled = true
        controller.rereadGridAuthorityForTesting()
        XCTAssertEqual(count(Self.ownerRead, in: sent.string), 1, sent.string)
        sent.clear()
        ackAllPending(controller, frames: 1)
        await waitForSubscriptionFlush(controller)
        XCTAssertTrue(Self.containsAuthorityFeed(sent.string, .ownSession), sent.string)
        XCTAssertNotNil(controller.gridAuthoritySessionForTesting.query.retryAt)
        controller.advanceGridAuthorityClockForTesting(by: 250)
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
        XCTAssertFalse(sent.string.contains(Self.ownerRead), sent.string)
        ackAllPending(controller, frames: 40)
        XCTAssertNil(controller.gridAuthoritySessionForTesting.query.current)
        sent.clear()
        controller.rereadGridAuthorityForTesting()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
        XCTAssertFalse(sent.string.contains(Self.ownerRead), sent.string)
    }

    /// A live owner without a stamp answers `$42|`: unstamped, still the owner.
    func test_ownerScopeKeepsTheOwnerWhenItsStampIsUnset() {
        let (controller, sent) = makeController(ownerName: "owner")
        sent.clear()
        controller.rereadGridAuthorityForTesting()
        ackAllPending(controller, frames: 40)
        XCTAssertFalse(Self.containsAuthorityFeed(sent.string, .ownSession), sent.string)
        sent.clear()
        controller.rereadGridAuthorityForTesting()
        XCTAssertEqual(count(Self.ownerRead, in: sent.string), 1, sent.string)
    }

    /// An owner killed between the read and the stamp fails the owner write:
    /// the claim stays yielded and the next read is our own session's.
    func test_ownerWriteFailureFallsBackToOwnSession() async throws {
        let (controller, sent) = makeController(remoteStamp: Self.peerValue, ownerName: "owner")
        await waitForSubscriptionFlush(controller)
        ackAllPending(controller, frames: 40)
        var repaint: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in repaint = generation }
        controller.gridAuthorityShown()
        ackAllPending(controller, frames: 40)
        ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
        ackAllPending(controller, frames: 40)
        controller.completeGridAuthoritySideChannelRepaint(generation: try XCTUnwrap(repaint))
        ackPendingGeometryQuery(controller)
        XCTAssertTrue(sent.string.contains("set-option -t '$42'"), sent.string)
        sent.clear()
        controller.ingest(Array("%begin 0 990 1\r\nno such session: $42\r\n%error 0 990 1\r\n".utf8))
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertNotEqual(controller.gridAuthority, .mine)
        await waitForSubscriptionFlush(controller)
        XCTAssertTrue(Self.containsAuthorityFeed(sent.string, .ownSession), sent.string)
        ackAllPending(controller, frames: 40)
        controller.rereadGridAuthorityForTesting()
        XCTAssertGreaterThanOrEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
        XCTAssertFalse(sent.string.contains(Self.ownerRead), sent.string)
    }

    /// A failure from our own session's read says nothing about the owner.
    func test_ownSessionReadFailureKeepsLegacyScopeAndRetries() {
        let (controller, sent) = makeController(remoteStamp: Self.peerValue)
        sent.clear()
        controller.rereadGridAuthorityForTesting()
        controller.ingest(Array("%begin 0 970 1\r\nread failed\r\n%error 0 970 1\r\n".utf8))
        XCTAssertFalse(sent.string.contains("refresh-client -B"), sent.string)
        controller.advanceGridAuthorityClockForTesting(by: 250)
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 2, sent.string)
    }

    func test_ownerResolutionOddReplyFallsBackToLegacyWire() async {
        let (controller, sent) = makeController(attach: false, ownerName: "owner")
        fixture(controller).ownerScopeReply = ["$42 other"]
        controller.ingest(Array(Self.handshake.utf8))
        ackAllPending(controller, frames: 2)
        XCTAssertTrue(sent.string.contains(TmuxGridAuthority.queryCommand(.ownSession)))
        ackAllPending(controller, frames: 40)
        await waitForSubscriptionFlush(controller)
        XCTAssertTrue(Self.containsAuthorityFeed(sent.string, .ownSession))
        XCTAssertFalse(sent.string.contains("#{session_id}|"))
    }

    func test_ownerResolutionCommandErrorFallsBackToLegacyWire() async {
        let (controller, sent) = makeController(attach: false, ownerName: "owner")
        controller.ingest(Array(Self.handshake.utf8))
        controller.ingest(Array("%begin 0 990 1\r\nno such session\r\n%error 0 990 1\r\n".utf8))
        ackAllPending(controller, frames: 1)
        XCTAssertTrue(sent.string.contains(TmuxGridAuthority.queryCommand(.ownSession)))
        ackAllPending(controller, frames: 40)
        await waitForSubscriptionFlush(controller)
        XCTAssertTrue(Self.containsAuthorityFeed(sent.string, .ownSession))
        XCTAssertFalse(sent.string.contains("#{session_id}|"))
    }

    func test_inlineKeepsLegacyOrderEvenWithOwnerName() async {
        let (controller, sent) = makeController(path: .inline, attach: false, ownerName: "owner")
        controller.ingest(Array(Self.handshake.utf8))
        XCTAssertFalse(sent.string.contains("#{session_group}"))
        let read = sent.string.range(of: TmuxGridAuthority.queryCommand(.ownSession))
        XCTAssertFalse(sent.string.contains("tessera-authority:"), sent.string)
        ackAllPending(controller, frames: 40)
        await waitForSubscriptionFlush(controller)
        let subscription = sent.string.range(of: "'tessera-authority:@")
        XCTAssertNotNil(read)
        XCTAssertNotNil(subscription)
        XCTAssertTrue(Self.containsAuthorityFeed(sent.string, .ownSession), sent.string)
        if let read, let subscription { XCTAssertLessThan(read.lowerBound, subscription.lowerBound) }
    }

    func test_ownerScopeReconnectResolvesAgainAndRejectsOldReplies() {
        let (controller, sent) = makeController(ownerName: "owner")
        controller.sideChannelDisconnected()
        sent.clear()
        fixture(controller).ownerScopeReply = ["$84 group"]
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array(Self.handshake.utf8))
        XCTAssertTrue(sent.string.contains("display-message -p -t '=owner:'"))
        XCTAssertFalse(sent.string.contains("show-options -qv"))
        ackAllPending(controller, frames: 40)
        XCTAssertTrue(sent.string.contains(TmuxGridAuthority.queryCommand(.owner(SessionId(84)))), sent.string)
        XCTAssertFalse(sent.string.contains(Self.ownerRead))
    }

    /// A reconnect resolves the same owner id. The previous connection's
    /// outstanding owner read completes with the reset, after the new
    /// connection exists; it must not move the new connection's scope.
    func test_ownerScopeSurvivesThePreviousConnectionsReadOnTheSameOwner() async {
        let (controller, sent) = makeController(remoteStamp: Self.peerValue, ownerName: "owner")
        await waitForSubscriptionFlush(controller)
        ackAllPending(controller, frames: 40)
        controller.rereadGridAuthorityForTesting()
        XCTAssertEqual(count(Self.ownerRead, in: sent.string), 1, sent.string)
        controller.sideChannelDisconnected()
        sent.clear()
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array(Self.handshake.utf8))
        ackAllPending(controller, frames: 40)
        await waitForSubscriptionFlush(controller)
        XCTAssertTrue(Self.containsAuthorityFeed(sent.string, .owner(SessionId(42))), sent.string)
        XCTAssertFalse(Self.containsAuthorityFeed(sent.string, .ownSession), sent.string)
        ackAllPending(controller, frames: 40)
        sent.clear()
        controller.rereadGridAuthorityForTesting()
        XCTAssertEqual(count(Self.ownerRead, in: sent.string), 1, sent.string)
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 0, sent.string)
    }

    func test_showWhileYieldedClaimsAfterAFreshRead() throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        sent.clear()

        controller.gridAuthorityShown()
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        XCTAssertFalse(controller.gridAuthorityAllowsInput)
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
        assertNoGeometryOrStamp(sent.string, "a show waits for its read")

        ackAllPending(controller, frames: 1)
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.reason, .show)
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        XCTAssertTrue(sent.string.contains("refresh-client -C 92,38"), sent.string)

        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        completeSideChannelRepaintAndCommit(controller, generation: try XCTUnwrap(repaintGeneration))
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
        XCTAssertFalse(controller.gridAuthorityGeometryHeldForTesting)
    }

    /// R2: already ours at our size resolves with zero commands.
    func test_showOverOwnWindowAtLocalSizeSendsNothingButTheRead() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeOwnerController(path: path)
            controller.gridAuthorityShown()
            XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
            sent.clear()
            ackAllPending(controller, frames: 1)
            XCTAssertEqual(sent.string, "", "\(path): resolving a show over our own window sends nothing")
            XCTAssertEqual(controller.gridAuthorityPresentation, .none)
            XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        }
    }

    /// Stage 3 review: the session hears the foreground (willEnterForeground)
    /// before the terminal's active phase, so a read can be answered while
    /// the controller is still inactive. An owner replay it releases is
    /// counted as replayed and never released again; activation sends it.
    func test_anOwnerReplayReleasedWhileInactiveGoesOutAtActivation() {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.prepareForAppInactivity()
        // Rotated while away: an inactive app sizes nothing.
        controller.updateClientSize(cols: 106, rows: 40)
        XCTAssertFalse(sent.string.contains("refresh-client -C"), sent.string)
        controller.gridAuthorityForegrounded()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
        sent.clear()
        controller.ingest(Array("%begin 0 900 1\r\n\(selfValue())\r\n%end 0 900 1\r\n".utf8))
        XCTAssertFalse(sent.string.contains("refresh-client -C"), "still inactive: \(sent.string)")
        controller.refreshActiveWindowOnForeground()
        XCTAssertEqual(count("refresh-client -C 106,40", in: sent.string), 1, sent.string)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertFalse(sent.string.contains("set-option"), "an owner replay writes no stamp: \(sent.string)")
    }

    /// Review note 2: the show's read is never folded into one issued before
    /// it, and a reply that predates the show cannot resolve its intent.
    func test_showAlwaysSendsItsOwnReadEvenWithAForegroundReadInFlight() {
        let (controller, sent) = makeOwnerController(path: .sideChannel)
        controller.prepareForAppInactivity()
        controller.refreshActiveWindowOnForeground()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)

        controller.gridAuthorityShown()
        XCTAssertEqual(
            count(Self.authorityRead, in: sent.string),
            2,
            "the show edge must send a fresh read: \(sent.string)"
        )
        // A repeated show is a new edge with a new intent: it reads afresh.
        controller.gridAuthorityShown()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 3, "each show edge reads afresh")
        // A foreground re-derive issued after the show coalesces into its read.
        controller.prepareForAppInactivity()
        controller.refreshActiveWindowOnForeground()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 3, sent.string)

        // The pre-show (foreground) reply names a peer; it must not decide
        // the intent, which belongs to the newest read only.
        controller.ingest(Array("%begin 0 900 1\r\n\(Self.peerValue)\r\n%end 0 900 1\r\n".utf8))
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        // The second read also predates the latest show.
        controller.ingest(Array("%begin 0 901 1\r\n\(Self.peerValue)\r\n%end 0 901 1\r\n".utf8))
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        // The newest read resolves it: still ours at our size, zero commands.
        sent.clear()
        controller.ingest(Array("%begin 0 902 1\r\n\(selfValue())\r\n%end 0 902 1\r\n".utf8))
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
        assertNoGeometryOrStamp(sent.string, "resolved over our own window")
    }

    /// Review note 1 / M2, in the order a resume really delivers it: the
    /// hide edge (emitted on return once the debounce has run out), the line
    /// tmux buffered while we were away, the foreground read naming the
    /// phone, and only then (0.35 s later) the show. No frame draws the veil.
    func test_showWithBufferedPeerObservationNeverFlashesTheVeil() throws {
        let (controller, _) = makeOwnerController(path: .sideChannel)
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        var frames: [TmuxController.GridAuthorityPresentation] = [controller.gridAuthorityPresentation]
        func sample() {
            if frames.last != controller.gridAuthorityPresentation {
                frames.append(controller.gridAuthorityPresentation)
            }
        }

        controller.prepareForAppInactivity()
        controller.gridAuthorityHidden()
        sample()
        // A line tmux buffered while we were away names the phone.
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        sample()
        // The foreground read lands before the settled show: still the phone.
        controller.refreshActiveWindowOnForeground()
        fixture(controller).authorityStamp = Self.peerValue
        ackAllPending(controller, frames: 1)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "a foreground read never claims")
        sample()
        // The show's fresh read: the phone still holds it, so claim.
        controller.gridAuthorityShown()
        sample()
        ackAllPending(controller, frames: 1)
        sample()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        for number in 0..<40 {
            ackAllPending(controller, frames: 1)
            sample()
            _ = number
        }
        completeSideChannelRepaintAndCommit(controller, generation: try XCTUnwrap(repaintGeneration))
        sample()

        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(frames, [.none, .resuming(awaitingConnection: false), .none], "\(frames)")
        XCTAssertFalse(frames.contains(where: \.showsVeil), "no veil frame: \(frames)")
    }

    /// A hide edge cancels the unsent intent (and so does the pending-state
    /// cancel); the late reply then only follows the stamp. While hidden the
    /// peer is not drawn as a veil (M2): the next show decides.
    func test_hideBeforeTheReadAnswersCancelsTheIntent() {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        controller.gridAuthorityShown()
        controller.gridAuthorityHidden()
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        sent.clear()
        ackAllPending(controller, frames: 1)
        assertNoGeometryOrStamp(sent.string, "a hidden session never claims")
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        XCTAssertFalse(controller.gridAuthorityAllowsInput)
    }

    /// R3: a show intent waiting for a channel expires; the clock pauses
    /// only while a prompt is up.
    func test_pendingShowIntentExpiresAndPausesForPrompts() async throws {
        let (controller, _) = makeController(path: .sideChannel, remoteStamp: Self.peerValue,
                                             authorityConfiguration: .init(intentWindowMillis: 50))
        controller.sideChannelDisconnected()
        controller.gridAuthorityShown()
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: true))

        controller.setGridAuthorityIntentClockPaused(true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.pendingIntent, "paused while a prompt is up")

        controller.setGridAuthorityIntentClockPaused(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
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
        XCTAssertFalse(
            wire.contains("set-option \(TmuxController.gridAuthorityOption)"),
            "the lifecycle stamp must wait for the authoritative repaint: \(wire)"
        )
        // …and the reclaim replays the latest latched size, not the
        // pre-yield one.
        XCTAssertTrue(wire.contains("refresh-client -C 47,20"), wire)
        // An early/stale own stamp echo is advisory — it must NOT lift the veil,
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

        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        ackAllPending(controller)
        // Re-observe the settled layout after installing the side-channel
        // delivery acknowledgement.
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        controller.completeGridAuthoritySideChannelRepaint(
            generation: try! XCTUnwrap(repaintGeneration)
        )
        ackPendingGeometryQuery(controller)
        XCTAssertTrue(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"),
            "the repaint must enqueue the lifecycle stamp: \(sent.string)"
        )
        XCTAssertTrue(controller.gridAuthority.isPeer)
        ackAllPending(controller, frames: 1)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
    }

    private func waitForSubscriptionFlush(_ controller: TmuxController) async {
        for _ in 0..<20 where !controller._debugPendingCommands.contains(where: {
            $0.hasPrefix("refresh-client -B ")
        }) {
            await Task.yield()
        }
    }

    private func ackAllPending(_ controller: TmuxController, frames: Int = 15) {
        let fixture = fixture(controller)
        fixture.observe(controller)
        for number in 500..<(500 + frames) {
            let lines = fixture.acknowledge(controller._debugPendingCommands.first)
            let body = (["%begin 0 \(number) 1"] + lines + ["%end 0 \(number) 1"])
                .joined(separator: "\r\n") + "\r\n"
            controller.ingest(Array(
                body.utf8
            ))
        }
    }

    /// No claim-only wire: no stamp, no inline latest fence and no side
    /// channel window force. A bare `refresh-client -C` may appear.
    private func assertNoClaimGeometryOrStamp(
        _ wire: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(wire.contains("resize-window"), "\(message): \(wire)", file: file, line: line)
        XCTAssertFalse(wire.contains("select-window"), "\(message): \(wire)", file: file, line: line)
        XCTAssertFalse(
            wire.contains("set-option \(TmuxController.gridAuthorityOption)"),
            "\(message): \(wire)",
            file: file,
            line: line
        )
    }

    /// `gridAuthority` has one source: the lifecycle reducer.
    private func assertAuthorityProjectionMatchesReducer(
        _ controller: TmuxController,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected: TmuxController.GridAuthority
        switch controller.gridAuthorityLifecycleForTesting.authority {
        case .unknown: expected = .unknown
        case .mine: expected = .mine
        case .peer(_, let displayName, _): expected = .peer(displayName: displayName)
        }
        XCTAssertEqual(controller.gridAuthority, expected, message, file: file, line: line)
    }

    private func completeSideChannelRepaintAndCommit(
        _ controller: TmuxController,
        generation: UInt64
    ) {
        controller.completeGridAuthoritySideChannelRepaint(generation: generation)
        ackAllPending(controller, frames: 15)
    }

    private func ackPendingGeometryQuery(_ controller: TmuxController) {
        guard controller._debugPendingCommands.first?.contains("tessera-window-size") == true else { return }
        ackAllPending(controller, frames: 1)
    }

    private func fixtureResponseBody(
        _ controller: TmuxController,
        command: String,
        otherBody: String
    ) -> String {
        let fixture = fixture(controller)
        fixture.observe(controller)
        let lines = fixture.acknowledge(command)
        guard command.contains("tessera-window-size") else { return otherBody }
        return lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Answers every command on the wire in transmission order, starting at
    /// line `from`, including commands transmitted while answering. Render
    /// commands (the inline foreground repaint is queued ahead of the read)
    /// get a well-formed metadata row and capture; the authority read
    /// returns `authority`. Returns the next unanswered line index.
    @discardableResult
    private func answerWire(
        _ controller: TmuxController,
        _ sent: ByteSink,
        from start: Int = 0,
        authority: String
    ) -> Int {
        var index = start
        var number = 900
        let fixture = fixture(controller)
        while true {
            let lines = sent.string.split(separator: "\n").map(String.init)
            guard index < lines.count, number < 1_100 else { return index }
            let command = lines[index]
            index += 1
            var body: [String]
            if command.hasPrefix(Self.authorityRead) {
                body = authority.isEmpty ? [] : [authority]
            } else if command.hasPrefix("display-message -p -t "), command.contains("#{cursor_x}") {
                body = [renderMetadata(pane: 0)]
            } else if command.hasPrefix("capture-pane ") {
                body = ["authoritative viewport"]
            } else {
                fixture.observe(controller)
                body = fixture.acknowledge(command)
            }
            let frame = (["%begin 0 \(number) 1"] + body + ["%end 0 \(number) 1"])
                .joined(separator: "\r\n") + "\r\n"
            number += 1
            controller.ingest(Array(frame.utf8))
        }
    }

    private func makeSettledSideChannelController() -> (
        controller: TmuxController, sent: ByteSink
    ) {
        makeOwnerController(path: .sideChannel)
    }

    /// The local grid changed while backgrounded and the window still has
    /// the size this device last pushed: one ordinary owner resize, with no
    /// claim and no stamp write (`replayOwnedGeometry`).
    func test_foregroundOwnStampAtLastOwnedSizeReplaysWithoutClaimOrStamp() {
        let (controller, sent) = makeSettledSideChannelController()
        controller.prepareForAppInactivity()
        controller.updateClientSize(cols: 106, rows: 40)
        XCTAssertTrue(sent.string.isEmpty, sent.string)
        controller.refreshActiveWindowOnForeground()
        XCTAssertTrue(sent.string.contains(Self.authorityRead), sent.string)
        controller.updateClientSize(cols: 112, rows: 42)
        assertNoGeometryOrStamp(sent.string, "geometry waits for the foreground read")
        sent.clear()

        controller.ingest(Array("%begin 0 900 1\r\n\(selfValue())\r\n%end 0 900 1\r\n".utf8))

        XCTAssertTrue(sent.string.contains("refresh-client -C 112,42"), sent.string)
        XCTAssertFalse(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"),
            "an owned replay never writes the stamp: \(sent.string)"
        )
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertFalse(controller.gridAuthorityRepaintRequiresFreshRemoteState)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
    }

    func test_foregroundPeerReplyKeepsOrdinaryResizeAndStampWithheld() {
        let (controller, sent) = makeSettledSideChannelController()
        controller.prepareForAppInactivity()
        controller.refreshActiveWindowOnForeground()
        controller.updateClientSize(cols: 106, rows: 40)
        sent.clear()
        controller.ingest(Array("%begin 0 900 1\r\n\(Self.peerValue)\r\n%end 0 900 1\r\n".utf8))
        controller.updateClientSize(cols: 112, rows: 42)

        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertFalse(sent.string.contains("list-clients"), "no peer-presence proof: \(sent.string)")
        XCTAssertFalse(sent.string.contains("#{client_name}"), "no peer-presence proof: \(sent.string)")
        assertNoGeometryOrStamp(sent.string, "a yielded foreground keeps geometry withheld")
    }

    /// Inactivity gates repainting, never authority: a read that answers
    /// while the app is inactive is processed at once.
    func test_authorityReplyIsProcessedWhileInactive() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeOwnerController(path: path)
            controller.prepareForAppInactivity()
            controller.refreshActiveWindowOnForeground()
            controller.prepareForAppInactivity()
            let next = answerWire(controller, sent, authority: Self.peerValue)

            XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"), "\(path)")
            XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
            assertNoGeometryOrStamp(sent.string, "\(path): an inactive read never claims")
            _ = next
            sent.clear()
            controller.refreshActiveWindowOnForeground()
            XCTAssertEqual(
                count(Self.authorityRead, in: sent.string),
                1,
                "\(path): the next foreground reads afresh: \(sent.string)"
            )
        }
    }

    func test_duplicateForegroundEdgesCoalesceOnePendingAuthorityQuery() {
        let (controller, sent) = makeSettledSideChannelController()
        for _ in 0..<3 {
            controller.prepareForAppInactivity()
            controller.refreshActiveWindowOnForeground()
        }
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
        assertNoGeometryOrStamp(sent.string, "foreground edges only read")
    }

    /// Foreground re-derives on the inline path as well (formerly only the
    /// side channel), and the read withholds geometry there too.
    func test_inlineForegroundReadsAuthorityAndWithholdsGeometry() {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.prepareForAppInactivity()
        controller.refreshActiveWindowOnForeground()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
        controller.updateClientSize(cols: 106, rows: 40)
        assertNoGeometryOrStamp(sent.string, "inline foreground waits for its read")

        answerWire(controller, sent, authority: selfValue())
        XCTAssertTrue(sent.string.contains("refresh-client -C 106,40"), sent.string)
        XCTAssertFalse(sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"), sent.string)
    }

    func test_inlineReclaimUsesSelectWindowFenceNotResizeWindow() {
        let (controller, sent) = makeController(path: .inline)
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()
        controller.reclaimGridAuthority()
        // A live tap claims at once, and the fence rides in the claim's
        // first burst (no ack-sequencing hop any more).
        XCTAssertTrue(sent.string.hasSuffix("\nselect-window\n"), sent.string)
        ackAllPending(controller)
        let wire = sent.string
        // tmux-native latest-client transfer: a targetless no-op select,
        // which tmux resolves to our own session's current window (W2). The
        // side-channel resize-window force must never leak onto the inline
        // path (it can snap back and churn repaints).
        XCTAssertTrue(wire.contains("\nselect-window\n"), wire)
        XCTAssertFalse(wire.contains("select-window -t"), wire)
        XCTAssertFalse(wire.contains("resize-window"), wire)
        XCTAssertFalse(wire.contains("set-option -w -u"), wire)
    }

    /// W2 and §6.6: the inline claim sends its replay, its policy probe and
    /// its fence in one burst. The fence used to wait a `display-message`
    /// round trip because it named a window; a targetless fence cannot name
    /// a stale one, so the hop is gone.
    func test_inlineClaimSendsTheTargetlessFenceInTheReplayBurst() {
        let (controller, sent) = makeController(path: .inline)
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()
        // A live tap begins the claim at once; nothing has been answered.
        XCTAssertTrue(controller.reclaimGridAuthority())
        let burst = sent.string
        let lines = burst.split(separator: "\n").map(String.init)
        let probe = lines.firstIndex(of: "show-options -wA -v -t @0 window-size")
        let fence = lines.firstIndex(of: TmuxClientSizeReplay.latestFenceCommand)
        XCTAssertNotNil(probe, burst)
        XCTAssertNotNil(fence, burst)
        if let probe, let fence { XCTAssertLessThan(probe, fence, burst) }
        if let replay = lines.firstIndex(where: { $0.hasPrefix("refresh-client -C ") }),
           let fence {
            XCTAssertLessThan(replay, fence, "the fence follows the size it fences: \(burst)")
        }
        XCTAssertFalse(burst.contains("display-message -p ''"), burst)
        XCTAssertFalse(burst.contains("select-window -t"), burst)
    }

    /// The side channel fences latest before unset, then a no-op ack orders
    /// its separate settle probe after that complete mutation sequence.
    func test_sideChannelClaimStillOrdersConfirmationBehindItsForce() {
        let (controller, sent) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()
        XCTAssertTrue(controller.reclaimGridAuthority())
        let lines = sent.string.split(separator: "\n").map(String.init)
        let force = lines.firstIndex(where: { $0.hasPrefix("resize-window ") })
        let ack = lines.lastIndex(of: "display-message -p ''")
        XCTAssertNotNil(force, sent.string)
        XCTAssertNotNil(ack, sent.string)
        if let force, let ack { XCTAssertLessThan(force, ack, sent.string) }
        let fence = lines.firstIndex(of: "select-window")
        let unset = lines.firstIndex(where: { $0.hasPrefix("set-option -w -u") })
        XCTAssertNotNil(fence, sent.string)
        XCTAssertNotNil(unset, sent.string)
        if let force, let fence, let unset, let ack {
            XCTAssertLessThan(force, fence)
            XCTAssertLessThan(fence, unset)
            XCTAssertLessThan(unset, ack)
        }
        XCTAssertFalse(sent.string.contains("select-window -t"), sent.string)
    }

    // MARK: - Ordinary replays carry the latest fence

    func test_inlineSizeChangeFencesLatestWithATargetlessSelectWindow() {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.updateClientSize(cols: 106, rows: 9)
        let wire = sent.string
        XCTAssertTrue(wire.hasSuffix("refresh-client -C 106,9\nselect-window\n"), wire)
        XCTAssertFalse(wire.contains("select-window -t"), wire)
        XCTAssertFalse(wire.contains("resize-window"), wire)
    }

    // MARK: - P5 / P6: ordinary replays write no stamp and no unchanged -C

    /// P5: the owner's keyboard, rotation and split-view churn resizes with
    /// `refresh-client -C` and never writes the stamp. Every peer already
    /// holds our stamp from the claim; a fresh generation per resize only
    /// redrew every client, fanned out to every peer and aborted any peer
    /// claim in flight as contested.
    func test_ownerResizesNeverWriteTheStamp() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeOwnerController(path: path)
            for (cols, rows) in [(106, 40), (106, 22), (92, 38), (120, 50)] {
                controller.updateClientSize(cols: cols, rows: rows)
                ackAllPending(controller)
            }
            XCTAssertTrue(sent.string.contains("refresh-client -C 106,22"), "\(path): \(sent.string)")
            XCTAssertTrue(sent.string.contains("refresh-client -C 120,50"), "\(path): \(sent.string)")
            XCTAssertFalse(
                sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"),
                "\(path): \(sent.string)"
            )
            XCTAssertEqual(controller.gridAuthority, .mine, "\(path)")
        }
    }

    /// P6: a take-back at the grid this connection already advertised needs
    /// no `-C`. The targetless fence re-takes `latest` and tmux sizes the
    /// window from the size it already stores for this client.
    func test_inlineTakeBackAtTheAdvertisedSizeSendsNoRefresh() {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.updateClientSize(cols: 106, rows: 40)
        XCTAssertTrue(sent.string.contains("refresh-client -C 106,40\nselect-window\n"), sent.string)
        ackAllPending(controller)
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))

        sent.clear()
        XCTAssertTrue(controller.reclaimGridAuthority())
        let burst = sent.string
        XCTAssertFalse(burst.contains("refresh-client -C"), burst)
        XCTAssertTrue(burst.contains("show-options -wA -v -t @0 window-size\n"), burst)
        XCTAssertTrue(burst.hasSuffix("\nselect-window\n"), burst)
    }

    func test_sideChannelTakeBackUsesAcknowledgedSizeOrAdvertisesNewSizeBeforeFence() {
        for changed in [false, true] {
            let (controller, sent) = makeOwnerController(path: .sideChannel)
            controller.updateClientSize(cols: 106, rows: 40)
            ackAllPending(controller)
            deliverStamp(controller, value: Self.peerValue)
            if changed { controller.updateClientSize(cols: 130, rows: 44) }
            sent.clear()
            XCTAssertTrue(controller.reclaimGridAuthority())
            let burst = sent.string
            XCTAssertEqual(count("refresh-client -C", in: burst), changed ? 1 : 0, burst)
            let columns = changed ? 130 : 106
            let rows = changed ? 44 : 40
            XCTAssertTrue(burst.contains("resize-window -x \(columns) -y \(rows) -t @0\nselect-window\nset-option -w -u -t @0 window-size\n"), burst)
            if changed, let refresh = burst.range(of: "refresh-client -C"), let fence = burst.range(of: "select-window") {
                XCTAssertLessThan(refresh.lowerBound, fence.lowerBound)
            }
        }
    }

    func test_sideChannelFailedLatestFenceAbortsClaimBeforeStampOrRepaint() {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var repaints = 0
        controller.onGridAuthoritySideChannelRepaintRequired = { _, _ in repaints += 1 }
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        for _ in 0..<50 {
            let wire = sent.string.split(separator: "\n").map(String.init)
            guard index < wire.count else { break }
            review610ReplyNext(controller, sent, answered: &index, success: wire[index] != "select-window")
        }
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, sent.string)
        XCTAssertEqual(stampWrites(sent), 0)
        XCTAssertEqual(repaints, 0)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
    }

    /// A side-channel controller attached over @0 (active) and @1.
    private func makeTwoWindowSideChannelController(
        activeGrid: FixtureGrid,
        backgroundGrid: FixtureGrid
    ) -> (controller: TmuxController, sent: ByteSink) {
        let (controller, sent) = makeController(
            path: .sideChannel, remoteStamp: Self.peerValue, remoteGrid: activeGrid, attach: false
        )
        fixture(controller).grids[WindowId(1)] = backgroundGrid
        controller.ingest(Array("%window-add @1\r\n".utf8))
        controller.ingest(Array(Self.handshake.utf8))
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.windows.map(\.id), [WindowId(0), WindowId(1)])
        sent.clear()
        return (controller, sent)
    }

    /// A claim forces its own window even at a matching layout, but a
    /// background window that already fits gets nothing: resize/unset would
    /// replace that window's own window-size policy for no reason, and the
    /// take-back budget is sizing commands for the target window only (§6.6).
    func test_sideChannelClaimAtAMatchingLayoutForcesOnlyItsOwnWindow() {
        let grid = FixtureGrid(columns: 92, rows: 38)
        let (controller, sent) = makeTwoWindowSideChannelController(activeGrid: grid, backgroundGrid: grid)
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        for _ in 0..<80 {
            guard review610ReplyNext(controller, sent, answered: &index) != nil else { break }
        }
        let wire = sent.string
        XCTAssertTrue(
            wire.contains("resize-window -x 92 -y 38 -t @0\nselect-window\nset-option -w -u -t @0 window-size\n"),
            wire
        )
        XCTAssertFalse(wire.contains("resize-window -x 92 -y 38 -t @1"), wire)
        XCTAssertFalse(wire.contains("set-option -w -u -t @1 window-size"), wire)
    }

    /// Only the claim's own window can abort it. A background window that
    /// closed between the snapshot and its resize answers `%error`, which
    /// says nothing about the take-back; Android binds its abort to the
    /// geometry fence's window the same way.
    func test_sideChannelBackgroundForceFailureLeavesTheClaimToSettle() throws {
        let (controller, sent) = makeTwoWindowSideChannelController(
            activeGrid: Self.peerGrid, backgroundGrid: FixtureGrid(columns: 160, rows: 47)
        )
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        for _ in 0..<80 {
            let wire = sent.string.split(separator: "\n").map(String.init)
            guard index < wire.count else { break }
            review610ReplyNext(
                controller, sent, answered: &index,
                success: wire[index] != "resize-window -x 92 -y 38 -t @1"
            )
        }
        XCTAssertFalse(sent.string.contains("resize-window -x 92 -y 38 -t @1"), sent.string)
        XCTAssertFalse(sent.string.contains("set-option -w -u -t @1 window-size"), sent.string)
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, sent.string)

        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        completeSideChannelRepaintAndCommit(controller, generation: try XCTUnwrap(repaintGeneration, sent.string))
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
    }

    /// P6, the other way round: a changed grid is advertised, once.
    func test_inlineTakeBackAtANewSizeAdvertisesItOnce() {
        let (controller, sent) = makeOwnerController(path: .inline)
        deliverStamp(controller, value: Self.peerValue)
        controller.updateClientSize(cols: 130, rows: 44)
        XCTAssertFalse(sent.string.contains("refresh-client -C"), "yielded: \(sent.string)")

        sent.clear()
        XCTAssertTrue(controller.reclaimGridAuthority())
        XCTAssertEqual(count("refresh-client -C 130,44", in: sent.string), 1, sent.string)
    }

    func test_sideChannelSizeChangeFencesLatestBeforeRestoringPolicy() {
        let (controller, sent) = makeOwnerController(path: .sideChannel)
        controller.updateClientSize(cols: 106, rows: 9)
        let wire = sent.string
        XCTAssertTrue(wire.contains("refresh-client -C 106,9"), wire)
        XCTAssertTrue(wire.contains("\nselect-window\nset-option -w -u"), wire)
        XCTAssertFalse(wire.contains("select-window -t"), wire)
    }

    func test_repeatedTakeBackGestureDoesNotQueueDuplicateClaim() {
        let (controller, sent) = makeController(path: .inline)
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()

        controller.reclaimGridAuthority()
        let firstWire = sent.string
        controller.reclaimGridAuthority()

        XCTAssertEqual(sent.string, firstWire)
        // One claim: one policy probe and one fence. Attach already
        // advertised 92x38 on this connection, so the claim sends no `-C`
        // (P6).
        XCTAssertEqual(count("show-options -wA -v -t @0 window-size", in: firstWire), 1, firstWire)
        XCTAssertEqual(count("\nselect-window\n", in: firstWire), 1, firstWire)
        XCTAssertEqual(count("refresh-client -C", in: firstWire), 0, firstWire)
    }

    /// R4 while the control channel is down: the gesture records a tap
    /// intent bound to the veil's peer and sends nothing; the re-attach read
    /// finds the same peer and the claim starts then.
    func test_tapWhileChannelDownClaimsAfterReattach() throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        controller.sideChannelDisconnected()
        XCTAssertTrue(controller.gridAuthority.isPeer)
        sent.clear()

        XCTAssertTrue(controller.reclaimGridAuthority())
        XCTAssertEqual(sent.string, "")
        XCTAssertEqual(
            controller.gridAuthorityPresentation,
            .reclaiming(peerName: "iPhone", awaitingConnection: true)
        )
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.pendingIntent?.source, .tap)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array(Self.handshake.utf8))
        XCTAssertTrue(sent.string.contains(Self.authorityRead), sent.string)
        ackAllPending(controller, frames: 40)
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.reason, .userTakeBack)
        XCTAssertEqual(
            controller.gridAuthorityPresentation,
            .reclaiming(peerName: "iPhone", awaitingConnection: false)
        )

        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        completeSideChannelRepaintAndCommit(controller, generation: try XCTUnwrap(repaintGeneration))
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
    }

    /// R3 for a tap: the re-attach read names a different device than the
    /// veil the user tapped. Stay yielded to the device that is working.
    func test_tapWhileChannelDownDropsWhenADifferentPeerTookOver() {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        controller.sideChannelDisconnected()
        XCTAssertTrue(controller.reclaimGridAuthority())
        fixture(controller).authorityStamp = "v1 OTHER-DEVICE-1 7 iPad"
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array(Self.handshake.utf8))
        ackAllPending(controller, frames: 40)

        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPad"))
        assertNoGeometryOrStamp(sent.string, "a stale tap never seizes another device")
    }

    /// S4′: a claim whose presentation timed out is restarted by the next
    /// tap under a new generation; the old generation's fence cannot settle
    /// the replacement.
    func test_retapAfterPresentationTimeoutRestartsTheClaim() throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var repaintGenerations: [UInt64] = []
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGenerations.append(generation)
        }
        sent.clear()

        XCTAssertTrue(controller.reclaimGridAuthority())
        let first = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertFalse(controller.gridAuthorityLifecycleForTesting.claim?.presentationVisible ?? true)

        XCTAssertTrue(controller.reclaimGridAuthority())
        let second = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertTrue(second.presentationVisible)
        XCTAssertEqual(
            controller.gridAuthorityPresentation,
            .reclaiming(peerName: "iPhone", awaitingConnection: false)
        )
        // While the restarted claim is visible, more taps are no-ops.
        let wire = sent.string
        XCTAssertFalse(controller.reclaimGridAuthority())
        XCTAssertEqual(sent.string, wire)

        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        ackAllPending(controller, frames: 60)
        let generation = try XCTUnwrap(repaintGenerations.last)
        completeSideChannelRepaintAndCommit(controller, generation: generation)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertTrue(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption) 'v1 \(Self.selfID) \(second.generation) iPad'"),
            "the restarted generation commits: \(sent.string)"
        )
        XCTAssertFalse(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption) 'v1 \(Self.selfID) \(first.generation) iPad'"),
            "the superseded generation never commits: \(sent.string)"
        )
    }

    /// §6.10 rule 2: a late claim advertises no new geometry. A size that
    /// hydrates after the deadline stays local; the claim completes at the
    /// grid it advertised, and the new size goes out as an ordinary owner
    /// resize once the claim has settled.
    func test_aLateClaimHoldsLocalChurnBackUntilItSettles() throws {
        let (controller, sent) = makeController(path: .sideChannel)
        var repaintGenerations: [UInt64] = []
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGenerations.append(generation)
        }
        deliverStamp(controller, value: Self.peerValue)
        controller.reclaimGridAuthority()
        controller.expireGridAuthorityReclaimPresentationForTesting()
        sent.clear()

        controller.updateClientSize(cols: 47, rows: 20)
        XCTAssertFalse(sent.string.contains("47"), "a late claim advertises no new size: \(sent.string)")
        XCTAssertEqual(
            controller.gridAuthorityLifecycleForTesting.claim?.advertisedGrids,
            [.init(columns: 92, rows: 38)]
        )

        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        ackAllPending(controller, frames: 60)
        completeSideChannelRepaintAndCommit(controller, generation: try XCTUnwrap(repaintGenerations.last))
        XCTAssertEqual(controller.gridAuthority, .mine)
        let wire = sent.string
        let stamp = try XCTUnwrap(wire.range(of: "set-option \(TmuxController.gridAuthorityOption)"), wire)
        let replay = try XCTUnwrap(wire.range(of: "refresh-client -C 47,20"), "held back, then replayed: \(wire)")
        XCTAssertGreaterThan(replay.lowerBound, stamp.lowerBound, "the replay follows the stamp: \(wire)")
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
            let body = fixtureResponseBody(controller, command: commands[responseIndex],
                otherBody: commands[responseIndex].contains("window-size") ? "smallest\r\n" : "")
            controller.ingest(Array(
                ("%begin 0 \(820 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(820 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        completeSideChannelRepaintAndCommit(
            controller,
            generation: try! XCTUnwrap(repaintGeneration)
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_inlineReclaimKeepsAuthorityVeilUntilRepaintCompletes() {
        let (controller, sent) = makeController(path: .inline)
        var deliveredSources: [RenderFeedSource] = []
        var deliveredRecords: [String] = []
        controller.renderFeedSurface = { surfaceID, owner, _, source in
            deliveredSources.append(source)
            deliveredRecords.append("\(surfaceID.rawValue):\(owner):\(source.rawValue)")
            return true
        }
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
        XCTAssertEqual(
            controller.gridAuthorityRepaintWindowTargetForTesting,
            WindowId(0)
        )
        XCTAssertTrue(
            sent.string.contains("display-message -p -t @0"),
            "settled geometry must start an authoritative capture: \(sent.string)"
        )

        // Metadata -> authoritative viewport. The lifecycle stamp must remain
        // deferred until that render-effect transaction has synchronously
        // reached the mounted surface.
        controller.ingest(Array(
            ("%begin 0 720 1\r\n"
                + renderMetadata(pane: 0)
                + "\r\n%end 0 720 1\r\n").utf8
        ))
        XCTAssertTrue(controller.gridAuthority.isPeer)
        controller.ingest(Array(
            "%begin 0 721 1\r\nauthoritative viewport\r\n%end 0 721 1\r\n".utf8
        ))

        XCTAssertEqual(
            deliveredSources,
            [.viewportRepaint],
            deliveredRecords.joined(separator: ",")
        )
        XCTAssertTrue(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"),
            "delivered inline repaint must enqueue the lifecycle stamp; target=\(String(describing: controller.gridAuthorityRepaintWindowTargetForTesting)) deliveries=\(deliveredRecords): \(sent.string)"
        )
        XCTAssertTrue(controller.gridAuthority.isPeer)
        ackAllPending(controller)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
    }

    func test_inlineReclaimStaysVeiledWhenMountedSurfaceRejectsRepaint() async {
        let (controller, sent) = makeController(path: .inline)
        controller.renderRefreshRetryDelay = 0.01
        controller.renderCommandQueueMaxWait = 0.01
        var deliveryAttempts = 0
        controller.renderFeedSurface = { _, _, _, _ in
            deliveryAttempts += 1
            return false
        }
        deliverStamp(controller, value: Self.peerValue)
        controller.updateClientSize(cols: 47, rows: 20)
        controller.reclaimGridAuthority()
        ackAllPending(controller)
        sent.clear()

        let settled = "beef,47x20,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(settled) \(settled) *\r\n".utf8
        ))
        controller.ingest(Array(
            ("%begin 0 730 1\r\n"
                + renderMetadata(pane: 0)
                + "\r\n%end 0 730 1\r\n").utf8
        ))
        controller.ingest(Array(
            "%begin 0 731 1\r\nauthoritative viewport\r\n%end 0 731 1\r\n".utf8
        ))

        XCTAssertEqual(deliveryAttempts, 1)
        XCTAssertEqual(
            controller.gridAuthorityRepaintWindowTargetForTesting,
            WindowId(0)
        )
        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertFalse(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"),
            "a rejected owner-qualified feed must not commit authority"
        )
        XCTAssertEqual(controller.gridAuthorityDeliveryRetryAttemptsForTesting, 0)
        sent.clear()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.gridAuthorityDeliveryRetryAttemptsForTesting, 1)
        XCTAssertTrue(
            sent.string.contains("display-message -p -t @0"),
            "a transient delivery rejection must schedule a bounded authoritative recapture: \(sent.string)"
        )
    }

    func test_authorityDeliveryTallyRejectsPartialDeepTransaction() {
        let owner = RenderOwner(
            windowID: WindowId(0),
            paneID: PaneId(0),
            epoch: 1
        )
        var tally = TmuxController.AuthorityDeliveryTally()

        tally.record(
            accepted: true,
            surfaceID: .live,
            owner: owner,
            source: .deepRepaint
        )
        tally.record(
            accepted: false,
            surfaceID: .live,
            owner: owner,
            source: .repaintScrub
        )

        XCTAssertEqual(tally.acceptedWindows, [WindowId(0)])
        XCTAssertEqual(tally.rejectedWindows, [WindowId(0)])
        XCTAssertTrue(
            tally.completedWindows.isEmpty,
            "one rejected constituent must fail the entire authoritative repaint transaction"
        )
    }

    func test_rejectedPaneDeliveryRetriesAccumulateIntoOneBatch() async {
        let (controller, _) = makeController(path: .inline)
        controller.renderRefreshRetryDelay = 0.01
        controller.armGridAuthorityDeliveryRetryForTesting(
            panes: [PaneId(1), PaneId(2)]
        )

        controller.scheduleGridAuthorityDeliveryRetryForTesting(
            panes: [PaneId(1)]
        )
        controller.scheduleGridAuthorityDeliveryRetryForTesting(
            panes: [PaneId(2)]
        )

        XCTAssertEqual(
            controller.gridAuthorityDeliveryRetryPaneTargetsForTesting,
            [PaneId(1), PaneId(2)]
        )
        XCTAssertEqual(controller.gridAuthorityDeliveryRetryAttemptsForTesting, 0)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            controller.gridAuthorityDeliveryRetryAttemptsForTesting,
            1,
            "two nearby pane rejections must consume one retry round"
        )
    }

    /// The pane a `-t %N` command addresses.
    private func targetPane(of command: String) -> Int? {
        let fields = command.split(separator: " ")
        guard let flag = fields.firstIndex(of: "-t"), flag + 1 < fields.count,
              fields[flag + 1].first == "%"
        else { return nil }
        return Int(fields[flag + 1].dropFirst())
    }

    private func renderMetadata(pane: Int) -> String {
        [
            "%\(pane)", "0", "0", "pane", "window", "host", "0",
            "0", "0", "19", "1", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0",
        ].joined(separator: "\t")
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

    /// D38 (shape-change half) — a split/collapse that lands after the claim's
    /// geometry settled but before its capture reached the render sink cannot
    /// be completed *or* aborted: the frame in flight describes the old
    /// surface shape, and the new shape has had no authoritative repaint. The
    /// claim must re-enter the geometry phase with targets re-armed for the
    /// shape now on screen.
    ///
    /// The window-move half is covered by
    /// `test_sideChannelWindowMoveInvalidatesRepaintAlreadyInFlight`; this
    /// pins `reconcileGridAuthorityRepaintForLayout`, which had no test, and
    /// follows the re-armed claim through the pane mounts to its stamp.
    func test_inlineClaimReArmsRepaintTargetsOnPaneGridShapeChange() async {
        let (controller, sent) = makeController(
            path: .inline,
            localCols: 100,
            localRows: 30
        )
        let single = "beef,100x30,0,0,0"
        controller.ingest(Array("%layout-change @0 \(single) \(single) *\r\n".utf8))
        controller.ingest(Array("%window-pane-changed @0 %0\r\n".utf8))
        deliverStamp(controller, value: Self.peerValue)

        controller.reclaimGridAuthority()
        var index = 0
        for _ in 0..<4 where !controller._debugPendingCommands.isEmpty {
            answerRound(controller, sent, answered: &index)
        }

        // Geometry already matches, so the claim is armed on the shared
        // (single-pane) window surface and is waiting for its repaint.
        XCTAssertEqual(controller.gridAuthorityRepaintWindowTargetForTesting, WindowId(0))
        XCTAssertTrue(controller.gridAuthorityRepaintPaneTargetsForTesting.isEmpty)
        XCTAssertTrue(controller.gridAuthority.isPeer)

        // The window splits underneath the in-flight repaint.
        let split = "cafe,100x30,0,0{50x30,0,0,0,49x30,51,0,1}"
        controller.ingest(Array("%layout-change @0 \(split) \(split) *\r\n".utf8))

        XCTAssertNil(
            controller.gridAuthorityRepaintWindowTargetForTesting,
            "the shared-window target cannot authorize a pane grid"
        )
        XCTAssertEqual(
            controller.gridAuthorityRepaintPaneTargetsForTesting,
            Set([PaneId(0), PaneId(1)]),
            "targets must be re-armed for the shape now on screen"
        )
        XCTAssertTrue(
            controller.gridAuthority.isPeer,
            "a shape change must neither complete the claim nor abort it"
        )
        // The re-armed claim confirms only once the ledger has seen the
        // split: confirming inside the layout step would capture the shared
        // window surface, which cannot paint a pane grid and would hold the
        // command FIFO ahead of the pane captures.
        XCTAssertEqual(count("capture-pane", in: sent.string), 0, sent.string)

        // Once the pane surfaces exist, the re-armed repaint paints them and
        // the claim settles on the split grid: one stamp, never a re-fence.
        controller.setPaneSink(PaneId(0)) { _ in }
        controller.setPaneSink(PaneId(1)) { _ in }
        controller.refreshPane(paneId: PaneId(0), deep: false)
        controller.refreshPane(paneId: PaneId(1), deep: false)
        let rounds = await answerUntilSettledWithTimers(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, "\(rounds)")
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 1, "no re-fence: \(sent.string)")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced ?? false, false)
        XCTAssertFalse(sent.string.contains("capture-pane -p -e -N -t @0"), sent.string)
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

    func test_acknowledgedAgentPaneInputIsWrittenWhileYielded() async {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeController(path: path, remoteStamp: Self.peerValue)
            await waitForSubscriptionFlush(controller)
            XCTAssertTrue(Self.containsAuthorityFeed(sent.string, .ownSession), "\(path): \(sent.string)")
            ackAllPending(controller, frames: 40)
            let authority = controller.gridAuthority
            sent.clear()

            let bytesTask = Task { await controller.sendInputAcknowledged([0x61], toPane: PaneId(6)) }
            for _ in 0..<20 where sent.string.isEmpty { await Task.yield() }
            XCTAssertEqual(sent.string, "send-keys -t %6 -H 61\n", "\(path)")
            ackAllPending(controller, frames: 40)
            let bytesAccepted = await bytesTask.value
            XCTAssertTrue(bytesAccepted, "\(path)")

            let beforeKey = sent.string
            let keyTask = Task { await controller.sendKeyAcknowledged(.enter, toPane: PaneId(6)) }
            for _ in 0..<20 where sent.string == beforeKey { await Task.yield() }
            XCTAssertEqual(String(sent.string.dropFirst(beforeKey.count)), "send-keys -t %6 Enter\n", "\(path)")
            ackAllPending(controller, frames: 40)
            let keyAccepted = await keyTask.value
            XCTAssertTrue(keyAccepted, "\(path)")

            let beforeGridTyping = sent.string
            controller.sendInput([0x62], toPane: PaneId(6))
            XCTAssertEqual(sent.string, beforeGridTyping, "grid typing stays gated")
            XCTAssertEqual(controller.gridAuthority, authority)
            XCTAssertTrue(sent.string.split(separator: "\n").allSatisfy {
                $0 == "send-keys -t %6 -H 61" || $0 == "send-keys -t %6 Enter" ||
                    TmuxAgentCommandAccess.isReadOnly(String($0))
            }, "only proved pane replies and reads: \(sent.string)")
        }
    }

    func test_sameGridReclaimStillRequiresAuthoritativeSideChannelRepaint() {
        let (controller, _) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        let layout = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        var repaintRequests: [Bool] = []
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { changed, generation in
            repaintRequests.append(changed)
            repaintGeneration = generation
        }

        controller.reclaimGridAuthority()
        ackAllPending(controller)

        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertEqual(repaintRequests, [false])
        completeSideChannelRepaintAndCommit(
            controller,
            generation: try! XCTUnwrap(repaintGeneration)
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_manualRefreshRequestsRepaintEvenWhenGridAlreadyMatches() {
        let (controller, _) = makeOwnerController(path: .sideChannel)
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

    /// The refresh button cannot size a window whose authority read has not
    /// resolved (D3), nor half-claim from under the veil.
    func test_manualRefreshNeverSizesWhileAuthorityIsUnresolvedOrYielded() {
        for stamp in ["", Self.peerValue] {
            let (controller, sent) = makeController(path: .sideChannel, remoteStamp: stamp)
            controller.claimActiveViewport(reason: "test-refresh", repaintEvenIfSame: true)
            ackAllPending(controller)
            assertNoGeometryOrStamp(sent.string, "refresh with stamp '\(stamp)'")
        }
    }

    func test_sideChannelRepaintRejectsStaleGeneration() {
        let (controller, sent) = makeController(path: .sideChannel)
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
        let wireBeforeStaleCompletion = sent.string
        controller.completeGridAuthoritySideChannelRepaint(
            generation: generation &+ 1
        )
        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertEqual(
            sent.string,
            wireBeforeStaleCompletion,
            "a stale repaint must not enqueue an authority stamp"
        )

        completeSideChannelRepaintAndCommit(
            controller,
            generation: generation
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_sideChannelRepaintFailureAbortsOnlyTheExactGeneration() {
        let (controller, sent) = makeController(path: .sideChannel)
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
        sent.clear()

        controller.failGridAuthoritySideChannelRepaint(generation: generation &+ 1)
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(controller.gridAuthority.isPeer)

        let failedClaim = try! XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation)
        controller.failGridAuthoritySideChannelRepaint(generation: generation)
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertGreaterThan(try! XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation), failedClaim)
        XCTAssertEqual(controller.gridAuthoritySessionForTesting.replay.count, 1)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertFalse(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"),
            "a failed repaint must never commit the claimant's stamp"
        )

        controller.completeGridAuthoritySideChannelRepaint(generation: generation)
        XCTAssertTrue(controller.gridAuthority.isPeer)
    }

    func test_sideChannelReclaimStaysYieldedWhenStampCommitFails() {
        let (controller, sent) = makeController(path: .sideChannel)
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
        sent.clear()
        controller.completeGridAuthoritySideChannelRepaint(
            generation: try! XCTUnwrap(repaintGeneration)
        )
        ackPendingGeometryQuery(controller)
        XCTAssertTrue(
            sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"),
            sent.string
        )
        let failedClaim = try! XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation)
        controller.ingest(Array(
            "%begin 0 880 1\r\nstamp rejected\r\n%error 0 880 1\r\n".utf8
        ))

        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertGreaterThan(try! XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation), failedClaim)
        XCTAssertEqual(controller.gridAuthoritySessionForTesting.replay.count, 1)
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
            let body = fixtureResponseBody(controller, command: commands[responseIndex], otherBody: commands[responseIndex].contains(
                "show-options -wA -v -t @0 window-size"
            )
                ? "smallest\r\n"
                : "")
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
        completeSideChannelRepaintAndCommit(
            controller,
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
            let body = fixtureResponseBody(controller, command: commands[responseIndex], otherBody: commands[responseIndex].contains(
                "show-options -wA -v -t @1 window-size"
            ) ? "smallest\r\n" : "")
            controller.ingest(Array(
                ("%begin 0 \(900 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(900 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        let generation = try! XCTUnwrap(repaintGeneration)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        completeSideChannelRepaintAndCommit(controller, generation: generation)
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
            let body = fixtureResponseBody(controller, command: commands[responseIndex],
                otherBody: commands[responseIndex].contains("window-size") ? "latest\r\n" : "")
            controller.ingest(Array(
                ("%begin 0 \(1_000 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(1_000 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        completeSideChannelRepaintAndCommit(
            controller,
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
            let body = fixtureResponseBody(controller, command: commands[responseIndex],
                otherBody: commands[responseIndex].contains("window-size") ? "smallest\r\n" : "")
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
            let body = fixtureResponseBody(controller, command: commands[responseIndex],
                otherBody: commands[responseIndex].contains("window-size") ? "smallest\r\n" : "")
            controller.ingest(Array(
                ("%begin 0 \(950 + responseIndex) 1\r\n"
                    + body
                    + "%end 0 \(950 + responseIndex) 1\r\n").utf8
            ))
            responseIndex += 1
        }

        let currentGeneration = try! XCTUnwrap(repaintGenerations.last)
        XCTAssertNotEqual(currentGeneration, staleGeneration)
        completeSideChannelRepaintAndCommit(
            controller,
            generation: currentGeneration
        )
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    func test_sideChannelReclaimKeepsForceAndAddsTargetlessLatestFence() {
        let (controller, sent) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        sent.clear()
        controller.reclaimGridAuthority()
        let wire = sent.string
        XCTAssertTrue(wire.contains("resize-window -x 92 -y 38 -t @0"), wire)
        XCTAssertTrue(wire.contains("\nselect-window\nset-option -w -u"), wire)
        XCTAssertFalse(wire.contains("select-window -t"), wire)
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

    /// A fence reply that outlived its claim (here a contest) acknowledges
    /// nothing: no later confirmation can stand on it.
    func test_aFenceReplyAfterTheClaimEndedAcknowledgesNothing() {
        let (controller, sent) = makeController(path: .inline, remoteStamp: Self.peerValue)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertTrue(controller.reclaimGridAuthority())
        XCTAssertTrue(sent.string.contains("select-window"), sent.string)
        deliverStamp(controller, value: "v1 PEER-DEVICE-9999 4 iPhone")
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        var index = 0
        let answered = answerRound(controller, sent, answered: &index)
        XCTAssertTrue(answered.contains("select-window"), "\(answered)")
        XCTAssertFalse(controller.gridAuthorityClaimFenceAcknowledgedForTesting, sent.string)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        XCTAssertTrue(controller.reclaimGridAuthority())
        XCTAssertFalse(controller.gridAuthorityClaimFenceAcknowledgedForTesting,
                       "the next claim still needs its own fence")
    }

    /// The own-write-won race (T4 follow-up): a user claim committed its
    /// stamp, a foreign stamp contested it, and then our already-queued write
    /// echoed after it. Re-enter the full fence under a fresh generation.
    func test_ownWriteEchoAfterAContestReentersTheFencedClaim() throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in
            repaintGeneration = generation
        }
        XCTAssertTrue(controller.reclaimGridAuthority())
        let first = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim)
        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        controller.completeGridAuthoritySideChannelRepaint(generation: try XCTUnwrap(repaintGeneration))
        ackPendingGeometryQuery(controller)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingStampCommit)
        XCTAssertTrue(sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"), sent.string)

        deliverStamp(controller, value: "v1 PEER-DEVICE-9999 4 iPhone")
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))

        deliverStamp(controller, value: selfValue(gen: Int(first.generation)))
        let restarted = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(restarted.reason, .ownWriteWon)
        XCTAssertGreaterThan(restarted.generation, first.generation)
        XCTAssertTrue(controller.gridAuthority.isPeer, "an echo alone never lifts the veil")
        XCTAssertEqual(
            controller.gridAuthorityPresentation,
            .reclaiming(peerName: "iPhone", awaitingConnection: false)
        )
    }

    func test_reconnectReadsInsteadOfStealing() {
        let (controller, sent) = makeOwnerController(path: .sideChannel)
        // Drop while owning — the exact shape of the seize bug: a takeover
        // can happen during any gap.
        controller.sideChannelDisconnected()
        sent.clear()

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))
        XCTAssertTrue(sent.string.contains(Self.authorityRead), sent.string)
        controller.updateClientSize(cols: 100, rows: 40)
        assertNoGeometryOrStamp(sent.string, "reconnect must not size before its read")

        // The read says the iPhone took over during our gap → yield.
        fixture(controller).authorityStamp = Self.peerValue
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        assertNoGeometryOrStamp(sent.string, "a yielded reconnect never replays size")
        XCTAssertFalse(sent.string.contains("list-clients"), "no peer-presence proof: \(sent.string)")
    }

    /// A reconnect while yielded never claims, whatever the read returns.
    func test_yieldedReconnectNeverClaims() {
        for stamp in ["", selfValue()] {
            let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
            controller.sideChannelDisconnected()
            XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
            sent.clear()

            fixture(controller).authorityStamp = stamp
            controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
            controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
            controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))
            ackAllPending(controller, frames: 40)

            XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "stamp '\(stamp)'")
            if stamp.isEmpty {
                // Nobody holds the grid any more: a bare client-size
                // advertisement only (M3), never a claim's stamp or force.
                assertNoClaimGeometryOrStamp(sent.string, "yielded reconnect reading ''")
            } else {
                assertNoGeometryOrStamp(sent.string, "yielded reconnect reading '\(stamp)'")
            }
        }
    }

    /// `.mine` over a foreign-sized window: some stamp-less client sized it
    /// during our gap. Veil as "another device" without claiming, and keep
    /// the stale reconnect layout from raising a fallback mid-read.
    func test_reconnectOwnStampOverForeignGeometryYieldsToAnotherDevice() {
        let (controller, sent) = makeOwnerController(path: .sideChannel)
        controller.sideChannelDisconnected()
        sent.clear()

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))

        let stale = "beef,120x40,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(stale) \(stale) *\r\n".utf8
        ))
        XCTAssertFalse(
            controller.gridAuthority.isPeer,
            "stale reconnect geometry must wait for the authoritative read"
        )

        fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 120, rows: 40)
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: TmuxStamplessPeer.displayName))
        XCTAssertEqual(
            controller.gridAuthorityPresentation,
            .veiled(peerName: TmuxStamplessPeer.displayName)
        )
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        assertNoGeometryOrStamp(sent.string, "our stamp over a foreign grid must not claim")
    }

    /// The window kept the size we last pushed but our grid changed during
    /// the gap: one ordinary replay with no claim and no stamp.
    func test_reconnectOwnStampAtLastOwnedSizeReplaysOwnedGeometry() {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.reset()
        controller.updateClientSize(cols: 100, rows: 40)
        sent.clear()

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n%window-add @0\r\n".utf8))
        controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))
        assertNoGeometryOrStamp(sent.string, "attach waits for its read")
        ackAllPending(controller, frames: 40)

        XCTAssertTrue(sent.string.contains("refresh-client -C 100,40"), sent.string)
        XCTAssertFalse(sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"), sent.string)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertFalse(controller.gridAuthorityGeometryHeldForTesting)
    }

    func test_sessionSwitchDropsPriorSessionAuthorityAndRederives() {
        let (controller, sent) = makeController(path: .sideChannel)
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        sent.clear()

        controller.ingest(Array("%session-changed $1 other\r\n".utf8))

        XCTAssertEqual(controller.gridAuthority, .unknown)
        XCTAssertTrue(sent.string.contains(Self.authorityRead), sent.string)
        XCTAssertFalse(
            sent.string.contains("refresh-client -C"),
            "a session switch must re-derive before sizing: \(sent.string)"
        )
    }

    /// §6.18: a switch resets the session and the hydration attaches it
    /// again, so the new session is read exactly once, and an unstamped one
    /// does not inherit the old session's peer or its veil.
    func test_sessionSwitchReadsTheNewSessionOnceAndForgetsTheOldPeer() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeController(path: path)
            deliverStamp(controller, value: Self.peerValue)
            XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"), "\(path)")
            fixture(controller).authorityStamp = ""
            sent.clear()

            controller.ingest(Array("%session-changed $1 other\r\n".utf8))
            XCTAssertEqual(controller.gridAuthority, .unknown, "\(path)")
            ackAllPending(controller, frames: 40)

            XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, "\(path): \(sent.string)")
            XCTAssertFalse(controller.gridAuthority.isPeer, "\(path): \(controller.gridAuthority)")
            XCTAssertNotEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"), "\(path)")
        }
    }

    func test_reclaimWithoutPeerIsANoOp() {
        let (controller, sent) = makeController()
        XCTAssertFalse(controller.reclaimGridAuthority())
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        XCTAssertFalse(sent.string.contains(TmuxController.gridAuthorityOption))
    }

    // MARK: - Stamp-less fallback (bare tmux attach)

    func test_foreignLayoutSizeFallsBackToGenericPeer() {
        let (controller, _) = makeOwnerController()
        // The steady-owner fixture has passed attach's advertisement echo.
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

    /// While the attach read is unresolved this device is not sizing the
    /// window, so a foreign layout proves nothing.
    func test_foreignLayoutWhileAuthorityIsUnresolvedDoesNotRaiseAPeer() {
        let (controller, _) = makeController()
        controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
        let layout = "beef,120x40,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        XCTAssertEqual(controller.gridAuthority, .unknown)
    }

    /// A foreign layout inside our own replay's echo window is a verdict put
    /// off, not given: it is judged again once the window ends, as Android
    /// does (`scheduleStamplessPeerRejudge`), or a laptop that resized
    /// right after our replay is never seen.
    func test_aForeignLayoutInsideOurReplayEchoIsJudgedWhenTheEchoEnds() {
        let (controller, sent) = makeOwnerController()
        controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
        controller.updateClientSize(cols: 92, rows: 30)
        XCTAssertTrue(sent.string.contains("refresh-client -C 92,30"), sent.string)
        let foreign = "beef,120x40,0,0,0"
        controller.ingest(Array("%layout-change @0 \(foreign) \(foreign) *\r\n".utf8))
        XCTAssertEqual(controller.gridAuthority, .mine, "inside the echo window")
        XCTAssertTrue(controller.stamplessPeerRejudgePendingForTesting)
        controller.finishStamplessPeerEchoForTesting()
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: TmuxStamplessPeer.displayName))
        XCTAssertFalse(controller.stamplessPeerRejudgePendingForTesting)
    }

    /// Only the layout put off is judged again: our own echo, arriving after
    /// it, is judged on its own, and the window is ours.
    func test_aLaterLayoutSupersedesTheDeferredJudgement() {
        let (controller, _) = makeOwnerController()
        controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
        controller.updateClientSize(cols: 92, rows: 30)
        let foreign = "beef,120x40,0,0,0"
        controller.ingest(Array("%layout-change @0 \(foreign) \(foreign) *\r\n".utf8))
        XCTAssertTrue(controller.stamplessPeerRejudgePendingForTesting)
        let echo = "beef,92x30,0,0,0"
        controller.ingest(Array("%layout-change @0 \(echo) \(echo) *\r\n".utf8))
        XCTAssertTrue(controller.stamplessPeerRejudgePendingForTesting,
                      "the shared judge retains its deferred record until the wake")
        controller.finishStamplessPeerEchoForTesting()
        XCTAssertFalse(controller.stamplessPeerRejudgePendingForTesting)
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    /// The deferred judgement belongs to its connection.
    func test_aDeferredJudgementDiesWithItsConnection() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makeOwnerController(path: path)
            controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
            controller.updateClientSize(cols: 92, rows: 30)
            let foreign = "beef,120x40,0,0,0"
            controller.ingest(Array("%layout-change @0 \(foreign) \(foreign) *\r\n".utf8))
            XCTAssertTrue(controller.stamplessPeerRejudgePendingForTesting)
            if path == .inline { controller.reset() }
            else { controller.sideChannelDisconnected() }
            XCTAssertFalse(controller.stamplessPeerRejudgePendingForTesting)
            controller.finishStamplessPeerEchoForTesting()
            XCTAssertFalse(controller.gridAuthority.isPeer)
        }
    }

    /// Even a callback retained across a connection boundary cannot judge
    /// the replacement connection's otherwise identical window and grid.
    func test_aDeferredJudgementRejectsADifferentConnectionGeneration() {
        let (controller, _) = makeOwnerController()
        controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
        controller.updateClientSize(cols: 92, rows: 30)
        let foreign = "beef,120x40,0,0,0"
        controller.ingest(Array("%layout-change @0 \(foreign) \(foreign) *\r\n".utf8))
        XCTAssertTrue(controller.stamplessPeerRejudgePendingForTesting)
        controller.advanceControlConnectionGenerationForTesting()
        controller.finishStamplessPeerEchoForTesting()
        XCTAssertEqual(controller.gridAuthority, .unknown)
    }

    /// A newer foreign layout must get its own deferred verdict; the old
    /// callback's dimensions cannot decide for it.
    func test_aNewerForeignLayoutGetsItsOwnDeferredJudgement() {
        let (controller, _) = makeOwnerController()
        controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
        controller.updateClientSize(cols: 92, rows: 30)
        for foreign in ["beef,120x40,0,0,0", "beef,130x45,0,0,0"] {
            controller.ingest(Array("%layout-change @0 \(foreign) \(foreign) *\r\n".utf8))
            XCTAssertTrue(controller.stamplessPeerRejudgePendingForTesting)
        }
        controller.finishStamplessPeerEchoForTesting()
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: TmuxStamplessPeer.displayName))
        XCTAssertFalse(controller.stamplessPeerRejudgePendingForTesting)
    }

    func test_delayedOwnEchoAfterForeignLayoutCannotBypassReclaimFence() {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
        let foreign = "beef,122x39,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(foreign) \(foreign) *\r\n".utf8
        ))
        XCTAssertEqual(
            controller.gridAuthority,
            .peer(displayName: "another device")
        )

        // This is the echo of a local size/stamp write that was queued before
        // the bare tmux client changed the layout. It must not silently turn
        // the controller authoritative without the latest-client fence.
        deliverStamp(controller, value: selfValue(gen: 69))
        XCTAssertEqual(
            controller.gridAuthority,
            .peer(displayName: "another device")
        )
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)

        sent.clear()
        controller.updateClientSize(cols: 166, rows: 54)
        XCTAssertFalse(sent.string.contains("refresh-client -C"), sent.string)

        controller.reclaimGridAuthority()
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(sent.string.contains("refresh-client -C 166,54"), sent.string)
        XCTAssertTrue(sent.string.contains("show-options -wA -v -t @0 window-size"), sent.string)
        XCTAssertTrue(sent.string.hasSuffix("\nselect-window\n"), sent.string)
    }

    func test_policyProbeRechecksLayoutThatArrivedWhilePolicyWasUnknown() {
        let (controller, sent) = makeOwnerController()
        controller.ingest(Array("%window-add @1\r\n%window-renamed @1 logs\r\n".utf8))
        ackAllPending(controller)
        fixture(controller).foreignClientWindows.insert(WindowId(1))
        sent.clear()
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        XCTAssertTrue(sent.string.contains("show-options -wA -v -t @1 window-size"), sent.string)
        let foreign = "beef,120x40,0,0,0"
        controller.ingest(Array("%layout-change @1 \(foreign) \(foreign) *\r\n".utf8))
        XCTAssertFalse(controller.gridAuthority.isPeer)
        ackAllPending(controller, frames: 80)
        XCTAssertTrue(sent.string.contains("list-clients -F "), sent.string)
        assertNoWindowForce(sent.string)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "another device"))
    }

    func test_matchingLayoutSizeDoesNotTrigger() {
        let (controller, _) = makeOwnerController()
        let layout = "beef,92x38,0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
        XCTAssertEqual(controller.gridAuthority, .mine)
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

    /// Only the session's claim fences. A controller that takes no part in
    /// authority (no identity, a harness) refreshes as a repaint as well:
    /// no geometry, `latest` fence or stamp.
    func test_aNonParticipantsRefreshIsARepaintOnly() {
        let (controller, sent) = makeController(path: .inline, identity: nil)
        controller.claimActiveViewport(reason: "forceRefresh", repaintEvenIfSame: true)
        ackAllPending(controller, frames: 40)
        assertNoGeometryOrStamp(sent.string, "non-participant refresh")
        XCTAssertFalse(sent.string.contains("window-size"), sent.string)
        XCTAssertTrue(sent.string.contains("#{cursor_x}"), "refresh repaints: \(sent.string)")
        XCTAssertNil(controller.gridAuthoritySessionForTesting.claimFence)
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

// MARK: - Phase 0a review regressions

extension GridAuthorityTests {
    // MARK: H1: the R3 clock runs from the user's step

    /// A show made before the first attach expires on the R3 clock like any
    /// other; it must not claim whenever the channel finally attaches.
    func test_showIntentExpiresFromTheUserStepEvenBeforeTheFirstAttach() async throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue, attach: false,
                                                authorityConfiguration: .init(intentWindowMillis: 50))
        controller.gridAuthorityShown()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent,
                     "the intent outlived its R3 window before the first attach")
        controller.ingest(Array(Self.handshake.utf8))
        ackAllPending(controller, frames: 40)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "stale show claimed at first attach: \(sent.string)")
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        assertNoGeometryOrStamp(sent.string, "an expired show is a plain attach")
    }

    /// A show carried to a replacement controller keeps the window it has
    /// left; one that already used it up records nothing.
    func test_carriedShowKeepsOnlyTheRemainingIntentWindow() async throws {
        let (fresh, _) = makeController(path: .sideChannel, remoteStamp: Self.peerValue, attach: false)
        fresh.gridAuthorityShown()
        let elapsed = try XCTUnwrap(fresh.gridAuthorityIntentElapsed)
        XCTAssertLessThan(elapsed, 1)
        fresh.setGridAuthorityIntentClockPaused(true)
        XCTAssertEqual(fresh.gridAuthorityIntentElapsed, 0, "a prompt restarts the full window when answered")

        let (carried, _) = makeController(path: .sideChannel, remoteStamp: Self.peerValue, attach: false,
                                          authorityConfiguration: .init(intentWindowMillis: 1_000))
        carried.gridAuthorityShown(intentElapsed: 0.9)
        XCTAssertNotNil(carried.gridAuthorityLifecycleForTesting.pendingIntent)
        let carriedElapsed = try XCTUnwrap(carried.gridAuthorityIntentElapsed)
        XCTAssertGreaterThanOrEqual(carriedElapsed, 0.85)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(carried.gridAuthorityLifecycleForTesting.pendingIntent,
                     "the replacement restarted the window instead of continuing it")

        let (expired, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue,
                                             authorityConfiguration: .init(intentWindowMillis: 1_000))
        expired.gridAuthorityShown(intentElapsed: 1.5)
        XCTAssertNil(expired.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertFalse(sent.string.contains(Self.authorityRead), sent.string)
    }

    // MARK: H2: one authority source

    /// A no-intent read finding no readable stamp leaves the fallback for
    /// `.unknown`. The runtime must follow it too, or P7/P8 still decide as
    /// yielded while the UI veils nobody.
    func test_aNoStampReadRetiresTheRuntimeStamplessFallback() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            for stamp in ["", "nobody's unreadable stamp"] {
                let (controller, sent) = makeController(
                    path: path, remoteStamp: selfValue(),
                    remoteGrid: FixtureGrid(columns: 120, rows: 40)
                )
                XCTAssertEqual(controller.snapshot.authority, .peer(
                    deviceID: "-", displayName: TmuxStamplessPeer.displayName, generation: 0
                ))
                fixture(controller).authorityStamp = stamp
                controller.prepareForAppInactivity()
                controller.refreshActiveWindowOnForeground()
                ackAllPending(controller, frames: 40)
                let expected: TmuxGridAuthoritySnapshot = stamp.isEmpty ? .unknown : .peer(
                    deviceID: "-", displayName: TmuxStamplessPeer.displayName, generation: 0
                )
                XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.authority, expected)
                XCTAssertEqual(controller.gridAuthorityPresentation, stamp.isEmpty ? .none : .veiled(peerName: TmuxStamplessPeer.displayName))
                XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
                XCTAssertEqual(controller.snapshot.authority, expected, "\(path) stamp='\(stamp)'")
                assertNoClaimGeometryOrStamp(sent.string, "a no-intent read never claims")
            }
        }
    }

    /// The fresh read decides for both policy and rendering: there is only
    /// one verdict, including when the server option has been removed.
    func test_aNoStampReadProjectsTheSharedUnknownVerdict() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makeController(path: path, remoteStamp: Self.peerValue)
            let peer = controller.snapshot.authority
            XCTAssertTrue(peer.isPeer)
            fixture(controller).authorityStamp = ""
            controller.prepareForAppInactivity()
            controller.refreshActiveWindowOnForeground()
            ackAllPending(controller, frames: 40)
            XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.authority, .unknown)
            XCTAssertEqual(controller.snapshot.authority, .unknown)
        }
    }

    func test_anEmptySubscriptionDuringADisconnectKeepsTheSharedPeer() {
        let (controller, _) = makeController(
            path: .sideChannel, remoteStamp: selfValue(),
            remoteGrid: FixtureGrid(columns: 120, rows: 40)
        )
        let peer = controller.snapshot.authority
        XCTAssertTrue(peer.isPeer)
        controller.sideChannelDisconnected()
        XCTAssertFalse(controller.gridAuthorityLifecycleForTesting.channelAttached)
        controller.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : \r\n".utf8))
        XCTAssertEqual(controller.snapshot.authority, peer)
    }

    func test_anEmptySubscriptionDuringAClaimKeepsTheSharedPeer() {
        let (controller, _) = makeController(
            path: .inline, remoteStamp: selfValue(),
            remoteGrid: FixtureGrid(columns: 120, rows: 40)
        )
        let peer = controller.snapshot.authority
        XCTAssertTrue(peer.isPeer)
        XCTAssertTrue(controller.reclaimGridAuthority())
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
        controller.ingest(Array("%subscription-changed tessera-authority $0 @0 0 %0 : \r\n".utf8))
        XCTAssertEqual(controller.snapshot.authority, peer)
    }

    /// Both kinds of debt are paid by the read itself: P7's missed relayout
    /// starts a visible rebuild, and P8's already-painted rebuild deepens.
    /// Neither waits for another layout or a claim to settle.
    func test_aNoStampReadReleasesFallbackRelayoutAndHistoryWork() {
        for debtIsDeepening in [false, true] {
            let (controller, sent) = makeOwnerController(path: .inline)
            controller.ingest(Array("%window-pane-changed @0 %0\r\n".utf8))
            let feeds = FeedLog()
            controller.renderFeedSurface = { _, _, _, source in
                feeds.sources.append(source)
                return true
            }
            controller.submitRenderFact(.refreshRequested(.live, stage: .deep, reason: "test-paint"))
            answerWire(controller, sent, authority: selfValue())
            XCTAssertFalse(feeds.sources.isEmpty, "the surface must have painted before yielding")
            feeds.sources.removeAll()
            sent.clear()
            let foreign = "beef,120x40,0,0,0"
            fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 120, rows: 40)
            controller.ingest(Array("%layout-change @0 \(foreign) \(foreign) *\r\n".utf8))
            XCTAssertEqual(controller.snapshot.authority, .peer(
                deviceID: "-", displayName: TmuxStamplessPeer.displayName, generation: 0
            ))
            let moved = "beef,130x45,0,0,0"
            fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 130, rows: 45)
            controller.ingest(Array("%layout-change @0 \(moved) \(moved) *\r\n".utf8))
            if debtIsDeepening {
                // The visible rebuild can paint under the fallback, as a
                // take-back's repaint does, but its history waits.
                controller.submitRenderFact(.correlatedRefreshRequested(
                    .live, stage: .viewport, reason: "test-fallback-visible", correlation: 9
                ))
                answerWire(controller, sent, authority: selfValue())
                XCTAssertEqual(feeds.sources, [.viewportRepaint])
                XCTAssertFalse(sent.string.contains("capture-pane -p -e -N -S -"), sent.string)
            } else {
                XCTAssertFalse(sent.string.contains("#{cursor_x}"), sent.string)
                XCTAssertFalse(sent.string.contains("capture-pane"), sent.string)
            }
            XCTAssertTrue(controller.snapshot.authority.isPeer)
            fixture(controller).authorityStamp = ""
            sent.clear()
            controller.rereadGridAuthorityForTesting()
            // Answer only the read; anything it releases must be on the
            // writer now, without another event giving the ledger authority.
            var index = 0
            let first = answerRound(controller, sent, answered: &index, authority: "")
            XCTAssertTrue(first.contains(Self.authorityRead), "\(first)")
            XCTAssertEqual(controller.snapshot.authority, .unknown)
            let released = Array(sent.string.split(separator: "\n").dropFirst(index)).map(String.init)
            XCTAssertTrue(released.contains(where: isMetadataQuery), "deepen=\(debtIsDeepening): \(released)")
            answerWire(controller, sent, from: index, authority: "")
            XCTAssertTrue(sent.string.contains("capture-pane -p -e -N -S -"), sent.string)
            if !debtIsDeepening {
                XCTAssertTrue(feeds.sources.contains(.viewportRepaint), "\(feeds.sources)")
            }
            XCTAssertTrue(feeds.sources.contains(.deepRepaint), "\(feeds.sources)")
            XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
            assertNoClaimGeometryOrStamp(sent.string, "released work is read-only")
        }
    }

    /// A fresh read resolving `.mine` (R2, or a no-intent read at our size)
    /// must also retire the runtime's stamp-less fallback; otherwise the
    /// next snapshot re-projects "another device" and every owner resize,
    /// ⌘R and Agent Center send is refused as yielded.
    func test_freshOwnReadRetiresTheRuntimeFallbackEverywhere() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            for viaShow in [true, false] {
                let tag = "\(path) show=\(viaShow)"
                let (controller, sent) = makeController(
                    path: path, remoteStamp: selfValue(), remoteGrid: FixtureGrid(columns: 120, rows: 40)
                )
                var repaints = 0
                controller.onGridAuthoritySideChannelRepaintRequired = { _, _ in repaints += 1 }
                XCTAssertEqual(controller.gridAuthority, .peer(displayName: TmuxStamplessPeer.displayName), tag)
                fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
                let mine = "beef,92x38,0,0,0"
                controller.ingest(Array("%layout-change @0 \(mine) \(mine) *\r\n".utf8))
                if viaShow {
                    controller.gridAuthorityShown()
                } else {
                    controller.prepareForAppInactivity()
                    controller.refreshActiveWindowOnForeground()
                }
                ackAllPending(controller, frames: 40)
                XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.authority, .mine(generation: 1), tag)
                XCTAssertEqual(controller.gridAuthorityPresentation, .none, tag)
                XCTAssertFalse(controller.gridAuthorityGeometryHeldForTesting, "\(tag): hold released")
                XCTAssertEqual(controller.gridAuthority, .mine, "\(tag): adapter projection disagrees with the reducer")
                assertAuthorityProjectionMatchesReducer(controller, tag)
                XCTAssertTrue(controller.gridAuthorityAllowsInput, tag)
                XCTAssertFalse(controller.gridAuthorityRefusesAgentSend, tag)

                ackAllPending(controller, frames: 40)
                sent.clear()
                controller.updateClientSize(cols: 92, rows: 30)
                XCTAssertTrue(sent.string.contains("refresh-client -C 92,30"), "\(tag): owner resize swallowed: '\(sent.string)'")
                answerWire(controller, sent, authority: selfValue())
                sent.clear()
                controller.claimActiveViewport(reason: "forceRefresh")
                if path == .inline {
                    XCTAssertTrue(sent.string.contains("#{cursor_x}"), "\(tag): ⌘R repaint inert: '\(sent.string)'")
                } else {
                    XCTAssertEqual(repaints, 1, "\(tag): ⌘R repaint inert")
                }
                assertNoClaimGeometryOrStamp(sent.string, "\(tag): ⌘R is a repaint only")
            }
        }
    }

    /// A show over the stamp-less fallback settles to `.mine` on both paths,
    /// and a later stamp-less takeover is raised again.
    func test_showOverTheStamplessFallbackSettlesAndALaterTakeoverReraises() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            do {
                let (controller, sent) = makeController(
                    path: path, remoteStamp: selfValue(), remoteGrid: FixtureGrid(columns: 120, rows: 40)
                )
                var repaintGeneration: UInt64?
                controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in repaintGeneration = generation }
                controller.gridAuthorityShown()
                let settled = "beef,92x38,0,0,0"
                if path == .inline {
                    // Answer the wire as tmux would (render metadata and
                    // captures included) so the inline repaint completes.
                    var index = answerWire(controller, sent, authority: selfValue())
                    XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "\(path) A: show claims")
                    XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim?.contestedPeer, "\(path) A: our stamp")
                    fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
                    controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
                    index = answerWire(controller, sent, from: index, authority: selfValue())
                    _ = index
                } else {
                    ackAllPending(controller, frames: 1)
                    XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "\(path) A: show claims")
                    XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim?.contestedPeer, "\(path) A: our stamp")
                    fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
                    controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
                    for _ in 0..<40 { ackAllPending(controller, frames: 1) }
                    if let generation = repaintGeneration {
                        completeSideChannelRepaintAndCommit(controller, generation: generation)
                    }
                }
                XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "\(path) A: claim outstanding")
                XCTAssertEqual(controller.gridAuthority, .mine, "\(path) A")
                XCTAssertEqual(controller.gridAuthorityPresentation, .none, "\(path) A")
                assertAuthorityProjectionMatchesReducer(controller, "\(path) A")
            }
            do {
                let (controller, _) = makeController(
                    path: path, remoteStamp: selfValue(), remoteGrid: FixtureGrid(columns: 120, rows: 40)
                )
                fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
                let mine = "beef,92x38,0,0,0"
                controller.ingest(Array("%layout-change @0 \(mine) \(mine) *\r\n".utf8))
                controller.gridAuthorityShown()
                ackAllPending(controller, frames: 40)
                XCTAssertEqual(controller.gridAuthorityPresentation, .none, "\(path) B precondition")
                let laptop = "cafe,130x45,0,0,0"
                fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 130, rows: 45)
                controller.ingest(Array("%layout-change @0 \(laptop) \(laptop) *\r\n".utf8))
                ackAllPending(controller, frames: 40)
                XCTAssertEqual(
                    controller.gridAuthorityPresentation,
                    .veiled(peerName: TmuxStamplessPeer.displayName),
                    "\(path) B: fresh stamp-less takeover swallowed"
                )
                assertAuthorityProjectionMatchesReducer(controller, "\(path) B")
            }
        }
    }

    /// Invariant: after every event, `gridAuthority` is the projection of the
    /// reducer's authority, whichever source (reads, live stamps, the
    /// stamp-less fallback, claims, resets) moved it.
    func test_gridAuthorityAlwaysEqualsTheReducerProjection() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makeController(
                path: path, remoteStamp: selfValue(), remoteGrid: FixtureGrid(columns: 120, rows: 40)
            )
            var repaintGeneration: UInt64?
            controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in repaintGeneration = generation }
            func check(_ step: String) { assertAuthorityProjectionMatchesReducer(controller, "\(path) \(step)") }
            check("attach over a foreign grid")
            controller.gridAuthorityShown()
            ackAllPending(controller, frames: 1)
            check("show claims")
            fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
            let settled = "beef,92x38,0,0,0"
            controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
            check("claim geometry settled")
            for _ in 0..<40 { ackAllPending(controller, frames: 1) }
            if path == .sideChannel, let generation = repaintGeneration {
                completeSideChannelRepaintAndCommit(controller, generation: generation)
            }
            check("claim repaint")
            deliverStamp(controller, value: Self.peerValue)
            check("peer stamp")
            deliverStamp(controller, value: selfValue(gen: 7))
            check("replayed own echo")
            controller.updateClientSize(cols: 60, rows: 30)
            check("yielded resize")
            controller.prepareForAppInactivity()
            controller.refreshActiveWindowOnForeground()
            fixture(controller).authorityStamp = selfValue(gen: 7)
            ackAllPending(controller, frames: 40)
            check("foreground read")
            controller.reset()
            check("reset")
            controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
            controller.ingest(Array("%session-changed $0 dev\r\n%window-add @0\r\n".utf8))
            controller.ingest(Array(Self.handshake.utf8))
            check("reattach before the read")
            ackAllPending(controller, frames: 40)
            check("reattach read")
        }
    }

    // MARK: M1 / D9: ⌘R is a repaint

    func test_manualRefreshOutsideAClaimNeverStampsOrFences() {
        let (controller, sent) = makeOwnerController(path: .inline)
        sent.clear()
        controller.claimActiveViewport(reason: "forceRefresh", repaintEvenIfSame: true)
        assertNoGeometryOrStamp(sent.string, "⌘R outside the reducer")
        XCTAssertTrue(sent.string.contains("#{cursor_x}"), "⌘R repaints: \(sent.string)")
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        sent.clear()
        controller.updateClientSize(cols: 47, rows: 20)
        assertNoGeometryOrStamp(sent.string, "yielded size change after ⌘R")
        controller.claimActiveViewport(reason: "forceRefresh", repaintEvenIfSame: true)
        assertNoGeometryOrStamp(sent.string, "⌘R while yielded")
    }

    /// A peer resizing the window right after ⌘R cannot leave claim
    /// bookkeeping behind that seizes the grid on every later resize.
    func test_manualRefreshContestCannotLeaveAClaimThatSeizesLaterResizes() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeOwnerController(path: path)
            controller.claimActiveViewport(reason: "forceRefresh", repaintEvenIfSame: true)
            deliverStamp(controller, value: Self.peerValue)
            fixture(controller).grids[WindowId(0)] = Self.peerGrid
            let peerLayout = "beef,105x31,0,0,0"
            controller.ingest(Array("%layout-change @0 \(peerLayout) \(peerLayout) *\r\n".utf8))
            ackAllPending(controller, frames: 40)
            XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"), "\(path)")
            sent.clear()
            controller.updateClientSize(cols: 60, rows: 30)
            ackAllPending(controller, frames: 40)
            assertNoGeometryOrStamp(sent.string, "\(path): veiled device resized after ⌘R")
        }
    }

    // MARK: M2: no veil on a hidden session

    /// Resume: the hide edge lands first (S2′), then the buffered peer line
    /// and the foreground read. The session shows `.resuming` until its
    /// show decides, never the veil (which would also take first responder).
    func test_hiddenSessionShowsResumingUntilItsShowDecides() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makeOwnerController(path: path)
            controller.prepareForAppInactivity()
            controller.gridAuthorityHidden()
            deliverStamp(controller, value: Self.peerValue)
            controller.refreshActiveWindowOnForeground()
            fixture(controller).authorityStamp = Self.peerValue
            ackAllPending(controller, frames: 1)
            XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"), "\(path)")
            XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false), "\(path)")
            XCTAssertFalse(controller.gridAuthorityAllowsInput, "\(path)")
            controller.gridAuthorityShown()
            XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false), "\(path)")
            ackAllPending(controller, frames: 40)
            XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "\(path): the show claims")
            XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false), "\(path)")
        }
    }

    /// A controller that never receives show-rule edges (harnesses) keeps
    /// drawing the veil.
    func test_sessionNeverHiddenStillDrawsTheVeil() {
        let (controller, _) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        controller.gridAuthorityHidden()
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false))
    }

    // MARK: M3: an unstamped session is not pinned at 80x24

    func test_unstampedReconnectReleasesABareClientSizeOnly() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeOwnerController(path: path)
            controller.reset()
            fixture(controller).authorityStamp = ""
            fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 80, rows: 24)
            controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
            controller.ingest(Array("%session-changed $0 dev\r\n%window-add @0\r\n".utf8))
            controller.ingest(Array("%begin 200 1 0\r\n%end 200 1 0\r\n".utf8))
            ackAllPending(controller, frames: 40)
            XCTAssertTrue(sent.string.contains("refresh-client -C 92,38"), "\(path): unstamped never sized: \(sent.string)")
            sent.clear()
            controller.updateClientSize(cols: 100, rows: 40)
            controller.claimActiveViewport(reason: "forceRefresh", repaintEvenIfSame: true)
            controller.prepareForAppInactivity()
            controller.refreshActiveWindowOnForeground()
            ackAllPending(controller, frames: 40)
            XCTAssertEqual(controller.gridAuthorityPresentation, .none, "\(path)")
            XCTAssertTrue(controller.gridAuthorityAllowsInput, "\(path)")
            XCTAssertTrue(sent.string.contains("refresh-client -C 100,40"), "\(path): \(sent.string)")
            assertNoClaimGeometryOrStamp(sent.string, "\(path): unstamped ordinary geometry")
            XCTAssertEqual(controller.gridAuthority, .unknown, "\(path): no stamp means nobody's")
        }
    }

    // MARK: M5: slow hydration is not a stamp-less peer

    func test_slowHydrationHoldsTheOwnStampReplyInsteadOfVeiling() async throws {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeController(
                path: path, remoteStamp: selfValue(), remoteGrid: FixtureGrid(columns: 92, rows: 38), attach: false
            )
            XCTAssertGreaterThanOrEqual(controller.gridAuthorityGeometryEvidenceTimeout, 10)
            controller.ingest(Array(Self.handshake.utf8))
            let pending = controller._debugPendingCommands
            let readIndex = try XCTUnwrap(pending.firstIndex { $0.hasPrefix(Self.authorityRead) })
            let listIndex = try XCTUnwrap(pending.firstIndex { $0.hasPrefix("list-windows") })
            XCTAssertLessThan(readIndex, listIndex, "\(path): read precedes hydration")
            ackAllPending(controller, frames: readIndex + 1)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertTrue(controller.gridAuthorityHasHeldReplyForTesting, "\(path)")
            XCTAssertNotEqual(controller.gridAuthorityPresentation, .veiled(peerName: TmuxStamplessPeer.displayName), "\(path)")
            ackAllPending(controller, frames: 40)
            XCTAssertEqual(controller.gridAuthorityPresentation, .none, "\(path): after hydration")
            XCTAssertEqual(controller.gridAuthority, .mine, "\(path)")
            controller.gridAuthorityShown()
            ackAllPending(controller, frames: 40)
            XCTAssertEqual(controller.gridAuthorityPresentation, .none, "\(path): after show")
            XCTAssertEqual(controller.gridAuthority, .mine, "\(path): after show")
            sent.clear()
            controller.updateClientSize(cols: 92, rows: 30)
            XCTAssertTrue(sent.string.contains("refresh-client -C 92,30"), "\(path): keyboard resize swallowed: '\(sent.string)'")
        }
    }

    /// The safety bound still delivers a reply that never gets evidence, so
    /// a read cannot stay unresolved forever. It delivers `.unknown`
    /// geometry, which cannot contradict our own stamp: the device stays the
    /// owner, never veiled as "another device", and replays nothing.
    func test_geometryEvidenceSafetyBoundStillDeliversTheReply() async throws {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeController(
                path: path, remoteStamp: selfValue(), remoteGrid: FixtureGrid(columns: 92, rows: 38), attach: false,
                authorityConfiguration: .init(replyHoldMillis: 50)
            )
            controller.ingest(Array(Self.handshake.utf8))
            let readIndex = try XCTUnwrap(controller._debugPendingCommands.firstIndex { $0.hasPrefix(Self.authorityRead) })
            ackAllPending(controller, frames: readIndex + 1)
            XCTAssertTrue(controller.gridAuthorityHasHeldReplyForTesting, "\(path)")
            sent.clear()
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(controller.gridAuthorityHasHeldReplyForTesting, "\(path): the bound delivered the reply")
            XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "\(path): a bounded read never claims")
            XCTAssertEqual(controller.gridAuthority, .mine, "\(path): our stamp, no contrary evidence")
            XCTAssertEqual(controller.gridAuthorityPresentation, .none, "\(path): never veiled as another device")
            XCTAssertFalse(controller.gridAuthorityPresentation.showsVeil, "\(path)")
            XCTAssertTrue(controller.gridAuthorityAllowsInput, "\(path)")
            assertNoGeometryOrStamp(sent.string, "\(path): an evidence-free read replays nothing")
        }
    }

    // MARK: M6: an inactive device sizes nothing

    func test_inactiveDeviceNeverSizesBeforeItsForegroundRead() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeOwnerController(path: path)
            controller.prepareForAppInactivity()
            sent.clear()
            controller.updateClientSize(cols: 92, rows: 38)
            controller.updateClientSize(cols: 100, rows: 40)
            assertNoGeometryOrStamp(sent.string, "\(path): resize while inactive, before the foreground read")
            controller.refreshActiveWindowOnForeground()
            controller.updateClientSize(cols: 100, rows: 40)
            assertNoGeometryOrStamp(sent.string, "\(path): the foreground read holds geometry")
            ackAllPending(controller, frames: 40)
            XCTAssertTrue(sent.string.contains("refresh-client -C 100,40"), "\(path): owned replay after the read: \(sent.string)")
            XCTAssertFalse(sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"), "\(path): \(sent.string)")
        }
    }

    private func makePublishedCompactController(path: TmuxController.ControlPath) -> (TmuxController, ByteSink) {
        let (controller, sent) = makeOwnerController(path: path, localCols: 200, localRows: 40)
        // An own-stamp attach can need no refresh at all. Establish a real
        // publication on the wire before withholding subsequent requests.
        controller.updateClientSize(cols: 198, rows: 40)
        controller.updateClientSize(cols: 200, rows: 40)
        ackAllPending(controller, frames: 40)
        sent.clear()
        return (controller, sent)
    }

    private enum CompactSizeHold { case inactive, authorityRead, yielded }

    func test_compactInactiveRequestsAreNotPublications() throws {
        try exerciseCompactSizeHold(.inactive)
    }

    func test_compactUnresolvedAuthorityRequestsAreNotPublications() throws {
        try exerciseCompactSizeHold(.authorityRead)
    }

    func test_compactYieldedRequestsAreNotPublications() throws {
        try exerciseCompactSizeHold(.yielded)
    }

    /// The same view-model sequence on inline SSH and Mosh's control client:
    /// the last real publication stays 200x40 while layouts request 202,
    /// 204, ... . Requested sizes never become cycle-guard evidence. The
    /// controller releases exactly one latest request after its real gate.
    private func exerciseCompactSizeHold(_ hold: CompactSizeHold) throws {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makePublishedCompactController(path: path)
            defer { controller.reset() }
            XCTAssertEqual(controller.lastPublishedClientSize, try TmuxClientGeometry(columns: 200, rows: 40))
            controller.sendBytesAdmitting = { bytes in
                sent.append(bytes)
                return true
            }
            switch hold {
            case .inactive: controller.prepareForAppInactivity()
            case .authorityRead:
                controller.prepareForAppInactivity()
                controller.refreshActiveWindowOnForeground()
            case .yielded: deliverStamp(controller, value: Self.peerValue)
            }
            sent.clear()
            var memo = TmuxCompactReprojectionMemo()
            var requested = (columns: 200, rows: 40)
            for columns in [200, 202, 204, 206] {
                let layout = try XCTUnwrap(WindowLayout.parse("0000,\(columns)x40,0,0{\(columns - 50)x40,0,0,0,49x40,\(columns - 49),0,1}"))
                let published = controller.lastPublishedClientSize
                let decision = TmuxCompactClientSizing.reprojection(
                    viewport: (50, 40), lastClientSize: published.map { ($0.columns, $0.rows) },
                    layout: layout, focusPaneId: PaneId(1), windowRect: layout.root.rect,
                    focusRect: layout.leaves.first { $0.paneId == PaneId(1) }?.rect, memo: &memo
                )
                XCTAssertNotEqual(decision, .holdCycle, "\(path) \(hold) at \(columns)")
                if decision == .reproject {
                    requested = TmuxCompactClientSizing.clientSize(viewport: (50, 40), layout: layout,
                        focusPaneId: PaneId(1), windowRect: layout.root.rect, focusRect: layout.leaves.first { $0.paneId == PaneId(1) }?.rect)
                    controller.updateClientSize(cols: requested.columns, rows: requested.rows)
                }
                XCTAssertEqual(controller.lastPublishedClientSize?.columns, 200)
            }
            XCTAssertFalse(memo.isHoldingCycle)
            assertNoGeometryOrStamp(sent.string, "\(path) \(hold): requests are withheld")
            switch hold {
            case .inactive: controller.refreshActiveWindowOnForeground()
            case .authorityRead: break
            case .yielded: XCTAssertTrue(controller.reclaimGridAuthority())
            }
            ackAllPending(controller, frames: 40)
            XCTAssertEqual(count("refresh-client -C ", in: sent.string), 1, "\(path) \(hold): \(sent.string)")
            XCTAssertEqual(controller.lastPublishedClientSize?.columns, requested.columns)
            let landed = try XCTUnwrap(WindowLayout.parse("0000,\(requested.columns)x40,0,0{\(requested.columns - 51)x40,0,0,0,50x40,\(requested.columns - 50),0,1}"))
            XCTAssertEqual(TmuxCompactClientSizing.reprojection(
                viewport: (50, 40), lastClientSize: (requested.columns, requested.rows),
                layout: landed, focusPaneId: PaneId(1), windowRect: landed.root.rect,
                focusRect: landed.leaves.first { $0.paneId == PaneId(1) }?.rect, memo: &memo
            ), .hold)
            XCTAssertFalse(memo.isHoldingCycle)
        }
    }

    func test_clientSizePublishesSynchronouslyAtTransportAdmissionBeforeAnyReply() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makePublishedCompactController(path: path)
            defer { controller.reset() }
            var admitted: [[UInt8]] = []
            controller.sendBytesAdmitting = { bytes in
                if String(decoding: bytes, as: UTF8.self).hasPrefix("refresh-client -C ") {
                    admitted.append(bytes)
                }
                return true
            }
            for columns in [202, 204, 206] {
                controller.updateClientSize(cols: columns, rows: 40)
                // The writer has not run and no reply has been ingested.
                // Publication must already describe the latest queued size.
                XCTAssertEqual(controller.lastPublishedClientSize?.columns, columns)
            }
            XCTAssertEqual(admitted.count, 3)
            XCTAssertTrue(String(decoding: admitted.last ?? [], as: UTF8.self).contains("refresh-client -C 206,40"))
            ackAllPending(controller, frames: 40)
            XCTAssertEqual(controller.lastPublishedClientSize?.columns, 206)
        }
    }

    func test_clientSizeRefusedByTransportAdmissionIsNeverPublished() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makePublishedCompactController(path: path)
            defer { controller.reset() }
            var attempts = 0
            controller.sendBytesAdmitting = { bytes in
                if String(decoding: bytes, as: UTF8.self).hasPrefix("refresh-client -C ") {
                    attempts += 1
                }
                return false
            }
            controller.updateClientSize(cols: 202, rows: 40)
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(controller.lastPublishedClientSize?.columns, 200)
        }
    }

    func test_clientSizeAdmissionIsClearedWhenTheControlConnectionEnds() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makePublishedCompactController(path: path)
            controller.sendBytesAdmitting = { _ in true }
            controller.updateClientSize(cols: 106, rows: 40)
            XCTAssertEqual(controller.lastPublishedClientSize?.columns, 106)
            if path == .sideChannel { controller.sideChannelDisconnected() } else { controller.reset() }
            XCTAssertNil(controller.lastPublishedClientSize)
            controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
            XCTAssertNil(controller.lastPublishedClientSize, "a replacement connection has admitted no geometry")
            controller.reset()
        }
    }

    func test_clientSizeAdmissionCannotRepublishAfterASynchronousConnectionReset() {
        let (controller, _) = makePublishedCompactController(path: .inline)
        controller.sendBytesAdmitting = { _ in
            controller.reset()
            return true
        }
        controller.updateClientSize(cols: 106, rows: 40)
        XCTAssertNil(controller.lastPublishedClientSize)
    }

    func test_clientSizeWithoutATransportIsNeverPublished() {
        let (controller, _) = makeOwnerController()
        defer { controller.reset() }
        let before = controller.lastPublishedClientSize
        controller.sendBytes = nil
        controller.updateClientSize(cols: 106, rows: 40)
        XCTAssertEqual(controller.lastPublishedClientSize, before)
    }

    func test_compactObservationKeyDoesNotChangeOnOutputOrWindowTitleChurn() throws {
        let (controller, _) = makeOwnerController()
        defer { controller.reset() }
        let windowID = try XCTUnwrap(controller.activeWindowId)
        let paneID = try XCTUnwrap(controller.activePaneId)
        func key() -> String {
            let layout = controller.windows.first { $0.id == windowID }?.layout
            return TmuxCompactClientSizing.observationKey(mode: String(describing: controller.mode),
                windowId: windowID, focusPaneId: paneID, layout: layout,
                windowRect: layout?.root.rect, focusRect: layout?.leaves.first { $0.paneId == paneID }?.rect)
        }
        let before = key()
        for step in 0..<100 {
            controller.ingest(Array("%output \(paneID) busy-output\r\n%window-renamed \(windowID) title-\(step)\r\n".utf8))
            XCTAssertEqual(key(), before)
        }
        XCTAssertEqual(controller.windows.first { $0.id == windowID }?.windowName, "title-99")
    }

    func test_unchangedSizeIsNotReplayed() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, sent) = makeOwnerController(path: path)
            controller.updateClientSize(cols: 92, rows: 38)
            assertNoGeometryOrStamp(sent.string, "\(path): same-size pass")
            controller.updateClientSize(cols: 92, rows: 37)
            XCTAssertTrue(sent.string.contains("refresh-client -C 92,37"), "\(path): \(sent.string)")
        }
    }

    // MARK: M7: input while a show waits for a connection

    func test_resumingAwaitingConnectionAllowsInputUnlessAPeerHolds() {
        let (owner, _) = makeOwnerController(path: .sideChannel)
        owner.sideChannelDisconnected()
        owner.gridAuthorityShown()
        XCTAssertEqual(owner.gridAuthorityPresentation, .resuming(awaitingConnection: true))
        XCTAssertTrue(owner.gridAuthorityAllowsInput, "typing reaches the shell through mosh")
        XCTAssertFalse(owner.gridAuthorityRefusesAgentSend)

        let (yielded, _) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        yielded.sideChannelDisconnected()
        yielded.gridAuthorityShown()
        XCTAssertEqual(yielded.gridAuthorityPresentation, .resuming(awaitingConnection: true))
        XCTAssertFalse(yielded.gridAuthorityAllowsInput, "the last-known holder is a peer")
        XCTAssertTrue(yielded.gridAuthorityRefusesAgentSend)

        let (live, _) = makeOwnerController(path: .sideChannel)
        live.gridAuthorityShown()
        XCTAssertEqual(live.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        XCTAssertFalse(live.gridAuthorityAllowsInput, "a live read is moments away")
        XCTAssertFalse(live.gridAuthorityRefusesAgentSend, "D7: resuming refuses only over a peer")

        let (veiled, _) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        XCTAssertTrue(veiled.gridAuthorityRefusesAgentSend)
        XCTAssertFalse(veiled.gridAuthorityAllowsInput)
    }

    // MARK: D13: background writes wait on the gate

    func test_backgroundWritesAreRefusedWhileAPeerHoldsButReadsGoOut() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (veiled, sent) = makeController(path: path, remoteStamp: Self.peerValue)
            ackAllPending(veiled, frames: 40)
            XCTAssertTrue(veiled.gridAuthorityRefusesAgentSend, "\(path)")
            let before = sent.string
            var launch: Result<[String], TmuxController.CommandError>?
            veiled.sendBackgroundControlQuery("new-window -d -P -F '#{pane_id}'") { launch = $0 }
            guard case .failure = launch else { return XCTFail("\(path): the launch was admitted") }
            XCTAssertEqual(sent.string, before, "\(path): nothing reached tmux")
            // The inline fixture keeps its authoritative render pending, which
            // turns every background query away first; the gate is the same
            // code on both paths.
            guard path == .sideChannel else { continue }
            XCTAssertEqual(launch, .failure(.refusedByAuthority))
            veiled.sendBackgroundControlQuery("display-message -p '#{pane_id}'") { _ in }
            XCTAssertTrue(sent.string.dropFirst(before.count).contains("display-message -p"), "reads still go out")
            var reply: Result<[String], TmuxController.CommandError>?
            veiled.sendBackgroundControlQuery("send-keys -t %6 -H 61") { reply = $0 }
            XCTAssertTrue(sent.string.dropFirst(before.count).contains("send-keys -t %6 -H 61\n"))
            ackAllPending(veiled, frames: 40)
            XCTAssertEqual(reply, .success([]))
            XCTAssertTrue(veiled.gridAuthority.isPeer)
            XCTAssertTrue(sent.string.dropFirst(before.count).split(separator: "\n").allSatisfy {
                $0 == "send-keys -t %6 -H 61" || TmuxAgentCommandAccess.isReadOnly(String($0))
            }, "only the pane reply and reads: \(sent.string)")

            let (owner, ownerSent) = makeOwnerController(path: path)
            ackAllPending(owner, frames: 40)
            XCTAssertFalse(owner.gridAuthorityRefusesAgentSend)
            owner.sendBackgroundControlQuery("new-window -d -P -F '#{pane_id}'") { _ in }
            XCTAssertTrue(ownerSent.string.contains("new-window -d"), "the owner launches")
        }
    }

    // MARK: L2: a hide abandons an unsent claim

    func test_hideAbandonsAClaimWhoseCommandsWereNeverSent() {
        let (controller, sent) = makeController(path: .sideChannel, localCols: 0, localRows: 0, remoteStamp: Self.peerValue)
        controller.gridAuthorityShown()
        ackAllPending(controller, frames: 1)
        let claim = controller.gridAuthorityLifecycleForTesting.claim
        XCTAssertEqual(claim?.phase, .awaitingFence, "deferred: viewport unavailable")
        controller.gridAuthorityHidden()
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "an unsent claim must not survive the hide")
        sent.clear()
        controller.updateClientSize(cols: 92, rows: 38)
        ackAllPending(controller, frames: 40)
        assertNoGeometryOrStamp(sent.string, "a hidden session's measurement cannot resume the claim")
    }

    // MARK: Round 3: cancel ends the intent; it is not a hide

    private func reattachSideChannel(_ controller: TmuxController) {
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 dev\r\n".utf8))
        controller.ingest(Array(Self.handshake.utf8))
        ackAllPending(controller, frames: 40)
    }

    /// The veil's "takes control when reconnected" X: cancelling a tap made
    /// while the side channel is down must leave the session displayed, so
    /// the peer the reconnect reads is the tappable veil again, never a
    /// `.resuming` with no way back.
    func test_cancellingATapWhileTheChannelIsDownLeavesATappableVeil() {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        controller.sideChannelDisconnected()
        XCTAssertTrue(controller.reclaimGridAuthority())
        XCTAssertEqual(
            controller.gridAuthorityPresentation,
            .reclaiming(peerName: "iPhone", awaitingConnection: true)
        )

        controller.cancelGridAuthorityIntent()
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))

        sent.clear()
        reattachSideChannel(controller)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "a cancelled tap never claims")
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"),
                       "the reconnect read draws the veil, not a stuck resume")
        XCTAssertFalse(controller.gridAuthorityAllowsInput)
        assertNoGeometryOrStamp(sent.string, "a cancelled tap sends nothing on reconnect")

        XCTAssertTrue(controller.reclaimGridAuthority(), "the veil still takes control back")
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
    }

    /// The show pill's X while the channel is down, then a peer appears:
    /// the session is still on screen, so that peer is drawn as the veil.
    func test_cancellingAShowWhileTheChannelIsDownStillVeilsALaterPeer() {
        let (controller, _) = makeController(path: .sideChannel)
        controller.sideChannelDisconnected()
        controller.gridAuthorityShown()
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: true))

        controller.cancelGridAuthorityIntent()
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)

        fixture(controller).authorityStamp = Self.peerValue
        reattachSideChannel(controller)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "a cancelled show never claims")
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertTrue(controller.reclaimGridAuthority())
    }

    /// Cancel also abandons a claim that never sent its commands (the same
    /// rule as a hide, L2), but leaves the hidden flag alone.
    func test_cancelAbandonsAnUnsentClaimWithoutHiding() {
        let (controller, sent) = makeController(path: .sideChannel, localCols: 0, localRows: 0, remoteStamp: Self.peerValue)
        controller.gridAuthorityShown()
        ackAllPending(controller, frames: 1)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence)
        controller.cancelGridAuthorityIntent()
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "an unsent claim must not survive the cancel")
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"), "cancel is not a hide")
        sent.clear()
        controller.updateClientSize(cols: 92, rows: 38)
        ackAllPending(controller, frames: 40)
        assertNoGeometryOrStamp(sent.string, "a cancelled claim's measurement cannot resume it")
    }

    // MARK: L4: the hold release replays what it withheld

    func test_holdReleaseUnderNonLatestPolicyReplaysTheWithheldSize() {
        let (controller, sent) = makeController(
            path: .sideChannel, remoteStamp: selfValue(), remoteGrid: FixtureGrid(columns: 80, rows: 30), attach: false
        )
        fixture(controller).windowSizePolicy = "smallest"
        controller.ingest(Array(Self.handshake.utf8))
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertFalse(controller.gridAuthorityGeometryHeldForTesting)
        XCTAssertTrue(sent.string.contains("refresh-client -C 92,38"), "the withheld size reaches tmux: \(sent.string)")
        XCTAssertFalse(sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"), sent.string)
    }

    // MARK: L11: one read per resume

    func test_foregroundWhileAShowIsPendingSendsNoSecondRead() {
        let (controller, sent) = makeOwnerController(path: .sideChannel)
        controller.prepareForAppInactivity()
        controller.gridAuthorityShown()
        controller.refreshActiveWindowOnForeground()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
    }
}

// MARK: - Phase 0c: take-back round trips (P7, P8)

extension GridAuthorityTests {
    private final class FeedLog {
        var sources: [RenderFeedSource] = []
    }

    /// Yielded to the peer over a window at `remoteGrid`, with the live
    /// surface already painted from tmux (a device that was showing the
    /// session before the peer took it).
    private func makePaintedYieldedController(
        remoteGrid: FixtureGrid
    ) -> (controller: TmuxController, sent: ByteSink, feeds: FeedLog) {
        let (controller, sent) = makeController(path: .inline, remoteGrid: remoteGrid)
        let feeds = FeedLog()
        controller.renderFeedSurface = { _, _, _, source in
            feeds.sources.append(source)
            return true
        }
        let layout = "beef,\(remoteGrid.columns)x\(remoteGrid.rows),0,0,0"
        controller.ingest(Array("%layout-change @0 \(layout) \(layout) *\r\n%window-pane-changed @0 %0\r\n".utf8))
        sent.clear()
        controller.submitRenderFact(.refreshRequested(.live, stage: .deep, reason: "test-paint"))
        answerWire(controller, sent, authority: "")
        XCTAssertFalse(feeds.sources.isEmpty, "fixture paint: \(sent.string)")
        deliverStamp(controller, value: Self.peerValue)
        XCTAssertEqual(controller.gridAuthority, .peer(displayName: "iPhone"))
        feeds.sources.removeAll()
        sent.clear()
        return (controller, sent, feeds)
    }

    /// Answers, in transmission order, exactly the commands already on the
    /// wire: one round trip. Commands sent while answering wait for the next
    /// round. Returns the commands this round answered.
    @discardableResult
    private func answerRound(
        _ controller: TmuxController,
        _ sent: ByteSink,
        answered index: inout Int,
        limit: Int = .max,
        authority: String? = nil
    ) -> [String] {
        let lines = sent.string.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        let round = Array(lines[index...].prefix(limit))
        index += round.count
        let fixture = fixture(controller)
        for (offset, command) in round.enumerated() {
            var body: [String]
            if command.hasPrefix(Self.authorityRead) {
                body = [authority ?? Self.peerValue]
            } else if command.hasPrefix("display-message -p -t "), command.contains("#{cursor_x}") {
                body = [renderMetadata(pane: targetPane(of: command) ?? 0)]
            } else if command.hasPrefix("capture-pane ") {
                body = ["authoritative viewport"]
            } else {
                fixture.observe(controller)
                body = fixture.acknowledge(command)
            }
            let number = 3_000 + index * 10 + offset
            let frame = (["%begin 0 \(number) 1"] + body + ["%end 0 \(number) 1"])
                .joined(separator: "\r\n") + "\r\n"
            controller.ingest(Array(frame.utf8))
        }
        return round
    }

    /// Answers rounds until the claim settles; returns each round's commands.
    @discardableResult
    private func answerUntilSettled(
        _ controller: TmuxController,
        _ sent: ByteSink,
        answered index: inout Int,
        afterRound: (Int) -> Void = { _ in }
    ) -> [[String]] {
        var rounds: [[String]] = []
        while controller.gridAuthority != .mine, rounds.count < 8 {
            let round = answerRound(controller, sent, answered: &index)
            guard !round.isEmpty else { break }
            rounds.append(round)
            afterRound(rounds.count)
        }
        return rounds
    }

    /// `answerUntilSettled`, also letting the ledger's timers run: a repaint
    /// that waits for the command FIFO to drain goes out from a timer.
    private func answerUntilSettledWithTimers(
        _ controller: TmuxController,
        _ sent: ByteSink,
        answered index: inout Int
    ) async -> [[String]] {
        controller.renderCommandQueueMaxWait = 0.05
        var rounds: [[String]] = []
        while controller.gridAuthority != .mine, rounds.count < 8 {
            let lines = { sent.string.split(separator: "\n", omittingEmptySubsequences: false).count - 1 }
            for _ in 0..<100 where lines() <= index {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let round = answerRound(controller, sent, answered: &index)
            guard !round.isEmpty else { break }
            rounds.append(round)
        }
        return rounds
    }

    private func isMetadataQuery(_ command: String) -> Bool {
        command.hasPrefix("display-message -p -t @0 ") && command.contains("#{cursor_x}")
    }

    private func isSettleProbe(_ command: String) -> Bool {
        command == TmuxWindowSizeReplay.sizeQuery(windowID: WindowId(0))
    }

    private func isStampWrite(_ command: String) -> Bool {
        command.hasPrefix("set-option \(TmuxController.gridAuthorityOption)")
    }

    /// P8 budget, geometry unchanged: the visible repaint rides in the
    /// fence's burst, so the take-back is that burst plus the stamp commit.
    func test_inlineTakeBackAtUnchangedGeometryCostsTwoRoundTrips() {
        let (controller, sent, feeds) = makePaintedYieldedController(remoteGrid: FixtureGrid(columns: 92, rows: 38))
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        let rounds = answerUntilSettled(controller, sent, answered: &index)

        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        XCTAssertEqual(rounds.count, 2, "\(rounds)")
        let burst = rounds.first ?? []
        XCTAssertEqual(burst.count, 4, "\(burst)")
        XCTAssertEqual(burst.first, "show-options -wA -v -t @0 window-size")
        XCTAssertEqual(burst.dropFirst().first, "select-window")
        XCTAssertTrue(burst.dropFirst(2).first.map(isMetadataQuery) == true, "\(burst)")
        XCTAssertEqual(burst.last, "capture-pane -p -e -N -t @0")
        // The settle probe goes out on the fence's reply, beside the stamp
        // the repaint authorized: it adds no round trip (§6.10 rule 5).
        XCTAssertEqual(rounds.last?.count, 2, "\(rounds)")
        XCTAssertTrue(rounds.last?.first.map(isSettleProbe) == true, "\(rounds)")
        XCTAssertTrue(rounds.last?.last.map(isStampWrite) == true, "\(rounds)")
        XCTAssertEqual(feeds.sources, [.viewportRefresh], "one in-place visible repaint")
        XCTAssertEqual(count("capture-pane", in: sent.string), 1, sent.string)
    }

    /// The repaint sent behind the fence is scoped by its correlation. It
    /// replaces no other callback, so a generation-guarded reply already in
    /// flight when the take-back starts (here a pane interaction query; on a
    /// reconnect, the hydration queued behind the authority read) still
    /// applies.
    func test_claimRepaintBehindTheFenceKeepsCallbacksAlreadyInFlight() {
        let (controller, sent, _) = makePaintedYieldedController(remoteGrid: FixtureGrid(columns: 92, rows: 38))
        var replied = false
        var state: TmuxController.PaneInteractionState?
        controller.queryActivePaneInteractionState { value in
            replied = true
            state = value
        }
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        let rounds = answerUntilSettled(controller, sent, answered: &index)

        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(rounds.count, 2, "\(rounds)")
        XCTAssertTrue(rounds.first?.contains("capture-pane -p -e -N -t @0") == true, "the repaint rode the fence: \(rounds)")
        XCTAssertTrue(replied)
        XCTAssertEqual(state?.paneId, PaneId(0), "the query predating the claim is not retired by it")
    }

    /// Answers every round, letting the ledger's queue-wait timers run
    /// between them, until nothing more goes out; returns each round.
    private func answerAllRoundsWithTimers(
        _ controller: TmuxController,
        _ sent: ByteSink,
        answered index: inout Int,
        authority: String,
        afterRound: ([String]) -> Void = { _ in }
    ) async -> [[String]] {
        controller.renderCommandQueueMaxWait = 0.05
        var rounds: [[String]] = []
        while rounds.count < 16 {
            let lines = { sent.string.split(separator: "\n", omittingEmptySubsequences: false).count - 1 }
            for _ in 0..<30 where lines() <= index {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let round = answerRound(controller, sent, answered: &index, authority: authority)
            guard !round.isEmpty else { break }
            rounds.append(round)
            afterRound(round)
        }
        return rounds
    }

    /// Review finding 1: a show claim no peer holds that resizes the window
    /// (back from the background after a rotation, our own stamp on the
    /// window) must rebuild the reflowed window and deepen it. Confirmed
    /// inside the `%layout-change`, its foreground refresh used to reach the
    /// ledger first, which then took the relayout for an echo and scrubbed
    /// the visible rows in place over history wrapped for the old grid.
    func test_noPeerShowClaimThatResizesTheWindowRebuildsAndDeepens() async {
        let (controller, sent) = makeOwnerController(path: .inline)
        let feeds = FeedLog()
        controller.renderFeedSurface = { _, _, _, source in
            feeds.sources.append(source)
            return true
        }
        let owned = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(owned) \(owned) *\r\n%window-pane-changed @0 %0\r\n".utf8))
        sent.clear()
        controller.submitRenderFact(.refreshRequested(.live, stage: .deep, reason: "test-paint"))
        answerWire(controller, sent, authority: selfValue())
        XCTAssertFalse(feeds.sources.isEmpty, "fixture paint: \(sent.string)")
        sent.clear()

        controller.prepareForAppInactivity()
        controller.updateClientSize(cols: 100, rows: 40)
        controller.refreshActiveWindowOnForeground()
        controller.gridAuthorityShown()
        var index = 0
        let resized = FixtureGrid(columns: 100, rows: 40)
        var feedsAtRelayout: Int?
        let rounds = await answerAllRoundsWithTimers(controller, sent, answered: &index, authority: selfValue()) { round in
            // tmux applies the fence's deferred resize after its burst.
            guard round.contains("select-window"), feedsAtRelayout == nil else { return }
            feedsAtRelayout = feeds.sources.count
            self.ingestLayout(controller, resized)
        }

        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
        let claimFeeds = Array(feeds.sources.dropFirst(feedsAtRelayout ?? 0))
        XCTAssertTrue(claimFeeds.contains(.viewportRepaint), "the reflowed window is rebuilt: \(claimFeeds)")
        XCTAssertFalse(claimFeeds.contains(.viewportRefresh), "never scrubbed in place: \(claimFeeds)")
        let wire = sent.string.split(separator: "\n").map(String.init)
        let stamp = wire.firstIndex(where: isStampWrite) ?? .max
        let deep = wire.firstIndex { $0.hasPrefix("capture-pane -p -e -N -S -") }
        XCTAssertNotNil(deep, "then its history: \(rounds)")
        XCTAssertGreaterThan(deep ?? -1, stamp, "no deep capture ahead of the stamp: \(rounds)")
    }

    /// An owner's keyboard toggle (a resize and its relayout) rebuilds the
    /// visible rows at most once deeply, and a plain inactive/active pull
    /// with nothing pending (Control Center) captures no history at all.
    func test_anOwnersKeyboardToggleAndAPlainForegroundPullStayCheap() async {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.renderFeedSurface = { _, _, _, _ in true }
        controller.renderCommandQueueMaxWait = 0.05
        let owned = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(owned) \(owned) *\r\n%window-pane-changed @0 %0\r\n".utf8))
        controller.submitRenderFact(.refreshRequested(.live, stage: .deep, reason: "test-paint"))
        answerWire(controller, sent, authority: selfValue())
        sent.clear()

        controller.updateClientSize(cols: 92, rows: 24)
        let keyboard = "beef,92x24,0,0,0"
        fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 24)
        controller.ingest(Array("%layout-change @0 \(keyboard) \(keyboard) *\r\n".utf8))
        var index = 0
        let keyboardRounds = await answerAllRoundsWithTimers(controller, sent, answered: &index, authority: selfValue())
        XCTAssertLessThanOrEqual(count("capture-pane -p -e -N -S -", in: sent.string), 1, "\(keyboardRounds)")

        sent.clear()
        index = 0
        controller.prepareForAppInactivity()
        controller.refreshActiveWindowOnForeground()
        let pullRounds = await answerAllRoundsWithTimers(controller, sent, answered: &index, authority: selfValue())
        XCTAssertEqual(count("capture-pane -p -e -N -S -", in: sent.string), 0, "a plain pull must not deepen: \(pullRounds)")
        XCTAssertEqual(controller.gridAuthority, .mine)
    }

    // MARK: `latest` taken after the claim confirmed

    private func stampWrites(_ sent: ByteSink) -> Int {
        sent.string.split(separator: "\n").filter { isStampWrite(String($0)) }.count
    }

    private func ingestLayout(_ controller: TmuxController, _ grid: FixtureGrid) {
        fixture(controller).grids[WindowId(0)] = grid
        let layout = "beef,\(grid.columns)x\(grid.rows),0,0,0"
        controller.ingest(Array("%layout-change @0 \(layout) \(layout) *\r\n".utf8))
    }

    /// The `%layout-change` tmux sends once it applied a fence's deferred
    /// resize: delivered when the window is at `grid` in the fixture (the
    /// fence ran) but the controller has not seen it yet.
    private func deliverFencedLayout(_ controller: TmuxController, _ grid: FixtureGrid) {
        guard fixture(controller).grids[WindowId(0)] == grid,
              let rect = controller.windows.first(where: { $0.id == WindowId(0) })?.layout?.root.rect,
              rect.width != grid.columns || rect.height != grid.rows
        else { return }
        ingestLayout(controller, grid)
    }

    /// Yielded over a window already at our grid, tapped, and the probe and
    /// fence answered: the claim confirmed and adopted the repaint queued
    /// behind its fence, whose metadata and capture are still unanswered.
    private func makeConfirmedTakeBack() -> (controller: TmuxController, sent: ByteSink, index: Int) {
        let (controller, sent, _) = makePaintedYieldedController(remoteGrid: FixtureGrid(columns: 92, rows: 38))
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        XCTAssertEqual(
            answerRound(controller, sent, answered: &index, limit: 2),
            ["show-options -wA -v -t @0 window-size", "select-window"]
        )
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint)
        return (controller, sent, index)
    }

    /// `sendBytes` may answer a command before it returns. A late claim's
    /// settle probe answered that way finds its fence already acknowledged,
    /// and no stall check ends the claim between the acknowledgement and the
    /// repaint its confirmation requests.
    func test_aLateClaimsSettleProbeAnsweredInsideSendBytesNeverStallsTheClaim() throws {
        let (controller, sent, _) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
        XCTAssertTrue(controller.reclaimGridAuthority())
        let generation = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.presentationVisible, false)
        let remote = fixture(controller)
        var answered = 0
        controller.sendBytes = { [weak controller] bytes in
            remote.noteSent(bytes)
            let command = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard let controller, command.contains("tessera-window-size") else { sent.append(bytes); return }
            answered += 1
            let number = 9_000 + answered
            let frame = (["%begin 0 \(number) 1"] + remote.acknowledge(command) + ["%end 0 \(number) 1"])
                .joined(separator: "\r\n") + "\r\n"
            controller.ingest(Array(frame.utf8))
        }
        let wire = sent.string.split(separator: "\n").map(String.init)
        XCTAssertEqual(wire.last, TmuxClientSizeReplay.latestFenceCommand)
        var index = 0
        answerRound(controller, sent, answered: &index, limit: wire.count - 1)
        // tmux applies the fence's resize and notifies it ahead of its reply.
        XCTAssertEqual(remote.acknowledge(TmuxClientSizeReplay.latestFenceCommand), [])
        let ours = FixtureGrid(columns: 92, rows: 38)
        ingestLayout(controller, ours)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence)
        controller.ingest(Array("%begin 0 8999 1\r\n%end 0 8999 1\r\n".utf8))
        XCTAssertEqual(answered, 1, "the acknowledgement wrote the settle probe: \(sent.string)")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, generation, "not stalled")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryLanded, true)
    }

    /// I3: a fence that waits for tmux to name a window leaves the claim's
    /// `-C` unordered. A counted no-op behind every such `-C` keeps a late
    /// claim until tmux has processed it, a window tmux names late is no
    /// move, and with nothing else of its own out the claim ends (rule 6).
    func test_aFenceDeferredForAnUnnamedWindowKeepsALateClaimUntilItsGridIsOrdered() throws {
        let marker = "display-message -p ''"
        for variant in ["plain", "churn", "named"] {
            let (controller, sent, _) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
            controller.deferGridAuthorityWireTargetForTesting()
            XCTAssertTrue(controller.reclaimGridAuthority())
            let generation = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation)
            let lines = { sent.string.split(separator: "\n").map(String.init) }
            XCTAssertEqual(lines().last, marker, "\(variant): \(sent.string)")
            XCTAssertNil(controller.gridAuthoritySessionForTesting.claimFence)
            if variant == "churn" {
                // A newer grid while the window is still unnamed.
                controller.updateClientSize(cols: 90, rows: 36)
                XCTAssertEqual(lines().filter { $0 == marker }.count, 2, sent.string)
                XCTAssertEqual(lines().last, marker, sent.string)
            }
            controller.expireGridAuthorityReclaimPresentationForTesting()
            XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, generation,
                           "\(variant): the deadline only hides while its grid is unordered")
            if variant == "named" {
                let before = lines().count
                controller.ingest(Array("%session-window-changed $0 @0\r\n".utf8))
                XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, generation,
                               "a window named late moved nothing")
                XCTAssertFalse(lines().dropFirst(before).contains { $0.hasPrefix("select-window") }, sent.string)
            }
            var index = 0
            let first = try XCTUnwrap(lines().firstIndex(of: marker))
            answerRound(controller, sent, answered: &index, limit: first + 1)
            if variant == "churn" {
                XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, generation,
                               "the newer grid is still unordered")
            }
            while index < lines().count, controller.gridAuthorityLifecycleForTesting.claim?.generation == generation {
                answerRound(controller, sent, answered: &index)
            }
            XCTAssertNotEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, generation,
                              "\(variant): nothing of its own is left: \(sent.string)")
        }
    }

    /// The window's grid each time the controller wrote its stamp.
    private func recordStampGrids(_ controller: TmuxController, _ sent: ByteSink) -> () -> [FixtureGrid] {
        final class Grids { var values: [FixtureGrid] = [] }
        let grids = Grids()
        let fixture = fixture(controller)
        controller.sendBytes = { [weak controller] bytes in
            sent.append(bytes)
            fixture.noteSent(bytes)
            let text = String(decoding: bytes, as: UTF8.self)
            guard text.contains("set-option \(TmuxController.gridAuthorityOption)"),
                  let rect = controller?.windows.first?.layout?.root.rect
            else { return }
            grids.values.append(FixtureGrid(columns: rect.width, rows: rect.height))
        }
        return { grids.values }
    }

    /// Another client takes tmux's `latest` after the claim confirmed (a
    /// reconnect's attach, a laptop's keystroke): the repaint in flight shows
    /// that client's grid, so it cannot authorize ours. The layout alone may
    /// be stale (§6.10 rule 4), so it only drops the repaint; the settle
    /// probe's answer proves the loss, the claim fences once more instead of
    /// stamping, and it stamps only at our grid.
    func test_inlineClaimWhoseWindowIsTakenAfterConfirmationFencesAgainBeforeItStamps() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let stampGrids = recordStampGrids(controller, sent)
        ingestLayout(controller, Self.peerGrid)
        XCTAssertEqual(count("select-window", in: sent.string), 1, "a layout before landing spends nothing: \(sent.string)")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence)
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(stampWrites(sent), 0, "no stamp over another client's grid: \(sent.string)")
        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertEqual(count("select-window", in: sent.string), 2, "the probe's loss fences again: \(sent.string)")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced, true)

        let ours = FixtureGrid(columns: 92, rows: 38)
        answerUntilSettled(controller, sent, answered: &index) { _ in
            self.deliverFencedLayout(controller, ours)
        }
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 2, "one fence takes `latest` back: \(sent.string)")
        let wire = sent.string.split(separator: "\n").map(String.init)
        let refence = wire.lastIndex(of: "select-window") ?? .max
        let stamp = wire.firstIndex(where: isStampWrite) ?? -1
        XCTAssertGreaterThan(stamp, refence, "the stamp follows the second fence: \(wire)")
        XCTAssertEqual(stampGrids(), [ours], "stamped only over our grid")
    }

    /// A peer's resize that tmux ran in the same server pass as our fence
    /// reaches us after the fence's reply, with our fence's own resize right
    /// behind it. That stale layout must neither abort the claim nor make it
    /// fence again and again.
    func test_aStaleForeignLayoutAfterTheFenceNeitherAbortsNorLoopsTheClaim() async {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let stampGrids = recordStampGrids(controller, sent)
        ingestLayout(controller, Self.peerGrid)
        ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
        let rounds = await answerUntilSettledWithTimers(controller, sent, answered: &index)
        XCTAssertEqual(stampGrids(), [FixtureGrid(columns: 92, rows: 38)])

        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertLessThanOrEqual(count("select-window", in: sent.string), 2, "at most one more fence: \(sent.string)")
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
        XCTAssertLessThanOrEqual(rounds.count, 3, "\(rounds)")
    }

    /// This device's grid changes after the claim confirmed (the keyboard, a
    /// rotation) and the size replay re-advertises it. The repaint in flight
    /// still shows the old grid and no layout has arrived yet, so only the
    /// commit itself can notice: the claim stamps once the window is at the
    /// grid it now asks for, as the side channel's final size read would
    /// insist.
    func test_aLocalResizeAfterConfirmationStampsOnlyOnceTheWindowFollows() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let stampGrids = recordStampGrids(controller, sent)
        let resized = FixtureGrid(columns: 92, rows: 30)
        controller.updateClientSize(cols: resized.columns, rows: resized.rows)
        XCTAssertTrue(sent.string.contains("refresh-client -C 92,30"), sent.string)
        answerRound(controller, sent, answered: &index, limit: 2)
        XCTAssertEqual(stampWrites(sent), 0, "no stamp from a repaint of the old grid: \(sent.string)")
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)

        answerUntilSettled(controller, sent, answered: &index) { _ in
            // tmux applies the replay's deferred resize after its burst.
            self.deliverFencedLayout(controller, resized)
        }
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(stampGrids(), [resized], sent.string)
        // Our own resize's echo is never a loss (§6.10 rule 3).
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced, nil)
        XCTAssertEqual(count("select-window", in: sent.string), 2, "the replay's own fence only: \(sent.string)")
    }

    /// The peer's own take-back fences `latest` away after our claim
    /// confirmed, then stamps. A peer that is genuinely claiming wins: we
    /// never stamp, and the veil names it.
    func test_aPeerClaimTakingTheWindowAfterOurConfirmationWins() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        ingestLayout(controller, Self.peerGrid)
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(stampWrites(sent), 0, "no stamp over the peer's grid: \(sent.string)")

        deliverStamp(controller, value: "v1 PEER-DEVICE-9999 4 iPhone")
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "contested by the peer's newer stamp")
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)

        // Replies still on the wire change nothing.
        answerRound(controller, sent, answered: &index)
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(stampWrites(sent), 0, sent.string)
        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertLessThanOrEqual(count("select-window", in: sent.string), 2, sent.string)
    }

    /// The re-fence is bounded: a second loss in the same claim aborts it
    /// (`geometryLost`) instead of fencing again (two devices that both
    /// tapped would otherwise trade `latest` forever), and a window that
    /// comes back later completes nothing. The user taps again.
    func test_aSecondLossInOneClaimAbortsInsteadOfFencingAgain() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let stampGrids = recordStampGrids(controller, sent)
        let ours = FixtureGrid(columns: 92, rows: 38)
        ingestLayout(controller, Self.peerGrid)
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(count("select-window", in: sent.string), 2, sent.string)
        answerRound(controller, sent, answered: &index)
        ingestLayout(controller, ours)
        // The window is ours again and the claim repaints; then it is taken
        // a second time before that repaint is answered.
        XCTAssertTrue(sent.string.split(separator: "\n").dropFirst(index).contains { $0.hasPrefix("capture-pane") },
                      "the confirmation's repaint: \(sent.string)")
        ingestLayout(controller, Self.peerGrid)
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "unlanded: the layout may be stale")
        answerRound(controller, sent, answered: &index)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "the second loss ends the claim")
        XCTAssertEqual(count("select-window", in: sent.string), 2, "one re-fence per claim: \(sent.string)")
        XCTAssertEqual(stampWrites(sent), 0, sent.string)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(controller.canReclaimGridAuthority, "a tap can restart it")

        ingestLayout(controller, ours)
        answerRound(controller, sent, answered: &index)
        answerRound(controller, sent, answered: &index)
        XCTAssertTrue(controller.gridAuthority.isPeer, "no late success: \(sent.string)")
        XCTAssertEqual(stampGrids(), [], sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 2, sent.string)
    }

    /// After a second loss to a stamp-less holder (a laptop's bare attach)
    /// the claim is gone, and a later local resize under the restored veil
    /// (a rotation) neither replays the size nor fences `latest` with no
    /// gesture since, let alone stamps.
    func test_aSecondLossClaimDoesNotSeizeTheWindowOnALaterRotation() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let ours = FixtureGrid(columns: 92, rows: 38)
        let laptop = FixtureGrid(columns: 120, rows: 40)
        ingestLayout(controller, laptop)
        answerRound(controller, sent, answered: &index)
        answerRound(controller, sent, answered: &index)
        ingestLayout(controller, ours)
        ingestLayout(controller, laptop)
        answerRound(controller, sent, answered: &index)
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(count("select-window", in: sent.string), 2, sent.string)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        XCTAssertTrue(controller.canReclaimGridAuthority, "a tap can restart it")

        let before = sent.string.count
        controller.updateClientSize(cols: 100, rows: 30)
        let after = String(sent.string.dropFirst(before))
        XCTAssertFalse(after.contains("select-window"), "a veiled rotation fences latest: \(after)")
        XCTAssertFalse(after.contains("refresh-client -C"), "a veiled rotation sizes the window: \(after)")
        answerUntilSettled(controller, sent, answered: &index) { _ in
            let resized = FixtureGrid(columns: 100, rows: 30)
            guard self.fixture(controller).grids[WindowId(0)] != resized else { return }
            self.ingestLayout(controller, resized)
        }
        XCTAssertEqual(stampWrites(sent), 0, "stamped with no gesture since the timeout: \(sent.string)")
        XCTAssertTrue(controller.gridAuthority.isPeer)
    }

    /// The tap after a given-up claim begins a new generation with its own
    /// re-fence budget, and settles over our grid.
    func test_aTapAfterASecondLossSettlesUnderANewGeneration() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let ours = FixtureGrid(columns: 92, rows: 38)
        let stampGrids = recordStampGrids(controller, sent)
        let firstGeneration = controller.gridAuthorityLifecycleForTesting.claim?.generation
        ingestLayout(controller, Self.peerGrid)
        answerRound(controller, sent, answered: &index)
        answerRound(controller, sent, answered: &index)
        ingestLayout(controller, ours)
        ingestLayout(controller, Self.peerGrid)
        answerRound(controller, sent, answered: &index)
        answerRound(controller, sent, answered: &index)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "given up at the second loss")
        XCTAssertTrue(controller.reclaimGridAuthority())
        let claim = controller.gridAuthorityLifecycleForTesting.claim
        XCTAssertNotNil(firstGeneration)
        XCTAssertGreaterThan(claim?.generation ?? 0, firstGeneration ?? .max)
        XCTAssertEqual(claim?.geometryRefenced, false)
        XCTAssertTrue(controller.gridAuthorityReclaimInFlight)
        answerUntilSettled(controller, sent, answered: &index) { _ in
            self.deliverFencedLayout(controller, ours)
        }
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
        XCTAssertEqual(stampGrids(), [ours], sent.string)
    }

    /// A claim whose presentation already timed out, waiting on a late
    /// confirmation, sees the window at a foreign grid. Before landing the
    /// layout may be stale, so the claim keeps waiting on its own acks; once
    /// its settle probe proves the loss it is given up at once, without
    /// fencing `latest` from under the restored veil (§6.10 rule 4).
    func test_aLossAfterThePresentationTimedOutGivesTheClaimUpWithoutFencing() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "an unlost claim may still succeed late")
        ingestLayout(controller, Self.peerGrid)
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "unlanded: the layout may be stale")
        answerRound(controller, sent, answered: &index)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "the probe proved the loss")
        XCTAssertEqual(count("select-window", in: sent.string), 1, "no re-fence: \(sent.string)")
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(stampWrites(sent), 0, sent.string)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertTrue(controller.canReclaimGridAuthority)
    }

    /// A split of the window at our grid after the claim confirmed (the
    /// user's own, say) is not a loss: the claim stays confirmed, never
    /// fences again, and settles once its pane surfaces mount and paint.
    func test_aSplitAtOurGridAfterConfirmationIsNotALoss() async {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let split = "beef,92x38,0,0{46x38,0,0,0,45x38,47,0,1}"
        controller.ingest(Array("%layout-change @0 \(split) \(split) *\r\n".utf8))
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced, false)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint)
        XCTAssertEqual(count("select-window", in: sent.string), 1, sent.string)
        // The platform's mount: declare each pane surface, then ask for its
        // first stage.
        controller.setPaneSink(PaneId(0)) { _ in }
        controller.setPaneSink(PaneId(1)) { _ in }
        controller.refreshPane(paneId: PaneId(0), deep: false)
        controller.refreshPane(paneId: PaneId(1), deep: false)
        let rounds = await answerUntilSettledWithTimers(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, "\(rounds)")
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, sent.string)
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 1, "no re-fence: \(sent.string)")
    }

    // MARK: §6.10 claim end of life: the review cases

    private var stampWrite: String { "set-option \(TmuxController.gridAuthorityOption)" }

    /// REVIEW-A. The presentation times out while the unlost claim repaints,
    /// then the user's own keyboard changes the local grid before the
    /// repaint lands. The late claim advertises nothing (rule 2): it settles
    /// late at the grid it confirmed, and the held-back size then goes out
    /// as an ordinary owner resize.
    func test_review_A_aLocalResizeAfterTheDeadlineIsHeldBackAndTheClaimSettlesLate() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let stampGrids = recordStampGrids(controller, sent)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "unlost claim survives the timeout")
        controller.updateClientSize(cols: 92, rows: 30)
        XCTAssertFalse(sent.string.contains("refresh-client -C 92,30"), "a late claim advertises nothing: \(sent.string)")
        let ours = FixtureGrid(columns: 92, rows: 38)
        answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(stampGrids(), [ours], sent.string)
        let wire = sent.string.split(separator: "\n").map(String.init)
        let stamp = wire.firstIndex(where: isStampWrite) ?? .max
        let replay = wire.firstIndex(of: "refresh-client -C 92,30") ?? -1
        XCTAssertGreaterThan(replay, stamp, "the held-back size follows the settlement: \(wire)")
        XCTAssertEqual(wire.prefix(upTo: min(stamp, wire.count)).filter { $0 == "select-window" }.count, 1,
                       "no fence of the late claim's own: \(wire)")
    }

    /// REVIEW-B. A stale foreign layout, then our fence's own resize, after
    /// the deadline: the late claim treats the unlanded foreign size as
    /// unsettled and settles late on its own acks, with no re-fence.
    func test_review_B_aStaleLayoutAfterTheDeadlineSettlesLate() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let stampGrids = recordStampGrids(controller, sent)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        ingestLayout(controller, Self.peerGrid)
        ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
        answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(stampGrids(), [FixtureGrid(columns: 92, rows: 38)], sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 1, "no re-fence: \(sent.string)")
    }

    /// REVIEW-D. An inline claim that never confirms (a laptop keeps
    /// `latest`, so our fence resizes nothing) reaches its deadline with
    /// its settle probe still out. A rotation under the restored veil then
    /// advertises nothing; the probe proves the loss, and the late claim
    /// ends without fencing or stamping.
    func test_review_D_anUnconfirmedLateClaimAdvertisesAndStampsNothing() {
        let (controller, sent, _) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
        fixture(controller).fenceTakesLatest = false
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "its settle probe is still out")
        controller.updateClientSize(cols: 100, rows: 30)
        let rotated = FixtureGrid(columns: 100, rows: 30)
        answerUntilSettled(controller, sent, answered: &index) { _ in
            self.deliverFencedLayout(controller, rotated)
        }
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "the probe's loss ends the late claim")
        XCTAssertFalse(sent.string.contains("refresh-client -C 100,30"), sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 1, "no fence after the deadline: \(sent.string)")
        XCTAssertEqual(stampWrites(sent), 0, sent.string)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
    }

    /// REVIEW-E. The settle probe proves a loss while the presentation is
    /// up, so the claim fences once more; the deadline passes with that
    /// re-fence on the wire. The late claim waits for its own acks and
    /// settles once the re-fence brings the window back.
    func test_review_E_aRefenceInFlightAtTheDeadlineSettlesLate() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let ours = FixtureGrid(columns: 92, rows: 38)
        let stampGrids = recordStampGrids(controller, sent)
        ingestLayout(controller, Self.peerGrid)
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(count("select-window", in: sent.string), 2, "the probe's loss re-fenced: \(sent.string)")
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "the re-fence is still on the wire")
        answerUntilSettled(controller, sent, answered: &index) { _ in
            self.deliverFencedLayout(controller, ours)
        }
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
        XCTAssertEqual(stampGrids(), [ours], sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 2, sent.string)
    }

    /// REVIEW-M3. Re-fenced and confirmed again (repainting at our grid)
    /// when the deadline passes: the late claim settles on its own acks.
    func test_review_M3_aRefencedClaimConfirmedAgainAtTheDeadlineSettlesLate() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let ours = FixtureGrid(columns: 92, rows: 38)
        let stampGrids = recordStampGrids(controller, sent)
        ingestLayout(controller, Self.peerGrid)
        answerRound(controller, sent, answered: &index)
        answerRound(controller, sent, answered: &index)
        deliverFencedLayout(controller, ours)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced, true)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(stampGrids(), [ours], sent.string)
    }

    /// REVIEW-M2kb. Two keyboard-animation frames while the claim repaints:
    /// each replay carries its own fence and re-targets the claim; the
    /// first frame's echo arrives with the grid already at the second. Our
    /// own grid is never a loss, so no re-fence is spent, and the claim,
    /// late by then, settles at the last grid it advertised.
    func test_review_M2kb_keyboardFramesSpendNoRefence() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        let stampGrids = recordStampGrids(controller, sent)
        controller.updateClientSize(cols: 92, rows: 34)
        controller.updateClientSize(cols: 92, rows: 30)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.targetGrid, .init(columns: 92, rows: 30))
        ingestLayout(controller, FixtureGrid(columns: 92, rows: 34))
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced, false)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        ingestLayout(controller, FixtureGrid(columns: 92, rows: 30))
        answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(stampGrids(), [FixtureGrid(columns: 92, rows: 30)], sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 3, "the first fence and one per frame: \(sent.string)")
    }

    /// REVIEW-F plus C6. A stalled generation ends at its deadline (rule 6).
    /// Its bounded replay remains a live claim and advertises local churn,
    /// while ownership and the stamp still wait for an authoritative frame.
    func test_review_F_stalledSideChannelClaimReplaysWithoutStampingBeforePaint() throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        controller.onGridAuthoritySideChannelRepaintRequired = { _, _ in }
        XCTAssertTrue(controller.reclaimGridAuthority())
        ackAllPending(controller, frames: 40)
        let laptop = "beef,105x31,0,0,0"
        fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 105, rows: 31)
        controller.ingest(Array("%layout-change @0 \(laptop) \(laptop) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        let failedClaim = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertGreaterThan(try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation), failedClaim)
        XCTAssertEqual(controller.gridAuthoritySessionForTesting.replay.count, 1)
        XCTAssertEqual(controller.gridAuthorityPresentation, .reclaiming(peerName: "iPhone", awaitingConnection: false))
        sent.clear()
        controller.updateClientSize(cols: 100, rows: 30)
        let rotated = "beef,100x30,0,0,0"
        controller.ingest(Array("%layout-change @0 \(rotated) \(rotated) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        XCTAssertTrue(sent.string.contains("resize-window -x 100 -y 30 -t @0"), sent.string)
        XCTAssertTrue(sent.string.contains("refresh-client -C 100,30"), sent.string)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.targetGrid, .init(columns: 100, rows: 30))
        XCTAssertFalse(sent.string.contains(stampWrite), sent.string)
        XCTAssertTrue(controller.gridAuthority.isPeer)
    }

    /// REVIEW-I. Side channel: the keyboard moves while the pre-stamp size
    /// read is on the wire. The read compares the window with the claim's
    /// target, never with the moving local grid, so the claim settles at
    /// its target instead of stranding, and the keyboard's size follows as
    /// an owner resize. Nothing claims or stamps after that without a
    /// gesture.
    func test_review_I_aResizeDuringThePreStampReadNeitherStrandsNorStampsAgain() throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in repaintGeneration = generation }
        XCTAssertTrue(controller.reclaimGridAuthority())
        let settled = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        controller.completeGridAuthoritySideChannelRepaint(generation: try XCTUnwrap(repaintGeneration))
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingStampCommit)
        controller.updateClientSize(cols: 92, rows: 30)
        ackAllPending(controller, frames: 40)
        let resized = "beef,92x30,0,0,0"
        controller.ingest(Array("%layout-change @0 \(resized) \(resized) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "stranded: \(sent.string)")
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(count(stampWrite, in: sent.string), 1, sent.string)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        sent.clear()
        controller.updateClientSize(cols: 80, rows: 30)
        XCTAssertFalse(sent.string.contains(stampWrite), "no stamp without a gesture: \(sent.string)")
        XCTAssertTrue(sent.string.contains("select-window"), "ordinary owner replay re-fences latest: \(sent.string)")
        XCTAssertFalse(sent.string.contains("select-window -t"), sent.string)
    }

    // MARK: §6.10 guards the review cases leave unexercised

    /// Rule 2 on the side channel: windows that hydrate only after the
    /// deadline are not forced to the local grid the late claim held back.
    /// Attach reads the stamp before it lists the windows, so a tap can
    /// land in between.
    func test_aLateClaimForcesNoWindowThatHydratesAfterItsDeadline() throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue, attach: false)
        let fixture = fixture(controller)
        controller.ingest(Array(Self.handshake.utf8))
        var number = 700
        func answerNext() {
            let lines = fixture.acknowledge(controller._debugPendingCommands.first)
            let frame = (["%begin 0 \(number) 1"] + lines + ["%end 0 \(number) 1"]).joined(separator: "\r\n") + "\r\n"
            number += 1
            controller.ingest(Array(frame.utf8))
        }
        while let next = controller._debugPendingCommands.first, !next.hasPrefix(Self.authorityRead), number < 760 {
            answerNext()
        }
        XCTAssertTrue(
            controller._debugPendingCommands.contains { $0.hasPrefix("list-windows ") },
            "the windows are still unlisted: \(sent.string)"
        )
        answerNext()
        XCTAssertTrue(controller.gridAuthority.isPeer, sent.string)
        XCTAssertTrue(controller.reclaimGridAuthority())
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim, "its own replies are still out")
        controller.updateClientSize(cols: 47, rows: 20)
        sent.clear()
        ackAllPending(controller, frames: 60)
        XCTAssertFalse(sent.string.contains("47"), "a late claim forces nothing: \(sent.string)")
    }

    /// Rule 2: a late claim whose fence waited for the window list fences
    /// nothing when hydration names the window after its deadline; it ends
    /// once its own commands are answered.
    func test_aLateClaimFencesNoWindowHydratedAfterItsDeadline() throws {
        let (controller, sent) = makeController(path: .inline, remoteStamp: Self.peerValue, attach: false)
        let fixture = fixture(controller)
        controller.ingest(Array(Self.handshake.utf8))
        var number = 700
        func answerNext() {
            let lines = fixture.acknowledge(controller._debugPendingCommands.first)
            let frame = (["%begin 0 \(number) 1"] + lines + ["%end 0 \(number) 1"]).joined(separator: "\r\n") + "\r\n"
            number += 1
            controller.ingest(Array(frame.utf8))
        }
        while let next = controller._debugPendingCommands.first, !next.hasPrefix(Self.authorityRead), number < 760 {
            answerNext()
        }
        answerNext()
        XCTAssertTrue(controller.gridAuthority.isPeer, sent.string)
        XCTAssertTrue(
            controller._debugPendingCommands.contains(TmuxRuntimeHydrationQuery.activeWindowCommand),
            "the active window is still unhydrated: \(controller._debugPendingCommands)"
        )
        controller.deferGridAuthorityWireTargetForTesting()
        sent.clear()
        XCTAssertTrue(controller.reclaimGridAuthority())
        let generation = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation)
        XCTAssertNil(controller.gridAuthoritySessionForTesting.claimFence, sent.string)
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, generation)
        // What the late claim wrote; a gesture it fails is replayed as a
        // new claim, which fences as any visible one does.
        var lateWire = sent.string
        var named = false
        while controller.gridAuthorityLifecycleForTesting.claim?.generation == generation,
              !controller._debugPendingCommands.isEmpty, number < 800 {
            answerNext()
            named = named || controller.activeWindowId != nil
            if controller.gridAuthorityLifecycleForTesting.claim?.generation == generation { lateWire = sent.string }
        }
        XCTAssertTrue(named, "hydration named the window: \(sent.string)")
        XCTAssertFalse(lateWire.contains("select-window"), "a late claim fences nothing: \(lateWire)")
        XCTAssertNotEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, generation, sent.string)
    }

    /// Rule 4: only a settle probe at the target proves the claim's grid
    /// landed. Once a probe found the window elsewhere, a cached layout
    /// still showing the target (its notification has not come) cannot
    /// confirm the re-fence on its acknowledgement; the re-fence's own
    /// probe decides, here as a second loss.
    func test_aRefenceAcknowledgedOverAStaleLayoutWaitsForTheProbe() {
        let (controller, sent, _) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
        let ours = FixtureGrid(columns: 92, rows: 38)
        let fixture = fixture(controller)
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        answerRound(controller, sent, answered: &index)
        deliverFencedLayout(controller, ours)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint, sent.string)
        // A laptop takes `latest` and keeps it; its layout has not arrived.
        fixture.observe(controller)
        fixture.grids[WindowId(0)] = Self.peerGrid
        fixture.fenceTakesLatest = false
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(count("select-window", in: sent.string), 2, "the probe's loss fences again: \(sent.string)")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced, true)
        let captures = count("capture-pane", in: sent.string)
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(
            controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence,
            "the stale layout does not confirm the re-fence: \(sent.string)"
        )
        answerUntilSettled(controller, sent, answered: &index)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "the re-fence's probe is a second loss")
        XCTAssertEqual(count("capture-pane", in: sent.string), captures, "nothing repainted over the laptop's grid: \(sent.string)")
        XCTAssertEqual(stampWrites(sent), 0, sent.string)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
    }

    /// Rule 6: a repaint whose delivery retries ran out is not waited on.
    /// A visible claim returns to its geometry phase and fences again; it
    /// settles once a frame can be delivered.
    func test_aClaimWhoseRepaintDeliveryIsExhaustedFencesAgain() async {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        controller.renderRefreshRetryDelay = 0.01
        controller.maxRenderRefreshAttempts = 0
        var accepting = false
        controller.renderFeedSurface = { _, _, _, _ in accepting }
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint, sent.string)
        for _ in 0..<50 where count("select-window", in: sent.string) < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(count("select-window", in: sent.string), 2, "fenced again: \(sent.string)")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced, false, "a stall spends no re-fence")
        accepting = true
        answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
    }

    /// Rule 7 (L4): a show over our own stamp that a stamp-less laptop
    /// keeps from landing loses twice and ends. The window is then judged
    /// as a read would judge it, so the device is veiled behind the laptop
    /// instead of left unveiled over a grid it does not own. The show's
    /// geometry hold does not defer that judgment: its read has resolved.
    func test_aShowThatEndsOverAStamplessSizerFallsBackToItsVeil() {
        let (controller, sent) = makeController(
            path: .inline, remoteStamp: selfValue(), remoteGrid: FixtureGrid(columns: 120, rows: 40)
        )
        fixture(controller).fenceTakesLatest = false
        controller.gridAuthorityShown()
        answerWire(controller, sent, authority: selfValue())
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, sent.string)
        XCTAssertEqual(count("select-window", in: sent.string), 2, "the show fenced and re-fenced: \(sent.string)")
        XCTAssertEqual(stampWrites(sent), 0, sent.string)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: TmuxStamplessPeer.displayName))
        assertAuthorityProjectionMatchesReducer(controller, "after the abort")
    }

    /// A foreign resize tmux applied after our capture but before our
    /// stamp. Its layout reaches us between the stamp write and the stamp's
    /// reply (`awaitingStampCommit`), where the claim can no longer be
    /// recalled and the stamp-less fallback is suppressed for the claim in
    /// flight. The settlement judges the window again and does not unveil
    /// this device as owner of a window another client sized.
    func test_aForeignLayoutBetweenTheStampAndItsReplyIsJudgedAtSettlement() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingStampCommit)
        // A laptop typed after our capture: tmux resized before our stamp ran.
        ingestLayout(controller, FixtureGrid(columns: 120, rows: 40))
        answerRound(controller, sent, answered: &index)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(
            controller.gridAuthority, .peer(displayName: TmuxStamplessPeer.displayName),
            "unveiled as owner over a window another client sized: presentation=\(controller.gridAuthorityPresentation)"
        )
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: TmuxStamplessPeer.displayName))
    }

    /// This device resizes while its stamp is on the wire (a rotation), and
    /// the stamp's reply beats the replay's layout. The window still has the
    /// grid we stamped, which is ours: the settlement must not take it for
    /// another client's.
    func test_aLocalResizeWhileTheStampIsInFlightIsNotAForeignLayoutAtSettlement() {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingStampCommit)
        let rotated = FixtureGrid(columns: 92, rows: 30)
        controller.updateClientSize(cols: rotated.columns, rows: rotated.rows)
        answerRound(controller, sent, answered: &index)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, sent.string)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
        // The resize then reaches the window as an ordinary owner resize.
        ingestLayout(controller, rotated)
        answerRound(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
    }

    /// P8 budget, geometry changed: the window resizes only after the
    /// fence's burst, so the visible repaint follows the confirmation, its
    /// metadata and capture together. The relayout is reduced before the
    /// confirmation, so the repaint is a rebuild.
    func test_inlineTakeBackThatResizesTheWindowCostsThreeRoundTrips() {
        let (controller, sent, feeds) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        let settled = "beef,92x38,0,0,0"
        let rounds = answerUntilSettled(controller, sent, answered: &index) { round in
            guard round == 1 else { return }
            // tmux applies the fence's deferred resize after the burst.
            self.fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
            controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        }

        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(rounds.count, 3, "\(rounds)")
        XCTAssertEqual(rounds.first, ["show-options -wA -v -t @0 window-size", "select-window"])
        // The settle probe leaves on the fence's reply; the repaint the
        // layout confirms queues behind it rather than waiting for it.
        let second = rounds.dropFirst().first ?? []
        XCTAssertEqual(second.count, 3, "\(rounds)")
        XCTAssertTrue(second.first.map(isSettleProbe) == true, "\(rounds)")
        XCTAssertTrue(second.dropFirst().first.map(isMetadataQuery) == true, "\(rounds)")
        XCTAssertEqual(second.last, "capture-pane -p -e -N -t @0")
        XCTAssertEqual(rounds.last?.count, 1, "\(rounds)")
        XCTAssertTrue(rounds.last?.first.map(isStampWrite) == true, "\(rounds)")
        // The window reflowed to our grid, so its visible rows are rebuilt,
        // not scrubbed in place over history wrapped for the peer's grid...
        XCTAssertEqual(feeds.sources, [.viewportRepaint])
        XCTAssertFalse(rounds.joined().contains { $0.contains("-S -") }, "no 2,000-row capture before the unveil: \(rounds)")
        // ...and deepened once the claim settled.
        answerRound(controller, sent, answered: &index)
        XCTAssertTrue(sent.string.contains("capture-pane -p -e -N -S -"), sent.string)
    }

    // MARK: The production ingest path

    /// `answerRound`, delivering each reply through `ingestCooperatively`,
    /// the entry point SessionView's inline SSH loop uses.
    @discardableResult
    private func answerRoundCooperatively(
        _ controller: TmuxController,
        _ sent: ByteSink,
        answered index: inout Int,
        limit: Int = .max,
        authority: String? = nil
    ) async -> [String] {
        let lines = sent.string.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        let round = Array(lines[index...].prefix(limit))
        index += round.count
        let fixture = fixture(controller)
        for (offset, command) in round.enumerated() {
            var body: [String]
            if command.hasPrefix(Self.authorityRead) {
                body = [authority ?? Self.peerValue]
            } else if command.hasPrefix("display-message -p -t "), command.contains("#{cursor_x}") {
                body = [renderMetadata(pane: 0)]
            } else if command.hasPrefix("capture-pane ") {
                body = ["authoritative viewport"]
            } else {
                fixture.observe(controller)
                body = fixture.acknowledge(command)
            }
            let number = 7_000 + index * 10 + offset
            let frame = (["%begin 0 \(number) 1"] + body + ["%end 0 \(number) 1"])
                .joined(separator: "\r\n") + "\r\n"
            _ = await controller.ingestCooperatively(Array(frame.utf8))
        }
        return round
    }

    private func ingestLayoutCooperatively(_ controller: TmuxController, _ grid: FixtureGrid) async {
        fixture(controller).grids[WindowId(0)] = grid
        let layout = "beef,\(grid.columns)x\(grid.rows),0,0,0"
        _ = await controller.ingestCooperatively(Array("%layout-change @0 \(layout) \(layout) *\r\n".utf8))
    }

    /// `answerUntilSettled` on the production ingest path.
    private func answerUntilSettledCooperatively(
        _ controller: TmuxController,
        _ sent: ByteSink,
        answered index: inout Int,
        afterRound: (Int) async -> Void = { _ in }
    ) async -> [[String]] {
        var rounds: [[String]] = []
        while controller.gridAuthority != .mine, rounds.count < 8 {
            let round = await answerRoundCooperatively(controller, sent, answered: &index)
            guard !round.isEmpty else { break }
            rounds.append(round)
            await afterRound(rounds.count)
        }
        return rounds
    }

    /// `test_inlineTakeBackAtUnchangedGeometryCostsTwoRoundTrips` through
    /// `ingestCooperatively`.
    func test_cooperativeInlineTakeBackAtUnchangedGeometryCostsTwoRoundTrips() async {
        let (controller, sent, feeds) = makePaintedYieldedController(remoteGrid: FixtureGrid(columns: 92, rows: 38))
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        let rounds = await answerUntilSettledCooperatively(controller, sent, answered: &index)

        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
        XCTAssertEqual(rounds.count, 2, "\(rounds)")
        let burst = rounds.first ?? []
        XCTAssertEqual(burst.count, 4, "\(burst)")
        XCTAssertEqual(burst.first, "show-options -wA -v -t @0 window-size")
        XCTAssertEqual(burst.dropFirst().first, "select-window")
        XCTAssertTrue(burst.dropFirst(2).first.map(isMetadataQuery) == true, "\(burst)")
        XCTAssertEqual(burst.last, "capture-pane -p -e -N -t @0")
        // The settle probe goes out on the fence's reply, beside the stamp
        // the repaint authorized: it adds no round trip (§6.10 rule 5).
        XCTAssertEqual(rounds.last?.count, 2, "\(rounds)")
        XCTAssertTrue(rounds.last?.first.map(isSettleProbe) == true, "\(rounds)")
        XCTAssertTrue(rounds.last?.last.map(isStampWrite) == true, "\(rounds)")
        XCTAssertEqual(feeds.sources, [.viewportRefresh], "one in-place visible repaint")
        XCTAssertEqual(count("capture-pane", in: sent.string), 1, sent.string)
    }

    /// `test_inlineTakeBackThatResizesTheWindowCostsThreeRoundTrips` through
    /// `ingestCooperatively`. The `%layout-change` that brings the window to
    /// our grid is the only confirmation (the fence's reply came first), and
    /// `handleLayoutChange` defers it to the end of its step. A drain only
    /// `process(steps:)` performed left this claim unconfirmed forever.
    func test_cooperativeInlineTakeBackThatResizesTheWindowCostsThreeRoundTrips() async {
        let (controller, sent, feeds) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        let rounds = await answerUntilSettledCooperatively(controller, sent, answered: &index) { round in
            guard round == 1 else { return }
            // tmux applies the fence's deferred resize after the burst.
            await self.ingestLayoutCooperatively(controller, FixtureGrid(columns: 92, rows: 38))
        }

        XCTAssertEqual(
            controller.gridAuthority, .mine,
            "stuck: \(rounds) claim=\(controller.gridAuthorityLifecycleForTesting.claim.traceLabel)"
        )
        XCTAssertEqual(rounds.count, 3, "\(rounds)")
        XCTAssertEqual(rounds.first, ["show-options -wA -v -t @0 window-size", "select-window"])
        // The settle probe leaves on the fence's reply; the repaint the
        // layout confirms queues behind it rather than waiting for it.
        let second = rounds.dropFirst().first ?? []
        XCTAssertEqual(second.count, 3, "\(rounds)")
        XCTAssertTrue(second.first.map(isSettleProbe) == true, "\(rounds)")
        XCTAssertTrue(second.dropFirst().first.map(isMetadataQuery) == true, "\(rounds)")
        XCTAssertEqual(second.last, "capture-pane -p -e -N -t @0")
        XCTAssertEqual(rounds.last?.count, 1, "\(rounds)")
        XCTAssertTrue(rounds.last?.first.map(isStampWrite) == true, "\(rounds)")
        XCTAssertEqual(feeds.sources, [.viewportRepaint])
        XCTAssertFalse(rounds.joined().contains { $0.contains("-S -") }, "no 2,000-row capture before the unveil: \(rounds)")
        await answerRoundCooperatively(controller, sent, answered: &index)
        XCTAssertTrue(sent.string.contains("capture-pane -p -e -N -S -"), sent.string)
    }

    /// Only the settling `%layout-change` takes the production path; the
    /// replies go through `ingest`. The confirmation belongs to the layout's
    /// own step, not to whichever synchronous batch comes next.
    func test_cooperativeLayoutChangeAloneConfirmsAResizedTakeBack() async {
        let (controller, sent, _) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        answerRound(controller, sent, answered: &index)
        await ingestLayoutCooperatively(controller, FixtureGrid(columns: 92, rows: 38))
        XCTAssertEqual(
            controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint,
            "the layout at our grid confirms the claim: \(controller.gridAuthorityLifecycleForTesting.claim.traceLabel) wire=\(sent.string)"
        )
        let rounds = answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, "\(rounds)")
    }

    /// The no-peer show after a rotation
    /// (`test_noPeerShowClaimThatResizesTheWindowRebuildsAndDeepens`) on the
    /// production ingest path, where its confirmation is deferred too: it
    /// rebuilds the reflowed window, never scrubs it in place, and deepens
    /// its history only after the stamp.
    func test_cooperativeNoPeerShowClaimThatResizesTheWindowSettles() async {
        let (controller, sent) = makeOwnerController(path: .inline)
        let feeds = FeedLog()
        controller.renderFeedSurface = { _, _, _, source in
            feeds.sources.append(source)
            return true
        }
        let owned = "beef,92x38,0,0,0"
        controller.ingest(Array("%layout-change @0 \(owned) \(owned) *\r\n%window-pane-changed @0 %0\r\n".utf8))
        sent.clear()
        controller.submitRenderFact(.refreshRequested(.live, stage: .deep, reason: "test-paint"))
        answerWire(controller, sent, authority: selfValue())
        sent.clear()

        controller.prepareForAppInactivity()
        controller.updateClientSize(cols: 100, rows: 40)
        controller.refreshActiveWindowOnForeground()
        controller.gridAuthorityShown()
        controller.renderCommandQueueMaxWait = 0.05
        var index = 0
        var feedsAtRelayout: Int?
        var rounds: [[String]] = []
        while rounds.count < 16 {
            let lines = { sent.string.split(separator: "\n", omittingEmptySubsequences: false).count - 1 }
            for _ in 0..<30 where lines() <= index {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let round = await answerRoundCooperatively(controller, sent, answered: &index, authority: selfValue())
            guard !round.isEmpty else { break }
            rounds.append(round)
            if round.contains("select-window"), feedsAtRelayout == nil {
                feedsAtRelayout = feeds.sources.count
                // tmux applies the fence's deferred resize after its burst.
                await ingestLayoutCooperatively(controller, FixtureGrid(columns: 100, rows: 40))
            }
        }
        XCTAssertNotNil(feedsAtRelayout, "\(rounds)")
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim, "stuck: \(rounds)")
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(stampWrites(sent), 1, "\(rounds)")
        let claimFeeds = Array(feeds.sources.dropFirst(feedsAtRelayout ?? 0))
        XCTAssertTrue(claimFeeds.contains(.viewportRepaint), "the reflowed window is rebuilt: \(claimFeeds)")
        XCTAssertFalse(claimFeeds.contains(.viewportRefresh), "never scrubbed in place: \(claimFeeds)")
        let wire = sent.string.split(separator: "\n").map(String.init)
        let stamp = wire.firstIndex(where: isStampWrite) ?? .max
        let deep = wire.firstIndex { $0.hasPrefix("capture-pane -p -e -N -S -") }
        XCTAssertNotNil(deep, "then its history: \(rounds)")
        XCTAssertGreaterThan(deep ?? -1, stamp, "no deep capture ahead of the stamp: \(rounds)")
    }

    /// One socket read on the cooperative path carrying the probe and fence
    /// replies, the resize's `%layout-change` and output between every
    /// step, slow enough that the budget yields mid-batch. The claim
    /// confirms at the layout's own step, not at the batch end, and costs
    /// one repaint.
    func test_review_singleReadWithYieldsConfirmsAtTheLayoutStep() async {
        let (controller, sent, feeds) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
        controller.renderFeedSurface = { _, _, _, source in
            feeds.sources.append(source)
            if source == .paneOutput { usleep(5_000) }
            return true
        }
        XCTAssertTrue(controller.reclaimGridAuthority())
        let burst = sent.string.split(separator: "\n").map(String.init)
        XCTAssertEqual(burst, ["show-options -wA -v -t @0 window-size", "select-window"], sent.string)
        fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
        let text = String(repeating: "x", count: 600)
        let owned = "beef,92x38,0,0,0"
        var read = ""
        read += "%output %0 A\(text)\r\n"
        read += "%begin 0 9001 1\r\n%end 0 9001 1\r\n"
        read += "%output %0 B\(text)\r\n"
        read += "%begin 0 9002 1\r\n%end 0 9002 1\r\n"
        read += "%output %0 C\(text)\r\n"
        read += "%layout-change @0 \(owned) \(owned) *\r\n"
        read += "%output %0 D\(text)\r\n"
        read += "%output %0 E\(text)\r\n"
        let yielded = await controller.ingestCooperatively(Array(read.utf8))
        XCTAssertTrue(yielded, "the budget must yield mid-batch for this read to mean anything")
        XCTAssertEqual(
            controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint,
            "claim=\(controller.gridAuthorityLifecycleForTesting.claim.traceLabel) wire=\(sent.string)"
        )
        var index = burst.count
        let rounds = await answerUntilSettledCooperatively(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, "\(rounds)")
        XCTAssertEqual(rounds.count, 2, "repaint round then stamp: \(rounds)")
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
        XCTAssertEqual(count("capture-pane -p -e -N -t @0", in: sent.string), 1, sent.string)
    }

    /// A synchronous adapter can answer from inside the step that wrote to
    /// it (`sendBytes` re-entering ingest). On the side channel a split
    /// layout that settles the claim also writes mosh's pane-border options
    /// before its step ends, so such a nested step ends before the outer
    /// step's ledger reduce. It must leave the outer step's deferred
    /// confirmation alone, or the frame is reserved against the owner the
    /// split is about to replace.
    func test_aNestedSynchronousStepLeavesTheOuterDeferralAlone() {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var frames = 0
        controller.onGridAuthoritySideChannelRepaintRequired = { _, _ in frames += 1 }
        XCTAssertTrue(controller.reclaimGridAuthority())
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence, sent.string)
        XCTAssertEqual(frames, 0)
        let fixture = fixture(controller)
        var nestedPhases: [TmuxGridAuthorityLifecycleReducer.ClaimPhase?] = []
        controller.sendBytes = { bytes in
            sent.append(bytes)
            fixture.noteSent(bytes)
            guard String(decoding: bytes, as: UTF8.self).contains("pane-border-status") else { return }
            controller.ingest(Array("%output %0 nested\r\n".utf8))
            nestedPhases.append(controller.gridAuthorityLifecycleForTesting.claim?.phase)
        }
        let split = "cafe,92x38,0,0{46x38,0,0,0,45x38,47,0,1}"
        controller.ingest(Array("%layout-change @0 \(split) \(split) *\r\n".utf8))
        XCTAssertFalse(nestedPhases.isEmpty, "the split wrote no pane-border option: \(sent.string)")
        XCTAssertEqual(Set(nestedPhases), [.awaitingFence], "a nested step drained the outer deferral")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint, sent.string)
        XCTAssertEqual(frames, 1, "one frame for one claim")
    }

    /// The nested step can itself carry the layout and ask to confirm. It
    /// keeps the outer step's depth: the confirmation still waits for the
    /// outer step's ledger reduce.
    func test_aNestedLayoutStepKeepsTheOuterDeferral() {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var frames = 0
        controller.onGridAuthoritySideChannelRepaintRequired = { _, _ in frames += 1 }
        XCTAssertTrue(controller.reclaimGridAuthority())
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence, sent.string)
        let fixture = fixture(controller)
        let split = "cafe,92x38,0,0{46x38,0,0,0,45x38,47,0,1}"
        var nestedPhases: [TmuxGridAuthorityLifecycleReducer.ClaimPhase?] = []
        controller.sendBytes = { bytes in
            sent.append(bytes)
            fixture.noteSent(bytes)
            guard nestedPhases.isEmpty,
                  String(decoding: bytes, as: UTF8.self).contains("pane-border-status")
            else { return }
            nestedPhases.append(nil)
            controller.ingest(Array("%layout-change @0 \(split) \(split) *\r\n".utf8))
            nestedPhases.append(controller.gridAuthorityLifecycleForTesting.claim?.phase)
        }
        controller.ingest(Array("%layout-change @0 \(split) \(split) *\r\n".utf8))
        XCTAssertEqual(nestedPhases, [nil, .awaitingFence], "a nested layout step confirmed early: \(sent.string)")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint, sent.string)
        XCTAssertEqual(frames, 1, "one frame for one claim")
    }

    /// The same read with the layout ahead of the fence's reply: the
    /// layout's step stays silent (fence unacknowledged) and the fence's own
    /// confirmation takes over.
    func test_review_layoutBeforeFenceReplyInOneCooperativeRead() async {
        let (controller, sent, _) = makePaintedYieldedController(remoteGrid: Self.peerGrid)
        XCTAssertTrue(controller.reclaimGridAuthority())
        let burst = sent.string.split(separator: "\n").map(String.init)
        fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
        let owned = "beef,92x38,0,0,0"
        let read = "%begin 0 9001 1\r\n%end 0 9001 1\r\n"
            + "%layout-change @0 \(owned) \(owned) *\r\n"
            + "%begin 0 9002 1\r\n%end 0 9002 1\r\n"
        _ = await controller.ingestCooperatively(Array(read.utf8))
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint)
        var index = burst.count
        let rounds = await answerUntilSettledCooperatively(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, "\(rounds)")
        XCTAssertEqual(stampWrites(sent), 1, sent.string)
        XCTAssertEqual(count("capture-pane -p -e -N -t @0", in: sent.string), 1, sent.string)
    }

    /// A window created during the take-back becomes current before tmux
    /// announces it, and control mode never sends its layout: the
    /// `%window-add` details reply alone describes it. That reply is a
    /// command correlation, not a notification, and when it shows the window
    /// at our grid it confirms the claim at the end of its own step, on
    /// either ingest path.
    func test_aWindowDetailsReplyAtOurGridConfirmsTheClaimOnEitherIngestPath() async {
        for cooperative in [false, true] {
            let (controller, sent, _) = makePaintedYieldedController(remoteGrid: FixtureGrid(columns: 92, rows: 38))
            XCTAssertTrue(controller.reclaimGridAuthority())
            let created = Array("%session-window-changed $0 @1\r\n%window-add @1\r\n".utf8)
            if cooperative {
                _ = await controller.ingestCooperatively(created)
            } else {
                controller.ingest(created)
            }
            fixture(controller).grids[WindowId(1)] = FixtureGrid(columns: 92, rows: 38)
            let details = TmuxRuntimeHydrationQuery.windowDetailsCommand(windowID: WindowId(1))
            var wire: [String] { sent.string.split(separator: "\n").map(String.init) }
            guard let detailsIndex = wire.firstIndex(of: details) else {
                XCTFail("cooperative=\(cooperative) no details query: \(sent.string)")
                continue
            }
            var index = 0
            if cooperative {
                await answerRoundCooperatively(controller, sent, answered: &index, limit: detailsIndex)
            } else {
                answerRound(controller, sent, answered: &index, limit: detailsIndex)
            }
            XCTAssertEqual(
                controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence,
                "cooperative=\(cooperative) the new window's grid is unknown: \(sent.string)"
            )
            XCTAssertNil(controller.windows.first { $0.id == WindowId(1) }?.layout)
            if cooperative {
                await answerRoundCooperatively(controller, sent, answered: &index, limit: 1)
            } else {
                answerRound(controller, sent, answered: &index, limit: 1)
            }
            XCTAssertEqual(
                controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint,
                "cooperative=\(cooperative) the details reply confirms the claim: \(sent.string)"
            )
            XCTAssertTrue(
                wire.dropFirst(index).contains("capture-pane -p -e -N -t @1"),
                "cooperative=\(cooperative) the confirmation repaints the new window: \(sent.string)"
            )
        }
    }

    /// P7: a peer's relayouts (a phone's keyboard toggling) cost the veiled
    /// device no capture; its take-back rebuilds the visible rows once.
    func test_peerRelayoutsWhileVeiledCaptureNothingAndTheTakeBackRebuildsOnce() {
        let (controller, sent, feeds) = makePaintedYieldedController(remoteGrid: FixtureGrid(columns: 92, rows: 38))
        for rows in [20, 24, 20, 38] {
            let layout = "beef,92x\(rows),0,0,0"
            controller.ingest(Array("%layout-change @0 \(layout) \(layout) *\r\n".utf8))
        }
        XCTAssertFalse(sent.string.contains("capture-pane"), sent.string)
        XCTAssertFalse(sent.string.contains("#{cursor_x}"), sent.string)
        XCTAssertEqual(feeds.sources, [])

        sent.clear()
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        let rounds = answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(rounds.count, 2, "\(rounds)")
        XCTAssertEqual(feeds.sources, [.viewportRepaint], "the missed relayouts force a rebuild")
        // Nothing but the stamp (beside the fence's settle probe) between
        // the visible rebuild and the unveil: the deepening's metadata must
        // not ride ahead of it.
        XCTAssertEqual(rounds.last?.count, 2, "\(rounds)")
        XCTAssertTrue(rounds.last?.first.map(isSettleProbe) == true, "\(rounds)")
        XCTAssertTrue(rounds.last?.last.map(isStampWrite) == true, "\(rounds)")
        let beforeSettle = rounds.flatMap { $0 }
        XCTAssertFalse(beforeSettle.contains { $0.contains("-S -") }, "\(beforeSettle)")
        // Then the history, after the stamp settled.
        answerRound(controller, sent, answered: &index)
        XCTAssertTrue(sent.string.contains("capture-pane -p -e -N -S -"), sent.string)
    }

    /// A peer relayout racing the take-back leaves the claim unconfirmed at
    /// the fence's reply, so the early capture lands before anything can
    /// count it; the confirmation once the window settles asks for its own.
    func test_claimRepaintLandingBeforeConfirmationIsNotCounted() {
        let (controller, sent, feeds) = makePaintedYieldedController(remoteGrid: FixtureGrid(columns: 92, rows: 38))
        XCTAssertTrue(controller.reclaimGridAuthority())
        // The peer's keyboard rises before tmux runs our fence.
        let peerLayout = "beef,92x20,0,0,0"
        fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 20)
        controller.ingest(Array("%layout-change @0 \(peerLayout) \(peerLayout) *\r\n".utf8))
        var index = 0
        let first = answerRound(controller, sent, answered: &index)
        XCTAssertEqual(first.count, 4, "\(first)")
        XCTAssertTrue(controller.gridAuthority.isPeer)
        XCTAssertEqual(feeds.sources.count, 1, "the early capture landed under the veil")

        // Our fence's deferred resize, then the confirmation's own repaint.
        let settled = "beef,92x38,0,0,0"
        fixture(controller).grids[WindowId(0)] = FixtureGrid(columns: 92, rows: 38)
        controller.ingest(Array("%layout-change @0 \(settled) \(settled) *\r\n".utf8))
        let rounds = answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, "\(rounds)")
        XCTAssertEqual(rounds.count, 2, "\(rounds)")
        // The repaint queues behind the fence's settle probe.
        XCTAssertTrue(rounds.first?.first.map(isSettleProbe) == true, "\(rounds)")
        XCTAssertTrue(rounds.first?.dropFirst().first.map(isMetadataQuery) == true, "\(rounds)")
        XCTAssertEqual(feeds.sources.count, 2)
    }

    /// If the repaint the confirmation adopted ends without a frame, the
    /// claim asks for the ordinary repaint instead of staying veiled.
    func test_adoptedClaimRepaintThatFailsFallsBackToTheForegroundRepaint() async {
        let (controller, sent, feeds) = makePaintedYieldedController(remoteGrid: FixtureGrid(columns: 92, rows: 38))
        controller.renderCommandQueueMaxWait = 0.01
        XCTAssertTrue(controller.reclaimGridAuthority())
        // Answer the probe and the fence only: the claim confirms and adopts
        // the repaint still in flight behind them. The fence's settle probe
        // queues behind that repaint; it is the wire's next unanswered line.
        sent.clear()
        let fixture = fixture(controller)
        for (number, command) in ["show-options -wA -v -t @0 window-size", "select-window"].enumerated() {
            fixture.observe(controller)
            let body = (["%begin 0 \(4_000 + number) 1"] + fixture.acknowledge(command) + ["%end 0 \(4_000 + number) 1"])
            controller.ingest(Array((body.joined(separator: "\r\n") + "\r\n").utf8))
        }
        XCTAssertEqual(controller.gridAuthorityRepaintWindowTargetForTesting, WindowId(0))
        XCTAssertTrue(sent.string.split(separator: "\n").first.map { isSettleProbe(String($0)) } == true, sent.string)
        // Another correlated refresh supersedes it before its reply.
        controller.submitRenderFact(.correlatedRefreshRequested(
            .live, stage: .viewportOnly, reason: "test-supersede", correlation: 999_999
        ))
        // The superseding refresh sends its own metadata at once; the
        // fallback's follows once the queue wait for the stale pair expires.
        for _ in 0..<200 where count("#{cursor_x}", in: sent.string) < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(count("#{cursor_x}", in: sent.string), 2, "fallback repaint: \(sent.string)")

        // The superseded pair's replies are stale; the fallback's complete it.
        var number = 4_100
        for command in ["metadata", "capture"] {
            let body = command == "metadata" ? [renderMetadata(pane: 0)] : ["superseded"]
            controller.ingest(Array(((["%begin 0 \(number) 1"] + body + ["%end 0 \(number) 1"]).joined(separator: "\r\n") + "\r\n").utf8))
            number += 1
        }
        var index = 0
        _ = answerUntilSettled(controller, sent, answered: &index)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertFalse(feeds.sources.isEmpty)
    }


    // MARK: P11: diagnostics scale with edges, not frames

    /// 100 keyboard-animation frames: a local resize and the window's
    /// `%layout-change` each. Returns the diagnostic lines they produced.
    private func resizeStormDiagnostics(_ controller: TmuxController) -> [String] {
        var lines: [String] = []
        TmuxDiagnostics.sink = { lines.append($0) }
        defer { TmuxDiagnostics.sink = nil }
        for frame in 0..<100 {
            let rows = 38 - (frame % 18)
            controller.updateClientSize(cols: 92, rows: rows)
            let layout = "beef,92x\(rows),0,0,0"
            controller.ingest(Array("%layout-change @0 \(layout) \(layout) *\r\n".utf8))
        }
        return lines
    }

    /// A gate episode ends with its connection: the repeats are counted
    /// into their line at the disconnect, and the next connection's gate
    /// logs its own first line rather than counting on as one episode.
    func test_clientSizeGateEpisodeEndsWithItsConnection() {
        for full in [false, true] {
            let (controller, _) = makeController(path: .sideChannel)
            deliverStamp(controller, value: Self.peerValue)
            var lines: [String] = []
            TmuxDiagnostics.sink = { lines.append($0) }
            defer { TmuxDiagnostics.sink = nil }
            controller.updateClientSize(cols: 47, rows: 20)
            controller.updateClientSize(cols: 47, rows: 19)
            controller.updateClientSize(cols: 47, rows: 18)
            XCTAssertEqual(lines.filter { $0.hasPrefix("client-size ") }.count, 1, "\(lines)")

            lines.removeAll()
            if full { controller.reset() } else { controller.sideChannelDisconnected() }
            XCTAssertTrue(
                lines.contains("client-size deferred (yielded) repeated=2"),
                "full=\(full): \(lines.filter { $0.hasPrefix("client-size") })"
            )
        }
    }

    /// Review finding 4: a `%session-changed` to another session starts a
    /// new connection generation without a disconnect. The gate episode
    /// ends with it, as with a disconnect: its repeats are counted then,
    /// and the next gated size opens a new episode.
    func test_sessionChangeEndsTheClientSizeGateEpisode() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makeController(path: path)
            deliverStamp(controller, value: Self.peerValue)
            var lines: [String] = []
            TmuxDiagnostics.sink = { lines.append($0) }
            defer { TmuxDiagnostics.sink = nil }
            controller.updateClientSize(cols: 47, rows: 20)
            controller.updateClientSize(cols: 47, rows: 19)
            controller.updateClientSize(cols: 47, rows: 18)
            XCTAssertEqual(lines.filter { $0.hasPrefix("client-size ") }.count, 1, "\(path): \(lines)")

            lines.removeAll()
            controller.ingest(Array("%session-changed $1 other\r\n".utf8))
            XCTAssertTrue(
                lines.contains("client-size deferred (yielded) repeated=2"),
                "\(path): \(lines.filter { $0.hasPrefix("client-size") })"
            )
            lines.removeAll()
            controller.updateClientSize(cols: 47, rows: 17)
            XCTAssertEqual(
                lines.filter { $0.hasPrefix("client-size ") && !$0.contains("repeated=") }.count,
                1,
                "\(path): the new session's gate logs its own first line: \(lines)"
            )
        }
    }

    /// Review finding 5 (P7): on a compact device each relayout of a peer's
    /// changes the focused pane's geometry, and the pane grid asked for a
    /// deep capture every time. While the peer holds the grid that repaint
    /// is owed (the ledger recorded the relayout); an owner still gets it.
    func test_compactPaneGeometryRefreshIsOwedWhileYielded() {
        for yielded in [true, false] {
            let (controller, sent) = makeController(
                path: .inline,
                localCols: 80,
                localRows: 24,
                remoteStamp: yielded ? Self.peerValue : selfValue(),
                remoteGrid: FixtureGrid(columns: 80, rows: 24)
            )
            let split = "beef,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"
            controller.ingest(Array("%layout-change @0 \(split) \(split) *\r\n%window-pane-changed @0 %0\r\n".utf8))
            controller.setGridAuthorityUsesCompactSinglePaneGrid(true)
            controller.setPaneSink(PaneId(0)) { _ in }
            ackAllPending(controller, frames: 40)
            XCTAssertEqual(controller.gridAuthority.isPeer, yielded)
            let moved = "cafe,80x24,0,0{30x24,0,0,0,49x24,31,0,1}"
            controller.ingest(Array("%layout-change @0 \(moved) \(moved) *\r\n".utf8))
            ackAllPending(controller, frames: 40)
            sent.clear()

            controller.refreshPaneAfterCompactGeometryChange(paneId: PaneId(0))
            if yielded {
                XCTAssertFalse(sent.string.contains("capture-pane"), sent.string)
                XCTAssertFalse(sent.string.contains("#{cursor_x}"), sent.string)
            } else {
                XCTAssertTrue(
                    sent.string.contains("display-message -p -t %0 '#{pane_id}"),
                    "an owner still rebuilds the pane: \(sent.string)"
                )
            }
        }
    }

    /// The review measured 7.1 lines per frame for an owner against 4.1 for
    /// a device outside grid authority: a stamp write and its transmit lines
    /// on every replay (removed by P5). An owner now logs what any device
    /// logs, and a yielded one logs its withheld sizes once per edge.
    func test_resizeStormDiagnosticsScaleWithEdgesNotAuthority() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let outside = resizeStormDiagnostics(makeController(
                path: path,
                identity: nil,
                remoteGrid: FixtureGrid(columns: 92, rows: 38)
            ).controller)
            let owner = resizeStormDiagnostics(makeOwnerController(path: path).controller)
            let yielded = resizeStormDiagnostics(makeController(
                path: path,
                remoteStamp: Self.peerValue,
                remoteGrid: FixtureGrid(columns: 92, rows: 38)
            ).controller)

            XCTAssertGreaterThan(outside.count, 0)
            XCTAssertLessThanOrEqual(owner.count, outside.count, "\(path): \(Set(owner.map { $0.prefix(40) }))")
            XCTAssertFalse(owner.contains { $0.hasPrefix("grid-authority stamp") }, "\(path)")
            let withheld = yielded.filter { $0.hasPrefix("client-size ") }
            XCTAssertEqual(withheld.count, 1, "\(path): \(withheld)")
        }
    }
}

extension GridAuthorityTests {
    @discardableResult
    private func review610ReplyNext(
        _ controller: TmuxController,
        _ sent: ByteSink,
        answered index: inout Int,
        success: Bool = true,
        body override: [String]? = nil
    ) -> String? {
        let wire = sent.string.split(separator: "\n").map(String.init)
        guard index < wire.count else { return nil }
        let command = wire[index]
        index += 1

        let body: [String]
        if let override {
            body = override
        } else if isMetadataQuery(command) {
            body = [renderMetadata(pane: targetPane(of: command) ?? 0)]
        } else if command.hasPrefix("capture-pane ") {
            body = ["authoritative viewport"]
        } else {
            let remote = fixture(controller)
            remote.observe(controller)
            body = remote.acknowledge(command)
        }

        let number = 99_000 + index
        let end = success ? "%end" : "%error"
        let frame = (
            ["%begin 0 \(number) 1"] + body + ["\(end) 0 \(number) 1"]
        ).joined(separator: "\r\n") + "\r\n"
        controller.ingest(Array(frame.utf8))
        return command
    }

    func test_review610_exhaustedReplacementRepaintEndsAtDeadline() async {
        let (controller, sent, start) = makeConfirmedTakeBack()
        var index = start
        var failedCaptures = 0
        controller.maxRenderRefreshAttempts = 0
        controller.renderCommandQueueMaxWait = 0
        controller.renderRefreshRetryDelay = 0.01

        // Fail both the correlated capture and its foreground replacement.
        // Answer every other command successfully, including the settle probe.
        for _ in 0..<80 {
            let wire = sent.string.split(separator: "\n").map(String.init)
            if index < wire.count {
                let capture = wire[index].hasPrefix("capture-pane ")
                if capture { failedCaptures += 1 }
                review610ReplyNext(
                    controller, sent, answered: &index,
                    success: !capture
                )
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        XCTAssertGreaterThanOrEqual(failedCaptures, 2, sent.string)
        XCTAssertEqual(index, sent.string.split(separator: "\n").count)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingFence,
                       "visible exhaustion returns to geometry, with no repaint left to wait on")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.geometryRefenced, false)
        let failedClaim = controller.gridAuthorityLifecycleForTesting.claim?.generation
        controller.expireGridAuthorityReclaimPresentationForTesting()

        XCTAssertNotEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, failedClaim,
                          "exhaustion must end the original claim")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.reason, .userTakeBack)
        XCTAssertEqual(controller.gridAuthoritySessionForTesting.replay.count, 1)
        XCTAssertEqual(stampWrites(sent), 0)
    }

    func test_review610_finalSideProbeConfirmsBeforeStallCheck() throws {
        let (controller, sent) = makeController(
            path: .sideChannel, remoteStamp: Self.peerValue
        )
        var repaintGeneration: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = {
            _, generation in repaintGeneration = generation
        }
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0

        // Drain the force, unset, policy and fence, stopping at the
        // force's first confirmation read.
        for _ in 0..<20 {
            let wire = sent.string.split(separator: "\n").map(String.init)
            guard index < wire.count else {
                XCTFail("Missing force confirmation: \(sent.string)")
                return
            }
            if isSettleProbe(wire[index]) { break }
            review610ReplyNext(controller, sent, answered: &index)
        }
        let firstRead = try XCTUnwrap(
            review610ReplyNext(
                controller, sent, answered: &index,
                body: ["tessera-window-size\t@0\t105\t31"]
            )
        )
        XCTAssertTrue(isSettleProbe(firstRead))

        // The force's first read caught the old grid. Its later layout
        // lands while the fence's separate probe is still outstanding.
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
        ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
        XCTAssertEqual(
            controller.gridAuthorityLifecycleForTesting.claim?.phase,
            .awaitingFence
        )

        let finalRead = try XCTUnwrap(
            review610ReplyNext(
                controller, sent, answered: &index,
                body: ["tessera-window-size\t@0\t92\t38"]
            )
        )
        XCTAssertTrue(isSettleProbe(finalRead))
        XCTAssertEqual(
            controller.gridAuthorityLifecycleForTesting.claim?.phase,
            .awaitingRepaint,
            "The successful last probe must request repaint before stalling"
        )
        let generation = try XCTUnwrap(repaintGeneration)
        controller.completeGridAuthoritySideChannelRepaint(
            generation: generation
        )
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(stampWrites(sent), 1)
    }
}


extension GridAuthorityTests {
    func test_review610_ordinaryForegroundRepaintExhaustionAbortsLateClaim() async {
        let (controller, sent, start) = makeConfirmedTakeBack()
        let failedClaim = controller.gridAuthorityLifecycleForTesting.claim?.generation
        var index = start
        controller.maxRenderRefreshAttempts = 1
        controller.renderCommandQueueMaxWait = 0
        controller.renderRefreshRetryDelay = 0.01
        // Supersede the correlated repaint with ordinary foreground work.
        // Its fail-closed retained ownership is not a repaint in flight.
        controller.refreshActiveWindowOnForeground()
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
        var failedCaptures = 0
        for _ in 0..<100 {
            let wire = sent.string.split(separator: "\n").map(String.init)
            if index < wire.count {
                let capture = wire[index].hasPrefix("capture-pane ")
                if capture { failedCaptures += 1 }
                review610ReplyNext(controller, sent, answered: &index, success: !capture)
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTAssertGreaterThanOrEqual(failedCaptures, 2)
        XCTAssertEqual(index, sent.string.split(separator: "\n").count)
        XCTAssertNotEqual(controller.gridAuthorityLifecycleForTesting.claim?.generation, failedClaim,
                          "ordinary repaint exhaustion must end the original generation")
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.reason, .userTakeBack)
        XCTAssertEqual(controller.gridAuthoritySessionForTesting.replay.count, 1)
        XCTAssertEqual(stampWrites(sent), 0)
        XCTAssertTrue(controller.gridAuthority.isPeer)
    }

    func test_review610_finalInlineProbeConfirmsBeforeStallCheck() async throws {
        let (controller, sent) = makeController(
            path: .inline, remoteStamp: Self.peerValue
        )
        XCTAssertTrue(controller.reclaimGridAuthority())
        var index = 0
        for _ in 0..<20 {
            let wire = sent.string.split(separator: "\n").map(String.init)
            guard index < wire.count else { return XCTFail("missing settle probe") }
            if isSettleProbe(wire[index]) { break }
            review610ReplyNext(controller, sent, answered: &index)
        }
        controller.expireGridAuthorityReclaimPresentationForTesting()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
        // The layout is installed while the last own read is outstanding.
        // Its confirmation is deferred until the ledger has seen the step.
        ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.claim?.phase, .awaitingRepaint)
        let read = try XCTUnwrap(review610ReplyNext(
            controller, sent, answered: &index,
            body: ["tessera-window-size\t@0\t92\t38"]
        ))
        XCTAssertTrue(isSettleProbe(read))
        for _ in 0..<80 {
            if review610ReplyNext(controller, sent, answered: &index) == nil {
                if controller.gridAuthorityLifecycleForTesting.claim == nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthority, .mine, sent.string)
        XCTAssertEqual(stampWrites(sent), 1)
    }
    // MARK: Shared session adapter regressions

    func test_sleepCountsTowardR3BeforeTheWakeRead() {
        final class Millis { var now: Int64 = 0 }
        let clock = Millis()
        let (controller, sent) = makeController(
            remoteStamp: Self.peerValue, attach: false, authorityNow: { clock.now }
        )
        controller.gridAuthorityShown()
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        // Simulate ten minutes asleep: neither a wake timer nor an event ran.
        clock.now += 600_000
        controller.ingest(Array(Self.handshake.utf8))
        ackAllPending(controller, frames: 40)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        assertNoClaimGeometryOrStamp(sent.string, "the wake read cannot revive an expired show")
    }

    func test_parkedSideChannelFailureReplaysWhenTheSurfaceReturns() throws {
        for samePeer in [true, false] {
            let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
            var issue: UInt64?
            controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in issue = generation }
            XCTAssertTrue(controller.reclaimGridAuthority())
            let first = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation)
            ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
            ackAllPending(controller, frames: 60)
            let failedIssue = try XCTUnwrap(issue, "\(sent.string)")
            // The failed surface is unmounted before its failure is reported.
            controller.onGridAuthoritySideChannelRepaintRequired = nil
            sent.clear()
            controller.failGridAuthoritySideChannelRepaint(generation: failedIssue)
            XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
            XCTAssertNotNil(controller.gridAuthoritySessionForTesting.replay.parked)
            XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
            XCTAssertFalse(sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"))
            if !samePeer { deliverStamp(controller, value: "v1 DIFFERENT-PEER 9 Mac") }
            issue = nil
            controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in issue = generation }
            if samePeer {
                let replayed = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim)
                XCTAssertGreaterThan(replayed.generation, first)
                XCTAssertEqual(replayed.reason, .userTakeBack)
                XCTAssertEqual(controller.gridAuthoritySessionForTesting.replay.count, 1)
                ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
                ackAllPending(controller, frames: 60)
                completeSideChannelRepaintAndCommit(controller, generation: try XCTUnwrap(issue, "\(sent.string)"))
                XCTAssertEqual(controller.gridAuthority, .mine)
                XCTAssertEqual(count("set-option \(TmuxController.gridAuthorityOption)", in: sent.string), 1)
            } else {
                XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
                XCTAssertNil(controller.gridAuthoritySessionForTesting.replay.parked)
                XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "Mac"))
                assertNoClaimGeometryOrStamp(sent.string, "a parked tap cannot take back from a different peer")
            }
        }
    }

    func test_parkedSideChannelReplayStopsAfterEightFailures() throws {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        var issue: UInt64?
        controller.onGridAuthoritySideChannelRepaintRequired = { _, generation in issue = generation }
        XCTAssertTrue(controller.reclaimGridAuthority())
        for attempt in 1...9 {
            let current = try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation)
            issue = nil
            ingestLayout(controller, FixtureGrid(columns: 92, rows: 38))
            ackAllPending(controller, frames: 60)
            let failedIssue = try XCTUnwrap(issue, "\(sent.string)")
            sent.clear()
            controller.failGridAuthoritySideChannelRepaint(generation: failedIssue)
            if attempt <= 8 {
                XCTAssertGreaterThan(try XCTUnwrap(controller.gridAuthorityLifecycleForTesting.claim?.generation), current)
                XCTAssertEqual(controller.gridAuthoritySessionForTesting.replay.count, attempt)
            } else {
                XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
                XCTAssertNil(controller.gridAuthoritySessionForTesting.replay.parked)
                XCTAssertEqual(controller.gridAuthoritySessionForTesting.replay.count, 8)
                XCTAssertFalse(controller.gridAuthorityReclaimInFlight)
            }
            XCTAssertFalse(sent.string.contains("set-option \(TmuxController.gridAuthorityOption)"))
        }
    }

    func test_deferredStamplessJudgmentDoesNotRunWhileHidden() {
        for background in [false, true] {
            let (controller, sent) = makeOwnerController(path: .inline)
            controller.setGridAuthorityGeometryPolicyForTesting(latest: true)
            controller.updateClientSize(cols: 92, rows: 30)
            let foreign = "beef,120x40,0,0,0"
            controller.ingest(Array("%layout-change @0 \(foreign) \(foreign) *\r\n".utf8))
            XCTAssertTrue(controller.stamplessPeerRejudgePendingForTesting)
            if background { controller.gridAuthorityBackgrounded() }
            else { controller.gridAuthorityHidden() }
            sent.clear()
            controller.finishStamplessPeerEchoForTesting()
            XCTAssertEqual(controller.gridAuthority, .mine)
            XCTAssertEqual(controller.gridAuthorityPresentation, .none)
            XCTAssertFalse(controller.stamplessPeerRejudgePendingForTesting)
            assertNoClaimGeometryOrStamp(sent.string, "hidden/background ticks cannot judge or replay geometry")
        }
    }

    func test_identityChangeInvalidatesMineAndProjectsParticipation() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _) = makeOwnerController(path: path)
            let owned = controller.snapshot.authority
            let revision = controller.snapshot.revision
            controller.gridAuthorityIdentity = .init(id: Self.selfID, displayName: "Renamed")
            XCTAssertEqual(controller.snapshot.authority, owned)
            XCTAssertEqual(controller.snapshot.revision, revision)
            controller.gridAuthorityIdentity = .init(id: "NEW-DEVICE", displayName: "Phone")
            XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.authority, .unknown)
            XCTAssertEqual(controller.snapshot.authority, .unknown)
            deliverStamp(controller, value: Self.peerValue)
            XCTAssertTrue(controller.snapshot.authority.isPeer)
            let reduced = controller.gridAuthorityLifecycleForTesting.authority
            controller.gridAuthorityIdentity = nil
            XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.authority, reduced)
            XCTAssertEqual(controller.snapshot.authority, .unknown)
            controller.gridAuthorityIdentity = .init(id: "NEW-DEVICE", displayName: "Phone")
            XCTAssertEqual(controller.snapshot.authority, reduced)
        }
    }

    /// A claim belongs to the identity that began it. Running on, it would
    /// settle the old identity's `.mine` under the new id.
    func test_identityChangeDuringAClaimEndsItAndInvalidatesMine() throws {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.gridAuthorityHidden()
        controller.updateClientSize(cols: 80, rows: 30)
        controller.gridAuthorityShown()
        ackAllPending(controller, frames: 1)
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
        guard case .mine = controller.gridAuthorityLifecycleForTesting.authority else {
            return XCTFail("a show over our own stamp claims while still the owner")
        }
        sent.clear()
        controller.gridAuthorityIdentity = .init(id: "NEW-DEVICE", displayName: "Phone")
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthorityLifecycleForTesting.authority, .unknown)
        XCTAssertEqual(controller.snapshot.authority, .unknown)
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, sent.string)
    }

    func test_repeatedSubscriptionKeepsRuntimeRevisionAndSharedStateUnchanged() {
        let (controller, sent) = makeController(path: .inline, remoteStamp: Self.peerValue)
        deliverStamp(controller, value: Self.peerValue)
        let before = controller.gridAuthoritySessionForTesting
        let snapshot = controller.snapshot
        sent.clear()
        for _ in 0..<100 {
            deliverStamp(controller, value: "  \(Self.peerValue)  ")
        }
        XCTAssertEqual(controller.gridAuthoritySessionForTesting, before)
        XCTAssertEqual(controller.snapshot, snapshot)
        XCTAssertEqual(sent.string, "")
    }

    /// The runtime parsed the whole read before the session saw its stamp.
    /// Every later layout/output still needs the verdict reduced in wire order.
    func test_stampAndPeerLayoutsInOneReadKeepRenderWorkDeferred() async {
        for cooperative in [false, true] {
            let (controller, sent) = makeOwnerController(path: .inline)
            controller.ingest(Array("%window-pane-changed @0 %0\r\n".utf8))
            controller.submitRenderFact(.refreshRequested(.live, stage: .deep, reason: "test-owner-paint"))
            answerWire(controller, sent, authority: selfValue())
            sent.clear()
            let first = "beef,92x20,0,0,0"
            let second = "cafe,92x24,0,0,0"
            let bytes = Array((
                "%subscription-changed tessera-authority $0 @0 0 %0 : \(Self.peerValue)\r\n" +
                "%layout-change @0 \(first) \(first) *\r\n" +
                "%output %0 live\r\n" +
                "%layout-change @0 \(second) \(second) *\r\n"
            ).utf8)
            if cooperative {
                _ = await controller.ingestCooperatively(bytes)
            } else {
                controller.ingest(bytes)
            }
            XCTAssertEqual(controller.snapshot.authority, controller.gridAuthorityLifecycleForTesting.authority)
            XCTAssertTrue(controller.snapshot.authority.isPeer)
            XCTAssertFalse(sent.string.contains("capture-pane"), sent.string)
            XCTAssertFalse(sent.string.contains("#{cursor_x}"), sent.string)
        }
    }

    func test_outputDoesNotFeedTheAuthoritySession() {
        let (controller, _) = makeOwnerController(path: .inline)
        let before = controller.gridAuthoritySessionForTesting
        let revision = controller.snapshot.revision
        for _ in 0..<1_000 {
            controller.ingest(Array("%output %0 text\r\n".utf8))
        }
        XCTAssertEqual(controller.gridAuthoritySessionForTesting, before)
        XCTAssertEqual(controller.snapshot.revision, revision)
    }

    func test_sideChannelClaimWithNoWindowTargetForcesNoBackgroundWindow() {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        controller.ingest(Array("%window-add @1\r\n".utf8))
        let background = "beef,80x24,0,0,1"
        controller.ingest(Array("%layout-change @1 \(background) \(background) *\r\n".utf8))
        ackAllPending(controller, frames: 40)
        XCTAssertEqual(controller.windows.count, 2)
        controller.deferGridAuthorityWireTargetForTesting()
        sent.clear()
        XCTAssertTrue(controller.reclaimGridAuthority())
        XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertFalse(sent.string.contains("resize-window"), sent.string)
        XCTAssertFalse(sent.string.contains("set-option -w -u"), sent.string)
        XCTAssertFalse(sent.string.contains("select-window"), "its fence waits for a target: \(sent.string)")
    }

    func test_newShowAtRetryDeadlineSendsOnlyItsCurrentReadWithSynchronousReply() {
        let (controller, sent) = makeOwnerController(path: .inline)
        controller.rereadGridAuthorityForTesting()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1)
        controller.ingest(Array("%begin 0 970 1\r\nread failed\r\n%error 0 970 1\r\n".utf8))
        XCTAssertNotNil(controller.gridAuthoritySessionForTesting.query.retryAt)
        controller.advanceGridAuthorityClockForTesting(by: 250, tick: false)
        sent.clear()
        var response = 971
        let remote = fixture(controller)
        controller.sendBytes = { [weak controller] bytes in
            sent.append(bytes)
            remote.noteSent(bytes)
            let commands = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
            for command in commands {
                XCTAssertEqual(String(command), Self.authorityRead)
                let number = response
                response += 1
                controller?.ingest(Array("%begin 0 \(number) 1\r\n\(self.selfValue())\r\n%end 0 \(number) 1\r\n".utf8))
            }
        }
        controller.gridAuthorityShown()
        XCTAssertEqual(count(Self.authorityRead, in: sent.string), 1, "the obsolete due retry is skipped")
        XCTAssertNil(controller.gridAuthoritySessionForTesting.query.current)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertEqual(controller.gridAuthority, .mine)
        XCTAssertEqual(controller.gridAuthorityPresentation, .none)
        assertNoGeometryOrStamp(sent.string, "the synchronous newest read resolves R2 at our size")
    }

    func test_adoptingShownAfterRestoreNeverClaimsOverPeer() {
        let (controller, sent) = makeController(path: .sideChannel, remoteStamp: Self.peerValue)
        controller.gridAuthorityHidden()
        XCTAssertEqual(controller.gridAuthorityPresentation, .resuming(awaitingConnection: false))
        sent.clear()
        controller.gridAuthorityAdoptShown()
        XCTAssertEqual(controller.gridAuthorityPresentation, .veiled(peerName: "iPhone"))
        XCTAssertFalse(controller.gridAuthoritySessionForTesting.hidden)
        XCTAssertNil(controller.gridAuthorityPendingIntentSource)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertTrue(sent.string.isEmpty, "adopting an already-shown slot is no new gesture: \(sent.string)")
    }

    func test_connectPromptStopsPausingWhenChannelHealsButSessionPromptStillPauses() {
        for sessionPrompt in [false, true] {
            final class Millis { var now: Int64 = 0 }
            let clock = Millis()
            let (controller, _) = makeController(attach: false, authorityNow: { clock.now })
            controller.gridAuthorityShown()
            controller.setGridAuthorityPromptState(session: sessionPrompt, connect: true)
            XCTAssertTrue(controller.gridAuthoritySessionForTesting.intentClock.paused)
            clock.now = 100_000
            controller.ingest(Array(Self.handshake.utf8))
            XCTAssertTrue(controller.gridAuthorityChannelIsLive)
            XCTAssertNotNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
            XCTAssertEqual(controller.gridAuthoritySessionForTesting.intentClock.paused, sessionPrompt)
            if sessionPrompt {
                XCTAssertNil(controller.gridAuthoritySessionForTesting.intentClock.deadline)
            } else {
                XCTAssertEqual(controller.gridAuthoritySessionForTesting.intentClock.deadline, 120_000)
            }
            controller.setGridAuthorityPromptState(session: false, connect: true)
            XCTAssertFalse(controller.gridAuthoritySessionForTesting.intentClock.paused)
            XCTAssertEqual(controller.gridAuthoritySessionForTesting.intentClock.deadline, 120_000)
        }
    }

    func test_appLifecycleBeforeIdentityStillReportsTheCurrentBackgroundState() {
        let controller = TmuxController(authorityInitialGeneration: 0, controlPath: .sideChannel)
        controller.gridAuthorityBackgrounded()
        XCTAssertTrue(controller.gridAuthoritySessionForTesting.inBackground)
        controller.gridAuthorityForegrounded()
        XCTAssertFalse(controller.gridAuthoritySessionForTesting.inBackground)
        controller.gridAuthorityIdentity = .init(id: "LATE-SELF", displayName: "iPad")
        XCTAssertFalse(controller.gridAuthoritySessionForTesting.inBackground)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.claim)
        XCTAssertNil(controller.gridAuthorityLifecycleForTesting.pendingIntent)
    }

}
