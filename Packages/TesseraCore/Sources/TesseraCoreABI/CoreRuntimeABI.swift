import Foundation
import TesseraBootstrapCore
import TesseraSessionCore

public struct CoreABICommand: Codable, Equatable, Sendable {
    public static let currentVersion = 4
    public static let maximumPayloadBytes = 1_048_576

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case connect
        case cancelConnect
        case disconnect
        case sendInput
        case resize
        case selectTmuxWindow
        case selectTmuxPane
        case sendTmuxPaneInput
        case sendTmuxPaneKey
        case createTmuxWindow
        case closeTmuxWindow
        case closeTmuxPane
        case splitTmuxPane
        case cycleTmuxPane
        case setTmuxPaneZoomed
        case moveTmuxWindow
        case renumberTmuxWindows
        case renameTmuxWindow
        case setTmuxGridPresentation
        case claimTmuxGridAuthority
        case reclaimTmuxGridAuthority
        case completeTmuxGridAuthorityRepaint
        case setFocused
        case setApplicationVisibility
        case requestFullRepaint
        case submitChallengeResponse
        case destroy
    }

    public let version: Int
    public let kind: Kind
    public let requestID: UUID?
    public let hostID: UUID?
    public let policyGeneration: UInt64?
    public let bytes: Data?
    public let columns: Int?
    public let rows: Int?
    public let targetID: String?
    public let receipt: SessionCommandReceipt?
    public let paneKey: SessionTmuxPaneKey?
    public let splitAxis: SessionTmuxSplitAxis?
    public let windowMove: TmuxWindowMove?
    public let name: String?
    public let gridPresentation: SessionTmuxGridPresentation?
    public let gridAuthorityReason: SessionTmuxGridAuthorityReason?
    public let authorityGeneration: UInt64?
    public let flag: Bool?
    public let visibility: SessionVisibility?
    public let challengeID: UUID?
    public let decision: ChallengeDecision?

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case requestID
        case hostID
        case policyGeneration
        case bytes
        case columns
        case rows
        case targetID
        case receipt
        case paneKey
        case splitAxis
        case windowMove
        case name
        case gridPresentation
        case gridAuthorityReason
        case authorityGeneration
        case flag
        case visibility
        case challengeID
        case decision
    }

    public init(
        version: Int = CoreABICommand.currentVersion,
        kind: Kind,
        requestID: UUID? = nil,
        hostID: UUID? = nil,
        policyGeneration: UInt64? = nil,
        bytes: Data? = nil,
        columns: Int? = nil,
        rows: Int? = nil,
        targetID: String? = nil,
        receipt: SessionCommandReceipt? = nil,
        paneKey: SessionTmuxPaneKey? = nil,
        splitAxis: SessionTmuxSplitAxis? = nil,
        windowMove: TmuxWindowMove? = nil,
        name: String? = nil,
        gridPresentation: SessionTmuxGridPresentation? = nil,
        gridAuthorityReason: SessionTmuxGridAuthorityReason? = nil,
        authorityGeneration: UInt64? = nil,
        flag: Bool? = nil,
        visibility: SessionVisibility? = nil,
        challengeID: UUID? = nil,
        decision: ChallengeDecision? = nil
    ) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.hostID = hostID
        self.policyGeneration = policyGeneration
        self.bytes = bytes
        self.columns = columns
        self.rows = rows
        self.targetID = targetID
        self.receipt = receipt
        self.paneKey = paneKey
        self.splitAxis = splitAxis
        self.windowMove = windowMove
        self.name = name
        self.gridPresentation = gridPresentation
        self.gridAuthorityReason = gridAuthorityReason
        self.authorityGeneration = authorityGeneration
        self.flag = flag
        self.visibility = visibility
        self.challengeID = challengeID
        self.decision = decision
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumPayloadBytes else {
            throw CoreABIError.payloadTooLarge(data.count)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw CoreABIError.emptyPayload }
        guard data.count <= maximumPayloadBytes else {
            throw CoreABIError.payloadTooLarge(data.count)
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    public func sessionCommand() throws -> SessionCommand {
        try validate()
        switch kind {
        case .connect:
            return .connect(ConnectionIntent(
                requestID: requestID!,
                hostID: hostID!,
                policyGeneration: policyGeneration!
            ))
        case .cancelConnect:
            return .cancelConnect(attemptID: requestID!)
        case .disconnect:
            return .disconnect
        case .sendInput:
            return .sendInput(bytes!)
        case .resize:
            return .resize(columns: columns!, rows: rows!)
        case .selectTmuxWindow:
            return .selectTmuxWindow(targetID!)
        case .selectTmuxPane:
            return .selectTmuxPane(targetID!)
        case .sendTmuxPaneInput:
            return .sendTmuxPaneInput(data: bytes!, paneID: targetID!, receipt: receipt)
        case .sendTmuxPaneKey:
            return .sendTmuxPaneKey(paneKey!, paneID: targetID!, receipt: receipt)
        case .createTmuxWindow:
            return .createTmuxWindow
        case .closeTmuxWindow:
            return .closeTmuxWindow(targetID!)
        case .closeTmuxPane:
            return .closeTmuxPane(targetID!)
        case .splitTmuxPane:
            return .splitTmuxPane(targetID!, axis: splitAxis!, before: flag ?? false)
        case .cycleTmuxPane:
            return .cycleTmuxPane(forward: flag!)
        case .setTmuxPaneZoomed:
            return .setTmuxPaneZoomed(targetID!, zoomed: flag!)
        case .moveTmuxWindow:
            return .moveTmuxWindow(targetID!, move: windowMove!)
        case .renumberTmuxWindows:
            return .renumberTmuxWindows
        case .renameTmuxWindow:
            return .renameTmuxWindow(targetID!, name: name!)
        case .setTmuxGridPresentation:
            return .setTmuxGridPresentation(gridPresentation!)
        case .claimTmuxGridAuthority:
            return .claimTmuxGridAuthority(
                reason: gridAuthorityReason!,
                repaintEvenIfSame: flag!
            )
        case .reclaimTmuxGridAuthority:
            return .reclaimTmuxGridAuthority(reason: gridAuthorityReason!)
        case .completeTmuxGridAuthorityRepaint:
            return .completeTmuxGridAuthorityRepaint(generation: authorityGeneration!)
        case .setFocused:
            return .setFocused(flag!)
        case .setApplicationVisibility:
            return .setApplicationVisibility(visibility!)
        case .requestFullRepaint:
            return .requestFullRepaint
        case .submitChallengeResponse:
            return .submitChallengeResponse(ChallengeResponse(
                challengeID: challengeID!,
                attemptID: requestID!,
                policyGeneration: policyGeneration!,
                decision: decision!
            ))
        case .destroy:
            return .destroy
        }
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw CoreABIError.unsupportedVersion(version)
        }
        switch kind {
        case .connect:
            guard requestID != nil, hostID != nil, policyGeneration != nil else {
                throw CoreABIError.missingField
            }
        case .cancelConnect:
            guard requestID != nil else { throw CoreABIError.missingField }
        case .sendInput:
            guard let bytes, !bytes.isEmpty, bytes.count <= Self.maximumPayloadBytes else {
                throw CoreABIError.invalidField
            }
        case .resize:
            guard let columns, let rows, columns > 0, rows > 0 else {
                throw CoreABIError.invalidField
            }
        case .selectTmuxWindow, .selectTmuxPane, .closeTmuxWindow, .closeTmuxPane:
            guard let targetID, !targetID.isEmpty, targetID.utf8.count <= 256 else {
                throw CoreABIError.invalidField
            }
        case .sendTmuxPaneInput:
            guard let targetID, !targetID.isEmpty, targetID.utf8.count <= 256,
                  let bytes, !bytes.isEmpty,
                  bytes.count <= SessionCommandLimits.maximumInputBytes
            else { throw CoreABIError.invalidField }
        case .sendTmuxPaneKey:
            guard let targetID, !targetID.isEmpty, targetID.utf8.count <= 256,
                  paneKey != nil
            else { throw CoreABIError.invalidField }
        case .splitTmuxPane:
            guard let targetID, !targetID.isEmpty, targetID.utf8.count <= 256,
                  splitAxis != nil
            else { throw CoreABIError.invalidField }
        case .cycleTmuxPane:
            guard flag != nil else { throw CoreABIError.missingField }
        case .setTmuxPaneZoomed:
            guard let targetID, !targetID.isEmpty, targetID.utf8.count <= 256,
                  flag != nil
            else { throw CoreABIError.invalidField }
        case .moveTmuxWindow:
            guard let targetID, WindowId(wireValue: targetID) != nil, let windowMove else {
                throw CoreABIError.invalidField
            }
            if case .position(let position) = windowMove, !(0..<512).contains(position) {
                throw CoreABIError.invalidField
            }
        case .renumberTmuxWindows: break
        case .renameTmuxWindow:
            guard let targetID, !targetID.isEmpty, targetID.utf8.count <= 256,
                  let name, !name.isEmpty,
                  name.unicodeScalars.count <= SessionCommandLimits.maximumRenameUnicodeScalars
            else { throw CoreABIError.invalidField }
        case .setTmuxGridPresentation:
            guard gridPresentation != nil else { throw CoreABIError.missingField }
        case .claimTmuxGridAuthority:
            guard gridAuthorityReason != nil, flag != nil else { throw CoreABIError.missingField }
        case .reclaimTmuxGridAuthority:
            guard gridAuthorityReason != nil else { throw CoreABIError.missingField }
        case .completeTmuxGridAuthorityRepaint:
            guard authorityGeneration != nil else { throw CoreABIError.missingField }
        case .setFocused:
            guard flag != nil else { throw CoreABIError.missingField }
        case .setApplicationVisibility:
            guard visibility != nil else { throw CoreABIError.missingField }
        case .submitChallengeResponse:
            guard challengeID != nil,
                  requestID != nil,
                  policyGeneration != nil,
                  decision != nil else { throw CoreABIError.missingField }
        case .disconnect, .createTmuxWindow, .requestFullRepaint, .destroy:
            break
        }
    }
}

