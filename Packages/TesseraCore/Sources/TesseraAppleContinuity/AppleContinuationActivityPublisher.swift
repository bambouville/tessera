import Foundation
import TesseraProtocolCore

public enum AppleContinuationActivityContract {
    public static let activityType = ContinuationActivityCodec.activityType
    public static let descriptorKey = ContinuationActivityCodec.descriptorKey
}

public struct AppleContinuationPublication: Equatable, Sendable {
    public let descriptorData: Data
    public let title: String
    public let targetContentIdentifier: String

    public init(
        descriptorData: Data,
        title: String,
        targetContentIdentifier: String
    ) {
        self.descriptorData = descriptorData
        self.title = title
        self.targetContentIdentifier = targetContentIdentifier
    }
}

public typealias AppleContinuationStreamHandler = @MainActor (
    _ input: InputStream,
    _ output: OutputStream
) -> Void

/// Foundation-only Handoff publication owner shared by the iOS/iPadOS app and
/// the macOS Bridge. Platform adapters supply localized titles and lifecycle
/// gates; this class owns exact activity bytes, replacement, invalidation, and
/// continuation-stream identity checks.
@MainActor
public final class AppleContinuationActivityPublisher: NSObject,
    NSUserActivityDelegate {
    public static let activityType = AppleContinuationActivityContract.activityType
    public static let descriptorKey = AppleContinuationActivityContract.descriptorKey

    public private(set) var isPublishing = false
    public private(set) var publicationGeneration = 0
    public private(set) var requestedPublication: AppleContinuationPublication?
    public private(set) var currentUserActivity: NSUserActivity?

    public var onContinuationStreams: AppleContinuationStreamHandler? {
        didSet { reconcile() }
    }

    private var enabled = true
    private var applicationActive = true
    private var locked = false
    private var publishedRequest: AppleContinuationPublication?
    private var publishedSupportsStreams = false

    public override init() {
        super.init()
    }

    /// Applies the full lifecycle/stream configuration as one state change.
    /// Adapters use this instead of assigning the stream handler and three
    /// gates separately: a retained descriptor must never be reconciled
    /// against a half-updated configuration and briefly become current while
    /// the app is locked, inactive, or disabling Handoff.
    public func configure(
        enabled: Bool,
        applicationActive: Bool,
        locked: Bool,
        onContinuationStreams: AppleContinuationStreamHandler?
    ) {
        self.enabled = enabled
        self.applicationActive = applicationActive
        self.locked = locked
        self.onContinuationStreams = onContinuationStreams
        // The property observer above reconciles after every stored value has
        // been assigned. Keep an explicit reconcile for the nil-to-nil case,
        // whose observer still runs today but is not part of this API's
        // correctness contract.
        reconcile()
    }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        reconcile()
    }

    public func setApplicationActive(_ active: Bool) {
        applicationActive = active
        reconcile()
    }

    public func setLocked(_ locked: Bool) {
        self.locked = locked
        reconcile()
    }

    /// Validates the frozen descriptor before it can become Handoff state.
    public func publish(_ publication: AppleContinuationPublication?) throws {
        if let publication {
            _ = try ContinuationDescriptorV1(encoded: publication.descriptorData)
        }
        requestedPublication = publication
        reconcile()
    }

    /// Invalidates only the current activity. The requested publication stays
    /// retained and may be reconciled again by a later lifecycle transition.
    public func invalidateCurrentActivity() {
        currentUserActivity?.invalidate()
        currentUserActivity = nil
        publishedRequest = nil
        publishedSupportsStreams = false
        isPublishing = false
    }

    /// Clears both the current activity and its retained publication request.
    public func clearPublication() {
        requestedPublication = nil
        invalidateCurrentActivity()
    }

    private func reconcile() {
        guard enabled,
              applicationActive,
              !locked,
              let request = requestedPublication else {
            invalidateCurrentActivity()
            return
        }

        let supportsStreams = onContinuationStreams != nil
        if currentUserActivity != nil,
           isPublishing,
           publishedRequest == request,
           publishedSupportsStreams == supportsStreams {
            return
        }

        let replacement = NSUserActivity(activityType: Self.activityType)
        replacement.title = request.title
        replacement.userInfo = [Self.descriptorKey: request.descriptorData]
        replacement.requiredUserInfoKeys = [Self.descriptorKey]
        replacement.targetContentIdentifier = request.targetContentIdentifier
        replacement.isEligibleForHandoff = true
        replacement.isEligibleForSearch = false
        replacement.isEligibleForPublicIndexing = false
        replacement.supportsContinuationStreams = supportsStreams
        replacement.delegate = self

        currentUserActivity?.invalidate()
        currentUserActivity = replacement
        publishedRequest = request
        publishedSupportsStreams = supportsStreams
        publicationGeneration += 1
        replacement.becomeCurrent()
        isPublishing = true
    }

    nonisolated public func userActivity(
        _ userActivity: NSUserActivity,
        didReceive inputStream: InputStream,
        outputStream: OutputStream
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.enabled,
                  self.applicationActive,
                  !self.locked,
                  self.isPublishing,
                  self.currentUserActivity === userActivity,
                  let handler = self.onContinuationStreams else {
                inputStream.close()
                outputStream.close()
                return
            }
            inputStream.open()
            outputStream.open()
            handler(inputStream, outputStream)
        }
    }
}
