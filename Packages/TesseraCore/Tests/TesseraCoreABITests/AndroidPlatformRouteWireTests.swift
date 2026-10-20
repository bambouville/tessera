import Foundation
import XCTest
import TesseraAgentCore
@testable import TesseraCoreABI

/// The Android route authority does not encode these registrations from Swift
/// types; it hand-builds `org.json.JSONObject` payloads and posts the bytes
/// across the C ABI. Nothing on either side of that seam fails loudly — the
/// entry points answer `-1` for a payload they cannot decode and `-1` again
/// for one they decode but refuse, so a single mistyped field looks exactly
/// like a policy rejection and reaches the user as an Agent Center that stays
/// empty. These tests pin the literal Kotlin wire text.
final class AndroidPlatformRouteWireTests: XCTestCase {
    private let hostID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let liveSessionID = "11111111-2222-3333-4444-555555555555"
    private let carrierGeneration = 3
    private let agentPID = 21524
    private let paneID = "%3"

    /// Mirrors `AgentEndpointBinding.coreBinding` in AgentRouteBindingAuthority.kt.
    private func androidCoreBinding(capabilities: Int, agentPID: Int?) -> String {
        let incarnation = agentPID.map { "\(liveSessionID):\(carrierGeneration):\($0)" }
            ?? "\(liveSessionID):\(carrierGeneration)"
        let pid = agentPID.map { "\"agentPID\":\($0)," } ?? ""
        return """
        {"liveSessionID":"\(liveSessionID)","carrierGeneration":\(carrierGeneration),\
        "incarnation":{"rawValue":"\(incarnation)"},"transport":"sshTmux",\
        "tmuxSession":"tessera-6d7ab28a","windowID":"@1","paneID":"\(paneID)",\
        \(pid)"capabilities":\(capabilities)}
        """
    }

    /// Mirrors `threadID(...)` in AgentCenterPresenter.kt.
    private var androidThreadID: String {
        """
        {"hostID":"\(hostID)","providerID":{"rawValue":"claude"},\
        "providerSessionID":"6d7ab28a-1f4c-4d90-9a3d-7c2b5e0f1a22"}
        """
    }

    private var androidSourceIdentity: String {
        "android:\(liveSessionID):\(carrierGeneration):\(paneID)"
    }