public struct CoreABIEvent: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum Kind: String, Codable, Sendable {
        case stateChanged
        case terminalBytes
        case tmuxSnapshotChanged
        case gridAuthorityChanged
        case challenge
        case remoteWorkingDirectoryChanged
        case forwardingStateChanged
        case commandCompleted
        case recoverableWarning
        case failure
        case diagnostics
        case destroyed
        case backendCommandRequested
        case commandRejected
    }

    public let version: Int
    public let kind: Kind
    public let generation: UInt64
    public let payload: Data?
    public let code: String?
    public let arguments: [String: String]?

    public init(
        version: Int = CoreABIEvent.currentVersion,
        kind: Kind,
        generation: UInt64,
        payload: Data? = nil,
        code: String? = nil,
        arguments: [String: String]? = nil
    ) {
        self.version = version
        self.kind = kind
        self.generation = generation
        self.payload = payload
        self.code = code
        self.arguments = arguments
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= CoreABICommand.maximumPayloadBytes else {
            throw CoreABIError.payloadTooLarge(data.count)
        }
        return data
    }
}

/// Versioned events delivered by a platform adapter through
/// `tessera_core_runtime_emit`. Associated values are encoded into `payload`
/// using the public TesseraSessionCore contracts.
public struct CoreABIBackendEvent: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public enum Kind: String, Codable, Sendable {
        case transportConnected
        case transportDisconnected
        case terminalBytes
        case failure
        case tmuxSnapshotChanged
        case gridAuthorityChanged
        case challenge
        case remoteWorkingDirectoryChanged
        case forwardingStateChanged
        case commandCompleted
        case recoverableWarning
        case diagnostics
    }

    public let version: Int
    public let kind: Kind
    public let generation: UInt64?
    public let attemptID: UUID?
    public let policyGeneration: UInt64?
    public let payload: Data?
    public let code: String?
    public let arguments: [String: String]?

    public init(
        version: Int = currentVersion,
        kind: Kind,
        generation: UInt64? = nil,
        attemptID: UUID? = nil,
        policyGeneration: UInt64? = nil,
        payload: Data? = nil,
        code: String? = nil,
        arguments: [String: String]? = nil
    ) {
        self.version = version
        self.kind = kind
        self.generation = generation
        self.attemptID = attemptID
        self.policyGeneration = policyGeneration
        self.payload = payload
        self.code = code
        self.arguments = arguments
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder.coreABI.encode(self)
        guard data.count <= CoreABICommand.maximumPayloadBytes else {
            throw CoreABIError.payloadTooLarge(data.count)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw CoreABIError.emptyPayload }
        guard data.count <= CoreABICommand.maximumPayloadBytes else {
            throw CoreABIError.payloadTooLarge(data.count)
        }
        let event = try JSONDecoder().decode(Self.self, from: data)
        try event.validate()
        return event
    }

    private func validate() throws {
        guard version == Self.currentVersion else { throw CoreABIError.unsupportedVersion(version) }
        if kind == .transportDisconnected, attemptID == nil {
            throw CoreABIError.missingField
        }
    }
}

