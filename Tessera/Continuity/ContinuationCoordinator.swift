import Foundation
import TesseraContinuityCore

/// Secret-free snapshot of persisted state that can change which host, route,
/// or local credential an accepted continuation will use. Display-only host
/// metadata is deliberately absent so unrelated edits do not invalidate an
/// in-flight receipt.
struct ContinuationSecurityPolicySnapshot: Equatable, Sendable {
    struct HostConnection: Equatable, Sendable {
        let id: UUID
        let user: String
        let address: String
        let port: Int
        let transport: HostTransport
        let launchMode: HostLaunchMode
        let tmuxSessionName: String?
        let launchCommand: String?
        let environment: String
        let startupSnippet: String
        let portForwardRulesData: Data?
    }

    struct JumpLink: Equatable, Sendable {
        let hostID: UUID
        let jumpHostID: UUID
    }

    enum Credential: Equatable, Sendable {
        case none(identityID: UUID?)
        case password(identityID: UUID)
        case key(
            identityID: UUID,
            keyID: UUID,
            algorithm: String?,
            authorizedKeysLine: String?,
            requiresBiometric: Bool?,
            isSecureEnclave: Bool?
        )
        case legacyDevKey(identityID: UUID, filename: String)
    }

    struct HostCredential: Equatable, Sendable {
        let hostID: UUID
        let credential: Credential
    }

    let hostConnections: [HostConnection]
    let jumpLinks: [JumpLink]
    let hostCredentials: [HostCredential]
    let requiresBiometricForKeyUse: Bool
    let passwordCredentialRevision: UInt64

    /// Credential creation/selection is the expected transition while the
    /// continuation is stopped at `needsCredential`. Only that narrow delta
    /// may be adopted. Endpoint, launch, forwarding, route, and global owner-
    /// presence policy changes always invalidate the accepted receipt.
    func invalidates(
        replacing previous: Self,
        allowingCredentialCompletionFor allowedHostID: UUID?
    ) -> Bool {
        guard hostConnections == previous.hostConnections,
              jumpLinks == previous.jumpLinks,
              requiresBiometricForKeyUse == previous.requiresBiometricForKeyUse
        else { return true }

        guard let allowedHostID else {
            return hostCredentials != previous.hostCredentials
                || passwordCredentialRevision != previous.passwordCredentialRevision
        }

        let currentByHost = Dictionary(
            uniqueKeysWithValues: hostCredentials.map { ($0.hostID, $0.credential) }
        )
        let previousByHost = Dictionary(
            uniqueKeysWithValues: previous.hostCredentials.map { ($0.hostID, $0.credential) }
        )
        let changedHostIDs = Set(currentByHost.keys)
            .union(previousByHost.keys)
            .filter { currentByHost[$0] != previousByHost[$0] }
        guard changedHostIDs.allSatisfy({ $0 == allowedHostID }) else {
            return true
        }

        if passwordCredentialRevision != previous.passwordCredentialRevision {
            guard case .password? = currentByHost[allowedHostID] else {
                return true
            }
        }
        return false
    }
}

/// Single production decision point for Enrollment's SwiftData/UserDefaults
/// policy observers. Keeping this wrapper beside the semantic snapshot lets
/// focused tests exercise the exact hook that ContentView calls, including the
/// requester's one permitted credential-persistence transition.
enum EnrollmentSecurityPolicyMonitor {
    static func invalidates(
        _ current: ContinuationSecurityPolicySnapshot,
        replacing previous: ContinuationSecurityPolicySnapshot,
        expectedCredentialMutationHostID: UUID?
    ) -> Bool {
        current.invalidates(
            replacing: previous,
            allowingCredentialCompletionFor: expectedCredentialMutationHostID
        )
    }
}

struct PendingContinuation: Identifiable, Equatable, Sendable {
    let id: UUID
    let descriptor: SessionActivityDescriptor
    let receivedAt: Date

    init(
        id: UUID = UUID(),
        descriptor: SessionActivityDescriptor,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.descriptor = descriptor
        self.receivedAt = receivedAt
    }
}

struct ContinuationDraftRecoveryRecord: Codable, Equatable, Sendable {
    var hostIDs: [UUID]
    var identityIDs: [UUID]
}

