import Foundation
import XCTest
@testable import TmuxControlCore

final class TmuxControlCoreTests: XCTestCase {
    func testStrictObjectIDsAndSafeTargets() throws {
        XCTAssertEqual(SessionId(wireValue: "$42"), SessionId(42))
        XCTAssertEqual(WindowId(wireValue: "@0"), WindowId(0))
        XCTAssertEqual(PaneId(wireValue: "%9"), PaneId(9))
        XCTAssertNil(SessionId(wireValue: "$-1"))
        XCTAssertNil(WindowId(wireValue: "@1junk"))
        XCTAssertNil(PaneId(wireValue: "%"))

        let name = try TmuxSessionName(validating: "prod.us-east_1")
        XCTAssertEqual(TmuxFixedQuery.hasSession(.sessionName(name)), "has-session -t prod.us-east_1")
        XCTAssertEqual(
            TmuxFixedQuery.displaySessionAttachment(name),
            "display-message -p -t =prod.us-east_1 '#{session_id}\\t#{session_name}\\t#{session_attached}'"
        )
        XCTAssertThrowsError(try TmuxSessionName(validating: "prod; kill-server"))
        XCTAssertThrowsError(try TmuxSessionName(validating: String(repeating: "a", count: 257)))
    }

    func testPortableGeometryValidationAndCapabilities() throws {
        let geometry = try TmuxClientGeometry(columns: 120, rows: 40)
        XCTAssertEqual(geometry.columns, 120)
        XCTAssertEqual(geometry.rows, 40)
        XCTAssertThrowsError(try TmuxClientGeometry(columns: 0, rows: 40))
        XCTAssertThrowsError(
            try TmuxClientGeometry(
                columns: TmuxClientGeometry.maximumDimension + 1,
                rows: 40
            )
        )
        XCTAssertTrue(
            TmuxGeometryCapability.canPublishLocalGeometry(
                policy: .resizeTmux,
                ownsPreservedGeometry: false
            )
        )
        XCTAssertFalse(
            TmuxGeometryCapability.canPublishLocalGeometry(
                policy: .preserveServerGeometry,
                ownsPreservedGeometry: false
            )
        )
        XCTAssertTrue(
            TmuxGeometryCapability.canPublishLocalGeometry(
                policy: .preserveServerGeometry,
                ownsPreservedGeometry: true
            )
        )
    }

    func testCommandCorrelationUsesOpeningGuardForClassification() {
        var correlator = TmuxCommandResponseCorrelator()
        _ = correlator.consume(.begin(time: 10, commandNumber: 4, flags: 1))
        _ = correlator.consume(.commandOutputLine("payload"))
        let event = correlator.consume(.end(time: 11, commandNumber: 99, flags: 0))
        guard case .frameCompleted(let frame) = event else {
            return XCTFail("expected a completed frame")
        }
        XCTAssertTrue(frame.isClientResponse)
        XCTAssertFalse(frame.guardMatches)
        XCTAssertEqual(frame.lines, ["payload"])
        XCTAssertEqual(frame.effectiveFlags, 1)
    }

    func testControlModeDetectionPreservesImmediateEchoAndSplitPrologue() {
        var detector = TmuxControlModeDetector()
        let ordinary = detector.feed(Array("prompt> ".utf8))
        XCTAssertEqual(ordinary.passthroughBytes, Array("prompt> ".utf8))
        XCTAssertFalse(ordinary.enteredControlMode)

        let prefix = detector.feed([0x1B, 0x50, 0x31])
        XCTAssertTrue(prefix.passthroughBytes.isEmpty)
        let suffix = detector.feed([0x30, 0x30, 0x30, 0x70] + Array("%window-add @1\n".utf8))
        XCTAssertTrue(suffix.enteredControlMode)
        XCTAssertEqual(suffix.controlBytes, Array("%window-add @1\n".utf8))
    }

