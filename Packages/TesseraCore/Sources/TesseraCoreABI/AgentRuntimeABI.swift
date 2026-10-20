import Foundation
import TesseraAgentCore

/// Independent Agent Center ABI. It intentionally does not reuse CoreABICommand
/// or the existing `tessera_core_*` symbol family, whose version is already
/// validated by Android session startup.
public struct AgentABICommand: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumPayloadBytes = 1_048_576

    public enum Kind: String, Codable, Sendable {
        case configure
        case bind
        case unbind
        case lifecycle
        /// Complete scoped process inventory; it can only revoke routes.
        case occupancy
        /// Proved empty or unidentified conversation root, with `providerID`
        /// and a PID binding. Optional `sourceTimestampNanoseconds` fences
        /// cleared frames and preserves tenures starting at or after it.
        case conversationCleared
        case projection
        case select
        case viewportAnchor
        case releaseIngestionWindow
        case filter
        case search
        case promptObservation
        case livePromptObservation
        case terminalVisible
        case action
        case armOutgoing
        case outgoingDispatched
        case launch
        case result
        case acknowledge
        /// The reader saw a finished thread without a record to point at;
        /// fenced by the `attentionEpoch` it saw.
        case acknowledgeCompletion
        case memoryWarning
        case destroy
        /// Either the width a row has for a fallback title, or a title the
        /// platform generated on device from a thread opening prompt.
        case title
        /// The largest acknowledged viewport each connected host advertised.
        case hostCapacity
    }

    public let version: Int
    public let kind: Kind
    public let threadID: AgentThreadID?
    public let binding: AgentTerminalBinding?
    /// Opaque per-runtime authority minted by a platform endpoint after it has
    /// performed its own fresh route/process proof. Raw ABI JSON cannot mint it.
    public let bindingToken: UUID?
    public let occupancy: AgentOccupancyObservation?
    public let providerID: AgentProviderID?
    public let sourceTimestampNanoseconds: UInt64?
    /// Saved host name supplied by the native session owner, never a provider tag.
    public let hostDisplayLabel: String?
    public let hostDisplayLabels: [String: String]?
    public let inventoryModified: Int64?
    public let lifecycle: AgentLifecycleEnvelope?
    public let lifecycleProof: AgentLifecycleBindingProof?
    public let sourceIdentity: String?
    public let projection: AgentProjectionPage?
    public let frontier: AgentOutgoingFrontier?
    public let ingestionWire: String?
    public let ingestionSummaryWire: String?
    public let ingestionHookWire: String?
    public let ingestionEpoch: String?
    public let ingestionThread: String?
    public let ingestionReceipt: Bool?
    public let ingestionRequestID: String?
    public let projectionError: AgentProjectionError?
    public let manifests: [AgentProviderManifest]?
    public let conformances: [AgentAdapterConformance]?
    public let metadata: [AgentThreadMetadata]?
    public let action: AgentActionKind?
    public let actionPayload: AgentABIActionPayload?
    public let launch: AgentLaunchIntent?
    public let lease: AgentActionLease?
    public let recordID: String?
    public let query: String?
    public let resultCode: String?
    public let resultOutcome: AgentActionResultOutcome?
    public let launchReceipt: AgentLaunchReceipt?
    public let grouping: AgentListGrouping?
    public let listFilter: AgentListFilter?
    public let searchSnapshot: AgentSearchSnapshot?
    public let promptObservation: AgentPromptObservationRequest?
    /// With `promptObservation`: plan the next answer step on that capture.
    public let promptAnswerPlan: AgentPromptAnswerPlanInput?
    /// With `promptObservation`: echoed on its reply, so a platform that
    /// stopped waiting for one request never takes its late reply for the
    /// next request's capture.
    public let promptRequestID: String?
    /// With `livePromptObservation`: the arrival sequence of the newest
    /// lifecycle frame forwarded before the capture started, in place of
    /// `observedGeneration`.
    public let observedLifecycleSequence: UInt64?
    /// With `livePromptObservation`: the thread's conversation is on screen,
    /// so its terminal is watched even when no hook announced a question.
    public let onDisplay: Bool?
    /// How many characters of an opening prompt a list row can show.
    public let titleBudget: Int?
    /// A title an on-device model wrote for `titleSeed`.
    public let generatedTitle: String?
    /// The opening prompt the generated title answers, echoed back so a title
    /// produced for a prompt the thread has since moved past can be dropped.
    public let titleSeed: String?
    public let observedGeneration: UInt64?
    /// Reported with `configure`; Core maps it to a retention tier.
    public let physicalMemoryBytes: Int64?
    public let lowRAMDevice: Bool?
    /// Host UUID string to the host's hello `maxWindowSegments`.
    public let hostWindowSegments: [String: Int]?
    /// The thread snapshot's `attentionEpoch` the reader saw.
    public let attentionEpoch: UInt64?

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind, threadID, binding, bindingToken, hostDisplayLabel, hostDisplayLabels, inventoryModified, lifecycle, lifecycleProof, sourceIdentity
        case occupancy, providerID, sourceTimestampNanoseconds
        case projection, frontier, projectionError, manifests, conformances, metadata, action, actionPayload, launch, lease, recordID, query, resultCode, resultOutcome, launchReceipt
        case ingestionWire, ingestionSummaryWire, ingestionHookWire, ingestionEpoch, ingestionThread, ingestionReceipt, ingestionRequestID
        case grouping, listFilter, searchSnapshot, promptObservation, promptAnswerPlan, promptRequestID, observedLifecycleSequence, onDisplay
        case titleBudget, generatedTitle, titleSeed, observedGeneration
        case physicalMemoryBytes, lowRAMDevice, hostWindowSegments
        case attentionEpoch
    }

    public init(
        version: Int = AgentABICommand.currentVersion,
        kind: Kind,
        threadID: AgentThreadID? = nil,
        binding: AgentTerminalBinding? = nil,
        bindingToken: UUID? = nil,
        occupancy: AgentOccupancyObservation? = nil,
        providerID: AgentProviderID? = nil,
        sourceTimestampNanoseconds: UInt64? = nil,
        hostDisplayLabel: String? = nil,
        hostDisplayLabels: [String: String]? = nil,
        inventoryModified: Int64? = nil,
        lifecycle: AgentLifecycleEnvelope? = nil,
        lifecycleProof: AgentLifecycleBindingProof? = nil,
        sourceIdentity: String? = nil,
        projection: AgentProjectionPage? = nil,
        frontier: AgentOutgoingFrontier? = nil,
        ingestionWire: String? = nil,
        ingestionSummaryWire: String? = nil,
        ingestionHookWire: String? = nil,
        ingestionEpoch: String? = nil,
        ingestionThread: String? = nil,
        ingestionReceipt: Bool? = nil,
        ingestionRequestID: String? = nil,
        projectionError: AgentProjectionError? = nil,
        manifests: [AgentProviderManifest]? = nil,
        conformances: [AgentAdapterConformance]? = nil,
        metadata: [AgentThreadMetadata]? = nil,
        action: AgentActionKind? = nil,
        actionPayload: AgentABIActionPayload? = nil,
        launch: AgentLaunchIntent? = nil,
        lease: AgentActionLease? = nil,
        recordID: String? = nil,
        query: String? = nil,
        resultCode: String? = nil,
        resultOutcome: AgentActionResultOutcome? = nil,
        launchReceipt: AgentLaunchReceipt? = nil,
        grouping: AgentListGrouping? = nil,
        listFilter: AgentListFilter? = nil,
        searchSnapshot: AgentSearchSnapshot? = nil,
        promptObservation: AgentPromptObservationRequest? = nil,
        promptAnswerPlan: AgentPromptAnswerPlanInput? = nil,
        promptRequestID: String? = nil,
        observedLifecycleSequence: UInt64? = nil,
        onDisplay: Bool? = nil,
        titleBudget: Int? = nil,
        generatedTitle: String? = nil,
        titleSeed: String? = nil,
        observedGeneration: UInt64? = nil,
        physicalMemoryBytes: Int64? = nil,
        lowRAMDevice: Bool? = nil,
        hostWindowSegments: [String: Int]? = nil,
        attentionEpoch: UInt64? = nil
    ) {
        self.version = version
        self.kind = kind
        self.threadID = threadID
        self.binding = binding
        self.bindingToken = bindingToken
        self.occupancy = occupancy
        self.providerID = providerID
        self.sourceTimestampNanoseconds = sourceTimestampNanoseconds
        self.hostDisplayLabel = hostDisplayLabel
        self.hostDisplayLabels = hostDisplayLabels
        self.inventoryModified = inventoryModified
        self.lifecycle = lifecycle
        self.lifecycleProof = lifecycleProof
        self.sourceIdentity = sourceIdentity
        self.projection = projection
        self.frontier = frontier
        self.ingestionWire = ingestionWire; self.ingestionEpoch = ingestionEpoch
        self.ingestionSummaryWire = ingestionSummaryWire
        self.ingestionHookWire = ingestionHookWire
        self.ingestionThread = ingestionThread; self.ingestionReceipt = ingestionReceipt
        self.ingestionRequestID = ingestionRequestID
        self.projectionError = projectionError
        self.manifests = manifests
        self.conformances = conformances
        self.metadata = metadata
        self.action = action
        self.actionPayload = actionPayload
        self.launch = launch
        self.lease = lease
        self.recordID = recordID
        self.query = query
        self.resultCode = resultCode
        self.resultOutcome = resultOutcome
        self.launchReceipt = launchReceipt
        self.grouping = grouping
        self.listFilter = listFilter
        self.searchSnapshot = searchSnapshot
        self.promptObservation = promptObservation
        self.promptAnswerPlan = promptAnswerPlan
        self.promptRequestID = promptRequestID
        self.observedLifecycleSequence = observedLifecycleSequence
        self.onDisplay = onDisplay
        self.titleBudget = titleBudget
        self.generatedTitle = generatedTitle
        self.titleSeed = titleSeed
        self.observedGeneration = observedGeneration
        self.physicalMemoryBytes = physicalMemoryBytes
        self.lowRAMDevice = lowRAMDevice
        self.hostWindowSegments = hostWindowSegments
        self.attentionEpoch = attentionEpoch
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder.agentABI.encode(self)
        guard data.count <= Self.maximumPayloadBytes else { throw AgentABIError.payloadTooLarge(data.count) }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw AgentABIError.emptyPayload }
        guard data.count <= maximumPayloadBytes else { throw AgentABIError.payloadTooLarge(data.count) }
        let command = try JSONDecoder().decode(Self.self, from: data)
        try command.validate()
        return command
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw AgentABIError.unsupportedVersion(version) }
        guard hostDisplayLabel.map({ $0.utf8.count <= 2_048 && !$0.contains("\0") }) ?? true else { throw AgentABIError.invalidField }
        guard inventoryModified.map({ kind == .bind && $0 >= 0 && $0 <= 32_503_680_000 }) ?? true else { throw AgentABIError.invalidField }
        guard hostDisplayLabels.map({ labels in
            labels.count <= 1_024 && Set(labels.keys.compactMap(UUID.init(uuidString:))).count == labels.count &&
                labels.allSatisfy { $0.value.utf8.count <= 2_048 && !$0.value.contains("\0") }
        }) ?? true else { throw AgentABIError.invalidField }
        guard physicalMemoryBytes.map({ kind == .configure && $0 > 0 }) ?? (lowRAMDevice == nil),
              hostWindowSegments == nil || kind == .hostCapacity,
              attentionEpoch == nil || kind == .acknowledgeCompletion,
              occupancy == nil || kind == .occupancy,
              providerID == nil || kind == .conversationCleared,
              sourceTimestampNanoseconds == nil || kind == .conversationCleared,
              onDisplay == nil || kind == .livePromptObservation else { throw AgentABIError.invalidField }
        switch kind {
        case .configure:
            guard (manifests != nil || metadata != nil || hostDisplayLabels != nil || physicalMemoryBytes != nil), manifests.map({ $0.count <= 32 }) ?? true,
                  metadata.map({ $0.count <= 1_024 }) ?? true,
                  conformances == nil,
                  manifests.map({ Set($0.map(\.id)).count == $0.count }) ?? true,
                  metadata.map({ Set($0.map(\.threadID)).count == $0.count }) ?? true
            else { throw AgentABIError.missingField }
        case .bind:
            guard threadID != nil, bindingToken != nil, binding == nil else { throw AgentABIError.missingField }
        case .unbind:
            guard threadID != nil else { throw AgentABIError.missingField }
        case .lifecycle:
            guard threadID != nil, lifecycle != nil, bindingToken != nil, binding == nil, lifecycleProof == nil, sourceIdentity == nil else {
                throw AgentABIError.missingField
            }
        case .occupancy:
            guard occupancy != nil, binding == nil, bindingToken == nil else { throw AgentABIError.missingField }
        case .conversationCleared:
            guard providerID != nil, binding?.agentPID != nil, bindingToken == nil else { throw AgentABIError.missingField }
        case .projection:
            guard threadID != nil, bindingToken != nil, binding == nil,
                  [projection != nil, projectionError != nil, ingestionWire != nil, ingestionSummaryWire != nil, ingestionHookWire != nil].filter({ $0 }).count == 1 else { throw AgentABIError.missingField }
            if let ingestionWire = ingestionWire ?? ingestionSummaryWire ?? ingestionHookWire {
                guard ingestionWire.utf8.count <= 400_000,
                      ingestionEpoch.map(AgentIngestionRange.identifier) == true,
                      ingestionThread.map(AgentIngestionRange.identifier) == true,
                      ingestionRequestID.map(AgentIngestionRange.identifier) == true else { throw AgentABIError.invalidField }
                if let observationalWire = ingestionSummaryWire ?? ingestionHookWire {
                    guard observationalWire.utf8.count <= 90_000, ingestionReceipt != true else { throw AgentABIError.invalidField }
                }
            } else if ingestionEpoch != nil || ingestionThread != nil || ingestionReceipt != nil || ingestionRequestID != nil { throw AgentABIError.invalidField }
        case .select:
            break
        case .viewportAnchor:
            guard threadID != nil, recordID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw AgentABIError.invalidField }
        case .releaseIngestionWindow:
            guard threadID != nil else { throw AgentABIError.missingField }
        case .filter:
            guard grouping != nil || listFilter != nil else { throw AgentABIError.missingField }
        case .search:
            let hasBoundedQuery = query.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? false
            guard (searchSnapshot != nil) != hasBoundedQuery else { throw AgentABIError.invalidField }
        case .promptObservation:
            guard promptObservation != nil else { throw AgentABIError.missingField }
            if let promptAnswerPlan { guard promptAnswerPlan.isValid else { throw AgentABIError.invalidField } }
            if let promptRequestID { guard !promptRequestID.isEmpty, promptRequestID.utf8.count <= 64 else { throw AgentABIError.invalidField } }
        case .livePromptObservation:
            guard promptObservation != nil, threadID != nil, bindingToken != nil, binding == nil,
                  (observedGeneration != nil) != (observedLifecycleSequence != nil) else { throw AgentABIError.missingField }
        case .terminalVisible:
            guard threadID != nil, bindingToken != nil, binding == nil, observedGeneration != nil else { throw AgentABIError.missingField }
        case .title:
            // One command carries one intent: a reader reporting how wide a row
            // is, or a platform returning a title its on-device model wrote.
            // Both at once would leave the order of two unrelated effects
            // undefined.
            let carriesBudget = titleBudget != nil
            let carriesGenerated = generatedTitle != nil || titleSeed != nil
            guard carriesBudget != carriesGenerated else { throw AgentABIError.missingField }
            if let titleBudget { guard titleBudget > 0, titleBudget <= 4_096 else { throw AgentABIError.invalidField } }
            if carriesGenerated {
                guard let generatedTitle, let titleSeed, threadID != nil,
                      !generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      generatedTitle.utf8.count <= 512, !titleSeed.isEmpty, titleSeed.utf8.count <= 4_096
                else { throw AgentABIError.missingField }
            }
        case .action:
            guard threadID != nil, bindingToken != nil, binding == nil, action != nil, actionPayload != nil else { throw AgentABIError.missingField }
            guard action != .spawn, action != .fork else { throw AgentABIError.invalidField }
            // Payload's binding is compared to the platform-minted binding
            // after token resolution in `apply`.
        case .armOutgoing:
            guard lease != nil, (projection != nil) != (frontier != nil), bindingToken != nil, binding == nil else { throw AgentABIError.missingField }
        case .outgoingDispatched:
            guard lease != nil, bindingToken != nil, binding == nil, frontier == nil, projection == nil else { throw AgentABIError.missingField }
        case .launch:
            guard threadID != nil, launch != nil, bindingToken != nil, binding == nil else { throw AgentABIError.missingField }
        case .result:
            // Retained in the source model for old non-actionable decoders,
            // but no actionable runtime result may carry free-form text.
            guard bindingToken != nil, binding == nil, resultCode == nil, (lease != nil) != (launchReceipt != nil) else { throw AgentABIError.invalidField }
            if let lease { guard let outcome = resultOutcome, lease.action == outcome.action else { throw AgentABIError.invalidField } }
            if launchReceipt != nil, resultOutcome != nil { throw AgentABIError.invalidField }
        case .acknowledge:
            guard threadID != nil, let recordID, !recordID.isEmpty, recordID.utf8.count <= 512 else {
                throw AgentABIError.missingField
            }
        case .acknowledgeCompletion:
            guard threadID != nil, attentionEpoch != nil, recordID == nil, bindingToken == nil else { throw AgentABIError.missingField }
        case .hostCapacity:
            guard let hostWindowSegments else { throw AgentABIError.missingField }
            guard hostWindowSegments.count <= 1_024,
                  Set(hostWindowSegments.keys.compactMap(UUID.init(uuidString:))).count == hostWindowSegments.count,
                  hostWindowSegments.values.allSatisfy({ (1...4_096).contains($0) }) else { throw AgentABIError.invalidField }
            // A thread-scoped report names exactly that thread's host.
            if let threadID, hostWindowSegments.keys.map({ UUID(uuidString: $0) }) != [threadID.hostID] {
                throw AgentABIError.invalidField
            }
        case .memoryWarning, .destroy:
            break
        }
    }
}