public enum CoreABIError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case emptyPayload
    case payloadTooLarge(Int)
    case missingField
    case invalidField
    case invalidHandle
}

public final class CoreABIRuntime: @unchecked Sendable {
    public typealias EventSink = @Sendable (Data) -> Void

    private let lock = NSLock()
    private var isDestroyed = false
    private var suppressCallbacks = false
    private var tail = Task<Void, Never> {}
    private let destroyCompletion = DispatchGroup()
    private let callbackScopeToken = UUID().uuidString
    private let sessionID: UUID
    private let now: @Sendable () -> Date
    private let eventSink: EventSink
    private lazy var engine = SessionEngine(
        sessionID: sessionID,
        backendPorts: SessionBackendPorts { [weak self] operation in
            try self?.emitBackendOperation(operation)
        },
        now: now,
        eventSink: { [weak self] event in self?.emit(event) }
    )

    public init(
        sessionID: UUID = UUID(),
        now: @escaping @Sendable () -> Date = { Date() },
        eventSink: @escaping EventSink
    ) {
        self.sessionID = sessionID
        self.now = now
        self.eventSink = eventSink
    }

    public func submit(_ data: Data) {
        enqueue { [self] in
            let command: SessionCommand
            do {
                command = try CoreABICommand.decode(data).sessionCommand()
            } catch {
                emitCorrelatedDecodeFailureIfPresent(in: data)
                emitRejection(code: Self.errorCode(error))
                return
            }
            do {
                try await engine.handle(command)
            } catch {
                emitRejection(
                    code: Self.errorCode(error),
                    commandCode: SessionBackendOperation(command).kindCode
                )
            }
        }
    }