    func testMalformedOpeningFlagsRequireMatchingValidClosingGuard() {
        for (openingFlags, closingTime, closingNumber, closingFlags, expectedClient) in [
            (-1, 10, 4, 1, true),
            (-1, 11, 4, 1, false),
            (-1, 10, 5, 1, false),
            (-1, 10, 4, -1, false),
            (-1, 10, 4, 0, false),
            (0, 10, 4, 1, false),
            (1, 10, 4, -1, true),
        ] {
            var correlator = TmuxCommandResponseCorrelator()
            _ = correlator.consume(.begin(time: 10, commandNumber: 4, flags: openingFlags))
            _ = correlator.consume(.commandOutputLine("body"))
            guard case .frameCompleted(let frame) = correlator.consume(
                .end(time: closingTime, commandNumber: closingNumber, flags: closingFlags)
            ) else { return XCTFail("Expected completed frame") }
            XCTAssertEqual(frame.isClientResponse, expectedClient)
            XCTAssertEqual(frame.lines, ["body"])
        }
        for (time, number) in [(-1, 4), (10, -1), (-1, -1)] {
            var correlator = TmuxCommandResponseCorrelator()
            _ = correlator.consume(.begin(time: time, commandNumber: number, flags: -1))
            guard case .frameCompleted(let frame) = correlator.consume(
                .end(time: time, commandNumber: number, flags: 1)
            ) else { return XCTFail("Expected completed frame") }
            XCTAssertFalse(frame.isClientResponse, "Matching invalid identity is not proof")
        }
        var correlator = TmuxCommandResponseCorrelator()
        _ = correlator.consume(.begin(time: 10, commandNumber: 4, flags: -1))
        guard case .frameCompleted(let failure) = correlator.consume(
            .error(time: 10, commandNumber: 4, flags: 1)
        ) else { return XCTFail("Expected error frame") }
        XCTAssertTrue(failure.isClientResponse)
        XCTAssertEqual(failure.status, .error)
    }

    func testAuthorityStampRoundTripsAndSanitizes() {
        let identity = TmuxGridAuthorityIdentity(id: "device one", displayName: "My iPad")
        let stamp = TmuxGridAuthorityStamp(identity: identity, generation: 7)
        XCTAssertEqual(stamp.wireValue, "v1 device-one 7 My-iPad")
        XCTAssertEqual(TmuxGridAuthorityStamp.parse(stamp.wireValue), stamp)
        XCTAssertEqual(
            TmuxGridAuthoritySnapshot.classify(rawValue: stamp.wireValue, localDeviceID: "other"),
            .peer(deviceID: "device-one", displayName: "My-iPad", generation: 7)
        )
    }

    func testCheckedInTraceReplaysToCheckedInImmutableSnapshot() throws {
        let vectors = try vectorsDirectory()
        let trace = try Data(contentsOf: vectors.appendingPathComponent("basic-topology.trace"))
        let expectedData = try Data(contentsOf: vectors.appendingPathComponent("basic-topology.snapshot.json"))
        let expected = try JSONDecoder().decode(TmuxSnapshot.self, from: expectedData)

        var replayer = TmuxTraceReplayer(localDeviceID: "phone")
        let midpoint = trace.count / 2
        _ = replayer.feed(trace[..<midpoint])
        let actual = replayer.feed(trace[midpoint...])
        XCTAssertEqual(actual, expected)
    }

    func testCheckedInRenderedStateAssemblesExactRepaintBytes() throws {
        let data = try Data(
            contentsOf: try vectorsDirectory().appendingPathComponent("repaint-v1.json")
        )
        let vector = try JSONDecoder().decode(RepaintVector.self, from: data)
        let state = try XCTUnwrap(TmuxRenderedPaneStateParser.parse(vector.renderedStateLine))
        let expected = try XCTUnwrap(Data(base64Encoded: vector.expectedBase64))

        let actual = TmuxRepaintAssembly.assemble(
            state: state,
            captureLines: vector.captureLines,
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: vector.terminalIsInAltScreen,
            clientRows: vector.clientRows
        )

        XCTAssertEqual(Data(actual), expected)
    }