public struct AgentABIRouteRetirement: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case replaced, absent, cleared, unbound }
    public let threadID: AgentThreadID
    public let bindingToken: UUID
    public let successor: AgentThreadID?
    public let reason: Reason

    public init(threadID: AgentThreadID, bindingToken: UUID, successor: AgentThreadID? = nil, reason: Reason) {
        self.threadID = threadID; self.bindingToken = bindingToken
        self.successor = successor; self.reason = reason
    }
}

public struct AgentABIEvent: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum Kind: String, Codable, Sendable {
        case listSnapshot
        case threadSnapshot
        case lifecycleAccepted
        case projectionApplied
        case actionPlan
        case launchPlan
        case launchResult
        case searchSnapshot
        case promptObservation
        case commandRejected
        case destroyed
        case routesRetired
    }

    public let version: Int
    public let kind: Kind
    public let generation: UInt64
    public let list: AgentCenterListSnapshot?
    public let thread: AgentThreadSnapshot?
    public let toolRuns: [AgentTranscriptGrouping.ToolRunDescriptor]?
    public let lease: AgentActionLease?
    public let actionPayload: AgentABIActionPayload?
    public let launchPlan: AgentLaunchPlan?
    public let search: AgentSearchSnapshot?
    public let promptObservation: AgentPromptObservationResult?
    public let promptAnswerPlan: AgentPromptAnswerPlan?
    /// The `promptRequestID` of the command this observation answers.
    public let promptRequestID: String?
    public let launchReceipt: AgentLaunchReceipt?
    public let code: String?
    public let ingestion: AgentIngestionRange?
    public let receiptBoundary: AgentProjectionPage?
    public let ingestionRequestID: String?
    /// `routesRetired` carries `retirements: [{threadID, bindingToken,
    /// successor?, reason}]`. Owners discard only the named token; a newer
    /// proof survives. Absence, clearing and unbinding name no successor.
    public let retirements: [AgentABIRouteRetirement]?

    public init(version: Int = currentVersion, kind: Kind, generation: UInt64, list: AgentCenterListSnapshot? = nil, thread: AgentThreadSnapshot? = nil, lease: AgentActionLease? = nil, actionPayload: AgentABIActionPayload? = nil, launchPlan: AgentLaunchPlan? = nil, search: AgentSearchSnapshot? = nil, promptObservation: AgentPromptObservationResult? = nil, promptAnswerPlan: AgentPromptAnswerPlan? = nil, promptRequestID: String? = nil, launchReceipt: AgentLaunchReceipt? = nil, code: String? = nil, ingestion: AgentIngestionRange? = nil, receiptBoundary: AgentProjectionPage? = nil, ingestionRequestID: String? = nil, retirements: [AgentABIRouteRetirement]? = nil) {
        self.version = version
        self.kind = kind
        self.generation = generation
        self.list = list
        self.thread = thread
        self.toolRuns = thread.map { AgentTranscriptGrouping.toolRunDescriptors($0.messages) }
        self.lease = lease
        self.actionPayload = actionPayload
        self.launchPlan = launchPlan
        self.search = search
        self.promptObservation = promptObservation
        self.promptAnswerPlan = promptAnswerPlan
        self.promptRequestID = promptRequestID
        self.launchReceipt = launchReceipt
        self.code = code
        self.ingestion = ingestion; self.receiptBoundary = receiptBoundary
        self.ingestionRequestID = ingestionRequestID
        self.retirements = retirements
    }

    private init(copying event: Self, thread: AgentThreadSnapshot, toolRuns: [AgentTranscriptGrouping.ToolRunDescriptor]?) {
        version = event.version; kind = event.kind; generation = event.generation; list = event.list
        self.thread = thread; self.toolRuns = toolRuns
        lease = event.lease; actionPayload = event.actionPayload; launchPlan = event.launchPlan; search = event.search
        promptObservation = event.promptObservation; promptAnswerPlan = event.promptAnswerPlan
        promptRequestID = event.promptRequestID
        launchReceipt = event.launchReceipt; code = event.code
        ingestion = event.ingestion; receiptBoundary = event.receiptBoundary; ingestionRequestID = event.ingestionRequestID
        retirements = event.retirements
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder.agentABI.encode(self)
        guard data.count <= AgentABICommand.maximumPayloadBytes else { throw AgentABIError.payloadTooLarge(data.count) }
        return data
    }

    /// The Swift reducer may retain several MiB for a selected thread, while
    /// the C ABI deliberately has a one MiB frame ceiling.  Keep that cache
    /// intact and construct a latest-first transport view instead of silently
    /// losing the accepted operation when the full snapshot cannot fit.
    /// Window admission reserves this frame (`presentationLimitBytes`), so the
    /// halving below is a last resort for non-window transcripts.
    func boundedForABI() -> Self { boundedEncodedForABI().event }

    /// The bounded event and its canonical bytes, encoded once. `data` is nil
    /// only when no bounded view fits the frame.
    func boundedEncodedForABI() -> (event: Self, data: Data?) {
        guard let thread else { return (self, try? encoded()) }
        // Android groups messages itself; `turns` would only resend them.
        if thread.turns.isEmpty, let data = try? encoded() { return (self, data) }

        var messages = thread.messages
        var activity = thread.activity
        var edits = thread.changes.edits
        let includeTurns = false

        func candidate() -> AgentABIEvent {
            let changes = AgentChangeSummary(
                authoritativeTotals: thread.changes.authoritativeTotals,
                edits: edits
            )
            let boundedThread = AgentThreadSnapshot(
                version: thread.version,
                summary: thread.summary,
                messages: messages,
                turns: includeTurns ? thread.turns : [],
                activity: activity,
                changes: changes,
                lineage: thread.lineage,
                cursor: thread.cursor,
                // `hasMore` remains the provider cursor contract; the ABI
                // view is independently windowed and must not invent a remote
                // cursor that the platform cannot actually request.
                hasMore: thread.hasMore,
                binding: thread.binding,
                deliveryGeneration: thread.deliveryGeneration,
                outgoingMessages: thread.outgoingMessages, livePreview: thread.livePreview, ingestionWindow: thread.ingestionWindow,
                attentionEpoch: thread.attentionEpoch, unreadCompletionKey: thread.unreadCompletionKey,
                acknowledgedCompletionKey: thread.acknowledgedCompletionKey,
                conversationEnded: thread.conversationEnded
            )
            // Descriptors depend only on messages; reuse them until halving.
            let runs = messages.count == thread.messages.count ? toolRuns :
                AgentTranscriptGrouping.toolRunDescriptors(messages)
            return .init(copying: self, thread: boundedThread, toolRuns: runs)
        }

        // Retain the newest visible material.
        while true {
            let output = candidate()
            if let data = try? JSONEncoder.agentABI.encode(output),
               data.count <= AgentABICommand.maximumPayloadBytes {
                return (output, data)
            }
            if messages.count > 1 {
                messages.removeFirst(max(1, messages.count / 2))
            } else if !activity.isEmpty {
                activity.removeFirst(max(1, activity.count / 2))
            } else if !edits.isEmpty {
                edits.removeFirst(max(1, edits.count / 2))
            } else {
                // Individual domain fields are capped well below the ABI
                // ceiling. If a future schema violates that invariant, emit a
                // bounded error below rather than dropping its operation.
                return (output, nil)
            }
        }
    }
}

