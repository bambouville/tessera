import XCTest
@testable import TmuxControl

@MainActor
final class ReverseAttachCedeTests: XCTestCase {
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

    private func makeController(
        path: TmuxController.ControlPath = .inline,
        policy: TmuxController.ClientSizePolicy = .preserveServerGeometry,
        localCols: Int = 50,
        localRows: Int = 30
    ) -> (controller: TmuxController, sent: ByteSink) {
        let sent = ByteSink()
        let controller = TmuxController(
            controlPath: path,
            clientSizePolicy: policy
        )
        controller.feedTerminal = { _ in }
        controller.sendBytes = { sent.append($0) }
        if path == .sideChannel {
            controller.onServerGeometryCeded = { _, _ in }
        }
        controller.updateClientSize(cols: localCols, rows: localRows)

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%session-changed $0 phone-born\r\n%window-renamed @0 shell\r\n".utf8))
        sent.clear()
        return (controller, sent)
    }

    private func announcePeer(
        _ controller: TmuxController,
        client: String = "/dev/ttys-peer",
        session: Int = 0
    ) {
        controller.ingest(Array(
            "%client-session-changed \(client) $\(session) phone-born\r\n".utf8
        ))
    }

    private func publishLayout(
        _ controller: TmuxController,
        cols: Int,
        rows: Int
    ) {
        let layout = "beef,\(cols)x\(rows),0,0,0"
        controller.ingest(Array(
            "%layout-change @0 \(layout) \(layout) *\r\n".utf8
        ))
    }

    private func acknowledgeCommand(_ controller: TmuxController, number: Int) {
        controller.ingest(Array(
            "%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8
        ))
    }

    private func respondPeerSize(
        _ controller: TmuxController,
        number: Int,
        cols: Int,
        rows: Int
    ) {
        controller.ingest(Array(
            "%begin 0 \(number) 1\r\n\(cols),\(rows)\r\n%end 0 \(number) 1\r\n".utf8
        ))
    }

    private func failCommand(_ controller: TmuxController, number: Int) {
        controller.ingest(Array(
            "%begin 0 \(number) 1\r\ncommand failed\r\n%error 0 \(number) 1\r\n".utf8
        ))
    }

    func test_reverseAttachCede_largerSameSessionPeerFlipsPhoneAndRetainsPeerGrid() {
        let (controller, sent) = makeController()
        var promotedGeometry: (cols: Int, rows: Int)?
        var promotionCount = 0
        controller.onServerGeometryCeded = { cols, rows in
            promotedGeometry = (cols, rows)
            promotionCount += 1
        }

        announcePeer(controller)
        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")

        publishLayout(controller, cols: 120, rows: 40)

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(
            sent.string,
            "display-message -p -c '/dev/ttys-peer' '#{client_width},#{client_height}'\n"
        )
        sent.clear()
        respondPeerSize(controller, number: 2, cols: 120, rows: 40)
        XCTAssertEqual(
            sent.string,
            "refresh-client -C 120,40\n",
            "the owner must not be ignored before tmux acknowledges the grid hold"
        )
        publishLayout(controller, cols: 130, rows: 44)
        XCTAssertEqual(
            sent.string,
            "refresh-client -C 120,40\n",
            "an in-flight cede must not enqueue duplicate mutations"
        )

        sent.clear()
        acknowledgeCommand(controller, number: 3)
        XCTAssertTrue(controller.hasCededGridOwnership)
        XCTAssertEqual(promotedGeometry?.cols, 120)
        XCTAssertEqual(promotedGeometry?.rows, 40)
        XCTAssertEqual(promotionCount, 1)
        XCTAssertEqual(sent.string, "refresh-client -f ignore-size\n")

        sent.clear()
        acknowledgeCommand(controller, number: 4)
        XCTAssertTrue(controller.hasCededGridOwnership)
        XCTAssertEqual(promotedGeometry?.cols, 120)
        XCTAssertEqual(promotedGeometry?.rows, 40)
        XCTAssertEqual(promotionCount, 1)
        XCTAssertEqual(sent.string, "")
        XCTAssertFalse(sent.string.contains("window-size"))
        XCTAssertFalse(sent.string.contains("aggressive-resize"))
        XCTAssertFalse(sent.string.contains("resize-window"))

        sent.clear()
        controller.ingest(Array("%client-detached /dev/ttys-peer\r\n".utf8))
        publishLayout(controller, cols: 120, rows: 40)

        XCTAssertTrue(controller.hasCededGridOwnership)
        XCTAssertEqual(promotedGeometry?.cols, 120)
        XCTAssertEqual(promotedGeometry?.rows, 40)
        XCTAssertEqual(promotionCount, 1)
        XCTAssertEqual(
            sent.string,
            "",
            "peer detach must not clear the cede latch or replay the smaller phone viewport"
        )
    }