    func testPortableTargetHasNoForbiddenImports() throws {
        var package = URL(fileURLWithPath: #filePath)
        package.deleteLastPathComponent()
        package.deleteLastPathComponent()
        package.deleteLastPathComponent()
        let sources = package.appendingPathComponent("Sources/TmuxControlCore")
        let files = try FileManager.default.contentsOfDirectory(
            at: sources,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let forbidden = [
            "import SwiftUI", "import UIKit", "import AppKit", "import SwiftData",
            "import StoreKit", "import Security", "import LocalAuthentication",
            "import Network", "import UserNotifications", "import GameController",
            "import Observation", "@Observable", "ObservableObject", "AsyncStream"
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
        }
    }

    func testParserEmitsPasteBufferNotifications() {
        var parser = TmuxControlParser()
        let messages = parser.feed(
            Array("%paste-buffer-changed buffer0\n%paste-buffer-deleted buffer0\n".utf8)
        )
        XCTAssertEqual(
            messages,
            [.pasteBufferChanged(name: "buffer0"), .pasteBufferDeleted(name: "buffer0")]
        )
    }

    func testParserBoundsOversizedPartialLineAndRecoversAtNextNewline() {
        var parser = TmuxControlParser()
        let oversized = Array(repeating: UInt8(ascii: "x"), count: TmuxControlParser.maximumBufferedLineBytes + 1)
        XCTAssertTrue(parser.feed(oversized).isEmpty)
        let recovered = parser.feed(Array("discarded\n%window-add @7\n".utf8))
        XCTAssertEqual(recovered, [.windowAdd(windowId: WindowId(7))])
    }

    func testRuntimeEngineOwnsRoutingTopologyAndCorrelation() throws {
        var engine = TmuxRuntimeEngine()
        let batch = engine.feed(Array((
            "%session-changed $1 work\n" +
            "%window-add @2\n" +
            "%session-window-changed $1 @2\n" +
            "%window-pane-changed @2 %9\n" +
            "%begin 1 4 1\nreply\n%end 1 4 1\n" +
            "%output %9 hello\n"
        ).utf8))
        XCTAssertEqual(batch.paneOutputs, [.init(paneID: PaneId(9), bytes: Array("hello".utf8))])
        XCTAssertEqual(batch.correlationEvents.count, 2)
        XCTAssertEqual(batch.snapshot.sessionID, SessionId(1))
        XCTAssertEqual(batch.snapshot.activeWindowID, WindowId(2))
        XCTAssertEqual(batch.snapshot.windows.first?.activePaneID, PaneId(9))
    }

    func testRuntimeEngineCarriesPerEventSnapshotsAcrossRoundTripSelectionBurst() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%session-changed $1 work\n" +
            "%window-add @1\n" +
            "%window-add @2\n" +
            "%window-pane-changed @1 %10\n" +
            "%window-pane-changed @2 %20\n" +
            "%session-window-changed $1 @1\n"
        ).utf8))

        let batch = engine.feed(Array((
            "%session-window-changed $1 @2\n" +
            "%output %20 foreign\n" +
            "%session-window-changed $1 @1\n"
        ).utf8))

        XCTAssertEqual(batch.orderedSteps.count, 3)
        XCTAssertEqual(batch.orderedSteps.map(\.snapshot.activeWindowID), [
            WindowId(2), WindowId(2), WindowId(1),
        ])
        XCTAssertEqual(batch.snapshot.activeWindowID, WindowId(1))
    }

    func testRuntimeEngineRoutesOutputBellToItsInactiveWindow() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%session-changed $1 work\n" +
            "%window-add @1\n" +
            "%window-add @2\n" +
            "%window-renamed @2 build\n" +
            "%window-pane-changed @1 %10\n" +
            "%window-pane-changed @2 %20\n" +
            "%session-window-changed $1 @1\n"
        ).utf8))

        let batch = engine.feed(Array("%output %20 build\u{07} finished\n".utf8))

        XCTAssertEqual(
            batch.bells,
            [.init(windowID: WindowId(2), isActiveWindow: false, windowName: "build")]
        )
        XCTAssertEqual(batch.paneOutputs, [.init(paneID: PaneId(20), bytes: Array("build\u{07} finished".utf8))])
    }

    func testRuntimeEngineBellSubscriptionOnlyEmitsOnInactiveZeroToOneTransition() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%session-changed $1 work\n" +
            "%window-add @1\n" +
            "%window-add @2\n" +
            "%window-renamed @2 logs\n" +
            "%session-window-changed $1 @1\n"
        ).utf8))

        let initial = engine.feed(Array(
            "%subscription-changed tessera-bell $1 @2 1 %20 : 1\n".utf8
        ))
        let clear = engine.feed(Array(
            "%subscription-changed tessera-bell $1 @2 1 %20 : 0\n".utf8
        ))
        let raised = engine.feed(Array(
            "%subscription-changed tessera-bell $1 @2 1 %20 : 1\n".utf8
        ))
        let duplicate = engine.feed(Array(
            "%subscription-changed tessera-bell $1 @2 1 %20 : 1\n".utf8
        ))
        let active = engine.feed(Array(
            "%subscription-changed tessera-bell $1 @1 1 %10 : 1\n".utf8
        ))

        XCTAssertTrue(initial.bells.isEmpty, "first observation is state hydration, not a bell")
        XCTAssertTrue(clear.bells.isEmpty)
        XCTAssertEqual(
            raised.bells,
            [.init(windowID: WindowId(2), isActiveWindow: false, windowName: "logs")]
        )
        XCTAssertTrue(duplicate.bells.isEmpty)
        XCTAssertTrue(active.bells.isEmpty, "the visible window must not receive an off-screen bell")
    }

    func testRuntimeEngineOwnsValidatedFixedQueryMetadata() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%session-changed $1 work\n" +
            "%window-add @2\n" +
            "%session-window-changed $1 @2\n"
        ).utf8))

        let pane = TmuxPaneSnapshot(
            id: PaneId(9),
            title: "editor",
            currentCommand: "vim",
            isActive: true,
            contentRect: CellRect(width: 80, height: 24, x: 0, y: 0)
        )
        let queried = TmuxWindowSnapshot(
            id: WindowId(2),
            index: 3,
            name: "work",
            activePaneID: PaneId(9),
            activePaneTitle: "editor",
            panes: [pane]
        )
        XCTAssertTrue(engine.ingestWindowListQuery([queried]))
        XCTAssertEqual(engine.snapshot.windows, [queried])

        let invalid = TmuxWindowSnapshot(
            id: WindowId(7),
            index: -1,
            name: String(repeating: "x", count: 8_193)
        )
        XCTAssertFalse(engine.ingestWindowMetadata(invalid))
        XCTAssertEqual(engine.snapshot.windows, [queried])

        _ = engine.feed(Array("%window-renamed @2 logs\n".utf8))
        XCTAssertEqual(engine.snapshot.windows.first?.name, "logs")
        XCTAssertEqual(engine.snapshot.windows.first?.activePaneTitle, "editor")
        XCTAssertEqual(engine.snapshot.windows.first?.panes.first?.currentCommand, "vim")
    }

    func testRuntimeEngineHydratesTaggedFixedQueryFrames() {
        var engine = TmuxRuntimeEngine()
        let windows = engine.feed(Array((
            "%begin 1 1 1\n" +
            "__tessera_windows__\t@4\t0\t%8\t8205,80x24,0,0{40x24,0,0,8,39x24,41,0,9}\t8205,80x24,0,0{40x24,0,0,8,39x24,41,0,9}\t0\tmain\n" +
            "%end 1 1 1\n"
        ).utf8))
        XCTAssertEqual(windows.snapshot.windows.first?.id, WindowId(4))
        XCTAssertEqual(
            windows.snapshot.windows.first?.panes.map(\.id),
            [PaneId(8), PaneId(9)]
        )
        XCTAssertFalse(
            engine.isActiveWindowAuthoritative,
            "window discovery must not manufacture an authoritative active window"
        )

        let serverOriginatedActive = engine.feed(Array((
            "%begin 1 2 0\n" +
            "__tessera_active_window__\t@4\n" +
            "%end 1 2 0\n"
        ).utf8))
        XCTAssertEqual(serverOriginatedActive.snapshot.activeWindowID, nil)
        XCTAssertFalse(
            engine.isActiveWindowAuthoritative,
            "only a correlated client response may hydrate the active window"
        )

        let panesAndActive = engine.feed(Array((
            "%begin 1 3 1\n" +
            "__tessera_panes__\t@4\t%8\t1\t0\t0\t80\t24\teditor\t/home/dev/Project Files\n" +
            "__tessera_panes__\t@4\t%9\t0\t40\t0\t40\t24\tshell\t/home/dev\n" +
            "%end 1 3 1\n" +
            "%begin 1 4 1\n" +
            "__tessera_active_window__\t@4\n" +
            "%end 1 4 1\n"
        ).utf8))
        XCTAssertEqual(panesAndActive.snapshot.activeWindowID, WindowId(4))
        XCTAssertTrue(engine.isActiveWindowAuthoritative)
        XCTAssertEqual(panesAndActive.snapshot.windows.first?.activePaneID, PaneId(8))
        XCTAssertEqual(panesAndActive.snapshot.windows.first?.panes.first?.title, "editor")
        XCTAssertEqual(
            panesAndActive.snapshot.windows.first?.panes.first?.currentPath,
            "/home/dev/Project Files"
        )
        let activePane = engine.feed(Array((
            "%begin 1 5 1\n" +
            "__tessera_active_pane__\t@4\t%9\n" +
            "%end 1 5 1\n"
        ).utf8))
        XCTAssertEqual(activePane.snapshot.windows.first?.activePaneID, PaneId(9))
        let revisionBeforeAmbiguousActiveQuery = activePane.snapshot.revision
        let ambiguousActiveWindow = engine.feed(Array((
            "%begin 1 6 1\n" +
            "__tessera_active_window__\t@4\n" +
            "unexpected-row\n" +
            "%end 1 6 1\n"
        ).utf8))
        XCTAssertEqual(
            ambiguousActiveWindow.snapshot.revision,
            revisionBeforeAmbiguousActiveQuery,
            "an ambiguous fixed-query body must not mutate active topology"
        )
        let ambiguousActivePane = engine.feed(Array((
            "%begin 1 7 1\n" +
            "__tessera_active_pane__\t@4\t%8\n" +
            "__tessera_active_pane__\t@4\t%9\n" +
            "%end 1 7 1\n"
        ).utf8))
        XCTAssertEqual(ambiguousActivePane.snapshot.windows.first?.activePaneID, PaneId(9))
        XCTAssertEqual(
            ambiguousActivePane.snapshot.revision,
            revisionBeforeAmbiguousActiveQuery,
            "multiple tagged pane rows must fail closed instead of accepting the first"
        )
        XCTAssertEqual(
            TmuxRuntimeHydrationQuery.commands.count,
            3
        )
        XCTAssertTrue(TmuxRuntimeHydrationQuery.commands.allSatisfy { $0.contains("\t") })
        XCTAssertFalse(TmuxRuntimeHydrationQuery.commands.contains { $0.contains("\\t") })
        XCTAssertTrue(
            TmuxRuntimeHydrationQuery.commands.contains { $0.contains("#{s/\t/ /:pane_current_path}") }
        )
        XCTAssertEqual(
            TmuxRuntimeHydrationQuery.activeWindowCommand,
            "display-message -p '__tessera_active_window__\t#{window_id}\t#{version}'"
        )
        XCTAssertEqual(
            TmuxRuntimeHydrationQuery.activePaneCommand(windowID: WindowId(4)),
            "display-message -p -t @4 '__tessera_active_pane__\t#{window_id}\t#{pane_id}'"
        )
        XCTAssertTrue(TmuxRuntimeHydrationQuery.activeWindowMatches(
            WindowId(4),
            lines: ["", "__tessera_active_window__\t@4"]
        ))
        XCTAssertEqual(
            TmuxRuntimeHydrationQuery.activeWindowID(
                lines: ["", "__tessera_active_window__\t@4"]
            ),
            WindowId(4)
        )
        XCTAssertFalse(TmuxRuntimeHydrationQuery.activeWindowMatches(
            WindowId(4),
            lines: ["__tessera_active_window__\t@5"]
        ))
        XCTAssertTrue(TmuxRuntimeHydrationQuery.activePaneMatches(
            windowID: WindowId(4),
            paneID: PaneId(9),
            lines: ["", "__tessera_active_pane__\t@4\t%9"]
        ))
        XCTAssertFalse(TmuxRuntimeHydrationQuery.activePaneMatches(
            windowID: WindowId(4),
            paneID: PaneId(9),
            lines: ["__tessera_active_pane__\t@4\t%8"]
        ))
        XCTAssertFalse(TmuxRuntimeHydrationQuery.activeWindowMatches(
            WindowId(4),
            lines: [
                "__tessera_active_window__\t@4",
                "__tessera_active_window__\t@4",
            ]
        ))
        XCTAssertNil(TmuxRuntimeHydrationQuery.activeWindowID(lines: [
            "__tessera_active_window__\t@4",
            "unexpected",
        ]))
    }

    func testRuntimeEngineDistinguishesFallbackFromSessionActiveWindow() {
        var engine = TmuxRuntimeEngine()

        let fallback = engine.feed(Array("%window-add @2\n".utf8))
        XCTAssertEqual(fallback.snapshot.activeWindowID, WindowId(2))
        XCTAssertFalse(engine.isActiveWindowAuthoritative)

        let authoritative = engine.feed(Array("%session-window-changed $0 @2\n".utf8))
        XCTAssertEqual(authoritative.snapshot.activeWindowID, WindowId(2))
        XCTAssertFalse(
            engine.isActiveWindowAuthoritative,
            "a broadcast is not authoritative until this client's session identity is known"
        )

        _ = engine.feed(Array("%session-changed $0 work\n".utf8))
        XCTAssertTrue(engine.isActiveWindowAuthoritative)

        _ = engine.feed(Array("%window-add @3\n%unlinked-window-close @2\n".utf8))
        XCTAssertEqual(engine.snapshot.activeWindowID, WindowId(3))
        XCTAssertFalse(
            engine.isActiveWindowAuthoritative,
            "a close fallback needs a fresh session active-window signal"
        )

        var foreign = TmuxRuntimeEngine()
        _ = foreign.feed(Array(
            "%window-add @9\n%session-window-changed $9 @9\n%session-changed $0 work\n".utf8
        ))
        XCTAssertEqual(foreign.snapshot.sessionID, SessionId(0))
        XCTAssertEqual(foreign.snapshot.activeWindowID, WindowId(9))
        XCTAssertFalse(
            foreign.isActiveWindowAuthoritative,
            "a foreign broadcast seen before our session identity must stay unproven"
        )
    }

    func testUnlinkedForeignAddsAndRenamesAreIgnoredButKnownCloseRemoves() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%window-add @1\n" +
            "%window-renamed @1 local\n" +
            "%unlinked-window-add @9\n" +
            "%unlinked-window-renamed @9 foreign\n"
        ).utf8))
        XCTAssertEqual(engine.snapshot.windows.map(\.id), [WindowId(1)])
        XCTAssertEqual(engine.snapshot.windows.first?.name, "local")

        _ = engine.feed(Array("%unlinked-window-close @1\n".utf8))
        XCTAssertTrue(engine.snapshot.windows.isEmpty)
    }

    private func vectorsDirectory() throws -> URL {
        var package = URL(fileURLWithPath: #filePath)
        package.deleteLastPathComponent()
        package.deleteLastPathComponent()
        package.deleteLastPathComponent()
        package.deleteLastPathComponent()
        package.deleteLastPathComponent()
        return package.appendingPathComponent("ProtocolVectors/tmux")
    }

    private struct RepaintVector: Decodable {
        let renderedStateLine: String
        let captureLines: [String]
        let terminalIsInAltScreen: Bool
        let clientRows: Int
        let expectedBase64: String
    }
}