public enum AgentABIError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case emptyPayload
    case payloadTooLarge(Int)
    case missingField
    case invalidField
    case invalidHandle
}

/// A privileged, host-bridge-only registration payload.  This is deliberately
/// not an `AgentABICommand`: JSON submitted through `send` can *use* an opaque
/// token but can never register, replace, or manufacture one.  The platform
/// bridge must construct this only after an authenticated route has verified
/// the exact process, carrier generation/incarnation, and working-directory
/// provenance.
///
/// C/JNI callers use this mode only after the trusted route owner has issued
/// an opaque process-proof handle for the exact current binding.
public enum AgentABIPlatformBindingMode: String, Codable, Sendable {
    /// Requires a proven agent PID and is eligible for action/launch after
    /// every current-binding check.
    case actionable
    /// A deliberately constrained fallback for lifecycle/projection discovery
    /// where no provider PID exists. It never carries action capability.
    case observeOnly
    /// Host inventory is lower-priority discovery, not a revocation of a live
    /// pane's process proof. It cannot replace an active actionable token.
    case inventoryObservation
}

/// Facts asserted by a trusted, authenticated route owner.  This payload is
/// accepted only by the dedicated platform-proof entry point; it is converted
/// immediately into an opaque, runtime-local handle and is never accepted by
/// the command channel or by binding registration.
public struct AgentABIPlatformProofRegistration: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 16_384

    public let threadID: AgentThreadID
    public let hostID: UUID
    public let binding: AgentTerminalBinding
    public let sourceIdentity: String
    public let processIDs: [Int]
    public let validatedDirectories: [String]
    public init?(
        threadID: AgentThreadID,
        hostID: UUID,
        binding: AgentTerminalBinding,
        sourceIdentity: String,
        processIDs: [Int],
        validatedDirectories: [String] = []
    ) {
        let isActionable = binding.agentPID.map { $0 > 1 && processIDs.contains($0) } ?? false
        let isObserveOnly = binding.agentPID == nil && processIDs.isEmpty &&
            binding.capabilities == [.observe] && validatedDirectories.isEmpty
        guard threadID.hostID == hostID,
              !sourceIdentity.isEmpty, sourceIdentity.utf8.count <= 512,
              processIDs.count <= 128,
              Set(processIDs).count == processIDs.count,
              processIDs.allSatisfy({ $0 > 1 }),
              validatedDirectories.count <= 64,
              Set(validatedDirectories).count == validatedDirectories.count,
              validatedDirectories.allSatisfy(Self.isValidDirectory),
              isActionable || isObserveOnly
        else { return nil }
        self.threadID = threadID
        self.hostID = hostID
        self.binding = binding
        self.sourceIdentity = sourceIdentity
        self.processIDs = processIDs
        self.validatedDirectories = validatedDirectories
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw AgentABIError.emptyPayload }
        guard data.count <= maximumPayloadBytes else { throw AgentABIError.payloadTooLarge(data.count) }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard let checked = Self(
            threadID: decoded.threadID,
            hostID: decoded.hostID,
            binding: decoded.binding,
            sourceIdentity: decoded.sourceIdentity,
            processIDs: decoded.processIDs,
            validatedDirectories: decoded.validatedDirectories
        ) else { throw AgentABIError.invalidField }
        return checked
    }

    fileprivate static func isValidDirectory(_ value: String) -> Bool {
        AgentRemotePath(value)?.value == value
    }
}

/// Opaque proof material returned only to a platform bridge.  A binding
/// registration repeats public identity facts solely so the runtime can reject
/// mismatches; process IDs themselves never cross that boundary again.
public struct AgentABIPlatformProofHandle: Codable, Equatable, Sendable {
    public let proofHandle: UUID
    public init(proofHandle: UUID) { self.proofHandle = proofHandle }
}

public struct AgentABIPlatformBindingRegistration: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 16_384

    public let threadID: AgentThreadID
    public let hostID: UUID
    public let binding: AgentTerminalBinding
    public let sourceIdentity: String
    public let validatedDirectories: [String]
    public let mode: AgentABIPlatformBindingMode
    public let proofHandle: UUID

    public init?(
        threadID: AgentThreadID,
        hostID: UUID,
        binding: AgentTerminalBinding,
        sourceIdentity: String,
        validatedDirectories: [String] = [],
        mode: AgentABIPlatformBindingMode = .actionable,
        proofHandle: UUID
    ) {
        let isObserveOnly = binding.agentPID == nil &&
            binding.capabilities == [.observe] && validatedDirectories.isEmpty
        guard threadID.hostID == hostID,
              !sourceIdentity.isEmpty, sourceIdentity.utf8.count <= 512,
              validatedDirectories.count <= 64,
              Set(validatedDirectories).count == validatedDirectories.count,
              validatedDirectories.allSatisfy(AgentABIPlatformProofRegistration.isValidDirectory),
              (mode == .actionable ? binding.agentPID.map({ $0 > 1 }) ?? false : isObserveOnly)
        else { return nil }
        self.threadID = threadID
        self.hostID = hostID
        self.binding = binding
        self.sourceIdentity = sourceIdentity
        self.validatedDirectories = validatedDirectories
        self.mode = mode
        self.proofHandle = proofHandle
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw AgentABIError.emptyPayload }
        guard data.count <= maximumPayloadBytes else { throw AgentABIError.payloadTooLarge(data.count) }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard let checked = Self(
            threadID: decoded.threadID,
            hostID: decoded.hostID,
            binding: decoded.binding,
            sourceIdentity: decoded.sourceIdentity,
            validatedDirectories: decoded.validatedDirectories,
            mode: decoded.mode,
            proofHandle: decoded.proofHandle
        ) else { throw AgentABIError.invalidField }
        return checked
    }
}

/// Direct response for a privileged platform-binding registration.  It is
/// returned from the registration call, not delivered to an ABI event sink.
public struct AgentABIPlatformBindingToken: Codable, Equatable, Sendable {
    public let bindingToken: UUID
    public init(bindingToken: UUID) { self.bindingToken = bindingToken }
}

/// Observe-only Tier-A discovery registration. It is accepted solely by the
/// privileged platform bridge, never by Agent command JSON, and deliberately
/// mints no binding token or action authority.
public struct AgentABIPlatformCandidateRegistration: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 32_768
    public let id: AgentSourceCandidateID
    public let fallback: AgentFallbackSnapshot
    public let providerName: String
    public let title: String
    public let hostDisplayLabel: String
    public let lastActivityMilliseconds: Int64?
    public let processIDs: [Int]

    public init?(id: AgentSourceCandidateID, fallback: AgentFallbackSnapshot, providerName: String = "Agent", title: String = "Live agent", hostDisplayLabel: String = "", lastActivityMilliseconds: Int64? = nil, processIDs: [Int]) {
        guard AgentSourceCandidateID(hostID: id.hostID, providerID: id.providerID, sourceIdentity: id.sourceIdentity) != nil,
              fallback.binding.agentPID.map({ $0 > 1 && processIDs.contains($0) }) == true,
              processIDs.count <= 128, Set(processIDs).count == processIDs.count,
              processIDs.allSatisfy({ $0 > 1 }), providerName.utf8.count <= 128,
              title.utf8.count <= 512, hostDisplayLabel.utf8.count <= 512,
              fallback.location.utf8.count <= 512, fallback.liveTail.utf8.count <= 16_384
        else { return nil }
        self.id = id; self.fallback = fallback; self.providerName = providerName
        self.title = title; self.hostDisplayLabel = hostDisplayLabel
        self.lastActivityMilliseconds = lastActivityMilliseconds; self.processIDs = processIDs
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else { throw AgentABIError.invalidField }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard let checked = Self(id: decoded.id, fallback: decoded.fallback, providerName: decoded.providerName, title: decoded.title, hostDisplayLabel: decoded.hostDisplayLabel, lastActivityMilliseconds: decoded.lastActivityMilliseconds, processIDs: decoded.processIDs) else { throw AgentABIError.invalidField }
        return checked
    }
}

