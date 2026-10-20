import XCTest
@testable import TesseraAgentCore

final class AgentComposerVerificationTests: XCTestCase {
    func testLegacyRequestsKeepVerificationAndExplicitOverrideSurvivesActionValidation() throws {
        for provider in [AgentProviderID.codex, .claude] {
            for queue in [false, true] {
                let thread = id(provider)
                let required = try XCTUnwrap(AgentTextSendRequest(threadID: thread, binding: binding,
                    text: "draft", queueWhenWorking: queue))
                var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(required)) as? [String: Any])
                legacy.removeValue(forKey: "composerVerification")
                XCTAssertEqual(try JSONDecoder().decode(AgentTextSendRequest.self,
                    from: JSONSerialization.data(withJSONObject: legacy)), required)
                XCTAssertNil(required.userOverrideSubmissionKey)

                let override = try XCTUnwrap(AgentTextSendRequest(threadID: thread, binding: binding,
                    text: "draft", queueWhenWorking: queue, composerVerification: .userOverride))
                XCTAssertEqual(override.userOverrideSubmissionKey, provider == .codex && queue ? .tab : .return)
                let payload = AgentABIActionPayload(text: override)
                XCTAssertTrue(payload.isValid(for: queue ? .queue : .send, threadID: thread, binding: binding))
                XCTAssertEqual(try JSONDecoder().decode(AgentABIActionPayload.self,
                    from: JSONEncoder().encode(payload)), payload)
                XCTAssertFalse(payload.isValid(for: queue ? .send : .queue, threadID: thread, binding: binding))
                XCTAssertFalse(payload.isValid(for: queue ? .queue : .send, threadID: id(provider), binding: binding))
            }
        }
    }

    func testOverrideDoesNotPermitUnsupportedProvidersOrUnsafeText() throws {
        XCTAssertNil(AgentTextSendRequest(threadID: id(.pi), binding: binding, text: "draft",
            queueWhenWorking: false, composerVerification: .userOverride))
        XCTAssertNil(AgentTextSendRequest(threadID: id(.codex), binding: binding, text: "draft\u{1b}",
            queueWhenWorking: false, composerVerification: .userOverride))
        let request = try XCTUnwrap(AgentTextSendRequest(threadID: id(.codex), binding: binding,
            text: "draft", queueWhenWorking: false))
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        malformed["composerVerification"] = "skipAllAuthority"
        XCTAssertThrowsError(try JSONDecoder().decode(AgentTextSendRequest.self,
            from: JSONSerialization.data(withJSONObject: malformed)))
    }

    private func id(_ provider: AgentProviderID) -> AgentThreadID {
        AgentThreadID(hostID: UUID(), providerID: provider, providerSessionID: "verification")!
    }

    private let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
        incarnation: AgentIncarnationToken("verification")!, transport: .sshTmux,
        tmuxSession: "test", windowID: "@1", paneID: "%1", agentPID: 42,
        capabilities: [.observe, .send, .tmux])
}