    public func receive(_ data: Data) {
        enqueue { [self] in
            do {
                try await apply(CoreABIBackendEvent.decode(data))
            } catch {
                emitRejection(code: Self.errorCode(error))
            }
        }
    }

    public func destroy() {
        // A callback is allowed to tear down its own runtime. Waiting for the
        // serial tail from inside that callback would deadlock, so that path
        // atomically suppresses every later callback and lets the tail drain.
        // All non-reentrant callers get a real completion barrier: when this
        // method returns, prior work and the final destroy operation have
        // finished and the event-sink context is no longer reachable by work.
        let isReentrant = isExecutingEventSinkOnCurrentThread
        let shouldWait = !isReentrant
        lock.lock()
        if !isDestroyed {
            isDestroyed = true
            suppressCallbacks = isReentrant
            destroyCompletion.enter()
            let previous = tail
            tail = Task { [self] in
                await previous.value
                // The normal path delivers the backend destroy request and
                // destroyed event before releasing the barrier. The reentrant
                // path cannot safely call the user's context again.
                if !isReentrant {
                    try? await engine.handle(.destroy)
                }
                destroyCompletion.leave()
            }
        }
        lock.unlock()
        if shouldWait {
            destroyCompletion.wait()
        }
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard !isDestroyed else {
            lock.unlock()
            return
        }
        let previous = tail
        tail = Task {
            await previous.value
            await operation()
        }
        lock.unlock()
    }

