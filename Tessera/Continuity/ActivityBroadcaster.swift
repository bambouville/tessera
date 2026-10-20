import Foundation
import Observation
import TesseraAppleContinuity

/// Apple-app adapter for the shared Handoff publisher. Session focus and
/// lifecycle remain app-owned; exact activity bytes, replacement, identity,
/// and invalidation semantics live in `TesseraAppleContinuity` so the macOS
/// bridge can use the same implementation.
@MainActor
@Observable
final class ActivityBroadcaster {
    static let activityType = AppleContinuationActivityContract.activityType
    static let descriptorKey = AppleContinuationActivityContract.descriptorKey

    typealias ContinuationStreamHandler = AppleContinuationStreamHandler

    private(set) var isBroadcasting = false
    private(set) var lastFailure: String?
    private(set) var publicationGeneration = 0

    var onContinuationStreams: ContinuationStreamHandler? {
        didSet { reconcile() }
    }

    private let publisher = AppleContinuationActivityPublisher()
    private var descriptor: SessionActivityDescriptor?
    private var enabled = true
    private var applicationActive = true
    private var locked = false

    /// The already validated focused-session descriptor. Pairing-v1 reads this
    /// only after the user explicitly chooses to continue that focused session
    /// on another device; it is never a credential or a connection trigger.
    var currentDescriptor: SessionActivityDescriptor? { descriptor }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        reconcile()
    }

    func setApplicationActive(_ active: Bool) {
        applicationActive = active
        reconcile()
    }

    func setLocked(_ locked: Bool) {
        self.locked = locked
        reconcile()
    }

    func publish(_ descriptor: SessionActivityDescriptor?) {
        self.descriptor = descriptor
        reconcile()
    }

    /// Matches the released app behavior: invalidate only the current
    /// `NSUserActivity`, retaining the focused descriptor for a later
    /// lifecycle reconciliation.
    func invalidate() {
        publisher.invalidateCurrentActivity()
        synchronizePublishedState()
    }

    func clearLastFailure() {
        lastFailure = nil
    }

    func reportFailure(_ message: String) {
        descriptor = nil
        publisher.clearPublication()
        synchronizePublishedState()
        lastFailure = message
    }

    private func reconcile() {
        // Clear the retained request before touching any publisher property
        // whose setter reconciles. Otherwise publish(nil) after an explicit
        // invalidation could briefly resurrect the old activity.
        guard let descriptor else {
            publisher.clearPublication()
            publisher.configure(
                enabled: enabled,
                applicationActive: applicationActive,
                locked: locked,
                onContinuationStreams: onContinuationStreams
            )
            synchronizePublishedState()
            return
        }

        publisher.configure(
            enabled: enabled,
            applicationActive: applicationActive,
            locked: locked,
            onContinuationStreams: onContinuationStreams
        )

        do {
            let data = try descriptor.handoffData()
            let previousGeneration = publisher.publicationGeneration
            try publisher.publish(
                AppleContinuationPublication(
                    descriptorData: data,
                    title: Self.title(for: descriptor),
                    targetContentIdentifier: descriptor.hostID.uuidString
                )
            )
            synchronizePublishedState()
            lastFailure = nil
            if publisher.publicationGeneration != previousGeneration {
                DiagnosticLogStore.appendApp(
                    "continuity broadcast result=current action=\(descriptor.continuationAction.rawValue) bytes=\(data.count)"
                )
            }
        } catch {
            publisher.clearPublication()
            synchronizePublishedState()
            lastFailure = error.localizedDescription
            DiagnosticLogStore.appendApp(
                "continuity broadcast result=rejected error='\(error.localizedDescription)'"
            )
        }
    }

    private func synchronizePublishedState() {
        isBroadcasting = publisher.isPublishing
        publicationGeneration = publisher.publicationGeneration
    }

    static func title(for descriptor: SessionActivityDescriptor) -> String {
        // Whole titles, not a name plus an appended verb: the two forms
        // inflect differently and some languages lead with the action.
        return switch descriptor.continuationAction {
        case .continueSession: String(localized: "\(descriptor.name) — continue session")
        case .reconnect: String(localized: "\(descriptor.name) — reconnect")
        }
    }
}