/// Crash-safe marker for the SwiftData rows created before a user confirms a
/// never-seen Handoff host. SwiftData autosaves, so an in-memory Cancel path is
/// insufficient: without this marker, terminating the process in the editor
/// could turn an unconfirmed descriptor into a saved fast-path host.
struct ContinuationDraftRecoveryStore {
    static let defaultKey = "tessera.continuationDraftRecovery.v1"

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func stage(hostIDs: Set<UUID>) {
        save(ContinuationDraftRecoveryRecord(
            hostIDs: hostIDs.sorted { $0.uuidString < $1.uuidString },
            identityIDs: []
        ))
    }

    func registerCreatedIdentity(_ id: UUID) {
        guard var record = load(), !record.identityIDs.contains(id) else { return }
        record.identityIDs.append(id)
        record.identityIDs.sort { $0.uuidString < $1.uuidString }
        save(record)
    }

    func load() -> ContinuationDraftRecoveryRecord? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(
            ContinuationDraftRecoveryRecord.self,
            from: data
        )
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    private func save(_ record: ContinuationDraftRecoveryRecord) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

/// Decodes incoming activities and enforces the app-lock boundary before any
/// resolver or connection code sees them. Receiving a Handoff activity is the
/// system-level user tap; replaying it after unlock preserves that same intent.
@MainActor
@Observable
final class ContinuationCoordinator {
    private(set) var ready: PendingContinuation?
    private(set) var stashedWhileLocked: PendingContinuation?
    private(set) var active: PendingContinuation?
    private(set) var lastFailure: String?
    /// Retained only for the explicit credential-card enrollment action.
    /// DEBUG descriptor injection and decoded data never synthesize this
    /// Apple-bound channel authority.
    private(set) var enrollmentActivity: NSUserActivity?
    /// The app still exposes its established observable presentation state,
    /// but ordering, peer binding, decoding, and lock transitions are owned by
    /// the transport-neutral core used by Android and Mac adapters too.
    private var core = ContinuationReceiveStateMachine()
    private var policyGeneration: UInt64 = 1

    /// Pairing-v1 uses the exact in-process authenticated binding supplied by
    /// the shared runtime. Apple Handoff remains the default for the released
    /// activity entry point below.
    var onDurableAcceptance: ((UUID, UUID) -> Void)?
    var onConnectionReceipt: ((UUID, UUID) -> Void)?

    var sharedState: ContinuationReceiveState { core.state }
    var sharedLastFailure: ContinuationReceiveError? { core.lastFailure }

    @discardableResult
    func receive(_ activity: NSUserActivity, isLocked: Bool) -> Bool {
        guard activity.activityType == ActivityBroadcaster.activityType else {
            return false
        }
        guard let data = activity.userInfo?[ActivityBroadcaster.descriptorKey] as? Data else {
            // Consult the shared authority before projecting a malformed Apple
            // activity. If a valid continuation is already pending, this is a
            // busy rejection and must not discard its first-use stream.
            do {
                _ = try core.receiveDescriptor(
                    Data(),
                    transportBinding: .appleAccountHandoff,
                    isLocked: isLocked,
                    policyGeneration: policyGeneration
                )
            } catch ContinuationReceiveError.busy {
                recordBusyReceive()
                return false
            } catch {
                recordTerminalCoreFailure("missing descriptor")
                return false
            }
            return false
        }
        let accepted = receive(data: data, isLocked: isLocked)
        if accepted {
            enrollmentActivity = activity
        }
        return accepted
    }

    @discardableResult
    func receive(data: Data, isLocked: Bool) -> Bool {
        receive(
            data: data,
            transportBinding: .appleAccountHandoff,
            isLocked: isLocked
        )
    }