public struct AgentABIPlatformCandidateRemoval: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 2_048
    public let id: AgentSourceCandidateID
    public init(id: AgentSourceCandidateID) { self.id = id }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else { throw AgentABIError.invalidField }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard AgentSourceCandidateID(hostID: decoded.id.hostID, providerID: decoded.id.providerID, sourceIdentity: decoded.id.sourceIdentity) != nil else {
            throw AgentABIError.invalidField
        }
        return decoded
    }
}

/// Compiled-attestation-only Tier-C enablement request.  A platform may name
/// a provider only after its own bounded live route has passed; adapter IDs,
/// fixture digests, and capability bits are deliberately not wire inputs.
public struct AgentABIPlatformConformanceRegistration: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 4_096
    public let providers: [AgentProviderID]

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        let intValue: Int? = nil
        init?(intValue: Int) { return nil }
    }

    public init?(providers: [AgentProviderID]) {
        let allowed: Set<AgentProviderID> = [.opencode, .pi, .kimi]
        guard providers.count <= allowed.count,
              Set(providers).count == providers.count,
              providers.allSatisfy(allowed.contains)
        else { return nil }
        self.providers = providers.sorted()
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw AgentABIError.emptyPayload }
        guard data.count <= maximumPayloadBytes else { throw AgentABIError.payloadTooLarge(data.count) }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard values.allKeys.map(\.stringValue) == ["providers"],
              let key = DynamicCodingKey(stringValue: "providers")
        else { throw AgentABIError.invalidField }
        let rawProviders = try values.decode([String].self, forKey: key)
        let providers = rawProviders.compactMap(AgentProviderID.init(rawValue:))
        guard providers.count == rawProviders.count,
              let checked = Self(providers: providers)
        else { throw AgentABIError.invalidField }
        self = checked
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: DynamicCodingKey.self)
        try values.encode(providers.map(\.rawValue), forKey: DynamicCodingKey(stringValue: "providers")!)
    }
}

public final class AgentABIRuntime: @unchecked Sendable {
    public typealias EventSink = @Sendable (Data) -> Void

    private let lock = NSLock()
    private var registry: AgentProviderRegistry
    private let center: AgentCenterRuntime
    private let eventSink: EventSink
    private var tail = Task<Void, Never> {}
    private var destroyed = false
    private var callbacksSuppressed = false
    private var generation: UInt64 = 0
    private let callbackScopeToken = UUID().uuidString
    private struct PlatformBindingAuthority: Equatable, Sendable {
        let threadID: AgentThreadID
        let hostID: UUID
        let binding: AgentTerminalBinding
        let sourceIdentity: String
        let processIDs: Set<Int>
        let validatedDirectories: Set<String>
        let mode: AgentABIPlatformBindingMode
        var route: PlatformRoute { .init(liveSessionID: binding.liveSessionID, carrierGeneration: binding.carrierGeneration) }
    }
    /// One platform carrier: every token it is issued, route or inventory,
    /// is torn down with it.
    private struct PlatformRoute: Hashable, Sendable {
        let liveSessionID: UUID
        let carrierGeneration: UInt64
    }
    private var platformBindings: [UUID: PlatformBindingAuthority] = [:]
    /// The route each retired token was issued to, so a queued `unbind`
    /// naming it still retires that route's newer token. Bounded: a token that
    /// ages out unbinds as if unnamed.
    private var retiredTokenRoutes: [UUID: PlatformRoute] = [:]
    private var retiredTokenOrder: [UUID] = []
    /// Exactly one current opaque capability may control a thread. Replacing or
    /// unbinding it retires the predecessor rather than leaving a stale route
    /// able to re-bind itself later.
    private var activeBindingTokenByThread: [AgentThreadID: UUID] = [:]
    /// A competing route's proof cannot revoke the live owner's token before
    /// Core admits its bind. Only that pending token may retry registration.
    private var pendingBindingTokenByThread: [AgentThreadID: UUID] = [:]
    private var pendingProofSequences: [UUID: UInt64] = [:]
    private var livePlatformBindings: [AgentThreadID: AgentTerminalBinding] = [:]
    private struct IssuedActionLease: Sendable {
        let lease: AgentActionLease
        let bindingToken: UUID
    }
    /// Only an issued text lease can withdraw its bubble after authority
    /// retires. A result consumes this identity, so draft restoration is once.
    private var issuedActionLeases: [UUID: IssuedActionLease] = [:]
    /// Proofs are issued synchronously as frames arrive, and commands apply
    /// later in queue order, so a thread can be proved again (say `/resume`
    /// back to it) while a queued frame that replaces it waits. The latest
    /// proof per thread, in issue order, tells which of the two came last.
    private var proofSequence: UInt64 = 0
    private var proofSequenceByThread: [AgentThreadID: UInt64] = [:]
    /// Proof handles are single-use capability material.  A route owner first
    /// registers its independently observed facts, then exchanges the opaque
    /// handle for a binding token.  Commands cannot reach this registry.
    private var platformProofs: [UUID: AgentABIPlatformProofRegistration] = [:]
    private var platformConformances: [AgentAdapterConformance] = []
    private struct PendingLaunchPlan: Sendable {
        let plan: AgentLaunchPlan
        let threadID: AgentThreadID
        let binding: AgentTerminalBinding
    }
    private var pendingLaunchPlans: [UUID: PendingLaunchPlan] = [:]

    /// Frame room kept for the event envelope, tool-run descriptors and a
    /// receipt boundary beside the thread snapshot.
    static let eventOverheadReserveBytes = 262_144

    public init(registry: AgentProviderRegistry = .builtIn, eventSink: @escaping EventSink) {
        self.registry = registry
        self.center = AgentCenterRuntime(registry: registry,
            presentationLimitBytes: AgentABICommand.maximumPayloadBytes - Self.eventOverheadReserveBytes)
        self.eventSink = eventSink
    }

    /// Native platform code calls this only after proving the exact current
    /// route/process. The returned handle is capability material scoped to
    /// this runtime; command JSON can neither issue nor inspect it.
    @discardableResult
    public func registerPlatformProcessProof(_ proof: AgentABIPlatformProofRegistration) -> AgentABIPlatformProofHandle? {
        let handle = UUID()
        lock.lock()
        guard !destroyed else { lock.unlock(); return nil }
        platformProofs[handle] = proof
        lock.unlock()
        return .init(proofHandle: handle)
    }

    /// Swift-only convenience for route owners.  C/JNI use the separate proof
    /// entry point before submitting a registration that contains only its
    /// opaque `proofHandle`.
    @discardableResult
    public func registerPlatformBinding(
        threadID: AgentThreadID,
        hostID: UUID,
        binding: AgentTerminalBinding,
        sourceIdentity: String,
        processIDs: Set<Int>,
        validatedDirectories: Set<String> = [],
        mode: AgentABIPlatformBindingMode = .actionable
    ) -> UUID? {
        guard let proof = AgentABIPlatformProofRegistration(
            threadID: threadID,
            hostID: hostID,
            binding: binding,
            sourceIdentity: sourceIdentity,
            processIDs: Array(processIDs),
            validatedDirectories: Array(validatedDirectories)
        ), let proofHandle = registerPlatformProcessProof(proof),
           let registration = AgentABIPlatformBindingRegistration(
            threadID: threadID,
            hostID: hostID,
            binding: binding,
            sourceIdentity: sourceIdentity,
            validatedDirectories: Array(validatedDirectories),
            mode: mode,
            proofHandle: proofHandle.proofHandle
        ), let token = registerPlatformBinding(registration)?.bindingToken else { return nil }
        return token
    }

    /// Host-bridge entry point shared by Swift and C/JNI integration.  The
    /// payload is bounded and revalidated here; only this method mints the
    /// random capability.  `AgentABICommand` has no equivalent operation.
    public func registerPlatformBinding(_ registration: AgentABIPlatformBindingRegistration) -> AgentABIPlatformBindingToken? {
        lock.lock()
        guard !destroyed,
              let proof = platformProofs.removeValue(forKey: registration.proofHandle),
              proof.threadID == registration.threadID,
              proof.hostID == registration.hostID,
              proof.binding == registration.binding,
              proof.sourceIdentity == registration.sourceIdentity,
              Set(proof.validatedDirectories) == Set(registration.validatedDirectories)
        else { lock.unlock(); return nil }
        let isActionable = registration.mode == .actionable &&
            registration.binding.agentPID.map({ proof.processIDs.contains($0) }) == true
        let isObserveOnly = (registration.mode == .observeOnly || registration.mode == .inventoryObservation) && proof.processIDs.isEmpty &&
            registration.binding.agentPID == nil && registration.binding.capabilities == [.observe] &&
            registration.validatedDirectories.isEmpty
        guard isActionable || isObserveOnly else { lock.unlock(); return nil }
        if registration.mode == .inventoryObservation,
           let current = activeBindingTokenByThread[registration.threadID],
           platformBindings[current]?.mode == .actionable {
            // A lower-priority catalog observation cannot revoke a live
            // route, nor may it receive that route's actionable token. Normal
            // observeOnly fallback still retires a failed process proof.
            lock.unlock(); return nil
        }
        proofSequence &+= 1
        let authority = PlatformBindingAuthority(threadID: registration.threadID, hostID: registration.hostID, binding: registration.binding, sourceIdentity: registration.sourceIdentity, processIDs: Set(proof.processIDs), validatedDirectories: Set(registration.validatedDirectories), mode: registration.mode)
        if let live = livePlatformBindings[registration.threadID],
           AgentCenterRuntime.competesForLiveRoute(held: live, incoming: registration.binding) {
            if let pending = pendingBindingTokenByThread[registration.threadID], platformBindings[pending] == authority {
                pendingProofSequences[pending] = proofSequence
                lock.unlock(); return .init(bindingToken: pending)
            }
            let retired = retirePendingBindingLocked(for: registration.threadID)
            let token = UUID()
            platformBindings[token] = authority
            pendingBindingTokenByThread[registration.threadID] = token
            pendingProofSequences[token] = proofSequence
            lock.unlock()
            if let retired { enqueue { [self] in emitRetirements([retired]) } }
            return .init(bindingToken: token)
        }
        proofSequenceByThread[registration.threadID] = proofSequence
        // Fresh proof of the identical authority must not revoke commands
        // already queued by another lifecycle/projection/action consumer.
        // Proof handles remain single-use, and ANY changed authority still
        // replaces the token and retires its predecessor below.
        if let current = activeBindingTokenByThread[registration.threadID], platformBindings[current] == authority {
            lock.unlock()
            return .init(bindingToken: current)
        }
        let token = UUID()
        var retirements: [AgentABIRouteRetirement] = []
        if let pending = retirePendingBindingLocked(for: registration.threadID) { retirements.append(pending) }
        if let previous = activeBindingTokenByThread[registration.threadID],
           let retired = platformBindings.removeValue(forKey: previous) {
            noteRetired(previous, route: retired.route)
            retirements.append(.init(threadID: registration.threadID, bindingToken: previous,
                                     successor: registration.threadID, reason: .replaced))
        }
        platformBindings[token] = authority
        activeBindingTokenByThread[registration.threadID] = token
        lock.unlock()
        if !retirements.isEmpty {
            let retired = retirements
            enqueue { [self] in emitRetirements(retired) }
        }
        return .init(bindingToken: token)
    }

