import Foundation
import SwiftData
import XCTest
@testable import Tessera

@MainActor
final class EnrollmentCoordinatorTests: XCTestCase {
    private enum TestAuthorizationError: Error {
        case denied
    }

    private final class Authorizer: EnrollmentBiometricAuthorizing {
        enum Decision {
            case fresh
            case denied
        }

        let decision: Decision
        private(set) var reasons: [String] = []

        init(decision: Decision) {
            self.decision = decision
        }

        func authorizeFreshBiometrics(
            reason: String
        ) async throws -> EnrollmentFreshBiometricAuthorization {
            reasons.append(reason)
            switch decision {
            case .fresh:
                return EnrollmentFreshBiometricAuthorization()
            case .denied:
                throw TestAuthorizationError.denied
            }
        }
    }

    private final class ContinuationActivity: NSUserActivity {
        private let continuationInput: InputStream
        private let continuationOutput: OutputStream

        init(input: InputStream, output: OutputStream) {
            continuationInput = input
            continuationOutput = output
            super.init(activityType: "com.bambouville.TesseraTests.enrollment")
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used by EnrollmentCoordinatorTests")
        }

        override func getContinuationStreams(
            completionHandler: @escaping (InputStream?, OutputStream?, Error?) -> Void
        ) {
            completionHandler(continuationInput, continuationOutput, nil)
        }
    }

    private final class DeferredContinuationActivity: NSUserActivity {
        private var completionHandler: ((InputStream?, OutputStream?, Error?) -> Void)?

        var isWaitingForStreams: Bool { completionHandler != nil }

        init() {
            super.init(activityType: "com.bambouville.TesseraTests.enrollment.deferred")
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used by EnrollmentCoordinatorTests")
        }

        override func getContinuationStreams(
            completionHandler: @escaping (InputStream?, OutputStream?, Error?) -> Void
        ) {
            XCTAssertNil(self.completionHandler, "test activity received a second pending request")
            self.completionHandler = completionHandler
        }

        func deliver(input: InputStream, output: OutputStream) {
            let completionHandler = self.completionHandler
            self.completionHandler = nil
            XCTAssertNotNil(completionHandler, "test activity had no pending stream request")
            completionHandler?(input, output, nil)
        }
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let requesterHost: PersistedHost
        let originHost: Host
        let key: StoredKey
        let publicKey: EnrollmentPublicKey
        let activity: NSUserActivity
    }