    /// Accepts a descriptor carried by an already authenticated non-Apple
    /// transport. The binding is process-local, supplied by Pairing-v1, and is
    /// never decoded from the descriptor bytes themselves.
    @discardableResult
    func receive(
        data: Data,
        transportBinding: ContinuationTransportBinding,
        isLocked: Bool
    ) -> Bool {
        do {
            let received = try core.receiveDescriptor(
                data,
                transportBinding: transportBinding,
                isLocked: isLocked,
                policyGeneration: policyGeneration
            )
            // A successful raw-data receive has no Apple continuation-stream
            // authority. Clear the prior activity only after the shared core
            // accepts it; busy rejection must retain the original user tap.
            enrollmentActivity = nil
            let descriptor = SessionActivityDescriptor(core: received.descriptor)
            let pending = PendingContinuation(
                id: received.id,
                descriptor: descriptor,
                receivedAt: received.receivedAt
            )
            lastFailure = nil
            if isLocked {
                stashedWhileLocked = pending
                ready = nil
                DiagnosticLogStore.appendApp(
                    "continuity receive result=stashed-locked action=\(descriptor.continuationAction.rawValue)"
                )
            } else {
                ready = pending
                stashedWhileLocked = nil
                DiagnosticLogStore.appendApp(
                    "continuity receive result=ready action=\(descriptor.continuationAction.rawValue)"
                )
            }
            return true
        } catch ContinuationReceiveError.busy {
            recordBusyReceive()
            return false
        } catch ContinuationReceiveError.invalidDescriptor(let detail) {
            recordTerminalCoreFailure(
                detail?.localizedDescription
                    ?? String(localized: "The continuation descriptor is invalid.")
            )
            return false
        } catch {
            reject(localizedMessage(for: error))
            return false
        }
    }

    func replayAfterUnlock() {
        guard let stashedWhileLocked else { return }
        do {
            try core.unlock()
        } catch {
            reject(String(localized: "The continuation could not be resumed after unlock."))
            return
        }
        self.stashedWhileLocked = nil
        ready = stashedWhileLocked
        DiagnosticLogStore.appendApp(
            "continuity receive result=replayed-after-unlock action=\(stashedWhileLocked.descriptor.continuationAction.rawValue)"
        )
    }

    /// Closes the foreground-lock race by moving an unhandled activity behind
    /// the same unlock boundary used when it originally arrived locked.
    func applicationDidLock() {
        guard let ready else { return }
        core.applicationDidLock()
        self.ready = nil
        stashedWhileLocked = ready
        DiagnosticLogStore.appendApp(
            "continuity receive result=restashed-on-lock action=\(ready.descriptor.continuationAction.rawValue)"
        )
    }

    func consume(_ id: UUID) {
        guard ready?.id == id else { return }
        do {
            _ = try core.consume(id, policyGeneration: policyGeneration)
        } catch {
            reject(String(localized: "The continuation is no longer current."))
            return
        }
        active = ready
        ready = nil
    }

    /// Runs UUID/typed-route resolution inside the shared state authority and
    /// maps its secret-free result back to the existing Apple Host DTO.
    func resolve(
        _ id: UUID,
        among candidates: [ContinuationHostCandidate],
        hasSavedHost: (UUID) -> Bool
    ) -> ContinuationResolution? {
        guard active?.id == id else { return nil }
        let mapped = candidates.compactMap { candidate in
            candidate.sharedCandidate.map { (app: candidate, core: $0) }
        }
        do {
            let resolution = try core.resolve(
                among: mapped.map(\.core),
                hasSavedHost: hasSavedHost
            )
            switch resolution {
            case .fastPath(let profile):
                return mapped.first(where: { $0.app.host.id == profile.id })
                    .map { .fastPath($0.app.host) }
            case .endpointMatch(let profile):
                return mapped.first(where: { $0.app.host.id == profile.id })
                    .map { .endpointMatch($0.app.host) }
            case .prefill(let descriptor):
                return .prefill(SessionActivityDescriptor(core: descriptor))
            }
        } catch {
            reject(localizedMessage(for: error))
            return nil
        }
    }

    func hostAdmissionCompleted(
        continuationID: UUID,
        admittedHostID: UUID,
        insertedHostIDs: Set<UUID>
    ) -> Bool {
        do {
            try core.hostAdmissionCompleted(
                continuationID: continuationID,
                admittedHostID: admittedHostID,
                insertedHostIDs: insertedHostIDs,
                policyGeneration: policyGeneration
            )
            return true
        } catch {
            reject(localizedMessage(for: error))
            return false
        }
    }

    func hostAdmissionDenied() {
        do {
            try core.hostAdmissionDenied()
        } catch {
            reject(localizedMessage(for: error))
        }
    }

    func credentialEnrollmentCompleted(
        continuationID: UUID,
        hostID: UUID
    ) -> Bool {
        do {
            try core.credentialEnrollmentCompleted(
                continuationID: continuationID,
                hostID: hostID,
                policyGeneration: policyGeneration
            )
            onDurableAcceptance?(continuationID, hostID)
            return true
        } catch {
            reject(localizedMessage(for: error))
            return false
        }
    }

