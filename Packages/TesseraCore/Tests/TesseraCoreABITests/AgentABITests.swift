import Foundation
import XCTest
import TesseraAgentCore
@testable import TesseraCoreABI

final class AgentABITests: XCTestCase {
    func testOutgoingFrontierRoundTripsFullWidthOffsetsAndRequiresSeparateDispatch() throws {
        let id = thread(), token = UUID()
        let lease = AgentActionLease(threadID: id, binding: binding(), action: .send)
        let frontier = AgentOutgoingFrontier(actionID: lease.token, serviceEpoch: "epoch", provider: id.providerID,
            providerSessionID: id.providerSessionID, sourceIdentity: "jsonl:1:2", sourceEnd: UInt64.max, consistency: .observedPrefix)!
        let arm = AgentABICommand(kind: .armOutgoing, bindingToken: token, frontier: frontier, lease: lease)
        let decoded = try AgentABICommand.decode(arm.encoded())
        XCTAssertEqual(decoded.frontier, frontier)
        let json = try JSONSerialization.jsonObject(with: arm.encoded()) as! [String: Any]
        let wire = json["frontier"] as! [String: Any]
        XCTAssertEqual(wire["sourceEnd"] as? String, String(UInt64.max))
        XCTAssertEqual(wire["provider"] as? String, id.providerID.rawValue)
        let longID = AgentThreadID(hostID: id.hostID, providerID: id.providerID, providerSessionID: String(repeating: "s", count: 512))!
        let longLease = AgentActionLease(threadID: longID, binding: binding(), action: .send)
        XCTAssertEqual(AgentOutgoingFrontier.unavailable(for: longLease).providerSessionID, longID.providerSessionID)
        let dispatch = AgentABICommand(kind: .outgoingDispatched, bindingToken: token, lease: lease)
        XCTAssertEqual(try AgentABICommand.decode(dispatch.encoded()).kind, .outgoingDispatched)
        XCTAssertThrowsError(try AgentABICommand(kind: .outgoingDispatched, bindingToken: token, frontier: frontier, lease: lease).encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .armOutgoing, bindingToken: token, lease: lease).encoded())
        for invalid in ["-1", "18446744073709551616", "1.5"] {
            var invalidWire = wire; invalidWire["sourceEnd"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(AgentOutgoingFrontier.self, from: JSONSerialization.data(withJSONObject: invalidWire)))
        }
        var falseAuthority = wire; falseAuthority["consistency"] = "providerSnapshot"
        XCTAssertThrowsError(try JSONDecoder().decode(AgentOutgoingFrontier.self, from: JSONSerialization.data(withJSONObject: falseAuthority)))
    }

    func testCodexPlaceholderLiteralCannotBypassEmptyDraftSafetyAcrossABI() throws {
        for (body, column, expected) in [
            ("Ask Codex to do anything", 2, Int32(4)),
            ("Ask Codex to do anything", 26, Int32(4)),
            ("\u{1b}[2mAsk Codex to do anything\u{1b}[0m", 2, Int32(1)),
            ("\u{1b}[2mAsk Codex to do anything\u{1b}[0m", 26, Int32(4)),
        ] {
            let input = try JSONSerialization.data(withJSONObject: ["provider": "codex", "text": "new message",
                "visibleText": "› " + body + "\n\nfooter", "cursorRow": 0, "cursorColumn": column,
                "cursorVisible": true, "safetyOnly": true, "requireEmpty": true])
            XCTAssertEqual(input.withUnsafeBytes {
                tesseraAgentComposerAssess(inputBytes: $0.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: $0.count)
            }, expected)
        }
    }

    func testClaudeSuggestionSafetyRequiresCursorColumnAcrossABI() throws {
        for (body, column, expected) in [
            ("S\u{1b}[2mummarize changes\u{1b}[0m", 2, Int32(1)),
            ("S\u{1b}[2mummarize changes\u{1b}[0m", nil, Int32(4)),
            ("S\u{1b}[2mummarize changes\u{1b}[0m", 3, Int32(4)),
            ("Summarize changes", 2, Int32(4)),
        ] as [(String, Int?, Int32)] {
            var payload: [String: Any] = ["provider": "claude", "text": "new message",
                "visibleText": "────\n❯ " + body + "\n────\nfooter", "cursorRow": 1,
                "cursorVisible": true, "safetyOnly": true, "requireEmpty": true]
            if let column { payload["cursorColumn"] = column }
            let input = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertEqual(input.withUnsafeBytes {
                tesseraAgentComposerAssess(inputBytes: $0.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: $0.count)
            }, expected)
        }
    }

    func testCodexImageGuardCrossesABIWithOriginalDraft() throws {
        for (screen, cursorRow, expected) in [("› Describe\n  [Image #1]\n\ngpt-5.4 default · /tmp", 1, Int32(1)),
                                              ("› [Image #1]\n\ngpt-5.4 default · /tmp", 0, Int32(-1))] {
            let input = try JSONSerialization.data(withJSONObject: ["provider": "codex", "text": "Describe\n\"/tmp/a.png\"",
                "visibleText": screen, "cursorRow": cursorRow, "cursorVisible": true, "safetyOnly": true,
                "requireEmpty": false, "queueWhenWorking": false])
            input.withUnsafeBytes { raw in
                XCTAssertEqual(tesseraAgentComposerAssess(inputBytes: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: raw.count), expected)
            }
        }
    }

    func testClaudeImageSafetyAndDepartureCrossABIWithOriginalDraft() throws {
        let text = "\"/tmp/a.png\"\n\"/tmp/b.png\"\nReply with one word: ok"
        for (rows, safetyExpected, presenceExpected) in [
            (["❯ [Image #4]", "  [Image #5]", "  Reply with one word: ok"], Int32(1), Int32(1)),
            (["❯ [Image #4]", "  [Image #6]", "  Reply with one word: ok"], Int32(-1), Int32(-1)),
            (["❯ [Image #4]"], Int32(-1), Int32(-1)),
            (["❯ "], Int32(-1), Int32(0)),
        ] {
            for safety in [false, true] {
                let input = try JSONSerialization.data(withJSONObject: ["provider": "claude", "text": text,
                    "visibleText": rows.joined(separator: "\n") + "\n────\n? for shortcuts", "cursorRow": rows.count - 1,
                    "cursorLine": rows.last!, "cursorVisible": true, "safetyOnly": safety, "requireEmpty": false])
                input.withUnsafeBytes { raw in
                    XCTAssertEqual(tesseraAgentComposerAssess(inputBytes: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        inputCount: raw.count), safety ? safetyExpected : presenceExpected)
                }
            }
        }
    }

    func testLiteralImageFallbackOptionalFieldCrossesABI() throws {
        let text = "\"/tmp/a.png\"\n\"/tmp/b.png\""
        for mode in [nil, false, true] as [Bool?] {
            for (body, normal, literal) in [(text, Int32(-1), Int32(1)),
                ("[Image #4]\n\"/tmp/b.png\"", -1, -1),
                ("[Image #4]\n[Image #5]", 1, -1)] {
                var payload: [String: Any] = ["provider": "claude", "text": text,
                    "visibleText": "❯ " + body + "\n────\n? for shortcuts", "cursorRow": 1,
                    "cursorVisible": true, "safetyOnly": true, "requireEmpty": false]
                if let mode { payload["literalImagePathsOnly"] = mode }
                let input = try JSONSerialization.data(withJSONObject: payload)
                XCTAssertEqual(try JSONSerialization.jsonObject(with: input) as? NSDictionary, payload as NSDictionary)
                XCTAssertEqual(input.withUnsafeBytes {
                    tesseraAgentComposerAssess(inputBytes: $0.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: $0.count)
                }, mode == true ? literal : normal)
            }
        }
    }

    func testComposerInsertionABIUsesBoundedExactPasteBytes() throws {
        for (provider, text) in [("claude", "first\n\nsecond\n"), ("claude", "Describe\n\"/tmp/a screenshot.png\""), ("codex", "Describe\n\"/tmp/a screenshot.png\"")] {
        let input = try JSONSerialization.data(withJSONObject: ["provider": provider, "text": text, "bracketedPasteEnabled": false])
        try input.withUnsafeBytes { raw in
            let inputBytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let count = tesseraAgentComposerInsertion(inputBytes: inputBytes, inputCount: raw.count, outputBytes: nil, outputCapacity: 0)
            XCTAssertGreaterThan(count, 0)
            var output = [UInt8](repeating: 0, count: Int(count))
            XCTAssertEqual(tesseraAgentComposerInsertion(inputBytes: inputBytes, inputCount: raw.count, outputBytes: &output, outputCapacity: output.count - 1), -1)
            XCTAssertEqual(tesseraAgentComposerInsertion(inputBytes: inputBytes, inputCount: raw.count, outputBytes: &output, outputCapacity: output.count), count)
            XCTAssertEqual(Data(base64Encoded: String(decoding: output, as: UTF8.self)), AgentTextInsertion.bytes(provider: provider, text: text, bracketedPasteEnabled: false))
        }
        }
        XCTAssertEqual(tesseraAgentComposerInsertion(inputBytes: nil, inputCount: 0, outputBytes: nil, outputCapacity: 0), -1)
    }

    func testBindCarriesSavedHostNameAndRefreshesItWithoutChangingThreadIdentity() async throws {
        let expectation = expectation(description: "two named binds")
        expectation.expectedFulfillmentCount = 8
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        let command = AgentABICommand(kind: .bind, threadID: id, bindingToken: token, hostDisplayLabel: "windows")
        XCTAssertEqual(try AgentABICommand.decode(command.encoded()).hostDisplayLabel, "windows")
        runtime.submit(try command.encoded())
        runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: id, bindingToken: token,
            lifecycle: AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart,
                status: .working, providerSessionID: id.providerSessionID, agentPID: 42, transcriptRef: "b3BhcXVl")!).encoded())
        runtime.submit(try AgentABICommand(kind: .configure, hostDisplayLabels: [hostID.uuidString: "Windows workstation"]).encoded())
        // A still-live carrier can retain its original host DTO. Saved-host
        // display metadata wins without rotating or replacing that carrier.
        runtime.submit(try command.encoded())
        await fulfillment(of: [expectation], timeout: 2)
        let snapshots = capture.events.compactMap(\.thread)
        XCTAssertEqual(snapshots.map(\.summary.hostDisplayLabel), ["windows", "windows", "Windows workstation", "Windows workstation"])
        XCTAssertTrue(snapshots.allSatisfy { $0.summary.id == id })
        XCTAssertTrue(snapshots.allSatisfy { $0.binding == binding() })
        XCTAssertEqual(capture.events.last?.list?.threads.first?.hostDisplayLabel, "Windows workstation")
        XCTAssertThrowsError(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token, hostDisplayLabel: String(repeating: "x", count: 2_049)).encoded())
        runtime.destroy()
    }

    func testComposerAssessmentABIKeepsUnknownSeparateFromAbsentAndSelectsQueueKey() throws {
        func assess(_ screen: String, cursor: String, queue: Bool = true) throws -> Int32 {
            let payload = try JSONSerialization.data(withJSONObject: ["provider": "codex", "visibleText": screen,
                "cursorLine": cursor, "text": "hello world", "queueWhenWorking": queue])
            return payload.withUnsafeBytes { tesseraAgentComposerAssess(inputBytes: $0.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: $0.count) }
        }
        XCTAssertEqual(try assess("› hello\n  world\n\ntab to queue message 97% context left", cursor: "world"), 2)
        XCTAssertEqual(try assess("› hello world\n\ntab to queue message", cursor: "› hello world", queue: false), 1)
        XCTAssertEqual(try assess("› hello world\n\ngpt-5.6 low · /repo", cursor: "› hello world"), 1)
        XCTAssertEqual(try assess("› Ask Codex to do anything\n\ngpt-5.6 low · /repo", cursor: "› Ask Codex to do anything"), 0)
        XCTAssertEqual(try assess("› hello world\nunknown footer", cursor: "› hello world"), -1)
        XCTAssertEqual(tesseraAgentComposerAssess(inputBytes: nil, inputCount: 0), -1)
    }

    func testComposerEvidenceABIFailsClosedAndPreservesWrappedText() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "provider": "codex", "visibleText": "› hello\n  world\n\ngpt-5.6 low · /repo",
            "cursorLine": "world", "text": "hello world"
        ])
        XCTAssertEqual(payload.withUnsafeBytes { raw in
            tesseraAgentComposerMatches(inputBytes: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: raw.count)
        }, 1)
        XCTAssertEqual(tesseraAgentComposerMatches(inputBytes: nil, inputCount: 0), 0)
        let invalid = Data("{}".utf8)
        XCTAssertEqual(invalid.withUnsafeBytes { raw in
            tesseraAgentComposerMatches(inputBytes: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: raw.count)
        }, 0)
    }
    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func thread(provider: AgentProviderID = .claude, session: String = "provider-session") -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: provider, providerSessionID: session)!
    }

    private func binding(generation: UInt64 = 1, paneID: String = "%2",
                         capabilities: AgentTerminalCapabilities = [.observe, .send, .tmux]) -> AgentTerminalBinding {
        AgentTerminalBinding(
            liveSessionID: sessionID,
            carrierGeneration: generation,
            incarnation: AgentIncarnationToken("incarnation")!,
            transport: .sshTmux,
            tmuxSession: "work",
            windowID: "@1",
            paneID: paneID,
            agentPID: 42,
            capabilities: capabilities
        )
    }

    private func bindingToken(
        _ runtime: AgentABIRuntime,
        id: AgentThreadID,
        binding: AgentTerminalBinding? = nil,
        sourceIdentity: String = "source",
        directories: [String] = []
    ) -> UUID {
        let current = binding ?? self.binding()
        let proof = AgentABIPlatformProofRegistration(
            threadID: id,
            hostID: hostID,
            binding: current,
            sourceIdentity: sourceIdentity,
            processIDs: [42],
            validatedDirectories: directories
        )!
        let proofHandle = runtime.registerPlatformProcessProof(proof)!.proofHandle
        let registration = AgentABIPlatformBindingRegistration(
            threadID: id,
            hostID: hostID,
            binding: current,
            sourceIdentity: sourceIdentity,
            validatedDirectories: directories,
            proofHandle: proofHandle
        )!
        return runtime.registerPlatformBinding(registration)!.bindingToken
    }

    func testAgentCommandUsesIndependentVersionAndCanonicalBoundedEncoding() throws {
        let command = AgentABICommand(kind: .bind, threadID: thread(), bindingToken: UUID())
        let encoded = try command.encoded()
        XCTAssertEqual(try AgentABICommand.decode(encoded), command)
        XCTAssertTrue(encoded.count < AgentABICommand.maximumPayloadBytes)
        XCTAssertEqual(tesseraAgentABIVersion(), 1)
        XCTAssertEqual(tesseraAgentABIMaxPayloadBytes(), 1_048_576)
        XCTAssertEqual(tesseraCoreABIVersion(), 4, "agent ABI must not repurpose the independently versioned core ABI")
    }

    func testThreadEventCarriesSharedToolGroupsWithoutDuplicatingBodies() throws {
        let messages = [
            AgentMessage(recordID: "m1", role: .assistant, displayTime: nil,
                         blocks: [.text("plan"), .toolCall(name: "Bash", preview: "pwd")]),
            AgentMessage(recordID: "m2", role: .tool, displayTime: nil,
                         blocks: [.toolResult(preview: "unique-result-body", truncated: false)]),
        ]
        let snapshot = AgentThreadSnapshot(
            summary: AgentThreadSummary(id: thread(), providerName: "Claude",
                availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true)),
            messages: messages, cursor: nil, hasMore: false, binding: binding()
        )
        XCTAssertNil(snapshot.ingestionWindow, "Non-ingestion fixtures carry no window ACK state")
        let event = AgentABIEvent(kind: .threadSnapshot, generation: 1, thread: snapshot)
        let encoded = try event.encoded()
        XCTAssertEqual(try JSONDecoder().decode(AgentABIEvent.self, from: encoded), event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let runs = try XCTUnwrap(json["toolRuns"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0]["id"] as? String, "m1#1")
        XCTAssertEqual(runs[0]["entryIDs"] as? [String], ["m1#1", "m2#0"])
        XCTAssertEqual(runs[0]["summaryTitle"] as? String, "1 tool call")
        XCTAssertEqual(runs[0]["latestSummary"] as? String, "latest: Bash · pwd")
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self).components(separatedBy: "unique-result-body").count, 2)
    }

    func testOversizedActionPlanPreservesPendingMessageAndLeaseDuringWindowing() throws {
        let outgoing = AgentOutgoingMessage(id: UUID(), text: "new pending message", status: .queueing)
        let messages = (0..<40).map { AgentMessage(recordID: "large-\($0)", role: .assistant,
            displayTime: nil, blocks: [.text(String(repeating: "x", count: 32_768))]) }
        let snapshot = AgentThreadSnapshot(summary: .init(id: thread(), providerName: "Claude",
            availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)),
            messages: messages, cursor: nil, hasMore: false, binding: binding(), outgoingMessages: [outgoing])
        XCTAssertNil(snapshot.ingestionWindow)
        let lease = AgentActionLease(threadID: thread(), token: outgoing.id, binding: binding(), action: .queue)
        let event = AgentABIEvent(kind: .actionPlan, generation: 1, thread: snapshot, lease: lease)
        XCTAssertThrowsError(try event.encoded())
        let bounded = event.boundedForABI()
        XCTAssertLessThanOrEqual(try bounded.encoded().count, AgentABICommand.maximumPayloadBytes)
        XCTAssertEqual(bounded.thread?.outgoingMessages, [outgoing])
        XCTAssertEqual(bounded.lease, lease)
    }

    func testIntegrationCommandsHaveAnIndependentV2NamespaceAndPreserveMissingSnapshots() throws {
        XCTAssertEqual(tesseraAgentIntegrationABIVersion(), 2)
        XCTAssertEqual(tesseraAgentIntegrationABIMaxConfigBytes(), 1_048_576)
        XCTAssertEqual(tesseraAgentABIVersion(), 1, "integration commands must not repurpose Agent runtime v1")

        let emptyKimi = try RemoteAgentLifecycleIntegrationInstaller.mergeKimiConfig(existing: "")
        let missingKimi = try RemoteAgentLifecycleIntegrationInstaller.mergeKimiConfig(existing: nil)
        XCTAssertEqual(emptyKimi, missingKimi)
        XCTAssertTrue(RemoteAgentLifecycleIntegrationInstaller.makeStatusCommand(requireNativeHost: true).contains("TESSERA_AGENT_INTEGRATION_STATUS"))
        XCTAssertTrue(RemoteAgentLifecycleIntegrationInstaller.makeStatusCommand(requireNativeHost: true).contains("tessera-agent-host"))
        let processIDs = Array("[42,43]".utf8)
        let shellStatusCount = processIDs.withUnsafeBytes { bytes in
            tesseraAgentIntegrationShellStatusCommand(
                processIDsBytes: bytes.bindMemory(to: UInt8.self).baseAddress,
                processIDsCount: bytes.count,
                outputBytes: nil,
                outputCapacity: 0
            )
        }
        XCTAssertGreaterThan(shellStatusCount, 0)
        XCTAssertGreaterThan(tesseraAgentIntegrationApplyCurrentShellCommand(outputBytes: nil, outputCapacity: 0), 0)
        XCTAssertGreaterThan(tesseraAgentIntegrationPersistApplyCurrentShellCommand(outputBytes: nil, outputCapacity: 0), 0)
    }

    func testIntegrationDecisionABIUsesSharedReducerAndFreshActionReconciliation() throws {
        let request = #"{"observation":{"installation":"missing","foreground":"shell","shellIntegrationActive":false,"agentIntegrationActive":false},"requestedAction":"installOnly"}"#
        let bytes = Array(request.utf8)
        let required = bytes.withUnsafeBytes { input in
            tesseraAgentIntegrationResolve(
                requestBytes: input.bindMemory(to: UInt8.self).baseAddress,
                requestCount: bytes.count,
                outputBytes: nil,
                outputCapacity: 0
            )
        }
        XCTAssertGreaterThan(required, 0)
        var output = [UInt8](repeating: 0, count: Int(required))
        let outputCapacity = output.count
        let written = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                tesseraAgentIntegrationResolve(
                    requestBytes: input.bindMemory(to: UInt8.self).baseAddress,
                    requestCount: bytes.count,
                    outputBytes: destination.bindMemory(to: UInt8.self).baseAddress,
                    outputCapacity: outputCapacity
                )
            }
        }
        XCTAssertEqual(written, required)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output)) as? [String: Any])
        let decision = try XCTUnwrap(json["decision"] as? [String: Any])
        XCTAssertEqual(decision["kind"] as? String, "notInstalled")
        XCTAssertEqual(decision["primaryAction"] as? String, "installAndApply")
        XCTAssertEqual(json["showsWarning"] as? Bool, true)
        XCTAssertEqual(json["effectiveAction"] as? String, "installAndApply")
    }

    func testIntegrationRawParsersAndScopedDiscoveryStayInCore() throws {
        func invoke(
            _ input: String,
            _ call: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int) -> Int32
        ) -> String? {
            let bytes = Array(input.utf8)
            let required = bytes.withUnsafeBytes { raw in
                call(raw.bindMemory(to: UInt8.self).baseAddress, bytes.count, nil, 0)
            }
            guard required > 0 else { return nil }
            var output = [UInt8](repeating: 0, count: Int(required))
            let outputCapacity = output.count
            let written = bytes.withUnsafeBytes { raw in output.withUnsafeMutableBytes { destination in
                call(raw.bindMemory(to: UInt8.self).baseAddress, bytes.count, destination.bindMemory(to: UInt8.self).baseAddress, outputCapacity)
            } }
            return written == required ? String(bytes: output, encoding: .utf8) : nil
        }

        let status = try XCTUnwrap(invoke("noise\nTESSERA_AGENT_INTEGRATION_STATUS outdated:10001\n", tesseraAgentIntegrationParseStatus))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])?["kind"] as? String, "outdated")
        // An implausible manifest version is never a version fact, but the
        // installation is still this app's to repair.
        let implausible = try XCTUnwrap(invoke("TESSERA_AGENT_INTEGRATION_STATUS outdated:99999\n", tesseraAgentIntegrationParseStatus))
        let implausibleJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(implausible.utf8)) as? [String: Any])
        XCTAssertEqual(implausibleJSON["kind"] as? String, "outdated")
        XCTAssertNil(implausibleJSON["version"])
        let unsupported = try XCTUnwrap(invoke("TESSERA_AGENT_INTEGRATION_STATUS unsupported:12\n", tesseraAgentIntegrationParseStatus))
        let unsupportedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(unsupported.utf8)) as? [String: Any])
        XCTAssertEqual(unsupportedJSON["kind"] as? String, "requiresAppUpdate")
        XCTAssertEqual(unsupportedJSON["version"] as? Int, 12)
        let newer = try XCTUnwrap(invoke("TESSERA_AGENT_INTEGRATION_STATUS newer:12\n", tesseraAgentIntegrationParseStatus))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(newer.utf8)) as? [String: Any])?["kind"] as? String, "current")
        let refused = try XCTUnwrap(invoke("TESSERA_AGENT_INTEGRATION_NEWER_INSTALLED 12\n", tesseraAgentIntegrationClassifyInstallOutput))
        let refusedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(refused.utf8)) as? [String: Any])
        XCTAssertEqual(refusedJSON["kind"] as? String, "failed")
        XCTAssertEqual(refusedJSON["reason"] as? String, "newerInstalled")

        let lifecycle = try XCTUnwrap(invoke(
            #"{"version":9,"provider":"kimi","event":"Stop","state":"idle","reason":"turn-stopped","timestampNs":"184467440","sessionId":"session-1","agentPid":42,"transcriptRef":"session_abc"}"#,
            tesseraAgentIntegrationParseLifecycleEvent
        ))
        let lifecycleJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lifecycle.utf8)) as? [String: Any])
        XCTAssertEqual((lifecycleJSON["providerID"] as? [String: Any])?["rawValue"] as? String, "kimi")
        XCTAssertEqual(lifecycleJSON["event"] as? String, "Stop")

        let scope = #"{"kind":"rootProcess","processID":42}"#
        let discovery = #"TESSERA_AGENT_PROCESS_DISCOVERY {"v":1,"kind":"processDiscovery","processes":[{"pid":42,"ppid":1,"executable":"ash","foreground":true}]}"# + "\n"
        let scopeBytes = Array(scope.utf8)
        let outputBytes = Array(discovery.utf8)
        let required = scopeBytes.withUnsafeBytes { scopeRaw in outputBytes.withUnsafeBytes { outputRaw in
            tesseraAgentIntegrationParseProcessDiscovery(
                scopeBytes: scopeRaw.bindMemory(to: UInt8.self).baseAddress, scopeCount: scopeBytes.count,
                outputInputBytes: outputRaw.bindMemory(to: UInt8.self).baseAddress, outputInputCount: outputBytes.count,
                outputBytes: nil, outputCapacity: 0
            )
        } }
        XCTAssertGreaterThan(required, 0)
        var parsed = [UInt8](repeating: 0, count: Int(required))
        let parsedCapacity = parsed.count
        let written = scopeBytes.withUnsafeBytes { scopeRaw in outputBytes.withUnsafeBytes { outputRaw in parsed.withUnsafeMutableBytes { destination in
            tesseraAgentIntegrationParseProcessDiscovery(
                scopeBytes: scopeRaw.bindMemory(to: UInt8.self).baseAddress, scopeCount: scopeBytes.count,
                outputInputBytes: outputRaw.bindMemory(to: UInt8.self).baseAddress, outputInputCount: outputBytes.count,
                outputBytes: destination.bindMemory(to: UInt8.self).baseAddress, outputCapacity: parsedCapacity
            )
        } } }
        XCTAssertEqual(written, required)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(parsed)) as? [String: Any])?["foreground"] as? String, "unsupportedShell")

        let invalidScope = Array(#"{"kind":"rootProcess","processID":1}"#.utf8)
        XCTAssertEqual(invalidScope.withUnsafeBytes { raw in
            tesseraAgentIntegrationProcessDiscoveryCommand(
                scopeBytes: raw.bindMemory(to: UInt8.self).baseAddress, scopeCount: invalidScope.count,
                outputBytes: nil, outputCapacity: 0
            )
        }, -1)
    }

    func testIntegrationInstallCommandFitsThePublishedAndroidCeilingAtMaximumConfigSize() throws {
        let paddingCount = 1_048_500
        let apostrophes = String(repeating: "'", count: paddingCount)
        let codex = #"{"padding":""# + apostrophes + #""}"#
        let claude = #"{"padding":""# + apostrophes + #""}"#
        let kimi = "# " + apostrophes + "\n"
        XCTAssertLessThanOrEqual(codex.utf8.count, 1_048_576)
        XCTAssertLessThanOrEqual(claude.utf8.count, 1_048_576)
        XCTAssertLessThanOrEqual(kimi.utf8.count, 1_048_576)

        let mergedCodex = try RemoteAgentLifecycleIntegrationInstaller.mergeCodexHooks(existing: codex)
        let mergedClaude = try RemoteAgentLifecycleIntegrationInstaller.mergeClaudeSettings(existing: claude)
        let mergedKimi = try RemoteAgentLifecycleIntegrationInstaller.mergeKimiConfig(existing: kimi)
        let command = RemoteAgentLifecycleIntegrationInstaller.makeInstallCommand(
            mergedCodexHooks: mergedCodex,
            expectedCodexHooks: codex,
            mergedClaudeSettings: mergedClaude,
            expectedClaudeSettings: claude,
            mergedKimiConfig: mergedKimi,
            expectedKimiConfig: kimi
        )
        XCTAssertGreaterThan(command.utf8.count, 8_388_608)
        XCTAssertLessThanOrEqual(command.utf8.count, 33_554_432)
    }

    /// Android runs the shared answer planner through the ABI: one fresh
    /// capture in, the observation and the next step out.
    func testPromptObservationPlansTheNextAnswerStep() async throws {
        let answered = expectation(description: "two planned steps")
        answered.expectedFulfillmentCount = 2
        let capture = AgentABIEventCapture(expectation: answered)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let menu = "Would you like to run the following command?\n› 1. Yes (y)\n  2. No (n)"
        let request = AgentPromptObservationRequest(providerID: .codex, visibleText: menu, currentCursorLine: "› 1. Yes (y)")!
        let signature = try XCTUnwrap(AgentPromptGrammar.observe(request)).signature
        runtime.submit(try AgentABICommand(kind: .promptObservation, promptObservation: request,
            promptAnswerPlan: .init(goal: .option("2"), expectedSignature: signature, anchor: nil, history: []),
            promptRequestID: "request-1").encoded())
        try await waitForEvents(capture, 1)
        XCTAssertEqual(capture.events.first?.promptRequestID, "request-1", "a reply names the request it answers")
        let first = try XCTUnwrap(capture.events.first?.promptAnswerPlan)
        XCTAssertEqual(first.step.action, .send)
        XCTAssertEqual(first.step.bytes, "n", "the option id selects the provider's own key")
        XCTAssertEqual(first.step.phase, .select)
        let gone = AgentPromptObservationRequest(providerID: .codex, visibleText: "› Ask Codex to do anything", currentCursorLine: "› Ask Codex to do anything")!
        runtime.submit(try AgentABICommand(kind: .promptObservation, promptObservation: gone,
            promptAnswerPlan: .init(goal: .option("2"), expectedSignature: signature, anchor: first.anchor, history: [.select])).encoded())
        await fulfillment(of: [answered], timeout: 2)
        XCTAssertNil(capture.events.last?.promptRequestID)
        XCTAssertNil(capture.events.last?.promptObservation)
        XCTAssertEqual(capture.events.last?.promptAnswerPlan?.step.action, .done)

        let invalid = AgentABICommand(kind: .promptObservation, promptObservation: request,
            promptAnswerPlan: .init(goal: .option("1"), expectedSignature: "", anchor: nil, history: []))
        XCTAssertThrowsError(try invalid.encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .promptObservation, promptObservation: request, promptRequestID: "").encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .promptObservation, promptObservation: request,
                                                 promptRequestID: String(repeating: "r", count: 65)).encoded())
        let plain = AgentABICommand(kind: .promptObservation, promptObservation: request)
        XCTAssertNil(try AgentABICommand.decode(plain.encoded()).promptAnswerPlan)
    }

    func testLivePromptObservationTakesExactlyOneFence() throws {
        let request = AgentPromptObservationRequest(providerID: .claude, visibleText: "prompt", currentCursorLine: nil)!
        let token = UUID()
        func command(generation: UInt64?, sequence: UInt64?) -> AgentABICommand {
            AgentABICommand(kind: .livePromptObservation, threadID: thread(), bindingToken: token, promptObservation: request,
                            observedLifecycleSequence: sequence, observedGeneration: generation)
        }
        XCTAssertNoThrow(try command(generation: 3, sequence: nil).encoded())
        let sequenced = try AgentABICommand.decode(command(generation: nil, sequence: 7).encoded())
        XCTAssertEqual(sequenced.observedLifecycleSequence, 7)
        XCTAssertThrowsError(try command(generation: 3, sequence: 7).encoded())
        XCTAssertThrowsError(try command(generation: nil, sequence: nil).encoded())

        let displayed = try AgentABICommand.decode(AgentABICommand(kind: .livePromptObservation, threadID: thread(), bindingToken: token,
            promptObservation: request, observedLifecycleSequence: 7, onDisplay: true).encoded())
        XCTAssertEqual(displayed.onDisplay, true)
        XCTAssertNil(try AgentABICommand.decode(command(generation: 3, sequence: nil).encoded()).onDisplay)
        XCTAssertThrowsError(try AgentABICommand(kind: .promptObservation, promptObservation: request, onDisplay: true).encoded(),
                             "only a live observation comes from a conversation on screen")
    }

    func testAgentCommandRejectsMissingRequiredFields() {
        let malformed = Data(#"{"kind":"bind","v":1}"#.utf8)
        XCTAssertThrowsError(try AgentABICommand.decode(malformed)) {
            XCTAssertEqual($0 as? AgentABIError, .missingField)
        }
        let duplicateManifest = AgentProviderRegistry.builtIn.manifest(for: .claude)!
        let duplicateConfiguration = AgentABICommand(kind: .configure, manifests: [duplicateManifest, duplicateManifest])
        XCTAssertThrowsError(try duplicateConfiguration.encoded())
    }

    /// Android releases its one-action-in-flight gate only for a rejection
    /// naming `@action`; a bare lease refusal left "An action is already in
    /// progress" stuck.
    func testActionRefusedByTheLeaseNamesItsCommand() async throws {
        let expectation = expectation(description: "lease refusal")
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        // Never bound, so Core has no thread to lease.
        let send = AgentTextSendRequest(threadID: id, binding: binding(), text: "hello", queueWhenWorking: false)!
        runtime.submit(try AgentABICommand(kind: .action, threadID: id, bindingToken: token, action: .send, actionPayload: .init(text: send)).encoded())
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.commandRejected])
        XCTAssertEqual(capture.events.last?.code, "unavailable@action")
        runtime.destroy()
    }

    func testAgentActionPlansAndResultsUseTypedCorrelatedPayloads() throws {
        let id = thread()
        let currentBinding = binding()
        let send = AgentTextSendRequest(threadID: id, binding: currentBinding, text: "hello", queueWhenWorking: false)!
        let command = AgentABICommand(kind: .action, threadID: id, bindingToken: UUID(), action: .send, actionPayload: .init(text: send))
        XCTAssertEqual(try AgentABICommand.decode(command.encoded()), command)

        let lease = AgentActionLease(threadID: id, token: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!, binding: currentBinding, action: .send)
        let wrongOutcome = AgentActionResultOutcome(status: .cancelled, action: .interrupt)!
        XCTAssertThrowsError(try AgentABICommand(kind: .result, bindingToken: UUID(), lease: lease, resultOutcome: wrongOutcome).encoded())
        let verified = AgentActionResultOutcome(status: .verified, action: .send, verification: "terminal.accepted")!
        XCTAssertNoThrow(try AgentABICommand(kind: .result, bindingToken: UUID(), lease: lease, resultOutcome: verified).encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .result, bindingToken: UUID(), lease: lease, resultCode: "raw-terminal-output", resultOutcome: verified).encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .result, lease: lease, resultOutcome: verified).encoded(), "action results require the current binding token")
        XCTAssertNil(AgentActionResultOutcome(status: .verified, action: .send, verification: "terminal output must never cross the ABI"))
        // Android reports a send refused before its first byte as `notSent`.
        let notSent = AgentABICommand(kind: .result, bindingToken: UUID(), lease: lease,
            resultOutcome: AgentActionResultOutcome(status: .notSent, action: .send)!)
        XCTAssertEqual(try AgentABICommand.decode(notSent.encoded()), notSent)
        let wire = String(decoding: try notSent.encoded(), as: UTF8.self)
        XCTAssertTrue(wire.contains(#""status":"notSent""#), "the JSON spelling Android sends")
        let malformed = Data(wire.replacingOccurrences(of: #""action":"send""#, with: #""action":"interrupt""#).utf8)
        XCTAssertThrowsError(try AgentABICommand.decode(malformed), "only text actions can be notSent")
    }

    func testConfigureCannotUseManifestToEnableTierCSpawn() async throws {
        let expectation = expectation(description: "configure and rejected launch")
        expectation.expectedFulfillmentCount = 4
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let opencodeID = AgentThreadID(hostID: hostID, providerID: .opencode, providerSessionID: "provider-session")!
        let token = bindingToken(runtime, id: opencodeID, directories: ["~/project"])
        let spoofed = AgentProviderManifest(
            id: .opencode,
            displayName: "Spoofed OpenCode",
            processMatchers: [],
            lifecycle: .rpc,
            conversation: .sqliteQuery(adapterID: "untrusted"),
            actions: [.spawn]
        )
        runtime.submit(try AgentABICommand(kind: .configure, manifests: [spoofed]).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: opencodeID, bindingToken: token).encoded())
        let launch = AgentLaunchIntent(
            kind: .spawn(name: nil),
            liveSessionID: sessionID,
            providerID: .opencode,
            workingDirectory: AgentRemotePath("~/project")!,
            task: "unsafe spawn",
            placement: .newWindow(name: nil),
            isolation: .currentWorktree
        )!
        runtime.submit(try AgentABICommand(kind: .launch, threadID: opencodeID, bindingToken: token, launch: launch).encoded())

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.listSnapshot, .threadSnapshot, .listSnapshot, .commandRejected])
        XCTAssertEqual(capture.events.last?.code, AgentActionError.unavailable.rawValue)
        runtime.destroy()
    }

    /// The page identity a real remote projector reports is the transcript
    /// file's dev/inode/size/mtime — never the route identity the binding was
    /// registered under. Requiring the two to match rejected every page a
    /// device sent, with `abi_invalidField` surfacing as the only clue.
    func testProjectionFromARealProjectorIdentityIsApplied() async throws {
        let expectation = expectation(description: "bind then projection applied")
        expectation.expectedFulfillmentCount = 4
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id, sourceIdentity: "android:11111111-2222-3333-4444-555555555555:3:%3")
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        let record = AgentProjectionRecord(sequence: 1, recordID: "record", record: .object([
            "type": .string("assistant"), "text": .string("hello")
        ]))!
        let page = AgentProjectionPage(sourceIdentity: "1000004:8a3f2:12ab:17bd9c1", records: [record], cursor: "1", hasMore: false)!
        runtime.submit(try AgentABICommand(kind: .projection, threadID: id, bindingToken: token, projection: page).encoded())
        runtime.submit(try AgentABICommand(kind: .acknowledge, threadID: id, recordID: "record").encoded())

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot, .projectionApplied, .threadSnapshot])
        XCTAssertFalse(capture.events.contains { $0.code == "abi_invalidField" })
        runtime.destroy()
    }

    /// A host running two agents listed only the first. `bind` admits a thread
    /// to the centre but emitted no list, and a client patches existing rows
    /// from thread snapshots -- so the second agent, discovered after the last
    /// list, had no row to patch and stayed invisible. Each agent is announced
    /// by a lifecycle frame, which is what makes it a live row.
    func testASecondLiveAgentReachesTheList() async throws {
        let expectation = expectation(description: "two announced agents each reach the list")
        expectation.expectedFulfillmentCount = 8
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let first = thread()
        let second = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "second-session")!
        let firstBinding = binding()
        let secondBinding = AgentTerminalBinding(
            liveSessionID: sessionID,
            carrierGeneration: 1,
            incarnation: AgentIncarnationToken("incarnation-2")!,
            transport: .sshTmux,
            tmuxSession: "work",
            windowID: "@2",
            paneID: "%3",
            agentPID: 42,
            capabilities: [.observe, .send, .tmux]
        )
        let firstToken = bindingToken(runtime, id: first, binding: firstBinding)
        let secondToken = bindingToken(runtime, id: second, binding: secondBinding, sourceIdentity: "source-2")

        runtime.submit(try AgentABICommand(kind: .bind, threadID: first, bindingToken: firstToken).encoded())
        runtime.submit(try AgentABICommand(
            kind: .lifecycle, threadID: first, bindingToken: firstToken,
            lifecycle: AgentLifecycleEnvelope(
                version: 9, providerID: .claude, event: .sessionStart, status: .working,
                providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl"
            )!
        ).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: second, bindingToken: secondToken).encoded())
        runtime.submit(try AgentABICommand(
            kind: .lifecycle, threadID: second, bindingToken: secondToken,
            lifecycle: AgentLifecycleEnvelope(
                version: 9, providerID: .claude, event: .sessionStart, status: .working,
                providerSessionID: "second-session", agentPID: 42, transcriptRef: "b3BhcXVl"
            )!
        ).encoded())
        await fulfillment(of: [expectation], timeout: 2)

        let lists = capture.events.filter { $0.kind == .listSnapshot }
        XCTAssertEqual(lists.count, 4, "each bind and each accepted lifecycle must re-emit the list")
        XCTAssertEqual(
            Set(try XCTUnwrap(lists.last?.list?.threads.map(\.id))), Set([first, second]),
            "the list after the second agent is announced must contain both"
        )
        runtime.destroy()
    }

    /// Tier-C inventory binds every *stored* session so it can authorise
    /// transcript reads, and those sessions never announce a lifecycle frame.
    /// Listing them put months-old opencode conversations, and dormant Claude
    /// sessions, in a list that is supposed to mean "open right now".
    func testABoundButUnannouncedThreadIsNotListed() async throws {
        let expectation = expectation(description: "bind emits its snapshots")
        expectation.expectedFulfillmentCount = 2
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        await fulfillment(of: [expectation], timeout: 2)

        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot])
        XCTAssertEqual(
            capture.events.last?.list?.threads.count, 0,
            "a thread nothing has announced is readable, but it is not an open agent"
        )
        XCTAssertNotNil(
            capture.events.first?.thread,
            "it must still be a real thread the client can select and read"
        )
        runtime.destroy()
    }

    /// Closing the pane must retract the row: `unbind` clears the route
    /// identity, so the agent stops being "open right now" even though its
    /// transcript stays readable.
    func testUnbindingALiveAgentRemovesItFromTheList() async throws {
        let expectation = expectation(description: "bind, announce, then unbind")
        expectation.expectedFulfillmentCount = 6
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        runtime.submit(try AgentABICommand(
            kind: .lifecycle, threadID: id, bindingToken: token,
            lifecycle: AgentLifecycleEnvelope(
                version: 9, providerID: .claude, event: .sessionStart, status: .working,
                providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl"
            )!
        ).encoded())
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id).encoded())
        await fulfillment(of: [expectation], timeout: 2)

        let lists = capture.events.filter { $0.kind == .listSnapshot }
        XCTAssertEqual(lists.count, 3)
        XCTAssertEqual(lists[1].list?.threads.count, 1, "announced agents are listed")
        XCTAssertEqual(lists[2].list?.threads.count, 0, "a closed pane leaves the list")
        XCTAssertEqual(capture.retirementEvents.flatMap { $0.retirements ?? [] },
                       [.init(threadID: id, bindingToken: token, reason: .unbound)])
        runtime.destroy()
    }

    func testRepeatedAcknowledgementAndCapacityCommandsEmitNoThreadSnapshot() async throws {
        let expectation = expectation(description: "five callbacks")
        expectation.expectedFulfillmentCount = 5
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        let record = AgentProjectionRecord(sequence: 1, recordID: "record", record: .object([
            "type": .string("assistant"), "text": .string("hello")
        ]))!
        let page = AgentProjectionPage(sourceIdentity: "source", records: [record], cursor: "1", hasMore: false)!
        runtime.submit(try AgentABICommand(kind: .projection, threadID: id, bindingToken: token, projection: page).encoded())
        runtime.submit(try AgentABICommand(kind: .acknowledge, threadID: id, recordID: "record").encoded())
        runtime.submit(try AgentABICommand(kind: .acknowledge, threadID: id, recordID: "record").encoded())
        runtime.submit(try AgentABICommand(kind: .hostCapacity, hostWindowSegments: [id.hostID.uuidString: 64]).encoded())
        runtime.submit(try AgentABICommand(kind: .configure, physicalMemoryBytes: 8 << 30, lowRAMDevice: false).encoded())

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot, .projectionApplied, .threadSnapshot, .listSnapshot])
        XCTAssertTrue(capture.events.compactMap(\.thread).allSatisfy { $0.turns.isEmpty }, "the ABI never carries turns")
        XCTAssertEqual(capture.events[2].toolRuns, [])
        runtime.destroy()
    }

    func testCapacityAndMemoryFieldsAreScopedToTheirCommands() throws {
        let host = UUID().uuidString
        let valid = AgentABICommand(kind: .hostCapacity, hostWindowSegments: [host: 64])
        XCTAssertEqual(try AgentABICommand.decode(valid.encoded()).hostWindowSegments, [host: 64])
        let scoped = AgentABICommand(kind: .hostCapacity, threadID: thread(), hostWindowSegments: [hostID.uuidString: 64])
        XCTAssertEqual(try AgentABICommand.decode(scoped.encoded()).threadID, thread())
        XCTAssertEqual(try AgentABICommand.decode(AgentABICommand(kind: .configure, physicalMemoryBytes: 4 << 30).encoded()).physicalMemoryBytes, 4 << 30)
        for invalid in [
            AgentABICommand(kind: .hostCapacity),
            AgentABICommand(kind: .hostCapacity, hostWindowSegments: ["not-a-uuid": 8]),
            AgentABICommand(kind: .hostCapacity, hostWindowSegments: [host: 0]),
            AgentABICommand(kind: .hostCapacity, hostWindowSegments: [host: 5_000]),
            // Thread-scoped reports name exactly the thread's own host.
            AgentABICommand(kind: .hostCapacity, threadID: thread(), hostWindowSegments: [host: 64]),
            AgentABICommand(kind: .hostCapacity, threadID: thread(), hostWindowSegments: [hostID.uuidString: 64, host: 64]),
            AgentABICommand(kind: .configure, physicalMemoryBytes: 0),
            AgentABICommand(kind: .configure, metadata: [], lowRAMDevice: true),
            AgentABICommand(kind: .memoryWarning, physicalMemoryBytes: 1 << 30),
            AgentABICommand(kind: .memoryWarning, hostWindowSegments: [host: 8]),
        ] {
            XCTAssertThrowsError(try invalid.encoded(), "\(invalid.kind)")
        }
    }

    func testAgentRuntimeSerializesBindProjectionAndAcknowledgementSnapshots() async throws {
        let expectation = expectation(description: "four callbacks")
        expectation.expectedFulfillmentCount = 4
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        let record = AgentProjectionRecord(sequence: 1, recordID: "record", record: .object([
            "type": .string("assistant"), "text": .string("hello")
        ]))!
        let page = AgentProjectionPage(sourceIdentity: "source", records: [record], cursor: "1", hasMore: false)!
        runtime.submit(try AgentABICommand(kind: .projection, threadID: id, bindingToken: token, projection: page).encoded())
        runtime.submit(try AgentABICommand(kind: .acknowledge, threadID: id, recordID: "record").encoded())

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot, .projectionApplied, .threadSnapshot])
        XCTAssertEqual(capture.events.map(\.generation), [1, 2, 3, 4])
        XCTAssertEqual(capture.events.last?.thread?.summary.attention, .some(.none))
        runtime.destroy()
    }

    func testAgentCHandleRejectsUseAfterDestroy() throws {
        let callback: TesseraAgentABIEventCallback = { _, _, _ in }
        let handle = tesseraAgentRuntimeCreate(callback: callback, context: nil)
        let command = try AgentABICommand(kind: .memoryWarning).encoded()
        XCTAssertEqual(agentSend(command, handle: handle), 0)
        tesseraAgentRuntimeDestroy(handle: handle)
        tesseraAgentRuntimeDestroy(handle: handle)
        XCTAssertEqual(agentSend(command, handle: handle), -2)
    }

    func testCPlatformRegistrationMintsOpaqueTokenOutsideRawCommands() throws {
        let callback: TesseraAgentABIEventCallback = { _, _, _ in }
        let handle = tesseraAgentRuntimeCreate(callback: callback, context: nil)
        defer { tesseraAgentRuntimeDestroy(handle: handle) }
        let proof = AgentABIPlatformProofRegistration(
            threadID: thread(),
            hostID: hostID,
            binding: binding(),
            sourceIdentity: "source",
            processIDs: [42],
            validatedDirectories: ["~/project"]
        )!
        let proofPayload = try JSONEncoder().encode(proof)
        var output = [UInt8](repeating: 0, count: 512)
        var outputCount = 0
        let proofStatus = proofPayload.withUnsafeBytes { raw in
            output.withUnsafeMutableBufferPointer { buffer in
                tesseraAgentRuntimeRegisterPlatformProof(
                    handle: handle,
                    bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count,
                    responseBytes: buffer.baseAddress,
                    responseCapacity: buffer.count,
                    responseCount: &outputCount
                )
            }
        }
        XCTAssertEqual(proofStatus, 0)
        let proofHandle = try JSONDecoder().decode(AgentABIPlatformProofHandle.self, from: Data(output.prefix(outputCount)))
        let registration = AgentABIPlatformBindingRegistration(
            threadID: thread(), hostID: hostID, binding: binding(), sourceIdentity: "source",
            validatedDirectories: ["~/project"], proofHandle: proofHandle.proofHandle
        )!
        let payload = try JSONEncoder().encode(registration)
        outputCount = 0
        let status = payload.withUnsafeBytes { raw in
            output.withUnsafeMutableBufferPointer { buffer in
                tesseraAgentRuntimeRegisterPlatformBinding(handle: handle, bytes: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count, responseBytes: buffer.baseAddress, responseCapacity: buffer.count, responseCount: &outputCount)
            }
        }
        XCTAssertEqual(status, 0)
        let response = try JSONDecoder().decode(
            AgentABIPlatformBindingToken.self,
            from: Data(output.prefix(outputCount))
        )
        XCTAssertNoThrow(try AgentABICommand(kind: .bind, threadID: thread(), bindingToken: response.bindingToken).encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .bind, threadID: thread(), binding: binding()).encoded())
    }

    func testPlatformProofIsSingleUseAndCannotAuthorizeDifferentBinding() {
        let runtime = AgentABIRuntime { _ in }
        let proof = AgentABIPlatformProofRegistration(
            threadID: thread(), hostID: hostID, binding: binding(), sourceIdentity: "source",
            processIDs: [42], validatedDirectories: ["~/project"]
        )!
        let handle = runtime.registerPlatformProcessProof(proof)!.proofHandle
        let changed = AgentABIPlatformBindingRegistration(
            threadID: thread(), hostID: hostID, binding: binding(generation: 2), sourceIdentity: "source",
            validatedDirectories: ["~/project"], proofHandle: handle
        )!
        XCTAssertNil(runtime.registerPlatformBinding(changed))
        let original = AgentABIPlatformBindingRegistration(
            threadID: thread(), hostID: hostID, binding: binding(), sourceIdentity: "source",
            validatedDirectories: ["~/project"], proofHandle: handle
        )!
        XCTAssertNil(runtime.registerPlatformBinding(original), "a rejected exchange consumes the proof handle")
    }

    func testAgentLifecycleRejectsRawProofWithoutMutatingTheSnapshot() async throws {
        let expectation = expectation(description: "bind only")
        // `bind` emits its thread snapshot and then re-emits the list, so the
        // count must be 2. Leaving it at the default 1 made the second event
        // an "API violation - multiple calls to fulfill" abort that took the
        // whole test binary down rather than failing this case.
        expectation.expectedFulfillmentCount = 2
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        let proof = AgentLifecycleBindingProof(hostID: hostID, binding: binding(generation: 2), sourceIdentity: "source", processIDs: [42])
        let lifecycle = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart, status: .working, providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl")!
        XCTAssertThrowsError(try AgentABICommand(kind: .lifecycle, bindingToken: token, lifecycle: lifecycle, lifecycleProof: proof).encoded())

        await fulfillment(of: [expectation], timeout: 2)
        // Only the bind's own events: a raw proof never reaches the runtime,
        // so there is neither a `lifecycleAccepted` nor a `commandRejected`.
        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot])
        runtime.destroy()
    }

    func testLifecycleCannotReidentifyARegisteredBindingToAnotherThread() async throws {
        let expectation = expectation(description: "bind then reject mismatched lifecycle")
        expectation.expectedFulfillmentCount = 3
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        let other = AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .sessionStart, status: .working, providerSessionID: "other-session", agentPID: 42, transcriptRef: "b3BhcXVl")!
        runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: id, bindingToken: token, lifecycle: other).encoded())
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot, .commandRejected])
        runtime.destroy()
    }

    func testAgentRuntimeAppliesFilterSearchAndMemoryWarningCommands() async throws {
        let expectation = expectation(description: "seven callbacks")
        expectation.expectedFulfillmentCount = 7
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let token = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        let record = AgentProjectionRecord(sequence: 1, recordID: "needle", record: .object([
            "type": .string("assistant"), "text": .string("find this exact phrase")
        ]))!
        let page = AgentProjectionPage(sourceIdentity: "source", records: [record], cursor: "1", hasMore: false)!
        runtime.submit(try AgentABICommand(kind: .projection, threadID: id, bindingToken: token, projection: page).encoded())
        runtime.submit(try AgentABICommand(kind: .filter, grouping: .host, listFilter: .init(providerIDs: [.claude], query: "Untitled")).encoded())
        runtime.submit(try AgentABICommand(kind: .search, query: "exact phrase").encoded())
        runtime.submit(try AgentABICommand(kind: .memoryWarning).encoded())
        runtime.submit(try AgentABICommand(kind: .search, query: "exact phrase").encoded())

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events[4].search?.results.first?.recordID, "needle")
        XCTAssertTrue(capture.events[6].search?.results.isEmpty == true)
        XCTAssertEqual(capture.events.map(\.generation), [1, 2, 3, 4, 5, 6, 7])
        runtime.destroy()
    }

    func testRemoteSearchSnapshotIsAcceptedAndBounded() async throws {
        let expectation = expectation(description: "remote search callback")
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let result = AgentSearchResult(threadID: thread(), recordID: "record", excerpt: String(repeating: "x", count: 2_000))
        let snapshot = AgentSearchSnapshot(results: [result])
        runtime.submit(try AgentABICommand(kind: .search, searchSnapshot: snapshot).encoded())
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.first?.kind, .searchSnapshot)
        XCTAssertEqual(capture.events.first?.search?.results.first?.excerpt.utf8.count, AgentSearchResult.maximumExcerptBytes)
        runtime.destroy()
    }

    func testReplacedAndUnboundTokensCannotRebindStaleRoute() async throws {
        let expectation = expectation(description: "old rejected, current bound, unbound rejected")
        expectation.expectedFulfillmentCount = 6
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        let stale = bindingToken(runtime, id: id, binding: binding(generation: 1))
        let current = bindingToken(runtime, id: id, binding: binding(generation: 2))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: stale).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: current).encoded())
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: current).encoded())
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(
            capture.events.map(\.kind),
            [.commandRejected, .threadSnapshot, .listSnapshot, .threadSnapshot, .listSnapshot, .commandRejected]
        )
        runtime.destroy()
    }

    func testIdenticalFreshProofPreservesQueuedCommandsButChangedAuthorityRotates() async throws {
        let expectation = expectation(description: "both identical-authority binds accepted")
        expectation.expectedFulfillmentCount = 4
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread()
        let first = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: first).encoded())
        let refreshed = bindingToken(runtime, id: id)
        XCTAssertEqual(first, refreshed)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: refreshed).encoded())
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertFalse(capture.events.contains { $0.kind == .commandRejected })
        let changed = runtime.registerPlatformBinding(threadID: id, hostID: hostID, binding: binding(), sourceIdentity: "different-source", processIDs: [42])
        XCTAssertNotNil(changed)
        XCTAssertNotEqual(first, changed)
    }

    func testInventoryObservationCannotRevokeActionablePlatformToken() async throws {
        let accepted = expectation(description: "live token still authorizes bind")
        accepted.expectedFulfillmentCount = 2
        let capture = AgentABIEventCapture(expectation: accepted)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread(), live = bindingToken(runtime, id: thread())
        let observation = AgentTerminalBinding(liveSessionID: binding().liveSessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("inventory-host")!, transport: .ssh, capabilities: [.observe])
        let token = runtime.registerPlatformBinding(threadID: id, hostID: hostID, binding: observation,
            sourceIdentity: "inventory-host", processIDs: [], mode: .inventoryObservation)
        XCTAssertNil(token, "host inventory cannot retire or inherit the actionable token")
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: live).encoded())
        await fulfillment(of: [accepted], timeout: 2)
        XCTAssertFalse(capture.events.contains { $0.kind == .commandRejected })
    }

    func testObserveOnlyRouteFallbackStillRevokesActionablePlatformToken() async throws {
        let completed = expectation(description: "old proof rejected and route fallback accepted")
        completed.expectedFulfillmentCount = 3
        let capture = AgentABIEventCapture(expectation: completed)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread(), live = bindingToken(runtime, id: thread())
        let observation = AgentTerminalBinding(liveSessionID: binding().liveSessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("unproved-route")!, transport: .ssh, capabilities: [.observe])
        let fallback = try XCTUnwrap(runtime.registerPlatformBinding(threadID: id, hostID: hostID,
            binding: observation, sourceIdentity: "unproved-route", processIDs: [], mode: .observeOnly))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: live).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: fallback).encoded())
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.commandRejected, .threadSnapshot, .listSnapshot])
    }

    func testExplicitUnbindAllowsInventoryObservationAgain() async throws {
        let retired = expectation(description: "live route explicitly retired")
        retired.expectedFulfillmentCount = 2
        let capture = AgentABIEventCapture(expectation: retired)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread(), live = bindingToken(runtime, id: thread())
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id).encoded())
        await fulfillment(of: [retired], timeout: 2)
        let observation = AgentTerminalBinding(liveSessionID: binding().liveSessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("inventory-after-unbind")!, transport: .ssh, capabilities: [.observe])
        let token = runtime.registerPlatformBinding(threadID: id, hostID: hostID, binding: observation,
            sourceIdentity: "inventory-after-unbind", processIDs: [], mode: .inventoryObservation)
        XCTAssertNotNil(token)
        XCTAssertNotEqual(token, live)
    }

    /// `/clear` hands the pane to the next conversation, and the one it
    /// replaced leaves Core. Its actionable token left with it: kept, it
    /// refused the session's next inventory observation, which aborted the
    /// whole Android inventory pass.
    func testReplacedConversationReleasesItsTokenForInventory() async throws {
        let applied = expectation(description: "two binds and two accepted frames")
        applied.expectedFulfillmentCount = 8
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let old = thread(), new = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "after-clear")!
        let oldToken = bindingToken(runtime, id: old), newToken = bindingToken(runtime, id: new)
        for (id, token, event) in [(old, oldToken, AgentLifecycleEventKind.stop), (new, newToken, .sessionStart)] {
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
            runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: id, bindingToken: token,
                lifecycle: AgentLifecycleEnvelope(version: 9, providerID: .claude, event: event,
                    status: event == .stop ? .finished : .idle, providerSessionID: id.providerSessionID,
                    agentPID: 42, transcriptRef: "b3BhcXVl")!).encoded())
        }
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertFalse(capture.events.contains { $0.kind == .commandRejected })
        XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads.map(\.id), [new])
        XCTAssertEqual(capture.retirementEvents.flatMap { $0.retirements ?? [] },
                       [.init(threadID: old, bindingToken: oldToken, successor: new, reason: .replaced)])
        let observation = AgentTerminalBinding(liveSessionID: binding().liveSessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("inventory-after-clear")!, transport: .ssh, capabilities: [.observe])
        let stored = runtime.registerPlatformBinding(threadID: old, hostID: hostID, binding: observation,
            sourceIdentity: "inventory-after-clear", processIDs: [], mode: .inventoryObservation)
        XCTAssertNotNil(stored, "the stored session is observable again")
        let live = runtime.registerPlatformBinding(threadID: new, hostID: hostID, binding: observation,
            sourceIdentity: "inventory-after-clear", processIDs: [], mode: .inventoryObservation)
        XCTAssertNil(live, "the conversation on the pane keeps its route")
    }

    /// Claude's `/clear` SessionEnd can land after the next SessionStart. Core
    /// refuses it as routine stale work, not a failure the user must see, and
    /// the ended conversation keeps no token.
    /// A platform proves frames as they arrive, before Core applies the
    /// queued ones. `/clear` then `/resume` back: the frame that replaced the
    /// old conversation must not retire the token its resume was proved with.
    func testResumeProvedBeforeTheReplacementAppliesKeepsTheResumedConversation() async throws {
        let applied = expectation(description: "first bind and frame")
        applied.expectedFulfillmentCount = 4
        applied.assertForOverFulfill = false
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let old = thread(), new = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "after-clear")!
        func frame(_ id: AgentThreadID, _ event: AgentLifecycleEventKind, _ status: AgentStatus) -> AgentLifecycleEnvelope {
            AgentLifecycleEnvelope(version: 9, providerID: .claude, event: event, status: status,
                providerSessionID: id.providerSessionID, agentPID: 42, transcriptRef: "b3BhcXVl")!
        }
        let oldToken = bindingToken(runtime, id: old)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: old, bindingToken: oldToken).encoded())
        runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: old, bindingToken: oldToken,
            lifecycle: frame(old, .userPromptSubmit, .working)).encoded())
        await fulfillment(of: [applied], timeout: 2)
        let newToken = bindingToken(runtime, id: new)
        let resumedToken = bindingToken(runtime, id: old)
        XCTAssertEqual(resumedToken, oldToken, "an identical authority keeps its token")
        runtime.submit(try AgentABICommand(kind: .bind, threadID: new, bindingToken: newToken).encoded())
        runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: new, bindingToken: newToken,
            lifecycle: frame(new, .sessionStart, .idle)).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: old, bindingToken: resumedToken).encoded())
        runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: old, bindingToken: resumedToken,
            lifecycle: frame(old, .sessionStart, .idle)).encoded())
        // Each bind and each accepted frame emits two events; nothing is refused.
        for _ in 0..<200 where capture.events.count < 12 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(capture.events.count, 12, "\(capture.events.map { "\($0.kind.rawValue):\($0.code ?? "")" })")
        XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }.map(\.code), [])
        XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads.map(\.id), [old],
            "the pane runs the resumed conversation")
        XCTAssertEqual(capture.retirementEvents.flatMap { $0.retirements ?? [] },
                       [.init(threadID: new, bindingToken: newToken, successor: old, reason: .replaced)],
                       "the newer proof of the resumed owner survives the queued replacement")
    }

    func testLateEndOfAReplacedConversationIsRoutineAndReleasesItsToken() async throws {
        let applied = expectation(description: "two binds and two accepted frames")
        applied.expectedFulfillmentCount = 8
        applied.assertForOverFulfill = false
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let old = thread(), new = AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "after-clear")!
        func frame(_ id: AgentThreadID, _ event: AgentLifecycleEventKind, _ status: AgentStatus) -> AgentLifecycleEnvelope {
            AgentLifecycleEnvelope(version: 9, providerID: .claude, event: event, status: status,
                providerSessionID: id.providerSessionID, agentPID: 42, transcriptRef: "b3BhcXVl")!
        }
        func deliver(_ id: AgentThreadID, _ event: AgentLifecycleEventKind, _ status: AgentStatus) throws {
            let token = bindingToken(runtime, id: id)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
            runtime.submit(try AgentABICommand(kind: .lifecycle, threadID: id, bindingToken: token,
                lifecycle: frame(id, event, status)).encoded())
        }
        try deliver(old, .stop, .finished)
        try deliver(new, .sessionStart, .idle)
        await fulfillment(of: [applied], timeout: 2)
        // The end is proved after `/clear` retired the old token.
        try deliver(old, .sessionEnd, .unavailable)
        for _ in 0..<200 where capture.events.count < 11 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(capture.events.count, 11)
        XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }.map(\.code), ["lifecycle_staleBinding"])
        XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads.map(\.id), [new])
        let observation = AgentTerminalBinding(liveSessionID: binding().liveSessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("inventory-after-late-end")!, transport: .ssh, capabilities: [.observe])
        XCTAssertNotNil(runtime.registerPlatformBinding(threadID: old, hostID: hostID, binding: observation,
            sourceIdentity: "inventory-after-late-end", processIDs: [], mode: .inventoryObservation))
    }

    /// A platform mints tokens synchronously but its commands apply in queue
    /// order, so background commands routinely arrive after a newer proof has
    /// rotated their token. That is stale work, refused under a code a client
    /// can recognise as routine -- not `abi_invalidField`, which Android shows
    /// as a global error dialog. A token still current for another thread
    /// remains a malformed command.
    func testBackgroundCommandsWithARotatedTokenAreStaleNotMalformed() async throws {
        let refused = expectation(description: "five refusals")
        refused.expectedFulfillmentCount = 5
        let capture = AgentABIEventCapture(expectation: refused)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread()
        let stale = bindingToken(runtime, id: id, binding: binding(generation: 1))
        _ = bindingToken(runtime, id: id, binding: binding(generation: 2))
        let otherThread = bindingToken(runtime, id: thread(provider: .codex))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: stale).encoded())
        runtime.submit(try AgentABICommand(
            kind: .lifecycle, threadID: id, bindingToken: stale,
            lifecycle: AgentLifecycleEnvelope(
                version: 9, providerID: .claude, event: .sessionStart, status: .working,
                providerSessionID: "provider-session", agentPID: 42, transcriptRef: "b3BhcXVl"
            )!
        ).encoded())
        runtime.submit(try AgentABICommand(kind: .terminalVisible, threadID: id, bindingToken: stale, observedGeneration: 1).encoded())
        runtime.submit(try AgentABICommand(
            kind: .livePromptObservation, threadID: id, bindingToken: stale,
            promptObservation: AgentPromptObservationRequest(providerID: .claude, visibleText: "prompt", currentCursorLine: nil)!,
            observedGeneration: 1
        ).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: otherThread).encoded())
        await fulfillment(of: [refused], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), Array(repeating: .commandRejected, count: 5))
        XCTAssertEqual(capture.events.map(\.code), [
            "bind_staleBinding", "lifecycle_staleBinding", "terminalVisible_staleBinding",
            "livePromptObservation_staleBinding", "abi_invalidField@bind",
        ])
    }

    /// Endpoint teardown queues `unbind` for the route it retires, but a newer
    /// route can prove the same thread before that command applies. Naming
    /// the retired token keeps the successor's token and binding alive.
    func testQueuedUnbindOfAReplacedRouteCannotRevokeItsSuccessor() async throws {
        let settled = expectation(description: "bind, stale unbind, successor bind, stale unbind, successor unbind")
        settled.expectedFulfillmentCount = 10
        let capture = AgentABIEventCapture(expectation: settled)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread()
        let retired = bindingToken(runtime, id: id, binding: binding(generation: 1))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: retired).encoded())
        // Minting is synchronous: rotate only once the first bind has applied.
        try await waitForEvents(capture, 2)
        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot])
        let successor = bindingToken(runtime, id: id, binding: binding(generation: 2))
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id, bindingToken: retired).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: successor).encoded())
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id, bindingToken: retired).encoded())
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id, bindingToken: successor).encoded())
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertFalse(capture.events.contains { $0.kind == .commandRejected }, "\(capture.events.map(\.code))")
        let threads = capture.events.filter { $0.kind == .threadSnapshot }.map { $0.thread?.binding }
        XCTAssertEqual(threads, [
            binding(generation: 1),
            nil, // the retired route no longer names the thread
            binding(generation: 2),
            binding(generation: 2), // a stale unbind cannot clear the successor
            nil,
        ])
    }

    /// The route being torn down may have re-proved itself (a fresh proof
    /// with changed process facts mints a new token for the same carrier)
    /// after the platform recorded its owner token. That newer token is the
    /// same route, so the unbind still retires it; an unknown token unbinds
    /// as an unnamed one did.
    func testQueuedUnbindStillRetiresItsOwnRoutesNewerToken() async throws {
        let settled = expectation(description: "bind, unbind re-proof, stale bind, bind, forged unbind, stale bind")
        settled.expectedFulfillmentCount = 10
        let capture = AgentABIEventCapture(expectation: settled)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread()
        let owner = bindingToken(runtime, id: id, binding: binding(generation: 1))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: owner).encoded())
        try await waitForEvents(capture, 2)
        let reproof = try XCTUnwrap(runtime.registerPlatformBinding(threadID: id, hostID: hostID,
            binding: binding(generation: 1), sourceIdentity: "source", processIDs: [42, 43]))
        XCTAssertNotEqual(owner, reproof)
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id, bindingToken: owner).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: reproof).encoded())
        try await waitForEvents(capture, 5)
        let observation = AgentTerminalBinding(liveSessionID: binding().liveSessionID, carrierGeneration: 2,
            incarnation: AgentIncarnationToken("inventory-after-teardown")!, transport: .ssh, capabilities: [.observe])
        XCTAssertNotNil(runtime.registerPlatformBinding(threadID: id, hostID: hostID, binding: observation,
            sourceIdentity: "inventory-after-teardown", processIDs: [], mode: .inventoryObservation),
            "no orphaned actionable token may lock out host inventory")

        let live = bindingToken(runtime, id: id, binding: binding(generation: 3))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: live).encoded())
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id, bindingToken: UUID()).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: live).encoded())
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(capture.events.filter { $0.kind == .threadSnapshot }.map { $0.thread?.binding },
                       [binding(generation: 1), nil, binding(generation: 3), nil])
        XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }.map(\.code),
                       ["bind_staleBinding", "bind_staleBinding"])
    }

    private func waitForEvents(_ capture: AgentABIEventCapture, _ count: Int) async throws {
        for _ in 0..<200 where capture.events.count < count { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func lifecycleCommand(_ id: AgentThreadID, token: UUID, timestamp: UInt64 = 1_000,
                                  agentID: String? = nil) -> AgentABICommand {
        .init(kind: .lifecycle, threadID: id, bindingToken: token,
            lifecycle: AgentLifecycleEnvelope(version: 9, providerID: id.providerID, event: .sessionStart, status: .idle,
                providerSessionID: id.providerSessionID, agentPID: 42, transcriptRef: "b3BhcXVl", agentID: agentID,
                eventSequence: timestamp, sourceTimestampNanoseconds: timestamp)!)
    }

    private func absentOccupancy() -> AgentOccupancyObservation {
        .init(hostID: hostID, liveSessionID: sessionID, carrierGeneration: 1, transport: .sshTmux, tmuxSession: "work",
              panes: [.init(paneID: "%2", exists: true, complete: true, processes: [])])
    }

    func testOccupancyAndConversationClearedCommandsRoundTripAndCannotMintAuthority() throws {
        let occupancy = AgentABICommand(kind: .occupancy, occupancy: absentOccupancy())
        XCTAssertEqual(try AgentABICommand.decode(occupancy.encoded()), occupancy)
        let cleared = AgentABICommand(kind: .conversationCleared, binding: binding(), providerID: .codex)
        XCTAssertEqual(try AgentABICommand.decode(cleared.encoded()), cleared)
        let json = try JSONSerialization.jsonObject(with: cleared.encoded()) as! [String: Any]
        XCTAssertEqual((json["providerID"] as? [String: Any])?["rawValue"] as? String, "codex")
        XCTAssertNil(json["bindingToken"])
        let timestamped = AgentABICommand(kind: .conversationCleared, binding: binding(), providerID: .codex,
            sourceTimestampNanoseconds: 200)
        XCTAssertEqual(try AgentABICommand.decode(timestamped.encoded()), timestamped)
        let timestampJSON = try JSONSerialization.jsonObject(with: timestamped.encoded()) as! [String: Any]
        XCTAssertEqual(timestampJSON["sourceTimestampNanoseconds"] as? UInt64, 200)
        XCTAssertThrowsError(try AgentABICommand(kind: .occupancy, occupancy: absentOccupancy(), sourceTimestampNanoseconds: 200).encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .occupancy).encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .occupancy, bindingToken: UUID(), occupancy: absentOccupancy()).encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .conversationCleared, binding: binding()).encoded())
        let unproved = AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("unproved")!, transport: .ssh, capabilities: [.observe])
        XCTAssertThrowsError(try AgentABICommand(kind: .conversationCleared, binding: unproved, providerID: .codex).encoded())
        XCTAssertThrowsError(try AgentABICommand(kind: .conversationCleared, binding: binding(), bindingToken: UUID(), providerID: .codex).encoded())
    }

    func testOccupancyEmitsTheRetiredTokenAndSnapshotsOnce() async throws {
        let applied = expectation(description: "live, absent, repeated observation, stale bind")
        applied.expectedFulfillmentCount = 8
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread(), token = bindingToken(runtime, id: thread())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        runtime.submit(try lifecycleCommand(id, token: token).encoded())
        runtime.submit(try AgentABICommand(kind: .occupancy, occupancy: absentOccupancy()).encoded())
        runtime.submit(try AgentABICommand(kind: .occupancy, occupancy: absentOccupancy()).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertEqual(capture.retirementEvents.count, 1)
        let retired = try XCTUnwrap(capture.retirementEvents.first)
        XCTAssertEqual(retired.retirements, [.init(threadID: id, bindingToken: token, reason: .absent)])
        XCTAssertEqual(try JSONDecoder().decode(AgentABIEvent.self, from: retired.encoded()), retired)
        let json = try JSONSerialization.jsonObject(with: retired.encoded()) as! [String: Any]
        XCTAssertEqual(json["kind"] as? String, "routesRetired")
        let routes = try XCTUnwrap(json["retirements"] as? [[String: Any]])
        XCTAssertEqual(routes.first?["bindingToken"] as? String, token.uuidString)
        XCTAssertEqual(routes.first?["reason"] as? String, "absent")
        XCTAssertNil(routes.first?["successor"])
        let snapshots = capture.events.filter { $0.kind == .threadSnapshot }.compactMap(\.thread)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertNil(snapshots.last?.binding)
        XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads, [])
        XCTAssertEqual(capture.events.last?.code, "bind_staleBinding")
    }

    func testConversationClearedRetiresRootAndChildTokensAndKeepsOtherRoutes() async throws {
        let applied = expectation(description: "three live routes, root clearing, two stale tokens")
        applied.expectedFulfillmentCount = 17
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let root = thread(provider: .codex, session: "root"), child = thread(provider: .codex, session: "child")
        let other = thread(session: "other-provider")
        let rootToken = bindingToken(runtime, id: root), childToken = bindingToken(runtime, id: child)
        let otherToken = bindingToken(runtime, id: other, binding: binding(generation: 2))
        for (id, token, timestamp, agentID) in [(root, rootToken, UInt64(1_000), nil),
            (child, childToken, 2_000, "child-agent"), (other, otherToken, 3_000, nil)] as [(AgentThreadID, UUID, UInt64, String?)] {
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
            runtime.submit(try lifecycleCommand(id, token: token, timestamp: timestamp, agentID: agentID).encoded())
        }
        runtime.submit(try AgentABICommand(kind: .conversationCleared, binding: binding(), providerID: .codex).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: root, bindingToken: rootToken).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: child, bindingToken: childToken).encoded())
        await fulfillment(of: [applied], timeout: 3)
        let retired = capture.retirementEvents.flatMap { $0.retirements ?? [] }
        XCTAssertEqual(Set(retired.map(\.threadID)), [root, child])
        XCTAssertEqual(Set(retired.map(\.bindingToken)), [rootToken, childToken])
        XCTAssertTrue(retired.allSatisfy { $0.reason == .cleared && $0.successor == nil })
        XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads.map(\.id), [other])
        XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }.map(\.code), ["bind_staleBinding", "bind_staleBinding"])
    }

    func testCompetingBindKeepsOriginalTokenUntilOccupancyAllowsTheRetry() async throws {
        let applied = expectation(description: "competing bind, original owner, absence, retry")
        applied.expectedFulfillmentCount = 14
        applied.assertForOverFulfill = false
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread(), original = bindingToken(runtime, id: thread())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
        runtime.submit(try lifecycleCommand(id, token: original).encoded())
        try await waitForEvents(capture, 4)
        let otherBinding = binding(paneID: "%3")
        let competing = bindingToken(runtime, id: id, binding: otherBinding, sourceIdentity: "other-route")
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: competing).encoded())
        try await waitForEvents(capture, 5)
        let refused = try XCTUnwrap(capture.events.last)
        XCTAssertEqual(refused.kind, .commandRejected)
        XCTAssertEqual(refused.code, "bind_liveElsewhere")
        XCTAssertEqual(refused.thread?.binding, binding())
        XCTAssertEqual(capture.retirementEvents, [])
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
        try await waitForEvents(capture, 7)
        XCTAssertEqual(capture.events.last { $0.kind == .threadSnapshot }?.thread?.binding, binding())
        runtime.submit(try AgentABICommand(kind: .occupancy, occupancy: absentOccupancy()).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: competing).encoded())
        runtime.submit(try lifecycleCommand(id, token: competing, timestamp: 2_000).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }.map(\.code), ["bind_liveElsewhere", "bind_staleBinding"])
        XCTAssertEqual(capture.events.last { $0.kind == .lifecycleAccepted }?.thread?.binding, otherBinding)
        XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads.map(\.id), [id])
        XCTAssertEqual(capture.retirementEvents.flatMap { $0.retirements ?? [] },
                       [.init(threadID: id, bindingToken: original, reason: .absent)])
    }

    func testRetirementKeepsANewerTokenWhoseBindIsQueued() async throws {
        for kind in [AgentABICommand.Kind.occupancy, .conversationCleared] {
            let applied = expectation(description: "retirement and queued successor bind")
            applied.expectedFulfillmentCount = 11
            let paused = expectation(description: "command queue paused")
            let resume = DispatchSemaphore(value: 0)
            let capture = AgentABIEventCapture(expectation: applied)
            let runtime = AgentABIRuntime { data in
                capture.receive(data)
                if let event = try? JSONDecoder().decode(AgentABIEvent.self, from: data), event.generation == 5 {
                    paused.fulfill()
                    _ = resume.wait(timeout: .now() + 3)
                }
            }
            defer { resume.signal(); runtime.destroy() }
            let id = thread(provider: .codex), original = bindingToken(runtime, id: id)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
            runtime.submit(try lifecycleCommand(id, token: original).encoded())
            runtime.submit(try AgentABICommand(kind: .filter, grouping: .attention).encoded())
            await fulfillment(of: [paused], timeout: 2)
            let retirement = kind == .occupancy ? AgentABICommand(kind: .occupancy, occupancy: absentOccupancy())
                : AgentABICommand(kind: .conversationCleared, binding: binding(), providerID: .codex, sourceTimestampNanoseconds: 2_000)
            runtime.submit(try retirement.encoded())
            let successor = binding(generation: 2), fresh = bindingToken(runtime, id: id, binding: successor)
            XCTAssertNotEqual(fresh, original)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: fresh).encoded())
            runtime.submit(try lifecycleCommand(id, token: fresh, timestamp: 3_000).encoded())
            resume.signal()
            await fulfillment(of: [applied], timeout: 3)
            XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }, [])
            XCTAssertEqual(capture.events.last { $0.kind == .lifecycleAccepted }?.thread?.binding, successor)
            XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads.map(\.id), [id])
            XCTAssertEqual(capture.retirementEvents.flatMap { $0.retirements ?? [] },
                           [.init(threadID: id, bindingToken: original, successor: id, reason: .replaced)])
        }
    }

    func testConversationClearTimestampFencesReplayAndPreservesNewerTenures() async throws {
        for timestamp in [UInt64(1_000), 2_000, 2_500] {
            let applied = expectation(description: "timestamped clear and replay")
            applied.expectedFulfillmentCount = 9
            let capture = AgentABIEventCapture(expectation: applied)
            let runtime = AgentABIRuntime { capture.receive($0) }
            defer { runtime.destroy() }
            let id = thread(provider: .codex), original = bindingToken(runtime, id: id)
            let start = lifecycleCommand(id, token: original, timestamp: timestamp)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
            runtime.submit(try start.encoded())
            runtime.submit(try AgentABICommand(kind: .conversationCleared, binding: binding(), providerID: .codex,
                sourceTimestampNanoseconds: 2_000).encoded())
            try await waitForEvents(capture, timestamp < 2_000 ? 6 : 5)
            let fresh = bindingToken(runtime, id: id)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: fresh).encoded())
            runtime.submit(try lifecycleCommand(id, token: fresh, timestamp: timestamp).encoded())
            await fulfillment(of: [applied], timeout: 3)
            if timestamp < 2_000 {
                XCTAssertNotEqual(fresh, original)
                XCTAssertEqual(capture.events.last?.code, "lifecycle_staleBinding")
                XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads, [])
                XCTAssertEqual(capture.retirementEvents.flatMap { $0.retirements ?? [] },
                               [.init(threadID: id, bindingToken: original, reason: .cleared)])
            } else {
                XCTAssertEqual(fresh, original)
                XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }, [])
                XCTAssertEqual(capture.events.last { $0.kind == .lifecycleAccepted }?.thread?.binding, binding())
                XCTAssertEqual(capture.retirementEvents, [])
            }
        }
    }

    func testNotSentAfterRebindWithdrawsOnlyItsIssuedBubbleOnce() async throws {
        for action in [AgentActionKind.send, .queue] {
            let applied = expectation(description: "old unwritten lease settles once after rebind")
            applied.expectedFulfillmentCount = 19
            let capture = AgentABIEventCapture(expectation: applied)
            let runtime = AgentABIRuntime { capture.receive($0) }
            defer { runtime.destroy() }
            let id = thread(), original = bindingToken(runtime, id: id)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
            runtime.submit(try lifecycleCommand(id, token: original).encoded())
            let text = AgentTextSendRequest(threadID: id, binding: binding(), text: "restore this draft", queueWhenWorking: action == .queue)!
            runtime.submit(try AgentABICommand(kind: .action, threadID: id, bindingToken: original,
                action: action, actionPayload: .init(text: text)).encoded())
            try await waitForEvents(capture, 5)
            let oldLease = try XCTUnwrap(capture.events.last { $0.kind == .actionPlan }?.lease)
            let successor = binding(generation: 2), fresh = bindingToken(runtime, id: id, binding: successor)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: fresh).encoded())
            runtime.submit(try lifecycleCommand(id, token: fresh, timestamp: 2_000).encoded())
            let next = AgentTextSendRequest(threadID: id, binding: successor, text: "new lease", queueWhenWorking: action == .queue)!
            runtime.submit(try AgentABICommand(kind: .action, threadID: id, bindingToken: fresh,
                action: action, actionPayload: .init(text: next)).encoded())
            try await waitForEvents(capture, 10)
            let newLease = try XCTUnwrap(capture.events.last { $0.kind == .actionPlan }?.lease)
            runtime.submit(try AgentABICommand(kind: .armOutgoing, bindingToken: fresh,
                frontier: .unavailable(for: newLease), lease: newLease).encoded())
            let notSent = AgentActionResultOutcome(status: .notSent, action: action)!
            runtime.submit(try AgentABICommand(kind: .outgoingDispatched, bindingToken: original, lease: oldLease).encoded())
            runtime.submit(try AgentABICommand(kind: .result, bindingToken: fresh, lease: oldLease, resultOutcome: notSent).encoded())
            let forged = AgentActionLease(threadID: id, binding: oldLease.binding, action: action)
            runtime.submit(try AgentABICommand(kind: .result, bindingToken: original, lease: forged, resultOutcome: notSent).encoded())
            let wrongThread = AgentActionLease(threadID: thread(session: "another-thread"), token: oldLease.token,
                binding: oldLease.binding, action: action)
            runtime.submit(try AgentABICommand(kind: .result, bindingToken: original, lease: wrongThread, resultOutcome: notSent).encoded())
            let refused = AgentABICommand(kind: .result, bindingToken: original, lease: oldLease, resultOutcome: notSent)
            runtime.submit(try refused.encoded())
            runtime.submit(try refused.encoded())
            runtime.submit(try AgentABICommand(kind: .result, bindingToken: original, lease: oldLease,
                resultOutcome: AgentActionResultOutcome(status: .verified, action: action, verification: "sent")!).encoded())
            runtime.submit(try AgentABICommand(kind: .outgoingDispatched, bindingToken: fresh, lease: newLease).encoded())
            await fulfillment(of: [applied], timeout: 3)
            let restorations = capture.events.filter { $0.kind == .threadSnapshot && $0.code == "notSent" }
            XCTAssertEqual(restorations.count, 1, "the platform receives one draft-restoration result")
            XCTAssertEqual(restorations.first?.thread?.binding, successor)
            XCTAssertEqual(restorations.first?.thread?.outgoingMessages?.map(\.id), [newLease.token])
            XCTAssertEqual(restorations.first?.thread?.outgoingMessages?.map(\.text), ["new lease"])
            XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }.count, 6)
            XCTAssertTrue(capture.events.contains { $0.kind == .commandRejected && $0.lease == oldLease &&
                $0.code == "abi_invalidField@result" }, "A repeated result is correlated to its exact lease, without restoring twice")
            XCTAssertEqual(capture.events.last?.code, "outgoingDispatched")
            XCTAssertEqual(capture.events.last?.lease, newLease)
        }
    }

    func testNotSentRequiresTheLeaseIssuedByThisRuntime() async throws {
        let issued = expectation(description: "issued text lease")
        let rejected = expectation(description: "foreign runtime lease rejected")
        issued.expectedFulfillmentCount = 3
        rejected.expectedFulfillmentCount = 3
        let first = AgentABIEventCapture(expectation: issued), second = AgentABIEventCapture(expectation: rejected)
        let source = AgentABIRuntime { first.receive($0) }, other = AgentABIRuntime { second.receive($0) }
        defer { source.destroy(); other.destroy() }
        let id = thread(), sourceToken = bindingToken(source, id: id), otherToken = bindingToken(other, id: id)
        source.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: sourceToken).encoded())
        other.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: otherToken).encoded())
        let text = AgentTextSendRequest(threadID: id, binding: binding(), text: "draft", queueWhenWorking: false)!
        source.submit(try AgentABICommand(kind: .action, threadID: id, bindingToken: sourceToken,
            action: .send, actionPayload: .init(text: text)).encoded())
        await fulfillment(of: [issued], timeout: 2)
        let lease = try XCTUnwrap(first.events.last?.lease)
        other.submit(try AgentABICommand(kind: .result, bindingToken: otherToken, lease: lease,
            resultOutcome: AgentActionResultOutcome(status: .notSent, action: .send)!).encoded())
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(second.events.last?.kind, .commandRejected)
        XCTAssertTrue(second.events.allSatisfy { $0.code != "notSent" })
    }

    // A written action whose authority retired before it finished: Core
    // rejects its result, but the result still ends the issued lease. The
    // identity does not outlive it, and no later `notSent` can withdraw a
    // bubble whose bytes may already be in the terminal.
    func testStaleWrittenResultEndsItsIssuedLease() async throws {
        for status in [AgentActionResultStatus.failed, .staleBinding, .cancelled] {
            let applied = expectation(description: "stale written result consumes its lease")
            applied.expectedFulfillmentCount = 7
            let capture = AgentABIEventCapture(expectation: applied)
            let runtime = AgentABIRuntime { capture.receive($0) }
            defer { runtime.destroy() }
            let id = thread(), original = bindingToken(runtime, id: id)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
            let text = AgentTextSendRequest(threadID: id, binding: binding(), text: "partly typed", queueWhenWorking: false)!
            runtime.submit(try AgentABICommand(kind: .action, threadID: id, bindingToken: original,
                action: .send, actionPayload: .init(text: text)).encoded())
            try await waitForEvents(capture, 3)
            let lease = try XCTUnwrap(capture.events.last?.lease)
            let successor = binding(generation: 2), fresh = bindingToken(runtime, id: id, binding: successor)
            runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: fresh).encoded())
            runtime.submit(try AgentABICommand(kind: .result, bindingToken: original, lease: lease,
                resultOutcome: AgentActionResultOutcome(status: status, action: .send)!).encoded())
            runtime.submit(try AgentABICommand(kind: .result, bindingToken: original, lease: lease,
                resultOutcome: AgentActionResultOutcome(status: .notSent, action: .send)!).encoded())
            await fulfillment(of: [applied], timeout: 2)
            XCTAssertEqual(capture.events.suffix(2).map(\.kind), [.commandRejected, .commandRejected], "\(status)")
            XCTAssertTrue(capture.events.allSatisfy { $0.code != "notSent" }, "\(status)")
            let outgoing = capture.events.last { $0.kind == .threadSnapshot }?.thread?.outgoingMessages
            XCTAssertEqual(outgoing?.map(\.id), [lease.token], "\(status)")
        }
    }

    func testAcknowledgedLeaseCannotBecomeNotSentAfterRebind() async throws {
        let applied = expectation(description: "acknowledged lease stays sent after rebind")
        applied.expectedFulfillmentCount = 7
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread(), original = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
        let text = AgentTextSendRequest(threadID: id, binding: binding(), text: "written", queueWhenWorking: false)!
        runtime.submit(try AgentABICommand(kind: .action, threadID: id, bindingToken: original,
            action: .send, actionPayload: .init(text: text)).encoded())
        try await waitForEvents(capture, 3)
        let lease = try XCTUnwrap(capture.events.last?.lease)
        runtime.submit(try AgentABICommand(kind: .result, bindingToken: original, lease: lease,
            resultOutcome: AgentActionResultOutcome(status: .verified, action: .send, verification: "sent")!).encoded())
        try await waitForEvents(capture, 4)
        let successor = binding(generation: 2), fresh = bindingToken(runtime, id: id, binding: successor)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: fresh).encoded())
        runtime.submit(try AgentABICommand(kind: .result, bindingToken: original, lease: lease,
            resultOutcome: AgentActionResultOutcome(status: .notSent, action: .send)!).encoded())
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(capture.events.last?.kind, .commandRejected)
        XCTAssertTrue(capture.events.allSatisfy { $0.code != "notSent" })
        let outgoing = capture.events.last { $0.kind == .threadSnapshot }?.thread?.outgoingMessages
        XCTAssertEqual(outgoing?.map(\.id), [lease.token])
        XCTAssertEqual(outgoing?.map(\.status), [.sentUnconfirmed])
    }

    func testSameProcessCapabilityReproofRotatesOnlyTheOldToken() async throws {
        let applied = expectation(description: "capability reproof")
        applied.expectedFulfillmentCount = 9
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread(), original = bindingToken(runtime, id: thread())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
        runtime.submit(try lifecycleCommand(id, token: original).encoded())
        try await waitForEvents(capture, 4)
        let changed = binding(capabilities: [.observe, .interrupt, .tmux])
        let fresh = bindingToken(runtime, id: id, binding: changed)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: fresh).encoded())
        runtime.submit(try lifecycleCommand(id, token: fresh, timestamp: 2_000).encoded())
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }.map(\.code), ["bind_staleBinding"])
        XCTAssertEqual(capture.events.last { $0.kind == .lifecycleAccepted }?.thread?.binding, changed)
        XCTAssertEqual(capture.retirementEvents.flatMap { $0.retirements ?? [] },
                       [.init(threadID: id, bindingToken: original, successor: id, reason: .replaced)])
    }

    func testUnbindingARefusedProofKeepsTheLiveOwnerOnTheSameCarrier() async throws {
        let applied = expectation(description: "refused proof teardown")
        applied.expectedFulfillmentCount = 9
        let capture = AgentABIEventCapture(expectation: applied)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread(), original = bindingToken(runtime, id: thread())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
        runtime.submit(try lifecycleCommand(id, token: original).encoded())
        try await waitForEvents(capture, 4)
        let competing = bindingToken(runtime, id: id, binding: binding(paneID: "%3"), sourceIdentity: "other-route")
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: competing).encoded())
        runtime.submit(try AgentABICommand(kind: .unbind, threadID: id, bindingToken: competing).encoded())
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: original).encoded())
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertEqual(capture.events.filter { $0.kind == .commandRejected }.map(\.code), ["bind_liveElsewhere"])
        XCTAssertEqual(capture.events.last { $0.kind == .threadSnapshot }?.thread?.binding, binding())
        XCTAssertEqual(capture.events.last { $0.kind == .listSnapshot }?.list?.threads.map(\.id), [id])
        XCTAssertEqual(capture.retirementEvents.flatMap { $0.retirements ?? [] },
                       [.init(threadID: id, bindingToken: competing, reason: .unbound)])
    }

    func testProjectionCannotBypassProviderTranscriptCapabilityGate() async throws {
        let expectation = expectation(description: "bind and projection rejection")
        expectation.expectedFulfillmentCount = 3
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread(provider: .opencode)
        let token = bindingToken(runtime, id: id)
        let record = AgentProjectionRecord(sequence: 1, recordID: "record", record: .object(["type": .string("assistant"), "text": .string("must not surface")]))!
        let page = AgentProjectionPage(sourceIdentity: "source", records: [record], cursor: nil, hasMore: false)!
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        runtime.submit(try AgentABICommand(kind: .projection, threadID: id, bindingToken: token, projection: page).encoded())
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot, .commandRejected])
        XCTAssertEqual(capture.events.last?.code, "projection_transcriptUnavailable")
        runtime.destroy()
    }

    func testProjectionFinishingAfterRouteReplacementIsRejectedWithoutMutatingNewOwner() async throws {
        let callbacks = expectation(description: "new owner, stale rejection, current projection")
        callbacks.expectedFulfillmentCount = 4
        let capture = AgentABIEventCapture(expectation: callbacks)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }
        let id = thread()
        let oldToken = bindingToken(runtime, id: id, binding: binding(generation: 1))
        let newToken = bindingToken(runtime, id: id, binding: binding(generation: 2))
        let page = AgentProjectionPage(sourceIdentity: "source", records: [
            AgentProjectionRecord(sequence: 1, recordID: "record", record: .object(["type": .string("assistant"), "text": .string("current content")]))!
        ], cursor: nil, hasMore: false)!
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: newToken).encoded())
        runtime.submit(try AgentABICommand(kind: .projection, threadID: id, bindingToken: oldToken, projection: page).encoded())
        runtime.submit(try AgentABICommand(kind: .projection, threadID: id, bindingToken: newToken, projection: page).encoded())
        await fulfillment(of: [callbacks], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.threadSnapshot, .listSnapshot, .commandRejected, .projectionApplied])
        XCTAssertEqual(capture.events[2].code, "projection_staleBinding")
        XCTAssertEqual(capture.events.last?.thread?.binding?.carrierGeneration, 2)
    }

    func testPlatformTierCRegistrationUsesOnlyCompiledProviderAttestations() async throws {
        XCTAssertNotNil(AgentABIPlatformConformanceRegistration(providers: []))
        XCTAssertNil(AgentABIPlatformConformanceRegistration(providers: [.claude]))
        XCTAssertNil(AgentABIPlatformConformanceRegistration(providers: [.opencode, .opencode]))
        let expectation = expectation(description: "conformance reconfigure then enabled bind")
        // Reconfigure emits a list; the bind then emits its thread snapshot
        // and re-emits the list.
        expectation.expectedFulfillmentCount = 3
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread(provider: .opencode)
        let token = bindingToken(runtime, id: id)
        XCTAssertTrue(runtime.registerPlatformConformingProviders(
            AgentABIPlatformConformanceRegistration(providers: [.opencode])!
        ))
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.listSnapshot, .threadSnapshot, .listSnapshot])
        XCTAssertEqual(
            capture.events.first(where: { $0.kind == .threadSnapshot })?.thread?.summary.availability.content,
            true
        )
        runtime.destroy()
    }

    func testCPlatformTierCRegistrationRejectsCallerSuppliedAdapterOrDigest() throws {
        let callback: TesseraAgentABIEventCallback = { _, _, _ in }
        let handle = tesseraAgentRuntimeCreate(callback: callback, context: nil)
        defer { tesseraAgentRuntimeDestroy(handle: handle) }
        let valid = Data(#"{"providers":["opencode","kimi"]}"#.utf8)
        let validStatus = valid.withUnsafeBytes { raw in
            tesseraAgentRuntimeRegisterPlatformConformances(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
        XCTAssertEqual(validStatus, 0)
        let forged = Data(#"{"providers":["opencode"],"adapterID":"forged","sourceFixtureDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8)
        let forgedStatus = forged.withUnsafeBytes { raw in
            tesseraAgentRuntimeRegisterPlatformConformances(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
        XCTAssertEqual(forgedStatus, -1)
    }

    func testManyTinyRecordsRemainBoundedWithoutQuadraticReencoding() throws {
        let id = thread()
        let summary = AgentThreadSummary(id: id, providerName: "codex", availability: .init(content: true, status: false, actions: false, spawn: false, fork: false, search: false))
        let messages = (0..<19_000).map { AgentMessage(recordID: "tiny-\($0)", role: .assistant, displayTime: nil, blocks: [.text("x")]) }
        let snapshot = AgentThreadSnapshot(summary: summary, messages: messages, turns: [], activity: [],
            cursor: "remote-cursor", hasMore: true, binding: nil, deliveryGeneration: 1)
        let started = Date()
        let bounded = AgentABIEvent(kind: .threadSnapshot, generation: 1, thread: snapshot).boundedForABI()
        XCTAssertNoThrow(try bounded.encoded())
        XCTAssertEqual(bounded.thread?.messages.last?.recordID, "tiny-18999")
        XCTAssertEqual(bounded.thread?.cursor, "remote-cursor")
        XCTAssertTrue(bounded.thread?.hasMore == true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testLargeThreadSnapshotIsDeliveredAsBoundedABIEvent() async throws {
        let expectation = expectation(description: "bind plus all bounded projection callbacks")
        expectation.expectedFulfillmentCount = 9
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        let id = thread()
        // The largest tier and window must still fit Android's JNI frame.
        runtime.submit(try AgentABICommand(kind: .configure, physicalMemoryBytes: 16 << 30, lowRAMDevice: false).encoded())
        runtime.submit(try AgentABICommand(kind: .hostCapacity, threadID: id, hostWindowSegments: [id.hostID.uuidString: 64]).encoded())
        let token = bindingToken(runtime, id: id)
        runtime.submit(try AgentABICommand(kind: .bind, threadID: id, bindingToken: token).encoded())
        let text = String(repeating: "x", count: 16_000)
        for pageIndex in 0..<8 {
            let records = (0..<10).map { offset in
                AgentProjectionRecord(
                    sequence: UInt64(pageIndex * 10 + offset + 1),
                    recordID: "record-\(pageIndex)-\(offset)",
                    record: .object(["type": .string("assistant"), "text": .string(text)])
                )!
            }
            let page = AgentProjectionPage(sourceIdentity: "source", records: records, cursor: "\(pageIndex)", hasMore: true)!
            runtime.submit(try AgentABICommand(kind: .projection, threadID: id, bindingToken: token, projection: page).encoded())
        }
        await fulfillment(of: [expectation], timeout: 4)
        XCTAssertEqual(capture.events.count, 9)
        XCTAssertEqual(capture.events.last?.kind, .projectionApplied)
        XCTAssertLessThan(capture.events.last?.thread?.messages.count ?? 0, 80)
        XCTAssertTrue(capture.events.last?.thread?.hasMore == true)
        XCTAssertLessThanOrEqual(capture.largestPayload, AgentABICommand.maximumPayloadBytes)
        XCTAssertGreaterThan(capture.largestPayload, AgentABICommand.maximumPayloadBytes / 2, "the bound was exercised")
        runtime.destroy()
    }

    func testDestroyCommandTerminatesOperationStreamWithoutSelfAwait() async throws {
        let expectation = expectation(description: "destroy callback")
        let capture = AgentABIEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        runtime.submit(try AgentABICommand(kind: .destroy).encoded())
        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(capture.events.map(\.kind), [.destroyed])
        runtime.submit(try AgentABICommand(kind: .memoryWarning).encoded())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(capture.events.count, 1)
    }
}

private func agentSend(_ data: Data, handle: UnsafeMutableRawPointer?) -> Int32 {
    data.withUnsafeBytes { raw in
        tesseraAgentRuntimeSend(handle: handle, bytes: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)
    }
}

private final class AgentABIEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var storage: [AgentABIEvent] = []
    private var largest = 0
    var largestPayload: Int { lock.lock(); defer { lock.unlock() }; return largest }

    init(expectation: XCTestExpectation) { self.expectation = expectation }

    var events: [AgentABIEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage.filter { $0.kind != .routesRetired }
    }

    var retirementEvents: [AgentABIEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage.filter { $0.kind == .routesRetired }
    }

    func receive(_ data: Data) {
        guard let event = try? JSONDecoder().decode(AgentABIEvent.self, from: data) else { return }
        lock.lock(); storage.append(event); largest = max(largest, data.count); lock.unlock()
        // Existing assertions cover the unchanged event stream. Retirement
        // assertions separately cover the additive token-bearing events.
        if event.kind != .routesRetired { expectation.fulfill() }
    }
}