    func testRealCoordinatorsCompleteOnlyAfterFreshAuthInstallAndDurableRecords() async throws {
        let streams = makeDuplexPair()
        let fixture = try makeFixture(
            requesterInput: streams.firstInput,
            requesterOutput: streams.firstOutput
        )
        let requesterSuite = "EnrollmentCoordinatorTests.requester.\(UUID().uuidString)"
        let originSuite = "EnrollmentCoordinatorTests.origin.\(UUID().uuidString)"
        let requesterDefaults = try XCTUnwrap(UserDefaults(suiteName: requesterSuite))
        let originDefaults = try XCTUnwrap(UserDefaults(suiteName: originSuite))
        defer {
            requesterDefaults.removePersistentDomain(forName: requesterSuite)
            originDefaults.removePersistentDomain(forName: originSuite)
        }
        let requesterMetadata = KeySecurityMetadataStore(
            defaults: requesterDefaults,
            storageKey: "requester-enrollment"
        )
        let originMetadata = KeySecurityMetadataStore(
            defaults: originDefaults,
            storageKey: "origin-enrollment"
        )
        let requesterAuthorizer = Authorizer(decision: .denied)
        let originAuthorizer = Authorizer(decision: .fresh)
        var installedGrants: [SyncDeviceAccessGrantEngine.InstallRequest] = []
        var authCountSeenByInstaller: Int?
        var completedHosts: [UUID] = []
        let grantEngine = SyncDeviceAccessGrantEngine(
            testInstaller: { request in
                authCountSeenByInstaller = originAuthorizer.reasons.count
                installedGrants.append(request)
            },
            intentRecorder: { request in
                originMetadata.recordRemoteInstallation(
                    keyID: request.publicKey.id,
                    hostID: request.hostID,
                    hostLabel: request.hostLabel,
                    endpoint: request.endpoint,
                    peerDeviceName: request.peerDeviceName,
                    direction: .grantedToPeer,
                    flow: request.flow,
                    verificationState: .uncertain,
                    publicKeyFingerprint: request.publicKey.fingerprint,
                    authorizedKeysLine: request.authorizedKeysLine
                )
            },
            verificationRecorder: { request in
                originMetadata.markRemoteInstallationVerificationState(
                    .verified,
                    keyID: request.publicKey.id,
                    hostID: request.hostID,
                    hostLabel: request.hostLabel,
                    endpoint: request.endpoint,
                    publicKeyFingerprint: request.publicKey.fingerprint,
                    authorizedKeysLine: request.authorizedKeysLine
                )
            }
        )

        let requester = EnrollmentCoordinator(
            metadata: requesterMetadata,
            authorizer: requesterAuthorizer,
            deviceKeyProvider: { _ in fixture.key }
        )
        let origin = EnrollmentCoordinator(
            metadata: originMetadata,
            authorizer: originAuthorizer,
            grantEngine: grantEngine
        )
        requester.onRequesterEnrollmentCompleted = { completedHosts.append($0.id) }

        origin.acceptOriginStreams(
            input: streams.secondInput,
            output: streams.secondOutput,
            focusedHost: fixture.originHost
        )
        requester.requestAuthorization(
            through: fixture.activity,
            for: fixture.requesterHost,
            authorizationHostID: fixture.originHost.id,
            peerDeviceName: "Origin iPad",
            in: fixture.context,
            defaultKeyUseOwnerAuthentication: false
        )

        await waitUntil("origin receives the rendered enrollment request") {
            if case .awaitingApproval = origin.phase { return true }
            return false
        }
        XCTAssertTrue(installedGrants.isEmpty, "the installer ran before explicit approval")
        XCTAssertTrue(originAuthorizer.reasons.isEmpty, "biometrics ran before explicit approval")
        XCTAssertTrue(originMetadata.record(for: fixture.key.id).remoteInstallations.isEmpty)
        let requesterIntent = try XCTUnwrap(
            requesterMetadata.record(for: fixture.key.id).remoteInstallations.first
        )
        XCTAssertEqual(requesterIntent.hostID, fixture.requesterHost.id)
        XCTAssertEqual(requesterIntent.verificationState, .uncertain)
        XCTAssertEqual(
            requesterIntent.routeIdentity,
            RemoteAccessRouteIdentity.value(for: Host(from: fixture.requesterHost))
        )

        origin.approve()

        await waitUntil("both coordinators reach final completion") {
            guard case .completed = requester.phase,
                  case .completed = origin.phase else { return false }
            return true
        }

        XCTAssertEqual(originAuthorizer.reasons.count, 1)
        XCTAssertEqual(requesterAuthorizer.reasons.count, 0)
        XCTAssertEqual(grantEngine.authorizationRequestCount, 1)
        XCTAssertEqual(grantEngine.installationAttemptCount, 1)
        XCTAssertEqual(authCountSeenByInstaller, 1, "installer crossed the grant boundary before fresh auth")
        XCTAssertEqual(installedGrants.count, 1)
        XCTAssertEqual(completedHosts, [fixture.requesterHost.id])

        let installed = try XCTUnwrap(installedGrants.first)
        XCTAssertEqual(installed.hostID, fixture.originHost.id)
        XCTAssertEqual(installed.host, fixture.originHost)
        XCTAssertEqual(installed.hostLabel, fixture.originHost.name)
        XCTAssertEqual(installed.endpoint, "\(fixture.originHost.address):\(fixture.originHost.port)")
        XCTAssertEqual(installed.peerDeviceName, UIDevice.current.name)
        XCTAssertEqual(installed.flow, .enrollment)
        XCTAssertEqual(installed.publicKey, fixture.publicKey)
        XCTAssertEqual(installed.authorizedKeysLine, fixture.publicKey.authorizedKeysLine)

        guard case .completed(let requesterName) = requester.phase,
              case .completed(let originName) = origin.phase else {
            return XCTFail("coordinators left their completed phases")
        }
        XCTAssertEqual(requesterName, fixture.requesterHost.name)
        XCTAssertEqual(originName, fixture.originHost.name)

        let requesterInstallation = try XCTUnwrap(
            requesterMetadata.record(for: fixture.key.id).remoteInstallations.first
        )
        XCTAssertEqual(requesterInstallation.hostID, fixture.requesterHost.id)
        XCTAssertEqual(requesterInstallation.peerDeviceName, "Origin iPad")
        XCTAssertEqual(requesterInstallation.direction, .receivedFromPeer)
        XCTAssertEqual(requesterInstallation.flow, .enrollment)
        XCTAssertEqual(requesterInstallation.verificationState, .verified)
        XCTAssertEqual(
            requesterInstallation.routeIdentity,
            RemoteAccessRouteIdentity.value(for: Host(from: fixture.requesterHost))
        )
        XCTAssertEqual(requesterInstallation.publicKeyFingerprint, fixture.publicKey.fingerprint)
        XCTAssertEqual(requesterInstallation.authorizedKeysLine, fixture.publicKey.authorizedKeysLine)

        let originInstallation = try XCTUnwrap(
            originMetadata.record(for: fixture.key.id).remoteInstallations.first
        )
        XCTAssertEqual(originInstallation.hostID, fixture.originHost.id)
        XCTAssertEqual(originInstallation.peerDeviceName, UIDevice.current.name)
        XCTAssertEqual(originInstallation.direction, .grantedToPeer)
        XCTAssertEqual(originInstallation.flow, .enrollment)
        XCTAssertEqual(originInstallation.verificationState, .verified)
        XCTAssertEqual(originInstallation.publicKeyFingerprint, fixture.publicKey.fingerprint)
        XCTAssertEqual(originInstallation.authorizedKeysLine, fixture.publicKey.authorizedKeysLine)

        let persistedHost = try XCTUnwrap(
            try fixture.context.fetch(FetchDescriptor<PersistedHost>()).first {
                $0.id == fixture.requesterHost.id
            }
        )
        guard case .key(let persistedKeyID) = persistedHost.identity?.credentialMode else {
            return XCTFail("requester did not durably bind the enrolled key identity")
        }
        XCTAssertEqual(persistedKeyID, fixture.key.id)
    }