    private func apply(_ event: CoreABIBackendEvent) async throws {
        switch event.kind {
        case .transportConnected:
            guard let attemptID = event.attemptID, let policyGeneration = event.policyGeneration else {
                throw CoreABIError.missingField
            }
            try await engine.transportConnected(
                attemptID: attemptID,
                policyGeneration: policyGeneration
            )
        case .transportDisconnected:
            guard let attemptID = event.attemptID else { throw CoreABIError.missingField }
            try await engine.transportDisconnected(attemptID: attemptID)
        case .terminalBytes:
            let payload = try requiredPayload(event)
            let receipt = try Self.terminalOutputReceipt(from: event.arguments)
            if let attemptID = event.attemptID {
                await engine.transportBytes(
                    payload,
                    attemptID: attemptID,
                    receipt: receipt
                )
            } else {
                // Backend-event ABI v1 permitted generation-only output.
                // Keep that decode path for compatibility while allowing
                // current adapters to bind every chunk to its source attempt.
                await engine.transportBytes(
                    payload,
                    generation: try requiredGeneration(event),
                    receipt: receipt
                )
            }
        case .failure:
            guard let attemptID = event.attemptID, let code = event.code else {
                throw CoreABIError.missingField
            }
            try await engine.fail(
                CoreFailure(code: code, arguments: event.arguments ?? [:]),
                attemptID: attemptID
            )
        case .tmuxSnapshotChanged:
            await engine.tmuxSnapshotChanged(
                try JSONDecoder().decode(TmuxSnapshot.self, from: requiredPayload(event)),
                generation: try requiredGeneration(event)
            )
        case .gridAuthorityChanged:
            await engine.gridAuthorityChanged(
                try JSONDecoder().decode(GridAuthoritySnapshot.self, from: requiredPayload(event)),
                generation: try requiredGeneration(event)
            )
        case .challenge:
            try await engine.challenge(
                try JSONDecoder().decode(SessionChallenge.self, from: requiredPayload(event)),
                generation: try requiredGeneration(event)
            )
        case .remoteWorkingDirectoryChanged:
            await engine.remoteWorkingDirectoryChanged(
                event.arguments?["path"],
                generation: try requiredGeneration(event)
            )
        case .forwardingStateChanged:
            await engine.forwardingStateChanged(
                try JSONDecoder().decode([ForwardingState].self, from: requiredPayload(event)),
                generation: try requiredGeneration(event)
            )
        case .commandCompleted:
            let completion = try JSONDecoder().decode(
                SessionCommandCompletion.self,
                from: requiredPayload(event)
            )
            await engine.backendCommandCompleted(
                receipt: completion.receipt,
                result: completion.result
            )
        case .recoverableWarning:
            guard let code = event.code else { throw CoreABIError.missingField }
            await engine.recoverableWarning(
                CoreFailure(code: code, arguments: event.arguments ?? [:]),
                generation: try requiredGeneration(event)
            )
        case .diagnostics:
            guard let code = event.code else { throw CoreABIError.missingField }
            await engine.diagnostic(
                DiagnosticEvent(code: code, values: event.arguments ?? [:]),
                generation: try requiredGeneration(event)
            )
        }
    }

    private func requiredGeneration(_ event: CoreABIBackendEvent) throws -> SessionGeneration {
        guard let generation = event.generation else { throw CoreABIError.missingField }
        return SessionGeneration(rawValue: generation)
    }

