import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

/// The C ABI is the only way Android reaches this policy, so the seam itself
/// is tested — not just the Swift core behind it.
final class TmuxCommandsABITests: XCTestCase {
    private struct WindowPlanWire: Decodable {
        let commands: [String]
        let expectedOrder: [String]
    }
    /// Exercise the two-phase string contract the JNI shim relies on: query
    /// the length with no buffer, then copy into exactly that many bytes.
    private func buildCommand(
        _ call: (UnsafeMutablePointer<UInt8>?, Int) -> Int32
    ) throws -> String {
        let required = call(nil, 0)
        XCTAssertGreaterThan(required, 0)
        var buffer = [UInt8](repeating: 0, count: Int(required))
        let written = buffer.withUnsafeMutableBufferPointer {
            call($0.baseAddress, $0.count)
        }
        XCTAssertEqual(written, required)
        return String(decoding: buffer, as: UTF8.self)
    }

    private func withUTF8<T>(_ value: String, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        var bytes = Array(value.utf8)
        return bytes.withUnsafeMutableBufferPointer { body($0.baseAddress, $0.count) }
    }

    func testAgentCommandAuthorityNeutralExport() {
        for command in ["capture-pane -p -t %3", "send-keys -t %3 -H 61 FF", "send-keys -t %3 Enter",
                        "send-keys -t %3 Escape", "send-keys -t %3 Tab", "send-keys -t %3 BTab"] {
            withUTF8(command) { bytes, count in
                XCTAssertEqual(tesseraTmuxAgentCommandIsAuthorityNeutral(commandBytes: bytes, commandCount: count), 1, command)
            }
        }
        for command in ["new-window -d", "set-buffer -b b x", "send-keys -t @3 Enter",
                        "send-keys -t %3 -H", "send-keys -t %3 -l x", "send-keys -t %3 Enter; new-window",
                        "send-keys -t %3 Enter\n"] {
            withUTF8(command) { bytes, count in
                XCTAssertEqual(tesseraTmuxAgentCommandIsAuthorityNeutral(commandBytes: bytes, commandCount: count), 0, command)
            }
        }
        withUTF8("send-keys -t %3 -H 61") { bytes, count in
            XCTAssertEqual(tesseraTmuxAgentCommandIsReadOnly(commandBytes: bytes, commandCount: count), 0)
            XCTAssertEqual(tesseraTmuxAgentCommandIsAuthorityNeutral(commandBytes: bytes, commandCount: 0), -1)
            XCTAssertEqual(tesseraTmuxAgentCommandIsAuthorityNeutral(commandBytes: bytes, commandCount: -1), -1)
        }
        XCTAssertEqual(tesseraTmuxAgentCommandIsAuthorityNeutral(commandBytes: nil, commandCount: 0), -1)
        XCTAssertEqual(tesseraTmuxAgentCommandIsAuthorityNeutral(commandBytes: nil, commandCount: 4), -1)
    }