    private func register(
        _ payload: String,
        into handle: UnsafeMutableRawPointer?,
        with entry: (
            UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
            UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?
        ) -> Int32
    ) -> (status: Int32, response: String) {
        let bytes = Array(payload.utf8)
        var output = [UInt8](repeating: 0, count: 4_096)
        var count = 0
        let status = bytes.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { buffer in
                entry(handle, input.baseAddress, input.count, buffer.baseAddress, buffer.count, &count)
            }
        }
        return (status, String(decoding: output[0..<count], as: UTF8.self))
    }

    /// The exact exchange an Android SSH+tmux pane performs once its remote
    /// `tessera-agent-prove` run has returned a valid proof.
    func testAndroidActionableRegistrationCrossesTheCABI() throws {
        let callback: TesseraAgentABIEventCallback = { _, _, _ in }
        let handle = tesseraAgentRuntimeCreate(callback: callback, context: nil)
        defer { tesseraAgentRuntimeDestroy(handle: handle) }

        let binding = androidCoreBinding(capabilities: 31, agentPID: agentPID)
        let proofPayload = """
        {"threadID":\(androidThreadID),"hostID":"\(hostID)","binding":\(binding),\
        "sourceIdentity":"\(androidSourceIdentity)","processIDs":[21524,72292],\
        "validatedDirectories":["/Users/avery/projects/tessera"]}
        """
        let proof = register(proofPayload, into: handle, with: tesseraAgentRuntimeRegisterPlatformProof)
        XCTAssertEqual(proof.status, 0, "the proof registration Android sends must decode: \(proofPayload)")

        let proofHandle = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(proof.response.utf8))) as? [String: Any]
        )["proofHandle"] as? String

        let bindingPayload = """
        {"threadID":\(androidThreadID),"hostID":"\(hostID)","binding":\(binding),\
        "sourceIdentity":"\(androidSourceIdentity)",\
        "validatedDirectories":["/Users/avery/projects/tessera"],"mode":"actionable",\
        "proofHandle":"\(try XCTUnwrap(proofHandle))"}
        """
        let token = register(bindingPayload, into: handle, with: tesseraAgentRuntimeRegisterPlatformBinding)
        XCTAssertEqual(token.status, 0, "the binding registration Android sends must be accepted: \(bindingPayload)")
        XCTAssertTrue(token.response.contains("bindingToken"))
    }

    /// A codex pane with no provider PID takes the observe-only branch, which
    /// Android builds from a different capability set and an empty PID list.
    func testAndroidObserveOnlyRegistrationCrossesTheCABI() throws {
        try checkAndroidObservationRegistration(mode: "observeOnly")
        try checkAndroidObservationRegistration(mode: "inventoryObservation")
    }

    private func checkAndroidObservationRegistration(mode: String) throws {
        let callback: TesseraAgentABIEventCallback = { _, _, _ in }
        let handle = tesseraAgentRuntimeCreate(callback: callback, context: nil)
        defer { tesseraAgentRuntimeDestroy(handle: handle) }

        let binding = androidCoreBinding(capabilities: 1, agentPID: nil)
        let proofPayload = """
        {"threadID":\(androidThreadID),"hostID":"\(hostID)","binding":\(binding),\
        "sourceIdentity":"\(androidSourceIdentity)","processIDs":[],"validatedDirectories":[]}
        """
        let proof = register(proofPayload, into: handle, with: tesseraAgentRuntimeRegisterPlatformProof)
        XCTAssertEqual(proof.status, 0, "observe-only proof must decode: \(proofPayload)")

        let proofHandle = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(proof.response.utf8))) as? [String: Any]
        )["proofHandle"] as? String
        let bindingPayload = """
        {"threadID":\(androidThreadID),"hostID":"\(hostID)","binding":\(binding),\
        "sourceIdentity":"\(androidSourceIdentity)","validatedDirectories":[],\
        "mode":"\(mode)","proofHandle":"\(try XCTUnwrap(proofHandle))"}
        """
        let token = register(bindingPayload, into: handle, with: tesseraAgentRuntimeRegisterPlatformBinding)
        XCTAssertEqual(token.status, 0, "observe-only binding must be accepted: \(bindingPayload)")
    }

    /// The command a pane's OSC hook actually produces. `consumeLifecycle`
    /// shipped it without `threadID`, which `validate()` requires for
    /// `.lifecycle` -- and because `submit` decodes on its own executor, the
    /// Kotlin `forward` had already returned true. Agent Center therefore
    /// showed rows whose model and location (projection) were right while
    /// their title and status (lifecycle) stayed "Untitled / unavailable",
    /// with `abi_missingField` as the only clue. The registrations above
    /// already prove the binding wire; this pins the command wire.
    func testAndroidLifecycleCommandCarriesItsThreadIdentity() async throws {
        let expectation = expectation(description: "bind then lifecycle accepted")
        expectation.expectedFulfillmentCount = 4
        let capture = AndroidWireEventCapture(expectation: expectation)
        let runtime = AgentABIRuntime { capture.receive($0) }
        defer { runtime.destroy() }

        let binding = androidCoreBinding(capabilities: 31, agentPID: agentPID)
        let proofPayload = """
        {"threadID":\(androidThreadID),"hostID":"\(hostID)","binding":\(binding),\
        "sourceIdentity":"\(androidSourceIdentity)","processIDs":[\(agentPID)],\
        "validatedDirectories":[]}
        """
        let proof = try XCTUnwrap(
            try? AgentABIPlatformProofRegistration.decode(Data(proofPayload.utf8)),
            "the proof Android sends must decode: \(proofPayload)"
        )
        let proofHandle = try XCTUnwrap(runtime.registerPlatformProcessProof(proof)).proofHandle
        let bindingPayload = """
        {"threadID":\(androidThreadID),"hostID":"\(hostID)","binding":\(binding),\
        "sourceIdentity":"\(androidSourceIdentity)","validatedDirectories":[],\
        "mode":"actionable","proofHandle":"\(proofHandle)"}
        """
        let registration = try XCTUnwrap(
            try? AgentABIPlatformBindingRegistration.decode(Data(bindingPayload.utf8)),
            "the binding Android sends must decode: \(bindingPayload)"
        )
        let bindingToken = try XCTUnwrap(runtime.registerPlatformBinding(registration)).bindingToken

        // `installThreadOwner` in AgentCenterPresenter.kt.
        runtime.submit(Data("""
        {"v":1,"kind":"bind","threadID":\(androidThreadID),"bindingToken":"\(bindingToken)"}
        """.utf8))
        // `consumeLifecycle` in AgentCenterPresenter.kt, over a real
        // `SessionStart` frame from a Claude pane -- empty hook tokens dropped
        // by the shared parser, so they never reach the envelope.
        runtime.submit(Data("""
        {"v":1,"kind":"lifecycle","threadID":\(androidThreadID),"bindingToken":"\(bindingToken)",\
        "lifecycle":{"version":9,"providerID":{"rawValue":"claude"},"event":"SessionStart",\
        "status":"idle","providerSessionID":"6d7ab28a-1f4c-4d90-9a3d-7c2b5e0f1a22",\
        "transcriptRef":"L1VzZXJzL2hvdXplLy5jbGF1ZGUvcHJvamVjdHMvcC83NjEwLmpzb25s",\
        "agentPID":\(agentPID),"eventSequence":1}}
        """.utf8))

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(
            capture.events.map(\.kind),
            [.threadSnapshot, .listSnapshot, .lifecycleAccepted, .listSnapshot]
        )
        XCTAssertNil(
            capture.events.compactMap(\.code).first,
            "no command Android sends on this path may be rejected"
        )
    }
}

private final class AndroidWireEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var storage: [AgentABIEvent] = []

    init(expectation: XCTestExpectation) { self.expectation = expectation }

    var events: [AgentABIEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func receive(_ data: Data) {
        guard let event = try? JSONDecoder().decode(AgentABIEvent.self, from: data) else { return }
        lock.lock(); storage.append(event); lock.unlock()
        expectation.fulfill()
    }
}