    private func requiredPayload(_ event: CoreABIBackendEvent) throws -> Data {
        guard let payload = event.payload else { throw CoreABIError.missingField }
        return payload
    }

    private func emitBackendOperation(_ operation: SessionBackendOperation) throws {
        let event = CoreABIEvent(
            kind: .backendCommandRequested,
            generation: 0,
            payload: try JSONEncoder.coreABI.encode(operation),
            code: operation.kindCode,
            arguments: ["sessionID": sessionID.uuidString]
        )
        deliver(try event.encoded())
    }

    private func emit(_ event: SessionEvent) {
        let envelope: CoreABIEvent
        switch event {
        case .stateChanged(let generation, let state):
            envelope = CoreABIEvent(
                kind: .stateChanged,
                generation: generation.rawValue,
                code: Self.stateCode(state)
            )
        case .terminalBytes(let generation, let bytes, let receipt):
            envelope = CoreABIEvent(
                kind: .terminalBytes,
                generation: generation.rawValue,
                payload: bytes,
                arguments: receipt.map {
                    var values = ["deliveryID": String($0.deliveryID)]
                    if let repaintRequestID = $0.repaintRequestID {
                        values["repaintRequestID"] = String(repaintRequestID)
                    }
                    return values
                }
            )
        case .failure(let generation, let failure):
            envelope = CoreABIEvent(
                kind: .failure,
                generation: generation.rawValue,
                code: failure.code,
                arguments: failure.arguments
            )
        case .recoverableWarning(let generation, let warning):
            envelope = CoreABIEvent(
                kind: .recoverableWarning,
                generation: generation.rawValue,
                code: warning.code,
                arguments: warning.arguments
            )
        case .destroyed(let generation):
            envelope = CoreABIEvent(kind: .destroyed, generation: generation.rawValue)
        case .tmuxSnapshotChanged(let generation, let snapshot):
            envelope = CoreABIEvent(
                kind: .tmuxSnapshotChanged,
                generation: generation.rawValue,
                payload: try? JSONEncoder().encode(snapshot)
            )
        case .gridAuthorityChanged(let generation, let snapshot):
            envelope = CoreABIEvent(
                kind: .gridAuthorityChanged,
                generation: generation.rawValue,
                payload: try? JSONEncoder().encode(snapshot)
            )
        case .challenge(let generation, let challenge):
            envelope = CoreABIEvent(
                kind: .challenge,
                generation: generation.rawValue,
                payload: try? JSONEncoder.coreABI.encode(challenge),
                code: Self.challengeCode(challenge),
                arguments: [
                    "challengeID": challenge.context.challengeID.uuidString,
                    "attemptID": challenge.context.attemptID.uuidString,
                    "policyGeneration": String(challenge.context.policyGeneration),
                ]
            )
        case .remoteWorkingDirectoryChanged(let generation, let path):
            envelope = CoreABIEvent(
                kind: .remoteWorkingDirectoryChanged,
                generation: generation.rawValue,
                arguments: path.map { ["path": $0] }
            )
        case .forwardingStateChanged(let generation, let states):
            envelope = CoreABIEvent(
                kind: .forwardingStateChanged,
                generation: generation.rawValue,
                payload: try? JSONEncoder().encode(states)
            )
        case .commandCompleted(let generation, let receipt, let result):
            envelope = CoreABIEvent(
                kind: .commandCompleted,
                generation: generation.rawValue,
                payload: try? JSONEncoder.coreABI.encode(SessionCommandCompletion(
                    receipt: receipt,
                    result: result
                ))
            )
        case .diagnostics(let generation, let diagnostic):
            envelope = CoreABIEvent(
                kind: .diagnostics,
                generation: generation.rawValue,
                code: diagnostic.code,
                arguments: diagnostic.values
            )
        }
        if let data = try? envelope.encoded() { deliver(data) }
    }

