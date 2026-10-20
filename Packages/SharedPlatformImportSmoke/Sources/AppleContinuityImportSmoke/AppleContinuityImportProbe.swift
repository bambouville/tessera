import Foundation
import TesseraAppleContinuity
import TesseraEnrollmentCore
import TesseraSessionCore

public enum AppleContinuityImportProbe {
    public struct Result: Equatable, Sendable {
        public let activityType: String
        public let descriptorKey: String
        public let publisherInitiallyIdle: Bool
        public let streamUsesAppleAccountBinding: Bool
        public let enrollmentFrameRoundTrips: Bool
        public let enrollmentStateMachineReachedRejected: Bool
    }

    @MainActor
    public static func run() async throws -> Result {
        let publisher = AppleContinuationActivityPublisher()
        let stream = AppleContinuationStreamTransport(
            input: InputStream(data: Data()),
            output: OutputStream.toMemory()
        )

        // The Mac bridge composes the Apple stream's same-account binding with
        // the public portable codec and state machine. No app-target
        // EnrollmentService or second protocol coordinator is required.
        let machine = try EnrollmentStateMachine(
            peerBinding: stream.peerBinding,
            authorizer: SmokeOwnerAuthorizer()
        )
        let request = makeEnrollmentRequest()
        let outbound = try await machine.request(request)
        let frame = try EnrollmentFrameCodecV1.encode(outbound)
        var decoder = EnrollmentFrameDecoderV1()
        let split = frame.index(frame.startIndex, offsetBy: 3)
        let prefix = try decoder.append(frame[..<split])
        let decoded = try decoder.append(frame[split...])
        _ = await machine.receive(.rejected(enrollmentID: request.id))
        let finalState = await machine.state

        return Result(
            activityType: AppleContinuationActivityContract.activityType,
            descriptorKey: AppleContinuationActivityContract.descriptorKey,
            publisherInitiallyIdle: !publisher.isPublishing
                && publisher.currentUserActivity == nil,
            streamUsesAppleAccountBinding: stream.peerBinding
                == .appleAccountContinuationStream,
            enrollmentFrameRoundTrips: prefix.isEmpty && decoded == [outbound],
            enrollmentStateMachineReachedRejected: finalState == .rejected(request.id)
        )
    }

    private static func makeEnrollmentRequest() -> EnrollmentRequestV1 {
        var blob = Data()
        appendSSHString(Data("ssh-ed25519".utf8), to: &blob)
        appendSSHString(Data(repeating: 0x5A, count: 32), to: &blob)
        let key = EnrollmentPublicKeyV1(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            displayName: "Mac smoke key",
            algorithm: .ed25519,
            blob: blob.base64EncodedString(),
            fingerprint: DevicePublicKeyValidator.fingerprint(forSSHBlob: blob),
            protection: .software
        )
        return EnrollmentRequestV1(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            hostID: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            hostName: "Mac smoke host",
            requestingDeviceName: "iPhone smoke",
            publicKey: key
        )
    }

    private static func appendSSHString(_ value: Data, to blob: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(value)
    }
}

private struct SmokeOwnerAuthorizer: FreshOwnerAuthorizing {
    func authorize(
        _ request: OwnerAuthorizationRequest
    ) async throws -> FreshOwnerAuthorization {
        FreshOwnerAuthorization(
            attemptID: request.attemptID,
            policyGeneration: request.policyGeneration,
            scope: request.scope,
            issuedAt: Date(),
            expiresAt: request.expiresAt
        )
    }
}