    func testBiometricDenialNeverReachesInstallerOrEitherLedger() async throws {
        let streams = makeDuplexPair()
        let fixture = try makeFixture(
            requesterInput: streams.firstInput,
            requesterOutput: streams.firstOutput
        )
        let requesterSuite = "EnrollmentCoordinatorTests.denied.requester.\(UUID().uuidString)"
        let originSuite = "EnrollmentCoordinatorTests.denied.origin.\(UUID().uuidString)"
        let requesterDefaults = try XCTUnwrap(UserDefaults(suiteName: requesterSuite))
        let originDefaults = try XCTUnwrap(UserDefaults(suiteName: originSuite))
        defer {
            requesterDefaults.removePersistentDomain(forName: requesterSuite)
            originDefaults.removePersistentDomain(forName: originSuite)
        }
        let requesterMetadata = KeySecurityMetadataStore(
            defaults: requesterDefaults,
            storageKey: "requester-denied"
        )
        let originMetadata = KeySecurityMetadataStore(
            defaults: originDefaults,
            storageKey: "origin-denied"
        )
        let originAuthorizer = Authorizer(decision: .denied)
        var installCount = 0
        let grantEngine = SyncDeviceAccessGrantEngine(
            testInstaller: { _ in installCount += 1 }
        )
        let requester = EnrollmentCoordinator(
            metadata: requesterMetadata,
            authorizer: Authorizer(decision: .denied),
            deviceKeyProvider: { _ in fixture.key }
        )
        let origin = EnrollmentCoordinator(
            metadata: originMetadata,
            authorizer: originAuthorizer,
            grantEngine: grantEngine
        )

        origin.acceptOriginStreams(
            input: streams.secondInput,
            output: streams.secondOutput,
            focusedHost: fixture.originHost
        )
        requester.requestAuthorization(
            through: fixture.activity,
            for: fixture.requesterHost,
            authorizationHostID: fixture.originHost.id,
            in: fixture.context,
            defaultKeyUseOwnerAuthentication: false
        )
        await waitUntil("origin receives the request before denial") {
            if case .awaitingApproval = origin.phase { return true }
            return false
        }

        origin.approve()

        await waitUntil("denial becomes terminal on both coordinators") {
            guard case .failed = requester.phase,
                  case .failed = origin.phase else { return false }
            return true
        }
        XCTAssertEqual(originAuthorizer.reasons.count, 1)
        XCTAssertEqual(grantEngine.authorizationRequestCount, 1)
        XCTAssertEqual(grantEngine.installationAttemptCount, 0)
        XCTAssertEqual(installCount, 0)
        XCTAssertTrue(originMetadata.record(for: fixture.key.id).remoteInstallations.isEmpty)
        XCTAssertTrue(requesterMetadata.record(for: fixture.key.id).remoteInstallations.isEmpty)
        XCTAssertNil(fixture.requesterHost.identity)
    }