    /// Live validation is a platform-owned release gate, never a raw ABI
    /// assertion. Callers may only select from these attested records.
    public func registerPlatformConformances(_ conformances: [AgentAdapterConformance]) {
        let accepted = conformances.filter {
            $0.liveGatePassed && AgentProviderCapabilityGate.expectedFixtureDigests[$0.providerID] == $0.sourceFixtureDigest
        }
        lock.lock(); platformConformances = accepted; lock.unlock()
    }

    /// Route-owner-only Tier-A discovery. Candidates remain observe-only list
    /// entries; no binding capability or action authority is created here.
    @discardableResult
    public func registerPlatformCandidate(_ registration: AgentABIPlatformCandidateRegistration) -> Bool {
        lock.lock()
        guard !destroyed else { lock.unlock(); return false }
        let providerName = registry.manifest(for: registration.id.providerID)?.displayName ?? "Agent"
        lock.unlock()
        enqueue { [self] in
            await center.registerCandidate(
                registration.id, fallback: registration.fallback,
                providerName: providerName,
                title: registration.title == "Live agent" ? "\(providerName) terminal" : registration.title,
                hostDisplayLabel: registration.hostDisplayLabel,
                lastActivity: registration.lastActivityMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) },
                processIDs: Set(registration.processIDs)
            )
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        }
        return true
    }

    @discardableResult
    public func removePlatformCandidate(_ registration: AgentABIPlatformCandidateRemoval) -> Bool {
        lock.lock(); guard !destroyed else { lock.unlock(); return false }; lock.unlock()
        enqueue { [self] in
            await center.removeCandidate(registration.id)
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        }
        return true
    }

    /// Applies a fixed Tier-C conformance set using only compiled provider
    /// adapter IDs and fixture digests. This narrow platform bridge exists so
    /// Android cannot smuggle adapter/digest values through general configure
    /// JSON. It serializes capability reconfiguration before later commands.
    @discardableResult
    public func registerPlatformConformingProviders(
        _ registration: AgentABIPlatformConformanceRegistration
    ) -> Bool {
        let conformances = registration.providers.compactMap { provider -> AgentAdapterConformance? in
            let adapterID: String
            switch provider {
            case .opencode: adapterID = AgentOpenCodeSQLiteAdapter.adapterID
            case .pi: adapterID = AgentPiSessionAdapter.adapterID
            case .kimi: adapterID = AgentKimiWireAdapter.adapterID
            default: return nil
            }
            guard let digest = AgentProviderCapabilityGate.expectedFixtureDigests[provider] else { return nil }
            return AgentAdapterConformance(
                providerID: provider,
                adapterID: adapterID,
                sourceFixtureDigest: digest,
                liveGatePassed: true
            )
        }
        guard conformances.count == registration.providers.count else { return false }
        lock.lock()
        guard !destroyed else { lock.unlock(); return false }
        platformConformances = conformances
        let requested = registry.allManifests
        lock.unlock()
        enqueue { [self] in
            let active = lock.withLock { platformConformances }
            let configured = AgentProviderCapabilityGate().hardenedRegistry(requested: requested, conformances: active)
            registry = configured
            await center.configure(registry: configured, metadata: nil)
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        }
        return true
    }

    private func platformBinding(token: UUID?, threadID: AgentThreadID?) -> PlatformBindingAuthority? {
        guard let token else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let authority = platformBindings[token],
              activeBindingTokenByThread[authority.threadID] == token,
              threadID.map({ $0 == authority.threadID }) ?? true
        else { return nil }
        return authority
    }

    /// `platformBinding` for background commands, which name their thread.
    /// Nil means stale: tokens are minted synchronously but commands apply in
    /// queue order, so a newer proof or an `unbind` can retire a token while
    /// its command waits. A token still current for another thread is a
    /// malformed command instead.
    private func currentPlatformBinding(token: UUID?, threadID: AgentThreadID) throws -> PlatformBindingAuthority? {
        if let authority = platformBinding(token: token, threadID: threadID) { return authority }
        if platformBinding(token: token, threadID: nil) != nil { throw AgentABIError.invalidField }
        return nil
    }

    private func registrationBinding(token: UUID?, threadID: AgentThreadID) throws -> PlatformBindingAuthority? {
        let authority: PlatformBindingAuthority? = lock.withLock {
            guard let token, let authority = platformBindings[token],
                  activeBindingTokenByThread[authority.threadID] == token
                    || pendingBindingTokenByThread[authority.threadID] == token else { return nil }
            return authority
        }
        if let authority, authority.threadID != threadID { throw AgentABIError.invalidField }
        return authority
    }

    /// Refuses stale work under a code clients treat as routine, like
    /// `projection_staleBinding`; `abi_invalidField` reads as a broken command.
    private func rejectStaleBinding(_ command: AgentABICommand) {
        emit(.init(kind: .commandRejected, generation: nextGeneration(), code: "\(command.kind.rawValue)_staleBinding"))
    }

    /// Caller holds `lock`.
    private func retirePlatformBindingLocked(for threadID: AgentThreadID,
                                            successor: AgentThreadID? = nil,
                                            reason: AgentABIRouteRetirement.Reason) -> AgentABIRouteRetirement? {
        if let token = activeBindingTokenByThread.removeValue(forKey: threadID),
           let retired = platformBindings.removeValue(forKey: token) {
            noteRetired(token, route: retired.route)
            return .init(threadID: threadID, bindingToken: token, successor: successor, reason: reason)
        }
        return nil
    }

    /// Caller holds `lock`. An unadmitted proof never replaces an owner.
    private func retirePendingBindingLocked(for threadID: AgentThreadID) -> AgentABIRouteRetirement? {
        guard let token = pendingBindingTokenByThread.removeValue(forKey: threadID),
              let retired = platformBindings.removeValue(forKey: token) else { return nil }
        pendingProofSequences.removeValue(forKey: token)
        noteRetired(token, route: retired.route)
        return .init(threadID: threadID, bindingToken: token, reason: .unbound)
    }

    private func emitRetirements(_ retirements: [AgentABIRouteRetirement]) {
        guard !retirements.isEmpty else { return }
        emit(.init(kind: .routesRetired, generation: nextGeneration(), retirements: retirements))
    }

    private func publishRetiredRoutes(_ bindings: [(AgentThreadID, AgentTerminalBinding)],
                                      reason: AgentABIRouteRetirement.Reason) async {
        let retirements: [AgentABIRouteRetirement] = lock.withLock {
            bindings.compactMap { id, binding in
                if livePlatformBindings[id] == binding { livePlatformBindings.removeValue(forKey: id) }
                guard let token = activeBindingTokenByThread[id], platformBindings[token]?.binding == binding else { return nil }
                return retirePlatformBindingLocked(for: id, reason: reason)
            }
        }
        emitRetirements(retirements)
        for (id, _) in bindings {
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: id)))
        }
        emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
    }

    /// Caller holds `lock`.
    private func noteRetired(_ token: UUID, route: PlatformRoute) {
        retiredTokenRoutes[token] = route
        retiredTokenOrder.append(token)
        if retiredTokenOrder.count > 1_024 { retiredTokenRoutes.removeValue(forKey: retiredTokenOrder.removeFirst()) }
    }

    public func submit(_ data: Data) {
        enqueue { [self] in
            // Carry the command kind into the rejection. `missingField` and
            // `invalidField` are each thrown from a dozen branches, so the bare
            // code said only "some command was refused" -- true of every
            // failure this ABI has ever reported, and useless in a device log.
            var kind: String?
            var ingestionRequestID: String?
            var resultLease: AgentActionLease?
            do {
                let command = try AgentABICommand.decode(data)
                kind = command.kind.rawValue
                ingestionRequestID = command.ingestionRequestID
                if command.kind == .result { resultLease = command.lease }
                try await apply(command)
                for id in await center.takeIngestionEvictions() {
                    emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: id), code: "cacheEvicted"))
                }
            } catch {
                // `decode` validates before returning, so a rejected command
                // never reached the `kind` assignment above. Recover the kind
                // from the raw payload rather than reporting a bare
                // `abi_missingField` that fits fifteen different branches.
                emit(.init(
                    kind: ingestionRequestID == nil ? .commandRejected : .projectionApplied,
                    generation: nextGeneration(),
                    lease: resultLease,
                    code: Self.code(for: error, command: kind ?? Self.kindHint(from: data)),
                    ingestionRequestID: ingestionRequestID
                ))
            }
        }
    }

    public func destroy() {
        lock.lock()
        guard !destroyed else { lock.unlock(); return }
        destroyed = true
        platformProofs.removeAll(keepingCapacity: false)
        platformBindings.removeAll(keepingCapacity: false)
        activeBindingTokenByThread.removeAll(keepingCapacity: false)
        pendingBindingTokenByThread.removeAll(keepingCapacity: false)
        pendingProofSequences.removeAll(keepingCapacity: false)
        livePlatformBindings.removeAll(keepingCapacity: false)
        proofSequenceByThread.removeAll(keepingCapacity: false)
        retiredTokenRoutes.removeAll(keepingCapacity: false)
        retiredTokenOrder.removeAll(keepingCapacity: false)
        // Handle teardown is not a semantic command and must never deliver a
        // late callback into an owner that is already disposing its sink. The
        // versioned `.destroy` command remains the acknowledged path which
        // emits one `.destroyed` event.
        callbacksSuppressed = true
        let previous = tail
        tail = Task { [self] in
            await previous.value
            issuedActionLeases.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        // Android disables Agent Center by destroying its runtime; parsed
        // Markdown is process-wide, so it goes with the handle.
        AgentMarkdownDocument.purgeCache()
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard !destroyed else { lock.unlock(); return }
        let previous = tail
        tail = Task { await previous.value; await operation() }
        lock.unlock()
    }

    private func apply(_ command: AgentABICommand) async throws {
        switch command.kind {
        case .configure:
            let conformances = lock.withLock { platformConformances }
            let configured = command.manifests.map { AgentProviderCapabilityGate().hardenedRegistry(requested: $0, conformances: conformances) }
            if let configured { registry = configured }
            if let memory = command.physicalMemoryBytes {
                await center.configure(budget: .forDevice(physicalMemoryBytes: UInt64(memory),
                                                          isLowRAMDevice: command.lowRAMDevice ?? false))
            }
            await center.configure(registry: configured, metadata: command.metadata)
            if let labels = command.hostDisplayLabels {
                let named = labels.reduce(into: [UUID: String]()) { values, entry in
                    if let id = UUID(uuidString: entry.key) { values[id] = entry.value }
                }
                for id in await center.updateHostDisplayLabels(named) {
                    emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: id)))
                }
            }
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .bind:
            guard let threadID = command.threadID else { throw AgentABIError.missingField }
            guard let authority = try registrationBinding(token: command.bindingToken, threadID: threadID) else {
                rejectStaleBinding(command)
                break
            }
            let binding = authority.binding
            let manifest = registry.manifest(for: threadID.providerID)
            let canSend = binding.capabilities.contains(.send)
            let canInterrupt = binding.capabilities.contains(.interrupt)
            let canAnswer = binding.capabilities.contains(.promptAnswer)
            let hasSafeAction = manifest?.actions.contains(where: { action in
                switch action {
                case .send, .queue: canSend
                case .interrupt: canInterrupt
                case .answerPrompt: canAnswer
                case .spawn, .fork: binding.hasCurrentTmuxTarget
                }
            }) ?? false
            let availability = AgentAvailability(
                content: manifest?.hasTranscript ?? false,
                status: manifest != nil,
                actions: hasSafeAction,
                spawn: (manifest?.actions.contains(.spawn) ?? false) && binding.hasCurrentTmuxTarget,
                fork: (manifest?.actions.contains(.fork) ?? false) && binding.hasCurrentTmuxTarget,
                search: manifest?.hasTranscript ?? false,
                reason: manifest == nil ? .unsupported : nil
            )
            if let modified = command.inventoryModified {
                guard !binding.capabilities.contains(.send), !binding.capabilities.contains(.interrupt),
                      !binding.capabilities.contains(.promptAnswer), binding.agentPID == nil else { throw AgentABIError.invalidField }
                await center.registerInventorySummary(.init(id: threadID, title: "\(manifest?.displayName ?? "Agent") · \(String(threadID.providerSessionID.prefix(8)))",
                    providerName: manifest?.displayName ?? "Unknown", hostDisplayLabel: command.hostDisplayLabel ?? "",
                    status: .unavailable, attention: .none, lastActivity: Date(timeIntervalSince1970: Double(modified)),
                    availability: .init(content: manifest?.hasTranscript ?? false, status: false,
                        actions: false, spawn: false, fork: false, search: false)), binding: binding)
                // Inventory pages batch admission; the caller requests one
                // list snapshot after the page, not O(n²) lists per record.
                break
            }
            let registration = await center.register(.init(id: threadID, providerName: manifest?.displayName ?? "Unknown",
                hostDisplayLabel: command.hostDisplayLabel ?? "", availability: availability), binding: binding)
            if case .liveElsewhere = registration {
                emit(.init(kind: .commandRejected, generation: nextGeneration(), thread: await center.snapshot(for: threadID),
                           code: "bind_liveElsewhere"))
                break
            }
            let retirements: [AgentABIRouteRetirement] = lock.withLock {
                guard let token = command.bindingToken, pendingBindingTokenByThread[threadID] == token else { return [] }
                let retired = retirePlatformBindingLocked(for: threadID, successor: threadID, reason: .replaced)
                activeBindingTokenByThread[threadID] = token
                pendingBindingTokenByThread.removeValue(forKey: threadID)
                proofSequenceByThread[threadID] = pendingProofSequences.removeValue(forKey: token)
                return retired.map { [$0] } ?? []
            }
            emitRetirements(retirements)
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: threadID)))
            // `bind` is what admits a thread to the centre, so the list must be
            // re-emitted here. Only `select`/`filter`/`configure` used to emit
            // one, and a client patches existing rows from thread snapshots --
            // so a thread discovered after the last list had no row to patch and
            // never appeared at all. On a host running two agents, the second
            // one was invisible until the user happened to change a filter.
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .unbind:
            guard let threadID = command.threadID else { throw AgentABIError.missingField }
            // A platform tearing down one route names a token it issued there.
            // Another route may have proved this thread since the command was
            // queued; its token survives, and so does its binding once its own
            // bind has applied. The same route re-proving itself is still the
            // route being torn down, and an unknown token unbinds as unnamed.
            var retirements: [AgentABIRouteRetirement] = []
            let successor: PlatformBindingAuthority? = lock.withLock {
                if let named = command.bindingToken, pendingBindingTokenByThread[threadID] == named {
                    if let retired = retirePendingBindingLocked(for: threadID) { retirements.append(retired) }
                    return activeBindingTokenByThread[threadID].flatMap { platformBindings[$0] }
                }
                let namedRoute = command.bindingToken.flatMap { platformBindings[$0]?.route ?? retiredTokenRoutes[$0] }
                if let pending = pendingBindingTokenByThread[threadID], let authority = platformBindings[pending],
                   namedRoute == nil || namedRoute == authority.route,
                   let retired = retirePendingBindingLocked(for: threadID) { retirements.append(retired) }
                guard let named = command.bindingToken,
                      let active = activeBindingTokenByThread[threadID], active != named,
                      let current = platformBindings[active],
                      let route = namedRoute, route != current.route else {
                    if let retired = retirePlatformBindingLocked(for: threadID, reason: .unbound) { retirements.append(retired) }
                    livePlatformBindings.removeValue(forKey: threadID)
                    return nil
                }
                return current
            }
            var keepsSuccessorBinding = false
            if let successor { keepsSuccessorBinding = (await center.snapshot(for: threadID))?.binding == successor.binding }
            if !keepsSuccessorBinding { await center.replaceBinding(nil, for: threadID) }
            emitRetirements(retirements)
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: threadID)))
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .lifecycle:
            guard let threadID = command.threadID else { throw AgentABIError.missingField }
            guard let authority = try currentPlatformBinding(token: command.bindingToken, threadID: threadID) else {
                rejectStaleBinding(command)
                break
            }
            guard let lifecycle = command.lifecycle,
                  lifecycle.providerID == threadID.providerID,
                  lifecycle.providerSessionID == threadID.providerSessionID,
                  (await center.snapshot(for: threadID))?.binding == authority.binding
            else { throw AgentABIError.invalidField }
            let proof = AgentLifecycleBindingProof(hostID: authority.hostID, binding: authority.binding, sourceIdentity: authority.sourceIdentity, processIDs: authority.processIDs)
            // Protect this holder while the actor reduces its first frame.
            // Proof registration is synchronous and may race that await.
            let previousLive = lock.withLock { livePlatformBindings.updateValue(authority.binding, forKey: threadID) }
            let acceptance = await center.applyLifecycle(lifecycle, proof: proof, expectedSourceIdentity: authority.sourceIdentity)
            // A conversation the pane's process replaced left Core. Its token
            // would still count as the live route and refuse the session's
            // later inventory observation. One the platform proved again
            // after this frame's conversation (`/resume` back to it, queued
            // behind this frame) keeps that newer proof's token.
            let replaced = await center.takeReplacedConversations()
            let retirements: [AgentABIRouteRetirement] = lock.withLock {
                if case .rejected = acceptance { livePlatformBindings[threadID] = previousLive }
                for id in replaced.keys { livePlatformBindings.removeValue(forKey: id) }
                let framed = proofSequenceByThread[threadID] ?? 0
                return replaced.compactMap { id, successor in
                    guard (proofSequenceByThread[id] ?? 0) <= framed else { return nil }
                    return retirePlatformBindingLocked(for: id, successor: successor, reason: .replaced)
                }
            }
            emitRetirements(retirements)
            switch acceptance {
            case .accepted(let threadID):
                let snapshot: AgentThreadSnapshot?
                if let threadID {
                    snapshot = await center.snapshot(for: threadID)
                } else {
                    snapshot = nil
                }
                emit(.init(kind: .lifecycleAccepted, generation: nextGeneration(), thread: snapshot))
                // An accepted frame can re-key a thread onto its provider
                // session ID, which changes who is in the list.
                emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
            case .rejected(.staleBinding):
                // Routine: a frame for a conversation that no longer holds
                // its pane, such as the late end of one `/clear` replaced.
                rejectStaleBinding(command)
            case .rejected(let rejection):
                emit(.init(kind: .commandRejected, generation: nextGeneration(), code: rejection.rawValue))
            }
        case .occupancy:
            guard let observation = command.occupancy else { throw AgentABIError.missingField }
            let retired = await center.reconcileOccupancyRetiringBindings(observation)
            await publishRetiredRoutes(retired, reason: .absent)
        case .conversationCleared:
            guard let providerID = command.providerID, let binding = command.binding,
                  binding.agentPID != nil else { throw AgentABIError.missingField }
            let retired = await center.clearConversationsRetiringBindings(providerID: providerID, binding: binding,
                timestampNanoseconds: command.sourceTimestampNanoseconds)
            await publishRetiredRoutes(retired, reason: .cleared)
        case .projection:
            guard let threadID = command.threadID else { throw AgentABIError.missingField }
            guard let authority = platformBinding(token: command.bindingToken, threadID: threadID),
                  (await center.snapshot(for: threadID))?.binding == authority.binding else {
                // Remote reads can finish after a route/proof replacement.
                // Reject their data, but distinguish normal stale work from a
                // malformed ABI command so native clients need not interrupt
                // the user with a global error dialog.
                emit(.init(kind: command.ingestionRequestID == nil ? .commandRejected : .projectionApplied,
                    generation: nextGeneration(), code: "projection_staleBinding", ingestionRequestID: command.ingestionRequestID))
                break
            }
            var incoming = command.projection
            if let wire = command.ingestionHookWire, let epoch = command.ingestionEpoch, let thread = command.ingestionThread {
                guard let bytes = Data(base64Encoded: wire) else { throw AgentABIError.invalidField }
                let hook = try AgentIngestionHook.decode(bytes, epoch: epoch, thread: thread)
                guard hook.requestID == command.ingestionRequestID else { throw AgentABIError.invalidField }
                let accepted = await center.apply(hook: hook, to: threadID)
                emit(.init(kind: .projectionApplied, generation: nextGeneration(), thread: await center.snapshot(for: threadID),
                    code: accepted ? "hookApplied" : "hookIgnored", ingestionRequestID: command.ingestionRequestID))
                break
            }
            if let wire = command.ingestionSummaryWire, let epoch = command.ingestionEpoch, let thread = command.ingestionThread {
                guard let bytes = Data(base64Encoded: wire) else { throw AgentABIError.invalidField }
                let summary = try AgentIngestionSummary.decode(bytes, epoch: epoch, thread: thread)
                guard summary.requestID == command.ingestionRequestID else { throw AgentABIError.invalidField }
                let accepted = await center.apply(summary: summary, to: threadID)
                emit(.init(kind: .projectionApplied, generation: nextGeneration(),
                    code: accepted ? "summaryApplied" : "resyncRequired", ingestionRequestID: command.ingestionRequestID))
                if accepted { emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot())) }
                break
            }
            if let wire = command.ingestionWire, let epoch = command.ingestionEpoch, let thread = command.ingestionThread {
                guard let bytes = Data(base64Encoded: wire) else { throw AgentABIError.invalidField }
                incoming = try AgentIngestionProjection.decode(bytes, epoch: epoch, thread: thread)
                guard incoming?.ingestion?.requestID == command.ingestionRequestID else { throw AgentABIError.invalidField }
            }
            if let projection = incoming {
                // A page's `sourceIdentity` is transcript provenance — the
                // remote projector reports the transcript file's
                // dev/inode/size/mtime so the reducer can reset cached records
                // when the file rotates. The authority's `sourceIdentity` is
                // route provenance ("android:<session>:<generation>:%3"). They
                // are different namespaces and never compare equal against a
                // real projector, so requiring it here rejected every page a
                // device ever sent. `apply(page:)` already handles a changed
                // transcript source; the capability checks above are what
                // actually bind this page to this route.
                guard registry.manifest(for: threadID.providerID)?.hasTranscript == true else {
                    emit(.init(kind: command.ingestionRequestID == nil ? .commandRejected : .projectionApplied,
                        generation: nextGeneration(), code: "projection_transcriptUnavailable", ingestionRequestID: command.ingestionRequestID))
                    break
                }
                let result = await center.apply(page: projection, to: threadID)
                let boundary = command.ingestionReceipt == true && result.accepted
                    ? try? await center.nativeReceiptBoundary(for: threadID, after: projection) : nil
                emit(.init(kind: .projectionApplied, generation: nextGeneration(), thread: await center.snapshot(for: threadID),
                    code: String(describing: result), ingestion: projection.ingestion, receiptBoundary: boundary,
                    ingestionRequestID: command.ingestionRequestID))
            } else if let error = command.projectionError {
                emit(.init(kind: .commandRejected, generation: nextGeneration(), code: error.rawValue))
            } else {
                throw AgentABIError.missingField
            }
        case .select:
            await center.select(threadID: command.threadID)
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .viewportAnchor:
            guard let threadID = command.threadID else { throw AgentABIError.missingField }
            await center.setIngestionViewportAnchor(command.recordID, for: threadID)
        case .hostCapacity:
            for (key, segments) in command.hostWindowSegments ?? [:] {
                if let hostID = UUID(uuidString: key) { await center.setIngestionHostSegments(segments, for: hostID, thread: command.threadID) }
            }
        case .releaseIngestionWindow:
            guard let threadID = command.threadID else { throw AgentABIError.missingField }
            await center.releaseIngestionWindow(for: threadID)
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: threadID)))
        case .filter:
            if let grouping = command.grouping { await center.setGrouping(grouping) }
            if let listFilter = command.listFilter { await center.setFilter(listFilter) }
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .search:
            let snapshot: AgentSearchSnapshot
            if let supplied = command.searchSnapshot {
                await center.applySearch(supplied)
                snapshot = supplied
            } else {
                snapshot = await center.search(query: command.query ?? "")
            }
            emit(.init(kind: .searchSnapshot, generation: nextGeneration(), search: snapshot))
        case .promptObservation:
            guard let request = command.promptObservation else { throw AgentABIError.missingField }
            let observed = AgentPromptGrammar.observe(request)
            let plan = command.promptAnswerPlan.map { input in
                AgentPromptAnswerPlanner.next(provider: request.providerID, goal: input.goal,
                    expectedSignature: input.expectedSignature, anchor: input.anchor,
                    observation: observed, history: input.history)
            }
            emit(.init(kind: .promptObservation, generation: nextGeneration(), promptObservation: observed, promptAnswerPlan: plan,
                promptRequestID: command.promptRequestID))
        case .livePromptObservation:
            guard let request = command.promptObservation, let threadID = command.threadID,
                  command.observedGeneration != nil || command.observedLifecycleSequence != nil else { throw AgentABIError.invalidField }
            guard let authority = try currentPlatformBinding(token: command.bindingToken, threadID: threadID) else {
                rejectStaleBinding(command)
                break
            }
            // Platforms poll while a thread's `livePromptWatch` holds; an
            // unchanged screen must not resend the whole thread each time.
            guard await center.observeLivePrompt(request, threadID: threadID, binding: authority.binding,
                observedGeneration: command.observedGeneration,
                observedLifecycleSequence: command.observedLifecycleSequence,
                onDisplay: command.onDisplay == true) else { break }
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: threadID)))
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .terminalVisible:
            guard let threadID = command.threadID, let generation = command.observedGeneration else { throw AgentABIError.invalidField }
            guard let authority = try currentPlatformBinding(token: command.bindingToken, threadID: threadID) else {
                rejectStaleBinding(command)
                break
            }
            _ = await center.acknowledgeTerminal(threadID: threadID, binding: authority.binding, observedGeneration: generation)
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: threadID)))
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .memoryWarning:
            await center.memoryWarning()
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .title:
            if let budget = command.titleBudget {
                await center.setTitleCharacterBudget(budget)
                emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
            } else if let threadID = command.threadID, let title = command.generatedTitle, let seed = command.titleSeed {
                // A refused title is not an error: the thread has since gained
                // one the agent wrote, or moved on to a different opening
                // prompt. Emitting nothing keeps a stale answer invisible.
                guard await center.applyGeneratedTitle(title, for: threadID, seed: seed) else { break }
                emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: threadID)))
                emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
            }
        case .action:
            guard let threadID = command.threadID, let action = command.action,
                  let authority = platformBinding(token: command.bindingToken, threadID: threadID),
                  authority.mode == .actionable,
                  let payload = command.actionPayload,
                  payload.isValid(for: action, threadID: threadID, binding: authority.binding) else { throw AgentABIError.invalidField }
            let binding = authority.binding
            let lease = try await center.acquireLease(threadID: threadID, action: action, binding: binding, textRequest: payload.text)
            if let bindingToken = command.bindingToken, action == .send || action == .queue {
                issuedActionLeases[lease.token] = .init(lease: lease, bindingToken: bindingToken)
            }
            emit(.init(kind: .actionPlan, generation: nextGeneration(), thread: await center.snapshot(for: threadID), lease: lease, actionPayload: command.actionPayload))
        case .armOutgoing, .outgoingDispatched:
            guard let lease = command.lease,
                  let authority = platformBinding(token: command.bindingToken, threadID: lease.threadID),
                  authority.mode == .actionable, authority.binding == lease.binding else { throw AgentABIError.invalidField }
            if command.kind == .outgoingDispatched {
                try await center.markOutgoingDispatched(lease)
            } else if let frontier = command.frontier {
                try await center.armOutgoing(lease, frontier: frontier)
            } else if let page = command.projection {
                try await center.armOutgoing(lease, freshPage: page)
            } else { throw AgentABIError.invalidField }
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: lease.threadID), lease: lease,
                code: command.kind == .outgoingDispatched ? "outgoingDispatched" : "outgoingArmed"))
        case .launch:
            guard let threadID = command.threadID, let intent = command.launch else { throw AgentABIError.missingField }
            guard let authority = platformBinding(token: command.bindingToken, threadID: threadID),
                  authority.mode == .actionable,
                  (await center.snapshot(for: threadID))?.binding == authority.binding,
                  authority.binding.liveSessionID == intent.liveSessionID,
                  authority.validatedDirectories.contains(intent.workingDirectory.value) else { throw AgentABIError.invalidField }
            if case .fork(let source, _) = intent.kind {
                guard source.threadID.providerID == intent.providerID,
                      let sourceSnapshot = await center.snapshot(for: source.threadID),
                      sourceSnapshot.binding == authority.binding,
                      (source.turnID != nil || source.recordID != nil) else { throw AgentABIError.invalidField }
            }
            let binding: AgentTerminalBinding? = authority.binding
            let result = AgentLaunchValidator(registry: registry).plan(intent, binding: binding)
            switch result {
            case .success(let plan):
                if let requestID = plan.requestID { pendingLaunchPlans[requestID] = .init(plan: plan, threadID: threadID, binding: authority.binding) }
                emit(.init(kind: .launchPlan, generation: nextGeneration(), launchPlan: plan))
            case .failure(let error): emit(.init(kind: .commandRejected, generation: nextGeneration(), code: error.rawValue))
            }
        case .result:
            if let lease = command.lease {
                guard let outcome = command.resultOutcome else { throw AgentABIError.invalidField }
                if outcome.status == .notSent {
                    guard let issued = issuedActionLeases[lease.token], issued.lease == lease,
                          issued.bindingToken == command.bindingToken else { throw AgentABIError.invalidField }
                } else {
                    guard let authority = platformBinding(token: command.bindingToken, threadID: lease.threadID),
                          authority.mode == .actionable, authority.binding == lease.binding,
                          (await center.snapshot(for: lease.threadID))?.binding == lease.binding else {
                        // Authority retired while this action finished: its
                        // result no longer applies, but it still ends the
                        // issued lease, so the identity cannot leak and a
                        // later `notSent` cannot withdraw a possibly typed bubble.
                        if let issued = issuedActionLeases[lease.token], issued.lease == lease,
                           issued.bindingToken == command.bindingToken {
                            issuedActionLeases.removeValue(forKey: lease.token)
                        }
                        throw AgentABIError.invalidField
                    }
                }
                issuedActionLeases.removeValue(forKey: lease.token)
                await center.releaseLease(lease, result: outcome.status)
                emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: lease.threadID), code: outcome.status.rawValue))
            } else if let receipt = command.launchReceipt,
                      let requestID = receipt.requestID,
                      let pending = pendingLaunchPlans[requestID],
                      let authority = platformBinding(token: command.bindingToken, threadID: pending.threadID),
                      authority.mode == .actionable,
                      authority.binding == pending.binding,
                      (await center.snapshot(for: pending.threadID))?.binding == pending.binding,
                      receipt.verifies(pending.plan) {
                // Keep the pending plan on every malformed/stale receipt; a
                // subsequent fresh verification may still complete it.
                pendingLaunchPlans.removeValue(forKey: requestID)
                emit(.init(kind: .launchResult, generation: nextGeneration(), launchReceipt: receipt, code: "receiptAccepted"))
            } else { throw AgentABIError.invalidField }
        case .acknowledge:
            guard let threadID = command.threadID, let recordID = command.recordID else { throw AgentABIError.missingField }
            // A repeated read of the same newest row changes nothing.
            guard await center.acknowledge(threadID: threadID, visibleRecordID: recordID) else { break }
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: threadID)))
        case .acknowledgeCompletion:
            guard let threadID = command.threadID, let epoch = command.attentionEpoch else { throw AgentABIError.missingField }
            // A stale or repeated read changes nothing and emits nothing.
            guard await center.acknowledgeCompletion(threadID: threadID, observedEpoch: epoch) else { break }
            emit(.init(kind: .threadSnapshot, generation: nextGeneration(), thread: await center.snapshot(for: threadID)))
            emit(.init(kind: .listSnapshot, generation: nextGeneration(), list: await center.listSnapshot()))
        case .destroy:
            destroyFromOperation()
        }
    }

    private func destroyFromOperation() {
        lock.lock()
        guard !destroyed else { lock.unlock(); return }
        destroyed = true
        platformProofs.removeAll(keepingCapacity: false)
        platformBindings.removeAll(keepingCapacity: false)
        activeBindingTokenByThread.removeAll(keepingCapacity: false)
        pendingBindingTokenByThread.removeAll(keepingCapacity: false)
        pendingProofSequences.removeAll(keepingCapacity: false)
        livePlatformBindings.removeAll(keepingCapacity: false)
        proofSequenceByThread.removeAll(keepingCapacity: false)
        retiredTokenRoutes.removeAll(keepingCapacity: false)
        retiredTokenOrder.removeAll(keepingCapacity: false)
        issuedActionLeases.removeAll(keepingCapacity: false)
        lock.unlock()
        emit(.init(kind: .destroyed, generation: nextGeneration()))
    }

    private func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    private func emit(_ event: AgentABIEvent) {
        let data: Data
        if let encoded = event.boundedEncodedForABI().data {
            data = encoded
        } else {
            // Never silently omit an accepted operation because a future
            // domain addition exceeds the canonical callback budget.
            guard let fallback = try? AgentABIEvent(
                kind: .commandRejected,
                generation: event.generation,
                code: "abi_event_too_large"
            ).encoded() else { return }
            data = fallback
        }
        lock.lock()
        let shouldDeliver = !callbacksSuppressed
        lock.unlock()
        guard shouldDeliver else { return }
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.callbackScopeKey]
        dictionary[Self.callbackScopeKey] = callbackScopeToken
        defer {
            if let previous { dictionary[Self.callbackScopeKey] = previous }
            else { dictionary.removeObject(forKey: Self.callbackScopeKey) }
        }
        eventSink(data)
    }

    private var isExecutingEventSinkOnCurrentThread: Bool {
        Thread.current.threadDictionary[Self.callbackScopeKey] as? String == callbackScopeToken
    }

    private static let callbackScopeKey = "com.bambouville.tessera.agent-abi.callback-runtime"

    /// Best-effort command kind for a payload that failed before `apply`.
    private static func kindHint(from data: Data) -> String? {
        struct KindOnly: Decodable { let kind: String }
        return (try? JSONDecoder().decode(KindOnly.self, from: data))?.kind
    }

    private static func code(for error: Error, command: String? = nil) -> String {
        let suffix = command.map { "@\($0)" } ?? ""
        if let error = error as? AgentABIError { return "abi_\(String(describing: error))\(suffix)" }
        // A lease refusal (`actionInFlight`, `staleBinding`, ...) must name its
        // command too: a platform releases its action gate on `@action`.
        if let error = error as? AgentActionError { return "\(error.rawValue)\(suffix)" }
        if let error = error as? AgentIngestionError {
            switch error {
            case .malformedFrame: return "ingestion_malformedFrame"
            case .capacityExceeded: return "ingestion_capacityExceeded"
            case .staleEpoch: return "ingestion_staleEpoch"
            case .incompletePage: return "ingestion_incompletePage"
            case .remote: return "ingestion_remoteRejected"
            }
        }
        // A decoding failure is the most common way a platform's JSON and this
        // ABI disagree, and it used to collapse into the same opaque
        // `command_failed` as every other thrown error -- the same blindness as
        // the C entry points returning -1 for both "could not decode" and
        // "refused". Name the field, so a device log says which key is wrong
        // instead of only that something was.
        if let error = error as? DecodingError { return "decode_\(describe(error))\(suffix)" }
        return "command_failed\(suffix)"
    }

    /// Field names and types only; never a decoded value, so this stays safe to
    /// put in a diagnostic log and bounded regardless of payload size.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
            return joined.isEmpty ? "<root>" : joined
        }
        let described: String
        switch error {
        case .keyNotFound(let key, let context): described = "missingKey:\(path(context)).\(key.stringValue)"
        case .typeMismatch(let type, let context): described = "typeMismatch:\(path(context)):\(type)"
        case .valueNotFound(let type, let context): described = "valueNotFound:\(path(context)):\(type)"
        case .dataCorrupted(let context): described = "dataCorrupted:\(path(context))"
        @unknown default: described = "unknown"
        }
        return String(described.prefix(160))
    }
}

