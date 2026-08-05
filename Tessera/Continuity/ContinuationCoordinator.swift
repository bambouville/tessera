import Foundation

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

    @discardableResult
    func receive(_ activity: NSUserActivity, isLocked: Bool) -> Bool {
        guard activity.activityType == ActivityBroadcaster.activityType else {
            return false
        }
        guard let data = activity.userInfo?[ActivityBroadcaster.descriptorKey] as? Data else {
            reject("missing descriptor")
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
        guard ready == nil, stashedWhileLocked == nil, active == nil else {
            lastFailure = "Finish the current continuation before opening another."
            DiagnosticLogStore.appendApp("continuity receive result=rejected-busy")
            return false
        }
        enrollmentActivity = nil
        do {
            let descriptor = try SessionActivityDescriptor(handoffData: data)
            let pending = PendingContinuation(descriptor: descriptor)
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
        } catch {
            reject(error.localizedDescription)
            return false
        }
    }

    func replayAfterUnlock() {
        guard let stashedWhileLocked else { return }
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
        self.ready = nil
        stashedWhileLocked = ready
        DiagnosticLogStore.appendApp(
            "continuity receive result=restashed-on-lock action=\(ready.descriptor.continuationAction.rawValue)"
        )
    }

    func consume(_ id: UUID) {
        guard ready?.id == id else { return }
        active = ready
        ready = nil
    }

    func finishActive() {
        active = nil
        enrollmentActivity = nil
    }

    func cancel() {
        ready = nil
        stashedWhileLocked = nil
        active = nil
        enrollmentActivity = nil
    }

    func clearLastFailure() {
        lastFailure = nil
    }

    private func reject(_ reason: String) {
        ready = nil
        stashedWhileLocked = nil
        active = nil
        lastFailure = reason
        enrollmentActivity = nil
        DiagnosticLogStore.appendApp(
            "continuity receive result=rejected error='\(reason)'"
        )
    }
}