    private static func terminalOutputReceipt(
        from arguments: [String: String]?
    ) throws -> TerminalOutputReceipt? {
        guard let arguments else { return nil }
        let rawDeliveryID = arguments["deliveryID"]
        let rawRepaintRequestID = arguments["repaintRequestID"]
        guard rawDeliveryID != nil || rawRepaintRequestID == nil else {
            throw CoreABIError.invalidField
        }
        guard let rawDeliveryID else { return nil }
        guard let deliveryID = UInt64(rawDeliveryID),
              deliveryID > 0,
              deliveryID <= TerminalOutputReceipt.maximumIdentifier else {
            throw CoreABIError.invalidField
        }
        let repaintRequestID: UInt64?
        if let rawRepaintRequestID {
            guard let parsed = UInt64(rawRepaintRequestID),
                  parsed > 0,
                  parsed <= TerminalOutputReceipt.maximumIdentifier else {
                throw CoreABIError.invalidField
            }
            repaintRequestID = parsed
        } else {
            repaintRequestID = nil
        }
        return TerminalOutputReceipt(
            deliveryID: deliveryID,
            repaintRequestID: repaintRequestID
        )
    }

    private func emitRejection(code: String, commandCode: String? = nil) {
        let event = CoreABIEvent(
            kind: .commandRejected,
            generation: 0,
            code: code,
            arguments: commandCode.map { ["command": $0] }
        )
        if let data = try? event.encoded() { deliver(data) }
    }

    private struct ReceiptProbe: Decodable {
        let receipt: SessionCommandReceipt?
    }

    private func emitCorrelatedDecodeFailureIfPresent(in data: Data) {
        guard !data.isEmpty,
              data.count <= CoreABICommand.maximumPayloadBytes,
              let probe = try? JSONDecoder().decode(ReceiptProbe.self, from: data),
              let receipt = probe.receipt
        else { return }
        let completion = SessionCommandCompletion(
            receipt: receipt,
            result: .failed(CoreFailure(code: "command_rejected"))
        )
        let event = CoreABIEvent(
            kind: .commandCompleted,
            generation: 0,
            payload: try? JSONEncoder.coreABI.encode(completion)
        )
        if let encoded = try? event.encoded() { deliver(encoded) }
    }

    private var isExecutingEventSinkOnCurrentThread: Bool {
        Thread.current.threadDictionary[Self.callbackScopeKey] as? String == callbackScopeToken
    }

    private func deliver(_ data: Data) {
        lock.lock()
        let shouldDeliver = !suppressCallbacks
        lock.unlock()
        guard shouldDeliver else { return }

        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.callbackScopeKey]
        dictionary[Self.callbackScopeKey] = callbackScopeToken
        defer {
            if let previous {
                dictionary[Self.callbackScopeKey] = previous
            } else {
                dictionary.removeObject(forKey: Self.callbackScopeKey)
            }
        }
        eventSink(data)
    }

    private static let callbackScopeKey = "com.bambouville.tessera.core-abi.callback-runtime"

    private static func stateCode(_ state: SharedSessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed(let failure): return failure.code
        }
    }

    private static func challengeCode(_ challenge: SessionChallenge) -> String {
        switch challenge {
        case .hostKey: return "host_key"
        case .credential: return "credential"
        case .ownerAuthorization: return "owner_authorization"
        case .importConflict: return "import_conflict"
        }
    }

    private static func errorCode(_ error: Error) -> String {
        switch error {
        case let error as CoreABIError: return "abi_\(String(describing: error))"
        case let error as SessionEngineError: return "session_\(String(describing: error))"
        case let error as ChallengeValidationError: return challengeErrorCode(error)
        default: return "command_failed"
        }
    }

    private static func challengeErrorCode(_ error: ChallengeValidationError) -> String {
        switch error {
        case .duplicateChallenge: return "challenge_duplicate"
        case .unknownChallenge: return "challenge_unknown"
        case .staleSession: return "challenge_stale_session"
        case .staleAttempt: return "challenge_stale_attempt"
        case .stalePolicy: return "challenge_stale_policy"
        case .expired: return "challenge_expired"
        case .alreadyConsumed: return "challenge_already_consumed"
        case .invalidLifetime: return "challenge_invalid_lifetime"
        case .invalidDisplayMetadata: return "challenge_invalid_display_metadata"
        case .encodedSizeExceeded: return "challenge_encoded_size_exceeded"
        }
    }
}