    func testCommandBuildersMatchTheCoreAcrossTheStringContract() throws {
        let mosh = try buildCommand { output, capacity in
            withUTF8("tessera-abc123") { target, targetCount in
                tesseraTmuxMoshVisibleClientCommand(
                    sessionTargetBytes: target,
                    sessionTargetCount: targetCount,
                    gridAuthorityDeviceIDBytes: nil,
                    gridAuthorityDeviceIDCount: 0,
                    ignoresSize: 1,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(
            mosh,
            AutoTmuxCommands.moshVisibleClientCommand(
                sessionTarget: "tessera-abc123",
                gridAuthorityDeviceID: nil,
                ignoresSize: true
            )
        )
        // The command separator has to survive the ABI byte-for-byte, or the
        // remote shell swallows `set-option` into the session name.
        XCTAssertTrue(mosh.contains(#"\;"#))

        let control = try buildCommand { output, capacity in
            withUTF8("tessera-abc123") { target, targetCount in
                tesseraTmuxControlModeSessionCommand(
                    sessionTargetBytes: target,
                    sessionTargetCount: targetCount,
                    preserveInitialGeometry: 0,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        // The builder wraps the exec in a PATH repair for hosts whose login
        // files are the only place tmux resolves; what crosses the ABI must be
        // that same command, byte for byte.
        XCTAssertEqual(
            control,
            AutoTmuxCommands.controlModeSessionCommand(sessionTarget: "tessera-abc123")
        )
        XCTAssertTrue(control.contains("exec tmux -CC new-session -A -s 'tessera-abc123'"))
        XCTAssertFalse(control.contains("ignore-size"))
    }

    func testClientSizeReplayCrossesTheSeamWithItsLatestFence() throws {
        let inline = try buildCommand { buffer, capacity in
            tesseraTmuxClientSizeReplayCommands(
                columns: 54, rows: 37, sideChannel: 0, belongsToClaim: 0,
                outputBytes: buffer, outputCapacity: capacity
            )
        }
        XCTAssertEqual(
            inline.split(separator: "\n").map(String.init),
            TmuxClientSizeReplay.commands(columns: 54, rows: 37, path: .inline)
        )
        XCTAssertEqual(inline, "refresh-client -C 54,37\nselect-window")

        let claim = try buildCommand { buffer, capacity in
            tesseraTmuxClientSizeReplayCommands(
                columns: 54, rows: 37, sideChannel: 0, belongsToClaim: 1,
                outputBytes: buffer, outputCapacity: capacity
            )
        }
        XCTAssertEqual(claim, "refresh-client -C 54,37")

        let sideChannel = try buildCommand { buffer, capacity in
            tesseraTmuxClientSizeReplayCommands(
                columns: 54, rows: 37, sideChannel: 1, belongsToClaim: 0,
                outputBytes: buffer, outputCapacity: capacity
            )
        }
        XCTAssertEqual(sideChannel, "refresh-client -C 54,37")

        XCTAssertEqual(
            tesseraTmuxClientSizeReplayCommands(
                columns: 0, rows: 37, sideChannel: 0, belongsToClaim: 0,
                outputBytes: nil, outputCapacity: 0
            ),
            -1
        )
    }

    /// The fence an adapter writes alone (a take-back's own, or the one it
    /// reissues for a grid it already advertised) is the replay's own fence,
    /// so the platforms keep no copy of the literal.
    func testLatestFenceCommandIsTheReplaysOwnFence() throws {
        let fence = try buildCommand { buffer, capacity in
            tesseraTmuxClientSizeLatestFenceCommand(outputBytes: buffer, outputCapacity: capacity)
        }
        XCTAssertEqual(fence, TmuxClientSizeReplay.latestFenceCommand)
        XCTAssertEqual(fence, "select-window")
        XCTAssertEqual(
            TmuxClientSizeReplay.commands(columns: 54, rows: 37, path: .inline).last,
            fence
        )
        var short = [UInt8](repeating: 0, count: fence.utf8.count - 1)
        XCTAssertEqual(
            short.withUnsafeMutableBufferPointer {
                tesseraTmuxClientSizeLatestFenceCommand(outputBytes: $0.baseAddress, outputCapacity: $0.count)
            },
            -1,
            "a short buffer is refused, never truncated"
        )
    }

    func testMoshDeviceIdIsOptionalAndCommandsRejectMissingArguments() throws {
        let stamped = try buildCommand { output, capacity in
            withUTF8("tessera-abc123") { target, targetCount in
                withUTF8("device-7") { device, deviceCount in
                    tesseraTmuxMoshVisibleClientCommand(
                        sessionTargetBytes: target,
                        sessionTargetCount: targetCount,
                        gridAuthorityDeviceIDBytes: device,
                        gridAuthorityDeviceIDCount: deviceCount,
                        ignoresSize: 0,
                        outputBytes: output,
                        outputCapacity: capacity
                    )
                }
            }
        }
        XCTAssertTrue(stamped.contains("set-option -F"))
        XCTAssertFalse(stamped.contains("ignore-size"))

        XCTAssertEqual(
            tesseraTmuxControlModeSessionCommand(
                sessionTargetBytes: nil,
                sessionTargetCount: 0,
                preserveInitialGeometry: 0,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )
    }

    func testAnUndersizedBufferIsRefusedRatherThanTruncated() {
        let required = withUTF8("tessera-abc123") { target, targetCount in
            tesseraTmuxControlModeSessionCommand(
                sessionTargetBytes: target,
                sessionTargetCount: targetCount,
                preserveInitialGeometry: 1,
                outputBytes: nil,
                outputCapacity: 0
            )
        }
        XCTAssertGreaterThan(required, 0)
        var buffer = [UInt8](repeating: 0, count: Int(required) - 1)
        let written = buffer.withUnsafeMutableBufferPointer { output in
            withUTF8("tessera-abc123") { target, targetCount in
                tesseraTmuxControlModeSessionCommand(
                    sessionTargetBytes: target,
                    sessionTargetCount: targetCount,
                    preserveInitialGeometry: 1,
                    outputBytes: output.baseAddress,
                    outputCapacity: output.count
                )
            }
        }
        XCTAssertEqual(written, -1)
    }

    func testWindowExportsUseCanonicalTwoPassPayloads() throws {
        func callJSON(
            _ request: String,
            _ function: (
                UnsafePointer<UInt8>?, Int,
                UnsafeMutablePointer<UInt8>?, Int
            ) -> Int32
        ) throws -> String {
            try buildCommand { output, capacity in
                withUTF8(request) { bytes, count in
                    function(bytes, count, output, capacity)
                }
            }
        }

        let command = try callJSON(#"{"op":"newWindowAfterCurrent"}"#, tesseraTmuxWindowCommand)
        XCTAssertEqual(command, TmuxWindowCommands.newWindowAfterCurrent())

        let detached = try callJSON(
            ##"{"command":"agent-host --resume","detached":true,"name":"Agent","op":"newWindowAtEnd","printFormat":"#{window_id}","target":"work"}"##,
            tesseraTmuxWindowCommand
        )
        XCTAssertEqual(
            detached,
            TmuxWindowCommands.newWindowAtEnd(
                target: "work",
                detached: true,
                name: "Agent",
                printFormat: "#{window_id}",
                command: "agent-host --resume"
            )
        )

        let capabilities = try callJSON(#"{"version":"3.2a"}"#, tesseraTmuxWindowCapabilities)
        XCTAssertEqual(
            capabilities,
            #"{"supportsMoveBefore":true,"supportsSubscriptions":true}"#
        )

        let request = #"{"activeWindowID":"@1","capabilities":{"supportsMoveBefore":true,"supportsSubscriptions":true},"destination":0,"highestIndex":3,"moving":"@3","order":["@1","@2","@3"],"sessionID":"$7"}"#
        let planJSON = try callJSON(request, tesseraTmuxWindowReorderPlan)
        let planData = try XCTUnwrap(planJSON.data(using: .utf8))
        let plan = try JSONDecoder().decode(WindowPlanWire.self, from: planData)
        let expected = try XCTUnwrap(TmuxWindowReorderPlanner.plan(
            order: [WindowId(1), WindowId(2), WindowId(3)],
            moving: WindowId(3),
            to: 0,
            capabilities: .init(supportsMoveBefore: true, supportsSubscriptions: true),
            sessionID: SessionId(7),
            activeWindowID: WindowId(1),
            highestIndex: 3
        ))
        XCTAssertEqual(plan.commands, expected.commands)
        XCTAssertEqual(plan.expectedOrder, expected.expectedOrder.map(\.description))
        XCTAssertTrue(planJSON.hasPrefix(#"{"commands":["#), planJSON)

        var tooSmall = [UInt8](repeating: 0xA5, count: max(0, command.utf8.count - 1))
        let undersized = tooSmall.withUnsafeMutableBufferPointer { output in
            withUTF8(#"{"op":"newWindowAfterCurrent"}"#) { bytes, count in
                tesseraTmuxWindowCommand(
                    requestBytes: bytes,
                    requestCount: count,
                    outputBytes: output.baseAddress,
                    outputCapacity: output.count
                )
            }
        }
        XCTAssertEqual(undersized, -1)
        XCTAssertEqual(tooSmall, [UInt8](repeating: 0xA5, count: tooSmall.count))
    }

    func testWindowExportsRejectNoncanonicalUnsafeAndOversizedInput() {
        let noncanonical = #"{ "op":"newWindowAfterCurrent" }"#
        XCTAssertEqual(withUTF8(noncanonical) { bytes, count in
            tesseraTmuxWindowCommand(
                requestBytes: bytes, requestCount: count,
                outputBytes: nil, outputCapacity: 0
            )
        }, -1)

        let injected = #"{"name":"x\nkill-server\nx","op":"renameWindow","windowId":"@1"}"#
        XCTAssertEqual(withUTF8(injected) { bytes, count in
            tesseraTmuxWindowCommand(
                requestBytes: bytes, requestCount: count,
                outputBytes: nil, outputCapacity: 0
            )
        }, -1)

        var invalidUTF8: [UInt8] = [0x7B, 0xFF, 0x7D]
        XCTAssertEqual(invalidUTF8.withUnsafeMutableBufferPointer { bytes in
            tesseraTmuxWindowCapabilities(
                requestBytes: bytes.baseAddress, requestCount: bytes.count,
                outputBytes: nil, outputCapacity: 0
            )
        }, -1)

        var oversized = [UInt8](repeating: 0x20, count: SharedABI.maximumInputBytes + 1)
        XCTAssertEqual(oversized.withUnsafeMutableBufferPointer { bytes in
            tesseraTmuxWindowReorderPlan(
                requestBytes: bytes.baseAddress, requestCount: bytes.count,
                outputBytes: nil, outputCapacity: 0
            )
        }, -1)
    }

    func testSessionGroupExportsPreserveEveryMembersSelection() throws {
        let query = try buildCommand { output, capacity in
            withUTF8(#"{"op":"sessionGroupQuery"}"#) { bytes, count in
                tesseraTmuxWindowCommand(
                    requestBytes: bytes, requestCount: count,
                    outputBytes: output, outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(query, TmuxSessionGroupQuery.command)

        let membersJSON = try buildCommand { output, capacity in
            withUTF8(#"{"containingSessionID":"$2","lines":["$1\tteam\t@10","$2\tteam\t@20","$3\tother\t@30"]}"#) { bytes, count in
                tesseraTmuxSessionGroupMembers(
                    requestBytes: bytes, requestCount: count,
                    outputBytes: output, outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(
            membersJSON,
            #"[{"activeWindowID":"@10","sessionID":"$1"},{"activeWindowID":"@20","sessionID":"$2"}]"#
        )

        let commandsJSON = try buildCommand { output, capacity in
            withUTF8(#"{"attachedSessionID":"$2","members":[{"activeWindowID":"@10","sessionID":"$1"},{"activeWindowID":"@20","sessionID":"$2"}]}"#) { bytes, count in
                tesseraTmuxSessionGroupRenumberCommands(
                    requestBytes: bytes, requestCount: count,
                    outputBytes: output, outputCapacity: capacity
                )
            }
        }
        let commands = try JSONDecoder().decode(
            [String].self,
            from: XCTUnwrap(commandsJSON.data(using: .utf8))
        )
        XCTAssertEqual(commands, [
            "move-window -r -t '$1'",
            "move-window -r -t '$2'",
            "select-window -t $1:@10",
            "select-window -t $2:@20",
        ])
    }

    func testCanvasProjectionPansASplitWindowAndReportsDegenerateInput() {
        var values = [Double](repeating: -1, count: 5)
        let status = values.withUnsafeMutableBufferPointer { output in
            tesseraTmuxCompactCanvasProjection(
                windowColumns: 80,
                windowRows: 24,
                windowX: 0,
                windowY: 0,
                focusColumns: 40,
                focusRows: 24,
                focusX: 40,
                focusY: 0,
                cellWidth: 10,
                cellHeight: 20,
                viewportWidth: 400,
                viewportHeight: 480,
                outputValues: output.baseAddress
            )
        }
        XCTAssertEqual(status, 1)
        let expected = TmuxCompactCanvas.projection(
            window: CellRect(width: 80, height: 24, x: 0, y: 0),
            focus: CellRect(width: 40, height: 24, x: 40, y: 0),
            cellWidth: 10,
            cellHeight: 20,
            viewportWidth: 400,
            viewportHeight: 480
        )
        XCTAssertEqual(values[0], expected?.contentWidth)
        XCTAssertEqual(values[1], expected?.contentHeight)
        XCTAssertEqual(values[2], expected?.scale)
        XCTAssertEqual(values[3], expected?.offsetX)
        XCTAssertEqual(values[4], expected?.offsetY)
        // The right-hand pane is panned fully into view.
        XCTAssertEqual(values[3], -400)

        var degenerate = [Double](repeating: 7, count: 5)
        let none = degenerate.withUnsafeMutableBufferPointer { output in
            tesseraTmuxCompactCanvasProjection(
                windowColumns: 0,
                windowRows: 0,
                windowX: 0,
                windowY: 0,
                focusColumns: 0,
                focusRows: 0,
                focusX: 0,
                focusY: 0,
                cellWidth: 10,
                cellHeight: 20,
                viewportWidth: 400,
                viewportHeight: 480,
                outputValues: output.baseAddress
            )
        }
        XCTAssertEqual(none, 0)
        // Nothing is written on the degenerate answer: the caller keeps its
        // own natural-size fallback rather than reading zeroes as a transform.
        XCTAssertEqual(degenerate, [Double](repeating: 7, count: 5))
        XCTAssertEqual(
            tesseraTmuxCompactCanvasProjection(
                windowColumns: 80,
                windowRows: 24,
                windowX: 0,
                windowY: 0,
                focusColumns: 80,
                focusRows: 24,
                focusX: 0,
                focusY: 0,
                cellWidth: 10,
                cellHeight: 20,
                viewportWidth: 400,
                viewportHeight: 480,
                outputValues: nil
            ),
            -1
        )
    }

    func testStamplessPeerBridgeMapsFlagsAndTheNeverReplayedSentinel() {
        func raise(
            policyIsLatest: Int32 = 1,
            alreadyPeer: Int32 = 0,
            seconds: Double = -1
        ) -> Int32 {
            tesseraTmuxStamplessPeerShouldRaise(
                participatesInAuthority: 1,
                windowSizePolicyKnown: 1,
                windowSizePolicyIsLatest: policyIsLatest,
                rederiveInFlight: 0,
                alreadyPeer: alreadyPeer,
                reclaimInFlight: 0,
                layoutIsForRenderedWindow: 1,
                layoutColumns: 120,
                layoutRows: 40,
                localColumns: 80,
                localRows: 24,
                secondsSinceLocalSizeReplay: seconds
            )
        }
        // A negative age is "never replayed", not "replayed just now".
        XCTAssertEqual(raise(), 1)
        XCTAssertEqual(raise(seconds: 0.5), 0)
        XCTAssertEqual(raise(seconds: TmuxStamplessPeer.replaySuppressionSeconds + 1), 1)
        XCTAssertEqual(raise(policyIsLatest: 0), 0)
        XCTAssertEqual(raise(alreadyPeer: 1), 0)
    }

    func testHydrationCommandsEndWithTheSharedPauseAfterPolicy() throws {
        let commands = try buildCommand { output, capacity in
            tesseraTmuxHydrationCommands(
                outputBytes: output,
                outputCapacity: capacity
            )
        }
        XCTAssertEqual(
            commands.split(separator: "\n").last,
            "refresh-client -f pause-after=5"
        )
    }

    func testActivePaneCommandCrossesTheSeamIntact() throws {
        let command = try buildCommand { output, capacity in
            tesseraTmuxActivePaneCommand(
                windowID: 7,
                outputBytes: output,
                outputCapacity: capacity
            )
        }
        XCTAssertEqual(
            command,
            TmuxRuntimeHydrationQuery.activePaneCommand(windowID: WindowId(7))
        )
        XCTAssertEqual(
            tesseraTmuxActivePaneCommand(
                windowID: -1,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )
    }

    /// W2: Android builds its tab switches and visible-client targets through
    /// this seam, so the quoted spelling is the one iOS sends in-process.
    func testSessionQualifiedWindowTargetCrossesTheSeam() throws {
        func target(_ session: Int32, _ window: Int32, _ pane: Int32) throws -> String {
            try buildCommand { output, capacity in
                tesseraTmuxSessionWindowTarget(
                    sessionID: session,
                    windowID: window,
                    paneID: pane,
                    outputBytes: output,
                    outputCapacity: capacity
                )
            }
        }
        XCTAssertEqual(try target(4, 7, -1), "'$4:@7'")
        XCTAssertEqual(try target(4, 7, 12), "'$4:@7.%12'")
        XCTAssertEqual(try target(0, 0, 0), "'$0:@0.%0'")
        XCTAssertEqual(
            try target(4, 7, -1),
            TmuxWindowCommands.sessionQualifiedTarget(WindowId(7), sessionID: SessionId(4))
        )
        for (session, window) in [(Int32(-1), Int32(7)), (4, -1)] {
            XCTAssertEqual(
                tesseraTmuxSessionWindowTarget(
                    sessionID: session,
                    windowID: window,
                    paneID: -1,
                    outputBytes: nil,
                    outputCapacity: 0
                ),
                -1
            )
        }
    }

    func testSelectWindowRequestBuildsTheSessionQualifiedTabSwitch() throws {
        func command(_ request: String) -> (Int32, String) {
            var buffer = [UInt8](repeating: 0, count: 256)
            let written = buffer.withUnsafeMutableBufferPointer { output in
                withUTF8(request) { bytes, count in
                    tesseraTmuxWindowCommand(
                        requestBytes: bytes,
                        requestCount: count,
                        outputBytes: output.baseAddress,
                        outputCapacity: output.count
                    )
                }
            }
            return (written, String(decoding: buffer.prefix(max(0, Int(written))), as: UTF8.self))
        }
        XCTAssertEqual(
            command(#"{"op":"selectWindow","sessionId":"$4","windowId":"@7"}"#).1,
            "select-window -t '$4:@7'"
        )
        XCTAssertEqual(
            command(#"{"op":"selectWindow","sessionId":"$4","windowId":"@7"}"#).1,
            TmuxWindowCommands.selectWindow(WindowId(7), inOwnSession: SessionId(4))
        )
        // The legacy request is unchanged.
        XCTAssertEqual(command(#"{"op":"selectWindow","windowId":"@7"}"#).1, "select-window -t @7")
        // A malformed session id, or a session on any other op, is refused.
        XCTAssertEqual(command(#"{"op":"selectWindow","sessionId":"4","windowId":"@7"}"#).0, -1)
        XCTAssertEqual(command(#"{"op":"killWindow","sessionId":"$4","windowId":"@7"}"#).0, -1)
    }

    /// Android resolves the veil's wording through this export, so the rule
    /// crossing the seam must be the same rule iOS applies in-process.
    func testPeerLabelResolvesThroughTheSeam() throws {
        func label(peer: String?, selfName: String, known: String) throws -> String {
            try buildCommand { output, capacity in
                withUTF8(selfName) { selfBytes, selfCount in
                    withUTF8(known) { knownBytes, knownCount in
                        func call(_ peerBytes: UnsafePointer<UInt8>?, _ peerCount: Int) -> Int32 {
                            tesseraTmuxPeerLabel(
                                peerDisplayNameBytes: peerBytes,
                                peerDisplayNameCount: peerCount,
                                selfDisplayNameBytes: selfBytes,
                                selfDisplayNameCount: selfCount,
                                knownDeviceNamesBytes: knownBytes,
                                knownDeviceNamesCount: knownCount,
                                outputBytes: output,
                                outputCapacity: capacity
                            )
                        }
                        guard let peer else { return call(nil, 0) }
                        return withUTF8(peer) { call($0, $1) }
                    }
                }
            }
        }
        let androidKnown = "Android-Phone\tAndroid-Tablet"
        XCTAssertEqual(
            try label(peer: "iPad", selfName: "Android-Phone", known: androidKnown),
            TmuxStamplessPeer.displayName
        )
        XCTAssertEqual(
            try label(peer: nil, selfName: "Android-Phone", known: androidKnown),
            TmuxStamplessPeer.displayName
        )
        XCTAssertEqual(
            try label(peer: "Android-Tablet", selfName: "Android-Phone", known: androidKnown),
            "Android-Tablet"
        )
        XCTAssertEqual(
            try label(peer: "Android-Phone", selfName: "Android-Phone", known: androidKnown),
            "another Android-Phone"
        )
    }

    func testPeerLabelRejectsAMissingSelfName() {
        XCTAssertEqual(
            tesseraTmuxPeerLabel(
                peerDisplayNameBytes: nil,
                peerDisplayNameCount: 0,
                selfDisplayNameBytes: nil,
                selfDisplayNameCount: 0,
                knownDeviceNamesBytes: nil,
                knownDeviceNamesCount: 0,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )
    }
}

extension TmuxCommandsABITests {

    /// The classifier crosses the ABI as a bare int so Android can degrade a
    /// failed tmux launch by the same rules iOS uses for its PTY sentinels.
    func testLaunchFailureClassificationCrossesTheABI() {
        func classify(_ exitStatus: Int32?, _ output: String) -> Int32 {
            var bytes = Array(output.utf8)
            return bytes.withUnsafeMutableBufferPointer { buffer in
                tesseraTmuxClassifyLaunchFailure(
                    exitStatus: exitStatus ?? 0,
                    hasExitStatus: exitStatus == nil ? 0 : 1,
                    outputBytes: buffer.baseAddress,
                    outputCount: buffer.count
                )
            }
        }

        XCTAssertEqual(classify(127, "zsh:1: command not found: tmux"), 1)
        XCTAssertEqual(classify(1, "no server running on /tmp/tmux-501/default"), 2)
        XCTAssertEqual(classify(1, "sessions should be nested with care"), 3)
        XCTAssertEqual(classify(0, ""), 0, "a clean exit with no signal is not a launch failure")
        XCTAssertEqual(classify(nil, ""), 0, "no reported status and no text classifies nothing")
    }

    /// An empty output buffer must be accepted, not treated as a broken call:
    /// exit 127 alone is the most reliable signal there is.
    func testClassificationAcceptsAnAbsentOutputBuffer() {
        XCTAssertEqual(
            tesseraTmuxClassifyLaunchFailure(
                exitStatus: 127,
                hasExitStatus: 1,
                outputBytes: nil,
                outputCount: 0
            ),
            1
        )
    }
}
