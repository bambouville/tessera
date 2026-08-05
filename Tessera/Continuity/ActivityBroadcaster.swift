import Foundation

/// Owns the one `NSUserActivity` representing the focused connected session.
/// The broadcaster has no session authority of its own: callers replace or
/// clear the descriptor as focus/lifecycle changes, and lock always forces an
/// invalidation before another activity can become current.
@MainActor
@Observable
final class ActivityBroadcaster: NSObject, NSUserActivityDelegate {
    static let activityType = "com.bambouville.tessera.session"
    static let descriptorKey = "descriptor"

    typealias ContinuationStreamHandler = @MainActor (
        _ input: InputStream,
        _ output: OutputStream
    ) -> Void

    private(set) var isBroadcasting = false
    private(set) var lastFailure: String?
    private(set) var publicationGeneration = 0

    var onContinuationStreams: ContinuationStreamHandler?

    private var activity: NSUserActivity?
    private var descriptor: SessionActivityDescriptor?
    private var publishedDescriptorData: Data?
    private var publishedSupportsStreams = false
    private var enabled = true
    private var applicationActive = true
    private var locked = false

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

    func invalidate() {
        activity?.invalidate()
        activity = nil
        publishedDescriptorData = nil
        publishedSupportsStreams = false
        isBroadcasting = false
    }

    func clearLastFailure() {
        lastFailure = nil
    }

    func reportFailure(_ message: String) {
        descriptor = nil
        invalidate()
        lastFailure = message
    }

    private func reconcile() {
        guard enabled, applicationActive, !locked, let descriptor else {
            invalidate()
            return
        }

        do {
            let data = try descriptor.handoffData()
            let supportsStreams = onContinuationStreams != nil
            if activity != nil,
               isBroadcasting,
               publishedDescriptorData == data,
               publishedSupportsStreams == supportsStreams {
                lastFailure = nil
                return
            }
            let replacement = NSUserActivity(activityType: Self.activityType)
            replacement.title = Self.title(for: descriptor)
            replacement.userInfo = [Self.descriptorKey: data]
            replacement.requiredUserInfoKeys = [Self.descriptorKey]
            replacement.targetContentIdentifier = descriptor.hostID.uuidString
            replacement.isEligibleForHandoff = true
            replacement.isEligibleForSearch = false
            replacement.isEligibleForPublicIndexing = false
            replacement.supportsContinuationStreams = supportsStreams
            replacement.delegate = self

            activity?.invalidate()
            activity = replacement
            publishedDescriptorData = data
            publishedSupportsStreams = supportsStreams
            publicationGeneration += 1
            lastFailure = nil
            replacement.becomeCurrent()
            isBroadcasting = true
            DiagnosticLogStore.appendApp(
                "continuity broadcast result=current action=\(descriptor.continuationAction.rawValue) bytes=\(data.count)"
            )
        } catch {
            invalidate()
            lastFailure = error.localizedDescription
            DiagnosticLogStore.appendApp(
                "continuity broadcast result=rejected error='\(error.localizedDescription)'"
            )
        }
    }

    static func title(for descriptor: SessionActivityDescriptor) -> String {
        let action = switch descriptor.continuationAction {
        case .continueSession: "continue session"
        case .reconnect: "reconnect"
        }
        return "\(descriptor.name) — \(action)"
    }

    nonisolated func userActivity(
        _ userActivity: NSUserActivity,
        didReceive inputStream: InputStream,
        outputStream: OutputStream
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.enabled,
                  self.applicationActive,
                  !self.locked,
                  self.isBroadcasting,
                  self.activity === userActivity,
                  let handler = self.onContinuationStreams
            else {
                inputStream.close()
                outputStream.close()
                return
            }
            // Foundation delivers unopened streams and requires the app to
            // open them immediately. The enrollment transport takes ownership
            // from this point and closes both on every terminal state.
            inputStream.open()
            outputStream.open()
            handler(inputStream, outputStream)
        }
    }
}