private extension JSONEncoder {
    static var agentABI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public typealias TesseraAgentABIEventCallback = @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void

private final class CAgentABIRuntime: @unchecked Sendable {
    let runtime: AgentABIRuntime

    init(callback: @escaping TesseraAgentABIEventCallback, context: UnsafeMutableRawPointer?) {
        let callbackBox = AgentCallbackBox(callback: callback, context: context)
        runtime = AgentABIRuntime { data in
            data.withUnsafeBytes { raw in
                callbackBox.callback(raw.bindMemory(to: UInt8.self).baseAddress, data.count, callbackBox.context)
            }
        }
    }
}

private final class AgentCallbackBox: @unchecked Sendable {
    let callback: TesseraAgentABIEventCallback
    let context: UnsafeMutableRawPointer?
    init(callback: @escaping TesseraAgentABIEventCallback, context: UnsafeMutableRawPointer?) {
        self.callback = callback
        self.context = context
    }
}

private enum CAgentABIRegistry {
    private static let lock = NSLock()
    private static var nextToken: UInt = 1
    private static var runtimes: [UInt: CAgentABIRuntime] = [:]

    static func insert(_ runtime: CAgentABIRuntime) -> UnsafeMutableRawPointer {
        lock.lock(); defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        runtimes[token] = runtime
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    static func withRuntime<T>(_ handle: UnsafeMutableRawPointer?, _ body: (CAgentABIRuntime) -> T) -> T? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let runtime = runtimes[token] else { return nil }
        return body(runtime)
    }