private extension JSONEncoder {
    static var coreABI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public typealias TesseraCoreABIEventCallback = @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void

private final class CCoreABIRuntime: @unchecked Sendable {
    let callback: TesseraCoreABIEventCallback
    let context: UnsafeMutableRawPointer?
    let runtime: CoreABIRuntime

    init(callback: @escaping TesseraCoreABIEventCallback, context: UnsafeMutableRawPointer?) {
        self.callback = callback
        self.context = context
        let callbackBox = CallbackBox(callback: callback, context: context)
        runtime = CoreABIRuntime { data in
        data.withUnsafeBytes { raw in
                callbackBox.callback(
                raw.bindMemory(to: UInt8.self).baseAddress,
                data.count,
                    callbackBox.context
            )
        }
        }
    }
}

private final class CallbackBox: @unchecked Sendable {
    let callback: TesseraCoreABIEventCallback
    let context: UnsafeMutableRawPointer?

    init(callback: @escaping TesseraCoreABIEventCallback, context: UnsafeMutableRawPointer?) {
        self.callback = callback
        self.context = context
    }
}

private enum CCoreABIRegistry {
    private static let lock = NSLock()
    private static var nextToken: UInt = 1
    private static var runtimes: [UInt: CCoreABIRuntime] = [:]

    static func insert(_ runtime: CCoreABIRuntime) -> UnsafeMutableRawPointer {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        runtimes[token] = runtime
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    static func withRuntime<T>(
        _ handle: UnsafeMutableRawPointer?,
        _ body: (CCoreABIRuntime) -> T
    ) -> T? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let runtime = runtimes[token] else { return nil }
        return body(runtime)
    }

    static func remove(_ handle: UnsafeMutableRawPointer?) -> CCoreABIRuntime? {
        guard let token = handle.map({ UInt(bitPattern: $0) }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return runtimes.removeValue(forKey: token)
    }
}

@_cdecl("tessera_core_abi_version")
public func tesseraCoreABIVersion() -> UInt32 {
    UInt32(CoreABICommand.currentVersion)
}

@_cdecl("tessera_core_abi_max_payload_bytes")
public func tesseraCoreABIMaxPayloadBytes() -> Int {
    CoreABICommand.maximumPayloadBytes
}

@_cdecl("tessera_core_runtime_create")
public func tesseraCoreRuntimeCreate(
    callback: @escaping TesseraCoreABIEventCallback,
    context: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer {
    CCoreABIRegistry.insert(CCoreABIRuntime(callback: callback, context: context))
}

@_cdecl("tessera_core_runtime_send")
public func tesseraCoreRuntimeSend(
    handle: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int
) -> Int32 {
    guard let handle, let bytes, count > 0, count <= CoreABICommand.maximumPayloadBytes else {
        return -1
    }
    guard CCoreABIRegistry.withRuntime(handle, { holder in
        holder.runtime.submit(Data(bytes: bytes, count: count))
    }) != nil else { return -2 }
    return 0
}

@_cdecl("tessera_core_runtime_emit")
public func tesseraCoreRuntimeEmit(
    handle: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int
) -> Int32 {
    guard let bytes, count > 0, count <= CoreABICommand.maximumPayloadBytes else { return -1 }
    guard CCoreABIRegistry.withRuntime(handle, { holder in
        holder.runtime.receive(Data(bytes: bytes, count: count))
    }) != nil else { return -2 }
    return 0
}

@_cdecl("tessera_core_runtime_destroy")
public func tesseraCoreRuntimeDestroy(handle: UnsafeMutableRawPointer?) {
    CCoreABIRegistry.remove(handle)?.runtime.destroy()
}