    func testDelayedCallbackFromCancelledAttemptCannotOverwriteRetry() async throws {
        let retryStreams = makeDuplexPair()
        let fixture = try makeFixture(
            requesterInput: retryStreams.firstInput,
            requesterOutput: retryStreams.firstOutput
        )
        let suite = "EnrollmentCoordinatorTests.delayed-streams.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = KeySecurityMetadataStore(
            defaults: defaults,
            storageKey: "delayed-streams"
        )
        let requester = EnrollmentCoordinator(
            metadata: metadata,
            authorizer: Authorizer(decision: .denied),
            deviceKeyProvider: { _ in fixture.key }
        )
        let origin = EnrollmentCoordinator(
            metadata: KeySecurityMetadataStore(
                defaults: defaults,
                storageKey: "delayed-streams-origin"
            ),
            authorizer: Authorizer(decision: .fresh),
            grantEngine: SyncDeviceAccessGrantEngine(testInstaller: { _ in })
        )
        let staleActivity = DeferredContinuationActivity()
        let retryActivity = DeferredContinuationActivity()
        let staleInput = InputStream(data: Data())
        let staleOutput = OutputStream(toMemory: ())
        staleInput.open()
        staleOutput.open()

        requester.requestAuthorization(
            through: staleActivity,
            for: fixture.requesterHost,
            authorizationHostID: fixture.originHost.id,
            in: fixture.context,
            defaultKeyUseOwnerAuthentication: false
        )
        await waitUntil("first attempt requests continuation streams") {
            staleActivity.isWaitingForStreams
        }
        guard case .openingStreams = requester.phase else {
            return XCTFail("first attempt did not wait for its delayed callback")
        }
        requester.cancel()
        requester.dismissTerminalState()

        requester.requestAuthorization(
            through: retryActivity,
            for: fixture.requesterHost,
            authorizationHostID: fixture.originHost.id,
            in: fixture.context,
            defaultKeyUseOwnerAuthentication: false
        )
        origin.acceptOriginStreams(
            input: retryStreams.secondInput,
            output: retryStreams.secondOutput,
            focusedHost: fixture.originHost
        )
        await waitUntil("retry requests continuation streams") {
            retryActivity.isWaitingForStreams
        }
        retryActivity.deliver(
            input: retryStreams.firstInput,
            output: retryStreams.firstOutput
        )
        await waitUntil("retry reaches the origin") {
            if case .awaitingApproval = origin.phase { return true }
            return false
        }