    static func remove(_ handle: UnsafeMutableRawPointer?) -> CAgentABIRuntime? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return runtimes.removeValue(forKey: token)
    }
}

@_cdecl("tessera_agent_abi_version")
public func tesseraAgentABIVersion() -> UInt32 { UInt32(AgentABICommand.currentVersion) }

@_cdecl("tessera_agent_abi_max_payload_bytes")
public func tesseraAgentABIMaxPayloadBytes() -> Int { AgentABICommand.maximumPayloadBytes }

@_cdecl("tessera_agent_runtime_create")
public func tesseraAgentRuntimeCreate(callback: @escaping TesseraAgentABIEventCallback, context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    CAgentABIRegistry.insert(CAgentABIRuntime(callback: callback, context: context))
}

@_cdecl("tessera_agent_runtime_send")
public func tesseraAgentRuntimeSend(handle: UnsafeMutableRawPointer?, bytes: UnsafePointer<UInt8>?, count: Int) -> Int32 {
    guard let bytes, count > 0, count <= AgentABICommand.maximumPayloadBytes else { return -1 }
    guard CAgentABIRegistry.withRuntime(handle, { $0.runtime.submit(Data(bytes: bytes, count: count)) }) != nil else { return -2 }
    return 0
}

/// Registers independently observed route/process facts and returns a
/// single-use opaque proof handle. This privileged bridge API is intentionally
/// not part of `send`; raw ABI commands cannot submit proof claims.
@_cdecl("tessera_agent_runtime_register_platform_proof")
public func tesseraAgentRuntimeRegisterPlatformProof(
    handle: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int,
    responseBytes: UnsafeMutablePointer<UInt8>?,
    responseCapacity: Int,
    responseCount: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let bytes, let responseBytes, let responseCount,
          count > 0, count <= AgentABIPlatformProofRegistration.maximumPayloadBytes,
          responseCapacity > 0, responseCapacity <= AgentABIPlatformProofRegistration.maximumPayloadBytes,
          let proof = try? AgentABIPlatformProofRegistration.decode(Data(bytes: bytes, count: count))
    else { return -1 }
    enum Attempt { case rejected; case accepted(Data) }
    guard let attempt = CAgentABIRegistry.withRuntime(handle, { boxed in
        guard let proofHandle = boxed.runtime.registerPlatformProcessProof(proof),
              let data = try? JSONEncoder.agentABI.encode(proofHandle), data.count <= responseCapacity
        else { return Attempt.rejected }
        return Attempt.accepted(data)
    }) else { return -2 }
    guard case .accepted(let response) = attempt else { return -1 }
    response.copyBytes(to: responseBytes, count: response.count)
    responseCount.pointee = response.count
    return 0
}