    func credentialEnrollmentFailed() {
        do {
            try core.credentialEnrollmentFailed()
        } catch {
            reject(localizedMessage(for: error))
        }
    }

    func connectionCompleted(continuationID: UUID, hostID: UUID) -> Bool {
        do {
            _ = try core.connectionCompleted(
                continuationID: continuationID,
                hostID: hostID,
                policyGeneration: policyGeneration
            )
            onConnectionReceipt?(continuationID, hostID)
            return true
        } catch {
            reject(localizedMessage(for: error))
            return false
        }
    }

    func connectionFailed() {
        do {
            try core.connectionFailed()
        } catch {
            reject(localizedMessage(for: error))
        }
    }

    /// Host/credential/route policy edits may invalidate unconsumed work. App
    /// lock deliberately does not call this after consume, matching released
    /// iOS behavior where the resulting session follows normal lock lifecycle.
    func securityPolicyChanged() {
        policyGeneration &+= 1
        if policyGeneration == 0 { policyGeneration = 1 }
        core.securityPolicyChanged(to: policyGeneration)
        if case .failed = core.state {
            recordTerminalCoreFailure(
                String(localized: "The continuation is no longer current.")
            )
        }
    }

    func finishActive() {
        active = nil
        enrollmentActivity = nil
        core.reset()
    }

    func cancel() {
        ready = nil
        stashedWhileLocked = nil
        active = nil
        enrollmentActivity = nil
        core.cancel()
    }

    /// Cancels only a Pairing-v1-delivered continuation. A concurrent Apple
    /// Handoff has independent user intent and must never be cleared merely
    /// because a QR attempt ended or the app was locked.
    func cancel(continuationID: UUID) {
        guard ready?.id == continuationID
                || stashedWhileLocked?.id == continuationID
                || active?.id == continuationID
        else { return }
        cancel()
    }

    func clearLastFailure() {
        lastFailure = nil
        // A malformed delivery never acquired an Apple activity/stream
        // authority. Once the UI has consumed its structured error, release
        // that nil-ID receipt so a later valid Handoff is not denied forever.
        // Failures belonging to an accepted activity retain their authority
        // until `finishActive()` instead.
        if enrollmentActivity == nil,
           case .failed(nil, _) = core.state {
            core.reset()
        }
    }

    private func reject(_ reason: String) {
        ready = nil
        stashedWhileLocked = nil
        active = nil
        lastFailure = reason
        enrollmentActivity = nil
        core.reset()
        DiagnosticLogStore.appendApp(
            "continuity receive result=rejected error='\(reason)'"
        )
    }

    /// Decode, authentication, and policy failures are already terminalized by
    /// the shared machine. Preserve that structured state and error for
    /// diagnostics and platform-neutral callers while projecting only the
    /// localized message into the Apple UI. The terminal receipt remains busy
    /// until the owning presentation calls `finishActive()`.
    private func recordTerminalCoreFailure(_ reason: String) {
        ready = nil
        stashedWhileLocked = nil
        active = nil
        lastFailure = reason
        // If the core terminalized a receipt that had already been accepted,
        // keep the first activity as the only continuation-stream authority
        // until `finishActive()` explicitly releases the receipt. A malformed
        // first delivery never reaches the assignment in `receive(_:)`, so it
        // has no activity to retain here.
        DiagnosticLogStore.appendApp(
            "continuity receive result=rejected error='\(reason)'"
        )
    }

    private func recordBusyReceive() {
        lastFailure = String(localized: "Finish the current continuation before opening another.")
        DiagnosticLogStore.appendApp("continuity receive result=rejected-busy")
    }

    private func localizedMessage(for error: Error) -> String {
        guard let error = error as? ContinuationReceiveError else {
            return String(localized: "The continuation could not be completed.")
        }
        switch error {
        case .busy:
            return String(localized: "Finish the current continuation before opening another.")
        case .invalidDescriptor(let detail):
            return detail?.localizedDescription
                ?? String(localized: "The continuation descriptor is invalid.")
        case .unauthenticatedTransport:
            return String(localized: "The continuation channel could not be authenticated.")
        case .stalePolicy:
            return String(localized: "The continuation is no longer current.")
        case .mismatchedContinuation, .mismatchedHost, .invalidTransition:
            return String(localized: "The continuation could not be completed safely.")
        }
    }
}