        // Attempt A completes only after attempt B is live. It must close its
        // streams and leave B's service/transport untouched.
        staleActivity.deliver(
            input: staleInput,
            output: staleOutput
        )
        await Task.yield()
        XCTAssertEqual(staleInput.streamStatus, .closed)
        XCTAssertEqual(staleOutput.streamStatus, .closed)

        origin.reject()
        await waitUntil("valid retry processes the explicit rejection") {
            requester.phase == .rejected
        }
        XCTAssertTrue(
            metadata.record(for: fixture.key.id).remoteInstallations.isEmpty,
            "an explicit rejection proves the retry never installed its staged intent"
        )
    }

    func testRequesterIntentSurvivesAmbiguousCancellationAndFreshStoreRead() async throws {
        let streams = makeDuplexPair()
        let fixture = try makeFixture(
            requesterInput: streams.firstInput,
            requesterOutput: streams.firstOutput
        )
        let suite = "EnrollmentCoordinatorTests.ambiguous-intent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "ambiguous-intent"
        let metadata = KeySecurityMetadataStore(defaults: defaults, storageKey: storageKey)
        let requester = EnrollmentCoordinator(
            metadata: metadata,
            authorizer: Authorizer(decision: .denied),
            deviceKeyProvider: { _ in fixture.key }
        )
        let origin = EnrollmentCoordinator(
            metadata: KeySecurityMetadataStore(
                defaults: defaults,
                storageKey: "ambiguous-intent-origin"
            ),
            authorizer: Authorizer(decision: .fresh),
            grantEngine: SyncDeviceAccessGrantEngine(testInstaller: { _ in })
        )
        origin.acceptOriginStreams(
            input: streams.secondInput,
            output: streams.secondOutput,
            focusedHost: fixture.originHost
        )
        requester.requestAuthorization(
            through: fixture.activity,
            for: fixture.requesterHost,
            authorizationHostID: fixture.originHost.id,
            peerDeviceName: "Origin iPad",
            in: fixture.context,
            defaultKeyUseOwnerAuthentication: false
        )
        await waitUntil("request is sent before interruption") {
            if case .awaitingApproval = origin.phase { return true }
            return false
        }

        requester.applicationDidEnterBackground()
        XCTAssertEqual(requester.phase, .cancelled)

        // A fresh metadata store models process relaunch. Cancellation/transport
        // loss cannot prove whether a remote mutation won its race, so the
        // requester must retain the recoverable uncertain row.
        let reloaded = KeySecurityMetadataStore(defaults: defaults, storageKey: storageKey)
        let intent = try XCTUnwrap(
            reloaded.record(for: fixture.key.id).remoteInstallations.first
        )
        XCTAssertEqual(intent.hostID, fixture.requesterHost.id)
        XCTAssertEqual(intent.verificationState, .uncertain)
        XCTAssertEqual(intent.peerDeviceName, "Origin iPad")
        XCTAssertEqual(
            intent.routeIdentity,
            RemoteAccessRouteIdentity.value(for: Host(from: fixture.requesterHost))
        )
        XCTAssertNil(fixture.requesterHost.identity)
    }

    func testRequesterRefusesRepointedHostWhenOlderTrackedAccessWouldBeLost() async throws {
        let streams = makeDuplexPair()
        let fixture = try makeFixture(
            requesterInput: streams.firstInput,
            requesterOutput: streams.firstOutput
        )
        let suite = "EnrollmentCoordinatorTests.repointed-ledger.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = KeySecurityMetadataStore(
            defaults: defaults,
            storageKey: "repointed-ledger"
        )
        metadata.recordRemoteInstallation(
            keyID: fixture.key.id,
            hostID: fixture.requesterHost.id,
            hostLabel: "Old Helios",
            endpoint: "dev@old-helios.example:22",
            routeIdentity: "old-frozen-route",
            peerDeviceName: "Earlier iPad",
            direction: .receivedFromPeer,
            flow: .enrollment,
            verificationState: .verified,
            publicKeyFingerprint: fixture.publicKey.fingerprint,
            authorizedKeysLine: fixture.publicKey.authorizedKeysLine
        )
        let requester = EnrollmentCoordinator(
            metadata: metadata,
            authorizer: Authorizer(decision: .denied),
            deviceKeyProvider: { _ in fixture.key }
        )

        requester.requestAuthorization(
            through: fixture.activity,
            for: fixture.requesterHost,
            authorizationHostID: fixture.originHost.id,
            peerDeviceName: "New iPad",
            in: fixture.context,
            defaultKeyUseOwnerAuthentication: false
        )
        await waitUntil("repointed ledger fails before request send") {
            if case .failed = requester.phase { return true }
            return false
        }

        let preserved = try XCTUnwrap(
            metadata.record(for: fixture.key.id).remoteInstallations.first
        )
        XCTAssertEqual(preserved.routeIdentity, "old-frozen-route")
        XCTAssertEqual(preserved.peerDeviceName, "Earlier iPad")
        XCTAssertEqual(preserved.verificationState, .verified)
    }

    private func makeFixture(
        requesterInput: InputStream,
        requesterOutput: OutputStream
    ) throws -> Fixture {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let originHostID = UUID()
        let requesterHost = PersistedHost(
            id: UUID(),
            name: "Helios",
            address: "helios.example",
            port: 2222,
            autoTmux: false,
            transport: .ssh,
            launchMode: .customCommand
        )
        requesterHost.user = "dev"

        let publicKey = makePublicKey()
        let key = StoredKey(
            id: publicKey.id,
            name: "Tessera device key",
            algorithm: .ecdsaP256,
            authorizedKeysLine: publicKey.authorizedKeysLine,
            requiresBiometric: true
        )
        key.isSecureEnclave = true
        context.insert(requesterHost)
        context.insert(key)
        try context.save()

        return Fixture(
            container: container,
            context: context,
            requesterHost: requesterHost,
            originHost: Host(
                id: originHostID,
                name: "Helios",
                address: "helios.example",
                port: 2222,
                user: "dev",
                transport: .ssh,
                autoTmux: false,
                launchMode: .customCommand
            ),
            key: key,
            publicKey: publicKey,
            activity: ContinuationActivity(
                input: requesterInput,
                output: requesterOutput
            )
        )
    }

    private func makePublicKey() -> EnrollmentPublicKey {
        var blob = Data()
        appendSSHString(Data(EnrollmentPublicKeyAlgorithm.secureEnclaveP256.rawValue.utf8), to: &blob)
        appendSSHString(Data("nistp256".utf8), to: &blob)
        appendSSHString(Data([0x04]) + Data(repeating: 0x37, count: 64), to: &blob)
        return EnrollmentPublicKey(
            id: UUID(),
            displayName: "Tessera device key",
            algorithm: .secureEnclaveP256,
            blob: blob.base64EncodedString(),
            fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blob),
            protection: .secureEnclave
        )
    }

    private func appendSSHString(_ value: Data, to blob: inout Data) {
        var length = UInt32(value.count).bigEndian
        blob.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        blob.append(value)
    }

    private func makeDuplexPair(capacity: Int = 64 * 1024) -> (
        firstInput: InputStream,
        firstOutput: OutputStream,
        secondInput: InputStream,
        secondOutput: OutputStream
    ) {
        let firstInbound = makeBoundPair(capacity: capacity)
        let secondInbound = makeBoundPair(capacity: capacity)
        return (
            firstInput: firstInbound.input,
            firstOutput: secondInbound.output,
            secondInput: secondInbound.input,
            secondOutput: firstInbound.output
        )
    }

    private func makeBoundPair(capacity: Int) -> (input: InputStream, output: OutputStream) {
        var read: Unmanaged<CFReadStream>?
        var write: Unmanaged<CFWriteStream>?
        CFStreamCreateBoundPair(nil, &read, &write, capacity)
        return (
            read!.takeRetainedValue() as InputStream,
            write!.takeRetainedValue() as OutputStream
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }
}