/// Exchanges a previously issued proof handle for a binding token and writes a
/// canonical `AgentABIPlatformBindingToken` JSON response into caller-owned
/// storage. The registration's identity facts must exactly equal the proof;
/// it contains no process IDs. Return values: 0 accepted, -1 malformed input
/// or insufficient output space, -2 stale handle.
@_cdecl("tessera_agent_runtime_register_platform_binding")
public func tesseraAgentRuntimeRegisterPlatformBinding(
    handle: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int,
    responseBytes: UnsafeMutablePointer<UInt8>?,
    responseCapacity: Int,
    responseCount: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let bytes, let responseBytes, let responseCount,
          count > 0, count <= AgentABIPlatformBindingRegistration.maximumPayloadBytes,
          responseCapacity > 0, responseCapacity <= AgentABIPlatformBindingRegistration.maximumPayloadBytes,
          let registration = try? AgentABIPlatformBindingRegistration.decode(Data(bytes: bytes, count: count))
    else { return -1 }

    enum Attempt { case rejected; case accepted(Data) }
    guard let attempt = CAgentABIRegistry.withRuntime(handle, { boxed in
        guard let token = boxed.runtime.registerPlatformBinding(registration),
              let data = try? JSONEncoder.agentABI.encode(token),
              data.count <= responseCapacity else { return Attempt.rejected }
        return Attempt.accepted(data)
    }) else { return -2 }
    guard case .accepted(let response) = attempt else { return -1 }
    response.copyBytes(to: responseBytes, count: response.count)
    responseCount.pointee = response.count
    return 0
}

/// Registers provider IDs that have passed a platform-owned live conformance
/// gate. Adapter IDs and fixture digests are selected entirely in Swift from
/// compiled attestations. Returns 0 accepted, -1 malformed/rejected, -2 stale.
@_cdecl("tessera_agent_runtime_register_platform_conformances")
public func tesseraAgentRuntimeRegisterPlatformConformances(
    handle: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int
) -> Int32 {
    guard let bytes,
          count > 0, count <= AgentABIPlatformConformanceRegistration.maximumPayloadBytes,
          let registration = try? AgentABIPlatformConformanceRegistration.decode(Data(bytes: bytes, count: count))
    else { return -1 }
    guard let accepted = CAgentABIRegistry.withRuntime(handle, {
        $0.runtime.registerPlatformConformingProviders(registration)
    }) else { return -2 }
    return accepted ? 0 : -1
}

@_cdecl("tessera_agent_runtime_register_platform_candidate")
public func tesseraAgentRuntimeRegisterPlatformCandidate(handle: UnsafeMutableRawPointer?, bytes: UnsafePointer<UInt8>?, count: Int) -> Int32 {
    guard let bytes, count > 0, count <= AgentABIPlatformCandidateRegistration.maximumPayloadBytes,
          let registration = try? AgentABIPlatformCandidateRegistration.decode(Data(bytes: bytes, count: count))
    else { return -1 }
    guard let accepted = CAgentABIRegistry.withRuntime(handle, { $0.runtime.registerPlatformCandidate(registration) }) else { return -2 }
    return accepted ? 0 : -1
}

@_cdecl("tessera_agent_runtime_remove_platform_candidate")
public func tesseraAgentRuntimeRemovePlatformCandidate(handle: UnsafeMutableRawPointer?, bytes: UnsafePointer<UInt8>?, count: Int) -> Int32 {
    guard let bytes, count > 0, count <= AgentABIPlatformCandidateRemoval.maximumPayloadBytes,
          let registration = try? AgentABIPlatformCandidateRemoval.decode(Data(bytes: bytes, count: count))
    else { return -1 }
    guard let accepted = CAgentABIRegistry.withRuntime(handle, { $0.runtime.removePlatformCandidate(registration) }) else { return -2 }
    return accepted ? 0 : -1
}

@_cdecl("tessera_agent_runtime_destroy")
public func tesseraAgentRuntimeDestroy(handle: UnsafeMutableRawPointer?) {
    CAgentABIRegistry.remove(handle)?.runtime.destroy()
}