    func test_reverseAttachCede_waitsUntilPeerGridIsLarger() {
        let (controller, sent) = makeController(localCols: 60, localRows: 32)
        announcePeer(controller)

        publishLayout(controller, cols: 60, rows: 32)
        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))
        sent.clear()
        respondPeerSize(controller, number: 2, cols: 60, rows: 32)
        XCTAssertEqual(sent.string, "")

        publishLayout(controller, cols: 100, rows: 32)
        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))
        sent.clear()
        respondPeerSize(controller, number: 3, cols: 100, rows: 32)
        XCTAssertEqual(
            sent.string,
            "refresh-client -C 100,32\n"
        )
        sent.clear()
        acknowledgeCommand(controller, number: 4)
        XCTAssertEqual(sent.string, "refresh-client -f ignore-size\n")
        XCTAssertTrue(controller.hasCededGridOwnership)
        acknowledgeCommand(controller, number: 5)
        XCTAssertTrue(controller.hasCededGridOwnership)
    }

    func test_reverseAttachCede_foreignOrDetachedPeerCannotTriggerCede() {
        let (foreignController, foreignSent) = makeController()

        announcePeer(foreignController, session: 9)
        publishLayout(foreignController, cols: 120, rows: 40)
        XCTAssertFalse(foreignController.hasCededGridOwnership)
        XCTAssertEqual(foreignSent.string, "")

        let (detachedController, detachedSent) = makeController()
        announcePeer(detachedController)
        detachedController.ingest(Array("%client-detached /dev/ttys-peer\r\n".utf8))
        publishLayout(detachedController, cols: 130, rows: 44)
        XCTAssertFalse(detachedController.hasCededGridOwnership)
        XCTAssertEqual(detachedSent.string, "")
    }

    func test_reverseAttachCede_iPadSizingBehaviorRemainsAuthoritative() {
        let (controller, sent) = makeController(policy: .resizeTmux)

        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")

        controller.updateClientSize(cols: 130, rows: 44)
        XCTAssertEqual(sent.string, "refresh-client -C 130,44\n")
        XCTAssertFalse(sent.string.contains("ignore-size"))
    }

    func test_reverseAttachCede_existingLargerGridWithoutPeerIsInert() {
        let (controller, sent) = makeController()

        publishLayout(controller, cols: 120, rows: 40)

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(
            sent.string,
            "",
            "an existing-session phone is already attached with ignore-size; hydration must not invent a cede transition"
        )
    }

    func test_reverseAttachCede_sideChannelTargetsTaggedVisibleMoshOwner() {
        let (controller, sent) = makeController(path: .sideChannel)
        announcePeer(controller)
        publishLayout(controller, cols: 100, rows: 40)
        publishLayout(controller, cols: 110, rows: 35)

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(
            sent.string,
            "display-message -p -c '/dev/ttys-peer' '#{client_width},#{client_height}'\n"
        )

        sent.clear()
        respondPeerSize(controller, number: 2, cols: 110, rows: 35)
        XCTAssertEqual(
            sent.string,
            "show-options -qv -t $0 \(TmuxController.reverseAttachGeometryOwnerOption)\n"
        )
        sent.clear()
        controller.ingest(Array(
            "%begin 0 3 1\r\n/dev/ttys-mosh-phone\r\n%end 0 3 1\r\n".utf8
        ))

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(
            sent.string,
            "refresh-client -C 110,35\n",
            "the side channel must establish its authoritative hold before mutating the visible owner"
        )

        sent.clear()
        acknowledgeCommand(controller, number: 4)
        XCTAssertTrue(controller.hasCededGridOwnership)
        XCTAssertEqual(
            sent.string,
            "refresh-client -t '/dev/ttys-mosh-phone' -f ignore-size\n"
        )
        sent.clear()
        acknowledgeCommand(controller, number: 5)
        XCTAssertTrue(controller.hasCededGridOwnership)
    }

    func test_reverseAttachCede_sideChannelMissingOwnerDoesNotClaimCede() {
        let (controller, sent) = makeController(path: .sideChannel)
        announcePeer(controller)
        publishLayout(controller, cols: 100, rows: 40)
        sent.clear()

        respondPeerSize(controller, number: 2, cols: 100, rows: 40)
        sent.clear()

        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")
    }

    func test_reverseAttachCede_sideChannelWithoutPromotionHandlerDoesNotMutateOwner() {
        let (controller, sent) = makeController(path: .sideChannel)
        controller.onServerGeometryCeded = nil
        announcePeer(controller)
        publishLayout(controller, cols: 100, rows: 40)
        sent.clear()

        respondPeerSize(controller, number: 2, cols: 100, rows: 40)
        sent.clear()

        controller.ingest(Array(
            "%begin 0 3 1\r\n/dev/ttys-mosh-phone\r\n%end 0 3 1\r\n".utf8
        ))

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(
            sent.string,
            "",
            "without a session promotion boundary the side channel must not cache or ignore either client"
        )
    }

    func test_reverseAttachCede_sideChannelLookupDoesNotCedeAfterGridShrinksBack() {
        let (controller, sent) = makeController(path: .sideChannel)
        announcePeer(controller)
        publishLayout(controller, cols: 100, rows: 40)
        publishLayout(controller, cols: 50, rows: 30)
        sent.clear()

        respondPeerSize(controller, number: 2, cols: 100, rows: 40)

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")
    }

    func test_reverseAttachCede_resetClearsConnectionScopedState() {
        let (controller, sent) = makeController()
        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)
        sent.clear()
        respondPeerSize(controller, number: 2, cols: 120, rows: 40)
        sent.clear()
        acknowledgeCommand(controller, number: 3)
        acknowledgeCommand(controller, number: 4)
        XCTAssertTrue(controller.hasCededGridOwnership)

        controller.reset()

        XCTAssertFalse(controller.hasCededGridOwnership)
    }

    func test_reverseAttachCede_doesNotLatchWhenGridCacheFailsAndCanRetry() {
        let (controller, sent) = makeController()
        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))
        sent.clear()
        respondPeerSize(controller, number: 2, cols: 120, rows: 40)
        XCTAssertEqual(sent.string, "refresh-client -C 120,40\n")

        sent.clear()
        failCommand(controller, number: 3)
        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")

        publishLayout(controller, cols: 120, rows: 40)
        XCTAssertEqual(sent.string, "refresh-client -C 120,40\n")
    }

    func test_reverseAttachCede_ownerIgnoreErrorKeepsAcknowledgedGridLatched() {
        let (controller, sent) = makeController()
        var promotedGeometry: (cols: Int, rows: Int)?
        var promotionCount = 0
        controller.onServerGeometryCeded = { cols, rows in
            promotedGeometry = (cols, rows)
            promotionCount += 1
        }
        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)

        sent.clear()
        respondPeerSize(controller, number: 2, cols: 120, rows: 40)
        sent.clear()
        acknowledgeCommand(controller, number: 3)
        XCTAssertEqual(sent.string, "refresh-client -f ignore-size\n")
        XCTAssertTrue(controller.hasCededGridOwnership)
        XCTAssertEqual(promotedGeometry?.cols, 120)
        XCTAssertEqual(promotedGeometry?.rows, 40)
        XCTAssertEqual(promotionCount, 1)

        sent.clear()
        failCommand(controller, number: 4)
        XCTAssertTrue(controller.hasCededGridOwnership)
        XCTAssertEqual(promotedGeometry?.cols, 120)
        XCTAssertEqual(promotedGeometry?.rows, 40)
        XCTAssertEqual(promotionCount, 1)
        XCTAssertEqual(sent.string, "")

        publishLayout(controller, cols: 130, rows: 44)
        XCTAssertEqual(
            sent.string,
            "",
            "a held grid must not retry owner exclusion or promote a divergent size after an unacknowledged ignore"
        )
    }

    func test_reverseAttachCede_sideChannelDisconnectDuringOwnerIgnoreKeepsSessionHold() {
        let (controller, sent) = makeController(path: .sideChannel)
        var promotedGeometry: (cols: Int, rows: Int)?
        var promotionCount = 0
        controller.onServerGeometryCeded = { cols, rows in
            promotedGeometry = (cols, rows)
            promotionCount += 1
        }
        announcePeer(controller)
        publishLayout(controller, cols: 132, rows: 44)
        sent.clear()
        respondPeerSize(controller, number: 2, cols: 132, rows: 44)
        sent.clear()
        controller.ingest(Array(
            "%begin 0 3 1\r\n/dev/ttys-mosh-phone\r\n%end 0 3 1\r\n".utf8
        ))
        XCTAssertEqual(sent.string, "refresh-client -C 132,44\n")

        sent.clear()
        acknowledgeCommand(controller, number: 4)
        XCTAssertEqual(
            sent.string,
            "refresh-client -t '/dev/ttys-mosh-phone' -f ignore-size\n"
        )
        XCTAssertTrue(controller.hasCededGridOwnership)
        XCTAssertEqual(promotedGeometry?.cols, 132)
        XCTAssertEqual(promotedGeometry?.rows, 44)
        XCTAssertEqual(promotionCount, 1)

        let generation = controller.controlConnectionGeneration
        controller.sideChannelDisconnected()

        XCTAssertNotEqual(controller.controlConnectionGeneration, generation)
        XCTAssertTrue(
            controller.hasCededGridOwnership,
            "the logical-session latch must survive loss of the ignore command acknowledgement"
        )
        XCTAssertEqual(promotedGeometry?.cols, 132)
        XCTAssertEqual(promotedGeometry?.rows, 44)
        XCTAssertEqual(promotionCount, 1)
    }

    func test_reverseAttachCede_phoneRotationCannotMasqueradeAsPeerGrid() {
        let (controller, sent) = makeController(localCols: 50, localRows: 30)
        announcePeer(controller)
        controller.updateClientSize(cols: 30, rows: 50)
        publishLayout(controller, cols: 50, rows: 30)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))

        sent.clear()
        respondPeerSize(controller, number: 2, cols: 120, rows: 40)
        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")

        publishLayout(controller, cols: 120, rows: 40)
        XCTAssertEqual(sent.string, "refresh-client -C 120,40\n")
    }

    func test_reverseAttachCede_inheritedOwnerGridCannotMasqueradeAsPeerExpansion() {
        let (controller, sent) = makeController(localCols: 50, localRows: 30)
        publishLayout(controller, cols: 50, rows: 30)
        controller.updateClientSize(cols: 25, rows: 30)
        announcePeer(controller)
        publishLayout(controller, cols: 50, rows: 30)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))

        sent.clear()
        respondPeerSize(controller, number: 2, cols: 50, rows: 30)

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(
            sent.string,
            "",
            "a new peer's inherited owner grid is not proof that it expanded the session"
        )

        publishLayout(controller, cols: 120, rows: 40)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))
        sent.clear()
        respondPeerSize(controller, number: 3, cols: 120, rows: 40)
        XCTAssertEqual(sent.string, "refresh-client -C 120,40\n")
    }

    func test_reverseAttachCede_firstLocalSizeAfterPeerEvidenceEnablesCede() {
        let (controller, sent) = makeController(localCols: 0, localRows: 0)
        publishLayout(controller, cols: 50, rows: 30)
        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))

        sent.clear()
        respondPeerSize(controller, number: 2, cols: 120, rows: 40)
        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")

        controller.updateClientSize(cols: 50, rows: 30)
        XCTAssertEqual(sent.string, "refresh-client -C 120,40\n")
    }

    func test_reverseAttachCede_layoutBeforePeerAnnouncementUsesQueriedPeerEvidence() {
        let (controller, sent) = makeController()
        publishLayout(controller, cols: 50, rows: 30)
        publishLayout(controller, cols: 120, rows: 40)
        XCTAssertEqual(sent.string, "display-message -p '#{client_name}'\n")

        sent.clear()
        controller.ingest(Array(
            "%begin 0 2 1\r\n/dev/ttys-phone\r\n%end 0 2 1\r\n".utf8
        ))
        XCTAssertEqual(
            sent.string,
            "list-clients -t $0 -F '#{client_name}\t#{client_width},#{client_height}'\n"
        )

        sent.clear()
        controller.ingest(Array(
            ("%begin 0 3 1\r\n"
                + "/dev/ttys-phone\t50,30\r\n"
                + "/dev/ttys-peer\t120,40\r\n"
                + "%end 0 3 1\r\n").utf8
        ))
        XCTAssertEqual(sent.string, "refresh-client -C 120,40\n")
    }

    func test_reverseAttachCede_hydratedOwnerGridSurvivesPeerLayoutBeforeAnnouncement() {
        let sent = ByteSink()
        let controller = TmuxController(
            controlPath: .inline,
            clientSizePolicy: .preserveServerGeometry
        )
        controller.feedTerminal = { _ in }
        controller.sendBytes = { sent.append($0) }
        controller.updateClientSize(cols: 50, rows: 30)

        var handshake: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        handshake.append(contentsOf: "%begin 0 1 0\r\n%end 0 1 0\r\n".utf8)
        controller.ingest(handshake)
        controller.ingest(Array("%session-changed $0 phone-born\r\n".utf8))
        for number in 2...4 {
            acknowledgeCommand(controller, number: number)
        }
        let compactLayout = "beef,50x30,0,0,0"
        controller.ingest(Array(
            ("%begin 0 5 1\r\n"
                + "@0\t\(compactLayout)\t\(compactLayout)\t0\tshell\r\n"
                + "%end 0 5 1\r\n").utf8
        ))
        for number in 6...8 {
            acknowledgeCommand(controller, number: number)
        }
        sent.clear()

        // This is the live ordering: the larger layout is broadcast before
        // any peer announcement. Hydration must remain the owner baseline and
        // list-clients must attribute the expanded grid to the new client.
        publishLayout(controller, cols: 132, rows: 44)
        XCTAssertEqual(
            sent.string,
            "display-message -p '#{client_name}'\n"
        )

        sent.clear()
        controller.ingest(Array(
            "%begin 0 9 1\r\n/dev/ttys-phone\r\n%end 0 9 1\r\n".utf8
        ))
        sent.clear()
        controller.ingest(Array(
            ("%begin 0 10 1\r\n"
                + "/dev/ttys-phone\t50,30\r\n"
                + "/dev/ttys-peer\t132,44\r\n"
                + "%end 0 10 1\r\n").utf8
        ))
        XCTAssertEqual(sent.string, "refresh-client -C 132,44\n")
    }

    func test_reverseAttachCede_fallsBackWhenTargetedClientSizeIsUnavailable() {
        let (controller, sent) = makeController()
        publishLayout(controller, cols: 50, rows: 30)
        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))

        sent.clear()
        controller.ingest(Array(
            "%begin 0 2 1\r\n,\r\n%end 0 2 1\r\n".utf8
        ))
        XCTAssertEqual(sent.string, "display-message -p '#{client_name}'\n")

        sent.clear()
        controller.ingest(Array(
            "%begin 0 3 1\r\n/dev/ttys-phone\r\n%end 0 3 1\r\n".utf8
        ))
        sent.clear()
        controller.ingest(Array(
            ("%begin 0 4 1\r\n"
                + "/dev/ttys-phone\t50,30\r\n"
                + "/dev/ttys-peer\t120,40\r\n"
                + "%end 0 4 1\r\n").utf8
        ))
        XCTAssertEqual(sent.string, "refresh-client -C 120,40\n")
    }

    func test_reverseAttachCede_tmux34ControlClientWidthAttributesLargerGrid() {
        let (controller, sent) = makeController()
        publishLayout(controller, cols: 50, rows: 30)
        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)
        XCTAssertTrue(sent.string.contains("display-message -p -c"))

        sent.clear()
        controller.ingest(Array(
            "%begin 0 2 1\r\n120,\r\n%end 0 2 1\r\n".utf8
        ))

        XCTAssertEqual(
            sent.string,
            "refresh-client -C 120,40\n",
            "tmux 3.4 omits client_height for control clients but reports their authoritative width"
        )
    }

    func test_reverseAttachCede_widthOnlyPeerStillMustMatchServerWidth() {
        let (controller, sent) = makeController()
        publishLayout(controller, cols: 50, rows: 30)
        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)
        sent.clear()

        controller.ingest(Array(
            "%begin 0 2 1\r\n119,\r\n%end 0 2 1\r\n".utf8
        ))

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "display-message -p '#{client_name}'\n")

        sent.clear()
        controller.ingest(Array(
            "%begin 0 3 1\r\n/dev/ttys-phone\r\n%end 0 3 1\r\n".utf8
        ))
        sent.clear()
        controller.ingest(Array(
            ("%begin 0 4 1\r\n"
                + "/dev/ttys-phone\t50,30\r\n"
                + "/dev/ttys-peer\t119,\r\n"
                + "%end 0 4 1\r\n").utf8
        ))

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")
    }

    func test_reverseAttachCede_discoversUnannouncedPeerAfterKnownPeerDoesNotMatch() {
        let (controller, sent) = makeController()
        publishLayout(controller, cols: 50, rows: 30)
        announcePeer(controller, client: "/dev/ttys-known")
        publishLayout(controller, cols: 140, rows: 50)
        sent.clear()

        respondPeerSize(controller, number: 2, cols: 80, rows: 30)
        XCTAssertEqual(sent.string, "display-message -p '#{client_name}'\n")

        sent.clear()
        controller.ingest(Array(
            "%begin 0 3 1\r\n/dev/ttys-phone\r\n%end 0 3 1\r\n".utf8
        ))
        XCTAssertEqual(
            sent.string,
            "list-clients -t $0 -F '#{client_name}\t#{client_width},#{client_height}'\n"
        )

        sent.clear()
        controller.ingest(Array(
            ("%begin 0 4 1\r\n"
                + "/dev/ttys-phone\t50,30\r\n"
                + "/dev/ttys-known\t80,30\r\n"
                + "/dev/ttys-unannounced\t140,50\r\n"
                + "%end 0 4 1\r\n").utf8
        ))
        XCTAssertEqual(sent.string, "refresh-client -C 140,50\n")
    }

    func test_reverseAttachCede_sideChannelRejectsDetachedPeersPendingGrid() {
        let (controller, sent) = makeController(path: .sideChannel)
        announcePeer(controller, client: "/dev/ttys-large")
        publishLayout(controller, cols: 120, rows: 40)
        sent.clear()

        respondPeerSize(controller, number: 2, cols: 120, rows: 40)
        XCTAssertEqual(
            sent.string,
            "show-options -qv -t $0 \(TmuxController.reverseAttachGeometryOwnerOption)\n"
        )

        sent.clear()
        announcePeer(controller, client: "/dev/ttys-compact")
        controller.ingest(Array("%client-detached /dev/ttys-large\r\n".utf8))
        sent.clear()
        controller.ingest(Array(
            "%begin 0 3 1\r\n/dev/ttys-mosh-phone\r\n%end 0 3 1\r\n".utf8
        ))

        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertFalse(sent.string.contains("refresh-client -C 120,40"))
    }

    func test_reverseAttachCede_sideChannelRejectsSupersededPendingGrid() {
        let (controller, sent) = makeController(path: .sideChannel)
        announcePeer(controller)
        publishLayout(controller, cols: 120, rows: 40)
        sent.clear()

        respondPeerSize(controller, number: 2, cols: 120, rows: 40)
        XCTAssertEqual(
            sent.string,
            "show-options -qv -t $0 \(TmuxController.reverseAttachGeometryOwnerOption)\n"
        )

        sent.clear()
        publishLayout(controller, cols: 130, rows: 40)
        XCTAssertEqual(
            sent.string,
            "display-message -p -c '/dev/ttys-peer' '#{client_width},#{client_height}'\n"
        )

        sent.clear()
        controller.ingest(Array(
            "%begin 0 3 1\r\n/dev/ttys-mosh-phone\r\n%end 0 3 1\r\n".utf8
        ))
        XCTAssertFalse(controller.hasCededGridOwnership)
        XCTAssertEqual(sent.string, "")

        respondPeerSize(controller, number: 4, cols: 130, rows: 40)
        XCTAssertEqual(
            sent.string,
            "show-options -qv -t $0 \(TmuxController.reverseAttachGeometryOwnerOption)\n",
            "fresh peer evidence must restart lookup for the current grid"
        )
    }
}
